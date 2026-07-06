# DungeonFarmer

`DungeonFarmer` is a small WoW Retail addon that tracks your dungeon lockout activity across a rolling hour.

It adds a color-coded `n/10` count to the minimap difficulty tooltip, keeps a retained cross-character log, and can optionally mirror the same information on Titan Panel.

## Features

- Tracks dungeon runs account-wide through a SavedVariables log
- Keeps one log row per run and updates that row while you move in and out of the same unreset instance
- Starts a new row when a reset is detected
- Shows a color-coded `n/10` lockout count
- Shows the remaining time until the next lockout falls off
- Prints status to chat with `/df` or `/dungeonfarmer`
- Prints the retained run log with `/dflog`
- Adds optional Titan Panel support with the same count and countdown tooltip

## Commands

- `/df`
  Prints the current lockout count and next falloff timer.
- `/dungeonfarmer`
  Same as `/df`.
- `/df log`
  Prints the retained run log.
- `/dflog`
  Same as `/df log`.

## Installation

Copy the `DungeonFarmer` folder into:

`World of Warcraft\_retail_\Interface\AddOns\`

## How Tracking Works

- Each stored run records entry time, latest exit time, realm, character, instance name, instance ID, and reset sequence.
- Re-entering the same unreset dungeon updates the same stored run instead of creating a duplicate row.
- Reloading or logging in inside a dungeon resumes an already-open row. If the latest matching row is already closed, the addon creates a new row.
- Active lockout timing uses `exitTime + 60 minutes` when an exit is known.
- If a run is still open and has no exit time yet, the addon falls back to `entryTime + 60 minutes`.
- Retained log rows stay for 90 minutes based on the most recent activity on that run so recent debugging data remains visible after the active lockout has fallen off.

## Titan Panel

If Titan Panel is installed and enabled, DungeonFarmer adds a plugin that shows:

- a colored `n/10` counter
- the same countdown tooltip
- live tooltip refresh while the tooltip is open
- left-click log printing through the normal addon log output

## Configuration

The main tuning values live at the top of [DungeonFarmer.lua](./DungeonFarmer.lua):

- `MAX_DUNGEONS_PER_HOUR`
- `GREEN_COLOR_COUNT_THRESHOLD`
- `ORANGE_COLOR_COUNT_THRESHOLD`
- `RED_COLOR_COUNT_THRESHOLD`

## Notes And Limitations

- This addon is written for WoW Retail.
- The minimap tooltip hook currently matches the default English difficulty tooltip text.
- Reset detection currently relies on the `ResetInstances()` API hook plus reset-related UI/system messages. Non-standard reset flows may still need additional tuning.
- Titan support is optional and only activates when Titan Panel is available.

## License

MIT. See [LICENSE](./LICENSE).
