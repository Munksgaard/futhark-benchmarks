import "lib/github.com/diku-dk/fft/stockham-radix-2"
import "lib/github.com/diku-dk/complex/complex"
import "lib/github.com/athas/matte/colour"
import "lib/github.com/diku-dk/cpprandom/random"
import "lib/github.com/diku-dk/segmented/segmented"

module fft = mk_fft f32
module complex = mk_complex f32
type complex = complex.complex

module rng_engine = minstd_rand
module uniform_f32 = uniform_real_distribution f32 rng_engine
module uniform_i32 = uniform_int_distribution i32 rng_engine

type sigmoid = #hard | #smooth | #atan | #atancos |
               #overshoot | #linear | #hermite | #sin

type conf =
  { world_size: i32
  , timestep: f32
  , rim: f32
  , disc_radius: (f32, f32)
  , birth_interval: (f32, f32)
  , death_interval: (f32, f32)
  , step: (f32, f32)
  , timestep_mode: i32
  , sig_mode: i32
  , sig_type: sigmoid
  , mix_type: sigmoid
  }

type state =
  { conf: conf
  , world: [][]f32
  , krf: [][]complex
  , kdf: [][]complex
  , kflr: f32
  , kfld: f32
  , seed: i32
  }

let default_conf: conf =
  { world_size    = 256
  , timestep       = 0.1
  , rim            = 1.0
  , disc_radius    = (10.0 / 3.0, 10.0)
  , birth_interval = (0.257, 0.336)
  , death_interval = (0.365, 0.549)
  , step           = (0.028, 0.147)
  , timestep_mode  = 1
  , sig_mode       = 2
  , sig_type       = #smooth : sigmoid
  , mix_type       = #smooth : sigmoid
  }

let make_conf_simple (win_size: i32) (timestep: f32): conf =
  default_conf with world_size = win_size
               with timestep = timestep

let make_conf (world_size: i32)
              (timestep: f32)
              (rim: f32)
              (disc_radius1: f32) (disc_radius2: f32)
              (birth_interval1: f32) (birth_interval2: f32)
              (death_interval1: f32) (death_interval2: f32)
              (step1: f32) (step2: f32)
              (timestep_mode: i32)
              (sig_mode: i32)
              (sig_type: i32)
              (mix_type: i32)
              : conf =
  let to_sigmoid n =
    match n
      case 0 -> #hard
      case 1 -> #smooth
      case 2 -> #atan
      case 3 -> #atancos
      case 4 -> #overshoot
      case 5 -> #linear
      case 6 -> #hermite
      case 7 -> #sin
      case _ -> #smooth
  in
  { world_size = world_size
  , timestep = timestep
  , rim = rim
  , disc_radius = (disc_radius1, disc_radius2)
  , birth_interval = (birth_interval1, birth_interval2)
  , death_interval = (death_interval1, death_interval2)
  , step = (step1, step2)
  , timestep_mode = timestep_mode
  , sig_mode = sig_mode
  , sig_type = to_sigmoid sig_type
  , mix_type = to_sigmoid mix_type
  }

let generate_world (size: i32) (disc: (f32, f32)) (seed: i32): [][]f32 =
  let (rmin, rmax) = disc
  let num_circles = size * size / t32 (rmax * rmax)

  let mk_circle rng z =
    let (rng, cell) = uniform_i32.rand (0, 1) rng
    let (rng, radius) = uniform_f32.rand (rmin, rmax) rng
    let (rng, x) = uniform_i32.rand (0, size - 1) rng
    let (rng, y) = uniform_i32.rand (0, size - 1) rng
    in (rng, (z, cell, radius, x, y))

  let lines_in_circle (_, _, r, _, _) = f32.round (2 * r) |> t32
  let get_line_in_circle (z, cell, r, x, y) (i: i32) =
    let a = r - (r32 i)
    let l = a * a - r * r |> f32.abs |> f32.sqrt
    let p1 = (t32 (f32.round ((r32 x) - l)), y + (f32.round a |> t32))
    let p2 = (t32 (f32.round ((r32 x) + l)), y + (f32.round a |> t32))
    in (z, cell, p1.1, p1.2, p2.1, p2.2)

  let points_in_line (_, _, x1, y1, x2, y2) =
    i32.(1 + max (abs (x2 - x1)) (abs (y2 - y1)))
  let get_point_in_line (z, cell, x1, y1, x2, y2) (i: i32) =
    let compare (v1) (v2) =
      if v2 > v1 then 1 else if v1 > v2 then -1 else 0
    let slope ((x1, y1)) ((x2, y2)) =
      if x2==x1
      then if y2>y1 then r32(1) else r32(-1)
      else r32(y2-y1) / r32(i32.abs(x2-x1))
    let p1 = (x1, y1)
    let p2 = (x2, y2) in
    if i32.abs (p1.1 - p2.1) > i32.abs (p1.2 - p2.2)
    then let dir = compare (p1.1) (p2.1)
         let sl = slope p1 p2
         let p = (p1.1 + dir * i, p1.2 + i32.f32 (f32.round (sl * r32 i)))
         in (z, cell, p.1, p.2)
    else let dir = compare (p1.2) (p2.2)
         let sl = slope (p1.2, p1.1) (p2.2, p2.1)
         let p = (p1.1 + i32.f32 (f32.round (sl * r32 i)), p1.2 + i * dir)
         in (z, cell, p.1, p.2)

  let rngs = rng_engine.rng_from_seed [seed] |>
             rng_engine.split_rng num_circles
  let (_, circles) = map2 mk_circle rngs (iota num_circles) |> unzip
  let lines = expand lines_in_circle get_line_in_circle circles
  let points = expand points_in_line get_point_in_line lines

  let (points, idxs) =
    map (\(z, cell, x, y) -> ((z, cell), size * y + x)) points |> unzip
  let op p1 p2 = if p1.1 >= p2.1 then p1 else p2
  let ne = (-1, 0)
  let initial_bins = map (const ne) (iota (size * size))
  let reduced = reduce_by_index initial_bins op ne idxs points
  let grid = map ((.2) >-> r32) reduced
  in unflatten size size grid

let init (conf: conf) (seed: i32): state =

  let shift2d 'a [r][c] (arr: [r][c]a): [r][c]a =
    let (mr, mc) = (r / 2, c / 2)
    let indices = map (\ir -> map (\ic -> (ir,ic)) (iota c)) (iota r) |> flatten
    let shift (ir, ic) =
      ( if ir < mr then ir + mr else ir - mr
      , if ic < mc then ic + mc else ic - mc
      )
    let indices' = map (\(ir, ic) -> let (ir', ic') = shift (ir, ic)
                                     in ir' * c + ic'
                       ) indices
    let arr' = flatten arr
    in scatter (copy arr') indices' arr' |> unflatten r c

  let size = conf.world_size
  let (ri, ra) = conf.disc_radius
  let b = conf.rim

  let linear (x: f32) (l: f32) (u: f32): f32 =
    if      x < l - u / 2 then 0.0
    else if x > l + u / 2 then 1.0
    else                       (x - l + u / 2) / u
  let radius ((y', x'): (i32, i32)) (size: i32): f32 =
    let x = x' - (size / 2)
    let y = y' - (size / 2)
    in f32.sqrt <| r32 (x * x + y * y)

  let kr = map (\y ->
             map (\x ->
               let r = radius (y, x) size
               in linear r ri b * (1 - linear r ra b)
             ) (iota size)
           ) (iota size)
  let kd = map (\y ->
             map (\x ->
               1 - linear (radius (y, x) size) ri b
             ) (iota size)
           ) (iota size)
  let krf = fft.fft2_re (shift2d kr)
  let kdf = fft.fft2_re (shift2d kd)
  let kflr = reduce (+) 0 (flatten kr)
  let kfld = reduce (+) 0 (flatten kd)

  in { conf = conf
     , world = generate_world size conf.disc_radius seed
     , krf = krf
     , kdf = kdf
     , kflr = kflr
     , kfld = kfld
     , seed = seed
     }

let apply_sigmoid (s: sigmoid) (x: f32) (a: f32) (ea: f32) =
  let bounded f =
        if      x < a - ea / 2.0 then 0.0
        else if x > a + ea / 2.0 then 1.0
        else                          f x a ea
  in
  match s
    case #hard       -> if x >= a then 1 else 0
    case #smooth     -> 1.0 / (1.0 + f32.exp (-(x - a) * 4.0 / ea))
    case #atan       -> f32.atan ((x - a) * f32.pi / ea) / f32.pi + 0.5
    case #atancos    -> 0.5 * (0.5 * f32.atan ((x - a) / ea) / f32.pi
                          * f32.cos ((x - a) * 1.4) * 1.1 + 1.0)
    case #overshoot  -> 0.5 + (1.0 / (1.0 + f32.exp (-(x - a) * 4.0 / ea)) - 0.5)
                          * (1.0 + f32.exp (-(x - a) * (x - a) / ea / ea))
    case #linear     -> bounded (\x a ea -> (x - a) / ea + 0.5)
    case #hermite    -> bounded (\x a ea -> let v = (x - (a - ea / 2.0)) / ea
                                            in v * v * (3.0 - 2.0 * v))
    case #sin        -> bounded (\x a ea -> f32.sin (f32.pi * (x - a) / ea)
                                              * 0.5 + 0.5)

let snm [l] (conf: conf) (n: [l]f32) (m: [l]f32): [l]f32 =
  let (b1, b2) = conf.birth_interval
  let (d1, d2) = conf.death_interval
  let (sn, sm) = conf.step
  let sigtype = conf.sig_type
  let mixtype = conf.mix_type
  let sigmoid_ab x a b =
    apply_sigmoid sigtype x a sn
    * (1.0 - apply_sigmoid sigtype x b sn)
  let sigmoid_mix x y m =
    x * (1 - apply_sigmoid mixtype m 0.5 sm)
    + y * apply_sigmoid mixtype m 0.5 sm
  let mix x y a = x * (1 - a) + y * a
  let sigmode n m =
    match conf.sig_mode
      case 1 -> mix          (sigmoid_ab n b1 b2)
                             (sigmoid_ab n d1 d2) m
      case 2 -> sigmoid_mix  (sigmoid_ab n b1 b2)
                             (sigmoid_ab n d1 d2) m
      case 3 -> sigmoid_ab n (mix b1 d1 m)
                             (mix b2 d2 m)
      case 4 -> sigmoid_ab n (sigmoid_mix b1 d1 m)
                             (sigmoid_mix b2 d2 m)
  in map2 sigmode n m

let step (state: state): state =
  let dt = state.conf.timestep
  let aa = state.world
  let (r, c) = (state.conf.world_size, state.conf.world_size)

  let aaf = fft.fft2_re aa
  let nf = map2 (complex.*) (flatten aaf) (flatten state.krf)
  let mf = map2 (complex.*) (flatten aaf) (flatten state.kdf)
  let n = map (\x -> complex.re x / state.kflr) (fft.ifft2 (unflatten r c nf) |> flatten)
  let m = map (\x -> complex.re x / state.kfld) (fft.ifft2 (unflatten r c mf) |> flatten)
  let aa' = snm state.conf n m |> unflatten r c

  let timestep f g =
    match state.conf.timestep_mode
      case 0 -> f
      case 1 -> g + dt * (2.0 * f - 1.0)
      case 2 -> g + dt * (f - g)
  let clamp v = f32.min (f32.max v 0.0) 1.0
  let aa'' = map2 (map2 (\a b -> clamp (timestep a b))) aa' aa
  in state with world = aa''

let render (state: state): [][]argb.colour =
  let w = state.world |> flatten
  let (r, c) = (state.conf.world_size, state.conf.world_size)
  in map (\v -> argb_colour.from_rgba v v v 0) w |> unflatten r c

type text_content = (i32, i32, i32)

-- Due to FFT limitations we always the size up to a power of 2.
let to_pow2 x = t32 (2 ** f32.ceil (f32.log2 (r32 x)))

-- Run as ./smoothlife -R -w 256 -h 256
-- Uses default config, since lys does not support any kind of custom
-- configuration atm
import "lib/github.com/diku-dk/lys/lys"
module lys: lys with text_content = text_content = {
  type state = {state: state, h: i32, w: i32}

  let init (seed: i32) (h: i32) (w: i32): state =
    let conf = make_conf_simple (to_pow2 (i32.min h w)) 0.1
    in {state=init conf seed, h, w}

  let step _ (s: state) = s with state = step s.state

  -- Cut it down to requested size.
  let render (s: state) =
    let screen = render s.state
    in map (take s.w) screen |> take s.h

  -- Resizes can occur even with the -R flag to lys (at least on my machine,
  -- with XMonad). World must be reinit'd on resize, since lys assumes world
  -- and window dimensions are equal
  let resize (h: i32) (w: i32) (s: state): state = init s.state.seed h w

  let grab_mouse = false

  let key (e: key_event) (key: i32) (s: state): state =
    if e == #keydown && key == SDLK_SPACE
    then init s.state.seed (length s.state.world) (length s.state.world[0])
    else s

  let mouse _ _ _ = id
  let wheel _ _ = id

  type text_content = text_content
  let text_format = "FPS: %d\nWorld: %d by %d"
  let text_content (render_duration: f32) (s: state): text_content =
    (t32 render_duration, length s.state.world, length s.state.world[0])
  let text_colour = const argb.yellow
}

-- And an entry point for benchmarking.  Measures initialisation and a
-- hundred frames (to amortise the initialisation cost).
-- ==
-- compiled input { 128 }
-- compiled input { 256 }
-- compiled input { 512 }
-- compiled input { 1024 }
let main (w: i32) =
  make_conf_simple w 0.1 |> (`init` 123) |> iterate 100 step |> (.world)