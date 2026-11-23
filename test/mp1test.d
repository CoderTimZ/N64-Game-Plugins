// Mario Party 1 tests, run by the test build of the plugin (dub build -c mp1-test). See test/driver.d.
module me.timz.n64.mp1test;

version (TestDriver):

import me.timz.n64.marioparty;
import me.timz.n64.marioparty2; // Mario Party 1's module (marioparty1.d)
import me.timz.n64.plugin;
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

    override void onInput(int port, InputData* input) {
        super.onInput(port, input);
        driver.onInput(port, input);
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
            Test("customSpaces", &customSpaces, 60 * 60 * 5),
            Test("landOnCustomSpaces", &landOnCustomSpaces, 60 * 60 * 20),
            Test("bonusStars", &bonusStars, 60 * 60 * 20),
            Test("mapEventSpaces", &mapEventSpaces, 60 * 60 * 30),
            Test("landOnEachConverted", &landOnEachConverted, 60 * 60 * 60),
            Test("explore", &explore, 60 * 60 * 30),
            Test("serve", &serve, ulong.max),
        ];
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

    // For finding button sequences: from boot (no state), runs the steps in N64TEST_ARG (see runSteps()), with a
    // screenshot after each button press
    void explore() {
        runSteps(d.arg, true);
        d.note("Explore done: ", describe(), "; controller reads by port: ", d.inputPolls);
    }

    // Keeps the emulator open for commands: runs each batch of steps written to TestCommands/mp1.txt (by
    // test/send-mp1-command.ps1; the first line is "# <id>"), logs "READY <id>" and pauses until the next batch.
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
                    d.note("Space ", sp, ": ", data.spaces[sp].type, i < state.spaces.length ? ", custom " ~ state.spaces[i].to!string : "",
                           ", at ", at, eventList(sp) ? ", events " ~ describeEvents(sp) : "");
                }
            } else if (step.startsWith("shots:")) { // shots:<n>: screenshots land: takes as a landing happens
                shotsOnLanding = step[6..$].to!int;
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
        d.check(state.spaces.length == data.spaceCount, format("state.spaces has %d entries for %d spaces",
                                                                state.spaces.length, data.spaceCount));

        auto solid = iota(data.spaceCount).count!(i => data.spaces[i].isSolid);
        foreach (type, ratio; config.standardSpaceRatio) {
            auto onBoard = iota(data.spaceCount).count!(i => data.spaces[i].type == type);
            auto wanted = roundTo!long(solid * min(ratio, 1.0));
            d.note(type, ": ", onBoard, " on the board, ratio ", ratio, " of ", solid, " solid spaces = ", wanted);
            d.check(onBoard >= wanted, format("Only %d %s spaces, wanted at least %d", onBoard, type, wanted));
        }
        foreach (i; 0..data.spaceCount) {
            auto custom = state.spaces[i];
            if (custom >= Space.Type.min && custom <= Space.Type.max && data.spaces[i].type != Space.Type.STAR) {
                d.check(data.spaces[i].type == cast(Space.Type)custom,
                        format("Space %d is %s on the board but %s in the State", i, data.spaces[i].type, custom));
            }
        }
        auto before = iota(data.spaceCount).map!(i => data.spaces[i].type).array;
        auto custom = state.spaces.dup;
        d.screenshot("custom spaces");

        // Through a save state
        d.saveEmulatorState("TestStates/tmp-custom-spaces.st");
        d.wait(120);
        d.loadEmulatorState("TestStates/tmp-custom-spaces.st");
        d.wait(30);
        auto after = iota(data.spaceCount).map!(i => data.spaces[i].type).array;
        d.check(after == before, "Spaces changed after loading a save state");
        d.check(state.spaces == custom, "state.spaces changed after loading a save state");
    }

    // Landing on a converted space counts as that type (the game's own counter for it goes up)
    void landOnCustomSpaces() {
        setUp(STATE_DK_TURN_1);
        d.wait(30);
        auto converted = iota(data.spaceCount).filter!(i => state.spaces[i] >= Space.Type.min && state.spaces[i] != CustomSpace.BLUE).array;
        d.check(!converted.empty, "No converted spaces");

        string[] problems;
        foreach (type; config.standardSpaceRatio.keys.sort) {
            // A converted space, and one that was that type already (for comparison)
            auto reachable = reachableSpaces(type);
            auto conv = reachable.filter!(s => state.spaces[s] == cast(CustomSpace)type && eventList(s) == 0).array;
            auto natural = reachable.filter!(s => state.spaces[s] == CustomSpace.DEFAULT && eventList(s) == 0).array;
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
        auto targets = reachableSpaces(type).filter!(s => state.spaces[s] == cast(CustomSpace)type && eventList(s) == 0).array;
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
            foreach (b; [EnumMembers!BonusType]) stats[i][b] = getBonusStat(p, b);
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
