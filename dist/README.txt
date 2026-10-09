ONLINE GALACTIC CONQUEST
for Star Wars Battlefront II in the Battlefront Classic Collection (Steam)

Two players play one Galactic Conquest campaign over the internet, each
commanding one faction. Battles are played together online.

INSTALL (both players)
  Windows: run OnlineGalacticConquest-Setup.exe and choose Install. Setup
           finds the game through Steam; if it does not, choose Browse and
           pick the game folder (in Steam: right-click the game > Manage >
           Browse local files). Run Setup again to update or uninstall.
           If Windows SmartScreen says it protected your PC, choose
           More info > Run anyway (Setup is not code-signed).
           Without Setup: run install.bat from the zip. If the game is not
           in the default Steam folder, drag the game folder onto it.
  Linux:   ./install.sh /path/to/steamapps/common/Battle (from the zip)
  To remove: Setup > Uninstall, uninstall.bat or ./install.sh --uninstall.
  Steam's "Verify integrity of game files" also turns the mod off.

PLAY
  Start Battlefront II, then Multiplayer > Galactic Conquest.

  Host Lobby: choose the scenario (Clone Wars or Galactic Civil War), then
        your side. The lobby shows your local address at the bottom right.
        Over the internet, give your friend your public IP address (search
        "what is my ip"). When they appear in the lobby, choose Launch.
  Join Lobby: type the host's IP address and press Enter or OK. You join on
        the side the host left free.

  The Republic or Rebels move first. On your turn, play as usual. On the
  other player's turn you watch the galaxy until they finish. In a battle
  the defender picks the battle type, each side picks its own bonus card,
  and then both players load into the battle together.
  The host's game decides every battle. If the host quits a battle before
  it is decided, the other player wins it. If the joining player quits a
  battle, the host plays on and the result still counts.

PORTS (host only)
  The host must forward these ports on their router to their PC:
    TCP 24600   mod connection (galaxy map, turns)
    UDP 3658    battles
  The joining player does not need to forward anything.
  Alternatively, both players can join a virtual LAN (ZeroTier, Tailscale,
  Radmin VPN) and use the host's address on that network instead.
  When the other player joins, the lobby checks that they can reach UDP
  3658 and says so in both lobbies if they cannot: battles will not start
  until that port is forwarded.
  If a battle cannot be joined anyway, the joining player can try again, or
  let the host play that battle alone; the campaign goes on with its result.

NOTES
  - Both players need the same version of this mod; the host turns away
    other versions.
  - If the connection drops, the campaign ends for both players. The host
    can save from the pause menu, but a saved campaign cannot be resumed
    online yet.
  - A log is written to conquest.log in the game folder; include it when
    reporting a problem.
