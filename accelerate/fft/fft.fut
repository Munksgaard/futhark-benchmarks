-- Straightforward port of the highpass filter from Accelerate's
-- example.  Uses the FFT implementation from Futhark's standard
-- library, so go there if you want to see how that one works.
-- ==
-- compiled input @ data/256x256.in
-- output @ data/256x256.out
-- compiled input @ data/128x512.in
-- output @ data/128x512.out
-- compiled input @ data/64x256.in
-- output @ data/64x256.out
-- compiled input @ data/512x512.in
-- output @ data/512x512.out
-- compiled input @ data/1024x1024.in
-- output @ data/1024x1024.out
-- compiled input @ data/128x128.in
-- output @ data/128x128.out

import "/futlib/complex"

module c32 = complex f32
type c32 = c32.complex

import "/futlib/fft"

module fft = mk_fft f32

let centre_2d [n][m] (arr: [n][m]c32): [n][m]c32 =
  let f (i: i32) (j: i32) (x: c32) =
        c32.mk_re (f32.i32 ((-1) ** (i+j))) c32.* x
  in map (\(i,r) -> map (\(j,x) -> f i j x) (zip (iota m) r)) (zip (iota n) arr)

let transform [n][m] (cutoff: i32) (arr: [n][m]u8) =
  let arr_complex = map (\r -> map c32.mk_re (map f32.u8 r)) arr
  let arr_centered = centre_2d arr_complex
  let arr_freq = fft.fft2 arr_centered
  let centre_i = n / 2
  let centre_j = m / 2
  let zap (i: i32) (j: i32) (x: c32) =
        if i > centre_i - cutoff && i < centre_i + cutoff &&
           j > centre_j - cutoff && j < centre_j + cutoff
        then c32.mk_re 0f32 else x
  let arr_filt = map (\(i,r) -> map (\(j,x) -> zap i j x) (zip (iota m) r))
                     (zip (iota n) arr_freq)
  let arr_inv = fft.ifft2 arr_filt
  in map (\r -> map c32.mag r) arr_inv

-- We have two entry points, for testing and the actual high-pass
-- filtering application.  The reason is that rounding the f32 values
-- to u8 induces too many false negatives when testing on hardware
-- with less accurate floats (such as GPUs).

import "/futlib/colour"

let unpack_rgb (x: [3]u8): (u8, u8, u8) =
  (x[0], x[1], x[2])

let main [n][m] (cutoff: i32) (img: [n][m][3]u8): [n][m][3]f32 =
  let (r, g, b) = unzip (map (\r -> map unpack_rgb r) img)
  let r' = transform cutoff r
  let g' = transform cutoff g
  let b' = transform cutoff b
  in map (\x -> map (\(r,g,b) -> [r, g, b]) x) (zip@1 r' g' b')

let pack_rgb ((r,g,b): (f32, f32, f32)): [3]u8 =
  [u8.f32 r, u8.f32 g, u8.f32 b]

entry highpass_filter [n][m] (cutoff: i32) (img: [n][m][3]u8): [n][m][3]u8 =
  let csss = main cutoff img
  in map (\css -> map (\cs -> map u8.f32 cs) css) csss