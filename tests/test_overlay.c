/* Overlay text (pl_draw_text in src/render.S, font in src/font.S).
 *
 * Renders known strings into a small buffer and compares every pixel with
 * an image built here from glyph art written independently of the font
 * table: text pixels in the text colour, a black drop shadow offset by
 * (scale, scale) where the text does not cover it, the background
 * untouched elsewhere. Checked at scale 1 and 2, across a newline, and
 * clipped at the right and bottom edges.
 */
#include "../ref/pl_state.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const struct { char c; const char *rows[7]; } ART[] = {
    { 'F', { "#####", "#....", "#....", "####.", "#....", "#....", "#...." } },
    { 'P', { "####.", "#...#", "#...#", "####.", "#....", "#....", "#...." } },
    { 'S', { ".####", "#....", "#....", ".###.", "....#", "....#", "####." } },
    { '6', { "..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###." } },
    { '0', { ".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###." } },
    { '.', { ".....", ".....", ".....", ".....", ".....", ".##..", ".##.." } },
    { 'K', { "#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#" } },
    { '=', { ".....", ".....", "#####", ".....", "#####", ".....", "....." } },
    { '9', { ".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.." } },
    { ' ', { ".....", ".....", ".....", ".....", ".....", ".....", "....." } },
};

static int on(char c, int row, int col)
{
    if (row >= 7 || col >= 5) return 0;
    for (size_t i = 0; i < sizeof ART / sizeof ART[0]; i++)
        if (ART[i].c == c) return ART[i].rows[row][col] == '#';
    fprintf(stderr, "no art for '%c'\n", c);
    exit(2);
}

#define BG 0xFF203040u
#define FG 0xFFE8E8E8u
#define SH 0xFF000000u

/* expected image: shadow pass then text pass, like the renderer */
static void expect(uint32_t *img, int w, int h, int x0, int y0, const char *s, int sc)
{
    for (int pass = 0; pass < 2; pass++) {
        int ox = pass ? 0 : sc, oy = pass ? 0 : sc;
        int px = x0, py = y0;
        for (const char *p = s; *p; p++) {
            if (*p == '\n') { px = x0; py += 10 * sc; continue; }
            for (int r = 0; r < 8; r++)
                for (int c = 0; c < 8; c++)
                    if (on(*p, r, c))
                        for (int dy = 0; dy < sc; dy++)
                            for (int dx = 0; dx < sc; dx++) {
                                int X = px + ox + c * sc + dx, Y = py + oy + r * sc + dy;
                                if (X >= 0 && X < w && Y >= 0 && Y < h) img[Y * w + X] = pass ? FG : SH;
                            }
            px += 8 * sc;
        }
    }
}

static int check(const char *name, int w, int h, int x, int y, const char *s, int sc)
{
    uint32_t *got = malloc(w * h * 4), *want = malloc(w * h * 4);
    for (int i = 0; i < w * h; i++) got[i] = want[i] = BG;
    pl_draw_text(got, w, h, x, y, s, FG, sc);
    expect(want, w, h, x, y, s, sc);
    int diff = 0, fg = 0, sh = 0;
    for (int i = 0; i < w * h; i++) {
        diff += got[i] != want[i];
        fg += got[i] == FG;
        sh += got[i] == SH;
    }
    printf("  %-34s %3dx%-3d scale %d: %4d text px, %4d shadow px, %d differing  %s\n", name, w, h, sc,
           fg, sh, diff, diff ? "FAIL" : "OK");
    if (diff && w <= 80) {
        for (int Y = 0; Y < h; Y++) {
            for (int X = 0; X < w; X++)
                putchar(got[Y * w + X] == FG ? '#' : got[Y * w + X] == SH ? 's' : '.');
            putchar(' ');
            for (int X = 0; X < w; X++)
                putchar(want[Y * w + X] == FG ? '#' : want[Y * w + X] == SH ? 's' : '.');
            putchar('\n');
        }
    }
    free(got); free(want);
    return diff != 0 || fg == 0;
}

int main(void)
{
    int f = 0;
    f += check("\"FPS 60.0\"", 80, 12, 2, 2, "FPS 60.0", 1);
    f += check("\"FPS 60.0\\nK=9\" (newline)", 80, 24, 1, 1, "FPS 60.0\nK=9", 1);
    f += check("\"FPS 60.0\" at scale 2", 140, 20, 2, 2, "FPS 60.0", 2);
    f += check("\"K=96\" clipped right and bottom", 30, 12, 3, 6, "K=96", 1);
    f += check("\"60\" clipped at scale 2", 25, 13, 4, 2, "60", 2);
    puts(f ? "OVERLAY TESTS FAILED" : "ALL OVERLAY TESTS PASSED");
    return f != 0;
}
