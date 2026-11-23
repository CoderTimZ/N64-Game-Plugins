module me.timz.n64.plugin;

import core.sys.windows.windows;
import core.sys.windows.dll;
import std.algorithm;
import std.random;
import std.range;
import std.string;
import std.json;
import std.file;
import std.conv;
import std.traits;
import std.stdio;
import std.typecons;
import std.math;
import std.regex;
import vibe.core.concurrency;
import vibe.core.task;
import vibe.vibe;

alias Address     = uint;
alias Instruction = uint;

enum Instruction NOP = 0;

ulong flip(ulong value) pure nothrow @nogc @safe {
    import core.bitop;
    return ror(value, 32);
}

double fixRoundingError(double x) pure nothrow @nogc @safe {
    auto f = cast(float)x;
    return f == cast(long)f ? f : x;
}

size_t swapAddrEndian(T)(size_t address) pure nothrow @nogc @safe {
    static if (T.sizeof == 1) {
        return address ^ 0b11;
    } else static if (T.sizeof == 2) {
        return address ^ 0b10;
    } else {
        return address;
    }
}

T* swapAddrEndian(T)(T* ptr) pure nothrow @nogc {
    return cast(T*)swapAddrEndian!T(cast(size_t)ptr);
}

Address addr(T)(ref T v) {
    return cast(Address)swapAddrEndian!T(cast(ubyte*)&v - memory.ptr) + 0x80000000;
}

ref T val(T)(Address address) {
    return *Ptr!T(address);
}

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

align (1) struct Arr(T, size_t S = 0) {
    T front;
    
    @property size_t length() const { return S; }
    @property bool empty() const { return S == 0; }
    ref T opIndex(size_t i) { return *swapAddrEndian(swapAddrEndian(&front) + i); }

    int opApply(scope int delegate(ref T) dg) {
        foreach (i; 0..S) {
            if (int result = dg(this[i])) {
                return result;
            }
        }
        return 0;
    }
}

mixin template Field(Address A, T, string N) {
    align (1) struct {
        ubyte[swapAddrEndian!T(A) & 0x7FFFFF] _pad;
        mixin("T " ~ N ~ ";");
    }
}

string lossyFloats(string json) {
    return json.replaceAll!(m => m.hit.to!double.to!string)(regex(`-?[0-9]+\.[0-9]+`));
}

JSONValue toJSON(T)(const T scl) if (isScalarType!T && !is (T == enum)) { return JSONValue(scl); }
JSONValue toJSON(T)(const T enm) if (is (T == enum)) { return JSONValue(enm.to!string); }
JSONValue toJSON(T)(const T str) if (isSomeString!T) { return JSONValue(str); }
JSONValue toJSON(T)(const T arr) if (isArray!T && !isSomeString!T) {
    return JSONValue(arr.map!(e => e.toJSON()).array);
}
JSONValue toJSON(T)(const T asc) if (isAssociativeArray!T) {
    auto result = parseJSON("{}");
    foreach (ref k, ref v; asc) {
        result[k.to!string] = v.toJSON();
    }
    return result;
}
JSONValue toJSON(T)(const ref T agg) if (is(T == struct)) {
    auto result = parseJSON("{}");
    foreach (i, ref v; agg.tupleof) {
        auto k = __traits(identifier, agg.tupleof[i]);
        result[k] = v.toJSON();
    }
    return result;
}
JSONValue toJSON(T)(const T agg, JSONValue result = parseJSON("{}")) if (is(T == class)) {
    if (agg is null) return JSONValue(null);
    foreach (i, ref v; agg.tupleof) {
        auto k = __traits(identifier, agg.tupleof[i]);
        result[k] = v.toJSON();
    }
    static if (is(BaseClassesTuple!T[0])) {
        return agg.toJSON!(BaseClassesTuple!T[0])(result);
    } else {
        return result;
    }
}

T fromJSON(T)(const JSONValue scl) if (isScalarType!T && !is (T == enum)) {
    switch (scl.type) {
        case JSONType.integer:  return cast(T)scl.integer;
        case JSONType.uinteger: return cast(T)scl.uinteger;
        case JSONType.float_:   return cast(T)scl.floating;
        case JSONType.true_:    return cast(T)scl.boolean;
        case JSONType.false_:   return cast(T)scl.boolean;
        default:                assert(0, "Invalid JSONValue type");
    }
}
T fromJSON(T)(const JSONValue enm) if (is (T == enum)) {
    return enm.type == JSONType.integer ? cast(T)enm.integer : enm.str.to!T;
}
T fromJSON(T)(const JSONValue str) if (isSomeString!T) { return str.str; }
T fromJSON(T)(const JSONValue arr) if (isArray!T && !isSomeString!T) {
    return arr.array.map!(e => e.fromJSON!(ElementType!T)).array;
}
T fromJSON(T)(const JSONValue obj) if (isAssociativeArray!T) {
    T result;
    foreach (ref k, ref v; obj.object) {
        result[k.to!(KeyType!T)] = v.fromJSON!(ValueType!T);
    }
    return result;
}
T fromJSON(T)(const JSONValue obj) if (is(T == struct)) {
    T result;
    foreach (i, ref v; result.tupleof) {
        auto k = __traits(identifier, result.tupleof[i]);
        if (auto value = k in obj) {
            v = (*value).fromJSON!(typeof(v));
        }
    }
    return result;
}
T fromJSON(T)(const JSONValue obj, T result = null) if (is(T == class)) {
    if (obj.type == JSONType.null_) return null;
    if (!result) result = new T;
    foreach (i, ref v; result.tupleof) {
        auto k = __traits(identifier, result.tupleof[i]);
        if (auto value = k in obj) {
            v = (*value).fromJSON!(typeof(v));
        }
    }
    static if (is(BaseClassesTuple!T[0])) {
        return cast(T)obj.fromJSON!(BaseClassesTuple!T[0])(result);
    } else {
        return result;
    }
}

struct SplitMix64 {
    enum isUniformRandom = true;
    enum hasFixedRange = true;
    enum min = ulong.min;
    enum max = ulong.max;
    enum empty = false;

    ulong state;

    this(ulong s) @safe nothrow @nogc { seed(s); }
    void seed(ulong s) @safe nothrow @nogc { state = s; }
    auto save() const @safe nothrow @nogc { return this; }
    @property ulong front() const @safe nothrow @nogc { return hash(state); }
    void popFront() @safe nothrow @nogc { state += 0x9e3779b97f4a7c15; }
    ulong next() @safe nothrow @nogc { popFront(); return front; }

    static ulong hash(ulong z) @safe nothrow @nogc pure {
        z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) * 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }
}

struct Xoshiro256pp {
    import core.bitop;

    enum isUniformRandom = true;
    enum hasFixedRange = true;
    enum min = ulong.min;
    enum max = ulong.max;
    enum empty = false;

    ulong[4] state;
    
    this(ulong[4] s) @safe nothrow @nogc { seed(s); }
    this(ulong s) @safe nothrow @nogc { seed(s); }
    void seed(ulong[4] s) @safe nothrow @nogc { state = s; }
    void seed(ulong s) @safe nothrow @nogc { seed([0, 0, 0, 0]); reseed(s); }
    void reseed(ulong s) @safe nothrow @nogc { auto r = SplitMix64(s); state.each!((ref e) => e ^= r.next); }
    auto save() const @safe nothrow @nogc { return this; }
    @property ulong front() const @safe nothrow @nogc { return rol(state[0] + state[3], 23) + state[0]; }
    void popFront() @safe nothrow @nogc {
        auto temp = state[1] << 17;
        state[2] ^= state[0];
        state[3] ^= state[1];
        state[1] ^= state[2];
        state[0] ^= state[3];
        state[2] ^= temp;
        state[3] = rol(state[3], 45);
    }
    ulong next() @safe nothrow @nogc { popFront(); return front; }
}

double normal(Random)(ref Random r) @safe {
    import std.math;

    double u = r.uniform01();
    double v = r.uniform01();
    return sqrt(-2 * log(u)) * cos(2 * PI * v);
}

T weighted(T, W, Random)(ref const W[T] options, ref Random r) {
    auto keys = options.keys;
    double random = r.uniform01() * options.values.sum();
    double weight = 0;
    foreach (ref const T e; keys) {
        if ((weight += options[e]) > random) {
            return e;
        }
    }
    return keys.back;
}

Range distanceShuffleFast(Range, RandomGen)(Range r, size_t d, ref RandomGen gen) if (isRandomAccessRange!Range && isUniformRNG!RandomGen) {
    if (r.length <= 1 || d == 0) return r;
    if (d >= r.length - 1) return r.randomShuffle(gen);

    void dS(Range)(Range r) {
        auto w = min(d+1, r.length);
        auto cpy = cycle(r.take(w).array);
        auto src = cycle(new bool[w]);
        auto dst = cycle(new bool[w]);

        foreach (size_t i; iota(r.length)) {
            size_t j;

            if (!src[i]) {
                do { j = i + uniform(0, min(r.length-i, w), gen); } while (dst[j]);
                r[j] = cpy[i];
                dst[j] = true;
            }

            if (!dst[i]) {
                do { j = i + uniform(1, min(r.length-i, w), gen); } while (src[j]);
                r[i] = cpy[j];
                src[j] = true;
            }

            if (i+w < r.length) {
                cpy[i+w] = r[i+w];
                src[i+w] = false;
                dst[i+w] = false;
            }
        }
    }

    if (uniform!"[]"(0, 1, gen)) {
        dS(r);
    } else {
        dS(retro(r));
    }
    
    return r;
}

Range distanceShuffleUniform(Range, RandomGen)(Range r, size_t d, ref RandomGen gen) if (isRandomAccessRange!Range && isUniformRNG!RandomGen) {
    if (r.length <= 1 || d == 0) return r;
    if (d >= r.length - 1) return r.randomShuffle(gen);

    auto p = iota(r.length).array; // Positions
    auto q = iota(r.length).array; // Inverse Positions

    void s(size_t i, size_t j) {
        swap(r[i], r[j]);
        swap(p[i], p[j]);
        swap(q[p[i]], q[p[j]]);
    }
    
    for (auto i = 0; i < r.length-1; i++) {
        auto j = uniform(i, min(i+d+1, r.length), gen);
        if (i >= d && q[i-d] >= i && q[i-d] != j) { // Dead End
            while (--i >= 0) s(i, q[i]);            // Reset
        } else {
            s(i, j);
        }
    }

    return r;
}

Range distanceShuffle(Range, RandomGen)(Range r, size_t d, ref RandomGen gen) if (isRandomAccessRange!Range && isUniformRNG!RandomGen) {
    if (r.length < 50) {
        return distanceShuffleUniform(r, d, gen);
    } else {
        return distanceShuffleFast(r, d, gen);
    }
}

// An endless shuffled sequence of a set of elements, where next() can skip elements without losing them.
//
// It behaves as if it were an endless list of cycles, each a distance shuffle of the one before (the first is a
// full shuffle), and next(pred) takes the earliest element in that list that hasn't been taken yet and satisfies
// pred. Skipped elements stay where they are, to be taken later. Cycles are only generated once a draw reaches
// them, which gives the same result as generating them all in advance.
struct ShuffleStream(T) {
    T[][] cycles;    // The cycles that still have elements left to take (always at least the latest one)
    bool[][] taken;  // Which elements of each cycle have been taken

    this(Range, RandomGen)(Range r, ref RandomGen gen) {
        initialize(r, gen);
    }

    void initialize(Range, RandomGen)(Range r, ref RandomGen gen) {
        auto first = r.array.dup;
        first.randomShuffle(gen);
        cycles = [first];
        taken = [new bool[first.length]];
    }

    bool empty() const {
        return cycles.empty || cycles[0].empty;
    }

    void clear() {
        cycles = null;
        taken = null;
    }

    T next(RandomGen)(ref RandomGen gen, scope bool delegate(T) pred = null) {
        assert(!empty);

        // Every cycle has the same elements, so if none satisfies pred, no cycle ever will
        if (pred && !cycles[$-1].any!(e => pred(e))) pred = null;

        for (size_t c = 0; ; c++) {
            if (c == cycles.length) {
                auto cycle = cycles[$-1].dup;
                distanceShuffle(cycle, (cycle.length - 1) / 2, gen);
                cycles ~= cycle;
                taken ~= new bool[cycle.length];
            }

            foreach (i, e; cycles[c]) {
                if (taken[c][i] || (pred && !pred(e))) continue;

                taken[c][i] = true;

                // Forget fully taken cycles, except the latest (the next cycle is made from it)
                while (cycles.length > 1 && taken[0].all) {
                    cycles = cycles[1..$];
                    taken = taken[1..$];
                }

                return e;
            }
        }
    }
}

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
};

union FPR {
    Register!float[32] r;

    struct {
        Register!float f0,  f1,  f2,  f3,  f4,  f5,  f6,  f7,
                       f8,  f9,  f10, f11, f12, f13, f14, f15,
                       f16, f17, f18, f19, f20, f21, f22, f23,
                       f24, f25, f26, f27, f28, f29, f30, f31;
    }
};

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

enum MsgLevel {
    ERROR   = 1,
    WARNING = 2,
    INFO    = 3,
    STATUS  = 4,
    VERBOSE = 5
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

interface Plugin {
    void loadConfig();
    void onStart();
    void onInput(int, InputData*);
    void onMessage(string msg);
    void onFrame(ulong);
    void onFinish();
}

final class NoState { }

static T loadJson(T)(string filename) {
    try {
        T json = readText(filename).parseJSON().fromJSON!T();
        if (!json) json = new T;
        json.saveJson(filename);
        return json;
    } catch (FileException e) {
        warning("[" ~ e.classinfo.name ~ "] " ~ e.message);
        T json = new T;
        json.saveJson(filename);
        return json;
    } catch (Exception e) {
        auto msg = e.classinfo.name ~ ": " ~ e.message;
        error("[" ~ filename ~ "] " ~ msg);
        MessageBoxA(window, msg.toStringz, filename.toStringz, MB_ICONEXCLAMATION);
        return null;
    }
}

static void saveJson(T)(T json, string filename) {
    static if (!is(T == NoState)) {
        try {
            std.file.write(filename, json.toJSON().toPrettyString(JSONOptions.doNotEscapeSlashes).lossyFloats());
        } catch (Exception e) {
            auto msg = e.classinfo.name ~ ": " ~ e.message;
            error("[" ~ filename ~ "] " ~ msg);
            MessageBoxA(window, msg.toStringz, filename.toStringz, MB_ICONEXCLAMATION);
        }
    }
}

// A game's State as stored in the N64's memory: minified JSON, compressed with zlib (deflate).
// It's still JSON underneath, so fields and enums are matched by name: a State saved by an older or newer version
// of a plugin still loads, with missing fields keeping their defaults and unknown fields ignored.
ubyte[] packState(T)(T state) {
    import std.zlib : compress;
    return cast(ubyte[])compress(state.toJSON().toString(JSONOptions.doNotEscapeSlashes).lossyFloats(), 9);
}

T unpackState(T)(const(ubyte)[] data) {
    import std.zlib : uncompress;
    return (cast(string)uncompress(data).idup).parseJSON().fromJSON!T();
}

// Where a game's permanent heap and its functions are, for keeping the plugin's State in the N64's memory.
// The plugin allocates a block on the permanent heap, so it never collides with anything else using the memory
// (such as PartyPlanner64 boards in the Expansion Pak), and save states include it automatically.
struct PermanentHeap {
    Address heapPointer;   // Variable holding the heap's first node (HeapNode*)
    Address heapInit;      // Function that (re)creates the heap
    Address alloc;         // void* alloc(u32 size)
    Address free;          // void free(void* ptr)
    Address processSleep;  // HuPrcVSleep: always runs inside a game process, where the heap functions are safe to call
}

// The plugin's folder for files that aren't settings (like the State backups):
// %APPDATA%\N64-Game-Plugins on Windows, $XDG_STATE_HOME/N64-Game-Plugins (~/.local/state) elsewhere
string dataDirectory() {
    import std.process : environment;
    import std.path : buildPath, expandTilde;

    version (Windows) {
        auto base = environment.get("APPDATA", "");
    } else {
        auto base = environment.get("XDG_STATE_HOME", expandTilde("~/.local/state"));
    }
    if (base.empty) return ".";

    auto dir = buildPath(base, "N64-Game-Plugins");
    try {
        mkdirRecurse(dir);
        return dir;
    } catch (Exception e) {
        warning("Can't create ", dir, ": ", e.message);
        return ".";
    }
}

abstract class Game(Config, State = NoState) : Plugin {
    string romName;
    string romHash;
    Config config;
    State state;
    bool stateError;

    // State block in the N64's memory (see PermanentHeap). The header is 8 words: magic (2), format version,
    // capacity, data length, data CRC32 and a write stamp (2) that changes on every write.
    enum STATE_MAGIC_1 = 0x4E363450; // "N64P"
    enum STATE_MAGIC_2 = 0x53544154; // "STAT"
    enum STATE_FORMAT = 2;                // 2: zlib-compressed JSON (1 was a custom binary format)
    enum STATE_HEADER_SIZE = 32;

    // Room for the State to grow by half before it needs a bigger block, in steps of 1 KB
    static uint stateBlockCapacity(size_t length) {
        return cast(uint)((length + length / 2 + 1023) / 1024 * 1024);
    }

    PermanentHeap permanentHeap;   // Set by games that support it; otherwise the State is only kept in the backup file
    bool stateInMemory;            // Whether permanentHeap is usable
    Address stateBlock;            // The block's address, or 0 if there isn't one yet
    uint stateCapacity;            // Data bytes the block can hold
    ulong stateStamp;              // Last stamp written to (or read from) the block
    uint stateCrc;                 // Last data CRC written to (or read from) the block
    bool stateAllocating;          // An allocation is in progress
    bool stateNeedsBiggerBlock;    // The State outgrew the block

    this(string romName, string romHash) {
        this.romName = romName;
        this.romHash = romHash;
    }

    void loadConfig() {
        config = loadJson!Config(romName ~ ".json");
        if (!config) config = new Config;
    }

    // The State's backup file, used when the State isn't in memory (e.g. when continuing a game from the game's
    // own save file rather than a save state). It's named after the ROM's header name and the start of its MD5,
    // so ROM hacks of the same game (which usually keep the header name) each get their own file.
    string stateFile;
    string stateBackupFile() {
        if (!stateFile) {
            import std.path : buildPath;
            import std.uni : isAlphaNum, toUpper;

            // Only characters that are safe in file names
            auto safe = (string s) => s.map!(c => (c.isAlphaNum || c == '-' || c == '_' || c == ' ') ? c : '_').to!string;
            auto name = safe(romName);
            auto hash = safe(romHash.take(8).to!string.toUpper);
            stateFile = buildPath(dataDirectory(), (hash.empty ? name : name ~ "-" ~ hash) ~ "-State.json");
        }
        return stateFile;
    }

    // Called whenever the State is (re)loaded, so games can update anything that refers into it
    void stateLoaded() { }

    void loadState() {
        static if (!is(State == NoState)) {
            state = loadJson!State(stateBackupFile());
            if (state) {
                stateError = false;
            } else {
                state = new State;
                stateError = true;
            }
            stateLoaded();
        }
    }

    void saveState() {
        static if (!is(State == NoState)) {
            if (!writeStateBlock()) return; // A save state was loaded, so the State was reloaded instead
            state.saveJson(stateBackupFile());
            stateError = false;
        }
    }

    static if (!is(State == NoState)) {
        bool inMemory(Address address, size_t size) {
            return address >= 0x80000000 && address + size <= 0x80000000 + memory.length && address % 4 == 0;
        }

        bool isHeapNode(Address node) {
            return inMemory(node, 16) && (node + 4).val!ubyte == 0xA5;
        }

        Address heapStart() {
            Address start = permanentHeap.heapPointer.val!uint;
            return isHeapNode(start) ? start : 0;
        }

        // Reads a State block, returning its data, or null if there's no valid block at the address
        const(ubyte)[] readStateBlock(Address block, out uint capacity, out ulong stamp, out uint crc) {
            import std.digest.crc : crc32Of;

            if (!inMemory(block, STATE_HEADER_SIZE)) return null;
            if (block.val!uint != STATE_MAGIC_1 || (block + 4).val!uint != STATE_MAGIC_2) return null;
            if ((block + 8).val!uint != STATE_FORMAT) return null;
            capacity = (block + 12).val!uint;
            auto length = (block + 16).val!uint;
            crc = (block + 20).val!uint;
            stamp = (cast(ulong)(block + 24).val!uint << 32) | (block + 28).val!uint;
            if (length == 0 || length > capacity || !inMemory(block, STATE_HEADER_SIZE + capacity)) return null;

            auto data = new ubyte[length];
            foreach (i, ref b; data) b = Ptr!ubyte(block + STATE_HEADER_SIZE + cast(uint)i)[0];
            auto check = crc32Of(data);
            if ((check[0] | check[1] << 8 | check[2] << 16 | check[3] << 24) != crc) return null;

            return data;
        }

        // Whether the block no longer holds what the plugin last wrote (i.e. a save state was loaded)
        bool stateBlockChanged() {
            Address block = stateBlock;
            return block.val!uint != STATE_MAGIC_1 || (block + 4).val!uint != STATE_MAGIC_2 ||
                   (block + 20).val!uint != stateCrc ||
                   (block + 24).val!uint != cast(uint)(stateStamp >> 32) || (block + 28).val!uint != cast(uint)stateStamp;
        }

        // Looks through the permanent heap's allocated blocks for a State block
        Address findStateBlock() {
            Address start = heapStart();
            if (!start) return 0;

            Address node = start;
            foreach (i; 0..100_000) {
                if (!isHeapNode(node)) return 0;
                uint capacity, crc;
                ulong stamp;
                if ((node + 5).val!ubyte && readStateBlock(node + 16, capacity, stamp, crc)) {
                    return node + 16;
                }
                node = (node + 12).val!uint;
                if (node == start) break;
            }
            return 0;
        }

        void writeBlock(Address block, uint capacity, const(ubyte)[] data) {
            import std.digest.crc : crc32Of;
            import std.datetime.systime : Clock;

            auto check = crc32Of(data);
            uint crc = check[0] | check[1] << 8 | check[2] << 16 | check[3] << 24;
            ulong stamp = max(cast(ulong)Clock.currStdTime, stateStamp + 1);

            foreach (i, b; data) Ptr!ubyte(block + STATE_HEADER_SIZE + cast(uint)i)[0] = b;
            (block +  0).val!uint = STATE_MAGIC_1;
            (block +  4).val!uint = STATE_MAGIC_2;
            (block +  8).val!uint = STATE_FORMAT;
            (block + 12).val!uint = capacity;
            (block + 16).val!uint = cast(uint)data.length;
            (block + 20).val!uint = crc;
            (block + 24).val!uint = cast(uint)(stamp >> 32);
            (block + 28).val!uint = cast(uint)stamp;

            stateCrc = crc;
            stateStamp = stamp;
        }

        void wipeStateBlock(Address block) {
            if (inMemory(block, 8)) block.val!uint = 0;
        }

        // Writes the State to its block. Returns false if a save state was loaded since the last write, in which
        // case the State is reloaded from memory instead (overwriting it would undo the loaded save state).
        bool writeStateBlock() {
            if (!stateInMemory || !stateBlock || stateAllocating) return true;

            if (stateBlockChanged()) {
                reloadStateFromMemory();
                return false;
            }

            auto data = packState(state);
            if (data.length > stateCapacity) {
                stateNeedsBiggerBlock = true; // A bigger block is made from the next game process
                return true;
            }

            writeBlock(stateBlock, stateCapacity, data);
            return true;
        }

        // Makes the State block at the address the plugin's State
        void useStateBlock(Address block) {
            uint capacity, crc;
            ulong stamp;
            auto data = readStateBlock(block, capacity, stamp, crc);
            if (!data) return;

            stateBlock = block;
            stateCapacity = capacity;
            stateStamp = stamp;
            stateCrc = crc;
            stateNeedsBiggerBlock = false;

            try {
                auto loaded = unpackState!State(data);
                if (loaded) state = loaded;
            } catch (Exception e) {
                error("Can't read the State in memory: ", e.classinfo.name, ": ", e.message);
            }

            stateLoaded();
            state.saveJson(stateBackupFile());
            stateError = false;
        }

        // A save state was loaded: switch to the State saved with it
        void reloadStateFromMemory() {
            uint capacity, crc;
            ulong stamp;
            Address block = readStateBlock(stateBlock, capacity, stamp, crc) ? stateBlock : findStateBlock();
            stateBlock = 0;

            // A save state made before the State was kept in memory has no block: keep the current State,
            // and a new block is made for it
            if (block) useStateBlock(block);
        }

        // Runs inside a game process (from HuPrcVSleep): finds or makes the State block when there isn't one,
        // and moves the State to a bigger block when it outgrows its block
        void maintainStateBlock() {
            if (!stateInMemory || stateAllocating) return;
            if (stateBlock && !stateNeedsBiggerBlock) return;

            // The hook is only safe if HuPrcVSleep starts with "addiu sp, sp, ..." (e.g. not on another ROM version)
            if ((permanentHeap.processSleep.val!uint & 0xFFFF0000) != 0x27BD0000) {
                warning("Unexpected code at ", permanentHeap.processSleep.to!string(16), "; the State is only kept in ", stateBackupFile());
                stateInMemory = false;
                return;
            }

            if (!heapStart()) return; // The heap isn't set up yet

            if (!stateBlock) {
                if (auto block = findStateBlock()) {
                    useStateBlock(block);
                    return;
                }
            }

            Address oldBlock = stateBlock;
            uint capacity = stateBlockCapacity(packState(state).length);

            stateAllocating = true;
            permanentHeap.alloc.jal(STATE_HEADER_SIZE + capacity, (ptr) {
                stateAllocating = false;

                if (!ptr || !inMemory(ptr, STATE_HEADER_SIZE + capacity)) {
                    warning("Not enough memory for the State; it is only kept in ", stateBackupFile());
                    stateInMemory = false;
                    return;
                }

                stateBlock = ptr;
                stateCapacity = capacity;
                stateNeedsBiggerBlock = false;
                writeBlock(ptr, capacity, packState(state));

                if (oldBlock) {
                    wipeStateBlock(oldBlock);
                    if (permanentHeap.free) permanentHeap.free.jal(oldBlock);
                }
            });
        }

        void setUpStateInMemory() {
            with (permanentHeap) {
                if (!heapPointer || !heapInit || !alloc || !processSleep) return;

                stateInMemory = true;

                // The heap is being (re)created (boot or reset), so the block is gone: a new one is made later
                heapInit.onExec({
                    if (stateBlock) wipeStateBlock(stateBlock);
                    stateBlock = 0;
                    stateAllocating = false;
                });

                processSleep.onExecDone({ maintainStateBlock(); });
            }
        }
    }

    void connect(string url) {
        spawn((Tid parentTid, URL url) {
            runTask({
                while (true) {
                    try {
                        auto ws = connectWebSocket(url);

                        synchronized (plugin) {
                            wsSender = runTask({
                                try {
                                    while (ws.connected) {
                                        ws.send(receiveOnly!string);
                                    }
                                } catch (Exception e) { }
                            });
                        }

                        while (ws.waitForData()) {
                            send(parentTid, ws.receiveText());
                        }
                    } catch (Exception e) { }

                    try { sleep(5.seconds); } catch (Exception e) { break; }
                }
            });

            runApplication();
        }, thisTid, URL(url));
    }

    void sendMessage(string msg) {
        synchronized (plugin) {
            if (wsSender) {
                send(wsSender, msg);
            }
        }
    }

    void sendMessage(JSONValue msg) {
        sendMessage(msg.toString(JSONOptions.doNotEscapeSlashes).lossyFloats());
    }

    void onStart() {
        try {
            loadConfig();
        } catch (Exception e) {
            auto msg = e.classinfo.name ~ ": " ~ e.message;
            error(msg);
            MessageBoxA(window, msg.toStringz, "loadConfig()", MB_ICONEXCLAMATION);
        }

        try {
            loadState();
        } catch (Exception e) {
            auto msg = e.classinfo.name ~ ": " ~ e.message;
            error(msg);
            MessageBoxA(window, msg.toStringz, "loadState()", MB_ICONEXCLAMATION);
        }

        static if (!is(State == NoState)) {
            setUpStateInMemory();
        }
    }
    void onInput(int, InputData*) { }
    void onMessage(string msg) { }
    void onFrame(ulong) {
        static if (!is(State == NoState)) {
            // A save state was loaded since the plugin last wrote the State
            if (stateInMemory && stateBlock && !stateAllocating && stateBlockChanged()) {
                reloadStateFromMemory();
            }
        }
    }
    void onFinish() {
        if (!stateError) {
            saveState();
        }
    }
}

void addAddress(Address addr) {
    addrMask[(addr & 0b111111111100000) >> 5] |= (1 << ((addr & 0b11100) >> 2));
}

void onExec(Address address, void delegate(Address) callback) {
    assert(address % 4 == 0);
    executeHandlers[address] ~= callback;
    addAddress(address);
}

void onExec(Address address, void delegate() callback) {
    onExec(address, (Address) { callback(); });
}

bool clearExec(Address address) {
    assert(address % 4 == 0);
    return executeHandlers.remove(address);
}

void onExecOnce(Address address, void delegate(Address) callback) {
    assert(address % 4 == 0);
    executeOnceHandlers[address] ~= callback;
    addAddress(address);
}

void onExecOnce(Address address, void delegate() callback) {
    onExecOnce(address, (Address) { callback(); });
}

bool clearExecOnce(Address address) {
    assert(address % 4 == 0);
    return executeOnceHandlers.remove(address);
}

void onExecDone(Address address, void delegate(Address) callback) {
    assert(address % 4 == 0);
    executeDoneHandlers[address] ~= callback;
    addAddress(address);
}

void onExecDone(Address address, void delegate() callback) {
    onExecDone(address, (Address) { callback(); });
}

bool clearExecDone(Address address) {
    assert(address % 4 == 0);
    return executeDoneHandlers.remove(address);
}

void onExecDoneOnce(Address address, void delegate(Address) callback) {
    assert(address % 4 == 0);
    executeDoneOnceHandlers[address] ~= callback;
    addAddress(address);
}

void onExecDoneOnce(Address address, void delegate() callback) {
    onExecDoneOnce(address, (Address) { callback(); });
}

bool clearExecDoneOnce(Address address) {
    assert(address % 4 == 0);
    return executeDoneOnceHandlers.remove(address);
}

void onRead(T)(ref T r, void delegate() callback)               { onRead!T(r, (ref T v, Address p, Address a) { callback(); }); }
void onRead(T)(ref T r, void delegate(ref T) callback)          { onRead!T(r, (ref T v, Address p, Address a) { callback(v); }); }
void onRead(T)(ref T r, void delegate(ref T, Address) callback) { onRead!T(r, (ref T v, Address p, Address a) { callback(v, p); }); }
void onRead(T)(ref T r, void delegate(ref T, Address, Address) callback) {
    handlers!(T.sizeof).read[r.addr] ~= (v, p, a) { callback(*cast(T*)v, p, a); };
    addAddress(r.addr);
}

void onWrite(T)(ref T r, void delegate() callback)               { onWrite!T(r, (ref T v, Address p, Address a) { callback(); }); }
void onWrite(T)(ref T r, void delegate(ref T) callback)          { onWrite!T(r, (ref T v, Address p, Address a) { callback(v); }); }
void onWrite(T)(ref T r, void delegate(ref T, Address) callback) { onWrite!T(r, (ref T v, Address p, Address a) { callback(v, p); }); }
void onWrite(T)(ref T r, void delegate(ref T, Address, Address) callback) {
    handlers!(T.sizeof).write[r.addr] ~= (v, p, a) { callback(*cast(T*)v, p, a); };
    addAddress(r.addr);
}

void jal(Address addr)                                                                   { jal(addr,  0,  0,  0,  0, (res) { }); }
void jal(Address addr,                                     void delegate()     callback) { jal(addr,  0,  0,  0,  0, (res) { callback(); }); }
void jal(Address addr,                                     void delegate(uint) callback) { jal(addr,  0,  0,  0,  0, callback); }
void jal(Address addr, uint a0)                                                          { jal(addr, a0,  0,  0,  0, (res) { }); }
void jal(Address addr, uint a0,                            void delegate()     callback) { jal(addr, a0,  0,  0,  0, (res) { callback(); }); }
void jal(Address addr, uint a0,                            void delegate(uint) callback) { jal(addr, a0,  0,  0,  0, callback); }
void jal(Address addr, uint a0, uint a1)                                                 { jal(addr, a0, a1,  0,  0, (res) { }); }
void jal(Address addr, uint a0, uint a1,                   void delegate()     callback) { jal(addr, a0, a1,  0,  0, (res) { callback(); }); }
void jal(Address addr, uint a0, uint a1,                   void delegate(uint) callback) { jal(addr, a0, a1,  0,  0, callback); }
void jal(Address addr, uint a0, uint a1, uint a2)                                        { jal(addr, a0, a1, a2,  0, (res) { }); }
void jal(Address addr, uint a0, uint a1, uint a2,          void delegate()     callback) { jal(addr, a0, a1, a2,  0, (res) { callback(); }); }
void jal(Address addr, uint a0, uint a1, uint a2,          void delegate(uint) callback) { jal(addr, a0, a1, a2,  0, callback); }
void jal(Address addr, uint a0, uint a1, uint a2, uint a3)                               { jal(addr, a0, a1, a2, a3, (res) { }); }
void jal(Address addr, uint a0, uint a1, uint a2, uint a3, void delegate()     callback) { jal(addr, a0, a1, a2, a3, (res) { callback(); }); }
void jal(Address addr, uint a0, uint a1, uint a2, uint a3, void delegate(uint) callback) {
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
        if (callback) {
            callback(v0);
        }
    });
}

Address[] searchMemory(immutable uint[] data) {
    auto mem = (cast(uint*)memory.ptr)[0..memory.length / uint.sizeof];
    ptrdiff_t[] result;
    ptrdiff_t start = 0;
    ptrdiff_t index;
    while (start < mem.length && (index = mem[start..$].countUntil(data)) != -1) {
        result ~= start + index;
        start += index + 1;
    }
    return result.map!(e => cast(Address)(0x80000000 + e * uint.sizeof)).array;
}

void info(T...)(T args) {
    msg(MsgLevel.INFO, args);
    version (Windows) { } else {
        stdout.writeln(args);
    }
}

void warning(T...)(T args) {
    msg(MsgLevel.WARNING, args);
    version (Windows) { } else {
        stderr.writeln(args);
    }
}

void error(T...)(T args) {
    msg(MsgLevel.ERROR, args);
    version (Windows) { } else {
        stderr.writeln(args);
    }
}

void msg(T...)(MsgLevel level, T args) {
    if (!debugCallback) return;

    string message;
    foreach (arg; args) {
        message ~= arg.to!string;
    }

    debugCallback(debugContext.toStringz, level, message.toStringz);
}

struct ExecutionInfo {
    void* window;
    const char* romName;
    const char* romHash;
    ubyte* addrMask;
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
    const(char)* name;
    Xoshiro256pp random;
    void* window;
    Plugin plugin;
    ubyte* addrMask;
    uint function() pc;
    void function(uint) jump;
    GPR* gpr;
    FPR* fpr;
    ubyte[] memory;
    void function() saveGameState;
    void function(int) setSaveStateSlot;
    ulong frame;
    InputData[4] input;
    Plugin function(string, string) pluginFactory;
    Task wsSender;
    void delegate(Address)[][Address] executeHandlers;
    void delegate(Address)[][Address] executeOnceHandlers;
    void delegate(Address)[][Address] executeDoneHandlers;
    void delegate(Address)[][Address] executeDoneOnceHandlers;
    template handlers(int S) {
        void delegate(void*, Address, Address)[][Address] read;
        void delegate(void*, Address, Address)[][Address] write;
    }
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

    export void RomOpen() {
        
    }

    export void RomClosed() {
        try {
            if (plugin) {
                plugin.onFinish();
                plugin = null;
            }
        } catch (Exception e) {
            error(e);
        }
    }

    export void InitiateExecution(ExecutionInfo ei) {
        try {
            info("Initializing...");
            random.seed(0);
            window = ei.window;
            addrMask = ei.addrMask;
            pc = ei.pc;
            jump = ei.jump;
            gpr = ei.gpr;
            fpr = ei.fpr;
            memory = ei.memory[0..ei.memorySize];
            saveGameState = ei.saveGameState;
            setSaveStateSlot = ei.setSaveStateSlot;
            frame = 0;
            input.each!((ref b) { b.value = 0; });
            executeHandlers.clear();
            executeOnceHandlers.clear();
            handlers!1.read.clear();
            handlers!2.read.clear();
            handlers!4.read.clear();
            handlers!8.read.clear();
            handlers!1.write.clear();
            handlers!2.write.clear();
            handlers!4.write.clear();
            handlers!8.write.clear();

            if (pluginFactory) {
                string romName = ei.romName.to!string().strip();
                string romHash = ei.romHash.to!string().strip();

                plugin = pluginFactory(romName, romHash);

                try { plugin.onStart(); }
                catch (Exception e) { error(e); }
            } else {
                plugin = null;
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
        if (plugin) {
            try {
                synchronized (plugin) {
                    if (wsSender) {
                        receiveTimeout(Duration.zero, (string msg) {
                            try {
                                plugin.onMessage(msg);
                            }
                            catch (Exception e) { error(e); }
                        });
                    }
                }
                
                plugin.onFrame(frame++);
            }
            catch (Exception e) { error(e); }
        }
    }

    export void Execute(Address pc) {
        // This address's one-time handlers are taken first: ones the handlers below add are for the next time it runs
        // (like jal()'s, which restores the registers when the call returns here)
        auto once = executeOnceHandlers.get(pc, null);
        if (once) executeOnceHandlers.remove(pc);

        if (auto handlers = (pc in executeHandlers)) {
            (*handlers).each!((h) {
                try { h(pc); }
                catch (Exception e) { error(e); }
            });
        }

        once.each!((h) {
            try { h(pc); }
            catch (Exception e) { error(e); }
        });
    }

    export void ExecuteDone(Address pc) {
        if (auto handlers = (pc in executeDoneHandlers)) {
            (*handlers).each!((h) {
                try { h(pc); }
                catch (Exception e) { error(e); }
            });
        }
        
        if (auto handlers = (pc in executeDoneOnceHandlers)) {
            executeDoneOnceHandlers.remove(pc);
            (*handlers).each!((h) {
                try { h(pc); }
                catch (Exception e) { error(e); }
            });
        }
    }

    void ReadHandler(int S)(void* value, Address pc, Address addr) {
        if (auto handlers = (addr in handlers!(S).read)) {
            (*handlers).each!((h) {
                try { h(value, pc, addr); }
                catch (Exception e) { error(e); }
            });
        }
    }

    void WriteHandler(int S)(void* value, Address pc, Address addr) {
        if (auto handlers = (addr in handlers!(S).write)) {
            (*handlers).each!((h) {
                try { h(value, pc, addr); }
                catch (Exception e) { error(e); }
            });
        }
    }

    export void Read8  (ubyte*  value, Address pc, Address addr) { ReadHandler !1(value, pc, addr); }
    export void Read16 (ushort* value, Address pc, Address addr) { ReadHandler !2(value, pc, addr); }
    export void Read32 (uint*   value, Address pc, Address addr) { ReadHandler !4(value, pc, addr); }
    export void Read64 (ulong*  value, Address pc, Address addr) { ReadHandler !8(value, pc, addr); }
    export void Write8 (ubyte*  value, Address pc, Address addr) { WriteHandler!1(value, pc, addr); }
    export void Write16(ushort* value, Address pc, Address addr) { WriteHandler!2(value, pc, addr); }
    export void Write32(uint*   value, Address pc, Address addr) { WriteHandler!4(value, pc, addr); }
    export void Write64(ulong*  value, Address pc, Address addr) { WriteHandler!8(value, pc, addr); }
}

version (Windows) {
    extern (Windows)
    BOOL DllMain(HINSTANCE hInstance, ULONG ulReason, LPVOID pvReserved) {
        switch (ulReason) {
            case DLL_PROCESS_ATTACH:
                dll_process_attach(hInstance, true);
                break;

            case DLL_PROCESS_DETACH:			
                dll_process_detach(hInstance, true);
                break;

            case DLL_THREAD_ATTACH:
                dll_thread_attach(true, true);
                break;

            case DLL_THREAD_DETACH:
                dll_thread_detach(true, true);
                break;

            default:
        }
        
        return true;
    }
}
