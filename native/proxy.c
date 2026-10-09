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

void crash_install(void);
void crash_hook_exits(HMODULE mod);
void crash_process_exit(void);
void testwin_install_exe(HMODULE exe);
void testwin_install_game(HMODULE game);

typedef HMODULE (WINAPI *LoadLibraryA_t)(LPCSTR);
typedef FARPROC (WINAPI *GetProcAddress_t)(HMODULE, LPCSTR);
typedef INT_PTR (*GameWinMain_t)(void *, void *, void *, void *, void *, int, void *);
typedef HMODULE (WINAPI *LoadLibraryW_t)(LPCWSTR);
typedef HMODULE (WINAPI *LoadLibraryExA_t)(LPCSTR, HANDLE, DWORD);
typedef HMODULE (WINAPI *LoadLibraryExW_t)(LPCWSTR, HANDLE, DWORD);
typedef BOOL (WINAPI *FreeLibrary_t)(HMODULE);

/* Lets dist/install.bat tell this loader from Aspyr's DLL with findstr. On a
 * line of its own, so a line-based search finds it inside a binary file. */
__attribute__((used)) static const char g_loader_marker[] = "\r\nOnlineGalacticConquestLoader\r\n";

static LoadLibraryA_t real_LoadLibraryA;
static LoadLibraryW_t real_LoadLibraryW;
static LoadLibraryExA_t real_LoadLibraryExA;
static LoadLibraryExW_t real_LoadLibraryExW;
static FreeLibrary_t real_FreeLibrary;
static volatile LONG g_patched;
static HMODULE g_bf2;
static GetProcAddress_t real_GetProcAddress;
static GameWinMain_t real_GameWinMain;

/* log why the game returns to the launcher (200 = back to game select) */
static INT_PTR wrap_GameWinMain(void *a, void *b, void *c, void *d, void *e, int f, void *g)
{
	INT_PTR r;
	log_printf("proxy: GameWinMain starting");
	r = real_GameWinMain(a, b, c, d, e, f, g);
	log_printf("proxy: GameWinMain returned %lld", (long long)r);
	return r;
}

static FARPROC WINAPI hook_GetProcAddress(HMODULE mod, LPCSTR name)
{
	FARPROC p = real_GetProcAddress(mod, name);
	if (p && (ULONG_PTR)name > 0xFFFF && !strcmp(name, "GameWinMain")) {
		real_GameWinMain = (GameWinMain_t)(void *)p;
		return (FARPROC)(void *)wrap_GameWinMain;
	}
	return p;
}

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
	g_bf2 = mod;
	log_printf("proxy: Battlefront2.dll loaded at %p", (void *)mod);
	crash_hook_exits(mod);
	crash_hook_exits(GetModuleHandleA("steam_api64.dll"));
	testwin_install_game(mod);
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

/* "Back to game select" unloads Battlefront2.dll, and choosing a game loads
 * it again: a fresh copy that must be patched again. */
static BOOL WINAPI hook_FreeLibrary(HMODULE mod)
{
	BOOL r;
	int ours = g_patched && mod && mod == g_bf2;
	r = real_FreeLibrary(mod);
	if (ours && !GetModuleHandleA("Battlefront2.dll")) {
		log_printf("proxy: Battlefront2.dll unloaded; it will be patched again when it loads");
		bridge_unload();
		shim_unload();
		game_unload();
		g_bf2 = NULL;
		InterlockedExchange(&g_patched, 0);
	}
	return r;
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
		{ "GetProcAddress", (void *)hook_GetProcAddress, (void **)&real_GetProcAddress },
		{ "FreeLibrary",    (void *)hook_FreeLibrary,    (void **)&real_FreeLibrary },
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

/*
 * Battlefront.exe calls startCrashpad once at startup. Forward it to Aspyr's
 * original. Test copies (CONQUEST_INSTANCE set) skip the crash reporter so a
 * crash prints Wine's diagnostics instead of exiting silently.
 * Signature: bool startCrashpad(const char*, const char*, const char*,
 *            const char* const*, size_t, const std::map<string,string>&)
 */
typedef unsigned char (*startCrashpad_t)(void *, void *, void *, void *, size_t, void *);

unsigned char conquest_startCrashpad(void *a, void *b, void *c, void *d, size_t e, void *f)
{
	static const char name[] =
		"?startCrashpad@@YA_NPEBD00QEAPEBD_KAEBV?$map@V?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@"
		"V12@U?$less@V?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@@2@V?$allocator@U?$pair@$$CBV?$"
		"basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@V12@@std@@@2@@std@@@Z";
	HMODULE orig;
	startCrashpad_t fn;

	if (instance_name()[0]) {
		log_printf("proxy: test instance, crash reporter disabled");
		return 0;
	}
	orig = LoadLibraryA("dle_crashpad_orig.dll");
	fn = orig ? (startCrashpad_t)(void *)GetProcAddress(orig, name) : NULL;
	if (!fn) {
		log_printf("proxy: dle_crashpad_orig.dll unavailable; crash reporting off");
		return 0;
	}
	return fn(a, b, c, d, e, f);
}

/*
 * Under Proton, vkd3d-proton (D3D12 on Vulkan) can crash in
 * vkGetPastPresentationTimingEXT after a swapchain is recreated, which the
 * game does on every shell <-> battle switch. vkd3d-proton reads its settings
 * when the game creates its D3D12 device, after this DLL loads, so steer it
 * away from that extension unless the player configured it themselves.
 */
static void avoid_proton_present_timing_crash(void)
{
	char existing[8];
	if (!GetProcAddress(GetModuleHandleA("ntdll.dll"), "wine_get_version"))
		return;   /* real Windows: native D3D12 */
	if (GetEnvironmentVariableA("VKD3D_DISABLE_EXTENSIONS", existing, sizeof(existing)))
		return;
	SetEnvironmentVariableA("VKD3D_DISABLE_EXTENSIONS", "VK_EXT_present_timing");
	log_printf("proxy: Wine detected; disabled vkd3d-proton present timing");
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
	(void)reserved;
	if (reason == DLL_PROCESS_ATTACH) {
		DisableThreadLibraryCalls(inst);
		log_init();
		log_printf("proxy: conquest loader attached");
		crash_install();
		crash_hook_exits(GetModuleHandleA(NULL));
		avoid_proton_present_timing_crash();
		hook_imports(GetModuleHandleA(NULL));
		testwin_install_exe(GetModuleHandleA(NULL));
		on_loaded(GetModuleHandleA("Battlefront2.dll"));
	} else if (reason == DLL_PROCESS_DETACH) {
		crash_process_exit();
	}
	return TRUE;
}
