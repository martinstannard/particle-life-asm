// Program entry, AArch64 port of src/main.S: argument parsing, headless
// benchmark, frame dump and the SDL2 window loop. Everything here calls
// libc / SDL2 through the C ABI (AAPCS64: variadic arguments go in
// registers like fixed ones, the ninth integer argument and later on the
// stack in 8-byte slots).
//
// Additions for the Raspberry Pi and its portrait panel:
//   --rotate 0|90|180|270  rotate the picture on the GPU at present time
//                          (SDL_RenderCopyEx), the world keeps --width x
//                          --height; the window is --height x --width for
//                          90 and 270
//   --fullscreen           SDL_WINDOW_FULLSCREEN_DESKTOP, cursor hidden
//   --present texture|surface
//                          texture (default): streaming ARGB8888 texture,
//                          SDL_UpdateTexture + RenderCopy(Ex) + Present;
//                          surface: the window surface, rendered into
//                          directly when its format and size allow, else
//                          blitted (no rotation)
//   --bench-present FRAMES open the window, draw FRAMES frames without
//                          stepping and print the upload / present cost
// The window reports upload and present times in the overlay, and prints
// the averages on exit.

        .include "layout.inc"
        .include "macros.inc"

.set SDL_INIT_VIDEO,        0x20
.set SDL_WINDOWPOS_CENTERED,0x2FFF0000
.set SDL_WINDOW_FULLSCREEN_DESKTOP, 0x1001
.set SDL_RENDERER_ACCEL,    2
.set SDL_RENDERER_VSYNC,    4
.set SDL_PIXELFORMAT_ARGB8888, 0x16362004
.set SDL_PIXELFORMAT_RGB888,   0x16161804
.set SDL_TEXTUREACCESS_STREAMING, 1
.set SDL_QUIT,              0x100
.set SDL_KEYDOWN,           0x300
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

// switch_to flags
.set KEEP_PALETTE,          1
.set KEEP_SPAWN,            2

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
s_keys:      .asciz "--keys"
s_preset:    .asciz "--preset"
s_interval:  .asciz "--interval"
s_nocycle:   .asciz "--no-cycle"
s_list:      .asciz "--list-presets"
s_headless:  .asciz "--headless"
s_fake:      .asciz "--fake-clock"
s_log:       .asciz "--log-switches"
s_pool:      .asciz "--pool"
s_spawn:     .asciz "--spawn"
s_lspawns:   .asciz "--list-spawns"
s_palette:   .asciz "--palette"
s_lpal:      .asciz "--list-palettes"
s_overlay:   .asciz "--overlay"
s_benchr:    .asciz "--bench-render"
s_rotate:    .asciz "--rotate"
s_fullscr:   .asciz "--fullscreen"
s_present:   .asciz "--present"
s_benchp:    .asciz "--bench-present"
s_r_start:   .asciz "start"
s_r_timer:   .asciz "timer"
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
s_cycle_log: .asciz "%9.3f s  auto-cycle %s\n"
s_ovl_log:   .asciz "%9.3f s  overlay %s\n"
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
s_neon:      .asciz "neon"
s_texture:   .asciz "texture"
s_surface:   .asciz "surface"
s_title0:    .asciz "Particle Life (asm)"
s_title:     .asciz "Particle Life (asm) | %s (%s %u/%u) | %s | %u particles, %u types | %.0f fps | step %.2f ms | upload %.2f ms | spawn %s | palette %s%s"
s_paused:    .asciz " | PAUSED"
s_paused2:   .asciz "   PAUSED"
s_empty:     .asciz ""
// overlay lines
s_o1:        .asciz "FPS %.1f   step %.2f ms x%u\n"
s_o1d:       .asciz "FPS -   step %.2f ms x%u\n"
s_o2:        .asciz "%u particles   %u types   %u threads %s\n"
s_o3:        .asciz "preset %s (%s %u/%u)   pool %s\n"
s_o4:        .asciz "spawn %s\npalette %s\n%s%s"
s_o5:        .asciz "\n%s: upload %.2f ms  present %.2f ms\n"
s_usage:     .ascii "usage: particle_life [--particles N] [--types K(1-16), pins the type count]\n"
             .ascii "         [--seed S] [--width W] [--height H] (>= 256)\n"
             .ascii "         [--threads T] [--simd neon] [--cell-div 1|2]\n"
             .ascii "         [--steps-per-frame S] [--no-vsync]\n"
             .ascii "         [--rotate 0|90|180|270] [--fullscreen] [--present texture|surface]\n"
             .ascii "         [--bench STEPS [--warmup STEPS]]   headless benchmark\n"
             .ascii "         [--bench-render FRAMES]  time the renderer with and without overlay\n"
             .ascii "         [--bench-present FRAMES] window: time texture upload and present\n"
             .ascii "         [--dump-frame out.ppm [--steps STEPS] [--overlay]] headless, one frame\n"
             .ascii "         [--pool curated|generated|all (default curated)]\n"
             .ascii "         [--preset NAME (c:NAME / g:NAME for curated / generated)]\n"
             .ascii "         [--spawn NAME (pins the layout)] [--palette NAME (pins it)]\n"
             .ascii "         [--interval SECONDS (default 120, 0 = off)] [--no-cycle]\n"
             .ascii "         [--list-presets] [--list-spawns] [--list-palettes]\n"
             .ascii "         [--headless FRAMES [--fake-clock SECONDS_PER_FRAME]] no window, runs the\n"
             .ascii "                       frame loop (steps, auto-cycle) and logs switches\n"
             .ascii "         [--log-switches]\n"
             .ascii "         [--keys STR]  feed key presses (e.g. \"r9+\") to the key handler first;\n"
             .ascii "                       '>' '<' = Right Left, 'S' = Shift+S\n"
             .ascii "keys: Space pause, Right/Left next/previous preset, P pool, C auto-cycle,\n"
             .ascii "      R re-roll, S/Shift+S next/previous spawn, N respawn, K palette,\n"
             .ascii "      [ ] fewer/more types, 1-9 types, +/- particles, F overlay, Esc quit\n"
             .byte 0
s_noneon:    .asciz "error: this program needs Advanced SIMD (NEON)\n"
s_badrot:    .asciz "error: --rotate takes 0, 90, 180 or 270; rotation needs --present texture\n"
s_nomem:     .asciz "error: out of memory\n"
s_sdlerr:    .asciz "SDL error: %s\n"
s_bench_hdr: .asciz "asm   simd=%s threads=%u particles=%u types=%u world=%ux%u cell-div=%u steps=%u (after %u warmup)\n"
s_bench_res: .asciz "      %.1f steps/s  %.3f ms/step  %.2f ns/particle-step\n"
s_benchr_res:.asciz "render %ux%u, %u particles, %u frames: %.3f ms/frame without overlay, %.3f ms/frame with overlay; overlay alone (text + drawing) %.4f ms/frame\n"
s_pres_res:  .asciz "present %s %ux%u rotate %u%s: %u frames, render %.3f ms + upload %.3f ms + present %.3f ms per frame (present includes the vsync wait unless --no-vsync)\n"
s_fs:        .asciz " fullscreen"
s_dumped:    .asciz "wrote %s (%ux%u, after %u steps, %u particles, %u types, %s, spawn %s, palette %s)\n"
s_dumpfail:  .asciz "error: could not write %s\n"
s_krange:    .asciz "2..%u"
s_knone:     .asciz "none (only 1)"
        .balign 8
D_1E9:       .double 1.0e-9
D_1E3:       .double 1000.0
D_1E9I:      .double 1.0e9
D_HALF:      .double 0.5
F_DT:        .float 0.016666668
F_FRIC:      .float 0.4
F_FSCALE:    .float 0.3
F_CORE:      .float 0.6

// option table: {name, dest, kind} kind 0 = u32, 1 = u64, 2 = string, 3 = flag,
// 4 = double
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
        .quad s_keys,      opt_keys,    2
        .quad s_preset,    opt_preset,  2
        .quad s_interval,  opt_interval, 4
        .quad s_nocycle,   opt_nocycle, 3
        .quad s_list,      opt_list,    3
        .quad s_headless,  opt_headless, 0
        .quad s_fake,      opt_fake,    4
        .quad s_log,       opt_log,     3
        .quad s_pool,      opt_pool,    2
        .quad s_spawn,     opt_spawn,   2
        .quad s_lspawns,   opt_lspawns, 3
        .quad s_palette,   opt_palette, 2
        .quad s_lpal,      opt_lpal,    3
        .quad s_overlay,   opt_overlay, 3
        .quad s_benchr,    opt_benchr,  0
        .quad s_rotate,    opt_rotate,  0
        .quad s_fullscr,   opt_fullscr, 3
        .quad s_present,   opt_present, 2
        .quad s_benchp,    opt_benchp,  0
        .quad 0

        .data
        .balign 8
opt_seed:    .quad -1                // -1 = not given: 1, or the clock for the window
opt_simd:    .quad 0
opt_dump:    .quad 0
opt_keys:    .quad 0
opt_preset:  .quad 0
opt_pool:    .quad 0
opt_spawn:   .quad 0
opt_palette: .quad 0
opt_present: .quad 0
opt_interval: .double 120.0
opt_fake:    .double 0.0
opt_n:       .long 20000
opt_k:       .long 0                 // 0 = not pinned
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
opt_lspawns: .long 0
opt_lpal:    .long 0
opt_overlay: .long 0
opt_benchr:  .long 0
opt_rotate:  .long 0
opt_fullscr: .long 0
opt_benchp:  .long 0
start_preset: .long -1
spawn_pin:   .long -1
palette_pin: .long -1
overlay_on:  .long 1
use_surface: .long 0

        .bss
        .balign 64
event:       .skip 64
title:       .skip 512
otext:       .skip OTEXT_SIZE
win:         .skip 8
ren:         .skip 8
tex:         .skip 8
pixels:      .skip 8
srcsurf:     .skip 8
paused:      .skip 4
cycle_on:    .skip 4
switches:    .skip 4
otext_len:   .skip 4
dstrect:     .skip 16               // SDL_Rect for the rotated copy
outw:        .skip 4
outh:        .skip 4
        .balign 8
deadline:    .skip 8                // clock time of the next automatic switch
fake_now:    .skip 8
g_fps:       .skip 8                // last measured fps (-1 = none: dump)
g_ms:        .skip 8                // last measured ms per step
g_up:        .skip 8                // last measured upload ms per frame (-1 = none)
g_pr:        .skip 8                // last measured present ms per frame
angle:       .skip 8                // rotation in degrees (double)
cbuf:        .skip 48
kbuf:        .skip 64

        .text

// a 32-bit option / global into wd (clobbers x16)
.macro LDW wd, sym
        LDRS    \wd, \sym, x16
.endm
// store wd into a 32-bit global (clobbers x16)
.macro STW wd, sym
        adrp    x16, \sym
        str     \wd, [x16, :lo12:\sym]
.endm

// double now(void): CLOCK_MONOTONIC seconds
now:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        mov     w0, #CLOCK_MONOTONIC
        add     x1, sp, #16
        bl      clock_gettime
        ldp     x9, x10, [sp, #16]
        scvtf   d0, x9
        scvtf   d1, x10
        LDRS    d2, D_1E9, x9
        fmadd   d0, d1, d2, d0
        ldp     x29, x30, [sp], #32
        ret

usage:  // noreturn
        ADR_L   x0, s_usage
        LDR_GOT x1, stderr
        bl      fputs
        mov     w0, #2
        bl      exit

die:    // x0 = message, noreturn
        LDR_GOT x1, stderr
        bl      fputs
        mov     w0, #1
        bl      exit

// noreturn: fprintf(stderr, x0 = format, x1 = argument); exit 2
die_arg:
        mov     x2, x1
        mov     x1, x0
        LDR_GOT x0, stderr
        bl      fprintf
        mov     w0, #2
        bl      exit

// parse argv; w0 = argc, x1 = argv
parse_args:
        ENTER
        mov     w19, w0
        mov     x20, x1
        mov     w21, #1
1:      cmp     w21, w19
        b.hs    9f
        ADR_L   x22, opts
2:      ldr     x1, [x22]
        cbz     x1, usage                       // unknown option
        ldr     x0, [x20, x21, lsl #3]
        bl      strcmp
        cbz     w0, 3f
        add     x22, x22, #24
        b       2b
3:      ldr     x23, [x22, #8]                  // dest
        ldr     x24, [x22, #16]                 // kind
        cmp     w24, #3
        b.ne    4f
        mov     w9, #1
        str     w9, [x23]
        add     w21, w21, #1
        b       1b
4:      add     w21, w21, #1
        cmp     w21, w19
        b.hs    usage                           // missing value
        ldr     x0, [x20, x21, lsl #3]
        cmp     w24, #2
        b.ne    41f
        str     x0, [x23]
        add     w21, w21, #1
        b       1b
41:     cmp     w24, #4
        b.ne    5f
        mov     x1, #0
        bl      strtod
        str     d0, [x23]
        add     w21, w21, #1
        b       1b
5:      mov     x1, #0
        mov     w2, #10
        bl      strtoull
        cmp     w24, #1
        b.eq    6f
        str     w0, [x23]
        add     w21, w21, #1
        b       1b
6:      str     x0, [x23]
        add     w21, w21, #1
        b       1b
9:      LEAVE

// set the simulation parameters from the options and initialise
setup_sim:
        ENTER2
        ADR_L   x19, pl
        LDW     w9, opt_k
        cbnz    w9, 0f
        mov     w9, #6                          // until a preset sets its own
0:      str     w9, [x19, #PL_K]
        LDW     w9, opt_w
        scvtf   s0, w9
        str     s0, [x19, #PL_W]
        LDW     w9, opt_h
        scvtf   s0, w9
        str     s0, [x19, #PL_H]
        LDW     w9, F_DT
        str     w9, [x19, #PL_DT]
        LDW     w9, F_FRIC
        str     w9, [x19, #PL_FRIC]
        LDW     w9, F_FSCALE
        str     w9, [x19, #PL_FSCALE]
        LDW     w9, F_CORE
        str     w9, [x19, #PL_CORE]
        LDRS    x0, opt_seed, x16
        cmn     x0, #1
        b.ne    1f
        mov     x0, #1                          // bench, dump, headless: reproducible
        LDW     w9, opt_bench
        cbnz    w9, 1f
        LDRS    x9, opt_dump, x16
        cbnz    x9, 1f
        LDW     w9, opt_headless
        cbnz    w9, 1f
        LDW     w9, opt_benchr
        cbnz    w9, 1f
        bl      now                             // window: a different start each run
        LDRS    d1, D_1E9I, x9
        fmul    d0, d0, d1
        fcvtzs  x0, d0
1:      str     x0, [x19, #PL_RNG]
        LDW     w9, opt_cdiv
        str     w9, [x19, #PL_CDIV]
        LDW     w0, opt_n
        bl      pl_alloc
        cbz     w0, 2f
        ADR_L   x0, s_nomem
        bl      die
        // bench, and dump without --preset: plain random rules with uniform
        // particles, or --spawn's layout; all other modes start on a preset
2:      LDW     w0, start_preset
        tbz     w0, #31, 3f
        LDW     w9, opt_bench
        cbnz    w9, 4f
        LDRS    x9, opt_dump, x16
        cbnz    x9, 4f
        bl      pl_preset_pick
3:      ADR_L   x1, s_r_start
        mov     w2, #0
        mov     w3, #0
        bl      switch_to
        LEAVE2
4:      bl      pl_random_rules
        LDW     w0, palette_pin
        tbnz    w0, #31, 41f
        bl      pl_palette_set
41:     LDW     w0, spawn_pin
        tbnz    w0, #31, 42f
        bl      pl_spawn
        LEAVE2
42:     bl      pl_random_particles
        LEAVE2

// double clock_now(void): the clock that drives auto-cycling: CLOCK_MONOTONIC,
// or the fake clock of --headless --fake-clock
clock_now:
        LDRS    d1, opt_fake, x9
        fcmp    d1, #0.0
        b.gt    1f
        b       now
1:      LDRS    d0, fake_now, x9
        ret

// switch_to(u32 e, const char *reason, u32 k, u32 flags): install a scene:
// preset e with k types (k = 0: --types if given, else the preset's own
// count, else a draw 2..16), every derived table and the grid, then a spawn
// layout (KEEP_SPAWN: the current one; else --spawn's, else pl-box's
// weighted pick) and a palette (--palette's; KEEP_PALETTE: the current one
// when it still qualifies for K; otherwise a new pick). Restarts the switch
// timer and logs.
switch_to:
        ENTER   32                              // [sp] t0, [sp+8] ms, [sp+16] clock
        mov     w19, w0
        mov     x20, x1
        mov     w21, w2
        mov     w22, w3
        bl      now
        str     d0, [sp]
        cbnz    w21, 2f
        LDW     w21, opt_k
        cbnz    w21, 2f
        mov     w0, w19
        bl      pl_entry_types
        mov     w21, w0
        cbnz    w0, 2f
        bl      pl_types_draw
        mov     w21, w0
2:      mov     w0, w19
        mov     w1, w21
        bl      pl_entry_install
        LDW     w0, pl_spawn_cur
        tbnz    w22, #1, 3f                     // KEEP_SPAWN
        LDW     w0, spawn_pin
        tbz     w0, #31, 3f
        bl      pl_spawn_pick
3:      bl      pl_spawn
        mov     w0, w22
        bl      choose_palette
        bl      now
        ldr     d1, [sp]
        fsub    d0, d0, d1
        LDRS    d1, D_1E3, x9
        fmul    d0, d0, d1
        str     d0, [sp, #8]
        bl      clock_now
        str     d0, [sp, #16]
        LDRS    d1, opt_interval, x9
        fadd    d0, d0, d1
        ADR_L   x9, deadline
        str     d0, [x9]
        LDW     w9, switches
        add     w9, w9, #1
        STW     w9, switches
        LDW     w9, opt_log
        cbz     w9, 9f
        bl      palette_name
        mov     x23, x0
        bl      spawn_name
        mov     x24, x0
        mov     w0, w19
        bl      pl_entry_name
        mov     x3, x0
        ldr     d0, [sp, #16]
        ldr     d1, [sp, #8]
        ADR_L   x9, pl
        ldr     s2, [x9, #PL_MAXR]
        fcvt    d2, s2
        ldr     s3, [x9, #PL_FSCALE]
        fcvt    d3, s3
        ldr     s4, [x9, #PL_FRIC]
        fcvt    d4, s4
        ldr     s5, [x9, #PL_CORE]
        fcvt    d5, s5
        ldr     w5, [x9, #PL_K]
        ldr     w10, [x9, #PL_COLS]
        ldr     w11, [x9, #PL_ROWS]
        sub     sp, sp, #16
        stp     x10, x11, [sp]                  // grid cols x rows (9th, 10th)
        ADR_L   x0, s_switch
        mov     x1, x20
        mov     w2, w19
        ADR_L   x4, s_curated
        ADR_L   x9, s_generated
        cmp     w19, #NCURATED
        csel    x4, x9, x4, hs
        mov     x6, x24
        mov     x7, x23
        bl      printf
        add     sp, sp, #16
9:      LEAVE   32

// palette for the scene just installed (w0 = switch_to flags)
choose_palette:
        ENTER2
        mov     w19, w0
        LDW     w0, palette_pin
        tbz     w0, #31, 8f
        tbz     w19, #0, 1f                     // KEEP_PALETTE
        LDW     w0, pl_palette_cur
        tbnz    w0, #31, 1f
        ADR_L   x9, pl
        ldr     w1, [x9, #PL_K]
        bl      pl_palette_ok
        cbz     w0, 1f
        LDW     w0, pl_palette_cur
        b       8f
1:      bl      pl_palette_pick
8:      bl      pl_palette_set
        LEAVE2

// log a scene event that is not a preset switch (x0 = reason)
log_event:
        ENTER4
        LDW     w9, opt_log
        cbz     w9, 9f
        mov     x19, x0
        bl      clock_now
        fmov    x21, d0
        bl      spawn_name
        mov     x20, x0
        bl      palette_name
        mov     x3, x0
        mov     x2, x20
        mov     x1, x19
        ADR_L   x9, pl
        ldr     w4, [x9, #PL_K]
        ADR_L   x0, s_ev_log
        fmov    d0, x21
        bl      printf
9:      LEAVE4

// auto-cycle: switch to a shuffle-bag pick once the clock passes the deadline
cycle_tick:
        ENTER2
        LDW     w9, cycle_on
        cbz     w9, 9f
        bl      clock_now
        LDRS    d1, deadline, x9
        fcmp    d0, d1
        b.lt    9f
        bl      pl_preset_pick
        ADR_L   x1, s_r_timer
        mov     w2, #0
        mov     w3, #0
        bl      switch_to
9:      LEAVE2

// cbuf = "next in N s" or "auto-cycle off"
cycle_text:
        ENTER2
        LDW     w9, cycle_on
        cbz     w9, 1f
        bl      clock_now
        LDRS    d1, deadline, x9
        fsub    d0, d1, d0
        movi    d1, #0
        fmax    d0, d0, d1
        ADR_L   x0, cbuf
        mov     x1, #48
        ADR_L   x2, s_next_in
        bl      snprintf
        LEAVE2
1:      ADR_L   x0, cbuf
        ADR_L   x1, s_cycoff
        bl      strcpy
        LEAVE2

// x0 = name of the active preset
preset_name:
        LDW     w0, pl_preset_cur
        tbnz    w0, #31, 1f
        b       pl_entry_name
1:      ADR_L   x0, s_rules
        ret

// x0 = list name ("curated"/"generated"), w1 = 1-based index in that list,
// w2 = list size, for the active preset
preset_list:
        LDW     w9, pl_preset_cur
        add     w1, w9, #1
        mov     w2, #NCURATED
        cmp     w9, #NCURATED
        b.hs    1f
        ADR_L   x0, s_curated
        ret
1:      sub     w1, w1, #NCURATED
        mov     w2, #NENTRIES - NCURATED
        ADR_L   x0, s_generated
        ret

spawn_name:
        LDW     w9, pl_spawn_cur
        ADR_L   x10, pl_spawn_names
        ldr     x0, [x10, x9, lsl #3]
        ret

palette_name:
        LDW     w9, pl_palette_cur
        ADR_L   x0, s_builtin
        tbnz    w9, #31, 1f
        ADR_L   x10, pl_palette_names
        ldr     x0, [x10, x9, lsl #3]
1:      ret

pool_name:
        LDW     w9, pl_pool
        ADR_L   x10, pl_pool_names
        ldr     x0, [x10, x9, lsl #3]
        ret

simd_name:      // x0 = name of the active kernel family
        ADR_L   x0, s_neon
        ret

present_name:   // x0 = "texture" or "surface"
        LDW     w9, use_surface
        ADR_L   x0, s_texture
        cbz     w9, 1f
        ADR_L   x0, s_surface
1:      ret

// ------------------------------------------------------------------ overlay
// otext = the overlay lines for the current state (g_fps < 0: no fps;
// g_up < 0: no present times)
.macro OAPPEND
        LDW     w9, otext_len
        ADR_L   x0, otext
        add     x0, x0, x9
        mov     w1, #OTEXT_SIZE
        sub     w1, w1, w9
.endm
.macro OADVANCE
        LDW     w9, otext_len
        add     w0, w0, w9
        mov     w9, #OTEXT_SIZE - 1
        cmp     w0, w9
        csel    w0, w9, w0, hi
        STW     w0, otext_len
.endm
overlay_text:
        ENTER
        STW     wzr, otext_len
        LDRS    d0, g_fps, x9
        fcmp    d0, #0.0
        b.lt    1f
        OAPPEND
        ADR_L   x2, s_o1
        LDW     w3, opt_spf
        LDRS    d0, g_fps, x9
        LDRS    d1, g_ms, x9
        bl      snprintf
        b       2f
1:      OAPPEND
        ADR_L   x2, s_o1d
        LDW     w3, opt_spf
        LDRS    d0, g_ms, x9
        bl      snprintf
2:      OADVANCE
        OAPPEND
        ADR_L   x2, s_o2
        ADR_L   x9, pl
        ldr     w3, [x9, #PL_N]
        ldr     w4, [x9, #PL_K]
        ldr     w5, [x9, #PL_NTHREADS]
        ADR_L   x6, s_neon
        bl      snprintf
        OADVANCE
        bl      preset_name
        mov     x19, x0
        bl      preset_list
        mov     x20, x0
        mov     w21, w1
        mov     w22, w2
        LDW     w9, pl_preset_cur
        tbz     w9, #31, 3f
        ADR_L   x20, s_empty
        mov     w21, #0
        mov     w22, #0
3:      bl      pool_name
        mov     x23, x0
        OAPPEND
        ADR_L   x2, s_o3
        mov     x3, x19
        mov     x4, x20
        mov     w5, w21
        mov     w6, w22
        mov     x7, x23
        bl      snprintf
        OADVANCE
        bl      spawn_name
        mov     x19, x0
        bl      palette_name
        mov     x20, x0
        LDW     w9, paused
        ADR_L   x21, s_empty
        ADR_L   x10, s_paused2
        cmp     w9, #0
        csel    x21, x10, x21, ne
        OAPPEND
        ADR_L   x2, s_o4
        mov     x3, x19
        mov     x4, x20
        ADR_L   x5, cbuf
        mov     x6, x21
        bl      snprintf
        OADVANCE
        LDRS    d0, g_up, x9
        fcmp    d0, #0.0
        b.lt    9f
        bl      present_name
        mov     x19, x0
        OAPPEND
        ADR_L   x2, s_o5
        mov     x3, x19
        LDRS    d0, g_up, x9
        LDRS    d1, g_pr, x9
        bl      snprintf
        OADVANCE
9:      LEAVE

// draw otext onto buffer x0 (opt_w x opt_h); scale max(1, h / 450)
draw_overlay:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        LDW     w2, opt_h
        mov     w9, #450
        udiv    w7, w2, w9
        cmp     w7, #1
        csinc   w7, w7, wzr, hs                 // scale
        LDW     w1, opt_w
        lsl     w3, w7, #3                      // x = y = 8 scale
        mov     w4, w3
        ADR_L   x5, otext
        MOV32   w6, TEXT_ARGB
        bl      pl_draw_text
        ldp     x29, x30, [sp], #16
        ret

// ------------------------------------------------------------------ headless
// the window's frame loop without SDL: opt_spf steps, then the auto-cycle
// check, opt_headless times; with --fake-clock the clock advances a fixed
// amount per frame
headless:
        ENTER2
        LDW     w19, opt_headless
1:      cbz     w19, 3f
        LDW     w20, opt_spf
2:      cbz     w20, 21f
        bl      pl_step
        sub     w20, w20, #1
        b       2b
21:     LDRS    d0, fake_now, x9
        LDRS    d1, opt_fake, x9
        fadd    d0, d0, d1
        ADR_L   x9, fake_now
        str     d0, [x9]
        bl      cycle_tick
        sub     w19, w19, #1
        b       1b
3:      bl      clock_now
        ADR_L   x0, s_headdone
        LDW     w1, opt_headless
        LDW     w2, opt_spf
        LDW     w3, switches
        sub     w3, w3, #1                      // not counting the start
        bl      printf
        mov     w0, #0
        LEAVE2

// change particle count to w0 (clamped) and respawn in the current layout
set_particles:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        mov     w9, #100
        cmp     w0, w9
        csel    w0, w9, w0, lo
        MOV32   w9, MAX_PARTICLES
        cmp     w0, w9
        csel    w0, w9, w0, hi
        STW     w0, opt_n
        bl      pl_alloc
        cbz     w0, 1f
        ADR_L   x0, s_nomem
        bl      die
1:      LDW     w0, pl_spawn_cur
        bl      pl_spawn
        ldp     x29, x30, [sp], #16
        ret

// ------------------------------------------------------------------ bench
bench:
        ENTER4
        LDW     w19, opt_warmup
1:      cbz     w19, 2f
        bl      pl_step
        sub     w19, w19, #1
        b       1b
2:      bl      now
        fmov    x21, d0
        LDW     w19, opt_bench
3:      cbz     w19, 4f
        bl      pl_step
        sub     w19, w19, #1
        b       3b
4:      bl      now
        fmov    d1, x21
        fsub    d0, d0, d1
        fmov    x21, d0                         // elapsed seconds

        sub     sp, sp, #16
        LDW     w9, opt_bench
        LDW     w10, opt_warmup
        stp     x9, x10, [sp]                   // steps, warmup (9th, 10th)
        ADR_L   x0, s_bench_hdr
        ADR_L   x1, s_neon
        ADR_L   x9, pl
        ldr     w2, [x9, #PL_NTHREADS]
        ldr     w3, [x9, #PL_N]
        ldr     w4, [x9, #PL_K]
        LDW     w5, opt_w
        LDW     w6, opt_h
        ldr     w7, [x9, #PL_CDIV]
        bl      printf
        add     sp, sp, #16
        // results: steps/s, ms/step, ns/particle-step
        LDW     w9, opt_bench
        scvtf   d3, w9
        fmov    d4, x21
        fdiv    d0, d3, d4                      // steps/s
        fdiv    d1, d4, d3                      // s/step
        LDRS    d5, D_1E3, x9
        fmul    d1, d1, d5                      // ms/step
        fdiv    d2, d4, d3
        LDRS    d5, D_1E9I, x9
        fmul    d2, d2, d5
        ADR_L   x9, pl
        ldr     w9, [x9, #PL_N]
        scvtf   d5, w9
        fdiv    d2, d2, d5                      // ns/particle-step
        ADR_L   x0, s_bench_res
        bl      printf
        LEAVE4

// --bench-render N: N frames of pl_render alone, N frames of pl_render plus
// the overlay (text built and drawn every frame, as in the window), and N
// times the overlay alone
bench_render:
        ENTER
        LDW     w9, opt_w
        LDW     w10, opt_h
        umull   x0, w9, w10
        lsl     x0, x0, #2
        bl      malloc
        mov     x20, x0
        fmov    d0, #-1.0
        ADR_L   x9, g_fps
        str     d0, [x9]
        ADR_L   x9, g_up
        str     d0, [x9]
        bl      cycle_text
        bl      now
        fmov    x21, d0
        LDW     w19, opt_benchr
1:      cbz     w19, 2f
        mov     x0, x20
        LDW     w1, opt_w
        LDW     w2, opt_h
        bl      pl_render
        sub     w19, w19, #1
        b       1b
2:      bl      now
        fmov    d1, x21
        fsub    d1, d0, d1
        fmov    x22, d1                         // plain
        fmov    x21, d0
        LDW     w19, opt_benchr
3:      cbz     w19, 4f
        mov     x0, x20
        LDW     w1, opt_w
        LDW     w2, opt_h
        bl      pl_render
        bl      cycle_text
        bl      overlay_text
        mov     x0, x20
        bl      draw_overlay
        sub     w19, w19, #1
        b       3b
4:      bl      now
        fmov    d1, x21
        fsub    d1, d0, d1
        fmov    x23, d1                         // with overlay
        fmov    x21, d0
        LDW     w19, opt_benchr                 // the overlay alone: text + drawing
5:      cbz     w19, 6f
        bl      cycle_text
        bl      overlay_text
        mov     x0, x20
        bl      draw_overlay
        sub     w19, w19, #1
        b       5b
6:      bl      now
        fmov    d1, x21
        fsub    d2, d0, d1
        LDW     w9, opt_benchr
        scvtf   d3, w9
        LDRS    d5, D_1E3, x9
        fmov    d0, x22
        fdiv    d0, d0, d3
        fmul    d0, d0, d5
        fmov    d1, x23
        fdiv    d1, d1, d3
        fmul    d1, d1, d5
        fdiv    d2, d2, d3
        fmul    d2, d2, d5
        ADR_L   x0, s_benchr_res
        LDW     w1, opt_w
        LDW     w2, opt_h
        ADR_L   x9, pl
        ldr     w3, [x9, #PL_N]
        LDW     w4, opt_benchr
        bl      printf
        mov     x0, x20
        bl      free
        mov     w0, #0
        LEAVE

// ------------------------------------------------------------------ dump
dump_frame:
        ENTER
        bl      now
        fmov    x21, d0
        LDW     w19, opt_steps
1:      cbz     w19, 2f
        bl      pl_step
        sub     w19, w19, #1
        b       1b
2:      bl      now                             // ms per step for the overlay
        fmov    d1, x21
        fsub    d0, d0, d1
        LDRS    d1, D_1E3, x9
        fmul    d0, d0, d1
        LDW     w9, opt_steps
        cbz     w9, 21f
        scvtf   d1, w9
        fdiv    d0, d0, d1
21:     ADR_L   x9, g_ms
        str     d0, [x9]
        fmov    d0, #-1.0
        ADR_L   x9, g_fps
        str     d0, [x9]
        ADR_L   x9, g_up
        str     d0, [x9]
        LDW     w9, opt_w
        LDW     w10, opt_h
        umull   x0, w9, w10
        lsl     x0, x0, #2
        bl      malloc
        mov     x20, x0
        LDW     w1, opt_w
        LDW     w2, opt_h
        bl      pl_render
        LDW     w9, opt_overlay
        cbz     w9, 22f
        bl      cycle_text
        bl      overlay_text
        mov     x0, x20
        bl      draw_overlay
22:     LDRS    x0, opt_dump, x9
        mov     x1, x20
        LDW     w2, opt_w
        LDW     w3, opt_h
        bl      pl_write_ppm
        cbnz    w0, 3f
        bl      palette_name
        mov     x22, x0
        bl      spawn_name
        mov     x23, x0
        bl      preset_name
        mov     x7, x0
        sub     sp, sp, #16
        stp     x23, x22, [sp]                  // spawn, palette (9th, 10th)
        ADR_L   x0, s_dumped
        LDRS    x1, opt_dump, x9
        LDW     w2, opt_w
        LDW     w3, opt_h
        LDW     w4, opt_steps
        ADR_L   x9, pl
        ldr     w5, [x9, #PL_N]
        ldr     w6, [x9, #PL_K]
        bl      printf
        add     sp, sp, #16
        mov     w0, #0
        LEAVE
3:      ADR_L   x0, s_dumpfail
        LDRS    x1, opt_dump, x9
        bl      printf
        mov     w0, #1
        LEAVE

// ------------------------------------------------------------------ window
sdl_fail:
        bl      SDL_GetError
        mov     x2, x0
        ADR_L   x1, s_sdlerr
        LDR_GOT x0, stderr
        bl      fprintf
        mov     w0, #1
        bl      exit

// w0 = the entry after (w0 = 1) or before (w0 = -1) the current one in
// the pool, wrapping
pool_step:
        LDW     w10, pl_preset_cur
        LDRS    x11, pl_pool_mask, x16
        mov     w12, #NENTRIES
1:      adds    w10, w10, w0
        b.pl    2f
        mov     w10, #NENTRIES - 1
2:      cmp     w10, #NENTRIES
        b.lo    3f
        mov     w10, #0
3:      lsr     x13, x11, x10
        tbnz    x13, #0, 4f
        subs    w12, w12, #1
        b.ne    1b
4:      mov     w0, w10
        ret

// re-apply the current preset with K = w0 (clamped to 1..16), keeping the
// spawn layout and, if it still qualifies, the palette
retype:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        mov     w9, #1
        cmp     w0, w9
        csel    w0, w9, w0, lt
        mov     w9, #MAXK
        cmp     w0, w9
        csel    w0, w9, w0, gt
        mov     w2, w0
        LDW     w0, pl_preset_cur
        tbnz    w0, #31, 1f
        ADR_L   x1, s_r_types
        mov     w3, #KEEP_PALETTE | KEEP_SPAWN
        bl      switch_to
        ldp     x29, x30, [sp], #16
        ret
1:      ADR_L   x9, pl                          // plain random rules
        str     w2, [x9, #PL_K]
        bl      pl_random_rules
        LDW     w0, pl_spawn_cur
        bl      pl_spawn
        bl      pl_palette_refresh
        ldp     x29, x30, [sp], #16
        ret

// handle one key, w0 = SDL keycode (or a --keys character: '>' / '<' for
// Right / Left, 'S' for Shift+S, other capitals as lower case); returns
// w0 = 1 to quit
on_key:
        ENTER2
        mov     w19, w0
        cmp     w19, #'S'
        b.eq    0f
        sub     w9, w19, #'A'
        cmp     w9, #25
        b.hi    0f
        add     w19, w19, #32                   // to lower case
0:      cmp     w19, #27                        // Esc
        b.ne    1f
        mov     w0, #1
        LEAVE2
1:      cmp     w19, #' '
        b.ne    2f
        LDW     w9, paused
        eor     w9, w9, #1
        STW     w9, paused
        b       98f
2:      cmp     w19, #'r'                       // re-roll: same preset and K, new draws
        b.ne    3f
        LDW     w0, pl_preset_cur
        tbnz    w0, #31, 21f
        ADR_L   x1, s_r_reroll
        ADR_L   x9, pl
        ldr     w2, [x9, #PL_K]
        mov     w3, #0
        bl      switch_to
        b       98f
21:     bl      pl_random_rules
        b       98f
3:      cmp     w19, #'n'                       // respawn, same layout
        b.ne    31f
        LDW     w0, pl_spawn_cur
        bl      pl_spawn
        ADR_L   x0, s_r_respawn
        bl      log_event
        b       98f
31:     cmp     w19, #'s'                       // next spawn layout
        b.ne    32f
        LDW     w0, pl_spawn_cur
        add     w0, w0, #1
        cmp     w0, #NSPAWNS
        csel    w0, wzr, w0, hs
311:    bl      pl_spawn
        ADR_L   x0, s_r_spawn
        bl      log_event
        b       98f
32:     cmp     w19, #'S'                       // previous spawn layout
        b.ne    33f
        LDW     w0, pl_spawn_cur
        subs    w0, w0, #1
        b.pl    311b
        mov     w0, #NSPAWNS - 1
        b       311b
33:     cmp     w19, #'k'                       // next palette (qualifying for K)
        b.ne    34f
        mov     w0, #1
        bl      pl_palette_next
        bl      pl_palette_set
        ADR_L   x0, s_r_palette
        bl      log_event
        b       98f
34:     cmp     w19, #'p'                       // next pool, and a preset from it
        b.ne    35f
        LDW     w0, pl_pool
        add     w0, w0, #1
        cmp     w0, #3
        csel    w0, wzr, w0, hs
        bl      pl_pool_set
        bl      pl_preset_pick
        ADR_L   x1, s_r_pool
        mov     w2, #0
        mov     w3, #0
        bl      switch_to
        b       98f
35:     cmp     w19, #'f'                       // overlay on/off
        b.ne    36f
        LDW     w9, overlay_on
        eor     w9, w9, #1
        STW     w9, overlay_on
        LDW     w9, opt_log
        cbz     w9, 98f
        bl      clock_now
        ADR_L   x0, s_ovl_log
        ADR_L   x1, s_off
        ADR_L   x9, s_on
        LDW     w10, overlay_on
        cmp     w10, #0
        csel    x1, x9, x1, ne
        bl      printf
        b       98f
36:     cmp     w19, #'['
        b.ne    37f
        ADR_L   x9, pl
        ldr     w0, [x9, #PL_K]
        sub     w0, w0, #1
        bl      retype
        b       98f
37:     cmp     w19, #']'
        b.ne    4f
        ADR_L   x9, pl
        ldr     w0, [x9, #PL_K]
        add     w0, w0, #1
        bl      retype
        b       98f
4:      cmp     w19, #'+'
        b.eq    41f
        cmp     w19, #'='
        b.eq    41f
        MOV32   w9, SDLK_KP_PLUS
        cmp     w19, w9
        b.ne    5f
41:     LDW     w0, opt_n
        add     w0, w0, w0, lsl #2
        lsr     w0, w0, #2                      // n * 5/4
        bl      set_particles
        b       98f
5:      cmp     w19, #'-'
        b.eq    51f
        MOV32   w9, SDLK_KP_MINUS
        cmp     w19, w9
        b.ne    6f
51:     LDW     w0, opt_n
        lsl     w0, w0, #2
        mov     w9, #5
        udiv    w0, w0, w9                      // n * 4/5
        bl      set_particles
        b       98f
6:      MOV32   w9, SDLK_RIGHT
        cmp     w19, w9
        b.eq    61f
        cmp     w19, #'>'
        b.ne    7f
61:     mov     w0, #1
        bl      pool_step
        ADR_L   x1, s_r_next
        mov     w2, #0
        mov     w3, #0
        bl      switch_to
        b       98f
7:      MOV32   w9, SDLK_LEFT
        cmp     w19, w9
        b.eq    71f
        cmp     w19, #'<'
        b.ne    72f
71:     mov     w0, #-1
        bl      pool_step
        ADR_L   x1, s_r_prev
        mov     w2, #0
        mov     w3, #0
        bl      switch_to
        b       98f
72:     cmp     w19, #'c'                       // auto-cycle on/off (needs an interval > 0)
        b.ne    73f
        LDRS    d0, opt_interval, x9
        fcmp    d0, #0.0
        b.le    98f
        LDW     w9, cycle_on
        eor     w9, w9, #1
        STW     w9, cycle_on
        bl      clock_now
        fmov    x20, d0
        LDRS    d1, opt_interval, x9
        fadd    d0, d0, d1
        ADR_L   x9, deadline
        str     d0, [x9]
        LDW     w9, opt_log
        cbz     w9, 98f
        ADR_L   x0, s_cycle_log
        fmov    d0, x20
        ADR_L   x1, s_off
        ADR_L   x9, s_on
        LDW     w10, cycle_on
        cmp     w10, #0
        csel    x1, x9, x1, ne
        bl      printf
        b       98f
73:     sub     w9, w19, #'1'                   // 1-9: type count
        cmp     w9, #8
        b.hi    98f
        add     w0, w9, #1
        bl      retype
98:     mov     w0, #0
        LEAVE2

// window frame locals
.set W_TTITLE, 0        // time of the last title update
.set W_STEPT, 8         // seconds spent stepping since then
.set W_FRAMES, 16       // frames since then
.set W_STEPS, 24        // steps since then
.set W_TSTEP, 32
.set W_LAST, 40         // last clock_now
.set W_UPLOAD, 48       // seconds uploading since the title update
.set W_FLIP, 56         // seconds presenting since then
.set W_T0, 64           // frame stage timer
.set W_NFR, 72          // frames in total
.set W_TREN, 80         // totals: render, upload, present seconds
.set W_TUP, 88
.set W_TFL, 96
.set W_FRAME, 112

window:
        ENTER   W_FRAME
        mov     w0, #SDL_INIT_VIDEO
        bl      SDL_Init
        tbnz    w0, #31, sdl_fail
        // window size: the world, transposed for 90 / 270
        LDW     w3, opt_w
        LDW     w4, opt_h
        LDW     w9, opt_rotate
        cmp     w9, #90
        b.eq    1f
        cmp     w9, #270
        b.ne    2f
1:      mov     w10, w3
        mov     w3, w4
        mov     w4, w10
2:      mov     w5, #0
        LDW     w9, opt_fullscr
        cbz     w9, 3f
        mov     w5, #SDL_WINDOW_FULLSCREEN_DESKTOP
3:      ADR_L   x0, s_title0
        MOV32   w1, SDL_WINDOWPOS_CENTERED
        mov     w2, w1
        bl      SDL_CreateWindow
        cbz     x0, sdl_fail
        ADR_L   x9, win
        str     x0, [x9]
        LDW     w9, opt_fullscr
        cbz     w9, 4f
        mov     w0, #0
        bl      SDL_ShowCursor
4:      LDW     w9, opt_w
        LDW     w10, opt_h
        umull   x0, w9, w10
        lsl     x0, x0, #2
        bl      malloc
        cbnz    x0, 41f
        ADR_L   x0, s_nomem
        bl      die
41:     ADR_L   x9, pixels
        str     x0, [x9]
        LDW     w9, use_surface
        cbz     w9, 5f
        // surface: a view of our buffer for blits when the window surface
        // cannot be rendered into directly
        LDW     w1, opt_w
        LDW     w2, opt_h
        mov     w3, #32
        lsl     w4, w1, #2
        MOV32   w5, SDL_PIXELFORMAT_ARGB8888
        bl      SDL_CreateRGBSurfaceWithFormatFrom
        cbz     x0, sdl_fail
        ADR_L   x9, srcsurf
        str     x0, [x9]
        b       6f
5:      LDRS    x0, win, x9
        mov     w1, #-1
        mov     w2, #SDL_RENDERER_ACCEL | SDL_RENDERER_VSYNC
        LDW     w9, opt_novsync
        cbz     w9, 51f
        mov     w2, #SDL_RENDERER_ACCEL
51:     bl      SDL_CreateRenderer
        cbz     x0, sdl_fail
        ADR_L   x9, ren
        str     x0, [x9]
        MOV32   w1, SDL_PIXELFORMAT_ARGB8888
        mov     w2, #SDL_TEXTUREACCESS_STREAMING
        LDW     w3, opt_w
        LDW     w4, opt_h
        bl      SDL_CreateTexture
        cbz     x0, sdl_fail
        ADR_L   x9, tex
        str     x0, [x9]
        LDW     w11, opt_rotate
        ucvtf   d0, w11
        ADR_L   x12, angle
        str     d0, [x12]

6:      bl      now
        str     d0, [sp, #W_TTITLE]
        stp     xzr, xzr, [sp, #W_STEPT]
        stp     xzr, xzr, [sp, #W_STEPS]
        stp     xzr, xzr, [sp, #W_UPLOAD]
        stp     xzr, xzr, [sp, #W_NFR]
        stp     xzr, xzr, [sp, #W_TUP]
        ADR_L   x9, g_fps
        str     xzr, [x9]
        ADR_L   x9, g_ms
        str     xzr, [x9]
        ADR_L   x9, g_up
        str     xzr, [x9]
        ADR_L   x9, g_pr
        str     xzr, [x9]
        bl      clock_now
        str     d0, [sp, #W_LAST]
        LDRS    d1, opt_interval, x9
        fadd    d0, d0, d1
        ADR_L   x9, deadline
        str     d0, [x9]                        // the first preset gets a full interval

.Lframe:
        // events
.Lpoll:
        ADR_L   x0, event
        bl      SDL_PollEvent
        cbz     w0, .Lsim
        ADR_L   x9, event
        ldr     w10, [x9]
        cmp     w10, #SDL_QUIT
        b.eq    .Lquit
        cmp     w10, #SDL_KEYDOWN
        b.ne    .Lpoll
        ldr     w0, [x9, #20]                   // keysym.sym
        ldrh    w10, [x9, #24]                  // keysym.mod
        tst     w10, #KMOD_SHIFT
        b.eq    0f
        sub     w10, w0, #'a'                   // Shift+letter -> capital
        cmp     w10, #25
        b.hi    0f
        sub     w0, w0, #32
0:      bl      on_key
        cbnz    w0, .Lquit
        b       .Lpoll

.Lsim:
        // auto-cycle; a pause holds the countdown
        bl      clock_now
        ldr     d1, [sp, #W_LAST]
        fsub    d1, d0, d1
        str     d0, [sp, #W_LAST]
        LDW     w9, paused
        LDW     w10, opt_benchp                 // --bench-present: no stepping
        orr     w9, w9, w10
        cbz     w9, 0f
        LDRS    d2, deadline, x9
        fadd    d1, d1, d2
        ADR_L   x9, deadline
        str     d1, [x9]
        b       .Ldraw
0:      bl      cycle_tick
        bl      now
        str     d0, [sp, #W_TSTEP]
        LDW     w19, opt_spf
1:      cbz     w19, 2f
        bl      pl_step
        ldr     x9, [sp, #W_STEPS]
        add     x9, x9, #1
        str     x9, [sp, #W_STEPS]
        sub     w19, w19, #1
        b       1b
2:      bl      now
        ldr     d1, [sp, #W_TSTEP]
        fsub    d0, d0, d1
        ldr     d1, [sp, #W_STEPT]
        fadd    d0, d0, d1
        str     d0, [sp, #W_STEPT]

.Ldraw:
        bl      now
        str     d0, [sp, #W_T0]
        LDRS    x19, pixels, x9                 // render target
        LDW     w9, use_surface
        cbz     w9, 1f
        // surface: render straight into it when it is our size and format
        LDRS    x0, win, x9
        bl      SDL_GetWindowSurface
        cbz     x0, sdl_fail
        mov     x20, x0
        mov     w21, #0                         // direct?
        ldr     x9, [x20, #8]                   // format
        ldr     w9, [x9]
        MOV32   w10, SDL_PIXELFORMAT_ARGB8888
        MOV32   w11, SDL_PIXELFORMAT_RGB888
        cmp     w9, w10
        ccmp    w9, w11, #4, ne                 // Z set if either format
        b.ne    1f
        ldp     w9, w10, [x20, #16]             // w, h
        LDW     w11, opt_w
        LDW     w12, opt_h
        cmp     w9, w11
        ccmp    w10, w12, #0, eq
        b.ne    1f
        ldr     w9, [x20, #24]                  // pitch
        lsl     w11, w11, #2
        cmp     w9, w11
        b.ne    1f
        mov     x0, x20
        bl      SDL_LockSurface
        cbnz    w0, 1f
        mov     w21, #1
        ldr     x19, [x20, #32]                 // pixels
1:      mov     x0, x19
        LDW     w1, opt_w
        LDW     w2, opt_h
        bl      pl_render
        LDW     w9, overlay_on
        cbz     w9, 3f
        bl      cycle_text
        bl      overlay_text
        mov     x0, x19
        bl      draw_overlay
3:      bl      now
        ldr     d1, [sp, #W_T0]
        fsub    d1, d0, d1
        ldr     d2, [sp, #W_TREN]
        fadd    d2, d2, d1
        str     d2, [sp, #W_TREN]
        str     d0, [sp, #W_T0]
        LDW     w9, use_surface
        cbnz    w9, 4f
        // texture: upload, copy (rotated on the GPU), present
        LDRS    x0, tex, x9
        mov     x1, #0
        LDRS    x2, pixels, x9
        LDW     w3, opt_w
        lsl     w3, w3, #2
        bl      SDL_UpdateTexture
        LDRS    x0, ren, x9
        LDRS    x1, tex, x9
        mov     x2, #0
        LDW     w9, opt_rotate
        cbnz    w9, 31f
        mov     x3, #0
        bl      SDL_RenderCopy
        b       32f
31:     bl      rot_rect
        mov     x3, x0
        LDRS    x0, ren, x9
        LDRS    x1, tex, x9
        mov     x2, #0
        LDRS    d0, angle, x9
        mov     x4, #0
        mov     w5, #0                          // SDL_FLIP_NONE
        bl      SDL_RenderCopyEx
32:     bl      now
        bl      .Lupload_done
        LDRS    x0, ren, x9
        bl      SDL_RenderPresent
        b       5f
4:      // surface: unlock, or blit our buffer (scaled if the sizes differ)
        cbz     w21, 41f
        mov     x0, x20
        bl      SDL_UnlockSurface
        b       43f
41:     LDRS    x0, srcsurf, x9
        mov     x1, #0
        mov     x2, x20
        mov     x3, #0
        ldp     w9, w10, [x20, #16]
        LDW     w11, opt_w
        LDW     w12, opt_h
        cmp     w9, w11
        ccmp    w10, w12, #0, eq
        b.ne    42f
        bl      SDL_UpperBlit
        b       43f
42:     bl      SDL_UpperBlitScaled
43:     bl      now
        bl      .Lupload_done
        LDRS    x0, win, x9
        bl      SDL_UpdateWindowSurface
5:      bl      now
        ldr     d1, [sp, #W_T0]
        fsub    d1, d0, d1
        ldr     d2, [sp, #W_FLIP]
        fadd    d2, d2, d1
        str     d2, [sp, #W_FLIP]
        ldr     d2, [sp, #W_TFL]
        fadd    d2, d2, d1
        str     d2, [sp, #W_TFL]
        ldr     x9, [sp, #W_FRAMES]
        add     x9, x9, #1
        str     x9, [sp, #W_FRAMES]
        ldr     x9, [sp, #W_NFR]
        add     x9, x9, #1
        str     x9, [sp, #W_NFR]
        LDW     w10, opt_benchp
        cbz     w10, 6f
        cmp     x9, x10
        b.hs    .Lquit

        // every 0.5 s: fps over the frames presented since, ms per step,
        // upload and present ms per frame
6:      bl      now
        ldr     d1, [sp, #W_TTITLE]
        fsub    d1, d0, d1
        LDRS    d2, D_HALF, x9
        fcmp    d1, d2
        b.lt    .Lframe
        str     d0, [sp, #W_TTITLE]
        ldr     d2, [sp, #W_FRAMES]
        scvtf   d2, d2
        fdiv    d0, d2, d1                      // fps
        ADR_L   x9, g_fps
        str     d0, [x9]
        LDRS    d5, D_1E3, x9
        ldr     d3, [sp, #W_UPLOAD]
        fdiv    d3, d3, d2
        fmul    d3, d3, d5
        ADR_L   x9, g_up
        str     d3, [x9]
        ldr     d3, [sp, #W_FLIP]
        fdiv    d3, d3, d2
        fmul    d3, d3, d5
        ADR_L   x9, g_pr
        str     d3, [x9]
        ldr     x9, [sp, #W_STEPS]
        cbz     x9, 7f                          // paused: keep the last ms/step
        scvtf   d2, x9
        ldr     d1, [sp, #W_STEPT]
        fdiv    d1, d1, d2
        fmul    d1, d1, d5                      // ms/step
        ADR_L   x9, g_ms
        str     d1, [x9]
7:      stp     xzr, xzr, [sp, #W_STEPT]
        stp     xzr, xzr, [sp, #W_STEPS]
        stp     xzr, xzr, [sp, #W_UPLOAD]
        bl      cycle_text
        bl      spawn_name
        mov     x20, x0
        bl      palette_name
        mov     x21, x0
        ADR_L   x22, s_empty
        ADR_L   x9, s_paused
        LDW     w10, paused
        cmp     w10, #0
        csel    x22, x9, x22, ne
        bl      preset_list
        mov     x23, x0
        mov     w24, w1
        mov     w25, w2
        bl      preset_name
        mov     x3, x0
        sub     sp, sp, #48
        ADR_L   x9, pl
        ldr     w10, [x9, #PL_N]
        ldr     w11, [x9, #PL_K]
        stp     x10, x11, [sp]                  // particles, types
        stp     x20, x21, [sp, #16]             // spawn, palette
        str     x22, [sp, #32]                  // paused
        ADR_L   x0, title
        mov     x1, #512
        ADR_L   x2, s_title
        mov     x4, x23
        mov     w5, w24
        mov     w6, w25
        ADR_L   x7, cbuf
        LDRS    d0, g_fps, x9
        LDRS    d1, g_ms, x9
        LDRS    d2, g_up, x9
        bl      snprintf
        add     sp, sp, #48
        LDRS    x0, win, x9
        ADR_L   x1, title
        bl      SDL_SetWindowTitle
        b       .Lframe

// time since W_T0 (d0 = now) into the upload sums; W_T0 = now. A local
// subroutine of window (its frame is at sp + 16 here).
.Lupload_done:
        stp     x29, x30, [sp, #-16]!
        ldr     d1, [sp, #16 + W_T0]
        fsub    d1, d0, d1
        ldr     d2, [sp, #16 + W_UPLOAD]
        fadd    d2, d2, d1
        str     d2, [sp, #16 + W_UPLOAD]
        ldr     d2, [sp, #16 + W_TUP]
        fadd    d2, d2, d1
        str     d2, [sp, #16 + W_TUP]
        str     d0, [sp, #16 + W_T0]
        ldp     x29, x30, [sp], #16
        ret

// x0 = the destination rectangle of the rotated copy for the current
// output size (queried every frame: fullscreen and window managers may
// change it after creation), or NULL (fill the output) if SDL cannot tell.
// Before rotation about its centre the rectangle is the output, transposed
// for 90 / 270.
rot_rect:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        LDRS    x0, ren, x9
        ADR_L   x1, outw
        ADR_L   x2, outh
        bl      SDL_GetRendererOutputSize
        mov     x9, x0
        mov     x0, #0
        cbnz    w9, 9f
        LDW     w9, outw
        LDW     w10, outh
        LDW     w11, opt_rotate
        ADR_L   x0, dstrect
        stp     wzr, wzr, [x0]
        stp     w9, w10, [x0, #8]
        cmp     w11, #90
        b.eq    1f
        cmp     w11, #270
        b.ne    9f
1:      sub     w12, w9, w10
        asr     w12, w12, #1                    // (ow - oh) / 2
        neg     w13, w12                        // (oh - ow) / 2
        stp     w12, w13, [x0]
        stp     w10, w9, [x0, #8]
9:      ldp     x29, x30, [sp], #16
        ret

.Lquit:
        // averages over the whole run
        ldr     x9, [sp, #W_NFR]
        cbz     x9, 9f
        scvtf   d6, x9
        LDRS    d5, D_1E3, x9
        ldr     d0, [sp, #W_TREN]
        fdiv    d0, d0, d6
        fmul    d0, d0, d5
        ldr     d1, [sp, #W_TUP]
        fdiv    d1, d1, d6
        fmul    d1, d1, d5
        ldr     d2, [sp, #W_TFL]
        fdiv    d2, d2, d6
        fmul    d2, d2, d5
        bl      present_name
        mov     x1, x0
        ADR_L   x0, s_pres_res
        LDW     w2, opt_w
        LDW     w3, opt_h
        LDW     w4, opt_rotate
        ADR_L   x5, s_empty
        ADR_L   x9, s_fs
        LDW     w10, opt_fullscr
        cmp     w10, #0
        csel    x5, x9, x5, ne
        ldr     x6, [sp, #W_NFR]
        bl      printf
        mov     x0, #0
        bl      fflush
9:      LDW     w9, use_surface
        cbnz    w9, 91f
        LDRS    x0, tex, x9
        bl      SDL_DestroyTexture
        LDRS    x0, ren, x9
        bl      SDL_DestroyRenderer
        b       92f
91:     LDRS    x0, srcsurf, x9
        bl      SDL_FreeSurface
92:     LDRS    x0, win, x9
        bl      SDL_DestroyWindow
        bl      SDL_Quit
        mov     w0, #0
        LEAVE   W_FRAME

// ------------------------------------------------------------------ lists
list_presets:
        ENTER
        mov     w19, #0
1:      mov     w0, w19
        bl      pl_entry_types
        cbz     w0, 2f
        mov     w2, w0
        ADR_L   x0, kbuf
        ADR_L   x1, s_kfmt
        bl      sprintf
        ADR_L   x21, kbuf
        b       3f
2:      ADR_L   x21, s_kdraw
3:      mov     w0, w19
        bl      pl_entry_rule
        ADR_L   x20, pl_preset_phys
        add     x20, x20, x0, lsl #5
        mov     w0, w19
        bl      pl_entry_name
        mov     x2, x0
        ADR_L   x3, s_curated
        ADR_L   x9, s_generated
        cmp     w19, #NCURATED
        csel    x3, x9, x3, hs
        mov     x4, x21
        ADR_L   x0, s_listfmt
        mov     w1, w19
        ldp     s0, s1, [x20]
        ldp     s2, s3, [x20, #8]
        ldp     s4, s5, [x20, #16]
        ldr     s6, [x20, #24]
        fcvt    d0, s0
        fcvt    d1, s1
        fcvt    d2, s2
        fcvt    d3, s3
        fcvt    d4, s4
        fcvt    d5, s5
        fcvt    d6, s6
        bl      printf
        add     w19, w19, #1
        cmp     w19, #NENTRIES
        b.lo    1b
        LEAVE

list_spawns:
        ENTER2
        mov     w19, #0
1:      ADR_L   x3, s_notpat
        cmp     w19, #2                         // ring
        b.eq    2f
        cmp     w19, #7                         // spiral
        b.eq    2f
        cmp     w19, #11                        // line_mixed
        b.eq    2f
        cmp     w19, #16                        // random
        b.eq    2f
        ADR_L   x3, s_starpat
        cmp     w19, #15                        // star: replaced by star_fixed
        b.eq    2f
        ADR_L   x3, s_fixpat
        cmp     w19, #17
        b.eq    2f
        ADR_L   x3, s_inpat
2:      ADR_L   x9, pl_spawn_names
        ldr     x2, [x9, x19, lsl #3]
        ADR_L   x0, s_lspfmt
        mov     w1, w19
        bl      printf
        add     w19, w19, #1
        cmp     w19, #NSPAWNS
        b.lo    1b
        LEAVE2

// each palette with the type counts it qualifies for, e.g. "2-9" or "2-16"
list_palettes:
        ENTER
        mov     w19, #0
1:      LDW     w9, pl_npalettes
        cmp     w19, w9
        b.hs    9f
        mov     w20, #1                         // largest K such that 2..K all qualify
2:      add     w1, w20, #1
        cmp     w1, #MAXK
        b.hi    3f
        mov     w0, w19
        bl      pl_palette_ok
        cbz     w0, 3f
        add     w20, w20, #1
        b       2b
3:      ADR_L   x0, kbuf
        mov     x1, #64
        ADR_L   x2, s_krange
        mov     w3, w20
        cmp     w20, #1
        b.ne    31f
        ADR_L   x2, s_knone
31:     bl      snprintf
        ADR_L   x9, pl_palette_cols
        ldr     x9, [x9, x19, lsl #3]
        ldr     w3, [x9]
        ADR_L   x9, pl_palette_names
        ldr     x2, [x9, x19, lsl #3]
        ADR_L   x0, s_lpalfmt
        mov     w1, w19
        ADR_L   x4, kbuf
        bl      printf
        add     w19, w19, #1
        b       1b
9:      LEAVE

// ------------------------------------------------------------------ main
        .globl main
        .type main, %function
main:
        ENTER
        bl      parse_args

        LDW     w9, opt_list
        cbz     w9, 11f
        bl      list_presets
        b       19f
11:     LDW     w9, opt_lspawns
        cbz     w9, 12f
        bl      list_spawns
        b       19f
12:     LDW     w9, opt_lpal
        cbz     w9, 13f
        ADR_L   x9, pl                          // qualification needs pl.K only
        mov     w10, #2
        str     w10, [x9, #PL_K]
        bl      list_palettes
19:     mov     w0, #0
        bl      exit

        // --pool, --preset, --spawn, --palette
13:     LDRS    x19, opt_pool, x9
        cbz     x19, 132f
        mov     w20, #0
131:    ADR_L   x9, pl_pool_names
        ldr     x1, [x9, x20, lsl #3]
        mov     x0, x19
        bl      strcasecmp
        cbz     w0, 133f
        add     w20, w20, #1
        cmp     w20, #3
        b.lo    131b
        ADR_L   x0, s_badpool
        mov     x1, x19
        bl      die_arg
133:    mov     w0, w20
        bl      pl_pool_set
132:    LDRS    x0, opt_preset, x9
        cbz     x0, 14f
        bl      pl_entry_find
        STW     w0, start_preset
        tbz     w0, #31, 14f
        ADR_L   x0, s_badpreset
        LDRS    x1, opt_preset, x9
        bl      die_arg
14:     LDRS    x0, opt_spawn, x9
        cbz     x0, 141f
        bl      pl_spawn_find
        STW     w0, spawn_pin
        tbz     w0, #31, 141f
        ADR_L   x0, s_badspawn
        LDRS    x1, opt_spawn, x9
        bl      die_arg
141:    LDRS    x0, opt_palette, x9
        cbz     x0, 142f
        bl      pl_palette_find
        STW     w0, palette_pin
        tbz     w0, #31, 142f
        ADR_L   x0, s_badpal
        LDRS    x1, opt_palette, x9
        bl      die_arg

        // auto-cycle unless --no-cycle or --interval 0; headless logs switches
142:    LDRS    d0, opt_interval, x9
        fcmp    d0, #0.0
        b.le    15f
        LDW     w9, opt_nocycle
        cbnz    w9, 15f
        mov     w9, #1
        STW     w9, cycle_on
15:     LDW     w9, opt_headless
        cbz     w9, 16f
        mov     w9, #1
        STW     w9, opt_log
16:
        // validate
        LDW     w9, opt_n
        cbz     w9, usage
        MOV32   w10, MAX_PARTICLES
        cmp     w9, w10
        b.hi    usage
        LDW     w9, opt_k
        cmp     w9, #MAXK
        b.hi    usage
        LDW     w9, opt_w
        cmp     w9, #256
        b.lo    usage
        mov     w10, #32768
        cmp     w9, w10
        b.hi    usage
        LDW     w9, opt_h
        cmp     w9, #256
        b.lo    usage
        cmp     w9, w10
        b.hi    usage
        LDW     w9, opt_cdiv
        sub     w9, w9, #1
        cmp     w9, #MAXCDIV - 1
        b.hi    usage
        LDRS    x0, opt_present, x9             // --present texture|surface
        cbz     x0, 162f
        ADR_L   x1, s_texture
        bl      strcmp
        cbz     w0, 162f
        LDRS    x0, opt_present, x9
        ADR_L   x1, s_surface
        bl      strcmp
        cbnz    w0, usage
        mov     w9, #1
        STW     w9, use_surface
162:    LDW     w9, opt_rotate                  // 0, 90, 180, 270; texture only
        cbz     w9, 17f
        LDW     w10, use_surface
        cbnz    w10, 161f
        cmp     w9, #90
        b.eq    17f
        cmp     w9, #180
        b.eq    17f
        cmp     w9, #270
        b.eq    17f
161:    ADR_L   x0, s_badrot
        bl      die

        // SIMD: Advanced SIMD is required (and always present on ARMv8-A Linux)
17:     bl      pl_cpu_features
        tbnz    w0, #0, 1f
        ADR_L   x0, s_noneon
        bl      die
1:      ADR_L   x9, pl
        mov     w10, #1
        str     w10, [x9, #PL_SIMD]
        LDRS    x0, opt_simd, x9
        cbz     x0, 4f
        ADR_L   x1, s_neon
        bl      strcmp
        cbnz    w0, usage

        // threads: default 1 for bench/dump/headless, every online CPU for
        // the window (the Pi 4 has 4 cores, no SMT)
4:      LDW     w0, opt_threads
        cbnz    w0, 5f
        mov     w0, #1
        LDW     w9, opt_bench
        LDW     w10, opt_headless
        orr     w9, w9, w10
        LDW     w10, opt_benchr
        orr     w9, w9, w10
        LDRS    x10, opt_dump, x16
        orr     x9, x9, x10
        cbnz    x9, 5f
        mov     w0, #SC_NPROCESSORS_ONLN
        bl      sysconf
        cmp     x0, #1
        csinc   x0, x0, xzr, ge
5:      bl      pl_threads_start

        bl      setup_sim

        // --keys: run the window's key handler on each character
        LDRS    x19, opt_keys, x9
        cbz     x19, 51f
50:     ldrb    w0, [x19]
        cbz     w0, 51f
        bl      on_key
        add     x19, x19, #1
        b       50b

51:     LDW     w9, opt_bench
        cbz     w9, 52f
        bl      bench
        mov     w0, #0
        b       9f
52:     LDW     w9, opt_benchr
        cbz     w9, 6f
        bl      bench_render
        b       9f
6:      LDRS    x9, opt_dump, x16
        cbz     x9, 7f
        bl      dump_frame
        b       9f
7:      LDW     w9, opt_headless
        cbz     w9, 8f
        bl      headless
        b       9f
8:      bl      window
9:      bl      exit
