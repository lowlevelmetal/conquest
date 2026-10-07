/*
 * ConquestNet_* functions exposed to the game's Lua, plus the boot script.
 *
 * Mod Lua lives as plain source in <game>/conquest/lua and is compiled by the
 * game's own parser (luaL_loadbuffer), so no .lvl repacking is needed.
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "game.h"
#include "log.h"
#include "net.h"
#include "shim.h"

#define CONQUEST_VERSION "0.1.0"
#define BOOT_SCRIPT "lua\\boot.lua"
#define MAX_VALUES 64

struct kv {
	char *key;
	char *value;
	size_t len;
};

/* survives Lua state teardown (shell <-> battle) */
static struct kv g_values[MAX_VALUES];
static CRITICAL_SECTION g_values_lock;
static INIT_ONCE g_values_init = INIT_ONCE_STATIC_INIT;

static BOOL CALLBACK init_values(PINIT_ONCE once, PVOID param, PVOID *ctx)
{
	(void)once; (void)param; (void)ctx;
	InitializeCriticalSection(&g_values_lock);
	return TRUE;
}

static const char *arg_string(lua_State *L, int idx, size_t *len)
{
	const char *s;
	if (lua.gettop(L) < idx)
		return NULL;
	s = lua.tostring(L, idx);
	if (s && len)
		*len = lua.strlen(L, idx);
	return s;
}

static int return_error(lua_State *L, const char *err)
{
	lua.pushnil(L);
	lua.pushstring(L, err);
	return 2;
}

/* Resolve a path inside <game>/conquest, rejecting anything that escapes it. */
static int mod_path(const char *rel, char *out, size_t outlen)
{
	if (!rel || !rel[0] || strstr(rel, "..") || strchr(rel, ':') || rel[0] == '\\' || rel[0] == '/')
		return 0;
	snprintf(out, outlen, "%sconquest\\%s", game_dir(), rel);
	for (char *p = out; *p; p++)
		if (*p == '/')
			*p = '\\';
	return 1;
}

static char *read_file(const char *path, size_t *len)
{
	FILE *f = fopen(path, "rb");
	char *buf;
	long n;

	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	n = ftell(f);
	fseek(f, 0, SEEK_SET);
	buf = malloc(n > 0 ? (size_t)n : 1);
	if (buf && n > 0 && fread(buf, 1, (size_t)n, f) != (size_t)n) {
		free(buf);
		buf = NULL;
	}
	fclose(f);
	if (buf)
		*len = (size_t)(n > 0 ? n : 0);
	return buf;
}

/* Load and run a mod Lua file in L. Returns 1 on success; on failure logs and,
 * if keep_error, leaves the message on the stack. */
static int run_file(lua_State *L, const char *rel, int keep_error)
{
	char path[MAX_PATH], chunk[MAX_PATH];
	size_t len;
	char *src;
	int rc;

	if (!mod_path(rel, path, sizeof(path))) {
		if (keep_error)
			lua.pushstring(L, "invalid path");
		return 0;
	}
	src = read_file(path, &len);
	if (!src) {
		log_printf("bridge: cannot read %s", path);
		if (keep_error)
			lua.pushstring(L, "cannot read file");
		return 0;
	}
	snprintf(chunk, sizeof(chunk), "@%s", rel);
	rc = lua.loadbuffer(L, src, len, chunk);
	free(src);
	if (!rc)
		rc = lua.pcall(L, 0, 0, 0);
	if (rc) {
		const char *err = lua.tostring(L, -1);
		log_printf("bridge: error in %s: %s", rel, err ? err : "(no message)");
		if (!keep_error)
			lua_pop(L, 1);
		return 0;
	}
	return 1;
}

static int l_version(lua_State *L)
{
	lua.pushstring(L, CONQUEST_VERSION);
	return 1;
}

static int l_instance(lua_State *L)
{
	lua.pushstring(L, instance_name());
	return 1;
}

static int l_log(lua_State *L)
{
	const char *s = arg_string(L, 1, NULL);
	log_printf("lua: %s", s ? s : "(nil)");
	return 0;
}

static int l_readfile(lua_State *L)
{
	char path[MAX_PATH];
	size_t len;
	char *buf;

	if (!mod_path(arg_string(L, 1, NULL), path, sizeof(path)))
		return return_error(L, "invalid path");
	buf = read_file(path, &len);
	if (!buf)
		return return_error(L, "cannot read file");
	lua.pushlstring(L, buf, len);
	free(buf);
	return 1;
}

static int l_writefile(lua_State *L)
{
	char path[MAX_PATH];
	size_t len = 0;
	const char *data = arg_string(L, 2, &len);
	FILE *f;

	if (!data || !mod_path(arg_string(L, 1, NULL), path, sizeof(path)))
		return return_error(L, "invalid arguments");
	f = fopen(path, "wb");
	if (!f)
		return return_error(L, "cannot write file");
	fwrite(data, 1, len, f);
	fclose(f);
	lua.pushboolean(L, 1);
	return 1;
}

static int l_runfile(lua_State *L)
{
	char rel[MAX_PATH];
	const char *s = arg_string(L, 1, NULL);

	snprintf(rel, sizeof(rel), "%s", s ? s : "");
	if (!run_file(L, rel, 1)) {
		lua.pushnil(L);
		lua.pushvalue(L, -2);   /* error message */
		return 2;
	}
	lua.pushboolean(L, 1);
	return 1;
}

static int l_host(lua_State *L)
{
	char err[256];
	int port = lua.gettop(L) >= 1 ? (int)lua.tonumber(L, 1) : 0;

	if (port <= 0 || port > 65535)
		return return_error(L, "invalid port");
	if (!net_host((unsigned short)port, err, sizeof(err)))
		return return_error(L, err);
	lua.pushboolean(L, 1);
	return 1;
}

static int l_connect(lua_State *L)
{
	char err[256];
	const char *host = arg_string(L, 1, NULL);
	int port = lua.gettop(L) >= 2 ? (int)lua.tonumber(L, 2) : 0;

	if (!host || !host[0] || port <= 0 || port > 65535)
		return return_error(L, "invalid address");
	if (!net_connect(host, (unsigned short)port, err, sizeof(err)))
		return return_error(L, err);
	lua.pushboolean(L, 1);
	return 1;
}

static int l_close(lua_State *L)
{
	(void)L;
	net_close();
	return 0;
}

static int l_status(lua_State *L)
{
	char detail[256];
	enum net_state s = net_status(detail, sizeof(detail));
	lua.pushstring(L, net_state_name(s));
	lua.pushstring(L, detail);
	return 2;
}

static int l_send(lua_State *L)
{
	size_t len = 0;
	const char *data = arg_string(L, 1, &len);
	if (!data || !net_send(NET_CH_LUA, data, len)) {
		lua.pushnil(L);
		return 1;
	}
	lua.pushboolean(L, 1);
	return 1;
}

static int l_recv(lua_State *L)
{
	char *data;
	size_t len;
	if (!net_recv(NET_CH_LUA, &data, &len)) {
		lua.pushnil(L);
		return 1;
	}
	lua.pushlstring(L, data, len);
	net_free(data);
	return 1;
}

/* ConquestNet_SetTunnel(1/0): route engine LAN discovery through the TCP peer */
static int l_settunnel(lua_State *L)
{
	shim_set_tunnel(lua.gettop(L) >= 1 && lua.type(L, 1) != LUA_TNIL && lua.tonumber(L, 1) != 0.0f);
	return 0;
}

static int l_localaddresses(lua_State *L)
{
	char buf[512];
	net_local_addresses(buf, sizeof(buf));
	lua.pushstring(L, buf);
	return 1;
}

static int l_time(lua_State *L)
{
	static LARGE_INTEGER freq, start;
	LARGE_INTEGER now;
	if (!freq.QuadPart) {
		QueryPerformanceFrequency(&freq);
		QueryPerformanceCounter(&start);
	}
	QueryPerformanceCounter(&now);
	lua.pushnumber(L, (float)((double)(now.QuadPart - start.QuadPart) / (double)freq.QuadPart));
	return 1;
}

static int l_setvalue(lua_State *L)
{
	const char *key = arg_string(L, 1, NULL);
	size_t len = 0;
	const char *value = arg_string(L, 2, &len);
	struct kv *slot = NULL;

	if (!key)
		return 0;
	InitOnceExecuteOnce(&g_values_init, init_values, NULL, NULL);
	EnterCriticalSection(&g_values_lock);
	for (int i = 0; i < MAX_VALUES; i++) {
		if (g_values[i].key && !strcmp(g_values[i].key, key)) {
			slot = &g_values[i];
			break;
		}
		if (!slot && !g_values[i].key)
			slot = &g_values[i];
	}
	if (slot) {
		free(slot->value);
		slot->value = NULL;
		if (value) {
			if (!slot->key)
				slot->key = _strdup(key);
			slot->value = malloc(len ? len : 1);
			if (slot->value)
				memcpy(slot->value, value, len);
			slot->len = len;
		} else {
			free(slot->key);
			slot->key = NULL;
		}
	}
	LeaveCriticalSection(&g_values_lock);
	return 0;
}

static int l_getvalue(lua_State *L)
{
	const char *key = arg_string(L, 1, NULL);
	int found = 0;

	if (key) {
		InitOnceExecuteOnce(&g_values_init, init_values, NULL, NULL);
		EnterCriticalSection(&g_values_lock);
		for (int i = 0; i < MAX_VALUES; i++) {
			if (g_values[i].key && g_values[i].value && !strcmp(g_values[i].key, key)) {
				lua.pushlstring(L, g_values[i].value, g_values[i].len);
				found = 1;
				break;
			}
		}
		LeaveCriticalSection(&g_values_lock);
	}
	if (!found)
		lua.pushnil(L);
	return 1;
}

static const struct {
	const char *name;
	lua_CFunction fn;
} g_functions[] = {
	{ "ConquestNet_Version",        l_version },
	{ "ConquestNet_Log",            l_log },
	{ "ConquestNet_Instance",       l_instance },
	{ "ConquestNet_ReadFile",       l_readfile },
	{ "ConquestNet_WriteFile",      l_writefile },
	{ "ConquestNet_RunFile",        l_runfile },
	{ "ConquestNet_Host",           l_host },
	{ "ConquestNet_Connect",        l_connect },
	{ "ConquestNet_Close",          l_close },
	{ "ConquestNet_Status",         l_status },
	{ "ConquestNet_Send",           l_send },
	{ "ConquestNet_Recv",           l_recv },
	{ "ConquestNet_LocalAddresses", l_localaddresses },
	{ "ConquestNet_SetTunnel",      l_settunnel },
	{ "ConquestNet_Time",           l_time },
	{ "ConquestNet_SetValue",       l_setvalue },
	{ "ConquestNet_GetValue",       l_getvalue },
};

static void get_global(lua_State *L, const char *name)
{
	lua.pushstring(L, name);
	lua.gettable(L, LUA_GLOBALSINDEX);
}

void bridge_register(lua_State *L)
{
	int registered;

	get_global(L, "ConquestNet_Version");
	registered = lua.type(L, -1) != LUA_TNIL;
	lua_pop(L, 1);
	if (registered)
		return;

	for (size_t i = 0; i < sizeof(g_functions) / sizeof(g_functions[0]); i++) {
		lua.pushstring(L, g_functions[i].name);
		lua.pushcclosure(L, g_functions[i].fn, 0);
		lua.settable(L, LUA_GLOBALSINDEX);
	}
	log_printf("bridge: registered API in lua_State %p", (void *)L);
	run_file(L, BOOT_SCRIPT, 0);
}

void bridge_tick(void)
{
	static int busy;
	static int errors;
	lua_State *L = game_current_state();
	int top;

	if (busy || !L)
		return;
	busy = 1;
	top = lua.gettop(L);
	get_global(L, "ConquestNet_Tick");
	if (lua.type(L, -1) != LUA_TNIL && lua.pcall(L, 0, 0, 0)) {
		const char *err = lua.tostring(L, -1);
		if (errors++ < 10)
			log_printf("bridge: ConquestNet_Tick failed: %s", err ? err : "(no message)");
	}
	lua.settop(L, top);
	busy = 0;
}

void bridge_after_dofile(lua_State *L, const char *name)
{
	get_global(L, "ConquestNet_AfterDoFile");
	if (lua.type(L, -1) == LUA_TNIL) {
		lua_pop(L, 1);
		return;
	}
	lua.pushstring(L, name);
	if (lua.pcall(L, 1, 0, 0)) {
		const char *err = lua.tostring(L, -1);
		log_printf("bridge: ConquestNet_AfterDoFile(%s) failed: %s", name, err ? err : "(no message)");
		lua_pop(L, 1);
	}
}
