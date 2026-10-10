# Spawn layouts ported from pl-box (crates/pl-core/src/simulation.rs):
# spawn_pie ... spawn_star and the weighted chooser spawn_pattern.
#
# pl-box draws every spawn from fastrand's global generator (wyrand). The
# same generator is implemented here (fr_u64, fr_f32 = fastrand::f32,
# fr_below = fastrand::usize(0..n), fr_bool = fastrand::bool), the trig goes
# through libm like Rust's f32::sin / cos / atan2 / powf, and the float
# arithmetic follows the Rust source operation by operation without FMA, so
# with the same seed a layout is bit-identical to pl-box's (checked by
# tests/test_spawns.c against tests/plbox_spawns.txt).
#
# Each layout appends exactly N particles (x, y, type) through `emit` into
# raw arrays; pl_spawn then wraps them into the world like pl-box's Wrap
# boundary does on its first step, and bins them.

        .intel_syntax noprefix
        .include "layout.inc"

.set NSPAWNS, 17

        .section .rodata
        .balign 16
C_0:      .float 0.0
C_1:      .float 1.0
C_2:      .float 2.0
C_HALF:   .float 0.5
C_2M63:   .float 1.0842021724855044e-19     # 1 / 2^63
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

# layout names (pl-box's bin/render.rs spelling); "random" is the old
# uniform scatter (pl-box's random_population), "star_fixed" is not in
# pl-box (see sp_star)
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

# spawn_pattern: rng.gen_range(0..15) -> layout, soft_clusters 3 of 15
pattern_map:
        .byte 0, 1, 10, 3, 4, 6, 8, 9, 12, 13, 14, 15, 5, 5, 5

        .section .data.rel.ro, "aw"
        .balign 8
        .globl pl_spawn_names
pl_spawn_names:
        .quad sn00, sn01, sn02, sn03, sn04, sn05, sn06, sn07, sn08
        .quad sn09, sn10, sn11, sn12, sn13, sn14, sn15, sn16
spawn_fns:
        .quad sp_pie, sp_line, sp_ring, sp_rainbow_ring, sp_rainbow_rings
        .quad sp_soft_clusters, sp_radiant_fans, sp_spiral, sp_twin_spirals
        .quad sp_spiral_arms, sp_blocks, sp_line_mixed, sp_stripes
        .quad sp_polar_maze, sp_heart, sp_star, sp_random

        .data
        .balign 8
        .globl pl_frng, pl_spawn_cur
pl_frng:      .quad 0           # wyrand state (fastrand's Rng.0)
pl_spawn_cur: .long 0           # layout of the last spawn

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
s_buf:  .skip 4096              # per-layout scratch (block order, lists)

        .text

# --------------------------------------------------------------- frame
# ENTER/LEAVE: rbp frame, all callee-saved registers, \frame bytes of
# locals at [rsp]; \frame must be 8 mod 16 so calls are aligned.
.macro ENTER frame
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, \frame
.endm
.macro LEAVE frame
        add     rsp, \frame
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        pop     rbp
        ret
.endm

# float -> usize like Rust `as` for the values seen here (negative -> 0)
.macro F2U r, x, tmp
        vcvttss2si \r, \x
        xor     \tmp, \tmp
        test    \r, \r
        cmovs   \r, \tmp
.endm

.macro CALLF fn
        call    \fn@PLT
.endm

# --------------------------------------------------------------- wyrand
# fastrand 2.4: s = state + C0; state = s; t = s * (s ^ C1) (128 bit);
# return lo(t) ^ hi(t). Clobbers rax, rcx, rdx.
        .globl pl_fr_u64
pl_fr_u64:
fr_u64:
        mov     rax, [rip + pl_frng]
        movabs  rcx, 0x2d358dccaa6c78a5
        add     rax, rcx
        mov     [rip + pl_frng], rax
        movabs  rcx, 0x8bb84b93962eacc9
        xor     rcx, rax
        mul     rcx
        xor     rax, rdx
        ret

# xmm0 = fastrand::f32(): (u64 >> 1) as f32 / 2^63, redrawn if it rounds to
# 1.0. Clobbers rax, rcx, rdx (no other xmm).
fr_f32:
1:      call    fr_u64
        shr     rax, 1
        vcvtsi2ss xmm0, xmm0, rax
        vmulss  xmm0, xmm0, [rip + C_2M63]
        vucomiss xmm0, [rip + C_1]
        jae     1b
        ret

# rax = fastrand::usize(0..rdi) (Lemire, with fastrand's rejection step).
# Clobbers rcx, rdx, rsi, r8, r9.
fr_below:
        push    rbx
        mov     rbx, rdi
        call    fr_u64
        mul     rbx
        cmp     rax, rbx
        jae     3f
        mov     r8, rax                 # lo
        mov     rsi, rdx                # hi
        mov     rax, rbx
        neg     rax
        xor     edx, edx
        div     rbx
        mov     r9, rdx                 # t = n.wrapping_neg() % n
1:      cmp     r8, r9
        jae     2f
        call    fr_u64
        mul     rbx
        mov     r8, rax
        mov     rsi, rdx
        jmp     1b
2:      mov     rax, rsi
        pop     rbx
        ret
3:      mov     rax, rdx
        pop     rbx
        ret

# eax = fastrand::bool() = (u32 as u8) % 2 == 0. Clobbers rcx, rdx.
fr_bool:
        call    fr_u64
        not     eax
        and     eax, 1
        ret

# xmm0 = f()*2*R - R for R = xmm1 (kept). Clobbers rax, rcx, rdx.
sym:
        call    fr_f32
        vaddss  xmm0, xmm0, xmm0
        vmulss  xmm0, xmm0, xmm1
        vsubss  xmm0, xmm0, xmm1
        ret

# xmm0 = (f()*2 - 1) * T for T = xmm1 (kept). Clobbers rax, rcx, rdx.
jit:
        call    fr_f32
        vaddss  xmm0, xmm0, xmm0
        vsubss  xmm0, xmm0, [rip + C_1]
        vmulss  xmm0, xmm0, xmm1
        ret

# append (xmm0, xmm1, edi) unless N are already out. Clobbers rax, rcx.
emit:
        mov     eax, [rip + s_cnt]
        cmp     eax, [rip + s_n]
        jae     1f
        mov     rcx, [rip + s_px]
        vmovss  [rcx + rax*4], xmm0
        mov     rcx, [rip + s_py]
        vmovss  [rcx + rax*4], xmm1
        mov     rcx, [rip + s_pt]
        mov     [rcx + rax*4], edi
        inc     eax
        mov     [rip + s_cnt], eax
1:      ret

# perm(u32 *a = rdi, u32 len = esi): a = 0..len, then pl-box's shuffle
# `for i in (1..len).rev() { a.swap(i, fastrand::usize(0..=i)) }`.
# Clobbers rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11.
perm:
        xor     eax, eax
1:      cmp     eax, esi
        jae     2f
        mov     [rdi + rax*4], eax
        inc     eax
        jmp     1b
2:      mov     r10, rdi
        lea     r11d, [esi - 1]         # i
3:      cmp     r11d, 1
        jl      4f
        lea     edi, [r11d + 1]
        call    fr_below
        mov     ecx, [r10 + r11*4]
        mov     edx, [r10 + rax*4]
        mov     [r10 + r11*4], edx
        mov     [r10 + rax*4], ecx
        dec     r11d
        jmp     3b
4:      ret

# xmm0 = min(w, h)
wh_min:
        vmovss  xmm0, [rip + s_w]
        vminss  xmm0, xmm0, [rip + s_h]
        ret

# --------------------------------------------------------------- pie
# spawn_pie_gap(gap 0.25): rejection-sampled disc, type by angular wedge
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
        ENTER   40
        vmovss  xmm0, [rip + s_w]
        vmulss  xmm0, xmm0, [rip + C_HALF]
        vmovss  [rsp + P_CX], xmm0
        vmovss  xmm0, [rip + s_h]
        vmulss  xmm0, xmm0, [rip + C_HALF]
        vmovss  [rsp + P_CY], xmm0
        call    wh_min
        vmulss  xmm0, xmm0, [rip + C_0_45]
        vmovss  [rsp + P_RM], xmm0
        vmulss  xmm0, xmm0, xmm0
        vmovss  [rsp + P_RM2], xmm0
        vcvtsi2ss xmm1, xmm1, dword ptr [rip + s_k]
        vmovss  [rsp + P_KF], xmm1
        vmovss  xmm0, [rip + C_1]
        vsubss  xmm0, xmm0, [rip + C_0_25]
        vdivss  xmm0, xmm0, xmm1
        vmovss  [rsp + P_WEDGE], xmm0
        mov     r14d, [rip + s_n]
        lea     r13, [r14*4]            # attempts limit
        xor     r12d, r12d              # attempts
1:      cmp     [rip + s_cnt], r14d
        jae     5f
        cmp     r12, r13
        jae     5f
        inc     r12
        vmovss  xmm1, [rsp + P_RM]
        call    sym
        vmovss  [rsp + P_DX], xmm0
        call    sym
        vmovss  [rsp + P_DY], xmm0
        vmulss  xmm2, xmm0, xmm0
        vmovss  xmm3, [rsp + P_DX]
        vmulss  xmm3, xmm3, xmm3
        vaddss  xmm3, xmm3, xmm2
        vucomiss xmm3, [rsp + P_RM2]
        ja      1b
        vmovss  xmm0, [rsp + P_DY]
        vmovss  xmm1, [rsp + P_DX]
        CALLF   atan2f
        vdivss  xmm0, xmm0, [rip + C_TAU]
        vaddss  xmm0, xmm0, [rip + C_1]
        vmovss  xmm1, [rip + C_1]
        CALLF   fmodf
        vmovss  [rsp + P_ANG], xmm0
        xor     r15d, r15d              # k
2:      cmp     r15d, [rip + s_k]
        jae     1b
        vcvtsi2ss xmm0, xmm0, r15d
        vdivss  xmm0, xmm0, [rsp + P_KF]        # start
        vaddss  xmm1, xmm0, [rsp + P_WEDGE]     # end
        vmovss  xmm2, [rsp + P_ANG]
        vucomiss xmm2, xmm0
        jb      3f
        vucomiss xmm2, xmm1
        jae     3f
        vmovss  xmm0, [rsp + P_CX]
        vaddss  xmm0, xmm0, [rsp + P_DX]
        vmovss  xmm1, [rsp + P_CY]
        vaddss  xmm1, xmm1, [rsp + P_DY]
        mov     edi, r15d
        call    emit
        jmp     1b
3:      inc     r15d
        jmp     2b
        # fallback: random type anywhere in the disc
5:      cmp     [rip + s_cnt], r14d
        jae     9f
        mov     edi, [rip + s_k]
        call    fr_below
        mov     r15d, eax
        vmovss  xmm1, [rsp + P_RM]
        call    sym
        vmovss  [rsp + P_DX], xmm0
        call    sym
        vmovss  [rsp + P_DY], xmm0
        vmulss  xmm2, xmm0, xmm0
        vmovss  xmm3, [rsp + P_DX]
        vmulss  xmm3, xmm3, xmm3
        vaddss  xmm3, xmm3, xmm2
        vucomiss xmm3, [rsp + P_RM2]
        ja      5b
        vmovss  xmm0, [rsp + P_CX]
        vaddss  xmm0, xmm0, [rsp + P_DX]
        vmovss  xmm1, [rsp + P_CY]
        vaddss  xmm1, xmm1, [rsp + P_DY]
        mov     edi, r15d
        call    emit
        jmp     5b
9:      LEAVE   40

# --------------------------------------------------------------- line
# spawn_line (r12d = 0): band of height 0.2 h, type by x box;
# spawn_line_mixed (r12d = 1): same band, uniform type
.set L_BOXW, 0
.set L_BANDH, 4
.set L_Y0, 8
.set L_X, 12
sp_line_mixed:
        ENTER   24
        mov     r12d, 1
        jmp     1f
sp_line:
        ENTER   24
        xor     r12d, r12d
1:      vcvtsi2ss xmm0, xmm0, dword ptr [rip + s_k]
        vmovss  xmm1, [rip + s_w]
        vdivss  xmm1, xmm1, xmm0
        vmovss  [rsp + L_BOXW], xmm1
        vmovss  xmm0, [rip + s_h]
        vmulss  xmm1, xmm0, [rip + C_0_2]
        vmovss  [rsp + L_BANDH], xmm1
        vmulss  xmm0, xmm0, [rip + C_HALF]
        vmulss  xmm1, xmm1, [rip + C_HALF]
        vsubss  xmm0, xmm0, xmm1
        vmovss  [rsp + L_Y0], xmm0
        mov     ebx, [rip + s_n]
2:      test    ebx, ebx
        jz      9f
        call    fr_f32
        vmulss  xmm0, xmm0, [rip + s_w]
        vmovss  [rsp + L_X], xmm0
        call    fr_f32
        vmulss  xmm0, xmm0, [rsp + L_BANDH]
        vaddss  xmm0, xmm0, [rsp + L_Y0]
        vmovss  [rsp + L_Y0 + 12], xmm0        # y (slot 20)
        test    r12d, r12d
        jnz     3f
        vmovss  xmm0, [rsp + L_X]
        vdivss  xmm0, xmm0, [rsp + L_BOXW]
        F2U     rdi, xmm0, rax
        mov     eax, [rip + s_k]
        dec     eax
        cmp     rdi, rax
        cmova   rdi, rax
        jmp     4f
3:      mov     edi, [rip + s_k]
        call    fr_below
        mov     edi, eax
4:      vmovss  xmm0, [rsp + L_X]
        vmovss  xmm1, [rsp + L_Y0 + 12]
        call    emit
        dec     ebx
        jmp     2b
9:      LEAVE   24

# --------------------------------------------------------------- rings
# spawn_ring (r12d = 0): annulus 0.30..0.50 m, uniform type;
# spawn_rainbow_ring (r12d = 1): same annulus, type by angle
.set R_CX, 0
.set R_CY, 4
.set R_MAX, 8
.set R_MIN2, 12
.set R_MAX2, 16
.set R_DX, 20
.set R_DY, 24
.set R_KF, 28
sp_rainbow_ring:
        ENTER   40
        mov     r12d, 1
        jmp     1f
sp_ring:
        ENTER   40
        xor     r12d, r12d
1:      vmovss  xmm0, [rip + s_w]
        vmulss  xmm0, xmm0, [rip + C_HALF]
        vmovss  [rsp + R_CX], xmm0
        vmovss  xmm0, [rip + s_h]
        vmulss  xmm0, xmm0, [rip + C_HALF]
        vmovss  [rsp + R_CY], xmm0
        call    wh_min
        vmulss  xmm1, xmm0, [rip + C_0_3]
        vmulss  xmm1, xmm1, xmm1
        vmovss  [rsp + R_MIN2], xmm1
        vmulss  xmm0, xmm0, [rip + C_HALF]
        vmovss  [rsp + R_MAX], xmm0
        vmulss  xmm0, xmm0, xmm0
        vmovss  [rsp + R_MAX2], xmm0
        vcvtsi2ss xmm0, xmm0, dword ptr [rip + s_k]
        vmovss  [rsp + R_KF], xmm0
        mov     ebx, [rip + s_n]
2:      test    ebx, ebx
        jz      9f
3:      vmovss  xmm1, [rsp + R_MAX]
        call    sym
        vmovss  [rsp + R_DX], xmm0
        call    sym
        vmovss  [rsp + R_DY], xmm0
        vmulss  xmm2, xmm0, xmm0
        vmovss  xmm3, [rsp + R_DX]
        vmulss  xmm3, xmm3, xmm3
        vaddss  xmm3, xmm3, xmm2
        vucomiss xmm3, [rsp + R_MIN2]
        jb      3b
        vucomiss xmm3, [rsp + R_MAX2]
        ja      3b
        test    r12d, r12d
        jnz     4f
        mov     edi, [rip + s_k]
        call    fr_below
        mov     edi, eax
        jmp     5f
4:      vmovss  xmm0, [rsp + R_DY]
        vmovss  xmm1, [rsp + R_DX]
        CALLF   atan2f
        vdivss  xmm0, xmm0, [rip + C_TAU]
        vaddss  xmm0, xmm0, [rip + C_1]
        vmovss  xmm1, [rip + C_1]
        CALLF   fmodf
        vmulss  xmm0, xmm0, [rsp + R_KF]
        F2U     rax, xmm0, rcx
        xor     edx, edx
        mov     ecx, [rip + s_k]
        div     rcx
        mov     edi, edx
5:      vmovss  xmm0, [rsp + R_CX]
        vaddss  xmm0, xmm0, [rsp + R_DX]
        vmovss  xmm1, [rsp + R_CY]
        vaddss  xmm1, xmm1, [rsp + R_DY]
        call    emit
        dec     ebx
        jmp     2b
9:      LEAVE   40

# spawn_rainbow_rings: disc of 0.48 m, type by radius
sp_rainbow_rings:
        ENTER   40
        vmovss  xmm0, [rip + s_w]
        vmulss  xmm0, xmm0, [rip + C_HALF]
        vmovss  [rsp + R_CX], xmm0
        vmovss  xmm0, [rip + s_h]
        vmulss  xmm0, xmm0, [rip + C_HALF]
        vmovss  [rsp + R_CY], xmm0
        call    wh_min
        vmulss  xmm0, xmm0, [rip + C_0_48]
        vmovss  [rsp + R_MAX], xmm0
        vmulss  xmm0, xmm0, xmm0
        vmovss  [rsp + R_MAX2], xmm0
        vcvtsi2ss xmm0, xmm0, dword ptr [rip + s_k]
        vmovss  [rsp + R_KF], xmm0
        mov     ebx, [rip + s_n]
2:      test    ebx, ebx
        jz      9f
3:      vmovss  xmm1, [rsp + R_MAX]
        call    sym
        vmovss  [rsp + R_DX], xmm0
        call    sym
        vmovss  [rsp + R_DY], xmm0
        vmulss  xmm2, xmm0, xmm0
        vmovss  xmm3, [rsp + R_DX]
        vmulss  xmm3, xmm3, xmm3
        vaddss  xmm3, xmm3, xmm2
        vucomiss xmm3, [rsp + R_MAX2]
        ja      3b
        vsqrtss xmm3, xmm3, xmm3
        vdivss  xmm3, xmm3, [rsp + R_MAX]
        vmulss  xmm3, xmm3, [rsp + R_KF]
        F2U     rax, xmm3, rcx
        xor     edx, edx
        mov     ecx, [rip + s_k]
        div     rcx
        mov     edi, edx
        vmovss  xmm0, [rsp + R_CX]
        vaddss  xmm0, xmm0, [rsp + R_DX]
        vmovss  xmm1, [rsp + R_CY]
        vaddss  xmm1, xmm1, [rsp + R_DY]
        call    emit
        dec     ebx
        jmp     2b
9:      LEAVE   40

# --------------------------------------------------------------- soft clusters
# spawn_soft_clusters: k disks (types/2..max(types,6)) placed with
# rejection, each filled uniformly with one or a few species
.set S_RMIN, 0
.set S_RDIFF, 4                 # r_max - r_min
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
.set S_RADII, 48                # 16 floats
.set S_CX, 112
.set S_CY, 176
.set S_TVEC, 240                # 16 u32
.set S_CLEN, 304                # 16 u32
.set S_K, 368                   # cluster count
.set S_FRAME, 376
# cluster type lists: s_buf, 16 bytes per cluster
sp_soft_clusters:
        ENTER   S_FRAME
        call    wh_min
        vmulss  xmm1, xmm0, [rip + C_0_14]
        vmovss  [rsp + S_RMIN], xmm1
        vmulss  xmm2, xmm0, [rip + C_0_2]
        vsubss  xmm2, xmm2, xmm1
        vmovss  [rsp + S_RDIFF], xmm2
        vmulss  xmm1, xmm0, [rip + C_M0_075]
        vmovss  [rsp + S_SPACING], xmm1
        vmovss  xmm0, [rip + C_2]
        vmulss  xmm0, xmm0, [rip + C_0_18]
        vmovss  xmm1, [rip + C_1]
        vsubss  xmm1, xmm1, xmm0                # 1 - 2 margin
        vmulss  xmm0, xmm1, [rip + s_w]
        vmovss  [rsp + S_SPANX], xmm0
        vmulss  xmm0, xmm1, [rip + s_h]
        vmovss  [rsp + S_SPANY], xmm0
        vmovss  xmm0, [rip + s_w]
        vmulss  xmm0, xmm0, [rip + C_0_18]
        vmovss  [rsp + S_MINX], xmm0
        vmovss  xmm0, [rip + s_h]
        vmulss  xmm0, xmm0, [rip + C_0_18]
        vmovss  [rsp + S_MINY], xmm0
        # k = min_clusters + usize(0..=(max - min))
        mov     eax, [rip + s_k]
        shr     eax, 1
        mov     ecx, 2
        cmp     eax, ecx
        cmovb   eax, ecx
        mov     r12d, eax               # min clusters
        mov     ecx, [rip + s_k]
        mov     edx, 6
        cmp     ecx, edx
        cmovb   ecx, edx                # max clusters
        sub     ecx, r12d
        lea     edi, [ecx + 1]
        call    fr_below
        add     eax, r12d
        mov     [rsp + S_K], eax
        # place the disks
        xor     ebx, ebx                # c
1:      cmp     ebx, [rsp + S_K]
        jae     8f
        call    fr_f32
        vmulss  xmm0, xmm0, [rsp + S_RDIFF]
        vaddss  xmm0, xmm0, [rsp + S_RMIN]
        vmovss  [rsp + S_RR], xmm0
        vmovss  [rsp + S_RADII + rbx*4], xmm0
        mov     r13d, 500
2:      test    r13d, r13d
        jz      6f
        dec     r13d
        call    fr_f32
        vmulss  xmm0, xmm0, [rsp + S_SPANX]
        vaddss  xmm0, xmm0, [rsp + S_MINX]
        vmovss  [rsp + S_X], xmm0
        call    fr_f32
        vmulss  xmm0, xmm0, [rsp + S_SPANY]
        vaddss  xmm0, xmm0, [rsp + S_MINY]
        vmovss  [rsp + S_Y], xmm0
        xor     r14d, r14d              # j
3:      cmp     r14d, ebx
        jae     5f
        vmovss  xmm0, [rsp + S_X]
        vsubss  xmm0, xmm0, [rsp + S_CX + r14*4]
        vmovss  xmm1, [rsp + S_Y]
        vsubss  xmm1, xmm1, [rsp + S_CY + r14*4]
        vmovss  xmm2, [rsp + S_RADII + r14*4]
        vaddss  xmm2, xmm2, [rsp + S_RR]
        vaddss  xmm2, xmm2, [rsp + S_SPACING]
        vmaxss  xmm2, xmm2, [rip + C_0]         # need
        vmulss  xmm0, xmm0, xmm0
        vmulss  xmm1, xmm1, xmm1
        vaddss  xmm0, xmm0, xmm1
        vmulss  xmm2, xmm2, xmm2
        vucomiss xmm0, xmm2
        jb      2b                      # too close: next try
        inc     r14d
        jmp     3b
5:      vmovss  xmm0, [rsp + S_X]
        vmovss  [rsp + S_CX + rbx*4], xmm0
        vmovss  xmm0, [rsp + S_Y]
        vmovss  [rsp + S_CY + rbx*4], xmm0
        jmp     7f
6:      call    fr_f32                  # not placed: anywhere in the span
        vmulss  xmm0, xmm0, [rsp + S_SPANX]
        vaddss  xmm0, xmm0, [rsp + S_MINX]
        vmovss  [rsp + S_CX + rbx*4], xmm0
        call    fr_f32
        vmulss  xmm0, xmm0, [rsp + S_SPANY]
        vaddss  xmm0, xmm0, [rsp + S_MINY]
        vmovss  [rsp + S_CY + rbx*4], xmm0
7:      inc     ebx
        jmp     1b
        # species per cluster
8:      lea     rdi, [rsp + S_TVEC]
        mov     esi, [rip + s_k]
        call    perm
        xor     eax, eax
81:     mov     dword ptr [rsp + S_CLEN + rax*4], 0
        inc     eax
        cmp     eax, 16
        jb      81b
        mov     r12d, [rip + s_k]       # first = min(types, k)
        cmp     r12d, [rsp + S_K]
        cmova   r12d, [rsp + S_K]
        lea     r15, [rip + s_buf]
        xor     ebx, ebx
82:     cmp     ebx, r12d
        jae     83f
        mov     eax, [rsp + S_TVEC + rbx*4]
        mov     ecx, ebx
        call    push_ct
        inc     ebx
        jmp     82b
83:     cmp     ebx, [rip + s_k]        # remaining types to random clusters
        jae     84f
        mov     edi, [rsp + S_K]
        call    fr_below
        mov     ecx, eax
        mov     eax, [rsp + S_TVEC + rbx*4]
        call    push_ct
        inc     ebx
        jmp     83b
84:     mov     ebx, [rip + s_k]        # surplus clusters get a random type
85:     cmp     ebx, [rsp + S_K]
        jae     86f
        mov     edi, [rip + s_k]
        call    fr_below
        mov     eax, [rsp + S_TVEC + rax*4]
        mov     ecx, ebx
        call    push_ct
        inc     ebx
        jmp     85b
        # fill: n / k per cluster, the first n % k get one more
86:     mov     eax, [rip + s_n]
        xor     edx, edx
        div     dword ptr [rsp + S_K]
        mov     r13d, eax               # base
        mov     r14d, edx               # rem
        xor     ebx, ebx                # c
87:     cmp     ebx, [rsp + S_K]
        jae     9f
        mov     r12d, r13d              # cnt
        test    r14d, r14d
        jz      88f
        dec     r14d
        inc     r12d
88:     test    r12d, r12d
        jz      892f
        mov     edi, [rsp + S_CLEN + rbx*4]
        mov     eax, 1
        cmp     edi, eax
        cmovb   edi, eax                # plen
        call    fr_below
        mov     r15d, eax               # ti
89:     test    r12d, r12d
        jz      892f
        call    fr_f32
        vmulss  xmm0, xmm0, [rip + C_TAU]       # TAU * f
        vmovss  [rsp + S_TH], xmm0
        call    fr_f32
        vsqrtss xmm0, xmm0, xmm0
        vmulss  xmm0, xmm0, [rsp + S_RADII + rbx*4]
        vmovss  [rsp + S_R], xmm0
        vmovss  xmm0, [rsp + S_TH]
        CALLF   cosf
        vmulss  xmm0, xmm0, [rsp + S_R]
        vaddss  xmm0, xmm0, [rsp + S_CX + rbx*4]
        vmovss  [rsp + S_X], xmm0
        vmovss  xmm0, [rsp + S_TH]
        CALLF   sinf
        vmulss  xmm1, xmm0, [rsp + S_R]
        vaddss  xmm1, xmm1, [rsp + S_CY + rbx*4]
        vmovss  xmm0, [rsp + S_X]
        mov     eax, ebx
        shl     eax, 4
        add     eax, r15d
        lea     rcx, [rip + s_buf]
        movzx   edi, byte ptr [rcx + rax]
        call    emit
        inc     r15d
        mov     edi, [rsp + S_CLEN + rbx*4]
        mov     eax, 1
        cmp     edi, eax
        cmovb   edi, eax
        xor     eax, eax
        cmp     r15d, edi
        cmove   r15d, eax
        dec     r12d
        jmp     89b
892:    inc     ebx
        jmp     87b
9:      LEAVE   S_FRAME

# push type eax onto cluster ecx's list (s_buf rows of 16, lengths at
# S_CLEN of the caller's frame, reached as [rsp + 8 + S_CLEN])
push_ct:
        mov     edx, [rsp + 8 + S_CLEN + rcx*4]
        cmp     edx, 16
        jae     1f
        shl     ecx, 4
        add     ecx, edx
        lea     rdx, [rip + s_buf]
        mov     [rdx + rcx], al
        shr     ecx, 4
        inc     dword ptr [rsp + 8 + S_CLEN + rcx*4]
1:      ret

# --------------------------------------------------------------- spiral
# spawn_spiral: one Archimedean spiral of 1.2..3.6 turns, one species per
# turn (shuffled), radial jitter 0.0175 m
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
.set SP_ORDER, 64               # 16 u32
.set SP_SEGS, 128
.set SP_FRAME, 136
sp_spiral:
        ENTER   SP_FRAME
        call    wh_min
        vmulss  xmm1, xmm0, [rip + C_0_46]
        vmovss  [rsp + SP_RADIUS], xmm1
        vmulss  xmm1, xmm0, [rip + C_0_0175]
        vmovss  [rsp + SP_THICK], xmm1
        vmovss  xmm0, [rip + s_w]
        vmulss  xmm0, xmm0, [rip + C_HALF]
        vmovss  [rsp + SP_CX], xmm0
        vmovss  xmm0, [rip + s_h]
        vmulss  xmm0, xmm0, [rip + C_HALF]
        vmovss  [rsp + SP_CY], xmm0
        call    fr_f32
        vmulss  xmm0, xmm0, [rip + C_2_4]
        vaddss  xmm0, xmm0, [rip + C_1_2]
        vmaxss  xmm0, xmm0, [rip + C_1]
        vmovss  [rsp + SP_TURNS], xmm0
        call    fr_f32
        vmulss  xmm0, xmm0, [rip + C_TAU]
        vmovss  [rsp + SP_ROT], xmm0
        vmovss  xmm0, [rsp + SP_TURNS]
        vroundss xmm0, xmm0, xmm0, 2            # ceil
        F2U     rax, xmm0, rcx
        mov     ecx, 1
        cmp     rax, rcx
        cmovb   rax, rcx
        mov     [rsp + SP_SEGS], eax
        vcvtsi2ss xmm0, xmm0, rax
        vmovss  [rsp + SP_SEGF], xmm0
        mov     eax, [rip + s_n]
        dec     eax
        mov     ecx, 1
        cmp     eax, ecx
        cmovb   eax, ecx
        vcvtsi2ss xmm0, xmm0, eax
        vmovss  [rsp + SP_N1], xmm0
        vmovss  xmm1, [rsp + SP_TURNS]
        vmulss  xmm1, xmm1, [rip + C_TAU]
        vmovss  [rsp + SP_TOTAL], xmm1
        vdivss  xmm1, xmm1, xmm0
        vmovss  [rsp + SP_DTH], xmm1
        vmovaps xmm0, xmm1
        CALLF   cosf
        vmovss  [rsp + SP_C], xmm0
        vmovss  xmm0, [rsp + SP_DTH]
        CALLF   sinf
        vmovss  [rsp + SP_S], xmm0
        vmovss  xmm0, [rsp + SP_ROT]
        CALLF   cosf
        vmovss  [rsp + SP_UX], xmm0
        vmovss  xmm0, [rsp + SP_ROT]
        CALLF   sinf
        vmovss  [rsp + SP_UY], xmm0
        lea     rdi, [rsp + SP_ORDER]
        mov     esi, [rip + s_k]
        call    perm
        vxorps  xmm0, xmm0, xmm0
        vmovss  [rsp + SP_ANGLE], xmm0
        xor     ebx, ebx                # i
1:      cmp     ebx, [rip + s_n]
        jae     9f
        cmp     dword ptr [rsp + SP_SEGS], 1
        jbe     2f
        vmovss  xmm0, [rsp + SP_ANGLE]
        vdivss  xmm0, xmm0, [rsp + SP_TOTAL]
        vmulss  xmm0, xmm0, [rsp + SP_SEGF]
        F2U     rax, xmm0, rcx
        jmp     3f
2:      mov     ecx, [rip + s_k]        # i % min(types, n)
        mov     eax, [rip + s_n]
        cmp     ecx, eax
        cmova   ecx, eax
        mov     eax, ebx
        xor     edx, edx
        div     ecx
        mov     eax, edx
3:      xor     edx, edx
        mov     ecx, [rip + s_k]
        div     rcx
        mov     r12d, [rsp + SP_ORDER + rdx*4]
        vcvtsi2ss xmm0, xmm0, ebx
        vdivss  xmm0, xmm0, [rsp + SP_N1]
        vmulss  xmm0, xmm0, [rsp + SP_RADIUS]
        vmovss  [rsp + SP_R], xmm0
        vmovss  xmm1, [rsp + SP_THICK]
        call    jit
        vaddss  xmm0, xmm0, [rsp + SP_R]
        vmaxss  xmm0, xmm0, [rip + C_0]
        vmulss  xmm2, xmm0, [rsp + SP_UX]
        vaddss  xmm2, xmm2, [rsp + SP_CX]
        vmulss  xmm1, xmm0, [rsp + SP_UY]
        vaddss  xmm1, xmm1, [rsp + SP_CY]
        vmovaps xmm0, xmm2
        mov     edi, r12d
        call    emit
        lea     rdi, [rsp + SP_UX]
        lea     rsi, [rsp + SP_C]
        call    rotate
        vmovss  xmm0, [rsp + SP_ANGLE]
        vaddss  xmm0, xmm0, [rsp + SP_DTH]
        vmovss  [rsp + SP_ANGLE], xmm0
        inc     ebx
        jmp     1b
9:      LEAVE   SP_FRAME

# rotate the unit vector {ux, uy} at [rdi] by {c, s} at [rsi]:
# nx = ux c - uy s; uy = ux s + uy c; ux = nx
rotate:
        vmovss  xmm0, [rdi]
        vmovss  xmm1, [rdi + 4]
        vmulss  xmm2, xmm0, [rsi]
        vmulss  xmm3, xmm1, [rsi + 4]
        vsubss  xmm2, xmm2, xmm3
        vmulss  xmm3, xmm0, [rsi + 4]
        vmulss  xmm4, xmm1, [rsi]
        vaddss  xmm3, xmm3, xmm4
        vmovss  [rdi], xmm2
        vmovss  [rdi + 4], xmm3
        ret

# --------------------------------------------------------------- heart
# spawn_heart: rejection sample inside (x^2+y^2-1)^3 - x^2 y^3 <= 0,
# type by angular lobe
.set H_CX, 0
.set H_CY, 4
.set H_SCALE, 8
.set H_X, 12
.set H_Y, 16
.set H_KF, 20
sp_heart:
        ENTER   24
        call    wh_min
        vmulss  xmm1, xmm0, [rip + C_0_46]
        vmovss  [rsp + H_SCALE], xmm1
        vmulss  xmm1, xmm0, [rip + C_0_06]
        vmovss  xmm0, [rip + s_h]
        vmulss  xmm0, xmm0, [rip + C_HALF]
        vaddss  xmm0, xmm0, xmm1
        vmovss  [rsp + H_CY], xmm0
        vmovss  xmm0, [rip + s_w]
        vmulss  xmm0, xmm0, [rip + C_HALF]
        vmovss  [rsp + H_CX], xmm0
        vcvtsi2ss xmm0, xmm0, dword ptr [rip + s_k]
        vmovss  [rsp + H_KF], xmm0
        mov     ebx, [rip + s_n]
1:      test    ebx, ebx
        jz      5f
        mov     r12d, 1000
2:      test    r12d, r12d
        jz      4f
        dec     r12d
        vmovss  xmm1, [rip + C_1]
        call    jit                             # u
        vmulss  xmm0, xmm0, [rip + C_1_2]
        vmovss  [rsp + H_X], xmm0
        call    jit                             # v
        vsubss  xmm0, xmm0, [rip + C_0_15]
        vmulss  xmm0, xmm0, [rip + C_1_2]
        vmovss  [rsp + H_Y], xmm0
        vmovss  xmm2, [rsp + H_X]
        vmulss  xmm3, xmm2, xmm2                # x*x
        vmulss  xmm4, xmm0, xmm0                # y*y
        vaddss  xmm4, xmm3, xmm4
        vsubss  xmm4, xmm4, [rip + C_1]         # x2y2
        vmulss  xmm5, xmm4, xmm4
        vmulss  xmm5, xmm5, xmm4
        vmulss  xmm3, xmm3, xmm0                # x*x*y
        vmulss  xmm3, xmm3, xmm0
        vmulss  xmm3, xmm3, xmm0                # x*x*y*y*y
        vsubss  xmm5, xmm5, xmm3
        vxorps  xmm6, xmm6, xmm6
        vucomiss xmm5, xmm6
        ja      2b
        vmovss  xmm0, [rsp + H_Y]
        vmovss  xmm1, [rsp + H_X]
        CALLF   atan2f
        vdivss  xmm0, xmm0, [rip + C_TAU]
        vaddss  xmm0, xmm0, [rip + C_HALF]
        vmovss  xmm1, [rip + C_1]
        CALLF   fmodf
        vmulss  xmm0, xmm0, [rsp + H_KF]
        F2U     rdi, xmm0, rax
        mov     eax, [rip + s_k]
        dec     eax
        cmp     rdi, rax
        cmova   rdi, rax
        vmovss  xmm0, [rsp + H_X]
        vmulss  xmm0, xmm0, [rsp + H_SCALE]
        vaddss  xmm0, xmm0, [rsp + H_CX]
        vmovss  xmm1, [rsp + H_Y]
        vmulss  xmm1, xmm1, [rsp + H_SCALE]
        vmovss  xmm2, [rsp + H_CY]
        vsubss  xmm1, xmm2, xmm1
        call    emit
4:      dec     ebx
        jmp     1b
5:      mov     eax, [rip + s_cnt]      # failed samples: the centre
        cmp     eax, [rip + s_n]
        jae     9f
        mov     edi, [rip + s_k]
        call    fr_below
        mov     edi, eax
        vmovss  xmm0, [rsp + H_CX]
        vmovss  xmm1, [rsp + H_CY]
        call    emit
        jmp     5b
9:      LEAVE   24

# --------------------------------------------------------------- star
# spawn_star, as in pl-box: note that pl-box samples the radius as
# rr = fastrand::f32() (0..1 px, never scaled by `outer`), so every
# particle lands within 1 px of the centre and inside core_r, i.e. one
# species in a dot that the core repulsion blows apart. Ported as is.
.set ST_CX, 0
.set ST_CY, 4
.set ST_OUTER, 8
.set ST_INNER, 12
.set ST_CORE, 16
.set ST_NPTS, 20
.set ST_A, 24
.set ST_RR, 28
.set ST_PIN, 32                 # PI / npts
.set ST_TAUN, 36                # TAU / npts
.set ST_X, 40
.set ST_REG, 48                 # 17 u32
.set ST_ORDER, 120              # 16 u32
.set ST_FRAME, 184
sp_star:
        ENTER   ST_FRAME
        vmovss  xmm0, [rip + s_w]
        vmulss  xmm0, xmm0, [rip + C_HALF]
        vmovss  [rsp + ST_CX], xmm0
        vmovss  xmm0, [rip + s_h]
        vmulss  xmm0, xmm0, [rip + C_HALF]
        vmovss  [rsp + ST_CY], xmm0
        call    wh_min
        vmulss  xmm0, xmm0, [rip + C_0_46]
        vmovss  [rsp + ST_OUTER], xmm0
        vmulss  xmm0, xmm0, [rip + C_0_45]
        vmovss  [rsp + ST_INNER], xmm0
        vmulss  xmm0, xmm0, [rip + C_0_35]
        vmovss  [rsp + ST_CORE], xmm0
        vcvtsi2ss xmm0, xmm0, dword ptr [rip + s_k]
        vmovss  [rsp + ST_NPTS], xmm0
        vmovss  xmm1, [rip + C_PI]
        vdivss  xmm1, xmm1, xmm0
        vmovss  [rsp + ST_PIN], xmm1
        vmovss  xmm1, [rip + C_TAU]
        vdivss  xmm1, xmm1, xmm0
        vmovss  [rsp + ST_TAUN], xmm1
        lea     rdi, [rsp + ST_ORDER]
        mov     esi, [rip + s_k]
        call    perm
        xor     ebx, ebx                # reg_type[r] = order[(r % types) % types]
1:      mov     eax, ebx
        xor     edx, edx
        div     dword ptr [rip + s_k]
        mov     eax, [rsp + ST_ORDER + rdx*4]
        mov     [rsp + ST_REG + rbx*4], eax
        inc     ebx
        cmp     ebx, [rip + s_k]
        jbe     1b
        mov     ebx, [rip + s_n]
2:      test    ebx, ebx
        jz      5f
        mov     r12d, 1000
3:      test    r12d, r12d
        jz      4f
        dec     r12d
        call    fr_f32
        vmulss  xmm0, xmm0, [rip + C_TAU]
        vmovss  [rsp + ST_A], xmm0
        call    fr_f32
        vmovss  [rsp + ST_RR], xmm0
        vmovss  xmm0, [rsp + ST_A]
        vaddss  xmm0, xmm0, [rsp + ST_PIN]
        vmovss  xmm1, [rsp + ST_TAUN]
        CALLF   fmodf                           # rem_euclid
        vxorps  xmm1, xmm1, xmm1
        vucomiss xmm0, xmm1
        jae     31f
        vaddss  xmm0, xmm0, [rsp + ST_TAUN]
31:     vdivss  xmm0, xmm0, [rsp + ST_TAUN]     # phase
        vmovss  xmm1, [rsp + ST_OUTER]
        vsubss  xmm2, xmm1, [rsp + ST_INNER]
        vmulss  xmm2, xmm2, xmm0
        vsubss  xmm1, xmm1, xmm2                # radius
        vmovss  xmm0, [rsp + ST_RR]
        vucomiss xmm0, xmm1
        ja      3b
        vmovss  xmm0, [rsp + ST_A]
        CALLF   cosf
        vmulss  xmm0, xmm0, [rsp + ST_RR]
        vaddss  xmm0, xmm0, [rsp + ST_CX]
        vmovss  [rsp + ST_X], xmm0
        vmovss  xmm0, [rsp + ST_A]
        CALLF   sinf
        vmulss  xmm0, xmm0, [rsp + ST_RR]
        vaddss  xmm0, xmm0, [rsp + ST_CY]
        vmovss  [rsp + ST_X + 4], xmm0
        vmovss  xmm0, [rsp + ST_A]
        vaddss  xmm0, xmm0, [rsp + ST_PIN]
        vdivss  xmm0, xmm0, [rsp + ST_TAUN]
        F2U     rax, xmm0, rcx
        xor     edx, edx
        mov     ecx, [rip + s_k]
        div     rcx                             # pt
        mov     edi, [rsp + ST_REG + rdx*4 + 4]
        vmovss  xmm0, [rsp + ST_RR]
        vucomiss xmm0, [rsp + ST_CORE]
        ja      32f
        mov     edi, [rsp + ST_REG]
32:     vmovss  xmm0, [rsp + ST_X]
        vmovss  xmm1, [rsp + ST_X + 4]
        call    emit
4:      dec     ebx
        jmp     2b
5:      mov     eax, [rip + s_cnt]
        cmp     eax, [rip + s_n]
        jae     9f
        mov     edi, [rsp + ST_REG]
        vmovss  xmm0, [rsp + ST_CX]
        vmovss  xmm1, [rsp + ST_CY]
        call    emit
        jmp     5b
9:      LEAVE   ST_FRAME

# --------------------------------------------------------------- arms
# spawn_twin_spirals: two opposed arms of 1.5..3 turns, the shuffled
# species split between them (cycled along each arm)
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
.set T_KM1, 44                  # (k-1) as f32
.set T_R, 48
.set T_PERM, 56                 # 16 u32
.set T_LO, 120                  # palette of the arm: [lo, hi)
.set T_HI, 124
.set T_FRAME, 136
sp_twin_spirals:
        ENTER   T_FRAME
        call    wh_min
        vmulss  xmm1, xmm0, [rip + C_0_46]
        vmovss  [rsp + T_RADIUS], xmm1
        vmulss  xmm1, xmm0, [rip + C_0_015]
        vmovss  [rsp + T_THICK], xmm1
        vmovss  xmm0, [rip + s_w]
        vmulss  xmm0, xmm0, [rip + C_HALF]
        vmovss  [rsp + T_CX], xmm0
        vmovss  xmm0, [rip + s_h]
        vmulss  xmm0, xmm0, [rip + C_HALF]
        vmovss  [rsp + T_CY], xmm0
        call    fr_f32
        vmulss  xmm0, xmm0, [rip + C_1_5]
        vaddss  xmm0, xmm0, [rip + C_1_5]
        vmovss  [rsp + T_TURNS], xmm0
        call    fr_f32
        vmulss  xmm0, xmm0, [rip + C_TAU]
        vmovss  [rsp + T_ROT], xmm0
        lea     rdi, [rsp + T_PERM]
        mov     esi, [rip + s_k]
        call    perm
        mov     r14d, [rip + s_n]
        mov     r15d, r14d
        and     r15d, 1                 # rem
        shr     r14d, 1                 # base
        xor     ebx, ebx                # arm a
1:      cmp     ebx, 2
        jae     9f
        mov     r12d, r14d              # k
        test    r15d, r15d
        jz      2f
        dec     r15d
        inc     r12d
2:      test    r12d, r12d
        jz      8f
        mov     eax, [rip + s_k]        # mid = (types + 1) / 2
        inc     eax
        shr     eax, 1
        xor     ecx, ecx
        mov     edx, eax
        test    ebx, ebx
        jz      3f
        mov     ecx, eax                # arm 1: perm[mid..], or perm[..mid] if empty
        mov     edx, [rip + s_k]
        cmp     ecx, edx
        jb      3f
        xor     ecx, ecx
        mov     edx, eax
3:      mov     [rsp + T_LO], ecx
        mov     [rsp + T_HI], edx
        mov     edi, edx
        sub     edi, ecx                # plen
        call    fr_below
        mov     r13d, eax               # pi
        vcvtsi2ss xmm0, xmm0, ebx
        vmulss  xmm0, xmm0, [rip + C_PI]
        vaddss  xmm0, xmm0, [rsp + T_ROT]       # th0
        vmovss  [rsp + T_UX], xmm0
        lea     eax, [r12d - 1]
        mov     ecx, 1
        cmp     eax, ecx
        cmovb   eax, ecx
        vcvtsi2ss xmm1, xmm1, eax
        vmovss  xmm2, [rsp + T_TURNS]
        vmulss  xmm2, xmm2, [rip + C_TAU]
        vdivss  xmm2, xmm2, xmm1
        vmovss  [rsp + T_DTH], xmm2
        lea     eax, [r12d - 1]
        vcvtsi2ss xmm1, xmm1, eax
        vmovss  [rsp + T_KM1], xmm1
        call    arm_setup
        xor     eax, eax                # nn
        push    rax
        push    rax
4:      mov     eax, [rsp]
        cmp     eax, r12d
        jae     7f
        vxorps  xmm0, xmm0, xmm0
        cmp     r12d, 1
        jbe     5f
        vcvtsi2ss xmm0, xmm0, eax
        vdivss  xmm0, xmm0, [rsp + 16 + T_KM1]
5:      vmulss  xmm0, xmm0, [rsp + 16 + T_RADIUS]
        vmovss  [rsp + 16 + T_R], xmm0
        vmovss  xmm1, [rsp + 16 + T_THICK]
        call    jit
        vaddss  xmm0, xmm0, [rsp + 16 + T_R]
        vmaxss  xmm0, xmm0, [rip + C_0]
        vmulss  xmm2, xmm0, [rsp + 16 + T_UX]
        vaddss  xmm2, xmm2, [rsp + 16 + T_CX]
        vmulss  xmm1, xmm0, [rsp + 16 + T_UY]
        vaddss  xmm1, xmm1, [rsp + 16 + T_CY]
        vmovaps xmm0, xmm2
        mov     eax, [rsp + 16 + T_LO]
        add     eax, r13d
        mov     edi, [rsp + 16 + T_PERM + rax*4]
        call    emit
        inc     r13d
        mov     eax, [rsp + 16 + T_LO]
        add     eax, r13d
        xor     ecx, ecx
        cmp     eax, [rsp + 16 + T_HI]
        cmovae  r13d, ecx
        lea     rdi, [rsp + 16 + T_UX]
        lea     rsi, [rsp + 16 + T_C]
        call    rotate
        inc     dword ptr [rsp]
        jmp     4b
7:      pop     rax
        pop     rax
8:      inc     ebx
        jmp     1b
9:      LEAVE   T_FRAME

# from the caller's frame (T_ layout, reached past the return address):
# th0 in T_UX -> {ux, uy} = {cos th0, sin th0}; dth in T_DTH -> {c, s}
arm_setup:
        sub     rsp, 8                  # aligned for libm
        vmovss  xmm0, [rsp + 16 + T_DTH]
        CALLF   cosf
        vmovss  [rsp + 16 + T_C], xmm0
        vmovss  xmm0, [rsp + 16 + T_DTH]
        CALLF   sinf
        vmovss  [rsp + 16 + T_S], xmm0
        vmovss  xmm0, [rsp + 16 + T_UX]
        vmovss  [rsp], xmm0
        CALLF   cosf
        vmovss  [rsp + 16 + T_UX], xmm0
        vmovss  xmm0, [rsp]
        CALLF   sinf
        vmovss  [rsp + 16 + T_UY], xmm0
        add     rsp, 8
        ret

# spawn_spiral_arms: one arm of 2.5 turns per species
sp_spiral_arms:
        ENTER   T_FRAME
        call    wh_min
        vmulss  xmm1, xmm0, [rip + C_0_46]
        vmovss  [rsp + T_RADIUS], xmm1
        vcvtsi2ss xmm1, xmm1, dword ptr [rip + s_k]
        vmovss  xmm2, [rip + C_0_07]
        vdivss  xmm2, xmm2, xmm1
        vmovss  xmm3, [rip + C_0_02]
        vminss  xmm3, xmm3, xmm2
        vmulss  xmm3, xmm3, xmm0
        vmovss  [rsp + T_THICK], xmm3
        vmovss  xmm0, [rip + s_w]
        vmulss  xmm0, xmm0, [rip + C_HALF]
        vmovss  [rsp + T_CX], xmm0
        vmovss  xmm0, [rip + s_h]
        vmulss  xmm0, xmm0, [rip + C_HALF]
        vmovss  [rsp + T_CY], xmm0
        lea     rdi, [rsp + T_PERM]
        mov     esi, [rip + s_k]
        call    perm
        mov     eax, [rip + s_n]
        xor     edx, edx
        div     dword ptr [rip + s_k]
        mov     r14d, eax               # base
        mov     r15d, edx               # rem
        xor     ebx, ebx                # a
1:      cmp     ebx, [rip + s_k]
        jae     9f
        mov     r12d, r14d
        cmp     ebx, r15d
        jae     2f
        inc     r12d
2:      test    r12d, r12d
        jz      8f
        vcvtsi2ss xmm0, xmm0, ebx
        vcvtsi2ss xmm1, xmm1, dword ptr [rip + s_k]
        vdivss  xmm0, xmm0, xmm1
        vmulss  xmm0, xmm0, [rip + C_TAU]
        vmovss  [rsp + T_UX], xmm0
        lea     eax, [r12d - 1]
        mov     ecx, 1
        cmp     eax, ecx
        cmovb   eax, ecx
        vcvtsi2ss xmm1, xmm1, eax
        vmovss  xmm2, [rip + C_2_5]
        vmulss  xmm2, xmm2, [rip + C_TAU]
        vdivss  xmm2, xmm2, xmm1
        vmovss  [rsp + T_DTH], xmm2
        lea     eax, [r12d - 1]
        vcvtsi2ss xmm1, xmm1, eax
        vmovss  [rsp + T_KM1], xmm1
        call    arm_setup
        xor     r13d, r13d              # nn
4:      cmp     r13d, r12d
        jae     8f
        vxorps  xmm0, xmm0, xmm0
        cmp     r12d, 1
        jbe     5f
        vcvtsi2ss xmm0, xmm0, r13d
        vdivss  xmm0, xmm0, [rsp + T_KM1]
5:      vmulss  xmm0, xmm0, [rsp + T_RADIUS]
        vmovss  [rsp + T_R], xmm0
        vmovss  xmm1, [rsp + T_THICK]
        call    jit
        vaddss  xmm0, xmm0, [rsp + T_R]
        vmaxss  xmm0, xmm0, [rip + C_0]
        vmulss  xmm2, xmm0, [rsp + T_UX]
        vaddss  xmm2, xmm2, [rsp + T_CX]
        vmulss  xmm1, xmm0, [rsp + T_UY]
        vaddss  xmm1, xmm1, [rsp + T_CY]
        vmovaps xmm0, xmm2
        mov     edi, [rsp + T_PERM + rbx*4]
        call    emit
        lea     rdi, [rsp + T_UX]
        lea     rsi, [rsp + T_C]
        call    rotate
        inc     r13d
        jmp     4b
8:      inc     ebx
        jmp     1b
9:      LEAVE   T_FRAME

# --------------------------------------------------------------- fans
# spawn_radiant_fans: clamp(types, 3, 10) beams from the centre, denser
# near the rim (r = r_out f^0.56). pl-box skips fans with no colour (types
# < 3), returning fewer than N particles; here such a fan borrows the set
# of fan f % types so the count is always N (no effect for types >= 3).
.set F_CX, 0
.set F_CY, 4
.set F_ROUT, 8
.set F_SPREAD, 12
.set F_TH0, 16
.set F_R, 20
.set F_TH, 24
.set F_X, 28
.set F_FANS, 32
.set F_TVEC, 40                 # 16 u32
.set F_CLEN, 104                # 10 u32
.set F_FRAME, 152
# colour sets: s_buf, 16 bytes per fan
sp_radiant_fans:
        ENTER   F_FRAME
        mov     eax, [rip + s_k]
        mov     ecx, 3
        cmp     eax, ecx
        cmovb   eax, ecx
        mov     ecx, 10
        cmp     eax, ecx
        cmova   eax, ecx
        mov     [rsp + F_FANS], eax
        call    wh_min
        vmulss  xmm0, xmm0, [rip + C_0_46]
        vmovss  [rsp + F_ROUT], xmm0
        vmovss  xmm0, [rip + C_0_22]
        vmulss  xmm0, xmm0, [rip + C_PI]
        vmovss  [rsp + F_SPREAD], xmm0
        vmovss  xmm0, [rip + s_w]
        vmulss  xmm0, xmm0, [rip + C_HALF]
        vmovss  [rsp + F_CX], xmm0
        vmovss  xmm0, [rip + s_h]
        vmulss  xmm0, xmm0, [rip + C_HALF]
        vmovss  [rsp + F_CY], xmm0
        lea     rdi, [rsp + F_TVEC]
        mov     esi, [rip + s_k]
        call    perm
        xor     eax, eax
1:      mov     dword ptr [rsp + F_CLEN + rax*4], 0
        inc     eax
        cmp     eax, 10
        jb      1b
        xor     ebx, ebx                # color_sets[i % fans].push(tvec[i])
2:      cmp     ebx, [rip + s_k]
        jae     3f
        mov     eax, ebx
        xor     edx, edx
        div     dword ptr [rsp + F_FANS]
        mov     ecx, [rsp + F_CLEN + rdx*4]
        inc     dword ptr [rsp + F_CLEN + rdx*4]
        shl     edx, 4
        add     edx, ecx
        lea     rcx, [rip + s_buf]
        mov     eax, [rsp + F_TVEC + rbx*4]
        mov     [rcx + rdx], al
        inc     ebx
        jmp     2b
3:      mov     eax, [rip + s_n]
        xor     edx, edx
        div     dword ptr [rsp + F_FANS]
        mov     r14d, eax               # base
        mov     r15d, edx               # rem
        xor     ebx, ebx                # f
4:      cmp     ebx, [rsp + F_FANS]
        jae     9f
        mov     r12d, r14d              # cnt
        test    r15d, r15d
        jz      5f
        dec     r15d
        inc     r12d
5:      test    r12d, r12d
        jz      8f
        mov     eax, ebx                # set index (see above)
        cmp     dword ptr [rsp + F_CLEN + rax*4], 0
        jne     51f
        xor     edx, edx
        div     dword ptr [rip + s_k]
        mov     eax, edx
51:     push    rax
        push    rax
        vcvtsi2ss xmm0, xmm0, ebx
        vcvtsi2ss xmm1, xmm1, dword ptr [rsp + 16 + F_FANS]
        vdivss  xmm0, xmm0, xmm1
        vmulss  xmm0, xmm0, [rip + C_TAU]
        vmovss  [rsp + 16 + F_TH0], xmm0
        call    fr_f32
        vmulss  xmm0, xmm0, [rip + C_0_2]
        vaddss  xmm0, xmm0, [rsp + 16 + F_TH0]
        vmovss  [rsp + 16 + F_TH0], xmm0
        mov     eax, [rsp]
        mov     edi, [rsp + 16 + F_CLEN + rax*4]
        call    fr_below
        mov     r13d, eax               # ci
6:      test    r12d, r12d
        jz      7f
        call    fr_f32
        vmovss  xmm1, [rip + C_0_56]
        CALLF   powf
        vmulss  xmm0, xmm0, [rsp + 16 + F_ROUT]
        vmovss  [rsp + 16 + F_R], xmm0
        vmovss  xmm1, [rsp + 16 + F_SPREAD]
        call    jit
        vaddss  xmm0, xmm0, [rsp + 16 + F_TH0]
        vmovss  [rsp + 16 + F_TH], xmm0
        CALLF   cosf
        vmulss  xmm0, xmm0, [rsp + 16 + F_R]
        vaddss  xmm0, xmm0, [rsp + 16 + F_CX]
        vmovss  [rsp + 16 + F_X], xmm0
        vmovss  xmm0, [rsp + 16 + F_TH]
        CALLF   sinf
        vmulss  xmm1, xmm0, [rsp + 16 + F_R]
        vaddss  xmm1, xmm1, [rsp + 16 + F_CY]
        vmovss  xmm0, [rsp + 16 + F_X]
        mov     eax, [rsp]
        shl     eax, 4
        add     eax, r13d
        lea     rcx, [rip + s_buf]
        movzx   edi, byte ptr [rcx + rax]
        call    emit
        inc     r13d
        mov     eax, [rsp]
        xor     ecx, ecx
        cmp     r13d, [rsp + 16 + F_CLEN + rax*4]
        cmove   r13d, ecx
        dec     r12d
        jmp     6b
7:      pop     rax
        pop     rax
8:      inc     ebx
        jmp     4b
9:      LEAVE   F_FRAME

# --------------------------------------------------------------- blocks
# spawn_blocks: a rows x cols mosaic (6..72+ blocks), shuffled species per
# block (every species at least once), 12% gaps
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
.set B_FRAME, 56
# s_buf: order (u32, up to 512), then species bytes at s_buf + 2048
sp_blocks:
        ENTER   B_FRAME
        # target = usize(max(types,6) ..= max(types*8, 72)).min(n)
        mov     r12d, [rip + s_k]
        mov     eax, 6
        cmp     r12d, eax
        cmovb   r12d, eax               # lo
        mov     ecx, [rip + s_k]
        shl     ecx, 3
        mov     eax, 72
        cmp     ecx, eax
        cmovb   ecx, eax                # hi
        sub     ecx, r12d
        lea     edi, [ecx + 1]
        call    fr_below
        add     eax, r12d
        cmp     eax, [rip + s_n]
        cmova   eax, [rip + s_n]
        mov     r12d, eax               # target
        vcvtsi2ss xmm0, xmm0, r12d
        vmovss  xmm1, [rip + s_w]
        vdivss  xmm1, xmm1, [rip + s_h]         # aspect
        vdivss  xmm0, xmm0, xmm1
        vsqrtss xmm0, xmm0, xmm0
        CALLF   roundf
        F2U     rax, xmm0, rcx
        mov     ecx, 1
        cmp     rax, rcx
        cmovb   rax, rcx
        mov     [rsp + B_ROWS], eax
        vcvtsi2ss xmm0, xmm0, r12d
        vcvtsi2ss xmm1, xmm1, eax
        vdivss  xmm0, xmm0, xmm1
        vroundss xmm0, xmm0, xmm0, 2            # ceil
        F2U     rax, xmm0, rcx
        mov     ecx, 1
        cmp     rax, rcx
        cmovb   rax, rcx
        mov     [rsp + B_COLS], eax
        imul    eax, [rsp + B_ROWS]
        mov     ecx, 512                # scratch bound (never reached: <= 2 x 128)
        cmp     eax, ecx
        cmova   eax, ecx
        mov     [rsp + B_BLOCKS], eax
        vcvtsi2ss xmm1, xmm1, dword ptr [rsp + B_COLS]
        vmovss  xmm0, [rip + s_w]
        vdivss  xmm0, xmm0, xmm1
        vmovss  [rsp + B_BW], xmm0
        vcvtsi2ss xmm1, xmm1, dword ptr [rsp + B_ROWS]
        vmovss  xmm2, [rip + s_h]
        vdivss  xmm2, xmm2, xmm1
        vmovss  [rsp + B_BH], xmm2
        vminss  xmm0, xmm0, xmm2
        vmulss  xmm0, xmm0, [rip + C_0_12]
        vmovss  [rsp + B_GAP], xmm0
        lea     rdi, [rip + s_buf]
        mov     esi, [rsp + B_BLOCKS]
        call    perm
        xor     ebx, ebx                # idx
1:      cmp     ebx, [rsp + B_BLOCKS]
        jae     3f
        mov     eax, ebx
        cmp     ebx, [rip + s_k]
        jb      2f
        mov     edi, [rip + s_k]
        call    fr_below
2:      lea     rcx, [rip + s_buf]
        mov     edx, [rcx + rbx*4]      # b = order[idx]
        mov     [rcx + rdx + 2048], al
        inc     ebx
        jmp     1b
3:      mov     eax, [rip + s_n]
        xor     edx, edx
        div     dword ptr [rsp + B_BLOCKS]
        mov     r14d, eax               # base
        mov     r15d, edx               # rem
        xor     ebx, ebx                # r
4:      cmp     ebx, [rsp + B_ROWS]
        jae     9f
        xor     r13d, r13d              # c
5:      cmp     r13d, [rsp + B_COLS]
        jae     8f
        mov     r12d, r14d              # cnt
        test    r15d, r15d
        jz      51f
        dec     r15d
        inc     r12d
51:     test    r12d, r12d
        jz      7f
        vmovss  xmm2, [rsp + B_GAP]
        vmulss  xmm3, xmm2, [rip + C_HALF]
        vcvtsi2ss xmm0, xmm0, r13d
        vmulss  xmm0, xmm0, [rsp + B_BW]
        vaddss  xmm0, xmm0, xmm3
        vmovss  [rsp + B_X0], xmm0
        vcvtsi2ss xmm0, xmm0, ebx
        vmulss  xmm0, xmm0, [rsp + B_BH]
        vaddss  xmm0, xmm0, xmm3
        vmovss  [rsp + B_Y0], xmm0
        vmovss  xmm0, [rsp + B_BW]
        vsubss  xmm0, xmm0, xmm2
        vmaxss  xmm0, xmm0, [rip + C_1]
        vmovss  [rsp + B_IW], xmm0
        vmovss  xmm0, [rsp + B_BH]
        vsubss  xmm0, xmm0, xmm2
        vmaxss  xmm0, xmm0, [rip + C_1]
        vmovss  [rsp + B_IH], xmm0
6:      test    r12d, r12d
        jz      7f
        call    fr_f32
        vmulss  xmm0, xmm0, [rsp + B_IW]
        vaddss  xmm0, xmm0, [rsp + B_X0]
        vmovss  [rsp + B_X], xmm0
        call    fr_f32
        vmulss  xmm1, xmm0, [rsp + B_IH]
        vaddss  xmm1, xmm1, [rsp + B_Y0]
        vmovss  xmm0, [rsp + B_X]
        mov     eax, ebx
        imul    eax, [rsp + B_COLS]
        add     eax, r13d
        lea     rcx, [rip + s_buf]
        movzx   edi, byte ptr [rcx + rax + 2048]
        call    emit
        dec     r12d
        jmp     6b
7:      inc     r13d
        jmp     5b
8:      inc     ebx
        jmp     4b
9:      LEAVE   B_FRAME

# --------------------------------------------------------------- stripes
# spawn_stripes: equal stripes, one species each, randomly vertical or
# horizontal and optionally reversed
.set SS_SEG, 0
.set SS_O, 4
.set SS_X, 8
.set SS_FRAME, 24
sp_stripes:
        ENTER   SS_FRAME
        call    fr_bool
        mov     r14d, eax               # vertical
        call    fr_bool
        mov     r15d, eax               # reversed
        mov     eax, [rip + s_n]
        xor     edx, edx
        div     dword ptr [rip + s_k]
        mov     r12d, eax               # base
        mov     r13d, edx               # rem
        vcvtsi2ss xmm1, xmm1, dword ptr [rip + s_k]
        vmovss  xmm0, [rip + s_w]
        test    r14d, r14d
        jnz     1f
        vmovss  xmm0, [rip + s_h]
1:      vdivss  xmm0, xmm0, xmm1
        vmovss  [rsp + SS_SEG], xmm0
        xor     ebx, ebx                # si
2:      cmp     ebx, [rip + s_k]
        jae     9f
        vcvtsi2ss xmm0, xmm0, ebx
        vmulss  xmm0, xmm0, [rsp + SS_SEG]
        vmovss  [rsp + SS_O], xmm0
        mov     ecx, r12d               # k
        test    r13d, r13d
        jz      3f
        dec     r13d
        inc     ecx
3:      push    rcx
        push    rcx
4:      cmp     dword ptr [rsp], 0
        je      7f
        test    r14d, r14d
        jz      5f
        call    fr_f32
        vmulss  xmm0, xmm0, [rsp + 16 + SS_SEG]
        vaddss  xmm0, xmm0, [rsp + 16 + SS_O]
        vmovss  [rsp + 16 + SS_X], xmm0
        call    fr_f32
        vmulss  xmm1, xmm0, [rip + s_h]
        vmovss  xmm0, [rsp + 16 + SS_X]
        jmp     6f
5:      call    fr_f32
        vmulss  xmm0, xmm0, [rip + s_w]
        vmovss  [rsp + 16 + SS_X], xmm0
        call    fr_f32
        vmulss  xmm1, xmm0, [rsp + 16 + SS_SEG]
        vaddss  xmm1, xmm1, [rsp + 16 + SS_O]
        vmovss  xmm0, [rsp + 16 + SS_X]
6:      mov     edi, ebx
        test    r15d, r15d
        jz      61f
        mov     edi, [rip + s_k]
        sub     edi, ebx
        dec     edi
61:     call    emit
        dec     dword ptr [rsp]
        jmp     4b
7:      pop     rcx
        pop     rcx
        inc     ebx
        jmp     2b
9:      LEAVE   SS_FRAME

# --------------------------------------------------------------- polar maze
# spawn_polar_maze: 6 rings of 18 sectors; each ring gets a few species and
# a random number of arcs, each arc a run of one species
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
.set M_LEN, 64                  # 6 u32: layer list lengths
.set M_USED, 88                 # 18 bytes
.set M_SHUF, 112                # 16 u32
.set M_ARCS, 176
.set M_KPA, 180
.set M_TT, 184
.set M_FRAME, 200
# layer lists: s_buf, 64 bytes per layer
sp_polar_maze:
        ENTER   M_FRAME
        vmovss  xmm0, [rip + s_w]
        vmulss  xmm0, xmm0, [rip + C_HALF]
        vmovss  [rsp + M_CX], xmm0
        vmovss  xmm0, [rip + s_h]
        vmulss  xmm0, xmm0, [rip + C_HALF]
        vmovss  [rsp + M_CY], xmm0
        call    wh_min
        vmulss  xmm1, xmm0, [rip + C_0_012]
        vmovss  [rsp + M_THICK], xmm1
        vmulss  xmm1, xmm0, [rip + C_0_12]
        vmovss  [rsp + M_RMIN], xmm1
        vmulss  xmm2, xmm0, [rip + C_0_46]
        vsubss  xmm2, xmm2, xmm1
        vdivss  xmm2, xmm2, [rip + C_6]
        vmovss  [rsp + M_DR], xmm2
        vmovss  xmm0, [rip + C_TAU]
        vdivss  xmm0, xmm0, [rip + C_18]
        vmovss  [rsp + M_DTH], xmm0
        lea     rdi, [rsp + M_SHUF]
        mov     esi, [rip + s_k]
        call    perm
        xor     eax, eax
1:      mov     dword ptr [rsp + M_LEN + rax*4], 0
        inc     eax
        cmp     eax, 6
        jb      1b
        xor     ebx, ebx                # layer_types[i % 6].push(shuffled[i])
2:      cmp     ebx, [rip + s_k]
        jae     3f
        mov     eax, ebx
        xor     edx, edx
        mov     ecx, 6
        div     ecx
        mov     ecx, edx
        mov     eax, [rsp + M_SHUF + rbx*4]
        call    push_layer
        inc     ebx
        jmp     2b
3:      xor     ebx, ebx                # extra colours, p = 0.35
31:     cmp     ebx, [rip + s_k]
        jae     4f
        call    fr_f32
        vucomiss xmm0, [rip + C_0_35]
        jae     32f
        mov     edi, 6
        call    fr_below
        mov     ecx, eax
        mov     eax, ebx
        call    push_layer
32:     inc     ebx
        jmp     31b
4:      xor     ebx, ebx                # no empty layer
41:     cmp     dword ptr [rsp + M_LEN + rbx*4], 0
        jne     42f
        mov     edi, [rip + s_k]
        call    fr_below
        mov     ecx, ebx
        call    push_layer
42:     inc     ebx
        cmp     ebx, 6
        jb      41b
        # rings
        xor     ebx, ebx                # l
5:      cmp     ebx, 6
        jae     9f
        mov     eax, [rip + s_n]
        xor     edx, edx
        mov     ecx, 6
        div     ecx
        mov     r12d, eax               # remain = base + (l < rem)
        cmp     ebx, edx
        jae     51f
        inc     r12d
51:     test    r12d, r12d
        jz      8f
        vcvtsi2ss xmm0, xmm0, ebx
        vaddss  xmm0, xmm0, [rip + C_HALF]
        vmulss  xmm0, xmm0, [rsp + M_DR]
        vaddss  xmm0, xmm0, [rsp + M_RMIN]
        vmovss  [rsp + M_R], xmm0
        call    fr_f32
        vmulss  xmm0, xmm0, [rip + C_HALF]
        vaddss  xmm0, xmm0, [rip + C_HALF]
        vmulss  xmm0, xmm0, [rip + C_18]
        F2U     rax, xmm0, rcx
        mov     ecx, 2
        cmp     rax, rcx
        cmovb   rax, rcx
        mov     [rsp + M_ARCS], eax
        xor     ecx, ecx
52:     mov     byte ptr [rsp + M_USED + rcx], 0
        inc     ecx
        cmp     ecx, 18
        jb      52b
        mov     eax, r12d
        xor     edx, edx
        div     dword ptr [rsp + M_ARCS]
        mov     ecx, 1
        cmp     eax, ecx
        cmovb   eax, ecx
        mov     [rsp + M_KPA], eax
        xor     r13d, r13d              # a
6:      cmp     r13d, [rsp + M_ARCS]
        jae     7f
        test    r12d, r12d
        jz      7f
        mov     edi, 18
        call    fr_below
61:     cmp     byte ptr [rsp + M_USED + rax], 0
        je      62f
        inc     eax
        xor     ecx, ecx
        cmp     eax, 18
        cmove   eax, ecx
        jmp     61b
62:     mov     byte ptr [rsp + M_USED + rax], 1
        vcvtsi2ss xmm0, xmm0, eax
        vmulss  xmm1, xmm0, [rsp + M_DTH]
        vmovss  xmm2, [rsp + M_DTH]
        vmulss  xmm2, xmm2, [rip + C_0_04]
        vaddss  xmm1, xmm1, xmm2                # th0
        vmovss  [rsp + M_TH0], xmm1
        vaddss  xmm0, xmm0, [rip + C_1]
        vsubss  xmm0, xmm0, [rip + C_0_04]
        vmulss  xmm0, xmm0, [rsp + M_DTH]       # th1
        vsubss  xmm0, xmm0, xmm1
        mov     r14d, [rsp + M_KPA]     # k = min(k_per_arc, remain)
        cmp     r14d, r12d
        cmova   r14d, r12d
        vcvtsi2ss xmm1, xmm1, r14d
        vdivss  xmm0, xmm0, xmm1
        vmovss  [rsp + M_STEP], xmm0
        call    fr_f32
        vmulss  xmm0, xmm0, [rsp + M_STEP]
        vaddss  xmm0, xmm0, [rsp + M_TH0]       # start
        vmovss  [rsp + M_TH0], xmm0
        vmovss  xmm0, [rsp + M_STEP]
        CALLF   sinf
        vmovss  [rsp + M_SN], xmm0
        vmovss  xmm0, [rsp + M_STEP]
        CALLF   cosf
        vmovss  [rsp + M_C], xmm0
        vmovss  xmm0, [rsp + M_TH0]
        CALLF   cosf
        vmovss  [rsp + M_UX], xmm0
        vmovss  xmm0, [rsp + M_TH0]
        CALLF   sinf
        vmovss  [rsp + M_UY], xmm0
        call    layer_type
        mov     [rsp + M_TT], eax
        mov     r15d, r14d
63:     test    r15d, r15d
        jz      64f
        vmovss  xmm1, [rsp + M_THICK]
        call    jit
        vaddss  xmm0, xmm0, [rsp + M_R]         # r + rr
        vmulss  xmm2, xmm0, [rsp + M_UX]
        vaddss  xmm2, xmm2, [rsp + M_CX]
        vmulss  xmm1, xmm0, [rsp + M_UY]
        vaddss  xmm1, xmm1, [rsp + M_CY]
        vmovaps xmm0, xmm2
        mov     edi, [rsp + M_TT]
        call    emit
        vmovss  xmm0, [rsp + M_UX]              # rotate by {c, sn}
        vmovss  xmm1, [rsp + M_UY]
        vmulss  xmm2, xmm0, [rsp + M_C]
        vmulss  xmm3, xmm1, [rsp + M_SN]
        vsubss  xmm2, xmm2, xmm3
        vmulss  xmm3, xmm0, [rsp + M_SN]
        vmulss  xmm4, xmm1, [rsp + M_C]
        vaddss  xmm3, xmm3, xmm4
        vmovss  [rsp + M_UX], xmm2
        vmovss  [rsp + M_UY], xmm3
        dec     r15d
        jmp     63b
64:     sub     r12d, r14d
        inc     r13d
        jmp     6b
        # leftovers: loosely around the ring
7:      test    r12d, r12d
        jz      8f
        mov     edi, 18
        call    fr_below
        vcvtsi2ss xmm0, xmm0, eax
        vmovss  [rsp + M_ANG], xmm0
        call    fr_f32
        vaddss  xmm0, xmm0, [rsp + M_ANG]
        vmulss  xmm0, xmm0, [rsp + M_DTH]
        vmovss  [rsp + M_ANG], xmm0
        vmovss  xmm1, [rsp + M_THICK]
        call    jit
        vaddss  xmm0, xmm0, [rsp + M_R]
        vmovss  [rsp + M_RR], xmm0
        call    layer_type
        mov     [rsp + M_TT], eax
        vmovss  xmm0, [rsp + M_ANG]
        CALLF   cosf
        vmulss  xmm0, xmm0, [rsp + M_RR]
        vaddss  xmm0, xmm0, [rsp + M_CX]
        vmovss  [rsp + M_X], xmm0
        vmovss  xmm0, [rsp + M_ANG]
        CALLF   sinf
        vmulss  xmm1, xmm0, [rsp + M_RR]
        vaddss  xmm1, xmm1, [rsp + M_CY]
        vmovss  xmm0, [rsp + M_X]
        mov     edi, [rsp + M_TT]
        call    emit
        dec     r12d
        jmp     7b
8:      inc     ebx
        jmp     5b
9:      LEAVE   M_FRAME

# push type eax onto layer ecx (lists of up to 64 at s_buf, lengths in the
# caller's frame at M_LEN)
push_layer:
        mov     edx, [rsp + 8 + M_LEN + rcx*4]
        cmp     edx, 64
        jae     1f
        shl     ecx, 6
        add     ecx, edx
        lea     rdx, [rip + s_buf]
        mov     [rdx + rcx], al
        shr     ecx, 6
        inc     dword ptr [rsp + 8 + M_LEN + rcx*4]
1:      ret

# eax = types_here[usize(0..len)] for layer ebx (caller's frame)
layer_type:
        push    rbx
        mov     edi, [rsp + 16 + M_LEN + rbx*4]
        call    fr_below
        shl     ebx, 6
        add     eax, ebx
        lea     rcx, [rip + s_buf]
        movzx   eax, byte ptr [rcx + rax]
        pop     rbx
        ret

# --------------------------------------------------------------- random
# uniform scatter: type, x, y (the order of pl-box's random_population,
# but drawn from fastrand rather than rand's SmallRng)
sp_random:
        ENTER   8
        mov     ebx, [rip + s_n]
1:      test    ebx, ebx
        jz      9f
        mov     edi, [rip + s_k]
        call    fr_below
        mov     r12d, eax
        call    fr_f32
        vmulss  xmm0, xmm0, [rip + s_w]
        vmovss  [rsp], xmm0
        call    fr_f32
        vmulss  xmm1, xmm0, [rip + s_h]
        vmovss  xmm0, [rsp]
        mov     edi, r12d
        call    emit
        dec     ebx
        jmp     1b
9:      LEAVE   8

# --------------------------------------------------------------- entry points
# u32 pl_spawn_raw(u32 layout, u32 n, u32 k, float w, float h,
#                  float *x, float *y, i32 *t): run one layout from the
# current pl_frng state into the given arrays, unwrapped (exactly pl-box's
# coordinates). Returns the number of particles written (always n).
        .globl pl_spawn_raw
pl_spawn_raw:
        push    rbx                     # rsp aligned
        mov     [rip + s_n], esi
        mov     [rip + s_k], edx
        vmovss  [rip + s_w], xmm0
        vmovss  [rip + s_h], xmm1
        mov     [rip + s_px], rcx
        mov     [rip + s_py], r8
        mov     [rip + s_pt], r9
        mov     dword ptr [rip + s_cnt], 0
        test    esi, esi
        jz      9f
        test    edx, edx
        jz      9f
        mov     eax, edi
        cmp     eax, NSPAWNS
        jb      1f
        xor     eax, eax
1:      lea     rcx, [rip + spawn_fns]
        call    [rcx + rax*8]
9:      mov     eax, [rip + s_cnt]
        pop     rbx
        ret

# void pl_spawn(u32 layout): respawn the pl.N particles of pl.K types in
# that layout (seeding wyrand from pl's splitmix stream), wrap into the
# world as pl-box's Wrap boundary does, zero velocities, ids 0..N-1, bin.
        .globl pl_spawn
pl_spawn:
        push    rbx
        push    r12
        push    r13                     # rsp aligned
        mov     ebx, edi
        cmp     ebx, NSPAWNS
        jb      1f
        xor     ebx, ebx
1:      mov     [rip + pl_spawn_cur], ebx
        call    pl_rng_u64
        mov     [rip + pl_frng], rax
        lea     r13, [rip + pl]
        mov     edi, ebx
        mov     esi, [r13 + PL_N]
        mov     edx, [r13 + PL_K]
        vmovss  xmm0, [r13 + PL_W]
        vmovss  xmm1, [r13 + PL_H]
        mov     rcx, [r13 + PL_NX]
        mov     r8, [r13 + PL_NY]
        mov     r9, [r13 + PL_T]
        call    pl_spawn_raw
        lea     r13, [rip + pl]
        mov     rsi, [r13 + PL_NX]
        mov     rdi, [r13 + PL_NY]
        mov     r8, [r13 + PL_ID]
        mov     r9, [r13 + PL_VX]
        mov     r10, [r13 + PL_VY]
        mov     rdx, [r13 + PL_T]
        mov     r11d, [r13 + PL_K]
        vmovss  xmm4, [r13 + PL_W]
        vmovss  xmm5, [r13 + PL_H]
        vxorps  xmm6, xmm6, xmm6
        xor     ecx, ecx
2:      cmp     ecx, [r13 + PL_N]
        jae     3f
        vmovss  xmm0, [rsi + rcx*4]
        vmovaps xmm1, xmm4
        call    wrap1
        vmovss  [rsi + rcx*4], xmm0
        vmovss  xmm0, [rdi + rcx*4]
        vmovaps xmm1, xmm5
        call    wrap1
        vmovss  [rdi + rcx*4], xmm0
        cmp     [rdx + rcx*4], r11d     # defensive: type < K
        jb      21f
        mov     dword ptr [rdx + rcx*4], 0
21:     mov     [r8 + rcx*4], ecx
        mov     dword ptr [r9 + rcx*4], 0
        mov     dword ptr [r10 + rcx*4], 0
        inc     ecx
        jmp     2b
3:      pop     r13
        pop     r12
        pop     rbx
        jmp     pl_bin

# xmm0 = coordinate xmm0 wrapped into [0, xmm1) (xmm6 = 0): one wrap step as
# pl-box's Wrap, then anything still outside (a NaN, or x + w rounding up
# to w) goes to 0
wrap1:
        vucomiss xmm0, xmm6
        jae     1f
        vaddss  xmm0, xmm0, xmm1
        jmp     2f
1:      vucomiss xmm0, xmm1
        jb      2f
        vsubss  xmm0, xmm0, xmm1
2:      vucomiss xmm0, xmm6
        jb      3f
        jp      3f
        vucomiss xmm0, xmm1
        jae     3f
        ret
3:      vxorps  xmm0, xmm0, xmm0
        ret

# u32 pl_spawn_pick(void): pl-box's spawn_pattern choice, 0..15 weighted
# (soft_clusters 3/15, never ring, spiral, line_mixed or random)
        .globl pl_spawn_pick
pl_spawn_pick:
        call    pl_rng_u64
        shr     rax, 32
        imul    rax, rax, 15
        shr     rax, 32
        lea     rcx, [rip + pattern_map]
        movzx   eax, byte ptr [rcx + rax]
        ret

# int pl_spawn_find(const char *name): layout index by name
# (case-insensitive, '-' accepted for '_'), or -1
        .globl pl_spawn_find
pl_spawn_find:
        push    rbx
        push    r12
        push    r13                     # rsp aligned
        sub     rsp, 64
        mov     r12, rdi
        xor     ecx, ecx                # copy with '-' -> '_'
1:      movzx   eax, byte ptr [r12 + rcx]
        cmp     al, '-'
        jne     2f
        mov     al, '_'
2:      mov     [rsp + rcx], al
        test    al, al
        jz      3f
        inc     ecx
        cmp     ecx, 63
        jb      1b
        mov     byte ptr [rsp + rcx], 0
3:      xor     ebx, ebx
4:      cmp     ebx, NSPAWNS
        jae     8f
        lea     r13, [rip + pl_spawn_names]
        mov     rsi, [r13 + rbx*8]
        mov     rdi, rsp
        call    strcasecmp@PLT
        test    eax, eax
        jz      9f
        inc     ebx
        jmp     4b
8:      mov     ebx, -1
9:      mov     eax, ebx
        add     rsp, 64
        pop     r13
        pop     r12
        pop     rbx
        ret
