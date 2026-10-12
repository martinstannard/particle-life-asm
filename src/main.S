# Program entry: argument parsing, headless benchmark, frame dump and the
# SDL2 window loop. Everything here calls libc / SDL2 through the C ABI.
#
# A "scene" is what a switch installs: a preset (entry of src/presets.S),
# its type count, a spawn layout (src/spawn.S) and a palette
# (src/palettes.S). Every --interval seconds the window picks a new preset
# from the pool's shuffle bag and a spawn layout with pl-box's weights.

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
.set SDL_MOUSEMOTION,       0x400
.set SDL_MOUSEWHEEL,        0x403
.set SDL_FINGERDOWN,        0x700
.set SDL_FINGERUP,          0x701
.set SDL_FINGERMOTION,      0x702        # the last finger event
.set KMOD_SHIFT,            0x0003
.set SDLK_KP_MINUS,         0x40000056
.set SDLK_KP_PLUS,          0x40000057
.set SDLK_RIGHT,            0x4000004F
.set SDLK_LEFT,             0x40000050
.set NCURATED,              17
.set NENTRIES,              48
.set NSPAWNS,               18
.set CLOCK_MONOTONIC,       1
.set SC_NPROCESSORS_ONLN,   84
.set MAX_PARTICLES,         4000000
.set TEXT_ARGB,             0xFFE8E8E8
.set OTEXT_SIZE,            1024

# switch_to flags
.set KEEP_PALETTE,          1
.set KEEP_SPAWN,            2

# Touch gestures (on_touch). A gesture starts with the first finger down
# and ends when the last finger is up; travel is measured on the first
# finger, in SDL's normalised coordinates (0..1 across the window), on its
# larger axis; times are SDL event timestamps in ms. Tune here.
        .section .rodata
        .balign 4
T_TAP_MOVE:  .float 0.04             # tap / long press / two-finger tap: travel below this
T_SWIPE:     .float 0.15             # swipe: travel on the dominant axis at least this
T_EXIT_X:    .float 0.12             # exit corner (top left): x below this ...
T_EXIT_Y:    .float 0.05             # ... and y below this, a short tap there quits
T_LONG_MS:   .long 700               # long press: held at least this; a tap is shorter
.set TMAX_FINGERS,          10

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
s_keys:      .asciz "--keys"
s_touches:   .asciz "--touches"
s_preset:    .asciz "--preset"
s_interval:  .asciz "--interval"
s_mutate:    .asciz "--mutate"
s_nocycle:   .asciz "--no-cycle"
s_list:      .asciz "--list-presets"
s_headless:  .asciz "--headless"
s_fake:      .asciz "--fake-clock"
s_log:       .asciz "--log-switches"
s_evlog:     .asciz "--log-events"
s_pool:      .asciz "--pool"
s_spawn:     .asciz "--spawn"
s_lspawns:   .asciz "--list-spawns"
s_palette:   .asciz "--palette"
s_lpal:      .asciz "--list-palettes"
s_overlay:   .asciz "--overlay"
s_benchr:    .asciz "--bench-render"
s_r_start:   .asciz "start"
s_r_timer:   .asciz "timer"
s_r_space:   .asciz "space"
s_r_next:    .asciz "next"
s_r_prev:    .asciz "prev"
s_r_reroll:  .asciz "reroll"
s_r_types:   .asciz "types"
s_r_pool:    .asciz "pool"
s_r_spawn:   .asciz "spawn"
s_r_respawn: .asciz "respawn"
s_r_palette: .asciz "palette"
s_switch:    .asciz "%9.3f s  %-6s -> %2u %-13s %-9s K=%-2u spawn %-13s palette %-22s %6.2f ms  maxr %.1f grid %ux%u force %.2f fric %.2f core %.2f\n"
s_ev_log:    .asciz "%9.3f s  %-7s -> spawn %-13s palette %-22s K=%u\n"
s_mut_log:   .asciz "%9.3f s  mutate %u rule value(s)\n"
s_cycle_log: .asciz "%9.3f s  auto-cycle %s\n"
s_ovl_log:   .asciz "%9.3f s  overlay %s\n"
s_ev_video:  .asciz "events: video driver %s, %d touch device(s)\n"
s_ev_dev:    .asciz "events: touch device %d: id %lld, type %d, name '%s'\n"
s_ev_finger: .asciz "%9.3f s  event 0x%x finger touch %lld finger %lld x %.4f y %.4f pressure %.3f\n"
s_ev_mouse:  .asciz "%9.3f s  event 0x%x mouse which %d button/state %u x %d y %d\n"
s_ev_other:  .asciz "%9.3f s  event 0x%x\n"
s_touch_log: .asciz "%9.3f s  touch: %s -> %s\n"
s_badtouch:  .asciz "bad --touches event at '%s' (want d|m|u X,Y@MS[#ID])\n"
# gestures: name, action (the log) and the key on_key runs (0 = none)
s_g_tap:     .asciz "tap"
s_g_long:    .asciz "long-press"
s_g_swl:     .asciz "swipe-left"
s_g_swr:     .asciz "swipe-right"
s_g_swu:     .asciz "swipe-up"
s_g_swd:     .asciz "swipe-down"
s_g_two:     .asciz "two-finger-tap"
s_g_exit:    .asciz "exit-tap"
s_g_none:    .asciz "unrecognised"
s_g_stray:   .asciz "stray-up"
s_a_tap:     .asciz "next-scene"
s_a_long:    .asciz "reroll"
s_a_swl:     .asciz "next-preset"
s_a_swr:     .asciz "prev-preset"
s_a_swu:     .asciz "next-palette"
s_a_swd:     .asciz "overlay"
s_a_two:     .asciz "pause"
s_a_exit:    .asciz "quit"
s_a_none:    .asciz "none"
s_a_stray:   .asciz "ignored"
g_keys:      .byte ' ', 'r', '>', '<', 'k', 'f', 'z', 27, 0, 0
.set G_TAP, 0
.set G_LONG, 1
.set G_SWL, 2
.set G_SWR, 3
.set G_SWU, 4
.set G_SWD, 5
.set G_TWO, 6
.set G_EXIT, 7
.set G_NONE, 8
.set G_STRAY, 9
s_on:        .asciz "on"
s_off:       .asciz "off"
s_next_in:   .asciz "next in %.0f s"
s_cycoff:    .asciz "auto-cycle off"
s_rules:     .asciz "random rules"
s_builtin:   .asciz "built-in"
s_curated:   .asciz "curated"
s_generated: .asciz "generated"
s_listfmt:   .asciz "%2u  %-13s %-9s K=%s  force %.2f fric %.2f core %.2f minr %.0f-%.0f maxr %.0f-%.0f\n"
s_lspfmt:    .asciz "%2u  %-13s %s\n"
s_lpalfmt:   .asciz "%2u  %-30s %2u colours, qualifies for K = %s\n"
s_kdraw:     .asciz "2..16"
s_kfmt:      .asciz "%u"
s_inpat:     .asciz "(in pl-box's spawn_pattern)"
s_notpat:    .asciz ""
s_fixpat:    .asciz "(not in pl-box; in spawn_pattern in place of star)"
s_starpat:   .asciz "(pl-box's exact star: a 1 px dot; spawn_pattern uses star_fixed)"
s_badpreset: .asciz "unknown preset '%s' (see --list-presets)\n"
s_badspawn:  .asciz "unknown spawn '%s' (see --list-spawns)\n"
s_badpal:    .asciz "unknown palette '%s' (see --list-palettes)\n"
s_badpool:   .asciz "unknown pool '%s' (curated, generated or all)\n"
s_headdone:  .asciz "headless: %u frames x %u steps, %u preset switches, clock %.3f s\n"
s_avx2:      .asciz "avx2"
s_avx512:    .asciz "avx512"
s_name_avx2: .asciz "avx2"
s_name_512:  .asciz "avx512"
s_title0:    .asciz "Particle Life (asm)"
s_title:     .asciz "Particle Life (asm) | %s (%s %u/%u) | %s | %u particles, %u types | %.0f fps | step %.2f ms | spawn %s | palette %s%s"
s_paused:    .asciz " | PAUSED"
s_paused2:   .asciz "   PAUSED"
s_empty:     .asciz ""
# overlay lines
s_o1:        .asciz "FPS %.1f   step %.2f ms x%u\n"
s_o1d:       .asciz "FPS -   step %.2f ms x%u\n"
s_o2:        .asciz "%u particles   %u types   %u threads %s\n"
s_o3:        .asciz "preset %s (%s %u/%u)   pool %s\n"
s_o4:        .asciz "spawn %s\npalette %s\n%s%s"
s_usage:     .ascii "usage: particle_life [--particles N] [--types K(1-16), pins the type count]\n"
             .ascii "         [--seed S] [--width W] [--height H] (>= 256)\n"
             .ascii "         [--threads T] [--simd avx2|avx512] [--cell-div 1|2]\n"
             .ascii "         [--steps-per-frame S] [--no-vsync]\n"
             .ascii "         [--bench STEPS [--warmup STEPS]]   headless benchmark\n"
             .ascii "         [--bench-render FRAMES]  time the renderer with and without overlay\n"
             .ascii "         [--dump-frame out.ppm [--steps STEPS] [--overlay]] headless, one frame\n"
             .ascii "         [--pool curated|generated|all (default curated)]\n"
             .ascii "         [--preset NAME (c:NAME / g:NAME for curated / generated)]\n"
             .ascii "         [--spawn NAME (pins the layout)] [--palette NAME (pins it)]\n"
             .ascii "         [--interval SECONDS (default 120, 0 = off)] [--no-cycle]\n"
             .ascii "         [--mutate SECONDS (default 20, 0 = off)] re-roll 1-2 rule values\n"
             .ascii "         [--list-presets] [--list-spawns] [--list-palettes]\n"
             .ascii "         [--headless FRAMES [--fake-clock SECONDS_PER_FRAME]] no window, runs the\n"
             .ascii "                       frame loop (steps, auto-cycle) and logs switches\n"
             .ascii "         [--log-switches]\n"
             .ascii "         [--log-events] log every SDL input event and the touch devices (window)\n"
             .ascii "         [--keys STR]  feed key presses (e.g. \"r9+\") to the key handler first;\n"
             .ascii "                       '>' '<' = Right Left, 'S' = Shift+S\n"
             .ascii "         [--touches STR] feed finger events to the gesture recogniser first,\n"
             .ascii "                       e.g. \"d0.5,0.5@0 u0.5,0.5@100\" (d/m/u X,Y@MS[#FINGER])\n"
             .ascii "keys: Space next scene, Z/Return pause, Right/Left next/previous preset, P pool, C auto-cycle,\n"
             .ascii "      R re-roll, S/Shift+S next/previous spawn, N respawn, K palette,\n"
             .ascii "      [ ] fewer/more types, 1-9 types, +/- particles, F overlay, Esc quit\n"
             .ascii "touch: tap next scene, long press re-roll, swipe left/right next/previous preset,\n"
             .ascii "      swipe up palette, swipe down overlay, two-finger tap pause, tap top-left corner quit\n"
             .byte 0
s_noavx2:    .asciz "error: this program needs a CPU with AVX2 and FMA\n"
s_no512:     .asciz "error: AVX-512F not available on this CPU\n"
s_nomem:     .asciz "error: out of memory\n"
s_sdlerr:    .asciz "SDL error: %s\n"
s_bench_hdr: .asciz "asm   simd=%s threads=%u particles=%u types=%u world=%ux%u cell-div=%u steps=%u (after %u warmup)\n"
s_bench_res: .asciz "      %.1f steps/s  %.3f ms/step  %.2f ns/particle-step\n"
s_benchr_res:.asciz "render %ux%u, %u particles, %u frames: %.3f ms/frame without overlay, %.3f ms/frame with overlay; overlay alone (text + drawing) %.4f ms/frame\n"
s_dumped:    .asciz "wrote %s (%ux%u, after %u steps, %u particles, %u types, %s, spawn %s, palette %s)\n"
s_dumpfail:  .asciz "error: could not write %s\n"
        .balign 8
D_1E9:       .double 1.0e-9
D_1E3:       .double 1000.0
D_1E9I:      .double 1.0e9
D_HALF:      .double 0.5
D_ZERO:      .double 0.0
D_M1:        .double -1.0
F_DT:        .float 0.016666668
F_FRIC:      .float 0.4
F_FSCALE:    .float 0.3
F_CORE:      .float 0.6

# option table: {name, dest, kind} kind 0 = u32, 1 = u64, 2 = string, 3 = flag,
# 4 = double
        .section .data.rel.ro, "aw"
        .balign 8
g_names:     .quad s_g_tap, s_g_long, s_g_swl, s_g_swr, s_g_swu, s_g_swd, s_g_two, s_g_exit, s_g_none, s_g_stray
g_actions:   .quad s_a_tap, s_a_long, s_a_swl, s_a_swr, s_a_swu, s_a_swd, s_a_two, s_a_exit, s_a_none, s_a_stray
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
        .quad s_keys,      opt_keys,    2
        .quad s_touches,   opt_touches, 2
        .quad s_preset,    opt_preset,  2
        .quad s_interval,  opt_interval, 4
        .quad s_mutate,    opt_mutate,  4
        .quad s_nocycle,   opt_nocycle, 3
        .quad s_list,      opt_list,    3
        .quad s_headless,  opt_headless, 0
        .quad s_fake,      opt_fake,    4
        .quad s_log,       opt_log,     3
        .quad s_evlog,     opt_evlog,   3
        .quad s_pool,      opt_pool,    2
        .quad s_spawn,     opt_spawn,   2
        .quad s_lspawns,   opt_lspawns, 3
        .quad s_palette,   opt_palette, 2
        .quad s_lpal,      opt_lpal,    3
        .quad s_overlay,   opt_overlay, 3
        .quad s_benchr,    opt_benchr,  0
        .quad 0

        .data
        .balign 8
opt_seed:    .quad -1                # -1 = not given: 1, or the clock for the window
opt_simd:    .quad 0
opt_dump:    .quad 0
opt_keys:    .quad 0
opt_touches: .quad 0
opt_preset:  .quad 0
opt_pool:    .quad 0
opt_spawn:   .quad 0
opt_palette: .quad 0
opt_interval: .double 120.0
opt_mutate:  .double 20.0
mut_deadline: .double 0.0
M_ONE:       .float -1.0, 1.0
opt_fake:    .double 0.0
opt_n:       .long 20000
opt_k:       .long 0                 # 0 = not pinned
opt_w:       .long 1600
opt_h:       .long 900
opt_bench:   .long 0
opt_warmup:  .long 0
opt_threads: .long 0
opt_steps:   .long 600
opt_spf:     .long 2
opt_novsync: .long 0
opt_cdiv:    .long 2
opt_nocycle: .long 0
opt_list:    .long 0
opt_headless: .long 0
opt_log:     .long 0
opt_evlog:   .long 0
opt_lspawns: .long 0
opt_lpal:    .long 0
opt_overlay: .long 0
opt_benchr:  .long 0
start_preset: .long -1
spawn_pin:   .long -1
palette_pin: .long -1
overlay_on:  .long 1

        .bss
        .balign 64
event:       .skip 64
title:       .skip 512
otext:       .skip OTEXT_SIZE
win:         .skip 8
ren:         .skip 8
tex:         .skip 8
pixels:      .skip 8
paused:      .skip 4
cycle_on:    .skip 4
switches:    .skip 4
otext_len:   .skip 4
        .balign 8
deadline:    .skip 8                # clock time of the next automatic switch
fake_now:    .skip 8
g_fps:       .skip 8                # last measured fps (-1 = none: dump)
g_ms:        .skip 8                # last measured ms per step
cbuf:        .skip 48
kbuf:        .skip 64
tev:         .skip 48               # an SDL_TouchFingerEvent built by --touches
t_ids:       .skip 8 * TMAX_FINGERS # finger ids down now
t_first:     .skip 8                # id of the gesture's first finger
t_count:     .skip 4                # fingers down now
t_max:       .skip 4                # most fingers down at once in this gesture
t_t0:        .skip 4                # timestamp of the first finger down
t_sx:        .skip 4                # first finger: start x, y and last x, y
t_sy:        .skip 4
t_lx:        .skip 4
t_ly:        .skip 4

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

# noreturn: fprintf(stderr, rdi = format, rsi = argument); exit 2
die_arg:
        and     rsp, -16
        mov     rdx, rsi
        mov     rsi, rdi
        mov     rdi, [rip + stderr]
        xor     eax, eax
        call    fprintf@PLT
        mov     edi, 2
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
        jne     41f
        mov     [r15], rdi
        inc     ebx
        jmp     1b
41:     cmp     eax, 4
        jne     5f
        xor     esi, esi
        call    strtod@PLT
        vmovsd  [r15], xmm0
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
        test    eax, eax
        jnz     0f
        mov     eax, 6                  # until a preset sets its own
0:      mov     [rbx + PL_K], eax
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
        cmp     rax, -1
        jne     1f
        mov     eax, 1                  # bench, dump, headless: reproducible
        cmp     dword ptr [rip + opt_bench], 0
        jne     1f
        cmp     qword ptr [rip + opt_dump], 0
        jne     1f
        cmp     dword ptr [rip + opt_headless], 0
        jne     1f
        cmp     dword ptr [rip + opt_benchr], 0
        jne     1f
        call    now                     # window: a different start each run
        vmulsd  xmm0, xmm0, [rip + D_1E9I]
        vcvttsd2si rax, xmm0
1:      mov     [rbx + PL_RNG], rax
        mov     eax, [rip + opt_cdiv]
        mov     [rbx + PL_CDIV], eax
        mov     edi, [rip + opt_n]
        call    pl_alloc
        test    eax, eax
        jz      2f
        lea     rdi, [rip + s_nomem]
        call    die
        # bench, and dump without --preset: plain random rules (as before
        # presets) with uniform particles, or --spawn's layout;
        # all other modes start on a preset (--preset, or a shuffle-bag pick)
2:      mov     eax, [rip + start_preset]
        test    eax, eax
        jns     3f
        cmp     dword ptr [rip + opt_bench], 0
        jne     4f
        cmp     qword ptr [rip + opt_dump], 0
        jne     4f
        call    pl_preset_pick
3:      mov     edi, eax
        lea     rsi, [rip + s_r_start]
        xor     edx, edx
        xor     ecx, ecx
        call    switch_to
        pop     rbx
        ret
4:      call    pl_random_rules
        mov     edi, [rip + palette_pin]
        test    edi, edi
        js      41f
        call    pl_palette_set
41:     mov     edi, [rip + spawn_pin]
        test    edi, edi
        js      42f
        call    pl_spawn
        pop     rbx
        ret
42:     call    pl_random_particles
        pop     rbx
        ret

# double clock_now(void): the clock that drives auto-cycling: CLOCK_MONOTONIC,
# or the fake clock of --headless --fake-clock
clock_now:
        vxorpd  xmm0, xmm0, xmm0
        vucomisd xmm0, [rip + opt_fake]
        jae     now
        vmovsd  xmm0, [rip + fake_now]
        ret

# switch_to(u32 e, const char *reason, u32 k, u32 flags): install a scene:
# preset e with k types (k = 0: --types if given, else the preset's own
# count, else a draw 2..16), every derived table and the grid, then a spawn
# layout (KEEP_SPAWN: the current one; else --spawn's, else pl-box's
# weighted pick) and a palette (--palette's; KEEP_PALETTE: the current one
# when it still qualifies for K; otherwise a new pick). Restarts the switch
# timer and logs.
switch_to:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 48                 # rsp aligned; [rsp] t0, [rsp+8] ms, [rsp+16] clock
        mov     ebx, edi
        mov     r12, rsi
        mov     r13d, edx
        mov     r14d, ecx
        call    now
        vmovsd  [rsp], xmm0
        test    r13d, r13d
        jnz     2f
        mov     r13d, [rip + opt_k]
        test    r13d, r13d
        jnz     2f
        mov     edi, ebx
        call    pl_entry_types
        mov     r13d, eax
        test    eax, eax
        jnz     2f
        call    pl_types_draw
        mov     r13d, eax
2:      mov     edi, ebx
        mov     esi, r13d
        call    pl_entry_install
        mov     edi, [rip + pl_spawn_cur]
        test    r14d, KEEP_SPAWN
        jnz     3f
        mov     edi, [rip + spawn_pin]
        test    edi, edi
        jns     3f
        call    pl_spawn_pick
        mov     edi, eax
3:      call    pl_spawn
        call    choose_palette
        call    now
        vsubsd  xmm0, xmm0, [rsp]
        vmulsd  xmm0, xmm0, [rip + D_1E3]
        vmovsd  [rsp + 8], xmm0
        call    clock_now
        vmovsd  [rsp + 16], xmm0
        vaddsd  xmm0, xmm0, [rip + opt_interval]
        vmovsd  [rip + deadline], xmm0
        vmovsd  xmm0, [rsp + 16]
        vaddsd  xmm0, xmm0, [rip + opt_mutate]
        vmovsd  [rip + mut_deadline], xmm0
        inc     dword ptr [rip + switches]
        cmp     dword ptr [rip + opt_log], 0
        je      9f
        mov     eax, [rip + pl + PL_ROWS]
        push    rax
        mov     eax, [rip + pl + PL_COLS]
        push    rax
        call    palette_name
        push    rax
        call    spawn_name
        push    rax
        mov     edi, ebx
        call    pl_entry_name
        mov     rcx, rax
        mov     rsi, r12
        mov     edx, ebx
        lea     r8, [rip + s_curated]
        lea     rax, [rip + s_generated]
        cmp     ebx, NCURATED
        cmovae  r8, rax
        mov     r9d, [rip + pl + PL_K]
        lea     rdi, [rip + s_switch]
        vmovsd  xmm0, [rsp + 32 + 16]
        vmovsd  xmm1, [rsp + 32 + 8]
        vcvtss2sd xmm2, xmm2, [rip + pl + PL_MAXR]
        vcvtss2sd xmm3, xmm3, [rip + pl + PL_FSCALE]
        vcvtss2sd xmm4, xmm4, [rip + pl + PL_FRIC]
        vcvtss2sd xmm5, xmm5, [rip + pl + PL_CORE]
        mov     eax, 6
        call    printf@PLT
        add     rsp, 32
9:      add     rsp, 48
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

# palette for the scene just installed (r14d = switch_to flags)
choose_palette:
        push    rbx                     # rsp aligned
        mov     edi, [rip + palette_pin]
        test    edi, edi
        jns     8f
        test    r14d, KEEP_PALETTE
        jz      1f
        mov     edi, [rip + pl_palette_cur]
        test    edi, edi
        js      1f
        mov     esi, [rip + pl + PL_K]
        call    pl_palette_ok
        test    eax, eax
        jz      1f
        mov     edi, [rip + pl_palette_cur]
        jmp     8f
1:      call    pl_palette_pick
        mov     edi, eax
8:      call    pl_palette_set
        pop     rbx
        ret

# log a scene event that is not a preset switch (rdi = reason)
log_event:
        push    rbx
        push    r12
        push    r13
        sub     rsp, 16                 # rsp aligned; [rsp] clock
        cmp     dword ptr [rip + opt_log], 0
        je      9f
        mov     rbx, rdi
        call    clock_now
        vmovsd  [rsp], xmm0
        call    spawn_name
        mov     r12, rax
        call    palette_name
        mov     rcx, rax
        mov     rdx, r12
        mov     rsi, rbx
        mov     r8d, [rip + pl + PL_K]
        lea     rdi, [rip + s_ev_log]
        vmovsd  xmm0, [rsp]
        mov     eax, 1
        call    printf@PLT
9:      add     rsp, 16
        pop     r13
        pop     r12
        pop     rbx
        ret

# auto-cycle: switch to a shuffle-bag pick once the clock passes the deadline
cycle_tick:
        push    rbx                     # rsp aligned
        cmp     dword ptr [rip + cycle_on], 0
        je      9f
        call    clock_now
        vucomisd xmm0, [rip + deadline]
        jb      9f
        call    pl_preset_pick
        mov     edi, eax
        lea     rsi, [rip + s_r_timer]
        xor     edx, edx
        xor     ecx, ecx
        call    switch_to
9:      pop     rbx
        ret

# every --mutate seconds re-draw 1 or 2 attraction values (random pair, uniform
# [-1,1)) and rebuild the tables; the scene, spawn and palette stay as they are
mutate_tick:
        push    rbx                     # rsp aligned
        push    r12
        push    r13
        cmp     dword ptr [rip + cycle_on], 0
        je      9f
        vxorpd  xmm0, xmm0, xmm0
        vucomisd xmm0, [rip + opt_mutate]
        jae     9f
        call    clock_now
        vucomisd xmm0, [rip + mut_deadline]
        jb      9f
        vaddsd  xmm0, xmm0, [rip + opt_mutate]
        vmovsd  [rip + mut_deadline], xmm0
        call    pl_rng_u64
        and     eax, 1
        lea     r13d, [rax + 1]         # 1 or 2 values
        mov     r12d, r13d
1:      call    pl_rng_u64
        shr     rax, 32
        xor     edx, edx
        div     dword ptr [rip + pl + PL_K]
        mov     ebx, edx                # i
        shl     ebx, 4
        call    pl_rng_u64
        shr     rax, 32
        xor     edx, edx
        div     dword ptr [rip + pl + PL_K]
        add     ebx, edx                # i*16 + j
        vmovss  xmm0, [rip + M_ONE]
        vmovss  xmm1, [rip + M_ONE + 4]
        call    pl_rng_range
        lea     rax, [rip + pl]
        vmovss  [rax + PL_ATTR + rbx*4], xmm0
        dec     r13d
        jnz     1b
        call    pl_update_tables
        cmp     dword ptr [rip + opt_log], 0
        je      9f
        call    clock_now
        lea     rdi, [rip + s_mut_log]
        mov     esi, r12d
        mov     eax, 1
        call    printf@PLT
9:      pop     r13
        pop     r12
        pop     rbx
        ret

# cbuf = "next in N s" or "auto-cycle off"
cycle_text:
        push    rbx                     # rsp aligned
        cmp     dword ptr [rip + cycle_on], 0
        je      1f
        call    clock_now
        vmovsd  xmm1, [rip + deadline]
        vsubsd  xmm0, xmm1, xmm0
        vmaxsd  xmm0, xmm0, [rip + D_ZERO]
        lea     rdi, [rip + cbuf]
        mov     esi, 48
        lea     rdx, [rip + s_next_in]
        mov     eax, 1
        call    snprintf@PLT
        jmp     9f
1:      lea     rdi, [rip + cbuf]
        lea     rsi, [rip + s_cycoff]
        call    strcpy@PLT
9:      pop     rbx
        ret

# rax = name of the active preset
preset_name:
        lea     rax, [rip + s_rules]
        mov     edi, [rip + pl_preset_cur]
        test    edi, edi
        js      1f
        push    rbx
        call    pl_entry_name
        pop     rbx
1:      ret

# rax = list name ("curated"/"generated"), ecx = 1-based index in that list,
# edx = list size, for the active preset
preset_list:
        mov     eax, [rip + pl_preset_cur]
        lea     ecx, [eax + 1]
        mov     edx, NCURATED
        cmp     eax, NCURATED
        jae     1f
        lea     rax, [rip + s_curated]
        ret
1:      sub     ecx, NCURATED
        mov     edx, NENTRIES - NCURATED
        lea     rax, [rip + s_generated]
        ret

spawn_name:
        mov     eax, [rip + pl_spawn_cur]
        lea     rcx, [rip + pl_spawn_names]
        mov     rax, [rcx + rax*8]
        ret

palette_name:
        lea     rax, [rip + s_builtin]
        movsxd  rcx, dword ptr [rip + pl_palette_cur]
        test    rcx, rcx
        js      1f
        lea     rax, [rip + pl_palette_names]
        mov     rax, [rax + rcx*8]
1:      ret

pool_name:
        mov     eax, [rip + pl_pool]
        lea     rcx, [rip + pl_pool_names]
        mov     rax, [rcx + rax*8]
        ret

# ------------------------------------------------------------------ overlay
# otext = the overlay lines for the current state (g_fps < 0: no fps)
.macro OAPPEND
        mov     ecx, [rip + otext_len]
        lea     rdi, [rip + otext]
        add     rdi, rcx
        mov     esi, OTEXT_SIZE
        sub     esi, ecx
.endm
.macro OADVANCE
        add     eax, [rip + otext_len]
        mov     ecx, OTEXT_SIZE - 1
        cmp     eax, ecx
        cmova   eax, ecx
        mov     [rip + otext_len], eax
.endm
overlay_text:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15                     # rsp aligned
        mov     dword ptr [rip + otext_len], 0
        vxorpd  xmm0, xmm0, xmm0
        vucomisd xmm0, [rip + g_fps]
        ja      1f
        OAPPEND
        lea     rdx, [rip + s_o1]
        mov     ecx, [rip + opt_spf]
        vmovsd  xmm0, [rip + g_fps]
        vmovsd  xmm1, [rip + g_ms]
        mov     eax, 2
        call    snprintf@PLT
        jmp     2f
1:      OAPPEND
        lea     rdx, [rip + s_o1d]
        mov     ecx, [rip + opt_spf]
        vmovsd  xmm0, [rip + g_ms]
        mov     eax, 1
        call    snprintf@PLT
2:      OADVANCE
        call    simd_name
        mov     r9, rax
        OAPPEND
        lea     rdx, [rip + s_o2]
        mov     ecx, [rip + pl + PL_N]
        mov     r8d, [rip + pl + PL_K]
        push    r9
        push    r9
        mov     r9d, [rip + pl + PL_NTHREADS]
        xor     eax, eax
        call    snprintf@PLT                    # arg 7 (simd name) on the stack
        add     rsp, 16
        OADVANCE
        call    preset_name
        mov     r12, rax
        call    preset_list
        mov     r13, rax
        mov     r14d, ecx
        mov     r15d, edx
        mov     eax, [rip + pl_preset_cur]
        test    eax, eax
        jns     3f
        lea     r13, [rip + s_empty]
        xor     r14d, r14d
        xor     r15d, r15d
3:      call    pool_name
        push    rax
        push    rax
        OAPPEND
        lea     rdx, [rip + s_o3]
        mov     rcx, r12
        mov     r8, r13
        mov     r9d, r14d
        mov     [rsp], r15
        xor     eax, eax
        call    snprintf@PLT                    # preset, list, i, n, pool
        add     rsp, 16
        OADVANCE
        call    spawn_name
        mov     r12, rax
        call    palette_name
        mov     r13, rax
        lea     r14, [rip + s_empty]
        lea     rax, [rip + s_paused2]
        cmp     dword ptr [rip + paused], 0
        cmovne  r14, rax
        push    r14
        push    r14
        OAPPEND
        lea     rdx, [rip + s_o4]
        mov     rcx, r12
        mov     r8, r13
        lea     r9, [rip + cbuf]
        xor     eax, eax
        call    snprintf@PLT
        add     rsp, 16
        OADVANCE
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

# draw otext onto buffer rdi (opt_w x opt_h); scale max(1, h / 450)
draw_overlay:
        push    rbx                     # rsp aligned
        mov     rbx, rdi
        mov     eax, [rip + opt_h]
        xor     edx, edx
        mov     ecx, 450
        div     ecx
        mov     ecx, 1
        cmp     eax, ecx
        cmovb   eax, ecx
        mov     r10d, eax               # scale
        mov     rdi, rbx
        mov     esi, [rip + opt_w]
        mov     edx, [rip + opt_h]
        lea     ecx, [r10d*8]           # x = y = 8 scale
        mov     r8d, ecx
        lea     r9, [rip + otext]
        push    r10
        mov     eax, TEXT_ARGB
        push    rax
        call    pl_draw_text
        add     rsp, 16
        pop     rbx
        ret

# ------------------------------------------------------------------ headless
# the window's frame loop without SDL: opt_spf steps, then the auto-cycle
# check, opt_headless times; with --fake-clock the clock advances a fixed
# amount per frame
headless:
        push    rbx
        push    r12
        sub     rsp, 8                  # rsp aligned
        mov     ebx, [rip + opt_headless]
1:      test    ebx, ebx
        jz      3f
        mov     r12d, [rip + opt_spf]
2:      test    r12d, r12d
        jz      21f
        call    pl_step
        dec     r12d
        jmp     2b
21:     vmovsd  xmm0, [rip + fake_now]
        vaddsd  xmm0, xmm0, [rip + opt_fake]
        vmovsd  [rip + fake_now], xmm0
        call    cycle_tick
        call    mutate_tick
        dec     ebx
        jmp     1b
3:      call    clock_now
        lea     rdi, [rip + s_headdone]
        mov     esi, [rip + opt_headless]
        mov     edx, [rip + opt_spf]
        mov     ecx, [rip + switches]
        dec     ecx                     # not counting the start
        mov     eax, 1
        call    printf@PLT
        xor     eax, eax
        add     rsp, 8
        pop     r12
        pop     rbx
        ret

# change particle count to edi (clamped) and respawn in the current layout
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
1:      mov     edi, [rip + pl_spawn_cur]
        call    pl_spawn
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

# --bench-render N: N frames of pl_render alone, N frames of pl_render plus
# the overlay (text built and drawn every frame, as in the window), and N
# times the overlay alone
bench_render:
        push    rbx
        push    r12
        sub     rsp, 40                 # rsp aligned; [rsp] t, [rsp+8] plain, [rsp+16] overlay
        mov     edi, [rip + opt_w]
        imul    edi, [rip + opt_h]
        shl     rdi, 2
        call    malloc@PLT
        mov     r12, rax
        vmovsd  xmm0, [rip + D_M1]
        vmovsd  [rip + g_fps], xmm0
        call    cycle_text
        call    now
        vmovsd  [rsp], xmm0
        mov     ebx, [rip + opt_benchr]
1:      test    ebx, ebx
        jz      2f
        mov     rdi, r12
        mov     esi, [rip + opt_w]
        mov     edx, [rip + opt_h]
        call    pl_render
        dec     ebx
        jmp     1b
2:      call    now
        vsubsd  xmm1, xmm0, [rsp]
        vmovsd  [rsp + 8], xmm1
        vmovsd  [rsp], xmm0
        mov     ebx, [rip + opt_benchr]
3:      test    ebx, ebx
        jz      4f
        mov     rdi, r12
        mov     esi, [rip + opt_w]
        mov     edx, [rip + opt_h]
        call    pl_render
        call    cycle_text
        call    overlay_text
        mov     rdi, r12
        call    draw_overlay
        dec     ebx
        jmp     3b
4:      call    now
        vsubsd  xmm1, xmm0, [rsp]
        vmovsd  [rsp + 16], xmm1
        vmovsd  [rsp], xmm0
        mov     ebx, [rip + opt_benchr]  # the overlay alone: text + drawing
5:      test    ebx, ebx
        jz      6f
        call    cycle_text
        call    overlay_text
        mov     rdi, r12
        call    draw_overlay
        dec     ebx
        jmp     5b
6:      call    now
        vsubsd  xmm2, xmm0, [rsp]
        vcvtsi2sd xmm3, xmm3, dword ptr [rip + opt_benchr]
        vmovsd  xmm0, [rsp + 8]
        vdivsd  xmm0, xmm0, xmm3
        vmulsd  xmm0, xmm0, [rip + D_1E3]
        vmovsd  xmm1, [rsp + 16]
        vdivsd  xmm1, xmm1, xmm3
        vmulsd  xmm1, xmm1, [rip + D_1E3]
        vdivsd  xmm2, xmm2, xmm3
        vmulsd  xmm2, xmm2, [rip + D_1E3]
        lea     rdi, [rip + s_benchr_res]
        mov     esi, [rip + opt_w]
        mov     edx, [rip + opt_h]
        mov     ecx, [rip + pl + PL_N]
        mov     r8d, [rip + opt_benchr]
        mov     eax, 3
        call    printf@PLT
        mov     rdi, r12
        call    free@PLT
        xor     eax, eax
        add     rsp, 40
        pop     r12
        pop     rbx
        ret

# ------------------------------------------------------------------ dump
dump_frame:
        push    rbx
        push    r12
        sub     rsp, 24                 # rsp aligned; [rsp] t0
        call    now
        vmovsd  [rsp], xmm0
        mov     ebx, [rip + opt_steps]
1:      test    ebx, ebx
        jz      2f
        call    pl_step
        dec     ebx
        jmp     1b
2:      call    now                     # ms per step for the overlay
        vsubsd  xmm0, xmm0, [rsp]
        vmulsd  xmm0, xmm0, [rip + D_1E3]
        mov     eax, [rip + opt_steps]
        test    eax, eax
        jz      21f
        vcvtsi2sd xmm1, xmm1, eax
        vdivsd  xmm0, xmm0, xmm1
21:     vmovsd  [rip + g_ms], xmm0
        vmovsd  xmm0, [rip + D_M1]
        vmovsd  [rip + g_fps], xmm0
        mov     edi, [rip + opt_w]
        imul    edi, [rip + opt_h]
        shl     rdi, 2
        call    malloc@PLT
        mov     r12, rax
        mov     rdi, rax
        mov     esi, [rip + opt_w]
        mov     edx, [rip + opt_h]
        call    pl_render
        cmp     dword ptr [rip + opt_overlay], 0
        je      22f
        call    cycle_text
        call    overlay_text
        mov     rdi, r12
        call    draw_overlay
22:     mov     rdi, [rip + opt_dump]
        mov     rsi, r12
        mov     edx, [rip + opt_w]
        mov     ecx, [rip + opt_h]
        call    pl_write_ppm
        test    eax, eax
        jnz     3f
        call    palette_name
        push    rax
        call    spawn_name
        push    rax
        call    preset_name
        push    rax
        mov     eax, [rip + pl + PL_K]
        push    rax
        lea     rdi, [rip + s_dumped]
        mov     rsi, [rip + opt_dump]
        mov     edx, [rip + opt_w]
        mov     ecx, [rip + opt_h]
        mov     r8d, [rip + opt_steps]
        mov     r9d, [rip + pl + PL_N]
        xor     eax, eax
        call    printf@PLT
        add     rsp, 32
        xor     eax, eax
        jmp     4f
3:      lea     rdi, [rip + s_dumpfail]
        mov     rsi, [rip + opt_dump]
        xor     eax, eax
        call    printf@PLT
        mov     eax, 1
4:      add     rsp, 24
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

# eax = the entry after (edi = 1) or before (edi = -1) the current one in
# the pool, wrapping
pool_step:
        mov     ecx, [rip + pl_preset_cur]
        mov     rdx, [rip + pl_pool_mask]
        mov     r8d, NENTRIES
1:      add     ecx, edi
        jns     2f
        mov     ecx, NENTRIES - 1
2:      cmp     ecx, NENTRIES
        jb      3f
        xor     ecx, ecx
3:      bt      rdx, rcx
        jc      4f
        dec     r8d
        jnz     1b
4:      mov     eax, ecx
        ret

# re-apply the current preset with K = edi (clamped to 1..16), keeping the
# spawn layout and, if it still qualifies, the palette
retype:
        push    rbx                     # rsp aligned
        mov     eax, 1
        cmp     edi, eax
        cmovl   edi, eax
        mov     eax, MAXK
        cmp     edi, eax
        cmovg   edi, eax
        mov     edx, edi
        mov     edi, [rip + pl_preset_cur]
        test    edi, edi
        js      1f
        lea     rsi, [rip + s_r_types]
        mov     ecx, KEEP_PALETTE | KEEP_SPAWN
        call    switch_to
        pop     rbx
        ret
1:      mov     [rip + pl + PL_K], edx  # plain random rules
        call    pl_random_rules
        mov     edi, [rip + pl_spawn_cur]
        call    pl_spawn
        call    pl_palette_refresh
        pop     rbx
        ret

# handle one key, edi = SDL keycode (or a --keys character: '>' / '<' for
# Right / Left, 'S' for Shift+S, other capitals as lower case); returns
# eax = 1 to quit
on_key:
        push    rbx                     # rsp aligned
        mov     ebx, edi
        cmp     ebx, 'S'
        je      0f
        lea     eax, [ebx - 'A']
        cmp     eax, 25
        ja      0f
        add     ebx, 32                 # to lower case
0:      xor     eax, eax
        cmp     ebx, 27                 # Esc
        jne     1f
        mov     eax, 1
        jmp     99f
1:      cmp     ebx, ' '                # next scene: same pick as the timer
        jne     12f
        call    pl_preset_pick
        mov     edi, eax
        lea     rsi, [rip + s_r_space]
        xor     edx, edx
        xor     ecx, ecx
        call    switch_to
        jmp     98f
12:     cmp     ebx, 'z'                # pause (Z or Return)
        je      13f
        cmp     ebx, 13
        jne     2f
13:     xor     dword ptr [rip + paused], 1
        jmp     98f
2:      cmp     ebx, 'r'                # re-roll: same preset and K, new draws
        jne     3f
        mov     edi, [rip + pl_preset_cur]
        test    edi, edi
        js      21f
        lea     rsi, [rip + s_r_reroll]
        mov     edx, [rip + pl + PL_K]
        xor     ecx, ecx
        call    switch_to
        jmp     98f
21:     call    pl_random_rules
        jmp     98f
3:      cmp     ebx, 'n'                # respawn, same layout
        jne     31f
        mov     edi, [rip + pl_spawn_cur]
        call    pl_spawn
        lea     rdi, [rip + s_r_respawn]
        call    log_event
        jmp     98f
31:     cmp     ebx, 's'                # next spawn layout
        jne     32f
        mov     edi, [rip + pl_spawn_cur]
        inc     edi
        cmp     edi, NSPAWNS
        jb      311f
        xor     edi, edi
311:    call    pl_spawn
        lea     rdi, [rip + s_r_spawn]
        call    log_event
        jmp     98f
32:     cmp     ebx, 'S'                # previous spawn layout
        jne     33f
        mov     edi, [rip + pl_spawn_cur]
        dec     edi
        jns     311b
        mov     edi, NSPAWNS - 1
        jmp     311b
33:     cmp     ebx, 'k'                # next palette (qualifying for K)
        jne     34f
        mov     edi, 1
        call    pl_palette_next
        mov     edi, eax
        call    pl_palette_set
        lea     rdi, [rip + s_r_palette]
        call    log_event
        jmp     98f
34:     cmp     ebx, 'p'                # next pool, and a preset from it
        jne     35f
        mov     edi, [rip + pl_pool]
        inc     edi
        cmp     edi, 3
        jb      341f
        xor     edi, edi
341:    call    pl_pool_set
        call    pl_preset_pick
        mov     edi, eax
        lea     rsi, [rip + s_r_pool]
        xor     edx, edx
        xor     ecx, ecx
        call    switch_to
        jmp     98f
35:     cmp     ebx, 'f'                # overlay on/off
        jne     36f
        xor     dword ptr [rip + overlay_on], 1
        cmp     dword ptr [rip + opt_log], 0
        je      98f
        call    clock_now
        lea     rdi, [rip + s_ovl_log]
        lea     rsi, [rip + s_off]
        lea     rax, [rip + s_on]
        cmp     dword ptr [rip + overlay_on], 0
        cmovne  rsi, rax
        mov     eax, 1
        call    printf@PLT
        jmp     98f
36:     cmp     ebx, '['
        jne     37f
        mov     edi, [rip + pl + PL_K]
        dec     edi
        call    retype
        jmp     98f
37:     cmp     ebx, ']'
        jne     4f
        mov     edi, [rip + pl + PL_K]
        inc     edi
        call    retype
        jmp     98f
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
        jmp     98f
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
        jmp     98f
6:      cmp     ebx, SDLK_RIGHT
        je      61f
        cmp     ebx, '>'
        jne     7f
61:     mov     edi, 1
        call    pool_step
        mov     edi, eax
        lea     rsi, [rip + s_r_next]
        xor     edx, edx
        xor     ecx, ecx
        call    switch_to
        jmp     98f
7:      cmp     ebx, SDLK_LEFT
        je      71f
        cmp     ebx, '<'
        jne     72f
71:     mov     edi, -1
        call    pool_step
        mov     edi, eax
        lea     rsi, [rip + s_r_prev]
        xor     edx, edx
        xor     ecx, ecx
        call    switch_to
        jmp     98f
72:     cmp     ebx, 'c'                # auto-cycle on/off (needs an interval > 0)
        jne     73f
        vxorpd  xmm0, xmm0, xmm0
        vucomisd xmm0, [rip + opt_interval]
        jae     98f
        xor     dword ptr [rip + cycle_on], 1
        call    clock_now
        vmovsd  [rip + cbuf], xmm0      # scratch
        vaddsd  xmm0, xmm0, [rip + opt_interval]
        vmovsd  [rip + deadline], xmm0
        cmp     dword ptr [rip + opt_log], 0
        je      98f
        lea     rdi, [rip + s_cycle_log]
        vmovsd  xmm0, [rip + cbuf]
        lea     rsi, [rip + s_off]
        lea     rax, [rip + s_on]
        cmp     dword ptr [rip + cycle_on], 0
        cmovne  rsi, rax
        mov     eax, 1
        call    printf@PLT
        jmp     98f
73:     lea     eax, [ebx - '1']        # 1-9: type count
        cmp     eax, 8
        ja      98f
        lea     edi, [eax + 1]
        call    retype
98:     xor     eax, eax
99:     pop     rbx
        ret

# feed one SDL_TouchFingerEvent (rdi) to the gesture recogniser; when the
# last finger lifts, classify the gesture, log it and run its key through
# on_key. Returns eax = 1 to quit.
on_touch:
        push    rbx
        push    r12
        push    r13                     # rsp aligned
        mov     rbx, rdi
        xor     r13d, r13d
        cmp     qword ptr [rbx + 8], -1 # SDL_TOUCH_MOUSEID: touch made up from the mouse
        je      9f
        mov     rax, [rbx + 16]         # fingerId
        lea     r8, [rip + t_ids]
        mov     edx, [rip + t_count]
        xor     r12d, r12d
1:      cmp     r12d, edx
        jae     2f
        cmp     rax, [r8 + r12*8]
        je      3f
        inc     r12d
        jmp     1b
2:      mov     r12d, -1                # r12d = its slot, -1 = not down
3:      mov     ecx, [rbx]
        cmp     ecx, SDL_FINGERDOWN
        je      20f
        cmp     ecx, SDL_FINGERMOTION
        je      30f
        cmp     ecx, SDL_FINGERUP
        jne     9f
        test    r12d, r12d              # up
        jns     4f
        mov     r12d, G_STRAY           # up without down
        jmp     80f
4:      call    t_track
        mov     edx, [rip + t_count]
        dec     edx
        mov     [rip + t_count], edx
        mov     rax, [r8 + rdx*8]       # last slot into the freed one
        mov     [r8 + r12*8], rax
        test    edx, edx
        jnz     9f
        # the gesture is over
        vmovss  xmm0, [rip + t_lx]
        vsubss  xmm0, xmm0, [rip + t_sx]        # dx
        vmovss  xmm1, [rip + t_ly]
        vsubss  xmm1, xmm1, [rip + t_sy]        # dy
        vpcmpeqd xmm5, xmm5, xmm5
        vpsrld  xmm5, xmm5, 1
        vandps  xmm2, xmm0, xmm5                # |dx|
        vandps  xmm3, xmm1, xmm5                # |dy|
        vmaxss  xmm4, xmm2, xmm3                # travel
        mov     eax, [rbx + 4]
        sub     eax, [rip + t_t0]               # held, ms
        mov     r12d, G_NONE
        cmp     dword ptr [rip + t_max], 1
        je      5f
        vucomiss xmm4, [rip + T_TAP_MOVE]       # two or more fingers
        jae     80f
        cmp     eax, [rip + T_LONG_MS]
        jae     80f
        mov     r12d, G_TWO
        jmp     80f
5:      vucomiss xmm4, [rip + T_TAP_MOVE]
        jae     6f
        mov     r12d, G_LONG
        cmp     eax, [rip + T_LONG_MS]
        jae     80f
        mov     r12d, G_TAP
        vmovss  xmm5, [rip + t_sx]
        vucomiss xmm5, [rip + T_EXIT_X]
        jae     80f
        vmovss  xmm5, [rip + t_sy]
        vucomiss xmm5, [rip + T_EXIT_Y]
        jae     80f
        mov     r12d, G_EXIT
        jmp     80f
6:      vxorps  xmm5, xmm5, xmm5
        vucomiss xmm2, xmm3
        jbe     7f
        vucomiss xmm2, [rip + T_SWIPE]          # horizontal
        jb      80f
        mov     r12d, G_SWL
        vucomiss xmm0, xmm5
        jb      80f
        mov     r12d, G_SWR
        jmp     80f
7:      vucomiss xmm3, xmm2
        jbe     80f
        vucomiss xmm3, [rip + T_SWIPE]          # vertical (y grows downwards)
        jb      80f
        mov     r12d, G_SWU
        vucomiss xmm1, xmm5
        jb      80f
        mov     r12d, G_SWD
        jmp     80f

20:     test    r12d, r12d              # down
        jns     9f                      # already down
        mov     edx, [rip + t_count]
        cmp     edx, TMAX_FINGERS
        jae     9f
        mov     [r8 + rdx*8], rax
        inc     edx
        mov     [rip + t_count], edx
        cmp     edx, 1
        jne     21f
        mov     [rip + t_first], rax    # first finger: a new gesture
        mov     [rip + t_max], edx
        mov     ecx, [rbx + 4]
        mov     [rip + t_t0], ecx
        mov     ecx, [rbx + 24]
        mov     [rip + t_sx], ecx
        mov     [rip + t_lx], ecx
        mov     ecx, [rbx + 28]
        mov     [rip + t_sy], ecx
        mov     [rip + t_ly], ecx
        jmp     9f
21:     cmp     edx, [rip + t_max]
        jbe     9f
        mov     [rip + t_max], edx
        jmp     9f

30:     test    r12d, r12d              # motion
        js      9f
        call    t_track
        jmp     9f

80:     cmp     dword ptr [rip + opt_log], 0
        je      81f
        call    clock_now
        lea     rdi, [rip + s_touch_log]
        lea     rax, [rip + g_names]
        mov     rsi, [rax + r12*8]
        lea     rax, [rip + g_actions]
        mov     rdx, [rax + r12*8]
        mov     eax, 1
        call    printf@PLT
81:     lea     rax, [rip + g_keys]
        movzx   edi, byte ptr [rax + r12]
        test    edi, edi
        jz      9f
        call    on_key
        mov     r13d, eax
9:      mov     eax, r13d
        pop     r13
        pop     r12
        pop     rbx
        ret

# --log-events, once the window is up: line-buffer stdout (it is often a
# file), log recognised gestures too, and print the video driver and the
# touch devices SDL knows
log_video:
        push    rbx
        push    r12
        sub     rsp, 8
        mov     dword ptr [rip + opt_log], 1
        xor     edi, edi
        call    fflush@PLT
        mov     rdi, [rip + stdout]
        xor     esi, esi
        mov     edx, 1                  # _IOLBF
        xor     ecx, ecx
        call    setvbuf@PLT
        call    SDL_GetCurrentVideoDriver@PLT
        mov     rbx, rax
        call    SDL_GetNumTouchDevices@PLT
        lea     rdi, [rip + s_ev_video]
        mov     rsi, rbx
        mov     edx, eax
        xor     eax, eax
        call    printf@PLT
        xor     ebx, ebx
1:      call    SDL_GetNumTouchDevices@PLT
        cmp     ebx, eax
        jge     9f
        mov     edi, ebx
        call    SDL_GetTouchDevice@PLT
        mov     r12, rax
        mov     rdi, rax
        call    SDL_GetTouchDeviceType@PLT
        mov     [rsp], eax
        mov     edi, ebx
        call    SDL_GetTouchName@PLT
        lea     rdi, [rip + s_ev_dev]
        mov     esi, ebx
        mov     rdx, r12
        mov     ecx, [rsp]
        mov     r8, rax
        xor     eax, eax
        call    printf@PLT
        inc     ebx
        jmp     1b
9:      add     rsp, 8
        pop     r12
        pop     rbx
        ret

# --log-events: print one SDL event (rdi): finger events with the touch
# device, finger and position; mouse events with the device ('which', -1 =
# made up from touch) and the pixel position, motion only with a button
# held; anything else just its type
log_sdl_event:
        push    rbx
        mov     rbx, rdi
        call    clock_now
        mov     esi, [rbx]
        lea     eax, [esi - SDL_FINGERDOWN]
        cmp     eax, SDL_FINGERMOTION - SDL_FINGERDOWN
        ja      1f
        mov     rdx, [rbx + 8]          # touchId
        mov     rcx, [rbx + 16]         # fingerId
        vcvtss2sd xmm1, xmm1, [rbx + 24]
        vcvtss2sd xmm2, xmm2, [rbx + 28]
        vcvtss2sd xmm3, xmm3, [rbx + 40]
        lea     rdi, [rip + s_ev_finger]
        mov     eax, 4
        jmp     8f
1:      lea     eax, [esi - SDL_MOUSEMOTION]
        cmp     eax, SDL_MOUSEWHEEL - SDL_MOUSEMOTION
        ja      2f
        mov     ecx, [rbx + 16]         # motion: button state
        test    eax, eax
        jnz     11f
        test    ecx, ecx
        jz      9f
        jmp     12f
11:     movzx   ecx, byte ptr [rbx + 16] # button / wheel x
12:     mov     edx, [rbx + 12]         # which
        mov     r8d, [rbx + 20]
        mov     r9d, [rbx + 24]
        lea     rdi, [rip + s_ev_mouse]
        mov     eax, 1
        jmp     8f
2:      lea     rdi, [rip + s_ev_other]
        mov     eax, 1
8:      call    printf@PLT
9:      pop     rbx
        ret

# on_touch helper: the first finger's position is the gesture's last one
t_track:
        mov     rax, [rbx + 16]
        cmp     rax, [rip + t_first]
        jne     1f
        mov     eax, [rbx + 24]
        mov     [rip + t_lx], eax
        mov     eax, [rbx + 28]
        mov     [rip + t_ly], eax
1:      ret

# --touches: parse rdi = "d0.5,0.5@0 m0.3,0.5@50#1 u..." into SDL finger
# events and feed each to on_touch; eax = 1 if a gesture quit
run_touches:
        push    rbx
        push    r12
        push    r13
        sub     rsp, 16                 # rsp aligned; [rsp] strto* end
        mov     rbx, rdi
1:      movzx   eax, byte ptr [rbx]
        cmp     eax, ' '
        jne     2f
        inc     rbx
        jmp     1b
2:      xor     r13d, r13d
        test    eax, eax
        jz      9f
        mov     ecx, SDL_FINGERDOWN
        cmp     eax, 'd'
        je      3f
        mov     ecx, SDL_FINGERMOTION
        cmp     eax, 'm'
        je      3f
        mov     ecx, SDL_FINGERUP
        cmp     eax, 'u'
        jne     8f
3:      lea     r12, [rip + tev]
        mov     [r12], ecx
        mov     qword ptr [r12 + 8], 0  # touchId
        mov     qword ptr [r12 + 16], 0 # fingerId
        inc     rbx
        mov     rdi, rbx                # x
        mov     rsi, rsp
        call    strtod@PLT
        cmp     [rsp], rbx
        je      8f
        vcvtsd2ss xmm0, xmm0, xmm0
        vmovss  [r12 + 24], xmm0
        mov     rbx, [rsp]
        cmp     byte ptr [rbx], ','
        jne     8f
        inc     rbx
        mov     rdi, rbx                # y
        mov     rsi, rsp
        call    strtod@PLT
        cmp     [rsp], rbx
        je      8f
        vcvtsd2ss xmm0, xmm0, xmm0
        vmovss  [r12 + 28], xmm0
        mov     rbx, [rsp]
        cmp     byte ptr [rbx], '@'
        jne     8f
        inc     rbx
        mov     rdi, rbx                # timestamp, ms
        mov     rsi, rsp
        mov     edx, 10
        call    strtoull@PLT
        cmp     [rsp], rbx
        je      8f
        mov     [r12 + 4], eax
        mov     rbx, [rsp]
        cmp     byte ptr [rbx], '#'
        jne     4f
        inc     rbx
        mov     rdi, rbx                # fingerId
        mov     rsi, rsp
        mov     edx, 10
        call    strtoull@PLT
        cmp     [rsp], rbx
        je      8f
        mov     [r12 + 16], rax
        mov     rbx, [rsp]
4:      movzx   eax, byte ptr [rbx]
        test    eax, eax
        jz      5f
        cmp     eax, ' '
        jne     8f
5:      mov     rdi, r12
        call    on_touch
        mov     r13d, eax
        test    eax, eax
        jz      1b
9:      mov     eax, r13d
        add     rsp, 16
        pop     r13
        pop     r12
        pop     rbx
        ret
8:      lea     rdi, [rip + s_badtouch]
        mov     rsi, rbx
        call    die_arg

window:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 64                 # rsp aligned; [rsp] t_title, [rsp+8] step_time, [rsp+16] frames, [rsp+24] steps
                                        # [rsp+32] t_step, [rsp+40] last clock
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
        cmp     dword ptr [rip + opt_evlog], 0
        je      0f
        call    log_video
0:      mov     rdi, [rip + win]
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
        vmovsd  [rip + g_fps], xmm0
        vmovsd  [rip + g_ms], xmm0
        mov     qword ptr [rsp + 16], 0
        mov     qword ptr [rsp + 24], 0
        call    clock_now
        vmovsd  [rsp + 40], xmm0
        vaddsd  xmm0, xmm0, [rip + opt_interval]
        vmovsd  [rip + deadline], xmm0  # the first preset gets a full interval

.Lframe:
        # events
.Lpoll:
        lea     rdi, [rip + event]
        call    SDL_PollEvent@PLT
        test    eax, eax
        jz      .Lsim
        cmp     dword ptr [rip + opt_evlog], 0
        je      0f
        lea     rdi, [rip + event]
        call    log_sdl_event
0:      mov     eax, [rip + event]
        cmp     eax, SDL_QUIT
        je      .Lquit
        lea     ecx, [eax - SDL_FINGERDOWN]
        cmp     ecx, SDL_FINGERMOTION - SDL_FINGERDOWN
        ja      1f
        lea     rdi, [rip + event]          # finger down / motion / up
        call    on_touch
        test    eax, eax
        jnz     .Lquit
        jmp     .Lpoll
1:      cmp     eax, SDL_KEYDOWN
        jne     .Lpoll
        mov     edi, [rip + event + 20]     # keysym.sym
        test    word ptr [rip + event + 24], KMOD_SHIFT
        jz      0f
        lea     eax, [edi - 'a']            # Shift+letter -> capital
        cmp     eax, 25
        ja      0f
        sub     edi, 32
0:      call    on_key
        test    eax, eax
        jnz     .Lquit
        jmp     .Lpoll

.Lsim:
        # auto-cycle; a pause holds the countdown
        call    clock_now
        vsubsd  xmm1, xmm0, [rsp + 40]
        vmovsd  [rsp + 40], xmm0
        cmp     dword ptr [rip + paused], 0
        je      0f
        vmovsd  xmm2, [rip + mut_deadline]
        vaddsd  xmm2, xmm2, xmm1
        vmovsd  [rip + mut_deadline], xmm2
        vaddsd  xmm1, xmm1, [rip + deadline]
        vmovsd  [rip + deadline], xmm1
        jmp     .Ldraw
0:      call    cycle_tick
        call    mutate_tick
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
        cmp     dword ptr [rip + overlay_on], 0
        je      3f
        call    cycle_text
        call    overlay_text
        mov     rdi, [rip + pixels]
        call    draw_overlay
3:      mov     rdi, [rip + tex]
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

        # every 0.5 s: fps over the frames presented since, ms per step
        call    now
        vsubsd  xmm1, xmm0, [rsp]
        vucomisd xmm1, [rip + D_HALF]
        jb      .Lframe
        vmovsd  [rsp], xmm0
        vcvtsi2sd xmm2, xmm2, qword ptr [rsp + 16]
        vdivsd  xmm0, xmm2, xmm1            # fps
        vmovsd  [rip + g_fps], xmm0
        mov     rax, [rsp + 24]
        test    rax, rax
        jz      4f                          # paused: keep the last ms/step
        vcvtsi2sd xmm2, xmm2, rax
        vmovsd  xmm1, [rsp + 8]
        vdivsd  xmm1, xmm1, xmm2
        vmulsd  xmm1, xmm1, [rip + D_1E3]   # ms/step
        vmovsd  [rip + g_ms], xmm1
4:      mov     qword ptr [rsp + 16], 0
        mov     qword ptr [rsp + 24], 0
        mov     qword ptr [rsp + 8], 0
        call    cycle_text
        call    spawn_name
        mov     r12, rax
        lea     rax, [rip + s_empty]
        lea     r13, [rip + s_paused]
        cmp     dword ptr [rip + paused], 0
        cmove   r13, rax
        call    preset_list
        mov     r14, rax
        mov     r15d, ecx
        mov     ebx, edx
        push    r13                     # pad
        push    r13                     # paused
        call    palette_name
        push    rax
        push    r12                     # spawn
        mov     eax, [rip + pl + PL_K]
        push    rax
        mov     eax, [rip + pl + PL_N]
        push    rax
        lea     rax, [rip + cbuf]
        push    rax
        push    rbx                     # list size
        call    preset_name
        mov     rcx, rax
        lea     rdi, [rip + title]
        mov     esi, 512
        lea     rdx, [rip + s_title]
        mov     r8, r14
        mov     r9d, r15d
        vmovsd  xmm0, [rip + g_fps]
        vmovsd  xmm1, [rip + g_ms]
        mov     eax, 2
        call    snprintf@PLT
        add     rsp, 64
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
        add     rsp, 64
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

# ------------------------------------------------------------------ lists
list_presets:
        push    rbx
        push    r12
        push    r13                     # rsp aligned
        xor     ebx, ebx
1:      mov     edi, ebx
        call    pl_entry_types
        test    eax, eax
        jz      2f
        lea     rdi, [rip + kbuf]
        lea     rsi, [rip + s_kfmt]
        mov     edx, eax
        xor     eax, eax
        call    sprintf@PLT
        lea     r13, [rip + kbuf]
        jmp     3f
2:      lea     r13, [rip + s_kdraw]
3:      mov     edi, ebx
        call    pl_entry_rule
        shl     eax, 5
        lea     r12, [rip + pl_preset_phys]
        add     r12, rax
        mov     edi, ebx
        call    pl_entry_name
        mov     rdx, rax
        lea     rcx, [rip + s_curated]
        lea     rax, [rip + s_generated]
        cmp     ebx, NCURATED
        cmovae  rcx, rax
        mov     r8, r13
        lea     rdi, [rip + s_listfmt]
        mov     esi, ebx
        vcvtss2sd xmm0, xmm0, [r12]
        vcvtss2sd xmm1, xmm1, [r12 + 4]
        vcvtss2sd xmm2, xmm2, [r12 + 8]
        vcvtss2sd xmm3, xmm3, [r12 + 12]
        vcvtss2sd xmm4, xmm4, [r12 + 16]
        vcvtss2sd xmm5, xmm5, [r12 + 20]
        vcvtss2sd xmm6, xmm6, [r12 + 24]
        mov     eax, 7
        call    printf@PLT
        inc     ebx
        cmp     ebx, NENTRIES
        jb      1b
        pop     r13
        pop     r12
        pop     rbx
        ret

list_spawns:
        push    rbx
        push    r12
        push    r13                     # rsp aligned
        xor     ebx, ebx
1:      lea     rcx, [rip + s_notpat]
        lea     rax, [rip + s_inpat]
        cmp     ebx, 2                  # ring
        je      2f
        cmp     ebx, 7                  # spiral
        je      2f
        cmp     ebx, 11                 # line_mixed
        je      2f
        cmp     ebx, 16                 # random
        je      2f
        lea     rax, [rip + s_starpat]
        cmp     ebx, 15                 # star: replaced by star_fixed
        je      21f
        lea     rax, [rip + s_fixpat]
        cmp     ebx, 17
        je      21f
        lea     rax, [rip + s_inpat]
21:     mov     rcx, rax
2:      lea     rax, [rip + pl_spawn_names]
        mov     rdx, [rax + rbx*8]
        lea     rdi, [rip + s_lspfmt]
        mov     esi, ebx
        xor     eax, eax
        call    printf@PLT
        inc     ebx
        cmp     ebx, NSPAWNS
        jb      1b
        pop     r13
        pop     r12
        pop     rbx
        ret

# each palette with the type counts it qualifies for, e.g. "2-9" or "2-16"
list_palettes:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15                     # rsp aligned
        xor     ebx, ebx
1:      cmp     ebx, [rip + pl_npalettes]
        jae     9f
        mov     r12d, 1                 # largest K such that 2..K all qualify
2:      lea     esi, [r12d + 1]
        cmp     esi, MAXK
        ja      3f
        mov     edi, ebx
        call    pl_palette_ok
        test    eax, eax
        jz      3f
        inc     r12d
        jmp     2b
3:      lea     rdi, [rip + kbuf]
        mov     esi, 64
        lea     rdx, [rip + s_krange]
        mov     ecx, r12d
        lea     rax, [rip + s_knone]
        cmp     r12d, 1
        jne     31f
        mov     rdx, rax
31:     xor     eax, eax
        call    snprintf@PLT
        lea     rax, [rip + pl_palette_cols]
        mov     rax, [rax + rbx*8]
        mov     ecx, [rax]
        lea     rax, [rip + pl_palette_names]
        mov     rdx, [rax + rbx*8]
        lea     rdi, [rip + s_lpalfmt]
        mov     esi, ebx
        lea     r8, [rip + kbuf]
        xor     eax, eax
        call    printf@PLT
        inc     ebx
        jmp     1b
9:      pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

        .section .rodata
s_krange:    .asciz "2..%u"
s_knone:     .asciz "none (only 1)"
        .text

# ------------------------------------------------------------------ main
        .globl main
main:
        push    rbx                     # rsp aligned
        call    parse_args

        cmp     dword ptr [rip + opt_list], 0
        je      11f
        call    list_presets
        jmp     19f
11:     cmp     dword ptr [rip + opt_lspawns], 0
        je      12f
        call    list_spawns
        jmp     19f
12:     cmp     dword ptr [rip + opt_lpal], 0
        je      13f
        lea     rax, [rip + pl]                 # qualification needs pl.K only
        mov     dword ptr [rax + PL_K], 2
        call    list_palettes
19:     xor     edi, edi
        call    exit@PLT

        # --pool, --preset, --spawn, --palette
13:     mov     rbx, [rip + opt_pool]
        test    rbx, rbx
        jz      132f
        xor     ecx, ecx
131:    lea     rax, [rip + pl_pool_names]
        mov     rsi, [rax + rcx*8]
        mov     rdi, rbx
        push    rcx
        push    rcx
        call    strcasecmp@PLT
        pop     rcx
        pop     rcx
        test    eax, eax
        jz      133f
        inc     ecx
        cmp     ecx, 3
        jb      131b
        lea     rdi, [rip + s_badpool]
        mov     rsi, rbx
        call    die_arg
133:    mov     edi, ecx
        call    pl_pool_set
132:    mov     rdi, [rip + opt_preset]
        test    rdi, rdi
        jz      14f
        call    pl_entry_find
        mov     [rip + start_preset], eax
        test    eax, eax
        jns     14f
        lea     rdi, [rip + s_badpreset]
        mov     rsi, [rip + opt_preset]
        call    die_arg
14:     mov     rdi, [rip + opt_spawn]
        test    rdi, rdi
        jz      141f
        call    pl_spawn_find
        mov     [rip + spawn_pin], eax
        test    eax, eax
        jns     141f
        lea     rdi, [rip + s_badspawn]
        mov     rsi, [rip + opt_spawn]
        call    die_arg
141:    mov     rdi, [rip + opt_palette]
        test    rdi, rdi
        jz      142f
        call    pl_palette_find
        mov     [rip + palette_pin], eax
        test    eax, eax
        jns     142f
        lea     rdi, [rip + s_badpal]
        mov     rsi, [rip + opt_palette]
        call    die_arg

        # auto-cycle unless --no-cycle or --interval 0; headless logs switches
142:    vxorpd  xmm0, xmm0, xmm0
        vucomisd xmm0, [rip + opt_interval]
        jae     15f
        cmp     dword ptr [rip + opt_nocycle], 0
        jne     15f
        mov     dword ptr [rip + cycle_on], 1
15:     cmp     dword ptr [rip + opt_headless], 0
        je      16f
        mov     dword ptr [rip + opt_log], 1
16:

        # validate
        mov     eax, [rip + opt_n]
        test    eax, eax
        jz      usage
        cmp     eax, MAX_PARTICLES
        ja      usage
        cmp     dword ptr [rip + opt_k], MAXK
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

        # threads: default 1 for bench/dump, half the logical CPUs for the window
4:      mov     edi, [rip + opt_threads]
        test    edi, edi
        jnz     5f
        mov     edi, 1
        mov     eax, [rip + opt_bench]
        or      eax, [rip + opt_headless]
        or      eax, [rip + opt_benchr]
        or      rax, [rip + opt_dump]
        jnz     5f
        mov     edi, SC_NPROCESSORS_ONLN
        call    sysconf@PLT
        mov     edi, eax
        shr     edi, 1                  # one per physical core on SMT machines
        mov     eax, 1
        cmp     edi, eax
        cmovb   edi, eax
5:      call    pl_threads_start

        call    setup_sim

        # --keys: run the window's key handler on each character
        mov     rbx, [rip + opt_keys]
        test    rbx, rbx
        jz      51f
50:     movzx   edi, byte ptr [rbx]
        test    edi, edi
        jz      51f
        call    on_key
        inc     rbx
        jmp     50b
        # --touches: the same for finger events through the gesture recogniser;
        # a gesture that quits (the exit-corner tap) ends the program here
51:     mov     rdi, [rip + opt_touches]
        test    rdi, rdi
        jz      53f
        call    run_touches
        test    eax, eax
        jz      53f
        xor     eax, eax
        jmp     9f

53:     cmp     dword ptr [rip + opt_bench], 0
        je      52f
        call    bench
        xor     eax, eax
        jmp     9f
52:     cmp     dword ptr [rip + opt_benchr], 0
        je      6f
        call    bench_render
        jmp     9f
6:      cmp     qword ptr [rip + opt_dump], 0
        je      7f
        call    dump_frame
        jmp     9f
7:      cmp     dword ptr [rip + opt_headless], 0
        je      8f
        call    headless
        jmp     9f
8:      call    window
9:      mov     edi, eax
        call    exit@PLT
