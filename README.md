# Provision Purge

Provision Purge removes spoiled food and herbs from Henry's inventory after sleeping.

## Requirements

- Kingdom Come: Deliverance II
- KCD2-LuaUtils

Version 1.2 uses the LuaUtils SKALD API for sleep/wait detection. Without LuaUtils, automatic cleanup after sleeping will not run.

## What It Does

- Checks Henry's inventory after real sleep.
- Removes food at or below the configured freshness threshold.
- Removes herbs at or below the configured freshness threshold.
- Shows an in-game message when spoiled provisions were removed.
- Skips cleanup if sleep was canceled or too short.

## Version 1.2

This release replaces the old SkipTime UI listener with LuaUtils SKALD triggers.

The previous listener could slow down long waits or sleeps. With LuaUtils, sleep/wait performance should remain unaffected while Provision Purge still runs after real sleep.

## Configuration

Settings can be edited in:

`Data/Scripts/ProvisionPurge/ProvisionPurgeConfig.lua`

Default settings:

```lua
ProvisionPurge_Config = {
    rottenThresholdFood = 0.40,
    rottenThresholdHerb = 0.30,
    debugLogs = false,
    enableSleepCleanup = true,
    showMessages = true,
    requireRealSleep = true,
    minExhaustGain = 3
}
```

Freshness values use `0.0` as fully rotten and `1.0` as perfectly fresh.

## Notes

- LuaUtils is required for automatic sleep cleanup in version 1.2.
- The mod is quiet by default unless provisions are actually removed.
- Enable `debugLogs` only when troubleshooting.
