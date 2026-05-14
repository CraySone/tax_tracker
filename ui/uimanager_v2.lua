-- tax_tracker/ui/uimanager_v2.lua - Complete editor window matching buildMainWindow
local api = require("api")
local Debug = require("tax_tracker/debug")
local Config = require("tax_tracker/config")
local Zones = require("tax_tracker/utils/zones")
local gui = require("tax_tracker/gui")
local HierarchicalDropdown = require("tax_tracker/ui/hierarchical_dropdown_fixed")
local SavedLandsWindow = nil -- Lazy load to avoid circular dependency

-- Local reference for compatibility with working version
local BASE_TAX = Config.BASE_TAX

-- Helper functions extracted from buildMainWindow
local function getCurrentPlayerName()
  local playerId = api.Unit:GetUnitId("player")
  if playerId then
    return api.Unit:GetUnitNameById(playerId)
  end
  return ""
end

local function getCurrentSextant()
  if not api.Map or not api.Map.GetPlayerSextants then
    return nil
  end
  
  local ok, sextant = pcall(function() return api.Map:GetPlayerSextants() end)
  if not ok or not sextant then
    return nil
  end
  
  return {
    lon = {
      dir = sextant.longitude or "E",
      deg = sextant.deg_long or 0,
      min = sextant.min_long or 0,
      sec = sextant.sec_long or 0
    },
    lat = {
      dir = sextant.latitude or "N",
      deg = sextant.deg_lat or 0,
      min = sextant.min_lat or 0,
      sec = sextant.sec_lat or 0
    }
  }
end

-- Helper functions from working version
local function fmt2(n) return string.format("%.2f", n or 0) end
local function is_checked(w) return (w and w.GetChecked and w:GetChecked()) and true or false end
local function getPure(btn)
  if not btn then return "" end
  if btn.GetPureText then return btn:GetPureText() or "" end
  if btn.cleanText then return btn.cleanText end
  local t = (btn.GetText and btn:GetText()) or ""
  return (t:gsub("%s*▾%s*$",""))
end

local function ownedMult(n)
  -- Based on ownership multipliers: 3=2x, 4=2.5x, 5=3x, 6=3.5x, 7=5x, 8=6x, 9+=7x
  -- 1-2 buildings have no ownership multiplier (1.0x)
  if n<=2 then return 1.00 
  elseif n==3 then return 2.00 
  elseif n==4 then return 2.50 
  elseif n==5 then return 3.00 
  elseif n==6 then return 3.50 
  elseif n==7 then return 5.00 
  elseif n==8 then return 6.00 
  elseif n>=9 then return 7.00 
  else return 7.00 end
end

-- Full getTargetSextant implementation
local function getTargetSextant()
  if not api or not api.Unit then
    return nil
  end

  -- Validate target using GetUnitId
  local success1, targetId = pcall(function()
    return api.Unit:GetUnitId("target")
  end)

  if not success1 or not targetId then
    return nil
  end

  -- Try to get target name
  local success2, targetName = pcall(function()
    return api.Unit:GetUnitNameById(targetId)
  end)

  -- Test the world position call
  local success3, targetPosX, targetPosY, targetPosZ = pcall(function()
    local x, y, z = api.Unit:UnitWorldPosition("target")
    return x, y, z
  end)

  if not success3 or not targetPosX or not targetPosY then
    return nil
  end

  -- Get player data for coordinate system reference
  local success4, playerSextants = pcall(function()
    return api.Map:GetPlayerSextants()
  end)

  local success5, playerWorldX, playerWorldY, playerWorldZ = pcall(function()
    return api.Unit:UnitWorldPosition("player")
  end)
  
  if success4 and playerSextants and success5 and playerWorldX and playerWorldY then
    -- Use the proper coordinate conversion from tier_2_sextant/Navigate
    local coordCoef = 0.00097657363894522145695357130138029
    
    -- Convert player sextants to world coordinates using the same method as Navigate addon
    local function sextantToWorldCoords(direction, degrees, minutes, seconds, isLatitude)
      local coords = seconds / 60
      coords = (coords + minutes) / 60
      coords = degrees + coords
      if (isLatitude and direction == "S") or (not isLatitude and direction == "W") then 
        coords = coords * -1 
      end
      local offset = isLatitude and 28 or 21
      return (coords + offset) / coordCoef
    end
    
    -- Convert world coordinates back to sextants
    local function worldCoordsToSextant(worldCoord, isLatitude)
      local offset = isLatitude and 28 or 21
      local coords = worldCoord * coordCoef - offset
      
      local direction
      if isLatitude then
        direction = coords >= 0 and "N" or "S"
      else
        direction = coords >= 0 and "E" or "W"
      end
      
      coords = math.abs(coords)
      local degrees = math.floor(coords)
      local minutesDecimal = (coords - degrees) * 60
      local minutes = math.floor(minutesDecimal)
      local seconds = math.floor((minutesDecimal - minutes) * 60)
      
      return direction, degrees, minutes, seconds
    end
    
    -- Convert player sextants to world coordinates for reference
    local playerWorldLon = sextantToWorldCoords(playerSextants.longitude, playerSextants.deg_long,
                                               playerSextants.min_long, playerSextants.sec_long, false)
    local playerWorldLat = sextantToWorldCoords(playerSextants.latitude, playerSextants.deg_lat,
                                               playerSextants.min_lat, playerSextants.sec_lat, true)

    local deltaX = targetPosX - playerWorldX
    local deltaY = targetPosY - playerWorldY
    local targetWorldLon = playerWorldLon + deltaX
    local targetWorldLat = playerWorldLat + deltaY

    local lonDir, lonDeg, lonMin, lonSec = worldCoordsToSextant(targetWorldLon, false)
    local latDir, latDeg, latMin, latSec = worldCoordsToSextant(targetWorldLat, true)

    local targetCoords = {
      lon = { dir = lonDir, deg = lonDeg, min = lonMin, sec = lonSec },
      lat = { dir = latDir, deg = latDeg, min = latMin, sec = latSec }
    }

    return targetCoords, targetName
  else
    return nil, targetName  -- Still return targetName even if coords fail
  end
end

-- Zone ID to Name mapping (ArcheAge Classic zone IDs)
-- This maps the zone group ID returned by GetCurrentZoneGroup() to zone names
local ZONE_ID_TO_NAME = {
  -- Nuia (West)
  [1] = "Gweonid Forest",
  [2] = "Marianople",
  [3] = "Dewstone Plains",
  [5] = "Solzreed Peninsula",
  [6] = "Lilyut Hills",
  [8] = "Two Crowns",
  [10] = "Airain Rock",
  [18] = "White Arden",
  [19] = "Karkasse Ridgelands",
  [20] = "Cinderstone Moor",
  [21] = "Aubre Cradle",
  [22] = "Halcyona",
  [26] = "Hellswamp",
  [27] = "Sanddeep",
  [93] = "Ahnimar",
  
  -- Haranya (East)
  [4] = "Solis Headlands",
  [7] = "Arcum Iris",
  [9] = "Mahadevi",
  [11] = "Falcorth Plains",
  [12] = "Villanelle",
  [13] = "Sunbite Wilds",
  [14] = "Windscour Savannah",
  [15] = "Perinoor Ruins",
  [16] = "Rookborne Basin",
  [17] = "Ynystere",
  [23] = "Hasla",
  [24] = "Tigerspine Mountains",
  [25] = "Silent Forest",
  [99] = "Rokhala Mountains",
  
  -- Auroria
  [33] = "Heedmar",
  [34] = "Nuimari",
  [43] = "Marcala",
  [44] = "Calmlands",
  [54] = "Exeloch",
  [56] = "Sungold Fields",
  [57] = "Golden Ruins",
  [61] = "Diamond Shores",
  [103] = "Whalesong Harbor",
}

-- Helper function to get current zone name
local function getCurrentZoneName()
  local success, zoneId = pcall(function()
    return api.Unit:GetCurrentZoneGroup()
  end)
  
  if success and zoneId then
    if type(zoneId) == "number" then
      local zoneName = ZONE_ID_TO_NAME[zoneId]
      if zoneName then
        return zoneName
      end
      return "Unknown Zone (ID: " .. tostring(zoneId) .. ")"
    elseif type(zoneId) == "string" then
      return zoneId
    elseif type(zoneId) == "table" then
      return zoneId.name or zoneId.zoneName or zoneId[1]
    end
  end

  return nil
end

-- Helper function to match target name to a land type from Config patterns
local function matchLandTypeFromName(targetName)
  if not targetName or targetName == "" then return nil end
  
  local lowerName = string.lower(targetName)

  local hasSolarLunarStellar =
      lowerName:find("solar", 1, true)
      or lowerName:find("lunar", 1, true)
      or lowerName:find("stellar", 1, true)

  if hasSolarLunarStellar then
    if lowerName:find("pavilion farm", 1, true) or lowerName:find("pavillion farm", 1, true) then
      return "P2W Gazebo (24x24)"
    end
    if lowerName:find("scarecrow farm", 1, true) then
      return "P2W Scarecrow (16x16)"
    end
    if lowerName:find("scarecrow garden", 1, true) or lowerName:find(" farm", 1, true) then
      return "P2W Farm (8x8)"
    end
  end
  
  -- Use Config.LAND_TYPE_PATTERNS to find a match
  for _, pattern in ipairs(Config.LAND_TYPE_PATTERNS) do
    local keyword = pattern[1]
    local landType = pattern[2]
    if string.find(lowerName, keyword, 1, true) then
      return landType
    end
  end
  
  return nil
end

local function isAutoTaxExemptLandName(targetName)
  if not targetName or targetName == "" then return false end
  local lowerName = string.lower(targetName)

  local hasSolarLunarStellar =
      lowerName:find("solar", 1, true)
      or lowerName:find("lunar", 1, true)
      or lowerName:find("stellar", 1, true)
  if not hasSolarLunarStellar then return false end

  local hasKnownExemptForm =
      lowerName:find("scarecrow garden", 1, true)
      or lowerName:find("scarecrow farm", 1, true)
      or lowerName:find("pavilion farm", 1, true)
      or lowerName:find("pavillion farm", 1, true)
  return hasKnownExemptForm and true or false
end

-- Helper function for adding tints (from working version)
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

local EDITOR_UI = {
  white = {1, 1, 1, 1},
  muted = {0.72, 0.72, 0.72, 1},
  gold = {1, 0.84, 0, 1},
  green = {0.12, 0.28, 0.15, 0.95},
  red = {0.24, 0.09, 0.09, 0.95},
  button = {0.11, 0.11, 0.13, 0.92},
  panel = {0.05, 0.05, 0.06, 0.62},
  header = {0.09, 0.09, 0.11, 0.95},
  input = {0.10, 0.10, 0.11, 0.96},
  groupDetails = {0.07, 0.07, 0.08, 0.74},
  groupTax = {0.055, 0.06, 0.07, 0.74},
  groupCoords = {0.065, 0.065, 0.075, 0.74},
  groupActions = {0.05, 0.05, 0.06, 0.76},
  rowOdd = {0.08, 0.08, 0.095, 0.72},
  rowEven = {0.12, 0.12, 0.135, 0.72}
}

local function addEditorPanel(parent, id, x, y, width, height, color)
  if not parent then return nil end
  local c = color or EDITOR_UI.panel
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

local function addEditorInputBackplate(parent, id, x, y, width, height)
  addEditorPanel(parent, id .. "Border", x - 1, y - 1, width + 2, height + 2, {0, 0, 0, 0.95})
  return addEditorPanel(parent, id, x, y, width, height, EDITOR_UI.input)
end

local function styleEditorEditBox(editbox)
  if not editbox then return end
  if editbox.CreateColorDrawable and not editbox._editorInputBorder then
    editbox._editorInputBorder = editbox:CreateColorDrawable(0, 0, 0, 0.95, "background")
    editbox._editorInputPlate = editbox:CreateColorDrawable(
      EDITOR_UI.input[1], EDITOR_UI.input[2], EDITOR_UI.input[3], EDITOR_UI.input[4], "background")
  end
  if editbox._editorInputBorder then
    if editbox._editorInputBorder.RemoveAllAnchors then editbox._editorInputBorder:RemoveAllAnchors() end
    editbox._editorInputBorder:AddAnchor("TOPLEFT", editbox, -1, -1)
    editbox._editorInputBorder:AddAnchor("BOTTOMRIGHT", editbox, 1, 1)
    editbox._editorInputBorder:Show(true)
  end
  if editbox._editorInputPlate then
    if editbox._editorInputPlate.RemoveAllAnchors then editbox._editorInputPlate:RemoveAllAnchors() end
    editbox._editorInputPlate:AddAnchor("TOPLEFT", editbox, 0, 0)
    editbox._editorInputPlate:AddAnchor("BOTTOMRIGHT", editbox, 0, 0)
    editbox._editorInputPlate:Show(true)
  end
  if editbox.style then
    if editbox.style.SetFontSize then editbox.style:SetFontSize(12) end
    if editbox.style.SetAlign then editbox.style:SetAlign(ALIGN.LEFT) end
    if editbox.style.SetColor then editbox.style:SetColor(1, 1, 1, 1) end
  end
end

local function setEditorTextColor(widget, color)
  if widget and widget.style and widget.style.SetColor then
    local c = color or EDITOR_UI.white
    widget.style:SetColor(c[1], c[2], c[3], c[4])
  elseif widget and ApplyTextColor and FONT_COLOR then
    ApplyTextColor(widget, FONT_COLOR.DEFAULT)
  end
end

local function styleEditorButton(button, text, width, height, tone)
  if not button then return end
  button:SetText("")
  local c = tone or EDITOR_UI.button
  button._editorBg = button:CreateColorDrawable(c[1], c[2], c[3], c[4], "background")
  button._editorBg:AddAnchor("TOPLEFT", button, 0, 0)
  button._editorBg:AddAnchor("BOTTOMRIGHT", button, 0, 0)
  button._editorBg:Show(true)
  local labelId = "editorButtonLabel"
  pcall(function() if button.GetId then labelId = tostring(button:GetId()) .. ".editorLabel" end end)
  button._editorLabel = button:CreateChildWidget("label", labelId, 0, true)
  button._editorLabel:SetExtent(width, math.max(1, height - 2))
  button._editorLabel:AddAnchor("TOPLEFT", button, 0, 1)
  button._editorLabel:SetText(text or "")
  if button._editorLabel.style then
    if button._editorLabel.style.SetFontSize then button._editorLabel.style:SetFontSize(11) end
    if button._editorLabel.style.SetAlign then button._editorLabel.style:SetAlign(ALIGN.CENTER) end
    if button._editorLabel.style.SetColor then button._editorLabel.style:SetColor(1, 1, 1, 1) end
  end
  if button._editorLabel.EnablePick then button._editorLabel:EnablePick(false) end
  button._editorLabel:Show(true)
  function button:SetCleanText(nextText)
    if self._editorLabel then self._editorLabel:SetText(nextText or "") end
  end
end

local function setControlText(control, text)
  if control and control.SetCleanText then
    control:SetCleanText(text or "")
  elseif control and control.SetText then
    control:SetText(text or "")
  end
end

-- Simple dropdown function (from working version - user's preferred implementation)
local function simpleDropdown(parent, id, width, items, defaultText, onChanged, maxHeight)
  local btn = parent:CreateChildWidget("button", id, 0, true)
  api.Interface:ApplyButtonSkin(btn, BUTTON_BASIC.DEFAULT)
  btn:SetExtent(width, 28)
  local initial = defaultText or "Select option"
  btn:SetText(initial)
  if btn.style and btn.style.SetAlign then btn.style:SetAlign(ALIGN.LEFT) end
  
  -- menu & overlay
  local menu = api.Interface:CreateWindow(id..".menu", "", width, 0)
  menu:AddAnchor("TOPLEFT", btn, 0, btn:GetHeight()+6)
  addTint(menu, id..".sheet", 0.96, 0)
  menu:Show(false)
  
  local overlay = api.Interface:CreateEmptyWindow(id..".overlay")
  overlay:AddAnchor("TOPLEFT", "UIParent", 0, 0)
  overlay:AddAnchor("BOTTOMRIGHT", "UIParent", 0, 0)
  overlay:Show(false)
  function overlay:OnMouseUp()
    -- Simple approach: close dropdown, but scroll list clicks will be handled first
    menu:Show(false)
    overlay:Show(false)
  end
  overlay:SetHandler("OnMouseUp", overlay.OnMouseUp)
  
  -- Calculate menu height based on items
  local itemCount = #(items or {})
  local itemHeight = 24
  local calculatedHeight = math.min(itemCount * itemHeight + 10, maxHeight or 200)
  local menuWidth = width + 20
  menu:SetExtent(menuWidth, calculatedHeight)
  
  -- Add border
  local border = menu:CreateChildWidget("emptywidget", id.."_border", 0, true)
  border:AddAnchor("TOPLEFT", menu, 1, 1)
  border:AddAnchor("BOTTOMRIGHT", menu, -1, -1)
  addTint(border, id.."_borderTint", 0.15, 0.15)
  
  -- Create simple list of buttons for each item
  local menuButtons = {}
  local yOffset = 5
  
  for i, item in ipairs(items or {}) do
    local itemBtn = menu:CreateChildWidget("button", id.."_item_"..i, 0, true)
    itemBtn:SetExtent(menuWidth - 10, itemHeight - 2)
    itemBtn:AddAnchor("TOPLEFT", menu, 5, yOffset)
    
    -- Set item text
    local displayText = (type(item) == "string") and item or (item.text or item.label or tostring(item.value or ""))
    itemBtn:SetText(displayText)
    
    -- Style the button
    api.Interface:ApplyButtonSkin(itemBtn, BUTTON_BASIC.DEFAULT)
    if itemBtn.style then
      itemBtn.style:SetAlign(ALIGN.LEFT)
      itemBtn.style:SetFontSize(FONT_SIZE.DEFAULT)
    end
    
    -- Click handler
    function itemBtn:OnClick()
      local value = (type(item) == "string") and item or (item.value or displayText)
      btn:SetText(displayText)
      if onChanged then onChanged(value, displayText) end
      menu:Show(false)
      overlay:Show(false)
    end
    itemBtn:SetHandler("OnClick", itemBtn.OnClick)
    
    -- Hover effects
    function itemBtn:OnEnter()
      if itemBtn.style then
        itemBtn:SetTextColor(1, 1, 0.8, 1) -- Bright yellow on hover
      end
    end
    itemBtn:SetHandler("OnEnter", itemBtn.OnEnter)
    
    function itemBtn:OnLeave()
      if itemBtn.style then
        itemBtn:SetTextColor(0.95, 0.95, 0.95, 1) -- Back to white
      end
    end
    itemBtn:SetHandler("OnLeave", itemBtn.OnLeave)
    
    menuButtons[i] = itemBtn
    yOffset = yOffset + itemHeight
  end
  
  -- Button click to show/hide menu
  function btn:OnClick()
    local willShow = not menu:IsVisible()
    if willShow then 
      overlay:Show(true)
      menu:Show(true)
    else
      menu:Show(false)
      overlay:Show(false)
    end
  end
  btn:SetHandler("OnClick", btn.OnClick)
  
  function btn:GetPureText() return getPure(btn) end
  
  parent[id] = btn
  return btn
end

-- Character management
local characterSelectOptions = {"All Characters"}
local currentCharacter = ""

local function getSavedTaxTrackerCharacters()
  local characters = {}
  
  -- Get current settings
  local settings = api.GetSettings("tax_tracker") or {}
  
  -- Get from character list if exists
  if settings.characterList then
    for _, char in ipairs(settings.characterList) do
      table.insert(characters, char)
    end
  end
  
  -- Auto-discover from existing land data
  if settings.lands then
    for _, land in ipairs(settings.lands) do
      if land.character and land.character ~= "" then
        local found = false
        for _, existingChar in ipairs(characters) do
          if existingChar == land.character then
            found = true
            break
          end
        end
        if not found then
          table.insert(characters, land.character)
        end
      end
    end
  end
  
  return characters
end

local UIManager = {
  mainWindow = nil,
  components = {},
  eventHandlers = {},
  isInitialized = false,
  editingLand = nil,
  editingIndex = nil
}

-- Recompute function (matching working version logic)
function UIManager.recompute()
  if not UIManager.components then return end
  
  
  local landTypeBtn = UIManager.components.landTypeBtn
  local baseTaxValue = UIManager.components.baseTaxValue
  local realTaxValue = UIManager.components.realTaxValue
  local chkHostile = UIManager.components.chkHostile
  local chkTerritory = UIManager.components.chkTerritory
  local chkTaxExempt = UIManager.components.chkTaxExempt
  local ownedLabel = UIManager.components.ownedLabel
  
  if not landTypeBtn or not baseTaxValue or not realTaxValue then
    return
  end
  
  local lt = getPure(landTypeBtn)
  local base = BASE_TAX[lt] or 0
  baseTaxValue:SetText(fmt2(base))
  
  local isExempt = is_checked(chkTaxExempt)
  local real = 0
  
  if isExempt then
    -- Tax exempt: only base tax (no hostile, no territory, no ownership multiplier)
    real = base
  else
    -- Calculate tax based on actual position of this land in ownership hierarchy
    -- For existing lands being edited, determine their position by counting non-exempt lands BEFORE them
    local currentLands = UIManager.getCurrentLandData()
    local highTaxCount = 0
    local thisLandPosition = 0
    local thisLandIsBeingEdited = false
    
    -- First, determine if we're editing an existing land and find its position
    local editingLandId = UIManager.editingLand and UIManager.editingLand.id
    
    for i, land in ipairs(currentLands) do
      local isExempt = land.taxExempt
      -- Use CURRENT form checkbox state for the land being edited, not saved state
      local isCurrentlyExempt = isExempt
      if editingLandId and land.id == editingLandId then
        isCurrentlyExempt = is_checked(chkTaxExempt)
        thisLandIsBeingEdited = true
      end
      
      if not isCurrentlyExempt then
        highTaxCount = highTaxCount + 1
        if thisLandIsBeingEdited then
          thisLandPosition = highTaxCount
        end
      end
    end
    
    -- If this land is not exempt, its position matters for multiplier
    -- If we're adding a new land (not editing), use count + 1 as preview position
    local ownMult
    if thisLandIsBeingEdited and not is_checked(chkTaxExempt) then
      -- Editing existing non-exempt land: use its actual position in hierarchy
      ownMult = ownedMult(thisLandPosition)
    else
      -- Adding new land or editing exempt land: preview what position it would take
      ownMult = ownedMult(highTaxCount + 1)
    end
    
    local baseWithOwnership = base * ownMult
    local hostileBonus = is_checked(chkHostile) and base or 0
    local territoryBonus = is_checked(chkTerritory) and (base * 0.5) or 0
    real = math.floor(baseWithOwnership + hostileBonus + territoryBonus + 0.5) -- Round to nearest integer
  end
  
realTaxValue:SetText(fmt2(real))
   
  -- Uncheck hostile and territory checkboxes when tax exempt is checked
  -- (they don't apply to tax-exempt lands - user wants them unchecked, not disabled)
  if isExempt then
    if chkHostile and chkHostile.SetChecked then
      chkHostile:SetChecked(false)
    end
    if chkTerritory and chkTerritory.SetChecked then
      chkTerritory:SetChecked(false)
    end
  end
    
  -- Disable hostile and territory checkboxes when tax exempt is checked
  -- (they don't apply to tax-exempt lands)
  if chkHostile and chkHostile.SetEnabled then
    chkHostile:SetEnabled(not isExempt)
  end
  if chkTerritory and chkTerritory.SetEnabled then
    chkTerritory:SetEnabled(not isExempt)
  end
   
  -- Update owned label
if ownedLabel then
    local totalBuildings = #UIManager.getCurrentLandData()
    local highTaxBuildings = 0
    for _, land in ipairs(UIManager.getCurrentLandData()) do
      if not land.taxExempt then
        highTaxBuildings = highTaxBuildings + 1
      end
    end
    local currentMult = ownedMult(highTaxBuildings)
    local multPercent = math.floor((currentMult - 1) * 100)
    ownedLabel:SetText(string.format("Owned: %d (+%d%%)", totalBuildings, multPercent))
  end
   
end

-- Recalculate ALL lands' tax values to ensure consistency after ownership changes
-- This fixes the issue where saved tax values become stale when lands are added/removed/edited
function UIManager.recalculateAllLandTaxes()
  local settings = api.GetSettings("tax_tracker") or {}
  if not settings.lands or #settings.lands == 0 then return end
   
  -- Count non-exempt lands to determine multiplier tier
  local nonExemptCount = 0
  for _, land in ipairs(settings.lands) do
    if not land.taxExempt then
      nonExemptCount = nonExemptCount + 1
    end
  end
   
  -- Recalculate each land's tax based on total non-exempt count
  -- All non-exempt lands get the same multiplier based on total count
  local baseMultiplier = ownedMult(nonExemptCount)
   
  for _, land in ipairs(settings.lands) do
    local base = land.base or land.baseTax or 0
    local real = 0
   
    if land.taxExempt then
      real = base -- Just base, no bonuses
    else
      -- All non-exempt lands use same multiplier (simplified approach)
      local baseWithOwnership = base * baseMultiplier
      local hostileBonus = (land.hostile and base) or 0
      local territoryBonus = (land.territory and (base * 0.5)) or 0
      real = math.floor(baseWithOwnership + hostileBonus + territoryBonus + 0.5)
    end
   
    land.tax = real
  end
   
  -- Save updated taxes
  pcall(function() api.SaveSettings() end)
end

-- Get current land data helper
function UIManager.getCurrentLandData()
  local settings = api.GetSettings("tax_tracker") or {}
  return settings.lands or {}
end

-- Parse coordinates from display text (NEW: needed for coordinate handling)
local function parseCoordinatesFromDisplay(coordText)
  if not coordText or coordText == "" or coordText:find("No coordinates") or coordText:find("unavailable") or coordText:find("Click Track") then
    -- Return default coordinates
    return { lon = { dir = "E", deg = 0, min = 0, sec = 0 }, lat = { dir = "N", deg = 0, min = 0, sec = 0 } }
  end
  
  -- Parse format: "E15°30'45\" N25°10'20\""
  local lonDir, lonDeg, lonMin, lonSec, latDir, latDeg, latMin, latSec = 
    coordText:match("([EW])(%d+)°(%d+)'(%d+)\"[%s]*([NS])(%d+)°(%d+)'(%d+)\"")
  
  if lonDir and lonDeg and lonMin and lonSec and latDir and latDeg and latMin and latSec then
    return {
      lon = { 
        dir = lonDir, 
        deg = tonumber(lonDeg) or 0, 
        min = tonumber(lonMin) or 0, 
        sec = tonumber(lonSec) or 0 
      },
      lat = { 
        dir = latDir, 
        deg = tonumber(latDeg) or 0, 
        min = tonumber(latMin) or 0, 
        sec = tonumber(latSec) or 0 
      }
    }
  else
    return { lon = { dir = "E", deg = 0, min = 0, sec = 0 }, lat = { dir = "N", deg = 0, min = 0, sec = 0 } }
  end
end

-- Initialize UI Manager
function UIManager.initialize(dataManager, taxService)
  if UIManager.isInitialized then
    return true
  end
  
  UIManager.dataManager = dataManager
  UIManager.taxService = taxService
  
  
  -- Create main window
  local success = UIManager._createMainWindow()
  if not success then
    return false
  end
  
  -- Create form controls (Editor should only have Add Land form, no list)
  pcall(UIManager._createFormControls)

  -- Set up event handlers
  UIManager._setupEventHandlers()
  
  UIManager.isInitialized = true
  return true
end

-- Create main window
function UIManager._createMainWindow()
  local success, window = pcall(function()
    -- Destroy any TaxTrackerMain left alive from a previous addon load —
    -- otherwise each reload leaks another editor window.
    if api.Interface.FindWidget then
      local ok, orphan = pcall(api.Interface.FindWidget, api.Interface, "TaxTrackerMain")
      if ok and orphan then
        pcall(function()
          if orphan.Show then orphan:Show(false) end
          if orphan.RemoveAllAnchors then orphan:RemoveAllAnchors() end
          if orphan.Destroy then orphan:Destroy() end
        end)
      end
    end

    local mainWindow = gui.CreateStyledWindow("TaxTrackerMain", "Tax Tracker", 1040, 620)
    if not mainWindow then
      error("Failed to create window")
    end
    
    -- SetClampedToScreen not available in ArcheAge UI API, skipping
    mainWindow:AddAnchor("CENTER", "UIParent", 0, -120)
    mainWindow:Show(false)
    
    -- Create main content area (set to not intercept mouse clicks)
    local contentArea = api.Interface:CreateWidget("emptywidget", "TaxTracker.ContentArea", mainWindow)
    contentArea:AddAnchor("TOPLEFT", mainWindow, "TOPLEFT", 10, 35)
    contentArea:AddAnchor("BOTTOMRIGHT", mainWindow, "BOTTOMRIGHT", -10, -10)
    if contentArea.EnableMouse then contentArea:EnableMouse(false) end
    
    -- Create form section (set to not intercept mouse clicks)
    local formArea = api.Interface:CreateWidget("emptywidget", "TaxTracker.FormArea", contentArea)
    formArea:AddAnchor("TOPLEFT", contentArea, "TOPLEFT", 0, 0)
    formArea:AddAnchor("BOTTOMRIGHT", contentArea, "BOTTOMRIGHT", 0, 0)
    if formArea.EnableMouse then formArea:EnableMouse(false) end
    
    -- Store references
    UIManager.mainWindow = mainWindow
    UIManager.components.contentArea = contentArea
    UIManager.components.formArea = formArea
    
    return mainWindow
  end)
  
  if not success then
    return false
  end
  
  return true
end

-- Create complete editor form matching buildMainWindow exactly
function UIManager._createFormControls()
  local mainWin = UIManager.mainWindow
  if not mainWin then
    return false
  end

  local LEFT_X = 34
  local LABEL_W = 92
  local FIELD_X = 135
  local RIGHT_X = 560
  local ROW1_Y = 116
  local ROW_H = 42
  local TAX_Y = 274
  local CHECK_Y = 316
  local COORD_Y = 390

  gui.CreateCategoryPanel(mainWin, "editorDetailsPanel", 12, 42, 1016, 192, "Land Details")
  gui.CreateCategoryPanel(mainWin, "editorTaxPanel", 12, 242, 1016, 106, "Tax Rules")
  gui.CreateCategoryPanel(mainWin, "editorCoordsPanel", 12, 358, 1016, 88, "Coordinates")
  addEditorPanel(mainWin, "editorDetailsGroup", 20, 84, 1000, 142, EDITOR_UI.groupDetails)
  addEditorPanel(mainWin, "editorTaxGroup", 20, 274, 1000, 66, EDITOR_UI.groupTax)
  addEditorPanel(mainWin, "editorCoordsGroup", 20, 390, 1000, 48, EDITOR_UI.groupCoords)
  addEditorPanel(mainWin, "editorActionsPanel", 28, 482, 984, 72, EDITOR_UI.groupActions)

  local function placeLabel(lbl, x, y, w)
    if not lbl then return end
    lbl:RemoveAllAnchors()
    lbl:SetExtent(w or LABEL_W, 24)
    lbl:AddAnchor("TOPLEFT", mainWin, x, y)
    if lbl.style then
      lbl.style:SetAlign(ALIGN.LEFT)
      lbl.style:SetFontSize(12)
    end
    setEditorTextColor(lbl, EDITOR_UI.muted)
  end

  local function placeField(field, x, y, w, h)
    if not field then return end
    field:RemoveAllAnchors()
    field:SetExtent(w, h or 28)
    field:AddAnchor("TOPLEFT", mainWin, x, y)
    if field.style then
      if field.style.SetFontSize then field.style:SetFontSize(12) end
      if field.style.SetAlign then field.style:SetAlign(ALIGN.LEFT) end
      if field.style.SetColor then field.style:SetColor(1, 1, 1, 1) end
    end
  end
  
  -- Owned label (top right) - matching working version exactly
  local ownedLabel = mainWin:CreateChildWidget("label", "owned", 0, true)
  ownedLabel:SetExtent(180, 24)
  ownedLabel:AddAnchor("TOPRIGHT", mainWin, -24, 16)
  if ownedLabel.style then ownedLabel.style:SetAlign(ALIGN.RIGHT); ownedLabel.style:SetFontSize(12) end
  setEditorTextColor(ownedLabel, EDITOR_UI.gold)
  ownedLabel:SetText("Owned: 0 (+0%)")
  UIManager.components.ownedLabel = ownedLabel
  
  -- Land Name field (full width at top) - using gui.AddEditBox like working version
  addEditorInputBackplate(mainWin, "editorLandNameInputBg", FIELD_X - 3, ROW1_Y - 1, 436, 30)
  local landName = gui.AddEditBox(mainWin, "landName",
      "TOPLEFT", mainWin, LEFT_X, ROW1_Y, 500, 28, 64, "", "Land Name:")
  placeLabel(landName.label, LEFT_X, ROW1_Y + 2, LABEL_W)
  placeField(landName, FIELD_X, ROW1_Y, 430, 28)
  styleEditorEditBox(landName)
  UIManager.components.landName = landName
  
  -- Character Selection Row - exactly like working version
  gui.AddLabel(mainWin, "charLabel", "Character:", "TOPLEFT", mainWin, LEFT_X, ROW1_Y + ROW_H)
  placeLabel(mainWin.charLabel, LEFT_X, ROW1_Y + ROW_H + 2, LABEL_W)
  
  -- Reset and populate character options (exactly like working version)
  characterSelectOptions = {"All Characters"}
  local savedCharacters = getSavedTaxTrackerCharacters()
  for _, char in ipairs(savedCharacters) do
    table.insert(characterSelectOptions, char)
  end
  
  -- Add current player if not in list
  local playerName = getCurrentPlayerName()
  if playerName and playerName ~= "" then
    local found = false
    for _, char in ipairs(characterSelectOptions) do
      if char == playerName then
        found = true
        break
      end
    end
    if not found then
      table.insert(characterSelectOptions, playerName)
    end
  end
  
  -- Character dropdown using the same clean dropdown treatment as the loan list
  addEditorInputBackplate(mainWin, "editorCharInputBg", FIELD_X - 3, ROW1_Y + ROW_H - 1, 186, 30)
  local characterData = {
    { id = "characters", name = "Characters", tier = 0, expanded = true, value = "category_characters" }
  }
  for i, char in ipairs(characterSelectOptions) do
    table.insert(characterData, { id = "character_" .. i, name = char, tier = 1, expanded = false, value = char })
  end

  local characterSelect = HierarchicalDropdown.create(mainWin, "characterSelect", 180, characterData, "All Characters", function(val, label)
    if val == "All Characters" then
      currentCharacter = ""
    elseif val and val ~= "" then
      currentCharacter = val
    end
  end, 220, { cleanStyle = true })
  characterSelect:RemoveAllAnchors()
  characterSelect:AddAnchor("TOPLEFT", mainWin, FIELD_X, ROW1_Y + ROW_H)
  setControlText(characterSelect, currentCharacter ~= "" and currentCharacter or "All Characters")
  
  UIManager.components.characterSelect = characterSelect
  
  -- Land Type and Zone Row (side by side with proper spacing) - like working version
  gui.AddLabel(mainWin, "ltLabel", "Land Type:", "TOPLEFT", mainWin, LEFT_X, ROW1_Y + ROW_H * 2)
  placeLabel(mainWin.ltLabel, LEFT_X, ROW1_Y + ROW_H * 2 + 2, LABEL_W)
  
  -- Build land type items from BASE_TAX with proper dropdown structure (like working version)
  local function parseFootprint(name)
    -- Matches "(8x8)", "(16 x 16)", "(20×20)", etc.
    local w, h = name:match("%((%d+)%s*[xX×]%s*(%d+)%)")
    if w and h then return tonumber(w), tonumber(h) end
    -- Default to large size for unknowns so they sort to the end
    return 1000, 1000
  end
  
  -- Group land types by size like working version
  local groups = {g8={}, g16={}, g24={}, g28={}, g44={}, gOther={}}
  
  for landType, baseTax in pairs(BASE_TAX) do
    local w, h = parseFootprint(landType)
    local maxDim = math.max(w, h)
    
    if maxDim <= 8 then
      table.insert(groups.g8, landType)
    elseif maxDim <= 16 then
      table.insert(groups.g16, landType)  
    elseif maxDim <= 24 then
      table.insert(groups.g24, landType)
    elseif maxDim <= 28 then
      table.insert(groups.g28, landType)
    elseif maxDim <= 44 then
      table.insert(groups.g44, landType)
    else
      table.insert(groups.gOther, landType)
    end
  end
  
  -- Sort each group
  table.sort(groups.g8)
  table.sort(groups.g16) 
  table.sort(groups.g24)
  table.sort(groups.g28)
  table.sort(groups.g44)
  table.sort(groups.gOther)
  
  -- Build simple land type list for simpleDropdown (just strings)
  local landTypes = {}
  
  -- Add all land types in sorted order by size
  for _, landType in ipairs(groups.g8) do table.insert(landTypes, landType) end
  for _, landType in ipairs(groups.g16) do table.insert(landTypes, landType) end  
  for _, landType in ipairs(groups.g24) do table.insert(landTypes, landType) end
  for _, landType in ipairs(groups.g28) do table.insert(landTypes, landType) end
  for _, landType in ipairs(groups.g44) do table.insert(landTypes, landType) end
  for _, landType in ipairs(groups.gOther) do table.insert(landTypes, landType) end
  
  -- Create hierarchical land type data with proper tier structure
  local hierarchicalLandTypes = {
    -- Tier 0: Main categories
    { id = "g8", name = "8x8 Properties", tier = 0, expanded = false, value = "category_g8" },
    -- Tier 1: 8x8 items
  }
  
  -- Add 8x8 land types as tier 1 children
  for i, landType in ipairs(groups.g8) do
    table.insert(hierarchicalLandTypes, { id = "g8_" .. i, name = landType, tier = 1, expanded = false, value = landType })
  end
  
  -- Add 16x16 category and items
  table.insert(hierarchicalLandTypes, { id = "g16", name = "16x16 Properties", tier = 0, expanded = false, value = "category_g16" })
  for i, landType in ipairs(groups.g16) do
    table.insert(hierarchicalLandTypes, { id = "g16_" .. i, name = landType, tier = 1, expanded = false, value = landType })
  end
  
  -- Add 24x24 category and items
  table.insert(hierarchicalLandTypes, { id = "g24", name = "24x24 Properties", tier = 0, expanded = false, value = "category_g24" })
  for i, landType in ipairs(groups.g24) do
    table.insert(hierarchicalLandTypes, { id = "g24_" .. i, name = landType, tier = 1, expanded = false, value = landType })
  end
  
  -- Add 28x28 category and items  
  table.insert(hierarchicalLandTypes, { id = "g28", name = "28x28 Properties", tier = 0, expanded = false, value = "category_g28" })
  for i, landType in ipairs(groups.g28) do
    table.insert(hierarchicalLandTypes, { id = "g28_" .. i, name = landType, tier = 1, expanded = false, value = landType })
  end
  
  -- Add 44x44 category and items
  table.insert(hierarchicalLandTypes, { id = "g44", name = "44x44 Properties", tier = 0, expanded = false, value = "category_g44" })
  for i, landType in ipairs(groups.g44) do
    table.insert(hierarchicalLandTypes, { id = "g44_" .. i, name = landType, tier = 1, expanded = false, value = landType })
  end
  
  -- Add Other category and items
  table.insert(hierarchicalLandTypes, { id = "gOther", name = "Other Properties", tier = 0, expanded = false, value = "category_other" })
  for i, landType in ipairs(groups.gOther) do
    table.insert(hierarchicalLandTypes, { id = "gOther_" .. i, name = landType, tier = 1, expanded = false, value = landType })
  end
  
  -- Create land type dropdown using hierarchical implementation (like Zeroun's approach)
  addEditorInputBackplate(mainWin, "editorTypeInputBg", FIELD_X - 3, ROW1_Y + ROW_H * 2 - 1, 226, 30)
  local landTypeBtn = HierarchicalDropdown.create(mainWin, "landType", 220, hierarchicalLandTypes, "Select type", function(val, label)
    UIManager.recompute()
  end, 300, { cleanStyle = true })
  landTypeBtn:RemoveAllAnchors()
  landTypeBtn:AddAnchor("TOPLEFT", mainWin, FIELD_X, ROW1_Y + ROW_H * 2)
  UIManager.components.landTypeBtn = landTypeBtn
  
  -- Zone on the same row with spacing
  gui.AddLabel(mainWin, "zoneLbl", "Zone:", "TOPLEFT", mainWin, RIGHT_X, ROW1_Y + ROW_H * 2 + 2)
  placeLabel(mainWin.zoneLbl, RIGHT_X, ROW1_Y + ROW_H * 2 + 2, 58)
  
  -- Get zones using our Zones utility and create zone dropdown with structured data (like working version)
  local zoneNames, ZONE_ID_BY_NAME = Zones.getAllZones(api)
  
  -- Create hierarchical zone data with proper continent structure
  local hierarchicalZones = {
    -- Tier 0: Continents
    { id = "haranya", name = "Haranya (East)", tier = 0, expanded = false, value = "continent_haranya" },
    -- Tier 1: Haranya zones
    { id = "arcum", name = "Arcum Iris", tier = 1, expanded = false, value = "Arcum Iris" },
    { id = "falcorth", name = "Falcorth Plains", tier = 1, expanded = false, value = "Falcorth Plains" },
    { id = "hasla", name = "Hasla", tier = 1, expanded = false, value = "Hasla" },
    { id = "mahadevi", name = "Mahadevi", tier = 1, expanded = false, value = "Mahadevi" },
    { id = "perinoor", name = "Perinoor Ruins", tier = 1, expanded = false, value = "Perinoor Ruins" },
    { id = "rookborne", name = "Rookborne Basin", tier = 1, expanded = false, value = "Rookborne Basin" },
    { id = "silent", name = "Silent Forest", tier = 1, expanded = false, value = "Silent Forest" },
    { id = "solis", name = "Solis Headlands", tier = 1, expanded = false, value = "Solis Headlands" },
    { id = "sunbite", name = "Sunbite Wilds", tier = 1, expanded = false, value = "Sunbite Wilds" },
    { id = "tigerspine", name = "Tigerspine Mountains", tier = 1, expanded = false, value = "Tigerspine Mountains" },
    { id = "villanelle", name = "Villanelle", tier = 1, expanded = false, value = "Villanelle" },
    { id = "windscour", name = "Windscour Savannah", tier = 1, expanded = false, value = "Windscour Savannah" },
    { id = "ynystere", name = "Ynystere", tier = 1, expanded = false, value = "Ynystere" },
    { id = "rokhala", name = "Rokhala Mountains", tier = 1, expanded = false, value = "Rokhala Mountains" },
    
    -- Tier 0: Nuia
    { id = "nuia", name = "Nuia (West)", tier = 0, expanded = false, value = "continent_nuia" },
    -- Tier 1: Nuia zones
    { id = "aubre", name = "Aubre Cradle", tier = 1, expanded = false, value = "Aubre Cradle" },
    { id = "airain", name = "Airain Rock", tier = 1, expanded = false, value = "Airain Rock" },
    { id = "ahnimar", name = "Ahnimar", tier = 1, expanded = false, value = "Ahnimar" },
    { id = "cinderstone", name = "Cinderstone Moor", tier = 1, expanded = false, value = "Cinderstone Moor" },
    { id = "dewstone", name = "Dewstone Plains", tier = 1, expanded = false, value = "Dewstone Plains" },
    { id = "gweonid", name = "Gweonid Forest", tier = 1, expanded = false, value = "Gweonid Forest" },
    { id = "halcyona", name = "Halcyona", tier = 1, expanded = false, value = "Halcyona" },
    { id = "hellswamp", name = "Hellswamp", tier = 1, expanded = false, value = "Hellswamp" },
    { id = "karkasse", name = "Karkasse Ridgelands", tier = 1, expanded = false, value = "Karkasse Ridgelands" },
    { id = "lilyut", name = "Lilyut Hills", tier = 1, expanded = false, value = "Lilyut Hills" },
    { id = "marianople", name = "Marianople", tier = 1, expanded = false, value = "Marianople" },
    { id = "sanddeep", name = "Sanddeep", tier = 1, expanded = false, value = "Sanddeep" },
    { id = "solzreed", name = "Solzreed Peninsula", tier = 1, expanded = false, value = "Solzreed Peninsula" },
    { id = "twocrowns", name = "Two Crowns", tier = 1, expanded = false, value = "Two Crowns" },
    { id = "whitearden", name = "White Arden", tier = 1, expanded = false, value = "White Arden" },
    
    -- Tier 0: Auroria
    { id = "auroria", name = "Auroria", tier = 0, expanded = false, value = "continent_auroria" },
    -- Tier 1: Auroria zones
    { id = "diamondshores", name = "Diamond Shores", tier = 1, expanded = false, value = "Diamond Shores" },
    { id = "goldenruins", name = "Golden Ruins", tier = 1, expanded = false, value = "Golden Ruins" },
    { id = "sungold", name = "Sungold Fields", tier = 1, expanded = false, value = "Sungold Fields" },
    { id = "calmlands", name = "Calmlands", tier = 1, expanded = false, value = "Calmlands" },
    { id = "marcala", name = "Marcala", tier = 1, expanded = false, value = "Marcala" },
    { id = "heedmar", name = "Heedmar", tier = 1, expanded = false, value = "Heedmar" },
    { id = "nuimari", name = "Nuimari", tier = 1, expanded = false, value = "Nuimari" },
    { id = "exeloch", name = "Exeloch", tier = 1, expanded = false, value = "Exeloch" },
    { id = "reedwind", name = "Reedwind", tier = 1, expanded = false, value = "Reedwind" },
    { id = "mistmerrow", name = "Mistmerrow", tier = 1, expanded = false, value = "Mistmerrow" },
    { id = "whalesong", name = "Whalesong Harbor", tier = 1, expanded = false, value = "Whalesong Harbor" },
    { id = "aegis", name = "Aegis Island", tier = 1, expanded = false, value = "Aegis Island" },
    
    -- Tier 0: Seas & Ocean Zones
    { id = "seas", name = "Seas & Ocean Zones", tier = 0, expanded = false, value = "continent_seas" },
    -- Tier 1: Sea zones
    { id = "arcadiansea", name = "Arcadian Sea", tier = 1, expanded = false, value = "Arcadian Sea" },
    { id = "sunspecksea", name = "Sunspeck Sea", tier = 1, expanded = false, value = "Sunspeck Sea" },
    { id = "castaway", name = "Castaway Strait", tier = 1, expanded = false, value = "Castaway Strait" },
    { id = "halcyonagulf", name = "Halcyona Gulf", tier = 1, expanded = false, value = "Halcyona Gulf" },
    { id = "seagraves", name = "Sea of Graves", tier = 1, expanded = false, value = "Sea of Graves" },
    { id = "stormraw", name = "Stormraw Sound", tier = 1, expanded = false, value = "Stormraw Sound" },
    { id = "whaleswell", name = "Whaleswell Straits", tier = 1, expanded = false, value = "Whaleswell Straits" },
    { id = "feuille", name = "Feuille Sound", tier = 1, expanded = false, value = "Feuille Sound" },
    { id = "shattered", name = "Shattered Sea", tier = 1, expanded = false, value = "Shattered Sea" },
    
    -- Tier 0: Islands & Special
    { id = "islands", name = "Islands & Special", tier = 0, expanded = false, value = "continent_islands" },
    -- Tier 1: Islands
    { id = "growlgate", name = "Growlgate Isle", tier = 1, expanded = false, value = "Growlgate Isle" }
  }
  
  -- Create zone dropdown using hierarchical implementation (like Zeroun's approach)
  addEditorInputBackplate(mainWin, "editorZoneInputBg", RIGHT_X + 61, ROW1_Y + ROW_H * 2 - 1, 226, 30)
  local zoneBtn = HierarchicalDropdown.create(mainWin, "zone", 220, hierarchicalZones, "Select zone", function(val, label)
  end, 300, { cleanStyle = true })
  zoneBtn:RemoveAllAnchors()
  zoneBtn:AddAnchor("TOPLEFT", mainWin, RIGHT_X + 64, ROW1_Y + ROW_H * 2)
  UIManager.components.zoneBtn = zoneBtn
  
  -- Tax Row (Base and Real side by side with proper spacing) - like working version
  gui.AddLabel(mainWin, "baseLabel", "Base Tax:", "TOPLEFT", mainWin, LEFT_X, TAX_Y)
  placeLabel(mainWin.baseLabel, LEFT_X, TAX_Y + 2, LABEL_W)
  addEditorInputBackplate(mainWin, "editorBaseTaxInputBg", FIELD_X - 3, TAX_Y - 1, 126, 30)
  local baseTaxValue = gui.AddEditBox(mainWin, "baseTaxValue",
      "TOPLEFT", mainWin, FIELD_X, TAX_Y, 120, 28, nil, "", nil)
  placeField(baseTaxValue, FIELD_X, TAX_Y, 120, 28)
  styleEditorEditBox(baseTaxValue)
  if baseTaxValue.SetReadOnly then baseTaxValue:SetReadOnly(true) end
  UIManager.components.baseTaxValue = baseTaxValue
  
  gui.AddLabel(mainWin, "realLabel", "Real Tax:", "TOPLEFT", mainWin, RIGHT_X, TAX_Y + 2)
  placeLabel(mainWin.realLabel, RIGHT_X, TAX_Y + 2, 75)
  addEditorInputBackplate(mainWin, "editorRealTaxInputBg", RIGHT_X + 85, TAX_Y - 1, 126, 30)
  local realTaxValue = gui.AddEditBox(mainWin, "realTaxValue",
      "TOPLEFT", mainWin, RIGHT_X + 88, TAX_Y, 120, 28, nil, "", nil)
  placeField(realTaxValue, RIGHT_X + 88, TAX_Y, 120, 28)
  styleEditorEditBox(realTaxValue)
  if realTaxValue.SetReadOnly then realTaxValue:SetReadOnly(true) end
  UIManager.components.realTaxValue = realTaxValue
  
  -- Checkboxes Row (aligned under taxes with proper spacing) - like working version
  local hostile = gui.AddCheckbox(mainWin, "chkHostile", "Hostile Faction Tax (+100%)", false,
      "TOPLEFT", mainWin, LEFT_X, CHECK_Y, 4)
  local territory = gui.AddCheckbox(mainWin, "chkTerritory", "Territory Tax (+50%)", false,
      "TOPLEFT", mainWin, LEFT_X + 280, CHECK_Y, 4)
  local exempt = gui.AddCheckbox(mainWin, "chkTaxExempt", "Tax Exempt", false,
      "TOPLEFT", mainWin, LEFT_X + 530, CHECK_Y, 4)
  
  UIManager.components.chkHostile = hostile
  UIManager.components.chkTerritory = territory
  UIManager.components.chkTaxExempt = exempt
  
  -- Add recompute event handlers to checkboxes (like working version)
  if hostile.SetHandler then hostile:SetHandler("OnCheckChanged", UIManager.recompute) end
  if territory.SetHandler then territory:SetHandler("OnCheckChanged", UIManager.recompute) end
  if exempt.SetHandler then exempt:SetHandler("OnCheckChanged", UIManager.recompute) end
  
  -- Coordinates Section - simplified version of working version  
  gui.AddLabel(mainWin, "coordsHeader", "Coordinates:", "TOPLEFT", mainWin, LEFT_X, COORD_Y)
  placeLabel(mainWin.coordsHeader, LEFT_X, COORD_Y + 2, LABEL_W)
  
  -- Simple coordinate display (will enhance later with full lat/lon system)
  addEditorInputBackplate(mainWin, "editorCoordsInputBg", FIELD_X - 3, COORD_Y - 1, 336, 30)
  local coordsDisplay = gui.AddEditBox(mainWin, "coordsDisplay",
      "TOPLEFT", mainWin, FIELD_X, COORD_Y, 330, 28, nil, "0,0 (Click Track Position)", nil)
  placeField(coordsDisplay, FIELD_X, COORD_Y, 330, 28)
  styleEditorEditBox(coordsDisplay)
  if coordsDisplay.SetReadOnly then coordsDisplay:SetReadOnly(true) end
  UIManager.components.coordsDisplay = coordsDisplay
  
  -- Track Position Button
  local trackPosBtn = mainWin:CreateChildWidget("button", "trackPosBtn", 0, true)
  trackPosBtn:SetExtent(180, 28)
  trackPosBtn:AddAnchor("TOPLEFT", mainWin, RIGHT_X, COORD_Y)
  styleEditorButton(trackPosBtn, "Track Position", 180, 28, EDITOR_UI.green)
  
  function trackPosBtn:OnClick()
    local coords = getCurrentSextant()
    if coords then
      local coordText = string.format("%s%d°%d'%d\" %s%d°%d'%d\"", 
          coords.lon.dir, coords.lon.deg, coords.lon.min, coords.lon.sec,
          coords.lat.dir, coords.lat.deg, coords.lat.min, coords.lat.sec)
      coordsDisplay:SetText(coordText)
    else
      coordsDisplay:SetText("Coordinates unavailable")
    end
  end
  trackPosBtn:SetHandler("OnClick", trackPosBtn.OnClick)
  UIManager.components.trackPosBtn = trackPosBtn
  
  -- Track Target Position Button (next to Track Position button, like working version)
  local trackTargetBtn = mainWin:CreateChildWidget("button", "trackTargetBtn", 0, true)
  trackTargetBtn:SetExtent(180, 28)
  trackTargetBtn:AddAnchor("TOPLEFT", mainWin, RIGHT_X + 190, COORD_Y)
  styleEditorButton(trackTargetBtn, "From Target", 180, 28, EDITOR_UI.green)
  
  function trackTargetBtn:OnClick()
    -- Get coordinates and target name from getTargetSextant
    local coords, targetName = getTargetSextant()
    
    -- Fill coordinates
    if coords then
      local coordText = string.format("%s%d°%d'%d\" %s%d°%d'%d\"", 
          coords.lon.dir, coords.lon.deg, coords.lon.min, coords.lon.sec,
          coords.lat.dir, coords.lat.deg, coords.lat.min, coords.lat.sec)
      coordsDisplay:SetText(coordText)
    else
      coordsDisplay:SetText("No target selected")
    end
    
    -- Handle target name - ALWAYS put in land name field AND try to match land type
    if targetName and targetName ~= "" then
      -- ALWAYS set the land name field with target name
      if UIManager.components.landName then
        UIManager.components.landName:SetText(targetName)
      end
      
      -- ALSO try to match target name to a land type for the dropdown
      local matchedLandType = matchLandTypeFromName(targetName)
      if matchedLandType then
        if UIManager.components.landTypeBtn then
          setControlText(UIManager.components.landTypeBtn, matchedLandType)
        end
      end

      if UIManager.components.chkTaxExempt and UIManager.components.chkTaxExempt.SetChecked then
        UIManager.components.chkTaxExempt:SetChecked(isAutoTaxExemptLandName(targetName))
      end

      UIManager.recompute()
    end
    
    -- Fill character with current player
    local playerName = getCurrentPlayerName()
    if playerName and playerName ~= "" then
      if UIManager.components.characterSelect then
        setControlText(UIManager.components.characterSelect, playerName)
        currentCharacter = playerName
      end
    end
    
    -- Fill zone with current player zone using GetCurrentZoneGroup
    local zoneName = getCurrentZoneName()
    if zoneName and zoneName ~= "" and UIManager.components.zoneBtn then
      setControlText(UIManager.components.zoneBtn, zoneName)
    end
  end
  trackTargetBtn:SetHandler("OnClick", trackTargetBtn.OnClick)
  UIManager.components.trackTargetBtn = trackTargetBtn
  
  -- ADD button (bottom right) - same pattern as working buttons above
  local addBtn = mainWin:CreateChildWidget("button", "addBtn", 0, true)
  addBtn:SetExtent(200, 42)
  addBtn:AddAnchor("BOTTOMRIGHT", mainWin, -36, -36)
  styleEditorButton(addBtn, "ADD", 200, 42, EDITOR_UI.green)
  UIManager.components.addButton = addBtn
  
  function addBtn:OnClick()
    local isEditing = UIManager.editingLand ~= nil

    -- Collect form data from dropdowns and inputs
    local landData = {
      name = UIManager.components.landName:GetText() or "",
      landType = getPure(UIManager.components.landTypeBtn) or "",
      zoneName = getPure(UIManager.components.zoneBtn) or "",
      character = currentCharacter ~= "" and currentCharacter or getCurrentPlayerName(),
      base = tonumber(UIManager.components.baseTaxValue:GetText()) or 0,
      hostile = UIManager.components.chkHostile and UIManager.components.chkHostile:GetChecked() or false,
      territory = UIManager.components.chkTerritory and UIManager.components.chkTerritory:GetChecked() or false,
      taxExempt = UIManager.components.chkTaxExempt and UIManager.components.chkTaxExempt:GetChecked() or false
    }
    
    -- FIXED: Collect coordinate data from coordsDisplay
    if UIManager.components.coordsDisplay then
      local coordText = UIManager.components.coordsDisplay:GetText() or ""
      landData.coords = parseCoordinatesFromDisplay(coordText)
    else
      landData.coords = { lon = { dir = "E", deg = 0, min = 0, sec = 0 }, lat = { dir = "N", deg = 0, min = 0, sec = 0 } }
    end
    
    -- Validation: prevent adding lands with default dropdown values
    if not landData.landType or landData.landType == "" or landData.landType == "Select type" or (landData.landType:find("Select") ~= nil) then
      api.Log:Info("[Tax Tracker] Please select a land type")
      return
    end

    if not landData.zoneName or landData.zoneName == "" or landData.zoneName == "Select zone" or (landData.zoneName:find("Select") ~= nil) then
      api.Log:Info("[Tax Tracker] Please select a zone")
      return
    end

    if not landData.name or landData.name == "" then
      api.Log:Info("[Tax Tracker] Please enter a land name")
      return
    end
    
    local settings = api.GetSettings("tax_tracker") or {}
    if not settings.lands then settings.lands = {} end
    
    if isEditing then
      -- Update existing land. Look up by unique id, NOT by editingIndex —
      -- the Edit button in landtable passes a per-zone row index, which
      -- doesn't match the global settings.lands index, so indexing by it
      -- silently rewrites the wrong land and leaves the user's edit looking
      -- like a duplicate insertion.
      local targetId = UIManager.editingLand and UIManager.editingLand.id
      local existingLand = nil
      if targetId then
        for _, savedLand in ipairs(settings.lands) do
          if savedLand.id == targetId then
            existingLand = savedLand
            break
          end
        end
      end

      if existingLand then
        existingLand.name = landData.name
        existingLand.landType = landData.landType
        existingLand.type = landData.landType
        existingLand.zoneName = landData.zoneName
        existingLand.zone = landData.zoneName
        existingLand.character = landData.character
        existingLand.base = landData.base
        existingLand.baseTax = landData.base
        existingLand.hostile = landData.hostile
        existingLand.territory = landData.territory
        existingLand.taxExempt = landData.taxExempt
        existingLand.tax = tonumber(UIManager.components.realTaxValue:GetText()) or landData.base
        existingLand.coords = landData.coords
        -- Recalculate ALL lands' taxes (exempt status change affects all)
        UIManager.recalculateAllLandTaxes()
local saveSuccess = pcall(function() api.SaveSettings() end)
      if saveSuccess then
        UIManager.clearEditMode()
        UIManager.hideWindow()
        if not SavedLandsWindow then SavedLandsWindow = require("tax_tracker/ui/savedlandswindow") end
        if SavedLandsWindow.refreshData then SavedLandsWindow.refreshData() end
      end
    else
        api.Log:Err("[Tax Tracker] Edit failed: land id " .. tostring(targetId) .. " not found")
      end
    else
      -- Add new land
      landData.type = landData.landType
      landData.zone = landData.zoneName
      landData.zoneId = 323
      landData.tax = tonumber(UIManager.components.realTaxValue:GetText()) or landData.base
      landData.dueDate = "Not calculated"

      -- Generate sequential ID: find highest existing ID and add 1
      local maxId = 0
      for _, land in ipairs(settings.lands) do
        if land.id and land.id > maxId then
          maxId = land.id
        end
      end
      landData.id = maxId + 1

      table.insert(settings.lands, landData)
      UIManager.recalculateAllLandTaxes()
      local saveSuccess = pcall(function() api.SaveSettings() end)
      if saveSuccess then
        UIManager.clearEditMode()
        UIManager.hideWindow()
        if not SavedLandsWindow then SavedLandsWindow = require("tax_tracker/ui/savedlandswindow") end
        if SavedLandsWindow.refreshData then SavedLandsWindow.refreshData() end
      else
        api.Log:Err("[Tax Tracker] Failed to save land")
      end
    end
  end
  addBtn:SetHandler("OnClick", addBtn.OnClick)
  
  -- Initial recompute to set up tax calculations (like working version)
  UIManager.recompute()
  
  return true
end

-- Clear edit mode and reset form
function UIManager.clearEditMode()
  if not UIManager.components then return end
  
  -- Reset editing state
  UIManager.editingLand = nil
  UIManager.editingIndex = nil
  
  -- Clear form fields (new components)
  if UIManager.components.landName then UIManager.components.landName:SetText("") end
  if UIManager.components.landTypeBtn then setControlText(UIManager.components.landTypeBtn, "Select type") end
  if UIManager.components.zoneBtn then setControlText(UIManager.components.zoneBtn, "Select zone") end
  if UIManager.components.baseTaxValue then UIManager.components.baseTaxValue:SetText("") end
  if UIManager.components.realTaxValue then UIManager.components.realTaxValue:SetText("") end
  
  -- Reset checkboxes
  if UIManager.components.chkHostile and UIManager.components.chkHostile.SetChecked then 
    UIManager.components.chkHostile:SetChecked(false) 
  end
  if UIManager.components.chkTerritory and UIManager.components.chkTerritory.SetChecked then 
    UIManager.components.chkTerritory:SetChecked(false) 
  end  
  if UIManager.components.chkTaxExempt and UIManager.components.chkTaxExempt.SetChecked then 
    UIManager.components.chkTaxExempt:SetChecked(false) 
  end
  
  -- Reset character selection
  if UIManager.components.characterSelect then 
    setControlText(UIManager.components.characterSelect, "All Characters")
  end
  currentCharacter = ""
  
  -- Reset button text to "ADD"
  if UIManager.components.addButton then
    if UIManager.components.addButton.SetCleanText then
      UIManager.components.addButton:SetCleanText("ADD")
    else
      UIManager.components.addButton:SetText("ADD")
    end
  end
  
end

-- Show window
function UIManager.showWindow()
  if UIManager.mainWindow then
    UIManager.mainWindow:Show(true)
  end
end

-- Hide window  
function UIManager.hideWindow()
  if UIManager.mainWindow then
    UIManager.mainWindow:Show(false)
    -- Clear edit mode when hiding (like original behavior)
    UIManager.clearEditMode()
  end
end

-- Toggle window visibility
function UIManager.toggleWindow()
  if UIManager.mainWindow then
    local isVisible = UIManager.mainWindow:IsVisible()
    if isVisible then
      UIManager.hideWindow()
    else
      UIManager.showWindow()
    end
  end
end

-- Enter edit mode for existing land
function UIManager.setEditMode(landData, landIndex)
  if not UIManager.components then
    return false
  end

  -- Store editing state
  UIManager.editingLand = landData
  UIManager.editingIndex = landIndex
  
  -- Populate form fields (using correct component names)
  if UIManager.components.landName then UIManager.components.landName:SetText(landData.name or "") end
  if UIManager.components.landTypeBtn then 
    local landType = landData.type or landData.landType or ""
    setControlText(UIManager.components.landTypeBtn, landType) 
  end
  if UIManager.components.zoneBtn then 
    local zone = landData.zone or landData.zoneName or ""
    setControlText(UIManager.components.zoneBtn, zone) 
  end
  if UIManager.components.baseTaxValue then UIManager.components.baseTaxValue:SetText(fmt2(landData.base or landData.baseTax or 0)) end
  if UIManager.components.realTaxValue then UIManager.components.realTaxValue:SetText(fmt2(landData.tax or 0)) end
  
  -- Set checkboxes
  if UIManager.components.chkHostile and UIManager.components.chkHostile.SetChecked then
    UIManager.components.chkHostile:SetChecked(landData.hostile or false)
  end
  if UIManager.components.chkTerritory and UIManager.components.chkTerritory.SetChecked then
    UIManager.components.chkTerritory:SetChecked(landData.territory or false)
  end
  if UIManager.components.chkTaxExempt and UIManager.components.chkTaxExempt.SetChecked then
    UIManager.components.chkTaxExempt:SetChecked(landData.taxExempt or false)
  end
  -- Only call recompute if checkboxes were changed by user (not on initial load)
  -- Otherwise the saved tax value gets overwritten with current ownership calculation
  if landData.tax and landData.tax > 0 then
    UIManager.components.realTaxValue:SetText(fmt2(landData.tax))
  else
    UIManager.recompute()
  end
  if landData.character then
    currentCharacter = landData.character
    if UIManager.components.characterSelect then
      setControlText(UIManager.components.characterSelect, landData.character)
    end
  end
  
  -- Set coordinates (NEW: missing coordinate data loading)
  if landData.coords and UIManager.components.coordsDisplay then
    local coords = landData.coords
    if coords.lon and coords.lat then
      local coordText = string.format("%s%d°%d'%d\" %s%d°%d'%d\"", 
          coords.lon.dir or "E", coords.lon.deg or 0, coords.lon.min or 0, coords.lon.sec or 0,
          coords.lat.dir or "N", coords.lat.deg or 0, coords.lat.min or 0, coords.lat.sec or 0)
      UIManager.components.coordsDisplay:SetText(coordText)
    else
      UIManager.components.coordsDisplay:SetText("No coordinates saved")
    end
  elseif UIManager.components.coordsDisplay then
    UIManager.components.coordsDisplay:SetText("No coordinates saved")
  end
  
  -- Change button text to "Update"
  if UIManager.components.addButton then
    if UIManager.components.addButton.SetCleanText then
      UIManager.components.addButton:SetCleanText("Update")
    else
      UIManager.components.addButton:SetText("Update")
    end
  end
  
  -- Show the window
  if UIManager.mainWindow then
    UIManager.mainWindow:Show(true)
  end
  
  return true
end

-- Setup event handlers
function UIManager._setupEventHandlers()
  -- Event handlers can be added here as needed
end

-- Cleanup function
function UIManager.cleanup()
  if UIManager.mainWindow and UIManager.mainWindow.Destroy then
    pcall(function() UIManager.mainWindow:Destroy() end)
  end
  
  UIManager.mainWindow = nil
  UIManager.components = {}
  UIManager.eventHandlers = {}
  UIManager.isInitialized = false
  UIManager.dataManager = nil
  UIManager.taxService = nil
  UIManager.editingLand = nil
  UIManager.editingIndex = nil
  
end

return UIManager
