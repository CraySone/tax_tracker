-- tax_tracker/ui/icon_hudmanager.lua - Icon-based HUD Button (buff_helper style)
local api = require("api")

local IconHUDManager = {}

-- HUD state - SINGLETON PATTERN
local hudRoot = nil
local hudIcon = nil
local isInitialized = false
local currentCallback = nil

-- Tax Certificate item ID for the icon
local TAX_CERT_ITEM_ID = 31891

-- Initialize Icon-based HUD
function IconHUDManager.initialize(toggleCallback)
  -- STRICT SINGLETON: Only allow one initialization
  if isInitialized and hudRoot and hudRoot.Show and hudIcon and hudIcon.SetHandler then
    if toggleCallback and toggleCallback ~= currentCallback then
      currentCallback = toggleCallback
      hudIcon:SetHandler("OnClick", function()
        if currentCallback then currentCallback() end
      end)
    end
    return true
  end

  -- Cleanup stale state
  IconHUDManager.cleanup()

  local success = pcall(function()
    -- Create root window with UIParent as parent (CRITICAL: prevents fullscreen overlay)
    hudRoot = api.Interface:CreateEmptyWindow("TaxTrackerIconHUDRoot", "UIParent")
    if not hudRoot then return false end

    -- CRITICAL: Size hudRoot to ONLY the icon area (40x40) to prevent fullscreen blocking
    hudRoot:SetExtent(40, 40)
    hudRoot:AddAnchor("TOPRIGHT", "UIParent", "TOPRIGHT", -120, 10)

    -- Create icon button as child of hudRoot
    hudIcon = hudRoot:CreateChildWidget("button", "TaxTrackerIconBtn", 0, true)
    if not hudIcon then return false end

    -- Set icon size BEFORE applying skin
    hudIcon:SetExtent(38, 38)
    hudIcon:AddAnchor("CENTER", hudRoot, 0, 0)

    -- Apply slot skin (creates the button background)
    pcall(function()
      F_SLOT.ApplySlotSkin(hudIcon, hudIcon.back, SLOT_STYLE.BAG_DEFAULT)
    end)

    -- Set icon texture using Tax Certificate item icon
    pcall(function()
      if F_SLOT and F_SLOT.SetIconBackGround and api.Item and api.Item.GetItemInfoByType then
        local itemInfo = api.Item:GetItemInfoByType(TAX_CERT_ITEM_ID)
        if itemInfo and itemInfo.path then
          F_SLOT.SetIconBackGround(hudIcon, itemInfo.path)
        end
      end
    end)

    -- Tooltip on hover
    local function showTooltip()
      if api.Interface and api.Interface.SetTooltipOnPos then
        pcall(function()
          api.Interface:SetTooltipOnPos(hudIcon, "Tax Tracker", POINT.BOTTOM_LEFT, 0, -5)
        end)
      end
    end

    local function hideTooltip()
      if api.Interface and api.Interface.Free then
        pcall(function() api.Interface:Free(hudIcon) end)
      end
    end

    -- Make icon clickable
    hudIcon:Show(true)
    hudIcon:Enable(true)
    hudRoot:Show(true)

    -- Set click handler
    if toggleCallback then
      currentCallback = toggleCallback
      hudIcon:SetHandler("OnClick", function()
        pcall(function()
          if currentCallback then currentCallback() end
        end)
      end)
    end

    -- Hover handlers for tooltip
    hudIcon:SetHandler("OnEnter", showTooltip)
    hudIcon:SetHandler("OnLeave", hideTooltip)

    isInitialized = true
    return true
  end)

  return success or false
end

-- Show/Hide HUD
function IconHUDManager.show()
  if hudRoot then
    hudRoot:Show(true)
  end
end

function IconHUDManager.hide()
  if hudRoot then
    hudRoot:Show(false)
  end
end

-- Get HUD visibility
function IconHUDManager.isVisible()
  return hudRoot and hudRoot:IsVisible() or false
end

-- Cleanup
function IconHUDManager.cleanup()
  if hudRoot and hudRoot.Show then
    pcall(function() hudRoot:Show(false) end)
  end
  hudRoot = nil
  hudIcon = nil
  currentCallback = nil
  isInitialized = false
end

return IconHUDManager
