# Running on the Raspberry Pi 4

The AArch64 / NEON build (`src/arm64/`, see the ARM64 section of the README)
for a Raspberry Pi 4 Model B (Cortex-A72, 4 cores) on Raspberry Pi OS 64-bit
(Debian 13), with the Waveshare 5.5" HDMI AMOLED (1080x1920, portrait).

Status: runs on a Raspberry Pi 4 Model B Rev 1.5 (Raspberry Pi OS 64-bit,
Debian 13). The test suites pass except one scene against the reference
tolerance, and the benchmark numbers are in the README ("Measured on the
Pi"). The workflow below is what produced them.

## 1. Once, on the Pi

```sh
sudo apt update
sudo apt install build-essential libsdl2-dev rsync
```

`build-essential` brings `gcc` and GNU `as`; `libsdl2-dev` the SDL2 headers and
library the window links against. Nothing else is needed.

## 2. One command from the desktop

With SSH working (ideally with a key: `ssh-copy-id pi@<host>`), from the
repository on the x86 machine:

```sh
tools/pi.sh pi@<host> test      # copy, build, run every test suite
tools/pi.sh pi@<host> bench     # copy, build, benchmarks + kernel variants
tools/pi.sh pi@<host> present   # time the display path at 1080x1920
tools/pi.sh pi@<host> all       # all of the above
```

It copies the tree to `~/particle_life_asm` with rsync (no `.git`, no build
directories), builds there with `make -j4`, runs the step and saves everything
it prints to `pi-<step>-<date>.log` here.

## 3. The same by hand

```sh
# on the desktop
rsync -az --exclude build --exclude 'build-arm64*' --exclude .git \
    ./ pi@<host>:particle_life_asm/
ssh pi@<host>

# on the Pi
cd particle_life_asm
make -j4                 # ARCH defaults to the host: aarch64, output in build-arm64/
make test                # all suites, see below
make bench               # benchmarks, see below
```

### Tests

`make test` runs the same suites as on x86, from `tests/`:

| suite | checks |
|---|---|
| `test_step` | asm vs the C reference (grid and O(N^2) brute force), bit-identical rules and initial state, K = 3..16, both grid sizes, strong forces, a very dense case, 8 threads |
| `test_spawns` | every spawn layout bit-identical to pl-box (FNV hash of all coordinates), invariants for K = 1..16 |
| `test_overlay` | the overlay text renderer pixel by pixel |
| `test_presets` | all 29 deterministic presets bit-identical to pl-box for K = 1..16, physics, derived tables, the shuffle bag, preset switches vs the C reference (stale-rule detection), scene switches over K = 2..16, A -> B -> A reproducibility |
| `test_threads 4` | 4 worker threads vs 1 thread, bit for bit, a state hash after every one of 300 steps, 5 cases (clustered presets, K = 3..16, both grid sizes, a tiny world) |
| `test_cycle.sh` | the binary headless: auto-cycle shuffle bag in every pool, timers, keys, options |

Each prints `ALL ... PASSED` at the end. The 4-thread test is the one that
exercises the AArch64 memory ordering (acquire/release in `src/arm64/threads.S`)
on real hardware; under qemu on an x86 host the guest inherits x86's strong
ordering, so only the Pi can catch an ordering bug.

Two things to look at if a suite fails:

* `test_presets` or `test_spawns` "MISMATCH" against pl-box only: the
  matrices and layouts go through glibc's `sinf` / `cosf` / `expf` /
  `atan2f` / `powf`, and the reference files were produced on x86. glibc
  builds the same C code for both architectures, but x86-64 may pick an
  FMA variant at run time and AArch64 GCC contracts to FMA, so a rare
  one-ulp difference is possible. That would be libm, not the port; the
  output names the preset/layout and K, which tells which call.
* `test_step` tolerance failures: the NEON kernel computes 1/d with
  FRSQRTE + two Newton steps (`NEWTON=2`, the default). `NEWTON=1` (one step,
  ~16 bits) is faster and is expected to stay within the 1e-3 px tolerance,
  but that is unverified: `make test NEWTON=1 BUILD=build-arm64-newton1`.

### Benchmarks

`make bench` prints, in the same format as on x86:

* 10k / 50k / 200k particles at constant density, 1 thread and 4 threads;
* the panel pass: 10k / 20k / 40k particles in a 1080x1920 world, 1 and 4
  threads;
* the renderer alone at 1080x1920 (`--bench-render`).

Kernel variants, built side by side (no `make clean` needed):

```sh
make bench NEWTON=1 BUILD=build-arm64-newton1   # one Newton step for 1/d
make bench KPIPE=0  BUILD=build-arm64-plain     # no software pipelining
```

and the C reference compiled for the A72 (`gcc -O3 -mcpu=cortex-a72`):
`make bench-ref`.

Before benchmarking, check that the CPU is not throttling:
`vcgencmd measure_temp`, `vcgencmd get_throttled` (0x0 is good), and the
governor in `/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`
(`performance` for stable numbers: `echo performance | sudo tee
/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor`).

## 4. The window on the AMOLED panel

From a terminal on the Pi's desktop (or see below for SSH):

```sh
make run-panel                     # 1080x1920 world, fullscreen, 4 threads
./build-arm64/particle_life --width 1080 --height 1920 --fullscreen --particles 20000
```

* If the panel shows the picture sideways (the HDMI mode is 1920x1080 and the
  panel is mounted portrait), add `--rotate 90` (or `270`). The world stays
  1080x1920; the picture is rotated on the GPU when it is presented
  (`SDL_RenderCopyEx`), which costs no CPU time. If the desktop itself is
  already rotated (Screen Configuration), use `--rotate 0`.
* Threads default to the number of cores (4) in the window, `--threads N`
  overrides; `--steps-per-frame 1` halves the simulation work per frame.
* The overlay (`F`) shows the upload and present time per frame; on exit the
  averages are printed, e.g.
  `present texture 1080x1920 rotate 90 fullscreen: 600 frames, render ... ms + upload ... ms + present ... ms per frame`.

Measuring the display path (the frame is 1080x1920x4 = 8.3 MB):

```sh
./build-arm64/particle_life --width 1080 --height 1920 --fullscreen --no-vsync \
    --particles 20000 --bench-present 300                      # streaming texture
./build-arm64/particle_life --width 1080 --height 1920 --fullscreen --no-vsync \
    --particles 20000 --bench-present 300 --present surface    # window surface
```

`--bench-present N` draws N frames without stepping the simulation and prints
render / upload / present milliseconds per frame. `--present texture` uploads a
streaming ARGB8888 texture (`SDL_UpdateTexture`) and lets the GPU scale and
rotate it; `--present surface` renders straight into the window surface when
its format is 32-bit XRGB/ARGB at the world size (else it blits) and calls
`SDL_UpdateWindowSurface`, no GPU, no rotation.

Over SSH the program needs the desktop session's display:

```sh
# Wayland desktop (Raspberry Pi OS default)
XDG_RUNTIME_DIR=/run/user/$(id -u) WAYLAND_DISPLAY=wayland-0 ./build-arm64/particle_life ...
# X11 desktop
DISPLAY=:0 ./build-arm64/particle_life ...
# no desktop (console login / Lite image): SDL's KMS/DRM backend
SDL_VIDEODRIVER=kmsdrm ./build-arm64/particle_life ...
```

Keys are the same as on x86 (README): Space pause, Right/Left preset, R
re-roll, S spawn, K palette, [ ] types, +/- particles, F overlay, Esc quit.
