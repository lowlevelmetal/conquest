/*
 * Local test copies only: CONQUEST_WINDOW=x,y,w,h (set by tools/run_pair.sh)
 * keeps the game in a window of that size and place, so two copies on one
 * screen stay visible side by side and can be screenshotted. Battlefront.exe
 * creates the SDL window; both it and Battlefront2.dll later resize it or
 * switch it to fullscreen from the video settings, so those calls are pinned
 * to the test geometry too. The game's event loop treats focus loss, the
 * mouse leaving the window and minimizing like a deactivation; the copy that
 * is not in front would get those constantly, so they are hidden from it.
 *
 * Autotests can also press a key (testwin_press): a key-down event, the key
 * held in the keyboard state the game polls, and the key-up a quarter second
 * later.
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>

#include "iat.h"
#include "log.h"

#define SDL_WINDOW_FULLSCREEN_DESKTOP 0x1001u   /* includes SDL_WINDOW_FULLSCREEN */

typedef void *(*CreateWindow_fn)(const char *, int, int, int, int, unsigned);
typedef int (*SetWindowFullscreen_fn)(void *, unsigned);
typedef void (*SetWindowSize_fn)(void *, int, int);
typedef void (*SetWindowPosition_fn)(void *, int, int);
typedef int (*PollEvent_fn)(void *);
typedef const unsigned char *(*GetKeyboardState_fn)(int *);

static CreateWindow_fn real_CreateWindow;
static SetWindowFullscreen_fn real_SetWindowFullscreen;
static SetWindowSize_fn real_SetWindowSize;
static SetWindowPosition_fn real_SetWindowPosition;
static PollEvent_fn real_PollEvent;
static GetKeyboardState_fn real_GetKeyboardState;
static int g_x, g_y, g_w, g_h;
static int g_enabled;

#define SDL_KEYDOWN 0x300u
#define SDL_KEYUP   0x301u
#define PRESS_HOLD_MS 250       /* the game wants an accept held for 0.125 s */

static volatile LONG g_press;   /* 0 none, 1 key down to send, 2 key up to send */
static int g_press_scancode, g_press_sym;
static DWORD g_press_at;

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

/* SDL_KeyboardEvent: type, timestamp, windowID, state, repeat, 2 pad bytes,
 * then SDL_Keysym: scancode, sym, mod */
static int fake_key(void *event, unsigned type)
{
	unsigned char *e = event;
	memset(e, 0, 32);
	((unsigned *)e)[0] = type;
	((unsigned *)e)[1] = GetTickCount();
	e[12] = type == SDL_KEYDOWN;
	((int *)e)[4] = g_press_scancode;
	((int *)e)[5] = g_press_sym;
	return 1;
}

#define NUM_SCANCODES 512   /* SDL_NUM_SCANCODES */

static const unsigned char *hook_GetKeyboardState(int *numkeys)
{
	static unsigned char keys[NUM_SCANCODES];
	int n = 0;
	const unsigned char *real = real_GetKeyboardState(&n);
	if (g_press != 2 || g_press_scancode <= 0 || g_press_scancode >= NUM_SCANCODES || n > NUM_SCANCODES) {
		if (numkeys)
			*numkeys = n;
		return real;
	}
	memcpy(keys, real, (size_t)n);
	keys[g_press_scancode] = 1;
	if (numkeys)
		*numkeys = n;
	return keys;
}

static int hook_PollEvent(void *event)
{
	int r = real_PollEvent(event);
	if (!r && event && g_press == 1) {
		g_press = 2;
		g_press_at = GetTickCount();
		log_printf("testwin: key %d down", g_press_scancode);
		return fake_key(event, SDL_KEYDOWN);
	}
	if (!r && event && g_press == 2 && GetTickCount() - g_press_at >= PRESS_HOLD_MS) {
		g_press = 0;
		return fake_key(event, SDL_KEYUP);
	}
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
	iat_hook(mod, "SDL.dll", "SDL_GetKeyboardState", (void *)hook_GetKeyboardState, (void **)&real_GetKeyboardState);
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

/* Test copies only: press and release a key (SDL scancode and keycode). */
int testwin_press(int scancode, int sym)
{
	if (!g_enabled || g_press)
		return 0;
	g_press_scancode = scancode;
	g_press_sym = sym;
	g_press = 1;
	return 1;
}
