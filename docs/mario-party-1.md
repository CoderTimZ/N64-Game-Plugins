# Mario Party 1

Options in `MarioParty.json`, for the US version of Mario Party. The [configuration page](configuration.md) explains how
the file works and describes the options every Mario Party plugin has: `characters`, `saveStateBeforeEachPlayerTurn`,
`bingoURL` and `rankPlayersByBingoScore`.

| Option | Type | Default |
|--------|------|---------|
| [`blockWeights`](#blockweights) | object | 1 for each special block, 27 for the normal one |
| [`teams`](#teams) | object | Mario and Luigi against everyone else |
| [`teamScores`](#teamscores) | `true`/`false` | `false` |
| [`teamMiniGames`](#teamminigames) | `true`/`false` | `false` |
| [`teamControl`](#teamcontrol) | `true`/`false` | `false` |
| [`randomBonus`](#randombonus) | `true`/`false` | `false` |
| [`bonuses`](#bonuses) | object | all nine bonus stars |
| [`standardSpaceRatio`](#standardspaceratio) | object | `{}` (off) |
| [`preventRepeatMiniGames`](#preventrepeatminigames) | `true`/`false` | `false` |
| [`blockedMiniGames`](#blockedminigames) | list | `[]` |
| [`mapScrollSpeedMultiplier`](#mapscrollspeedmultiplier) | number | `1` |

## Dice blocks

### `blockWeights`

How often each kind of dice block is used when a player rolls.

- Type: an object of block names and weights
- Default: `{ "PLUS": 1, "MINUS": 1, "SPEED": 1, "SLOW": 1, "WARP": 1, "NORMAL": 27 }`

A block's chance is its weight divided by the total of all the weights. The default makes each special block a 1 in 32
chance and the normal block 27 in 32. A block left out, or with weight 0, is never used, so `{ "NORMAL": 1 }` means only
the normal dice block. Give at least one block a weight above 0.

Block names: `NORMAL` (the regular dice block), `PLUS`, `MINUS`, `SPEED`, `SLOW`, `WARP`.

## Teams

### `teams`

Which characters play together, for the other team options.

- Type: an object of character names and team numbers
- Default: `{ "MARIO": 2, "LUIGI": 2, "PEACH": 1, "YOSHI": 1, "WARIO": 1, "DK": 1 }`

Players whose characters have the same number are teammates; the numbers themselves don't matter. Teams go by
character, not by player number. A character left out is on team 0, with every other character left out.

With the default, a game with both Mario and Luigi is Mario and Luigi against the other two. With only one of them, that
player is alone against the other three.

Teams only matter to `teamScores`, `teamMiniGames` and `teamControl`.

### `teamScores`

Teammates share their coins and stars.

- Type: `true` or `false`
- Default: `false`

Whenever a player gains or loses coins or stars, their teammates get the same total, so each team has one shared
wallet. This covers the board, board events, Chance Time, Bowser, Boo, mini-game results and the bonus stars:

- **Chance Time** between teammates changes nothing. Between players of different teams, both teams' players get the
  result.
- **Boo** can't steal from the player's teammates: they're greyed out under "From whom?". A computer player steals
  from an opponent instead.
- **Bowser's** event that sets everyone's coins to the average works as usual (the change isn't counted twice).
- **Bonus stars:** each player gets their whole team's bonus stars, so teammates finish with the same number of stars.
- **Bingo corrections** to a player's coins or stars apply to their teammates too.

The "Coin Star" record (most coins held at once) is shared too. The other bonus star records, such as mini-game coins
and the spaces each player has landed on, stay per player.

### `teamMiniGames`

Makes the 2 vs 2 mini-games team against team.

- Type: `true` or `false`
- Default: `false`

When the panel colors at the end of a round would make a 2 vs 2 mini-game that splits a team up, the panels are
recolored so each team plays together. 4-player and 1 vs 3 mini-games are left alone. If every player is on one team, a
1 vs 3 or 2 vs 2 becomes a 4-player mini-game. Players without a teammate are never changed.

### `teamControl`

Lets a human play their computer teammates' turns with their own controller.

- Type: `true` or `false`
- Default: `false`

A computer player becomes human-controlled when a teammate is human and on a lower-numbered controller, and that
teammate's controller plays their turns. So in a game of one human and one computer per team, each human plays for
both of their team's characters.

## Bonus stars

### `randomBonus`

Replaces the end-of-game bonus stars (the Game, Coin and Happening Stars) with 3 chosen at random.

- Type: `true` or `false`
- Default: `false`

The stars are picked from `bonuses` when the bonus stars are given out, from the ones at least one player has done
anything towards (if fewer than 3 qualify, from all of them). The announcements name each star and what it was for, and
ties work as usual. If `bonuses` has fewer than 3 stars, the game's own bonus stars are used.

### `bonuses`

The bonus stars `randomBonus` can pick, and their names.

- Type: an object of bonus star types and names
- Default:

  ```json
  {
      "MINI_GAME": "Game", "COIN": "Coin", "HAPPENING": "Happening", "RED": "Unlucky", "BLUE": "Blue",
      "MINI_GAME_SPACE": "Game Space", "CHANCE": "Chance", "MUSHROOM": "Mushroom", "BOWSER": "Bowser"
  }
  ```

Remove a type to stop it being picked. The name is shown in the game as "the *name* Star", so keep it short (the
message windows are small). Letters the game's font doesn't have are shown as `?`.

| Type | Awarded to the player who |
|------|---------------------------|
| `MINI_GAME` | collected the most coins in mini-games |
| `COIN` | held the most coins at one time |
| `HAPPENING` | landed on the most ? Spaces |
| `RED` | landed on the most Red Spaces |
| `BLUE` | landed on the most Blue Spaces |
| `MINI_GAME_SPACE` | landed on the most Mini-Game Spaces |
| `CHANCE` | landed on the most ! Spaces |
| `MUSHROOM` | landed on the most Mushroom Spaces |
| `BOWSER` | landed on the most Bowser Spaces |

## Spaces

### `standardSpaceRatio`

Turns some of a board's Blue Spaces into other kinds of space.

- Type: an object of space types and fractions (0 to 1)
- Default: `{}` (off)

Each fraction is how much of the board should be that type, counting every space a player can land on, including the
board's own spaces of that type. For example, `{ "RED": 0.15 }` on a board with 100 such spaces makes 15 of them Red
Spaces: if the board already has 6, 9 Blue Spaces become Red Spaces. Only Blue Spaces are changed, and only up to the
fraction (a board that already has more of a type keeps them). Star Spaces are never changed.

The spaces are chosen when a game starts on a board and stay for the whole game, through save states. A new game picks
new ones.

Changed spaces work like the board's own: landing on one counts towards that type's bonus star and colors the player's
panel. A changed ! Space starts Chance Time. A changed ? Space counts as a ? Space but has no board happening, since each
board's happenings belong to particular spaces.

Space types: `RED`, `MINI_GAME`, `HAPPENING` (? Space), `CHANCE` (! Space), `MUSHROOM`, `BOWSER`.

## Mini-games

### `preventRepeatMiniGames`

Plays every mini-game of a kind before any of them is played again.

- Type: `true` or `false`
- Default: `false`

Each kind of mini-game (4-player, 1 vs 3, 2 vs 2, and the 1-player games of Mini-Game Spaces) goes through all of its
mini-games in a random order before starting again. A mini-game played recently doesn't come up again soon after the
order starts again either. The roulette still shows several mini-games, but always stops on the next one.

The plugin chooses the mini-game itself, so the game's own rules for it are skipped. Among them is the one that avoids
mini-games needing more coins than players have.

### `blockedMiniGames`

Mini-games that are never played.

- Type: a list of mini-game names
- Default: `[]`

A blocked mini-game can still appear on the roulette, but it never stops on it. If every mini-game of a kind is
blocked, all of that kind are played. Blocking any mini-game also turns on `preventRepeatMiniGames`.

| Kind | Mini-games |
|------|------------|
| 4-player | `BURIED_TREASURE`, `TREASURE_DIVERS`, `HOT_BOB_OMB`, `MUSICAL_MUSHROOM`, `CRAZY_CUTTER`, `FACE_LIFT`, `BALLOON_BURST`, `COIN_BLOCK_BLITZ`, `SKATEBOARD_SCAMPER`, `BOX_MOUNTAIN_MAYHEM`, `PLATFORM_PERIL`, `MUSHROOM_MIX_UP`, `GRAB_BAG`, `BUMPER_BALLS`, `TIPSY_TOURNEY`, `BOMBS_AWAY`, `SLOT_CAR_DERBY`, `MARIO_BANDSTAND`, `SHY_GUY_SAYS`, `CAST_AWAYS`, `KEY_PA_WAY`, `RUNNING_OF_THE_BULB`, `HOT_ROPE_JUMP`, `HAMMER_DROP` |
| 1 vs 3 | `PIPE_MAZE`, `BASH_N_CASH`, `BOWL_OVER`, `COIN_BLOCK_BASH`, `TIGHTROPE_TREACHERY`, `CRANE_GAME`, `PIRANHAS_PURSUIT`, `TUG_O_WAR`, `PADDLE_BATTLE`, `COIN_SHOWER_FLOWER` |
| 2 vs 2 | `BOBSLED_RUN`, `DESERT_DASH`, `BOMBSKETBALL`, `HANDCAR_HAVOC`, `DEEP_SEA_DIVERS` |
| 1-player (Mini-Game Spaces) | `MEMORY_MATCH`, `SLOT_MACHINE`, `SHELL_GAME`, `GHOST_GUESS`, `PEDAL_POWER`, `WHACK_A_PLANT`, `GROUND_POUND`, `TEETERING_TOWERS`, `KNOCK_BLOCK_TOWER`, `LIMBO_DANCE` |

## Board

### `mapScrollSpeedMultiplier`

How fast the board map scrolls, as a multiple of its normal speed.

- Type: a number
- Default: `1`

The map is the view opened with B at the dice block or at a junction. `2` scrolls twice as fast.
