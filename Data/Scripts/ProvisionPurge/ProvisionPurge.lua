ProvisionPurge = ProvisionPurge or {}

-- 🛠 Default config (fallbacks)
ProvisionPurge.config = {
    rottenThresholdFood = 0.50,
    rottenThresholdHerb = 0.40,
    debugLogs           = true,
    enableSleepCleanup  = true,
    showMessages        = true,

    -- NEW: avoid purge on SkipTime cancel or micro-naps
    requireRealSleep    = true, -- gate purge on actual rest gain
    minExhaustGain      = 3, -- how much rest must be gained to count
}

-- -----------------------------
-- Runtime state
-- -----------------------------
-- Track sleep start (exhaust at fader start)
ProvisionPurge._sleepSession = { startExhaust = nil }

-- Debounce duplicate OnHide
ProvisionPurge._wakeGuard = { lastRunMs = 0, cooldownMs = 1200 }

-- Ensure SkipTime listener only registered once
ProvisionPurge._skipListenerRegistered = false

-- -----------------------------
-- Utils
-- -----------------------------
local function nowMillis()
    -- Best-effort monotonic-ish
    if System.GetCurrTime then
        -- seconds → ms
        local ok, t = pcall(System.GetCurrTime)
        if ok and type(t) == "number" then return math.floor(t * 1000) end
    end
    if System.GetFrameID then
        local ok, f = pcall(System.GetFrameID)
        if ok and type(f) == "number" then return f * 16 end
    end
    return 0
end

local function shouldRunOnce()
    local t = nowMillis()
    if (t - ProvisionPurge._wakeGuard.lastRunMs) < ProvisionPurge._wakeGuard.cooldownMs then
        return false
    end
    ProvisionPurge._wakeGuard.lastRunMs = t
    return true
end

-- Exhaust getter (STATE, not STAT)
local function getExhaust(player)
    local soul = player and player.soul
    if soul and soul.GetState then
        local ok, val = pcall(function() return soul:GetState("exhaust") end)
        if ok and type(val) == "number" then return val end
    end
    return nil
end

-- Logging utilities
function ProvisionPurge.Log(msg)
    if ProvisionPurge.config and ProvisionPurge.config.debugLogs then
        System.LogAlways("[ProvisionPurge] " .. tostring(msg))
    end
end

function ProvisionPurge.Info(msg)
    System.LogAlways("[ProvisionPurge] " .. tostring(msg))
end

local Log  = ProvisionPurge.Log
local Info = ProvisionPurge.Info

-- Player getter
function ProvisionPurge.GetPlayer()
    return System.GetEntityByName("Henry") or System.GetEntityByName("dude")
end

-- Dump config
function ProvisionPurge.DumpConfig()
    ProvisionPurge.Info("Active ProvisionPurge config:")
    for k, v in pairs(ProvisionPurge.config) do
        ProvisionPurge.Info(string.format("  %s = %s", k, tostring(v)))
    end
end

-- -----------------------------
-- Load config override (safe)
-- -----------------------------
local ok, err = pcall(function()
    Script.ReloadScript("Scripts/ProvisionPurge/ProvisionPurgeConfig.lua")
end)

if not ok then
    Info("⚠ Failed to load ProvisionPurgeConfig.lua: " .. tostring(err))
elseif ProvisionPurge_Config then
    for k, v in pairs(ProvisionPurge_Config) do
        ProvisionPurge.config[k] = v
    end
    Info("Loaded config from ProvisionPurgeConfig.lua")
else
    Info("⚠ ProvisionPurgeConfig.lua loaded but no ProvisionPurge_Config table found")
end

-- Lookup tables
Script.ReloadScript("Scripts/ProvisionPurge/FoodLookup.lua")
Script.ReloadScript("Scripts/ProvisionPurge/HerbLookup.lua")

-- -----------------------------
-- Lifecycle hooks
-- -----------------------------
function ProvisionPurge.OnGameplayStarted(actionName, eventName, argTable)
    Info("OnGameplayStarted fired")
    ProvisionPurge.DumpConfig()
    ProvisionPurge.Initialize(true)
end

function ProvisionPurge.OnSetFaderState(actionName, eventName, argTable)
    Info("OnSetFaderState fired → ensuring watcher is running")
    ProvisionPurge.Initialize(false)
end

-- -----------------------------
-- SkipTime / Sleep hook
-- -----------------------------
function ProvisionPurge:onSkipTimeEvent(elementName, instanceId, eventName, argTable)
    if not ProvisionPurge.config.enableSleepCleanup then return end
    local player = ProvisionPurge.GetPlayer()

    if eventName == "OnSetFaderState" and argTable and argTable[1] == "sleep" then
        Log("Sleep session starting...")
        if ProvisionPurge.config.requireRealSleep then
            ProvisionPurge._sleepSession.startExhaust = getExhaust(player)
            Log("Captured start exhaust: " .. tostring(ProvisionPurge._sleepSession.startExhaust))
        end
        return
    end

    if eventName == "OnHide" then
        -- Debounce double close
        if not shouldRunOnce() then
            Log("Skip duplicate wake trigger (debounced)")
            return
        end

        local okToRun = true
        if ProvisionPurge.config.requireRealSleep then
            local startExh = ProvisionPurge._sleepSession.startExhaust
            local endExh   = getExhaust(player)

            local gain     = 0
            if type(startExh) == "number" and type(endExh) == "number" then
                gain = endExh - startExh
                if gain < 0 then gain = 0 end -- clamp negative blips after wake
            else
                -- If we never captured start, be conservative
                okToRun = false
            end

            if okToRun then
                okToRun = gain >= (ProvisionPurge.config.minExhaustGain or 3)
            end

            Log(string.format("Sleep gain check: start=%s end=%s Δ=%.1f → %s",
                tostring(startExh), tostring(endExh), gain, okToRun and "ALLOW" or "BLOCK"))
        end

        -- Always reset session
        ProvisionPurge._sleepSession.startExhaust = nil

        if not okToRun then
            Log("Sleep canceled or too short → skipping purge")
            return
        end

        Log("Woke up from sleep → cleaning spoiled provisions")
        -- Let inventory settle a moment after SkipTime closes
        Script.SetTimer(500, function() ProvisionPurge.ScanInventory() end)
    end
end

-- -----------------------------
-- Init (register SkipTime listener once)
-- -----------------------------
function ProvisionPurge.Initialize(fullInit)
    if fullInit and ProvisionPurge._initialized then
        Info("Already initialized, skipping")
        return
    end
    if fullInit then ProvisionPurge._initialized = true end

    if ProvisionPurge.config.enableSleepCleanup and not ProvisionPurge._skipListenerRegistered then
        if UIAction and UIAction.RegisterElementListener then
            UIAction.RegisterElementListener(ProvisionPurge, "SkipTime", -1, "", "onSkipTimeEvent")
            ProvisionPurge._skipListenerRegistered = true
            Log("Registered SkipTime listener for sleep/wake cleanup")
        else
            Log("UIAction not available for SkipTime registration")
        end
    end
end

-- -----------------------------
-- Inventory scan
-- -----------------------------
function ProvisionPurge.ScanInventory()
    local player = ProvisionPurge.GetPlayer()
    if not player or not player.inventory then
        Log("No player or inventory found")
        return
    end

    local invTable = player.inventory:GetInventoryTable()
    if not invTable then
        Log("Inventory table empty")
        return
    end

    local removedFood, removedHerbs, removedCount = 0, 0, 0
    Log("Scanning inventory...")

    for _, userdata in pairs(invTable) do
        local item = ItemManager.GetItem(userdata)
        if item then
            local class  = tostring(item.class)
            local name   = ItemManager.GetItemName(item.class) or "unknown"
            local health = item.health or 1
            local amount = item.amount or 1

            local isFood = ProvisionPurge.FoodLookup[class] ~= nil
            local isHerb = ProvisionPurge.HerbLookup[class] ~= nil

            if isFood or isHerb then
                local threshold = isFood and ProvisionPurge.config.rottenThresholdFood
                    or ProvisionPurge.config.rottenThresholdHerb

                if health <= threshold then
                    local label = ProvisionPurge.FoodLookup[class] or ProvisionPurge.HerbLookup[class] or name
                    Info("Removed provision: " .. label .. " x" .. tostring(amount))

                    player.inventory:DeleteItemOfClass(class, amount)
                    removedCount = removedCount + amount

                    -- track by type
                    if isFood then removedFood = removedFood + amount end
                    if isHerb then removedHerbs = removedHerbs + amount end
                end
            end
        end
    end

    if removedCount > 0 then
        Info("Removed " .. removedCount .. " spoiled provisions in total.")

        if ProvisionPurge.config.showMessages then
            local pool = {}
            if removedFood > 0 and removedHerbs == 0 then
                pool = { "@ui_purged_food_1", "@ui_purged_food_2", "@ui_purged_food_3", "@ui_purged_food_4",
                    "@ui_purged_food_5" }
            elseif removedHerbs > 0 and removedFood == 0 then
                pool = { "@ui_purged_herbs_1", "@ui_purged_herbs_2", "@ui_purged_herbs_3", "@ui_purged_herbs_4",
                    "@ui_purged_herbs_5" }
            else
                pool = { "@ui_purged_both_1", "@ui_purged_both_2", "@ui_purged_both_3", "@ui_purged_both_4",
                    "@ui_purged_both_5" }
            end

            local message = pool[math.random(#pool)]

            -- Delay by 6 seconds before showing
            Script.SetTimer(6000, function()
                Game.SendInfoText(message, false, nil, 5)
            end)
        end
    else
        Info("No spoiled provisions found.")
    end
end

-- -----------------------------
-- System listeners (kept from your original)
-- -----------------------------
UIAction.RegisterEventSystemListener(ProvisionPurge, "System", "OnGameplayStarted", "OnGameplayStarted")
UIAction.RegisterEventSystemListener(ProvisionPurge, "System", "OnSetFaderState", "OnSetFaderState")
