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
/* src/presets.S */
#define PL_NPRESETS 31
extern const char *pl_preset_names[PL_NPRESETS];
extern const float pl_preset_phys[PL_NPRESETS][8]; /* fscale fric core minr0 minr1 maxr0 maxr1 - */
#define PL_NCURATED 17
#define PL_NENTRIES 48  /* 0..16 curated, 17..47 generated (rule = e - 17) */
extern int32_t pl_preset_cur;
extern uint64_t pl_preset_shown, pl_pool_mask;
extern uint32_t pl_pool;
extern const uint8_t pl_curated[PL_NCURATED][3]; /* rule, K, speed */
void pl_preset_attraction(uint32_t rule, uint32_t k, float *out);
void pl_preset_rules(uint32_t rule);
void pl_preset_apply(uint32_t rule);   /* rules + uniform particles */
uint32_t pl_preset_pick(void);
int pl_preset_find(const char *name);
uint32_t pl_entry_rule(uint32_t e);
uint32_t pl_entry_types(uint32_t e);
const char *pl_entry_name(uint32_t e);
void pl_entry_install(uint32_t e, uint32_t k);
void pl_pool_set(uint32_t pool);
uint32_t pl_types_draw(void);
int pl_entry_find(const char *name);
/* src/spawn.S */
#define PL_NSPAWNS 18
extern const char *pl_spawn_names[PL_NSPAWNS];
extern uint64_t pl_frng;
extern uint32_t pl_spawn_cur;
void pl_spawn(uint32_t layout);
uint32_t pl_spawn_pick(void);
uint32_t pl_spawn_raw(uint32_t layout, uint32_t n, uint32_t k, float w, float h,
                      float *x, float *y, int32_t *t);
/* src/palettes.S */
extern uint32_t pl_colors[16];
extern int32_t pl_palette_cur;
extern const int pl_npalettes;
extern const char *pl_palette_names[];
void pl_palette_build(uint32_t p, uint32_t k, uint32_t *out);
float pl_palette_mindist2(uint32_t p, uint32_t k);
int pl_palette_ok(uint32_t p, uint32_t k);
void pl_palette_set(uint32_t p);
uint32_t pl_palette_pick(void);
/* src/render.S */
void pl_render(uint32_t *buf, uint32_t w, uint32_t h);
void pl_draw_text(uint32_t *buf, uint32_t w, uint32_t h, int x, int y, const char *s,
                  uint32_t argb, uint32_t scale);
extern const uint8_t pl_font8[95][8];
#endif
