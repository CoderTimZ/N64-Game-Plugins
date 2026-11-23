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
// off (test/mp2-config-plain.json) and an empty State
// Western Land, a new game of 20 turns (with bonus stars): turn 1, P1's turn, at the dice block. P1 Mario (human), P2
// Luigi, P3 Yoshi, P4 Peach (computers, normal), 10 coins each. The default teams make Mario and Luigi (P1, P2) one team
// and Yoshi and Peach (P3, P4) the other.
enum STATE_WESTERN_TURN_1 = "TestStates/mp2-western-turn1.st";

// Board data the plugin's Memory doesn't have
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
    override void loadConfig() {
        super.loadConfig();
        config.bingoURL = "";
    }

    override void onStart() {
        super.onStart();
        driver = new TestDriver(tests());
        clampForcedRolls();
    }

    override void onFrame(ulong frame) {
        super.onFrame(frame);
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
    void setUp(string stateFile, ushort currentTurn = 0, ushort totalTurns = 0, bool allCPU = true) {
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
    // "coins:<P1>,<P2>,<P3>,<P4>" (or "stars:"), or "test:<name>" (runs a test).
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
                           i < state.spaces.length ? ", custom " ~ state.spaces[i].to!string : "", ", at ", at);
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
        setUp(STATE_WESTERN_TURN_1);
        d.check(isBoardScene(), "Not on a board after loading the state");
        d.check(chainCount > 0 && data.spaceCount > 0, "No board spaces");
        d.note(data.spaceCount, " spaces in ", chainCount, " chains; P1 on space ", spaceOf(players[0]));
        d.wait(60);
        d.screenshot("smoke");
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
            setUp(STATE_WESTERN_TURN_1);
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
}
