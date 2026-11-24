/*
 * Widescreen for Mario Party 3 (US): the game draws a 424x240 picture (16:9 when stretched) instead of 320x240.
 *
 * This is an adaptation of gamemasterplc's widescreen patch for Mario Party 3
 * (https://www.youtube.com/watch?v=DME9IiB77fg), licensed under the Creative Commons Attribution license
 * (CC BY 3.0, https://creativecommons.org/licenses/by/3.0/). The patch changes the ROM; this module makes the same
 * changes to the game as it runs: the values the patch changed are changed as the game loads its code (the tables at
 * the end), the code it rewrote is done by hooks (setUpHooks()), and the background images it widened are widened from
 * the game's own images as they're loaded. What's different from the patch:
 *
 * - Memory: the patch puts the framebuffers and the depth buffer in the Expansion Pak's memory, where custom boards made
 *   with PartyPlanner64 keep their main heap (0x80400000 to 0x807B0000, with their own code after it). Here the
 *   framebuffers stay where the game had them (they fit), the main heap is at 0x80400000 for the original game too (the
 *   patch made it bigger where it was instead), it's 0x40000 smaller (0x370000, still twice the original game's), and the
 *   depth buffer and the board arrays the patch enlarged go after it, from 0x80770000 to about 0x807A4000.
 * - Fixed: some of the patch's changes landed on the instruction next to the intended one, or used the wrong register,
 *   which broke a store, a call or a load there. They're made where they were meant to be (marked "fixed").
 * - The patch's changes to ROM offsets (its bigger file system moved the data after it) and two changes that aren't for
 *   widescreen (it removed a hang at 0x8000C2C0 and a branch at 0x8004FD50) aren't made.
 * - Added: a few values the patch missed (marked "Added"), like where an item being bought goes on the screen.
 * - Custom boards: their own overlay (which replaces a board's) gets the patch's changes to the code and data it shares
 *   with the original boards' (like the item shops), found by signatures since they're somewhere else in each.
 */
module me.timz.n64.mp3widescreen;

import me.timz.n64.plugin;
import std.algorithm;
import std.array;
import std.conv;
import std.range;

// The screen
enum int SCREEN_WIDTH     = 424;
enum int SCREEN_HEIGHT    = 240;
enum int OLD_SCREEN_WIDTH = 320;
enum int MORE = SCREEN_WIDTH - OLD_SCREEN_WIDTH; // 104: the extra width (what moves a right-aligned position)
enum int HALF = MORE / 2;                        // 52: half of it (what moves a centered position)
enum double ASPECT = cast(double)SCREEN_WIDTH / SCREEN_HEIGHT; // The cameras' aspect ratio (4:3 before)

// A width or X position scaled to the wider screen
int scaled(int x) { return x < 0 ? -scaled(-x) : (x * SCREEN_WIDTH + OLD_SCREEN_WIDTH / 2) / OLD_SCREEN_WIDTH; }
double scaled(double x) { return x * SCREEN_WIDTH / OLD_SCREEN_WIDTH; }

// Memory
enum uint    FRAMEBUFFER_SIZE = SCREEN_WIDTH * SCREEN_HEIGHT * 2;  // 16-bit color
enum Address FRAMEBUFFERS     = 0x80360000;                       // Three, where the game's 320-wide ones were (to 0x803F5100)
enum Address MAIN_HEAP        = 0x80400000;                       // Where custom boards have it too
enum uint    MAIN_HEAP_SIZE   = 0x370000;                         // Custom boards' is 0x3B0000, followed by their code
enum Address DEPTH_BUFFER     = MAIN_HEAP + MAIN_HEAP_SIZE;       // 0x80770000
enum Address BOARD_ARRAYS     = DEPTH_BUFFER + FRAMEBUFFER_SIZE;  // 0x807A1B00: the board arrays the patch enlarged (to about 0x807A4000)

ushort hi(uint x) { return cast(ushort)((x + 0x8000) >> 16); } // For "lui" with an "addiu" (or a signed offset) after it
short  lo(uint x) { return cast(short)x; }

// A change to a word of the game's code or data: where (word & mask) is `from`, it becomes `to`
struct Change {
    Address address;
    uint mask;
    uint from;
    uint to;
}

// An instruction's 16-bit immediate (or a load or store's offset)
Change[] I(Address a, int from, int to) {
    assert(from >= short.min && from <= ushort.max && to >= short.min && to <= ushort.max);
    return [Change(a, 0xFFFF, from & 0xFFFF, to & 0xFFFF)];
}

// A "lui" of a float's upper half (the lower half being 0). The new value is rounded to what a "lui" can make.
Change[] F(Address a, double from, double to) {
    return [Change(a, 0xFFFF, floatHi(from), cast(ushort)((bits(cast(float)to) + 0x8000) >> 16))];
}

// A 32-bit constant made by "lui" (at `h`) and "ori" (at `l`)
Change[] K(Address h, Address l, uint from, uint to) {
    return [Change(h, 0xFFFF, from >> 16, to >> 16), Change(l, 0xFFFF, from & 0xFFFF, to & 0xFFFF)];
}
Change[] KF(Address h, Address l, double from, double to) { return K(h, l, bits(cast(float)from), bits(cast(float)to)); }

// A shift's amount (sll, srl, sra)
Change[] S(Address a, int from, int to) { return [Change(a, 0x7C0, from << 6, to << 6)]; }

// An instruction's opcode
enum Opcode : uint { BEQ = 4, BLEZ = 6 }
alias BEQ = Opcode.BEQ;
alias BLEZ = Opcode.BLEZ;
Change[] O(Address a, Opcode from, Opcode to) { return [Change(a, 0xFC000000, from << 26, to << 26)]; }

// Data: a 16-bit value, a 32-bit value, a float and a double
Change[] H(Address a, int from, int to) {
    auto shift = (a & 2) ? 0 : 16;
    return [Change(a & ~3, 0xFFFFu << shift, (from & 0xFFFF) << shift, (to & 0xFFFF) << shift)];
}
Change[] W(Address a, uint from, uint to) { return [Change(a, 0xFFFFFFFF, from, to)]; }
Change[] DF(Address a, double from, double to) { return W(a, bits(cast(float)from), bits(cast(float)to)); }
Change[] DD(Address a, double from, double to) {
    auto f = bits(from), t = bits(to);
    return W(a, cast(uint)(f >> 32), cast(uint)(t >> 32)) ~ W(a + 4, cast(uint)f, cast(uint)t);
}

uint bits(float f) { return *cast(uint*)&f; }
ulong bits(double d) { return *cast(ulong*)&d; }
ushort floatHi(double d) {
    auto b = bits(cast(float)d);
    assert((b & 0xFFFF) == 0, "Not a lui float: " ~ d.to!string);
    return cast(ushort)(b >> 16);
}

// A value moved for the wider screen, at each of `at`: + `amount` (shift), or scaled by 424/320 (scale)
enum Kind : ubyte {
    IMM,    // An instruction's 16-bit immediate (or a load or store's offset)
    LUI,    // A "lui" of a float's upper half (rounded to what a "lui" can make)
    SHORT,  // Data: 16 bits (at the address, or at +2)
    FLOAT,  // Data: a float
    DOUBLE  // Data: a double
}
alias IMM = Kind.IMM, LUI = Kind.LUI, SHORT = Kind.SHORT, FLOAT = Kind.FLOAT, DOUBLE = Kind.DOUBLE;

struct Move {
    Kind kind;
    bool scale;
    int amount;
    const(Address)[] at;
}

Move shift(int amount, Kind kind, Address[] at...) { return Move(kind, false, amount, at.dup); }
Move scale(Kind kind, Address[] at...) { return Move(kind, true, 0, at.dup); }

// The changes to an overlay (or the main code): the values moved by rules, and the changes the patch chose values for
// (each made where the word is still what the US ROM has). An overlay's code and data are loaded separately (the board
// code's sometimes one without the other), so each has a CRC-32 (of its words, big-endian): a part's changes are made
// when it's loaded, if its CRC is the US ROM's (not to an overlay a custom board replaced).
struct Patch {
    uint overlay;
    uint codeCrc;  // The main code's (its data has no CRC: it's checked with the code)
    uint dataCrc;
    const(Move)[] moves;
    const(Change)[] changes;
}

enum uint MAIN = uint.max;

float  toFloat(uint b)   { return *cast(float*)&b; }
double toDouble(ulong b) { return *cast(double*)&b; }

void apply(const Move m, Address a) {
    final switch (m.kind) {
        case IMM: {
            auto w = a.val!uint, op = w >> 26;
            int v = op >= 0xC && op <= 0xE ? w & 0xFFFF : cast(short)w; // andi, ori, xori: unsigned
            v = m.scale ? scaled(v) : v + m.amount;
            a.val!uint = (w & 0xFFFF0000) | (v & 0xFFFF);
            break;
        }
        case LUI: {
            auto w = a.val!uint;
            double v = toFloat((w & 0xFFFF) << 16);
            v = m.scale ? scaled(v) : v + m.amount;
            a.val!uint = (w & 0xFFFF0000) | ((bits(cast(float)v) + 0x8000) >> 16);
            break;
        }
        case SHORT: {
            auto word = a & ~3, at = (a & 2) ? 0 : 16, w = word.val!uint;
            int v = cast(short)(w >> at);
            v = m.scale ? scaled(v) : v + m.amount;
            word.val!uint = (w & ~(0xFFFFu << at)) | ((v & 0xFFFF) << at);
            break;
        }
        case FLOAT: {
            double v = toFloat(a.val!uint);
            v = m.scale ? scaled(v) : v + m.amount;
            a.val!uint = bits(cast(float)v);
            break;
        }
        case DOUBLE: {
            double v = toDouble(cast(ulong)a.val!uint << 32 | (a + 4).val!uint);
            v = m.scale ? scaled(v) : v + m.amount;
            auto b = bits(v);
            a.val!uint = cast(uint)(b >> 32);
            (a + 4).val!uint = cast(uint)b;
            break;
        }
    }
}

// Makes the patch's changes at the addresses `where` allows
void apply(const Patch p, scope bool delegate(Address) where = null) {
    foreach (m; p.moves) foreach (a; m.at) if (!where || where(a)) apply(m, a);
    foreach (c; p.changes) {
        if (where && !where(c.address)) continue;
        auto w = c.address.val!uint;
        if ((w & c.mask) == c.from) c.address.val!uint = (w & ~c.mask) | c.to;
    }
}

// CRC-32 of memory's words (big-endian, as in the ROM), with the words in `skip` counted as 0
uint crc(Address start, Address end, const(Address[2])[] skip = null) {
    import std.digest.crc : crc32Of;
    auto bytes = new ubyte[end - start];
    for (Address a = start; a < end; a += 4) {
        uint w = skip.any!(r => a >= r[0] && a < r[1]) ? 0 : a.val!uint;
        auto i = a - start;
        bytes[i] = cast(ubyte)(w >> 24); bytes[i + 1] = cast(ubyte)(w >> 16);
        bytes[i + 2] = cast(ubyte)(w >> 8); bytes[i + 3] = cast(ubyte)w;
    }
    auto c = crc32Of(bytes);
    return c[0] | c[1] << 8 | c[2] << 16 | c[3] << 24;
}

// Custom boards made with PartyPlanner64 replace a board's overlay with their own, which has much of the original boards'
// code and data (like the item shops), assembled somewhere else. The patch's changes to those are found by signatures,
// made from the original boards: for code, a CRC-32 of the instruction and the 4 on each side, with what assembling
// somewhere else changes (jump and branch targets, and addresses in the overlay) left out; for data, CRC-32s of the
// word and the 6 before it, and of it and the 6 after it (either matching). Each also has the word as the original
// boards have it, and the change.
struct Signature {
    uint crc;
    uint word;
    Move move;
}

struct DataSignature {
    uint before;
    uint after;
    uint word;
    Move move;
}

enum CODE_REACH = 4;
enum DATA_REACH = 6;

immutable Signature[] BOARD_CODE = [
    Signature(0xD97FF3A2, 0x240600A0, shift(HALF, IMM)), // Chilly Waters 0x8010C088: li a2,160
    Signature(0x18BB4AD0, 0x240600A0, shift(HALF, IMM)), // Chilly Waters 0x8010C438: li a2,160
    Signature(0x359DDD49, 0x240600A0, shift(HALF, IMM)), // Chilly Waters 0x8010C4A0: li a2,160
    Signature(0xD8186D99, 0x3C014320, shift(HALF, LUI)), // Chilly Waters 0x80113BA0: lui at,0x4320
    Signature(0xE0EC31E7, 0x3C014320, shift(HALF, LUI)), // Chilly Waters 0x80113F74: lui at,0x4320
    Signature(0x7EE04C82, 0x240600A0, shift(HALF, IMM)), // Chilly Waters 0x80113F8C: li a2,160
    Signature(0x3ACD5FAE, 0x3C014302, shift(HALF, LUI)), // Chilly Waters 0x80114018: lui at,0x4302
    Signature(0x42F7EC57, 0x240600A0, shift(HALF, IMM)), // Chilly Waters 0x8011402C: li a2,160
    Signature(0x8B4543C0, 0x3C01433E, shift(HALF, LUI)), // Chilly Waters 0x80114058: lui at,0x433e
    Signature(0x34956F7E, 0x240600A0, shift(HALF, IMM)), // Chilly Waters 0x80114070: li a2,160
    Signature(0x5F6F10B5, 0x3C0142DC, shift(HALF, LUI)), // Chilly Waters 0x80114150: lui at,0x42dc
    Signature(0x50AA2101, 0x240600A0, shift(HALF, IMM)), // Chilly Waters 0x80114168: li a2,160
    Signature(0x687265AF, 0x3C014352, shift(HALF, LUI)), // Chilly Waters 0x80114194: lui at,0x4352
    Signature(0x62B5588D, 0x3C014320, shift(HALF, LUI)), // Chilly Waters 0x801141D0: lui at,0x4320
    Signature(0x4F8BED9D, 0x240600A0, shift(HALF, IMM)), // Chilly Waters 0x801141E8: li a2,160
    Signature(0x4ABBE9EC, 0x240600B1, shift(HALF, IMM)), // Chilly Waters 0x80115618: li a2,177
    Signature(0xFEAC54D4, 0x2406007A, shift(HALF, IMM)), // Chilly Waters 0x8011563C: li a2,122
    Signature(0x388F20FE, 0x240600A0, shift(HALF, IMM)), // Chilly Waters 0x8011565C: li a2,160
    Signature(0x691676D1, 0x3C014320, shift(HALF, LUI)), // Chilly Waters 0x80115E00: lui at,0x4320
    Signature(0xDFE1ABE3, 0x3C01434B, shift(HALF, LUI)), // Chilly Waters 0x80115E94: lui at,0x434b
    Signature(0xC66645CF, 0x240600A0, shift(HALF, IMM)), // Chilly Waters 0x80116228: li a2,160
    Signature(0x639A66A6, 0x240600A0, shift(HALF, IMM)), // Chilly Waters 0x80119F28: li a2,160
    Signature(0x1AD221F0, 0x24040066, shift(HALF, IMM)), // Deep Bloober Sea 0x8011A3CC: li a0,102
    Signature(0xF3240DF9, 0x2404005A, shift(HALF, IMM)), // Woody Woods 0x80118804: li a0,90
    Signature(0xB7EA016C, 0x2404003C, shift(HALF, IMM)), // Gate Guy 0x8010F230: li a0,60
    Signature(0xFFDDF105, 0x2405003C, shift(HALF, IMM)), // Gate Guy 0x8010F474: li a1,60
    Signature(0xA4FE5682, 0x240600A0, shift(HALF, IMM)), // Gate Guy 0x801139BC: li a2,160
    Signature(0xF03C8BBA, 0x240600A0, shift(HALF, IMM)), // Gate Guy 0x80113ADC: li a2,160
    Signature(0xC97F06A4, 0x240600A0, shift(HALF, IMM)), // Gate Guy 0x80113BD0: li a2,160
    Signature(0x2961161F, 0x240600A0, shift(HALF, IMM)), // Gate Guy 0x80113C00: li a2,160
];

immutable DataSignature[] BOARD_DATA = [
    DataSignature(0xBD878614, 0x9DD39B36, 0x43740000, shift(MORE, FLOAT)), // Chilly Waters 0x8011E204: 244
    DataSignature(0x7BBB68E7, 0x97772CA9, 0x43240000, shift(HALF, FLOAT)), // Chilly Waters 0x8011E354: 164
    DataSignature(0x18D276DA, 0xF475F832, 0x430C0000, shift(HALF, FLOAT)), // Chilly Waters 0x8011E35C: 140
    DataSignature(0xA87AB44C, 0x7EF72BD9, 0x43240000, shift(HALF, FLOAT)), // Chilly Waters 0x8011E364: 164
    DataSignature(0x97772CA9, 0xA556404D, 0x430C0000, shift(HALF, FLOAT)), // Chilly Waters 0x8011E36C: 140
    DataSignature(0xF475F832, 0xD3572752, 0x43040000, shift(HALF, FLOAT)), // Chilly Waters 0x8011E374: 132
    DataSignature(0x7EF72BD9, 0x03107DBE, 0x435C0000, shift(HALF, FLOAT)), // Chilly Waters 0x8011E37C: 220
    DataSignature(0xA556404D, 0x469A03F9, 0x43040000, shift(HALF, FLOAT)), // Chilly Waters 0x8011E384: 132
    DataSignature(0xD3572752, 0x25E8A97B, 0x435C0000, shift(HALF, FLOAT)), // Chilly Waters 0x8011E38C: 220
    DataSignature(0x03107DBE, 0x2E72F488, 0x43240000, shift(HALF, FLOAT)), // Chilly Waters 0x8011E394: 164
    DataSignature(0x469A03F9, 0x2E72F488, 0x43240000, shift(HALF, FLOAT)), // Chilly Waters 0x8011E39C: 164
    DataSignature(0x25E8A97B, 0x8E0C0232, 0x43240000, shift(HALF, FLOAT)), // Chilly Waters 0x8011E3A4: 164
    DataSignature(0x2E72F488, 0x8F9B3499, 0x43240000, shift(HALF, FLOAT)), // Chilly Waters 0x8011E3AC: 164
    DataSignature(0x2E72F488, 0x8E0C5060, 0x43240000, shift(HALF, FLOAT)), // Chilly Waters 0x8011E3B4: 164
    DataSignature(0x8E0C0232, 0xCA839152, 0x43240000, shift(HALF, FLOAT)), // Chilly Waters 0x8011E3BC: 164
    DataSignature(0x8F9B3499, 0x22C53869, 0x43240000, shift(HALF, FLOAT)), // Chilly Waters 0x8011E3C4: 164
    DataSignature(0x8E0C5060, 0x4752B541, 0x43240000, shift(HALF, FLOAT)), // Chilly Waters 0x8011E3CC: 164
    DataSignature(0xB009892F, 0xC943039D, 0x43740000, shift(MORE, FLOAT)), // Deep Bloober Sea 0x8011D5B0: 244
    DataSignature(0x4FF5A422, 0x97772CA9, 0x43240000, shift(HALF, FLOAT)), // Deep Bloober Sea 0x8011D710: 164
    DataSignature(0x40DABF2C, 0xF475F832, 0x430C0000, shift(HALF, FLOAT)), // Deep Bloober Sea 0x8011D718: 140
    DataSignature(0x666528A2, 0x0A2AF306, 0x43200000, shift(HALF, FLOAT)), // Deep Bloober Sea 0x8011EB34: 160
    DataSignature(0xEF8D3904, 0xC943039D, 0x43740000, shift(MORE, FLOAT)), // Spiny Desert 0x8011D0EC: 244
    DataSignature(0x0584F188, 0x97772CA9, 0x43240000, shift(HALF, FLOAT)), // Spiny Desert 0x8011D24C: 164
    DataSignature(0xD8871CF4, 0xF475F832, 0x430C0000, shift(HALF, FLOAT)), // Spiny Desert 0x8011D254: 140
    DataSignature(0x7EDCBAA0, 0xC943039D, 0x43740000, shift(MORE, FLOAT)), // Woody Woods 0x8011C6A4: 244
    DataSignature(0xCB41C1F0, 0x97772CA9, 0x43240000, shift(HALF, FLOAT)), // Woody Woods 0x8011C804: 164
    DataSignature(0x1851EA3E, 0xF475F832, 0x430C0000, shift(HALF, FLOAT)), // Woody Woods 0x8011C80C: 140
    DataSignature(0x3F9FC647, 0xC943039D, 0x43740000, shift(MORE, FLOAT)), // Creepy Cavern 0x8011EB54: 244
    DataSignature(0x286ED2B4, 0x97772CA9, 0x43240000, shift(HALF, FLOAT)), // Creepy Cavern 0x8011ECB4: 164
    DataSignature(0x7A3EAA96, 0xF475F832, 0x430C0000, shift(HALF, FLOAT)), // Creepy Cavern 0x8011ECBC: 140
    DataSignature(0x675D7509, 0xC943039D, 0x43740000, shift(MORE, FLOAT)), // Waluigi's Island 0x8011C8E4: 244
    DataSignature(0x8B565F5B, 0x97772CA9, 0x43240000, shift(HALF, FLOAT)), // Waluigi's Island 0x8011CA44: 164
    DataSignature(0x16A176EF, 0xF475F832, 0x430C0000, shift(HALF, FLOAT)), // Waluigi's Island 0x8011CA4C: 140
    DataSignature(0x6AFC6DA3, 0x0E95A45E, 0x00A0FFB0, shift(HALF, SHORT)), // Gate Guy 0x80118F60: (160, -80)
    DataSignature(0xF4F4C9B3, 0x0BD2476C, 0x00A0FF60, shift(HALF, SHORT)), // Gate Guy 0x80118F64: (160, -160)
    DataSignature(0x47211FC6, 0xE97CE725, 0x00A0FFB0, shift(HALF, SHORT)), // Gate Guy 0x80118F68: (160, -80)
];

// An instruction without what assembling it somewhere else changes
uint unplaced(uint w) {
    auto op = w >> 26;
    if (op == 2 || op == 3) return w & 0xFC000000;                                     // j, jal
    if (op == 1 || (op >= 4 && op <= 7) || (op >= 0x14 && op <= 0x17)) return w & 0xFFFF0000; // Branches
    if (op == 0x11 && ((w >> 21) & 31) == 8) return w & 0xFFFF0000;                    // bc1f, bc1t
    if (op == 0xF && isOverlayHi(w & 0xFFFF)) return w & 0xFFFF0000;                    // lui of an address
    return w;
}

bool isOverlayHi(uint hi) { return hi >= 0x8008 && hi <= 0x8013; }

// unplaced() of each instruction, and the lower halves of the addresses made by a "lui" (in the next 5 instructions,
// from its register)
uint[] unplaced(const uint[] code) {
    auto result = code.map!(w => unplaced(w)).array;
    foreach (i, w; code) {
        if (w >> 26 != 0xF || !isOverlayHi(w & 0xFFFF)) continue;
        auto register = (w >> 16) & 31;
        foreach (k; 1..6) {
            if (i + k >= code.length) break;
            auto x = code[i + k], op = x >> 26;
            if (((x >> 21) & 31) == register && [9, 0xD, 0x20, 0x21, 0x23, 0x24, 0x25, 0x28, 0x29, 0x2B, 0x31, 0x35, 0x39, 0x3D].canFind(op)) {
                result[i + k] = x & 0xFFFF0000;
            }
        }
    }
    return result;
}

uint crcOf(const uint[] words) {
    import std.digest.crc : crc32Of;
    auto bytes = new ubyte[words.length * 4];
    foreach (i, w; words) {
        bytes[4 * i] = cast(ubyte)(w >> 24); bytes[4 * i + 1] = cast(ubyte)(w >> 16);
        bytes[4 * i + 2] = cast(ubyte)(w >> 8); bytes[4 * i + 3] = cast(ubyte)w;
    }
    auto c = crc32Of(bytes);
    return c[0] | c[1] << 8 | c[2] << 16 | c[3] << 24;
}

uint[] words(Address start, Address end) {
    uint[] result;
    for (Address a = start; a < end; a += 4) result ~= a.val!uint;
    return result;
}

// Makes the patch's changes in a custom board's code (from `start` to `end`) or data, where the signatures are found
// (all found first, then changed)
void applySignatures(Address start, Address end, bool code) {
    auto ws = words(start, end);
    Move[size_t] found;
    if (code) {
        auto u = unplaced(ws);
        for (size_t i = CODE_REACH; i + CODE_REACH < ws.length; i++) {
            foreach (s; BOARD_CODE) {
                if (ws[i] == s.word && crcOf(u[i - CODE_REACH..i + CODE_REACH + 1]) == s.crc) found[i] = s.move;
            }
        }
    } else {
        for (size_t i = DATA_REACH; i + DATA_REACH < ws.length; i++) {
            foreach (s; BOARD_DATA) {
                if (ws[i] != s.word) continue;
                if (crcOf(ws[i - DATA_REACH..i + 1]) == s.before || crcOf(ws[i..i + DATA_REACH + 1]) == s.after) found[i] = s.move;
            }
        }
    }
    foreach (i, m; found) apply(m, start + cast(uint)(i * 4));
}

const(Patch)* patchFor(uint overlay) {
    foreach (ref p; PATCHES) if (p.overlay == overlay) return &p;
    return null;
}

// The game's overlay table: (ROM start, ROM end, address, ...) for each overlay, 0x24 bytes apart. Overlays load at a
// few fixed addresses: mini-games, boards and menus at 0x801059A0, and the board code (overlays 128 to 130) at
// 0x800D6B70.
enum Address OVERLAY_TABLE = 0x800962F4;
enum uint OVERLAY_COUNT = 131;
Address overlayAddress(uint overlay) { return (OVERLAY_TABLE + overlay * 0x24 + 8).val!uint; }

// The main code: from 0x80000400 (ROM 0x1000) to the first overlay (ROM 0xA96F0)
enum Address MAIN_END = 0x800A8AF0;

private __gshared bool mainChanged;             // Whether the main code is the US ROM's (or a custom board's), changed
private __gshared int[Address] changedOverlays; // The overlay with its changes made at each overlay address (-1: none)

// Whether `overlay` is loaded, with its changes made
bool changed(uint overlay) {
    auto p = overlayAddress(overlay) in changedOverlays;
    return p && *p == overlay;
}

// Runs `f` at `address` while `overlay` is loaded with its changes
void at(uint overlay, Address address, void delegate() f) {
    address.onExec({ if (changed(overlay)) f(); });
}

// Sets the game up for widescreen: the main code's changes are made when the game boots, and each overlay's when the
// game loads it. Nothing is changed in a ROM whose main code isn't the US ROM's (or a custom board's).
void setUpWidescreen() {
    changedOverlays.clear();
    mainChanged = false;

    0x80000400.onExec({
        auto main = patchFor(MAIN);
        mainChanged = crc(0x80000400, MAIN_END, MAIN_UNCHECKED) == main.codeCrc;
        if (mainChanged) apply(*main);
        else warning("Widescreen is off: this ROM's code isn't Mario Party 3 (US)'s");
    });

    // Overlays are copied from the ROM by func_8004DB14(rom, address, size), which returns once they're in memory: whole
    // (func_8000B2C4), or their code and data separately (func_8000B1A4, for the board code). The overlay is found by its
    // ROM offset in the game's overlay table (custom boards move overlays in the ROM), which also has its code's end.
    0x8004DB14.onExec({
        if (!mainChanged) return;
        uint rom = gpr.a0, size = gpr.a2;
        foreach (n; 0..OVERLAY_COUNT) {
            auto entry = OVERLAY_TABLE + n * 0x24;
            uint start = entry.val!uint, end = (entry + 4).val!uint, address = (entry + 8).val!uint;
            if (rom < start || rom >= end) continue;
            Address codeEnd = (entry + 16).val!uint, dataEnd = address + (end - start);
            Address from = address + (rom - start), to = from + size;
            bool code = from <= address && to >= codeEnd, data = from <= codeEnd && to >= dataEnd;
            if (code) changedOverlays[address] = -1; // Its code is replaced
            auto patch = patchFor(n);
            if (!patch) return;
            gpr.ra.onExecOnce({
                // A board's code or data that isn't the US ROM's is a custom board's (see BOARD_CODE)
                bool board = n >= 72 && n <= 77 || n >= 91 && n <= 96;
                if (code && crc(address, codeEnd, OVERLAY_UNCHECKED) != patch.codeCrc) {
                    code = false;
                    if (board) applySignatures(address, codeEnd, true);
                }
                if (data && crc(codeEnd, dataEnd, OVERLAY_UNCHECKED) != patch.dataCrc) {
                    data = false;
                    if (board) applySignatures(codeEnd, dataEnd, false);
                }
                apply(*patch, a => code && a < codeEnd || data && a >= codeEnd);
                if (code) changedOverlays[address] = n;
            });
            return;
        }
    });

    setUpHooks();
    setUpImages();
}

// The code the patch rewrote, done here by changing registers where it has computed them
private void setUpHooks() {
    uint savedA1;

    // Main code: X positions from a table of bytes (at 0x800A184D, which can't hold them + 52), before the calls
    0x80049078.onExec({ if (mainChanged) gpr.a0 += HALF; });
    0x8004912C.onExec({ if (mainChanged) gpr.a0 += HALF; });

    // Board code: X offsets from a table of bytes (0 to 127), + 52
    at(129, 0x800DE464, { gpr.v0 += HALF; });
    at(129, 0x800DF0EC, { gpr.v0 += HALF; });

    // Boot (and overlay 127): the tiles are in 9 columns instead of 7 (row in v1, column in v0)
    at(0, 0x80105D90, { gpr.v1 = gpr.s2 / 9; gpr.v0 = gpr.s2 % 9; });
    at(127, 0x80105DB0, { gpr.v1 = gpr.s2 / 9; gpr.v0 = gpr.s2 % 9; });

    // Coconut Conk, Messy Memory, Three Door Monty and Merry-Go-Chomp: a rectangle's left side at x = 52 (in 10.2 fixed
    // point, << 12) instead of 0, with its right side at 372 (a "lui" change in the tables)
    at(2, 0x80105F7C, { gpr.t3 = (HALF * 4) << 12; });
    at(29, 0x80105D78, { gpr.t3 = (HALF * 4) << 12; });
    at(43, 0x80106A48, { gpr.t3 = (HALF * 4) << 12; });
    at(43, 0x80106D84, { gpr.t4 = (HALF * 4) << 12; });
    at(45, 0x80106238, { gpr.t3 = (HALF * 4) << 12; });

    // Spotlight Swim: the rows of its 2D buffer are 212 words long instead of 160 (424 and 320 pixels)
    at(3, 0x8010BE88, { gpr.a0 = gpr.t5 * (SCREEN_WIDTH / 2); });
    at(3, 0x8010C01C, { gpr.v1 = gpr.a3 * (SCREEN_WIDTH / 2); });

    // Thwomp Pull: always sets 0x800CD280 (which makes the depth buffer be cleared)
    at(8, 0x8010B234, { gpr.v1 = 1; });

    // Baby Bowser Broadside: the two columns 284 pixels apart instead of 180
    at(12, 0x80106A1C, { gpr.s4 = gpr.s2 * 284; });
    at(12, 0x80106B34, { gpr.s0 = gpr.s2 * 284; });

    // Pump, Pump and Away: while a balloon rises (the jump table case at 0x8010A5D4, which also adds 0.2 to its speed),
    // s1's X (+28) moves left by 1.2837 a frame
    at(13, 0x8010A5F8, { (gpr.s1 + 28).val!float = (gpr.s1 + 28).val!float - 1.2837f; });

    // Picking Panic: X positions (in 1/4 pixels) + 208, after they're made 16-bit
    foreach (a; [0x80107FF8, 0x801080B4, 0x80108F14, 0x801097C8, 0x80109878]) {
        at(15, a, { gpr.a0 += HALF * 4; gpr.v0 = gpr.a0; });
    }
    foreach (a; [0x8010814C, 0x80109010, 0x80109910]) at(15, a, { gpr.a0 += HALF * 4; });
    foreach (a; [0x801081EC, 0x801099B0]) at(15, a, { gpr.v1 += HALF * 4; });
    at(15, 0x80108D50, { gpr.v1 += HALF * 4; gpr.v0 = gpr.v1; });
    at(15, 0x801090A4, { gpr.a1 += HALF * 4; });

    // Cosmic Coaster: x * 212 + 106 instead of x * 160 + 80
    at(16, 0x80106180, { gpr.a1 = gpr.s2 * 212 + 106; });

    // Puddle Paddle: x * 264 instead of x * 160
    at(17, 0x801066FC, { gpr.s2 = gpr.v0 * 264; });
    at(17, 0x80106810, { gpr.s1 = gpr.v1 * 264; });
    at(17, 0x80107700, { gpr.a1 = gpr.a2 * 264; });

    // Etch 'n' Catch: X positions - 52 and - 26
    at(18, 0x8010720C, { gpr.v0 -= HALF; });
    at(18, 0x80109F74, { gpr.v0 -= HALF / 2; });

    // Slot Synch, Swing 'n' Swipe and overlay 116: func_8000B364's left side (a1) at 52.0 instead of 0 (with the right
    // side at 372.0, a "lui" change in the tables); All Fired Up: the same, a1 having been f20
    0x8000B364.onExec({
        if (!mainChanged) return;
        if ((gpr.ra == 0x80105A70 && changed(20)) || (gpr.ra == 0x80105A80 && changed(64)) || (gpr.ra == 0x80105A98 && changed(116))) {
            gpr.a1 = bits(cast(float)HALF);
        }
    });
    at(41, 0x80105D90, { gpr.a1 = bits(cast(float)HALF); });

    // Slot Synch: x = 52 instead of 0 for func_80054904
    foreach (a; [0x8010787C, 0x80107908, 0x80107A14]) at(20, a, { gpr.a2 = HALF; });

    // Toadstool Titan: X positions + 52
    at(22, 0x80107840, { fpr.f14 += HALF; });
    at(22, 0x8010789C, { fpr.f2 += HALF; });
    at(22, 0x80107AC4, { gpr.v0 += HALF; });

    // Awful Tower: x * 376 + 288 instead of x * 272 + 236
    at(37, 0x80105ADC, { gpr.v0 = gpr.s2 * 376 + 288; });

    // Storm Chasers: the rectangle's left side at x = 52 (10.2 fixed point, << 12) instead of 0
    at(47, 0x801065C8, { gpr.v0 |= (HALF * 4) << 12; });

    // Vine With Me: 1220.0 instead of 900.0
    at(49, 0x8010D68C, { gpr.at = bits(1220.0f); });

    // End of the Line: x * 212 (+ 106) instead of x * 160 (+ 80)
    at(51, 0x80106874, { gpr.s0 = gpr.s3 * 212 + 106; });
    at(51, 0x80109830, { gpr.v0 = gpr.v1 * 212; });
    at(51, 0x801098B8, { gpr.v0 = gpr.a0 * 212; });

    // Bowser Toss: always the second case
    at(52, 0x80108CD8, { gpr.v0 = 1; });

    // Fowl Play: x * 212 instead of x * 160
    at(58, 0x80107060, { gpr.v0 = gpr.s2 * 212; });

    // Bobbing Bow-loons: func_801065C8 isn't called
    at(61, 0x801065C8, { if (gpr.ra == 0x80105A24) jump(gpr.ra); });

    // Game Guy's Magic Boxes: x * 212 instead of x * 160
    at(68, 0x8010A280, { gpr.v0 = gpr.v1 * 212; });
    at(68, 0x8010A438, { gpr.v0 = gpr.v1 * 212; });
    at(68, 0x8010BC7C, { gpr.a0 = gpr.v0 * 212; });
    at(68, 0x8010BE80, { gpr.v1 = gpr.t2 * 212; });
    at(68, 0x8010C0AC, { gpr.v0 = gpr.a2 * 212; });
    at(68, 0x8010C194, { gpr.v0 = gpr.a2 * 212; });

    // Chilly Waters, Spiny Desert and Creepy Cavern: x * 104 (+ 55) instead of x * 70
    at(72, 0x8011A2E4, { gpr.a2 = gpr.s3 * 104; });
    at(74, 0x801189BC, { gpr.a2 = gpr.s3 * 104; });
    at(76, 0x80117EE4, { gpr.a2 = gpr.s3 * 104; });

    // The final results (party and duel): x * 258 (+ 133) instead of x * 154
    at(85, 0x80108100, { gpr.a2 = gpr.s3 * 258; });
    at(99, 0x80107B80, { gpr.a2 = gpr.s3 * 258; });

    // The staff credits: random X positions % 424 (and % 212) instead of % 320 (and % 160)
    at(124, 0x8010796C, { gpr.a2 = gpr.s1 % SCREEN_WIDTH; });
    at(124, 0x80107C4C, { savedA1 = gpr.a1; });
    at(124, 0x80107C8C, { gpr.v1 = savedA1 % (SCREEN_WIDTH / 2) + (savedA1 >> 5) % (SCREEN_WIDTH / 2); });
    at(124, 0x80107CC8, { gpr.v0 = gpr.a1 % SCREEN_WIDTH; });
}

// ---------------------------------------------------------------------------------------------------------------------
// The widened images. The patch replaced 57 images in the game's file system with wider ones (mostly full-screen
// backgrounds, 320 to 424 pixels wide) and widened 5 models. Here they're made from the game's own files as the game
// loads them: each is the original's pixels rearranged (kept in the middle with its sides extended, tiled, mirrored,
// or stretched and zoomed), keeping its palette. They aren't the patch's images pixel for pixel: the patch's were
// re-colored to new palettes, and a few were partly redrawn (noted below).
// ---------------------------------------------------------------------------------------------------------------------

private struct Image {
    ushort directory, file;
    uint size;             // The original's (decompressed)
    uint room;             // Room for the widened one (the patch's size + 512 for a palette)
    uint word14;           // The widened one's header word 0x14
    ushort[4][] frames;    // Its frames: width, height, center X, center Y
    uint key() const { return directory << 16 | file; }
}

// A sprite file: big-endian, a 0x20-byte header (0x0C: palette offset, 0x10: frame count << 16, 0x14: width << 16 |
// height, 0x18: flags (0x80: intensity, no palette), 0x19: format (32: RGBA32, 16: RGBA16, 8: CI8/I8, 4: CI4/I4),
// 0x1A: palette size), 12 bytes for each frame (pixels' offset, width, height, center X, center Y), the pixels, and
// the palette (RGBA5551)
private struct Frame {
    int w, h, cx, cy;
    uint[] px; // Palette indices, intensities or colors
}

private struct Sprite {
    uint word10, word14;
    ubyte flags, format, colors, byte1B;
    Frame[] frames;
    ushort[] palette;
}

private uint be32(const(ubyte)[] d, size_t o) { return d[o] << 24 | d[o + 1] << 16 | d[o + 2] << 8 | d[o + 3]; }
private ushort be16(const(ubyte)[] d, size_t o) { return cast(ushort)(d[o] << 8 | d[o + 1]); }
private void put32(ref ubyte[] d, uint v) { d ~= [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte)v]; }
private void put16(ref ubyte[] d, uint v) { d ~= [cast(ubyte)(v >> 8), cast(ubyte)v]; }
private uint bitsPerPixel(ubyte format) { return format; }

private Sprite parse(const(ubyte)[] d) {
    Sprite s;
    s.word10 = be32(d, 0x10);
    s.word14 = be32(d, 0x14);
    s.flags = d[0x18]; s.format = d[0x19]; s.colors = d[0x1A]; s.byte1B = d[0x1B];
    foreach (i; 0..s.word10 >> 16) {
        auto t = 0x20 + 12 * i;
        auto o = be32(d, t);
        Frame f = Frame(be16(d, t + 4), be16(d, t + 6), be16(d, t + 8), be16(d, t + 10));
        f.px.length = f.w * f.h;
        foreach (j; 0..f.w * f.h) {
            switch (s.format) {
                case 32: f.px[j] = be32(d, o + 4 * j); break;
                case 16: f.px[j] = be16(d, o + 2 * j); break;
                case 8:  f.px[j] = d[o + j]; break;
                default: f.px[j] = j % 2 == 0 ? d[o + j / 2] >> 4 : d[o + j / 2] & 15; break;
            }
        }
        s.frames ~= f;
    }
    if ((s.format == 4 || s.format == 8) && !(s.flags & 0x80)) {
        auto p = be32(d, 0x0C);
        foreach (i; 0..(d.length - p) / 2) s.palette ~= be16(d, p + 2 * i);
    }
    return s;
}

private ubyte[] build(const Sprite s) {
    uint header = 0x20 + 12 * cast(uint)s.frames.length;
    ubyte[] table, pixels;
    foreach (f; s.frames) {
        put32(table, header + cast(uint)pixels.length);
        put16(table, f.w); put16(table, f.h); put16(table, f.cx); put16(table, f.cy);
        switch (s.format) {
            case 32: foreach (v; f.px) put32(pixels, v); break;
            case 16: foreach (v; f.px) put16(pixels, v); break;
            case 8:  foreach (v; f.px) pixels ~= cast(ubyte)v; break;
            default:
                for (size_t i = 0; i < f.px.length; i += 2) {
                    pixels ~= cast(ubyte)(f.px[i] << 4 | (i + 1 < f.px.length ? f.px[i + 1] : 0));
                }
                break;
        }
    }
    ubyte[] d;
    put32(d, 0x20); put32(d, header); put32(d, header); put32(d, header + cast(uint)pixels.length);
    put32(d, cast(uint)s.frames.length << 16 | (s.word10 & 0xFFFF));
    put32(d, s.word14);
    d ~= [s.flags, s.format, cast(ubyte)(s.palette.length ? s.palette.length : s.colors), s.byte1B];
    put32(d, 0);
    d ~= table ~ pixels;
    foreach (c; s.palette) put16(d, c);
    return d;
}

// Column (and row) maps: map[new x] = the original's x. The original is at new x = dx to dx + w - 1, and outside it:
enum Side {
    EDGE,   // its first and last columns, repeated
    MIRROR, // it, reflected at its edges
    TILE    // its first `period` columns repeated leftward and its last `period` rightward (period w: it wraps)
}

private int[] extend(int w, int newW, int dx, Side side, int period = 0) {
    int[] map;
    auto p = period ? period : w;
    foreach (x; 0..newW) {
        auto s = x - dx;
        if (s >= 0 && s < w) map ~= s;
        else if (side == Side.EDGE) map ~= s < 0 ? 0 : w - 1;
        else if (side == Side.MIRROR) map ~= s < 0 ? -1 - s : 2 * w - 1 - s;
        else map ~= s < 0 ? (s % p + p) % p : (w - p) + (s - (w - p)) % p;
    }
    return map;
}

// The original at dx, with the columns left of it copied from the original's `left` on, and right of it from `right` on
private int[] cloneSides(int w, int newW, int dx, int left, int right) {
    return iota(newW).map!(x => x < dx ? left + x : x < dx + w ? x - dx : right + x - dx - w).array;
}

// Copies of the original's column ranges, one after another: [start, length]...
private int[] segments(int[2][] ranges...) {
    int[] map;
    foreach (r; ranges) map ~= iota(r[0], r[0] + r[1]).array;
    return map;
}

private int[] tile(int w, int newW)    { return iota(newW).map!(x => x % w).array; }
private int[] stretch(int w, int newW) { return iota(newW).map!(x => x * w / newW).array; }

// Zoomed by num/den, from `offset` on (nearest neighbor)
private int[] zoom(int newLength, int num, int den, int offset, int length) {
    return iota(newLength).map!(x => min(length - 1, max(0, offset + x * den / num))).array;
}

private void gather(ref Frame f, const int[] columns, const int[] rows = null) {
    auto r = rows ? rows : iota(f.h).array;
    uint[] px;
    foreach (y; r) foreach (x; columns) px ~= f.px[y * f.w + x];
    f.px = px;
    f.w = cast(int)columns.length;
    f.h = cast(int)r.length;
}

// Palettes (RGBA5551)
private int[4] rgba(ushort c) { return [c >> 11 & 31, c >> 6 & 31, c >> 1 & 31, c & 1]; }
private ushort pack(int r, int g, int b, int a = 1) { return cast(ushort)(r << 11 | g << 6 | b << 1 | a); }

// A color's index in the palette: added if it isn't there and there's room, or else the nearest
private uint colorIndex(ref ushort[] palette, ushort c) {
    auto i = palette.countUntil(c);
    if (i >= 0) return cast(uint)i;
    if (palette.length < 255) { palette ~= c; return cast(uint)palette.length - 1; }
    auto want = rgba(c);
    uint best;
    int bestDistance = int.max;
    foreach (j, p; palette) {
        auto have = rgba(p);
        if (have[3] != want[3]) continue;
        auto d = (have[0] - want[0]) ^^ 2 + (have[1] - want[1]) ^^ 2 + (have[2] - want[2]) ^^ 2;
        if (d < bestDistance) { bestDistance = d; best = cast(uint)j; }
    }
    return best;
}

// The curtain is 4 pieces of 80x120 (19/449 top left, 450 top right, 451 bottom left, 452 bottom right), 106x120
// widened: the original curtain (160 wide) is followed by its last 17 columns mirrored, fading to black, and black.
// So the left pieces end with the right pieces' first 26 columns. The right pieces' originals are kept for that, and
// a left piece loaded before its right piece gets them when it's loaded.
private __gshared Sprite[uint] curtainRight;  // Right pieces' originals
private struct LeftPiece { Sprite sprite; Address buffer; ubyte[] written; }
private __gshared LeftPiece[uint] curtainLeft; // Left pieces waiting for their right piece, by the right piece

private void curtainColumns(ref Sprite left, const Sprite right) {
    uint[uint] remap;
    auto f = &left.frames[0];
    foreach (y; 0..f.h) foreach (x; 0..26) {
        auto v = right.frames[0].px[y * 80 + x];
        if (v !in remap) remap[v] = colorIndex(left.palette, right.palette[v]);
        f.px[y * 106 + 80 + x] = remap[v];
    }
}

private void writeBytes(Address a, const(ubyte)[] bytes) { foreach (i, b; bytes) (a + cast(uint)i).val!ubyte = b; }
private bool hasBytes(Address a, const(ubyte)[] bytes) { foreach (i, b; bytes) if ((a + cast(uint)i).val!ubyte != b) return false; return true; }

// The widened file, from the original's (decompressed) file, at `buffer`
private ubyte[] widen(const Image image, ubyte[] original, Address buffer) {
    if (image.frames.empty) return widenModel(original);

    auto s = parse(original);
    auto f = &s.frames[0];
    auto w = f.w, h = f.h;
    void columns(const int[] map) { foreach (ref fr; s.frames) gather(fr, map); }
    void zoomed(int oy) { gather(*f, zoom(424, 53, 40, 0, w), zoom(h, 53, 40, oy, h)); } // By 424/320

    switch (image.key) {
        case 16 << 16 | 0, 16 << 16 | 1:                    // The title screen: centered, the sides extended
        case 25 << 16 | 1, 93 << 16 | 0:
            columns(extend(w, 424, HALF, Side.EDGE)); break;
        case 19 << 16 | 71, 19 << 16 | 72, 19 << 16 | 73, 19 << 16 | 74, 19 << 16 | 76: // Bars: their last 104 columns again
            columns(segments([0, w], [w - MORE, MORE])); break;
        case 19 << 16 | 450, 19 << 16 | 452: {              // The curtain's right pieces (see curtainRight)
            auto key = image.key;
            curtainRight[key] = parse(original);
            ushort black = pack(0, 0, 0);
            auto blackIndex = colorIndex(s.palette, black);
            uint[] px;
            uint[uint] faded;
            foreach (y; 0..h) {
                foreach (x; 26..80) px ~= f.px[y * 80 + x];
                foreach (x; 160..177) { // Curtain columns 160 to 176: 159 to 143 mirrored, fading to black
                    auto v = f.px[y * 80 + (239 - x)], k = 177 - x;
                    auto id = v << 8 | k;
                    if (id !in faded) {
                        auto c = rgba(s.palette[v]);
                        faded[id] = colorIndex(s.palette, pack(c[0] * k / 17, c[1] * k / 17, c[2] * k / 17));
                    }
                    px ~= faded[id];
                }
                foreach (x; 177..212) px ~= blackIndex;
            }
            f.px = px; f.w = 106;
            break;
        }
        case 19 << 16 | 449, 19 << 16 | 451: {              // The curtain's left pieces: + the right piece's first 26 columns
            auto right = image.key + 1;
            columns(iota(80).array ~ 79.repeat(26).array); // Its last column, until the right piece's columns are there
            if (auto r = right in curtainRight) curtainColumns(s, *r);
            break;
        }
        case 20 << 16 | 103: columns(cloneSides(w, 424, HALF, 202, 202)); break; // Starry sky: sides from its middle
        case 22 << 16 | 26, 73 << 16 | 2:                   // Tiled patterns: centered, the sides tiled
        case 23 << 16 | 0, 23 << 16 | 1, 23 << 16 | 2, 23 << 16 | 3, 23 << 16 | 4, 23 << 16 | 5, 23 << 16 | 6:
            columns(extend(w, 424, HALF, Side.TILE)); break;
        case 22 << 16 | 27:                                 // Castle on hills: centered, the sides mirrored (the patch's has new hills)
        case 23 << 16 | 8, 65 << 16 | 12:
            columns(extend(w, 424, HALF, Side.MIRROR)); break;
        case 22 << 16 | 36, 52 << 16 | 12, 60 << 16 | 30, 64 << 16 | 0: zoomed(29); break; // Zoomed by 424/320, cropped
        case 43 << 16 | 0, 77 << 16 | 14: zoomed(0); break;
        case 63 << 16 | 1: zoomed(39); break;
        case 61 << 16 | 2: zoomed(16); break;               // (The patch's has its clouds rearranged)
        case 31 << 16 | 0: columns(segments([116, 204], [154, 15], [0, 205])); break;
        case 40 << 16 | 35: columns(extend(w, 424, HALF, Side.TILE, 32)); break; // Repeating patterns, continued
        case 63 << 16 | 3: columns(extend(w, 424, HALF, Side.TILE, 24)); break;
        case 85 << 16 | 10: columns(extend(w, 424, HALF, Side.TILE, 60)); break;
        case 48 << 16 | 17: columns(extend(w, 424, 0, Side.TILE, 4)); break;
        case 56 << 16 | 30, 101 << 16 | 5: columns(extend(w, 424, 0, Side.EDGE)); break; // Left-aligned, extended
        case 84 << 16 | 24, 84 << 16 | 25, 84 << 16 | 26: columns(extend(w, 212, 0, Side.EDGE)); break;
        case 49 << 16 | 14: columns(cloneSides(w, 212, 26, 78, 4)); break;
        case 81 << 16 | 5: columns(cloneSides(w, 424, HALF, 88, 200)); break;
        case 82 << 16 | 14: columns(cloneSides(w, 424, MORE, 18, 0)); break;
        case 47 << 16 | 0, 47 << 16 | 1: columns(stretch(w, 212)); break; // Stretched
        case 52 << 16 | 13: columns(stretch(w, 424)); break;
        case 84 << 16 | 27: columns(stretch(w, 212)); break; // (The patch's is a new, wider picture)
        case 52 << 16 | 16: {                               // Not shown: a transparent 4x4 image
            auto t = s.palette.countUntil!(c => !(c & 1));
            auto clear = t >= 0 ? cast(uint)t : colorIndex(s.palette, 0);
            f.px = new uint[16]; f.px[] = clear; f.w = f.h = 4;
            break;
        }
        case 85 << 16 | 7, 85 << 16 | 8, 85 << 16 | 9: columns(tile(w, 640)); break; // Scrolling: twice as wide
        case 94 << 16 | 0: {                                // A black bar, then the original zoomed by 93/80
            auto black = colorIndex(s.palette, pack(0, 0, 0));
            gather(*f, zoom(424 - HALF, 93, 80, 0, w), zoom(h, 93, 80, 34, h));
            uint[] px;
            foreach (y; 0..h) { foreach (x; 0..HALF) px ~= black; px ~= f.px[y * f.w..(y + 1) * f.w]; }
            f.px = px; f.w = 424;
            break;
        }
        case 63 << 16 | 2: widenFramedWall(*f); break;
        default: return null;
    }

    foreach (i, ref fr; s.frames) {
        assert(fr.w == image.frames[i][0] && fr.h == image.frames[i][1]);
        fr.cx = image.frames[i][2];
        fr.cy = image.frames[i][3];
    }
    s.word14 = image.word14;
    auto widened = build(s);

    if (image.key == (19 << 16 | 450) || image.key == (19 << 16 | 452)) { // Its left piece is waiting for it
        if (auto left = image.key in curtainLeft) {
            if (hasBytes(left.buffer, left.written)) {
                curtainColumns(left.sprite, curtainRight[image.key]);
                writeBytes(left.buffer, build(left.sprite));
            }
            curtainLeft.remove(image.key);
        }
    } else if ((image.key == (19 << 16 | 449) || image.key == (19 << 16 | 451)) && (image.key + 1) !in curtainRight) {
        curtainLeft[image.key + 1] = LeftPiece(s, buffer, widened);
    }
    return widened;
}

// (63, 2): a picture frame on a wall. The wall, bricks and pipe are zoomed by 424/320, while the frame (x 18 to 99,
// y 13 to 94) stays where it is at its size, without its shadow. The wall behind the frame is filled in first.
private void widenFramedWall(ref Frame f) {
    enum X0 = 18, Y0 = 13, X1 = 99, Y1 = 94, SHADOW_X = 103, SHADOW_Y = 98;
    auto original = f;
    Frame wall = f;
    wall.px = f.px.dup;
    foreach (y; Y0..SHADOW_Y + 1) foreach (x; X0..SHADOW_X + 1) {
        wall.px[y * f.w + x] = y < 86 ? f.px[min(y, 81) * f.w + SHADOW_X + 1 + (x - X0) % (f.w - SHADOW_X - 1)]
                                      : f.px[y * f.w + x % 15];
    }
    gather(wall, zoom(212, 53, 40, 0, f.w), zoom(f.h, 53, 40, 20, f.h));
    foreach (y; Y0..Y1 + 1) foreach (x; X0..X1 + 1) wall.px[y * wall.w + x] = original.px[y * original.w + x];
    f = wall;
}

// The models (45, 3) and (69, 8 to 11): widened by 424/320. Every vertex's X (VTX1: 9-byte vertices, s16 x, y, z and
// s8 normal) and every face corner's texture U (FAC1: faces of a type byte (0x16: 3 corners, 0x35: 4), corners of u16
// vertex, s16 color, f32 u, f32 v, then 5 bytes), so the texture repeats instead of stretching.
private ubyte[] widenModel(ubyte[] d) {
    size_t chunk(string name) {
        foreach (i; 0..d.length - 4) if (d[i..i + 4] == cast(const(ubyte)[])name) return i + 8;
        assert(false);
    }
    auto o = chunk("VTX1");
    foreach (i; 0..be16(d, o)) {
        auto p = o + 8 + 9 * i;
        auto x = cast(short)be16(d, p);
        auto widened = cast(short)(x * SCREEN_WIDTH / OLD_SCREEN_WIDTH);
        d[p] = cast(ubyte)(widened >> 8); d[p + 1] = cast(ubyte)widened;
    }
    o = chunk("FAC1");
    auto p = o + 8;
    foreach (i; 0..be16(d, o)) {
        auto corners = d[p++] == 0x16 ? 3 : 4;
        foreach (c; 0..corners) {
            uint ub = be32(d, p + 4);
            auto u = *cast(float*)&ub * SCREEN_WIDTH / OLD_SCREEN_WIDTH;
            ub = *cast(uint*)&u;
            d[p + 4] = cast(ubyte)(ub >> 24); d[p + 5] = cast(ubyte)(ub >> 16); d[p + 6] = cast(ubyte)(ub >> 8); d[p + 7] = cast(ubyte)ub;
            p += 12;
        }
        p += 5;
    }
    return d;
}

// The game reads a file in its main file system by opening its directory (func_80009EAC(47, directory)), reading its
// header (func_80009B64(46, file, info): info = its data's ROM offset, decompressed size and compression), allocating
// the size, and decompressing it (func_8000B000(rom, buffer, size, compression)). A widened file says it's bigger, is
// decompressed as it is, and is widened in its buffer. Only files the size the US ROM's are are widened.
private __gshared uint fileDirectory;
private __gshared uint[uint] widening; // ROM offset of a file's data -> IMAGES index

private void setUpImages() {
    widening.clear();
    curtainLeft.clear();

    0x80009EAC.onExec({ if (gpr.a0 == 47) fileDirectory = gpr.a1; });

    0x80009B64.onExec({
        if (gpr.a0 != 46 || !mainChanged) return;
        auto key = fileDirectory << 16 | (gpr.a1 & 0xFFFF);
        auto i = IMAGES.countUntil!(m => m.key == key);
        if (i < 0) return;
        Address info = gpr.a2;
        gpr.ra.onExecOnce({
            if ((info + 4).val!uint != IMAGES[i].size || (info + 8).val!uint != 1) return;
            widening[info.val!uint] = cast(uint)i;
            (info + 4).val!uint = IMAGES[i].room;
        });
    });

    0x8000B000.onExec({
        auto i = gpr.a0 in widening;
        if (!i) return;
        auto image = IMAGES[*i];
        widening.remove(gpr.a0);
        Address buffer = gpr.a1;
        gpr.a2 = image.size;
        gpr.ra.onExecOnce({
            auto original = new ubyte[image.size];
            foreach (j, ref b; original) b = (buffer + cast(uint)j).val!ubyte;
            auto widened = widen(image, original, buffer);
            if (widened is null || widened.length > image.room) return;
            writeBytes(buffer, widened);
        });
    });
}


// The widened images (and models): (directory, file), the original's size, room for the widened one, and the
// widened one's header word 0x14 and frames (width, height, center X, center Y), which the patch's code expects
private immutable Image[] IMAGES = [
    Image(16, 0, 153644, 204076, 0x01A800F0, [[424, 240, 212, 120]]),
    Image(16, 1, 153644, 204076, 0x01A800F0, [[424, 240, 212, 120]]),
    Image(19, 71, 3328, 4988, 0x00010001, [[400, 22, 200, 11]]),
    Image(19, 72, 3332, 4988, 0x00010001, [[400, 22, 200, 11]]),
    Image(19, 73, 3330, 4988, 0x00010001, [[400, 22, 200, 11]]),
    Image(19, 74, 3328, 4988, 0x00010001, [[400, 22, 200, 11]]),
    Image(19, 76, 2320, 3976, 0x00010001, [[308, 22, 154, 11]]),
    Image(19, 449, 9876, 13786, 0x00010001, [[106, 120, 53, 60]]),
    Image(19, 450, 9852, 13786, 0x00010001, [[106, 120, 53, 60]]),
    Image(19, 451, 10066, 13786, 0x00010001, [[106, 120, 53, 60]]),
    Image(19, 452, 9948, 13786, 0x00010001, [[106, 120, 53, 60]]),
    Image(20, 103, 77010, 102826, 0x00010001, [[424, 240, 212, 120]]),
    Image(22, 26, 77054, 102826, 0x00010001, [[424, 240, 212, 120]]),
    Image(22, 27, 41894, 56186, 0x00010001, [[424, 130, 212, 65]]),
    Image(22, 36, 77344, 102826, 0x00010001, [[424, 240, 212, 120]]),
    Image(23, 0, 77098, 102826, 0x00010001, [[424, 240, 212, 120]]),
    Image(23, 1, 77140, 102826, 0x00010001, [[424, 240, 212, 120]]),
    Image(23, 2, 77134, 102826, 0x00010001, [[424, 240, 212, 120]]),
    Image(23, 3, 77150, 102826, 0x00010001, [[424, 240, 212, 120]]),
    Image(23, 4, 77028, 102826, 0x00010001, [[424, 240, 212, 120]]),
    Image(23, 5, 77202, 102826, 0x00010001, [[424, 240, 212, 120]]),
    Image(23, 6, 77310, 102826, 0x00010001, [[424, 240, 212, 120]]),
    Image(23, 8, 25644, 34476, 0x00010001, [[424, 20, 212, 10]]),
    Image(25, 1, 38444, 51436, 0x00010001, [[424, 240, 160, 120]]),
    Image(31, 0, 77140, 102826, 0x00010001, [[424, 240, 212, 120]]),
    Image(40, 35, 9106, 12938, 0x00010001, [[424, 28, 160, 14]]),
    Image(43, 0, 81098, 107914, 0x00010001, [[424, 252, 212, 126]]),
    Image(45, 3, 2902, 2902, 0, []),
    Image(47, 0, 38918, 51946, 0x00010001, [[212, 240, 106, 120]]),
    Image(47, 1, 38444, 51436, 0x00D400F0, [[212, 240, 106, 120]]),
    Image(48, 17, 1010, 1860, 0x00010001, [[424, 6, 212, 3]]),
    Image(49, 14, 38534, 51946, 0x00010001, [[212, 240, 106, 120]]),
    Image(52, 12, 77330, 102826, 0x00010001, [[424, 240, 212, 120]]),
    Image(52, 13, 48140, 64666, 0x00010001, [[424, 150, 0, 0]]),
    Image(52, 16, 35292, 1082, 0x00010001, [[4, 4, 0, 0]]),
    Image(56, 30, 1328, 2284, 0x00010001, [[424, 8, 212, 4]]),
    Image(60, 30, 77260, 102826, 0x00010001, [[424, 240, 212, 120]]),
    Image(61, 2, 77048, 102826, 0x00010001, [[424, 240, 212, 120]]),
    Image(63, 1, 77262, 102826, 0x00010001, [[424, 240, 212, 120]]),
    Image(63, 2, 19638, 26506, 0x00010001, [[212, 120, 106, 60]]),
    Image(63, 3, 38458, 51468, 0x00010001, [[424, 240, 212, 120]]),
    Image(64, 0, 77290, 102826, 0x00010001, [[424, 240, 212, 120]]),
    Image(65, 12, 38528, 51946, 0x00010001, [[424, 120, 212, 60]]),
    Image(69, 8, 2958, 2958, 0, []),
    Image(69, 9, 2958, 2958, 0, []),
    Image(69, 10, 2958, 2958, 0, []),
    Image(69, 11, 2958, 2958, 0, []),
    Image(73, 2, 10634, 14580, 0x00010001, [[424, 66, 212, 33]]),
    Image(77, 14, 153644, 204076, 0x00010001, [[424, 240, 212, 120]]),
    Image(81, 5, 2636, 3980, 0x00010001, [[424, 16, 212, 8]]),
    Image(82, 14, 5510, 7796, 0x00010001, [[424, 34, 160, 17]]),
    Image(84, 24, 19248, 26028, 0x00010001, [[212, 240, 106, 120]]),
    Image(84, 25, 19276, 26028, 0x00010001, [[212, 240, 106, 120]]),
    Image(84, 26, 19248, 26028, 0x00010001, [[212, 240, 106, 120]]),
    Image(84, 27, 38944, 51946, 0x00010001, [[212, 240, 106, 120]]),
    Image(85, 7, 77172, 154678, 0x00010001, [[640, 120, 0, 0], [640, 120, 0, 0]]),
    Image(85, 8, 76982, 154678, 0x00010001, [[640, 120, 0, 0], [640, 120, 0, 0]]),
    Image(85, 9, 77194, 154678, 0x00010001, [[640, 120, 0, 0], [640, 120, 0, 0]]),
    Image(85, 10, 3946, 6154, 0x00010001, [[424, 12, 212, 6]]),
    Image(93, 0, 76930, 102826, 0x00010001, [[424, 240, 212, 120]]),
    Image(94, 0, 77336, 102826, 0x01A800F0, [[424, 240, 160, 120]]),
    Image(101, 5, 38468, 51468, 0x00010001, [[424, 240, 212, 120]]),
];

// ---------------------------------------------------------------------------------------------------------------------
// The changes. Most move values by a rule: "shift(HALF, ...)" for positions centered on the screen (or the left side of
// something centered), "shift(MORE, ...)" for right-aligned ones (or widths that are the screen's), multiples of them
// for fixed-point values (2 * MORE is 52 in 1/4 pixels), and "scale" for ones scaled to the wider screen. The others
// are written as what they were and what they become: the cameras' aspect ratio (ASPECT), the memory layout, RDP
// commands and scissors (positions in 10.2 fixed point: "0x50" in a lui's upper half is 320 << 2, "0x6A" 424 << 2),
// and values the patch chose.
// ---------------------------------------------------------------------------------------------------------------------

// Each overlay's (and the main code's) changes, with a CRC-32 of its original code and data (see Patch)
immutable Patch[] PATCHES = [
    // The main code (its CRC leaves out MAIN_UNCHECKED, which custom boards change)
    Patch(MAIN, 0x2B8E493A, 0, [
        shift(HALF, IMM, 0x80037610, 0x80037B60, 0x8003830C, 0x800384A0, 0x800387F0, 0x80038C88, 0x80038DF0,
                         0x800391A8, 0x800396D8, 0x80039978, 0x80039AE0, 0x80039D84, 0x8003C1AC, 0x8003C2B4,
                         0x8003C3E4, 0x8003C6A8, 0x8003C9E8, 0x8003CA90, 0x8003CBC0, 0x8003CF04, 0x8003D1A4,
                         0x8003D494, 0x8003D54C, 0x8003D670, 0x8003D848, 0x8003D900, 0x8003DA30, 0x8003DDA0,
                         0x8004116C, 0x80041264, 0x80044A84, 0x80044D48, 0x80044D60, 0x800455AC, 0x800455F0,
                         0x80048F50, 0x80048F70, 0x80048FD8, 0x80049028, 0x800490CC, 0x8006465C, 0x800647A8,
                         0x800648E8, 0x80064A20, 0x80064B5C, 0x80064BAC, 0x80064D44, 0x80064E6C, 0x80064EF0,
                         0x80064F78, 0x80064FFC, 0x80065038, 0x800652F4, 0x800659D4),
        shift(HALF, LUI, 0x80012AAC, 0x80036D0C, 0x80036DE4, 0x80036F2C, 0x80037948, 0x80037D00, 0x80037DD4,
                         0x8003A0F8, 0x8003A16C, 0x8003B56C, 0x8003B8AC, 0x8003B990, 0x8003BC34, 0x8003C594,
                         0x8003CD70, 0x8003DC00, 0x8003DFFC, 0x8003E120, 0x8003F738, 0x8003F9C0, 0x8003FAE0,
                         0x8003FDCC, 0x8004032C, 0x80040ED8, 0x80040FA8, 0x80040FC8, 0x80041140, 0x80041178,
                         0x80041198, 0x80041238, 0x80041270, 0x80041290, 0x80041308, 0x80041420, 0x800417E4,
                         0x800441DC, 0x800442C0, 0x80044410, 0x800444EC, 0x800449DC, 0x80044BE0, 0x80044CB4,
                         0x800523EC, 0x80057950, 0x80058714, 0x80063A88),
        shift(HALF, SHORT, 0x800A1436, 0x800A143E, 0x800A1446, 0x800A144E, 0x800A1456, 0x800A145E, 0x800A1466,
                           0x800A146E, 0x800A1476, 0x800A147E, 0x800A1486, 0x800A148E, 0x800A1496, 0x800A149E,
                           0x800A14A6, 0x800A18A8, 0x800A18B0, 0x800A18B4, 0x800A7812, 0x800A781A, 0x800A7822,
                           0x800A782A, 0x800A7832, 0x800A783A, 0x800A7842, 0x800A784A),
        shift(HALF, FLOAT, 0x800A05E4, 0x800A05EC, 0x800A0604, 0x800A060C),
        shift(MORE, IMM, 0x8001BFF8, 0x800456F8, 0x80045764, 0x8004EA0C, 0x80053054, 0x8005AAA0, 0x8005AAFC,
                         0x8005AB08, 0x8006406C),
        shift(MORE, LUI, 0x80012DEC, 0x8003E5E0, 0x800575E0, 0x80057670),
        shift(MORE, SHORT, 0x800A18AC, 0x800A2EAA, 0x800A376A),
        shift(MORE, FLOAT, 0x800A056C, 0x800A0578, 0x800A0584, 0x800A059C, 0x800A05B4, 0x800A05D4, 0x800A05F4,
                           0x800A0614),
        shift(2 * MORE, LUI, 0x8004B89C),
        shift(2 * MORE, SHORT, 0x800A1E90, 0x800A1E98, 0x800A2ECA, 0x800A2EDE, 0x800A378A, 0x800A379E),
        shift(2 * MORE, FLOAT, 0x800A0554, 0x800A0590),
        shift(-HALF, LUI, 0x800523E8),
        scale(SHORT, 0x800A2EC2, 0x800A3782),
    ], join([
        K(0x8000E764, 0x8000E76C, 0x003D0800, DEPTH_BUFFER), // lui a1, 0x3D; ori a1, a1, 0x800: the depth buffer
        KF(0x800125D8, 0x800125DC, 1.33333337f, ASPECT), // lui a3, 0x3faa; ori a3, a3, 0xaaab
        KF(0x80012A70, 0x80012A74, 1.33333337f, ASPECT), // lui at, 0x3faa; ori at, at, 0xaaab
        KF(0x80012DD4, 0x80012DD8, 1.33333337f, ASPECT), // lui at, 0x3faa; ori at, at, 0xaaab
        K(0x8001BC34, 0x8001BC38, 0x005003C0, 0x006A03C0), // lui s0, 0x50; ori s0, s0, 0x3c0
        I(0x800354EC, 0x8014, hi(MAIN_HEAP)), // lui a0, 0x8014: the main heap at 0x80400000 (like custom boards)
        I(0x800354F4, 0x1A, MAIN_HEAP_SIZE >> 16), // lui a1, 0x1A: its size (0x370000 instead of 0x1A0000)
        I(0x800354F4, 0x3B, MAIN_HEAP_SIZE >> 16), // lui a1, 0x3B: custom boards' size (0x370000 instead of 0x3B0000), so the depth buffer is before their code at 0x807B0000
        KF(0x80039EE0, 0x80039EE4, 265f, 265 + MORE), // lui at, 0x4384; ori at, at, 0x8000
        I(0x8003DBEC, 240, 262), // addiu v0, v0, 240
        K(0x8004887C, 0x80048884, 0x003D0800, DEPTH_BUFFER), // lui a1, 0x3D; ori a1, a1, 0x800: the depth buffer
        K(0x8004E5C4, 0x8004E5C8, 0xF64A0040, 0xF6640040), // lui v0, 0xf64a; ori v0, v0, 0x40
        K(0x8004E5E4, 0x8004E5E8, 0xF64A0380, 0xF6640380), // lui a0, 0xf64a; ori a0, a0, 0x380
        K(0x8004E620, 0x8004E624, 0x004A0040, 0x00640040), // lui v0, 0x4a; ori v0, v0, 0x40
        K(0x8004E63C, 0x8004E640, 0x004FC54C, 0x0069C54C), // lui v0, 0x4f; ori v0, v0, 0xc54c
        K(0x80054338, 0x8005433C, 0x005003C0, 0x006A03C0), // lui v0, 0x50; ori v0, v0, 0x3c0
        K(0x80054708, 0x8005470C, 0x005003C0, 0x006A03C0), // lui v0, 0x50; ori v0, v0, 0x3c0
        KF(0x80054BD0, 0x80054BD4, 1.33333337f, ASPECT), // lui a3, 0x3faa; ori a3, a3, 0xaaab
        K(0x800623DC, 0x800623E0, 0xF65003C0, 0xF66A03C0), // lui v0, 0xf650; ori v0, v0, 0x3c0
        K(0x80063788, 0x8006378C, 0x005003C0, 0x006A03C0), // lui v0, 0x50; ori v0, v0, 0x3c0
        I(0x80063F98, 0xF650, 0xF66A), // lui v1, 0xf650
        K(0x80063FC8, 0x80063FCC, 0xF65003C0, 0xF66A03C0), // lui v0, 0xf650; ori v0, v0, 0x3c0
        I(0x80064074, 0xF650, 0xF66A), // lui v1, 0xf650
        K(0x80064760, 0x80064764, 0xE42C0220, 0xE4390220), // lui v0, 0xe42c; ori v0, v0, 0x220
        K(0x8006476C, 0x80064770, 0x002401A0, 0x003101A0), // lui v0, 0x24; ori v0, v0, 0x1a0
        I(0x80064C90, 6, 7), // slti v0, v0, 6
        K(0x80064E38, 0x80064E3C, 0xF62C0220, 0xF6390220), // lui v0, 0xf62c; ori v0, v0, 0x220
        K(0x80064E44, 0x80064E48, 0x002401A0, 0x003101A0), // lui v0, 0x24; ori v0, v0, 0x1a0
        I(0x80065080, 6, 7), // slti v0, v0, 6
        I(0x80065480, 0xF650, 0xF66A), // lui v1, 0xf650
        DF(0x800A0560, 320, 848),
        DF(0x800A05A8, 960, 1696),
        DF(0x800A05C0, 960, 1696),
        H(0x800A0A28, -2481, -2455),
        H(0x800A0A50, -2481, -2455),
        W(0x800A1240, 0x80360000, FRAMEBUFFERS), // the framebuffers
        W(0x800A1244, 0x80385800, FRAMEBUFFERS + FRAMEBUFFER_SIZE),
        W(0x800A1248, 0x803AB000, FRAMEBUFFERS + 2 * FRAMEBUFFER_SIZE),
        DD(0x800A7BD8, 1.3333333730697632, ASPECT),
        DD(0x800A7BE8, 1.3333333730697632, ASPECT),
    ])),
    // Overlay 0: BOOT
    Patch(0, 0x75D640AC, 0x2F9C44B0, [
        shift(HALF, IMM, 0x80106AE8, 0x80106B78, 0x80106BB4, 0x80106DE8, 0x80106E64, 0x80106EC8, 0x80107818,
                         0x80107874, 0x80108204, 0x801083F8),
        shift(MORE, IMM, 0x80107944, 0x80107D04),
    ], join([
        I(0x80105DBC, 35, 45), // slti v0, s2, 35
    ])),
    // Overlay 1: HAND_LINE_AND_SINKER
    Patch(1, 0x6D2D92E8, 0x67461B04, [
        shift(MORE, LUI, 0x80105A40),
        shift(2 * MORE, LUI, 0x80105A4C),
    ]),
    // Overlay 2: COCONUT_CONK
    Patch(2, 0x73D7DF02, 0xB1E7D5AE, [
        shift(HALF, IMM, 0x80106140, 0x8010626C),
        shift(HALF, FLOAT, 0x8010B018, 0x8010B020, 0x8010B044, 0x8010B04C),
        shift(2 * MORE, FLOAT, 0x8010B028, 0x8010B034, 0x8010B054, 0x8010B060),
    ], join([
        I(0x80105F74, 0x50, 0x5D), // lui t4, 0x50: right side x = 372 (10.2 fixed point, << 12) instead of 320
    ])),
    // Overlay 3: SPOTLIGHT_SWIM
    Patch(3, 0x5EBEF3DA, 0x9B54B805, [
        shift(HALF, IMM, 0x8010BB80),
        shift(HALF, LUI, 0x80109CF0, 0x80109D04, 0x80109D18),
        shift(HALF, SHORT, 0x8010D1CA, 0x8010D1CE, 0x8010D1D2),
        shift(MORE, FLOAT, 0x8010D1DC),
        shift(2 * MORE, FLOAT, 0x8010D1E4, 0x8010D1F0),
        shift(43 * MORE, IMM, 0x8010BD48),
        shift(60 * MORE, IMM, 0x8010BD94),
    ], join([
        K(0x8010BB8C, 0x8010BB90, 0xF5185000, 0xF5186A00), // lui t3, 0xf518; ori t3, t3, 0x5000
        K(0x8010BBA0, 0x8010BBA4, 0x0727C000, 0x0734C000), // lui t8, 0x727; ori t8, t8, 0xc000
        K(0x8010BBB0, 0x8010BBB4, 0x0027C000, 0x0069C000), // lui t4, 0x27; ori t4, t4, 0xc000
        I(0x8010BCA0, 0xE450, 0xE46A), // lui v1, 0xe450
        K(0x8010C2DC, 0x8010C2E0, 0x00012C00, 0x00018D80), // lui a0, 0x1; ori a0, a0, 0x2c00
        I(0x8010C320, 19200, 25440), // slti v0, s0, 19200
        I(0x8010C36C, 0x1, 0x2), // lui a0, 0x1
        DD(0x8010D210, 1.3333333730697632, ASPECT),
    ])),
    // Overlay 4: BOULDER_BALL
    Patch(4, 0x7D99D543, 0x8B525080, [
        shift(MORE, LUI, 0x80105A14),
        shift(2 * MORE, LUI, 0x80105A20),
    ]),
    // Overlay 5: CRAZY_COGS
    Patch(5, 0x8E99EA82, 0x2F5A6B6C, [
        shift(HALF, LUI, 0x80106284),
        shift(HALF, FLOAT, 0x8010B898, 0x8010B8A0),
        shift(2 * MORE, FLOAT, 0x8010B8A8, 0x8010B8B4),
    ]),
    // Overlay 6: HIDE_AND_SNEAK
    Patch(6, 0xAAF5814A, 0x53F1B2C6, [
        shift(HALF, LUI, 0x8010674C),
        shift(HALF, SHORT, 0x8010C4A4, 0x8010C4A8, 0x8010C4AC, 0x8010C4B0),
        shift(HALF, FLOAT, 0x8010C4C0, 0x8010C4C8, 0x8010C4EC, 0x8010C4F4),
        shift(2 * MORE, FLOAT, 0x8010C4D0, 0x8010C4DC, 0x8010C4FC, 0x8010C508),
    ]),
    // Overlay 7: RIDICULOUS_RELAY
    Patch(7, 0x62B0548B, 0xA638E034, [
        shift(HALF, LUI, 0x8010ABD8, 0x8010AC04),
        shift(MORE, IMM, 0x80107180, 0x801078A8, 0x8010A49C),
        shift(MORE, LUI, 0x80105A04, 0x80105A28, 0x801098E0, 0x8010A474),
        shift(2 * MORE, LUI, 0x80105A34),
        shift(4 * MORE, IMM, 0x80107354, 0x80107C50, 0x80108A58, 0x8010927C),
        scale(IMM, 0x80108D88, 0x801095D8, 0x8010A748),
        scale(SHORT, 0x80110D14, 0x80110D5C),
        scale(DOUBLE, 0x80111238),
    ], join([
        F(0x8010AB80, 24, 80), // lui at, 0x41c0
        F(0x8010ABAC, 24, 80), // lui at, 0x41c0
        DD(0x80111210, 137.5, 178.125),
        DD(0x80111280, 137.5, 178.125),
    ])),
    // Overlay 8: THWOMP_PULL
    Patch(8, 0x99D7EA31, 0x94EDC559, [
        shift(HALF, IMM, 0x80106EA8, 0x8010805C, 0x80108064, 0x80109380),
        shift(HALF, LUI, 0x80105A04, 0x80105A18, 0x80106FE8, 0x80106FF8, 0x8010733C, 0x801073BC, 0x80108A28,
                         0x80109394),
        shift(MORE, IMM, 0x80106EBC, 0x80108060),
        shift(MORE, LUI, 0x80105A1C, 0x80105A28, 0x80107008, 0x80107200, 0x801072E8, 0x80107308, 0x801077E8,
                         0x8010795C, 0x80107C14, 0x801081DC),
        shift(2 * MORE, IMM, 0x80108C24, 0x80108C4C),
        shift(2 * MORE, LUI, 0x80105A5C, 0x80105A8C, 0x80107150, 0x80107320, 0x801073A0, 0x8010742C, 0x80107834,
                             0x80107870, 0x8010793C, 0x80107BF4),
        shift(3 * MORE, LUI, 0x80105A74, 0x80107024, 0x8010784C, 0x8010799C, 0x80107C74),
        shift(4 * MORE, IMM, 0x80108648),
        scale(SHORT, 0x8010EDCC, 0x8010EE14),
    ]),
    // Overlay 9: RIVER_RAIDERS
    Patch(9, 0x3D8E6CCE, 0x1C27D384, [
        shift(MORE, FLOAT, 0x8010D870, 0x8010D878, 0x8010D880, 0x8010D8A8, 0x8010D8B0, 0x8010D8B8, 0x8010D8C0,
                           0x8010D8D0),
        shift(2 * MORE, FLOAT, 0x8010D8D8, 0x8010D8E4),
    ], join([
        DF(0x8010D8F0, 36, 29.75),
    ])),
    // Overlay 10: TIDAL_TOSS
    Patch(10, 0x35042BF7, 0xB16D5DBE, [
        shift(HALF, IMM, 0x801061CC),
        shift(MORE, LUI, 0x80105A38),
        shift(2 * MORE, LUI, 0x80105A44),
        scale(SHORT, 0x8010AA74, 0x8010AA78, 0x8010AA7A),
    ], join([
        KF(0x80106584, 0x80106588, 1380f, scaled(1380.0)), // lui a2, 0x44ac; ori a2, a2, 0x8000
        H(0x8010AA76, 30, 39),
        H(0x8010AA7C, 294, 389),
        H(0x8010AA7E, 24, 31),
    ])),
    // Overlay 11: EATSA_PIZZA
    Patch(11, 0x4C936F85, 0x8CD16289, [
        shift(HALF, IMM, 0x801084BC, 0x8010870C, 0x80108720),
        shift(HALF, DOUBLE, 0x80109250),
        shift(MORE, LUI, 0x80105A38),
        shift(2 * MORE, LUI, 0x80105A44),
    ]),
    // Overlay 12: BABY_BOWSER_BROADSIDE
    Patch(12, 0x55F3606A, 0xBD78A2E7, [
        shift(MORE, IMM, 0x801069E0),
        shift(MORE, LUI, 0x80105A80),
        shift(2 * MORE, LUI, 0x80105A8C),
    ]),
    // Overlay 13: PUMP_PUMP_AND_AWAY
    Patch(13, 0xC3C0CE92, 0x69E7556C, [
        shift(MORE, SHORT, 0x80110FE0, 0x80110FF4, 0x80110FF8, 0x80110FFC, 0x80111000),
        shift(MORE, FLOAT, 0x80111124),
        shift(2 * MORE, FLOAT, 0x8011112C, 0x80111138),
        scale(IMM, 0x8010772C),
    ], join([
        F(0x8010A8FC, 200, 132), // lui at, 0x4348
        F(0x8010F94C, 65, -3), // lui at, 0x4282
        DF(0x80111144, 20, 15.1604004),
    ])),
    // Overlay 14: HYPER_HYDRANTS
    Patch(14, 0x44D9F4EA, 0x2A363AA6, [
        shift(HALF, IMM, 0x8010AEE4),
        shift(HALF, LUI, 0x80106008, 0x80106080),
        shift(MORE, LUI, 0x80106014),
        shift(MORE, SHORT, 0x8010BE1C, 0x8010BE20, 0x8010BF34),
        shift(2 * MORE, LUI, 0x80106048, 0x801060AC),
        shift(3 * MORE, LUI, 0x80106094),
        scale(IMM, 0x8010AF70, 0x8010AF90, 0x8010B094, 0x8010B0B4),
    ]),
    // Overlay 15: PICKING_PANIC
    Patch(15, 0x7DDCDB13, 0x34E05074, [
        shift(HALF, IMM, 0x8010A6B8, 0x8010A6DC),
        shift(MORE, LUI, 0x80105A04, 0x80105A28, 0x801078BC, 0x80107944),
        shift(2 * MORE, LUI, 0x80105A34, 0x80107954),
    ], join([
        I(0x80107F50, 0x50, 0x6A), // lui v1, 0x50
        I(0x80107F90, 0x50, 0x6A), // lui v0, 0x50
        I(0x80108CA4, 0x50, 0x6A), // lui v1, 0x50
        I(0x80108CE4, 0x50, 0x6A), // lui v0, 0x50
        I(0x80109710, 0x50, 0x6A), // lui v1, 0x50
        I(0x80109750, 0x50, 0x6A), // lui v0, 0x50
        I(0x8010A0EC, 0x50, 0x6A), // lui v1, 0x50
        I(0x8010A128, 0x50, 0x6A), // lui v0, 0x50
        K(0x8010A240, 0x8010A244, 0xE44AC000, 0xE457C000), // lui v0, 0xe44a; ori v0, v0, 0xc000
        K(0x8010A270, 0x8010A274, 0x003BC000, 0x0048C000), // lui v0, 0x3b; ori v0, v0, 0xc000
        K(0x8010A694, 0x8010A698, 0x00408000, 0x004D8000), // lui s8, 0x40; ori s8, s8, 0x8000
        K(0x8010A6A0, 0x8010A6A4, 0x003CC000, 0x0049C000), // lui t9, 0x3c; ori t9, t9, 0xc000
        I(0x8010A724, 0x50, 0x6A), // lui v1, 0x50
        I(0x8010A760, 0x50, 0x6A), // lui v0, 0x50
        K(0x8010ADF4, 0x8010ADF8, 0x005003C0, 0x006A03C0), // lui v0, 0x50; ori v0, v0, 0x3c0
        K(0x8010AEC4, 0x8010AEC8, 0xFD48009F, 0xFD4800D3), // lui v0, 0xfd48; ori v0, v0, 0x9f
        K(0x8010AEE4, 0x8010AEE8, 0xF5482800, 0xF5483600), // lui v0, 0xf548; ori v0, v0, 0x2800
        I(0x8010AF24, 0x728, 0x735), // lui v0, 0x728
        K(0x8010AF50, 0x8010AF54, 0xF5402800, 0xF5403600), // lui v0, 0xf540; ori v0, v0, 0x2800
        K(0x8010AF7C, 0x8010AF80, 0x00500018, 0x006A0018), // lui v0, 0x50; ori v0, v0, 0x18
        I(0x8010AFEC, 0xE450, 0xE46A), // lui v0, 0xe450
    ])),
    // Overlay 16: COSMIC_COASTER
    Patch(16, 0xF9A82A7B, 0x53F3A6C2, [
        shift(HALF, IMM, 0x80106120, 0x801061D0, 0x8010621C, 0x80106294, 0x8010646C),
        shift(HALF, LUI, 0x80105AE8, 0x80105B48),
        shift(MORE, LUI, 0x80105AF4),
        shift(2 * MORE, LUI, 0x80105B28, 0x80105B74),
        shift(3 * MORE, LUI, 0x80105B5C),
    ]),
    // Overlay 17: PUDDLE_PADDLE
    Patch(17, 0x5F83C3E5, 0xA7001BC2, [
        shift(MORE, IMM, 0x8010660C, 0x80106664, 0x801066BC),
        shift(MORE, LUI, 0x80105A80),
        shift(2 * MORE, LUI, 0x80105A8C),
    ], join([
        F(0x801075CC, 280, 102), // lui at, 0x438c
        KF(0x80107610, 0x80107614, 2970f, 2404), // lui at, 0x4539; ori at, at, 0xa000
    ])),
    // Overlay 18: ETCH_N_CATCH
    Patch(18, 0xD6609208, 0xC91A3A14, [
        shift(HALF, IMM, 0x8010BF10, 0x8010BF90),
        shift(HALF, SHORT, 0x8010C6A4, 0x8010C6A8, 0x8010C820, 0x8010C824),
        shift(MORE, LUI, 0x80105D9C),
        shift(2 * MORE, LUI, 0x80105DA8),
    ]),
    // Overlay 19: LOG_JAM
    Patch(19, 0xD9E47ACA, 0xAED119A2, [
        shift(HALF, IMM, 0x80109CC0),
        shift(MORE, LUI, 0x80105A64, 0x8010A1C4, 0x8010A1D8, 0x8010A1F4),
        shift(MORE, SHORT, 0x8010E092),
        shift(2 * MORE, LUI, 0x80105A70),
        shift(3 * HALF, FLOAT, 0x8010E074),
        scale(FLOAT, 0x8010E054, 0x8010E05C, 0x8010E06C),
    ], join([
        F(0x80105ABC, 30, 22.875), // lui a1, 0x41f0
    ])),
    // Overlay 20: SLOT_SYNCH
    Patch(20, 0x6F42A576, 0x0A2C54DF, [
        shift(HALF, IMM, 0x80107988),
        shift(HALF, LUI, 0x80105A64),
        shift(HALF, SHORT, 0x8010D838, 0x8010D83C, 0x8010D938, 0x8010D93E, 0x8010D944, 0x8010D94A, 0x8010D950,
                           0x8010D956, 0x8010D95C, 0x8010D962, 0x8010D968, 0x8010D96E, 0x8010D974, 0x8010D97A,
                           0x8010D980, 0x8010D986, 0x8010D98C, 0x8010D992, 0x8010D998, 0x8010D99E, 0x8010D9A4,
                           0x8010D9AA, 0x8010D9B0, 0x8010D9B6, 0x8010D9BC, 0x8010D9C2),
        shift(2 * MORE, LUI, 0x80105A70),
    ]),
    // Overlay 21: TREADMILL_GRILL
    Patch(21, 0x25DC1BE8, 0xC7B668F1, [
        shift(MORE, LUI, 0x80105A0C),
        shift(2 * MORE, LUI, 0x80105A18),
    ], join([
        F(0x80105A64, 20, 18.875), // lui a1, 0x41a0
    ])),
    // Overlay 22: TOADSTOOL_TITAN
    Patch(22, 0x7B88410F, 0xF43D5416, [
        shift(HALF, FLOAT, 0x8010EDA4, 0x8010EDAC),
        shift(MORE, LUI, 0x80105A2C),
        shift(2 * MORE, LUI, 0x80105A40, 0x80107474, 0x801078D0, 0x80107C58),
        shift(4 * MORE, IMM, 0x8010B110),
        scale(SHORT, 0x8010EE2C),
    ]),
    // Overlay 23: ACES_HIGH
    Patch(23, 0xE750ED2F, 0xACE1393A, [
        shift(HALF, IMM, 0x80106128, 0x80106170, 0x8010CA44, 0x8010D62C),
        shift(HALF, LUI, 0x8010CBC0, 0x8010D4B4, 0x8010D548),
        shift(HALF, FLOAT, 0x8010DB78, 0x8010DB80, 0x8010DB98, 0x8010DBA0, 0x8010DCB4),
        shift(MORE, LUI, 0x8010D538),
        shift(MORE, SHORT, 0x8010DC58, 0x8010DC5C, 0x8010DC68, 0x8010DC6C, 0x8010DC74, 0x8010DC7C),
        shift(MORE, FLOAT, 0x8010DB88, 0x8010DBA8, 0x8010DBB8, 0x8010DBD8, 0x8010DCBC, 0x8010DCCC),
        shift(2 * MORE, FLOAT, 0x8010DBB0, 0x8010DBC0, 0x8010DBD0, 0x8010DBE0),
        shift(3 * MORE, FLOAT, 0x8010DBC8, 0x8010DBE8),
    ], join([
        KF(0x8010D838, 0x8010D83C, 144.600006f, 144.600006 + HALF), // lui at, 0x4310; ori at, at, 0x999a
        KF(0x8010D860, 0x8010D864, 175.399994f, 175.399994 + HALF), // lui at, 0x432f; ori at, at, 0x6666
        KF(0x8010D86C, 0x8010D870, 304.600006f, 304.600006 + MORE), // lui at, 0x4398; ori at, at, 0x4ccd
    ])),
    // Overlay 24: BOUNCE_N_TROUNCE
    Patch(24, 0xCD7D8F35, 0xEDF3326F, [
        shift(MORE, LUI, 0x80105A58),
        shift(2 * MORE, LUI, 0x80105A64),
        shift(-4 * MORE, LUI, 0x8010A6D0, 0x8010A700),
    ]),
    // Overlay 25: ICE_RINK_RISK
    Patch(25, 0xF07A1A59, 0x0F1F5652, [
        shift(HALF, IMM, 0x80105D8C),
        shift(MORE, LUI, 0x80105A20),
        shift(2 * MORE, LUI, 0x80105A2C),
    ]),
    // Overlay 26: LOCKED_OUT
    Patch(26, 0x355CB389, 0x378E770E, [
        shift(MORE, LUI, 0x80105A38),
        shift(2 * MORE, LUI, 0x80105A44),
    ], join([
        F(0x80105A90, 45, 43.25), // lui a1, 0x4234
    ])),
    // Overlay 27: CHIP_SHOT_CHALLENGE
    Patch(27, 0x39044750, 0x8A5D5FCA, [
        shift(HALF, IMM, 0x80105CCC, 0x8010771C, 0x80107864),
        shift(MORE, LUI, 0x80105A1C),
        shift(2 * MORE, LUI, 0x80105A28),
    ]),
    // Overlay 28: PARASOL_PLUMMET
    Patch(28, 0x1E25CE90, 0x537CFF2E, [
        shift(HALF, IMM, 0x80106BE4, 0x80106C70, 0x80108338, 0x80108790, 0x80108A2C, 0x80108A34),
        shift(HALF, LUI, 0x801090FC, 0x80109120),
        shift(MORE, LUI, 0x8010A7D0),
        shift(MORE, SHORT, 0x8010AB46, 0x8010AB4A),
        shift(2 * MORE, LUI, 0x8010A7E0),
    ], join([
        KF(0x80109170, 0x80109174, 281f, 281 + HALF), // lui at, 0x438c; ori at, at, 0x8000
    ])),
    // Overlay 29: MESSY_MEMORY
    Patch(29, 0xE8BFA899, 0x68E7BA16, [
        shift(HALF, LUI, 0x80106430, 0x801064D4, 0x8010D234),
        shift(HALF, SHORT, 0x80110FE0, 0x80110FE4, 0x80110FE8, 0x80110FEC, 0x80110FF4, 0x80110FF8, 0x80110FFC,
                           0x80111000, 0x80111004, 0x80111008, 0x8011100C, 0x80111010, 0x80111014, 0x80111018,
                           0x8011101C, 0x80111020, 0x80111024, 0x80111028, 0x8011102C, 0x80111030, 0x80111034,
                           0x80111038, 0x8011103C, 0x80111040),
        shift(HALF, FLOAT, 0x801112B8, 0x801112C0, 0x801112C8, 0x801112D0, 0x801112D8, 0x801112E0, 0x801112E8,
                           0x801112F0, 0x801112F8, 0x80111300, 0x80111308, 0x80111310, 0x80111340, 0x80111348,
                           0x8011136C, 0x80111374),
        shift(2 * MORE, FLOAT, 0x80111350, 0x8011135C, 0x8011137C, 0x80111388),
    ], join([
        I(0x80105D70, 0x50, 0x5D), // lui t4, 0x50: right side x = 372 (10.2 fixed point, << 12) instead of 320
        I(0x80105F90, 0x2B, 0x38), // lui t4, 0x2b
        I(0x80105F94, 0x25, 0x32), // lui t3, 0x25
    ])),
    // Overlay 30: PICTURE_IMPERFECT
    Patch(30, 0xD2E60B46, 0xA16396D4, [
        shift(HALF, IMM, 0x80109768, 0x801097C0, 0x80109F60, 0x80109FA8),
        shift(HALF, LUI, 0x80105FF8, 0x80106058, 0x801060A8, 0x801060E8, 0x80109CBC),
        shift(HALF, SHORT, 0x8010A01C, 0x8010A024),
        shift(MORE, LUI, 0x80106004),
        shift(2 * MORE, LUI, 0x80106038, 0x80106084, 0x801060CC, 0x8010610C),
        shift(3 * MORE, LUI, 0x8010606C),
        scale(SHORT, 0x80109FE8, 0x80109FEC, 0x80109FF0, 0x80109FF4),
    ], join([
        F(0x80105F34, -200, -262), // lui at, 0xc348
        I(0x80108E9C, -25, 1), // addiu a1, a1, -25
        I(0x80108F58, -14, 12), // addiu a1, a1, -14
        I(0x8010903C, 2, 28), // addiu a1, a1, 2
        I(0x801090AC, 30, 56), // addiu a1, a1, 30
    ])),
    // Overlay 31: MARIOS_PUZZLE_PARTY
    Patch(31, 0x6A8D262C, 0xFFCCA8D8, [
        shift(HALF, IMM, 0x801060F0, 0x80106624, 0x80106644, 0x8010EB38),
        shift(HALF, SHORT, 0x80110082, 0x8011008A, 0x80110092, 0x8011009A, 0x801100A2),
        shift(HALF, FLOAT, 0x80110170, 0x801101D0),
        shift(MORE, IMM, 0x80106684),
        shift(MORE, LUI, 0x80105A50),
        shift(MORE, FLOAT, 0x80110188, 0x801101A0, 0x801101B8),
        shift(2 * MORE, LUI, 0x80105A5C),
    ], join([
        I(0x80106604, 70, 96), // li v1, 70
        I(0x80106664, 270, 348), // li v1, 270
        I(0x8010E418, 90, 131), // li a2, 90
    ])),
    // Overlay 32: THE_BEAT_GOES_ON
    Patch(32, 0xEED347A7, 0x91209DDF, [
        shift(HALF, IMM, 0x80105F48, 0x80106098, 0x801061EC, 0x80106340, 0x80108A2C, 0x80108A70, 0x8010B27C,
                         0x8010B28C, 0x8010B2F8, 0x8010B4A4, 0x8010B4D4, 0x8010B5B4, 0x8010BD1C, 0x8010BD30,
                         0x8010BD48, 0x8010BD4C, 0x8010C110, 0x8010C138),
        shift(HALF, LUI, 0x8010B8C4, 0x8010BD54, 0x8010BD6C),
        shift(MORE, LUI, 0x80105D84),
        shift(2 * MORE, LUI, 0x80105D90),
    ]),
    // Overlay 33: MPIQ
    Patch(33, 0xBD7E2822, 0xAB5D45B5, [
        shift(HALF, IMM, 0x80106C50, 0x80106CC0, 0x80106D2C, 0x80106DA4, 0x80106E24, 0x80106F5C, 0x80106F78,
                         0x80106FA0, 0x80106FB4, 0x80106FD0, 0x80106FE4, 0x80107000, 0x80107014, 0x80107030,
                         0x80107044, 0x80107060, 0x80107074, 0x80107090, 0x801070A4, 0x801070C0, 0x801070D4,
                         0x8010BC20, 0x8010C0E8),
        shift(HALF, LUI, 0x80106ED4, 0x80108704, 0x8010C370),
        shift(HALF, FLOAT, 0x8010C6A8, 0x8010C6AC, 0x8010C6B0, 0x8010C6B4),
        shift(MORE, LUI, 0x80108AB0),
        shift(2 * MORE, LUI, 0x80108AC0),
    ]),
    // Overlay 34: CURTAIN_CALL
    Patch(34, 0xB9108342, 0xDB261E97, [
        shift(HALF, IMM, 0x80106300),
        shift(HALF, LUI, 0x80106510),
        shift(HALF, FLOAT, 0x8010B280, 0x8010B288),
        shift(2 * MORE, FLOAT, 0x8010B290, 0x8010B29C),
    ]),
    // Overlay 35: WATER_WHIRLED
    Patch(35, 0x6AD7957A, 0xFED9ADF7, [
        shift(HALF, IMM, 0x80108EE8),
        shift(MORE, LUI, 0x80105A14),
        shift(MORE, SHORT, 0x8010A52A, 0x8010A53A, 0x8010A54A, 0x8010A55A),
        shift(2 * MORE, LUI, 0x80105A20),
    ], join([
        F(0x80108F04, 2, 2.65625), // lui a1, 0x4000
    ])),
    // Overlay 36: FRIGID_BRIDGES
    Patch(36, 0x3993FEC9, 0x8D9B7889, [
        shift(HALF, LUI, 0x80105B5C, 0x80105BB8, 0x80105C18, 0x80105C58),
        shift(MORE, LUI, 0x80105B68),
        shift(2 * MORE, LUI, 0x80105B9C, 0x80105BE8, 0x80105C3C, 0x80105C7C),
        shift(3 * MORE, LUI, 0x80105BD0),
    ], join([
        KF(0x80105BC0, 0x80105BC4, 319f, 319 + MORE), // lui a3, 0x439f; ori a3, a3, 0x8000
        KF(0x80105C60, 0x80105C64, 319f, 319 + MORE), // lui a3, 0x439f; ori a3, a3, 0x8000
    ])),
    // Overlay 37: AWFUL_TOWER
    Patch(37, 0x74E23F0B, 0xCFF377A7, [
        shift(HALF, LUI, 0x80107BA0),
        shift(HALF, SHORT, 0x8010CCCA, 0x8010CCD6),
        shift(MORE, LUI, 0x80107BB0, 0x8010859C),
        shift(MORE, SHORT, 0x8010CCDE, 0x8010CE72, 0x8010CE76, 0x8010CE7A, 0x8010CE7E),
        shift(2 * MORE, LUI, 0x80105AF4),
        scale(SHORT, 0x8010CBDC),
    ], join([
        H(0x8010CCC6, 93, 119),
        H(0x8010CCCE, 229, 307),
        H(0x8010CCD2, 92, 118),
        H(0x8010CCDA, 228, 306),
        H(0x8010CE50, 0, -1),
        H(0x8010CE52, 0, -5),
        H(0x8010CE56, 25, 19),
        H(0x8010CE5A, 25, 19),
        H(0x8010CE5E, 25, 0),
    ])),
    // Overlay 38: CHEEP_CHEEP_CHASE
    Patch(38, 0xF33C0493, 0x76260080, [
        shift(MORE, LUI, 0x80105A80),
        shift(2 * MORE, LUI, 0x80105A8C),
        shift(-MORE, LUI, 0x80107F98),
    ], join([
        F(0x80105AD8, 30, 22.75), // lui a1, 0x41f0
        KF(0x80107CB0, 0x80107CB4, -343f, -455), // lui at, 0xc3ab; ori at, at, 0x8000
        F(0x80107DB4, -16, -128), // lui at, 0xc180
        F(0x80107F88, 101, 213), // lui at, 0x42ca
    ])),
    // Overlay 39: PIPE_CLEANERS
    Patch(39, 0x24843A4F, 0x3ED7E762, [
        shift(HALF, LUI, 0x80105C6C),
        shift(HALF, SHORT, 0x8010A012, 0x8010A01A, 0x8010A022, 0x8010A02A),
        shift(HALF, FLOAT, 0x8010A040, 0x8010A048, 0x8010A06C, 0x8010A074, 0x8010A098, 0x8010A0A0, 0x8010A0C4,
                           0x8010A0CC),
        shift(MORE, FLOAT, 0x8010A050, 0x8010A07C, 0x8010A0A8, 0x8010A0D4),
        shift(2 * MORE, FLOAT, 0x8010A05C, 0x8010A088, 0x8010A0B4, 0x8010A0E0),
    ]),
    // Overlay 40: SNOWBALL_SUMMIT
    Patch(40, 0xD66D0011, 0xBF3B60D3, [
        shift(HALF, LUI, 0x801061EC),
        shift(MORE, FLOAT, 0x8010F5D4, 0x8010F600),
        shift(2 * MORE, FLOAT, 0x8010F5DC, 0x8010F5E8, 0x8010F608, 0x8010F614),
    ], join([
        I(0x80106410, 0xE41A, 0xE422), // lui t7, 0xe41a
        I(0x8010641C, 0x400, 0x30F), // lui t4, 0x400
        I(0x8010660C, 0xE450, 0xE46A), // lui t7, 0xe450
        I(0x80106610, 0x36, 0x48), // lui t6, 0x36
        I(0x80106710, 0x400, 0x30F), // lui v0, 0x400
    ])),
    // Overlay 41: ALL_FIRED_UP
    Patch(41, 0x1443754B, 0xB7B9FDD9, [
        shift(HALF, IMM, 0x80109830, 0x801098A0),
        shift(HALF, LUI, 0x80105D94),
        shift(2 * MORE, LUI, 0x80105DA0),
    ]),
    // Overlay 42: STACKED_DECK
    Patch(42, 0x34173D6B, 0x86AF8857, [
        shift(HALF, IMM, 0x80106710),
        shift(HALF, FLOAT, 0x8010F360, 0x8010F368),
        shift(2 * MORE, FLOAT, 0x8010F370, 0x8010F37C),
    ]),
    // Overlay 43: THREE_DOOR_MONTY
    Patch(43, 0x48975017, 0xF48B3A44, [
        shift(HALF, SHORT, 0x8010CD66, 0x8010CD6A, 0x8010CD6E, 0x8010CD72, 0x8010CD76, 0x8010CD7A, 0x8010CD7E,
                           0x8010CD82, 0x8010CD86, 0x8010CD8A, 0x8010CD8E, 0x8010CD92, 0x8010CD96, 0x8010CD9A,
                           0x8010CD9E, 0x8010CDA2, 0x8010CDC4, 0x8010CDC8),
        shift(HALF, FLOAT, 0x8010CDD0, 0x8010CDD8, 0x8010CDFC, 0x8010CE04, 0x8010CE28, 0x8010CE30),
        shift(2 * MORE, FLOAT, 0x8010CDE0, 0x8010CDEC, 0x8010CE0C, 0x8010CE18, 0x8010CE38, 0x8010CE44),
    ], join([
        I(0x80106A40, 0x50, 0x5D), // lui t4, 0x50: right side x = 372 (10.2 fixed point, << 12) instead of 320
        I(0x80106D7C, 0x50, 0x5D), // lui t5, 0x50: right side x = 372 (10.2 fixed point, << 12) instead of 320
    ])),
    // Overlay 44: ROCKIN_RACEWAY
    Patch(44, 0x4FCA87F8, 0x29ED7903, [
        shift(HALF, IMM, 0x80109CAC, 0x8010A57C),
        shift(HALF, SHORT, 0x80111340, 0x80111342, 0x80111344, 0x80111346, 0x80111348, 0x8011134A, 0x8011134C,
                           0x8011134E),
        shift(MORE, LUI, 0x80105A94),
        shift(MORE, SHORT, 0x80111334, 0x8011133C),
        shift(2 * MORE, LUI, 0x80105AA0),
    ]),
    // Overlay 45: MERRY_GO_CHOMP
    Patch(45, 0x660ABB2E, 0x2AF3D753, [
        shift(HALF, LUI, 0x80106394),
        shift(HALF, FLOAT, 0x8010C258, 0x8010C260, 0x8010C284, 0x8010C28C),
        shift(2 * MORE, FLOAT, 0x8010C268, 0x8010C274, 0x8010C294, 0x8010C2A0),
    ], join([
        I(0x80106230, 0x50, 0x5D), // lui t4, 0x50: right side x = 372 (10.2 fixed point, << 12) instead of 320
    ])),
    // Overlay 46: SLAP_DOWN
    Patch(46, 0x79CB362C, 0xA052E51A, [
        shift(HALF, IMM, 0x8010667C),
        shift(HALF, FLOAT, 0x8010A838, 0x8010A840, 0x8010A848, 0x8010A850, 0x8010A858, 0x8010A860, 0x8010A868,
                           0x8010A870, 0x8010A88C, 0x8010A894),
        shift(2 * MORE, FLOAT, 0x8010A89C, 0x8010A8A8),
    ]),
    // Overlay 47: STORM_CHASERS
    Patch(47, 0x07E8BE17, 0xD93F8243, [
        shift(HALF, LUI, 0x8010622C),
        shift(HALF, FLOAT, 0x8010CAB8, 0x8010CAC0, 0x8010CAE4, 0x8010CAEC),
        shift(2 * MORE, FLOAT, 0x8010CAC8, 0x8010CAD4, 0x8010CAF4, 0x8010CB00),
    ], join([
        I(0x801064E0, 0xE450, 0xE45D), // lui t7, 0xe450
    ])),
    // Overlay 48: EYE_SORE
    Patch(48, 0x6A570507, 0xD3905967, [
        shift(HALF, LUI, 0x801060B4),
        shift(HALF, FLOAT, 0x8010AD00, 0x8010AD24, 0x8010AD58, 0x8010AD7C),
        shift(MORE, FLOAT, 0x8010AD08, 0x8010AD2C, 0x8010AD34, 0x8010AD60, 0x8010AD84, 0x8010AD8C),
        scale(FLOAT, 0x8010AD14, 0x8010AD40, 0x8010AD6C, 0x8010AD98),
    ]),
    // Overlay 49: VINE_WITH_ME
    Patch(49, 0x0A29DEC7, 0x3D6E37B9, [
        shift(HALF, IMM, 0x8010B938),
        shift(MORE, IMM, 0x8010BA44, 0x8010BA4C),
        shift(MORE, LUI, 0x80105A04, 0x80105A28, 0x8010702C, 0x8010722C, 0x801074B0),
        shift(MORE, DOUBLE, 0x80111E78),
        shift(2 * MORE, LUI, 0x80105A34),
        shift(4 * MORE, LUI, 0x80107244, 0x801074C8),
        scale(IMM, 0x8010BE48),
        scale(SHORT, 0x80111BD4, 0x80111C1C),
    ], join([
        DD(0x80112080, 14, 20.5),
    ])),
    // Overlay 50: POPGUN_PICK_OFF
    Patch(50, 0xA18C865F, 0x78D2F08D, [
        shift(HALF, IMM, 0x801061E0, 0x801066A8, 0x801066BC, 0x80106778, 0x8010678C, 0x8010682C, 0x80106840,
                         0x80106854, 0x80106868, 0x8010687C, 0x80106890, 0x80106C50),
        shift(HALF, LUI, 0x80105EDC),
        shift(HALF, DOUBLE, 0x8010C8B0, 0x8010C8C0),
        shift(MORE, LUI, 0x80105A38),
        shift(2 * MORE, LUI, 0x80105A44),
    ], join([
        I(0x80105ACC, 180, 0), // li a0, 180
        I(0x80105AD0, 180, 0), // li a1, 180
        I(0x80105AD8, 180, 0), // li a2, 180
        DD(0x8010C8A8, 1.3333333333333333, ASPECT),
        DD(0x8010C8D0, 1.3333333333333333, ASPECT),
    ])),
    // Overlay 51: END_OF_THE_LINE
    Patch(51, 0x71D8F07D, 0x5D272823, [
        shift(HALF, IMM, 0x80106950),
        shift(HALF, LUI, 0x8010B720, 0x8010B9A4, 0x8010BA20, 0x8010BCA4),
        shift(HALF, SHORT, 0x8010C604, 0x8010C608),
        shift(HALF, FLOAT, 0x8010C5CC),
        shift(MORE, LUI, 0x8010B6E4, 0x8010B994, 0x8010BC94),
        shift(MORE, SHORT, 0x8010C60C, 0x8010C614),
        shift(2 * MORE, SHORT, 0x8010C610, 0x8010C618),
        shift(3 * MORE, SHORT, 0x8010C61C),
        scale(FLOAT, 0x8010C5D0, 0x8010C5D4),
    ], join([
        H(0x8010C664, 110, 136),
        H(0x8010C666, 50, 76),
    ])),
    // Overlay 52: BOWSER_TOSS
    Patch(52, 0xE70CFD61, 0x5E7BC525, [
        shift(HALF, IMM, 0x8010A890),
        shift(HALF, LUI, 0x8010C08C),
        shift(HALF, SHORT, 0x8010F378, 0x8010F37C, 0x8010F380, 0x8010F384, 0x8010F388, 0x8010F38C, 0x8010F390,
                           0x8010F398, 0x8010F39C, 0x8010F3A0, 0x8010F3A4, 0x8010F3A8, 0x8010F3AC, 0x8010F3B0),
        shift(MORE, LUI, 0x80105A74, 0x80105A98),
        shift(MORE, SHORT, 0x8010F340, 0x8010F348),
        shift(2 * MORE, LUI, 0x80105AA4),
    ], join([
        F(0x80105B1C, 45, 34.75), // lui a1, 0x4234
        F(0x8010B220, 320, 640), // lui at, 0x43a0
        F(0x8010B37C, 320, 640), // lui at, 0x43a0
        H(0x8010F394, 124, 248),
        H(0x8010F3B4, 124, 248),
        DD(0x8010F838, 320, 640),
        DD(0x8010F848, 320, 640),
    ])),
    // Overlay 53: BABY_BOWSER_BONKERS
    Patch(53, 0x46B77076, 0xADAEF9F3, [
        shift(MORE, IMM, 0x80109C78),
        shift(MORE, LUI, 0x80105A64),
        shift(2 * MORE, LUI, 0x80105A70),
    ], join([
        F(0x80105ABC, 30, 23), // lui a1, 0x41f0
    ])),
    // Overlay 54: MOTOR_ROOTER
    Patch(54, 0x004A770E, 0x7A4207A0, [
        shift(HALF, IMM, 0x801072BC, 0x80107540, 0x80107620, 0x80107994),
        shift(HALF, LUI, 0x80105A90, 0x80105B04),
        shift(MORE, IMM, 0x801072CC, 0x801073F4),
        shift(MORE, LUI, 0x80105A9C),
        shift(2 * MORE, LUI, 0x80105AD0, 0x80105B30),
        shift(3 * MORE, LUI, 0x80105B18),
    ]),
    // Overlay 55: SILLY_SCREWS
    Patch(55, 0x2881B0F9, 0x21BC772D, [
        shift(HALF, IMM, 0x801060F4),
        shift(HALF, LUI, 0x80105A90),
        shift(MORE, LUI, 0x80105A9C),
        shift(2 * MORE, LUI, 0x80105AD0, 0x80105B30),
        shift(3 * MORE, LUI, 0x80105B18),
        scale(LUI, 0x80109254),
    ], join([
        F(0x80105B04, 161, 220), // lui a1, 0x4321
        KF(0x80106484, 0x80106488, 1050f, scaled(1050.0)), // lui at, 0x4483; ori at, at, 0x4000
        F(0x80106490, 1600, 2128), // lui at, 0x44c8
        KF(0x801065B0, 0x801065B4, 1500f, scaled(1500.0)), // lui at, 0x44bb; ori at, at, 0x8000
        KF(0x80106614, 0x80106618, 1700f, scaled(1700.0)), // lui at, 0x44d4; ori at, at, 0x8000
        KF(0x80106868, 0x8010686C, 1050f, scaled(1050.0)), // lui at, 0x4483; ori at, at, 0x4000
        F(0x80106874, 1600, 2128), // lui at, 0x44c8
        F(0x80106B60, 800, 1064), // lui at, 0x4448
        F(0x80109204, 800, 1064), // lui at, 0x4448
    ])),
    // Overlay 56: CROWD_COVER
    Patch(56, 0x6377407E, 0xB105E078, [
        shift(HALF, IMM, 0x8010629C, 0x801062E8, 0x80106458, 0x8010651C),
        shift(HALF, SHORT, 0x8010C6C4, 0x8010C6C8, 0x8010C6CC),
        shift(MORE, LUI, 0x80105A38),
        shift(2 * MORE, LUI, 0x80105A44),
    ]),
    // Overlay 57: TICK_TOCK_HOP
    Patch(57, 0x9ACE0E92, 0xE0B640A6, [
        shift(HALF, IMM, 0x80106194, 0x80106338, 0x80106A10),
        shift(MORE, LUI, 0x80105A80),
        shift(2 * MORE, LUI, 0x80105A8C),
    ]),
    // Overlay 58: FOWL_PLAY
    Patch(58, 0x47D61B04, 0xA7870267, [
        shift(HALF, IMM, 0x80106AA4, 0x80106ACC, 0x80106B28, 0x80106B64),
        shift(HALF, LUI, 0x80105A84, 0x80105AF8),
        shift(MORE, IMM, 0x80106B18),
        shift(MORE, LUI, 0x80105A90),
        shift(2 * MORE, LUI, 0x80105AC4, 0x80105B24),
        shift(3 * MORE, LUI, 0x80105B0C),
    ]),
    // Overlay 59: WINNERS_WHEEL
    Patch(59, 0xFB25FE37, 0x32E746BA, [
        shift(HALF, IMM, 0x801093AC),
        shift(HALF, LUI, 0x801093BC),
    ]),
    // Overlay 60: HEY_BATTER_BATTER
    Patch(60, 0x6075BFD7, 0x297203B6, [
        shift(HALF, IMM, 0x801067EC, 0x80106D20),
        shift(HALF, LUI, 0x80106804),
        shift(MORE, LUI, 0x80105B24),
        shift(2 * MORE, LUI, 0x80105B30),
    ]),
    // Overlay 61: BOBBING_BOW_LOONS
    Patch(61, 0x6A7E7B93, 0xFF98FFB8, [
        shift(HALF, IMM, 0x80107FB8),
        shift(HALF, LUI, 0x80107FC8),
    ]),
    // Overlay 62: DORRIE_DIP
    Patch(62, 0x26DB5DF8, 0x55C4770A, [
        shift(HALF, IMM, 0x80108750),
        shift(HALF, LUI, 0x80108760),
        shift(MORE, LUI, 0x80105BB8),
        shift(2 * MORE, LUI, 0x80105BC8),
    ], join([
        F(0x80105C44, 41.5, 36.75), // lui a1, 0x4226
    ])),
    // Overlay 63: SWINGING_WITH_SHARKS
    Patch(63, 0x12A29AF9, 0xB691D435, [
        shift(MORE, LUI, 0x801059FC),
        shift(2 * MORE, LUI, 0x80105A08),
    ], join([
        KF(0x80105AA0, 0x80105AA4, -698f, -477), // lui at, 0xc42e; ori at, at, 0x8000
        F(0x80105ADC, 20, 18.375), // lui at, 0x41a0
    ])),
    // Overlay 64: SWING_N_SWIPE
    Patch(64, 0x9FDF6278, 0x2E37933B, [
        shift(HALF, IMM, 0x80105C34),
        shift(HALF, LUI, 0x80105A74),
        shift(2 * MORE, LUI, 0x80105A80),
    ]),
    // Overlay 65: STARDUST_BATTLE
    Patch(65, 0xE299D751, 0xC057E111, [
        shift(HALF, SHORT, 0x80113CE0, 0x80113CE2, 0x80113CE4, 0x80113CE6, 0x80113CE8, 0x80113CEA, 0x80113CEC,
                           0x80113CEE),
        shift(MORE, LUI, 0x80105A64),
        shift(2 * MORE, LUI, 0x80105A70),
    ]),
    // Overlay 66: GAME_GUYS_ROULETTE
    Patch(66, 0x7C65C5A9, 0xBD5CDE0D, [
        shift(HALF, IMM, 0x80105BE8, 0x8010663C, 0x801066C4, 0x80106740, 0x80106794, 0x801067E4, 0x80106830,
                         0x80106860, 0x80106890, 0x8010852C, 0x80108734, 0x801087F0, 0x80108880, 0x80109E2C),
        shift(MORE, IMM, 0x80106510),
        shift(MORE, LUI, 0x80105AE4),
        shift(2 * MORE, LUI, 0x80105AF0),
    ]),
    // Overlay 67: GAME_GUYS_LUCKY_7
    Patch(67, 0xC9038236, 0x4EFF1874, [
        shift(HALF, IMM, 0x801061CC, 0x8010866C, 0x80108714, 0x8010877C, 0x8010C93C),
        shift(HALF, SHORT, 0x8010D150, 0x8010D156, 0x8010D15C, 0x8010D162, 0x8010D168, 0x8010D16E, 0x8010D174,
                           0x8010D17A, 0x8010D180, 0x8010D40E, 0x8010D41E, 0x8010D42E, 0x8010D43A, 0x8010D446,
                           0x8010D452, 0x8010D45E, 0x8010D46A, 0x8010D476, 0x8010D482, 0x8010D48E, 0x8010D49A,
                           0x8010D4A6, 0x8010D4B2, 0x8010D4BE),
        shift(MORE, LUI, 0x80105B34),
        shift(2 * MORE, LUI, 0x80105B40),
    ]),
    // Overlay 68: GAME_GUYS_MAGIC_BOXES
    Patch(68, 0xF3066E76, 0x3959FDCA, [
        shift(HALF, IMM, 0x80106224, 0x80106284, 0x80106394, 0x801063F0, 0x80106474, 0x80106500, 0x8010704C,
                         0x80107A50, 0x80107BB0, 0x80107F74, 0x80107F90, 0x80108510, 0x80108514, 0x80108958,
                         0x80108D0C, 0x80108F50, 0x80109018, 0x80109084, 0x8010A084, 0x8010A910, 0x8010B9CC,
                         0x8010BCD0, 0x8010BCD8, 0x8010BD50),
        shift(MORE, IMM, 0x8010606C, 0x8010A2C8, 0x8010A474, 0x8010BD10, 0x8010BED4, 0x8010C050, 0x8010C138),
        shift(MORE, LUI, 0x80109A70),
        shift(2 * MORE, LUI, 0x80109A7C),
        shift(120 * MORE, IMM, 0x8010A0F0, 0x8010A100, 0x8010A15C, 0x8010BA78, 0x8010BA88, 0x8010BB30, 0x8010BB40,
                               0x8010BB7C, 0x8010BBC0),
    ]),
    // Overlay 69: GAME_GUYS_SWEET_SURPRISE
    Patch(69, 0x2DD18EFE, 0xDC9E9F71, [
        shift(HALF, IMM, 0x80106378, 0x801065C0, 0x8010675C, 0x801067C4, 0x80106C18, 0x801074A0, 0x801074C8,
                         0x801074E8, 0x80107538, 0x80107778, 0x801077A4, 0x80107AB8, 0x80107AE0, 0x80107AFC,
                         0x80108554, 0x8010C35C),
        shift(HALF, SHORT, 0x8010CBCE, 0x8010CBD6),
        shift(MORE, LUI, 0x80105B24),
        shift(2 * MORE, LUI, 0x80105B30),
    ], join([
        I(0x80107578, 0x118, 0x14C), // lui s3, 0x118
        I(0x80107B18, 66, 106), // li a3, 66
        I(0x80107B34, 78, 106), // li a3, 78
    ])),
    // Overlay 70: DIZZY_DINGHIES
    Patch(70, 0xD2929F7A, 0x8C672949, [
        shift(MORE, LUI, 0x80105A14),
        shift(2 * MORE, LUI, 0x80105A20),
    ]),
    // Overlay 72: CHILLY_WATERS_BOARD
    Patch(72, 0xD3A1E266, 0x288866BC, [
        shift(HALF, IMM, 0x8010C088, 0x8010C438, 0x8010C4A0, 0x80113F8C, 0x8011402C, 0x80114070, 0x80114168,
                         0x801141AC, 0x801141E8, 0x80115618, 0x8011563C, 0x8011565C, 0x80116228, 0x80119F28),
        shift(HALF, LUI, 0x80113BA0, 0x80113F74, 0x80114018, 0x80114058, 0x80114150, 0x80114194, 0x801141D0,
                         0x80115E00, 0x80115E94),
        shift(HALF, FLOAT, 0x8011E354, 0x8011E35C, 0x8011E364, 0x8011E36C, 0x8011E374, 0x8011E37C, 0x8011E384,
                           0x8011E38C, 0x8011E394, 0x8011E39C, 0x8011E3A4, 0x8011E3AC, 0x8011E3B4, 0x8011E3BC,
                           0x8011E3C4, 0x8011E3CC),
        shift(MORE, FLOAT, 0x8011E1F4, 0x8011E204), // Fixed: the patch moved a 1.0 at 0x8011E214 instead of 0x8011E1F4
    ]),
    // Overlay 73: DEEP_BLOOBER_SEA_BOARD
    Patch(73, 0xB17C7D36, 0xD370CB0E, [
        shift(HALF, IMM, 0x8010BBF0, 0x8010BFA0, 0x8010C008, 0x80113AF4, 0x80113B94, 0x80113BD8, 0x80113CD0,
                         0x80113D14, 0x80113D50, 0x80115180, 0x801151A4, 0x801151C4, 0x80115D90, 0x80119AB0,
                         0x8011A3CC),
        shift(HALF, LUI, 0x80113708, 0x80113ADC, 0x80113B80, 0x80113BC0, 0x80113CB8, 0x80113CFC, 0x80113D38,
                         0x80115968, 0x801159FC),
        shift(HALF, FLOAT, 0x8011D710, 0x8011D718, 0x8011D720, 0x8011D728, 0x8011D730, 0x8011D738, 0x8011D740,
                           0x8011D748, 0x8011D750, 0x8011D758, 0x8011D760, 0x8011D768, 0x8011D770, 0x8011D778,
                           0x8011D780, 0x8011D788, 0x8011EB34),
        shift(MORE, FLOAT, 0x8011D5B0, 0x8011D5C0),
    ]),
    // Overlay 74: SPINY_DESERT_BOARD
    Patch(74, 0x9BCEA6CE, 0xA99A9510, [
        shift(HALF, IMM, 0x8010C160, 0x8010C510, 0x8010C578, 0x80114064, 0x80114104, 0x80114148, 0x80114240,
                         0x80114284, 0x801142C0, 0x801156F0, 0x80115714, 0x80115734, 0x80116300, 0x80118600),
        shift(HALF, LUI, 0x80113C78, 0x8011404C, 0x801140F0, 0x80114130, 0x80114228, 0x8011426C, 0x801142A8,
                         0x80115ED8, 0x80115F6C),
        shift(HALF, FLOAT, 0x8011D24C, 0x8011D254, 0x8011D25C, 0x8011D264, 0x8011D26C, 0x8011D274, 0x8011D27C,
                           0x8011D284, 0x8011D28C, 0x8011D294, 0x8011D29C, 0x8011D2A4, 0x8011D2AC, 0x8011D2B4,
                           0x8011D2BC, 0x8011D2C4),
        shift(MORE, FLOAT, 0x8011D0EC, 0x8011D0FC),
    ]),
    // Overlay 75: WOODY_WOODS_BOARD
    Patch(75, 0x1587A713, 0xA1C44949, [
        shift(HALF, IMM, 0x8010BC28, 0x8010BFD8, 0x8010C040, 0x80113B2C, 0x80113BCC, 0x80113C10, 0x80113D08,
                         0x80113D4C, 0x80113D88, 0x801151B8, 0x801151DC, 0x801151FC, 0x80115DC8, 0x80117F6C,
                         0x80118804),
        shift(HALF, IMM, 0x801195F0), // Added: the patch moved this window's X in its other copy (0x80118804), not here
        shift(HALF, LUI, 0x80113740, 0x80113B14, 0x80113BB8, 0x80113BF8, 0x80113CF0, 0x80113D34, 0x80113D70,
                         0x801159A0, 0x80115A34),
        shift(HALF, FLOAT, 0x8011C804, 0x8011C80C, 0x8011C814, 0x8011C81C, 0x8011C824, 0x8011C82C, 0x8011C834,
                           0x8011C83C, 0x8011C844, 0x8011C84C, 0x8011C854, 0x8011C85C, 0x8011C864, 0x8011C86C,
                           0x8011C874, 0x8011C87C),
        shift(MORE, FLOAT, 0x8011C6A4, 0x8011C6B4),
    ]),
    // Overlay 76: CREEPY_CAVERN_BOARD
    Patch(76, 0x1001D0D7, 0xF2617FF5, [
        shift(HALF, IMM, 0x8010B634, 0x8010B9E4, 0x8010BA4C, 0x80113538, 0x801135D8, 0x8011361C, 0x80113714,
                         0x80113758, 0x80113794, 0x80114BC4, 0x80114BE8, 0x80114C08, 0x801157D4, 0x80117B28,
                         0x80118804),
        shift(HALF, LUI, 0x8011314C, 0x80113520, 0x801135C4, 0x80113604, 0x801136FC, 0x80113740, 0x8011377C,
                         0x801153AC, 0x80115440),
        shift(HALF, FLOAT, 0x8011ECB4, 0x8011ECBC, 0x8011ECC4, 0x8011ECCC, 0x8011ECD4, 0x8011ECDC, 0x8011ECE4,
                           0x8011ECEC, 0x8011ECF4, 0x8011ECFC, 0x8011ED04, 0x8011ED0C, 0x8011ED14, 0x8011ED1C,
                           0x8011ED24, 0x8011ED2C),
        shift(MORE, FLOAT, 0x8011EB54, 0x8011EB64),
    ]),
    // Overlay 77: WALUIGIS_ISLAND_BOARD
    Patch(77, 0x7932E39B, 0x6A1ED29A, [
        shift(HALF, IMM, 0x80108C94), // Added: the item being bought, which the patch moved in the other boards
        shift(HALF, IMM, 0x8010D418, 0x8010D7C8, 0x8010D830, 0x8011531C, 0x801153BC, 0x80115400, 0x801154F8,
                         0x8011553C, 0x80115578, 0x801169A8, 0x801169CC, 0x801169EC, 0x801175B8),
        shift(HALF, LUI, 0x80114F30, 0x80115304, 0x801153A8, 0x801153E8, 0x801154E0, 0x80115524, 0x80115560,
                         0x80117190, 0x80117224),
        shift(HALF, FLOAT, 0x8011CA44, 0x8011CA4C, 0x8011CA54, 0x8011CA5C, 0x8011CA64, 0x8011CA6C, 0x8011CA74,
                           0x8011CA7C, 0x8011CA84, 0x8011CA8C, 0x8011CA94, 0x8011CA9C, 0x8011CAA4, 0x8011CAAC,
                           0x8011CAB4, 0x8011CABC),
        shift(MORE, FLOAT, 0x8011C8E4, 0x8011C8F4),
    ]),
    // Overlay 78
    Patch(78, 0x12A350B2, 0x720C4695, [
        shift(HALF, IMM, 0x8010960C, 0x80109688, 0x8010970C, 0x80109788, 0x80109824, 0x801098A0, 0x801099F4,
                         0x80109AD4, 0x8010B1C8, 0x8010B288),
        scale(LUI, 0x8010B1D8),
    ]),
    // Overlay 79: FINISH_BOARD
    Patch(79, 0x12B15723, 0x6EA470C2, [
        shift(HALF, IMM, 0x80106084, 0x8010B984),
        scale(FLOAT, 0x8010E4C8, 0x8010E970, 0x8010E978, 0x8010E988, 0x8010E990, 0x8010E998, 0x8010E9A8),
    ]),
    // Overlay 80: BOWSER_EVENT
    Patch(80, 0x23A7CA9A, 0xD46E38ED, [
        shift(HALF, IMM, 0x80106904, 0x80107C18, 0x80107F58),
        shift(HALF, LUI, 0x80107C44, 0x80107C64, 0x80107F84, 0x80107FA4),
        shift(HALF, SHORT, 0x8010937C, 0x80109384, 0x8010938C, 0x80109394, 0x8010939C),
    ]),
    // Overlay 81: LAST_FIVE_TURNS
    Patch(81, 0x78A45567, 0xD3C7BDBD, [
        shift(HALF, IMM, 0x80105E9C, 0x80105F38, 0x80106038, 0x80106074, 0x80106230, 0x8010642C, 0x80106470,
                         0x80106510, 0x80106558, 0x80106590, 0x80106608, 0x8010694C, 0x80106B40, 0x80106D2C,
                         0x80106D94, 0x80106E34, 0x80106E7C, 0x80106EB4, 0x80106F60, 0x80106FBC),
        scale(FLOAT, 0x80107480),
    ]),
    // Overlay 82: GENIE
    Patch(82, 0x2684D254, 0xAEE95D4E, [
        shift(HALF, IMM, 0x80106F34),
    ], join([
        F(0x80106F4C, 50, 53), // lui a2, 0x4248
    ])),
    // Overlay 83: START_BOARD
    Patch(83, 0xF7D997BA, 0xE0E694B5, [
        shift(HALF, IMM, 0x801064DC, 0x80106688),
    ]),
    // Overlay 84: START_BOARD_TUTORIAL
    Patch(84, 0x5962BACF, 0x9061F922, [
        shift(HALF, IMM, 0x80106938, 0x8010701C),
    ]),
    // Overlay 85: FINAL_RESULTS
    Patch(85, 0x96197DFE, 0x1FDD4AD8, [
        shift(HALF, IMM, 0x80105F28, 0x80107C40, 0x80107D08, 0x80107DB8, 0x80107E68, 0x80108B04, 0x80108BB4,
                         0x80108C2C, 0x80108CF0, 0x80108D90, 0x80108DE0, 0x801090D0, 0x80109170, 0x801091C0,
                         0x80109284, 0x801092A4),
        shift(HALF, SHORT, 0x801097C2, 0x801097C6, 0x801097CA, 0x801097CE),
        scale(IMM, 0x80108E68, 0x80108F44),
    ], join([
        I(0x801075B4, 4, 6), // addiu v0, v0, 4
        I(0x801075E8, 64, 96), // slti v0, s3, 64
        I(0x801078E4, 4, 6), // addiu v0, v0, 4
        I(0x80108208, 64, 96), // li a0, 64
        I(0x801082DC, 64, 96), // slti v0, s3, 64
        I(0x80108740, 64, 96), // slti v0, s0, 64
        // The detailed results show 6 of their 13 columns instead of 4: the cursor goes up to 5 instead of 3, and the
        // first column shown up to 7 instead of 9 (fixed: the patch made it 6, so the last column was never shown)
        I(0x801093F4, 4, 6), // slti v0, v0, 4
        I(0x801093FC, 3, 5), // li v0, 3
        I(0x8010941C, 10, 8), // slti v0, v0, 10
        I(0x80109424, 9, 7), // li v0, 9
        // The right arrow hides at the end (fixed to match: the patch changed only one of these two checks)
        I(0x8010890C, 9, 7), // li v0, 9
        I(0x80108914, 3, 5), // li v0, 3
        I(0x80109550, 9, 7), // li v0, 9
        I(0x80109558, 3, 5), // li v0, 3
    ])),
    // Overlay 88: OPENING_CREDITS
    Patch(88, 0x7ADB5D82, 0x54C5A79B, [
        shift(HALF, IMM, 0x80105CC0, 0x80105D8C, 0x80105E50),
    ]),
    // Overlay 89
    Patch(89, 0xA8AC9505, 0x01478867, [
        shift(HALF, IMM, 0x80105C28, 0x80105C3C, 0x80105C64, 0x80105C84, 0x80105CA4, 0x80105CB4, 0x80105CC8,
                         0x801060FC),
    ]),
    // Overlay 91: GATE_GUY_BOARD
    Patch(91, 0x7F9EC066, 0x9904D379, [
        shift(HALF, IMM, 0x8010F230, 0x8010F474, 0x8010F554, 0x8010F634, 0x801139BC, 0x80113ADC, 0x80113B44,
                         0x80113BAC, 0x80113BD0, 0x80113C00),
        shift(HALF, SHORT, 0x80118F60, 0x80118F64, 0x80118F68),
    ]),
    // Overlay 92: ARROWHEAD_BOARD
    Patch(92, 0x5C3FD20A, 0xE98F1718, [
        shift(HALF, IMM, 0x8010F270, 0x8010F4B4, 0x8010F594, 0x8010F674, 0x801139FC, 0x80113B1C, 0x80113B84,
                         0x80113BEC, 0x80113C10, 0x80113C40),
        shift(HALF, SHORT, 0x80117170, 0x80117174, 0x80117178),
    ]),
    // Overlay 93: PIPESQUEAK_BOARD
    Patch(93, 0x8AED7B3A, 0x98708932, [
        shift(HALF, IMM, 0x8010F064, 0x8010F2A8, 0x8010F388, 0x8010F468, 0x801137F0, 0x80113910, 0x80113978,
                         0x801139E0, 0x80113A04, 0x80113A34),
        shift(HALF, SHORT, 0x80117C30, 0x80117C34, 0x80117C38),
    ]),
    // Overlay 94: BLOWHARD_BOARD
    Patch(94, 0x53055A6A, 0x5CD55141, [
        shift(HALF, IMM, 0x8010F2EC, 0x8010F530, 0x8010F610, 0x8010F6F0, 0x80113A84, 0x80113BA4, 0x80113C0C,
                         0x80113C74, 0x80113C98, 0x80113CC8),
        shift(HALF, SHORT, 0x8011AFDC, 0x8011AFE0, 0x8011AFE4),
    ]),
    // Overlay 95: MR_MOVER_BOARD
    Patch(95, 0xDDC9ADAB, 0x66A2DAF0, [
        shift(HALF, IMM, 0x8010F200, 0x8010F444, 0x8010F524, 0x8010F604, 0x8011398C, 0x80113AAC, 0x80113B14,
                         0x80113B7C, 0x80113BA0, 0x80113BD0),
        shift(HALF, SHORT, 0x80115ED0, 0x80115ED4, 0x80115ED8),
    ]),
    // Overlay 96: BACKTRACK_BOARD
    Patch(96, 0xAD03C912, 0x6A370BF5, [
        shift(HALF, IMM, 0x8010F3F8, 0x8010F63C, 0x8010F71C, 0x8010F7FC, 0x80113B84, 0x80113CA4, 0x80113D0C,
                         0x80113D74, 0x80113D98, 0x80113DC8),
        shift(HALF, SHORT, 0x801148A0, 0x801148A4, 0x801148A8),
    ]),
    // Overlay 97
    Patch(97, 0xD2428AA2, 0x41DDC186, [
        shift(HALF, IMM, 0x8010DE40, 0x80110080, 0x801100DC, 0x8011015C, 0x801101B0, 0x80110328, 0x80110494,
                         0x801104F8, 0x8011054C, 0x801120E0, 0x80112320, 0x801123FC, 0x801124D8, 0x801145EC,
                         0x80114754, 0x801147C4, 0x80114834, 0x80114860, 0x80114898),
        shift(HALF, SHORT, 0x80114BF0, 0x80114BF4, 0x80114BF8),
        scale(LUI, 0x8010DE50),
    ], join([
        I(0x8010DF00, 160, 210), // li a2, 160
    ])),
    // Overlay 98: DUEL_FINISH_BOARD
    Patch(98, 0x8EDC3071, 0xC64D0B13, [
        shift(HALF, IMM, 0x8010607C, 0x801092DC, 0x8010A824),
        scale(FLOAT, 0x8010D36C, 0x8010D6E0, 0x8010D6E8, 0x8010D6F8, 0x8010D700, 0x8010D708, 0x8010D718),
    ]),
    // Overlay 99: DUEL_FINAL_RESULTS
    Patch(99, 0x87DEF9F5, 0x4B3AFE3A, [
        shift(HALF, IMM, 0x80106650, 0x80106710, 0x801067DC, 0x801067FC, 0x801076D8, 0x801077AC, 0x8010785C,
                         0x8010790C, 0x80108718, 0x80108738),
        scale(IMM, 0x80108528, 0x80108604),
    ], join([
        I(0x8010707C, 4, 6), // addiu v0, v0, 4
        I(0x801070B0, 64, 96), // slti v0, s3, 64
        I(0x801073D4, 4, 6), // addiu v0, v0, 4
        I(0x80107CAC, 64, 96), // li a0, 64
        I(0x80107D80, 64, 96), // slti v0, s3, 64
        I(0x801081E4, 64, 96), // slti v0, s0, 64
        I(0x80108888, 4, 6), // slti v0, v0, 4
        I(0x80108890, 3, 5), // li v0, 3
        I(0x801088B0, 7, 5), // slti v0, v0, 7
        I(0x801088B8, 6, 4), // li v0, 6
        I(0x801089EC, 3, 5), // li v0, 3
    ])),
    // Overlay 100: START_DUEL_BOARD
    Patch(100, 0x5EAA1C0D, 0x165A12D8, [
        shift(HALF, IMM, 0x801064A4, 0x80106650),
        shift(HALF, SHORT, 0x801094F0, 0x801094F4),
        scale(FLOAT, 0x801092EC, 0x801092F8),
    ]),
    // Overlay 101: START_DUEL_BOARD_TUTORIAL
    Patch(101, 0x67903023, 0x5CB58919, [
        shift(HALF, IMM, 0x80106CE8),
        shift(HALF, SHORT, 0x80108BBC, 0x80108BC0),
        scale(FLOAT, 0x80108A04, 0x80108A10),
    ]),
    // Overlay 103
    Patch(103, 0x32350FC8, 0xA11653D1, [
        shift(HALF, IMM, 0x80105A70, 0x80105B04, 0x80105BA4, 0x80105C44, 0x80105CE4),
    ]),
    // Overlay 104: MINI_GAME_ROOM_RETRY
    Patch(104, 0x7D5ABA0E, 0x092CF69A, [
        shift(HALF, IMM, 0x80105E8C, 0x80105EA4, 0x80106004, 0x8010600C, 0x80106F04, 0x801080F0, 0x80108228),
        shift(HALF, LUI, 0x8010634C, 0x80106628, 0x80106900, 0x801069D8, 0x80106ACC, 0x80107A78, 0x80107FA0,
                         0x80108320, 0x80108474),
        shift(MORE, IMM, 0x80105DFC, 0x801063DC, 0x80107B08, 0x80107BA0),
    ]),
    // Overlay 105: MINI_GAME_ROOM
    Patch(105, 0x357B9B41, 0xAEB19F9A, [
        shift(HALF, IMM, 0x80109220, 0x80109274, 0x801092D4, 0x8010A200, 0x8010A314, 0x8010A320, 0x8010A490,
                         0x8010CC60, 0x8010D4D4, 0x8010D4EC, 0x8010D504, 0x8010D830, 0x8010DC4C, 0x8010E058,
                         0x8010F3A4, 0x8010F6E4, 0x8010F77C, 0x8010F814, 0x8010F898, 0x80110608, 0x8011066C,
                         0x801107BC, 0x80110848, 0x80110A54, 0x80110AE0, 0x80110CE0, 0x80110D6C, 0x80110EF4,
                         0x80110F78, 0x8011149C, 0x801115CC, 0x80111734, 0x80111838, 0x80113784, 0x801137C4,
                         0x80114450, 0x80114478, 0x80114484, 0x80114864, 0x801148D0, 0x8011493C, 0x80114994,
                         0x801149D0, 0x80114A64, 0x80114B2C, 0x80114BB8, 0x80114C38, 0x80114C9C),
        shift(HALF, SHORT, 0x80119158, 0x8011915C, 0x80119160, 0x80119164, 0x80119168, 0x80119170, 0x80119174,
                           0x80119178, 0x8011917C, 0x80119180, 0x80119184, 0x80119188, 0x80119424, 0x80119428,
                           0x8011943C, 0x80119440, 0x80119444, 0x80119454, 0x80119458, 0x8011945C, 0x80119460,
                           0x80119464, 0x801195B0, 0x801195B4, 0x8011A2CA),
        shift(MORE, IMM, 0x801060B0, 0x801073CC, 0x8010AFB8, 0x8010BF1C, 0x80112234, 0x801140F4),
        shift(MORE, LUI, 0x80105A18, 0x80105A7C),
        shift(MORE, SHORT, 0x801192CA),
        shift(2 * MORE, LUI, 0x80105A24),
    ], join([
        K(0x8010AF9C, 0x8010AFA0, 0x003D0800, DEPTH_BUFFER), // lui a0, 0x3D; ori a0, a0, 0x800: the depth buffer (fixed: see the top)
        H(0x801192B0, -2481, -2455),
        H(0x80119F2E, 160, 232),
    ])),
    // Overlay 106: CHANCE_TIME
    Patch(106, 0x3BF3EDEE, 0x2AE7358D, [
        shift(HALF, IMM, 0x80106274, 0x801062B4, 0x8010BD9C, 0x8010C784, 0x8010C7D0, 0x8010C888, 0x8010C8A0,
                         0x8010DE90),
        shift(HALF, LUI, 0x80105B88),
        shift(MORE, LUI, 0x80105BB4, 0x80105BCC),
        shift(2 * MORE, LUI, 0x80105BD8),
    ], join([
        F(0x80105B90, 215, 268), // lui a3, 0x4357
        F(0x8010ECAC, 8.5, 13.6875), // lui at, 0x4108
    ])),
    // Overlay 107
    Patch(107, 0xF56A1F52, 0x3EFE6F8F, [
        shift(HALF, IMM, 0x80105E38, 0x80106050, 0x801060B4, 0x8010616C, 0x80106298, 0x8010698C),
        shift(MORE, LUI, 0x80105AA0),
        shift(2 * MORE, LUI, 0x80105AAC),
        scale(LUI, 0x801062AC),
    ]),
    // Overlay 108
    Patch(108, 0x0AEE7701, 0xE85ECE41, [
        shift(HALF, IMM, 0x8010601C, 0x801063E8, 0x80106508, 0x8010656C, 0x80106624, 0x80106750),
        shift(MORE, LUI, 0x80105A90),
        shift(2 * MORE, LUI, 0x80105A9C),
        scale(LUI, 0x80106764),
    ]),
    // Overlay 109
    Patch(109, 0x791F5158, 0x268A7BB4, [
        shift(HALF, IMM, 0x80105FB4, 0x80106378, 0x80106498, 0x801064FC, 0x801065B4, 0x801066E0),
        shift(MORE, LUI, 0x80105A90),
        shift(2 * MORE, LUI, 0x80105A9C),
        scale(LUI, 0x801066F4),
    ]),
    // Overlay 110
    Patch(110, 0xAB43B4AB, 0x8D3EEA9F, [
        shift(HALF, IMM, 0x80105F78, 0x80106198, 0x801061FC, 0x801062B4, 0x801063F0, 0x80106C18, 0x8010ECC4,
                         0x8010EEB0),
        shift(HALF, SHORT, 0x80111BA4, 0x80111BA8, 0x80111BAC, 0x80111BB0, 0x80111BB4, 0x80111BB8, 0x80111BBC,
                           0x80111BC0, 0x80111BC4, 0x80111BC8, 0x80111BCC, 0x80111BD0, 0x80111BD4, 0x80111BD8,
                           0x80111BDC, 0x80111BE0, 0x80111BE4, 0x80111BE8, 0x80111BEC, 0x80111BF0, 0x80111BF4,
                           0x80111BF8, 0x801120F4, 0x801120F6, 0x801120F8, 0x801120FC, 0x801120FE, 0x80112100,
                           0x80112102, 0x80112104, 0x80112106, 0x80112108, 0x8011210A, 0x8011210C, 0x8011210E,
                           0x80112110, 0x80112112),
        shift(MORE, LUI, 0x80105AA0),
        shift(2 * MORE, LUI, 0x80105AAC),
        scale(LUI, 0x80106404),
    ], join([
        H(0x801120FA, 92, 146),
    ])),
    // Overlay 111
    Patch(111, 0xC10FA46F, 0x71B4FE07, [
        shift(HALF, IMM, 0x80105E6C, 0x80106084, 0x801060E8, 0x801061A0, 0x801062CC, 0x801069C0),
        shift(MORE, LUI, 0x801059EC),
        shift(2 * MORE, LUI, 0x801059F8),
        scale(LUI, 0x801062E0),
    ]),
    // Overlay 112: MINI_GAME_RULES
    Patch(112, 0xD6E93C9C, 0xF5222C70, [
        shift(HALF, IMM, 0x801063CC, 0x8010BA90, 0x8010BC10, 0x8010BE98, 0x8010BEB8, 0x8010BEC4, 0x8010BED8,
                         0x8010BFD4, 0x8010BFE0, 0x8010BFFC, 0x8010C06C, 0x8010C088, 0x8010CF80, 0x8010CFDC),
        shift(HALF, LUI, 0x8010CF4C, 0x8010CFA8),
        shift(HALF, SHORT, 0x8010DAFA, 0x8010DAFE, 0x8010DB02),
        shift(MORE, LUI, 0x80105B78),
        shift(2 * MORE, LUI, 0x80105B84),
    ]),
    // Overlay 113: MINI_GAME_RESULTS
    Patch(113, 0x2247315C, 0xF0D4DDFE, [
        shift(HALF, IMM, 0x801071BC, 0x80107218),
        shift(MORE, LUI, 0x80105A14),
        shift(2 * MORE, LUI, 0x801059E8),
    ], join([
        K(0x80107170, 0x80107174, 0xF64FC3BC, 0xF669C3BC), // lui v1, 0xf64f; ori v1, v1, 0xc3bc
    ])),
    // Overlay 114: GAMBLE_GAME_RESULTS
    Patch(114, 0xD547FEF5, 0xEE2299F2, [
        shift(HALF, IMM, 0x801062E4, 0x801083D4, 0x80108768, 0x8010877C, 0x801087E8),
        shift(MORE, LUI, 0x80105ACC),
        shift(2 * MORE, LUI, 0x80105AA0),
    ], join([
        K(0x801083D8, 0x801083DC, 0xF5882800, 0xF5883600), // lui s4, 0xf588; ori s4, s4, 0x2800
        K(0x801083EC, 0x801083F0, 0x0727E000, 0x0734E000), // lui s0, 0x727; ori s0, s0, 0xe000
        K(0x801083F8, 0x801083FC, 0xF5802800, 0xF5803600), // lui t8, 0xf580; ori t8, t8, 0x2800
        K(0x80108404, 0x80108408, 0x004FC000, 0x0069C000), // lui t6, 0x4f; ori t6, t6, 0xc000
        K(0x8010840C, 0x80108410, 0x00500028, 0x0069C028), // lui t5, 0x50; ori t5, t5, 0x28
        I(0x80108414, 0xE450, 0xE46A), // lui t4, 0xe450
        I(0x801087A8, 163, 221), // li a1, 163
    ])),
    // Overlay 115: DUEL_GAME_RESULTS
    Patch(115, 0x2DC82650, 0x7F774216, [
        shift(HALF, SHORT, 0x80108EA0, 0x80108EA4),
        scale(LUI, 0x80108798, 0x801087B0, 0x80108860),
    ], join([
        F(0x801069E0, -460, -596), // lui a1, 0xc3e6
        F(0x80106A10, -460, -596), // lui a1, 0xc3e6
        F(0x80106D78, -460, -596), // lui at, 0xc3e6
        F(0x80106D94, 240, 356), // lui at, 0x4370
        F(0x80106FE8, 460, 596), // lui a1, 0x43e6
        F(0x80107018, 460, 596), // lui a1, 0x43e6
        F(0x80107314, 460, 596), // lui at, 0x43e6
        F(0x80107330, 240, 356), // lui at, 0x4370
    ])),
    // Overlay 116: BATTLE_GAME_RESULTS
    Patch(116, 0x52047B0F, 0x28DA6469, [
        shift(HALF, LUI, 0x80105A8C),
        shift(2 * MORE, LUI, 0x80105A98),
    ], join([
        K(0x8010608C, 0x80106090, 0xF64FC3BC, 0xF669C3BC), // lui v1, 0xf64f; ori v1, v1, 0xc3bc
    ])),
    // Overlay 118: MESSAGE_CHECK
    Patch(118, 0xE3BBACC9, 0x8F4709B8, [
        shift(HALF, IMM, 0x80105C14, 0x80105E28, 0x80105E5C),
    ]),
    // Overlay 119: CASTLE_GROUNDS
    Patch(119, 0xE0395330, 0x577F03BF, [
        shift(HALF, IMM, 0x80108070, 0x80108224, 0x80108270, 0x801082CC, 0x801083D8, 0x801084CC, 0x8010BC74,
                         0x8010C0B8, 0x8010C0D4, 0x8010C46C, 0x8010C484, 0x8010C580, 0x8010C5A4, 0x8010C5E8,
                         0x8010C638, 0x8010C668, 0x8010C6E0, 0x8010D62C, 0x8010E0A8, 0x8010E0AC),
        shift(MORE, LUI, 0x80105A8C),
        shift(2 * MORE, LUI, 0x80105A98),
    ]),
    // Overlay 120: GAME_SETUP
    Patch(120, 0x0D3872E9, 0x9D1EC2A0, [
        shift(HALF, IMM, 0x8010B5EC, 0x8010B698, 0x8010EDC4, 0x8010FBE8, 0x8010FBEC, 0x801139CC, 0x801139D0,
                         0x80114004, 0x80114008, 0x801142D0, 0x80114848, 0x80114B7C, 0x80114B80, 0x801160FC,
                         0x80116100, 0x80116A00, 0x80116A04, 0x8011713C, 0x80117140, 0x80118E9C, 0x80118EA8),
        shift(HALF, SHORT, 0x80119B60, 0x80119B64, 0x80119B68, 0x80119B6C, 0x80119B70, 0x80119B74, 0x80119B78,
                           0x80119B7C, 0x80119B80, 0x80119B84, 0x80119B88, 0x80119B8C, 0x80119B90, 0x80119B98,
                           0x80119DE8, 0x80119DEC, 0x80119DF0, 0x80119DF4, 0x80119DF8, 0x80119DFC, 0x80119E00,
                           0x80119E04, 0x80119E08, 0x8011A514, 0x8011A518, 0x8011A51C, 0x8011A520, 0x8011A524,
                           0x8011A528, 0x8011A52C, 0x8011A530, 0x8011A534, 0x8011A538, 0x8011A53C, 0x8011A540),
        scale(FLOAT, 0x8011A0DC, 0x8011A10C),
    ], join([
        DD(0x8011A838, 1.3333333730697632, ASPECT),
    ])),
    // Overlay 121: FILE_SELECTION
    Patch(121, 0xA3F8C989, 0x96922A8A, [
        shift(HALF, IMM, 0x80105DBC, 0x80106A94, 0x8010A99C, 0x8010ACD0, 0x8010AD04, 0x8010AD38, 0x8010B274,
                         0x8010B2F0, 0x8010B5D8, 0x8010D180, 0x8010D19C, 0x8010D1DC, 0x8010D248, 0x8010D2A8,
                         0x8010D684, 0x8010D6A0, 0x8010D6D4, 0x8010D730, 0x8010D790, 0x8010D7E8, 0x8010D840,
                         0x8010F210),
        shift(HALF, LUI, 0x801086F0, 0x80108C78, 0x80108DB4, 0x801091C0, 0x8010AEC8, 0x8010AF2C),
        shift(HALF, FLOAT, 0x80112DF8, 0x80112E00),
        shift(MORE, LUI, 0x80105A8C, 0x8010898C, 0x801089A4, 0x80108B18, 0x80108B30),
        shift(MORE, SHORT, 0x801127D6, 0x801127DE),
        shift(2 * MORE, LUI, 0x80105A98),
    ]),
    // Overlay 122: TITLE_SCREEN
    Patch(122, 0x7B16F872, 0x7DE19550, [
        shift(HALF, IMM, 0x801063BC, 0x80108130, 0x801122E0, 0x8011231C, 0x80112358, 0x801123A4, 0x80112408,
                         0x80112454, 0x80114A74),
        shift(HALF, LUI, 0x8010FA1C, 0x8010FAE4),
        shift(HALF, SHORT, 0x80114CE6, 0x80114CF6, 0x80114D06, 0x80114D16, 0x80114D26, 0x80114D36, 0x80114D46,
                           0x80114D56, 0x80114D66, 0x80114D76),
        shift(MORE, LUI, 0x80105A30, 0x80105B00),
        shift(MORE, FLOAT, 0x80114BD8),
        shift(2 * MORE, LUI, 0x80105A3C),
        shift(2 * MORE, FLOAT, 0x80114BB8, 0x80114BC4),
    ], join([
        K(0x8011444C, 0x80114450, 0xF65003C0, 0xF66A03C0), // lui v0, 0xf650; ori v0, v0, 0x3c0
    ])),
    // Overlay 123: PEACHS_CASTLE
    Patch(123, 0x76AA3590, 0x9AC53EA9, [
        shift(HALF, IMM, 0x8010A8DC, 0x8010A914, 0x8010A918, 0x8010A92C, 0x8010BBCC, 0x8010BC40, 0x8010BDF8,
                         0x801133D4),
        shift(HALF, LUI, 0x8010989C),
        shift(MORE, IMM, 0x8010F1D4, 0x8010F1EC, 0x8010F210, 0x8010F3AC, 0x8010F7E4, 0x8010F7EC, 0x8010F81C),
        shift(MORE, LUI, 0x80105A30, 0x80105B00),
        shift(2 * MORE, LUI, 0x80105A3C),
    ], join([
        KF(0x80109868, 0x8010986C, 1.33333337f, ASPECT), // lui at, 0x3faa; ori at, at, 0xaaab
        I(0x8010F494, 176, 294), // li a1, 176
    ])),
    // Overlay 124: STAFF_CREDITS
    Patch(124, 0xE754346C, 0x13104F1E, [
        shift(HALF, IMM, 0x80106F58, 0x80107FF4, 0x801082A0, 0x801082AC, 0x8010C1C4, 0x8010DA18),
        shift(HALF, SHORT, 0x801105C8),
        shift(MORE, IMM, 0x8010DC28),
    ], join([
        H(0x801105D0, 286, 392),
        DF(0x80110630, -402, -580.668762),
        DF(0x80110648, -402, -580.668762),
    ])),
    // Overlay 125: STORY_RESULTS
    Patch(125, 0x1DDFE62A, 0xC6EA736D, [
        shift(HALF, IMM, 0x8010731C, 0x8010A50C),
        scale(LUI, 0x80107364),
    ], join([
        I(0x8010725C, 120, 212), // li s4, 120
    ])),
    // Overlay 127
    Patch(127, 0xBBC8CD34, 0x4747BFCA, [
        shift(HALF, IMM, 0x80106AA4, 0x80106B34, 0x80106B84, 0x80106BC0, 0x80106E40, 0x80106EBC, 0x80106F20,
                         0x80107870, 0x801078CC, 0x801082B4, 0x801084A8),
        shift(MORE, IMM, 0x8010799C, 0x80107D5C),
    ], join([
        I(0x80105DDC, 35, 45), // slti v0, s2, 35
    ])),
    // Overlay 128 (board code)
    Patch(128, 0x1CFBA996, 0x22B3CA65, [
        // Added (the patch missed these): where an item being bought or given goes, if it's on the screen (x from 0 to
        // 320.0): the middle of the screen, x = 160. The patch moved one of the two x's, but neither check's 320.0.
        shift(MORE, LUI, 0x800DB278, 0x800DBA9C),
        shift(HALF, IMM, 0x800DBB28),
        shift(HALF, IMM, 0x800DB2F0, 0x800DE070, 0x800DEEC4, 0x800DF074, 0x800DF788, 0x800DFAB8, 0x800E1FCC,
                         0x800E42A8, 0x800E54B0, 0x800E555C, 0x800E55D8, 0x800E5718, 0x800E96C4, 0x800EC098,
                         0x800EC0CC, 0x800EF494, 0x800EF54C, 0x800EF5C4, 0x800EF5DC, 0x800EF64C, 0x800EF97C,
                         0x800EFE98, 0x800F016C, 0x800F03D4, 0x800F0580, 0x800F073C, 0x800F113C, 0x800F1DFC,
                         0x800F548C, 0x800FBA88, 0x800FBD1C, 0x800FD9B8, 0x800FDA8C, 0x800FDC44, 0x800FDD2C,
                         0x800FDF4C, 0x800FE040, 0x800FE708),
        shift(HALF, LUI, 0x800E528C, 0x800E6A68, 0x800E6AE0, 0x800E6B2C, 0x800E939C, 0x800E9850, 0x800E9904,
                         0x800E99C0, 0x800E9C50, 0x800F54B8),
        shift(HALF, SHORT, 0x801007F4, 0x801007F8, 0x80100D94, 0x80100D98, 0x80100D9C, 0x80100E44, 0x80100E4C,
                           0x80100E54, 0x80100E5C, 0x80100E64, 0x80100E6C, 0x80100E74, 0x80100E7C, 0x801015FC,
                           0x801015FE, 0x80101600, 0x80101602, 0x801017B4, 0x801017B8, 0x801017BC, 0x801017C0,
                           0x801017C4, 0x801017D8, 0x801017EC, 0x80101800, 0x80101824, 0x80101828, 0x8010183C,
                           0x80101840, 0x80101844, 0x80101848, 0x8010184C, 0x80101850, 0x80101854, 0x80101858,
                           0x8010185C, 0x80101860, 0x80101864, 0x80101868, 0x8010186C, 0x80101870, 0x80101874,
                           0x80101878, 0x8010187C, 0x80101880, 0x80101884, 0x80101888, 0x80101EB8, 0x80101EBC,
                           0x80101EC0, 0x80101EC4, 0x80101EC8, 0x80101ECC),
        shift(MORE, LUI, 0x800D9520, 0x800E6B44, 0x800E75A8, 0x800E8888, 0x800E97C0, 0x800E9970, 0x800F2800,
                         0x800F28B8),
        shift(MORE, SHORT, 0x80101798, 0x801017A0, 0x801017A8, 0x801017B0, 0x801017C8, 0x801017D0, 0x801017E0,
                           0x801017E8, 0x801017F0, 0x801017F8, 0x80101804, 0x80101808, 0x8010180C, 0x80101810,
                           0x80101814, 0x80101818, 0x8010181C, 0x80101820, 0x80101830, 0x80101838, 0x80101EB4),
        shift(MORE, FLOAT, 0x80100F08, 0x80100F18, 0x80101A7C, 0x80101A8C),
        shift(2 * MORE, LUI, 0x800E91C8, 0x800E93A8),
        shift(4 * MORE, LUI, 0x800E5FD0),
        shift(-HALF, IMM, 0x800E75CC, 0x800E87BC, 0x800E87C8, 0x800E8878, 0x800E88C4),
        scale(IMM, 0x800E76A4, 0x800E8D68),
        scale(LUI, 0x800F1E0C),
    ], join([
        O(0x800DB8C4, BEQ, BLEZ), // beqz v0, 0x800DBC18: also skips a negative value
        I(0x800E6ED8, 0x8010, hi(BOARD_ARRAYS)), // lui a1, 0x8010: the board arrays
        I(0x800E6EDC, 13440, lo(BOARD_ARRAYS + 0x0)), // addiu a1, a1, 13440
        I(0x800E6EE4, 36, 72), // li a2, 36
        I(0x800E6EF0, 0x8010, hi(BOARD_ARRAYS)), // lui a1, 0x8010: the board arrays
        I(0x800E6EF4, 18584, lo(BOARD_ARRAYS + 0x120)), // addiu a1, a1, 18584
        I(0x800E6EFC, 36, 72), // li a2, 36
        I(0x800E6F08, 0x8010, hi(BOARD_ARRAYS)), // lui a1, 0x8010: the board arrays
        I(0x800E6F0C, 18752, lo(BOARD_ARRAYS + 0x120)), // addiu a1, a1, 18752
        I(0x800E6F14, 36, 72), // li a2, 36
        I(0x800E70DC, 0x8010, hi(BOARD_ARRAYS)), // lui s2, 0x8010: the board arrays
        I(0x800E70E0, 11736, lo(BOARD_ARRAYS + 0x360)), // addiu s2, s2, 11736
        I(0x800E710C, 36, 72), // slti v0, s0, 36
        I(0x800E7144, 0x8010, hi(BOARD_ARRAYS)), // lui s0, 0x8010: the board arrays
        I(0x800E7148, 11736, lo(BOARD_ARRAYS + 0x360)), // addiu s0, s0, 11736
        I(0x800E7174, 36, 72), // slti v0, s1, 36
        I(0x800E7180, 0x8010, hi(BOARD_ARRAYS)), // lui a0, 0x8010: the board arrays
        I(0x800E7184, 12456, lo(BOARD_ARRAYS + 0x900)), // addiu a0, a0, 12456
        I(0x800E718C, 144, 288), // li a1, 144
        I(0x800E71A8, 0x8010, hi(BOARD_ARRAYS)), // lui v1, 0x8010: the board arrays
        I(0x800E71AC, 11736, lo(BOARD_ARRAYS + 0x360)), // addiu v1, v1, 11736
        I(0x800E71D8, 36, 72), // slti v0, a0, 36
        I(0x800E7200, 0x8010, hi(BOARD_ARRAYS)), // lui s0, 0x8010: the board arrays
        I(0x800E7204, 11736, lo(BOARD_ARRAYS + 0x360)), // addiu s0, s0, 11736
        I(0x800E7230, 36, 72), // slti v0, s1, 36
        I(0x800E739C, 0x8010, hi(BOARD_ARRAYS)), // lui a3, 0x8010: the board arrays
        I(0x800E73A0, 11736, lo(BOARD_ARRAYS + 0x360)), // addiu a3, a3, 11736
        I(0x800E74A0, 36, 72), // slti v0, a2, 36
        I(0x800E75B0, 0x8010, hi(BOARD_ARRAYS)), // lui s6, 0x8010: the board arrays
        I(0x800E75B4, 12456, lo(BOARD_ARRAYS + 0x900)), // addiu s6, s6, 12456
        S(0x800E7664, 3, 4), // sll v0, v0, 3: array entries of 48 bytes instead of 24
        S(0x800E7690, 3, 4), // sll v1, v1, 3: array entries of 48 bytes instead of 24
        S(0x800E8A58, 3, 4), // sll v0, v0, 3: array entries of 48 bytes instead of 24
        I(0x800E8A5C, 0x8010, hi(BOARD_ARRAYS)), // lui t0, 0x8010: the board arrays
        I(0x800E8A60, 12456, lo(BOARD_ARRAYS + 0x900)), // addiu t0, t0, 12456
        KF(0x800E921C, 0x800E9220, 159.5f, 159.5 + HALF), // lui at, 0x431f; ori at, at, 0x8000
        F(0x800F28D4, 32, 49), // lui at, 0x4200
        I(0x800F2900, 9, 8), // slti v0, s0, 9
        F(0x800F2994, 32, 49), // lui at, 0x4200
        I(0x800F29C0, 9, 8), // slti v0, s0, 9
        H(0x801007F6, 252, 306),
        H(0x801007FA, 252, 306),
    ])),
    // Overlay 129 (board code)
    Patch(129, 0xD9A4553E, 0x20066064, [
        // Added (the patch missed these): the same as in BOARD_A's second check (its first the patch moved)
        shift(MORE, LUI, 0x800DAFB8),
        shift(HALF, IMM, 0x800DB044),
        shift(HALF, IMM, 0x800DA834, 0x800DDB70, 0x800DDD20, 0x800DE64C, 0x800DE7F8, 0x800DF430, 0x800E15CC,
                         0x800E32AC, 0x800E3358, 0x800E33D4, 0x800E3514, 0x800E3FB8, 0x800E4A08, 0x800E8500,
                         0x800EAC6C, 0x800EACA0, 0x800F09A4, 0x800F0A78, 0x800F0B00, 0x800F0B18, 0x800F0B7C,
                         0x800F0C00, 0x800F0F30, 0x800F144C, 0x800F1720, 0x800F1988, 0x800F1B54, 0x800F1D10,
                         0x800F2748, 0x800F3434, 0x800F6DC4, 0x800FB208, 0x800FB310),
        shift(HALF, LUI, 0x800E3088, 0x800E5478, 0x800E54C4, 0x800E81D8, 0x800E866C, 0x800E86C4, 0x800E8720,
                         0x800E87DC, 0x800E8A6C, 0x800F6DF8, 0x8010021C),
        shift(HALF, SHORT, 0x80100E8C, 0x80100E94, 0x80100E9C, 0x80100EA4, 0x80100EAC, 0x80100EB4, 0x80100EBC,
                           0x80100EC4, 0x80100FD4, 0x80100FD6, 0x80100FD8, 0x80100FDA, 0x80100FDC, 0x80100FDE,
                           0x80100FE0, 0x80101348, 0x8010134A, 0x80101B48, 0x80101B4C, 0x80101B50, 0x80101B54,
                           0x80101B58, 0x80101B5C),
        shift(MORE, LUI, 0x800D8684, 0x800DA7BC, 0x800E54DC, 0x800E5E6C, 0x800E7990, 0x800E85DC, 0x800E878C,
                         0x800F40B0, 0x800F4168, 0x800F42D0),
        shift(MORE, SHORT, 0x801014EC, 0x80101B44, 0x80101B80, 0x80101B84, 0x80101B88, 0x80101B8C, 0x80101B90),
        shift(MORE, FLOAT, 0x80100F58, 0x80102510, 0x80102518, 0x80102530, 0x80102538),
        shift(2 * MORE, LUI, 0x800E8004, 0x800E81E4),
        shift(4 * MORE, LUI, 0x800E4D74),
        shift(-HALF, IMM, 0x800E5E90, 0x800E78C8, 0x800E78D4, 0x800E7980, 0x800E79CC),
        scale(IMM, 0x800E5F68, 0x800E7BA4),
        scale(LUI, 0x800F3444),
    ], join([
        I(0x800E5870, 0x8010, hi(BOARD_ARRAYS)), // lui a1, 0x8010: the board arrays
        I(0x800E5874, 12840, lo(BOARD_ARRAYS + 0x0)), // addiu a1, a1, 12840
        I(0x800E587C, 50, 72), // li a2, 50
        I(0x800E5888, 0x8010, hi(BOARD_ARRAYS)), // lui a1, 0x8010: the board arrays
        I(0x800E588C, 18040, lo(BOARD_ARRAYS + 0x0)), // addiu a1, a1, 18040
        I(0x800E5894, 50, 72), // li a2, 50
        I(0x800E58A0, 0x8010, hi(BOARD_ARRAYS)), // lui a1, 0x8010: the board arrays
        I(0x800E58A4, 18264, lo(BOARD_ARRAYS + 0x0)), // addiu a1, a1, 18264
        I(0x800E58AC, 50, 72), // li a2, 50
        I(0x800E5A74, 0x8010, hi(BOARD_ARRAYS)), // lui s2, 0x8010: the board arrays
        I(0x800E5A78, 11592, lo(BOARD_ARRAYS + 0x360)), // addiu s2, s2, 11592
        I(0x800E5AA4, 50, 72), // slti v0, s0, 50
        I(0x800E5ADC, 0x8010, hi(BOARD_ARRAYS)), // lui s0, 0x8010: the board arrays
        I(0x800E5AE0, 11592, lo(BOARD_ARRAYS + 0x360)), // addiu s0, s0, 11592
        I(0x800E5B08, 50, 72), // slti v0, s1, 50
        I(0x800E5B14, 0x8010, hi(BOARD_ARRAYS)), // lui a0, 0x8010: the board arrays
        I(0x800E5B18, 12592, lo(BOARD_ARRAYS + 0x900)), // addiu a0, a0, 12592
        I(0x800E5B20, 144, 288), // li a1, 144
        I(0x800E5B3C, 0x8010, hi(BOARD_ARRAYS)), // lui v1, 0x8010: the board arrays
        I(0x800E5B40, 11592, lo(BOARD_ARRAYS + 0x360)), // addiu v1, v1, 11592
        I(0x800E5B6C, 50, 72), // slti v0, a0, 50
        I(0x800E5B94, 0x8010, hi(BOARD_ARRAYS)), // lui s0, 0x8010: the board arrays
        I(0x800E5B98, 11592, lo(BOARD_ARRAYS + 0x360)), // addiu s0, s0, 11592
        I(0x800E5BC4, 50, 72), // slti v0, s1, 50
        I(0x800E5D2C, 0x8010, hi(BOARD_ARRAYS)), // lui v1, 0x8010: the board arrays
        I(0x800E5D30, 11592, lo(BOARD_ARRAYS + 0x360)), // addiu v1, v1, 11592
        I(0x800E5D68, 50, 72), // slti v0, a1, 50
        I(0x800E5E74, 0x8010, hi(BOARD_ARRAYS)), // lui s6, 0x8010: the board arrays
        I(0x800E5E78, 12592, lo(BOARD_ARRAYS + 0x900)), // addiu s6, s6, 12592
        S(0x800E5F28, 3, 4), // sll v0, v0, 3: array entries of 48 bytes instead of 24
        S(0x800E5F54, 3, 4), // sll v1, v1, 3: array entries of 48 bytes instead of 24
        I(0x800E7B08, 0x8010, hi(BOARD_ARRAYS)), // lui s6, 0x8010: the board arrays
        I(0x800E7B0C, 12592, lo(BOARD_ARRAYS + 0x900)), // addiu s6, s6, 12592
        S(0x800E7B5C, 3, 4), // sll v0, v0, 3: array entries of 48 bytes instead of 24
        KF(0x800E8058, 0x800E805C, 159.5f, 159.5 + HALF), // lui at, 0x431f; ori at, at, 0x8000
        F(0x800F4184, 32, 49), // lui at, 0x4200
        I(0x800F41B0, 9, 8), // slti v0, s0, 9
        F(0x800F4244, 32, 49), // lui at, 0x4200
        I(0x800F4270, 9, 8), // slti v0, s0, 9
    ])),
    // Overlay 130 (board code)
    Patch(130, 0xDBB981AC, 0xA64DDDEA, [
        shift(HALF, IMM, 0x800E8F2C, 0x800E91F0, 0x800E9260, 0x800E928C, 0x800E9374, 0x800E937C),
        shift(HALF, SHORT, 0x800EB91E),
        shift(MORE, IMM, 0x800E6140),
        scale(LUI, 0x800E91DC),
    ]),
];

// Main code words that custom boards (made with PartyPlanner64) change, which its CRC leaves out: the heaps, the
// file system's ROM offset, ROM offsets of data after it, and the overlay table
immutable Address[2][] MAIN_UNCHECKED = [
    [0x8000C2C0, 0x8000C2C4], [0x8000E540, 0x8000E544], [0x8000E548, 0x8000E54C], [0x8000E668, 0x8000E670],
    [0x8000E674, 0x8000E67C], [0x8000E69C, 0x8000E6A4], [0x800354EC, 0x800354F0], [0x800354F4, 0x800354F8],
    [0x80035500, 0x80035504], [0x8003559C, 0x800355A0], [0x800355A4, 0x800355A8], [0x800489D4, 0x800489D8],
    [0x8004B2F0, 0x8004B2F8], [0x8004B2FC, 0x8004B304], [0x8005A7C8, 0x8005A7CC], [0x8005A7D0, 0x8005A7D4],
    [0x8005A810, 0x8005A814], [0x8005A818, 0x8005A820], [0x8005A824, 0x8005A82C], [0x8005A830, 0x8005A838],
    [0x8005A83C, 0x8005A848], [0x8007F058, 0x8007F05C], [0x8007F060, 0x8007F064], [0x800962F4, 0x80097560],
];

// Words in overlays that custom boards (made with PartyPlanner64) change without replacing the overlay, which overlays'
// CRCs leave out: a ROM offset of data after the file system (0x0128CC60, in a "lui" and "addiu"), a call in the game
// setup and a branch in the board code
immutable Address[2][] OVERLAY_UNCHECKED = [
    [0x800E89D4, 0x800E89D8], [0x800E89DC, 0x800E89E0], [0x800E9BB8, 0x800E9BBC], [0x800E9BC0, 0x800E9BC4],
    [0x800F89F4, 0x800F89F8], [0x800F89FC, 0x800F8A00], [0x800FC284, 0x800FC288], [0x800FC28C, 0x800FC290],
    [0x800FC5A4, 0x800FC5A8], [0x80105AC8, 0x80105ACC], [0x80105AD0, 0x80105AD4], [0x80105EFC, 0x80105F00],
    [0x80105F04, 0x80105F08], [0x80106FD0, 0x80106FD4], [0x80106FD8, 0x80106FDC], [0x8010728C, 0x80107290],
    [0x80107294, 0x80107298], [0x80107400, 0x80107404], [0x80107408, 0x8010740C], [0x80107574, 0x80107578],
    [0x8010757C, 0x80107580], [0x801080E8, 0x801080EC], [0x801080F0, 0x801080F4], [0x80108254, 0x80108258],
    [0x8010825C, 0x80108260], [0x801088E8, 0x801088EC], [0x801088F0, 0x801088F4], [0x80108D10, 0x80108D14],
    [0x80108D18, 0x80108D1C], [0x801091A8, 0x801091AC], [0x801091B0, 0x801091B4], [0x801092E4, 0x801092E8],
    [0x801092EC, 0x801092F0], [0x8010AB74, 0x8010AB78], [0x8010AB7C, 0x8010AB80], [0x8010BCC8, 0x8010BCCC],
    [0x8010BCD0, 0x8010BCD4], [0x8010D218, 0x8010D220], [0x8010FD58, 0x8010FD60], [0x80111800, 0x80111804],
    [0x80111820, 0x80111824],
];
