module me.timz.n64.mariogolf;

import me.timz.n64.game;
import std.algorithm;
import std.math;
import std.stdio;
import std.random;
import std.range;
import std.string;

enum ClubType : uint {
    PUTTER = 0xD
}

union Score {
    ubyte[0x02] _data;
    mixin Field!(0x00, ubyte, "strokes");
    mixin Field!(0x01, ubyte, "putts");
}

union Player {
    ubyte[0xB8] _data;
    mixin Field!(0x02, ubyte, "cpu");
    mixin Field!(0x0B, ubyte, "controller");
    mixin Field!(0x10, Arr!(Score, 18), "scores");
    mixin Field!(0x31, ubyte, "mulligansUsed");
    mixin Field!(0x36, Arr!(ushort, 14), "clubs");
}

union Club {
    ubyte[0x34] _data;
    mixin Field!(0x00, ushort, "distance");
    mixin Field!(0x08, ushort, "meetArea");
    mixin Field!(0x0C, uint, "powerSpeed");
    mixin Field!(0x10, uint, "normalSpeed");
}

union Memory {
    ubyte[0x800000] ram;
    mixin Field!(0x800BB264, Arr!(Club, 192), "clubs");
    mixin Field!(0x801B71EC, Arr!(Player, 4), "players");
    mixin Field!(0x800B67F0, uint, "time");
    mixin Field!(0x800FBE77, ubyte, "currentPlayerId");
    mixin Field!(0x800FBE88, uint, "powerCursor");
    mixin Field!(0x80224B24, uint, "shotPower");
    mixin Field!(0x801B608C, int, "mode");
    mixin Field!(0x80224928, uint, "mulliganMenuLength");
    mixin Field!(0x80224A9C, uint, "mulliganMenuSelection");
    mixin Field!(0x801B60AC, int, "holeSet");
    mixin Field!(0x800BA9F8, uint, "isRaining");
    mixin Field!(0x800FBE58, ClubType, "currentClubType");
    mixin Field!(0x800FBE70, uint, "terrainType");
}

class Config {
    bool expandMeetArea = false;
    bool improveMaple = false;
    bool imperfectCPUMeetArea = false;
    bool autoSwing = false;
}

class MarioGolf64 : Game!Config {
    @Fixed Memory* data;

    this(string name, string hash) {
        // (the heap: malloc, free, InitHeap, and the function that reads the controllers each frame, in the game's thread)
        super(name, hash, Heap(0x8004E2DC, 0x8004E47C, 0x8004E1E0, 0x8002A310, true));
        data = cast(Memory*)memory.ptr;

        feature(new Percentages);
        feature(new ExpandMeetArea);
        feature(new ImproveMaple);
        feature(new AutoSwing);
        feature(new ImperfectCPUMeetArea);
    }

    ref Player currentPlayer() {
        return data.players[data.currentPlayerId];
    }
}

// The shot's percentages: the meet area's and the power's, as the game would use them
final class Percentages : Feature!MarioGolf64 {
    Address format;   // The percentage's format string, while it's replaced
    char[] oldFormat; // ... and what it was

    @Exec(0x8008B908) void adjustPercentage() {
        gpr.a2 = cast(uint)round(data.currentClubType == ClubType.PUTTER
            ? (data.isRaining ? 0.80 : 1) * 100
            : (data.isRaining ? 0.95 : 1) * (0.25 * gpr.a2 + 0.75 * gpr.a3));

        format = gpr.a1;
        oldFormat = null;
        for (auto c = Ptr!char(format); *c; c++) oldFormat ~= *c;
        oldFormat ~= '\0';
        "%3d%%\0".each!((i, c) { Ptr!char(format)[i] = c; });
        hookExecOnce!restoreFormat(0x8008B910);
    }

    void restoreFormat() {
        oldFormat.each!((i, c) { Ptr!char(format)[i] = c; });
    }

    @Exec(0x8008B934) void moveText() { gpr.a1 += 15; } // A bit to the right

    // The actual shot power
    @Exec(0x8008B9BC, 0x8008B9E4) void shotPower() {
        if (data.shotPower) gpr.v0 = gpr.v0 * data.shotPower / 30;
    }
}

final class ExpandMeetArea : Feature!MarioGolf64 {
    override bool enabled() { return config.expandMeetArea; }

    override void setUp() {
        foreach (ref club; data.clubs) hookRead!expand(club.meetArea);
    }

    void expand(ref ushort meetArea) { meetArea = meetArea / 2 + 59; }
}

// The maple clubs (28 to 41) go further and faster
final class ImproveMaple : Feature!MarioGolf64 {
    override bool enabled() { return config.improveMaple; }

    override void setUp() {
        foreach (i; 28..42) {
            hookRead!longer(data.clubs[i].distance);
            hookRead!faster(data.clubs[i].powerSpeed);
            hookRead!faster(data.clubs[i].normalSpeed);
        }
    }

    void longer(ref ushort distance) { distance = cast(ushort)(distance * 1.08); }
    void faster(ref uint speed) { speed = cast(uint)(speed * 1.125); }
}

final class AutoSwing : Feature!MarioGolf64 {
    override bool enabled() { return config.autoSwing; }

    @Exec(0x8020AB78) void swing() {
        if (data.powerCursor == 69) {
            int offset = cast(int)round(random.normal * 0.75); // 0 ~ 50%, ≤1 ~ 95%, ≤2 ~ 99.9%, ≤3 ~ 100.0%
            data.powerCursor = clamp(60 + offset, 0, 69);      // 0 ~ 50%, ±1 ~ 45%, ±2 ~  4.9%, ±3 ~   0.1%
        }
    }
}

final class ImperfectCPUMeetArea : Feature!MarioGolf64 {
    override bool enabled() { return config.imperfectCPUMeetArea; }

    @Exec(0x8020AB78) void cpuSwing() {
        if (data.currentPlayerId >= 4 || !currentPlayer.cpu) return;
        int offset = cast(int)round(random.normal * 0.5);
        data.powerCursor = clamp(60 + offset, 0, 69);
    }
}

extern (C) {
    string getName() {
        return "Mario Golf";
    }

    int startup() {
        usePlugin!MarioGolf64();
        return 0;
    }
}

mixin NoMutableGlobals;
