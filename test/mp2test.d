// Mario Party 2 tests, run by the test build of the plugin (dub build -c mp2-test). See test/driver.d, and
// test/mp1test.d for the Mario Party 1 tests this follows.
module me.timz.n64.mp2test;

version (TestDriver):

import me.timz.n64.marioparty;
import me.timz.n64.marioparty2;
import me.timz.n64.plugin;
import me.timz.n64.testdriver;
import std.algorithm;
import std.array;
import std.conv;
import std.format;
import std.range;
import std.string;

// States the tests start from, in the test emulator's folder (TestStates/), made from boot with the plugin's options
// off (test/mp2-config-plain.json) and none of the plugin's state
// Western Land, a new game of 20 turns (with bonus stars): turn 1, P1's turn, at the dice block. P1 Mario (human), P2
// Luigi, P3 Yoshi, P4 Peach (computers, normal), 10 coins each. The default teams make Mario and Luigi (P1, P2) one team
// and Yoshi and Peach (P3, P4) the other.
enum STATE_WESTERN_TURN_1 = "TestStates/mp2-western-turn1.st";

// Board data the plugin's Memory doesn't have
enum Address MINI_GAME_FLAGS = 0x800F8C7C; // A bit for each mini-game (MiniGame - 1): unlocked
enum Address STEPS_LEFT = 0x80100028; // s32: steps left in the moving player's move (counts down on each solid space;
                                      // they land on the one where it reaches 0)

class TestMarioParty2 : MarioParty2 {
    TestDriver driver;
    alias d = driver;

    string[] teamMismatches; // teamScores problems seen on the board
    bool watchTeams;         // Whether to check teams (once a test has set the players up)

    this(string name, string hash) {
        super(name, hash);
    }

    // Tests never connect to a Bingo page, whatever the config says
    override Config readConfig() {
        auto c = super.readConfig();
        c.bingoURL = "";
        return c;
    }

    override void onStart() {
        super.onStart();
        driver = new TestDriver(tests());
        clampForcedRolls();
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
    void setUpTest(string stateFile, ushort currentTurn = 0, ushort totalTurns = 0, bool allCPU = true) {
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

    // --- Board ---

    // The board's chains exist only while a board is loaded: these check the game's pointers before following them,
    // since following a stale or null one would read outside the N64's memory (and crash the emulator)
    static bool valid(Address a) { return a >= 0x80000000 && a < 0x80800000; }
    ushort chainCount() { return valid(data.chains.address) ? data.chainCount : 0; }
    ushort chainLength(uint c) {
        return c < chainCount ? (data.chains.address + c * 8).val!ushort : 0;
    }
    short chainSpace(uint c, uint i) {
        if (i >= chainLength(c)) return -1;
        auto spaces = (data.chains.address + c * 8 + 4).val!uint;
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
            if (s >= 0 && data.spaces[s].type == type && !result.canFind(s)) result ~= s;
        }
        return result;
    }

    short spaceOf(Player p) {
        return chainSpace(p.data.chain, p.data.space);
    }

    // Puts a player on a space (where it is in the chains), standing there
    void moveOnto(Player p, short space) {
        auto at = findInChains(space);
        d.check(at[0] >= 0, "Space " ~ space.to!string ~ " isn't in a chain");
        p.data.chain = cast(ushort)at[0];
        p.data.space = cast(ushort)at[1];
        p.data.nextChain = cast(ushort)at[0];
        p.data.nextSpace = cast(ushort)(at[1] + 1);
        d.note("Moved P", p.index + 1, " onto space ", space, " (chain ", at[0], ", position ", at[1], ")");
    }

    // Puts a player on the space before `space` in its chain, so a one-step move lands on it
    void moveBefore(Player p, short space) {
        auto at = findInChains(space);
        d.check(at[0] >= 0 && at[1] >= 1, "Space " ~ space.to!string ~ " can't be reached in one step");
        p.data.chain = cast(ushort)at[0];
        p.data.space = cast(ushort)(at[1] - 1);
        p.data.nextChain = cast(ushort)at[0];
        p.data.nextSpace = cast(ushort)at[1];
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

    // Waits for the start of a player's turn on the board
    void waitForTurn(uint player, string why = null) {
        d.waitUntil(() => isBoardScene() && data.currentPlayerIndex == player, "P" ~ (player + 1).to!string ~ "'s turn" ~
                    (why ? " (" ~ why ~ ")" : ""));
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

    // --- Tests ---

    Test[] tests() {
        return [
            Test("smoke", &smoke, 60 * 60),
            Test("teamDuels", &teamDuels, 60 * 60 * 20),
            Test("randomItemAndDuelMiniGames", &randomItemAndDuelMiniGames, 60 * 60 * 40),
            Test("revealHiddenBlocks", &revealHiddenBlocks, 60 * 60 * 5),
            Test("explore", &explore, 60 * 60 * 30),
            Test("serve", &serve, ulong.max),
        ];
    }

    // For finding button sequences: from boot (no state), runs the steps in N64TEST_ARG (see runSteps()), with a
    // screenshot after each button press
    void explore() {
        runSteps(d.arg, true);
        d.note("Explore done: ", describe(), "; controller reads by port: ", d.inputPolls);
    }

    // Keeps the emulator open for commands: runs each batch of steps written to TestCommands/mp2.txt (by
    // test/send-command.ps1 -Game mp2; the first line is "# <id>"), logs "READY <id>" and pauses until the next batch.
    // "quit" ends it, and "test:<name>" runs one of the tests.
    void serve() {
        d.note("READY 0");
        while (true) {
            auto text = d.waitForCommand("TestCommands/mp2.txt");
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
    // "stick:<x>,<y>", "cpu" (makes every player a computer), "spaces" (lists the board's spaces), "turn:<player>",
    // "coins:<P1>,<P2>,<P3>,<P4>" (or "stars:"), "lastturn" (makes the current turn the last), "until:<scene>" (presses
    // A until a scene), "human:<player>", "lucky:<P1>,<P2>,<P3>,<P4>" (Lucky Space counts), or "test:<name>".
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
            } else if (step == "spaces") { // Lists the board's spaces: type, the plugin's custom type, chain positions
                foreach (i; 0..data.spaceCount) {
                    auto sp = cast(short)i;
                    int[2][] at;
                    foreach (c; 0..chainCount) foreach (k; 0..chainLength(c)) if (chainSpace(c, k) == sp) at ~= [c, k];
                    d.note("Space ", sp, ": ", data.spaces[sp].type,
                           i < spaces.length ? ", custom " ~ spaces[i].to!string : "", ", at ", at);
                }
            } else if (step.startsWith("coins:") || step.startsWith("stars:")) {
                auto values = step[6..$].split(",").map!(v => v.to!ushort).array;
                foreach (i, p; players) {
                    if (step[0] == 'c') p.data.coins = values[i]; else p.data.stars = values[i];
                }
                d.note("Set ", step, ": ", describe());
            } else if (step.startsWith("turn:")) { // turn:<player>: waits for a player's (1-4) turn on the board
                waitForTurn(step[5..$].to!int - 1);
                d.note("Turn: ", describe());
            } else if (step.startsWith("stick:")) { // stick:<x>,<y>: holds the control stick there for 10 frames
                auto xy = step[6..$].split(",").map!(v => v.to!byte).array;
                d.hold(0, 0, xy[0], xy[1]);
                watch(10);
                d.hold(0, 0);
                watch(30);
                d.release(0);
                d.note("Stick ", xy, " (scene ", data.currentScene, ")");
                if (shotAfterPress) d.screenshot(step);
            } else if (step == "lastturn") { // Makes the current turn the game's last
                data.totalTurns = data.currentTurn;
                d.note("Last turn: ", describe());
            } else if (step.startsWith("until:")) { // until:<scene>: presses A (Start on rules screens) until a scene
                auto target = step[6..$].to!Scene;
                auto start = d.frame;
                while (data.currentScene != target) {
                    auto rules = data.currentScene == Scene.MINI_GAME_RULES || data.currentScene == Scene.MINI_GAME_RULES_2;
                    d.hold(0, !isBoardScene() && (d.frame - start) % 90 < 10 ? (rules ? Pad.START : Pad.A) : 0);
                    watch(1);
                    d.check(d.frame - start < 60 * 60 * 15, "Timed out waiting for " ~ target.to!string);
                }
                d.release(0);
                d.note("Reached ", target, ": ", describe());
            } else if (step.startsWith("human:")) { // human:<player>: makes a player (1-4) human
                auto p = players[step[6..$].to!int - 1];
                p.data.flags = p.data.flags & ~1;
                d.note("Human: ", describe());
            } else if (step.startsWith("lucky:")) { // lucky:<P1>,<P2>,<P3>,<P4>: each player's Lucky Space count
                foreach (i, v; step[6..$].split(",").map!(v => v.to!int).array) players[i].state.luckySpaceCount = v;
                d.note("Lucky Space counts: ", players.map!(p => p.state.luckySpaceCount));
            } else if (step == "dumpresults") { // Dumps the detailed results' icon files and logs their messages
                0x80103F5C.onExec({ // DataClose(a0 = s3): the icon file s4 was just made a sprite animation
                    if (data.currentScene != Scene.FINAL_RESULTS) return;
                    import std.file : write;
                    auto bytes = new ubyte[4096];
                    foreach (k, ref b; bytes) b = (gpr.s3 + cast(uint)k).val!ubyte;
                    auto name = format("TestLogs/mp2-icon-%02d.bin", cast(int)gpr.s4);
                    write(name, bytes);
                    d.note("Dumped icon ", cast(int)gpr.s4, " (", (cast(uint)gpr.s3).to!string(16), ") to ", name);
                });
                static ushort dumpId;
                static uint dumpLength;
                0x80068CD4.onExec({ dumpId = cast(ushort)gpr.a0; });            // Load message a0
                0x80068CE8.onExec({ dumpLength = (gpr.sp + 20).val!uint; });   // Its length
                0x80068D10.onExec({                                            // s0 = the message, read
                    if (data.currentScene != Scene.FINAL_RESULTS || dumpId < 0x60D || dumpId > 0x618) return;
                    auto bytes = iota(dumpLength).map!(k => (gpr.s0 + k).val!ubyte);
                    d.note(format("Message %04X (%d bytes): %(%02X %)", dumpId, dumpLength, bytes));
                });
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

    // The test setup works: a state loads, the game runs, memory reads make sense, and screenshots are taken
    void smoke() {
        setUpTest(STATE_WESTERN_TURN_1);
        d.check(isBoardScene(), "Not on a board after loading the state");
        d.check(chainCount > 0 && data.spaceCount > 0, "No board spaces");
        d.note(data.spaceCount, " spaces in ", chainCount, " chains; P1 on space ", spaceOf(players[0]));
        d.wait(60);
        d.screenshot("smoke");
    }

    // revealHiddenBlocksOnRemainingTurns (1, with luckySpaceRatio: test/mp2-config-reveal.json): with the game's Hidden
    // Blocks on, blocks put on Lucky Spaces are moved to Blue Spaces that aren't, no space is drawn gold before the
    // last turn, and on the last turn exactly the Coin and Star blocks' spaces are (with the gold texture). Then the
    // blocks are put on the Blue Spaces nearest P1, for a screenshot.
    void revealHiddenBlocks() {
        d.check(config.revealHiddenBlocksOnRemainingTurns == 1 && config.luckySpaceRatio > 0,
                "Needs test/mp2-config-reveal.json");
        setUpTest(STATE_WESTERN_TURN_1, 1, 20);
        d.waitUntil(() => isBoardScene() && chainCount > 0 && spaces.length == data.spaceCount, "the board's spaces",
                    60 * 60);
        d.wait(30);
        d.note("Hidden Blocks ", hiddenBlocksSetting() ? "on" : "off", " in the state; Coin block on space ",
               data.coinHiddenBlock, ", Star block on ", data.starHiddenBlock);
        data.flags9 = data.flags9 | 0x40;

        // The spaces drawn gold, and the texture they're drawn with, while watching
        bool[short] gold;
        Address goldTexture;
        bool watching;
        0x800546B4.onExecDone({
            if (watching && isBoardScene() && gpr.v0 == CustomSpace.HIDDEN) gold[cast(short)gpr.s2] = true;
        });
        0x8005448C.onExecDone({
            if (watching && isBoardScene() && gpr.s4 == CustomSpace.HIDDEN) goldTexture = cast(Address)gpr.v0;
        });
        bool[short] goldFor(ulong frames) {
            gold = null;
            goldTexture = 0;
            watching = true;
            d.wait(frames);
            watching = false;
            return gold;
        }

        bool lucky(short i) { return i >= 0 && isLucky(i); }
        bool blue(short i) { return i >= 0 && i < data.spaceCount && data.spaces[i].type == Space.Type.BLUE; }
        auto luckySpaces = iota(data.spaceCount).map!(i => cast(short)i).filter!(i => lucky(i)).array;
        d.check(luckySpaces.length >= 2, "Fewer than 2 Lucky Spaces");

        // Blocks on Lucky Spaces are moved
        data.coinHiddenBlock = luckySpaces[0];
        data.starHiddenBlock = luckySpaces[1];
        d.wait(10);
        auto coin = data.coinHiddenBlock, star = data.starHiddenBlock;
        d.note("Blocks put on Lucky Spaces ", luckySpaces[0], " and ", luckySpaces[1], " are now on ", coin, " and ", star);
        string[] problems;
        foreach (name, i; ["Coin": coin, "Star": star]) {
            if (!blue(i) || lucky(i)) problems ~= format("the %s block is on space %d, not a plain Blue Space", name, i);
        }
        if (coin == star) problems ~= "both blocks are on the same space";

        // Not shown before the last turn
        auto before = goldFor(60);
        d.note("Gold before the last turn: ", before.keys.sort);
        if (!before.empty) problems ~= format("spaces %s were gold on turn %d of %d", before.keys.sort, data.currentTurn,
                                              data.totalTurns);

        // Shown on it
        data.totalTurns = data.currentTurn;
        auto last = goldFor(60);
        d.note("Gold on the last turn: ", last.keys.sort, ", texture ", goldTexture.to!string(16));
        if (last.keys.sort.array != [coin, star].sort.array) {
            problems ~= format("gold on the last turn: %s, but the blocks are on %d and %d", last.keys.sort, coin, star);
        }
        if (!valid(goldTexture)) problems ~= "no gold texture";

        // For the screenshot: the blocks on the plain Blue Spaces nearest P1
        float[3] position(short i) {
            Address a = data.spaces.address + i * cast(uint)Space.sizeof;
            return [(a + 8).val!float, (a + 12).val!float, (a + 16).val!float];
        }
        auto p1 = position(spaceOf(players[0]));
        auto near = iota(data.spaceCount).map!(i => cast(short)i).filter!(i => blue(i) && !lucky(i))
            .array.sort!((a, b) => distance(position(a), p1) < distance(position(b), p1)).array;
        data.coinHiddenBlock = near[0];
        data.starHiddenBlock = near[1];
        auto shown = goldFor(30);
        d.note("Blocks moved near P1 to ", near[0], " and ", near[1], "; gold: ", shown.keys.sort);
        if (shown.keys.sort.array != [near[0], near[1]].sort.array) problems ~= format("gold near P1: %s", shown.keys.sort);
        d.screenshot("reveal-hidden-blocks");

        d.check(problems.empty, problems.join("; "));
    }

    bool hiddenBlocksSetting() { return (data.flags9 & 0x40) != 0; }

    static float distance(float[3] a, float[3] b) {
        import std.math : sqrt;
        return sqrt((a[0] - b[0]) ^^ 2 + (a[1] - b[1]) ^^ 2 + (a[2] - b[2]) ^^ 2);
    }

    // teamScores in duels (with alwaysDuel, so a duel can happen on any turn): P1 lands on a Blue Space with other
    // players on it. With an opponent there, a duel is played, and afterwards each team's players have the same
    // coins, and the coins that changed hands went between the teams. With only P1's teammate there, there's no duel,
    // and nobody's coins change (beyond the Blue Space's 3).
    void teamDuels() {
        string[] problems;
        auto p1 = players[0];
        auto teammate = teammates(p1).front;
        auto opponent = players.find!(p => team(p) != team(p1)).front;
        d.note("P1's teammate is P", teammate.index + 1, ", and P", opponent.index + 1, " is an opponent");

        foreach (withOpponent; [true, false]) {
            setUpTest(STATE_WESTERN_TURN_1);
            d.waitUntil(() => isBoardScene() && chainCount > 0, "the board", 60 * 60);
            d.wait(30); // The board's chains are filled in just after they're allocated
            auto target = reachableSpaces(Space.Type.BLUE).front;
            foreach (p; players) {
                p.data.coins = cast(ushort)(team(p) == team(p1) ? 30 : 20);
                p.data.stars = 0;
            }
            moveOnto(teammate, target);
            if (withOpponent) moveOnto(opponent, target);
            auto before = scores();
            d.note(withOpponent ? "With an opponent" : "With only P1's teammate", " on space ", target, ": ", describe());

            forceLanding(p1, target);
            Scene[] scenes;
            Scene scene = data.currentScene;
            int[2][4] lowest = before;
            d.waitUntil(() {
                if (data.currentScene != scene) {
                    scene = data.currentScene;
                    if (scene != Scene.TRANSITION) scenes ~= scene;
                    d.note("Scene ", scene, ": ", describe());
                }
                foreach (i, p; players) lowest[i][0] = min(lowest[i][0], cast(int)p.data.coins);
                return isBoardScene() && data.currentPlayerIndex != 0;
            }, "P1's turn to end", 60 * 60 * 10);
            auto after = scores();
            auto duel = scenes.any!(s => s.to!string.endsWith("_DUEL"));
            d.note("Scenes ", scenes, "; coins ", before[].map!(s => s[0]).array, " -> ", after[].map!(s => s[0]).array);

            problems ~= teamProblems();
            auto team1 = after[0][0] - before[0][0];                 // P1's team's change
            auto team2 = after[opponent.index][0] - before[opponent.index][0];
            if (withOpponent) {
                if (!duel) problems ~= "no duel with an opponent on the space: " ~ scenes.to!string;
                // The Blue Space gives P1 3 coins before the duel; the duel itself moves coins between the teams
                if (duel && team1 - 3 != -team2) problems ~= format("the duel didn't move coins between the teams: P1's team %+d (3 from the Blue Space), the other %+d", team1, team2);
            } else {
                if (duel) problems ~= "a duel with only P1's teammate on the space: " ~ scenes.to!string;
                if (team1 != 3 || team2 != 0) problems ~= format("coins changed without a duel: P1's team %+d, the other %+d", team1, team2);
            }
        }
        d.check(problems.empty, problems.join("; "));
    }

    // --- randomItemAndDuelMiniGames ---

    ref ubyte flagByte(MiniGame game) { return (MINI_GAME_FLAGS + (game - 1) / 8).val!ubyte; }
    bool unlocked(MiniGame game) { return (flagByte(game) & (1 << ((game - 1) % 8))) != 0; }
    void lock(MiniGame game) { flagByte(game) = cast(ubyte)(flagByte(game) & ~(1 << ((game - 1) % 8))); }

    // The duel mini-game a duel scene plays (each board's duel scene plays its own)
    static MiniGame duelOf(Scene scene) {
        switch (scene) {
            case Scene.WESTERN_LAND_DUEL: return DUEL_MINI_GAMES[Board.WESTERN];
            case Scene.PIRATE_LAND_DUEL:  return DUEL_MINI_GAMES[Board.PIRATE];
            case Scene.HORROR_LAND_DUEL:  return DUEL_MINI_GAMES[Board.HORROR];
            case Scene.SPACE_LAND_DUEL:   return DUEL_MINI_GAMES[Board.SPACE];
            case Scene.MYSTERY_LAND_DUEL: return DUEL_MINI_GAMES[Board.MYSTERY];
            case Scene.BOWSER_LAND_DUEL:  return DUEL_MINI_GAMES[Board.BOWSER];
            default:                      return cast(MiniGame)0;
        }
    }

    // Waits for a player's turn to end, pressing A now and then off the board (for the screens around a mini-game),
    // and returns the scenes it went through
    Scene[] playTurn(uint player) {
        Scene[] scenes;
        Scene scene = data.currentScene;
        auto start = d.frame;
        d.waitUntil(() {
            if (data.currentScene != scene) {
                scene = data.currentScene;
                if (scene != Scene.TRANSITION) scenes ~= scene;
                d.note("Scene ", scene, ": ", describe());
            }
            if (!isBoardScene() && (d.frame - start) % 90 < 10) d.hold(0, Pad.A); else d.hold(0, 0);
            return isBoardScene() && data.currentPlayerIndex != player;
        }, "P" ~ (player + 1).to!string ~ "'s turn to end", 60 * 60 * 10);
        d.release(0);
        return scenes;
    }

    // Waits for a player's turn with the board loaded, pressing A now and then off the board (for the mini-game
    // between turns)
    void waitForTurnPressing(uint player) {
        auto start = d.frame;
        d.waitUntil(() {
            if (!isBoardScene() && (d.frame - start) % 90 < 10) d.hold(0, Pad.A); else d.hold(0, 0);
            return isBoardScene() && data.currentPlayerIndex == player && chainCount > 0;
        }, "P" ~ (player + 1).to!string ~ "'s turn", 60 * 60 * 10);
        d.release(0);
        d.wait(30); // The board's chains are filled in just after they're allocated
    }

    // randomItemAndDuelMiniGames with blockedMiniGames (run with test/mp2-config-random.json, which blocks Western,
    // Pirate and Horror Land's duel and item mini-games, and has alwaysDuel): players land on Item Spaces 3 times, and
    // duel 3 times. Each plays a different one of the other 3 boards' mini-games, and unlocks the one it played (not
    // Western Land's own).
    void randomItemAndDuelMiniGames() {
        d.check(config.randomItemAndDuelMiniGames && config.alwaysDuel && !config.blockedMiniGames.empty,
                "Run this with test/mp2-config-random.json");
        string[] problems;
        MiniGame[] items, duels;

        setUpTest(STATE_WESTERN_TURN_1);
        waitForTurnPressing(0);
        foreach (g; DUEL_MINI_GAMES ~ ITEM_MINI_GAMES) lock(g);
        auto itemSpaces = reachableSpaces(Space.Type.ITEM);
        auto blueSpaces = reachableSpaces(Space.Type.BLUE);
        d.check(!itemSpaces.empty && !blueSpaces.empty, "No Item Space or Blue Space can be reached in one step");

        // P1, P2 and P3 land on an Item Space, then P4, P1 and P2 duel
        foreach (n, player; [0, 1, 2, 3, 0, 1]) {
            waitForTurnPressing(player);
            auto p = players[player];
            players.each!(q => q.data.coins = 30);
            p.data.item = Item.NONE;
            auto duel = n >= 3;
            if (duel) {
                moveOnto(players[(player + 1) % 4], blueSpaces[0]);
                forceLanding(p, blueSpaces[0]);
            } else {
                // (nobody else on the Item Space: with alwaysDuel, landing with another player there is a duel too,
                // which would take a board from the duels' queue)
                foreach (q; players) if (q !is p && spaceOf(q) == itemSpaces[0]) moveOnto(q, blueSpaces[$ - 1]);
                forceLanding(p, itemSpaces[0]);
            }
            auto scenes = playTurn(player);
            d.note("P", player + 1, "'s turn: ", scenes);

            auto played = duel ? scenes.map!(s => duelOf(s)).filter!(g => g != 0).array
                               : scenes.map!(s => cast(MiniGame)s).filter!(g => ITEM_MINI_GAMES[].canFind(g)).array;
            if (played.length != 1) {
                problems ~= format("P%d's turn: not one %s: %s", player + 1, duel ? "duel" : "item mini-game", scenes);
                continue;
            }
            if (duel) duels ~= played[0]; else items ~= played[0];
            if (!unlocked(played[0])) problems ~= format("%s was played but isn't unlocked", played[0]);
        }

        d.note("Item mini-games ", items, ", duels ", duels);
        foreach (g; items ~ duels) {
            if (config.blockedMiniGames.canFind(g)) problems ~= format("blocked %s was played", g);
        }
        if (items.dup.sort.uniq.count != items.length) problems ~= format("an item mini-game repeated: %s", items);
        if (duels.dup.sort.uniq.count != duels.length) problems ~= format("a duel repeated: %s", duels);
        foreach (g; DUEL_MINI_GAMES ~ ITEM_MINI_GAMES) {
            if (unlocked(g) && !(items ~ duels).canFind(g)) problems ~= format("%s is unlocked but wasn't played", g);
        }
        d.check(problems.empty, problems.join("; "));
    }
}
