// Colour palettes, AArch64 port of src/palettes.S (see there for the
// lift / expand / check steps). Data in src/palettes_data.S (shared).
// The arithmetic follows the x86 version operation by operation (the luma
// dot product sums (p0 + p1) + (p2 + p3) like DPPS, FMA where x86 uses
// FMA, round-to-nearest-even conversion), so the colours are the same.

        .include "layout.inc"
        .include "macros.inc"

        .section .rodata
        .balign 16
LUMA_W:   .float 0.2126, 0.7152, 0.0722, 0.0
F_LMIN:   .float 100.0
F_255:    .float 255.0
F_256:    .float 256.0
F_MIND2:  .float 3600.0                 // MINDIST = 60, squared

        .data
        .balign 64
        .globl pl_colors, pl_palette_cur
pl_colors:                              // ARGB per type, used by the renderer
        .long 0xFFFF4D4D, 0xFF4DA6FF, 0xFF5CE65C, 0xFFFFD24D
        .long 0xFFD966FF, 0xFF4DFFE1, 0xFFFF944D, 0xFFFF66B3
        .long 0xFFB3FF4D, 0xFF8C8CFF, 0xFFFFFFFF, 0xFF33CC99
        .long 0xFFCC3333, 0xFF3366CC, 0xFFE6B380, 0xFF999999
pl_palette_cur: .long -1                // -1 = the built-in colours above

        .bss
        .balign 16
lifted: .skip 16 * 16                   // lifted colours as {r, g, b, 0} floats
tmpcol: .skip 64                        // expansion output (ARGB)
qual:   .skip 4 * 256

        .text

// v0 = {r, g, b, 0} of 0xRRGGBB in w0. Clobbers w9-w11.
unpack:
        ubfx    w9, w0, #16, #8
        ubfx    w10, w0, #8, #8
        and     w11, w0, #255
        fmov    s0, w9
        mov     v0.s[1], w10
        mov     v0.s[2], w11
        ucvtf   v0.4s, v0.4s
        ret

// s1 = luma of v0, summed as DPPS does. Clobbers v1, v16 (LUMA_W), x9.
.macro LUMA
        LDRS    q16, LUMA_W, x9
        fmul    v1.4s, v0.4s, v16.4s
        faddp   v1.4s, v1.4s, v1.4s
        faddp   s1, v1.2s
.endm

// lift {r, g, b, 0} in v0 to luma >= LMIN (see the header of src/palettes.S)
// Clobbers v1-v5, v16-v18, x9.
lift:
        LUMA
        LDRS    s17, F_LMIN, x9
        LDRS    s18, F_255, x9
        fcmp    s1, s17
        b.ge    9f
        fcmp    s1, #0.0
        b.le    2f                              // black: blend only
        fmaxv   s3, v0.4s                       // max channel
        fdiv    s4, s17, s1                     // LMIN / L
        fdiv    s5, s18, s3                     // 255 / max
        fmin    s4, s4, s5
        fmul    v0.4s, v0.4s, v4.s[0]
        LUMA
        fcmp    s1, s17
        b.ge    9f
2:      fsub    s2, s17, s1                     // t = (LMIN - L) / (255 - L)
        fsub    s3, s18, s1
        fdiv    s2, s2, s3
        dup     v18.4s, v18.s[0]
        fsub    v3.4s, v18.4s, v0.4s
        fmla    v0.4s, v3.4s, v2.s[0]           // c + (255 - c) t
        mov     v0.s[3], wzr
9:      ret

// w0 = ARGB of {r, g, b, x} in v0 (rounded, clamped). Clobbers v1, v2, x9-x11.
pack:
        movi    v1.2d, #0
        fmax    v0.4s, v0.4s, v1.4s
        LDRS    s2, F_255, x9
        dup     v2.4s, v2.s[0]
        fmin    v0.4s, v0.4s, v2.4s
        fcvtns  v0.4s, v0.4s
        mov     w9, v0.s[0]
        mov     w10, v0.s[1]
        mov     w11, v0.s[2]
        lsl     w0, w9, #16
        orr     w0, w0, w10, lsl #8
        orr     w0, w0, w11
        orr     w0, w0, #0xFF000000
        ret

// void pl_palette_build(u32 p, u32 k, u32 *out): K ARGB colours of palette
// p into out[0..16) (slots >= K repeat the list cyclically)
        .globl pl_palette_build
        .type pl_palette_build, %function
pl_palette_build:
        ENTER
        mov     w20, w1                         // K
        mov     x21, x2                         // out
        ADR_L   x9, pl_palette_cols
        ldr     x22, [x9, w0, uxtw #3]
        ldr     w23, [x22], #4                  // len
        cmp     w23, #16
        b.ls    0f
        mov     w23, #16
0:      ADR_L   x24, lifted
        mov     w19, #0                         // lift every colour
1:      cmp     w19, w23
        b.hs    2f
        ldr     w0, [x22, x19, lsl #2]
        bl      unpack
        bl      lift
        str     q0, [x24, x19, lsl #4]
        add     w19, w19, #1
        b       1b
2:      mov     w19, #0                         // slot i
3:      cmp     w19, #16
        b.hs    9f
        cmp     w19, w20
        b.hs    7f
        cmp     w20, w23
        b.hi    5f
        mul     w9, w19, w23                    // K <= len: colour i*len/K
        udiv    w9, w9, w20
        ldr     q0, [x24, x9, lsl #4]
        b       6f
5:      sub     w9, w23, #1                     // K > len: t = i (len-1) / (K-1)
        mul     w9, w9, w19
        scvtf   s1, w9
        sub     w9, w20, #1
        scvtf   s2, w9
        fdiv    s1, s1, s2
        fcvtzs  w9, s1                          // a
        sub     w10, w23, #2
        cmp     w9, w10
        csel    w9, w10, w9, gt
        scvtf   s2, w9
        fsub    s1, s1, s2                      // f
        sxtw    x9, w9
        add     x10, x24, x9, lsl #4
        ldr     q0, [x10]
        ldr     q2, [x10, #16]
        fsub    v2.4s, v2.4s, v0.4s
        fmla    v0.4s, v2.4s, v1.s[0]
6:      bl      pack
        str     w0, [x21, x19, lsl #2]
        add     w19, w19, #1
        b       3b
7:      udiv    w9, w19, w20                    // unused slots: cycle the first K
        msub    w9, w9, w20, w19
        ldr     w9, [x21, x9, lsl #2]
        str     w9, [x21, x19, lsl #2]
        add     w19, w19, #1
        b       3b
9:      LEAVE

// float pl_palette_mindist2(u32 p, u32 k): smallest squared redmean distance
// between two of palette p's K colours (as built), 1e30 for K = 1
        .globl pl_palette_mindist2
        .type pl_palette_mindist2, %function
pl_palette_mindist2:
        ENTER   16
        str     d8, [sp]
        mov     w20, w1
        ADR_L   x2, tmpcol
        bl      pl_palette_build
        ADR_L   x21, tmpcol
        MOV32   w9, 0x7149f2ca                  // 1e30
        fmov    s8, w9
        mov     w19, #0                         // i
1:      cmp     w19, w20
        b.hs    9f
        mov     w22, #0                         // j < i
2:      cmp     w22, w19
        b.hs    8f
        ldr     w0, [x21, x19, lsl #2]
        ldr     w1, [x21, x22, lsl #2]
        bl      dist2
        fmin    s8, s8, s0
        add     w22, w22, #1
        b       2b
8:      add     w19, w19, #1
        b       1b
9:      fmov    s0, s8
        ldr     d8, [sp]
        LEAVE   16

// s0 = redmean distance^2 of ARGB w0, w1:
// (2 + rm/256) dr^2 + 4 dg^2 + (2 + (255 - rm)/256) db^2, rm = (r1 + r2)/2
// Clobbers x9-x12, v0-v7.
dist2:
        ubfx    w9, w0, #16, #8
        ubfx    w10, w1, #16, #8
        add     w11, w9, w10
        scvtf   s6, w11
        fmov    s7, #0.5
        fmul    s6, s6, s7                      // rm
        sub     w11, w9, w10
        scvtf   s1, w11                         // dr
        ubfx    w9, w0, #8, #8
        ubfx    w10, w1, #8, #8
        sub     w11, w9, w10
        scvtf   s2, w11                         // dg
        and     w9, w0, #255
        and     w10, w1, #255
        sub     w11, w9, w10
        scvtf   s3, w11                         // db
        LDRS    s7, F_256, x12
        fmov    s5, #2.0
        fdiv    s4, s6, s7
        fadd    s4, s4, s5
        fmul    s1, s1, s1
        fmul    s0, s1, s4
        fmul    s2, s2, s2
        fmov    s4, #4.0
        fmadd   s0, s2, s4, s0
        LDRS    s4, F_255, x12
        fsub    s4, s4, s6
        fdiv    s4, s4, s7
        fadd    s4, s4, s5
        fmul    s3, s3, s3
        fmadd   s0, s3, s4, s0
        ret

// int pl_palette_ok(u32 p, u32 k): 1 if palette p qualifies for K
        .globl pl_palette_ok
        .type pl_palette_ok, %function
pl_palette_ok:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        bl      pl_palette_mindist2
        LDRS    s1, F_MIND2, x9
        fcmp    s0, s1
        cset    w0, ge
        ldp     x29, x30, [sp], #16
        ret

// void pl_palette_set(u32 p): make p current and build pl_colors for pl.K
        .globl pl_palette_set
        .type pl_palette_set, %function
pl_palette_set:
        ADR_L   x9, pl_palette_cur
        str     w0, [x9]
        ADR_L   x9, pl
        ldr     w1, [x9, #PL_K]
        ADR_L   x2, pl_colors
        b       pl_palette_build

// void pl_palette_refresh(void): rebuild pl_colors for the current palette
// after a type-count change
        .globl pl_palette_refresh
        .type pl_palette_refresh, %function
pl_palette_refresh:
        LDRS    w0, pl_palette_cur, x9
        tbz     w0, #31, pl_palette_set
        ret

// u32 pl_palette_pick(void): a random palette qualifying for pl.K other than
// the current one; if none qualifies, the non-current one with the largest
// minimum distance
        .globl pl_palette_pick
        .type pl_palette_pick, %function
pl_palette_pick:
        ENTER   16
        ADR_L   x22, qual                       // qualifying list
        mov     w20, #0                         // count
        mov     w21, #-1                        // best fallback
        MOV32   w9, 0xff800000                  // -inf
        str     w9, [sp]                        // best distance
        mov     w19, #0
1:      LDRS    w9, pl_npalettes, x10
        cmp     w19, w9
        b.hs    3f
        LDRS    w9, pl_palette_cur, x10
        cmp     w19, w9
        b.eq    2f
        mov     w0, w19
        ADR_L   x9, pl
        ldr     w1, [x9, #PL_K]
        bl      pl_palette_mindist2
        ldr     s1, [sp]
        fcmp    s0, s1
        b.le    11f
        str     s0, [sp]
        mov     w21, w19
11:     LDRS    s1, F_MIND2, x9
        fcmp    s0, s1
        b.lt    2f
        str     w19, [x22, x20, lsl #2]
        add     w20, w20, #1
2:      add     w19, w19, #1
        b       1b
3:      mov     w0, w21
        cbz     w20, 9f
        bl      pl_rng_u64
        lsr     x0, x0, #32
        mul     x0, x0, x20
        lsr     x0, x0, #32
        ldr     w0, [x22, x0, lsl #2]
9:      LEAVE   16

// u32 pl_palette_next(int dir): the next (dir = 1) or previous (dir = -1)
// palette in list order that qualifies for pl.K; the current one if no
// other qualifies
        .globl pl_palette_next
        .type pl_palette_next, %function
pl_palette_next:
        ENTER
        mov     w20, w0                         // dir
        LDRS    w19, pl_palette_cur, x9
        tbz     w19, #31, 0f
        mov     w19, #-1
        cmp     w20, #0
        b.gt    0f
        mov     w19, #0
0:      LDRS    w21, pl_npalettes, x9
        mov     w22, w21                        // at most one full round
1:      add     w19, w19, w20
        tbz     w19, #31, 2f
        sub     w19, w21, #1
2:      cmp     w19, w21
        b.lo    3f
        mov     w19, #0
3:      LDRS    w9, pl_palette_cur, x10
        cmp     w19, w9
        b.eq    8f                              // wrapped all the way round
        subs    w22, w22, #1
        b.mi    8f
        mov     w0, w19
        ADR_L   x9, pl
        ldr     w1, [x9, #PL_K]
        bl      pl_palette_ok
        cbz     w0, 1b
8:      mov     w0, w19
        LEAVE

// int pl_palette_find(const char *name): index by name, case-insensitive,
// ' ' and '_' accepted for '-'; -1 if unknown
        .globl pl_palette_find
        .type pl_palette_find, %function
pl_palette_find:
        ENTER   64
        mov     x9, #0
1:      ldrb    w10, [x0, x9]
        cmp     w10, #' '
        b.eq    11f
        cmp     w10, #'_'
        b.ne    2f
11:     mov     w10, #'-'
2:      strb    w10, [sp, x9]
        cbz     w10, 3f
        add     x9, x9, #1
        cmp     x9, #63
        b.lo    1b
        strb    wzr, [sp, x9]
3:      mov     w19, #0
4:      LDRS    w9, pl_npalettes, x10
        cmp     w19, w9
        b.hs    8f
        ADR_L   x10, pl_palette_names
        ldr     x1, [x10, x19, lsl #3]
        mov     x0, sp
        bl      strcasecmp
        cbz     w0, 9f
        add     w19, w19, #1
        b       4b
8:      mov     w19, #-1
9:      mov     w0, w19
        LEAVE   64
