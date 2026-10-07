# Battlefront II (Classic Collection) networking internals

Notes from reverse engineering `Battlefront2.dll` and `Battlefront.exe`
(Steam build 14742199). RVAs refer to that build. Use `tools/re/dec.py`
against the Ghidra decompilation to find them again.

## Two transports behind one switch

The launcher (`Battlefront.exe`) contains Aspyr's **RedNet** layer
(`RedNet`, `RedNetInstance`, `RedNetClient`, `RedNetPhotonListener`,
`DefaultSessionManager`), built on Exit Games' **Photon** LoadBalancing SDK
with STUN-based peer-to-peer connections. `Battlefront.exe` passes a RedNet
interface to `GameWinMain`, which stores it in `DAT_180f83af0`
(`FUN_180408d00` returns it).

`Battlefront2.dll` still contains the original Pandemic UDP transport. One
byte chooses between them:

| | |
| --- | --- |
| `DAT_18064b14c` | "use RedNet" flag, default 1 |
| `FUN_180408d10` (rva 408d10) | reads it; checked by ~36 network functions |
| `FUN_180408d20` (rva 408d20) | sets it (0 also calls RedNet vtable +0x20) |
| `ScriptCB_SetConnectType` (rva 236290) | clears it only for `"lan"`, sets it for anything else (including `"direct"`) |

With the flag cleared the engine binds its own sockets:

| Port | Purpose | Code |
| --- | --- | --- |
| UDP 3658 | game socket when hosting | `FUN_18040caf0(1)` |
| UDP 3659 | game socket when joining | `FUN_18040caf0(0)` |
| UDP 3656 | LAN discovery: broadcast sender connected to 255.255.255.255, plus a listener | `FUN_18040c990` |

Ports live at `DAT_18064b190/194/198`. Packets are sent by `FUN_18040cfe0`
(`sendto` on the game socket, or `send` on the broadcast socket for peer slot
`0x4a`) and received by `FUN_18040cc20`, which dispatches through
`FUN_1803d01b0`.

## Addresses

Engine addresses are 24-byte structs: a 16-byte peer header (a RedNet ID; in
LAN mode a copy of `DAT_180f83af8`) followed by `sockaddr_in` fields: family
at +0x10, port at +0x12, IPv4 at +0x14. `FUN_18040c6e0` extracts IP and port.
Peer slots: `FUN_1803cf9d0(i)` returns `&DAT_180e76680 + i*0x88` for `i < 0x49`;
slot `0x4a` is the discovery broadcast.

## Session discovery (LAN mode)

* `FUN_18040bff0` periodically builds a query (random 32-bit ID
  `DAT_180f83b1c`, 12-bit version `FUN_1803ea970()`, 3 bits) and sends it to
  slot `0x4a`, i.e. broadcast to :3656.
* Packet types 0/1 go to `FUN_180440ee0`. A host checks the version and
  **broadcasts** a reply containing the query ID, game name, map, mode string,
  its game port (`DAT_180e76624`) and player counts.
* A client (`FUN_180440c10`) matches the query ID and adds or updates a session
  entry. Because `DAT_1806481e0` is always 1, the entry's address is
  **the reply sender's IP plus the advertised game port**.

## Joining

* `ScriptCB_BeginJoinIP` (rva 239c00) creates a type-2 session query
  (`FUN_1803ea380` -> `FUN_180409660`) but never parses the IP: the address
  argument is NULL. In LAN mode it falls back to broadcast discovery.
* `ScriptCB_IsQuickmatchDone` (rva 239ea0) returns 1 once the query has a
  session (`FUN_18040a1b0`).
* `ScriptCB_LaunchQuickmatch` (rva 239db0) creates `CNetJoinGame`
  (`FUN_180290aa0`), which copies the chosen session's address (entry +0x24)
  and connects to it over the game socket.

## What the mod adds

`native/shim.c` hooks `Battlefront2.dll`'s Winsock imports (`connect`, `bind`,
`send`, `recvfrom`, `closesocket` by ordinal) and identifies the discovery
sockets from how the engine sets them up. With the tunnel on, the discovery
query and reply travel over the mod's TCP link and are injected with the
peer's real IP as sender, so the client's engine lists `<host IP>:3658` and
joins it with its normal UDP handshake. For internet play the host forwards
UDP 3658 and the mod's TCP port.

## Battles and results

* Hosting: `SetConnectType("lan")`, `SetMissionNames({{Map=...}})`,
  `SetAmHost(1)`, `SetGameName("...")` (plain string, not unicode),
  `SetGameRules("mp")`, `SetNetGameDefaults(p)`, `SetDedicated(nil)`,
  `BeginLobby()`, then `UpdateLobby(nil)` + `LaunchLobby()` per tick.
* `MissionVictory` is registered after `setup_teams` loads; wrap it from
  `ScriptPostLoad`. `ScriptCB_QuitToShell()` right after victory returns to
  the shell without map rotation, and `ScriptCB_GetLastBattleVictory()` then
  reports the winner on the host.
