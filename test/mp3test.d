// Mario Party 3 tests, run by the test build of the plugin (dub build -c mp3-test). See test/driver.d, and
// test/mp1test.d for the Mario Party 1 tests these follow.
module me.timz.n64.mp3test;

version (TestDriver):

import me.timz.n64.marioparty;
import me.timz.n64.marioparty3;
import me.timz.n64.mp3map;
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
            Test("autoStartNextBoard", &autoStartNextBoard, 60 * 60 * 30),
            Test("flagReaders", &flagReaders, 60 * 60 * 20),
            Test("balanceSuperHardCPU", &balanceSuperHardCPU, 60 * 60 * 20),
            Test("logJamMistakes", &logJamMistakes, 60 * 60 * 20),
            Test("slotSynchHumanPartner", &slotSynchHumanPartner, 60 * 60 * 40),
            Test("frigidBridgesFps", &frigidBridgesFps, 60 * 60 * 20),
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

    // Logs a0-a3 each time `address` runs in `inScene` (the first 20)
    void hitAddress(Scene inScene, uint address) {
        auto count = new int;
        address.onExec({
            if (data.currentScene != inScene || (*count)++ >= 20) return;
            d.note("hit ", address.to!string(16), ": ", (cast(uint)gpr.a0).to!string(16), " ", (cast(uint)gpr.a1).to!string(16), " ",
                   (cast(uint)gpr.a2).to!string(16), " ", (cast(uint)gpr.a3).to!string(16), " ra ", (cast(uint)gpr.ra).to!string(16));
        });
    }

    // See the hvqdump step
    void hvqDump(uint directory, string file) {
        import std.file : read, write;
        auto rom = cast(ubyte[])read(d.arg);
        uint be(size_t o) { return rom[o] << 24 | rom[o + 1] << 16 | rom[o + 2] << 8 | rom[o + 3]; }
        auto count = be(directory);                 // Files: the info, the HVQ-MPS, the tiles and an end offset
        auto tiles = count - 3;
        // The board code's work buffer (overlay 128's or 129's, whichever is loaded)
        // and its decoder setup (func_80069E68(the HVQ-MPS file), switched to this directory's and back)
        uint work, boardMps;
        if (0x800E6E58.val!uint == 0x0C01A63A) { work = 0x80102DCC.val!uint; boardMps = 0x80103138.val!uint; }
        else if (0x800E57F0.val!uint == 0x0C01A63A) { work = 0x80102D3C.val!uint; boardMps = 0x801031C0.val!uint; }
        auto mpsStart = directory + be(directory + 8), mpsEnd = directory + be(directory + 12);
        d.note("HVQ directory ", directory.to!string(16), ": ", tiles, " tiles, work buffer ", work.to!string(16));
        if (!work) return;
        auto output = new ubyte[tiles * 0x1800];
        auto done = new bool;
        // Started from HuPrcVSleep, a safe point in a game process (HuMemMemoryAllocTemp for the buffers)
        0x8004F074.onExecOnce({ 0x80035934.jal(0x4000, (uint input) {
            0x80035934.jal(0x1800, (uint pixels) {
                void decodeTile(uint t) {
                    if (t == tiles) {
                        write(file, output);
                        d.note("Wrote ", tiles, " tiles to ", file);
                        0x80069E68.jal(boardMps, { *done = true; });
                        return;
                    }
                    auto start = directory + be(directory + 4 + 4 * (t + 2)), end = directory + be(directory + 4 + 4 * (t + 3));
                    foreach (i; 0..end - start) (cast(Address)(input + i)).val!ubyte = rom[start + i];
                    0x800698E8.jal(input + 4, pixels, 64, work, {
                        foreach (i; 0..0x1800) output[t * 0x1800 + i] = (cast(Address)(pixels + i)).val!ubyte;
                        decodeTile(t + 1);
                    });
                }
                foreach (i; 0..mpsEnd - mpsStart) (cast(Address)(input + i)).val!ubyte = rom[mpsStart + i];
                0x80035934.jal(mpsEnd - mpsStart, (uint mps) {
                    foreach (i; 0..mpsEnd - mpsStart) (cast(Address)(mps + i)).val!ubyte = rom[mpsStart + i];
                    0x80069E68.jal(mps, { decodeTile(0); });
                });
            });
        }); });
        foreach (frame; 0..600) { if (*done) return; d.wait(); }
        d.note("STEP FAILED: the decoding didn't finish in 600 frames (the game's main thread may be stuck)");
    }

    // A model's vertices' X stretched by 424/320 as it loads (for finding which model is which)
    void stretchModel(uint dir, uint file) {
        auto directory = new uint;
        0x80009EAC.onExec({ if (gpr.a0 == 47) *directory = gpr.a1; });
        0x80009B64.onExec({
            if (gpr.a0 != 46 || *directory != dir || (gpr.a1 & 0xFFFF) != file) return;
            Address info = gpr.a2;
            gpr.ra.onExecOnce({
                auto rom = info.val!uint, size = (info + 4).val!uint;
                0x8000B000.onExecOnce({
                    if (gpr.a0 != rom) return;
                    Address buffer = gpr.a1;
                    gpr.ra.onExecOnce({
                        foreach (i; 0..size - 4) {
                            if ((buffer + i).val!ubyte != 'V' || (buffer + i + 1).val!ubyte != 'T') continue;
                            Address o = buffer + i + 8;
                            auto count = (o.val!ubyte << 8) | (o + 1).val!ubyte;
                            foreach (k; 0..count) {
                                Address p = o + 8 + 9 * k;
                                auto x = cast(short)((p.val!ubyte << 8) | (p + 1).val!ubyte);
                                auto w = cast(short)(x * 424 / 320);
                                p.val!ubyte = cast(ubyte)(w >> 8); (p + 1).val!ubyte = cast(ubyte)w;
                            }
                            d.note("Stretched (", dir, ", ", file, "): ", count, " vertices");
                            break;
                        }
                    });
                });
            });
        });
    }

    // Runs steps separated by spaces, logging scene changes. A step is a button (A, B, Z, START, L, R, UP, DOWN, LEFT,
    // RIGHT, CUP, CDOWN, CLEFT, CRIGHT, or several joined with +) pressed on controller 1, "wait<frames>", "shot",
    // "save:<file>" or "load:<file>" (an emulator state), "untilboard" (presses A until a board's first turn starts),
    // "stick:<x>,<y>", "cpu" (makes every player a computer), "spaces" (lists the board's spaces), "turn:<player>",
    // "lastturn" (makes the current turn the last), "until:<scene>" (presses A until a scene), "human:<player>",
    // "lucky:<P1>,<P2>,<P3>,<P4>" (Lucky Space counts), or "test:<name>".
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
            } else if (step == "lastturn") { // Makes the current turn the game's last
                data.totalTurns = data.currentTurn;
                d.note("Last turn: ", describe());
            } else if (step.startsWith("until:")) { // until:<scene>: presses A (Start on rules screens) until a scene
                auto target = step[6..$].to!Scene;
                auto start = d.frame;
                while (data.currentScene != target) {
                    auto button = data.currentScene == Scene.MINI_GAME_RULES ? Pad.START : Pad.A;
                    d.hold(0, !isBoardScene() && (d.frame - start) % 90 < 10 ? button : 0);
                    watch(1);
                    if ((d.frame - start) % 1800 == 1799) d.screenshot("until"); // To see where it's stuck, if it is
                    d.check(d.frame - start < 60 * 60 * 6, "Timed out waiting for " ~ target.to!string);
                }
                d.release(0);
                d.note("Reached ", target, ": ", describe());
            } else if (step.startsWith("human:")) { // human:<player>: makes a player (1-4) human
                auto p = players[step[6..$].to!int - 1];
                p.data.flags = p.data.flags & ~1;
                d.note("Human: ", describe());
            } else if (step == "dumpresults") { // Dumps the detailed results' icon files and logs their messages
                0x80108178.onExec({ // HuSprAnimRead(data): s2 = the icon file DataRead loaded
                    if (data.currentScene != Scene.FINAL_RESULTS) return;
                    import std.file : write;
                    auto bytes = new ubyte[4096];
                    foreach (k, ref b; bytes) b = (gpr.s2 + cast(uint)k).val!ubyte;
                    static int dumped;
                    auto name = format("TestLogs/icon-%02d.bin", dumped++);
                    write(name, bytes);
                    d.note("Dumped icon file at ", (cast(uint)gpr.s2).to!string(16), " to ", name);
                });
                0x80036574.onExec({ // A message is being loaded: s0 = length, then text
                    if (data.currentScene != Scene.FINAL_RESULTS) return;
                    if (messageId < 0x1900 || messageId > 0x190C) return;
                    auto bytes = iota(cast(short)gpr.s1).map!(k => (gpr.s0 + 2 + k).val!ubyte);
                    d.note(format("Message %04X: %(%02X %)", messageId, bytes));
                });
            } else if (step.startsWith("lucky:")) { // lucky:<P1>,<P2>,<P3>,<P4>: each player's Lucky Space count
                foreach (i, v; step[6..$].split(",").map!(v => v.to!int).array) players[i].state.luckySpaceCount = v;
                saveState();
                d.note("Lucky Space counts: ", players.map!(p => p.state.luckySpaceCount));
            } else if (step.startsWith("untilshop")) { // untilshop[:<state>]: until a player enters an item shop (func_800EC590), which gives them 50 coins (to buy something), then saves a state there
                bool entered;
                0x800EC590.onExecOnce({ entered = true; });
                auto start = d.frame;
                while (!entered) {
                    d.check(d.frame - start < 60 * 60 * 30, "No item shop in 30 minutes");
                    watch(1);
                }
                auto p = players[data.currentPlayerIndex];
                p.data.coins = 50;
                d.note("Item shop: ", describe());
                if (step.length > 10) d.saveEmulatorState(step[10..$]);
            } else if (step.startsWith("buywatch:")) { // buywatch:<shots>: plays (every player getting 50 coins each turn) until someone buys an item, with that many screenshots 10 frames apart
                int[4] coins;
                Item[3][4] items;
                void remember() { foreach (i, p; players) { coins[i] = p.data.coins; foreach (k; 0..3) items[i][k] = p.data.items[k]; } }
                int turnPlayer = -1;
                remember();
                auto start = d.frame;
                // Sprite positions near the old screen's middle (func_80054904(group, index, x, y)), by caller
                bool[string] seen;
                0x80054904.onExec({
                    auto x = cast(short)gpr.a2;
                    if (!isBoardScene() || x < 140 || x > 175) return;
                    auto key = format("ra %08X x %d y %d", cast(uint)gpr.ra, x, cast(short)gpr.a3);
                    if (key !in seen) { seen[key] = true; d.note("Sprite position: ", key); }
                });
                while (true) {
                    d.check(d.frame - start < 60 * 60 * 60, "No purchase in an hour");
                    if (isBoardScene() && data.currentPlayerIndex != turnPlayer) {
                        turnPlayer = data.currentPlayerIndex;
                        foreach (p; players) p.data.coins = 50;
                        remember();
                        // The latest turn's start, to replay a purchase from (load it, then buywatch again)
                        d.saveEmulatorState("TestStates/mp3-buywatch-turn.st");
                    }
                    watch(1);
                    bool bought;
                    foreach (i, p; players) {
                        if (p.data.coins + 5 <= coins[i]) bought = true;
                        foreach (k; 0..3) if (p.data.items[k] != items[i][k] && p.data.items[k] != Item.NONE) bought = true;
                    }
                    remember();
                    if (bought) break;
                }
                d.note("Bought: ", describe(), " items ", players.map!(p => p.data.items[0]));
                foreach (i; 0..step[9..$].to!int) { watch(10); d.screenshot("buy"); }
            } else if (step.startsWith("pad:")) { // pad:<player>,<port>: a player's (1-4) controller (0-3)
                auto v = step[4..$].split(",").map!(x => x.to!int).array;
                players[v[0] - 1].data.controller = cast(ubyte)v[1];
                d.note("Controller: P", v[0], " port ", v[1]);
            } else if (step.startsWith("shots:")) { // shots:<count>,<frames>: screenshots that many frames apart
                auto v = step[6..$].split(",").map!(x => x.to!int).array;
                foreach (i; 0..v[0]) { watch(v[1]); d.screenshot("shots"); }
            } else if (step == "noduels") { // No duels on shared spaces (the check setUpAlwaysDuel() forces on)
                0x800FA854.onExec({ if (isBoardScene()) gpr.v0 = 0; });
                d.note("No duels");
            } else if (step == "skipgames") { // Mini-games are skipped (like Superstars' results): the rules screen goes
                                              // straight to the results, with no coins won
                0x80048128.onExec({
                    if (gpr.a0 != Scene.MINI_GAME_RULES) return;
                    players.each!((p) { p.data.gameCoinsExtra = 0; p.data.gameCoinsMain = 0; });
                    gpr.a0 = Scene.MINI_GAME_RESULTS;
                    d.note("Skipped a mini-game");
                });
            } else if (step.startsWith("stretchmodel:")) { // stretchmodel:<dir>,<file>: a model's X stretched by 424/320 as it loads
                auto v = step[13..$].split(",").map!(x => x.to!uint).array;
                stretchModel(v[0], v[1]);
            } else if (step == "decompressions") { // Logs every decompression (func_8000B000(rom, buffer, size, type)) and dumps it
                0x8000B000.onExec({
                    auto rom = cast(uint)gpr.a0, size = cast(uint)gpr.a2, type = cast(uint)gpr.a3;
                    Address buffer = gpr.a1;
                    gpr.ra.onExecOnce({
                        import std.file : mkdirRecurse, write;
                        auto bytes = new ubyte[size];
                        foreach (i, ref b; bytes) b = (buffer + cast(uint)i).val!ubyte;
                        mkdirRecurse("TestLogs/decomp");
                        write(format("TestLogs/decomp/%08X.bin", rom), bytes);
                        d.note("Decompressed ", rom.to!string(16), " size ", size, " type ", type, " first ",
                               buffer.val!uint.to!string(16), " in ", data.currentScene);
                    });
                });
            } else if (step.startsWith("dumpram:")) { // dumpram:<file>: writes the 8 MB of RDRAM (big-endian)
                import std.file : write;
                auto bytes = new ubyte[0x800000];
                foreach (i; 0..0x200000) {
                    auto w = (0x80000000 + i * 4).val!uint;
                    bytes[4 * i] = cast(ubyte)(w >> 24); bytes[4 * i + 1] = cast(ubyte)(w >> 16);
                    bytes[4 * i + 2] = cast(ubyte)(w >> 8); bytes[4 * i + 3] = cast(ubyte)w;
                }
                write(step[8..$], bytes);
                d.note("Dumped RDRAM to ", step[8..$]);
            } else if (step.startsWith("watchwrite:")) { // watchwrite:<hex address>: logs the first writes to a byte, with pc and ra
                Address address = step[11..$].to!uint(16);
                auto count = new int;
                address.val!ubyte.onWrite((ref ubyte v, Address pc) {
                    if ((*count)++ < 6) d.note("Write ", address.to!string(16), " = ", v, " from ", pc.to!string(16),
                                               " ra ", (cast(uint)gpr.ra).to!string(16), " in ", data.currentScene);
                });
            } else if (step.startsWith("watchread:")) { // watchread:<hex address>: logs the first reads of a byte, with pc and ra
                Address address = step[10..$].to!uint(16);
                auto count = new int;
                address.val!ubyte.onRead((ref ubyte v, Address pc) {
                    if ((*count)++ < 6) d.note("Read ", address.to!string(16), " = ", v, " from ", pc.to!string(16),
                                               " ra ", (cast(uint)gpr.ra).to!string(16), " in ", data.currentScene);
                });
            } else if (step.startsWith("hit:")) { // hit:<scene>,<hex address>: logs a0-a3 each time the address runs in that scene (the first 20)
                auto v = step[4..$].split(",");
                hitAddress(v[0].to!Scene, v[1].to!uint(16));
            } else if (step.startsWith("hvqdump:")) { // hvqdump:<hex ROM offset of an HVQ directory>,<file>: decodes its
                // tiles with the game's decoder (func_800698E8(data + 4, out, 64, work), which the board code sets up
                // for the board's background: run it on that board) and writes them as RGBA5551, in the directory's order
                // (the ROM is N64TEST_ARG)
                auto v = step[8..$].split(",");
                hvqDump(v[0].to!uint(16), v[1]);
            } else if (step.startsWith("mapbg:")) { // mapbg:<background dir>,<map dir>: sharperCustomBoardMaps' map from that background
                auto v = step[6..$].split(",").map!(x => x.to!uint).array;
                0x8004F074.onExecOnce({ useCustomBoardMapBackground(v[0], v[1]); }); // From HuPrcVSleep
                auto start = d.frame;
                watch(2);
                while (customBoardMapPreparing() && d.frame - start < 1800) watch(1);
                d.note("Map background: ", v[0], " (made in ", d.frame - start, " frames)");
            } else if (step.startsWith("poke:")) { // poke:<hex address>,<byte>: writes a byte
                auto v = step[5..$].split(",");
                (cast(Address)v[0].to!uint(16)).val!ubyte = v[1].to!ubyte;
                d.note("Poked ", v[0], " = ", v[1]);
            } else if (step.startsWith("roll:")) { // roll:<player>,<steps>[,r]: that player's (1-4) next roll is made
                                                   // that many steps (r: and backward, as with a Reverse Mushroom,
                                                   // set as the roll is: the walk checks for it just after)
                auto v = step[5..$].split(",");
                auto player = v[0].to!int, count = v[1].to!int;
                auto reverse = v.length > 2 && v[2] == "r";
                auto pending = new bool;
                *pending = true;
                STEPS_LEFT.val!int.onWrite((ref int steps) {
                    if (!*pending || data.currentPlayerIndex != player - 1) return;
                    if (steps <= 0 || steps == stepsLeft - 1) return; // Not a roll: a step's count down
                    *pending = false;
                    d.note("P", player, " rolled ", steps, ", made ", count, reverse ? " backward" : "");
                    steps = count;
                    if (reverse) playerByte(players[player - 1], 0x17) |= 0x80;
                });
            } else if (step == "walklog") { // Logs each step of a move (the walk loop's prev = cur, cur = next at
                                            // func_800FCA7C + 0xA18): current, previous and next chain positions and
                                            // +0x17 (0x80: Reverse Mushroom, 0x01: walking backward)
                0x800FD4DC.onExec({
                    if (!isBoardScene()) return;
                    Address p = gpr.s2;
                    string at(int o) {
                        auto c = (p + o).val!byte, k = (p + o + 1).val!byte;
                        return c >= 0 && c < chainCount && k >= 0 && k < chainLength(c)
                            ? format("%d (%d,%d)", chainSpace(c, k), c, k) : format("INVALID (%d,%d)", c, k);
                    }
                    d.note("Walk P", data.currentPlayerIndex + 1, ": at ", at(0x0F), " from ", at(0x15), " next ",
                           at(0x11), format(" flags %02X", (p + 0x17).val!ubyte), " steps ", stepsLeft);
                });
            } else if (step == "files") { // Logs the files the game reads from its main file system, with images' sizes
                auto directory = new uint;
                0x80009EAC.onExec({ if (gpr.a0 == 47) *directory = gpr.a1; });
                0x80009B64.onExec({
                    if (gpr.a0 != 46) return;
                    auto file = gpr.a1 & 0xFFFF, dir = *directory;
                    Address info = gpr.a2;
                    gpr.ra.onExecOnce({
                        auto rom = info.val!uint, size = (info + 4).val!uint;
                        d.note("File (", dir, ", ", file, ") size ", size, " in ", data.currentScene);
                        0x8000B000.onExecOnce({
                            if (gpr.a0 != rom) return;
                            Address buffer = gpr.a1;
                            gpr.ra.onExecOnce({
                                import std.file : mkdirRecurse, write;
                                auto bytes = new ubyte[size];
                                foreach (i, ref b; bytes) b = (buffer + cast(uint)i).val!ubyte;
                                mkdirRecurse("TestLogs/files");
                                write(format("TestLogs/files/%d-%d.bin", dir, file), bytes);
                                if (buffer.val!uint != 0x20) return; // Not an image
                                d.note("  image (", dir, ", ", file, "): ", (buffer + 0x24).val!ushort, "x",
                                       (buffer + 0x26).val!ushort, " format ", (buffer + 0x19).val!ubyte);
                            });
                        });
                    });
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

    // autoStartNextBoard (run with test/mp3-config-autostart.json, which also has Lucky Spaces and
    // preventRepeatMiniGames): the game ends after this turn, and the next board starts with the plugin's
    // start-of-game resets done, like a game started from the castle grounds: no Lucky Spaces landed on, the mini-game
    // order started over, and the board's own custom spaces.
    void autoStartNextBoard() {
        d.check(config.autoStartNextBoard && config.luckySpaceRatio > 0 && config.preventRepeatMiniGames,
                "Run this with test/mp3-config-autostart.json");
        string[] problems;

        setUp(STATE_CHILLY_TURN_1);
        waitForBoard();
        data.totalTurns = data.currentTurn; // This turn is the last
        players.each!(p => p.state.luckySpaceCount = 5);
        saveState();
        auto board = data.currentBoard;
        d.note("Last turn on board ", board, ": ", describe());

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
            return isBoardScene() && data.currentBoard != board;
        }, "the next board", 60 * 60 * 25);
        d.release(0);
        waitForBoard();
        d.wait(120);
        d.note("Next board: ", describe(), "; scenes ", scenes);
        d.screenshot("autoStartNextBoard");

        if (!scenes.canFind(Scene.FINAL_RESULTS)) problems ~= "no final results: " ~ scenes.to!string;
        if (data.currentBoard != (board + 1) % 6) problems ~= format("board %d after board %d", data.currentBoard, board);
        if (data.currentTurn != 1) problems ~= format("the next game starts on turn %d", data.currentTurn);
        foreach (p; players) {
            if (p.state.luckySpaceCount != 0) {
                problems ~= format("P%d's Lucky Space count is still %d", p.index + 1, p.state.luckySpaceCount);
            }
        }
        if (state.miniGameQueue.byValue.any!(q => !q.empty)) problems ~= "the mini-game order wasn't started over";
        if (state.spacesBoard != data.currentBoard) {
            problems ~= format("the custom spaces are board %d's, not board %d's", state.spacesBoard, data.currentBoard);
        }
        d.check(problems.empty, problems.join("; "));
    }

    // Logs the code that reads and writes the save's flag bytes that unlockEverything changes (GwCommon.flag[5] and
    // [6]), and the calls that set or clear flags and encode the save, while the game plays to its end (the final
    // results save the game)
    void flagReaders() {
        int[Address] readers;
        foreach (Address a; [0x800CC158, 0x800CC159]) {
            a.val!ubyte.onRead((ref ubyte v, Address pc) { readers[pc]++; });
            a.val!ubyte.onWrite((ref ubyte v, Address pc) {
                d.note("WRITE ", a.to!string(16), " = ", v.to!string(16), " from ", pc.to!string(16));
            });
        }
        0x80035EF4.onExec({ d.note("CALL _SetFlag(", cast(int)gpr.a0, ") from ", (cast(uint)gpr.ra).to!string(16)); });
        0x80035F44.onExec({ d.note("CALL _ClearFlag(", cast(int)gpr.a0, ") from ", (cast(uint)gpr.ra).to!string(16)); });
        0x8004F5A4.onExec({
            d.note("CALL SaveFileEncode(", (cast(uint)gpr.a0).to!string(16), ", ", (cast(uint)gpr.a1).to!string(16), ")");
        });

        setUp(STATE_CHILLY_TURN_1);
        waitForBoard();
        data.totalTurns = data.currentTurn; // This turn is the last
        auto start = d.frame;
        ulong resultsAt;
        d.waitUntil(() {
            if (data.currentScene == Scene.FINAL_RESULTS && !resultsAt) resultsAt = d.frame;
            auto press = data.currentScene != Scene.FINAL_RESULTS && (d.frame - start) % 90 < 10;
            d.hold(0, press ? Pad.A : 0);
            return resultsAt && d.frame - resultsAt > 60 * 30;
        }, "the final results", 60 * 60 * 15);
        d.release(0);
        foreach (pc; readers.keys.sort) d.note("READ from ", pc.to!string(16), " x", readers[pc]);
        d.note("Flags now ", 0x800CC158.val!ubyte.to!string(16), " ", 0x800CC159.val!ubyte.to!string(16));
    }

    // balanceSuperHardCPU in Log Jam (run with test/mp3-config-logjam.json, which blocks every other 2 vs 2
    // mini-game): every player is a Super Hard computer, and the panels are kept 2 blue and 2 red so the round ends
    // with Log Jam. Logs the code that reads each player's difficulty, by scene, and the value it gets (after the
    // plugin's change); in Log Jam, every read should stay Super Hard (the option fixes its teammate check instead).
    void balanceSuperHardCPU() {
        d.check(config.balanceSuperHardCPU, "Run this with test/mp3-config-logjam.json");
        int[string] reads;
        string[] problems;
        foreach (p; players) {
            p.data.cpuDifficulty.onRead((ref ubyte v, Address pc) {
                auto key = format("%s from %08X: %s", data.currentScene, pc, cast(CPUDifficulty)v);
                if (key !in reads) d.note("READ P", p.index + 1, " ", key);
                reads[key]++;
                if (data.currentScene == Scene.LOG_JAM && v != CPUDifficulty.SUPER_HARD) {
                    problems ~= format("Log Jam read P%d's difficulty as %s (from %08X)", p.index + 1,
                                       cast(CPUDifficulty)v, pc);
                }
            });
        }

        setUp(STATE_CHILLY_TURN_1);
        waitForBoard();
        players.each!(p => p.data.cpuDifficulty = CPUDifficulty.SUPER_HARD);
        Scene[] scenes;
        Scene scene = data.currentScene;
        auto start = d.frame;
        d.waitUntil(() {
            if (data.currentScene != scene) {
                scene = data.currentScene;
                if (scene != Scene.TRANSITION) scenes ~= scene;
                d.note("Scene ", scene);
            }
            if (isBoardScene() && !scenes.canFind(Scene.LOG_JAM)) {
                foreach (p; players) {
                    auto color = p.index < 2 ? PanelColor.BLUE : PanelColor.RED;
                    p.data.color = color;
                    p.panel.color = color;
                }
            }
            auto press = !isBoardScene() && (d.frame - start) % 90 < 10;
            d.hold(0, press ? Pad.A : 0);
            return scenes.canFind(Scene.LOG_JAM) && isBoardScene();
        }, "Log Jam to be played", 60 * 60 * 15);
        d.release(0);
        d.note("Scenes ", scenes);
        foreach (key; reads.keys.sort) d.note("  ", key, " x", reads[key]);
        d.check(scenes.canFind(Scene.LOG_JAM), "Log Jam wasn't played: " ~ scenes.to!string);
        d.check(reads.keys.any!(k => k.startsWith("LOG_JAM")), "Log Jam never read a difficulty");
        d.check(problems.empty, problems.uniq.join("; "));
    }

    // Counts the computers' right and wrong presses in Log Jam, with every player a Super Hard computer (run with
    // test/mp3-config-logjam.json for balanceSuperHardCPU, which lets a human's partner make mistakes too, or
    // test/mp3-config-logjam-off.json without it). Log Jam's two press decisions store the right button at 0x801089B8 and 0x80108C18, and a wrong one
    // at 0x80108A04 and 0x80108C64 (for the player whose data is in s1 and s0 there).
    void logJamMistakes() {
        string[Address] presses; // By player data: "R" or "W" for each press, in order
        auto record = (Address player, string press) {
            if (data.currentScene == Scene.LOG_JAM) presses[player] ~= press;
        };
        0x801089B8.onExec({ record(gpr.s1, "R"); });
        0x80108C18.onExec({ record(gpr.s0, "R"); });
        0x80108A04.onExec({ record(gpr.s1, "W"); });
        0x80108C64.onExec({ record(gpr.s0, "W"); });
        // Before a wrong press, each decision checks a computer flag (offset 0x1E) in another struct: s0 for the
        // player in s1, and s2 for the player in s0
        int[string] checks;
        auto check = (Address player, Address other) {
            if (data.currentScene != Scene.LOG_JAM) return; // Other code is at these addresses outside Log Jam
            auto key = format("player %08X (port %d, computer %d) checks %08X: %d", player, (player + 26).val!short,
                              (player + 30).val!short, other, (other + 30).val!short);
            if (key !in checks) d.note("CHECK ", key);
            checks[key]++;
        };
        0x8010896C.onExec({ check(gpr.s1, gpr.s0); });
        0x80108BCC.onExec({ check(gpr.s0, gpr.s2); });

        setUp(STATE_CHILLY_TURN_1);
        waitForBoard();
        players.each!(p => p.data.cpuDifficulty = CPUDifficulty.SUPER_HARD);
        // N64TEST_ARG: the players (1-4) to make human, like "1,3"
        foreach (n; d.arg.split(",").filter!(a => !a.empty).map!(a => a.strip.to!int)) {
            players[n - 1].data.flags = players[n - 1].data.flags & ~1;
        }
        d.note("Players: ", players.map!(p => format("P%d port %d %s", p.index + 1, p.data.controller,
                                                       p.isCPU ? "computer" : "human")).join(", "));
        bool played;
        auto start = d.frame;
        d.waitUntil(() {
            if (data.currentScene == Scene.LOG_JAM) played = true;
            if (isBoardScene() && !played) {
                foreach (p; players) {
                    auto color = p.index < 2 ? PanelColor.BLUE : PanelColor.RED;
                    p.data.color = color;
                    p.panel.color = color;
                }
            }
            auto press = (!isBoardScene() || !players.find!(p => p.data.controller == 0).front.isCPU) && (d.frame - start) % 90 < 10;
            // On the rules screen, A only pages through the rules: Start starts the mini-game
            auto button = data.currentScene == Scene.MINI_GAME_RULES ? Pad.START : Pad.A;
            d.hold(0, press ? button : 0);
            // Human players' controllers too, everywhere (their turns, and the mini-game roulette)
            foreach (p; players.filter!(p => !p.isCPU && p.data.controller != 0)) {
                d.hold(p.data.controller, (d.frame - start) % 90 < 10 ? button : 0);
            }
            // In Log Jam, humans press the button their log needs (in their Log Jam data, which is 0x38 bytes per
            // player from 0x801DA370, in no particular order: the controller port at 0x1A, the button at 0x24: 0 A, 1 B, 2 Z), every 12 frames
            if (data.currentScene == Scene.LOG_JAM) {
                foreach (p; players.filter!(p => !p.isCPU)) {
                    auto found = iota(4).map!(k => cast(Address)(0x801DA370 + k * 0x38))
                                        .find!(a => (a + 0x1A).val!short == p.data.controller);
                    if (found.empty) continue;
                    auto st = found.front;
                    auto need = (st + 0x24).val!short;
                    auto b = need == 0 ? Pad.A : need == 1 ? Pad.B : Pad.Z;
                    d.hold(p.data.controller, d.frame % 12 < 4 ? b : 0);
                }
            }
            return played && isBoardScene();
        }, "Log Jam to be played", 60 * 60 * 15);
        foreach (port; 0..4) d.release(port);

        d.check(played, "Log Jam wasn't played");
        size_t right, wrong, longest;
        foreach (player; presses.keys.sort) {
            auto seq = presses[player];
            auto w = seq.count('W');
            auto streak = seq.split("R").map!(r => r.length).fold!max(0UL);
            d.note(format("Player data %08X: %d presses, %d wrong (%.0f%%), at most %d wrong in a row: %s", player,
                          seq.length, w, 100.0 * w / seq.length, streak, seq));
            right += seq.length - w;
            wrong += w;
            longest = max(longest, streak);
        }
        d.note(format("All: %d presses, %d wrong (%.1f%%), at most %d wrong in a row", right + wrong, wrong,
                      100.0 * wrong / (right + wrong), longest));
        foreach (key; checks.keys.sort) d.note("  ", key, " x", checks[key]);
        d.check(right + wrong > 0, "No presses counted");
    }

    // Slot Synch with balanceSuperHardCPU (run with test/mp3-config-slotsynch.json, which blocks every other 2 vs 2
    // mini-game), the players in N64TEST_ARG (like "1") human and the rest Easy computers, P1 and P2 one team and P3 and
    // P4 the other, until Slot Synch has been played 3 times. Humans press A every 240 frames, so they stop their reel at
    // a random time (before or after the computer), on a random symbol. For each round it logs each team's symbols, who
    // stopped first and the computers' miss rolls, and checks that a human's computer partner plays like the plugin
    // makes it: when it doesn't roll a miss it stops on +3, or on the human's symbol if the human stopped first (unless
    // that's -1), and it never matches a -1 the human stopped on first. A rolled miss presses A when the symbol coming
    // up isn't its target, but the reel can still land on the target (computer-only teams do that too), so misses are
    // only counted.
    void slotSynchHumanPartner() {
        d.check(config.balanceSuperHardCPU, "Run this with test/mp3-config-slotsynch.json");
        enum string[] NAMES = ["+3", "+1", "+2", "-1"]; // Symbols 0-3
        // Each team's data (s0 at 0x80106AEC, where a round's result is decided): its two players' Slot Synch data at
        // 0x08 and 0x0C (0x00 reel, 0x22 computer flag, 0x28 miss roll, 0x2C the symbol it aims for). Each reel:
        // 0x3C bytes from *0x8010DF7C, 0x0C nonzero while it's spinning.
        Address reel(Address player) { return 0x8010DF7C.val!uint + (player + 0x00).val!short * 0x3C; }
        bool[4] spinning;
        ulong[4] stoppedAt, pressedAt; // When each reel stopped, and when a computer pressed A to stop it
        // A computer's press (0x801074DC, its data in s1): its reel keeps turning for a few frames after it
        0x801074DC.onExec({
            if (data.currentScene != Scene.SLOT_SYNCH) return;
            auto r = (gpr.s1 + 0x00).val!short;
            if (r >= 0 && r < 4 && pressedAt[r] == ulong.max) pressedAt[r] = d.frame;
        });
        int humanRounds, misses, missesOnTarget, wrong, plays;
        int[string] counts;
        string[] problems;
        0x80106AEC.onExec({
            if (data.currentScene != Scene.SLOT_SYNCH) return;
            Address[2] members = [(gpr.s0 + 0x08).val!uint, (gpr.s0 + 0x0C).val!uint];
            short[2] symbols = [cast(short)gpr.s1, cast(short)gpr.s2];
            auto result = (gpr.s0 + 0x1A).val!short;
            string describeMember(int k) {
                auto m = members[k];
                auto r = (m + 0x00).val!short;
                return format("reel %d %s %s at %d%s", r, (m + 0x22).val!short ? "computer" : "human",
                              NAMES[symbols[k] & 3], stoppedAt[r],
                              (m + 0x22).val!short ? format(" (pressed at %d, aims %s, miss %d)", pressedAt[r],
                                                          NAMES[(m + 0x2C).val!short & 3], (m + 0x28).val!short) : "");
            }
            d.note("ROUND ", describeMember(0), " | ", describeMember(1), " -> ",
                   result == 4 ? "no match" : NAMES[result & 3]);
            foreach (k; 0..2) {
                auto cpu = members[k], human = members[1 - k];
                if (!(cpu + 0x22).val!short || (human + 0x22).val!short) continue;
                humanRounds++;
                auto miss = (cpu + 0x28).val!short != 0;
                if (miss) misses++;
                // Whether the human's reel had stopped when the computer pressed A
                auto humanFirst = stoppedAt[(human + 0x00).val!short] < pressedAt[(cpu + 0x00).val!short];
                auto target = humanFirst && symbols[1 - k] != 3 ? symbols[1 - k] : 0;
                if (miss && symbols[k] == target) missesOnTarget++;
                counts[format("%s, human %s %s", miss ? "miss" : "aim", humanFirst ? "first" : "second",
                              NAMES[symbols[1 - k] & 3])]++;
                string problem;
                if (!miss && symbols[k] != target) {
                    problem = format("aimed and stopped on %s, not %s", NAMES[symbols[k] & 3], NAMES[target]);
                } else if (humanFirst && symbols[1 - k] == 3 && symbols[k] == 3) {
                    problem = "matched the human's -1";
                }
                if (problem) {
                    wrong++;
                    problems ~= problem;
                    d.note("PROBLEM ", problem);
                }
            }
        });

        setUp(STATE_CHILLY_TURN_1);
        waitForBoard();
        players.each!(p => p.data.cpuDifficulty = CPUDifficulty.EASY);
        // N64TEST_ARG: the players (1-4) to make human, like "1"
        foreach (n; d.arg.split(",").filter!(a => !a.empty).map!(a => a.strip.to!int)) {
            players[n - 1].data.flags = players[n - 1].data.flags & ~1;
        }
        d.note("Players: ", players.map!(p => format("P%d port %d %s", p.index + 1, p.data.controller,
                                                       p.isCPU ? "computer" : "human")).join(", "));
        auto start = d.frame;
        auto scene = data.currentScene;
        d.waitUntil(() {
            if (data.currentScene != scene) {
                if (scene == Scene.SLOT_SYNCH) plays++;
                scene = data.currentScene;
            }
            if (isBoardScene()) {
                foreach (p; players) {
                    auto color = p.index < 2 ? PanelColor.BLUE : PanelColor.RED;
                    p.data.color = color;
                    p.panel.color = color;
                }
            }
            // When each reel stops
            if (data.currentScene == Scene.SLOT_SYNCH && valid(0x8010DF7C.val!uint)) {
                foreach (r; 0..4) {
                    auto now = (0x8010DF7C.val!uint + r * 0x3C + 0x0C).val!short != 0;
                    if (spinning[r] && !now) stoppedAt[r] = d.frame;
                    if (now) stoppedAt[r] = ulong.max;
                    if (now && !spinning[r]) pressedAt[r] = ulong.max;
                    spinning[r] = now;
                }
            }
            auto press = (!isBoardScene() || !players.find!(p => p.data.controller == 0).front.isCPU) &&
                         (d.frame - start) % 90 < 10;
            // On the rules screen, A only pages through the rules: Start starts the mini-game
            auto button = data.currentScene == Scene.MINI_GAME_RULES ? Pad.START : Pad.A;
            d.hold(0, press ? button : 0);
            foreach (p; players.filter!(p => !p.isCPU && p.data.controller != 0)) {
                d.hold(p.data.controller, (d.frame - start) % 90 < 10 ? button : 0);
            }
            // In Slot Synch, humans press A every 240 frames
            if (data.currentScene == Scene.SLOT_SYNCH) {
                foreach (p; players.filter!(p => !p.isCPU)) d.hold(p.data.controller, d.frame % 240 < 4 ? Pad.A : 0);
            }
            if ((d.frame - start) % (60 * 60) == 0) d.screenshot(format("slotsynch-%s", data.currentScene));
            return plays >= 3 && isBoardScene();
        }, "Slot Synch to be played 3 times", 60 * 60 * 35);
        foreach (port; 0..4) d.release(port);

        foreach (key; counts.keys.sort) d.note("  ", key, " x", counts[key]);
        d.note(format("Human's partner: %d rounds, %d misses rolled (%.0f%%, %d still on the target), %d problems",
                      humanRounds, misses, humanRounds ? 100.0 * misses / humanRounds : 0, missesOnTarget, wrong));
        d.check(plays >= 1, "Slot Synch wasn't played");
        d.check(humanRounds > 0, "No rounds with a human's computer partner");
        d.check(problems.empty, problems.uniq.join("; "));
    }

    // Measures the emulator's speed (frames per wall-clock second, with the speed limiter off and on) on the board and in
    // Frigid Bridges, a four-way split-screen mini-game (run with test/mp3-config-frigid.json, which blocks every other
    // 4-player mini-game). Every player is a computer and the panels are held blue, so the round ends with it.
    void frigidBridgesFps() {
        import std.datetime.stopwatch : StopWatch, AutoStart;
        enum CHUNK = 120;
        // The game's own speed: calls to HuPrcVSleep (each game process calls it once per game frame) per VI
        ulong sleeps;
        0x8004F074.onExec({ sleeps++; });
        double[] measure(ulong chunks, string where) {
            double[] rates, game;
            foreach (c; 0..chunks) {
                auto sw = StopWatch(AutoStart.yes);
                auto before = sleeps;
                d.wait(CHUNK);
                rates ~= CHUNK / (sw.peek.total!"usecs" / 1e6);
                game ~= cast(double)(sleeps - before) / CHUNK;
            }
            d.note(format("FPS %s: %s; mean %.1f, min %.1f", where, rates.map!(r => format("%.1f", r)).join(" "),
                          rates.sum / rates.length, rates.fold!min));
            d.note(format("GAME %s: HuPrcVSleep calls per VI %s; mean %.3f", where,
                          game.map!(r => format("%.2f", r)).join(" "), game.sum / game.length));
            return rates;
        }

        setUp(STATE_CHILLY_TURN_1);
        waitForBoard();
        players.each!(p => p.data.flags = p.data.flags | 1);
        d.wait(30);
        measure(3, "board, limiter off");
        d.setSpeedLimiter(true);
        d.wait(30);
        measure(3, "board, limiter on");
        d.setSpeedLimiter(false);
        auto start = d.frame;
        d.waitUntil(() {
            if (isBoardScene()) {
                foreach (p; players) {
                    p.data.color = PanelColor.BLUE;
                    p.panel.color = PanelColor.BLUE;
                }
            }
            auto button = data.currentScene == Scene.MINI_GAME_RULES ? Pad.START : Pad.A;
            d.hold(0, !isBoardScene() && (d.frame - start) % 90 < 10 ? button : 0);
            return data.currentScene == Scene.FRIGID_BRIDGES;
        }, "Frigid Bridges to start", 60 * 60 * 15);
        d.release(0);
        d.wait(CHUNK);
        measure(4, "Frigid Bridges, limiter off");
        d.setSpeedLimiter(true);
        d.wait(30);
        measure(8, "Frigid Bridges, limiter on");
        d.setSpeedLimiter(false);
        d.check(data.currentScene == Scene.FRIGID_BRIDGES, "Left Frigid Bridges while measuring: " ~ data.currentScene.to!string);
    }
}
