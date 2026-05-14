local api = require("api")
local gui = require("tax_tracker/gui")

local FarmSystem = {}
local trackedLands = {}

-- ============================================================
-- CONSTANTS
-- ============================================================

local SETTINGS_KEY      = "farmTrackerSettings"
local ALL_FARMS_KEY     = "farmTrackerData"

local MAIN_W, MAIN_H     = 820, 500
local DETAIL_W, DETAIL_H = 800, 580

-- Detail window layout
local DETAIL_LIST_Y        = 170  -- top of doodad list content
local DETAIL_ROWS_PER_PAGE = 10
local DETAIL_NAME_X        = 37
local DETAIL_NAME_W        = 390
local DETAIL_QTY_X         = 442
local DETAIL_QTY_W         = 36
local DETAIL_EARLIEST_X    = 486
local DETAIL_TIME_W        = 110
local DETAIL_LATEST_X      = 600

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
local ROWS_PER_PAGE     = 9
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
-- ============================================================================
-- ACTIONS BAR — single semi-transparent panel hosting all floating buttons.
-- ============================================================================
-- Why this exists / Option A architecture:
--
-- Originally each floating button (AUTO ON/OFF, +Land, TRACKING ON/OFF, plus
-- the always-visible Arise button owned by HUDManager) was its own draggable
-- widget with its own persisted X/Y. That meant 4 widgets to drag and 4
-- positions to track. This module replaces them with a single vertical
-- panel that auto-sizes based on which toggles are enabled.
--
-- This is "Option A" — the bar lives here in FarmSystem and reaches into
-- HUDManager via two small public methods (HUDManager.invokeToggle and
-- HUDManager.hide) to suppress the standalone Arise widget and forward
-- clicks. It's pragmatic, not architecturally clean.
--
-- Migration path to "Option B" (clean shared module) — see notes below
-- the function definitions for the step-by-step plan.
--
-- Local-count discipline: everything hangs off the FarmSystem table — no
-- new module-level `local` declarations, because this chunk is right at
-- Lua's 200-local cap.
-- ============================================================================
FarmSystem.floatActions = {
    bar     = { widget = nil },            -- shared container window
    buttons = {},                          -- live child button widgets (for cleanup)
    -- Stable widget names so cullByName() can find orphans from prior addon
    -- loads. We don't bake a sequence counter into the names because module
    -- locals reset on /reload and we'd lose the ability to find the old
    -- widgets at all.
    names = {
        bar    = "ft_actions_bar",
        arise  = "ft_bar_btn_arise",
        auto   = "ft_bar_btn_auto",
        addLand = "ft_bar_btn_addland",
        track  = "ft_bar_btn_trackview",
        farms  = "ft_bar_btn_farms",
    },
    config  = {
        BTN_W = 104, BTN_H = 24, PAD = 6, GAP = 4,
        OUTER_W = 116,                            -- BTN_W + 2*PAD = 116 (matches old style)
        TONE_ON  = {0.12, 0.28, 0.15, 0.95},
        TONE_OFF = {0.11, 0.11, 0.13, 0.92},
    },
}
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

FARM_UI = {
    white = {1, 1, 1, 1},
    muted = {0.72, 0.72, 0.72, 1},
    gold = {1, 0.84, 0, 1},
    green = {0.12, 0.28, 0.15, 0.95},
    red = {0.24, 0.09, 0.09, 0.95},
    button = {0.11, 0.11, 0.13, 0.92},
    buttonBlue = {0.14, 0.17, 0.22, 0.95},
    panel = {0.05, 0.05, 0.06, 0.64},
    listPanel = {0.05, 0.05, 0.06, 0.36},
    header = {0.09, 0.09, 0.11, 0.95},
    groupDetails = {0.07, 0.07, 0.08, 0.74},
    groupTools = {0.055, 0.06, 0.07, 0.74},
    groupActions = {0.065, 0.065, 0.075, 0.74},
    rowOdd = {0.08, 0.08, 0.095, 0.72},
    rowEven = {0.12, 0.12, 0.135, 0.72}
}

function ftClearAnchors(widget)
    if widget and widget.RemoveAllAnchors then
        pcall(function() widget:RemoveAllAnchors() end)
    end
end

function ftSetTextColor(widget, color)
    if widget and widget.style and widget.style.SetColor and color then
        widget.style:SetColor(color[1], color[2], color[3], color[4] or 1)
    elseif ApplyTextColor and FONT_COLOR then
        ApplyTextColor(widget, FONT_COLOR.DEFAULT)
    end
end

function ftSetDrawableColor(drawable, color)
    if drawable and drawable.SetColor and color then
        drawable:SetColor(color[1], color[2], color[3], color[4] or 0.92)
    end
end

function ftAddPanel(parent, id, x, y, w, h, color)
    if not (parent and parent.CreateChildWidget) then return nil end
    local c = color or FARM_UI.panel
    local box = parent:CreateChildWidget("emptywidget", id, 0, true)
    box:SetExtent(w, h)
    box:AddAnchor("TOPLEFT", parent, x, y)
    if box.EnableMouse then box:EnableMouse(false) end
    local bg = box:CreateColorDrawable(c[1], c[2], c[3], c[4], "background")
    bg:AddAnchor("TOPLEFT", box, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", box, 0, 0)
    bg:Show(true)
    box:Show(true)
    return box
end

function ftAddDrawable(parent, color)
    if not (parent and parent.CreateColorDrawable) then return nil end
    local c = color or FARM_UI.panel
    local bg = parent:CreateColorDrawable(c[1], c[2], c[3], c[4], "background")
    bg:AddAnchor("TOPLEFT", parent, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", parent, 0, 0)
    bg:Show(true)
    return bg
end

function ftPlace(widget, anchorPoint, relativeTo, relativePoint, x, y, w, h)
    if not widget then return nil end
    ftClearAnchors(widget)
    if w and h then widget:SetExtent(w, h) end
    if relativePoint then
        widget:AddAnchor(anchorPoint, relativeTo, relativePoint, x, y)
    else
        widget:AddAnchor(anchorPoint, relativeTo, x, y)
    end
    return widget
end

function ftStyleLabel(label, color, size, align)
    if not label then return nil end
    if label.style then
        if label.style.SetFontSize then label.style:SetFontSize(size or 12) end
        if label.style.SetAlign then label.style:SetAlign(align or ALIGN.LEFT) end
    end
    ftSetTextColor(label, color or FARM_UI.white)
    return label
end

function ftStyleButton(button, text, tone, fontSize)
    if not button then return nil end
    local w, h = 80, 24
    pcall(function()
        if button.GetWidth and button:GetWidth() and button:GetWidth() > 0 then w = button:GetWidth() end
        if button.GetHeight and button:GetHeight() and button:GetHeight() > 0 then h = button:GetHeight() end
    end)
    if button.SetText then button:SetText("") end
    if not button.cleanBg and button.CreateColorDrawable then
        button.cleanBg = button:CreateColorDrawable(0.11, 0.11, 0.13, 0.92, "background")
        button.cleanBg:Show(true)
    end
    ftClearAnchors(button.cleanBg)
    if button.cleanBg then
        button.cleanBg:AddAnchor("TOPLEFT", button, 0, 0)
        button.cleanBg:AddAnchor("BOTTOMRIGHT", button, 0, 0)
    end
    if not button.cleanLabel then
        local label = button:CreateChildWidget("label", "cleanLabel", 0, true)
        if label.EnablePick then label:EnablePick(false) end
        label:Show(true)
        button.cleanLabel = label
    end
    ftClearAnchors(button.cleanLabel)
    button.cleanLabel:SetExtent(w, math.max(1, h - 2))
    button.cleanLabel:AddAnchor("TOPLEFT", button, 0, 1)
    ftStyleLabel(button.cleanLabel, FARM_UI.white, fontSize or 11, ALIGN.CENTER)

    function button:SetCleanText(nextText)
        if self.cleanLabel then self.cleanLabel:SetText(nextText or "") end
    end
    function button:SetText(nextText)
        self:SetCleanText(nextText)
    end
    function button:SetTone(nextTone)
        ftSetDrawableColor(self.cleanBg, nextTone or FARM_UI.button)
    end

    button:SetCleanText(text or "")
    button:SetTone(tone or FARM_UI.button)
    return button
end

function ftDestroyWidget(widget)
    if not widget then return end
    pcall(function()
        if widget.Show then widget:Show(false) end
        ftClearAnchors(widget)
        if widget.Destroy then widget:Destroy() end
    end)
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
    if type(settings.mineralWaterSpots) ~= "table" then settings.mineralWaterSpots = {} end
    if not settings.floatingBtnX    then settings.floatingBtnX = 200 end
    if not settings.floatingBtnY    then settings.floatingBtnY = 200 end
    if settings.showTrackButton == nil then settings.showTrackButton = false end
    if not settings.trackBtnX       then settings.trackBtnX = 200 end
    if not settings.trackBtnY       then settings.trackBtnY = 240 end
    if settings.showTrackingViewBtn == nil then settings.showTrackingViewBtn = false end
    if not settings.trackingViewBtnX then settings.trackingViewBtnX = 200 end
    if not settings.trackingViewBtnY then settings.trackingViewBtnY = 280 end
    if settings.showFarmListBtn == nil then settings.showFarmListBtn = false end
    -- Global favourite filter lists. Names in these tables bypass per-farm
    -- filter rejection and survive across farm creation/deletion.
    if type(settings.favouritePlayers) ~= "table" then settings.favouritePlayers = {} end
    if type(settings.favouriteEntities) ~= "table" then settings.favouriteEntities = {} end
    -- Single position for the actions bar. Defaults to the legacy hud
    -- position so existing users keep their familiar Arise location after
    -- upgrading to the bar.
    if not settings.actionsBarX then settings.actionsBarX = settings.hudX or 970 end
    if not settings.actionsBarY then settings.actionsBarY = settings.hudY or 10 end
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

-- Tracked fish hover targets. Both names per fish: schooling (non-fed) and
-- feeding frenzy (fed). Hardcoded set so unrelated mobs can't trigger fish
-- mode by accident.
--
-- Attached to the FarmSystem table rather than as module-level locals
-- because this chunk is at Lua's 200-local cap (see "Local-count
-- discipline" comment near floatActions). Same for the helpers below.
FarmSystem._FISH_NAMES = {
    "Bluefin Tuna",
    "Sturgeon",
    "Sailfish",
    "Blue Marlin",
}

FarmSystem._FISH_MATCH = {}
for _, fish in ipairs(FarmSystem._FISH_NAMES) do
    FarmSystem._FISH_MATCH["schooling " .. fish:lower()] = true
    FarmSystem._FISH_MATCH[fish:lower() .. " feeding frenzy"] = true
end

function FarmSystem._isFishInfo(info)
    if not info or not info.name then return false end
    return FarmSystem._FISH_MATCH[tostring(info.name):lower()] == true
end

-- Working Settler Gamekeeper NPC — quest unlocks after its timer, so
-- hover-tracking the timer is exactly the right tool. Single name match.
function FarmSystem._isGamekeeperInfo(info)
    if not info or not info.name then return false end
    return tostring(info.name):lower():find("working settler gamekeeper", 1, true) ~= nil
end

-- Global favourite-filter helpers. Stored on settings as
-- lowercase-key -> original-case-name string tables. Lookup is
-- case-insensitive; the original case is preserved so seeded entries
-- display nicely. Legacy entries with value === true are still treated
-- as favourites (key used as display name) for backward compatibility.
function FarmSystem._isFavouritePlayer(name)
    if not name or name == "" then return false end
    local s = api.GetSettings("tax_tracker") or {}
    local list = s.favouritePlayers
    if type(list) ~= "table" then return false end
    return list[tostring(name):lower()] ~= nil
end

function FarmSystem._isFavouriteEntity(name)
    if not name or name == "" then return false end
    local s = api.GetSettings("tax_tracker") or {}
    local list = s.favouriteEntities
    if type(list) ~= "table" then return false end
    return list[tostring(name):lower()] ~= nil
end

function FarmSystem._toggleFavouritePlayer(name)
    if not name or name == "" then return end
    local s = api.GetSettings("tax_tracker") or {}
    if type(s.favouritePlayers) ~= "table" then s.favouritePlayers = {} end
    local key = tostring(name):lower()
    -- Don't use `and ... or` ternary here: Lua short-circuits when the middle
    -- operand is nil, so `(x) and nil or v` always evaluates to v, leaving the
    -- favourite stuck on.
    if s.favouritePlayers[key] ~= nil then
        s.favouritePlayers[key] = nil
    else
        s.favouritePlayers[key] = name
    end
    pcall(function() api.SaveSettings() end)
end

function FarmSystem._toggleFavouriteEntity(name)
    if not name or name == "" then return end
    local s = api.GetSettings("tax_tracker") or {}
    if type(s.favouriteEntities) ~= "table" then s.favouriteEntities = {} end
    local key = tostring(name):lower()
    if s.favouriteEntities[key] ~= nil then
        s.favouriteEntities[key] = nil
    else
        s.favouriteEntities[key] = name
    end
    pcall(function() api.SaveSettings() end)
end

-- Ensure every global favourite has a corresponding (enabled) entry in the
-- given farm's scanPlayers/scanEntities. Called when the filter window
-- opens and when tryAddDoodad would auto-register, so favourites show up in
-- every farm's filter list immediately, not just after a name is scanned.
function FarmSystem._seedFavourites(farm)
    if type(farm) ~= "table" then return end
    if type(farm.scanPlayers) ~= "table" then farm.scanPlayers = {} end
    if type(farm.scanEntities) ~= "table" then farm.scanEntities = {} end
    local s = api.GetSettings("tax_tracker") or {}
    local function seedInto(list, favTable)
        if type(favTable) ~= "table" then return end
        for favKey, favVal in pairs(favTable) do
            if favVal ~= nil then
                local displayName = (type(favVal) == "string" and favVal ~= "") and favVal or favKey
                local found = false
                for _, e in ipairs(list) do
                    if type(e.name) == "string" and e.name:lower() == favKey then
                        found = true
                        break
                    end
                end
                if not found then
                    table.insert(list, { name = displayName, enabled = true })
                end
            end
        end
    end
    seedInto(farm.scanPlayers,  s.favouritePlayers)
    seedInto(farm.scanEntities, s.favouriteEntities)
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

-- Find or create a single fishing farm per zone. Unlike cooled tree spots
-- (which are pinned to manually-captured positions), fish move around so
-- we just bind one farm to each zone the user fishes in. The farm is
-- anchored at the player's first hover position in that zone.
function FarmSystem._ensureFarmForFishZone(pos)
    if not pos then return nil end
    local zName = zoneName(pos.zone)
    for _, f in ipairs(farms or {}) do
        if f.isFishSpot and f.fishZoneName == zName then
            return f
        end
    end
    local farm = createFarm("Fishing - " .. tostring(zName), {
        zone = zName,
        sextants = pos.sextants or "",
        worldX = pos.worldX or 0,
        worldY = pos.worldY or 0,
        worldZ = pos.worldZ or 0,
    })
    farm.isFishSpot = true
    farm.fishZoneName = zName
    saveFarm(farm)
    return farm
end

-- One Gamekeeper farm per zone, same pattern as fish.
function FarmSystem._ensureFarmForGamekeeperZone(pos)
    if not pos then return nil end
    local zName = zoneName(pos.zone)
    for _, f in ipairs(farms or {}) do
        if f.isGamekeeperSpot and f.gamekeeperZoneName == zName then
            return f
        end
    end
    local farm = createFarm("Gamekeeper - " .. tostring(zName), {
        zone = zName,
        sextants = pos.sextants or "",
        worldX = pos.worldX or 0,
        worldY = pos.worldY or 0,
        worldZ = pos.worldZ or 0,
    })
    farm.isGamekeeperSpot = true
    farm.gamekeeperZoneName = zName
    saveFarm(farm)
    return farm
end

-- Dried Up Mineral Water — same pattern as cooled tree trunks: positions
-- are user-captured, hovers are routed to the nearest captured spot in
-- the same zone. All helpers attached to FarmSystem to stay clear of the
-- module-level local cap.
function FarmSystem._isDriedMineralWaterInfo(info)
    if not info or not info.name then return false end
    return tostring(info.name):lower():find("dried up mineral water", 1, true) ~= nil
end

function FarmSystem._ensureMineralWaterSpots()
    if type(settings.mineralWaterSpots) ~= "table" then settings.mineralWaterSpots = {} end
    return settings.mineralWaterSpots
end

function FarmSystem._makeMineralWaterSpot(pos, customName)
    local spots = FarmSystem._ensureMineralWaterSpots()
    local zone = zoneName(pos.zone)
    local name = customName
    if not name or name == "" then
        name = string.format("Dried Mineral Water %s #%d", zone, #spots + 1)
    end
    local spot = {
        id = "mineral_water_" .. tostring(api.Time:GetUiMsec()):gsub("%.", ""),
        name = name,
        zone = pos.zone,
        zoneName = zone,
        coords = nil,
        sextants = pos.sextants or "",
        worldX = pos.worldX or 0,
        worldY = pos.worldY or 0,
        worldZ = pos.worldZ or 0,
        isMineralWaterSpot = true,
    }
    table.insert(spots, spot)
    saveSettings()
    return spot
end

function FarmSystem._findNearestMineralWaterSpot(pos)
    local best, bestD2
    for _, spot in ipairs(FarmSystem._ensureMineralWaterSpots()) do
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

function FarmSystem._ensureFarmForMineralWaterSpot(spot)
    local landId = spot.id
    local existing = getFarmByLandId(landId)
    if existing then
        existing.name = spot.name or existing.name
        existing.zone = spot.zoneName or existing.zone
        existing.isMineralWaterSpot = true
        return existing
    end

    local farm = createFarm(spot.name or "Dried Mineral Water", {
        zone = spot.zoneName or spot.zone,
        sextants = spot.sextants or "",
        worldX = spot.worldX or 0,
        worldY = spot.worldY or 0,
        worldZ = spot.worldZ or 0,
    })
    farm.landId = landId
    farm.landName = spot.name
    farm.isMineralWaterSpot = true
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
    if farmMinuteReminderWin and farmMinuteReminderWin._styleVersion ~= 2 then
        ftDestroyWidget(farmMinuteReminderWin)
        farmMinuteReminderWin = nil
    end

    if not farmMinuteReminderWin then
        farmMinuteReminderWin = gui.CreateStyledWindow("tax_tracker_farm_minute_reminder", "Farm Reminder", 420, 180)
        if farmMinuteReminderWin.RemoveAllAnchors then
            farmMinuteReminderWin:RemoveAllAnchors()
        end
        farmMinuteReminderWin:AddAnchor("CENTER", "UIParent", 0, -120)

        farmMinuteReminderWin._rootPanel = gui.CreateCategoryPanel(farmMinuteReminderWin,
            "farm_minute_root", 12, 42, 396, 112, "Farm Reminder")
        farmMinuteReminderWin._listPanel = ftAddPanel(farmMinuteReminderWin,
            "farm_minute_list", 24, 82, 372, 64, {0, 0, 0, 0.54})

        local text = farmMinuteReminderWin:CreateChildWidget("textbox", "farm_minute_text", 0, true)
        text:SetExtent(356, 74)
        text:AddAnchor("TOPLEFT", farmMinuteReminderWin, 32, 92)
        if text.style then
            text.style:SetFontSize(FONT_SIZE.MIDDLE or 12)
            text.style:SetAlign(ALIGN.TOP_LEFT)
        end
        ftSetTextColor(text, FARM_UI.white)
        text:Show(true)
        farmMinuteReminderWin._text = text

        local closeBtn = farmMinuteReminderWin:CreateChildWidget("button", "farm_minute_close", 0, true)
        ftPlace(closeBtn, "BOTTOM", farmMinuteReminderWin, nil, 0, -18, 86, 24)
        ftStyleButton(closeBtn, "OK", FARM_UI.button)
        function closeBtn:OnClick() farmMinuteReminderWin:Show(false) end
        closeBtn:SetHandler("OnClick", closeBtn.OnClick)
        closeBtn:Show(true)
        farmMinuteReminderWin._closeBtn = closeBtn
        farmMinuteReminderWin._styleVersion = 2
    end

    local lines = {}
    table.insert(lines, string.format("%d farm%s finishing soon", #items, #items == 1 and "" or "s"))
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

    local height = math.max(180, 112 + (math.min(#items, 5) * 20))
    farmMinuteReminderWin:SetExtent(420, height)
    if farmMinuteReminderWin._rootPanel then farmMinuteReminderWin._rootPanel:SetExtent(396, height - 54) end
    if farmMinuteReminderWin._listPanel then farmMinuteReminderWin._listPanel:SetExtent(372, math.max(64, height - 118)) end
    if farmMinuteReminderWin._text then farmMinuteReminderWin._text:SetExtent(356, math.max(74, height - 126)) end
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

    -- Ensure per-farm filter lists exist + global favourites are seeded so
    -- they appear in every farm's lists immediately, even before any scan.
    if not farm.scanPlayers  then farm.scanPlayers  = {} end
    if not farm.scanEntities then farm.scanEntities = {} end
    if FarmSystem._seedFavourites then FarmSystem._seedFavourites(farm) end

    local defaultEnabled = farm.scanDefaultEnabled
    if defaultEnabled == nil then defaultEnabled = true end

    local populateFilter = farm.populateFilter
    if populateFilter == nil then populateFilter = true end

    local filterListsChanged = false

    -- Auto-register owner in scanPlayers if new (only if filter is not locked)
    local playerEntry = nil
    for _, e in ipairs(farm.scanPlayers) do
        if e.name:lower() == owner:lower() then playerEntry = e; break end
    end
    if not playerEntry then
        -- Favourites bypass the populateFilter lock: they should always
        -- appear in every farm's filter list.
        if not populateFilter and not FarmSystem._isFavouritePlayer(owner) then return false end
        playerEntry = { name = owner, enabled = true }
        table.insert(farm.scanPlayers, playerEntry)
        filterListsChanged = true
    end

    -- Auto-register entity name in scanEntities if new (only if filter is not locked)
    local entityEntry = nil
    for _, e in ipairs(farm.scanEntities) do
        if e.name:lower() == name:lower() then entityEntry = e; break end
    end
    if not entityEntry then
        if not populateFilter and not FarmSystem._isFavouriteEntity(name) then return false end
        entityEntry = { name = name, enabled = true }
        table.insert(farm.scanEntities, entityEntry)
        filterListsChanged = true
    end

    -- Live-refresh the filter window if it's open on this farm and we
    -- just added new entries. Without this the user has to close & reopen
    -- the window to see freshly-scanned names.
    if filterListsChanged and filterWin and filterWin._currentFarm == farm
       and filterWin.IsVisible and filterWin:IsVisible()
       and FarmSystem._rebuildFilterLists then
        pcall(function() FarmSystem._rebuildFilterLists(farm) end)
    end

    -- Reject if either filter is enabled and the entry is disabled.
    -- Favourites always pass regardless of per-farm enabled state.
    local filterPlayers  = farm.filterPlayersEnabled;  if filterPlayers  == nil then filterPlayers  = true end
    local filterEntities = farm.filterEntitiesEnabled; if filterEntities == nil then filterEntities = true end
    if filterPlayers  and not playerEntry.enabled and not FarmSystem._isFavouritePlayer(owner) then return false end
    if filterEntities and not entityEntry.enabled and not FarmSystem._isFavouriteEntity(name) then return false end

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
    -- Live-refresh the farm list so newly auto-created farms (cooled
    -- trunks, fish, gamekeeper, mineral water) appear without having to
    -- close & reopen the Farm Tracker window.
    if mainWin and mainWin.IsVisible and mainWin:IsVisible() then
        pcall(rebuildFarmList)
    end
    return true
end

local AUTO_W = 760
local AUTO_H = 220
local AUTO_ROWS = 11
local AUTO_LOCATION_X = 30
local AUTO_LOCATION_W = 210
local AUTO_ENTITY_X = 246
local AUTO_ENTITY_W = 150
local AUTO_QTY_X = 402
local AUTO_QTY_W = 34
local AUTO_EARLIEST_X = 442
local AUTO_TIME_W = 110
local AUTO_LATEST_X = 558

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

-- Color for an autotracker group's farm/name labels. Special-case farms
-- (cooled trunks, fish, gamekeeper) get a distinguishing tint so they're
-- visually grouped at a glance. FONT_COLOR.YELLOW is engine-provided;
-- blue/green are direct RGBA via style:SetColor since the engine table
-- doesn't expose them by name in this build.
function FarmSystem._applyGroupLabelColor(widget, group)
    if not widget then return end
    if group.fish and widget.style and widget.style.SetColor then
        widget.style:SetColor(0.42, 0.72, 1.00, 1.00)
        return
    end
    if group.gamekeeper and widget.style and widget.style.SetColor then
        widget.style:SetColor(0.40, 0.92, 0.55, 1.00)
        return
    end
    if group.mineralWater and widget.style and widget.style.SetColor then
        -- Cyan-ish, distinct from fish blue and gamekeeper green.
        widget.style:SetColor(0.55, 0.90, 0.95, 1.00)
        return
    end
    if ApplyTextColor and FONT_COLOR then
        ApplyTextColor(widget, group.cooled and (FONT_COLOR.YELLOW or FONT_COLOR.DEFAULT) or FONT_COLOR.DEFAULT)
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
                    groups[key] = {
                        key=key, farm=farm, name=d.name, entries={},
                        cooled = farm.isCooledTreeSpot or isCooledTreeInfo(d),
                        fish = farm.isFishSpot or FarmSystem._isFishInfo(d),
                        gamekeeper = farm.isGamekeeperSpot or FarmSystem._isGamekeeperInfo(d),
                        mineralWater = farm.isMineralWaterSpot or FarmSystem._isDriedMineralWaterInfo(d),
                    }
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
            local group = {
                key=farm.id .. "\0_empty", farm=farm, name="-", entries={},
                cooled = farm.isCooledTreeSpot,
                fish = farm.isFishSpot,
                gamekeeper = farm.isGamekeeperSpot,
                mineralWater = farm.isMineralWaterSpot,
            }
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

local function clearAutotrackerWindow()
    autotrackerFarmIds = {}
    autotrackerFarmOrder = {}
    autotrackerExpandedGroups = {}
    autotrackerPage = 1
    for _, row in ipairs(autotrackerRows or {}) do
        if row and row.Show then row:Show(false) end
    end
    autotrackerRows = {}
    autotrackerTimeLbls = {}
    if autotrackerWin then
        rebuildAutotrackerWindow()
        autotrackerWin:Show(true)
    end
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

    local statusText = settings.autotrackerEnabled and "Tracking Window" or "Tracking Window (Paused)"
    if autotrackerWin._titleLbl then autotrackerWin._titleLbl:SetText(statusText) end

    local renderRows = buildAutotrackerRenderList()
    local totalPages = math.max(1, math.ceil(#renderRows / AUTO_ROWS))
    if autotrackerPage > totalPages then autotrackerPage = totalPages end
    if autotrackerPage < 1 then autotrackerPage = 1 end
    if autotrackerWin._pageLbl then autotrackerWin._pageLbl:SetText(string.format("%d / %d", autotrackerPage, totalPages)) end
    if autotrackerWin._prevBtn and autotrackerWin._prevBtn.Enable then autotrackerWin._prevBtn:Enable(autotrackerPage > 1) end
    if autotrackerWin._nextBtn and autotrackerWin._nextBtn.Enable then autotrackerWin._nextBtn:Enable(autotrackerPage < totalPages) end

    if #renderRows == 0 then
        autotrackerWin:SetExtent(AUTO_W, 125)
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
    autotrackerWin:SetExtent(AUTO_W, 110 + (visibleRows * 24))
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
            FarmSystem._applyGroupLabelColor(farmLbl, group)
            farmLbl:Show(true)

            local nameLbl = row:CreateChildWidget("label", "tt_auto_name_" .. rowIndex, 0, true)
            nameLbl:SetText(fitText(group.name or "", 22))
            nameLbl:SetExtent(AUTO_ENTITY_W, 22)
            nameLbl:AddAnchor("LEFT", row, AUTO_ENTITY_X, 0)
            if nameLbl.style then nameLbl.style:SetFontSize(FONT_SIZE.SMALL or 14); nameLbl.style:SetAlign(ALIGN.LEFT) end
            FarmSystem._applyGroupLabelColor(nameLbl, group)
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
            ftPlace(delBtn, "RIGHT", row, nil, -4, 0, 38, 20)
            ftStyleButton(delBtn, "Del", FARM_UI.red, 10)
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
            ftPlace(delBtn, "RIGHT", row, nil, -4, 0, 38, 20)
            ftStyleButton(delBtn, "Del", FARM_UI.red, 10)
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
    -- Once dragged, position is persisted in settings as a TOPLEFT offset.
    -- First-run / never-dragged users still get the original CENTER default.
    if settings.autotrackerWinX and settings.autotrackerWinY then
        autotrackerWin:AddAnchor("TOPLEFT", "UIParent", settings.autotrackerWinX, settings.autotrackerWinY)
    else
        autotrackerWin:AddAnchor("CENTER", "UIParent", 380, -110)
    end
    if autotrackerWin.EnableDrag then autotrackerWin:EnableDrag(true) end
    function autotrackerWin:OnDragStart()
        if self.StartMoving then self:StartMoving() end
        if api.Cursor and api.Cursor.ClearCursor then api.Cursor:ClearCursor() end
    end
    autotrackerWin:SetHandler("OnDragStart", autotrackerWin.OnDragStart)
    function autotrackerWin:OnDragStop()
        if self.StopMovingOrSizing then self:StopMovingOrSizing() end
        if self.GetEffectiveOffset then
            local x, y = self:GetEffectiveOffset()
            if x and y then
                settings.autotrackerWinX = x
                settings.autotrackerWinY = y
                saveSettings()
            end
        end
        if api.Cursor and api.Cursor.ClearCursor then api.Cursor:ClearCursor() end
    end
    autotrackerWin:SetHandler("OnDragStop", autotrackerWin.OnDragStop)

    -- Keep the bar's TRACKING ON/OFF label + tone in sync with this window's
    -- visibility. Fires for any close path (X button, Show(false) elsewhere)
    -- without having to wire each call site.
    --
    -- Two safety gates here:
    --
    -- 1. Stale-session bail. The handler captures the OLD `FarmSystem`
    --    table via upvalue, so after /reload the engine can still fire
    --    OnShow/OnHide on the orphan tracking window and re-trigger OLD
    --    floatActions.rebuild. Compare the captured bar.mySession against
    --    the live disk value and bail when they diverge.
    --
    -- 2. Don't re-create during shutdown. /reload's OnUnload calls
    --    floatActions.destroy() (which sets fa.bar.widget = nil), THEN
    --    calls autotrackerWin:Show(false) — which fires OnHide HERE,
    --    which calls fa.rebuild(), which sees nil widget and calls
    --    fa.create() — birthing a phantom orphan bar mid-shutdown that
    --    nothing will clean up. That phantom is the duplicate the user
    --    sees post-reload (in addition to the real new bar). We bail if
    --    the bar widget is already gone.
    local function shouldSkipBarRebuild()
        local fa = FarmSystem and FarmSystem.floatActions
        if not (fa and fa.bar) then return true end
        local cur = api.GetSettings("tax_tracker") or {}
        if fa.bar.mySession and (cur.barSession or 0) ~= fa.bar.mySession then
            return true  -- stale handler from a prior load
        end
        if not fa.bar.widget then
            return true  -- bar destroyed; don't resurrect it
        end
        return false
    end
    function autotrackerWin:OnShow()
        if shouldSkipBarRebuild() then return end
        FarmSystem.floatActions.rebuild()
    end
    autotrackerWin:SetHandler("OnShow", autotrackerWin.OnShow)
    function autotrackerWin:OnHide()
        if shouldSkipBarRebuild() then return end
        FarmSystem.floatActions.rebuild()
    end
    autotrackerWin:SetHandler("OnHide", autotrackerWin.OnHide)

    local bg = autotrackerWin:CreateColorDrawable(0, 0, 0, 0.62, "background")
    bg:AddAnchor("TOPLEFT", autotrackerWin, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", autotrackerWin, 0, 0)
    bg:Show(true)

    local titleLbl = autotrackerWin:CreateChildWidget("label", "tt_auto_title", 0, true)
    titleLbl:SetText("Tracking Window")
    titleLbl:SetExtent(300, 24)
    titleLbl:AddAnchor("TOPLEFT", autotrackerWin, 12, 10)
    if titleLbl.style then titleLbl.style:SetFontSize(FONT_SIZE.LARGE or 18); titleLbl.style:SetAlign(ALIGN.LEFT) end
    if ApplyTextColor and FONT_COLOR then ApplyTextColor(titleLbl, FONT_COLOR.DEFAULT) end
    titleLbl:Show(true)
    autotrackerWin._titleLbl = titleLbl

    local clearBtn = autotrackerWin:CreateChildWidget("button", "tt_auto_clear", 0, true)
    ftPlace(clearBtn, "TOPRIGHT", autotrackerWin, nil, -72, 8, 56, 24)
    ftStyleButton(clearBtn, "Clear", FARM_UI.button)
    function clearBtn:OnClick()
        clearAutotrackerWindow()
    end
    clearBtn:SetHandler("OnClick", clearBtn.OnClick)
    clearBtn:Show(true)
    autotrackerWin._clearBtn = clearBtn

    local closeBtn = autotrackerWin:CreateChildWidget("button", "tt_auto_hide", 0, true)
    ftPlace(closeBtn, "TOPRIGHT", autotrackerWin, nil, -10, 8, 54, 24)
    ftStyleButton(closeBtn, "Hide", FARM_UI.button)
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
    -- Auto-register the farm in the tracker only for the special cases
    -- (cooled trunks, fish, gamekeeper) — they shouldn't require the user
    -- to manually pin them. Regular farms get pinned via the detail-window
    -- "Show in Tracker" path.
    if isCooled and farm and farm.id and not autotrackerFarmIds[farm.id] then
        autotrackerFarmIds[farm.id] = true
        table.insert(autotrackerFarmOrder, farm.id)
    end
    if isCooled and settings.autotrackerEnabled then showAutotrackerWindow() end
    -- Always rebuild if the tracking window is showing — this fixes the
    -- case where a regular (already-pinned) farm's qty didn't update
    -- until the user expanded/collapsed a group.
    if autotrackerWin and autotrackerWin.IsVisible and autotrackerWin:IsVisible() then
        pcall(rebuildAutotrackerWindow)
    end
end

local function updateAutotrackerButton()
    if autotrackerBtn then autotrackerBtn:SetText(settings.autotrackerEnabled and "Autotracker ON" or "Autotracker OFF") end
    -- Bar's Autotracker row label + tone are owned by FarmSystem.floatActions.rebuild()
    if FarmSystem.floatActions and FarmSystem.floatActions.rebuild then
        FarmSystem.floatActions.rebuild()
    end
    local text = settings.autotrackerEnabled and "Autotracker ON" or "Autotracker OFF"
    for i = #externalAutotrackerButtons, 1, -1 do
        local btn = externalAutotrackerButtons[i]
        local ok = btn and btn.SetText and pcall(function()
            btn:SetText(text)
            if btn.SetTone then
                btn:SetTone(settings.autotrackerEnabled and {0.12, 0.28, 0.15, 0.95} or {0.11, 0.11, 0.13, 0.92})
            end
        end)
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

    ftDestroyWidget(detailWin._listContent)

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
    listContent:SetExtent(DETAIL_W - 36, rowCount * 28)
    listContent:RemoveAllAnchors()
    listContent:AddAnchor("TOPLEFT", detailWin, 18, DETAIL_LIST_Y)
    listContent:Show(true)
    detailWin._listContent = listContent

    if #flat == 0 then
        local emptyLbl1 = listContent:CreateChildWidget("label", "ft_dl_empty1_"..rid, 0, true)
        emptyLbl1:SetText("No entities scanned yet.")
        emptyLbl1:AddAnchor("TOPLEFT", listContent, 4, 8)
        emptyLbl1:SetExtent(300, 22)
        emptyLbl1:SetAutoResize(false)
        ftStyleLabel(emptyLbl1, FARM_UI.white, 12, ALIGN.LEFT)
        emptyLbl1:Show(true)
        local emptyLbl2 = listContent:CreateChildWidget("label", "ft_dl_empty2_"..rid, 0, true)
        emptyLbl2:SetText("Entities will be scanned on mouseover when holding the modifier key selected in the settings page for this addon.")
        emptyLbl2:AddAnchor("TOPLEFT", listContent, 4, 28)
        emptyLbl2:SetExtent(680, 22)
        emptyLbl2:SetAutoResize(false)
        ftStyleLabel(emptyLbl2, FARM_UI.muted, 12, ALIGN.LEFT)
        emptyLbl2:Show(true)
        return
    end

    for i = startIdx, endIdx do
        local item = flat[i]
        local yOff = (i - startIdx) * 28

        if item.type == "header" then
            local hdr = listContent:CreateChildWidget("emptywidget", "ft_dl_hdr_"..rid.."_"..i, 0, true)
            hdr:SetExtent(DETAIL_W - 36, 27)
            hdr:RemoveAllAnchors()
            hdr:AddAnchor("TOPLEFT", listContent, 0, yOff)
            local hdrShade = hdr:CreateColorDrawable(FARM_UI.header[1], FARM_UI.header[2], FARM_UI.header[3], FARM_UI.header[4], "background")
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
            ftStyleLabel(nameLbl, FARM_UI.white, 12, ALIGN.LEFT)
            nameLbl:Show(true)

            local qtyLbl = hdr:CreateChildWidget("label", "ft_dl_hq_"..rid.."_"..i, 0, true)
            qtyLbl:SetExtent(DETAIL_QTY_W, 27)
            qtyLbl:AddAnchor("LEFT", hdr, DETAIL_QTY_X, 0)
            qtyLbl:SetText("x" .. item.qty)
            qtyLbl:SetAutoResize(false)
            ftStyleLabel(qtyLbl, FARM_UI.white, 12, ALIGN.CENTER)
            qtyLbl:Show(true)

            local eLbl = hdr:CreateChildWidget("label", "ft_dl_he_"..rid.."_"..i, 0, true)
            eLbl:SetExtent(DETAIL_TIME_W, 27)
            eLbl:AddAnchor("LEFT", hdr, DETAIL_EARLIEST_X, 0)
            eLbl:SetText(formatTime(item.earliest))
            eLbl:SetAutoResize(false)
            ftStyleLabel(eLbl, FARM_UI.white, 12, ALIGN.LEFT)
            eLbl:Show(true)
            table.insert(detailTimeLbls, { kind="earliest", lbl=eLbl, groupName=item.name, groupOwner=item.owner })

            local lLbl = hdr:CreateChildWidget("label", "ft_dl_hl_"..rid.."_"..i, 0, true)
            lLbl:SetExtent(DETAIL_TIME_W, 27)
            lLbl:AddAnchor("LEFT", hdr, DETAIL_LATEST_X, 0)
            lLbl:SetText(formatTime(item.latest))
            lLbl:SetAutoResize(false)
            ftStyleLabel(lLbl, FARM_UI.white, 12, ALIGN.LEFT)
            lLbl:Show(true)
            table.insert(detailTimeLbls, { kind="latest", lbl=lLbl, groupName=item.name, groupOwner=item.owner })

            -- Delete button for this group
            local delBtn = hdr:CreateChildWidget("button", "ft_dl_hdel_"..rid.."_"..i, 0, true)
            ftPlace(delBtn, "RIGHT", hdr, nil, -6, 0, 38, 22)
            ftStyleButton(delBtn, "Del", FARM_UI.red)
            local capturedName  = item.name
            local capturedOwner = item.owner
            delBtn._groupKey = item.key
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
                if #remaining == 0 then
                    local farmId = f.id
                    expandedGroups[self._groupKey] = nil
                    deleteFarm(farmId)
                    if detailWin and detailWin:IsVisible() and detailFarmId == farmId then closeDetailWindow() end
                    if mainWin and mainWin:IsVisible() then rebuildFarmList() end
                    if autotrackerWin then rebuildAutotrackerWindow() end
                    return
                end
                f.doodads = remaining
                expandedGroups[self._groupKey] = nil
                saveFarm(f)
                detailPage = 1
                rebuildDoodadList()
                if mainWin and mainWin:IsVisible() then rebuildFarmList() end
                if autotrackerWin then rebuildAutotrackerWindow() end
            end
            delBtn:SetHandler("OnClick", delBtn.OnClick)
            delBtn:Show(true)

        elseif item.type == "entry" then
            local row = listContent:CreateChildWidget("emptywidget", "ft_dl_ent_"..rid.."_"..i, 0, true)
            row:SetExtent(DETAIL_W - 36, 27)
            row:RemoveAllAnchors()
            row:AddAnchor("TOPLEFT", listContent, 0, yOff)
            local relIndex = i - startIdx + 1
            local tone = relIndex % 2 == 0 and FARM_UI.rowEven or FARM_UI.rowOdd
            local rowShade = row:CreateColorDrawable(tone[1], tone[2], tone[3], tone[4], "background")
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
            ftStyleLabel(ownerLbl, FARM_UI.muted, 12, ALIGN.LEFT)
            ownerLbl:Show(true)

            -- Time label in Earliest column
            local tLbl = row:CreateChildWidget("label", "ft_dl_et_"..rid.."_"..i, 0, true)
            tLbl:SetExtent(170, 27)
            tLbl:AddAnchor("LEFT", row, DETAIL_EARLIEST_X, 0)
            tLbl:SetText(formatTime(item.t))
            tLbl:SetAutoResize(false)
            ftStyleLabel(tLbl, FARM_UI.white, 12, ALIGN.LEFT)
            tLbl:Show(true)
            table.insert(detailTimeLbls, { kind="entry", lbl=tLbl, entry=item.entry })

            row._delBtn = row:CreateChildWidget("button", "ft_dl_edel_"..rid.."_"..i, 0, true)
            ftPlace(row._delBtn, "RIGHT", row, nil, -6, 0, 38, 22)
            ftStyleButton(row._delBtn, "Del", FARM_UI.red)
            row._delBtn._farmId = detailFarmId
            row._delBtn._entryRef = item.entry
            function row._delBtn:OnClick()
                local f = self._farmId and getFarmById(self._farmId)
                if f then deleteTrackedEntry(f, self._entryRef) end
            end
            row._delBtn:SetHandler("OnClick", row._delBtn.OnClick)
            row._delBtn:Show(true)
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
        detailWin = gui.CreateStyledWindow("tax_tracker_farm_detail", "Farm Detail", DETAIL_W, DETAIL_H)
        detailWin:RemoveAllAnchors()
        detailWin:AddAnchor("CENTER", "UIParent", 0, 0)
        gui.CreateCategoryPanel(detailWin, "ft_detail_land_panel", 12, 42, DETAIL_W - 24, 58, "Land")
        gui.CreateCategoryPanel(detailWin, "ft_detail_entities_panel", 12, 110, DETAIL_W - 24, 346, "Tracked Entities")
        ftAddPanel(detailWin, "ft_detail_info_panel", 18, 72, DETAIL_W - 36, 22, FARM_UI.groupDetails)
        ftAddPanel(detailWin, "ft_detail_header_panel", 18, 140, DETAIL_W - 36, 26, FARM_UI.header)
        ftAddPanel(detailWin, "ft_detail_list_panel", 18, 170, DETAIL_W - 36, 280, FARM_UI.listPanel)
        ftAddPanel(detailWin, "ft_detail_action_panel", 18, DETAIL_H - 78, DETAIL_W - 36, 54, FARM_UI.groupActions)
        detailWin:Show(false)

        function detailWin:OnHide() lastDoodadInfo = nil end
        detailWin:SetHandler("OnHide", detailWin.OnHide)

        -- Farm info: zone on left, coords on right
        detailWin._zoneLbl = detailWin:CreateChildWidget("label", "ft_detail_zone", 0, true)
        detailWin._zoneLbl:SetExtent(200, 22)
        detailWin._zoneLbl:SetAutoResize(false)
        detailWin._zoneLbl:AddAnchor("TOPLEFT", detailWin, 28, 72)
        ftStyleLabel(detailWin._zoneLbl, FARM_UI.gold, 12, ALIGN.LEFT)
        detailWin._zoneLbl:Show(true)

        detailWin._sextLbl = detailWin:CreateChildWidget("label", "ft_detail_sext", 0, true)
        detailWin._sextLbl:SetExtent(220, 22)
        detailWin._sextLbl:SetAutoResize(false)
        detailWin._sextLbl:AddAnchor("TOPRIGHT", detailWin, -28, 72)
        ftStyleLabel(detailWin._sextLbl, FARM_UI.muted, 12, ALIGN.RIGHT)
        detailWin._sextLbl:Show(true)

        -- Doodad list column headers
        local function makeDHdr(name, txt, x, w)
            local lbl = detailWin:CreateChildWidget("label", name, 0, true)
            lbl:SetExtent(w, 22)
            lbl:RemoveAllAnchors()
            lbl:AddAnchor("TOPLEFT", detailWin, x + 8, 144)
            lbl:SetText(txt)
            lbl:SetAutoResize(false)
            ftStyleLabel(lbl, FARM_UI.gold, 12, ALIGN.LEFT)
            lbl:Show(true)
        end
        makeDHdr("ft_dh_expand",   "",            13,                24)
        makeDHdr("ft_dh_name",     "Entity Name", DETAIL_NAME_X,     DETAIL_NAME_W)
        makeDHdr("ft_dh_qty",      "Qty",         DETAIL_QTY_X,      DETAIL_QTY_W)
        makeDHdr("ft_dh_earliest", "Earliest",    DETAIL_EARLIEST_X, DETAIL_TIME_W)
        makeDHdr("ft_dh_latest",   "Latest",      DETAIL_LATEST_X,   DETAIL_TIME_W)
        makeDHdr("ft_dh_delete",   "Del",         DETAIL_W - 74,     40)

        -- Doodad list page controls (centered at bottom)
        local dPageCtrl = W_CTRL.CreatePageControl("ft_d_pagectrl", detailWin, "tutorial")
        dPageCtrl:RemoveAllAnchors()
        dPageCtrl:AddAnchor("BOTTOM", detailWin, 0, -30)
        function dPageCtrl:ProcOnPageChanged(pageIndex)
            detailPage = pageIndex
            rebuildDoodadList()
        end
        dPageCtrl:Show(true)
        detailWin._dPageCtrl = dPageCtrl

        -- "Populate Filter List" checkbox (above Back button)
        local cbPopulate = detailWin:CreateChildWidget("checkbutton", "ft_detail_cb_populate", 0, true)
        cbPopulate:SetExtent(18, 17)
        cbPopulate:RemoveAllAnchors()
        cbPopulate:AddAnchor("BOTTOMLEFT", detailWin, 28, -60)
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
        ftStyleLabel(cbPopulateLbl, FARM_UI.white, 12, ALIGN.LEFT)
        cbPopulateLbl:Show(true)

        -- "Scan only when holding [modifier]" checkbox
        local cbModOnly = detailWin:CreateChildWidget("checkbutton", "ft_detail_cb_modonly", 0, true)
        cbModOnly:SetExtent(18, 17)
        cbModOnly:RemoveAllAnchors()
        cbModOnly:AddAnchor("BOTTOMLEFT", detailWin, 210, -60)
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
        ftStyleLabel(cbModOnlyLbl, FARM_UI.white, 12, ALIGN.LEFT)
        cbModOnlyLbl:Show(true)
        detailWin._cbModOnlyLbl = cbModOnlyLbl

        -- Back button (bottom-left)
        local btnBack = detailWin:CreateChildWidget("button", "ft_detail_back", 0, true)
        ftPlace(btnBack, "BOTTOMLEFT", detailWin, nil, 28, -29, 74, 26)
        ftStyleButton(btnBack, "< Back", FARM_UI.button)
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
        ftPlace(btnFiltersBottom, "BOTTOMLEFT", detailWin, nil, 110, -29, 82, 26)
        ftStyleButton(btnFiltersBottom, "Filters", FARM_UI.buttonBlue)
        function btnFiltersBottom:OnClick()
            local f = detailFarmId and getFarmById(detailFarmId)
            if f then openFilterWindow(f) end
        end
        btnFiltersBottom:SetHandler("OnClick", btnFiltersBottom.OnClick)
        btnFiltersBottom:Show(true)

        -- Clear button (bottom-right)
        local btnReset = detailWin:CreateChildWidget("button", "ft_detail_reset", 0, true)
        ftPlace(btnReset, "BOTTOMRIGHT", detailWin, nil, -28, -29, 104, 26)
        ftStyleButton(btnReset, "Clear All", FARM_UI.red)
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
            if mainWin and mainWin:IsVisible() then rebuildFarmList() end
            if autotrackerWin then rebuildAutotrackerWindow() end
        end
        btnReset:SetHandler("OnClick", btnReset.OnClick)
        btnReset:Show(true)
        detailWin._btnReset = btnReset
    end

    -- Populate static labels
    detailWin._zoneLbl:SetText(zoneName(farm.zone))
    detailWin._sextLbl:SetText(farm.sextants or "")
    if detailWin.styledTitle then detailWin.styledTitle:SetText(farm.name or "Farm Detail")
    elseif detailWin.SetTitle then detailWin:SetTitle(farm.name or "Farm Detail") end
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
    -- Live-refresh tracking-window title so the "(Paused)" suffix flips
    -- the moment the toggle changes, not on the next user interaction.
    if autotrackerWin and autotrackerWin._titleLbl then
        local statusText = settings.autotrackerEnabled and "Tracking Window" or "Tracking Window (Paused)"
        pcall(function() autotrackerWin._titleLbl:SetText(statusText) end)
    end
    -- Note: AUTO toggle controls only the doodad scanner now. The tracker
    -- window's visibility is owned by the bar's TRACKING toggle (or the
    -- window's own X button). Don't force-hide here — that was old coupling
    -- from before the TRACKING toggle existed and made AUTO off → TRACKING
    -- off as a side effect.
end

local function refreshSettingsLabels()
    if settingsCooledSpotLbl then
        settingsCooledSpotLbl:SetText("Captured cooled tree spots: " .. tostring(#ensureCooledTreeSpots()))
    end
    if FarmSystem._settingsMineralLbl then
        FarmSystem._settingsMineralLbl:SetText("Captured mineral water spots: " .. tostring(#FarmSystem._ensureMineralWaterSpots()))
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
    if spotListWin and spotListWin:IsVisible() and spotListWin._spotType == "cooled" then
        rebuildSpotListWindow()
    end
    log("Captured cooled tree spot: " .. tostring(spot.name))
    return spot
end

rebuildSpotListWindow = function()
    if not spotListWin then return end
    for _, row in ipairs(spotListRows) do
        if row and row.Show then row:Show(false) end
    end
    spotListRows = {}

    -- Window is reused for both cooled-tree and mineral-water spot lists.
    -- The opener stamps `_spotType` on the window before calling this.
    local spotType = spotListWin._spotType or "cooled"
    local spots, defaultName, emptyText, settingsKey
    if spotType == "mineral" then
        spots = FarmSystem._ensureMineralWaterSpots()
        defaultName = "Dried Mineral Water"
        emptyText = "No mineral water spots captured."
        settingsKey = "mineralWaterSpots"
    else
        spots = ensureCooledTreeSpots()
        defaultName = "Cooled Tree Trunk"
        emptyText = "No cooled tree spots captured."
        settingsKey = "cooledTreeSpots"
    end
    if #spots == 0 then
        local empty = spotListWin:CreateChildWidget("label", "tt_spot_empty_" .. tostring(api.Time:GetUiMsec()), 0, true)
        empty:SetText(emptyText)
        empty:SetExtent(480, 22)
        empty:AddAnchor("TOPLEFT", spotListWin, 28, 114)
        ftStyleLabel(empty, FARM_UI.muted, 12, ALIGN.LEFT)
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
        local y = 106 + ((rowIndex - 1) * 28)
        local row = spotListWin:CreateChildWidget("emptywidget", "tt_spot_row_" .. tostring(api.Time:GetUiMsec()) .. "_" .. i, 0, true)
        row:SetExtent(504, 26)
        row:AddAnchor("TOPLEFT", spotListWin, 18, y)
        local tone = rowIndex % 2 == 0 and FARM_UI.rowEven or FARM_UI.rowOdd
        local shade = row:CreateColorDrawable(tone[1], tone[2], tone[3], tone[4], "background")
        shade:AddAnchor("TOPLEFT", row, 0, 0)
        shade:AddAnchor("BOTTOMRIGHT", row, 0, 0)
        shade:Show(true)
        row:Show(true)
        table.insert(spotListRows, row)

        local nameLbl = row:CreateChildWidget("label", "tt_spot_name_" .. i, 0, true)
        nameLbl:SetText(spot.name or defaultName)
        nameLbl:SetExtent(190, 24)
        nameLbl:AddAnchor("LEFT", row, 8, 0)
        nameLbl:SetAutoResize(false)
        ftStyleLabel(nameLbl, FARM_UI.white, 12, ALIGN.LEFT)
        nameLbl:Show(true)

        local zoneLbl = row:CreateChildWidget("label", "tt_spot_zone_" .. i, 0, true)
        zoneLbl:SetText(spot.zoneName or zoneName(spot.zone))
        zoneLbl:SetExtent(110, 24)
        zoneLbl:AddAnchor("LEFT", row, 204, 0)
        zoneLbl:SetAutoResize(false)
        ftStyleLabel(zoneLbl, FARM_UI.muted, 12, ALIGN.LEFT)
        zoneLbl:Show(true)

        local coordLbl = row:CreateChildWidget("label", "tt_spot_coord_" .. i, 0, true)
        coordLbl:SetText(spot.sextants or "")
        coordLbl:SetExtent(140, 24)
        coordLbl:AddAnchor("LEFT", row, 318, 0)
        coordLbl:SetAutoResize(false)
        ftStyleLabel(coordLbl, FARM_UI.muted, 12, ALIGN.LEFT)
        coordLbl:Show(true)

        local delBtn = row:CreateChildWidget("button", "tt_spot_del_" .. i, 0, true)
        delBtn:SetExtent(44, 22)
        delBtn:AddAnchor("RIGHT", row, -6, 0)
        ftStyleButton(delBtn, "Del", FARM_UI.red)
        local capturedIndex = i
        function delBtn:OnClick()
            if settings[settingsKey] then
                table.remove(settings[settingsKey], capturedIndex)
            end
            saveSettings()
            refreshSettingsLabels()
            rebuildSpotListWindow()
        end
        delBtn:SetHandler("OnClick", delBtn.OnClick)
        delBtn:Show(true)
    end
end

local function openSpotListWindow(spotType)
    spotType = spotType or "cooled"
    if not spotListWin then
        spotListWin = gui.CreateStyledWindow("tax_tracker_tree_spot_list", "Captured Spots", 540, 430)
        spotListWin:RemoveAllAnchors()
        spotListWin:AddAnchor("CENTER", "UIParent", 0, 0)

        gui.CreateCategoryPanel(spotListWin, "tt_spot_root", 12, 42, 516, 330, "Captured Spots")
        ftAddPanel(spotListWin, "tt_spot_hdr",    18, 72, 504, 26,  FARM_UI.header)
        ftAddPanel(spotListWin, "tt_spot_list",   18, 102, 504, 260, FARM_UI.listPanel)
        ftAddPanel(spotListWin, "tt_spot_footer", 18, 382, 504, 28, FARM_UI.groupActions)

        -- Column header labels in gold
        local function colHdr(id, text, x, w)
            local l = spotListWin:CreateChildWidget("label", id, 0, true)
            l:SetText(text)
            l:SetExtent(w, 22)
            l:AddAnchor("TOPLEFT", spotListWin, x, 76)
            l:SetAutoResize(false)
            ftStyleLabel(l, FARM_UI.gold, 12, ALIGN.LEFT)
            l:Show(true)
        end
        colHdr("tt_spot_h_name",  "Name",        26,  190)
        colHdr("tt_spot_h_zone",  "Zone",        222, 110)
        colHdr("tt_spot_h_coord", "Coordinates", 336, 140)
        colHdr("tt_spot_h_del",   "",            486,  44)

        local prevBtn = spotListWin:CreateChildWidget("button", "tt_spot_prev", 0, true)
        ftPlace(prevBtn, "BOTTOMLEFT", spotListWin, nil, 28, -18, 76, 22)
        ftStyleButton(prevBtn, "Prev", FARM_UI.button)
        function prevBtn:OnClick()
            spotListPage = spotListPage - 1
            rebuildSpotListWindow()
        end
        prevBtn:SetHandler("OnClick", prevBtn.OnClick)
        prevBtn:Show(true)
        spotListWin._prevBtn = prevBtn

        local pageLbl = spotListWin:CreateChildWidget("label", "tt_spot_page", 0, true)
        pageLbl:SetExtent(100, 22)
        pageLbl:AddAnchor("BOTTOM", spotListWin, 0, -18)
        pageLbl:SetAutoResize(false)
        pageLbl:SetText("1 / 1")
        ftStyleLabel(pageLbl, FARM_UI.muted, 12, ALIGN.CENTER)
        pageLbl:Show(true)
        spotListWin._pageLbl = pageLbl

        local nextBtn = spotListWin:CreateChildWidget("button", "tt_spot_next", 0, true)
        ftPlace(nextBtn, "BOTTOMRIGHT", spotListWin, nil, -28, -18, 76, 22)
        ftStyleButton(nextBtn, "Next", FARM_UI.button)
        function nextBtn:OnClick()
            spotListPage = spotListPage + 1
            rebuildSpotListWindow()
        end
        nextBtn:SetHandler("OnClick", nextBtn.OnClick)
        nextBtn:Show(true)
        spotListWin._nextBtn = nextBtn
    end

    spotListWin._spotType = spotType
    if spotListWin.styledTitle then
        if spotType == "mineral" then
            spotListWin.styledTitle:SetText("Dried Mineral Water Spots")
        else
            spotListWin.styledTitle:SetText("Cooled Tree Spots")
        end
    elseif spotListWin.SetTitle then
        if spotType == "mineral" then
            spotListWin:SetTitle("Dried Mineral Water Spots")
        else
            spotListWin:SetTitle("Cooled Tree Spots")
        end
    end
    spotListPage = 1
    rebuildSpotListWindow()
    spotListWin:Show(true)
end

-- Capture a mineral-water spot at the player's current position. Mirrors
-- captureCooledTreeSpot. Lives on FarmSystem to avoid module-locals.
function FarmSystem._captureMineralWaterSpot()
    local pos = capturePlayerPosition()
    if not pos then
        log("Could not capture mineral water spot: player position unavailable.")
        return nil
    end
    local customName = nil
    if FarmSystem._settingsMineralEdit and FarmSystem._settingsMineralEdit.GetText then
        local text = FarmSystem._settingsMineralEdit:GetText()
        if text and text ~= "" then customName = text end
    end
    local spot = FarmSystem._makeMineralWaterSpot(pos, customName)
    if FarmSystem._settingsMineralEdit and FarmSystem._settingsMineralEdit.SetText then
        FarmSystem._settingsMineralEdit:SetText("")
    end
    refreshSettingsLabels()
    if spotListWin and spotListWin:IsVisible() and spotListWin._spotType == "mineral" then
        rebuildSpotListWindow()
    end
    log("Captured mineral water spot: " .. tostring(spot.name))
    return spot
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
            elseif FarmSystem._isFishInfo(info) then
                local pos = capturePlayerPosition()
                if pos then
                    local fishFarm = FarmSystem._ensureFarmForFishZone(pos)
                    if fishFarm and tryAddDoodad(fishFarm, info) then
                        addAutotrackerItem(fishFarm, info.name, true)
                        if detailWin and detailWin:IsVisible() and detailFarmId == fishFarm.id then
                            rebuildDoodadList()
                        end
                    end
                end
            elseif FarmSystem._isGamekeeperInfo(info) then
                local pos = capturePlayerPosition()
                if pos then
                    local gkFarm = FarmSystem._ensureFarmForGamekeeperZone(pos)
                    if gkFarm and tryAddDoodad(gkFarm, info) then
                        addAutotrackerItem(gkFarm, info.name, true)
                        if detailWin and detailWin:IsVisible() and detailFarmId == gkFarm.id then
                            rebuildDoodadList()
                        end
                    end
                end
            elseif FarmSystem._isDriedMineralWaterInfo(info) then
                local pos = capturePlayerPosition()
                if pos then
                    local spot = FarmSystem._findNearestMineralWaterSpot(pos)
                    if not spot then
                        log("No captured mineral water spot in this zone. Capture the spot first in settings.")
                    else
                        local mwFarm = FarmSystem._ensureFarmForMineralWaterSpot(spot)
                        if mwFarm and tryAddDoodad(mwFarm, info) then
                            addAutotrackerItem(mwFarm, info.name, true)
                            if detailWin and detailWin:IsVisible() and detailFarmId == mwFarm.id then
                                rebuildDoodadList()
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
    -- Make sure global favourites appear in this farm's filter lists. Doing
    -- it here covers the "open filter on a fresh farm" case; tryAddDoodad
    -- also calls _seedFavourites so they appear without ever opening the
    -- window.
    if FarmSystem._seedFavourites then FarmSystem._seedFavourites(farm) end
    filterRebuildId = filterRebuildId + 1
    local rid = filterRebuildId

    ftDestroyWidget(filterWin._playerContainer)
    ftDestroyWidget(filterWin._entityContainer)

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

    local function buildColumn(list, page, containerName, xOff, isPlayer)
        local startIdx = (page - 1) * FW_ROWS_PER_PAGE + 1
        local endIdx   = math.min(startIdx + FW_ROWS_PER_PAGE - 1, #list)
        local rowCount = math.max(1, endIdx - startIdx + 1)

        local c = filterWin:CreateChildWidget("emptywidget", containerName.."_"..rid, 0, true)
        c:SetExtent(FW_COL_W, rowCount * FW_ROW_H)
        c:RemoveAllAnchors()
        c:AddAnchor("TOPLEFT", filterWin, xOff, 104)
        c:Show(true)

        if #list == 0 then
            local lbl = c:CreateChildWidget("label", containerName.."_empty_"..rid, 0, true)
            lbl:SetText(xOff < 200 and "No players scanned yet." or "No entities scanned yet.")
            lbl:SetExtent(FW_COL_W - 12, 22)
            lbl:AddAnchor("TOPLEFT", c, 0, 4)
            lbl:SetAutoResize(false)
            ftStyleLabel(lbl, FARM_UI.muted, 12, ALIGN.LEFT)
            lbl:Show(true)
        else
            for i = startIdx, endIdx do
                local entry = list[i]
                local y     = (i - startIdx) * FW_ROW_H
                local uid   = fwId()
                local captured = entry
                local rowBg = c:CreateChildWidget("emptywidget", containerName.."_row_"..uid, 0, true)
                rowBg:SetExtent(FW_COL_W, FW_ROW_H - 2)
                rowBg:AddAnchor("TOPLEFT", c, 0, y)
                local tone = (i - startIdx + 1) % 2 == 0 and FARM_UI.rowEven or FARM_UI.rowOdd
                local shade = rowBg:CreateColorDrawable(tone[1], tone[2], tone[3], tone[4], "background")
                shade:AddAnchor("TOPLEFT", rowBg, 0, 0)
                shade:AddAnchor("BOTTOMRIGHT", rowBg, 0, 0)
                shade:Show(true)
                rowBg:Show(true)
                makeFilterCheckbox(c, uid, 0, y+1, entry.enabled, function(val)
                    captured.enabled = val
                    saveFarm(farm)
                end)
                local lbl = c:CreateChildWidget("label", containerName.."_lbl_"..uid, 0, true)
                lbl:SetExtent(FW_COL_W - 50, FW_ROW_H)
                lbl:AddAnchor("TOPLEFT", c, 24, y-2)
                lbl:SetText(entry.name ~= "" and entry.name or "(no owner)")
                lbl:SetAutoResize(false)
                ftStyleLabel(lbl, FARM_UI.white, 12, ALIGN.LEFT)
                lbl:Show(true)

                -- Favourite toggle (★). Persists in settings.favourite{Players,Entities}
                -- and bypasses per-farm filter rejection / populateFilter lock.
                local star = c:CreateChildWidget("button", containerName.."_fav_"..uid, 0, true)
                star:SetExtent(20, 20)
                star:AddAnchor("TOPLEFT", c, FW_COL_W - 26, y + 3)
                local function isFav()
                    if isPlayer then return FarmSystem._isFavouritePlayer(captured.name) end
                    return FarmSystem._isFavouriteEntity(captured.name)
                end
                local function refreshStar()
                    local fav = isFav()
                    star:SetText(fav and "*" or "-")
                    if star.style and star.style.SetColor then
                        if fav then star.style:SetColor(1.0, 0.84, 0.0, 1.0)
                        else star.style:SetColor(0.5, 0.5, 0.5, 1.0) end
                    end
                end
                refreshStar()
                function star:OnClick()
                    if isPlayer then FarmSystem._toggleFavouritePlayer(captured.name)
                    else FarmSystem._toggleFavouriteEntity(captured.name) end
                    -- Favouriting forces the per-farm checkbox to enabled so the
                    -- filter actually lets it through right now.
                    if isFav() and not captured.enabled then
                        captured.enabled = true
                        saveFarm(farm)
                    end
                    refreshStar()
                end
                star:SetHandler("OnClick", star.OnClick)
                star:Show(true)
            end
        end
        return c
    end

    filterWin._playerContainer = buildColumn(players,  filterPlayerPage, "ft_fw_pc", 18,  true)
    filterWin._entityContainer = buildColumn(entities, filterEntityPage, "ft_fw_ec", 312, false)
end

-- Expose for cross-scope live-refresh from tryAddDoodad (which is defined
-- earlier in the file and can't see this local directly).
FarmSystem._rebuildFilterLists = rebuildFilterLists

openFilterWindow = function(farm)
    if not filterWin then
        filterWin = gui.CreateStyledWindow("tax_tracker_farm_filters", "Scan Filters", FW_W, FW_H)
        filterWin:RemoveAllAnchors()
        filterWin:AddAnchor("CENTER", "UIParent", 0, 0)
        gui.CreateCategoryPanel(filterWin, "ft_filter_left_panel", 12, 42, 282, 326, "Players")
        gui.CreateCategoryPanel(filterWin, "ft_filter_right_panel", 306, 42, 282, 326, "Entities")
        ftAddPanel(filterWin, "ft_filter_left_header", 18, 76, FW_COL_W, 24, FARM_UI.groupDetails)
        ftAddPanel(filterWin, "ft_filter_right_header", 312, 76, FW_COL_W, 24, FARM_UI.groupDetails)
        ftAddPanel(filterWin, "ft_filter_left_list", 18, 104, FW_COL_W, 260, FARM_UI.listPanel)
        ftAddPanel(filterWin, "ft_filter_right_list", 312, 104, FW_COL_W, 260, FARM_UI.listPanel)
        ftAddPanel(filterWin, "ft_filter_footer", 18, FW_H - 48, FW_W - 36, 26, FARM_UI.groupActions)

        -- Column headers
        local hdrPlayers = filterWin:CreateChildWidget("label", "ft_fw_hdr_p", 0, true)
        hdrPlayers:SetExtent(FW_COL_W - 42, 24)
        hdrPlayers:AddAnchor("TOPLEFT", filterWin, 52, 78)
        hdrPlayers:SetText("Scan only from these players:")
        ftStyleLabel(hdrPlayers, FARM_UI.gold, 12, ALIGN.LEFT)
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

        filterWin._cbPlayerFilter = makeInlineCb("ft_fw_cb_pfilter", 28, 80, function(val)
            if filterWin._currentFarm then
                filterWin._currentFarm.filterPlayersEnabled = val
                saveFarm(filterWin._currentFarm)
                rebuildFilterLists(filterWin._currentFarm)
            end
        end)

        local hdrEntities = filterWin:CreateChildWidget("label", "ft_fw_hdr_e", 0, true)
        hdrEntities:SetExtent(FW_COL_W - 42, 24)
        hdrEntities:AddAnchor("TOPLEFT", filterWin, 346, 78)
        hdrEntities:SetText("Scan only these entities:")
        ftStyleLabel(hdrEntities, FARM_UI.gold, 12, ALIGN.LEFT)
        hdrEntities:Show(true)

        filterWin._cbEntityFilter = makeInlineCb("ft_fw_cb_efilter", 322, 80, function(val)
            if filterWin._currentFarm then
                filterWin._currentFarm.filterEntitiesEnabled = val
                saveFarm(filterWin._currentFarm)
                rebuildFilterLists(filterWin._currentFarm)
            end
        end)

        -- Reset button (bottom-right)
        local btnReset = filterWin:CreateChildWidget("button", "ft_fw_reset", 0, true)
        ftPlace(btnReset, "BOTTOMRIGHT", filterWin, nil, -28, -25, 76, 22)
        ftStyleButton(btnReset, "Reset", FARM_UI.red)
        filterWin._btnReset = btnReset
        btnReset:Show(true)

        filterWin._playerContainer = filterWin:CreateChildWidget("emptywidget", "ft_fw_pc_init", 0, true)
        filterWin._playerContainer:SetExtent(FW_COL_W, 10)
        filterWin._playerContainer:AddAnchor("TOPLEFT", filterWin, 18, 104)
        filterWin._entityContainer = filterWin:CreateChildWidget("emptywidget", "ft_fw_ec_init", 0, true)
        filterWin._entityContainer:SetExtent(FW_COL_W, 10)
        filterWin._entityContainer:AddAnchor("TOPLEFT", filterWin, 312, 104)

        -- Pagination for player column
        local pPageCtrl = W_CTRL.CreatePageControl("ft_fw_p_pagectrl", filterWin, "tutorial")
        pPageCtrl:RemoveAllAnchors()
        pPageCtrl:AddAnchor("BOTTOMLEFT", filterWin, 18, -25)
        function pPageCtrl:ProcOnPageChanged(pageIndex)
            filterPlayerPage = pageIndex
            rebuildFilterLists(filterWin._currentFarm)
        end
        pPageCtrl:Show(true)
        filterWin._pPageCtrl = pPageCtrl

        -- Pagination for entity column
        local ePageCtrl = W_CTRL.CreatePageControl("ft_fw_e_pagectrl", filterWin, "tutorial")
        ePageCtrl:RemoveAllAnchors()
        ePageCtrl:AddAnchor("BOTTOMLEFT", filterWin, 312, -25)
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
-- ACTIONS BAR — unified floating panel
-- ============================================================
-- Replaces three separate floating widgets (AUTO, +Land, TRACKING) plus
-- HUDManager's standalone Arise button. The bar auto-resizes vertically
-- based on which toggles are enabled. Single position persisted in
-- settings.actionsBarX/Y.
--
-- ALL methods attach to FarmSystem.floatActions (table fields) so they do
-- NOT add module-level `local`s — the chunk is at Lua's 200-local cap.
--
-- See "MIGRATION NOTES" comment at the bottom of this section for the
-- step-by-step path to Option B (clean shared module).
-- ============================================================

-- Hide the legacy standalone Arise widget so it doesn't double up with
-- the bar's Arise button.
function FarmSystem.floatActions.suppressStandaloneArise()
    pcall(function()
        local HUDManager = require("tax_tracker/ui/hudmanager")
        if HUDManager and HUDManager.hide then HUDManager.hide() end
    end)
end

-- Restore the standalone Arise widget. Called when the bar is destroyed
-- so the user always has a way to open the saved-lands window.
function FarmSystem.floatActions.restoreStandaloneArise()
    pcall(function()
        local HUDManager = require("tax_tracker/ui/hudmanager")
        if HUDManager and HUDManager.show then HUDManager.show() end
    end)
end

function FarmSystem.floatActions.invokeArise()
    pcall(function()
        local HUDManager = require("tax_tracker/ui/hudmanager")
        if HUDManager and HUDManager.invokeToggle then HUDManager.invokeToggle() end
    end)
end

function FarmSystem.floatActions.openEditorFromTarget()
    -- Open the land editor and immediately trigger its built-in "From Target"
    -- button so coordinates, name, and (where possible) type are filled from
    -- whatever the player is currently targeting.
    local ok, UIManager = pcall(require, "tax_tracker/ui/uimanager_v2")
    if not (ok and UIManager) then
        log("Quick-track: UIManager unavailable")
        return
    end
    pcall(function()
        if not UIManager.isInitialized then UIManager.initialize(nil, nil) end
        if UIManager.clearEditMode then UIManager.clearEditMode() end
        if UIManager.showWindow then UIManager.showWindow() end
        local trackTargetBtn = UIManager.components and UIManager.components.trackTargetBtn
        if trackTargetBtn and trackTargetBtn.OnClick then trackTargetBtn:OnClick() end
    end)
end

function FarmSystem.floatActions.isAutotrackerVisible()
    return autotrackerWin and autotrackerWin.IsVisible and autotrackerWin:IsVisible()
end

function FarmSystem.floatActions.toggleTrackingWindow()
    pcall(function()
        ensureAutotrackerWindow()
        if FarmSystem.floatActions.isAutotrackerVisible() then
            autotrackerWin:Show(false)
        else
            rebuildAutotrackerWindow()
            autotrackerWin:Show(true)
        end
        FarmSystem.floatActions.rebuild()  -- refresh TRACKING ON/OFF label + tone
    end)
end

-- Hunt down any widget(s) registered under a given name and hide+destroy
-- them. Used to cull orphan bars/buttons left over from prior addon loads
-- where module-locals were reset and our cached references were lost.
-- The 50-iteration cap is a sanity guard against an engine that returns
-- the same widget repeatedly without releasing it.
function FarmSystem.floatActions.cullByName(name)
    if not api.Interface then return end
    -- Try every lookup method the engine exposes. FindWidget commonly
    -- misses CreateEmptyWindow widgets but GetWindow / GetWidgetByName
    -- have been observed to find them in HUDManager — see hudmanager.lua's
    -- destroyNamedWidget for the same pattern.
    local methods = {"FindWidget", "GetWindow", "GetWidgetByName"}
    for _ = 1, 50 do
        local foundAny = false
        for _, fn in ipairs(methods) do
            local f = api.Interface[fn]
            if f then
                local ok, w = pcall(function() return f(api.Interface, name) end)
                if ok and w then
                    foundAny = true
                    pcall(function() if w.Show then w:Show(false) end end)
                    pcall(function() if w.RemoveAllAnchors then w:RemoveAllAnchors() end end)
                    pcall(function() if w.AddAnchor then w:AddAnchor("TOPLEFT", "UIParent", -10000, -10000) end end)
                    pcall(function() if w.SetExtent then w:SetExtent(1, 1) end end)
                    pcall(function() if w.Destroy then w:Destroy() end end)
                end
            end
        end
        if not foundAny then return end
    end
end

-- Build a single button widget as a child of the bar's container.
function FarmSystem.floatActions.makeBarButton(parent, name, label, tone, onClick)
    local fa = FarmSystem.floatActions
    local cfg = fa.config
    -- Snapshot of the current bar session at button creation. Read by the
    -- click handler against the live disk value to detect /reload orphans.
    local mySession = fa.bar and fa.bar.mySession
    local btn = api.Interface:CreateWidget("button", name, parent)
    btn:SetExtent(cfg.BTN_W, cfg.BTN_H)
    btn:SetText("")
    btn._bg = btn:CreateColorDrawable(tone[1], tone[2], tone[3], tone[4], "background")
    btn._bg:AddAnchor("TOPLEFT", btn, 0, 0)
    btn._bg:AddAnchor("BOTTOMRIGHT", btn, 0, 0)
    btn._bg:Show(true)
    btn._label = btn:CreateChildWidget("label", name.."_lbl", 0, true)
    btn._label:SetExtent(cfg.BTN_W, cfg.BTN_H - 2)
    btn._label:AddAnchor("TOPLEFT", btn, 0, 1)
    if btn._label.style then
        if btn._label.style.SetFontSize then btn._label.style:SetFontSize(11) end
        if btn._label.style.SetAlign then btn._label.style:SetAlign(ALIGN.CENTER) end
        if btn._label.style.SetColor then btn._label.style:SetColor(1, 1, 1, 1) end
    end
    if btn._label.EnablePick then btn._label:EnablePick(false) end
    btn._label:SetText(label or "")
    btn._label:Show(true)
    btn.OnClick = function()
        local s = api.GetSettings("tax_tracker") or {}
        if (s.barSession or 0) ~= mySession then return end
        onClick()
    end
    btn:SetHandler("OnClick", btn.OnClick)
    btn:Show(true)
    return btn
end

-- Tear down the live button children (called before re-rendering, and on
-- bar destroy). We can't trust Destroy() in this engine, so we Show(false)
-- + clear our list. Children stay parented to the bar's container; when
-- the next rebuild runs, fresh widgets get unique names so they don't
-- collide with the hidden ones.
-- Hide every tracked button widget AND any orphans that share our stable
-- button names. Stable names + cull-by-name is what makes the bar
-- reload-safe — the per-load `buttons` array would reset on /reload and
-- miss the old children otherwise.
function FarmSystem.floatActions.clearButtons()
    for _, b in ipairs(FarmSystem.floatActions.buttons) do
        pcall(function() if b.Show then b:Show(false) end end)
    end
    FarmSystem.floatActions.buttons = {}
    for _, n in pairs(FarmSystem.floatActions.names) do
        if n ~= FarmSystem.floatActions.names.bar then
            FarmSystem.floatActions.cullByName(n)
        end
    end
end

-- Render the bar's contents based on the current settings flags. Re-runs
-- whenever a toggle changes, the autotracker visibility flips, or the
-- AUTO button is clicked (label/tone need to update).
function FarmSystem.floatActions.rebuild()
    local fa = FarmSystem.floatActions
    if not fa.bar.widget then
        fa.create()
        return
    end

    fa.clearButtons()
    local cfg = fa.config

    -- Build ordered list of items based on which toggles are enabled.
    -- Arise is always first (the addon's primary entrypoint).
    local items = {}
    table.insert(items, {
        name = fa.names.arise, label = "Arise", tone = cfg.TONE_ON,
        onClick = fa.invokeArise,
    })
    if settings.showFloatingBtn then
        table.insert(items, {
            name = fa.names.auto,
            label = settings.autotrackerEnabled and "Autotracker ON" or "Autotracker OFF",
            tone  = settings.autotrackerEnabled and cfg.TONE_ON or cfg.TONE_OFF,
            onClick = function()
                setAutotrackerEnabled(not settings.autotrackerEnabled)
                fa.rebuild()
            end,
        })
    end
    if settings.showTrackButton then
        table.insert(items, {
            name = fa.names.addLand, label = "+ Land", tone = cfg.TONE_ON,
            onClick = fa.openEditorFromTarget,
        })
    end
    if settings.showTrackingViewBtn then
        local on = fa.isAutotrackerVisible()
        table.insert(items, {
            name = fa.names.track,
            label = on and "Tracking Window ON" or "Tracking Window OFF",
            tone  = on and cfg.TONE_ON or cfg.TONE_OFF,
            onClick = fa.toggleTrackingWindow,
        })
    end
    if settings.showFarmListBtn then
        table.insert(items, {
            name = fa.names.farms, label = "Farm Tracker", tone = cfg.TONE_ON,
            onClick = function() FarmSystem.toggleFarmWindow() end,
        })
    end

    -- Resize the container to fit N stacked buttons.
    local count = #items
    local h = cfg.PAD * 2 + count * cfg.BTN_H + math.max(0, count - 1) * cfg.GAP
    fa.bar.widget:SetExtent(cfg.OUTER_W, h)

    -- Place children top-to-bottom with consistent gaps.
    for i, item in ipairs(items) do
        local b = fa.makeBarButton(fa.bar.widget, item.name, item.label, item.tone, item.onClick)
        b:RemoveAllAnchors()
        b:AddAnchor("TOPLEFT", fa.bar.widget, cfg.PAD, cfg.PAD + (i - 1) * (cfg.BTN_H + cfg.GAP))
        table.insert(fa.buttons, b)
    end
end

function FarmSystem.floatActions.destroy()
    FarmSystem.floatActions.clearButtons()
    if FarmSystem.floatActions.bar.staleHide and api.Off then
        pcall(function() api.Off("UPDATE", FarmSystem.floatActions.bar.staleHide) end)
        FarmSystem.floatActions.bar.staleHide = nil
    end
    if FarmSystem.floatActions.bar.widget then
        pcall(function() FarmSystem.floatActions.bar.widget:Show(false) end)
        FarmSystem.floatActions.bar.widget = nil
    end
    -- Cull any orphan bar widgets too. Belt-and-suspenders for the case
    -- where module-locals were reset and bar.widget is nil.
    FarmSystem.floatActions.cullByName(FarmSystem.floatActions.names.bar)
    -- Intentionally NOT calling restoreStandaloneArise() during destroy.
    -- The standalone Arise was hidden by suppressStandaloneArise() at create
    -- time. If we un-hide it here on /reload, then HUDManager re-initializes
    -- (often creating a fresh widget alongside the now-visible old one), and
    -- the next bar create() only hides the *latest* HUDManager widget — the
    -- one we just un-hid stays visible as a permanent orphan. Symptom: "a
    -- second floating window appears after the first /reload".
    -- HUDManager.cleanup() handles destroying its own widgets at addon
    -- shutdown; we don't need to re-show them on the way out.
end

function FarmSystem.floatActions.create()
    local fa  = FarmSystem.floatActions
    local cfg = fa.config
    if fa.bar.widget then
        fa.rebuild()
        return
    end

    -- Session-id deafness for /reload orphans. Same pattern as
    -- taxpayment.lua's listener guard. The bar is CreateEmptyWindow which
    -- FindWidget can't see, Destroy() is unreliable, /reload doesn't fire
    -- OnUnload — so we cannot physically remove the orphan bar. Instead we
    -- bump a counter on disk; each button's click handler snapshots the
    -- counter at creation and compares against the live value before
    -- running its callback. Orphan handlers see a stale id and become
    -- deaf, so OLD bar's TRACKING button no longer opens its own copy of
    -- the tracking window.
    local cur = api.GetSettings("tax_tracker") or {}
    cur.barSession = (cur.barSession or 0) + 1
    pcall(function() api.SaveSettings() end)
    fa.bar.mySession = cur.barSession

    -- Cull child button orphans (CreateWidget buttons are typically findable).
    for _, n in pairs(fa.names) do
        if n ~= fa.names.bar then fa.cullByName(n) end
    end

    -- Reuse-if-findable for the bar itself. /reload doesn't fire OnUnload
    -- and CreateEmptyWindow widgets are unreliable to look up, but
    -- GetWindow / GetWidgetByName have been observed to surface them in
    -- HUDManager. If any method finds a prior bar, take it over instead
    -- of creating a fresh one stacked on top — the visual duplicate is
    -- exactly the OLD bar still alive in the engine.
    local existing = nil
    for _, fn in ipairs({"FindWidget", "GetWindow", "GetWidgetByName"}) do
        local f = api.Interface and api.Interface[fn]
        if f and not existing then
            local ok, found = pcall(function() return f(api.Interface, fa.names.bar) end)
            if ok and found then existing = found end
        end
    end

    local isReused = existing ~= nil
    local w = existing or api.Interface:CreateEmptyWindow(fa.names.bar, "UIParent")
    fa.bar.widget = w

    -- Skip bg creation when reusing an orphan — its bg drawable is still
    -- there. Stacking another drawable each /reload would just darken it.
    if not isReused then
        local bg = w:CreateColorDrawable(0.05, 0.05, 0.06, 0.62, "background")
        bg:AddAnchor("TOPLEFT", w, 0, 0)
        bg:AddAnchor("BOTTOMRIGHT", w, 0, 0)
        bg:Show(true)
    end

    settings.actionsBarX = settings.actionsBarX or settings.hudX or 970
    settings.actionsBarY = settings.actionsBarY or settings.hudY or 10
    saveSettings()
    -- Re-anchor in case we're reusing an orphan whose anchors are stale.
    pcall(function() if w.RemoveAllAnchors then w:RemoveAllAnchors() end end)
    w:AddAnchor("TOPLEFT", "UIParent", settings.actionsBarX, settings.actionsBarY)
    w:SetExtent(cfg.OUTER_W, cfg.PAD * 2 + cfg.BTN_H)  -- placeholder; rebuild() resizes

    function w:OnDragStart()
        if api.Input:IsShiftKeyDown() then
            w:StartMoving()
            api.Cursor:ClearCursor()
            api.Cursor:SetCursorImage(CURSOR_PATH.MOVE, 0, 0)
        end
    end
    w:SetHandler("OnDragStart", w.OnDragStart)
    function w:OnDragStop()
        local x, y = w:GetEffectiveOffset()
        if x and y then
            settings.actionsBarX = x
            settings.actionsBarY = y
            saveSettings()
        end
        w:StopMovingOrSizing()
        api.Cursor:ClearCursor()
    end
    w:SetHandler("OnDragStop", w.OnDragStop)

    w:Show(true)
    w:EnableDrag(true)

    -- Orphan self-hide via UPDATE.
    --
    -- /reload doesn't fire OnUnload and FindWidget can't see CreateEmptyWindow
    -- widgets, so we can't reach prior bars from the new load. Instead we
    -- piggy-back on api.On("UPDATE", ...) which (per sandbox notes) is the
    -- one event mechanism that survives /reload reliably. The handler
    -- captures `mySession` and `w` as upvalues — after the next /reload
    -- bumps the on-disk session counter, the orphan handler's snapshot no
    -- longer matches, so it hides its own widget on the very next tick and
    -- then unregisters itself. The current load's handler always matches so
    -- it does nothing.
    local mySession = fa.bar.mySession
    local function staleHide(...)
        local s = api.GetSettings("tax_tracker") or {}
        if (s.barSession or 0) == mySession then return end
        pcall(function() if w.Show then w:Show(false) end end)
        pcall(function() if w.RemoveAllAnchors then w:RemoveAllAnchors() end end)
        pcall(function() if w.AddAnchor then w:AddAnchor("TOPLEFT", "UIParent", -10000, -10000) end end)
        pcall(function() if w.SetExtent then w:SetExtent(1, 1) end end)
        if api.Off then pcall(function() api.Off("UPDATE", staleHide) end) end
    end
    fa.bar.staleHide = staleHide
    if api.On then pcall(function() api.On("UPDATE", staleHide) end) end

    fa.suppressStandaloneArise()
    fa.rebuild()
end

-- ============================================================================
-- MIGRATION NOTES — moving from Option A (here) to Option B (shared module)
-- ============================================================================
-- The bar lives inline in FarmSystem because moving it would have required
-- refactoring HUDManager's singleton/orphan-cleanup machinery, which has
-- known scar tissue. If/when that complexity is acceptable:
--
-- 1. Create tax_tracker/ui/actions_bar.lua exporting:
--      ActionsBar.register(name, { isEnabled=fn, getLabel=fn, getTone=fn,
--                                   onClick=fn })
--      ActionsBar.unregister(name)
--      ActionsBar.rebuild()  -- iterates registrations in order
--      ActionsBar.create() / destroy() / show() / hide()
-- 2. Move bar/buttons/config tables and create/destroy/rebuild logic from
--    here into that module. Keep openEditorFromTarget /
--    toggleTrackingWindow here in FarmSystem (they're farm-specific).
-- 3. In HUDManager.initialize(): instead of creating the standalone Arise
--    widget, call ActionsBar.register("arise", { ... onClick = callback }).
--    Remove HUDManager.hide() / restoreStandaloneArise() calls — no longer
--    needed because Arise is no longer a separate widget.
-- 4. In FarmSystem (here): replace the inline rebuild() with three
--    register() calls — one per toggle. The settings-toggle handlers in
--    openSettingsWindow flip the enabled flag and call ActionsBar.rebuild().
-- 5. Delete obsolete settings keys: floatingBtnX/Y, trackBtnX/Y,
--    trackingViewBtnX/Y, hudX/Y. They're already unused in Option A but
--    still consume settings space.
-- 6. main.lua's MichaelClient ESC entry doesn't depend on the bar — leave
--    that path alone.
-- ============================================================================

-- ============================================================
-- SETTINGS WINDOW
-- ============================================================

local SETTINGS_W = 500
local SETTINGS_H = 660

local function openSettingsWindow()
    if settingsWin then
        refreshSettingsLabels()
        settingsWin:Show(true)
        return
    end

    settingsWin = gui.CreateStyledWindow("tax_tracker_farm_settings", "Farm Tracker Settings", SETTINGS_W, SETTINGS_H)
    settingsWin:RemoveAllAnchors()
    settingsWin:AddAnchor("CENTER", "UIParent", 0, 0)

    local ui = {
        white = {1, 1, 1, 1}, muted = {0.72, 0.72, 0.72, 1}, gold = {1, 0.84, 0, 1},
        green = {0.12, 0.28, 0.15, 0.95}, red = {0.24, 0.09, 0.09, 0.95},
        button = {0.11, 0.11, 0.13, 0.92}, panel = {0.05, 0.05, 0.06, 0.64},
        header = {0.09, 0.09, 0.11, 0.95}, input = {0.10, 0.10, 0.11, 0.96},
        groupDetails = {0.07, 0.07, 0.08, 0.74}, groupTools = {0.055, 0.06, 0.07, 0.74},
        groupActions = {0.065, 0.065, 0.075, 0.74},
        rowOdd = {0.08, 0.08, 0.095, 0.72}, rowEven = {0.12, 0.12, 0.135, 0.72}
    }

    local function panel(x, y, w, h, color)
        local c = color or ui.panel
        local box = settingsWin:CreateChildWidget("emptywidget", "ft_sw_panel_" .. tostring(x) .. "_" .. tostring(y) .. "_" .. tostring(h), 0, true)
        box:SetExtent(w, h)
        box:AddAnchor("TOPLEFT", settingsWin, x, y)
        local p = box:CreateColorDrawable(c[1], c[2], c[3], c[4], "background")
        p:AddAnchor("TOPLEFT", box, 0, 0)
        p:AddAnchor("BOTTOMRIGHT", box, 0, 0)
        p:Show(true)
        box:Show(true)
        return box
    end

    local function label(id, text, x, y, w, color, size)
        local l = settingsWin:CreateChildWidget("label", id, 0, true)
        l:SetText(text or "")
        l:SetExtent(w or 260, 22)
        l:AddAnchor("TOPLEFT", settingsWin, x, y)
        if l.style then
            if l.style.SetFontSize then l.style:SetFontSize(size or 12) end
            if l.style.SetAlign then l.style:SetAlign(ALIGN.LEFT) end
            if l.style.SetColor then
                local c = color or ui.white
                l.style:SetColor(c[1], c[2], c[3], c[4])
            elseif ApplyTextColor and FONT_COLOR then
                ApplyTextColor(l, FONT_COLOR.DEFAULT)
            end
        end
        l:Show(true)
        return l
    end

    local function button(id, text, x, y, w, h, tone, onClick)
        local b = settingsWin:CreateChildWidget("button", id, 0, true)
        b:SetExtent(w or 120, h or 24)
        b:AddAnchor("TOPLEFT", settingsWin, x, y)
        b:SetText("")
        local c = tone or ui.button
        b._bg = b:CreateColorDrawable(c[1], c[2], c[3], c[4], "background")
        b._bg:AddAnchor("TOPLEFT", b, 0, 0)
        b._bg:AddAnchor("BOTTOMRIGHT", b, 0, 0)
        b._bg:Show(true)
        b._label = b:CreateChildWidget("label", id .. "_label", 0, true)
        b._label:SetText(text or "")
        b._label:SetExtent(w or 120, (h or 24) - 2)
        b._label:AddAnchor("TOPLEFT", b, 0, 1)
        if b._label.style then
            if b._label.style.SetFontSize then b._label.style:SetFontSize(11) end
            if b._label.style.SetAlign then b._label.style:SetAlign(ALIGN.CENTER) end
            if b._label.style.SetColor then b._label.style:SetColor(1, 1, 1, 1) end
        end
        if b._label.EnablePick then b._label:EnablePick(false) end
        b._label:Show(true)
        function b:SetCleanText(nextText)
            if self._label then self._label:SetText(nextText or "") end
        end
        function b:SetTone(nextTone)
            local nextColor = nextTone or ui.button
            if self._bg and self._bg.SetColor then
                self._bg:SetColor(nextColor[1], nextColor[2], nextColor[3], nextColor[4])
            end
        end
        if onClick then
            function b:OnClick() onClick(self) end
            b:SetHandler("OnClick", b.OnClick)
        end
        b:Show(true)
        return b
    end

    local function inputBackplate(x, y, w, h)
        panel(x - 1, y - 1, w + 2, h + 2, {0, 0, 0, 0.95})
        panel(x, y, w, h, ui.input)
    end

    local function styleSettingsEdit(edit)
        if not edit then return end
        if edit.CreateColorDrawable and not edit._styledInputBorder then
            edit._styledInputBorder = edit:CreateColorDrawable(0, 0, 0, 0.95, "background")
            edit._styledInputPlate = edit:CreateColorDrawable(ui.input[1], ui.input[2], ui.input[3], ui.input[4], "background")
        end
        if edit._styledInputBorder then
            ftClearAnchors(edit._styledInputBorder)
            edit._styledInputBorder:AddAnchor("TOPLEFT", edit, -1, -1)
            edit._styledInputBorder:AddAnchor("BOTTOMRIGHT", edit, 1, 1)
            edit._styledInputBorder:Show(true)
        end
        if edit._styledInputPlate then
            ftClearAnchors(edit._styledInputPlate)
            edit._styledInputPlate:AddAnchor("TOPLEFT", edit, 0, 0)
            edit._styledInputPlate:AddAnchor("BOTTOMRIGHT", edit, 0, 0)
            edit._styledInputPlate:Show(true)
        end
        if edit.style then
            if edit.style.SetFontSize then edit.style:SetFontSize(12) end
            if edit.style.SetAlign then edit.style:SetAlign(ALIGN.LEFT) end
            if edit.style.SetColor then edit.style:SetColor(1, 1, 1, 1) end
        end
    end

    gui.CreateCategoryPanel(settingsWin, "ft_sw_autotracker_panel", 12, 42, SETTINGS_W - 24, 258, "Autotracker")
    panel(20, 80, SETTINGS_W - 40, 214, ui.groupDetails)

    local MOD_OPTIONS = { "Any modifier", "Ctrl", "Alt", "Shift", "None required" }
    local MOD_VALUES  = { "any", "ctrl", "alt", "shift", "none" }
    local function modIndexFromValue(v)
        for i, val in ipairs(MOD_VALUES) do if val == v then return i end end
        return 1
    end

    label("ft_fb_mod_lbl", "Scan trigger key", 30, 86, 160, ui.muted)
    local modBtn
    local function updateModBtn()
        if modBtn then modBtn:SetCleanText(MOD_OPTIONS[modIndexFromValue(settings.scanModifier or "any")] or "Any modifier") end
    end
    modBtn = button("ft_fb_mod_btn", "", 250, 83, 210, 24, ui.button, function()
        local idx = (modIndexFromValue(settings.scanModifier or "any") % #MOD_VALUES) + 1
        settings.scanModifier = MOD_VALUES[idx]
        saveSettings()
        updateModBtn()
    end)
    updateModBtn()

    local floatBtn
    local function updateFloatBtn()
        if not floatBtn then return end
        floatBtn:SetCleanText(settings.showFloatingBtn and "On" or "Off")
        floatBtn:SetTone(settings.showFloatingBtn and ui.green or ui.button)
    end
    label("ft_fb_float_lbl", "Floating autotracker button", 30, 122, 260, ui.white)
    floatBtn = button("ft_fb_float_btn", "", 340, 120, 120, 24, ui.button, function()
        settings.showFloatingBtn = not settings.showFloatingBtn
        saveSettings()
        FarmSystem.floatActions.rebuild()
        updateFloatBtn()
    end)
    updateFloatBtn()

    local reminderBtn
    local function updateReminderBtn()
        if not reminderBtn then return end
        reminderBtn:SetCleanText(settings.farmMinuteReminderEnabled and "On" or "Off")
        reminderBtn:SetTone(settings.farmMinuteReminderEnabled and ui.green or ui.button)
    end
    label("ft_fb_reminder_lbl", "1-minute farm reminder popup", 30, 158, 260, ui.white)
    reminderBtn = button("ft_fb_reminder_btn", "", 340, 156, 120, 24, ui.button, function()
        settings.farmMinuteReminderEnabled = not settings.farmMinuteReminderEnabled
        saveSettings()
        updateReminderBtn()
    end)
    updateReminderBtn()

    local trackToggleBtn
    local function updateTrackToggleBtn()
        if not trackToggleBtn then return end
        trackToggleBtn:SetCleanText(settings.showTrackButton and "On" or "Off")
        trackToggleBtn:SetTone(settings.showTrackButton and ui.green or ui.button)
    end
    label("ft_fb_track_lbl", "Floating quick-track button (+ Land)", 30, 194, 280, ui.white)
    trackToggleBtn = button("ft_fb_track_btn", "", 340, 192, 120, 24, ui.button, function()
        settings.showTrackButton = not settings.showTrackButton
        saveSettings()
        FarmSystem.floatActions.rebuild()
        updateTrackToggleBtn()
    end)
    updateTrackToggleBtn()

    local trackingViewToggleBtn
    local function updateTrackingViewToggleBtn()
        if not trackingViewToggleBtn then return end
        trackingViewToggleBtn:SetCleanText(settings.showTrackingViewBtn and "On" or "Off")
        trackingViewToggleBtn:SetTone(settings.showTrackingViewBtn and ui.green or ui.button)
    end
    label("ft_fb_trackview_lbl", "Floating tracking-window button", 30, 230, 280, ui.white)
    trackingViewToggleBtn = button("ft_fb_trackview_btn", "", 340, 228, 120, 24, ui.button, function()
        settings.showTrackingViewBtn = not settings.showTrackingViewBtn
        saveSettings()
        FarmSystem.floatActions.rebuild()
        updateTrackingViewToggleBtn()
    end)
    updateTrackingViewToggleBtn()

    local farmListToggleBtn
    local function updateFarmListToggleBtn()
        if not farmListToggleBtn then return end
        farmListToggleBtn:SetCleanText(settings.showFarmListBtn and "On" or "Off")
        farmListToggleBtn:SetTone(settings.showFarmListBtn and ui.green or ui.button)
    end
    label("ft_fb_farms_lbl", "Floating Farm Tracker button", 30, 266, 280, ui.white)
    farmListToggleBtn = button("ft_fb_farms_btn", "", 340, 264, 120, 24, ui.button, function()
        settings.showFarmListBtn = not settings.showFarmListBtn
        saveSettings()
        FarmSystem.floatActions.rebuild()
        updateFarmListToggleBtn()
    end)
    updateFarmListToggleBtn()

    gui.CreateCategoryPanel(settingsWin, "ft_fb_spot_panel", 12, 316, SETTINGS_W - 24, 156, "Cooled Tree Trunk Spots")
    panel(20, 354, SETTINGS_W - 40, 84, ui.groupTools)
    settingsCooledSpotLbl = label("ft_fb_spot_count", "", 30, 362, 420, ui.white)
    label("ft_fb_spot_name_lbl", "Spot name", 30, 392, 80, ui.muted)
    inputBackplate(108, 388, 262, 30)

    if W_CTRL and W_CTRL.CreateEdit then
        settingsSpotNameEdit = W_CTRL.CreateEdit("ft_fb_spot_name_edit", settingsWin)
    else
        settingsSpotNameEdit = settingsWin:CreateChildWidget("edit", "ft_fb_spot_name_edit", 0, true)
    end
    settingsSpotNameEdit:SetExtent(254, 26)
    settingsSpotNameEdit:AddAnchor("TOPLEFT", settingsWin, 112, 390)
    settingsSpotNameEdit:SetText("")
    styleSettingsEdit(settingsSpotNameEdit)
    settingsSpotNameEdit:Show(true)

    panel(20, 442, SETTINGS_W - 40, 30, ui.groupActions)
    button("ft_fb_capture", "Capture Spot", 30, 448, 130, 24, ui.green, function() captureCooledTreeSpot() end)
    button("ft_fb_list", "List Spots", 170, 448, 110, 24, ui.button, function() openSpotListWindow("cooled") end)
    button("ft_fb_clear", "Clear Spots", 290, 448, 110, 24, ui.red, function()
        settings.cooledTreeSpots = {}
        saveSettings()
        refreshSettingsLabels()
        if spotListWin and spotListWin:IsVisible() and spotListWin._spotType == "cooled" then
            rebuildSpotListWindow()
        end
    end)

    -- Dried Up Mineral Water section — same layout as cooled tree, shifted by 166.
    gui.CreateCategoryPanel(settingsWin, "ft_fb_mw_panel", 12, 482, SETTINGS_W - 24, 156, "Dried Up Mineral Water Spots")
    panel(20, 520, SETTINGS_W - 40, 84, ui.groupTools)
    FarmSystem._settingsMineralLbl = label("ft_fb_mw_count", "", 30, 528, 420, ui.white)
    label("ft_fb_mw_name_lbl", "Spot name", 30, 558, 80, ui.muted)
    inputBackplate(108, 554, 262, 30)

    if W_CTRL and W_CTRL.CreateEdit then
        FarmSystem._settingsMineralEdit = W_CTRL.CreateEdit("ft_fb_mw_name_edit", settingsWin)
    else
        FarmSystem._settingsMineralEdit = settingsWin:CreateChildWidget("edit", "ft_fb_mw_name_edit", 0, true)
    end
    FarmSystem._settingsMineralEdit:SetExtent(254, 26)
    FarmSystem._settingsMineralEdit:AddAnchor("TOPLEFT", settingsWin, 112, 556)
    FarmSystem._settingsMineralEdit:SetText("")
    styleSettingsEdit(FarmSystem._settingsMineralEdit)
    FarmSystem._settingsMineralEdit:Show(true)

    panel(20, 608, SETTINGS_W - 40, 30, ui.groupActions)
    button("ft_fb_mw_capture", "Capture Spot", 30, 614, 130, 24, ui.green, function()
        FarmSystem._captureMineralWaterSpot()
    end)
    button("ft_fb_mw_list", "List Spots", 170, 614, 110, 24, ui.button, function()
        openSpotListWindow("mineral")
    end)
    button("ft_fb_mw_clear", "Clear Spots", 290, 614, 110, 24, ui.red, function()
        settings.mineralWaterSpots = {}
        saveSettings()
        refreshSettingsLabels()
        if spotListWin and spotListWin:IsVisible() and spotListWin._spotType == "mineral" then
            rebuildSpotListWindow()
        end
    end)

    refreshSettingsLabels()
    settingsWin:Show(true)
end

-- ============================================================
-- MAIN WINDOW — farm list
-- ============================================================

local ROW_H          = 34
local NAME_W         = 250
local ZONE_W         = 160
local EARLIEST_W     = 120
local BTN_W          = 52
local GAP            = 8
local SCROLL_Y_START = 112

local COL_NAME_X = 12
local COL_ZONE_X = COL_NAME_X + NAME_W + GAP
local COL_EARLIEST_X = COL_ZONE_X + ZONE_W + GAP
local BTN_Y_OFF  = 0

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

    for _, row in ipairs(mainListRows) do ftDestroyWidget(row) end
    mainListRows = {}
    mainListTimeLbls = {}

    ftDestroyWidget(mainListContent)

    local startIdx = (currentPage - 1) * ROWS_PER_PAGE + 1
    local endIdx   = math.min(startIdx + ROWS_PER_PAGE - 1, #filtered)
    local pageRows = {}
    for i = startIdx, endIdx do table.insert(pageRows, filtered[i]) end

    local contentH = math.max(1, #pageRows) * ROW_H
    mainListContent = mainWin:CreateChildWidget("emptywidget", "ft_list_content_"..rid, 0, true)
    mainListContent:SetExtent(MAIN_W - 36, contentH)
    mainListContent:RemoveAllAnchors()
    mainListContent:AddAnchor("TOPLEFT", mainWin, 18, SCROLL_Y_START)
    mainListContent:Show(true)

    if #filtered == 0 then
        local emptyLbl = mainListContent:CreateChildWidget("label", "ft_empty_lbl", 0, true)
        emptyLbl:SetText("No farms yet. Click [+ Add Land] to create one.")
        emptyLbl:SetExtent(420, 22)
        emptyLbl:AddAnchor("TOPLEFT", mainListContent, 10, 10)
        emptyLbl:SetAutoResize(false)
        ftStyleLabel(emptyLbl, FARM_UI.muted, 12, ALIGN.LEFT)
        emptyLbl:Show(true)
        return
    end

    for i, farm in ipairs(pageRows) do
        local yOff = (i - 1) * ROW_H

        local rowBg = mainListContent:CreateChildWidget("emptywidget", "ft_row_bg_"..rid.."_"..i, 0, true)
        rowBg:SetExtent(MAIN_W - 36, ROW_H - 2)
        rowBg:RemoveAllAnchors()
        rowBg:AddAnchor("TOPLEFT", mainListContent, 0, yOff)
        local rowTone = i % 2 == 0 and FARM_UI.rowEven or FARM_UI.rowOdd
        local rowShade = rowBg:CreateColorDrawable(rowTone[1], rowTone[2], rowTone[3], rowTone[4], "background")
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
            ftStyleLabel(lbl, FARM_UI.white, sz or 12, ALIGN.LEFT)
            lbl:Show(true)
            return lbl
        end
        makeRowLbl("ft_row_name_"..rid.."_"..i, fitText(farm.name or "", 32), COL_NAME_X, NAME_W, 12)
        makeRowLbl("ft_row_zone_"..rid.."_"..i, fitText(zoneName(farm.zone), 22), COL_ZONE_X, ZONE_W, 12)
        local earliestLbl = makeRowLbl("ft_row_earliest_"..rid.."_"..i, farmEarliestTime(farm), COL_EARLIEST_X, EARLIEST_W, 12)
        table.insert(mainListTimeLbls, { lbl=earliestLbl, farmId=farm.id })

        local btnOpen = rowBg:CreateChildWidget("button", "ft_row_open_"..rid.."_"..i, 0, true)
        ftPlace(btnOpen, "RIGHT", rowBg, nil, -4, BTN_Y_OFF, BTN_W, 24)
        ftStyleButton(btnOpen, "Open", FARM_UI.green)
        local capturedId = farm.id
        function btnOpen:OnClick() openDetailWindow(capturedId) end
        btnOpen:SetHandler("OnClick", btnOpen.OnClick); btnOpen:Show(true)

        local btnTrack = rowBg:CreateChildWidget("button", "ft_row_track_"..rid.."_"..i, 0, true)
        ftPlace(btnTrack, "RIGHT", rowBg, nil, -(BTN_W + GAP + 4), BTN_Y_OFF, BTN_W, 24)
        ftStyleButton(btnTrack, "Track", FARM_UI.button)
        local capturedTrackFarm = farm
        function btnTrack:OnClick() showFarmInTracker(capturedTrackFarm) end
        btnTrack:SetHandler("OnClick", btnTrack.OnClick); btnTrack:Show(true)

        local btnDel = rowBg:CreateChildWidget("button", "ft_row_del_"..rid.."_"..i, 0, true)
        ftPlace(btnDel, "RIGHT", rowBg, nil, -((BTN_W + GAP) * 2 + 4), BTN_Y_OFF, BTN_W, 24)
        ftStyleButton(btnDel, "Del", FARM_UI.red)
        local capturedIdDel = farm.id
        function btnDel:OnClick() deleteFarm(capturedIdDel); rebuildFarmList() end
        btnDel:SetHandler("OnClick", btnDel.OnClick); btnDel:Show(true)

        local btnMap = rowBg:CreateChildWidget("button", "ft_row_map_"..rid.."_"..i, 0, true)
        api.Interface:ApplyButtonSkin(btnMap, BUTTON_CONTENTS.MAP_OPEN)
        ftPlace(btnMap, "RIGHT", rowBg, nil, -(BTN_W * 3 + GAP * 3 + 4), BTN_Y_OFF, 28, 28)
        local capturedFarm = farm
        function btnMap:OnClick()
            pcall(function() api.Map:ToggleMapWithPortal(323, capturedFarm.worldX, capturedFarm.worldY, 100) end)
        end
        btnMap:SetHandler("OnClick", btnMap.OnClick); btnMap:Show(true)
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
            addAutotrackerItem(farm, info.name, isCooledTreeInfo(info) or FarmSystem._isFishInfo(info) or FarmSystem._isGamekeeperInfo(info) or FarmSystem._isDriedMineralWaterInfo(info))
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
        ftDestroyWidget(row)
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
        emptyLbl:SetExtent(420, 22)
        emptyLbl:SetAutoResize(false)
        emptyLbl:AddAnchor("TOPLEFT", landPickerWin, 28, 112)
        ftStyleLabel(emptyLbl, FARM_UI.muted, 12, ALIGN.LEFT)
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
        row:SetExtent(464, 28)
        row:RemoveAllAnchors()
        row:AddAnchor("TOPLEFT", landPickerWin, 18, 104 + ((rowIndex - 1) * 30))
        row:Show(true)
        table.insert(landPickerRows, row)

        local bg = nil
        if item.type == "zone" then
            bg = row:CreateColorDrawable(FARM_UI.header[1], FARM_UI.header[2], FARM_UI.header[3], FARM_UI.header[4], "background")
        else
            local tone = rowIndex % 2 == 0 and FARM_UI.rowEven or FARM_UI.rowOdd
            bg = row:CreateColorDrawable(tone[1], tone[2], tone[3], tone[4], "background")
        end
        bg:AddAnchor("TOPLEFT", row, 0, 0)
        bg:AddAnchor("BOTTOMRIGHT", row, 0, 0)
        bg:Show(true)

        local label = row:CreateChildWidget("label", "tt_farm_land_label_"..rid.."_"..rowIndex, 0, true)
        label:SetExtent(item.type == "zone" and 350 or 340, 28)
        label:RemoveAllAnchors()
        label:AddAnchor("LEFT", row, item.type == "zone" and 10 or 28, 0)
        ftStyleLabel(label, item.type == "zone" and FARM_UI.gold or FARM_UI.white, 12, ALIGN.LEFT)
        label:Show(true)

        local btn = row:CreateChildWidget("button", "tt_farm_land_btn_"..rid.."_"..rowIndex, 0, true)
        ftPlace(btn, "RIGHT", row, nil, -6, 0, 78, 22)
        if item.type == "zone" then
            label:SetText((landPickerExpandedZones[item.zone] and "- " or "+ ") .. item.zone .. " (" .. tostring(item.count) .. ")")
            ftStyleButton(btn, landPickerExpandedZones[item.zone] and "Collapse" or "Expand", FARM_UI.button)
            local capturedZone = item.zone
            function btn:OnClick()
                landPickerExpandedZones[capturedZone] = not landPickerExpandedZones[capturedZone]
                landPickerPage = 1
                rebuildLandPicker()
            end
        else
            label:SetText(landPickerText(item.land))
            ftStyleButton(btn, "Select", FARM_UI.green)
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
        landPickerWin = gui.CreateStyledWindow("tax_tracker_farm_land_picker", "Choose Land", 500, 400)
        landPickerWin:RemoveAllAnchors()
        landPickerWin:AddAnchor("CENTER", "UIParent", 0, 0)
        gui.CreateCategoryPanel(landPickerWin, "ft_land_picker_root", 12, 42, 476, 346, "Choose Land")
        ftAddPanel(landPickerWin, "ft_land_picker_action_panel", 18, 78, 464, 22, FARM_UI.groupDetails)
        ftAddPanel(landPickerWin, "ft_land_picker_list_panel", 18, 104, 464, 240, FARM_UI.listPanel)
        ftAddPanel(landPickerWin, "ft_land_picker_footer", 18, 352, 464, 28, FARM_UI.groupActions)
        landPickerWin:Show(false)

        function landPickerWin:OnHide()
            pendingDoodadInfo = nil
        end
        landPickerWin:SetHandler("OnHide", landPickerWin.OnHide)

        local hintLbl = landPickerWin:CreateChildWidget("label", "tt_farm_land_hint", 0, true)
        hintLbl:SetText("Attach scanned timer to:")
        hintLbl:SetExtent(180, 20)
        hintLbl:SetAutoResize(false)
        hintLbl:AddAnchor("TOPLEFT", landPickerWin, 28, 80)
        ftStyleLabel(hintLbl, FARM_UI.muted, 12, ALIGN.LEFT)
        hintLbl:Show(true)
        landPickerWin._hintLbl = hintLbl

        local btnPrev = landPickerWin:CreateChildWidget("button", "tt_farm_land_prev", 0, true)
        ftPlace(btnPrev, "BOTTOMLEFT", landPickerWin, nil, 28, -24, 72, 22)
        ftStyleButton(btnPrev, "Prev", FARM_UI.button)
        function btnPrev:OnClick()
            landPickerPage = landPickerPage - 1
            rebuildLandPicker()
        end
        btnPrev:SetHandler("OnClick", btnPrev.OnClick)
        btnPrev:Show(true)
        landPickerWin._prevBtn = btnPrev

        local pageLbl = landPickerWin:CreateChildWidget("label", "tt_farm_land_page", 0, true)
        pageLbl:SetExtent(80, 22)
        pageLbl:AddAnchor("BOTTOM", landPickerWin, 0, -24)
        pageLbl:SetText("1 / 1")
        ftStyleLabel(pageLbl, FARM_UI.muted, 12, ALIGN.CENTER)
        pageLbl:Show(true)
        landPickerWin._pageLbl = pageLbl

        local btnNext = landPickerWin:CreateChildWidget("button", "tt_farm_land_next", 0, true)
        ftPlace(btnNext, "BOTTOMRIGHT", landPickerWin, nil, -28, -24, 72, 22)
        ftStyleButton(btnNext, "Next", FARM_UI.button)
        function btnNext:OnClick()
            landPickerPage = landPickerPage + 1
            rebuildLandPicker()
        end
        btnNext:SetHandler("OnClick", btnNext.OnClick)
        btnNext:Show(true)
        landPickerWin._nextBtn = btnNext

        local btnCancel = landPickerWin:CreateChildWidget("button", "tt_farm_land_cancel", 0, true)
        ftPlace(btnCancel, "TOPRIGHT", landPickerWin, nil, -28, 78, 82, 22)
        ftStyleButton(btnCancel, "Cancel", FARM_UI.button)
        function btnCancel:OnClick() closeLandPickerWindow(true) end
        btnCancel:SetHandler("OnClick", btnCancel.OnClick)
        btnCancel:Show(true)

        local btnPlayerLocation = landPickerWin:CreateChildWidget("button", "tt_farm_land_player_location", 0, true)
        ftPlace(btnPlayerLocation, "TOPRIGHT", landPickerWin, nil, -118, 78, 160, 22)
        ftStyleButton(btnPlayerLocation, "Use Player Location", FARM_UI.buttonBlue)
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

    mainWin = gui.CreateStyledWindow("tax_tracker_farm_main", "Farm Tracker", MAIN_W, MAIN_H)
    mainWin:RemoveAllAnchors()
    mainWin:AddAnchor("CENTER", "UIParent", 0, 0)
    gui.CreateCategoryPanel(mainWin, "ft_main_root", 12, 42, MAIN_W - 24, 384, "Farms")
    ftAddPanel(mainWin, "ft_main_header_panel", 18, 72, MAIN_W - 36, 28, FARM_UI.header)
    ftAddPanel(mainWin, "ft_main_list_panel", 18, 106, MAIN_W - 36, 316, FARM_UI.listPanel)
    ftAddPanel(mainWin, "ft_main_actions_panel", 18, MAIN_H - 58, MAIN_W - 36, 34, FARM_UI.groupActions)
    mainWin:Show(false)

    function mainWin:OnHide()
        closeLandPickerWindow(true)
    end
    mainWin:SetHandler("OnHide", mainWin.OnHide)

    local hdrBar = mainWin:CreateChildWidget("emptywidget", "ft_hdr_bar", 0, true)
    hdrBar:SetExtent(MAIN_W - 36, 28)
    hdrBar:RemoveAllAnchors()
    hdrBar:AddAnchor("TOPLEFT", mainWin, 18, 72)
    ftAddDrawable(hdrBar, FARM_UI.header)
    hdrBar:Show(true)

    local function makeHdrLabel(name, txt, xOff, w)
        local lbl = hdrBar:CreateChildWidget("textbox", name, 0, true)
        lbl:SetExtent(w, 28)
        lbl:RemoveAllAnchors()
        lbl:AddAnchor("LEFT", hdrBar, xOff, 0)
        lbl:SetText(txt)
        if lbl.style then lbl.style:SetAlign(ALIGN.LEFT); lbl.style:SetFontSize(FONT_SIZE.LARGE or 18) end
        ftStyleLabel(lbl, FARM_UI.gold, 12, ALIGN.LEFT)
        lbl:Show(true)
    end
    makeHdrLabel("ft_hdr_name", "Farm Name",   COL_NAME_X, NAME_W)
    makeHdrLabel("ft_hdr_zone", "Zone",        COL_ZONE_X, ZONE_W)
    makeHdrLabel("ft_hdr_earliest", "Earliest End", COL_EARLIEST_X, EARLIEST_W)

    -- Add Land button
    local btnAdd = mainWin:CreateChildWidget("button", "ft_btn_add_farm", 0, true)
    ftPlace(btnAdd, "BOTTOMRIGHT", mainWin, nil, -18, -29, 94, 26)
    ftStyleButton(btnAdd, "+ Add Land", FARM_UI.green)
    function btnAdd:OnClick() openAddFarmPopup() end
    btnAdd:SetHandler("OnClick", btnAdd.OnClick); btnAdd:Show(true)

    -- Pagination
    local pageCtrl = W_CTRL.CreatePageControl("ft_pagectrl", mainWin, "tutorial")
    pageCtrl:RemoveAllAnchors()
    pageCtrl:AddAnchor("BOTTOM", mainWin, 0, -29)
    function pageCtrl:ProcOnPageChanged(pageIndex)
        currentPage = pageIndex
        rebuildFarmList()
    end
    pageCtrl:Show(true)
    mainWin._pageCtrl = pageCtrl

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

    -- Always create the actions bar — it hosts the always-visible Arise button
    -- plus whichever toggle-driven buttons are enabled. Slight delay to let
    -- HUDManager finish creating its standalone Arise so suppressStandaloneArise
    -- has something to hide.
    api:DoIn(250, function() pcall(FarmSystem.floatActions.create) end)

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

    if FarmSystem.floatActions and FarmSystem.floatActions.destroy then
        pcall(FarmSystem.floatActions.destroy)
    end
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
