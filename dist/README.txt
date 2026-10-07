ONLINE GALACTIC CONQUEST
for Star Wars Battlefront II in the Battlefront Classic Collection (Steam)

Two players play one Galactic Conquest campaign over the internet, each
commanding one faction. Battles are played together online.

INSTALL (both players)
  Windows: run install.bat. If the game is not in the default Steam folder,
           drag the game folder onto install.bat. (Steam: right-click the
           game > Manage > Browse local files shows the folder.)
  Linux:   ./install.sh /path/to/steamapps/common/Battle
  To remove: uninstall.bat / ./install.sh --uninstall, or use Steam's
  "Verify integrity of game files".

PLAY
  Start Battlefront II, then Multiplayer > Galactic Conquest.

  Host: pick an era and your side ("Host Clone Wars as the Republic", ...).
        The screen shows your local address. Give your friend your public
        IP address (search "what is my ip").
  Join: choose "Join a game by IP address" and type the host's IP.

  The Republic or Rebels move first. On your turn, play as usual. On the
  other player's turn you watch the galaxy until they finish. In a battle
  the defender picks the battle type, each side picks its own bonus card,
  and then both players load into the battle together. Pick your faction
  on the side-select screen if it is not chosen for you.

PORTS (host only)
  The host must forward these ports on their router to their PC:
    TCP 24600   mod connection (galaxy map, turns)
    UDP 3658    battles
  The joining player does not need to forward anything.
  Alternatively, both players can join a virtual LAN (ZeroTier, Tailscale,
  Radmin VPN) and use the host's address on that network instead.

NOTES
  - Both players need the same version of this mod.
  - If the connection drops, the campaign ends for both players. The host
    can save from the pause menu.
  - A log is written to conquest.log in the game folder; include it when
    reporting a problem.
