-- tax_tracker/services/data_manager.lua - Centralized data management
local Land = require("tax_tracker/models/land")
local Config = require("tax_tracker/config")
local Debug = require("tax_tracker/debug")

local DataManager = {
  lands = {},           -- Array for iteration
  landIndex = {},       -- Hash map for O(1) lookups
  zoneIndex = {},       -- Zone-based grouping
  typeIndex = {},       -- Type-based grouping
  characterIndex = {},  -- Character-based grouping
  nextId = 1,
  dirty = false,        -- Track if data needs saving
  eventHandlers = {}    -- Event system for data changes
}

-- Initialize data manager
function DataManager.initialize()
  DataManager.lands = {}
  DataManager.landIndex = {}
  DataManager.zoneIndex = {}
  DataManager.typeIndex = {}
  DataManager.characterIndex = {}
  DataManager.nextId = 1
  DataManager.dirty = false
  
end

-- Add event handler
function DataManager.on(event, handler)
  if not DataManager.eventHandlers[event] then
    DataManager.eventHandlers[event] = {}
  end
  table.insert(DataManager.eventHandlers[event], handler)
end

-- Emit event
function DataManager.emit(event, data)
  if DataManager.eventHandlers[event] then
    for _, handler in ipairs(DataManager.eventHandlers[event]) do
      pcall(handler, data)
    end
  end
end

-- Add land to the system
function DataManager.addLand(landData)
  local land = Land:new(landData)
  land.id = DataManager.nextId
  DataManager.nextId = DataManager.nextId + 1
  
  -- Add to main array
  table.insert(DataManager.lands, land)
  
  -- Update indices
  DataManager.landIndex[land.id] = land
  DataManager._addToZoneIndex(land)
  DataManager._addToTypeIndex(land)
  DataManager._addToCharacterIndex(land)
  
  DataManager.dirty = true

  Debug.info("DataManager", "Land added", {
    landId = land.id,
    name = land.name,
    type = land.type,
    zone = land.zone
  })

  DataManager.emit("landAdded", land)
  return land
end

-- Update existing land
function DataManager.updateLand(landId, updateData)
  local land = DataManager.landIndex[landId]
  if not land then
    return nil
  end
  
  -- Remove from old indices
  DataManager._removeFromIndices(land)
  
  -- Update the land
  local success, errors = land:update(updateData)
  if not success then
    return nil
  end
  
  -- Add back to indices with new data
  DataManager._addToZoneIndex(land)
  DataManager._addToTypeIndex(land)
  DataManager._addToCharacterIndex(land)
  
  DataManager.dirty = true
  
  DataManager.emit("landUpdated", land)
  return land
end

-- Remove land from system
function DataManager.removeLand(landId)
  local land = DataManager.landIndex[landId]
  if not land then
    return false
  end
  
  -- Remove from main array
  for i, l in ipairs(DataManager.lands) do
    if l.id == landId then
      table.remove(DataManager.lands, i)
      break
    end
  end
  
  -- Remove from indices
  DataManager.landIndex[landId] = nil
  DataManager._removeFromIndices(land)
  
  DataManager.dirty = true
  
  DataManager.emit("landRemoved", land)
  return true
end

-- Get land by ID
function DataManager.getLand(landId)
  return DataManager.landIndex[landId]
end

-- Get all lands
function DataManager.getAllLands()
  return DataManager.lands
end

-- Get lands by zone
function DataManager.getLandsByZone(zone)
  return DataManager.zoneIndex[zone] or {}
end

-- Get lands by type
function DataManager.getLandsByType(landType)
  return DataManager.typeIndex[landType] or {}
end

-- Get lands by character
function DataManager.getLandsByCharacter(character)
  return DataManager.characterIndex[character] or {}
end

-- Search lands by criteria
function DataManager.searchLands(criteria)
  local results = {}
  
  for _, land in ipairs(DataManager.lands) do
    local matches = true
    
    for field, value in pairs(criteria) do
      if land[field] ~= value then
        matches = false
        break
      end
    end
    
    if matches then
      table.insert(results, land)
    end
  end
  
  return results
end

-- Filter lands by function
function DataManager.filterLands(filterFunc)
  local results = {}
  
  for _, land in ipairs(DataManager.lands) do
    if filterFunc(land) then
      table.insert(results, land)
    end
  end
  
  return results
end

-- Load data from save format
function DataManager.loadData(saveData)
  DataManager.initialize()
  
  if not saveData or not saveData.lands then
    return
  end
  
  for _, landData in ipairs(saveData.lands) do
    local land = Land:new(landData)
    if land.id then
      -- Preserve existing IDs
      if land.id then
        DataManager.nextId = math.max(DataManager.nextId, land.id + 1)
      else
        land.id = DataManager.nextId
        DataManager.nextId = DataManager.nextId + 1
      end
      
      table.insert(DataManager.lands, land)
      DataManager.landIndex[land.id] = land
      DataManager._addToZoneIndex(land)
      DataManager._addToTypeIndex(land)
      DataManager._addToCharacterIndex(land)
    end
  end
  
  DataManager.emit("dataLoaded", DataManager.lands)
end

-- Save data to save format
function DataManager.getSaveData()
  local saveData = {
    lands = {},
    metadata = {
      version = Config.SYSTEM and Config.SYSTEM.VERSION or "1.67-ENHANCED",
      savedAt = DataManager.nextId, -- Use counter instead of os.time
      landCount = #DataManager.lands
    }
  }
  
  for _, land in ipairs(DataManager.lands) do
    table.insert(saveData.lands, land:toSaveFormat())
  end
  
  DataManager.dirty = false
  
  return saveData
end

-- Check if data needs saving
function DataManager.isDirty()
  return DataManager.dirty
end

-- Internal helper functions
function DataManager._addToZoneIndex(land)
  if not DataManager.zoneIndex[land.zone] then
    DataManager.zoneIndex[land.zone] = {}
  end
  table.insert(DataManager.zoneIndex[land.zone], land)
end

function DataManager._addToTypeIndex(land)
  if not DataManager.typeIndex[land.type] then
    DataManager.typeIndex[land.type] = {}
  end
  table.insert(DataManager.typeIndex[land.type], land)
end

function DataManager._addToCharacterIndex(land)
  if land.character and land.character ~= "" then
    if not DataManager.characterIndex[land.character] then
      DataManager.characterIndex[land.character] = {}
    end
    table.insert(DataManager.characterIndex[land.character], land)
  end
end

function DataManager._removeFromIndices(land)
  -- Remove from zone index
  if DataManager.zoneIndex[land.zone] then
    for i, l in ipairs(DataManager.zoneIndex[land.zone]) do
      if l.id == land.id then
        table.remove(DataManager.zoneIndex[land.zone], i)
        break
      end
    end
  end
  
  -- Remove from type index
  if DataManager.typeIndex[land.type] then
    for i, l in ipairs(DataManager.typeIndex[land.type]) do
      if l.id == land.id then
        table.remove(DataManager.typeIndex[land.type], i)
        break
      end
    end
  end
  
  -- Remove from character index
  if land.character and DataManager.characterIndex[land.character] then
    for i, l in ipairs(DataManager.characterIndex[land.character]) do
      if l.id == land.id then
        table.remove(DataManager.characterIndex[land.character], i)
        break
      end
    end
  end
end

-- Legacy compatibility methods
function DataManager.importLegacyData(legacyData)
  
  for _, landData in ipairs(legacyData) do
    -- Convert legacy format to new format
    local normalizedData = {
      name = landData.name or "",
      type = landData.landType or landData.type or "",
      zone = landData.zone or "",
      tax = tonumber(landData.tax) or 0,
      dueDate = landData.dueDate or "",
      notes = landData.notes or "",
      character = landData.character or "",
      createdAt = landData.createdAt or DataManager.nextId,
      updatedAt = landData.updatedAt or DataManager.nextId,
      id = landData.id -- Preserve if exists
    }
    
    DataManager.addLand(normalizedData)
  end
  
end

-- Delete land by index (legacy compatibility)
function DataManager.deleteLand(index)
  if type(index) == "number" and DataManager.lands[index] then
    local land = DataManager.lands[index]
    return DataManager.removeLand(land.id)
  end
  return false
end

-- Update land by index (legacy compatibility)
function DataManager.updateLandByIndex(index, updateData)
  if type(index) == "number" and DataManager.lands[index] then
    local land = DataManager.lands[index]
    return DataManager.updateLand(land.id, updateData)
  end
  return nil
end

-- Cleanup function
function DataManager.cleanup()
  
  DataManager.lands = {}
  DataManager.landIndex = {}
  DataManager.zoneIndex = {}
  DataManager.typeIndex = {}
  DataManager.characterIndex = {}
  DataManager.eventHandlers = {}
  DataManager.nextId = 1
  DataManager.dirty = false
  
end

return DataManager