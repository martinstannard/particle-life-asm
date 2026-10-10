# Particle Life simulation core, x86-64 / AVX2 / AVX-512F, GNU as.
#
# Per step:
#   1. force kernel: for every cell, for every particle i in it, sum the force
#      from all particles in the 3x3 neighbouring cells (SIMD over j), then
#      integrate (semi-implicit Euler, friction, toroidal wrap) and write the
#      new position to nx/ny and the new velocity in place.
#   2. bin: counting sort of (nx, ny, vx, vy, type, id) by cell into the
#      second buffer set, then swap the sets. Particles stay cell-ordered, so
#      the neighbour cells of a cell row are one contiguous index range.
#
# Force law (pl-box rules.rs/simulation.rs):
#   d >= maxr          : 0
#   d <  minr          : -core * (1 - d/minr)
#   minr <= d < maxr   : attraction * smoothstep(1 - (d-minr)/(maxr-minr))
#   F += dir * f * force_scale
# Rewritten per pair with s = (maxr - d)/(maxr - minr) = b0 - d*ir, so that
# s > 1 <=> d < minr and s <= 0 <=> d >= maxr; no explicit range mask needed.
# The kernels accumulate g = f/d times (dx, dy) and use
#   core branch:  g = (d*c1 - core)/d = c1 - core/d
#   attraction:   g = attraction * sc^2 (3 - 2 sc) / d,   sc = clamp(s, 0, 1)
# with 1/d from rsqrt + one Newton step. The Newton step's factor 1/2 is folded
# into the tables (exact powers of two): the kernel works with i2 = 2/d and
# d2 = 2d, so TIR = ir/2, TAS = -attraction*force_scale/2 (sign absorbs
# 2sc - 3), CORES = core*force_scale/2.

        .intel_syntax noprefix
        .include "layout.inc"

        .section .rodata
        .balign 64
V_HALF:   .rept 8
          .float 0.5
          .endr
V_THREE:  .rept 8
          .float 3.0
          .endr
V_ZERO:   .rept 8
          .float 0.0
          .endr
V_IOTA:   .long 0,1,2,3,4,5,6,7
F_ONE:    .float 1.0
F_EPS:    .float 1.0e-8           # min d^2 (pl-box clamps d >= 1e-4)
F_2M24:   .float 5.9604644775390625e-8
F_M1:     .float -1.0
F_P1:     .float 1.0
F_MINR0:  .float 12.0
F_MINR1:  .float 24.0
F_MAXR0:  .float 33.0
F_MAXR1:  .float 70.0
F_ZEROS:  .float 0.0
F_HALF:   .float 0.5
F_MHALF:  .float -0.5
F_TWO:    .float 2.0

        .bss
        .balign 64
        .globl pl
pl:     .skip PL_SIZE

        .text

# ---------------------------------------------------------------- RNG
# splitmix64 on pl.rng. Returns rax. Clobbers rcx.
        .globl pl_rng_u64
pl_rng_u64:
        mov     rax, [rip + pl + PL_RNG]
        movabs  rcx, 0x9E3779B97F4A7C15
        add     rax, rcx
        mov     [rip + pl + PL_RNG], rax
        mov     rcx, rax
        shr     rcx, 30
        xor     rax, rcx
        movabs  rcx, 0xBF58476D1CE4E5B9
        imul    rax, rcx
        mov     rcx, rax
        shr     rcx, 27
        xor     rax, rcx
        movabs  rcx, 0x94D049BB133111EB
        imul    rax, rcx
        mov     rcx, rax
        shr     rcx, 31
        xor     rax, rcx
        ret

# xmm0 = uniform [0,1) with 24 random bits. Clobbers rax, rcx.
pl_rng_f01:
        call    pl_rng_u64
        shr     rax, 40
        vcvtsi2ss xmm0, xmm0, rax
        vmulss  xmm0, xmm0, [rip + F_2M24]
        ret

# xmm0 = fma(b - a, u, a) for a = xmm0, b = xmm1. Clobbers xmm2, xmm3.
        .globl pl_rng_range
pl_rng_range:
        vmovaps xmm2, xmm0
        vsubss  xmm3, xmm1, xmm0
        call    pl_rng_f01
        vfmadd213ss xmm0, xmm3, xmm2
        ret

# ---------------------------------------------------------------- alloc
# int pl_alloc(u32 n): (re)allocate all particle arrays for n particles.
        .globl pl_alloc
pl_alloc:
        push    rbx
        push    r12
        push    r13                     # rsp aligned
        mov     r12d, edi
        mov     ebx, PL_X
1:      lea     r13, [rip + pl]
        mov     rdi, [r13 + rbx]
        call    free@PLT
        lea     edi, [r12d + PAD]
        mov     esi, 4
        call    calloc@PLT
        lea     r13, [rip + pl]
        mov     [r13 + rbx], rax
        test    rax, rax
        jz      9f
        add     ebx, 8
        cmp     ebx, PL_CELLID
        jbe     1b
        mov     [rip + pl + PL_N], r12d
        mov     [rip + pl + PL_CAP], r12d
        xor     eax, eax
        jmp     8f
9:      mov     eax, -1
8:      pop     r13
        pop     r12
        pop     rbx
        ret


# ---------------------------------------------------------------- rules
# void pl_random_rules(void): for every (i,j) < K draw attraction in [-1,1),
# minr in [12,24), maxr in [33,70) (pl-box render defaults), then
# rebuild the derived tables and the grid.
        .globl pl_random_rules
pl_random_rules:
        push    rbx
        push    r12
        push    r13
        lea     r13, [rip + pl]
        xor     ebx, ebx                # i
1:      cmp     ebx, [r13 + PL_K]
        jae     4f
        xor     r12d, r12d              # j
2:      cmp     r12d, [r13 + PL_K]
        jae     3f
        mov     eax, ebx
        shl     eax, 4
        add     eax, r12d
        push    rax
        push    rax
        vmovss  xmm0, [rip + F_M1]
        vmovss  xmm1, [rip + F_P1]
        call    pl_rng_range
        mov     rax, [rsp]
        vmovss  [r13 + PL_ATTR + rax*4], xmm0
        vmovss  xmm0, [rip + F_MINR0]
        vmovss  xmm1, [rip + F_MINR1]
        call    pl_rng_range
        mov     rax, [rsp]
        vmovss  [r13 + PL_MINR + rax*4], xmm0
        vmovss  xmm0, [rip + F_MAXR0]
        vmovss  xmm1, [rip + F_MAXR1]
        call    pl_rng_range
        pop     rax
        pop     rax
        vmovss  [r13 + PL_MAXRT + rax*4], xmm0
        inc     r12d
        jmp     2b
3:      inc     ebx
        jmp     1b
4:      pop     r13
        pop     r12
        pop     rbx
        jmp     pl_update_tables

# ---------------------------------------------------------------- tables
# void pl_update_tables(void): derived per-pair tables, damping, grid
# geometry, cell arrays, neighbour-range table and kernel selection.
        .globl pl_update_tables
pl_update_tables:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 16                 # rsp aligned
        lea     r15, [rip + pl]

        vmovss  xmm0, [r15 + PL_CORE]
        vmulss  xmm0, xmm0, [r15 + PL_FSCALE]
        vmovss  [rsp], xmm0                     # core_s
        vmulss  xmm0, xmm0, [rip + F_HALF]
        vmovss  [r15 + PL_CORES], xmm0          # core_s / 2
        vmovss  xmm1, [r15 + PL_FRIC]
        vmulss  xmm1, xmm1, [r15 + PL_DT]
        vmovss  xmm2, [rip + F_ONE]
        vsubss  xmm1, xmm2, xmm1
        vmovss  [r15 + PL_DAMP], xmm1

        vxorps  xmm7, xmm7, xmm7        # global max radius
        xor     ebx, ebx
1:      cmp     ebx, [r15 + PL_K]
        jae     4f
        xor     r12d, r12d
2:      cmp     r12d, [r15 + PL_K]
        jae     3f
        mov     eax, ebx
        shl     eax, 4
        add     eax, r12d
        vmovss  xmm1, [r15 + PL_MINR + rax*4]
        vmovss  xmm2, [r15 + PL_MAXRT + rax*4]
        vmaxss  xmm7, xmm7, xmm2
        vsubss  xmm3, xmm2, xmm1
        vmovss  xmm4, [rip + F_ONE]
        vdivss  xmm3, xmm4, xmm3        # ir
        vmulss  xmm4, xmm2, xmm3        # b0 = maxr * ir
        vmovss  [r15 + PL_TB0 + rax*4], xmm4
        vmulss  xmm3, xmm3, [rip + F_HALF]
        vmovss  [r15 + PL_TIR + rax*4], xmm3    # ir / 2
        vmovss  xmm4, [rsp]
        vdivss  xmm4, xmm4, xmm1        # c1 = core_s / minr
        vmovss  [r15 + PL_TC1 + rax*4], xmm4
        vmovss  xmm4, [r15 + PL_ATTR + rax*4]
        vmulss  xmm4, xmm4, [r15 + PL_FSCALE]
        vmulss  xmm4, xmm4, [rip + F_MHALF]
        vmovss  [r15 + PL_TAS + rax*4], xmm4    # -attraction * force_scale / 2
        inc     r12d
        jmp     2b
3:      inc     ebx
        jmp     1b
4:      vmovss  [r15 + PL_MAXR], xmm7

        # grid: cell >= maxr / R, at least 2R+1 cells per axis
        mov     eax, [r15 + PL_CDIV]
        lea     ecx, [eax - 1]
        cmp     ecx, MAXCDIV - 1
        jbe     41f
        mov     eax, 1
        mov     [r15 + PL_CDIV], eax
41:     lea     ecx, [eax*4 + 2]
        mov     [r15 + PL_NRANGE], ecx
        vcvtsi2ss xmm1, xmm1, eax
        vdivss  xmm7, xmm7, xmm1                # min cell size
        lea     ecx, [eax*2 + 1]                # min cells per axis
        vmovss  xmm0, [r15 + PL_W]
        vdivss  xmm1, xmm0, xmm7
        vcvttss2si eax, xmm1
        cmp     eax, ecx
        cmovl   eax, ecx
        mov     [r15 + PL_COLS], eax
        vcvtsi2ss xmm1, xmm1, eax
        vdivss  xmm2, xmm0, xmm1
        vmovss  [r15 + PL_CW], xmm2
        vmovss  xmm3, [rip + F_ONE]
        vdivss  xmm3, xmm3, xmm2
        vmovss  [r15 + PL_ICW], xmm3
        vmovss  xmm0, [r15 + PL_H]
        vdivss  xmm1, xmm0, xmm7
        vcvttss2si eax, xmm1
        cmp     eax, ecx
        cmovl   eax, ecx
        mov     [r15 + PL_ROWS], eax
        vcvtsi2ss xmm1, xmm1, eax
        vdivss  xmm2, xmm0, xmm1
        vmovss  [r15 + PL_CH], xmm2
        vmovss  xmm3, [rip + F_ONE]
        vdivss  xmm3, xmm3, xmm2
        vmovss  [r15 + PL_ICH], xmm3
        imul    eax, [r15 + PL_COLS]
        mov     [r15 + PL_NCELLS], eax

        cmp     eax, [r15 + PL_CELLCAP]
        jbe     5f
        mov     [r15 + PL_CELLCAP], eax
        mov     rdi, [r15 + PL_CSTART]
        call    free@PLT
        mov     rdi, [r15 + PL_CCUR]
        call    free@PLT
        mov     rdi, [r15 + PL_NBR]
        call    free@PLT
        mov     edi, [r15 + PL_CELLCAP]
        add     edi, 1
        mov     esi, 4
        call    calloc@PLT
        mov     [r15 + PL_CSTART], rax
        mov     edi, [r15 + PL_CELLCAP]
        add     edi, 1
        mov     esi, 4
        call    calloc@PLT
        mov     [r15 + PL_CCUR], rax
        mov     edi, [r15 + PL_CELLCAP]
        mov     esi, NBR_STRIDE
        call    calloc@PLT
        mov     [r15 + PL_NBR], rax

        # neighbour ranges: per cell, per neighbour row ry = cy-R..cy+R, two
        # entries {first cell, last cell + 1, shift x, shift y} covering
        # columns cx-R..cx+R; the second is empty unless the row wraps in x.
5:      mov     r14, [r15 + PL_NBR]
        mov     r10d, [r15 + PL_COLS]
        mov     r11d, [r15 + PL_ROWS]
        mov     r12d, [r15 + PL_CDIV]
        xor     r8d, r8d                # cy
6:      cmp     r8d, r11d
        jae     12f
        xor     r9d, r9d                # cx
7:      cmp     r9d, r10d
        jae     11f
        mov     rdx, r14
        mov     ecx, r12d
        neg     ecx                     # d = -R
8:      lea     eax, [r8d + ecx]        # ry
        xor     edi, edi                # sy bits
        test    eax, eax
        jns     81f
        add     eax, r11d
        mov     edi, [r15 + PL_H]
        xor     edi, 0x80000000         # -H
        jmp     82f
81:     cmp     eax, r11d
        jb      82f
        sub     eax, r11d
        mov     edi, [r15 + PL_H]       # +H
82:     imul    eax, r10d               # base = ry * cols
        mov     [rdx + 12], edi
        mov     [rdx + 28], edi
        mov     esi, r9d
        sub     esi, r12d               # lo = cx - R
        lea     ebx, [r9d + r12d]       # hi = cx + R
        test    esi, esi
        jns     83f
        # lo < 0: [base, base+hi+1) shift 0; [base+cols+lo, base+cols) shift -W
        mov     [rdx + 0], eax
        lea     edi, [eax + ebx + 1]
        mov     [rdx + 4], edi
        mov     dword ptr [rdx + 8], 0
        lea     edi, [eax + r10d]
        add     edi, esi
        mov     [rdx + 16], edi
        lea     edi, [eax + r10d]
        mov     [rdx + 20], edi
        mov     edi, [r15 + PL_W]
        xor     edi, 0x80000000
        mov     [rdx + 24], edi
        jmp     85f
83:     cmp     ebx, r10d
        jb      84f
        # hi >= cols: [base+lo, base+cols) shift 0; [base, base+hi-cols+1) shift +W
        lea     edi, [eax + esi]
        mov     [rdx + 0], edi
        lea     edi, [eax + r10d]
        mov     [rdx + 4], edi
        mov     dword ptr [rdx + 8], 0
        mov     [rdx + 16], eax
        lea     edi, [eax + ebx + 1]
        sub     edi, r10d
        mov     [rdx + 20], edi
        mov     edi, [r15 + PL_W]
        mov     [rdx + 24], edi
        jmp     85f
84:     # interior: [base+lo, base+hi+1) shift 0, second entry empty
        lea     edi, [eax + esi]
        mov     [rdx + 0], edi
        lea     edi, [eax + ebx + 1]
        mov     [rdx + 4], edi
        mov     dword ptr [rdx + 8], 0
        mov     qword ptr [rdx + 16], 0
        mov     qword ptr [rdx + 24], 0
85:     add     rdx, 32
        inc     ecx
        cmp     ecx, r12d
        jle     8b
        add     r14, NBR_STRIDE
        inc     r9d
        jmp     7b
11:     inc     r8d
        jmp     6b

        # kernel selection
12:     lea     rax, [rip + pl_kernel_avx512]
        cmp     dword ptr [r15 + PL_SIMD], 2
        je      13f
        lea     rax, [rip + pl_kernel_avx2_k8]
        cmp     dword ptr [r15 + PL_K], 8
        jbe     13f
        lea     rax, [rip + pl_kernel_avx2_k16]
13:     mov     [r15 + PL_KERNEL], rax

        add     rsp, 16
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

# ---------------------------------------------------------------- particles
# void pl_random_particles(void): uniform positions in the world, zero
# velocity, uniform type in [0,K), ids 0..N-1; then bin.
        .globl pl_random_particles
pl_random_particles:
        push    rbx
        push    r12
        push    r13
        lea     r13, [rip + pl]
        xor     ebx, ebx
1:      cmp     ebx, [r13 + PL_N]
        jae     2f
        vxorps  xmm0, xmm0, xmm0
        vmovss  xmm1, [r13 + PL_W]
        call    pl_rng_range
        mov     rax, [r13 + PL_NX]
        vmovss  [rax + rbx*4], xmm0
        vxorps  xmm0, xmm0, xmm0
        vmovss  xmm1, [r13 + PL_H]
        call    pl_rng_range
        mov     rax, [r13 + PL_NY]
        vmovss  [rax + rbx*4], xmm0
        call    pl_rng_u64
        shr     rax, 32
        mov     ecx, [r13 + PL_K]
        imul    rax, rcx
        shr     rax, 32
        mov     rcx, [r13 + PL_T]
        mov     [rcx + rbx*4], eax
        mov     rcx, [r13 + PL_ID]
        mov     [rcx + rbx*4], ebx
        mov     rcx, [r13 + PL_VX]
        mov     dword ptr [rcx + rbx*4], 0
        mov     rcx, [r13 + PL_VY]
        mov     dword ptr [rcx + rbx*4], 0
        inc     ebx
        jmp     1b
2:      pop     r13
        pop     r12
        pop     rbx
        jmp     pl_bin

# ---------------------------------------------------------------- bin
# void pl_bin(void): stable counting sort of the current set by the cell of
# (nx, ny) into the second set, then swap the sets. Particles are already
# nearly cell-ordered, so counts and cursors are kept in registers for runs
# of equal cells instead of read-modify-writing memory per particle.

.macro SCATTER src, dst
        mov     r8, [r15 + \src]
        mov     r9, [r15 + \dst]
        xor     esi, esi
1:      cmp     esi, edx
        jae     2f
        mov     eax, [r10 + rsi*4]
        mov     ecx, [r8 + rsi*4]
        mov     [r9 + rax*4], ecx
        inc     esi
        jmp     1b
2:
.endm

        .globl pl_bin
pl_bin:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15
        lea     r15, [rip + pl]

        mov     rdi, [r15 + PL_CSTART]
        mov     ecx, [r15 + PL_NCELLS]
        inc     ecx
        xor     eax, eax
        rep stosd

        # pass 1a: cell ids, 8 at a time (arrays are padded)
        mov     r8, [r15 + PL_NX]
        mov     r9, [r15 + PL_NY]
        mov     r10, [r15 + PL_CELLID]
        mov     r11, [r15 + PL_CSTART]
        mov     edx, [r15 + PL_N]
        vbroadcastss ymm4, [r15 + PL_ICW]
        vbroadcastss ymm5, [r15 + PL_ICH]
        vpbroadcastd ymm8, [r15 + PL_COLS]
        vpcmpeqd ymm9, ymm9, ymm9               # -1
        vpaddd  ymm6, ymm8, ymm9                # cols-1
        vpbroadcastd ymm7, [r15 + PL_ROWS]
        vpaddd  ymm7, ymm7, ymm9                # rows-1
        xor     esi, esi
1:      cmp     esi, edx
        jae     2f
        vmulps  ymm0, ymm4, [r8 + rsi*4]
        vcvttps2dq ymm0, ymm0
        vpminud ymm0, ymm0, ymm6                # unsigned clamp
        vmulps  ymm1, ymm5, [r9 + rsi*4]
        vcvttps2dq ymm1, ymm1
        vpminud ymm1, ymm1, ymm7
        vpmulld ymm1, ymm1, ymm8
        vpaddd  ymm0, ymm0, ymm1
        vmovdqu [r10 + rsi*4], ymm0
        add     esi, 8
        jmp     1b
2:      vzeroupper

        # pass 1b: run-length counts into cstart[c+1]
        test    edx, edx
        jz      5f
        mov     ebx, [r10]                      # current cell
        xor     ecx, ecx                        # run length
        xor     esi, esi
3:      mov     eax, [r10 + rsi*4]
        cmp     eax, ebx
        je      4f
        add     [r11 + rbx*4 + 4], ecx
        mov     ebx, eax
        xor     ecx, ecx
4:      inc     ecx
        inc     esi
        cmp     esi, edx
        jb      3b
        add     [r11 + rbx*4 + 4], ecx

        # prefix sum -> starts, copy to cursors
5:      mov     rdi, [r15 + PL_CCUR]
        mov     ecx, [r15 + PL_NCELLS]
        xor     eax, eax
        xor     esi, esi
6:      add     eax, [r11 + rsi*4]
        mov     [r11 + rsi*4], eax
        mov     [rdi + rsi*4], eax
        inc     esi
        cmp     esi, ecx
        jbe     6b

        # pass 2a: destination index per particle (overwrites cellid)
        test    edx, edx
        jz      9f
        mov     ebx, [r10]                      # current cell
        mov     ecx, [rdi + rbx*4]              # its cursor
        xor     esi, esi
7:      mov     eax, [r10 + rsi*4]
        cmp     eax, ebx
        je      8f
        mov     [rdi + rbx*4], ecx
        mov     ebx, eax
        mov     ecx, [rdi + rbx*4]
8:      mov     [r10 + rsi*4], ecx
        inc     ecx
        inc     esi
        cmp     esi, edx
        jb      7b
        mov     [rdi + rbx*4], ecx

        # pass 2b: one scatter per array
9:      SCATTER PL_NX, PL_X2
        SCATTER PL_NY, PL_Y2
        SCATTER PL_VX, PL_VX2
        SCATTER PL_VY, PL_VY2
        SCATTER PL_T,  PL_T2
        SCATTER PL_ID, PL_ID2

        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        # fall through

# void pl_swap_sets(void): exchange the current and the second particle set
        .globl pl_swap_sets
pl_swap_sets:
        lea     rax, [rip + pl]
        vmovdqu ymm0, [rax + PL_X]
        vmovdqu ymm1, [rax + PL_X2]
        vmovdqu xmm2, [rax + PL_X + 32]
        vmovdqu xmm3, [rax + PL_X2 + 32]
        vmovdqu [rax + PL_X2], ymm0
        vmovdqu [rax + PL_X], ymm1
        vmovdqu [rax + PL_X2 + 32], xmm2
        vmovdqu [rax + PL_X + 32], xmm3
        vzeroupper
        ret

# ---------------------------------------------------------------- parallel bin
# The same stable counting sort split over T threads (called by threads.S
# between barriers): particle chunk t = [lo, hi) with 16-aligned bounds,
# per-thread histograms hist[t][c], cell blocks for the prefix sum. The
# resulting order is identical to pl_bin.

        .globl pbin_hist, pbin_cap
        .bss
        .balign 8
pbin_hist:      .skip 8                 # u32 [T][ncells+1]
pbin_cap:       .skip 4                 # allocated u32 entries
        .balign 64
pbin_blocksum:  .skip 4 * 64
        .text

# (eax, edx) = bounds [lo, hi) of part edi of esi items, lo 16-aligned.
# Clobbers rcx, r8, r9.
pbounds:
        mov     r8d, [rip + pl + PL_NTHREADS]
        mov     r9d, esi
        mov     eax, esi
        imul    rax, rdi
        xor     edx, edx
        div     r8
        and     eax, -16
        mov     ecx, eax                        # lo
        lea     eax, [edi + 1]
        cmp     eax, r8d
        jae     1f
        imul    rax, r9
        xor     edx, edx
        div     r8
        and     eax, -16
        mov     edx, eax
        mov     eax, ecx
        ret
1:      mov     edx, r9d
        mov     eax, ecx
        ret

# phase 1: cell ids of chunk t, run-length counts into hist[t]
        .globl pl_pbin_count
pl_pbin_count:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15
        lea     r15, [rip + pl]
        mov     r12d, edi
        mov     esi, [r15 + PL_N]
        call    pbounds
        mov     r13d, eax                       # lo
        mov     r14d, edx                       # hi
        mov     ecx, [r15 + PL_NCELLS]
        inc     ecx
        mov     eax, ecx
        imul    eax, r12d
        mov     rbx, [rip + pbin_hist]
        lea     rbx, [rbx + rax*4]              # hist[t]
        mov     rdi, rbx
        xor     eax, eax
        rep stosd

        mov     r8, [r15 + PL_NX]
        mov     r9, [r15 + PL_NY]
        mov     r10, [r15 + PL_CELLID]
        vbroadcastss ymm4, [r15 + PL_ICW]
        vbroadcastss ymm5, [r15 + PL_ICH]
        vpbroadcastd ymm8, [r15 + PL_COLS]
        vpcmpeqd ymm9, ymm9, ymm9
        vpaddd  ymm6, ymm8, ymm9
        vpbroadcastd ymm7, [r15 + PL_ROWS]
        vpaddd  ymm7, ymm7, ymm9
        mov     esi, r13d
1:      cmp     esi, r14d
        jae     2f
        vmulps  ymm0, ymm4, [r8 + rsi*4]
        vcvttps2dq ymm0, ymm0
        vpminud ymm0, ymm0, ymm6
        vmulps  ymm1, ymm5, [r9 + rsi*4]
        vcvttps2dq ymm1, ymm1
        vpminud ymm1, ymm1, ymm7
        vpmulld ymm1, ymm1, ymm8
        vpaddd  ymm0, ymm0, ymm1
        vmovdqu [r10 + rsi*4], ymm0
        add     esi, 8
        jmp     1b
2:      vzeroupper
        cmp     r13d, r14d
        jae     5f
        mov     esi, r13d
        mov     edx, [r10 + rsi*4]              # current cell
        xor     ecx, ecx
3:      mov     eax, [r10 + rsi*4]
        cmp     eax, edx
        je      4f
        add     [rbx + rdx*4], ecx
        mov     edx, eax
        xor     ecx, ecx
4:      inc     ecx
        inc     esi
        cmp     esi, r14d
        jb      3b
        add     [rbx + rdx*4], ecx
5:      pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

# phase 2: total count of cell block t over all threads
        .globl pl_pbin_sum
pl_pbin_sum:
        push    rbx
        push    r12
        mov     r12d, edi
        mov     esi, [rip + pl + PL_NCELLS]
        call    pbounds
        mov     r10d, [rip + pl + PL_NCELLS]
        inc     r10d                            # hist stride
        mov     r11d, [rip + pl + PL_NTHREADS]
        mov     rbx, [rip + pbin_hist]
        xor     r9d, r9d                        # sum
        xor     r8d, r8d                        # t'
1:      cmp     r8d, r11d
        jae     3f
        mov     ecx, eax
2:      cmp     ecx, edx
        jae     21f
        add     r9d, [rbx + rcx*4]
        inc     ecx
        jmp     2b
21:     lea     rbx, [rbx + r10*4]
        inc     r8d
        jmp     1b
3:      lea     rcx, [rip + pbin_blocksum]
        mov     [rcx + r12*4], r9d
        pop     r12
        pop     rbx
        ret

# phase 3: cell starts and per-thread cursors for cell block t
        .globl pl_pbin_offsets
pl_pbin_offsets:
        push    rbx
        push    r12
        push    r13
        mov     r12d, edi
        mov     esi, [rip + pl + PL_NCELLS]
        call    pbounds
        lea     rcx, [rip + pbin_blocksum]
        xor     r9d, r9d                        # base
        xor     r8d, r8d
1:      cmp     r8d, r12d
        jae     2f
        add     r9d, [rcx + r8*4]
        inc     r8d
        jmp     1b
2:      mov     r10d, [rip + pl + PL_NCELLS]
        inc     r10d                            # stride
        mov     r11d, [rip + pl + PL_NTHREADS]
        mov     rbx, [rip + pbin_hist]
        mov     r13, [rip + pl + PL_CSTART]
        mov     ecx, eax                        # c
3:      cmp     ecx, edx
        jae     5f
        mov     [r13 + rcx*4], r9d
        lea     rsi, [rbx + rcx*4]
        xor     r8d, r8d
4:      mov     eax, [rsi]
        mov     [rsi], r9d
        add     r9d, eax
        lea     rsi, [rsi + r10*4]
        inc     r8d
        cmp     r8d, r11d
        jb      4b
        inc     ecx
        jmp     3b
5:      lea     eax, [r12d + 1]
        cmp     eax, r11d
        jne     6f
        mov     ecx, [rip + pl + PL_NCELLS]
        mov     eax, [rip + pl + PL_N]
        mov     [r13 + rcx*4], eax
6:      pop     r13
        pop     r12
        pop     rbx
        ret

# phase 4: destinations of chunk t from its cursors, then scatter it
.macro PSCATTER src, dst
        mov     r8, [r15 + \src]
        mov     r9, [r15 + \dst]
        mov     esi, r13d
1:      cmp     esi, r14d
        jae     2f
        mov     eax, [r10 + rsi*4]
        mov     ecx, [r8 + rsi*4]
        mov     [r9 + rax*4], ecx
        inc     esi
        jmp     1b
2:
.endm

        .globl pl_pbin_scatter
pl_pbin_scatter:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15
        lea     r15, [rip + pl]
        mov     r12d, edi
        mov     esi, [r15 + PL_N]
        call    pbounds
        mov     r13d, eax
        mov     r14d, edx
        cmp     r13d, r14d
        jae     9f
        mov     eax, [r15 + PL_NCELLS]
        inc     eax
        imul    eax, r12d
        mov     rbx, [rip + pbin_hist]
        lea     rbx, [rbx + rax*4]              # cursors of thread t
        mov     r10, [r15 + PL_CELLID]
        mov     esi, r13d
        mov     edx, [r10 + rsi*4]
        mov     ecx, [rbx + rdx*4]
1:      mov     eax, [r10 + rsi*4]
        cmp     eax, edx
        je      2f
        mov     [rbx + rdx*4], ecx
        mov     edx, eax
        mov     ecx, [rbx + rdx*4]
2:      mov     [r10 + rsi*4], ecx
        inc     ecx
        inc     esi
        cmp     esi, r14d
        jb      1b
        mov     [rbx + rdx*4], ecx
        PSCATTER PL_NX, PL_X2
        PSCATTER PL_NY, PL_Y2
        PSCATTER PL_VX, PL_VX2
        PSCATTER PL_VY, PL_VY2
        PSCATTER PL_T,  PL_T2
        PSCATTER PL_ID, PL_ID2
9:      pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

# ---------------------------------------------------------------- kernels
# void kernel(u32 c_begin, u32 c_end)
#
# Registers in the j loop:
#   rsi x[], rdi y[], r8 type[], r9 table row of type(i), r10 j, r11 j_end
#   AVX2:   ymm0 xi-sx, ymm1 yi-sy, ymm2/3 fx/fy accumulators, ymm4/5 dx/dy,
#           ymm6..11 temps, ymm12 1.0, ymm13 0.0 (K<=8) or temp (K<=16),
#           ymm14 core_s (K<=8) or type bit-3 mask (K<=16), ymm15 eps
#   AVX512: zmm16..19 table rows (b0, ir, c1, as), zmm20.. constants, k1 lane
#           mask, k2 repulsion mask
# Frame: [rsp] c_end, [rsp+4] xi, [rsp+8] yi, [rsp+12] 2*ranges,
#        [rsp+32] core_s/2 x8, [rsp+64] up to 10 ranges {u32 j0, u32 j1, f32 sx, f32 sy}

.set TOFF_B0, 0
.set TOFF_IR, 1024
.set TOFF_C1, 2048
.set TOFF_AS, 3072

# per-pair table lookup by ymm9 = type(j)
.macro LOOKUP2 wide, dst, off
        vpermps \dst, ymm9, [r9 + \off]
.if \wide
        vpermps ymm13, ymm9, [r9 + \off + 32]
        vblendvps \dst, \dst, ymm13, ymm14
.endif
.endm

.macro BODY2 wide, tail
        vsubps  ymm4, ymm0, [rsi + r10*4]       # -dx (load folded)
        vsubps  ymm5, ymm1, [rdi + r10*4]       # -dy
        vmovaps ymm6, ymm5
        vfmadd213ps ymm6, ymm5, ymm15           # dy^2 + eps
        vfmadd231ps ymm6, ymm4, ymm4            # d^2 + eps
        vrsqrtps ymm7, ymm6                     # r ~ 1/d, 12 bits
        vmulps  ymm8, ymm6, ymm7                # h = d^2 r
        vmovaps ymm6, ymm7
        vfnmadd213ps ymm6, ymm8, [rip + V_THREE] # e = 3 - h r
        vmulps  ymm7, ymm7, ymm6                # i2 = r e  = 2/d
        vmulps  ymm8, ymm8, ymm6                # d2 = h e  = 2d
        vmovdqu ymm9, [r8 + r10*4]              # type(j)
.if \wide
        vpslld  ymm14, ymm9, 28
.endif
        LOOKUP2 \wide, ymm10, TOFF_B0
        LOOKUP2 \wide, ymm11, TOFF_IR
        vfnmadd231ps ymm10, ymm8, ymm11         # s = b0 - d*ir
        LOOKUP2 \wide, ymm11, TOFF_AS
        vmulps  ymm11, ymm11, ymm7              # -a/d
        LOOKUP2 \wide, ymm8, TOFF_C1
.if \wide
        vfnmadd231ps ymm8, ymm7, [rsp + 32]     # core: c1 - core/d
        vmaxps  ymm6, ymm10, [rip + V_ZERO]
.else
        vfnmadd231ps ymm8, ymm7, ymm14          # core: c1 - core/d
        vmaxps  ymm6, ymm10, ymm13              # sc (s > 1 lanes are discarded)
.endif
        vmulps  ymm7, ymm6, ymm6                # sc^2
        vaddps  ymm6, ymm6, ymm6
        vsubps  ymm6, ymm6, [rip + V_THREE]     # 2sc - 3
        vmulps  ymm11, ymm11, ymm7
        vmulps  ymm11, ymm11, ymm6              # attraction: a sc^2 (3-2sc) / d
        vcmpps  ymm10, ymm10, ymm12, 0x1e       # s > 1  <=>  d < minr
        vblendvps ymm6, ymm11, ymm8, ymm10      # g = f / d
.if \tail
        mov     eax, r11d
        sub     eax, r10d
        vmovd   xmm7, eax
        vpbroadcastd ymm7, xmm7
        vpcmpgtd ymm7, ymm7, [rip + V_IOTA]
        vandps  ymm6, ymm6, ymm7
.endif
        vfnmadd231ps ymm2, ymm6, ymm4           # F += g * dx
        vfnmadd231ps ymm3, ymm6, ymm5
.endm

# Software-pipelined AVX-512 stages for full 16-lane vectors. Stage 1 (loads,
# distance, 1/d, table lookups) for vector j+1 is issued next to stage 2
# (smoothstep, branch select, accumulate) of vector j, so that the long
# dependency chain of one vector does not fill the out-of-order window.
# A register set is {dx, dy, s, a/d, core branch}. Lanes outside the range
# get dx = dy = 0 from the zero-masked loads and so contribute exactly 0.
.macro S1_512 dx, dy, s, ad, cb
        vsubps  \dx{k1}{z}, zmm0, [rsi + r10*4] # -dx (load folded), 0 in unused lanes
        vsubps  \dy{k1}{z}, zmm1, [rdi + r10*4] # -dy
        vmovaps zmm6, \dy
        vfmadd213ps zmm6, \dy, zmm23            # dy^2 + eps
        vfmadd231ps zmm6, \dx, \dx              # d^2 + eps
        vrsqrt14ps zmm7, zmm6
        vmulps  \cb, zmm6, zmm7                 # h
        vmovaps zmm6, zmm7
        vfnmadd213ps zmm6, \cb, zmm27           # e
        vmulps  zmm7, zmm7, zmm6                # i2
        vmulps  \cb, \cb, zmm6                  # d2
        vmovdqu32 zmm9{k1}{z}, [r8 + r10*4]
        add     r10d, 16
        vpermps \s, zmm9, zmm16
        vpermps \ad, zmm9, zmm17
        vfnmadd231ps \s, \cb, \ad               # s
        vpermps \ad, zmm9, zmm19
        vmulps  \ad, \ad, zmm7
        vpermps \cb, zmm9, zmm18
        vfnmadd231ps \cb, zmm7, zmm22           # core branch
.endm

# Advance the j stream of particle i: r10 = j, r11 = range end, ecx = range
# index * 2. Moves to the next non-empty range when the current one is used up
# (updating xi-sx / yi-sy in zmm0/zmm1), sets k1 to the valid lanes of
# [j, j+16) and advances j by 16; jumps to \done when all ranges are used up.
.macro NEXTVEC name, done
        cmp     r10d, r11d
        jb      2f
1:      add     ecx, 2
        cmp     ecx, [rsp + 12]
        jae     \done
        mov     r10d, [rsp + 64 + rcx*8]
        mov     r11d, [rsp + 68 + rcx*8]
        cmp     r10d, r11d
        jae     1b
        vmovss  xmm0, [rsp + 4]
        vsubss  xmm0, xmm0, [rsp + 72 + rcx*8]
        vbroadcastss zmm0, xmm0
        vmovss  xmm1, [rsp + 8]
        vsubss  xmm1, xmm1, [rsp + 76 + rcx*8]
        vbroadcastss zmm1, xmm1
2:      mov     eax, r11d
        sub     eax, r10d
        mov     edx, 16
        cmp     eax, edx
        cmova   eax, edx                        # bzhi only looks at 8 index bits
        mov     edx, 0xffff
        bzhi    edx, edx, eax                   # (1 << min(n,16)) - 1
        kmovw   k1, edx
.endm

.macro S2_512 dx, dy, s, ad, cb
        vmaxps  zmm28, \s, zmm21                # sc (s > 1 lanes are discarded)
        vmulps  zmm29, zmm28, zmm28
        vfmsub213ps zmm28, zmm26, zmm27         # 2sc - 3
        vmulps  \ad, \ad, zmm29
        vcmpps  k2, \s, zmm20, 0x12             # s <= 1: attraction lanes
        vmulps  \cb{k2}, \ad, zmm28             # merge attraction into core branch
        vfnmadd231ps zmm2, \cb, \dx             # F += g * dx
        vfnmadd231ps zmm3, \cb, \dy
.endm

# x = xmm7 wrapped into [0, extent) for extent at [r15 + off]; clobbers xmm8
.macro WRAP off
        vxorps  xmm8, xmm8, xmm8
        vucomiss xmm7, xmm8
        jae     1f
        vaddss  xmm7, xmm7, [r15 + \off]
        jmp     2f
1:      vucomiss xmm7, [r15 + \off]
        jb      2f
        vsubss  xmm7, xmm7, [r15 + \off]
2:
.endm

# mode: 0 AVX2 K<=8, 1 AVX2 K<=16, 2 AVX-512 K<=16
.macro KERNEL name, mode
        .globl \name
\name:
        push    rbp
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 232
        lea     r15, [rip + pl]
        mov     [rsp], esi
        mov     eax, [r15 + PL_NRANGE]
        add     eax, eax
        mov     [rsp + 12], eax                 # 2 * ranges per cell
        mov     ebp, edi
        vbroadcastss ymm14, [r15 + PL_CORES]
        vmovups [rsp + 32], ymm14
.if \mode == 2
        vbroadcastss zmm20, [rip + F_ONE]
        vxorps  xmm21, xmm21, xmm21
        vbroadcastss zmm22, [r15 + PL_CORES]
        vbroadcastss zmm23, [rip + F_EPS]
        vbroadcastss zmm26, [rip + F_TWO]
        vbroadcastss zmm27, [rip + V_THREE]
.else
        vbroadcastss ymm12, [rip + F_ONE]
        vxorps  xmm13, xmm13, xmm13
        vbroadcastss ymm15, [rip + F_EPS]
.endif
        mov     rsi, [r15 + PL_X]
        mov     rdi, [r15 + PL_Y]
        mov     r8,  [r15 + PL_T]

.L\name\()_cell:
        cmp     ebp, [rsp]
        jae     .L\name\()_done
        mov     rax, [r15 + PL_CSTART]
        mov     r12d, [rax + rbp*4]             # i
        mov     r13d, [rax + rbp*4 + 4]         # i_end
        cmp     r12d, r13d
        jae     .L\name\()_next_cell

        # neighbour cell ranges -> particle index ranges
        imul    rbx, rbp, NBR_STRIDE
        add     rbx, [r15 + PL_NBR]
        xor     ecx, ecx
.L\name\()_fill:
        mov     r9d, [rbx + rcx*8]
        mov     r9d, [rax + r9*4]
        mov     [rsp + 64 + rcx*8], r9d
        mov     r9d, [rbx + rcx*8 + 4]
        mov     r9d, [rax + r9*4]
        mov     [rsp + 68 + rcx*8], r9d
        mov     r9, [rbx + rcx*8 + 8]
        mov     [rsp + 72 + rcx*8], r9
        add     ecx, 2
        cmp     ecx, [rsp + 12]
        jb      .L\name\()_fill

.L\name\()_i:
        mov     eax, [rsi + r12*4]
        mov     [rsp + 4], eax
        mov     eax, [rdi + r12*4]
        mov     [rsp + 8], eax
        mov     eax, [r8 + r12*4]
        shl     eax, 6
        lea     r9, [r15 + PL_TB0]
        add     r9, rax                         # table row of type(i)
.if \mode == 2
        vmovups zmm16, [r9 + TOFF_B0]
        vmovups zmm17, [r9 + TOFF_IR]
        vmovups zmm18, [r9 + TOFF_C1]
        vmovups zmm19, [r9 + TOFF_AS]
        vxorps  xmm2, xmm2, xmm2
        vxorps  xmm3, xmm3, xmm3
.else
        vxorps  xmm2, xmm2, xmm2
        vxorps  xmm3, xmm3, xmm3
.endif
.if \mode == 2
        # all vectors of all ranges form one stream through the 2-stage
        # pipeline; NEXTVEC sets k1 for the next 16 j or jumps to \done
        mov     ecx, -2                         # range index * 2
        xor     r10d, r10d                      # j
        xor     r11d, r11d                      # end of current range
        NEXTVEC \name, .L\name\()_fin
        S1_512  zmm4, zmm5, zmm10, zmm11, zmm8
.L\name\()_stream:
        NEXTVEC \name, .L\name\()_finA
        S1_512  zmm12, zmm13, zmm14, zmm15, zmm24
        S2_512  zmm4, zmm5, zmm10, zmm11, zmm8
        NEXTVEC \name, .L\name\()_finB
        S1_512  zmm4, zmm5, zmm10, zmm11, zmm8
        S2_512  zmm12, zmm13, zmm14, zmm15, zmm24
        jmp     .L\name\()_stream
.L\name\()_finA:
        S2_512  zmm4, zmm5, zmm10, zmm11, zmm8
        jmp     .L\name\()_fin
.L\name\()_finB:
        S2_512  zmm12, zmm13, zmm14, zmm15, zmm24
.L\name\()_fin:
.else
        xor     ecx, ecx                        # range index * 2
.L\name\()_range:
        mov     r10d, [rsp + 64 + rcx*8]
        mov     r11d, [rsp + 68 + rcx*8]
        cmp     r10d, r11d
        jae     .L\name\()_next_range
        vmovss  xmm0, [rsp + 4]
        vsubss  xmm0, xmm0, [rsp + 72 + rcx*8]
        vmovss  xmm1, [rsp + 8]
        vsubss  xmm1, xmm1, [rsp + 76 + rcx*8]
        vbroadcastss ymm0, xmm0
        vbroadcastss ymm1, xmm1
        lea     eax, [r10d + 8]
        cmp     eax, r11d
        ja      .L\name\()_tail
.L\name\()_vec:
        BODY2   \mode, 0
        add     r10d, 8
        lea     eax, [r10d + 8]
        cmp     eax, r11d
        jbe     .L\name\()_vec
.L\name\()_tail:
        cmp     r10d, r11d
        jae     .L\name\()_next_range
        BODY2   \mode, 1
.L\name\()_next_range:
        add     ecx, 2
        cmp     ecx, [rsp + 12]
        jb      .L\name\()_range

.endif
        # horizontal sums -> xmm2 = fx, xmm3 = fy
.if \mode == 2
        vextractf64x4 ymm6, zmm2, 1
        vaddps  ymm2, ymm2, ymm6
        vextractf64x4 ymm6, zmm3, 1
        vaddps  ymm3, ymm3, ymm6
.endif
        vextractf128 xmm6, ymm2, 1
        vaddps  xmm2, xmm2, xmm6
        vmovhlps xmm6, xmm2, xmm2
        vaddps  xmm2, xmm2, xmm6
        vmovshdup xmm6, xmm2
        vaddss  xmm2, xmm2, xmm6
        vextractf128 xmm6, ymm3, 1
        vaddps  xmm3, xmm3, xmm6
        vmovhlps xmm6, xmm3, xmm3
        vaddps  xmm3, xmm3, xmm6
        vmovshdup xmm6, xmm3
        vaddss  xmm3, xmm3, xmm6

        # integrate: v = v*damp + f*dt; p = p + v*dt; wrap
        mov     rax, [r15 + PL_VX]
        vmovss  xmm6, [rax + r12*4]
        vmulss  xmm6, xmm6, [r15 + PL_DAMP]
        vfmadd231ss xmm6, xmm2, [r15 + PL_DT]
        vmovss  [rax + r12*4], xmm6
        vmovss  xmm7, [rsp + 4]
        vfmadd231ss xmm7, xmm6, [r15 + PL_DT]
        WRAP    PL_W
        mov     rax, [r15 + PL_NX]
        vmovss  [rax + r12*4], xmm7
        mov     rax, [r15 + PL_VY]
        vmovss  xmm6, [rax + r12*4]
        vmulss  xmm6, xmm6, [r15 + PL_DAMP]
        vfmadd231ss xmm6, xmm3, [r15 + PL_DT]
        vmovss  [rax + r12*4], xmm6
        vmovss  xmm7, [rsp + 8]
        vfmadd231ss xmm7, xmm6, [r15 + PL_DT]
        WRAP    PL_H
        mov     rax, [r15 + PL_NY]
        vmovss  [rax + r12*4], xmm7

        inc     r12d
        cmp     r12d, r13d
        jb      .L\name\()_i
.L\name\()_next_cell:
        inc     ebp
        jmp     .L\name\()_cell
.L\name\()_done:
        vzeroupper
        add     rsp, 232
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        pop     rbp
        ret
.endm

        KERNEL pl_kernel_avx2_k8, 0
        KERNEL pl_kernel_avx2_k16, 1
        KERNEL pl_kernel_avx512, 2

# ---------------------------------------------------------------- step
# void pl_step(void)
        .globl pl_step
pl_step:
        push    rbx
        lea     rbx, [rip + pl]
        cmp     dword ptr [rbx + PL_NTHREADS], 1
        jbe     1f
        pop     rbx
        jmp     pl_mt_step                      # forces and bin on all threads
1:      xor     edi, edi
        mov     esi, [rbx + PL_NCELLS]
        call    [rbx + PL_KERNEL]
2:      pop     rbx
        jmp     pl_bin

# int pl_cpu_features(void): bit 0 AVX2+FMA usable, bit 1 AVX-512F usable
        .globl pl_cpu_features
pl_cpu_features:
        push    rbx
        xor     r8d, r8d
        mov     eax, 1
        cpuid
        mov     r9d, ecx
        bt      r9d, 27                 # OSXSAVE
        jnc     9f
        bt      r9d, 12                 # FMA
        jnc     9f
        xor     ecx, ecx
        xgetbv
        mov     r10d, eax
        and     eax, 6                  # XMM|YMM state
        cmp     eax, 6
        jne     9f
        mov     eax, 7
        xor     ecx, ecx
        cpuid
        bt      ebx, 5                  # AVX2
        jnc     9f
        or      r8d, 1
        bt      ebx, 16                 # AVX512F
        jnc     9f
        mov     eax, r10d
        and     eax, 0xe6               # opmask|ZMM_Hi256|Hi16_ZMM
        cmp     eax, 0xe6
        jne     9f
        or      r8d, 2
9:      mov     eax, r8d
        pop     rbx
        ret
