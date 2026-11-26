// The execution plugin's side of the emulator: the N64's memory and registers, the hooks the emulator calls the plugin
// for (which can wait for the game, like for a game function they call), netplay, and the functions the emulator calls
// (the exports at the end). The game classes are in game.d.
module me.timz.n64.plugin;

import core.sys.windows.windows;
import core.sys.windows.dll;
import core.sync.mutex;
import core.thread.fiber;
import std.algorithm;
import std.conv;
import std.json;
import std.range;
import std.stdio;
import std.string;
import std.traits;

public import me.timz.n64.util;

alias Address     = uint;
alias Instruction = uint;

enum Instruction NOP = 0;

// --- The N64's memory ---

// The emulator keeps memory as 32-bit words in the host's byte order, so a byte or a halfword is at its address with
// the low bits flipped
size_t swapAddrEndian(T)(size_t address) pure nothrow @nogc @safe {
    static if (T.sizeof == 1) return address ^ 0b11;
    else static if (T.sizeof == 2) return address ^ 0b10;
    else return address;
}

T* swapAddrEndian(T)(T* ptr) pure nothrow @nogc {
    return cast(T*)swapAddrEndian!T(cast(size_t)ptr);
}

// The N64 address of a field in memory (like data.currentScene.addr)
Address addr(T)(ref T v) {
    return cast(Address)swapAddrEndian!T(cast(ubyte*)&v - memory.ptr) + 0x80000000;
}

ref T val(T)(Address address) {
    return *Ptr!T(address);
}

// A pointer in the N64's memory, as the game keeps it
struct Ptr(T) {
    Address address;

    this(Address a) { address = a; }
    ref Ptr!T opAssign(Address a) { address = a; return this; }
    ref T opIndex(size_t i) { return *Ptr!T(address + cast(int)(i * T.sizeof)); }
    ref T opUnary(string op)() if (op == "*") { return *swapAddrEndian(cast(T*)&memory[address - 0x80000000]); }
    ref Ptr!T opUnary(string op)() if (op == "++") { address += T.sizeof; return this; }
    ref Ptr!T opUnary(string op)() if (op == "--") { address -= T.sizeof; return this; }
    T opCast(T)() const if (is(T == bool)) { return 0x80000000 <= address && address < 0x80800000; }

    alias address this;
}

// An array in the N64's memory
align (1) struct Arr(T, size_t S = 0) {
    T front;

    @property size_t length() const { return S; }
    @property bool empty() const { return S == 0; }
    ref T opIndex(size_t i) { return *swapAddrEndian(swapAddrEndian(&front) + i); }

    int opApply(scope int delegate(ref T) dg) {
        foreach (i; 0..S) {
            if (int result = dg(this[i])) return result;
        }
        return 0;
    }
}

// A field of a struct in the N64's memory, at its offset (structs are unions of these)
mixin template Field(Address A, T, string N) {
    align (1) struct {
        ubyte[swapAddrEndian!T(A) & 0x7FFFFF] _pad;
        mixin("T " ~ N ~ ";");
    }
}

// Whether an address and the bytes after it are in the N64's memory (and the address is word-aligned)
bool inMemory(Address address, size_t size) {
    return address >= 0x80000000 && address % 4 == 0 && address - 0x80000000 + size <= memory.length;
}

// Tells the emulator that the code at the address changed: its cached interpreter (and dynarec) would keep running the
// instructions it already decoded otherwise. The game's own writes do that by themselves, the plugin's don't. Does
// nothing in an emulator without ExecutionInvalidateCode (it doesn't cache code, or the change isn't seen).
void invalidateCode(Address address, uint size = 4) {
    if (invalidateCodeFunction) invalidateCodeFunction(address, size);
}

// Changes an instruction (or any word the CPU runs or decodes as code)
void setCode(Address address, Instruction instruction) {
    if (address.val!Instruction == instruction) return;
    address.val!Instruction = instruction;
    invalidateCode(address);
}

Address[] searchMemory(immutable uint[] data) {
    auto mem = (cast(uint*)memory.ptr)[0..memory.length / uint.sizeof];
    Address[] result;
    ptrdiff_t start = 0, index;
    while (start < mem.length && (index = mem[start..$].countUntil(data)) != -1) {
        result ~= cast(Address)(0x80000000 + (start + index) * uint.sizeof);
        start += index + 1;
    }
    return result;
}

// --- The CPU's registers ---

union Register(T) if (T.sizeof == 4) {
    ulong v;
    struct { T l, h; }
    @property ref U value(U)()  if (U.sizeof == 8) { return *cast(U*)&v; }
    @property ref U lo(U = T)() if (U.sizeof == 4) { return *cast(U*)&l; }
    @property ref U hi(U = T)() if (U.sizeof == 4) { return *cast(U*)&h; }
    // A 32-bit integer is kept sign-extended to 64 bits, as the CPU's 32-bit instructions leave it: branches like BGEZ
    // read all 64 bits, so a positive value over a negative one would still look negative
    ref T opAssign(T rhs) {
        static if (__traits(isIntegral, T)) v = cast(long)cast(int)rhs;
        else l = rhs;
        return l;
    }
    ref T opOpAssign(string op)(T rhs) { return opAssign(mixin("l " ~ op ~ " rhs")); }
    alias l this;
}

union GPR {
    Register!uint[32] r;

    struct {
        Register!uint r0, at, v0, v1, a0, a1, a2, a3,
                      t0, t1, t2, t3, t4, t5, t6, t7,
                      s0, s1, s2, s3, s4, s5, s6, s7,
                      t8, t9, k0, k1, gp, sp, fp, ra;
    }
}

union FPR {
    Register!float[32] r;

    struct {
        Register!float f0,  f1,  f2,  f3,  f4,  f5,  f6,  f7,
                       f8,  f9,  f10, f11, f12, f13, f14, f15,
                       f16, f17, f18, f19, f20, f21, f22, f23,
                       f24, f25, f26, f27, f28, f29, f30, f31;
    }
}

// The index of a register by its name (for options that name the register a game keeps a value in)
int registerIndex(string name)() {
    static immutable names = ["r0", "at", "v0", "v1", "a0", "a1", "a2", "a3", "t0", "t1", "t2", "t3", "t4", "t5",
                              "t6", "t7", "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "t8", "t9", "k0", "k1",
                              "gp", "sp", "fp", "ra"];
    enum i = names.countUntil(name);
    static assert(i >= 0, "No register " ~ name);
    return cast(int)i;
}

// --- Controllers ---

enum Button : ushort {
    C_R = 0x0001,
    C_L = 0x0002,
    C_D = 0x0004,
    C_U = 0x0008,
    R   = 0x0010,
    L   = 0x0020,
    D_R = 0x0100,
    D_L = 0x0200,
    D_D = 0x0400,
    D_U = 0x0800,
    S   = 0x1000,
    Z   = 0x2000,
    B   = 0x4000,
    A   = 0x8000
}

union InputData {
    struct {
        ushort buttons;
        byte analogY;
        byte analogX;
    }

    uint value;

    alias value this;
}

// --- Logging ---

enum MsgLevel { ERROR = 1, WARNING = 2, INFO = 3, STATUS = 4, VERBOSE = 5 }

void info(T...)(T args)    { msg(MsgLevel.INFO, args); }
void warning(T...)(T args) { msg(MsgLevel.WARNING, args); }
void error(T...)(T args)   { msg(MsgLevel.ERROR, args); }

void msg(T...)(MsgLevel level, T args) {
    string message;
    foreach (arg; args) message ~= arg.to!string;

    version (Windows) { } else {
        (level <= MsgLevel.WARNING ? stderr : stdout).writeln(message);
    }
    if (!debugCallback) return;
    // (during netplay once the frame is final: a rollback mustn't log the same thing twice)
    auto callback = debugCallback;
    auto context = debugContext.toStringz;
    afterFinal({ callback(context, level, message.toStringz); });
}

// Shows an error to the player: a message box on Windows. (It's in the emulator's log everywhere.)
void showError(const(char)[] title, const(char)[] message) {
    version (Windows) {
        MessageBoxA(window, message.toStringz, title.toStringz, MB_ICONEXCLAMATION);
    }
}

// --- Hooks ---

// What the emulator calls the plugin for (m64p_execution_hook in its m64p_plugin.h)
enum HookKind : int { EXECUTE, READ, WRITE } // EXECUTE has Execute() and ExecuteDone()

// A hook's handler, and what it was made from (to remove it again: see unhook())
struct Handler(F) {
    const(void)*[2] key;
    F run;
}
alias ExecHandler = Handler!(void delegate(Address pc));
alias MemHandler  = Handler!(void delegate(void* value, Address pc, Address address));

// Every hook, and where the waiting hooks and game calls wait. Rollback keeps a copy of it with each frame it saves
// (the same copy for frames that didn't change it: see hooksVersion).
struct Hooks {
    ExecHandler[][Address] exec, execOnce, execDone, execDoneOnce;
    MemHandler[][Address][4] read, write; // By size: 1, 2, 4 and 8 bytes
    // The emulator has a bit per word of RDRAM for each kind of hook, which addresses that agree in bits 2..22 share (a
    // KSEG0 address and its KSEG1 mirror, or the bytes of a word). These count the hooked addresses on each, so the bit
    // is turned off only once none is left.
    uint[uint][3] hooked;
    HookReturn[] returns;
    GameCall[] calls; // In progress (see callGame())
    ulong serial;     // Numbers the waits in the order they start (see Execute)

    Hooks dup() {
        Hooks h;
        static foreach (i; 0 .. Hooks.tupleof.length) {
            static if (isStaticArray!(typeof(h.tupleof[i]))) {
                foreach (k, ref e; h.tupleof[i]) e = this.tupleof[i][k].dup;
            } else static if (isScalarType!(typeof(h.tupleof[i]))) {
                h.tupleof[i] = this.tupleof[i];
            } else {
                h.tupleof[i] = this.tupleof[i].dup;
            }
        }
        return h;
    }
}

int sizeIndex(size_t size) { return size == 1 ? 0 : size == 2 ? 1 : size == 4 ? 2 : 3; }

uint hookedWord(Address addr) { return (addr >> 2) & 0x1FFFFF; }

void hookAdded(HookKind kind, Address addr) {
    if (hooks.hooked[kind].require(hookedWord(addr), 0)++ == 0) setHook(addr, kind, 1);
    hooksVersion++;
}

void hookRemoved(HookKind kind, Address addr) {
    auto word = hookedWord(addr);
    auto count = word in hooks.hooked[kind];
    if (count && --*count == 0) {
        hooks.hooked[kind].remove(word);
        setHook(addr, kind, 0);
    }
    hooksVersion++;
}

// Adds a handler for an address, turning on its hook if it's the address's first
void addHandler(H)(ref H[][Address] table, HookKind kind, Address addr, H handler) {
    if (addr !in table) hookAdded(kind, addr);
    table[addr] ~= handler;
    hooksVersion++;
}

// Removes an address's handlers made from a key (or all of them), turning off its hook if none is left
void removeHandlers(H)(ref H[][Address] table, HookKind kind, Address addr, const(void)*[2] key = [null, null]) {
    auto handlers = addr in table;
    if (!handlers) return;
    auto left = key == [null, null] ? null : (*handlers).filter!(h => h.key != key).array;
    if (left.length) {
        *handlers = left;
    } else {
        table.remove(addr);
        hookRemoved(kind, addr);
    }
    hooksVersion++;
}

// A method as the handlers the tables keep: Execute and ExecuteDone hooks take () or (Address pc), Read and Write hooks
// (ref T value), optionally with (Address pc, Address address) after it
ExecHandler execHandler(D)(D method) {
    static if (Parameters!D.length == 0) auto run = (Address pc) { method(); };
    else auto run = method;
    return ExecHandler([method.ptr, method.funcptr], run);
}

MemHandler memHandler(T, D)(D method) {
    enum n = Parameters!D.length;
    return MemHandler([method.ptr, method.funcptr], (void* v, Address pc, Address address) {
        static if (n == 1) method(*cast(T*)v);
        else static if (n == 2) method(*cast(T*)v, pc);
        else method(*cast(T*)v, pc, address);
    });
}

void runHandlers(H, Args...)(H[] handlers, Args args) {
    foreach (h; handlers) {
        try { h.run(args); }
        catch (Exception e) { error(e); }
    }
}

// --- Hooks that wait for the game ---

// Execute and ExecuteDone hooks run on fibers (kept and used again), so a hook can wait for the game partway through,
// briefly: for a game function it calls (callGame()), or for the game to get somewhere (waitExec()). It goes on from
// there when the game gets there. Where it was is on the fiber's stack (the return address, its local variables) and in
// the fiber's saved stack pointer, so rollback saves a waiting hook by copying the used part of its stack and the
// fiber's few fields (see saveFibers()). Its local variables should be values (numbers, structs of them) or immutable:
// what a reference points to isn't saved. A save state can't hold it, so a save waits until no hook waits.
final class HookFiber : Fiber {
    uint index;
    ExecHandler handler; // What it runs, and for which address
    Address pc;
    uint result;         // The game call's it waits for (see callGame())
    Address waitingFor;  // (for the warning in Frame)
    ulong since;         // The frame it started waiting in

    this(uint index) { super(&run, 64 * 1024); this.index = index; }

    void run() {
        if (!handler.run) return;
        try { handler.run(pc); }
        catch (Exception e) { error(e); }
    }
}

// Runs a hook's handler on a fiber that isn't waiting
void runHook(ExecHandler handler, Address pc) {
    uint index = 0;
    while (index < hookFibers.length && hookFibers[index].state != Fiber.State.TERM) index++;
    if (index == hookFibers.length) hookFibers ~= new HookFiber(index);
    auto fiber = hookFibers[index];
    if (fiber.state == Fiber.State.TERM) fiber.reset();
    fiber.handler = handler;
    fiber.pc = pc;
    resumeFiber(fiber);
    if (fiber.state == Fiber.State.TERM) fiber.handler = ExecHandler.init;
}

void runHooks(ExecHandler[] handlers, Address pc) {
    foreach (h; handlers) runHook(h, pc);
}

void resumeFiber(HookFiber fiber) {
    try { fiber.call(); }
    catch (Throwable t) { error("A hook failed: ", t); }
}

// Ends a waiting hook (what it waited for won't come)
void endFiber(HookFiber fiber) {
    if (fiber.state == Fiber.State.TERM) return;
    fiber.handler = ExecHandler.init;
    fiber.reset();
    fiber.call();
}

HookFiber currentFiber(string what) {
    auto fiber = cast(HookFiber)Fiber.getThis();
    if (!fiber) throw new Exception(what ~ " is only for Execute and ExecuteDone hooks");
    return fiber;
}

// --- Calling the game ---
//
// A hook calls a game function and waits for it on its fiber (callGame()), which is quick: the function returns in
// microseconds, and a save state waits until no hook waits (see StateSaving). A call that waits for the game itself
// (for frames, input, a message to load) is started with startCall() instead, and what comes after it is a method
// that runs when it returns (then!m in game.d), kept as data: a save state made in the middle has it, and loading it
// carries on from there. afterReturn!m does the same for a function the game called (a hook at its start).
// A hook that waits for longer than a frame is logged (see warnLongWaits()): it puts save states off.

// Calls a game function from a hook and returns its result (v0), with the registers put back as they were. For
// functions that return at once; one that waits for the game needs startCall(). The game can run one call at a time
// from a run of the hooks: a hook that calls while another call from the same run hasn't returned waits for it first.
uint callGame(Args...)(Address function_, Args args) {
    auto fiber = currentFiber("callGame()");
    waitTurn(fiber);
    auto call = setUpCall(function_, args);
    call.fiber = cast(int)fiber.index;
    addCall(call);
    jump(function_);
    fiber.waitingFor = function_;
    fiber.since = frame;
    Fiber.yield();
    return fiber.result;
}

// Starts a call of a game function that waits for the game: the hook goes on (and should end), and the game runs the
// function. What comes after it is its .then!m (see game.d), which runs when it returns.
ref GameCall startCall(Args...)(Address function_, Args args) {
    waitTurn(currentFiber("startCall()"));
    addCall(setUpCall(function_, args));
    jump(function_);
    return hooks.calls[$ - 1];
}

// Runs `next` when the function the game is in returns (from a hook at its first instruction: to gpr.ra, with the
// stack pointer and the registers a function keeps as they are now). See afterReturn!m in game.d.
void waitForReturn(Then next) {
    addCall(GameCall(gpr.ra, gpr.sp, *gpr, *fpr, 0, false, next));
}

// (one call at a time from a run of the hooks: see callGame())
void waitTurn(HookFiber fiber) {
    while (true) {
        auto running = hooks.calls.find!(c => c.run == hookRun && c.function_);
        if (running.empty) return;
        running.front.queued ~= Resume(cast(int)fiber.index);
        hooksVersion++;
        fiber.waitingFor = running.front.function_;
        fiber.since = frame;
        Fiber.yield();
    }
}

// A call's return address and arguments: the first 4 in a0..a3, the others on the stack, after the 16 bytes the
// function may keep a0..a3 in (as the game's own calls pass them). The registers to put back are the ones before.
GameCall setUpCall(Args...)(Address function_, Args args) {
    static assert(Args.length <= 8, "A game call takes up to 8 arguments");
    GPR g = *gpr;
    FPR f = *fpr;
    Address returnTo = pc();
    static if (Args.length > 4) gpr.sp -= (16 + 4 * (Args.length - 4) + 7) & ~7;
    gpr.ra = returnTo;
    static foreach (i; 0 .. Args.length) {
        static if (i < 4) gpr.r[4 + i] = cast(uint)args[i];
        else (gpr.sp + cast(uint)(16 + 4 * (i - 4))).val!uint = cast(uint)args[i];
    }
    return GameCall(returnTo, gpr.sp, g, f, function_, returnTo == executing);
}

void addCall(GameCall call) {
    call.run = hookRun;
    hooks.calls ~= call;
    hookAdded(HookKind.EXECUTE, call.at);
    if (plugin) plugin.onCallsChanged();
}

// What runs when a call returns, kept as data a save state can hold: a method, by its class's name and its own (see
// then!m in game.d), and its arguments' bytes
struct Then {
    string method;
    immutable(ubyte)[] args;
    bool opCast(T : bool)() const { return method.length > 0; }
}

__gshared void function(const ref Then, uint result) runThen; // (set by game.d)

// A hook, or a Then, that goes on when a call returns
struct Resume {
    int fiber = -1;
    Then next;
    uint result;
}

// A call in progress: one the plugin made (function_), or a function the game called that a hook waits for (0). When
// it returns to `at` (the stack pointer back at `sp`, and the registers a function keeps as they were), the plugin's
// call gets its registers put back, and what waits for it goes on: its hook (fiber, see callGame()) or its Then, then
// the ones queued behind it. The state block keeps these (see FrameworkState in game.d), and a save state waits while a
// hook waits on its fiber, so loading one carries on from where it was.
struct GameCall {
    Address at;
    uint sp;
    GPR gpr;
    FPR fpr;
    Address function_;
    bool revisit;     // It started in at's Execute hooks: the game was at `at` already, so they don't run again
    Then next;        // What runs when it returns (see startCall() and afterReturn!m)
    int fiber = -1;
    ulong run;        // The run of the hooks it started in (see hookRun)
    Resume[] queued;

    // Whether the game is back from it: at `at`, with the registers a function keeps (gp, sp, s0-s7, fp) as they were
    bool returned(Address pc) const {
        static immutable kept = [16, 17, 18, 19, 20, 21, 22, 23, 28, 30];
        if (pc != at || .gpr.sp != sp) return false;
        foreach (r; kept) if (.gpr.r[r].v != gpr.r[r].v) return false;
        return true;
    }
}

// The calls that returned here (see GameCall): taken, and the plugin's call gets its registers put back. Returns what
// goes on now, and whether one of them started in this address's hooks.
Resume[] returnFromCalls(Address pc, out bool revisit) {
    Resume[] resumes;
    foreach_reverse (i, c; hooks.calls) {
        if (!c.returned(pc)) continue;
        hooks.calls = hooks.calls.remove(i);
        hookRemoved(HookKind.EXECUTE, c.at);
        uint result = gpr.v0;
        if (c.function_) {
            *gpr = c.gpr;
            *fpr = c.fpr;
        }
        revisit |= c.revisit;
        resumes = Resume(c.fiber, c.next, result) ~ c.queued ~ resumes;
    }
    if (resumes.length && plugin) plugin.onCallsChanged();
    return resumes;
}

// Goes on with what waited for calls that returned, one at a time until one calls the game again (the rest wait for
// that call)
void resume(Resume[] resumes) {
    foreach (i, r; resumes) {
        if (r.fiber >= 0) {
            hookFibers[r.fiber].result = r.result;
            resumeFiber(hookFibers[r.fiber]);
        } else if (r.next) {
            auto next = r.next;
            auto result = r.result;
            runHook(ExecHandler([null, null], (Address pc) { runThen(next, result); }), pc());
        }
        auto running = hooks.calls.find!(c => c.run == hookRun && c.function_);
        if (!running.empty) {
            running.front.queued ~= resumes[i + 1 .. $];
            hooksVersion++;
            return;
        }
    }
}

// The calls a save state had in progress (see GameCall)
void restoreCalls(const GameCall[] calls) {
    foreach (c; calls) {
        auto call = GameCall(c.at, c.sp, c.gpr, c.fpr, c.function_, c.revisit, c.next);
        foreach (r; c.queued) if (r.next) call.queued ~= Resume(-1, r.next, r.result);
        hooks.calls ~= call;
        hookAdded(HookKind.EXECUTE, c.at);
    }
}

// --- Waiting for the game ---

// Where a hook waits for the game to get (see waitExec()), and which hook (its fiber)
struct HookReturn {
    Address at;
    uint fiber;
    ulong serial; // (see Hooks.serial)
}

// Waits in a hook until the game runs the instruction at an address (like a function returning to gpr.ra). For a
// wait that's over at once; one that lasts frames needs afterReturn (a save state waits while a hook waits).
void waitExec(Address address) {
    auto fiber = currentFiber("waitExec()");
    hooks.returns ~= HookReturn(address, fiber.index, hooks.serial++);
    hookAdded(HookKind.EXECUTE, address);
    fiber.waitingFor = address;
    fiber.since = frame;
    Fiber.yield();
}

// The hooks that started waiting at the address before a serial number (see Hooks.serial)
void resumeHooksAt(Address pc, ulong before) {
    HookFiber[] ready;
    foreach_reverse (i, r; hooks.returns) {
        if (r.at != pc || r.serial >= before) continue;
        ready = hookFibers[r.fiber] ~ ready;
        hooks.returns = hooks.returns.remove(i);
        hookRemoved(HookKind.EXECUTE, r.at);
    }
    foreach (fiber; ready) resumeFiber(fiber);
}

// Whether a hook waits on its fiber (which a save state can't hold)
bool hookWaiting() {
    return hookFibers.any!(f => f.state == Fiber.State.HOLD);
}

// A hook that has waited for more than a frame puts save states off: what it waits for needs startCall() or
// afterReturn!m. Logged once for each function or address it waits for.
void warnLongWaits() {
    foreach (f; hookFibers) {
        if (f.state != Fiber.State.HOLD || f.since + 2 > frame || f.waitingFor in warnedWaits) continue;
        warnedWaits[f.waitingFor] = true;
        warning(format!"A hook has waited %d frames for %08X, which puts save states off: it needs startCall() or %s"(
            frame - f.since, f.waitingFor, "afterReturn!m"));
    }
}

// Ends every waiting hook and call (a save state was loaded: what they waited for won't come)
void cancelWaits() {
    foreach (r; hooks.returns) hookRemoved(HookKind.EXECUTE, r.at);
    foreach (c; hooks.calls) hookRemoved(HookKind.EXECUTE, c.at);
    hooks.returns = null;
    hooks.calls = null;
    foreach (fiber; hookFibers) endFiber(fiber);
    hooksVersion++;
}

// A hook's fiber as it was: its own fields, its saved stack pointer and the used part of its stack
struct FiberState {
    void[] fields;
    void* tstack;
    void* ehContext;
    void[] stack;
}

// A fiber's fields are in Fiber's base class, which druntime doesn't make public: found by name
alias FiberBase = BaseClassesTuple!Fiber[0];

ref auto fiberField(string name)(Fiber f) {
    auto b = cast(FiberBase)f;
    static foreach (i; 0 .. FiberBase.tupleof.length) {
        static if (__traits(identifier, FiberBase.tupleof[i]) == name) return b.tupleof[i];
    }
}

FiberState[] saveFibers() {
    FiberState[] saved;
    foreach (f; hookFibers) {
        FiberState s;
        auto ctxt = fiberField!"m_ctxt"(f);
        // (the fields that change while it runs: the stack and its context stay where they are)
        s.fields = (cast(void*)f)[0 .. __traits(classInstanceSize, FiberBase)].dup;
        s.tstack = ctxt.tstack;
        s.ehContext = ctxt.ehContext;
        if (f.state == Fiber.State.HOLD) s.stack = ctxt.tstack[0 .. ctxt.bstack - ctxt.tstack].dup;
        saved ~= s;
    }
    return saved;
}

// The hooks' fibers as they were; ones made since are free
void restoreFibers(FiberState[] saved) {
    foreach (i, f; hookFibers) {
        if (i >= saved.length) {
            endFiber(f);
            continue;
        }
        auto s = &saved[i];
        auto ctxt = fiberField!"m_ctxt"(f);
        enum header = 2 * size_t.sizeof; // (the object's vtable and monitor)
        (cast(void*)f)[header .. s.fields.length] = s.fields[header .. $];
        ctxt.tstack = s.tstack;
        ctxt.ehContext = s.ehContext;
        if (s.stack.length) ctxt.tstack[0 .. s.stack.length] = s.stack[];
    }
}

// For tests: the time spent in each hooked address's hooks (ExecuteDone's address + 1, a memory hook's + 2, + 3 for a
// write), and how often they ran
version (TestDriver) {
    import core.time : MonoTime;
    __gshared long[Address] profileTicks;
    __gshared ulong[Address] profileRuns;
    __gshared uint profileDepth;

    struct Profiled {
        Address at;
        MonoTime start;
        this(Address at) { this.at = at; start = MonoTime.currTime; profileDepth++; }
        ~this() {
            if (--profileDepth) return; // (the outermost hook's time has the nested ones')
            profileTicks[at] += (MonoTime.currTime - start).total!"hnsecs";
            profileRuns[at]++;
        }
    }
}

// --- Netplay ---

// A netplay session's role (see NetplayStart)
enum NetplayRole { none, host, guest }

// Something that reaches outside the game (sending to a server, saving a state, logging). Outside netplay it's done
// now. During netplay it waits until the frame it comes from is final: a frame that isn't can be run again with
// different input after a rollback, which would do something else (the plugin forgets what the frames it goes back
// from planned, see NetplayLoadState). A final frame can be run again too, when a rollback goes back to a frame saved
// before it, but with the same input it does the same: what it planned was done the first time, so it's skipped.
void afterFinal(void delegate() effect) {
    if (netplayRole == NetplayRole.none) return effect();
    if (netplayFrame < effectsDoneBefore) return;
    synchronized (effectsLock) pendingEffects ~= PendingEffect(netplayFrame, effect);
}

struct PendingEffect {
    ulong frame;
    void delegate() effect;
}

// Does what the frames that are final now planned to do
void runFinalEffects() {
    PendingEffect[] ready;
    synchronized (effectsLock) {
        auto n = pendingEffects.countUntil!(e => e.frame >= netplayFinal);
        if (n < 0) n = pendingEffects.length;
        effectsDoneBefore = max(effectsDoneBefore, netplayFinal);
        ready = pendingEffects[0 .. n].dup;
        pendingEffects = pendingEffects[n .. $].dup;
    }
    foreach (ref e; ready) {
        try { e.effect(); } catch (Exception) { }
    }
}

// Forgets what the frame and the ones after it planned to do (they're run again)
void dropEffectsFrom(ulong frame) {
    synchronized (effectsLock) pendingEffects = pendingEffects.filter!(e => e.frame < frame).array;
}

// What the server sends reaches the game in one place, Plugin.onMessage(). Outside netplay that's at the frame it
// arrives. During netplay the speaker passes it to the core, which hands it to every machine's plugin at the same frame
// (NetplayMessage), so every game applies it at the same point.
void passOnServerMessage(string text) {
    if (netplayRole == NetplayRole.none) return applyServerMessage(text);
    if (!netplaySendFunction || !netplaySendFunction(text.ptr, cast(uint)text.length)) {
        warning("Netplay: couldn't pass a message from the server on to the other players");
    }
}

void applyServerMessage(string text) {
    if (!plugin) return;
    info("The server's message at frame ", netplayRole != NetplayRole.none ? netplayFrame : frame, ": ",
         text.length > 60 ? text[0..60] ~ "..." : text);
    try { plugin.onMessage(text); }
    catch (Exception e) { error(e); }
}

// A frame saved for rollback (see NetplaySaveState)
final class RollbackSave {
    Hooks* hooks;              // (the same copy for saves that didn't change them)
    FiberState[] fibers;       // The waiting hooks
    Object game;               // The game's state (see Plugin.saveRollback)
}

// --- The game ---

// What the exports call (Game in game.d)
interface Plugin {
    void onStart();
    void onInput(int port, InputData* data);
    void onFrame();
    void onMessage(string text);     // From the server (see passOnServerMessage)
    void onStateLoaded();            // A save state was loaded
    void onStateSaving();            // A save state is about to be made
    void onCallsChanged();           // A game call started or returned (see callGame())
    void onReset(bool hard);
    void onSpeakerChanged(bool speaker);
    void onFinish();
    string netplayExport();          // The settings, for the other players in a netplay session (see NetplayStart)
    Object saveRollback();           // Rollback: the game's state now, and back to it
    void loadRollback(Object saved);
    ulong stateHash();               // For the emulator's rollback self-test
}

struct ExecutionInfo {
    void* window;
    const char* romName;
    const char* romHash;
    extern (C) void function(uint, int, int) setHook;
    uint function() pc;
    void function(uint) jump;
    GPR* gpr;
    FPR* fpr;
    ubyte* memory;
    uint memorySize;
    void function() saveGameState;
    void function(int) setSaveStateSlot;
}

__gshared {
    // The emulator
    void* window;
    extern (C) void function(uint, int, int) setHook;           // Turns a hook on or off (see Hooks.hooked)
    extern (C) void function(uint, uint) invalidateCodeFunction; // The core's ExecutionInvalidateCode, if it has one
    uint function() pc;
    void function(uint) jump;
    GPR* gpr;
    FPR* fpr;
    ubyte[] memory;
    void function() saveGameState;
    void function(int) setSaveStateSlot;

    // The game
    Plugin plugin;
    Plugin function(string, string) pluginFactory; // (set with usePlugin() in game.d)
    const(char)* name;
    Hooks hooks;
    ulong hooksVersion; // Changes with the hooks (see Hooks)
    ulong hookRun;      // Counts the runs of the hooks at an address (Execute, ExecuteDone, and Frame)
    Address executing;  // The address whose Execute hooks run, or 0
    bool[Address] warnedWaits; // (see warnLongWaits())
    HookFiber[] hookFibers; // (kept, and used again)
    // State that isn't a game object's (the game saves it with its own: see Game.stateParts in game.d)
    Xoshiro256pp random;
    ulong frame;
    InputData[4] input;

    // Netplay (see NetplayStart and NetplayFrame): the role, the frame being emulated, the first one that isn't final,
    // whether this machine talks to the server for everyone, and who plays on each port
    NetplayRole netplayRole;
    ulong netplayFrame;
    ulong netplayFinal;
    bool netplaySpeaker;
    string[4] netplayNames;
    JSONValue netplayImport;   // The host's settings, on a guest
    string netplayExported;    // What NetplayExport handed out last (it has to stay valid)
    extern (C) int function(const(void)*, uint) netplaySendFunction; // The core's ExecutionNetplaySendMessage
    // what frames that aren't final yet will do outside the game (see afterFinal()), oldest first, and the frames
    // whose effects were done (they're final)
    PendingEffect[] pendingEffects;
    ulong effectsDoneBefore;
    Mutex effectsLock;
    // Rollback: the saved frames, and the last copy of the hooks (and their version then)
    RollbackSave[uint] rollbackSaves;
    Hooks* savedHooks;
    ulong savedHooksVersion;
}

shared static this() {
    effectsLock = new Mutex;
}

void resetNetplay(NetplayRole role) {
    netplayRole = role;
    netplayImport = JSONValue.init;
    netplayExported = null;
    netplayFrame = 0;
    netplayFinal = 0;
    effectsDoneBefore = 0;
    netplaySpeaker = false;
}

extern (C) {
    void* coreHandle;
    const(char)[] debugContext;
    void function(const char*, int, const char*) debugCallback;

    string getName();
    int startup();

    export int PluginStartup(void* handle, const char* context, void function(const char*, int, const char*) callback) {
        coreHandle = handle;
        debugContext = context ? fromStringz(context) : "[EXEC]  ";
        debugCallback = callback;

        T core(T)(string name) {
            version (Windows) return cast(T)GetProcAddress(cast(HMODULE)handle, name.toStringz);
            else {
                import core.sys.posix.dlfcn : dlsym;
                return cast(T)dlsym(handle, name.toStringz);
            }
        }
        invalidateCodeFunction = core!(typeof(invalidateCodeFunction))("ExecutionInvalidateCode");
        netplaySendFunction = core!(typeof(netplaySendFunction))("ExecutionNetplaySendMessage");

        return startup();
    }

    export int PluginShutdown() { return 0; }

    export int PluginGetVersion(int* pluginType, int* pluginVersion, int* apiVersion, const(char)** pluginNamePtr, int* pluginCapabilities) {
        if (pluginType) *pluginType = 5;
        if (pluginVersion) *pluginVersion = 0x020000;
        if (apiVersion) *apiVersion = 0x020000;
        if (pluginNamePtr) {
            name = getName().toStringz;
            *pluginNamePtr = name;
        }
        if (pluginCapabilities) *pluginCapabilities = 0;
        return 0;
    }

    export void RomOpen() { }

    export void RomClosed() {
        if (plugin) {
            try { plugin.onFinish(); }
            catch (Exception e) { error(e); }
            plugin = null;
        }

        // what final frames planned is done; the rest never happened
        runFinalEffects();
        synchronized (effectsLock) pendingEffects = null;
        rollbackSaves = null;
        savedHooks = null;
        resetNetplay(NetplayRole.none);
        netplayNames = netplayNames.init;
    }

    // Peer-to-peer netplay: every player needs the same settings, or their games drift apart. The emulator calls
    // NetplayStart before InitiateExecution. The host's plugin then starts as usual and NetplayExport hands its settings
    // over; each guest's plugin gets them with NetplayImport, before its InitiateExecution, and uses them instead of its
    // own file. Until RomClosed, only the speaker talks to the bingo server (see NetplayFrame).
    export void NetplayStart(int isHost) {
        resetNetplay(isHost ? NetplayRole.host : NetplayRole.guest);
        info(isHost ? "Netplay: hosting, sharing the settings with the other players"
                    : "Netplay: playing with the host's settings");
    }

    export int NetplayExport(const(void)** data, uint* size) {
        try {
            if (!plugin || !data || !size) return 1;
            netplayExported = plugin.netplayExport();
            *data = netplayExported.ptr;
            *size = cast(uint)netplayExported.length;
            return 0;
        } catch (Exception e) {
            error(e);
            return 1;
        }
    }

    export int NetplayImport(const(void)* data, uint size) {
        try {
            netplayImport = (cast(const(char)*)data)[0..size].idup.parseJSON();
            return 0;
        } catch (Exception e) {
            error(e);
            netplayImport = JSONValue.init;
            return 1;
        }
    }

    // Who plays on each port (the same on every machine), right after NetplayStart
    export void NetplayPlayers(const(char*)* names) {
        foreach (i; 0..4) netplayNames[i] = names && names[i] ? names[i].fromStringz.idup : "";
    }

    // The start of a frame during netplay: frames before `final_` are final, so what they planned to do outside the
    // game is done now (see afterFinal()). Whether this machine is the speaker can change.
    export void NetplayFrame(uint f, uint final_, int flags) {
        enum SPEAKER = 2;
        netplayFrame = f;
        netplayFinal = final_;
        bool speaker = (flags & SPEAKER) != 0;
        if (speaker != netplaySpeaker) {
            netplaySpeaker = speaker;
            if (plugin) {
                try { plugin.onSpeakerChanged(speaker); }
                catch (Exception e) { error(e); }
            }
        }
        runFinalEffects();
    }

    // A message from the speaker's plugin (what the server sent), at the same point of the game on every machine
    export void NetplayMessage(const(void)* data, uint size) {
        applyServerMessage((cast(const(char)*)data)[0..size].idup);
    }

    // Rollback: the core saves the plugin's state with each frame it saves. The plugin keeps the saves itself (they
    // hold references to its objects), so the core's buffer for it is empty.
    export uint NetplayStateSize() {
        return 0;
    }

    export void NetplaySaveState(uint f, void* data) {
        try {
            auto save = new RollbackSave;
            if (!savedHooks || savedHooksVersion != hooksVersion) {
                savedHooks = new Hooks;
                *savedHooks = hooks.dup;
                savedHooksVersion = hooksVersion;
            }
            save.hooks = savedHooks;
            save.fibers = saveFibers();
            if (plugin) save.game = plugin.saveRollback();
            rollbackSaves[f] = save;
        } catch (Exception e) {
            error(e);
        }
    }

    export void NetplayLoadState(uint f, const(void)* data) {
        auto save = rollbackSaves.get(f, null);
        if (!save) return error("Netplay: the plugin has no saved state for frame ", f);

        // the hooks as they were, and the emulator's with them
        auto before = hooks.hooked;
        hooks = save.hooks.dup;
        foreach (k; 0..3) {
            foreach (word; before[k].byKey) if (word !in hooks.hooked[k]) setHook(0x80000000 | (word << 2), k, 0);
            foreach (word; hooks.hooked[k].byKey) if (word !in before[k]) setHook(0x80000000 | (word << 2), k, 1);
        }
        hooksVersion++;
        savedHooks = save.hooks;
        savedHooksVersion = hooksVersion;

        restoreFibers(save.fibers);
        if (plugin) {
            try { plugin.loadRollback(save.game); }
            catch (Exception e) { error(e); }
        }

        // the frames after it are gone, with what they planned to do outside the game
        foreach (k; rollbackSaves.keys) if (k > f) rollbackSaves.remove(k);
        dropEffectsFrom(f);
        netplayFrame = f;
    }

    export void NetplayDropState(uint f) {
        rollbackSaves.remove(f);
    }

    // For the emulator's rollback self-test: a hash of the plugin's state, which must be the same at the end of a frame
    // run again as at the end of its first run
    export ulong NetplayStateHash() {
        try {
            ulong h = plugin ? plugin.stateHash() : 0;
            void mix(ulong v) { h = (h ^ v) * 0x100000001B3; }
            foreach (r; hooks.returns) { mix(r.at); mix(r.fiber); }
            foreach (c; hooks.calls) {
                mix(c.at);
                mix(c.sp);
                mix(c.function_);
                mix(c.revisit);
                mix(c.fiber);
                mix(hashOf(c.next.method));
                mix(c.queued.length);
            }
            foreach (k; 0..3) foreach (word; hooks.hooked[k].keys.sort) { mix(word); mix(hooks.hooked[k][word]); }
            // (not the hooks' stacks: their unused slots hold whatever was there before, so they can differ when a frame
            // is run again; what a hook does shows in the game's state and memory)
            foreach (fiber; hookFibers) mix(fiber.state);
            return h;
        } catch (Exception e) {
            error(e);
            return 0;
        }
    }

    export void InitiateExecution(ExecutionInfo ei) {
        try {
            info("Initializing...");
            window = ei.window;
            setHook = ei.setHook;
            pc = ei.pc;
            jump = ei.jump;
            gpr = ei.gpr;
            fpr = ei.fpr;
            memory = ei.memory[0..ei.memorySize];
            saveGameState = ei.saveGameState;
            setSaveStateSlot = ei.setSaveStateSlot;

            random.seed(0);
            frame = 0;
            input = input.init;
            hooks = Hooks.init; // (the emulator turned its hooks off)
            hooksVersion++;
            foreach (fiber; hookFibers) endFiber(fiber);
            rollbackSaves = null;
            savedHooks = null;

            plugin = null;
            if (pluginFactory) {
                plugin = pluginFactory(ei.romName.to!string.strip, ei.romHash.to!string.strip);
                try { plugin.onStart(); }
                catch (Exception e) { error(e); }
            }
        } catch (Exception e) {
            error(e);
        }
    }

    export void Input(int port, InputData* data) {
        if (plugin) {
            try { plugin.onInput(port, data); }
            catch (Exception e) { error(e); }
        }

        if (*data && *data != input[port]) {
            random.reseed((frame << 34) | (cast(ulong)port << 32) | *data);
        }

        input[port] = *data;
    }

    export void Frame(uint f) {
        if (!plugin) return;
        frame++;
        hookRun++;
        executing = 0;
        warnLongWaits();
        try { plugin.onFrame(); }
        catch (Exception e) { error(e); }
    }

    export void Execute(Address pc) {
        version (TestDriver) auto profiled = Profiled(pc);
        hookRun++;
        executing = pc;
        scope (exit) executing = 0;

        // This address's one-time handlers are taken first: ones added meanwhile are for the next time it runs, as are
        // waits that start meanwhile
        auto once = hooks.execOnce.get(pc, null);
        if (once) removeHandlers(hooks.execOnce, HookKind.EXECUTE, pc);
        auto serial = hooks.serial;

        // Calls that return here: the game goes on as it was. If a call started in this address's hooks, they ran then
        // (the game was here already), and only what waits for the game to get here goes on now. What waits for the
        // calls goes on last, as the game would after the call.
        bool revisit;
        auto resumes = hooks.calls.length ? returnFromCalls(pc, revisit) : null;
        if (!revisit) {
            if (auto handlers = pc in hooks.exec) runHooks(*handlers, pc);
        }
        runHooks(once, pc);
        if (hooks.returns.length) resumeHooksAt(pc, serial);
        resume(resumes);
    }

    export void ExecuteDone(Address pc) {
        version (TestDriver) auto profiled = Profiled(pc | 1);
        hookRun++;
        auto once = hooks.execDoneOnce.get(pc, null);
        if (once) removeHandlers(hooks.execDoneOnce, HookKind.EXECUTE, pc);

        if (auto handlers = pc in hooks.execDone) runHooks(*handlers, pc);
        runHooks(once, pc);
    }

    // Before a save state is made: not while a hook waits (a save state can't hold it, see HookFiber), and the
    // plugin's state in the game's memory is brought up to date. 0 puts it off until the next interrupt.
    export int StateSaving() {
        if (hookWaiting()) return 0;
        if (plugin) {
            try { plugin.onStateSaving(); }
            catch (Exception e) { error(e); }
        }
        return 1;
    }

    export void StateLoaded() {
        info("Save state loaded");
        if (plugin) {
            try { plugin.onStateLoaded(); }
            catch (Exception e) { error(e); }
        }
    }

    export void Reset(int hard) {
        info(hard ? "Hard reset" : "Soft reset");
        if (plugin) {
            try { plugin.onReset(hard != 0); }
            catch (Exception e) { error(e); }
        }
    }

    void memoryHook(bool write, T)(T* value, Address pc, Address addr) {
        version (TestDriver) auto profiled = Profiled(addr | 2 | write);
        auto table = write ? &hooks.write[sizeIndex(T.sizeof)] : &hooks.read[sizeIndex(T.sizeof)];
        if (auto handlers = addr in *table) runHandlers(*handlers, cast(void*)value, pc, addr);
    }

    export void Read8  (ubyte*  value, Address pc, Address addr) { memoryHook!false(value, pc, addr); }
    export void Read16 (ushort* value, Address pc, Address addr) { memoryHook!false(value, pc, addr); }
    export void Read32 (uint*   value, Address pc, Address addr) { memoryHook!false(value, pc, addr); }
    export void Read64 (ulong*  value, Address pc, Address addr) { memoryHook!false(value, pc, addr); }
    export void Write8 (ubyte*  value, Address pc, Address addr) { memoryHook!true(value, pc, addr); }
    export void Write16(ushort* value, Address pc, Address addr) { memoryHook!true(value, pc, addr); }
    export void Write32(uint*   value, Address pc, Address addr) { memoryHook!true(value, pc, addr); }
    export void Write64(ulong*  value, Address pc, Address addr) { memoryHook!true(value, pc, addr); }
}

version (Windows) {
    extern (Windows)
    BOOL DllMain(HINSTANCE hInstance, ULONG ulReason, LPVOID pvReserved) {
        switch (ulReason) {
            case DLL_PROCESS_ATTACH: dll_process_attach(hInstance, true); break;
            case DLL_PROCESS_DETACH: dll_process_detach(hInstance, true); break;
            case DLL_THREAD_ATTACH:  dll_thread_attach(true, true); break;
            case DLL_THREAD_DETACH:  dll_thread_detach(true, true); break;
            default:
        }
        return true;
    }
}
