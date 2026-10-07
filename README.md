# conquest

Galactic Conquest multiplayer mod for *STAR WARS Battlefront II* in the
*Battlefront Classic Collection* (Steam app 2446550).

## Tooling

The Classic Collection's shell (`data2/_lvl_common/shell.lvl`) holds the
Galactic Conquest UI as Lua 5.0 bytecode inside `ucfb` containers. The
game's Lua build differs from stock Lua 5.0 in three ways: 32-bit `size_t`,
`float` numbers, and `MAXSTACK = 128`, so RK constant operands start at 128
rather than 250. Bytecode from a stock compiler reads the wrong constants
in-game.

| Tool | Purpose |
| --- | --- |
| `tools/build_luac.sh` | Fetches Lua 5.0.3 and builds a `luac` that emits game-compatible bytecode (verified byte-identical code against 40 unchanged stock scripts). |
| `tools/ucfb.py` | Lists and extracts `scr_` chunks from `.lvl` / `.script` files. |
| `tools/lua50chunk.py` | Parses Lua 5.0 binary chunks. |
| `tools/decompile.py` | Rewrites RK operands to stock encoding and decompiles with [unluac](https://sourceforge.net/projects/unluac/) (place `unluac.jar` in `tools/`). |

Extracted game scripts and third-party reference sources are gitignored and
must not be committed.
