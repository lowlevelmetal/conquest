/* Winsock shim that tunnels engine LAN discovery over the mod's TCP link. */
#ifndef CONQUEST_SHIM_H
#define CONQUEST_SHIM_H

#include <windows.h>

/* Hook Battlefront2.dll's Winsock imports. Returns 0 if any hook is missing. */
int shim_install(HMODULE mod);

/* Route discovery through the TCP peer (1) or the real network (0). */
void shim_set_tunnel(int on);

#endif
