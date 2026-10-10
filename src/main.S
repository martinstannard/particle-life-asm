# Program entry: argument parsing, headless benchmark, frame dump and the
# SDL2 window loop. Everything here calls libc / SDL2 through the C ABI.

        .intel_syntax noprefix
        .include "layout.inc"

.set SDL_INIT_VIDEO,        0x20
.set SDL_WINDOWPOS_CENTERED,0x2FFF0000
.set SDL_RENDERER_ACCEL,    2
.set SDL_RENDERER_VSYNC,    4
.set SDL_PIXELFORMAT_ARGB8888, 0x16362004
.set SDL_TEXTUREACCESS_STREAMING, 1
.set SDL_QUIT,              0x100
.set SDL_KEYDOWN,           0x300
.set SDLK_KP_MINUS,         0x40000056
.set SDLK_KP_PLUS,          0x40000057
.set CLOCK_MONOTONIC,       1
.set SC_NPROCESSORS_ONLN,   84
.set MAX_PARTICLES,         4000000

        .section .rodata
s_particles: .asciz "--particles"
s_types:     .asciz "--types"
s_seed:      .asciz "--seed"
s_width:     .asciz "--width"
s_height:    .asciz "--height"
s_bench:     .asciz "--bench"
s_warmup:    .asciz "--warmup"
s_threads:   .asciz "--threads"
s_simd:      .asciz "--simd"
s_dump:      .asciz "--dump-frame"
s_steps:     .asciz "--steps"
s_spf:       .asciz "--steps-per-frame"
s_novsync:   .asciz "--no-vsync"
s_cdiv:      .asciz "--cell-div"
s_avx2:      .asciz "avx2"
s_avx512:    .asciz "avx512"
s_name_avx2: .asciz "avx2"
s_name_512:  .asciz "avx512"
s_title0:    .asciz "Particle Life (asm)"
s_title:     .asciz "Particle Life (asm) | %u particles, %u types | %.0f fps | step %.2f ms | %u threads %s%s"
s_paused:    .asciz " | PAUSED"
s_empty:     .asciz ""
s_usage:     .ascii "usage: particle_life [--particles N] [--types K(1-16)] [--seed S]\n"
             .ascii "         [--width W] [--height H] (>= 256)\n"
             .ascii "         [--threads T] [--simd avx2|avx512] [--cell-div 1|2]\n"
             .ascii "         [--steps-per-frame S] [--no-vsync]\n"
             .ascii "         [--bench STEPS [--warmup STEPS]]   headless benchmark\n"
             .ascii "         [--dump-frame out.ppm [--steps STEPS]] headless, writes one frame\n"
             .asciz "keys: Space pause, R new rules, N new positions, +/- particles, 1-9 types, Esc quit\n"
s_noavx2:    .asciz "error: this program needs a CPU with AVX2 and FMA\n"
s_no512:     .asciz "error: AVX-512F not available on this CPU\n"
s_nomem:     .asciz "error: out of memory\n"
s_sdlerr:    .asciz "SDL error: %s\n"
s_bench_hdr: .asciz "asm   simd=%s threads=%u particles=%u types=%u world=%ux%u cell-div=%u steps=%u (after %u warmup)\n"
s_bench_res: .asciz "      %.1f steps/s  %.3f ms/step  %.2f ns/particle-step\n"
s_dumped:    .asciz "wrote %s (%ux%u, after %u steps, %u particles)\n"
s_dumpfail:  .asciz "error: could not write %s\n"
        .balign 8
D_1E9:       .double 1.0e-9
D_1E3:       .double 1000.0
D_1E9I:      .double 1.0e9
D_HALF:      .double 0.5
F_DT:        .float 0.016666668
F_FRIC:      .float 0.4
F_FSCALE:    .float 0.3
F_CORE:      .float 0.6

# option table: {name, dest, kind} kind 0 = u32, 1 = u64, 2 = string, 3 = flag
        .section .data.rel.ro, "aw"
        .balign 8
opts:
        .quad s_particles, opt_n,       0
        .quad s_types,     opt_k,       0
        .quad s_seed,      opt_seed,    1
        .quad s_width,     opt_w,       0
        .quad s_height,    opt_h,       0
        .quad s_bench,     opt_bench,   0
        .quad s_warmup,    opt_warmup,  0
        .quad s_threads,   opt_threads, 0
        .quad s_simd,      opt_simd,    2
        .quad s_dump,      opt_dump,    2
        .quad s_steps,     opt_steps,   0
        .quad s_spf,       opt_spf,     0
        .quad s_novsync,   opt_novsync, 3
        .quad s_cdiv,      opt_cdiv,    0
        .quad 0

        .data
        .balign 8
opt_seed:    .quad 1
opt_simd:    .quad 0
opt_dump:    .quad 0
opt_n:       .long 20000
opt_k:       .long 6
opt_w:       .long 1600
opt_h:       .long 900
opt_bench:   .long 0
opt_warmup:  .long 0
opt_threads: .long 0
opt_steps:   .long 600
opt_spf:     .long 2
opt_novsync: .long 0
opt_cdiv:    .long 2

        .bss
        .balign 64
event:       .skip 64
title:       .skip 256
win:         .skip 8
ren:         .skip 8
tex:         .skip 8
pixels:      .skip 8
paused:      .skip 4

        .text

# double now(void): CLOCK_MONOTONIC seconds
now:
        sub     rsp, 24
        mov     edi, CLOCK_MONOTONIC
        mov     rsi, rsp
        call    clock_gettime@PLT
        vcvtsi2sd xmm0, xmm0, qword ptr [rsp]
        vcvtsi2sd xmm1, xmm1, qword ptr [rsp + 8]
        vfmadd231sd xmm0, xmm1, [rip + D_1E9]
        add     rsp, 24
        ret

usage:  # noreturn, may be reached with any stack alignment
        and     rsp, -16
        lea     rdi, [rip + s_usage]
        mov     rsi, [rip + stderr]
        call    fputs@PLT
        mov     edi, 2
        call    exit@PLT

die:    # rdi = message, noreturn
        and     rsp, -16
        mov     rsi, [rip + stderr]
        call    fputs@PLT
        mov     edi, 1
        call    exit@PLT

# parse argv; edi = argc, rsi = argv
parse_args:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15                     # rsp aligned
        mov     r12d, edi
        mov     r13, rsi
        mov     ebx, 1
1:      cmp     ebx, r12d
        jae     9f
        lea     r14, [rip + opts]
2:      mov     rsi, [r14]
        test    rsi, rsi
        jz      usage                   # unknown option
        mov     rdi, [r13 + rbx*8]
        call    strcmp@PLT
        test    eax, eax
        jz      3f
        add     r14, 24
        jmp     2b
3:      mov     r15, [r14 + 8]          # dest
        mov     rax, [r14 + 16]         # kind
        cmp     eax, 3
        jne     4f
        mov     dword ptr [r15], 1
        inc     ebx
        jmp     1b
4:      inc     ebx
        cmp     ebx, r12d
        jae     usage                   # missing value
        mov     rdi, [r13 + rbx*8]
        cmp     eax, 2
        jne     5f
        mov     [r15], rdi
        inc     ebx
        jmp     1b
5:      push    rax
        push    rax
        xor     esi, esi
        mov     edx, 10
        call    strtoull@PLT
        pop     rcx
        pop     rcx
        cmp     ecx, 1
        je      6f
        mov     [r15], eax
        inc     ebx
        jmp     1b
6:      mov     [r15], rax
        inc     ebx
        jmp     1b
9:      pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

# set the simulation parameters from the options and initialise
setup_sim:
        push    rbx                     # rsp aligned
        lea     rbx, [rip + pl]
        mov     eax, [rip + opt_k]
        mov     [rbx + PL_K], eax
        vcvtsi2ss xmm0, xmm0, dword ptr [rip + opt_w]
        vmovss  [rbx + PL_W], xmm0
        vcvtsi2ss xmm0, xmm0, dword ptr [rip + opt_h]
        vmovss  [rbx + PL_H], xmm0
        mov     eax, [rip + F_DT]
        mov     [rbx + PL_DT], eax
        mov     eax, [rip + F_FRIC]
        mov     [rbx + PL_FRIC], eax
        mov     eax, [rip + F_FSCALE]
        mov     [rbx + PL_FSCALE], eax
        mov     eax, [rip + F_CORE]
        mov     [rbx + PL_CORE], eax
        mov     rax, [rip + opt_seed]
        mov     [rbx + PL_RNG], rax
        mov     eax, [rip + opt_cdiv]
        mov     [rbx + PL_CDIV], eax
        mov     edi, [rip + opt_n]
        call    pl_alloc
        test    eax, eax
        jz      1f
        lea     rdi, [rip + s_nomem]
        call    die
1:      call    pl_random_rules
        call    pl_random_particles
        pop     rbx
        ret

# change particle count to edi (clamped) and respawn
set_particles:
        push    rbx
        mov     eax, 100
        cmp     edi, eax
        cmovb   edi, eax
        mov     eax, MAX_PARTICLES
        cmp     edi, eax
        cmova   edi, eax
        mov     [rip + opt_n], edi
        call    pl_alloc
        test    eax, eax
        jz      1f
        lea     rdi, [rip + s_nomem]
        call    die
1:      call    pl_random_particles
        pop     rbx
        ret

simd_name:      # rax = name of the active kernel family
        lea     rax, [rip + s_name_avx2]
        cmp     dword ptr [rip + pl + PL_SIMD], 2
        jne     1f
        lea     rax, [rip + s_name_512]
1:      ret

# ------------------------------------------------------------------ bench
bench:
        push    rbx
        push    r12
        sub     rsp, 24                 # rsp aligned
        mov     ebx, [rip + opt_warmup]
1:      test    ebx, ebx
        jz      2f
        call    pl_step
        dec     ebx
        jmp     1b
2:      call    now
        vmovsd  [rsp], xmm0
        mov     ebx, [rip + opt_bench]
3:      test    ebx, ebx
        jz      4f
        call    pl_step
        dec     ebx
        jmp     3b
4:      call    now
        vsubsd  xmm0, xmm0, [rsp]
        vmovsd  [rsp], xmm0             # elapsed seconds

        call    simd_name
        lea     rdi, [rip + s_bench_hdr]
        mov     rsi, rax
        mov     edx, [rip + pl + PL_NTHREADS]
        mov     ecx, [rip + pl + PL_N]
        mov     r8d, [rip + pl + PL_K]
        mov     r9d, [rip + opt_w]
        mov     eax, [rip + opt_warmup]
        push    rax
        mov     eax, [rip + opt_bench]
        push    rax
        mov     eax, [rip + pl + PL_CDIV]
        push    rax
        mov     eax, [rip + opt_h]
        push    rax
        xor     eax, eax
        call    printf@PLT                  # args beyond r9: h, cdiv, steps, warmup
        add     rsp, 32
        # results: steps/s, ms/step, ns/particle-step
        vcvtsi2sd xmm3, xmm3, dword ptr [rip + opt_bench]
        vmovsd  xmm4, [rsp]
        vdivsd  xmm0, xmm3, xmm4            # steps/s
        vdivsd  xmm1, xmm4, xmm3            # s/step
        vmulsd  xmm1, xmm1, [rip + D_1E3]   # ms/step
        vdivsd  xmm2, xmm4, xmm3
        vmulsd  xmm2, xmm2, [rip + D_1E9I]
        vcvtsi2sd xmm5, xmm5, dword ptr [rip + pl + PL_N]
        vdivsd  xmm2, xmm2, xmm5            # ns/particle-step
        lea     rdi, [rip + s_bench_res]
        mov     eax, 3
        call    printf@PLT
        add     rsp, 24
        pop     r12
        pop     rbx
        ret

# ------------------------------------------------------------------ dump
dump_frame:
        push    rbx
        push    r12
        sub     rsp, 8                  # rsp aligned
        mov     ebx, [rip + opt_steps]
1:      test    ebx, ebx
        jz      2f
        call    pl_step
        dec     ebx
        jmp     1b
2:      mov     edi, [rip + opt_w]
        imul    edi, [rip + opt_h]
        shl     rdi, 2
        call    malloc@PLT
        mov     r12, rax
        mov     rdi, rax
        mov     esi, [rip + opt_w]
        mov     edx, [rip + opt_h]
        call    pl_render
        mov     rdi, [rip + opt_dump]
        mov     rsi, r12
        mov     edx, [rip + opt_w]
        mov     ecx, [rip + opt_h]
        call    pl_write_ppm
        test    eax, eax
        jnz     3f
        lea     rdi, [rip + s_dumped]
        mov     rsi, [rip + opt_dump]
        mov     edx, [rip + opt_w]
        mov     ecx, [rip + opt_h]
        mov     r8d, [rip + opt_steps]
        mov     r9d, [rip + pl + PL_N]
        xor     eax, eax
        call    printf@PLT
        xor     eax, eax
        jmp     4f
3:      lea     rdi, [rip + s_dumpfail]
        mov     rsi, [rip + opt_dump]
        xor     eax, eax
        call    printf@PLT
        mov     eax, 1
4:      add     rsp, 8
        pop     r12
        pop     rbx
        ret

# ------------------------------------------------------------------ window
sdl_fail:
        and     rsp, -16
        call    SDL_GetError@PLT
        mov     rdx, rax
        mov     rdi, [rip + stderr]
        lea     rsi, [rip + s_sdlerr]
        xor     eax, eax
        call    fprintf@PLT
        mov     edi, 1
        call    exit@PLT

# handle one key, edi = SDL keycode; returns eax = 1 to quit
on_key:
        push    rbx                     # rsp aligned
        mov     ebx, edi
        xor     eax, eax
        cmp     ebx, 27                 # Esc
        jne     1f
        mov     eax, 1
        jmp     9f
1:      cmp     ebx, ' '
        jne     2f
        xor     dword ptr [rip + paused], 1
        jmp     8f
2:      cmp     ebx, 'r'
        jne     3f
        call    pl_random_rules
        jmp     8f
3:      cmp     ebx, 'n'
        jne     4f
        call    pl_random_particles
        jmp     8f
4:      cmp     ebx, '+'
        je      41f
        cmp     ebx, '='
        je      41f
        cmp     ebx, SDLK_KP_PLUS
        jne     5f
41:     mov     edi, [rip + opt_n]
        lea     edi, [edi + edi*4]
        shr     edi, 2                  # n * 5/4
        call    set_particles
        jmp     8f
5:      cmp     ebx, '-'
        je      51f
        cmp     ebx, SDLK_KP_MINUS
        jne     6f
51:     mov     edi, [rip + opt_n]
        shl     edi, 2
        mov     eax, edi
        xor     edx, edx
        mov     ecx, 5
        div     ecx                     # n * 4/5
        mov     edi, eax
        call    set_particles
        jmp     8f
6:      lea     eax, [ebx - '1']
        cmp     eax, 8
        ja      8f
        inc     eax
        mov     [rip + opt_k], eax
        mov     [rip + pl + PL_K], eax
        call    pl_random_rules
        call    pl_random_particles
8:      xor     eax, eax
9:      pop     rbx
        ret

window:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 48                 # rsp aligned; [rsp] t_title, [rsp+8] step_time, [rsp+16] frames, [rsp+24] steps
        mov     edi, SDL_INIT_VIDEO
        call    SDL_Init@PLT
        test    eax, eax
        js      sdl_fail
        lea     rdi, [rip + s_title0]
        mov     esi, SDL_WINDOWPOS_CENTERED
        mov     edx, SDL_WINDOWPOS_CENTERED
        mov     ecx, [rip + opt_w]
        mov     r8d, [rip + opt_h]
        xor     r9d, r9d
        call    SDL_CreateWindow@PLT
        test    rax, rax
        jz      sdl_fail
        mov     [rip + win], rax
        mov     rdi, rax
        mov     esi, -1
        mov     edx, SDL_RENDERER_ACCEL | SDL_RENDERER_VSYNC
        cmp     dword ptr [rip + opt_novsync], 0
        je      1f
        mov     edx, SDL_RENDERER_ACCEL
1:      call    SDL_CreateRenderer@PLT
        test    rax, rax
        jz      sdl_fail
        mov     [rip + ren], rax
        mov     rdi, rax
        mov     esi, SDL_PIXELFORMAT_ARGB8888
        mov     edx, SDL_TEXTUREACCESS_STREAMING
        mov     ecx, [rip + opt_w]
        mov     r8d, [rip + opt_h]
        call    SDL_CreateTexture@PLT
        test    rax, rax
        jz      sdl_fail
        mov     [rip + tex], rax
        mov     edi, [rip + opt_w]
        imul    edi, [rip + opt_h]
        shl     rdi, 2
        call    malloc@PLT
        mov     [rip + pixels], rax

        call    now
        vmovsd  [rsp], xmm0
        vxorpd  xmm0, xmm0, xmm0
        vmovsd  [rsp + 8], xmm0
        mov     qword ptr [rsp + 16], 0
        mov     qword ptr [rsp + 24], 0

.Lframe:
        # events
.Lpoll:
        lea     rdi, [rip + event]
        call    SDL_PollEvent@PLT
        test    eax, eax
        jz      .Lsim
        mov     eax, [rip + event]
        cmp     eax, SDL_QUIT
        je      .Lquit
        cmp     eax, SDL_KEYDOWN
        jne     .Lpoll
        mov     edi, [rip + event + 20]     # keysym.sym
        call    on_key
        test    eax, eax
        jnz     .Lquit
        jmp     .Lpoll

.Lsim:
        cmp     dword ptr [rip + paused], 0
        jne     .Ldraw
        call    now
        vmovsd  [rsp + 32], xmm0
        mov     ebx, [rip + opt_spf]
1:      test    ebx, ebx
        jz      2f
        call    pl_step
        inc     qword ptr [rsp + 24]
        dec     ebx
        jmp     1b
2:      call    now
        vsubsd  xmm0, xmm0, [rsp + 32]
        vaddsd  xmm0, xmm0, [rsp + 8]
        vmovsd  [rsp + 8], xmm0

.Ldraw:
        mov     rdi, [rip + pixels]
        mov     esi, [rip + opt_w]
        mov     edx, [rip + opt_h]
        call    pl_render
        mov     rdi, [rip + tex]
        xor     esi, esi
        mov     rdx, [rip + pixels]
        mov     ecx, [rip + opt_w]
        shl     ecx, 2
        call    SDL_UpdateTexture@PLT
        mov     rdi, [rip + ren]
        mov     rsi, [rip + tex]
        xor     edx, edx
        xor     ecx, ecx
        call    SDL_RenderCopy@PLT
        mov     rdi, [rip + ren]
        call    SDL_RenderPresent@PLT
        inc     qword ptr [rsp + 16]

        # title every 0.5 s: fps, ms per step
        call    now
        vsubsd  xmm1, xmm0, [rsp]
        vucomisd xmm1, [rip + D_HALF]
        jb      .Lframe
        vmovsd  [rsp], xmm0
        vcvtsi2sd xmm2, xmm2, qword ptr [rsp + 16]
        vdivsd  xmm0, xmm2, xmm1            # fps
        vxorpd  xmm1, xmm1, xmm1
        mov     rax, [rsp + 24]
        test    rax, rax
        jz      3f
        vcvtsi2sd xmm2, xmm2, rax
        vmovsd  xmm1, [rsp + 8]
        vdivsd  xmm1, xmm1, xmm2
        vmulsd  xmm1, xmm1, [rip + D_1E3]   # ms/step
3:      mov     qword ptr [rsp + 16], 0
        mov     qword ptr [rsp + 24], 0
        mov     qword ptr [rsp + 8], 0
        call    simd_name
        mov     r12, rax
        lea     rax, [rip + s_empty]
        lea     r13, [rip + s_paused]
        cmp     dword ptr [rip + paused], 0
        cmove   r13, rax
        lea     rdi, [rip + title]
        mov     esi, 256
        lea     rdx, [rip + s_title]
        mov     ecx, [rip + pl + PL_N]
        mov     r8d, [rip + pl + PL_K]
        mov     r9d, [rip + pl + PL_NTHREADS]
        push    r13
        push    r12
        mov     eax, 2
        call    snprintf@PLT
        add     rsp, 16
        mov     rdi, [rip + win]
        lea     rsi, [rip + title]
        call    SDL_SetWindowTitle@PLT
        jmp     .Lframe

.Lquit:
        mov     rdi, [rip + tex]
        call    SDL_DestroyTexture@PLT
        mov     rdi, [rip + ren]
        call    SDL_DestroyRenderer@PLT
        mov     rdi, [rip + win]
        call    SDL_DestroyWindow@PLT
        call    SDL_Quit@PLT
        xor     eax, eax
        add     rsp, 48
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

# ------------------------------------------------------------------ main
        .globl main
main:
        push    rbx                     # rsp aligned
        call    parse_args

        # validate
        mov     eax, [rip + opt_n]
        test    eax, eax
        jz      usage
        cmp     eax, MAX_PARTICLES
        ja      usage
        mov     eax, [rip + opt_k]
        dec     eax
        cmp     eax, MAXK - 1
        ja      usage
        cmp     dword ptr [rip + opt_w], 256
        jb      usage
        cmp     dword ptr [rip + opt_h], 256
        jb      usage
        cmp     dword ptr [rip + opt_w], 32768
        ja      usage
        cmp     dword ptr [rip + opt_h], 32768
        ja      usage
        mov     eax, [rip + opt_cdiv]
        dec     eax
        cmp     eax, MAXCDIV - 1
        ja      usage

        # SIMD selection: AVX2 required; AVX-512 by default when present
        call    pl_cpu_features
        mov     ebx, eax
        test    ebx, 1
        jnz     1f
        lea     rdi, [rip + s_noavx2]
        call    die
1:      mov     eax, 1
        test    ebx, 2
        jz      2f
        mov     eax, 2
2:      mov     [rip + pl + PL_SIMD], eax
        mov     rdi, [rip + opt_simd]
        test    rdi, rdi
        jz      4f
        lea     rsi, [rip + s_avx2]
        call    strcmp@PLT
        test    eax, eax
        jnz     3f
        mov     dword ptr [rip + pl + PL_SIMD], 1
        jmp     4f
3:      mov     rdi, [rip + opt_simd]
        lea     rsi, [rip + s_avx512]
        call    strcmp@PLT
        test    eax, eax
        jnz     usage
        test    ebx, 2
        jnz     31f
        lea     rdi, [rip + s_no512]
        call    die
31:     mov     dword ptr [rip + pl + PL_SIMD], 2

        # threads: default 1 for bench/dump, all cores for the window
4:      mov     edi, [rip + opt_threads]
        test    edi, edi
        jnz     5f
        mov     edi, 1
        mov     eax, [rip + opt_bench]
        or      rax, [rip + opt_dump]
        jnz     5f
        mov     edi, SC_NPROCESSORS_ONLN
        call    sysconf@PLT
        mov     edi, eax
5:      call    pl_threads_start

        call    setup_sim

        cmp     dword ptr [rip + opt_bench], 0
        je      6f
        call    bench
        xor     eax, eax
        jmp     9f
6:      cmp     qword ptr [rip + opt_dump], 0
        je      7f
        call    dump_frame
        jmp     9f
7:      call    window
9:      mov     edi, eax
        call    exit@PLT
