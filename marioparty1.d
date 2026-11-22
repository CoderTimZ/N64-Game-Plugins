module me.timz.n64.marioparty2;

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

    this() {
        blockWeights = [
            Block.PLUS:    1,
            Block.MINUS:   1,
            Block.SPEED:   1,
            Block.SLOW:    1,
            Block.WARP:    1,
            Block.NORMAL: 27
        ];
    }
}

class PlayerState {

}

class State : MarioPartyState!PlayerState {

}

union PlayerData {
    ubyte[0x30] _data;
    mixin Field!(0x01, ubyte, "cpuDifficulty1");
    mixin Field!(0x02, ubyte, "cpuDifficulty2");
    mixin Field!(0x04, Character, "character");
    mixin Field!(0x07, ubyte, "flags");
    mixin Field!(0x08, ushort, "coins");
    mixin Field!(0x0A, short, "miniGameCoins");
    mixin Field!(0x0C, ushort, "stars");
    mixin Field!(0x0E, ushort, "currentChainIndex");
    mixin Field!(0x10, ushort, "currentSpaceIndex");
    mixin Field!(0x12, ushort, "nextChainIndex");
    mixin Field!(0x14, ushort, "nextSpaceIndex");
    mixin Field!(0x16, ubyte, "poisoned");
    mixin Field!(0x17, PanelColor, "color");
    mixin Field!(0x24, ushort, "miniGameCoins");
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
    mixin Field!(0x800C2FF4, uint, "randomState");
    mixin Field!(0x800D83A8, Arr!(PlayerPanel, 4), "playerPanels");
    mixin Field!(0x800ED5C7, ubyte, "totalTurns");
    mixin Field!(0x800ED5C9, ubyte, "currentTurn");
    mixin Field!(0x800ED5DC, ushort, "currentPlayerIndex");
    mixin Field!(0x800F09F4, Scene, "currentScene");
    mixin Field!(0x800F32B0, Arr!(PlayerData, 4), "players");
    mixin Field!(0x801012E0, ubyte, "chancePlayer1");
    mixin Field!(0x801012E1, ubyte, "chancePlayer2");
    mixin Field!(0x801012E2, ubyte, "chanceOutcome");
}

union PlayerPanel {
    ubyte[0x40] _data;
    mixin Field!(0x03, PanelColor, "color");
}

class MarioParty1 : MarioParty!(Config, State, Memory) {
    this(string name, string hash) {
        super(name, hash);

        // Keep the State on the permanent heap (D_800D6030, MakePermHeap, HuMemDirectMalloc, HuMemDirectFree, HuPrcVSleep)
        permanentHeap = PermanentHeap(0x800D6030, 0x8003B680, 0x8003B6A4, 0x8003B6C8, 0x800635B4);
    }

    override bool lockTeamScores() const {
        return false;
    }

    override bool disableTeamScores() const {
        return false;
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
        return Scene.SLOT_MACHINE <= scene && scene <= Scene.BUMPER_BALL_MAZE;
    }

    override bool isScoreScene(Scene scene) const {
        switch (scene) {
            case Scene.FINISH_BOARD:
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

    override void onStart() {
        super.onStart();

        0x80040828.onExec({
            gpr.v0 = weighted(config.blockWeights, random);
        });

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
        pluginFactory = (name, hash) => new MarioParty1(name, hash);

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

enum Scene : uint {
    BOOT                   =   0,
    CHANCE_TIME            =   1,
    SLOT_MACHINE           =   2,
    COIN_BLOCK_BLITZ       =  20,
    PIRANHAS_PURSUIT       =  49,
    TUG_O_WAR              =  50,
    PADDLE_BATTLE          =  51,
    BUMPER_BALL_MAZE       =  52,
    DKS_JUNGLE_ADVENTURE   =  54,
    PEACHS_BIRTHDAY_CAKE   =  55,
    YOSHIS_TROPICAL_ISLAND =  56,
    WARIOS_BATTLE_CANYON   =  57,
    LUIGIS_ENGINE_ROOM     =  58,
    MARIOS_RAINBOW_CASTLE  =  59,
    BOWSERS_MAGMA_MOUNTAIN =  60,
    ETERNAL_STAR           =  61,
    LAST_FIVE_TURNS        =  63,
    FINAL_RESULTS_2        =  64,
    BOARD_WINNER           =  65,
    FINISH_BOARD           =  66,
    TOAD                   =  68,
    BOWSER                 =  70,
    BOB_OMB                =  81,
    SHY_GUY                =  82,
    KOOPA                  =  95,
    START_BOARD            =  98,
    FINAL_RESULTS          = 100,
    BOO                    = 101,
    MUSHROOM_VILLAGE       = 105,
    GAME_SETUP             = 106,
    MINI_GAME_RULES        = 111,
    MINI_GAME_RESULTS      = 124,
    TITLE_SCREEN           = 129
}
