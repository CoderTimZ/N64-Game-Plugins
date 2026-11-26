// Test driver for the game plugins, compiled only into the test builds (the "TestDriver" version, see dub.json).
//
// A test is a function that runs as a fiber: it runs during the game's frames, waiting for the game between steps
// (wait(), waitUntil()), and can read and write the game's memory, press buttons, load and save emulator states and
// take screenshots. Results go to the log file named by the N64TEST_LOG environment variable, and the emulator stops
// when the tests end (run RMG with --quit-after-emulation so it quits too).
module me.timz.n64.testdriver;

version (TestDriver):

import me.timz.n64.game;
import core.sys.windows.windows;
import core.thread;
import std.algorithm;
import std.array;
import std.conv;
import std.datetime.stopwatch;
import std.datetime.systime : SysTime;
import core.time : Duration, msecs;
import std.file;
import std.format;
import std.path;
import std.process : environment;
import std.range : take;
import std.stdio;
import std.string;

// Controller buttons as the emulator passes them to onInput() (mupen64plus's BUTTONS layout, not the N64's own)
enum Pad : ushort {
    RIGHT = 0x0001, LEFT = 0x0002, DOWN = 0x0004, UP = 0x0008, START = 0x0010, Z = 0x0020, B = 0x0040, A = 0x0080,
    C_RIGHT = 0x0100, C_LEFT = 0x0200, C_DOWN = 0x0400, C_UP = 0x0800, R = 0x1000, L = 0x2000
}

class TestFailure : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) { super(msg, file, line); }
}

// A test: its name and the function that runs it
struct Test {
    string name;
    void delegate() run;
    ulong timeoutFrames = 60 * 60 * 10; // 10 minutes of game time
}

final class TestDriver {
    Test[] tests;
    ulong frame;             // Frames since the driver started
    private Fiber fiber;
    private File log;
    private size_t current;  // Index of the running test
    private ulong testStart; // Frame the running test started on
    private int passed, failed;
    private string[] failures;
    private bool finished;
    private StopWatch clock;
    private Duration testClock; // When the running test started

    string arg;              // N64TEST_ARG: an argument for the tests (like which case to run)

    // Buttons to hold on each controller port (null: leave the input alone), and frames left to hold them
    InputData[4] heldInput;
    bool[4] holding;

    this(Test[] tests) {
        this.tests = tests;
        auto path = environment.get("N64TEST_LOG", "test.log");
        log = File(path, "w");
        auto only = environment.get("N64TEST", "");
        if (!only.empty) {
            auto names = only.split(",");
            this.tests = tests.filter!(t => names.canFind(t.name)).array;
            if (this.tests.empty) note("No tests match N64TEST=", only);
        }
        arg = environment.get("N64TEST_ARG", "");
        clock.start();
        note("Tests: ", this.tests.map!(t => t.name).join(", "));
    }

    // Writes a line to the log (and the emulator's log)
    void note(T...)(T args) {
        auto line = format("[%6d] ", frame) ~ text(args);
        log.writeln(line);
        log.flush();
        info(line);
    }

    // Call from the plugin's onFrame()
    void onFrame() {
        frame++;
        // A heartbeat for test\send-command.ps1, which reports the emulator stalled if it stops changing
        if (frame % 60 == 0) {
            import std.file : write;
            try write("TestCommands/heartbeat.txt", frame.to!string); catch (Exception) {}
        }
        if (finished) return;
        if (frame == 1) unlimitSpeed();

        if (!fiber) {
            if (current >= tests.length) return finish();
            auto test = tests[current];
            note("START ", test.name);
            testStart = frame;
            testClock = clock.peek;
            holding[] = false;
            fiber = new Fiber({ test.run(); }, 1024 * 1024);
        }

        try {
            fiber.call();
            if (fiber.state == Fiber.State.TERM) {
                pass();
            } else if (frame - testStart > tests[current].timeoutFrames) {
                fail("Timed out after " ~ (frame - testStart).to!string ~ " frames");
            }
        } catch (TestFailure e) {
            fail(e.msg);
        } catch (Throwable e) {
            fail(e.classinfo.name ~ ": " ~ e.msg ~ " (" ~ e.file ~ ":" ~ e.line.to!string ~ ")");
        }
    }

    // Call from the plugin's onInput()
    void onInput(int port, InputData* input) {
        if (port >= 0 && port < 4) inputPolls[port]++;
        if (port >= 0 && port < 4 && holding[port]) *input = heldInput[port];
    }

    ulong[4] inputPolls; // How many times the game has read each controller

    private void pass() {
        note("PASS ", tests[current].name, " (", frame - testStart, " frames)");
        passed++;
        next();
    }

    private void fail(string reason) {
        note("FAIL ", tests[current].name, ": ", reason);
        command(Command.TAKE_NEXT_SCREENSHOT, 0, null);
        note("SCREENSHOT at the failure");
        failures ~= tests[current].name ~ ": " ~ reason;
        failed++;
        next();
    }

    private void next() {
        auto seconds = (clock.peek - testClock).total!"msecs" / 1000.0;
        note(format!"  %.0f frames per second; hooks at %d addresses, %d calls in progress, %d fibers, %d once-hooks"(
            (frame - testStart) / max(seconds, 0.001), hooks.hooked[0].length, hooks.calls.length, hookFibers.length,
            hooks.execOnce.length + hooks.execDoneOnce.length));
        fiber = null;
        current++;
    }

    private void finish() {
        finished = true;
        note("DONE ", passed, " passed, ", failed, " failed, in ", clock.peek.total!"seconds", " s");
        note("Hook runs: ", hookRun, ", ", hookRun / max(frame, 1), " per frame");
        auto total = profileTicks.byValue.sum;
        note(format!"Time in hooks: %.0f us per frame"(total / 10.0 / max(frame, 1)));
        foreach (a; profileTicks.keys.sort!((x, y) => profileTicks[x] > profileTicks[y]).take(12)) {
            note(format!"  %08X: %.1f us per frame, %d runs"(a, profileTicks[a] / 10.0 / max(frame, 1), profileRuns[a]));
        }
        failures.each!(f => note("  FAILED ", f));
        stopEmulation();
    }

    // --- For tests ---

    // Waits for a number of frames
    void wait(ulong frames = 1) {
        foreach (i; 0..frames) Fiber.yield();
    }

    // Waits until a condition holds (checked once a frame), failing after a number of frames
    void waitUntil(bool delegate() condition, string what, ulong maxFrames = 60 * 60 * 5) {
        auto start = frame;
        while (!condition()) {
            if (frame - start > maxFrames) throw new TestFailure("Timed out waiting for " ~ what);
            Fiber.yield();
        }
    }

    void check(bool condition, lazy string message, string file = __FILE__, size_t line = __LINE__) {
        if (!condition) throw new TestFailure(message ~ " (" ~ baseName(file) ~ ":" ~ line.to!string ~ ")");
    }

    // Holds buttons on a port until release(), or for a number of frames
    void hold(int port, ushort buttons, byte x = 0, byte y = 0) {
        // The stick's X is the third byte and Y the fourth (InputData names them the other way around)
        heldInput[port].value = buttons | (cast(uint)cast(ubyte)x << 16) | (cast(uint)cast(ubyte)y << 24);
        holding[port] = true;
    }

    void release(int port) {
        holding[port] = false;
    }

    // Presses and releases buttons on a port
    void press(int port, ushort buttons, ulong frames = 3) {
        hold(port, buttons);
        wait(frames);
        hold(port, 0);
        wait(frames);
        release(port);
    }

    // --- The emulator core (mupen64plus's CoreDoCommand) ---

    enum Command { NOP = 0, STOP = 6, PAUSE = 7, RESUME = 8, STATE_LOAD = 10, STATE_SAVE = 11, TAKE_NEXT_SCREENSHOT = 16,
                   CORE_STATE_SET = 17 }
    enum CoreParam { SPEED_LIMITER = 5 }

    // Found on the emulator's thread and shared: coreHandle, like other module variables in D, is per thread, so the
    // thread in waitForCommand() can't look it up itself
    alias DoCommand = extern (C) int function(int, int, void*);
    private __gshared DoCommand doCommand;

    private int command(Command cmd, int paramInt, void* paramPtr) {
        if (!doCommand) doCommand = cast(DoCommand)GetProcAddress(cast(HMODULE)coreHandle, "CoreDoCommand");
        if (!doCommand) {
            note("Can't find CoreDoCommand");
            return -1;
        }
        return doCommand(cmd, paramInt, paramPtr);
    }

    void unlimitSpeed() {
        setSpeedLimiter(false);
    }

    // Tests run with the speed limiter off (see onFrame()); a test that measures the frame rate can turn it back on
    void setSpeedLimiter(bool on) {
        int value = on;
        command(Command.CORE_STATE_SET, CoreParam.SPEED_LIMITER, &value);
    }

    // Loads an emulator state file (it takes effect at the end of the frame), and waits for it
    void loadEmulatorState(string path) {
        check(exists(path), "No state file " ~ path);
        auto p = path.toStringz;
        check(command(Command.STATE_LOAD, 0, cast(void*)p) == 0, "Couldn't load " ~ path);
        wait(5);
        note("Loaded ", path);
    }

    // Saves an emulator state file (mupen64plus format)
    void saveEmulatorState(string path) {
        auto p = path.toStringz;
        check(command(Command.STATE_SAVE, 1, cast(void*)p) == 0, "Couldn't save " ~ path);
        wait(5);
        note("Saved ", path);
    }

    // Takes a screenshot (into the emulator's screenshot folder) after the next frame, and logs its file
    void screenshot(string label) {
        command(Command.TAKE_NEXT_SCREENSHOT, 0, null);
        wait(3);
        string newest;
        SysTime newestTime;
        if (exists("Screenshots")) {
            foreach (e; dirEntries("Screenshots", "*.png", SpanMode.shallow)) {
                if (e.timeLastModified > newestTime) {
                    newestTime = e.timeLastModified;
                    newest = e.name;
                }
            }
        }
        note("SCREENSHOT ", label, ": ", newest.empty ? "?" : absolutePath(newest));
    }

    // Pauses the emulator until a command file changes (written by test/send-command.ps1), then returns its text.
    // A thread watches the file and resumes the emulator; the game doesn't run while it waits.
    string waitForCommand(string file) {
        import core.atomic : atomicLoad, atomicStore;
        import std.datetime.systime : SysTime;

        auto lastChange = exists(file) ? timeLastModified(file) : SysTime.init;
        shared bool resumed;
        auto watcher = new Thread({
            while (true) {
                auto changed = exists(file) && timeLastModified(file) != lastChange;
                if (changed) {
                    // Keep resuming until the driver runs again: a pause asked for just before can take effect late
                    while (!atomicLoad(resumed)) {
                        command(Command.RESUME, 0, null);
                        Thread.sleep(50.msecs);
                    }
                    return;
                }
                Thread.sleep(100.msecs);
            }
        });
        command(Command.NOP, 0, null); // Looks CoreDoCommand up on this thread first
        watcher.isDaemon = true;
        watcher.start();
        command(Command.PAUSE, 0, null);
        while (!(exists(file) && timeLastModified(file) != lastChange)) wait();
        atomicStore(resumed, true);
        wait(2); // In case the file is still being written
        return readText(file);
    }

    void stopEmulation() {
        command(Command.STOP, 0, null);
    }
}

// Hooks for tests: any delegate (a test build doesn't roll back, so closures are fine here; the games' own hooks are
// methods, see game.d)
void onExec(Address address, void delegate(Address) callback) { addHandler(hooks.exec, HookKind.EXECUTE, address, ExecHandler([callback.ptr, callback.funcptr], callback)); }
void onExec(Address address, void delegate() callback) { onExec(address, (Address) { callback(); }); }
void onExecOnce(Address address, void delegate(Address) callback) { addHandler(hooks.execOnce, HookKind.EXECUTE, address, ExecHandler([null, null], callback)); }
void onExecOnce(Address address, void delegate() callback) { onExecOnce(address, (Address) { callback(); }); }
void onExecDone(Address address, void delegate(Address) callback) { addHandler(hooks.execDone, HookKind.EXECUTE, address, ExecHandler([callback.ptr, callback.funcptr], callback)); }
void onExecDone(Address address, void delegate() callback) { onExecDone(address, (Address) { callback(); }); }
void onExecDoneOnce(Address address, void delegate(Address) callback) { addHandler(hooks.execDoneOnce, HookKind.EXECUTE, address, ExecHandler([null, null], callback)); }
void onExecDoneOnce(Address address, void delegate() callback) { onExecDoneOnce(address, (Address) { callback(); }); }
void clearExec(Address address) { removeHandlers(hooks.exec, HookKind.EXECUTE, address); }
// Removes a test's hook (only that one: the plugin's own at the address stay)
void removeExec(Address address, void delegate(Address) callback) { removeHandlers(hooks.exec, HookKind.EXECUTE, address, [callback.ptr, callback.funcptr]); }
void removeExecDone(Address address, void delegate(Address) callback) { removeHandlers(hooks.execDone, HookKind.EXECUTE, address, [callback.ptr, callback.funcptr]); }

void onRead(T)(ref T field, void delegate() callback)               { onRead!T(field, (ref T v, Address p, Address a) { callback(); }); }
void onRead(T)(ref T field, void delegate(ref T) callback)          { onRead!T(field, (ref T v, Address p, Address a) { callback(v); }); }
void onRead(T)(ref T field, void delegate(ref T, Address) callback) { onRead!T(field, (ref T v, Address p, Address a) { callback(v, p); }); }
void onRead(T)(ref T field, void delegate(ref T, Address, Address) callback) {
    addHandler(hooks.read[sizeIndex(T.sizeof)], HookKind.READ, field.addr,
               MemHandler([null, null], (void* v, Address p, Address a) { callback(*cast(T*)v, p, a); }));
}

void onWrite(T)(ref T field, void delegate() callback)               { onWrite!T(field, (ref T v, Address p, Address a) { callback(); }); }
void onWrite(T)(ref T field, void delegate(ref T) callback)          { onWrite!T(field, (ref T v, Address p, Address a) { callback(v); }); }
void onWrite(T)(ref T field, void delegate(ref T, Address) callback) { onWrite!T(field, (ref T v, Address p, Address a) { callback(v, p); }); }
void onWrite(T)(ref T field, void delegate(ref T, Address, Address) callback) {
    addHandler(hooks.write[sizeIndex(T.sizeof)], HookKind.WRITE, field.addr,
               MemHandler([null, null], (void* v, Address p, Address a) { callback(*cast(T*)v, p, a); }));
}

// Calls a game function from a hook and then the callback with its result, with the registers put back as they were
// (for tests of the jump mechanism: the games call the game with callGame())
void jal(Address addr, uint a0 = 0, uint a1 = 0, uint a2 = 0, uint a3 = 0, void delegate(uint) callback = null) {
    GPR g = *gpr;
    FPR f = *fpr;
    gpr.ra = pc();
    gpr.a0 = a0;
    gpr.a1 = a1;
    gpr.a2 = a2;
    gpr.a3 = a3;
    jump(addr);
    gpr.ra.onExecOnce({
        uint v0 = gpr.v0;
        *gpr = g;
        *fpr = f;
        if (callback) callback(v0);
    });
}
void jal(Address addr, void delegate(uint) callback) { jal(addr, 0, 0, 0, 0, callback); }
void jal(Address addr, uint a0, void delegate(uint) callback) { jal(addr, a0, 0, 0, 0, callback); }
void jal(Address addr, uint a0, uint a1, void delegate(uint) callback) { jal(addr, a0, a1, 0, 0, callback); }
void jal(Address addr, void delegate() callback) { jal(addr, 0, 0, 0, 0, (uint) { callback(); }); }
void jal(Address addr, uint a0, void delegate() callback) { jal(addr, a0, 0, 0, 0, (uint) { callback(); }); }
