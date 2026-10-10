AS_FLAGS  = -g
CC        = gcc
CFLAGS    = -O3 -march=native -Wall -Wextra -g
BUILD     = build

CORE_OBJ  = $(BUILD)/sim.o $(BUILD)/threads.o $(BUILD)/presets.o $(BUILD)/spawn.o
APP_OBJ   = $(BUILD)/main.o $(BUILD)/render.o $(CORE_OBJ)

ARGS     ?=
BENCH_STEPS ?= 200
BENCH_WARMUP ?= 100
THREADS  ?= 8

.PHONY: all run bench bench-ref bench-ref-clang test clean

all: $(BUILD)/particle_life $(BUILD)/ref_bench

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/%.o: src/%.S src/layout.inc | $(BUILD)
	$(CC) -c $(AS_FLAGS) -Isrc -o $@ $<

$(BUILD)/particle_life: $(APP_OBJ)
	$(CC) -o $@ $^ -lSDL2 -lpthread -lm

$(BUILD)/ref.o: ref/ref.c ref/ref.h | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/ref_bench: ref/ref_bench.c $(BUILD)/ref.o
	$(CC) $(CFLAGS) -o $@ $^ -lm

# the same C reference, auto-vectorised by clang (needs -ffast-math to
# reassociate the force sums)
$(BUILD)/ref_bench_clang: ref/ref_bench.c ref/ref.c ref/ref.h | $(BUILD)
	clang -O3 -ffast-math -march=native -o $@ ref/ref_bench.c ref/ref.c -lm

$(BUILD)/test_step: tests/test_step.c $(BUILD)/ref.o $(CORE_OBJ) ref/pl_state.h
	$(CC) $(CFLAGS) -o $@ tests/test_step.c $(BUILD)/ref.o $(CORE_OBJ) -lm -lpthread

$(BUILD)/test_presets: tests/test_presets.c $(BUILD)/ref.o $(CORE_OBJ) ref/pl_state.h
	$(CC) $(CFLAGS) -o $@ tests/test_presets.c $(BUILD)/ref.o $(CORE_OBJ) -lm -lpthread

$(BUILD)/test_spawns: tests/test_spawns.c $(BUILD)/ref.o $(CORE_OBJ) ref/pl_state.h
	$(CC) $(CFLAGS) -o $@ tests/test_spawns.c $(BUILD)/ref.o $(CORE_OBJ) -lm -lpthread

run: $(BUILD)/particle_life
	./$(BUILD)/particle_life $(ARGS)

test: $(BUILD)/test_step $(BUILD)/test_presets $(BUILD)/test_spawns $(BUILD)/particle_life
	./$(BUILD)/test_step
	./$(BUILD)/test_spawns tests/plbox_spawns.txt
	./$(BUILD)/test_presets tests/plbox_ref.txt
	sh tests/test_cycle.sh ./$(BUILD)/particle_life

# Headless benchmark at constant density (10k particles per 1920x1080):
# the world grows with N so every run sees the same neighbourhood sizes.
# 1 thread, then $(THREADS) threads.
BENCH_SIZES = 10000:1920:1080 50000:4293:2415 200000:8587:4830
BENCH_RUN = for s in $(BENCH_SIZES); do \
	  set -- $$(echo $$s | tr : ' '); \
	  $(1) --bench $(BENCH_STEPS) --warmup $(BENCH_WARMUP) \
	    --particles $$1 --width $$2 --height $$3 --types 6 --seed 1 $(2); \
	done

bench: $(BUILD)/particle_life
	@$(call BENCH_RUN,./$(BUILD)/particle_life,--threads 1 $(ARGS))
	@$(call BENCH_RUN,./$(BUILD)/particle_life,--threads $(THREADS) $(ARGS))

bench-ref: $(BUILD)/ref_bench
	@$(call BENCH_RUN,./$(BUILD)/ref_bench,)

bench-ref-clang: $(BUILD)/ref_bench_clang
	@$(call BENCH_RUN,./$(BUILD)/ref_bench_clang,)

clean:
	rm -rf $(BUILD)
