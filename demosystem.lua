-- tax_tracker/demosystem.lua - Demo (Demolition) Tracker for land sniping
-- Tracks other players' properties approaching demolition by date/time
local api = require("api")
local gui = require("tax_tracker/gui")
local Config = require("tax_tracker/config")

-- Safe Debug loading
local Debug = nil
pcall(function() Debug = require("tax_tracker/debug") end)
if not Debug then
  Debug = { info = function() end, warn = function() end, error = function() end, debug = function() end, trace = function() end }
end

-- Safe LandInference loading (for auto-fill land type from target)
local LandInference = nil
pcall(function() LandInference = require("tax_tracker/utils/landinference") end)

local DemoSystem = {}

-- Data
local demoData = {}
local demoSeq = 0
local demoWin = nil
local demoItemList = nil
local editingEntryId = nil
local lastCheckTime = 0 -- For 60-second check interval

-- Notification window (tier2_sextant style popup)
local notifyWin = nil
local notifyLabel = nil
local notifyMapBtn = nil
local notifyDismissBtn = nil
local notifyQueue = {} -- Queue of entries waiting to be shown
local currentNotifyEntry = nil -- Entry currently being displayed
local queueNotification -- Forward declaration to avoid reference errors

-- Helper to add tint background
local function addTint(win, id, alpha, topPad)
  local pad = topPad or 36
  local a = alpha or 0.60
  local bg = win:CreateChildWidget("textbox", id or "bg", 0, true)
  bg:AddAnchor("TOPLEFT", win, 0, pad)
  bg:AddAnchor("BOTTOMRIGHT", win, 0, 0)
  bg:SetText("")
  if bg.style and bg.style.SetColor then bg.style:SetColor(0, 0, 0, a) end
  if bg.Enable then bg:Enable(false) end
  bg:Show(true)
  return bg
end

-- Helper to create a section background bar
local function addSectionBg(parent, id, x, y, w, h, r, g, b, a)
  local bg = parent:CreateChildWidget("textbox", id, 0, true)
  bg:SetExtent(w, h)
  bg:AddAnchor("TOPLEFT", parent, x, y)
  bg:SetText("")
  if bg.style and bg.style.SetColor then bg.style:SetColor(r or 0.1, g or 0.12, b or 0.18, a or 0.7) end
  if bg.Enable then bg:Enable(false) end
  bg:Show(true)
  return bg
end

-- Helper to create a section title label
local function addSectionTitle(parent, id, text, x, y, r, g, b)
  local lbl = parent:CreateChildWidget("label", id, 0, true)
  lbl:SetText(text)
  lbl:AddAnchor("TOPLEFT", parent, x, y)
  if lbl.style then
    lbl.style:SetFontSize(FONT_SIZE.MIDDLE)
    lbl.style:SetColor(r or 0.5, g or 0.7, b or 0.9, 1)
  end
  return lbl
end

-- ==================== TIME HELPERS ====================

-- Get current date object from API
local function getCurrentDate()
  local localTime = api.Time:GetLocalTime()
  if localTime then
    local success, dateObj = pcall(function()
      return api.Time:TimeToDate(localTime)
    end)
    if success and dateObj and dateObj.year and dateObj.year > 2000 then
      return dateObj
    end
  end
  return nil
end

-- Get current date string for display
local function getCurrentDateString()
  local d = getCurrentDate()
  if d then
    return string.format("%02d.%02d.%04d", d.day, d.month, d.year)
  end
  return "Today"
end

-- Julian Day Number for date comparison (pure integer math, no os.time needed)
local function toJulianDayNumber(year, month, day)
  local a = math.floor((14 - month) / 12)
  local y = year + 4800 - a
  local m = month + 12 * a - 3
  return day + math.floor((153 * m + 2) / 5) + 365 * y
       + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400) - 32045
end

-- Get seconds from now until a target date/time (negative = past)
local function getSecondsUntilDate(targetYear, targetMonth, targetDay, targetHour, targetMin)
  local now = getCurrentDate()
  if not now then return 999999999 end

  local nowJDN = toJulianDayNumber(now.year, now.month, now.day)
  local targetJDN = toJulianDayNumber(targetYear, targetMonth, targetDay)

  local daysDiff = targetJDN - nowJDN
  -- Handle both possible field names from api.Time:TimeToDate()
  local nowHour = now.hour or now.hours or 0
  local nowMin  = now.min or now.minute or now.minutes or 0
  local nowSec  = now.sec or now.second or now.seconds or 0

  local nowTimeOfDay    = nowHour * 3600 + nowMin * 60 + nowSec
  local targetTimeOfDay = (targetHour or 0) * 3600 + (targetMin or 0) * 60

  return daysDiff * 86400 + (targetTimeOfDay - nowTimeOfDay)
end

-- Format a demo date/time for display: "12:30 - 13:00 | 20.02.2026"
local function formatDemoTime(entry)
  if not entry then return "No Time" end
  return string.format("%02d:%02d - %02d:%02d | %02d.%02d.%04d",
    entry.demoStartHour or 0, entry.demoStartMin or 0,
    entry.demoEndHour or 0, entry.demoEndMin or 0,
    entry.demoDay or 1, entry.demoMonth or 1, entry.demoYear or 2026)
end

-- Get seconds until demo START (negative = past)
local function getSecondsUntilDemo(entry)
  if not entry then return 999999999 end
  return getSecondsUntilDate(entry.demoYear, entry.demoMonth, entry.demoDay,
    entry.demoStartHour, entry.demoStartMin)
end

-- Get seconds until demo END (negative = fully expired)
local function getSecondsUntilDemoEnd(entry)
  if not entry then return 999999999 end
  return getSecondsUntilDate(entry.demoYear, entry.demoMonth, entry.demoDay,
    entry.demoEndHour, entry.demoEndMin)
end

-- Get color based on time until demo
local function getDemoColor(entry)
  local secUntil = getSecondsUntilDemo(entry)

  if secUntil <= 0 then
    return { 1, 0.2, 0.2, 1 }    -- Red: demo window active or passed
  elseif secUntil <= 900 then      -- 15 min
    return { 1, 0.4, 0.1, 1 }    -- Bright orange: imminent
  elseif secUntil <= 3600 then     -- 1 hour
    return { 1, 0.6, 0.2, 1 }    -- Orange
  elseif secUntil <= 10800 then    -- 3 hours
    return { 1, 0.9, 0.3, 1 }    -- Yellow
  elseif secUntil <= 86400 then    -- 24 hours
    return { 0.7, 1, 0.5, 1 }    -- Light green
  else
    return { 0.4, 1, 0.4, 1 }    -- Green: far away
  end
end

-- Format time-until as human readable relative string
local function formatTimeUntil(entry)
  local secUntil = getSecondsUntilDemo(entry)

  if secUntil <= 0 then
    local secUntilEnd = getSecondsUntilDemoEnd(entry)
    if secUntilEnd > 0 then
      return "NOW!"
    else
      return "EXPIRED"
    end
  end

  local days = math.floor(secUntil / 86400)
  local hours = math.floor((secUntil % 86400) / 3600)
  local minutes = math.floor((secUntil % 3600) / 60)

  if days > 0 then
    return string.format("in %dd %dh", days, hours)
  elseif hours > 0 then
    return string.format("in %dh %dm", hours, minutes)
  else
    return string.format("in %dm", minutes)
  end
end

-- ==================== COORDINATE HELPERS ====================

-- Same COEFF used by saved lands list (landtable.lua) for sextant-to-map conversion
local MAP_COEFF = 0.00097657363894522145695357130138029

local function sextantToMapX(dir, deg, min, sec)
  local x = deg + (min + (sec / 60)) / 60
  if dir == "W" then x = -x end
  return (x + 21) / MAP_COEFF
end

local function sextantToMapY(dir, deg, min, sec)
  local y = deg + (min + (sec / 60)) / 60
  if dir == "S" then y = -y end
  return (y + 28) / MAP_COEFF
end

-- Format sextant coordinates for display (nested format like saved lands)
local function formatSextantCoords(coords)
  if not coords or not coords.lon then return nil end
  return string.format("%s%d°%d'%d\" %s%d°%d'%d\"",
    coords.lon.dir or "E",
    tonumber(coords.lon.deg) or 0,
    tonumber(coords.lon.min) or 0,
    tonumber(coords.lon.sec) or 0,
    coords.lat.dir or "N",
    tonumber(coords.lat.deg) or 0,
    tonumber(coords.lat.min) or 0,
    tonumber(coords.lat.sec) or 0)
end

-- ==================== AUTO-CAPTURE ====================

-- Match land type from target name using Config patterns (like land editor)
local function matchLandTypeFromName(targetName)
  if not targetName or targetName == "" then return nil end

  -- Try LandInference module first
  if LandInference and LandInference.inferFromName then
    local inferred = LandInference.inferFromName(targetName)
    if inferred then return inferred end
  end

  -- Fallback: match directly against Config.LAND_TYPE_PATTERNS
  local lowerName = string.lower(targetName)
  if Config.LAND_TYPE_PATTERNS then
    for _, pattern in ipairs(Config.LAND_TYPE_PATTERNS) do
      if string.find(lowerName, pattern[1], 1, true) then
        return pattern[2]
      end
    end
  end

  return nil
end

local function capturePlayerData()
  local data = {
    coordinates = nil,
    zone = nil,
    zoneId = 323,
    targetName = nil,
    inferredLandType = nil
  }

  -- Capture player sextant coordinates (EXACT same format as saved lands)
  local coordSuccess, coordErr = pcall(function()
    local sextants = api.Map:GetPlayerSextants()
    Debug.info("Demo", "GetPlayerSextants result", {
      success = sextants ~= nil,
      hasDegLong = sextants and sextants.deg_long ~= nil
    })
    if sextants and sextants.deg_long then
      -- Convert to nested format (same as uimanager_v2.lua getCurrentSextant)
      data.coordinates = {
        lon = {
          dir = sextants.longitude or "E",
          deg = sextants.deg_long or 0,
          min = sextants.min_long or 0,
          sec = sextants.sec_long or 0
        },
        lat = {
          dir = sextants.latitude or "N",
          deg = sextants.deg_lat or 0,
          min = sextants.min_lat or 0,
          sec = sextants.sec_lat or 0
        }
      }
      Debug.info("Demo", "Coordinates captured", {
        lon = string.format("%s%d°%d'%d\"", data.coordinates.lon.dir, data.coordinates.lon.deg,
          data.coordinates.lon.min, data.coordinates.lon.sec),
        lat = string.format("%s%d°%d'%d\"", data.coordinates.lat.dir, data.coordinates.lat.deg,
          data.coordinates.lat.min, data.coordinates.lat.sec)
      })
    else
      Debug.warn("Demo", "Failed to capture coordinates - GetPlayerSextants returned invalid data")
    end
  end)
  if not coordSuccess then
    Debug.error("Demo", "Coordinate capture error", { error = coordErr })
  end

  -- Capture target name: try UnitInfo first (like existing code)
  pcall(function()
    local info = api.Unit:UnitInfo("target")
    if info and info.name and info.name ~= "" then
      data.targetName = info.name
    end
  end)

  -- Fallback: try GetUnitId + GetUnitNameById (like land editor's auto-fill)
  if not data.targetName then
    pcall(function()
      local targetId = api.Unit:GetUnitId("target")
      if targetId then
        local name = api.Unit:GetUnitNameById(targetId)
        if name and name ~= "" then
          data.targetName = name
        end
      end
    end)
  end

  -- Infer land type from target name (always attempt)
  if data.targetName then
    data.inferredLandType = matchLandTypeFromName(data.targetName)
  end

  -- Capture current zone
  pcall(function()
    local zoneGroup = api.Unit:GetCurrentZoneGroup()
    if zoneGroup then
      local prodZones = api.Store:GetProductionZoneGroups()
      if prodZones then
        for _, z in ipairs(prodZones) do
          if z.id == zoneGroup then
            local name = z.name or ""
            local dashPos = name:find(" %- ")
            if dashPos then
              name = name:sub(dashPos + 3)
            end
            data.zone = name
            data.zoneId = z.id
            break
          end
        end
      end
      if not data.zone then
        data.zoneId = zoneGroup
      end
    end
  end)

  if not data.zone then
    data.zone = "Unknown Zone"
  end

  return data
end

-- ==================== SORTING ====================

local function sortByUrgency()
  table.sort(demoData, function(a, b)
    return getSecondsUntilDemo(a) < getSecondsUntilDemo(b)
  end)
end

-- ==================== CRUD ====================

function DemoSystem.createEntry(landType, zone, zoneId, coords, targetName,
                                 startHour, startMin, endHour, endMin, day, month, year, notes)
  demoSeq = demoSeq + 1

  local entry = {
    id = demoSeq,
    landType = landType or "Unknown",
    zone = zone or "Unknown Zone",
    zoneId = zoneId or 323,
    coordinates = coords,
    targetName = targetName or "",
    demoStartHour = startHour or 0,
    demoStartMin = startMin or 0,
    demoEndHour = endHour or 0,
    demoEndMin = endMin or 0,
    demoDay = day or 1,
    demoMonth = month or 1,
    demoYear = year or 2026,
    notified10min = false,  -- Alert at 10 minutes before
    notifiedNow = false,    -- Alert when demo starts
    recordedAt = api.Time:GetLocalTime(),
    notes = notes or ""
  }

  table.insert(demoData, entry)
  sortByUrgency()

  Debug.info("Demo", "Entry created", {
    id = entry.id, landType = entry.landType, zone = entry.zone,
    demoTime = formatDemoTime(entry)
  })

  api.Log:Info(string.format("[Demo Tracker] Tracking: %s in %s (Demo: %s)",
    entry.landType, entry.zone, formatDemoTime(entry)))
  return true
end

function DemoSystem.updateEntry(entryId, updates)
  for _, entry in ipairs(demoData) do
    if entry.id == entryId then
      if updates.landType then entry.landType = updates.landType end
      if updates.zone then entry.zone = updates.zone end
      if updates.zoneId then entry.zoneId = updates.zoneId end
      if updates.notes ~= nil then entry.notes = updates.notes end
      if updates.targetName then entry.targetName = updates.targetName end
      if updates.demoStartHour then entry.demoStartHour = updates.demoStartHour end
      if updates.demoStartMin ~= nil then entry.demoStartMin = updates.demoStartMin end
      if updates.demoEndHour then entry.demoEndHour = updates.demoEndHour end
      if updates.demoEndMin ~= nil then entry.demoEndMin = updates.demoEndMin end
      if updates.demoDay then entry.demoDay = updates.demoDay end
      if updates.demoMonth then entry.demoMonth = updates.demoMonth end
      if updates.demoYear then entry.demoYear = updates.demoYear end

      -- Reset notification flags if time changed
      if updates.demoStartHour or updates.demoDay then
        entry.notified10min = false
        entry.notifiedNow = false
      end

      sortByUrgency()
      Debug.info("Demo", "Entry updated", { id = entryId })
      return true
    end
  end
  return false
end

function DemoSystem.deleteEntry(entryId)
  for i, entry in ipairs(demoData) do
    if entry.id == entryId then
      Debug.info("Demo", "Deleting entry", { id = entryId, landType = entry.landType })
      table.remove(demoData, i)
      return true
    end
  end
  return false
end

-- ==================== PERSISTENCE ====================

function DemoSystem.saveData()
  local settings = api.GetSettings("tax_tracker") or {}
  settings.demoData = demoData
  settings.demoSeq = demoSeq

  local success = pcall(function() api.SaveSettings() end)
  if success then
    Debug.info("Demo", "Saved demo data", { count = #demoData })
  else
    Debug.error("Demo", "Failed to save demo data")
  end
end

function DemoSystem.loadData()
  local settings = api.GetSettings("tax_tracker") or {}
  local loaded = settings.demoData or {}
  local loadedSeq = settings.demoSeq or 0

  demoData = {}
  for _, entry in ipairs(loaded) do
    if entry.id and entry.landType and entry.demoDay then
      -- Backward compatibility: add new notification flags if missing
      if entry.notified10min == nil then entry.notified10min = false end
      if entry.notifiedNow == nil then entry.notifiedNow = false end
      table.insert(demoData, entry)
    end
  end

  demoSeq = loadedSeq
  if demoSeq == 0 then
    for _, entry in ipairs(demoData) do
      if entry.id and entry.id > demoSeq then
        demoSeq = entry.id
      end
    end
  end

  sortByUrgency()
  Debug.info("Demo", "Loaded demo data", { count = #demoData })
end

-- ==================== 1-MINUTE CHECK CYCLE ====================

-- Queue a notification (forward-declared at top, defined here before checkDemos)
queueNotification = function(entry)
  if not notifyWin or not notifyWin:IsVisible() then
    DemoSystem.showNotification(entry)
  else
    table.insert(notifyQueue, entry)
  end
end

-- Called from UpdateSystem approximately every 1 second, but only processes every 60 seconds
function DemoSystem.checkDemos()
  -- Accumulate ~1000ms per call (UpdateSystem fires this every ~1 second)
  lastCheckTime = lastCheckTime + 1000

  if lastCheckTime < 60000 then
    return  -- Only check every 60 seconds
  end

  lastCheckTime = 0

  -- Log check cycle running
  if #demoData > 0 then
    api.Log:Info(string.format("[Demo Tracker] Checking %d demos for alerts", #demoData))
  end

  local expired = {}
  local notifying10min = {}
  local notifyingNow = {}

  for i = #demoData, 1, -1 do
    local entry = demoData[i]
    local secUntilEnd = getSecondsUntilDemoEnd(entry)
    local secUntilStart = getSecondsUntilDemo(entry)

    -- Log each entry being checked
    api.Log:Info(string.format("[Demo Tracker] Checking: %s - %d sec until start (10min=%s, now=%s)",
      entry.landType or "?", secUntilStart, tostring(entry.notified10min), tostring(entry.notifiedNow)))

    -- Check if demo window has fully passed -> delete
    if secUntilEnd <= 0 then
      table.insert(expired, entry)
      table.remove(demoData, i)
    else
      -- Check if demo starts within 10 minutes -> first alert
      if secUntilStart <= 600 and secUntilStart > 0 and not entry.notified10min then
        entry.notified10min = true
        table.insert(notifying10min, entry)
      end

      -- Check if demo is currently active -> second alert
      if secUntilStart <= 0 and secUntilEnd > 0 and not entry.notifiedNow then
        entry.notifiedNow = true
        table.insert(notifyingNow, entry)
      end
    end
  end

  -- Show 10-minute alerts
  for _, entry in ipairs(notifying10min) do
    api.Log:Info(string.format("[Demo Tracker] 10-MIN ALERT: %s in %s", entry.landType, entry.zone))
    pcall(queueNotification, entry)
  end

  -- Show NOW alerts
  for _, entry in ipairs(notifyingNow) do
    api.Log:Info(string.format("[Demo Tracker] NOW ALERT: %s in %s", entry.landType, entry.zone))
    pcall(queueNotification, entry)
  end

  -- Show expired alerts and delete
  for _, entry in ipairs(expired) do
    api.Log:Info(string.format("[Demo Tracker] EXPIRED: %s in %s", entry.landType, entry.zone))
    pcall(queueNotification, entry)
  end

  if #expired > 0 or #notifying10min > 0 or #notifyingNow > 0 then
    DemoSystem.saveData()
    return true
  end
  return false
end

-- ==================== SCREEN NOTIFICATION (tier2_sextant style) ====================

-- Create the notification window once, reuse it for all alerts
local function createNotifyWindow()
  if notifyWin then return end

  notifyWin = api.Interface:CreateWindow("DemoTrackerNotify", "Demo Alert!", 0, 0)
  notifyWin:SetExtent(380, 170)
  notifyWin:AddAnchor("CENTER", "UIParent", 0, -150)
  notifyWin:Show(false)

  -- Message label
  notifyLabel = notifyWin:CreateChildWidget("textbox", "notifyLabel", 0, true)
  notifyLabel:SetExtent(340, FONT_SIZE.LARGE * 3)
  notifyLabel:AddAnchor("CENTER", notifyWin, 0, -5)
  if notifyLabel.style then
    notifyLabel.style:SetAlign(ALIGN.CENTER)
    notifyLabel.style:SetFontSize(FONT_SIZE.MIDDLE)
  end
  pcall(function() ApplyTextColor(notifyLabel, FONT_COLOR.DEFAULT) end)
  notifyLabel:SetText("")

  -- "Show on Map" button (left side)
  notifyMapBtn = notifyWin:CreateChildWidget("button", "notifyMapBtn", 0, true)
  api.Interface:ApplyButtonSkin(notifyMapBtn, BUTTON_BASIC.DEFAULT)
  notifyMapBtn:SetText("Show on Map")
  notifyMapBtn:SetExtent(120, 28)
  notifyMapBtn:AddAnchor("BOTTOMLEFT", notifyWin, 30, -12)

  function notifyMapBtn:OnClick()
    if currentNotifyEntry then
      local lon, lat = currentNotifyEntry.coordinates and currentNotifyEntry.coordinates.lon,
                        currentNotifyEntry.coordinates and currentNotifyEntry.coordinates.lat
      local zoneId = currentNotifyEntry.zoneId or 323
      if lon and lat and api.Map and api.Map.ToggleMapWithPortal then
        local COEFF = 0.00097657363894522145695357130138029
        local function toX(dir,deg,min,sec) local x=deg+(min+(sec/60))/60; if dir=="W" then x=-x end; return (x+21)/COEFF end
        local function toY(dir,deg,min,sec) local y=deg+(min+(sec/60))/60; if dir=="S" then y=-y end; return (y+28)/COEFF end
        local x = toX(lon.dir or "E", tonumber(lon.deg or 0) or 0, tonumber(lon.min or 0) or 0, tonumber(lon.sec or 0) or 0)
        local y = toY(lat.dir or "N", tonumber(lat.deg or 0) or 0, tonumber(lat.min or 0) or 0, tonumber(lat.sec or 0) or 0)
        api.Map:ToggleMapWithPortal(zoneId, x, y, 100)
      end
    end
    notifyWin:Show(false)
    DemoSystem.showNextNotification()
  end
  notifyMapBtn:SetHandler("OnClick", notifyMapBtn.OnClick)

  -- "Dismiss" button (right side)
  notifyDismissBtn = notifyWin:CreateChildWidget("button", "notifyDismissBtn", 0, true)
  api.Interface:ApplyButtonSkin(notifyDismissBtn, BUTTON_BASIC.DEFAULT)
  notifyDismissBtn:SetText("Dismiss")
  notifyDismissBtn:SetExtent(100, 28)
  notifyDismissBtn:AddAnchor("BOTTOMRIGHT", notifyWin, -30, -12)

  function notifyDismissBtn:OnClick()
    notifyWin:Show(false)
    currentNotifyEntry = nil
    -- Show next queued notification if any
    DemoSystem.showNextNotification()
  end
  notifyDismissBtn:SetHandler("OnClick", notifyDismissBtn.OnClick)
end

-- Show the next notification from queue
function DemoSystem.showNextNotification()
  if #notifyQueue == 0 then
    currentNotifyEntry = nil
    return
  end

  local entry = table.remove(notifyQueue, 1)
  DemoSystem.showNotification(entry)
end

-- Show a screen notification for a demo entry
function DemoSystem.showNotification(entry)
  if not entry then return end

  local success, err = pcall(function()
    createNotifyWindow()
    currentNotifyEntry = entry

    local secUntil = getSecondsUntilDemo(entry)
    local timeText
    if secUntil <= 0 then
      timeText = "DEMOLITION IN PROGRESS!"
    else
      local mins = math.floor(secUntil / 60)
      timeText = string.format("Demolition starts in %d minutes!", mins)
    end

    local msg = string.format("%s\n\n%s in %s\nDemo: %02d:%02d - %02d:%02d",
      timeText,
      entry.landType or "Unknown",
      entry.zone or "Unknown Zone",
      entry.demoStartHour or 0, entry.demoStartMin or 0,
      entry.demoEndHour or 0, entry.demoEndMin or 0)

    notifyWin:SetTitle("Demo Alert!")
    notifyLabel:SetText(msg)
    notifyWin:Show(true)
  end)

  -- Log to chat for user awareness
  if success then
    api.Log:Info(string.format("[Demo Tracker] %s in %s at %02d:%02d!",
      entry.landType, entry.zone, entry.demoStartHour or 0, entry.demoStartMin or 0))
  end
end

-- ==================== UI ====================

-- Helper: create a small dropdown popup for minute values (15-min intervals)
local function createMinuteDropdown(parent, anchorWidget, id, initialVal, onSelect)
  local selectedVal = initialVal or 0
  local btn = parent:CreateChildWidget("button", id, 0, true)
  api.Interface:ApplyButtonSkin(btn, BUTTON_BASIC.DEFAULT)
  btn:SetText(string.format("%02d", selectedVal))
  btn:SetExtent(45, 28)
  btn:AddAnchor("LEFT", anchorWidget, "RIGHT", 3, 0)

  local menuWin = nil
  local menuOpen = false

  local function closeMenu()
    if menuWin then menuWin:Show(false) end
    menuOpen = false
  end

  function btn:OnClick()
    if menuOpen then closeMenu(); return end

    if not menuWin then
      menuWin = api.Interface:CreateEmptyWindow(id .. "_menu")
      menuWin:SetExtent(50, 105)
      menuWin:AddAnchor("TOPLEFT", btn, "BOTTOMLEFT", 0, 2)

      local bg = menuWin:CreateChildWidget("textbox", "bg", 0, true)
      bg:AddAnchor("TOPLEFT", menuWin, 0, 0)
      bg:AddAnchor("BOTTOMRIGHT", menuWin, 0, 0)
      bg:SetText("")
      if bg.style and bg.style.SetColor then bg.style:SetColor(0.1, 0.1, 0.15, 0.95) end
      if bg.Enable then bg:Enable(false) end

      local vals = { 0, 15, 30, 45 }
      local yOff = 5
      for _, v in ipairs(vals) do
        local item = menuWin:CreateChildWidget("button", id .. "_" .. v, 0, true)
        api.Interface:ApplyButtonSkin(item, BUTTON_BASIC.DEFAULT)
        item:SetText(string.format("%02d", v))
        item:SetExtent(40, 22)
        item:AddAnchor("TOPLEFT", menuWin, 5, yOff)
        yOff = yOff + 24

        item.val = v
        function item:OnClick()
          selectedVal = self.val
          btn:SetText(string.format("%02d", self.val))
          closeMenu()
          if onSelect then onSelect(self.val) end
        end
        item:SetHandler("OnClick", item.OnClick)
      end
    end
    menuWin:Show(true)
    menuOpen = true
  end
  btn:SetHandler("OnClick", btn.OnClick)

  btn.getVal = function() return selectedVal end
  btn.setVal = function(v)
    selectedVal = v
    btn:SetText(string.format("%02d", v))
  end
  return btn
end

function DemoSystem.buildDemoWindow()
  if demoWin and demoWin.Show then return end

  demoWin = api.Interface:CreateWindow("TaxTrackerDemo", "Demo Tracker", 0, 0)
  demoWin:SetExtent(1520, 710)
  demoWin:AddAnchor("CENTER", "UIParent", 0, 0)
  addTint(demoWin, "demoBg", 0.65, 36)
  demoWin:Show(false)

  -- ==================== HEADER SECTION ====================
  addSectionBg(demoWin, "headerBg", 10, 42, 1500, 42, 0.08, 0.12, 0.2, 0.85)

  local trackingLabel = demoWin:CreateChildWidget("label", "trackingLabel", 0, true)
  trackingLabel:SetText("Tracking: 0")
  trackingLabel:AddAnchor("TOPLEFT", demoWin, 30, 52)
  if trackingLabel.style then
    trackingLabel.style:SetFontSize(FONT_SIZE.LARGE)
    trackingLabel.style:SetColor(1, 0.85, 0.2, 1)
  end
  demoWin.trackingLabel = trackingLabel

  local expiringSoonLabel = demoWin:CreateChildWidget("label", "expiringSoonLabel", 0, true)
  expiringSoonLabel:SetText("Expiring Soon: 0")
  expiringSoonLabel:AddAnchor("TOPLEFT", demoWin, 300, 52)
  if expiringSoonLabel.style then
    expiringSoonLabel.style:SetFontSize(FONT_SIZE.LARGE)
    expiringSoonLabel.style:SetColor(0.4, 1, 0.4, 1)
  end
  demoWin.expiringSoonLabel = expiringSoonLabel

  local currentDateLabel = demoWin:CreateChildWidget("label", "currentDateLabel", 0, true)
  currentDateLabel:SetText("Today: " .. getCurrentDateString())
  currentDateLabel:AddAnchor("TOPRIGHT", demoWin, -30, 52)
  if currentDateLabel.style then
    currentDateLabel.style:SetFontSize(FONT_SIZE.LARGE)
    currentDateLabel.style:SetColor(0.7, 0.85, 1, 1)
  end
  demoWin.currentDateLabel = currentDateLabel

  -- ==================== INPUT SECTION ====================
  local inputSectionY = 90
  addSectionBg(demoWin, "inputBg", 10, inputSectionY, 1500, 110, 0.06, 0.08, 0.14, 0.6)
  addSectionTitle(demoWin, "inputTitle", "-- New Entry --", 20, inputSectionY + 4, 0.45, 0.65, 0.85)

  -- ---- ROW 1: Auto-Fill + Status + Land Type ----
  local row1Y = inputSectionY + 24

  -- "Auto-Fill from Target" button (matches land editor naming)
  local trackBtn = demoWin:CreateChildWidget("button", "trackBtn", 0, true)
  api.Interface:ApplyButtonSkin(trackBtn, BUTTON_BASIC.DEFAULT)
  trackBtn:SetText("Auto-Fill from Target")
  trackBtn:SetExtent(180, 28)
  trackBtn:AddAnchor("TOPLEFT", demoWin, 20, row1Y)

  -- Capture status display
  local captureStatusLabel = demoWin:CreateChildWidget("label", "captureStatus", 0, true)
  captureStatusLabel:SetText("Target something and click Auto-Fill")
  captureStatusLabel:AddAnchor("LEFT", trackBtn, "RIGHT", 12, 0)
  if captureStatusLabel.style then
    captureStatusLabel.style:SetFontSize(FONT_SIZE.MIDDLE)
    captureStatusLabel.style:SetColor(0.55, 0.55, 0.55, 1)
  end
  demoWin.captureStatusLabel = captureStatusLabel

  -- Land Type dropdown (right side of row 1)
  local selectedLandType = nil
  local capturedData = {}

  local landTypeLbl = demoWin:CreateChildWidget("label", "landTypeLabel", 0, true)
  landTypeLbl:SetText("Land Type:")
  landTypeLbl:AddAnchor("TOPLEFT", demoWin, 900, row1Y + 5)
  if landTypeLbl.style then
    landTypeLbl.style:SetFontSize(FONT_SIZE.MIDDLE)
    landTypeLbl.style:SetColor(0.8, 0.8, 0.8, 1)
  end

  local landTypeBtn = demoWin:CreateChildWidget("button", "landTypeBtn", 0, true)
  api.Interface:ApplyButtonSkin(landTypeBtn, BUTTON_BASIC.DEFAULT)
  landTypeBtn:SetText("Select Land Type")
  landTypeBtn:SetExtent(260, 28)
  landTypeBtn:AddAnchor("LEFT", landTypeLbl, "RIGHT", 8, 0)
  demoWin.landTypeBtn = landTypeBtn

  -- Land type popup menu
  local landTypeMenuOpen = false
  local landTypeMenuWin = nil

  local function closeLandTypeMenu()
    if landTypeMenuWin then landTypeMenuWin:Show(false) end
    landTypeMenuOpen = false
  end

  function landTypeBtn:OnClick()
    if landTypeMenuOpen then closeLandTypeMenu(); return end

    if not landTypeMenuWin then
      landTypeMenuWin = api.Interface:CreateEmptyWindow("DemoLandTypeMenu")
      landTypeMenuWin:AddAnchor("TOPLEFT", landTypeBtn, "BOTTOMLEFT", 0, 2)

      local bg = landTypeMenuWin:CreateChildWidget("textbox", "menuBg", 0, true)
      bg:AddAnchor("TOPLEFT", landTypeMenuWin, 0, 0)
      bg:AddAnchor("BOTTOMRIGHT", landTypeMenuWin, 0, 0)
      bg:SetText("")
      if bg.style and bg.style.SetColor then bg.style:SetColor(0.08, 0.08, 0.12, 0.95) end
      if bg.Enable then bg:Enable(false) end

      local landTypes = Config.getLandTypes()
      local yOff = 5
      for idx, lt in ipairs(landTypes) do
        local itemBtn = landTypeMenuWin:CreateChildWidget("button", "lt_" .. idx, 0, true)
        api.Interface:ApplyButtonSkin(itemBtn, BUTTON_BASIC.DEFAULT)
        itemBtn:SetText(lt)
        itemBtn:SetExtent(250, 22)
        itemBtn:AddAnchor("TOPLEFT", landTypeMenuWin, 5, yOff)
        yOff = yOff + 24

        itemBtn.landType = lt
        function itemBtn:OnClick()
          selectedLandType = self.landType
          landTypeBtn:SetText(self.landType)
          closeLandTypeMenu()
        end
        itemBtn:SetHandler("OnClick", itemBtn.OnClick)
      end
      landTypeMenuWin:SetExtent(260, math.min(yOff + 5, 400))
    end
    landTypeMenuWin:Show(true)
    landTypeMenuOpen = true
  end
  landTypeBtn:SetHandler("OnClick", landTypeBtn.OnClick)

  -- Auto-Fill button handler: captures position, zone, target + auto-fills land type ALWAYS
  function trackBtn:OnClick()
    capturedData = capturePlayerData()

    -- ALWAYS auto-fill land type from target (like the land editor)
    if capturedData.inferredLandType then
      selectedLandType = capturedData.inferredLandType
      landTypeBtn:SetText(capturedData.inferredLandType)
      Debug.info("Demo", "Land type auto-filled from target", { landType = capturedData.inferredLandType })
    end

    -- Build status display
    local statusParts = {}
    if capturedData.zone and capturedData.zone ~= "Unknown Zone" then
      table.insert(statusParts, capturedData.zone)
    end
    if capturedData.coordinates then
      local coordStr = formatSextantCoords(capturedData.coordinates)
      if coordStr then
        table.insert(statusParts, coordStr)
      end
    end
    if capturedData.targetName then
      table.insert(statusParts, "Target: " .. capturedData.targetName)
    end

    if #statusParts > 0 then
      captureStatusLabel:SetText(table.concat(statusParts, "  |  "))
      if captureStatusLabel.style then captureStatusLabel.style:SetColor(0.3, 1, 0.4, 1) end
    else
      captureStatusLabel:SetText("Captured (no target selected)")
      if captureStatusLabel.style then captureStatusLabel.style:SetColor(1, 0.85, 0.2, 1) end
    end
  end
  trackBtn:SetHandler("OnClick", trackBtn.OnClick)

  -- ---- ROW 2: Demo Time + Date + Notes + Buttons ----
  local row2Y = inputSectionY + 60

  -- Demo time label
  local demoTimeLbl = demoWin:CreateChildWidget("label", "demoTimeLbl", 0, true)
  demoTimeLbl:SetText("Demo Time:")
  demoTimeLbl:AddAnchor("TOPLEFT", demoWin, 20, row2Y + 5)
  if demoTimeLbl.style then
    demoTimeLbl.style:SetFontSize(FONT_SIZE.MIDDLE)
    demoTimeLbl.style:SetColor(0.8, 0.8, 0.8, 1)
  end

  -- Start Hour
  local startHourInput = gui.AddEditBox(demoWin, "startHour",
    "LEFT", demoTimeLbl, 85, -5, 35, 28, 2, "12", nil)
  demoWin.startHourInput = startHourInput

  -- ":" separator
  local sep1 = demoWin:CreateChildWidget("label", "sep1", 0, true)
  sep1:SetText(":")
  sep1:AddAnchor("LEFT", startHourInput, 38, 0)
  if sep1.style then sep1.style:SetFontSize(FONT_SIZE.LARGE); sep1.style:SetColor(0.8, 0.8, 0.8, 1) end
  demoWin.sep1 = sep1

  -- Start Minute (15-min dropdown)
  local startMinBtn = createMinuteDropdown(demoWin, sep1, "startMin", 0, nil)
  demoWin.startMinBtn = startMinBtn

  -- "-" separator
  local sep2 = demoWin:CreateChildWidget("label", "sep2", 0, true)
  sep2:SetText(" - ")
  sep2:AddAnchor("LEFT", startMinBtn, 50, 0)
  if sep2.style then sep2.style:SetFontSize(FONT_SIZE.LARGE); sep2.style:SetColor(0.6, 0.6, 0.6, 1) end
  demoWin.sep2 = sep2

  -- End Hour
  local endHourInput = gui.AddEditBox(demoWin, "endHour",
    "LEFT", sep2, 28, 0, 35, 28, 2, "13", nil)
  demoWin.endHourInput = endHourInput

  -- ":" separator
  local sep3 = demoWin:CreateChildWidget("label", "sep3", 0, true)
  sep3:SetText(":")
  sep3:AddAnchor("LEFT", endHourInput, 38, 0)
  if sep3.style then sep3.style:SetFontSize(FONT_SIZE.LARGE); sep3.style:SetColor(0.8, 0.8, 0.8, 1) end
  demoWin.sep3 = sep3

  -- End Minute (15-min dropdown)
  local endMinBtn = createMinuteDropdown(demoWin, sep3, "endMin", 0, nil)
  demoWin.endMinBtn = endMinBtn

  -- Date label
  local dateLbl = demoWin:CreateChildWidget("label", "dateLbl", 0, true)
  dateLbl:SetText("Date:")
  dateLbl:AddAnchor("LEFT", endMinBtn, 70, 0)
  if dateLbl.style then
    dateLbl.style:SetFontSize(FONT_SIZE.MIDDLE)
    dateLbl.style:SetColor(0.8, 0.8, 0.8, 1)
  end

  -- Pre-fill with current date
  local now = getCurrentDate()
  local defaultDay = now and tostring(now.day) or "1"
  local defaultMonth = now and tostring(now.month) or "1"
  local defaultYear = now and tostring(now.year) or "2026"

  local dayInput = gui.AddEditBox(demoWin, "dayInput",
    "LEFT", dateLbl, 42, 0, 30, 28, 2, defaultDay, nil)
  demoWin.dayInput = dayInput

  local dot1 = demoWin:CreateChildWidget("label", "dotSep1", 0, true)
  dot1:SetText(".")
  dot1:AddAnchor("LEFT", dayInput, 33, 0)
  if dot1.style then dot1.style:SetFontSize(FONT_SIZE.LARGE); dot1.style:SetColor(0.6, 0.6, 0.6, 1) end

  local monthInput = gui.AddEditBox(demoWin, "monthInput",
    "LEFT", dot1, 14, 0, 30, 28, 2, defaultMonth, nil)
  demoWin.monthInput = monthInput

  local dot2 = demoWin:CreateChildWidget("label", "dotSep2", 0, true)
  dot2:SetText(".")
  dot2:AddAnchor("LEFT", monthInput, 33, 0)
  if dot2.style then dot2.style:SetFontSize(FONT_SIZE.LARGE); dot2.style:SetColor(0.6, 0.6, 0.6, 1) end

  local yearInput = gui.AddEditBox(demoWin, "yearInput",
    "LEFT", dot2, 14, 0, 50, 28, 4, defaultYear, nil)
  demoWin.yearInput = yearInput

  -- Notes
  local notesLbl = demoWin:CreateChildWidget("label", "notesLbl", 0, true)
  notesLbl:SetText("Notes:")
  notesLbl:AddAnchor("LEFT", yearInput, 70, 0)
  if notesLbl.style then
    notesLbl.style:SetFontSize(FONT_SIZE.MIDDLE)
    notesLbl.style:SetColor(0.8, 0.8, 0.8, 1)
  end

  local notesInput = gui.AddEditBox(demoWin, "notesInput",
    "LEFT", notesLbl, 48, 0, 150, 28, 50, "", nil)
  demoWin.notesInput = notesInput

  -- ADD / SAVE button
  local addBtn = demoWin:CreateChildWidget("button", "addBtn", 0, true)
  api.Interface:ApplyButtonSkin(addBtn, BUTTON_BASIC.DEFAULT)
  addBtn:SetText("ADD")
  addBtn:SetExtent(70, 28)
  addBtn:AddAnchor("LEFT", notesInput, 165, 0)
  demoWin.addBtn = addBtn

  -- Cancel button (hidden by default)
  local cancelBtn = demoWin:CreateChildWidget("button", "cancelBtn", 0, true)
  api.Interface:ApplyButtonSkin(cancelBtn, BUTTON_BASIC.DEFAULT)
  cancelBtn:SetText("Cancel")
  cancelBtn:SetExtent(70, 28)
  cancelBtn:AddAnchor("LEFT", addBtn, "RIGHT", 5, 0)
  cancelBtn:Show(false)
  demoWin.cancelBtn = cancelBtn

  -- Clear All button (far right of row 2)
  local resetBtn = demoWin:CreateChildWidget("button", "resetBtn", 0, true)
  api.Interface:ApplyButtonSkin(resetBtn, BUTTON_BASIC.DEFAULT)
  resetBtn:SetText("Clear All")
  resetBtn:SetExtent(100, 28)
  resetBtn:AddAnchor("TOPRIGHT", demoWin, -16, row2Y)

  -- ==================== INPUT HELPERS ====================

  local function clearInputs()
    landTypeBtn:SetText("Select Land Type")
    selectedLandType = nil
    startHourInput:SetText("12")
    startMinBtn.setVal(0)
    endHourInput:SetText("13")
    endMinBtn.setVal(0)
    local nowDate = getCurrentDate()
    dayInput:SetText(nowDate and tostring(nowDate.day) or "1")
    monthInput:SetText(nowDate and tostring(nowDate.month) or "1")
    yearInput:SetText(nowDate and tostring(nowDate.year) or "2026")
    notesInput:SetText("")
    captureStatusLabel:SetText("Target something and click Auto-Fill")
    if captureStatusLabel.style then captureStatusLabel.style:SetColor(0.55, 0.55, 0.55, 1) end
    capturedData = {}
    editingEntryId = nil
    addBtn:SetText("ADD")
    cancelBtn:Show(false)
  end

  local function populateForEdit(entry)
    editingEntryId = entry.id
    addBtn:SetText("SAVE")
    cancelBtn:Show(true)

    selectedLandType = entry.landType
    landTypeBtn:SetText(entry.landType or "Select Land Type")

    capturedData = {
      coordinates = entry.coordinates,
      zone = entry.zone,
      zoneId = entry.zoneId,
      targetName = entry.targetName
    }

    local statusParts = {}
    if entry.zone then table.insert(statusParts, entry.zone) end
    if entry.coordinates then
      local coordStr = formatSextantCoords(entry.coordinates)
      if coordStr then
        table.insert(statusParts, coordStr)
      end
    end
    if entry.targetName and entry.targetName ~= "" then
      table.insert(statusParts, "Target: " .. entry.targetName)
    end
    if #statusParts > 0 then
      captureStatusLabel:SetText(table.concat(statusParts, "  |  "))
      if captureStatusLabel.style then captureStatusLabel.style:SetColor(0.5, 0.8, 1, 1) end
    end

    startHourInput:SetText(tostring(entry.demoStartHour or 12))
    startMinBtn.setVal(entry.demoStartMin or 0)
    endHourInput:SetText(tostring(entry.demoEndHour or 13))
    endMinBtn.setVal(entry.demoEndMin or 0)
    dayInput:SetText(tostring(entry.demoDay or 1))
    monthInput:SetText(tostring(entry.demoMonth or 1))
    yearInput:SetText(tostring(entry.demoYear or 2026))
    notesInput:SetText(entry.notes or "")
  end

  -- ==================== BUTTON HANDLERS ====================

  function addBtn:OnClick()
    if not selectedLandType then
      api.Log:Info("[Demo Tracker] Please select a land type first")
      return
    end

    local sH = tonumber(startHourInput:GetText() or "0") or 0
    local sM = startMinBtn.getVal()
    local eH = tonumber(endHourInput:GetText() or "0") or 0
    local eM = endMinBtn.getVal()
    local dd = tonumber(dayInput:GetText() or "1") or 1
    local mm = tonumber(monthInput:GetText() or "1") or 1
    local yy = tonumber(yearInput:GetText() or "2026") or 2026

    -- Basic validation
    if sH < 0 or sH > 23 or eH < 0 or eH > 23 then
      api.Log:Info("[Demo Tracker] Hours must be 0-23")
      return
    end
    if dd < 1 or dd > 31 or mm < 1 or mm > 12 then
      api.Log:Info("[Demo Tracker] Invalid date")
      return
    end

    local zone = capturedData.zone or "Unknown Zone"
    local zoneId = capturedData.zoneId or 323
    local coords = capturedData.coordinates
    local target = capturedData.targetName or ""
    local notes = notesInput:GetText() or ""

    if editingEntryId then
      DemoSystem.updateEntry(editingEntryId, {
        landType = selectedLandType,
        zone = zone, zoneId = zoneId,
        targetName = target, notes = notes,
        demoStartHour = sH, demoStartMin = sM,
        demoEndHour = eH, demoEndMin = eM,
        demoDay = dd, demoMonth = mm, demoYear = yy
      })
      api.Log:Info(string.format("[Demo Tracker] Updated: %s in %s", selectedLandType, zone))
    else
      DemoSystem.createEntry(selectedLandType, zone, zoneId, coords, target,
        sH, sM, eH, eM, dd, mm, yy, notes)
    end

    if demoItemList then demoItemList:UpdateData(demoData) end
    DemoSystem.updateStats()
    DemoSystem.saveData()
    clearInputs()
  end
  addBtn:SetHandler("OnClick", addBtn.OnClick)

  function cancelBtn:OnClick() clearInputs() end
  cancelBtn:SetHandler("OnClick", cancelBtn.OnClick)

  function resetBtn:OnClick()
    if #demoData > 0 then
      api.Log:Info(string.format("[Demo Tracker] Cleared all %d entries", #demoData))
      demoData = {}
      demoSeq = 0
      if demoItemList then demoItemList:UpdateData(demoData) end
      DemoSystem.updateStats()
      DemoSystem.saveData()
    end
  end
  resetBtn:SetHandler("OnClick", resetBtn.OnClick)

  -- ==================== LIST SECTION ====================
  local listSectionY = 208
  addSectionTitle(demoWin, "listTitle", "-- Tracked Demos --", 20, listSectionY - 6, 0.45, 0.65, 0.85)

  local columns = {
    { name = "Demo Window", field = "demoStartHour", width = 230,
      setFunc = function(s, i, set)
        if set then
          local display = formatDemoTime(i)
          s:SetText(display)
          local color = getDemoColor(i)
          if s.style and s.style.SetColor then
            s.style:SetColor(color[1], color[2], color[3], color[4])
          end
        end
      end },
    { name = "Status", field = "status", width = 100,
      setFunc = function(s, i, set)
        if set then
          local status = formatTimeUntil(i)
          s:SetText(status)
          local color = getDemoColor(i)
          if s.style and s.style.SetColor then
            s.style:SetColor(color[1], color[2], color[3], color[4])
          end
        end
      end },
    { name = "Land Type", field = "landType", width = 200,
      setFunc = function(s, i, set)
        if set then
          s:SetText(i.landType or "")
          if s.style and s.style.SetColor then
            s.style:SetColor(0.9, 0.9, 0.9, 1)
          end
        end
      end },
    { name = "Zone", field = "zone", width = 150,
      setFunc = function(s, i, set)
        if set then
          s:SetText(i.zone or "")
          if s.style and s.style.SetColor then
            s.style:SetColor(0.7, 0.85, 1, 1)
          end
        end
      end },
    { name = "Target", field = "targetName", width = 150,
      setFunc = function(s, i, set)
        if set then
          s:SetText(i.targetName or "")
          if s.style and s.style.SetColor then
            s.style:SetColor(0.85, 0.85, 0.7, 1)
          end
        end
      end },
    { name = "Notes", field = "notes", width = 130,
      setFunc = function(s, i, set)
        if set then
          s:SetText(i.notes or "")
          if s.style and s.style.SetColor then
            s.style:SetColor(0.65, 0.65, 0.65, 1)
          end
        end
      end },
    { name = "Actions", width = 200, disableSort = true,
      setFunc = function(sub, info, set)
        if sub.mapBtn then sub.mapBtn:Show(set) end
        if sub.editBtn then sub.editBtn:Show(set) end
        if sub.delBtn then sub.delBtn:Show(set) end
        -- Store current row data on cell so button handlers always get the right entry
        sub.rowData = info
      end,
      layoutFunc = function(list, row, col, cell)
        -- Map icon button (same as saved lands list)
        local mapBtn = cell:CreateChildWidget("button", cell:GetId() .. ".map", 0, true)
        mapBtn:AddAnchor("LEFT", cell, 2, 0)
        api.Interface:ApplyButtonSkin(mapBtn, BUTTON_CONTENTS.MAP_OPEN)
        mapBtn:SetExtent(24, 24)

        function mapBtn:OnClick()
          local d = cell.rowData
          if not d then return end
          local lon, lat = d.coordinates and d.coordinates.lon, d.coordinates and d.coordinates.lat
          local zoneId = d.zoneId or 323

          if lon and lat and api.Map and api.Map.ToggleMapWithPortal then
            local COEFF = 0.00097657363894522145695357130138029
            local function toX(dir,deg,min,sec) local x=deg+(min+(sec/60))/60; if dir=="W" then x=-x end; return (x+21)/COEFF end
            local function toY(dir,deg,min,sec) local y=deg+(min+(sec/60))/60; if dir=="S" then y=-y end; return (y+28)/COEFF end
            local x = toX(lon.dir or "E", tonumber(lon.deg or 0) or 0, tonumber(lon.min or 0) or 0, tonumber(lon.sec or 0) or 0)
            local y = toY(lat.dir or "N", tonumber(lat.deg or 0) or 0, tonumber(lat.min or 0) or 0, tonumber(lat.sec or 0) or 0)
            api.Map:ToggleMapWithPortal(zoneId, x, y, 100)
          end
        end
        mapBtn:SetHandler("OnClick", mapBtn.OnClick)
        cell.mapBtn = mapBtn

        local editBtn = cell:CreateChildWidget("button", cell:GetId() .. ".edit", 0, true)
        api.Interface:ApplyButtonSkin(editBtn, BUTTON_BASIC.DEFAULT)
        editBtn:SetText("Edit")
        editBtn:SetExtent(55, 22)
        editBtn:AddAnchor("LEFT", mapBtn, "RIGHT", 5, 0)

        function editBtn:OnClick()
          local d = cell.rowData
          if d then populateForEdit(d) end
        end
        editBtn:SetHandler("OnClick", editBtn.OnClick)
        cell.editBtn = editBtn

        local delBtn = cell:CreateChildWidget("button", cell:GetId() .. ".del", 0, true)
        api.Interface:ApplyButtonSkin(delBtn, BUTTON_BASIC.DEFAULT)
        delBtn:SetText("Delete")
        delBtn:SetExtent(60, 22)
        delBtn:AddAnchor("LEFT", editBtn, "RIGHT", 5, 0)

        function delBtn:OnClick()
          local d = cell.rowData
          if d then
            DemoSystem.deleteEntry(d.id)
            if demoItemList then demoItemList:UpdateData(demoData) end
            DemoSystem.updateStats()
            DemoSystem.saveData()
            if editingEntryId == d.id then clearInputs() end
          end
        end
        delBtn:SetHandler("OnClick", delBtn.OnClick)
        cell.delBtn = delBtn

        mapBtn:Show(false)
        editBtn:Show(false)
        delBtn:Show(false)
      end }
  }

  demoItemList = gui.AddScrollList(
    demoWin, "demoItemList", columns,
    { point = "TOPLEFT", relativeTo = demoWin, offsetX = 10, offsetY = listSectionY + 12 },
    { width = 1490, height = 420 },
    { listType = 3, rowCount = 16, columnHeight = 26, enableColumns = true }
  )

  demoItemList:UpdateData(demoData)

  -- ==================== STATS ====================
  function DemoSystem.updateStats()
    if not demoWin then return end

    local trackCount = #demoData
    local expiringSoonCount = 0

    for _, entry in ipairs(demoData) do
      local secUntil = getSecondsUntilDemo(entry)
      if secUntil > 0 and secUntil <= 3600 then
        expiringSoonCount = expiringSoonCount + 1
      end
    end

    if demoWin.trackingLabel then
      demoWin.trackingLabel:SetText("Tracking: " .. trackCount)
    end
    if demoWin.expiringSoonLabel then
      demoWin.expiringSoonLabel:SetText("Expiring Soon: " .. expiringSoonCount)
      if demoWin.expiringSoonLabel.style then
        if expiringSoonCount > 0 then
          demoWin.expiringSoonLabel.style:SetColor(1, 0.4, 0.2, 1)
        else
          demoWin.expiringSoonLabel.style:SetColor(0.4, 1, 0.4, 1)
        end
      end
    end
    if demoWin.currentDateLabel then
      demoWin.currentDateLabel:SetText("Today: " .. getCurrentDateString())
    end
  end

  DemoSystem.updateStats()
end

-- ==================== WINDOW MANAGEMENT ====================

function DemoSystem.showDemoWindow()
  if not demoWin then
    DemoSystem.buildDemoWindow()
    if demoWin then demoWin:Show(true); return end
  else
    demoWin:Show(true)
  end
end

function DemoSystem.hideDemoWindow()
  if demoWin then demoWin:Show(false) end
end

-- ==================== UPDATE (called from UpdateSystem) ====================

function DemoSystem.updateDemoList()
  -- Run the 1-minute check cycle (handles notifications + expiry)
  local dataChanged = DemoSystem.checkDemos()

  -- Only update UI when window is visible
  if demoWin and demoWin:IsVisible() and demoItemList then
    pcall(function()
      sortByUrgency()
      demoItemList:UpdateData(demoData)
      DemoSystem.updateStats()
    end)
  end
end

-- ==================== LIFECYCLE ====================

function DemoSystem.initialize()
  DemoSystem.loadData()
  api.Log:Info(string.format("[Demo Tracker] System initialized (%d entries)", #demoData))
  return true
end

function DemoSystem.cleanup()
  DemoSystem.saveData()
  if demoWin then demoWin:Show(false) end
  if notifyWin then notifyWin:Show(false) end
  notifyQueue = {}
  currentNotifyEntry = nil
  api.Log:Info("[Demo Tracker] System cleaned up")
end

return DemoSystem
