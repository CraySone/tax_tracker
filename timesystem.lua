-- tax_tracker/time_system.lua - REWRITTEN USING DECOMPILED API KNOWLEDGE
-- Fixed time management system based on decompiled/api.lua patterns

local api = require("api")
-- Debug removed to prevent circular dependency crashes

local TimeSystem = {}

-- Time constants
local SECONDS_PER_DAY = 86400
local SECONDS_PER_HOUR = 3600
local SECONDS_PER_MINUTE = 60

-- Timer addon approach - just use UiMsec converted to seconds (no server time needed)
local function getCurrentTimestamp()
  if api and api.Time and api.Time.GetUiMsec then
    local uiMsec = api.Time:GetUiMsec()
    if uiMsec and uiMsec > 0 then
      return math.floor(uiMsec / 1000)
    end
  end
  return 0
end

-- Safe wrapper for os.time() - fallback to game time if os not available
local function safeOsTime()
  local success, result = pcall(function() return os and os.time() end)
  if success and result then
    return result
  else
    -- Fallback to game time if os is not available
    return getCurrentTimestamp()
  end
end

-- Timer addon approach - always use UI time (no server time needed)
function TimeSystem.getCurrentTime()
  return getCurrentTimestamp()
end

-- Timer addon approach - show countdown/countup like timer display (no dates)
function TimeSystem.formatCountdown(deadlineData)
  if not deadlineData then
    return "No Timer"
  end
  
  -- Calculate elapsed time since timer creation (EXACT timer addon method)
  local elapsedTime = 0
  local createdTimeStr = nil
  
  if type(deadlineData) == "number" then
    -- Legacy format - treat as overdue by default
    local currentTime = getCurrentTimestamp()
    if currentTime == 0 then
      return "Time Error"
    end
    local timeSinceDeadline = currentTime - deadlineData
    elapsedTime = math.max(0, timeSinceDeadline * 1000) -- Convert to ms
    -- Display as countup
    local totalSeconds = math.floor(elapsedTime / 1000)
    local days = math.floor(totalSeconds / SECONDS_PER_DAY)
    local hours = math.floor((totalSeconds % SECONDS_PER_DAY) / SECONDS_PER_HOUR)
    local minutes = math.floor((totalSeconds % SECONDS_PER_HOUR) / SECONDS_PER_MINUTE)
    local seconds = totalSeconds % SECONDS_PER_MINUTE
    
    -- Format with fixed alignment: left-aligned label + center-aligned timer
    local timeStr = ""
    if days > 0 then
      timeStr = string.format("%d days %02d hours %02d:%02d", days, hours, minutes, seconds)
    elseif hours > 0 then
      timeStr = string.format("%02d hours %02d:%02d", hours, minutes, seconds)
    else
      timeStr = string.format("%02d:%02d", minutes, seconds)
    end
    -- Fixed format: "OVERDUE:" + padding to center the timer in remaining space
    local totalWidth = 35 -- Total column width
    local labelWidth = 8  -- "OVERDUE:" width
    local remainingWidth = totalWidth - labelWidth
    local timerPadding = math.max(0, (remainingWidth - #timeStr) / 2)
    local paddingStr = string.rep(" ", math.floor(timerPadding))
    return "OVERDUE:" .. paddingStr .. timeStr
  end
  
  -- New persistent format - extract createdTimeStr
  createdTimeStr = deadlineData.createdAtLocalTime
  
  if not createdTimeStr then
    return "Invalid Timer"
  end
  
  -- EXACT timer addon elapsed time calculation
  local localTimeStr = api.Time:GetLocalTime()
  if not localTimeStr or type(localTimeStr) ~= "string" then
    return "Invalid Timer"
  end

  local starttime = tonumber(string.sub(createdTimeStr, -6))
  local currtime = tonumber(string.sub(localTimeStr, -6))

  if not starttime or not currtime then
    return "Invalid Timer"
  end

  if starttime > currtime then
    currtime = currtime + 1000000
  end
  
  elapsedTime = (currtime - starttime) * 1000
  
  -- Handle both timer types
  local timerType = deadlineData.timerType or "countdown"
  local durationDays = deadlineData.durationDays or deadlineData.daysFromCreation or 7
  
  if timerType == "countup" then
    -- COUNTUP TIMER (overdue) - show elapsed time since creation
    local totalSeconds = math.floor(elapsedTime / 1000)
    local days = math.floor(totalSeconds / SECONDS_PER_DAY)
    local hours = math.floor((totalSeconds % SECONDS_PER_DAY) / SECONDS_PER_HOUR)
    local minutes = math.floor((totalSeconds % SECONDS_PER_HOUR) / SECONDS_PER_MINUTE)
    local seconds = totalSeconds % SECONDS_PER_MINUTE
    
    -- Format with fixed alignment: left-aligned label + center-aligned timer
    local timeStr = ""
    if days > 0 then
      timeStr = string.format("%d days %02d hours %02d:%02d", days, hours, minutes, seconds)
    elseif hours > 0 then
      timeStr = string.format("%02d hours %02d:%02d", hours, minutes, seconds)
    else
      timeStr = string.format("%02d:%02d", minutes, seconds)
    end
    -- Fixed format: "OVERDUE:" + padding to center the timer in remaining space
    local totalWidth = 35 -- Total column width
    local labelWidth = 8  -- "OVERDUE:" width
    local remainingWidth = totalWidth - labelWidth
    local timerPadding = math.max(0, (remainingWidth - #timeStr) / 2)
    local paddingStr = string.rep(" ", math.floor(timerPadding))
    return "OVERDUE:" .. paddingStr .. timeStr
  else
    -- COUNTDOWN TIMER (paid) - show remaining time like timer addon IsTimer=true
    local targetDuration = durationDays * SECONDS_PER_DAY * 1000
    local remainingTime = targetDuration - elapsedTime
    
    if remainingTime > 0 then
      -- Still counting down
      local remainingSeconds = math.floor(remainingTime / 1000)
      local days = math.floor(remainingSeconds / SECONDS_PER_DAY)
      local hours = math.floor((remainingSeconds % SECONDS_PER_DAY) / SECONDS_PER_HOUR)
      local minutes = math.floor((remainingSeconds % SECONDS_PER_HOUR) / SECONDS_PER_MINUTE)
      local seconds = remainingSeconds % SECONDS_PER_MINUTE
      
      -- Format with fixed alignment: left-aligned label + center-aligned timer
      local timeStr = ""
      if days > 0 then
        timeStr = string.format("%d days %02d hours %02d:%02d", days, hours, minutes, seconds)
      elseif hours > 0 then
        timeStr = string.format("%02d hours %02d:%02d", hours, minutes, seconds)
      else
        timeStr = string.format("%02d:%02d", minutes, seconds)
      end
      -- Fixed format: "PAID FOR:" + padding to center the timer in remaining space
      local totalWidth = 35 -- Total column width
      local labelWidth = 9  -- "PAID FOR:" width
      local remainingWidth = totalWidth - labelWidth
      local timerPadding = math.max(0, (remainingWidth - #timeStr) / 2)
      local paddingStr = string.rep(" ", math.floor(timerPadding))
      return "PAID FOR:" .. paddingStr .. timeStr
    else
      -- Timer finished, show overdue time
      local overdueSeconds = math.floor(math.abs(remainingTime) / 1000)
      local days = math.floor(overdueSeconds / SECONDS_PER_DAY)
      local hours = math.floor((overdueSeconds % SECONDS_PER_DAY) / SECONDS_PER_HOUR)
      local minutes = math.floor((overdueSeconds % SECONDS_PER_HOUR) / SECONDS_PER_MINUTE)
      local seconds = overdueSeconds % SECONDS_PER_MINUTE
      
      if days > 0 then
        return string.format("OVERDUE: %dd %02d:%02d:%02d", days, hours, minutes, seconds)
      elseif hours > 0 then
        return string.format("OVERDUE: %02d:%02d:%02d", hours, minutes, seconds)
      else
        return string.format("OVERDUE: %02d:%02d", minutes, seconds)
      end
    end
  end
end

-- Get color for time display based on urgency (timer addon approach)
function TimeSystem.getTimeColor(deadlineData)
  if not deadlineData then
    return {1, 1, 1, 1} -- White for errors
  end
  
  -- Calculate remaining time like timer addon
  local elapsedTime = 0
  local targetDuration = 0
  
  if type(deadlineData) == "number" then
    -- Legacy format
    local currentTime = getCurrentTimestamp()
    if currentTime == 0 then
      return {1, 1, 1, 1} -- White for errors
    end
    local remainingTime = deadlineData - currentTime
    elapsedTime = (7 * SECONDS_PER_DAY * 1000) + (remainingTime * -1000)
    targetDuration = 7 * SECONDS_PER_DAY * 1000
  else
    -- New persistent format
    local createdTimeStr = deadlineData.createdAtLocalTime
    local daysFromCreation = deadlineData.durationDays or deadlineData.daysFromCreation or 7
    
    if not createdTimeStr then
      return {1, 1, 1, 1} -- White for errors
    end
    
    local starttime = tonumber(string.sub(createdTimeStr, -6))
    local currtime = tonumber(string.sub(api.Time:GetLocalTime(), -6))
    if starttime > currtime then
      currtime = currtime + 1000000
    end
    
    elapsedTime = (currtime - starttime) * 1000
    targetDuration = daysFromCreation * SECONDS_PER_DAY * 1000
  end
  
  local remainingTime = targetDuration - elapsedTime
  local remainingSeconds = remainingTime / 1000
  
  if remainingSeconds <= 0 then
    return {1, 0.2, 0.2, 1} -- Bright red for overdue
  elseif remainingSeconds <= SECONDS_PER_DAY then -- Less than 1 day
    return {1, 0.6, 0.2, 1} -- Orange for urgent  
  elseif remainingSeconds <= 3 * SECONDS_PER_DAY then -- Less than 3 days
    return {1, 0.9, 0.3, 1} -- Yellow for warning
  else
    return {0.4, 1, 0.4, 1} -- Green for safe
  end
end

-- Get time left in milliseconds (for UI urgency calculations)
function TimeSystem.getTimeLeft(deadlineData)
  if not deadlineData then return 0 end
  
  -- Calculate remaining time like timer addon
  local elapsedTime = 0
  local targetDuration = 0
  
  if type(deadlineData) == "number" then
    -- Legacy format
    local currentTime = getCurrentTimestamp()
    if currentTime == 0 then return 0 end
    local remainingTime = deadlineData - currentTime
    return remainingTime * 1000 -- Convert to milliseconds
  end
  
  -- New persistent format
  local createdTimeStr = deadlineData.createdAtLocalTime
  local daysFromCreation = deadlineData.durationDays or deadlineData.daysFromCreation or 7
  
  if not createdTimeStr then return 0 end
  
  -- Check for countup timer type - always returns negative (overdue)
  if deadlineData.timerType == "countup" then
    local starttime = tonumber(string.sub(createdTimeStr, -6))
    local currtime = tonumber(string.sub(api.Time:GetLocalTime(), -6))
    if starttime > currtime then
      currtime = currtime + 1000000
    end
    elapsedTime = (currtime - starttime) * 1000
    return -elapsedTime -- Negative means overdue
  end
  
  local starttime = tonumber(string.sub(createdTimeStr, -6))
  local currtime = tonumber(string.sub(api.Time:GetLocalTime(), -6))
  if starttime > currtime then
    currtime = currtime + 1000000
  end
  
  elapsedTime = (currtime - starttime) * 1000
  targetDuration = daysFromCreation * SECONDS_PER_DAY * 1000
  
  return targetDuration - elapsedTime
end

-- Get remaining time in seconds (for backward compatibility)
function TimeSystem.getRemainingSeconds(deadlineData)
  local timeLeftMs = TimeSystem.getTimeLeft(deadlineData)
  return timeLeftMs / 1000
end

-- Format time ago (for farm system)
function TimeSystem.formatTimeAgo(timestamp)
  if not timestamp then return "Unknown" end
  local currentTime = getCurrentTimestamp()
  if currentTime == 0 then return "Unknown" end
  
  local elapsed = currentTime - timestamp
  if elapsed < 0 then return "Just now" end
  
  local hours = math.floor(elapsed / SECONDS_PER_HOUR)
  local minutes = math.floor((elapsed % SECONDS_PER_HOUR) / SECONDS_PER_MINUTE)
  
  if hours > 0 then
    return string.format("%dh %dm ago", hours, minutes)
  else
    return string.format("%dm ago", minutes)
  end
end

-- Validate land data - only fix legacy formats, don't auto-create timers
function TimeSystem.validateLandData(land)
  if not land then return end
  
  -- DO NOT auto-create timers when nil - nil means no timer
  -- Only convert legacy number format to new timer format
  if land.nextPayment == nil then
    -- Leave as nil - this means "No Timer"
    return
  elseif type(land.nextPayment) == "number" then
    -- Convert legacy timestamp format to new timer format
    local currentTime = getCurrentTimestamp()
    if currentTime > 0 then
      local daysRemaining = math.max(0, math.floor((land.nextPayment - currentTime) / SECONDS_PER_DAY))
      if daysRemaining > 0 then
        land.nextPayment = TimeSystem.createCountdownTimer(daysRemaining)
      else
        land.nextPayment = TimeSystem.createCountupTimer()
      end
    end
  end
  
  -- Update isOverdue flag
  land.isOverdue = TimeSystem.isOverdue(land.nextPayment)
end

-- Create a payment deadline (X days from now)
function TimeSystem.createDeadline(daysFromNow)
  local currentTime = getCurrentTimestamp()
  if currentTime == 0 then return 0 end
  return currentTime + (daysFromNow * SECONDS_PER_DAY)
end

-- Check if a payment is overdue (timer addon approach)
function TimeSystem.isOverdue(deadlineData)
  if not deadlineData then
    return false
  end
  
  -- Check for countup timer type first - always overdue
  if type(deadlineData) == "table" and deadlineData.timerType == "countup" then
    return true -- Countup timers are always overdue
  end
  
  -- Calculate remaining time like timer addon
  local elapsedTime = 0
  local targetDuration = 0
  
  if type(deadlineData) == "number" then
    -- Legacy format
    local currentTime = getCurrentTimestamp()
    if currentTime == 0 then
      return false
    end
    local remainingTime = deadlineData - currentTime
    elapsedTime = (7 * SECONDS_PER_DAY * 1000) + (remainingTime * -1000)
    targetDuration = 7 * SECONDS_PER_DAY * 1000
  else
    -- New persistent format
    local createdTimeStr = deadlineData.createdAtLocalTime
    local daysFromCreation = deadlineData.daysFromCreation or deadlineData.durationDays or 7
    
    if not createdTimeStr then
      return false
    end
    
    local starttime = tonumber(string.sub(createdTimeStr, -6))
    local currtime = tonumber(string.sub(api.Time:GetLocalTime(), -6))
    if starttime > currtime then
      currtime = currtime + 1000000
    end
    
    elapsedTime = (currtime - starttime) * 1000
    targetDuration = daysFromCreation * SECONDS_PER_DAY * 1000
  end
  
  local remainingTime = targetDuration - elapsedTime
  return remainingTime <= 0
end

-- ======= TIMER ADDON'S EXACT APPROACH =======
-- Based on timers/timer_window.lua Export/Import functions
-- Store payment creation time like timer addon stores start time

-- Create countdown timer exactly like timer addon creates countdown timers
function TimeSystem.createCountdownTimer(daysFromNow)
  return {
    createdAtLocalTime = api.Time:GetLocalTime(),
    createdAtUiMsec = api.Time:GetUiMsec(),
    durationDays = daysFromNow,
    timerType = "countdown",
    running = true,
    elapsedTime = 0
  }
end

-- Create countup timer for overdue taxes (like stopwatch mode)
function TimeSystem.createCountupTimer()
  return {
    createdAtLocalTime = api.Time:GetLocalTime(),
    createdAtUiMsec = api.Time:GetUiMsec(),
    durationDays = 0,
    timerType = "countup",
    running = true,
    elapsedTime = 0
  }
end

-- Legacy wrapper for backward compatibility
function TimeSystem.createDeadlineWithPersistence(daysFromNow)
  if daysFromNow > 0 then
    return TimeSystem.createCountdownTimer(daysFromNow)
  else
    return TimeSystem.createCountupTimer()
  end
end

-- Convert deadline data back to current deadline timestamp (EXACTLY like timer addon's Import)
function TimeSystem.loadDeadlineFromPersistence(deadlineData)
  if not deadlineData then return 0 end

  -- If it's just a number (legacy format), return as-is for now
  if type(deadlineData) == "number" then
    return deadlineData
  end

  -- If it's the new persistent format, use EXACT timer addon approach
  if type(deadlineData) == "table" and deadlineData.createdAtLocalTime and deadlineData.daysFromCreation then
    local createdTimeStr = deadlineData.createdAtLocalTime
    local daysOffset = deadlineData.daysFromCreation

    if not createdTimeStr or not daysOffset then return 0 end
    
    -- EXACT timer addon's last-6-digits approach to handle float precision
    local starttime = tonumber(string.sub(createdTimeStr, -6))
    local currtime = tonumber(string.sub(api.Time:GetLocalTime(), -6))
    
    -- Handle rollover exactly like timer addon does
    if starttime > currtime then
      currtime = currtime + 1000000
    end
    
    -- Calculate the creation UiMsec using EXACT timer addon method
    local createdUiMsec = api.Time:GetUiMsec() - ((currtime - starttime) * 1000)
    
    -- Convert to seconds and add days offset to get deadline
    local createdTimestamp = math.floor(createdUiMsec / 1000)
    local deadlineTimestamp = createdTimestamp + (daysOffset * SECONDS_PER_DAY)
    
    -- Debug.trace removed to prevent circular dependency
    
    return deadlineTimestamp
  end
  
  -- Fallback for unknown format
  -- Debug.warn removed to prevent circular dependency
  return 0
end

-- Get time remaining in seconds (negative if overdue)
function TimeSystem.getTimeRemaining(targetTimestamp)
  local currentTime = getCurrentTimestamp()
  if currentTime == 0 or not targetTimestamp or targetTimestamp == 0 then
    return 0
  end
  return targetTimestamp - currentTime
end

-- Mark a payment as paid (extend countdown timer by 7 days like timer addon)
function TimeSystem.markPaid(currentDeadline)
  if not currentDeadline then
    return TimeSystem.createCountdownTimer(7)
  end

  if type(currentDeadline) == "table" and currentDeadline.createdAtLocalTime then
    local timerType = currentDeadline.timerType or "countdown"

    if timerType == "countup" then
      -- Converting overdue (countup) to paid (countdown) - create fresh 7-day timer
      return TimeSystem.createCountdownTimer(7)
    end

    -- Extending existing countdown timer - add 7 days to duration (preserve exact timing)
    return {
      createdAtLocalTime = currentDeadline.createdAtLocalTime,
      createdAtUiMsec = currentDeadline.createdAtUiMsec,
      durationDays = (currentDeadline.durationDays or currentDeadline.daysFromCreation or 7) + 7,
      timerType = "countdown",
      running = true,
      elapsedTime = currentDeadline.elapsedTime or 0,
    }
  end

  -- Legacy format - convert to new 7-day countdown timer
  return TimeSystem.createCountdownTimer(7)
end

-- Mark a payment as unpaid (start countup timer for overdue)
function TimeSystem.markUnpaid()
  if getCurrentTimestamp() == 0 then return 0 end
  return TimeSystem.createCountupTimer()
end

-- Validate and fix extreme timestamps
function TimeSystem.validateTimestamp(timestamp, landName)
  local currentTime = getCurrentTimestamp()
  if currentTime == 0 then return 0 end

  if not timestamp or type(timestamp) ~= "number" or timestamp == 0 then
    return currentTime + (7 * SECONDS_PER_DAY)
  end

  local days = (timestamp - currentTime) / SECONDS_PER_DAY
  if math.abs(days) > 365 then
    return currentTime + (7 * SECONDS_PER_DAY)
  end

  return timestamp
end

-- Format simple time remaining for warnings
function TimeSystem.formatSimpleRemaining(seconds)
  if seconds <= 0 then
    local overdue = math.abs(seconds)
    local days = math.floor(overdue / SECONDS_PER_DAY)
    local hours = math.floor((overdue % SECONDS_PER_DAY) / SECONDS_PER_HOUR)
    local minutes = math.floor((overdue % SECONDS_PER_HOUR) / SECONDS_PER_MINUTE)
    
    if days > 0 then
      return string.format("%dd %dh ago", days, hours)
    elseif hours > 0 then
      return string.format("%dh %dm ago", hours, minutes)
    else
      return string.format("%dm ago", minutes)
    end
  else
    local days = math.floor(seconds / SECONDS_PER_DAY)
    local hours = math.floor((seconds % SECONDS_PER_DAY) / SECONDS_PER_HOUR)
    local minutes = math.floor((seconds % SECONDS_PER_HOUR) / SECONDS_PER_MINUTE)
    
    if days > 0 then
      return string.format("%dd %dh left", days, hours)
    elseif hours > 0 then
      return string.format("%dh %dm left", hours, minutes)
    else
      return string.format("%dm left", minutes)
    end
  end
end

-- Initialize function required by main.lua
function TimeSystem.initialize()
  -- TimeSystem is stateless and ready to use
  return true
end

return TimeSystem
