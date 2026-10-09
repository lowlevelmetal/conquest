/*
 * Locate the Lua 5.0 API inside Battlefront2.dll and hook function registration.
 *
 * Each API function is found by a byte signature (call/RIP-relative operands
 * wildcarded), checked first at the RVA from the build we reverse engineered
 * and then by scanning .text. The ScriptCB_* registration tables live in .data
 * as {name, fn} pairs; we swap the function pointer of ScriptCB_DoFile for a
 * wrapper that registers our API into whichever lua_State calls it and lets
 * Lua react after each script loads.
 */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "game.h"
#include "log.h"

struct lua_api lua;

struct section {
	uint8_t *start;
	size_t size;
};

struct signature {
	const char *name;
	void **slot;
	DWORD rva;          /* location in Steam build 14742199 */
	const char *bytes;  /* hex bytes, "??" = wildcard */
};

#define SLOT(f) ((void **)&lua.f)

static const struct signature g_sigs[] = {
	{ "lua_gettop",       SLOT(gettop),       0x383ff0, "48 8B 41 10 48 2B 41 18 48 C1 F8 04 C3 CC CC CC" },
	{ "lua_settop",       SLOT(settop),       0x3849d0, "85 D2 78 3F 4C 63 C2 48 8B 51 18 4D 03 C0 4A 8D" },
	{ "lua_pushvalue",    SLOT(pushvalue),    0x384640, "48 83 EC 28 4C 8B C9 E8 ?? ?? ?? ?? 4D 8B 41 10" },
	{ "lua_type",         SLOT(type),         0x384ce0, "48 83 EC 28 E8 ?? ?? ?? ?? 48 85 C0 75 0A B8 FF" },
	{ "lua_tostring",     SLOT(tostring),     0x384bf0, "48 89 5C 24 08 57 48 83 EC 20 48 8B F9 E8 ?? ?? ?? ?? 48 8B D8 48 85 C0" },
	{ "lua_strlen",       SLOT(strlen),       0x384ac0, "40 53 48 83 EC 20 4C 8B C9 E8 ?? ?? ?? ?? 48 8B" },
	{ "lua_tonumber",     SLOT(tonumber),     0x384b40, "48 83 EC 38 E8 ?? ?? ?? ?? 48 85 C0 74 21 83 38 03 74 12 48 8D 54 24 20 48 8B C8 E8 ?? ?? ?? ?? 48 85 C0 74 0A F3 0F 10" },
	{ "lua_pushnil",      SLOT(pushnil),      0x384570, "48 8B 41 10 C7 00 00 00 00 00 48 83 41 10 10 C3" },
	{ "lua_pushnumber",   SLOT(pushnumber),   0x384580, "48 8B 41 10 F3 0F 11 48 08 C7 00 03 00 00 00 48" },
	{ "lua_pushlstring",  SLOT(pushlstring),  0x384500, "48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57 48 83 EC 20 4C 8B 49 20" },
	{ "lua_pushstring",   SLOT(pushstring),   0x3845a0, "48 89 6C 24 18 56 48 83 EC 20 48 8B EA 48 8B F1 48 85 D2 75 16 48 8B 41" },
	{ "lua_pushcclosure", SLOT(pushcclosure), 0x3843e0, "48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 4C 8B 49 20 48 8B F2 49 63" },
	{ "lua_gettable",     SLOT(gettable),     0x383fb0, "40 53 48 83 EC 20 48 8B D9 E8 ?? ?? ?? ?? 4C 8B 43 10 45 33 C9 49 83 E8" },
	{ "lua_settable",     SLOT(settable),     0x3849a0, "40 53 48 83 EC 20 48 8B D9 E8 ?? ?? ?? ?? 4C 8B 43 10 48 8B D0 48 8B CB" },
	{ "lua_newtable",     SLOT(newtable),     0x384230, "48 89 5C 24 08 57 48 83 EC 20 48 8B 51 20 48 8B" },
	{ "lua_pushboolean",  SLOT(pushboolean),  0x3843c0, "4C 8B 41 10 33 C0 85 D2 0F 95 C0 41 89 40 08 41" },
	{ "luaL_loadbuffer",  SLOT(loadbuffer),   0x385860, "48 83 EC 38 48 89 54 24 20 48 8D 15 ?? ?? ?? ??" },
	{ "lua_pcall",        SLOT(pcall),        0x384350, "48 89 5C 24 08 57 48 83 EC 40 4C 8B 59 38 41 8B" },
};

/* Registration helper whose first RIP-relative load is the engine's current lua_State. */
static const char *STATE_HELPER_SIG = "40 53 48 83 EC 20 48 8B D9 48 8B 0D ?? ?? ?? ?? E8 ?? ?? ?? ?? 48 8B 0D";
#define STATE_HELPER_RVA 0x249b80
static lua_State **g_current_state;
static lua_CFunction g_orig_hooked;

lua_State *game_current_state(void)
{
	return g_current_state ? *g_current_state : NULL;
}

void game_unload(void)
{
	g_current_state = NULL;
	g_orig_hooked = NULL;
}

/* Every mission and the shell load their scripts through this, in each Lua state. */
#define HOOK_FUNCTION "ScriptCB_DoFile"

static int parse_pattern(const char *s, int *out, int max)
{
	int n = 0;
	while (*s && n < max) {
		while (*s == ' ')
			s++;
		if (!*s)
			break;
		if (s[0] == '?') {
			out[n++] = -1;
		} else {
			unsigned v;
			sscanf(s, "%2x", &v);
			out[n++] = (int)v;
		}
		s += 2;
	}
	return n;
}

static int match_at(const uint8_t *p, const int *pat, int n)
{
	for (int i = 0; i < n; i++)
		if (pat[i] >= 0 && p[i] != pat[i])
			return 0;
	return 1;
}

static int find_sections(HMODULE mod, struct section *text, struct section *rdata, struct section *data)
{
	uint8_t *base = (uint8_t *)mod;
	IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *)base;
	IMAGE_NT_HEADERS64 *nt = (IMAGE_NT_HEADERS64 *)(base + dos->e_lfanew);
	IMAGE_SECTION_HEADER *sec = IMAGE_FIRST_SECTION(nt);
	int found = 0;

	for (int i = 0; i < nt->FileHeader.NumberOfSections; i++) {
		struct section *dst = NULL;
		if (!memcmp(sec[i].Name, ".text", 6))
			dst = text;
		else if (!memcmp(sec[i].Name, ".rdata", 7))
			dst = rdata;
		else if (!memcmp(sec[i].Name, ".data", 6))
			dst = data;
		if (dst) {
			dst->start = base + sec[i].VirtualAddress;
			dst->size = sec[i].Misc.VirtualSize;
			found++;
		}
	}
	return found == 3;
}

static void *resolve(HMODULE mod, const struct section *text, const struct signature *sig)
{
	int pat[128];
	int n = parse_pattern(sig->bytes, pat, 128);
	uint8_t *expected = (uint8_t *)mod + sig->rva;
	uint8_t *hit = NULL;
	int hits = 0;

	if (expected >= text->start && expected + n <= text->start + text->size && match_at(expected, pat, n))
		return expected;

	for (uint8_t *p = text->start; p + n <= text->start + text->size; p++) {
		if (match_at(p, pat, n)) {
			hit = p;
			if (++hits > 1)
				break;
		}
	}
	if (hits != 1) {
		log_printf("game: %s signature matched %d times", sig->name, hits);
		return NULL;
	}
	log_printf("game: %s found at rva %#lx (expected %#lx)", sig->name,
	           (unsigned long)(hit - (uint8_t *)mod), (unsigned long)sig->rva);
	return hit;
}

/* Find the {name, fn} pair for name in the .data registration tables. */
static uint64_t *find_reg_entry(const struct section *text, const struct section *rdata,
                                const struct section *data, const char *name)
{
	size_t len = strlen(name) + 1;

	/* strings may directly follow other constants, so don't require a leading NUL */
	for (uint8_t *s = rdata->start; s + len <= rdata->start + rdata->size; s++) {
		if (s[0] != (uint8_t)name[0] || memcmp(s, name, len))
			continue;
		for (uint64_t *e = (uint64_t *)data->start; (uint8_t *)(e + 2) <= data->start + data->size; e++) {
			if (e[0] == (uint64_t)(uintptr_t)s &&
			    e[1] >= (uint64_t)(uintptr_t)text->start &&
			    e[1] < (uint64_t)(uintptr_t)(text->start + text->size))
				return e;
		}
	}
	return NULL;
}

static int hook_entry(lua_State *L)
{
	char name[128] = "";
	const char *s;
	int r;

	bridge_register(L);
	s = lua.gettop(L) >= 1 ? lua.tostring(L, 1) : NULL;
	if (s)
		snprintf(name, sizeof(name), "%s", s);
	r = g_orig_hooked(L);
	if (name[0])
		bridge_after_dofile(L, name);
	return r;
}

int game_patch(HMODULE bf2)
{
	struct section text, rdata, data;
	uint64_t *entry;
	DWORD old;

	if (!find_sections(bf2, &text, &rdata, &data)) {
		log_printf("game: unexpected Battlefront2.dll layout");
		return 0;
	}
	for (size_t i = 0; i < sizeof(g_sigs) / sizeof(g_sigs[0]); i++) {
		*g_sigs[i].slot = resolve(bf2, &text, &g_sigs[i]);
		if (!*g_sigs[i].slot) {
			log_printf("game: cannot locate %s; this game build is not supported", g_sigs[i].name);
			return 0;
		}
	}

	{
		struct signature helper = { "current lua_State", NULL, STATE_HELPER_RVA, STATE_HELPER_SIG };
		uint8_t *p = resolve(bf2, &text, &helper);
		if (p) {
			int32_t disp = *(int32_t *)(p + 12);
			g_current_state = (lua_State **)(p + 16 + disp);
			log_printf("game: current lua_State global at rva %#lx",
			           (unsigned long)((uint8_t *)g_current_state - (uint8_t *)bf2));
		} else {
			log_printf("game: current lua_State global not found; per-frame tick disabled");
		}
	}

	entry = find_reg_entry(&text, &rdata, &data, HOOK_FUNCTION);
	if (!entry) {
		log_printf("game: cannot find registration entry for %s", HOOK_FUNCTION);
		return 0;
	}
	g_orig_hooked = (lua_CFunction)(uintptr_t)entry[1];
	VirtualProtect(&entry[1], sizeof(entry[1]), PAGE_READWRITE, &old);
	entry[1] = (uint64_t)(uintptr_t)hook_entry;
	VirtualProtect(&entry[1], sizeof(entry[1]), old, &old);

	log_printf("game: hooked %s (entry rva %#lx, original fn rva %#lx)", HOOK_FUNCTION,
	           (unsigned long)((uint8_t *)entry - (uint8_t *)bf2),
	           (unsigned long)((uint8_t *)(uintptr_t)g_orig_hooked - (uint8_t *)bf2));
	return 1;
}
