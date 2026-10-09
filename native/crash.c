/*
 * Last-chance diagnostics: log fatal exceptions (with module+offset and a short
 * stack) and normal process exit to conquest.log, so a game that vanishes
 * leaves a trace even when a crash reporter swallows the crash.
 */
#include <windows.h>
#include <stdio.h>

#include "iat.h"
#include "log.h"

static void describe(void *addr, char *buf, size_t len)
{
	HMODULE mod = NULL;
	char path[MAX_PATH] = "?";
	const char *base;

	if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
	                       (LPCSTR)addr, &mod) && mod) {
		GetModuleFileNameA(mod, path, sizeof(path));
		base = strrchr(path, '\\');
		snprintf(buf, len, "%s+%#llx", base ? base + 1 : path,
		         (unsigned long long)((char *)addr - (char *)mod));
	} else {
		snprintf(buf, len, "%p", addr);
	}
}

/*
 * A vectored handler sees every exception first, including the many the game
 * or Steam catch themselves (C++ throws among them). Each place that raises
 * one is logged once, so those cannot use up the log before a real crash.
 */
#define MAX_SITES 64

static LONG CALLBACK on_exception(EXCEPTION_POINTERS *info)
{
	static struct { DWORD code; void *addr; } sites[MAX_SITES];
	static volatile LONG nsites, busy;
	DWORD code = info->ExceptionRecord->ExceptionCode;
	void *addr = info->ExceptionRecord->ExceptionAddress;
	void *frames[24];
	char where[300];
	USHORT n;
	LONG i, count;

	/* fatal-class exceptions and C++ throws (0xE06D7363); skip debugger noise */
	if (((code & 0xF0000000u) != 0xC0000000u && code != 0xE06D7363u) || code == 0xC0000374u)
		return EXCEPTION_CONTINUE_SEARCH;
	if (InterlockedExchange(&busy, 1))
		return EXCEPTION_CONTINUE_SEARCH;   /* another thread is logging (or we faulted while logging) */
	count = nsites;
	for (i = 0; i < count; i++)
		if (sites[i].code == code && sites[i].addr == addr)
			break;
	if (i < count || count == MAX_SITES) {
		InterlockedExchange(&busy, 0);
		return EXCEPTION_CONTINUE_SEARCH;
	}
	sites[count].code = code;
	sites[count].addr = addr;
	InterlockedExchange(&nsites, count + 1);

	describe(addr, where, sizeof(where));
	if (code == EXCEPTION_ACCESS_VIOLATION && info->ExceptionRecord->NumberParameters >= 2)
		log_printf("crash: access violation (%s %#llx) at %s",
		           info->ExceptionRecord->ExceptionInformation[0] ? "write" : "read",
		           (unsigned long long)info->ExceptionRecord->ExceptionInformation[1], where);
	else
		log_printf("crash: exception %#lx at %s%s", (unsigned long)code, where,
		           code == 0xE06D7363u ? " (C++ throw, usually caught)" : "");

	/* C++ throws are nearly always caught: the place is enough */
	if (code != 0xE06D7363u) {
		n = RtlCaptureStackBackTrace(0, 24, frames, NULL);
		for (USHORT j = 0; j < n; j++) {
			describe(frames[j], where, sizeof(where));
			log_printf("crash:   #%u %s", j, where);
		}
	}
	InterlockedExchange(&busy, 0);
	return EXCEPTION_CONTINUE_SEARCH;
}

static void log_stack(const char *why)
{
	void *frames[24];
	char where[300];
	USHORT n = RtlCaptureStackBackTrace(1, 24, frames, NULL);
	log_printf("crash: %s", why);
	for (USHORT i = 0; i < n; i++) {
		describe(frames[i], where, sizeof(where));
		log_printf("crash:   #%u %s", i, where);
	}
}

typedef void (WINAPI *ExitProcess_fn)(UINT);
typedef BOOL (WINAPI *TerminateProcess_fn)(HANDLE, UINT);
typedef void (*exit_fn)(int);
static ExitProcess_fn real_ExitProcess;
static TerminateProcess_fn real_TerminateProcess;
static exit_fn real_exit, real__exit;

static void WINAPI hook_ExitProcess(UINT code)
{
	char why[64];
	snprintf(why, sizeof(why), "ExitProcess(%u)", code);
	log_stack(why);
	real_ExitProcess(code);
}

static BOOL WINAPI hook_TerminateProcess(HANDLE h, UINT code)
{
	char why[80];
	snprintf(why, sizeof(why), "TerminateProcess(%p, %u)", (void *)h, code);
	log_stack(why);
	return real_TerminateProcess(h, code);
}

static void hook_exit(int code)
{
	char why[64];
	snprintf(why, sizeof(why), "exit(%d)", code);
	log_stack(why);
	real_exit(code);
}

static void hook__exit(int code)
{
	char why[64];
	snprintf(why, sizeof(why), "_exit(%d)", code);
	log_stack(why);
	real__exit(code);
}

/* Log who ends the process: exe, game DLL and Steam API. */
void crash_hook_exits(HMODULE mod)
{
	iat_hook(mod, "KERNEL32.dll", "ExitProcess", (void *)hook_ExitProcess, (void **)&real_ExitProcess);
	iat_hook(mod, "KERNEL32.dll", "TerminateProcess", (void *)hook_TerminateProcess, (void **)&real_TerminateProcess);
	iat_hook(mod, "api-ms-win-crt-runtime-l1-1-0.dll", "exit", (void *)hook_exit, (void **)&real_exit);
	iat_hook(mod, "api-ms-win-crt-runtime-l1-1-0.dll", "_exit", (void *)hook__exit, (void **)&real__exit);
}

void crash_install(void)
{
	AddVectoredExceptionHandler(1, on_exception);
}

void crash_process_exit(void)
{
	log_printf("proxy: process exiting (thread %lu)", GetCurrentThreadId());
	log_stack("exit call chain");
}
