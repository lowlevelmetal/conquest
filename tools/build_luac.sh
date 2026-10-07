#!/usr/bin/env bash
# Build a Lua 5.0.3 compiler that emits bytecode the SWBF2 Classic Collection
# can load: 32-bit size_t, float lua_Number, and MAXSTACK=128 (the game's VM
# encodes RK constant operands starting at 128, not stock Lua's 250).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p lua50 && cd lua50
[ -f lua-5.0.3.tar.gz ] || curl -sSfLO https://www.lua.org/ftp/lua-5.0.3.tar.gz
rm -rf lua-5.0.3 && tar xzf lua-5.0.3.tar.gz && cd lua-5.0.3

cat > etc/swbf_number.h <<'H'
/* SWBF2 uses Lua 5.0 with single-precision floats */
#define LUA_NUMBER	float
#define LUA_NUMBER_SCAN	"%f"
#define LUA_NUMBER_FMT	"%.7g"
#define lua_str2number(s,p)	strtod((s), (p))
H
sed -i 's/#define MAXSTACK\t250/#define MAXSTACK\t128/' src/llimits.h
grep -qP 'define MAXSTACK\t128' src/llimits.h

make CC="gcc -m32 -std=gnu89 -w" NUMBER="-DLUA_USER_H='\"../etc/swbf_number.h\"'" MYLDFLAGS="-m32" >/dev/null
echo "built $(pwd)/bin/luac"
