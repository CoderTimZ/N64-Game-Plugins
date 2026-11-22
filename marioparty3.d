module me.timz.n64.marioparty3;

import me.timz.n64.marioparty;
import me.timz.n64.plugin;
import core.time;
import std.algorithm;
import std.random;
import std.range;
import std.conv;
import std.traits;
import std.stdio;
import std.string;
import std.file;
import std.json;
import std.container.array;
import vibe.vibe;

immutable DEFAULT_BATTLE_DIST = [0.7, 0.3, 0.0, 0.0];

class Config : MarioPartyConfig {
    bool alwaysDuel = false;
    bool lastPlaceDoubleRoll = false;
    bool teamControl = false;
    bool teamMiniGames = false;
    bool teamScores = false;
    int[Character] teams;
    bool randomBonus = false;
    string[BonusType] bonuses;
    bool enhancedTaunts = false;
    bool preventRepeatMiniGames = false;
    bool randomChanceOrder = false;
    bool itemsOnFinalTurn = false;
    float[Space.Type] standardSpaceRatio;
    float luckySpaceRatio = 0.0;
    float luckySpaceItemChance = 0.333;
    MiniGame[] blockedMiniGames;
    bool doubleCoinMiniGames = false;
    bool mpiqPermadeath = false;
    bool finalResultsDoNotProceed = false;
    bool improveLastFiveTurnsBonus = false;
    bool singleUseBattleSpaces = false;
    bool unlockEverything = false;
    int revealHiddenBlocksOnRemainingTurns = 0;
    float mapScrollSpeedMultiplier = 1.0;
    bool increaseItemGameVariety = false;
    bool increaseItemShopVariety = false;
    float toadShopChance = -1.0;
    int replaceWackyWatchBeforeRemainingTurns = 50;
    bool autoStartNextBoard = false;
    bool balanceSuperHardCPU = false;
    bool chanceSwapInsteadOfTransfer = false;
    ChancePrize[ChancePrize] chancePrizeReplace;
    bool bingoPlayerNames = false;
    double[] battleCoinDistribution = DEFAULT_BATTLE_DIST;
    bool superstarsMiniGames = false;
    SuperstarsMiniGame[] blockedSuperstarsMiniGames;

    this() {
        bonuses = [
            BonusType.MINI_GAME: "Mini-Game",
            BonusType.COIN:      "Coin",
            BonusType.HAPPENING: "Happening",
            BonusType.RED:       "Unlucky",
            BonusType.BLUE:      "Blue",
            BonusType.CHANCE:    "Chance",
            BonusType.BOWSER:    "Bowser",
            BonusType.BATTLE:    "Battle",
            BonusType.ITEM:      "Item",
            BonusType.BANK:      "Banking",
            BonusType.GAME_GUY:  "Gambling",
            BonusType.LUCKY:     "Lucky"
        ];

        teams = [
            Character.MARIO:   2,
            Character.LUIGI:   2,
            Character.PEACH:   1,
            Character.YOSHI:   1,
            Character.WARIO:   1,
            Character.DK:      1,
            Character.WALUIGI: 1,
            Character.DAISY:   1
        ];
    }
}

class PlayerState {
    int luckySpaceCount = 0;
}

class State : MarioPartyState!PlayerState {
    ShuffleStream!MiniGame[MiniGameType] miniGameQueue;
    ShuffleStream!SuperstarsMiniGame[MiniGameType] superstarsMiniGameQueue;
    CustomSpace[] spaces;
    uint luckySpaceTexturePtr;
    uint goldSpaceTexturePtr;
    string[] boardNames;
}

union Memory {
    ubyte[0x800000] ram;
    mixin Field!(0x80009A1C, Instruction, "storeButtonPress");
    mixin Field!(0x8000B198, Instruction, "randomByteRoutine");
    mixin Field!(0x8004ACE0, Instruction, "playSFX");
    mixin Field!(0x80097650, uint, "randomState");
    mixin Field!(0x800ABF8A, Arr!(ubyte, 4), "controllerPresent");
    mixin Field!(0x800CC378, Arr!(short, 4), "finalPlayerRankOrder");
    mixin Field!(0x800CC4E4, ushort, "itemHiddenBlock");
    mixin Field!(0x800CC698, ushort, "battleCoinTotal");
    mixin Field!(0x800CD059, ubyte, "currentBoard");
    mixin Field!(0x800CD05A, ubyte, "totalTurns");
    mixin Field!(0x800CD05B, ubyte, "currentTurn");
    mixin Field!(0x800CD067, ubyte, "currentPlayerIndex");
    mixin Field!(0x800CD069, ubyte, "currentSpaceIndex");
    mixin Field!(0x800CD06C, MessageSpeed, "messageSpeed");
    mixin Field!(0x800CDA7C, Arr!(ushort, 4), "buttons");
    mixin Field!(0x800CDBD2, Arr!(PlayerExtra, 4), "playerExtras");
    mixin Field!(0x800CE1C4, ushort, "coinHiddenBlock");
    mixin Field!(0x800CE200, Scene, "currentScene");
    mixin Field!(0x800D1108, Arr!(PlayerData, 4), "players");
    mixin Field!(0x800D124E, ushort, "starHiddenBlock");
    mixin Field!(0x800DFE88, Instruction, "chooseGameRoutine");
    mixin Field!(0x800EB094, Instruction, "spacesLoaded");
    mixin Field!(0x800F52C4, Instruction, "determineTeams");
    mixin Field!(0x800FAB98, Instruction, "duelRoutine");
    mixin Field!(0x800FB624, Instruction, "battleRoutine");
    mixin Field!(0x800FC3C8, Instruction, "battleRoutineComplete");
    mixin Field!(0x800FE29C, Instruction, "blueOrRedSpaceCoins");
    mixin Field!(0x80101780, uint, "chancePlayer1");
    mixin Field!(0x80101784, uint, "chancePlayer2");
    mixin Field!(0x80101DE8, Arr!(ubyte, 27), "gamePhaseTable");
    mixin Field!(0x80102C08, Arr!(MiniGame, 5), "miniGameRoulette");
    mixin Field!(0x80102C58, Ptr!Instruction, "booRoutinePtr");
    mixin Field!(0x80105210, ushort, "spaceCount");
    mixin Field!(0x80105214, Ptr!Space, "spaces");
    mixin Field!(0x80105220, Arr!(Address, 16), "spaceTypeTexturePointers");
    mixin Field!(0x8010570E, ubyte, "numberOfRolls");
    mixin Field!(0x801057E0, Arr!(PlayerPanel, 4), "playerPanels");
    mixin Field!(0x80108470, Instruction, "loadBonusStat1a");
    mixin Field!(0x801084B4, Instruction, "loadBonusStat1b");
    mixin Field!(0x80108898, Instruction, "loadBonusStat2a");
    mixin Field!(0x801088DC, Instruction, "loadBonusStat2b");
    mixin Field!(0x80108920, Arr!(float, 32), "battleCoinDistributionTable");
    mixin Field!(0x80108CC0, Instruction, "loadBonusStat3a");
    mixin Field!(0x80108D04, Instruction, "loadBonusStat3b");
    mixin Field!(0x80108F70, uint, "battlePityCoins");
    mixin Field!(0x80109568, BowserEventType, "bowserEventType");
    mixin Field!(0x8010C9E8, Arr!(uint, 4), "mpiqNoJump");
    mixin Field!(0x800A11D0, Arr!(short, 5), "itemMiniGameItems");
    mixin Field!(0x8010D40C, Arr!(Item, 5), "itemMiniGameHelpScreenItems");
    mixin Field!(0x8010FE64, Arr!(ubyte, 3), "chanceOrder");
    mixin Field!(0x801100DD, Character, "chanceCharacter1");
    mixin Field!(0x801100DE, Character, "chanceCharacter2");
    mixin Field!(0x801100DF, ChancePrize, "chancePrize");
}

union PlayerData {
    ubyte[0x38] _data;
    mixin Field!(0x01, ubyte, "cpuDifficulty");
    mixin Field!(0x02, ubyte, "controller");
    mixin Field!(0x03, Character, "character");
    mixin Field!(0x04, ubyte, "flags");
    mixin Field!(0x06, ushort, "gameCoinsExtra");
    mixin Field!(0x06, ushort, "battleCoins");
    mixin Field!(0x08, ushort, "gameCoinsMain");
    mixin Field!(0x08, ushort, "battleRank");
    mixin Field!(0x0A, ushort, "coins");
    mixin Field!(0x0E, ubyte, "stars");
    mixin Field!(0x17, ubyte, "directionFlags");
    mixin Field!(0x18, Arr!(Item, 3), "items");
    mixin Field!(0x1C, PanelColor, "color");
    mixin Field!(0x28, ushort, "miniGameCoins");
    mixin Field!(0x2A, ushort, "maxCoins");
    mixin Field!(0x2C, ubyte, "happeningSpaces");
    mixin Field!(0x2D, ubyte, "redSpaces");
    mixin Field!(0x2E, ubyte, "blueSpaces");
    mixin Field!(0x2F, ubyte, "chanceSpaces");
    mixin Field!(0x30, ubyte, "bowserSpaces");
    mixin Field!(0x31, ubyte, "battleSpaces");
    mixin Field!(0x32, ubyte, "itemSpaces");
    mixin Field!(0x33, ubyte, "bankSpaces");
    mixin Field!(0x34, ubyte, "gameGuySpaces");
}

union PlayerExtra {
    ubyte[0x4C] _data;
    mixin Field!(0x00, ubyte, "diceRoll");
    mixin Field!(0x01, ubyte, "diceRoll2");
    mixin Field!(0x02, ubyte, "diceRoll3");
    mixin Field!(0x03, ubyte, "diceTotal");
}

union Space {
    static enum Type : byte {
        START     = 0x00,
        BLUE      = 0x01,
        RED       = 0x02,
        INVISIBLE = 0x03,
        HAPPENING = 0x04,
        CHANCE    = 0x05,
        ITEM      = 0x06,
        BANK      = 0x07,
        INVIS_2   = 0x08,
        BATTLE    = 0x09,
        UNKNOWN_1 = 0x0A,
        UNKNOWN_2 = 0x0B,
        BOWSER    = 0x0C,
        ARROW     = 0x0D,
        STAR      = 0x0E,
        GAME_GUY  = 0x0F
    }

    ubyte[0x24] _data;
    mixin Field!(0x01, Type, "type");

    bool isSolid() {
        switch (type) {
            case Type.BLUE:
            case Type.RED:
            case Type.HAPPENING:
            case Type.CHANCE:
            case Type.ITEM:
            case Type.BANK:
            case Type.BATTLE:
            case Type.BOWSER:
            case Type.GAME_GUY:
                return true;
            default:
                return false;
        }
    }
}

enum CustomSpace : byte {
    DEFAULT   =   -2,
    LOCKED    =   -1,
    START     = 0x00,
    BLUE      = 0x01,
    RED       = 0x02,
    INVISIBLE = 0x03,
    HAPPENING = 0x04,
    CHANCE    = 0x05,
    ITEM      = 0x06,
    BANK      = 0x07,
    INVIS_2   = 0x08,
    BATTLE    = 0x09,
    UNKNOWN_1 = 0x0A,
    UNKNOWN_2 = 0x0B,
    BOWSER    = 0x0C,
    ARROW     = 0x0D,
    STAR      = 0x0E,
    GAME_GUY  = 0x0F,
    LUCKY     = 0x10,
    HIDDEN    = 0x11
}

union PlayerPanel {
    ubyte[0x6C] _data;
    mixin Field!(0x04, PanelColor, "color");
}

// Text color of each bonus star's name
string getColor(BonusType type) {
    final switch (type) {
        case BonusType.MINI_GAME: return "BLUE";
        case BonusType.COIN:      return "YELLOW";
        case BonusType.HAPPENING: return "GREEN";
        case BonusType.RED:       return "RED";
        case BonusType.BLUE:      return "BLUE";
        case BonusType.CHANCE:    return "GREEN";
        case BonusType.BOWSER:    return "RED";
        case BonusType.BATTLE:    return "GREEN";
        case BonusType.ITEM:      return "GREEN";
        case BonusType.BANK:      return "GREEN";
        case BonusType.GAME_GUY:  return "GREEN";
        case BonusType.LUCKY:     return "BLUE";
    }
}

// What a player did to win each bonus star (completes "This award goes to the person who ...")
string getDescription(BonusType type) {
    final switch (type) {
        case BonusType.MINI_GAME: return "has won the most coins in Mini-Games";
        case BonusType.COIN:      return "had the most coins at any one time during the game";
        case BonusType.HAPPENING: return "landed on the most <GREEN><OUTLINE>? Spaces<NO_OUTLINE><RESET>";
        case BonusType.RED:       return "landed on the most <RED><OUTLINE>Red Spaces<NO_OUTLINE><RESET>";
        case BonusType.BLUE:      return "landed on the most <BLUE><OUTLINE>Blue Spaces<NO_OUTLINE><RESET>";
        case BonusType.CHANCE:    return "landed on the most <GREEN><OUTLINE>! Spaces<NO_OUTLINE><RESET>";
        case BonusType.BOWSER:    return "landed on the most <RED><OUTLINE>Bowser Spaces<NO_OUTLINE><RESET>";
        case BonusType.BATTLE:    return "landed on the most <GREEN><OUTLINE>Battle Spaces<NO_OUTLINE><RESET>";
        case BonusType.ITEM:      return "landed on the most <GREEN><OUTLINE>Item Spaces<NO_OUTLINE><RESET>";
        case BonusType.BANK:      return "landed on the most <GREEN><OUTLINE>Bank Spaces<NO_OUTLINE><RESET>";
        case BonusType.GAME_GUY:  return "landed on the most <GREEN><OUTLINE>Game Guy Spaces<NO_OUTLINE><RESET>";
        case BonusType.LUCKY:     return "landed on the most <BLUE><OUTLINE>Lucky Spaces<NO_OUTLINE><RESET>";
    }
}

void showPlayerMessage(string message, byte character = -1) {
    message = formatText(message ~ "<END><NUL>");
    gpr.sp -= cast(uint)(message.length + 0b111) & ~0b111;
    message.each!((i, c) { Ptr!char(gpr.sp)[i] = c; });
    gpr.sp -= 32;
    (gpr.sp + 16).val!uint = 0;
    (gpr.sp + 20).val!uint = 0;
    (gpr.sp + 24).val!uint = 0;
    0x800EC8EC.jal(character, gpr.sp + 32, 0, 0, { // ShowPlayerMessage
        0x800EC9DC.jal({
            0x800EC6C8.jal({                       // CloseMessage
                0x800EC6EC.jal({
                    gpr.sp += 32 + (cast(uint)(message.length + 0b111) & ~0b111);
                });
            });
        });
    });
}

void showGlobalMessage(string message, byte character = -1, bool waitForInput = false, void delegate() done = null) {
    message = formatText(message ~ "<END><NUL>");
    gpr.sp -= cast(uint)(message.length + 0b111) & ~0b111;
    message.each!((i, c) { Ptr!char(gpr.sp)[i] = c; });
    gpr.sp -= 32;
    (gpr.sp + 16).val!uint = 0;
    (gpr.sp + 20).val!uint = 0;
    (gpr.sp + 24).val!uint = 0;
    auto close = {
        0x800EC6C8.jal({                           // MBDlgWinClose
            0x800EC6EC.jal({                       // MBDlgWinKill
                gpr.sp += 32 + (cast(uint)(message.length + 0b111) & ~0b111);
                if (done) done();
            });
        });
    };
    0x800EC92C.jal(character, gpr.sp + 32, 0, 0, { // ShowGlobalMessage
        if (waitForInput) {
            0x800ECA38.jal(close);                 // Wait for any player to press A
        } else {
            close();
        }
    });
}

// Colors the plugin adds to windows (RGBA5551): the character name colors, indexed by Character. Mario, Peach, Yoshi
// and Wario use the text palette's own red, magenta, green and yellow; the others get colors of their own.
immutable ushort[8] TEXT_COLORS = [
    rgba5551(255,  66,  66),  // Mario: red
    rgba5551( 24, 160,  40),  // Luigi: dark green
    rgba5551(255,   0, 255),  // Peach: magenta
    rgba5551(  0, 255,   0),  // Yoshi: green
    rgba5551(255, 255,   0),  // Wario: yellow
    rgba5551(176,  96,  32),  // DK: brown
    rgba5551(160,  64, 232),  // Waluigi: purple
    rgba5551(255, 144,   0),  // Daisy: orange
];

// Text that colors what follows in one of TEXT_COLORS. It's <SKIP_NEXT> and the color's digit, which the window skips.
// Setting a window's message turns it into a color code for that window (see colorize()); in an argument, the whole
// argument is shown in that color instead (see colorArgs()).
string textColor(int n) {
    return "<SKIP_NEXT>" ~ cast(char)('0' + n);
}

ushort rgba5551(ubyte r, ubyte g, ubyte b) {
    return cast(ushort)((r >> 3) << 11 | (g >> 3) << 6 | (b >> 3) << 1 | 1);
}

// Text that colors what follows in a character's color
string characterColor(Character c) {
    return textColor(c);
}

// The plugin's colors in a window. Text has only 4 bits per pixel, so a window shows only the 16 colors of its
// palette (at the start of its struct): color code n is entry n, and entry n + 7 its darker edge. Codes 0x02-0x07 are
// the ones text can change to, so a color the palette doesn't have replaces one of those that the text doesn't use.
//
// Each message gets its colors anew. Setting a window's message first undoes the plugin's colors from its previous
// one, since windows are reused for other text (like the mini-game help's pages) without being created again. Then the
// names in the message, and in its arguments (<1>-<5>), get their colors (see colorize() and colorArgs()).
struct WindowColors {
    bool[8] used;       // Color codes the window's current text uses
    bool[16] changed;   // Palette entries the plugin changed
    ushort[16] before;  // Their values before that
    ushort[16] value;   // And after (to tell if the game has since replaced them)
}

class MarioParty3 : MarioParty!(Config, State, Memory) {
    ushort messageId;            // Message being loaded by func_800364DC
    string messageReplacement;   // Text (game bytes) to load instead, from replaceMessage()
    short messageWindow = -1;    // Window whose message is being set, or -1
    char nameColor;              // The game's color for a name given as text (see nameMessageId()), or 0
    WindowColors[short] windowColors;
    int lastFiveTurnsBonus = 20;

    // Superstars mini-game mode
    enum SuperstarsPhase { NONE, SELECTED, WAITING, READY }
    SuperstarsPhase ssPhase = SuperstarsPhase.NONE;
    SuperstarsMiniGame[MiniGame] ssRoulette; // Placeholder MP3 mini-game -> Superstars mini-game shown in its roulette slot
    SuperstarsMiniGame ssGame;               // Selected Superstars mini-game
    MiniGameType ssType;             // MP3 roulette category of the selected mini-game
    uint[] ssDuelists;               // Player indices taking part in a duel
    SuperstarsResults* ssResults;    // Results entered on the Bingo page
    Address ssNameBuffer;            // Board temp heap buffer holding the roulette names

    this(string name, string hash) {
        super(name, hash);

        // Keep the State on the permanent heap (perm_heap_addr, HuMemHeapInitPerm, HuMemMemoryAllocPerm, HuMemMemoryFreePerm, HuPrcVSleep)
        permanentHeap = PermanentHeap(0x800B1A10, 0x80035840, 0x80035864, 0x80035888, 0x8004F074);
        tempHeap = TempHeap(0x80035934, 0x80035958); // HuMemMemoryAllocTemp, HuMemMemoryFreeTemp
    }

    override void loadConfig() {
        super.loadConfig();

        if (config.battleCoinDistribution.length != 4) {
            while (config.battleCoinDistribution.length < 4) {
                config.battleCoinDistribution ~= 0.0;
            }
            config.battleCoinDistribution = config.battleCoinDistribution[0..4];
        }

        if (fixRoundingError(config.battleCoinDistribution.sum) > 1.0) {
            config.battleCoinDistribution = DEFAULT_BATTLE_DIST.dup;
            throw new Exception("battleCoinDistribution.sum > 1.0");
        }
    }

    override bool lockTeamScores() const {
        if (data.currentScene == Scene.CHANCE_TIME) {
            if (data.chancePlayer1 < players.length && data.chancePlayer2 < players.length) {
                return team(players[data.chancePlayer1])
                    == team(players[data.chancePlayer2]);
            }
        }
        return false;
    }

    override bool disableTeamScores() const {
        if (data.currentScene == Scene.BOWSER_EVENT) {
            return data.bowserEventType == BowserEventType.COIN_POTLUCK
                || data.bowserEventType == BowserEventType.REVOLUTION;
        }
        return false;
    }

    override bool disableTeamControl() const {
        return data.currentScene == Scene.GAME_SETUP
            || data.currentScene == Scene.FINAL_RESULTS;
    }

    alias isBoardScene = typeof(super).isBoardScene;
    alias isScoreScene = typeof(super).isScoreScene;

    override bool isBoardScene(Scene scene) const {
        switch (scene) {
            case Scene.CHILLY_WATERS_BOARD:
            case Scene.DEEP_BLOOBER_SEA_BOARD:
            case Scene.SPINY_DESERT_BOARD:
            case Scene.WOODY_WOODS_BOARD:
            case Scene.CREEPY_CAVERN_BOARD:
            case Scene.WALUIGIS_ISLAND_BOARD:
            case Scene.GATE_GUY_BOARD:
            case Scene.ARROWHEAD_BOARD:
            case Scene.PIPESQUEAK_BOARD:
            case Scene.BLOWHARD_BOARD:
            case Scene.MR_MOVER_BOARD:
            case Scene.BACKTRACK_BOARD:
                return true;
            default:
                return false;
        }
    }

    // Party mode boards, which run the shared board code (mini-game roulette, messages, etc.) at 0x800D6B70+.
    // Duel mode boards load a different overlay there.
    bool isPartyBoardScene() const {
        return isBattleRoyaleBoardScene(data.currentScene);
    }

    bool isBattleRoyaleBoardScene(Scene scene) const {
        switch (scene) {
            case Scene.CHILLY_WATERS_BOARD:
            case Scene.DEEP_BLOOBER_SEA_BOARD:
            case Scene.SPINY_DESERT_BOARD:
            case Scene.WOODY_WOODS_BOARD:
            case Scene.CREEPY_CAVERN_BOARD:
            case Scene.WALUIGIS_ISLAND_BOARD:
                return true;
            default:
                return false;
        }
    }

    override bool isMiniGameScene(Scene scene) const {
        return Scene.HAND_LINE_AND_SINKER <= scene && scene <= Scene.SWING_N_SWIPE;
    }

    override bool isScoreScene(Scene scene) const {
        switch (scene) {
            case Scene.FINISH_BOARD:
            case Scene.BOWSER_EVENT:
            case Scene.LAST_FIVE_TURNS:
            case Scene.START_BOARD:
            case Scene.CHANCE_TIME:
            case Scene.MINI_GAME_RESULTS:
            case Scene.GAMBLE_GAME_RESULTS:
            case Scene.BATTLE_GAME_RESULTS:
                return true;
            default:
                return isBoardScene(scene);
        }
    }

    GamePhase getGamePhase() {
        auto i = clamp(cast(int)data.totalTurns, 10, 50) / 5 - 2;

        if (data.currentTurn < data.gamePhaseTable[3 * i]) {
            return GamePhase.EARLY;
        } else if (data.currentTurn < data.gamePhaseTable[3 * i + 1]) {
            return GamePhase.MID;
        } else {
            return GamePhase.END;
        }
    }

    string getCurrentBoardName() {
        if (!isBoardScene()) return null;
        int index;
        if (data.currentScene <= Scene.WALUIGIS_ISLAND_BOARD) {
            index = data.currentScene - Scene.CHILLY_WATERS_BOARD;
        } else {
            index = data.currentScene - Scene.GATE_GUY_BOARD + 6;
        }
        if (index < state.boardNames.length) {
            return state.boardNames[index];
        } else {
            return "N/A";
        }
    }

    override uint getBonusStat(Player player, BonusType type) {
        final switch (type) {
            case BonusType.MINI_GAME: return player.data.miniGameCoins;
            case BonusType.COIN:      return player.data.maxCoins;
            case BonusType.HAPPENING: return player.data.happeningSpaces;
            case BonusType.RED:       return player.data.redSpaces;
            case BonusType.BLUE:      return player.data.blueSpaces;
            case BonusType.CHANCE:    return player.data.chanceSpaces;
            case BonusType.BOWSER:    return player.data.bowserSpaces;
            case BonusType.BATTLE:    return player.data.battleSpaces;
            case BonusType.ITEM:      return player.data.itemSpaces;
            case BonusType.BANK:      return player.data.bankSpaces;
            case BonusType.GAME_GUY:  return player.data.gameGuySpaces;
            case BonusType.LUCKY:     return player.state.luckySpaceCount;
        }
    }

    override void onStart() {
        super.onStart();

        /*
        bool[uint] seen;
        0x800843F0.onExec({
            if (gpr.a0 !in seen) {
                info((cast(uint)gpr.a0).to!string(16), " ", (cast(uint)gpr.a1).to!string(16), " ", (cast(uint)gpr.a2).to!string(16), " ", (cast(uint)gpr.a3).to!string(16));
                seen[gpr.a0] = true;
            }

            if (gpr.a0 == 0x801D73D0) return;

            gpr.a0 = gpr.a1 = 0x80240340;
        });
        */

        data.currentScene.onWrite((ref Scene scene) {
            if (scene != Scene.START_BOARD) return;
            state.currentPlayerTurn = 0;
            saveState();
        });

        data.currentScene.onWrite((ref Scene scene) {
            if (scene != Scene.CASTLE_GROUNDS) return;
            state.boardNames.length = 0;
            saveState();
        });

        0x800364A0.onExec({
            if (data.currentScene != Scene.CASTLE_GROUNDS) return;
            if (!state.boardNames.empty) return;
            auto result = searchMemory([0x0A4E6F74, 0x20626164, 0x20617420, 0x616C6C85, 0x19FF0000]); // "Not bad at all";
            if (result.empty) return;
            auto c = Ptr!char(result.front + 20);
            for (auto i = 0; i < 12; i++) {
                string boardName;
                while (*c <= 0x1F) c++;
                while (*c >= 0x20) boardName ~= *(c++);
                state.boardNames ~= unformatText(boardName);
            }
            saveState();
        });

        // Every message is loaded by ID through func_800364DC(id), id = (directory << 8) | index. Window message
        // arguments (<1>-<5>) can be message IDs too, which it also loads. It copies the message into a newly
        // allocated buffer, so replacing text here needs no memory management: the game allocates the new length
        // and frees the buffer itself.
        0x800364DC.onExec({ messageId = cast(ushort)gpr.a0; });
        0x80036574.onExec({ // s0 = message (length, then text), s1 = length; next, it allocates s1 bytes
            string text;
            auto c = Ptr!char(gpr.s0 + 2);
            foreach (i; 0..cast(short)gpr.s1) text ~= c[i];
            messageReplacement = replaceMessage(messageId, text);
            if (messageWindow >= 0) {
                auto colored = colorize(messageWindow, messageReplacement is null ? text : messageReplacement);
                if (colored != text) messageReplacement = colored;
            }
            if (messageReplacement !is null) gpr.s1 = cast(uint)messageReplacement.length;
        });

        // The turn counter (see maintainTurnCounter())
        0x8004F074.onExecDone({ maintainTurnCounter(); }); // HuPrcVSleep, after "addiu sp, sp, ..."
        0x8005F364.onExec({ // func_8005F364 (close window, a0 = window)
            if (cast(short)gpr.a0 == turnCounterWindow) turnCounterWindow = -1;
        });
        data.currentScene.onWrite((ref Scene scene) { // The board's windows go away with it: forget the counter's
            if (scene != data.currentScene) {
                turnCounterWindow = -1;
                turnCounterCovered = 0;
                turnCounterLowered = 0;
            }
        });
        // Hidden while the pause menu is open (MBPauseCreate), and lowered below the up arrow while the scrolling map is
        // (MBMapScrollExec): they return once it's closed
        0x800F1EC8.onExec({
            if (!isPartyBoardScene()) return;
            turnCounterCovered++;
            gpr.ra.onExecOnce({ if (turnCounterCovered > 0) turnCounterCovered--; });
        });
        0x8010067C.onExec({
            if (!isPartyBoardScene()) return;
            turnCounterLowered++;
            gpr.ra.onExecOnce({ if (turnCounterLowered > 0) turnCounterLowered--; });
        });

        // Plugin colors in windows (textColor()): player names
        if (config.bingoPlayerNames) {
            // Window creation (func_8005AF84 area): the window has just copied the text palette (0x800A2174) to the
            // start of its struct, so it has none of the plugin's colors
            0x8005AF8C.onExec({
                windowColors.remove(cast(short)((gpr.s1 - windowAddress(0)) / WINDOW_SIZE));
            });
            // func_8005B43C (set window message, a0 = window, a1 = message ID or pointer). The previous message's
            // colors are undone, then the message's names get colors as it's loaded (colorize()), then its arguments'
            // (colorArgs()). Codes in the arguments are the game's, so they're kept.
            0x8005B43C.onExec({
                auto w = cast(short)gpr.a0;
                resetColors(w);
                foreach (n; 0..5) markUsed(w, argText(w, n));
                if (gpr.a1 >= 0x80000000) colorizeInPlace(w, gpr.a1); // Text of the plugin's own (showGlobalMessage)
                messageWindow = w;
                gpr.ra.onExecOnce({ // Back in the caller, where the game can be called
                    messageWindow = -1;
                    foreach (n; 0..5) colorArg(w, n);
                    copyTextPaletteIfChanged(w);
                });
            });
            // func_8006022C (measure a window message argument, a0 = message ID or pointer, a1 = argument), which sizes
            // the window: a name given as text is measured as the message it's replaced with (see 0x8005B6BC)
            0x8006022C.onExec({
                if (auto id = nameMessageId(gpr.a0)) gpr.a0 = id;
                gpr.ra.onExecOnce({ nameColor = 0; });
            });
            // func_8005B6BC (set window message argument, a0 = window, a1 = message ID or pointer, a2 = argument).
            // Arguments are usually set before the message, which colors them again, but some may come after it.
            0x8005B6BC.onExec({
                if (auto id = nameMessageId(gpr.a1)) gpr.a1 = id; // A name given as text: load it as a message
                auto w = cast(short)gpr.a0;
                auto n = cast(byte)gpr.a2;
                gpr.ra.onExecOnce({
                    nameColor = 0;
                    colorArg(w, n);
                    copyTextPaletteIfChanged(w);
                });
            });
        }
        0x800365BC.onExec({ // s2 = the copy (0 if it couldn't be allocated)
            if (messageReplacement is null) return;
            if (gpr.s2) foreach (i, c; messageReplacement) Ptr!char(gpr.s2)[i] = c;
            messageReplacement = null;
        });

        if (config.teamScores) {
            setUpTeamDuels(data.duelRoutine.addr);
            setUpTeamBattles(data.battleRoutine.addr);
        }

        if (config.alwaysDuel) {
            setUpAlwaysDuel(0x800FA854);
        }

        if (config.randomBonus) {
            setUpRandomBonus!"s2"([[data.loadBonusStat1a.addr, data.loadBonusStat1b.addr],
                                   [data.loadBonusStat2a.addr, data.loadBonusStat2b.addr],
                                   [data.loadBonusStat3a.addr, data.loadBonusStat3b.addr]], false);
            0x800EEA78.onExec({
                if (0x800EE9E0.val!uint != 0x0C03BB2C) return;
                gpr.v0 = 0; // Disable vanilla bonus stars for GetPlayerPlacementAtEndOfGame
            });
        }

        bool superstarsEnabled = config.superstarsMiniGames;
        if (superstarsEnabled && config.bingoURL.empty) {
            warning("superstarsMiniGames requires bingoURL to be set; Superstars mini-games are disabled");
            superstarsEnabled = false;
        }

        if (config.preventRepeatMiniGames || config.blockedMiniGames.length > 0 || superstarsEnabled) {
            data.currentScene.onWrite((ref Scene scene) {
                if (scene == Scene.START_BOARD) {
                    state.miniGameQueue.clear();
                    state.superstarsMiniGameQueue.clear();
                    saveState();
                }
            });
            // Populate mini-game roulette
            0x800DFE90.onExec({
                if (!isPartyBoardScene()) return;
                0x800DFED4.val!Instruction = NOP;
                0x800DFF40.val!Instruction = NOP;
                0x800DFF64.val!Instruction = NOP;
                0x800DFF78.val!Instruction = NOP;
                if (gpr.s0 == 0) {
                    auto type = (cast(MiniGame)gpr.v0).type;
                    auto count = (0x80100E18 + gpr.s2).val!ubyte;
                    ssRoulette.clear();
                    if (!superstarsEnabled || !populateSuperstarsRoulette(type, count)) {
                        auto games = [EnumMembers!MiniGame].filter!(g => g.type == type).array;
                        fillMiniGameRoulette(type, games, count, 0x800DF120);
                    }
                    saveState();
                }
                gpr.v0 = data.miniGameRoulette[gpr.s0];
            });
            // Prevent the mini-game roulette from jumping backward
            0x800DF3C0.onExec({ if (isPartyBoardScene()) gpr.v0 = 1; });
        }

        if (superstarsEnabled) {
            data.currentScene.onWrite((ref Scene scene) {
                if (scene == data.currentScene) return;
                if (scene == Scene.START_BOARD || scene == Scene.CASTLE_GROUNDS || scene == Scene.TITLE_SCREEN) {
                    resetSuperstars();
                }
            });

            // MBMgCallListCreate: Allocate a buffer on the board's temp heap for this roulette's names.
            // Allocating per roulette (instead of when the board loads) also works right after loading a save state.
            0x800DFBA8.onExecDone({
                if (!isPartyBoardScene()) return;
                allocateSuperstarsNameBuffer();

                // Make the duel roulette (category 5) 3 long, laid out like the other 3-long roulettes (category 1).
                // These tables are the board overlay's data, which is reloaded with the board.
                0x80100E1D.val!ubyte = 3;                           // Number of entries
                0x80100E89.val!ubyte = 0x80100E85.val!ubyte;        // Window Y
                0x80100E91.val!ubyte = 0x80100E8D.val!ubyte;        // Cursor Y
                0x801020C4.val!uint  = 0x801020B4.val!uint;         // Entry rectangles
            });

            // GWMgUnlockCheck: Show every roulette slot, even if the placeholder MP3 mini-game is still locked
            0x80035BD8.onExec({
                if (ssRoulette.empty || !isPartyBoardScene()) return;
                gpr.ra.onExecOnce({ gpr.v0 = 1; });
            });

            // func_8005B43C (set window message): Swap the MP3 mini-game name for the Superstars name
            0x8005B43C.onExec({
                if (ssRoulette.empty || !isPartyBoardScene() || !ssNameBuffer) return;
                if (gpr.a1 < 0x4700 || gpr.a1 >= 0x4748) return; // Mini-game name messages
                auto game = cast(MiniGame)(gpr.a1 - 0x4700 + 1);
                if (game !in ssRoulette) return;
                foreach (i; 0..data.miniGameRoulette.length) {
                    if (data.miniGameRoulette[i] == game) {
                        gpr.a1 = ssNameBuffer + cast(uint)(i * SUPERSTARS_NAME_SLOT_SIZE);
                        return;
                    }
                }
            });

            // func_800E11C0 (duel roulette): Remember who is dueling
            0x800E11C0.onExec({
                if (!isPartyBoardScene()) return;
                ssDuelists = [cast(uint)gpr.a0, cast(uint)gpr.a1];
            });

            // GWMgNoSet: The roulette has landed on a mini-game
            0x80035AA8.onExec({
                if (ssRoulette.empty || !isPartyBoardScene()) return;
                auto game = cast(MiniGame)cast(byte)gpr.a0;
                if (auto selected = game in ssRoulette) {
                    ssGame = *selected;
                    ssResults = null;
                    ssPhase = SuperstarsPhase.SELECTED;
                    info("Superstars mini-game: ", ssGame.fullName, " (", ssType, ")");
                    sendSuperstarsInfo();
                }
                ssRoulette.clear();
                ssNameBuffer = 0; // Only valid for this roulette
            });

            // MBVsSprKill: Called by the roulette process (regular, battle and duel) after the roulette closes.
            // Show the "play on Superstars" message from that process, which keeps the board waiting on it.
            // (It can't wait for the wipe to Tumble instead: the wipe is drawn over the message.)
            0x800F5644.onExecDone({
                if (ssPhase != SuperstarsPhase.SELECTED || !isPartyBoardScene()) return;
                showSuperstarsMessage();
            });

            // func_800EE2DC (message waits for any player): If every player is a CPU, the message advances itself.
            // While waiting for results, report the players as human to this function so it waits for A instead.
            players.each!((p) {
                p.data.flags.onRead((ref ubyte flags, Address pc) {
                    if (ssPhase != SuperstarsPhase.WAITING || !isPartyBoardScene()) return;
                    if (pc < 0x800EE2DC || pc >= 0x800EE614) return;
                    if (!players.all!(o => o.isCPU)) return;
                    flags &= ~0b1;
                });
            });

            // omOvlCallEx: Skip the rules screen and mini-game, going straight to the results
            0x80048128.onExec({
                if (gpr.a0 != Scene.MINI_GAME_RULES) return;
                if (ssPhase == SuperstarsPhase.NONE) return;

                if (ssPhase == SuperstarsPhase.READY && ssResults) {
                    auto next = applySuperstarsResults();
                    gpr.a0 = next;
                    if (isBoardScene(cast(Scene)next)) {
                        // Duels have no results screen: the board pays out the winner itself (MBKettouResultExec).
                        // Go straight back to the board, as MBOvlCallExec does once a mini-game returns.
                        gpr.a1 = 2;
                        gpr.a2 = 0x192;
                        0x800D4196.val!short = 0; // D_800D4190_main.stat
                    }
                } else {
                    warning("No Superstars results were entered for ", ssGame.fullName, "; playing the MP3 mini-game instead");
                }

                resetSuperstars();
            });
        }

        if (config.enhancedTaunts) {
            data.storeButtonPress.addr.onExecDone({
                if (gpr.v0 == 0 || data.totalTurns == 0) return;

                SFX sfx;
                switch (data.buttons[gpr.t0]) {
                    case Button.L:   sfx = SFX.TAUNT;               break;
                    case Button.D_R: sfx = SFX.BEING_CHOSEN;        break;
                    case Button.D_L: sfx = SFX.GETTING_AN_ITEM;     break;
                    case Button.D_D: sfx = SFX.WINNING_A_STAR;      break;
                    case Button.D_U: sfx = SFX.WINNING_A_MINI_GAME; break;
                    case Button.C_R: sfx = SFX.DESPAIR_1;           break;
                    case Button.C_L: sfx = SFX.DESPAIR_2;           break;
                    case Button.C_D: sfx = SFX.LOSING_A_MINI_GAME;  break;
                    case Button.C_U: sfx = SFX.LOSING_A_MINI_GAME;  break;
                    default:                                        return;
                }

                auto p = players.find!(p => p.data.controller == gpr.t0);
                if (p.empty || p.front.isCPU) return;

                data.playSFX.addr.jal(sfx, p.front.index);
            });
        }

        if (config.randomChanceOrder) {
            0x80105B58.onExec({
                if (data.currentScene != Scene.CHANCE_TIME) return;
                [0, 1, 2].randomShuffle(random).each!((i, j) => data.chanceOrder[i] = cast(ubyte)j);
            });
        }

        if (config.itemsOnFinalTurn) {
            data.currentTurn.onRead((ref ubyte turn, Address pc) {
                if (!isBoardScene()) return;
                if (turn != data.totalTurns) return;
                if (pc == 0x800FE420                       || // Item Space
                   (pc + 32).val!Instruction == 0x0C036783 || // Toad Shop
                   (pc + 32).val!Instruction == 0x0C03B164) { // Item Shop
                    turn--;
                }
            });
        }

        if (config.luckySpaceRatio > 0 || config.revealHiddenBlocksOnRemainingTurns > 0 || config.standardSpaceRatio.values.any!(v => v > 0.0)) {
            bool lumasPlaygroundHiddenIndex(ushort index) {
                if (getCurrentBoardName() != "Luma's Playground") return false;
                
                return index == 0xFFFF || index == 98 || index == 103 || index == 107;
            }

            bool validHiddenIndex(string exclude = null)(ushort index) {
                if (lumasPlaygroundHiddenIndex(index)) return true;
                if (index >= data.spaceCount) return false;
                if (data.spaces[index].type != Space.Type.BLUE) return false;
                if (index < state.spaces.length && state.spaces[index] == CustomSpace.LUCKY) return false;
                static if (exclude != "item") {
                    if (index == data.itemHiddenBlock) return false;
                }
                static if (exclude != "coin") {
                    if (index == data.coinHiddenBlock) return false;
                }
                static if (exclude != "star") {
                    if (index == data.starHiddenBlock) return false;
                }
                return true;
            }

            ushort randomHiddenIndex() {
                auto selection = iota(data.spaceCount).filter!(i => validHiddenIndex(i))
                                                      .filter!(i => !lumasPlaygroundHiddenIndex(i))
                                                      .array;
                return selection.empty ? cast(ushort)0xFFFF : selection.choice(random);
            }
            
            0x8003592C.onExecDone({ // Finish making temp heap
                if (!isBoardScene()) return;

                mallocTemp(LUCKY_SPACE_TEXTURE.length + 0x10, (ptr) {
                    LUCKY_SPACE_TEXTURE.each!((i, b) { Ptr!ubyte(ptr + 0x10)[i] = b; });
                    state.luckySpaceTexturePtr = ptr;

                    if (config.revealHiddenBlocksOnRemainingTurns <= 0) {
                        saveState();
                        return;
                    }

                    mallocTemp(GOLD_SPACE_TEXTURE.length + 0x10, (ptr) {
                        GOLD_SPACE_TEXTURE.each!((i, b) { Ptr!ubyte(ptr + 0x10)[i] = b; });
                        state.goldSpaceTexturePtr = ptr;

                        saveState();
                    });
                });
            });
            0x800EA4F0.onExec({ // Force high res space textures on full map view
                if (!isBoardScene()) return;
                gpr.a0 = false;
            });
            auto selectSpaceTexture = {
                if (!isBoardScene()) return;
                switch (gpr.s3) {
                    case CustomSpace.LUCKY:  gpr.v0 = state.luckySpaceTexturePtr; break;
                    case CustomSpace.HIDDEN: gpr.v0 = state.goldSpaceTexturePtr;  break;
                    default:                                                break;
                }
            };
            0x800EA838.onExecDone(selectSpaceTexture);
            0x800EA8AC.onExecDone(selectSpaceTexture);
            0x800EA970.onExecDone(selectSpaceTexture);
            0x800EAA3C.onExecDone(selectSpaceTexture);
            0x800EAC70.onExecDone({
                if (!isBoardScene()) return;

                static Array!ubyte[CustomSpace.max+1] spaceLists;

                if (gpr.s3 == Space.Type.BLUE && gpr.s2 == 0) {
                    spaceLists.each!((ref e) => e.length = 0);
                    foreach (i; iota(data.spaceCount)) {
                        if (data.spaces[i].type == Space.Type.BLUE) {
                            if (remainingTurns() <= config.revealHiddenBlocksOnRemainingTurns &&
                               (i == data.itemHiddenBlock || i == data.coinHiddenBlock || i == data.starHiddenBlock)) {
                                spaceLists[CustomSpace.HIDDEN] ~= cast(ubyte)i;
                                continue;
                            } else if (state.spaces[i] == CustomSpace.LUCKY) {
                                spaceLists[CustomSpace.LUCKY] ~= cast(ubyte)i;
                                continue;
                            }
                        }

                        spaceLists[data.spaces[i].type] ~= cast(ubyte)i;
                    }
                }

                gpr.a0 = (gpr.s2 >= spaceLists[gpr.s3].length ? 0xFF : spaceLists[gpr.s3][gpr.s2]);
            });
            0x800EADB8.onExec({
                if (!isBoardScene()) return;
                gpr.v0 = (gpr.s3 <= CustomSpace.max);
            });
            resetCustomSpacesAtStart();
            0x800EA6F4.onExec({ // Space render function
                if (!isBoardScene()) return;

                bool changed = assignCustomSpaces();

                if (!validHiddenIndex!"item"(data.itemHiddenBlock)) data.itemHiddenBlock = randomHiddenIndex();
                if (!validHiddenIndex!"coin"(data.coinHiddenBlock)) data.coinHiddenBlock = randomHiddenIndex();
                if (!validHiddenIndex!"star"(data.starHiddenBlock)) data.starHiddenBlock = randomHiddenIndex();

                if (changed) {
                    saveState();
                }
            });
            0x800FD774.onExec({ // Increment lucky space count
                if (!isBoardScene()) return;
                if (state.spaces[data.currentSpaceIndex] != CustomSpace.LUCKY) return;
                if (data.spaces[data.currentSpaceIndex].type != Space.Type.BLUE) return;

                gpr.v0--;
                currentPlayer.state.luckySpaceCount++;

                saveState();
            });
            0x800FE258.onExec({ // Trigger lucky space
                if (!isBoardScene()) return;
                if (state.spaces[data.currentSpaceIndex] != CustomSpace.LUCKY) return;
                if (data.spaces[data.currentSpaceIndex].type != Space.Type.BLUE) return;

                if (random.uniform01() < config.luckySpaceItemChance) {
                    gpr.v0 = Space.Type.ITEM;
                }
            });
            data.blueOrRedSpaceCoins.addr.onExec({ // Give extra coins on lucky space
                if (!isBoardScene()) return;
                if (state.spaces[data.currentSpaceIndex] != CustomSpace.LUCKY) return;
                if (data.spaces[data.currentSpaceIndex].type != Space.Type.BLUE) return;

                switch (gpr.s0) {
                    case 3: gpr.s0 = [7, 10, 12, 15, 20].choice(random); break;
                    case 6: gpr.s0 =        [12, 15, 20].choice(random); break;
                    default: break;
                }
            });
            0x800FE478.onExec({ // Force Toad or Baby Bowser on lucky space
                if (!isBoardScene()) return;
                if (state.spaces[data.currentSpaceIndex] != CustomSpace.LUCKY) return;
                if (data.spaces[data.currentSpaceIndex].type != Space.Type.BLUE) return;
                
                gpr.v0 = uniform!"[]"(0, 1, random);
            });
            logLuckySpaces();

            auto chooseHiddenBlockLocation = (ref ushort index) {
                if (!isBoardScene()) return;
                if (lumasPlaygroundHiddenIndex(index)) return;
                index = randomHiddenIndex();
            };
            data.itemHiddenBlock.onWrite(chooseHiddenBlockLocation);
            data.coinHiddenBlock.onWrite(chooseHiddenBlockLocation);
            data.starHiddenBlock.onWrite(chooseHiddenBlockLocation);
        }

        if (config.doubleCoinMiniGames) {
            immutable INTERVAL = 5;
            auto doubleCoins = (ref ushort amount) {
                if (data.currentScene != Scene.MINI_GAME_RESULTS) return;
                if ((data.currentTurn - 1) % INTERVAL == 0) {
                    amount *= 2;
                }
            };
            players.each!((p) {
                p.data.gameCoinsMain.onRead(doubleCoins);
                p.data.gameCoinsExtra.onRead(doubleCoins);
            });

            0x800FEF1C.onExecDone({
                if (!isBoardScene()) return;
                if (data.currentTurn % INTERVAL != 0) return;

                showGlobalMessage("          Bonus Mini-Game!\n\n" ~
                                  "                 <YELLOW><COIN_OUTLINE> × 2<RESET>", 0x15);
            });
        }

        if (config.mpiqPermadeath) {
            /*
            0x8010B374.onExec({
                if (data.currentScene != Scene.MPIQ) return;
                gpr.v0 = -1; // Force all answers to be incorrect for testing purposes
            });
            */
            0x8010B5B4.onExec({
                if (data.currentScene != Scene.MPIQ) return;

                bool allNoJump = data.mpiqNoJump[0] && data.mpiqNoJump[1] &&
                                 data.mpiqNoJump[2] && data.mpiqNoJump[3];

                if (gpr.v0 == 0 && !allNoJump) {
                    gpr.v0 = 1; // Prevent jumping
                } else if (gpr.v0 == 1 && allNoJump) {
                    gpr.v0 = 0; // Allow jumping
                }
            });
        }

        if (config.finalResultsDoNotProceed) {
            0x80109348.onExec({
                if (data.currentScene != Scene.FINAL_RESULTS) return;
                gpr.v0 = input[0..$].map!(i => i.buttons << 8)
                                    .canFind!(b => (b & Button.A) && (b & Button.Z));
            });
        }

        if (config.improveLastFiveTurnsBonus) {
            0x80107260.onExec({ // Prevent Baby Bowser
                if (data.currentScene != Scene.LAST_FIVE_TURNS) return;
                gpr.v0 = 1;
            });

            0x80106A80.onExec({ // Prevent Whomp
                if (data.currentScene != Scene.LAST_FIVE_TURNS) return;
                gpr.v0 = 1;
            });
            
            0x80106ED4.onExec({ // Choose prize amount
                if (data.currentScene != Scene.LAST_FIVE_TURNS) return;
                lastFiveTurnsBonus = [10, 20, 20, 20, 30, 30].choice(random);
            });

            0x80106EF4.onExecDone({ // Apply prize amount
                if (data.currentScene != Scene.LAST_FIVE_TURNS) return;
                gpr.a1 = lastFiveTurnsBonus;
            });
        }

        if (config.singleUseBattleSpaces) {
            data.battleRoutineComplete.addr.onExec({
                if (!isBoardScene()) return;
                if (!gpr.v0) return; // Battle cancelled
                state.spaces[data.currentSpaceIndex] = CustomSpace.BLUE;
                saveState();
            });
        }

        // TODO: Not actually everything. Expand later.
        if (config.unlockEverything) {
            0x80035C00.onExecDone({ gpr.a0 |= 0xFF; });                        // Mini-Games (800CC0DE - 800CC0E5)
            0x800CC158.val!ubyte.onRead((ref ubyte flags) { flags |= 0x20; }); // Super Hard
            0x800CC159.val!ubyte.onRead((ref ubyte flags) { flags |= 0x02; }); // Waluigi's Island
        }

        if (config.mapScrollSpeedMultiplier != 1.0) {
            setUpMapScrollSpeed(0x80100350);
        }

        if (config.increaseItemGameVariety) {
            void populateHelpScreen() {
                iota(5).map!(i => cast(Item)data.itemMiniGameItems[i])
                       .array.sort!((a, b) => a.to!string < b.to!string)
                       .each!((i, item) => data.itemMiniGameHelpScreenItems[3*i%5] = item);
            }

            0x80106CE8.onExec({
                if (data.currentScene != Scene.MINI_GAME_RULES) return;

                [EnumMembers!Item].filter!(item => item.isCommon)
                                  .array.randomShuffle(random).take(5)
                                  .each!((i, item) => data.itemMiniGameItems[i] = item);

                populateHelpScreen();
            });

            0x80106E90.onExec({
                if (data.currentScene != Scene.MINI_GAME_RULES) return;

                populateHelpScreen();
            });
        }

        if (config.increaseItemShopVariety) {
            int phase = -1;
            int rank  = -1;

            data.currentTurn.onRead((ref ubyte turn, Address pc) {
                if (!isBoardScene()) return;
                if ((pc + 32).val!Instruction != 0x0C03B164) return; // Not item shop

                phase = -1;
                rank  = -1;
            });

            0x800EEA50.onExec({ // Return player rank
                if (!isBoardScene()) return;

                if ((gpr.ra + 12).val!Instruction != 0x00041840) return; // Not item shop
                if ((gpr.ra + 16).val!Instruction != 0x00641821) return; // Not item shop
                if ((gpr.ra + 20).val!Instruction != 0x00031880) return; // Not item shop
                if ((gpr.ra + 24).val!Instruction != 0x00651821) return; // Not item shop

                if (phase == -1 && rank == -1) {
                    phase = gpr.s1;
                    rank  = gpr.v0;

                    if (uniform!"[]"(1, 3, random) == 1) {
                        switch (phase) {
                            case GamePhase.EARLY: phase = GamePhase.MID;                                   break;
                            case GamePhase.MID:   phase = [GamePhase.EARLY, GamePhase.END].choice(random); break;
                            case GamePhase.END:   phase = GamePhase.MID;                                   break;
                            default:                                                                       break;
                        }
                    }

                    if (uniform!"[]"(1, 3, random) == 1) {
                        switch (phase) {
                            case GamePhase.MID: rank = [0, 1]   .remove(min(rank, 1)).choice(random); break;
                            case GamePhase.END: rank = [0, 1, 2].remove(min(rank, 2)).choice(random); break;
                            default:                                                                  break;
                        }
                    }
                }

                gpr.s1 = phase;
                gpr.v0 = rank;
            });
        }

        if (config.toadShopChance >= 0) {
            Address[][Scene] shopTypeAddress;
            0x800ECEDC.onExec({ // return RNGPercentChance
                if (!isBoardScene()) return;
                if (data.currentScene !in shopTypeAddress) {
                    shopTypeAddress[data.currentScene] = searchMemory([0x0C03B3A7, 0x24040042, 0x00021400, 0x2C420001]);
                }
                if (shopTypeAddress[data.currentScene].canFind(gpr.ra - 8)) {
                    gpr.v0 = random.uniform01() < config.toadShopChance;
                }
            });
        }

        players.each!((p) {
            foreach (i; iota(3)) {
                p.data.items[i].onWrite((ref Item item) {
                    if (remainingTurns() <= config.replaceWackyWatchBeforeRemainingTurns) return;

                    if (item == Item.WACKY_WATCH) {
                        item = [Item.KOOPA_KARD, Item.BARTER_BOX, Item.LUCKY_CHARM].choice(random);
                    }
                });
            }
        });

        if (config.autoStartNextBoard) {
            0x80048228.onExec({
                if (gpr.a0 == Scene.TRANSITION && data.currentScene == Scene.FINAL_RESULTS) {
                    gpr.a0 = Scene.CHILLY_WATERS_BOARD + (data.currentBoard + 1) % 6;
                    gpr.a1 = 0;

                    iota(4).each!((i) {
                        data.players[i].coins = 0;
                        data.players[i].stars = 0;
                        iota(3).each!(j => data.players[i].items[j] = Item.NONE);
                        data.players[i].miniGameCoins = 0;
                        data.players[i].maxCoins = 0;
                        data.players[i].happeningSpaces = 0;
                        data.players[i].redSpaces = 0;
                        data.players[i].blueSpaces = 0;
                        data.players[i].chanceSpaces = 0;
                        data.players[i].bowserSpaces = 0;
                        data.players[i].battleSpaces = 0;
                        data.players[i].itemSpaces = 0;
                        data.players[i].bankSpaces = 0;
                        data.players[i].gameGuySpaces = 0;
                    });
                }
            });
        }

        if (config.balanceSuperHardCPU) {
            iota(4).each!((i) {
                data.players[i].cpuDifficulty.onRead((ref ubyte difficulty) {
                    if (difficulty != CPUDifficulty.SUPER_HARD) return;

                    switch (data.currentScene) {
                        case Scene.LOG_JAM:
                            difficulty = CPUDifficulty.EASY;
                            break;

                        case Scene.TOADSTOOL_TITAN:
                            difficulty = CPUDifficulty.NORMAL;
                            break;

                        case Scene.BABY_BOWSER_BROADSIDE:
                        case Scene.HYPER_HYDRANTS:
                        case Scene.THE_BEAT_GOES_ON:
                        case Scene.CHEEP_CHEEP_CHASE:
                        case Scene.POPGUN_PICK_OFF:
                        case Scene.BOWSER_TOSS:
                        case Scene.SILLY_SCREWS:
                            difficulty = CPUDifficulty.HARD;
                            break;

                        default:
                            break;
                    }
                });
            });
        }

        if (config.chanceSwapInsteadOfTransfer) {
            0x8010D5FC.onExecDone({ // Write chance outcome
                if (data.currentScene != Scene.CHANCE_TIME) return;
                if (data.chanceCharacter1 == -1) return;
                if (data.chanceCharacter2 == -1) return;
                if (data.chancePrize      == -1) return;

                auto p1 = players.find!(p => p.data.character == data.chanceCharacter1).front;
                auto p2 = players.find!(p => p.data.character == data.chanceCharacter2).front;

                switch (data.chancePrize) {
                    case ChancePrize.COINS_ALL:
                        if (p1.data.coins < p2.data.coins) {
                            data.chanceCharacter1 = p2.data.character;
                            data.chanceCharacter2 = p1.data.character;
                        }
                        break;

                    case ChancePrize.STARS_ALL:
                        if (p1.data.stars < p2.data.stars) {
                            data.chanceCharacter1 = p2.data.character;
                            data.chanceCharacter2 = p1.data.character;
                        }
                        break;

                    default:
                        break;
                }
            });

            0x8010FA4C.onExecDone({ // Check if coins will transfer
                if (data.currentScene != Scene.CHANCE_TIME) return;
                if (data.chancePrize != ChancePrize.COINS_ALL) return;

                auto p1 = players.find!(p => p.data.character == data.chanceCharacter1).front;
                auto p2 = players.find!(p => p.data.character == data.chanceCharacter2).front;

                gpr.v0 = p1.data.coins - p2.data.coins;
            });

            0x8010FA80.onExecDone({ // Check if stars will transfer
                if (data.currentScene != Scene.CHANCE_TIME) return;
                if (data.chancePrize != ChancePrize.STARS_ALL) return;

                auto p1 = players.find!(p => p.data.character == data.chanceCharacter1).front;
                auto p2 = players.find!(p => p.data.character == data.chanceCharacter2).front;

                gpr.v0 = p1.data.stars - p2.data.stars;
            });

            0x8010E650.onExecDone({ // Determine coin transfer amount
                if (data.currentScene != Scene.CHANCE_TIME) return;
                if (data.chancePrize != ChancePrize.COINS_ALL) return;

                gpr.v0 = data.players[data.chancePlayer1].coins - data.players[data.chancePlayer2].coins;
            });

            0x8010E684.onExecDone({ // Determine star transfer amount
                if (data.currentScene != Scene.CHANCE_TIME) return;
                if (data.chancePrize != ChancePrize.STARS_ALL) return;

                gpr.v0 = data.players[data.chancePlayer1].stars - data.players[data.chancePlayer2].stars;
            });
        }

        if (!config.chancePrizeReplace.empty) {
            0x8010D190.onExecDone({
                if (data.currentScene != Scene.CHANCE_TIME) return;

                auto replacement = cast(ChancePrize)gpr.v0 in config.chancePrizeReplace;
                if (replacement) gpr.v0 = *replacement;
            });
        }

        if (config.rankPlayersByBingoScore) {
            setUpBingoRanking(0x800EE9C0, 0x800EEA50, 0x800EE9E0, 0x0C03BB2C);
        }

        if (config.battleCoinDistribution != DEFAULT_BATTLE_DIST) {
            0x80105BCC.onExec({
                if (data.currentScene != Scene.BATTLE_GAME_RESULTS) return;

                auto rankCounts = [0, 0, 0, 0];
                players.each!(p => rankCounts[p.data.battleRank]++);

                auto rankDist = [0.0, 0.0, 0.0, 0.0];
                size_t r = 0;
                config.battleCoinDistribution.each!((i, e) {
                    if (rankCounts[i]) r = i;
                    rankDist[r] += e;
                });

                rankDist.each!((i, ref e) {
                    if (rankCounts[i]) e /= rankCounts[i];
                });

                auto dist = players.map!(p => rankDist[p.data.battleRank]).array;
                auto coins = apportion(data.battleCoinTotal, dist);
                coins.each!((i, c) => players[i].data.battleCoins = cast(ushort)c);
                data.battlePityCoins = data.battleCoinTotal - cast(ushort)coins.sum;
            });
        }

        // Chance Time duplicate character fix
        0x8010E308.onExec({
            if (data.currentScene != Scene.CHANCE_TIME) return;

            if (gpr.a1 == 0) {
                data.chancePlayer1 = players.filter!(p => p.data.character == gpr.v0)
                                            .filter!(p => p.index != data.chancePlayer2)
                                            .array.choice(random).index;
            } else {
                data.chancePlayer2 = players.filter!(p => p.data.character == gpr.v0)
                                            .filter!(p => p.index != data.chancePlayer1)
                                            .array.choice(random).index;
            }

            gpr.a0 = (gpr.a1 == 0 ? data.chancePlayer1 : data.chancePlayer2);
        });

        // Chance Time duplicate character fix
        0x8010F9DC.onExec({
            if (data.currentScene != Scene.CHANCE_TIME) return;

            gpr.a0 = (gpr.a2 == 0 ? data.chancePlayer1 : data.chancePlayer2);
        });

        // Chance Time duplicate character fix
        0x8010E568.onExec({
            if (data.currentScene != Scene.CHANCE_TIME) return;

            gpr.a0 = (gpr.s2 == 0 ? data.chancePlayer1 : data.chancePlayer2);
        });

        watchPlayerInfo(); // Keep this at the bottom
    }

    void allocateSuperstarsNameBuffer() {
        ssNameBuffer = 0;
        mallocTemp(SUPERSTARS_NAME_SLOT_SIZE * data.miniGameRoulette.length, (ptr) {
            ssNameBuffer = ptr;
        });
    }

    // Fills the roulette with Superstars mini-games, using MP3 mini-games of the same type as placeholders.
    // Returns false if the roulette should be populated normally instead.
    bool populateSuperstarsRoulette(MiniGameType type, uint count) {
        auto all = superstarsMiniGames(type);
        if (all.empty || count == 0 || count > data.miniGameRoulette.length) return false;

        auto placeholders = [EnumMembers!MiniGame].filter!(g => g.type == type).take(count).array;
        if (placeholders.length < count) return false;

        auto choices = all.filter!(g => !config.blockedSuperstarsMiniGames.canFind(g)).array;
        if (choices.empty) choices = all;

        // The queue holds every (unblocked) mini-game of the list. Battles skip its coin mini-games,
        // which stay in the queue for regular 4-player roulettes.
        auto key = superstarsQueueKey(type);
        auto queue = &state.superstarsMiniGameQueue.require(key);
        if (queue.empty) queue.initialize(choices, random);
        auto allowed = (SuperstarsMiniGame g) => isAllowedSuperstarsMiniGame(g, type);
        auto game = queue.next(random, allowed);
        auto alternatives = choices.filter!(g => g != game && allowed(g)).array.randomShuffle(random)
                          ~ all.filter!(g => g != game && !choices.canFind(g) && allowed(g)).array.randomShuffle(random);
        // At most one coin mini-game and one Bowser mini-game per roulette
        auto fits = (SuperstarsMiniGame g, SuperstarsMiniGame[] list) =>
            !(g.isCoinMiniGame && list.any!(o => o.isCoinMiniGame)) &&
            !(g.isBowserMiniGame && list.any!(o => o.isBowserMiniGame));
        SuperstarsMiniGame[] names = [game];
        foreach (g; alternatives) {
            if (names.length == count) break;
            if (fits(g, names)) names ~= g;
        }
        for (size_t i = 0; names.length < count; i++) {
            names ~= names[i];
        }
        names.randomShuffle(random);

        foreach (i, g; names) {
            data.miniGameRoulette[i] = placeholders[i];
            ssRoulette[placeholders[i]] = g;
        }

        if (ssNameBuffer) {
            foreach (i, g; names) {
                // Plain label: no <END>, which would make the window show a "press A" arrow.
                // Coin mini-games are yellow, Bowser mini-games red.
                auto name = g.isCoinMiniGame   ? "<YELLOW>" ~ g.fullName ~ "<RESET>"
                          : g.isBowserMiniGame ? "<RED>"    ~ g.fullName ~ "<RESET>"
                          : g.fullName;
                auto text = formatText(name ~ "<NUL><NUL>");
                if (text.length > SUPERSTARS_NAME_SLOT_SIZE) {
                    text = text[0..SUPERSTARS_NAME_SLOT_SIZE - 2] ~ formatText("<NUL><NUL>");
                }
                auto slot = Ptr!char(ssNameBuffer + cast(uint)(i * SUPERSTARS_NAME_SLOT_SIZE));
                foreach (j, char c; text) slot[j] = c;
            }
        } else {
            warning("No buffer for Superstars mini-game names; the roulette will show MP3 mini-game names");
        }

        auto target = names.countUntil(game);
        0x800DF120.onExecOnce({ gpr.v0 = cast(uint)target; });

        ssType = type;
        if (type != MiniGameType.DUEL) ssDuelists = null;

        return true;
    }

    // Fades out the music the same way the board does before a mini-game (func_800F93A4), so it doesn't play
    // during the Superstars mini-game. Battles and duels play their music on a second track (D_800C9930).
    void fadeOutBoardMusic(void delegate() done) {
        enum FRAMES = 60;
        auto stopSeq = (void delegate() next) {
            0x8004A950.jal(next);                                  // Stop the main track
        };
        auto checkFlag = {
            if (0x800CE206.val!short != 0) {
                0x800CE206.val!short = 0;
                stopSeq(done);
            } else {
                done();
            }
        };
        auto fadeExtraTrack = {
            auto track = 0x800C9930.val!short;
            if (track != -1) {
                0x800C9930.val!short = -1;
                0x800039A4.jal(cast(uint)cast(int)track, FRAMES, { // Fade the battle/duel track
                    stopSeq(checkFlag);
                });
            } else {
                checkFlag();
            }
        };
        0x8004A994.jal(FRAMES, fadeExtraTrack);                     // HuAudSeqFadeOut: fade the main track
    }

    // The bingo card name for a character's player (null if none, or bingoPlayerNames is off)
    string bingoPlainName(Character c) {
        if (!config.bingoPlayerNames) return null;
        auto n = c in characterToName;
        if (!n) return null;
        return (*n).toUpper == "CPU" ? c.fullName : *n; // CPUs go by their character (Mario, Daisy, DK, ...)
    }

    // bingoPlainName() in the character's color, then back to the default color unless `reset` is false
    string bingoName(Character c, bool reset = true) {
        auto name = bingoPlainName(c);
        return name ? characterColor(c) ~ name ~ (reset ? "<RESET>" : "") : null;
    }

    enum WINDOW_SIZE = 0x27C;
    Address windowAddress(short w) { return 0x800CC69C.val!uint + w * WINDOW_SIZE; }

    WindowColors* colorsOf(short w) {
        if (auto wc = w in windowColors) return wc;
        windowColors[w] = WindowColors();
        return w in windowColors;
    }

    // Palette entry i of window w (RGBA5551)
    Ptr!ushort paletteEntry(short w, size_t i) { return Ptr!ushort(windowAddress(w) + cast(uint)i * 2); }

    // Undoes the plugin's colors in window w (except ones the game has since replaced), for its next message
    void resetColors(short w) {
        auto wc = colorsOf(w);
        foreach (i; 0..16) {
            if (!wc.changed[i]) continue;
            wc.changed[i] = false;
            if (paletteEntry(w, i)[0] != wc.value[i]) continue; // Replaced by the game
            paletteEntry(w, i)[0] = wc.before[i];
            paletteChanged[w] = true;
        }
        wc.used = false;
    }

    // Marks the color codes in game text as used in window w, so the plugin's colors don't replace them
    void markUsed(short w, string text) {
        auto wc = colorsOf(w);
        for (size_t i = 0; i < text.length; i++) {
            auto c = text[i];
            if (c == '\x18') i++; // <SKIP_NEXT> and its byte
            else if (c >= '\x02' && c <= '\x07') wc.used[c] = true;
        }
    }

    // The text of window w's argument n (<1>-<5>), as loaded (null if none)
    string argText(short w, int n) {
        auto p = (windowAddress(w) + 184 + n * 4).val!uint;
        if (p < 0x80000000 || p >= 0x80800000) return null;
        string s;
        auto c = Ptr!char(p);
        for (int i = 0; c[i] != '\0' && i < 256; i++) s ~= c[i];
        return s;
    }

    // Shows window w's argument n in the color of the first plugin color (textColor()) in it, if any. An argument can
    // have its own color (window + 178 + n, as color code - 1; -1 for none): the window draws it in that color, then
    // goes back to the color before it. func_8005B6BC resets it.
    void colorArg(short w, int n) {
        if (n < 0 || n >= 5) return;
        auto text = argText(w, n);
        auto i = text.indexOf('\x18');
        if (i < 0 || i + 1 >= text.length) return;
        auto c = text[i + 1] - '0';
        if (c < 0 || c >= TEXT_COLORS.length) return;
        (windowAddress(w) + 178 + n).val!byte = cast(byte)(colorCode(w, TEXT_COLORS[c]) - 1);
    }

    // A window's text sprite draws with a copy of its palette, which may be shared with other windows until the game
    // gives it one of its own. func_8005C060(window, color - 1, r, g, b) sets a color of the window's palette, then
    // gives its text sprite a new copy of the whole palette, so calling it with a color the palette already has makes
    // that copy, with the plugin's colors in it. (Writing to the sprite's palette directly could change shared ones.)
    bool[short] paletteChanged;

    void copyTextPaletteIfChanged(short w) {
        if (w !in paletteChanged) return;
        paletteChanged.remove(w);
        auto color = paletteEntry(w, 2)[0]; // Color 2, as it is
        gpr.sp -= 24;
        (gpr.sp + 16).val!uint = ((color >> 1) & 31) << 3; // b, the 5th argument
        0x8005C060.jal(w, 1, ((color >> 11) & 31) << 3, ((color >> 6) & 31) << 3, { gpr.sp += 24; });
    }

    // The color code (0x02-0x07) showing `color` in window w, recoloring one that isn't in use if none does
    char colorCode(short w, ushort color) {
        auto wc = colorsOf(w);
        auto use = (int n) { wc.used[n] = true; return cast(char)n; };

        foreach (n; 2..8) if (paletteEntry(w, n)[0] == color) return use(n);

        // The window's own colors aren't in its text as codes: its default text color (window + 35, as code - 1;
        // white in board dialogs, but not in others, like Chance Time's speech bubbles), current color (+ 34) and
        // outline color (+ 51)
        auto own = [35, 34, 51].map!(o => (windowAddress(w) + o).val!ubyte + 1);

        foreach (n; [6, 2, 4, 3, 5, 7]) { // Cyan first: the game's English text never uses it
            if (wc.used[n] || own.canFind(n)) continue;
            // Its edge, as the game makes them (func_8005FC80 area): 30% of the color at half brightness, 70% of the
            // window's background (window + 45, + 46, + 47: red, green, blue)
            ushort edge = 1;
            foreach (k, shift; [11, 6, 1]) {
                auto dark = ((color >> shift) & 31) / 2 << 3;
                auto background = (windowAddress(w) + 45 + cast(uint)k).val!ubyte;
                edge |= min(255, cast(int)(dark * 0.3f + background * 0.7f)) >> 3 << shift;
            }
            foreach (i, value; [n: color, n + 7: edge]) {
                if (!wc.changed[i]) {
                    wc.changed[i] = true;
                    wc.before[i] = paletteEntry(w, i)[0];
                }
                wc.value[i] = value;
                paletteEntry(w, i)[0] = value;
            }
            paletteChanged[w] = true; // Copied to the text sprite once the message is set (copyTextPaletteIfChanged())
            return use(n);
        }
        warning("Window ", w, " has no text color left for ", color);
        return cast(char)((windowAddress(w) + 35).val!ubyte + 1); // The window's default text color
    }

    // A message for window w: its plugin colors (textColor()) become color codes, which keeps its length
    // (<SKIP_NEXT> 'n' -> code, 0x09). The game's own codes in it are kept.
    string colorize(short w, string text) {
        markUsed(w, text);
        char[] t;
        for (size_t i = 0; i < text.length; i++) {
            if (text[i] != '\x18' || i + 1 >= text.length) continue;
            auto n = text[i + 1] - '0';
            if (n >= 0 && n < TEXT_COLORS.length) {
                if (t is null) t = text.dup;
                t[i] = colorCode(w, TEXT_COLORS[n]);
                t[i + 1] = '\x09'; // Does nothing
            }
            i++;
        }
        return t is null ? text : t.idup;
    }

    // colorize() for text in memory that has character colors (the plugin's own messages)
    void colorizeInPlace(short w, Address address) {
        auto p = Ptr!char(address);
        string text;
        for (size_t i = 0; p[i] != '\0' && i < 4096; i++) text ~= p[i];
        markUsed(w, text); // Its own colors, even with no plugin colors in it (like a custom board's star shop price)
        if (!text.canFind('\x18')) return;
        auto colored = colorize(w, text);
        foreach (i, c; colored) p[i] = c;
    }

    // Whether game text `shown` is the character name `name`. Some messages have names in capitals (0x1C00-0x1C5F,
    // 0x5200-0x5207), so case is ignored; game text isn't always valid UTF-8, so bytes are compared.
    static bool sameName(string shown, string name) {
        auto upper = (ubyte b) => (b >= 'a' && b <= 'z') ? b - 32 : b;
        return shown.length == name.length && iota(shown.length).all!(i => upper(shown[i]) == upper(name[i]));
    }

    // The game passes some window arguments as pointers to text instead of message IDs (like the names in the duel
    // opponent menu, message 0x5C00). If one is just a character's name (maybe colored), this is the ID of that
    // character's name message (0x1B10 + character), which goes through replaceMessage(); otherwise 0.
    // Menus show players who can't be chosen (yourself, or someone with nothing to take) in color 1, which is dark
    // (enabled ones are white, color 8). That color is kept in nameColor for replaceMessage(), until the caller is done.
    uint nameMessageId(Address p) {
        nameColor = 0;
        if (p < 0x80000000 || p >= 0x80800000) return 0;
        string s;
        auto c = Ptr!char(p);
        for (int i = 0; c[i] != '\0' && i < 32; i++) s ~= c[i];
        size_t start = 0, end = s.length;
        if (end > start && s[start] == '\x0B') start++;
        if (end > start && s[end - 1] == '\x19') end--;                            // <RESET>
        char color = 0;
        if (end > start && s[start] >= '\x01' && s[start] <= '\x08') color = s[start++]; // Color
        foreach (ch; [EnumMembers!Character]) {
            if (ch == Character.UNDEFINED || !sameName(s[start..end], ch.fullName)) continue;
            if (!bingoName(ch)) return 0;
            if (color == '\x01') nameColor = color;
            return 0x1B10 + ch;
        }
        return 0;
    }

    // Text (game bytes) to load instead of message `id`, whose own text is `text`, or null to keep it
    string replaceMessage(ushort id, string text) {
        auto message = (string s) => formatText("<CLEAR>" ~ s ~ "<RESET><END><NUL>");

        // A character's name by itself, possibly in a color. The game shows these alone and inserts them into other
        // messages as <1>-<5>, so this covers player names everywhere without touching any other text.
        if (config.bingoPlayerNames && text.length >= 2 && text[0] == '\x0B') {
            size_t start = 1, end = text.length;
            while (end > start && text[end - 1] == '\x00') end--;
            auto nuls = end;
            if (end > start && text[end - 1] == '\x19') end--;                            // <RESET>
            if (end > start && text[start] >= '\x01' && text[start] <= '\x08') start++; // Color
            foreach (c; [EnumMembers!Character]) {
                if (!sameName(text[start..end], c.fullName)) continue;
                // In the character's color, instead of the message's own. Without a <RESET>: inserted as an argument,
                // the window switches back to the color before it (see colorArg()). A name the game showed dark (a
                // player who can't be chosen) stays dark.
                if (nameColor) {
                    if (auto plain = bingoPlainName(c)) return "\x0B" ~ nameColor ~ formatText(plain) ~ text[nuls..$];
                }
                auto name = bingoName(c, false);
                if (name) return "\x0B" ~ formatText(name) ~ text[nuls..$];
            }
        }

        // The turn counter's text, while it's being loaded (see maintainTurnCounter())
        if (id == TURN_COUNTER_MESSAGE && turnCounterText !is null) {
            return formatText("<CLEAR>" ~ turnCounterText ~ "<NUL><NUL>");
        }

        // Bonus stars: 0x1402 introduces them, then each has 5 messages (0x1403, 0x1408, 0x140D): the award, then the
        // winner, or a 2-, 3- or 4-way tie
        if (config.randomBonus && data.currentScene == Scene.FINISH_BOARD && bonus.length >= 3 && id >= 0x1402 && id <= 0x1411) {
            if (id == 0x1402) return message("Now, here are the <YELLOW><OUTLINE>Bonus Star<NO_OUTLINE><RESET> results.\nEach winner will get one star.");

            auto i = (id - 0x1403) / 5;
            auto b = bonus[i];
            auto star = "<" ~ getColor(b) ~ "><OUTLINE>" ~ config.bonuses[b] ~ " Star";
            final switch ((id - 0x1403) % 5) {
                case 0: return message(["Let's begin with the ", "Next, the ", "Finally, the "][i] ~ star ~ "<NO_OUTLINE><RESET>.\n" ~
                                       wrapMessage("This award goes to the person who " ~ getDescription(b) ~ ".",
                                                   messageTextWidth("This award goes to the person")));
                case 1: return message("The " ~ star ~ "<NO_OUTLINE><RESET> award\ngoes to...<1>!");
                case 2: return message("It's a tie! " ~ star ~ "<NO_OUTLINE><RESET>\nawards go to both\n<1> and <2>!");
                case 3: return message("It's a three-way tie!\n" ~ star ~ "<NO_OUTLINE><RESET> awards\ngo to <1>,\n<2> and <3>!");
                case 4: return message("It's a four-way tie!!!\nAll four players are\n" ~ star ~ "s<NO_OUTLINE><RESET>,\nso no stars will be awarded.");
            }
        }

        // Last Five Turns: the standings. The game shows first and last place outlined, in yellow and red; with the
        // bingo names in their own colors, they're plain like second and third place.
        if ((id == 0x4301 || id == 0x4304) && config.bingoPlayerNames && characterToName.length) {
            return message(id == 0x4301 ? "<1> is first!" : "And <1> is in last place.");
        }

        // Last Five Turns: the present for the predicted winner
        if (id == 0x4308 && config.improveLastFiveTurnsBonus && data.currentScene == Scene.LAST_FIVE_TURNS) {
            return message("And to <1>, our predicted\nwinner, we award a\npresent of <YELLOW><OUTLINE>" ~ lastFiveTurnsBonus.to!string ~ " coins<NO_OUTLINE><RESET><YELLOW>!");
        }

        // Chance Time: swaps instead of "all coins/stars" transfers
        if (config.chanceSwapInsteadOfTransfer && data.currentScene == Scene.CHANCE_TIME &&
            (data.chancePrize == ChancePrize.COINS_ALL || data.chancePrize == ChancePrize.STARS_ALL)) {
            enum SAME = "Both players have the\n<YELLOW><OUTLINE>same number<NO_OUTLINE><RESET> of ";
            switch (id) {
                case 0x1B0C: return message("The results are in!<RESET><END><CLEAR>Wow! <GREEN><1><RESET> swaps\n<YELLOW><OUTLINE>coins<NO_OUTLINE><RESET> with <GREEN><2><RESET>!");
                case 0x1B0E: return message("The results are in!<RESET><END><CLEAR>Wow! <GREEN><1><RESET> swaps\n<YELLOW><OUTLINE>stars<NO_OUTLINE><RESET> with <GREEN><2><RESET>!" ~
                                            "<RESET><END><CLEAR>This is amazing!\nA complete turnaround!\n");
                case 0x1B0B: return message("...Whoa! Bad news!<RESET><END><CLEAR>" ~ SAME ~ "stars.\nWhat a pity.");
                case 0x1B0D: return message("...Oh my goodness!<RESET><END><CLEAR>" ~ SAME ~ "coins.\nUnbelievable!");
                case 0x1B0F: return message("...Whoa! Bad news!<RESET><END><CLEAR>" ~ SAME ~ "stars.\nHow disappointing.");
                default:
            }
        }

        return null;
    }

    // The turn counter: a frameless window at the top center of the board screen, between the top players' panels,
    // made the way the board makes its button hints (func_800E1F70). Its text is message TURN_COUNTER_MESSAGE (one the
    // board never shows), which replaceMessage() replaces while the counter loads it, so the game keeps its own copy.
    //
    // It's shown on the board, except while the pause menu is open, and lowered while the scrolling map is (see
    // onStart(); the game pauses for its other menus too, like the item screen and the full map, so 0x800D6A90 can't
    // tell them apart). Whenever what it should show changes (its text or place, or showing it at all), its window is
    // closed and another made. That's at most a few times a turn, and simpler than changing a window.
    //
    // It's kept up from inside a game process (HuPrcVSleep), one call to the game at a time. Windows go away when the
    // game closes them, or all at once when the board does, and their numbers are reused, so a window only counts as
    // the counter while it still has the sprite group it was made with (window + 108).
    enum TURN_COUNTER_MESSAGE = 0x2A0D;
    short turnCounterWindow = -1;
    short turnCounterGroup;         // Its sprite group
    string turnCounterShown;        // Its text
    int turnCounterX, turnCounterY; // Where it is
    string turnCounterText;         // Text being loaded, or null
    int turnCounterCovered;         // Screens open that it's hidden for
    int turnCounterLowered;         // Screens open that it's lowered for
    bool turnCounterBusy;           // Calls to the game are in progress

    short windowGroup(short w) { return (windowAddress(w) + 108).val!short; }

    void maintainTurnCounter() {
        if (turnCounterBusy || stateAllocating) return;
        if ((0x8004F074.val!uint & 0xFFFF0000) != 0x27BD0000) return; // HuPrcVSleep isn't "addiu sp, sp, ..."
        if (!isBoardScene() || 0x800A2150.val!ubyte == 0) return;      // Not on the board, or no windows set up

        auto exists = turnCounterWindow >= 0 && windowGroup(turnCounterWindow) == turnCounterGroup;
        if (!exists) turnCounterWindow = -1;

        // What it should show. The text is centered on the screen (320 pixels wide, so the same way as a 5-pixel "/" on
        // pixels 158-162): func_8005A968 takes the window's left side, and the text starts 4 pixels right of it. The
        // text is from 4 lines above y to 6 below: level with the top players' panels, or on the scrolling map, below
        // its up arrow (down to line 31).
        auto wanted = data.currentTurn >= 1 && turnCounterCovered == 0;
        auto text = "<YELLOW>" ~ data.currentTurn.to!string ~ " / " ~ data.totalTurns.to!string ~ "<RESET>";
        auto x = (321 - messageTextWidth(text)) / 2 - 4;
        auto y = turnCounterLowered > 0 ? 40 : 15;

        if (exists) {
            if (wanted && text == turnCounterShown && x == turnCounterX && y == turnCounterY) return;
            turnCounterBusy = true;
            auto w = turnCounterWindow;
            turnCounterWindow = -1;
            0x8005F364.jal(w, { turnCounterBusy = false; }); // Closed; made again later if it's wanted
            return;
        }
        if (!wanted) return;

        // func_80060394(1, short[2]* size, message) measures the window the text needs (padding included), and
        // func_8005A968(x, y, w, h, 0, 0) makes it, with (x, y) its top left
        turnCounterBusy = true;
        turnCounterText = text; // Replaces the message while it's measured and set
        gpr.sp -= 32;
        0x80060394.jal(1, gpr.sp + 24, TURN_COUNTER_MESSAGE, {
            auto width = (gpr.sp + 24).val!short, height = (gpr.sp + 26).val!short;
            (gpr.sp + 16).val!uint = 0; // The 5th and 6th arguments
            (gpr.sp + 20).val!uint = 0;
            // func_8005A968 takes the first free window from 2 up (window + 94 is -1 when free). Custom board events
            // can update a window by its number (like Thwomp Toll's window 2), so the counter takes the last free one
            // instead, which leaves the game's windows the numbers they'd have without it.
            uint slot = 0;
            foreach_reverse (i; 2..16) if (!slot && (windowAddress(cast(short)i) + 94).val!short == -1) slot = i;
            if (slot) 0x8005A9AC.onExecOnce({ gpr.fp = slot; }); // After the search starts at 2
            0x8005A968.jal(x, y, width, height, (uint result) {
                gpr.sp += 32;
                auto w = cast(short)result;
                0x8005BDFC.jal(w, 0, {                     // Text appears at once, not letter by letter
                    0x8005BEE0.jal(w, 0, {                 // No window frame or background
                        0x8005B63C.jal(w, 0, 0x20000, {    // Outlined text
                            0x8005B43C.jal(w, TURN_COUNTER_MESSAGE, -1, -1, {
                                turnCounterText = null;
                                turnCounterWindow = w;
                                turnCounterGroup = windowGroup(w);
                                turnCounterShown = text;
                                turnCounterX = x;
                                turnCounterY = y;
                                turnCounterBusy = false;
                            });
                        });
                    });
                });
            });
        });
    }

    void showSuperstarsMessage() {
        ssPhase = SuperstarsPhase.WAITING;

        fadeOutBoardMusic({
            // Coin mini-games are yellow and Bowser mini-games red, as on the roulette
            auto color = ssGame.isCoinMiniGame ? "<YELLOW>" : ssGame.isBowserMiniGame ? "<RED>" : "<CYAN>";
            auto intro  = ["Let's play <OUTLINE>" ~ color ~ ssGame.fullName ~ "<NO_OUTLINE><RESET>",
                           "in <OUTLINE><YELLOW>Mario Party Superstars<NO_OUTLINE><RESET>!"];
            auto outro  = ["When you're done, enter the", "results on the Bingo page."];
            auto teams  = superstarsTeamLines((intro ~ outro).map!messageTextWidth.maxElement);
            showGlobalMessage((intro.join("\n") ~ "\n\n" ~ (teams.empty ? "" : teams.join("\n") ~ "\n\n") ~ outro.join("\n")),
                              -1, true, {
                if (ssPhase != SuperstarsPhase.WAITING) return;
                if (ssResults) {
                    ssPhase = SuperstarsPhase.READY;
                } else {
                    // Input is blocked until results arrive, so this should not happen
                    warning("The Superstars message closed without results; playing the MP3 mini-game instead");
                    resetSuperstars();
                }
            });
        });
    }

    // The players of the Superstars mini-game, laid out by team for the message window, each line centered:
    //   4-player/battle: two pairs   2-vs-2: team / vs. / team   1-vs-3: solo / vs. / two of the team / third
    //   duel: A / vs. / B
    // Widths come from the game's font table; padding is made of 4- and 10-pixel spaces, so it is within 1-2 pixels.
    string[] superstarsTeamLines(int textWidth) {
        enum GAP = 16; // Between the two names of a pair

        auto name = (Player p) {
            auto n = bingoName(p.data.character);
            return n ? n : p.data.character.fullName;
        };
        auto pair = (Player a, Player b) => name(a) ~ messageSpace(GAP) ~ name(b);
        auto blue = players.filter!(p => p.panel.color == PanelColor.BLUE).array;
        auto red  = players.filter!(p => p.panel.color == PanelColor.RED).array;
        auto split = (blue.length + red.length == 4);

        string[] lines;
        if (ssType == MiniGameType.DUEL && ssDuelists.length == 2) {
            lines = [name(players[ssDuelists[0]]), "vs.", name(players[ssDuelists[1]])];
        } else if (ssType == MiniGameType.TWO_V_TWO && split && blue.length == 2) {
            auto first  = (blue[0].index < red[0].index ? blue : red);
            auto second = (first is blue ? red : blue);
            lines = [pair(first[0], first[1]), "vs.", pair(second[0], second[1])];
        } else if (ssType == MiniGameType.ONE_V_THREE && split && (blue.length == 1 || red.length == 1)) {
            auto solo = (blue.length == 1 ? blue : red);
            auto team = (blue.length == 1 ? red : blue);
            lines = [name(solo[0]), "vs.", pair(team[0], team[1]), name(team[2])];
        } else {
            lines = [pair(players[0], players[1]), pair(players[2], players[3])];
        }

        int width = max(textWidth, lines.map!messageTextWidth.maxElement);
        return lines.map!(l => messageSpace((width - messageTextWidth(l)) / 2) ~ l).array;
    }

    // Writes the entered results where the mini-game would have and returns the overlay to go to next
    // (the results screen, or the board for duels)
    uint applySuperstarsResults() {
        auto r = ssResults;
        info("Superstars results for ", ssGame.fullName, ": coins=", r.coins, " ranks=", r.ranks, " winner=", r.winner);

        final switch (ssType) {
            case MiniGameType.BATTLE:
                players.each!((p) {
                    p.data.battleCoins = 0;
                    p.data.battleRank = cast(ushort)clamp(r.ranks[p.index] - 1, 0, 3);
                });
                return Scene.BATTLE_GAME_RESULTS;

            case MiniGameType.DUEL:
                players.each!((p) {
                    p.data.gameCoinsExtra = 0;
                    p.data.gameCoinsMain = (r.winner == p.index + 1 ? 10 : 0); // Any non-zero value wins
                });
                return Scene.CHILLY_WATERS_BOARD + data.currentBoard;

            case MiniGameType.ONE_V_THREE:
            case MiniGameType.TWO_V_TWO:
            case MiniGameType.FOUR_PLAYER:
                players.each!((p) {
                    p.data.gameCoinsExtra = 0;
                    p.data.gameCoinsMain = cast(ushort)clamp(r.coins[p.index], 0, 999);
                });
                return Scene.MINI_GAME_RESULTS;

            case MiniGameType.ITEM:
            case MiniGameType.GAMBLE:
            case MiniGameType.SPECIAL:
                assert(0, "Superstars mini-games are not used for " ~ ssType.to!string);
        }
    }

    void resetSuperstars() {
        bool wasActive = (ssPhase != SuperstarsPhase.NONE);
        ssPhase = SuperstarsPhase.NONE;
        ssRoulette.clear();
        ssGame = SuperstarsMiniGame.init;
        ssResults = null;
        ssDuelists = null;
        if (wasActive) sendSuperstarsInfo();
    }

    void sendSuperstarsInfo() {
        struct SuperstarsPlayer {
            int player;
            Character chr;
            PanelColor color;
            bool cpu;
            bool participant;
        }

        struct SuperstarsInfo {
            immutable type = "superstars";
            string game;
            MiniGameType category;
            bool coin;
            bool bowser;
            SuperstarsPlayer[] players;
            bool submitted;
        }

        SuperstarsInfo msg;
        if (ssPhase != SuperstarsPhase.NONE) {
            msg.game = ssGame.fullName;
            msg.category = ssType;
            msg.coin = ssGame.isCoinMiniGame;
            msg.bowser = ssGame.isBowserMiniGame;
            msg.submitted = (ssResults !is null);
            players.each!((p) {
                SuperstarsPlayer sp;
                sp.player = p.index + 1;
                sp.chr = p.data.character;
                sp.color = (p.panel.color <= PanelColor.max ? p.panel.color : PanelColor.NONE);
                sp.cpu = p.isCPU;
                sp.participant = (ssType != MiniGameType.DUEL || ssDuelists.canFind(p.index));
                msg.players ~= sp;
            });
        }

        sendMessage(msg.toJSON());
    }

    override void onMessage(string msg) {
        super.onMessage(msg);

        if (ssPhase == SuperstarsPhase.NONE && !config.superstarsMiniGames) return;

        auto json = parseJSON(msg);

        switch (json.object["type"].str) {
            case "cards": // Sent when (re)connecting, so make sure the Bingo page knows about the current mini-game
                if (ssPhase != SuperstarsPhase.NONE) sendSuperstarsInfo();
                break;

            case "superstars-results":
                auto results = json.fromJSON!SuperstarsResults();
                if (ssPhase == SuperstarsPhase.NONE || results.game != ssGame.fullName) {
                    warning("Ignoring Superstars results for ", results.game, " (current mini-game: ", ssGame.fullName, ")");
                    return;
                }
                if (!results.isValid(ssType, ssDuelists)) {
                    warning("Ignoring invalid Superstars results: ", msg);
                    return;
                }
                ssResults = new SuperstarsResults;
                *ssResults = results;
                info("Received Superstars results for ", ssGame.fullName);
                sendSuperstarsInfo();
                break;

            default:
                break;
        }
    }

    override void onInput(int port, InputData* input) {
        super.onInput(port, input);

        if (ssPhase != SuperstarsPhase.WAITING) return;

        // Nobody can close the message until results are entered, then press A to close it
        input.value = 0;
        if (ssResults && (frame / 4) % 2 == 0) {
            input.buttons = 0x0080; // A
        }
    }

    override bool isPlayable(Character c) const {
        return c >= Character.MARIO && c <= Character.DAISY;
    }

    override bool overrideItems(Player p, string[] names) {
        Item[] items;
        try {
            items = names.map!(n => n.to!Item).array;
        } catch (ConvException) {
            return false;
        }
        if (items.canFind(Item.NONE)) return false;

        iota(3).each!(i => p.data.items[i] = (i < items.length ? items[i] : Item.NONE)); // The game keeps them packed
        return true;
    }

    override void addPlayerItems(Player player, ref JSONValue msg) {
        Item[] items;
        iota(3).filter!(i => player.data.items[i] != Item.NONE).each!(i => items ~= player.data.items[i]);
        msg["items"] = items.toJSON();
        msg["itemSlots"] = JSONValue(3);
    }

    override void watchPlayerItems(Player p) {
        iota(3).each!((j) {
            p.data.items[j].onWrite((ref Item item) {
                if (!isScoreScene(data.currentScene)) return;
                if (item == p.data.items[j]) return;

                p.data.items[j] = item;

                sendPlayerInfo(p);
            });
        });
    }
}

extern (C) {
    string getName() {
        return "Mario Party 3";
    }

    int startup() {
        pluginFactory = (name, hash) => new MarioParty3(name, hash);

        return 0;
    }
}

enum Item : byte {
    NONE             =   -1,
    MUSHROOM         = 0x00,
    SKELETON_KEY     = 0x01,
    POISON_MUSHROOM  = 0x02,
    REVERSE_MUSHROOM = 0x03,
    CELLULAR_SHOPPER = 0x04,
    WARP_BLOCK       = 0x05,
    PLUNDER_CHEST    = 0x06,
    BOWSER_PHONE     = 0x07,
    DUELING_GLOVE    = 0x08,
    LUCKY_LAMP       = 0x09,
    GOLDEN_MUSHROOM  = 0x0A,
    BOO_BELL         = 0x0B,
    BOO_REPELLANT    = 0x0C,
    BOWSER_SUIT      = 0x0D,
    MAGIC_LAMP       = 0x0E,
    KOOPA_KARD       = 0x0F,
    BARTER_BOX       = 0x10,
    LUCKY_CHARM      = 0x11,
    WACKY_WATCH      = 0x12
}

enum CPUDifficulty : byte {
    EASY       = 0,
    NORMAL     = 1,
    HARD       = 2,
    SUPER_HARD = 3
}

enum ChancePrize : byte {
    UNDEFINED = -1,
    COINS_ALL =  0,
    COINS_30  =  1,
    COINS_20  =  2,
    COINS_10  =  3,
    COINS_1   =  4, 
    STARS_ALL =  5,
    STARS_3   =  6,
    STARS_2   =  7,
    STARS_1   =  8
}

enum Scene : uint {
    BOOT                     =   0,
    HAND_LINE_AND_SINKER     =   1,
    COCONUT_CONK             =   2,
    SPOTLIGHT_SWIM           =   3,
    BOULDER_BALL             =   4,
    CRAZY_COGS               =   5,
    HIDE_AND_SNEAK           =   6,
    RIDICULOUS_RELAY         =   7,
    THWOMP_PULL              =   8,
    RIVER_RAIDERS            =   9,
    TIDAL_TOSS               =  10,
    EATSA_PIZZA              =  11,
    BABY_BOWSER_BROADSIDE    =  12,
    PUMP_PUMP_AND_AWAY       =  13,
    HYPER_HYDRANTS           =  14,
    PICKING_PANIC            =  15,
    COSMIC_COASTER           =  16,
    PUDDLE_PADDLE            =  17,
    ETCH_N_CATCH             =  18,
    LOG_JAM                  =  19,
    SLOT_SYNCH               =  20,
    TREADMILL_GRILL          =  21,
    TOADSTOOL_TITAN          =  22,
    ACES_HIGH                =  23,
    BOUNCE_N_TROUNCE         =  24,
    ICE_RINK_RISK            =  25,
    LOCKED_OUT               =  26,
    CHIP_SHOT_CHALLENGE      =  27,
    PARASOL_PLUMMET          =  28,
    MESSY_MEMORY             =  29,
    PICTURE_IMPERFECT        =  30,
    MARIOS_PUZZLE_PARTY      =  31,
    THE_BEAT_GOES_ON         =  32,
    MPIQ                     =  33,
    CURTAIN_CALL             =  34,
    WATER_WHIRLED            =  35,
    FRIGID_BRIDGES           =  36,
    AWFUL_TOWER              =  37,
    CHEEP_CHEEP_CHASE        =  38,
    PIPE_CLEANERS            =  39,
    SNOWBALL_SUMMIT          =  40,
    ALL_FIRED_UP             =  41,
    STACKED_DECK             =  42,
    THREE_DOOR_MONTY         =  43,
    ROCKIN_RACEWAY           =  44,
    MERRY_GO_CHOMP           =  45,
    SLAP_DOWN                =  46,
    STORM_CHASERS            =  47,
    EYE_SORE                 =  48,
    VINE_WITH_ME             =  49,
    POPGUN_PICK_OFF          =  50,
    END_OF_THE_LINE          =  51,
    BOWSER_TOSS              =  52,
    BABY_BOWSER_BONKERS      =  53,
    MOTOR_ROOTER             =  54,
    SILLY_SCREWS             =  55,
    CROWD_COVER              =  56,
    TICK_TOCK_HOP            =  57,
    FOWL_PLAY                =  58,
    WINNERS_WHEEL            =  59,
    HEY_BATTER_BATTER        =  60,
    BOBBING_BOW_LOONS        =  61,
    DORRIE_DIP               =  62,
    SWINGING_WITH_SHARKS     =  63,
    SWING_N_SWIPE            =  64,
    STARDUST_BATTLE          =  65,
    GAME_GUYS_ROULETTE       =  66,
    GAME_GUYS_LUCKY_7        =  67,
    GAME_GUYS_MAGIC_BOXES    =  68,
    GAME_GUYS_SWEET_SURPRISE =  69,
    DIZZY_DINGHIES           =  70,
    TRANSITION               =  71,
    CHILLY_WATERS_BOARD      =  72,
    DEEP_BLOOBER_SEA_BOARD   =  73,
    SPINY_DESERT_BOARD       =  74,
    WOODY_WOODS_BOARD        =  75,
    CREEPY_CAVERN_BOARD      =  76,
    WALUIGIS_ISLAND_BOARD    =  77,
    FINISH_BOARD             =  79,
    BOWSER_EVENT             =  80,
    LAST_FIVE_TURNS          =  81,
    GENIE                    =  82,
    START_BOARD              =  83,
    START_BOARD_TUTORIAL     =  84, // START_BOARD's tutorial version
    FINAL_RESULTS            =  85,
    OPENING_CREDITS          =  88,
    DUEL_TRANSITION          =  90, // Duel mode version of TRANSITION
    GATE_GUY_BOARD           =  91,
    ARROWHEAD_BOARD          =  92,
    PIPESQUEAK_BOARD         =  93,
    BLOWHARD_BOARD           =  94,
    MR_MOVER_BOARD           =  95,
    BACKTRACK_BOARD          =  96,
    DUEL_FINISH_BOARD        =  98, // Duel mode version of FINISH_BOARD
    DUEL_FINAL_RESULTS       =  99, // Duel mode version of FINAL_RESULTS
    START_DUEL_BOARD         = 100, // Duel mode version of START_BOARD
    START_DUEL_BOARD_TUTORIAL = 101, // START_DUEL_BOARD's tutorial version
    STORY_DEBUG              = 102,
    MINI_GAME_ROOM_RETRY     = 104,
    MINI_GAME_ROOM           = 105,
    CHANCE_TIME              = 106,
    MINI_GAME_RULES          = 112,
    MINI_GAME_RESULTS        = 113,
    GAMBLE_GAME_RESULTS      = 114,
    DUEL_GAME_RESULTS        = 115,
    BATTLE_GAME_RESULTS      = 116,
    STORY_TRANSITION         = 117, // Story mode version of TRANSITION
    MESSAGE_CHECK            = 118, // Debug
    CASTLE_GROUNDS           = 119,
    GAME_SETUP               = 120,
    FILE_SELECTION           = 121,
    TITLE_SCREEN             = 122,
    PEACHS_CASTLE            = 123,
    STAFF_CREDITS            = 124,
    STORY_RESULTS            = 125 // Story mode results
}

enum MiniGame : ubyte {
    HAND_LINE_AND_SINKER     =  1,
    COCONUT_CONK             =  2,
    SPOTLIGHT_SWIM           =  3,
    BOULDER_BALL             =  4,
    CRAZY_COGS               =  5,
    HIDE_AND_SNEAK           =  6,
    RIDICULOUS_RELAY         =  7,
    THWOMP_PULL              =  8,
    RIVER_RAIDERS            =  9,
    TIDAL_TOSS               = 10,
    EATSA_PIZZA              = 11,
    BABY_BOWSER_BROADSIDE    = 12,
    PUMP_PUMP_AND_AWAY       = 13,
    HYPER_HYDRANTS           = 14,
    PICKING_PANIC            = 15,
    COSMIC_COASTER           = 16,
    PUDDLE_PADDLE            = 17,
    ETCH_N_CATCH             = 18,
    LOG_JAM                  = 19,
    SLOT_SYNCH               = 20,
    TREADMILL_GRILL          = 21,
    TOADSTOOL_TITAN          = 22,
    ACES_HIGH                = 23,
    BOUNCE_N_TROUNCE         = 24,
    ICE_RINK_RISK            = 25,
    LOCKED_OUT               = 26,
    CHIP_SHOT_CHALLENGE      = 27,
    PARASOL_PLUMMET          = 28,
    MESSY_MEMORY             = 29,
    PICTURE_IMPERFECT        = 30,
    MARIOS_PUZZLE_PARTY      = 31,
    THE_BEAT_GOES_ON         = 32,
    MPIQ                     = 33,
    CURTAIN_CALL             = 34,
    WATER_WHIRLED            = 35,
    FRIGID_BRIDGES           = 36,
    AWFUL_TOWER              = 37,
    CHEEP_CHEEP_CHASE        = 38,
    PIPE_CLEANERS            = 39,
    SNOWBALL_SUMMIT          = 40,
    ALL_FIRED_UP             = 41,
    STACKED_DECK             = 42,
    THREE_DOOR_MONTY         = 43,
    ROCKIN_RACEWAY           = 44,
    MERRY_GO_CHOMP           = 45,
    SLAP_DOWN                = 46,
    STORM_CHASERS            = 47,
    EYE_SORE                 = 48,
    VINE_WITH_ME             = 49,
    POPGUN_PICK_OFF          = 50,
    END_OF_THE_LINE          = 51,
    BOWSER_TOSS              = 52,
    BABY_BOWSER_BONKERS      = 53,
    MOTOR_ROOTER             = 54,
    SILLY_SCREWS             = 55,
    CROWD_COVER              = 56,
    TICK_TOCK_HOP            = 57,
    FOWL_PLAY                = 58,
    WINNERS_WHEEL            = 59,
    HEY_BATTER_BATTER        = 60,
    BOBBING_BOW_LOONS        = 61,
    DORRIE_DIP               = 62,
    SWINGING_WITH_SHARKS     = 63,
    SWING_N_SWIPE            = 64,
    CHANCE_TIME              = 65,
    STARDUST_BATTLE          = 66,
    GAME_GUYS_ROULETTE       = 67,
    GAME_GUYS_LUCKY_7        = 68,
    GAME_GUYS_MAGIC_BOXES    = 69,
    GAME_GUYS_SWEET_SURPRISE = 70,
    DIZZY_DINGHIES           = 71,
    MARIOS_PUZZLE_PARTY_PRO  = 72,
}

enum MiniGameType {
    ONE_V_THREE,
    TWO_V_TWO,
    FOUR_PLAYER,
    BATTLE,
    DUEL,
    ITEM,
    GAMBLE,
    SPECIAL
}

enum BonusType {
    MINI_GAME,
    COIN,
    HAPPENING,
    RED,
    BLUE,
    CHANCE,
    BOWSER,
    BATTLE,
    ITEM,
    BANK,
    GAME_GUY,
    LUCKY
}

enum BowserEventType : int {
    UNKNOWN           = -1,
    COINS_FOR_BOWSER  =  0,
    COIN_POTLUCK      =  1,
    SUIT_GIVEAWAY     =  2,
    PHONE_GIVEAWAY    =  3,
    CURSE             =  4,
    REVERSE_CURSE     =  5,
    SHUFFLE           =  6,
    REVOLUTION        =  7,
    BOWSER_RAN_AWAY_1 =  8,
    BOWSER_RAN_AWAY_2 =  9
}

enum SFX {
    WINNING_A_STAR       = 0x0262,
    LOSING_A_MINI_GAME   = 0x026B,
    GETTING_AN_ITEM      = 0x0274,
    WINNING_A_BOARD_GAME = 0x027D,
    DESPAIR_1            = 0x0286,
    WINNING_A_MINI_GAME  = 0x028F,
    DESPAIR_2            = 0x02AB,
    BEING_CHOSEN         = 0x02B4,
    TAUNT                = 0x02BD,
    SUPERSTAR            = 0x02C6
}

enum GamePhase {
    EARLY = 0,
    MID   = 1,
    END   = 2
}

enum MessageSpeed : ubyte {
    FAST   = 0,
    NORMAL = 1,
    SLOW   = 2
}

MiniGameType type(MiniGame game) {
    switch (game) {
        case 26: return MiniGameType.BATTLE;
        case 44: return MiniGameType.FOUR_PLAYER;
        default:
    }

    switch (game) {
        case  1: .. case 10: return MiniGameType.ONE_V_THREE;
        case 11: .. case 20: return MiniGameType.TWO_V_TWO;
        case 21: .. case 40: return MiniGameType.FOUR_PLAYER;
        case 41: .. case 48: return MiniGameType.BATTLE;
        case 49: .. case 58: return MiniGameType.DUEL;
        case 59: .. case 64: return MiniGameType.ITEM;
        case 67: .. case 70: return MiniGameType.GAMBLE;
        default:             return MiniGameType.SPECIAL;
    }
}

enum SUPERSTARS_NAME_SLOT_SIZE = 64;

struct SuperstarsResults {
    string game;
    int[] coins;      // Per player (1-vs-3, 2-vs-2 and 4-player mini-games)
    int[] ranks;      // Per player, 1-4 (battle mini-games)
    int winner = -1;  // Player number 1-4, or 0 for a tie (duel mini-games)

    bool isValid(MiniGameType type, const uint[] duelists) const {
        switch (type) {
            case MiniGameType.BATTLE:
                return ranks.length == 4 && ranks.all!(r => 1 <= r && r <= 4);
            case MiniGameType.DUEL:
                return winner == 0 || duelists.canFind(winner - 1) || (duelists.empty && 1 <= winner && winner <= 4);
            case MiniGameType.ONE_V_THREE:
            case MiniGameType.TWO_V_TWO:
            case MiniGameType.FOUR_PLAYER:
                return coins.length == 4 && coins.all!(c => 0 <= c && c <= 999);
            default:
                return false;
        }
    }
}

// Mario Party Superstars combines battle mini-games into its 4-player list
MiniGameType type(SuperstarsMiniGame game) {
    switch (game) {
        case  1: .. case 53: return MiniGameType.FOUR_PLAYER;
        case 54: .. case 71: return MiniGameType.ONE_V_THREE;
        case 72: .. case 89: return MiniGameType.TWO_V_TWO;
        case 90: .. case 94: return MiniGameType.DUEL;
        default:             assert(0, "Invalid Superstars mini-game");
    }
}

MiniGameType superstarsQueueKey(MiniGameType type) {
    return type == MiniGameType.BATTLE ? MiniGameType.FOUR_PLAYER : type;
}

SuperstarsMiniGame[] superstarsMiniGames(MiniGameType type) {
    return [EnumMembers!SuperstarsMiniGame].filter!(g => g.type == superstarsQueueKey(type)).array;
}

// Mini-games where players collect coins
bool isCoinMiniGame(SuperstarsMiniGame game) {
    switch (game) {
        case SuperstarsMiniGame.HAMMER_DROP:
        case SuperstarsMiniGame.CAST_AWAYS:
        case SuperstarsMiniGame.PARASOL_PLUMMET:
        case SuperstarsMiniGame.X_RAY_PAYDAY:
        case SuperstarsMiniGame.QUICKSAND_CACHE:
        case SuperstarsMiniGame.RIVER_RAIDERS:
        case SuperstarsMiniGame.MONEY_BELTS:
        case SuperstarsMiniGame.PUDDLE_PADDLE:
        case SuperstarsMiniGame.CASHAPULT:
        case SuperstarsMiniGame.WINNER_OR_DINNER:
            return true;
        default:
            return false;
    }
}

// Width in pixels of one line of message window text, the way the game sizes its windows (func_800605A4):
// each character's advance comes from the font width table at 0x800A2194, except <WIDE_SPACE> (0x1A), a 10-pixel space.
int messageTextWidth(string text) {
    int width = 0;
    auto t = formatText(text);
    for (size_t i = 0; i < t.length; i++) {
        auto b = cast(ubyte)t[i];
        if (b == 0x18) i++; // <SKIP_NEXT> skips the next byte
        width += (b == 0x1A ? 10 : (0x800A2194 + b).val!ubyte);
    }
    return width;
}

// Breaks lines at spaces so none is wider than maxWidth pixels (when possible); existing line breaks are kept.
// Outlined phrases (like "<OUTLINE>Game Guy Spaces<NO_OUTLINE>") stay on one line, as in the game's own text.
string wrapMessage(string text, int maxWidth) {
    string kept;
    bool outlined;
    for (size_t i = 0; i < text.length; i++) {
        if (text[i..$].startsWith("<OUTLINE>")) outlined = true;
        if (text[i..$].startsWith("<NO_OUTLINE>")) outlined = false;
        kept ~= (outlined && text[i] == ' ') ? "<SPACE>" : text[i..i + 1]; // <SPACE> looks the same, but isn't split
    }
    text = kept;

    string[] lines;
    foreach (paragraph; text.split("\n")) {
        string line;
        foreach (word; paragraph.split(" ")) {
            auto longer = line.empty ? word : line ~ " " ~ word;
            if (!line.empty && messageTextWidth(longer) > maxWidth) {
                lines ~= line;
                line = word;
            } else {
                line = longer;
            }
        }
        lines ~= line;
    }
    return lines.join("\n");
}

// Blank space of (about) the given width, made of 4-pixel spaces and 10-pixel <WIDE_SPACE> spaces
string messageSpace(int pixels) {
    if (pixels < 2) return "";
    pixels = (pixels + 1) / 2 * 2; // Every combination of the two is even
    foreach_reverse (wide; 0..pixels / 10 + 1) {
        auto rest = pixels - wide * 10;
        if (rest % 4 == 0) return "<WIDE_SPACE>".replicate(wide) ~ " ".replicate(rest / 4);
    }
    return " ".replicate((pixels + 2) / 4); // 2 or 6: the closest is 4 or 8
}

// Mini-games played against Bowser
bool isBowserMiniGame(SuperstarsMiniGame game) {
    switch (game) {
        case SuperstarsMiniGame.FACE_LIFT:
        case SuperstarsMiniGame.DARK_N_CRISPY:
        case SuperstarsMiniGame.PIT_BOSS:
            return true;
        default:
            return false;
    }
}

// Coin mini-games make no sense as battles, so battles skip the 4-player coin mini-games
bool isAllowedSuperstarsMiniGame(SuperstarsMiniGame game, MiniGameType type) {
    return type != MiniGameType.BATTLE || !game.isCoinMiniGame;
}

enum SuperstarsMiniGame : ubyte {
    MUSHROOM_MIX_UP     =  1,
    BOMBS_AWAY          =  2,
    SHY_GUY_SAYS        =  3,
    CRAZY_CUTTERS       =  4,
    TIPSY_TOURNEY       =  5,
    FACE_LIFT           =  6,
    HAMMER_DROP         =  7,
    CAST_AWAYS          =  8,
    DIZZY_DANCING       =  9,
    BUMPER_BALLS        = 10,
    HOT_ROPE_JUMP       = 11,
    TREAD_CAREFULLY     = 12,
    BUMPER_BALLOON_CARS = 13,
    SNEAK_N_SNORE       = 14,
    MECHA_MARATHON      = 15,
    SLOT_CAR_DERBY      = 16,
    BOWSER_S_BIG_BLAST  = 17,
    ROLL_CALL           = 18,
    HONEYCOMB_HAVOC     = 19,
    SNOWBALL_SUMMIT     = 20,
    ICE_RINK_RISK       = 21,
    BOUNCE_N_TROUNCE    = 22,
    STORM_CHASERS       = 23,
    MUSH_PIT            = 24,
    CHEEP_CHEEP_CHASE   = 25,
    CHIP_SHOT_CHALLENGE = 26,
    ROCKIN_RACEWAY      = 27,
    MESSY_MEMORY        = 28,
    PARASOL_PLUMMET     = 29,
    TRACE_RACE          = 30,
    BOOKSQUIRM          = 31,
    PATHS_OF_PERIL      = 32,
    DINGER_DERBY        = 33,
    LEAF_LEAP           = 34,
    PUSHY_PENGUINS      = 35,
    CONEY_ISLAND        = 36,
    BILL_BLASTERS       = 37,
    NIGHT_LIGHT_FRIGHT  = 38,
    LATER_SKATER        = 39,
    CATCH_YOU_LETTER    = 40,
    TRAP_EASE_ARTIST    = 41,
    WHAT_GOES_UP        = 42,
    SNOW_WHIRLED        = 43,
    DARK_N_CRISPY       = 44,
    PIT_BOSS            = 45,
    X_RAY_PAYDAY        = 46,
    MONTY_S_REVENGE     = 47,
    THE_FINAL_COUNTDOWN = 48,
    POKEY_PUMMEL        = 49,
    MANOR_OF_ESCAPE     = 50,
    GOOMBA_SPOTTING     = 51,
    FLASH_FORWARD       = 52,
    RAPID_RIVER_RACE    = 53,
    PIRANHA_S_PURSUIT   = 54,
    TUG_O_WAR           = 55,
    ARCHER_IVAL         = 56,
    LOOK_AWAY           = 57,
    QUICKSAND_CACHE     = 58,
    TIDAL_TOSS          = 59,
    BOULDER_BALL        = 60,
    COCONUT_CONK        = 61,
    SPOTLIGHT_SWIM      = 62,
    HIDE_AND_SNEAK      = 63,
    RIVER_RAIDERS       = 64,
    GOOOOOOOAL          = 65,
    MONEY_BELTS         = 66,
    SQUARED_AWAY        = 67,
    TUBE_IT_OR_LOSE_IT  = 68,
    POGO_A_GO_GO        = 69,
    TACKLE_TAKEDOWN     = 70,
    SKEWER_SCURRY       = 71,
    BOBSLED_RUN         = 72,
    HANDCAR_HAVOC       = 73,
    DUNGEON_DASH        = 74,
    SPEED_HOCKEY        = 75,
    BALLOON_BURST       = 76,
    CAKE_FACTORY        = 77,
    SKY_PILOTS          = 78,
    ETCH_N_CATCH        = 79,
    PICKING_PANIC       = 80,
    EATSA_PIZZA         = 81,
    PUDDLE_PADDLE       = 82,
    DUNGEON_DUOS        = 83,
    REVERS_A_BOMB       = 84,
    BURNSTILE           = 85,
    ROCKY_ROAD          = 86,
    CASHAPULT           = 87,
    PAINT_MISBEHAVIN    = 88,
    WINNER_OR_DINNER    = 89,
    TICKTOCK_HOP        = 90,
    VINE_WITH_ME        = 91,
    MOTOR_ROOTER        = 92,
    MASS_METEOR         = 93,
    SPIN_DOCTOR         = 94
}

alias fullName = me.timz.n64.marioparty.fullName; // Keep fullName(Character) visible alongside this overload

string fullName(SuperstarsMiniGame game) pure {
    final switch (game) {
        case SuperstarsMiniGame.MUSHROOM_MIX_UP:     return "Mushroom Mix-Up";
        case SuperstarsMiniGame.BOMBS_AWAY:          return "Bombs Away";
        case SuperstarsMiniGame.SHY_GUY_SAYS:        return "Shy Guy Says";
        case SuperstarsMiniGame.CRAZY_CUTTERS:       return "Crazy Cutters";
        case SuperstarsMiniGame.TIPSY_TOURNEY:       return "Tipsy Tourney";
        case SuperstarsMiniGame.FACE_LIFT:           return "Face-Lift";
        case SuperstarsMiniGame.HAMMER_DROP:         return "Hammer Drop";
        case SuperstarsMiniGame.CAST_AWAYS:          return "Cast Aways";
        case SuperstarsMiniGame.DIZZY_DANCING:       return "Dizzy Dancing";
        case SuperstarsMiniGame.BUMPER_BALLS:        return "Bumper Balls";
        case SuperstarsMiniGame.HOT_ROPE_JUMP:       return "Hot Rope Jump";
        case SuperstarsMiniGame.TREAD_CAREFULLY:     return "Tread Carefully";
        case SuperstarsMiniGame.BUMPER_BALLOON_CARS: return "Bumper Balloon Cars";
        case SuperstarsMiniGame.SNEAK_N_SNORE:       return "Sneak 'n' Snore";
        case SuperstarsMiniGame.MECHA_MARATHON:      return "Mecha Marathon";
        case SuperstarsMiniGame.SLOT_CAR_DERBY:      return "Slot-Car Derby";
        case SuperstarsMiniGame.BOWSER_S_BIG_BLAST:  return "Bowser's Big Blast";
        case SuperstarsMiniGame.ROLL_CALL:           return "Roll Call";
        case SuperstarsMiniGame.HONEYCOMB_HAVOC:     return "Honeycomb Havoc";
        case SuperstarsMiniGame.SNOWBALL_SUMMIT:     return "Snowball Summit";
        case SuperstarsMiniGame.ICE_RINK_RISK:       return "Ice-Rink Risk";
        case SuperstarsMiniGame.BOUNCE_N_TROUNCE:    return "Bounce 'n' Trounce";
        case SuperstarsMiniGame.STORM_CHASERS:       return "Storm Chasers";
        case SuperstarsMiniGame.MUSH_PIT:            return "Mush Pit";
        case SuperstarsMiniGame.CHEEP_CHEEP_CHASE:   return "Cheep Cheep Chase";
        case SuperstarsMiniGame.CHIP_SHOT_CHALLENGE: return "Chip-Shot Challenge";
        case SuperstarsMiniGame.ROCKIN_RACEWAY:      return "Rockin' Raceway";
        case SuperstarsMiniGame.MESSY_MEMORY:        return "Messy Memory";
        case SuperstarsMiniGame.PARASOL_PLUMMET:     return "Parasol Plummet";
        case SuperstarsMiniGame.TRACE_RACE:          return "Trace Race";
        case SuperstarsMiniGame.BOOKSQUIRM:          return "Booksquirm";
        case SuperstarsMiniGame.PATHS_OF_PERIL:      return "Paths of Peril";
        case SuperstarsMiniGame.DINGER_DERBY:        return "Dinger Derby";
        case SuperstarsMiniGame.LEAF_LEAP:           return "Leaf Leap";
        case SuperstarsMiniGame.PUSHY_PENGUINS:      return "Pushy Penguins";
        case SuperstarsMiniGame.CONEY_ISLAND:        return "Coney Island";
        case SuperstarsMiniGame.BILL_BLASTERS:       return "Bill Blasters";
        case SuperstarsMiniGame.NIGHT_LIGHT_FRIGHT:  return "Night-Light Fright";
        case SuperstarsMiniGame.LATER_SKATER:        return "Later Skater";
        case SuperstarsMiniGame.CATCH_YOU_LETTER:    return "Catch You Letter";
        case SuperstarsMiniGame.TRAP_EASE_ARTIST:    return "Trap Ease Artist";
        case SuperstarsMiniGame.WHAT_GOES_UP:        return "What Goes Up...";
        case SuperstarsMiniGame.SNOW_WHIRLED:        return "Snow Whirled";
        case SuperstarsMiniGame.DARK_N_CRISPY:       return "Dark 'n' Crispy";
        case SuperstarsMiniGame.PIT_BOSS:            return "Pit Boss";
        case SuperstarsMiniGame.X_RAY_PAYDAY:        return "X-Ray Payday";
        case SuperstarsMiniGame.MONTY_S_REVENGE:     return "Monty's Revenge";
        case SuperstarsMiniGame.THE_FINAL_COUNTDOWN: return "The Final Countdown";
        case SuperstarsMiniGame.POKEY_PUMMEL:        return "Pokey Pummel";
        case SuperstarsMiniGame.MANOR_OF_ESCAPE:     return "Manor of Escape";
        case SuperstarsMiniGame.GOOMBA_SPOTTING:     return "Goomba Spotting";
        case SuperstarsMiniGame.FLASH_FORWARD:       return "Flash Forward";
        case SuperstarsMiniGame.RAPID_RIVER_RACE:    return "Rapid River Race";
        case SuperstarsMiniGame.PIRANHA_S_PURSUIT:   return "Piranha's Pursuit";
        case SuperstarsMiniGame.TUG_O_WAR:           return "Tug o' War";
        case SuperstarsMiniGame.ARCHER_IVAL:         return "Archer-ival";
        case SuperstarsMiniGame.LOOK_AWAY:           return "Look Away";
        case SuperstarsMiniGame.QUICKSAND_CACHE:     return "Quicksand Cache";
        case SuperstarsMiniGame.TIDAL_TOSS:          return "Tidal Toss";
        case SuperstarsMiniGame.BOULDER_BALL:        return "Boulder Ball";
        case SuperstarsMiniGame.COCONUT_CONK:        return "Coconut Conk";
        case SuperstarsMiniGame.SPOTLIGHT_SWIM:      return "Spotlight Swim";
        case SuperstarsMiniGame.HIDE_AND_SNEAK:      return "Hide-and-Sneak";
        case SuperstarsMiniGame.RIVER_RAIDERS:       return "River Raiders";
        case SuperstarsMiniGame.GOOOOOOOAL:          return "GOOOOOOOAL!!";
        case SuperstarsMiniGame.MONEY_BELTS:         return "Money Belts";
        case SuperstarsMiniGame.SQUARED_AWAY:        return "Squared Away";
        case SuperstarsMiniGame.TUBE_IT_OR_LOSE_IT:  return "Tube It or Lose It";
        case SuperstarsMiniGame.POGO_A_GO_GO:        return "Pogo-a-Go-Go";
        case SuperstarsMiniGame.TACKLE_TAKEDOWN:     return "Tackle Takedown";
        case SuperstarsMiniGame.SKEWER_SCURRY:       return "Skewer Scurry";
        case SuperstarsMiniGame.BOBSLED_RUN:         return "Bobsled Run";
        case SuperstarsMiniGame.HANDCAR_HAVOC:       return "Handcar Havoc";
        case SuperstarsMiniGame.DUNGEON_DASH:        return "Dungeon Dash";
        case SuperstarsMiniGame.SPEED_HOCKEY:        return "Speed Hockey";
        case SuperstarsMiniGame.BALLOON_BURST:       return "Balloon Burst";
        case SuperstarsMiniGame.CAKE_FACTORY:        return "Cake Factory";
        case SuperstarsMiniGame.SKY_PILOTS:          return "Sky Pilots";
        case SuperstarsMiniGame.ETCH_N_CATCH:        return "Etch 'n' Catch";
        case SuperstarsMiniGame.PICKING_PANIC:       return "Picking Panic";
        case SuperstarsMiniGame.EATSA_PIZZA:         return "Eatsa Pizza";
        case SuperstarsMiniGame.PUDDLE_PADDLE:       return "Puddle Paddle";
        case SuperstarsMiniGame.DUNGEON_DUOS:        return "Dungeon Duos";
        case SuperstarsMiniGame.REVERS_A_BOMB:       return "Revers-a-Bomb";
        case SuperstarsMiniGame.BURNSTILE:           return "Burnstile";
        case SuperstarsMiniGame.ROCKY_ROAD:          return "Rocky Road";
        case SuperstarsMiniGame.CASHAPULT:           return "Cashapult";
        case SuperstarsMiniGame.PAINT_MISBEHAVIN:    return "Paint Misbehavin'";
        case SuperstarsMiniGame.WINNER_OR_DINNER:    return "Winner or Dinner";
        case SuperstarsMiniGame.TICKTOCK_HOP:        return "Ticktock Hop";
        case SuperstarsMiniGame.VINE_WITH_ME:        return "Vine with Me";
        case SuperstarsMiniGame.MOTOR_ROOTER:        return "Motor Rooter";
        case SuperstarsMiniGame.MASS_METEOR:         return "Mass Meteor";
        case SuperstarsMiniGame.SPIN_DOCTOR:         return "Spin Doctor";
    }
}

bool isValid(Item item) {
    return Item.MUSHROOM <= item && item <= Item.WACKY_WATCH;
}

bool isRare(Item item) {
    return Item.KOOPA_KARD <= item && item <= Item.WACKY_WATCH;
}

bool isCommon(Item item) {
    return isValid(item) && !isRare(item);
}

// The Lucky Space texture: 32x32 pixels, 4 bytes each (red, green, blue, alpha), from textures/mp3-lucky-space.rgba
immutable ubyte[] LUCKY_SPACE_TEXTURE = cast(immutable(ubyte)[])import("mp3-lucky-space.rgba");
static assert(LUCKY_SPACE_TEXTURE.length == 32 * 32 * 4);

// The gold space (a revealed Hidden Block) texture: 32x32 pixels, 4 bytes each (red, green, blue, alpha), from textures/mp3-gold-space.rgba
immutable ubyte[] GOLD_SPACE_TEXTURE = cast(immutable(ubyte)[])import("mp3-gold-space.rgba");
static assert(GOLD_SPACE_TEXTURE.length == 32 * 32 * 4);
