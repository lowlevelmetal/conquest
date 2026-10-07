# Cross-compile the conquest loader (a dle_crashpad.dll proxy) with mingw-w64.
CC      = x86_64-w64-mingw32-gcc
CFLAGS  = -O2 -Wall -Wextra -std=c11 -D_WIN32_WINNT=0x0601
LDFLAGS = -shared -static-libgcc -Wl,--enable-stdcall-fixup
LIBS    = -lws2_32

SRCS = proxy.c game.c bridge.c net.c shim.c crash.c log.c
OUT  = build/dle_crashpad.dll

$(OUT): $(SRCS) exports.def game.h net.h shim.h log.h
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS) exports.def $(LIBS)

clean:
	rm -rf build

.PHONY: clean
