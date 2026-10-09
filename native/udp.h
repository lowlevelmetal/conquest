/* Lobby check that the host's battle port (UDP) can be reached. */
#ifndef CONQUEST_UDP_H
#define CONQUEST_UDP_H

enum {
	UDP_PROBE_NONE,
	UDP_PROBE_RUNNING,
	UDP_PROBE_OK,
	UDP_PROBE_FAILED,
};

/* Host: answer probes on port until udp_echo_stop. 0 if the port can't be opened. */
int  udp_echo_start(unsigned short port);
void udp_echo_stop(void);

/* Joining player: probe host:port for a few seconds; poll udp_probe_result. */
int  udp_probe_start(const char *host, unsigned short port);
void udp_probe_stop(void);
int  udp_probe_result(void);

/* Test copies (CONQUEST_INSTANCE set): CONQUEST_TEST_BLOCK_UDP=1 makes the
 * battle port unreachable. */
int  udp_test_blocked(void);

#endif
