/* Bindings to the Lua 5.0 C API compiled into Battlefront2.dll. */
#ifndef CONQUEST_GAME_H
#define CONQUEST_GAME_H

#include <stddef.h>
#include <windows.h>

typedef struct lua_State lua_State;
typedef int (*lua_CFunction)(lua_State *L);

#define LUA_GLOBALSINDEX (-10001)
#define LUA_TNIL 0

struct lua_api {
	int         (*gettop)(lua_State *L);
	void        (*settop)(lua_State *L, int idx);
	void        (*pushvalue)(lua_State *L, int idx);
	int         (*type)(lua_State *L, int idx);
	const char *(*tostring)(lua_State *L, int idx);
	size_t      (*strlen)(lua_State *L, int idx);
	float       (*tonumber)(lua_State *L, int idx);
	void        (*pushnil)(lua_State *L);
	void        (*pushnumber)(lua_State *L, float n);
	void        (*pushlstring)(lua_State *L, const char *s, size_t len);
	void        (*pushstring)(lua_State *L, const char *s);
	void        (*pushcclosure)(lua_State *L, lua_CFunction fn, int n);
	void        (*gettable)(lua_State *L, int idx);
	void        (*settable)(lua_State *L, int idx);
	void        (*newtable)(lua_State *L);
	void        (*pushboolean)(lua_State *L, int b);
	int         (*loadbuffer)(lua_State *L, const char *buf, size_t len, const char *name);
	int         (*pcall)(lua_State *L, int nargs, int nresults, int errfunc);
};

extern struct lua_api lua;

#define lua_pop(L, n) lua.settop(L, -(n) - 1)

/* Resolve the Lua API and install the ScriptCB_DoFile hook. Returns 0 on failure. */
int game_patch(HMODULE bf2);

/* The engine's active Lua state (shell or mission), or NULL. */
lua_State *game_current_state(void);

/* Call the Lua global ConquestNet_Tick in the active state, if defined.
 * Safe to call from the game thread outside Lua; ignores re-entrant calls. */
void bridge_tick(void);

/* Register the ConquestNet_* functions into L and run the boot script (once per state). */
void bridge_register(lua_State *L);

/* Called after every ScriptCB_DoFile(name) so Lua can hook script loads. */
void bridge_after_dofile(lua_State *L, const char *name);

/* Battlefront2.dll is being unloaded: drop all state tied to it. */
void bridge_unload(void);
void game_unload(void);

#endif
