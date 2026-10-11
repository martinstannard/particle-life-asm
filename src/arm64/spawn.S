// Spawn layouts ported from pl-box (crates/pl-core/src/simulation.rs):
// spawn_pie ... spawn_star and the weighted chooser spawn_pattern.
// AArch64 port of src/spawn.S: the same wyrand generator (fastrand), the
// same libm calls (sinf, cosf, atan2f, powf, fmodf, roundf) and the float
// arithmetic operation by operation without FMA, so a layout is
// bit-identical to pl-box's with the same seed (tests/test_spawns.c).
//
// Conventions in this file: a layout keeps its loop state in x19-x26, x27 =
// s_px (spawn state base), x28 = its locals (sp after ENTER), which the
// small helpers (push_ct, push_layer, layer_type, arm_setup) also use.
// Helpers and their clobbers:
//   fr_u64  x0 <- next     x9, x10
//   fr_f32  s0 <- [0,1)    x0, x9, x10, v7
//   fr_below x0 <- [0,x0)  x0, x9-x13 (calls fr_u64)
//   sym/jit s0, s1 kept    as fr_f32
//   emit (w0, s0, s1)      x9-x11

        .include "layout.inc"
        .include "macros.inc"

.set NSPAWNS, 18

        .section .rodata
        .balign 16
C_0:      .float 0.0
C_1:      .float 1.0
C_2:      .float 2.0
C_HALF:   .float 0.5
C_2M63:   .float 1.0842021724855044e-19     // 1 / 2^63
C_TAU:    .float 6.28318530717958647692
C_PI:     .float 3.14159265358979323846
C_6:      .float 6.0
C_18:     .float 18.0
C_0_012:  .float 0.012
C_0_015:  .float 0.015
C_0_0175: .float 0.0175
C_0_02:   .float 0.02
C_0_04:   .float 0.04
C_0_06:   .float 0.06
C_0_07:   .float 0.07
C_0_12:   .float 0.12
C_0_14:   .float 0.14
C_0_15:   .float 0.15
C_0_18:   .float 0.18
C_0_2:    .float 0.2
C_0_22:   .float 0.22
C_0_25:   .float 0.25
C_0_3:    .float 0.3
C_0_35:   .float 0.35
C_0_45:   .float 0.45
C_0_46:   .float 0.46
C_0_48:   .float 0.48
C_0_56:   .float 0.56
C_M0_075: .float -0.075
C_1_2:    .float 1.2
C_1_5:    .float 1.5
C_2_4:    .float 2.4
C_2_5:    .float 2.5

// layout names (pl-box's bin/render.rs spelling); "random" is the old
// uniform scatter (pl-box's random_population); "star_fixed" is not in
// pl-box: its star with the radius scaled to the star (see sp_star)
sn00: .asciz "pie"
sn01: .asciz "line"
sn02: .asciz "ring"
sn03: .asciz "rainbow_ring"
sn04: .asciz "rainbow_rings"
sn05: .asciz "soft_clusters"
sn06: .asciz "radiant_fans"
sn07: .asciz "spiral"
sn08: .asciz "twin_spirals"
sn09: .asciz "spiral_arms"
sn10: .asciz "blocks"
sn11: .asciz "line_mixed"
sn12: .asciz "stripes"
sn13: .asciz "polar_maze"
sn14: .asciz "heart"
sn15: .asciz "star"
sn16: .asciz "random"
sn17: .asciz "star_fixed"

// spawn_pattern: rng.gen_range(0..15) -> layout, soft_clusters 3 of 15.
// Slot 11 is pl-box's star; it is mapped to star_fixed here because pl-box's
// star is a 1 px dot of one species (see sp_star).
pattern_map:
        .byte 0, 1, 10, 3, 4, 6, 8, 9, 12, 13, 14, 17, 5, 5, 5

        .section .data.rel.ro, "aw"
        .balign 8
        .globl pl_spawn_names
pl_spawn_names:
        .quad sn00, sn01, sn02, sn03, sn04, sn05, sn06, sn07, sn08
        .quad sn09, sn10, sn11, sn12, sn13, sn14, sn15, sn16, sn17
spawn_fns:
        .quad sp_pie, sp_line, sp_ring, sp_rainbow_ring, sp_rainbow_rings
        .quad sp_soft_clusters, sp_radiant_fans, sp_spiral, sp_twin_spirals
        .quad sp_spiral_arms, sp_blocks, sp_line_mixed, sp_stripes
        .quad sp_polar_maze, sp_heart, sp_star, sp_random, sp_star_fixed

        .data
        .balign 8
        .globl pl_frng, pl_spawn_cur
pl_frng:      .quad 0           // wyrand state (fastrand's Rng.0)
pl_spawn_cur: .long 0           // layout of the last spawn

        .bss
        .balign 8
s_px:   .skip 8
s_py:   .skip 8
s_pt:   .skip 8
s_n:    .skip 4
s_k:    .skip 4
s_w:    .skip 4
s_h:    .skip 4
s_cnt:  .skip 4
        .balign 16
s_buf:  .skip 4096              // per-layout scratch (block order, lists)

        .text
.set S_PX, 0
.set S_PY, 8
.set S_PT, 16
.set S_N, 24
.set S_K, 28
.set S_W, 32
.set S_H, 36
.set S_CNT, 40

// constant from rodata into sd (clobbers x9)
.macro LC sd, sym
        LDRS    \sd, \sym, x9
.endm
.macro BASES
        mov     x28, sp
        ADR_L   x27, s_px
.endm

// --------------------------------------------------------------- wyrand
// fastrand 2.4: s = state + C0; state = s; t = s * (s ^ C1) (128 bit);
// return lo(t) ^ hi(t). Clobbers x9, x10.
        .globl pl_fr_u64
        .type pl_fr_u64, %function
pl_fr_u64:
fr_u64:
        ADR_L   x9, pl_frng
        ldr     x0, [x9]
        MOV64   x10, 0x2d358dccaa6c78a5
        add     x0, x0, x10
        str     x0, [x9]
        MOV64   x10, 0x8bb84b93962eacc9
        eor     x10, x10, x0
        mul     x9, x0, x10
        umulh   x10, x0, x10
        eor     x0, x9, x10
        ret

// s0 = fastrand::f32(): (u64 >> 1) as f32 / 2^63, redrawn if it rounds to
// 1.0. Clobbers x0, x9, x10, v7 (no other FP register).
fr_f32:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
1:      bl      fr_u64
        lsr     x0, x0, #1
        scvtf   s0, x0
        movz    w9, #0x2000, lsl #16            // 2^-63
        fmov    s7, w9
        fmul    s0, s0, s7
        fmov    s7, #1.0
        fcmp    s0, s7
        b.ge    1b
        ldp     x29, x30, [sp], #16
        ret

// x0 = fastrand::usize(0..x0) (Lemire, with fastrand's rejection step).
// Clobbers x9-x13.
fr_below:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0                         // n
        bl      fr_u64
        mul     x20, x0, x19                    // lo
        umulh   x21, x0, x19                    // hi
        cmp     x20, x19
        b.hs    2f
        neg     x11, x19
        udiv    x12, x11, x19
        msub    x22, x12, x19, x11              // t = n.wrapping_neg() % n
1:      cmp     x20, x22
        b.hs    2f
        bl      fr_u64
        mul     x20, x0, x19
        umulh   x21, x0, x19
        b       1b
2:      mov     x0, x21
        ldp     x19, x20, [sp, #16]
        ldp     x21, x22, [sp, #32]
        ldp     x29, x30, [sp], #48
        ret

// w0 = fastrand::bool() = (u32 as u8) % 2 == 0. Clobbers x9, x10.
fr_bool:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        bl      fr_u64
        mvn     w0, w0
        and     w0, w0, #1
        ldp     x29, x30, [sp], #16
        ret

// s0 = f()*2*R - R for R = s1 (kept)
sym:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        bl      fr_f32
        fadd    s0, s0, s0
        fmul    s0, s0, s1
        fsub    s0, s0, s1
        ldp     x29, x30, [sp], #16
        ret

// s0 = (f()*2 - 1) * T for T = s1 (kept)
jit:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        bl      fr_f32
        fadd    s0, s0, s0
        fmov    s7, #1.0
        fsub    s0, s0, s7
        fmul    s0, s0, s1
        ldp     x29, x30, [sp], #16
        ret

// append (s0, s1, w0) unless N are already out. Clobbers x9-x11.
emit:
        ADR_L   x9, s_px
        ldr     w10, [x9, #S_CNT]
        ldr     w11, [x9, #S_N]
        cmp     w10, w11
        b.hs    1f
        ldr     x11, [x9, #S_PX]
        str     s0, [x11, x10, lsl #2]
        ldr     x11, [x9, #S_PY]
        str     s1, [x11, x10, lsl #2]
        ldr     x11, [x9, #S_PT]
        str     w0, [x11, x10, lsl #2]
        add     w10, w10, #1
        str     w10, [x9, #S_CNT]
1:      ret

// perm(u32 *a = x0, u32 len = w1): a = 0..len, then pl-box's shuffle
// `for i in (1..len).rev() { a.swap(i, fastrand::usize(0..=i)) }`.
// Clobbers x0, x1, x9-x15.
perm:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        mov     x14, x0
        mov     w9, #0
1:      cmp     w9, w1
        b.hs    2f
        str     w9, [x14, x9, lsl #2]
        add     w9, w9, #1
        b       1b
2:      sub     w15, w1, #1                     // i
3:      cmp     w15, #1
        b.lt    4f
        add     w0, w15, #1
        bl      fr_below
        ldr     w9, [x14, x15, lsl #2]
        ldr     w10, [x14, x0, lsl #2]
        str     w10, [x14, x15, lsl #2]
        str     w9, [x14, x0, lsl #2]
        sub     w15, w15, #1
        b       3b
4:      ldp     x29, x30, [sp], #16
        ret

// s0 = min(w, h). Clobbers x9, v7.
wh_min:
        ADR_L   x9, s_px
        ldr     s0, [x9, #S_W]
        ldr     s7, [x9, #S_H]
        fmin    s0, s0, s7
        ret

// s0 = s0 * c (rodata constant). Clobbers x9, v7.
.macro MULC c
        LC      s7, \c
        fmul    s0, s0, s7
.endm

// x at [x28 + a] + y at [x28 + b] into s0 / s1 for emit: s0 = [x28+cx] + [x28+dx]
.macro ADDLOC sd, a, b
        ldr     \sd, [x28, #\a]
        ldr     s7, [x28, #\b]
        fadd    \sd, \sd, s7
.endm

// --------------------------------------------------------------- pie
// spawn_pie_gap(gap 0.25): rejection-sampled disc, type by angular wedge
.set P_CX, 0
.set P_CY, 4
.set P_RM, 8
.set P_RM2, 12
.set P_WEDGE, 16
.set P_DX, 20
.set P_DY, 24
.set P_ANG, 28
.set P_KF, 32
sp_pie:
        ENTER   48
        BASES
        ldr     s0, [x27, #S_W]
        MULC    C_HALF
        str     s0, [x28, #P_CX]
        ldr     s0, [x27, #S_H]
        MULC    C_HALF
        str     s0, [x28, #P_CY]
        bl      wh_min
        MULC    C_0_45
        str     s0, [x28, #P_RM]
        fmul    s0, s0, s0
        str     s0, [x28, #P_RM2]
        ldr     w9, [x27, #S_K]
        scvtf   s1, w9
        str     s1, [x28, #P_KF]
        fmov    s0, #1.0
        LC      s7, C_0_25
        fsub    s0, s0, s7
        fdiv    s0, s0, s1
        str     s0, [x28, #P_WEDGE]
        ldr     w22, [x27, #S_N]
        lsl     x21, x22, #2                    // attempts limit
        mov     x20, #0                         // attempts
1:      ldr     w9, [x27, #S_CNT]
        cmp     w9, w22
        b.hs    5f
        cmp     x20, x21
        b.hs    5f
        add     x20, x20, #1
        ldr     s1, [x28, #P_RM]
        bl      sym
        str     s0, [x28, #P_DX]
        bl      sym
        str     s0, [x28, #P_DY]
        fmul    s2, s0, s0
        ldr     s3, [x28, #P_DX]
        fmul    s3, s3, s3
        fadd    s3, s3, s2
        ldr     s4, [x28, #P_RM2]
        fcmp    s3, s4
        b.gt    1b
        ldr     s0, [x28, #P_DY]
        ldr     s1, [x28, #P_DX]
        bl      atan2f
        LC      s7, C_TAU
        fdiv    s0, s0, s7
        fmov    s7, #1.0
        fadd    s0, s0, s7
        fmov    s1, #1.0
        bl      fmodf
        str     s0, [x28, #P_ANG]
        mov     w23, #0                         // k
2:      ldr     w9, [x27, #S_K]
        cmp     w23, w9
        b.hs    1b
        scvtf   s0, w23
        ldr     s7, [x28, #P_KF]
        fdiv    s0, s0, s7                      // start
        ldr     s7, [x28, #P_WEDGE]
        fadd    s1, s0, s7                      // end
        ldr     s2, [x28, #P_ANG]
        fcmp    s2, s0
        b.lt    3f
        fcmp    s2, s1
        b.ge    3f
        ADDLOC  s0, P_CX, P_DX
        ADDLOC  s1, P_CY, P_DY
        mov     w0, w23
        bl      emit
        b       1b
3:      add     w23, w23, #1
        b       2b
        // fallback: random type anywhere in the disc
5:      ldr     w9, [x27, #S_CNT]
        cmp     w9, w22
        b.hs    9f
        ldr     w0, [x27, #S_K]
        bl      fr_below
        mov     w23, w0
        ldr     s1, [x28, #P_RM]
        bl      sym
        str     s0, [x28, #P_DX]
        bl      sym
        str     s0, [x28, #P_DY]
        fmul    s2, s0, s0
        ldr     s3, [x28, #P_DX]
        fmul    s3, s3, s3
        fadd    s3, s3, s2
        ldr     s4, [x28, #P_RM2]
        fcmp    s3, s4
        b.gt    5b
        ADDLOC  s0, P_CX, P_DX
        ADDLOC  s1, P_CY, P_DY
        mov     w0, w23
        bl      emit
        b       5b
9:      LEAVE   48

// --------------------------------------------------------------- line
// spawn_line (w20 = 0): band of height 0.2 h, type by x box;
// spawn_line_mixed (w20 = 1): same band, uniform type
.set L_BOXW, 0
.set L_BANDH, 4
.set L_Y0, 8
.set L_X, 12
.set L_Y, 20
sp_line_mixed:
        ENTER   32
        mov     w20, #1
        b       1f
sp_line:
        ENTER   32
        mov     w20, #0
1:      BASES
        ldr     w9, [x27, #S_K]
        scvtf   s0, w9
        ldr     s1, [x27, #S_W]
        fdiv    s1, s1, s0
        str     s1, [x28, #L_BOXW]
        ldr     s0, [x27, #S_H]
        LC      s7, C_0_2
        fmul    s1, s0, s7
        str     s1, [x28, #L_BANDH]
        LC      s7, C_HALF
        fmul    s0, s0, s7
        fmul    s1, s1, s7
        fsub    s0, s0, s1
        str     s0, [x28, #L_Y0]
        ldr     w19, [x27, #S_N]
2:      cbz     w19, 9f
        bl      fr_f32
        ldr     s7, [x27, #S_W]
        fmul    s0, s0, s7
        str     s0, [x28, #L_X]
        bl      fr_f32
        ldr     s7, [x28, #L_BANDH]
        fmul    s0, s0, s7
        ldr     s7, [x28, #L_Y0]
        fadd    s0, s0, s7
        str     s0, [x28, #L_Y]
        cbnz    w20, 3f
        ldr     s0, [x28, #L_X]
        ldr     s7, [x28, #L_BOXW]
        fdiv    s0, s0, s7
        fcvtzu  x0, s0                          // as usize (negative -> 0)
        ldr     w9, [x27, #S_K]
        sub     w9, w9, #1
        cmp     x0, x9
        csel    x0, x9, x0, hi
        b       4f
3:      ldr     w0, [x27, #S_K]
        bl      fr_below
4:      ldr     s0, [x28, #L_X]
        ldr     s1, [x28, #L_Y]
        bl      emit
        sub     w19, w19, #1
        b       2b
9:      LEAVE   32

// --------------------------------------------------------------- rings
// spawn_ring (w20 = 0): annulus 0.30..0.50 m, uniform type;
// spawn_rainbow_ring (w20 = 1): same annulus, type by angle
.set R_CX, 0
.set R_CY, 4
.set R_MAX, 8
.set R_MIN2, 12
.set R_MAX2, 16
.set R_DX, 20
.set R_DY, 24
.set R_KF, 28
sp_rainbow_ring:
        ENTER   32
        mov     w20, #1
        b       1f
sp_ring:
        ENTER   32
        mov     w20, #0
1:      BASES
        ldr     s0, [x27, #S_W]
        MULC    C_HALF
        str     s0, [x28, #R_CX]
        ldr     s0, [x27, #S_H]
        MULC    C_HALF
        str     s0, [x28, #R_CY]
        bl      wh_min
        LC      s7, C_0_3
        fmul    s1, s0, s7
        fmul    s1, s1, s1
        str     s1, [x28, #R_MIN2]
        MULC    C_HALF
        str     s0, [x28, #R_MAX]
        fmul    s0, s0, s0
        str     s0, [x28, #R_MAX2]
        ldr     w9, [x27, #S_K]
        scvtf   s0, w9
        str     s0, [x28, #R_KF]
        ldr     w19, [x27, #S_N]
2:      cbz     w19, 9f
3:      ldr     s1, [x28, #R_MAX]
        bl      sym
        str     s0, [x28, #R_DX]
        bl      sym
        str     s0, [x28, #R_DY]
        fmul    s2, s0, s0
        ldr     s3, [x28, #R_DX]
        fmul    s3, s3, s3
        fadd    s3, s3, s2
        ldr     s4, [x28, #R_MIN2]
        fcmp    s3, s4
        b.lt    3b
        ldr     s4, [x28, #R_MAX2]
        fcmp    s3, s4
        b.gt    3b
        cbnz    w20, 4f
        ldr     w0, [x27, #S_K]
        bl      fr_below
        b       5f
4:      ldr     s0, [x28, #R_DY]
        ldr     s1, [x28, #R_DX]
        bl      atan2f
        LC      s7, C_TAU
        fdiv    s0, s0, s7
        fmov    s7, #1.0
        fadd    s0, s0, s7
        fmov    s1, #1.0
        bl      fmodf
        ldr     s7, [x28, #R_KF]
        fmul    s0, s0, s7
        fcvtzu  x9, s0
        ldr     w10, [x27, #S_K]
        udiv    x11, x9, x10
        msub    x0, x11, x10, x9
5:      ADDLOC  s0, R_CX, R_DX
        ADDLOC  s1, R_CY, R_DY
        bl      emit
        sub     w19, w19, #1
        b       2b
9:      LEAVE   32

// spawn_rainbow_rings: disc of 0.48 m, type by radius
sp_rainbow_rings:
        ENTER   32
        BASES
        ldr     s0, [x27, #S_W]
        MULC    C_HALF
        str     s0, [x28, #R_CX]
        ldr     s0, [x27, #S_H]
        MULC    C_HALF
        str     s0, [x28, #R_CY]
        bl      wh_min
        MULC    C_0_48
        str     s0, [x28, #R_MAX]
        fmul    s0, s0, s0
        str     s0, [x28, #R_MAX2]
        ldr     w9, [x27, #S_K]
        scvtf   s0, w9
        str     s0, [x28, #R_KF]
        ldr     w19, [x27, #S_N]
2:      cbz     w19, 9f
3:      ldr     s1, [x28, #R_MAX]
        bl      sym
        str     s0, [x28, #R_DX]
        bl      sym
        str     s0, [x28, #R_DY]
        fmul    s2, s0, s0
        ldr     s3, [x28, #R_DX]
        fmul    s3, s3, s3
        fadd    s3, s3, s2
        ldr     s4, [x28, #R_MAX2]
        fcmp    s3, s4
        b.gt    3b
        fsqrt   s3, s3
        ldr     s7, [x28, #R_MAX]
        fdiv    s3, s3, s7
        ldr     s7, [x28, #R_KF]
        fmul    s3, s3, s7
        fcvtzu  x9, s3
        ldr     w10, [x27, #S_K]
        udiv    x11, x9, x10
        msub    x0, x11, x10, x9
        ADDLOC  s0, R_CX, R_DX
        ADDLOC  s1, R_CY, R_DY
        bl      emit
        sub     w19, w19, #1
        b       2b
9:      LEAVE   32

// --------------------------------------------------------------- soft clusters
// spawn_soft_clusters: k disks (types/2..max(types,6)) placed with
// rejection, each filled uniformly with one or a few species
.set S_RMIN, 0
.set S_RDIFF, 4                 // r_max - r_min
.set S_SPACING, 8
.set S_SPANX, 12
.set S_SPANY, 16
.set S_MINX, 20
.set S_MINY, 24
.set S_RR, 28
.set S_X, 32
.set S_Y, 36
.set S_TH, 40
.set S_R, 44
.set S_RADII, 48                // 16 floats
.set S_CX, 112
.set S_CY, 176
.set S_TVEC, 240                // 16 u32
.set S_CLEN, 304                // 16 u32
.set S_NCL, 368                 // cluster count
.set S_FRAME, 384
// cluster type lists: s_buf, 16 bytes per cluster
sp_soft_clusters:
        ENTER   S_FRAME
        BASES
        bl      wh_min
        LC      s7, C_0_14
        fmul    s1, s0, s7
        str     s1, [x28, #S_RMIN]
        LC      s7, C_0_2
        fmul    s2, s0, s7
        fsub    s2, s2, s1
        str     s2, [x28, #S_RDIFF]
        LC      s7, C_M0_075
        fmul    s1, s0, s7
        str     s1, [x28, #S_SPACING]
        fmov    s0, #2.0
        LC      s7, C_0_18
        fmul    s0, s0, s7
        fmov    s1, #1.0
        fsub    s1, s1, s0                      // 1 - 2 margin
        ldr     s7, [x27, #S_W]
        fmul    s0, s1, s7
        str     s0, [x28, #S_SPANX]
        ldr     s7, [x27, #S_H]
        fmul    s0, s1, s7
        str     s0, [x28, #S_SPANY]
        LC      s7, C_0_18
        ldr     s0, [x27, #S_W]
        fmul    s0, s0, s7
        str     s0, [x28, #S_MINX]
        ldr     s0, [x27, #S_H]
        fmul    s0, s0, s7
        str     s0, [x28, #S_MINY]
        // k = min_clusters + usize(0..=(max - min))
        ldr     w9, [x27, #S_K]
        lsr     w9, w9, #1
        mov     w10, #2
        cmp     w9, w10
        csel    w20, w10, w9, lo                // min clusters
        ldr     w9, [x27, #S_K]
        mov     w10, #6
        cmp     w9, w10
        csel    w9, w10, w9, lo                 // max clusters
        sub     w9, w9, w20
        add     w0, w9, #1
        bl      fr_below
        add     w0, w0, w20
        str     w0, [x28, #S_NCL]
        // place the disks
        mov     w19, #0                         // c
1:      ldr     w9, [x28, #S_NCL]
        cmp     w19, w9
        b.hs    8f
        bl      fr_f32
        ldr     s7, [x28, #S_RDIFF]
        fmul    s0, s0, s7
        ldr     s7, [x28, #S_RMIN]
        fadd    s0, s0, s7
        str     s0, [x28, #S_RR]
        add     x9, x28, #S_RADII
        str     s0, [x9, x19, lsl #2]
        mov     w21, #500
2:      cbz     w21, 6f
        sub     w21, w21, #1
        bl      fr_f32
        ldr     s7, [x28, #S_SPANX]
        fmul    s0, s0, s7
        ldr     s7, [x28, #S_MINX]
        fadd    s0, s0, s7
        str     s0, [x28, #S_X]
        bl      fr_f32
        ldr     s7, [x28, #S_SPANY]
        fmul    s0, s0, s7
        ldr     s7, [x28, #S_MINY]
        fadd    s0, s0, s7
        str     s0, [x28, #S_Y]
        mov     w22, #0                         // j
3:      cmp     w22, w19
        b.hs    5f
        ldr     s0, [x28, #S_X]
        add     x9, x28, #S_CX
        ldr     s7, [x9, x22, lsl #2]
        fsub    s0, s0, s7
        ldr     s1, [x28, #S_Y]
        add     x9, x28, #S_CY
        ldr     s7, [x9, x22, lsl #2]
        fsub    s1, s1, s7
        add     x9, x28, #S_RADII
        ldr     s2, [x9, x22, lsl #2]
        ldr     s7, [x28, #S_RR]
        fadd    s2, s2, s7
        ldr     s7, [x28, #S_SPACING]
        fadd    s2, s2, s7
        movi    d7, #0
        fmax    s2, s2, s7                      // need
        fmul    s0, s0, s0
        fmul    s1, s1, s1
        fadd    s0, s0, s1
        fmul    s2, s2, s2
        fcmp    s0, s2
        b.lt    2b                              // too close: next try
        add     w22, w22, #1
        b       3b
5:      ldr     s0, [x28, #S_X]
        add     x9, x28, #S_CX
        str     s0, [x9, x19, lsl #2]
        ldr     s0, [x28, #S_Y]
        add     x9, x28, #S_CY
        str     s0, [x9, x19, lsl #2]
        b       7f
6:      bl      fr_f32                          // not placed: anywhere in the span
        ldr     s7, [x28, #S_SPANX]
        fmul    s0, s0, s7
        ldr     s7, [x28, #S_MINX]
        fadd    s0, s0, s7
        add     x9, x28, #S_CX
        str     s0, [x9, x19, lsl #2]
        bl      fr_f32
        ldr     s7, [x28, #S_SPANY]
        fmul    s0, s0, s7
        ldr     s7, [x28, #S_MINY]
        fadd    s0, s0, s7
        add     x9, x28, #S_CY
        str     s0, [x9, x19, lsl #2]
7:      add     w19, w19, #1
        b       1b
        // species per cluster
8:      add     x0, x28, #S_TVEC
        ldr     w1, [x27, #S_K]
        bl      perm
        add     x9, x28, #S_CLEN
        stp     xzr, xzr, [x9]
        stp     xzr, xzr, [x9, #16]
        stp     xzr, xzr, [x9, #32]
        stp     xzr, xzr, [x9, #48]
        ldr     w20, [x27, #S_K]                // first = min(types, k)
        ldr     w9, [x28, #S_NCL]
        cmp     w20, w9
        csel    w20, w9, w20, hi
        mov     w19, #0
82:     cmp     w19, w20
        b.hs    83f
        add     x9, x28, #S_TVEC
        ldr     w0, [x9, x19, lsl #2]
        mov     w1, w19
        bl      push_ct
        add     w19, w19, #1
        b       82b
83:     ldr     w9, [x27, #S_K]                 // remaining types to random clusters
        cmp     w19, w9
        b.hs    84f
        ldr     w0, [x28, #S_NCL]
        bl      fr_below
        mov     w1, w0
        add     x9, x28, #S_TVEC
        ldr     w0, [x9, x19, lsl #2]
        bl      push_ct
        add     w19, w19, #1
        b       83b
84:     ldr     w19, [x27, #S_K]                // surplus clusters get a random type
85:     ldr     w9, [x28, #S_NCL]
        cmp     w19, w9
        b.hs    86f
        ldr     w0, [x27, #S_K]
        bl      fr_below
        add     x9, x28, #S_TVEC
        ldr     w0, [x9, x0, lsl #2]
        mov     w1, w19
        bl      push_ct
        add     w19, w19, #1
        b       85b
        // fill: n / k per cluster, the first n % k get one more
86:     ldr     w9, [x27, #S_N]
        ldr     w10, [x28, #S_NCL]
        udiv    w21, w9, w10                    // base
        msub    w22, w21, w10, w9               // rem
        mov     w19, #0                         // c
87:     ldr     w9, [x28, #S_NCL]
        cmp     w19, w9
        b.hs    9f
        mov     w20, w21                        // cnt
        cbz     w22, 88f
        sub     w22, w22, #1
        add     w20, w20, #1
88:     cbz     w20, 892f
        add     x9, x28, #S_CLEN
        ldr     w0, [x9, x19, lsl #2]
        cmp     w0, #1
        csinc   w0, w0, wzr, hs                 // plen
        bl      fr_below
        mov     w23, w0                         // ti
89:     cbz     w20, 892f
        bl      fr_f32
        MULC    C_TAU                           // TAU * f
        str     s0, [x28, #S_TH]
        bl      fr_f32
        fsqrt   s0, s0
        add     x9, x28, #S_RADII
        ldr     s7, [x9, x19, lsl #2]
        fmul    s0, s0, s7
        str     s0, [x28, #S_R]
        ldr     s0, [x28, #S_TH]
        bl      cosf
        ldr     s7, [x28, #S_R]
        fmul    s0, s0, s7
        add     x9, x28, #S_CX
        ldr     s7, [x9, x19, lsl #2]
        fadd    s0, s0, s7
        str     s0, [x28, #S_X]
        ldr     s0, [x28, #S_TH]
        bl      sinf
        ldr     s7, [x28, #S_R]
        fmul    s1, s0, s7
        add     x9, x28, #S_CY
        ldr     s7, [x9, x19, lsl #2]
        fadd    s1, s1, s7
        ldr     s0, [x28, #S_X]
        lsl     w9, w19, #4
        add     w9, w9, w23
        ADR_L   x10, s_buf
        ldrb    w0, [x10, x9]
        bl      emit
        add     w23, w23, #1
        add     x9, x28, #S_CLEN
        ldr     w10, [x9, x19, lsl #2]
        cmp     w10, #1
        csinc   w10, w10, wzr, hs
        cmp     w23, w10
        csel    w23, wzr, w23, eq
        sub     w20, w20, #1
        b       89b
892:    add     w19, w19, #1
        b       87b
9:      LEAVE   S_FRAME

// push type w0 onto cluster w1's list (s_buf rows of 16, lengths at
// S_CLEN of the caller's frame x28). Clobbers x9-x12.
push_ct:
        add     x9, x28, #S_CLEN
        ldr     w10, [x9, w1, uxtw #2]
        cmp     w10, #16
        b.hs    1f
        lsl     w11, w1, #4
        add     w11, w11, w10
        ADR_L   x12, s_buf
        strb    w0, [x12, x11]
        add     w10, w10, #1
        str     w10, [x9, w1, uxtw #2]
1:      ret

// --------------------------------------------------------------- spiral
// spawn_spiral: one Archimedean spiral of 1.2..3.6 turns, one species per
// turn (shuffled), radial jitter 0.0175 m
.set SP_CX, 0
.set SP_CY, 4
.set SP_RADIUS, 8
.set SP_THICK, 12
.set SP_TURNS, 16
.set SP_ROT, 20
.set SP_N1, 24
.set SP_DTH, 28
.set SP_C, 32
.set SP_S, 36
.set SP_UX, 40
.set SP_UY, 44
.set SP_TOTAL, 48
.set SP_ANGLE, 52
.set SP_SEGF, 56
.set SP_R, 60
.set SP_ORDER, 64               // 16 u32
.set SP_SEGS, 128
.set SP_FRAME, 144
sp_spiral:
        ENTER   SP_FRAME
        BASES
        bl      wh_min
        LC      s7, C_0_46
        fmul    s1, s0, s7
        str     s1, [x28, #SP_RADIUS]
        LC      s7, C_0_0175
        fmul    s1, s0, s7
        str     s1, [x28, #SP_THICK]
        ldr     s0, [x27, #S_W]
        MULC    C_HALF
        str     s0, [x28, #SP_CX]
        ldr     s0, [x27, #S_H]
        MULC    C_HALF
        str     s0, [x28, #SP_CY]
        bl      fr_f32
        MULC    C_2_4
        LC      s7, C_1_2
        fadd    s0, s0, s7
        fmov    s7, #1.0
        fmax    s0, s0, s7
        str     s0, [x28, #SP_TURNS]
        bl      fr_f32
        MULC    C_TAU
        str     s0, [x28, #SP_ROT]
        ldr     s0, [x28, #SP_TURNS]
        frintp  s0, s0                          // ceil
        fcvtzu  x9, s0
        cmp     x9, #1
        csinc   x9, x9, xzr, hs
        str     w9, [x28, #SP_SEGS]
        scvtf   s0, x9
        str     s0, [x28, #SP_SEGF]
        ldr     w9, [x27, #S_N]
        sub     w9, w9, #1
        cmp     w9, #1
        csinc   w9, w9, wzr, hs
        scvtf   s0, w9
        str     s0, [x28, #SP_N1]
        ldr     s1, [x28, #SP_TURNS]
        LC      s7, C_TAU
        fmul    s1, s1, s7
        str     s1, [x28, #SP_TOTAL]
        fdiv    s1, s1, s0
        str     s1, [x28, #SP_DTH]
        fmov    s0, s1
        bl      cosf
        str     s0, [x28, #SP_C]
        ldr     s0, [x28, #SP_DTH]
        bl      sinf
        str     s0, [x28, #SP_S]
        ldr     s0, [x28, #SP_ROT]
        bl      cosf
        str     s0, [x28, #SP_UX]
        ldr     s0, [x28, #SP_ROT]
        bl      sinf
        str     s0, [x28, #SP_UY]
        add     x0, x28, #SP_ORDER
        ldr     w1, [x27, #S_K]
        bl      perm
        str     wzr, [x28, #SP_ANGLE]
        mov     w19, #0                         // i
1:      ldr     w9, [x27, #S_N]
        cmp     w19, w9
        b.hs    9f
        ldr     w9, [x28, #SP_SEGS]
        cmp     w9, #1
        b.ls    2f
        ldr     s0, [x28, #SP_ANGLE]
        ldr     s7, [x28, #SP_TOTAL]
        fdiv    s0, s0, s7
        ldr     s7, [x28, #SP_SEGF]
        fmul    s0, s0, s7
        fcvtzu  x9, s0
        b       3f
2:      ldr     w10, [x27, #S_K]                // i % min(types, n)
        ldr     w11, [x27, #S_N]
        cmp     w10, w11
        csel    w10, w11, w10, hi
        udiv    w9, w19, w10
        msub    w9, w9, w10, w19
3:      ldr     w10, [x27, #S_K]
        udiv    x11, x9, x10
        msub    x9, x11, x10, x9
        add     x10, x28, #SP_ORDER
        ldr     w20, [x10, x9, lsl #2]
        scvtf   s0, w19
        ldr     s7, [x28, #SP_N1]
        fdiv    s0, s0, s7
        ldr     s7, [x28, #SP_RADIUS]
        fmul    s0, s0, s7
        str     s0, [x28, #SP_R]
        ldr     s1, [x28, #SP_THICK]
        bl      jit
        ldr     s7, [x28, #SP_R]
        fadd    s0, s0, s7
        movi    d7, #0
        fmax    s0, s0, s7
        ldr     s7, [x28, #SP_UX]
        fmul    s2, s0, s7
        ldr     s7, [x28, #SP_CX]
        fadd    s2, s2, s7
        ldr     s7, [x28, #SP_UY]
        fmul    s1, s0, s7
        ldr     s7, [x28, #SP_CY]
        fadd    s1, s1, s7
        fmov    s0, s2
        mov     w0, w20
        bl      emit
        add     x0, x28, #SP_UX
        add     x1, x28, #SP_C
        bl      rotate
        ldr     s0, [x28, #SP_ANGLE]
        ldr     s7, [x28, #SP_DTH]
        fadd    s0, s0, s7
        str     s0, [x28, #SP_ANGLE]
        add     w19, w19, #1
        b       1b
9:      LEAVE   SP_FRAME

// rotate the unit vector {ux, uy} at [x0] by {c, s} at [x1]:
// nx = ux c - uy s; uy = ux s + uy c; ux = nx. Clobbers v0-v6.
rotate:
        ldp     s0, s1, [x0]
        ldp     s2, s3, [x1]
        fmul    s4, s0, s2
        fmul    s5, s1, s3
        fsub    s4, s4, s5
        fmul    s5, s0, s3
        fmul    s6, s1, s2
        fadd    s5, s5, s6
        stp     s4, s5, [x0]
        ret

// --------------------------------------------------------------- heart
// spawn_heart: rejection sample inside (x^2+y^2-1)^3 - x^2 y^3 <= 0,
// type by angular lobe
.set H_CX, 0
.set H_CY, 4
.set H_SCALE, 8
.set H_X, 12
.set H_Y, 16
.set H_KF, 20
sp_heart:
        ENTER   32
        BASES
        bl      wh_min
        LC      s7, C_0_46
        fmul    s1, s0, s7
        str     s1, [x28, #H_SCALE]
        LC      s7, C_0_06
        fmul    s1, s0, s7
        ldr     s0, [x27, #S_H]
        MULC    C_HALF
        fadd    s0, s0, s1
        str     s0, [x28, #H_CY]
        ldr     s0, [x27, #S_W]
        MULC    C_HALF
        str     s0, [x28, #H_CX]
        ldr     w9, [x27, #S_K]
        scvtf   s0, w9
        str     s0, [x28, #H_KF]
        ldr     w19, [x27, #S_N]
1:      cbz     w19, 5f
        mov     w20, #1000
2:      cbz     w20, 4f
        sub     w20, w20, #1
        fmov    s1, #1.0
        bl      jit                             // u
        MULC    C_1_2
        str     s0, [x28, #H_X]
        bl      jit                             // v
        LC      s7, C_0_15
        fsub    s0, s0, s7
        MULC    C_1_2
        str     s0, [x28, #H_Y]
        ldr     s2, [x28, #H_X]
        fmul    s3, s2, s2                      // x*x
        fmul    s4, s0, s0                      // y*y
        fadd    s4, s3, s4
        fmov    s7, #1.0
        fsub    s4, s4, s7                      // x2y2
        fmul    s5, s4, s4
        fmul    s5, s5, s4
        fmul    s3, s3, s0                      // x*x*y
        fmul    s3, s3, s0
        fmul    s3, s3, s0                      // x*x*y*y*y
        fsub    s5, s5, s3
        fcmp    s5, #0.0
        b.gt    2b
        ldr     s0, [x28, #H_Y]
        ldr     s1, [x28, #H_X]
        bl      atan2f
        LC      s7, C_TAU
        fdiv    s0, s0, s7
        LC      s7, C_HALF
        fadd    s0, s0, s7
        fmov    s1, #1.0
        bl      fmodf
        ldr     s7, [x28, #H_KF]
        fmul    s0, s0, s7
        fcvtzu  x0, s0
        ldr     w9, [x27, #S_K]
        sub     w9, w9, #1
        cmp     x0, x9
        csel    x0, x9, x0, hi
        ldr     s0, [x28, #H_X]
        ldr     s7, [x28, #H_SCALE]
        fmul    s0, s0, s7
        ldr     s7, [x28, #H_CX]
        fadd    s0, s0, s7
        ldr     s1, [x28, #H_Y]
        ldr     s7, [x28, #H_SCALE]
        fmul    s1, s1, s7
        ldr     s2, [x28, #H_CY]
        fsub    s1, s2, s1
        bl      emit
4:      sub     w19, w19, #1
        b       1b
5:      ldr     w9, [x27, #S_CNT]               // failed samples: the centre
        ldr     w10, [x27, #S_N]
        cmp     w9, w10
        b.hs    9f
        ldr     w0, [x27, #S_K]
        bl      fr_below
        ldr     s0, [x28, #H_CX]
        ldr     s1, [x28, #H_CY]
        bl      emit
        b       5b
9:      LEAVE   32

// --------------------------------------------------------------- star
// spawn_star, as in pl-box: pl-box samples the radius as rr = fastrand::f32()
// (0..1 px, never scaled by `outer`), so every particle lands within 1 px
// of the centre and inside core_r. Ported as is; star_fixed (w21 = 1)
// scales rr by `outer`.
.set ST_CX, 0
.set ST_CY, 4
.set ST_OUTER, 8
.set ST_INNER, 12
.set ST_CORE, 16
.set ST_NPTS, 20
.set ST_A, 24
.set ST_RR, 28
.set ST_PIN, 32                 // PI / npts
.set ST_TAUN, 36                // TAU / npts
.set ST_X, 40
.set ST_REG, 48                 // 17 u32
.set ST_ORDER, 120              // 16 u32
.set ST_FRAME, 192
sp_star_fixed:
        ENTER   ST_FRAME
        mov     w21, #1
        b       0f
sp_star:
        ENTER   ST_FRAME
        mov     w21, #0
0:      BASES
        ldr     s0, [x27, #S_W]
        MULC    C_HALF
        str     s0, [x28, #ST_CX]
        ldr     s0, [x27, #S_H]
        MULC    C_HALF
        str     s0, [x28, #ST_CY]
        bl      wh_min
        MULC    C_0_46
        str     s0, [x28, #ST_OUTER]
        MULC    C_0_45
        str     s0, [x28, #ST_INNER]
        MULC    C_0_35
        str     s0, [x28, #ST_CORE]
        ldr     w9, [x27, #S_K]
        scvtf   s0, w9
        str     s0, [x28, #ST_NPTS]
        LC      s1, C_PI
        fdiv    s1, s1, s0
        str     s1, [x28, #ST_PIN]
        LC      s1, C_TAU
        fdiv    s1, s1, s0
        str     s1, [x28, #ST_TAUN]
        add     x0, x28, #ST_ORDER
        ldr     w1, [x27, #S_K]
        bl      perm
        mov     w19, #0                         // reg_type[r] = order[(r % types) % types]
1:      ldr     w10, [x27, #S_K]
        udiv    w9, w19, w10
        msub    w9, w9, w10, w19
        add     x10, x28, #ST_ORDER
        ldr     w9, [x10, x9, lsl #2]
        add     x10, x28, #ST_REG
        str     w9, [x10, x19, lsl #2]
        add     w19, w19, #1
        ldr     w10, [x27, #S_K]
        cmp     w19, w10
        b.ls    1b
        ldr     w19, [x27, #S_N]
2:      cbz     w19, 5f
        mov     w20, #1000
3:      cbz     w20, 4f
        sub     w20, w20, #1
        bl      fr_f32
        MULC    C_TAU
        str     s0, [x28, #ST_A]
        bl      fr_f32
        cbz     w21, 30f
        ldr     s7, [x28, #ST_OUTER]
        fmul    s0, s0, s7
30:     str     s0, [x28, #ST_RR]
        ldr     s0, [x28, #ST_A]
        ldr     s7, [x28, #ST_PIN]
        fadd    s0, s0, s7
        ldr     s1, [x28, #ST_TAUN]
        bl      fmodf                           // rem_euclid
        fcmp    s0, #0.0
        b.ge    31f
        ldr     s7, [x28, #ST_TAUN]
        fadd    s0, s0, s7
31:     ldr     s7, [x28, #ST_TAUN]
        fdiv    s0, s0, s7                      // phase
        ldr     s1, [x28, #ST_OUTER]
        ldr     s7, [x28, #ST_INNER]
        fsub    s2, s1, s7
        fmul    s2, s2, s0
        fsub    s1, s1, s2                      // radius
        ldr     s0, [x28, #ST_RR]
        fcmp    s0, s1
        b.gt    3b
        ldr     s0, [x28, #ST_A]
        bl      cosf
        ldr     s7, [x28, #ST_RR]
        fmul    s0, s0, s7
        ldr     s7, [x28, #ST_CX]
        fadd    s0, s0, s7
        str     s0, [x28, #ST_X]
        ldr     s0, [x28, #ST_A]
        bl      sinf
        ldr     s7, [x28, #ST_RR]
        fmul    s0, s0, s7
        ldr     s7, [x28, #ST_CY]
        fadd    s0, s0, s7
        str     s0, [x28, #ST_X + 4]
        ldr     s0, [x28, #ST_A]
        ldr     s7, [x28, #ST_PIN]
        fadd    s0, s0, s7
        ldr     s7, [x28, #ST_TAUN]
        fdiv    s0, s0, s7
        fcvtzu  x9, s0
        ldr     w10, [x27, #S_K]
        udiv    x11, x9, x10
        msub    x9, x11, x10, x9                // pt
        add     x10, x28, #ST_REG + 4
        ldr     w0, [x10, x9, lsl #2]
        ldr     s0, [x28, #ST_RR]
        ldr     s7, [x28, #ST_CORE]
        fcmp    s0, s7
        b.gt    32f
        ldr     w0, [x28, #ST_REG]
32:     ldr     s0, [x28, #ST_X]
        ldr     s1, [x28, #ST_X + 4]
        bl      emit
4:      sub     w19, w19, #1
        b       2b
5:      ldr     w9, [x27, #S_CNT]
        ldr     w10, [x27, #S_N]
        cmp     w9, w10
        b.hs    9f
        ldr     w0, [x28, #ST_REG]
        ldr     s0, [x28, #ST_CX]
        ldr     s1, [x28, #ST_CY]
        bl      emit
        b       5b
9:      LEAVE   ST_FRAME

// --------------------------------------------------------------- arms
// spawn_twin_spirals: two opposed arms of 1.5..3 turns, the shuffled
// species split between them (cycled along each arm)
.set T_CX, 0
.set T_CY, 4
.set T_RADIUS, 8
.set T_THICK, 12
.set T_TURNS, 16
.set T_ROT, 20
.set T_DTH, 24
.set T_C, 28
.set T_S, 32
.set T_UX, 36
.set T_UY, 40
.set T_KM1, 44                  // (k-1) as f32
.set T_R, 48
.set T_PERM, 56                 // 16 u32
.set T_LO, 120                  // palette of the arm: [lo, hi)
.set T_HI, 124
.set T_FRAME, 128
sp_twin_spirals:
        ENTER   T_FRAME
        BASES
        bl      wh_min
        LC      s7, C_0_46
        fmul    s1, s0, s7
        str     s1, [x28, #T_RADIUS]
        LC      s7, C_0_015
        fmul    s1, s0, s7
        str     s1, [x28, #T_THICK]
        ldr     s0, [x27, #S_W]
        MULC    C_HALF
        str     s0, [x28, #T_CX]
        ldr     s0, [x27, #S_H]
        MULC    C_HALF
        str     s0, [x28, #T_CY]
        bl      fr_f32
        LC      s7, C_1_5
        fmul    s0, s0, s7
        fadd    s0, s0, s7
        str     s0, [x28, #T_TURNS]
        bl      fr_f32
        MULC    C_TAU
        str     s0, [x28, #T_ROT]
        add     x0, x28, #T_PERM
        ldr     w1, [x27, #S_K]
        bl      perm
        ldr     w22, [x27, #S_N]
        and     w23, w22, #1                    // rem
        lsr     w22, w22, #1                    // base
        mov     w19, #0                         // arm a
1:      cmp     w19, #2
        b.hs    9f
        mov     w20, w22                        // k
        cbz     w23, 2f
        sub     w23, w23, #1
        add     w20, w20, #1
2:      cbz     w20, 8f
        ldr     w9, [x27, #S_K]                 // mid = (types + 1) / 2
        add     w9, w9, #1
        lsr     w9, w9, #1
        mov     w10, #0
        mov     w11, w9
        cbz     w19, 3f
        mov     w10, w9                         // arm 1: perm[mid..], or perm[..mid] if empty
        ldr     w11, [x27, #S_K]
        cmp     w10, w11
        b.lo    3f
        mov     w10, #0
        mov     w11, w9
3:      str     w10, [x28, #T_LO]
        str     w11, [x28, #T_HI]
        sub     w0, w11, w10                    // plen
        bl      fr_below
        mov     w21, w0                         // pi
        scvtf   s0, w19
        LC      s7, C_PI
        fmul    s0, s0, s7
        ldr     s7, [x28, #T_ROT]
        fadd    s0, s0, s7                      // th0
        str     s0, [x28, #T_UX]
        sub     w9, w20, #1
        cmp     w9, #1
        csinc   w9, w9, wzr, hs
        scvtf   s1, w9
        ldr     s2, [x28, #T_TURNS]
        LC      s7, C_TAU
        fmul    s2, s2, s7
        fdiv    s2, s2, s1
        str     s2, [x28, #T_DTH]
        sub     w9, w20, #1
        scvtf   s1, w9
        str     s1, [x28, #T_KM1]
        bl      arm_setup
        mov     w24, #0                         // nn
4:      cmp     w24, w20
        b.hs    8f
        movi    d0, #0
        cmp     w20, #1
        b.ls    5f
        scvtf   s0, w24
        ldr     s7, [x28, #T_KM1]
        fdiv    s0, s0, s7
5:      ldr     s7, [x28, #T_RADIUS]
        fmul    s0, s0, s7
        str     s0, [x28, #T_R]
        ldr     s1, [x28, #T_THICK]
        bl      jit
        ldr     s7, [x28, #T_R]
        fadd    s0, s0, s7
        movi    d7, #0
        fmax    s0, s0, s7
        ldr     s7, [x28, #T_UX]
        fmul    s2, s0, s7
        ldr     s7, [x28, #T_CX]
        fadd    s2, s2, s7
        ldr     s7, [x28, #T_UY]
        fmul    s1, s0, s7
        ldr     s7, [x28, #T_CY]
        fadd    s1, s1, s7
        fmov    s0, s2
        ldr     w9, [x28, #T_LO]
        add     w9, w9, w21
        add     x10, x28, #T_PERM
        ldr     w0, [x10, x9, lsl #2]
        bl      emit
        add     w21, w21, #1
        ldr     w9, [x28, #T_LO]
        add     w9, w9, w21
        ldr     w10, [x28, #T_HI]
        cmp     w9, w10
        csel    w21, wzr, w21, hs
        add     x0, x28, #T_UX
        add     x1, x28, #T_C
        bl      rotate
        add     w24, w24, #1
        b       4b
8:      add     w19, w19, #1
        b       1b
9:      LEAVE   T_FRAME

// from the caller's frame (T_ layout at x28): th0 in T_UX -> {ux, uy} =
// {cos th0, sin th0}; dth in T_DTH -> {c, s}
arm_setup:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        ldr     s0, [x28, #T_DTH]
        bl      cosf
        str     s0, [x28, #T_C]
        ldr     s0, [x28, #T_DTH]
        bl      sinf
        str     s0, [x28, #T_S]
        ldr     s0, [x28, #T_UX]
        str     s0, [sp, #16]
        bl      cosf
        str     s0, [x28, #T_UX]
        ldr     s0, [sp, #16]
        bl      sinf
        str     s0, [x28, #T_UY]
        ldp     x29, x30, [sp], #32
        ret

// spawn_spiral_arms: one arm of 2.5 turns per species
sp_spiral_arms:
        ENTER   T_FRAME
        BASES
        bl      wh_min
        LC      s7, C_0_46
        fmul    s1, s0, s7
        str     s1, [x28, #T_RADIUS]
        ldr     w9, [x27, #S_K]
        scvtf   s1, w9
        LC      s2, C_0_07
        fdiv    s2, s2, s1
        LC      s3, C_0_02
        fmin    s3, s3, s2
        fmul    s3, s3, s0
        str     s3, [x28, #T_THICK]
        ldr     s0, [x27, #S_W]
        MULC    C_HALF
        str     s0, [x28, #T_CX]
        ldr     s0, [x27, #S_H]
        MULC    C_HALF
        str     s0, [x28, #T_CY]
        add     x0, x28, #T_PERM
        ldr     w1, [x27, #S_K]
        bl      perm
        ldr     w9, [x27, #S_N]
        ldr     w10, [x27, #S_K]
        udiv    w22, w9, w10                    // base
        msub    w23, w22, w10, w9               // rem
        mov     w19, #0                         // a
1:      ldr     w9, [x27, #S_K]
        cmp     w19, w9
        b.hs    9f
        mov     w20, w22
        cmp     w19, w23
        b.hs    2f
        add     w20, w20, #1
2:      cbz     w20, 8f
        scvtf   s0, w19
        ldr     w9, [x27, #S_K]
        scvtf   s1, w9
        fdiv    s0, s0, s1
        MULC    C_TAU
        str     s0, [x28, #T_UX]
        sub     w9, w20, #1
        cmp     w9, #1
        csinc   w9, w9, wzr, hs
        scvtf   s1, w9
        LC      s2, C_2_5
        LC      s7, C_TAU
        fmul    s2, s2, s7
        fdiv    s2, s2, s1
        str     s2, [x28, #T_DTH]
        sub     w9, w20, #1
        scvtf   s1, w9
        str     s1, [x28, #T_KM1]
        bl      arm_setup
        mov     w21, #0                         // nn
4:      cmp     w21, w20
        b.hs    8f
        movi    d0, #0
        cmp     w20, #1
        b.ls    5f
        scvtf   s0, w21
        ldr     s7, [x28, #T_KM1]
        fdiv    s0, s0, s7
5:      ldr     s7, [x28, #T_RADIUS]
        fmul    s0, s0, s7
        str     s0, [x28, #T_R]
        ldr     s1, [x28, #T_THICK]
        bl      jit
        ldr     s7, [x28, #T_R]
        fadd    s0, s0, s7
        movi    d7, #0
        fmax    s0, s0, s7
        ldr     s7, [x28, #T_UX]
        fmul    s2, s0, s7
        ldr     s7, [x28, #T_CX]
        fadd    s2, s2, s7
        ldr     s7, [x28, #T_UY]
        fmul    s1, s0, s7
        ldr     s7, [x28, #T_CY]
        fadd    s1, s1, s7
        fmov    s0, s2
        add     x10, x28, #T_PERM
        ldr     w0, [x10, x19, lsl #2]
        bl      emit
        add     x0, x28, #T_UX
        add     x1, x28, #T_C
        bl      rotate
        add     w21, w21, #1
        b       4b
8:      add     w19, w19, #1
        b       1b
9:      LEAVE   T_FRAME

// --------------------------------------------------------------- fans
// spawn_radiant_fans: clamp(types, 3, 10) beams from the centre, denser
// near the rim (r = r_out f^0.56). pl-box skips fans with no colour (types
// < 3), returning fewer than N particles; here such a fan borrows the set
// of fan f % types so the count is always N (no effect for types >= 3).
.set F_CX, 0
.set F_CY, 4
.set F_ROUT, 8
.set F_SPREAD, 12
.set F_TH0, 16
.set F_R, 20
.set F_TH, 24
.set F_X, 28
.set F_FANS, 32
.set F_TVEC, 40                 // 16 u32
.set F_CLEN, 104                // 10 u32
.set F_SET, 144                 // colour set of the current fan
.set F_FRAME, 160
// colour sets: s_buf, 16 bytes per fan
sp_radiant_fans:
        ENTER   F_FRAME
        BASES
        ldr     w9, [x27, #S_K]
        mov     w10, #3
        cmp     w9, w10
        csel    w9, w10, w9, lo
        mov     w10, #10
        cmp     w9, w10
        csel    w9, w10, w9, hi
        str     w9, [x28, #F_FANS]
        bl      wh_min
        MULC    C_0_46
        str     s0, [x28, #F_ROUT]
        LC      s0, C_0_22
        MULC    C_PI
        str     s0, [x28, #F_SPREAD]
        ldr     s0, [x27, #S_W]
        MULC    C_HALF
        str     s0, [x28, #F_CX]
        ldr     s0, [x27, #S_H]
        MULC    C_HALF
        str     s0, [x28, #F_CY]
        add     x0, x28, #F_TVEC
        ldr     w1, [x27, #S_K]
        bl      perm
        add     x9, x28, #F_CLEN
        stp     xzr, xzr, [x9]
        stp     xzr, xzr, [x9, #16]
        str     xzr, [x9, #32]
        mov     w19, #0                         // color_sets[i % fans].push(tvec[i])
2:      ldr     w9, [x27, #S_K]
        cmp     w19, w9
        b.hs    3f
        ldr     w10, [x28, #F_FANS]
        udiv    w9, w19, w10
        msub    w9, w9, w10, w19                // f
        add     x10, x28, #F_CLEN
        ldr     w11, [x10, x9, lsl #2]
        add     w12, w11, #1
        str     w12, [x10, x9, lsl #2]
        lsl     w9, w9, #4
        add     w9, w9, w11
        add     x10, x28, #F_TVEC
        ldr     w11, [x10, x19, lsl #2]
        ADR_L   x10, s_buf
        strb    w11, [x10, x9]
        add     w19, w19, #1
        b       2b
3:      ldr     w9, [x27, #S_N]
        ldr     w10, [x28, #F_FANS]
        udiv    w22, w9, w10                    // base
        msub    w23, w22, w10, w9               // rem
        mov     w19, #0                         // f
4:      ldr     w9, [x28, #F_FANS]
        cmp     w19, w9
        b.hs    9f
        mov     w20, w22                        // cnt
        cbz     w23, 5f
        sub     w23, w23, #1
        add     w20, w20, #1
5:      cbz     w20, 8f
        mov     w9, w19                         // set index (see above)
        add     x10, x28, #F_CLEN
        ldr     w11, [x10, x9, lsl #2]
        cbnz    w11, 51f
        ldr     w10, [x27, #S_K]
        udiv    w11, w9, w10
        msub    w9, w11, w10, w9
51:     str     w9, [x28, #F_SET]
        scvtf   s0, w19
        ldr     w9, [x28, #F_FANS]
        scvtf   s1, w9
        fdiv    s0, s0, s1
        MULC    C_TAU
        str     s0, [x28, #F_TH0]
        bl      fr_f32
        MULC    C_0_2
        ldr     s7, [x28, #F_TH0]
        fadd    s0, s0, s7
        str     s0, [x28, #F_TH0]
        ldr     w9, [x28, #F_SET]
        add     x10, x28, #F_CLEN
        ldr     w0, [x10, x9, lsl #2]
        bl      fr_below
        mov     w21, w0                         // ci
6:      cbz     w20, 8f
        bl      fr_f32
        LC      s1, C_0_56
        bl      powf
        ldr     s7, [x28, #F_ROUT]
        fmul    s0, s0, s7
        str     s0, [x28, #F_R]
        ldr     s1, [x28, #F_SPREAD]
        bl      jit
        ldr     s7, [x28, #F_TH0]
        fadd    s0, s0, s7
        str     s0, [x28, #F_TH]
        bl      cosf
        ldr     s7, [x28, #F_R]
        fmul    s0, s0, s7
        ldr     s7, [x28, #F_CX]
        fadd    s0, s0, s7
        str     s0, [x28, #F_X]
        ldr     s0, [x28, #F_TH]
        bl      sinf
        ldr     s7, [x28, #F_R]
        fmul    s1, s0, s7
        ldr     s7, [x28, #F_CY]
        fadd    s1, s1, s7
        ldr     s0, [x28, #F_X]
        ldr     w9, [x28, #F_SET]
        lsl     w9, w9, #4
        add     w9, w9, w21
        ADR_L   x10, s_buf
        ldrb    w0, [x10, x9]
        bl      emit
        add     w21, w21, #1
        ldr     w9, [x28, #F_SET]
        add     x10, x28, #F_CLEN
        ldr     w10, [x10, x9, lsl #2]
        cmp     w21, w10
        csel    w21, wzr, w21, eq
        sub     w20, w20, #1
        b       6b
8:      add     w19, w19, #1
        b       4b
9:      LEAVE   F_FRAME

// --------------------------------------------------------------- blocks
// spawn_blocks: a rows x cols mosaic (6..72+ blocks), shuffled species per
// block (every species at least once), 12% gaps
.set B_BW, 0
.set B_BH, 4
.set B_GAP, 8
.set B_X0, 12
.set B_Y0, 16
.set B_IW, 20
.set B_IH, 24
.set B_ROWS, 28
.set B_COLS, 32
.set B_BLOCKS, 36
.set B_X, 40
.set B_FRAME, 48
// s_buf: order (u32, up to 512), then species bytes at s_buf + 2048
sp_blocks:
        ENTER   B_FRAME
        BASES
        // target = usize(max(types,6) ..= max(types*8, 72)).min(n)
        ldr     w9, [x27, #S_K]
        mov     w10, #6
        cmp     w9, w10
        csel    w20, w10, w9, lo                // lo
        ldr     w9, [x27, #S_K]
        lsl     w9, w9, #3
        mov     w10, #72
        cmp     w9, w10
        csel    w9, w10, w9, lo                 // hi
        sub     w9, w9, w20
        add     w0, w9, #1
        bl      fr_below
        add     w0, w0, w20
        ldr     w9, [x27, #S_N]
        cmp     w0, w9
        csel    w20, w9, w0, hi                 // target
        scvtf   s0, w20
        ldr     s1, [x27, #S_W]
        ldr     s7, [x27, #S_H]
        fdiv    s1, s1, s7                      // aspect
        fdiv    s0, s0, s1
        fsqrt   s0, s0
        bl      roundf
        fcvtzu  x9, s0
        cmp     x9, #1
        csinc   x9, x9, xzr, hs
        str     w9, [x28, #B_ROWS]
        scvtf   s0, w20
        scvtf   s1, w9
        fdiv    s0, s0, s1
        frintp  s0, s0                          // ceil
        fcvtzu  x10, s0
        cmp     x10, #1
        csinc   x10, x10, xzr, hs
        str     w10, [x28, #B_COLS]
        mul     w9, w10, w9
        mov     w10, #512                       // scratch bound (never reached: <= 2 x 128)
        cmp     w9, w10
        csel    w9, w10, w9, hi
        str     w9, [x28, #B_BLOCKS]
        ldr     w9, [x28, #B_COLS]
        scvtf   s1, w9
        ldr     s0, [x27, #S_W]
        fdiv    s0, s0, s1
        str     s0, [x28, #B_BW]
        ldr     w9, [x28, #B_ROWS]
        scvtf   s1, w9
        ldr     s2, [x27, #S_H]
        fdiv    s2, s2, s1
        str     s2, [x28, #B_BH]
        fmin    s0, s0, s2
        MULC    C_0_12
        str     s0, [x28, #B_GAP]
        ADR_L   x0, s_buf
        ldr     w1, [x28, #B_BLOCKS]
        bl      perm
        mov     w19, #0                         // idx
1:      ldr     w9, [x28, #B_BLOCKS]
        cmp     w19, w9
        b.hs    3f
        mov     w0, w19
        ldr     w9, [x27, #S_K]
        cmp     w19, w9
        b.lo    2f
        mov     w0, w9
        bl      fr_below
2:      ADR_L   x10, s_buf
        ldr     w11, [x10, x19, lsl #2]         // b = order[idx]
        add     x10, x10, #2048
        strb    w0, [x10, x11]
        add     w19, w19, #1
        b       1b
3:      ldr     w9, [x27, #S_N]
        ldr     w10, [x28, #B_BLOCKS]
        udiv    w22, w9, w10                    // base
        msub    w23, w22, w10, w9               // rem
        mov     w19, #0                         // r
4:      ldr     w9, [x28, #B_ROWS]
        cmp     w19, w9
        b.hs    9f
        mov     w21, #0                         // c
5:      ldr     w9, [x28, #B_COLS]
        cmp     w21, w9
        b.hs    8f
        mov     w20, w22                        // cnt
        cbz     w23, 51f
        sub     w23, w23, #1
        add     w20, w20, #1
51:     cbz     w20, 7f
        ldr     s2, [x28, #B_GAP]
        LC      s7, C_HALF
        fmul    s3, s2, s7
        scvtf   s0, w21
        ldr     s7, [x28, #B_BW]
        fmul    s0, s0, s7
        fadd    s0, s0, s3
        str     s0, [x28, #B_X0]
        scvtf   s0, w19
        ldr     s7, [x28, #B_BH]
        fmul    s0, s0, s7
        fadd    s0, s0, s3
        str     s0, [x28, #B_Y0]
        fmov    s7, #1.0
        ldr     s0, [x28, #B_BW]
        fsub    s0, s0, s2
        fmax    s0, s0, s7
        str     s0, [x28, #B_IW]
        ldr     s0, [x28, #B_BH]
        fsub    s0, s0, s2
        fmax    s0, s0, s7
        str     s0, [x28, #B_IH]
6:      cbz     w20, 7f
        bl      fr_f32
        ldr     s7, [x28, #B_IW]
        fmul    s0, s0, s7
        ldr     s7, [x28, #B_X0]
        fadd    s0, s0, s7
        str     s0, [x28, #B_X]
        bl      fr_f32
        ldr     s7, [x28, #B_IH]
        fmul    s1, s0, s7
        ldr     s7, [x28, #B_Y0]
        fadd    s1, s1, s7
        ldr     s0, [x28, #B_X]
        ldr     w9, [x28, #B_COLS]
        madd    w9, w19, w9, w21
        ADR_L   x10, s_buf
        add     x10, x10, #2048
        ldrb    w0, [x10, x9]
        bl      emit
        sub     w20, w20, #1
        b       6b
7:      add     w21, w21, #1
        b       5b
8:      add     w19, w19, #1
        b       4b
9:      LEAVE   B_FRAME

// --------------------------------------------------------------- stripes
// spawn_stripes: equal stripes, one species each, randomly vertical or
// horizontal and optionally reversed
.set SS_SEG, 0
.set SS_O, 4
.set SS_X, 8
.set SS_FRAME, 16
sp_stripes:
        ENTER   SS_FRAME
        BASES
        bl      fr_bool
        mov     w22, w0                         // vertical
        bl      fr_bool
        mov     w23, w0                         // reversed
        ldr     w9, [x27, #S_N]
        ldr     w10, [x27, #S_K]
        udiv    w20, w9, w10                    // base
        msub    w21, w20, w10, w9               // rem
        scvtf   s1, w10
        ldr     s0, [x27, #S_W]
        cbnz    w22, 1f
        ldr     s0, [x27, #S_H]
1:      fdiv    s0, s0, s1
        str     s0, [x28, #SS_SEG]
        mov     w19, #0                         // si
2:      ldr     w9, [x27, #S_K]
        cmp     w19, w9
        b.hs    9f
        scvtf   s0, w19
        ldr     s7, [x28, #SS_SEG]
        fmul    s0, s0, s7
        str     s0, [x28, #SS_O]
        mov     w24, w20                        // k
        cbz     w21, 4f
        sub     w21, w21, #1
        add     w24, w24, #1
4:      cbz     w24, 7f
        cbz     w22, 5f
        bl      fr_f32
        ldr     s7, [x28, #SS_SEG]
        fmul    s0, s0, s7
        ldr     s7, [x28, #SS_O]
        fadd    s0, s0, s7
        str     s0, [x28, #SS_X]
        bl      fr_f32
        ldr     s7, [x27, #S_H]
        fmul    s1, s0, s7
        ldr     s0, [x28, #SS_X]
        b       6f
5:      bl      fr_f32
        ldr     s7, [x27, #S_W]
        fmul    s0, s0, s7
        str     s0, [x28, #SS_X]
        bl      fr_f32
        ldr     s7, [x28, #SS_SEG]
        fmul    s1, s0, s7
        ldr     s7, [x28, #SS_O]
        fadd    s1, s1, s7
        ldr     s0, [x28, #SS_X]
6:      mov     w0, w19
        cbz     w23, 61f
        ldr     w0, [x27, #S_K]
        sub     w0, w0, w19
        sub     w0, w0, #1
61:     bl      emit
        sub     w24, w24, #1
        b       4b
7:      add     w19, w19, #1
        b       2b
9:      LEAVE   SS_FRAME

// --------------------------------------------------------------- polar maze
// spawn_polar_maze: 6 rings of 18 sectors; each ring gets a few species and
// a random number of arcs, each arc a run of one species
.set M_CX, 0
.set M_CY, 4
.set M_THICK, 8
.set M_RMIN, 12
.set M_DR, 16
.set M_DTH, 20
.set M_R, 24
.set M_TH0, 28
.set M_STEP, 32
.set M_SN, 36
.set M_C, 40
.set M_UX, 44
.set M_UY, 48
.set M_RR, 52
.set M_ANG, 56
.set M_X, 60
.set M_LEN, 64                  // 6 u32: layer list lengths
.set M_USED, 88                 // 18 bytes
.set M_SHUF, 112                // 16 u32
.set M_ARCS, 176
.set M_KPA, 180
.set M_TT, 184
.set M_FRAME, 192
// layer lists: s_buf, 64 bytes per layer
sp_polar_maze:
        ENTER   M_FRAME
        BASES
        ldr     s0, [x27, #S_W]
        MULC    C_HALF
        str     s0, [x28, #M_CX]
        ldr     s0, [x27, #S_H]
        MULC    C_HALF
        str     s0, [x28, #M_CY]
        bl      wh_min
        LC      s7, C_0_012
        fmul    s1, s0, s7
        str     s1, [x28, #M_THICK]
        LC      s7, C_0_12
        fmul    s1, s0, s7
        str     s1, [x28, #M_RMIN]
        LC      s7, C_0_46
        fmul    s2, s0, s7
        fsub    s2, s2, s1
        LC      s7, C_6
        fdiv    s2, s2, s7
        str     s2, [x28, #M_DR]
        LC      s0, C_TAU
        LC      s7, C_18
        fdiv    s0, s0, s7
        str     s0, [x28, #M_DTH]
        add     x0, x28, #M_SHUF
        ldr     w1, [x27, #S_K]
        bl      perm
        add     x9, x28, #M_LEN
        stp     xzr, xzr, [x9]
        str     xzr, [x9, #16]
        mov     w19, #0                         // layer_types[i % 6].push(shuffled[i])
2:      ldr     w9, [x27, #S_K]
        cmp     w19, w9
        b.hs    3f
        mov     w10, #6
        udiv    w9, w19, w10
        msub    w1, w9, w10, w19
        add     x9, x28, #M_SHUF
        ldr     w0, [x9, x19, lsl #2]
        bl      push_layer
        add     w19, w19, #1
        b       2b
3:      mov     w19, #0                         // extra colours, p = 0.35
31:     ldr     w9, [x27, #S_K]
        cmp     w19, w9
        b.hs    4f
        bl      fr_f32
        LC      s7, C_0_35
        fcmp    s0, s7
        b.ge    32f
        mov     w0, #6
        bl      fr_below
        mov     w1, w0
        mov     w0, w19
        bl      push_layer
32:     add     w19, w19, #1
        b       31b
4:      mov     w19, #0                         // no empty layer
41:     add     x9, x28, #M_LEN
        ldr     w9, [x9, x19, lsl #2]
        cbnz    w9, 42f
        ldr     w0, [x27, #S_K]
        bl      fr_below
        mov     w1, w19
        bl      push_layer
42:     add     w19, w19, #1
        cmp     w19, #6
        b.lo    41b
        // rings
        mov     w19, #0                         // l
5:      cmp     w19, #6
        b.hs    9f
        ldr     w9, [x27, #S_N]
        mov     w10, #6
        udiv    w20, w9, w10                    // remain = base + (l < rem)
        msub    w9, w20, w10, w9
        cmp     w19, w9
        b.hs    51f
        add     w20, w20, #1
51:     cbz     w20, 8f
        scvtf   s0, w19
        LC      s7, C_HALF
        fadd    s0, s0, s7
        ldr     s7, [x28, #M_DR]
        fmul    s0, s0, s7
        ldr     s7, [x28, #M_RMIN]
        fadd    s0, s0, s7
        str     s0, [x28, #M_R]
        bl      fr_f32
        LC      s7, C_HALF
        fmul    s0, s0, s7
        fadd    s0, s0, s7
        MULC    C_18
        fcvtzu  x9, s0
        cmp     x9, #2
        mov     x10, #2
        csel    x9, x10, x9, lo
        str     w9, [x28, #M_ARCS]
        add     x9, x28, #M_USED
        stp     xzr, xzr, [x9]
        strh    wzr, [x9, #16]
        ldr     w9, [x28, #M_ARCS]
        udiv    w9, w20, w9
        cmp     w9, #1
        csinc   w9, w9, wzr, hs
        str     w9, [x28, #M_KPA]
        mov     w21, #0                         // a
6:      ldr     w9, [x28, #M_ARCS]
        cmp     w21, w9
        b.hs    7f
        cbz     w20, 7f
        mov     w0, #18
        bl      fr_below
        add     x10, x28, #M_USED
61:     ldrb    w9, [x10, x0]
        cbz     w9, 62f
        add     w0, w0, #1
        cmp     w0, #18
        csel    w0, wzr, w0, eq
        b       61b
62:     mov     w9, #1
        strb    w9, [x10, x0]
        scvtf   s0, w0
        ldr     s7, [x28, #M_DTH]
        fmul    s1, s0, s7
        LC      s6, C_0_04
        fmul    s2, s7, s6
        fadd    s1, s1, s2                      // th0
        str     s1, [x28, #M_TH0]
        fmov    s5, #1.0
        fadd    s0, s0, s5
        fsub    s0, s0, s6
        fmul    s0, s0, s7                      // th1
        fsub    s0, s0, s1
        ldr     w22, [x28, #M_KPA]              // k = min(k_per_arc, remain)
        cmp     w22, w20
        csel    w22, w20, w22, hi
        scvtf   s1, w22
        fdiv    s0, s0, s1
        str     s0, [x28, #M_STEP]
        bl      fr_f32
        ldr     s7, [x28, #M_STEP]
        fmul    s0, s0, s7
        ldr     s7, [x28, #M_TH0]
        fadd    s0, s0, s7                      // start
        str     s0, [x28, #M_TH0]
        ldr     s0, [x28, #M_STEP]
        bl      sinf
        str     s0, [x28, #M_SN]
        ldr     s0, [x28, #M_STEP]
        bl      cosf
        str     s0, [x28, #M_C]
        ldr     s0, [x28, #M_TH0]
        bl      cosf
        str     s0, [x28, #M_UX]
        ldr     s0, [x28, #M_TH0]
        bl      sinf
        str     s0, [x28, #M_UY]
        bl      layer_type
        str     w0, [x28, #M_TT]
        mov     w23, w22
63:     cbz     w23, 64f
        ldr     s1, [x28, #M_THICK]
        bl      jit
        ldr     s7, [x28, #M_R]
        fadd    s0, s0, s7                      // r + rr
        ldr     s7, [x28, #M_UX]
        fmul    s2, s0, s7
        ldr     s7, [x28, #M_CX]
        fadd    s2, s2, s7
        ldr     s7, [x28, #M_UY]
        fmul    s1, s0, s7
        ldr     s7, [x28, #M_CY]
        fadd    s1, s1, s7
        fmov    s0, s2
        ldr     w0, [x28, #M_TT]
        bl      emit
        ldr     s0, [x28, #M_UX]                // rotate by {c, sn}
        ldr     s1, [x28, #M_UY]
        ldr     s4, [x28, #M_C]
        ldr     s5, [x28, #M_SN]
        fmul    s2, s0, s4
        fmul    s3, s1, s5
        fsub    s2, s2, s3
        fmul    s3, s0, s5
        fmul    s6, s1, s4
        fadd    s3, s3, s6
        str     s2, [x28, #M_UX]
        str     s3, [x28, #M_UY]
        sub     w23, w23, #1
        b       63b
64:     sub     w20, w20, w22
        add     w21, w21, #1
        b       6b
        // leftovers: loosely around the ring
7:      cbz     w20, 8f
        mov     w0, #18
        bl      fr_below
        scvtf   s0, w0
        str     s0, [x28, #M_ANG]
        bl      fr_f32
        ldr     s7, [x28, #M_ANG]
        fadd    s0, s0, s7
        ldr     s7, [x28, #M_DTH]
        fmul    s0, s0, s7
        str     s0, [x28, #M_ANG]
        ldr     s1, [x28, #M_THICK]
        bl      jit
        ldr     s7, [x28, #M_R]
        fadd    s0, s0, s7
        str     s0, [x28, #M_RR]
        bl      layer_type
        str     w0, [x28, #M_TT]
        ldr     s0, [x28, #M_ANG]
        bl      cosf
        ldr     s7, [x28, #M_RR]
        fmul    s0, s0, s7
        ldr     s7, [x28, #M_CX]
        fadd    s0, s0, s7
        str     s0, [x28, #M_X]
        ldr     s0, [x28, #M_ANG]
        bl      sinf
        ldr     s7, [x28, #M_RR]
        fmul    s1, s0, s7
        ldr     s7, [x28, #M_CY]
        fadd    s1, s1, s7
        ldr     s0, [x28, #M_X]
        ldr     w0, [x28, #M_TT]
        bl      emit
        sub     w20, w20, #1
        b       7b
8:      add     w19, w19, #1
        b       5b
9:      LEAVE   M_FRAME

// push type w0 onto layer w1 (lists of up to 64 at s_buf, lengths in the
// caller's frame x28 at M_LEN). Clobbers x9-x12.
push_layer:
        add     x9, x28, #M_LEN
        ldr     w10, [x9, w1, uxtw #2]
        cmp     w10, #64
        b.hs    1f
        lsl     w11, w1, #6
        add     w11, w11, w10
        ADR_L   x12, s_buf
        strb    w0, [x12, x11]
        add     w10, w10, #1
        str     w10, [x9, w1, uxtw #2]
1:      ret

// w0 = types_here[usize(0..len)] for layer w19 (caller's frame x28)
layer_type:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        add     x9, x28, #M_LEN
        ldr     w0, [x9, x19, lsl #2]
        bl      fr_below
        lsl     w9, w19, #6
        add     w9, w9, w0
        ADR_L   x10, s_buf
        ldrb    w0, [x10, x9]
        ldp     x29, x30, [sp], #16
        ret

// --------------------------------------------------------------- random
// uniform scatter: type, x, y (the order of pl-box's random_population,
// but drawn from fastrand rather than rand's SmallRng)
sp_random:
        ENTER   16
        BASES
        ldr     w19, [x27, #S_N]
1:      cbz     w19, 9f
        ldr     w0, [x27, #S_K]
        bl      fr_below
        mov     w20, w0
        bl      fr_f32
        ldr     s7, [x27, #S_W]
        fmul    s0, s0, s7
        str     s0, [x28]
        bl      fr_f32
        ldr     s7, [x27, #S_H]
        fmul    s1, s0, s7
        ldr     s0, [x28]
        mov     w0, w20
        bl      emit
        sub     w19, w19, #1
        b       1b
9:      LEAVE   16

// --------------------------------------------------------------- entry points
// u32 pl_spawn_raw(u32 layout, u32 n, u32 k, float w, float h,
//                  float *x, float *y, i32 *t): run one layout from the
// current pl_frng state into the given arrays, unwrapped (exactly pl-box's
// coordinates). Returns the number of particles written (always n).
        .globl pl_spawn_raw
        .type pl_spawn_raw, %function
pl_spawn_raw:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        ADR_L   x9, s_px
        str     w1, [x9, #S_N]
        str     w2, [x9, #S_K]
        str     s0, [x9, #S_W]
        str     s1, [x9, #S_H]
        str     x3, [x9, #S_PX]
        str     x4, [x9, #S_PY]
        str     x5, [x9, #S_PT]
        str     wzr, [x9, #S_CNT]
        cbz     w1, 9f
        cbz     w2, 9f
        cmp     w0, #NSPAWNS
        csel    w0, wzr, w0, hs
        ADR_L   x10, spawn_fns
        ldr     x10, [x10, w0, uxtw #3]
        blr     x10
9:      ADR_L   x9, s_px
        ldr     w0, [x9, #S_CNT]
        ldp     x29, x30, [sp], #16
        ret

// \s wrapped into [0, \e) (one wrap step as pl-box's Wrap, then anything
// still outside, a NaN or x + w rounding up to w, goes to 0)
.macro WRAP1 s, e
        fcmp    \s, #0.0
        b.ge    1f
        fadd    \s, \s, \e
        b       2f
1:      fcmp    \s, \e
        b.lt    2f
        fsub    \s, \s, \e
2:      fcmp    \s, #0.0
        b.lt    3f
        fcmp    \s, \e
        b.lt    4f
3:      fmov    \s, wzr
4:
.endm

// void pl_spawn(u32 layout): respawn the pl.N particles of pl.K types in
// that layout (seeding wyrand from pl's splitmix stream), wrap into the
// world as pl-box's Wrap boundary does, zero velocities, ids 0..N-1, bin.
        .globl pl_spawn
        .type pl_spawn, %function
pl_spawn:
        ENTER
        mov     w19, w0
        cmp     w19, #NSPAWNS
        csel    w19, wzr, w19, hs
        ADR_L   x9, pl_spawn_cur
        str     w19, [x9]
        bl      pl_rng_u64
        ADR_L   x9, pl_frng
        str     x0, [x9]
        ADR_L   x20, pl
        mov     w0, w19
        ldr     w1, [x20, #PL_N]
        ldr     w2, [x20, #PL_K]
        ldr     s0, [x20, #PL_W]
        ldr     s1, [x20, #PL_H]
        ldr     x3, [x20, #PL_NX]
        ldr     x4, [x20, #PL_NY]
        ldr     x5, [x20, #PL_T]
        bl      pl_spawn_raw
        ldr     x1, [x20, #PL_NX]
        ldr     x2, [x20, #PL_NY]
        ldr     x3, [x20, #PL_ID]
        ldr     x4, [x20, #PL_VX]
        ldr     x5, [x20, #PL_VY]
        ldr     x6, [x20, #PL_T]
        ldr     w7, [x20, #PL_K]
        ldr     w8, [x20, #PL_N]
        ldr     s4, [x20, #PL_W]
        ldr     s5, [x20, #PL_H]
        mov     x9, #0
5:      cmp     w9, w8
        b.hs    6f
        ldr     s0, [x1, x9, lsl #2]
        WRAP1   s0, s4
        str     s0, [x1, x9, lsl #2]
        ldr     s0, [x2, x9, lsl #2]
        WRAP1   s0, s5
        str     s0, [x2, x9, lsl #2]
        ldr     w10, [x6, x9, lsl #2]           // defensive: type < K
        cmp     w10, w7
        b.lo    51f
        str     wzr, [x6, x9, lsl #2]
51:     str     w9, [x3, x9, lsl #2]
        str     wzr, [x4, x9, lsl #2]
        str     wzr, [x5, x9, lsl #2]
        add     x9, x9, #1
        b       5b
6:      UNFRAME
        b       pl_bin

// u32 pl_spawn_pick(void): pl-box's spawn_pattern choice, 0..15 weighted
// (soft_clusters 3/15, star_fixed for pl-box's star; never ring, spiral,
// line_mixed, random or star)
        .globl pl_spawn_pick
        .type pl_spawn_pick, %function
pl_spawn_pick:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        bl      pl_rng_u64
        lsr     x0, x0, #32
        mov     x9, #15
        mul     x0, x0, x9
        lsr     x0, x0, #32
        ADR_L   x9, pattern_map
        ldrb    w0, [x9, x0]
        ldp     x29, x30, [sp], #16
        ret

// int pl_spawn_find(const char *name): layout index by name
// (case-insensitive, '-' accepted for '_'), or -1
        .globl pl_spawn_find
        .type pl_spawn_find, %function
pl_spawn_find:
        ENTER   64
        mov     x9, #0                          // copy with '-' -> '_'
1:      ldrb    w10, [x0, x9]
        cmp     w10, #'-'
        b.ne    2f
        mov     w10, #'_'
2:      strb    w10, [sp, x9]
        cbz     w10, 3f
        add     x9, x9, #1
        cmp     x9, #63
        b.lo    1b
        strb    wzr, [sp, x9]
3:      mov     w19, #0
4:      cmp     w19, #NSPAWNS
        b.hs    8f
        ADR_L   x10, pl_spawn_names
        ldr     x1, [x10, x19, lsl #3]
        mov     x0, sp
        bl      strcasecmp
        cbz     w0, 9f
        add     w19, w19, #1
        b       4b
8:      mov     w19, #-1
9:      mov     w0, w19
        LEAVE   64
