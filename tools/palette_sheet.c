/* docs/palettes.png source: every palette as the program builds it for
 * K = 4, 8 and 16 types (src/palettes.S: lift, expand), drawn on the
 * simulation background; names and a dark line through the K values the palette does not
 * qualify for (some pair closer than the distance limit) are drawn with the
 * asm font. Writes a PPM to argv[1].
 *   build/run: tools/palette_sheet.sh */
#include "../ref/pl_state.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int pl_write_ppm(const char *path, const uint32_t *buf, uint32_t w, uint32_t h);

int main(int argc, char **argv)
{
    const int ks[3] = { 4, 8, 16 };
    const int name_w = 250, sw = 16, gap = 24, row_h = 20, cols = 2;
    const int block_w = name_w + (4 + 8 + 16) * sw + 3 * gap + 30;
    const int rows = (pl_npalettes + cols - 1) / cols;
    const int W = cols * block_w + 10, H = rows * row_h + 40;
    uint32_t *buf = malloc((size_t)W * H * 4);
    for (int i = 0; i < W * H; i++) buf[i] = 0xFF0A0A10;
    for (int c = 0; c < cols; c++) {
        int x = c * block_w + 10;
        pl_draw_text(buf, W, H, x, 10, "palette", 0xFFE8E8E8, 1);
        x += name_w;
        for (int j = 0; j < 3; j++) {
            char t[8];
            snprintf(t, sizeof t, "K=%d", ks[j]);
            pl_draw_text(buf, W, H, x, 10, t, 0xFFE8E8E8, 1);
            x += ks[j] * sw + gap;
        }
    }
    for (int p = 0; p < pl_npalettes; p++) {
        int bx = (p / rows) * block_w + 10, by = (p % rows) * row_h + 30;
        char lbl[64];
        snprintf(lbl, sizeof lbl, "%2d %s", p, pl_palette_names[p]);
        pl_draw_text(buf, W, H, bx, by + 4, lbl, 0xFFE8E8E8, 1);
        int x = bx + name_w;
        for (int c = 0; c < 3; c++) {
            uint32_t col[16];
            pl_palette_build(p, ks[c], col);
            int ok = pl_palette_ok(p, ks[c]);
            for (int i = 0; i < ks[c]; i++)
                for (int yy = 2; yy < row_h - 3; yy++)
                    for (int xx = 1; xx < sw - 2; xx++)
                        buf[(by + yy) * W + x + i * sw + xx] =
                            !ok && yy == row_h / 2 - 1 ? 0xFF0A0A10 : col[i];
            x += ks[c] * sw + gap;
        }
    }
    return pl_write_ppm(argc > 1 ? argv[1] : "palettes.ppm", buf, W, H);
}
