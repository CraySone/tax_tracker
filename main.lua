-- tax_tracker/main.lua - MODULAR VERSION WITH WORKING UI
local api = require("api")
local Debug = require("tax_tracker/debug")

-- Core Systems
local Config = require("tax_tracker/config")
local TimeSystem = require("tax_tracker/timesystem")
local UpdateSystem = require("tax_tracker/updatesystem")
local LoansSystem = require("tax_tracker/loanssystem")
local TaxPayment = require("tax_tracker/taxpayment")

local FarmSystem = {}
do
  local ok, mod = pcall(require, "tax_tracker/farmsystem")
  if ok and mod then
    FarmSystem = mod
  else
    Debug.warn("Main", "FarmSystem failed to load; continuing without farm tracker", {error = tostring(mod)})
  end
end

local MichaelClient = {}
do
  local ok, mod = pcall(require, "tax_tracker/michael_client")
  if ok and mod then
    MichaelClient = mod
  else
    Debug.warn("Main", "MichaelClient failed to load; ESC settings entry disabled", {error = tostring(mod)})
  end
end

-- UI Systems
local HUDManager = require("tax_tracker/ui/hudmanager")
local SavedLandsWindow = require("tax_tracker/ui/savedlandswindow")
local ReminderWindow = require("tax_tracker/reminderwindow")

local addon = {
  name    = "Tax Tracker",
  version = "1.72.34-TRACKER-CLEAR",
  author  = "CraySone",
  desc    = "Land Barons Arise"
}

-- Global state
local listData = {}
local isInitialized = false

-- Initialize all modular components
local function initializeModules()
  -- PREVENT RE-INITIALIZATION: Check if already initialized
  if isInitialized then
    Debug.info("Main", "Systems already initialized - skipping re-initialization")
    return
  end
  
  Debug.info("Main", "Initializing modular components")
  
  -- Initialize systems in dependency order
  local success, err
  
  -- Config first
  success, err = pcall(function() return Config.initialize() end)
  if not success then
    Debug.warn("Main", "Config initialization failed", {error = err})
  end
  
  -- Time system
  success, err = pcall(function() return TimeSystem.initialize() end)
  if not success then
    Debug.warn("Main", "TimeSystem initialization failed", {error = err})
  end
  
  -- Update system
  success, err = pcall(function() return UpdateSystem.initialize() end)
  if not success then
    Debug.warn("Main", "UpdateSystem initialization failed", {error = err})
  end
  
  -- Loans system
  success, err = pcall(function() return LoansSystem.initialize() end)
  if not success then
    Debug.warn("Main", "LoansSystem initialization failed", {error = err})
  end
  
  -- Farm system
  success, err = pcall(function() return FarmSystem.initialize() end)
  if not success then
    Debug.warn("Main", "FarmSystem initialization failed", {error = err})
  end
  
  Debug.info("Main", "Core systems initialized")
end

-- Initialize UI components  
local function initializeUI()
  Debug.info("Main", "Initializing UI components")
  
  local success, err
  
  -- HUD Manager with proper callback
  local function toggleCallback()
    Debug.info("Main", "HUD button clicked - showing saved lands window")
    if SavedLandsWindow and SavedLandsWindow.show then
      SavedLandsWindow.show()
    else
      Debug.error("Main", "SavedLandsWindow.show not available")
    end
  end
  success, err = pcall(function() return HUDManager.initialize(toggleCallback) end)
  if not success then
    Debug.error("Main", "HUDManager initialization failed", {error = err})
    return false
  end
  
  -- Saved Lands Window with data callback
  local function getDataCallback()
    return listData
  end
  success, err = pcall(function() return SavedLandsWindow.initialize(getDataCallback) end)
  if not success then
    Debug.error("Main", "SavedLandsWindow initialization failed", {error = err})
    return false
  end
  
  Debug.info("Main", "UI components initialized successfully")
  return true
end

-- Validate that lands data is structurally sound
local function validateLandsData(lands)
  if type(lands) ~= "table" then return false, "not a table" end

  for i, land in ipairs(lands) do
    if type(land) ~= "table" then
      return false, "land " .. i .. " is not a table"
    end
    -- A land should at minimum have an id or name
    if not land.id and not land.name then
      return false, "land " .. i .. " missing both id and name"
    end
  end

  return true
end

-- Load and validate land data with comprehensive recovery
local function loadData()
  Debug.info("Main", "Loading addon data")

  local settings = api.GetSettings("tax_tracker") or {}
  local rawLands = settings.lands or {}

  -- GUARD: Validate the loaded data structure
  local isValid, err = validateLandsData(rawLands)
  if not isValid then
    Debug.error("Main", "Saved data is corrupt - attempting recovery", {error = err})
    -- Try the snapshot backup we wrote on previous save
    if settings.landsBackup and validateLandsData(settings.landsBackup) then
      Debug.warn("Main", "Recovering from in-settings snapshot backup")
      rawLands = settings.landsBackup
    else
      Debug.error("Main", "No valid backup found - starting with empty data")
      rawLands = {}
    end
  end

  listData = rawLands

  -- SMART DATA RECOVERY: Only inject default backup if settings are truly empty (first run)
  if #listData == 0 then
    local isFirstTime = not settings.lands and not settings.hasBeenInitialized

    if isFirstTime then
      Debug.info("Main", "First-time setup - loading default lands from BACKUP_LANDS.lua")
      local backupSuccess, backupData = pcall(require, "tax_tracker/BACKUP_LANDS")
      if backupSuccess and backupData and backupData.lands and #backupData.lands > 0 then
        listData = backupData.lands
        settings.lands = listData
        settings.hasBeenInitialized = true
        pcall(function() api.SaveSettings() end)
        Debug.info("Main", "Default lands loaded for first-time setup", {count = #listData})
      end
    else
      Debug.info("Main", "Not first-time - user may have cleared their lands intentionally")
    end
  end

  -- Validate and process data through TimeSystem
  if TimeSystem and TimeSystem.validateLandData then
    for i, land in ipairs(listData) do
      TimeSystem.validateLandData(land)
    end
  end

  Debug.info("Main", "Data load completed", {landCount = #listData})
  return true
end

-- Save data with validation and snapshot backup
local function saveData()
  -- GUARD: Don't save corrupt data
  local isValid, err = validateLandsData(listData)
  if not isValid then
    Debug.error("Main", "Refusing to save invalid data", {error = err})
    return false
  end

  local settings = api.GetSettings("tax_tracker") or {}

  -- BACKUP: Keep snapshot of previous good save in case current save corrupts somehow
  if settings.lands and #settings.lands > 0 then
    local prevValid = validateLandsData(settings.lands)
    if prevValid then
      settings.landsBackup = settings.lands
    end
  end

  settings.lands = listData

  local success = pcall(function()
    api.SaveSettings()
  end)

  if success then
    Debug.info("Main", "Data saved successfully", {landCount = #listData})
  else
    Debug.error("Main", "Failed to save data")
  end

  return success
end


-- Wipe leftover widgets from a previous load. Was buggy: pcall returns
-- (success, result) but we only captured success, so cleanup ran every load
-- whether or not a stale HUD existed.
local function emergencyCleanup()
  local found, hud = pcall(function()
    return api.Interface:FindWidget("TaxTrackerHUDRoot")
  end)
  if not (found and hud) then return end

  Debug.info("Main", "Stale widgets detected - cleaning up")
  for _, name in ipairs({"TaxTrackerHUDRoot", "TaxTrackerList"}) do
    local ok, widget = pcall(api.Interface.FindWidget, api.Interface, name)
    if ok and widget and widget.Destroy then
      pcall(function() widget:Destroy() end)
    end
  end
end

local function Load()
  -- Initialize debug system first
  Debug.init()
  Debug.info("Main", "=== TAX TRACKER MODULAR VERSION LOADING ===")
  Debug.info("Main", "Version: " .. addon.version)
  
  -- EMERGENCY: Clean up any broken state from previous loads
  emergencyCleanup()
  
  -- Initialize all systems
  initializeModules()

  -- ESC menu addon settings entry, matching the Idol addon pattern
  local settingsMenuSuccess, settingsMenuErr = pcall(function()
    MichaelClient.initializeMichaelClient()
    local configMenu = ADDON:GetContent(UIC.SYSTEM_CONFIG_FRAME)
    if configMenu and configMenu.michaelClient and configMenu.michaelClient.AddAddon then
      configMenu.michaelClient:AddAddon("TaxTracker", function()
        if FarmSystem and FarmSystem.openSettingsWindow then
          local ok, err = pcall(function()
            FarmSystem.openSettingsWindow()
          end)
          if not ok then
            Debug.warn("Main", "Farm settings window failed to open", {error = tostring(err)})
          end
        end
      end)
    end
  end)
  if not settingsMenuSuccess then
    Debug.warn("Main", "ESC settings menu registration failed", {error = tostring(settingsMenuErr)})
  end
  
  -- Load data
  loadData()

  -- TAX PAYMENT AUTO-DETECTION: Listen for REMOVED_ITEM events (needs listData loaded)
  local taxPaySuccess, taxPayErr = pcall(function() return TaxPayment.initialize(listData) end)
  if not taxPaySuccess then
    Debug.warn("Main", "TaxPayment initialization failed", {error = tostring(taxPayErr)})
  else
    Debug.info("Main", "Tax payment auto-detection enabled")
  end

  -- Initialize UI
  local uiSuccess = initializeUI()
  if not uiSuccess then
    Debug.error("Main", "UI initialization failed - addon may not work correctly")
  end


  -- CONTROLLED UPDATE SYSTEM: Re-enabled with performance controls
  if UpdateSystem and UpdateSystem.startUpdates then
    UpdateSystem.startUpdates(listData, saveData)
    Debug.info("Main", "Update system enabled with performance controls")
  else
    Debug.warn("Main", "Update system not available")
  end

  -- FARM SYSTEM: Pass land data for position-based detection
  if FarmSystem and FarmSystem.updateLandDetectionData then
    FarmSystem.updateLandDetectionData(listData)
    Debug.info("Main", "Farm system updated with land data for detection")
  end
  
  -- REMINDER WINDOW: Initialize for login and exit reminders
  ReminderWindow.initForLogin()
  ReminderWindow.initForExit()
  
  isInitialized = true
  Debug.info("Main", "Tax Tracker modular version loaded successfully")
  Debug.info("Main", "=== LOADING COMPLETE ===")
end

-- Unload function
local function Unload()
  if not isInitialized then return end
  
  Debug.info("Main", "=== TAX TRACKER UNLOADING ===")
  
  -- Save data before shutdown
  saveData()
  
  -- Cleanup systems in reverse order
  if UpdateSystem and UpdateSystem.stopUpdates then
    UpdateSystem.stopUpdates()
  end
  
  if SavedLandsWindow and SavedLandsWindow.cleanup then
    SavedLandsWindow.cleanup()
  end
  
  if HUDManager and HUDManager.cleanup then
    HUDManager.cleanup()
  end

  if ReminderWindow and ReminderWindow.cleanup then
    ReminderWindow.cleanup()
  end

  if TaxPayment and TaxPayment.cleanup then
    TaxPayment.cleanup()
  end

  if FarmSystem and FarmSystem.cleanup then
    FarmSystem.cleanup()
  end

  if MichaelClient and MichaelClient.OnUnload then
    MichaelClient.OnUnload()
  end
  
  if LoansSystem and LoansSystem.cleanup then
    LoansSystem.cleanup()
  end
  
  if TimeSystem and TimeSystem.cleanup then
    TimeSystem.cleanup()
  end
  
  -- Clear global state
  listData = {}
  isInitialized = false
  
  Debug.info("Main", "Tax Tracker unloaded successfully")
  Debug.cleanup()
end

-- Export global access functions for compatibility
function addon.getData()
  return listData
end

function addon.saveData()
  return saveData()
end

function addon.refreshData()
  if SavedLandsWindow and SavedLandsWindow.refreshData then
    SavedLandsWindow.refreshData()
  end
end

-- RECOVERY FUNCTION: Force recovery from backup data
function addon.forceRecoveryFromBackup()
  Debug.info("Main", "Forcing recovery from backup data")
  
  -- Load backup data directly
  local backupSuccess, backupData = pcall(require, "tax_tracker/BACKUP_LANDS")
  if not backupSuccess then
    Debug.error("Main", "Failed to load BACKUP_LANDS.lua", {error = backupData})
    api.Log:Info("[Tax Tracker] ERROR: Could not load backup file")
    return false
  end
  
  if not backupData or not backupData.lands or #backupData.lands == 0 then
    Debug.error("Main", "Invalid backup data structure")
    api.Log:Info("[Tax Tracker] ERROR: Backup data is invalid")
    return false
  end
  
  Debug.info("Main", "Backup data loaded successfully", {landCount = #backupData.lands})
  
  -- Force set the data
  listData = backupData.lands
  
  -- Save to settings with multiple keys for recovery
  local settings = api.GetSettings("tax_tracker") or {}
  settings.lands = listData
  settings.landData = listData
  settings.listData = listData
  settings.savedLands = listData
  settings.emergency_backup_1 = listData
  
  local success = pcall(function() 
    api.SaveSettings() 
  end)
  
  if success then
    Debug.info("Main", "Backup data restored and saved", {landCount = #listData})
    api.Log:Info("[Tax Tracker] SUCCESS: Recovered " .. #listData .. " lands from backup!")
    
    -- Refresh the UI
    if SavedLandsWindow and SavedLandsWindow.refreshData then
      SavedLandsWindow.refreshData()
    end
    
    return true
  else
    Debug.error("Main", "Failed to save recovered data")
    api.Log:Info("[Tax Tracker] ERROR: Could not save recovered data")
    return false
  end
end

-- RECOVERY FUNCTION: Add sample data to test if system is working
function addon.createSampleData()
  Debug.info("Main", "Creating sample land data for testing")
  
  -- Create a sample land entry
  local sampleLand = {
    id = 1,
    name = "Test Farm",
    landType = "Scarecrow Farm (16x16)",
    zoneName = "Test Zone",
    nextPayment = TimeSystem.createCountdownTimer(7), -- 7 days from now
    coords = {
      lon = { dir = "E", deg = 1, min = 30, sec = 45 },
      lat = { dir = "N", deg = 2, min = 15, sec = 30 }
    }
  }
  
  listData = { sampleLand }
  
  -- Save the sample data
  local success = saveData()
  if success then
    Debug.info("Main", "Sample data created and saved", {landCount = #listData})
    api.Log:Info("[Tax Tracker] Sample data created - you should now see 1 test land")
    
    -- Refresh the UI
    if SavedLandsWindow and SavedLandsWindow.refreshData then
      SavedLandsWindow.refreshData()
    end
    
    return true
  else
    Debug.error("Main", "Failed to save sample data")
    return false
  end
end

addon.OnLoad = Load
addon.OnUnload = Unload
addon.OnSettingToggle = function()
  if FarmSystem and FarmSystem.openSettingsWindow then
    local ok, err = pcall(function()
      FarmSystem.openSettingsWindow()
    end)
    if not ok then
      Debug.warn("Main", "Farm settings window failed to open from slash command", {error = tostring(err)})
    end
  end
end

return addon
