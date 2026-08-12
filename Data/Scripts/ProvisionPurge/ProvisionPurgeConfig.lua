-- #####################################
-- Provision Purge Configuration
-- #####################################

-- Users: edit the numbers below to adjust behavior.
-- Freshness values are 0.0 = fully rotten, 1.0 = perfectly fresh.

ProvisionPurge_Config = {
    rottenThresholdFood = 0.40, -- delete food if freshness <= 40%
    rottenThresholdHerb = 0.30, -- delete herbs if freshness <= 30%
    debugLogs = false,          -- show detailed log output
    enableSleepCleanup = true,  -- run cleanup after waking up
    showMessages = true,
    requireRealSleep = true,    -- avoid purge on cancel
    minExhaustGain = 3          -- how much rest must be gained to count
}
