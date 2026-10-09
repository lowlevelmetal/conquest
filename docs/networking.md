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
* `MissionVictory` and `MissionDefeat` are registered after `setup_teams`
  loads; wrap them from `ScriptPostLoad`. Battles end three ways: a side
  wins (`MissionVictory(team)`), a time limit ends in a tie
  (`MissionVictory({1,2})`), or a side runs out of reinforcements
  (`MissionDefeat(team)`, the usual end of a conquest battle).
  `ScriptCB_QuitToShell()` right after the end returns to the shell without
  map rotation, and `ScriptCB_GetLastBattleVictory()` then reports the
  winner on the host. The client never runs the battle's logic, so the host
  sends that value from the shell (`result {winner}`) and the client uses it
  as is; the in-battle `end` message only tells the client to leave. A
  battle the host leaves undecided reads -1 ("not fought"), after which
  the stock galaxy starts it over at once on each machine, out of step;
  online the mod reports it as won by the client instead (forfeit).
* A battle's end leaves engine network errors behind on the client ("The
  session has ended because the host has left"). Every shell screen opens
  the engine's error box from `ScriptCB_GetLatestError()`
  (`gIFShellScreenTemplate_CommonUpdate`), and while it is open the screen
  under it gets no `Update`. During an online campaign the mod clears them
  (`ScriptCB_ClearError`) except on the battle launch and join screens.
* Side select, the spawn map and the unit screen confirm on a held accept
  key (about 0.125 s): the engine then reads the screen's `CurButton` (a
  team, or `_ok` for Spawn). Keys come from `SDL_GetKeyboardState`, not key
  events; test copies press keys through `native/testwin.c`.

## Lobby protocol (mod link)

The Galactic Conquest lobby runs over the mod's TCP link before any engine
session exists. The joining player sends `hello {protocol, version, name}`;
the host answers `setup {scenario, hostTeam, name, udp}` or `refuse {reason}`
(`version` for another protocol or mod version, `full`), so the joiner takes
the side the host left free. `ping`/`pong {t}` fill the lobby's Ping column,
`udp {ok}` reports the battle-port check, `start` launches the campaign on
both machines and `bye` leaves the lobby.

Messages are Lua table constructors (`CGC.Serialize`) but are parsed as data
only (`CGC.Deserialize` never runs them), and each kind's fields are checked
before a screen sees it (`link.lua`). The native link caps a message at
1 MiB and the queue at 1024 messages.

The host's port stays open for the whole lobby (`net.c`). A new connection
waits as pending until it sends its first message; only then does it become
the player, so connections that stay silent cannot take the slot. One that
arrives while a player is connected is refused as `full`. Lua drops a player
whose first message is not `hello` and takes the next with
`ConquestNet_AcceptNext()`. Closing a connection still sends what was queued
for it, so `bye`, `quit` and `refuse` arrive.

While the lobby is open the host answers a small UDP probe on 3658 (`udp.c`)
and the joining player sends a few: no answer means battles will not
connect, which both lobbies show before the campaign starts.

## Shell UI notes

* Localized strings worth reusing (all present in the shipped localization):
  `ifs.mplobby.host_title` "Host Lobby", `ifs.mplobby.client_title`,
  `ifs.MPLobby.name_header` / `team_header` / `ping_header`,
  `common.mp.joinip_prompt` "IP :", `common.mp.joining`, `common.mp.launch`,
  `common.launching` "Prepare for Battle...", `common.waitforhost`
  "Contacting host ...", `ifs.meta.Configs.title` "Select Scenario",
  `ifs.freeform.picksides`, `common.sides.<rep|cis|all|imp>.name`,
  `ifs.onlinelobby.cancelsession` / `leavesession` / `wrongver`, and the join
  errors `ifs.mp.joinerrors.<noconnect|full|hostquit|connectlost|version>`
  (key names found as strings in `Battlefront2.dll`).
* The PC Join IP box is an `NewEditbox` that takes keys only while it is
  `gCurEditbox`; the screen's `Input_KeyDown(this, key)` feeds
  `IFEditbox_fnAddChar` (8 = backspace, 10 = Enter). Set `bKeepsFocus` so
  mouse movement does not steal focus.
* An `IFImage` with a `tag` is a mouse target: hovering sets `CurButton` to
  the tag and calls the screen's `UpdateUI`. The mouse code clears
  `CurButton` when the pointer is over nothing.
* `Popup_Busy` polls `fnCheckDone` every frame (-1 fail, 0 busy, 1 done) and
  calls `fnOnFail` itself after `fTimeout`; the success/fail callbacks must
  close the popup.
* The shell's Back button is a 150-wide `NewPCIFButton` centred 75 in from
  the bottom-left corner. Stock right-corner buttons placed with
  `gIFShellScreenTemplate_fnMoveClickableButton` end up partly off screen at
  16:9.
* The SDL event loop (`FUN_1802dda20`, rva 0x2dda20) handles window events
  7, 11 and 13 (minimized, mouse left, focus lost) with one deactivation
  path and 8, 9, 10 and 12 with the matching reactivation.
* Under GNOME Wayland, asking the window manager to activate another game
  window (`_NET_ACTIVE_WINDOW`) left that copy stalled at 0% CPU, and a
  covered XWayland window reads back black, so local test copies run
  windowed side by side instead (`CONQUEST_WINDOW`, `native/testwin.c`).
