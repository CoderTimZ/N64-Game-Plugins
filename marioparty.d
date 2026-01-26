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

enum PanelColor : ubyte {
    CLEAR = 0,
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

immutable Tuple!(ubyte, "id", string, "text")[] FORMATTING = [
    tuple(cast(ubyte)0x00, "<NUL>"),
    tuple(cast(ubyte)0x01, "<BLACK>"),
    tuple(cast(ubyte)0x02, "<BLUE>"),
    tuple(cast(ubyte)0x03, "<RED>"),
    tuple(cast(ubyte)0x04, "<PINK>"),
    tuple(cast(ubyte)0x05, "<GREEN>"),
    tuple(cast(ubyte)0x06, "<CYAN>"),
    tuple(cast(ubyte)0x07, "<YELLOW>"),
    tuple(cast(ubyte)0x08, "<WHITE>"),
    tuple(cast(ubyte)0x0E, "<TAB>"),
    tuple(cast(ubyte)0x0F, "<BOLD>"),
    tuple(cast(ubyte)0x10, "<SMALL_TAB>"),
    tuple(cast(ubyte)0x11, "<1>"),
    tuple(cast(ubyte)0x12, "<2>"),
    tuple(cast(ubyte)0x13, "<3>"),
    tuple(cast(ubyte)0x14, "<4>"),
    tuple(cast(ubyte)0x15, "<5>"),
    tuple(cast(ubyte)0x16, "<NORMAL>"),
    tuple(cast(ubyte)0x17, "<DELETE_LINE>"),
    tuple(cast(ubyte)0x18, "<DELETE_CHAR>"),
    tuple(cast(ubyte)0x19, "<RESET>"),
    tuple(cast(ubyte)0x1A, "<TAB2>"),
    tuple(cast(ubyte)0x21, "<A>"),
    tuple(cast(ubyte)0x22, "<B>"),
    tuple(cast(ubyte)0x23, "<C_UP>"),
    tuple(cast(ubyte)0x24, "<C_RIGHT>"),
    tuple(cast(ubyte)0x25, "<C_LEFT>"),
    tuple(cast(ubyte)0x26, "<C_DOWN>"),
    tuple(cast(ubyte)0x27, "<Z>"),
    tuple(cast(ubyte)0x28, "<STICK>"),
    tuple(cast(ubyte)0x29, "<COIN>"),
    tuple(cast(ubyte)0x2A, "<STAR>"),
    tuple(cast(ubyte)0x2B, "<START>"),
    tuple(cast(ubyte)0x2C, "<R>"),
    tuple(cast(ubyte)0x3A, "<COIN_OUTLINE>"),
    tuple(cast(ubyte)0x3B, "<STAR_OUTLINE>"),
    tuple(cast(ubyte)0x3C, "+"),
    tuple(cast(ubyte)0x3D, "-"),
    tuple(cast(ubyte)0x3E, "×"),
    tuple(cast(ubyte)0x3F, "→"),
    tuple(cast(ubyte)0x5B, "\""),
    tuple(cast(ubyte)0x5C, "'"),
    tuple(cast(ubyte)0x5D, "("),
    tuple(cast(ubyte)0x5E, ")"),
    tuple(cast(ubyte)0x5F, "/"),
    tuple(cast(ubyte)0x7B, ":"),
    tuple(cast(ubyte)0x7C, "÷"),
    tuple(cast(ubyte)0x7D, "·"),
    tuple(cast(ubyte)0x7E, "&"),
    tuple(cast(ubyte)0x82, ","),
    tuple(cast(ubyte)0x84, "<LINE>"),
    tuple(cast(ubyte)0x85, "."),
    tuple(cast(ubyte)0x86, "_"),
    tuple(cast(ubyte)0x87, "<TAB3>"),
    tuple(cast(ubyte)0x91, "Ä"),
    tuple(cast(ubyte)0x92, "Ö"),
    tuple(cast(ubyte)0x93, "Ü"),
    tuple(cast(ubyte)0x94, "ß"),
    tuple(cast(ubyte)0x95, "À"),
    tuple(cast(ubyte)0x96, "Á"),
    tuple(cast(ubyte)0x97, "È"),
    tuple(cast(ubyte)0x98, "É"),
    tuple(cast(ubyte)0x99, "Ì"),
    tuple(cast(ubyte)0x9A, "Í"),
    tuple(cast(ubyte)0x9B, "Ò"),
    tuple(cast(ubyte)0x9C, "Ó"),
    tuple(cast(ubyte)0x9D, "Ù"),
    tuple(cast(ubyte)0x9E, "Ú"),
    tuple(cast(ubyte)0x9F, "Ñ"),
    tuple(cast(ubyte)0xA0, "<BIG_0>"),
    tuple(cast(ubyte)0xA1, "<BIG_1>"),
    tuple(cast(ubyte)0xA2, "<BIG_2>"),
    tuple(cast(ubyte)0xA3, "<BIG_3>"),
    tuple(cast(ubyte)0xA4, "<BIG_4>"),
    tuple(cast(ubyte)0xA5, "<BIG_5>"),
    tuple(cast(ubyte)0xA6, "<BIG_6>"),
    tuple(cast(ubyte)0xA7, "<BIG_7>"),
    tuple(cast(ubyte)0xA8, "<BIG_8>"),
    tuple(cast(ubyte)0xA9, "<BIG_9>"),
    tuple(cast(ubyte)0xC0, "<COPY_NEXT>"),
    tuple(cast(ubyte)0xC1, "\""),
    tuple(cast(ubyte)0xC2, "!"),
    tuple(cast(ubyte)0xC3, "?"),
    tuple(cast(ubyte)0xC4, "⁉"),
    tuple(cast(ubyte)0xC5, "‼"),
    tuple(cast(ubyte)0xC6, "¿"),
    tuple(cast(ubyte)0xC7, "¡"),
    tuple(cast(ubyte)0xD1, "à"),
    tuple(cast(ubyte)0xD2, "â"),
    tuple(cast(ubyte)0xD3, "ä"),
    tuple(cast(ubyte)0xD4, "ç"),
    tuple(cast(ubyte)0xD5, "è"),
    tuple(cast(ubyte)0xD6, "é"),
    tuple(cast(ubyte)0xD7, "ê"),
    tuple(cast(ubyte)0xD8, "ë"),
    tuple(cast(ubyte)0xD9, "î"),
    tuple(cast(ubyte)0xDA, "ï"),
    tuple(cast(ubyte)0xDB, "ô"),
    tuple(cast(ubyte)0xDC, "ö"),
    tuple(cast(ubyte)0xDD, "ù"),
    tuple(cast(ubyte)0xDE, "û"),
    tuple(cast(ubyte)0xDF, "ü"),
    tuple(cast(ubyte)0xE0, "á"),
    tuple(cast(ubyte)0xE1, "ì"),
    tuple(cast(ubyte)0xE2, "í"),
    tuple(cast(ubyte)0xE3, "ò"),
    tuple(cast(ubyte)0xE4, "ó"),
    tuple(cast(ubyte)0xE5, "ú"),
    tuple(cast(ubyte)0xE6, "ñ"),
    tuple(cast(ubyte)0xFE, "…"),
    tuple(cast(ubyte)0xFF, "<END>")
];

string formatText(string text) pure {
    char[] result;

    while (!text.empty) {
        if (text.startsWith("\\x") && text.length >= 4) {
            result ~= text[2..4].to!ubyte(16);
            text = text[4..$];
            continue;
        }
        
        ptrdiff_t m = -1;
        FORMATTING.each!((i, ref f) {
            if (!text.startsWith(f.text)) return;
            if (m == -1 || f.text.length > FORMATTING[m].text.length) {
                m = i;
            }
        });
        if (m == -1) {
            result ~= text.decodeFront;
        } else {
            result ~= FORMATTING[m].id;
            text = text[FORMATTING[m].text.length..$];
        }
    }

    return result;
}

string unformatText(string text) pure {
    char[] result;

    text.each!((c) {
        auto f = FORMATTING.find!((ref f) => f.id == c);
        if (f.empty) result ~= c; else result ~= f.front.text;
    });
    
    return result;
}

struct BingoCard {
    string name;
    int bingos;
    int squares;
    Character[] characters;
}

class MarioParty(Config, State, Memory, Player) : Game!(Config, State) {
    alias typeof(Memory.currentScene) Scene;

    Memory* data;
    Player[] players;
    int[Character.max+1] teams;

    this(string name, string hash) {
        super(name, hash);

        data = cast(Memory*)memory.ptr;
    }

    override void loadConfig() {
        super.loadConfig();

        static if (is(typeof(config.teams))) {
            teams.each!((c, ref t) => t = config.teams.require(cast(Character)c, t));
        }
    }

    override void loadState() {
        super.loadState();

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
    bool isBoardScene() const { return isBoardScene(data.currentScene); }
    bool isScoreScene() const { return isScoreScene(data.currentScene); }

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

        static if (is(typeof(config.teamMiniGames)) && is(typeof(data.playerPanels)) && is(typeof(data.determineTeams))) {
            if (config.teamMiniGames) {
                data.determineTeams.addr.onExec({
                    if (!isBoardScene()) return;

                    auto allTeamsSplit = players.all!(p => teammates(p).any!(t =>
                        data.playerPanels[t.index].color != data.playerPanels[p.index].color)
                    );
                    
                    if (!allTeamsSplit) return;
                    
                    players.each!((i, p) {
                        data.playerPanels[i].color = (team(p) == team(players[0]) ? PanelColor.BLUE : PanelColor.RED);
                    });
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

            state.bingoCards = json.fromJSON!Message().cards;
            state.bingoCards.each!((ref card) {
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
                        card.characters ~= CHARS[m];
                        name = name[CHARS[m].to!string.length..$];
                    }
                }
            });
            saveState();
        }
    }

    override void onFrame(ulong frame) {
        super.onFrame(frame);

        if (!isBoardScene(data.currentScene)) return;

        float currentPlayerTurn = data.currentTurn + data.currentPlayerIndex / 4.0f;
        if (currentPlayerTurn <= state.currentPlayerTurn) return;

        state.currentPlayerTurn = currentPlayerTurn;
        saveState();

        if (config.saveStateBeforeEachPlayerTurn) {
            setSaveStateSlot(data.currentPlayerIndex + 1);
            saveGameState();
        }

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
