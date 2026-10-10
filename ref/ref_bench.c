/* Headless benchmark of the C reference step, same CLI and initial state as
 * `particle_life --bench`. Single threaded. */
#include "ref.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

int main(int argc, char **argv)
{
    int n = 20000, k = 6, w = 1600, h = 900, steps = 200, warmup = 0;
    unsigned long long seed = 1;
    for (int i = 1; i + 1 < argc; i += 2) {
        const char *a = argv[i], *v = argv[i + 1];
        if (!strcmp(a, "--particles")) n = atoi(v);
        else if (!strcmp(a, "--types")) k = atoi(v);
        else if (!strcmp(a, "--seed")) seed = strtoull(v, 0, 10);
        else if (!strcmp(a, "--width")) w = atoi(v);
        else if (!strcmp(a, "--height")) h = atoi(v);
        else if (!strcmp(a, "--bench")) steps = atoi(v);
        else if (!strcmp(a, "--warmup")) warmup = atoi(v);
        else { fprintf(stderr, "unknown option %s\n", a); return 2; }
    }
    ref_sim s;
    ref_init(&s, n, k, (float)w, (float)h, seed);
    for (int i = 0; i < warmup; i++) ref_step(&s);
    double t0 = now();
    for (int i = 0; i < steps; i++) ref_step(&s);
    double el = now() - t0;
    printf("C ref threads=1 particles=%d types=%d world=%dx%d steps=%d (after %d warmup)\n",
           n, k, w, h, steps, warmup);
    printf("      %.1f steps/s  %.3f ms/step  %.2f ns/particle-step\n",
           steps / el, el / steps * 1e3, el / steps * 1e9 / n);
    return 0;
}
