-- tax_tracker/ui/dropdown.lua - Reusable dropdown component
local Debug = require("tax_tracker/debug")

local Dropdown = {}
Dropdown.__index = Dropdown

-- Constructor
function Dropdown:new(options)
  local dropdown = {
    id = options.id or "dropdown",
    parent = options.parent,
    items = options.items or {},
    onSelectionChanged = options.onSelectionChanged,
    placeholder = options.placeholder or "Select...",
    width = options.width or 200,
    height = options.height or 28,
    maxHeight = options.maxHeight or 250,
    multiSelect = options.multiSelect or false,
    hierarchical = options.hierarchical or false,
    
    -- Internal state
    button = nil,
    menu = nil,
    overlay = nil,
    isOpen = false,
    selectedValue = nil,
    selectedText = options.placeholder or "Select..."
  }
  
  setmetatable(dropdown, {__index = self})
  dropdown:_init()
  return dropdown
end

-- Initialize dropdown UI
function Dropdown:_init()
  if not self.parent then
    Debug.error("Dropdown", "Parent widget is required", {id = self.id})
    return
  end
  
  -- Create main button
  local api = require("api")
  self.button = self.parent:CreateChildWidget("button", self.id .. "_btn", 0, true)
  api.Interface:ApplyButtonSkin(self.button, BUTTON_BASIC.DEFAULT)
  self.button:SetExtent(self.width, self.height)
  self.button:SetText(self.selectedText .. " ▾")
  
  -- Button click handler
  function self.button:OnClick()
    dropdown:toggle()
  end
  self.button:SetHandler("OnClick", self.button.OnClick)
  
  Debug.info("Dropdown", "Dropdown initialized", {id = self.id})
end

-- Toggle dropdown open/closed
function Dropdown:toggle()
  if self.isOpen then
    self:close()
  else
    self:open()
  end
end

-- Open dropdown menu
function Dropdown:open()
  if self.isOpen then return end
  
  self:_createMenu()
  self.isOpen = true
  
  Debug.debug("Dropdown", "Dropdown opened", {id = self.id, itemCount = #self.items})
end

-- Close dropdown menu
function Dropdown:close()
  if not self.isOpen then return end
  
  if self.menu then
    self.menu:Show(false)
  end
  if self.overlay then
    self.overlay:Show(false)
  end
  
  self.isOpen = false
  
  Debug.debug("Dropdown", "Dropdown closed", {id = self.id})
end

-- Create dropdown menu
function Dropdown:_createMenu()
  local api = require("api")
  
  -- Create overlay for click-away detection
  if not self.overlay then
    self.overlay = api.Interface:CreateEmptyWindow(self.id .. "_overlay")
    self.overlay:AddAnchor("TOPLEFT", "UIParent", 0, 0)
    self.overlay:AddAnchor("BOTTOMRIGHT", "UIParent", 0, 0)
    
    function self.overlay:OnMouseUp()
      Debug.trace("Dropdown", "Overlay clicked - closing dropdown")
      dropdown:close()
    end
    self.overlay:SetHandler("OnMouseUp", self.overlay.OnMouseUp)
  end
  
  -- Create menu window
  if not self.menu then
    self.menu = api.Interface:CreateEmptyWindow(self.id .. "_menu")
    self.menu:SetExtent(self.width + 20, math.min(#self.items * 24 + 10, self.maxHeight))
    
    -- Position menu below button
    self.menu:RemoveAllAnchors()
    self.menu:AddAnchor("TOPLEFT", self.button, "BOTTOMLEFT", -10, 2)
    
    -- Add background and border
    local bg = self.menu:CreateChildWidget("emptywidget", self.id .. "_bg", 0, true)
    bg:AddAnchor("TOPLEFT", self.menu, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", self.menu, 0, 0)
    if bg.SetColor then bg:SetColor(0.1, 0.1, 0.1, 0.9) end
    
    local border = self.menu:CreateChildWidget("emptywidget", self.id .. "_border", 0, true)
    border:AddAnchor("TOPLEFT", self.menu, 1, 1)
    border:AddAnchor("BOTTOMRIGHT", self.menu, -1, -1)
    if border.SetColor then border:SetColor(0.3, 0.3, 0.3, 1.0) end
  end
  
  -- Create menu items
  self:_createMenuItems()
  
  -- Show menu and overlay
  self.overlay:Show(true)
  self.menu:Show(true)
  self.menu:Raise()
end

-- Create menu items
function Dropdown:_createMenuItems()
  if self.hierarchical then
    self:_createHierarchicalItems()
  else
    self:_createFlatItems()
  end
end

-- Create flat menu items
function Dropdown:_createFlatItems()
  for i, item in ipairs(self.items) do
    local itemBtn = self.menu:CreateChildWidget("button", self.id .. "_item_" .. i, 0, true)
    local api = require("api")
    api.Interface:ApplyButtonSkin(itemBtn, BUTTON_BASIC.DEFAULT)
    
    itemBtn:SetExtent(self.width, 24)
    itemBtn:AddAnchor("TOPLEFT", self.menu, 10, (i-1) * 24 + 5)
    
    local displayText = type(item) == "string" and item or item.text or item.name or "Unknown"
    itemBtn:SetText(displayText)
    
    -- Item click handler
    function itemBtn:OnClick()
      local value = type(item) == "string" and item or item.value or displayText
      dropdown:_selectItem(value, displayText)
    end
    itemBtn:SetHandler("OnClick", itemBtn.OnClick)
    
    -- Hover effects
    function itemBtn:OnEnter()
      itemBtn:SetTextColor(1, 1, 0.8, 1)
    end
    itemBtn:SetHandler("OnEnter", itemBtn.OnEnter)
    
    function itemBtn:OnLeave()
      itemBtn:SetTextColor(1, 1, 1, 1)
    end
    itemBtn:SetHandler("OnLeave", itemBtn.OnLeave)
  end
end

-- Create hierarchical menu items (for tree structures)
function Dropdown:_createHierarchicalItems()
  -- This would implement the complex hierarchical dropdown logic
  -- For now, fall back to flat items
  self:_createFlatItems()
end

-- Handle item selection
function Dropdown:_selectItem(value, text)
  self.selectedValue = value
  self.selectedText = text
  
  self.button:SetText(text .. " ▾")
  
  if self.onSelectionChanged then
    self.onSelectionChanged(value, text)
  end
  
  self:close()

end

-- Update dropdown items
function Dropdown:setItems(items)
  self.items = items or {}
  
  -- If menu is open, recreate it
  if self.isOpen then
    self:close()
    self:open()
  end

end

-- Get selected value
function Dropdown:getSelectedValue()
  return self.selectedValue
end

-- Get selected text
function Dropdown:getSelectedText()
  return self.selectedText
end

-- Set selected value
function Dropdown:setSelectedValue(value, text)
  self.selectedValue = value
  self.selectedText = text or value or self.placeholder
  
  if self.button then
    self.button:SetText(self.selectedText .. " ▾")
  end
end

-- Set position
function Dropdown:setPosition(anchorPoint, relativeTo, offsetX, offsetY)
  if self.button then
    self.button:RemoveAllAnchors()
    self.button:AddAnchor(anchorPoint, relativeTo, offsetX or 0, offsetY or 0)
  end
end

-- Set size
function Dropdown:setSize(width, height)
  self.width = width or self.width
  self.height = height or self.height
  
  if self.button then
    self.button:SetExtent(self.width, self.height)
  end
end

-- Enable/disable dropdown
function Dropdown:setEnabled(enabled)
  if self.button then
    self.button:Enable(enabled)
  end
end

-- Show/hide dropdown
function Dropdown:setVisible(visible)
  if self.button then
    self.button:Show(visible)
  end
  if not visible and self.isOpen then
    self:close()
  end
end

-- Cleanup
function Dropdown:destroy()
  self:close()
  
  if self.button then
    self.button:Show(false)
  end
  if self.menu then
    self.menu:Show(false)
  end
  if self.overlay then
    self.overlay:Show(false)
  end
  
  Debug.info("Dropdown", "Dropdown destroyed", {id = self.id})
end

return Dropdown