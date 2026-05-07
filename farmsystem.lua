local api = require("api")

local FarmSystem = {}
local trackedLands = {}

-- ============================================================
-- CONSTANTS
-- ============================================================

local SETTINGS_KEY      = "farmTrackerSettings"
local ALL_FARMS_KEY     = "farmTrackerData"

local MAIN_W, MAIN_H     = 760, 470
local DETAIL_W, DETAIL_H = 760, 430

-- Detail window layout
local DETAIL_LIST_Y        = 66   -- top of doodad list content
local DETAIL_ROWS_PER_PAGE = 10
local DETAIL_NAME_X        = 37
local DETAIL_NAME_W        = 390
local DETAIL_QTY_X         = 442
local DETAIL_QTY_W         = 36
local DETAIL_EARLIEST_X    = 486
local DETAIL_TIME_W        = 100
local DETAIL_LATEST_X      = 596

-- ============================================================
-- STATE
-- ============================================================

local farms    = {}
local settings = { whitelist = {}, groupBy = "name" }
local adjustedTime = nil
local adjustedTimeForDedup = nil
local formatTime = nil
local timerSessionId = nil
local timerRuntimeAnchors = {}

-- Main window
local mainWin
local mainListContent
local mainListRows      = {}
local mainListTimeLbls  = {}
local mainListRebuildId = 0
local currentPage       = 1
local ROWS_PER_PAGE     = 7
local filterText        = ""
local filterDebounce    = false

-- Detail window
local detailWin
local detailFarmId    = nil
local detailPage      = 1
local detailRebuildId = 0
local detailTimeLbls  = {}
local expandedGroups  = {}  -- keyed by group key, bool
local lastDoodadInfo  = nil
local doodadListener  = nil

-- Filter window (per-farm)
local filterWin       = nil
local filterRebuildId = 0
local filterPlayerPage = 1
local filterEntityPage = 1

-- Settings window
local settingsWin     = nil
local settingsCooledSpotLbl = nil
local settingsSpotNameEdit = nil
local farmMinuteReminderWin = nil
local farmMinuteReminderShown = {}
local spotListWin = nil
local spotListRows = {}
local spotListPage = 1
local SPOT_LIST_ROWS = 9
local floatingBtn     = nil
local floatingAutoBtn = nil
local floatingBtnSeq  = 0
local updateHandler    = nil
local autotrackerWin   = nil
local autotrackerRows  = {}
local autotrackerTimeLbls = {}
local autotrackerFarmIds = {}
local autotrackerFarmOrder = {}
local autotrackerExpandedGroups = {}
local autotrackerPage = 1
local autotrackerBtn   = nil
local externalAutotrackerButtons = {}
local doodadListenerRegistered = false

-- Saved-land picker shown when a hovered timer needs to be attached to a
-- Tax Tracker land.
local landPickerWin    = nil
local landPickerRows   = {}
local landPickerPage   = 1
local landPickerRebuildId = 0
local landPickerExpandedZones = {}
local pendingDoodadInfo = nil
local LAND_PICKER_ROWS_PER_PAGE = 8

local rebuildAutotrackerWindow
local showAutotrackerWindow
local rebuildFarmList
local closeDetailWindow
local rebuildDoodadList
local openFilterWindow
local toggleMainWindow
local openLandPickerWindow
local getFarmById


-- ============================================================
-- UTILITY
-- ============================================================

local zone_name_list = (function()
    local ok, z = pcall(require, "tax_tracker/zone_name_list")
    return (ok and z) or {}
end)()

local function zoneName(id)
    if type(id) == "string" and id ~= "" then return id end
    local n = tonumber(id)
    if not n then return "Unknown" end
    local name = zone_name_list[n]
    if type(name) == "string" and name ~= "" then return name end
    return "Zone " .. tostring(n)
end

local function fitText(value, maxLen)
    local text = tostring(value or "")
    if maxLen and maxLen > 3 and string.len(text) > maxLen then
        return string.sub(text, 1, maxLen - 3) .. "..."
    end
    return text
end

local function addWindowTint(win, alpha)
    if not win or not win.CreateColorDrawable then return end
    local bg = win:CreateColorDrawable(0, 0, 0, alpha or 0.55, "background")
    bg:AddAnchor("TOPLEFT", win, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", win, 0, 0)
    bg:Show(true)
end

local function newId()
    return "farm_" .. tostring(api.Time:GetUiMsec()):gsub("%.", "")
end

local function log(msg)
    if api and api.Log and api.Log.Info then
        api.Log:Info("[TaxTracker Farm] " .. tostring(msg))
    end
end

local function getTimerSessionId()
    if not timerSessionId then
        local ok, localTime = pcall(function() return api.Time:GetLocalTime() end)
        local okMs, uiMs = pcall(function() return api.Time:GetUiMsec() end)
        timerSessionId = tostring(ok and localTime or "session") .. ":" .. tostring(okMs and uiMs or 0)
    end
    return timerSessionId
end

-- ============================================================
-- SEXTANT PARSING
-- ============================================================

local function parsePlayerSextants()
    local ok, r1, r2, r3, r4, r5, r6, r7, r8 = pcall(api.Map.GetPlayerSextants, api.Map)
    if not ok then return nil end
    if type(r1) == "table" and r2 == nil then
        local t = r1
        if t.longitude or t.deg_long then
            return t.longitude or "E", tonumber(t.deg_long) or 0, tonumber(t.min_long) or 0, tonumber(t.sec_long) or 0,
                   t.latitude  or "N", tonumber(t.deg_lat)  or 0, tonumber(t.min_lat)  or 0, tonumber(t.sec_lat)  or 0
        end
        if type(t.longitude) == "table" and type(t.latitude) == "table" then
            local L, A = t.longitude, t.latitude
            return L.dir or "E", tonumber(L.deg) or 0, tonumber(L.min) or 0, tonumber(L.sec) or 0,
                   A.dir or "N", tonumber(A.deg) or 0, tonumber(A.min) or 0, tonumber(A.sec) or 0
        end
        if t.longitudeDir then
            return t.longitudeDir or "E", tonumber(t.longitudeDeg) or 0, tonumber(t.longitudeMin) or 0, tonumber(t.longitudeSec) or 0,
                   t.latitudeDir  or "N", tonumber(t.latitudeDeg)  or 0, tonumber(t.latitudeMin)  or 0, tonumber(t.latitudeSec)  or 0
        end
        if type(t[1]) == "string" and type(t[2]) == "number" then
            return t[1], tonumber(t[2]) or 0, tonumber(t[3]) or 0, tonumber(t[4]) or 0,
                   t[5], tonumber(t[6]) or 0, tonumber(t[7]) or 0, tonumber(t[8]) or 0
        end
        return nil
    end
    if type(r1) == "string" and type(r2) == "number" and type(r5) == "string" and type(r6) == "number" then
        return r1, tonumber(r2) or 0, tonumber(r3) or 0, tonumber(r4) or 0,
               r5, tonumber(r6) or 0, tonumber(r7) or 0, tonumber(r8) or 0
    end
    return nil
end

local function dmsToSigned(dir, d, m, s)
    local val = (tonumber(d) or 0) + ((tonumber(m) or 0) / 60) + ((tonumber(s) or 0) / 3600)
    if dir == "W" or dir == "S" then val = -val end
    return val
end

local _coef = 0.00097657363894522145695357130138029
local function lonLatToWorldXY(lon, lat)
    return (lon + 21) / _coef, (lat + 28) / _coef
end

local function capturePlayerPosition()
    local ew, ld, lm, ls, ns, pd, pm, ps = parsePlayerSextants()
    if not ew then
        local ok, ax, ay, az = pcall(api.Unit.UnitWorldPosition, api.Unit, "player")
        if not ok then return nil end
        if type(ax) == "table" then ax, ay, az = ax.x or ax[1] or 0, ax.y or ax[2] or 0, ax.z or ax[3] or 0 end
        local zoneGroup = (pcall(api.Unit.GetCurrentZoneGroup, api.Unit) and api.Unit:GetCurrentZoneGroup()) or 0
        return { sextants="", worldX=tonumber(ax) or 0, worldY=tonumber(ay) or 0, worldZ=tonumber(az) or 0, zone=zoneGroup }
    end
    local lon = dmsToSigned(ew, ld, lm, ls)
    local lat = dmsToSigned(ns, pd, pm, ps)
    local wx, wy = lonLatToWorldXY(lon, lat)
    local ok, ax, ay, az = pcall(api.Unit.UnitWorldPosition, api.Unit, "player")
    if not ok then ax, ay, az = 0, 0, 0 end
    if type(ax) == "table" then ax, ay, az = ax.x or ax[1] or 0, ax.y or ax[2] or 0, ax.z or ax[3] or 0 end
    local wz = (tonumber(az) or 0) - 1.4
    local zoneGroup = (pcall(api.Unit.GetCurrentZoneGroup, api.Unit) and api.Unit:GetCurrentZoneGroup()) or 0
    local sext = string.format("%s %d° %d' %d\", %s %d° %d' %d\"", ew, ld, lm, ls, ns, pd, pm, ps)
    return { sextants=sext, worldX=wx, worldY=wy, worldZ=wz, zone=zoneGroup }
end

-- ============================================================
-- FILE I/O
-- ============================================================

local function loadSettings()
    local addonSettings = api.GetSettings("tax_tracker") or {}
    local s = addonSettings[SETTINGS_KEY]
    if type(s) == "table" then
        settings = s
    end
    if not settings.groupBy         then settings.groupBy = "name" end
    if not settings.scanModifier    then settings.scanModifier = "any" end
    if settings.showFloatingBtn == nil then settings.showFloatingBtn = false end
    if settings.autotrackerEnabled == nil then settings.autotrackerEnabled = false end
    if settings.farmMinuteReminderEnabled == nil then settings.farmMinuteReminderEnabled = true end
    if type(settings.cooledTreeSpots) ~= "table" then settings.cooledTreeSpots = {} end
    if not settings.floatingBtnX    then settings.floatingBtnX = 200 end
    if not settings.floatingBtnY    then settings.floatingBtnY = 200 end
end

local function saveSettings()
    local addonSettings = api.GetSettings("tax_tracker") or {}
    addonSettings[SETTINGS_KEY] = settings
    pcall(function() api.SaveSettings() end)
end

local function saveAllFarmsData()
    local addonSettings = api.GetSettings("tax_tracker") or {}
    addonSettings[ALL_FARMS_KEY] = farms
    pcall(function() api.SaveSettings() end)
end

local function saveFarm(farm)
    local found = false
    for i, f in ipairs(farms) do
        if f.id == farm.id then farms[i] = farm; found = true; break end
    end
    if not found then table.insert(farms, farm) end
    saveAllFarmsData()
end

local function prepareLoadedFarmTimers()
    for _, farm in ipairs(farms or {}) do
        for idx, entry in ipairs(farm.doodads or {}) do
            entry._runtimeKey = tostring(farm.id or "")
                .. ":" .. tostring(idx)
                .. ":" .. tostring(entry.expiryUnix or "")
                .. ":" .. tostring(entry.name or "")
                .. ":" .. tostring(entry.owner or "")
        end
    end
end

local function loadAllFarms()
    farms = {}
    local addonSettings = api.GetSettings("tax_tracker") or {}
    local data = addonSettings[ALL_FARMS_KEY]
    if type(data) == "table" then
        for i = #data, 1, -1 do
            local f = data[i]
            if type(f) == "table" and f.id then
                table.insert(farms, f)
            end
        end
    end
    prepareLoadedFarmTimers()
end

local function createFarm(name, posData)
    local id = newId()
    local farm = {
        id=id, name=name,
        zone     = posData and posData.zone     or 0,
        sextants = posData and posData.sextants or "",
        worldX   = posData and posData.worldX   or 0,
        worldY   = posData and posData.worldY   or 0,
        worldZ   = posData and posData.worldZ   or 0,
        needsPost=false, doodads={},
    }
    table.insert(farms, 1, farm)
    saveAllFarmsData()
    return farm
end

local function savedLandCoordsToPosition(land)
    local coords = land and land.coords
    if not coords or not coords.lon or not coords.lat then
        return {
            sextants = land and land.sextants or "",
            worldX = land and land.worldX or 0,
            worldY = land and land.worldY or 0,
            worldZ = land and land.worldZ or 0,
            zone = land and (land.zoneName or land.zone) or "Unknown",
        }
    end

    local lon, lat = coords.lon, coords.lat
    local ew = lon.dir or "E"
    local ns = lat.dir or "N"
    local ld, lm, ls = tonumber(lon.deg) or 0, tonumber(lon.min) or 0, tonumber(lon.sec) or 0
    local pd, pm, ps = tonumber(lat.deg) or 0, tonumber(lat.min) or 0, tonumber(lat.sec) or 0
    local worldX, worldY = lonLatToWorldXY(dmsToSigned(ew, ld, lm, ls), dmsToSigned(ns, pd, pm, ps))
    local sext = string.format("%s %d° %d' %d\", %s %d° %d' %d\"", ew, ld, lm, ls, ns, pd, pm, ps)
    return {
        sextants = sext,
        worldX = worldX,
        worldY = worldY,
        worldZ = 0,
        zone = land.zoneName or land.zone or "Unknown",
    }
end

local function getFarmByLandId(landId)
    if landId == nil then return nil end
    for _, f in ipairs(farms) do
        if tostring(f.landId or "") == tostring(landId) then return f end
    end
    return nil
end

local function ensureFarmForLand(land)
    if not land then return nil end
    local landId = land.id or land.name
    local existing = getFarmByLandId(landId)
    if existing then
        existing.name = land.name or existing.name
        existing.zone = land.zoneName or land.zone or existing.zone
        return existing
    end

    local pos = savedLandCoordsToPosition(land)
    local farm = createFarm(land.name or "Unnamed Land", pos)
    farm.landId = landId
    farm.landName = land.name
    saveFarm(farm)
    return farm
end

local function isCooledTreeInfo(info)
    if not info or not info.name then return false end
    return tostring(info.name):lower():find("cooled tree trunk", 1, true) ~= nil
end

local function ensureCooledTreeSpots()
    if type(settings.cooledTreeSpots) ~= "table" then settings.cooledTreeSpots = {} end
    return settings.cooledTreeSpots
end

local function distance2(a, b)
    local dx = (tonumber(a.worldX) or 0) - (tonumber(b.worldX) or 0)
    local dy = (tonumber(a.worldY) or 0) - (tonumber(b.worldY) or 0)
    return dx * dx + dy * dy
end

local function makeCooledTreeSpot(pos, customName)
    local spots = ensureCooledTreeSpots()
    local zone = zoneName(pos.zone)
    local name = customName
    if not name or name == "" then
        name = string.format("Cooled Tree Trunk %s #%d", zone, #spots + 1)
    end
    local spot = {
        id = "cooled_tree_" .. tostring(api.Time:GetUiMsec()):gsub("%.", ""),
        name = name,
        zone = pos.zone,
        zoneName = zone,
        coords = nil,
        sextants = pos.sextants or "",
        worldX = pos.worldX or 0,
        worldY = pos.worldY or 0,
        worldZ = pos.worldZ or 0,
        isCooledTreeSpot = true,
    }
    table.insert(spots, spot)
    saveSettings()
    return spot
end

local function spotToLand(spot)
    return {
        id = spot.id,
        name = spot.name or "Cooled Tree Trunk",
        zone = spot.zoneName or spot.zone,
        zoneName = spot.zoneName or zoneName(spot.zone),
        coords = spot.coords,
        isCooledTreeSpot = true,
        sextants = spot.sextants,
        worldX = spot.worldX,
        worldY = spot.worldY,
        worldZ = spot.worldZ,
    }
end

local function ensureFarmForCooledTreeSpot(spot)
    local land = spotToLand(spot)
    local existing = getFarmByLandId(land.id)
    if existing then
        existing.name = land.name
        existing.zone = land.zoneName or existing.zone
        existing.isCooledTreeSpot = true
        return existing
    end

    local farm = createFarm(land.name, {
        zone = land.zoneName or land.zone,
        sextants = land.sextants or "",
        worldX = land.worldX or 0,
        worldY = land.worldY or 0,
        worldZ = land.worldZ or 0,
    })
    farm.landId = land.id
    farm.landName = land.name
    farm.isCooledTreeSpot = true
    saveFarm(farm)
    return farm
end

local function farmEarliestTime(farm)
    if not adjustedTime or not formatTime then return "-" end
    local earliest = nil
    for _, d in ipairs(farm and farm.doodads or {}) do
        local t = adjustedTime(d)
        if earliest == nil or t < earliest then earliest = t end
    end
    if earliest == nil then return "-" end
    return formatTime(earliest)
end

local function updateMainListTimeLabels()
    if not (mainWin and mainWin:IsVisible()) then return end
    for _, item in ipairs(mainListTimeLbls) do
        if item and item.lbl and item.farmId then
            local farm = getFarmById(item.farmId)
            item.lbl:SetText(farmEarliestTime(farm))
        end
    end
end

local function getFarmReminderCandidates(thresholdSecs)
    local found = {}
    for _, farm in ipairs(farms or {}) do
        local earliest = nil
        for _, d in ipairs(farm.doodads or {}) do
            local remaining = adjustedTime(d)
            if remaining <= thresholdSecs then
                if earliest == nil or remaining < earliest then earliest = remaining end
            end
        end
        if earliest ~= nil then
            table.insert(found, { farm=farm, remaining=earliest })
        end
    end
    table.sort(found, function(a, b) return (a.remaining or 0) < (b.remaining or 0) end)
    return found
end

local function showFarmMinuteReminder(items)
    if not items or #items == 0 then return end
    if not farmMinuteReminderWin then
        farmMinuteReminderWin = api.Interface:CreateWindow("tax_tracker_farm_minute_reminder", "Farm Reminder", 360, 180)
        farmMinuteReminderWin:AddAnchor("CENTER", "UIParent", 0, -120)
        farmMinuteReminderWin:SetCloseOnEscape(true)
        farmMinuteReminderWin:SetHandler("OnCloseByEsc", function() farmMinuteReminderWin:Show(false) end)

        local bg = farmMinuteReminderWin:CreateColorDrawable(0, 0, 0, 0.62, "background")
        bg:AddAnchor("TOPLEFT", farmMinuteReminderWin, 8, 36)
        bg:AddAnchor("BOTTOMRIGHT", farmMinuteReminderWin, -8, -8)
        bg:Show(true)

        local text = farmMinuteReminderWin:CreateChildWidget("textbox", "farm_minute_text", 0, true)
        text:SetExtent(330, 88)
        text:AddAnchor("TOPLEFT", farmMinuteReminderWin, 16, 48)
        if text.style then
            text.style:SetFontSize(FONT_SIZE.MIDDLE or 16)
            text.style:SetAlign(ALIGN.TOP_LEFT)
        end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(text, FONT_COLOR.DEFAULT) end
        text:Show(true)
        farmMinuteReminderWin._text = text

        local closeBtn = farmMinuteReminderWin:CreateChildWidget("button", "farm_minute_close", 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(closeBtn, BUTTON_BASIC.DEFAULT) end
        closeBtn:SetExtent(80, 26)
        closeBtn:AddAnchor("BOTTOM", farmMinuteReminderWin, 0, -14)
        closeBtn:SetText("OK")
        function closeBtn:OnClick() farmMinuteReminderWin:Show(false) end
        closeBtn:SetHandler("OnClick", closeBtn.OnClick)
        closeBtn:Show(true)
    end

    local lines = {}
    table.insert(lines, string.format("%d farm%s about to finish:", #items, #items == 1 and "" or "s"))
    for i, item in ipairs(items) do
        if i > 5 then
            table.insert(lines, string.format("...and %d more", #items - 5))
            break
        end
        table.insert(lines, string.format("%s - %s", item.farm.name or "Farm", formatTime(item.remaining)))
    end
    if farmMinuteReminderWin._text then
        farmMinuteReminderWin._text:SetText(table.concat(lines, "\n"))
    end
    farmMinuteReminderWin:SetExtent(360, math.max(160, 96 + (math.min(#items, 5) * 20)))
    farmMinuteReminderWin:Show(true)
end

local function updateFarmMinuteReminders()
    if not settings.farmMinuteReminderEnabled then return end
    local due = {}
    for _, farm in ipairs(farms or {}) do
        local earliest = nil
        local reminderKey = nil
        for _, d in ipairs(farm.doodads or {}) do
            local remaining = adjustedTime(d)
            if remaining > 0 and remaining <= 60 then
                local key = tostring(farm.id) .. ":" .. tostring(d.expiryUnix or d.captureUiMsec or d.name)
                if not farmMinuteReminderShown[key] then
                    if earliest == nil or remaining < earliest then
                        earliest = remaining
                        reminderKey = key
                    end
                end
            end
        end
        if earliest ~= nil and reminderKey then
            farmMinuteReminderShown[reminderKey] = true
            table.insert(due, { farm=farm, remaining=earliest })
        end
    end
    if #due > 0 then showFarmMinuteReminder(due) end
end

local function findNearestCooledTreeSpot(pos)
    local best, bestD2
    for _, spot in ipairs(ensureCooledTreeSpots()) do
        if spot and spot.worldX and spot.worldY then
            local sameZone = not pos.zone or not spot.zone or tostring(spot.zone) == tostring(pos.zone)
                          or (spot.zoneName and spot.zoneName == zoneName(pos.zone))
            if sameZone then
                local d2 = distance2(spot, pos)
                if not bestD2 or d2 < bestD2 then
                    best, bestD2 = spot, d2
                end
            end
        end
    end
    return best, bestD2
end

local function deleteFarm(farmId)
    for i, f in ipairs(farms) do
        if f.id == farmId then table.remove(farms, i); break end
    end
    autotrackerFarmIds[farmId] = nil
    local kept = {}
    for _, id in ipairs(autotrackerFarmOrder) do
        if id ~= farmId then table.insert(kept, id) end
    end
    autotrackerFarmOrder = kept
    saveAllFarmsData()
    if autotrackerWin then rebuildAutotrackerWindow() end
end

getFarmById = function(farmId)
    for _, f in ipairs(farms) do
        if f.id == farmId then return f end
    end
    return nil
end

-- ============================================================
-- DOODAD HELPERS
-- ============================================================

formatTime = function(secs)
    if secs <= 0 then
        local ago = math.abs(secs)
        if ago < 60 then return string.format("Done - %ds ago", ago) end
        local d = math.floor(ago / 86400)
        local h = math.floor((ago % 86400) / 3600)
        local m = math.floor((ago % 3600) / 60)
        if d > 0 then return string.format("Done - %dd %dh ago", d, h) end
        if h > 0 then return string.format("Done - %dh %dm ago", h, m) end
        return string.format("Done - %dm ago", m)
    end
    local d = math.floor(secs / 86400)
    local h = math.floor((secs % 86400) / 3600)
    local m = math.floor((secs % 3600) / 60)
    local s = secs % 60
    if d > 0 then return string.format("%dd %dh %dm %ds", d, h, m, s) end
    if h > 0 then return string.format("%dh %dm %ds", h, m, s) end
    if m > 0 then return string.format("%dm %ds", m, s) end
    return string.format("%ds", s)
end

-- Convert a calendar date to Unix timestamp (seconds since 1970-01-01 UTC)
local function dateToUnix(year, month, day, hour, min, sec)
    -- Days in each month (non-leap)
    local days_in_month = {31,28,31,30,31,30,31,31,30,31,30,31}
    local function isLeap(y)
        return (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
    end
    -- Count days from epoch to start of year
    local days = 0
    for y = 1970, year - 1 do
        days = days + (isLeap(y) and 366 or 365)
    end
    -- Add days for months in current year
    for m = 1, month - 1 do
        days = days + days_in_month[m]
        if m == 2 and isLeap(year) then days = days + 1 end
    end
    -- Add days in current month
    days = days + (day - 1)
    return days * 86400 + hour * 3600 + min * 60 + sec
end

-- UTC offset hardcoded to -4 (EDT). TimeToDate returns local time.
local utcOffset = 5 * 3600

local function nowUnix()
    local t = api.Time:TimeToDate(api.Time:GetLocalTime())
    return dateToUnix(t.year, t.month, t.day, t.hour, t.minute, t.second) + utcOffset
end

-- Convert a TimeToDate table to total seconds (day*86400 + h*3600 + m*60 + s)
local function timeToSecs(t)
    return (t.day or 0)*86400 + (t.hour or 0)*3600 + (t.minute or 0)*60 + (t.second or 0)
end

-- Add displayTime seconds to a {day,hour,min,sec} table, returns new components
local function addSeconds(t, secs)
    local s = t.sec + secs
    local m = t.min + math.floor(s / 60)
    s = s % 60
    local h = t.hour + math.floor(m / 60)
    m = m % 60
    local d = t.day + math.floor(h / 24)
    h = h % 24

    -- Days per month (will be filled in with year/month from caller)
    local function daysInMonth(month, year)
        local days = {31,28,31,30,31,30,31,31,30,31,30,31}
        if month == 2 and (year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)) then
            return 29
        end
        return days[month] or 30
    end

    local month = t.month or 1
    local year  = t.year  or 2026

    while d > daysInMonth(month, year) do
        d = d - daysInMonth(month, year)
        month = month + 1
        if month > 12 then month = 1; year = year + 1 end
    end

    return { day=d, hour=h, min=m, sec=math.floor(s), month=month, year=year }
end

-- Convert expiry components to Unix timestamp using current time as anchor
-- adjustedTime() tells us seconds until expiry; add that to current Unix time
local function expiryToUnix(entry)
    if entry.expiryUnix then
        return tonumber(entry.expiryUnix)
    end
    -- Legacy fallback
    local remaining = adjustedTime and adjustedTime(entry) or 0
    return math.floor(nowUnix() + remaining)
end

adjustedTime = function(entry)
    if not entry then return 0 end

    local nowMs = api.Time:GetUiMsec()

    -- Original Farm Tracker path, but only for entries captured in this addon
    -- session. Old saved UiMsec values belong to previous client uptimes.
    if entry.captureSession == getTimerSessionId() and entry.captureUiMsec and entry.displayTime then
        if nowMs >= entry.captureUiMsec then
            local remainingMs = (entry.captureUiMsec + entry.displayTime * 1000) - nowMs
            return math.ceil(remainingMs / 1000)
        end
    end

    local expiryUnix = tonumber(entry.expiryUnix)
    if expiryUnix then
        local key = entry._runtimeKey or tostring(expiryUnix) .. ":" .. tostring(entry.name or "") .. ":" .. tostring(entry.owner or "")
        local anchor = timerRuntimeAnchors[key]
        if not anchor then
            anchor = {
                displayTime = expiryUnix - nowUnix(),
                captureUiMsec = nowMs,
            }
            timerRuntimeAnchors[key] = anchor
        end
        local remainingMs = (anchor.captureUiMsec + anchor.displayTime * 1000) - nowMs
        return math.ceil(remainingMs / 1000)
    end

    if not entry.expiry then return 0 end

    -- Legacy entries without expiryUnix: component-based fallback
    local now     = api.Time:TimeToDate(api.Time:GetLocalTime())
    local nowSecs = (now.day or 0)*86400 + (now.hour or 0)*3600
                  + (now.minute or 0)*60  + (now.second or 0)
    local expSecs = (entry.expiry.day or 0)*86400 + (entry.expiry.hour or 0)*3600
                  + (entry.expiry.min or 0)*60    + (entry.expiry.sec or 0)
    return math.floor(expSecs - nowSecs)
end

adjustedTimeForDedup = function(entry)
    if not entry then return 0 end

    -- Only trust captureUiMsec for entries captured during this addon load.
    -- Saved captureUiMsec values belong to an old UI session.
    if entry.captureSession == getTimerSessionId() and entry.captureUiMsec and entry.displayTime then
        local nowMs = api.Time:GetUiMsec()
        if nowMs >= entry.captureUiMsec then
            local remainingMs = (entry.captureUiMsec + entry.displayTime * 1000) - nowMs
            return math.ceil(remainingMs / 1000)
        end
    end

    return adjustedTime(entry)
end

-- Flat render list: header rows interleaved with their entry rows, grouped
local function buildRenderList(farm)
    local function groupKey(d)
        if settings.groupBy == "name_owner" then
            return d.name .. "\0" .. (d.owner or "")
        end
        return d.name
    end

    local groupOrder = {}
    local groups = {}
    for idx, d in ipairs(farm.doodads or {}) do
        local k = groupKey(d)
        if not groups[k] then
            groups[k] = { name=d.name, owner=d.owner, entries={}, key=k }
            table.insert(groupOrder, k)
        end
        table.insert(groups[k].entries, { entry=d, idx=idx })
    end

    local flat = {}
    for _, k in ipairs(groupOrder) do
        local g = groups[k]
        local earliest, latest
        for _, e in ipairs(g.entries) do
            local t = adjustedTime(e.entry)
            if not earliest or t < earliest then earliest = t end
            if not latest   or t > latest   then latest   = t end
        end
        table.insert(flat, {
            type="header", name=g.name, owner=g.owner,
            qty=#g.entries, earliest=earliest or 0, latest=latest or 0,
            key=k, entries=g.entries,
        })
        -- If expanded, insert individual entry rows sorted by time ascending
        if expandedGroups[k] then
            local sorted = {}
            for _, e in ipairs(g.entries) do
                table.insert(sorted, { entry=e.entry, idx=e.idx, t=adjustedTime(e.entry) })
            end
            table.sort(sorted, function(a, b) return a.t < b.t end)
            for _, s in ipairs(sorted) do
                table.insert(flat, {
                    type="entry", entry=s.entry, t=s.t,
                    owner=s.entry.owner or "", groupKey=k,
                })
            end
        end
    end
    return flat
end

-- Try to add a doodad; returns true if added.
local function tryAddDoodad(farm, info)
    if not info or not info.name then return false end
    local t       = api.Time:TimeToDate(api.Time:GetLocalTime())
    local newTime = info.displayTime or 0
    if newTime <= 0 then return false end

    -- Normalize name: strip everything from the first symbol character onwards
    local function normalizeName(n)
        return (n:match("^([^%(%)%[%]%{%}%:%,%;%/%\\%.%!%?]+)") or n):match("^%s*(.-)%s*$")
    end

    local owner = info.owner or ""
    local name  = normalizeName(info.name)

    -- Ensure per-farm filter lists exist
    if not farm.scanPlayers  then farm.scanPlayers  = {} end
    if not farm.scanEntities then farm.scanEntities = {} end

    local defaultEnabled = farm.scanDefaultEnabled
    if defaultEnabled == nil then defaultEnabled = true end

    local populateFilter = farm.populateFilter
    if populateFilter == nil then populateFilter = true end

    -- Auto-register owner in scanPlayers if new (only if filter is not locked)
    local playerEntry = nil
    for _, e in ipairs(farm.scanPlayers) do
        if e.name:lower() == owner:lower() then playerEntry = e; break end
    end
    if not playerEntry then
        if not populateFilter then return false end
        playerEntry = { name = owner, enabled = true }
        table.insert(farm.scanPlayers, playerEntry)
    end

    -- Auto-register entity name in scanEntities if new (only if filter is not locked)
    local entityEntry = nil
    for _, e in ipairs(farm.scanEntities) do
        if e.name:lower() == name:lower() then entityEntry = e; break end
    end
    if not entityEntry then
        if not populateFilter then return false end
        entityEntry = { name = name, enabled = true }
        table.insert(farm.scanEntities, entityEntry)
    end

    -- Reject if either filter is enabled and the entry is disabled
    local filterPlayers  = farm.filterPlayersEnabled;  if filterPlayers  == nil then filterPlayers  = true end
    local filterEntities = farm.filterEntitiesEnabled; if filterEntities == nil then filterEntities = true end
    if filterPlayers  and not playerEntry.enabled then return false end
    if filterEntities and not entityEntry.enabled then return false end

    -- Dedup
    for _, d in ipairs(farm.doodads or {}) do
        if d.name == name and (d.owner or "") == owner then
            if math.abs(adjustedTimeForDedup(d) - newTime) < 2 then
                return false
            end
        end
    end

    local expiry = addSeconds({ day=t.day, hour=t.hour, min=t.minute, sec=t.second, month=t.month, year=t.year }, newTime)

    -- Build expiryUnix: nowUnix() is accurate enough for saved fallback.
    local expiryUnixStr = string.format("%d", nowUnix() + newTime)

    local captureMs = api.Time:GetUiMsec() - 500 - 500
    table.insert(farm.doodads, {
        name           = name,
        owner          = owner,
        displayTime    = newTime,
        captureUiMsec  = captureMs,
        captureSession = getTimerSessionId(),
        expiryUnix     = expiryUnixStr,
        expiry         = expiry,
    })
    local inserted = farm.doodads[#farm.doodads]
    inserted._runtimeKey = tostring(farm.id or "")
        .. ":" .. tostring(#farm.doodads)
        .. ":" .. tostring(inserted.expiryUnix or "")
        .. ":" .. tostring(inserted.name or "")
        .. ":" .. tostring(inserted.owner or "")
    saveFarm(farm)
    return true
end

local AUTO_W = 680
local AUTO_H = 220
local AUTO_ROWS = 11
local AUTO_LOCATION_X = 30
local AUTO_LOCATION_W = 210
local AUTO_ENTITY_X = 246
local AUTO_ENTITY_W = 150
local AUTO_QTY_X = 402
local AUTO_QTY_W = 34
local AUTO_EARLIEST_X = 442
local AUTO_TIME_W = 72
local AUTO_LATEST_X = 520

local function updateAutotrackerTimeLabels()
    for _, item in ipairs(autotrackerTimeLbls) do
        if item.lbl then
            if item.entry then
                item.lbl:SetText(formatTime(adjustedTime(item.entry)))
            elseif item.entries then
                local val = nil
                for _, entry in ipairs(item.entries) do
                    local t = adjustedTime(entry)
                    if item.kind == "earliest" then
                        if val == nil or t < val then val = t end
                    else
                        if val == nil or t > val then val = t end
                    end
                end
                item.lbl:SetText(val ~= nil and formatTime(val) or "-")
            end
        end
    end
end

local function buildAutotrackerRenderList()
    local rows = {}
    for _, farmId in ipairs(autotrackerFarmOrder) do
        local farm = getFarmById(farmId)
        if farm and farm.doodads and #farm.doodads > 0 then
            local groupOrder, groups = {}, {}
            for _, d in ipairs(farm.doodads) do
                local key = farm.id .. "\0" .. d.name
                if not groups[key] then
                    groups[key] = { key=key, farm=farm, name=d.name, entries={}, cooled=farm.isCooledTreeSpot or isCooledTreeInfo(d) }
                    table.insert(groupOrder, key)
                end
                table.insert(groups[key].entries, d)
            end

            for _, key in ipairs(groupOrder) do
                local group = groups[key]
                table.insert(rows, { type="header", group=group })
                if autotrackerExpandedGroups[key] then
                    local sorted = {}
                    for _, entry in ipairs(group.entries) do
                        table.insert(sorted, entry)
                    end
                    table.sort(sorted, function(a, b) return adjustedTime(a) < adjustedTime(b) end)
                    for _, entry in ipairs(sorted) do
                        table.insert(rows, { type="entry", group=group, entry=entry })
                    end
                end
            end
        elseif farm then
            local group = { key=farm.id .. "\0_empty", farm=farm, name="-", entries={}, cooled=farm.isCooledTreeSpot }
            table.insert(rows, { type="header", group=group })
        end
    end
    return rows
end

local function removeAutotrackerFarm(farmId)
    if not farmId then return end
    autotrackerFarmIds[farmId] = nil
    local kept = {}
    for _, id in ipairs(autotrackerFarmOrder) do
        if id ~= farmId then table.insert(kept, id) end
    end
    autotrackerFarmOrder = kept
    if autotrackerWin then rebuildAutotrackerWindow() end
end

local function showFarmInTracker(farm)
    if not farm or not farm.id then return end
    if not autotrackerFarmIds[farm.id] then
        autotrackerFarmIds[farm.id] = true
        table.insert(autotrackerFarmOrder, farm.id)
    end
    showAutotrackerWindow()
    if autotrackerWin then autotrackerWin:Show(true) end
end

local function deleteTrackedEntry(farm, entry)
    if not farm or not entry then return end
    local kept = {}
    for _, d in ipairs(farm.doodads or {}) do
        if d ~= entry then table.insert(kept, d) end
    end
    if #kept == 0 then
        local farmId = farm.id
        deleteFarm(farmId)
        if detailWin and detailWin:IsVisible() and detailFarmId == farmId then closeDetailWindow() end
        if mainWin and mainWin:IsVisible() then rebuildFarmList() end
        if autotrackerWin then rebuildAutotrackerWindow() end
        return
    end
    farm.doodads = kept
    saveFarm(farm)
    if detailWin and detailWin:IsVisible() and detailFarmId == farm.id then rebuildDoodadList() end
    if mainWin and mainWin:IsVisible() then rebuildFarmList() end
    if autotrackerWin then rebuildAutotrackerWindow() end
end

local function deleteTrackedGroup(farm, group)
    if not farm or not group then return end
    if not group.entries or #group.entries == 0 then
        local farmId = farm.id
        deleteFarm(farmId)
        if detailWin and detailWin:IsVisible() and detailFarmId == farmId then closeDetailWindow() end
        if mainWin and mainWin:IsVisible() then rebuildFarmList() end
        if autotrackerWin then rebuildAutotrackerWindow() end
        return
    end

    local name = group.name
    local kept = {}
    for _, d in ipairs(farm.doodads or {}) do
        if d.name ~= name then
            table.insert(kept, d)
        end
    end
    if #kept == 0 then
        local farmId = farm.id
        autotrackerExpandedGroups[group.key] = nil
        deleteFarm(farmId)
        if detailWin and detailWin:IsVisible() and detailFarmId == farmId then closeDetailWindow() end
        if mainWin and mainWin:IsVisible() then rebuildFarmList() end
        if autotrackerWin then rebuildAutotrackerWindow() end
        return
    end
    farm.doodads = kept
    autotrackerExpandedGroups[group.key] = nil
    saveFarm(farm)
    if detailWin and detailWin:IsVisible() and detailFarmId == farm.id then rebuildDoodadList() end
    if mainWin and mainWin:IsVisible() then rebuildFarmList() end
    if autotrackerWin then rebuildAutotrackerWindow() end
end

local function deleteTrackedFarm(farmId)
    if not farmId then return end
    removeAutotrackerFarm(farmId)
    deleteFarm(farmId)
    if detailWin and detailWin:IsVisible() and detailFarmId == farmId then closeDetailWindow() end
    if mainWin and mainWin:IsVisible() then rebuildFarmList() end
    if autotrackerWin then rebuildAutotrackerWindow() end
end

rebuildAutotrackerWindow = function()
    if not autotrackerWin then return end

    for _, row in ipairs(autotrackerRows) do
        if row and row.Show then row:Show(false) end
    end
    autotrackerRows = {}
    autotrackerTimeLbls = {}

    local statusText = settings.autotrackerEnabled and "Tracking" or "Paused"
    if autotrackerWin._titleLbl then autotrackerWin._titleLbl:SetText(statusText) end

    local renderRows = buildAutotrackerRenderList()
    local totalPages = math.max(1, math.ceil(#renderRows / AUTO_ROWS))
    if autotrackerPage > totalPages then autotrackerPage = totalPages end
    if autotrackerPage < 1 then autotrackerPage = 1 end
    if autotrackerWin._pageLbl then autotrackerWin._pageLbl:SetText(string.format("%d / %d", autotrackerPage, totalPages)) end
    if autotrackerWin._prevBtn and autotrackerWin._prevBtn.Enable then autotrackerWin._prevBtn:Enable(autotrackerPage > 1) end
    if autotrackerWin._nextBtn and autotrackerWin._nextBtn.Enable then autotrackerWin._nextBtn:Enable(autotrackerPage < totalPages) end

    if #renderRows == 0 then
        autotrackerWin:SetExtent(AUTO_W, 105)
        local empty = autotrackerWin:CreateChildWidget("label", "tt_auto_empty_" .. tostring(api.Time:GetUiMsec()), 0, true)
        empty:SetText(settings.autotrackerEnabled and "Waiting for hover..." or "Autotracker is off")
        empty:SetExtent(AUTO_W - 24, 20)
        empty:AddAnchor("TOPLEFT", autotrackerWin, 12, 64)
        if empty.style then empty.style:SetFontSize(FONT_SIZE.SMALL or 14); empty.style:SetAlign(ALIGN.LEFT) end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(empty, FONT_COLOR.DEFAULT) end
        empty:Show(true)
        table.insert(autotrackerRows, empty)
        return
    end

    local startIdx = (autotrackerPage - 1) * AUTO_ROWS + 1
    local endIdx = math.min(startIdx + AUTO_ROWS - 1, #renderRows)
    local visibleRows = math.max(1, endIdx - startIdx + 1)
    autotrackerWin:SetExtent(AUTO_W, 92 + (visibleRows * 24))
    for idx = startIdx, endIdx do
        local item = renderRows[idx]
        local rowIndex = idx - startIdx + 1
        local y = 64 + ((rowIndex - 1) * 24)

        if item.type == "header" then
            local group = item.group
            local row = autotrackerWin:CreateChildWidget("emptywidget", "tt_auto_hdr_" .. tostring(api.Time:GetUiMsec()) .. "_" .. rowIndex, 0, true)
            row:SetExtent(AUTO_W - 24, 23)
            row:AddAnchor("TOPLEFT", autotrackerWin, 12, y)
            local rowBg = row:CreateColorDrawable(0.08, 0.10, 0.13, 0.58, "background")
            rowBg:AddAnchor("TOPLEFT", row, 0, 0)
            rowBg:AddAnchor("BOTTOMRIGHT", row, 0, 0)
            rowBg:Show(true)
            row:Show(true)
            table.insert(autotrackerRows, row)

            local toggle = row:CreateChildWidget("checkbutton", "tt_auto_exp_" .. rowIndex, 0, true)
            toggle:SetExtent(18, 17)
            toggle:AddAnchor("LEFT", row, 2, 0)
            local bgs = {}
            local coords = { {0,0,18,17},{0,0,18,17},{0,0,18,17},{0,17,18,17},{18,0,18,17},{18,17,18,17} }
            for j = 1, 6 do
                bgs[j] = toggle:CreateImageDrawable("ui/button/check_button.dds", "background")
                bgs[j]:SetExtent(16, 16)
                bgs[j]:AddAnchor("CENTER", toggle, 0, 0)
                bgs[j]:SetTexture("ui/button/check_button.dds")
                local c = coords[j]
                bgs[j]:SetCoords(c[1], c[2], c[3], c[4])
            end
            toggle:SetNormalBackground(bgs[1]); toggle:SetHighlightBackground(bgs[2])
            toggle:SetPushedBackground(bgs[3]); toggle:SetDisabledBackground(bgs[4])
            toggle:SetCheckedBackground(bgs[5]); toggle:SetDisabledCheckedBackground(bgs[6])
            toggle:SetChecked(autotrackerExpandedGroups[group.key] and true or false)
            function toggle:OnCheckChanged()
                autotrackerExpandedGroups[group.key] = self:GetChecked()
                rebuildAutotrackerWindow()
            end
            toggle:SetHandler("OnCheckChanged", toggle.OnCheckChanged)
            toggle:Show(true)

            local farmLbl = row:CreateChildWidget("label", "tt_auto_farm_" .. rowIndex, 0, true)
            farmLbl:SetText(fitText(string.format("%s (%s)", group.farm.name or "Farm", zoneName(group.farm.zone)), 31))
            farmLbl:SetExtent(AUTO_LOCATION_W, 22)
            farmLbl:AddAnchor("LEFT", row, AUTO_LOCATION_X, 0)
            if farmLbl.style then farmLbl.style:SetFontSize(FONT_SIZE.SMALL or 14); farmLbl.style:SetAlign(ALIGN.LEFT) end
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(farmLbl, group.cooled and (FONT_COLOR.YELLOW or FONT_COLOR.DEFAULT) or FONT_COLOR.DEFAULT) end
            farmLbl:Show(true)

            local nameLbl = row:CreateChildWidget("label", "tt_auto_name_" .. rowIndex, 0, true)
            nameLbl:SetText(fitText(group.name or "", 22))
            nameLbl:SetExtent(AUTO_ENTITY_W, 22)
            nameLbl:AddAnchor("LEFT", row, AUTO_ENTITY_X, 0)
            if nameLbl.style then nameLbl.style:SetFontSize(FONT_SIZE.SMALL or 14); nameLbl.style:SetAlign(ALIGN.LEFT) end
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(nameLbl, group.cooled and (FONT_COLOR.YELLOW or FONT_COLOR.DEFAULT) or FONT_COLOR.DEFAULT) end
            nameLbl:Show(true)

            local qtyLbl = row:CreateChildWidget("label", "tt_auto_qty_" .. rowIndex, 0, true)
            qtyLbl:SetText("x" .. tostring(#group.entries))
            qtyLbl:SetExtent(AUTO_QTY_W, 22)
            qtyLbl:AddAnchor("LEFT", row, AUTO_QTY_X, 0)
            if qtyLbl.style then qtyLbl.style:SetFontSize(FONT_SIZE.SMALL or 14); qtyLbl.style:SetAlign(ALIGN.LEFT) end
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(qtyLbl, FONT_COLOR.DEFAULT) end
            qtyLbl:Show(true)

            local earliestLbl = row:CreateChildWidget("label", "tt_auto_earliest_" .. rowIndex, 0, true)
            earliestLbl:SetExtent(AUTO_TIME_W, 22)
            earliestLbl:AddAnchor("LEFT", row, AUTO_EARLIEST_X, 0)
            if earliestLbl.style then earliestLbl.style:SetFontSize(FONT_SIZE.SMALL or 14); earliestLbl.style:SetAlign(ALIGN.LEFT) end
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(earliestLbl, FONT_COLOR.DEFAULT) end
            earliestLbl:Show(true)
            table.insert(autotrackerTimeLbls, { lbl=earliestLbl, entries=group.entries, kind="earliest" })

            local latestLbl = row:CreateChildWidget("label", "tt_auto_latest_" .. rowIndex, 0, true)
            latestLbl:SetExtent(AUTO_TIME_W, 22)
            latestLbl:AddAnchor("LEFT", row, AUTO_LATEST_X, 0)
            if latestLbl.style then latestLbl.style:SetFontSize(FONT_SIZE.SMALL or 14); latestLbl.style:SetAlign(ALIGN.LEFT) end
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(latestLbl, FONT_COLOR.DEFAULT) end
            latestLbl:Show(true)
            table.insert(autotrackerTimeLbls, { lbl=latestLbl, entries=group.entries, kind="latest" })

            local delBtn = row:CreateChildWidget("button", "tt_auto_del_group_" .. rowIndex, 0, true)
            if api.Interface.ApplyButtonSkin and BUTTON_CONTENTS then
                api.Interface:ApplyButtonSkin(delBtn, BUTTON_CONTENTS.SKILL_ABILITY_DELETE)
            elseif ApplyButtonSkin and BUTTON_BASIC then
                ApplyButtonSkin(delBtn, BUTTON_BASIC.DEFAULT)
            end
            delBtn:SetExtent(24, 24)
            delBtn:AddAnchor("RIGHT", row, -2, 0)
            local capturedFarm = group.farm
            local capturedGroup = group
            function delBtn:OnClick()
                deleteTrackedGroup(capturedFarm, capturedGroup)
            end
            delBtn:SetHandler("OnClick", delBtn.OnClick)
            delBtn:Show(true)
        else
            local entry = item.entry
            local row = autotrackerWin:CreateChildWidget("emptywidget", "tt_auto_ent_" .. tostring(api.Time:GetUiMsec()) .. "_" .. rowIndex, 0, true)
            row:SetExtent(AUTO_W - 24, 23)
            row:AddAnchor("TOPLEFT", autotrackerWin, 12, y)
            local rowBg = row:CreateColorDrawable(0.02, 0.02, 0.02, 0.35, "background")
            rowBg:AddAnchor("TOPLEFT", row, 0, 0)
            rowBg:AddAnchor("BOTTOMRIGHT", row, 0, 0)
            rowBg:Show(true)
            row:Show(true)
            table.insert(autotrackerRows, row)

            local nameLbl = row:CreateChildWidget("label", "tt_auto_ent_name_" .. rowIndex, 0, true)
            nameLbl:SetText("  " .. fitText(entry.owner and entry.owner ~= "" and entry.owner or "No Owner", 48))
            nameLbl:SetExtent(AUTO_ENTITY_X + AUTO_ENTITY_W - AUTO_LOCATION_X, 22)
            nameLbl:AddAnchor("LEFT", row, AUTO_LOCATION_X, 0)
            if nameLbl.style then nameLbl.style:SetFontSize(FONT_SIZE.SMALL or 14); nameLbl.style:SetAlign(ALIGN.LEFT) end
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(nameLbl, FONT_COLOR.DEFAULT) end
            nameLbl:Show(true)

            local timeLbl = row:CreateChildWidget("label", "tt_auto_ent_time_" .. rowIndex, 0, true)
            timeLbl:SetExtent(AUTO_TIME_W + 30, 22)
            timeLbl:AddAnchor("LEFT", row, AUTO_EARLIEST_X, 0)
            if timeLbl.style then timeLbl.style:SetFontSize(FONT_SIZE.SMALL or 14); timeLbl.style:SetAlign(ALIGN.LEFT) end
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(timeLbl, FONT_COLOR.DEFAULT) end
            timeLbl:Show(true)
            table.insert(autotrackerTimeLbls, { lbl=timeLbl, entry=entry })

            local delBtn = row:CreateChildWidget("button", "tt_auto_del_entry_" .. rowIndex, 0, true)
            if api.Interface.ApplyButtonSkin and BUTTON_CONTENTS then
                api.Interface:ApplyButtonSkin(delBtn, BUTTON_CONTENTS.SKILL_ABILITY_DELETE)
            elseif ApplyButtonSkin and BUTTON_BASIC then
                ApplyButtonSkin(delBtn, BUTTON_BASIC.DEFAULT)
            end
            delBtn:SetExtent(22, 22)
            delBtn:AddAnchor("RIGHT", row, -4, 0)
            local capturedFarm = item.group.farm
            local capturedEntry = entry
            function delBtn:OnClick()
                deleteTrackedEntry(capturedFarm, capturedEntry)
            end
            delBtn:SetHandler("OnClick", delBtn.OnClick)
            delBtn:Show(true)
        end
    end

    updateAutotrackerTimeLabels()
end

local function ensureAutotrackerWindow()
    if autotrackerWin then return end

    autotrackerWin = api.Interface:CreateEmptyWindow("tax_tracker_autotracker_window")
    autotrackerWin:SetExtent(AUTO_W, AUTO_H)
    autotrackerWin:AddAnchor("CENTER", "UIParent", 380, -110)
    if autotrackerWin.EnableDrag then autotrackerWin:EnableDrag(true) end
    function autotrackerWin:OnDragStart()
        if self.StartMoving then self:StartMoving() end
        if api.Cursor and api.Cursor.ClearCursor then api.Cursor:ClearCursor() end
    end
    autotrackerWin:SetHandler("OnDragStart", autotrackerWin.OnDragStart)
    function autotrackerWin:OnDragStop()
        if self.StopMovingOrSizing then self:StopMovingOrSizing() end
        if api.Cursor and api.Cursor.ClearCursor then api.Cursor:ClearCursor() end
    end
    autotrackerWin:SetHandler("OnDragStop", autotrackerWin.OnDragStop)

    local bg = autotrackerWin:CreateColorDrawable(0, 0, 0, 0.62, "background")
    bg:AddAnchor("TOPLEFT", autotrackerWin, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", autotrackerWin, 0, 0)
    bg:Show(true)

    local titleLbl = autotrackerWin:CreateChildWidget("label", "tt_auto_title", 0, true)
    titleLbl:SetText("Tracking")
    titleLbl:SetExtent(300, 24)
    titleLbl:AddAnchor("TOPLEFT", autotrackerWin, 12, 10)
    if titleLbl.style then titleLbl.style:SetFontSize(FONT_SIZE.LARGE or 18); titleLbl.style:SetAlign(ALIGN.LEFT) end
    if ApplyTextColor and FONT_COLOR then ApplyTextColor(titleLbl, FONT_COLOR.DEFAULT) end
    titleLbl:Show(true)
    autotrackerWin._titleLbl = titleLbl

    local closeBtn = autotrackerWin:CreateChildWidget("button", "tt_auto_hide", 0, true)
    if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(closeBtn, BUTTON_BASIC.DEFAULT) end
    closeBtn:SetExtent(54, 24)
    closeBtn:AddAnchor("TOPRIGHT", autotrackerWin, -10, 8)
    closeBtn:SetText("Hide")
    function closeBtn:OnClick()
        autotrackerWin:Show(false)
    end
    closeBtn:SetHandler("OnClick", closeBtn.OnClick)
    closeBtn:Show(true)

    local hdr = autotrackerWin:CreateChildWidget("emptywidget", "tt_auto_header", 0, true)
    hdr:SetExtent(AUTO_W - 24, 22)
    hdr:AddAnchor("TOPLEFT", autotrackerWin, 12, 38)
    hdr:Show(true)

    local function headerLbl(name, txt, x, w)
        local lbl = hdr:CreateChildWidget("label", name, 0, true)
        lbl:SetText(txt)
        lbl:SetExtent(w, 20)
        lbl:AddAnchor("LEFT", hdr, x, 0)
        if lbl.style then lbl.style:SetFontSize(FONT_SIZE.SMALL or 14); lbl.style:SetAlign(ALIGN.LEFT) end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(lbl, FONT_COLOR.DEFAULT) end
        lbl:Show(true)
    end
    local hdrBg = hdr:CreateColorDrawable(0.08, 0.11, 0.16, 0.68, "background")
    hdrBg:AddAnchor("TOPLEFT", hdr, 0, 0)
    hdrBg:AddAnchor("BOTTOMRIGHT", hdr, 0, 0)
    hdrBg:Show(true)

    headerLbl("tt_auto_h_farm", "Location", AUTO_LOCATION_X, AUTO_LOCATION_W)
    headerLbl("tt_auto_h_entity", "Entity", AUTO_ENTITY_X, AUTO_ENTITY_W)
    headerLbl("tt_auto_h_qty", "Qty", AUTO_QTY_X, AUTO_QTY_W)
    headerLbl("tt_auto_h_earliest", "Earliest", AUTO_EARLIEST_X, AUTO_TIME_W)
    headerLbl("tt_auto_h_latest", "Latest", AUTO_LATEST_X, AUTO_TIME_W)
    headerLbl("tt_auto_h_delete", "Del", AUTO_W - 68, 40)

    local prevBtn = autotrackerWin:CreateChildWidget("button", "tt_auto_prev", 0, true)
    if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(prevBtn, BUTTON_BASIC.DEFAULT) end
    prevBtn:SetExtent(70, 24)
    prevBtn:AddAnchor("BOTTOMLEFT", autotrackerWin, 12, -10)
    prevBtn:SetText("Prev")
    function prevBtn:OnClick()
        autotrackerPage = autotrackerPage - 1
        rebuildAutotrackerWindow()
    end
    prevBtn:SetHandler("OnClick", prevBtn.OnClick)
    prevBtn:Show(true)
    autotrackerWin._prevBtn = prevBtn

    local pageLbl = autotrackerWin:CreateChildWidget("label", "tt_auto_page", 0, true)
    pageLbl:SetExtent(80, 24)
    pageLbl:AddAnchor("BOTTOM", autotrackerWin, 0, -10)
    pageLbl:SetText("1 / 1")
    if pageLbl.style then pageLbl.style:SetFontSize(FONT_SIZE.SMALL or 14); pageLbl.style:SetAlign(ALIGN.CENTER) end
    if ApplyTextColor and FONT_COLOR then ApplyTextColor(pageLbl, FONT_COLOR.DEFAULT) end
    pageLbl:Show(true)
    autotrackerWin._pageLbl = pageLbl

    local nextBtn = autotrackerWin:CreateChildWidget("button", "tt_auto_next", 0, true)
    if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(nextBtn, BUTTON_BASIC.DEFAULT) end
    nextBtn:SetExtent(70, 24)
    nextBtn:AddAnchor("BOTTOMRIGHT", autotrackerWin, -12, -10)
    nextBtn:SetText("Next")
    function nextBtn:OnClick()
        autotrackerPage = autotrackerPage + 1
        rebuildAutotrackerWindow()
    end
    nextBtn:SetHandler("OnClick", nextBtn.OnClick)
    nextBtn:Show(true)
    autotrackerWin._nextBtn = nextBtn
end

showAutotrackerWindow = function()
    ensureAutotrackerWindow()
    if #autotrackerFarmOrder == 0 then
        autotrackerWin:Show(false)
        return
    end
    rebuildAutotrackerWindow()
    autotrackerWin:Show(true)
end

local function addAutotrackerItem(farm, entryName, isCooled)
    if not isCooled then return end
    if farm and farm.id and not autotrackerFarmIds[farm.id] then
        autotrackerFarmIds[farm.id] = true
        table.insert(autotrackerFarmOrder, farm.id)
    end
    if settings.autotrackerEnabled then showAutotrackerWindow() end
end

local function updateAutotrackerButton()
    if autotrackerBtn then autotrackerBtn:SetText(settings.autotrackerEnabled and "Autotracker: ON" or "Autotracker: OFF") end
    if floatingAutoBtn then floatingAutoBtn:SetText(settings.autotrackerEnabled and "Auto: ON" or "Auto: OFF") end
    local text = settings.autotrackerEnabled and "Autotracker: ON" or "Autotracker: OFF"
    for i = #externalAutotrackerButtons, 1, -1 do
        local btn = externalAutotrackerButtons[i]
        local ok = btn and btn.SetText and pcall(function() btn:SetText(text) end)
        if not ok then table.remove(externalAutotrackerButtons, i) end
    end
end

-- ============================================================
-- DETAIL WINDOW
-- ============================================================

closeDetailWindow = function()
    lastDoodadInfo = nil
    if detailWin then detailWin:Show(false) end
    if filterWin then filterWin:Show(false) end
    detailFarmId = nil
end

local detailRebuilding = false
rebuildDoodadList = function()
    if detailRebuilding then return end
    detailRebuilding = true
    local ok, err = pcall(function()
    local farm = detailFarmId and getFarmById(detailFarmId)
    if not farm or not detailWin then return end

    detailRebuildId = detailRebuildId + 1
    local rid = detailRebuildId
    detailTimeLbls = {}

    if detailWin._listContent then detailWin._listContent:Show(false) end

    -- Update Clear button label
    if detailWin._btnReset then
        local hasDone = false
        for _, d in ipairs(farm.doodads or {}) do
            if adjustedTime(d) <= 0 then hasDone = true; break end
        end
        detailWin._btnReset._clearDoneMode = hasDone
        detailWin._btnReset:SetText(hasDone and "Clear 'Done'" or "Clear All")
    end

    local flat       = buildRenderList(farm)
    local totalPages = math.max(1, math.ceil(#flat / DETAIL_ROWS_PER_PAGE))
    if detailPage > totalPages then detailPage = totalPages end
    if detailPage < 1          then detailPage = 1          end

    if detailWin._dPageCtrl then
        detailWin._dPageCtrl:SetPageCount(totalPages, DETAIL_ROWS_PER_PAGE, false)
        detailWin._dPageCtrl:SetCurrentPage(detailPage, false)
    end

    local startIdx = (detailPage - 1) * DETAIL_ROWS_PER_PAGE + 1
    local endIdx   = math.min(startIdx + DETAIL_ROWS_PER_PAGE - 1, #flat)
    local rowCount = math.max(1, endIdx - startIdx + 1)

    local listContent = detailWin:CreateChildWidget("emptywidget", "ft_dl_content_"..rid, 0, true)
    listContent:SetExtent(DETAIL_W - 16, rowCount * 28)
    listContent:RemoveAllAnchors()
    listContent:AddAnchor("TOPLEFT", detailWin, 8, DETAIL_LIST_Y)
    listContent:Show(true)
    detailWin._listContent = listContent

    if #flat == 0 then
        local emptyLbl1 = listContent:CreateChildWidget("label", "ft_dl_empty1_"..rid, 0, true)
        emptyLbl1:SetText("No entities scanned yet.")
        emptyLbl1:AddAnchor("TOPLEFT", listContent, 4, 8)
        emptyLbl1:SetAutoResize(true)
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(emptyLbl1, FONT_COLOR.DEFAULT) end
        emptyLbl1:Show(true)
        local emptyLbl2 = listContent:CreateChildWidget("label", "ft_dl_empty2_"..rid, 0, true)
        emptyLbl2:SetText("Entities will be scanned on mouseover when holding the modifier key selected in the settings page for this addon.")
        emptyLbl2:AddAnchor("TOPLEFT", listContent, 4, 28)
        emptyLbl2:SetAutoResize(true)
        if emptyLbl2.style then emptyLbl2.style:SetFontSize(FONT_SIZE.SMALL or 14) end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(emptyLbl2, FONT_COLOR.DEFAULT) end
        emptyLbl2:Show(true)
        return
    end

    for i = startIdx, endIdx do
        local item = flat[i]
        local yOff = (i - startIdx) * 28

        if item.type == "header" then
            local hdr = listContent:CreateChildWidget("emptywidget", "ft_dl_hdr_"..rid.."_"..i, 0, true)
            hdr:SetExtent(DETAIL_W - 16, 27)
            hdr:RemoveAllAnchors()
            hdr:AddAnchor("TOPLEFT", listContent, 0, yOff)
            local hdrShade = hdr:CreateColorDrawable(0.08, 0.10, 0.13, 0.62, "background")
            hdrShade:AddAnchor("TOPLEFT", hdr, 0, 0)
            hdrShade:AddAnchor("BOTTOMRIGHT", hdr, 0, 0)
            hdrShade:Show(true)
            hdr:Show(true)

            -- Expand checkbox (only show if qty > 1)
            if item.qty > 1 then
                local capturedKey = item.key
                local chk = hdr:CreateChildWidget("checkbutton", "ft_dl_exp_"..rid.."_"..i, 0, true)
                chk:SetExtent(18, 17)
                chk:AddAnchor("LEFT", hdr, 4, 0)
                local bgs = {}
                local coords = {
                    {0,0,18,17},{0,0,18,17},{0,0,18,17},
                    {0,17,18,17},{18,0,18,17},{18,17,18,17}
                }
                for j = 1, 6 do
                    bgs[j] = chk:CreateImageDrawable("ui/button/check_button.dds", "background")
                    bgs[j]:SetExtent(16, 16)
                    bgs[j]:AddAnchor("CENTER", chk, 0, 0)
                    bgs[j]:SetTexture("ui/button/check_button.dds")
                    local c = coords[j]
                    bgs[j]:SetCoords(c[1], c[2], c[3], c[4])
                end
                chk:SetNormalBackground(bgs[1])
                chk:SetHighlightBackground(bgs[2])
                chk:SetPushedBackground(bgs[3])
                chk:SetDisabledBackground(bgs[4])
                chk:SetCheckedBackground(bgs[5])
                chk:SetDisabledCheckedBackground(bgs[6])
                chk:SetChecked(expandedGroups[capturedKey] and true or false)
                function chk:OnCheckChanged()
                    expandedGroups[capturedKey] = self:GetChecked()
                    rebuildDoodadList()
                end
                chk:SetHandler("OnCheckChanged", chk.OnCheckChanged)
                chk:Show(true)
            end

            local nameLbl = hdr:CreateChildWidget("label", "ft_dl_hn_"..rid.."_"..i, 0, true)
            nameLbl:SetExtent(DETAIL_NAME_W, 27)
            nameLbl:AddAnchor("LEFT", hdr, 26, 0)
            nameLbl:SetText(fitText(item.name or "", 46))
            nameLbl:SetAutoResize(false)
            if nameLbl.style then nameLbl.style:SetAlign(ALIGN.LEFT); nameLbl.style:SetFontSize(FONT_SIZE.MIDDLE or 16) end
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(nameLbl, FONT_COLOR.DEFAULT) end
            nameLbl:Show(true)

            local qtyLbl = hdr:CreateChildWidget("label", "ft_dl_hq_"..rid.."_"..i, 0, true)
            qtyLbl:SetExtent(DETAIL_QTY_W, 27)
            qtyLbl:AddAnchor("LEFT", hdr, DETAIL_QTY_X, 0)
            qtyLbl:SetText("x" .. item.qty)
            qtyLbl:SetAutoResize(false)
            if qtyLbl.style then qtyLbl.style:SetAlign(ALIGN.CENTER) end
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(qtyLbl, FONT_COLOR.DEFAULT) end
            qtyLbl:Show(true)

            local eLbl = hdr:CreateChildWidget("label", "ft_dl_he_"..rid.."_"..i, 0, true)
            eLbl:SetExtent(DETAIL_TIME_W, 27)
            eLbl:AddAnchor("LEFT", hdr, DETAIL_EARLIEST_X, 0)
            eLbl:SetText(formatTime(item.earliest))
            eLbl:SetAutoResize(false)
            if eLbl.style then eLbl.style:SetAlign(ALIGN.LEFT) end
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(eLbl, FONT_COLOR.DEFAULT) end
            eLbl:Show(true)
            table.insert(detailTimeLbls, { kind="earliest", lbl=eLbl, groupName=item.name, groupOwner=item.owner })

            local lLbl = hdr:CreateChildWidget("label", "ft_dl_hl_"..rid.."_"..i, 0, true)
            lLbl:SetExtent(DETAIL_TIME_W, 27)
            lLbl:AddAnchor("LEFT", hdr, DETAIL_LATEST_X, 0)
            lLbl:SetText(formatTime(item.latest))
            lLbl:SetAutoResize(false)
            if lLbl.style then lLbl.style:SetAlign(ALIGN.LEFT) end
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(lLbl, FONT_COLOR.DEFAULT) end
            lLbl:Show(true)
            table.insert(detailTimeLbls, { kind="latest", lbl=lLbl, groupName=item.name, groupOwner=item.owner })

            -- Delete button for this group
            local delBtn = hdr:CreateChildWidget("button", "ft_dl_hdel_"..rid.."_"..i, 0, true)
            api.Interface:ApplyButtonSkin(delBtn, BUTTON_CONTENTS.SKILL_ABILITY_DELETE)
            delBtn:SetExtent(22, 22)
            delBtn:AddAnchor("RIGHT", hdr, -2, 0)
            local capturedName  = item.name
            local capturedOwner = item.owner
            function delBtn:OnClick()
                local f = detailFarmId and getFarmById(detailFarmId)
                if not f then return end
                local remaining = {}
                for _, d in ipairs(f.doodads or {}) do
                    local nameMatch  = d.name == capturedName
                    local ownerMatch = settings.groupBy ~= "name_owner"
                                    or (d.owner or "") == (capturedOwner or "")
                    if not (nameMatch and ownerMatch) then
                        table.insert(remaining, d)
                    end
                end
                f.doodads = remaining
                expandedGroups[item.key] = nil
                saveFarm(f)
                detailPage = 1
                rebuildDoodadList()
            end
            delBtn:SetHandler("OnClick", delBtn.OnClick)
            delBtn:Show(true)

        elseif item.type == "entry" then
            local row = listContent:CreateChildWidget("emptywidget", "ft_dl_ent_"..rid.."_"..i, 0, true)
            row:SetExtent(DETAIL_W - 16, 27)
            row:RemoveAllAnchors()
            row:AddAnchor("TOPLEFT", listContent, 0, yOff)
            local rowShade = row:CreateColorDrawable(0.02, 0.02, 0.02, 0.35, "background")
            rowShade:AddAnchor("TOPLEFT", row, 0, 0)
            rowShade:AddAnchor("BOTTOMRIGHT", row, 0, 0)
            rowShade:Show(true)
            row:Show(true)

            -- Indent + owner label
            local ownerLbl = row:CreateChildWidget("label", "ft_dl_eo_"..rid.."_"..i, 0, true)
            ownerLbl:SetExtent(DETAIL_NAME_W, 27)
            ownerLbl:AddAnchor("LEFT", row, 36, 0)
            ownerLbl:SetText("  " .. fitText(item.owner ~= "" and item.owner or "No Owner", 44))
            ownerLbl:SetAutoResize(false)
            if ownerLbl.style then ownerLbl.style:SetAlign(ALIGN.LEFT); ownerLbl.style:SetFontSize(FONT_SIZE.SMALL or 14) end
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(ownerLbl, FONT_COLOR.SOFT_BROWN or FONT_COLOR.DEFAULT) end
            ownerLbl:Show(true)

            -- Time label in Earliest column
            local tLbl = row:CreateChildWidget("label", "ft_dl_et_"..rid.."_"..i, 0, true)
            tLbl:SetExtent(200, 27)
            tLbl:AddAnchor("LEFT", row, DETAIL_EARLIEST_X, 0)
            tLbl:SetText(formatTime(item.t))
            tLbl:SetAutoResize(false)
            if tLbl.style then tLbl.style:SetAlign(ALIGN.LEFT); tLbl.style:SetFontSize(FONT_SIZE.SMALL or 14) end
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(tLbl, FONT_COLOR.DEFAULT) end
            tLbl:Show(true)
            table.insert(detailTimeLbls, { kind="entry", lbl=tLbl, entry=item.entry })
        end
    end
    end) -- end pcall
    if not ok then log("rebuildDoodadList error: " .. tostring(err)) end
    detailRebuilding = false
end

local function openDetailWindow(farmId)
    local farm = getFarmById(farmId)
    if not farm then
        log("openDetailWindow: farm not found: " .. tostring(farmId))
        return
    end
    detailFarmId = farmId
    detailPage   = 1

    if mainWin then mainWin:Show(false) end

    if not detailWin then
        detailWin = api.Interface:CreateWindow("tax_tracker_farm_detail", "Farm Detail", DETAIL_W, DETAIL_H)
        detailWin:RemoveAllAnchors()
        detailWin:AddAnchor("CENTER", "UIParent", 0, 0)
        addWindowTint(detailWin, 0.55)
        detailWin:Show(false)

        function detailWin:OnHide() lastDoodadInfo = nil end
        detailWin:SetHandler("OnHide", detailWin.OnHide)

        -- Farm info: zone on left, coords on right
        detailWin._zoneLbl = detailWin:CreateChildWidget("label", "ft_detail_zone", 0, true)
        detailWin._zoneLbl:SetExtent(200, 22)
        detailWin._zoneLbl:SetAutoResize(false)
        detailWin._zoneLbl:AddAnchor("TOPLEFT", detailWin, 10, 10)
        if detailWin._zoneLbl.style then
            detailWin._zoneLbl.style:SetFontSize(FONT_SIZE.MIDDLE or 16)
            detailWin._zoneLbl.style:SetAlign(ALIGN.LEFT)
        end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(detailWin._zoneLbl, FONT_COLOR.DEFAULT) end
        detailWin._zoneLbl:Show(true)

        detailWin._sextLbl = detailWin:CreateChildWidget("label", "ft_detail_sext", 0, true)
        detailWin._sextLbl:SetExtent(220, 22)
        detailWin._sextLbl:SetAutoResize(false)
        detailWin._sextLbl:AddAnchor("TOPRIGHT", detailWin, -20, 10)
        if detailWin._sextLbl.style then
            detailWin._sextLbl.style:SetFontSize(FONT_SIZE.MIDDLE or 16)
            detailWin._sextLbl.style:SetAlign(ALIGN.RIGHT)
        end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(detailWin._sextLbl, FONT_COLOR.DEFAULT) end
        detailWin._sextLbl:Show(true)

        -- Separator below info
        local sep1 = detailWin:CreateColorDrawable(0.3, 0.3, 0.5, 0.5, "background")
        sep1:SetExtent(DETAIL_W - 20, 1)
        sep1:RemoveAllAnchors()
        sep1:AddAnchor("TOPLEFT", detailWin, 10, 38)
        sep1:Show(true)

        local dHdrBg = detailWin:CreateColorDrawable(0.08, 0.11, 0.16, 0.72, "background")
        dHdrBg:SetExtent(DETAIL_W - 20, 26)
        dHdrBg:RemoveAllAnchors()
        dHdrBg:AddAnchor("TOPLEFT", detailWin, 10, 40)
        dHdrBg:Show(true)

        -- Doodad list column headers
        local function makeDHdr(name, txt, x, w)
            local lbl = detailWin:CreateChildWidget("label", name, 0, true)
            lbl:SetExtent(w, 22)
            lbl:RemoveAllAnchors()
            lbl:AddAnchor("TOPLEFT", detailWin, x, 42)
            lbl:SetText(txt)
            lbl:SetAutoResize(false)
            if lbl.style then lbl.style:SetAlign(ALIGN.LEFT); lbl.style:SetFontSize(FONT_SIZE.LARGE or 18) end
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(lbl, FONT_COLOR.DEFAULT) end
            lbl:Show(true)
        end
        makeDHdr("ft_dh_expand",   "",            13,                24)
        makeDHdr("ft_dh_name",     "Entity Name", DETAIL_NAME_X,     DETAIL_NAME_W)
        makeDHdr("ft_dh_qty",      "Qty",         DETAIL_QTY_X,      DETAIL_QTY_W)
        makeDHdr("ft_dh_earliest", "Earliest",    DETAIL_EARLIEST_X, DETAIL_TIME_W)
        makeDHdr("ft_dh_latest",   "Latest",      DETAIL_LATEST_X,   DETAIL_TIME_W)

        -- Separator below column headers
        local sep3 = detailWin:CreateColorDrawable(0.3, 0.3, 0.5, 0.5, "background")
        sep3:SetExtent(DETAIL_W - 20, 1)
        sep3:RemoveAllAnchors()
        sep3:AddAnchor("TOPLEFT", detailWin, 10, 66)
        sep3:Show(true)

        -- Doodad list page controls (centered at bottom)
        local dPageCtrl = W_CTRL.CreatePageControl("ft_d_pagectrl", detailWin, "tutorial")
        dPageCtrl:RemoveAllAnchors()
        dPageCtrl:AddAnchor("BOTTOM", detailWin, 0, -14)
        function dPageCtrl:ProcOnPageChanged(pageIndex)
            detailPage = pageIndex
            rebuildDoodadList()
        end
        dPageCtrl:Show(true)
        detailWin._dPageCtrl = dPageCtrl

        -- Bottom separator
        local sep4 = detailWin:CreateColorDrawable(0.3, 0.3, 0.5, 0.5, "background")
        sep4:SetExtent(DETAIL_W - 20, 1)
        sep4:RemoveAllAnchors()
        sep4:AddAnchor("BOTTOMLEFT", detailWin, 10, -46)
        sep4:Show(true)

        -- "Populate Filter List" checkbox (above Back button)
        local cbPopulate = detailWin:CreateChildWidget("checkbutton", "ft_detail_cb_populate", 0, true)
        cbPopulate:SetExtent(18, 17)
        cbPopulate:RemoveAllAnchors()
        cbPopulate:AddAnchor("BOTTOMLEFT", detailWin, 10, -48)
        local cbpBgs = {}
        local cbpCoords = {
            {0,0,18,17},{0,0,18,17},{0,0,18,17},
            {0,17,18,17},{18,0,18,17},{18,17,18,17}
        }
        for j = 1, 6 do
            cbpBgs[j] = cbPopulate:CreateImageDrawable("ui/button/check_button.dds", "background")
            cbpBgs[j]:SetExtent(16, 16)
            cbpBgs[j]:AddAnchor("CENTER", cbPopulate, 0, 0)
            cbpBgs[j]:SetTexture("ui/button/check_button.dds")
            local c = cbpCoords[j]
            cbpBgs[j]:SetCoords(c[1], c[2], c[3], c[4])
        end
        cbPopulate:SetNormalBackground(cbpBgs[1])
        cbPopulate:SetHighlightBackground(cbpBgs[2])
        cbPopulate:SetPushedBackground(cbpBgs[3])
        cbPopulate:SetDisabledBackground(cbpBgs[4])
        cbPopulate:SetCheckedBackground(cbpBgs[5])
        cbPopulate:SetDisabledCheckedBackground(cbpBgs[6])
        cbPopulate:SetChecked(false)
        function cbPopulate:OnCheckChanged()
            local f = detailFarmId and getFarmById(detailFarmId)
            if f then f.populateFilter = not self:GetChecked(); saveFarm(f) end
        end
        cbPopulate:SetHandler("OnCheckChanged", cbPopulate.OnCheckChanged)
        cbPopulate:Show(true)
        detailWin._cbPopulate = cbPopulate

        local cbPopulateLbl = detailWin:CreateChildWidget("label", "ft_detail_populate_lbl", 0, true)
        cbPopulateLbl:SetText("Lock Filter")
        cbPopulateLbl:SetAutoResize(true)
        cbPopulateLbl:AddAnchor("LEFT", cbPopulate, "RIGHT", 4, 0)
        if cbPopulateLbl.style then cbPopulateLbl.style:SetAlign(ALIGN.LEFT); cbPopulateLbl.style:SetFontSize(FONT_SIZE.SMALL or 14) end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(cbPopulateLbl, FONT_COLOR.DEFAULT) end
        cbPopulateLbl:Show(true)

        -- "Scan only when holding [modifier]" checkbox
        local cbModOnly = detailWin:CreateChildWidget("checkbutton", "ft_detail_cb_modonly", 0, true)
        cbModOnly:SetExtent(18, 17)
        cbModOnly:RemoveAllAnchors()
        cbModOnly:AddAnchor("BOTTOMLEFT", detailWin, 210, -48)
        local cbmBgs = {}
        local cbmCoords = {
            {0,0,18,17},{0,0,18,17},{0,0,18,17},
            {0,17,18,17},{18,0,18,17},{18,17,18,17}
        }
        for j = 1, 6 do
            cbmBgs[j] = cbModOnly:CreateImageDrawable("ui/button/check_button.dds", "background")
            cbmBgs[j]:SetExtent(16, 16)
            cbmBgs[j]:AddAnchor("CENTER", cbModOnly, 0, 0)
            cbmBgs[j]:SetTexture("ui/button/check_button.dds")
            local c = cbmCoords[j]
            cbmBgs[j]:SetCoords(c[1], c[2], c[3], c[4])
        end
        cbModOnly:SetNormalBackground(cbmBgs[1])
        cbModOnly:SetHighlightBackground(cbmBgs[2])
        cbModOnly:SetPushedBackground(cbmBgs[3])
        cbModOnly:SetDisabledBackground(cbmBgs[4])
        cbModOnly:SetCheckedBackground(cbmBgs[5])
        cbModOnly:SetDisabledCheckedBackground(cbmBgs[6])
        cbModOnly:SetChecked(true)
        function cbModOnly:OnCheckChanged()
            local f = detailFarmId and getFarmById(detailFarmId)
            if f then f.requireModifier = self:GetChecked(); saveFarm(f) end
        end
        cbModOnly:SetHandler("OnCheckChanged", cbModOnly.OnCheckChanged)
        cbModOnly:Show(true)
        detailWin._cbModOnly = cbModOnly

        local cbModOnlyLbl = detailWin:CreateChildWidget("label", "ft_detail_modonly_lbl", 0, true)
        cbModOnlyLbl:SetText("Scan only when holding modifier")
        cbModOnlyLbl:SetAutoResize(true)
        cbModOnlyLbl:AddAnchor("LEFT", cbModOnly, "RIGHT", 4, 0)
        if cbModOnlyLbl.style then cbModOnlyLbl.style:SetAlign(ALIGN.LEFT); cbModOnlyLbl.style:SetFontSize(FONT_SIZE.SMALL or 14) end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(cbModOnlyLbl, FONT_COLOR.DEFAULT) end
        cbModOnlyLbl:Show(true)
        detailWin._cbModOnlyLbl = cbModOnlyLbl

        -- Back button (bottom-left)
        local btnBack = detailWin:CreateChildWidget("button", "ft_detail_back", 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(btnBack, BUTTON_BASIC.DEFAULT) end
        btnBack:SetExtent(70, 28)
        btnBack:AddAnchor("BOTTOMLEFT", detailWin, 10, -10)
        btnBack:SetText("< Back")
        function btnBack:OnClick()
            closeDetailWindow()
            if mainWin then
                loadAllFarms()
                rebuildFarmList()
                mainWin:Show(true)
            end
        end
        btnBack:SetHandler("OnClick", btnBack.OnClick)
        btnBack:Show(true)

        -- Filters button (right of Back)
        local btnFiltersBottom = detailWin:CreateChildWidget("button", "ft_detail_filters_btm", 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(btnFiltersBottom, BUTTON_BASIC.DEFAULT) end
        btnFiltersBottom:SetExtent(80, 28)
        btnFiltersBottom:AddAnchor("BOTTOMLEFT", detailWin, 88, -10)
        btnFiltersBottom:SetText("Filters")
        function btnFiltersBottom:OnClick()
            local f = detailFarmId and getFarmById(detailFarmId)
            if f then openFilterWindow(f) end
        end
        btnFiltersBottom:SetHandler("OnClick", btnFiltersBottom.OnClick)
        btnFiltersBottom:Show(true)

        -- Clear button (bottom-right)
        local btnReset = detailWin:CreateChildWidget("button", "ft_detail_reset", 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(btnReset, BUTTON_BASIC.DEFAULT) end
        btnReset:SetExtent(100, 28)
        btnReset:AddAnchor("BOTTOMRIGHT", detailWin, -10, -10)
        btnReset:SetText("Clear All")
        if btnReset.style then btnReset.style:SetColor(1, 0.5, 0.2, 1) end
        function btnReset:OnClick()
            local f = detailFarmId and getFarmById(detailFarmId)
            if not f then return end
            if self._clearDoneMode then
                local remaining = {}
                for _, d in ipairs(f.doodads or {}) do
                    if adjustedTime(d) > 0 then
                        table.insert(remaining, d)
                    end
                end
                f.doodads = remaining
            else
                f.doodads = {}
            end
            saveFarm(f); detailPage = 1; rebuildDoodadList()
        end
        btnReset:SetHandler("OnClick", btnReset.OnClick)
        btnReset:Show(true)
        detailWin._btnReset = btnReset
    end

    -- Populate static labels
    detailWin._zoneLbl:SetText(zoneName(farm.zone))
    detailWin._sextLbl:SetText(farm.sextants or "")
    if detailWin.SetTitle then detailWin:SetTitle(farm.name or "Farm Detail") end
    if detailWin._cbPopulate then
        local pop = farm.populateFilter
        if pop == nil then pop = true end
        detailWin._cbPopulate:SetChecked(not pop)
    end
    if detailWin._cbModOnly then
        local req = farm.requireModifier
        if req == nil then req = true end
        detailWin._cbModOnly:SetChecked(req)
    end
    if detailWin._cbModOnlyLbl then
        local mod = settings.scanModifier or "any"
        local modLabel
        if     mod == "ctrl"  then modLabel = "Ctrl"
        elseif mod == "alt"   then modLabel = "Alt"
        elseif mod == "shift" then modLabel = "Shift"
        elseif mod == "none"  then modLabel = "any key"
        else                       modLabel = "Alt/Shift/Ctrl"
        end
        detailWin._cbModOnlyLbl:SetText("Scan only when holding " .. modLabel)
    end

    rebuildDoodadList()
    detailWin:Show(true)
end

-- ============================================================
-- DOODAD EVENT LISTENER
-- Uses its own window + RegisterEvent. Must NOT be hidden —
-- hidden windows don't receive events in this engine.
-- ============================================================

local function createDoodadListener()
    if doodadListener then return end
    doodadListener = api.Interface:CreateEmptyWindow("ft_doodad_listener")
    -- Do NOT call Show(false) — hidden windows don't receive events

    function doodadListener:OnEvent(event, ...)
        if not settings.autotrackerEnabled then return end
        if event == "DRAW_DOODAD_TOOLTIP" then
            local info = unpack(arg)
            if type(info) == "table" then lastDoodadInfo = info end
        elseif event == "DRAW_DOODAD_SIGN_TAG" then
            local tag = unpack(arg)
            if tag == nil or tag == "" then lastDoodadInfo = nil end
        end
    end
    doodadListener:SetHandler("OnEvent", doodadListener.OnEvent)
end

local function setDoodadListenerEnabled(enabled)
    if enabled then
        createDoodadListener()
        if doodadListener and not doodadListenerRegistered then
            doodadListener:RegisterEvent("DRAW_DOODAD_TOOLTIP")
            doodadListener:RegisterEvent("DRAW_DOODAD_SIGN_TAG")
            doodadListenerRegistered = true
        end
    else
        lastDoodadInfo = nil
        if doodadListener and doodadListenerRegistered then
            if doodadListener.UnregisterEvent then
                pcall(function() doodadListener:UnregisterEvent("DRAW_DOODAD_TOOLTIP") end)
                pcall(function() doodadListener:UnregisterEvent("DRAW_DOODAD_SIGN_TAG") end)
                doodadListenerRegistered = false
            end
        end
    end
end

local function setAutotrackerEnabled(enabled)
    settings.autotrackerEnabled = enabled and true or false
    saveSettings()
    setDoodadListenerEnabled(settings.autotrackerEnabled)
    updateAutotrackerButton()
    if not settings.autotrackerEnabled and autotrackerWin then
        rebuildAutotrackerWindow()
        autotrackerWin:Show(false)
    end
end

local function refreshSettingsLabels()
    if settingsCooledSpotLbl then
        settingsCooledSpotLbl:SetText("Captured cooled tree spots: " .. tostring(#ensureCooledTreeSpots()))
    end
end

local function getSpotCaptureName()
    if settingsSpotNameEdit and settingsSpotNameEdit.GetText then
        local text = settingsSpotNameEdit:GetText()
        if text and text ~= "" then return text end
    end
    return nil
end

local rebuildSpotListWindow

local function captureCooledTreeSpot()
    local pos = capturePlayerPosition()
    if not pos then
        log("Could not capture cooled tree spot: player position unavailable.")
        return nil
    end
    local spot = makeCooledTreeSpot(pos, getSpotCaptureName())
    if settingsSpotNameEdit and settingsSpotNameEdit.SetText then settingsSpotNameEdit:SetText("") end
    refreshSettingsLabels()
    if spotListWin and spotListWin:IsVisible() then rebuildSpotListWindow() end
    log("Captured cooled tree spot: " .. tostring(spot.name))
    return spot
end

rebuildSpotListWindow = function()
    if not spotListWin then return end
    for _, row in ipairs(spotListRows) do
        if row and row.Show then row:Show(false) end
    end
    spotListRows = {}

    local spots = ensureCooledTreeSpots()
    if #spots == 0 then
        local empty = spotListWin:CreateChildWidget("label", "tt_spot_empty_" .. tostring(api.Time:GetUiMsec()), 0, true)
        empty:SetText("No cooled tree spots captured.")
        empty:SetExtent(460, 22)
        empty:AddAnchor("TOPLEFT", spotListWin, 18, 48)
        if empty.style then empty.style:SetFontSize(FONT_SIZE.MIDDLE or 16); empty.style:SetAlign(ALIGN.LEFT) end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(empty, FONT_COLOR.DEFAULT) end
        empty:Show(true)
        table.insert(spotListRows, empty)
        return
    end

    local totalPages = math.max(1, math.ceil(#spots / SPOT_LIST_ROWS))
    if spotListPage > totalPages then spotListPage = totalPages end
    if spotListPage < 1 then spotListPage = 1 end
    if spotListWin._pageLbl then
        spotListWin._pageLbl:SetText(string.format("%d / %d", spotListPage, totalPages))
    end
    if spotListWin._prevBtn and spotListWin._prevBtn.Enable then spotListWin._prevBtn:Enable(spotListPage > 1) end
    if spotListWin._nextBtn and spotListWin._nextBtn.Enable then spotListWin._nextBtn:Enable(spotListPage < totalPages) end

    local startIdx = (spotListPage - 1) * SPOT_LIST_ROWS + 1
    local endIdx = math.min(startIdx + SPOT_LIST_ROWS - 1, #spots)
    for i = startIdx, endIdx do
        local spot = spots[i]
        local rowIndex = i - startIdx + 1
        local y = 68 + ((rowIndex - 1) * 28)
        local row = spotListWin:CreateChildWidget("emptywidget", "tt_spot_row_" .. tostring(api.Time:GetUiMsec()) .. "_" .. i, 0, true)
        row:SetExtent(500, 26)
        row:AddAnchor("TOPLEFT", spotListWin, 12, y)
        row:Show(true)
        table.insert(spotListRows, row)

        local nameLbl = row:CreateChildWidget("label", "tt_spot_name_" .. i, 0, true)
        nameLbl:SetText(spot.name or "Cooled Tree Trunk")
        nameLbl:SetExtent(190, 24)
        nameLbl:AddAnchor("LEFT", row, 4, 0)
        if nameLbl.style then nameLbl.style:SetFontSize(FONT_SIZE.SMALL or 14); nameLbl.style:SetAlign(ALIGN.LEFT) end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(nameLbl, FONT_COLOR.DEFAULT) end
        nameLbl:Show(true)

        local zoneLbl = row:CreateChildWidget("label", "tt_spot_zone_" .. i, 0, true)
        zoneLbl:SetText(spot.zoneName or zoneName(spot.zone))
        zoneLbl:SetExtent(90, 24)
        zoneLbl:AddAnchor("LEFT", row, 200, 0)
        if zoneLbl.style then zoneLbl.style:SetFontSize(FONT_SIZE.SMALL or 14); zoneLbl.style:SetAlign(ALIGN.LEFT) end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(zoneLbl, FONT_COLOR.DEFAULT) end
        zoneLbl:Show(true)

        local coordLbl = row:CreateChildWidget("label", "tt_spot_coord_" .. i, 0, true)
        coordLbl:SetText(spot.sextants or "")
        coordLbl:SetExtent(150, 24)
        coordLbl:AddAnchor("LEFT", row, 294, 0)
        if coordLbl.style then coordLbl.style:SetFontSize(FONT_SIZE.SMALL or 14); coordLbl.style:SetAlign(ALIGN.LEFT) end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(coordLbl, FONT_COLOR.DEFAULT) end
        coordLbl:Show(true)

        local delBtn = row:CreateChildWidget("button", "tt_spot_del_" .. i, 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(delBtn, BUTTON_BASIC.DEFAULT) end
        delBtn:SetExtent(48, 24)
        delBtn:AddAnchor("RIGHT", row, -2, 0)
        delBtn:SetText("Del")
        local capturedIndex = i
        function delBtn:OnClick()
            table.remove(settings.cooledTreeSpots, capturedIndex)
            saveSettings()
            refreshSettingsLabels()
            rebuildSpotListWindow()
        end
        delBtn:SetHandler("OnClick", delBtn.OnClick)
        delBtn:Show(true)
    end
end

local function openSpotListWindow()
    if not spotListWin then
        spotListWin = api.Interface:CreateWindow("tax_tracker_tree_spot_list", "Cooled Tree Spots", 540, 340)
        spotListWin:RemoveAllAnchors()
        spotListWin:AddAnchor("CENTER", "UIParent", 0, 0)
        spotListWin:SetHandler("OnCloseByEsc", function() spotListWin:Show(false) end)

        local bg = spotListWin:CreateColorDrawable(0, 0, 0, 0.55, "background")
        bg:AddAnchor("TOPLEFT", spotListWin, 8, 36)
        bg:AddAnchor("BOTTOMRIGHT", spotListWin, -8, -8)
        bg:Show(true)

        local hdr = spotListWin:CreateChildWidget("label", "tt_spot_hdr", 0, true)
        hdr:SetText("Name                         Zone        Coordinates")
        hdr:SetExtent(500, 20)
        hdr:AddAnchor("TOPLEFT", spotListWin, 18, 42)
        if hdr.style then hdr.style:SetFontSize(FONT_SIZE.SMALL or 14); hdr.style:SetAlign(ALIGN.LEFT) end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(hdr, FONT_COLOR.DEFAULT) end
        hdr:Show(true)

        local prevBtn = spotListWin:CreateChildWidget("button", "tt_spot_prev", 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(prevBtn, BUTTON_BASIC.DEFAULT) end
        prevBtn:SetExtent(80, 26)
        prevBtn:AddAnchor("BOTTOMLEFT", spotListWin, 18, -14)
        prevBtn:SetText("Prev")
        function prevBtn:OnClick()
            spotListPage = spotListPage - 1
            rebuildSpotListWindow()
        end
        prevBtn:SetHandler("OnClick", prevBtn.OnClick)
        prevBtn:Show(true)
        spotListWin._prevBtn = prevBtn

        local pageLbl = spotListWin:CreateChildWidget("label", "tt_spot_page", 0, true)
        pageLbl:SetExtent(80, 26)
        pageLbl:AddAnchor("BOTTOM", spotListWin, 0, -14)
        pageLbl:SetText("1 / 1")
        if pageLbl.style then pageLbl.style:SetFontSize(FONT_SIZE.SMALL or 14); pageLbl.style:SetAlign(ALIGN.CENTER) end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(pageLbl, FONT_COLOR.DEFAULT) end
        pageLbl:Show(true)
        spotListWin._pageLbl = pageLbl

        local nextBtn = spotListWin:CreateChildWidget("button", "tt_spot_next", 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(nextBtn, BUTTON_BASIC.DEFAULT) end
        nextBtn:SetExtent(80, 26)
        nextBtn:AddAnchor("BOTTOMRIGHT", spotListWin, -18, -14)
        nextBtn:SetText("Next")
        function nextBtn:OnClick()
            spotListPage = spotListPage + 1
            rebuildSpotListWindow()
        end
        nextBtn:SetHandler("OnClick", nextBtn.OnClick)
        nextBtn:Show(true)
        spotListWin._nextBtn = nextBtn
    end

    spotListPage = 1
    rebuildSpotListWindow()
    spotListWin:Show(true)
end

-- ============================================================
-- UPDATE LOOP  — scan capture + live time refresh
-- ============================================================

local function OnUpdate(dt)
    -- Scan capture: modifier held + doodad hovered. If a farm detail is open,
    -- scan straight into it; otherwise ask which saved land this timer belongs to.
    if settings.autotrackerEnabled and lastDoodadInfo and not (landPickerWin and landPickerWin:IsVisible()) then
        local mod = settings.scanModifier or "any"
        local farm = (detailWin and detailWin:IsVisible() and detailFarmId) and getFarmById(detailFarmId) or nil
        local requireMod = farm and farm.requireModifier
        if requireMod == nil then requireMod = true end
        local effectiveMod = requireMod and mod or "none"
        local modDown =
            (effectiveMod == "any"   and (api.Input:IsControlKeyDown() or api.Input:IsAltKeyDown() or api.Input:IsShiftKeyDown())) or
            (effectiveMod == "ctrl"  and api.Input:IsControlKeyDown()) or
            (effectiveMod == "alt"   and api.Input:IsAltKeyDown()) or
            (effectiveMod == "shift" and api.Input:IsShiftKeyDown()) or
            (effectiveMod == "none"  and true)
        if modDown then
            local info = lastDoodadInfo
            if isCooledTreeInfo(info) then
                local pos = capturePlayerPosition()
                if pos then
                    local z = zoneName(pos.zone)
                    local spot = nil
                    if z == "Marcala" or z == "Calmlands" then
                        spot = findNearestCooledTreeSpot(pos)
                        if not spot then
                            log("No captured cooled tree spot in " .. tostring(z) .. ". Capture the spot first in settings.")
                        else
                            local cooledFarm = ensureFarmForCooledTreeSpot(spot)
                            if cooledFarm and tryAddDoodad(cooledFarm, info) then
                                addAutotrackerItem(cooledFarm, "Cooled Tree Trunk", true)
                                if detailWin and detailWin:IsVisible() and detailFarmId == cooledFarm.id then
                                    rebuildDoodadList()
                                end
                            end
                        end
                    end
                end
            elseif farm and tryAddDoodad(farm, info) then
                addAutotrackerItem(farm, info.name, false)
                rebuildDoodadList()
            elseif not farm and openLandPickerWindow then
                openLandPickerWindow(info)
            end
            lastDoodadInfo = nil
        end
    end

    if autotrackerWin and autotrackerWin:IsVisible() then
        updateAutotrackerTimeLabels()
    end

    updateMainListTimeLabels()
    updateFarmMinuteReminders()

    -- Live time label refresh (only when detail window is open)
    if not (detailWin and detailWin:IsVisible()) then return end
    if #detailTimeLbls == 0 then return end

    local farm = detailFarmId and getFarmById(detailFarmId)
    if not farm then return end

    for _, item in ipairs(detailTimeLbls) do
        if item.lbl then
            if item.kind == "entry" then
                -- Individual entry row: update directly from entry
                if item.entry then
                    item.lbl:SetText(formatTime(adjustedTime(item.entry)))
                end
            else
                -- Header earliest/latest
                local val = nil
                for _, d in ipairs(farm.doodads or {}) do
                    local nameMatch  = d.name == item.groupName
                    local ownerMatch = settings.groupBy ~= "name_owner"
                                    or (d.owner or "") == (item.groupOwner or "")
                    if nameMatch and ownerMatch then
                        local t = adjustedTime(d)
                        if item.kind == "earliest" then
                            if val == nil or t < val then val = t end
                        else
                            if val == nil or t > val then val = t end
                        end
                    end
                end
                if val ~= nil then item.lbl:SetText(formatTime(val)) end
            end
        end
    end
end

-- ============================================================
-- PER-FARM FILTER WINDOW
-- ============================================================

local FW_W           = 600
local FW_H           = 420
local FW_COL_W       = 270   -- width of each column
local FW_ROW_H       = 26
local FW_ROWS_PER_PAGE = 10
local fwSeq     = 0
local function fwId() fwSeq = fwSeq + 1; return fwSeq end

local function makeFilterCheckbox(parent, id, x, y, checked, onToggle)
    local cb = parent:CreateChildWidget("checkbutton", "ft_fw_cb_"..id, 0, true)
    cb:SetExtent(18, 17)
    cb:AddAnchor("TOPLEFT", parent, x, y)
    local bgs = {}
    local coords = {
        {0,0,18,17},{0,0,18,17},{0,0,18,17},
        {0,17,18,17},{18,0,18,17},{18,17,18,17}
    }
    for i = 1, 6 do
        bgs[i] = cb:CreateImageDrawable("ui/button/check_button.dds", "background")
        bgs[i]:SetExtent(16,16)
        bgs[i]:AddAnchor("CENTER", cb, 0, 0)
        bgs[i]:SetTexture("ui/button/check_button.dds")
        local c = coords[i]
        bgs[i]:SetCoords(c[1],c[2],c[3],c[4])
    end
    cb:SetNormalBackground(bgs[1])
    cb:SetHighlightBackground(bgs[2])
    cb:SetPushedBackground(bgs[3])
    cb:SetDisabledBackground(bgs[4])
    cb:SetCheckedBackground(bgs[5])
    cb:SetDisabledCheckedBackground(bgs[6])
    cb:SetChecked(checked)
    function cb:OnCheckChanged() onToggle(self:GetChecked()) end
    cb:SetHandler("OnCheckChanged", cb.OnCheckChanged)
    cb:Show(true)
    return cb
end

local function rebuildFilterLists(farm)
    if not filterWin then return end
    filterRebuildId = filterRebuildId + 1
    local rid = filterRebuildId

    -- Hide old containers
    if filterWin._playerContainer then filterWin._playerContainer:Show(false) end
    if filterWin._entityContainer then filterWin._entityContainer:Show(false) end

    local players  = farm.scanPlayers  or {}
    local entities = farm.scanEntities or {}

    -- Clamp pages
    local pTotalPages = math.max(1, math.ceil(#players  / FW_ROWS_PER_PAGE))
    local eTotalPages = math.max(1, math.ceil(#entities / FW_ROWS_PER_PAGE))
    if filterPlayerPage > pTotalPages then filterPlayerPage = pTotalPages end
    if filterEntityPage > eTotalPages then filterEntityPage = eTotalPages end

    -- Update pagination controls
    if filterWin._pPageCtrl then
        filterWin._pPageCtrl:SetPageCount(pTotalPages, FW_ROWS_PER_PAGE, false)
        filterWin._pPageCtrl:SetCurrentPage(filterPlayerPage, false)
    end
    if filterWin._ePageCtrl then
        filterWin._ePageCtrl:SetPageCount(eTotalPages, FW_ROWS_PER_PAGE, false)
        filterWin._ePageCtrl:SetCurrentPage(filterEntityPage, false)
    end

    local function buildColumn(list, page, containerName, xOff)
        local startIdx = (page - 1) * FW_ROWS_PER_PAGE + 1
        local endIdx   = math.min(startIdx + FW_ROWS_PER_PAGE - 1, #list)
        local rowCount = math.max(1, endIdx - startIdx + 1)

        local c = filterWin:CreateChildWidget("emptywidget", containerName.."_"..rid, 0, true)
        c:SetExtent(FW_COL_W, rowCount * FW_ROW_H)
        c:RemoveAllAnchors()
        c:AddAnchor("TOPLEFT", filterWin, xOff, 90)
        c:Show(true)

        if #list == 0 then
            local lbl = c:CreateChildWidget("label", containerName.."_empty_"..rid, 0, true)
            lbl:SetText(xOff < 200 and "No players scanned yet." or "No entities scanned yet.")
            lbl:AddAnchor("TOPLEFT", c, 0, 4)
            lbl:SetAutoResize(true)
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(lbl, FONT_COLOR.MIDDLE_GRAY or FONT_COLOR.DEFAULT) end
            lbl:Show(true)
        else
            for i = startIdx, endIdx do
                local entry = list[i]
                local y     = (i - startIdx) * FW_ROW_H
                local uid   = fwId()
                local captured = entry
                makeFilterCheckbox(c, uid, 0, y+1, entry.enabled, function(val)
                    captured.enabled = val
                    saveFarm(farm)
                end)
                local lbl = c:CreateChildWidget("label", containerName.."_lbl_"..uid, 0, true)
                lbl:SetExtent(FW_COL_W - 26, FW_ROW_H)
                lbl:AddAnchor("TOPLEFT", c, 24, y-6)
                lbl:SetText(entry.name ~= "" and entry.name or "(no owner)")
                lbl:SetAutoResize(false)
                if lbl.style then lbl.style:SetAlign(ALIGN.LEFT); lbl.style:SetFontSize(FONT_SIZE.MIDDLE or 16) end
                if ApplyTextColor and FONT_COLOR then ApplyTextColor(lbl, FONT_COLOR.DEFAULT) end
                lbl:Show(true)
            end
        end
        return c
    end

    filterWin._playerContainer = buildColumn(players,  filterPlayerPage, "ft_fw_pc", 10)
    filterWin._entityContainer = buildColumn(entities, filterEntityPage, "ft_fw_ec", 320)
end

openFilterWindow = function(farm)
    if not filterWin then
        filterWin = api.Interface:CreateWindow("tax_tracker_farm_filters", "Scan Filters", FW_W, FW_H)
        filterWin:RemoveAllAnchors()
        filterWin:AddAnchor("CENTER", "UIParent", 0, 0)

        -- Column headers
        local hdrPlayers = filterWin:CreateChildWidget("label", "ft_fw_hdr_p", 0, true)
        hdrPlayers:SetExtent(FW_COL_W - 28, 24)
        hdrPlayers:AddAnchor("TOPLEFT", filterWin, 36, 44)
        hdrPlayers:SetText("Scan only from these players:")
        if hdrPlayers.style then hdrPlayers.style:SetFontSize(FONT_SIZE.LARGE or 18); hdrPlayers.style:SetAlign(ALIGN.LEFT) end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(hdrPlayers, FONT_COLOR.DEFAULT) end
        hdrPlayers:Show(true)

        -- Player filter enable checkbox
        local function makeInlineCb(widgetId, xOff, yOff, onChanged)
            local cb = filterWin:CreateChildWidget("checkbutton", widgetId, 0, true)
            cb:SetExtent(18, 17)
            cb:RemoveAllAnchors()
            cb:AddAnchor("TOPLEFT", filterWin, xOff, yOff)
            local bgs = {}
            local coords = { {0,0,18,17},{0,0,18,17},{0,0,18,17},{0,17,18,17},{18,0,18,17},{18,17,18,17} }
            for j = 1, 6 do
                bgs[j] = cb:CreateImageDrawable("ui/button/check_button.dds", "background")
                bgs[j]:SetExtent(16, 16); bgs[j]:AddAnchor("CENTER", cb, 0, 0)
                bgs[j]:SetTexture("ui/button/check_button.dds")
                local c = coords[j]; bgs[j]:SetCoords(c[1], c[2], c[3], c[4])
            end
            cb:SetNormalBackground(bgs[1]); cb:SetHighlightBackground(bgs[2])
            cb:SetPushedBackground(bgs[3]); cb:SetDisabledBackground(bgs[4])
            cb:SetCheckedBackground(bgs[5]); cb:SetDisabledCheckedBackground(bgs[6])
            cb:SetChecked(true)
            function cb:OnCheckChanged() onChanged(self:GetChecked()) end
            cb:SetHandler("OnCheckChanged", cb.OnCheckChanged)
            cb:Show(true)
            return cb
        end

        filterWin._cbPlayerFilter = makeInlineCb("ft_fw_cb_pfilter", 10, 46, function(val)
            if filterWin._currentFarm then
                filterWin._currentFarm.filterPlayersEnabled = val
                saveFarm(filterWin._currentFarm)
                rebuildFilterLists(filterWin._currentFarm)
            end
        end)

        local hdrEntities = filterWin:CreateChildWidget("label", "ft_fw_hdr_e", 0, true)
        hdrEntities:SetExtent(FW_COL_W - 28, 24)
        hdrEntities:AddAnchor("TOPLEFT", filterWin, 346, 44)
        hdrEntities:SetText("Scan only these entities:")
        if hdrEntities.style then hdrEntities.style:SetFontSize(FONT_SIZE.LARGE or 18); hdrEntities.style:SetAlign(ALIGN.LEFT) end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(hdrEntities, FONT_COLOR.DEFAULT) end
        hdrEntities:Show(true)

        filterWin._cbEntityFilter = makeInlineCb("ft_fw_cb_efilter", 320, 46, function(val)
            if filterWin._currentFarm then
                filterWin._currentFarm.filterEntitiesEnabled = val
                saveFarm(filterWin._currentFarm)
                rebuildFilterLists(filterWin._currentFarm)
            end
        end)

        -- Column divider
        local div = filterWin:CreateColorDrawable(0.3, 0.3, 0.5, 0.5, "background")
        div:SetExtent(1, FW_H - 80)
        div:RemoveAllAnchors()
        div:AddAnchor("TOPLEFT", filterWin, 308, 44)
        div:Show(true)

        -- Separator below headers
        local sep = filterWin:CreateColorDrawable(0.3, 0.3, 0.5, 0.5, "background")
        sep:SetExtent(FW_W - 20, 1)
        sep:RemoveAllAnchors()
        sep:AddAnchor("TOPLEFT", filterWin, 10, 76)
        sep:Show(true)

        -- Bottom separator
        local sepBot = filterWin:CreateColorDrawable(0.3, 0.3, 0.5, 0.5, "background")
        sepBot:SetExtent(FW_W - 20, 1)
        sepBot:RemoveAllAnchors()
        sepBot:AddAnchor("BOTTOMLEFT", filterWin, 10, -46)
        sepBot:Show(true)

        -- Reset button (bottom-right)
        local btnReset = filterWin:CreateChildWidget("button", "ft_fw_reset", 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(btnReset, BUTTON_BASIC.DEFAULT) end
        btnReset:SetExtent(70, 28)
        btnReset:AddAnchor("BOTTOMRIGHT", filterWin, -10, -10)
        btnReset:SetText("Reset")
        if btnReset.style then btnReset.style:SetColor(1, 0.5, 0.2, 1) end
        filterWin._btnReset = btnReset
        btnReset:Show(true)

        filterWin._playerContainer = filterWin:CreateChildWidget("emptywidget", "ft_fw_pc_init", 0, true)
        filterWin._playerContainer:SetExtent(FW_COL_W, 10)
        filterWin._playerContainer:AddAnchor("TOPLEFT", filterWin, 10, 90)
        filterWin._entityContainer = filterWin:CreateChildWidget("emptywidget", "ft_fw_ec_init", 0, true)
        filterWin._entityContainer:SetExtent(FW_COL_W, 10)
        filterWin._entityContainer:AddAnchor("TOPLEFT", filterWin, 320, 90)

        -- Pagination for player column
        local pPageCtrl = W_CTRL.CreatePageControl("ft_fw_p_pagectrl", filterWin, "tutorial")
        pPageCtrl:RemoveAllAnchors()
        pPageCtrl:AddAnchor("BOTTOMLEFT", filterWin, 10, -10)
        function pPageCtrl:ProcOnPageChanged(pageIndex)
            filterPlayerPage = pageIndex
            rebuildFilterLists(filterWin._currentFarm)
        end
        pPageCtrl:Show(true)
        filterWin._pPageCtrl = pPageCtrl

        -- Pagination for entity column
        local ePageCtrl = W_CTRL.CreatePageControl("ft_fw_e_pagectrl", filterWin, "tutorial")
        ePageCtrl:RemoveAllAnchors()
        ePageCtrl:AddAnchor("BOTTOM", filterWin, 90, -10)
        function ePageCtrl:ProcOnPageChanged(pageIndex)
            filterEntityPage = pageIndex
            rebuildFilterLists(filterWin._currentFarm)
        end
        ePageCtrl:Show(true)
        filterWin._ePageCtrl = ePageCtrl
    end

    -- Wire reset button to current farm
    filterWin._currentFarm = farm
    filterPlayerPage = 1
    filterEntityPage = 1
    filterWin._btnReset:SetHandler("OnClick", function()
        farm.scanPlayers  = {}
        farm.scanEntities = {}
        saveFarm(farm)
        rebuildFilterLists(farm)
    end)

    -- Sync default checkbox to farm setting
    if filterWin._cbPlayerFilter then
        local v = farm.filterPlayersEnabled; if v == nil then v = true end
        filterWin._cbPlayerFilter:SetChecked(v)
    end
    if filterWin._cbEntityFilter then
        local v = farm.filterEntitiesEnabled; if v == nil then v = true end
        filterWin._cbEntityFilter:SetChecked(v)
    end

    rebuildFilterLists(farm)
    filterWin:Show(true)
end

-- ============================================================
-- FLOATING BUTTON
-- ============================================================

local function destroyFloatingBtn()
    if floatingBtn then
        floatingBtn:Show(false)
        floatingBtn = nil
        floatingAutoBtn = nil
    end
end

local function createFloatingBtn()
    if floatingBtn then return end

    floatingBtnSeq = floatingBtnSeq + 1
    floatingBtn = api.Interface:CreateEmptyWindow("ft_floating_btn_"..floatingBtnSeq, "UIParent")
    floatingBtn.background = floatingBtn:CreateNinePartDrawable(TEXTURE_PATH.HUD, "background")
    floatingBtn.background:SetTextureInfo("bg_quest")
    floatingBtn.background:SetColor(0, 0, 0, 0.6)
    floatingBtn.background:AddAnchor("TOPLEFT", floatingBtn, 0, 0)
    floatingBtn.background:AddAnchor("BOTTOMRIGHT", floatingBtn, 0, 0)
    floatingBtn:AddAnchor("TOPLEFT", "UIParent", settings.floatingBtnX or 200, settings.floatingBtnY or 200)
    settings.floatingBtnX = settings.floatingBtnX or 200
    settings.floatingBtnY = settings.floatingBtnY or 200
    saveSettings()
    floatingBtn:SetExtent(120, 40)

    function floatingBtn:OnDragStart()
        if api.Input:IsShiftKeyDown() then
            floatingBtn:StartMoving()
            api.Cursor:ClearCursor()
            api.Cursor:SetCursorImage(CURSOR_PATH.MOVE, 0, 0)
        end
    end
    floatingBtn:SetHandler("OnDragStart", floatingBtn.OnDragStart)

    function floatingBtn:OnDragStop()
        local x, y = floatingBtn:GetEffectiveOffset()
        settings.floatingBtnX = x
        settings.floatingBtnY = y
        saveSettings()
        floatingBtn:StopMovingOrSizing()
        api.Cursor:ClearCursor()
    end
    floatingBtn:SetHandler("OnDragStop", floatingBtn.OnDragStop)

    local btn = api.Interface:CreateWidget("button", "ft_floating_inner_btn_"..floatingBtnSeq, floatingBtn)
    api.Interface:ApplyButtonSkin(btn, BUTTON_BASIC.DEFAULT)
    btn:SetExtent(110, 28)
    btn:RemoveAllAnchors()
    btn:AddAnchor("TOPLEFT", floatingBtn, 5, 6)
    btn:SetText(settings.autotrackerEnabled and "Auto: ON" or "Auto: OFF")
    btn.OnClick = function(self)
        setAutotrackerEnabled(not settings.autotrackerEnabled)
        self:SetText(settings.autotrackerEnabled and "Auto: ON" or "Auto: OFF")
    end
    btn:SetHandler("OnClick", btn.OnClick)
    btn:Show(true)
    floatingAutoBtn = btn

    floatingBtn:Show(true)
    floatingBtn:EnableDrag(true)
end

-- ============================================================
-- SETTINGS WINDOW
-- ============================================================

local SETTINGS_W = 390
local SETTINGS_H = 360

local function openSettingsWindow()
    if settingsWin then
        refreshSettingsLabels()
        settingsWin:Show(true)
        return
    end

    settingsWin = api.Interface:CreateWindow("tax_tracker_farm_settings", "Farm Tracker Settings", SETTINGS_W, SETTINGS_H)
    settingsWin:RemoveAllAnchors()
    settingsWin:AddAnchor("CENTER", "UIParent", 0, 0)
    settingsWin:SetHandler("OnCloseByEsc", function() settingsWin:Show(false) end)

    local bg = settingsWin:CreateColorDrawable(0, 0, 0, 0.55, "background")
    bg:AddAnchor("TOPLEFT", settingsWin, 8, 36)
    bg:AddAnchor("BOTTOMRIGHT", settingsWin, -8, -8)
    bg:Show(true)

    -- Modifier key label
    local modLbl = settingsWin:CreateChildWidget("label", "ft_sw_mod_lbl", 0, true)
    modLbl:SetExtent(200, 24)
    modLbl:AddAnchor("TOPLEFT", settingsWin, 18, 48)
    modLbl:SetText("Scan trigger key:")
    if modLbl.style then modLbl.style:SetFontSize(FONT_SIZE.LARGE or 18); modLbl.style:SetAlign(ALIGN.LEFT) end
    if ApplyTextColor and FONT_COLOR then ApplyTextColor(modLbl, FONT_COLOR.DEFAULT) end
    modLbl:Show(true)

    local MOD_OPTIONS = { "Any modifier", "Ctrl", "Alt", "Shift", "None required" }
    local MOD_VALUES  = { "any", "ctrl", "alt", "shift", "none" }
    local function modIndexFromValue(v)
        for i, val in ipairs(MOD_VALUES) do if val == v then return i end end
        return 1
    end

    local ok, combo = pcall(function() return api.Interface:CreateComboBox(settingsWin) end)
    if ok and combo then
        combo:RemoveAllAnchors()
        combo:AddAnchor("TOPLEFT", settingsWin, 160, 48)
        combo:SetWidth(190)
        combo.dropdownItem = MOD_OPTIONS
        combo:Select(modIndexFromValue(settings.scanModifier or "any"))
        function combo:SelectedProc()
            settings.scanModifier = MOD_VALUES[self:GetSelectedIndex()] or "any"
            saveSettings()
        end
    else
        local cycleBtn = settingsWin:CreateChildWidget("button", "ft_sw_mod_cycle", 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(cycleBtn, BUTTON_BASIC.DEFAULT) end
        cycleBtn:SetExtent(190, 24)
        cycleBtn:AddAnchor("TOPLEFT", settingsWin, 160, 48)
        local function updateCycleBtn()
            cycleBtn:SetText(MOD_OPTIONS[modIndexFromValue(settings.scanModifier or "any")] or "Any modifier")
        end
        updateCycleBtn()
        function cycleBtn:OnClick()
            local idx = (modIndexFromValue(settings.scanModifier or "any") % #MOD_VALUES) + 1
            settings.scanModifier = MOD_VALUES[idx]
            saveSettings()
            updateCycleBtn()
        end
        cycleBtn:SetHandler("OnClick", cycleBtn.OnClick)
        cycleBtn:Show(true)
    end

    -- "Show Autotracker button" checkbox
    local cbFloat = settingsWin:CreateChildWidget("checkbutton", "ft_sw_cb_float", 0, true)
    cbFloat:SetExtent(18, 17)
    cbFloat:RemoveAllAnchors()
    cbFloat:AddAnchor("TOPLEFT", settingsWin, 18, 88)
    local cbfBgs = {}
    local cbfCoords = { {0,0,18,17},{0,0,18,17},{0,0,18,17},{0,17,18,17},{18,0,18,17},{18,17,18,17} }
    for j = 1, 6 do
        cbfBgs[j] = cbFloat:CreateImageDrawable("ui/button/check_button.dds", "background")
        cbfBgs[j]:SetExtent(16, 16); cbfBgs[j]:AddAnchor("CENTER", cbFloat, 0, 0)
        cbfBgs[j]:SetTexture("ui/button/check_button.dds")
        local c = cbfCoords[j]; cbfBgs[j]:SetCoords(c[1], c[2], c[3], c[4])
    end
    cbFloat:SetNormalBackground(cbfBgs[1]); cbFloat:SetHighlightBackground(cbfBgs[2])
    cbFloat:SetPushedBackground(cbfBgs[3]); cbFloat:SetDisabledBackground(cbfBgs[4])
    cbFloat:SetCheckedBackground(cbfBgs[5]); cbFloat:SetDisabledCheckedBackground(cbfBgs[6])
    cbFloat:SetChecked(settings.showFloatingBtn and true or false)
    function cbFloat:OnCheckChanged()
        settings.showFloatingBtn = self:GetChecked()
        saveSettings()
        if settings.showFloatingBtn then
            createFloatingBtn()
        else
            destroyFloatingBtn()
        end
    end
    cbFloat:SetHandler("OnCheckChanged", cbFloat.OnCheckChanged)
    cbFloat:Show(true)
    settingsWin._cbFloat = cbFloat

    local cbFloatLbl = settingsWin:CreateChildWidget("label", "ft_sw_float_lbl", 0, true)
    cbFloatLbl:SetText("Show Autotracker button")
    cbFloatLbl:SetAutoResize(true)
    cbFloatLbl:AddAnchor("LEFT", cbFloat, "RIGHT", 4, 0)
    if cbFloatLbl.style then cbFloatLbl.style:SetAlign(ALIGN.LEFT); cbFloatLbl.style:SetFontSize(FONT_SIZE.MIDDLE or 16) end
    if ApplyTextColor and FONT_COLOR then ApplyTextColor(cbFloatLbl, FONT_COLOR.DEFAULT) end
    cbFloatLbl:Show(true)

    -- "1-minute farm reminder" checkbox
    local cbFarmReminder = settingsWin:CreateChildWidget("checkbutton", "ft_sw_cb_farm_reminder", 0, true)
    cbFarmReminder:SetExtent(18, 17)
    cbFarmReminder:RemoveAllAnchors()
    cbFarmReminder:AddAnchor("TOPLEFT", settingsWin, 18, 118)
    local cbrBgs = {}
    local cbrCoords = { {0,0,18,17},{0,0,18,17},{0,0,18,17},{0,17,18,17},{18,0,18,17},{18,17,18,17} }
    for j = 1, 6 do
        cbrBgs[j] = cbFarmReminder:CreateImageDrawable("ui/button/check_button.dds", "background")
        cbrBgs[j]:SetExtent(16, 16); cbrBgs[j]:AddAnchor("CENTER", cbFarmReminder, 0, 0)
        cbrBgs[j]:SetTexture("ui/button/check_button.dds")
        local c = cbrCoords[j]; cbrBgs[j]:SetCoords(c[1], c[2], c[3], c[4])
    end
    cbFarmReminder:SetNormalBackground(cbrBgs[1]); cbFarmReminder:SetHighlightBackground(cbrBgs[2])
    cbFarmReminder:SetPushedBackground(cbrBgs[3]); cbFarmReminder:SetDisabledBackground(cbrBgs[4])
    cbFarmReminder:SetCheckedBackground(cbrBgs[5]); cbFarmReminder:SetDisabledCheckedBackground(cbrBgs[6])
    cbFarmReminder:SetChecked(settings.farmMinuteReminderEnabled and true or false)
    function cbFarmReminder:OnCheckChanged()
        settings.farmMinuteReminderEnabled = self:GetChecked()
        saveSettings()
    end
    cbFarmReminder:SetHandler("OnCheckChanged", cbFarmReminder.OnCheckChanged)
    cbFarmReminder:Show(true)

    local cbFarmReminderLbl = settingsWin:CreateChildWidget("label", "ft_sw_farm_reminder_lbl", 0, true)
    cbFarmReminderLbl:SetText("1-minute farm reminder popup")
    cbFarmReminderLbl:SetAutoResize(true)
    cbFarmReminderLbl:AddAnchor("LEFT", cbFarmReminder, "RIGHT", 4, 0)
    if cbFarmReminderLbl.style then cbFarmReminderLbl.style:SetAlign(ALIGN.LEFT); cbFarmReminderLbl.style:SetFontSize(FONT_SIZE.MIDDLE or 16) end
    if ApplyTextColor and FONT_COLOR then ApplyTextColor(cbFarmReminderLbl, FONT_COLOR.DEFAULT) end
    cbFarmReminderLbl:Show(true)

    local spotHeader = settingsWin:CreateChildWidget("label", "ft_sw_spot_header", 0, true)
    spotHeader:SetText("Cooled Tree Trunk Spots")
    spotHeader:SetExtent(340, 20)
    spotHeader:AddAnchor("TOPLEFT", settingsWin, 18, 154)
    if spotHeader.style then spotHeader.style:SetAlign(ALIGN.LEFT); spotHeader.style:SetFontSize(FONT_SIZE.LARGE or 18) end
    if ApplyTextColor and FONT_COLOR then ApplyTextColor(spotHeader, FONT_COLOR.DEFAULT) end
    spotHeader:Show(true)

    settingsCooledSpotLbl = settingsWin:CreateChildWidget("label", "ft_sw_spot_count", 0, true)
    settingsCooledSpotLbl:SetExtent(340, 20)
    settingsCooledSpotLbl:AddAnchor("TOPLEFT", settingsWin, 18, 180)
    if settingsCooledSpotLbl.style then settingsCooledSpotLbl.style:SetAlign(ALIGN.LEFT); settingsCooledSpotLbl.style:SetFontSize(FONT_SIZE.MIDDLE or 16) end
    if ApplyTextColor and FONT_COLOR then ApplyTextColor(settingsCooledSpotLbl, FONT_COLOR.DEFAULT) end
    settingsCooledSpotLbl:Show(true)

    local spotNameLbl = settingsWin:CreateChildWidget("label", "ft_sw_spot_name_lbl", 0, true)
    spotNameLbl:SetText("Spot name:")
    spotNameLbl:SetExtent(90, 24)
    spotNameLbl:AddAnchor("TOPLEFT", settingsWin, 18, 208)
    if spotNameLbl.style then spotNameLbl.style:SetAlign(ALIGN.LEFT); spotNameLbl.style:SetFontSize(FONT_SIZE.MIDDLE or 16) end
    if ApplyTextColor and FONT_COLOR then ApplyTextColor(spotNameLbl, FONT_COLOR.DEFAULT) end
    spotNameLbl:Show(true)

    if W_CTRL and W_CTRL.CreateEdit then
        settingsSpotNameEdit = W_CTRL.CreateEdit("ft_sw_spot_name_edit", settingsWin)
    else
        settingsSpotNameEdit = settingsWin:CreateChildWidget("edit", "ft_sw_spot_name_edit", 0, true)
    end
    settingsSpotNameEdit:SetExtent(245, 28)
    settingsSpotNameEdit:AddAnchor("TOPLEFT", settingsWin, 105, 204)
    settingsSpotNameEdit:SetText("")
    settingsSpotNameEdit:Show(true)

    local captureSpotBtn = settingsWin:CreateChildWidget("button", "ft_sw_capture_tree_spot", 0, true)
    if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(captureSpotBtn, BUTTON_BASIC.DEFAULT) end
    captureSpotBtn:SetExtent(180, 28)
    captureSpotBtn:AddAnchor("TOPLEFT", settingsWin, 18, 244)
    captureSpotBtn:SetText("Capture Current Spot")
    function captureSpotBtn:OnClick()
        captureCooledTreeSpot()
    end
    captureSpotBtn:SetHandler("OnClick", captureSpotBtn.OnClick)
    captureSpotBtn:Show(true)

    local listSpotsBtn = settingsWin:CreateChildWidget("button", "ft_sw_list_tree_spots", 0, true)
    if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(listSpotsBtn, BUTTON_BASIC.DEFAULT) end
    listSpotsBtn:SetExtent(130, 28)
    listSpotsBtn:AddAnchor("LEFT", captureSpotBtn, "RIGHT", 10, 0)
    listSpotsBtn:SetText("List Spots")
    function listSpotsBtn:OnClick()
        openSpotListWindow()
    end
    listSpotsBtn:SetHandler("OnClick", listSpotsBtn.OnClick)
    listSpotsBtn:Show(true)

    local clearSpotsBtn = settingsWin:CreateChildWidget("button", "ft_sw_clear_tree_spots", 0, true)
    if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(clearSpotsBtn, BUTTON_BASIC.DEFAULT) end
    clearSpotsBtn:SetExtent(130, 28)
    clearSpotsBtn:AddAnchor("TOPLEFT", settingsWin, 18, 280)
    clearSpotsBtn:SetText("Clear Spots")
    function clearSpotsBtn:OnClick()
        settings.cooledTreeSpots = {}
        saveSettings()
        refreshSettingsLabels()
        if spotListWin and spotListWin:IsVisible() then rebuildSpotListWindow() end
    end
    clearSpotsBtn:SetHandler("OnClick", clearSpotsBtn.OnClick)
    clearSpotsBtn:Show(true)

    refreshSettingsLabels()

    settingsWin:Show(true)
end

-- ============================================================
-- MAIN WINDOW — farm list
-- ============================================================

local ROW_H          = 44
local NAME_W         = 250
local ZONE_W         = 160
local EARLIEST_W     = 120
local BTN_W          = 52
local GAP            = 8
local SCROLL_Y_START = 78

local COL_NAME_X = 12
local COL_ZONE_X = COL_NAME_X + NAME_W + GAP
local COL_EARLIEST_X = COL_ZONE_X + ZONE_W + GAP
local BTN_Y_OFF  = -math.floor(ROW_H / 2) + 23

rebuildFarmList = function()
    if not mainWin then return end

    mainListRebuildId = mainListRebuildId + 1
    local rid = mainListRebuildId

    local filtered = farms

    local totalPages = math.max(1, math.ceil(#filtered / ROWS_PER_PAGE))
    if currentPage > totalPages then currentPage = totalPages end
    if currentPage < 1          then currentPage = 1          end

    if mainWin._pageCtrl then
        mainWin._pageCtrl:SetPageCount(totalPages, ROWS_PER_PAGE, false)
        mainWin._pageCtrl:SetCurrentPage(currentPage, false)
    end

    for _, row in ipairs(mainListRows) do
        if row and row.Show then row:Show(false) end
    end
    mainListRows = {}
    mainListTimeLbls = {}

    if mainListContent and mainListContent.Show then mainListContent:Show(false) end

    local startIdx = (currentPage - 1) * ROWS_PER_PAGE + 1
    local endIdx   = math.min(startIdx + ROWS_PER_PAGE - 1, #filtered)
    local pageRows = {}
    for i = startIdx, endIdx do table.insert(pageRows, filtered[i]) end

    local contentH = math.max(1, #pageRows) * ROW_H
    mainListContent = mainWin:CreateChildWidget("emptywidget", "ft_list_content_"..rid, 0, true)
    mainListContent:SetExtent(MAIN_W - 24, contentH)
    mainListContent:RemoveAllAnchors()
    mainListContent:AddAnchor("TOPLEFT", mainWin, 4, SCROLL_Y_START)
    mainListContent:Show(true)

    if #filtered == 0 then
        local emptyLbl = mainListContent:CreateChildWidget("label", "ft_empty_lbl", 0, true)
        emptyLbl:SetText("No farms yet. Click [+ Add Land] to create one.")
        emptyLbl:AddAnchor("TOPLEFT", mainListContent, 10, 10)
        emptyLbl:SetAutoResize(true)
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(emptyLbl, FONT_COLOR.DEFAULT) end
        emptyLbl:Show(true)
        return
    end

    for i, farm in ipairs(pageRows) do
        local yOff = (i - 1) * ROW_H

        local rowBg = mainListContent:CreateChildWidget("emptywidget", "ft_row_bg_"..rid.."_"..i, 0, true)
        rowBg:SetExtent(MAIN_W - 24, ROW_H - 2)
        rowBg:RemoveAllAnchors()
        rowBg:AddAnchor("TOPLEFT", mainListContent, 0, yOff)
        local rowShade
        if i % 2 == 0 then
            rowShade = rowBg:CreateColorDrawable(0.08, 0.10, 0.13, 0.62, "background")
        else
            rowShade = rowBg:CreateColorDrawable(0.02, 0.02, 0.02, 0.42, "background")
        end
        rowShade:AddAnchor("TOPLEFT", rowBg, 0, 0)
        rowShade:AddAnchor("BOTTOMRIGHT", rowBg, 0, 0)
        rowShade:Show(true)
        rowBg:Show(true)
        table.insert(mainListRows, rowBg)

        local function makeRowLbl(name, txt, x, w, sz)
            local lbl = rowBg:CreateChildWidget("label", name, 0, true)
            lbl:SetExtent(w, ROW_H)
            lbl:RemoveAllAnchors()
            lbl:AddAnchor("LEFT", rowBg, x, 0)
            lbl:SetText(txt)
            lbl:SetAutoResize(false)
            if lbl.style then lbl.style:SetAlign(ALIGN.LEFT); lbl.style:SetFontSize(sz) end
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(lbl, FONT_COLOR.DEFAULT) end
            lbl:Show(true)
            return lbl
        end
        makeRowLbl("ft_row_name_"..rid.."_"..i, fitText(farm.name or "", 32), COL_NAME_X, NAME_W, FONT_SIZE.MIDDLE or 16)
        makeRowLbl("ft_row_zone_"..rid.."_"..i, fitText(zoneName(farm.zone), 22), COL_ZONE_X, ZONE_W, FONT_SIZE.SMALL or 14)
        local earliestLbl = makeRowLbl("ft_row_earliest_"..rid.."_"..i, farmEarliestTime(farm), COL_EARLIEST_X, EARLIEST_W, FONT_SIZE.SMALL  or 14)
        table.insert(mainListTimeLbls, { lbl=earliestLbl, farmId=farm.id })

        local btnOpen = rowBg:CreateChildWidget("button", "ft_row_open_"..rid.."_"..i, 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(btnOpen, BUTTON_BASIC.DEFAULT) end
        btnOpen:SetExtent(BTN_W, 26); btnOpen:RemoveAllAnchors()
        btnOpen:AddAnchor("RIGHT", rowBg, -4, BTN_Y_OFF)
        btnOpen:SetText("Open")
        local capturedId = farm.id
        function btnOpen:OnClick() openDetailWindow(capturedId) end
        btnOpen:SetHandler("OnClick", btnOpen.OnClick); btnOpen:Show(true)

        local btnTrack = rowBg:CreateChildWidget("button", "ft_row_track_"..rid.."_"..i, 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(btnTrack, BUTTON_BASIC.DEFAULT) end
        btnTrack:SetExtent(BTN_W, 26); btnTrack:RemoveAllAnchors()
        btnTrack:AddAnchor("RIGHT", rowBg, -(BTN_W + GAP + 4), BTN_Y_OFF)
        btnTrack:SetText("Track")
        local capturedTrackFarm = farm
        function btnTrack:OnClick() showFarmInTracker(capturedTrackFarm) end
        btnTrack:SetHandler("OnClick", btnTrack.OnClick); btnTrack:Show(true)

        local btnMap = rowBg:CreateChildWidget("button", "ft_row_map_"..rid.."_"..i, 0, true)
        api.Interface:ApplyButtonSkin(btnMap, BUTTON_CONTENTS.MAP_OPEN)
        btnMap:SetExtent(30, 30)
        btnMap:RemoveAllAnchors()
        btnMap:AddAnchor("RIGHT", rowBg, -((BTN_W + GAP) * 2 + 4), BTN_Y_OFF)
        local capturedFarm = farm
        function btnMap:OnClick()
            pcall(function() api.Map:ToggleMapWithPortal(323, capturedFarm.worldX, capturedFarm.worldY, 100) end)
        end
        btnMap:SetHandler("OnClick", btnMap.OnClick); btnMap:Show(true)

        local btnDel = rowBg:CreateChildWidget("button", "ft_row_del_"..rid.."_"..i, 0, true)
        api.Interface:ApplyButtonSkin(btnDel, BUTTON_CONTENTS.SKILL_ABILITY_DELETE)
        btnDel:SetExtent(30, 30); btnDel:RemoveAllAnchors()
        btnDel:AddAnchor("RIGHT", rowBg, -((BTN_W + GAP) * 2 + 30 + GAP + 4), BTN_Y_OFF)
        local capturedIdDel = farm.id
        function btnDel:OnClick() deleteFarm(capturedIdDel); rebuildFarmList() end
        btnDel:SetHandler("OnClick", btnDel.OnClick); btnDel:Show(true)
    end
end

-- ============================================================
-- SAVED LAND PICKER
-- ============================================================

local function getTrackedLands()
    if type(trackedLands) == "table" and #trackedLands > 0 then
        return trackedLands
    end

    local addonSettings = api.GetSettings("tax_tracker") or {}
    if type(addonSettings.lands) == "table" then
        return addonSettings.lands
    end

    return {}
end

local function closeLandPickerWindow(clearPending)
    if clearPending then pendingDoodadInfo = nil end
    if landPickerWin then landPickerWin:Show(false) end
end

local function landPickerText(land)
    local name = land and land.name or "Unnamed Land"
    local zone = land and (land.zoneName or land.zone) or ""
    if zone and zone ~= "" then
        return string.format("%s - %s", name, tostring(zone))
    end
    return name
end

local function applyDoodadToLand(land)
    if not land then return end

    loadAllFarms()
    local farm = ensureFarmForLand(land)
    if not farm then return end

    local info = pendingDoodadInfo
    pendingDoodadInfo = nil
    if info then
        if tryAddDoodad(farm, info) then
            addAutotrackerItem(farm, info.name, isCooledTreeInfo(info))
        end
    end

    saveFarm(farm)
    if mainWin and mainWin:IsVisible() then
        rebuildFarmList()
    end
    closeLandPickerWindow(false)
    detailPage = 1
    openDetailWindow(farm.id)
end

local function applyDoodadToPlayerLocation()
    local pos = capturePlayerPosition()
    if not pos then
        log("Could not create farm at player location.")
        return
    end

    loadAllFarms()
    local farm = createFarm("Player Location - " .. zoneName(pos.zone), pos)
    local info = pendingDoodadInfo
    pendingDoodadInfo = nil
    if info then
        tryAddDoodad(farm, info)
    end
    saveFarm(farm)
    if mainWin and mainWin:IsVisible() then rebuildFarmList() end
    closeLandPickerWindow(false)
    detailPage = 1
    openDetailWindow(farm.id)
end

local function buildLandPickerRows()
    local lands = getTrackedLands()
    local zoneOrder, zoneGroups = {}, {}
    for _, land in ipairs(lands) do
        local z = tostring(land.zoneName or land.zone or "Unknown")
        if not zoneGroups[z] then
            zoneGroups[z] = {}
            table.insert(zoneOrder, z)
        end
        table.insert(zoneGroups[z], land)
    end
    table.sort(zoneOrder)

    local rows = {}
    for _, z in ipairs(zoneOrder) do
        table.insert(rows, { type="zone", zone=z, count=#zoneGroups[z] })
        if landPickerExpandedZones[z] then
            for _, land in ipairs(zoneGroups[z]) do
                table.insert(rows, { type="land", zone=z, land=land })
            end
        end
    end
    return rows
end

local function rebuildLandPicker()
    if not landPickerWin then return end

    for _, row in ipairs(landPickerRows) do
        if row and row.Show then row:Show(false) end
    end
    landPickerRows = {}
    landPickerRebuildId = landPickerRebuildId + 1
    local rid = landPickerRebuildId

    local rows = buildLandPickerRows()
    local totalPages = math.max(1, math.ceil(#rows / LAND_PICKER_ROWS_PER_PAGE))
    if landPickerPage > totalPages then landPickerPage = totalPages end
    if landPickerPage < 1 then landPickerPage = 1 end

    local hasPending = pendingDoodadInfo ~= nil
    if landPickerWin._hintLbl then
        landPickerWin._hintLbl:SetText(hasPending and "Attach scanned timer to:" or "Create or open farm for:")
    end

    if landPickerWin._pageLbl then
        landPickerWin._pageLbl:SetText(string.format("%d / %d", landPickerPage, totalPages))
    end

    if landPickerWin._prevBtn and landPickerWin._prevBtn.Enable then landPickerWin._prevBtn:Enable(landPickerPage > 1) end
    if landPickerWin._nextBtn and landPickerWin._nextBtn.Enable then landPickerWin._nextBtn:Enable(landPickerPage < totalPages) end

    if #rows == 0 then
        local emptyLbl = landPickerWin:CreateChildWidget("label", "tt_farm_land_empty_"..rid, 0, true)
        emptyLbl:SetText("No saved lands found.")
        emptyLbl:SetAutoResize(true)
        emptyLbl:AddAnchor("TOPLEFT", landPickerWin, 18, 74)
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(emptyLbl, FONT_COLOR.DEFAULT) end
        emptyLbl:Show(true)
        table.insert(landPickerRows, emptyLbl)
        return
    end

    local startIdx = (landPickerPage - 1) * LAND_PICKER_ROWS_PER_PAGE + 1
    local endIdx = math.min(startIdx + LAND_PICKER_ROWS_PER_PAGE - 1, #rows)
    for idx = startIdx, endIdx do
        local item = rows[idx]
        local rowIndex = idx - startIdx + 1
        local row = landPickerWin:CreateChildWidget("emptywidget", "tt_farm_land_row_"..rid.."_"..rowIndex, 0, true)
        row:SetExtent(420, 29)
        row:RemoveAllAnchors()
        row:AddAnchor("TOPLEFT", landPickerWin, 18, 68 + ((rowIndex - 1) * 31))
        row:Show(true)
        table.insert(landPickerRows, row)

        local bg = nil
        if item.type == "zone" then
            bg = row:CreateColorDrawable(0.08, 0.11, 0.16, 0.75, "background")
        else
            bg = row:CreateColorDrawable(0.02, 0.02, 0.02, 0.35, "background")
        end
        bg:AddAnchor("TOPLEFT", row, 0, 0)
        bg:AddAnchor("BOTTOMRIGHT", row, 0, 0)
        bg:Show(true)

        local label = row:CreateChildWidget("label", "tt_farm_land_label_"..rid.."_"..rowIndex, 0, true)
        label:SetExtent(item.type == "zone" and 320 or 300, 28)
        label:RemoveAllAnchors()
        label:AddAnchor("LEFT", row, item.type == "zone" and 10 or 28, 0)
        if label.style then
            label.style:SetAlign(ALIGN.LEFT)
            label.style:SetFontSize(item.type == "zone" and (FONT_SIZE.MIDDLE or 16) or (FONT_SIZE.SMALL or 14))
        end
        if ApplyTextColor and FONT_COLOR then
            ApplyTextColor(label, item.type == "zone" and (FONT_COLOR.YELLOW or FONT_COLOR.DEFAULT) or FONT_COLOR.DEFAULT)
        end
        label:Show(true)

        local btn = row:CreateChildWidget("button", "tt_farm_land_btn_"..rid.."_"..rowIndex, 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(btn, BUTTON_BASIC.DEFAULT) end
        btn:SetExtent(86, 24)
        btn:RemoveAllAnchors()
        btn:AddAnchor("RIGHT", row, -4, 0)
        if item.type == "zone" then
            label:SetText((landPickerExpandedZones[item.zone] and "- " or "+ ") .. item.zone .. " (" .. tostring(item.count) .. ")")
            btn:SetText(landPickerExpandedZones[item.zone] and "Collapse" or "Expand")
            local capturedZone = item.zone
            function btn:OnClick()
                landPickerExpandedZones[capturedZone] = not landPickerExpandedZones[capturedZone]
                landPickerPage = 1
                rebuildLandPicker()
            end
        else
            label:SetText(landPickerText(item.land))
            btn:SetText("Select")
            local capturedLand = item.land
            function btn:OnClick()
                local ok, err = pcall(function() applyDoodadToLand(capturedLand) end)
                if not ok then log("Land picker error: " .. tostring(err)) end
            end
        end
        btn:SetHandler("OnClick", btn.OnClick)
        btn:Show(true)
    end
end

openLandPickerWindow = function(info)
    pendingDoodadInfo = info

    if not landPickerWin then
        landPickerWin = api.Interface:CreateWindow("tax_tracker_farm_land_picker", "Choose Land", 460, 360)
        landPickerWin:RemoveAllAnchors()
        landPickerWin:AddAnchor("CENTER", "UIParent", 0, 0)
        landPickerWin:Show(false)

        function landPickerWin:OnHide()
            pendingDoodadInfo = nil
        end
        landPickerWin:SetHandler("OnHide", landPickerWin.OnHide)

        local hintLbl = landPickerWin:CreateChildWidget("label", "tt_farm_land_hint", 0, true)
        hintLbl:SetText("Attach scanned timer to:")
        hintLbl:SetAutoResize(true)
        hintLbl:AddAnchor("TOPLEFT", landPickerWin, 18, 42)
        if hintLbl.style then hintLbl.style:SetFontSize(FONT_SIZE.MIDDLE or 16) end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(hintLbl, FONT_COLOR.DEFAULT) end
        hintLbl:Show(true)
        landPickerWin._hintLbl = hintLbl

        local btnPrev = landPickerWin:CreateChildWidget("button", "tt_farm_land_prev", 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(btnPrev, BUTTON_BASIC.DEFAULT) end
        btnPrev:SetExtent(80, 28)
        btnPrev:AddAnchor("BOTTOMLEFT", landPickerWin, 18, -14)
        btnPrev:SetText("Prev")
        function btnPrev:OnClick()
            landPickerPage = landPickerPage - 1
            rebuildLandPicker()
        end
        btnPrev:SetHandler("OnClick", btnPrev.OnClick)
        btnPrev:Show(true)
        landPickerWin._prevBtn = btnPrev

        local pageLbl = landPickerWin:CreateChildWidget("label", "tt_farm_land_page", 0, true)
        pageLbl:SetExtent(80, 28)
        pageLbl:AddAnchor("BOTTOM", landPickerWin, 0, -14)
        pageLbl:SetText("1 / 1")
        if pageLbl.style then pageLbl.style:SetAlign(ALIGN.CENTER) end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(pageLbl, FONT_COLOR.DEFAULT) end
        pageLbl:Show(true)
        landPickerWin._pageLbl = pageLbl

        local btnNext = landPickerWin:CreateChildWidget("button", "tt_farm_land_next", 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(btnNext, BUTTON_BASIC.DEFAULT) end
        btnNext:SetExtent(80, 28)
        btnNext:AddAnchor("BOTTOMRIGHT", landPickerWin, -18, -14)
        btnNext:SetText("Next")
        function btnNext:OnClick()
            landPickerPage = landPickerPage + 1
            rebuildLandPicker()
        end
        btnNext:SetHandler("OnClick", btnNext.OnClick)
        btnNext:Show(true)
        landPickerWin._nextBtn = btnNext

        local btnCancel = landPickerWin:CreateChildWidget("button", "tt_farm_land_cancel", 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(btnCancel, BUTTON_BASIC.DEFAULT) end
        btnCancel:SetExtent(90, 26)
        btnCancel:AddAnchor("TOPRIGHT", landPickerWin, -18, 38)
        btnCancel:SetText("Cancel")
        function btnCancel:OnClick() closeLandPickerWindow(true) end
        btnCancel:SetHandler("OnClick", btnCancel.OnClick)
        btnCancel:Show(true)

        local btnPlayerLocation = landPickerWin:CreateChildWidget("button", "tt_farm_land_player_location", 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(btnPlayerLocation, BUTTON_BASIC.DEFAULT) end
        btnPlayerLocation:SetExtent(170, 26)
        btnPlayerLocation:AddAnchor("TOPRIGHT", landPickerWin, -116, 38)
        btnPlayerLocation:SetText("Use Player Location")
        function btnPlayerLocation:OnClick()
            local ok, err = pcall(applyDoodadToPlayerLocation)
            if not ok then log("Player location farm error: " .. tostring(err)) end
        end
        btnPlayerLocation:SetHandler("OnClick", btnPlayerLocation.OnClick)
        btnPlayerLocation:Show(true)
    end

    landPickerPage = 1
    rebuildLandPicker()
    landPickerWin:Show(true)
end

local function openAddFarmPopup()
    openLandPickerWindow(nil)
end

-- ============================================================
-- MAIN WINDOW SETUP
-- ============================================================

local function ensureMainWindow()
    if mainWin then return end

    mainWin = api.Interface:CreateWindow("tax_tracker_farm_main", "Farm Tracker", MAIN_W, MAIN_H)
    mainWin:RemoveAllAnchors()
    mainWin:AddAnchor("CENTER", "UIParent", 0, 0)
    addWindowTint(mainWin, 0.55)
    mainWin:Show(false)

    function mainWin:OnHide()
        closeLandPickerWindow(true)
    end
    mainWin:SetHandler("OnHide", mainWin.OnHide)

    local hdrBar = mainWin:CreateChildWidget("emptywidget", "ft_hdr_bar", 0, true)
    hdrBar:SetExtent(MAIN_W - 20, 28)
    hdrBar:RemoveAllAnchors()
    hdrBar:AddAnchor("TOPLEFT", mainWin, 4, 42)
    local hdrBg = hdrBar:CreateColorDrawable(0.08, 0.11, 0.16, 0.72, "background")
    hdrBg:AddAnchor("TOPLEFT", hdrBar, 0, 0)
    hdrBg:AddAnchor("BOTTOMRIGHT", hdrBar, 0, 0)
    hdrBg:Show(true)
    hdrBar:Show(true)

    local function makeHdrLabel(name, txt, xOff, w)
        local lbl = hdrBar:CreateChildWidget("textbox", name, 0, true)
        lbl:SetExtent(w, 28)
        lbl:RemoveAllAnchors()
        lbl:AddAnchor("LEFT", hdrBar, xOff, 0)
        lbl:SetText(txt)
        if lbl.style then lbl.style:SetAlign(ALIGN.LEFT); lbl.style:SetFontSize(FONT_SIZE.LARGE or 18) end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(lbl, FONT_COLOR.DEFAULT) end
        lbl:Show(true)
    end
    makeHdrLabel("ft_hdr_name", "Farm Name",   COL_NAME_X, NAME_W)
    makeHdrLabel("ft_hdr_zone", "Zone",        COL_ZONE_X, ZONE_W)
    makeHdrLabel("ft_hdr_earliest", "Earliest End", COL_EARLIEST_X, EARLIEST_W)

    -- Add Land button
    local btnAdd = mainWin:CreateChildWidget("button", "ft_btn_add_farm", 0, true)
    if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(btnAdd, BUTTON_BASIC.DEFAULT) end
    btnAdd:SetExtent(90, 28); btnAdd:RemoveAllAnchors()
    btnAdd:AddAnchor("BOTTOMRIGHT", mainWin, -10, -10)
    btnAdd:SetText("+ Add Land")
    function btnAdd:OnClick() openAddFarmPopup() end
    btnAdd:SetHandler("OnClick", btnAdd.OnClick); btnAdd:Show(true)

    -- Pagination
    local pageCtrl = W_CTRL.CreatePageControl("ft_pagectrl", mainWin, "tutorial")
    pageCtrl:RemoveAllAnchors()
    pageCtrl:AddAnchor("BOTTOM", mainWin, 0, -10)
    function pageCtrl:ProcOnPageChanged(pageIndex)
        currentPage = pageIndex
        rebuildFarmList()
    end
    pageCtrl:Show(true)
    mainWin._pageCtrl = pageCtrl

    local sep = mainWin:CreateColorDrawable(0.3, 0.3, 0.5, 0.5, "background")
    sep:SetExtent(MAIN_W - 20, 1); sep:RemoveAllAnchors()
    sep:AddAnchor("BOTTOMLEFT", mainWin, 10, -46); sep:Show(true)
end

local function openMainWindow()
    ensureMainWindow()
    currentPage    = 1
    loadAllFarms()
    rebuildFarmList()
    mainWin:Show(true)
end

toggleMainWindow = function()
    ensureMainWindow()
    if mainWin:IsVisible() then
        mainWin:Show(false)
    else
        openMainWindow()
    end
end

local function OnLoad()
    local ok, err
    ok, err = pcall(loadSettings)
    if not ok then log("Failed to load settings: " .. tostring(err)) end

    ok, err = pcall(loadAllFarms)
    if not ok then log("Failed to load farm data: " .. tostring(err)) end

    ok, err = pcall(function() setDoodadListenerEnabled(settings.autotrackerEnabled) end)
    if not ok then log("Failed to initialize doodad listener: " .. tostring(err)) end

    if settings.showFloatingBtn then
        api:DoIn(200, function() pcall(createFloatingBtn) end)
    end

    if api.On and not updateHandler then
        updateHandler = OnUpdate
        api.On("UPDATE", updateHandler)
    end
end

local function OnUnload()
    if updateHandler and api.Off then
        pcall(function() api.Off("UPDATE", updateHandler) end)
    end
    updateHandler = nil

    if floatingBtn   then floatingBtn:Show(false)      end
    if mainWin       then mainWin:Show(false)          end
    if detailWin     then detailWin:Show(false)        end
    if filterWin     then filterWin:Show(false)        end
    if settingsWin   then settingsWin:Show(false)      end
    if landPickerWin then landPickerWin:Show(false)    end
    if autotrackerWin then autotrackerWin:Show(false)  end
    if spotListWin then spotListWin:Show(false)        end
    if farmMinuteReminderWin then farmMinuteReminderWin:Show(false) end

    saveSettings()
    saveAllFarmsData()
end

function FarmSystem.initialize()
    local ok, err = pcall(OnLoad)
    if not ok then
        log("initialize error: " .. tostring(err))
        return false
    end
    return true
end

function FarmSystem.cleanup()
    OnUnload()
end

function FarmSystem.showFarmWindow()
    openMainWindow()
end

function FarmSystem.toggleFarmWindow()
    toggleMainWindow()
end

function FarmSystem.hideFarmWindow()
    if mainWin then mainWin:Show(false) end
end

function FarmSystem.updateLandDetectionData(data)
    trackedLands = data or {}
end

function FarmSystem.openSettingsWindow()
    openSettingsWindow()
end

function FarmSystem.isAutotrackerEnabled()
    return settings.autotrackerEnabled and true or false
end

function FarmSystem.setAutotrackerEnabled(enabled)
    setAutotrackerEnabled(enabled)
end

function FarmSystem.toggleAutotracker()
    setAutotrackerEnabled(not settings.autotrackerEnabled)
end

function FarmSystem.registerAutotrackerButton(btn)
    if not btn then return end
    for _, existing in ipairs(externalAutotrackerButtons) do
        if existing == btn then
            updateAutotrackerButton()
            return
        end
    end
    table.insert(externalAutotrackerButtons, btn)
    updateAutotrackerButton()
end

function FarmSystem.captureCooledTreeSpot()
    return captureCooledTreeSpot()
end

return FarmSystem

