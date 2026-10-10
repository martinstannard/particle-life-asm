/* Tests for the rule presets (src/presets.S):
 *
 *  1. every preset's raw attraction matrix equals pl-box's own output bit for
 *     bit, for K = 1..16 (tests/plbox_ref.txt, printed by tools/plbox_dump from
 *     pl-box's RuleMatrix::from_preset); Random and Symmetric draw random
 *     numbers and are only range-checked;
 *  2. every preset installed for every K: K x K attraction in [-1, 1], zero
 *     outside, 0 < minr < maxr within the preset's ranges, physics copied, and
 *     all derived tables, the max radius and the grid equal what the C
 *     reference derives from the same rules;
 *  3. shuffle bag: no preset twice in a row, none twice within a round;
 *  4. after a switch, the asm and the C reference loaded with the NEW rules
 *     from the same state agree step by step (and a reference holding the
 *     OLD rules does not, so a stale matrix would be caught);
 *  5. A -> B -> A with the same seed reproduces A's steps bit for bit.
 */
#include "../ref/pl_state.h"
#include "../ref/ref.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TOL 1e-3f

static int feat;

static float tor(float a, float b, float e)
{
    float d = fabsf(a - b);
    return fminf(d, e - d);
}

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

/* particles off by more than TOL (pl-box's force jumps at d = minr, so one
   float ulp in d can kick a single pair onto the other side; that particle
   then drifts away linearly while all others still agree) */
static int outliers(const ref_sim *r)
{
    static float *ax, *ay;
    ax = realloc(ax, pl.n * sizeof(float));
    ay = realloc(ay, pl.n * sizeof(float));
    for (uint32_t i = 0; i < pl.n; i++) {
        ax[pl.id[i]] = pl.x[i];
        ay[pl.id[i]] = pl.y[i];
    }
    int c = 0;
    for (int i = 0; i < r->n; i++) {
        int id = r->id[i];
        c += tor(ax[id], r->x[i], r->w) > TOL || tor(ay[id], r->y[i], r->h) > TOL;
    }
    return c;
}

static void setup(int k, float w, float h, int cdiv, int simd, int threads)
{
    static int started;
    if (threads > 1 && !started) {
        if (pl_threads_start(threads)) { puts("thread start failed"); exit(1); }
        started = threads;
    }
    pl.nthreads = threads > 1 ? (uint32_t)started : 1;
    pl.k = k; pl.w = w; pl.h = h; pl.cdiv = cdiv; pl.simd = simd;
    pl.dt = 1.0f / 60.0f;
}

/* ------------------------------------------------------------ 1. pl-box */
static int test_plbox_ref(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) { printf("cannot open %s\n", path); return 1; }
    int fails = 0, checked[PL_NPRESETS] = {0}, bad[PL_NPRESETS] = {0}, cells[PL_NPRESETS] = {0};
    char line[8192];
    float out[256];
    while (fgets(line, sizeof line, f)) {
        int idx, k, off;
        char name[64];
        if (sscanf(line, "%d %63s %d%n", &idx, name, &k, &off) != 3) continue;
        if (idx < 0 || idx >= PL_NPRESETS || strcmp(name, pl_preset_names[idx])) {
            printf("  preset %d is '%s' in pl-box but '%s' here\n", idx, name,
                   idx >= 0 && idx < PL_NPRESETS ? pl_preset_names[idx] : "?");
            fails++;
            continue;
        }
        if (idx < 2) continue; /* Random, Symmetric: random draws */
        pl.rng = 1;
        pl_preset_attraction(idx, k, out);
        char *p = line + off;
        for (int i = 0; i < k; i++)
            for (int j = 0; j < k; j++) {
                unsigned bits = (unsigned)strtoul(p, &p, 16);
                float want;
                memcpy(&want, &bits, 4);
                unsigned got;
                memcpy(&got, &out[i * 16 + j], 4);
                if (got != bits) {
                    if (!bad[idx])
                        printf("  %s K=%d [%d][%d]: asm %.9g, pl-box %.9g\n", name, k, i, j,
                               out[i * 16 + j], want);
                    bad[idx]++;
                }
                cells[idx]++;
            }
        checked[idx]++;
    }
    fclose(f);
    int nmatch = 0;
    for (int p = 2; p < PL_NPRESETS; p++) {
        if (checked[p] != 16 || bad[p]) fails++;
        else nmatch++;
        printf("  %-13s K=1..16: %2d matrices, %4d values, %s\n", pl_preset_names[p], checked[p],
               cells[p], bad[p] ? "MISMATCH" : (checked[p] == 16 ? "bit-identical to pl-box" : "MISSING"));
    }
    printf("  %d of 29 deterministic presets bit-identical to pl-box (Random, Symmetric are random)\n",
           nmatch);
    return fails;
}

/* ------------------------------------------------------------ 2. ranges */
static int test_ranges(void)
{
    int fails = 0;
    for (int p = 0; p < PL_NPRESETS; p++) {
        float lo = 1e9f, hi = -1e9f;
        int bad = 0;
        const float *ph = pl_preset_phys[p];
        for (int k = 1; k <= 16; k++) {
            setup(k, 1000.0f + 37.0f * k, 700.0f, 1 + (k & 1), 2 - !(feat & 2), 1);
            pl.rng = 100 + p * 16 + k;
            pl_preset_rules(p);
            if (pl_preset_cur != p) bad++;
            if (pl.fscale != ph[0] || pl.fric != ph[1] || pl.core != ph[2]) bad++;
            float gmax = 0.0f;
            for (int i = 0; i < 16; i++)
                for (int j = 0; j < 16; j++) {
                    float a = pl.attr[i * 16 + j], mn = pl.minr[i * 16 + j], mx = pl.maxr_t[i * 16 + j];
                    if (i >= k || j >= k) {
                        if (a != 0.0f || mn != 0.0f || mx != 0.0f) bad++;
                        continue;
                    }
                    if (!(a >= -1.0f && a <= 1.0f)) bad++;
                    if (!(mn > 0.0f && mn < mx && mn >= ph[3] && mn < ph[4])) bad++;
                    if (!(mx >= ph[5] && mx <= ph[6])) bad++;
                    lo = fminf(lo, a);
                    hi = fmaxf(hi, a);
                    gmax = fmaxf(gmax, mx);
                }
            /* derived tables and grid must equal the C reference's for these rules */
            ref_sim r;
            ref_load(&r, 0, k, pl.w, pl.h, pl.cdiv, pl.dt, pl.fric, pl.fscale, pl.core,
                     pl.attr, pl.minr, pl.maxr_t, NULL, NULL, NULL, NULL, NULL, NULL);
            if (pl.maxr != gmax || pl.maxr != r.gmaxr || pl.cols != (uint32_t)r.cols ||
                pl.rows != (uint32_t)r.rows || pl.ncells != (uint32_t)r.ncells || pl.cw != r.cw ||
                pl.cores != r.cores || pl.damp != r.damp)
                bad++;
            for (int i = 0; i < k; i++)
                for (int j = 0; j < k; j++)
                    if (pl.tb0[i * 16 + j] != r.b0[i][j] || pl.tir[i * 16 + j] != r.ir[i][j] ||
                        pl.tc1[i * 16 + j] != r.c1[i][j] || pl.tas[i * 16 + j] != r.as[i][j])
                        bad++;
        }
        printf("  %-13s force %.2f fric %.2f core %.2f minr [%2.0f,%2.0f) maxr [%2.0f,%2.0f)  attraction in [%+.3f, %+.3f]  %s\n",
               pl_preset_names[p], ph[0], ph[1], ph[2], ph[3], ph[4], ph[5], ph[6], lo, hi,
               bad ? "FAIL" : "OK");
        fails += bad != 0;
    }
    return fails;
}

/* ------------------------------------------------------------ 3. shuffle bag */
static int test_bag(void)
{
    setup(5, 400, 300, 2, 2 - !(feat & 2), 1);
    pl.rng = 77;
    if (pl_alloc(200)) return 1;
    pl_preset_cur = -1;
    pl_preset_shown = 0;
    uint32_t seen = 0;
    int prev = -1, rounds = 0, fails = 0, picks = 0;
    const uint32_t all = (1u << PL_NPRESETS) - 1;
    for (; picks < PL_NPRESETS * 20; picks++) {
        uint32_t p = pl_preset_pick();
        if (p >= PL_NPRESETS || (int)p == prev || (seen >> p & 1)) {
            printf("  pick %d: %u (prev %d, seen %08x)  FAIL\n", picks, p, prev, seen);
            fails++;
            break;
        }
        pl_preset_apply(p);
        seen |= 1u << p;
        prev = p;
        if (seen == all) { rounds++; seen = 1u << p; }
    }
    printf("  %d picks: never the current preset, each preset once per round, %d full rounds  %s\n",
           picks, rounds, fails ? "FAIL" : "OK");
    return fails;
}

/* ------------------------------------------------------------ 4. switch vs reference */
static void save_rules(float *a, float *mn, float *mx, float *phys)
{
    memcpy(a, pl.attr, sizeof pl.attr);
    memcpy(mn, pl.minr, sizeof pl.minr);
    memcpy(mx, pl.maxr_t, sizeof pl.maxr_t);
    phys[0] = pl.fric; phys[1] = pl.fscale; phys[2] = pl.core;
}

static int test_switch(int n, int k, float w, float h, int simd, int threads, int pa, int pb, int steps)
{
    setup(k, w, h, 2, simd, threads);
    pl.rng = 4242 + pa * 31 + pb;
    if (pl_alloc(n)) return 1;
    pl_preset_apply(pa);
    for (int s = 0; s < 20; s++) pl_step();
    uint32_t cols_a = pl.cols, rows_a = pl.rows;
    float maxr_a = pl.maxr;
    float oa[256], omn[256], omx[256], ophys[3];
    save_rules(oa, omn, omx, ophys);

    pl_preset_apply(pb); /* the switch: new rules, new scatter */

    ref_sim r, rb, stale;
    ref_load(&r, n, k, w, h, 2, pl.dt, pl.fric, pl.fscale, pl.core, pl.attr, pl.minr, pl.maxr_t,
             pl.x, pl.y, pl.vx, pl.vy, pl.t, pl.id);
    ref_load(&rb, n, k, w, h, 2, pl.dt, pl.fric, pl.fscale, pl.core, pl.attr, pl.minr, pl.maxr_t,
             pl.x, pl.y, pl.vx, pl.vy, pl.t, pl.id);
    ref_load(&stale, n, k, w, h, 2, pl.dt, ophys[0], ophys[1], ophys[2], oa, omn, omx,
             pl.x, pl.y, pl.vx, pl.vy, pl.t, pl.id);
    int fail = 0;
    if (pl.cols != (uint32_t)r.cols || pl.rows != (uint32_t)r.rows || pl.maxr != r.gmaxr) fail = 1;
    for (uint32_t i = 0; i < pl.n; i++)
        if (pl.x[i] != r.x[i] || pl.y[i] != r.y[i] || pl.id[i] != r.id[i]) fail = 1;
    for (int i = 0; i < k; i++)
        for (int j = 0; j < k; j++)
            if (pl.tb0[i * 16 + j] != r.b0[i][j] || pl.tas[i * 16 + j] != r.as[i][j] ||
                pl.tc1[i * 16 + j] != r.c1[i][j] || pl.tir[i * 16 + j] != r.ir[i][j])
                fail = 1;
    const char *sname = simd == 2 ? "avx512" : (k <= 8 ? "avx2-k8" : "avx2-k16");
    printf("  %s -> %s  N=%d K=%d %s threads=%u: maxr %.1f -> %.1f, grid %ux%u -> %ux%u, state %s\n",
           pl_preset_names[pa], pl_preset_names[pb], n, k, sname, pl.nthreads, maxr_a, pl.maxr,
           cols_a, rows_a, pl.cols, pl.rows, fail ? "MISMATCH" : "bit-identical to ref");
    if (fail) return 1;
    /* pass: every particle within TOL, except at most N/1000 minr-jump
       outliers which must still be within MAXDEV; the stale-rule reference
       must disagree on more than 10% of the particles */
    const float MAXDEV = 0.05f;
    float eg = 0, eb = 0, es = 0;
    int og = 0, ob = 0, os = 0;
    for (int s = 1; s <= steps; s++) {
        pl_step();
        ref_step(&r);
        ref_step_brute(&rb);
        ref_step(&stale);
        eg = fmaxf(eg, compare(&r));
        eb = fmaxf(eb, compare(&rb));
        es = fmaxf(es, compare(&stale));
        if (eg > MAXDEV || eb > MAXDEV) {
            printf("    step %d: asm vs new-rule ref %.3g px, vs brute %.3g  FAIL\n", s, eg, eb);
            return 1;
        }
    }
    og = outliers(&r);
    ob = outliers(&rb);
    os = outliers(&stale);
    int ok_new = og <= n / 1000 && ob <= n / 1000;
    int stale_caught = os > n / 10;
    printf("    %d steps: asm vs ref(new rules) max %.1e px, %d/%d particles > %.0e; vs brute(new) max %.1e px, %d > %.0e\n",
           steps, eg, og, n, TOL, eb, ob, TOL);
    printf("              asm vs ref(OLD rules) max %.2f px, %d/%d particles > %.0e (%s)  %s\n", es, os, n,
           TOL, stale_caught ? "stale rules detected" : "stale rules NOT detected",
           ok_new && stale_caught ? "OK" : "FAIL");
    return !(ok_new && stale_caught);
}

/* ------------------------------------------------------------ 5. A -> B -> A */
static int test_aba(int n, int k, int simd, int threads, int pa, int pb, uint64_t seed)
{
    const int steps = 40;
    setup(k, 900, 700, 2, simd, threads);
    if (pl_alloc(n)) return 1;
    float *sx = malloc(n * 4), *sy = malloc(n * 4), *svx = malloc(n * 4);
    int *sid = malloc(n * 4);
    float tabs[7][256];
    uint32_t grid[3];

    pl.rng = seed;
    pl_preset_apply(pa);
    for (int s = 0; s < steps; s++) pl_step();
    memcpy(sx, pl.x, n * 4); memcpy(sy, pl.y, n * 4); memcpy(svx, pl.vx, n * 4);
    memcpy(sid, pl.id, n * 4);
    memcpy(tabs, pl.attr, sizeof tabs);
    grid[0] = pl.cols; grid[1] = pl.rows; grid[2] = pl.ncells;
    float fs = pl.fscale, fr = pl.fric, co = pl.core;

    pl_preset_apply(pb);
    for (int s = 0; s < steps; s++) pl_step();
    uint32_t bcols = pl.cols, brows = pl.rows;

    pl.rng = seed;
    pl_preset_apply(pa);
    for (int s = 0; s < steps; s++) pl_step();
    int same = !memcmp(sx, pl.x, n * 4) && !memcmp(sy, pl.y, n * 4) && !memcmp(svx, pl.vx, n * 4) &&
               !memcmp(sid, pl.id, n * 4) && !memcmp(tabs, pl.attr, sizeof tabs) &&
               grid[0] == pl.cols && grid[1] == pl.rows && grid[2] == pl.ncells &&
               fs == pl.fscale && fr == pl.fric && co == pl.core;
    printf("  %s -> %s -> %s  N=%d K=%d threads=%u (grid %ux%u -> %ux%u -> %ux%u): %d steps of A %s\n",
           pl_preset_names[pa], pl_preset_names[pb], pl_preset_names[pa], n, k, pl.nthreads,
           grid[0], grid[1], bcols, brows, pl.cols, pl.rows, steps,
           same ? "bit-identical  OK" : "DIFFER  FAIL");
    free(sx); free(sy); free(svx); free(sid);
    return !same;
}

int main(int argc, char **argv)
{
    feat = pl_cpu_features();
    if (!(feat & 1)) { puts("AVX2/FMA not available"); return 1; }
    int simd = 2 - !(feat & 2);
    int fails = 0, f;
    pl.rng = 1;

    puts("--- preset names");
    f = 0;
    if (pl_preset_find("helical") != 21 || pl_preset_find("HelicalLadder") != 21 ||
        pl_preset_find("hub&spokes") != 8 || pl_preset_find("nope") != -1)
        f = 1;
    printf("  %d presets, lookup by display/enum name, case-insensitive  %s\n", PL_NPRESETS,
           f ? "FAIL" : "OK");
    fails += f;

    puts("--- attraction matrices vs pl-box (RuleMatrix::from_preset run by tools/plbox_dump)");
    fails += test_plbox_ref(argc > 1 ? argv[1] : "tests/plbox_ref.txt");

    puts("--- every preset installed for K = 1..16: ranges, physics, derived tables, grid");
    fails += test_ranges();

    puts("--- shuffle bag");
    fails += test_bag();

    puts("--- switch, then asm vs C reference loaded with the new rules from the same state");
    /* Shells, Dimers, Bipartite: pl-box cfg physics (maxr < 45); Checker,
       Snake: render defaults (maxr < 70), so the grid changes size */
    fails += test_switch(4000, 6, 1000, 700, 1, 1, 9, 11, 30);   /* Shells -> Checker */
    fails += test_switch(4000, 6, 1000, 700, 1, 1, 9, 12, 30);   /* Shells -> Dimers (same physics) */
    fails += test_switch(4000, 12, 1000, 700, 1, 1, 2, 28, 30);  /* Snake -> TriSpiral */
    if (feat & 2) {
        fails += test_switch(4000, 8, 1000, 700, 2, 1, 11, 20, 30);  /* Checker -> ParityVortex */
        fails += test_switch(4000, 16, 1000, 700, 2, 1, 7, 2, 30);   /* Bipartite -> Snake */
    }
    fails += test_switch(20000, 7, 1920, 1080, simd, 8, 21, 24, 20); /* Helical -> SkipPursuit, 8 threads */
    fails += test_switch(20000, 9, 1920, 1080, 1, 8, 24, 0, 20);     /* SkipPursuit -> Random, 8 threads */

    puts("--- A -> B -> A with the same seed");
    fails += test_aba(5000, 6, simd, 1, 9, 11, 99);     /* Shells -> Checker -> Shells */
    fails += test_aba(5000, 10, 1, 1, 28, 19, 5);       /* TriSpiral -> PrimeHop -> TriSpiral */
    fails += test_aba(20000, 8, simd, 8, 0, 25, 1234);  /* Random -> BlueNoise -> Random, 8 threads */

    puts(fails ? "FAILED" : "ALL PRESET TESTS PASSED");
    return fails != 0;
}
