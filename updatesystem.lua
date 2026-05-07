-- tax_tracker/update_system.lua - REAL-TIME UPDATE SYSTEM
-- Based on decompiled/addons.lua EventHandler and api.lua timer system

local api = require("api")
-- Use Debug safely to avoid circular dependencies
local Debug = nil
pcall(function() Debug = require("tax_tracker/debug") end)
if not Debug then
  Debug = { info = function() end, warn = function() end, error = function() end, debug = function() end, trace = function() end }
end

local UpdateSystem = {}

-- Update state
local updateCallbacks = {}
local isRunning = false
local updateInterval = 1000 -- FORCE 1 second updates for real-time countdowns
local updateCount = 0 -- Track update cycles
local onUpdateEvent = nil -- Store reference for cleanup

-- REWRITTEN: Direct UPDATE event like timers addon (no interval filtering)
function UpdateSystem.init()
  if isRunning then
    return
  end
  
  isRunning = true
  
  -- Direct UPDATE event handler like the working timers addon
  onUpdateEvent = function(dt)
    if not isRunning then
      return
    end
    
    updateCount = updateCount + 1
    
    -- Execute all registered update callbacks every frame like timers addon
    for callbackName, callback in pairs(updateCallbacks) do
      local success, error = pcall(callback, dt) -- Pass dt like timers addon
      if not success then
        Debug.error("UpdateSystem", "Callback failed", {
          callbackName = callbackName,
          error = error,
          updateCount = updateCount
        })
        api.Log:Err(string.format("[Tax Tracker] Update callback '%s' failed: %s", callbackName, error))
      end
    end
  end
  
  -- Register for the UPDATE event directly like timers addon
  api.On("UPDATE", onUpdateEvent)

  Debug.info("UpdateSystem", "UPDATE event system started")
end

-- Stop the update system
function UpdateSystem.stop()
  isRunning = false
  updateCallbacks = {}
end

-- Cleanup function to properly remove event handlers (CRITICAL FOR RELOAD CRASH FIX)
function UpdateSystem.cleanup()
  Debug.info("UpdateSystem", "Starting UpdateSystem cleanup")
  
  -- Stop the update system first
  isRunning = false
  
  -- Remove UPDATE event handler if it exists
  if onUpdateEvent and api.Off then
    api.Off("UPDATE", onUpdateEvent)
    onUpdateEvent = nil
    Debug.info("UpdateSystem", "UPDATE event handler removed")
  end
  
  -- Clear all callbacks
  updateCallbacks = {}
  updateCount = 0

  Debug.info("UpdateSystem", "UpdateSystem cleanup completed")
end

-- Register a callback for real-time updates
function UpdateSystem.registerCallback(name, callback)
  if type(callback) ~= "function" then
    Debug.error("UpdateSystem", "Invalid callback", {name = name, type = type(callback)})
    api.Log:Err("[Tax Tracker] Invalid callback for " .. tostring(name))
    return
  end
  
  updateCallbacks[name] = callback
  Debug.info("UpdateSystem", "Registered callback", {name = name})
end

-- Unregister a callback
function UpdateSystem.unregisterCallback(name)
  updateCallbacks[name] = nil
end

-- Force an immediate update of all callbacks
function UpdateSystem.forceUpdate()
  for callbackName, callback in pairs(updateCallbacks) do
    local success, error = pcall(callback)
    if not success then
      api.Log:Err(string.format("[Tax Tracker] Force update callback '%s' failed: %s", callbackName, error))
    end
  end
end

-- Set custom update interval (in milliseconds)
function UpdateSystem.setUpdateInterval(intervalMs)
  if intervalMs and intervalMs > 100 then
    updateInterval = intervalMs
  end
end

-- Get current update interval
function UpdateSystem.getUpdateInterval()
  return updateInterval
end

-- Check if update system is running
function UpdateSystem.isRunning()
  return isRunning
end

-- Get number of registered callbacks
function UpdateSystem.getCallbackCount()
  local count = 0
  for _ in pairs(updateCallbacks) do
    count = count + 1
  end
  return count
end

-- Start updates system with data and save callback (called from main.lua)
function UpdateSystem.startUpdates(listData, saveCallback)
  Debug.info("UpdateSystem", "Starting updates with list window integration", {landCount = listData and #listData or 0})
  
  -- Initialize the update system
  UpdateSystem.init()
  
  -- Register main update callback - Real-time updates for countdown timers
  local lastUpdate = 0
  local updateIntervalMs = 1000 -- Update every 1 second for real-time countdown updates
  local lastFullRefresh = 0
  local fullRefreshInterval = 5000 -- Force full refresh every 5 seconds for color updates
  
  -- UNIFIED UPDATE SYSTEM: Handles all updates efficiently
  local function mainUpdateCallback(dt)
    lastUpdate = lastUpdate + (dt or 16)
    if lastUpdate < updateIntervalMs then return end
    lastUpdate = 0
    
    -- Track time for periodic full refresh
    lastFullRefresh = lastFullRefresh + updateIntervalMs
    
    -- PERFORMANCE: Skip update entirely if window not visible
    local SavedLandsWindow = nil
    local windowVisible = false
    
    pcall(function()
      SavedLandsWindow = require("tax_tracker/ui/savedlandswindow")
      windowVisible = SavedLandsWindow and SavedLandsWindow.isVisible and SavedLandsWindow.isVisible()
    end)
    
    -- ALWAYS update exit reminder label (doesn't need window visible)
    pcall(function()
      local ReminderWindow = require("tax_tracker/reminderwindow")
      if ReminderWindow and ReminderWindow.updateExitReminder then
        ReminderWindow.updateExitReminder()
      end
    end)
    
    -- Exit immediately if window not visible
    if not windowVisible then
      return
    end
    
    -- PERFORMANCE: Skip if no data to process
    local dataCount = 0
    if listData and type(listData) == "table" then
      dataCount = #listData
    end
    if dataCount == 0 then
      return
    end
    
    -- REAL-TIME COLOR UPDATE: Check for overdue status changes
    pcall(function()
      local TimeSystem = require("tax_tracker/timesystem")
      if TimeSystem and TimeSystem.isOverdue and listData then
        local overdueChanges = 0
        local anyStatusChanged = false
        
        -- Check each land for overdue status changes
        for _, land in ipairs(listData) do
          if land and land.nextPayment then
            local wasOverdue = land.isOverdue
            local isNowOverdue = TimeSystem.isOverdue(land.nextPayment)
            
            if wasOverdue ~= isNowOverdue then
              land.isOverdue = isNowOverdue
              overdueChanges = overdueChanges + 1
              anyStatusChanged = true
              Debug.info("UpdateSystem", "Overdue status changed", {
                landName = land.name,
                wasOverdue = wasOverdue,
                isNowOverdue = isNowOverdue
              })
            end
          end
        end
        
        -- CRITICAL FIX: Force full UI refresh when status changes OR periodically
        local shouldFullRefresh = anyStatusChanged or (lastFullRefresh >= fullRefreshInterval)
        
        if shouldFullRefresh then
          lastFullRefresh = 0
          
          -- Trigger full data refresh to update colors
          if SavedLandsWindow and SavedLandsWindow.refreshData then
            pcall(SavedLandsWindow.refreshData)
            Debug.trace("UpdateSystem", "Triggered full UI refresh", {
              reason = anyStatusChanged and "status_change" or "periodic",
              overdueChanges = overdueChanges
            })
          end
        end
      end
    end)
    
    -- Update subsidiary systems with individual error protection
    pcall(function()
      local LoansSystem = require("tax_tracker/loanssystem")
      if LoansSystem and LoansSystem.updateLoansList and listData then
        LoansSystem.updateLoansList(listData)
      end
    end)
    
pcall(function()
      local FarmSystem = require("tax_tracker/farmsystem")
      if FarmSystem and FarmSystem.onUpdateEvent then
        FarmSystem.onUpdateEvent(dt)
      end
    end)
  end
  
  UpdateSystem.registerCallback("mainUpdate", mainUpdateCallback)
  Debug.info("UpdateSystem", "Main update callback registered for real-time list updates")
end

-- Stop updates system (called from main.lua)
function UpdateSystem.stopUpdates()
  Debug.info("UpdateSystem", "Stopping updates system")
  UpdateSystem.stop()
end

-- Initialize function required by main.lua
function UpdateSystem.initialize()
  -- Initialize the update system
  UpdateSystem.init()
  return true
end

return UpdateSystem