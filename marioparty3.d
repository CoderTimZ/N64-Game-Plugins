module me.timz.n64.marioparty3;

import me.timz.n64.marioparty;
import me.timz.n64.plugin;
import std.algorithm;
import std.random;
import std.range;
import std.conv;
import std.traits;
import std.stdio;

class PlayerConfig {
    int team;
    //bool reverse;

    this() {}
    this(int team) { this.team = team; }
}

class MarioParty3Config : MarioPartyConfig {
    bool replaceChanceSpaces = true;
    //bool moveInAnyDirection = true;
    MiniGame[] blockedMiniGames;
    PlayerConfig[] players = [
        new PlayerConfig(0),
        new PlayerConfig(0),
        new PlayerConfig(1),
        new PlayerConfig(1)
    ];
}

union Space {
    static enum Type : ubyte {
        BLUE     = 0x1,
        CHANCE   = 0x5,
        GAME_GUY = 0xF
    }
}

union Player {
    ubyte[56] _data;
    mixin Field!(0x02, ubyte, "controller");
    mixin Field!(0x04, ubyte, "flags");
    mixin Field!(0x0A, ushort, "coins");
    mixin Field!(0x0E, ubyte, "stars");
    mixin Field!(0x17, ubyte, "directionFlags");
    mixin Field!(0x18, Arr!(Item, 3), "items");
    mixin Field!(0x1C, Color, "color");
    mixin Field!(0x28, ushort, "gameCoins");
    mixin Field!(0x2A, ushort, "maxCoins");
    mixin Field!(0x2D, ubyte, "redSpaces");
    mixin Field!(0x32, ubyte, "itemSpaces");
}

union Data {
    ubyte[0x400000] memory;
    mixin Field!(0x800D1108, Arr!(Player, 4), "players");
    mixin Field!(0x800CE200, Scene, "currentScene");
    mixin Field!(0x800CD05A, ubyte, "turnLimit");
    mixin Field!(0x800CD05B, ubyte, "currentTurn");
    mixin Field!(0x800CD067, ubyte, "currentPlayerIndex");
    mixin Field!(0x8010570E, ubyte, "numberOfRolls");
    mixin Field!(0x80097650, uint, "randomState");
    mixin Field!(0x80102C58, Ptr!Instruction, "booRoutinePtr");
    mixin Field!(0x800DFE88, Instruction, "chooseGameRoutine");
    mixin Field!(0x800FAB98, Instruction, "duelRoutine");
    mixin Field!(0x8000B198, Instruction, "randomByteRoutine");
    mixin Field!(0x80102C08, Arr!(MiniGame, 5), "miniGameSelection");
}

class MarioParty3 : MarioParty!(MarioParty3Config, Data) {
    this(string name, string hash) {
        super(name, hash);
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
                return true;
            default:
                return false;
        }
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

    override void onStart() {
        super.onStart();

        if (config.teams) {
            data.duelRoutine.addr.onExec({
                if (!isBoardScene()) return;
                teammates(currentPlayer).each!((t) {
                    t.data.coins = 0;
                });
                gpr.ra.onExecOnce({
                    teammates(currentPlayer).each!((t) {
                        t.data.coins = currentPlayer.data.coins;
                    });
                });
            });
        }

        if (config.alwaysDuel) {
            0x800FA854.onExec({ if (isBoardScene()) gpr.v0 = 1; });
        }

        if (config.replaceChanceSpaces) {
            0x800FC594.onExec({ 0x800FC5A4.val!Instruction = 0x10000085; });
            0x800EAEF4.onExec({
                if (isBoardScene() && gpr.v0 == Space.Type.CHANCE) {
                    gpr.v0 = Space.Type.GAME_GUY;
                }
            });
        }

        /*
        if (config.moveInAnyDirection) {
            0x800FD190.onExec({
                writeln(1);
                if (!isBoardScene()) return;
                writeln(2);
                if (currentPlayer.config.reverse) {
                    writeln(3);
                    currentPlayer.directionFlags |= 0x80;
                }
            });
            0x800FD194.onExec({
                if (!isBoardScene()) return;
                currentPlayer.directionFlags |= 0x80;
            });
            players.each!((p) {
                p.directionFlags.onWrite((ref ubyte flags) {
                    if (!isBoardScene()) return;
                    if (flags & 0x80) {
                        p.config.reverse = (flags & 0x01);
                        writeln(currentPlayerIndex, " ", p.config.reverse);
                    }
                });
            });
        }
        */

        if (config.blockedMiniGames.length > 0) {
            MiniGame[][MiniGameType] miniGameList;
            MiniGame[uint][MiniGameType] miniGameScreen;
            0x800DFE90.onExec({
                if (!isBoardScene()) return;
                0x800DFED4.val!Instruction = NOP;
                0x800DFF40.val!Instruction = NOP;
                0x800DFF64.val!Instruction = NOP;
                0x800DFF78.val!Instruction = NOP;
                auto t = (cast(MiniGame)gpr.v0).type;
                miniGameList.require(t, [EnumMembers!MiniGame].filter!(g => g.type == t)
                                                              .filter!(g => !config.blockedMiniGames.canFind(g))
                                                              .array.randomShuffle(random));
                if (gpr.s0 !in miniGameScreen.require(t)) {
                    miniGameScreen[t][gpr.s0] = miniGameList[t].front;
                    miniGameList[t].popFront();
                }
                gpr.v0 = miniGameScreen[t][gpr.s0];
            });
            0x800DF468.onExec({
                if (!isBoardScene()) return;
                auto t = data.miniGameSelection[gpr.v1].type;
                miniGameList[t] ~= miniGameScreen[t][gpr.v1];
                miniGameList[t].swapAt(0, uniform(0, miniGameList[t].length / 3, random));
                miniGameScreen[t][gpr.v1] = miniGameList[t].front;
                miniGameList[t].popFront();
            });
        }
    }
}

shared static this() {
    pluginFactory = (name, hash) => new MarioParty3(name, hash);
}

enum Item : byte {
    NONE = -1
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
    BOBBLING_BOW_LOONS       =  61,
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
    OPENING_CREDITS          =  88,
    MINI_GAME_ROOM_RETRY     = 104,
    MINI_GAME_ROOM           = 105,
    CHANCE_TIME              = 106,
    MINI_GAME_RULES          = 112,
    MINI_GAME_RESULTS        = 113,
    GAMBLE_GAME_RESULTS      = 114,
    BATTLE_GAME_RESULTS      = 116,
    CASTLE_GROUNDS           = 119,
    GAME_SETUP               = 120,
    FILE_SELECTION           = 121,
    TITLE_SCREEN             = 122,
    PEACHS_CASTLE            = 123
}

enum MiniGame : ubyte {
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
    BOBBLING_BOW_LOONS       =  61,
    DORRIE_DIP               =  62,
    SWINGING_WITH_SHARKS     =  63,
    SWING_N_SWIPE            =  64,
    CHANCE_TIME              =  65,
    STARDUST_BATTLE          =  66,
    GAME_GUYS_ROULETTE       =  67,
    GAME_GUYS_LUCKY_7        =  68,
    GAME_GUYS_MAGIC_BOXES    =  69,
    GAME_GUYS_SWEET_SURPRISE =  70,
    DIZZY_DINGHIES           =  71,
    MARIOS_PUZZLE_PARTY_PRO  =  72
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