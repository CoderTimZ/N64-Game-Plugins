module me.timz.n64.marioparty;

import me.timz.n64.plugin;
import std.algorithm;
import std.random;
import std.range;
import std.json;
import std.traits;
import std.stdio;
import std.conv;

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

string formatText(string text) pure {
    return text.replace("<NUL>",    "\x00")
               .replace("<BLACK>",  "\x01")
               .replace("<BLUE>",   "\x02")
               .replace("<RED>",    "\x03")
               .replace("<PINK>",   "\x04")
               .replace("<GREEN>",  "\x05")
               .replace("<CYAN>",   "\x06")
               .replace("<YELLOW>", "\x07")
               .replace("<BOLD>",   "\x0F")
               .replace("<1>",      "\x11")
               .replace("<2>",      "\x12")
               .replace("<3>",      "\x13")
               .replace("<NORMAL>", "\x16")
               .replace("<RESET>",  "\x19")
               .replace("-",        "\x3D")
               .replace("×",        "\x3E")
               .replace("'",        "\x5C")
               .replace("/",        "\x5F")
               .replace(":",        "\x7B")
               .replace(",",        "\x82")
               .replace(".",        "\x85")
               .replace("!",        "\xC2")
               .replace("?",        "\xC3")
               .replace("<END>",    "\xFF");
}

string unformatText(string text) pure {
    return text.replace("\x3D", "-")
               .replace("\x3E", "×")
               .replace("\x5C", "'")
               .replace("\x5F", "/")
               .replace("\x7B", ":")
               .replace("\x82", ",")
               .replace("\x85", ".")
               .replace("\xC2", "!")
               .replace("\xC3", "?");
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

    override void onFrame(ulong frame) {
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
