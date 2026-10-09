/*
 * The crash log under a stream of handled exceptions: one place raises the
 * same exception many times (as the game and Steam do with exceptions they
 * catch), then other places raise others. Each place must be logged once,
 * and the later ones must still be logged.
 *
 *   CONQUEST_INSTANCE=crashtest wine crash_test.exe   (log: conquest.crashtest.log)
 */
#include <windows.h>
#include <stdio.h>

/* stands in for the code that catches them */
static LONG CALLBACK handled(EXCEPTION_POINTERS *info)
{
	return info->ExceptionRecord->ExceptionCode >= 0xC0000000u ? EXCEPTION_CONTINUE_EXECUTION
	                                                            : EXCEPTION_CONTINUE_SEARCH;
}

static __attribute__((noinline)) void raise_here(DWORD code)
{
	RaiseException(code, 0, 0, NULL);
}

static __attribute__((noinline)) void raise_elsewhere(DWORD code)
{
	RaiseException(code, 0, 0, NULL);
}

int main(void)
{
	if (!LoadLibraryA("dle_crashpad.dll")) {
		printf("cannot load dle_crashpad.dll\n");
		return 1;
	}
	AddVectoredExceptionHandler(0, handled);
	for (int i = 0; i < 50; i++)
		raise_here(0xC0000094u);       /* the same place, over and over */
	raise_elsewhere(0xC0000094u);
	raise_elsewhere(0xC0000096u);
	raise_here(0xC000001Du);
	printf("raised 53 exceptions\n");
	return 0;
}
