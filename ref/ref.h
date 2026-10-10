/* Plain C reference of the same Particle Life step (see ref.c). */
#ifndef REF_H
#define REF_H
#include <stdint.h>

typedef struct {
    int n, k, cdiv;
    float w, h, dt, fric, fscale, core;
    uint64_t rng;
    float attr[16][16], minr[16][16], maxr[16][16];
    /* derived */
    float b0[16][16], ir[16][16], c1[16][16], as[16][16];
    float cores, damp, gmaxr;
    int cols, rows, ncells;
    float cw, ch, icw, ich;
    /* particles, cell ordered after ref_bin */
    float *x, *y, *vx, *vy; int *t, *id;
    float *x2, *y2, *vx2, *vy2; int *t2, *id2;
    float *nx, *ny; int *cellid, *cstart, *ccur;
} ref_sim;

/* cdiv = R: cell size >= max radius / R, (2R+1)^2 neighbour cells */
void ref_init(ref_sim *s, int n, int k, float w, float h, uint64_t seed, int cdiv);
void ref_set_params(ref_sim *s, float dt, float fric, float fscale, float core);
void ref_step(ref_sim *s);        /* grid version, same algorithm as asm */
void ref_step_brute(ref_sim *s);  /* O(N^2) minimum-image version */
#endif
