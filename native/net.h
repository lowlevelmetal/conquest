/* Threaded single-peer TCP link with length-prefixed message framing. */
#ifndef CONQUEST_NET_H
#define CONQUEST_NET_H

#include <stddef.h>

enum net_state {
	NET_IDLE,
	NET_LISTENING,
	NET_CONNECTING,
	NET_CONNECTED,
	NET_CLOSED,     /* peer disconnected or link timed out */
	NET_ERROR,
};

int  net_host(unsigned short port, char *err, size_t errlen);
int  net_connect(const char *host, unsigned short port, char *err, size_t errlen);
void net_close(void);

/* Returns the current state; copies a human-readable detail into buf. */
enum net_state net_status(char *buf, size_t buflen);
const char *net_state_name(enum net_state s);

/* Queue a message for sending. Returns 0 if not connected or out of memory. */
int net_send(const char *data, size_t len);

/* Pop the next received message. Caller frees *data with net_free. Returns 0 if none. */
int  net_recv(char **data, size_t *len);
void net_free(char *data);

/* Comma-separated IPv4 addresses of this machine. */
void net_local_addresses(char *buf, size_t buflen);

#endif
