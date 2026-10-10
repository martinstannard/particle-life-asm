# Software rendering into an ARGB8888 pixel buffer, and a PPM writer.

        .intel_syntax noprefix
        .include "layout.inc"

        .section .rodata
        .balign 64
palette:                        # 16 type colours, ARGB
        .long 0xFFFF4D4D, 0xFF4DA6FF, 0xFF5CE65C, 0xFFFFD24D
        .long 0xFFD966FF, 0xFF4DFFE1, 0xFFFF944D, 0xFFFF66B3
        .long 0xFFB3FF4D, 0xFF8C8CFF, 0xFFFFFFFF, 0xFF33CC99
        .long 0xFFCC3333, 0xFF3366CC, 0xFFE6B380, 0xFF999999
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
        lea     r11, [rip + palette]
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
