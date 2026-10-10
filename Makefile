AS_FLAGS  = -g
CC        = gcc
CFLAGS    = -O3 -march=native -Wall -Wextra -g
BUILD     = build

CORE_OBJ  = $(BUILD)/sim.o $(BUILD)/threads.o
APP_OBJ   = $(BUILD)/main.o $(BUILD)/render.o $(CORE_OBJ)

ARGS     ?=
BENCH_STEPS ?= 200
BENCH_WARMUP ?= 100

.PHONY: all run bench bench-ref bench-all test clean

all: $(BUILD)/particle_life $(BUILD)/ref_bench

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/%.o: src/%.S src/layout.inc | $(BUILD)
	$(CC) -c $(AS_FLAGS) -Isrc -o $@ $<

$(BUILD)/particle_life: $(APP_OBJ)
	$(CC) -o $@ $^ -lSDL2 -lpthread

$(BUILD)/ref.o: ref/ref.c ref/ref.h | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/ref_bench: ref/ref_bench.c $(BUILD)/ref.o
	$(CC) $(CFLAGS) -o $@ $^ -lm

$(BUILD)/test_step: tests/test_step.c $(BUILD)/ref.o $(CORE_OBJ) ref/pl_state.h
	$(CC) $(CFLAGS) -o $@ tests/test_step.c $(BUILD)/ref.o $(CORE_OBJ) -lm -lpthread

run: $(BUILD)/particle_life
	./$(BUILD)/particle_life $(ARGS)

test: $(BUILD)/test_step
	./$(BUILD)/test_step

# Headless benchmark at constant density (10k particles per 1920x1080):
# the world grows with N so every run sees the same neighbourhood sizes.
BENCH_SIZES = 10000:1920:1080 50000:4293:2415 200000:8587:4830
bench: $(BUILD)/particle_life
	@for s in $(BENCH_SIZES); do \
	  set -- $$(echo $$s | tr : ' '); \
	  ./$(BUILD)/particle_life --bench $(BENCH_STEPS) --warmup $(BENCH_WARMUP) \
	    --particles $$1 --width $$2 --height $$3 --types 6 --seed 1 $(ARGS); \
	done

bench-ref: $(BUILD)/ref_bench
	@for s in $(BENCH_SIZES); do \
	  set -- $$(echo $$s | tr : ' '); \
	  ./$(BUILD)/ref_bench --bench $(BENCH_STEPS) --warmup $(BENCH_WARMUP) \
	    --particles $$1 --width $$2 --height $$3 --types 6 --seed 1; \
	done

clean:
	rm -rf $(BUILD)
