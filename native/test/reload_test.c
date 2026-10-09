/*
 * "Back to game select" without the launcher's menu: load the loader the way
 * Battlefront.exe does (it imports dle_crashpad.dll), then load and free
 * Battlefront2.dll twice, as the launcher does for each game started. Each
 * load must be patched again (see conquest.<CONQUEST_INSTANCE>.log).
 *
 * Run from the game folder, with CONQUEST_INSTANCE set:
 *   CONQUEST_INSTANCE=reloadtest wine reload_test.exe
 */
#include <windows.h>
#include <stdio.h>

int main(void)
{
	HMODULE proxy = LoadLibraryA("dle_crashpad.dll");

	if (!proxy) {
		printf("cannot load dle_crashpad.dll (%lu)\n", GetLastError());
		return 1;
	}
	for (int i = 1; i <= 2; i++) {
		HMODULE bf2 = LoadLibraryA("Battlefront2.dll");
		printf("load %d: Battlefront2.dll at %p\n", i, (void *)bf2);
		if (!bf2)
			return 1;
		if (!GetProcAddress(bf2, "GameWinMain")) {
			printf("no GameWinMain\n");
			return 1;
		}
		if (!FreeLibrary(bf2)) {
			printf("FreeLibrary failed (%lu)\n", GetLastError());
			return 1;
		}
		printf("freed %d: still loaded: %s\n", i, GetModuleHandleA("Battlefront2.dll") ? "yes" : "no");
	}
	return 0;
}
