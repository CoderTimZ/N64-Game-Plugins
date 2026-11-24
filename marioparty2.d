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
import std.typecons;

class Config : MarioPartyConfig {
    bool alwaysDuel = false;
    bool lastPlaceDoubleRoll = false;
    bool teamControl = false;
    bool teamMiniGames = false;
    bool teamScores = false;
    int[Character] teams;
    bool carryThreeItems = false;
    bool randomItemAndDuelMiniGames = false;
    bool cheaperAndBetterItems = false;
    bool randomBonus = false;
    string[BonusType] bonuses;
    float[Space.Type] standardSpaceRatio;
    float luckySpaceRatio = 0;
    float luckySpaceItemChance = 0.5;
    int revealHiddenBlocksOnRemainingTurns = 0;
    float mapScrollSpeedMultiplier = 1.0;
    bool preventRepeatMiniGames = false;
    MiniGame[] blockedMiniGames;

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
            BonusType.LUCKY:     "Lucky"
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
    Item[] items;
    int luckySpaceCount = 0;
}

class State : MarioPartyState!PlayerState {
    ShuffleStream!MiniGame[MiniGameType] miniGameQueue;
    ShuffleStream!Board itemGameQueue;
    ShuffleStream!Board duelGameQueue;
    CustomSpace[] spaces;
    int spacesBoard = -1; // The board (data.currentBoard) spaces are for (-1: none yet)
    uint luckySpaceTexturePtr; // The custom spaces' textures, in the board's temporary heap (0: none)
    uint goldSpaceTexturePtr;
}

union Chain {
    ubyte[8] _data;
    mixin Field!(4, Ptr!ushort, "spaces");
}

union Space {
    static enum Type : byte {
        START       = 0x00,
        BLUE        = 0x01,
        RED         = 0x02,
        INVIS_1     = 0x03,
        HAPPENING   = 0x04,
        CHANCE      = 0x05,
        ITEM        = 0x06,
        BANK        = 0x07,
        INVIS_2     = 0x08,
        BATTLE      = 0x09,
        UNKNOWN_1   = 0x0A,
        UNKNOWN_2   = 0x0B,
        BOWSER      = 0x0C,
        ARROW       = 0x0D,
        STAR        = 0x0E,
        BLACK_STAR  = 0x0F,
        TOAD        = 0x10,
        BABY_BOWSER = 0x11
    }

    ubyte[0x24] _data;
    mixin Field!(0x01, Type, "type");
    mixin Field!(0x20, Ptr!Event, "eventPtr");

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
                return true;
            default:
                return false;
        }
    }
}

enum CustomSpace : byte {
    DEFAULT     =   -2,
    LOCKED      =   -1,
    START       = 0x00,
    BLUE        = 0x01,
    RED         = 0x02,
    INVIS_1     = 0x03,
    HAPPENING   = 0x04,
    CHANCE      = 0x05,
    ITEM        = 0x06,
    BANK        = 0x07,
    INVIS_2     = 0x08,
    BATTLE      = 0x09,
    UNKNOWN_1   = 0x0A,
    UNKNOWN_2   = 0x0B,
    BOWSER      = 0x0C,
    ARROW       = 0x0D,
    STAR        = 0x0E,
    BLACK_STAR  = 0x0F,
    TOAD        = 0x10,
    BABY_BOWSER = 0x11,
    LUCKY       = 0x12,
    HIDDEN      = 0x13  // A revealed hidden block (drawn only; never in State.spaces)
}

union Event {
    ubyte[8] _data;
    mixin Field!(0x0, ushort, "activationType");
    mixin Field!(0x2, ushort, "executionType");
    mixin Field!(0x4, Ptr!Instruction, "routine");
}

union PlayerData {
    ubyte[0x34] _data;
    mixin Field!(0x03, ubyte, "controller");
    mixin Field!(0x04, Character, "character");
    mixin Field!(0x07, ubyte, "flags");
    mixin Field!(0x08, ushort, "coins");
    mixin Field!(0x0E, ushort, "stars");
    mixin Field!(0x10, ushort, "chain");
    mixin Field!(0x12, ushort, "space");
    mixin Field!(0x14, ushort, "nextChain"); // Where the player moves next
    mixin Field!(0x16, ushort, "nextSpace");
    mixin Field!(0x19, Item, "item");
    mixin Field!(0x1B, PanelColor, "color");
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
}

union Memory {
    ubyte[0x800000] ram;
    mixin Field!(0x80018B28, Instruction, "randomByteRoutine");
    mixin Field!(0x8004DE7C, Instruction, "openItemMenuRoutine");
    mixin Field!(0x80060A1C, Instruction, "determineTeams");
    mixin Field!(0x80064200, Instruction, "duelRoutine");       // Checks the player can duel, then asks for the duel scene
    mixin Field!(0x80064478, Instruction, "duelCancelRoutine"); // In duelRoutine: shows why there is no duel
    mixin Field!(0x800C99B4, uint, "randomState");
    mixin Field!(0x800CC000, Arr!(ubyte, 10), "itemPrices");
    mixin Field!(0x800DF645, ubyte, "numberOfRolls");
    mixin Field!(0x800DF6C0, Arr!(MiniGame, 5), "miniGameRoulette");
    mixin Field!(0x800DF718, Ptr!Instruction, "booRoutinePtr");
    mixin Field!(0x800DF724, Ptr!Instruction, "plunderChestRoutinePtr");
    mixin Field!(0x800E18A8, float, "mapX");
    mixin Field!(0x800E18AC, float, "mapY");
    mixin Field!(0x800E18D0, ushort, "spaceCount");
    mixin Field!(0x800E18D2, ushort, "chainCount");
    mixin Field!(0x800E18D4, Ptr!Space, "spaces");
    mixin Field!(0x800E18D8, Ptr!Chain, "chains");
    mixin Field!(0x800E18E0, Arr!(Address, 18), "spaceTypeTexturePointers");
    mixin Field!(0x800E1B68, Arr!(short, 16), "noHiddenBlockSpaces"); // Spaces the board keeps hidden blocks off
    mixin Field!(0x800E1B88, short, "noHiddenBlockSpaceCount");
    mixin Field!(0x800F851A, byte, "itemMenuOpen");
    mixin Field!(0x800F8CE1, ubyte, "flags9"); // Flags 0x48-0x4F (_CheckFlag): 0x40 = hidden blocks are on (0x4E)
    mixin Field!(0x800F8CE4, Arr!(short, 4), "finalPlayerRankOrder");
    mixin Field!(0x800F93AA, Board, "currentBoard");
    mixin Field!(0x800F93AE, ushort, "totalTurns");
    mixin Field!(0x800F93B0, ushort, "currentTurn");
    mixin Field!(0x800F93C6, ushort, "currentPlayerIndex");
    mixin Field!(0x800FA608, short, "coinHiddenBlock"); // The hidden blocks' spaces (-1: none)
    mixin Field!(0x800FA63C, Scene, "currentScene");
    mixin Field!(0x800FD2C0, Arr!(PlayerData, 4), "players");
    mixin Field!(0x800FD418, short, "starHiddenBlock");
    mixin Field!(0x80101510, Arr!(PlayerPanel, 4), "playerPanels");
    mixin Field!(0x80110180, ubyte, "chancePlayer1");
    mixin Field!(0x80110181, ubyte, "chancePlayer2");
    mixin Field!(0x80110182, ubyte, "chancePrize");
}

union PlayerPanel {
    ubyte[0x48] _data;
    mixin Field!(0x04, PanelColor, "color");
}

class MarioParty2 : MarioParty!(Config, State, Memory) {
    Address[Scene] itemShopRoutines;
    Address[Scene] itemShopEvents;

    this(string name, string hash) {
        super(name, hash);

        // Keep the State on the permanent heap (perm_heap_addr, HuMemHeapInitPerm, HuMemMemoryAllocPerm, HuMemMemoryFreePerm, HuPrcVSleep)
        permanentHeap = PermanentHeap(0x800DEFD0, 0x80040D80, 0x80040DA4, 0x80040DC8, 0x8007DA44);
        tempHeap = TempHeap(0x80040E74, 0x80040E98); // HuMemMemoryAllocTemp, HuMemMemoryFreeTemp
    }

    override bool lockTeamScores() const {
        return false;
    }

    override bool disableTeamScores() const {
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
            case Scene.WESTERN_LAND_BOARD:
            case Scene.PIRATE_LAND_BOARD:
            case Scene.HORROR_LAND_BOARD:
            case Scene.SPACE_LAND_BOARD:
            case Scene.MYSTERY_LAND_BOARD:
            case Scene.BOWSER_LAND_BOARD:
                return true;
            default:
                return false;
        }
    }

    override bool isScoreScene(Scene scene) const {
        switch (scene) {
            case Scene.CHANCE_TIME:
            case Scene.FINISH_BOARD:
            case Scene.BOWSER_EVENT:
            case Scene.START_BOARD:
            case Scene.BATTLE_GAME_RESULTS:
            case Scene.MINI_GAME_RESULTS:
            // The wager is taken and the pot paid out in the duel scenes (by func_8005DCC8, which adds to a player's
            // coins), so teammates get the duel's coins there. The duelist's teammates have no coins until then, so
            // they can't be picked (see setUpTeamDuels()).
            case Scene.WESTERN_LAND_DUEL:
            case Scene.PIRATE_LAND_DUEL:
            case Scene.HORROR_LAND_DUEL:
            case Scene.SPACE_LAND_DUEL:
            case Scene.MYSTERY_LAND_DUEL:
            case Scene.BOWSER_LAND_DUEL:
                return true;
            default:
                return isBoardScene(scene);
        }
    }

    override bool isMiniGameScene(Scene scene) const {
        return Scene.BOWSER_SLOTS <= scene && scene <= Scene.DEEP_SEA_SALVAGE;
    }

    short getSpaceIndex(Player p) {
        if (!p) return -1;
        if (!data.chains) return -1;
        auto spaces = data.chains[p.data.chain].spaces;
        if (!spaces) return -1;
        return spaces[p.data.space];
    }

    Space* getSpace(Player p) {
        auto i = getSpaceIndex(p);
        return i >= 0 ? &data.spaces[i] : null;
    }

    bool itemsFull(Player p) {
        if (config.carryThreeItems) {
            return p.state.items.length >= (p.isCPU ? 1 : 3);
        } else {
            return p.data.item != Item.NONE;
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
            case BonusType.LUCKY:     return player.state.luckySpaceCount;
        }
    }

    // Text (game bytes) for the bonus star messages, or null for other messages. Each bonus star has 5 messages
    // (0x5F8, 0x5FD, 0x602): the award, then the winner, or a 2-, 3- or 4-way tie.
    string bonusMessage(ushort id) {
        if (id < 0x5F8 || id > 0x606) return null;

        auto i = (id - 0x5F8) / 5;
        auto b = bonus[i];
        auto star = "<" ~ getColor(b) ~ "><OUTLINE>" ~ config.bonuses[b] ~ " Star";
        string text;
        final switch ((id - 0x5F8) % 5) {
            case 0: text = ["First, the ", "Next, the ", "Finally, the "][i] ~ star ~ "<NO_OUTLINE><RESET>\naward! This award goes to\nthe player who " ~ getDescription(b) ~ "."; break;
            case 1: text = "The " ~ star ~ "<NO_OUTLINE><RESET>\ngoes to <1>!"; break;
            case 2: text = "It's a tie! <YELLOW>Stars<RESET> go\nto two players...\n<1> and <2>!"; break;
            case 3: text = "It's a three-way tie!\n<YELLOW>Stars<RESET> go to three\nplayers...<1>,\n<2> and <3>!"; break;
            case 4: text = "It's a four-way tie!!!\nAll four players are\n" ~ star ~ "s<NO_OUTLINE><RESET>, so no\n<YELLOW>Stars<RESET> will be awarded."; break;
        }
        return formatText("<CLEAR>" ~ text ~ "<END><NUL>");
    }

    // The detailed results (the final results' Start screen) get a Lucky Spaces column after Blue Spaces. The screen
    // shows 4 of its 12 columns at a time (0x8010848C = the first one shown, 0x80108490 = the cursor in them), each
    // with a header icon (sprites 1-12), each player's number in a text window (11 windows: Bank Spaces shares Stars',
    // which is never shown with it, and the game changes its text as the screen scrolls), and Toad's description of
    // the cursor's column. With the Lucky Spaces column there are 13: from Red Spaces on, column c is the game's
    // column c - 1. Its icon is a 14th sprite, made from the Blue Spaces icon, and its numbers share Coins' window,
    // which is never shown with it either.
    bool luckyDescription;   // The description being shown is the Lucky Spaces column's (Blue's message, changed)
    bool luckyDescriptionLoading;

    void setUpLuckyResultsColumn() {
        enum LUCKY = 5, COLUMNS = 13;
        enum Address FIRST = 0x8010848C, CURSOR = 0x80108490;
        enum Address ICONS = 0x80108AA6;      // The icons' sprite group (short)
        enum Address WINDOWS = 0x80108AE0;    // The columns' text windows (int each)
        enum Address TEXTS = 0x80108B10;      // Their numbers' text: 32 bytes per column, 8 per row
        enum Address RANKS = 0x800F8CE4;      // Each row's player (short each), from 1st
        enum Address SCALES = 0x801084F4;     // Each column's icon scale (float each)
        enum Address WINDOW_DATA = 0x800F920C; // Pointer to the windows' data, 636 bytes each
        bool resultsScreen() { return data.currentScene == Scene.FINAL_RESULTS; }
        // For column c: the game's column (Lucky Spaces: Blue's), its text window, and its icon's sprite
        static int column(int c) { return c < LUCKY ? c : c == LUCKY ? 4 : c - 1; }
        static int window(int c) { return c < LUCKY ? c : c == LUCKY ? 1 : c == COLUMNS - 1 ? 0 : c - 1; }
        static int sprite(int c) { return c == LUCKY ? COLUMNS : column(c) + 1; }
        int shownColumn(int slot) { return FIRST.val!int + slot; }
        short luckyIcon = -1;   // The Lucky Spaces icon's sprite animation, freed with the others
        // The hooks below call the game, which returns to the hooked instruction: these keep them from starting again
        bool makingIcon, settingUpIcon;
        bool windowShowsLucky;  // Coins' window has the Lucky Spaces numbers

        // The icons: a sprite group of 14 instead of 13 (func_8007FA6C(count, ...))
        0x80103EDC.onExec({
            if (!resultsScreen() || gpr.a0 != 13) return;
            gpr.a0 = 14;
            makingIcon = settingUpIcon = false;
        });
        // Each icon's file is loaded, made a sprite animation (func_80082800), then freed (DataClose, a0 = s3). Before
        // the Blue Spaces icon's (s4 = 4) is freed, its pixels and palette become the Lucky Spaces icon's, and it's
        // made an animation again.
        0x80103F5C.onExec({
            if (!resultsScreen() || gpr.s4 != 4 || makingIcon) return;
            makingIcon = true;
            foreach (i, b; LUCKY_RESULTS_ICON[0..256]) (gpr.s3 + 0x2C + cast(uint)i).val!ubyte = b;  // Pixels
            foreach (i, b; LUCKY_RESULTS_ICON[256..$]) (gpr.s3 + 0x12C + cast(uint)i).val!ubyte = b; // Palette
            0x80082800.jal(gpr.s3, (uint anim) { luckyIcon = cast(short)anim; });
        });
        // After the 12 icons, sprite 13 gets the Lucky Spaces icon, set up like the others: its animation
        // (func_8008218C), then func_8008225C, its priority (func_80082384), its attributes (func_80082418), its
        // position (func_80081AD0, the first slot's), its scale (func_80082340, 1 like the space icons') and
        // func_8008221C
        0x80104004.onExec({
            if (!resultsScreen() || luckyIcon < 0 || settingUpIcon) return;
            settingUpIcon = true;
            auto group = ICONS.val!short;
            0x8008218C.jal(group, COLUMNS, luckyIcon, 0, {
                0x8008225C.jal(group, COLUMNS, 1, {
                    0x80082384.jal(group, COLUMNS, 15, {
                        0x80082418.jal(group, COLUMNS, 0x9000, {
                            0x80081AD0.jal(group, COLUMNS, 0x801084A4.val!short, 0x801084A6.val!short, {
                                0x80082340.jal(group, COLUMNS, 0x3F800000, 0x3F800000, {
                                    0x8008221C.jal(group, COLUMNS, 0);
                                });
                            });
                        });
                    });
                });
            });
        });
        // The screen frees the icons' animations (func_80082660), then the group: the Lucky Spaces icon's too
        0x80104430.onExec({
            if (!resultsScreen() || luckyIcon < 0) return;
            auto anim = luckyIcon;
            luckyIcon = -1;
            0x80082660.jal(anim);
        });

        // Showing the icons: all 13 are hidden, then the 4 shown are shown and positioned (a1 = the column's sprite,
        // scaled by the game column's scale)
        0x80102C44.onExecDone({ if (resultsScreen()) gpr.v0 = gpr.s1 < COLUMNS; });
        0x80102C84.onExec({ if (resultsScreen()) gpr.a1 = sprite(shownColumn(cast(int)gpr.s1)); });
        0x80102CCC.onExec({ if (resultsScreen()) gpr.v0 = SCALES + 4 * column(shownColumn(cast(int)gpr.s1)); });
        0x80102D1C.onExec({ if (resultsScreen()) gpr.a1 = sprite(shownColumn(cast(int)gpr.s1)); });
        // Showing the numbers: the 4 shown columns' windows are shown and positioned (s0 = the column's window entry)
        0x80102DC4.onExec({ if (resultsScreen()) gpr.s0 = WINDOWS + 4 * window(shownColumn(cast(int)gpr.s1)); });

        // Coins' window has Coins' numbers while it can be shown (the first column shown is 0 or 1), and Lucky
        // Spaces' otherwise. The game fills the windows (func_80102EB4) when the screen opens, and changes Stars'
        // window to Bank's and back (func_8010361C) before showing the columns. The numbers are each row's text
        // ("%3d", spaces as code 0x1A) for func_80089308 (window, text, row), then the window shows them again (its
        // data + 76 = 8, then func_800890CC(window, 0x61B, 8, 4)).
        0x80102EB4.onExec({ if (resultsScreen()) windowShowsLucky = false; });
        0x8010361C.onExec({
            if (!resultsScreen()) return;
            auto lucky = FIRST.val!int >= 2;
            if (lucky == windowShowsLucky) return;
            windowShowsLucky = lucky;
            auto id = (WINDOWS + 4).val!int;
            foreach (row; 0..4) {
                auto player = (RANKS + row * 2).val!short;
                auto value = lucky ? players[player].state.luckySpaceCount
                                   : (0x800FD2C8 + player * 0x34).val!short; // Coins
                auto text = format("%3d", value).replace(" ", "\x1A") ~ '\0';
                foreach (i, c; text) (TEXTS + 32 + row * 8 + cast(uint)i).val!char = c;
            }
            0x80089308.jal(id, TEXTS + 32, 0, {
                0x80089308.jal(id, TEXTS + 40, 1, {
                    0x80089308.jal(id, TEXTS + 48, 2, {
                        0x80089308.jal(id, TEXTS + 56, 3, {
                            (WINDOW_DATA.val!uint + id * 636 + 76).val!short = 8;
                            0x800890CC.jal(id, 0x61B, 8, 4);
                        });
                    });
                });
            });
        });

        // Scrolling: the first column shown goes up to 9 instead of 8 (moving right, 0x801042A8 checks it's below 8),
        // and the right arrow hides at 9 (0x80102BF0 compares it with 8)
        0x801042A8.onExecDone({ if (resultsScreen()) gpr.v0 = cast(int)gpr.v1 < COLUMNS - 4; });
        0x80102BF0.onExec({ if (resultsScreen()) gpr.v0 = COLUMNS - 4; });

        // Toad's description of the cursor's column (func_800890CC, a1 = message 0x60D + the game's column): the
        // Lucky Spaces column shows the Blue Spaces message (0x611), changed as it's loaded. Every message is loaded by
        // ID through func_80068CD4(id), which reads it from ROM into a newly allocated buffer of its length.
        0x80102E58.onExec({
            if (!resultsScreen()) return;
            auto c = FIRST.val!int + CURSOR.val!int;
            luckyDescription = c == LUCKY;
            gpr.a1 = 0x60D + column(c);
        });
        ushort loadingId;
        0x80068CD4.onExec({ loadingId = cast(ushort)gpr.a0; });
        0x80068CE8.onExec({ // 20(sp) = length; next, it allocates and reads that many bytes
            if (!resultsScreen() || !luckyDescription || loadingId != 0x611) return;
            (gpr.sp + 20).val!ushort = cast(ushort)LUCKY_DESCRIPTION.length;
            luckyDescriptionLoading = true;
        });
        0x80068D10.onExec({ // s0 = the buffer, read
            if (!luckyDescriptionLoading) return;
            luckyDescriptionLoading = false;
            foreach (i, b; LUCKY_DESCRIPTION) (gpr.s0 + cast(uint)i).val!ubyte = b;
        });
    }

    override void onStart() {
        super.onStart();

        if (config.preventRepeatMiniGames || config.blockedMiniGames.length > 0) {
            data.currentScene.onWrite((ref Scene scene) {
                if (scene == Scene.START_BOARD) {
                    state.miniGameQueue.clear();
                    saveState();
                }
            });
            // Populate mini-game roulette
            0x8004AFA8.onExec({
                if (!isBoardScene()) return;
                0x8004AFEC.setCode(NOP);
                0x8004B044.setCode(NOP);
                0x8004B0F0.setCode(NOP);
                0x8004B140.setCode(NOP);
                if (gpr.s0 == 0) {
                    auto type = (cast(MiniGame)gpr.v0).type;
                    auto games = [EnumMembers!MiniGame].filter!(g => g.type == type).array;
                    fillMiniGameRoulette(type, games, (0x800CBD10 + gpr.s2).val!ubyte, 0x8004A1FC);
                    saveState();
                }
                gpr.v0 = data.miniGameRoulette[gpr.s0];
            });
            // Prevent the mini-game roulette from jumping backward
            0x8004A4A8.onExec({ if (isBoardScene()) gpr.v0 = 1; });
        }

        if (config.teamScores) {
            setUpTeamDuels(data.duelRoutine.addr, data.duelCancelRoutine.addr);
        }

        if (config.alwaysDuel) {
            setUpAlwaysDuel(0x800661AC);
        }

        if (config.carryThreeItems) {
            data.currentScene.onWrite((ref Scene scene) { // Clear the carried items at the start of a game
                if (scene == Scene.START_BOARD) {
                    players.each!(p => p.state.items = []);
                    saveState();
                }
            });

            players.each!((p) {
                p.data.item.onWrite((ref Item item, Address pc) {
                    if (!isBoardScene()) return;
                    //info(pc.to!string(16), ": P", p.index, " Write");

                    if (data.itemMenuOpen) {
                        if (item == Item.NONE) {
                            if (!p.state.items.empty) {
                                p.state.items.popFront();
                            }
                        } else if (p.state.items.empty) {
                            p.state.items ~= item;
                        } else {
                            p.state.items[0] = item;
                        }
                    } else if (item != Item.NONE) {
                        p.state.items ~= item;
                    }

                    saveState();
                    sendPlayerInfo(p);

                    item = item.NONE;
                });

                p.data.item.onRead((ref Item item, Address pc) {
                    if (!isBoardScene()) return;
                    //if (pc != 0x8005EEA8) info(pc.to!string(16), ": P", p.index, " Read");
                    if (item != Item.NONE) return;
                    if (p.state.items.empty) return;

                    if (pc == data.plunderChestRoutinePtr + 0x354) {
                        p.state.items.partialShuffle(1, random); // Randomize item being plundered
                    }

                    if (data.itemMenuOpen) {
                        item = p.state.items.front;
                        return;
                    }

                    if ((pc + 4).val!Instruction == 0x24020001) { // ADDIU V0, R0, 0x0001 (Checking if item is key (hopefully))
                        auto i = p.state.items.countUntil(Item.SKELETON_KEY);
                        if (i >= 0) {
                            item = p.data.item = Item.SKELETON_KEY;
                            p.state.items = p.state.items.remove(i);
                            saveState();
                            return;
                        }
                    }

                    if (p.state.items.canFind(Item.BOWSER_BOMB)) {
                        if (p.index != data.currentPlayerIndex || pc == 0x8004E984) { // pc == Check for Bowser Bomb
                            item = Item.BOWSER_BOMB;
                            return;
                        }
                    }

                    if (itemsFull(p) || pc == 0x8005EEA8) { // pc == Display Icon on Panel
                        item = p.state.items.front;
                    }
                });
            });

            data.itemMenuOpen.onWrite((ref byte isOpen) {
                if (!isBoardScene()) return;

                if (data.itemMenuOpen && !isOpen) {
                    players.each!((p) {
                        if (p.state.items.length <= 1) return;

                        p.state.items ~= p.state.items.front;
                        p.state.items.popFront();

                        sendPlayerInfo(p);
                    });
                }

                saveState();
            });

            0x8005600C.onExec({ // Executes after declining to use key
                if (!isBoardScene()) return;

                players.each!((p) {
                    if (p.data.item == Item.NONE) return;

                    p.state.items ~= p.data.item; // Move key back
                    p.data.item = Item.NONE;
                    saveState();
                });
            });

            0x8006661C.onExec({ // Clear Bowser Bombs
                if (!isBoardScene()) return;

                bool found = false;
                players.each!((p) {
                    ptrdiff_t i;
                    while ((i = p.state.items.countUntil(Item.BOWSER_BOMB)) >= 0) {
                        p.state.items = p.state.items.remove(i);
                        saveState();
                        sendPlayerInfo(p);

                        if (found) continue;
                        p.data.item = Item.BOWSER_BOMB;
                        found = true;
                    }
                });
            });
        }

        if (config.cheaperAndBetterItems) {
            // Decrease item price by 5 coins
            for (auto item = Item.MUSHROOM; item <= Item.MAGIC_LAMP; item++) {
                data.itemPrices[item].onRead((ref ubyte price) {
                    if (!isBoardScene()) return;
                    if (!price) return;

                    price -= 5;
                });
            }

            // Allow players with 5 or more coins to shop
            players.each!((p) {
                p.data.coins.onRead((ref ushort coins, Address pc) {
                    if (!isBoardScene()) return;

                    auto space = getSpace(currentPlayer);
                    if (!space || space.type != Space.Type.ARROW) return;

                    if (((pc + 4).val!Instruction & 0xFC00FFFF) == 0x2800000A) { // SLTI $T, $S, 10
                        coins += 5;
                    }
                });
            });

            // Update prices in dialog box
            0x8009DB18.onExecDone({
                if (!isBoardScene()) return;
                if (gpr.v0 < 16 || gpr.v0 >= 0x7FF) return;
                char[16] start;
                start.each!((i, ref c) => c = (gpr.a3 + cast(uint)i).val!char);
                if (start != "\x0B\x1A\x1A\x1A\x1AWhich \x0FItem") return;

                auto text = new char[gpr.v0];
                text.each!((i, ref c) => c = (gpr.a3 + cast(uint)i).val!char);
                text.replace("x 10", "x  5")
                    .replace("x 15", "x 10")
                    .replace("x 20", "x 15")
                    .replace("x 25", "x 20")
                    .replace("x 30", "x 25")
                    .each!((i, ref c) => (gpr.a3 + cast(uint)i).val!char = c);
            });

            // Make items available at all times
            data.currentTurn.onRead((ref ushort turn, Address pc) {
                if (!isBoardScene()) return;
                auto space = getSpace(currentPlayer);
                if (!space) return;

                if (space.type == Space.Type.ARROW) { // Item Shop
                    turn = cast(ushort)(data.totalTurns - 1);
                } else if (pc == 0x800663C8) {        // Item Space
                    turn = cast(ushort)(data.totalTurns - 1);
                }
            });
        }

        if (config.randomItemAndDuelMiniGames) {
            data.currentScene.onWrite((ref Scene scene) {
                if (scene == Scene.START_BOARD) {
                    state.itemGameQueue.clear();
                    state.duelGameQueue.clear();
                    saveState();
                }
            });

            // The duel's board is read twice: first to start its mini-game, then to unlock it (in the mini-game flags at
            // 0x800F8C7C, for the mini-game lists): both get the board chosen for it
            Nullable!Board duelBoard;
            data.currentBoard.onRead((ref Board board, Address pc) {
                if (!isBoardScene()) return;

                if (pc == 0x80064594) { // Unlock the duel mini-game
                    if (!duelBoard.isNull) board = duelBoard.get;
                    duelBoard.nullify();
                    return;
                }

                if (state.duelGameQueue.empty) state.duelGameQueue.initialize([EnumMembers!Board], random);
                if (state.itemGameQueue.empty) state.itemGameQueue.initialize([EnumMembers!Board], random);

                // Skips the boards whose mini-game is blocked (unless all of them are)
                auto blocked = (MiniGame game) => config.blockedMiniGames.canFind(game);
                switch (pc) {
                    case 0x80064574: // Start the duel mini-game
                        board = state.duelGameQueue.next(random, b => !blocked(DUEL_MINI_GAMES[b]));
                        duelBoard = board;
                        break;
                    case 0x80066428: // Start the Item Space mini-game
                        board = state.itemGameQueue.next(random, b => !blocked(ITEM_MINI_GAMES[b]));
                        break;
                    default: return;
                }

                saveState();
            });
        }

        if (config.randomBonus) {
            setUpRandomBonus!"s1"([[0x80103F04, 0x80103F50], [0x80104314, 0x80104360], [0x80104724, 0x80104770]], true);

            // Every message is loaded by ID through func_80068CD4(id), which reads it from ROM into a newly allocated
            // buffer of its length. Loading a different length and writing the bonus star text into that buffer
            // replaces the message with nothing else to manage: the game frees the buffer itself.
            ushort messageId;
            string replacement;
            0x80068CD4.onExec({ messageId = cast(ushort)gpr.a0; });
            0x80068CE8.onExec({ // 16(sp) = ROM address, 20(sp) = length; next, it allocates and reads that many bytes
                if (data.currentScene != Scene.FINISH_BOARD || bonus.length < 3) return;
                replacement = bonusMessage(messageId);
                if (replacement is null) return;
                if (replacement.length % 2) replacement ~= '\0';
                (gpr.sp + 20).val!ushort = cast(ushort)replacement.length;
            });
            0x80068D10.onExec({ // s0 = the buffer
                if (replacement is null) return;
                foreach (i, c; replacement) Ptr!char(gpr.s0)[i] = c;
                replacement = null;
            });
        }

        if (config.luckySpaceRatio > 0 || config.revealHiddenBlocksOnRemainingTurns > 0 ||
            config.standardSpaceRatio.values.any!(v => v > 0.0)) {
            immutable ITEM_WEIGHTS_EARLY = [
                Item.MUSHROOM:        22,
                Item.SKELETON_KEY:     9,
                Item.PLUNDER_CHEST:    7,
                Item.BOWSER_BOMB:      4,
                Item.DUELING_GLOVE:    7,
                Item.WARP_BLOCK:      15,
                Item.GOLDEN_MUSHROOM: 12,
                Item.BOO_BELL:         8,
                Item.BOWSER_SUIT:     10,
                Item.MAGIC_LAMP:       6
            ];

            immutable ITEM_WEIGHTS_MID = [
                Item.MUSHROOM:        18,
                Item.SKELETON_KEY:    10,
                Item.PLUNDER_CHEST:    9,
                Item.BOWSER_BOMB:      4,
                Item.DUELING_GLOVE:    9,
                Item.WARP_BLOCK:      10,
                Item.GOLDEN_MUSHROOM: 15,
                Item.BOO_BELL:         9,
                Item.BOWSER_SUIT:      9,
                Item.MAGIC_LAMP:       7
            ];

            immutable ITEM_WEIGHTS_END = [
                Item.MUSHROOM:        13,
                Item.SKELETON_KEY:     8,
                Item.PLUNDER_CHEST:    7,
                Item.BOWSER_BOMB:      4,
                Item.DUELING_GLOVE:   12,
                Item.WARP_BLOCK:       7,
                Item.GOLDEN_MUSHROOM: 18,
                Item.BOO_BELL:        13,
                Item.BOWSER_SUIT:      7,
                Item.MAGIC_LAMP:      11
            ];

            // The custom spaces' textures go in the board's temporary heap when it's made, and their addresses in the
            // State, which is saved with each save state (as the heap is). A save state that has none (made without
            // these options) gets them when the spaces are next drawn.
            bool allocatingTextures;
            void allocateSpaceTextures() {
                if (allocatingTextures) return;
                immutable needLucky = !state.luckySpaceTexturePtr;
                immutable needGold = config.revealHiddenBlocksOnRemainingTurns > 0 && !state.goldSpaceTexturePtr;
                if (!needLucky && !needGold) return;
                allocatingTextures = true;
                void allocateGold() {
                    if (!needGold) {
                        allocatingTextures = false;
                        saveState();
                        return;
                    }
                    mallocTemp(GOLD_SPACE_TEXTURE.length + 0x10, (ptr) {
                        GOLD_SPACE_TEXTURE.each!((i, b) { Ptr!ubyte(ptr + 0x10)[i] = b; });
                        state.goldSpaceTexturePtr = ptr;
                        allocatingTextures = false;
                        saveState();
                    });
                }
                if (!needLucky) {
                    allocateGold();
                    return;
                }
                mallocTemp(LUCKY_SPACE_TEXTURE.length + 0x10, (ptr) {
                    LUCKY_SPACE_TEXTURE.each!((i, b) { Ptr!ubyte(ptr + 0x10)[i] = b; });
                    state.luckySpaceTexturePtr = ptr;
                    allocateGold();
                });
            }
            0x80077AA8.onExecDone({ // Finish making temp heap
                state.luckySpaceTexturePtr = 0;
                state.goldSpaceTexturePtr = 0;
                if (!isBoardScene()) return;
                allocateSpaceTextures();
            });

            // The hidden blocks (Coin and Star): the game places each on a Blue Space it picks (func_80064DA8),
            // picking again while the space is -1. Like MP3, they're kept off Lucky Spaces, so a revealed block never
            // hides one.
            bool hiddenBlocksOn() { return (data.flags9 & 0x40) != 0; }
            bool hiddenBlockAllowed(int i, int other) {
                return i >= 0 && i < data.spaceCount && i != other && data.spaces[i].type == Space.Type.BLUE &&
                       (i >= state.spaces.length || state.spaces[i] != CustomSpace.LUCKY) &&
                       !iota(min(cast(int)data.noHiddenBlockSpaceCount, 16)).any!(j => data.noHiddenBlockSpaces[j] == i);
            }
            void moveHiddenBlock(ref short block, short other) {
                if (block < 0 || hiddenBlockAllowed(block, other)) return;
                auto choices = iota(data.spaceCount).filter!(i => hiddenBlockAllowed(i, other)).array;
                if (!choices.empty) block = cast(short)choices.choice(random);
            }
            // A space it picks that isn't allowed becomes -1, so it picks again (if any space is allowed: if none is,
            // it would never stop)
            void rejectHiddenBlock(ref short block, short other) {
                if (!isBoardScene() || block < 0 || hiddenBlockAllowed(block, other)) return;
                if (iota(data.spaceCount).any!(i => hiddenBlockAllowed(i, other))) block = -1;
            }
            data.coinHiddenBlock.onWrite((ref short block) { rejectHiddenBlock(block, data.starHiddenBlock); });
            data.starHiddenBlock.onWrite((ref short block) { rejectHiddenBlock(block, data.coinHiddenBlock); });
            bool revealed(int i) {
                return remainingTurns() <= config.revealHiddenBlocksOnRemainingTurns && hiddenBlocksOn() &&
                       (i == data.coinHiddenBlock || i == data.starHiddenBlock);
            }

            0x800540B0.onExec({ // Force high res space textures on full map view
                if (!isBoardScene()) return;
                gpr.a0 = false;
            });
            // The space render function (func_800542FC) draws each type s4 in turn (0x80054810 loops while it's below
            // 18), with that type's texture (0x80054460, 0x8005448C), at its scale (f20, from a table of 18 for the
            // board's view), each space s2 whose type (0x800546B4) is s4. Lucky Spaces and revealed hidden blocks are
            // drawn as types of their own, after the game's, with their own textures at a Blue Space's scale.
            auto selectSpaceTexture = {
                if (!isBoardScene()) return;
                switch (gpr.s4) {
                    case CustomSpace.LUCKY:  gpr.v0 = state.luckySpaceTexturePtr; break;
                    case CustomSpace.HIDDEN: gpr.v0 = state.goldSpaceTexturePtr;  break;
                    default:                                                break;
                }
            };
            0x80054460.onExecDone(selectSpaceTexture);
            0x8005448C.onExecDone(selectSpaceTexture);
            0x80054474.onExecDone({ // f20 = the scale, from the table at 108(sp)
                if (!isBoardScene() || gpr.s4 < CustomSpace.LUCKY) return;
                fpr.f20 = ((gpr.sp + 108).val!uint + 4 * Space.Type.BLUE).val!float;
            });
            0x800546B4.onExecDone({
                if (!isBoardScene()) return;
                if (gpr.v0 != Space.Type.BLUE) return;
                if (revealed(cast(int)gpr.s2)) {
                    gpr.v0 = CustomSpace.HIDDEN;
                } else if (gpr.s2 < state.spaces.length && state.spaces[gpr.s2] == CustomSpace.LUCKY) {
                    gpr.v0 = CustomSpace.LUCKY;
                }
            });
            0x80054810.onExec({
                if (!isBoardScene()) return;
                gpr.v0 = (gpr.s4 <= CustomSpace.max);
            });
            resetCustomSpacesAtStart();
            0x800542FC.onExec({ // Space render function
                if (!isBoardScene()) return;

                if (assignCustomSpaces()) {
                    saveState();
                }

                if (hiddenBlocksOn()) {
                    moveHiddenBlock(data.coinHiddenBlock, data.starHiddenBlock);
                    moveHiddenBlock(data.starHiddenBlock, data.coinHiddenBlock);
                }

                allocateSpaceTextures(); // Calls back into this function when it allocates (allocatingTextures stops it)
            });
            0x80065AA4.onExec({ // Increment lucky space count
                if (!isBoardScene()) return;
                auto i = getSpaceIndex(currentPlayer);
                if (data.spaces[i].type != Space.Type.BLUE) return;
                if (i >= state.spaces.length) return;
                if (state.spaces[i] != CustomSpace.LUCKY) return;

                gpr.v0--;
                currentPlayer.state.luckySpaceCount++;

                saveState();
            });
            0x800557C8.onExecDone({ // Trigger lucky space
                if (!isBoardScene()) return;
                if (data.spaces[gpr.s0].type != Space.Type.BLUE) return;
                if (gpr.s3 != 3) return;
                if (gpr.s1) return; // Space already has an event defined
                if (gpr.s0 >= state.spaces.length) return;
                if (state.spaces[gpr.s0] != CustomSpace.LUCKY) return;
                if (itemsFull(currentPlayer) || random.uniform01() >= config.luckySpaceItemChance) return; // Give coins

                0x800662F0.onExecOnce({ gpr.v0 = 1; }); // Skip giving coins
                gpr.ra.onExecOnce({ clearExecOnce(0x800662F0); });

                if (data.currentScene !in itemShopRoutines) {
                    auto result = searchMemory([
                        0x27BDFF90, 0xAFBF0068, 0xAFB50064, 0xAFB40060,
                        0xAFB3005C, 0xAFB20058, 0xAFB10054, 0xAFB00050,
                        0x3C148010, 0x269493A8, 0x0C01770F, 0x2404FFFF,
                        0x0040A821, 0x3C038010, 0x846393C6, 0x24020004,
                        0x10620169, 0x2404FFFF, 0x2405FFFF, 0x0C01775A
                    ]);
                    itemShopRoutines[data.currentScene] = (result.empty ? 0 : result.front);
                }
                Address routine = itemShopRoutines[data.currentScene];
                if (!routine) return;

                auto result = iota(data.spaceCount).map!(i => data.spaces[i].eventPtr).find!(e => e && (*e).routine == routine);
                if (result.empty) return;
                gpr.s1 = result.front;

                0x800557F0.onExecOnce({ gpr.v0 = 3; });

                routine.onExecOnce({
                    (routine + 0x048).onExecOnce({ jump(routine + 0x06C); }); // Skip look at shop animation
                    (routine + 0x10C).onExecOnce({ jump(routine + 0x404); }); // Skip message box
                    (routine + 0x414).onExecOnce({ jump(routine + 0x418); });
                    (routine + 0x414).onExecOnce({
                        Item item;
                        if (data.currentTurn <= data.totalTurns / 3) {
                            item = weighted(ITEM_WEIGHTS_EARLY, random);
                        } else if (data.currentTurn <= data.totalTurns * 2 / 3) {
                            item = weighted(ITEM_WEIGHTS_MID, random);
                        } else {
                            item = weighted(ITEM_WEIGHTS_END, random);
                        }
                        gpr.v0 = item; // Give random item
                        if (config.carryThreeItems) {
                            currentPlayer.state.items ~= item;
                        } else {
                            currentPlayer.data.item = item;
                        }
                    });
                    gpr.ra.onExecOnce({
                        clearExecOnce(routine + 0x048);
                        clearExecOnce(routine + 0x10C);
                        clearExecOnce(routine + 0x414);
                    });
                });
            });
            0x80066318.onExec({ // Give extra coins on lucky space
                if (!isBoardScene()) return;
                auto i = getSpaceIndex(currentPlayer);
                if (data.spaces[i].type != Space.Type.BLUE) return;
                if (i >= state.spaces.length) return;
                if (state.spaces[i] != CustomSpace.LUCKY) return;

                if (remainingTurns() <= 5) {
                    gpr.s0 =        [12, 15, 20].choice(random);
                } else {
                    gpr.s0 = [7, 10, 12, 15, 20].choice(random);
                }
            });
            if (config.luckySpaceRatio > 0) {
                setUpLuckyResultsColumn();
            }
        }

        if (config.mapScrollSpeedMultiplier != 1.0) {
            setUpMapScrollSpeed(0x80067944);
        }

        if (config.rankPlayersByBingoScore) {
            setUpBingoRanking(0x80059FD0, 0x8005A07C, 0x8005A000, 0x8484D2CE);
        }

        fixChanceTimeDuplicates(0x8010D6F0, 0x8010D924); // Chance Time duplicate character fix

        watchPlayerInfo(); // Keep this at the bottom
    }

    override bool overrideItems(Player p, string[] names) {
        Item[] items;
        try {
            items = names.map!(n => n.to!Item).array;
        } catch (ConvException) {
            return false;
        }
        if (items.canFind(Item.NONE)) return false;

        if (config.carryThreeItems) {
            p.state.items = items; // The game's own slot stays empty: the hooks in onStart() hand out these
        } else {
            if (items.length > 1) return false;
            p.data.item = (items.empty ? Item.NONE : items[0]);
        }
        return true;
    }

    override void addPlayerItems(Player player, ref JSONValue msg) {
        msg["items"] = (config.carryThreeItems ? player.state.items : [player.data.item]).toJSON();
        msg["itemSlots"] = JSONValue(config.carryThreeItems ? 3 : 1);
    }

    override void watchPlayerItems(Player p) {
        if (config.carryThreeItems) return; // The item hooks in onStart() send the player when their items change

        p.data.item.onWrite((ref Item item) {
            if (!isScoreScene(data.currentScene)) return;
            if (item == p.data.item) return;

            p.data.item = item;

            sendPlayerInfo(p);
        });
    }
}

extern (C) {
    string getName() {
        return "Mario Party 2";
    }

    int startup() {
        version (TestDriver) {
            import me.timz.n64.mp2test : TestMarioParty2;
            pluginFactory = (name, hash) => new TestMarioParty2(name, hash); // The test build (test/mp2test.d)
        } else {
            pluginFactory = (name, hash) => new MarioParty2(name, hash);
        }

        return 0;
    }
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
    LUCKY
}

string getColor(BonusType type) {
    final switch (type) {
        case BonusType.MINI_GAME: return "CYAN";
        case BonusType.COIN:      return "YELLOW";
        case BonusType.HAPPENING: return "GREEN";
        case BonusType.RED:       return "RED";
        case BonusType.BLUE:      return "BLUE";
        case BonusType.CHANCE:    return "GREEN";
        case BonusType.BOWSER:    return "RED";
        case BonusType.BATTLE:    return "GREEN";
        case BonusType.ITEM:      return "GREEN";
        case BonusType.BANK:      return "YELLOW";
        case BonusType.LUCKY:     return "BLUE";
    }
}

string getDescription(BonusType type) {
    final switch (type) {
        case BonusType.MINI_GAME: return "collected the\nmost <YELLOW>Coins<RESET> in Mini-Games";
        case BonusType.COIN:      return "held the\nmost <YELLOW>Coins<RESET> at one time";
        case BonusType.HAPPENING: return "landed on\nthe most <GREEN>? Spaces<RESET>";
        case BonusType.RED:       return "landed on\nthe most <RED>Red Spaces<RESET>";
        case BonusType.BLUE:      return "landed on\nthe most <BLUE>Blue Spaces<RESET>";
        case BonusType.CHANCE:    return "landed on\nthe most <GREEN>! Spaces<RESET>";
        case BonusType.BOWSER:    return "landed on\nthe most <RED>Bowser Spaces<RESET>";
        case BonusType.BATTLE:    return "landed on\nthe most <GREEN>Battle Spaces<RESET>";
        case BonusType.ITEM:      return "landed on\nthe most <GREEN>Item Spaces<RESET>";
        case BonusType.BANK:      return "landed on\nthe most <GREEN>Bank Spaces<RESET>";
        case BonusType.LUCKY:     return "landed on\nthe most <BLUE>Lucky Spaces<RESET>";
    }
}

enum Board : ushort {
    WESTERN = 0,
    PIRATE  = 1,
    HORROR  = 2,
    SPACE   = 3,
    MYSTERY = 4,
    BOWSER  = 5
}

// Each board's duel and Item Space mini-games, by Board (the game's tables at 0x800CCD54 and 0x800CCCFC)
immutable MiniGame[6] DUEL_MINI_GAMES = [
    MiniGame.QUICK_DRAW_CORKS, MiniGame.SABER_SLASHES, MiniGame.MUSHROOM_BREW,
    MiniGame.TIME_BOMB,        MiniGame.PSYCHIC_SAFARI, MiniGame.ROCK_PAPER_MARIO
];
immutable MiniGame[6] ITEM_MINI_GAMES = [
    MiniGame.GIVE_ME_A_BRAKE, MiniGame.ROLL_OUT_THE_BARRELS, MiniGame.COFFIN_CONGESTION,
    MiniGame.HAMMER_SLAMMER,  MiniGame.MALLET_GO_ROUND,      MiniGame.BOWSER_SLOTS
];

enum Item : byte {
    NONE            = -1,
    MUSHROOM        =  0,
    SKELETON_KEY    =  1,
    PLUNDER_CHEST   =  2,
    BOWSER_BOMB     =  3,
    DUELING_GLOVE   =  4,
    WARP_BLOCK      =  5,
    GOLDEN_MUSHROOM =  6,
    BOO_BELL        =  7,
    BOWSER_SUIT     =  8,
    MAGIC_LAMP      =  9
}

enum MiniGameType {
    ONE_V_THREE,
    TWO_V_TWO,
    FOUR_PLAYER,
    BATTLE,
    DUEL,
    ITEM,
    SPECIAL
}

enum MiniGame : ubyte {
    BOWSER_SLOTS         =  1,
    ROLL_OUT_THE_BARRELS =  2,
    COFFIN_CONGESTION    =  3,
    HAMMER_SLAMMER       =  4,
    GIVE_ME_A_BRAKE      =  5,
    MALLET_GO_ROUND      =  6,
    GRAB_BAG             =  7,
    BUMPER_BALLOON_CARS  =  8,
    RAKE_EM_IN           =  9,
    DAY_AT_THE_RACES     = 11,
    FACE_LIFT            = 12,
    CRAZY_CUTTERS        = 13,
    HOT_BOB_OMB          = 14,
    BOWL_OVER            = 15,
    RAINBOW_RUN          = 16,
    CRANE_GAME           = 17,
    MOVE_TO_THE_MUSIC    = 18,
    BOB_OMB_BARRAGE      = 19,
    LOOK_AWAY            = 20,
    SHOCK_DROP_OR_ROLL   = 21,
    LIGHTS_OUT           = 22,
    FILET_RELAY          = 23,
    ARCHER_IVAL          = 24,
    TOAD_BANDSTAND       = 26,
    BOBSLED_RUN          = 27,
    HANDCAR_HAVOC        = 28,
    BALLOON_BURST        = 30,
    SKY_PILOTS           = 31,
    SPEED_HOCKEY         = 32,
    CAKE_FACTORY         = 33,
    DUNGEON_DASH         = 35,
    MAGNET_CARTA         = 36,
    LAVA_TILE_ISLE       = 37,
    HOT_ROPE_JUMP        = 38,
    SHELL_SHOCKED        = 39,
    TOAD_IN_THE_BOX      = 40,
    MECHA_MARATHON       = 41,
    ROLL_CALL            = 42,
    ABANDON_SHIP         = 43,
    PLATFORM_PERIL       = 44,
    TOTEM_POLE_POUND     = 45,
    BUMPER_BALLS         = 46,
    BOMBS_AWAY           = 48,
    TIPSY_TOURNEY        = 49,
    HONEYCOMB_HAVOC      = 50,
    HEXAGON_HEAT         = 51,
    SKATEBOARD_SCAMPER   = 52,
    SLOT_CAR_DERBY       = 53,
    SHY_GUY_SAYS         = 54,
    SNEAK_N_SNORE        = 55,
    DRIVERS_ED           = 57,
    CHANCE_TIME          = 58,
    QUICK_DRAW_CORKS     = 59,
    SABER_SLASHES        = 60,
    MUSHROOM_BREW        = 61,
    TIME_BOMB            = 62,
    PSYCHIC_SAFARI       = 63,
    ROCK_PAPER_MARIO     = 64,
    BOWSERS_BIG_BLAST    = 65,
    LOONEY_LUMBERJACKS   = 66,
    TORPEDO_TARGETS      = 67,
    DESTRUCTION_DUET     = 68,
    DIZZY_DANCING        = 69,
    TILE_DRIVER          = 70,
    QUICKSAND_CACHE      = 71,
    DEEP_SEA_SALVAGE     = 72
}

MiniGameType type(MiniGame game) {
    switch (game) {
        case MiniGame.LAVA_TILE_ISLE:
        case MiniGame.HOT_ROPE_JUMP:
        case MiniGame.SHELL_SHOCKED:
        case MiniGame.TOAD_IN_THE_BOX:
        case MiniGame.MECHA_MARATHON:
        case MiniGame.ROLL_CALL:
        case MiniGame.ABANDON_SHIP:
        case MiniGame.PLATFORM_PERIL:
        case MiniGame.TOTEM_POLE_POUND:
        case MiniGame.BUMPER_BALLS:
        case MiniGame.BOMBS_AWAY:
        case MiniGame.TIPSY_TOURNEY:
        case MiniGame.HONEYCOMB_HAVOC:
        case MiniGame.HEXAGON_HEAT:
        case MiniGame.SKATEBOARD_SCAMPER:
        case MiniGame.SLOT_CAR_DERBY:
        case MiniGame.SHY_GUY_SAYS:
        case MiniGame.SNEAK_N_SNORE:
        case MiniGame.DIZZY_DANCING:
        case MiniGame.TILE_DRIVER:
        case MiniGame.DEEP_SEA_SALVAGE:
            return MiniGameType.FOUR_PLAYER;

        case MiniGame.BOWL_OVER:
        case MiniGame.RAINBOW_RUN:
        case MiniGame.CRANE_GAME:
        case MiniGame.MOVE_TO_THE_MUSIC:
        case MiniGame.BOB_OMB_BARRAGE:
        case MiniGame.LOOK_AWAY:
        case MiniGame.SHOCK_DROP_OR_ROLL:
        case MiniGame.LIGHTS_OUT:
        case MiniGame.FILET_RELAY:
        case MiniGame.ARCHER_IVAL:
        case MiniGame.QUICKSAND_CACHE:
            return MiniGameType.ONE_V_THREE;

        case MiniGame.TOAD_BANDSTAND:
        case MiniGame.BOBSLED_RUN:
        case MiniGame.HANDCAR_HAVOC:
        case MiniGame.BALLOON_BURST:
        case MiniGame.SKY_PILOTS:
        case MiniGame.SPEED_HOCKEY:
        case MiniGame.CAKE_FACTORY:
        case MiniGame.DUNGEON_DASH:
        case MiniGame.MAGNET_CARTA:
        case MiniGame.LOONEY_LUMBERJACKS:
        case MiniGame.TORPEDO_TARGETS:
        case MiniGame.DESTRUCTION_DUET:
            return MiniGameType.TWO_V_TWO;

        case MiniGame.GRAB_BAG:
        case MiniGame.BUMPER_BALLOON_CARS:
        case MiniGame.RAKE_EM_IN:
        case MiniGame.DAY_AT_THE_RACES:
        case MiniGame.HOT_BOB_OMB:
        case MiniGame.FACE_LIFT:
        case MiniGame.CRAZY_CUTTERS:
        case MiniGame.BOWSERS_BIG_BLAST:
            return MiniGameType.BATTLE;

        case MiniGame.BOWSER_SLOTS:
        case MiniGame.ROLL_OUT_THE_BARRELS:
        case MiniGame.COFFIN_CONGESTION:
        case MiniGame.HAMMER_SLAMMER:
        case MiniGame.GIVE_ME_A_BRAKE:
        case MiniGame.MALLET_GO_ROUND:
            return MiniGameType.ITEM;

        case MiniGame.QUICK_DRAW_CORKS:
        case MiniGame.SABER_SLASHES:
        case MiniGame.MUSHROOM_BREW:
        case MiniGame.TIME_BOMB:
        case MiniGame.PSYCHIC_SAFARI:
        case MiniGame.ROCK_PAPER_MARIO:
            return MiniGameType.DUEL;

        default:
            return MiniGameType.SPECIAL;
    }
}

enum Scene : uint {
    BOOT                 =   0,
    BOWSER_SLOTS         =   1,
    ROLL_OUT_THE_BARRELS =   2,
    COFFIN_CONGESTION    =   3,
    HAMMER_SLAMMER       =   4,
    GIVE_ME_A_BRAKE      =   5,
    MALLET_GO_ROUND      =   6,
    GRAB_BAG             =   7,
    LAVA_TILE_ISLE       =   8,
    BUMPER_BALLOON_CARS  =   9,
    RAKE_EM_IN           =  10,
    DAY_AT_THE_RACES     =  11,
    HOT_ROPE_JUMP        =  12,
    HOT_BOB_OMB          =  13,
    BOWL_OVER            =  14,
    RAINBOW_RUN          =  15,
    CRANE_GAME           =  16,
    MOVE_TO_THE_MUSIC    =  17,
    BOB_OMB_BARRAGE      =  18,
    LOOK_AWAY            =  19,
    SHOCK_DROP_OR_ROLL   =  20,
    LIGHTS_OUT           =  21,
    FILET_RELAY          =  22,
    ARCHER_IVAL          =  23,
    TOAD_BANDSTAND       =  24,
    BOBSLED_RUN          =  25,
    HANDCAR_HAVOC        =  26,
    BALLOON_BURST        =  27,
    SKY_PILOTS           =  28,
    SPEED_HOCKEY         =  29,
    CAKE_FACTORY         =  30,
    DUNGEON_DASH         =  31,
    MAGNET_CARTA         =  32,
    FACE_LIFT            =  33,
    SHELL_SHOCKED        =  34,
    CRAZY_CUTTERS        =  35,
    TOAD_IN_THE_BOX      =  36,
    MECHA_MARATHON       =  37,
    ROLL_CALL            =  38,
    ABANDON_SHIP         =  39,
    PLATFORM_PERIL       =  40,
    TOTEM_POLE_POUND     =  41,
    BUMPER_BALLS         =  42,
    BOMBS_AWAY           =  43,
    TIPSY_TOURNEY        =  44,
    HONEYCOMB_HAVOC      =  45,
    HEXAGON_HEAT         =  46,
    SKATEBOARD_SCAMPER   =  47,
    SLOT_CAR_DERBY       =  48,
    SHY_GUY_SAYS         =  49,
    SNEAK_N_SNORE        =  50,
    DRIVERS_ED           =  51,
    CHANCE_TIME          =  52,
    LOONEY_LUMBERJACKS   =  53,
    DIZZY_DANCING        =  54,
    TILE_DRIVER          =  55,
    QUICKSAND_CACHE      =  56,
    BOWSERS_BIG_BLAST    =  57,
    TORPEDO_TARGETS      =  58,
    DESTRUCTION_DUET     =  59,
    DEEP_SEA_SALVAGE     =  60,
    TRANSITION           =  61,
    WESTERN_LAND_BOARD   =  62,
    WESTERN_LAND_DUEL    =  63, // Each board's duel: picking the opponent, the wager, the duel and the payout
    LAST_FIVE_TURNS      =  64,
    PIRATE_LAND_BOARD    =  65,
    PIRATE_LAND_DUEL     =  66,
    HORROR_LAND_BOARD    =  67,
    HORROR_LAND_DUEL     =  68,
    SPACE_LAND_BOARD     =  69,
    SPACE_LAND_DUEL      =  70,
    MYSTERY_LAND_BOARD   =  71,
    MYSTERY_LAND_DUEL    =  72,
    BOWSER_LAND_BOARD    =  73,
    BOWSER_LAND_DUEL     =  74,
    RULES_LAND           =  77,
    FINAL_RESULTS        =  81,
    FINISH_BOARD         =  82,
    BOWSER_EVENT         =  83,
    START_BOARD          =  85,
    OPENING_CREDITS      =  87,
    GAME_SETUP           =  88,
    MAIN_MENU            =  91,
    MINI_GAME_LAND       =  92,
    MINI_GAME_PARK       =  93,
    MINI_GAME_RULES_2    =  95,
    MINI_GAME_RULES      =  96,
    TITLE_SCREEN         =  98,
    FINAL_MINI_GAME_COASTER = 109,
    MINI_GAME_COASTER    = 110,
    BATTLE_GAME_RESULTS  = 111,
    MINI_GAME_RESULTS    = 112,
    MESSAGE_TEST         = 113,
    CREDITS              = 114
}

// The Lucky Space texture: 32x32 pixels, 4 bytes each (red, green, blue, alpha), from textures/mp2-lucky-space.rgba
immutable ubyte[] LUCKY_SPACE_TEXTURE = cast(immutable(ubyte)[])import("mp2-lucky-space.rgba");

// The gold space (a revealed hidden block) texture: 32x32 pixels, 4 bytes each (red, green, blue, alpha), from
// textures/mp2-gold-space.rgba: the Blue Space texture, recolored gold.
immutable ubyte[] GOLD_SPACE_TEXTURE = cast(immutable(ubyte)[])import("mp2-gold-space.rgba");
static assert(GOLD_SPACE_TEXTURE.length == 32 * 32 * 4);

// The Lucky Spaces column's icon in the detailed results, from textures/mp2-lucky-results-icon.ci8: the Blue Spaces
// icon (16x16 pixels, a byte each, a palette index) with a white four-leaf clover. Its pixels (256 bytes, for 0x2C in
// the icon file) then its palette (66 RGBA5551 colors, for 0x12C).
immutable ubyte[] LUCKY_RESULTS_ICON = cast(immutable(ubyte)[])import("mp2-lucky-results-icon.ci8");
static assert(LUCKY_RESULTS_ICON.length == 256 + 66 * 2);

// The Lucky Spaces column's description: the Blue Spaces one (message 0x611) for Lucky Spaces, padded to an even length
immutable ubyte[] LUCKY_DESCRIPTION = cast(immutable(ubyte)[])("\x0BNumber of times player\nlanded on \x02\x0FLucky Spaces" ~
    "\x16\x19\x85\n\x1A\x1A\x1A\x1A\x2B \xFE Back to Last Screen\0\0\0");
static assert(LUCKY_SPACE_TEXTURE.length == 32 * 32 * 4);
