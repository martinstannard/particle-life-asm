/* Stand-ins for the SDL2 functions src/arm64/main.S calls, linked only into
 * the cross-built AArch64 binary that runs the headless tests under
 * qemu-aarch64 (there is no AArch64 libSDL2 on the build host). Every one
 * fails, so the window path reports an SDL error; the headless paths
 * (--bench, --headless, --dump-frame, --list-*) never call them. The
 * native build on the Pi links the real -lSDL2 instead. */
#include <stddef.h>

static const char msg[] = "SDL2 not linked (cross build for headless tests)";
const char *SDL_GetError(void) { return msg; }
int SDL_Init(unsigned f) { (void)f; return -1; }
void SDL_Quit(void) {}
void *SDL_CreateWindow(void) { return NULL; }
void *SDL_CreateRenderer(void) { return NULL; }
void *SDL_CreateTexture(void) { return NULL; }
void *SDL_CreateRGBSurfaceWithFormatFrom(void) { return NULL; }
void *SDL_GetWindowSurface(void) { return NULL; }
int SDL_GetRendererOutputSize(void) { return -1; }
int SDL_ShowCursor(void) { return 0; }
int SDL_PollEvent(void) { return 0; }
int SDL_UpdateTexture(void) { return -1; }
int SDL_RenderCopy(void) { return -1; }
int SDL_RenderCopyEx(void) { return -1; }
void SDL_RenderPresent(void) {}
int SDL_LockSurface(void) { return -1; }
void SDL_UnlockSurface(void) {}
int SDL_UpperBlit(void) { return -1; }
int SDL_UpperBlitScaled(void) { return -1; }
int SDL_UpdateWindowSurface(void) { return -1; }
void SDL_SetWindowTitle(void) {}
void SDL_DestroyTexture(void) {}
void SDL_DestroyRenderer(void) {}
void SDL_DestroyWindow(void) {}
void SDL_FreeSurface(void) {}
