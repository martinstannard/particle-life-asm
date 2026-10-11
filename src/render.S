# Software rendering into an ARGB8888 pixel buffer, and a PPM writer.

        .intel_syntax noprefix
        .include "layout.inc"

# Type colours come from pl_colors (src/palettes.S). The overlay text is
# drawn with the 8x8 font in src/font.S.

        .section .rodata
s_wb:   .asciz "wb"
s_ppm:  .asciz "P6\n%d %d\n255\n"

        .text

.set BG, 0xFF0A0A10

# void pl_render(u32 *buf, u32 w, u32 h): clear, then a 2x2 dot per particle.
# The world is drawn 1:1 (world size == buffer size).
        .globl pl_render
pl_render:
        push    rbx
        push    r12
        mov     r8, rdi                 # buf
        mov     r9d, esi                # w
        mov     r10d, edx               # h
        mov     eax, esi
        imul    eax, edx
        mov     ecx, eax
        mov     eax, BG
        rep stosd

        lea     r12, [rip + pl]
        mov     rsi, [r12 + PL_X]
        mov     rdi, [r12 + PL_Y]
        mov     rdx, [r12 + PL_T]
        lea     ebx, [r9d - 2]          # max px
        mov     r12d, [r12 + PL_N]
        lea     ecx, [r10d - 2]         # max py
        xor     r10d, r10d
1:      cmp     r10d, r12d
        jae     2f
        vcvttss2si eax, [rsi + r10*4]
        cmp     eax, ebx
        cmova   eax, ebx                # unsigned clamp
        vcvttss2si r11d, [rdi + r10*4]  # temporarily py
        cmp     r11d, ecx
        cmova   r11d, ecx
        imul    r11d, r9d
        add     eax, r11d               # pixel index
        lea     r11, [rip + pl_colors]
        push    rcx
        mov     ecx, [rdx + r10*4]
        and     ecx, 15
        mov     ecx, [r11 + rcx*4]
        mov     [r8 + rax*4], ecx
        mov     [r8 + rax*4 + 4], ecx
        add     eax, r9d
        mov     [r8 + rax*4], ecx
        mov     [r8 + rax*4 + 4], ecx
        pop     rcx
        inc     r10d
        jmp     1b
2:      pop     r12
        pop     rbx
        ret

# int pl_write_ppm(const char *path, const u32 *buf, u32 w, u32 h)
        .globl pl_write_ppm
pl_write_ppm:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15
        push    rbp
        sub     rsp, 8                  # rsp aligned
        mov     r12, rsi                # buf
        mov     r13d, edx               # w
        mov     r14d, ecx               # h
        lea     rsi, [rip + s_wb]
        call    fopen@PLT
        test    rax, rax
        jz      9f
        mov     r15, rax
        mov     rdi, r15
        lea     rsi, [rip + s_ppm]
        mov     edx, r13d
        mov     ecx, r14d
        xor     eax, eax
        call    fprintf@PLT
        lea     edi, [r13d + r13d*2]
        call    malloc@PLT
        mov     rbp, rax                # one RGB row
        xor     ebx, ebx                # pixel index
        mov     eax, r13d
        imul    eax, r14d
        mov     [rsp], eax
1:      cmp     ebx, [rsp]
        jae     3f
        xor     ecx, ecx                # x
2:      mov     eax, [r12 + rbx*4]
        lea     edx, [ecx + ecx*2]
        mov     r8d, eax
        shr     r8d, 16
        mov     [rbp + rdx], r8b        # R
        mov     [rbp + rdx + 2], al     # B
        shr     eax, 8
        mov     [rbp + rdx + 1], al     # G
        inc     ebx
        inc     ecx
        cmp     ecx, r13d
        jb      2b
        mov     rdi, rbp
        mov     esi, 3
        mov     edx, r13d
        mov     rcx, r15
        call    fwrite@PLT
        jmp     1b
3:      mov     rdi, rbp
        call    free@PLT
        mov     rdi, r15
        call    fclose@PLT
        xor     eax, eax
        jmp     8f
9:      mov     eax, -1
8:      add     rsp, 8
        pop     rbp
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

# ------------------------------------------------------------------ text
# void pl_draw_text(u32 *buf, u32 w, u32 h, int x, int y, const char *s,
#                   u32 argb, u32 scale)
# Draws s with the 8x8 font, each font pixel a scale x scale block, first
# a black drop shadow offset by (scale, scale), then the text in argb.
# '\n' starts a new line 10*scale below; other bytes outside 32..126 draw
# as '?'. Clipped to the buffer.
        .globl pl_draw_text
pl_draw_text:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15
        push    rbp
        sub     rsp, 56                 # rsp aligned
        mov     [rsp], rdi              # buf
        mov     [rsp + 8], esi          # w
        mov     [rsp + 12], edx         # h
        mov     [rsp + 16], ecx         # x
        mov     [rsp + 20], r8d         # y
        mov     [rsp + 24], r9          # s
        mov     eax, [rsp + 56 + 56]    # argb (7th arg)
        mov     [rsp + 32], eax
        mov     eax, [rsp + 56 + 64]    # scale (8th arg)
        mov     ecx, 1
        cmp     eax, ecx
        cmovb   eax, ecx
        mov     [rsp + 36], eax
        # shadow
        mov     ecx, [rsp + 16]
        add     ecx, eax
        mov     r8d, [rsp + 20]
        add     r8d, eax
        mov     r9d, 0xFF000000
        call    glyphs
        mov     ecx, [rsp + 16]
        mov     r8d, [rsp + 20]
        mov     r9d, [rsp + 32]
        call    glyphs
        add     rsp, 56
        pop     rbp
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

# the string at [frame+24] from (ecx, r8d) in colour r9d; frame fields as
# set up by pl_draw_text (reached at rsp + 8)
.set TF, 8
glyphs:
        mov     [rsp + TF + 40], ecx    # line start x
        mov     [rsp + TF + 44], r9d    # colour
        mov     r12d, ecx               # pen x
        mov     r13d, r8d               # pen y
        mov     r14, [rsp + TF + 24]    # s
1:      movzx   eax, byte ptr [r14]
        test    eax, eax
        jz      9f
        inc     r14
        cmp     eax, 10
        jne     2f
        mov     r12d, [rsp + TF + 40]
        mov     eax, [rsp + TF + 36]
        lea     eax, [eax + eax*4]
        lea     r13d, [r13d + eax*2]    # y += 10 scale
        jmp     1b
2:      lea     ecx, [eax - 32]
        cmp     ecx, 94
        jbe     3f
        mov     ecx, '?' - 32
3:      lea     rbx, [rip + pl_font8]
        lea     rbx, [rbx + rcx*8]      # glyph rows
        xor     r15d, r15d              # row
4:      movzx   ebp, byte ptr [rbx + r15]
        xor     r11d, r11d              # col
5:      test    ebp, 0x80
        jz      7f
        # block at (pen_x + col*s, pen_y + row*s), s x s
        mov     eax, [rsp + TF + 36]
        mov     edx, r11d
        imul    edx, eax
        add     edx, r12d               # px0
        mov     ecx, r15d
        imul    ecx, eax
        add     ecx, r13d               # py0
        xor     r10d, r10d              # dy
6:      cmp     r10d, [rsp + TF + 36]
        jae     7f
        lea     r9d, [ecx + r10d]       # py
        cmp     r9d, [rsp + TF + 12]
        jae     65f                     # also catches negative
        xor     r8d, r8d                # dx
61:     cmp     r8d, [rsp + TF + 36]
        jae     65f
        lea     eax, [edx + r8d]        # px
        cmp     eax, [rsp + TF + 8]
        jae     64f
        mov     esi, r9d
        imul    esi, [rsp + TF + 8]
        add     esi, eax
        mov     rdi, [rsp + TF]
        mov     eax, [rsp + TF + 44]
        mov     [rdi + rsi*4], eax
64:     inc     r8d
        jmp     61b
65:     inc     r10d
        jmp     6b
7:      shl     ebp, 1
        and     ebp, 0xFF
        inc     r11d
        cmp     r11d, 8
        jb      5b
        inc     r15d
        cmp     r15d, 8
        jb      4b
        mov     eax, [rsp + TF + 36]
        lea     r12d, [r12d + eax*8]    # next cell
        jmp     1b
9:      ret
