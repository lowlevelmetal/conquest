/*
 * Windows setup for Online Galactic Conquest: one self-contained exe that
 * finds the game's Steam folder and writes the loader (dle_crashpad.dll) and
 * conquest\ from its payload resource (built by pack.py), or removes them.
 *
 *   OnlineGalacticConquest-Setup.exe                          dialog
 *   OnlineGalacticConquest-Setup.exe /install [game folder]   errors in a message box
 *   OnlineGalacticConquest-Setup.exe /uninstall [game folder]
 *   add /quiet to report errors on stderr only; the exit code is 1 on failure
 *
 * Like dist/install.bat, install keeps Aspyr's crash reporter as
 * dle_crashpad_orig.dll for the loader to forward to.
 */
#define COBJMACROS
#include <windows.h>
#include <commctrl.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <shobjidl.h>
#include <tlhelp32.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

#include "../version.h"
#include "resource.h"

#define WIDEN2(s) L##s
#define WIDEN(s) WIDEN2(s)
#define VERSION_W WIDEN(CONQUEST_VERSION)
#define CAPTION L"Online Galactic Conquest Setup"
#define STEAM_APP_ID L"2446550"
#define PATHLEN 1024

/* in our dle_crashpad.dll (it loads Aspyr's original by this name), never in Aspyr's */
static const char LOADER_MARKER[] = "dle_crashpad_orig";

static wchar_t g_error[2048];
static const BYTE *g_payload;
static DWORD g_payload_size;
static HFONT g_title_font;
static HICON g_header_icon;
static BOOL g_activated;

/* ---- helpers ---------------------------------------------------------- */

static BOOL fmt(wchar_t *out, size_t cap, const wchar_t *f, ...)
{
	va_list ap;
	int n;

	va_start(ap, f);
	n = _vsnwprintf(out, cap, f, ap);
	va_end(ap);
	if (n < 0 || (size_t)n >= cap) {
		out[cap - 1] = 0;
		return FALSE;
	}
	return TRUE;
}
#define PATHF(out, ...) fmt(out, ARRAYSIZE(out), __VA_ARGS__)

/* Set g_error (plus Windows' text for `code`, if any) and return FALSE. */
static BOOL fail(DWORD code, const wchar_t *f, ...)
{
	va_list ap;
	size_t len;

	va_start(ap, f);
	_vsnwprintf(g_error, ARRAYSIZE(g_error) - 1, f, ap);
	va_end(ap);
	g_error[ARRAYSIZE(g_error) - 1] = 0;
	len = wcslen(g_error);
	if (code && len + 3 < ARRAYSIZE(g_error)) {
		wcscpy(g_error + len, L"\n\n");
		len += 2;
		if (FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, code, 0,
		                   g_error + len, (DWORD)(ARRAYSIZE(g_error) - len), NULL)) {
			len = wcslen(g_error);
			while (len && (g_error[len - 1] == L'\r' || g_error[len - 1] == L'\n'))
				g_error[--len] = 0;
		} else {
			fmt(g_error + len, ARRAYSIZE(g_error) - len, L"Error %lu.", code);
		}
	}
	return FALSE;
}

static BOOL is_file(const wchar_t *path)
{
	DWORD attr = GetFileAttributesW(path);
	return attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY);
}

/* Whole file plus a terminating NUL, or NULL; HeapFree the result. */
static char *read_file(const wchar_t *path, DWORD *size)
{
	HANDLE f = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
	                       NULL, OPEN_EXISTING, 0, NULL);
	LARGE_INTEGER len;
	DWORD got = 0;
	char *buf = NULL;

	if (f == INVALID_HANDLE_VALUE)
		return NULL;
	if (GetFileSizeEx(f, &len) && len.QuadPart < 64 * 1024 * 1024 &&
	    (buf = HeapAlloc(GetProcessHeap(), 0, (SIZE_T)len.QuadPart + 1)) != NULL &&
	    ReadFile(f, buf, (DWORD)len.QuadPart, &got, NULL) && got == (DWORD)len.QuadPart) {
		buf[got] = 0;
		if (size)
			*size = got;
	} else if (buf) {
		HeapFree(GetProcessHeap(), 0, buf);
		buf = NULL;
	}
	CloseHandle(f);
	return buf;
}

static BOOL is_loader(const wchar_t *path)
{
	size_t n = sizeof(LOADER_MARKER) - 1;
	DWORD size = 0, i;
	char *buf = read_file(path, &size);
	BOOL found = FALSE;

	if (!buf)
		return FALSE;
	for (i = 0; !found && i + n <= size; i++)
		found = buf[i] == LOADER_MARKER[0] && !memcmp(buf + i, LOADER_MARKER, n);
	HeapFree(GetProcessHeap(), 0, buf);
	return found;
}

static BOOL make_parent_dirs(const wchar_t *file)
{
	wchar_t path[PATHLEN], *p;
	DWORD attr, err = 0;

	if (!PATHF(path, L"%ls", file))
		return fail(0, L"The path is too long:\n%ls", file);
	p = path + 1;
	if (path[0] == L'\\' && path[1] == L'\\') {
		/* skip \\server\share\ */
		int seps = 0;
		for (p = path + 2; *p && seps < 2; p++)
			seps += *p == L'\\';
	}
	for (; *p; p++) {
		if (*p != L'\\' || p[-1] == L':')
			continue;
		*p = 0;
		if (!CreateDirectoryW(path, NULL))
			err = GetLastError();
		attr = GetFileAttributesW(path);
		if (attr == INVALID_FILE_ATTRIBUTES || !(attr & FILE_ATTRIBUTE_DIRECTORY))
			return fail(err, L"Could not create the folder %ls.", path);
		*p = L'\\';
	}
	return TRUE;
}

/* Write through a temporary file so a failure never leaves half a file. */
static BOOL write_file(const wchar_t *path, const void *data, DWORD size)
{
	wchar_t tmp[PATHLEN];
	HANDLE f;
	DWORD wrote = 0, err;
	BOOL ok;

	if (!PATHF(tmp, L"%ls.new", path))
		return fail(0, L"The path is too long:\n%ls", path);
	if (!make_parent_dirs(path))
		return FALSE;
	f = CreateFileW(tmp, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
	if (f == INVALID_HANDLE_VALUE)
		return fail(GetLastError(), L"Could not write %ls.", path);
	ok = WriteFile(f, data, size, &wrote, NULL) && wrote == size;
	err = GetLastError();
	CloseHandle(f);
	if (ok && !MoveFileExW(tmp, path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
		ok = FALSE;
		err = GetLastError();
	}
	if (!ok) {
		DeleteFileW(tmp);
		return fail(err, L"Could not write %ls.", path);
	}
	return TRUE;
}

/* Delete a file, or a folder and everything in it. A missing one is fine. */
static BOOL delete_tree(const wchar_t *path)
{
	DWORD attr = GetFileAttributesW(path), err = GetLastError();
	BOOL ok;

	if (attr == INVALID_FILE_ATTRIBUTES) {
		if (err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND)
			return TRUE;
		return fail(err, L"Could not remove %ls.", path);
	}
	if (attr & FILE_ATTRIBUTE_READONLY)
		SetFileAttributesW(path, attr & ~FILE_ATTRIBUTE_READONLY);
	if ((attr & FILE_ATTRIBUTE_DIRECTORY) && !(attr & FILE_ATTRIBUTE_REPARSE_POINT)) {
		wchar_t pattern[PATHLEN], child[PATHLEN];
		WIN32_FIND_DATAW fd;
		HANDLE h;

		if (!PATHF(pattern, L"%ls\\*", path))
			return fail(0, L"The path is too long:\n%ls", path);
		h = FindFirstFileW(pattern, &fd);
		if (h != INVALID_HANDLE_VALUE) {
			do {
				if (!wcscmp(fd.cFileName, L".") || !wcscmp(fd.cFileName, L".."))
					continue;
				if (!PATHF(child, L"%ls\\%ls", path, fd.cFileName)) {
					FindClose(h);
					return fail(0, L"The path is too long:\n%ls", child);
				}
				if (!delete_tree(child)) {
					FindClose(h);
					return FALSE;
				}
			} while (FindNextFileW(h, &fd));
			FindClose(h);
		}
	}
	ok = (attr & FILE_ATTRIBUTE_DIRECTORY) ? RemoveDirectoryW(path) : DeleteFileW(path);
	return ok ? TRUE : fail(GetLastError(), L"Could not remove %ls.", path);
}

/* Trim blanks and quotes, make absolute, drop a trailing backslash. */
static void normalize_dir(const wchar_t *in, wchar_t *out, DWORD cap)
{
	wchar_t tmp[PATHLEN];
	size_t len;
	DWORD n;

	while (*in == L' ' || *in == L'\t' || *in == L'"')
		in++;
	lstrcpynW(tmp, in, ARRAYSIZE(tmp));
	len = wcslen(tmp);
	while (len && (tmp[len - 1] == L' ' || tmp[len - 1] == L'\t' || tmp[len - 1] == L'"'))
		tmp[--len] = 0;
	out[0] = 0;
	if (!len)
		return;
	n = GetFullPathNameW(tmp, cap, out, NULL);
	if (!n || n >= cap)
		lstrcpynW(out, tmp, cap);
	len = wcslen(out);
	while (len > 3 && (out[len - 1] == L'\\' || out[len - 1] == L'/'))
		out[--len] = 0;
}

/* ---- payload ---------------------------------------------------------- */

/* b"CGC1", then per file: u16 path length, UTF-8 path, u32 size, bytes */
struct entry {
	wchar_t path[MAX_PATH];
	const BYTE *data;
	DWORD size;
};

static BOOL load_payload(void)
{
	HRSRC res;
	HGLOBAL mem;

	if (g_payload)
		return TRUE;
	res = FindResourceW(NULL, MAKEINTRESOURCEW(IDR_PAYLOAD), RT_RCDATA);
	mem = res ? LoadResource(NULL, res) : NULL;
	g_payload = mem ? LockResource(mem) : NULL;
	g_payload_size = res ? SizeofResource(NULL, res) : 0;
	if (!g_payload || g_payload_size < 4 || memcmp(g_payload, "CGC1", 4)) {
		g_payload = NULL;
		return fail(0, L"This setup program is damaged. Download it again.");
	}
	return TRUE;
}

/* *pos starts at 0. Paths come back with backslashes. */
static BOOL next_entry(DWORD *pos, struct entry *e)
{
	DWORD p = *pos ? *pos : 4;
	WORD len;
	int n;
	wchar_t *c;

	if (p + 2 > g_payload_size)
		return FALSE;
	memcpy(&len, g_payload + p, 2);
	p += 2;
	if (p + len + 4 > g_payload_size)
		return FALSE;
	n = MultiByteToWideChar(CP_UTF8, 0, (const char *)g_payload + p, len, e->path, ARRAYSIZE(e->path) - 1);
	e->path[n] = 0;
	for (c = e->path; *c; c++)
		if (*c == L'/')
			*c = L'\\';
	p += len;
	memcpy(&e->size, g_payload + p, 4);
	p += 4;
	if (e->size > g_payload_size - p)
		return FALSE;
	e->data = g_payload + p;
	*pos = p + e->size;
	return TRUE;
}

/* ---- finding the game ------------------------------------------------- */

static BOOL is_game_dir(const wchar_t *dir)
{
	wchar_t a[PATHLEN], b[PATHLEN];

	return dir[0] && PATHF(a, L"%ls\\Battlefront2.dll", dir) && PATHF(b, L"%ls\\Battlefront.exe", dir) &&
	       is_file(a) && is_file(b);
}

static BOOL try_dir(const wchar_t *candidate, wchar_t *out)
{
	wchar_t dir[PATHLEN];

	normalize_dir(candidate, dir, ARRAYSIZE(dir));
	if (!is_game_dir(dir))
		return FALSE;
	lstrcpynW(out, dir, PATHLEN);
	return TRUE;
}

/* Next quoted string of a Valve KeyValues text file, unescaped in place. */
static char *vdf_next(char **cursor)
{
	char *s = *cursor, *start, *out;

	while (*s && *s != '"')
		s++;
	if (!*s)
		return NULL;
	start = out = ++s;
	while (*s && *s != '"') {
		if (*s == '\\' && s[1])
			s++;
		*out++ = *s++;
	}
	if (*s)
		s++;
	*out = 0;
	*cursor = s;
	return start;
}

/* The game inside one Steam library, named by the app's manifest. */
static BOOL try_library(const wchar_t *lib, wchar_t *out)
{
	wchar_t path[PATHLEN], installdir[MAX_PATH] = L"Battle";
	char *text, *p, *tok;

	if (PATHF(path, L"%ls\\steamapps\\appmanifest_" STEAM_APP_ID L".acf", lib) && (text = read_file(path, NULL))) {
		for (p = text; (tok = vdf_next(&p)) != NULL;) {
			if (!_stricmp(tok, "installdir")) {
				if ((tok = vdf_next(&p)) && *tok)
					MultiByteToWideChar(CP_UTF8, 0, tok, -1, installdir, ARRAYSIZE(installdir));
				break;
			}
		}
		HeapFree(GetProcessHeap(), 0, text);
	}
	return PATHF(path, L"%ls\\steamapps\\common\\%ls", lib, installdir) && try_dir(path, out);
}

/* The game in any library of the Steam installation at `steam`. */
static BOOL try_steam(const wchar_t *steam, wchar_t *out)
{
	wchar_t path[PATHLEN], lib[PATHLEN];
	char *text, *p, *tok;
	BOOL found = FALSE;

	if (try_library(steam, out))
		return TRUE;
	if (!PATHF(path, L"%ls\\steamapps\\libraryfolders.vdf", steam) || !(text = read_file(path, NULL)))
		return FALSE;
	for (p = text; !found && (tok = vdf_next(&p)) != NULL;) {
		if (_stricmp(tok, "path") || !(tok = vdf_next(&p)))
			continue;
		if (MultiByteToWideChar(CP_UTF8, 0, tok, -1, lib, ARRAYSIZE(lib)))
			found = try_library(lib, out);
	}
	HeapFree(GetProcessHeap(), 0, text);
	return found;
}

static BOOL reg_path(HKEY root, const wchar_t *key, const wchar_t *name, wchar_t *out)
{
	DWORD size = PATHLEN * sizeof(wchar_t);
	wchar_t *c;

	if (RegGetValueW(root, key, name, RRF_RT_REG_SZ, NULL, out, &size) != ERROR_SUCCESS)
		return FALSE;
	for (c = out; *c; c++)
		if (*c == L'/')
			*c = L'\\';
	return TRUE;
}

static BOOL find_game(wchar_t *out)
{
	static const struct {
		HKEY root;
		const wchar_t *key, *name;
	} steam[] = {
		{ HKEY_CURRENT_USER, L"Software\\Valve\\Steam", L"SteamPath" },
		{ HKEY_LOCAL_MACHINE, L"SOFTWARE\\WOW6432Node\\Valve\\Steam", L"InstallPath" },
		{ HKEY_LOCAL_MACHINE, L"SOFTWARE\\Valve\\Steam", L"InstallPath" },
	};
	static const wchar_t *uninstall[] = {
		L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Steam App " STEAM_APP_ID,
		L"SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Steam App " STEAM_APP_ID,
	};
	wchar_t path[PATHLEN], *slash;
	size_t i;

	/* setup run from inside the game folder */
	if (GetModuleFileNameW(NULL, path, ARRAYSIZE(path)) && (slash = wcsrchr(path, L'\\')) != NULL) {
		*slash = 0;
		if (try_dir(path, out))
			return TRUE;
	}
	for (i = 0; i < ARRAYSIZE(uninstall); i++)
		if (reg_path(HKEY_LOCAL_MACHINE, uninstall[i], L"InstallLocation", path) && try_dir(path, out))
			return TRUE;
	for (i = 0; i < ARRAYSIZE(steam); i++)
		if (reg_path(steam[i].root, steam[i].key, steam[i].name, path) && try_steam(path, out))
			return TRUE;
	return try_steam(L"C:\\Program Files (x86)\\Steam", out);
}

/* ---- install / uninstall ---------------------------------------------- */

enum mod_state { MOD_ABSENT, MOD_INSTALLED, MOD_PARTIAL };

/* `version` gets the installed version, or "" if it predates version.txt. */
static enum mod_state mod_state(const wchar_t *dir, wchar_t *version, int cap)
{
	wchar_t path[PATHLEN];
	char *text, *end;
	BOOL loader, scripts;

	version[0] = 0;
	if (PATHF(path, L"%ls\\conquest\\version.txt", dir) && (text = read_file(path, NULL))) {
		for (end = text + strlen(text); end > text && (unsigned char)end[-1] <= ' ';)
			*--end = 0;
		if (!MultiByteToWideChar(CP_UTF8, 0, text, -1, version, cap))
			version[0] = 0;
		HeapFree(GetProcessHeap(), 0, text);
	}
	loader = PATHF(path, L"%ls\\dle_crashpad.dll", dir) && is_loader(path);
	scripts = PATHF(path, L"%ls\\conquest\\lua\\boot.lua", dir) && is_file(path);
	if (loader && scripts)
		return MOD_INSTALLED;
	return loader || scripts ? MOD_PARTIAL : MOD_ABSENT;
}

static BOOL game_running(void)
{
	PROCESSENTRY32W pe = { .dwSize = sizeof(pe) };
	HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
	BOOL ok, found = FALSE;

	if (snap == INVALID_HANDLE_VALUE)
		return FALSE;
	for (ok = Process32FirstW(snap, &pe); ok && !found; ok = Process32NextW(snap, &pe))
		found = !_wcsicmp(pe.szExeFile, L"Battlefront.exe");
	CloseHandle(snap);
	return found;
}

static BOOL check_folder(const wchar_t *dir)
{
	if (!is_game_dir(dir))
		return fail(0, L"Battlefront Classic Collection was not found in:\n%ls", dir);
	if (game_running())
		return fail(0, L"Battlefront Classic Collection is running. Quit the game, then try again.");
	return TRUE;
}

static BOOL do_install(const wchar_t *dir)
{
	wchar_t path[PATHLEN], orig[PATHLEN];
	const BYTE *dll = NULL;
	DWORD dll_size = 0, pos = 0;
	struct entry e;

	if (!check_folder(dir) || !load_payload())
		return FALSE;
	if (!PATHF(path, L"%ls\\conquest\\lua", dir) || !PATHF(orig, L"%ls\\dle_crashpad_orig.dll", dir))
		return fail(0, L"The game folder path is too long.");

	/* replace the scripts wholesale so files a newer version dropped go too */
	if (!delete_tree(path))
		return FALSE;
	while (next_entry(&pos, &e)) {
		if (!wcscmp(e.path, L"dle_crashpad.dll")) {
			dll = e.data;
			dll_size = e.size;
			continue;
		}
		if (!PATHF(path, L"%ls\\%ls", dir, e.path))
			return fail(0, L"The game folder path is too long.");
		if (!write_file(path, e.data, e.size))
			return FALSE;
	}
	if (!dll)
		return fail(0, L"This setup program is damaged. Download it again.");
	PATHF(path, L"%ls\\conquest\\version.txt", dir);
	if (!write_file(path, CONQUEST_VERSION, sizeof(CONQUEST_VERSION) - 1))
		return FALSE;

	/* The loader goes last: until it is in place the game ignores conquest\.
	 * If the current DLL is Aspyr's crash reporter (first install, or a game
	 * update restored it) it becomes the backup the loader forwards to. */
	PATHF(path, L"%ls\\dle_crashpad.dll", dir);
	if (is_file(path) && !is_loader(path) && !MoveFileExW(path, orig, MOVEFILE_REPLACE_EXISTING))
		return fail(GetLastError(), L"Could not rename %ls.", path);
	return write_file(path, dll, dll_size);
}

static BOOL do_uninstall(const wchar_t *dir)
{
	wchar_t dll[PATHLEN], orig[PATHLEN], path[PATHLEN];

	if (!check_folder(dir))
		return FALSE;
	if (!PATHF(dll, L"%ls\\dle_crashpad.dll", dir) || !PATHF(orig, L"%ls\\dle_crashpad_orig.dll", dir))
		return fail(0, L"The game folder path is too long.");
	if (is_file(orig)) {
		if (!is_file(dll) || is_loader(dll)) {
			if (!MoveFileExW(orig, dll, MOVEFILE_REPLACE_EXISTING))
				return fail(GetLastError(), L"Could not restore %ls.", dll);
		} else if (!DeleteFileW(orig)) {
			/* a game update already put Aspyr's DLL back; the backup is stale */
			return fail(GetLastError(), L"Could not remove %ls.", orig);
		}
	} else if (is_loader(dll) && !DeleteFileW(dll)) {
		return fail(GetLastError(), L"Could not remove %ls.", dll);
	}
	PATHF(path, L"%ls\\conquest", dir);
	if (!delete_tree(path))
		return FALSE;
	PATHF(path, L"%ls\\conquest.log", dir);
	return delete_tree(path);
}

/* ---- administrator rights --------------------------------------------- */

static BOOL is_elevated(void)
{
	HANDLE token;
	TOKEN_ELEVATION elevation;
	DWORD len;
	BOOL r = FALSE;

	if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
		if (GetTokenInformation(token, TokenElevation, &elevation, sizeof(elevation), &len))
			r = elevation.TokenIsElevated;
		CloseHandle(token);
	}
	return r;
}

/* Steam's own folders are writable by users; a game folder elsewhere under
 * Program Files may not be. */
static BOOL needs_admin(const wchar_t *dir)
{
	wchar_t probe[PATHLEN];
	HANDLE f;

	if (is_elevated() || !PATHF(probe, L"%ls\\conquest-setup.tmp", dir))
		return FALSE;
	f = CreateFileW(probe, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
	                FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, NULL);
	if (f != INVALID_HANDLE_VALUE) {
		CloseHandle(f);
		return FALSE;
	}
	return GetLastError() == ERROR_ACCESS_DENIED;
}

/* Run this program as administrator for one action and return its exit
 * code (it reports its own errors), or -1 if the user said no. */
static int run_elevated(HWND owner, const wchar_t *action, const wchar_t *dir)
{
	wchar_t exe[PATHLEN], params[PATHLEN + 32];
	SHELLEXECUTEINFOW sei = { .cbSize = sizeof(sei) };
	DWORD code = 1;
	MSG msg;

	if (!GetModuleFileNameW(NULL, exe, ARRAYSIZE(exe)) || !PATHF(params, L"%ls \"%ls\"", action, dir))
		return 1;
	sei.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
	sei.hwnd = owner;
	sei.lpVerb = L"runas";
	sei.lpFile = exe;
	sei.lpParameters = params;
	sei.nShow = SW_SHOWNORMAL;
	if (!ShellExecuteExW(&sei)) {
		if (GetLastError() == ERROR_CANCELLED)
			return -1;
		fail(GetLastError(), L"Could not start Setup as administrator.");
		MessageBoxW(owner, g_error, CAPTION, MB_ICONERROR);
		return 1;
	}
	EnableWindow(owner, FALSE);
	while (MsgWaitForMultipleObjects(1, &sei.hProcess, FALSE, INFINITE, QS_ALLINPUT) == WAIT_OBJECT_0 + 1) {
		while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
			TranslateMessage(&msg);
			DispatchMessageW(&msg);
		}
	}
	EnableWindow(owner, TRUE);
	SetForegroundWindow(owner);
	GetExitCodeProcess(sei.hProcess, &code);
	CloseHandle(sei.hProcess);
	return (int)code;
}

/* ---- dialog ----------------------------------------------------------- */

static void get_folder(HWND dlg, wchar_t *dir)
{
	wchar_t text[PATHLEN];

	GetDlgItemTextW(dlg, IDC_FOLDER, text, ARRAYSIZE(text));
	normalize_dir(text, dir, PATHLEN);
}

static void update_status(HWND dlg)
{
	wchar_t dir[PATHLEN], text[512], version[32];
	const wchar_t *install = L"&Install";
	BOOL can_install = FALSE, can_remove = FALSE;

	get_folder(dlg, dir);
	if (!dir[0]) {
		PATHF(text, L"Choose the folder where Steam installed Battlefront Classic Collection.");
	} else if (!is_game_dir(dir)) {
		PATHF(text, L"Battlefront Classic Collection is not in this folder. To find it, right-click the "
		            L"game in Steam and choose Manage > Browse local files.");
	} else {
		can_install = TRUE;
		switch (mod_state(dir, version, ARRAYSIZE(version))) {
		case MOD_ABSENT:
			PATHF(text, L"Ready to install version %ls.", VERSION_W);
			break;
		case MOD_INSTALLED:
			can_remove = TRUE;
			if (!wcscmp(version, VERSION_W)) {
				install = L"&Reinstall";
				PATHF(text, L"Version %ls is installed. Start STAR WARS Battlefront II and choose "
				            L"Multiplayer > Galactic Conquest.", version);
			} else if (version[0]) {
				install = L"&Update";
				PATHF(text, L"Version %ls is installed. Choose Update to install version %ls.", version, VERSION_W);
			} else {
				install = L"&Update";
				PATHF(text, L"An earlier version is installed. Choose Update to install version %ls.", VERSION_W);
			}
			break;
		case MOD_PARTIAL:
			can_remove = TRUE;
			install = L"&Repair";
			PATHF(text, L"The mod is only partly installed. A game update or Steam's file check may have "
			            L"replaced one of its files. Choose Repair to fix it.");
			break;
		}
	}
	SetDlgItemTextW(dlg, IDC_STATUS, text);
	SetDlgItemTextW(dlg, IDC_INSTALL, install);
	EnableWindow(GetDlgItem(dlg, IDC_INSTALL), can_install);
	EnableWindow(GetDlgItem(dlg, IDC_UNINSTALL), can_remove);
}

static void browse(HWND dlg)
{
	IFileOpenDialog *fd;
	IShellItem *item;
	wchar_t current[PATHLEN], dir[PATHLEN], *picked;
	DWORD opts;

	if (FAILED(CoCreateInstance(&CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER, &IID_IFileOpenDialog,
	                            (void **)&fd)))
		return;
	if (SUCCEEDED(IFileOpenDialog_GetOptions(fd, &opts)))
		IFileOpenDialog_SetOptions(fd, opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
	IFileOpenDialog_SetTitle(fd, L"Choose the Battlefront Classic Collection folder");
	get_folder(dlg, current);
	if (current[0] && SUCCEEDED(SHCreateItemFromParsingName(current, NULL, &IID_IShellItem, (void **)&item))) {
		IFileOpenDialog_SetFolder(fd, item);
		IShellItem_Release(item);
	}
	if (SUCCEEDED(IFileOpenDialog_Show(fd, dlg)) && SUCCEEDED(IFileOpenDialog_GetResult(fd, &item))) {
		if (SUCCEEDED(IShellItem_GetDisplayName(item, SIGDN_FILESYSPATH, &picked))) {
			/* also accept steamapps\common, a Steam library or Steam itself */
			if (!try_dir(picked, dir) && !(PATHF(current, L"%ls\\Battle", picked) && try_dir(current, dir)) &&
			    !try_steam(picked, dir))
				lstrcpynW(dir, picked, ARRAYSIZE(dir));
			SetDlgItemTextW(dlg, IDC_FOLDER, dir);
			CoTaskMemFree(picked);
		}
		IShellItem_Release(item);
	}
	IFileOpenDialog_Release(fd);
}

static void open_readme(HWND dlg)
{
	wchar_t temp[PATHLEN], path[PATHLEN];
	struct entry e;
	DWORD pos = 0, n;

	n = GetTempPathW(ARRAYSIZE(temp), temp);
	if (!load_payload() || !n || n >= ARRAYSIZE(temp) ||
	    !PATHF(path, L"%lsOnline Galactic Conquest - Read me.txt", temp)) {
		MessageBoxW(dlg, g_error, CAPTION, MB_ICONERROR);
		return;
	}
	while (next_entry(&pos, &e)) {
		if (wcscmp(e.path, L"conquest\\README.txt"))
			continue;
		if (!write_file(path, e.data, e.size)) {
			MessageBoxW(dlg, g_error, CAPTION, MB_ICONERROR);
			return;
		}
		/* Notepad when nothing is registered for .txt */
		if ((INT_PTR)ShellExecuteW(dlg, L"open", path, NULL, NULL, SW_SHOWNORMAL) <= 32 &&
		    PATHF(temp, L"\"%ls\"", path))
			ShellExecuteW(dlg, L"open", L"notepad.exe", temp, NULL, SW_SHOWNORMAL);
		return;
	}
}

static void run_action(HWND dlg, BOOL install)
{
	wchar_t dir[PATHLEN], dll[PATHLEN];
	HCURSOR cursor;
	BOOL ok;
	int code;

	get_folder(dlg, dir);
	if (!install && MessageBoxW(dlg, L"Remove Online Galactic Conquest from Battlefront Classic Collection?",
	                            CAPTION, MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2) != IDYES)
		return;
	if (needs_admin(dir)) {
		code = run_elevated(dlg, install ? L"/install" : L"/uninstall", dir);
		ok = code == 0;
	} else {
		cursor = SetCursor(LoadCursorW(NULL, IDC_WAIT));
		ok = install ? do_install(dir) : do_uninstall(dir);
		SetCursor(cursor);
		if (!ok)
			MessageBoxW(dlg, g_error, CAPTION, MB_ICONERROR);
	}
	update_status(dlg);
	if (!ok)
		return;
	if (install) {
		MessageBoxW(dlg, L"Online Galactic Conquest " VERSION_W L" is installed.\n\n"
		                 L"Start STAR WARS Battlefront II and choose Multiplayer, then Galactic Conquest.",
		            CAPTION, MB_ICONINFORMATION);
	} else if (PATHF(dll, L"%ls\\dle_crashpad.dll", dir) && !is_file(dll)) {
		/* there was no backup of Aspyr's DLL to put back */
		MessageBoxW(dlg, L"Online Galactic Conquest was removed.\n\n"
		                 L"Before playing, let Steam restore one game file: right-click the game in Steam, "
		                 L"choose Properties > Installed Files, then Verify integrity of game files.",
		            CAPTION, MB_ICONWARNING);
	} else {
		MessageBoxW(dlg, L"Online Galactic Conquest was removed.", CAPTION, MB_ICONINFORMATION);
	}
	SendMessageW(dlg, WM_NEXTDLGCTL, (WPARAM)GetDlgItem(dlg, IDCANCEL), TRUE);
}

static void header_rect(HWND dlg, RECT *rc)
{
	RECT r = { 0, 0, 0, HEADER_HEIGHT };

	MapDialogRect(dlg, &r);
	GetClientRect(dlg, rc);
	rc->bottom = r.bottom;
}

static void init_dialog(HWND dlg, const wchar_t *dir)
{
	HINSTANCE inst = GetModuleHandleW(NULL);
	HFONT base = (HFONT)SendMessageW(dlg, WM_GETFONT, 0, 0);
	LOGFONTW lf;
	RECT rc;
	int size;

	SendMessageW(dlg, WM_SETICON, ICON_BIG, (LPARAM)LoadImageW(inst, MAKEINTRESOURCEW(IDI_APP), IMAGE_ICON,
		GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), 0));
	SendMessageW(dlg, WM_SETICON, ICON_SMALL, (LPARAM)LoadImageW(inst, MAKEINTRESOURCEW(IDI_APP), IMAGE_ICON,
		GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0));
	header_rect(dlg, &rc);
	size = rc.bottom * 2 / 3;
	g_header_icon = LoadImageW(inst, MAKEINTRESOURCEW(IDI_APP), IMAGE_ICON, size, size, 0);

	if (base && GetObjectW(base, sizeof(lf), &lf)) {
		lf.lfHeight = lf.lfHeight * 3 / 2;
		lf.lfWeight = FW_SEMIBOLD;
		g_title_font = CreateFontIndirectW(&lf);
		SendDlgItemMessageW(dlg, IDC_TITLE, WM_SETFONT, (WPARAM)g_title_font, FALSE);
	}
	SetDlgItemTextW(dlg, IDC_SUBTITLE, L"Version " VERSION_W L" for STAR WARS Battlefront II (Classic Collection)");
	SHAutoComplete(GetDlgItem(dlg, IDC_FOLDER), SHACF_FILESYS_DIRS);
	SetDlgItemTextW(dlg, IDC_FOLDER, dir);
	update_status(dlg);
}

static INT_PTR CALLBACK dialog_proc(HWND dlg, UINT msg, WPARAM wp, LPARAM lp)
{
	switch (msg) {
	case WM_INITDIALOG:
		init_dialog(dlg, (const wchar_t *)lp);
		return TRUE;
	case WM_ACTIVATE:
		/* Start on Install (or Browse). Posted from the first activation:
		 * activating a dialog puts focus back on its first control. */
		if (LOWORD(wp) != WA_INACTIVE && !g_activated) {
			g_activated = TRUE;
			PostMessageW(dlg, WM_NEXTDLGCTL, (WPARAM)GetDlgItem(dlg,
				IsWindowEnabled(GetDlgItem(dlg, IDC_INSTALL)) ? IDC_INSTALL : IDC_BROWSE), TRUE);
		}
		break;
	case WM_PAINT: {
		PAINTSTRUCT ps;
		RECT rc;
		HDC dc = BeginPaint(dlg, &ps);
		int size, margin;

		header_rect(dlg, &rc);
		FillRect(dc, &rc, GetSysColorBrush(COLOR_WINDOW));
		if (g_header_icon) {
			size = rc.bottom * 2 / 3;
			margin = (rc.bottom - size) / 2;
			DrawIconEx(dc, rc.right - size - margin * 2, margin, g_header_icon, size, size, 0, NULL, DI_NORMAL);
		}
		EndPaint(dlg, &ps);
		return TRUE;
	}
	case WM_CTLCOLORSTATIC: {
		int id = GetDlgCtrlID((HWND)lp);
		if (id == IDC_TITLE || id == IDC_SUBTITLE) {
			SetTextColor((HDC)wp, GetSysColor(COLOR_WINDOWTEXT));
			SetBkColor((HDC)wp, GetSysColor(COLOR_WINDOW));
			return (INT_PTR)GetSysColorBrush(COLOR_WINDOW);
		}
		break;
	}
	case WM_COMMAND:
		switch (LOWORD(wp)) {
		case IDC_FOLDER:
			if (HIWORD(wp) == EN_CHANGE)
				update_status(dlg);
			return TRUE;
		case IDC_BROWSE:
			browse(dlg);
			return TRUE;
		case IDC_INSTALL:
			run_action(dlg, TRUE);
			return TRUE;
		case IDC_UNINSTALL:
			run_action(dlg, FALSE);
			return TRUE;
		case IDCANCEL:
			EndDialog(dlg, 0);
			return TRUE;
		}
		break;
	case WM_NOTIFY: {
		NMHDR *nm = (NMHDR *)lp;
		if (nm->idFrom == IDC_README && (nm->code == NM_CLICK || nm->code == NM_RETURN)) {
			open_readme(dlg);
			return TRUE;
		}
		break;
	}
	case WM_DESTROY:
		if (g_title_font)
			DeleteObject(g_title_font);
		if (g_header_icon)
			DestroyIcon(g_header_icon);
		break;
	}
	return FALSE;
}

/* ---- entry ------------------------------------------------------------ */

static void report_error(BOOL quiet)
{
	HANDLE err;
	char buf[4096];
	DWORD wrote;
	int n;

	if (!quiet) {
		MessageBoxW(NULL, g_error, CAPTION, MB_ICONERROR);
		return;
	}
	err = GetStdHandle(STD_ERROR_HANDLE);
	n = WideCharToMultiByte(CP_UTF8, 0, g_error, -1, buf, sizeof(buf) - 1, NULL, NULL);
	if (n > 0 && err && err != INVALID_HANDLE_VALUE) {
		buf[n - 1] = '\n';
		WriteFile(err, buf, (DWORD)n, &wrote, NULL);
	}
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, PWSTR cmdline, int show)
{
	INITCOMMONCONTROLSEX icc = { sizeof(icc), ICC_STANDARD_CLASSES | ICC_LINK_CLASS };
	wchar_t **argv, dir[PATHLEN] = L"";
	const wchar_t *folder = NULL, *action = NULL;
	BOOL quiet = FALSE, ok;
	int argc, i;

	(void)prev;
	(void)cmdline;
	(void)show;
	argv = CommandLineToArgvW(GetCommandLineW(), &argc);
	for (i = 1; argv && i < argc; i++) {
		if (!_wcsicmp(argv[i], L"/install") || !_wcsicmp(argv[i], L"/uninstall"))
			action = argv[i];
		else if (!_wcsicmp(argv[i], L"/quiet"))
			quiet = TRUE;
		else
			folder = argv[i];
	}
	CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
	if (folder)
		normalize_dir(folder, dir, ARRAYSIZE(dir));
	else if (!find_game(dir))
		dir[0] = 0;

	if (action) {
		if (!dir[0])
			ok = fail(0, L"Battlefront Classic Collection was not found. Put its folder after %ls.", action);
		else
			ok = !_wcsicmp(action, L"/install") ? do_install(dir) : do_uninstall(dir);
		if (!ok)
			report_error(quiet);
		return ok ? 0 : 1;
	}

	InitCommonControlsEx(&icc);
	DialogBoxParamW(inst, MAKEINTRESOURCEW(IDD_SETUP), NULL, dialog_proc, (LPARAM)dir);
	return 0;
}
