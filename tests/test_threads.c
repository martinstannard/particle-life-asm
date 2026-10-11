/* Multi-thread stress test: T worker threads (argv[1], default 4) must give
 * bit for bit the same simulation as one thread.
 *
 * The force pass hands cells out dynamically and the bin pass runs as four
 * phases separated by a spinning barrier (src/threads.S, src/sim.S). Every
 * particle's force sum and the counting sort are independent of which
 * thread does the work, so any difference between the two runs means a
 * thread read data that another had not finished or published: a missing
 * barrier, or on AArch64 a missing acquire/release.
 *
 * For each case the single-threaded run records a 64-bit FNV-1a hash of the
 * whole particle state (x, y, vx, vy, type, id and the cell starts) after
 * every step; the threaded run from the same seed must reproduce every hash.
 * Cases: preset scenes (clustered, very uneven cells), plain random rules,
 * K = 3..16, both grid sizes, and a tiny world with many threads per cell
 * row. Usage: test_threads [T [steps]].
 */
#include "../ref/pl_state.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t fnv(uint64_t h, const void *p, size_t n)
{
    const unsigned char *b = p;
    for (size_t i = 0; i < n; i++) {
        h ^= b[i];
        h *= 0x100000001b3ull;
    }
    return h;
}

static uint64_t state_hash(void)
{
    uint64_t h = 0xcbf29ce484222325ull;
    size_t n = pl.n * sizeof(float);
    h = fnv(h, pl.x, n);
    h = fnv(h, pl.y, n);
    h = fnv(h, pl.vx, n);
    h = fnv(h, pl.vy, n);
    h = fnv(h, pl.t, n);
    h = fnv(h, pl.id, n);
    h = fnv(h, pl.cstart, (pl.ncells + 1) * sizeof(uint32_t));
    return h;
}

struct scase {
    const char *what;
    int n, k, cdiv, entry, spawn; /* entry < 0: random rules, uniform */
    float w, h;
    uint64_t seed;
};

/* the initial state of a case, identical for any thread count */
static int init(const struct scase *c, uint32_t threads)
{
    pl.nthreads = threads;
    pl.k = c->k; pl.w = c->w; pl.h = c->h; pl.cdiv = c->cdiv; pl.simd = 1;
    pl.dt = 1.0f / 60.0f; pl.fric = 0.4f; pl.fscale = 0.3f; pl.core = 0.6f;
    pl.rng = c->seed;
    if (pl_alloc(c->n)) return 1;
    if (c->entry < 0) {
        pl_random_rules();
        pl_random_particles();
    } else {
        pl_entry_install(c->entry, c->k);
        pl_spawn(c->spawn);
    }
    return 0;
}

int main(int argc, char **argv)
{
    int threads = argc > 1 ? atoi(argv[1]) : 4;
    int steps = argc > 2 ? atoi(argv[2]) : 300;
    if (threads < 2) threads = 2;
    if (pl_threads_start(threads)) { puts("thread start failed"); return 1; }
    const struct scase cases[] = {
        { "SkippedPursuit, soft_clusters", 20000, 7, 2, 0, 5, 1600, 900, 11 },
        { "RotatingConveyor, blocks", 20000, 13, 2, 17 + 18, 10, 1600, 900, 12 },
        { "random rules, uniform", 30000, 16, 1, -1, 0, 1920, 1080, 13 },
        { "Shells, spiral_arms, dense", 12000, 7, 2, 3, 9, 640, 480, 14 },
        { "random rules, tiny world", 3000, 3, 2, -1, 0, 300, 256, 15 },
    };
    const int ncases = sizeof cases / sizeof cases[0];
    uint64_t *want = malloc(steps * sizeof *want);
    int fails = 0;
    printf("%d threads vs 1 thread, %d steps per case, state hash after every step\n", threads, steps);
    for (int ci = 0; ci < ncases; ci++) {
        const struct scase *c = &cases[ci];
        if (init(c, 1)) { puts("alloc failed"); return 1; }
        uint64_t h0 = state_hash();
        for (int s = 0; s < steps; s++) {
            pl_step();
            want[s] = state_hash();
        }
        if (init(c, (uint32_t)threads)) { puts("alloc failed"); return 1; }
        int first_bad = -1;
        if (state_hash() != h0) first_bad = 0;
        for (int s = 0; s < steps && first_bad < 0; s++) {
            pl_step();
            if (state_hash() != want[s]) first_bad = s + 1;
        }
        printf("  %-32s N=%-5d K=%-2d R=%d grid %3ux%-3u  %s", c->what, c->n, c->k, pl.cdiv,
               pl.cols, pl.rows, first_bad < 0 ? "bit-identical" : "DIFFERS");
        if (first_bad >= 0) printf(" from step %d", first_bad);
        printf("\n");
        fails += first_bad >= 0;
    }
    free(want);
    puts(fails ? "THREAD TESTS FAILED" : "ALL THREAD TESTS PASSED");
    return fails != 0;
}
