/* C view of the asm global state `pl` (src/layout.inc). */
#ifndef PL_STATE_H
#define PL_STATE_H
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint32_t n, k;
    float w, h;
    uint32_t cols, rows;
    float cw, ch, icw, ich;
    float dt, fric, fscale, core;
    uint32_t cap, nthreads;
    float *x, *y, *vx, *vy; int32_t *t, *id;
    float *x2, *y2, *vx2, *vy2; int32_t *t2, *id2;
    float *nx, *ny; uint32_t *cellid, *cstart, *ccur;
    uint64_t rng;
    uint32_t ncells; float maxr;
    uint32_t simd; float cores; float damp; uint32_t cellcap;
    void *nbr; void *kernel;
    uint32_t cdiv, nrange;
    float attr[256], minr[256], maxr_t[256];
    float tb0[256], tir[256], tc1[256], tas[256];
} pl_state;

_Static_assert(offsetof(pl_state, x) == 64, "x");
_Static_assert(offsetof(pl_state, nx) == 160, "nx");
_Static_assert(offsetof(pl_state, rng) == 200, "rng");
_Static_assert(offsetof(pl_state, kernel) == 240, "kernel");
_Static_assert(offsetof(pl_state, attr) == 256, "attr");
_Static_assert(offsetof(pl_state, tb0) == 3328, "tb0");
_Static_assert(sizeof(pl_state) == 7424, "size");

extern pl_state pl;
int pl_alloc(uint32_t n);
void pl_random_rules(void);
void pl_update_tables(void);
void pl_random_particles(void);
void pl_bin(void);
void pl_step(void);
int pl_cpu_features(void);
int pl_threads_start(uint32_t n);
#endif
