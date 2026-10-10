/* Headless benchmark of the C reference step, same CLI and initial state as
 * `particle_life --bench`. Single threaded. */
#include "ref.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <math.h>

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

int main(int argc, char **argv)
{
    int n = 20000, k = 6, w = 1600, h = 900, steps = 200, warmup = 0, stats = 0, cdiv = 2;
    unsigned long long seed = 1;
    for (int i = 1; i < argc; i += 2) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : "0";
        if (!strcmp(a, "--stats")) { stats = 1; i--; continue; }
        if (!strcmp(a, "--particles")) n = atoi(v);
        else if (!strcmp(a, "--types")) k = atoi(v);
        else if (!strcmp(a, "--seed")) seed = strtoull(v, 0, 10);
        else if (!strcmp(a, "--width")) w = atoi(v);
        else if (!strcmp(a, "--height")) h = atoi(v);
        else if (!strcmp(a, "--bench")) steps = atoi(v);
        else if (!strcmp(a, "--warmup")) warmup = atoi(v);
        else if (!strcmp(a, "--cell-div")) cdiv = atoi(v);
        else { fprintf(stderr, "unknown option %s\n", a); return 2; }
    }
    ref_sim s;
    ref_init(&s, n, k, (float)w, (float)h, seed, cdiv);
    for (int i = 0; i < warmup; i++) ref_step(&s);
    double t0 = now();
    for (int i = 0; i < steps; i++) ref_step(&s);
    double el = now() - t0;
    printf("C ref threads=1 particles=%d types=%d world=%dx%d cell-div=%d steps=%d (after %d warmup)\n",
           n, k, w, h, cdiv, steps, warmup);
    printf("      %.1f steps/s  %.3f ms/step  %.2f ns/particle-step\n",
           steps / el, el / steps * 1e3, el / steps * 1e9 / n);
    if (stats) {
        /* candidate pairs examined per particle and pairs within maxr */
        double cand = 0, inter = 0;
        for (int cy = 0; cy < s.rows; cy++)
            for (int cx = 0; cx < s.cols; cx++) {
                int c = cy * s.cols + cx, nb = 0;
                for (int dy = -cdiv; dy <= cdiv; dy++)
                    for (int dx = -cdiv; dx <= cdiv; dx++) {
                        int q = ((cy + dy + s.rows) % s.rows) * s.cols + (cx + dx + s.cols) % s.cols;
                        nb += s.cstart[q + 1] - s.cstart[q];
                    }
                cand += (double)(s.cstart[c + 1] - s.cstart[c]) * nb;
            }
        for (int i = 0; i < n; i++)
            for (int j = 0; j < n; j++) {
                float dx = fabsf(s.x[j] - s.x[i]), dy = fabsf(s.y[j] - s.y[i]);
                dx = fminf(dx, s.w - dx); dy = fminf(dy, s.h - dy);
                float m = s.maxr[s.t[i]][s.t[j]];
                if (j != i && dx < m && dy < m && dx * dx + dy * dy < m * m) inter++;
            }
        printf("      grid %dx%d, %.1f candidates/particle, %.1f within maxr (%.0f%%)\n",
               s.cols, s.rows, cand / n, inter / n, 100.0 * inter / cand);
    }
    return 0;
}
