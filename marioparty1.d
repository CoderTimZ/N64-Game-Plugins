module me.timz.n64.marioparty1;

import me.timz.n64.marioparty;
import me.timz.n64.plugin;
import std.algorithm;
import std.range;
import std.stdio;
import std.json;
import std.conv;
import std.random;
import std.stdio;
import std.string;
import std.traits;

class Config : MarioPartyConfig {
    float[Block] blockWeights;
    bool teamControl = false;
    bool teamMiniGames = false;
    bool teamScores = false;
    int[Character] teams;
    bool randomBonus = false;
    string[BonusType] bonuses;
    float[Space.Type] standardSpaceRatio;
    float mapScrollSpeedMultiplier = 1.0;
    bool preventRepeatMiniGames = false;
    MiniGame[] blockedMiniGames;

    this() {
        blockWeights = [
            Block.PLUS:    1,
            Block.MINUS:   1,
            Block.SPEED:   1,
            Block.SLOW:    1,
            Block.WARP:    1,
            Block.NORMAL: 27
        ];

        bonuses = [
            BonusType.MINI_GAME:       "Game", // Mario Party 1's own name for it
            BonusType.COIN:            "Coin",
            BonusType.HAPPENING:       "Happening",
            BonusType.RED:             "Unlucky",
            BonusType.BLUE:            "Blue",
            BonusType.MINI_GAME_SPACE: "Game Space",
            BonusType.CHANCE:          "Chance",
            BonusType.MUSHROOM:        "Mushroom",
            BonusType.BOWSER:          "Bowser"
        ];

        teams = [
            Character.MARIO: 2,
            Character.LUIGI: 2,
            Character.PEACH: 1,
            Character.YOSHI: 1,
            Character.WARIO: 1,
            Character.DK:    1
        ];
    }
}

class PlayerState {

}

class State : MarioPartyState!PlayerState {
    ShuffleStream!MiniGame[MiniGameType] miniGameQueue;
    CustomSpace[] spaces;
}

union Space {
    static enum Type : byte {
        INVISIBLE = 0,
        BLUE      = 1,
        RED       = 2,
        MINI_GAME = 3,
        HAPPENING = 4,
        STAR      = 5,
        CHANCE    = 6,
        START     = 7,
        MUSHROOM  = 8,
        BOWSER    = 9
    }

    ubyte[0x20] _data;
    mixin Field!(0x01, Type, "type");

    bool isSolid() {
        switch (type) {
            case Type.BLUE:
            case Type.RED:
            case Type.MINI_GAME:
            case Type.HAPPENING:
            case Type.CHANCE:
            case Type.MUSHROOM:
            case Type.BOWSER:
                return true;
            default:
                return false;
        }
    }
}

enum CustomSpace : byte {
    DEFAULT   = -2,
    LOCKED    = -1,
    INVISIBLE =  0,
    BLUE      =  1,
    RED       =  2,
    MINI_GAME =  3,
    HAPPENING =  4,
    STAR      =  5,
    CHANCE    =  6,
    START     =  7,
    MUSHROOM  =  8,
    BOWSER    =  9
}

union PlayerData {
    ubyte[0x30] _data;
    mixin Field!(0x00, ubyte, "group"); // Which side of a mini-game or Chance Time the player is on
    mixin Field!(0x01, ubyte, "cpuDifficulty1");
    mixin Field!(0x02, ubyte, "cpuDifficulty2");
    mixin Field!(0x03, ubyte, "controller");
    mixin Field!(0x04, Character, "character");
    mixin Field!(0x07, ubyte, "flags");
    mixin Field!(0x08, ushort, "coins");
    mixin Field!(0x0A, short, "miniGameCoinsToAdd"); // After the mini-game
    mixin Field!(0x0C, ushort, "stars");
    mixin Field!(0x0E, ushort, "currentChainIndex");
    mixin Field!(0x10, ushort, "currentSpaceIndex");
    mixin Field!(0x12, ushort, "nextChainIndex");
    mixin Field!(0x14, ushort, "nextSpaceIndex");
    mixin Field!(0x16, ubyte, "poisoned");
    mixin Field!(0x17, PanelColor, "color");
    mixin Field!(0x24, short, "miniGameCoins"); // Won (or lost) in mini-games, for the Game Star
    mixin Field!(0x26, ushort, "maxCoins");
    mixin Field!(0x28, ubyte, "happeningSpaces");
    mixin Field!(0x29, ubyte, "redSpaces");
    mixin Field!(0x2A, ubyte, "blueSpaces");
    mixin Field!(0x2B, ubyte, "miniGameSpaces");
    mixin Field!(0x2C, ubyte, "chanceSpaces");
    mixin Field!(0x2D, ubyte, "mushroomSpaces");
    mixin Field!(0x2E, ubyte, "bowserSpaces");
}

union Memory {
    ubyte[0x800000] ram;
    mixin Field!(0x800175B8, Instruction, "randomByteRoutine");
    mixin Field!(0x80054FE4, Instruction, "determineTeams"); // Counts blue/red panels: the mini-game type, or -1
    mixin Field!(0x800C2FF4, uint, "randomState");
    mixin Field!(0x800C4D3C, Arr!(ubyte, 4), "miniGameRouletteSizes"); // By MiniGameType
    mixin Field!(0x800D6454, Arr!(MiniGame, 5), "miniGameRoulette");
    mixin Field!(0x800D8100, ushort, "spaceCount");
    mixin Field!(0x800D8108, Ptr!Space, "spaces");
    mixin Field!(0x800D83A8, Arr!(PlayerPanel, 4), "playerPanels");
    // What the board does once the current space's events are done (func_800587BC(overlay, entrance, fade, sound) asks
    // for an overlay call): flags (8: call boardRequestOverlay), the fade, whether to play a sound, and the overlay
    mixin Field!(0x800D86EC, short, "boardRequest");
    mixin Field!(0x800D86EE, short, "boardRequestFade");
    mixin Field!(0x800D86F0, short, "boardRequestSound");
    mixin Field!(0x800D86F4, int, "boardRequestOverlay");
    mixin Field!(0x800D86F8, short, "boardRequestEntrance");
    // Each player's bonus stars, once the board's end has given them: the final results add them to the players'
    // stars (at 0x800FB0F0), and put the stars back (as they saved them) when the game goes back to the title screen
    mixin Field!(0x800ED168, Arr!(ushort, 4), "bonusStars");
    mixin Field!(0x800ED5C7, ubyte, "totalTurns");
    mixin Field!(0x800ED5C9, ubyte, "currentTurn");
    mixin Field!(0x800ED5DC, ushort, "currentPlayerIndex");
    mixin Field!(0x800F09F4, Scene, "currentScene");
    mixin Field!(0x800F32B0, Arr!(PlayerData, 4), "players");
    mixin Field!(0x800F9601, ubyte, "booPlayer");     // Boo scene: the player using Boo
    mixin Field!(0x800F9630, int, "booCpuChoice");    // Boo scene, CPU: 0 coins, 1 stars, 2 nothing (the first menu)
    mixin Field!(0x800F9634, int, "booCpuVictim");    // Boo scene, CPU: the player to steal from
    mixin Field!(0x801012E0, ubyte, "chancePlayer1");
    mixin Field!(0x801012E1, ubyte, "chancePlayer2");
    mixin Field!(0x801012E2, ubyte, "chanceOutcome");
}

union PlayerPanel {
    ubyte[0x40] _data;
    mixin Field!(0x03, PanelColor, "color");
}

class MarioParty1 : MarioParty!(Config, State, Memory) {
    bool coinsEqualizing; // In the Bowser Space event that sets everyone's coins to the average

    this(string name, string hash) {
        super(name, hash);

        // Keep the State on the permanent heap (D_800D6030, MakePermHeap, HuMemDirectMalloc, HuMemDirectFree, HuPrcVSleep)
        permanentHeap = PermanentHeap(0x800D6030, 0x8003B680, 0x8003B6A4, 0x8003B6C8, 0x800635B4);
        tempHeap = TempHeap(0x8003B774, 0x8003B798); // MallocTemp, FreeTemp (on D_800D6040)
    }

    // A Chance Time between teammates changes nothing for the team. Once the blocks stop, chancePlayer1 and
    // chancePlayer2 are player indices (Chance Time's own result window reads GwPlayer[] with them).
    override bool lockTeamScores() const {
        if (data.currentScene == Scene.CHANCE_TIME) {
            if (data.chancePlayer1 < players.length && data.chancePlayer2 < players.length) {
                return team(players[data.chancePlayer1])
                    == team(players[data.chancePlayer2]);
            }
        }
        return false;
    }

    // The Bowser Space event that sets every player's coins to the average moves each player's coins one at a time, so
    // syncing teammates would count each change twice (like Mario Party 3's Bowser Revolution)
    override bool disableTeamScores() const {
        return data.currentScene == Scene.BOWSER && coinsEqualizing;
    }

    override bool disableTeamControl() const {
        return data.currentScene == Scene.GAME_SETUP
            || data.currentScene == Scene.FINAL_RESULTS_2;
    }

    alias isBoardScene = typeof(super).isBoardScene;
    alias isScoreScene = typeof(super).isScoreScene;

    override bool isBoardScene(Scene scene) const {
        switch (scene) {
            case Scene.DKS_JUNGLE_ADVENTURE:
            case Scene.PEACHS_BIRTHDAY_CAKE:
            case Scene.YOSHIS_TROPICAL_ISLAND:
            case Scene.WARIOS_BATTLE_CANYON:
            case Scene.LUIGIS_ENGINE_ROOM:
            case Scene.MARIOS_RAINBOW_CASTLE:
            case Scene.BOWSERS_MAGMA_MOUNTAIN:
            case Scene.ETERNAL_STAR:
                return true;
            default:
                return false;
        }
    }

    override bool isMiniGameScene(Scene scene) const {
        return scene == Scene.MEMORY_MATCH || (Scene.SLOT_MACHINE <= scene && scene <= Scene.BUMPER_BALL_MAZE);
    }

    override bool isScoreScene(Scene scene) const {
        switch (scene) {
            case Scene.FINISH_BOARD:
            case Scene.FINISH_BOARD_NO_STARS:
            // Board events that change the current player's coins or stars (and only theirs; the Piranha Plant moves
            // a Star to the player who planted it)
            case Scene.CALLED_BOWSER:
            case Scene.PATH_TOLL:
            case Scene.BOWSER_VISIT_DK:
            case Scene.BOWSER_VISIT_PEACH:
            case Scene.GOOMBA_PEACH:
            case Scene.FLOWER_LOTTERY_PEACH:
            case Scene.PIRANHA_PLANT_PEACH:
            case Scene.THWOMP_TOLL_YOSHI:
            case Scene.BOWSER_VISIT_YOSHI:
            case Scene.BOWSER_VISIT_WARIO:
            case Scene.BOWSER_VISIT_LUIGI:
            case Scene.DOORS_LUIGI:
            case Scene.BOWSER_VISIT_MARIO:
            case Scene.SHORTCUT_MAGMA_MOUNTAIN:
            case Scene.BOWSER_VISIT_MAGMA_MOUNTAIN:
            case Scene.BOWSER_VISIT_ETERNAL_STAR:
            case Scene.STAR_ETERNAL_STAR:
            case Scene.SPECIAL_BONUS:
            case Scene.TOAD:
            case Scene.BOWSER:
            case Scene.BOB_OMB:
            case Scene.SHY_GUY:
            case Scene.KOOPA:
            case Scene.BOO:
            case Scene.START_BOARD:
            case Scene.CHANCE_TIME:
            case Scene.MINI_GAME_RESULTS:
                return true;
            default:
                return isBoardScene(scene);
        }
    }

    // The bonus stars are given in scene FINISH_BOARD, or FINISH_BOARD_NO_STARS when nobody has a Star yet (a copy of
    // it, at other addresses)
    bool isBonusScene() const {
        return data.currentScene == Scene.FINISH_BOARD || data.currentScene == Scene.FINISH_BOARD_NO_STARS;
    }

    override uint getBonusStat(Player player, BonusType type) {
        final switch (type) {
            case BonusType.MINI_GAME:       return cast(uint)cast(int)player.data.miniGameCoins; // Signed, as the game compares it
            case BonusType.COIN:            return player.data.maxCoins;
            case BonusType.HAPPENING:       return player.data.happeningSpaces;
            case BonusType.RED:             return player.data.redSpaces;
            case BonusType.BLUE:            return player.data.blueSpaces;
            case BonusType.MINI_GAME_SPACE: return player.data.miniGameSpaces;
            case BonusType.CHANCE:          return player.data.chanceSpaces;
            case BonusType.MUSHROOM:        return player.data.mushroomSpaces;
            case BonusType.BOWSER:          return player.data.bowserSpaces;
        }
    }

    // Text (game bytes) for the bonus star messages, or null for other messages. Each bonus star has 5 messages
    // (264, 269, 274): the award, then the winner, or a 2-, 3- or 4-way tie. The lines and line counts follow the
    // game's own messages, which have to fit fixed-size windows. Mario Party 1's text uses 0x10 for spaces.
    string bonusMessage(ushort id) {
        if (id < 264 || id > 278) return null;

        auto i = (id - 264) / 5;
        auto b = bonus[i];
        auto star = "<" ~ getColor(b) ~ ">" ~ config.bonuses[b] ~ " Star";
        string text;
        final switch ((id - 264) % 5) {
            case 0: text = ["First", "Next", "Last"][i] ~ ", the " ~ star ~ "<WHITE>.\nThis award goes to the player\nwho " ~ getDescription(b) ~ "."; break;
            case 1: text = "The " ~ star ~ "<WHITE> goes to\n<CYAN><1><WHITE>!"; break;
            case 2: text = "Oh!  This time, there are two\n" ~ star ~ "s<WHITE>.\n<CYAN><1><WHITE> and <CYAN><2><WHITE>!"; break;
            case 3: text = "Oh!  This time, we have\nthree " ~ star ~ "s<WHITE>.\n<CYAN><1><WHITE>, <CYAN><2><WHITE>,\nand also <CYAN><3><WHITE>!"; break;
            case 4: text = "Why, this time all four\nplayers are " ~ star ~ "s<WHITE>!\nWhich means,\n<RED>There is no winner!"; break;
        }
        return formatText(text ~ "<END><NUL>").replace(" ", "\x10");
    }

    override void onStart() {
        super.onStart();

        0x80040828.onExec({
            gpr.v0 = weighted(config.blockWeights, random);
        });

        if (config.preventRepeatMiniGames || config.blockedMiniGames.length > 0) {
            data.currentScene.onWrite((ref Scene scene) {
                if (scene == Scene.START_BOARD) {
                    state.miniGameQueue.clear();
                    saveState();
                }
            });
            // Populate mini-game roulette (func_8004388C). For each slot it picks a random mini-game of the type (s2)
            // and stores it here (slot s0), then picks again if it's a duplicate, recently played, or needs more coins
            // than players have. The plugin fills every slot itself, so it skips all of that: picking again would
            // throw its choice away (or never end).
            0x80043AC4.onExec({
                if (!isBoardScene()) return;
                if (gpr.s2 > MiniGameType.max) return;
                if (gpr.s0 == 0) {
                    auto type = cast(MiniGameType)gpr.s2;
                    auto games = [EnumMembers!MiniGame].filter!(g => g.type == type).array;
                    // The roulette (func_80042BAC) stores the slot it will stop on at 0x80042DB0 (v1)
                    fillMiniGameRoulette!"v1"(type, games, data.miniGameRouletteSizes[gpr.s2], 0x80042DB0);
                    saveState();
                }
                jump(0x80043C90); // Show the slot's mini-game
            });
            // Prevent the mini-game roulette from jumping backward
            0x80043060.onExec({ if (isBoardScene()) gpr.v0 = 1; });
        }

        if (config.teamScores) {
            data.currentScene.onWrite((ref Scene scene) {
                if (scene != Scene.BOWSER) coinsEqualizing = false;
            });

            // The final results add each player's own bonus stars to their stars, outside the scenes where teammates'
            // scores are kept the same. Each player's bonus stars are made their team's, before the board's winner is
            // shown, so the final results give every teammate the team's.
            data.currentScene.onWrite((ref Scene scene) {
                if (scene != Scene.BOARD_WINNER || data.currentScene == Scene.BOARD_WINNER) return;
                ushort[4] team;
                foreach (p; players) team[p.index] = cast(ushort)teamMembers(p).map!(t => cast(int)data.bonusStars[t.index]).sum;
                foreach (i, b; team) data.bonusStars[i] = b;
            });

            0x800F6AF8.onExec({ // func_800F6AF8_BowserSpaceEvent: sets every player's coins to the average
                if (data.currentScene == Scene.BOWSER) coinsEqualizing = true;
            });

            // Boo can't steal from the player's teammates. The Boo scene (func_800F884C) enables "Steal Coins" and
            // "Steal Stars" if another player has coins or stars, and each player in "From whom?" if they have them:
            // these loads (of player s1's coins or stars) read 0 for teammates, so teammates are greyed out.
            bool booTeammate(uint i) {
                return data.currentScene == Scene.BOO && i < players.length && data.booPlayer < players.length
                    && i != data.booPlayer && team(players[i]) == team(players[data.booPlayer]);
            }
            foreach (load; [0x800F890C, 0x800F8988, 0x800F8B10, 0x800F8B54]) {
                load.onExecDone({ if (booTeammate(gpr.s1)) gpr.v0 = 0; });
            }
            // A CPU player decides in func_800F7278, which leaves here with its choice and victim. The menus move the
            // cursor to them, so a teammate (greyed out) can't be the victim: steal from the opponent with the most
            // of what it's stealing instead, or don't steal if no opponent has any.
            0x800F7628.onExec({
                if (data.currentScene != Scene.BOO) return;
                auto choice = data.booCpuChoice;
                if (choice != 0 && choice != 1) return;
                if (!booTeammate(data.booCpuVictim)) return;

                uint amount(Player p) { return choice == 0 ? p.data.coins : p.data.stars; }
                auto opponents = players.filter!(p => p.index != data.booPlayer && !booTeammate(p.index) && amount(p) > 0);
                if (opponents.empty) {
                    data.booCpuChoice = 2; // Don't do anything
                } else {
                    data.booCpuVictim = cast(int)opponents.maxElement!(p => amount(p)).index;
                }
            });
        }

        if (config.randomBonus) {
            setUpRandomBonus!"s3"([[0x800F828C, 0x800F82D0], [0x800F8648, 0x800F868C], [0x800F8A04, 0x800F8A48]], true);
            setUpRandomBonus!"s3"([[0x800F8454, 0x800F8498], [0x800F87E0, 0x800F8824], [0x800F8B6C, 0x800F8BB0]], true,
                                  Scene.FINISH_BOARD_NO_STARS);

            // Every message is loaded by ID through func_8005B7E8(id), which reads it from ROM into a newly allocated
            // buffer of its length. Loading a different length and writing the bonus star text into that buffer
            // replaces the message with nothing else to manage: the game frees the buffer itself.
            ushort messageId;
            string replacement;
            0x8005B7E8.onExec({ messageId = cast(ushort)gpr.a0; });
            0x8005B7FC.onExec({ // 16(sp) = ROM address, 20(sp) = length; next, it allocates and reads that many bytes
                if (!isBonusScene() || bonus.length < 3) return;
                replacement = bonusMessage(messageId);
                if (replacement is null) return;
                if (replacement.length % 2) replacement ~= '\0';
                (gpr.sp + 20).val!ushort = cast(ushort)replacement.length;
            });
            0x8005B824.onExec({ // s0 = the buffer
                if (replacement is null) return;
                foreach (i, c; replacement) Ptr!char(gpr.s0)[i] = c;
                replacement = null;
            });
            // The bonus star windows (at 30, 42) are sized for the game's own text, 15 to 18 wide: make them all 18,
            // the widest the game uses there, so other stars' names fit
            0x8004D930.onExec({ // CreateTextWindow(x, y, w, h)
                if (!isBonusScene() || bonus.length < 3) return;
                if (cast(short)gpr.a0 != 30 || cast(short)gpr.a1 != 42) return;
                if (cast(short)gpr.a2 < 18) gpr.a2 = 18;
            });
        }

        if (config.standardSpaceRatio.values.any!(v => v > 0.0)) {
            resetCustomSpacesAtStart();
            0x8004BA04.onExec({ // RenderSpaces: draws every space with its type's texture, each frame
                if (!isBoardScene()) return;
                if (!data.spaces) return;

                if (assignCustomSpaces()) {
                    saveState();
                }
            });

            // Chance Time comes from an event the board gives each of its ! Spaces, not from the space type, so
            // converted ! Spaces would do nothing. RunSpaceEvents (0x8004C968, a0 = space, a1 = activation) has the
            // space in s0 and the activation in s3 here: on landing (3) on a converted ! Space, do what the boards'
            // own ! Space event does (like 0x800F79BC on Peach's Birthday Cake)
            0x8004CA28.onExec({
                if (cast(short)gpr.s3 != 3) return;
                auto space = cast(short)gpr.s0;
                if (space < 0 || space >= data.spaceCount || space >= state.spaces.length) return;
                if (state.spaces[space] != CustomSpace.CHANCE) return;
                if (data.spaces[space].type != Space.Type.CHANCE) return;

                // The current player is on one side, everyone else on the other
                players.each!(p => p.data.group = (p.index == data.currentPlayerIndex ? 0 : 1));
                // func_800587BC(1, 0, 5, 1): Chance Time (scene 1), back to the board after it
                data.boardRequestOverlay = Scene.CHANCE_TIME;
                data.boardRequestEntrance = 0;
                data.boardRequest = 8;
                data.boardRequestFade = 5;
                data.boardRequestSound = 1;
            });
        }

        // The Bingo page gets the players' stars with the bonus stars, which the final results add (in the loop
        // ending at 0x800FB158) outside the scenes where star changes are sent
        0x800FB158.onExec({
            if (data.currentScene != Scene.FINAL_RESULTS) return;
            players.each!(p => sendPlayerInfo(p));
        });

        if (config.mapScrollSpeedMultiplier != 1.0) {
            setUpMapScrollSpeed(0x80058F5C);
        }

        if (config.rankPlayersByBingoScore) {
            setUpBingoRanking(0x8004FEBC, 0x8004FF60, 0x8004FEE4, 0x846332BC);
        }

        fixChanceTimeDuplicates(0x800FC830, 0x800FE1A0); // Chance Time duplicate character fix

        watchPlayerInfo(); // Keep this at the bottom
    }
}

extern (C) {
    string getName() {
        return "Mario Party 1";
    }

    int startup() {
        version (TestDriver) {
            import me.timz.n64.mp1test : TestMarioParty1;
            pluginFactory = (name, hash) => new TestMarioParty1(name, hash); // The test build (test/mp1test.d)
        } else {
            pluginFactory = (name, hash) => new MarioParty1(name, hash);
        }

        return 0;
    }
}

enum Block : ubyte {
    PLUS   = 0x00,
    MINUS  = 0x01,
    SPEED  = 0x02,
    SLOW   = 0x03,
    WARP   = 0x04,
    NORMAL = 0xFF
}

enum BonusType {
    MINI_GAME,
    COIN,
    HAPPENING,
    RED,
    BLUE,
    MINI_GAME_SPACE,
    CHANCE,
    MUSHROOM,
    BOWSER
}

// Mario Party 1's colors aren't FORMATTING's (which are Mario Party 3's), so these are the codes Mario Party 1's own
// messages use for each: 0x03 for Red Spaces, 0x04 for the Coin Star and Bowser Spaces, 0x05 for ? Spaces, ! Spaces
// and Mushroom Spaces, and 0x06 for the Game Star, Blue Spaces and Mini-Game Spaces. 0x08 ends a color.
string getColor(BonusType type) {
    final switch (type) {
        case BonusType.MINI_GAME:       return "CYAN";
        case BonusType.COIN:            return "MAGENTA";
        case BonusType.HAPPENING:       return "GREEN";
        case BonusType.RED:             return "RED";
        case BonusType.BLUE:            return "CYAN";
        case BonusType.MINI_GAME_SPACE: return "CYAN";
        case BonusType.CHANCE:          return "GREEN";
        case BonusType.MUSHROOM:        return "GREEN";
        case BonusType.BOWSER:          return "MAGENTA";
    }
}

// What the winner did, after "who " (two lines)
string getDescription(BonusType type) {
    final switch (type) {
        case BonusType.MINI_GAME:       return "collected the most Coins\nin Mini-Games";
        case BonusType.COIN:            return "held the most Coins\nat one time";
        case BonusType.HAPPENING:       return "landed on the most\n<GREEN>? Spaces<WHITE>";
        case BonusType.RED:             return "landed on the most\n<RED>Red Spaces<WHITE>";
        case BonusType.BLUE:            return "landed on the most\n<CYAN>Blue Spaces<WHITE>";
        case BonusType.MINI_GAME_SPACE: return "landed on the most\n<CYAN>Mini-Game Spaces<WHITE>";
        case BonusType.CHANCE:          return "landed on the most\n<GREEN>! Spaces<WHITE>";
        case BonusType.MUSHROOM:        return "landed on the most\n<GREEN>Mushroom Spaces<WHITE>";
        case BonusType.BOWSER:          return "landed on the most\n<MAGENTA>Bowser Spaces<WHITE>";
    }
}

// The game's mini-game types (its roulette's categories, in its own order)
enum MiniGameType {
    FOUR_PLAYER = 0,
    ONE_V_THREE = 1,
    TWO_V_TWO   = 2,
    ONE_PLAYER  = 3  // Mini-Game Spaces
}

// The mini-games the board roulettes can show (their lists are at 0x800CAD38), by the roulette's numbers. These
// aren't the scene numbers. A mini-game's name is message 804 + its number.
enum MiniGame : ubyte {
    MEMORY_MATCH        =  1,
    SLOT_MACHINE        =  3,
    BURIED_TREASURE     =  4,
    TREASURE_DIVERS     =  5,
    SHELL_GAME          =  6,
    HOT_BOB_OMB         =  8,
    PIPE_MAZE           = 10,
    GHOST_GUESS         = 11,
    MUSICAL_MUSHROOM    = 12,
    PEDAL_POWER         = 13,
    CRAZY_CUTTER        = 14,
    FACE_LIFT           = 15,
    WHACK_A_PLANT       = 16,
    BASH_N_CASH         = 17,
    BOWL_OVER           = 18,
    GROUND_POUND        = 19,
    BALLOON_BURST       = 20,
    COIN_BLOCK_BLITZ    = 21,
    COIN_BLOCK_BASH     = 22,
    SKATEBOARD_SCAMPER  = 23,
    BOX_MOUNTAIN_MAYHEM = 24,
    PLATFORM_PERIL      = 25,
    TEETERING_TOWERS    = 26,
    MUSHROOM_MIX_UP     = 27,
    GRAB_BAG            = 29,
    BOBSLED_RUN         = 30,
    BUMPER_BALLS        = 31,
    TIGHTROPE_TREACHERY = 32,
    KNOCK_BLOCK_TOWER   = 33,
    TIPSY_TOURNEY       = 34,
    BOMBS_AWAY          = 35,
    CRANE_GAME          = 36,
    SLOT_CAR_DERBY      = 38,
    MARIO_BANDSTAND     = 39,
    DESERT_DASH         = 40,
    SHY_GUY_SAYS        = 41,
    LIMBO_DANCE         = 42,
    BOMBSKETBALL        = 43,
    CAST_AWAYS          = 44,
    KEY_PA_WAY          = 45,
    RUNNING_OF_THE_BULB = 46,
    HOT_ROPE_JUMP       = 47,
    HANDCAR_HAVOC       = 48,
    DEEP_SEA_DIVERS     = 50,
    PIRANHAS_PURSUIT    = 51,
    TUG_O_WAR           = 52,
    PADDLE_BATTLE       = 53,
    COIN_SHOWER_FLOWER  = 55,
    HAMMER_DROP         = 56
}

MiniGameType type(MiniGame game) {
    final switch (game) {
        case MiniGame.BURIED_TREASURE:
        case MiniGame.TREASURE_DIVERS:
        case MiniGame.HOT_BOB_OMB:
        case MiniGame.MUSICAL_MUSHROOM:
        case MiniGame.CRAZY_CUTTER:
        case MiniGame.FACE_LIFT:
        case MiniGame.BALLOON_BURST:
        case MiniGame.COIN_BLOCK_BLITZ:
        case MiniGame.SKATEBOARD_SCAMPER:
        case MiniGame.BOX_MOUNTAIN_MAYHEM:
        case MiniGame.PLATFORM_PERIL:
        case MiniGame.MUSHROOM_MIX_UP:
        case MiniGame.GRAB_BAG:
        case MiniGame.BUMPER_BALLS:
        case MiniGame.TIPSY_TOURNEY:
        case MiniGame.BOMBS_AWAY:
        case MiniGame.SLOT_CAR_DERBY:
        case MiniGame.MARIO_BANDSTAND:
        case MiniGame.SHY_GUY_SAYS:
        case MiniGame.CAST_AWAYS:
        case MiniGame.KEY_PA_WAY:
        case MiniGame.RUNNING_OF_THE_BULB:
        case MiniGame.HOT_ROPE_JUMP:
        case MiniGame.HAMMER_DROP:
            return MiniGameType.FOUR_PLAYER;

        case MiniGame.PIPE_MAZE:
        case MiniGame.BASH_N_CASH:
        case MiniGame.BOWL_OVER:
        case MiniGame.COIN_BLOCK_BASH:
        case MiniGame.TIGHTROPE_TREACHERY:
        case MiniGame.CRANE_GAME:
        case MiniGame.PIRANHAS_PURSUIT:
        case MiniGame.TUG_O_WAR:
        case MiniGame.PADDLE_BATTLE:
        case MiniGame.COIN_SHOWER_FLOWER:
            return MiniGameType.ONE_V_THREE;

        case MiniGame.BOBSLED_RUN:
        case MiniGame.DESERT_DASH:
        case MiniGame.BOMBSKETBALL:
        case MiniGame.HANDCAR_HAVOC:
        case MiniGame.DEEP_SEA_DIVERS:
            return MiniGameType.TWO_V_TWO;

        case MiniGame.MEMORY_MATCH:
        case MiniGame.SLOT_MACHINE:
        case MiniGame.SHELL_GAME:
        case MiniGame.GHOST_GUESS:
        case MiniGame.PEDAL_POWER:
        case MiniGame.WHACK_A_PLANT:
        case MiniGame.GROUND_POUND:
        case MiniGame.TEETERING_TOWERS:
        case MiniGame.KNOCK_BLOCK_TOWER:
        case MiniGame.LIMBO_DANCE:
            return MiniGameType.ONE_PLAYER;
    }
}

enum Scene : uint {
    MEMORY_MATCH                =   0, // Also the scene number before the game sets one, at boot
    CHANCE_TIME                 =   1,
    SLOT_MACHINE                =   2,
    BURIED_TREASURE             =   3,
    TREASURE_DIVERS             =   4,
    SHELL_GAME                  =   5,
    UNUSED_MINI_GAME_0          =   6,
    HOT_BOB_OMB                 =   7,
    UNUSED_MINI_GAME_1          =   8,
    PIPE_MAZE                   =   9,
    GHOST_GUESS                 =  10,
    MUSICAL_MUSHROOM            =  11,
    PEDAL_POWER                 =  12,
    CRAZY_CUTTER                =  13,
    FACE_LIFT                   =  14,
    WHACK_A_PLANT               =  15,
    BASH_N_CASH                 =  16,
    BOWL_OVER                   =  17,
    GROUND_POUND                =  18,
    BALLOON_BURST               =  19,
    COIN_BLOCK_BLITZ            =  20,
    COIN_BLOCK_BASH             =  21,
    SKATEBOARD_SCAMPER          =  22,
    BOX_MOUNTAIN_MAYHEM         =  23,
    PLATFORM_PERIL              =  24,
    TEETERING_TOWERS            =  25,
    MUSHROOM_MIX_UP             =  26,
    HAMMER_DROP                 =  27,
    GRAB_BAG                    =  28,
    BOBSLED_RUN                 =  29,
    BUMPER_BALLS                =  30,
    TIGHTROPE_TREACHERY         =  31,
    KNOCK_BLOCK_TOWER           =  32,
    TIPSY_TOURNEY               =  33,
    BOMBS_AWAY                  =  34,
    CRANE_GAME                  =  35,
    COIN_SHOWER_FLOWER          =  36,
    SLOT_CAR_DERBY              =  37,
    MARIO_BANDSTAND             =  38,
    DESERT_DASH                 =  39,
    SHY_GUY_SAYS                =  40,
    LIMBO_DANCE                 =  41,
    BOMBSKETBALL                =  42,
    CAST_AWAYS                  =  43,
    KEY_PA_WAY                  =  44,
    RUNNING_OF_THE_BULB         =  45,
    HOT_ROPE_JUMP               =  46,
    HANDCAR_HAVOC               =  47,
    DEEP_SEA_DIVERS             =  48,
    PIRANHAS_PURSUIT            =  49,
    TUG_O_WAR                   =  50,
    PADDLE_BATTLE               =  51,
    BUMPER_BALL_MAZE            =  52,
    DKS_JUNGLE_ADVENTURE        =  54,
    PEACHS_BIRTHDAY_CAKE        =  55,
    YOSHIS_TROPICAL_ISLAND      =  56,
    WARIOS_BATTLE_CANYON        =  57,
    LUIGIS_ENGINE_ROOM          =  58,
    MARIOS_RAINBOW_CASTLE       =  59,
    BOWSERS_MAGMA_MOUNTAIN      =  60,
    ETERNAL_STAR                =  61,
    LAST_FIVE_TURNS             =  63,
    FINAL_RESULTS_2             =  64,
    BOARD_WINNER                =  65,
    FINISH_BOARD                =  66,
    FINISH_BOARD_NO_STARS       =  67, // Instead of FINISH_BOARD when nobody has a Star
    TOAD                        =  68,
    CALLED_BOWSER               =  69, // "You called, so I have come": Bowser takes 20 Coins
    BOWSER                      =  70,
    PATH_TOLL                   =  71, // 10 Coins to go down a path
    BOWSER_VISIT_DK             =  72,
    BOWSER_VISIT_PEACH          =  73,
    GOOMBA_PEACH                =  74,
    FLOWER_LOTTERY_PEACH        =  75,
    PIRANHA_PLANT_PEACH         =  76,
    THWOMP_TOLL_YOSHI           =  77,
    TOAD_BOWSER_SWAP_YOSHI      =  78, // Bowser and Toad swap places
    BOWSER_VISIT_YOSHI          =  79,
    LOAD_CANNON_WARIO           =  80, // Loading the cannon
    BOB_OMB                     =  81,
    SHY_GUY                     =  82,
    BOWSER_VISIT_WARIO          =  83,
    BOWSER_VISIT_LUIGI          =  84,
    DOORS_LUIGI                 =  85,
    TOAD_BOWSER_SWAP_MARIO      =  86, // Bowser and Toad swap places
    BOWSER_VISIT_MARIO          =  87,
    BOWSER_VISIT_MAGMA_MOUNTAIN_2 =  89, // The decomp names this one Bowser's visit too
    SHORTCUT_MAGMA_MOUNTAIN     =  90,
    BOWSER_VISIT_MAGMA_MOUNTAIN =  91,
    HAPPENING_ETERNAL_STAR      =  92,
    BOWSER_VISIT_ETERNAL_STAR   =  93,
    STAR_ETERNAL_STAR           =  94,
    KOOPA                       =  95,
    SPECIAL_BONUS               =  96, // "You get a special bonus": 20 Coins
    OPENING                     =  97,
    START_BOARD                 =  98,
    STAFF_CREDITS               =  99,
    FINAL_RESULTS               = 100,
    BOO                         = 101,
    LOGOS                       = 102,
    LOGOS_2                     = 103,
    SAVE_DATA_CORRUPTED         = 104,
    MUSHROOM_VILLAGE            = 105,
    GAME_SETUP                  = 106,
    MINI_GAME_HOUSE             = 107,
    MUSHROOM_SHOP               = 108,
    MUSHROOM_BANK               = 109,
    OPTIONS_HOUSE               = 110,
    MINI_GAME_RULES             = 111,
    TESTING_ROOM                = 112,
    MINI_GAME_ISLAND            = 113,
    MINI_GAME_ISLAND_2          = 114,
    MINI_GAME_ISLAND_FINISH     = 119,
    MINI_GAME_ISLAND_START      = 120,
    DEBUG_RANDOM_PLAY           = 122,
    MINI_GAME_STADIUM_GAME_RESULTS = 123,
    MINI_GAME_RESULTS           = 124,
    MINI_GAME_ISLAND_MISS       = 125, // Losing a Mini-Game Island game
    DEBUG_SEQUENTIAL_PLAY       = 126,
    MINI_GAME_STADIUM_START     = 127,
    MINI_GAME_STADIUM_RESULTS   = 128,
    TITLE_SCREEN                = 129,
    MINI_GAME_STADIUM_START_2   = 130,
    DEBUG_MINI_GAME_MENU        = 131
}
