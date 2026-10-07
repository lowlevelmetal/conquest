/*
 * Local test copies only: CONQUEST_WINDOW=x,y,w,h (set by tools/run_pair.sh)
 * keeps the game in a window of that size and place, so two copies on one
 * screen stay visible side by side and can be screenshotted. Battlefront.exe
 * creates the SDL window; both it and Battlefront2.dll later resize it or
 * switch it to fullscreen from the video settings, so those calls are pinned
 * to the test geometry too. The game's event loop treats focus loss, the
 * mouse leaving the window and minimizing like a deactivation; the copy that
 * is not in front would get those constantly, so they are hidden from it.
 */
#include <windows.h>
#include <stdio.h>

#include "iat.h"
#include "log.h"

#define SDL_WINDOW_FULLSCREEN_DESKTOP 0x1001u   /* includes SDL_WINDOW_FULLSCREEN */

typedef void *(*CreateWindow_fn)(const char *, int, int, int, int, unsigned);
typedef int (*SetWindowFullscreen_fn)(void *, unsigned);
typedef void (*SetWindowSize_fn)(void *, int, int);
typedef void (*SetWindowPosition_fn)(void *, int, int);
typedef int (*PollEvent_fn)(void *);

static CreateWindow_fn real_CreateWindow;
static SetWindowFullscreen_fn real_SetWindowFullscreen;
static SetWindowSize_fn real_SetWindowSize;
static SetWindowPosition_fn real_SetWindowPosition;
static PollEvent_fn real_PollEvent;
static int g_x, g_y, g_w, g_h;
static int g_enabled;

static void *hook_CreateWindow(const char *title, int x, int y, int w, int h, unsigned flags)
{
	log_printf("testwin: window %dx%d at %d,%d flags %#x -> %dx%d at %d,%d windowed",
	           w, h, x, y, flags, g_w, g_h, g_x, g_y);
	return real_CreateWindow(title, g_x, g_y, g_w, g_h, flags & ~SDL_WINDOW_FULLSCREEN_DESKTOP);
}

static int hook_SetWindowFullscreen(void *window, unsigned flags)
{
	return real_SetWindowFullscreen(window, flags & ~SDL_WINDOW_FULLSCREEN_DESKTOP);
}

static void hook_SetWindowSize(void *window, int w, int h)
{
	(void)w;
	(void)h;
	real_SetWindowSize(window, g_w, g_h);
}

static void hook_SetWindowPosition(void *window, int x, int y)
{
	(void)x;
	(void)y;
	real_SetWindowPosition(window, g_x, g_y);
}

#define SDL_WINDOWEVENT 0x200u
#define SDL_WINDOWEVENT_EXPOSED 3
#define SDL_WINDOWEVENT_MINIMIZED 7
#define SDL_WINDOWEVENT_LEAVE 11
#define SDL_WINDOWEVENT_FOCUS_LOST 13

static int hook_PollEvent(void *event)
{
	int r = real_PollEvent(event);
	if (r && event && ((unsigned *)event)[0] == SDL_WINDOWEVENT) {
		unsigned char *id = (unsigned char *)event + 12;   /* SDL_WindowEvent.event */
		if (*id == SDL_WINDOWEVENT_MINIMIZED || *id == SDL_WINDOWEVENT_LEAVE || *id == SDL_WINDOWEVENT_FOCUS_LOST)
			*id = SDL_WINDOWEVENT_EXPOSED;   /* ignored by the game */
	}
	return r;
}

static void hook_module(HMODULE mod)
{
	iat_hook(mod, "SDL.dll", "SDL_CreateWindow", (void *)hook_CreateWindow, (void **)&real_CreateWindow);
	iat_hook(mod, "SDL.dll", "SDL_SetWindowFullscreen", (void *)hook_SetWindowFullscreen, (void **)&real_SetWindowFullscreen);
	iat_hook(mod, "SDL.dll", "SDL_SetWindowSize", (void *)hook_SetWindowSize, (void **)&real_SetWindowSize);
	iat_hook(mod, "SDL.dll", "SDL_SetWindowPosition", (void *)hook_SetWindowPosition, (void **)&real_SetWindowPosition);
	iat_hook(mod, "SDL.dll", "SDL_PollEvent", (void *)hook_PollEvent, (void **)&real_PollEvent);
}

void testwin_install_exe(HMODULE exe)
{
	char spec[64];

	if (!instance_name()[0] || !GetEnvironmentVariableA("CONQUEST_WINDOW", spec, sizeof(spec)))
		return;
	if (sscanf(spec, "%d,%d,%d,%d", &g_x, &g_y, &g_w, &g_h) != 4 || g_w <= 0 || g_h <= 0) {
		log_printf("testwin: ignoring CONQUEST_WINDOW=%s", spec);
		return;
	}
	g_enabled = 1;
	hook_module(exe);
}

void testwin_install_game(HMODULE game)
{
	if (g_enabled)
		hook_module(game);
}
