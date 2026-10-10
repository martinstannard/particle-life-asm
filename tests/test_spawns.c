/* Spawn layouts (src/spawn.S) against pl-box.
 *
 * 1. Bit-identity: for every case in tests/plbox_spawns.txt (pl-box's own
 *    Simulation::spawn_* run from a fixed fastrand seed, see
 *    tools/plbox_dump), seed the asm wyrand the same way, run the same
 *    layout unwrapped, and compare the count and an FNV-1a hash over every
 *    (x bits, y bits, type) in order.
 * 2. Invariants of pl_spawn (the wrapped, installed version) for all
 *    layouts and K = 1..16: exactly N particles, all inside [0,W) x [0,H),
 *    types < K, ids 0..N-1, and every type present for the layouts whose
 *    construction guarantees it.
 */
#include "../ref/pl_state.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern uint64_t pl_frng;
extern const char *pl_spawn_names[];
uint32_t pl_spawn_raw(uint32_t layout, uint32_t n, uint32_t k, float w, float h,
                      float *x, float *y, int32_t *t);
void pl_spawn(uint32_t layout);
#define NSPAWNS 17

static uint64_t fnv(const float *x, const float *y, const int32_t *t, uint32_t n)
{
    uint64_t h = 0xcbf29ce484222325ull;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t v[3];
        memcpy(&v[0], &x[i], 4);
        memcpy(&v[1], &y[i], 4);
        v[2] = (uint32_t)t[i];
        for (int j = 0; j < 3; j++)
            for (int b = 0; b < 4; b++) {
                h ^= (v[j] >> (8 * b)) & 0xff;
                h *= 0x100000001b3ull;
            }
    }
    return h;
}

/* every species present by construction (given N >= a few hundred) */
static int all_types_expected(const char *name, uint32_t k)
{
    static const char *yes[] = { "pie", "line", "ring", "rainbow_ring", "rainbow_rings",
        "soft_clusters", "radiant_fans", "twin_spirals", "spiral_arms", "blocks",
        "line_mixed", "stripes", "random", 0 };
    if (k == 1) return 1;
    for (int i = 0; yes[i]; i++)
        if (!strcmp(name, yes[i])) return 1;
    return 0;
}

int main(int argc, char **argv)
{
    int fails = 0;
    FILE *f = fopen(argc > 1 ? argv[1] : "tests/plbox_spawns.txt", "r");
    if (!f) { puts("cannot open reference"); return 1; }
    static float x[4096], y[4096];
    static int32_t t[4096];
    int cases = 0, same = 0, deviations = 0;
    int per_layout[NSPAWNS] = {0}, per_layout_ok[NSPAWNS] = {0};
    char line[512];
    while (fgets(line, sizeof line, f)) {
        unsigned li, n, k, cnt; char name[32]; float w, h;
        unsigned long long seed, hash; unsigned x0, y0, t0;
        if (sscanf(line, "%u %31s %u %u %f %f %llu %u %llx %x %x %u",
                   &li, name, &n, &k, &w, &h, &seed, &cnt, &hash, &x0, &y0, &t0) != 12)
            continue;
        cases++;
        if (strcmp(name, pl_spawn_names[li])) { printf("name mismatch %s\n", name); fails++; continue; }
        pl_frng = seed;
        uint32_t got = pl_spawn_raw(li, n, k, w, h, x, y, t);
        if (cnt != n) {
            /* pl-box returned fewer than N (radiant_fans with K < 3 skips
               fans that have no colour); the asm always fills N */
            printf("  %-13s K=%-2u n=%-4u pl-box gives %u particles, asm %u (documented deviation)\n",
                   name, k, n, cnt, got);
            deviations++;
            continue;
        }
        per_layout[li]++;
        uint64_t hh = fnv(x, y, t, got);
        if (got == cnt && hh == hash) {
            same++;
            per_layout_ok[li]++;
        } else {
            uint32_t ax, ay; memcpy(&ax, &x[0], 4); memcpy(&ay, &y[0], 4);
            printf("  MISMATCH %-13s K=%-2u n=%u: count %u/%u hash %016llx/%016llx first %08x %08x %d / %08x %08x %u\n",
                   name, k, n, got, cnt, (unsigned long long)hh, hash, ax, ay, t[0], x0, y0, t0);
            fails++;
        }
    }
    fclose(f);
    printf("bit-identical to pl-box (count + hash of all x, y, type):\n");
    for (int i = 0; i < NSPAWNS; i++)
        if (per_layout[i])
            printf("  %-13s %2d/%-2d cases (K 2,3,5,8,13,16; 2000 @1600x900 and 1001 @900x1400)\n",
                   pl_spawn_names[i], per_layout_ok[i], per_layout[i]);
    printf("  total %d/%d identical, %d cases where pl-box itself returns < N\n",
           same, cases - deviations, deviations);

    /* invariants of the installed spawn */
    pl.w = 1280; pl.h = 720; pl.dt = 1.0f / 60; pl.fric = 0.4f; pl.fscale = 0.3f; pl.core = 0.6f;
    pl.simd = 1; pl.cdiv = 1; pl.nthreads = 1; pl.rng = 99;
    const uint32_t N = 3001;
    if (pl_alloc(N)) { puts("alloc"); return 1; }
    int inv_bad = 0;
    printf("invariants of pl_spawn, N=%u, 1280x720, K=1..16 (min/max count per type at K=8):\n", N);
    for (int li = 0; li < NSPAWNS; li++) {
        int bad = 0, missing = 0; unsigned mn8 = 0, mx8 = 0;
        for (uint32_t k = 1; k <= 16; k++) {
            pl.k = k;
            pl_random_rules();
            pl_spawn(li);
            unsigned hist[16] = {0};
            int seen_id[N]; memset(seen_id, 0, sizeof seen_id);
            if (pl.n != N) bad++;
            for (uint32_t i = 0; i < pl.n; i++) {
                if (!(pl.x[i] >= 0 && pl.x[i] < pl.w && pl.y[i] >= 0 && pl.y[i] < pl.h)) bad++;
                if (pl.t[i] < 0 || (uint32_t)pl.t[i] >= k) { bad++; continue; }
                if (pl.id[i] < 0 || (uint32_t)pl.id[i] >= N || seen_id[pl.id[i]]++) bad++;
                if (pl.vx[i] != 0 || pl.vy[i] != 0) bad++;
                hist[pl.t[i]]++;
            }
            if (all_types_expected(pl_spawn_names[li], k))
                for (uint32_t j = 0; j < k; j++)
                    if (!hist[j]) missing++;
            if (k == 8) {
                mn8 = N; mx8 = 0;
                for (int j = 0; j < 8; j++) {
                    if (hist[j] < mn8) mn8 = hist[j];
                    if (hist[j] > mx8) mx8 = hist[j];
                }
            }
        }
        printf("  %-13s %s  K=8 per-type %4u..%-4u %s\n", pl_spawn_names[li],
               bad || missing ? "FAIL" : "ok  ", mn8, mx8,
               all_types_expected(pl_spawn_names[li], 2) ? "(all types present)"
                                                         : "(type coverage not guaranteed by pl-box)");
        if (bad || missing) { inv_bad++; printf("     %d bad particles, %d missing types\n", bad, missing); }
    }
    fails += inv_bad;
    puts(fails ? "SPAWN TESTS FAILED" : "ALL SPAWN TESTS PASSED");
    return fails != 0;
}
