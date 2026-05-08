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
local loansPage = 1
local LOANS_PER_PAGE = 15
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

local UI = {
  WHITE = {1, 1, 1, 1},
  MUTED = {0.72, 0.72, 0.72, 1},
  GOLD = {1, 0.84, 0, 1},
  GREEN = {0.12, 0.28, 0.15, 0.95},
  RED = {0.24, 0.09, 0.09, 0.95},
  BUTTON = {0.16, 0.16, 0.18, 0.92},
  BUTTON_DARK = {0.11, 0.11, 0.13, 0.92},
  BUTTON_BLUE = {0.14, 0.17, 0.22, 0.95},
  PANEL = {0.05, 0.05, 0.06, 0.55},
  PANEL_DARK = {0.035, 0.035, 0.045, 0.68},
  INPUT = {0.11, 0.11, 0.125, 0.72},
  LIST_PANEL = {0.05, 0.05, 0.06, 0.36},
  HEADER = {0.09, 0.09, 0.11, 0.95},
  GROUP_DETAILS = {0.07, 0.07, 0.08, 0.74},
  GROUP_MONEY = {0.055, 0.06, 0.07, 0.74},
  GROUP_STATUS = {0.065, 0.065, 0.075, 0.74},
  ROW_ODD = {0.08, 0.08, 0.095, 0.72},
  ROW_EVEN = {0.12, 0.12, 0.135, 0.72},
  STATUS = {0.04, 0.04, 0.05, 0.72}
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

local function addColorPanel(parent, id, x, y, width, height, color)
  if not (parent and parent.CreateColorDrawable) then return nil end
  local c = color or UI.PANEL
  local bg = parent:CreateColorDrawable(c[1], c[2], c[3], c[4] or 0.55, "background")
  bg:SetExtent(width, height)
  bg:AddAnchor("TOPLEFT", parent, x, y)
  bg:Show(true)
  return bg
end

local function addWidgetPanel(parent, id, x, y, width, height, color)
  if not (parent and parent.CreateChildWidget) then return nil end
  local c = color or UI.PANEL
  local panel = parent:CreateChildWidget("emptywidget", id, 0, true)
  panel:SetExtent(width, height)
  panel:AddAnchor("TOPLEFT", parent, x, y)
  if panel.EnableMouse then panel:EnableMouse(false) end
  local bg = panel:CreateColorDrawable(c[1], c[2], c[3], c[4] or 0.55, "background")
  bg:AddAnchor("TOPLEFT", panel, 0, 0)
  bg:AddAnchor("BOTTOMRIGHT", panel, 0, 0)
  bg:Show(true)
  panel:Show(true)
  return panel
end

local function addInputBackplate(parent, id, x, y, width, height)
  return addColorPanel(parent, id, x - 2, y - 1, width + 4, height + 2, UI.INPUT)
end

local function styleEditBox(editbox, muted)
  if not editbox then return end
  if editbox.style then
    if editbox.style.SetFontSize then editbox.style:SetFontSize(12) end
    if editbox.style.SetAlign then editbox.style:SetAlign(ALIGN.LEFT) end
    if editbox.style.SetColor then
      if muted then
        editbox.style:SetColor(UI.MUTED[1], UI.MUTED[2], UI.MUTED[3], UI.MUTED[4])
      else
        editbox.style:SetColor(UI.WHITE[1], UI.WHITE[2], UI.WHITE[3], UI.WHITE[4])
      end
    end
  end
end

local function getLoanPageCount()
  local count = #loansData
  if count <= 0 then return 1 end
  return math.ceil(count / LOANS_PER_PAGE)
end

local function clampLoanPage(page)
  local maxPage = getLoanPageCount()
  page = tonumber(page) or 1
  if page < 1 then return 1 end
  if page > maxPage then return maxPage end
  return page
end

local function addSectionTitle(parent, id, text, x, y, width)
  if not parent then return nil end
  local title = parent:CreateChildWidget("label", id, 0, true)
  title:SetText(text or "")
  title:SetExtent(width or 200, 18)
  title:AddAnchor("TOPLEFT", parent, x, y)
  if title.style then
    title.style:SetFontSize(13)
    if title.style.SetAlign then title.style:SetAlign(ALIGN.LEFT) end
  end
  setTextColor(title, UI.GOLD)
  title:Show(true)
  return title
end

local function styleLoanCell(cell, loan, visible)
  if not cell then return end
  if not visible then
    if cell.loanRowBg and cell.loanRowBg.Show then cell.loanRowBg:Show(false) end
    return
  end

  if not cell.loanRowBg and cell.CreateColorDrawable then
    local bg = cell:CreateColorDrawable(UI.ROW_ODD[1], UI.ROW_ODD[2], UI.ROW_ODD[3], UI.ROW_ODD[4], "background")
    bg:AddAnchor("TOPLEFT", cell, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", cell, 0, 0)
    bg:Show(true)
    cell.loanRowBg = bg
  end

  local index = tonumber(loan and loan._uiRowIndex) or tonumber(loan and loan.id) or 1
  setDrawableColor(cell.loanRowBg, index % 2 == 0 and UI.ROW_EVEN or UI.ROW_ODD)
  if cell.loanRowBg and cell.loanRowBg.Show then cell.loanRowBg:Show(true) end
end

local function styleFlatButton(button, text, tone)
  if not button then return nil end
  local width = 80
  local height = 22
  pcall(function()
    if button.GetWidth and button:GetWidth() and button:GetWidth() > 0 then width = button:GetWidth() end
    if button.GetHeight and button:GetHeight() and button:GetHeight() > 0 then height = button:GetHeight() end
  end)

  if button.SetText then button:SetText("") end

  if not button.cleanBg and button.CreateColorDrawable then
    local bg = button:CreateColorDrawable(UI.BUTTON[1], UI.BUTTON[2], UI.BUTTON[3], UI.BUTTON[4], "background")
    bg:AddAnchor("TOPLEFT", button, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", button, 0, 0)
    bg:Show(true)
    button.cleanBg = bg
  end

  if not button.cleanLabel then
    local buttonId = "btn"
    pcall(function()
      if button.GetId then buttonId = tostring(button:GetId() or "btn") end
    end)
    local label = button:CreateChildWidget("label", buttonId .. ".cleanLabel", 0, true)
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
    button.cleanLabel:SetText(text or "")
    pcall(function()
      button.cleanLabel:SetExtent(width, math.max(1, height - 2))
    end)
    setTextColor(button.cleanLabel, UI.WHITE)
  end

  setDrawableColor(button.cleanBg, tone or UI.BUTTON)
  return button
end

-- Helper to add tint background to windows
local function addTint(win, id, alpha, topPad)
  if not win then return nil end
  local pad = topPad or 36
  if win.CreateColorDrawable then
    local bg = win:CreateColorDrawable(0.05, 0.05, 0.06, alpha or 0.55, "background")
    bg:AddAnchor("TOPLEFT", win, 0, pad)
    bg:AddAnchor("BOTTOMRIGHT", win, 0, 0)
    bg:Show(true)
    return bg
  end
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
      addTint(noteWin, "noteBg", 0.55, 36)
      addColorPanel(noteWin, "notePanel", 20, 46, W - 40, 156, UI.LIST_PANEL)
      noteWin:Show(false)

      local hdr = addSectionTitle(noteWin, "noteHeader", "Note", 30, 54, W - 60)

      if W_CTRL and W_CTRL.CreateMultiLineEdit then
        addInputBackplate(noteWin, "noteEditBg", 30, 75, W - 60, 120)
        noteEdit = W_CTRL.CreateMultiLineEdit("noteEdit", noteWin)
        noteEdit:SetExtent(W - 60, 120)
        noteEdit:AddAnchor("TOPLEFT", noteWin, 30, 75)
        styleEditBox(noteEdit)
        pcall(function() noteEdit:SetMaxTextLength(2000) end)
      else
        addInputBackplate(noteWin, "noteEditBg", 30, 75, W - 60, 120)
        noteEdit = gui.AddEditBox(noteWin, "noteEdit",
          "TOPLEFT", noteWin, 30, 75, W - 60, 120, 1024, "", nil)
        styleEditBox(noteEdit)
        pcall(function()
          if noteEdit.style and noteEdit.style.SetAlign then
            noteEdit.style:SetAlign(ALIGN.TOPLEFT)
          end
        end)
      end

      local saveBtn = noteWin:CreateChildWidget("button", "noteSaveBtn", 0, true)
      saveBtn:SetExtent(100, 28)
      saveBtn:AddAnchor("BOTTOM", noteWin, -60, -20)
      styleFlatButton(saveBtn, "Save", UI.GREEN)
      function saveBtn:OnClick()
        local txt = (noteEdit and noteEdit.GetText and noteEdit:GetText()) or ""
        LoansSystem.setLoanNote(noteCurrentLoanId, txt)
        noteWin:Show(false)
      end
      saveBtn:SetHandler("OnClick", saveBtn.OnClick)

      local cancelBtn = noteWin:CreateChildWidget("button", "noteCancelBtn", 0, true)
      cancelBtn:SetExtent(100, 28)
      cancelBtn:AddAnchor("BOTTOM", noteWin, 60, -20)
      styleFlatButton(cancelBtn, "Cancel", UI.BUTTON_DARK)
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
  local LIST_W = 1280
  local PANEL_W = 170
  local PANEL_GAP = 20

  loansWin = api.Interface:CreateWindow("TaxTrackerLoans", "Land Loans & Rentals", 0, 0)
  loansWin:SetExtent(WIN_W, WIN_H)
  loansWin:AddAnchor("CENTER", "UIParent", 0, 0)
  addTint(loansWin, "loansBg", 0.55, 36)
  loansWin:Show(false)

  -- ==================== INPUT SECTION ====================
  local inputY = 78
  local COL_LABEL_W = 90
  addWidgetPanel(loansWin, "loansInputBackWindow", 10, 42, WIN_W - 20, 122, UI.PANEL)
  addWidgetPanel(loansWin, "loansInputHeader", 10, 42, WIN_W - 20, 26, UI.HEADER)
  addSectionTitle(loansWin, "loansInputTitle", "Add Loan", 20, 47, 220)
  local row2Y = inputY + 42
  addWidgetPanel(loansWin, "loansFormGroup", 18, inputY - 8, WIN_W - 36, 84, UI.GROUP_DETAILS)

  local function updateLoansPager()
    if not loansWin then return end
    loansPage = clampLoanPage(loansPage)
    local totalPages = getLoanPageCount()
    local total = #loansData
    local startIndex = total > 0 and ((loansPage - 1) * LOANS_PER_PAGE) + 1 or 0
    local endIndex = total > 0 and math.min(startIndex + LOANS_PER_PAGE - 1, total) or 0

    if loansWin.loansPageLabel then
      loansWin.loansPageLabel:SetText(string.format("Showing %d-%d of %d   Page %d/%d", startIndex, endIndex, total, loansPage, totalPages))
    end
    if loansWin.loansPrevBtn and loansWin.loansPrevBtn.Enable then loansWin.loansPrevBtn:Enable(loansPage > 1) end
    if loansWin.loansNextBtn and loansWin.loansNextBtn.Enable then loansWin.loansNextBtn:Enable(loansPage < totalPages) end
  end

  local function refreshLoansList()
    loansPage = clampLoanPage(loansPage)
    for index, loan in ipairs(loansData) do
      loan._uiRowIndex = index
    end
    if loansItemList then
      loansItemList:UpdateData(loansData)
      if loansItemList.RefreshPage then
        loansItemList:RefreshPage(loansPage)
      end
    end
    updateLoansPager()
  end
  LoansSystem.refreshLoansList = refreshLoansList

  local function placeLabel(lbl, x, y, w)
    if not lbl then return end
    lbl:RemoveAllAnchors()
    lbl:SetExtent(w or COL_LABEL_W, 24)
    lbl:AddAnchor("TOPLEFT", loansWin, x, y)
    if lbl.style then
      lbl.style:SetAlign(ALIGN.LEFT)
      lbl.style:SetFontSize(FONT_SIZE.MIDDLE or 16)
    end
    setTextColor(lbl, UI.MUTED)
  end

  local function placeInput(input, x, y, w, h)
    if not input then return end
    input:RemoveAllAnchors()
    input:SetExtent(w, h or 28)
    input:AddAnchor("TOPLEFT", loansWin, x, y)
    styleEditBox(input)
  end

  -- Player Name input. Pass nil for labelText — AddEditBox builds an extra
  -- ghost label when that's set, which was rendering a stray "Player name"
  -- string overlapping the input.
  gui.AddLabel(loansWin, "playerLabel", "Player:", "TOPLEFT", loansWin, 20, inputY)
  addInputBackplate(loansWin, "playerNameInputBg", 100, inputY, 180, 28)
  local playerNameInput = gui.AddEditBox(loansWin, "playerNameInput",
    "LEFT", loansWin.playerLabel, 80, 0, 150, 28, 50, "", nil)
  placeLabel(loansWin.playerLabel, 20, inputY + 2, 75)
  placeInput(playerNameInput, 100, inputY, 180, 28)
  loansWin.playerNameInput = playerNameInput
  
  -- Renting Since (auto-generated, read-only)
  gui.AddLabel(loansWin, "rentingSinceLabel", "Renting Since:", "LEFT", playerNameInput, 170, 0)
  addInputBackplate(loansWin, "rentingSinceDisplayBg", 425, inputY, 130, 28)
  local rentingSinceDisplay = gui.AddEditBox(loansWin, "rentingSinceDisplay",
    "LEFT", loansWin.rentingSinceLabel, 100, 0, 120, 28, nil, "", nil)
  placeLabel(loansWin.rentingSinceLabel, 315, inputY + 2, 105)
  placeInput(rentingSinceDisplay, 425, inputY, 130, 28)
  if rentingSinceDisplay.SetReadOnly then rentingSinceDisplay:SetReadOnly(true) end
  styleEditBox(rentingSinceDisplay, true)
  rentingSinceDisplay:SetText(getCurrentDateString())
  loansWin.rentingSinceDisplay = rentingSinceDisplay
  
  -- Land dropdown (populated from saved lands) - FIXED
  gui.AddLabel(loansWin, "landLabel", "Land:", "TOPLEFT", loansWin, 20, row2Y + 2)
  placeLabel(loansWin.landLabel, 20, row2Y + 2, 75)

  -- Create hierarchical land dropdown with zone grouping
  local selectedLandId = 0
  local selectedLandName = ""
  local selectedLandZone = ""
  local landDropdown = nil

  local function resetSelectedLand()
    selectedLandId = 0
    selectedLandName = ""
    selectedLandZone = ""
    if landDropdown and landDropdown.SetCleanText then
      landDropdown:SetCleanText("Select Land")
    elseif landDropdown and landDropdown.SetText then
      landDropdown:SetText("Select Land")
    end
  end
  
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

      if selectedLandId ~= 0 then
        local selectionStillAvailable = false
        for _, item in ipairs(newData) do
          if item.landData and item.landData.id == selectedLandId then
            selectionStillAvailable = true
            break
          end
        end
        if not selectionStillAvailable then
          resetSelectedLand()
        end
      end
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
      300,
      { cleanStyle = true }
    )
    landDropdown:RemoveAllAnchors()
    landDropdown:AddAnchor("TOPLEFT", loansWin, 100, row2Y)
    loansWin.landDropdown = landDropdown
  else
    -- Fallback to simple dropdown if hierarchical not available
    landDropdown = loansWin:CreateChildWidget("button", "landDropdown", 0, true)
    landDropdown:SetExtent(500, 28)
    landDropdown:AddAnchor("TOPLEFT", loansWin, 100, row2Y)
    styleFlatButton(landDropdown, "Select Land", UI.BUTTON_DARK)
    loansWin.landDropdown = landDropdown
  end
  -- Rent Amount input - positioned inline with dropdown
  -- Land dropdown is 400 wide. Anchored "LEFT" with offset 370 puts the
  -- "Rent:" label 30px BEFORE the dropdown's right edge — visually inside
  -- the dropdown box. Bump offset to 420 (dropdown width 400 + 20 gap).
  gui.AddLabel(loansWin, "rentLabel", "Rent:", "TOPLEFT", loansWin, 625, row2Y + 2)
  placeLabel(loansWin.rentLabel, 625, row2Y + 2, 50)
  -- nil labelText avoids the AddEditBox ghost-label bug.
  addInputBackplate(loansWin, "rentAmountInputBg", 680, row2Y, 110, 28)
  local rentAmountInput = gui.AddEditBox(loansWin, "rentAmountInput",
    "LEFT", loansWin.rentLabel, 50, 0, 100, 28, 10, "0", nil)
  placeInput(rentAmountInput, 680, row2Y, 110, 28)
  loansWin.rentAmountInput = rentAmountInput
  
  local addLoanBtn = loansWin:CreateChildWidget("button", "addLoanBtn", 0, true)
  addLoanBtn:SetExtent(120, 32)
  addLoanBtn:AddAnchor("TOPLEFT", loansWin, 810, row2Y - 2)
  styleFlatButton(addLoanBtn, "Add Loan", UI.GREEN)
  
  -- Status label for click-feedback. Anchored just below the list with
  -- a fixed width so long messages ("Added loan: VeryLongPlayerName -> ...")
  -- can't overflow past the right edge of the window.
  addColorPanel(loansWin, "loansStatusPanel", 10, WIN_H - 36, LIST_W, 24, UI.STATUS)
  local statusLabel = loansWin:CreateChildWidget("label", "loansStatusLabel", 0, true)
  statusLabel:SetText("")
  statusLabel:SetExtent(LIST_W - 16, 22)
  statusLabel:AddAnchor("TOPLEFT", loansWin, 18, WIN_H - 35)
  if statusLabel.style then
    statusLabel.style:SetFontSize(12)
    if statusLabel.style.SetAlign then statusLabel.style:SetAlign(ALIGN.LEFT) end
  end
  setTextColor(statusLabel, UI.MUTED)
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
    resetSelectedLand()

    refreshLoansList()
    if LoansSystem.updateLoansSum then LoansSystem.updateLoansSum() end
    refreshLandDropdown()
    LoansSystem.saveLoans()
  end
  addLoanBtn:SetHandler("OnClick", addLoanBtn.OnClick)
  -- Reset button in the same top section, aligned with the Add Loan controls.
  local resetBtn = loansWin:CreateChildWidget("button", "resetBtn", 0, true)
  resetBtn:SetExtent(110, 32)
  resetBtn:AddAnchor("TOPRIGHT", loansWin, -34, row2Y - 2)
  styleFlatButton(resetBtn, "Del All", UI.RED)
  
  function resetBtn:OnClick()
    -- Was a no-op: pushed the existing loansData into the list without
    -- clearing it first, so nothing changed.
    if #loansData == 0 then return end

    for i = #loansData, 1, -1 do loansData[i] = nil end
    loansSeq = 0

    loansPage = 1
    refreshLoansList()
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
  local listY = 194  -- clear gap below the two-line input area
  addColorPanel(loansWin, "loansListPanel", 10, listY - 8, LIST_W, WIN_H - listY - 52, UI.LIST_PANEL)
  addSectionTitle(loansWin, "loansListTitle", "Loans", 20, listY - 24, 200)

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
      setFunc=function(s,i,set) styleLoanCell(s, i, set); if set then s:SetText(tostring(i.id or "")) end end },
    { name="Player", field="playerName", width=130,
      setFunc=function(s,i,set) styleLoanCell(s, i, set); if set then s:SetText(i.playerName or "") end end },
    { name="Land", field="landName", width=320,
      setFunc=function(s,i,set) styleLoanCell(s, i, set); if set then s:SetText(i.landName or "") end end },
    { name="Rent", field="rentAmount", width=70,
      setFunc=function(s,i,set) styleLoanCell(s, i, set); if set then s:SetText(formatRent(i.rentAmount or 0)) end end },
    { name="Since", field="rentingSince", width=110,
      setFunc=function(s,i,set) styleLoanCell(s, i, set); if set then s:SetText(fmtSince(i.rentingSince)) end end },
    { name="Next Due", field="nextRentDue", width=220,
      setFunc=function(s, i, set)
        styleLoanCell(s, i, set)
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
      setFunc=function(s,i,set) styleLoanCell(s, i, set); if set then s:SetText(formatRent(i.totalPaid or 0)) end end },
    { name="Actions", width=278, disableSort=true,
      setFunc = function(s, i, set)
        styleLoanCell(s, i, set)
        s.loanData = set and i or nil
        if s.paidBtn then s.paidBtn.loanData = s.loanData end
        if s.overdueBtn then s.overdueBtn.loanData = s.loanData end
        if s.noteBtn then s.noteBtn.loanData = s.loanData end
        if s.delBtn then s.delBtn.loanData = s.loanData end
        if s.paidBtn  then s.paidBtn:Show(set)  end
        if s.overdueBtn then s.overdueBtn:Show(set) end
        if s.noteBtn  then s.noteBtn:Show(set)  end
        if s.delBtn   then s.delBtn:Show(set)   end
      end,
      layoutFunc = function(list, row, col, cell)
        -- Paid button - FIXED with proper list reference
        local paidBtn = cell:CreateChildWidget("button", cell:GetId()..".paid", 0, true)
        paidBtn:SetExtent(64, 22)
        paidBtn:AddAnchor("LEFT", cell, 2, 0)
        styleFlatButton(paidBtn, "Paid", UI.GREEN)
        paidBtn.loanData = cell.loanData
        function paidBtn:OnClick()

          -- Use direct array access - more reliable than GetRowData
          local loan = self.loanData
          if loan then
            if LoansSystem.markRentPaid(loan.id) then
              -- Use global list reference instead of parameter
              refreshLoansList()
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
        overdueBtn:SetExtent(64, 22)
        overdueBtn:AddAnchor("LEFT", paidBtn, "RIGHT", 6, 0)
        styleFlatButton(overdueBtn, "Overdue", UI.BUTTON_DARK)
        overdueBtn.loanData = cell.loanData
        function overdueBtn:OnClick()
          local loan = self.loanData
          if loan and LoansSystem.markOverdue(loan.id) then
            refreshLoansList()
            if LoansSystem.updateLoansSum then LoansSystem.updateLoansSum() end
            LoansSystem.saveLoans()
          end
        end
        overdueBtn:SetHandler("OnClick", overdueBtn.OnClick)
        cell.overdueBtn = overdueBtn

        -- Note button — opens the shared note dialog populated with this
        -- loan's stored note (or empty for the first time).
        local noteBtn = cell:CreateChildWidget("button", cell:GetId()..".note", 0, true)
        noteBtn:SetExtent(64, 22)
        noteBtn:AddAnchor("LEFT", overdueBtn, "RIGHT", 6, 0)
        styleFlatButton(noteBtn, "Note", UI.BUTTON_BLUE)
        noteBtn.loanData = cell.loanData
        function noteBtn:OnClick()
          local loan = self.loanData
          if loan then openLoanNoteDialog(loan) end
        end
        noteBtn:SetHandler("OnClick", noteBtn.OnClick)
        cell.noteBtn = noteBtn

        -- Delete button
        local delBtn = cell:CreateChildWidget("button", cell:GetId()..".del", 0, true)
        delBtn:SetExtent(64, 22)
        delBtn:AddAnchor("LEFT", noteBtn, "RIGHT", 6, 0)
        styleFlatButton(delBtn, "Del", UI.RED)
        delBtn.loanData = cell.loanData
        
        function delBtn:OnClick()
          
          -- Use direct array access - more reliable than GetRowData  
          local loan = self.loanData
          if loan then
            if LoansSystem.deleteLoan(loan.id) then
              -- Use global list reference instead of parameter
              refreshLoansList()
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

  local function sortLoansByColumn(column, ascending)
    if not column or not column.field then return end
    local field = column.field
    table.sort(loansData, function(a, b)
      local av = a and a[field]
      local bv = b and b[field]
      if field == "rentAmount" or field == "totalPaid" or field == "id" or field == "nextRentDue" then
        av = tonumber(av) or 0
        bv = tonumber(bv) or 0
      else
        av = tostring(av or ""):lower()
        bv = tostring(bv or ""):lower()
      end
      if ascending then return av < bv end
      return av > bv
    end)
    loansPage = 1
    refreshLoansList()
  end

  loansItemList = gui.AddScrollList(
    loansWin, "loansItemList", columns,
    { point="TOPLEFT", relativeTo=loansWin, offsetX=10, offsetY=listY },
    { width=LIST_W, height=WIN_H - listY - 58 },
    {
      listType=3,
      rowCount=LOANS_PER_PAGE,
      columnHeight=26,
      enableColumns=true,
      hidePageControl=true,
      pageSize=LOANS_PER_PAGE,
      underlineColor={0.09, 0.09, 0.11, 0.95},
      separatorColor={0.18, 0.18, 0.2, 0.55},
      onSortChanged=function(colIndex, column, ascending)
        sortLoansByColumn(column, ascending)
      end
    }
  )

  if loansItemList and loansItemList.listCtrl and loansItemList.listCtrl.column then
    for i, columnButton in ipairs(loansItemList.listCtrl.column) do
      local col = columns[i]
      styleFlatButton(columnButton, col and col.name or "", UI.HEADER)
      if columnButton.cleanLabel then
        setTextColor(columnButton.cleanLabel, UI.GOLD)
      end
    end
  end

  local pageLabel = loansWin:CreateChildWidget("label", "loansPageLabel", 0, true)
  pageLabel:SetText("Showing 0-0 of 0   Page 1/1")
  pageLabel:SetExtent(330, 20)
  pageLabel:AddAnchor("TOPRIGHT", loansWin, -(WIN_W - (10 + LIST_W)) - 76, listY - 25)
  if pageLabel.style then
    pageLabel.style:SetFontSize(11)
    if pageLabel.style.SetAlign then pageLabel.style:SetAlign(ALIGN.RIGHT) end
  end
  setTextColor(pageLabel, UI.MUTED)
  loansWin.loansPageLabel = pageLabel

  local prevBtn = loansWin:CreateChildWidget("button", "loansPrevPageBtn", 0, true)
  prevBtn:SetExtent(28, 20)
  prevBtn:AddAnchor("TOPRIGHT", loansWin, -(WIN_W - (10 + LIST_W)) - 40, listY - 27)
  styleFlatButton(prevBtn, "<", UI.BUTTON_DARK)
  function prevBtn:OnClick()
    loansPage = clampLoanPage(loansPage - 1)
    refreshLoansList()
  end
  prevBtn:SetHandler("OnClick", prevBtn.OnClick)
  loansWin.loansPrevBtn = prevBtn

  local nextBtn = loansWin:CreateChildWidget("button", "loansNextPageBtn", 0, true)
  nextBtn:SetExtent(28, 20)
  nextBtn:AddAnchor("TOPRIGHT", loansWin, -(WIN_W - (10 + LIST_W)) - 8, listY - 27)
  styleFlatButton(nextBtn, ">", UI.BUTTON_DARK)
  function nextBtn:OnClick()
    loansPage = clampLoanPage(loansPage + 1)
    refreshLoansList()
  end
  nextBtn:SetHandler("OnClick", nextBtn.OnClick)
  loansWin.loansNextBtn = nextBtn

  refreshLoansList()

  -- ==================== RIGHT-SIDE SUMMARY PANEL ====================
  -- Replaces the old top-header strip and bottom-footer strip. All totals
  -- now live in one column to the right of the list.
  local panelBg = loansWin:CreateChildWidget("emptywidget", "panelBg", 0, true)
  panelBg:SetExtent(PANEL_W, WIN_H - listY - 58)
  panelBg:AddAnchor("TOPLEFT", loansWin, 10 + LIST_W + PANEL_GAP, listY)
  addColorPanel(panelBg, "loansSummaryBg", 0, 0, PANEL_W, WIN_H - listY - 58, UI.PANEL)
  addColorPanel(panelBg, "loansSummaryHeader", 0, 0, PANEL_W, 30, UI.HEADER)
  addColorPanel(panelBg, "loansSummaryStatusGroup", 8, 42, PANEL_W - 16, 72, UI.GROUP_STATUS)
  addColorPanel(panelBg, "loansSummaryIncomeGroup", 8, 122, PANEL_W - 16, 110, UI.GROUP_MONEY)
  addColorPanel(panelBg, "loansSummaryOverdueGroup", 8, 236, PANEL_W - 16, 36, UI.GROUP_STATUS)

  local function panelLabel(name, text, yOff, color)
    local lbl = loansWin:CreateChildWidget("label", name, 0, true)
    lbl:SetText(text)
      lbl:SetExtent(PANEL_W - 16, 24)
    lbl:AddAnchor("TOPLEFT", panelBg, 10, yOff)
    if lbl.style then
      lbl.style:SetFontSize(12)
      lbl.style:SetAlign(ALIGN.CENTER)
    end
    setTextColor(lbl, color or UI.WHITE)
    return lbl
  end

  -- Header for the panel
  local panelTitle = panelLabel("loansPanelTitle", "Summary", 8, UI.GOLD)

  -- Defaults to engine color; only Total received (gold) and Overdue (red
  -- when positive) get explicit coloring. Weekly income removed — duplicated
  -- the "Weekly" line above it.
  local GOLD = {1.0, 0.85, 0.0}
  loansWin.currentDateLabel  = panelLabel("currentDateLabel",  getCurrentDateString(), 50)
  loansWin.activeLoansLabel  = panelLabel("activeLoansLabel",  "Active: 0",                         88)
  loansWin.totalRentLabel    = panelLabel("totalRentLabel",    "Monthly: 0g",                       126)
  loansWin.weeklyHeaderLabel = panelLabel("weeklyHeaderLabel", "Weekly: 0g",                        164)
  loansWin.loansSumLabel     = panelLabel("loansSumLabel",     "Received: 0g",                      202, GOLD)
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

    if loansWin.loansSumLabel    then loansWin.loansSumLabel:SetText("Received: " .. formatRent(totalPaid)) end
    if loansWin.activeLoansLabel then loansWin.activeLoansLabel:SetText("Active: " .. activeCount) end
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
      loansWin.currentDateLabel:SetText(getCurrentDateString())
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
        if LoansSystem.refreshLoansList then
          LoansSystem.refreshLoansList()
        else
          loansItemList:UpdateData(loansData)
        end
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
