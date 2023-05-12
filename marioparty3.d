module me.timz.n64.marioparty3;

import me.timz.n64.marioparty;
import me.timz.n64.plugin;
import std.algorithm;
import std.random;
import std.range;
import std.conv;
import std.traits;
import std.stdio;
import std.string;

class PlayerConfig {
    int team;
    //bool reverse;

    this() {}
    this(int team) { this.team = team; }
}

class MarioParty3Config : MarioPartyConfig {
    bool randomBonus = true;
    bool replaceChanceSpaces = true;
    //bool moveInAnyDirection = true;
    bool enhancedTaunts = true;
    bool reduceRepeatMiniGames = true;
    MiniGame[] blockedMiniGames;
    PlayerConfig[] players = [
        new PlayerConfig(1),
        new PlayerConfig(1),
        new PlayerConfig(2),
        new PlayerConfig(2)
    ];
}

union Space {
    static enum Type : ubyte {
        BLUE     = 0x1,
        CHANCE   = 0x5,
        BATTLE   = 0x9,
        BOWSER   = 0xC,
        ITEM     = 0xD,
        STAR     = 0xE,
        GAME_GUY = 0xF
    }
}

union Data {
    ubyte[0x400000] memory;
    mixin Field!(0x800D1108, Arr!(Player, 4), "players");
    mixin Field!(0x800CE200, Scene, "currentScene");
    mixin Field!(0x800CD05A, ubyte, "totalTurns");
    mixin Field!(0x800CD05B, ubyte, "currentTurn");
    mixin Field!(0x800CD067, ubyte, "currentPlayerIndex");
    mixin Field!(0x800CDA7C, Arr!(ushort, 4), "buttons");
    mixin Field!(0x8010570E, ubyte, "numberOfRolls");
    mixin Field!(0x80097650, uint, "randomState");
    mixin Field!(0x80102C58, Ptr!Instruction, "booRoutinePtr");
    mixin Field!(0x800DFE88, Instruction, "chooseGameRoutine");
    mixin Field!(0x800FAB98, Instruction, "duelRoutine");
    mixin Field!(0x800FB624, Instruction, "battleRoutine");
    mixin Field!(0x8000B198, Instruction, "randomByteRoutine");
    mixin Field!(0x80036574, Instruction, "messageBoxLength");
    mixin Field!(0x800365A8, Instruction, "messageBoxChar");
    mixin Field!(0x80009A1C, Instruction, "storeButtonPress");
    mixin Field!(0x8004ACE0, Instruction, "playSFX");
    mixin Field!(0x800F52C4, Instruction, "determineTeams");
    mixin Field!(0x80102C08, Arr!(MiniGame, 5), "miniGameSelection");
    mixin Field!(0x801057E0, Arr!(PlayerCard, 4), "playerCards");
    mixin Field!(0x80108470, Instruction, "loadBonusStat1a");
    mixin Field!(0x801084B4, Instruction, "loadBonusStat1b");
    mixin Field!(0x80108898, Instruction, "loadBonusStat2a");
    mixin Field!(0x801088DC, Instruction, "loadBonusStat2b");
    mixin Field!(0x80108CC0, Instruction, "loadBonusStat3a");
    mixin Field!(0x80108D04, Instruction, "loadBonusStat3b");
}

union Player {
    ubyte[0x38] _data;
    mixin Field!(0x01, ubyte, "cpuDifficulty");
    mixin Field!(0x02, ubyte, "controller");
    mixin Field!(0x04, ubyte, "flags");
    mixin Field!(0x0A, ushort, "coins");
    mixin Field!(0x0E, ubyte, "stars");
    mixin Field!(0x17, ubyte, "directionFlags");
    mixin Field!(0x18, Arr!(Item, 3), "items");
    mixin Field!(0x1C, Color, "color");
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

    uint getBonusStat(BonusType type) {
        final switch (type) {
            case BonusType.MINI_GAME: return miniGameCoins;
            case BonusType.COIN:      return maxCoins;
            case BonusType.HAPPENING: return happeningSpaces;
            case BonusType.UNLUCKY:   return redSpaces;
            case BonusType.BLUE:      return blueSpaces;
            case BonusType.CHANCE:    return chanceSpaces;
            case BonusType.BOWSER:    return bowserSpaces;
            case BonusType.BATTLE:    return battleSpaces;
            case BonusType.ITEM:      return itemSpaces;
            case BonusType.BANK:      return bankSpaces;
            case BonusType.GAMBLING:  return gameGuySpaces;
        }
    }
}

union PlayerCard {
    ubyte[0x6C] _data;
    mixin Field!(0x04, ubyte, "color");
}

immutable BONUS_TEXT = [
    ["\x02\x0FMini=Game Star\x16\x19", "\x02\x0FMini=Game Stars\x16\x19", "has won the most coins\nin Mini=Games"],
    ["\x07\x0FCoin Star\x16\x19",      "\x07\x0FCoin Stars\x16\x19",      "had the most\ncoins at any one time\nduring the game"],
    ["\x05\x0FHappening Star\x16\x19", "\x05\x0FHappening Stars\x16\x19", "landed on the most\n\x05\x0F\xC3 Spaces\x16\x19"],
    ["\x03\x0FUnlucky Star\x16\x19",   "\x03\x0FUnlucky Stars\x16\x19",   "landed on the most\n\x03\x0FRed Spaces\x16\x19"],
    ["\x02\x0FBlue Star\x16\x19",      "\x02\x0FBlue Stars\x16\x19",      "landed on the most\n\x02\x0FBlue Spaces\x16\x19"],
    ["\x05\x0FChance Star\x16\x19",    "\x05\x0FChance Stars\x16\x19",    "landed on the most\n\x05\x0F\xC2 Spaces\x16\x19"],
    ["\x03\x0FBowser Star\x16\x19",    "\x03\x0FBowser Stars\x16\x19",    "landed on the most\n\x03\x0FBowser Spaces\x16\x19"],
    ["\x05\x0FBattle Star\x16\x19",    "\x05\x0FBattle Stars\x16\x19",    "landed on the most\n\x05\x0FBattle Spaces\x16\x19"],
    ["\x05\x0FItem Star\x16\x19",      "\x05\x0FItem Stars\x16\x19",      "landed on the most\n\x05\x0FItem Spaces\x16\x19"],
    ["\x05\x0FBanking Star\x16\x19",   "\x05\x0FBanking Stars\x16\x19",   "landed on the most\n\x05\x0FBank Spaces\x16\x19"],
    ["\x05\x0FGambling Star\x16\x19",  "\x05\x0FGambling Stars\x16\x19",  "landed on the most\n\x05\x0FGame Guy Spaces\x16\x19"]
];

class MarioParty3 : MarioParty!(MarioParty3Config, Data) {
    BonusType[] bonus = [EnumMembers!BonusType];

    this(string name, string hash) {
        super(name, hash);

        if (config.replaceChanceSpaces) {
            bonus = bonus.remove!(b => b == BonusType.CHANCE);
        }
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
            
            data.battleRoutine.addr.onExec({
                if (!isBoardScene()) return;
                players.each!((p) {
                    teammates(p).filter!(t => t.index > p.index).each!((t) {
                        t.data.coins = 0;
                    });
                });
                gpr.ra.onExecOnce({
                    players.each!((p) {
                        teammates(p).filter!(t => t.index > p.index).each!((t) {
                            t.data.coins = p.data.coins;
                        });
                    });
                });
            });
        }

        if (config.alwaysDuel) {
            0x800FA854.onExec({ if (isBoardScene()) gpr.v0 = 1; });
        }

        if (config.randomBonus) {
            string message;

            data.currentScene.onWrite((ref Scene scene) {
                if (scene == Scene.FINISH_BOARD) {
                    bonus.randomShuffle(random);
                    writeln("Bonus: ", bonus[0..3]);
                }
            });
            
            data.messageBoxLength.addr.onExec({
                if (data.currentScene != Scene.FINISH_BOARD) return;
                
                auto c = Ptr!char(gpr.s0 + 2);
                message = "";
                foreach (i; 0..gpr.s1) {
                    message ~= *(c++);
                }

                message = message.replace("one\nstar", "one star")
                                 .replace("\x02\x0F Mini=Game Star\x16\x19", " \x02\x0FMini=Game Star\x16\x19")
                                 .replace("\x02\x0FMini=Game Star\x16 \x19", "\x02\x0FMini=Game Star\x16\x19 ");

                foreach (b; EnumMembers!BonusType[0..3]) {
                    auto text = BONUS_TEXT[b].enumerate.filter!(t => message.canFind(t.value));
                    if (text.empty) continue;
                    foreach(t; text) {
                        message = message.replace(t.value, BONUS_TEXT[bonus[b]][t.index]);
                    }
                    break;
                }
                
                gpr.s1 = cast(ushort)message.length;
            });
            data.messageBoxChar.addr.onExec({
                if (data.currentScene != Scene.FINISH_BOARD) return;
                gpr.v0 = message[gpr.a0];
            });

            data.loadBonusStat1a.addr.onExec({
                if (data.currentScene != Scene.FINISH_BOARD) return;
                gpr.v1 = data.players[gpr.s2].getBonusStat(bonus[BonusType.MINI_GAME]);
            });
            data.loadBonusStat1b.addr.onExec({
                if (data.currentScene != Scene.FINISH_BOARD) return;
                gpr.v0 = data.players[gpr.s2].getBonusStat(bonus[BonusType.MINI_GAME]);
            });
            data.loadBonusStat2a.addr.onExec({
                if (data.currentScene != Scene.FINISH_BOARD) return;
                gpr.v1 = data.players[gpr.s2].getBonusStat(bonus[BonusType.COIN]);
            });
            data.loadBonusStat2b.addr.onExec({
                if (data.currentScene != Scene.FINISH_BOARD) return;
                gpr.v0 = data.players[gpr.s2].getBonusStat(bonus[BonusType.COIN]);
            });
            data.loadBonusStat3a.addr.onExec({
                if (data.currentScene != Scene.FINISH_BOARD) return;
                gpr.v1 = data.players[gpr.s2].getBonusStat(bonus[BonusType.HAPPENING]);
            });
            data.loadBonusStat3b.addr.onExec({
                if (data.currentScene != Scene.FINISH_BOARD) return;
                gpr.v0 = data.players[gpr.s2].getBonusStat(bonus[BonusType.HAPPENING]);
            });
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

        if (config.reduceRepeatMiniGames || config.blockedMiniGames.length > 0) {
            MiniGame[][MiniGameType] queue;
            // Populate mini-game roulette
            0x800DFE90.onExec({
                if (!isBoardScene()) return;
                0x800DFED4.val!Instruction = NOP;
                0x800DFF40.val!Instruction = NOP;
                0x800DFF64.val!Instruction = NOP;
                0x800DFF78.val!Instruction = NOP;
                auto t = (cast(MiniGame)gpr.v0).type;
                // Initialize mini-game queue
                queue.require(t, [EnumMembers!MiniGame].filter!(g => g.type == t)
                                                       .filter!(g => !config.blockedMiniGames.canFind(g))
                                                       .array.randomShuffle(random));
                gpr.v0 = queue[t][gpr.s0];
            });
            // Roulette result
            0x800DF468.onExec({
                if (!isBoardScene()) return;
                auto g = data.miniGameSelection[gpr.v1];                  // Get chosen mini-game
                queue[g.type] = (queue[g.type].remove!(e => e == g) ~ g); // Move chosen mini-game to end of queue
                queue[g.type][0..$/2].randomShuffle(random);              // Shuffle first half of queue
            });
        }

        if (config.enhancedTaunts) {
            data.storeButtonPress.addr.onExec({
                if (gpr.v0 == 0 || data.totalTurns == 0) return;

                SFX sfx;
                switch (data.buttons[gpr.t0]) {
                    case BUTTON.L:   sfx = SFX.TAUNT;               break;
                    case BUTTON.D_R: sfx = SFX.BEING_CHOSEN;        break;
                    case BUTTON.D_L: sfx = SFX.GETTING_AN_ITEM;     break;
                    case BUTTON.D_D: sfx = SFX.WINNING_A_STAR;      break;
                    case BUTTON.D_U: sfx = SFX.WINNING_A_MINI_GAME; break;
                    case BUTTON.C_R: sfx = SFX.DESPAIR_1;           break;
                    case BUTTON.C_L: sfx = SFX.DESPAIR_2;           break;
                    case BUTTON.C_D: sfx = SFX.LOSING_A_MINI_GAME;  break;
                    case BUTTON.C_U: sfx = SFX.LOSING_A_MINI_GAME;  break;
                    default:                                        return;
                }

                auto p = players.find!(p => p.data.controller == gpr.t0);
                if (p.empty || p.front.isCPU) return;

                data.playSFX.addr.jal({
                    gpr.a0 = sfx;
                    gpr.a1 = p.front.index;
                });
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
    FINAL_RESULTS            =  85,
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

enum BonusType {
    MINI_GAME,
    COIN,
    HAPPENING,
    UNLUCKY,
    BLUE,
    CHANCE,
    BOWSER,
    BATTLE,
    ITEM,
    BANK,
    GAMBLING
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