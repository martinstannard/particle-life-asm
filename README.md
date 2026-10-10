# Particle Life in x86-64 assembly

A Particle Life simulation whose whole program — simulation core, software
renderer, SDL2 window loop, argument parsing, benchmark — is hand-written
x86-64 assembly (GNU `as`, `.intel_syntax noprefix`, ~3600 lines). C appears
only in the reference implementation and the test harnesses.

It has the 31 rule presets of `~/code/pl-box` and switches to a new one every
20 seconds (see [Presets and cycling](#presets-and-cycling)).

![frame after 6000 steps](docs/frame.png)

*20 000 particles, 6 types, 1600×900, seed 1, after 6000 steps
(`--dump-frame`, converted to PNG).*

The model and parameters follow `~/code/pl-box` (`rules.rs`,
`simulation.rs`, render defaults): N particles of K types,
`attraction[i][j]` ∈ [-1, 1), per-pair `min_radius` ∈ [12, 24) and
`max_radius` ∈ [33, 70), force scale 0.3, core repulsion 0.6, friction 0.4,
dt = 1/60, toroidal world, semi-implicit Euler:

```
d >= maxr          : 0
d <  minr          : -core * (1 - d/minr)                    (hard-core repulsion)
minr <= d < maxr   : attraction * smoothstep(1 - (d-minr)/(maxr-minr))
v = v*(1 - friction*dt) + F*dt ;  p = wrap(p + v*dt)
```

pl-box's profile is the smoothstep-shaped bump, not the textbook triangle;
it is reproduced exactly (the O(N²) test reference below is a line-by-line
transcription of pl-box's loop).

## Build and run

Needs `gcc`/`as`/`ld`, libSDL2, and a CPU with AVX2 + FMA (AVX-512F is used
when CPUID and XGETBV report it).

```sh
make                 # build/particle_life and build/ref_bench
make run             # window, 20k particles, 1600x900, new preset every 20 s
make run ARGS="--particles 50000 --types 9 --no-vsync"
make test            # asm vs C reference vs brute force, presets vs pl-box, cycling
make bench           # headless, 10k/50k/200k particles, 1 and 8 threads
make bench-ref       # C reference, gcc -O3 -march=native
make bench-ref-clang # C reference, clang -O3 -ffast-math -march=native
```

```
particle_life [--particles N] [--types K(1-16)] [--seed S] [--width W] [--height H]
              [--threads T] [--simd avx2|avx512] [--cell-div 1|2]
              [--steps-per-frame S] [--no-vsync]
              [--bench STEPS [--warmup STEPS]]          headless benchmark
              [--dump-frame out.ppm [--steps STEPS]]    headless, writes one frame
              [--keys STR]                              feed key presses to the key handler first
                                                        ('>' / '<' stand for Right / Left)
              [--preset NAME]                           start on this preset (case-insensitive)
              [--interval SECONDS]                      auto-cycle period, default 20, 0 = off
              [--no-cycle]                              stay on the preset
              [--list-presets]                          print the 31 preset names
              [--headless FRAMES [--fake-clock DT]]     window frame loop without a window, logs switches
              [--log-switches]                          print a line per preset switch
```

Keys: Space pause, Right/Left next/previous preset (in list order, wrapping),
C auto-cycle on/off, R re-roll the current preset (same preset, next random
numbers: new radii and positions), N new positions, `+`/`-` particle count
×5/4 and ×4/5 (respawns), 1–9 type count (re-applies the current preset),
Esc quit. The title shows the preset, its number, the seconds to the next
switch (or "auto-cycle off"), particles, types, fps, ms per step, threads
and SIMD path, e.g.

```
Particle Life (asm) | Bipartite (8/31) | next in 3 s | 20000 particles, 6 types | 120 fps | step 0.39 ms | 8 threads avx512
```

The window and `--headless` always run a preset (`--preset`, otherwise a
random one). `--bench` and `--dump-frame` use the old plain random rules
unless `--preset` is given, so benchmark numbers stay comparable. Without
`--seed` the window seeds from the clock (a different preset order each
run). Everything else uses seed 1. The world is the window size, drawn 1:1. The window uses half the
logical CPUs by default; bench and dump use 1 thread unless `--threads` is
given.

## Presets and cycling

![all 31 presets](docs/presets.png)

*Every preset after 1200 steps (20 s at 60 steps/s): 5000 particles, 8
types, 960×540, seed 1, 2×2-pixel dots, thumbnails brightened
(`tools/contact_sheet.sh`).*

### The presets

The 31 `RulePreset` generators from pl-box `crates/pl-core/src/rules.rs`,
in pl-box's order and with its display names (`--preset` also accepts the
enum names, e.g. `RockPaperScissors`, `HelicalLadder`):

| # | name | # | name | # | name | # | name |
|--:|---|--:|---|--:|---|--:|---|
| 0 | Random | 8 | Hub&Spokes | 16 | Wavefield | 24 | SkipPursuit |
| 1 | Symmetric | 9 | Shells | 17 | ChiralBand | 25 | BlueNoise |
| 2 | Snake | 10 | Swirl | 18 | RotConveyor | 26 | Phasefield |
| 3 | Chains1 | 11 | Checker | 19 | PrimeHop | 27 | RingRoad |
| 4 | Chains2 | 12 | Dimers | 20 | ParityVortex | 28 | TriSpiral |
| 5 | Chains3 | 13 | TriadFlocks | 21 | Helical | 29 | VortexLattice |
| 6 | RPS | 14 | Conveyor | 22 | BiasedWave | 30 | DriftPatch |
| 7 | Bipartite | 15 | Patchwork | 23 | ModTriads | | |

**All of it is hand-written asm (`src/presets.S`). Nothing is generated at
build time.** Every pl-box generator is pointwise: `attraction[i][j]`
depends only on i, j and K. So one driver loops over (i, j) for the current
K (1–16) and calls a per-preset cell function. Symmetric reads back the
mirrored entry it already wrote; Random and Symmetric draw from the
program's RNG in pl-box's order. Sines, cosines and exponentials call libm
`sinf`/`cosf`/`expf`/`fmodf`. Those are the functions Rust's `f32::sin`,
`cos`, `exp` and `%` call on Linux. The arithmetic follows the Rust
expression order with no FMA contraction (Rust does not contract either),
and pl-box's quirks are kept: Patchwork's `sin(h as f32)` hash, the two
xorshift hashes, PrimeHop's prime that is always 2, and DriftPatch's
`base * 0.0` that leaves −0.0. The result is **bit-identical to pl-box for
all 29 deterministic presets and every K from 1 to 16** (test below).

pl-box's own Helical (up to ±1.1) and SkipPursuit (down to −1.335, from a
negative `%` in its `circ` helper) leave [-1, 1]. The raw generator output
matches pl-box exactly. When installed, every value is clamped to
[-1, 1], the range pl-box's own `jitter_attraction` clamps to.

**Radii and physics per preset.** As in `RuleMatrix::from_preset`, each
pair gets a random min radius and max radius from the preset's ranges (max
= min + 1 if they collide, which these ranges never do). The ranges and
force scale / friction / core repulsion come from pl-box's curated list
(`presets.rs`, `CURATED`) for the 17 presets in it. The other 14 use the
defaults of pl-box's `render.rs` preview tool, which were already this
program's defaults:

| family | presets | force | friction | core | min r | max r |
|---|---|--:|--:|--:|---|---|
| `cfg` | Random, Bipartite, Hub&Spokes, Shells, Dimers, TriadFlocks, Conveyor, ParityVortex, SkipPursuit | 1.1 | 0.6 | 0.7 | 12–22 | 28–45 |
| `cfg_fric` | VortexLattice / DriftPatch | 1.1 | 0.4 / 0.5 | 0.7 | 12–22 | 28–45 |
| `flow` | Swirl, Wavefield, ChiralBand, ModTriads, Phasefield, TriSpiral | 1.4 | 0.35 | 0.9 | 12–20 | 28–45 |
| not curated | Symmetric, Snake, Chains1–3, RPS, Checker, Patchwork, RotConveyor, PrimeHop, Helical, BiasedWave, BlueNoise, RingRoad | 0.3 | 0.4 | 0.6 | 12–24 | 33–70 |

The particle and type counts stay as set (pl-box's curated list fixes 7–9
types; here K stays whatever `--types` or 1–9 chose).

### What a switch replaces

Every switch (timer, Right/Left, R, 1–9, `--keys`, start-up) goes through
one path, `pl_preset_apply`:

1. physics: force scale, friction, core repulsion of the new preset;
2. the whole 16×16 attraction, min-radius and max-radius tables (entries
   outside K×K are zeroed);
3. `pl_update_tables`, the same routine the program has always used to set
   up rules: the kernel tables (b0, ir, c1, as), core·scale/2 and the damping
   factor, the global max radius, cell size and grid dimensions, the cell
   arrays (reallocated if the grid grows), the per-cell neighbour-range
   table and the kernel choice. Thread work partitions (cell chunk size,
   per-thread histograms) are derived from the cell count at the start of
   every multi-threaded step, so they follow the new grid automatically;
4. a fresh uniform scatter of all N particles (zero velocity, new random
   types) and a bin into the new grid.

Switches happen on the main thread between steps, while the workers wait
on the step barrier. `--log-switches` (on by default in `--headless`)
prints what was installed:

```
    2.000 s  timer  ->  2 Snake            0.03 ms  K=5 maxr 67.6 grid 23x17 force 0.30 fric 0.40 core 0.60
    4.000 s  timer  -> 30 DriftPatch       0.09 ms  K=5 maxr 44.1 grid 36x27 force 1.10 fric 0.50 core 0.70
    6.000 s  timer  -> 26 Phasefield       0.04 ms  K=5 maxr 44.6 grid 35x26 force 1.40 fric 0.35 core 0.90
```

The window has no rules readout beyond the title, which names the active
preset (above).

### Cycling

- The timer is `CLOCK_MONOTONIC` (`clock_gettime`), not frames: the
  next switch is due `--interval` seconds (default 20, fractional allowed,
  0 = off) after the last one. Any manual switch restarts the countdown, and
  the countdown is held while paused. The first preset gets a full interval
  counted from when the window loop starts.
- The next preset is drawn from a shuffle bag: uniformly among the presets
  not yet shown in this round, never the current one. When all 31 have
  been shown, a new round starts with only the current preset marked.
  Presets reached with Right/Left also count as shown.
- `--preset NAME` starts there and still cycles. `--no-cycle` (or
  `--interval 0`) stays on it. C toggles cycling at runtime.
- `--headless FRAMES` runs the window's frame loop (steps, then the cycle
  check) without SDL. `--fake-clock DT` advances the clock DT seconds per
  frame instead of reading the real clock, for deterministic tests.

### What the presets look like

Seen in the contact sheet above (one still frame each, so motion does not
show). To tell a gas from a frozen or collapsed state I also measured mean
speed and the coefficient of variation (CV) of particle counts on a 24 px
grid after 1200 steps. Pure noise gives CV ≈ 0.43; clumps give more.

- **Clear, distinct structure:** Bipartite (round single-colour blobs,
  CV 1.53), PrimeHop (the same kind of blobs, CV 1.57: with pl-box's prime
  always 2 it attracts even type distances, a parity rule much like
  Bipartite), Hub&Spokes (hollow rings), Shells (small mixed clusters),
  Checker (rings and curved chains, 1.30), Chains1 and Chains2 (short
  worms, 1.32 / 1.00), Dimers and TriadFlocks (dense lattices of small
  clusters), RingRoad and RotConveyor (filaments and streams), Patchwork
  (sparse clumps on gas).
- **Look alike:** Bipartite ≈ PrimeHop; Dimers ≈ TriadFlocks; Random,
  Symmetric, Snake and Chains3 all give loose small clusters (CV
  0.75–0.88).
- **Look like gas in a still frame:** RPS, Helical, BlueNoise and
  DriftPatch are a near-uniform, slow gas (CV 0.36–0.42, about 1–2 px/s).
  The `flow` presets Swirl, Wavefield, ModTriads, Phasefield and TriSpiral,
  and also ChiralBand and VortexLattice, move 4–5 times faster (4–8 px/s)
  but only clump slightly (CV 0.45–0.54). Conveyor, ParityVortex,
  SkipPursuit and BiasedWave show faint stripes and arcs (CV 0.49–0.63).
  None collapses into one blob and none freezes. More steps (6000) or 4×
  the density did not change this. pl-box's own comment in `presets.rs`
  explains it: uniform-random starts "tend to leave directional rules as
  diffuse dust", which is why pl-box spawns its presets from patterns
  (rings, spirals, clusters). Those spawn patterns are not ported (see
  below).

### Cost of a switch

200 000 particles, 8587×4830, K = 16 for the rule build:

| part | time |
|---|--:|
| matrix + radii + all derived tables + grid (`pl_preset_rules`) | 0.57 ms mean, 5.9 ms max (grid grows, cell arrays reallocated) |
| re-scatter + bin of 200 000 particles | 4.1 ms |
| whole switch as logged (`--keys '>>>>>>>>>>'`, 1 and 8 threads) | 4–16 ms |

The switch is serial (RNG scatter, serial bin), so threads do not change
it. One switch every 20 s costs nothing measurable; at 60 fps it is at most
one late frame.

## Layout

```
src/layout.inc   offsets of the global state struct `pl`
src/sim.S        RNG, rules, grid tables, binning (serial + parallel phases),
                 force kernels (AVX2 K<=8, AVX2 K<=16, AVX-512), step, CPUID
src/threads.S    pthread workers, barriers, dynamic cell scheduling
src/render.S     software renderer into an ARGB8888 buffer, PPM writer
src/presets.S    the 31 pl-box rule generators, per-preset physics, preset
                 install, shuffle bag, name lookup
src/main.S       main: options, bench, frame dump, SDL2 window, keys,
                 auto-cycle timer, headless frame loop
ref/ref.c        C reference: same grid step + O(N^2) pl-box-style step
ref/pl_state.h   C view of `pl` (offsets checked by _Static_assert)
tests/test_step.c    asm vs reference comparison (make test)
tests/test_presets.c presets vs pl-box, ranges, switch vs reference, A->B->A
tests/plbox_ref.txt  attraction matrices printed by pl-box itself
tests/test_cycle.sh  auto-cycle on the real binary (headless)
tools/plbox_dump/    prints pl-box's matrices (regenerates plbox_ref.txt)
tools/contact_sheet.sh  docs/presets.png
```

### Memory layout

One global struct `pl` (7424 bytes, 64-byte aligned, `src/layout.inc`)
holds scalars, pointers and the rule tables. Particles are
structure-of-arrays, float32 / int32, each array padded with 32 zeroed
elements so vector loads may run past the end:

```
current set  x[] y[] vx[] vy[] type[] id[]     cell-ordered
second set   x2[] y2[] vx2[] vy2[] type2[] id2[]  sort destination, swapped each step
scratch      nx[] ny[] (integrated positions), cellid[]
grid         cstart[ncells+1], ccur[ncells+1], nbr[ncells][10] neighbour ranges
tables       attr/minr/maxr[16][16]; kernel tables b0, ir, c1, as [16][16]
```

Rule tables have 16-float rows, so one type's row is one zmm register (or
two ymm) and per-pair parameters are fetched with `vpermps` indexed by the
neighbours' types. Up to 16 types are supported.

## Algorithm

Each step:

1. **Forces + integration.** Process each cell. For each particle *i* in it,
   sum the forces from every particle in the (2R+1)×(2R+1) neighbouring cells.
   Because particles are stored in cell order, the cells of one neighbour row
   form one contiguous index range (two at a wrap-around edge). Each range
   carries a ±W/±H shift that implements the torus without per-pair
   branches. The inner loop is SIMD over *j* (8 lanes AVX2, 16 lanes
   AVX-512). Then *i* is integrated, writing the velocity in place and the
   new position to `nx/ny`.
2. **Binning.** A stable counting sort by cell of `nx/ny` moves
   (x, y, vx, vy, type, id) into the second set, then the sets swap. Cell ids
   are computed 8 at a time. Counts and cursors are kept in registers for
   runs of equal cells, since particles rarely change cell. Each array then
   gets its own simple scatter loop.

Grid: cell size ≥ max radius / R, with R = `--cell-div`. With R = 1
(cell = max radius, the classic 3×3 cell list) a particle examines ~223
candidates, of which ~20% are within range. **R = 2 (default)** uses half-size
cells and a 5×5 neighbourhood: ~155 candidates, about 30% less work, and
1.2× faster in practice.

Force kernel per pair, using `s = (maxr - d)/(maxr - minr) = b0 - d·ir`:
s > 1 ⇔ d < minr and s ≤ 0 ⇔ d ≥ maxr, so no explicit cut-off mask is
needed. The kernel accumulates `g·(dx, dy)` with g = f/d:

```
core branch  (s > 1):  g = (d·c1 - core)/d = c1 - core/d
attraction   (s <= 1): g = a · sc²(3 - 2sc) / d,   sc = max(s, 0)
```

1/d is `vrsqrtps`/`vrsqrt14ps` plus one Newton step. The Newton step's ½ is
folded into the tables (exact powers of two), so the kernel works with 2/d
and 2d.

What made it fast (single thread, 10k particles, ns per particle-step):

| change | AVX-512 | AVX2 |
|---|---:|---:|
| first working version, R = 1 | 89.3 | 106.7 |
| binning: register run-lengths, per-array scatter | 85.6 | — |
| shorter dependency chain (c1 - core/d, parallel 1/d and d) | 83.8 | 96.4 |
| 2-stage software pipeline (AVX-512) | 78.5 | — |
| fewer FP-register allocations (folded loads, eps in FMA, no min) | 73.6 | 86.0 |
| R = 2 half-size cells | 62.9 | 71.2 |
| AVX-512: one pipelined stream over all ranges, masked tails | 62.1 | 71.0 |

`perf` showed the kernel bound by the FP physical register file on Zen 4,
not by FP throughput. 61% of cycles were dispatch stalls on
`fp_reg_file_rsrc_stall`: each vector of pairs has a ~55-cycle dependency
chain, and every zmm result holds a register until it retires. The changes
above shorten the chain and cut the number of register-writing ops per
vector. AVX-512 beats AVX2 here (16 lanes per register, masks, single
16-entry `vpermps` lookups), so it is the default when available. The AVX2
path stays for other CPUs and `--simd avx2`.

**Multi-threading:** persistent pthreads sleep on a pthread barrier between
steps. In a step, cells are handed out in chunks through an atomic counter
(dynamic, since clustering makes per-cell work uneven). Binning then runs
as a parallel counting sort: per-thread histograms over 16-aligned particle
chunks, a prefix sum over cell blocks, and per-chunk permutation and scatter.
It gives the same order as the serial sort. The phases are separated by a
spinning barrier that falls back to `sched_yield`.

## Correctness

`make test` builds `tests/test_step.c`, which links the asm core with
`ref/ref.c`, and runs each configuration from the same seed:

- rules, derived tables, grid, initial positions, cell order and ids must
  be **bit-identical** between asm and C;
- after every step, asm positions (matched by particle id, toroidal
  distance) must agree within **1e-3 px** with the C grid step, and on the
  smaller cases also with an **O(N²) brute-force** step written the way
  pl-box writes it (minimum-image delta, original force law). That proves
  the grid misses no neighbours.

Configurations: R = 1 and R = 2; AVX2 K≤8, AVX2 K>8 and AVX-512 kernels;
a tiny world with wrap-around on every cell; strong forces (dt = 1/20, force
scale 3, ~0.8 px/step, crossing cells and edges); a very dense world with
neighbour ranges far longer than 256 particles. That case caught a real
lane-mask bug (`bzhi` only reads 8 index bits), which I fixed and checked by
re-breaking the code. The test also covers 30k particles at 1920×1080 with 1
and 8 threads on both kernels, and 100 particles on 8 threads, where most
parallel-bin chunks are empty.

Last run (excerpt):

```
--- cell size = max radius / 1
N=2000   K=6  world= 800x600  fscale=0.3 dt=0.017 avx2-k8  threads=1  R=1 grid=11x8  init bit-identical
  60 steps: max |asm - C grid| = 6.10e-05 px, max |asm - brute| = 7.63e-06 px, max speed 0.022 px/step  OK
N=2000   K=11 world= 600x400  fscale=3.0 dt=0.050 avx512   threads=1  R=1 grid=8x5  init bit-identical
  20 steps: max |asm - C grid| = 6.10e-05 px, max |asm - brute| = 6.10e-05 px, max speed 0.827 px/step  OK
N=12000  K=4  world= 256x256  fscale=0.3 dt=0.017 avx512   threads=1  R=1 grid=3x3  init bit-identical
  3 steps: max |asm - C grid| = 1.93e-04 px, max |asm - brute| = 1.53e-05 px, max speed 0.012 px/step  OK
--- cell size = max radius / 2
N=30000  K=9  world=1920x1080 fscale=0.3 dt=0.017 avx2-k16 threads=8  R=2 grid=55x31  init bit-identical
  30 steps: max |asm - C grid| = 6.10e-05 px, max speed 0.028 px/step  OK
ALL TESTS PASSED
```

**Preset tests** (`tests/test_presets.c`, `tests/test_cycle.sh`, both in
`make test`):

1. *pl-box's own matrices.* `tools/plbox_dump` runs pl-box's
   `RuleMatrix::from_preset` for every preset and K = 1..16 and prints the
   attraction values as f32 bit patterns. `cargo` works offline here; the
   script copies `pl-core` into a temporary workspace with its own target
   directory, so pl-box is not modified. The output is
   `tests/plbox_ref.txt`. The test compares the asm generators bit for bit
   (Random and Symmetric are random in both programs and are range-checked
   only).
2. *Every preset installed for every K:* K×K attraction in [-1, 1] and zero
   outside, 0 < min r < max r within the preset's ranges, the preset's
   physics, and the derived tables, max radius and grid bit-identical to
   what the C reference derives from the same rules.
3. *Shuffle bag* (620 picks through `pl_preset_apply`): never the current
   preset, never a repeat within a round.
4. *Switch vs reference:* run preset A for 20 steps, switch to B, load the C
   reference from the asm state with B's rules, check the grid, tables and
   particle order are bit-identical, then step both. As a negative control,
   a third reference keeps A's (stale) rules on the same particles and must
   disagree. Seven switches cover every kernel, 1 and 8 threads, grids that
   grow and shrink, and a pair with the same physics where only the matrix
   changes.
5. *A → B → A:* with the same seed, A's 40 steps after the round trip are
   bit-identical (positions, velocities, order, tables, grid).
6. *Cycling on the real binary* (`--headless`): fake clock (100 timer
   switches exactly 1.000 s apart, 3 full shuffle rounds), real monotonic
   clock with a 0.05 s interval (all gaps ≥ 0.05 s), `--preset` plus
   cycling, `--no-cycle`, `--interval 0`, C, Right/Left/R through `--keys`,
   max radius and grid in every switch log line, unknown names rejected.

Last run (excerpt; all 29 deterministic presets print the same line):

```
--- attraction matrices vs pl-box (RuleMatrix::from_preset run by tools/plbox_dump)
  Snake         K=1..16: 16 matrices, 1496 values, bit-identical to pl-box
  Helical       K=1..16: 16 matrices, 1496 values, bit-identical to pl-box
  SkipPursuit   K=1..16: 16 matrices, 1496 values, bit-identical to pl-box
  DriftPatch    K=1..16: 16 matrices, 1496 values, bit-identical to pl-box
  29 of 29 deterministic presets bit-identical to pl-box (Random, Symmetric are random)
--- every preset installed for K = 1..16: ranges, physics, derived tables, grid
  Helical       force 0.30 fric 0.40 core 0.60 minr [12,24) maxr [33,70)  attraction in [-1.000, +1.000]  OK
  Swirl         force 1.40 fric 0.35 core 0.90 minr [12,20) maxr [28,45)  attraction in [-0.700, +0.700]  OK
--- shuffle bag
  620 picks: never the current preset, each preset once per round, 20 full rounds  OK
--- switch, then asm vs C reference loaded with the new rules from the same state
  Shells -> Checker  N=4000 K=6 avx2-k8 threads=1: maxr 44.8 -> 69.6, grid 44x31 -> 28x20, state bit-identical to ref
    30 steps: asm vs ref(new rules) max 6.1e-05 px, 0/4000 particles > 1e-03; vs brute(new) max 6.1e-05 px, 0 > 1e-03
              asm vs ref(OLD rules) max 0.72 px, 4000/4000 particles > 1e-03 (stale rules detected)  OK
  Shells -> Dimers  N=4000 K=6 avx2-k8 threads=1: maxr 44.9 -> 43.9, grid 44x31 -> 45x31, state bit-identical to ref
    30 steps: asm vs ref(new rules) max 6.1e-05 px, 0/4000 particles > 1e-03; vs brute(new) max 6.1e-05 px, 0 > 1e-03
              asm vs ref(OLD rules) max 0.79 px, 3999/4000 particles > 1e-03 (stale rules detected)  OK
  Helical -> SkipPursuit  N=20000 K=7 avx512 threads=8: maxr 69.1 -> 44.9, grid 55x31 -> 85x48, state bit-identical to ref
    20 steps: asm vs ref(new rules) max 1.8e-03 px, 1/20000 particles > 1e-03; vs brute(new) max 1.8e-03 px, 1 > 1e-03
              asm vs ref(OLD rules) max 0.40 px, 19997/20000 particles > 1e-03 (stale rules detected)  OK
--- A -> B -> A with the same seed
  Shells -> Checker -> Shells  N=5000 K=6 threads=1 (grid 40x31 -> 25x20 -> 40x31): 40 steps of A bit-identical  OK
  Random -> BlueNoise -> Random  N=20000 K=8 threads=8 (grid 40x31 -> 25x20 -> 40x31): 40 steps of A bit-identical  OK
ALL PRESET TESTS PASSED
  fake clock: 101 switches, 3 full rounds, each preset once per round, never twice in a row  OK
  fake clock: 100 timer switches, exactly 1.000 s apart  OK
  real clock: 91 switches, 3 full rounds, each preset once per round, never twice in a row  OK
  real clock: 90 timer switches, gaps >= 0.050 s (min 0.050, max 0.051 s as logged)  OK
  --preset helicalladder: starts on Helical, 5 timer switches in 5 s  OK
  --no-cycle: no automatic switch in 20 s  OK
  --keys cc: cycling back on, 4 timer switches in 20 s (at 5, 10, 15, 20)  OK
  keys > > < r: start:DriftPatch next:Random next:Symmetric prev:Random reroll:Random   OK
ALL CYCLE TESTS PASSED
```

In the 20 000-particle switch cases one particle out of 20 000 ends up
2e-3 px off. Step by step, all particles agree to 5e-7 px until step 12.
Then one particle jumps and drifts linearly, and the C grid and brute-force
references agree with each other. This is pl-box's force jump at d = minr
(below): one float ulp in d puts a pair on the other side of the jump.
The curated presets use 3.7× the old force scale, so the jump is bigger.
The switch test therefore allows up to N/1000 particles above 1e-3 px
(each still under 0.05 px). A stale matrix moves essentially every particle
by 0.4–0.9 px.

The residual differences are a few float ulps. They come from summation
order and the rsqrt + Newton 1/d versus the C `1/sqrtf`. pl-box's force law
has a jump at d = minr, so the C grid and asm can disagree by up to ~5e-4 px
over 30 steps when a pair sits exactly on minr.

## Performance

AMD Ryzen 7 255 (Zen 4, 8 cores / 16 threads, mobile), Linux, gcc 16.2,
clang 22.1. Constant density (10k particles per 1920×1080, the world grows
with N), 6 types, seed 1, 100 warm-up steps then 200 timed steps
(`make bench`). The machine was shared with other sessions (load average
≈3), so multi-thread numbers are noisy.

| particles | world | asm 1 thread | ns/particle-step | asm 8 threads | ns/particle-step |
|---:|---|---:|---:|---:|---:|
| 10 000 | 1920×1080 | 1610 steps/s | 62.1 | 10 636 steps/s | 9.4 |
| 50 000 | 4293×2415 | 325 steps/s | 61.6 | 1 893 steps/s | 10.6 |
| 200 000 | 8587×4830 | 79.7 steps/s | 62.8 | 496 steps/s | 10.1 |

C reference (`ref/ref.c`, same algorithm and R = 2, scalar code, one
thread):

| particles | gcc -O3 -march=native | clang -O3 -ffast-math -march=native | asm 1 thread vs gcc | vs clang |
|---:|---:|---:|---:|---:|
| 10 000 | 143 steps/s (697 ns) | 416 steps/s (241 ns) | 11.2× | 3.9× |
| 50 000 | 28.7 steps/s (697 ns) | 82.0 steps/s (244 ns) | 11.3× | 3.9× |
| 200 000 | 7.2 steps/s (691 ns) | 19.9 steps/s (252 ns) | 11.1× | 4.0× |

GCC does not vectorise the reference's inner loop: per-pair table lookups
and the branch select read as "unsupported control flow". Clang does
(16-wide AVX-512) once `-ffast-math` lets it reassociate the force sums. The
clang column is the fair "good compiler" baseline.

Other single-thread variants (ns/particle-step at 10k / 50k / 200k):

| variant | 10k | 50k | 200k |
|---|---:|---:|---:|
| AVX-512, R = 2 (default) | 62.1 | 61.6 | 62.8 |
| AVX2, R = 2 | 71.0 | 74.1 | 74.6 |
| AVX-512, R = 1 (cell = max radius) | 74.3 | 74.2 | 74.5 |
| AVX2, R = 1 | 85.1 | 83.5 | 83.9 |

Thread scaling at 200k (one run each, shared machine): 1 → 79.5,
4 → 291, 8 → 447–511, 12 → 564, 16 → 340 steps/s. 16 threads use every
logical CPU, so other processes preempt the spinning phases. SMT siblings
also share the FP units this kernel saturates.

**After adding presets** (kernels untouched; `make bench`, which uses the
plain random rules exactly as before). The old build is commit `fe587ee`
in a separate worktree, run alternately with the new one. ns/particle-step,
4 runs each (runs 1, 3, 4 shown; in run 2 another session's `beam.smp`
took ~9 cores during both builds and the numbers are meaningless):

| particles | threads | before (fe587ee) | after |
|---:|--:|---|---|
| 10 000 | 1 | 63.8 / 66.2 / 63.5 | 63.2 / 65.4 / 63.7 |
| 50 000 | 1 | 61.6 / 68.5 / 65.1 | 61.5 / 69.9 / 63.7 |
| 200 000 | 1 | 63.3 / 66.6 / 65.8 | 63.3 / 68.8 / 64.1 |
| 10 000 | 8 | 11.1 / 13.4 / 11.2 | 10.1 / 12.5 / 11.3 |
| 50 000 | 8 | 9.2 / 12.8 / 11.4 | 11.3 / 11.0 / 11.1 |
| 200 000 | 8 | 11.3 / 13.0 / 11.2 | 10.6 / 10.3 / 10.8 |

Same speed within run-to-run noise (load average ≈ 9 during runs 3–4).
Speed with a preset depends on its radius range, not on the code:
200 000 particles, 1 thread: Snake (max r 33–70) 69 ns, Bipartite and
Swirl (max r 28–45, smaller cells, fewer candidates) 43 ns per
particle-step.

Window (Wayland/niri, run for a few seconds with `timeout`, read back via
`niri msg windows`): 20 000 particles in 1600×900, 8 threads, AVX-512: title
"120 fps | step 0.79 ms" with vsync. 50 000 particles with `--no-vsync`:
"159 fps | step 2.62 ms" at 2 steps per frame.

## What was tested and what not

- `make test` passes (output above). `make bench` and the reference benches
  were run, giving the numbers above.
- The SDL window opened on this Wayland session (niri, native Wayland) and
  ran for 6–10 s with no errors, and the compositor reported the title with
  live fps. I did not look at the window contents. The visual check is the
  `--dump-frame` output, which goes through the same `pl_render` code.
- Key presses were not sent to the real window, to avoid injecting input
  into the desktop. The key handler is the same function `--keys` drives
  headlessly. `+`, `-`, `1`–`9`, `r` and `n` were exercised that way
  (counts and frames change as expected), and so were Right/Left (`>`/`<`),
  C and R (`tests/test_cycle.sh`). Space and Esc are only reachable from the
  window; Right/Left arrive there as SDL keycodes 0x4000004F/0x40000050,
  which were not pressed for real.
- Presets in the window: run with `timeout` for 8–9 s with `--interval 3`
  and `--interval 4`. Read back through `niri msg windows`, the title went
  from "ChiralBand (18/31) | next in 1 s" to "Bipartite (8/31) | next in
  3 s", and the switch log showed timer switches 3.0 s apart. Two launches
  without `--seed` started on different presets (Snake, PrimeHop). The
  machine was loaded by another session at the time (40–49 fps instead of
  120). I did not look at the window contents. The visual check is
  `docs/presets.png`, made with the same renderer.

## Not done / limitations

- pl-box's 13 spawn patterns (pie, rings, spirals, soft clusters, ...) are
  not ported. Every switch scatters uniformly. pl-box notes that this
  leaves its directional presets as "diffuse dust", and that is what about
  a third of the presets look like here (see above).
- Not ported from pl-box's preset handling: `PresetConfig::jittered` (±18%
  physics variation per instance), the per-preset playback speed
  (sub-steps per frame, here always `--steps-per-frame`), the curated type
  count per preset (K stays as chosen), and the curated palette. No brush,
  no mutation drift, wrap boundary only.
- Random and Symmetric use this program's splitmix64 RNG, not pl-box's
  `fastrand`, so their matrices (and every preset's random radii) are not
  the same numbers as pl-box's, only the same distributions.
- Switching re-scatters on one thread (~4 ms at 200 000 particles).
- The world is the window size, drawn 1:1. There is no zoom/pan and the
  window does not resize.
- `+`/`-` and `1`–`9` respawn all particles rather than adding or removing
  some.
- No Newton's-third-law pair sharing: each pair is evaluated from both
  sides (like pl-box), which doubles the arithmetic but avoids write
  conflicts.
- AVX-512 always keeps the Newton step on `rsqrt14`. Dropping it (14-bit
  1/d) would cut more register pressure but was left out for accuracy.
- Up to 16 types (one zmm table row). Keys only reach 9.
- Binning is serial when running single-threaded (~7% of the step).
- Linux x86-64 only (SysV ABI, glibc, PIE).
