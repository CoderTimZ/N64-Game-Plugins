# Configuration

Each plugin reads a JSON config file when a game starts. This page explains how the files work and describes the options
every Mario Party plugin shares. Each game's own options are on its page:

- [Mario Party 1](mario-party-1.md)
- [Mario Party 2](mario-party-2.md)
- [Mario Party 3](mario-party-3.md)
- [Mario Golf 64](mario-golf-64.md)

## The config files

| Game | File |
|------|------|
| Mario Party | `MarioParty.json` |
| Mario Party 2 | `MarioParty2.json` |
| Mario Party 3 | `MarioParty3.json` |
| Mario Golf | `MarioGolf64.json` |

The file is named after the name inside the game's ROM, and lives in the folder RMG runs in (normally RMG's own
folder).

- **First run:** if the file doesn't exist, the plugin writes it with every option at its default.
- **Read once:** the file is read when the game starts. To change an option, edit the file and start the game again.
- **Rewritten:** after reading the file, the plugin writes it back with every option, in alphabetical order. Options you
  left out appear with their defaults, and anything it doesn't recognise is removed without an error, so a misspelled
  option just disappears: check the file after starting the game.
- **Errors:** if the file isn't valid (a JSON syntax error, a value of the wrong kind for its option, or a name that
  isn't one of an option's values), the plugin reports what's wrong (in a message box on Windows, and in the emulator's
  log), plays with every option at its default, and leaves your file as it is so you can fix it. Numbers and
  `true`/`false` are interchangeable: `1` is `true`, and `true` is `1`.

### Names

Options that take characters, mini-games, spaces, items and so on use the names listed on each game's page, in capitals
with underscores, such as `"MARIO"` or `"BUMPER_BALLS"`. Names are case-sensitive.

### Options that are objects

Some options are objects whose keys are names, such as `teams` or `bonuses`. Giving one replaces the whole default
object: anything you leave out of it is gone, not kept at its default. For example, giving `bonuses` with three entries
means random bonus stars only choose from those three.

### Example

Options you leave out keep their defaults, so a config only needs what you change. For example, a Mario Party 1 config
that never plays Tipsy Tourney, and picks the bonus stars at random from three:

```json
{
    "blockedMiniGames": ["TIPSY_TOURNEY"],
    "randomBonus": true,
    "bonuses": { "MINI_GAME": "Game", "COIN": "Coin", "RED": "Unlucky" }
}
```

## The plugin's saved state

Some options need the plugin to remember things during a game, like which spaces it changed or which mini-games have
been played. The plugin keeps this in the game's own memory, so it's saved and loaded with the emulator's save states
(and netplay's rollback). It isn't kept anywhere else: a game continued from the game's own save file, rather than a save
state, starts with nothing remembered (for example, the changed spaces are picked again).

## Options for every Mario Party game

These work in Mario Party 1, 2 and 3.

### `characters`

The character each player plays as, overriding what's chosen in the game.

- Type: a list of up to 4 character names, for players 1 to 4 (players left off the end are left to the game)
- Default: `["UNDEFINED", "UNDEFINED", "UNDEFINED", "UNDEFINED"]`

`UNDEFINED` leaves a player's character to the game. Any other name makes that player always be that character: the
game can't change it, and neither can a bingo admin. Two players can be the same character; Chance Time still picks two
different players when they are.

Character names: `MARIO`, `LUIGI`, `PEACH`, `YOSHI`, `WARIO`, `DK`, and in Mario Party 3 also `WALUIGI` and `DAISY`.

### `saveStateBeforeEachPlayerTurn`

Makes an emulator save state at the start of every player's turn.

- Type: `true` or `false`
- Default: `false`

Player 1's turns are saved in save state slot 1, player 2's in slot 2, and so on, so each slot holds the start of that
player's latest turn. They're overwritten every round, so don't keep your own save states in slots 1 to 4. The
emulator's selected slot changes with each turn too, so a save state you make yourself goes in the current player's
slot unless you choose another.

The option does nothing during netplay: the emulator doesn't make save states then, so the plugin neither saves nor
changes the selected slot.

### `bingoURL`

The address of a game on [Mario Party Bingo](https://mp.bingo/) to connect to.

- Type: text
- Default: `""` (not connected)

While connected, the plugin sends each player's character, coins, stars, items and panel color (blue or red, for the
mini-game teams), whether they're a computer, and the current turn, so the bingo page can show them. If it can't
connect, or the connection drops, it tries again every 5 seconds. It also receives the bingo cards, which some options
use (such as `rankPlayersByBingoScore`), and corrections from the bingo game's admins, who can set a player's character,
coins, stars and items.

### `rankPlayersByBingoScore`

Ranks the players in the final results by their bingo cards instead of by stars and coins.

- Type: `true` or `false`
- Default: `false`
- Needs: `bingoURL`

Players are ranked by most bingos, then most squares, then most stars, then most coins. A player's card is the one for
their character. Without the cards (if the plugin isn't connected), every player has 0 bingos and 0 squares, so the
ranking is by stars and coins as usual.

## Options several games share

These appear on more than one game's page, and work the same way in each game that has them. Their pages give the
details for that game, such as its names and its own differences.

- **Teams:** `teams`, `teamScores`, `teamMiniGames`, `teamControl`
- **Bonus stars:** `randomBonus`, `bonuses`
- **Spaces:** `standardSpaceRatio`, and in Mario Party 2 and 3, `luckySpaceRatio` and `luckySpaceItemChance`
- **Mini-games:** `preventRepeatMiniGames`, `blockedMiniGames`
- **Board:** `mapScrollSpeedMultiplier`, and in Mario Party 2 and 3, `alwaysDuel` and `lastPlaceDoubleRoll`
