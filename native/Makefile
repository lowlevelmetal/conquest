# Cross-compile the conquest loader (a dle_crashpad.dll proxy) and the Windows
# setup program with mingw-w64.
CC      = x86_64-w64-mingw32-gcc
WINDRES = x86_64-w64-mingw32-windres
CFLAGS  = -O2 -Wall -Wextra -std=c11 -D_WIN32_WINNT=0x0601
LDFLAGS = -shared -static-libgcc -Wl,--enable-stdcall-fixup
LIBS    = -lws2_32

SRCS = proxy.c game.c bridge.c net.c shim.c crash.c iat.c testwin.c log.c
OUT  = build/dle_crashpad.dll

SETUP        = build/OnlineGalacticConquest-Setup.exe
SETUP_CFLAGS = -O2 -Wall -Wextra -std=c11 -municode -mwindows -DUNICODE -D_UNICODE -D_WIN32_WINNT=0x0A00
SETUP_LIBS   = -s -static-libgcc -lcomctl32 -lshell32 -lshlwapi -lole32 -luuid -ladvapi32
MOD_FILES    = $(shell find ../mod -type f)

all: $(OUT) $(SETUP)

$(OUT): $(SRCS) exports.def game.h net.h shim.h iat.h log.h version.h
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS) exports.def $(LIBS)

# the files setup writes into the game folder
build/payload.bin: $(OUT) setup/pack.py $(MOD_FILES) ../dist/README.txt
	python3 setup/pack.py $@ $(OUT) ../mod ../dist/README.txt

build/setup_res.o: setup/setup.rc setup/resource.h setup/setup.manifest setup/conquest.ico version.h build/payload.bin
	$(WINDRES) -O coff -o $@ setup/setup.rc

$(SETUP): setup/setup.c setup/resource.h version.h build/setup_res.o
	$(CC) $(SETUP_CFLAGS) -o $@ setup/setup.c build/setup_res.o $(SETUP_LIBS)

clean:
	rm -rf build

.PHONY: all clean
