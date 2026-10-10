# Particle Life in x86-64 assembly (new project)

You are building a NEW project in this directory (`~/code/particle_life_asm`, already `git init`ed). Nothing here is a work repo: no Linear, no PRs, no Slack/Discord/WhatsApp posts, no AI attribution lines in commits (no "Generated with Claude Code", no Co-Authored-By). Never print or paste secrets.

## Goal
Martin wants a Particle Life simulation written in assembler for maximum speed, like the ones in `~/code` (read these first, do not modify them):
- `~/code/biome` (p5.js, `sketch.js`, `SimulationState.js`, `Quadtree.js`)
- `~/code/pl-box` (Rust, `crates/pl-core/src/{rules,simulation,flow}.rs`, spatial hashing, rule presets)
- `~/code/culture` (Rust + wgpu)
- `~/code/projects.html` describes them.
The model: N particles of K types (colours). `attraction[i][j]` in [-1,1]; below a min radius particles repel hard; between min and max radius the force follows the usual triangular profile scaled by attraction; beyond max radius no interaction; velocity friction each step; wrap-around (toroidal) world. Match the force law and parameter ranges used in pl-box `rules.rs`/`simulation.rs` so the behaviour is recognisable.

## Requirements
1. **The simulation core is hand-written x86-64 assembly** (GNU `as`, AT&T or Intel syntax with `.intel_syntax noprefix`; `nasm`/`yasm` are NOT installed, `gcc`, `as`, `ld` are). Structure-of-arrays float32 layout, AVX2 required (the machine also has AVX-512F: use it behind a runtime CPUID check only if it is clearly faster, keep an AVX2 path).
2. Use a **uniform spatial grid / cell list** (cell size = max radius) so the step is O(N), not O(N^2). Sort or bin particles by cell each step. Multi-threading is optional and last: first make one thread fast, then consider splitting cells across pthreads (16 cores here).
3. **Display via SDL2** called from assembly through the C ABI (libSDL2 2.32 is installed, headers in `/usr/include/SDL2`). Keep the C/asm boundary thin: window, event loop, texture/pixel upload, FPS in the title. A tiny C `main` is NOT allowed for the hot path, but a minimal `_start`/`main` in asm calling SDL is fine. Rendering particles into a software pixel buffer in asm (additive/solid dots, colour per type) is preferred to per-particle SDL draw calls.
4. Keys: Space pause, R re-randomise the rules, N new particle positions, +/- change particle count, 1-9 switch type count, Esc quit. Command line: `--particles N --types K --seed S --width W --height H`.
5. A `Makefile` (`make`, `make run`, `make bench`). `make bench` runs headless (no window) for a fixed number of steps and prints particles, steps/sec and ns per particle-step.
6. **Correctness**: also write a small plain-C or Python reference implementation (`ref/`) of the same step with the same seed/initial state, and a test (`make test`) that runs both for a few steps and checks the asm positions agree within a float tolerance. Do not claim it works without running this test and showing the output.
7. **Speed evidence**: report measured steps/sec for 10k, 50k and 200k particles with 1 thread (and with threads if you add them), compared with the C reference compiled `-O3 -march=native`. Report honestly if the asm is not faster.
8. `README.md`: how to build/run, the memory layout, the algorithm, the measured numbers, and what is not done.

## Working rules
- Work in this directory only. Commit in small steps with plain conventional messages (`feat: ...`, `test: ...`). Do not push anywhere, do not create a remote.
- If the display cannot be tested (Wayland session; SDL2 may fall back to XWayland), test headless via `make bench` and `make test`, and say that the window was or was not actually run. You may run the window for a few seconds with `timeout 10` and report what happened, but do not claim visual correctness you did not observe. Save a PPM/PNG frame dump from the pixel buffer (`--dump-frame out.ppm`) so correctness can be inspected without a display.
- Check `free -g` before heavy steps; the host is tight on RAM. No sudo, no package installs.
- Report to the conductor (the session that launched you) when done.

## Final step — assert completion
When the task is fully done, print exactly this as the last line of your final message:
  ===AGENTDECK_DONE=== status=ok summary=<what you built and the measured steps/sec, one line>
Use status=fail if you could not complete it; put the blocker in the summary.
