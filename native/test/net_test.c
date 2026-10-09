/*
 * Exercise net.c without the game, driven by a Python peer (peer.py):
 *   net_test host [port]        echo server
 *   net_test client <ip> [port] echo client
 * Messages starting "cmd:" are commands: quit (send "bye", close, exit), next
 * (host: drop this peer and take the next) and pause (stop reading for 3 s).
 * Anything else is echoed back as "echo:<message>".
 */
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
	const char *addr = hosting ? NULL : (argc > 2 ? argv[2] : "127.0.0.1");
	unsigned short port = (unsigned short)atoi(argc > (hosting ? 2 : 3) ? argv[hosting ? 2 : 3] : "24680");
	enum net_state last = -1;
	DWORD start = GetTickCount(), paused_until = 0;

	setvbuf(stdout, NULL, _IONBF, 0);
	log_init();
	if (!(hosting ? net_host(port, err, sizeof(err)) : net_connect(addr, port, err, sizeof(err)))) {
		printf("start failed: %s\n", err);
		return 1;
	}
	while (GetTickCount() - start < 90000) {
		char *data;
		size_t len;
		enum net_state s = net_status(detail, sizeof(detail));
		if (s != last) {
			printf("state %s: %s\n", net_state_name(s), detail);
			last = s;
		}
		if (!hosting && (s == NET_CLOSED || s == NET_ERROR))
			break;
		if (paused_until && (LONG)(GetTickCount() - paused_until) < 0) {
			Sleep(10);
			continue;
		}
		paused_until = 0;
		while (net_recv(NET_CH_LUA, &data, &len)) {
			char reply[4096];
			int n;
			if (len == 8 && !memcmp(data, "cmd:quit", 8)) {
				net_free(data);
				net_send(NET_CH_LUA, "bye", 3);
				net_close();
				printf("quit\n");
				Sleep(3000);   /* the link thread sends "bye" in the background */
				return 0;
			}
			if (len == 8 && !memcmp(data, "cmd:next", 8)) {
				printf("accept next: %d\n", net_accept_next());
				net_free(data);
				continue;
			}
			if (len == 9 && !memcmp(data, "cmd:pause", 9)) {
				printf("pausing\n");
				paused_until = GetTickCount() + 3000;
				net_free(data);
				break;
			}
			n = snprintf(reply, sizeof(reply), "echo:%.*s", (int)len, data);
			net_send(NET_CH_LUA, reply, (size_t)n);
			net_free(data);
		}
		Sleep(10);
	}
	printf("ended\n");
	return 0;
}
