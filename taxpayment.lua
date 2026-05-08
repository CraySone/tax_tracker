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

-- Recognized cert types. Both regular and bound certs can be used to pay tax,
-- so auto-detect needs to accept either. Table form makes adding more variants
-- (e.g. event-specific certs) a one-line change.
local TAX_CERT_IDS = {
  ["31891"] = true,  -- Tax Certificate
  ["31892"] = true,  -- Bound Tax Certificate
}
local TAX_CERT_NAMES = {
  ["Tax Certificate"] = true,
  ["Bound Tax Certificate"] = true,
}

local POPUP_UI = {
  WHITE = {1, 1, 1, 1},
  MUTED = {0.72, 0.72, 0.72, 1},
  GOLD = {1, 0.84, 0, 1},
  BUTTON = {0.11, 0.11, 0.13, 0.92},
  PANEL = {0.05, 0.05, 0.06, 0.62},
  LIST_PANEL = {0.05, 0.05, 0.06, 0.38},
  HEADER = {0.09, 0.09, 0.11, 0.95},
  ROW_ODD = {0.08, 0.08, 0.095, 0.72},
  ROW_EVEN = {0.12, 0.12, 0.135, 0.72}
}

local function setTextColor(widget, color)
  if widget and widget.style and widget.style.SetColor and color then
    widget.style:SetColor(color[1], color[2], color[3], color[4] or 1)
  end
end

local function setDrawableColor(drawable, color)
  if drawable and drawable.SetColor and color then
    drawable:SetColor(color[1], color[2], color[3], color[4] or 0.92)
  end
end

local function clearAnchors(widget)
  if widget and widget.RemoveAllAnchors then
    pcall(function() widget:RemoveAllAnchors() end)
  end
end

local function addPanel(parent, id, x, y, width, height, color)
  if not (parent and parent.CreateChildWidget) then return nil end
  local c = color or POPUP_UI.PANEL
  local panel = parent:CreateChildWidget("emptywidget", id, 0, true)
  panel:SetExtent(width, height)
  panel:AddAnchor("TOPLEFT", parent, x, y)
  if panel.EnableMouse then panel:EnableMouse(false) end
  if panel.CreateColorDrawable then
    local bg = panel:CreateColorDrawable(c[1], c[2], c[3], c[4], "background")
    bg:AddAnchor("TOPLEFT", panel, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", panel, 0, 0)
    bg:Show(true)
    panel.cleanBg = bg
  end
  panel:Show(true)
  return panel
end

local function styleFlatButton(button, text, tone)
  if not button then return end
  local width = 120
  local height = 26
  pcall(function()
    if button.GetWidth and button:GetWidth() and button:GetWidth() > 0 then width = button:GetWidth() end
    if button.GetHeight and button:GetHeight() and button:GetHeight() > 0 then height = button:GetHeight() end
  end)

  if button.SetText then button:SetText("") end

  if not button.cleanBg and button.CreateColorDrawable then
    local c = tone or POPUP_UI.BUTTON
    local bg = button:CreateColorDrawable(c[1], c[2], c[3], c[4], "background")
    bg:AddAnchor("TOPLEFT", button, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", button, 0, 0)
    bg:Show(true)
    button.cleanBg = bg
  end

  if not button.cleanLabel then
    local label = button:CreateChildWidget("label", "cleanLabel", 0, true)
    label:AddAnchor("TOPLEFT", button, 0, 1)
    label:SetExtent(width, math.max(1, height - 2))
    if label.style then
      label.style:SetFontSize(11)
      if label.style.SetAlign then label.style:SetAlign(ALIGN.CENTER) end
    end
    if label.EnablePick then label:EnablePick(false) end
    label:Show(true)
    button.cleanLabel = label
  end

  if button.cleanLabel then
    clearAnchors(button.cleanLabel)
    button.cleanLabel:SetExtent(width, math.max(1, height - 2))
    button.cleanLabel:AddAnchor("TOPLEFT", button, 0, 1)
    button.cleanLabel:SetText(text or "")
    setTextColor(button.cleanLabel, POPUP_UI.WHITE)
  end
  setDrawableColor(button.cleanBg, tone or POPUP_UI.BUTTON)

  function button:SetCleanText(nextText)
    if self.cleanLabel then self.cleanLabel:SetText(nextText or "") end
    if self.SetText then self:SetText("") end
  end
end

local function fitText(value, maxLen)
  local text = tostring(value or "")
  if maxLen and maxLen > 3 and string.len(text) > maxLen then
    return string.sub(text, 1, maxLen - 3) .. "..."
  end
  return text
end

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

-- Create the disambiguation window once and reuse it. Same idempotent pattern
-- as farmsystem's landPickerWin / doodadListener: module-level locals survive
-- /reload in this engine, so guarding on `disambigWin` prevents stacking
-- duplicate windows. Destroy-and-recreate doesn't work reliably here.
local function createDisambigWindow()
  if not disambigWin then
    disambigWin = api.Interface:CreateWindow("TaxPaymentDisambig", "Tax Payment Detected", 0, 0)
    disambigWin:AddAnchor("CENTER", "UIParent", 0, -100)
    disambigWin:Show(false)
  end

  if disambigWin._taxPopupStyleVersion == 1 then return end

  disambigWin:SetExtent(460, 150)

  if not disambigWin._rootPanel then
    disambigWin._rootPanel = addPanel(disambigWin, "taxPopupRootPanel", 12, 40, 436, 96, POPUP_UI.PANEL)
  end
  if not disambigWin._headerPanel then
    disambigWin._headerPanel = addPanel(disambigWin, "taxPopupHeaderPanel", 18, 46, 424, 28, POPUP_UI.HEADER)
  end
  if not disambigWin._listPanel then
    disambigWin._listPanel = addPanel(disambigWin, "taxPopupListPanel", 18, 110, 424, 28, POPUP_UI.LIST_PANEL)
  end

  if not disambigWin._titleLabel then
    local title = disambigWin:CreateChildWidget("label", "taxPopupTitle", 0, true)
    title:SetText("Tax Payment Detected")
    title:SetExtent(250, 24)
    title:AddAnchor("TOPLEFT", disambigWin, 30, 50)
    if title.style then
      title.style:SetFontSize(13)
      if title.style.SetAlign then title.style:SetAlign(ALIGN.LEFT) end
    end
    setTextColor(title, POPUP_UI.GOLD)
    title:Show(true)
    disambigWin._titleLabel = title
  end

  if not disambigLabel then
    disambigLabel = disambigWin:CreateChildWidget("textbox", "disambigLabel", 0, true)
  end
  clearAnchors(disambigLabel)
  disambigLabel:SetExtent(404, 34)
  disambigLabel:AddAnchor("TOPLEFT", disambigWin, 30, 78)
  if disambigLabel.style then
    disambigLabel.style:SetAlign(ALIGN.LEFT)
    disambigLabel.style:SetFontSize(FONT_SIZE.MIDDLE)
  end
  setTextColor(disambigLabel, POPUP_UI.MUTED)
  disambigLabel:SetText("")
  disambigWin._taxPopupStyleVersion = 1
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
    "%d Tax Certificates consumed.\nChoose the land to mark as paid.", certCount))

  -- Create a button for each matching land
  local yOffset = 116
  for idx, land in ipairs(matches) do
    local landName = fitText(land.name or "Land #" .. tostring(land.id or idx), 34)
    local zoneName = fitText(land.zone or land.zoneName or "Unknown zone", 22)
    local btnText = string.format("%s  |  %s", landName, zoneName)
    local btn = disambigWin:CreateChildWidget("button", "disambig_" .. idx, 0, true)
    btn:SetExtent(424, 26)
    btn:AddAnchor("TOPLEFT", disambigWin, 18, yOffset)
    styleFlatButton(btn, btnText, idx % 2 == 0 and POPUP_UI.ROW_EVEN or POPUP_UI.ROW_ODD)
    yOffset = yOffset + 30

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
  dismissBtn:SetExtent(424, 26)
  dismissBtn:AddAnchor("TOPLEFT", disambigWin, 18, yOffset + 4)
  styleFlatButton(dismissBtn, "Not a tax payment", POPUP_UI.BUTTON)
  yOffset = yOffset + 36
  function dismissBtn:OnClick()
    disambigWin:Show(false)
    clearDisambigButtons()
  end
  dismissBtn:SetHandler("OnClick", dismissBtn.OnClick)
  dismissBtn:Show(true)
  table.insert(disambigButtons, dismissBtn)

  -- Resize window to fit all buttons
  local windowHeight = yOffset + 18
  disambigWin:SetExtent(460, windowHeight)
  if disambigWin._rootPanel then disambigWin._rootPanel:SetExtent(436, windowHeight - 52) end
  if disambigWin._listPanel then disambigWin._listPanel:SetExtent(424, math.max(28, windowHeight - 124)) end
  disambigWin:Show(true)
end

-- ==================== EVENT HANDLING ====================

-- Process REMOVED_ITEM event
local function processRemovedItem(itemLinkText, itemCount, removeState, itemTaskType, tradeOtherName)
  local itemId = itemIdFromItemLinkText(itemLinkText)
  if not itemId then return end

  -- Check if this is a recognized Tax Certificate variant (regular or bound).
  local isTaxCert = TAX_CERT_IDS[itemId] or false
  if not isTaxCert then
    local itemName = getItemName(itemId)
    if itemName and TAX_CERT_NAMES[itemName] then isTaxCert = true end
  end
  if not isTaxCert then return end

  local count = tonumber(itemCount) or 0
  if count <= 0 then return end

  local matches = findMatchingLands(count)
  if #matches == 0 then
    return
  elseif #matches == 1 then
    markLandPaid(matches[1])
  else
    showDisambigPopup(matches, count)
  end
end

-- ==================== LIFECYCLE ====================

function TaxPayment.initialize(lands)
  landsData = lands

  -- Stale-listener guard via a session counter on disk.
  --
  -- We can't use api.On/api.Off for REMOVED_ITEM (it's a widget event, not
  -- an api event), and module-level locals don't reliably persist across
  -- /reload, so every reload leaves a new widget listener subscribed to
  -- REMOVED_ITEM with no way to unregister the previous ones. After N
  -- reloads, N listeners fire on every payment → N popups.
  --
  -- The fix: bump a counter in addon settings (which DO survive reload),
  -- capture the value as `mySession` at registration time, and have each
  -- listener compare its captured value against the current value before
  -- doing any work. Only the most recent load matches → orphan listeners
  -- become deaf even though they still fire.
  local settings = api.GetSettings("tax_tracker") or {}
  settings.taxListenerSession = (settings.taxListenerSession or 0) + 1
  pcall(function() api.SaveSettings() end)
  local mySession = settings.taxListenerSession

  local success, eventWnd = pcall(function()
    return api.Interface:CreateEmptyWindow("taxPaymentEventWnd")
  end)
  if success and eventWnd then
    eventWindow = eventWnd

    function eventWindow:OnEvent(event, ...)
      local cur = api.GetSettings("tax_tracker") or {}
      if (cur.taxListenerSession or 0) ~= mySession then return end
      if event == "REMOVED_ITEM" then
        local arg = {...}
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
  -- Hide the popup if it's open, but DO NOT nil disambigWin/disambigLabel/
  -- eventWindow. They're module-level locals that survive /reload, and the
  -- initialize() guards (`if not eventWindow then`) rely on them being
  -- non-nil so we don't recreate duplicates. Same pattern as
  -- farmsystem.doodadListener.
  clearDisambigButtons()
  if disambigWin and disambigWin.Show then
    pcall(function() disambigWin:Show(false) end)
  end

  -- Stop the listener firing while we're unloaded; initialize() will rebind.
  if eventWindow then
    pcall(function() eventWindow:UnregisterEvent("REMOVED_ITEM") end)
  end
end

return TaxPayment
