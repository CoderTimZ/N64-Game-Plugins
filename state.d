// The plugin's state as bytes.
//
// A game's state is its fields: the game object's, its players' and its features' (see game.d), plus the framework's
// few (the random generator, the latest input). The game keeps it in the N64's memory (see StateBlock in game.d), so
// the emulator's save states and the new netplay's rollback restore it with the game's own memory, and the netplay's
// desync check covers it.
//
// Every field is state except:
//   - const and immutable fields: settings, made with the game and never changed;
//   - fields labeled @Fixed: set once when the game is made, like references to its players or to the game's memory.
//     A class reference or a pointer has to be labeled (a compile error otherwise): what it points to isn't saved.
// A delegate can't be state at all (a compile error): what it would do belongs in a method.
//
// The bytes name each field, so the state of an older or newer version of a plugin still loads: a field the bytes
// don't have keeps its value, and one they have that the plugin doesn't (or with another type) is skipped.
//   number, enum, character, union  its bytes (an enum by its number)
//   array                           its length (uint), then its elements (a fixed-size array the same way)
//   associative array               its length (uint), then each key and value, in key order (the same bytes on every
//                                   machine)
//   struct, object                  its number of fields (ushort), then each field's name (ubyte length, characters),
//                                   its value's length in bytes (uint) and its value
module me.timz.n64.state;

import std.algorithm : sort;
import std.array : array;
import std.meta : AliasSeq, anySatisfy;
import std.traits;

enum Fixed;   // (see the module's description)
enum Session; // Belongs to the live session rather than the game (like the bingo cards): rollback restores it, but
              // loading a save state keeps what it is now

// The fields of an object, by class (the class's own, then its base classes')
template classesOf(T) {
    static if (is(T == Object)) alias classesOf = AliasSeq!();
    else alias classesOf = AliasSeq!(T, classesOf!(BaseClassesTuple!T[0]));
}

// Whether a struct's or class's field is state, and a compile error for a field that can't be
template isStateField(alias field) {
    alias T = typeof(field);
    enum fixed = hasUDA!(field, Fixed);
    enum isReference = is(T == class) || is(T == interface) || isPointer!T ||
                       (isArray!T && (is(ForeachType!T == class) || isPointer!(ForeachType!T)));
    static assert(!isDelegate!T && !isFunctionPointer!T || fixed, "A delegate can't be state (keep what it would do " ~
                  "in a method): " ~ __traits(identifier, field));
    static assert(!isReference || fixed || is(T == const) || is(T == immutable), "A class reference or a pointer " ~
                  "isn't saved: label it @Fixed if it's set once when the game is made (otherwise keep an index or " ~
                  "an address instead): " ~ __traits(identifier, field));
    enum isStateField = !fixed && !is(T == const) && !is(T == immutable);
}

enum isRaw(T) = isScalarType!T || isSomeChar!T || is(T == union);

struct StateWriter {
    ubyte[] data;

    void raw(const(void)[] bytes) { data ~= cast(const(ubyte)[])bytes; }

    void put(T)(ref const T value) {
        static if (isRaw!T) {
            raw((&value)[0 .. 1]);
        } else static if (isArray!T) {
            num(cast(uint)value.length);
            static if (isRaw!(ForeachType!T)) raw(value[]);
            else foreach (ref e; value) put(e);
        } else static if (isAssociativeArray!T) {
            num(cast(uint)value.length);
            foreach (k; value.keys.sort.array) {
                put(k);
                put(value[k]);
            }
        } else static if (is(T == struct)) {
            fields!T(value);
        } else {
            static assert(false, "Can't save a " ~ T.stringof);
        }
    }

    void num(U)(U value) if (isScalarType!U) { raw((&value)[0 .. 1]); }

    // A struct's fields, or a class's (all of them, its base classes' too)
    void fields(T)(auto ref const T value) {
        static if (is(T == class)) alias parts = classesOf!T;
        else alias parts = AliasSeq!T;

        ushort count;
        auto countAt = data.length;
        num(count);
        static foreach (C; parts) {
            static foreach (i; 0 .. C.tupleof.length) {
                static if (isStateField!(C.tupleof[i])) {{
                    enum name = __traits(identifier, C.tupleof[i]);
                    num(cast(ubyte)name.length);
                    raw(name);
                    auto lengthAt = data.length;
                    num(uint.init);
                    static if (is(T == class)) put((cast(const C)value).tupleof[i]);
                    else put(value.tupleof[i]);
                    *cast(uint*)&data[lengthAt] = cast(uint)(data.length - lengthAt - uint.sizeof);
                    count++;
                }}
            }
        }
        *cast(ushort*)&data[countAt] = count;
    }
}

class StateFormatError : Exception {
    this() { super("The state's bytes don't fit its fields"); }
}

struct StateReader {
    const(ubyte)[] data;
    bool keepSession; // Leave @Session fields as they are (loading a save state)

    const(ubyte)[] raw(size_t n) {
        if (n > data.length) throw new StateFormatError;
        auto bytes = data[0 .. n];
        data = data[n .. $];
        return bytes;
    }

    U read(U)() if (isScalarType!U) { return *cast(const U*)raw(U.sizeof).ptr; }

    void get(T)(ref T value) {
        static if (isRaw!T) {
            (cast(ubyte*)&value)[0 .. T.sizeof] = raw(T.sizeof);
        } else static if (isStaticArray!T) {
            auto n = read!uint;
            foreach (i; 0 .. n) {
                if (i < value.length) get(value[i]);
                else { ForeachType!T skipped; get(skipped); }
            }
        } else static if (isDynamicArray!T) {
            alias E = Unqual!(ForeachType!T);
            auto n = read!uint;
            static if (isRaw!E) {
                if (n > data.length / E.sizeof) throw new StateFormatError;
                value = cast(T)(cast(const(E)[])raw(n * E.sizeof)).dup;
            } else {
                if (n > data.length) throw new StateFormatError;
                auto elements = new E[n];
                foreach (ref e; elements) get(e);
                value = cast(T)elements;
            }
        } else static if (isAssociativeArray!T) {
            auto n = read!uint;
            if (n > data.length) throw new StateFormatError;
            T result;
            foreach (i; 0 .. n) {
                Unqual!(KeyType!T) k;
                ValueType!T v;
                get(k);
                get(v);
                result[k] = v;
            }
            value = result;
        } else static if (is(T == struct)) {
            fields(value);
        }
    }

    void fields(T)(ref T value) {
        static if (is(T == class)) alias parts = classesOf!T;
        else alias parts = AliasSeq!T;

        auto count = read!ushort;
        foreach (f; 0 .. count) {
            auto name = cast(const(char)[])raw(read!ubyte);
            auto bytes = raw(read!uint);
            field: switch (name) {
                static foreach (C; parts) {
                    static foreach (i; 0 .. C.tupleof.length) {
                        static if (isStateField!(C.tupleof[i])) {
                            case __traits(identifier, C.tupleof[i]): {
                                static if (hasUDA!(C.tupleof[i], Session)) {
                                    if (keepSession) break field;
                                }
                                // the value as a whole, or not at all (its type changed)
                                typeof(C.tupleof[i]) v;
                                auto r = StateReader(bytes, keepSession);
                                try {
                                    r.get(v);
                                } catch (StateFormatError) {
                                    break field;
                                }
                                if (r.data.length) break field;
                                static if (is(T == class)) (cast(C)value).tupleof[i] = v;
                                else value.tupleof[i] = v;
                                break field;
                            }
                        }
                    }
                }
                default: // a field this version doesn't have
            }
        }
    }
}

// For each game module: a compile error for any mutable module variable (state outside the game's objects, which the
// state block doesn't hold). Thread-local and __gshared ones alike; immutable and const ones are fine.
mixin template NoMutableGlobals() {
    import std.traits : isSomeFunction;
    static foreach (name; __traits(allMembers, mixin(__MODULE__))) {
        static if (__traits(compiles, &__traits(getMember, mixin(__MODULE__), name)) &&
                   !isSomeFunction!(__traits(getMember, mixin(__MODULE__), name)) &&
                   !is(typeof(__traits(getMember, mixin(__MODULE__), name)) == immutable) &&
                   !is(typeof(__traits(getMember, mixin(__MODULE__), name)) == const)) {
            static assert(false, __MODULE__ ~ "." ~ name ~ " is a mutable global: state belongs in the game's objects " ~
                                 "(the state block holds only those), or make it immutable");
        }
    }
}
