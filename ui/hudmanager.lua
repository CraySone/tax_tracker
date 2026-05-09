-- tax_tracker/ui/hudmanager.lua - HUD Button Management
local api = require("api")
-- Use Debug safely to avoid circular dependencies
local Debug = nil
pcall(function() Debug = require("tax_tracker/debug") end)
if not Debug then
  Debug = { info = function() end, warn = function() end, error = function() end, debug = function() end, trace = function() end }
end

local HUDManager = {}

-- HUD state - SINGLETON PATTERN
local hudRoot = nil
local hudBtn = nil
local isInitialized = false
local currentCallback = nil

local HUD_W = 112
local HUD_H = 30
local REGISTRY_KEY = "__TAX_TRACKER_ARISE_HUD"
local fallbackRegistry = nil

local function getRegistry()
  if type(_G) == "table" then
    _G[REGISTRY_KEY] = _G[REGISTRY_KEY] or {}
    return _G[REGISTRY_KEY]
  end
  fallbackRegistry = fallbackRegistry or {}
  return fallbackRegistry
end

local function loadHudPosition()
  local settings = api.GetSettings("tax_tracker") or {}
  local x = settings.hudX
  local y = settings.hudY

  -- Older versions stored this as a TOPRIGHT offset, usually negative.
  -- Use a stable TOPLEFT position now so dragged locations survive reloads.
  if type(x) ~= "number" or type(y) ~= "number" then
    return 970, 10
  end
  if x < 0 then
    x = 970
  end
  if y < 0 then
    y = 10
  end
  if x > 2500 or y > 1600 then
    return 970, 10
  end

  return x, y
end

local function saveHudPosition(x, y)
  local settings = api.GetSettings("tax_tracker") or {}
  if type(x) == "number" and type(y) == "number" then
    settings.hudX = x
    settings.hudY = y
  end
  pcall(function() api.SaveSettings() end)
end

local function isShiftDown()
  local ok, down = pcall(function()
    return api.Input and api.Input:IsShiftKeyDown()
  end)
  return ok and down
end

local function hideAndDestroy(widget)
  if not widget then return false end
  pcall(function()
    if widget.Show then widget:Show(false) end
    if widget.Enable then widget:Enable(false) end
  end)
  if widget.Destroy then
    pcall(function() widget:Destroy() end)
  end
  return true
end

local function destroyNamedWidget(name)
  local destroyed = false
  for _, fn in ipairs({"FindWidget", "GetWindow", "GetWidgetByName"}) do
    local f = api.Interface and api.Interface[fn]
    if f then
      local ok, w = pcall(function() return f(api.Interface, name) end)
      if ok and w then
        hideAndDestroy(w)
        destroyed = true
      end
    end
  end
  return destroyed
end

local function cleanupStaleWidgets()
  local registry = getRegistry()
  hideAndDestroy(registry.btn)
  hideAndDestroy(registry.root)
  registry.btn = nil
  registry.root = nil

  local possibleNames = {"TaxTrackerHUDRoot", "hudToggleBtn", "TaxTrackerHUD", "TaxTrackerButton", "TaxTracker", "tax_tracker_hud"}
  for _ = 1, 5 do
    local destroyedAny = false
    for _, name in ipairs(possibleNames) do
      if destroyNamedWidget(name) then
        destroyedAny = true
        Debug.info("HUDManager", "Destroyed stale widget: " .. name)
      end
    end
    if not destroyedAny then return end
  end
end

-- Initialize HUD Manager - ROBUST SINGLETON IMPLEMENTATION
function HUDManager.initialize(toggleCallback)
  -- STRICT SINGLETON: Only allow one initialization
  if isInitialized and hudRoot and hudRoot.Show and hudBtn and hudBtn.SetHandler then
    Debug.info("HUDManager", "HUD already initialized and functional")
    
    -- Update callback if needed
    if toggleCallback and toggleCallback ~= currentCallback then
      currentCallback = toggleCallback
      hudBtn:SetHandler("OnClick", function()
        Debug.info("HUDManager", "HUD button clicked")
        currentCallback()
      end)
      Debug.info("HUDManager", "HUD callback updated")
    end
    return true
  end
  
  Debug.info("HUDManager", "Performing first-time HUD initialization")
  
  -- FORCE CLEANUP: Ensure no existing widgets from a previous reload remain.
  pcall(function() HUDManager.cleanup() end)
  
  local success, result = pcall(function()
    pcall(cleanupStaleWidgets)

    hudRoot = api.Interface:CreateEmptyWindow("TaxTrackerHUDRoot", "UIParent")
    hudRoot:SetExtent(HUD_W, HUD_H)
    local hudX, hudY = loadHudPosition()
    hudRoot:AddAnchor("TOPLEFT", "UIParent", "TOPLEFT", hudX, hudY)

    hudBtn  = hudRoot:CreateChildWidget("button", "hudToggleBtn", 0, true)
    local registry = getRegistry()
    registry.root = hudRoot
    registry.btn = hudBtn
    
    Debug.info("HUDManager", "Created HUD widgets", {hudRoot = hudRoot ~= nil, hudBtn = hudBtn ~= nil})

    hudBtn:SetExtent(HUD_W, HUD_H)
    hudBtn:SetText("")
    hudBtn._bg = hudBtn:CreateColorDrawable(0.11, 0.11, 0.13, 0.92, "background")
    hudBtn._bg:AddAnchor("TOPLEFT", hudBtn, 0, 0)
    hudBtn._bg:AddAnchor("BOTTOMRIGHT", hudBtn, 0, 0)
    hudBtn._bg:Show(true)
    hudBtn._label = hudBtn:CreateChildWidget("label", "hudToggleBtnLabel", 0, true)
    hudBtn._label:SetText("Arise")
    hudBtn._label:SetExtent(HUD_W, HUD_H - 2)
    hudBtn._label:AddAnchor("TOPLEFT", hudBtn, 0, 1)
    if hudBtn._label.style then
      if hudBtn._label.style.SetFontSize then hudBtn._label.style:SetFontSize(12) end
      if hudBtn._label.style.SetAlign then hudBtn._label.style:SetAlign(ALIGN.CENTER) end
      if hudBtn._label.style.SetColor then hudBtn._label.style:SetColor(1, 1, 1, 1) end
    end
    if hudBtn._label.EnablePick then hudBtn._label:EnablePick(false) end
    hudBtn._label:Show(true)
    hudBtn:AddAnchor("TOPLEFT", hudRoot, "TOPLEFT", 0, 0)
    if hudBtn.EnableDrag then hudBtn:EnableDrag(true) end
    function hudBtn:OnDragStart()
      if not isShiftDown() then
        if api.Cursor and api.Cursor.ClearCursor then api.Cursor:ClearCursor() end
        return
      end
      hudRoot._shiftDragging = true
      if hudRoot and hudRoot.StartMoving then hudRoot:StartMoving() end
      if api.Cursor and api.Cursor.ClearCursor then api.Cursor:ClearCursor() end
    end
    hudBtn:SetHandler("OnDragStart", hudBtn.OnDragStart)
    function hudBtn:OnDragStop()
      if not (hudRoot and hudRoot._shiftDragging) then
        if api.Cursor and api.Cursor.ClearCursor then api.Cursor:ClearCursor() end
        return
      end
      hudRoot._shiftDragging = false
      if hudRoot and hudRoot.StopMovingOrSizing then hudRoot:StopMovingOrSizing() end
      if hudRoot and hudRoot.GetEffectiveOffset then
        local x, y = hudRoot:GetEffectiveOffset()
        saveHudPosition(x, y)
      end
      if api.Cursor and api.Cursor.ClearCursor then api.Cursor:ClearCursor() end
    end
    hudBtn:SetHandler("OnDragStop", hudBtn.OnDragStop)
    
    -- Ensure button is visible
    hudBtn:Show(true)
    hudBtn:Enable(true)
    Debug.info("HUDManager", "HUD button configured", {text = "Arise"})

    -- Set click handler if provided
    if toggleCallback then
      currentCallback = toggleCallback
      hudBtn:SetHandler("OnClick", function()
        Debug.info("HUDManager", "HUD button clicked")
        currentCallback()
      end)
    end

    hudRoot:Show(true)
    
    -- MARK AS INITIALIZED
    isInitialized = true
    Debug.info("HUDManager", "HUD button created successfully - singleton initialized")
    return true
  end)
  
  if not success then
    Debug.error("HUDManager", "Failed to create HUD button", {error = result})
    return false
  end
  
  return true
end

-- Show/Hide HUD
function HUDManager.show()
  if hudRoot then
    hudRoot:Show(true)
  end
end

function HUDManager.hide()
  if hudRoot then
    hudRoot:Show(false)
  end
end

-- Get HUD visibility
function HUDManager.isVisible()
  return hudRoot and hudRoot:IsVisible() or false
end

-- Invoke the toggle callback registered at initialize() time. Lets external
-- callers (e.g. the FarmSystem actions bar) trigger the same "open saved
-- lands window" action that clicking the standalone Arise button would.
function HUDManager.invokeToggle()
  if currentCallback then
    pcall(currentCallback)
  end
end

-- Cleanup - RESET SINGLETON STATE
function HUDManager.cleanup()
  hideAndDestroy(hudBtn)
  hideAndDestroy(hudRoot)
  hudRoot = nil
  hudBtn = nil
  currentCallback = nil
  isInitialized = false -- RESET SINGLETON FLAG
  
  pcall(cleanupStaleWidgets)
  
  Debug.info("HUDManager", "HUD cleaned up - singleton reset")
end

return HUDManager
