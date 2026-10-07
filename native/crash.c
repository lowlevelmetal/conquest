/*
 * Last-chance diagnostics: log fatal exceptions (with module+offset and a short
 * stack) and normal process exit to conquest.log, so a game that vanishes
 * leaves a trace even when a crash reporter swallows the crash.
 */
#include <windows.h>
#include <stdio.h>

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

static LONG CALLBACK on_exception(EXCEPTION_POINTERS *info)
{
	static volatile LONG reported;
	DWORD code = info->ExceptionRecord->ExceptionCode;
	void *frames[24];
	char where[300];
	USHORT n;

	/* fatal-class exceptions and C++ throws (0xE06D7363); skip debugger noise */
	if (((code & 0xF0000000u) != 0xC0000000u && code != 0xE06D7363u) || code == 0xC0000374u)
		return EXCEPTION_CONTINUE_SEARCH;
	if (InterlockedIncrement(&reported) > 3)
		return EXCEPTION_CONTINUE_SEARCH;

	describe(info->ExceptionRecord->ExceptionAddress, where, sizeof(where));
	if (code == EXCEPTION_ACCESS_VIOLATION && info->ExceptionRecord->NumberParameters >= 2)
		log_printf("crash: access violation (%s %#llx) at %s",
		           info->ExceptionRecord->ExceptionInformation[0] ? "write" : "read",
		           (unsigned long long)info->ExceptionRecord->ExceptionInformation[1], where);
	else
		log_printf("crash: exception %#lx at %s", (unsigned long)code, where);

	n = RtlCaptureStackBackTrace(0, 24, frames, NULL);
	for (USHORT i = 0; i < n; i++) {
		describe(frames[i], where, sizeof(where));
		log_printf("crash:   #%u %s", i, where);
	}
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

/* Replace one named import of `mod` (case-insensitive DLL match). */
static void hook_import(HMODULE mod, const char *dll, const char *func, void *hook, void **real)
{
	BYTE *base = (BYTE *)mod;
	IMAGE_NT_HEADERS *nt;
	IMAGE_IMPORT_DESCRIPTOR *imp;

	if (!mod)
		return;
	nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
	imp = (IMAGE_IMPORT_DESCRIPTOR *)(base + nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress);
	for (; imp->Name; imp++) {
		IMAGE_THUNK_DATA *names, *iat;
		if (_stricmp((const char *)(base + imp->Name), dll) || !imp->OriginalFirstThunk)
			continue;
		names = (IMAGE_THUNK_DATA *)(base + imp->OriginalFirstThunk);
		iat = (IMAGE_THUNK_DATA *)(base + imp->FirstThunk);
		for (; names->u1.AddressOfData; names++, iat++) {
			DWORD old;
			if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal) ||
			    strcmp((const char *)((IMAGE_IMPORT_BY_NAME *)(base + names->u1.AddressOfData))->Name, func))
				continue;
			if (!*real)
				*real = (void *)iat->u1.Function;
			VirtualProtect(&iat->u1.Function, sizeof(iat->u1.Function), PAGE_READWRITE, &old);
			iat->u1.Function = (ULONG_PTR)hook;
			VirtualProtect(&iat->u1.Function, sizeof(iat->u1.Function), old, &old);
		}
	}
}

/* Log who ends the process: exe, game DLL and Steam API. */
void crash_hook_exits(HMODULE mod)
{
	hook_import(mod, "KERNEL32.dll", "ExitProcess", (void *)hook_ExitProcess, (void **)&real_ExitProcess);
	hook_import(mod, "KERNEL32.dll", "TerminateProcess", (void *)hook_TerminateProcess, (void **)&real_TerminateProcess);
	hook_import(mod, "api-ms-win-crt-runtime-l1-1-0.dll", "exit", (void *)hook_exit, (void **)&real_exit);
	hook_import(mod, "api-ms-win-crt-runtime-l1-1-0.dll", "_exit", (void *)hook__exit, (void **)&real__exit);
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
