// Rule presets ported from pl-box (crates/pl-core/src/rules.rs, RulePreset),
// their physics and pl-box's curated list, and the shuffle bag used to cycle
// through them. AArch64 port of src/presets.S: the same data, the same
// pointwise generators, the same libm calls (sinf, cosf, expf, fmodf) and
// the arithmetic in the same order without FMA contraction, so that the
// matrices stay bit-identical to pl-box's (tests/test_presets.c). The libm
// results come from the Pi's glibc, the reference from x86's: the same C
// code, but built with different FMA use, so a rare one-ulp difference
// there would be libm's, not this file's.

        .include "layout.inc"
        .include "macros.inc"

.set NPRESETS, 31
.set NCURATED, 17
.set NENTRIES, 48

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
K_TAU:    .float 6.28318530717958647692    // std::f32::consts::TAU (= 2 * PI in f32)
K_2P32:   .float 4294967296.0              // u32::MAX as f32
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

// display names (RulePreset::name) and enum names, both accepted by --preset
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

// Physics per preset: force scale, friction, core repulsion, min radius
// range, max radius range (7 floats + pad). The 17 presets in pl-box's
// CURATED list use their tuned values: cfg() = 1.1 / 0.6 / 0.7,
// minr 12-22, maxr 28-45 (cfg_fric overrides friction); flow() = 1.4 /
// 0.35 / 0.9, minr 12-20, maxr 28-45. The others are not in CURATED; they
// get pl-box's render.rs defaults 0.3 / 0.4 / 0.6, minr 12-24, maxr 33-70.
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
        CFG             // Random
        DEF             // Symmetric
        DEF             // Snake
        DEF             // Chains1
        DEF             // Chains2
        DEF             // Chains3
        DEF             // RPS
        CFG             // Bipartite
        CFG             // Hub&Spokes
        CFG             // Shells
        FLOW            // Swirl
        DEF             // Checker
        CFG             // Dimers
        CFG             // TriadFlocks
        CFG             // Conveyor
        DEF             // Patchwork
        FLOW            // Wavefield
        FLOW            // ChiralBand
        DEF             // RotConveyor
        DEF             // PrimeHop
        CFG             // ParityVortex
        DEF             // Helical
        DEF             // BiasedWave
        FLOW            // ModTriads
        CFG             // SkipPursuit
        DEF             // BlueNoise
        FLOW            // Phasefield
        DEF             // RingRoad
        FLOW            // TriSpiral
        CFG 0.4         // VortexLattice
        CFG 0.5         // DriftPatch

// pl-box CURATED: rule, num_types, speed (sub-steps per frame in pl-box;
// kept for reference, not used: the window has --steps-per-frame).
// Physics come from pl_preset_phys[rule], which holds these presets' cfg /
// cfg_fric / flow values.
        .globl pl_curated
pl_curated:
        .byte 24, 7, 3          // SkippedPursuit     flowing maze / coral
        .byte 14, 7, 3          // SpiralConveyor     labyrinth streams
        .byte 20, 8, 3          // ParityVortex       striped rotating segments
        .byte  9, 7, 2          // ConcentricShells   directional shells/rings
        .byte  8, 7, 2          // HubAndSpokes       hub-directed flows
        .byte 29, 8, 4          // VortexAntivortex   (friction 0.4)
        .byte 30, 8, 3          // DriftedPatchwork   (friction 0.5)
        .byte  0, 8, 3          // Random             fully-asymmetric wildcard
        .byte 10, 8, 4          // AntiSymmetricSwirl flow physics
        .byte 17, 8, 4          // ChiralBandpass     flow
        .byte 16, 8, 3          // Wavefield          flow
        .byte 26, 8, 3          // OffsetPhasefield   flow
        .byte 28, 8, 4          // TriSpiral          flow
        .byte 23, 8, 3          // ModularTriads      flow
        .byte 13, 9, 2          // TriadFlocks        symmetric cell-formers
        .byte 12, 8, 2
        .byte  7, 8, 1          // Bipartite
s_pool_c: .asciz "curated"
s_pool_g: .asciz "generated"
s_pool_a: .asciz "all"

        .section .data.rel.ro, "aw"
        .balign 8
        .globl pl_pool_names
pl_pool_names:
        .quad s_pool_c, s_pool_g, s_pool_a
pool_masks:
        .quad (1 << NCURATED) - 1
        .quad ((1 << NENTRIES) - 1) & ~((1 << NCURATED) - 1)
        .quad (1 << NENTRIES) - 1
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
        .globl pl_preset_cur, pl_preset_shown, pl_pool, pl_pool_mask
pl_preset_cur:   .long -1       // active entry, -1 = none (plain random rules)
pl_pool:         .long 0        // 0 curated, 1 generated, 2 all
        .balign 8
pl_preset_shown: .quad 0        // shuffle bag: bit e set = shown this round
pl_pool_mask:    .quad (1 << NCURATED) - 1

        .bss
        .balign 64
raw:    .skip 1024              // generator output, 16 x 16
g_out:  .skip 8
g_i:    .skip 4
g_j:    .skip 4
g_n:    .skip 4
g_d:    .skip 4                 // (j - i) mod n
g_fi:   .skip 4
g_fj:   .skip 4
g_fn:   .skip 4
g_ph:   .skip 4                 // TAU * (j - i) / n

        .text

// globals of the generator call, at fixed offsets from g_out
.set G_OUT, 0
.set G_I, 8
.set G_J, 12
.set G_N, 16
.set G_D, 20
.set G_FI, 24
.set G_FJ, 28
.set G_FN, 32
.set G_PH, 36

// ---------------------------------------------------------------- driver
// void pl_preset_attraction(u32 p, u32 k, float *out): raw pl-box matrix
// of preset p for k types into out[i*16 + j]; the rest of out is zeroed.
        .globl pl_preset_attraction
        .type pl_preset_attraction, %function
pl_preset_attraction:
        ENTER
        ADR_L   x9, cell_fns
        ldr     x23, [x9, w0, uxtw #3]
        mov     w21, w1                         // n
        mov     x22, x2                         // out
        mov     x0, x2
        mov     w1, #0
        mov     x2, #1024
        bl      memset
        ADR_L   x24, g_out
        str     x22, [x24, #G_OUT]
        str     w21, [x24, #G_N]
        scvtf   s0, w21
        str     s0, [x24, #G_FN]
        mov     w19, #0                         // i
1:      cmp     w19, w21
        b.hs    9f
        mov     w20, #0                         // j
2:      cmp     w20, w21
        b.hs    8f
        str     w19, [x24, #G_I]
        str     w20, [x24, #G_J]
        add     w9, w20, w21
        sub     w9, w9, w19
        udiv    w10, w9, w21
        msub    w9, w10, w21, w9
        str     w9, [x24, #G_D]
        scvtf   s0, w19
        str     s0, [x24, #G_FI]
        scvtf   s1, w20
        str     s1, [x24, #G_FJ]
        fsub    s2, s1, s0
        LDRS    s3, K_TAU, x9
        fmul    s2, s2, s3
        ldr     s3, [x24, #G_FN]
        fdiv    s2, s2, s3
        str     s2, [x24, #G_PH]
        blr     x23
        add     w9, w20, w19, lsl #4
        str     s0, [x22, x9, lsl #2]
        add     w20, w20, #1
        b       2b
8:      add     w19, w19, #1
        b       1b
9:      LEAVE

// ---------------------------------------------------------------- cells
// Return the attraction in s0. May clobber all caller-saved registers.
// g_d is in [1, n-1] whenever i != j, so "j == (i + k) % n" is "d == k" and
// "j == (i + n - k) % n" is "d == n - k"; both are simply never true when
// k >= n, as in the Rust code.

.macro RETC c
        LDRS    s0, \c, x9
        ret
.endm
.macro GV
        ADR_L   x9, g_out
.endm
.macro DIAG c                           // i == j -> c
        GV
        ldr     w10, [x9, #G_I]
        ldr     w11, [x9, #G_J]
        cmp     w10, w11
        b.ne    77f
        RETC    \c
77:
.endm
.macro IFD k, lbl                       // d == k -> lbl
        GV
        ldr     w10, [x9, #G_D]
        cmp     w10, #\k
        b.eq    \lbl
.endm
.macro IFDN k, lbl                      // d == n - k -> lbl
        GV
        ldr     w10, [x9, #G_N]
        sub     w10, w10, #\k
        ldr     w11, [x9, #G_D]
        cmp     w10, w11
        b.eq    \lbl
.endm
// frame for cells that call libm: lr + 16 bytes of locals at [sp, #16]
.macro CENTER
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
.endm
.macro CLEAVE
        ldp     x29, x30, [sp], #32
        ret
.endm

c_random:
        fmov    s0, #-1.0
        fmov    s1, #1.0
        b       pl_rng_range

c_symmetric:                            // upper triangle drawn row-major, mirrored
        GV
        ldr     w10, [x9, #G_I]
        ldr     w11, [x9, #G_J]
        cmp     w11, w10
        b.hs    c_random
        add     w11, w10, w11, lsl #4   // j*16 + i
        ldr     x12, [x9, #G_OUT]
        ldr     s0, [x12, x11, lsl #2]
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
        GV
        ldr     w10, [x9, #G_I]
        ldr     w11, [x9, #G_J]
        eor     w10, w10, w11
        tbnz    w10, #0, 1f
        RETC    K_0_8
1:      RETC    K_M0_8

c_hub:
        DIAG    K_0
        GV
        ldr     w10, [x9, #G_I]
        cbz     w10, 1f
        ldr     w10, [x9, #G_J]
        cbz     w10, 2f
        RETC    K_0
1:      RETC    K_1
2:      RETC    K_0_6

c_shells:
        DIAG    K_0_9
        IFD     1, 1f
        RETC    K_M0_6
1:      RETC    K_0_3

c_swirl:        // upper: |j-i| <= n/2 ? 0.7 : -0.7, lower: the negation
        DIAG    K_M0_05
        GV
        ldr     w10, [x9, #G_J]
        ldr     w11, [x9, #G_I]
        subs    w10, w10, w11
        ldr     w12, [x9, #G_N]
        lsr     w12, w12, #1
        b.mi    2f
        cmp     w10, w12
        b.ls    1f
        RETC    K_M0_7
1:      RETC    K_0_7
2:      neg     w10, w10
        cmp     w10, w12
        b.ls    3f
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
        GV
        ldr     w10, [x9, #G_I]
        eor     w10, w10, #1
        ldr     w11, [x9, #G_J]
        cmp     w10, w11
        b.eq    1f
        RETC    K_M0_9
1:      RETC    K_1

c_triad:
        DIAG    K_0_1
        GV
        mov     w12, #3
        ldr     w10, [x9, #G_I]
        udiv    w10, w10, w12
        ldr     w11, [x9, #G_J]
        udiv    w11, w11, w12
        cmp     w10, w11
        b.eq    1f
        RETC    K_M0_7
1:      RETC    K_0_9

c_conveyor:
        DIAG    K_M0_1
        IFD     1, 1f
        IFD     2, 2f
        RETC    K_M0_6
1:      RETC    K_0_7
2:      RETC    K_0_3

c_patchwork:    // r = |fract(sin(h as f32) * 43758.5453)|, h = i*73856093 ^ j*19349663
        DIAG    K_0
        CENTER
        GV
        ldr     w10, [x9, #G_I]
        MOV32   w12, 73856093
        mul     x10, x10, x12
        ldr     w11, [x9, #G_J]
        MOV32   w12, 19349663
        mul     x11, x11, x12
        eor     x10, x10, x11
        scvtf   s0, x10
        bl      sinf
        LDRS    s1, K_43758, x9
        fmul    s0, s0, s1
        fmov    s1, #1.0
        bl      fmodf
        fabs    s0, s0
        LDRS    s1, K_0_35, x9
        fcmp    s0, s1
        b.lt    1f
        fadd    s1, s1, s1              // 2 * p
        fcmp    s0, s1
        b.lt    2f
        LDRS    s0, K_0, x9
        CLEAVE
1:      LDRS    s0, K_0_9, x9
        CLEAVE
2:      LDRS    s0, K_M0_9, x9
        CLEAVE

c_wave:
        DIAG    K_M0_05
        CENTER
        GV
        ldr     s0, [x9, #G_PH]
        bl      sinf
        LDRS    s1, K_0_9, x9
        fmul    s0, s0, s1
        CLEAVE

c_chiral:       // ph = TAU*d/n: 0.5 sin(ph) + 0.3 sin(2 ph) + 0.15
        DIAG    K_M0_05
        CENTER
        GV
        ldr     w10, [x9, #G_D]
        scvtf   s0, w10
        LDRS    s1, K_TAU, x11
        fmul    s0, s0, s1
        ldr     s1, [x9, #G_FN]
        fdiv    s0, s0, s1
        str     s0, [sp, #16]
        bl      sinf
        LDRS    s1, K_0_5, x9
        fmul    s0, s0, s1
        str     s0, [sp, #20]
        ldr     s0, [sp, #16]
        fmov    s1, #2.0
        fmul    s0, s0, s1
        bl      sinf
        LDRS    s1, K_0_3, x9
        fmul    s0, s0, s1
        ldr     s1, [sp, #20]
        fadd    s0, s0, s1
        LDRS    s1, K_0_15, x9
        fadd    s0, s0, s1
        CLEAVE

c_rotconv:      // 0.8 sin(TAU (j-i)/n + i TAU/(1.5 n))
        DIAG    K_M0_05
        CENTER
        GV
        ldr     s0, [x9, #G_FN]
        fmov    s1, #1.5
        fmul    s0, s0, s1
        LDRS    s1, K_TAU, x10
        fdiv    s1, s1, s0
        ldr     s2, [x9, #G_FI]
        fmul    s1, s1, s2
        ldr     s0, [x9, #G_PH]
        fadd    s0, s0, s1
        bl      sinf
        LDRS    s1, K_0_8, x9
        fmul    s0, s0, s1
        CLEAVE

c_primehop:     // pl-box's prime p is always 2 (first prime < n, else 2)
        DIAG    K_M0_05
        GV
        ldr     w10, [x9, #G_D]
        tbnz    w10, #0, 1f
        RETC    K_0_9
1:      CENTER
        ldr     w11, [x9, #G_N]
        sub     w11, w11, w10
        cmp     w10, w11
        csel    w10, w11, w10, hi       // circular distance min(d, n-d)
        scvtf   s0, w10
        LDRS    s1, K_M0_7, x9
        fmul    s0, s0, s1
        bl      expf
        LDRS    s1, K_M0_7, x9
        fmul    s0, s0, s1
        CLEAVE

c_parity:
        DIAG    K_M0_05
        GV
        ldr     w10, [x9, #G_I]
        ldr     w11, [x9, #G_J]
        and     w10, w10, #1
        and     w11, w11, #1
        add     w10, w11, w10, lsl #1   // 2*odd(i) + odd(j)
        cmp     w10, #1
        b.eq    1f
        cmp     w10, #2
        b.eq    2f
        cbz     w10, 3f
        RETC    K_M0_6
1:      RETC    K_0_8
2:      RETC    K_0_6
3:      RETC    K_M0_4

c_helical:      // 0.7 sin(k (j-i)) + 0.4 cos(k (i+j)), k = TAU/n
        DIAG    K_M0_05
        CENTER
        GV
        LDRS    s2, K_TAU, x10
        ldr     s3, [x9, #G_FN]
        fdiv    s2, s2, s3
        str     s2, [sp, #24]
        ldr     s0, [x9, #G_FJ]
        ldr     s1, [x9, #G_FI]
        fsub    s0, s0, s1
        fmul    s0, s0, s2
        bl      sinf
        LDRS    s1, K_0_7, x9
        fmul    s0, s0, s1
        str     s0, [sp, #16]
        GV
        ldr     s0, [x9, #G_FI]
        ldr     s1, [x9, #G_FJ]
        fadd    s0, s0, s1
        ldr     s1, [sp, #24]
        fmul    s0, s0, s1
        bl      cosf
        LDRS    s1, K_0_4, x9
        fmul    s0, s0, s1
        ldr     s1, [sp, #16]
        fadd    s0, s0, s1
        CLEAVE

c_biased:
        DIAG    K_M0_05
        CENTER
        GV
        ldr     s0, [x9, #G_PH]
        bl      sinf
        LDRS    s1, K_0_75, x9
        fmul    s0, s0, s1
        LDRS    s1, K_0_15, x9
        fadd    s0, s0, s1
        CLEAVE

c_modtri:
        DIAG    K_M0_05
        GV
        mov     w12, #3
        ldr     w10, [x9, #G_I]
        udiv    w13, w10, w12
        msub    w10, w13, w12, w10      // di
        ldr     w11, [x9, #G_J]
        udiv    w13, w11, w12
        msub    w11, w13, w12, w11      // dj
        cmp     w11, w10
        b.eq    1f
        add     w10, w10, #1
        cmp     w10, #3
        csel    w10, wzr, w10, eq
        cmp     w11, w10
        b.eq    2f
        RETC    K_M0_75
1:      RETC    K_M0_2
2:      RETC    K_0_85

// x0 = circ(x0) = min((x + n) % n, (n - x) % n), signed remainders as in
// Rust's i64 %, for skipped_pursuit. Clobbers x9-x12.
circ:
        GV
        ldrsw   x10, [x9, #G_N]
        add     x11, x0, x10
        sdiv    x12, x11, x10
        msub    x11, x12, x10, x11      // a
        sub     x12, x10, x0
        sdiv    x0, x12, x10
        msub    x12, x0, x10, x12       // b
        cmp     x12, x11
        csel    x0, x11, x12, gt
        ret

c_skip:         // d == 2 ? 0.9 : -0.6 exp(-0.8 min(circ(d-2), circ(d+2)))
        DIAG    K_M0_05
        IFD     2, 1f
        CENTER
        str     x19, [sp, #16]
        GV
        ldrsw   x0, [x9, #G_D]
        sub     x0, x0, #2
        bl      circ
        mov     x19, x0
        GV
        ldrsw   x0, [x9, #G_D]
        add     x0, x0, #2
        bl      circ
        cmp     x0, x19
        csel    x0, x19, x0, gt
        ldr     x19, [sp, #16]
        scvtf   s0, x0
        LDRS    s1, K_M0_8, x9
        fmul    s0, s0, s1
        bl      expf
        LDRS    s1, K_M0_6, x9
        fmul    s0, s0, s1
        CLEAVE
1:      RETC    K_0_9

// s0 = hash(w0, w1) in [0, 1] with multipliers w2, w3 (det_hash32/b).
// Clobbers x9, x10, v1.
dhash:
        mul     w0, w0, w2
        mul     w1, w1, w3
        eor     w0, w0, w1
        eor     w9, w0, w0, lsl #13
        eor     w9, w9, w0, lsr #7
        eor     w9, w9, w0, lsl #17
        ucvtf   s0, w9
        LDRS    s1, K_2P32, x10
        fdiv    s0, s0, s1
        ret

c_bluenoise:    // upper: 0.9 (h(i,j) - 0.5) 2; lower: -0.8 * upper mirror
        DIAG    K_M0_05
        CENTER
        GV
        ldr     w10, [x9, #G_I]
        ldr     w11, [x9, #G_J]
        cmp     w10, w11
        csel    w0, w10, w11, lo        // min
        csel    w1, w11, w10, lo        // max
        MOV32   w2, 73856093
        MOV32   w3, 19349663
        bl      dhash
        LDRS    s1, K_HALF, x9
        fsub    s0, s0, s1
        LDRS    s1, K_0_9, x9
        fmul    s0, s0, s1
        fmov    s1, #2.0
        fmul    s0, s0, s1
        GV
        ldr     w10, [x9, #G_I]
        ldr     w11, [x9, #G_J]
        cmp     w10, w11
        b.lo    2f
        LDRS    s1, K_M0_8, x9
        fmul    s0, s0, s1
2:      CLEAVE

c_phasefield:   // 0.8 sin(th(j) - th(i)) + 0.12 sin(th(i)), th(x) = (TAU/n * 3) x
        DIAG    K_M0_05
        CENTER
        GV
        LDRS    s2, K_TAU, x10
        ldr     s3, [x9, #G_FN]
        fdiv    s2, s2, s3
        fmov    s3, #3.0
        fmul    s2, s2, s3
        ldr     s3, [x9, #G_FI]
        fmul    s1, s2, s3              // th(i)
        str     s1, [sp, #24]
        ldr     s3, [x9, #G_FJ]
        fmul    s0, s2, s3              // th(j)
        fsub    s0, s0, s1
        bl      sinf
        LDRS    s1, K_0_8, x9
        fmul    s0, s0, s1
        str     s0, [sp, #16]
        ldr     s0, [sp, #24]
        bl      sinf
        LDRS    s1, K_0_12, x9
        fmul    s0, s0, s1
        ldr     s1, [sp, #16]
        fadd    s0, s0, s1
        CLEAVE

c_ringroad:     // circular distance <= 1: 0.85, <= max(ceil(n/3), 2): 0.2, else -0.8
        DIAG    K_M0_05
        GV
        ldr     w10, [x9, #G_D]
        ldr     w11, [x9, #G_N]
        sub     w11, w11, w10
        cmp     w10, w11
        csel    w10, w11, w10, hi
        cmp     w10, #1
        b.ls    1f
        ldr     s0, [x9, #G_FN]
        fmov    s1, #3.0
        fdiv    s0, s0, s1
        frintp  s0, s0                  // ceil
        fcvtzs  w11, s0
        cmp     w11, #2
        mov     w12, #2
        csel    w11, w12, w11, lo
        cmp     w10, w11
        b.ls    2f
        RETC    K_M0_8
1:      RETC    K_0_85
2:      RETC    K_0_2

c_trispiral:    // 0.7 sin(ph) + 0.55 sin(3 ph)
        DIAG    K_M0_05
        CENTER
        GV
        ldr     s0, [x9, #G_PH]
        bl      sinf
        LDRS    s1, K_0_7, x9
        fmul    s0, s0, s1
        str     s0, [sp, #16]
        GV
        ldr     s0, [x9, #G_PH]
        fmov    s1, #3.0
        fmul    s0, s0, s1
        bl      sinf
        LDRS    s1, K_0_55, x9
        fmul    s0, s0, s1
        ldr     s1, [sp, #16]
        fadd    s0, s0, s1
        CLEAVE

c_vortex:       // (+-0.6 by parity of i+j) sin(ph)
        DIAG    K_M0_05
        CENTER
        GV
        ldr     s0, [x9, #G_PH]
        bl      sinf
        GV
        ldr     w10, [x9, #G_I]
        ldr     w11, [x9, #G_J]
        add     w10, w10, w11
        LDRS    s1, K_0_6, x11
        tbz     w10, #0, 1f
        LDRS    s1, K_M0_6, x11
1:      fmul    s0, s0, s1
        CLEAVE

c_drift:        // (0.75 sin(ph) + 0.12) * (hash_b(i,j) < 0.6 ? 1 : 0)
        DIAG    K_M0_05
        CENTER
        GV
        ldr     s0, [x9, #G_PH]
        bl      sinf
        LDRS    s1, K_0_75, x9
        fmul    s0, s0, s1
        LDRS    s1, K_0_12, x9
        fadd    s0, s0, s1
        str     s0, [sp, #16]
        GV
        ldr     w0, [x9, #G_I]
        ldr     w1, [x9, #G_J]
        MOV32   w2, 2654435761
        MOV32   w3, 1597334677
        bl      dhash
        movi    d1, #0
        LDRS    s2, K_0_6, x9
        fcmp    s0, s2
        b.ge    1f
        fmov    s1, #1.0
1:      ldr     s0, [sp, #16]
        fmul    s0, s0, s1              // multiply, not select: keeps pl-box's -0.0
        CLEAVE

// ---------------------------------------------------------------- apply
// void pl_preset_rules(u32 rule): install rule generator `rule` for the
// current K: physics (force scale, friction, core), attraction clamped to
// [-1, 1], per-pair radii drawn from the preset's ranges as in
// RuleMatrix::from_preset, then rebuild every derived table, the grid, the
// neighbour ranges and the kernel choice.
        .globl pl_preset_rules
        .type pl_preset_rules, %function
pl_preset_rules:
        ENTER   16
        ADR_L   x19, pl
        mov     w20, w0
        ADR_L   x21, pl_preset_phys
        add     x21, x21, x20, lsl #5
        ldr     w9, [x21, #0]
        str     w9, [x19, #PL_FSCALE]
        ldr     w9, [x21, #4]
        str     w9, [x19, #PL_FRIC]
        ldr     w9, [x21, #8]
        str     w9, [x19, #PL_CORE]

        mov     w0, w20
        ldr     w1, [x19, #PL_K]
        ADR_L   x2, raw
        bl      pl_preset_attraction
        ADR_L   x9, raw
        add     x10, x19, #PL_ATTR
        ADDL    x11, x19, PL_MINR
        ADDL    x12, x19, PL_MAXRT
        fmov    v1.4s, #-1.0
        fmov    v2.4s, #1.0
        movi    v3.2d, #0
        mov     w13, #64
1:      ld1     {v0.4s}, [x9], #16
        fmax    v0.4s, v1.4s, v0.4s
        fmin    v0.4s, v2.4s, v0.4s
        st1     {v0.4s}, [x10], #16
        st1     {v3.4s}, [x11], #16
        st1     {v3.4s}, [x12], #16
        subs    w13, w13, #1
        b.ne    1b

        mov     w22, #0                         // i
2:      ldr     w9, [x19, #PL_K]
        cmp     w22, w9
        b.hs    5f
        mov     w23, #0                         // j
3:      ldr     w9, [x19, #PL_K]
        cmp     w23, w9
        b.hs    4f
        add     w24, w23, w22, lsl #4           // idx
        ldr     s0, [x21, #12]
        ldr     s1, [x21, #16]
        bl      pl_rng_range
        ADDL    x9, x19, PL_MINR
        str     s0, [x9, x24, lsl #2]
        str     s0, [sp]
        ldr     s0, [x21, #20]
        ldr     s1, [x21, #24]
        bl      pl_rng_range
        ldr     s1, [sp]
        fcmp    s1, s0
        b.lt    31f
        fmov    s2, #1.0
        fadd    s0, s1, s2                      // min >= max: max = min + 1
31:     ADDL    x9, x19, PL_MAXRT
        str     s0, [x9, x24, lsl #2]
        add     w23, w23, #1
        b       3b
4:      add     w22, w22, #1
        b       2b
5:      UNFRAME 16
        b       pl_update_tables

// ---------------------------------------------------------------- entries
// u32 pl_entry_rule(u32 e): rule generator of entry e. Clobbers x9, x10.
        .globl pl_entry_rule
        .type pl_entry_rule, %function
pl_entry_rule:
        cmp     w0, #NCURATED
        b.hs    1f
        add     w9, w0, w0, lsl #1
        ADR_L   x10, pl_curated
        ldrb    w0, [x10, x9]
        ret
1:      sub     w0, w0, #NCURATED
        ret

// u32 pl_entry_types(u32 e): the curated type count, 0 for a generated
// entry (its count is drawn per switch)
        .globl pl_entry_types
        .type pl_entry_types, %function
pl_entry_types:
        cmp     w0, #NCURATED
        b.hs    1f
        add     w9, w0, w0, lsl #1
        ADR_L   x10, pl_curated
        add     x10, x10, #1
        ldrb    w0, [x10, x9]
        ret
1:      mov     w0, #0
        ret

// const char *pl_entry_name(u32 e)
        .globl pl_entry_name
        .type pl_entry_name, %function
pl_entry_name:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        bl      pl_entry_rule
        ADR_L   x9, pl_preset_names
        ldr     x0, [x9, w0, uxtw #3]
        ldp     x29, x30, [sp], #16
        ret

// void pl_entry_install(u32 e, u32 k): K = k (1..16), entry e's rules and
// physics, every derived table, grid and kernel; marks e shown. The caller
// then spawns the particles.
        .globl pl_entry_install
        .type pl_entry_install, %function
pl_entry_install:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        ADR_L   x9, pl
        str     w1, [x9, #PL_K]
        ADR_L   x9, pl_preset_cur
        str     w0, [x9]
        ADR_L   x9, pl_preset_shown
        ldr     x10, [x9]
        mov     x11, #1
        lsl     x11, x11, x0                    // shift amount taken mod 64
        orr     x10, x10, x11
        str     x10, [x9]
        bl      pl_entry_rule
        ldp     x29, x30, [sp], #16
        b       pl_preset_rules

// void pl_preset_apply(u32 rule): rule generator `rule` for the current K
// with uniform particles (used by the tests as a rule-level switch)
        .globl pl_preset_apply
        .type pl_preset_apply, %function
pl_preset_apply:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        bl      pl_preset_rules
        ldp     x29, x30, [sp], #16
        b       pl_random_particles

// void pl_pool_set(u32 pool): 0 curated, 1 generated, 2 all
        .globl pl_pool_set
        .type pl_pool_set, %function
pl_pool_set:
        cmp     w0, #2
        csel    w0, wzr, w0, hi
        ADR_L   x9, pl_pool
        str     w0, [x9]
        ADR_L   x9, pool_masks
        ldr     x10, [x9, w0, uxtw #3]
        ADR_L   x9, pl_pool_mask
        str     x10, [x9]
        ret

// ---------------------------------------------------------------- shuffle bag
// u32 pl_preset_pick(void): a random entry of the pool that has not been
// shown in this round and is not the current one. When every entry of the
// pool has been shown, a new round starts with only the current one marked.
// A pool of one entry returns that entry.
        .globl pl_preset_pick
        .type pl_preset_pick, %function
pl_preset_pick:
        ENTER2
        LDRS    x9, pl_pool_mask, x12           // mask
        LDRS    x10, pl_preset_shown, x12       // shown
        LDRS    w11, pl_preset_cur, x12
        sxtw    x11, w11                        // cur
        mov     x13, #1
        lsl     x13, x13, x11                   // 1 << cur (when cur >= 0)
        tbnz    x11, #63, 1f
        orr     x10, x10, x13
1:      bics    x19, x9, x10                    // available
        b.ne    2f
        bic     x10, x10, x9                    // new round: keep other pools' bits
        tbnz    x11, #63, 11f
        orr     x10, x10, x13                   // only the current one shown
11:     ADR_L   x12, pl_preset_shown
        str     x10, [x12]
        bics    x19, x9, x10
        b.ne    2f
        mov     x19, x9                         // single-entry pool
2:      bl      pl_rng_u64
        lsr     x0, x0, #32
        fmov    d0, x19
        cnt     v0.8b, v0.8b
        addv    b0, v0.8b
        fmov    w9, s0
        mul     x0, x0, x9
        lsr     x0, x0, #32                     // r in [0, count)
3:      cbz     w0, 4f
        sub     x9, x19, #1
        and     x19, x19, x9                    // drop r lowest candidates
        sub     w0, w0, #1
        b       3b
4:      rbit    x0, x19
        clz     x0, x0
        LEAVE2

// u32 pl_types_draw(void): a type count for a generated entry, uniform 2..16
        .globl pl_types_draw
        .type pl_types_draw, %function
pl_types_draw:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        bl      pl_rng_u64
        lsr     x0, x0, #32
        mov     x9, #15
        mul     x0, x0, x9
        lsr     x0, x0, #32
        add     w0, w0, #2
        ldp     x29, x30, [sp], #16
        ret

// int pl_entry_find(const char *name): entry by display or enum name,
// case-insensitive; curated entries first unless the pool is "generated";
// "c:NAME" / "g:NAME" pick the list explicitly. -1 if unknown.
        .globl pl_entry_find
        .type pl_entry_find, %function
pl_entry_find:
        ENTER2
        LDRS    w20, pl_pool, x9                // 1 = generated first
        ldrb    w9, [x0, #1]
        cmp     w9, #':'
        b.ne    1f
        ldrb    w9, [x0]
        orr     w9, w9, #0x20
        add     x0, x0, #2
        mov     w20, #3                         // curated only
        cmp     w9, #'c'
        b.eq    1f
        mov     w20, #4                         // generated only
        cmp     w9, #'g'
        b.ne    8f
1:      bl      pl_preset_find
        tbnz    w0, #31, 9f
        mov     w19, w0                         // rule
        cmp     w20, #1
        b.eq    5f
        cmp     w20, #4
        b.eq    5f
        mov     w10, #0                         // curated entry with this rule?
        ADR_L   x11, pl_curated
2:      add     w9, w10, w10, lsl #1
        ldrb    w9, [x11, x9]
        cmp     w9, w19
        b.eq    3f
        add     w10, w10, #1
        cmp     w10, #NCURATED
        b.lo    2b
        cmp     w20, #3
        b.eq    8f
        b       5f
3:      mov     w0, w10
        b       9f
5:      add     w0, w19, #NCURATED
        b       9f
8:      mov     w0, #-1
9:      LEAVE2

// int pl_preset_find(const char *name): index by display or enum name,
// case-insensitive, or -1
        .globl pl_preset_find
        .type pl_preset_find, %function
pl_preset_find:
        ENTER4
        mov     x20, x0
        mov     w19, #0
1:      cmp     w19, #NPRESETS
        b.hs    8f
        ADR_L   x9, pl_preset_names
        ldr     x1, [x9, x19, lsl #3]
        mov     x0, x20
        bl      strcasecmp
        cbz     w0, 9f
        ADR_L   x9, enum_names
        ldr     x1, [x9, x19, lsl #3]
        cbz     x1, 2f
        mov     x0, x20
        bl      strcasecmp
        cbz     w0, 9f
2:      add     w19, w19, #1
        b       1b
8:      mov     w19, #-1
9:      mov     w0, w19
        LEAVE4
