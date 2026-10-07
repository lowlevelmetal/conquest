/*
 * Single-peer TCP link run on a background thread.
 *
 * Frames are a 4-byte big-endian length followed by the payload. A zero-length
 * frame is a heartbeat. The game thread only touches the inbox/outbox queues,
 * so the link keeps running while the game is loading or in a battle.
 */
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "net.h"
#include "log.h"

#define HEARTBEAT_MS   2000
#define TIMEOUT_MS     30000
#define CONNECT_MS     10000
#define MAX_FRAME      (16u * 1024u * 1024u)

struct msg {
	struct msg *next;
	size_t len;
	char data[];
};

struct queue {
	struct msg *head, *tail;
};

struct thread_args {
	int hosting;
	char host[256];
	unsigned short port;
	LONG generation;
};

static CRITICAL_SECTION g_lock;
static INIT_ONCE g_init = INIT_ONCE_STATIC_INIT;
static enum net_state g_state = NET_IDLE;
static char g_detail[256];
static struct queue g_inbox[NET_CH_COUNT], g_outbox;
static unsigned long g_peer_ipv4;   /* network byte order */
static HANDLE g_thread;
static volatile LONG g_generation;

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

static void queue_push(struct queue *q, struct msg *m)
{
	m->next = NULL;
	if (q->tail)
		q->tail->next = m;
	else
		q->head = m;
	q->tail = m;
}

static struct msg *queue_pop(struct queue *q)
{
	struct msg *m = q->head;
	if (m) {
		q->head = m->next;
		if (!q->head)
			q->tail = NULL;
	}
	return m;
}

static void queue_clear(struct queue *q)
{
	struct msg *m;
	while ((m = queue_pop(q)))
		free(m);
}

static struct msg *msg_new(const char *data, size_t len)
{
	struct msg *m = malloc(sizeof(*m) + len);
	if (!m)
		return NULL;
	m->len = len;
	if (data && len)
		memcpy(m->data, data, len);
	return m;
}

/* Update state only if this thread still owns the link. */
static void set_state(LONG gen, enum net_state s, const char *fmt, ...)
{
	va_list ap;
	EnterCriticalSection(&g_lock);
	if (gen == g_generation) {
		g_state = s;
		va_start(ap, fmt);
		vsnprintf(g_detail, sizeof(g_detail), fmt, ap);
		va_end(ap);
		log_printf("net: %s (%s)", net_state_name(s), g_detail);
	}
	LeaveCriticalSection(&g_lock);
}

static int stale(LONG gen)
{
	return gen != g_generation;
}

static SOCKET accept_peer(struct thread_args *a)
{
	struct sockaddr_in addr;
	SOCKET ls, s = INVALID_SOCKET;
	BOOL yes = TRUE;

	ls = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (ls == INVALID_SOCKET) {
		set_state(a->generation, NET_ERROR, "socket failed (%d)", WSAGetLastError());
		return INVALID_SOCKET;
	}
	setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, (const char *)&yes, sizeof(yes));
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons(a->port);
	addr.sin_addr.s_addr = htonl(INADDR_ANY);
	if (bind(ls, (struct sockaddr *)&addr, sizeof(addr)) || listen(ls, 1)) {
		set_state(a->generation, NET_ERROR, "cannot listen on port %u (%d)", a->port, WSAGetLastError());
		closesocket(ls);
		return INVALID_SOCKET;
	}
	set_state(a->generation, NET_LISTENING, "listening on port %u", a->port);

	while (!stale(a->generation)) {
		fd_set rd;
		struct timeval tv = { 0, 100 * 1000 };
		FD_ZERO(&rd);
		FD_SET(ls, &rd);
		if (select(0, &rd, NULL, NULL, &tv) > 0) {
			struct sockaddr_in peer;
			int plen = sizeof(peer);
			s = accept(ls, (struct sockaddr *)&peer, &plen);
			if (s != INVALID_SOCKET) {
				char ip[64];
				inet_ntop(AF_INET, &peer.sin_addr, ip, sizeof(ip));
				g_peer_ipv4 = peer.sin_addr.s_addr;
				set_state(a->generation, NET_CONNECTED, "connected to %s", ip);
				break;
			}
		}
	}
	closesocket(ls);
	return s;
}

static SOCKET connect_peer(struct thread_args *a)
{
	struct addrinfo hints, *res, *ai;
	char port[16];
	SOCKET s = INVALID_SOCKET;
	int rc;

	set_state(a->generation, NET_CONNECTING, "connecting to %s:%u", a->host, a->port);
	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_INET;
	hints.ai_socktype = SOCK_STREAM;
	snprintf(port, sizeof(port), "%u", a->port);
	rc = getaddrinfo(a->host, port, &hints, &res);
	if (rc) {
		set_state(a->generation, NET_ERROR, "cannot resolve %s (%d)", a->host, rc);
		return INVALID_SOCKET;
	}

	for (ai = res; ai && !stale(a->generation); ai = ai->ai_next) {
		u_long nb = 1;
		DWORD start = GetTickCount();
		s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
		if (s == INVALID_SOCKET)
			continue;
		ioctlsocket(s, FIONBIO, &nb);
		if (connect(s, ai->ai_addr, (int)ai->ai_addrlen) == 0)
			break;
		if (WSAGetLastError() == WSAEWOULDBLOCK) {
			while (!stale(a->generation) && GetTickCount() - start < CONNECT_MS) {
				fd_set wr, ex;
				struct timeval tv = { 0, 100 * 1000 };
				FD_ZERO(&wr); FD_SET(s, &wr);
				FD_ZERO(&ex); FD_SET(s, &ex);
				if (select(0, NULL, &wr, &ex, &tv) > 0) {
					int err = 0, elen = sizeof(err);
					getsockopt(s, SOL_SOCKET, SO_ERROR, (char *)&err, &elen);
					if (FD_ISSET(s, &wr) && !err)
						goto connected;
					break;
				}
			}
		}
		closesocket(s);
		s = INVALID_SOCKET;
	}
connected:
	if (s != INVALID_SOCKET && ai)
		g_peer_ipv4 = ((struct sockaddr_in *)ai->ai_addr)->sin_addr.s_addr;
	freeaddrinfo(res);
	if (s == INVALID_SOCKET) {
		if (!stale(a->generation))
			set_state(a->generation, NET_ERROR, "could not connect to %s:%u", a->host, a->port);
		return INVALID_SOCKET;
	}
	set_state(a->generation, NET_CONNECTED, "connected to %s:%u", a->host, a->port);
	return s;
}

/* Pump frames until the link drops or a newer host/connect call supersedes us. */
static void run_link(struct thread_args *a, SOCKET s)
{
	unsigned char *rbuf = NULL;
	size_t rlen = 0, rcap = 0;
	struct msg *out = NULL;       /* frame currently being written */
	unsigned char hdr[4];
	size_t out_off = 0;           /* bytes of header+payload already sent */
	DWORD last_send = GetTickCount(), last_recv = GetTickCount();
	u_long nb = 1;
	BOOL yes = TRUE;

	ioctlsocket(s, FIONBIO, &nb);
	setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char *)&yes, sizeof(yes));

	while (!stale(a->generation)) {
		fd_set rd, wr;
		/* short wait: messages queued by the game thread go out promptly */
		struct timeval tv = { 0, 2 * 1000 };
		DWORD now = GetTickCount();

		if (!out) {
			EnterCriticalSection(&g_lock);
			out = queue_pop(&g_outbox);
			LeaveCriticalSection(&g_lock);
			if (!out && now - last_send >= HEARTBEAT_MS)
				out = msg_new(NULL, 0);
			if (out) {
				hdr[0] = (unsigned char)(out->len >> 24);
				hdr[1] = (unsigned char)(out->len >> 16);
				hdr[2] = (unsigned char)(out->len >> 8);
				hdr[3] = (unsigned char)out->len;
				out_off = 0;
			}
		}
		if (now - last_recv >= TIMEOUT_MS) {
			set_state(a->generation, NET_CLOSED, "connection timed out");
			break;
		}

		FD_ZERO(&rd); FD_SET(s, &rd);
		FD_ZERO(&wr);
		if (out)
			FD_SET(s, &wr);
		if (select(0, &rd, &wr, NULL, &tv) < 0) {
			set_state(a->generation, NET_ERROR, "select failed (%d)", WSAGetLastError());
			break;
		}

		if (FD_ISSET(s, &rd)) {
			int n;
			if (rcap - rlen < 65536) {
				size_t ncap = rcap ? rcap * 2 : 131072;
				unsigned char *nb2 = realloc(rbuf, ncap);
				if (!nb2) {
					set_state(a->generation, NET_ERROR, "out of memory");
					break;
				}
				rbuf = nb2;
				rcap = ncap;
			}
			n = recv(s, (char *)rbuf + rlen, (int)(rcap - rlen), 0);
			if (n == 0 || (n < 0 && WSAGetLastError() != WSAEWOULDBLOCK)) {
				set_state(a->generation, NET_CLOSED, "peer disconnected");
				break;
			}
			if (n > 0) {
				size_t pos = 0;
				rlen += (size_t)n;
				last_recv = GetTickCount();
				while (rlen - pos >= 4) {
					size_t flen = ((size_t)rbuf[pos] << 24) | ((size_t)rbuf[pos + 1] << 16) |
					              ((size_t)rbuf[pos + 2] << 8) | rbuf[pos + 3];
					if (flen > MAX_FRAME) {
						set_state(a->generation, NET_ERROR, "oversized frame (%u bytes)", (unsigned)flen);
						goto done;
					}
					if (rlen - pos - 4 < flen)
						break;
					if (flen > 1 && rbuf[pos + 4] < NET_CH_COUNT) {
						struct msg *m = msg_new((char *)rbuf + pos + 5, flen - 1);
						if (m) {
							EnterCriticalSection(&g_lock);
							if (!stale(a->generation))
								queue_push(&g_inbox[rbuf[pos + 4]], m);
							else
								free(m);
							LeaveCriticalSection(&g_lock);
						}
					}
					pos += 4 + flen;
				}
				memmove(rbuf, rbuf + pos, rlen - pos);
				rlen -= pos;
			}
		}

		if (out && FD_ISSET(s, &wr)) {
			int n;
			if (out_off < 4)
				n = send(s, (const char *)hdr + out_off, (int)(4 - out_off), 0);
			else
				n = send(s, out->data + (out_off - 4), (int)(out->len - (out_off - 4)), 0);
			if (n < 0 && WSAGetLastError() != WSAEWOULDBLOCK) {
				set_state(a->generation, NET_CLOSED, "send failed (%d)", WSAGetLastError());
				break;
			}
			if (n > 0) {
				out_off += (size_t)n;
				last_send = GetTickCount();
				if (out_off == 4 + out->len) {
					free(out);
					out = NULL;
				}
			}
		}
	}
done:
	free(out);
	free(rbuf);
	closesocket(s);
}

static DWORD WINAPI link_thread(LPVOID param)
{
	struct thread_args *a = param;
	SOCKET s = a->hosting ? accept_peer(a) : connect_peer(a);
	if (s != INVALID_SOCKET)
		run_link(a, s);
	free(a);
	return 0;
}

/* Stop any running link and wait briefly for its thread to exit. */
static void stop_link(void)
{
	HANDLE t;
	EnterCriticalSection(&g_lock);
	InterlockedIncrement(&g_generation);
	t = g_thread;
	g_thread = NULL;
	for (int i = 0; i < NET_CH_COUNT; i++)
		queue_clear(&g_inbox[i]);
	queue_clear(&g_outbox);
	g_peer_ipv4 = 0;
	LeaveCriticalSection(&g_lock);
	if (t) {
		WaitForSingleObject(t, 2000);
		CloseHandle(t);
	}
}

static int start_link(int hosting, const char *host, unsigned short port, char *err, size_t errlen)
{
	struct thread_args *a;

	ensure_init();
	stop_link();

	a = calloc(1, sizeof(*a));
	if (!a) {
		snprintf(err, errlen, "out of memory");
		return 0;
	}
	a->hosting = hosting;
	a->port = port;
	if (host)
		snprintf(a->host, sizeof(a->host), "%s", host);

	EnterCriticalSection(&g_lock);
	a->generation = g_generation;
	g_state = hosting ? NET_LISTENING : NET_CONNECTING;
	snprintf(g_detail, sizeof(g_detail), "starting");
	g_thread = CreateThread(NULL, 0, link_thread, a, 0, NULL);
	LeaveCriticalSection(&g_lock);
	if (!g_thread) {
		free(a);
		snprintf(err, errlen, "cannot start network thread");
		return 0;
	}
	return 1;
}

int net_host(unsigned short port, char *err, size_t errlen)
{
	return start_link(1, NULL, port, err, errlen);
}

int net_connect(const char *host, unsigned short port, char *err, size_t errlen)
{
	return start_link(0, host, port, err, errlen);
}

void net_close(void)
{
	ensure_init();
	stop_link();
	EnterCriticalSection(&g_lock);
	g_state = NET_IDLE;
	snprintf(g_detail, sizeof(g_detail), "closed");
	LeaveCriticalSection(&g_lock);
	log_printf("net: closed by game");
}

enum net_state net_status(char *buf, size_t buflen)
{
	enum net_state s;
	ensure_init();
	EnterCriticalSection(&g_lock);
	s = g_state;
	if (buf && buflen)
		snprintf(buf, buflen, "%s", g_detail);
	LeaveCriticalSection(&g_lock);
	return s;
}

const char *net_state_name(enum net_state s)
{
	switch (s) {
	case NET_IDLE:       return "idle";
	case NET_LISTENING:  return "listening";
	case NET_CONNECTING: return "connecting";
	case NET_CONNECTED:  return "connected";
	case NET_CLOSED:     return "closed";
	case NET_ERROR:      return "error";
	}
	return "unknown";
}

int net_send(enum net_channel ch, const char *data, size_t len)
{
	struct msg *m;
	int ok = 0;
	if (!len || len >= MAX_FRAME)
		return 0;
	ensure_init();
	m = msg_new(NULL, len + 1);
	if (!m)
		return 0;
	m->data[0] = (char)ch;
	memcpy(m->data + 1, data, len);
	EnterCriticalSection(&g_lock);
	if (g_state == NET_CONNECTED) {
		queue_push(&g_outbox, m);
		ok = 1;
	}
	LeaveCriticalSection(&g_lock);
	if (!ok)
		free(m);
	return ok;
}

unsigned long net_peer_ipv4(void)
{
	return g_peer_ipv4;
}

int net_recv(enum net_channel ch, char **data, size_t *len)
{
	struct msg *m;
	ensure_init();
	EnterCriticalSection(&g_lock);
	m = queue_pop(&g_inbox[ch]);
	LeaveCriticalSection(&g_lock);
	if (!m)
		return 0;
	*len = m->len;
	*data = malloc(m->len ? m->len : 1);
	if (*data)
		memcpy(*data, m->data, m->len);
	free(m);
	return *data != NULL;
}

void net_free(char *data)
{
	free(data);
}

void net_local_addresses(char *buf, size_t buflen)
{
	char name[256];
	struct addrinfo hints, *res, *ai;
	size_t used = 0;

	ensure_init();
	buf[0] = '\0';
	if (gethostname(name, sizeof(name)))
		return;
	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_INET;
	if (getaddrinfo(name, NULL, &hints, &res))
		return;
	for (ai = res; ai; ai = ai->ai_next) {
		char ip[64];
		struct sockaddr_in *sin = (struct sockaddr_in *)ai->ai_addr;
		inet_ntop(AF_INET, &sin->sin_addr, ip, sizeof(ip));
		if (!strncmp(ip, "127.", 4) || strstr(buf, ip))
			continue;
		used += (size_t)snprintf(buf + used, used < buflen ? buflen - used : 0, "%s%s", used ? ", " : "", ip);
		if (used >= buflen)
			break;
	}
	freeaddrinfo(res);
}
