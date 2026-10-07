/*
 * Winsock shim for Battlefront2.dll: tunnels the engine's LAN session
 * discovery over the mod's TCP link so a client can find and join a host by IP.
 *
 * In "lan" connect mode the engine finds sessions by broadcasting a query to
 * 255.255.255.255:3656 and listening on :3656 for broadcast replies. The reply
 * carries the host's game port, and the client joins <sender IP>:<that port>.
 * With the tunnel on, the discovery socket's send() goes to the peer over TCP,
 * and packets from the peer are handed to the discovery listener's recvfrom()
 * as if they came from the peer's IP. Game traffic itself is untouched UDP.
 */
#include <winsock2.h>
#include <windows.h>
#include <string.h>

#include "game.h"
#include "log.h"
#include "net.h"
#include "shim.h"

typedef int (WSAAPI *connect_fn)(SOCKET, const struct sockaddr *, int);
typedef int (WSAAPI *bind_fn)(SOCKET, const struct sockaddr *, int);
typedef int (WSAAPI *send_fn)(SOCKET, const char *, int, int);
typedef int (WSAAPI *recvfrom_fn)(SOCKET, char *, int, int, struct sockaddr *, int *);
typedef int (WSAAPI *closesocket_fn)(SOCKET);

static connect_fn real_connect;
static bind_fn real_bind;
static send_fn real_send;
static recvfrom_fn real_recvfrom;
static closesocket_fn real_closesocket;

static SOCKET g_broadcast = INVALID_SOCKET;  /* connected to 255.255.255.255:<port> */
static SOCKET g_listener = INVALID_SOCKET;   /* bound to the discovery port */
static unsigned short g_port = 3656;         /* discovery port, host byte order */
static volatile LONG g_tunnel;
static LONG g_sent, g_injected;

static int WSAAPI hook_connect(SOCKET s, const struct sockaddr *addr, int len)
{
	int r = real_connect(s, addr, len);
	const struct sockaddr_in *in = (const struct sockaddr_in *)addr;
	if (addr && addr->sa_family == AF_INET && in->sin_addr.s_addr == INADDR_BROADCAST) {
		g_broadcast = s;
		g_port = ntohs(in->sin_port);
		log_printf("shim: discovery broadcast socket %llu -> port %u", (unsigned long long)s, g_port);
	}
	return r;
}

static int WSAAPI hook_bind(SOCKET s, const struct sockaddr *addr, int len)
{
	int r = real_bind(s, addr, len);
	const struct sockaddr_in *in = (const struct sockaddr_in *)addr;
	if (addr && addr->sa_family == AF_INET) {
		unsigned short port = ntohs(in->sin_port);
		log_printf("shim: bind socket %llu to port %u (%s)", (unsigned long long)s, port, r ? "failed" : "ok");
		if (port == g_port)
			g_listener = s;
	}
	return r;
}

static int WSAAPI hook_send(SOCKET s, const char *buf, int len, int flags)
{
	if (g_tunnel && s == g_broadcast && len > 0) {
		if (net_send(NET_CH_DISCOVERY, buf, (size_t)len) && InterlockedIncrement(&g_sent) <= 5)
			log_printf("shim: tunnelled discovery packet out (%d bytes)", len);
		return len;
	}
	return real_send(s, buf, len, flags);
}

static int WSAAPI hook_recvfrom(SOCKET s, char *buf, int len, int flags, struct sockaddr *from, int *fromlen)
{
	/* the engine drains its sockets every frame on the game thread: a safe
	 * place to give mod Lua a regular tick, even inside battles */
	static DWORD last_tick;
	DWORD now = GetTickCount();
	if (now - last_tick >= 50) {
		last_tick = now;
		bridge_tick();
	}

	if (g_tunnel && s == g_listener) {
		char *data;
		size_t n;
		if (net_recv(NET_CH_DISCOVERY, &data, &n)) {
			if (n > (size_t)len)
				n = (size_t)len;
			memcpy(buf, data, n);
			net_free(data);
			if (from && fromlen && *fromlen >= (int)sizeof(struct sockaddr_in)) {
				struct sockaddr_in *in = (struct sockaddr_in *)from;
				memset(in, 0, sizeof(*in));
				in->sin_family = AF_INET;
				in->sin_port = htons(g_port);
				in->sin_addr.s_addr = (u_long)net_peer_ipv4();
				*fromlen = sizeof(*in);
			}
			if (InterlockedIncrement(&g_injected) <= 5)
				log_printf("shim: injected tunnelled discovery packet (%u bytes)", (unsigned)n);
			return (int)n;
		}
		/* ignore real LAN discovery while tunnelling so we only see our peer */
		while (real_recvfrom(s, buf, len, flags, from, fromlen) >= 0)
			;
		WSASetLastError(WSAEWOULDBLOCK);
		return SOCKET_ERROR;
	}
	return real_recvfrom(s, buf, len, flags, from, fromlen);
}

static int WSAAPI hook_closesocket(SOCKET s)
{
	if (s == g_broadcast)
		g_broadcast = INVALID_SOCKET;
	if (s == g_listener)
		g_listener = INVALID_SOCKET;
	return real_closesocket(s);
}

void shim_set_tunnel(int on)
{
	InterlockedExchange(&g_tunnel, on ? 1 : 0);
	g_sent = g_injected = 0;
	log_printf("shim: discovery tunnel %s", on ? "on" : "off");
}

int shim_install(HMODULE mod)
{
	static const struct {
		WORD ordinal;
		void *hook;
		void **real;
	} hooks[] = {
		{ 2,  (void *)hook_bind,        (void **)&real_bind },
		{ 3,  (void *)hook_closesocket, (void **)&real_closesocket },
		{ 4,  (void *)hook_connect,     (void **)&real_connect },
		{ 17, (void *)hook_recvfrom,    (void **)&real_recvfrom },
		{ 19, (void *)hook_send,        (void **)&real_send },
	};
	BYTE *base = (BYTE *)mod;
	IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
	IMAGE_DATA_DIRECTORY dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
	IMAGE_IMPORT_DESCRIPTOR *imp = (IMAGE_IMPORT_DESCRIPTOR *)(base + dir.VirtualAddress);
	int count = 0;

	for (; imp->Name; imp++) {
		IMAGE_THUNK_DATA *names, *iat;
		if (_stricmp((const char *)(base + imp->Name), "WS2_32.dll") || !imp->OriginalFirstThunk)
			continue;
		names = (IMAGE_THUNK_DATA *)(base + imp->OriginalFirstThunk);
		iat = (IMAGE_THUNK_DATA *)(base + imp->FirstThunk);
		for (; names->u1.AddressOfData; names++, iat++) {
			if (!IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal))
				continue;
			for (size_t i = 0; i < sizeof(hooks) / sizeof(hooks[0]); i++) {
				DWORD old;
				if (IMAGE_ORDINAL(names->u1.Ordinal) != hooks[i].ordinal)
					continue;
				*hooks[i].real = (void *)iat->u1.Function;
				VirtualProtect(&iat->u1.Function, sizeof(iat->u1.Function), PAGE_READWRITE, &old);
				iat->u1.Function = (ULONG_PTR)hooks[i].hook;
				VirtualProtect(&iat->u1.Function, sizeof(iat->u1.Function), old, &old);
				count++;
			}
		}
	}
	log_printf("shim: hooked %d Winsock imports", count);
	return count == (int)(sizeof(hooks) / sizeof(hooks[0]));
}
