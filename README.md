# N64 Game Plugins

Emulator plugins that add options and fixes to Mario Party 1, 2 and 3 and Mario Golf 64, and connect Mario Party games to
the [Mario Party Bingo](https://mp.bingo/) website.

The plugins are execution plugins for [CoderTimZ's fork of RMG](https://github.com/CoderTimZ/RMG) (Rosalie's Mupen GUI),
which can load a plugin that watches and changes the game as it runs. They don't work with other emulators.

| Game | Plugin | Config file |
|------|--------|-------------|
| Mario Party (US) | `MarioParty1` | `MarioParty.json` |
| Mario Party 2 (US) | `MarioParty2` | `MarioParty2.json` |
| Mario Party 3 (US) | `MarioParty3` | `MarioParty3.json` |
| Mario Golf (US) | `MarioGolf64` | `MarioGolf64.json` |

The plugins work with the US versions of the games: they rely on where things are in those versions' memory.

## What they do

By default, the options are off, so a plugin with an empty config file plays the game as normal. Some of what they can
do:

- **Teams:** play 2 vs 2, with teammates sharing coins and stars, team mini-games, and a human controlling their
  computer teammate too.
- **Bingo:** send each player's coins, stars and items to a game on [mp.bingo](https://mp.bingo/), rank the final
  results by bingo score, and (in Mario Party 3) have the roulettes pick Mario Party Superstars mini-games.
- **Spaces, bonus stars and mini-games:** turn blue spaces into other kinds, add Lucky Spaces (Mario Party 2 and 3),
  pick random bonus stars, and keep the mini-game roulette from repeating mini-games or choosing ones you've blocked.
- **Board:** faster map scrolling, duels on any turn, and a double roll for the player in last place.

The [configuration documentation](docs/configuration.md) describes every option.

## Installing

1. Build the plugins (see [Building](#building)).
2. Copy `MarioParty1.dll`, `MarioParty2.dll`, `MarioParty3.dll` and `MarioGolf64.dll` (`libMarioParty1.so` and so on,
   on Linux) into RMG's `Plugin/Execution` folder. They use the OpenSSL libraries RMG already comes with
   (`libssl-3-x64.dll` and `libcrypto-3-x64.dll`, next to `RMG.exe`), or on Linux, the system's.
3. In RMG, open each game's settings and choose its plugin as the game's execution plugin.
4. Run the game once: the plugin writes its config file (see the table above) with every option at its default, in
   the folder RMG runs in (normally RMG's own folder). Edit it, then restart the game for the changes to take effect.

The plugins follow the game's code as it runs, and work with any of RMG's CPU emulators: the dynamic recompiler, the
cached interpreter and the pure interpreter. In a build of RMG whose dynamic recompiler can't call the plugin (one for
a CPU other than x86-64), RMG uses the cached interpreter for a game with an execution plugin instead. This needs an RMG
from November 2026 or later: older ones can't run these plugins.

The plugins also work in RMG's netplay, including its Rollback mode. Every player plays with the host's settings (a
guest's own config file isn't read), and only one player's plugin talks to the bingo site, for everyone.

## Configuring

The config files are JSON. Options you leave out keep their defaults, so a config only needs what you change. For
example, a Mario Party 2 game of two teams, sending scores to a bingo game:

```json
{
    "bingoURL": "https://mp.bingo/ABC123",
    "teamScores": true,
    "teamMiniGames": true,
    "teams": { "MARIO": 1, "LUIGI": 1, "PEACH": 2, "YOSHI": 2 }
}
```

See:

- [Configuration](docs/configuration.md): how the config files work, and the options every Mario Party plugin has
- [Mario Party 1](docs/mario-party-1.md), [Mario Party 2](docs/mario-party-2.md), [Mario Party 3](docs/mario-party-3.md)
  and [Mario Golf 64](docs/mario-golf-64.md): each game's options

## Building

The plugins are written in [D](https://dlang.org/) and built with dub. You need a D compiler with a recent dub: the
official ones from [dlang.org](https://dlang.org/download.html) work (some Linux distributions ship a dub that's too old,
such as Debian 12's). On Linux you also need a C compiler and OpenSSL's development files (`libssl-dev`).

```sh
./build.sh                    # Linux, macOS, or Git Bash on Windows
```

```powershell
.\build.ps1                   # PowerShell
```

```bat
build.cmd                     :: cmd or a .bat file
```

Each builds every plugin into `bin/`. To build only some, name them (`mp1`, `mp2`, `mp3`, `mg64`); to copy the built
plugins into RMG as well, give its plugin folder:

```sh
./build.sh mp2 mp3 --install ~/RMG/Plugin/Execution
```

```powershell
.\build.ps1 mp2 mp3 -InstallDir C:\RMG\Plugin\Execution
```

`./build.sh --help` and `Get-Help .\build.ps1 -Full` list every option, including debug builds.

## Tests

`test/` has tests that play Mario Party 1, 2 and 3 in a copy of RMG, checking the plugins' features in the running game.
`test/run-tests.ps1` builds a test version of a plugin and runs them (Windows only):

```powershell
.\test\run-tests.ps1 -Game mp2 -Tests teamDuels
```

The tests need a portable copy of RMG (with `portable.txt`) set up for testing, and the US ROMs: give their locations
with `-Rmg` and `-Rom`, since the defaults are the author's own folders. The comments at the top of
`test/run-tests.ps1`, `test/driver.d` and each game's test file explain how they work.

## License

[MIT](LICENSE)
