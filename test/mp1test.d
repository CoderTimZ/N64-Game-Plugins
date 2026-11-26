// Mario Party 1 tests, run by the test build of the plugin (dub build -c mp1-test). See test/driver.d.
module me.timz.n64.mp1test;

version (TestDriver):

import me.timz.n64.marioparty;
import me.timz.n64.marioparty1;
import me.timz.n64.game;
import me.timz.n64.testdriver;
import std.algorithm;
import std.array;
import std.conv;
import std.format;
import std.math;
import std.range;
import std.string;
import std.traits;

// States the tests start from, in the test emulator's folder (TestStates/)
// DK's Jungle Adventure, a new game (made from boot with the plugin's options off and an empty State): turn 1 of 20,
// P1's turn, at the dice block (A Block, B Map, R Overview). P1 Yoshi, P2 Mario (human), P3 Luigi, P4 Peach
// (computers), 10 coins each. The default teams make Yoshi and Peach (P1, P4) one team and Mario and Luigi (P2, P3) the
// other.
enum STATE_DK_BEFORE_BONUS = "TestStates/mp1-dk-before-bonus.st"; // DK, the final mini-game's results (turn 20/20):
                                                                    // stars 2, 1, 1, 2 (made by makeBonusState)
enum STATE_DK_TURN_1_CUSTOM = "TestStates/mp1-dk-turn1-custom.st"; // STATE_DK_TURN_1 with mp1-config.json's custom
                                                                    // spaces assigned (space 14 is a converted ! Space)
enum STATE_DK_TURN_1 = "TestStates/mp1-dk-turn1.st";

// Board data the plugin's Memory doesn't have
enum Address CHAINS = 0x800D8110;      // ChainData*: { u16 length; s16* spaces } (8 bytes each)
enum Address CHAIN_COUNT = 0x800D8104; // u16
enum Address STEPS_LEFT = 0x800F3FF0;  // s32: steps left in the moving player's move (counts down on each solid space;
                                       // they land on the one where it reaches 0). 0x800D62D3 + player * 0x44 is only
                                       // the number shown over the player.


class TestMarioParty1 : MarioParty1 {
    TestDriver driver;
    alias d = driver;

    string[] teamMismatches;   // teamScores problems seen on the board
    bool watchTeams;           // Whether to check teams (once a test has set the players up)
    int shotsOnLanding;        // Screenshots land() takes as a landing happens (0: none)

    this(string name, string hash) {
        super(name, hash);
    }

    // A mini-game roulette: the type, the mini-games it showed, the one it stopped on, and the players' panel colors
    struct RoulettePick {
        ulong frame;
        MiniGameType type;
        MiniGame[] shown;
        MiniGame chosen;
        PanelColor[4] colors;
    }
    RoulettePick[] roulettePicks; // Every roulette since the emulator started
    bool splitTeams;              // Make the game's blue and red panels split every team (see splitTeamPanels())
    int[2] forcedChancePlayers = [-1, -1]; // Chance Time's two players, made these when its blocks set them (-1: not)
    int forcedBowserEvent = -1;   // The Bowser Space roulette's result, made this (2: everyone's coins to the average)

    // Hooks for the forced events above
    void forceEvents() {
        data.chancePlayer1.onWrite((ref ubyte v) { if (forcedChancePlayers[0] >= 0) v = cast(ubyte)forcedChancePlayers[0]; });
        data.chancePlayer2.onWrite((ref ubyte v) { if (forcedChancePlayers[1] >= 0) v = cast(ubyte)forcedChancePlayers[1]; });
        // The roulette's result (-1 while it spins), read by func_80049328 and func_80049334
        foreach (Address a; [0x800D670C, 0x800D6710]) {
            a.val!int.onWrite((ref int v) { if (forcedBowserEvent >= 0 && v >= 0) v = forcedBowserEvent; });
        }
    }

    void setScores(int[4] coins, int[4] stars) {
        foreach (i, p; players) {
            p.data.coins = cast(ushort)coins[i];
            p.data.stars = cast(ushort)stars[i];
        }
    }

    int[2][4] scores() {
        int[2][4] result;
        foreach (i, p; players) result[i] = [p.data.coins, p.data.stars];
        return result;
    }

    // Problems with teammates' scores (teamScores keeps them the same)
    string[] teamProblems() {
        string[] problems;
        foreach (p; players) foreach (t; teammates(p)) {
            if (t.index > p.index && (p.data.coins != t.data.coins || p.data.stars != t.data.stars)) {
                problems ~= format("teammates P%d (%dc %ds) and P%d (%dc %ds) differ", p.index + 1, p.data.coins,
                                   p.data.stars, t.index + 1, t.data.coins, t.data.stars);
            }
        }
        return problems;
    }

    // While splitTeams is set, the blue and red panel colors the game sets are replaced so each team has one of each:
    // the round's mini-game is then 2 vs 2 with teammates apart, which teamMiniGames turns into teams against teams
    void splitTeamPanels() {
        foreach (i; 0..4) splitTeamPanel(i);
    }

    // (A function of its own so each hook has its own index: delegates made in a loop share its variables)
    void splitTeamPanel(uint index) {
        data.playerPanels[index].color.onWrite((ref PanelColor color) {
            if (!splitTeams || (color != PanelColor.BLUE && color != PanelColor.RED)) return;
            auto p = players[index];
            auto first = players.find!(q => team(q) == team(p)).front; // The team's first player gets blue
            color = (first.index == p.index) ? PanelColor.BLUE : PanelColor.RED;
        });
    }

    int[4] starsSentInResults = [-1, -1, -1, -1]; // The stars last sent to the Bingo page in the final results

    override void sendPlayerInfo(Player player) {
        if (data.currentScene == Scene.FINAL_RESULTS) starsSentInResults[player.index] = player.data.stars;
        super.sendPlayerInfo(player);
    }

    // Tests never connect to a Bingo page, whatever the config says
    override Config readConfig() {
        auto config = super.readConfig();
        config.bingoURL = "";
        return config;
    }

    // The bonus stars the plugin picked (see RandomBonus)
    @property const(BonusType)[] bonus() { return featureOf!RandomBonus1.bonus; }

    override void onStart() {
        super.onStart();
        driver = new TestDriver(tests());
        clampForcedRolls();
        splitTeamPanels();
        forceEvents();

        0x80042DB4.onExec({ // The roulette (func_80042BAC) has just chosen the slot it stops on (v1)
            if (!isBoardScene()) return;
            auto slot = cast(uint)gpr.v1;
            auto game = data.miniGameRoulette[slot < 5 ? slot : 0];
            if (slot >= 5 || ![EnumMembers!MiniGame].canFind(game)) {
                d.note("Roulette stopped on slot ", slot, " (", cast(uint)game, "), which isn't a mini-game");
                return;
            }
            RoulettePick pick;
            pick.frame = d.frame;
            pick.chosen = game;
            pick.type = type(game);
            pick.shown = iota(min(5, data.miniGameRouletteSizes[pick.type])).map!(i => data.miniGameRoulette[i]).array;
            foreach (i, p; players) pick.colors[i] = p.panel.color;
            roulettePicks ~= pick;
        });
    }

    override void onFrame() {
        super.onFrame();
        checkTeams();
        driver.onFrame();
    }

    // The test's buttons go in first, as a real controller's would (teamControl copies them to teammates)
    override void onInput(int port, InputData* input) {
        driver.onInput(port, input);
        super.onInput(port, input);
    }

    // --- Setup ---

    // Loads a state and sets the players up for the tests: computers (unless allCPU is false), the same coins and stars
    // within each team, and the turns
    void setUp(string stateFile, ubyte currentTurn = 0, ubyte totalTurns = 0, bool allCPU = true) {
        watchTeams = false;
        d.loadEmulatorState(stateFile);
        if (allCPU) players.each!(p => p.data.flags = p.data.flags | 1);
        foreach (p; players) foreach (t; teammates(p)) {
            if (t.index > p.index) {
                t.data.coins = p.data.coins;
                t.data.stars = p.data.stars;
            }
        }
        if (currentTurn) data.currentTurn = currentTurn;
        if (totalTurns) data.totalTurns = totalTurns;
        teamMismatches = null;
        watchTeams = true;
        d.note("Set up: ", describe());
    }

    string describe() {
        return format("%s, turn %d/%d, P%d's turn: ", data.currentScene, data.currentTurn, data.totalTurns,
                      data.currentPlayerIndex + 1) ~
               players.map!(p => format("P%d %s %dc %ds%s", p.index + 1, p.data.character, p.data.coins, p.data.stars,
                                        p.isCPU ? " CPU" : "")).join(", ");
    }

    // --- Board ---

    // The board's chains exist only while a board is loaded: these check the game's pointers before following them,
    // since following a stale or null one would read outside the N64's memory (and crash the emulator)
    static bool valid(Address a) { return a >= 0x80000000 && a < 0x80800000; }
    ushort chainCount() { return valid(CHAINS.val!uint) ? CHAIN_COUNT.val!ushort : 0; }
    ushort chainLength(uint c) {
        auto chains = CHAINS.val!uint;
        return valid(chains) && c < chainCount ? (chains + c * 8).val!ushort : 0;
    }
    short chainSpace(uint c, uint i) {
        if (i >= chainLength(c)) return -1;
        auto spaces = (CHAINS.val!uint + c * 8 + 4).val!uint;
        return valid(spaces) ? Ptr!short(spaces)[i] : -1;
    }

    // Where a space is: its chain and its position in the chain (the first one found), or [-1, -1]
    int[2] findInChains(short space) {
        foreach (c; 0..chainCount) foreach (i; 0..chainLength(c)) {
            if (chainSpace(c, i) == space) return [c, i];
        }
        return [-1, -1];
    }

    // Spaces of a type that a player can be moved one step onto (not first in their chain)
    short[] reachableSpaces(Space.Type type) {
        short[] result;
        foreach (c; 0..chainCount) foreach (i; 1..chainLength(c)) {
            auto s = chainSpace(c, i);
            if (data.spaces[s].type == type && !result.canFind(s)) result ~= s;
        }
        return result;
    }

    // Puts a player on the space before `space` in its chain, so a one-step move lands on it
    void moveBefore(Player p, short space) {
        auto at = findInChains(space);
        d.check(at[0] >= 0 && at[1] >= 1, "Space " ~ space.to!string ~ " can't be reached in one step");
        p.data.currentChainIndex = cast(ushort)at[0];
        p.data.currentSpaceIndex = cast(ushort)(at[1] - 1);
        p.data.nextChainIndex = cast(ushort)at[0];
        p.data.nextSpaceIndex = cast(ushort)at[1];
        d.note("Moved P", p.index + 1, " before space ", space, " (chain ", at[0], ", position ", at[1], ")");
    }

    ref int stepsLeft() { return STEPS_LEFT.val!int; }

    bool forcing;   // forceLanding(): whether the roll the game sets is made 1
    int forcedRoll; // The roll the game set (0 until it does)

    // Makes the roll the game sets 1 while forcing (a roll is a write that isn't a step's count down)
    void clampForcedRolls() {
        STEPS_LEFT.val!int.onWrite((ref int steps) {
            if (!forcing || forcedRoll) return;
            if (steps <= 0 || steps == stepsLeft - 1) return;
            forcedRoll = steps;
            steps = 1;
        });
    }

    // Makes a player's next move land on `space`: puts them one space before it, and makes their roll 1 (once the
    // game sets it, putting them before the space again, in case it moved them). Steps left is 0 between moves, so if
    // it isn't, the roll is already set, and the player may have started moving.
    void forceLanding(Player p, short space) {
        moveBefore(p, space);
        if (stepsLeft > 0) {
            d.note("P", p.index + 1, " already rolled ", stepsLeft);
            stepsLeft = 1;
            return;
        }
        forcedRoll = 0;
        forcing = true;
        scope (exit) forcing = false;
        d.waitUntil(() => forcedRoll != 0, "P" ~ (p.index + 1).to!string ~ "'s roll", 60 * 60 * 3);
        d.note("P", p.index + 1, " rolled ", forcedRoll);
        moveBefore(p, space);
        stepsLeft = 1;
    }

    short spaceOf(Player p) {
        return chainSpace(p.data.currentChainIndex, p.data.currentSpaceIndex);
    }

    // Waits for the start of a player's turn on the board
    void waitForTurn(uint player, string why = null) {
        d.waitUntil(() => isBoardScene() && data.currentPlayerIndex == player, "P" ~ (player + 1).to!string ~ "'s turn" ~
                    (why ? " (" ~ why ~ ")" : ""));
    }

    void waitForScene(Scene scene, ulong maxFrames = 60 * 60 * 5) {
        d.waitUntil(() => data.currentScene == scene, "scene " ~ scene.to!string, maxFrames);
    }

    void waitWhileScene(Scene scene, ulong maxFrames = 60 * 60 * 5) {
        d.waitUntil(() => data.currentScene != scene, "the end of scene " ~ scene.to!string, maxFrames);
    }

    // --- teamScores ---

    // On the board, teammates always have the same coins and stars
    void checkTeams() {
        if (!d || !watchTeams || !config.teamScores || !isBoardScene()) return;
        foreach (p; players) foreach (t; teammates(p)) {
            if (t.index < p.index) continue;
            if (p.data.coins != t.data.coins || p.data.stars != t.data.stars) {
                auto problem = format("%s turn %d: P%d %dc %ds but teammate P%d %dc %ds", data.currentScene,
                                      data.currentTurn, p.index + 1, p.data.coins, p.data.stars, t.index + 1,
                                      t.data.coins, t.data.stars);
                if (teamMismatches.empty || teamMismatches[$ - 1] != problem) {
                    teamMismatches ~= problem;
                    d.note("TEAM MISMATCH ", problem);
                }
            }
        }
    }

    void checkNoTeamMismatches() {
        d.check(teamMismatches.empty, "Teammates' coins or stars differed on the board " ~
                teamMismatches.length.to!string ~ " times, first: " ~ (teamMismatches.empty ? "" : teamMismatches[0]));
    }

    // --- Tests ---

    Test[] tests() {
        return [
            Test("smoke", &smoke, 60 * 60),
            Test("jalFromExec", &jalFromExec, 60 * 60),
            Test("jumpTiming", &jumpTiming, 60 * 60),
            Test("execEventsPaired", &execEventsPaired, 60 * 60),
            Test("patchedCode", &patchedCode, 60 * 60),
            Test("delaySlotJump", &delaySlotJump, 60 * 60),
            Test("newHookTypes", &newHookTypes, 60 * 60),
            Test("customSpaces", &customSpaces, 60 * 60 * 5),
            Test("staleCustomSpaces", &staleCustomSpaces, 60 * 60),
            Test("landOnCustomSpaces", &landOnCustomSpaces, 60 * 60 * 20),
            Test("bonusStars", &bonusStars, 60 * 60 * 20),
            Test("bonusStarCases", &bonusStarCases, 60 * 60 * 20),
            Test("makeBonusState", &makeBonusState, 60 * 60 * 20),
            Test("makeCustomSpacesState", &makeCustomSpacesState, 60 * 60),
            Test("chanceTimeTeams", &chanceTimeTeams, 60 * 60 * 10),
            Test("bowserAverage", &bowserAverage, 60 * 60 * 10),
            Test("booTeams", &booTeams, 60 * 60 * 10),
            Test("teamControl", &teamControl, 60 * 60 * 10),
            Test("mapScrollSpeed", &mapScrollSpeed, 60 * 60 * 5),
            Test("miniGameRoulette", () => miniGameRoulette(false), 60 * 60 * 60),
            Test("teamMiniGames", () => miniGameRoulette(true), 60 * 60 * 60),
            Test("mapEventSpaces", &mapEventSpaces, 60 * 60 * 30),
            Test("landOnEachConverted", &landOnEachConverted, 60 * 60 * 60),
            Test("explore", &explore, 60 * 60 * 30),
            Test("serve", &serve, ulong.max),
        ];
    }

    // preventRepeatMiniGames, blockedMiniGames, teamMiniGames: plays (all CPU) until there have been N64TEST_ARG
    // roulettes (8 by default), and checks each: the game played is the one it stopped on, which isn't blocked, and in
    // a 2 vs 2 teammates are on the same side. Then that no type repeats a mini-game within a cycle of its allowed ones.
    // With split, every team's panels are split, so every round's mini-game should be teams against teams.
    void miniGameRoulette(bool split) {
        setUp(STATE_DK_TURN_1);
        splitTeams = split;
        scope (exit) splitTeams = false;
        auto count = d.arg.empty ? 8 : d.arg.to!int;
        auto first = roulettePicks.length;
        string[] problems;

        foreach (n; 0..count) {
            d.waitUntil(() => roulettePicks.length > first + n, "roulette " ~ (n + 1).to!string, 60 * 60 * 10);
            auto pick = roulettePicks[first + n];

            Scene[] scenes;
            Scene scene = data.currentScene;
            d.waitUntil(() => !isBoardScene(), "the mini-game to start", 60 * 60);
            d.waitUntil(() {
                if (data.currentScene != scene) {
                    scene = data.currentScene;
                    if (!isBoardScene(scene) && scene != cast(Scene)53) scenes ~= scene;
                }
                return isBoardScene();
            }, "the board after the mini-game", 60 * 60 * 10);

            d.note(format("Roulette %d (%s, turn %d): %s from %s, panels %s; scenes %s", n + 1, pick.type,
                          data.currentTurn, pick.chosen, pick.shown, pick.colors, scenes));
            auto what = format("roulette %d (%s)", n + 1, pick.chosen);
            if (!pick.shown.canFind(pick.chosen)) problems ~= what ~ " wasn't one it showed";
            if (config.blockedMiniGames.canFind(pick.chosen)) problems ~= what ~ " is blocked";
            if (!scenes.canFind!(s => s.to!string == pick.chosen.to!string)) problems ~= what ~ " wasn't played: " ~ scenes.to!string;
            if (split && pick.type != MiniGameType.TWO_V_TWO && pick.type != MiniGameType.ONE_PLAYER) {
                problems ~= what ~ " isn't 2 vs 2, with every team's panels split";
            }
            if (pick.type == MiniGameType.TWO_V_TWO && config.teamMiniGames) {
                foreach (p; players) foreach (t; teammates(p)) {
                    if (pick.colors[p.index] != pick.colors[t.index]) problems ~= what ~ format(": teammates P%d and P%d on different sides", p.index + 1, t.index + 1);
                }
            }
        }

        foreach (kind; EnumMembers!MiniGameType) {
            auto chosen = roulettePicks[first..$].filter!(p => p.type == kind).map!(p => p.chosen).array;
            auto allowed = [EnumMembers!MiniGame].count!(g => type(g) == kind && !config.blockedMiniGames.canFind(g));
            d.note(kind, " (", allowed, " allowed): ", chosen);
            if (!config.preventRepeatMiniGames || allowed == 0) continue;
            for (size_t start = 0; start < chosen.length; start += allowed) {
                auto cycle = chosen[start .. min($, start + allowed)];
                if (cycle.dup.sort.uniq.count != cycle.length) problems ~= format("%s repeated a mini-game within a cycle: %s", kind, cycle);
            }
        }
        d.check(problems.empty, problems.join("; "));
    }

    // randomBonus edge cases: on the final turn, with stars to start with, sets every player's stats as the bonus scene
    // starts (so the bonus stars are decided on them), then follows the stars to the final results. Each team should
    // gain the bonus stars its players won (a tie between teammates counting for both), and teammates should match.
    // Run it with a config whose bonuses are the 3 the stats are set up for (test/mp1-config-bonus-a.json, -b.json).
    void bonusStarCases() {
        setUp(STATE_DK_BEFORE_BONUS);

        d.waitUntil(() => isBonusScene(), "the bonus stars", 60 * 60 * 3);
        auto starsBefore = players.map!(p => cast(int)p.data.stars).array;
        foreach (i, p; players) {
            p.data.miniGameCoins = cast(short)[-5, -5, -12, -30][i]; // A tie on a negative Game Star total, across teams
            p.data.blueSpaces = cast(ubyte)[3, 9, 9, 3][i];          // A tie between teammates (P2 and P3)
            p.data.happeningSpaces = 2;                               // A 4-way tie: nobody
            p.data.maxCoins = cast(ushort)[40, 25, 25, 40][i];       // A tie between teammates (P1 and P4)
            p.data.mushroomSpaces = cast(ubyte)[0, 2, 2, 2][i];       // A 3-way tie
            p.data.redSpaces = cast(ubyte)[1, 5, 0, 0][i];            // One winner (P2)
        }
        // Without randomBonus, the game's own: the Game, Coin and Happening Stars
        auto chosen = config.randomBonus ? bonus.take(3).array : [BonusType.MINI_GAME, BonusType.COIN, BonusType.HAPPENING];
        d.note("Bonus scene ", data.currentScene, ", bonus stars ", chosen, "; ", describe());
        d.check(chosen.length == 3, "The plugin didn't pick 3 bonus stars");

        int[4] won;
        foreach (b; chosen) {
            auto value = (int i) => cast(int)featureOf!RandomBonus1.stat(players[i], b);
            auto best = iota(4).map!(i => value(i)).maxElement;
            auto winners = iota(4).filter!(i => value(i) == best).array;
            d.note(b, ": ", iota(4).map!(i => value(i)).array, " -> ", winners.length == 4 ? "nobody" : winners.map!(w => "P" ~ (w + 1).to!string).join(", "));
            if (winners.length < 4) foreach (w; winners) won[w]++;
        }

        // The game adds the bonus stars to the players' stars during the final results (and takes them back off when
        // it goes back to the title screen)
        starsSentInResults = [-1, -1, -1, -1];
        Scene scene = data.currentScene;
        d.waitUntil(() {
            if (data.currentScene != scene) {
                scene = data.currentScene;
                d.note("Scene ", scene, ": bonus stars ", iota(4).map!(i => data.bonusStars[i]).array);
            }
            return data.currentScene == Scene.FINAL_RESULTS;
        }, "the final results", 60 * 60 * 3);
        auto starsAtResults = players.map!(p => cast(int)p.data.stars).array;
        d.check(starsAtResults == starsBefore, format("Stars changed before the final results: %s -> %s", starsBefore, starsAtResults));
        d.waitUntil(() => players.any!(p => p.data.stars != starsAtResults[p.index]) || data.currentScene != Scene.FINAL_RESULTS,
                    "the bonus stars to be added", 60 * 60);
        d.wait(30); // In case they're added one player at a time
        if (d.arg == "shots") d.screenshot("final results");
        auto starsWithBonus = players.map!(p => cast(int)p.data.stars).array;
        d.waitUntil(() => data.currentScene != Scene.FINAL_RESULTS, "the end of the final results", 60 * 60 * 2);
        d.note("After the final results: stars ", players.map!(p => p.data.stars).array);

        string[] problems;
        d.note("Stars sent to the Bingo page in the final results: ", starsSentInResults);
        if (starsSentInResults != starsWithBonus) problems ~= format("the Bingo page got stars %s, not %s", starsSentInResults, starsWithBonus);
        foreach (i, p; players) {
            auto expected = starsBefore[i] + (config.teamScores ? teamMembers(p).map!(t => won[t.index]).sum : won[i]);
            auto got = starsWithBonus[i];
            d.note(format("P%d: %d -> %d stars, expected %d (own wins %d)", i + 1, starsBefore[i], got, expected, won[i]));
            if (got != expected) problems ~= format("P%d has %d stars, expected %d", i + 1, got, expected);
        }
        d.check(problems.empty, problems.join("; "));
    }

    // Makes STATE_DK_BEFORE_BONUS: plays the final turn from STATE_DK_TURN_1 (run it with the plain config, so the
    // state has no custom spaces) and saves when the final mini-game's results start
    void makeBonusState() {
        setUp(STATE_DK_TURN_1, 20, 20);
        foreach (i, p; players) p.data.stars = cast(ushort)[2, 1, 1, 2][i]; // Someone has a Star: FINISH_BOARD
        waitForTurn(3, "P4's turn, before the round's mini-game"); // Not a 1P game from a Mini-Game Space
        d.waitUntil(() => data.currentScene == Scene.MINI_GAME_RESULTS, "the final mini-game's results", 60 * 60 * 10);
        d.saveEmulatorState(STATE_DK_BEFORE_BONUS);
        d.note("Saved: ", describe());
    }

    // Makes STATE_DK_TURN_1_CUSTOM again, with its custom spaces in the plugin's state (in the game's memory): from the
    // board's spaces in the state made by an older version of the plugin (whose state the plugin can't read), compared
    // with STATE_DK_TURN_1's (blue spaces that are another type now are converted ones)
    void makeCustomSpacesState() {
        // (without the plugin's custom spaces while it reads the board's own)
        auto customSpaces = featureOf!CustomSpaces1;
        removeHandlers(hooks.exec, HookKind.EXECUTE, 0x8004BA04);
        setUp(STATE_DK_TURN_1);
        auto original = iota(data.spaceCount).map!(i => data.spaces[i].type).array;
        setUp(STATE_DK_TURN_1_CUSTOM);
        customSpaces.hookExec!(CustomSpaces1.renderSpaces)(0x8004BA04);
        d.check(data.spaceCount == original.length, "The two states have different boards");
        spacesBoard = data.currentBoard;
        spaces = iota(data.spaceCount).map!(i => original[i] != Space.Type.BLUE ? CustomSpace.DEFAULT
                                                 : data.spaces[i].type == Space.Type.BLUE ? CustomSpace.LOCKED
                                                 : cast(CustomSpace)data.spaces[i].type).array;
        d.wait(30); // (written to the game's memory at the next frame)
        d.check(spaces[14] == CustomSpace.CHANCE, "Space 14 isn't a converted ! Space");
        d.saveEmulatorState(STATE_DK_TURN_1_CUSTOM);
        d.note("Saved, with ", spaces.count!(c => c >= 0 && c != CustomSpace.BLUE), " converted spaces");
    }

    // teamScores in Chance Time: P1 lands on a converted ! Space, and Chance Time's players are made P1 and a
    // teammate (N64TEST_ARG "teammates", the default: nothing should change) or an opponent ("opponents": teammates'
    // scores should still match)
    void chanceTimeTeams() {
        setUp(STATE_DK_TURN_1_CUSTOM);
        setScores([30, 5, 5, 30], [2, 1, 1, 2]);
        auto opponents = d.arg == "opponents";
        forcedChancePlayers = opponents ? [0, 1] : [0, 3];
        scope (exit) forcedChancePlayers = [-1, -1];
        auto before = scores();
        auto r = land(14, Space.Type.CHANCE);
        d.note("Landed: ", r.describe, "; outcome ", data.chanceOutcome, "; scores ", before, " -> ", scores());
        d.check(r.scenes.canFind(Scene.CHANCE_TIME), "No Chance Time: " ~ r.scenes.to!string);
        auto problems = teamProblems();
        if (!opponents && scores() != before) problems ~= format("scores changed in a Chance Time between teammates: %s -> %s", before, scores());
        d.check(problems.empty, problems.join("; "));
    }

    // The Bowser Space event that sets everyone's coins to the average, with teamScores: P1 lands on Bowser Space 16
    // with the event forced. The average of 40, 10, 10, 40 is 25.
    void bowserAverage() {
        setUp(STATE_DK_TURN_1_CUSTOM);
        setScores([40, 10, 10, 40], [0, 0, 0, 0]);
        forcedBowserEvent = 2;
        scope (exit) forcedBowserEvent = -1;
        auto r = land(16, Space.Type.BOWSER);
        d.note("Landed: ", r.describe, "; scores ", scores());
        d.check(r.scenes.canFind(Scene.BOWSER), "No Bowser event: " ~ r.scenes.to!string);
        auto problems = teamProblems();
        foreach (p; players) if (p.data.coins != 25) problems ~= format("P%d has %d coins, not 25", p.index + 1, p.data.coins);
        d.check(problems.empty, problems.join("; "));
    }

    // Boo with teamScores, for a CPU: P1 passes DK's Boo (space 10; Boo runs on the board, not in a scene of its own).
    // First only P1's teammate has coins and stars, so Boo can't steal anything (nobody loses any); then opponents
    // have them too, so Boo steals from them, and teammates' scores should still match.
    void booTeams() {
        string[] problems;
        foreach (opponentsHaveSome; [false, true]) {
            setUp(STATE_DK_TURN_1_CUSTOM);
            auto opponents = opponentsHaveSome ? 20 : 0;
            setScores([30, opponents, opponents, 30], [1, opponentsHaveSome ? 1 : 0, opponentsHaveSome ? 1 : 0, 1]);
            auto before = scores();
            auto r = land(10, Space.Type.INVISIBLE);
            d.note(opponentsHaveSome ? "Opponents have coins: " : "Only P1's teammate has coins: ", r.describe,
                   "; scores ", before, " -> ", scores());
            problems ~= teamProblems();
            auto after = scores();
            auto lost = iota(4).filter!(i => after[i][0] < before[i][0] || after[i][1] < before[i][1]).array;
            if (!opponentsHaveSome && !lost.empty) problems ~= format("Boo stole from P1's teammate: %s -> %s", before, after);
            if (opponentsHaveSome && !lost.all!(i => i == 1 || i == 2)) problems ~= format("Boo stole from the wrong team: %s -> %s", before, after);
            if (opponentsHaveSome && lost.empty) problems ~= "Boo didn't steal from the opponents";
        }
        d.check(problems.empty, problems.join("; "));
    }

    // teamControl: a human's teammate on a later controller is played with the human's controller. P1 Yoshi is made
    // human on controller 1 at the start of his turn (rolling with A, onto a Blue Space); when P4 Peach's turn comes
    // (she's his teammate), she should not be a CPU, should wait for her roll, and A on controller 1 should hit it.
    void teamControl() {
        setUp(STATE_DK_TURN_1_CUSTOM);
        auto yoshi = players[0], peach = players[3];
        yoshi.data.flags = yoshi.data.flags & ~1;
        yoshi.data.controller = 0;
        d.note("Controllers: ", players.map!(p => p.data.controller + 1).array, "; ", describe());
        d.check(peach.data.controller > 0, "Peach is on controller 1 already");

        // One step onto a Blue Space (no junction to choose at): his roll may already be set (the CPU hits the block
        // quickly), or not yet, when A hits it
        auto target = reachableSpaces(Space.Type.BLUE).front;
        moveBefore(yoshi, target);
        if (stepsLeft > 0) {
            stepsLeft = 1;
        } else {
            forcedRoll = 0;
            forcing = true;
            scope (exit) forcing = false;
            d.wait(60);
            d.press(0, Pad.A, 10);
            d.waitUntil(() => forcedRoll != 0, "Yoshi's roll", 300);
        }
        // With a human in the game, some messages in other scenes (like Chance Time's) wait for A: press it now and
        // then there, but not on the board (where it could pick something in a CPU's turn) until Peach's turn
        d.waitUntil(() {
            if (d.arg == "shots" && d.frame % 300 == 0) d.screenshot(format("P%d's turn, %s", data.currentPlayerIndex + 1, data.currentScene));
            auto peachsTurn = isBoardScene() && data.currentPlayerIndex == 3;
            if (isBoardScene()) d.release(0);
            else if (d.frame % 90 == 0) d.hold(0, Pad.A);
            else if (d.frame % 90 == 5) d.hold(0, 0);
            return peachsTurn;
        }, "Peach's turn", 60 * 60 * 10);
        d.release(0);

        d.wait(300);
        d.check(!peach.isCPU, "Peach is a CPU");
        d.check(stepsLeft == 0, format("Peach rolled (%d) without anyone pressing A", stepsLeft));
        auto start = d.frame;
        d.waitUntil(() {
            if ((d.frame - start) % 60 == 0) d.hold(0, Pad.A);
            else if ((d.frame - start) % 60 == 5) d.hold(0, 0);
            return stepsLeft > 0;
        }, "Peach's roll, pressing A on controller 1", 60 * 15);
        d.release(0);
        d.note("Peach rolled ", stepsLeft, " with controller 1");
    }

    // mapScrollSpeedMultiplier: P1 (made human) opens the map with B at the dice block; the game's scroll speed
    // (0x800D672C, 4 normally) should be 4 times the multiplier. Screenshots before and after holding the stick up
    // for 20 frames show how far it scrolls.
    void mapScrollSpeed() {
        setUp(STATE_DK_TURN_1_CUSTOM);
        auto yoshi = players[0];
        yoshi.data.flags = yoshi.data.flags & ~1;
        yoshi.data.controller = 0;
        // B opens the map at the dice block or at a junction (whichever comes first): press it until the map sets
        // its scroll speed
        ref float speed() { return (cast(Address)0x800D672C).val!float; }
        auto before = speed;
        auto start = d.frame;
        d.waitUntil(() {
            if ((d.frame - start) % 30 == 0) d.hold(0, Pad.B);
            else if ((d.frame - start) % 30 == 5) d.hold(0, 0);
            return speed != before;
        }, "the map to open", 60 * 30);
        d.release(0);
        d.wait(60);
        d.screenshot("map opened");
        d.hold(0, 0, 0, 80);
        d.wait(20);
        d.release(0);
        d.wait(5);
        d.screenshot("after 20 frames of scrolling up");
        auto expected = 4.0f * config.mapScrollSpeedMultiplier;
        d.note("Map scroll speed ", speed, " (", before, " before the map), expected ", expected);
        d.check(abs(speed - expected) < 0.001, format("The map scroll speed is %s, not %s", speed, expected));
    }

    // Custom spaces from another board aren't used: STATE_DK_TURN_1_CUSTOM's are DK's, then spaces that are all
    // ! Spaces, for another board, are replaced. The board's ! Spaces (all converted ones; DK has none of its own) stay
    // as they were.
    void staleCustomSpaces() {
        setUp(STATE_DK_TURN_1_CUSTOM);
        d.wait(5);
        auto board = cast(int)data.currentBoard;
        auto chanceSpaces = () => iota(data.spaceCount).count!(i => data.spaces[i].type == Space.Type.CHANCE);
        auto chanceBefore = chanceSpaces();
        d.note("Board ", board, ", custom spaces for board ", spacesBoard, ", space 14 ", spaces[14],
               ", ", chanceBefore, " ! Spaces");
        d.check(spacesBoard == board, "The state's spaces aren't this board's");
        d.check(spaces[14] == CustomSpace.CHANCE, "Space 14 isn't a converted ! Space any more");
        // DK has no ! Spaces of its own, so they're all the State's (and none from the State before the load)
        auto marked = spaces.count!(c => c == CustomSpace.CHANCE);
        d.check(chanceBefore == marked, format("The board has %d ! Spaces, but the State marks %d", chanceBefore, marked));

        spaces[] = CustomSpace.CHANCE;
        spacesBoard = board == 0 ? 1 : 0;
        d.wait(5);
        auto stale = spaces.count!(c => c == CustomSpace.CHANCE);
        d.note("After another board's spaces: custom spaces for board ", spacesBoard, ", ", stale,
               " marked ! Spaces, ", chanceSpaces(), " ! Spaces");
        d.check(spacesBoard == board, "The spaces aren't for this board");
        d.check(stale < spaces.length / 2, "Another board's spaces were kept");
        d.check(chanceSpaces() == chanceBefore, format("The board has %d ! Spaces, not %d", chanceSpaces(), chanceBefore));
    }

    // jal() from an onExec hook: the call gets its arguments (GetPlayerStruct(2) returns P3's), and the registers are
    // back as they were once it returns to the hooked address
    void jalFromExec() {
        setUp(STATE_DK_TURN_1);
        bool armed = true, returned, returnedAtOnce;
        uint result;
        GPR before, after;
        0x8004BA04.onExec({ // RenderSpaces, each frame on the board
            if (!armed) return;
            armed = false;
            before = *gpr;
            0x80052A8C.jal(2, (uint v) { // GetPlayerStruct(index)
                result = v;
                after = *gpr;
                returned = true;
            });
            returnedAtOnce = returned; // The call hasn't run yet: the callback is for when it returns
        });
        d.waitUntil(() => returned, "the call to return", 60);
        d.check(!returnedAtOnce, "The callback ran before the call did");
        d.check(result == 0x800F3310, format("GetPlayerStruct(2) returned %08X, not P3's 800F3310", result));
        foreach (i; 0..32) {
            d.check(before.r[i].v == after.r[i].v, format("Register %d was %X before the call and %X after", i,
                    before.r[i].v, after.r[i].v));
        }
        d.note("GetPlayerStruct(2) returned ", result.to!string(16), " and the registers were restored");
    }

    // Free memory for code the tests write: the top of the Expansion Pak's RDRAM, which Mario Party doesn't use
    enum Address SCRATCH = 0x80700000;

    void writeCode(Address at, const Instruction[] code) {
        d.check(memory.length >= 0x800000, "The test writes code to the Expansion Pak's RDRAM, which isn't there");
        foreach (i, w; code) (at + cast(uint)(i * 4)).setCode(w);
    }

    // Calls code the test wrote (from RenderSpaces, on the board) and returns v0
    uint callCode(Address address) {
        bool armed = true, returned;
        uint result;
        0x8004BA04.onExec({
            if (!armed) return;
            armed = false;
            address.jal((uint v) { result = v; returned = true; });
        });
        d.waitUntil(() => returned, "the call to return", 60);
        return result;
    }

    enum Instruction JR_RA = 0x03E00008;
    static Instruction addiuV0(short v) { return 0x24020000 | cast(ushort)v; } // addiu v0, zero, v

    // jump() keeps the CPU's cycle count (CP0 Count) right. The interpreters count cycles from how far the PC got since
    // the last branch, so a jump made the next count add the distance jumped: a jump forward added about a cycle per 4
    // bytes (1.7M from HuPrcVSleep to the scratch code), and one back wrapped around and added about 2^30. Reads Count
    // (with code the test writes) around a call back to GetPlayerStruct and calls forward to the scratch code.
    void jumpTiming() {
        setUp(STATE_DK_TURN_1);
        enum Address READ_COUNT = SCRATCH + 0x5000;
        writeCode(READ_COUNT, [0x40024800, JR_RA, NOP]); // mfc0 v0, Count
        bool armed = true, done;
        uint c0, c1, c2, result;
        0x800635B4.onExec({ // HuPrcVSleep: above GetPlayerStruct, below the scratch code
            if (!armed) return;
            armed = false;
            READ_COUNT.jal((uint a) {
                c0 = a;
                READ_COUNT.jal((uint b) { // A jump forward (from HuPrcVSleep)
                    c1 = b;
                    0x80052A8C.jal(2, (uint v) { // And one back
                        result = v;
                        READ_COUNT.jal((uint c) { c2 = c; done = true; });
                    });
                });
            });
        });
        d.waitUntil(() => done, "the calls to return", 60);
        d.note("Count went up by ", c1 - c0, " over a call forward, and ", c2 - c1, " over a call back");
        d.check(result == 0x800F3310, format("GetPlayerStruct(2) returned %08X, not P3's 800F3310", result));
        d.check(c1 - c0 < 10_000, format("Count went up by %d over a call that runs a few instructions", c1 - c0));
        d.check(c2 - c1 < 10_000, format("Count went up by %d over a call back to GetPlayerStruct", c2 - c1));
    }

    // Execute and ExecuteDone come in pairs: Execute isn't sent twice in a row for an instruction. (The pure interpreter
    // sent a delay slot's twice. The cached interpreter sent the instruction after the end of its decoded code twice:
    // the code is decoded up to 0x3F8 bytes into the next 4 KB page, so that takes a long run of code without a jump,
    // which the test writes.) Also watches all of three busy stretches of the game's code, with their delay slots.
    void execEventsPaired() {
        setUp(STATE_DK_TURN_1);
        bool active = true;
        Address lastExecute = 0; // The last event was Execute for this address (0: it wasn't an Execute)
        ulong executes, doubles;
        Address[] doubled;
        auto onExecute = (Address pc) {
            if (!active) return;
            executes++;
            if (pc == lastExecute) {
                doubles++;
                if (doubled.length < 10 && !doubled.canFind(pc)) doubled ~= pc;
            }
            lastExecute = pc;
        };
        auto onDone = (Address pc) { if (active) lastExecute = 0; };

        // 0x104 NOPs from 16 bytes before a page to past where its block's decoded code ends, then return
        enum Address RUN = SCRATCH + 0xFF0, RUN_END = SCRATCH + 0x1400;
        writeCode(RUN, repeat(NOP, (RUN_END - RUN) / 4).array ~ [JR_RA, NOP]);

        Address[] addresses;
        foreach (range; [[0x8004B000, 0x8004D000], [0x80052000, 0x80053000], [0x80063000, 0x80064000], [RUN, RUN_END + 8]]) {
            for (Address a = range[0]; a < range[1]; a += 4) addresses ~= a;
        }
        foreach (a; addresses) {
            a.onExec(onExecute);
            a.onExecDone(onDone);
        }
        d.wait(60);
        callCode(RUN);
        d.wait(60);
        active = false; // The handlers stay (removing them would remove the plugin's own at these addresses)
        d.note(executes, " Executes, ", doubles, " twice in a row",
               doubled.empty ? "" : " (at " ~ doubled.map!(a => a.to!string(16)).join(", ") ~ ")");
        d.check(executes > 1000, "Too few instructions ran to tell");
        d.check(doubles == 0, format("Execute was sent twice in a row %d times", doubles));
    }

    // jump() from Execute in a delay slot goes where the plugin says, not where the branch goes, for a branch within
    // the page (BEQ) and one to another page (J)
    void delaySlotJump() {
        setUp(STATE_DK_TURN_1);
        enum Address BRANCH = SCRATCH + 0x2000, JUMP = SCRATCH + 0x3000, FAR = SCRATCH + 0x4000;
        writeCode(BRANCH, [
            0x10000004,  NOP,               // beq zero, zero, +0x14 (always), with its delay slot
            addiuV0(2),  JR_RA, NOP,        // after the delay slot: 2
            addiuV0(1),  JR_RA, NOP,        // the branch's target: 1
            addiuV0(3),  JR_RA, NOP,        // where the plugin jumps: 3
        ]);
        writeCode(JUMP, [
            0x08000000 | ((FAR >> 2) & 0x3FFFFFF), NOP, // j FAR, with its delay slot
            addiuV0(3),  JR_RA, NOP,        // where the plugin jumps: 3
        ]);
        writeCode(FAR, [addiuV0(1), JR_RA, NOP]);

        d.check(callCode(BRANCH) == 1 && callCode(JUMP) == 1, "The code the test wrote doesn't work");
        (BRANCH + 4).onExec({ jump(BRANCH + 32); });
        (JUMP + 4).onExec({ jump(JUMP + 8); });
        auto branch = callCode(BRANCH), far = callCode(JUMP);
        clearExec(BRANCH + 4);
        clearExec(JUMP + 4);
        d.note("After jumping from the delay slots: ", branch, " (BEQ), ", far, " (J)");
        d.check(branch == 3, format("Jumping from BEQ's delay slot ended up returning %d, not 3", branch));
        d.check(far == 3, format("Jumping from J's delay slot ended up returning %d, not 3", far));
    }

    // Reads and writes by the unaligned (LWL, LWR, LDL, LDR, SWL, SWR, SDL, SDR) and FPU (LWC1, LDC1, SWC1, SDC1) loads
    // and stores reach the handlers: a word's or doubleword's handlers, with its aligned address, see the whole value
    // (for a store, as the store leaves it) and can change it. Runs code the test writes on words it watches.
    void newHookTypes() {
        setUp(STATE_DK_TURN_1);
        enum Address D = SCRATCH + 0x6000, CODE = SCRATCH + 0x7000;
        enum Instruction T0_D_HI = 0x3C088070, T0_D_LO = 0x35086000;     // lui t0, 0x8070; ori t0, t0, 0x6000
        enum Instruction T1_HI = 0x3C099988, T1_LO = 0x35297766;         // lui t1, 0x9988; ori t1, t1, 0x7766

        bool active;
        int hits0, hits4, hits8;
        uint seen0, seen4, replace0, replace4;
        ulong seen8, replace8;
        bool doReplace0, doReplace4, doReplace8;
        D.val!uint.onRead((ref uint v) { if (!active) return; hits0++; seen0 = v; if (doReplace0) v = replace0; });
        (D + 4).val!uint.onRead((ref uint v) { if (!active) return; hits4++; seen4 = v; if (doReplace4) v = replace4; });
        D.val!ulong.onRead((ref ulong v) { if (!active) return; hits8++; seen8 = v; if (doReplace8) v = replace8; });
        D.val!uint.onWrite((ref uint v) { if (!active) return; hits0++; seen0 = v; if (doReplace0) v = replace0; });
        (D + 4).val!uint.onWrite((ref uint v) { if (!active) return; hits4++; seen4 = v; if (doReplace4) v = replace4; });
        D.val!ulong.onWrite((ref ulong v) { if (!active) return; hits8++; seen8 = v; if (doReplace8) v = replace8; });

        string[] problems;
        uint run(string name, const Instruction[] body, uint w0 = 0x11223344, uint w4 = 0x55667788) {
            D.val!uint = w0;
            (D + 4).val!uint = w4;
            writeCode(CODE, [T0_D_HI, T0_D_LO, T1_HI, T1_LO] ~ body ~ [JR_RA, NOP]);
            hits0 = hits4 = hits8 = 0;
            seen0 = seen4 = 0;
            seen8 = 0;
            active = true;
            auto v0 = callCode(CODE);
            active = false;
            return v0;
        }
        void expect(string what, bool ok, string detail) {
            if (!ok) problems ~= what ~ ": " ~ detail;
            else d.note("ok ", what);
        }
        uint word(Address a) { return a.val!uint; }

        // LWL/LWR of the word at D+1: each instruction's word, the first one changed
        doReplace0 = true; replace0 = 0xAABBCCDD; doReplace4 = false; doReplace8 = false;
        auto v = run("lwl/lwr", [0x89020001, 0x99020004]);                     // lwl v0, 1(t0); lwr v0, 4(t0)
        expect("LWL/LWR", v == 0xBBCCDD55 && hits0 == 1 && hits4 == 1 && seen0 == 0x11223344,
               format("v0 %08X, handlers %d and %d, saw %08X", v, hits0, hits4, seen0));

        // LWC1
        v = run("lwc1", [0xC5000000, 0x44020000]);                             // lwc1 f0, 0(t0); mfc1 v0, f0
        expect("LWC1", v == 0xAABBCCDD && hits0 == 1, format("v0 %08X, handler %d", v, hits0));

        // LDC1 and LDL/LDR: the doubleword
        doReplace0 = false; doReplace8 = true; replace8 = 0x0102030405060708;
        v = run("ldc1", [0xD5000000, 0x44220000]);                             // ldc1 f0, 0(t0); dmfc1 v0, f0
        expect("LDC1", v == 0x05060708 && hits8 == 1 && seen8 == 0x1122334455667788,
               format("v0 %08X, handler %d, saw %016X", v, hits8, seen8));
        v = run("ldl/ldr", [0x69020000, 0x6D020007]);                          // ldl v0, 0(t0); ldr v0, 7(t0)
        expect("LDL/LDR", v == 0x05060708 && hits8 == 2, format("v0 %08X, handler %d", v, hits8));
        doReplace8 = false;

        // SWL/SWR of 99887766 at D+1: each word as the store leaves it, and a change to the second one
        doReplace4 = true; replace4 = 0xDEADBEEF;
        run("swl/swr", [0xA9090001, 0xB9090004]);                              // swl t1, 1(t0); swr t1, 4(t0)
        expect("SWL/SWR", hits0 == 1 && hits4 == 1 && seen0 == 0x11998877 && seen4 == 0x66667788 &&
                          word(D) == 0x11998877 && word(D + 4) == 0xDEADBEEF,
               format("handlers %d and %d, saw %08X and %08X, memory %08X %08X", hits0, hits4, seen0, seen4, word(D), word(D + 4)));
        doReplace4 = false;

        // SWC1, changed
        doReplace0 = true; replace0 = 0x12345678;
        run("swc1", [0x44890000, 0xE5000000]);                                 // mtc1 t1, f0; swc1 f0, 0(t0)
        expect("SWC1", hits0 == 1 && seen0 == 0x99887766 && word(D) == 0x12345678,
               format("handler %d, saw %08X, memory %08X", hits0, seen0, word(D)));
        doReplace0 = false;

        // SDC1, changed
        doReplace8 = true; replace8 = 0x0102030405060708;
        run("sdc1", [0x44A90000, 0xF5000000]);                                 // dmtc1 t1, f0; sdc1 f0, 0(t0)
        expect("SDC1", hits8 == 1 && seen8 == 0xFFFFFFFF99887766 && word(D) == 0x01020304 && word(D + 4) == 0x05060708,
               format("handler %d, saw %016X, memory %08X %08X", hits8, seen8, word(D), word(D + 4)));
        doReplace8 = false;

        // SDL/SDR of the whole doubleword
        run("sdl/sdr", [0xB1090000, 0xB5090007]);                              // sdl t1, 0(t0); sdr t1, 7(t0)
        expect("SDL/SDR", hits8 == 2 && seen8 == 0xFFFFFFFF99887766 && word(D) == 0xFFFFFFFF && word(D + 4) == 0x99887766,
               format("handlers %d, saw %016X, memory %08X %08X", hits8, seen8, word(D), word(D + 4)));

        d.check(problems.empty, problems.join("; "));
    }

    // Code changed with setCode() runs at once, even in the cached interpreter (which keeps code it has decoded): here
    // GetPlayerStruct, which has run every frame, is changed as its first instruction is about to run to return 7, then
    // changed back, and the original runs again
    void patchedCode() {
        setUp(STATE_DK_TURN_1);
        enum Address F = 0x80052A8C; // GetPlayerStruct(index)
        immutable Instruction[2] original = [F.val!Instruction, (F + 4).val!Instruction];
        uint call(bool change) {
            bool armed = true, returned;
            uint result;
            0x8004BA04.onExec({ // RenderSpaces
                if (!armed) return;
                armed = false;
                if (change) {
                    F.onExecOnce({
                        F.setCode(0x03E00008);       // jr ra
                        (F + 4).setCode(0x24020007); // addiu v0, zero, 7
                    });
                }
                F.jal(2, (uint v) {
                    result = v;
                    F.setCode(original[0]);
                    (F + 4).setCode(original[1]);
                    returned = true;
                });
            });
            d.waitUntil(() => returned, "the call to return", 60);
            return result;
        }
        auto changed = call(true);
        d.check(changed == 7, format("The changed GetPlayerStruct(2) returned %08X, not 7", changed));
        auto restored = call(false);
        d.check(restored == 0x800F3310, format("The restored GetPlayerStruct(2) returned %08X, not P3's 800F3310", restored));
        d.note("The changed code returned ", changed, ", and the restored code ", restored.to!string(16));
    }

    // For finding button sequences: from boot (no state), runs the steps in N64TEST_ARG (see runSteps()), with a
    // screenshot after each button press
    void explore() {
        runSteps(d.arg, true);
        d.note("Explore done: ", describe(), "; controller reads by port: ", d.inputPolls);
    }

    // Keeps the emulator open for commands: runs each batch of steps written to TestCommands/mp1.txt (by
    // test/send-command.ps1; the first line is "# <id>"), logs "READY <id>" and pauses until the next batch.
    // "quit" ends it, and "test:<name>" runs one of the tests.
    void serve() {
        d.note("READY 0");
        while (true) {
            auto text = d.waitForCommand("TestCommands/mp1.txt");
            auto lines = text.splitLines;
            auto id = !lines.empty && lines[0].startsWith("# ") ? lines[0][2..$].strip : "?";
            auto steps = lines.filter!(l => !l.startsWith("#")).join(" ");
            d.note("COMMAND ", id, ": ", steps);
            if (steps.strip == "quit") return;
            try {
                runSteps(steps, false);
            } catch (TestFailure e) {
                d.note("STEP FAILED: ", e.msg);
            } catch (Exception e) {
                d.note("STEP FAILED: ", e.classinfo.name, ": ", e.msg);
            }
            d.note("READY ", id, " (", describe(), ")");
        }
    }

    // Runs steps separated by spaces, logging scene changes. A step is a button (A, B, Z, START, L, R, UP, DOWN, LEFT,
    // RIGHT, CUP, CDOWN, CLEFT, CRIGHT, or several joined with +) pressed on controller 1, "wait<frames>", "shot",
    // "save:<file>" or "load:<file>" (an emulator state), "untilboard" (presses A until a board's first turn starts),
    // "cpu" (makes every player a computer), or "test:<name>" (runs a test).
    void runSteps(string stepText, bool shotAfterPress) {
        ushort[string] BUTTONS = ["A": Pad.A, "B": Pad.B, "Z": Pad.Z, "START": Pad.START, "UP": Pad.UP, "DOWN": Pad.DOWN,
                                  "LEFT": Pad.LEFT, "RIGHT": Pad.RIGHT, "L": Pad.L, "R": Pad.R, "CUP": Pad.C_UP,
                                  "CDOWN": Pad.C_DOWN, "CLEFT": Pad.C_LEFT, "CRIGHT": Pad.C_RIGHT];
        auto scene = data.currentScene;
        void watch(ulong frames) {
            foreach (i; 0..frames) {
                if (data.currentScene != scene) {
                    d.note("Scene ", scene, " -> ", data.currentScene);
                    scene = data.currentScene;
                }
                d.wait();
            }
        }
        foreach (step; stepText.split(" ").filter!(s => !s.empty)) {
            if (step.startsWith("wait")) {
                watch(step[4..$].to!ulong);
            } else if (step == "untilboard") {
                // The board's own scene shows for a moment before START_BOARD (the board's introduction), so this
                // waits for START_BOARD, then the board's scene on turn 1
                bool started;
                ulong onBoard;
                while (onBoard < 60) {
                    if (data.currentScene == Scene.START_BOARD) started = true;
                    onBoard = started && isBoardScene() && data.currentTurn >= 1 ? onBoard + 1 : 0;
                    if (onBoard == 0 && (d.frame % 90) < 10) d.hold(0, Pad.A); else d.hold(0, 0);
                    watch(1);
                }
                d.release(0);
                d.note("On the board: ", describe());
            } else if (step == "spaces") { // Lists the board's spaces: type, the plugin's custom type, chain positions, events
                foreach (i; 0..data.spaceCount) {
                    auto sp = cast(short)i;
                    int[2][] at;
                    foreach (c; 0..chainCount) foreach (k; 0..chainLength(c)) if (chainSpace(c, k) == sp) at ~= [c, k];
                    d.note("Space ", sp, ": ", data.spaces[sp].type, i < spaces.length ? ", custom " ~ spaces[i].to!string : "",
                           ", at ", at, eventList(sp) ? ", events " ~ describeEvents(sp) : "");
                }
            } else if (step.startsWith("shots:")) { // shots:<n>: screenshots land: takes as a landing happens
                shotsOnLanding = step[6..$].to!int;
            } else if (step.startsWith("coins:") || step.startsWith("stars:")) { // coins:<P1>,<P2>,<P3>,<P4> (or stars:)
                auto values = step[6..$].split(",").map!(v => v.to!ushort).array;
                foreach (i, p; players) {
                    if (step[0] == 'c') p.data.coins = values[i]; else p.data.stars = values[i];
                }
                d.note("Set ", step, ": ", describe());
            } else if (step.startsWith("turn:")) { // turn:<player>: waits for a player's (1-4) turn on the board
                waitForTurn(step[5..$].to!int - 1);
                d.note("Turn: ", describe());
            } else if (step.startsWith("human:")) { // human:<player>: makes a player (1-4) human, on controller 1
                auto p = players[step[6..$].to!int - 1];
                p.data.flags = p.data.flags & ~1;
                d.note("Set ", step, " (it was on controller ", p.data.controller + 1, "): ", describe());
                p.data.controller = 0;
            } else if (step.startsWith("move:")) { // move:<space>: the current player's next move is 1 step, onto it
                auto target = step[5..$].to!short;      // (without waiting for the roll, so a human can roll)
                moveBefore(players[data.currentPlayerIndex], target);
                forcedRoll = 0;
                forcing = true; // Until the roll (clampForcedRolls() makes it 1)
            } else if (step.startsWith("land:")) { // land:<space>: the current player's next move lands there
                auto target = step[5..$].to!short;
                auto r = land(target, data.spaces[target].type);
                d.note("Landed: ", r.describe);
            } else if (step.startsWith("stick:")) { // stick:<x>,<y>: holds the control stick there for 10 frames
                auto xy = step[6..$].split(",").map!(v => v.to!byte).array;
                d.hold(0, 0, xy[0], xy[1]);
                watch(10);
                d.hold(0, 0);
                watch(30);
                d.release(0);
                d.note("Stick ", xy, " (scene ", data.currentScene, ")");
                if (shotAfterPress) d.screenshot(step);
            } else if (step == "cpu") {
                players.each!(p => p.data.flags = p.data.flags | 1);
            } else if (step == "shot") {
                d.screenshot("shot");
            } else if (step.startsWith("save:")) {
                d.saveEmulatorState(step[5..$]);
            } else if (step.startsWith("load:")) {
                d.loadEmulatorState(step[5..$]);
                scene = data.currentScene;
            } else if (step.startsWith("test:")) {
                auto name = step[5..$];
                auto found = tests().find!(t => t.name == name);
                d.check(!found.empty, "No test " ~ name);
                d.note("START ", name);
                found.front.run();
                d.note("PASS ", name);
            } else {
                ushort buttons;
                foreach (b; step.split("+")) {
                    d.check((b in BUTTONS) !is null, "Unknown button " ~ b);
                    buttons |= BUTTONS[b];
                }
                d.hold(0, buttons);
                watch(10);
                d.hold(0, 0);
                watch(30);
                d.release(0);
                d.note("Pressed ", step, " (scene ", data.currentScene, ")");
                if (shotAfterPress) d.screenshot(step);
            }
        }
    }

    // A space's event list (EventListEntry*: { s16 activationType; s16 executionType; void* func }), or 0
    Address eventList(short space) {
        return valid(data.spaces.address) && space < data.spaceCount ? (data.spaces.address + space * 0x20 + 0x1C).val!uint : 0;
    }

    string describeEvents(short space) {
        string[] events;
        for (auto e = eventList(space); valid(e) && e.val!short != 0; e += 8) {
            events ~= format("activation %d, execution %d, func %08X", e.val!short, (e + 2).val!short, (e + 4).val!uint);
        }
        return events.join("; ");
    }

    // Finds the board's event spaces, then lands a player on each one (or passes it, if it's invisible) and records the
    // scenes that follow, to find the spaces the other tests use (Boo, Bowser's visits, etc.)
    void mapEventSpaces() {
        setUp(STATE_DK_TURN_1);
        short[] spaces = iota(data.spaceCount).filter!(i => eventList(cast(short)i) != 0).map!(i => cast(short)i).array;
        foreach (s; spaces) {
            int[2][] at;
            foreach (c; 0..chainCount) foreach (i; 0..chainLength(c)) if (chainSpace(c, i) == s) at ~= [c, i];
            d.note("Event space ", s, " (", data.spaces[s].type, ") at ", at, ": ", describeEvents(s));
        }

        if (!d.arg.empty) spaces = d.arg.split(",").map!(a => a.to!short).array; // Only these spaces
        foreach (s; spaces) {
            d.waitUntil(() => isBoardScene() && chainCount > 0, "the board", 60 * 60 * 5);
            auto at = findInChains(s);
            if (at[1] < 1) {
                d.note("Space ", s, " is first in its chain; skipping");
                continue;
            }
            auto player = data.currentPlayerIndex;
            auto p = players[player];
            waitForTurn(player);
            forceLanding(p, s);
            Scene[] scenes = [data.currentScene];
            auto start = d.frame;
            while (d.frame - start < 60 * 40 && (data.currentPlayerIndex == player || !isBoardScene())) {
                if (data.currentScene != scenes[$ - 1]) scenes ~= data.currentScene;
                if (!d.arg.empty && (d.frame - start) % 10 == 0) {
                    d.note("  scene ", data.currentScene, ", P", player + 1, " at chain ", p.data.currentChainIndex, " position ",
                           p.data.currentSpaceIndex, ", next ", p.data.nextChainIndex, "/", p.data.nextSpaceIndex,
                           ", steps left ", stepsLeft, ", spaces ", format("%08X", data.spaces.address));
                }
                d.wait();
            }
            d.note("Space ", s, " (", data.spaces[s].type, "): scenes ", scenes, "; P", player + 1, " now on space ",
                   spaceOf(p), "; ", describe());
            d.waitUntil(() => isBoardScene() && data.currentPlayerIndex != player, "the next turn", 60 * 60 * 5);
        }
    }

    // The test setup works: a state loads, the game runs, memory reads make sense, and screenshots are taken
    void smoke() {
        setUp(STATE_DK_TURN_1);
        d.check(isBoardScene(), "Not on a board after loading the state");
        d.check(chainCount > 0 && data.spaceCount > 0, "No board spaces");
        d.note(data.spaceCount, " spaces in ", chainCount, " chains; P1 on space ", spaceOf(players[0]));
        d.wait(60);
        d.screenshot("smoke");
    }

    // standardSpaceRatio turns the right number of blue spaces into each type, keeps them through save states, and
    // leaves the Star spaces alone
    void customSpaces() {
        setUp(STATE_DK_TURN_1);
        d.wait(30); // A few frames of RenderSpaces
        d.check(spaces.length == data.spaceCount, format("spaces has %d entries for %d spaces",
                                                                spaces.length, data.spaceCount));

        auto solid = iota(data.spaceCount).count!(i => data.spaces[i].isSolid);
        foreach (type, ratio; config.standardSpaceRatio) {
            auto onBoard = iota(data.spaceCount).count!(i => data.spaces[i].type == type);
            auto wanted = roundTo!long(solid * min(ratio, 1.0));
            d.note(type, ": ", onBoard, " on the board, ratio ", ratio, " of ", solid, " solid spaces = ", wanted);
            d.check(onBoard >= wanted, format("Only %d %s spaces, wanted at least %d", onBoard, type, wanted));
        }
        foreach (i; 0..data.spaceCount) {
            auto custom = spaces[i];
            if (custom >= Space.Type.min && custom <= Space.Type.max && data.spaces[i].type != Space.Type.STAR) {
                d.check(data.spaces[i].type == cast(Space.Type)custom,
                        format("Space %d is %s on the board but %s in the State", i, data.spaces[i].type, custom));
            }
        }
        auto before = iota(data.spaceCount).map!(i => data.spaces[i].type).array;
        auto custom = spaces.dup;
        d.screenshot("custom spaces");

        // Through a save state
        d.saveEmulatorState("TestStates/tmp-custom-spaces.st");
        d.wait(120);
        d.loadEmulatorState("TestStates/tmp-custom-spaces.st");
        d.wait(30);
        auto after = iota(data.spaceCount).map!(i => data.spaces[i].type).array;
        d.check(after == before, "Spaces changed after loading a save state");
        d.check(spaces == custom, "spaces changed after loading a save state");
    }

    // Landing on a converted space counts as that type (the game's own counter for it goes up)
    void landOnCustomSpaces() {
        setUp(STATE_DK_TURN_1);
        d.wait(30);
        auto converted = iota(data.spaceCount).filter!(i => spaces[i] >= Space.Type.min && spaces[i] != CustomSpace.BLUE).array;
        d.check(!converted.empty, "No converted spaces");

        string[] problems;
        foreach (type; config.standardSpaceRatio.keys.sort) {
            // A converted space, and one that was that type already (for comparison)
            auto reachable = reachableSpaces(type);
            auto conv = reachable.filter!(s => spaces[s] == cast(CustomSpace)type && eventList(s) == 0).array;
            auto natural = reachable.filter!(s => spaces[s] == CustomSpace.DEFAULT && eventList(s) == 0).array;
            Landing[2] results;
            foreach (k, targets; [natural, conv]) {
                if (targets.empty) {
                    d.note("No reachable ", k ? "converted " : "natural ", type, " space without board events");
                    continue;
                }
                // Moving a player doesn't always put them where intended (some spaces are reached through other chains):
                // try a few spaces
                foreach (target; targets.take(4)) {
                    results[k] = land(target, type);
                    d.note(k ? "Converted " : "Natural ", type, " space ", target, ": ", results[k].describe);
                    if (results[k].landedOn == target) break;
                }
            }
            auto conversion = results[1];
            if (!conversion.space) continue;
            foreach (r; results) if (r.space && r.landedOn != r.space) {
                problems ~= format("%s: the test sent a player to space %d but they landed on %d", type, r.space, r.landedOn);
            }
            if (conversion.counterChange != 1) {
                problems ~= format("%s: landing on converted space %d changed the %s count by %d", type, conversion.space,
                                   type, conversion.counterChange);
            }
            if (results[0].space && results[0].landedOn == results[0].space &&
                eventKinds(results[0].scenes) != eventKinds(conversion.scenes)) {
                problems ~= format("%s: a natural space led to %s, the converted one to %s", type, results[0].scenes,
                                   conversion.scenes);
            }
            if (conversion.landedOn == conversion.space && results[0].space && results[0].landedOn == results[0].space &&
                (results[0].coinChange < 0) != (conversion.coinChange < 0) && type == Space.Type.RED) {
                problems ~= format("RED: a natural space changed coins by %d, the converted one by %d",
                                   results[0].coinChange, conversion.coinChange);
            }
        }
        problems.each!(p => d.note("PROBLEM ", p));
        checkNoTeamMismatches();
        d.check(problems.empty, problems.length.to!string ~ " converted space types don't act like real ones");
    }

    // Lands on every reachable converted space of a type (N64TEST_ARG, e.g. CHANCE) without board events, to see
    // whether each one acts like that type
    void landOnEachConverted() {
        auto type = d.arg.empty ? Space.Type.CHANCE : d.arg.to!(Space.Type);
        setUp(STATE_DK_TURN_1);
        d.wait(30);
        auto targets = reachableSpaces(type).filter!(s => spaces[s] == cast(CustomSpace)type && eventList(s) == 0).array;
        d.note(targets.length, " reachable converted ", type, " spaces: ", targets);
        foreach (t; targets) {
            auto r = land(t, type);
            d.note("Converted ", type, " space ", t, ": ", r.describe);
        }
        checkNoTeamMismatches();
    }

    // The kinds of events in a list of scenes: the first scene of each event (any mini-game counts as one kind)
    static string[] eventKinds(Scene[] scenes) {
        string[] kinds;
        foreach (sc; scenes) {
            auto k = sc == Scene.MINI_GAME_RULES || sc == Scene.MINI_GAME_RESULTS || (sc >= Scene.SLOT_MACHINE && sc <= Scene.BUMPER_BALL_MAZE)
                   ? "mini-game" : sc.to!string;
            if (kinds.empty || kinds[$ - 1] != k) kinds ~= k;
        }
        return kinds.length ? [kinds[0]] : null;
    }

    // What happened when a player landed on a space
    struct Landing {
        short space;            // Where they were sent
        short landedOn;         // Where they were when the move ended
        int coinsBefore;
        int counterChange;      // In the game's count for the space's type, over the turn
        int coinChange;         // Over the turn
        ubyte panelColor;       // turn_status (PlayerData +0x17) at the end of the turn: 1 blue, 2 red, 4 green
        Scene[] scenes;         // Until the next player's turn (without the transitions between scenes)

        string describe() {
            return format("landed on %d, count %+d, coins %d%+d, panel %d, scenes %s", landedOn, counterChange,
                          coinsBefore, coinChange, panelColor, scenes);
        }
    }

    // Lands a player (P1-P3: P4's turn ends with the round's mini-game) on a space and records what follows, until the
    // next player's turn
    Landing land(short space, Space.Type type) {
        d.waitUntil(() => isBoardScene() && chainCount > 0 && data.currentPlayerIndex < 3, "P1-P3's turn", 60 * 60 * 10);
        d.wait(30); // The board's chains are filled in just after they're allocated
        auto player = data.currentPlayerIndex;
        auto p = players[player];
        Landing result;
        result.space = space;
        auto counterBefore = counter(p, type);
        forceLanding(p, space);
        auto coinsBefore = p.data.coins;
        result.coinsBefore = coinsBefore;
        d.waitUntil(() => stepsLeft == 0, "the move to end", 60 * 60);
        result.landedOn = spaceOf(p);
        if (shotsOnLanding) {
            foreach (k; 0..shotsOnLanding) {
                d.wait(k == 0 ? 20 : 90);
                d.screenshot(format("P%d landing on space %d (%s), %d frames after the move", player + 1, space,
                                    data.spaces[space].type, d.frame));
            }
        }
        Scene scene = data.currentScene;
        auto start = d.frame;
        while ((data.currentPlayerIndex == player || !isBoardScene()) && d.frame - start < 60 * 60 * 3) {
            if (data.currentScene != scene) {
                scene = data.currentScene;
                if (!isBoardScene(scene) && scene != cast(Scene)53) result.scenes ~= scene; // 53: transitions
            }
            if (isBoardScene()) {
                result.counterChange = counter(p, type) - counterBefore;
                result.coinChange = p.data.coins - coinsBefore;
                result.panelColor = p.data.color;
            }
            d.wait();
        }
        return result;
    }

    // The game's count of a player's landings on a type of space
    ubyte counter(Player p, Space.Type type) {
        switch (type) {
            case Space.Type.BLUE:      return p.data.blueSpaces;
            case Space.Type.RED:       return p.data.redSpaces;
            case Space.Type.MINI_GAME: return p.data.miniGameSpaces;
            case Space.Type.HAPPENING: return p.data.happeningSpaces;
            case Space.Type.CHANCE:    return p.data.chanceSpaces;
            case Space.Type.MUSHROOM:  return p.data.mushroomSpaces;
            case Space.Type.BOWSER:    return p.data.bowserSpaces;
            default:                   return 0;
        }
    }

    // randomBonus: the three bonus stars go to the players with the most of each chosen stat, with the plugin's
    // messages, at the end of the game
    void bonusStars() {
        setUp(STATE_DK_TURN_1, 20, 20); // The final turn

        // Hooks recording the bonus star messages as they're loaded
        ushort messageId;
        string[ushort] messages;
        0x8005B7E8.onExec({ messageId = cast(ushort)gpr.a0; });
        0x8005B824.onExec({
            if (!isBonusScene()) return;
            string text;
            for (uint i = 0; i < 512; i++) {
                auto c = Ptr!char(gpr.s0)[i];
                if (c == '\xFF' || c == '\0') break;
                text ~= c;
            }
            messages[messageId] = text;
        });

        // Stats and stars when the bonus scene starts (when the plugin picks the bonus stars)
        uint[BonusType][4] stats;
        ushort[4] starsBefore;
        BonusType[] chosen;
        d.waitUntil(() => isBonusScene(), "the bonus stars", 60 * 60 * 10);
        foreach (i, p; players) {
            starsBefore[i] = p.data.stars;
            foreach (b; [EnumMembers!BonusType]) stats[i][b] = featureOf!RandomBonus1.stat(p, b);
        }
        chosen = bonus.dup;
        d.note("Bonus scene ", data.currentScene, ", bonus stars ", chosen.take(3), "; ", describe());
        d.check(chosen.length >= 3, "The plugin didn't pick 3 bonus stars");

        bool[ushort] shot;
        while (isBonusScene()) {
            auto shown = messages.keys.filter!(id => id >= 264 && id <= 278 && id !in shot).array;
            if (!shown.empty) {
                shot[shown[0]] = true;
                d.wait(150); // The text is drawn a letter at a time
                d.screenshot("bonus star message " ~ shown[0].to!string);
            }
            d.wait();
        }
        auto starsAfterScene = players.map!(p => p.data.stars).array;
        d.note("After the bonus scene: ", describe());
        foreach (id; messages.keys.sort) d.note("Message ", id, ": ", unformatText(messages[id]).replace("\x10", " "));

        // Who should have won each bonus star: the most (signed for the Game Star), shared on ties, nobody on a 4-way tie
        int[4] expected;
        foreach (b; chosen.take(3)) {
            auto value = (int i) => cast(int)stats[i][b]; // Signed: the Game Star's total can be negative
            auto best = iota(4).map!(i => value(i)).maxElement;
            auto winners = iota(4).filter!(i => value(i) == best).array;
            d.note(b, ": ", iota(4).map!(i => value(i)).array, " -> ", winners.length == 4 ? "nobody" : winners.map!(w => "P" ~ (w + 1).to!string).join(", "));
            if (winners.length < 4) foreach (w; winners) expected[w]++;
        }
        foreach (i, p; players) {
            auto got = starsAfterScene[i] - starsBefore[i];
            d.note("P", i + 1, " got ", got, " bonus stars, expected ", expected[i], " (before team syncing)");
        }
        d.check(messages.length >= 3, "Only " ~ messages.length.to!string ~ " bonus star messages were replaced");
    }

}
