# Cross-compile the conquest loader (a dle_crashpad.dll proxy) and the Windows
# setup program with mingw-w64.
CC      = x86_64-w64-mingw32-gcc
WINDRES = x86_64-w64-mingw32-windres
CFLAGS  = -O2 -Wall -Wextra -std=c11 -D_WIN32_WINNT=0x0601
LDFLAGS = -shared -static-libgcc -Wl,--enable-stdcall-fixup
LIBS    = -lws2_32 -lbcrypt

SRCS = proxy.c game.c bridge.c net.c udp.c shim.c crash.c iat.c testwin.c log.c
OUT  = build/dle_crashpad.dll

SETUP        = build/OnlineGalacticConquest-Setup.exe
SETUP_CFLAGS = -O2 -Wall -Wextra -std=c11 -municode -mwindows -DUNICODE -D_UNICODE -D_WIN32_WINNT=0x0A00
SETUP_LIBS   = -s -static-libgcc -lcomctl32 -lshell32 -lshlwapi -lole32 -luuid -ladvapi32
MOD_FILES    = $(shell find ../mod -type f)

all: $(OUT) $(SETUP)

$(OUT): $(SRCS) exports.def game.h net.h udp.h shim.h iat.h log.h version.h
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS) exports.def $(LIBS)

# the list of mod files, rewritten only when a file is added, removed or
# renamed, so the payload is rebuilt for those too (not only for edits)
build/mod_files.txt: FORCE
	@mkdir -p build
	@find ../mod -type f | LC_ALL=C sort > $@.tmp
	@if cmp -s $@.tmp $@; then rm $@.tmp; else mv $@.tmp $@; fi

# the files setup writes into the game folder
build/payload.bin: $(OUT) setup/pack.py $(MOD_FILES) build/mod_files.txt ../dist/README.txt
	python3 setup/pack.py $@ $(OUT) ../mod ../dist/README.txt

build/setup_res.o: setup/setup.rc setup/resource.h setup/setup.manifest setup/conquest.ico version.h build/payload.bin
	$(WINDRES) -O coff -o $@ setup/setup.rc

$(SETUP): setup/setup.c setup/resource.h version.h build/setup_res.o
	$(CC) $(SETUP_CFLAGS) -o $@ setup/setup.c build/setup_res.o $(SETUP_LIBS)

# net.c checks under Wine (python3 test/peer.py drives build/net_test.exe)
build/net_test.exe: test/net_test.c net.c net.h log.c log.h
	@mkdir -p build
	$(CC) $(CFLAGS) -o $@ test/net_test.c net.c log.c $(LIBS)

# "back to game select": run from the game folder (see test/reload_test.c)
# -O0: each call must read the import table, which the loader patches after
# the program starts (as the launcher's calls do)
build/reload_test.exe: test/reload_test.c
	@mkdir -p build
	$(CC) -O0 -Wall -Wextra -std=c11 -o $@ test/reload_test.c

# crash log under many handled exceptions (see test/crash_test.c)
build/crash_test.exe: test/crash_test.c
	@mkdir -p build
	$(CC) -O0 -Wall -Wextra -std=c11 -o $@ test/crash_test.c

test: build/net_test.exe build/reload_test.exe build/crash_test.exe
	python3 test/peer.py build/net_test.exe

clean:
	rm -rf build

.PHONY: all clean test FORCE
FORCE:
