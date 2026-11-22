module me.timz.n64.marioparty;

import me.timz.n64.plugin;
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

string shortName(Character character) pure {
    final switch (character) {
        case Character.UNDEFINED: return "<WHITE>(?)<RESET>";
        case Character.MARIO:     return "<RED>(M)<RESET>";
        case Character.LUIGI:     return "<GREEN>(L)<RESET>";
        case Character.PEACH:     return "<MAGENTA>(P)<RESET>";
        case Character.YOSHI:     return "<GREEN>(Y)<RESET>";
        case Character.WARIO:     return "<YELLOW>(W)<RESET>";
        case Character.DK:        return "<RED>(D)<RESET>";
        case Character.WALUIGI:   return "<BLUE>(W)<RESET>";
        case Character.DAISY:     return "<YELLOW>(D)<RESET>";
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
    bool saveStateBeforeEachPlayerTurn = false;
    string bingoURL = "";
    bool rankPlayersByBingoScore = false;
}

// What every game keeps in the State: the plugin's PlayerState for each player, and the turn it last saw (see
// onFrame()). Each game's State adds its own.
class MarioPartyState(PlayerState) {
    PlayerState[] players = [
        new PlayerState(),
        new PlayerState(),
        new PlayerState(),
        new PlayerState()
    ];
    float currentPlayerTurn = 0;
}

// A player: their data in the game's memory, their panel on the board, and the plugin's State for them
class MarioPartyPlayer(PlayerData, PlayerPanel, PlayerState) {
    const uint index;
    PlayerData* data;
    PlayerPanel* panel;
    PanelColor cachedColor;
    PlayerState state;

    this(uint index, ref PlayerData data, ref PlayerPanel panel) {
        this.index = index;
        this.data = &data;
        this.panel = &panel;
        this.cachedColor = PanelColor.NONE;
    }

    @property bool isCPU() const {
        return data.flags.isCPU;
    }

    bool isAheadOf(const MarioPartyPlayer o) const {
        if (data.stars == o.data.stars) {
            return data.coins > o.data.coins;
        } else {
            return data.stars > o.data.stars;
        }
    }
}

// The code every game shares. Code for things only some games have is in function templates (with "()" before their
// parameters), which only get compiled for the games that call them, or under "static if" when it declares members.
class MarioParty(Config : MarioPartyConfig, State, Memory) : Game!(Config, State) {
    alias Scene = typeof(Memory.currentScene);
    alias Player = MarioPartyPlayer!(typeof(Memory.players.front), typeof(Memory.playerPanels.front), typeof(State.players[0]));

    Memory* data;
    Player[] players;
    int[Character.max+1] teams;

    // The bingo cards, as the bingo site last sent them. They aren't part of the State: they belong to the live bingo
    // session, so loading a save state mustn't bring back older cards. The site sends them whenever the plugin connects.
    BingoCard[] bingoCards;
    string[Character] characterToName;

    this(string name, string hash) {
        super(name, hash);

        data = cast(Memory*)memory.ptr;
        players = iota(4).map!(i => new Player(i, data.players[i], data.playerPanels[i])).array;
    }

    override void loadConfig() {
        super.loadConfig();

        static if (is(typeof(config.teams))) {
            teams.each!((c, ref t) => t = config.teams.require(cast(Character)c, t));
        }
    }

    // Also runs when a save state brings back a different State
    override void stateLoaded() {
        super.stateLoaded();

        players.each!(p => p.state = state.players[p.index]);
    }

    @property Player currentPlayer() {
        return data.currentPlayerIndex < 4 ? players[data.currentPlayerIndex] : null;
    }

    abstract bool lockTeamScores() const;
    abstract bool disableTeamScores() const;
    abstract bool disableTeamControl() const;
    abstract bool isBoardScene(Scene scene) const;
    abstract bool isScoreScene(Scene scene) const;
    abstract bool isMiniGameScene(Scene scene) const;
    bool isBoardScene() const { return isBoardScene(data.currentScene); }
    bool isScoreScene() const { return isScoreScene(data.currentScene); }

    // Characters a player can be in this game (Waluigi and Daisy are new in Mario Party 3)
    bool isPlayable(Character c) const {
        return c >= Character.MARIO && c <= Character.DK;
    }

    // Sets a player's items from a PlayerOverride, or returns false (changing nothing) if they aren't valid for this game
    bool overrideItems(Player p, string[] items) {
        return items.empty;
    }

    auto team(const Player p) const {
        return teams[p.data.character];
    }

    auto teamMembers(const Player p) {
        return players.filter!(t => p && team(t) == team(p));
    }

    auto teammates(const Player p) {
        return teamMembers(p).filter!(t => t !is p);
    }

    bool isIn4thPlace(const Player p) const {
        return p && players.filter!(o => o !is p).all!(o => o.isAheadOf(p));
    }

    bool isInLastPlace(const Player p) const {
        return p && !players.filter!(o => o !is p).any!(o => p.isAheadOf(o));
    }

    int remainingTurns() const {
        return cast(int)data.totalTurns - cast(int)data.currentTurn + 1;
    }

    override void onStart() {
        super.onStart();

        if (!config.bingoURL.empty) {
            connect(config.bingoURL);
        }

        players.each!((i, p) {
            if (i >= config.characters.length) return;
            if (config.characters[i] == Character.UNDEFINED) return;
            p.data.character = config.characters[i];
            p.data.character.onRead( (ref Character character) { character = config.characters[i]; });
            p.data.character.onWrite((ref Character character) { character = config.characters[i]; });
        });

        data.currentScene.onWrite((ref Scene scene) {
            if (scene == data.currentScene) return;

            //info("Scene: ", scene);
        });

        static if (is(typeof(data.randomState))) {
            data.randomState.onWrite((ref uint state) {
                state = random.uniform!uint;
            });
        }

        static if (is(typeof(config.teamScores))) {
            if (config.teamScores) {
                players.each!((p) {
                    p.data.coins.onWrite((ref ushort coins) {
                        if (!isScoreScene()) return;
                        if (lockTeamScores()) {
                            coins = p.data.coins;
                        } else if (!disableTeamScores()) {
                            teammates(p).each!((t) {
                                t.data.coins = coins;
                            });
                        }
                    });
                    p.data.stars.onWrite((ref typeof(p.data.stars) stars) {
                        if (!isScoreScene()) return;
                        if (lockTeamScores()) {
                            stars = p.data.stars;
                        } else if (!disableTeamScores()) {
                            teammates(p).each!((t) {
                                t.data.stars = stars;
                            });
                        }
                    });
                    p.data.maxCoins.onWrite((ref ushort maxCoins) {
                        if (!isScoreScene()) return;
                        if (lockTeamScores()) {
                            maxCoins = p.data.maxCoins;
                        } else {
                            teammates(p).each!((t) {
                                t.data.maxCoins = maxCoins;
                            });
                        }
                    });
                });

                data.currentPlayerIndex.onWrite((ref typeof(data.currentPlayerIndex) index) {
                    if (!isBoardScene()) return;
                    if (index >= 4) return;
                    teammates(players[index]).each!((t) {
                        t.data.coins = players[index].data.coins;
                        t.data.stars = players[index].data.stars;
                    });
                });

                static if (is(typeof(data.booRoutinePtr))) {
                    Ptr!Instruction previousRoutinePtr = 0;
                    auto booRoutinePtrHandler = delegate void(ref Ptr!Instruction routinePtr) {
                        if (!routinePtr || routinePtr == previousRoutinePtr || !isBoardScene()) return;
                        if (previousRoutinePtr) {
                            executeHandlers.remove(previousRoutinePtr);
                        }
                        routinePtr.onExec({
                            teammates(currentPlayer).each!((t) {
                                t.data.coins = 0;
                                t.data.stars = 0;
                            });
                            gpr.ra.onExecOnce({
                                teammates(currentPlayer).each!((t) {
                                    t.data.coins = currentPlayer.data.coins;
                                    t.data.stars = currentPlayer.data.stars;
                                });
                            });
                        });
                        previousRoutinePtr = routinePtr;
                    };
                    data.booRoutinePtr.onWrite(booRoutinePtrHandler);
                    data.currentScene.onWrite((ref Scene scene) {
                        if (!isBoardScene(scene) && previousRoutinePtr) {
                            executeHandlers.remove(previousRoutinePtr);
                            previousRoutinePtr = 0;
                        }
                    });
                    booRoutinePtrHandler(data.booRoutinePtr);
                }
            }
        }

        static if (is(typeof(config.teamMiniGames)) && is(typeof(Player.panel)) && is(typeof(data.determineTeams))) {
            if (config.teamMiniGames) {
                data.determineTeams.addr.onExec({
                    if (!isBoardScene()) return;

                    auto allBlueOrRed = players.all!(p => p.panel.color == PanelColor.BLUE || p.panel.color == PanelColor.RED);
                    if (!allBlueOrRed) return;

                    auto allTeamsSplit = players.all!(p => teammates(p).any!(t => t.panel.color != p.panel.color));
                    if (!allTeamsSplit) return;
                    
                    players.each!(p => p.panel.color = (team(p) == team(players[0]) ? PanelColor.BLUE : PanelColor.RED));
                    players.each!(p => p.cachedColor = p.panel.color);
                });
            }
        }

        static if (is(typeof(data.numberOfRolls))) {
            if (config.lastPlaceDoubleRoll) {
                data.numberOfRolls.onRead((ref ubyte rolls) {
                    if (!isBoardScene()) return;
                    if (data.currentTurn <= 1) return;
                    if (isInLastPlace(currentPlayer) && rolls < 2) {
                        rolls = 2;
                    }
                });
            }
        }
    }

    override void onInput(int port, InputData* data) {
        static InputData[4] input;

        super.onInput(port, data);

        static if (is(typeof(config.teamControl))) {
            if (config.teamControl && !disableTeamControl()) {
                auto p = players.find!(p => p.data.controller == port);
                if (!p.empty) {
                    auto t = players.find!(t => team(t) == team(p.front) && t.data.controller < port && !t.isCPU);
                    if (!t.empty) {
                        p.front.data.flags &= ~0b1; // Disable CPU flag

                        *data = input[t.front.data.controller];
                    }
                }
            }
        }

        input[port] = *data;
    }

    override void onMessage(string msg) {
        super.onMessage(msg);

        auto json = parseJSON(msg);

        if (json.object["type"].str == "cards") {
            immutable CHARS = [EnumMembers!Character];
            
            struct Message { BingoCard[] cards; }

            characterToName.clear();

            bingoCards = json.fromJSON!Message().cards;
            bingoCards.each!((ref card) {
                string name = card.name.toUpper();
                while (!name.empty) {
                    ptrdiff_t m = -1;
                    CHARS.each!((i, c) {
                        if (!name.startsWith(c.to!string)) return;
                        if (m == -1 || c.to!string.length > CHARS[m].to!string.length) {
                            m = i;
                        }
                    });
                    if (m == -1) {
                        name.decodeFront;
                    } else {
                        characterToName[CHARS[m]] = gameName(card.formattedName);
                        name = name[CHARS[m].to!string.length..$];
                    }
                }
            });
        } else if (json.object["type"].str == "player-override") {
            overridePlayer(json.fromJSON!PlayerOverride());
        }
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
        p.data.character = chr; // Just the game's: a character set in the config still wins (see onStart())

        p.data.coins = cast(ushort)o.coins;
        p.data.stars = cast(typeof(p.data.stars))o.stars;
        if (p.data.maxCoins < p.data.coins) p.data.maxCoins = p.data.coins;

        static if (is(typeof(config.teamScores))) {
            if (config.teamScores) {
                teammates(p).each!((t) {
                    t.data.coins = p.data.coins;
                    t.data.stars = p.data.stars;
                    if (t.data.maxCoins < t.data.coins) t.data.maxCoins = t.data.coins;
                });
            }
        }

        info("Bingo admin override for P", o.player, ": ", chr, (chr != old ? " (was " ~ old.to!string ~ ")" : ""),
            ", ", o.stars, " stars, ", o.coins, " coins, items ", o.items);

        saveState();
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

        PlayerInfo fields;
        fields.player = player.index + 1;
        fields.chr = player.data.character;
        fields.stars = player.data.stars;
        fields.coins = player.data.coins;
        fields.color = player.cachedColor;
        fields.cpu = player.isCPU;

        auto msg = fields.toJSON();
        addPlayerItems(player, msg);
        sendMessage(msg);
    }

    // Adds a player's items to their message for the Bingo page: "items" (Item names) and "itemSlots" (how many they can
    // have). Mario Party 1 has no items.
    void addPlayerItems(Player player, ref JSONValue msg) { }

    // Sends players to the Bingo page when their stars, coins, items, panel color or CPU flag change, and around
    // mini-games. Call it at the end of onStart(): handlers run in the order they're added, so these see the values
    // the game's other handlers leave.
    void watchPlayerInfo() {
        players.each!((p) {
            p.data.stars.onWrite((ref typeof(p.data.stars) stars) {
                if (!isScoreScene(data.currentScene)) return;
                if (stars == p.data.stars) return;

                p.data.stars = stars;

                sendPlayerInfo(p);
            });

            p.data.coins.onWrite((ref ushort coins) {
                if (!isScoreScene(data.currentScene)) return;
                if (coins == p.data.coins) return;

                p.data.coins = coins;

                sendPlayerInfo(p);
            });

            watchPlayerItems(p);

            p.panel.color.onWrite((ref PanelColor color) {
                if (!isBoardScene(data.currentScene)) return;
                if (color == p.panel.color || color == p.cachedColor) return;
                if (color > PanelColor.max) return;

                p.cachedColor = color;

                sendPlayerInfo(p);
            });

            p.data.flags.onWrite((ref ubyte flags) {
                if (!isBoardScene(data.currentScene)) return;
                if (flags.isCPU == p.data.flags.isCPU) return;

                p.data.flags = flags;

                sendPlayerInfo(p);
            });
        });

        data.currentScene.onWrite((ref Scene scene) {
            if (data.currentScene == Scene.MINI_GAME_RESULTS) {
                players.each!(p => p.cachedColor = PanelColor.NONE);
            }

            if (data.currentScene == Scene.MINI_GAME_RESULTS || isMiniGameScene(scene) || scene == Scene.MINI_GAME_RULES) {
                players.each!(p => sendPlayerInfo(p));
            }
        });
    }

    // Like watchPlayerInfo(), for a player's items (called by it, for each player)
    void watchPlayerItems(Player p) { }

    // Options more than one game has. Each game calls these from its onStart() with its own addresses. Where a game
    // calls them matters: handlers at the same address run in the order they're added.

    // rankPlayersByBingoScore: Ranks players at the end of the game by their bingo cards (bingos, then squares), then
    // stars and coins. The game's placement function starts at start (a0 = the player) and returns the number of
    // players ahead of them at end (v0). check holds checkValue when that function is loaded.
    void setUpBingoRanking(Address start, Address end, Address check, uint checkValue) {
        Player player = null;

        start.onExec({
            if (check.val!uint != checkValue) return;

            player = players[gpr.a0];
        });
        end.onExec({
            if (check.val!uint != checkValue) return;

            auto card = bingoCards.find!(c => c.characters.canFind(player.data.character));

            gpr.v0 = 0;
            players.filter!(p => p != player).each!((p) {
                auto c = bingoCards.find!(c => c.characters.canFind(p.data.character));

                if ((c.empty ? 0 : c.front.bingos) > (card.empty ? 0 : card.front.bingos)) gpr.v0++;
                else if ((c.empty ? 0 : c.front.bingos) < (card.empty ? 0 : card.front.bingos)) { }
                else if ((c.empty ? 0 : c.front.squares) > (card.empty ? 0 : card.front.squares)) gpr.v0++;
                else if ((c.empty ? 0 : c.front.squares) < (card.empty ? 0 : card.front.squares)) { }
                else if (p.data.stars > player.data.stars) gpr.v0++;
                else if (p.data.stars < player.data.stars) { }
                else if (p.data.coins > player.data.coins) gpr.v0++;
            });
        });
    }

    // alwaysDuel: The game decides whether a duel happens at check (v0). Mario Party 1 has no duels.
    void setUpAlwaysDuel()(Address check) {
        check.onExec({ if (isBoardScene()) gpr.v0 = 1; });
    }

    // teamScores: A player can't duel their teammates. The game only lets players with coins be picked, so their
    // teammates have no coins from the start of the duel function (duel) until they get the team's coins back: at
    // giveBack if there's one, or else when the duel function returns.
    // In Mario Party 3 the opponent is picked inside the duel function, so giving them back when it returns works.
    // In Mario Party 2 it's picked in the next scene, after the duel function returns, so they only get them back at
    // giveBack (when there's no duel, because the player has no coins or nobody to pick). Otherwise the team score
    // handlers in onStart() give them the team's coins in the duel scene (a score scene), when the wager is taken after
    // the opponent is picked, and again when the pot is paid out.
    void setUpTeamDuels()(Address duel, Address giveBack = 0) {
        duel.onExec({
            if (!isBoardScene()) return;
            teammates(currentPlayer).each!((t) {
                t.data.coins = 0;
            });
            if (giveBack) return;
            gpr.ra.onExecOnce({
                teammates(currentPlayer).each!((t) {
                    t.data.coins = currentPlayer.data.coins;
                });
            });
        });

        if (giveBack) {
            giveBack.onExec({
                if (!isBoardScene()) return;
                teammates(currentPlayer).each!((t) {
                    t.data.coins = currentPlayer.data.coins;
                });
            });
        }
    }

    // teamScores: A team pays into a battle mini-game's pot once. The game collects coins from every player in the
    // battle function (battle), so each team's other players have no coins until it returns, when they get the team's
    // coins back. (Mario Party 2's battle function hasn't been found yet.)
    void setUpTeamBattles()(Address battle) {
        battle.onExec({
            if (!isBoardScene()) return;
            players.each!((p) {
                teammates(p).filter!(t => t.index > p.index).each!((t) {
                    t.data.coins = 0;
                });
            });
            gpr.ra.onExecOnce({
                players.each!((p) {
                    teammates(p).filter!(t => t.index > p.index).each!((t) {
                        t.data.coins = p.data.coins;
                    });
                });
            });
        });
    }

    // mapScrollSpeedMultiplier: The map view's scroll speed is f12 at scroll
    void setUpMapScrollSpeed()(Address scroll) {
        scroll.onExec({
            if (!isBoardScene()) return;

            fpr.f12 *= config.mapScrollSpeedMultiplier;
        });
    }

    static if (is(typeof(Config.bonuses))) {
        alias BonusType = KeyType!(typeof(Config.bonuses));

        BonusType[] bonus; // randomBonus: the bonus stars given instead of the game's, in its order (when there are 3)

        // A player's stat for a bonus star (the most of it wins)
        abstract uint getBonusStat(Player player, BonusType type);

        // randomBonus: Gives 3 random bonus stars instead of the game's: ones that someone has a stat for, if 3 do.
        // When the board ends (in bonusScene), the game loads each player's stat for its i-th bonus star twice:
        // statLoads[i][0] leaves it in v1 and statLoads[i][1] in v0 (both after the instruction there if afterLoad),
        // with the player's index in playerRegister.
        void setUpRandomBonus(string playerRegister)(Address[2][3] statLoads, bool afterLoad,
                                                     Scene bonusScene = Scene.FINISH_BOARD) {
            data.currentScene.onWrite((ref Scene scene) {
                if (scene != bonusScene) return;
                bonus = config.bonuses.keys.filter!(b => players.any!(p => getBonusStat(p, b) > 0)).array;
                if (bonus.length < 3) {
                    bonus = config.bonuses.keys;
                }
                if (bonus.length >= 3) {
                    bonus.randomShuffle(random);
                    info("Bonus Stars: ", bonus.take(3));
                }
            });

            // Each in its own call, so each handler gets its own slot and register
            void replaceStat(Address address, size_t slot, bool inV1) {
                auto replace = {
                    if (data.currentScene != bonusScene) return;
                    if (bonus.length < 3) return;
                    auto stat = getBonusStat(players[mixin("gpr." ~ playerRegister)], bonus[slot]);
                    if (inV1) gpr.v1 = stat; else gpr.v0 = stat;
                };
                if (afterLoad) address.onExecDone(replace); else address.onExec(replace);
            }
            foreach (slot; 0..3) {
                replaceStat(statLoads[slot][0], slot, true);
                replaceStat(statLoads[slot][1], slot, false);
            }
        }
    }

    // preventRepeatMiniGames, blockedMiniGames: Fills the mini-game roulette (data.miniGameRoulette) with count of the
    // mini-games in games (all of the category being chosen, type): the next one in the category's queue, which skips
    // blocked mini-games (unless all of them are), and others, in a random order. The game picks the entry the roulette
    // lands on at landOn (in landRegister), so it lands on that next one.
    void fillMiniGameRoulette(string landRegister = "v0", MiniGameType, MiniGame)(MiniGameType type, MiniGame[] games,
                                                                                int count, Address landOn) {
        auto choices = games.filter!(g => !config.blockedMiniGames.canFind(g)).array;
        if (choices.empty) choices = games; // Every mini-game of this type is blocked
        auto queue = &state.miniGameQueue.require(type);
        if (queue.empty) queue.initialize(choices, random);
        auto game = queue.next(random);
        auto roulette = game ~ games.filter!(g => g != game).array.randomShuffle(random).take(count - 1);
        roulette.randomShuffle(random).each!((i, e) => data.miniGameRoulette[i] = e);
        landOn.onExecOnce({ mixin("gpr." ~ landRegister) = cast(uint)roulette.countUntil(game); });
    }

    // Custom spaces (standardSpaceRatio, and luckySpaceRatio in games with lucky spaces): blue spaces the plugin turns
    // into other kinds, kept in state.spaces for the whole game. These clear them when a game starts.
    void resetCustomSpacesAtStart()() {
        data.currentScene.onWrite((ref Scene scene) { // Reset lucky spaces at start of game
            if (scene != Scene.START_BOARD) return;

            state.spaces.length = 0;
            static if (is(typeof(state.players[0].luckySpaceCount))) {
                state.players.each!(p => p.luckySpaceCount = 0);
            }
            saveState();
        });
    }

    // Picks the custom spaces the board doesn't have yet and sets the board's spaces to them. Call it from the game's
    // space render function. Returns whether state.spaces changed (so it needs saving).
    bool assignCustomSpaces()() {
        alias SpaceType = typeof(data.spaces[0].type);
        alias CustomSpace = typeof(state.spaces[0]);

        bool changed = false;

        if (state.spaces.length != data.spaceCount) {
            state.spaces.length = data.spaceCount;
            changed = true;
        }

        auto solidCount = iota(data.spaceCount).filter!(i => data.spaces[i].isSolid).count;
        auto blueSpaces = iota(data.spaceCount).filter!(i => data.spaces[i].type == SpaceType.BLUE);

        foreach (type, ratio; config.standardSpaceRatio) {
            long newCount = roundTo!long(solidCount * min(ratio, 1.0))
                          - iota(data.spaceCount).count!(i => data.spaces[i].type == type || state.spaces[i] == cast(CustomSpace)type);
            if (newCount > 0) {
                blueSpaces.filter!(i => state.spaces[i] == CustomSpace.DEFAULT)
                          .array.randomShuffle(random).take(newCount).each!((i) {
                    state.spaces[i] = cast(CustomSpace)type;
                    changed = true;
                });
            }
        }

        static if (is(typeof(config.luckySpaceRatio))) { // Games with lucky spaces
            long newCount = roundTo!long(blueSpaces.count * min(config.luckySpaceRatio, 1.0))
                          - state.spaces.count!(e => e == CustomSpace.LUCKY);
            if (newCount > 0) {
                blueSpaces.filter!(i => state.spaces[i] == CustomSpace.DEFAULT)
                          .array.randomShuffle(random).take(newCount).each!((i) {
                    state.spaces[i] = CustomSpace.LUCKY;
                    changed = true;
                });
            }
        }

        blueSpaces.filter!(i => state.spaces[i] == CustomSpace.DEFAULT).each!((i) {
            state.spaces[i] = CustomSpace.LOCKED;
            changed = true;
        });

        iota(data.spaceCount).each!((i) {
            if (state.spaces[i] < SpaceType.min) return;
            if (state.spaces[i] > SpaceType.max) return;
            if (data.spaces[i].type == SpaceType.STAR) return;
            static if (__traits(hasMember, SpaceType, "BLACK_STAR")) { // Mario Party 2
                if (data.spaces[i].type == SpaceType.BLACK_STAR) return;
            }

            data.spaces[i].type = cast(SpaceType)state.spaces[i];
        });

        return changed;
    }

    // Logs how many lucky spaces each player landed on, when the game ends
    void logLuckySpaces()() {
        data.currentScene.onWrite((ref Scene scene) {
            if (scene != Scene.FINAL_RESULTS) return;
            info("Lucky Spaces:");
            iota(4).map!(i => players[data.finalPlayerRankOrder[i]]).each!((p) {
                info(format("    %-8s %2d", p.data.character.to!string ~ ":", p.state.luckySpaceCount));
            });
        });
    }

    // Chance Time picks its two players by character, so with two players of the same character it could pick the
    // wrong one, or the same player twice. The game finds the player for the first and second character at pickFirst
    // and pickSecond (a0): these pick a player with that character who isn't the other one instead.
    void fixChanceTimeDuplicates(Address pickFirst, Address pickSecond) {
        pickFirst.onExec({
            if (data.currentScene != Scene.CHANCE_TIME) return;

            gpr.a0 = players.filter!(p => p.data.character == data.chancePlayer1)
                            .filter!(p => p.index != data.chancePlayer2)
                            .array.choice(random).index;
        });

        pickSecond.onExec({
            if (data.currentScene != Scene.CHANCE_TIME) return;

            gpr.a0 = players.filter!(p => p.data.character == data.chancePlayer2)
                            .filter!(p => p.index != data.chancePlayer1)
                            .array.choice(random).index;
        });
    }

    // The game's heaps, through its own functions (so these call back when the game's code is done). The permanent
    // heap's are permanentHeap's; games that use the temporary heap set tempHeap.
    struct TempHeap { Address alloc, free; }
    TempHeap tempHeap;

    void mallocPerm(size_t size, void delegate(uint ptr) callback) {
        permanentHeap.alloc.jal(cast(ushort)size, callback);
    }

    void freePerm(uint ptr, void delegate() callback) {
        permanentHeap.free.jal(ptr, callback);
    }

    void mallocTemp(size_t size, void delegate(uint ptr) callback) {
        if (!tempHeap.alloc) throw new Exception("This game has no temporary heap set up");
        tempHeap.alloc.jal(cast(ushort)size, callback);
    }

    void freeTemp(uint ptr, void delegate() callback) {
        if (!tempHeap.free) throw new Exception("This game has no temporary heap set up");
        tempHeap.free.jal(ptr, callback);
    }

    void onTurn(float turn) {

    }

    override void onFrame(ulong frame) {
        super.onFrame(frame);

        if (!isBoardScene(data.currentScene)) return;

        float currentPlayerTurn = data.currentTurn + data.currentPlayerIndex / 4.0f;
        if (currentPlayerTurn == state.currentPlayerTurn) return;

        state.currentPlayerTurn = currentPlayerTurn;
        saveState();

        if (config.saveStateBeforeEachPlayerTurn) {
            setSaveStateSlot(data.currentPlayerIndex + 1);
            saveGameState();
        }

        onTurn(currentPlayerTurn);

        struct TurnMessage {
            immutable type = "turn";
            float currentTurn;
            int totalTurns;
        }
        TurnMessage msg;
        msg.currentTurn = currentPlayerTurn;
        msg.totalTurns = data.totalTurns;
        sendMessage(msg.toJSON());
    }
}
