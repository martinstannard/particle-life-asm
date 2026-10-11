// Software rendering into an ARGB8888 pixel buffer, a PPM writer and the
// overlay text, AArch64 port of src/render.S. Type colours come from
// pl_colors (palettes.S), glyphs from pl_font8 (src/font.S, shared).
//
// Rotation for portrait panels is not done here: the window path rotates
// the finished texture on the GPU (SDL_RenderCopyEx, main.S), which costs
// no CPU time, instead of a per-frame 8 MB rotate-copy on the A72.

        .include "layout.inc"
        .include "macros.inc"

        .section .rodata
s_wb:   .asciz "wb"
s_ppm:  .asciz "P6\n%d %d\n255\n"

        .text

.set BG, 0xFF0A0A10

// void pl_render(u32 *buf, u32 w, u32 h): clear, then a 2x2 dot per particle.
// The world is drawn 1:1 (world size == buffer size).
        .globl pl_render
        .type pl_render, %function
pl_render:
        umull   x9, w1, w2                      // pixels
        MOV32   w10, BG
        dup     v0.4s, w10
        mov     v1.16b, v0.16b
        mov     x11, x0
        lsr     x12, x9, #3                     // 8 pixels (32 bytes) per store
        cbz     x12, 2f
1:      stp     q0, q1, [x11], #32
        subs    x12, x12, #1
        b.ne    1b
2:      and     x12, x9, #7
        cbz     x12, 4f
3:      str     w10, [x11], #4
        subs    x12, x12, #1
        b.ne    3b

4:      ADR_L   x9, pl
        ldr     x3, [x9, #PL_X]
        ldr     x4, [x9, #PL_Y]
        ldr     x5, [x9, #PL_T]
        ldr     w6, [x9, #PL_N]
        sub     w7, w1, #2                      // max px
        sub     w8, w2, #2                      // max py
        ADR_L   x13, pl_colors
        mov     w9, w1                          // row pitch in pixels
        mov     x10, #0
5:      cmp     w10, w6
        b.hs    6f
        ldr     s0, [x3, x10, lsl #2]
        ldr     s1, [x4, x10, lsl #2]
        fcvtzs  w11, s0
        cmp     w11, w7
        csel    w11, w7, w11, hi                // unsigned clamp
        fcvtzs  w12, s1
        cmp     w12, w8
        csel    w12, w8, w12, hi
        madd    w11, w12, w9, w11               // pixel index
        ldr     w12, [x5, x10, lsl #2]
        and     w12, w12, #15
        ldr     w12, [x13, x12, lsl #2]
        orr     x12, x12, x12, lsl #32          // two pixels
        add     x14, x0, x11, lsl #2
        str     x12, [x14]
        add     x14, x14, x9, lsl #2
        str     x12, [x14]
        add     x10, x10, #1
        b       5b
6:      ret

// int pl_write_ppm(const char *path, const u32 *buf, u32 w, u32 h)
        .globl pl_write_ppm
        .type pl_write_ppm, %function
pl_write_ppm:
        ENTER
        mov     x20, x1                         // buf
        mov     w21, w2                         // w
        mov     w22, w3                         // h
        ADR_L   x1, s_wb
        bl      fopen
        cbz     x0, 9f
        mov     x23, x0
        ADR_L   x1, s_ppm
        mov     w2, w21
        mov     w3, w22
        bl      fprintf
        add     w0, w21, w21, lsl #1
        bl      malloc
        mov     x24, x0                         // one RGB row
        umull   x25, w21, w22                   // pixels
        mov     x19, #0                         // pixel index
1:      cmp     x19, x25
        b.hs    3f
        mov     x9, #0                          // x
        mov     x10, x24
2:      ldr     w11, [x20, x19, lsl #2]
        lsr     w12, w11, #16
        strb    w12, [x10]                      // R
        lsr     w12, w11, #8
        strb    w12, [x10, #1]                  // G
        strb    w11, [x10, #2]                  // B
        add     x10, x10, #3
        add     x19, x19, #1
        add     w9, w9, #1
        cmp     w9, w21
        b.lo    2b
        mov     x0, x24
        mov     x1, #3
        mov     w2, w21
        mov     x3, x23
        bl      fwrite
        b       1b
3:      mov     x0, x24
        bl      free
        mov     x0, x23
        bl      fclose
        mov     w0, #0
        LEAVE
9:      mov     w0, #-1
        LEAVE

// ------------------------------------------------------------------ text
// void pl_draw_text(u32 *buf, u32 w, u32 h, int x, int y, const char *s,
//                   u32 argb, u32 scale)
// Draws s with the 8x8 font, each font pixel a scale x scale block, first
// a black drop shadow offset by (scale, scale), then the text in argb.
// '\n' starts a new line 10*scale below; other bytes outside 32..126 draw
// as '?'. Clipped to the buffer.
        .globl pl_draw_text
        .type pl_draw_text, %function
pl_draw_text:
        ENTER
        mov     x19, x0                         // buf
        mov     w20, w1                         // w
        mov     w21, w2                         // h
        mov     w22, w3                         // x
        mov     w23, w4                         // y
        mov     x24, x5                         // s
        mov     w25, w6                         // argb
        cmp     w7, #1
        csinc   w26, w7, wzr, hs                // scale >= 1
        // shadow
        add     w0, w22, w26
        add     w1, w23, w26
        mov     w2, #0xFF000000
        bl      glyphs
        mov     w0, w22
        mov     w1, w23
        mov     w2, w25
        bl      glyphs
        LEAVE

// the string x24 from (w0, w1) in colour w2; buffer and sizes in x19..w21,
// scale in w26 (pl_draw_text's registers). Leaf: uses x0-x17.
glyphs:
        mov     w3, w0                          // line start x
        mov     w4, w0                          // pen x
        mov     w5, w1                          // pen y
        mov     x6, x24                         // s
        ADR_L   x7, pl_font8
1:      ldrb    w8, [x6], #1
        cbz     w8, 9f
        cmp     w8, #10
        b.ne    2f
        mov     w4, w3
        add     w9, w26, w26, lsl #2
        add     w5, w5, w9, lsl #1              // y += 10 scale
        b       1b
2:      sub     w8, w8, #32
        cmp     w8, #94
        b.ls    3f
        mov     w8, #'?' - 32
3:      add     x9, x7, x8, lsl #3              // glyph rows
        mov     w10, #0                         // row
4:      ldrb    w11, [x9, x10]
        mov     w12, #0                         // col
5:      tbz     w11, #7, 7f
        // block at (pen_x + col*s, pen_y + row*s), s x s
        madd    w13, w12, w26, w4               // px0
        madd    w14, w10, w26, w5               // py0
        mov     w15, #0                         // dy
6:      cmp     w15, w26
        b.hs    7f
        add     w16, w14, w15                   // py
        cmp     w16, w21
        b.hs    65f                             // also catches negative
        mov     w17, #0                         // dx
61:     cmp     w17, w26
        b.hs    65f
        add     w0, w13, w17                    // px
        cmp     w0, w20
        b.hs    64f
        madd    w1, w16, w20, w0
        str     w2, [x19, x1, lsl #2]
64:     add     w17, w17, #1
        b       61b
65:     add     w15, w15, #1
        b       6b
7:      lsl     w11, w11, #1
        and     w11, w11, #0xFF
        add     w12, w12, #1
        cmp     w12, #8
        b.lo    5b
        add     w10, w10, #1
        cmp     w10, #8
        b.lo    4b
        add     w4, w4, w26, lsl #3             // next cell
        b       1b
9:      ret
