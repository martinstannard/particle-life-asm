// Particle Life simulation core, AArch64 (ARMv8.0-A + NEON, tuned for the
// Cortex-A72 of the Raspberry Pi 4), GNU as. Port of src/sim.S.
//
// Per step (as on x86):
//   1. force kernel: for every cell, for every particle i in it, sum the force
//      from all particles in the (2R+1)^2 neighbouring cells (4 j per NEON
//      vector), then integrate and write the new position to nx/ny and the
//      new velocity in place.
//   2. bin: counting sort by cell into the second buffer set, swap the sets.
//
// Force law and the per-pair rewriting are those of src/sim.S (see its
// header): s = b0 - d*ir, core branch for s > 1, smoothstep attraction for
// 0 <= s <= 1, nothing for s <= 0. Differences of the NEON kernel:
//   * 1/d comes from FRSQRTE (8 bits) and two Newton steps with FRSQRTS
//     (NEWTON=1 keeps one step: ~16 bits, faster; see README);
//   * the four per-pair parameters are gathered per lane from one
//     interleaved table pl_ptab[ti][tj] = {b0, ir, c1, 4*as} (16 bytes, so
//     one LDR Q per lane and a 4x4 transpose) instead of x86's in-register
//     permutes: on NEON a 16-entry TBL over four registers per parameter
//     would cost more than the loads, and it handles every K <= 16 alike;
//   * the per-vector work is software pipelined over the stream of all
//     neighbour ranges of particle i: stage A (loads, distance, 1/d, gather)
//     of vector n+1 is interleaved with stage B (force, accumulate) of
//     vector n, so the long dependency chain of one vector overlaps the
//     other's (KPIPE=0 builds a plain loop for comparison);
//   * lanes past the end of a range get dx = dy = 0 (mask) and so add 0.

#ifndef NEWTON
#define NEWTON 2
#endif
#ifndef KPIPE
#define KPIPE 1
#endif

        .include "layout.inc"
        .include "macros.inc"

        .section .rodata
        .balign 16
// lane masks for 0..4 valid lanes
masktab:
        .long 0, 0, 0, 0
        .long -1, 0, 0, 0
        .long -1, -1, 0, 0
        .long -1, -1, -1, 0
        .long -1, -1, -1, -1
F_MAXR0:  .float 33.0
F_MAXR1:  .float 70.0

        .bss
        .balign 64
        .globl pl
pl:     .skip PL_SIZE
        .balign 64
        .globl pl_ptab
pl_ptab: .skip 16 * 16 * 16             // [ti][tj] {b0, ir, c1, 4*as}

        .text

// ---------------------------------------------------------------- RNG
// xd = next splitmix64 value of pl.rng; xa, xb clobbered
.macro RNG xd, xa, xb
        ADR_L   \xb, pl
        ldr     \xd, [\xb, #PL_RNG]
        MOV64   \xa, 0x9E3779B97F4A7C15
        add     \xd, \xd, \xa
        str     \xd, [\xb, #PL_RNG]
        eor     \xd, \xd, \xd, lsr #30
        MOV64   \xa, 0xBF58476D1CE4E5B9
        mul     \xd, \xd, \xa
        eor     \xd, \xd, \xd, lsr #27
        MOV64   \xa, 0x94D049BB133111EB
        mul     \xd, \xd, \xa
        eor     \xd, \xd, \xd, lsr #31
.endm

// s wrapped into [0, e) by one step, as the x86 WRAP (a NaN gets e added)
.macro WRAP s, e
        fcmp    \s, #0.0
        b.ge    1f
        fadd    \s, \s, \e
        b       2f
1:      fcmp    \s, \e
        b.lt    2f
        fsub    \s, \s, \e
2:
.endm

// u64 pl_rng_u64(void). Clobbers x1, x2 only.
        .globl pl_rng_u64
        .type pl_rng_u64, %function
pl_rng_u64:
        RNG     x0, x1, x2
        ret

// s0 = fma(b - a, u, a) for a = s0, b = s1, u uniform in [0,1) with 24
// random bits. Clobbers x0-x2, v1-v3.
        .globl pl_rng_range
        .type pl_rng_range, %function
pl_rng_range:
        fsub    s3, s1, s0
        fmov    s2, s0
        RNG     x0, x1, x2
        lsr     x0, x0, #40
        ucvtf   s0, x0
        movz    w1, #0x3380, lsl #16            // 2^-24
        fmov    s1, w1
        fmul    s0, s0, s1
        fmadd   s0, s3, s0, s2
        ret

// ---------------------------------------------------------------- alloc
// int pl_alloc(u32 n): (re)allocate all particle arrays for n particles.
        .globl pl_alloc
        .type pl_alloc, %function
pl_alloc:
        ENTER
        mov     w19, w0                         // n
        mov     x20, #PL_X                      // array slot
        ADR_L   x21, pl
1:      ldr     x0, [x21, x20]
        bl      free
        add     w0, w19, #PAD
        mov     x1, #4
        bl      calloc
        str     x0, [x21, x20]
        cbz     x0, 9f
        add     x20, x20, #8
        cmp     x20, #PL_CELLID
        b.ls    1b
        str     w19, [x21, #PL_N]
        str     w19, [x21, #PL_CAP]
        mov     w0, #0
        LEAVE
9:      mov     w0, #-1
        LEAVE

// ---------------------------------------------------------------- rules
// void pl_random_rules(void): for every (i,j) < K draw attraction in [-1,1),
// minr in [12,24), maxr in [33,70), then rebuild the tables and the grid.
        .globl pl_random_rules
        .type pl_random_rules, %function
pl_random_rules:
        ENTER
        ADR_L   x19, pl
        mov     w20, #0                         // i
1:      ldr     w9, [x19, #PL_K]
        cmp     w20, w9
        b.hs    4f
        mov     w21, #0                         // j
2:      ldr     w9, [x19, #PL_K]
        cmp     w21, w9
        b.hs    3f
        add     w22, w21, w20, lsl #4           // i*16 + j
        fmov    s0, #-1.0
        fmov    s1, #1.0
        bl      pl_rng_range
        add     x9, x19, #PL_ATTR
        str     s0, [x9, x22, lsl #2]
        fmov    s0, #12.0
        fmov    s1, #24.0
        bl      pl_rng_range
        ADDL    x9, x19, PL_MINR
        str     s0, [x9, x22, lsl #2]
        LDRS    s0, F_MAXR0, x9
        LDRS    s1, F_MAXR1, x9
        bl      pl_rng_range
        ADDL    x9, x19, PL_MAXRT
        str     s0, [x9, x22, lsl #2]
        add     w21, w21, #1
        b       2b
3:      add     w20, w20, #1
        b       1b
4:      UNFRAME
        b       pl_update_tables

// ---------------------------------------------------------------- tables
// void pl_update_tables(void): derived per-pair tables (and the kernel's
// interleaved pl_ptab), damping, grid geometry, cell arrays, neighbour-range
// table and kernel selection.
        .globl pl_update_tables
        .type pl_update_tables, %function
pl_update_tables:
        ENTER
        ADR_L   x19, pl
        ldr     s0, [x19, #PL_CORE]
        ldr     s1, [x19, #PL_FSCALE]
        fmul    s16, s0, s1                     // core_s
        fmov    s2, #0.5
        fmul    s0, s16, s2
        str     s0, [x19, #PL_CORES]            // core_s / 2
        ldr     s0, [x19, #PL_FRIC]
        ldr     s1, [x19, #PL_DT]
        fmul    s0, s0, s1
        fmov    s1, #1.0
        fsub    s0, s1, s0
        str     s0, [x19, #PL_DAMP]

        ldr     s18, [x19, #PL_FSCALE]
        fmov    s19, #-0.5
        fmov    s20, #4.0
        movi    d17, #0                         // global max radius
        add     x20, x19, #PL_ATTR
        ADDL    x21, x19, PL_MINR
        ADDL    x22, x19, PL_MAXRT
        ADDL    x23, x19, PL_TB0
        ADDL    x24, x19, PL_TIR
        ADDL    x25, x19, PL_TC1
        ADDL    x26, x19, PL_TAS
        ADR_L   x27, pl_ptab
        ldr     w12, [x19, #PL_K]
        mov     w10, #0                         // i
1:      cmp     w10, w12
        b.hs    4f
        mov     w11, #0                         // j
2:      cmp     w11, w12
        b.hs    3f
        add     w9, w11, w10, lsl #4            // idx
        ldr     s1, [x21, x9, lsl #2]           // minr
        ldr     s2, [x22, x9, lsl #2]           // maxr
        fmax    s17, s17, s2
        fsub    s3, s2, s1
        fmov    s4, #1.0
        fdiv    s3, s4, s3                      // ir
        fmul    s4, s2, s3                      // b0 = maxr * ir
        str     s4, [x23, x9, lsl #2]
        fmov    s5, #0.5
        fmul    s5, s3, s5
        str     s5, [x24, x9, lsl #2]           // ir / 2
        fdiv    s5, s16, s1                     // c1 = core_s / minr
        str     s5, [x25, x9, lsl #2]
        ldr     s6, [x20, x9, lsl #2]
        fmul    s6, s6, s18
        fmul    s6, s6, s19
        str     s6, [x26, x9, lsl #2]           // -attraction * force_scale / 2
        fmul    s6, s6, s20                     // 4 * that (exact)
        add     x13, x27, x9, lsl #4
        stp     s4, s3, [x13]                   // {b0, ir,
        stp     s5, s6, [x13, #8]               //  c1, 4 as}
        add     w11, w11, #1
        b       2b
3:      add     w10, w10, #1
        b       1b
4:      str     s17, [x19, #PL_MAXR]

        // grid: cell >= maxr / R, at least 2R+1 cells per axis
        ldr     w9, [x19, #PL_CDIV]
        sub     w10, w9, #1
        cmp     w10, #MAXCDIV - 1
        b.ls    41f
        mov     w9, #1
        str     w9, [x19, #PL_CDIV]
41:     lsl     w10, w9, #2
        add     w10, w10, #2
        str     w10, [x19, #PL_NRANGE]          // 4R + 2
        scvtf   s1, w9
        fdiv    s17, s17, s1                    // min cell size
        lsl     w11, w9, #1
        add     w11, w11, #1                    // min cells per axis
        fmov    s3, #1.0
        ldr     s0, [x19, #PL_W]
        fdiv    s1, s0, s17
        fcvtzs  w12, s1
        cmp     w12, w11
        csel    w12, w11, w12, lt
        str     w12, [x19, #PL_COLS]
        scvtf   s1, w12
        fdiv    s2, s0, s1
        str     s2, [x19, #PL_CW]
        fdiv    s4, s3, s2
        str     s4, [x19, #PL_ICW]
        ldr     s0, [x19, #PL_H]
        fdiv    s1, s0, s17
        fcvtzs  w13, s1
        cmp     w13, w11
        csel    w13, w11, w13, lt
        str     w13, [x19, #PL_ROWS]
        scvtf   s1, w13
        fdiv    s2, s0, s1
        str     s2, [x19, #PL_CH]
        fdiv    s4, s3, s2
        str     s4, [x19, #PL_ICH]
        mul     w13, w13, w12
        str     w13, [x19, #PL_NCELLS]

        ldr     w9, [x19, #PL_CELLCAP]
        cmp     w13, w9
        b.ls    5f
        str     w13, [x19, #PL_CELLCAP]
        ldr     x0, [x19, #PL_CSTART]
        bl      free
        ldr     x0, [x19, #PL_CCUR]
        bl      free
        ldr     x0, [x19, #PL_NBR]
        bl      free
        ldr     w0, [x19, #PL_CELLCAP]
        add     w0, w0, #1
        mov     x1, #4
        bl      calloc
        str     x0, [x19, #PL_CSTART]
        ldr     w0, [x19, #PL_CELLCAP]
        add     w0, w0, #1
        mov     x1, #4
        bl      calloc
        str     x0, [x19, #PL_CCUR]
        ldr     w0, [x19, #PL_CELLCAP]
        mov     x1, #NBR_STRIDE
        bl      calloc
        str     x0, [x19, #PL_NBR]

        // neighbour ranges: per cell, per neighbour row ry = cy-R..cy+R, two
        // entries {first cell, last cell + 1, shift x, shift y} covering
        // columns cx-R..cx+R; the second is empty unless the row wraps in x.
5:      ldr     x14, [x19, #PL_NBR]
        ldr     w10, [x19, #PL_COLS]
        ldr     w11, [x19, #PL_ROWS]
        ldr     w12, [x19, #PL_CDIV]
        ldr     w15, [x19, #PL_W]               // bits of +W
        ldr     w16, [x19, #PL_H]               // bits of +H
        mov     w8, #0                          // cy
6:      cmp     w8, w11
        b.hs    12f
        mov     w9, #0                          // cx
7:      cmp     w9, w10
        b.hs    11f
        mov     x2, x14
        neg     w3, w12                         // d = -R
8:      add     w0, w8, w3                      // ry
        mov     w4, #0                          // sy bits
        tbz     w0, #31, 81f
        add     w0, w0, w11
        eor     w4, w16, #0x80000000            // -H
        b       82f
81:     cmp     w0, w11
        b.lo    82f
        sub     w0, w0, w11
        mov     w4, w16                         // +H
82:     mul     w0, w0, w10                     // base = ry * cols
        str     w4, [x2, #12]
        str     w4, [x2, #28]
        sub     w5, w9, w12                     // lo = cx - R
        add     w6, w9, w12                     // hi = cx + R
        tbz     w5, #31, 83f
        // lo < 0: [base, base+hi+1) shift 0; [base+cols+lo, base+cols) shift -W
        str     w0, [x2]
        add     w7, w0, w6
        add     w7, w7, #1
        str     w7, [x2, #4]
        str     wzr, [x2, #8]
        add     w7, w0, w10
        add     w7, w7, w5
        str     w7, [x2, #16]
        add     w7, w0, w10
        str     w7, [x2, #20]
        eor     w7, w15, #0x80000000
        str     w7, [x2, #24]
        b       85f
83:     cmp     w6, w10
        b.lo    84f
        // hi >= cols: [base+lo, base+cols) shift 0; [base, base+hi-cols+1) shift +W
        add     w7, w0, w5
        str     w7, [x2]
        add     w7, w0, w10
        str     w7, [x2, #4]
        str     wzr, [x2, #8]
        str     w0, [x2, #16]
        add     w7, w0, w6
        add     w7, w7, #1
        sub     w7, w7, w10
        str     w7, [x2, #20]
        str     w15, [x2, #24]
        b       85f
84:     // interior: [base+lo, base+hi+1) shift 0, second entry empty
        add     w7, w0, w5
        str     w7, [x2]
        add     w7, w0, w6
        add     w7, w7, #1
        str     w7, [x2, #4]
        str     wzr, [x2, #8]
        str     xzr, [x2, #16]
        str     xzr, [x2, #24]
85:     add     x2, x2, #32
        add     w3, w3, #1
        cmp     w3, w12
        b.le    8b
        add     x14, x14, #NBR_STRIDE
        add     w9, w9, #1
        b       7b
11:     add     w8, w8, #1
        b       6b

        // one NEON kernel for every K
12:     ADR_L   x0, pl_kernel_neon
        str     x0, [x19, #PL_KERNEL]
        LEAVE

// ---------------------------------------------------------------- particles
// void pl_random_particles(void): uniform positions in the world, zero
// velocity, uniform type in [0,K), ids 0..N-1; then bin.
        .globl pl_random_particles
        .type pl_random_particles, %function
pl_random_particles:
        ENTER
        ADR_L   x19, pl
        mov     w20, #0
1:      ldr     w9, [x19, #PL_N]
        cmp     w20, w9
        b.hs    2f
        fmov    s0, wzr
        ldr     s1, [x19, #PL_W]
        bl      pl_rng_range
        ldr     x9, [x19, #PL_NX]
        str     s0, [x9, x20, lsl #2]
        fmov    s0, wzr
        ldr     s1, [x19, #PL_H]
        bl      pl_rng_range
        ldr     x9, [x19, #PL_NY]
        str     s0, [x9, x20, lsl #2]
        bl      pl_rng_u64
        lsr     x0, x0, #32
        ldr     w9, [x19, #PL_K]
        mul     x0, x0, x9
        lsr     x0, x0, #32
        ldr     x9, [x19, #PL_T]
        str     w0, [x9, x20, lsl #2]
        ldr     x9, [x19, #PL_ID]
        str     w20, [x9, x20, lsl #2]
        ldr     x9, [x19, #PL_VX]
        str     wzr, [x9, x20, lsl #2]
        ldr     x9, [x19, #PL_VY]
        str     wzr, [x9, x20, lsl #2]
        add     w20, w20, #1
        b       1b
2:      UNFRAME
        b       pl_bin

// ---------------------------------------------------------------- bin
// Cell ids of particles [x14, w11) (index registers as words) from
// nx/ny into cellid, 4 at a time (the arrays are padded). x19 = pl.
// Clobbers x8-x10, x12-x14, v0, v1, v4-v7, v16.
.macro CELLIDS
        ldr     x8, [x19, #PL_NX]
        ldr     x9, [x19, #PL_NY]
        ldr     x10, [x19, #PL_CELLID]
        add     x8, x8, x14, lsl #2
        add     x9, x9, x14, lsl #2
        add     x10, x10, x14, lsl #2
        add     x12, x19, #PL_ICW
        ld1r    {v4.4s}, [x12]
        add     x12, x19, #PL_ICH
        ld1r    {v5.4s}, [x12]
        ldr     w12, [x19, #PL_COLS]
        dup     v6.4s, w12
        sub     w12, w12, #1
        dup     v7.4s, w12                      // cols - 1
        ldr     w12, [x19, #PL_ROWS]
        sub     w12, w12, #1
        dup     v16.4s, w12                     // rows - 1
1:      cmp     w14, w11
        b.hs    2f
        ld1     {v0.4s}, [x8], #16
        ld1     {v1.4s}, [x9], #16
        fmul    v0.4s, v0.4s, v4.4s
        fcvtzs  v0.4s, v0.4s
        umin    v0.4s, v0.4s, v7.4s             // unsigned clamp
        fmul    v1.4s, v1.4s, v5.4s
        fcvtzs  v1.4s, v1.4s
        umin    v1.4s, v1.4s, v16.4s
        mla     v0.4s, v1.4s, v6.4s             // cx + cy * cols
        st1     {v0.4s}, [x10], #16
        add     w14, w14, #4
        b       1b
2:
.endm

// scatter particles [w14, w11) of the current set to the second set at the
// destinations in cellid. x19 = pl. Clobbers x0-x10, x12-x17.
.macro SCATTER6
        ldr     x10, [x19, #PL_CELLID]
        ldr     x0, [x19, #PL_NX]
        ldr     x1, [x19, #PL_NY]
        ldr     x2, [x19, #PL_VX]
        ldr     x3, [x19, #PL_VY]
        ldr     x4, [x19, #PL_T]
        ldr     x5, [x19, #PL_ID]
        ldr     x6, [x19, #PL_X2]
        ldr     x7, [x19, #PL_Y2]
        ldr     x8, [x19, #PL_VX2]
        ldr     x9, [x19, #PL_VY2]
        ldr     x12, [x19, #PL_T2]
        ldr     x13, [x19, #PL_ID2]
1:      cmp     w14, w11
        b.hs    2f
        ldr     w15, [x10, x14, lsl #2]         // destination
        ldr     w16, [x0, x14, lsl #2]
        str     w16, [x6, x15, lsl #2]
        ldr     w16, [x1, x14, lsl #2]
        str     w16, [x7, x15, lsl #2]
        ldr     w16, [x2, x14, lsl #2]
        str     w16, [x8, x15, lsl #2]
        ldr     w16, [x3, x14, lsl #2]
        str     w16, [x9, x15, lsl #2]
        ldr     w16, [x4, x14, lsl #2]
        str     w16, [x12, x15, lsl #2]
        ldr     w16, [x5, x14, lsl #2]
        str     w16, [x13, x15, lsl #2]
        add     w14, w14, #1
        b       1b
2:
.endm

// void pl_bin(void): stable counting sort of the current set by the cell of
// (nx, ny) into the second set, then swap the sets. Run lengths of equal
// cells are counted in registers (particles are nearly cell-ordered).
        .globl pl_bin
        .type pl_bin, %function
pl_bin:
        ENTER
        ADR_L   x19, pl
        ldr     x0, [x19, #PL_CSTART]
        ldr     w2, [x19, #PL_NCELLS]
        add     w2, w2, #1
        lsl     x2, x2, #2
        mov     w1, #0
        bl      memset

        ldr     w11, [x19, #PL_N]
        mov     w14, #0
        CELLIDS

        // run-length counts into cstart[c+1]
        ldr     x10, [x19, #PL_CELLID]
        ldr     x17, [x19, #PL_CSTART]
        cbz     w11, 5f
        ldr     w12, [x10]                      // current cell
        mov     w13, #0                         // run length
        mov     w14, #0
3:      ldr     w15, [x10, x14, lsl #2]
        cmp     w15, w12
        b.eq    4f
        add     x16, x17, x12, lsl #2
        ldr     w9, [x16, #4]
        add     w9, w9, w13
        str     w9, [x16, #4]
        mov     w12, w15
        mov     w13, #0
4:      add     w13, w13, #1
        add     w14, w14, #1
        cmp     w14, w11
        b.lo    3b
        add     x16, x17, x12, lsl #2
        ldr     w9, [x16, #4]
        add     w9, w9, w13
        str     w9, [x16, #4]

        // prefix sum -> starts, copy to cursors
5:      ldr     x16, [x19, #PL_CCUR]
        ldr     w12, [x19, #PL_NCELLS]
        mov     w13, #0
        mov     w14, #0
6:      ldr     w9, [x17, x14, lsl #2]
        add     w13, w13, w9
        str     w13, [x17, x14, lsl #2]
        str     w13, [x16, x14, lsl #2]
        add     w14, w14, #1
        cmp     w14, w12
        b.ls    6b

        // destination index per particle (overwrites cellid)
        cbz     w11, 9f
        ldr     w12, [x10]                      // current cell
        ldr     w13, [x16, x12, lsl #2]         // its cursor
        mov     w14, #0
7:      ldr     w15, [x10, x14, lsl #2]
        cmp     w15, w12
        b.eq    8f
        str     w13, [x16, x12, lsl #2]
        mov     w12, w15
        ldr     w13, [x16, x12, lsl #2]
8:      str     w13, [x10, x14, lsl #2]
        add     w13, w13, #1
        add     w14, w14, #1
        cmp     w14, w11
        b.lo    7b
        str     w13, [x16, x12, lsl #2]

9:      mov     w14, #0
        SCATTER6
        UNFRAME
        b       pl_swap_sets

// void pl_swap_sets(void): exchange the current and the second particle set
        .globl pl_swap_sets
        .type pl_swap_sets, %function
pl_swap_sets:
        ADR_L   x0, pl
        add     x1, x0, #PL_X
        add     x2, x0, #PL_X2
        ldp     q0, q1, [x1]
        ldr     q2, [x1, #32]
        ldp     q3, q4, [x2]
        ldr     q5, [x2, #32]
        stp     q3, q4, [x1]
        str     q5, [x1, #32]
        stp     q0, q1, [x2]
        str     q2, [x2, #32]
        ret

// ---------------------------------------------------------------- parallel bin
// The same stable counting sort split over T threads (called by threads.S
// between barriers): particle chunk t = [lo, hi) with 16-aligned bounds,
// per-thread histograms hist[t][c], cell blocks for the prefix sum. The
// resulting order is identical to pl_bin.

        .globl pbin_hist, pbin_cap
        .bss
        .balign 8
pbin_hist:      .skip 8                 // u32 [T][ncells+1]
pbin_cap:       .skip 4                 // allocated u32 entries
        .balign 64
pbin_blocksum:  .skip 4 * 64
        .text

// (w0, w1) = bounds [lo, hi) of part w0 of w1 items, lo 16-aligned.
// Clobbers x9-x12.
pbounds:
        ADR_L   x9, pl
        ldr     w9, [x9, #PL_NTHREADS]
        mov     w10, w1                         // n
        umull   x11, w1, w0
        udiv    x11, x11, x9
        and     x11, x11, #0xfffffffffffffff0   // lo
        add     w12, w0, #1
        cmp     w12, w9
        b.hs    1f
        umull   x12, w10, w12
        udiv    x12, x12, x9
        and     x1, x12, #0xfffffffffffffff0
        mov     w0, w11
        ret
1:      mov     w1, w10
        mov     w0, w11
        ret

// x0 = hist[w0] (row of thread w0). Clobbers x9, x10.
.macro HISTROW t
        ldr     w9, [x19, #PL_NCELLS]
        add     w9, w9, #1
        umull   x9, w9, \t
        LDRS    x10, pbin_hist, x10
        add     x0, x10, x9, lsl #2
.endm

// phase 1: cell ids of chunk t, run-length counts into hist[t]
        .globl pl_pbin_count
        .type pl_pbin_count, %function
pl_pbin_count:
        ENTER
        ADR_L   x19, pl
        mov     w20, w0
        ldr     w1, [x19, #PL_N]
        bl      pbounds
        mov     w21, w0                         // lo
        mov     w22, w1                         // hi
        HISTROW w20
        mov     x23, x0
        ldr     w2, [x19, #PL_NCELLS]
        add     w2, w2, #1
        lsl     x2, x2, #2
        mov     w1, #0
        bl      memset
        mov     w14, w21
        mov     w11, w22
        CELLIDS
        cmp     w21, w22
        b.hs    5f
        ldr     x10, [x19, #PL_CELLID]
        mov     w14, w21
        ldr     w12, [x10, x14, lsl #2]         // current cell
        mov     w13, #0
3:      ldr     w15, [x10, x14, lsl #2]
        cmp     w15, w12
        b.eq    4f
        ldr     w9, [x23, x12, lsl #2]
        add     w9, w9, w13
        str     w9, [x23, x12, lsl #2]
        mov     w12, w15
        mov     w13, #0
4:      add     w13, w13, #1
        add     w14, w14, #1
        cmp     w14, w22
        b.lo    3b
        ldr     w9, [x23, x12, lsl #2]
        add     w9, w9, w13
        str     w9, [x23, x12, lsl #2]
5:      LEAVE

// phase 2: total count of cell block t over all threads
        .globl pl_pbin_sum
        .type pl_pbin_sum, %function
pl_pbin_sum:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        mov     w13, w0                         // t
        ADR_L   x14, pl
        ldr     w1, [x14, #PL_NCELLS]
        bl      pbounds                         // [w0, w1)
        ldr     w15, [x14, #PL_NCELLS]
        add     w15, w15, #1                    // hist stride
        ldr     w16, [x14, #PL_NTHREADS]
        LDRS    x17, pbin_hist, x17
        mov     w9, #0                          // sum
        mov     w10, #0                         // t'
1:      cmp     w10, w16
        b.hs    3f
        mov     w11, w0
2:      cmp     w11, w1
        b.hs    21f
        ldr     w12, [x17, x11, lsl #2]
        add     w9, w9, w12
        add     w11, w11, #1
        b       2b
21:     add     x17, x17, x15, lsl #2
        add     w10, w10, #1
        b       1b
3:      ADR_L   x12, pbin_blocksum
        str     w9, [x12, x13, lsl #2]
        ldp     x29, x30, [sp], #16
        ret

// phase 3: cell starts and per-thread cursors for cell block t
        .globl pl_pbin_offsets
        .type pl_pbin_offsets, %function
pl_pbin_offsets:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        mov     w13, w0                         // t
        ADR_L   x14, pl
        ldr     w1, [x14, #PL_NCELLS]
        bl      pbounds                         // [w0, w1)
        ADR_L   x12, pbin_blocksum
        mov     w9, #0                          // base
        mov     w10, #0
1:      cmp     w10, w13
        b.hs    2f
        ldr     w11, [x12, x10, lsl #2]
        add     w9, w9, w11
        add     w10, w10, #1
        b       1b
2:      ldr     w15, [x14, #PL_NCELLS]
        add     w15, w15, #1                    // stride
        ldr     w16, [x14, #PL_NTHREADS]
        LDRS    x17, pbin_hist, x17
        ldr     x12, [x14, #PL_CSTART]
        mov     w11, w0                         // c
3:      cmp     w11, w1
        b.hs    5f
        str     w9, [x12, x11, lsl #2]
        add     x2, x17, x11, lsl #2
        mov     w10, #0
4:      ldr     w3, [x2]
        str     w9, [x2]
        add     w9, w9, w3
        add     x2, x2, x15, lsl #2
        add     w10, w10, #1
        cmp     w10, w16
        b.lo    4b
        add     w11, w11, #1
        b       3b
5:      add     w10, w13, #1
        cmp     w10, w16
        b.ne    6f
        ldr     w11, [x14, #PL_NCELLS]
        ldr     w10, [x14, #PL_N]
        str     w10, [x12, x11, lsl #2]
6:      ldp     x29, x30, [sp], #16
        ret

// phase 4: destinations of chunk t from its cursors, then scatter it
        .globl pl_pbin_scatter
        .type pl_pbin_scatter, %function
pl_pbin_scatter:
        ENTER
        ADR_L   x19, pl
        mov     w20, w0
        ldr     w1, [x19, #PL_N]
        bl      pbounds
        mov     w21, w0                         // lo
        mov     w22, w1                         // hi
        cmp     w21, w22
        b.hs    9f
        HISTROW w20
        mov     x23, x0                         // cursors of thread t
        ldr     x10, [x19, #PL_CELLID]
        mov     w14, w21
        ldr     w12, [x10, x14, lsl #2]
        ldr     w13, [x23, x12, lsl #2]
1:      ldr     w15, [x10, x14, lsl #2]
        cmp     w15, w12
        b.eq    2f
        str     w13, [x23, x12, lsl #2]
        mov     w12, w15
        ldr     w13, [x23, x12, lsl #2]
2:      str     w13, [x10, x14, lsl #2]
        add     w13, w13, #1
        add     w14, w14, #1
        cmp     w14, w22
        b.lo    1b
        str     w13, [x23, x12, lsl #2]
        mov     w14, w21
        mov     w11, w22
        SCATTER6
9:      LEAVE

// ---------------------------------------------------------------- kernel
// void pl_kernel_neon(u32 c_begin, u32 c_end)
//
// General registers:
//   x19 pl, w20 cell, w21 c_end, w22 i, w4 i_end, x23 pl_ptab, x24 x[],
//   x25 y[], x26 type[], x27 pl_ptab row of type(i), x28 masktab;
//   stream: x6 next range entry, x14 end of the range entries, w5 lanes left
//   in the current range, x1/x2/x3 x/y/type pointers of the next vector,
//   w10-w13 its four types.
// NEON registers:
//   v0/v1 xi - sx, yi - sy (broadcast), v2/v3 fx/fy accumulators, v4 1.0,
//   v5 0.0, v6 1.5, v7 lane mask of the vector entering stage A,
//   v14 -core*force_scale, v15 {xi, yi}, v8-v11 stage B temporaries;
//   two register sets (P, Q) of {4 gathered table entries, dx, dy, d, 1/d,
//   temporary} alternate between the stages.
// Frame: [sp] up to 10 ranges {u32 j0, u32 j1, f32 sx, f32 sy}, then d8-d15,
// then the caller's FPCR at [sp + 224].

.set KFRAME, 240

// next vector of the stream for stage A, or branch to \done when every
// range of particle i is used up
.macro NEXTVEC done
        cmp     w5, #0
        b.gt    2f
1:      cmp     x6, x14
        b.hs    \done
        ldp     w9, w10, [x6]
        ldr     d8, [x6, #8]
        add     x6, x6, #16
        subs    w5, w10, w9
        b.le    1b
        add     x1, x24, x9, lsl #2
        add     x2, x25, x9, lsl #2
        add     x3, x26, x9, lsl #2
        fsub    v8.2s, v15.2s, v8.2s
        dup     v0.4s, v8.s[0]
        dup     v1.4s, v8.s[1]
2:      mov     w9, #4
        cmp     w5, #4
        csel    w9, w5, w9, lt
        ldr     q7, [x28, x9, lsl #4]
        sub     w5, w5, #4
.endm

// stage A in pieces (register set a0..a3 = gather destinations, X, Y, D, I, H)
.macro A1 a0, a1, a2, a3, X, Y, D, I, H
        ldr     q\X, [x1], #16
        ldr     q\Y, [x2], #16
.endm
.macro A2 a0, a1, a2, a3, X, Y, D, I, H
        ldp     w10, w11, [x3], #8
        ldp     w12, w13, [x3], #8
.endm
.macro A3 a0, a1, a2, a3, X, Y, D, I, H
        ldr     q\a0, [x27, w10, uxtw #4]       // {b0, ir, c1, 4as}[type j]
        ldr     q\a1, [x27, w11, uxtw #4]
.endm
.macro A4 a0, a1, a2, a3, X, Y, D, I, H
        ldr     q\a2, [x27, w12, uxtw #4]
        ldr     q\a3, [x27, w13, uxtw #4]
.endm
.macro A5 a0, a1, a2, a3, X, Y, D, I, H
        fsub    v\X\().4s, v0.4s, v\X\().4s     // -dx
        fsub    v\Y\().4s, v1.4s, v\Y\().4s     // -dy
.endm
.macro A6 a0, a1, a2, a3, X, Y, D, I, H
        and     v\X\().16b, v\X\().16b, v7.16b  // 0 in lanes past the range
        and     v\Y\().16b, v\Y\().16b, v7.16b
.endm
.macro A7 a0, a1, a2, a3, X, Y, D, I, H
        fmul    v\D\().4s, v\X\().4s, v\X\().4s
        fmla    v\D\().4s, v\Y\().4s, v\Y\().4s // d^2
.endm
.macro A8 a0, a1, a2, a3, X, Y, D, I, H
        orr     v\D\().4s, #1                   // d^2 > 0 (1 ulp at most)
        frsqrte v\I\().4s, v\D\().4s            // r0 ~ 1/d, 8 bits
.endm
.macro A9 a0, a1, a2, a3, X, Y, D, I, H
        fmul    v\H\().4s, v\D\().4s, v\I\().4s
        frsqrts v\H\().4s, v\H\().4s, v\I\().4s // (3 - d^2 r0^2) / 2
.endm
.macro A10 a0, a1, a2, a3, X, Y, D, I, H
        fmul    v\I\().4s, v\I\().4s, v\H\().4s // r1, ~16 bits
.if NEWTON > 1
        fmul    v\H\().4s, v\D\().4s, v\I\().4s
.endif
.endm
.macro A11 a0, a1, a2, a3, X, Y, D, I, H
.if NEWTON > 1
        frsqrts v\H\().4s, v\H\().4s, v\I\().4s
        fmul    v\I\().4s, v\I\().4s, v\H\().4s // r2 = 1/d
.endif
.endm
.macro A12 a0, a1, a2, a3, X, Y, D, I, H
        fmul    v\D\().4s, v\D\().4s, v\I\().4s // d = d^2 / d
.endm

// stage B in pieces (set b0..b3 = gathered entries, X, Y, D, I)
.macro B1 b0, b1, b2, b3, X, Y, D, I
        trn1    v8.4s, v\b0\().4s, v\b1\().4s
        trn2    v9.4s, v\b0\().4s, v\b1\().4s
.endm
.macro B2 b0, b1, b2, b3, X, Y, D, I
        trn1    v10.4s, v\b2\().4s, v\b3\().4s
        trn2    v11.4s, v\b2\().4s, v\b3\().4s
.endm
.macro B3 b0, b1, b2, b3, X, Y, D, I
        trn1    v\b0\().2d, v8.2d, v10.2d       // b0
        trn1    v\b2\().2d, v9.2d, v11.2d       // ir
.endm
.macro B4 b0, b1, b2, b3, X, Y, D, I
        trn2    v\b1\().2d, v8.2d, v10.2d       // c1
        trn2    v\b3\().2d, v9.2d, v11.2d       // 4 as
.endm
.macro B5 b0, b1, b2, b3, X, Y, D, I
        fmls    v\b0\().4s, v\D\().4s, v\b2\().4s // s = b0 - d ir
.endm
.macro B6 b0, b1, b2, b3, X, Y, D, I
        fmax    v8.4s, v\b0\().4s, v5.4s        // sc (lanes with s > 1 are discarded)
.endm
.macro B7 b0, b1, b2, b3, X, Y, D, I
        fmul    v9.4s, v8.4s, v8.4s             // sc^2
.endm
.macro B8 b0, b1, b2, b3, X, Y, D, I
        fmul    v8.4s, v9.4s, v8.4s             // sc^3
.endm
.macro B9 b0, b1, b2, b3, X, Y, D, I
        fmls    v8.4s, v9.4s, v6.s[0]           // sc^3 - 1.5 sc^2
.endm
.macro B10 b0, b1, b2, b3, X, Y, D, I
        fcmgt   v\b0\().4s, v\b0\().4s, v4.4s   // s > 1  <=>  d < minr
.endm
.macro B11 b0, b1, b2, b3, X, Y, D, I
        fmul    v\b3\().4s, v\b3\().4s, v8.4s   // h = 4as (sc^3 - 1.5 sc^2)
.endm
.macro B12 b0, b1, b2, b3, X, Y, D, I
        and     v\b1\().16b, v\b1\().16b, v\b0\().16b // c1 in core lanes, else 0
.endm
.macro B13 b0, b1, b2, b3, X, Y, D, I
        bsl     v\b0\().16b, v14.16b, v\b3\().16b // -core_s in core lanes, else h
.endm
.macro B14 b0, b1, b2, b3, X, Y, D, I
        fmla    v\b1\().4s, v\b0\().4s, v\I\().4s // g = force / d
.endm
.macro B15 b0, b1, b2, b3, X, Y, D, I
        fmls    v2.4s, v\b1\().4s, v\X\().4s    // F += g * (xj - xi)
        fmls    v3.4s, v\b1\().4s, v\Y\().4s
.endm

#define SETP 16, 17, 18, 19, 20, 21, 22, 23, 24
#define SETQ 25, 26, 27, 28, 29, 30, 31, 12, 13
#define BSETP 16, 17, 18, 19, 20, 21, 22, 23
#define BSETQ 25, 26, 27, 28, 29, 30, 31, 12

.macro STAGE_A s:vararg
        A1 \s
        A2 \s
        A3 \s
        A4 \s
        A5 \s
        A6 \s
        A7 \s
        A8 \s
        A9 \s
        A10 \s
        A11 \s
        A12 \s
.endm
.macro STAGE_B s:vararg
        B1 \s
        B2 \s
        B3 \s
        B4 \s
        B5 \s
        B6 \s
        B7 \s
        B8 \s
        B9 \s
        B10 \s
        B11 \s
        B12 \s
        B13 \s
        B14 \s
        B15 \s
.endm

        .globl pl_kernel_neon
        .type pl_kernel_neon, %function
pl_kernel_neon:
        ENTER   KFRAME
        stp     d8, d9, [sp, #160]
        stp     d10, d11, [sp, #176]
        stp     d12, d13, [sp, #192]
        stp     d14, d15, [sp, #208]
        // the 2^-149 that `orr #1` makes of d^2 = 0 (i == j, masked lanes)
        // must stay a denormal: clear flush-to-zero (FPCR.FZ, bit 24) for
        // the kernel in case something set it (-ffast-math startup code, a
        // driver), restore the caller's FPCR on exit
        mrs     x9, fpcr
        str     x9, [sp, #224]
        bic     x9, x9, #(1 << 24)
        msr     fpcr, x9
        ADR_L   x19, pl
        mov     w20, w0
        mov     w21, w1
        ldr     x24, [x19, #PL_X]
        ldr     x25, [x19, #PL_Y]
        ldr     x26, [x19, #PL_T]
        ADR_L   x23, pl_ptab
        ADR_L   x28, masktab
        fmov    v4.4s, #1.0
        movi    v5.2d, #0
        fmov    v6.4s, #1.5
        ldr     s8, [x19, #PL_CORES]
        fadd    s8, s8, s8                      // core * force_scale
        fneg    s8, s8
        dup     v14.4s, v8.s[0]
        ldr     w9, [x19, #PL_NRANGE]
        add     x14, sp, x9, lsl #4             // end of the range entries

.Lk_cell:
        cmp     w20, w21
        b.hs    .Lk_done
        ldr     x9, [x19, #PL_CSTART]
        ldr     w22, [x9, x20, lsl #2]          // i
        add     x10, x20, #1
        ldr     w4, [x9, x10, lsl #2]           // i_end
        cmp     w22, w4
        b.hs    .Lk_next_cell

        // neighbour cell ranges -> particle index ranges; prefetch where the
        // next cell's ranges will end (one cell further along each row)
        ldr     x8, [x19, #PL_NBR]
        mov     x10, #NBR_STRIDE
        umaddl  x8, w20, w10, x8
        mov     x15, sp
1:      ldp     w12, w13, [x8]
        ldr     w12, [x9, x12, lsl #2]
        ldr     w13, [x9, x13, lsl #2]
        ldr     x16, [x8, #8]
        stp     w12, w13, [x15]
        str     x16, [x15, #8]
        add     x16, x24, x13, lsl #2
        prfm    pldl1keep, [x16]
        add     x16, x25, x13, lsl #2
        prfm    pldl1keep, [x16]
        add     x16, x26, x13, lsl #2
        prfm    pldl1keep, [x16]
        add     x8, x8, #16
        add     x15, x15, #16
        cmp     x15, x14
        b.lo    1b

.Lk_i:
        ldr     s15, [x24, x22, lsl #2]         // {xi,
        add     x9, x25, x22, lsl #2
        ld1     {v15.s}[1], [x9]                //  yi}
        ldr     w9, [x26, x22, lsl #2]
        add     x27, x23, x9, lsl #8            // table row of type(i)
        movi    v2.2d, #0
        movi    v3.2d, #0
        mov     x6, sp
        mov     w5, #0
#if KPIPE
        // one stream of vectors over all ranges, two-stage pipeline
        NEXTVEC .Lk_fin
        STAGE_A SETP
.Lk_stream:
        // stage A of the next vector, then stage B of the current one: the
        // two are independent, so the out-of-order core overlaps A's long
        // chain with B (issuing A first measured best in llvm-mca)
        NEXTVEC .Lk_finP
        STAGE_A SETQ
        STAGE_B BSETP
        NEXTVEC .Lk_finQ
        STAGE_A SETP
        STAGE_B BSETQ
        b       .Lk_stream
.Lk_finP:
        STAGE_B BSETP
        b       .Lk_fin
.Lk_finQ:
        STAGE_B BSETQ
#else
        // plain loop: each vector through both stages
.Lk_stream:
        NEXTVEC .Lk_fin
        STAGE_A SETP
        STAGE_B BSETP
        b       .Lk_stream
#endif
.Lk_fin:
        // horizontal sums -> s2 = fx, v2.s[1] = fy
        faddp   v2.4s, v2.4s, v3.4s
        faddp   v2.4s, v2.4s, v2.4s

        // integrate: v = v*damp + f*dt; p = p + v*dt; wrap
        ldr     s16, [x19, #PL_DAMP]
        ldr     s17, [x19, #PL_DT]
        ldr     x9, [x19, #PL_VX]
        ldr     s18, [x9, x22, lsl #2]
        fmul    s18, s18, s16
        fmadd   s18, s2, s17, s18
        str     s18, [x9, x22, lsl #2]
        fmadd   s19, s18, s17, s15
        ldr     s20, [x19, #PL_W]
        WRAP    s19, s20
        ldr     x9, [x19, #PL_NX]
        str     s19, [x9, x22, lsl #2]
        mov     s21, v2.s[1]
        ldr     x9, [x19, #PL_VY]
        ldr     s18, [x9, x22, lsl #2]
        fmul    s18, s18, s16
        fmadd   s18, s21, s17, s18
        str     s18, [x9, x22, lsl #2]
        mov     s22, v15.s[1]
        fmadd   s19, s18, s17, s22
        ldr     s20, [x19, #PL_H]
        WRAP    s19, s20
        ldr     x9, [x19, #PL_NY]
        str     s19, [x9, x22, lsl #2]

        add     w22, w22, #1
        cmp     w22, w4
        b.lo    .Lk_i
.Lk_next_cell:
        add     w20, w20, #1
        b       .Lk_cell
.Lk_done:
        ldr     x9, [sp, #224]
        msr     fpcr, x9
        ldp     d8, d9, [sp, #160]
        ldp     d10, d11, [sp, #176]
        ldp     d12, d13, [sp, #192]
        ldp     d14, d15, [sp, #208]
        LEAVE   KFRAME

// ---------------------------------------------------------------- step
// void pl_step(void)
        .globl pl_step
        .type pl_step, %function
pl_step:
        ADR_L   x9, pl
        ldr     w10, [x9, #PL_NTHREADS]
        cmp     w10, #1
        b.ls    1f
        b       pl_mt_step                      // forces and bin on all threads
1:      stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        mov     w0, #0
        ldr     w1, [x9, #PL_NCELLS]
        ldr     x10, [x9, #PL_KERNEL]
        blr     x10
        ldp     x29, x30, [sp], #16
        b       pl_bin

// int pl_cpu_features(void): bit 0 = Advanced SIMD (NEON) usable. There is
// no wider variant on the A72 (no SVE), so bit 1 is never set.
        .globl pl_cpu_features
        .type pl_cpu_features, %function
pl_cpu_features:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        mov     x0, #16                         // AT_HWCAP
        bl      getauxval
        ubfx    w0, w0, #1, #1                  // HWCAP_ASIMD
        ldp     x29, x30, [sp], #16
        ret
