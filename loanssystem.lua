-- tax_tracker/loans_system.lua - Land rental/loan tracking system
local api = require("api")
local gui = require("tax_tracker/gui")
-- Use Debug safely to avoid circular dependencies
local Debug = nil
pcall(function() Debug = require("tax_tracker/debug") end)
if not Debug then
  Debug = { info = function() end, warn = function() end, error = function() end, debug = function() end, trace = function() end }
end
-- Safe TimeSystem loading
local TimeSystem = nil
pcall(function() TimeSystem = require("tax_tracker/timesystem") end)
-- Load hierarchical dropdown
local HierarchicalDropdown = nil
pcall(function() HierarchicalDropdown = require("tax_tracker/ui/hierarchical_dropdown_fixed") end)

local LoansSystem = {}

-- Loans data structure
local loansData = {}
local loansSeq = 0
local loansWin = nil
local loansItemList = nil
local noteWin = nil          -- Reused note dialog (one instance for all loans)
local noteEdit = nil         -- The editbox inside the note dialog
local noteCurrentLoanId = 0  -- Which loan the dialog is currently editing

-- Widget teardown helpers. Defined up here (rather than alongside
-- LoansSystem.init where they're conceptually related) because earlier
-- code in this file — openLoanNoteDialog, the build flow, etc. — also
-- needs to call them. Lua's `local function` is in scope only AFTER its
-- declaration line, so calling these from a function defined before they
-- existed silently threw "attempt to call nil" inside the click handler,
-- which the engine swallowed → "Note button does nothing".
local function destroyWidget(w)
  if not w then return end
  pcall(function()
    if w.Show then w:Show(false) end
    if w.RemoveAllAnchors then w:RemoveAllAnchors() end
    if w.Destroy then w:Destroy() end
  end)
end

local function destroyOrphanByName(name)
  if not (api.Interface and api.Interface.FindWidget) then return end
  for _ = 1, 50 do
    local ok, widget = pcall(api.Interface.FindWidget, api.Interface, name)
    if not (ok and widget) then return end
    destroyWidget(widget)
  end
end

-- Settings key for persistence
local LOANS_SETTINGS_KEY = "tax_tracker_loans"

-- Helper to add tint background to windows
local function addTint(win, id, alpha, topPad)
  local pad = topPad or 36
  local a   = alpha or 0.60
  local bg  = win:CreateChildWidget("textbox", id or "bg", 0, true)
  bg:AddAnchor("TOPLEFT", win, 0, pad)
  bg:AddAnchor("BOTTOMRIGHT", win, 0, 0)
  bg:SetText("")
  if bg.style and bg.style.SetColor then bg.style:SetColor(0,0,0,a) end
  if bg.Enable then bg:Enable(false) end
  bg:Show(true)
  return bg
end

-- Helper to check if checkbox is checked
local function is_checked(w) 
  return (w and w.GetChecked and w:GetChecked()) and true or false 
end

-- Format date from server timestamp - FIXED
local function formatDate(timestamp)
  if not timestamp or timestamp == 0 or timestamp < 86400 then
    -- Create a current date string as fallback
    local fallbackTime = 1700000000 -- ~November 2023
  end
  local success, dateStr = pcall(function()
    if api and api.Time and api.Time.TimeToDate then
      local timeObj = api.Time:TimeToDate(timestamp)
      if timeObj and timeObj.year and timeObj.month and timeObj.day and timeObj.year > 1980 then
        return string.format("%d-%02d-%02d", timeObj.year, timeObj.month, timeObj.day)
      end
    end
    return nil
  end)
  
  if success and dateStr then
    return dateStr
  end
  
  -- Fallback: Try to format timestamp as readable date
  local fallbackSuccess, fallbackDate = pcall(function()
    -- Convert timestamp to approximate date (assuming Unix timestamp)
    local days = math.floor(timestamp / 86400)
    local years = math.floor(days / 365.25)
    local remainingDays = days - math.floor(years * 365.25)
    local months = math.floor(remainingDays / 30.44)
    local dayOfMonth = remainingDays - math.floor(months * 30.44)
    
    return string.format("~%04d-%02d-%02d", 1970 + years, math.max(1, months), math.max(1, dayOfMonth))
  end)
  
  if fallbackSuccess and fallbackDate then
    return fallbackDate
  else
    return string.format("Time_%d", timestamp)
  end
end

-- Format rent amount
local function formatRent(amount)
  if not amount or amount == 0 then
    return "0g"
  end
  
  -- Format with commas for large numbers
  local str = tostring(math.floor(amount))
  str = str:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  if str:sub(1,1) == "," then str = str:sub(2) end
  return str .. "g"
end

-- Get current real date string using game's time API
local function getCurrentDateString()
  -- Use api.Time:GetLocalTime() which returns current real time
  if api and api.Time and api.Time.GetLocalTime then
    local localTime = api.Time:GetLocalTime()
    if localTime then
      -- TimeToDate converts the time to a date object
      local success, dateObj = pcall(function()
        return api.Time:TimeToDate(localTime)
      end)
      
      if success and dateObj and dateObj.year and dateObj.year > 2000 then
        return string.format("%04d-%02d-%02d", dateObj.year, dateObj.month, dateObj.day)
      end
    end
  end
  
  -- Fallback: Use TimeSystem if available
  if TimeSystem and TimeSystem.getCurrentTime then
    local currentTime = TimeSystem.getCurrentTime()
    if currentTime and currentTime > 0 then
      return formatDate(currentTime)
    end
  end
  
  -- Final fallback: Show "Today" instead of wrong date
  return "Today"
end

-- Calculate next rent payment date (1 week from given date)
local function calculateNextRent(baseTimestamp)
  if not baseTimestamp or baseTimestamp == 0 then
    return TimeSystem.createDeadline(7) -- 7 days from now
  end
  
  return baseTimestamp + (7 * 86400) -- Add 7 days
end

-- Create a new loan entry.
function LoansSystem.createLoan(playerName, landId, landName, rentAmount)
  loansSeq = loansSeq + 1

  -- rentingSince is stored as a pre-formatted date STRING (e.g.
  -- "2026-05-03"). Was previously TimeSystem.getCurrentTime() which is
  -- session-uptime in seconds (~1234), and formatDate then rendered it as
  -- a 1970 date. The Since column reads the string directly via fmtSince.
  local nowDateStr = getCurrentDateString()

  local loan = {
    id = loansSeq,
    playerName = playerName,
    landId = landId,
    landName = landName,
    rentAmount = tonumber(rentAmount) or 0,
    rentingSince = nowDateStr,
    nextRentDue = 0,        -- 0 = "Not Paid" (the formatter renders gray text)
    totalPaid = 0,
    paymentCount = 0,
    isPaid = false,
    createdAt = nowDateStr,
    note = "",              -- free-form per-loan note shown in the Note dialog
  }
  table.insert(loansData, loan)

  return true
end

-- Mark rent as paid for a loan - FIXED PAYMENT PROGRESSION
function LoansSystem.markRentPaid(loanId)
  
  for _, loan in ipairs(loansData) do
    if loan.id == loanId then
      -- Store old due date for logging
      local oldDueDate = loan.nextRentDue
      local wasFirstPayment = (not loan.nextRentDue or loan.nextRentDue == 0)
      
      -- Use timer addon approach instead of timestamps
      if not loan.nextRentDue or loan.nextRentDue == 0 or type(loan.nextRentDue) == "number" then
        -- First payment or legacy format: create new 7-day countdown timer
        loan.nextRentDue = TimeSystem.createCountdownTimer(7)
        loan.isPaid = true
      else
        -- Existing timer: extend by 7 days (preserve exact timing)
        loan.nextRentDue = TimeSystem.markPaid(loan.nextRentDue)
      end
      
      loan.totalPaid = loan.totalPaid + loan.rentAmount
      loan.paymentCount = loan.paymentCount + 1

      return true
    end
  end
  
  return false
end

-- Set a per-loan free-form note. Persists with the loan, isn't shown in
-- the row — only revealed when the user clicks the Note button.
function LoansSystem.setLoanNote(loanId, noteText)
  for _, loan in ipairs(loansData) do
    if loan.id == loanId then
      loan.note = noteText or ""
      LoansSystem.saveLoans()
      return true
    end
  end
  return false
end

function LoansSystem.getLoanNote(loanId)
  for _, loan in ipairs(loansData) do
    if loan.id == loanId then
      return loan.note or ""
    end
  end
  return ""
end

-- Wipe a loan's payment timer back to "Not Paid" without deleting the loan
-- itself. Used by the per-row Reset button when a payment was logged in
-- error or when starting a fresh billing cycle.
function LoansSystem.resetPayment(loanId)
  for _, loan in ipairs(loansData) do
    if loan.id == loanId then
      loan.nextRentDue = 0
      loan.isPaid = false
      return true
    end
  end
  return false
end

-- Mark a loan as overdue (starts countup timer like land tax overdue)
function LoansSystem.markOverdue(loanId)
  for _, loan in ipairs(loansData) do
    if loan.id == loanId then
      loan.nextRentDue = TimeSystem.markUnpaid()
      loan.isPaid = false
      return true
    end
  end
  return false
end

-- Delete a loan entry
function LoansSystem.deleteLoan(loanId)
  for i, loan in ipairs(loansData) do
    if loan.id == loanId then
      table.remove(loansData, i)
      return true
    end
  end
  return false
end

-- Delete all loans associated with a land (called when land is deleted)
function LoansSystem.deleteLoansForLand(landIdOrName)
  if not landIdOrName then return 0 end
  local deletedCount = 0
  for i = #loansData, 1, -1 do
    local loan = loansData[i]
    if loan.landId == landIdOrName or loan.landName == landIdOrName then
      table.remove(loansData, i)
      deletedCount = deletedCount + 1
    end
  end
  if deletedCount > 0 then
    LoansSystem.saveLoans()
  end
  return deletedCount
end

-- Get loan data for display
function LoansSystem.getLoansData()
  return loansData
end

-- Persist loans data
function LoansSystem.saveLoans()
  local settings = api.GetSettings("tax_tracker") or {}
  settings.loansData = loansData
  settings.loansSeq = loansSeq
  settings.loansSaveVersion = "1.0_SERVER_TIME"
  
  local success = pcall(function() api.SaveSettings() end)
  if not success then
    api.Log:Err("[Loans] Failed to save loan data")
  end
end

-- Load loans data
function LoansSystem.loadLoans()
  local settings = api.GetSettings("tax_tracker") or {}
  local loadedLoans = settings.loansData or {}
  local loadedSeq = settings.loansSeq or 0
  
  loansData = {}
  for _, loan in ipairs(loadedLoans) do
    if loan.id and loan.playerName and loan.landName then
      -- rentingSince is now a date STRING ("2026-05-03"); legacy entries
      -- may still be numeric. Comparing string < number throws a Lua error
      -- (this was wiping every loan on reload because loadLoans is pcall'd
      -- and the failure was silent). Only run the numeric "fix" when the
      -- stored value really is a number.
      if loan.rentingSince == nil or loan.rentingSince == "" then
        loan.rentingSince = getCurrentDateString()
      elseif type(loan.rentingSince) == "number" and loan.rentingSince < 86400 then
        loan.rentingSince = getCurrentDateString()
      end

      -- Don't validate nextRentDue if it's already in timer format OR if it's 0 (Not Paid)
      if type(loan.nextRentDue) == "number" and loan.nextRentDue ~= 0 then
        loan.nextRentDue = TimeSystem.validateTimestamp(loan.nextRentDue, "Loan-" .. loan.playerName)
      end

      loan.createdAt = loan.createdAt or loan.rentingSince
      loan.totalPaid = loan.totalPaid or 0
      loan.paymentCount = loan.paymentCount or 0
      loan.note = loan.note or ""
      loan.isPaid = loan.isPaid or (loan.nextRentDue ~= 0 and loan.nextRentDue ~= nil)

      table.insert(loansData, loan)
    end
  end
  
  loansSeq = loadedSeq
  if loansSeq == 0 then
    for _, loan in ipairs(loansData) do
      if loan.id and loan.id > loansSeq then
        loansSeq = loan.id
      end
    end
  end
end

-- Open (and lazily build) the per-loan note dialog. Builds the window
-- once and reuses it for every loan; the editbox is just re-populated
-- with that loan's stored note when opened. Saving writes back to the
-- loan via setLoanNote.
local function openLoanNoteDialog(loan)
  if not loan then return end

  if not noteWin then
    destroyOrphanByName("TaxTrackerLoanNote")

    local ok, err = pcall(function()
      local W, H = 420, 260
      noteWin = api.Interface:CreateWindow("TaxTrackerLoanNote", "Loan Note", 0, 0)
      noteWin:SetExtent(W, H)
      noteWin:AddAnchor("CENTER", "UIParent", 0, 0)
      addTint(noteWin, "noteBg", 0.85, 36)
      noteWin:Show(false)

      local hdr = noteWin:CreateChildWidget("label", "noteHeader", 0, true)
      hdr:SetText("Note:")
      hdr:AddAnchor("TOPLEFT", noteWin, 30, 50)

      if W_CTRL and W_CTRL.CreateMultiLineEdit then
        noteEdit = W_CTRL.CreateMultiLineEdit("noteEdit", noteWin)
        noteEdit:SetExtent(W - 60, 120)
        noteEdit:AddAnchor("TOPLEFT", noteWin, 30, 75)
        pcall(function() noteEdit:SetMaxTextLength(2000) end)
      else
        noteEdit = gui.AddEditBox(noteWin, "noteEdit",
          "TOPLEFT", noteWin, 30, 75, W - 60, 120, 1024, "", nil)
        pcall(function()
          if noteEdit.style and noteEdit.style.SetAlign then
            noteEdit.style:SetAlign(ALIGN.TOPLEFT)
          end
        end)
      end

      local saveBtn = noteWin:CreateChildWidget("button", "noteSaveBtn", 0, true)
      api.Interface:ApplyButtonSkin(saveBtn, BUTTON_BASIC.DEFAULT)
      saveBtn:SetText("Save")
      saveBtn:SetExtent(100, 28)
      saveBtn:AddAnchor("BOTTOM", noteWin, -60, -20)
      function saveBtn:OnClick()
        local txt = (noteEdit and noteEdit.GetText and noteEdit:GetText()) or ""
        LoansSystem.setLoanNote(noteCurrentLoanId, txt)
        noteWin:Show(false)
      end
      saveBtn:SetHandler("OnClick", saveBtn.OnClick)

      local cancelBtn = noteWin:CreateChildWidget("button", "noteCancelBtn", 0, true)
      api.Interface:ApplyButtonSkin(cancelBtn, BUTTON_BASIC.DEFAULT)
      cancelBtn:SetText("Cancel")
      cancelBtn:SetExtent(100, 28)
      cancelBtn:AddAnchor("BOTTOM", noteWin, 60, -20)
      function cancelBtn:OnClick() noteWin:Show(false) end
      cancelBtn:SetHandler("OnClick", cancelBtn.OnClick)
    end)

    if not ok then
      api.Log:Err("[Tax Tracker] Note dialog build failed: " .. tostring(err))
      destroyWidget(noteWin)
      noteWin = nil
      noteEdit = nil
      return
    end
  end

  noteCurrentLoanId = loan.id or 0
  pcall(function() noteWin:SetTitle(string.format("Note: %s", loan.playerName or "Loan")) end)
  if noteEdit and noteEdit.SetText then
    pcall(function() noteEdit:SetText(loan.note or "") end)
  end
  local showOk = pcall(function() noteWin:Show(true) end)
  if not showOk then
    -- Window got destroyed under us; clear refs so next click rebuilds.
    noteWin = nil
    noteEdit = nil
  end
end

-- Build the loans window. Layout: input form across the top, list on the
-- left, totals panel on the right.
function LoansSystem.buildLoansWindow(savedLandsList)
  if loansWin and loansWin.Show then
    return -- Don't show here, let showLoansWindow handle it
  end

  -- Window proportions: reduced panel to give more space to Land column
  -- Land column widened to 290 (was 220), taking space from summary panel
  local WIN_W, WIN_H = 1490, 720
  local LIST_W = 1200
  local PANEL_W = 190
  local PANEL_GAP = 55

  loansWin = api.Interface:CreateWindow("TaxTrackerLoans", "Land Loans & Rentals", 0, 0)
  loansWin:SetExtent(WIN_W, WIN_H)
  loansWin:AddAnchor("CENTER", "UIParent", 0, 0)
  addTint(loansWin, "loansBg", 0.65, 36)
  loansWin:Show(false)

  -- ==================== INPUT SECTION ====================
  local inputY = 50  -- moved up since the old summary header bar was removed
  local COL_LABEL_W = 90

  local function placeLabel(lbl, x, y, w)
    if not lbl then return end
    lbl:RemoveAllAnchors()
    lbl:SetExtent(w or COL_LABEL_W, 24)
    lbl:AddAnchor("TOPLEFT", loansWin, x, y)
    if lbl.style then
      lbl.style:SetAlign(ALIGN.LEFT)
      lbl.style:SetFontSize(FONT_SIZE.MIDDLE or 16)
    end
  end

  local function placeInput(input, x, y, w, h)
    if not input then return end
    input:RemoveAllAnchors()
    input:SetExtent(w, h or 28)
    input:AddAnchor("TOPLEFT", loansWin, x, y)
  end

  -- Player Name input. Pass nil for labelText — AddEditBox builds an extra
  -- ghost label when that's set, which was rendering a stray "Player name"
  -- string overlapping the input.
  gui.AddLabel(loansWin, "playerLabel", "Player:", "TOPLEFT", loansWin, 20, inputY)
  local playerNameInput = gui.AddEditBox(loansWin, "playerNameInput",
    "LEFT", loansWin.playerLabel, 80, 0, 150, 28, 50, "", nil)
  placeLabel(loansWin.playerLabel, 20, inputY + 2, 75)
  placeInput(playerNameInput, 100, inputY, 180, 28)
  loansWin.playerNameInput = playerNameInput
  
  -- Renting Since (auto-generated, read-only)
  gui.AddLabel(loansWin, "rentingSinceLabel", "Renting Since:", "LEFT", playerNameInput, 170, 0)
  local rentingSinceDisplay = gui.AddEditBox(loansWin, "rentingSinceDisplay",
    "LEFT", loansWin.rentingSinceLabel, 100, 0, 120, 28, nil, "", nil)
  placeLabel(loansWin.rentingSinceLabel, 315, inputY + 2, 105)
  placeInput(rentingSinceDisplay, 425, inputY, 130, 28)
  if rentingSinceDisplay.SetReadOnly then rentingSinceDisplay:SetReadOnly(true) end
  rentingSinceDisplay:SetText(getCurrentDateString())
  loansWin.rentingSinceDisplay = rentingSinceDisplay
  
  -- Land dropdown (populated from saved lands) - FIXED
  local row2Y = inputY + 42
  gui.AddLabel(loansWin, "landLabel", "Land:", "TOPLEFT", loansWin, 20, row2Y + 2)
  placeLabel(loansWin.landLabel, 20, row2Y + 2, 75)

  -- Create hierarchical land dropdown with zone grouping
  local selectedLandId = 0
  local selectedLandName = ""
  local selectedLandZone = ""
  local landDropdown = nil
  
  local function createHierarchicalLandData()
    local hierarchicalData = {}
    local zoneGroups = {}
    
    -- Group available lands by zone
    if savedLandsList and #savedLandsList > 0 then
      for _, land in ipairs(savedLandsList) do
        -- Check if this land is already used in a loan (NON-REUSABLE)
        local landAlreadyUsed = false
        for _, loan in ipairs(loansData) do
          if loan.landId == land.id then
            landAlreadyUsed = true
            break
          end
        end
        -- Only add lands that are NOT already used
        if not landAlreadyUsed then
          local zoneName = land.zoneName or "Unknown Zone"
          if not zoneGroups[zoneName] then
            zoneGroups[zoneName] = {}
          end
          table.insert(zoneGroups[zoneName], land)
        end
      end
    end

    -- Build hierarchical items in the shape HierarchicalDropdown expects:
    -- {name, tier, value, ...} keyed fields. The previous version used
    -- positional arrays {zoneName, "zone_N"} which left the keyed fields
    -- nil — that's why every entry rendered as "Unknown".
    local zoneIndex = 1
    for zoneName, lands in pairs(zoneGroups) do
      table.insert(hierarchicalData, {
        id = "zone_" .. zoneIndex,
        name = zoneName,
        tier = 0,
        expanded = false,
        value = "zone_" .. zoneIndex,
      })
      for _, land in ipairs(lands) do
        table.insert(hierarchicalData, {
          id = "land_" .. tostring(land.id or land.name),
          name = land.name or "Unnamed",
          tier = 1,
          value = tostring(land.id or "?"),
          landData = land,
        })
      end
      zoneIndex = zoneIndex + 1
    end
    if #hierarchicalData == 0 then
      table.insert(hierarchicalData, {
        id = "fallback",
        name = "No lands available",
        tier = 0,
        value = "fallback",
      })
    end
    return hierarchicalData
  end
  
  local function refreshLandDropdown()
    if landDropdown and landDropdown.UpdateData then
      local newData = createHierarchicalLandData()
      landDropdown:UpdateData(newData)
    end
  end
  
  -- Expose for external access (used by updateLoansList)
  LoansSystem.refreshLandDropdown = refreshLandDropdown
  
  -- Create hierarchical dropdown for lands
  if HierarchicalDropdown then
    local initialData = createHierarchicalLandData()
    landDropdown = HierarchicalDropdown.create(
      loansWin,
      "landDropdown",
      500,
      initialData,
      "Select Land",
      function(value, displayName, landData)
        -- HierarchicalDropdown passes the matched item's landData as the
        -- third arg. Use it directly instead of searching initialData —
        -- which would go stale every time refreshLandDropdown swapped in
        -- a new list, leaving the Add Loan button's "select a land" guard
        -- permanently failing.
        if landData then
          selectedLandId = landData.id or 0
          selectedLandName = landData.name or ""
          selectedLandZone = landData.zoneName or landData.zone or ""
        end
      end,
      300
    )
    landDropdown:RemoveAllAnchors()
    landDropdown:AddAnchor("TOPLEFT", loansWin, 100, row2Y)
    loansWin.landDropdown = landDropdown
  else
    -- Fallback to simple dropdown if hierarchical not available
    landDropdown = loansWin:CreateChildWidget("button", "landDropdown", 0, true)
    api.Interface:ApplyButtonSkin(landDropdown, BUTTON_BASIC.DEFAULT)
    landDropdown:SetExtent(500, 28)
    landDropdown:AddAnchor("TOPLEFT", loansWin, 100, row2Y)
    landDropdown:SetText("Select Land ▾")
    loansWin.landDropdown = landDropdown
  end
  -- Rent Amount input - positioned inline with dropdown
  -- Land dropdown is 400 wide. Anchored "LEFT" with offset 370 puts the
  -- "Rent:" label 30px BEFORE the dropdown's right edge — visually inside
  -- the dropdown box. Bump offset to 420 (dropdown width 400 + 20 gap).
  gui.AddLabel(loansWin, "rentLabel", "Rent:", "TOPLEFT", loansWin, 625, row2Y + 2)
  placeLabel(loansWin.rentLabel, 625, row2Y + 2, 50)
  -- nil labelText avoids the AddEditBox ghost-label bug.
  local rentAmountInput = gui.AddEditBox(loansWin, "rentAmountInput",
    "LEFT", loansWin.rentLabel, 50, 0, 100, 28, 10, "0", nil)
  placeInput(rentAmountInput, 680, row2Y, 110, 28)
  loansWin.rentAmountInput = rentAmountInput
  
  local addLoanBtn = loansWin:CreateChildWidget("button", "addLoanBtn", 0, true)
  api.Interface:ApplyButtonSkin(addLoanBtn, BUTTON_BASIC.DEFAULT)
  addLoanBtn:SetText("ADD LOAN")
  addLoanBtn:SetExtent(120, 32)
  addLoanBtn:AddAnchor("TOPLEFT", loansWin, 810, row2Y - 2)
  
  -- Status label for click-feedback. Anchored just below the list with
  -- a fixed width so long messages ("Added loan: VeryLongPlayerName -> ...")
  -- can't overflow past the right edge of the window.
  local statusLabel = loansWin:CreateChildWidget("label", "loansStatusLabel", 0, true)
  statusLabel:SetText("")
  statusLabel:SetExtent(LIST_W, 22)
  statusLabel:AddAnchor("BOTTOMLEFT", loansWin, 10, -12)
  if statusLabel.style then
    statusLabel.style:SetFontSize(FONT_SIZE.MIDDLE)
    if statusLabel.style.SetAlign then statusLabel.style:SetAlign(ALIGN.LEFT) end
  end
  loansWin.statusLabel = statusLabel

  local function setStatus(msg, r, g, b)
    if statusLabel then
      statusLabel:SetText(msg or "")
      if statusLabel.style and statusLabel.style.SetColor then
        statusLabel.style:SetColor(r or 1, g or 1, b or 1, 1)
      end
    end
  end

  function addLoanBtn:OnClick()
    local playerName = playerNameInput:GetText() or ""
    local rentAmount = tonumber(rentAmountInput:GetText() or "0") or 0

    if playerName == "" then
      setStatus("Please enter a player name.", 1, 0.5, 0.5)
      return
    end
    if selectedLandId == 0 then
      setStatus("Please pick a land from the dropdown.", 1, 0.5, 0.5)
      return
    end
    if rentAmount <= 0 then
      setStatus("Please enter a rent amount > 0.", 1, 0.5, 0.5)
      return
    end

    local fullLandName = string.format("%s (%s)", selectedLandName or "Unknown", selectedLandZone or "Unknown Zone")
    local ok = LoansSystem.createLoan(playerName, selectedLandId, fullLandName, rentAmount)
    if not ok then
      setStatus("Failed to create loan.", 1, 0.4, 0.4)
      return
    end

    setStatus(string.format("Added loan: %s -> %s (%dg)", playerName, selectedLandName or "?", rentAmount), 0.5, 1, 0.5)

    playerNameInput:SetText("")
    rentAmountInput:SetText("0")
    rentingSinceDisplay:SetText(getCurrentDateString())
    if landDropdown and landDropdown.SetText then
      landDropdown:SetText("Select Land")
    end

    if loansItemList then
      loansItemList:UpdateData(loansData)
      if LoansSystem.updateLoansSum then LoansSystem.updateLoansSum() end
    end
    refreshLandDropdown()
    LoansSystem.saveLoans()
  end
  addLoanBtn:SetHandler("OnClick", addLoanBtn.OnClick)
  -- Reset button in top right
  local resetBtn = loansWin:CreateChildWidget("button", "resetBtn", 0, true)
  api.Interface:ApplyButtonSkin(resetBtn, BUTTON_BASIC.MINUS or BUTTON_BASIC.DEFAULT)
  resetBtn:SetText("DEL ALL")
  resetBtn:SetExtent(100, 32)
  resetBtn:AddAnchor("TOPRIGHT", loansWin, -16, 50)
  
  function resetBtn:OnClick()
    -- Was a no-op: pushed the existing loansData into the list without
    -- clearing it first, so nothing changed.
    if #loansData == 0 then return end

    for i = #loansData, 1, -1 do loansData[i] = nil end
    loansSeq = 0

    if loansItemList then
      loansItemList:UpdateData(loansData)
    end
    if LoansSystem.updateLoansSum then LoansSystem.updateLoansSum() end
    refreshLandDropdown()
    LoansSystem.saveLoans()

    if loansWin and loansWin.statusLabel then
      loansWin.statusLabel:SetText("All loans cleared.")
      if loansWin.statusLabel.style and loansWin.statusLabel.style.SetColor then
        loansWin.statusLabel.style:SetColor(1, 0.85, 0.4, 1)
      end
    end
  end
  resetBtn:SetHandler("OnClick", resetBtn.OnClick)

  -- ==================== LIST SECTION ====================
  local listY = 138  -- clear gap below the two-line input area

  -- rentingSince is now stored as a "YYYY-MM-DD" string at creation time,
  -- but legacy data may still be a numeric timestamp — handle both.
  local function fmtSince(stored)
    if type(stored) == "string" and stored ~= "" then return stored end
    if not stored or stored == 0 then return "-" end
    return formatDate(stored)
  end

  -- Columns. These use setFunc/layoutFunc — the ScrollList engine ignores
  -- the setFormatter/createCell keys this file used to use, so previously
  -- nothing was rendering and rows looked blank when added.
  local columns = {
    { name="ID", field="id", width=40,
      setFunc=function(s,i,set) if set then s:SetText(tostring(i.id or "")) end end },
    { name="Player", field="playerName", width=130,
      setFunc=function(s,i,set) if set then s:SetText(i.playerName or "") end end },
    { name="Land", field="landName", width=290,
      setFunc=function(s,i,set) if set then s:SetText(i.landName or "") end end },
    { name="Rent", field="rentAmount", width=70,
      setFunc=function(s,i,set) if set then s:SetText(formatRent(i.rentAmount or 0)) end end },
    { name="Since", field="rentingSince", width=110,
      setFunc=function(s,i,set) if set then s:SetText(fmtSince(i.rentingSince)) end end },
    { name="Next Due", field="nextRentDue", width=200,
      setFunc=function(s, i, set)
        if not set then return end
        if not i.nextRentDue or i.nextRentDue == 0 then
          s:SetText("Not Paid")
          if s.style and s.style.SetColor then
            s.style:SetColor(0.8, 0.8, 0.8, 1.0)
          end
        else
          local timerDisplay = TimeSystem.formatCountdown(i.nextRentDue)
          s:SetText(timerDisplay)
          local color = TimeSystem.getTimeColor(i.nextRentDue)
          if s.style and s.style.SetColor then
            if timerDisplay and timerDisplay:find("OVERDUE:") then
              s.style:SetColor(1.0, 0.2, 0.2, 1.0)
            else
              s.style:SetColor(color[1], color[2], color[3], color[4])
            end
          end
        end
      end
    },
    { name="Total Paid", field="totalPaid", width=80,
      setFunc=function(s,i,set) if set then s:SetText(formatRent(i.totalPaid or 0)) end end },
    { name="Actions", width=340, disableSort=true,
      setFunc = function(s, i, set)
        if s.paidBtn  then s.paidBtn:Show(set)  end
        if s.overdueBtn then s.overdueBtn:Show(set) end
        if s.noteBtn  then s.noteBtn:Show(set)  end
        if s.delBtn   then s.delBtn:Show(set)   end
      end,
      layoutFunc = function(list, row, col, cell)
        -- Paid button - FIXED with proper list reference
        local paidBtn = cell:CreateChildWidget("button", cell:GetId()..".paid", 0, true)
        api.Interface:ApplyButtonSkin(paidBtn, BUTTON_BASIC.DEFAULT)
        paidBtn:SetText("Paid")
        paidBtn:SetExtent(70, 22)
        paidBtn:AddAnchor("LEFT", cell, 2, 0)
        function paidBtn:OnClick()

          -- Use direct array access - more reliable than GetRowData
          local loan = loansData[row]
          if loan then
            if LoansSystem.markRentPaid(loan.id) then
              -- Use global list reference instead of parameter
              loansItemList:UpdateData(loansData)
              if LoansSystem.updateLoansSum then LoansSystem.updateLoansSum() end
              LoansSystem.saveLoans()
            end
          else
          end
        end
        paidBtn:SetHandler("OnClick", paidBtn.OnClick)
        cell.paidBtn = paidBtn

        -- Overdue button — marks the loan as overdue (countup timer like land tax)
        local overdueBtn = cell:CreateChildWidget("button", cell:GetId()..".overdue", 0, true)
        api.Interface:ApplyButtonSkin(overdueBtn, BUTTON_BASIC.DEFAULT)
        overdueBtn:SetText("Overdue")
        overdueBtn:SetExtent(70, 22)
        overdueBtn:AddAnchor("LEFT", paidBtn, "RIGHT", 6, 0)
        function overdueBtn:OnClick()
          local loan = loansData[row]
          if loan and LoansSystem.markOverdue(loan.id) then
            loansItemList:UpdateData(loansData)
            if LoansSystem.updateLoansSum then LoansSystem.updateLoansSum() end
            LoansSystem.saveLoans()
          end
        end
        overdueBtn:SetHandler("OnClick", overdueBtn.OnClick)
        cell.overdueBtn = overdueBtn

        -- Note button — opens the shared note dialog populated with this
        -- loan's stored note (or empty for the first time).
        local noteBtn = cell:CreateChildWidget("button", cell:GetId()..".note", 0, true)
        api.Interface:ApplyButtonSkin(noteBtn, BUTTON_BASIC.DEFAULT)
        noteBtn:SetText("Note")
        noteBtn:SetExtent(50, 22)
        noteBtn:AddAnchor("LEFT", overdueBtn, "RIGHT", 6, 0)
        function noteBtn:OnClick()
          local loan = loansData[row]
          if loan then openLoanNoteDialog(loan) end
        end
        noteBtn:SetHandler("OnClick", noteBtn.OnClick)
        cell.noteBtn = noteBtn

        -- Delete button
        local delBtn = cell:CreateChildWidget("button", cell:GetId()..".del", 0, true)
        api.Interface:ApplyButtonSkin(delBtn, BUTTON_BASIC.MINUS or BUTTON_BASIC.DEFAULT)
        delBtn:SetText("DEL")
        delBtn:SetExtent(70, 22)
        delBtn:AddAnchor("LEFT", noteBtn, "RIGHT", 6, 0)
        
        function delBtn:OnClick()
          
          -- Use direct array access - more reliable than GetRowData  
          local loan = loansData[row]
          if loan then
            if LoansSystem.deleteLoan(loan.id) then
              -- Use global list reference instead of parameter
              loansItemList:UpdateData(loansData)
              if LoansSystem.updateLoansSum then LoansSystem.updateLoansSum() end
              
              -- Refresh dropdown to show the now-available land
              refreshLandDropdown()
              
              LoansSystem.saveLoans()
            end
          else
          end
        end
        delBtn:SetHandler("OnClick", delBtn.OnClick)
        cell.delBtn = delBtn

        paidBtn:Show(false)
        overdueBtn:Show(false)
        noteBtn:Show(false)
        delBtn:Show(false)
      end
    }
  }

  loansItemList = gui.AddScrollList(
    loansWin, "loansItemList", columns,
    { point="TOPLEFT", relativeTo=loansWin, offsetX=10, offsetY=listY },
    { width=LIST_W, height=WIN_H - listY - 30 },
    { listType=3, rowCount=15, columnHeight=26, enableColumns=true }
  )

  loansItemList:UpdateData(loansData)

  -- ==================== RIGHT-SIDE SUMMARY PANEL ====================
  -- Replaces the old top-header strip and bottom-footer strip. All totals
  -- now live in one column to the right of the list.
  local panelBg = loansWin:CreateChildWidget("emptywidget", "panelBg", 0, true)
  panelBg:SetExtent(PANEL_W, WIN_H - listY - 30)
  panelBg:AddAnchor("TOPLEFT", loansWin, 10 + LIST_W + PANEL_GAP, listY)
  if panelBg.SetColor then panelBg:SetColor(0.1, 0.15, 0.2, 0.85) end

  local function panelLabel(name, text, yOff, color)
    local lbl = loansWin:CreateChildWidget("label", name, 0, true)
    lbl:SetText(text)
    lbl:SetExtent(PANEL_W - 28, 24)
    lbl:AddAnchor("TOPLEFT", panelBg, 16, yOff)
    if lbl.style then
      lbl.style:SetFontSize(FONT_SIZE.MIDDLE or 16)
      lbl.style:SetAlign(ALIGN.LEFT)
      if color and lbl.style.SetColor then
        lbl.style:SetColor(color[1], color[2], color[3], 1)
      end
    end
    return lbl
  end

  -- Header for the panel
  local panelTitle = panelLabel("loansPanelTitle", "Summary", 14)

  -- Defaults to engine color; only Total received (gold) and Overdue (red
  -- when positive) get explicit coloring. Weekly income removed — duplicated
  -- the "Weekly" line above it.
  local GOLD = {1.0, 0.85, 0.0}
  loansWin.currentDateLabel  = panelLabel("currentDateLabel",  "Today: " .. getCurrentDateString(), 50)
  loansWin.activeLoansLabel  = panelLabel("activeLoansLabel",  "Active loans: 0",                    90)
  loansWin.totalRentLabel    = panelLabel("totalRentLabel",    "Monthly: 0g",                       125)
  loansWin.weeklyHeaderLabel = panelLabel("weeklyHeaderLabel", "Weekly: 0g",                        160)
  loansWin.loansSumLabel     = panelLabel("loansSumLabel",     "Total received: 0g",                200, GOLD)
  loansWin.overdueLabel      = panelLabel("overdueLabel",      "Overdue: 0",                        240)
  
  -- Recompute all summary panel values. The previous version had empty
  -- bodies inside every accumulator branch (`if loan.totalPaid then end`)
  -- so totals stayed at 0 forever even when loans existed.
  local function updateLoansSum()
    local totalPaid = 0
    local weeklyIncome = 0
    local activeCount = 0
    local overdueCount = 0

    if loansData and type(loansData) == "table" then
      for _, loan in ipairs(loansData) do
        local paid = tonumber(loan.totalPaid) or 0
        local rent = tonumber(loan.rentAmount) or 0
        totalPaid = totalPaid + paid
        weeklyIncome = weeklyIncome + rent
        activeCount = activeCount + 1
        if loan.nextRentDue and loan.nextRentDue ~= 0 then
          if TimeSystem.isOverdue(loan.nextRentDue) then
            overdueCount = overdueCount + 1
          end
        end
      end
    end

    if loansWin.loansSumLabel    then loansWin.loansSumLabel:SetText("Total received: " .. formatRent(totalPaid)) end
    if loansWin.activeLoansLabel then loansWin.activeLoansLabel:SetText("Active loans: " .. activeCount) end
    if loansWin.totalRentLabel    then loansWin.totalRentLabel:SetText("Monthly: " .. formatRent(weeklyIncome * 4)) end
    if loansWin.weeklyHeaderLabel then loansWin.weeklyHeaderLabel:SetText("Weekly: " .. formatRent(weeklyIncome)) end

    if loansWin.overdueLabel then
      loansWin.overdueLabel:SetText("Overdue: " .. overdueCount)
      if loansWin.overdueLabel.style and loansWin.overdueLabel.style.SetColor then
        if overdueCount > 0 then
          loansWin.overdueLabel.style:SetColor(1, 0.3, 0.3, 1)
        else
          loansWin.overdueLabel.style:SetColor(0.4, 1, 0.4, 1)
        end
      end
    end

    if loansWin.currentDateLabel then
      loansWin.currentDateLabel:SetText("Today: " .. getCurrentDateString())
    end
  end
  
  -- Store function reference for external access
  LoansSystem.updateLoansSum = updateLoansSum
  
  -- Initial sum calculation
  updateLoansSum()
end

-- Show the loans window
function LoansSystem.showLoansWindow(savedLandsList)
  if not loansWin then
    LoansSystem.buildLoansWindow(savedLandsList)
    -- Give the window a moment to fully initialize before showing
    if loansWin then
      loansWin:Show(true)
      return -- Early return to avoid double show
    end
  else
    loansWin:Show(true)
  end
end

-- Hide the loans window
function LoansSystem.hideLoansWindow()
  if loansWin then
    loansWin:Show(false)
  end
end

-- Update loans list (for real-time updates) - ENHANCED FORCE UPDATE
function LoansSystem.updateLoansList(savedLandsData)
  if loansWin and loansItemList then
    pcall(function()
      -- Check if loan entries still exist in saved lands and remove invalid ones
      local validLoans = {}
      local removedCount = 0
      local updatedCount = 0
      
      for i, loan in ipairs(loansData) do
        local landStillExists = false
        
        -- Keep loan.landName in sync with the underlying land. Reformat as
        -- "Name (Zone)" — the previous version overwrote with just land.name
        -- which stripped the zone suffix the user wanted to keep visible.
        if loan.landId and loan.landId > 0 and savedLandsData then
          for _, land in ipairs(savedLandsData) do
            if land.id == loan.landId then
              local zoneStr = land.zoneName or land.zone or "Unknown Zone"
              local newName = string.format("%s (%s)", land.name or "Unnamed", zoneStr)
              if newName ~= loan.landName then
                loan.landName = newName
              end
              break
            end
          end
        end
        if landStillExists then
          -- Update overdue status for valid loans
          loan.isOverdue = TimeSystem.isOverdue(loan.nextRentDue)
          table.insert(validLoans, loan)
        else
        end
      end
      
      -- Update the loans data and save if any changes were made
      local needsSave = (removedCount > 0 or updatedCount > 0)
      if needsSave then
        -- Save the updated loans data
        LoansSystem.saveLoans()
      end
      
      -- Only update list display if window is visible
      if loansWin:IsVisible() then
        loansItemList:UpdateData(loansData)
        if LoansSystem.updateLoansSum then LoansSystem.updateLoansSum() end
        if loansItemList.UpdateView then
          loansItemList:UpdateView()
        end
        
        -- Also update the "Renting Since" display for new entries
        if loansWin.rentingSinceDisplay then
          loansWin.rentingSinceDisplay:SetText(getCurrentDateString())
        end
      end
      
      -- Always refresh land dropdown when lands change (even if window is hidden)
      -- This ensures the dropdown is up-to-date when user opens the loans window
      if LoansSystem.refreshLandDropdown then
        LoansSystem.refreshLandDropdown()
      end
    end)
  end
end

function LoansSystem.init()
  -- A previous load may have left the loans window alive; wipe it before we
  -- create a new one so they don't pile up.
  destroyOrphanByName("TaxTrackerLoans")
  LoansSystem.loadLoans()
end

function LoansSystem.cleanup()
  LoansSystem.saveLoans()
  destroyWidget(loansWin)
  destroyWidget(noteWin)
  loansWin = nil
  loansItemList = nil
  noteWin = nil
  noteEdit = nil
end

-- Initialize function required by main.lua
function LoansSystem.initialize()
  LoansSystem.init()
  return true
end

return LoansSystem
