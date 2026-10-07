/* Append-only log at <game>/conquest.log. Safe to call from any thread. */
#include <windows.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "log.h"

static CRITICAL_SECTION g_log_lock;
static char g_dir[MAX_PATH];
static char g_path[MAX_PATH];

const char *game_dir(void)
{
	return g_dir;
}

void log_init(void)
{
	char *slash;
	FILE *f;

	InitializeCriticalSection(&g_log_lock);
	GetModuleFileNameA(NULL, g_dir, sizeof(g_dir));
	slash = strrchr(g_dir, '\\');
	if (slash)
		slash[1] = '\0';
	snprintf(g_path, sizeof(g_path), "%sconquest.log", g_dir);

	/* start each session with a fresh log */
	f = fopen(g_path, "w");
	if (f)
		fclose(f);
}

void log_printf(const char *fmt, ...)
{
	SYSTEMTIME t;
	va_list ap;
	FILE *f;

	EnterCriticalSection(&g_log_lock);
	f = fopen(g_path, "a");
	if (f) {
		GetLocalTime(&t);
		fprintf(f, "%02u:%02u:%02u.%03u ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
		va_start(ap, fmt);
		vfprintf(f, fmt, ap);
		va_end(ap);
		fputc('\n', f);
		fclose(f);
	}
	LeaveCriticalSection(&g_log_lock);
}
