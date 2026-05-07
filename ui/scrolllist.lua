-- tax_tracker/ui/scroll_list.lua - Reusable scroll list component
local gui = require("tax_tracker/gui")
local Debug = require("tax_tracker/debug")

local ScrollList = {}
ScrollList.__index = ScrollList

-- Constructor
function ScrollList:new(options)
  local scrollList = {
    id = options.id or "scrollList",
    parent = options.parent,
    columns = options.columns or {},
    width = options.width or 400,
    height = options.height or 300,
    rowHeight = options.rowHeight or 20,
    onItemClick = options.onItemClick,
    onItemDoubleClick = options.onItemDoubleClick,
    enableSorting = options.enableSorting or false,
    
    -- Internal state
    widget = nil,
    data = {},
    sortColumn = nil,
    sortAscending = true,
    selectedIndex = nil
  }
  
  setmetatable(scrollList, {__index = self})
  scrollList:_init()
  return scrollList
end

-- Initialize scroll list UI
function ScrollList:_init()
  if not self.parent then
    Debug.error("ScrollList", "Parent widget is required", {id = self.id})
    return
  end
  
  -- Create scroll list using existing gui helper
  self.widget = gui.AddScrollList(
    self.parent,
    self.id,
    self.columns,
    {point = "TOPLEFT", relativeTo = self.parent, offsetX = 0, offsetY = 0},
    {width = self.width, height = self.height},
    {
      rowHeight = self.rowHeight,
      enableColumns = self.enableSorting
    }
  )
  
  if not self.widget then
    Debug.error("ScrollList", "Failed to create scroll list widget", {id = self.id})
    return
  end
  
  -- Set up custom layout function
  self.widget.layoutFunc = function(list, rowIndex, colIndex, subItem)
    self:_layoutRow(list, rowIndex, colIndex, subItem)
  end
  
  Debug.info("ScrollList", "ScrollList initialized", {
    id = self.id,
    columns = #self.columns,
    size = {width = self.width, height = self.height}
  })
end

-- Layout individual row
function ScrollList:_layoutRow(list, rowIndex, colIndex, subItem)
  -- Clear existing content
  if subItem.children then
    for _, child in ipairs(subItem.children) do
      if child.Show then child:Show(false) end
    end
  end
  subItem.children = {}
  
  -- Create labels for each column
  local data = self.data[rowIndex]
  if not data then return end
  
  for i, column in ipairs(self.columns) do
    local label = subItem:CreateChildWidget("label", "col_" .. i, 0, true)
    label:AddAnchor("LEFT", subItem, (i-1) * (self.width / #self.columns), 0)
    label:SetExtent(self.width / #self.columns - 10, self.rowHeight)
    label.style:SetAlign(ALIGN.LEFT)
    label.style:SetEllipsis(true)
    
    -- Get column data
    local cellData = ""
    if type(data) == "table" then
      if column.field then
        cellData = tostring(data[column.field] or "")
      elseif column.index then
        cellData = tostring(data[column.index] or "")
      end
    else
      cellData = tostring(data)
    end
    
    label:SetText(cellData)
    table.insert(subItem.children, label)
  end
  
  -- Set up click handlers
  subItem:Enable(true)
  subItem:Show(true)
  
  function subItem:OnClick()
    scrollList:_handleItemClick(rowIndex, data)
  end
  subItem:SetHandler("OnClick", subItem.OnClick)
  
  function subItem:OnDoubleClick()
    scrollList:_handleItemDoubleClick(rowIndex, data)
  end
  subItem:SetHandler("OnDoubleClick", subItem.OnDoubleClick)
  
  -- Hover effects
  function subItem:OnEnter()
    for _, child in ipairs(subItem.children) do
      if child.SetTextColor then
        child:SetTextColor(1, 1, 0.8, 1)
      end
    end
  end
  subItem:SetHandler("OnEnter", subItem.OnEnter)
  
  function subItem:OnLeave()
    for _, child in ipairs(subItem.children) do
      if child.SetTextColor then
        child:SetTextColor(1, 1, 1, 1)
      end
    end
  end
  subItem:SetHandler("OnLeave", subItem.OnLeave)
end

-- Handle item click
function ScrollList:_handleItemClick(rowIndex, data)
  self.selectedIndex = rowIndex
  
  if self.onItemClick then
    self.onItemClick(data, rowIndex)
  end
  
  Debug.debug("ScrollList", "Item clicked", {
    id = self.id,
    rowIndex = rowIndex,
    data = data
  })
end

-- Handle item double click
function ScrollList:_handleItemDoubleClick(rowIndex, data)
  if self.onItemDoubleClick then
    self.onItemDoubleClick(data, rowIndex)
  end
  
  Debug.debug("ScrollList", "Item double clicked", {
    id = self.id,
    rowIndex = rowIndex,
    data = data
  })
end

-- Update data
function ScrollList:setData(data)
  self.data = data or {}
  
  if self.widget and self.widget.UpdateData then
    self.widget:UpdateData(self.data)
  end
  
  Debug.info("ScrollList", "Data updated", {
    id = self.id,
    itemCount = #self.data
  })
end

-- Add single item
function ScrollList:addItem(item)
  table.insert(self.data, item)
  self:setData(self.data)
end

-- Remove item by index
function ScrollList:removeItem(index)
  if index >= 1 and index <= #self.data then
    table.remove(self.data, index)
    self:setData(self.data)
    return true
  end
  return false
end

-- Clear all data
function ScrollList:clear()
  self.data = {}
  self.selectedIndex = nil
  self:setData(self.data)
end

-- Get selected item
function ScrollList:getSelectedItem()
  if self.selectedIndex and self.selectedIndex >= 1 and self.selectedIndex <= #self.data then
    return self.data[self.selectedIndex], self.selectedIndex
  end
  return nil, nil
end

-- Set selected index
function ScrollList:setSelectedIndex(index)
  if index >= 1 and index <= #self.data then
    self.selectedIndex = index
    -- Visual selection update would go here
  end
end

-- Sort by column
function ScrollList:sortByColumn(columnIndex, ascending)
  if not self.enableSorting or columnIndex < 1 or columnIndex > #self.columns then
    return
  end
  
  local column = self.columns[columnIndex]
  if not column then return end
  
  self.sortColumn = columnIndex
  self.sortAscending = ascending
  
  table.sort(self.data, function(a, b)
    local aValue = ""
    local bValue = ""
    
    if column.field then
      aValue = tostring(a[column.field] or "")
      bValue = tostring(b[column.field] or "")
    elseif column.index then
      aValue = tostring(a[column.index] or "")
      bValue = tostring(b[column.index] or "")
    end
    
    if ascending then
      return aValue < bValue
    else
      return aValue > bValue
    end
  end)
  
  self:setData(self.data)
  
  Debug.info("ScrollList", "Data sorted", {
    id = self.id,
    column = columnIndex,
    ascending = ascending
  })
end

-- Filter data
function ScrollList:filter(filterFunc)
  if not filterFunc then
    return
  end
  
  local filteredData = {}
  for _, item in ipairs(self.data) do
    if filterFunc(item) then
      table.insert(filteredData, item)
    end
  end
  
  self:setData(filteredData)
  
  Debug.info("ScrollList", "Data filtered", {
    id = self.id,
    originalCount = #self.data,
    filteredCount = #filteredData
  })
end

-- Set position
function ScrollList:setPosition(anchorPoint, relativeTo, offsetX, offsetY)
  if self.widget then
    self.widget:RemoveAllAnchors()
    self.widget:AddAnchor(anchorPoint, relativeTo, offsetX or 0, offsetY or 0)
  end
end

-- Set size
function ScrollList:setSize(width, height)
  self.width = width or self.width
  self.height = height or self.height
  
  if self.widget then
    self.widget:SetExtent(self.width, self.height)
  end
end

-- Enable/disable
function ScrollList:setEnabled(enabled)
  if self.widget then
    self.widget:Enable(enabled)
  end
end

-- Show/hide
function ScrollList:setVisible(visible)
  if self.widget then
    self.widget:Show(visible)
  end
end

-- Cleanup
function ScrollList:destroy()
  if self.widget then
    self.widget:Show(false)
  end
  
  Debug.info("ScrollList", "ScrollList destroyed", {id = self.id})
end

return ScrollList