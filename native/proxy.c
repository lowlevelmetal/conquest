/*
 * Stand-in for Aspyr's dle_crashpad.dll.
 *
 * Battlefront.exe imports a single function (startCrashpad) from
 * dle_crashpad.dll; exports.def forwards it to the renamed original
 * dle_crashpad_orig.dll. Loading early lets us hook the launcher's
 * LoadLibrary calls and patch Battlefront2.dll before GameWinMain runs.
 */
#include <windows.h>
#include <string.h>

#include "game.h"
#include "log.h"
#include "shim.h"

typedef HMODULE (WINAPI *LoadLibraryA_t)(LPCSTR);
typedef HMODULE (WINAPI *LoadLibraryW_t)(LPCWSTR);
typedef HMODULE (WINAPI *LoadLibraryExA_t)(LPCSTR, HANDLE, DWORD);
typedef HMODULE (WINAPI *LoadLibraryExW_t)(LPCWSTR, HANDLE, DWORD);

static LoadLibraryA_t real_LoadLibraryA;
static LoadLibraryW_t real_LoadLibraryW;
static LoadLibraryExA_t real_LoadLibraryExA;
static LoadLibraryExW_t real_LoadLibraryExW;
static volatile LONG g_patched;

static void on_loaded(HMODULE mod)
{
	char path[MAX_PATH];
	const char *base;

	if (!mod || g_patched)
		return;
	GetModuleFileNameA(mod, path, sizeof(path));
	base = strrchr(path, '\\');
	base = base ? base + 1 : path;
	if (_stricmp(base, "Battlefront2.dll"))
		return;
	if (InterlockedExchange(&g_patched, 1))
		return;
	log_printf("proxy: Battlefront2.dll loaded at %p", (void *)mod);
	if (!game_patch(mod))
		log_printf("proxy: patching failed; online conquest is disabled");
	if (!shim_install(mod))
		log_printf("proxy: Winsock shim incomplete; joining by IP will not work");
}

static HMODULE WINAPI hook_LoadLibraryA(LPCSTR name)
{
	HMODULE m = real_LoadLibraryA(name);
	on_loaded(m);
	return m;
}

static HMODULE WINAPI hook_LoadLibraryW(LPCWSTR name)
{
	HMODULE m = real_LoadLibraryW(name);
	on_loaded(m);
	return m;
}

static HMODULE WINAPI hook_LoadLibraryExA(LPCSTR name, HANDLE file, DWORD flags)
{
	HMODULE m = real_LoadLibraryExA(name, file, flags);
	on_loaded(m);
	return m;
}

static HMODULE WINAPI hook_LoadLibraryExW(LPCWSTR name, HANDLE file, DWORD flags)
{
	HMODULE m = real_LoadLibraryExW(name, file, flags);
	on_loaded(m);
	return m;
}

/* Replace imports by name in the executable's import table. */
static void hook_imports(HMODULE exe)
{
	static const struct {
		const char *name;
		void *hook;
		void **real;
	} hooks[] = {
		{ "LoadLibraryA",   (void *)hook_LoadLibraryA,   (void **)&real_LoadLibraryA },
		{ "LoadLibraryW",   (void *)hook_LoadLibraryW,   (void **)&real_LoadLibraryW },
		{ "LoadLibraryExA", (void *)hook_LoadLibraryExA, (void **)&real_LoadLibraryExA },
		{ "LoadLibraryExW", (void *)hook_LoadLibraryExW, (void **)&real_LoadLibraryExW },
	};
	BYTE *base = (BYTE *)exe;
	IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
	IMAGE_DATA_DIRECTORY dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
	IMAGE_IMPORT_DESCRIPTOR *imp = (IMAGE_IMPORT_DESCRIPTOR *)(base + dir.VirtualAddress);
	int count = 0;

	for (; imp->Name; imp++) {
		IMAGE_THUNK_DATA *names, *iat;
		if (!imp->OriginalFirstThunk)
			continue;
		names = (IMAGE_THUNK_DATA *)(base + imp->OriginalFirstThunk);
		iat = (IMAGE_THUNK_DATA *)(base + imp->FirstThunk);
		for (; names->u1.AddressOfData; names++, iat++) {
			IMAGE_IMPORT_BY_NAME *ibn;
			if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal))
				continue;
			ibn = (IMAGE_IMPORT_BY_NAME *)(base + names->u1.AddressOfData);
			for (size_t i = 0; i < sizeof(hooks) / sizeof(hooks[0]); i++) {
				DWORD old;
				if (strcmp((const char *)ibn->Name, hooks[i].name))
					continue;
				*hooks[i].real = (void *)iat->u1.Function;
				VirtualProtect(&iat->u1.Function, sizeof(iat->u1.Function), PAGE_READWRITE, &old);
				iat->u1.Function = (ULONG_PTR)hooks[i].hook;
				VirtualProtect(&iat->u1.Function, sizeof(iat->u1.Function), old, &old);
				count++;
			}
		}
	}
	log_printf("proxy: hooked %d LoadLibrary imports", count);
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
	(void)reserved;
	if (reason == DLL_PROCESS_ATTACH) {
		DisableThreadLibraryCalls(inst);
		log_init();
		log_printf("proxy: conquest loader attached");
		hook_imports(GetModuleHandleA(NULL));
		on_loaded(GetModuleHandleA("Battlefront2.dll"));
	}
	return TRUE;
}
