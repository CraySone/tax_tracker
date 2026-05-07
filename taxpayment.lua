-- tax_tracker/taxpayment.lua - Auto-detect tax payment from inventory events
-- Listens for REMOVED_ITEM event when Tax Certificates are consumed
-- Matches count to saved lands and auto-marks as paid

local api = require("api")
local TimeSystem = require("tax_tracker/timesystem")

-- Safe Debug loading
local Debug = nil
pcall(function() Debug = require("tax_tracker/debug") end)
if not Debug then
  Debug = { info = function() end, warn = function() end, error = function() end, debug = function() end, trace = function() end }
end

local TaxPayment = {}

-- State
local landsData = nil       -- Reference to the saved lands list from main.lua
local eventWindow = nil      -- Event listener window
local disambigWin = nil      -- Disambiguation popup for multiple matches
local disambigLabel = nil
local disambigButtons = {}
local pendingMatches = nil   -- Lands matching a recent tax payment
local pendingCount = 0       -- How many certs were consumed

-- Tax Certificate item ID (from auction house data)
local TAX_CERT_ID = "31891"
local TAX_CERT_NAME = "Tax Certificate"

-- Extract item ID from itemLinkText (same pattern as farmsystem.lua)
local function itemIdFromItemLinkText(itemLinkText)
  if not itemLinkText or type(itemLinkText) ~= "string" then return nil end
  local itemIdStr = itemLinkText:sub(3)
  local parts = {}
  for part in itemIdStr:gmatch("[^,]+") do
    table.insert(parts, part)
  end
  return parts[1]
end

-- Get item name from item ID
local function getItemName(itemId)
  if not itemId then return nil end
  local itemInfo = nil
  pcall(function()
    itemInfo = api.Item:GetItemInfoByType(tonumber(itemId))
  end)
  return itemInfo and itemInfo.name or nil
end

-- Find lands that match a given tax certificate count AND need payment.
-- "Need payment" means either: nextPayment timer says overdue, OR no timer
-- exists yet (a new land that's never been marked paid). Lands with a
-- running countdown are skipped — paying again would be a double-pay and
-- the user almost certainly didn't mean that one.
local function findMatchingLands(certCount)
  if not landsData or not certCount or certCount <= 0 then return {} end

  local matches = {}
  for _, land in ipairs(landsData) do
    if land.tax and tonumber(land.tax) == certCount then
      local needsPayment = (land.nextPayment == nil) or TimeSystem.isOverdue(land.nextPayment)
      if needsPayment then
        table.insert(matches, land)
      end
    end
  end
  return matches
end

-- Mark a specific land as paid (replicates landtable.lua Paid button logic)
local function markLandPaid(land)
  if not land then return end


  -- Update payment timer (same as Paid button in landtable.lua)
  land.nextPayment = TimeSystem.markPaid(land.nextPayment)
  land.isOverdue = TimeSystem.isOverdue(land.nextPayment)

  -- Save to settings
  pcall(function()
    local settings = api.GetSettings("tax_tracker") or {}
    if settings.lands then
      for i, savedLand in ipairs(settings.lands) do
        if savedLand.id == land.id then
          settings.lands[i] = land
          break
        end
      end
    end
    api.SaveSettings()
  end)

  -- Refresh the saved lands window if visible
  pcall(function()
    local SavedLandsWindow = require("tax_tracker/ui/savedlandswindow")
    if SavedLandsWindow and SavedLandsWindow.refreshData then
      SavedLandsWindow.refreshData()
    end
  end)

  api.Log:Info(string.format("[Tax Tracker] Auto-paid: %s (%d certs)",
    land.name or "Unknown", land.tax or 0))
end

-- ==================== DISAMBIGUATION POPUP ====================

-- Properly destroy a widget instead of just hiding it. Hidden widgets keep
-- their anchors and the engine reuses cached widgets when CreateChildWidget
-- is called with the same ID, leaving a stack of ghost popups visible.
local function destroyWidget(w)
  if not w then return end
  pcall(function()
    if w.Show then w:Show(false) end
    if w.RemoveAllAnchors then w:RemoveAllAnchors() end
    if w.Destroy then w:Destroy() end
  end)
end

local function clearDisambigButtons()
  for _, btn in ipairs(disambigButtons) do
    destroyWidget(btn)
  end
  disambigButtons = {}
end

-- Destroy ALL orphans with this name, not just one. Multiple addon
-- reloads (especially before this cleanup logic existed) can leave
-- several widgets sharing the same name alive in the engine. The most
-- damaging case is the event window: every orphan stays subscribed to
-- REMOVED_ITEM and runs its own popup logic, so paying once produces
-- N popups. FindWidget returns one at a time, so we loop until none
-- remain. The 50-iteration cap is just a sanity guard against an
-- engine that returns the same widget without releasing it.
local function destroyOrphanByName(name)
  if not (api.Interface and api.Interface.FindWidget) then return end
  for _ = 1, 50 do
    local ok, widget = pcall(api.Interface.FindWidget, api.Interface, name)
    if not (ok and widget) then return end
    destroyWidget(widget)
  end
end

-- Create the disambiguation window (once, reuse)
local function createDisambigWindow()
  -- ALWAYS destroy any existing orphan first
  destroyOrphanByName("TaxPaymentDisambig")
  disambigWin = nil

  disambigWin = api.Interface:CreateWindow("TaxPaymentDisambig", "Tax Payment Detected", 0, 0)
  disambigWin:SetExtent(400, 100) -- Will be resized based on number of matches
  disambigWin:AddAnchor("CENTER", "UIParent", 0, -100)
  disambigWin:Show(false)

  -- Message label
  disambigLabel = disambigWin:CreateChildWidget("textbox", "disambigLabel", 0, true)
  disambigLabel:SetExtent(360, FONT_SIZE.LARGE * 2)
  disambigLabel:AddAnchor("TOPLEFT", disambigWin, 20, 42)
  if disambigLabel.style then
    disambigLabel.style:SetAlign(ALIGN.LEFT)
    disambigLabel.style:SetFontSize(FONT_SIZE.MIDDLE)
  end
  pcall(function() ApplyTextColor(disambigLabel, FONT_COLOR.DEFAULT) end)
  disambigLabel:SetText("")
end

-- Show disambiguation popup with land choices
local function showDisambigPopup(matches, certCount)
  -- Hide existing popup if open
  if disambigWin and disambigWin.Show then
    disambigWin:Show(false)
  end
  
  createDisambigWindow()
  clearDisambigButtons()

  pendingMatches = matches
  pendingCount = certCount

  disambigLabel:SetText(string.format(
    "%d Tax Certificates consumed.\nWhich property did you pay for?", certCount))

  -- Create a button for each matching land
  local yOffset = 80
  for idx, land in ipairs(matches) do
    local btnText = string.format("%s (%s)", land.name or "Land #" .. land.id, land.zone or land.zoneName or "")
    local btn = disambigWin:CreateChildWidget("button", "disambig_" .. idx, 0, true)
    api.Interface:ApplyButtonSkin(btn, BUTTON_BASIC.DEFAULT)
    btn:SetText(btnText)
    btn:SetExtent(360, 28)
    btn:AddAnchor("TOPLEFT", disambigWin, 20, yOffset)
    yOffset = yOffset + 34

    btn.landRef = land
    function btn:OnClick()
      markLandPaid(self.landRef)
      disambigWin:Show(false)
      clearDisambigButtons()
    end
    btn:SetHandler("OnClick", btn.OnClick)
    btn:Show(true)
    table.insert(disambigButtons, btn)
  end

  -- "Not a tax payment" dismiss button
  local dismissBtn = disambigWin:CreateChildWidget("button", "disambig_dismiss", 0, true)
  api.Interface:ApplyButtonSkin(dismissBtn, BUTTON_BASIC.DEFAULT)
  dismissBtn:SetText("Not a tax payment")
  dismissBtn:SetExtent(360, 28)
  dismissBtn:AddAnchor("TOPLEFT", disambigWin, 20, yOffset)
  yOffset = yOffset + 34
  function dismissBtn:OnClick()
    disambigWin:Show(false)
    clearDisambigButtons()
  end
  dismissBtn:SetHandler("OnClick", dismissBtn.OnClick)
  dismissBtn:Show(true)
  table.insert(disambigButtons, dismissBtn)

  -- Resize window to fit all buttons
  disambigWin:SetExtent(400, yOffset + 10)
  disambigWin:Show(true)
end

-- ==================== EVENT HANDLING ====================

-- Process REMOVED_ITEM event
local function processRemovedItem(itemLinkText, itemCount, removeState, itemTaskType, tradeOtherName)
  local itemId = itemIdFromItemLinkText(itemLinkText)
  if not itemId then return end

  -- Check if this is a Tax Certificate by item ID or name
  local isTaxCert = false
  if itemId == TAX_CERT_ID then
    isTaxCert = true
  else
    -- Fallback: check by name
    local itemName = getItemName(itemId)
    if itemName and itemName == TAX_CERT_NAME then
      isTaxCert = true
    end
  end

  if not isTaxCert then return end

  local count = tonumber(itemCount) or 0
  if count <= 0 then return end


  -- Find matching lands
  local matches = findMatchingLands(count)

  if #matches == 0 then
    -- No matching lands - might be trading/selling certs, ignore
    return
  elseif #matches == 1 then
    -- Exactly one match - auto-mark as paid
    markLandPaid(matches[1])
  else
    -- Multiple matches - show disambiguation popup
    showDisambigPopup(matches, count)
  end
end

-- ==================== LIFECYCLE ====================

function TaxPayment.initialize(lands)
  landsData = lands

  -- A previous load may have left an event window with this name still
  -- registered for REMOVED_ITEM. Without destroying it, both the old and
  -- new windows would receive every event, double-firing the popup.
  destroyOrphanByName("taxPaymentEventWnd")

  local success, eventWnd = pcall(function()
    return api.Interface:CreateEmptyWindow("taxPaymentEventWnd")
  end)

  if success and eventWnd then
    eventWindow = eventWnd

    function eventWindow:OnEvent(event, ...)
      local arg = {...}
      if event == "REMOVED_ITEM" then
        pcall(processRemovedItem, arg[1], arg[2], arg[3], arg[4], arg[5])
      end
    end

    eventWindow:SetHandler("OnEvent", eventWindow.OnEvent)
    eventWindow:RegisterEvent("REMOVED_ITEM")
    eventWindow:Show(true)
  end

  return true
end

-- Update lands reference (if main.lua reloads data)
function TaxPayment.updateLandsData(lands)
  landsData = lands
end

function TaxPayment.cleanup()
  clearDisambigButtons()
  destroyWidget(disambigWin)
  destroyWidget(eventWindow)
  disambigWin = nil
  disambigLabel = nil
  eventWindow = nil
  
  -- Force destroy any remaining orphans
  destroyOrphanByName("TaxPaymentDisambig")
  destroyOrphanByName("taxPaymentEventWnd")
end

return TaxPayment
