-- Fluid simulation library.
--
-- A port of Accelerate's version:
-- https://github.com/AccelerateHS/accelerate-examples/tree/master/examples/fluid
-- (mostly based on the C version, since it was simpler).
--
-- Variable naming conventions:
--
--   + `g`: The grid resolution.  The fluid simulation works on a square grid of
--          size `g * g`.
--   + `i`: the horizontal index.
--   + `j`: the vertical index.
--   + `S*`: Some array, purpose unknown.
--   + `U*`: Array of horizontal forces.
--   + `V*`: Array of vertical forces.
--   + `D*`: Array of densities.
--
-- The simulation handles the 1-size border around the `(g - 2) * (g - 2)` grid
-- differently from the inner content.  The border depends on the outermost
-- inner values.  The original C version writes this border after writing the
-- inner values, by reading from the array.  We would like to handle this
-- pattern with a single map, so the Futhark port instead *calculates* the
-- outermost inner values when it needs them for the outer bound values, which
-- means that a few calculations are done twice.  The alternative would be to
-- first calculate all the inner values, and then write the outer values
-- afterwards.
--
-- This file has no main function, only fluid simulation library functions.  Two
-- Futhark programs use this library:
--
--   + `fluid-visualize-densities.fut`: Generate `n_steps` frames with the
--     evolving densities.
--   + `fluid-measure.fut`: Calculate the resulting densities and forces after
--     `n_steps`, not spending memory to store the intermediate frames.
--
-- The different `main` functions take the same arguments.
-- ==
-- tags { disable }

------------------------------------------------------------
-- General helper functions.
------------------------------------------------------------

fun bool inside(i32 i, i32 j, i32 g) =
  i >= 1 && i <= g - 2
  && j >= 1 && j <= g - 2

fun bool in_outside_corner(i32 i, i32 j, i32 g) =
  (i == 0 || i == g - 1) && (j == 0 || j == g - 1)
  
fun {i32, i32, i32, i32} corner_index_neighbors(i32 i, i32 j, i32 g) =
  if i == 0 && j == 0
  then {1, 0, 0, 1}
  else if i == 0 && j == g - 1
  then {1, g - 1, 0, g - 2}
  else if i == g - 1 && j == 0
  then {g - 2, 0, g - 1, 1}
  else {g - 2, g - 1, g - 1, g - 2} -- if i == g - 1 && j == g - 1

fun {i32, i32, f32} outermost_inner_index(i32 i, i32 j, i32 g, i32 b) =
  if i == 0
  then {1, j, if b == 1 then -1.0f32 else 1.0f32}
  else if i == g - 1
  then {g - 2, j, if b == 1 then -1.0f32 else 1.0f32}
  else if j == 0
  then {i, 1, if b == 2 then -1.0f32 else 1.0f32}
  else if j == g - 1
  then {i, g - 2, if b == 2 then -1.0f32 else 1.0f32}
  else {0, 0, 0.0f32} -- This is not supposed to happen.


------------------------------------------------------------
-- lin_solve.
------------------------------------------------------------

fun *[[f32, g], g]
  lin_solve(i32 n_solver_steps,
            [[f32, g], g] S0,
            i32 b,
            f32 a,
            f32 c) =
  let one = (g*g+2*g+1)/(g+1) - g in
  loop (S1 = replicate(g, replicate(g, 0.0f32))) = for k < n_solver_steps do
    reshape((g, g),
      map(fn f32 (i32 ij) =>
            let i = ij / g in
            let j = ij % g in
            if inside(i, j, g)
            then lin_solve_inner(i, j, S0, S1, a, c)
            else lin_solve_outer(i/one, j/one, S0, S1, a, c, b/one)
              -- lin_solve_outer(i, j, S0, S1, a, c, b)
         , iota(g * g)))
  in S1

fun f32
  lin_solve_inner(i32 i,
                  i32 j,
                  [[f32, g], g] S0,
                  [[f32, g], g] S1,
                  f32 a,
                  f32 c) =
  -- A stencil.
  unsafe ((S0[i, j] + a *
           (S1[(i - 1), j]
            + S1[(i + 1), j]
            + S1[i, (j - 1)]
            + S1[i, (j + 1)])) / c)

fun f32
  lin_solve_outer(i32 i,
                  i32 j,
                  [[f32, g], g] S0,
                  [[f32, g], g] S1,
                  f32 a,
                  f32 c,
                  i32 b) =
  if in_outside_corner(i, j, g)
  then let {i1, j1, i2, j2} = corner_index_neighbors(i, j, g)
       in 0.5f32 * (lin_solve_outer_base(i1, j1, S0, S1, a, c, b)
                    + lin_solve_outer_base(i2, j2, S0, S1, a, c, b))
  else lin_solve_outer_base(i, j, S0, S1, a, c, b)

fun f32
  lin_solve_outer_base(i32 i,
                       i32 j,
                       [[f32, g], g] S0,
                       [[f32, g], g] S1,
                       f32 a,
                       f32 c,
                       i32 b) =
  let {i1, j1, f} = outermost_inner_index(i, j, g, b)
  in f * lin_solve_inner(i1, j1, S0, S1, a, c)


------------------------------------------------------------
-- diffuse.
------------------------------------------------------------

fun [[f32, g], g]
  diffuse([[f32, g], g] S,
          i32 b,
          i32 n_solver_steps,
          f32 diffusion_rate_or_viscosity,
          f32 time_step) =
  let a = (time_step * diffusion_rate_or_viscosity
           * f32(g - 2) * f32(g - 2)) in
  lin_solve(n_solver_steps, S, b, a, 1.0f32 + 4.0f32 * a)


------------------------------------------------------------
-- advect.
------------------------------------------------------------

fun *[[f32, g], g]
  advect([[f32, g], g] S0,
         [[f32, g], g] U,
         [[f32, g], g] V,
         i32 b,
         f32 time_step) =
  let one = (g*g+2*g+1)/(g+1) - g in
  let time_step0 = time_step * f32(g - 2) in
  reshape((g, g), 
    map(fn f32 (i32 ij) =>
          let i = ij / g in
          let j = ij % g in
          if inside(i, j, g)
          then advect_inner(i, j, S0, U, V, time_step0)
          else advect_outer(i/one, j/one, S0, U, V, time_step0, b/one)
       , iota(g * g)))

fun f32
  advect_inner(i32 i,
               i32 j,
               [[f32, g], g] S0,
               [[f32, g], g] U,
               [[f32, g], g] V,
               f32 time_step0) =
  let x = f32(i) - time_step0 * unsafe U[i, j] in
  let y = f32(j) - time_step0 * unsafe V[i, j] in

  let x = if x < 0.5f32 then 0.5f32 else x in
  let x = if x > f32(g - 2) + 0.5f32 then f32(g - 2) + 0.5f32 else x in
  let i0 = i32(x) in
  let i1 = i0 + 1 in

  let y = if y < 0.5f32 then 0.5f32 else y in
  let y = if y > f32(g - 2) + 0.5f32 then f32(g - 2) + 0.5f32 else y in
  let j0 = i32(y) in
  let j1 = j0 + 1 in

  let s1 = x - f32(i0) in
  let s0 = 1.0f32 - s1 in
  let t1 = y - f32(j0) in
  let t0 = 1.0f32 - t1 in

  unsafe (s0 * (t0 * S0[i0, j0] + t1 * S0[i0, j1])
          + s1 * (t0 * S0[i1, j0] + t1 * S0[i1, j1]))

fun f32
  advect_outer(i32 i,
               i32 j,
               [[f32, g], g] S0,
               [[f32, g], g] U,
               [[f32, g], g] V,
               f32 time_step0,
               i32 b) =
  if in_outside_corner(i, j, g)
  then let {i1, j1, i2, j2} = corner_index_neighbors(i, j, g)
       in 0.5f32 * (advect_outer_base(i1, j1, S0, U, V, time_step0, b)
                    + advect_outer_base(i2, j2, S0, U, V, time_step0, b))
  else advect_outer_base(i, j, S0, U, V, time_step0, b)

fun f32
  advect_outer_base(i32 i,
                    i32 j,
                    [[f32, g], g] S0,
                    [[f32, g], g] U,
                    [[f32, g], g] V,
                    f32 time_step0,
                    i32 b) =
  let {i1, j1, f} = outermost_inner_index(i, j, g, b)
  in f * advect_inner(i1, j1, S0, U, V, time_step0)


------------------------------------------------------------
-- project.
------------------------------------------------------------

fun {*[[f32, g], g],
     *[[f32, g], g]}
  project(i32 n_solver_steps,
          [[f32, g], g] U0,
          [[f32, g], g] V0) =
  let Div0 = project_top(U0, V0) in
  let P0 = lin_solve(n_solver_steps, Div0, 0, 1.0f32, 4.0f32) in
  let U1 = project_bottom(P0, U0, 1, 1, 0, -1, 0) in
  let V1 = project_bottom(P0, V0, 2, 0, 1, 0, -1) in
  {U1, V1}

fun [[f32, g], g]
  project_top([[f32, g], g] U0,
              [[f32, g], g] V0) =
      let one = (g*g+2*g+1)/(g+1) - g in
      reshape((g, g), 
        map(fn f32 (i32 ij) =>
              let i = ij / g in
              let j = ij % g in
              if inside(i, j, g)
              then project_top_inner(i, j, U0, V0)
              else project_top_outer(i/one, j/one, U0, V0)
           , iota(g * g)))

fun f32
  project_top_inner(i32 i,
                    i32 j,
                    [[f32, g], g] U0,
                    [[f32, g], g] V0) =
  unsafe (-0.5f32 * (U0[i + 1, j]
                     - U0[i - 1, j]
                     + V0[i, j + 1]
                     - V0[i, j - 1]) / f32(g))

fun f32
  project_top_outer(i32 i,
                    i32 j,
                    [[f32, g], g] U0,
                    [[f32, g], g] V0) =
  if in_outside_corner(i, j, g)
  then let {i1, j1, i2, j2} = corner_index_neighbors(i, j, g)
       in 0.5f32 * (project_top_outer_base(i1, j1, U0, V0)
                    + project_top_outer_base(i2, j2, U0, V0))
  else project_top_outer_base(i, j, U0, V0)

fun f32
  project_top_outer_base(i32 i,
                         i32 j,
                         [[f32, g], g] U0,
                         [[f32, g], g] V0) =
  let {i1, j1, f} = outermost_inner_index(i, j, g, 0)
  in project_top_inner(i1, j1, U0, V0)

fun *[[f32, g], g]
  project_bottom([[f32, g], g] P0,
                 [[f32, g], g] S0,
                 i32 b,
                 i32 i0d,
                 i32 j0d,
                 i32 i1d,
                 i32 j1d) =
      let one = (g*g+2*g+1)/(g+1) - g in
      reshape((g, g), 
        map(fn f32 (i32 ij) =>
          let i = ij / g in
          let j = ij % g in
          if inside(i, j, g)
          then project_bottom_inner(i, j, P0, S0, i0d, j0d, i1d, j1d)
          else project_bottom_outer(i/one, j/one, P0, S0,
                                    i0d/one, j0d/one, i1d/one, j1d/one, b/one)
           , iota(g * g)))

fun f32
  project_bottom_inner(i32 i,
                       i32 j,
                       [[f32, g], g] P0,
                       [[f32, g], g] S0,
                       i32 i0d,
                       i32 j0d,
                       i32 i1d,
                       i32 j1d) =
  unsafe (S0[i, j] - 0.5f32 * f32(g - 2)
          * (P0[i + i0d, j + j0d] - P0[i + i1d, j + j1d]))

fun f32
  project_bottom_outer(i32 i,
                       i32 j,
                       [[f32, g], g] P0,
                       [[f32, g], g] S0,
                       i32 i0d,
                       i32 j0d,
                       i32 i1d,
                       i32 j1d,
                       i32 b) =
  if in_outside_corner(i, j, g)
  then let {i1, j1, i2, j2} = corner_index_neighbors(i, j, g)
       in 0.5f32 * (project_bottom_outer_base(i1, j1, P0, S0, i0d, j0d, i1d, j1d, b)
                    + project_bottom_outer_base(i2, j2, P0, S0, i0d, j0d, i1d, j1d, b))
  else project_bottom_outer_base(i, j, P0, S0, i0d, j0d, i1d, j1d, b)

fun f32
  project_bottom_outer_base(i32 i,
                            i32 j,
                            [[f32, g], g] P0,
                            [[f32, g], g] S0,
                            i32 i0d,
                            i32 j0d,
                            i32 i1d,
                            i32 j1d,
                            i32 b) =
  let {i1, j1, f} = outermost_inner_index(i, j, g, b)
  in f * project_bottom_inner(i1, j1, P0, S0, i0d, j0d, i1d, j1d)


------------------------------------------------------------
-- Step functions.
------------------------------------------------------------

fun *[[f32, g], g]
  dens_step([[f32, g], g] D0,
            [[f32, g], g] U0,
            [[f32, g], g] V0,
            i32 n_solver_steps,
            f32 diffusion_rate,
            f32 time_step) =
  let D1 = diffuse(D0, 0, n_solver_steps, diffusion_rate, time_step) in
  let D2 = advect(D1, U0, V0, 0, time_step) in
  D2

fun {*[[f32, g], g],
     *[[f32, g], g]}
  vel_step([[f32, g], g] U0,
           [[f32, g], g] V0,
           i32 n_solver_steps,
           f32 viscosity,
           f32 time_step) =
  let U1 = diffuse(U0, 1, n_solver_steps, viscosity, time_step) in
  let V1 = diffuse(V0, 2, n_solver_steps, viscosity, time_step) in
  let {U2, V2} = project(n_solver_steps, U1, V1) in
  let U3 = advect(U2, U2, V2, 1, time_step) in
  let V3 = advect(V2, U2, V2, 2, time_step) in
  let {U4, V4} = project(n_solver_steps, U3, V3) in
  {U4, V4}

fun {*[[f32, g], g],
     *[[f32, g], g],
     *[[f32, g], g]}
     step([[f32, g], g] U0,
          [[f32, g], g] V0,
          [[f32, g], g] D0,
          i32 n_solver_steps,
          f32 time_step,
          f32 diffusion_rate,
          f32 viscosity) =
  let {U1, V1} = vel_step(U0, V0, n_solver_steps,
                          viscosity, time_step) in
  let D1 = dens_step(D0, U0, V0, n_solver_steps,
                     diffusion_rate, time_step) in
  {U1, V1, D1}


------------------------------------------------------------
-- Wrapper functions.
------------------------------------------------------------

fun {[[f32, g], g],
     [[f32, g], g],
     [[f32, g], g]}
  get_end_frame([[f32, g], g] U0,
                [[f32, g], g] V0,
                [[f32, g], g] D0,
                i32 n_steps,
                i32 n_solver_steps,
                f32 time_step,
                f32 diffusion_rate,
                f32 viscosity) =
  loop ({U0, V0, D0}) = for i < n_steps do
    step(U0, V0, D0, n_solver_steps, time_step,
         diffusion_rate, viscosity)
  in {U0, V0, D0}

fun {[[[f32, g], g], n_steps],
     [[[f32, g], g], n_steps],
     [[[f32, g], g], n_steps]}
  get_all_frames([[f32, g], g] U0,
                 [[f32, g], g] V0,
                 [[f32, g], g] D0,
                 i32 n_steps,
                 i32 n_solver_steps,
                 f32 time_step,
                 f32 diffusion_rate,
                 f32 viscosity) =
  let U_out = replicate(n_steps, U0) in
  let V_out = replicate(n_steps, V0) in
  let D_out = replicate(n_steps, D0) in
  loop ({U_out, V_out, D_out}) = for 1 <= i < n_steps do
    let {U0, V0, D0} = {U_out[i - 1], V_out[i - 1], D_out[i - 1]} in
    let {U1, V1, D1} = step(U0, V0, D0, n_solver_steps, time_step,
                            diffusion_rate, viscosity) in
    let U_out[i] = U1 in
    let V_out[i] = V1 in
    let D_out[i] = D1 in
    {U_out, V_out, D_out}
  in {U_out, V_out, D_out}
