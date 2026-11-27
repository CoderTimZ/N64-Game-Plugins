// Helpers that don't need the emulator: random numbers and shuffles, and reading and writing JSON (the settings
// files and the bingo site's messages).
module me.timz.n64.util;

import std.algorithm;
import std.conv;
import std.json;
import std.random;
import std.range;
import std.string;
import std.traits;

ulong flip(ulong value) pure nothrow @nogc @safe {
    import core.bitop;
    return ror(value, 32);
}

double fixRoundingError(double x) pure nothrow @nogc @safe {
    auto f = cast(float)x;
    return f == cast(long)f ? f : x;
}

// JSON text for a value, laid out as std.json's toString/toPrettyString do (sorted keys, the same escaping), but with
// floats written as D writes them (0.333, 2) rather than std.json's 18 significant digits (0.333000000000000018).
string toJSONText(const JSONValue value, bool pretty = false) {
    import std.array : appender;
    import std.math.traits : isFinite;

    auto json = appender!string;
    void put(const JSONValue v, size_t indent) {
        void newLine(size_t level) {
            if (!pretty) return;
            json.put('\n');
            foreach (i; 0..level) json.put("    ");
        }
        final switch (v.type) {
            case JSONType.object:
                auto obj = v.objectNoRef;
                if (obj.length == 0) { json.put("{}"); break; }
                json.put('{');
                foreach (i, key; obj.keys.sort.release) {
                    if (i) json.put(',');
                    newLine(indent + 1);
                    json.put(JSONValue(key).toString(JSONOptions.doNotEscapeSlashes));
                    json.put(pretty ? ": " : ":");
                    put(obj[key], indent + 1);
                }
                newLine(indent);
                json.put('}');
                break;
            case JSONType.array:
                auto arr = v.arrayNoRef;
                if (arr.length == 0) { json.put("[]"); break; }
                json.put('[');
                foreach (i, element; arr) {
                    if (i) json.put(',');
                    newLine(indent + 1);
                    put(element, indent + 1);
                }
                newLine(indent);
                json.put(']');
                break;
            case JSONType.float_:
                if (!v.floating.isFinite) throw new JSONException("Can't write " ~ v.floating.to!string ~ " in JSON");
                json.put(v.floating.to!string);
                break;
            case JSONType.string:
            case JSONType.integer:
            case JSONType.uinteger:
            case JSONType.true_:
            case JSONType.false_:
            case JSONType.null_:
                json.put(v.toString(JSONOptions.doNotEscapeSlashes));
                break;
        }
    }
    put(value, 0);
    return json.data;
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
        default:
            throw new JSONException("expected " ~ (is(T == bool) ? "true, false or a number" : "a number") ~ ", not " ~
                                    (scl.type == JSONType.null_ ? "null" : "a " ~ scl.type.to!string.stripRight("_")));
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
// A field's value, with errors saying which field they're in (for a config file's options)
T fromJSONField(T)(const JSONValue value, string field) {
    try {
        return value.fromJSON!T;
    } catch (Exception e) {
        throw new JSONException(field ~ ": " ~ e.msg);
    }
}

T fromJSON(T)(const JSONValue obj) if (is(T == struct)) {
    T result;
    foreach (i, ref v; result.tupleof) {
        auto k = __traits(identifier, result.tupleof[i]);
        if (auto value = k in obj) {
            v = (*value).fromJSONField!(typeof(v))(k);
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
            v = (*value).fromJSONField!(typeof(v))(k);
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

// One of the options, picked with the odds of its weight. The options are taken in their sorted order (and their
// weights added up in it), not the associative array's, which can differ between machines with the same options (it
// depends on the order they were added in): a netplay game picks the same on every machine.
T weighted(T, W, Random)(ref const W[T] options, ref Random r) {
    auto keys = options.keys.sort.release;
    double total = 0;
    foreach (e; keys) total += options[e];
    double random = r.uniform01() * total;
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
