-- tax_tracker/reminderwindow.lua - Login/Exit Reminder Window
local api = require("api")
local gui = require("tax_tracker/gui")
local Debug = nil
pcall(function() Debug = require("tax_tracker/debug") end)
if not Debug then
  Debug = { info = function() end, warn = function() end, error = function() end, debug = function() end, trace = function() end }
end
local TimeSystem = nil
pcall(function() TimeSystem = require("tax_tracker/timesystem") end)

local ReminderWindow = {}

local reminderWin = nil
local gameExitFrame = nil
local FARM_DATA_KEY = "farmTrackerData"
local FARM_SOON_SECONDS = 10 * 60

local function dateToUnix(year, month, day, hour, min, sec)
  local daysInMonth = {31,28,31,30,31,30,31,31,30,31,30,31}
  local function isLeap(y)
    return (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
  end
  local days = 0
  for y = 1970, year - 1 do
    days = days + (isLeap(y) and 366 or 365)
  end
  for m = 1, month - 1 do
    days = days + daysInMonth[m]
    if m == 2 and isLeap(year) then days = days + 1 end
  end
  days = days + (day - 1)
  return days * 86400 + hour * 3600 + min * 60 + sec
end

local function nowUnix()
  local t = api.Time:TimeToDate(api.Time:GetLocalTime())
  return dateToUnix(t.year, t.month, t.day, t.hour, t.minute, t.second) + (5 * 3600)
end

local function formatFarmTime(secs)
  secs = tonumber(secs) or 0
  if secs <= 0 then return "done" end
  local m = math.floor(secs / 60)
  local s = secs % 60
  if m > 0 then return string.format("%dm %ds", m, s) end
  return string.format("%ds", s)
end

local function farmEntryRemaining(entry)
  if not entry then return nil end
  if entry.expiryUnix then
    return tonumber(entry.expiryUnix) - nowUnix()
  end
  if entry.captureUiMsec and entry.displayTime and api.Time and api.Time.GetUiMsec then
    local nowMs = api.Time:GetUiMsec()
    if nowMs >= entry.captureUiMsec then
      return math.ceil(((entry.captureUiMsec + entry.displayTime * 1000) - nowMs) / 1000)
    end
  end
  return nil
end

local function getDueFarms(thresholdSecs)
  local dueFarms = {}
  local settings = api.GetSettings("tax_tracker") or {}
  local farms = settings[FARM_DATA_KEY] or {}

  for _, farm in ipairs(farms) do
    local earliest = nil
    for _, entry in ipairs(farm.doodads or {}) do
      local remaining = farmEntryRemaining(entry)
      if remaining and remaining <= thresholdSecs then
        if earliest == nil or remaining < earliest then earliest = remaining end
      end
    end
    if earliest ~= nil then
      table.insert(dueFarms, {
        name = farm.name or "Farm",
        zoneName = farm.zone or "Unknown Zone",
        remaining = earliest,
      })
    end
  end

  table.sort(dueFarms, function(a, b) return (a.remaining or 0) < (b.remaining or 0) end)
  return dueFarms
end

-- Get overdue lands
local function getOverdueLands()
  local overdueLands = {}
  local settings = api.GetSettings("tax_tracker") or {}
  local lands = settings.lands or {}
  
  for _, land in ipairs(lands) do
    if land.nextPayment and TimeSystem.isOverdue(land.nextPayment) then
      table.insert(overdueLands, {
        name = land.name or "Unknown",
        zoneName = land.zoneName or "Unknown Zone",
        tax = land.tax or 0,
        landType = land.landType or ""
      })
    end
  end
  
  return overdueLands
end

-- Get overdue loan payments
local function getOverdueLoans()
  local overdueLoans = {}
  local settings = api.GetSettings("tax_tracker") or {}
  local loansData = settings.loansData or {}
  
  for _, loan in ipairs(loansData) do
    if loan.nextRentDue and loan.nextRentDue ~= 0 and TimeSystem.isOverdue(loan.nextRentDue) then
      table.insert(overdueLoans, {
        playerName = loan.playerName or "Unknown",
        landName = loan.landName or "Unknown Land",
        rentAmount = loan.rentAmount or 0
      })
    end
  end
  
  return overdueLoans
end

-- Create the reminder window content
local function buildReminderContent(overdueLands, overdueLoans, dueFarms)
  Debug.info("ReminderWindow", "Building content", {hasWindow = reminderWin ~= nil})
  if not reminderWin then return end
  
  -- Clear existing content
  if reminderWin.content then
    reminderWin.content:Destroy()
  end
  
  local content = reminderWin:CreateChildWidget("emptywidget", "content", 0, true)
  content:SetExtent(500, 400)
  content:AddAnchor("TOPLEFT", reminderWin, 10, 50)
  reminderWin.content = content
  
  local yOffset = 20
  local hasOverdueItems = false
  
  -- OVERDUE LANDS SECTION
  if #overdueLands > 0 then
    hasOverdueItems = true
    
    local landsHeader = content:CreateChildWidget("label", "landsHeader", 0, true)
    landsHeader:SetText("OVERDUE LANDS - Tax Payment Required")
    landsHeader:SetExtent(480, 25)
    landsHeader:AddAnchor("TOPLEFT", content, 0, yOffset)
    if landsHeader.style then
      landsHeader.style:SetFontSize(FONT_SIZE.LARGE)
      landsHeader.style:SetAlign(ALIGN.LEFT)
      landsHeader.style:SetColor(1, 0.3, 0.3, 1)
    end
    yOffset = yOffset + 30
    
    local totalTax = 0
    for _, land in ipairs(overdueLands) do
      totalTax = totalTax + land.tax
      
      local landLabel = content:CreateChildWidget("label", "land_" .. _, 0, true)
      landLabel:SetText(string.format("  %s (%s) - %s tax", land.name, land.zoneName, formatTax(land.tax)))
      landLabel:SetExtent(480, 20)
      landLabel:AddAnchor("TOPLEFT", content, 0, yOffset)
      if landLabel.style then
        landLabel.style:SetFontSize(FONT_SIZE.MIDDLE)
        landLabel.style:SetAlign(ALIGN.LEFT)
      end
      yOffset = yOffset + 22
    end
    
    local totalLabel = content:CreateChildWidget("label", "landsTotal", 0, true)
    totalLabel:SetText(string.format("Total Tax Due: %s certs", formatTax(totalTax)))
    totalLabel:SetExtent(480, 22)
    totalLabel:AddAnchor("TOPLEFT", content, 0, yOffset)
    if totalLabel.style then
      totalLabel.style:SetFontSize(FONT_SIZE.MIDDLE)
      totalLabel.style:SetColor(1, 0.85, 0, 1)
    end
    yOffset = yOffset + 35
  end
  
  -- OVERDUE LOANS SECTION
  if #overdueLoans > 0 then
    hasOverdueItems = true
    
    local loansHeader = content:CreateChildWidget("label", "loansHeader", 0, true)
    loansHeader:SetText("OVERDUE LOAN PAYMENTS")
    loansHeader:SetExtent(480, 25)
    loansHeader:AddAnchor("TOPLEFT", content, 0, yOffset)
    if loansHeader.style then
      loansHeader.style:SetFontSize(FONT_SIZE.LARGE)
      loansHeader.style:SetAlign(ALIGN.LEFT)
      loansHeader.style:SetColor(1, 0.3, 0.3, 1)
    end
    yOffset = yOffset + 30
    
    local totalRent = 0
    for _, loan in ipairs(overdueLoans) do
      totalRent = totalRent + loan.rentAmount
      
      local loanLabel = content:CreateChildWidget("label", "loan_" .. _, 0, true)
      loanLabel:SetText(string.format("  %s -> %s - %s", loan.playerName, loan.landName, formatRent(loan.rentAmount)))
      loanLabel:SetExtent(480, 20)
      loanLabel:AddAnchor("TOPLEFT", content, 0, yOffset)
      if loanLabel.style then
        loanLabel.style:SetFontSize(FONT_SIZE.MIDDLE)
        loanLabel.style:SetAlign(ALIGN.LEFT)
      end
      yOffset = yOffset + 22
    end
    
    local totalLoansLabel = content:CreateChildWidget("label", "loansTotal", 0, true)
    totalLoansLabel:SetText(string.format("Total Rent Due: %s", formatRent(totalRent)))
    totalLoansLabel:SetExtent(480, 22)
    totalLoansLabel:AddAnchor("TOPLEFT", content, 0, yOffset)
    if totalLoansLabel.style then
      totalLoansLabel.style:SetFontSize(FONT_SIZE.MIDDLE)
      totalLoansLabel.style:SetColor(1, 0.85, 0, 1)
    end
    yOffset = yOffset + 35
  end

  -- FARMS SECTION
  if #dueFarms > 0 then
    hasOverdueItems = true

    local farmsHeader = content:CreateChildWidget("label", "farmsHeader", 0, true)
    farmsHeader:SetText("FARMS DONE OR FINISHING SOON")
    farmsHeader:SetExtent(480, 25)
    farmsHeader:AddAnchor("TOPLEFT", content, 0, yOffset)
    if farmsHeader.style then
      farmsHeader.style:SetFontSize(FONT_SIZE.LARGE)
      farmsHeader.style:SetAlign(ALIGN.LEFT)
      farmsHeader.style:SetColor(1, 0.85, 0, 1)
    end
    yOffset = yOffset + 30

    for i, farm in ipairs(dueFarms) do
      if i > 10 then
        local moreLabel = content:CreateChildWidget("label", "farm_more", 0, true)
        moreLabel:SetText(string.format("  ...and %d more", #dueFarms - 10))
        moreLabel:SetExtent(480, 20)
        moreLabel:AddAnchor("TOPLEFT", content, 0, yOffset)
        if moreLabel.style then moreLabel.style:SetFontSize(FONT_SIZE.MIDDLE); moreLabel.style:SetAlign(ALIGN.LEFT) end
        yOffset = yOffset + 22
        break
      end

      local farmLabel = content:CreateChildWidget("label", "farm_" .. i, 0, true)
      farmLabel:SetText(string.format("  %s (%s) - %s", farm.name, farm.zoneName, formatFarmTime(farm.remaining)))
      farmLabel:SetExtent(480, 20)
      farmLabel:AddAnchor("TOPLEFT", content, 0, yOffset)
      if farmLabel.style then
        farmLabel.style:SetFontSize(FONT_SIZE.MIDDLE)
        farmLabel.style:SetAlign(ALIGN.LEFT)
      end
      yOffset = yOffset + 22
    end
    yOffset = yOffset + 15
  end
  
  -- NO OVERDUE ITEMS
  if not hasOverdueItems then
    local noItemsLabel = content:CreateChildWidget("label", "noItems", 0, true)
    noItemsLabel:SetText("No overdue payments!")
    noItemsLabel:SetExtent(480, 30)
    noItemsLabel:AddAnchor("TOPLEFT", content, 0, yOffset + 20)
    if noItemsLabel.style then
      noItemsLabel.style:SetFontSize(FONT_SIZE.LARGE)
      noItemsLabel.style:SetAlign(ALIGN.CENTER)
      noItemsLabel.style:SetColor(0.4, 1, 0.4, 1)
    end
    yOffset = yOffset + 60
  end
  
  -- Resize window to fit content
  local newHeight = math.max(200, yOffset + 60)
  reminderWin:SetExtent(520, newHeight)
end

-- Format tax amount
function formatTax(amount)
  if not amount then return "0" end
  return string.format("%.2f", amount)
end

-- Format rent amount
function formatRent(amount)
  if not amount or amount == 0 then
    return "0g"
  end
  local str = tostring(math.floor(amount))
  str = str:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  if str:sub(1,1) == "," then str = str:sub(2) end
  return str .. "g"
end

-- Show the reminder window
function ReminderWindow.show(isExit)
  local overdueLands = getOverdueLands()
  local overdueLoans = getOverdueLoans()
  local dueFarms = getDueFarms(FARM_SOON_SECONDS)
  
  local title = isExit and "Tax Tracker - Exit Reminder" or "Tax Tracker - Login Reminder"
  
  if not reminderWin then
    reminderWin = api.Interface:CreateWindow("TaxTrackerReminder", title, 0, 0)
    reminderWin:SetExtent(520, 300)
    reminderWin:AddAnchor("CENTER", "UIParent", 0, 0)
    
    -- Handle ESC key to close
    local winForEsc = reminderWin
    reminderWin:SetCloseOnEscape(true)
    reminderWin:SetHandler("OnCloseByEsc", function()
      winForEsc:Show(false)
    end)
    
    -- Background tint - start below title bar
    local bg = reminderWin:CreateChildWidget("textbox", "bg", 0, true)
    bg:AddAnchor("TOPLEFT", reminderWin, 0, 36)
    bg:AddAnchor("BOTTOMRIGHT", reminderWin, 0, 0)
    bg:SetText("")
    if bg.style and bg.style.SetColor then bg.style:SetColor(0, 0, 0, 0.7) end
    if bg.Enable then bg:Enable(false) end
  else
    reminderWin:SetTitle(title)
  end
  
  buildReminderContent(overdueLands, overdueLoans, dueFarms)
  reminderWin:Show(true)
  
  Debug.info("ReminderWindow", "Reminder shown", {
    isExit = isExit,
    overdueLands = #overdueLands,
    overdueLoans = #overdueLoans,
    dueFarms = #dueFarms
  })
end

-- Hide the reminder window
function ReminderWindow.hide()
  if reminderWin then
    reminderWin:Show(false)
  end
end

-- Initialize for login reminder
function ReminderWindow.initForLogin()
  -- Hook into GAME_EXIT_FRAME for exit reminder like reality_check does
  local ok, frame = pcall(function() return ADDON:GetContent(UIC.GAME_EXIT_FRAME) end)
  if ok and frame then
    gameExitFrame = frame
    Debug.info("ReminderWindow", "initForLogin got GAME_EXIT_FRAME")
  end
  
  -- Show login reminder after a short delay to not interfere with loading
  api:DoIn(2000, function()
    local overdueLands = getOverdueLands()
    local overdueLoans = getOverdueLoans()
    local dueFarms = getDueFarms(FARM_SOON_SECONDS)
    if #overdueLands > 0 or #overdueLoans > 0 or #dueFarms > 0 then
      ReminderWindow.show(false)
    end
  end)
end

-- Update exit reminder label (called periodically from UpdateSystem)
function ReminderWindow.updateExitReminder()
  if not gameExitFrame then
    local ok, frame = pcall(function() return ADDON:GetContent(UIC.GAME_EXIT_FRAME) end)
    if ok and frame then
      gameExitFrame = frame
    else
      return
    end
  end
  
  if gameExitFrame and gameExitFrame.taxTrackerReminderLabel then
    local overdueLands = getOverdueLands()
    local overdueLoans = getOverdueLoans()
    local dueFarms = getDueFarms(FARM_SOON_SECONDS)
    local totalOverdue = #overdueLands + #overdueLoans + #dueFarms
    
    if totalOverdue > 0 then
      local taxSuffix = #overdueLands == 1 and "" or "s"
      local loanSuffix = #overdueLoans == 1 and "" or "s"
      local farmSuffix = #dueFarms == 1 and "" or "s"
      local msg = string.format("TaxTracker: %d Tax Payment%s, %d Loan Payment%s, %d Farm%s Done/Soon!", #overdueLands, taxSuffix, #overdueLoans, loanSuffix, #dueFarms, farmSuffix)
      gameExitFrame.taxTrackerReminderLabel:SetText(msg)
      if gameExitFrame.taxTrackerReminderLabel.style and gameExitFrame.taxTrackerReminderLabel.style.SetColor then
        gameExitFrame.taxTrackerReminderLabel.style:SetColor(1, 0.3, 0.3, 1)
      end
    else
      gameExitFrame.taxTrackerReminderLabel:SetText("TaxTracker: No Overdue Payments")
      if gameExitFrame.taxTrackerReminderLabel.style and gameExitFrame.taxTrackerReminderLabel.style.SetColor then
        gameExitFrame.taxTrackerReminderLabel.style:SetColor(0.4, 1, 0.4, 1)
      end
    end
  end
end

-- Initialize for exit reminder (called from OnUnload-like scenario)
function ReminderWindow.initForExit()
  -- Try to get the game exit frame for adding exit reminder widgets
  if not gameExitFrame then
    local ok, frame = pcall(function() return ADDON:GetContent(UIC.GAME_EXIT_FRAME) end)
    if ok and frame then
      gameExitFrame = frame
    end
  end
  
  if not gameExitFrame then
    return
  end
  
  -- ALWAYS destroy any existing button with our name (it persists across reloads)
  pcall(function()
    local btn = api.Interface:FindWidget("taxTrackerShowReminderBtn")
    if btn then
      if btn.Destroy then
        btn:Destroy()
      elseif btn.Show then
        btn:Show(false)
      end
    end
  end)
  
  -- Clear our reference if it exists
  gameExitFrame.taxTrackerShowReminderBtn = nil
  
  -- Create label widget only (no button, no popup window)
  if not gameExitFrame.taxTrackerReminderLabel then
    local exitLabel = gameExitFrame:CreateChildWidget("label", "taxTrackerReminderLabel", 0, true)
    exitLabel.style:SetAlign(ALIGN.MIDDLE)
    exitLabel:AddAnchor("BOTTOM", gameExitFrame, 0, -120)
    exitLabel.style:SetFontSize(FONT_SIZE.MIDDLE)
    exitLabel.style:SetShadow(true)
    gameExitFrame.taxTrackerReminderLabel = exitLabel
  end
  
  -- Update exit reminder label with count
  local overdueLands = getOverdueLands()
  local overdueLoans = getOverdueLoans()
  local dueFarms = getDueFarms(FARM_SOON_SECONDS)
  local totalOverdue = #overdueLands + #overdueLoans + #dueFarms
  
  if gameExitFrame.taxTrackerReminderLabel then
    if totalOverdue > 0 then
      local taxSuffix = #overdueLands == 1 and "" or "s"
      local loanSuffix = #overdueLoans == 1 and "" or "s"
      local farmSuffix = #dueFarms == 1 and "" or "s"
      local msg = string.format("TaxTracker: %d Tax Payment%s, %d Loan Payment%s, %d Farm%s Done/Soon!", #overdueLands, taxSuffix, #overdueLoans, loanSuffix, #dueFarms, farmSuffix)
      gameExitFrame.taxTrackerReminderLabel:SetText(msg)
      if gameExitFrame.taxTrackerReminderLabel.style and gameExitFrame.taxTrackerReminderLabel.style.SetColor then
        gameExitFrame.taxTrackerReminderLabel.style:SetColor(1, 0.3, 0.3, 1)
      end
    else
      gameExitFrame.taxTrackerReminderLabel:SetText("TaxTracker: No Overdue Payments")
      if gameExitFrame.taxTrackerReminderLabel.style and gameExitFrame.taxTrackerReminderLabel.style.SetColor then
        gameExitFrame.taxTrackerReminderLabel.style:SetColor(0.4, 1, 0.4, 1)
      end
    end
  end
end

-- Cleanup
function ReminderWindow.cleanup()
  if reminderWin then
    reminderWin:Destroy()
    reminderWin = nil
  end
  if gameExitFrame then
    if gameExitFrame.taxTrackerReminderLabel then
      gameExitFrame.taxTrackerReminderLabel:Show(false)
      gameExitFrame.taxTrackerReminderLabel = nil
    end
    gameExitFrame = nil
  end
end

return ReminderWindow
