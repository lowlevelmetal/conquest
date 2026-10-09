/*
 * Battle-port check for the lobby. Battles use the engine's own UDP transport
 * on the host's port 3658, which the mod's TCP link says nothing about. While
 * the lobby is open the host answers probes on that port, and the joining
 * player sends a few: no answer means battles will not connect (usually the
 * port is not forwarded to the host's PC).
 *
 * A probe is "CGCPROBE" + 8 random bytes; the answer is "CGCECHO!" + the same
 * 8 bytes, the same size, so the echo cannot amplify traffic.
 */
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdio.h>
#include <string.h>

#include "log.h"
#include "udp.h"

#define PROBE_LEN      16
#define PROBE_EVERY_MS 250
#define PROBE_FOR_MS   5000
#define ECHO_PER_SEC   20

static const char PROBE_TAG[8] = { 'C', 'G', 'C', 'P', 'R', 'O', 'B', 'E' };
static const char ECHO_TAG[8] = { 'C', 'G', 'C', 'E', 'C', 'H', 'O', '!' };

static CRITICAL_SECTION g_lock;
static INIT_ONCE g_init = INIT_ONCE_STATIC_INIT;
static volatile LONG g_echo_gen, g_probe_gen;
static volatile LONG g_echo_running;
static volatile LONG g_probe_result;   /* UDP_PROBE_* */

static BOOL CALLBACK init_once(PINIT_ONCE once, PVOID param, PVOID *ctx)
{
	WSADATA wsa;
	(void)once; (void)param; (void)ctx;
	InitializeCriticalSection(&g_lock);
	WSAStartup(MAKEWORD(2, 2), &wsa);
	return TRUE;
}

static void ensure_init(void)
{
	InitOnceExecuteOnce(&g_init, init_once, NULL, NULL);
}

/* test copies only (CONQUEST_INSTANCE set): CONQUEST_TEST_BLOCK_UDP=1
 * pretends port 3658 is not forwarded */
int udp_test_blocked(void)
{
	char v[8];
	return instance_name()[0] && GetEnvironmentVariableA("CONQUEST_TEST_BLOCK_UDP", v, sizeof(v)) && v[0] == '1';
}

struct echo_args {
	SOCKET s;
	LONG gen;
};

static DWORD WINAPI echo_thread(LPVOID param)
{
	struct echo_args a = *(struct echo_args *)param;
	DWORD window = GetTickCount();
	int sent = 0, blocked = udp_test_blocked();

	free(param);
	while (a.gen == g_echo_gen) {
		char buf[64];
		struct sockaddr_in from;
		int flen = sizeof(from), n;
		fd_set rd;
		struct timeval tv = { 0, 50 * 1000 };

		FD_ZERO(&rd);
		FD_SET(a.s, &rd);
		if (select(0, &rd, NULL, NULL, &tv) <= 0)
			continue;
		n = recvfrom(a.s, buf, sizeof(buf), 0, (struct sockaddr *)&from, &flen);
		if (n != PROBE_LEN || memcmp(buf, PROBE_TAG, 8) || blocked)
			continue;
		if (GetTickCount() - window >= 1000) {
			window = GetTickCount();
			sent = 0;
		}
		if (sent++ >= ECHO_PER_SEC)
			continue;
		memcpy(buf, ECHO_TAG, 8);
		sendto(a.s, buf, PROBE_LEN, 0, (struct sockaddr *)&from, flen);
	}
	closesocket(a.s);
	InterlockedExchange(&g_echo_running, 0);
	return 0;
}

int udp_echo_start(unsigned short port)
{
	struct sockaddr_in addr;
	struct echo_args *a;
	SOCKET s;
	BOOL yes = TRUE;
	HANDLE t;

	ensure_init();
	udp_echo_stop();
	s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
	if (s == INVALID_SOCKET)
		return 0;
	setsockopt(s, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (const char *)&yes, sizeof(yes));
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons(port);
	addr.sin_addr.s_addr = htonl(INADDR_ANY);
	if (bind(s, (struct sockaddr *)&addr, sizeof(addr))) {
		log_printf("udp: cannot answer battle-port checks on %u (%d)", port, WSAGetLastError());
		closesocket(s);
		return 0;
	}
	a = malloc(sizeof(*a));
	if (!a) {
		closesocket(s);
		return 0;
	}
	a->s = s;
	a->gen = g_echo_gen;
	InterlockedExchange(&g_echo_running, 1);
	t = CreateThread(NULL, 0, echo_thread, a, 0, NULL);
	if (!t) {
		InterlockedExchange(&g_echo_running, 0);
		free(a);
		closesocket(s);
		return 0;
	}
	CloseHandle(t);
	log_printf("udp: answering battle-port checks on %u", port);
	return 1;
}

void udp_echo_stop(void)
{
	ensure_init();
	InterlockedIncrement(&g_echo_gen);
	/* the thread closes its socket within one select timeout; wait for that so
	 * the port is free for the engine or a new echo */
	for (int i = 0; i < 20 && g_echo_running; i++)
		Sleep(10);
}

struct probe_args {
	struct sockaddr_in to;
	LONG gen;
};

static DWORD WINAPI probe_thread(LPVOID param)
{
	struct probe_args a = *(struct probe_args *)param;
	SOCKET s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
	DWORD start = GetTickCount(), last = 0;
	char probe[PROBE_LEN];
	LONG result = UDP_PROBE_FAILED;
	int first = 1;

	free(param);
	if (s == INVALID_SOCKET)
		goto done;
	memcpy(probe, PROBE_TAG, 8);
	for (int i = 8; i < PROBE_LEN; i++)
		probe[i] = (char)(GetTickCount() * 2654435761u >> (i * 3));
	while (a.gen == g_probe_gen && GetTickCount() - start < PROBE_FOR_MS) {
		char buf[64];
		fd_set rd;
		struct timeval tv = { 0, 50 * 1000 };
		int n;

		if (first || GetTickCount() - last >= PROBE_EVERY_MS) {
			first = 0;
			last = GetTickCount();
			sendto(s, probe, PROBE_LEN, 0, (struct sockaddr *)&a.to, sizeof(a.to));
		}
		FD_ZERO(&rd);
		FD_SET(s, &rd);
		if (select(0, &rd, NULL, NULL, &tv) <= 0)
			continue;
		n = recv(s, buf, sizeof(buf), 0);
		if (n == PROBE_LEN && !memcmp(buf, ECHO_TAG, 8) && !memcmp(buf + 8, probe + 8, PROBE_LEN - 8)) {
			result = UDP_PROBE_OK;
			break;
		}
	}
	closesocket(s);
done:
	if (a.gen == g_probe_gen) {
		InterlockedExchange(&g_probe_result, result);
		log_printf("udp: battle port %s", result == UDP_PROBE_OK ? "answered" : "did not answer");
	}
	return 0;
}

int udp_probe_start(const char *host, unsigned short port)
{
	struct addrinfo hints, *res;
	struct probe_args *a;
	char p[16];
	HANDLE t;

	ensure_init();
	InterlockedIncrement(&g_probe_gen);
	InterlockedExchange(&g_probe_result, UDP_PROBE_NONE);
	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_INET;
	hints.ai_socktype = SOCK_DGRAM;
	snprintf(p, sizeof(p), "%u", port);
	if (getaddrinfo(host, p, &hints, &res))
		return 0;
	a = malloc(sizeof(*a));
	if (!a) {
		freeaddrinfo(res);
		return 0;
	}
	memcpy(&a->to, res->ai_addr, sizeof(a->to));
	freeaddrinfo(res);
	a->gen = g_probe_gen;
	InterlockedExchange(&g_probe_result, UDP_PROBE_RUNNING);
	t = CreateThread(NULL, 0, probe_thread, a, 0, NULL);
	if (!t) {
		free(a);
		InterlockedExchange(&g_probe_result, UDP_PROBE_NONE);
		return 0;
	}
	CloseHandle(t);
	return 1;
}

void udp_probe_stop(void)
{
	ensure_init();
	InterlockedIncrement(&g_probe_gen);
	InterlockedExchange(&g_probe_result, UDP_PROBE_NONE);
}

int udp_probe_result(void)
{
	return (int)g_probe_result;
}
