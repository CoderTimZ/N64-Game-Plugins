// Mario Party 3 tests, run by the test build of the plugin (dub build -c mp3-test). See test/driver.d, and
// test/mp1test.d for the Mario Party 1 tests these follow.
module me.timz.n64.mp3test;

version (TestDriver):

import me.timz.n64.marioparty;
import me.timz.n64.marioparty3;
import me.timz.n64.plugin;
import me.timz.n64.testdriver;
import std.algorithm;
import std.array;
import std.conv;
import std.format;
import std.range;
import std.string;

// States the tests start from, in the test emulator's folder (TestStates/), made from boot with the plugin's options
// off (test/mp3-config-plain.json) and an empty State
// Chilly Waters, a new game of 20 turns (with bonuses, all mini-games): turn 1, as P2's turn starts (P1's move is
// done). P1 Daisy, P2 Luigi, P4 Peach (computers, normal), P3 Mario (human), 10 coins each but P1's 8.
enum STATE_CHILLY_TURN_1 = "TestStates/mp3-chilly-turn1.st";

// Board data the plugin's Memory doesn't have
enum Address STEPS_LEFT  = 0x800D41C0; // s32: steps left in the moving player's move (counts down on each solid space;
                                       // they land on the one where it reaches 0)
enum Address CHAIN_COUNT = 0x80105212; // u16: how many chains the board has
enum Address CHAINS      = 0x80105218; // Pointer to the chains: per chain, s16 length, s16, then a pointer to its s16
                                       // space indexes
enum Address BATTLE_AMOUNTS = 0x80101E44; // u16[5]: the battle roulette's coin amounts (0, 10, 20, 30, 50; 0 cancels
                                          // the battle)
enum Address SPACES      = 0x80105214; // Pointer to the board's spaces
enum Address PLAYERS     = 0x800D1108; // The players (0x38 bytes each): chain and position in it (0x0F, 0x10), and the
                                       // chain and position they move to next (0x11, 0x12)

class TestMarioParty3 : MarioParty3 {
    TestDriver driver;
    alias d = driver;

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
        driver.onFrame();
    }

    override void onInput(int port, InputData* input) {
        driver.onInput(port, input);
        super.onInput(port, input);
    }

    // --- Setup ---

    // Loads a state and makes every player a computer (unless allCPU is false)
    void setUp(string stateFile, bool allCPU = true) {
        d.loadEmulatorState(stateFile);
        if (allCPU) players.each!(p => p.data.flags = p.data.flags | 1);
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
    Address chains() { return CHAINS.val!uint; }
    ushort chainCount() { return valid(chains) ? CHAIN_COUNT.val!ushort : 0; }
    ushort chainLength(uint c) {
        return c < chainCount ? (chains + c * 8).val!ushort : 0;
    }
    short chainSpace(uint c, uint i) {
        if (i >= chainLength(c)) return -1;
        auto spaces = (chains + c * 8 + 4).val!uint;
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

    ref ubyte playerByte(Player p, uint offset) { return (PLAYERS + p.index * 0x38 + offset).val!ubyte; }
    ref ubyte chainOf(Player p)     { return playerByte(p, 0x0F); }
    ref ubyte positionOf(Player p)  { return playerByte(p, 0x10); }
    ref ubyte nextChainOf(Player p) { return playerByte(p, 0x11); }
    ref ubyte nextPositionOf(Player p) { return playerByte(p, 0x12); }

    short spaceOf(Player p) {
        return chainSpace(chainOf(p), positionOf(p));
    }

    // Puts a player on the space before `space` in its chain, so a one-step move lands on it
    void moveBefore(Player p, short space) {
        auto at = findInChains(space);
        d.check(at[0] >= 0 && at[1] >= 1, "Space " ~ space.to!string ~ " can't be reached in one step");
        chainOf(p) = cast(ubyte)at[0];
        positionOf(p) = cast(ubyte)(at[1] - 1);
        nextChainOf(p) = cast(ubyte)at[0];
        nextPositionOf(p) = cast(ubyte)at[1];
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
    // game sets it, putting them before the space again, in case it moved them)
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

    // Waits for the board to be loaded (after a mini-game, it's reloaded), with its spaces and chains
    void waitForBoard() {
        d.waitUntil(() => isBoardScene() && chainCount > 0 && valid(SPACES.val!uint) && data.spaceCount > 0,
                    "the board", 60 * 60);
        d.wait(30); // The board's chains are filled in just after they're allocated
    }

    // Waits for the start of a player's turn on the board
    void waitForTurn(uint player, string why = null) {
        d.waitUntil(() => isBoardScene() && data.currentPlayerIndex == player, "P" ~ (player + 1).to!string ~ "'s turn" ~
                    (why ? " (" ~ why ~ ")" : ""));
    }

    // Waits for a player's turn to end, pressing A now and then off the board (for the screens before and after a
    // mini-game), and returns the scenes it went through
    Scene[] playTurn(uint player) {
        Scene[] scenes;
        Scene scene = data.currentScene;
        auto start = d.frame;
        auto p = players[player];
        short space = spaceOf(p);
        int steps = stepsLeft;
        d.waitUntil(() {
            if (data.currentScene != scene) {
                scene = data.currentScene;
                if (scene != Scene.TRANSITION) scenes ~= scene;
                d.note("Scene ", scene, ": ", describe());
            }
            if (isBoardScene() && (spaceOf(p) != space || stepsLeft != steps)) {
                space = spaceOf(p);
                steps = stepsLeft;
                d.note("P", player + 1, " on space ", space, " (", space >= 0 ? data.spaces[space].type.to!string : "?",
                       "), ", steps, " steps left");
            }
            if (!isBoardScene() && (d.frame - start) % 90 < 10) d.hold(0, Pad.A); else d.hold(0, 0);
            return isBoardScene() && data.currentPlayerIndex != player;
        }, "P" ~ (player + 1).to!string ~ "'s turn to end", 60 * 60 * 10);
        d.release(0);
        return scenes;
    }

    // --- Tests ---

    Test[] tests() {
        return [
            Test("smoke", &smoke, 60 * 60),
            Test("singleUseBattleSpaces", &singleUseBattleSpaces, 60 * 60 * 20),
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

    // Keeps the emulator open for commands: runs each batch of steps written to TestCommands/mp3.txt (by
    // test/send-command.ps1 -Game mp3; the first line is "# <id>"), logs "READY <id>" and pauses until the next batch.
    // "quit" ends it, and "test:<name>" runs one of the tests.
    void serve() {
        d.note("READY 0");
        while (true) {
            auto text = d.waitForCommand("TestCommands/mp3.txt");
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
    // or "test:<name>" (runs a test).
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
        setUp(STATE_CHILLY_TURN_1);
        d.check(isBoardScene(), "Not on a board after loading the state");
        d.check(chainCount > 0 && data.spaceCount > 0, "No board spaces");
        d.note(data.spaceCount, " spaces in ", chainCount, " chains; P1 on space ", spaceOf(players[0]));
        d.wait(60);
        d.screenshot("smoke");
    }

    // Makes every slot of the battle roulette this many coins (0 cancels the battle), until the returned delegate is
    // called
    void delegate() setBattleAmounts(ushort amount) {
        ushort[5] before;
        foreach (i; 0..5) {
            before[i] = (BATTLE_AMOUNTS + i * 2).val!ushort;
            (BATTLE_AMOUNTS + i * 2).val!ushort = amount;
        }
        return () { foreach (i; 0..5) (BATTLE_AMOUNTS + i * 2).val!ushort = before[i]; };
    }

    // singleUseBattleSpaces (run with test/mp3-config.json, and test/mp3-config-lucky.json for it alongside Lucky
    // Spaces). P2 lands on a Battle Space and a battle is played (the roulette made to give 10 coins), after which the
    // space is a Blue Space, in the game and in the plugin's State. Then P3 lands on it, and gets a Blue Space's 3 coins
    // instead of a battle. Then P4 lands on another Battle Space, and the battle is cancelled (the roulette made to give
    // 0 coins), which leaves it a Battle Space.
    void singleUseBattleSpaces() {
        d.check(config.singleUseBattleSpaces, "Run this with singleUseBattleSpaces on (test/mp3-config.json)");
        string[] problems;

        setUp(STATE_CHILLY_TURN_1);
        waitForBoard();
        players.each!(p => p.data.coins = 20); // Everyone can pay for the battle
        auto battleSpaces = reachableSpaces(Space.Type.BATTLE);
        d.check(battleSpaces.length >= 2, "Fewer than 2 Battle Spaces can be reached in one step");
        auto target = battleSpaces[0], other = battleSpaces[1];
        auto lucky = state.spaces.count!(s => s == CustomSpace.LUCKY);
        d.note("Battle Spaces ", target, " and ", other, "; custom spaces: ", state.spaces.length, " (", lucky,
               " lucky)");

        // The used Battle Space stays a Blue Space: the other custom spaces don't take it, or change because of it
        void checkUsedSpace(string when) {
            waitForBoard();
            // When the board reloads (after a mini-game), its spaces start as the board's own, until the plugin sets
            // its custom spaces as it draws them
            foreach (i; 0..120) {
                if (data.spaces[target].type == Space.Type.BLUE) break;
                d.wait();
            }
            if (data.spaces[target].type != Space.Type.BLUE) {
                problems ~= format("space %d is a %s %s", target, data.spaces[target].type, when);
            }
            if (target >= state.spaces.length || state.spaces[target] != CustomSpace.BLUE) {
                problems ~= format("the State has space %d as %s %s", target,
                                   target < state.spaces.length ? state.spaces[target].to!string : "nothing", when);
            }
            auto nowLucky = state.spaces.count!(s => s == CustomSpace.LUCKY);
            if (nowLucky != lucky) problems ~= format("%d Lucky Spaces %s, not %d", nowLucky, when, lucky);
        }

        // A battle
        auto first = players[1], second = players[2], third = players[3];
        auto restore = setBattleAmounts(10);
        forceLanding(first, target);
        auto scenes = playTurn(first.index);
        restore();
        d.note("P", first.index + 1, "'s turn: ", scenes);
        if (!scenes.canFind(Scene.BATTLE_GAME_RESULTS)) problems ~= "no battle on the Battle Space: " ~ scenes.to!string;
        checkUsedSpace("after the battle");

        // The used Battle Space
        waitForTurn(second.index);
        d.wait(30);
        auto coins = second.data.coins;
        forceLanding(second, target);
        d.wait(40);
        d.screenshot("P" ~ (second.index + 1).to!string ~ " on the used Battle Space");
        scenes = playTurn(second.index);
        d.note("P", second.index + 1, "'s turn: ", scenes, "; coins ", coins, " -> ", second.data.coins);
        if (scenes.canFind(Scene.BATTLE_GAME_RESULTS)) {
            problems ~= "a battle on the used Battle Space: " ~ scenes.to!string;
        }
        if (second.data.coins != coins + 3) {
            problems ~= format("P%d got %+d coins on the used Battle Space, not a Blue Space's 3", second.index + 1,
                               second.data.coins - coins);
        }
        checkUsedSpace(format("after P%d's turn", second.index + 1));

        // A cancelled battle
        waitForTurn(third.index);
        d.wait(30);
        restore = setBattleAmounts(0);
        forceLanding(third, other);
        scenes = playTurn(third.index);
        restore();
        d.note("P", third.index + 1, "'s turn: ", scenes);
        if (scenes.canFind(Scene.BATTLE_GAME_RESULTS)) problems ~= "a battle for 0 coins: " ~ scenes.to!string;
        checkUsedSpace("after the next turn's mini-game"); // Waits for the board after the mini-game
        if (data.spaces[other].type != Space.Type.BATTLE) {
            problems ~= format("space %d is a %s after a cancelled battle", other, data.spaces[other].type);
        }
        if (other < state.spaces.length && state.spaces[other] == CustomSpace.BLUE) {
            problems ~= format("the State has space %d as BLUE after a cancelled battle", other);
        }

        d.screenshot("singleUseBattleSpaces");
        d.check(problems.empty, problems.join("; "));
    }
}
