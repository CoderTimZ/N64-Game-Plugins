// A game's plugin: its settings, its features, its state and the server it talks to.
//
// A game is a class (MarioParty1 and so on) with features: each option is a class of its own, with the fields it needs
// and its hooks as methods, labeled with where the game runs them:
//
//     final class BlockWeights : Feature!MarioParty1 {
//         override bool enabled() { return config.blockWeights.length > 0; }
//
//         @Exec(0x80040828) void rollBlock() { gpr.v0 = weighted(config.blockWeights, random); }
//     }
//
// The game makes its features in its constructor (feature(new BlockWeights)), and when the game starts, those enabled
// get their labeled hooks and setUp(). A feature sees the game's members as its own (alias game this). Its hooks run in
// the order they're declared, and features in the order they're made, so for one address the game decides which runs
// first.
//
// The state is the fields of the game, its features and anything else it adds (see addState()), as state.d describes.
// The game keeps it in the N64's memory, in a block on the game's heap (see StateBlock), written at the start of each
// frame it changed in: the emulator's save states have it, and the netplay's desync check covers it. Rollback keeps its
// own copy of the bytes with each frame it saves.
module me.timz.n64.game;

public import me.timz.n64.plugin;
public import me.timz.n64.state;

import core.atomic;
import core.sync.mutex;
import core.time : Duration;
import std.algorithm;
import std.array;
import std.conv;
import std.digest.crc : crc32Of;
import std.file : FileException, readText, write;
import std.json;
import std.meta : Reverse;
import std.range;
import std.string;
import std.traits;
import vibe.core.concurrency;
import vibe.core.task;
import vibe.vibe : URL, connectWebSocket, runTask, runApplication, exitEventLoop, sleep, seconds;

// --- Continuations ---

// What runs after a game call that waits for the game (startCall() in plugin.d), or after a function the game called
// returns (afterReturn!m): a method and its arguments, kept as data, so a save state made in the middle carries on
// with it when it's loaded, even in a later run of the emulator. A continuation's parameters are values (numbers,
// structs of them, strings, Then); one named `result` gets the call's result (v0).
Then then(alias m, A...)(A args) if (!A.length || !is(A[0] == GameCall)) {
    alias C = Continuation!m;
    static assert(A.length == C.Args.length, "then!" ~ C.name ~ " takes " ~ C.Args.stringof ~ (C.takesResult ?
                  " (and its result)" : ""));
    auto w = StateWriter();
    static foreach (i; 0 .. A.length) {{
        C.Args[i] value = args[i];
        w.put(value);
    }}
    return Then(C.name, w.data.idup);
}

// The same for a call started with startCall(): startCall(f, ...).then!m(args)
void then(alias m, A...)(ref GameCall call, A args) {
    call.next = .then!m(args);
    if (plugin) plugin.onCallsChanged();
}

// Runs a method (with its arguments) when the function the game is in returns, from a hook at its first instruction
void afterReturn(alias m, A...)(A args) {
    waitForReturn(then!m(args));
}

// The methods continuations can name, by "Class.method", with the object each runs on (the game's or a feature's).
// They're registered when the program starts, so a save state from before still finds them.
private __gshared void function(const(ubyte)[] args, uint result)[string] continuations;

private struct Continuation(alias m) {
    alias Class = __traits(parent, m);
    enum name = __traits(identifier, Class) ~ "." ~ __traits(identifier, m);
    static assert(is(Class : Hooked) && !__traits(isStaticFunction, m), "A continuation is a method: " ~ name);
    alias P = Parameters!m;
    enum takesResult = P.length && ParameterIdentifierTuple!m[$ - 1] == "result";
    alias Args = P[0 .. $ - takesResult];
    static foreach (T; P) {
        static assert(!is(T == class) && !is(T == interface) && !isPointer!T && !isDelegate!T,
                      "A continuation's parameters are values (a save state keeps them): " ~ name);
    }

    shared static this() { continuations[name] = &run; }

    static void run(const(ubyte)[] bytes, uint result) {
        P args;
        auto r = StateReader(bytes);
        static foreach (i; 0 .. Args.length) r.get(args[i]);
        static if (takesResult) args[$ - 1] = cast(P[$ - 1])result;
        foreach (obj; stateObjects) {
            if (auto o = cast(Class)obj) return __traits(child, o, m)(args);
        }
        error("No ", __traits(identifier, Class), " for ", name);
    }
}

shared static this() {
    runThen = (const ref Then then, uint result) {
        if (auto run = then.method in continuations) return (*run)(then.args, result);
        error("A game call goes on in ", then.method, ", which this version of the plugin doesn't have");
    };
}

// --- Labels ---

// The address (or addresses) where the game runs a hook: numbers, or an expression in the feature (or game) naming
// them, like @Exec("start") for a field the constructor sets
struct Exec     { Address[] at; string expression; this(Address[] a...) { at = a.dup; } this(string e) { expression = e; } }
struct ExecDone { Address[] at; string expression; this(Address[] a...) { at = a.dup; } this(string e) { expression = e; } }
// A field in the game's memory the game reads or writes, like @Write("data.currentScene")
struct Read  { string field; }
struct Write { string field; }
// The same field of each of a list, like @WriteEach("players", "data.coins"): the hook gets the element first
struct ReadEach  { string list, field; }
struct WriteEach { string list, field; }

// A method as a delegate, for hooks. A hook has to be a method (not a lambda or a nested function): those would keep
// state of their own, which the state block doesn't hold.
private auto method(alias fn)(Object obj) {
    static assert(is(__traits(parent, fn) : Object) && !__traits(isStaticFunction, fn), "A hook must be a method, not " ~
                  "a lambda or a nested function (their state isn't saved): " ~ __traits(identifier, fn));
    return &__traits(child, cast(__traits(parent, fn))obj, fn);
}

// The labeled hooks of an object (its class's and its base classes')
void hookLabels(T)(T obj) {
    static foreach (C; Reverse!(classesOf!T)) {
        static foreach (name; __traits(derivedMembers, C)) {
            static if (__traits(compiles, __traits(getOverloads, C, name))) {
                static foreach (fn; __traits(getOverloads, C, name)) {
                    static foreach (label; __traits(getAttributes, fn)) {
                        static if (is(typeof(label) == Exec) || is(typeof(label) == ExecDone)) {{
                            auto table = is(typeof(label) == Exec) ? &hooks.exec : &hooks.execDone;
                            static if (label.expression.length) {
                                const(Address)[] at;
                                static if (isArray!(typeof(mixin("obj." ~ label.expression)))) at = mixin("obj." ~ label.expression);
                                else at = [mixin("obj." ~ label.expression)];
                            } else {
                                const(Address)[] at = label.at;
                            }
                            foreach (a; at) if (a) addHandler(*table, HookKind.EXECUTE, a, execHandler(method!fn(obj)));
                        }}
                        static if (is(typeof(label) == Read) || is(typeof(label) == Write)) {{
                            alias F = typeof(mixin("obj." ~ label.field));
                            enum write = is(typeof(label) == Write);
                            hookMemory!(write, F)(mixin("obj." ~ label.field).addr, memHandler!F(method!fn(obj)));
                        }}
                        static if (is(typeof(label) == ReadEach) || is(typeof(label) == WriteEach)) {{
                            enum write = is(typeof(label) == WriteEach);
                            foreach (e; mixin("obj." ~ label.list)) {
                                alias F = typeof(mixin("e." ~ label.field));
                                hookMemory!(write, F)(mixin("e." ~ label.field).addr, eachHandler!F(method!fn(obj), e));
                            }
                        }}
                    }
                }
            }
        }
    }
}

// A hook for one element of a list (in a function of its own: closures made in a loop would share its variable)
MemHandler eachHandler(F, D, E)(D method, E e) {
    enum n = Parameters!D.length;
    return MemHandler([method.ptr, method.funcptr], (void* v, Address pc, Address address) {
        static if (n == 2) method(e, *cast(F*)v);
        else method(e, *cast(F*)v, pc, address);
    });
}

void hookMemory(bool write, F)(Address address, MemHandler handler) {
    auto table = write ? &hooks.write[sizeIndex(F.sizeof)] : &hooks.read[sizeIndex(F.sizeof)];
    addHandler(*table, write ? HookKind.WRITE : HookKind.READ, address, handler);
}

// What a game and its features have: hooks set while the game runs (where it only says when: a return address, or
// the routine a pointer holds). Execute and ExecuteDone hooks can wait for the game (see HookFiber in plugin.d).
abstract class Hooked {
    void setUp() { } // Once, when the game starts (after the labeled hooks)

    final void hookExec(alias fn)(Address address)         { addHandler(hooks.exec, HookKind.EXECUTE, address, execHandler(method!fn(this))); }
    final void hookExecOnce(alias fn)(Address address)     { addHandler(hooks.execOnce, HookKind.EXECUTE, address, execHandler(method!fn(this))); }
    final void hookExecDone(alias fn)(Address address)     { addHandler(hooks.execDone, HookKind.EXECUTE, address, execHandler(method!fn(this))); }
    final void hookExecDoneOnce(alias fn)(Address address) { addHandler(hooks.execDoneOnce, HookKind.EXECUTE, address, execHandler(method!fn(this))); }
    final void hookRead(alias fn, F)(ref F field)  { hookMemory!(false, F)(field.addr, memHandler!F(method!fn(this))); }
    final void hookWrite(alias fn, F)(ref F field) { hookMemory!(true, F)(field.addr, memHandler!F(method!fn(this))); }
    final void unhookExec(alias fn)(Address address) {
        auto m = method!fn(this);
        removeHandlers(hooks.exec, HookKind.EXECUTE, address, [m.ptr, m.funcptr]);
    }
    final void unhookExecOnce(alias fn)(Address address) {
        auto m = method!fn(this);
        removeHandlers(hooks.execOnce, HookKind.EXECUTE, address, [m.ptr, m.funcptr]);
    }
}

// A feature of a game (see the module's description)
abstract class FeatureBase : Hooked {
    bool enabled() { return true; } // Whether the game has it now (its settings turn it on): only then is it set up
    void onFrame() { }
    void onInput(int port, InputData* data) { }
    void receive(const JSONValue message) { } // A message from the server
    void onReset(bool hard) { }
    void onStateLoaded() { } // A save state was loaded, which ends the waiting hooks (flags saying one waits are reset)
}

abstract class Feature(G) : FeatureBase {
    @Fixed G game;
    alias game this;

    // (and the game's types, like Player: alias this only finds its fields and methods)
    static foreach (name; __traits(allMembers, G)) {
        static if (is(__traits(getMember, G, name)) && !__traits(hasMember, FeatureBase, name)) {
            mixin("alias " ~ name ~ " = G." ~ name ~ ";");
        }
    }
}

// --- The game ---

// The game's plugin class: startup() calls this. The game's state is S's fields (a test build's game is a subclass of
// the game, whose own fields aren't state).
void usePlugin(T, S = T)() {
    pluginFactory = (name, hash) {
        auto game = new T(name, hash);
        game.stateParts = StatePart.of!S("game", game) ~ game.stateParts;
        return game;
    };
}

// An object that's part of the game's state, and how to save it
struct StatePart {
    string name;
    Object obj;
    void function(Object, ref StateWriter) save;
    void function(Object, ref StateReader) load;
    void function(Object) hook;

    static StatePart of(T)(string name, T obj) {
        return StatePart(name, obj, (Object o, ref StateWriter w) { w.fields(cast(T)o); },
                         (Object o, ref StateReader r) { auto t = cast(T)o; r.fields(t); },
                         (Object o) { hookLabels(cast(T)o); });
    }
}

// The framework's state (see plugin.d)
struct FrameworkState {
    Xoshiro256pp random;
    ulong frame;
    InputData[4] input;
    GameCall[] calls;
}

// The game's functions for the state block: alloc(size) and free(ptr) on a heap that lives as long as the game (a
// permanent one), the function that (re)creates that heap, and one that always runs in a game process (where alloc and
// free are safe to call), from its start. A game without them keeps the state only for rollback. In some games free
// takes where the pointer is (and clears it there) rather than the pointer.
struct Heap {
    Address alloc, free, create, process;
    bool freeTakesPointerTo;
}

abstract class Game(Config) : Hooked, Plugin {
    immutable string romName;
    immutable string romHash;
    const Config config;
    @Fixed StatePart[] stateParts;       // The game's state: itself (first), its features and whatever it adds, in order
    @Fixed FeatureBase[] activeFeatures; // The enabled features, once the game started
    immutable Heap heap;

    this(string romName, string romHash, Heap heap = Heap.init) {
        this.romName = romName;
        this.romHash = romHash;
        this.heap = heap;
        config = readConfig();
        .stateBlock = StateBlock.init;
    }

    // A feature of the game (see the module's description)
    F feature(F : FeatureBase)(F f) {
        f.game = cast(typeof(f.game))this;
        addState(__traits(identifier, F), f);
        return f;
    }

    // The game's feature of a class (for tests), or null
    F featureOf(F : FeatureBase)() {
        foreach (p; stateParts) if (auto found = cast(F)p.obj) return found;
        return null;
    }

    // Another object whose fields are part of the game's state, by a name of its own
    T addState(T)(string name, T obj) {
        stateParts ~= StatePart.of(name, obj);
        return obj;
    }

    // The settings: the game's file (named after the ROM), or the host's during netplay
    Config readConfig() {
        if (netplayRole == NetplayRole.guest && netplayImport.type == JSONType.object) {
            if (auto imported = "config" in netplayImport) {
                auto config = (*imported).fromJSON!Config;
                return config ? config : new Config;
            }
        }
        auto file = romName ~ ".json";
        try {
            auto config = readText(file).parseJSON.fromJSON!Config;
            if (!config) config = new Config;
            write(file, config.toJSON.toJSONText(true)); // (with the options it didn't have)
            return config;
        } catch (FileException e) {
            warning(e.message);
            auto config = new Config;
            try write(file, config.toJSON.toJSONText(true)); catch (Exception) { }
            return config;
        } catch (Exception e) {
            auto message = e.classinfo.name ~ ": " ~ e.message;
            error("[", file, "] ", message);
            showError(file, message);
            return new Config;
        }
    }

    // The settings as JSON, for netplay guests. Written with std.json rather than toJSONText, since its floats keep
    // every digit: a rounded float would make a guest's game run differently.
    string netplayExport() {
        JSONValue result = parseJSON("{}");
        result["config"] = config.toJSON;
        return result.toString;
    }

    void onStart() {
        if (serverURL.length && (netplayRole == NetplayRole.none || netplaySpeaker)) connect(serverURL);
        stateObjects = stateParts.map!(p => p.obj).array;
        stateParts[0].hook(this);
        setUp();
        foreach (p; stateParts[1 .. $]) {
            auto f = cast(FeatureBase)p.obj;
            if (!f || !f.enabled) continue;
            activeFeatures ~= f;
            p.hook(f);
            f.setUp();
        }
    }

    void onFrame() {
        receiveFromServer();
        foreach (f; activeFeatures) f.onFrame();
        writeStateBlock();
    }

    void onInput(int port, InputData* data) {
        foreach (f; activeFeatures) f.onInput(port, data);
    }

    void onMessage(string text) {
        auto message = parseJSON(text);
        receive(message);
        foreach (f; activeFeatures) f.receive(message);
    }

    void receive(const JSONValue message) { }

    void onReset(bool hard) {
        foreach (f; activeFeatures) f.onReset(hard);
    }

    void onFinish() {
        disconnect();
    }

    // --- The state ---

    // The state's bytes: a field for each part, and the framework's
    const(ubyte)[] saveState() {
        auto w = StateWriter(stateBuffer[0 .. 0]);
        w.num(cast(ushort)(stateParts.length + 1));
        void part(string name, void delegate() save) {
            w.num(cast(ubyte)name.length);
            w.raw(name);
            auto at = w.data.length;
            w.num(uint.init);
            save();
            *cast(uint*)&w.data[at] = cast(uint)(w.data.length - at - uint.sizeof);
        }
        auto framework = FrameworkState(random, frame, input, hooks.calls);
        part("framework", { w.fields(framework); });
        foreach (ref p; stateParts) part(p.name, { p.save(p.obj, w); });
        stateBuffer = w.data;
        return w.data;
    }

    // (and the framework's part, whose game calls are the caller's to restore)
    FrameworkState loadState(const(ubyte)[] bytes, bool keepSession) {
        auto r = StateReader(bytes, keepSession);
        auto framework = FrameworkState(random, frame, input);
        foreach (i; 0 .. r.read!ushort) {
            auto name = cast(const(char)[])r.raw(r.read!ubyte);
            auto part = StateReader(r.raw(r.read!uint), keepSession);
            if (name == "framework") {
                part.fields(framework);
                random = framework.random;
                frame = framework.frame;
                input = framework.input;
            } else {
                auto p = stateParts.find!(p => p.name == name);
                if (!p.empty) p.front.load(p.front.obj, part);
            }
        }
        return framework;
    }

    // Rollback: the state's bytes (the block's own when the state is what the block holds), and the block as it was
    final class RollbackState {
        const(ubyte)[] bytes;
        StateBlock block;
    }

    Object saveRollback() {
        auto save = new RollbackState;
        auto bytes = saveState();
        save.bytes = bytes == .stateBlock.bytes ? .stateBlock.bytes : bytes.idup;
        save.block = .stateBlock;
        return save;
    }

    void loadRollback(Object saved) {
        auto save = cast(RollbackState)saved;
        loadState(save.bytes, false);
        .stateBlock = save.block;
    }

    ulong stateHash() {
        ulong h = 0xCBF29CE484222325;
        foreach (b; saveState()) h = (h ^ b) * 0x100000001B3;
        return h;
    }

    // A save state was loaded: its state is in its block, if it has one (with the game calls it was in the middle of)
    void onStateLoaded() {
        cancelWaits();
        .stateBlock = StateBlock.find();
        if (!.stateBlock.address) {
            warning("The save state has no state of the plugin's: the plugin keeps its own");
        } else {
            try {
                restoreCalls(loadState(.stateBlock.bytes, true).calls);
            } catch (Exception e) {
                error("Can't read the plugin's state in the save state: ", e.message);
                .stateBlock = StateBlock.init;
            }
        }
        foreach (f; activeFeatures) f.onStateLoaded();
    }

    // (a save state made before the next frame has it)
    void onCallsChanged() {
        writeStateBlock();
    }

    void onStateSaving() {
        writeStateBlock();
    }

    // --- The state block ---

    // Writes the state to its block if it changed (or asks for a bigger block)
    void writeStateBlock() {
        auto bytes = saveState();
        if (bytes == .stateBlock.bytes) return;
        if (.stateBlock.address && bytes.length <= .stateBlock.capacity) .stateBlock.write(bytes.idup);
        else .stateBlock.needed = true;
    }

    // Makes a block (or a bigger one) from a game process when the state needs one
    @ExecDone("heap.process") final void maintainStateBlock() {
        if (!.stateBlock.needed || .stateBlock.noRoom || !heap.alloc) return;
        // (only safe if the function starts with "addiu sp, sp, ...", which a different version of the game might not)
        if ((heap.process.val!uint & 0xFFFF0000) != 0x27BD0000) {
            warning("Unexpected code at ", heap.process.to!string(16), ": the plugin's state isn't saved with save states");
            .stateBlock.noRoom = true;
            return;
        }
        auto capacity = StateBlock.capacityFor(saveState().length);
        auto old = .stateBlock;
        Address address = callGame(heap.alloc, StateBlock.HEADER + capacity);
        if (!inMemory(address, StateBlock.HEADER + capacity)) {
            warning("Not enough memory for the plugin's state (", capacity, " bytes): it isn't saved with save states");
            .stateBlock.noRoom = true;
            return;
        }
        .stateBlock = StateBlock(address, capacity, old.count, null, false);
        writeStateBlock();
        info("The plugin's state is in the game's memory at ", address.to!string(16), " (", capacity, " bytes of room)");
        if (old.address) {
            old.wipe();
            if (heap.free) callGame(heap.free, heap.freeTakesPointerTo ? old.address + StateBlock.SELF : old.address);
        }
    }

    // The heap is being (re)created (boot or reset), so the block is gone: a new one is made later
    @Exec("heap.create") final void heapRecreated() {
        .stateBlock.wipe();
        .stateBlock = StateBlock.init;
    }

    // --- The server ---

    // The server (the bingo site) the plugin talks to, if any. During netplay only the speaker connects (see
    // NetplayFrame), and connects or disconnects when that changes.
    string serverURL() { return null; }

    // Sends a message to the server. During netplay only the speaker sends, once the frame it comes from is final.
    void sendMessage(string message) {
        if (netplayRole != NetplayRole.none && !netplaySpeaker) return;
        afterFinal({ if (netplayRole == NetplayRole.none || netplaySpeaker) sendNow(message); });
    }

    void sendMessage(JSONValue message) {
        sendMessage(message.toJSONText);
    }

    void onSpeakerChanged(bool speaker) {
        if (!serverURL.length) return;
        if (speaker) {
            info("Netplay: this machine talks to ", serverURL, " for everyone now");
            connect(serverURL);
        } else {
            info("Netplay: another machine talks to ", serverURL, " now");
            disconnect();
        }
    }
}

// --- The state block ---

// The state in the N64's memory: a header of 8 words (two magic words, the format, the capacity, the length of the
// state's bytes, their CRC-32, a count of the writes, and the block's own address), then the bytes
struct StateBlock {
    enum MAGIC_1 = 0x4E363450; // "N64P"
    enum MAGIC_2 = 0x53544154; // "STAT"
    enum FORMAT = 3;           // 3: the format in state.d (2 was zlib-compressed JSON, 1 a binary format)
    enum HEADER = 32;
    enum SELF = 28; // (where the header has the block's address)

    Address address;       // 0 if there's none
    uint capacity;
    uint count;            // The last write's
    const(ubyte)[] bytes;  // What it holds (the last write's)
    bool needed = true;    // The state needs a block, or a bigger one (see Game.maintainStateBlock)
    bool noRoom;           // The game had no room for it (until the heap is made again)

    // Room for the state to grow by half before it needs a bigger block, in steps of 1 KB
    static uint capacityFor(size_t length) {
        return cast(uint)((length + length / 2 + 1023) / 1024 * 1024);
    }

    static uint crc(const(ubyte)[] bytes) {
        auto c = crc32Of(bytes);
        return c[0] | c[1] << 8 | c[2] << 16 | c[3] << 24;
    }

    void write(const(ubyte)[] state) {
        foreach (i, b; state) Ptr!ubyte(address + HEADER + cast(uint)i)[0] = b;
        auto header = [MAGIC_1, MAGIC_2, FORMAT, capacity, cast(uint)state.length, crc(state), ++count, address];
        foreach (i, w; header) (address + cast(uint)i * 4).val!uint = w;
        bytes = state;
    }

    void wipe() {
        if (inMemory(address, HEADER)) address.val!uint = 0;
    }

    // The block at an address, or none
    static StateBlock at(Address address) {
        if (!inMemory(address, HEADER) || address.val!uint != MAGIC_1 || (address + 4).val!uint != MAGIC_2 ||
            (address + 8).val!uint != FORMAT || (address + SELF).val!uint != address) return StateBlock.init;
        auto capacity = (address + 12).val!uint;
        auto length = (address + 16).val!uint;
        if (length > capacity || !inMemory(address, HEADER + capacity)) return StateBlock.init;
        auto state = new ubyte[length];
        foreach (i, ref b; state) b = Ptr!ubyte(address + HEADER + cast(uint)i)[0];
        if (crc(state) != (address + 20).val!uint) return StateBlock.init;
        return StateBlock(address, capacity, (address + 24).val!uint, state, false);
    }

    // The block in memory (the most recently written, if a freed one is left over)
    static StateBlock find() {
        StateBlock best;
        foreach (address; searchMemory([MAGIC_1, MAGIC_2, FORMAT])) {
            auto b = at(address);
            if (b.address && (!best.address || b.count > best.count)) best = b;
        }
        return best;
    }
}

__gshared {
    StateBlock stateBlock; // (rollback saves it with the state: see Game.saveRollback)
    ubyte[] stateBuffer;   // (used again for each frame's bytes: see Game.saveState)
    Object[] stateObjects; // The game's state parts' objects (see Continuation)
}

// --- The connection to the server ---

// Opens the connection to a server: a thread that keeps it open, reconnecting when it drops, until disconnect()
void connect(string url) {
    disconnect();
    info("Connecting to ", url);
    int generation = atomicLoad(connectionGeneration);
    spawn((Tid parentTid, URL url, int generation) {
        bool wanted() { return atomicLoad(connectionGeneration) == generation; }
        runTask({
            while (wanted()) {
                try {
                    auto ws = connectWebSocket(url);
                    synchronized (connectionLock) {
                        if (wanted()) {
                            wsSender = runTask({
                                try {
                                    while (ws.connected) ws.send(receiveOnly!string);
                                } catch (Exception e) { }
                            });
                        }
                    }
                    while (wanted() && ws.connected) {
                        if (ws.waitForData(1.seconds)) {
                            auto text = ws.receiveText();
                            if (wanted()) send(parentTid, text);
                        }
                    }
                    ws.close();
                } catch (Exception e) { }

                // wait 5 seconds before reconnecting, unless disconnected
                foreach (i; 0..5) {
                    if (!wanted()) break;
                    try { sleep(1.seconds); } catch (Exception e) { break; }
                }
            }
            exitEventLoop();
        });
        runApplication();
    }, thisTid, URL(url), generation);
    connectionSpawned = true;
}

// Closes the connection connect() opened (its thread ends within a second)
void disconnect() {
    synchronized (connectionLock) {
        atomicOp!"+="(connectionGeneration, 1);
        wsSender = Task.init;
    }
    // what it received and nobody read is from the old connection (std.concurrency only has a mailbox here once a
    // connection's thread was spawned)
    if (connectionSpawned) {
        while (receiveTimeout(Duration.zero, (string msg) { })) { }
    }
}

void sendNow(string message) {
    synchronized (connectionLock) {
        if (wsSender) send(wsSender, message);
    }
}

// What the server sent since the last frame (during netplay, passed on to every machine: see passOnServerMessage)
void receiveFromServer() {
    bool connected;
    synchronized (connectionLock) connected = cast(bool)wsSender;
    if (connected) receiveTimeout(Duration.zero, (string message) { passOnServerMessage(message); });
}

shared int connectionGeneration; // A connection's thread ends when it changes (see disconnect())

__gshared {
    Mutex connectionLock;
    bool connectionSpawned;
    Task wsSender;
}

shared static this() {
    connectionLock = new Mutex;
}
