/* Compares the asm core (src/sim.S) against the C reference (ref/ref.c).
 *
 * For each configuration: same seed -> rules and initial state must be
 * bit-identical; then after every step the asm positions are compared by
 * particle id with the C grid step and with the O(N^2) brute-force step
 * (toroidal distance), and must agree within TOL pixels.
 */
#include "../ref/pl_state.h"
#include "../ref/ref.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TOL 1e-3f

static float tor(float a, float b, float e)
{
    float d = fabsf(a - b);
    return fminf(d, e - d);
}

/* max position error of asm vs ref, matched by particle id */
static float compare(const ref_sim *r)
{
    static float *ax, *ay;
    ax = realloc(ax, pl.n * sizeof(float));
    ay = realloc(ay, pl.n * sizeof(float));
    for (uint32_t i = 0; i < pl.n; i++) {
        ax[pl.id[i]] = pl.x[i];
        ay[pl.id[i]] = pl.y[i];
    }
    float m = 0.0f;
    for (int i = 0; i < r->n; i++) {
        int id = r->id[i];
        m = fmaxf(m, tor(ax[id], r->x[i], r->w));
        m = fmaxf(m, tor(ay[id], r->y[i], r->h));
    }
    return m;
}

/* pl-box defaults: dt 1/60, friction 0.4, force scale 0.3, core 0.6 */
static float g_dt = 1.0f / 60.0f, g_fscale = 0.3f;
static int g_cdiv = 1;

static int run(int n, int k, float w, float h, uint64_t seed, int simd, int threads, int steps, int brute)
{
    static int threads_started;
    pl.k = k; pl.w = w; pl.h = h;
    pl.dt = g_dt; pl.fric = 0.4f; pl.fscale = g_fscale; pl.core = 0.6f;
    pl.simd = simd;
    pl.cdiv = g_cdiv;
    pl.rng = seed;
    if (threads > 1 && !threads_started) {
        if (pl_threads_start(threads)) { puts("thread start failed"); return 1; }
        threads_started = threads;
    }
    pl.nthreads = threads > 1 ? (uint32_t)threads_started : 1;
    if (pl_alloc(n)) { puts("alloc failed"); return 1; }
    pl_random_rules();
    pl_random_particles();

    ref_sim r, rb;
    ref_init(&r, n, k, w, h, seed, g_cdiv);
    ref_set_params(&r, g_dt, 0.4f, g_fscale, 0.6f);
    if (brute) {
        ref_init(&rb, n, k, w, h, seed, g_cdiv);
        ref_set_params(&rb, g_dt, 0.4f, g_fscale, 0.6f);
    }

    int fail = 0;
    for (int i = 0; i < k; i++)
        for (int j = 0; j < k; j++)
            if (pl.attr[i * 16 + j] != r.attr[i][j] || pl.minr[i * 16 + j] != r.minr[i][j] ||
                pl.maxr_t[i * 16 + j] != r.maxr[i][j] || pl.tb0[i * 16 + j] != r.b0[i][j] ||
                pl.tc1[i * 16 + j] != r.c1[i][j])
                fail = 1;
    for (uint32_t i = 0; i < pl.n; i++)
        if (pl.x[i] != r.x[i] || pl.y[i] != r.y[i]) fail = 1;
    if (pl.cols != (uint32_t)r.cols || pl.rows != (uint32_t)r.rows) fail = 1;
    float e0 = compare(&r);
    for (uint32_t c = 0; c <= pl.ncells; c++)
        if (pl.cstart[c] != (uint32_t)r.cstart[c]) fail = 1;
    for (int i = 0; i < n; i++)
        if (pl.id[i] != r.id[i] || pl.t[i] != r.t[i]) fail = 1;
    const char *sname = simd == 2 ? "avx512" : (k <= 8 ? "avx2-k8" : "avx2-k16");
    printf("N=%-6d K=%-2d world=%4.0fx%-4.0f fscale=%.1f dt=%.3f %-8s threads=%-2d R=%u grid=%ux%u  init %s\n",
           n, k, w, h, g_fscale, g_dt, sname, pl.nthreads, pl.cdiv, pl.cols, pl.rows,
           fail ? "MISMATCH" : "bit-identical");
    if (fail || e0 != 0.0f) return 1;

    float eg = 0, eb = 0;
    for (int s = 1; s <= steps; s++) {
        pl_step();
        ref_step(&r);
        float g = compare(&r);
        eg = fmaxf(eg, g);
        if (brute) {
            ref_step_brute(&rb);
            eb = fmaxf(eb, compare(&rb));
        }
        if (g > TOL || eb > TOL) {
            printf("  step %d: asm vs C grid %.3g px, vs brute %.3g px  FAIL\n", s, g, eb);
            return 1;
        }
    }
    /* how far did particles actually move? (so a tolerance pass means something) */
    float mv = 0.0f;
    for (uint32_t i = 0; i < pl.n; i++) mv = fmaxf(mv, hypotf(pl.vx[i], pl.vy[i]));
    printf("  %d steps: max |asm - C grid| = %.2e px", steps, eg);
    if (brute) printf(", max |asm - brute| = %.2e px", eb);
    printf(", max speed %.3f px/step  OK\n", mv * pl.dt);
    return 0;
}

int main(void)
{
    int feat = pl_cpu_features();
    if (!(feat & 1)) { puts("AVX2/FMA not available"); return 1; }
    int fails = 0;
    for (g_cdiv = 1; g_cdiv <= 2; g_cdiv++) {
    printf("--- cell size = max radius / %d\n", g_cdiv);
    /* K<=8 AVX2 path, K>8 AVX2 path, AVX-512 path; brute force on the small cases */
    fails += run(2000, 6, 800, 600, 1, 1, 1, 60, 1);
    fails += run(2000, 12, 800, 600, 2, 1, 1, 60, 1);
    fails += run(1500, 3, 300, 256, 3, 1, 1, 60, 1);       /* tiny 3x3-ish grid, wrap everywhere */
    if (feat & 2) {
        fails += run(2000, 6, 800, 600, 1, 2, 1, 60, 1);
        fails += run(2000, 16, 800, 600, 4, 2, 1, 60, 1);
    } else {
        puts("(AVX-512 not available, skipped)");
    }
    /* strong forces: particles move several px per step, cross cell and wrap edges */
    g_dt = 1.0f / 20.0f; g_fscale = 3.0f;
    fails += run(2000, 5, 600, 400, 7, 1, 1, 20, 1);
    fails += run(2000, 11, 600, 400, 8, 1, 1, 20, 1);
    if (feat & 2) fails += run(2000, 11, 600, 400, 8, 2, 1, 20, 1);
    g_dt = 1.0f / 60.0f; g_fscale = 0.3f;
    /* very dense: ~1000 particles per cell, neighbour ranges far longer than
       256 (regression test for a lane-mask bug with long ranges) */
    fails += run(12000, 4, 256, 256, 9, 1, 1, 3, 1);
    if (feat & 2) fails += run(12000, 4, 256, 256, 9, 2, 1, 3, 1);
    fails += run(30000, 9, 1920, 1080, 5, 1, 1, 30, 0);
    if (feat & 2) fails += run(30000, 9, 1920, 1080, 5, 2, 1, 30, 0);
    fails += run(30000, 9, 1920, 1080, 5, 1, 8, 30, 0);     /* multi-threaded */
    }
    puts(fails ? "FAILED" : "ALL TESTS PASSED");
    return fails != 0;
}
