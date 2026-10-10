/* Plain C reference implementation of the Particle Life step.
 *
 * ref_step()       same grid / counting-sort algorithm and the same per-pair
 *                  formulation as the asm kernels (scalar code, the compiler
 *                  may auto-vectorise it).
 * ref_step_brute() O(N^2) version written the way pl-box writes it
 *                  (minimum-image delta, original force law), used to check
 *                  that the grid misses nothing.
 * Both use the same RNG and initialisation order as src/sim.S.
 */
#include "ref.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

static uint64_t rng_u64(ref_sim *s)
{
    uint64_t z = (s->rng += 0x9E3779B97F4A7C15ull);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
}

static float rng_range(ref_sim *s, float a, float b)
{
    float u = (float)(rng_u64(s) >> 40) * 5.9604644775390625e-8f;
    return fmaf(b - a, u, a);
}

static void update_pairs(ref_sim *s)
{
    float core_s = s->core * s->fscale;
    s->cores = core_s * 0.5f;
    s->damp = 1.0f - s->fric * s->dt;
    float g = 0.0f;
    for (int i = 0; i < s->k; i++)
        for (int j = 0; j < s->k; j++) {
            float mn = s->minr[i][j], mx = s->maxr[i][j];
            g = fmaxf(g, mx);
            /* same folded tables as the asm (see src/sim.S header) */
            float ir = 1.0f / (mx - mn);
            s->b0[i][j] = mx * ir;
            s->ir[i][j] = ir * 0.5f;
            s->c1[i][j] = core_s / mn;
            s->as[i][j] = s->attr[i][j] * s->fscale * -0.5f;
        }
    s->gmaxr = g;
}

static void update_tables(ref_sim *s)
{
    update_pairs(s);
    const int R = s->cdiv;
    float g = s->gmaxr / (float)R;
    s->cols = (int)(s->w / g);
    if (s->cols < 2 * R + 1) s->cols = 2 * R + 1;
    s->rows = (int)(s->h / g);
    if (s->rows < 2 * R + 1) s->rows = 2 * R + 1;
    s->cw = s->w / (float)s->cols;
    s->ch = s->h / (float)s->rows;
    s->icw = 1.0f / s->cw;
    s->ich = 1.0f / s->ch;
    s->ncells = s->cols * s->rows;
    free(s->cstart);
    free(s->ccur);
    s->cstart = calloc(s->ncells + 1, sizeof(int));
    s->ccur = calloc(s->ncells + 1, sizeof(int));
}

static void ref_bin(ref_sim *s)
{
    int n = s->n;
    memset(s->cstart, 0, (s->ncells + 1) * sizeof(int));
    for (int i = 0; i < n; i++) {
        unsigned cx = (unsigned)(int)(s->nx[i] * s->icw);
        unsigned cy = (unsigned)(int)(s->ny[i] * s->ich);
        if (cx > (unsigned)s->cols - 1) cx = s->cols - 1;
        if (cy > (unsigned)s->rows - 1) cy = s->rows - 1;
        int c = cy * s->cols + cx;
        s->cellid[i] = c;
        s->cstart[c + 1]++;
    }
    for (int c = 0, a = 0; c <= s->ncells; c++) {
        a += s->cstart[c];
        s->cstart[c] = s->ccur[c] = a;
    }
    for (int i = 0; i < n; i++) {
        int d = s->ccur[s->cellid[i]]++;
        s->x2[d] = s->nx[i];
        s->y2[d] = s->ny[i];
        s->vx2[d] = s->vx[i];
        s->vy2[d] = s->vy[i];
        s->t2[d] = s->t[i];
        s->id2[d] = s->id[i];
    }
#define SWAP(a, b) do { void *tmp_ = (void *)a; a = b; b = tmp_; } while (0)
    SWAP(s->x, s->x2); SWAP(s->y, s->y2); SWAP(s->vx, s->vx2);
    SWAP(s->vy, s->vy2); SWAP(s->t, s->t2); SWAP(s->id, s->id2);
#undef SWAP
}

void ref_init(ref_sim *s, int n, int k, float w, float h, uint64_t seed, int cdiv)
{
    memset(s, 0, sizeof *s);
    s->n = n; s->k = k; s->w = w; s->h = h; s->cdiv = cdiv;
    s->dt = 1.0f / 60.0f; s->fric = 0.4f; s->fscale = 0.3f; s->core = 0.6f;
    s->rng = seed;
    for (int i = 0; i < k; i++)
        for (int j = 0; j < k; j++) {
            s->attr[i][j] = rng_range(s, -1.0f, 1.0f);
            s->minr[i][j] = rng_range(s, 12.0f, 24.0f);
            s->maxr[i][j] = rng_range(s, 33.0f, 70.0f);
        }
    update_tables(s);
    float **fa[] = {&s->x, &s->y, &s->vx, &s->vy, &s->x2, &s->y2, &s->vx2, &s->vy2, &s->nx, &s->ny};
    for (unsigned a = 0; a < sizeof fa / sizeof *fa; a++) *fa[a] = calloc(n + 32, sizeof(float));
    int **ia[] = {&s->t, &s->id, &s->t2, &s->id2, &s->cellid};
    for (unsigned a = 0; a < sizeof ia / sizeof *ia; a++) *ia[a] = calloc(n + 32, sizeof(int));
    for (int i = 0; i < n; i++) {
        s->nx[i] = rng_range(s, 0.0f, w);
        s->ny[i] = rng_range(s, 0.0f, h);
        s->t[i] = (int)(((rng_u64(s) >> 32) * (uint64_t)k) >> 32);
        s->id[i] = i;
    }
    ref_bin(s);
}

void ref_load(ref_sim *s, int n, int k, float w, float h, int cdiv,
              float dt, float fric, float fscale, float core,
              const float *attr, const float *minr, const float *maxr,
              const float *x, const float *y, const float *vx, const float *vy,
              const int *t, const int *id)
{
    memset(s, 0, sizeof *s);
    s->n = n; s->k = k; s->w = w; s->h = h; s->cdiv = cdiv;
    s->dt = dt; s->fric = fric; s->fscale = fscale; s->core = core;
    for (int i = 0; i < k; i++)
        for (int j = 0; j < k; j++) {
            s->attr[i][j] = attr[i * 16 + j];
            s->minr[i][j] = minr[i * 16 + j];
            s->maxr[i][j] = maxr[i * 16 + j];
        }
    update_tables(s);
    float **fa[] = {&s->x, &s->y, &s->vx, &s->vy, &s->x2, &s->y2, &s->vx2, &s->vy2, &s->nx, &s->ny};
    for (unsigned a = 0; a < sizeof fa / sizeof *fa; a++) *fa[a] = calloc(n + 32, sizeof(float));
    int **ia[] = {&s->t, &s->id, &s->t2, &s->id2, &s->cellid};
    for (unsigned a = 0; a < sizeof ia / sizeof *ia; a++) *ia[a] = calloc(n + 32, sizeof(int));
    if (n > 0) {
        memcpy(s->nx, x, n * sizeof(float));
        memcpy(s->ny, y, n * sizeof(float));
        memcpy(s->vx, vx, n * sizeof(float));
        memcpy(s->vy, vy, n * sizeof(float));
        memcpy(s->t, t, n * sizeof(int));
        memcpy(s->id, id, n * sizeof(int));
    }
    ref_bin(s);
}

void ref_set_params(ref_sim *s, float dt, float fric, float fscale, float core)
{
    s->dt = dt; s->fric = fric; s->fscale = fscale; s->core = core;
    update_pairs(s); /* radii unchanged, so the grid stays valid */
}

static inline float wrapf(float p, float e)
{
    if (p < 0.0f) p += e;
    else if (p >= e) p -= e;
    return p;
}

static inline void integrate(ref_sim *s, int i, float fx, float fy)
{
    float vx = fmaf(fx, s->dt, s->vx[i] * s->damp);
    float vy = fmaf(fy, s->dt, s->vy[i] * s->damp);
    s->vx[i] = vx;
    s->vy[i] = vy;
    s->nx[i] = wrapf(fmaf(vx, s->dt, s->x[i]), s->w);
    s->ny[i] = wrapf(fmaf(vy, s->dt, s->y[i]), s->h);
}

void ref_step(ref_sim *s)
{
    const int cols = s->cols, rows = s->rows, R = s->cdiv;
    for (int cy = 0; cy < rows; cy++)
        for (int cx = 0; cx < cols; cx++) {
            int c = cy * cols + cx;
            /* contiguous particle ranges (one or two per neighbour row) with their wrap shift */
            int r0[10], r1[10], nr = 0;
            float rsx[10], rsy[10];
            for (int d = -R; d <= R; d++) {
                int ry = cy + d;
                float sy = 0.0f;
                if (ry < 0) { ry += rows; sy = -s->h; }
                else if (ry >= rows) { ry -= rows; sy = s->h; }
                int base = ry * cols, lo = cx - R, hi = cx + R;
                int a0, a1, b0 = -1, b1 = -1;
                float bsx = 0.0f;
                if (lo < 0) { a0 = base; a1 = base + hi + 1; b0 = base + cols + lo; b1 = base + cols; bsx = -s->w; }
                else if (hi >= cols) { a0 = base + lo; a1 = base + cols; b0 = base; b1 = base + hi - cols + 1; bsx = s->w; }
                else { a0 = base + lo; a1 = base + hi + 1; }
                r0[nr] = s->cstart[a0]; r1[nr] = s->cstart[a1]; rsx[nr] = 0.0f; rsy[nr] = sy; nr++;
                if (b0 >= 0) { r0[nr] = s->cstart[b0]; r1[nr] = s->cstart[b1]; rsx[nr] = bsx; rsy[nr] = sy; nr++; }
            }
            for (int i = s->cstart[c]; i < s->cstart[c + 1]; i++) {
                const int ki = s->t[i];
                const float *b0 = s->b0[ki], *ir = s->ir[ki], *c1 = s->c1[ki], *as = s->as[ki];
                const float cores = s->cores;
                float fx = 0.0f, fy = 0.0f;
                for (int r = 0; r < nr; r++) {
                    const float bx = s->x[i] - rsx[r], by = s->y[i] - rsy[r];
                    for (int j = r0[r]; j < r1[r]; j++) {
                        float dx = s->x[j] - bx, dy = s->y[j] - by;
                        float d2 = fmaf(dx, dx, fmaf(dy, dy, 1e-8f));
                        float i2 = 2.0f / sqrtf(d2);     /* 2/d */
                        float dd = d2 * i2;              /* 2d  */
                        int kj = s->t[j];
                        float sv = b0[kj] - dd * ir[kj]; /* (maxr-d)/(maxr-minr) */
                        float sc = fmaxf(sv, 0.0f); /* sv > 1 takes the core branch */
                        /* g = force / d */
                        float g = sv > 1.0f ? c1[kj] - cores * i2
                                            : as[kj] * i2 * (sc * sc) * (sc + sc - 3.0f);
                        fx += g * dx;
                        fy += g * dy;
                    }
                }
                integrate(s, i, fx, fy);
            }
        }
    ref_bin(s);
}

static float smoothstep(float t)
{
    t = fminf(fmaxf(t, 0.0f), 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

void ref_step_brute(ref_sim *s)
{
    for (int i = 0; i < s->n; i++) {
        int ki = s->t[i];
        float fx = 0.0f, fy = 0.0f;
        for (int j = 0; j < s->n; j++) {
            if (j == i) continue;
            float dx = s->x[j] - s->x[i], dy = s->y[j] - s->y[i];
            if (dx > s->w * 0.5f) dx -= s->w; else if (dx < -s->w * 0.5f) dx += s->w;
            if (dy > s->h * 0.5f) dy -= s->h; else if (dy < -s->h * 0.5f) dy += s->h;
            int kj = s->t[j];
            float d2 = dx * dx + dy * dy, mx = s->maxr[ki][kj], mn = s->minr[ki][kj];
            if (d2 >= mx * mx) continue;
            float dist = fmaxf(sqrtf(d2), 0.0001f);
            float f = dist < mn ? -s->core * (1.0f - fminf(fmaxf(dist / mn, 0.0f), 1.0f))
                                : s->attr[ki][kj] * smoothstep(1.0f - (dist - mn) / (mx - mn));
            fx += dx / dist * f * s->fscale;
            fy += dy / dist * f * s->fscale;
        }
        integrate(s, i, fx, fy);
    }
    ref_bin(s);
}
