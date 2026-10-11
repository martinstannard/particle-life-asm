# x86-64 build (src/*.S) in build/, AArch64 / NEON build (src/arm64/*.S) in
# build-arm64/. ARCH defaults to the host: `make` on the Raspberry Pi builds
# the AArch64 version; on x86 `make ARCH=aarch64` cross-builds it with
# aarch64-linux-gnu-gcc and runs the tests under qemu-aarch64 (static
# binaries; no SDL2 for AArch64 on the host, so the window is stubbed out
# there). `make check-arm64` only needs clang: it assembles every AArch64
# file and checks that nothing but libc / libm / pthread / SDL2 is left
# undefined.
HOST     := $(shell uname -m)
ARCH     ?= $(HOST)
ifeq ($(ARCH),arm64)
override ARCH := aarch64
endif

ARGS     ?=
BENCH_STEPS ?= 200
BENCH_WARMUP ?= 100

ifeq ($(ARCH),aarch64)
BUILD     = build-arm64
SRC       = src/arm64
# kernel variants (README, "ARM64"): NEWTON=1 one Newton step for 1/d
# (faster, ~16 bits), KPIPE=0 the plain loop instead of the two-stage
# software pipeline
NEWTON   ?= 2
KPIPE    ?= 1
AS_FLAGS  = -g -DNEWTON=$(NEWTON) -DKPIPE=$(KPIPE)
CFLAGS    = -O3 -mcpu=cortex-a72 -Wall -Wextra -g
THREADS  ?= 4
ifeq ($(HOST),aarch64)
CC        = gcc
RUN       =
LDFLAGS   =
SDL_LIBS  = -lSDL2
else
CC        = aarch64-linux-gnu-gcc
RUN       = qemu-aarch64
LDFLAGS   = -static
SDL_LIBS  = $(BUILD)/sdl_stub.o
endif
else
BUILD     = build
SRC       = src
AS_FLAGS  = -g
CC        = gcc
CFLAGS    = -O3 -march=native -Wall -Wextra -g
THREADS  ?= 8
RUN       =
LDFLAGS   =
SDL_LIBS  = -lSDL2
endif

CORE_OBJ  = $(BUILD)/sim.o $(BUILD)/threads.o $(BUILD)/presets.o $(BUILD)/spawn.o $(BUILD)/palettes.o $(BUILD)/palettes_data.o
APP_OBJ   = $(BUILD)/main.o $(BUILD)/render.o $(BUILD)/font.o $(CORE_OBJ)
TESTS     = test_step test_presets test_spawns test_overlay test_threads

# the architecture's sources first, then the shared data files (font,
# palettes) in src/
vpath %.S $(SRC) src

.PHONY: all run run-panel bench bench-panel bench-ref bench-ref-clang test clean check-arm64

all: $(BUILD)/particle_life $(BUILD)/ref_bench

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/%.o: %.S src/layout.inc $(wildcard $(SRC)/*.inc) | $(BUILD)
	$(CC) -c $(AS_FLAGS) -I$(SRC) -Isrc -o $@ $<

$(BUILD)/sdl_stub.o: tests/sdl_stub.c | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/particle_life: $(APP_OBJ) $(filter %.o,$(SDL_LIBS))
	$(CC) $(LDFLAGS) -o $@ $(APP_OBJ) $(SDL_LIBS) -lpthread -lm

$(BUILD)/ref.o: ref/ref.c ref/ref.h | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/ref_bench: ref/ref_bench.c $(BUILD)/ref.o
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^ -lm

# the same C reference, auto-vectorised by clang (needs -ffast-math to
# reassociate the force sums)
$(BUILD)/ref_bench_clang: ref/ref_bench.c ref/ref.c ref/ref.h | $(BUILD)
	clang -O3 -ffast-math -march=native -o $@ ref/ref_bench.c ref/ref.c -lm

$(BUILD)/test_step: tests/test_step.c $(BUILD)/ref.o $(CORE_OBJ) ref/pl_state.h
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ tests/test_step.c $(BUILD)/ref.o $(CORE_OBJ) -lm -lpthread

$(BUILD)/test_presets: tests/test_presets.c $(BUILD)/ref.o $(CORE_OBJ) ref/pl_state.h
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ tests/test_presets.c $(BUILD)/ref.o $(CORE_OBJ) -lm -lpthread

$(BUILD)/test_spawns: tests/test_spawns.c $(BUILD)/ref.o $(CORE_OBJ) ref/pl_state.h
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ tests/test_spawns.c $(BUILD)/ref.o $(CORE_OBJ) -lm -lpthread

$(BUILD)/test_overlay: tests/test_overlay.c $(BUILD)/render.o $(BUILD)/font.o $(CORE_OBJ) ref/pl_state.h
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ tests/test_overlay.c $(BUILD)/render.o $(BUILD)/font.o $(CORE_OBJ) -lm -lpthread

$(BUILD)/test_threads: tests/test_threads.c $(CORE_OBJ) ref/pl_state.h
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ tests/test_threads.c $(CORE_OBJ) -lm -lpthread

run: $(BUILD)/particle_life
	./$(BUILD)/particle_life $(ARGS)

# the Pi's portrait panel (Waveshare 5.5" AMOLED, 1080x1920), fullscreen
run-panel: $(BUILD)/particle_life
	./$(BUILD)/particle_life --width 1080 --height 1920 --fullscreen $(ARGS)

test: $(addprefix $(BUILD)/,$(TESTS)) $(BUILD)/particle_life
	$(RUN) ./$(BUILD)/test_step
	$(RUN) ./$(BUILD)/test_spawns tests/plbox_spawns.txt
	$(RUN) ./$(BUILD)/test_overlay
	$(RUN) ./$(BUILD)/test_presets tests/plbox_ref.txt
	$(RUN) ./$(BUILD)/test_threads $(THREADS)
	sh tests/test_cycle.sh "$(RUN) ./$(BUILD)/particle_life"

# Headless benchmark at constant density (10k particles per 1920x1080):
# the world grows with N so every run sees the same neighbourhood sizes.
# 1 thread, then $(THREADS) threads. On AArch64 also the panel pass.
BENCH_SIZES = 10000:1920:1080 50000:4293:2415 200000:8587:4830
# the Pi panel, 1080x1920: the same density (10k), then 2x and 4x denser
PANEL_SIZES = 10000:1080:1920 20000:1080:1920 40000:1080:1920
BENCH_RUN = for s in $(2); do \
	  set -- $$(echo $$s | tr : ' '); \
	  $(1) --bench $(BENCH_STEPS) --warmup $(BENCH_WARMUP) \
	    --particles $$1 --width $$2 --height $$3 --types 6 --seed 1 $(3); \
	done

bench: $(BUILD)/particle_life
	@$(call BENCH_RUN,./$(BUILD)/particle_life,$(BENCH_SIZES),--threads 1 $(ARGS))
	@$(call BENCH_RUN,./$(BUILD)/particle_life,$(BENCH_SIZES),--threads $(THREADS) $(ARGS))
ifeq ($(ARCH),aarch64)
	@$(MAKE) --no-print-directory bench-panel
endif

bench-panel: $(BUILD)/particle_life
	@$(call BENCH_RUN,./$(BUILD)/particle_life,$(PANEL_SIZES),--threads 1 $(ARGS))
	@$(call BENCH_RUN,./$(BUILD)/particle_life,$(PANEL_SIZES),--threads $(THREADS) $(ARGS))
	@./$(BUILD)/particle_life --bench-render 100 --particles 20000 --width 1080 --height 1920 --seed 1

bench-ref: $(BUILD)/ref_bench
	@$(call BENCH_RUN,./$(BUILD)/ref_bench,$(BENCH_SIZES),)

bench-ref-clang: $(BUILD)/ref_bench_clang
	@$(call BENCH_RUN,./$(BUILD)/ref_bench_clang,$(BENCH_SIZES),)

# AArch64 syntax and symbol check with clang only (no cross toolchain, no
# emulator): assemble every file of the AArch64 build in all kernel
# variants, link them into one relocatable object and list what is left
# undefined, which must be libc / libm / pthread / SDL2 only.
ARM_CHECK = /tmp/pl-arm64-check
check-arm64:
	@rm -rf $(ARM_CHECK) && mkdir -p $(ARM_CHECK)
	@for v in "2 1" "1 1" "2 0" "1 0"; do set -- $$v; \
	  for f in src/arm64/*.S src/font.S src/palettes_data.S; do \
	    clang --target=aarch64-linux-gnu -c -DNEWTON=$$1 -DKPIPE=$$2 -Isrc/arm64 -Isrc \
	      -o $(ARM_CHECK)/$$(basename $$f .S).o $$f || exit 1; \
	  done; \
	  echo "assembled $$(ls src/arm64/*.S | wc -l) AArch64 files + 2 shared data files (NEWTON=$$1 KPIPE=$$2)"; \
	done
	@for f in src/arm64/*.S; do \
	  d=$$(cat src/layout.inc src/arm64/macros.inc $$f | grep -oE '^[[:space:]]*\.set[[:space:]]+[A-Za-z_0-9]+' | \
	    awk '{print $$2}' | sort | uniq -d); \
	  if [ -n "$$d" ]; then echo "$$f: .set redefined (gas keeps the last value silently): $$d"; exit 1; fi; \
	done; echo "no .set name defined twice in a file"
	@ld.lld -m aarch64linux -r -o $(ARM_CHECK)/all.o $(ARM_CHECK)/[a-z]*.o
	@undef=$$(llvm-nm -u $(ARM_CHECK)/all.o | awk '{print $$2}' | \
	  grep -vE '^(SDL_[A-Za-z]+|abort|atan2f|calloc|clock_gettime|cosf|exit|expf|fclose|fflush|fmodf|fopen|fprintf|fputs|free|fwrite|getauxval|malloc|memset|powf|printf|pthread_[a-z_]+|roundf|sched_yield|sinf|snprintf|sprintf|stderr|strcasecmp|strcmp|strcpy|strtod|strtoull|sysconf)$$'); \
	  if [ -n "$$undef" ]; then echo "unexpected undefined symbols: $$undef"; exit 1; fi; \
	  echo "linked: only libc / libm / pthread / SDL2 symbols left undefined"

clean:
	rm -rf $(BUILD)
