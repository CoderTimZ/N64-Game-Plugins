# Mario Party 2

Options in `MarioParty2.json`, for the US version of Mario Party 2. The [configuration page](configuration.md) explains
how the file works and describes the options every Mario Party plugin has: `characters`,
`saveStateBeforeEachPlayerTurn`, `bingoURL` and `rankPlayersByBingoScore`.

| Option | Type | Default |
|--------|------|---------|
| [`teams`](#teams) | object | Mario and Luigi against everyone else |
| [`teamScores`](#teamscores) | `true`/`false` | `false` |
| [`teamMiniGames`](#teamminigames) | `true`/`false` | `false` |
| [`teamControl`](#teamcontrol) | `true`/`false` | `false` |
| [`alwaysDuel`](#alwaysduel) | `true`/`false` | `false` |
| [`lastPlaceDoubleRoll`](#lastplacedoubleroll) | `true`/`false` | `false` |
| [`carryThreeItems`](#carrythreeitems) | `true`/`false` | `false` |
| [`cheaperAndBetterItems`](#cheaperandbetteritems) | `true`/`false` | `false` |
| [`randomItemAndDuelMiniGames`](#randomitemandduelminigames) | `true`/`false` | `false` |
| [`randomBonus`](#randombonus) | `true`/`false` | `false` |
| [`bonuses`](#bonuses) | object | all eleven bonus stars |
| [`standardSpaceRatio`](#standardspaceratio) | object | `{}` (off) |
| [`luckySpaceRatio`](#luckyspaceratio) | number | `0` (off) |
| [`luckySpaceItemChance`](#luckyspaceitemchance) | number | `0.5` |
| [`preventRepeatMiniGames`](#preventrepeatminigames) | `true`/`false` | `false` |
| [`blockedMiniGames`](#blockedminigames) | list | `[]` |
| [`mapScrollSpeedMultiplier`](#mapscrollspeedmultiplier) | number | `1` |

## Teams

### `teams`

Which characters play together, for the other team options.

- Type: an object of character names and team numbers
- Default: `{ "MARIO": 2, "LUIGI": 2, "PEACH": 1, "YOSHI": 1, "WARIO": 1, "DK": 1 }`

Players whose characters have the same number are teammates; the numbers themselves don't matter. Teams go by
character, not by player number. A character left out is on team 0, with every other character left out.

With the default, a game with both Mario and Luigi is Mario and Luigi against the other two. With only one of them, that
player is alone against the other three.

Character names: `MARIO`, `LUIGI`, `PEACH`, `YOSHI`, `WARIO`, `DK`.

### `teamScores`

Teammates share their coins and stars.

- Type: `true` or `false`
- Default: `false`

Whenever a player gains or loses coins or stars, their teammates get the same total, so each team has one shared
wallet. This covers the board, Chance Time, Bowser, duels, mini-game and Battle results, and the bonus stars. Each
team also shares the "Coin Star" record (most coins held at once); the other bonus star records stay per player.

- **Duels** can't be against a teammate. Coins wagered and won go to both teams' players.
- **Boo** can't steal from the player's teammates.
- **Bingo corrections** to a player's coins or stars apply to their teammates too.

Battle Spaces don't have special team handling yet: each teammate pays into the pot as usual.

### `teamMiniGames`

Makes the 2 vs 2 mini-games team against team.

- Type: `true` or `false`
- Default: `false`

When the panel colors at the end of a round would make a 2 vs 2 mini-game that splits a team up, the panels are
recolored so each team plays together. 4-player and 1 vs 3 mini-games are left alone. If every player is on one team, a
2 vs 2 becomes a 4-player mini-game. Players without a teammate are never changed.

### `teamControl`

Lets a human play their computer teammates' turns with their own controller.

- Type: `true` or `false`
- Default: `false`

A computer player becomes human-controlled when a teammate is human and on a lower-numbered controller, and that
teammate's controller plays their turns, menus and mini-games. So in a game of one human and one computer per team, each
human plays for both of their team's characters.

## Board

### `alwaysDuel`

Lets duels happen on any turn, not only in the last 5.

- Type: `true` or `false`
- Default: `false`

A duel still needs the usual things: landing on a space with another player, and coins to wager.

### `lastPlaceDoubleRoll`

Gives the player in last place two dice blocks to hit.

- Type: `true` or `false`
- Default: `false`

From turn 2, a player in last place (fewest stars, then fewest coins, counting ties) hits two dice blocks instead of
one. It doesn't reduce a Golden Mushroom's three. Computer players get it too.

### `mapScrollSpeedMultiplier`

How fast the board map scrolls, as a multiple of its normal speed.

- Type: a number
- Default: `1`

`2` scrolls twice as fast.

## Items

### `carryThreeItems`

Lets human players carry up to three items instead of one.

- Type: `true` or `false`
- Default: `false`

Computer players still carry one. Items from shops, Item Spaces and anywhere else are added to the player's items until
they have three. The item menu shows one item at a time: each time it's opened, it shows the next one.

- **Plunder Chest** takes a random one of the other player's items.
- **Skeleton Keys** are used at locked gates as usual, wherever they are among the player's items.
- **Bowser Bombs** count as held if they're among a player's items, and are all removed as usual.
- **Bingo:** the bingo page shows all three item slots, and bingo admins can set up to three items.

### `cheaperAndBetterItems`

Makes items cheaper, and makes every item available from the start of the game.

- Type: `true` or `false`
- Default: `false`

- Every item in the Item Shops costs 5 coins less, and players with 5 coins can shop (instead of 10).
- The Item Shops and Item Spaces offer the items they normally only have near the end of the game, from turn 1.

### `randomItemAndDuelMiniGames`

Picks the Item Space mini-games and duel mini-games from every board, instead of each board's own.

- Type: `true` or `false`
- Default: `false`

Each board normally has one item mini-game and one duel mini-game. With this, each is a random board's instead,
skipping any in `blockedMiniGames`.

## Bonus stars

### `randomBonus`

Replaces the end-of-game bonus stars (the Mini-Game, Coin and Happening Stars) with 3 chosen at random.

- Type: `true` or `false`
- Default: `false`

The stars are picked from `bonuses` when the bonus stars are given out, from the ones at least one player has done
anything towards (if fewer than 3 qualify, from all of them). The announcements name each star and what it was for, and
ties work as usual. If `bonuses` has fewer than 3 stars, the game's own bonus stars are used. It only matters in games
played with bonus stars on.

### `bonuses`

The bonus stars `randomBonus` can pick, and their names.

- Type: an object of bonus star types and names
- Default:

  ```json
  {
      "MINI_GAME": "Mini-Game", "COIN": "Coin", "HAPPENING": "Happening", "RED": "Unlucky", "BLUE": "Blue",
      "CHANCE": "Chance", "BOWSER": "Bowser", "BATTLE": "Battle", "ITEM": "Item", "BANK": "Banking", "LUCKY": "Lucky"
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
| `CHANCE` | landed on the most ! Spaces |
| `BOWSER` | landed on the most Bowser Spaces |
| `BATTLE` | landed on the most Battle Spaces |
| `ITEM` | landed on the most Item Spaces |
| `BANK` | landed on the most Bank Spaces |
| `LUCKY` | landed on the most Lucky Spaces (only with `luckySpaceRatio`) |

## Spaces

### `standardSpaceRatio`

Turns some of a board's Blue Spaces into other kinds of space.

- Type: an object of space types and fractions (0 to 1)
- Default: `{}` (off)

Each fraction is how much of the board should be that type, counting every space a player can land on, including the
board's own spaces of that type. For example, `{ "ITEM": 0.1 }` on a board with 80 such spaces makes 8 of them Item
Spaces: if the board already has 5, 3 Blue Spaces become Item Spaces. Only Blue Spaces are changed, and only up to the
fraction (a board that already has more of a type keeps them). Star Spaces are never changed.

The spaces are chosen when a game starts on a board and stay for the whole game, through save states. A new game picks
new ones.

Space types: `RED`, `HAPPENING` (? Space), `CHANCE` (! Space), `ITEM`, `BANK`, `BATTLE`, `BOWSER`. A changed ? Space
counts as a ? Space, but probably has no happening, since each board's happenings belong to particular spaces.

### `luckySpaceRatio`

Turns some of a board's Blue Spaces into Lucky Spaces.

- Type: a number from 0 to 1
- Default: `0` (off)

The number is the fraction of the board's Blue Spaces to make Lucky Spaces. Lucky Spaces look different (they have
their own picture, on the board and the map), and landing on one gives either a free item or more coins than a Blue
Space:

- **An item**, with the chance in `luckySpaceItemChance`, if the player has room for one. Which items are likely
  depends on how far into the game it is, like the Item Shops.
- **Coins** otherwise: 7, 10, 12, 15 or 20 at random, or 12, 15 or 20 in the last 5 turns (a Blue Space gives 3, or 6
  in the last 5 turns).

Landing on a Lucky Space doesn't count as a Blue Space for the Blue bonus star, and counts for the `LUCKY` bonus star
instead. At the end of the game, the emulator's log lists how many Lucky Spaces each player landed on.

Lucky Spaces are chosen with `standardSpaceRatio`'s spaces, from the Blue Spaces it leaves, and stay for the whole game
in the same way.

### `luckySpaceItemChance`

The chance that a Lucky Space gives an item instead of coins.

- Type: a number from 0 to 1
- Default: `0.5`

`0` always gives coins, `1` always gives an item (when the player has room for one). It only matters with
`luckySpaceRatio`.

## Mini-games

### `preventRepeatMiniGames`

Plays every mini-game of a kind before any of them is played again.

- Type: `true` or `false`
- Default: `false`

Each kind of mini-game chosen by a roulette (4-player, 1 vs 3, 2 vs 2, and Battle) goes through all of its mini-games
in a random order before starting again. A mini-game played recently doesn't come up again soon after the order starts
again either. The roulette still shows several mini-games, but always stops on the next one.

### `blockedMiniGames`

Mini-games that are never played.

- Type: a list of mini-game names
- Default: `[]`

A blocked mini-game can still appear on the roulette, but it never stops on it. If every mini-game of a kind is
blocked, all of that kind are played. Blocking any mini-game also turns on `preventRepeatMiniGames`. Blocking duel and
item mini-games only matters with `randomItemAndDuelMiniGames`: otherwise each board plays its own.

| Kind | Mini-games |
|------|------------|
| 4-player | `LAVA_TILE_ISLE`, `HOT_ROPE_JUMP`, `SHELL_SHOCKED`, `TOAD_IN_THE_BOX`, `MECHA_MARATHON`, `ROLL_CALL`, `ABANDON_SHIP`, `PLATFORM_PERIL`, `TOTEM_POLE_POUND`, `BUMPER_BALLS`, `BOMBS_AWAY`, `TIPSY_TOURNEY`, `HONEYCOMB_HAVOC`, `HEXAGON_HEAT`, `SKATEBOARD_SCAMPER`, `SLOT_CAR_DERBY`, `SHY_GUY_SAYS`, `SNEAK_N_SNORE`, `DIZZY_DANCING`, `TILE_DRIVER`, `DEEP_SEA_SALVAGE` |
| 1 vs 3 | `BOWL_OVER`, `RAINBOW_RUN`, `CRANE_GAME`, `MOVE_TO_THE_MUSIC`, `BOB_OMB_BARRAGE`, `LOOK_AWAY`, `SHOCK_DROP_OR_ROLL`, `LIGHTS_OUT`, `FILET_RELAY`, `ARCHER_IVAL`, `QUICKSAND_CACHE` |
| 2 vs 2 | `TOAD_BANDSTAND`, `BOBSLED_RUN`, `HANDCAR_HAVOC`, `BALLOON_BURST`, `SKY_PILOTS`, `SPEED_HOCKEY`, `CAKE_FACTORY`, `DUNGEON_DASH`, `MAGNET_CARTA`, `LOONEY_LUMBERJACKS`, `TORPEDO_TARGETS`, `DESTRUCTION_DUET` |
| Battle | `GRAB_BAG`, `BUMPER_BALLOON_CARS`, `RAKE_EM_IN`, `DAY_AT_THE_RACES`, `HOT_BOB_OMB`, `FACE_LIFT`, `CRAZY_CUTTERS`, `BOWSERS_BIG_BLAST` |
| Duel | `QUICK_DRAW_CORKS`, `SABER_SLASHES`, `MUSHROOM_BREW`, `TIME_BOMB`, `PSYCHIC_SAFARI`, `ROCK_PAPER_MARIO` |
| Item | `BOWSER_SLOTS`, `ROLL_OUT_THE_BARRELS`, `COFFIN_CONGESTION`, `HAMMER_SLAMMER`, `GIVE_ME_A_BRAKE`, `MALLET_GO_ROUND` |
