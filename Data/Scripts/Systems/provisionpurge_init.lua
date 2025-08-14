-- Ensure global table exists
ProvisionPurge = ProvisionPurge or {}

-- Bootstrap: load the main logic
Script.ReloadScript("Scripts/ProvisionPurge/ProvisionPurge.lua")

-- Register lifecycle event
UIAction.RegisterEventSystemListener(ProvisionPurge, "System", "OnGameplayStarted", "OnGameplayStarted")
System.LogAlways("[Rotten To The Core]: Event listener registered")
