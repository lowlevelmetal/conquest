/* Import address table patching by function name. */
#include <windows.h>
#include <string.h>

#include "iat.h"

int iat_hook(HMODULE mod, const char *dll, const char *func, void *hook, void **real)
{
	BYTE *base = (BYTE *)mod;
	IMAGE_NT_HEADERS *nt;
	IMAGE_IMPORT_DESCRIPTOR *imp;
	int count = 0;

	if (!mod)
		return 0;
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
			count++;
		}
	}
	return count;
}
