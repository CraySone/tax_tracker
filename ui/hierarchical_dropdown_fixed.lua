-- tax_tracker/ui/hierarchical_dropdown_fixed.lua - Fixed hierarchical dropdown with direct button clicks
local api = require("api")
local Debug = require("tax_tracker/debug")

local HierarchicalDropdown = {}

-- Global dropdown management for auto-close behavior
local openDropdowns = {}

local function closeAllDropdowns()
  Debug.info("HierarchicalDropdown", "Closing all open dropdowns", {count = #openDropdowns})
  for i, dropdown in ipairs(openDropdowns) do
    if dropdown.menu and dropdown.menu.Show then
      dropdown.menu:Show(false)
    end
    if dropdown.overlay and dropdown.overlay.Show then
      dropdown.overlay:Show(false)
    end
    dropdown.isOpen = false
  end
  openDropdowns = {}
end

local function registerDropdown(dropdown)
  table.insert(openDropdowns, dropdown)
  Debug.debug("HierarchicalDropdown", "Registered dropdown", {totalOpen = #openDropdowns})
end

local function unregisterDropdown(dropdown)
  for i = #openDropdowns, 1, -1 do
    if openDropdowns[i] == dropdown then
      table.remove(openDropdowns, i)
      break
    end
  end
  Debug.debug("HierarchicalDropdown", "Unregistered dropdown", {totalOpen = #openDropdowns})
end

-- Create hierarchical dropdown with direct button click handling (no scroll list)
function HierarchicalDropdown.create(parent, id, width, hierarchicalData, defaultText, onChanged, maxHeight)
  Debug.info("HierarchicalDropdown", "Creating fixed hierarchical dropdown", {id = id, dataCount = #hierarchicalData})
  
  -- Create main button
  local btn = parent:CreateChildWidget("button", id, 0, true)
  api.Interface:ApplyButtonSkin(btn, BUTTON_BASIC.DEFAULT)
  btn:SetExtent(width, 28)
  local initial = defaultText or "Select option"
  btn:SetText(initial)
  if btn.style and btn.style.SetAlign then btn.style:SetAlign(ALIGN.LEFT) end
  
  -- Store original data and current visible data
  local originalData = hierarchicalData
  local visibleData = {}
  local isOpen = false
  
  -- Initialize data structure with proper hierarchy
  for i, item in ipairs(originalData) do
    if not item.tier then item.tier = 0 end
    if not item.expanded then item.expanded = false end
    if not item.collapsed then item.collapsed = false end
    if not item.id then item.id = i end
  end
  
  -- Create menu container
  local menu = api.Interface:CreateWindow(id..".menu", "", width + 20, 0)
  menu:AddAnchor("TOPLEFT", btn, -10, btn:GetHeight() + 2)
  menu:Show(false)
  
  -- Add background
  local bg = menu:CreateChildWidget("emptywidget", id .. "_bg", 0, true)
  bg:AddAnchor("TOPLEFT", menu, 0, 0)
  bg:AddAnchor("BOTTOMRIGHT", menu, 0, 0)
  if bg.SetColor then bg:SetColor(0.1, 0.1, 0.1, 0.9) end
  
  -- Create overlay for click-away detection
  local overlay = api.Interface:CreateEmptyWindow(id .. "_overlay")
  overlay:AddAnchor("TOPLEFT", "UIParent", 0, 0)
  overlay:AddAnchor("BOTTOMRIGHT", "UIParent", 0, 0)
  overlay:Show(false)
  
  function overlay:OnMouseUp()
    Debug.trace("HierarchicalDropdown", "Overlay clicked - closing dropdown")
    menu:Show(false)
    overlay:Show(false)
    isOpen = false
    unregisterDropdown({menu = menu, overlay = overlay, isOpen = isOpen})
  end
  overlay:SetHandler("OnMouseUp", overlay.OnMouseUp)
  
  -- Filter visible items based on hierarchy
  local function filterVisibleItems()
    Debug.info("HierarchicalDropdown", "Filtering visible items")
    visibleData = {}
    
    for k, item in ipairs(originalData) do
      local shouldShow = true
      
      if item.tier == 0 then
        -- Always show main items (tier 0)
        shouldShow = true
      else
        -- For child items, check if any ancestor in the lineage is collapsed
        shouldShow = true
        
        -- Build the ancestry chain by walking backwards through tiers
        for checkTier = item.tier - 1, 0, -1 do
          local ancestorAtTier = nil
          
          -- Find the most recent item at this tier level
          for parentIndex = k - 1, 1, -1 do
            local potentialAncestor = originalData[parentIndex]
            if potentialAncestor.tier == checkTier then
              ancestorAtTier = potentialAncestor
              break
            end
          end
          
          -- If we found an ancestor at this tier and it's not expanded, hide this item
          if ancestorAtTier and not ancestorAtTier.expanded then
            shouldShow = false
            break
          end
        end
      end

      if shouldShow then
        table.insert(visibleData, item)
      end
    end

    if Debug and Debug.info then
      Debug.info("HierarchicalDropdown", "Filtering complete", { count = #visibleData })
    end
  end
  
  -- Create menu items as direct buttons (like simpleDropdown but with hierarchy)
  local menuItems = {}
  
  local function createMenuItems()
    -- Clear existing items
    for i, itemBtn in ipairs(menuItems) do
      if itemBtn and itemBtn.Show then
        itemBtn:Show(false)
      end
    end
    menuItems = {}
    
    -- Calculate menu height
    local itemHeight = 24
    local calculatedHeight = math.min(#visibleData * itemHeight + 10, maxHeight or 300)
    menu:SetExtent(width + 20, calculatedHeight)
    
    local yOffset = 5
    
    for i, item in ipairs(visibleData) do
      local itemBtn = menu:CreateChildWidget("button", id .. "_item_" .. i, 0, true)
      api.Interface:ApplyButtonSkin(itemBtn, BUTTON_BASIC.DEFAULT)
      itemBtn:SetExtent(width, itemHeight - 2)
      itemBtn:AddAnchor("TOPLEFT", menu, 10, yOffset)
      
      -- Create display text with indentation and expansion indicators
      local displayName = item.name or "Unknown"
      local indent = string.rep("  ", item.tier or 0)
      local expansionIndicator = ""
      
      -- Check if item has children
      local hasChildren = false
      local itemIndex = nil
      for j, originalItem in ipairs(originalData) do
        if originalItem.id == item.id then
          itemIndex = j
          break
        end
      end
      
      if itemIndex then
        -- Look for children (higher tier items immediately following)
        for j = itemIndex + 1, #originalData do
          local potentialChild = originalData[j]
          if potentialChild.tier <= item.tier then
            break -- No more descendants
          end
          if potentialChild.tier == (item.tier + 1) then
            hasChildren = true
            break
          end
        end
      end
      
      if hasChildren then
        expansionIndicator = item.expanded and "[-] " or "[+] "
      end
      
      displayName = indent .. expansionIndicator .. displayName
      itemBtn:SetText(displayName)
      
      -- Color coding based on priority for zone headers, tier for children
      local color = {1, 1, 1, 1} -- Default white
      
      if item.priority then
        -- Zone headers with priority-based colors
        if item.priority == "red" then
          color = {1, 0.2, 0.2, 1}  -- Red for overdue
        elseif item.priority == "yellow" then
          color = {1, 1, 0.2, 1}    -- Yellow for urgent
        elseif item.priority == "green" then
          color = {0.2, 1, 0.2, 1}  -- Green for normal
        end
      else
        -- Child items with tier-based colors
        local tierColors = {
          [0] = {1, 1, 1, 1},        -- White for main items
          [1] = {1, 1, 0.5, 1},      -- Yellow for level 1
          [2] = {1, 0.7, 0.3, 1},    -- Orange for level 2
          [3] = {0.8, 0.8, 0.8, 1}   -- Gray for level 3+
        }
        color = tierColors[item.tier] or tierColors[3]
      end
      
      if itemBtn.style then
        itemBtn.style:SetAlign(ALIGN.LEFT)
        itemBtn:SetTextColor(color[1], color[2], color[3], color[4])
      end
      
      -- Click handler (CRITICAL FIX)
      function itemBtn:OnClick()
        local debugData = {
          name = item.name,
          tier = item.tier,
          hasChildren = hasChildren
        }
        Debug.info("HierarchicalDropdown", "Direct button click", debugData)

        if hasChildren then
          -- This is a category - toggle expansion with auto-collapse
          local targetExpanded = false
          
          -- First, find the target item and determine its new state
          for j, originalItem in ipairs(originalData) do
            if originalItem.id == item.id then
              targetExpanded = not originalItem.expanded
              break
            end
          end
          
          -- If we're expanding this category, collapse all other categories at the same tier
          if targetExpanded then
            for j, originalItem in ipairs(originalData) do
              if originalItem.tier == item.tier and originalItem.id ~= item.id then
                if originalItem.expanded then
                Debug.info("HierarchicalDropdown", "Auto-collapsing category", {
                  name = originalItem.name
                })
                originalItem.expanded = false
              end
              end
            end
          end
          
          -- Now toggle the target item
          for j, originalItem in ipairs(originalData) do
            if originalItem.id == item.id then
              originalItem.expanded = targetExpanded
              Debug.info("HierarchicalDropdown", "Toggled expansion", {
                name = originalItem.name,
                newState = originalItem.expanded
              })
              break
            end
          end
          
          -- Refresh the menu
          filterVisibleItems()
          createMenuItems()
        else
          -- This is a leaf item - select it and close
          btn:SetText(item.name or "Unknown")
          if onChanged then 
            onChanged(item.value or item.name, item.name, item.landData)
          end
          menu:Show(false)
          overlay:Show(false)
          isOpen = false
          unregisterDropdown({menu = menu, overlay = overlay, isOpen = isOpen})
        end
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
        -- Restore original color (same logic as above)
        local restoreColor = {1, 1, 1, 1}
        
        if item.priority then
          -- Zone headers with priority-based colors
          if item.priority == "red" then
            restoreColor = {1, 0.2, 0.2, 1}
          elseif item.priority == "yellow" then
            restoreColor = {1, 1, 0.2, 1}
          elseif item.priority == "green" then
            restoreColor = {0.2, 1, 0.2, 1}
          end
        else
          -- Child items with tier-based colors
          local tierColors = {
            [0] = {1, 1, 1, 1},
            [1] = {1, 1, 0.5, 1},
            [2] = {1, 0.7, 0.3, 1},
            [3] = {0.8, 0.8, 0.8, 1}
          }
          restoreColor = tierColors[item.tier] or tierColors[3]
        end
        
        if itemBtn.style then
          itemBtn:SetTextColor(restoreColor[1], restoreColor[2], restoreColor[3], restoreColor[4])
        end
      end
      itemBtn:SetHandler("OnLeave", itemBtn.OnLeave)
      
      menuItems[i] = itemBtn
      yOffset = yOffset + itemHeight
    end
    
    Debug.info("HierarchicalDropdown", "Menu items created", {itemCount = #menuItems})
  end
  
  -- Button click to show/hide menu
  function btn:OnClick()
    if isOpen then
      Debug.info("HierarchicalDropdown", "Closing dropdown")
      menu:Show(false)
      overlay:Show(false)
      isOpen = false
      unregisterDropdown({menu = menu, overlay = overlay, isOpen = isOpen})
    else
      Debug.info("HierarchicalDropdown", "Opening dropdown - closing all others first")
      -- Close all other open dropdowns first
      closeAllDropdowns()
      
      filterVisibleItems()
      createMenuItems()
      overlay:Show(true)
      menu:Show(true)
      menu:Raise()
      isOpen = true
      
      -- Register this dropdown as open
      registerDropdown({menu = menu, overlay = overlay, isOpen = isOpen})
    end
  end
  btn:SetHandler("OnClick", btn.OnClick)
  
  -- Utility functions
  function btn:GetPureText()
    local text = btn:GetText() or ""
    return text:gsub("%s*▾%s*$", "")
  end
  
  function btn:UpdateData(newData)
    originalData = newData
    -- Reset expansion states
    for i, item in ipairs(originalData) do
      if not item.tier then item.tier = 0 end
      if not item.expanded then item.expanded = false end
      if not item.collapsed then item.collapsed = false end
      if not item.id then item.id = i end
    end
    Debug.info("HierarchicalDropdown", "Data updated", {itemCount = #originalData})
  end
  
  parent[id] = btn
  return btn
end

return HierarchicalDropdown