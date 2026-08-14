ProvisionPurge = ProvisionPurge or {}

-- Default config (fallbacks)
ProvisionPurge.config = {
    rottenThresholdFood = 0.40,
    rottenThresholdHerb = 0.30,
    debugLogs           = false,
    enableSleepCleanup  = true,
    showMessages        = true,

    -- Avoid purge on SkipTime cancel or very short rests.
    requireRealSleep    = true,
    minExhaustGain      = 3,
}

-- -----------------------------
-- Runtime state
-- -----------------------------
-- Track sleep start (exhaust at fader start)
ProvisionPurge._sleepSession = { startExhaust = nil }

-- Debounce duplicate OnHide
ProvisionPurge._wakeGuard = { lastRunMs = 0, cooldownMs = 1200 }

ProvisionPurge._skaldSkipTimeHook = {
    registered = false,
    node = nil,
    startConn = nil,
    stopConn = nil,
}

-- -----------------------------
-- Utils
-- -----------------------------
local function nowMillis()
    -- Best-effort monotonic-ish
    if System.GetCurrTime then
        -- seconds to ms
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
    Info("Failed to load ProvisionPurgeConfig.lua: " .. tostring(err))
elseif ProvisionPurge_Config then
    for k, v in pairs(ProvisionPurge_Config) do
        ProvisionPurge.config[k] = v
    end
    Log("Loaded config from ProvisionPurgeConfig.lua")
else
    Info("ProvisionPurgeConfig.lua loaded but no ProvisionPurge_Config table found")
end

-- Lookup tables
Script.ReloadScript("Scripts/ProvisionPurge/FoodLookup.lua")
Script.ReloadScript("Scripts/ProvisionPurge/HerbLookup.lua")

-- -----------------------------
-- Lifecycle hooks
-- -----------------------------
function ProvisionPurge.OnGameplayStarted(actionName, eventName, argTable)
    Log("OnGameplayStarted fired")
    if ProvisionPurge.config.debugLogs then
        ProvisionPurge.DumpConfig()
    end
    ProvisionPurge.Initialize(true)
end

-- -----------------------------
-- Sleep hook
-- -----------------------------
function ProvisionPurge:HandleSleepStart()
    if not ProvisionPurge.config.enableSleepCleanup then
        return
    end

    Log("Sleep session starting...")

    if ProvisionPurge.config.requireRealSleep then
        local player = ProvisionPurge.GetPlayer()
        ProvisionPurge._sleepSession.startExhaust = getExhaust(player)

        Log(
            "Captured start exhaust: "
                .. tostring(ProvisionPurge._sleepSession.startExhaust)
        )
    end
end

function ProvisionPurge:HandleSleepEnd()
    if not ProvisionPurge.config.enableSleepCleanup then
        return
    end

    -- Debounce double close
    if not shouldRunOnce() then
        Log("Skip duplicate wake trigger (debounced)")
        return
    end

    local player = ProvisionPurge.GetPlayer()

    local okToRun = true

    if ProvisionPurge.config.requireRealSleep then
        local startExh = ProvisionPurge._sleepSession.startExhaust
        local endExh = getExhaust(player)

        local gain = 0

        if type(startExh) == "number" and type(endExh) == "number" then
            gain = startExh - endExh

            if gain < 0 then
                gain = 0
            end
        else
            -- If we never captured start, be conservative
            okToRun = false
        end

        if okToRun then
            okToRun = gain >= (ProvisionPurge.config.minExhaustGain or 3)
        end

        Log(
            string.format(
                "Sleep gain check: start=%s end=%s delta=%.1f -> %s",
                tostring(startExh),
                tostring(endExh),
                gain,
                okToRun and "ALLOW" or "BLOCK"
            )
        )
    end

    -- Always reset session
    ProvisionPurge._sleepSession.startExhaust = nil

    if not okToRun then
        Log("Sleep canceled or too short -> skipping purge")
        return
    end

    Log("Woke up from sleep -> cleaning spoiled provisions")

    -- Let inventory settle a moment after SkipTime closes
    Script.SetTimer(500, function()
        ProvisionPurge.ScanInventory()
    end)
end

function ProvisionPurge.InitializeSkaldSkipTimeHook()
    local hook = ProvisionPurge._skaldSkipTimeHook
    if hook.registered then
        return true
    end

    if not wh then
        Log("LuaUtils SKALD wrappers are not available")
        return false
    end

    local triggerClass = nil
    local createArgs = { IsActive = true }
    local startOutput = "OnStarted"
    local stopOutput = "OnStopped"
    local triggerLabel = "playermodule.SkipTimeTrigger"

    if wh.entitymodule and wh.entitymodule.ActorSkipTimeTrigger then
        local soul = nil
        if wh.globals then
            local okSoul, value = pcall(function() return wh.globals.soul end)
            if okSoul then
                soul = value
            end
        end

        if soul then
            triggerClass = wh.entitymodule.ActorSkipTimeTrigger
            createArgs = { IsActive = true, Soul = soul }
            startOutput = "SkipTimeStarted"
            stopOutput = "SkipTimeEnded"
            triggerLabel = "entitymodule.ActorSkipTimeTrigger"
        else
            Log("LuaUtils SKALD ActorSkipTimeTrigger is available, but player soul is not")
        end
    end

    if not triggerClass and wh.playermodule and wh.playermodule.SkipTimeTrigger then
        triggerClass = wh.playermodule.SkipTimeTrigger
    end

    if not triggerClass then
        Log("LuaUtils SKALD SkipTime trigger is not available")
        return false
    end

    if type(triggerClass.Create) ~= "function" then
        Log("LuaUtils SKALD " .. triggerLabel .. ".Create is not available")
        return false
    end

    local node, err = triggerClass.Create(createArgs)
    if not node then
        Log("Failed to create SKALD " .. triggerLabel .. ": " .. tostring(err))
        return false
    end

    local startConn, startErr = node:BindOutput(startOutput, function()
        Log("SKALD SkipTime started")
        ProvisionPurge:HandleSleepStart()
    end)

    if not startConn then
        Log("Failed to bind SKALD SkipTime start output: " .. tostring(startErr))
        node:Destroy()
        return false
    end

    local stopConn, stopErr = node:BindOutput(stopOutput, function()
        Log("SKALD SkipTime stopped")
        Script.SetTimer(250, function()
            ProvisionPurge:HandleSleepEnd()
        end)
    end)

    if not stopConn then
        Log("Failed to bind SKALD SkipTime stop output: " .. tostring(stopErr))
        startConn:Disconnect()
        node:Destroy()
        return false
    end

    local ok, activateErr = node:Activate()
    if not ok then
        Log("Failed to activate SKALD SkipTimeTrigger: " .. tostring(activateErr))
        stopConn:Disconnect()
        startConn:Disconnect()
        node:Destroy()
        return false
    end

    hook.registered = true
    hook.node = node
    hook.startConn = startConn
    hook.stopConn = stopConn
    Log("Registered SKALD " .. triggerLabel .. " for sleep/wake cleanup")
    return true
end

-- -----------------------------
-- Init
-- -----------------------------
function ProvisionPurge.Initialize(fullInit)
    if fullInit and ProvisionPurge._initialized then
        Log("Already initialized, skipping")
        return
    end
    if fullInit then ProvisionPurge._initialized = true end

    if not ProvisionPurge.config.enableSleepCleanup then
        Log("Sleep cleanup disabled by config")
        return
    end

    ProvisionPurge.InitializeSkaldSkipTimeHook()
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
        Log("No spoiled provisions found.")
    end
end

