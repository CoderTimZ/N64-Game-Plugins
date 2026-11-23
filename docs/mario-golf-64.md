# Mario Golf 64

Options in `MarioGolf64.json`, for the US version of Mario Golf. The [configuration page](configuration.md) explains how
the file works. Mario Golf has none of the Mario Party options.

| Option | Type | Default |
|--------|------|---------|
| [`expandMeetArea`](#expandmeetarea) | `true`/`false` | `false` |
| [`improveMaple`](#improvemaple) | `true`/`false` | `false` |
| [`autoSwing`](#autoswing) | `true`/`false` | `false` |
| [`imperfectCPUMeetArea`](#imperfectcpumeetarea) | `true`/`false` | `false` |

The plugin also always shows the shot's power as a percentage during a shot (putts always show 100%), lowered in the
rain, and draws the power bar at the shot's actual power.

The swing options below are about the swing meter's impact point: the spot the meter's last press should hit for a
straight shot. A "step" is one position of the meter's cursor.

### `expandMeetArea`

Makes every club's meet area (the swing meter's sweet spot) closer to the same size.

- Type: `true` or `false`
- Default: `false`

Clubs with a small meet area get a bigger one, and clubs with a big one get a smaller one, halfway towards the same
size, so the differences between clubs (and so between characters) are halved.

### `improveMaple`

Makes Maple's clubs better.

- Type: `true` or `false`
- Default: `false`

Her clubs' distance is 8% higher, and their shot speeds (for power and normal shots) are 12.5% higher.

### `autoSwing`

Hits the impact point automatically when a player doesn't press for it.

- Type: `true` or `false`
- Default: `false`

If the swing meter reaches the end without the impact press, the shot is hit close to the perfect impact point instead:
exactly on it about half the time, and within one step of it about 95% of the time.

### `imperfectCPUMeetArea`

Makes computer players' impact slightly imperfect.

- Type: `true` or `false`
- Default: `false`

Computer players' shots are hit close to the perfect impact point rather than exactly on it: exactly on it about two
thirds of the time, and almost always within one step of it. It takes priority over `autoSwing` for computer players.
