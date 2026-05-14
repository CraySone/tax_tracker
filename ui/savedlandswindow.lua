-- tax_tracker/ui/savedlandswindow.lua - Saved Lands List Window (matches original layout)
local api = require("api")
local Debug = require("tax_tracker/debug")
local gui = require("tax_tracker/gui")
local TimeSystem = require("tax_tracker/timesystem")
local HybridList = require("tax_tracker/ui/hybrid_list")
local UIManager = nil -- Lazy load to avoid circular dependency

local SavedLandsWindow = {}

-- Window state
local listWin = nil
local itemList = nil
local ownedLabel = nil
local bulkHostileWin = nil
local bulkHostileRows = {}
local bulkHostilePage = 1
-- Bumped on every rebuild and baked into per-row widget names. CreateChildWidget
-- with a stable name returns the engine's cached widget, which carries stale
-- anchors and extents and made OFF buttons render at varying widths row-to-row.
-- Unique names per rebuild guarantee fresh widgets with clean anchors.
local bulkHostileRebuildSeq = 0
local BULK_HOSTILE_ROWS = 9
local BULK_HOSTILE_RIGHT_MARGIN = 12
local BULK_HOSTILE_BUTTON_GAP = 6
local BULK_HOSTILE_ON_WIDTH = 82
local BULK_HOSTILE_OFF_WIDTH = 52
local BULK_HOSTILE_TERR_ON_WIDTH = 72
local BULK_HOSTILE_LABEL_WIDTH = 345

local UI = {
  white = {1, 1, 1, 1},
  muted = {0.72, 0.72, 0.72, 1},
  gold = {1, 0.84, 0, 1},
  green = {0.12, 0.28, 0.15, 0.95},
  red = {0.24, 0.09, 0.09, 0.95},
  button = {0.11, 0.11, 0.13, 0.92},
  panel = {0.05, 0.05, 0.06, 0.64},
  listPanel = {0.05, 0.05, 0.06, 0.36},
  header = {0.09, 0.09, 0.11, 0.95},
  groupDetails = {0.07, 0.07, 0.08, 0.74},
  groupStatus = {0.065, 0.065, 0.075, 0.74},
  rowOdd = {0.08, 0.08, 0.095, 0.72},
  rowEven = {0.12, 0.12, 0.135, 0.72}
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

local function destroyWidget(widget)
  if not widget then return end
  pcall(function()
    if widget.Show then widget:Show(false) end
    clearAnchors(widget)
    if widget.Destroy then widget:Destroy() end
  end)
end

local function placeButton(button, anchorPoint, relativeTo, relativePoint, x, y, width, height)
  if not button then return nil end
  clearAnchors(button)
  button:SetExtent(width, height)
  if relativePoint then
    button:AddAnchor(anchorPoint, relativeTo, relativePoint, x, y)
  else
    button:AddAnchor(anchorPoint, relativeTo, x, y)
  end
  return button
end

local function addPanel(parent, id, x, y, width, height, color)
  if not (parent and parent.CreateChildWidget) then return nil end
  local c = color or UI.panel
  local box = parent:CreateChildWidget("emptywidget", id, 0, true)
  box:SetExtent(width, height)
  box:AddAnchor("TOPLEFT", parent, x, y)
  if box.EnableMouse then box:EnableMouse(false) end
  local bg = box:CreateColorDrawable(c[1], c[2], c[3], c[4], "background")
  bg:AddAnchor("TOPLEFT", box, 0, 0)
  bg:AddAnchor("BOTTOMRIGHT", box, 0, 0)
  bg:Show(true)
  box:Show(true)
  return box
end

local function addStretchPanel(parent, id, left, top, right, bottom, color)
  if not (parent and parent.CreateChildWidget) then return nil end
  local c = color or UI.panel
  local box = parent:CreateChildWidget("emptywidget", id, 0, true)
  box:SetExtent(1, 1)
  box:AddAnchor("TOPLEFT", parent, left, top)
  box:AddAnchor("BOTTOMRIGHT", parent, -right, -bottom)
  if box.EnableMouse then box:EnableMouse(false) end
  local bg = box:CreateColorDrawable(c[1], c[2], c[3], c[4], "background")
  bg:AddAnchor("TOPLEFT", box, 0, 0)
  bg:AddAnchor("BOTTOMRIGHT", box, 0, 0)
  bg:Show(true)
  box:Show(true)
  return box
end

local function styleFlatButton(button, text, tone)
  if not button then return nil end
  local width, height = 100, 24
  pcall(function()
    if button.GetWidth and button:GetWidth() and button:GetWidth() > 0 then width = button:GetWidth() end
    if button.GetHeight and button:GetHeight() and button:GetHeight() > 0 then height = button:GetHeight() end
  end)

  local nativeSetText = button.SetText
  if nativeSetText then nativeSetText(button, "") end

  if not button.cleanBg and button.CreateColorDrawable then
    local c = tone or UI.button
    local bg = button:CreateColorDrawable(c[1], c[2], c[3], c[4], "background")
    bg:AddAnchor("TOPLEFT", button, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", button, 0, 0)
    bg:Show(true)
    button.cleanBg = bg
  end
  clearAnchors(button.cleanBg)
  if button.cleanBg then
    button.cleanBg:AddAnchor("TOPLEFT", button, 0, 0)
    button.cleanBg:AddAnchor("BOTTOMRIGHT", button, 0, 0)
  end

  if not button.cleanLabel then
    local label = button:CreateChildWidget("label", "cleanLabel", 0, true)
    if label.style then
      if label.style.SetFontSize then label.style:SetFontSize(11) end
      if label.style.SetAlign then label.style:SetAlign(ALIGN.CENTER) end
      if label.style.SetColor then label.style:SetColor(1, 1, 1, 1) end
    end
    if label.EnablePick then label:EnablePick(false) end
    label:Show(true)
    button.cleanLabel = label
  end

  function button:SetCleanText(nextText)
    if self.cleanLabel then self.cleanLabel:SetText(nextText or "") end
  end
  function button:SetText(nextText)
    self:SetCleanText(nextText)
  end
  function button:SetTone(nextTone)
    setDrawableColor(self.cleanBg, nextTone or UI.button)
  end

  if button.cleanLabel then
    clearAnchors(button.cleanLabel)
    button.cleanLabel:SetExtent(width, math.max(1, height - 2))
    button.cleanLabel:AddAnchor("TOPLEFT", button, 0, 1)
  end
  button:SetCleanText(text or "")
  button:SetTone(tone or UI.button)
  return button
end

-- Same ownership multiplier ladder as the editor's recompute(): the Nth
-- non-tax-exempt building you own pays this multiplier in tax.
local function ownedMult(n)
  if n <= 2 then return 1.00
  elseif n == 3 then return 2.00
  elseif n == 4 then return 2.50
  elseif n == 5 then return 3.00
  elseif n == 6 then return 3.50
  elseif n == 7 then return 5.00
  elseif n == 8 then return 6.00
  else return 7.00
  end
end

local function computeOwnership(lands)
  local total = 0
  local highTax = 0
  if lands then
    for _, land in ipairs(lands) do
      total = total + 1
      if not land.taxExempt then highTax = highTax + 1 end
    end
  end
  local mult = ownedMult(highTax)
  return total, math.floor((mult - 1) * 100 + 0.5)
end

local function landZoneName(land)
  return tostring((land and (land.zoneName or land.zone)) or "Unknown Zone")
end

local function collectZoneTaxRows()
  local settings = api.GetSettings("tax_tracker") or {}
  local zones = {}
  local order = {}
  for _, land in ipairs(settings.lands or {}) do
    local zone = landZoneName(land)
    if not zones[zone] then
      zones[zone] = { zoneName = zone, total = 0, editable = 0, hostile = 0, territory = 0, exempt = 0 }
      table.insert(order, zone)
    end
    local z = zones[zone]
    z.total = z.total + 1
    if land.taxExempt then
      z.exempt = z.exempt + 1
    else
      z.editable = z.editable + 1
      if land.hostile then z.hostile = z.hostile + 1 end
      if land.territory then z.territory = z.territory + 1 end
    end
  end
  table.sort(order)
  local rows = {}
  for _, zone in ipairs(order) do table.insert(rows, zones[zone]) end
  return rows
end

function SavedLandsWindow.setZoneTaxFlag(zoneName, fieldName, enabled)
  if not zoneName or not fieldName then return 0, 0 end
  local settings = api.GetSettings("tax_tracker") or {}
  local changed, skipped = 0, 0

  for _, land in ipairs(settings.lands or {}) do
    if landZoneName(land) == tostring(zoneName) then
      if land.taxExempt then
        skipped = skipped + 1
      elseif land[fieldName] ~= (enabled and true or false) then
        land[fieldName] = enabled and true or false
        changed = changed + 1
      end
    end
  end

  if changed > 0 then
    local ok, UI = pcall(require, "tax_tracker/ui/uimanager_v2")
    if ok and UI and UI.recalculateAllLandTaxes then
      UI.recalculateAllLandTaxes()
    else
      pcall(function() api.SaveSettings() end)
    end
    SavedLandsWindow.refreshData()
  end

  return changed, skipped
end

function SavedLandsWindow.setZoneHostileTax(zoneName, enabled)
  return SavedLandsWindow.setZoneTaxFlag(zoneName, "hostile", enabled)
end

function SavedLandsWindow.setZoneTerritoryTax(zoneName, enabled)
  return SavedLandsWindow.setZoneTaxFlag(zoneName, "territory", enabled)
end

local function rebuildBulkHostileWindow()
  if not bulkHostileWin then return end

  for _, row in ipairs(bulkHostileRows) do
    destroyWidget(row)
  end
  bulkHostileRows = {}
  bulkHostileRebuildSeq = bulkHostileRebuildSeq + 1

  local rows = collectZoneTaxRows()
  local totalPages = math.max(1, math.ceil(#rows / BULK_HOSTILE_ROWS))
  if bulkHostilePage > totalPages then bulkHostilePage = totalPages end
  if bulkHostilePage < 1 then bulkHostilePage = 1 end

  if bulkHostileWin._pageLbl then
    bulkHostileWin._pageLbl:SetText(string.format("%d / %d", bulkHostilePage, totalPages))
  end
  if bulkHostileWin._prevBtn and bulkHostileWin._prevBtn.Enable then bulkHostileWin._prevBtn:Enable(bulkHostilePage > 1) end
  if bulkHostileWin._nextBtn and bulkHostileWin._nextBtn.Enable then bulkHostileWin._nextBtn:Enable(bulkHostilePage < totalPages) end

  if #rows == 0 then
    local empty = bulkHostileWin:CreateChildWidget("label", "bulk_hostile_empty_" .. bulkHostileRebuildSeq, 0, true)
    empty:SetText("No tracked lands found.")
    empty:SetExtent(400, 24)
    empty:AddAnchor("TOPLEFT", bulkHostileWin, 28, 120)
    if empty.style then empty.style:SetAlign(ALIGN.LEFT); empty.style:SetFontSize(12) end
    setTextColor(empty, UI.muted)
    empty:Show(true)
    table.insert(bulkHostileRows, empty)
    return
  end

  local startIdx = (bulkHostilePage - 1) * BULK_HOSTILE_ROWS + 1
  local endIdx = math.min(startIdx + BULK_HOSTILE_ROWS - 1, #rows)
  for idx = startIdx, endIdx do
    local item = rows[idx]
    local rowIndex = idx - startIdx + 1
    local y = 116 + ((rowIndex - 1) * 31)
    local nameSuffix = bulkHostileRebuildSeq .. "_" .. tostring(rowIndex)
    local row = bulkHostileWin:CreateChildWidget("emptywidget", "bulk_hostile_row_" .. nameSuffix, 0, true)
    row:SetExtent(660, 28)
    row:AddAnchor("TOPLEFT", bulkHostileWin, 18, y)
    row:Show(true)
    table.insert(bulkHostileRows, row)

    local rowTone = rowIndex % 2 == 0 and UI.rowEven or UI.rowOdd
    local bg = row:CreateColorDrawable(rowTone[1], rowTone[2], rowTone[3], rowTone[4], "background")
    bg:AddAnchor("TOPLEFT", row, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", row, 0, 0)
    bg:Show(true)

    local lbl = row:CreateChildWidget("label", "bulk_hostile_lbl_" .. nameSuffix, 0, true)
    lbl:SetText(string.format("%s  (%d land, H:%d, T:%d, exempt:%d)", item.zoneName, item.total, item.hostile, item.territory, item.exempt))
    lbl:SetExtent(BULK_HOSTILE_LABEL_WIDTH, 24)
    lbl:AddAnchor("LEFT", row, 8, 0)
    if lbl.style then lbl.style:SetAlign(ALIGN.LEFT); lbl.style:SetFontSize(12) end
    setTextColor(lbl, UI.white)
    lbl:Show(true)

    local btnOn = row:CreateChildWidget("button", "bulk_hostile_on_" .. nameSuffix, 0, true)
    placeButton(btnOn, "RIGHT", row, nil, -(BULK_HOSTILE_RIGHT_MARGIN + BULK_HOSTILE_OFF_WIDTH + BULK_HOSTILE_BUTTON_GAP + BULK_HOSTILE_TERR_ON_WIDTH + BULK_HOSTILE_BUTTON_GAP + BULK_HOSTILE_OFF_WIDTH + BULK_HOSTILE_BUTTON_GAP), 0, BULK_HOSTILE_ON_WIDTH, 22)
    styleFlatButton(btnOn, "Hostile ON", UI.green)
    local capturedZoneOn = item.zoneName
    function btnOn:OnClick()
      local changed, skipped = SavedLandsWindow.setZoneHostileTax(capturedZoneOn, true)
      if bulkHostileWin._statusLbl then bulkHostileWin._statusLbl:SetText(string.format("Updated %d land(s), skipped %d exempt.", changed, skipped)) end
      rebuildBulkHostileWindow()
    end
    btnOn:SetHandler("OnClick", btnOn.OnClick)
    btnOn:Show(true)

    local btnOff = row:CreateChildWidget("button", "bulk_hostile_off_" .. nameSuffix, 0, true)
    placeButton(btnOff, "RIGHT", row, nil, -(BULK_HOSTILE_RIGHT_MARGIN + BULK_HOSTILE_TERR_ON_WIDTH + BULK_HOSTILE_BUTTON_GAP + BULK_HOSTILE_OFF_WIDTH + BULK_HOSTILE_BUTTON_GAP), 0, BULK_HOSTILE_OFF_WIDTH, 22)
    styleFlatButton(btnOff, "OFF", UI.button)
    local capturedZoneOff = item.zoneName
    function btnOff:OnClick()
      local changed, skipped = SavedLandsWindow.setZoneHostileTax(capturedZoneOff, false)
      if bulkHostileWin._statusLbl then bulkHostileWin._statusLbl:SetText(string.format("Updated %d land(s), skipped %d exempt.", changed, skipped)) end
      rebuildBulkHostileWindow()
    end
    btnOff:SetHandler("OnClick", btnOff.OnClick)
    btnOff:Show(true)

    local btnTerrOn = row:CreateChildWidget("button", "bulk_territory_on_" .. nameSuffix, 0, true)
    placeButton(btnTerrOn, "RIGHT", row, nil, -(BULK_HOSTILE_RIGHT_MARGIN + BULK_HOSTILE_OFF_WIDTH + BULK_HOSTILE_BUTTON_GAP), 0, BULK_HOSTILE_TERR_ON_WIDTH, 22)
    styleFlatButton(btnTerrOn, "Terr. ON", UI.green)
    local capturedTerrZoneOn = item.zoneName
    function btnTerrOn:OnClick()
      local changed, skipped = SavedLandsWindow.setZoneTerritoryTax(capturedTerrZoneOn, true)
      if bulkHostileWin._statusLbl then bulkHostileWin._statusLbl:SetText(string.format("Territory: updated %d land(s), skipped %d exempt.", changed, skipped)) end
      rebuildBulkHostileWindow()
    end
    btnTerrOn:SetHandler("OnClick", btnTerrOn.OnClick)
    btnTerrOn:Show(true)

    local btnTerrOff = row:CreateChildWidget("button", "bulk_territory_off_" .. nameSuffix, 0, true)
    placeButton(btnTerrOff, "RIGHT", row, nil, -BULK_HOSTILE_RIGHT_MARGIN, 0, BULK_HOSTILE_OFF_WIDTH, 22)
    styleFlatButton(btnTerrOff, "OFF", UI.button)
    local capturedTerrZoneOff = item.zoneName
    function btnTerrOff:OnClick()
      local changed, skipped = SavedLandsWindow.setZoneTerritoryTax(capturedTerrZoneOff, false)
      if bulkHostileWin._statusLbl then bulkHostileWin._statusLbl:SetText(string.format("Territory: updated %d land(s), skipped %d exempt.", changed, skipped)) end
      rebuildBulkHostileWindow()
    end
    btnTerrOff:SetHandler("OnClick", btnTerrOff.OnClick)
    btnTerrOff:Show(true)
  end
end

local function openBulkHostileWindow()
  if not bulkHostileWin then
    bulkHostileWin = gui.CreateStyledWindow("TaxTrackerZoneHostile", "Zone Tax", 700, 450)
    if bulkHostileWin.RemoveAllAnchors then
      bulkHostileWin:RemoveAllAnchors()
    end
    bulkHostileWin:AddAnchor("CENTER", "UIParent", 0, 0)

    gui.CreateCategoryPanel(bulkHostileWin, "bulkHostileRoot", 12, 42, 676, 352, "Zone Tax")
    addPanel(bulkHostileWin, "bulkHostileHintGroup", 18, 76, 664, 28, UI.groupStatus)
    addPanel(bulkHostileWin, "bulkHostileListPanel", 18, 112, 664, 282, UI.listPanel)
    addPanel(bulkHostileWin, "bulkHostileFooter", 18, 402, 664, 30, UI.groupStatus)

    local hint = bulkHostileWin:CreateChildWidget("label", "bulk_hostile_hint", 0, true)
    hint:SetText("Set hostile faction or territory tax for all non-exempt tracked land in one zone.")
    hint:SetExtent(640, 22)
    hint:AddAnchor("TOPLEFT", bulkHostileWin, 28, 80)
    if hint.style then hint.style:SetAlign(ALIGN.LEFT); hint.style:SetFontSize(12) end
    setTextColor(hint, UI.muted)
    hint:Show(true)

    local status = bulkHostileWin:CreateChildWidget("label", "bulk_hostile_status", 0, true)
    status:SetText("")
    status:SetExtent(390, 24)
    status:AddAnchor("TOPLEFT", bulkHostileWin, 156, 406)
    if status.style then status.style:SetAlign(ALIGN.LEFT); status.style:SetFontSize(12) end
    setTextColor(status, UI.muted)
    status:Show(true)
    bulkHostileWin._statusLbl = status

    local prevBtn = bulkHostileWin:CreateChildWidget("button", "bulk_hostile_prev", 0, true)
    prevBtn:SetExtent(70, 22)
    prevBtn:AddAnchor("BOTTOMLEFT", bulkHostileWin, 18, -14)
    styleFlatButton(prevBtn, "Prev", UI.button)
    function prevBtn:OnClick()
      bulkHostilePage = bulkHostilePage - 1
      rebuildBulkHostileWindow()
    end
    prevBtn:SetHandler("OnClick", prevBtn.OnClick)
    prevBtn:Show(true)
    bulkHostileWin._prevBtn = prevBtn

    local pageLbl = bulkHostileWin:CreateChildWidget("label", "bulk_hostile_page", 0, true)
    pageLbl:SetText("1 / 1")
    pageLbl:SetExtent(54, 24)
    pageLbl:AddAnchor("TOPLEFT", bulkHostileWin, 94, 406)
    if pageLbl.style then pageLbl.style:SetAlign(ALIGN.LEFT); pageLbl.style:SetFontSize(12) end
    setTextColor(pageLbl, UI.muted)
    pageLbl:Show(true)
    bulkHostileWin._pageLbl = pageLbl

    local nextBtn = bulkHostileWin:CreateChildWidget("button", "bulk_hostile_next", 0, true)
    nextBtn:SetExtent(70, 22)
    nextBtn:AddAnchor("BOTTOMRIGHT", bulkHostileWin, -18, -14)
    styleFlatButton(nextBtn, "Next", UI.button)
    function nextBtn:OnClick()
      bulkHostilePage = bulkHostilePage + 1
      rebuildBulkHostileWindow()
    end
    nextBtn:SetHandler("OnClick", nextBtn.OnClick)
    nextBtn:Show(true)
    bulkHostileWin._nextBtn = nextBtn
  end

  bulkHostilePage = 1
  if bulkHostileWin._statusLbl then bulkHostileWin._statusLbl:SetText("") end
  rebuildBulkHostileWindow()
  bulkHostileWin:Show(true)
end

-- Initialize Saved Lands Window
function SavedLandsWindow.initialize(dataCallback)
    if listWin and listWin.Show then
        return true -- Already exists
    end
    
    -- Store data callback for dynamic data access
    if dataCallback then
        SavedLandsWindow.getDataCallback = dataCallback
    end
    
    Debug.info("SavedLandsWindow", "Building Saved Lands window")
    
    local success, result = pcall(function()
        -- Wipe any TaxTrackerList widget left over from a previous addon load
        -- before we create a new one — otherwise each /reload stacks another
        -- saved-lands window on top of the previous one.
        if api.Interface.FindWidget then
            local ok, orphan = pcall(api.Interface.FindWidget, api.Interface, "TaxTrackerList")
            if ok and orphan then
                pcall(function()
                    if orphan.Show then orphan:Show(false) end
                    if orphan.RemoveAllAnchors then orphan:RemoveAllAnchors() end
                    if orphan.Destroy then orphan:Destroy() end
                end)
            end
        end

        -- Create main window - widened to show all columns properly
        listWin = gui.CreateStyledWindow("TaxTrackerList", "Land Barons - Arise", 1500, 800)
        if listWin.RemoveAllAnchors then
            listWin:RemoveAllAnchors()
        end
        listWin:AddAnchor("CENTER", "UIParent", "CENTER", 0, 220)
        listWin:Show(false) -- Initially hidden, opened from HUD button
        
        -- TIMER REMOVED: All updates now handled by centralized UpdateSystem
        -- This eliminates dual timer conflicts and consolidates update logic
        listWin.refreshTimer = nil
        Debug.info("SavedLandsWindow", "Local refresh timer disabled - using centralized UpdateSystem")
        
        -- Timer registration removed - UpdateSystem handles all updates
        Debug.info("SavedLandsWindow", "Timer registration skipped - UpdateSystem handles all updates")
        
        -- Add the same dark grouped treatment used by the editor.
        addStretchPanel(listWin, "savedLandsRootPanel", 12, 42, 12, 30, UI.panel)
        addPanel(listWin, "savedLandsToolbarPanel", 20, 42, 1050, 38, UI.groupDetails)
        addStretchPanel(listWin, "savedLandsListPanel", 20, 86, 20, 24, UI.listPanel)
        
        -- Create header buttons (Loans, Open Editor, Farm Tracker)
        CreateHeaderButtons()
        
        -- Owned lands label, top-right corner. Explicit width so the Sum
        -- label sitting to its left can be spaced reliably.
        ownedLabel = listWin:CreateChildWidget("label", "ownedList", 0, true)
        ownedLabel:SetExtent(180, 22)
        ownedLabel:AddAnchor("TOPRIGHT", listWin, -20, 46)
        ownedLabel:SetText("Owned: 0 (+0%)")
        if ownedLabel.style then
            if ownedLabel.style.SetAlign then ownedLabel.style:SetAlign(ALIGN.RIGHT) end
            if ownedLabel.style.SetFontSize then ownedLabel.style:SetFontSize(12) end
        end
        setTextColor(ownedLabel, UI.gold)
        listWin.ownedLabel = ownedLabel
        
        -- Create lands list using EXACT same approach as working version
        CreateLandsList()
        
        Debug.info("SavedLandsWindow", "Saved Lands window created successfully")
        return true
    end)
    
    if not success then
        Debug.error("SavedLandsWindow", "Failed to create Saved Lands window", {error = result})
        return false
    end
    
    return true
end

-- Create header buttons (Loans, Open Editor, Farm Tracker)
function CreateHeaderButtons()
    -- Loans button (left side)
    local loansBtn = listWin:CreateChildWidget("button", "loansBtn", 0, true)
    loansBtn:SetExtent(100, 28)
    loansBtn:AddAnchor("TOPLEFT", listWin, 20, 42)
    styleFlatButton(loansBtn, "Loans", UI.button)
    
    function loansBtn:OnClick()
        Debug.info("SavedLandsWindow", "Loans button clicked")
        
        -- Load LoansSystem and get current land data
        local loansSuccess, LoansSystem = pcall(require, "tax_tracker/loanssystem")
        if loansSuccess and LoansSystem then
            -- Get current land data from SavedLandsWindow
            local lands = SavedLandsWindow.getCurrentLandData()
            LoansSystem.showLoansWindow(lands)
        else
            Debug.error("SavedLandsWindow", "Failed to load LoansSystem")
        end
    end
    loansBtn:SetHandler("OnClick", loansBtn.OnClick)
    
    -- "Open Editor" button next to Loans button  
    local openEditorBtn = listWin:CreateChildWidget("button", "openEditorBtn", 0, true)
    openEditorBtn:SetExtent(130, 28)
    openEditorBtn:AddAnchor("LEFT", loansBtn, "RIGHT", 10, 0)
    styleFlatButton(openEditorBtn, "Open Editor", UI.green)
    
    function openEditorBtn:OnClick()
        Debug.info("SavedLandsWindow", "Open Editor button clicked")
        
        -- Load UIManager and initialize if needed (NO FALLBACKS)
        if not UIManager then UIManager = require("tax_tracker/ui/uimanager_v2") end
        
        if not UIManager.isInitialized then
            Debug.info("SavedLandsWindow", "Initializing UIManager")
            UIManager.initialize(nil, nil)
        end
        
        -- Always clear edit mode to show a fresh form for adding new land
        if UIManager.clearEditMode then
            UIManager.clearEditMode()
            Debug.info("SavedLandsWindow", "Edit mode cleared - ready for new land entry")
        end
        
        -- Show the window (always show, don't toggle) - EXACT SAME AS WORKING VERSION
        UIManager.showWindow()
        Debug.info("SavedLandsWindow", "UIManager editor window shown")
    end
    openEditorBtn:SetHandler("OnClick", openEditorBtn.OnClick)
    
    -- "Farm Tracker" button next to Open Editor button
    local farmTrackerBtn = listWin:CreateChildWidget("button", "farmTrackerBtn", 0, true)
    farmTrackerBtn:SetExtent(130, 28)
    farmTrackerBtn:AddAnchor("LEFT", openEditorBtn, "RIGHT", 10, 0)
    styleFlatButton(farmTrackerBtn, "Farm Tracker", UI.button)
    
    function farmTrackerBtn:OnClick()
        Debug.info("SavedLandsWindow", "Farm Tracker button clicked")

        -- Load FarmSystem
        local farmSuccess, FarmSystem = pcall(require, "tax_tracker/farmsystem")
        if farmSuccess and FarmSystem then
            FarmSystem.showFarmWindow()
        else
            Debug.error("SavedLandsWindow", "Failed to load FarmSystem")
        end
    end
    farmTrackerBtn:SetHandler("OnClick", farmTrackerBtn.OnClick)

    -- "Autotracker" toggle next to Farm Tracker
    local autotrackerBtn = listWin:CreateChildWidget("button", "autotrackerBtn", 0, true)
    autotrackerBtn:SetExtent(150, 28)
    autotrackerBtn:AddAnchor("LEFT", farmTrackerBtn, "RIGHT", 10, 0)
    styleFlatButton(autotrackerBtn, "Autotracker OFF", UI.button)

    local function refreshAutotrackerText()
        local farmSuccess, FarmSystem = pcall(require, "tax_tracker/farmsystem")
        local enabled = farmSuccess and FarmSystem and FarmSystem.isAutotrackerEnabled and FarmSystem.isAutotrackerEnabled()
        autotrackerBtn:SetText(enabled and "Autotracker ON" or "Autotracker OFF")
        if autotrackerBtn.SetTone then autotrackerBtn:SetTone(enabled and UI.green or UI.button) end
    end
    refreshAutotrackerText()
    do
        local farmSuccess, FarmSystem = pcall(require, "tax_tracker/farmsystem")
        if farmSuccess and FarmSystem and FarmSystem.registerAutotrackerButton then
            FarmSystem.registerAutotrackerButton(autotrackerBtn)
        end
    end

    function autotrackerBtn:OnClick()
        Debug.info("SavedLandsWindow", "Autotracker button clicked")
        local farmSuccess, FarmSystem = pcall(require, "tax_tracker/farmsystem")
        if farmSuccess and FarmSystem and FarmSystem.toggleAutotracker then
            FarmSystem.toggleAutotracker()
            refreshAutotrackerText()
        else
            Debug.error("SavedLandsWindow", "Failed to toggle FarmSystem autotracker")
        end
    end
    autotrackerBtn:SetHandler("OnClick", autotrackerBtn.OnClick)

    -- Reset All button: wipes the payment timer on every saved land back to
    -- "No Timer" without touching the lands themselves. Useful after a
    -- big tax-day clean-up or for re-syncing all timers from scratch.
    local resetAllBtn = listWin:CreateChildWidget("button", "resetAllBtn", 0, true)
    resetAllBtn:SetExtent(150, 28)
    resetAllBtn:AddAnchor("LEFT", autotrackerBtn, "RIGHT", 10, 0)
    styleFlatButton(resetAllBtn, "Reset All Timers", UI.button)

    function resetAllBtn:OnClick()
        SavedLandsWindow.resetAllTimers()
    end
    resetAllBtn:SetHandler("OnClick", resetAllBtn.OnClick)

    local zoneHostileBtn = listWin:CreateChildWidget("button", "zoneHostileBtn", 0, true)
    zoneHostileBtn:SetExtent(140, 28)
    zoneHostileBtn:AddAnchor("LEFT", resetAllBtn, "RIGHT", 10, 0)
    styleFlatButton(zoneHostileBtn, "Zone Tax", UI.button)

    function zoneHostileBtn:OnClick()
        openBulkHostileWindow()
    end
    zoneHostileBtn:SetHandler("OnClick", zoneHostileBtn.OnClick)
end

-- Create hierarchical zone-based land categorization with timer aggregation  
local function getTimerUrgency(timerData)
  if not timerData then return 999999 end
  
  -- First check if timer is overdue using TimeSystem
  local isOverdue = false
  pcall(function()
    isOverdue = TimeSystem.isOverdue(timerData)
  end)
  
  if isOverdue then
    return -1 -- Overdue = highest urgency
  end
  
  -- Get remaining time in milliseconds and convert to hours
  local timeLeftMs = 0
  pcall(function()
    timeLeftMs = TimeSystem.getTimeLeft(timerData)
  end)
  
  if timeLeftMs <= 0 then
    return -1 -- Overdue
  end
  
  -- Convert milliseconds to hours
  return timeLeftMs / (1000 * 60 * 60)
end

local function getZoneTimerStatus(zoneLands)
  local mostUrgent = nil
  local minUrgency = 999999
  local overdueCount = 0
  local urgentCount = 0
  
  for _, land in ipairs(zoneLands) do
    local urgency = getTimerUrgency(land.nextPayment)
    if urgency == -1 then
      overdueCount = overdueCount + 1
      if minUrgency > -1 then
        minUrgency = -1
        mostUrgent = land
      end
    elseif urgency < 24 and urgency > 0 then
      urgentCount = urgentCount + 1
      if urgency < minUrgency and minUrgency ~= -1 then
        minUrgency = urgency
        mostUrgent = land
      end
    elseif urgency < minUrgency and minUrgency ~= -1 then
      minUrgency = urgency
      mostUrgent = land
    end
  end
  
  local priority, statusText, statusIcon = "green", "", "🟢"
  if overdueCount > 0 then
    priority = "red"
    statusIcon = "🔴"
    statusText = string.format("OVERDUE: %d land%s", overdueCount, overdueCount > 1 and "s" or "")
  elseif urgentCount > 0 then
    priority = "yellow"
    statusIcon = "🟡"
    if mostUrgent and mostUrgent.nextPayment then
      local success, timeText = pcall(TimeSystem.formatCountdown, mostUrgent.nextPayment)
      if success and timeText then
        statusText = string.format("Next: %s", timeText:gsub("Next payment: ", ""))
      else
        statusText = "Next: <24h"
      end
    else
      statusText = "Next: <24h"
    end
  else
    if mostUrgent and mostUrgent.nextPayment then
      local success, timeText = pcall(TimeSystem.formatCountdown, mostUrgent.nextPayment)
      if success and timeText then
        statusText = string.format("Next: %s", timeText:gsub("Next payment: ", ""))
      else
        statusText = "Next: >24h"
      end
    else
      statusText = "Next: >24h"
    end
  end
  return priority, statusIcon .. " " .. statusText, overdueCount > 0
end

-- Create hierarchical lands list with zone categorization
function CreateLandsList()
  Debug.info("SavedLandsWindow", "Creating hierarchical zone-based lands list")
  
  local hierarchicalData = {}
  local originalLandsData = SavedLandsWindow.getData()
  
  local function buildHierarchicalData()
    hierarchicalData = {}
    local zoneGroups = {}
    
    -- Group lands by zone
    for _, land in ipairs(originalLandsData) do
      local zoneName = land.zoneName or "Unknown Zone"
      if not zoneGroups[zoneName] then zoneGroups[zoneName] = {} end
      table.insert(zoneGroups[zoneName], land)
    end
    
    -- Sort zones by urgency
    local sortedZones = {}
    for zoneName, zoneLands in pairs(zoneGroups) do
      local priority, statusText, shouldExpand = getZoneTimerStatus(zoneLands)
      table.insert(sortedZones, {
        zoneName = zoneName, zoneLands = zoneLands, priority = priority, statusText = statusText, shouldExpand = shouldExpand
      })
    end
    
    table.sort(sortedZones, function(a, b)
      local priorityOrder = {red = 1, yellow = 2, green = 3}
      return priorityOrder[a.priority] < priorityOrder[b.priority]
    end)
    
    -- Create hierarchical structure
    local zoneIndex = 1
    for _, zoneInfo in ipairs(sortedZones) do
      local zoneDisplayName = string.format("%s (%d lands) - %s", zoneInfo.zoneName, #zoneInfo.zoneLands, zoneInfo.statusText)
      
      table.insert(hierarchicalData, {
        id = "zone_" .. zoneIndex, name = zoneDisplayName, tier = 0, expanded = false, -- Always closed by default
        priority = zoneInfo.priority, value = "zone_" .. zoneInfo.zoneName, isZoneHeader = true,
        zoneName = zoneInfo.zoneName, landCount = #zoneInfo.zoneLands
      })
      
      for i, land in ipairs(zoneInfo.zoneLands) do
        local timerText = "No timer"
        if land.nextPayment then
          local success, formatted = pcall(TimeSystem.formatCountdown, land.nextPayment)
          if success and formatted then
            timerText = formatted
          end
        end
        
        table.insert(hierarchicalData, {
          id = "land_" .. (land.id or i),
          name = string.format("%s [#%s] - %s", land.name or "Unnamed", tostring(land.id or "?"), timerText),
          tier = 1, expanded = false, value = land.id, isZoneHeader = false, landData = land
        })
      end
      zoneIndex = zoneIndex + 1
    end
  end
  
  buildHierarchicalData()
  
  -- Create hybrid list with embedded tables (fill window)
  itemList = HybridList.create(listWin, "hybridLandsList", 1480, hierarchicalData,
    function(value, displayName, landData)
      Debug.info("SavedLandsWindow", "Land item selected", {value = value, name = displayName})
      if landData then
        listWin.selectedLandData = landData
      end
    end, 540)
  
  -- NOTE: Action panel removed - actions will be embedded in expanded table rows
  
-- Map button handler removed - will be embedded in table rows
-- Paid button handler removed - will be embedded in table rows
  
  -- Store references (action panel removed)
  listWin.selectedLandData = nil
  
  -- updateActionPanel function removed - actions will be embedded in table rows

  if itemList then
    listWin.hybridList = itemList
    function listWin:refreshHybridData()
      Debug.info("SavedLandsWindow", "=== refreshHybridData CALLED ===")
      
      -- Preserve current selected land
      local currentSelectedLand = listWin.selectedLandData
      
      originalLandsData = SavedLandsWindow.getData()
      buildHierarchicalData()
      
      if itemList and itemList.UpdateData then 
        Debug.info("SavedLandsWindow", "Calling itemList:UpdateData", {
          dataCount = #hierarchicalData
        })
        itemList:UpdateData(hierarchicalData) 
      else
        Debug.error("SavedLandsWindow", "itemList or UpdateData method not available")
      end
      
      -- Restore selected land if it still exists in the updated data
      if currentSelectedLand then
        for _, land in ipairs(originalLandsData) do
          if land.id == currentSelectedLand.id then
            listWin.selectedLandData = land
            if listWin.selectedLabel then
              listWin.selectedLabel:SetText(string.format("%s [#%s] in %s", 
                land.name or "Unnamed", 
                tostring(land.id or "?"), 
                land.zoneName or "Unknown Zone"))
            end
            -- updateActionPanel removed - actions will be in table rows
            break
          end
        end
      end
      
      if listWin.updateTaxSum then 
        listWin.updateTaxSum() 
      end
      
      Debug.info("SavedLandsWindow", "Hybrid data refreshed", {
        totalLands = #originalLandsData, 
        zoneGroups = #hierarchicalData,
        selectedLandPreserved = currentSelectedLand ~= nil
      })
    end
  end
  
  Debug.info("SavedLandsWindow", "Hybrid lands list created", {totalItems = #hierarchicalData, originalLands = #originalLandsData})
  
  -- Tax Sum label. Anchored TOPRIGHT (not relative to ownedLabel) with a
  -- fixed extent and explicit RIGHT alignment so the two labels can't
  -- visually overlap regardless of text length. Sum value is in tax certs,
  -- not gold — the suffix is "tax".
  local taxSumLabel = listWin:CreateChildWidget("label", "taxSumLabel", 0, true)
  taxSumLabel:SetText("Sum: 0.00 tax")
  taxSumLabel:SetExtent(200, 22)
  taxSumLabel:AddAnchor("TOPRIGHT", listWin, -220, 46)
  if taxSumLabel.style then
    if taxSumLabel.style.SetFontSize then taxSumLabel.style:SetFontSize(12) end
    if taxSumLabel.style.SetAlign    then taxSumLabel.style:SetAlign(ALIGN.RIGHT) end
  end
  setTextColor(taxSumLabel, UI.gold)
  listWin.taxSumLabel = taxSumLabel
  
  local function updateTaxSum()
    if not listWin.taxSumLabel then return end
    local totalTax = 0
    local data = SavedLandsWindow.getData()
    for _, land in ipairs(data) do totalTax = totalTax + (land.tax or 0) end
    local function fmt2(n) return string.format("%.2f", n or 0) end
    listWin.taxSumLabel:SetText(string.format("Sum: %s tax", fmt2(totalTax)))
    Debug.info("SavedLandsWindow", "Tax sum updated", {totalTax = totalTax})
  end
  
  listWin.updateTaxSum = updateTaxSum
  updateTaxSum()

end

-- Show/Hide window
function SavedLandsWindow.show()
    if not listWin then
        SavedLandsWindow.initialize()
    end
    if listWin then
        listWin:Show(true)
        -- Refresh data when shown
        SavedLandsWindow.refreshData()
    end
end

function SavedLandsWindow.hide()
    if listWin then
        listWin:Show(false)
    end
end

function SavedLandsWindow.toggle()
    Debug.info("SavedLandsWindow", "Toggle called")
    if not listWin then
        Debug.info("SavedLandsWindow", "Window not initialized, calling initialize()")
        SavedLandsWindow.initialize()
    end
    if listWin then
        local isCurrentlyVisible = listWin:IsVisible()
        Debug.info("SavedLandsWindow", "Toggling window visibility", {currentlyVisible = isCurrentlyVisible})
        if isCurrentlyVisible then
            SavedLandsWindow.hide()
        else
            SavedLandsWindow.show()
        end
    else
        Debug.error("SavedLandsWindow", "Failed to initialize window for toggle")
    end
end

-- Get window visibility
function SavedLandsWindow.isVisible()
    return listWin and listWin:IsVisible() or false
end

-- PERFORMANCE METHODS: Support granular updates from UpdateSystem

-- Get reference to hybrid list for granular updates
function SavedLandsWindow.getHybridList()
    if listWin and listWin.hybridList then
        return listWin.hybridList
    end
    return nil
end

-- Get zone status data for header updates (priority, color, etc.)
function SavedLandsWindow.getZoneStatusData(zoneName)
    if not zoneName then return nil end
    
    -- This should calculate zone priority and return display data
    local data = SavedLandsWindow.getData()
    if not data then return nil end
    
    -- Find lands in this zone and calculate priority
    local zoneUrgency = "green"  -- default
    local overdueCount = 0
    local urgentCount = 0
    
    for _, land in ipairs(data) do
        if land.zoneName == zoneName then
            if land.isOverdue then
                overdueCount = overdueCount + 1
                zoneUrgency = "red"
            else
                local TimeSystem = require("tax_tracker/timesystem")
                local timeLeft = TimeSystem.getTimeLeft(land.nextPayment)
                if timeLeft and timeLeft < 24 * 60 * 60 * 1000 then -- Less than 24 hours
                    urgentCount = urgentCount + 1
                    if zoneUrgency ~= "red" then
                        zoneUrgency = "yellow"
                    end
                end
            end
        end
    end
    
    -- Return status data for zone header updates
    local color = {1, 1, 1, 1} -- Default white
    if zoneUrgency == "red" then
        color = {1, 0.3, 0.3, 1} -- Red for overdue
    elseif zoneUrgency == "yellow" then
        color = {1, 1, 0.3, 1} -- Yellow for urgent
    elseif zoneUrgency == "green" then
        color = {0.3, 1, 0.3, 1} -- Green for safe
    end
    
    return {
        priority = zoneUrgency,
        color = color,
        overdueCount = overdueCount,
        urgentCount = urgentCount
    }
end

-- Get current land data for other systems (like LoansSystem)
function SavedLandsWindow.getCurrentLandData()
    -- Try to get data from DataManager first
    local dmSuccess, DataManager = pcall(require, "tax_tracker/services/datamanager")
    if dmSuccess and DataManager then
        local lands = DataManager.getAllLands()
        if lands and #lands > 0 then
            return lands
        end
    end
    
    -- Fallback to settings
    -- api already required at top
    local settings = api.GetSettings("tax_tracker")
    if settings and settings.lands then
        return settings.lands
    end
    
    return {}
end

-- Wipe the payment timer on every saved land back to "No Timer" (nil).
-- Doesn't delete any lands. Persists immediately so a reload doesn't
-- bring the old timers back.
function SavedLandsWindow.resetAllTimers()
    local settings = api.GetSettings("tax_tracker") or {}
    if not settings.lands or #settings.lands == 0 then return end

    for _, land in ipairs(settings.lands) do
        land.nextPayment = nil
        land.isOverdue = false
    end

    pcall(function() api.SaveSettings() end)
    SavedLandsWindow.refreshData()
end

-- Delete a land by ID or index
function SavedLandsWindow.deleteLand(landId)
    Debug.info("SavedLandsWindow", "Attempting to delete land", {landId = landId})

    -- Get land info before deleting (to find associated loans)
    local settings = api.GetSettings("tax_tracker") or {}
    local landToDelete = nil
    local landNameToDelete = nil
    if settings.lands then
        for _, land in ipairs(settings.lands) do
            if land.id == landId then
                landToDelete = land
                landNameToDelete = land.name
                break
            end
        end
    end

    -- Try to delete via DataManager first
    local dmSuccess, DataManager = pcall(require, "tax_tracker/services/datamanager")
    if dmSuccess and DataManager and DataManager.deleteLand then
        local success = DataManager.deleteLand(landId)
        if success then
            Debug.info("SavedLandsWindow", "Land deleted via DataManager")
            LoansSystem.deleteLoansForLand(landId)
            return true
        end
    end
    
    -- Fallback to settings-based deletion
    -- api already required at top
    settings = api.GetSettings("tax_tracker") or {}
    if settings.lands then
        for i, land in ipairs(settings.lands) do
            if land.id == landId or i == landId then
                table.remove(settings.lands, i)

                LoansSystem.deleteLoansForLand(landId)

                -- Save settings
                local saveSuccess = pcall(function()
                    api.SaveSettings()
                end)

                if saveSuccess then
                    Debug.info("SavedLandsWindow", "Land deleted via settings", {index = i})
                    return true
                else
                    Debug.error("SavedLandsWindow", "Failed to save after deletion")
                    return false
                end
            end
        end
    end
    
    Debug.warn("SavedLandsWindow", "Land not found for deletion", {landId = landId})
    return false
end


-- Update data in the list - Now uses hierarchical approach
function SavedLandsWindow.updateData(landData)
    Debug.info("SavedLandsWindow", "UpdateData called", {landCount = landData and #landData or 0, hasItemList = itemList ~= nil})
    
    if not itemList then
        Debug.warn("SavedLandsWindow", "itemList not available for updateData")
        return
    end
    
    -- GUARD: Don't update with empty data unless explicitly intended
    if not landData or #landData == 0 then
        Debug.warn("SavedLandsWindow", "UpdateData called with empty/nil data - this might indicate data loss issue")
        -- Still allow the update but warn about it
    end
    
    -- Update owned label with the real ownership-tax percentage so the
    -- main window stays in sync with the editor's recompute().
    if ownedLabel and landData then
        local total, pct = computeOwnership(landData)
        ownedLabel:SetText(string.format("Owned: %d (+%d%%)", total, pct))
    end
    
    -- Use hybrid refresh function instead of direct UpdateData
    if listWin and listWin.refreshHybridData then
        listWin:refreshHybridData()
        Debug.info("SavedLandsWindow", "List data updated using hybrid refresh")
    else
        Debug.error("SavedLandsWindow", "listWin.refreshHybridData not available")
    end
    
    -- Update tax sum after data update (like working version)
    if listWin and listWin.updateTaxSum then
        listWin.updateTaxSum()
    end
end




-- Refresh data from current sources
function SavedLandsWindow.refreshData()
    Debug.info("SavedLandsWindow", "RefreshData called - getting current land data")
    
    local lands = {}
    
    -- Try callback first (from main.lua)
    if SavedLandsWindow.getDataCallback then
        lands = SavedLandsWindow.getDataCallback() or {}
        Debug.info("SavedLandsWindow", "Data retrieved from callback", {
            landCount = #lands,
            hasCallback = true,
            firstLand = lands[1] and lands[1].name or "No lands"
        })
    else
        -- Fallback to settings
        -- api already required at top
        local settings = api.GetSettings("tax_tracker")
        lands = settings and settings.lands or {}
        Debug.info("SavedLandsWindow", "Data retrieved from settings", {
            landCount = #lands,
            hasCallback = false,
            firstLand = lands[1] and lands[1].name or "No lands"
        })
    end
    
    -- DEBUGGING: Log if we're getting empty data when we shouldn't
    if #lands == 0 then
        Debug.warn("SavedLandsWindow", "RefreshData called with empty data - checking callback status", {
            hasCallback = SavedLandsWindow.getDataCallback ~= nil,
            callbackType = type(SavedLandsWindow.getDataCallback)
        })
    end
    
    if #lands > 0 then
        -- Validate each land entry has required time data
        for i, land in ipairs(lands) do
            if TimeSystem and TimeSystem.validateLandData then
                TimeSystem.validateLandData(land)
            end
        end
        Debug.info("SavedLandsWindow", "Land data validated through TimeSystem")
    end
    
    SavedLandsWindow.updateData(lands)
end

-- Get the list control for direct access
function SavedLandsWindow.getListControl()
    return itemList
end

-- Get the window for direct access  
function SavedLandsWindow.getWindow()
    return listWin
end

-- Check if initialized
function SavedLandsWindow.isInitialized()
    return listWin ~= nil
end

-- Cleanup
-- Refresh the list (alias for updateData)
function SavedLandsWindow.refresh(landData)
    SavedLandsWindow.updateData(landData)
end


-- Get current land data
function SavedLandsWindow.getData()
    -- api already required at top
    local settings = api.GetSettings("tax_tracker") or {}
    return settings.lands or {}
end

function SavedLandsWindow.cleanup()
    Debug.info("SavedLandsWindow", "Starting SavedLandsWindow cleanup")
    
    if listWin then
        -- Timer cleanup removed - no local timer to clean up
        Debug.info("SavedLandsWindow", "Cleanup called - no local timer to remove")
        
        if listWin.Destroy then
            pcall(function() listWin:Destroy() end)
        end
    end
    if bulkHostileWin then
        if bulkHostileWin.Destroy then
            pcall(function() bulkHostileWin:Destroy() end)
        elseif bulkHostileWin.Show then
            bulkHostileWin:Show(false)
        end
    end
    
    listWin = nil
    itemList = nil
    ownedLabel = nil
    bulkHostileWin = nil
    bulkHostileRows = {}
    Debug.info("SavedLandsWindow", "Saved Lands window cleaned up")
end

return SavedLandsWindow
