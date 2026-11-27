module me.timz.n64.marioparty;

import me.timz.n64.game;
import std.algorithm;
import std.random;
import std.range;
import std.json;
import std.traits;
import std.typecons;
import std.stdio;
import std.conv;
import std.uni;
import std.utf;
import std.math;
import std.format : format;

ulong[] apportion(ulong total, const(double)[] dist) pure {
    if (dist.any!(e => e < 0.0)) throw new Exception("dist.any!(e => e < 0.0)");
    if (fixRoundingError(dist.sum) > 1.0) throw new Exception("dist.sum > 1.0");

    dist = (dist ~ [1.0 - fixRoundingError(dist.sum)]);
    auto unrounded = dist.map!(e => fixRoundingError(total * e)).array;
    auto unique = dist.dup.sort().uniq().array;
    ulong[] result;
    auto remaining = ulong.max;
    auto error = double.infinity;
    iota(1UL << unique.length).each!((combo) {
        auto rounded = unrounded.enumerate.map!((e) {
            bool c = (combo >> unique.countUntil(dist[e.index])) & 0b1;
            return cast(ulong)(c ? ceil(e.value) : floor(e.value));
        }).array;
        if (rounded.sum > total) return;

        auto r = total - rounded.sum;
        auto e = rounded.enumerate.map!(e => abs(e.value - unrounded[e.index])).sum;
        
        if (r < remaining || (r == remaining && e < error)) {
            result = rounded[0..$-1];
            remaining = r;
            error = e;
        }
    });

    return result;
}

enum PanelColor : ubyte {
    NONE  = 0,
    BLUE  = 1,
    RED   = 2,
    GREEN = 4
}

enum Character : byte {
    UNDEFINED = -1,
    MARIO     =  0,
    LUIGI     =  1,
    PEACH     =  2,
    YOSHI     =  3,
    WARIO     =  4,
    DK        =  5,
    WALUIGI   =  6,
    DAISY     =  7
}

string fullName(Character character) pure {
    final switch (character) {
        case Character.UNDEFINED: return "UNDEFINED_CHARACTER";
        case Character.MARIO:     return "Mario";
        case Character.LUIGI:     return "Luigi";
        case Character.PEACH:     return "Peach";
        case Character.YOSHI:     return "Yoshi";
        case Character.WARIO:     return "Wario";
        case Character.DK:        return "DK";
        case Character.WALUIGI:   return "Waluigi";
        case Character.DAISY:     return "Daisy";
    }
}

bool isCPU(ubyte flags) pure {
    return flags & 0b00000001;
}

immutable Tuple!(char, "id", string, "text")[] FORMATTING = [
    tuple('\x00', "<NUL>"),
    // Text colors (palette at 0x800A2174). Text has a 1-pixel drop shadow, except in black.
    tuple('\x01', "<BLACK>"),
    tuple('\x02', "<BLUE>"),          // 0, 0, 255
    tuple('\x03', "<RED>"),           // 255, 66, 66
    tuple('\x04', "<MAGENTA>"),       // 255, 0, 255
    tuple('\x05', "<GREEN>"),         // 0, 255, 0
    tuple('\x06', "<CYAN>"),          // 0, 255, 255
    tuple('\x07', "<YELLOW>"),        // 255, 255, 0
    tuple('\x08', "<WHITE>"),
    tuple('\x0B', "<CLEAR>"),         // Clears the window and starts again at the top left
    tuple('\x0C', "<CHOICE>"),        // Start of a selectable choice
    tuple('\x0D', "<CHOICE_END>"),    // End of a selectable choice
    tuple('\x0E', "<TAB>"),           // Moves to the next tab stop
    tuple('\x0F', "<OUTLINE>"),       // Outlines the text (in black by default)
    tuple('\x10', "<SPACE>"),         // Same as a space (4 pixels)
    tuple('\x11', "<1>"),
    tuple('\x12', "<2>"),
    tuple('\x13', "<3>"),
    tuple('\x14', "<4>"),
    tuple('\x15', "<5>"),
    tuple('\x16', "<NO_OUTLINE>"),
    tuple('\x17', "<SHORT_NEWLINE>"), // New line, moving down only a quarter of a line
    tuple('\x18', "<SKIP_NEXT>"),     // Skips the next byte (no other effect)
    tuple('\x19', "<RESET>"),         // Default text color
    tuple('\x1A', "<WIDE_SPACE>"),    // 10-pixel space
    // Icons: frames of mainfs file 0x34. 0x2D-0x2F are past the end of the icon table; don't use them.
    tuple('\x21', "<A>"),
    tuple('\x22', "<B>"),
    tuple('\x23', "<C_UP>"),
    tuple('\x24', "<C_RIGHT>"),
    tuple('\x25', "<C_LEFT>"),
    tuple('\x26', "<C_DOWN>"),
    tuple('\x27', "<Z>"),
    tuple('\x28', "<STICK>"),
    tuple('\x29', "<COIN>"),
    tuple('\x2A', "<STAR>"),
    tuple('\x2B', "<START>"),
    tuple('\x2C', "<R>"),
    // Glyphs: mainfs file 0x2C (10x12, 4-bit) from code 0x30 on; advance widths at 0x800A2194
    tuple('\x3A', "<COIN_OUTLINE>"),
    tuple('\x3B', "<STAR_OUTLINE>"),
    tuple('\x3C', "+"),
    tuple('\x3D', "-"),
    tuple('\x3E', "×"),
    tuple('\x3F', "→"),
    tuple('\x5B', "\""),
    tuple('\x5C', "'"),
    tuple('\x5D', "("),
    tuple('\x5E', ")"),
    tuple('\x5F', "/"),
    tuple('\x7B', ":"),
    tuple('\x7C', "%"),
    tuple('\x7D', "·"),
    tuple('\x7E', "&"),
    tuple('\x80', "゛"),              // Japanese leftovers; 0x80/0x81 are drawn over the previous character
    tuple('\x81', "゜"),
    tuple('\x82', ","),
    tuple('\x83', "。"),
    tuple('\x84', "—"),
    tuple('\x85', "."),
    tuple('\x86', "_"),
    tuple('\x91', "Ä"),
    tuple('\x92', "Ö"),
    tuple('\x93', "Ü"),
    tuple('\x94', "ß"),
    tuple('\x95', "À"),
    tuple('\x96', "Á"),
    tuple('\x97', "È"),
    tuple('\x98', "É"),
    tuple('\x99', "Ì"),
    tuple('\x9A', "Í"),
    tuple('\x9B', "Ò"),
    tuple('\x9C', "Ó"),
    tuple('\x9D', "Ù"),
    tuple('\x9E', "Ú"),
    tuple('\x9F', "Ñ"),
    tuple('\xA0', "<BIG_0>"),
    tuple('\xA1', "<BIG_1>"),
    tuple('\xA2', "<BIG_2>"),
    tuple('\xA3', "<BIG_3>"),
    tuple('\xA4', "<BIG_4>"),
    tuple('\xA5', "<BIG_5>"),
    tuple('\xA6', "<BIG_6>"),
    tuple('\xA7', "<BIG_7>"),
    tuple('\xA8', "<BIG_8>"),
    tuple('\xA9', "<BIG_9>"),
    tuple('\xC0', "“"),
    tuple('\xC1', "”"),
    tuple('\xC2', "!"),
    tuple('\xC3', "?"),
    tuple('\xC4', "⁉"),
    tuple('\xC5', "‼"),
    tuple('\xC6', "¿"),
    tuple('\xC7', "¡"),
    tuple('\xD1', "à"),
    tuple('\xD2', "â"),
    tuple('\xD3', "ä"),
    tuple('\xD4', "ç"),
    tuple('\xD5', "è"),
    tuple('\xD6', "é"),
    tuple('\xD7', "ê"),
    tuple('\xD8', "ë"),
    tuple('\xD9', "î"),
    tuple('\xDA', "ï"),
    tuple('\xDB', "ô"),
    tuple('\xDC', "ö"),
    tuple('\xDD', "ù"),
    tuple('\xDE', "û"),
    tuple('\xDF', "ü"),
    tuple('\xE0', "á"),
    tuple('\xE1', "ì"),
    tuple('\xE2', "í"),
    tuple('\xE3', "ò"),
    tuple('\xE4', "ó"),
    tuple('\xE5', "ú"),
    tuple('\xE6', "ñ"),
    tuple('\xFE', "…"),
    tuple('\xFF', "<END>")            // Waits for A, showing the ▼ glyph
];

// Game text (bytes) for text in the plugin's markup: FORMATTING's tags and characters become their codes, and other
// ASCII is kept as it is (letters, digits, space, and control bytes like "\n"). Other characters have no glyph, so
// they become "?".
string formatText(string text) pure {
    char[] result;

    while (!text.empty) {
        ptrdiff_t m = -1;
        FORMATTING.each!((i, ref f) {
            if (!text.startsWith(f.text)) return;
            if (m == -1 || f.text.length > FORMATTING[m].text.length) {
                m = i;
            }
        });
        if (m == -1) {
            auto c = text.decodeFront;
            result ~= c < 0x80 ? cast(char)c : '\xC3'; // "?"
        } else {
            result ~= FORMATTING[m].id;
            text = text[FORMATTING[m].text.length..$];
        }
    }

    return result;
}

// The plugin's markup for game text (bytes): the reverse of formatText(). Bytes with no meaning in FORMATTING are kept
// if they're ASCII, and become "?" otherwise (so the result is valid UTF-8).
string unformatText(string text) pure {
    static immutable string[256] MARKUP = () {
        string[256] markup;
        foreach (f; FORMATTING) markup[cast(ubyte)f.id] = f.text;
        return markup;
    }();
    string result;

    foreach (b; cast(immutable(ubyte)[])text) { // Bytes: game text isn't UTF-8
        if (MARKUP[b] !is null) result ~= MARKUP[b];
        else result ~= b < 0x80 ? cast(char)b : '?';
    }

    return result;
}

// Markup showing a player's name as closely as the game's font can: without tags (so "<1>" is just text), and with
// characters the font has no glyph for replaced by similar ones, or by "?". The result goes through formatText().
string gameName(string name) {
    string result;
    foreach (dchar c; name) {
        // The font's own characters: ASCII letters, digits and space, and FORMATTING's characters
        // (but not the Japanese marks, which are drawn over the previous character)
        auto glyph = FORMATTING.find!(f => f.id >= '\x30' && f.id != '\x80' && f.id != '\x81' && !f.text.startsWith("<") &&
                                           f.text == c.to!string);
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == ' ' || !glyph.empty) {
            result ~= c;
            continue;
        }
        switch (c) {
            case '~', '=', '–':                result ~= '-'; break;
            case '<', '[', '{':                result ~= '('; break;
            case '>', ']', '}':                result ~= ')'; break;
            case '\\', '|':                    result ~= '/'; break;
            case ';':                          result ~= ':'; break;
            case '*':                          result ~= '×'; break;
            case '`', '‘', '’', '´':           result ~= '\''; break;
            case '\t', '\n', '\r', ' ':   result ~= ' '; break;
            default:
                // A letter with a mark the font doesn't have (like "Å" or "ł"): the letter by itself
                auto base = normalize!NFD(c.to!string);
                auto b = base.empty ? dchar.init : base.front;
                result ~= ((b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z')) ? b : '?';
        }
    }
    return result;
}

struct BingoCard {
    string name;
    string formattedName;
    int bingos;
    int squares;
    Character[] characters;
}

// A bingo admin's correction to a player (the Bingo page's player panels). Names are the games' enum names.
struct PlayerOverride {
    int player;      // 1-4
    string chr;
    int stars;
    int coins;
    string[] items;  // Without NONE, in slot order
}

// Settings every game has. Each game's Config adds its own.
class MarioPartyConfig {
    Character[] characters = [Character.UNDEFINED, Character.UNDEFINED, Character.UNDEFINED, Character.UNDEFINED];
    // A save state at the start of each player's turn, in slots 1 to 4. Not during netplay: the emulator doesn't make
    // save states then, and the slot shouldn't change either.
    bool saveStateBeforeEachPlayerTurn = false;
    string bingoURL = "";
    bool rankPlayersByBingoScore = false;
}

struct NoPlayerState { }

// A player: their data in the game's memory, their panel on the board, and the plugin's own state for them (a struct of
// the game's)
final class MarioPartyPlayer(PlayerData, PlayerPanel, PlayerState) {
    const uint index;
    @Fixed PlayerData* data;
    @Fixed PlayerPanel* panel;
    PanelColor cachedColor; // The panel color last sent to the Bingo page
    PlayerState state;

    this(uint index, ref PlayerData data, ref PlayerPanel panel) {
        this.index = index;
        this.data = &data;
        this.panel = &panel;
    }

    @property bool isCPU() const {
        return data.flags.isCPU;
    }

    bool isAheadOf(const MarioPartyPlayer o) const {
        return data.stars == o.data.stars ? data.coins > o.data.coins : data.stars > o.data.stars;
    }
}

// The temporary heap's functions, in the games that use it
struct TempHeap { Address alloc, free; }

// The code every game shares. Code for things only some games have is in function templates (with "()" before their
// parameters), which only get compiled for the games that call them, or under "static if" when it declares members.
abstract class MarioParty(Config : MarioPartyConfig, Memory, PlayerState = NoPlayerState) : Game!Config {
    alias Scene = typeof(Memory.currentScene);
    alias Player = MarioPartyPlayer!(typeof(Memory.players.front), typeof(Memory.playerPanels.front), PlayerState);
    alias Stars = typeof(Memory.players.front.stars);
    alias PlayerIndex = typeof(Memory.currentPlayerIndex);

    @Fixed Memory* data;
    @Fixed Player[] players;
    const int[Character.max + 1] teams; // By character (see Config.teams)
    immutable TempHeap tempHeap;
    float currentPlayerTurn = 0;        // The turn and player the plugin last saw (see onFrame())

    // The bingo cards, as the bingo site last sent them, and each character's name on them. They belong to the live
    // bingo session, so loading a save state keeps them. The site sends them whenever the plugin connects.
    @Session BingoCard[] bingoCards;
    @Session string[Character] characterToName;

    this(string name, string hash, Heap heap, TempHeap tempHeap = TempHeap.init) {
        super(name, hash, heap);
        this.tempHeap = tempHeap;
        data = cast(Memory*)memory.ptr;
        players = iota(4).map!(i => new Player(i, data.players[i], data.playerPanels[i])).array;
        foreach (p; players) addState("player" ~ (p.index + 1).to!string, p);

        static if (is(typeof(config.teams))) {
            int[Character.max + 1] t;
            foreach (c, team; config.teams) if (c >= 0) t[c] = team;
            teams = t;
        }
    }

    override string serverURL() { return config.bingoURL; }

    // The player whose data or panel an address is in
    Player playerAt(Address address) {
        foreach (p; players) {
            if (address >= (*p.data).addr && address < (*p.data).addr + typeof(*p.data).sizeof) return p;
            if (address >= (*p.panel).addr && address < (*p.panel).addr + typeof(*p.panel).sizeof) return p;
        }
        return null;
    }

    @property Player currentPlayer() {
        return data.currentPlayerIndex < 4 ? players[data.currentPlayerIndex] : null;
    }

    abstract bool isBoardScene(Scene scene) const;
    abstract bool isScoreScene(Scene scene) const;
    abstract bool isMiniGameScene(Scene scene) const;
    bool isBoardScene() const { return isBoardScene(data.currentScene); }
    bool isScoreScene() const { return isScoreScene(data.currentScene); }

    // Characters a player can be in this game (Waluigi and Daisy are new in Mario Party 3)
    bool isPlayable(Character c) const {
        return c >= Character.MARIO && c <= Character.DK;
    }

    auto team(const Player p) const { return teams[p.data.character]; }
    auto teamMembers(const Player p) { return players.filter!(t => p && team(t) == team(p)); }
    auto teammates(const Player p) { return teamMembers(p).filter!(t => t !is p); }

    bool isIn4thPlace(const Player p) const {
        return p && players.filter!(o => o !is p).all!(o => o.isAheadOf(p));
    }

    bool isInLastPlace(const Player p) const {
        return p && !players.filter!(o => o !is p).any!(o => p.isAheadOf(o));
    }

    int remainingTurns() const {
        return cast(int)data.totalTurns - cast(int)data.currentTurn + 1;
    }

    // Memory on the game's temporary heap, and back
    uint mallocTemp()(size_t size) {
        if (!tempHeap.alloc) throw new Exception("This game has no temporary heap set up");
        return callGame(tempHeap.alloc, cast(ushort)size);
    }

    void freeTemp()(uint ptr) {
        if (!tempHeap.free) throw new Exception("This game has no temporary heap set up");
        callGame(tempHeap.free, ptr);
    }

    // Each player's turn: saves a state first if the settings say so (not during netplay, see
    // saveStateBeforeEachPlayerTurn), and tells the Bingo page
    override void onFrame() {
        if (isBoardScene()) {
            float turn = data.currentTurn + data.currentPlayerIndex / 4.0f;
            if (turn != currentPlayerTurn) {
                currentPlayerTurn = turn;
                if (config.saveStateBeforeEachPlayerTurn && netplayRole == NetplayRole.none) {
                    setSaveStateSlot(data.currentPlayerIndex + 1);
                    saveGameState();
                }
                struct TurnMessage {
                    immutable type = "turn";
                    float currentTurn;
                    int totalTurns;
                }
                TurnMessage message;
                message.currentTurn = turn;
                message.totalTurns = data.totalTurns;
                sendMessage(message.toJSON);
            }
        }
        super.onFrame();
    }

    override void receive(const JSONValue message) {
        auto type = message["type"].str;
        if (type == "cards") {
            struct Cards { BingoCard[] cards; }
            bingoCards = message.fromJSON!Cards.cards;
            characterToName = null;
            // a card's name has the characters it plays (like "MARIO LUIGI" or "YOSHIDK")
            foreach (ref card; bingoCards) {
                string name = card.name.toUpper;
                while (!name.empty) {
                    auto c = Character.UNDEFINED; // (the longest name it starts with)
                    foreach (m; [EnumMembers!Character][1 .. $]) {
                        if (name.startsWith(m.to!string) && m.to!string.length > c.to!string.length * (c != Character.UNDEFINED)) c = m;
                    }
                    if (c == Character.UNDEFINED) {
                        name.decodeFront;
                    } else {
                        characterToName[c] = gameName(card.formattedName);
                        name = name[c.to!string.length..$];
                    }
                }
            }
        } else if (type == "player-override") {
            overridePlayer(message.fromJSON!PlayerOverride);
        }
    }

    // Sets a player's items from a PlayerOverride, or returns false (changing nothing) if they aren't valid for this game
    bool overrideItems(Player p, string[] items) {
        return items.empty;
    }

    // A bingo admin fixing a mistake: sets the player's coins, stars, items and character in the game
    void overridePlayer(PlayerOverride o) {
        if (o.player < 1 || o.player > players.length) return warning("Ignoring override for player ", o.player);
        auto p = players[o.player - 1];

        Character chr;
        try {
            chr = o.chr.to!Character;
        } catch (ConvException) {
            chr = Character.UNDEFINED;
        }
        if (!isPlayable(chr)) return warning("Ignoring override for P", o.player, ": invalid character ", o.chr);
        if (o.coins < 0 || o.coins > 999) return warning("Ignoring override for P", o.player, ": invalid coins ", o.coins);
        if (o.stars < 0 || o.stars > 99) return warning("Ignoring override for P", o.player, ": invalid stars ", o.stars);
        if (o.items.length > 3 || !overrideItems(p, o.items)) {
            return warning("Ignoring override for P", o.player, ": invalid items ", o.items);
        }

        auto old = p.data.character;
        p.data.character = chr; // Just the game's: a character set in the config still wins (see ConfiguredCharacters)

        p.data.coins = cast(ushort)o.coins;
        p.data.stars = cast(Stars)o.stars;
        if (p.data.maxCoins < p.data.coins) p.data.maxCoins = p.data.coins;

        static if (is(typeof(config.teamScores))) {
            if (config.teamScores) {
                foreach (t; teammates(p)) {
                    t.data.coins = p.data.coins;
                    t.data.stars = p.data.stars;
                    if (t.data.maxCoins < t.data.coins) t.data.maxCoins = t.data.coins;
                }
            }
        }

        info("Bingo admin override for P", o.player, ": ", chr, (chr != old ? " (was " ~ old.to!string ~ ")" : ""),
            ", ", o.stars, " stars, ", o.coins, " coins, items ", o.items);

        players.each!(t => sendPlayerInfo(t));
    }

    // Sends a player to the Bingo page for its player panels
    void sendPlayerInfo(Player player) {
        struct PlayerInfo {
            immutable type = "player";
            int player;
            Character chr;
            int stars;
            int coins;
            PanelColor color;
            bool cpu;
        }
        PlayerInfo info;
        info.player = player.index + 1;
        info.chr = player.data.character;
        info.stars = player.data.stars;
        info.coins = player.data.coins;
        info.color = player.cachedColor;
        info.cpu = player.isCPU;
        auto msg = info.toJSON;
        addPlayerItems(player, msg);
        sendMessage(msg);
    }

    // Adds a player's items to their message for the Bingo page: "items" (Item names) and "itemSlots" (how many they can
    // have). Mario Party 1 has no items.
    void addPlayerItems(Player player, ref JSONValue msg) { }
}

// Custom spaces (standardSpaceRatio, and luckySpaceRatio in games with lucky spaces): blue spaces the plugin turns into
// other kinds, kept in spaces (for the board in spacesBoard) for the whole game. Several features use them, so they're
// the game's: a game class mixes this in.
mixin template CustomSpaces(CustomSpace) {
    CustomSpace[] spaces;
    int spacesBoard = -1; // The board (data.currentBoard) spaces are for (-1: none yet)

    // A new game has none yet
    @Write("data.currentScene") final void clearCustomSpacesAtStart(ref Scene scene) {
        if (scene != Scene.START_BOARD) return;
        spaces = null;
        spacesBoard = -1;
        static if (is(typeof(players[0].state.luckySpaceCount))) {
            foreach (p; players) p.state.luckySpaceCount = 0;
        }
    }

    // Picks the custom spaces the board doesn't have yet and sets the board's spaces to them. Call it from the game's
    // space render function.
    final void assignCustomSpaces() {
        alias SpaceType = typeof(data.spaces[0].type);

        // The spaces may be another board's: start over
        auto board = cast(int)data.currentBoard;
        if (spacesBoard != board) {
            spaces = null;
            spacesBoard = board;
        }
        spaces.length = data.spaceCount;

        auto solidCount = iota(data.spaceCount).filter!(i => data.spaces[i].isSolid).count;
        auto blueSpaces = iota(data.spaceCount).filter!(i => data.spaces[i].type == SpaceType.BLUE);

        void convert(long count, CustomSpace type) {
            if (count <= 0) return;
            blueSpaces.filter!(i => spaces[i] == CustomSpace.DEFAULT).array.randomShuffle(random).take(count)
                      .each!(i => spaces[i] = type);
        }
        foreach (type; config.standardSpaceRatio.keys.sort) {
            auto ratio = config.standardSpaceRatio[type];
            convert(roundTo!long(solidCount * min(ratio, 1.0))
                    - iota(data.spaceCount).count!(i => data.spaces[i].type == type || spaces[i] == cast(CustomSpace)type),
                    cast(CustomSpace)type);
        }
        static if (is(typeof(config.luckySpaceRatio))) {
            convert(roundTo!long(blueSpaces.count * min(config.luckySpaceRatio, 1.0))
                    - spaces.count!(e => e == CustomSpace.LUCKY), CustomSpace.LUCKY);
        }
        blueSpaces.filter!(i => spaces[i] == CustomSpace.DEFAULT).each!(i => spaces[i] = CustomSpace.LOCKED);

        foreach (i; 0 .. data.spaceCount) {
            if (spaces[i] < SpaceType.min || spaces[i] > SpaceType.max) continue;
            if (data.spaces[i].type == SpaceType.STAR) continue;
            static if (__traits(hasMember, SpaceType, "BLACK_STAR")) { // Mario Party 2
                if (data.spaces[i].type == SpaceType.BLACK_STAR) continue;
            }
            data.spaces[i].type = cast(SpaceType)spaces[i];
        }
    }
}

// --- Features more than one game has (see game.d). A game makes them with its own addresses. ---

// A character set in the config: the player is always that character
final class ConfiguredCharacters(G) : Feature!G {
    override bool enabled() { return config.characters.any!(c => c != Character.UNDEFINED); }

    Character configured(G.Player p) {
        return p.index < config.characters.length ? config.characters[p.index] : Character.UNDEFINED;
    }

    override void setUp() {
        foreach (p; players) if (configured(p) != Character.UNDEFINED) p.data.character = configured(p);
    }

    @ReadEach("players", "data.character") @WriteEach("players", "data.character")
    void keepCharacter(G.Player p, ref Character character) {
        if (configured(p) != Character.UNDEFINED) character = configured(p);
    }
}

// The game's own random numbers come from the plugin's (which every netplay machine has the same)
final class RandomizeState(G) : Feature!G {
    @Write("data.randomState") void randomize(ref uint state) {
        state = random.uniform!uint;
    }
}

// teamScores: teammates share coins and stars. A player's coins, stars and most coins go to their teammates in the
// scenes that change scores, unless the scene locks or disables that. A game adds its own cases in a subclass.
class TeamScores(G) : Feature!G {
    override bool enabled() { return config.teamScores; }

    bool locked() const { return false; }   // Teammates' scores stay as they are (like a Chance Time between teammates)
    bool disabled() const { return false; } // Scores change in a way syncing teammates would count twice

    @WriteEach("players", "data.coins") void coinsWritten(G.Player p, ref ushort coins) {
        if (!isScoreScene()) return;
        if (locked()) coins = p.data.coins;
        else if (!disabled()) teammates(p).each!(t => t.data.coins = coins);
    }

    @WriteEach("players", "data.stars") void starsWritten(G.Player p, ref G.Stars stars) {
        if (!isScoreScene()) return;
        if (locked()) stars = p.data.stars;
        else if (!disabled()) teammates(p).each!(t => t.data.stars = stars);
    }

    @WriteEach("players", "data.maxCoins") void maxCoinsWritten(G.Player p, ref ushort maxCoins) {
        if (!isScoreScene()) return;
        if (locked()) maxCoins = p.data.maxCoins;
        else teammates(p).each!(t => t.data.maxCoins = maxCoins);
    }

    @Write("data.currentPlayerIndex") void turnStarted(ref G.PlayerIndex index) {
        if (!isBoardScene() || index >= 4) return;
        foreach (t; teammates(players[index])) {
            t.data.coins = players[index].data.coins;
            t.data.stars = players[index].data.stars;
        }
    }

    // Boo can't steal from the player's own team. The board's Boo routine (where data.booRoutinePtr points, hooked
    // while the board runs) takes everyone's teammates' coins and stars away until it returns.
    static if (is(typeof(G.init.data.booRoutinePtr))) {
        Ptr!Instruction booRoutine; // The Boo routine hooked now

        override void setUp() { booRoutineWritten(data.booRoutinePtr); }

        @Write("data.booRoutinePtr") void booRoutineWritten(ref Ptr!Instruction routine) {
            if (!routine || routine == booRoutine || !isBoardScene()) return;
            if (booRoutine) unhookExec!booRoutineStarted(booRoutine);
            hookExec!booRoutineStarted(routine);
            booRoutine = routine;
        }

        void booRoutineStarted() {
            foreach (t; teammates(currentPlayer)) {
                t.data.coins = 0;
                t.data.stars = 0;
            }
            hookExecOnce!booRoutineReturned(gpr.ra);
        }

        void booRoutineReturned() {
            foreach (t; teammates(currentPlayer)) {
                t.data.coins = currentPlayer.data.coins;
                t.data.stars = currentPlayer.data.stars;
            }
        }

        @Write("data.currentScene") void booSceneChanged(ref G.Scene scene) {
            if (isBoardScene(scene) || !booRoutine) return;
            unhookExec!booRoutineStarted(booRoutine);
            booRoutine = 0;
        }
    }
}

// teamScores: A player can't duel their teammates. The game only lets players with coins be picked, so their teammates
// have no coins from the start of the duel function (duel) until they get the team's coins back: at giveBack if there's
// one, or else when the duel function returns.
// In Mario Party 3 the opponent is picked inside the duel function, so giving them back when it returns works. In Mario
// Party 2 it's picked in the next scene, after the duel function returns, so they only get them back at giveBack (when
// there's no duel, because the player has no coins or nobody to pick). Otherwise TeamScores gives them the team's coins
// in the duel scene (a score scene), when the wager is taken after the opponent is picked, and again when the pot is
// paid out.
final class TeamDuels(G) : Feature!G {
    const Address duel, giveBack;
    this(Address duel, Address giveBack = 0) { this.duel = duel; this.giveBack = giveBack; }

    override bool enabled() { return config.teamScores; }

    @Exec("duel") void duelStarted() {
        if (!isBoardScene()) return;
        teammates(currentPlayer).each!(t => t.data.coins = 0);
        if (!giveBack) hookExecOnce!coinsBack(gpr.ra);
    }

    @Exec("giveBack") void coinsBack() {
        if (!isBoardScene()) return;
        teammates(currentPlayer).each!(t => t.data.coins = currentPlayer.data.coins);
    }
}

// teamScores: A team pays into a battle mini-game's pot once. The game collects coins from every player in the battle
// function (battle), so each team's other players have no coins until it returns, when they get the team's coins back.
// (Mario Party 2's battle function hasn't been found yet.)
final class TeamBattles(G) : Feature!G {
    const Address battle;
    this(Address battle) { this.battle = battle; }

    override bool enabled() { return config.teamScores; }

    @Exec("battle") void battleStarted() {
        if (!isBoardScene()) return;
        foreach (p; players) teammates(p).filter!(t => t.index > p.index).each!(t => t.data.coins = 0);
        hookExecOnce!battleEnded(gpr.ra);
    }

    void battleEnded() {
        foreach (p; players) teammates(p).filter!(t => t.index > p.index).each!(t => t.data.coins = p.data.coins);
    }
}

// teamMiniGames: a 2 vs 2 mini-game's teams are the plugin's teams
final class TeamMiniGames(G) : Feature!G {
    override bool enabled() { return config.teamMiniGames; }

    @Exec("data.determineTeams.addr") void determineTeams() {
        if (!isBoardScene()) return;
        if (!players.all!(p => p.panel.color == PanelColor.BLUE || p.panel.color == PanelColor.RED)) return;
        if (!players.all!(p => teammates(p).any!(t => t.panel.color != p.panel.color))) return; // Every team is split

        foreach (p; players) {
            p.panel.color = team(p) == team(players[0]) ? PanelColor.BLUE : PanelColor.RED;
            p.cachedColor = p.panel.color;
        }
    }
}

// teamControl: a player's controller plays for their teammates (the ones on later ports, that aren't computers)
class TeamControl(G) : Feature!G {
    InputData[4] lastInput; // Each controller's input as the game last read it

    override bool enabled() { return config.teamControl; }
    bool disabled() const { return false; } // (in the scenes where everyone has to press buttons themselves)

    override void onInput(int port, InputData* input) {
        if (!disabled()) {
            auto p = players.find!(p => p.data.controller == port);
            if (!p.empty) {
                auto t = players.find!(t => team(t) == team(p.front) && t.data.controller < port && !t.isCPU);
                if (!t.empty) {
                    p.front.data.flags &= ~0b1; // Not a computer
                    *input = lastInput[t.front.data.controller];
                }
            }
        }
        lastInput[port] = *input;
    }
}

// lastPlaceDoubleRoll: the player in last place rolls twice
final class LastPlaceDoubleRoll(G) : Feature!G {
    override bool enabled() { return config.lastPlaceDoubleRoll; }

    @Read("data.numberOfRolls") void doubleRoll(ref ubyte rolls) {
        if (!isBoardScene() || data.currentTurn <= 1) return;
        if (isInLastPlace(currentPlayer) && rolls < 2) rolls = 2;
    }
}

// alwaysDuel: The game decides whether a duel happens at check (v0). Mario Party 1 has no duels.
final class AlwaysDuel(G) : Feature!G {
    const Address check;
    this(Address check) { this.check = check; }

    override bool enabled() { return config.alwaysDuel; }

    @Exec("check") void duel() { if (isBoardScene()) gpr.v0 = 1; }
}

// mapScrollSpeedMultiplier: The map view's scroll speed is f12 at scroll
final class MapScrollSpeed(G) : Feature!G {
    const Address scroll;
    this(Address scroll) { this.scroll = scroll; }

    override bool enabled() { return config.mapScrollSpeedMultiplier != 1.0; }

    @Exec("scroll") void faster() { if (isBoardScene()) fpr.f12 *= config.mapScrollSpeedMultiplier; }
}

// rankPlayersByBingoScore: Ranks players at the end of the game by their bingo cards (bingos, then squares), then stars
// and coins. The game's placement function starts at start (a0 = the player) and returns the number of players ahead
// of them at end (v0). check holds checkValue when that function is loaded.
final class BingoRanking(G) : Feature!G {
    const Address start, end, check;
    const uint checkValue;
    uint ranked; // The player being placed

    this(Address start, Address end, Address check, uint checkValue) {
        this.start = start;
        this.end = end;
        this.check = check;
        this.checkValue = checkValue;
    }

    override bool enabled() { return config.rankPlayersByBingoScore; }

    @Exec("start") void rankingStarted() {
        if (check.val!uint == checkValue) ranked = gpr.a0;
    }

    @Exec("end") void rankingEnded() {
        if (check.val!uint != checkValue) return;
        auto score(G.Player p) {
            auto card = bingoCards.find!(c => c.characters.canFind(p.data.character));
            return tuple(card.empty ? 0 : card.front.bingos, card.empty ? 0 : card.front.squares, cast(int)p.data.stars,
                         cast(int)p.data.coins);
        }
        gpr.v0 = cast(uint)players.count!(p => p.index != ranked && score(p) > score(players[ranked]));
    }
}

// Chance Time picks its two players by character, so with two players of the same character it could pick the wrong
// one, or the same player twice. The game finds the player for the first and second character at pickFirst and
// pickSecond (a0): these pick a player with that character who isn't the other one instead.
final class ChanceTimeFix(G) : Feature!G {
    const Address pickFirst, pickSecond;
    this(Address pickFirst, Address pickSecond) { this.pickFirst = pickFirst; this.pickSecond = pickSecond; }

    @Exec("pickFirst") void first() {
        if (data.currentScene == G.Scene.CHANCE_TIME) gpr.a0 = pick(data.chancePlayer1, data.chancePlayer2);
    }

    @Exec("pickSecond") void second() {
        if (data.currentScene == G.Scene.CHANCE_TIME) gpr.a0 = pick(data.chancePlayer2, data.chancePlayer1);
    }

    uint pick(int character, int other) {
        return players.filter!(p => p.data.character == character && p.index != other).array.choice(random).index;
    }
}

// randomBonus: Gives 3 random bonus stars instead of the game's: ones that someone has a stat for, if 3 do. When the
// board ends (in a bonus scene), the game loads each player's stat for its i-th bonus star twice: loads[scene][i][0]
// leaves it in v1 and loads[scene][i][1] in v0 (both after the instruction there if afterLoad), with the player's index
// in the register. A game adds its stats (and whatever else its bonus stars need) in a subclass.
abstract class RandomBonus(G, string register) : Feature!G {
    alias BonusType = Unqual!(KeyType!(typeof(G.init.config.bonuses)));

    // Where the game loads a player's stat for a bonus star, the scene it does it in, which of the 3 it's for, and
    // whether the stat goes to v1 (or v0)
    static struct Load { G.Scene scene; size_t slot; bool inV1; }
    const Load[Address] loads;
    const Address[] beforeLoads, afterLoads;
    BonusType[] bonus; // The bonus stars given instead of the game's, in its order (when there are 3)

    this(Address[2][3][G.Scene] loads, bool afterLoad) {
        Load[Address] l;
        foreach (scene, slots; loads) foreach (slot, pair; slots) foreach (i, a; pair) l[a] = Load(scene, slot, i == 0);
        this.loads = l;
        if (afterLoad) afterLoads = l.keys.sort.array;
        else beforeLoads = l.keys.sort.array;
    }

    override bool enabled() { return config.randomBonus; }

    // A player's stat for a bonus star (the most of it wins)
    abstract uint stat(G.Player player, BonusType type);

    @Write("data.currentScene") void pickBonus(ref G.Scene scene) {
        if (!loads.values.canFind!(l => l.scene == scene)) return;
        bonus = config.bonuses.keys.sort.filter!(b => players.any!(p => stat(p, b) > 0)).array;
        if (bonus.length < 3) bonus = config.bonuses.keys.sort.array;
        if (bonus.length >= 3) {
            bonus.randomShuffle(random);
            info("Bonus Stars: ", bonus.take(3));
        }
    }

    @Exec("beforeLoads") @ExecDone("afterLoads") void replaceStat(Address pc) {
        auto load = pc in loads;
        if (!load || data.currentScene != load.scene || bonus.length < 3) return;
        auto value = stat(players[gpr.r[registerIndex!register]], bonus[load.slot]);
        if (load.inV1) gpr.v1 = value; else gpr.v0 = value;
    }
}

// preventRepeatMiniGames, blockedMiniGames: Fills the mini-game roulette (data.miniGameRoulette) from a queue for each
// mini-game type, which skips blocked mini-games (unless all of them are) and doesn't repeat one until the others came
// up. A game hooks its roulette in a subclass.
abstract class MiniGameRoulette(G, MiniGameType, MiniGame) : Feature!G {
    ShuffleStream!MiniGame[MiniGameType] queues;
    uint landing;     // The roulette's entry the game lands on next (see fill())
    int landRegister; // ... and the register it's in

    override bool enabled() { return config.preventRepeatMiniGames || config.blockedMiniGames.length > 0; }

    // A new game starts the queues again
    @Write("data.currentScene") void clearQueues(ref G.Scene scene) {
        if (scene == G.Scene.START_BOARD) queues = null;
    }

    // Fills the roulette with count of the mini-games in games (all of the type, being chosen): the next one in the
    // type's queue, and others, in a random order. The game picks the entry the roulette lands on at landOn (in the
    // register), so it lands on that next one.
    void fill(string register = "v0")(MiniGameType type, MiniGame[] games, int count, Address landOn) {
        auto choices = games.filter!(g => !config.blockedMiniGames.canFind(g)).array;
        if (choices.empty) choices = games; // Every mini-game of this type is blocked
        auto queue = &queues.require(type);
        if (queue.empty) queue.initialize(choices, random);
        auto game = queue.next(random);
        auto roulette = game ~ games.filter!(g => g != game).array.randomShuffle(random).take(count - 1).array;
        roulette.randomShuffle(random).each!((i, e) => data.miniGameRoulette[i] = e);
        landing = cast(uint)roulette.countUntil(game);
        landRegister = registerIndex!register;
        hookExecOnce!land(landOn);
    }

    void land() {
        gpr.r[landRegister] = landing;
    }
}

// The Bingo page's player panels: sends players to it when their stars, coins, items, panel color or CPU flag change,
// and around mini-games. Make it the game's last feature: hooks at one address run in the order they're set, so these
// see the values the game's other hooks leave. A game with items adds them in a subclass.
class PlayerInfo(G) : Feature!G {
    @WriteEach("players", "data.stars") void starsChanged(G.Player p, ref G.Stars stars) {
        if (!isScoreScene() || stars == p.data.stars) return;
        p.data.stars = stars;
        sendPlayerInfo(p);
    }

    @WriteEach("players", "data.coins") void coinsChanged(G.Player p, ref ushort coins) {
        if (!isScoreScene() || coins == p.data.coins) return;
        p.data.coins = coins;
        sendPlayerInfo(p);
    }

    @WriteEach("players", "panel.color") void panelColorChanged(G.Player p, ref PanelColor color) {
        if (!isBoardScene() || color == p.panel.color || color == p.cachedColor || color > PanelColor.max) return;
        p.cachedColor = color;
        sendPlayerInfo(p);
    }

    @WriteEach("players", "data.flags") void cpuFlagChanged(G.Player p, ref ubyte flags) {
        if (!isBoardScene() || flags.isCPU == p.data.flags.isCPU) return;
        p.data.flags = flags;
        sendPlayerInfo(p);
    }

    @Write("data.currentScene") void miniGameSceneChanged(ref G.Scene scene) {
        if (data.currentScene == G.Scene.MINI_GAME_RESULTS) players.each!(p => p.cachedColor = PanelColor.NONE);
        if (data.currentScene == G.Scene.MINI_GAME_RESULTS || isMiniGameScene(scene) || scene == G.Scene.MINI_GAME_RULES) {
            players.each!(p => sendPlayerInfo(p));
        }
    }
}

mixin NoMutableGlobals;
