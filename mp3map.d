/*
 * Sharper zoomed-out maps for custom boards made with PartyPlanner64 (Mario Party 3, US): the map (Z on a turn) is the
 * board's background shrunk to 640x480 (from 1152x864 for most boards, averaging the area each pixel covers) instead
 * of PartyPlanner64's 320x240 copy, drawn in the same place: 2 texels for each of the 320x240 pixels. It's made from
 * the background the board uses this turn, so boards whose background changes (like Seasonal Woodland's seasons,
 * PartyPlanner64's "additional backgrounds") get a matching map. It looks sharper when the emulator renders above the
 * N64's resolution.
 *
 * The original boards' maps are drawn by hand (their routes and arrows over a darkened background), so they're kept.
 * A custom board is told apart by its background's tiles: PartyPlanner64 writes them compressed with the game's type
 * 3 (sliding window) compression, while the original boards' are HVQ.
 *
 * How the game draws a board: the board code (overlay 128) shows a background from the HVQ file system, a directory
 * of 64x48 tiles (an info file: tile width, height, columns, rows; an HVQ-MPS file; then the tiles, from the bottom
 * row up), keeping the ones on the screen in a cache and drawing each one with func_800E76EC(gfx, texture, x, y) (two
 * texture rectangles: rows 0 to 31 and 32 to 47). The board's setup, func_800F89D0(background, board definition, map),
 * names the background's directory and the map's. The zoomed-out map (func_800D7F5C) switches the background shown
 * to the map's directory, drawn the same way (its 5 x 5 tiles 1:1), and back when it's closed.
 */
module me.timz.n64.mp3map;

import me.timz.n64.game;
import std.algorithm;
import std.array;
import std.conv;
import std.exception : assumeUnique;

private enum TILE_W = 64, TILE_H = 48, TILE_BYTES = TILE_W * TILE_H * 2;
private enum MAP_W = 320, MAP_H = 240; // Where the game draws the map
private enum MAP_SCALE = 2;              // The map is made twice that size (640x480)

// Overlay 128 (the board code), recognized by its call to the HVQ decoder (jal func_800698E8) and its setup's start
private enum Address DECODE_CALL = 0x800E6E58, SETUP = 0x800F89D0;
private enum uint DECODE_CALL_WORD = 0x0C01A63A, SETUP_WORD = 0x27BDFFE0;
// The HVQ file system's ROM offset: a lui/addiu pair in overlay 128 (where PartyPlanner64 changes it too)
private enum Address HVQ_FS_HI = 0x800D6B70 + 0x1304A, HVQ_FS_LO = 0x800D6B70 + 0x13052;
// The draw call in the tile loop (func_800E76EC: a0 = the display list pointer's address, a2 = x; y << 16 is in a3,
// shifted in the delay slot), s0 = the tile's cache entry (its ROM offset at 16), and the instruction after the call
private enum Address DRAW_CALL = 0x800E8B80, AFTER_DRAW = 0x800E8B88;
// The zoomed-out map (func_800D7F5C): it shows the map's directory (MAP_DIR) instead of the board's background (the
// one shown, SHOWN_DIR), and the background again when it's closed
private enum Address MAP_VIEW = 0x800D7F5C, MAP_DIR = 0x80102700, SHOWN_DIR = 0x80105990;

private enum Address MALLOC = 0x80035934, FREE = 0x80035958; // HuMemMemoryAllocTemp, HuMemMemoryFreeTemp
private enum Address DMA = 0x8004DB14;                       // (ROM, address, size), returns once it's copied
private enum uint BUFFER = 0x10000;                          // The ROM is copied through a buffer this big

private struct Directory {
    uint rom;        // Its ROM offset
    uint[] files;    // Its files' ROM offsets (the info, the HVQ-MPS, the tiles), and its end
    uint columns, rows;
    uint tile(uint i) const { return files[2 + i]; }
    uint tileEnd(uint i) const { return files[3 + i]; }
}

// A shrunk background: its size in 64x48 tiles and in pixels (0 for a background that isn't a custom board's). Its
// tiles (RGBA5551, big-endian, from the top left, row by row) are in a MapCache.
private struct Map {
    uint columns, rows;
    uint width, height;
}

// The shrunk backgrounds' tiles, by background directory: what the ROM's background makes, the same every time (on
// every netplay machine too), so they aren't state, which only says which backgrounds were made (see
// CustomBoardMaps.maps)
final class MapCache {
    immutable(ubyte)[][uint] tiles;
}

// sharperCustomBoardMaps (see the module's description)
final class CustomBoardMaps(G) : Feature!G {
    bool ready;            // The map's directory is known (preparedMapDir)
    uint preparedMapDir;
    uint backgroundDir, mapDir;
    uint[2] mapTiles;      // The map's tiles' ROM range
    uint mapColumns, mapRows;
    uint[uint] mapTileIndices;
    // The backgrounds made, by directory (a Map.init for one that isn't a custom board's). Like the cache, they're
    // the session's: loading a save state keeps them.
    @Session Map[uint] maps;
    @Fixed MapCache cache;
    bool preparing;

    Address buffer;        // The map's tiles and display list in the N64's memory, while the map is shown (after a
                           // marker: a save state loaded since may not have it)
    uint bufferStamp;
    uint bufferDir;        // The background they're from
    int builtX = int.min, builtY = int.min; // The map's position the display list is for
    Address displayList;

    this() { cache = new MapCache; }

    override bool enabled() { return config.sharperCustomBoardMaps; }

    override void onStateLoaded() { preparing = false; }

    // The board's setup (overlay 128): note the background and map, and make the map if it's a custom board's
    @Exec(SETUP) void boardSetUp() {
        if (!overlay128()) return;
        auto background = cast(uint)gpr.a0, map = cast(uint)gpr.a2;
        if (background > 0xFF || map > 0xFF || preparing) return;
        backgroundDir = background;
        mapDir = map;
        prepare();
    }

    // Opening the map: the background it's for is the one shown (the setup's, or another a board's code chose since).
    // This also covers a save state loaded since the setup. A new background's map is made here (about 15 frames).
    @Exec(MAP_VIEW) void mapOpened() {
        if (!overlay128() || preparing) return;
        auto background = SHOWN_DIR.val!uint, map = MAP_DIR.val!uint;
        if (background > 0xFF || map > 0xFF) return;
        if (ready && preparedMapDir == map && background in maps) { backgroundDir = background; return; }
        backgroundDir = background;
        mapDir = map;
        prepare();
    }

    // Drawing the map's tiles: our map instead (once, at its top left tile), or the game's until ours is ready
    @Exec(DRAW_CALL) void tileDrawn() {
        if (!overlay128() || !ready) return;
        Address entry = gpr.s0;
        auto rom = (entry + 16).val!uint;
        bool mapTile = rom >= mapTiles[0] && rom < mapTiles[1];
        if (!mapTile) {
            if (buffer) release(); // Back to the board
            return;
        }
        auto map = backgroundDir in maps;
        if (!map || !map.columns || backgroundDir !in cache.tiles) return; // Not a custom board's: the game's map
        if (buffer && !bufferValid()) buffer = 0; // A save state was loaded: its memory doesn't have the buffer
        if (!buffer || bufferDir != backgroundDir) {
            allocate(backgroundDir);
            if (!buffer) return; // The game's tile
        }
        // Which map tile this is (the directory's tiles go from the bottom row up), and so where the map is
        auto index = mapTileIndices.get(rom, 0);
        auto column = index % mapColumns, row = mapRows - 1 - index / mapColumns;
        int x = cast(short)gpr.a2 - cast(int)(column * TILE_W), y = (cast(int)gpr.a3 >> 16) - cast(int)(row * TILE_H);
        if (column == 0 && row == 0) {
            if (x != builtX || y != builtY) buildDisplayList(*map, x, y);
            Address gfx = gpr.a0;
            Address p = gfx.val!uint;
            p.val!uint = 0xDE000000; (p + 4).val!uint = commands(*map); // gSPDisplayList
            gfx.val!uint = p + 8;
        }
        jump(AFTER_DRAW);
    }

    // For tests: makes the map from another background (as the board's setup does), from a safe point in the game's
    // code
    void useBackground(uint background, uint map) {
        if (!overlay128() || preparing) return;
        backgroundDir = background;
        mapDir = map;
        prepare();
    }

    // Reads the file system's table, the directories, and (for a custom board, the first time) the background's tiles,
    // through a buffer the ROM is copied to. Started at the setup's start: the calls run before it continues.
    void prepare() {
        preparing = true;
        auto fs = cast(uint)(HVQ_FS_HI.val!ushort << 16) + cast(short)HVQ_FS_LO.val!ushort;
        Address buf = callGame(MALLOC, BUFFER);
        if (buf) {
            readMaps(buf, fs);
            callGame(FREE, buf);
        }
        preparing = false;
    }

    // In prepare(): copies `size` bytes of the ROM from `rom` (rounded down to 2) to the buffer, and returns where they
    // are
    Address readRom(Address buf, uint rom, uint size) {
        auto aligned = rom & ~1u;
        callGame(DMA, aligned, buf, min(size + (rom - aligned), BUFFER));
        return buf + (rom - aligned);
    }

    // In prepare(): a directory of the file system (at `fs` in the ROM)
    Directory directory(Address buf, uint fs, uint index) {
        Address t = readRom(buf, fs, 4 + 4 * (index + 2));
        Directory dir;
        dir.rom = fs + (t + 4 + 4 * index).val!uint;
        Address d = readRom(buf, dir.rom, 0x800);
        auto count = min(d.val!uint, 0x1F0);
        foreach (i; 0..count) dir.files ~= dir.rom + (d + 4 + 4 * i).val!uint;
        Address info = readRom(buf, dir.files[0], 16);
        dir.columns = (info + 8).val!uint;
        dir.rows = (info + 12).val!uint;
        return dir;
    }

    // In prepare(): the map's directory, then the background's map if it isn't made yet. The pixels are kept until all
    // the tiles are read: they're the ROM's, so if a rollback runs this again, it writes them the same way again.
    void readMaps(Address buf, uint fs) {
        auto map = directory(buf, fs, mapDir);
        mapColumns = map.columns;
        mapRows = map.rows;
        mapTileIndices = null;
        foreach (i; 0..map.columns * map.rows) mapTileIndices[map.tile(i)] = i;
        mapTiles = [map.tile(0), map.tileEnd(map.columns * map.rows - 1)];
        preparedMapDir = mapDir;
        ready = true;
        if (backgroundDir in maps) return;

        auto background = directory(buf, fs, backgroundDir);
        if (readRom(buf, background.tile(0), 4).val!uint != 3) { // HVQ: an original board
            maps[backgroundDir] = Map.init;
            return;
        }
        auto count = background.columns * background.rows;
        auto pixels = new ushort[count * TILE_W * TILE_H];
        // The tiles, read a chunk (as many as fit in the buffer) at a time
        for (uint i = 0; i < count; ) {
            auto start = background.tile(i) & ~1u;
            auto last = i;
            while (last + 1 < count && background.tileEnd(last + 1) - start <= BUFFER) last++;
            auto end = min(background.tileEnd(last), start + BUFFER);
            Address data = readRom(buf, start, end - start);
            auto chunk = new ubyte[end - start];
            foreach (j, ref v; chunk) v = (data + cast(uint)j).val!ubyte;
            foreach (t; i..last + 1) {
                auto decoded = decompress(chunk[background.tile(t) - start..min(background.tileEnd(t), end) - start]);
                // Tile t: column t % columns, row (from the top) rows - 1 - t / columns
                auto column = t % background.columns, row = background.rows - 1 - t / background.columns;
                auto width = background.columns * TILE_W;
                foreach (y; 0..TILE_H) foreach (x; 0..TILE_W) {
                    auto o = (y * TILE_W + x) * 2;
                    pixels[(row * TILE_H + y) * width + column * TILE_W + x] =
                        o + 1 < decoded.length ? cast(ushort)(decoded[o] << 8 | decoded[o + 1]) : 1;
                }
            }
            i = last + 1;
        }
        ubyte[] tiles;
        auto shrunk = shrink(pixels, background.columns, background.rows, tiles);
        cache.tiles[backgroundDir] = assumeUnique(tiles);
        maps[backgroundDir] = shrunk;
        info("Made the zoomed-out map of background ", backgroundDir, " (", shrunk.width, "x", shrunk.height, ")");
    }

    // Puts the map's tiles in the N64's memory (and room for the display list after them)
    void allocate(uint dir) {
        auto map = maps[dir];
        auto tiles = cache.tiles[dir];
        Address b = callGame(MALLOC, cast(uint)(MARKER + tiles.length + displayListSize(map)));
        if (!b) return;
        bufferStamp++;
        b.val!uint = MAGIC;
        (b + 4).val!uint = bufferStamp;
        buffer = b + MARKER;
        bufferDir = dir;
        displayList = buffer + cast(uint)tiles.length;
        foreach (i, v; tiles) (buffer + cast(uint)i).val!ubyte = v;
        builtX = builtY = int.min;
    }

    bool bufferValid() {
        Address start = buffer - MARKER;
        return start.val!uint == MAGIC && (start + 4).val!uint == bufferStamp;
    }

    void release() {
        auto valid = bufferValid();
        Address start = buffer - MARKER;
        buffer = 0;
        if (!valid) return;
        start.val!uint = 0;
        callGame(FREE, start);
    }

    // Where the display list's commands start
    Address commands(const Map map) { return displayList + VERTICES + map.columns * map.rows * 8 * 16; }

    // The display list drawing the map's tiles over the 320x240 the game's map covers, at (x, y), as textured
    // triangles: unlike texture rectangles, which some emulators draw at the N64's resolution (like Parallel's "native
    // resolution TEX_RECT"), they're drawn at the emulator's. Positions are in 1/4 pixels (VTX), mapped to the screen
    // by an orthographic projection and a viewport covering 0 to 1024 pixels (wider than any screen, which clips them).
    // Each tile's two parts (rows 0 to 31 and 32 to 47, as the game loads them: a tile doesn't fit in the texture
    // memory) are loaded and drawn in turn, filtered bilinearly and clamped at their edges. The game sets its own
    // viewport, projection and modes after the background, so only the background pass's texture modes are restored at
    // the end.
    void buildDisplayList(const Map map, int x, int y) {
        builtX = x;
        builtY = y;
        Address data = displayList;                      // The viewport, matrices and vertices, then the commands
        Address p = commands(map);
        void command(uint w0, uint w1) { p.val!uint = w0; (p + 4).val!uint = w1; p += 8; }
        void half(Address a, int v) { a.val!ubyte = cast(ubyte)(v >> 8); (a + 1).val!ubyte = cast(ubyte)v; }
        uint physical(Address a) { return a & 0x1FFFFFFF; }

        // The viewport: scale and translation (x, y, z, 0) in 1/4 pixels, 512 pixels: x and y from 0 to 1024
        foreach (i, v; [2048, 2048, 511, 0, 2048, 2048, 511, 0]) half(data + VIEWPORT + cast(uint)i * 2, v);
        // A 4x4 matrix in 16.16 fixed point (integer parts, then fractions), row by row, for row vectors
        void matrix(Address m, const int[16] values) { // In 1/65536
            foreach (i, v; values) {
                half(m + cast(uint)i * 2, v >> 16);
                half(m + 32 + cast(uint)i * 2, v & 0xFFFF);
            }
        }
        // x (1/4 pixels) to x / 2048 - 1, y to 1 - y / 2048: the viewport makes those x / 4 and y / 4 pixels
        matrix(data + PROJECTION, [32, 0, 0, 0,  0, -32, 0, 0,  0, 0, 65536, 0,  -65536, 65536, 0, 65536]);
        matrix(data + MODELVIEW, [65536, 0, 0, 0,  0, 65536, 0, 0,  0, 0, 65536, 0,  0, 0, 0, 65536]);

        command(0xE7000000, 0);                                       // gDPPipeSync
        command(0xDC080008, physical(data + VIEWPORT));               // gSPViewport
        command(0xDA380007, physical(data + PROJECTION));             // gSPMatrix (projection, load)
        command(0xDA380003, physical(data + MODELVIEW));              // gSPMatrix (modelview, load)
        command(0xD9000000, 0);                                       // gSPLoadGeometryMode(0): no z-buffer, culling, lighting
        command(0xD7000002, 0xFFFFFFFF);                              // gSPTexture (on, scale 1)
        command(0xE3000A01, 0);                                       // gDPSetCycleType(G_CYC_1CYCLE)
        command(0xE3001201, 0x2000);                                  // gDPSetTextureFilter(G_TF_BILERP)
        command(0xE3000C00, 0x80000);                                 // gDPSetTexturePersp(G_TP_PERSP): the RSP's
                                                                      // texture coordinates are always perspective's
        command(0xFCFFFFFF, 0xFFFCF279);                              // gDPSetCombineMode(G_CC_DECALRGBA)
        command(0xE200001C, 0x00552248);                              // The background's render mode
        command(0xE7000000, 0);                                       // gDPPipeSync

        auto scaleX = cast(double)MAP_W / map.width, scaleY = cast(double)MAP_H / map.height;
        Address vertex = data + VERTICES;
        foreach (row; 0..map.rows) foreach (column; 0..map.columns) {
            Address texture = buffer + (row * map.columns + column) * TILE_BYTES;
            Address first = vertex;
            // Its 8 vertices: the corners of its two parts, with their texture coordinates (10.5 fixed point, half a
            // texel in, for the bilinear filter's texel centers)
            foreach (part; 0..2) {
                auto top = part * 32, height = part ? 16 : 32;
                auto x0 = cast(int)((x + column * TILE_W * scaleX) * 4 + 0.5);
                auto x1 = cast(int)((x + (column + 1) * TILE_W * scaleX) * 4 + 0.5);
                auto y0 = cast(int)((y + (row * TILE_H + top) * scaleY) * 4 + 0.5);
                auto y1 = cast(int)((y + (row * TILE_H + top + height) * scaleY) * 4 + 0.5);
                foreach (corner; 0..4) {
                    bool right = corner == 1 || corner == 2, bottom = corner >= 2;
                    half(vertex, right ? x1 : x0);
                    half(vertex + 2, bottom ? y1 : y0);
                    half(vertex + 4, 0);
                    half(vertex + 6, 0);
                    half(vertex + 8, (right ? TILE_W : 0) * 32 - 16);
                    half(vertex + 10, (bottom ? height : 0) * 32 - 16);
                    (vertex + 12).val!uint = 0xFFFFFFFF;
                    vertex += 16;
                }
            }
            command(0x01008010, physical(first));                     // gSPVertex(first, 8, 0)
            foreach (part; 0..2) {
                auto top = part * 32, height = part ? 16 : 32;
                auto clamp = 0x00080200;                              // Clamped (no mirroring or masks) in s and t
                command(0xFD100000, physical(texture + top * TILE_W * 2));                 // gDPSetTextureImage (RGBA16)
                command(0xF5100000, 0x07000000 | clamp);                                  // gDPSetTile (load)
                command(0xE6000000, 0);                                                   // gDPLoadSync
                command(0xF3000000, 0x07000000 | (TILE_W * height - 1) << 12 | 0x080);   // gDPLoadBlock
                command(0xE7000000, 0);                                                   // gDPPipeSync
                command(0xF5102000, clamp);                                               // gDPSetTile (render)
                command(0xF2000000, 63 << 14 | (height - 1) << 2);                        // gDPSetTileSize (0..63, 0..h-1)
                auto v = part * 4 * 2;                                                    // Vertex indices (times 2)
                command(0x06000000 | v << 16 | (v + 2) << 8 | (v + 4), (v << 16) | (v + 4) << 8 | (v + 6)); // gSP2Triangles
            }
        }

        // The background pass's modes again (for the game's tiles drawn after this)
        command(0xE7000000, 0);                                       // gDPPipeSync
        command(0xE3001201, 0x3000);                                  // Its texture filter
        command(0xE3000C00, 0);                                       // Its texture perspective (off)
        command(0xD9FFFFFF, 0x00220401);                              // Its geometry mode
        command(0xE7000000, 0);                                       // gDPPipeSync
        command(0xDF000000, 0);                                       // gSPEndDisplayList
    }
}

private bool overlay128() { return DECODE_CALL.val!uint == DECODE_CALL_WORD && SETUP.val!uint == SETUP_WORD; }

// A type 3 file (u32 3, u32 size, then the data compressed with the sliding window method)
private ubyte[] decompress(const ubyte[] file) {
    if (file.length < 8) return null;
    auto size = file[4] << 24 | file[5] << 16 | file[6] << 8 | file[7];
    auto output = new ubyte[](0);
    output.reserve(size);
    size_t s = 8;
    uint command, bits;
    while (output.length < size && s < file.length) {
        if (bits == 0) {
            if (s + 4 > file.length) break;
            command = file[s] << 24 | file[s + 1] << 16 | file[s + 2] << 8 | file[s + 3];
            s += 4;
            bits = 32;
        }
        if (command & 0x80000000) {
            output ~= file[s++];
        } else {
            if (s + 2 > file.length) break;
            auto b1 = file[s], b2 = file[s + 1];
            s += 2;
            auto offset = ((b1 & 0xF) << 8 | b2) + 1;
            uint count = b1 >> 4;
            if (count == 0) {
                if (s >= file.length) break;
                count = file[s++] + 0x12;
            } else {
                count += 2;
            }
            foreach (i; 0..count) output ~= offset <= output.length ? output[$ - offset] : 0;
        }
        command <<= 1;
        bits--;
    }
    output.length = size;
    return output;
}

// The background (columns x rows tiles of RGBA5551 pixels, row by row) resized to MAP_SCALE times the map's size
// (smaller only: one that's already smaller keeps its size), as 64x48 tiles. Each new pixel is the average of the
// background's area it covers, with the pixels at its edges weighted by how much of them it covers.
private Map shrink(const ushort[] pixels, uint columns, uint rows, out ubyte[] tiles) {
    auto width = columns * TILE_W, height = rows * TILE_H;
    Map map;
    map.width = min(width, MAP_W * MAP_SCALE);
    map.height = min(height, MAP_H * MAP_SCALE);
    map.columns = (map.width + TILE_W - 1) / TILE_W;
    map.rows = (map.height + TILE_H - 1) / TILE_H;
    tiles = new ubyte[map.columns * map.rows * TILE_BYTES];

    // For each new column (or row): the source pixels it covers and how much of each (in 1/newSize of a pixel)
    static struct Span { uint first; uint[] weights; }
    static Span[] spans(uint size, uint newSize) {
        auto result = new Span[newSize];
        foreach (i; 0..newSize) {
            auto start = i * size, end = (i + 1) * size; // In 1/newSize of a source pixel
            result[i].first = start / newSize;
            for (auto p = start / newSize; p * newSize < end; p++) {
                result[i].weights ~= min(end, (p + 1) * newSize) - max(start, p * newSize);
            }
        }
        return result;
    }
    auto xs = spans(width, map.width), ys = spans(height, map.height);
    auto total = cast(ulong)width * height; // Every new pixel's weights add up to this

    foreach (y; 0..map.height) foreach (x; 0..map.width) {
        ulong r, g, b;
        foreach (j, wy; ys[y].weights) foreach (i, wx; xs[x].weights) {
            auto c = pixels[(ys[y].first + j) * width + xs[x].first + i];
            auto w = cast(ulong)wx * wy;
            r += (c >> 11 & 31) * w; g += (c >> 6 & 31) * w; b += (c >> 1 & 31) * w;
        }
        auto c = cast(ushort)((r + total / 2) / total << 11 | (g + total / 2) / total << 6 | (b + total / 2) / total << 1 | 1);
        auto o = ((y / TILE_H * map.columns + x / TILE_W) * TILE_H + y % TILE_H) * TILE_W * 2 + x % TILE_W * 2;
        tiles[o] = cast(ubyte)(c >> 8);
        tiles[o + 1] = cast(ubyte)c;
    }
    return map;
}

private enum uint MAGIC = 0x4D50334D; // "MP3M"
private enum uint MARKER = 16;         // Before the tiles (keeping them 16-byte aligned)

// After the tiles: the viewport, the projection and modelview matrices, the vertices (8 for each tile), and the
// display list (its commands: the setup, 17 for each tile, the restoring and the end)
private enum uint VIEWPORT = 0, PROJECTION = 16, MODELVIEW = 80, VERTICES = 144;
private enum uint SETUP_COMMANDS = 12, TILE_COMMANDS = 17, END_COMMANDS = 6;

private size_t displayListSize(const Map map) {
    return VERTICES + map.columns * map.rows * 8 * 16 + (SETUP_COMMANDS + map.columns * map.rows * TILE_COMMANDS + END_COMMANDS) * 8;
}

mixin NoMutableGlobals;
