# Mario Party 3

Options in `MarioParty3.json`, for the US version of Mario Party 3. The [configuration page](configuration.md) explains
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
| [`itemsOnFinalTurn`](#itemsonfinalturn) | `true`/`false` | `false` |
| [`increaseItemShopVariety`](#increaseitemshopvariety) | `true`/`false` | `false` |
| [`increaseItemGameVariety`](#increaseitemgamevariety) | `true`/`false` | `false` |
| [`toadShopChance`](#toadshopchance) | number | `-1` (the game's own) |
| [`replaceWackyWatchBeforeRemainingTurns`](#replacewackywatchbeforeremainingturns) | number | `50` |
| [`randomChanceOrder`](#randomchanceorder) | `true`/`false` | `false` |
| [`chanceSwapInsteadOfTransfer`](#chanceswapinsteadoftransfer) | `true`/`false` | `false` |
| [`chancePrizeReplace`](#chanceprizereplace) | object | `{}` |
| [`randomBonus`](#randombonus) | `true`/`false` | `false` |
| [`bonuses`](#bonuses) | object | all twelve bonus stars |
| [`improveLastFiveTurnsBonus`](#improvelastfiveturnsbonus) | `true`/`false` | `false` |
| [`standardSpaceRatio`](#standardspaceratio) | object | `{}` (off) |
| [`luckySpaceRatio`](#luckyspaceratio) | number | `0` (off) |
| [`luckySpaceItemChance`](#luckyspaceitemchance) | number | `0.333` |
| [`revealHiddenBlocksOnRemainingTurns`](#revealhiddenblocksonremainingturns) | number | `0` (off) |
| [`singleUseBattleSpaces`](#singleusebattlespaces) | `true`/`false` | `false` |
| [`preventRepeatMiniGames`](#preventrepeatminigames) | `true`/`false` | `false` |
| [`blockedMiniGames`](#blockedminigames) | list | `[]` |
| [`doubleCoinMiniGames`](#doublecoinminigames) | `true`/`false` | `false` |
| [`battleCoinDistribution`](#battlecoindistribution) | list | `[0.7, 0.3, 0, 0]` (the game's own) |
| [`balanceSuperHardCPU`](#balancesuperhardcpu) | `true`/`false` | `false` |
| [`mpiqPermadeath`](#mpiqpermadeath) | `true`/`false` | `false` |
| [`superstarsMiniGames`](#superstarsminigames) | `true`/`false` | `false` |
| [`blockedSuperstarsMiniGames`](#blockedsuperstarsminigames) | list | `[]` |
| [`bingoPlayerNames`](#bingoplayernames) | `true`/`false` | `false` |
| [`enhancedTaunts`](#enhancedtaunts) | `true`/`false` | `false` |
| [`mapScrollSpeedMultiplier`](#mapscrollspeedmultiplier) | number | `1` |
| [`autoStartNextBoard`](#autostartnextboard) | `true`/`false` | `false` |
| [`finalResultsDoNotProceed`](#finalresultsdonotproceed) | `true`/`false` | `false` |
| [`unlockEverything`](#unlockeverything) | `true`/`false` | `false` |
| [`widescreen`](#widescreen) | `true`/`false` | `false` |
| [`sharperCustomBoardMaps`](#sharpercustomboardmaps) | `true`/`false` | `false` |
| [`customCPUJunctionArrowFix`](#customcpujunctionarrowfix) | `true`/`false` | `false` |
| [`customReverseMovementFix`](#customreversemovementfix) | `true`/`false` | `false` |
| [`customExtraItemShopFix`](#customextraitemshopfix) | `true`/`false` | `false` |

The plugin also always shows the turn number ("current / total") at the top of the board.

## Teams

### `teams`

Which characters play together, for the other team options.

- Type: an object of character names and team numbers
- Default:
  `{ "MARIO": 2, "LUIGI": 2, "PEACH": 1, "YOSHI": 1, "WARIO": 1, "DK": 1, "WALUIGI": 1, "DAISY": 1 }`

Players whose characters have the same number are teammates; the numbers themselves don't matter. Teams go by
character, not by player number. Characters left out are all on one team together.

With the default, a game with both Mario and Luigi is Mario and Luigi against the other two. With only one of them, that
player is alone against the other three.

Character names: `MARIO`, `LUIGI`, `PEACH`, `YOSHI`, `WARIO`, `DK`, `WALUIGI`, `DAISY`.

### `teamScores`

Teammates share their coins and stars.

- Type: `true` or `false`
- Default: `false`

Whenever a player gains or loses coins or stars, their teammates get the same total, so each team has one shared
wallet. This covers the board, Chance Time, Bowser, the Last Five Turns event, the results of mini-games, Battles and
Game Guy mini-games, and the bonus stars. Each team also shares the "Coin Star" record (most coins held at once); the
other bonus star records stay per player.

- **Duels** can't be against a teammate.
- **Battles:** each team pays into the pot once.
- **Chance Time** between teammates changes nothing.
- **Boo** can't steal from the player's teammates.
- **Bowser's** Coin Potluck and Bowser Revolution work as usual (each change isn't counted twice).
- **Bingo corrections** to a player's coins or stars apply to their teammates too.

### `teamMiniGames`

Makes the 2 vs 2 mini-games team against team.

- Type: `true` or `false`
- Default: `false`

The panels (the colored boxes next to each player, which decide the mini-game's teams) are recolored at the end of a
round when they would split every team up: a 2 vs 2 that splits both teams becomes team against team, and if every
player is on one team, a 1 vs 3 or 2 vs 2 becomes a 4-player mini-game. Otherwise the panels are left alone, and the
option does nothing unless every player has a teammate.

### `teamControl`

Lets a human play their computer teammates' turns with their own controller.

- Type: `true` or `false`
- Default: `false`

A player whose teammate is human and on a lower-numbered controller is controlled by that teammate's controller: their
turns, menus and mini-games. So in a game of one human and one computer per team, each human plays for both of their
team's characters. A team of two humans doesn't work: the higher-numbered controller's player is taken over too.

## Board

### `alwaysDuel`

Lets duels happen on any turn.

- Type: `true` or `false`
- Default: `false`

The game's other conditions for a duel, such as having coins to wager, still apply.

### `lastPlaceDoubleRoll`

Gives the player in last place two dice blocks to hit.

- Type: `true` or `false`
- Default: `false`

From turn 2, a player in last place (fewest stars, then fewest coins; players tied for last all get it) hits two dice
blocks instead of one. A Golden Mushroom still gives three. Computer players get it too.

### `mapScrollSpeedMultiplier`

How fast the board map scrolls, as a multiple of its normal speed.

- Type: a number
- Default: `1`

`2` scrolls twice as fast.

## Items

### `itemsOnFinalTurn`

Keeps Item Spaces and shops working on the final turn.

- Type: `true` or `false`
- Default: `false`

On the final turn, Item Spaces, the Item Shops and Toad's shop work as they do on the turns before it.

### `increaseItemShopVariety`

Makes the Item Shops' stock more varied.

- Type: `true` or `false`
- Default: `false`

What a shop sells depends on how far into the game it is and the player's place. On each visit, there's a 1 in 3 chance
the shop sells what it would at a neighbouring stage of the game, and from the middle of the game on, a separate 1 in 3
chance it sells what it would for a player in a different place.

### `increaseItemGameVariety`

Makes the item mini-games offer 5 different random items.

- Type: `true` or `false`
- Default: `false`

The items are any of the common items: never the Koopa Kard, Barter Box, Lucky Charm or Wacky Watch.

### `toadShopChance`

How likely a shop is to be Toad's rather than Baby Bowser's.

- Type: a number from 0 to 1, or a negative number for the game's own chance
- Default: `-1`

`0` makes every shop Baby Bowser's, `1` every shop Toad's.

### `replaceWackyWatchBeforeRemainingTurns`

Replaces Wacky Watches with other rare items until near the end of the game.

- Type: a whole number of turns
- Default: `50` (never replaced, since games have at most 50 turns)

A Wacky Watch a player gets while more than this many turns remain, counting the current one, becomes a Koopa Kard,
Barter Box or Lucky Charm instead. For example, `5` allows Wacky Watches only in the last 5 turns.

## Chance Time

### `randomChanceOrder`

Shuffles the order of Chance Time's three blocks.

- Type: `true` or `false`
- Default: `false`

### `chanceSwapInsteadOfTransfer`

Makes Chance Time's "all coins" and "all stars" outcomes swap the two players' totals.

- Type: `true` or `false`
- Default: `false`

Instead of one player giving all their coins or stars to the other, the two players exchange totals. The messages say
so. It applies to the outcome after `chancePrizeReplace` has replaced it, so an outcome replaced with an "all coins"
or "all stars" one swaps too.

### `chancePrizeReplace`

Replaces Chance Time outcomes with others.

- Type: an object of outcomes and their replacements
- Default: `{}`

For example, `{ "STARS_ALL": "STARS_1", "COINS_ALL": "COINS_30" }` turns "all stars" into 1 star and "all coins" into
30 coins.

Outcomes: `COINS_ALL`, `COINS_30`, `COINS_20`, `COINS_10`, `COINS_1`, `STARS_ALL`, `STARS_3`, `STARS_2`, `STARS_1`.

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
      "CHANCE": "Chance", "BOWSER": "Bowser", "BATTLE": "Battle", "ITEM": "Item", "BANK": "Banking",
      "GAME_GUY": "Gambling", "LUCKY": "Lucky"
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
| `GAME_GUY` | landed on the most Game Guy Spaces |
| `LUCKY` | landed on the most Lucky Spaces (only with `luckySpaceRatio`) |

### `improveLastFiveTurnsBonus`

Makes the Last Five Turns event's present for the predicted winner always coins.

- Type: `true` or `false`
- Default: `false`

The present is 10, 20 or 30 coins (20 is the most likely), never Baby Bowser or Whomp.

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

Space types: `RED`, `HAPPENING` (? Space), `CHANCE` (! Space), `ITEM`, `BANK`, `BATTLE`, `BOWSER`, `GAME_GUY`. Other
space types aren't supported.

Turning on this option, `luckySpaceRatio` or `revealHiddenBlocksOnRemainingTurns` also moves the hidden blocks (the
Item, Coin and Star blocks) to random Blue Spaces that aren't Lucky Spaces.

### `luckySpaceRatio`

Turns some of a board's Blue Spaces into Lucky Spaces.

- Type: a number from 0 to 1
- Default: `0` (off)

The number is the fraction of the board's Blue Spaces to make Lucky Spaces. Lucky Spaces have their own picture, on the
board and the map, and landing on one either works as an Item Space or gives more coins than a Blue Space:

- **An Item Space**, with the chance in `luckySpaceItemChance`: Toad's or Baby Bowser's item event, equally likely.
- **Coins** otherwise: 7, 10, 12, 15 or 20 at random, or 12, 15 or 20 when a Blue Space would give 6 coins instead of
  3.

Landing on a Lucky Space doesn't count as a Blue Space for the Blue bonus star, and counts for the `LUCKY` bonus star
instead. At the end of the game, the detailed results (Start, at the final results) have a Lucky Spaces column after
Blue Spaces, with how many Lucky Spaces each player landed on.

Lucky Spaces are chosen with `standardSpaceRatio`'s spaces, from the Blue Spaces it leaves, and stay for the whole game
in the same way. Hidden blocks are never on a Lucky Space.

### `luckySpaceItemChance`

The chance that a Lucky Space works as an Item Space instead of giving coins.

- Type: a number from 0 to 1
- Default: `0.333`

`0` always gives coins, `1` always works as an Item Space. It only matters with `luckySpaceRatio`.

### `revealHiddenBlocksOnRemainingTurns`

Shows where the hidden blocks are near the end of the game.

- Type: a whole number of turns
- Default: `0` (off)

When this many turns or fewer remain, counting the current one, the spaces with the hidden Item, Coin and Star blocks
are shown in gold. `1` shows them on the final turn only, `5` in the last 5 turns. The blocks still work as usual.

### `singleUseBattleSpaces`

Turns a Battle Space into a Blue Space once a battle has been played on it.

- Type: `true` or `false`
- Default: `false`

The Blue Space stays for the rest of the game, and the plugin's other changed spaces (like Lucky Spaces) never take
it. A battle the roulette makes worth 0 coins is cancelled, and leaves the Battle Space as it is.

## Mini-games

### `preventRepeatMiniGames`

Plays every mini-game of a kind before any of them is played again.

- Type: `true` or `false`
- Default: `false`

Each kind of mini-game chosen by a roulette (4-player, 1 vs 3, 2 vs 2, Battle and duel) goes through all of its
mini-games in a random order before starting again. A mini-game played recently doesn't come up again soon after the
order starts again either. The roulette still shows several mini-games, but always stops on the next one. Mini-games
you haven't unlocked yet are included. It works on the Party mode boards, not in Duel mode.

### `blockedMiniGames`

Mini-games that are never played.

- Type: a list of mini-game names
- Default: `[]`

A blocked mini-game can still appear on a roulette, but it never stops on it. If every mini-game of a kind is blocked,
all of that kind are played. Blocking any mini-game also turns on `preventRepeatMiniGames`. Item, Game Guy and other
special mini-games can't be blocked.

| Kind | Mini-games |
|------|------------|
| 4-player | `TREADMILL_GRILL`, `TOADSTOOL_TITAN`, `ACES_HIGH`, `BOUNCE_N_TROUNCE`, `ICE_RINK_RISK`, `CHIP_SHOT_CHALLENGE`, `PARASOL_PLUMMET`, `MESSY_MEMORY`, `PICTURE_IMPERFECT`, `MARIOS_PUZZLE_PARTY`, `THE_BEAT_GOES_ON`, `MPIQ`, `CURTAIN_CALL`, `WATER_WHIRLED`, `FRIGID_BRIDGES`, `AWFUL_TOWER`, `CHEEP_CHEEP_CHASE`, `PIPE_CLEANERS`, `SNOWBALL_SUMMIT`, `ROCKIN_RACEWAY` |
| 1 vs 3 | `HAND_LINE_AND_SINKER`, `COCONUT_CONK`, `SPOTLIGHT_SWIM`, `BOULDER_BALL`, `CRAZY_COGS`, `HIDE_AND_SNEAK`, `RIDICULOUS_RELAY`, `THWOMP_PULL`, `RIVER_RAIDERS`, `TIDAL_TOSS` |
| 2 vs 2 | `EATSA_PIZZA`, `BABY_BOWSER_BROADSIDE`, `PUMP_PUMP_AND_AWAY`, `HYPER_HYDRANTS`, `PICKING_PANIC`, `COSMIC_COASTER`, `PUDDLE_PADDLE`, `ETCH_N_CATCH`, `LOG_JAM`, `SLOT_SYNCH` |
| Battle | `LOCKED_OUT`, `ALL_FIRED_UP`, `STACKED_DECK`, `THREE_DOOR_MONTY`, `MERRY_GO_CHOMP`, `SLAP_DOWN`, `STORM_CHASERS`, `EYE_SORE` |
| Duel | `VINE_WITH_ME`, `POPGUN_PICK_OFF`, `END_OF_THE_LINE`, `BOWSER_TOSS`, `BABY_BOWSER_BONKERS`, `MOTOR_ROOTER`, `SILLY_SCREWS`, `CROWD_COVER`, `TICK_TOCK_HOP`, `FOWL_PLAY` |

### `doubleCoinMiniGames`

Doubles the coins from the mini-game of every fifth turn.

- Type: `true` or `false`
- Default: `false`

On turns 5, 10, 15 and so on, a message announces a bonus mini-game, and the end-of-round mini-game's coins are
doubled. Battle, duel and Game Guy results aren't doubled.

### `battleCoinDistribution`

How a Battle mini-game's pot is shared out by place.

- Type: a list of 4 fractions, for 1st to 4th place
- Default: `[0.7, 0.3, 0, 0]` (the game's own: 70% to 1st, 30% to 2nd)

The fractions can't be negative or add up to more than 1; if they do, the plugin shows an error and uses the default.
A list shorter than 4 is filled out with 0s. Anything left
over goes where the game puts a battle's leftover coins. Players tied for a place share its coins, and a place nobody
finished in gives its share to the place above it.

### `balanceSuperHardCPU`

Makes Super Hard computer players easier in the mini-games where they're hardest to beat.

- Type: `true` or `false`
- Default: `false`

In these mini-games, a Super Hard computer plays at a lower level:

- Normal: Toadstool Titan
- Hard: Baby Bowser Broadside, Hyper Hydrants, The Beat Goes On, Cheep Cheep Chase, Popgun Pick-Off, Bowser Toss,
  Silly Screws

In Log Jam, a computer teamed with a human makes mistakes like one teamed with a computer. Without this, a human's
computer partner never presses a wrong button, at any level.

In Slot Synch, a computer teamed with a human plays at its level, like one teamed with a computer: its level sets how
quickly it stops and how often it misses. It aims for +3, or for the human's symbol once the human has stopped, unless
that's -1 (then it stays off -1, so the round scores nothing). Without this, a human's computer partner never misses,
and stops on whatever symbol the human stopped on, even -1.

### `mpiqPermadeath`

In M.P.I.Q., a player who answers wrong stays out for the rest of the mini-game.

- Type: `true` or `false`
- Default: `false`

Normally a wrong answer only locks a player out of that question. If all four players are locked out, they're all let
back in.

## Bingo

These need `bingoURL` (see the [configuration page](configuration.md)), connected to a game on
[Mario Party Bingo](https://mp.bingo/).

### `superstarsMiniGames`

Plays the mini-games in Mario Party Superstars instead.

- Type: `true` or `false`
- Default: `false`
- Needs: `bingoURL`

The 4-player, 1 vs 3, 2 vs 2, Battle and duel roulettes show Mario Party Superstars mini-games, going through all of
each kind before repeating, as `preventRepeatMiniGames` does. Battles use the 4-player mini-games, in the same order as
the 4-player roulette. A roulette shows at most one coin mini-game (in yellow)
and one Bowser mini-game (in red); the duel roulette shows 3. Item, Game Guy and special mini-games stay Mario Party 3's.

When the roulette stops, the game tells the players which mini-game to play in Mario Party Superstars, and who's on
which side, then waits. Enter the results on the bingo page, and the game carries on with them:

- **4-player, 1 vs 3 and 2 vs 2:** each player's coins, shown on the usual results screen.
- **Battle:** each player's place; the pot is shared out as usual (or by `battleCoinDistribution`).
- **Duel:** the winner, or a tie.

The Battle roulette uses Mario Party Superstars' 4-player mini-games, apart from its coin mini-games.

### `blockedSuperstarsMiniGames`

Mario Party Superstars mini-games that are never played.

- Type: a list of mini-game names
- Default: `[]`

Works like `blockedMiniGames`. It only matters with `superstarsMiniGames`. Coin mini-games are marked (coin), Bowser
mini-games (Bowser).

| Kind | Mini-games |
|------|------------|
| 4-player | `MUSHROOM_MIX_UP`, `BOMBS_AWAY`, `SHY_GUY_SAYS`, `CRAZY_CUTTERS`, `TIPSY_TOURNEY`, `FACE_LIFT` (Bowser), `HAMMER_DROP` (coin), `CAST_AWAYS` (coin), `DIZZY_DANCING`, `BUMPER_BALLS`, `HOT_ROPE_JUMP`, `TREAD_CAREFULLY`, `BUMPER_BALLOON_CARS`, `SNEAK_N_SNORE`, `MECHA_MARATHON`, `SLOT_CAR_DERBY`, `BOWSER_S_BIG_BLAST`, `ROLL_CALL`, `HONEYCOMB_HAVOC`, `SNOWBALL_SUMMIT`, `ICE_RINK_RISK`, `BOUNCE_N_TROUNCE`, `STORM_CHASERS`, `MUSH_PIT`, `CHEEP_CHEEP_CHASE`, `CHIP_SHOT_CHALLENGE`, `ROCKIN_RACEWAY`, `MESSY_MEMORY`, `PARASOL_PLUMMET` (coin), `TRACE_RACE`, `BOOKSQUIRM`, `PATHS_OF_PERIL`, `DINGER_DERBY`, `LEAF_LEAP`, `PUSHY_PENGUINS`, `CONEY_ISLAND`, `BILL_BLASTERS`, `NIGHT_LIGHT_FRIGHT`, `LATER_SKATER`, `CATCH_YOU_LETTER`, `TRAP_EASE_ARTIST`, `WHAT_GOES_UP`, `SNOW_WHIRLED`, `DARK_N_CRISPY` (Bowser), `PIT_BOSS` (Bowser), `X_RAY_PAYDAY` (coin), `MONTY_S_REVENGE`, `THE_FINAL_COUNTDOWN`, `POKEY_PUMMEL`, `MANOR_OF_ESCAPE`, `GOOMBA_SPOTTING`, `FLASH_FORWARD`, `RAPID_RIVER_RACE` |
| 1 vs 3 | `PIRANHA_S_PURSUIT`, `TUG_O_WAR`, `ARCHER_IVAL`, `LOOK_AWAY`, `QUICKSAND_CACHE` (coin), `TIDAL_TOSS`, `BOULDER_BALL`, `COCONUT_CONK`, `SPOTLIGHT_SWIM`, `HIDE_AND_SNEAK`, `RIVER_RAIDERS` (coin), `GOOOOOOOAL`, `MONEY_BELTS` (coin), `SQUARED_AWAY`, `TUBE_IT_OR_LOSE_IT`, `POGO_A_GO_GO`, `TACKLE_TAKEDOWN`, `SKEWER_SCURRY` |
| 2 vs 2 | `BOBSLED_RUN`, `HANDCAR_HAVOC`, `DUNGEON_DASH`, `SPEED_HOCKEY`, `BALLOON_BURST`, `CAKE_FACTORY`, `SKY_PILOTS`, `ETCH_N_CATCH`, `PICKING_PANIC`, `EATSA_PIZZA`, `PUDDLE_PADDLE` (coin), `DUNGEON_DUOS`, `REVERS_A_BOMB`, `BURNSTILE`, `ROCKY_ROAD`, `CASHAPULT` (coin), `PAINT_MISBEHAVIN`, `WINNER_OR_DINNER` (coin) |
| Duel | `TICKTOCK_HOP`, `VINE_WITH_ME`, `MOTOR_ROOTER`, `MASS_METEOR`, `SPIN_DOCTOR` |

### `bingoPlayerNames`

Shows each player's bingo card name in the game instead of their character's name.

- Type: `true` or `false`
- Default: `false`
- Needs: `bingoURL`

Wherever the game names a character (in messages, menus, the duel opponent list and the mini-game help), it shows the
name of that character's bingo card, in the character's color. A card named "CPU" shows the character's name. A name
the game grays out (like a player who can't be chosen in a menu) stays gray.

## Other

### `enhancedTaunts`

Plays a character voice when a player presses a button by itself.

- Type: `true` or `false`
- Default: `false`

During a game, a human player pressing one of these buttons on its own plays their character saying:

| Button | Voice |
|--------|-------|
| L | taunt |
| D-pad Right | being chosen |
| D-pad Left | getting an item |
| D-pad Down | winning a star |
| D-pad Up | winning a mini-game |
| C-Right | despair |
| C-Left | despair (another) |
| C-Down, C-Up | losing a mini-game |

### `autoStartNextBoard`

Starts a new game on the next board when a game ends.

- Type: `true` or `false`
- Default: `false`

After the final results, the next board starts instead of returning to the castle grounds, in this order: Chilly
Waters, Deep Bloober Sea, Spiny Desert, Woody Woods, Creepy Cavern, Waluigi's Island, then Chilly Waters again. It
starts like any new game, with the same players and settings: everyone has the usual starting coins and no stars or
items, and the plugin's options start over too (such as Lucky Spaces and the mini-game order).

### `finalResultsDoNotProceed`

Keeps the final results on screen until a player presses A and Z together.

- Type: `true` or `false`
- Default: `false`

### `unlockEverything`

Unlocks the mini-games, the Super Hard computer level and Waluigi's Island.

- Type: `true` or `false`
- Default: `false`

The save file isn't changed: turning the option off locks them again.

### `widescreen`

Plays the game in 16:9 widescreen.

- Type: `true` or `false`
- Default: `false`

The game draws a 424x240 picture instead of 320x240: the board, mini-games and menus show more to the sides, with the
HUD moved to fit (like the players' panels, in the corners on the board). Set the video plugin to stretch the picture to
16:9, or it's squeezed into 4:3. It needs the Expansion Pak (on by default in RMG).

It also works with custom boards made with PartyPlanner64.

The option takes effect when the game boots, so restart the game after changing it, and don't load save states made
with it set the other way.

#### Credits

This option is an adaptation of [gamemasterplc's widescreen patch for Mario Party 3](https://www.youtube.com/watch?v=DME9IiB77fg),
licensed under the [Creative Commons Attribution license (CC BY 3.0)](https://creativecommons.org/licenses/by/3.0/).
The patch changes the ROM; the plugin makes its changes as the game runs ([`mp3widescreen.d`](../mp3widescreen.d)).
What's changed from the patch:

- The background images the patch widened are made from the game's own images as they're loaded (their sides extended,
  tiled or mirrored, or the image stretched or zoomed), instead of being the patch's. Most are close to the patch's;
  a few the patch partly redrew are simpler here, like the castle's hills and the clouds in two mini-game backgrounds,
  and one board picture, which is stretched.
- Memory is laid out so that it also works with custom boards (the patch's framebuffers and depth buffer are where they
  keep their main heap).
- Some of the patch's changes were made to the instruction next to the one intended, or with the wrong register, which
  broke a store, a call or a load there (most of them in the Mini-Game Room). They're made where they were meant to be.
- The patch's changes to ROM offsets (for its own file system) and two changes that aren't for widescreen aren't made.
- A few values the patch missed are moved too, like where an item being bought appears on the board.
- The detailed results (Start, at the final results) scroll to their last column (Game Guy Spaces), which the patch
  never showed.
- The night sky at the end of a game (where the results are announced) fills the wider screen.

### `sharperCustomBoardMaps`

On boards made with PartyPlanner64, the zoomed-out map (Z on a turn) is made from the board's own background shrunk to
640x480 instead of the 320x240 copy PartyPlanner64 saves. It's sharper when the emulator
renders above the N64's resolution (like Parallel's upscaling).

The map is also made from the background the board is showing that turn. PartyPlanner64 boards can change their
background between turns, like Seasonal Woodland's four seasons, but their map always showed the first one; now it
shows the current one.

The original boards keep their own maps, which are drawn by hand (their routes and arrows over a darkened board).

### `customCPUJunctionArrowFix`

On boards made with PartyPlanner64 that pick a computer's direction at a junction with their own event (like
Seasonal Woodland, whose computers head for the star), the arrow the computer chooses points the way it goes.
PartyPlanner64's junction has the computer pick an arrow at random, and the board's event then picks again and the
computer often walks the other way. With this option, the board's event chooses first and the arrow follows it.

### `customReverseMovementFix`

On boards made with PartyPlanner64, walking backward with a Reverse Mushroom no longer crashes the game or sends
players off the board's paths. On many of these boards (like Sarasaland), a player who reverses into the start bounces
off it but stays marked as walking backward. If they land just after the start, their next move walks off the end of
the start's path, and the game reads a space that doesn't exist, which can crash it. A player who lands on a space where
paths join at the end of a reverse move, then uses another Reverse Mushroom, has the same problem.

With this option, a player who bounces off a dead end turns around. A Reverse Mushroom used on a space where paths join
asks which way to go back. Any other step to a space that doesn't exist turns the player around. The original boards
are unchanged.

### `customExtraItemShopFix`

On boards made with PartyPlanner64 that have more than two item shops (like Kaos Kore), every shop works like a shop.
PartyPlanner64's item shop only knows the board's first two (by their order in the board). Any other shop runs like a Cellular Shopper call: the camera doesn't go to the shop, the shopkeeper
doesn't come out, and "View Map" closes the map as soon as it opens, then leaves the board stopped for the rest of the
turn. The camera stays on the shop while the player walks away, and the game can crash.

With this option, those shops are paired with their closest shop building, the way PartyPlanner64 pairs the first two,
and play out like them: the shopkeeper comes out, and View Map can be scrolled. Computers shopping there use the first
two shops' buying choices in turn. Shops made with other events (a board's own custom shop), the Cellular Shopper and
the original boards are unchanged.
