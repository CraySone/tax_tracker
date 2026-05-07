-- tax_tracker/models/land.lua - Land data model
local Config = require("tax_tracker/config")
local LandInference = require("tax_tracker/utils/landinference")
local Debug = require("tax_tracker/debug")

-- Simple time substitute since os.time is not available
local timeCounter = 1000
local function getTime()
  timeCounter = timeCounter + 1
  return timeCounter
end

local Land = {}
Land.__index = Land

-- Constructor
function Land:new(data)
  local land = setmetatable({
    id = data.id or 0,
    name = data.name or "",
    type = data.type or "",
    zone = data.zone or "",
    tax = tonumber(data.tax) or 0,
    dueDate = data.dueDate or "",
    coordinates = data.coordinates or {},
    notes = data.notes or "",
    character = data.character or "",
    isPaid = data.isPaid or false,
    lastPaid = data.lastPaid or "",
    createdAt = data.createdAt or getTime(),
    updatedAt = data.updatedAt or getTime()
  }, Land)
  
  -- Validate and infer missing data
  land:validate()
  
  return land
end

-- Validate land data
function Land:validate()
  local errors = {}
  
  if not self.name or self.name:gsub("^%s*(.-)%s*$", "%1") == "" then
    table.insert(errors, "Land name is required")
  end
  
  if not self.type or self.type == "" then
    -- Try to infer from name
    local inferredType = LandInference.inferFromName(self.name)
    if inferredType then
      self.type = inferredType
      Debug.info("Land", "Type inferred from name", {
        landId = self.id,
        name = self.name,
        inferredType = inferredType
      })
    else
      table.insert(errors, "Land type is required or could not be inferred")
    end
  end
  
  if not self.zone or self.zone == "" then
    table.insert(errors, "Zone is required")
  end
  
  if #errors > 0 then
    Debug.warn("Land", "Validation failed", {
      landId = self.id,
      errors = errors
    })
    return false, errors
  end
  
  return true
end

-- Calculate tax based on land type
function Land:calculateTax()
  local baseTax = Config.BASE_TAX[self.type] or 0
  if baseTax == 0 then
    Debug.warn("Land", "No base tax defined for type", {
      landId = self.id,
      landType = self.type
    })
  end
  
  -- Future: Add zone multipliers, player bonuses, etc.
  self.tax = baseTax
  self.updatedAt = getTime()
  
  return self.tax
end

-- Check if land tax is overdue
function Land:isOverdue()
  if not self.dueDate or self.dueDate == "" then
    return false
  end
  
  -- Parse due date and compare with current time
  -- This would need proper date parsing based on your date format
  -- For now, return false as placeholder
  return false
end

-- Get days until due
function Land:getDaysUntilDue()
  if not self.dueDate or self.dueDate == "" then
    return nil
  end
  
  -- Placeholder - would need proper date calculation
  return 0
end

-- Get land category
function Land:getCategory()
  return LandInference.categorize(self.type)
end

-- Get land area
function Land:getArea()
  return LandInference.calculateArea(self.type)
end

-- Update land data
function Land:update(data)
  for key, value in pairs(data) do
    if self[key] ~= nil then
      self[key] = value
    end
  end
  self.updatedAt = getTime()
  
  -- Re-validate after update
  return self:validate()
end

-- Mark as paid
function Land:markPaid()
  self.isPaid = true
  self.lastPaid = "Paid_" .. getTime() -- Simple timestamp substitute
  self.updatedAt = getTime()

  Debug.info("Land", "Marked as paid", {
    landId = self.id,
    name = self.name,
    paidAt = self.lastPaid
  })
end

-- Mark as unpaid
function Land:markUnpaid()
  self.isPaid = false
  self.updatedAt = getTime()

  Debug.info("Land", "Marked as unpaid", {
    landId = self.id,
    name = self.name
  })
end

-- Convert to display format for UI
function Land:toDisplayFormat()
  return {
    id = self.id,
    name = self.name,
    type = self.type,
    zone = self.zone,
    tax = self.tax,
    dueDate = self.dueDate,
    category = self:getCategory(),
    area = self:getArea(),
    isPaid = self.isPaid,
    character = self.character,
    notes = self.notes
  }
end

-- Convert to save format for persistence
function Land:toSaveFormat()
  return {
    id = self.id,
    name = self.name,
    type = self.type,
    zone = self.zone,
    tax = self.tax,
    dueDate = self.dueDate,
    coordinates = self.coordinates,
    notes = self.notes,
    character = self.character,
    isPaid = self.isPaid,
    lastPaid = self.lastPaid,
    createdAt = self.createdAt,
    updatedAt = self.updatedAt
  }
end

return Land