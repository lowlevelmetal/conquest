/*
 * Single-peer TCP link run on a background thread.
 *
 * Frames are a 4-byte big-endian length followed by the payload. A zero-length
 * frame is a heartbeat. The game thread only touches the inbox/outbox queues,
 * so the link keeps running while the game is loading or in a battle.
 *
 * Hosting: the listening socket is opened by net_host itself, so a port that
 * cannot be opened is reported at once, and it stays open until the link is
 * closed. A new connection waits as "pending" until it sends its first
 * message; only then does it become the peer. Connections that never send
 * anything (port scanners, a stranger idling) cannot take the peer slot, and
 * one that arrives while a peer is connected is refused as full.
 *
 * Closing (net_close, net_accept_next, a new net_host/net_connect) still
 * sends what was queued for the old peer, in the background, for a moment.
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
#define PENDING_MS     10000      /* a new connection must send its first message within this */
#define DRAIN_MS       2000       /* time to send what was queued for a peer being closed */
#define POLL_MS        10
#define MAX_FRAME      (1u << 20)
#define MAX_PENDING    8
#define MAX_DRAINS     4
#define INBOX_MAX_MSGS 1024       /* Lua messages waiting for the game */
#define INBOX_MAX_BYTES (8u << 20)
#define DISCOVERY_MAX  32         /* tunnelled discovery packets (lossy, oldest dropped) */

/* sent to a connection that arrives while the host already has its peer
 * (a Lua message: see CGC.Serialize and the "refuse" lobby message) */
static const char REFUSE_FULL[] = "{[\"kind\"]=\"refuse\",[\"reason\"]=\"full\",}";

struct msg {
	struct msg *next;
	size_t len;
	char data[];
};

struct queue {
	struct msg *head, *tail;
};

struct conn {
	SOCKET s;
	unsigned char *rbuf;
	size_t rlen, rcap;
	struct queue outq;            /* thread-owned: refusals and drains */
	struct msg *out;              /* frame being written */
	size_t out_off;               /* bytes of header+payload already sent */
	unsigned char hdr[4];
	DWORD since, last_recv, last_send;
	unsigned long ipv4;           /* network byte order */
	int shut;                     /* drain: SD_SEND done, waiting for the peer's EOF */
};

struct link {
	volatile LONG refs;           /* the thread and the game side */
	LONG generation;
	int hosting;
	char host[256];
	unsigned short port;
	SOCKET listener;
	HANDLE released;              /* set once the thread has closed the listener */
	/* guarded by g_lock */
	struct queue outbox;          /* for the current peer */
	struct queue dropped;         /* still to send to a peer net_accept_next dropped */
	int drop;                     /* net_accept_next asked to drop the peer */
	int accepting;                /* hosting: the next pending connection becomes the peer */
	LONG serial;                  /* bumped when the peer is dropped; stale frames are ignored */
	int running;                  /* the thread is still serving this link */
};

static CRITICAL_SECTION g_lock;
static INIT_ONCE g_init = INIT_ONCE_STATIC_INIT;
static enum net_state g_state = NET_IDLE;
static char g_detail[256];
static struct queue g_inbox[NET_CH_COUNT];
static size_t g_inbox_count[NET_CH_COUNT], g_inbox_bytes[NET_CH_COUNT];
static unsigned long g_peer_ipv4;   /* network byte order */
static struct link *g_link;
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

/* append all of src to dst, leaving src empty */
static void queue_move(struct queue *dst, struct queue *src)
{
	if (!src->head)
		return;
	if (dst->tail)
		dst->tail->next = src->head;
	else
		dst->head = src->head;
	dst->tail = src->tail;
	src->head = src->tail = NULL;
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

/* caller holds g_lock */
static void inbox_clear(void)
{
	for (int i = 0; i < NET_CH_COUNT; i++) {
		queue_clear(&g_inbox[i]);
		g_inbox_count[i] = 0;
		g_inbox_bytes[i] = 0;
	}
}

static void link_release(struct link *k)
{
	if (InterlockedDecrement(&k->refs))
		return;
	queue_clear(&k->outbox);
	queue_clear(&k->dropped);
	if (k->released)
		CloseHandle(k->released);
	free(k);
}

static int stale(struct link *k)
{
	return k->generation != g_generation;
}

/* Update state only if this link is still the current one. */
static void set_state(struct link *k, enum net_state s, const char *fmt, ...)
{
	va_list ap;
	EnterCriticalSection(&g_lock);
	if (!stale(k)) {
		g_state = s;
		va_start(ap, fmt);
		vsnprintf(g_detail, sizeof(g_detail), fmt, ap);
		va_end(ap);
		log_printf("net: %s (%s)", net_state_name(s), g_detail);
	}
	LeaveCriticalSection(&g_lock);
}

/* connections ------------------------------------------------------------------ */

static void conn_init(struct conn *c, SOCKET s, unsigned long ipv4)
{
	u_long nb = 1;
	BOOL yes = TRUE;
	memset(c, 0, sizeof(*c));
	c->s = s;
	c->ipv4 = ipv4;
	c->since = c->last_recv = c->last_send = GetTickCount();
	ioctlsocket(s, FIONBIO, &nb);
	setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char *)&yes, sizeof(yes));
}

static void conn_free(struct conn *c)
{
	if (c->s != INVALID_SOCKET)
		closesocket(c->s);
	c->s = INVALID_SOCKET;
	free(c->rbuf);
	c->rbuf = NULL;
	free(c->out);
	c->out = NULL;
	queue_clear(&c->outq);
}

static void conn_start_frame(struct conn *c, struct msg *m)
{
	c->out = m;
	c->out_off = 0;
	c->hdr[0] = (unsigned char)(m->len >> 24);
	c->hdr[1] = (unsigned char)(m->len >> 16);
	c->hdr[2] = (unsigned char)(m->len >> 8);
	c->hdr[3] = (unsigned char)m->len;
}

/* Send what the socket takes. Returns 0 if the connection failed. */
static int conn_write(struct conn *c)
{
	int n;
	if (!c->out)
		return 1;
	if (c->out_off < 4)
		n = send(c->s, (const char *)c->hdr + c->out_off, (int)(4 - c->out_off), 0);
	else
		n = send(c->s, c->out->data + (c->out_off - 4), (int)(c->out->len - (c->out_off - 4)), 0);
	if (n < 0)
		return WSAGetLastError() == WSAEWOULDBLOCK;
	c->out_off += (size_t)n;
	c->last_send = GetTickCount();
	if (c->out_off == 4 + c->out->len) {
		free(c->out);
		c->out = NULL;
	}
	return 1;
}

typedef int (*frame_fn)(void *ctx, const unsigned char *f, size_t len);

/* Hand each complete buffered frame to on_frame (heartbeats included, as len
 * 0). on_frame returns 1 to go on, 2 to stop and leave that frame buffered, or
 * anything else to stop. Returns 1, 2, -1 for a bad frame, or on_frame's result. */
static int conn_parse(struct conn *c, frame_fn on_frame, void *ctx)
{
	size_t pos = 0;
	int r = 1;

	while (c->rlen - pos >= 4) {
		size_t flen = ((size_t)c->rbuf[pos] << 24) | ((size_t)c->rbuf[pos + 1] << 16) |
		              ((size_t)c->rbuf[pos + 2] << 8) | c->rbuf[pos + 3];
		if (flen > MAX_FRAME) {
			r = -1;
			break;
		}
		if (c->rlen - pos - 4 < flen)
			break;
		r = on_frame(ctx, c->rbuf + pos + 4, flen);
		if (r == 2)
			break;
		pos += 4 + flen;
		if (r != 1)
			break;
	}
	memmove(c->rbuf, c->rbuf + pos, c->rlen - pos);
	c->rlen -= pos;
	/* a buffer grown for one big frame shrinks back once it is consumed */
	if (!c->rlen && c->rcap > 262144) {
		free(c->rbuf);
		c->rbuf = NULL;
		c->rcap = 0;
	}
	return r;
}

/* Read what has arrived and parse it. Returns 0 if the peer closed the
 * connection, otherwise as conn_parse. */
static int conn_read(struct conn *c, frame_fn on_frame, void *ctx)
{
	int n;

	if (c->rcap - c->rlen < 65536) {
		size_t ncap = c->rcap ? c->rcap * 2 : 131072;
		unsigned char *nb = realloc(c->rbuf, ncap);
		if (!nb)
			return -1;
		c->rbuf = nb;
		c->rcap = ncap;
	}
	n = recv(c->s, (char *)c->rbuf + c->rlen, (int)(c->rcap - c->rlen), 0);
	if (n == 0)
		return 0;
	if (n < 0)
		return WSAGetLastError() == WSAEWOULDBLOCK ? 1 : -1;
	c->rlen += (size_t)n;
	c->last_recv = GetTickCount();
	return conn_parse(c, on_frame, ctx);
}

/* drains: a closed peer still gets what was queued for it -------------------- */

struct drains {
	struct conn c[MAX_DRAINS];
	DWORD deadline[MAX_DRAINS];
};

/* Take over c (and the frames in q) to finish sending. c is reset. */
static void drain_add(struct drains *d, struct conn *c, struct queue *q)
{
	int i;
	if (q)
		queue_move(&c->outq, q);
	if (c->s == INVALID_SOCKET || (!c->out && !c->outq.head)) {
		conn_free(c);
		return;
	}
	for (i = 0; i < MAX_DRAINS && d->c[i].s != INVALID_SOCKET; i++)
		;
	if (i == MAX_DRAINS) {
		conn_free(c);
		return;
	}
	d->c[i] = *c;
	d->deadline[i] = GetTickCount() + DRAIN_MS;
	memset(c, 0, sizeof(*c));
	c->s = INVALID_SOCKET;
}

static int drains_busy(const struct drains *d)
{
	for (int i = 0; i < MAX_DRAINS; i++)
		if (d->c[i].s != INVALID_SOCKET)
			return 1;
	return 0;
}

static int discard_frame(void *ctx, const unsigned char *f, size_t len)
{
	(void)ctx; (void)f; (void)len;
	return 1;
}

static void drains_fdset(struct drains *d, fd_set *rd, fd_set *wr)
{
	for (int i = 0; i < MAX_DRAINS; i++) {
		struct conn *c = &d->c[i];
		if (c->s == INVALID_SOCKET)
			continue;
		if (c->shut)
			FD_SET(c->s, rd);
		else
			FD_SET(c->s, wr);
	}
}

static void drains_service(struct drains *d, fd_set *rd, fd_set *wr)
{
	DWORD now = GetTickCount();
	for (int i = 0; i < MAX_DRAINS; i++) {
		struct conn *c = &d->c[i];
		int done = 0;
		if (c->s == INVALID_SOCKET)
			continue;
		if ((LONG)(now - d->deadline[i]) >= 0) {
			done = 1;
		} else if (!c->shut && FD_ISSET(c->s, wr)) {
			if (!c->out && c->outq.head)
				conn_start_frame(c, queue_pop(&c->outq));
			if (!conn_write(c)) {
				done = 1;
			} else if (!c->out && !c->outq.head) {
				/* all sent: say so, then wait for the peer to close its side, so
				 * unread data on our side cannot turn the close into a reset */
				shutdown(c->s, SD_SEND);
				c->shut = 1;
			}
		} else if (c->shut && FD_ISSET(c->s, rd)) {
			done = conn_read(c, discard_frame, NULL) != 1;
		}
		if (done)
			conn_free(c);
	}
}

/* the link thread ---------------------------------------------------------------- */

struct ctx {
	struct link *k;
	LONG serial;                  /* k->serial when the current peer was taken on */
};

/* frame from the peer: queue it for the game. Returns -1 if the peer floods. */
static int deliver(void *p, const unsigned char *f, size_t len)
{
	struct ctx *x = p;
	unsigned ch;
	struct msg *m;
	int r = 1;

	if (len <= 1)
		return 1;   /* heartbeat */
	ch = f[0];
	if (ch >= NET_CH_COUNT)
		return 1;
	m = msg_new((const char *)f + 1, len - 1);
	if (!m)
		return -1;
	EnterCriticalSection(&g_lock);
	if (stale(x->k) || x->serial != x->k->serial) {
		free(m);
	} else if (ch == NET_CH_DISCOVERY && g_inbox_count[ch] >= DISCOVERY_MAX) {
		struct msg *old = queue_pop(&g_inbox[ch]);
		g_inbox_bytes[ch] -= old->len;
		free(old);
		queue_push(&g_inbox[ch], m);
		g_inbox_bytes[ch] += m->len;
	} else if (g_inbox_count[ch] >= INBOX_MAX_MSGS || g_inbox_bytes[ch] + m->len > INBOX_MAX_BYTES) {
		free(m);
		r = -1;
	} else {
		queue_push(&g_inbox[ch], m);
		g_inbox_count[ch]++;
		g_inbox_bytes[ch] += m->len;
	}
	LeaveCriticalSection(&g_lock);
	return r;
}

/* pending connection: stop at its first real message (heartbeats don't count) */
static int first_frame(void *p, const unsigned char *f, size_t len)
{
	(void)p;
	return len > 1 && f[0] < NET_CH_COUNT ? 2 : 1;
}

static SOCKET connect_peer(struct link *k)
{
	struct addrinfo hints, *res, *ai;
	char port[16];
	SOCKET s = INVALID_SOCKET;
	int rc;

	set_state(k, NET_CONNECTING, "connecting to %s:%u", k->host, k->port);
	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_INET;
	hints.ai_socktype = SOCK_STREAM;
	snprintf(port, sizeof(port), "%u", k->port);
	rc = getaddrinfo(k->host, port, &hints, &res);
	if (rc) {
		set_state(k, NET_ERROR, "cannot resolve %s (%d)", k->host, rc);
		return INVALID_SOCKET;
	}

	for (ai = res; ai && !stale(k); ai = ai->ai_next) {
		u_long nb = 1;
		DWORD start = GetTickCount();
		s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
		if (s == INVALID_SOCKET)
			continue;
		ioctlsocket(s, FIONBIO, &nb);
		if (connect(s, ai->ai_addr, (int)ai->ai_addrlen) == 0)
			break;
		if (WSAGetLastError() == WSAEWOULDBLOCK) {
			while (!stale(k) && GetTickCount() - start < CONNECT_MS) {
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
	if (s != INVALID_SOCKET && ai) {
		EnterCriticalSection(&g_lock);
		if (!stale(k))
			g_peer_ipv4 = ((struct sockaddr_in *)ai->ai_addr)->sin_addr.s_addr;
		LeaveCriticalSection(&g_lock);
	}
	freeaddrinfo(res);
	if (s == INVALID_SOCKET) {
		set_state(k, NET_ERROR, "could not connect to %s:%u", k->host, k->port);
		return INVALID_SOCKET;
	}
	set_state(k, NET_CONNECTED, "connected to %s:%u", k->host, k->port);
	return s;
}

static void ip_string(unsigned long ipv4, char *buf, size_t len)
{
	struct in_addr a;
	a.s_addr = ipv4;
	inet_ntop(AF_INET, &a, buf, len);
}

static DWORD WINAPI link_thread(LPVOID param)
{
	struct link *k = param;
	struct conn peer, pending[MAX_PENDING];
	struct drains drains;
	struct ctx x = { k, 0 };
	int npending = 0;

	memset(&peer, 0, sizeof(peer));
	peer.s = INVALID_SOCKET;
	memset(&drains, 0, sizeof(drains));
	for (int i = 0; i < MAX_DRAINS; i++)
		drains.c[i].s = INVALID_SOCKET;

	if (!k->hosting) {
		SOCKET s = connect_peer(k);
		if (s == INVALID_SOCKET)
			goto out;
		conn_init(&peer, s, 0);
		EnterCriticalSection(&g_lock);
		x.serial = k->serial;
		LeaveCriticalSection(&g_lock);
	}

	while (!stale(k)) {
		fd_set rd, wr;
		struct timeval tv = { 0, POLL_MS * 1000 };
		DWORD now = GetTickCount();
		int drop;

		/* the game asked to drop the peer (hosting: accept the next one) */
		EnterCriticalSection(&g_lock);
		drop = k->drop;
		k->drop = 0;
		if (drop) {
			struct queue q = k->dropped;
			k->dropped.head = k->dropped.tail = NULL;
			LeaveCriticalSection(&g_lock);
			if (peer.s != INVALID_SOCKET)
				log_printf("net: dropping the peer");
			drain_add(&drains, &peer, &q);
			queue_clear(&q);
		} else {
			LeaveCriticalSection(&g_lock);
		}

		/* next frame for the peer */
		if (peer.s != INVALID_SOCKET && !peer.out) {
			struct msg *m;
			EnterCriticalSection(&g_lock);
			m = queue_pop(&k->outbox);
			LeaveCriticalSection(&g_lock);
			if (!m && now - peer.last_send >= HEARTBEAT_MS)
				m = msg_new(NULL, 0);
			if (m)
				conn_start_frame(&peer, m);
		}
		if (peer.s != INVALID_SOCKET && now - peer.last_recv >= TIMEOUT_MS) {
			set_state(k, NET_CLOSED, "connection timed out");
			conn_free(&peer);
		}
		/* pending connections that stay silent are dropped */
		for (int i = 0; i < npending; i++) {
			if (now - pending[i].since >= PENDING_MS) {
				conn_free(&pending[i]);
				pending[i--] = pending[--npending];
			}
		}

		FD_ZERO(&rd);
		FD_ZERO(&wr);
		if (k->listener != INVALID_SOCKET && npending < MAX_PENDING)
			FD_SET(k->listener, &rd);
		for (int i = 0; i < npending; i++)
			FD_SET(pending[i].s, &rd);
		if (peer.s != INVALID_SOCKET) {
			FD_SET(peer.s, &rd);
			if (peer.out)
				FD_SET(peer.s, &wr);
		}
		drains_fdset(&drains, &rd, &wr);
		if (!rd.fd_count && !wr.fd_count) {
			/* nothing to wait on (client whose peer is gone) */
			if (!k->hosting)
				break;
			Sleep(POLL_MS);
			continue;
		}
		if (select(0, &rd, &wr, NULL, &tv) < 0) {
			set_state(k, NET_ERROR, "select failed (%d)", WSAGetLastError());
			break;
		}

		if (k->listener != INVALID_SOCKET && FD_ISSET(k->listener, &rd)) {
			struct sockaddr_in from;
			int flen = sizeof(from);
			SOCKET s = accept(k->listener, (struct sockaddr *)&from, &flen);
			if (s != INVALID_SOCKET) {
				char ip[64];
				ip_string(from.sin_addr.s_addr, ip, sizeof(ip));
				log_printf("net: connection from %s", ip);
				conn_init(&pending[npending++], s, from.sin_addr.s_addr);
			}
		}

		for (int i = 0; i < npending; i++) {
			struct conn *c = &pending[i];
			int r;
			if (!FD_ISSET(c->s, &rd))
				continue;
			r = conn_read(c, first_frame, NULL);
			if (r == 2) {
				int take;
				char ip[64];
				ip_string(c->ipv4, ip, sizeof(ip));
				EnterCriticalSection(&g_lock);
				take = k->accepting && peer.s == INVALID_SOCKET;
				if (take) {
					k->accepting = 0;
					x.serial = k->serial;
					g_peer_ipv4 = c->ipv4;
				}
				LeaveCriticalSection(&g_lock);
				if (take) {
					/* its first message (still buffered) and anything after it go to the game */
					peer = *c;
					set_state(k, NET_CONNECTED, "connected to %s", ip);
					if (conn_parse(&peer, deliver, &x) < 0) {
						set_state(k, NET_CLOSED, "dropped the peer: bad data or too many messages");
						conn_free(&peer);
					}
				} else {
					struct msg *m = msg_new(NULL, sizeof(REFUSE_FULL));
					log_printf("net: refusing %s: a player is already connected", ip);
					if (m) {
						m->data[0] = NET_CH_LUA;
						memcpy(m->data + 1, REFUSE_FULL, sizeof(REFUSE_FULL) - 1);
						queue_push(&c->outq, m);
					}
					c->rlen = 0;
					drain_add(&drains, c, NULL);
				}
				pending[i--] = pending[--npending];
			} else if (r != 1) {
				conn_free(c);
				pending[i--] = pending[--npending];
			}
		}

		if (peer.s != INVALID_SOCKET && FD_ISSET(peer.s, &rd)) {
			int r = conn_read(&peer, deliver, &x);
			if (r == 0) {
				set_state(k, NET_CLOSED, "peer disconnected");
				conn_free(&peer);
			} else if (r < 0) {
				set_state(k, NET_CLOSED, "dropped the peer: bad data or too many messages");
				conn_free(&peer);
			}
		}
		if (peer.s != INVALID_SOCKET && peer.out && FD_ISSET(peer.s, &wr) && !conn_write(&peer)) {
			set_state(k, NET_CLOSED, "send failed (%d)", WSAGetLastError());
			conn_free(&peer);
		}
		drains_service(&drains, &rd, &wr);
	}

out:
	/* superseded, closed or failed: free the port first, then let the peer
	 * have what was queued for it */
	EnterCriticalSection(&g_lock);
	k->running = 0;
	LeaveCriticalSection(&g_lock);
	if (k->listener != INVALID_SOCKET) {
		closesocket(k->listener);
		k->listener = INVALID_SOCKET;
	}
	if (k->released)
		SetEvent(k->released);
	for (int i = 0; i < npending; i++)
		conn_free(&pending[i]);
	{
		struct queue q;
		EnterCriticalSection(&g_lock);
		q = k->outbox;
		k->outbox.head = k->outbox.tail = NULL;
		queue_move(&q, &k->dropped);
		LeaveCriticalSection(&g_lock);
		drain_add(&drains, &peer, &q);
		queue_clear(&q);
	}
	while (drains_busy(&drains)) {
		fd_set rd, wr;
		struct timeval tv = { 0, POLL_MS * 1000 };
		FD_ZERO(&rd);
		FD_ZERO(&wr);
		drains_fdset(&drains, &rd, &wr);
		if (select(0, &rd, &wr, NULL, &tv) < 0)
			break;
		drains_service(&drains, &rd, &wr);
	}
	for (int i = 0; i < MAX_DRAINS; i++)
		conn_free(&drains.c[i]);
	link_release(k);
	return 0;
}

/* game-side API ------------------------------------------------------------------ */

/* Detach the current link; its thread finishes sending in the background. */
static void stop_link(void)
{
	struct link *k;
	EnterCriticalSection(&g_lock);
	InterlockedIncrement(&g_generation);
	k = g_link;
	g_link = NULL;
	inbox_clear();
	g_peer_ipv4 = 0;
	LeaveCriticalSection(&g_lock);
	if (!k)
		return;
	/* a new host may want the same port: wait until the listener is closed */
	if (k->hosting && k->released)
		WaitForSingleObject(k->released, 2000);
	link_release(k);
}

static SOCKET open_listener(unsigned short port, char *err, size_t errlen)
{
	struct sockaddr_in addr;
	SOCKET ls;
	BOOL yes = TRUE;

	ls = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (ls == INVALID_SOCKET) {
		snprintf(err, errlen, "cannot create a socket (%d)", WSAGetLastError());
		return INVALID_SOCKET;
	}
	/* never share the port with another program listening on it */
	setsockopt(ls, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (const char *)&yes, sizeof(yes));
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons(port);
	addr.sin_addr.s_addr = htonl(INADDR_ANY);
	if (bind(ls, (struct sockaddr *)&addr, sizeof(addr)) || listen(ls, MAX_PENDING)) {
		int e = WSAGetLastError();
		if (e == WSAEADDRINUSE || e == WSAEACCES)
			snprintf(err, errlen, "port %u is in use by another program (%d)", port, e);
		else
			snprintf(err, errlen, "cannot listen on port %u (%d)", port, e);
		closesocket(ls);
		return INVALID_SOCKET;
	}
	return ls;
}

static int start_link(int hosting, const char *host, unsigned short port, char *err, size_t errlen)
{
	struct link *k;
	HANDLE t;

	ensure_init();
	stop_link();

	k = calloc(1, sizeof(*k));
	if (!k) {
		snprintf(err, errlen, "out of memory");
		return 0;
	}
	k->refs = 2;
	k->running = 1;
	k->hosting = hosting;
	k->port = port;
	k->listener = INVALID_SOCKET;
	k->accepting = 1;
	if (host)
		snprintf(k->host, sizeof(k->host), "%s", host);
	if (hosting) {
		k->listener = open_listener(port, err, errlen);
		if (k->listener == INVALID_SOCKET) {
			log_printf("net: %s", err);
			free(k);
			return 0;
		}
		k->released = CreateEventA(NULL, TRUE, FALSE, NULL);
	}

	EnterCriticalSection(&g_lock);
	k->generation = g_generation;
	g_link = k;
	g_state = hosting ? NET_LISTENING : NET_CONNECTING;
	snprintf(g_detail, sizeof(g_detail), hosting ? "listening on port %u" : "starting", port);
	t = CreateThread(NULL, 0, link_thread, k, 0, NULL);
	if (!t) {
		g_link = NULL;
		g_state = NET_ERROR;
		snprintf(g_detail, sizeof(g_detail), "cannot start network thread");
	}
	LeaveCriticalSection(&g_lock);
	if (!t) {
		if (k->listener != INVALID_SOCKET)
			closesocket(k->listener);
		if (k->released)
			CloseHandle(k->released);
		free(k);
		snprintf(err, errlen, "cannot start network thread");
		return 0;
	}
	CloseHandle(t);
	if (hosting)
		log_printf("net: listening on port %u", port);
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

int net_accept_next(void)
{
	int ok = 0;
	ensure_init();
	EnterCriticalSection(&g_lock);
	if (g_link && g_link->hosting && g_link->running) {
		struct link *k = g_link;
		queue_move(&k->dropped, &k->outbox);
		k->drop = 1;
		k->accepting = 1;
		k->serial++;
		inbox_clear();
		g_peer_ipv4 = 0;
		g_state = NET_LISTENING;
		snprintf(g_detail, sizeof(g_detail), "listening on port %u", k->port);
		ok = 1;
	}
	LeaveCriticalSection(&g_lock);
	if (ok)
		log_printf("net: listening for the next player");
	return ok;
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
	if (g_link && g_state == NET_CONNECTED) {
		queue_push(&g_link->outbox, m);
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
	if (m) {
		g_inbox_count[ch]--;
		g_inbox_bytes[ch] -= m->len;
	}
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
