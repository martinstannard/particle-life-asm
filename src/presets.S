# Rule presets ported from pl-box (crates/pl-core/src/rules.rs, RulePreset),
# their physics (crates/pl-core/src/presets.rs, CURATED), and the shuffle bag
# used to cycle through them.
#
# Every generator is pointwise: attraction[i][j] depends only on (i, j, K)
# (Symmetric reads back the mirrored entry it already produced, Random and
# Symmetric draw from the RNG in row-major order). So one driver loops over
# (i, j) and calls a per-preset cell function. The trigonometry goes through
# libm (sinf, cosf, expf, fmodf), the same functions Rust's f32::sin, cos,
# exp and % call on Linux, and the arithmetic is done in the same order as
# the Rust source without FMA contraction, so the matrices are bit-identical
# to pl-box's (checked by tests/test_presets.c against tests/plbox_ref.txt).

        .intel_syntax noprefix
        .include "layout.inc"

.set NPRESETS, 31

        .section .rodata
        .balign 16
ABSMASK:  .long 0x7fffffff, 0, 0, 0
K_0:      .float 0.0
K_1:      .float 1.0
K_M1:     .float -1.0
K_2:      .float 2.0
K_3:      .float 3.0
K_1_5:    .float 1.5
K_HALF:   .float 0.5
K_TAU:    .float 6.28318530717958647692    # std::f32::consts::TAU (= 2 * PI in f32)
K_2P32:   .float 4294967296.0              # u32::MAX as f32
K_43758:  .float 43758.5453
K_0_1:    .float 0.1
K_0_12:   .float 0.12
K_0_15:   .float 0.15
K_0_2:    .float 0.2
K_0_3:    .float 0.3
K_0_35:   .float 0.35
K_0_4:    .float 0.4
K_0_5:    .float 0.5
K_0_55:   .float 0.55
K_0_6:    .float 0.6
K_0_7:    .float 0.7
K_0_75:   .float 0.75
K_0_8:    .float 0.8
K_0_85:   .float 0.85
K_0_9:    .float 0.9
K_M0_05:  .float -0.05
K_M0_1:   .float -0.1
K_M0_2:   .float -0.2
K_M0_4:   .float -0.4
K_M0_6:   .float -0.6
K_M0_7:   .float -0.7
K_M0_75:  .float -0.75
K_M0_8:   .float -0.8
K_M0_9:   .float -0.9

# display names (RulePreset::name) and enum names, both accepted by --preset
n00: .asciz "Random"
n01: .asciz "Symmetric"
n02: .asciz "Snake"
n03: .asciz "Chains1"
n04: .asciz "Chains2"
n05: .asciz "Chains3"
n06: .asciz "RPS"
n07: .asciz "Bipartite"
n08: .asciz "Hub&Spokes"
n09: .asciz "Shells"
n10: .asciz "Swirl"
n11: .asciz "Checker"
n12: .asciz "Dimers"
n13: .asciz "TriadFlocks"
n14: .asciz "Conveyor"
n15: .asciz "Patchwork"
n16: .asciz "Wavefield"
n17: .asciz "ChiralBand"
n18: .asciz "RotConveyor"
n19: .asciz "PrimeHop"
n20: .asciz "ParityVortex"
n21: .asciz "Helical"
n22: .asciz "BiasedWave"
n23: .asciz "ModTriads"
n24: .asciz "SkipPursuit"
n25: .asciz "BlueNoise"
n26: .asciz "Phasefield"
n27: .asciz "RingRoad"
n28: .asciz "TriSpiral"
n29: .asciz "VortexLattice"
n30: .asciz "DriftPatch"
e06: .asciz "RockPaperScissors"
e08: .asciz "HubAndSpokes"
e09: .asciz "ConcentricShells"
e10: .asciz "AntiSymmetricSwirl"
e11: .asciz "CheckerOffsets"
e12: .asciz "DimersAndChains"
e14: .asciz "SpiralConveyor"
e17: .asciz "ChiralBandpass"
e18: .asciz "RotatingConveyor"
e21: .asciz "HelicalLadder"
e23: .asciz "ModularTriads"
e24: .asciz "SkippedPursuit"
e25: .asciz "BlueNoiseConveyor"
e26: .asciz "OffsetPhasefield"
e29: .asciz "VortexAntivortex"
e30: .asciz "DriftedPatchwork"

# Physics per preset: force scale, friction, core repulsion, min radius
# range, max radius range (7 floats + pad). The 17 presets in pl-box's
# CURATED list use their tuned values: cfg() = 1.1 / 0.6 / 0.7,
# minr 12-22, maxr 28-45 (cfg_fric overrides friction); flow() = 1.4 /
# 0.35 / 0.9, minr 12-20, maxr 28-45. The others are not in CURATED; they
# get pl-box's render.rs defaults 0.3 / 0.4 / 0.6, minr 12-24, maxr 33-70.
.macro PHYS fs, fr, co, a0, a1, b0, b1
        .float \fs, \fr, \co, \a0, \a1, \b0, \b1, 0.0
.endm
.macro CFG fr=0.6
        PHYS 1.1, \fr, 0.7, 12.0, 22.0, 28.0, 45.0
.endm
.macro FLOW
        PHYS 1.4, 0.35, 0.9, 12.0, 20.0, 28.0, 45.0
.endm
.macro DEF
        PHYS 0.3, 0.4, 0.6, 12.0, 24.0, 33.0, 70.0
.endm
        .balign 32
        .globl pl_preset_phys
pl_preset_phys:
        CFG             # Random
        DEF             # Symmetric
        DEF             # Snake
        DEF             # Chains1
        DEF             # Chains2
        DEF             # Chains3
        DEF             # RPS
        CFG             # Bipartite
        CFG             # Hub&Spokes
        CFG             # Shells
        FLOW            # Swirl
        DEF             # Checker
        CFG             # Dimers
        CFG             # TriadFlocks
        CFG             # Conveyor
        DEF             # Patchwork
        FLOW            # Wavefield
        FLOW            # ChiralBand
        DEF             # RotConveyor
        DEF             # PrimeHop
        CFG             # ParityVortex
        DEF             # Helical
        DEF             # BiasedWave
        FLOW            # ModTriads
        CFG             # SkipPursuit
        DEF             # BlueNoise
        FLOW            # Phasefield
        DEF             # RingRoad
        FLOW            # TriSpiral
        CFG 0.4         # VortexLattice
        CFG 0.5         # DriftPatch

        .section .data.rel.ro, "aw"
        .balign 8
        .globl pl_preset_names
pl_preset_names:
        .quad n00, n01, n02, n03, n04, n05, n06, n07, n08, n09
        .quad n10, n11, n12, n13, n14, n15, n16, n17, n18, n19
        .quad n20, n21, n22, n23, n24, n25, n26, n27, n28, n29, n30
enum_names:
        .quad 0, 0, 0, 0, 0, 0, e06, 0, e08, e09
        .quad e10, e11, e12, 0, e14, 0, 0, e17, e18, 0
        .quad 0, e21, 0, e23, e24, e25, e26, 0, 0, e29, e30
cell_fns:
        .quad c_random, c_symmetric, c_snake, c_chains1, c_chains2
        .quad c_chains3, c_rps, c_bipartite, c_hub, c_shells
        .quad c_swirl, c_checker, c_dimers, c_triad, c_conveyor
        .quad c_patchwork, c_wave, c_chiral, c_rotconv, c_primehop
        .quad c_parity, c_helical, c_biased, c_modtri, c_skip
        .quad c_bluenoise, c_phasefield, c_ringroad, c_trispiral, c_vortex
        .quad c_drift

        .data
        .balign 4
        .globl pl_preset_cur, pl_preset_shown
pl_preset_cur:   .long -1       # active preset, -1 = none (plain random rules)
pl_preset_shown: .long 0        # shuffle bag: bit p set = shown this round

        .bss
        .balign 64
raw:    .skip 1024              # generator output, 16 x 16
g_out:  .skip 8
g_i:    .skip 4
g_j:    .skip 4
g_n:    .skip 4
g_d:    .skip 4                 # (j - i) mod n
g_fi:   .skip 4
g_fj:   .skip 4
g_fn:   .skip 4
g_ph:   .skip 4                 # TAU * (j - i) / n

        .text

# ---------------------------------------------------------------- driver
# void pl_preset_attraction(u32 p, u32 k, float *out): raw pl-box matrix
# of preset p for k types into out[i*16 + j]; the rest of out is zeroed.
        .globl pl_preset_attraction
pl_preset_attraction:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15                     # rsp aligned
        lea     rax, [rip + cell_fns]
        mov     edi, edi
        mov     r13, [rax + rdi*8]
        mov     r15d, esi
        mov     r14, rdx
        mov     rdi, rdx
        mov     ecx, 256
        xor     eax, eax
        rep stosd
        mov     [rip + g_out], r14
        mov     [rip + g_n], r15d
        vcvtsi2ss xmm0, xmm0, r15d
        vmovss  [rip + g_fn], xmm0
        xor     ebx, ebx                # i
1:      cmp     ebx, r15d
        jae     9f
        xor     r12d, r12d              # j
2:      cmp     r12d, r15d
        jae     8f
        mov     [rip + g_i], ebx
        mov     [rip + g_j], r12d
        lea     eax, [r12d + r15d]
        sub     eax, ebx
        xor     edx, edx
        div     r15d
        mov     [rip + g_d], edx
        vcvtsi2ss xmm0, xmm0, ebx
        vmovss  [rip + g_fi], xmm0
        vcvtsi2ss xmm1, xmm1, r12d
        vmovss  [rip + g_fj], xmm1
        vsubss  xmm2, xmm1, xmm0
        vmulss  xmm2, xmm2, [rip + K_TAU]
        vdivss  xmm2, xmm2, [rip + g_fn]
        vmovss  [rip + g_ph], xmm2
        call    r13
        mov     eax, ebx
        shl     eax, 4
        add     eax, r12d
        vmovss  [r14 + rax*4], xmm0
        inc     r12d
        jmp     2b
8:      inc     ebx
        jmp     1b
9:      pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

# ---------------------------------------------------------------- cells
# Called with rsp = 8 mod 16, return attraction in xmm0. May clobber all
# caller-saved registers. g_d is in [1, n-1] whenever i != j, so "j ==
# (i + k) % n" is "d == k" and "j == (i + n - k) % n" is "d == n - k"; both
# are simply never true when k >= n, as in the Rust code.

.macro RETC c
        vmovss  xmm0, [rip + \c]
        ret
.endm
.macro DIAG c                           # i == j -> c
        mov     eax, [rip + g_i]
        cmp     eax, [rip + g_j]
        jne     77f
        RETC    \c
77:
.endm
.macro IFD k, lbl                       # d == k -> lbl
        cmp     dword ptr [rip + g_d], \k
        je      \lbl
.endm
.macro IFDN k, lbl                      # d == n - k -> lbl
        mov     eax, [rip + g_n]
        sub     eax, \k
        cmp     eax, [rip + g_d]
        je      \lbl
.endm

c_random:
        vmovss  xmm0, [rip + K_M1]
        vmovss  xmm1, [rip + K_1]
        jmp     pl_rng_range

c_symmetric:                            # upper triangle drawn row-major, mirrored
        mov     eax, [rip + g_i]
        mov     ecx, [rip + g_j]
        cmp     ecx, eax
        jae     c_random
        shl     ecx, 4
        add     ecx, eax
        mov     rax, [rip + g_out]
        vmovss  xmm0, [rax + rcx*4]
        ret

c_snake:
        DIAG    K_1
        IFD     1, 1f
        RETC    K_0
1:      RETC    K_0_2

c_chains1:
        DIAG    K_1
        IFD     1, 1f
        IFDN    1, 1f
        RETC    K_M1
1:      RETC    K_1

c_chains2:
        DIAG    K_1
        IFD     1, 1f
        IFDN    1, 1f
        RETC    K_M1
1:      RETC    K_0_2

c_chains3:
        DIAG    K_1
        IFD     1, 1f
        IFDN    1, 1f
        RETC    K_0
1:      RETC    K_0_2

c_rps:
        DIAG    K_M0_1
        IFD     1, 1f
        IFDN    1, 2f
        RETC    K_0
1:      RETC    K_0_9
2:      RETC    K_M0_7

c_bipartite:
        DIAG    K_0_2
        mov     eax, [rip + g_i]
        xor     eax, [rip + g_j]
        test    eax, 1
        jnz     1f
        RETC    K_0_8
1:      RETC    K_M0_8

c_hub:
        DIAG    K_0
        cmp     dword ptr [rip + g_i], 0
        je      1f
        cmp     dword ptr [rip + g_j], 0
        je      2f
        RETC    K_0
1:      RETC    K_1
2:      RETC    K_0_6

c_shells:
        DIAG    K_0_9
        IFD     1, 1f
        RETC    K_M0_6
1:      RETC    K_0_3

c_swirl:        # upper: |j-i| <= n/2 ? 0.7 : -0.7, lower: the negation
        DIAG    K_M0_05
        mov     eax, [rip + g_j]
        sub     eax, [rip + g_i]
        mov     ecx, [rip + g_n]
        shr     ecx, 1
        test    eax, eax
        js      2f
        cmp     eax, ecx
        jbe     1f
        RETC    K_M0_7
1:      RETC    K_0_7
2:      neg     eax
        cmp     eax, ecx
        jbe     3f
        RETC    K_0_7
3:      RETC    K_M0_7

c_checker:
        DIAG    K_0_2
        IFD     1, 1f
        IFDN    1, 1f
        IFD     2, 2f
        IFDN    2, 2f
        RETC    K_0
1:      RETC    K_M0_8
2:      RETC    K_0_8

c_dimers:
        DIAG    K_0
        mov     eax, [rip + g_i]
        xor     eax, 1
        cmp     eax, [rip + g_j]
        je      1f
        RETC    K_M0_9
1:      RETC    K_1

c_triad:
        DIAG    K_0_1
        mov     ecx, 3
        mov     eax, [rip + g_i]
        xor     edx, edx
        div     ecx
        mov     r8d, eax
        mov     eax, [rip + g_j]
        xor     edx, edx
        div     ecx
        cmp     eax, r8d
        je      1f
        RETC    K_M0_7
1:      RETC    K_0_9

c_conveyor:
        DIAG    K_M0_1
        IFD     1, 1f
        IFD     2, 2f
        RETC    K_M0_6
1:      RETC    K_0_7
2:      RETC    K_0_3

c_patchwork:    # r = |fract(sin(h as f32) * 43758.5453)|, h = i*73856093 ^ j*19349663
        DIAG    K_0
        sub     rsp, 24
        mov     eax, [rip + g_i]
        imul    rax, rax, 73856093
        mov     ecx, [rip + g_j]
        imul    rcx, rcx, 19349663
        xor     rax, rcx
        vcvtsi2ss xmm0, xmm0, rax
        call    sinf@PLT
        vmulss  xmm0, xmm0, [rip + K_43758]
        vmovss  xmm1, [rip + K_1]
        call    fmodf@PLT
        vandps  xmm0, xmm0, [rip + ABSMASK]
        add     rsp, 24
        vmovss  xmm1, [rip + K_0_35]
        vcomiss xmm0, xmm1
        jb      1f
        vaddss  xmm1, xmm1, xmm1        # 2 * p
        vcomiss xmm0, xmm1
        jb      2f
        RETC    K_0
1:      RETC    K_0_9
2:      RETC    K_M0_9

c_wave:
        DIAG    K_M0_05
        sub     rsp, 24
        vmovss  xmm0, [rip + g_ph]
        call    sinf@PLT
        vmulss  xmm0, xmm0, [rip + K_0_9]
        add     rsp, 24
        ret

c_chiral:       # ph = TAU*d/n: 0.5 sin(ph) + 0.3 sin(2 ph) + 0.15
        DIAG    K_M0_05
        sub     rsp, 24
        vcvtsi2ss xmm0, xmm0, dword ptr [rip + g_d]
        vmulss  xmm0, xmm0, [rip + K_TAU]
        vdivss  xmm0, xmm0, [rip + g_fn]
        vmovss  [rsp], xmm0
        call    sinf@PLT
        vmulss  xmm0, xmm0, [rip + K_0_5]
        vmovss  [rsp + 4], xmm0
        vmovss  xmm0, [rsp]
        vmulss  xmm0, xmm0, [rip + K_2]
        call    sinf@PLT
        vmulss  xmm0, xmm0, [rip + K_0_3]
        vaddss  xmm0, xmm0, [rsp + 4]
        vaddss  xmm0, xmm0, [rip + K_0_15]
        add     rsp, 24
        ret

c_rotconv:      # 0.8 sin(TAU (j-i)/n + i TAU/(1.5 n))
        DIAG    K_M0_05
        sub     rsp, 24
        vmovss  xmm0, [rip + g_fn]
        vmulss  xmm0, xmm0, [rip + K_1_5]
        vmovss  xmm1, [rip + K_TAU]
        vdivss  xmm1, xmm1, xmm0
        vmulss  xmm1, xmm1, [rip + g_fi]
        vmovss  xmm0, [rip + g_ph]
        vaddss  xmm0, xmm0, xmm1
        call    sinf@PLT
        vmulss  xmm0, xmm0, [rip + K_0_8]
        add     rsp, 24
        ret

c_primehop:     # pl-box's prime p is always 2 (first prime < n, else 2)
        DIAG    K_M0_05
        mov     eax, [rip + g_d]
        test    eax, 1
        jnz     1f
        RETC    K_0_9
1:      sub     rsp, 24
        mov     ecx, [rip + g_n]
        sub     ecx, eax
        cmp     eax, ecx
        cmova   eax, ecx                # circular distance min(d, n-d)
        vcvtsi2ss xmm0, xmm0, eax
        vmulss  xmm0, xmm0, [rip + K_M0_7]
        call    expf@PLT
        vmulss  xmm0, xmm0, [rip + K_M0_7]
        add     rsp, 24
        ret

c_parity:
        DIAG    K_M0_05
        mov     eax, [rip + g_i]
        mov     ecx, [rip + g_j]
        and     eax, 1
        and     ecx, 1
        lea     eax, [eax*2 + ecx]      # 2*odd(i) + odd(j)
        cmp     eax, 1
        je      1f
        cmp     eax, 2
        je      2f
        test    eax, eax
        jz      3f
        RETC    K_M0_6
1:      RETC    K_0_8
2:      RETC    K_0_6
3:      RETC    K_M0_4

c_helical:      # 0.7 sin(k (j-i)) + 0.4 cos(k (i+j)), k = TAU/n
        DIAG    K_M0_05
        sub     rsp, 24
        vmovss  xmm2, [rip + K_TAU]
        vdivss  xmm2, xmm2, [rip + g_fn]
        vmovss  [rsp + 8], xmm2
        vmovss  xmm0, [rip + g_fj]
        vsubss  xmm0, xmm0, [rip + g_fi]
        vmulss  xmm0, xmm0, xmm2
        call    sinf@PLT
        vmulss  xmm0, xmm0, [rip + K_0_7]
        vmovss  [rsp], xmm0
        vmovss  xmm0, [rip + g_fi]
        vaddss  xmm0, xmm0, [rip + g_fj]
        vmulss  xmm0, xmm0, [rsp + 8]
        call    cosf@PLT
        vmulss  xmm0, xmm0, [rip + K_0_4]
        vaddss  xmm0, xmm0, [rsp]
        add     rsp, 24
        ret

c_biased:
        DIAG    K_M0_05
        sub     rsp, 24
        vmovss  xmm0, [rip + g_ph]
        call    sinf@PLT
        vmulss  xmm0, xmm0, [rip + K_0_75]
        vaddss  xmm0, xmm0, [rip + K_0_15]
        add     rsp, 24
        ret

c_modtri:
        DIAG    K_M0_05
        mov     ecx, 3
        mov     eax, [rip + g_i]
        xor     edx, edx
        div     ecx
        mov     r8d, edx                # di
        mov     eax, [rip + g_j]
        xor     edx, edx
        div     ecx                     # edx = dj
        cmp     edx, r8d
        je      1f
        lea     eax, [r8d + 1]
        cmp     eax, 3
        jne     4f
        xor     eax, eax
4:      cmp     edx, eax
        je      2f
        RETC    K_M0_75
1:      RETC    K_M0_2
2:      RETC    K_0_85

# rax = circ(rdi) = min((x + n) % n, (n - x) % n), signed remainders as in
# Rust's i64 %, for skipped_pursuit
circ:
        movsxd  rcx, dword ptr [rip + g_n]
        lea     rax, [rdi + rcx]
        cqo
        idiv    rcx
        mov     r8, rdx
        mov     rax, rcx
        sub     rax, rdi
        cqo
        idiv    rcx
        cmp     rdx, r8
        cmovg   rdx, r8
        mov     rax, rdx
        ret

c_skip:         # d == 2 ? 0.9 : -0.6 exp(-0.8 min(circ(d-2), circ(d+2)))
        DIAG    K_M0_05
        IFD     2, 1f
        push    rbx
        movsxd  rdi, dword ptr [rip + g_d]
        sub     rdi, 2
        call    circ
        mov     rbx, rax
        movsxd  rdi, dword ptr [rip + g_d]
        add     rdi, 2
        call    circ
        cmp     rax, rbx
        cmovg   rax, rbx
        pop     rbx
        sub     rsp, 24
        vcvtsi2ss xmm0, xmm0, rax
        vmulss  xmm0, xmm0, [rip + K_M0_8]
        call    expf@PLT
        vmulss  xmm0, xmm0, [rip + K_M0_6]
        add     rsp, 24
        ret
1:      RETC    K_0_9

# xmm0 = hash(edi, esi) in [0, 1] with multipliers r8d, r9d (det_hash32/b)
dhash:
        imul    edi, r8d
        imul    esi, r9d
        xor     edi, esi
        mov     eax, edi
        shl     eax, 13
        xor     eax, edi
        mov     ecx, edi
        shr     ecx, 7
        xor     eax, ecx
        shl     edi, 17
        xor     eax, edi                # zero-extends into rax
        vcvtsi2ss xmm0, xmm0, rax
        vdivss  xmm0, xmm0, [rip + K_2P32]
        ret

c_bluenoise:    # upper: 0.9 (h(i,j) - 0.5) 2; lower: -0.8 * upper mirror
        DIAG    K_M0_05
        mov     edi, [rip + g_i]
        mov     esi, [rip + g_j]
        cmp     edi, esi
        jb      1f
        xchg    edi, esi
1:      mov     r8d, 73856093
        mov     r9d, 19349663
        call    dhash
        vsubss  xmm0, xmm0, [rip + K_HALF]
        vmulss  xmm0, xmm0, [rip + K_0_9]
        vmulss  xmm0, xmm0, [rip + K_2]
        mov     eax, [rip + g_i]
        cmp     eax, [rip + g_j]
        jb      2f
        vmulss  xmm0, xmm0, [rip + K_M0_8]
2:      ret

c_phasefield:   # 0.8 sin(th(j) - th(i)) + 0.12 sin(th(i)), th(x) = (TAU/n * 3) x
        DIAG    K_M0_05
        sub     rsp, 24
        vmovss  xmm2, [rip + K_TAU]
        vdivss  xmm2, xmm2, [rip + g_fn]
        vmulss  xmm2, xmm2, [rip + K_3]
        vmulss  xmm1, xmm2, [rip + g_fi]        # th(i)
        vmovss  [rsp + 8], xmm1
        vmulss  xmm0, xmm2, [rip + g_fj]        # th(j)
        vsubss  xmm0, xmm0, xmm1
        call    sinf@PLT
        vmulss  xmm0, xmm0, [rip + K_0_8]
        vmovss  [rsp], xmm0
        vmovss  xmm0, [rsp + 8]
        call    sinf@PLT
        vmulss  xmm0, xmm0, [rip + K_0_12]
        vaddss  xmm0, xmm0, [rsp]
        add     rsp, 24
        ret

c_ringroad:     # circular distance <= 1: 0.85, <= max(ceil(n/3), 2): 0.2, else -0.8
        DIAG    K_M0_05
        mov     eax, [rip + g_d]
        mov     ecx, [rip + g_n]
        sub     ecx, eax
        cmp     eax, ecx
        cmova   eax, ecx
        cmp     eax, 1
        jbe     1f
        vmovss  xmm0, [rip + g_fn]
        vdivss  xmm0, xmm0, [rip + K_3]
        vroundss xmm0, xmm0, xmm0, 2    # ceil
        vcvttss2si ecx, xmm0
        mov     edx, 2
        cmp     ecx, edx
        cmovb   ecx, edx
        cmp     eax, ecx
        jbe     2f
        RETC    K_M0_8
1:      RETC    K_0_85
2:      RETC    K_0_2

c_trispiral:    # 0.7 sin(ph) + 0.55 sin(3 ph)
        DIAG    K_M0_05
        sub     rsp, 24
        vmovss  xmm0, [rip + g_ph]
        call    sinf@PLT
        vmulss  xmm0, xmm0, [rip + K_0_7]
        vmovss  [rsp], xmm0
        vmovss  xmm0, [rip + g_ph]
        vmulss  xmm0, xmm0, [rip + K_3]
        call    sinf@PLT
        vmulss  xmm0, xmm0, [rip + K_0_55]
        vaddss  xmm0, xmm0, [rsp]
        add     rsp, 24
        ret

c_vortex:       # (+-0.6 by parity of i+j) sin(ph)
        DIAG    K_M0_05
        sub     rsp, 24
        vmovss  xmm0, [rip + g_ph]
        call    sinf@PLT
        mov     eax, [rip + g_i]
        add     eax, [rip + g_j]
        vmovss  xmm1, [rip + K_0_6]
        test    eax, 1
        jz      1f
        vmovss  xmm1, [rip + K_M0_6]
1:      vmulss  xmm0, xmm0, xmm1
        add     rsp, 24
        ret

c_drift:        # (0.75 sin(ph) + 0.12) * (hash_b(i,j) < 0.6 ? 1 : 0)
        DIAG    K_M0_05
        sub     rsp, 24
        vmovss  xmm0, [rip + g_ph]
        call    sinf@PLT
        vmulss  xmm0, xmm0, [rip + K_0_75]
        vaddss  xmm0, xmm0, [rip + K_0_12]
        vmovss  [rsp], xmm0
        mov     edi, [rip + g_i]
        mov     esi, [rip + g_j]
        mov     r8d, 2654435761
        mov     r9d, 1597334677
        call    dhash
        vmovss  xmm1, [rip + K_0]
        vcomiss xmm0, [rip + K_0_6]
        jae     1f
        vmovss  xmm1, [rip + K_1]
1:      vmovss  xmm0, [rsp]
        vmulss  xmm0, xmm0, xmm1        # multiply, not select: keeps pl-box's -0.0
        add     rsp, 24
        ret

# ---------------------------------------------------------------- apply
# void pl_preset_rules(u32 p): install preset p for the current K: physics
# (force scale, friction, core), attraction clamped to [-1, 1] (pl-box's
# Helical and SkipPursuit generators exceed it), per-pair radii drawn from
# the preset's ranges as in RuleMatrix::from_preset, then rebuild every
# derived table, the grid, the neighbour ranges and the kernel choice.
        .globl pl_preset_rules
pl_preset_rules:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 16                 # rsp aligned, [rsp] = min radius
        lea     r13, [rip + pl]
        mov     r14d, edi
        mov     [rip + pl_preset_cur], edi
        lea     r15, [rip + pl_preset_phys]
        shl     edi, 5
        add     r15, rdi
        mov     eax, [r15 + 0]
        mov     [r13 + PL_FSCALE], eax
        mov     eax, [r15 + 4]
        mov     [r13 + PL_FRIC], eax
        mov     eax, [r15 + 8]
        mov     [r13 + PL_CORE], eax

        mov     edi, r14d
        mov     esi, [r13 + PL_K]
        lea     rdx, [rip + raw]
        call    pl_preset_attraction
        lea     rsi, [rip + raw]
        vbroadcastss ymm1, [rip + K_M1]
        vbroadcastss ymm2, [rip + K_1]
        xor     eax, eax
1:      vmaxps  ymm0, ymm1, [rsi + rax]
        vminps  ymm0, ymm2, ymm0
        vmovups [r13 + PL_ATTR + rax], ymm0
        vxorps  ymm3, ymm3, ymm3
        vmovups [r13 + PL_MINR + rax], ymm3
        vmovups [r13 + PL_MAXRT + rax], ymm3
        add     eax, 32
        cmp     eax, 1024
        jb      1b
        vzeroupper

        xor     ebx, ebx                # i
2:      cmp     ebx, [r13 + PL_K]
        jae     5f
        xor     r12d, r12d              # j
3:      cmp     r12d, [r13 + PL_K]
        jae     4f
        vmovss  xmm0, [r15 + 12]
        vmovss  xmm1, [r15 + 16]
        call    pl_rng_range
        mov     eax, ebx
        shl     eax, 4
        add     eax, r12d
        vmovss  [r13 + PL_MINR + rax*4], xmm0
        vmovss  [rsp], xmm0
        vmovss  xmm0, [r15 + 20]
        vmovss  xmm1, [r15 + 24]
        call    pl_rng_range
        vmovss  xmm1, [rsp]
        vcomiss xmm1, xmm0
        jb      31f
        vaddss  xmm0, xmm1, [rip + K_1] # min >= max: max = min + 1
31:     mov     eax, ebx
        shl     eax, 4
        add     eax, r12d
        vmovss  [r13 + PL_MAXRT + rax*4], xmm0
        inc     r12d
        jmp     3b
4:      inc     ebx
        jmp     2b
5:      add     rsp, 16
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        jmp     pl_update_tables

# void pl_preset_apply(u32 p): new rules for preset p, mark it shown, and
# scatter all particles afresh (same N and K).
        .globl pl_preset_apply
pl_preset_apply:
        push    rbx                     # rsp aligned
        mov     ebx, edi
        call    pl_preset_rules
        bts     [rip + pl_preset_shown], ebx
        pop     rbx
        jmp     pl_random_particles

# ---------------------------------------------------------------- shuffle bag
# u32 pl_preset_pick(void): a random preset that has not been shown in this
# round and is not the current one. When every preset has been shown, a new
# round starts with only the current one marked.
        .globl pl_preset_pick
pl_preset_pick:
        push    rbx                     # rsp aligned
        mov     ebx, (1 << NPRESETS) - 1
        mov     eax, [rip + pl_preset_shown]
        mov     ecx, [rip + pl_preset_cur]
        test    ecx, ecx
        js      1f
        bts     eax, ecx
1:      andn    edx, eax, ebx           # available
        jnz     2f
        xor     eax, eax
        test    ecx, ecx
        js      11f
        bts     eax, ecx
11:     mov     [rip + pl_preset_shown], eax
        andn    edx, eax, ebx
2:      mov     ebx, edx
        call    pl_rng_u64
        shr     rax, 32
        popcnt  ecx, ebx
        imul    rax, rcx
        shr     rax, 32                 # r in [0, count)
3:      test    eax, eax
        jz      4f
        blsr    ebx, ebx                # drop r lowest candidates
        dec     eax
        jmp     3b
4:      tzcnt   eax, ebx
        pop     rbx
        ret

# int pl_preset_find(const char *name): index by display or enum name,
# case-insensitive, or -1
        .globl pl_preset_find
pl_preset_find:
        push    rbx
        push    r12
        push    r13                     # rsp aligned
        mov     r12, rdi
        xor     ebx, ebx
1:      cmp     ebx, NPRESETS
        jae     8f
        lea     r13, [rip + pl_preset_names]
        mov     rsi, [r13 + rbx*8]
        mov     rdi, r12
        call    strcasecmp@PLT
        test    eax, eax
        jz      9f
        lea     r13, [rip + enum_names]
        mov     rsi, [r13 + rbx*8]
        test    rsi, rsi
        jz      2f
        mov     rdi, r12
        call    strcasecmp@PLT
        test    eax, eax
        jz      9f
2:      inc     ebx
        jmp     1b
8:      mov     ebx, -1
9:      mov     eax, ebx
        pop     r13
        pop     r12
        pop     rbx
        ret
