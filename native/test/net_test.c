/* Exercise net.c without the game: echo server or client, driven by a Python peer. */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "../net.h"
#include "../log.h"

int main(int argc, char **argv)
{
	char err[256], detail[256];
	int hosting = argc > 1 && !strcmp(argv[1], "host");
	const char *addr = argc > 2 ? argv[2] : "127.0.0.1";
	unsigned short port = (unsigned short)(argc > 3 ? atoi(argv[3]) : 24680);
	enum net_state last = -1;
	DWORD start = GetTickCount();

	log_init();
	if (!(hosting ? net_host(port, err, sizeof(err)) : net_connect(addr, port, err, sizeof(err)))) {
		printf("start failed: %s\n", err);
		return 1;
	}
	while (GetTickCount() - start < 60000) {
		char *data;
		size_t len;
		enum net_state s = net_status(detail, sizeof(detail));
		if (s != last) {
			printf("state %s: %s\n", net_state_name(s), detail);
			fflush(stdout);
			last = s;
		}
		if (s == NET_CLOSED || s == NET_ERROR)
			break;
		while (net_recv(&data, &len)) {
			char reply[4096];
			int n = snprintf(reply, sizeof(reply), "echo:%.*s", (int)len, data);
			if (len == 4 && !memcmp(data, "quit", 4)) {
				net_free(data);
				net_close();
				printf("quit\n");
				return 0;
			}
			net_send(reply, (size_t)n);
			net_free(data);
		}
		Sleep(10);
	}
	printf("ended\n");
	return 0;
}
