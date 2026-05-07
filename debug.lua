-- tax_tracker/debug.lua - Comprehensive debug logging system
local api = require("api")
-- TimeSystem removed to prevent circular dependency crashes

local Debug = {}

-- Debug configuration
local DEBUG_CONFIG = {
  enabled = true,
  logToFile = true,
  logToChat = false,  -- File-only by default; flip to true when actively debugging
  maxLogFileSize = 1024 * 1024, -- 1MB max log file
  maxLogLines = 1000, -- Max lines to keep in memory
  logLevels = {
    ERROR = 1,
    WARN = 2,
    INFO = 3,
    DEBUG = 4,
    TRACE = 5
  },
  currentLevel = 3 -- INFO level by default
}

-- Log storage
local logBuffer = {}
local logFilePath = "tax_tracker_UNIFIED.log"  -- CENTRALIZED LOG FILE
local sessionStartTime = 0

-- Store original API log functions for interception
local originalLogInfo = nil
local originalLogErr = nil

-- BUFFERED WRITE SYSTEM (Performance optimization)
local logWriteBuffer = {}
local BUFFER_SIZE = 50 -- Write to disk after 50 log entries
local BUFFER_TIMEOUT_MS = 5000 -- Force flush after 5 seconds
local lastFlushTime = 0
local flushTimer = nil

-- Initialize debug system - ENHANCED with API log interception
function Debug.init()
  -- Use GetUiMsec like the timer system does (from decompiled API)
  if api and api.Time and api.Time.GetUiMsec then
    sessionStartTime = api.Time:GetUiMsec()
  else
    sessionStartTime = 0
  end
  
  -- Clear old buffer
  logBuffer = {}
  
  -- Store original API log functions for restoration during cleanup
  if api and api.Log then
    originalLogInfo = api.Log.Info
    originalLogErr = api.Log.Err
  end
  
  -- Log session start
  Debug.info("Debug", "=== TAX TRACKER UNIFIED LOGGING SESSION STARTED ===")
  Debug.info("Debug", "Session time: " .. (sessionStartTime or 0))
  Debug.info("Debug", "Log level: " .. Debug.getLevelName(DEBUG_CONFIG.currentLevel))
  Debug.info("Debug", "API log interception enabled - all logs now unified")
end

-- Get level name from number
function Debug.getLevelName(level)
  for name, num in pairs(DEBUG_CONFIG.logLevels) do
    if num == level then return name end
  end
  return "UNKNOWN"
end

-- Get current timestamp string - FIXED to avoid circular dependency
local function getTimestamp()
  -- AVOID circular dependency - don't load TimeSystem from debug system
  local serverTime = 0
  -- TimeSystem loading removed to prevent circular dependency crash
  
  -- Get UI time for session tracking (matches timer system)
  local uiTime = 0
  if api and api.Time and api.Time.GetUiMsec then
    uiTime = api.Time:GetUiMsec()
  end
  
  -- Calculate session time in milliseconds
  local sessionTimeMs = uiTime - sessionStartTime
  local sessionTimeSec = math.floor(sessionTimeMs / 1000)
  local hours = math.floor(sessionTimeSec / 3600)
  local minutes = math.floor((sessionTimeSec % 3600) / 60)
  local seconds = sessionTimeSec % 60
  
  -- Format server time if available
  local timeStr = "NoServerTime"
  if serverTime > 0 then
    local success = pcall(function()
      if api and api.Time and api.Time.TimeToDate then
        local timeObj = api.Time:TimeToDate(serverTime)
        if timeObj and timeObj.year and timeObj.month and timeObj.day then
          timeStr = string.format("%04d-%02d-%02d %02d:%02d:%02d", 
            timeObj.year, timeObj.month, timeObj.day, 
            timeObj.hour or 0, timeObj.minute or 0, timeObj.sec or 0)
        end
      end
    end)
    
    if not success then
      timeStr = string.format("ServerTime_%d", serverTime)
    end
  end
  
  return string.format("[%s +%02d:%02d:%02d]", timeStr, hours, minutes, seconds)
end

-- Core logging function
local function writeLog(level, module, message, data)
  if not DEBUG_CONFIG.enabled then return end
  if level > DEBUG_CONFIG.currentLevel then return end
  
  local timestamp = getTimestamp()
  local levelName = Debug.getLevelName(level)
  local logLine = string.format("%s [%s] [%s] %s", timestamp, levelName, module or "Unknown", message or "")
  
  -- Add data if provided
  if data then
    if type(data) == "table" then
      local dataStr = ""
      for k, v in pairs(data) do
        dataStr = dataStr .. string.format(" %s=%s", tostring(k), tostring(v))
      end
      logLine = logLine .. " |" .. dataStr
    else
      logLine = logLine .. " | " .. tostring(data)
    end
  end
  
  -- Add to buffer
  table.insert(logBuffer, logLine)
  
  -- Trim buffer if too large
  if #logBuffer > DEBUG_CONFIG.maxLogLines then
    table.remove(logBuffer, 1)
  end
  
  -- Log to chat if enabled
  if DEBUG_CONFIG.logToChat and api and api.Log then
    if level == DEBUG_CONFIG.logLevels.ERROR then
      api.Log:Err(string.format("[%s] %s", module or "Debug", message or ""))
    else
      api.Log:Info(string.format("[%s] %s", module or "Debug", message or ""))
    end
  end
  
  -- Write to file if enabled
  if DEBUG_CONFIG.logToFile then
    Debug.writeToFile(logLine)
  end
end

-- Flush log write buffer to disk
function Debug.flushLogBuffer()
  if not api or not api.File or #logWriteBuffer == 0 then return end

  local success, error = pcall(function()
    -- Read existing log
    local existingLog = ""
    local readSuccess, content = pcall(function()
      return api.File:Read(logFilePath)
    end)

    if readSuccess and content and type(content) == "string" then
      existingLog = content
    end

    -- Append all buffered lines at once (MAJOR PERFORMANCE IMPROVEMENT)
    local newLines = table.concat(logWriteBuffer, "\n") .. "\n"
    local newLog = existingLog .. newLines

    -- Check file size and trim if necessary
    if string.len(newLog) > DEBUG_CONFIG.maxLogFileSize then
      local lines = {}
      for line in newLog:gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
      end

      -- Keep only the last 500 lines
      local startIndex = math.max(1, #lines - 500)
      local trimmedLines = {}
      for i = startIndex, #lines do
        trimmedLines[#trimmedLines + 1] = lines[i]
      end

      newLog = table.concat(trimmedLines, "\n") .. "\n"
    end

    -- Write to file (single disk write for many log entries)
    api.File:Write(logFilePath, newLog)

    -- Clear buffer after successful write
    logWriteBuffer = {}
    lastFlushTime = api.Time and api.Time:GetUiMsec() or 0
  end)

  if not success then
    -- Fallback to chat if file write fails
    if api and api.Log then
      api.Log:Err("[Debug] Failed to flush log buffer: " .. tostring(error))
    end
    -- Clear buffer anyway to prevent memory leak
    logWriteBuffer = {}
  end
end

-- Write log line to file (buffered version - PERFORMANCE OPTIMIZED)
function Debug.writeToFile(logLine)
  if not api or not api.File then return end

  -- Add to write buffer
  logWriteBuffer[#logWriteBuffer + 1] = logLine

  -- Auto-flush when buffer is full
  if #logWriteBuffer >= BUFFER_SIZE then
    Debug.flushLogBuffer()
    return
  end

  -- Auto-flush after timeout
  local currentTime = api.Time and api.Time:GetUiMsec() or 0
  if currentTime - lastFlushTime >= BUFFER_TIMEOUT_MS then
    Debug.flushLogBuffer()
    return
  end

  -- Set up timeout timer if not already running (use api:DoIn instead of Timer.TickTimer)
  if not flushTimer and api and api.DoIn then
    flushTimer = api:DoIn(BUFFER_TIMEOUT_MS, function()
      Debug.flushLogBuffer()
      flushTimer = nil
    end)
  end
end

-- Public logging functions
function Debug.error(module, message, data)
  writeLog(DEBUG_CONFIG.logLevels.ERROR, module, message, data)
end

function Debug.warn(module, message, data)
  writeLog(DEBUG_CONFIG.logLevels.WARN, module, message, data)
end

function Debug.info(module, message, data)
  writeLog(DEBUG_CONFIG.logLevels.INFO, module, message, data)
end

function Debug.debug(module, message, data)
  writeLog(DEBUG_CONFIG.logLevels.DEBUG, module, message, data)
end

function Debug.trace(module, message, data)
  writeLog(DEBUG_CONFIG.logLevels.TRACE, module, message, data)
end

-- Function call tracing
function Debug.traceCall(module, functionName, args, result)
  if DEBUG_CONFIG.currentLevel >= DEBUG_CONFIG.logLevels.TRACE then
    local argsStr = ""
    if args and type(args) == "table" then
      local argParts = {}
      for i, v in ipairs(args) do
        table.insert(argParts, tostring(v))
      end
      argsStr = "(" .. table.concat(argParts, ", ") .. ")"
    elseif args then
      argsStr = "(" .. tostring(args) .. ")"
    else
      argsStr = "()"
    end
    
    local resultStr = ""
    if result ~= nil then
      resultStr = " -> " .. tostring(result)
    end
    
    Debug.trace(module, "CALL: " .. functionName .. argsStr .. resultStr)
  end
end

-- Performance timing
local timers = {}

function Debug.startTimer(timerName)
  if api and api.Time and api.Time.GetUiMsec then
    timers[timerName] = api.Time:GetUiMsec()
    Debug.trace("Performance", "Timer started: " .. timerName)
  end
end

function Debug.endTimer(timerName, operation)
  if timers[timerName] and api and api.Time and api.Time.GetUiMsec then
    local elapsed = api.Time:GetUiMsec() - timers[timerName]
    Debug.info("Performance", string.format("Timer %s: %dms for %s", timerName, elapsed, operation or "operation"))
    timers[timerName] = nil
    return elapsed
  end
  return 0
end

-- Dump current log buffer
function Debug.dumpBuffer()
  Debug.info("Debug", "=== LOG BUFFER DUMP ===")
  for i, line in ipairs(logBuffer) do
    if api and api.Log then
      api.Log:Info(string.format("[%d] %s", i, line))
    end
  end
  Debug.info("Debug", "=== END BUFFER DUMP ===")
end

-- Save current buffer to file
function Debug.saveBuffer()
  if #logBuffer == 0 then
    Debug.info("Debug", "No log buffer to save")
    return
  end
  
  local bufferContent = table.concat(logBuffer, "\n")
  local success = pcall(function()
    api.File:Write("tax_tracker_buffer_dump.log", bufferContent)
  end)
  
  if success then
    Debug.info("Debug", "Buffer saved to tax_tracker_buffer_dump.log")
  else
    Debug.error("Debug", "Failed to save buffer to file")
  end
end

-- Configuration functions
function Debug.setLogLevel(level)
  if type(level) == "string" then
    level = DEBUG_CONFIG.logLevels[level:upper()]
  end
  
  if level and level >= 1 and level <= 5 then
    DEBUG_CONFIG.currentLevel = level
    Debug.info("Debug", "Log level set to: " .. Debug.getLevelName(level))
  else
    Debug.error("Debug", "Invalid log level: " .. tostring(level))
  end
end

function Debug.enableFileLogging(enabled)
  DEBUG_CONFIG.logToFile = enabled == true
  Debug.info("Debug", "File logging " .. (enabled and "enabled" or "disabled"))
end

function Debug.enableChatLogging(enabled)
  DEBUG_CONFIG.logToChat = enabled == true
  Debug.info("Debug", "Chat logging " .. (enabled and "enabled" or "disabled"))
end

-- Get debug stats
function Debug.getStats()
  return {
    bufferSize = #logBuffer,
    sessionStartTime = sessionStartTime,
    logLevel = Debug.getLevelName(DEBUG_CONFIG.currentLevel),
    fileLoggingEnabled = DEBUG_CONFIG.logToFile,
    chatLoggingEnabled = DEBUG_CONFIG.logToChat
  }
end

-- Cleanup - ENHANCED with API log restoration and flush
function Debug.cleanup()
  -- Log cleanup start BEFORE restoring API
  Debug.info("Debug", "=== TAX TRACKER UNIFIED LOGGING SESSION ENDED ===")

  -- CRITICAL: Flush pending log writes before cleanup
  Debug.flushLogBuffer()

  -- Stop flush timer if running (note: api:DoIn callbacks cannot be cancelled)
  -- Just mark as not running to prevent re-creation
  flushTimer = nil

  -- Save buffer before any cleanup
  Debug.saveBuffer()

  -- Clear references to original API functions
  -- (No restoration needed since we're not intercepting anymore)

  -- Clear all data
  logBuffer = {}
  logWriteBuffer = {}
  timers = {}

  -- Clear references to prevent reload conflicts
  originalLogInfo = nil
  originalLogErr = nil
end

return Debug