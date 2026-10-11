# Layout of the global simulation state `pl` (see sim.S).
# Mirrored in C by ref/pl_state.h (checked with _Static_assert).
#
# Particle arrays are structure-of-arrays, float32 / int32, each allocated
# with PAD extra zeroed elements so vector loads may run past the end.

.set PL_N,        0     /* u32  particle count */
.set PL_K,        4     /* u32  type count (1..16) */
.set PL_W,        8     /* f32  world width */
.set PL_H,        12    /* f32  world height */
.set PL_COLS,     16    /* u32  grid columns */
.set PL_ROWS,     20    /* u32  grid rows */
.set PL_CW,       24    /* f32  cell width  (>= global max radius) */
.set PL_CH,       28    /* f32  cell height */
.set PL_ICW,      32    /* f32  1 / cell width */
.set PL_ICH,      36    /* f32  1 / cell height */
.set PL_DT,       40    /* f32  time step */
.set PL_FRIC,     44    /* f32  friction */
.set PL_FSCALE,   48    /* f32  force scale */
.set PL_CORE,     52    /* f32  core repulsion strength */
.set PL_CAP,      56    /* u32  allocated particle capacity */
.set PL_NTHREADS, 60    /* u32  worker threads (incl. caller) */

# current particle set (sorted by cell)
.set PL_X,        64
.set PL_Y,        72
.set PL_VX,       80
.set PL_VY,       88
.set PL_T,        96    /* i32 type */
.set PL_ID,       104   /* i32 original particle id */
# second set (sort destination), swapped with the first after each bin
.set PL_X2,       112
.set PL_Y2,       120
.set PL_VX2,      128
.set PL_VY2,      136
.set PL_T2,       144
.set PL_ID2,      152

.set PL_NX,       160   /* f32* integrated positions, input of the bin pass */
.set PL_NY,       168
.set PL_CELLID,   176   /* u32* cell of each particle (bin scratch) */
.set PL_CSTART,   184   /* u32* cell start offsets, ncells+1 */
.set PL_CCUR,     192   /* u32* scatter cursors, ncells+1 */
.set PL_RNG,      200   /* u64  splitmix64 state */
.set PL_NCELLS,   208   /* u32 */
.set PL_MAXR,     212   /* f32  global max radius */
.set PL_SIMD,     216   /* u32  1 = AVX2, 2 = AVX-512 */
.set PL_CORES,    220   /* f32  core * force_scale / 2 */
.set PL_DAMP,     224   /* f32  1 - friction*dt */
.set PL_CELLCAP,  228   /* u32  allocated cells */
.set PL_NBR,      232   /* ptr  per-cell neighbour ranges, NRANGE x {u32 c0, u32 c1, f32 sx, f32 sy} */
.set PL_KERNEL,   240   /* ptr  force kernel(c_begin, c_end) */
.set PL_CDIV,     248   /* u32  R: cell size = max radius / R, (2R+1)^2 neighbour cells */
.set PL_NRANGE,   252   /* u32  ranges per cell = 2 * (2R + 1) */

# rule tables, row-major, 16 floats per row (64 bytes): [ki*16 + kj]
.set PL_ATTR,     256
.set PL_MINR,     1280
.set PL_MAXRT,    2304
# derived per-pair tables used by the kernels (consecutive, 1024 bytes apart)
.set PL_TB0,      3328  /* maxr / (maxr - minr) */
.set PL_TIR,      4352  /* 1 / (maxr - minr) / 2 */
.set PL_TC1,      5376  /* core*force_scale / minr */
.set PL_TAS,      6400  /* -attraction * force_scale / 2 */
.set PL_SIZE,     7424

.set PAD,         32    /* padding elements per array */
.set MAXK,        16
.set MAXCDIV,     2
.set NBR_STRIDE,  160   /* up to 10 ranges * 16 bytes */
