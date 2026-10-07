#ifndef CONQUEST_IAT_H
#define CONQUEST_IAT_H

#include <windows.h>

/* Point every import of `func` from `dll` (case-insensitive) in `mod` at
 * `hook`. The original address is stored in *real unless already set.
 * Returns the number of import slots replaced. */
int iat_hook(HMODULE mod, const char *dll, const char *func, void *hook, void **real);

#endif
