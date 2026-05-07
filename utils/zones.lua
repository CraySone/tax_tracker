-- tax_tracker/utils/zones.lua - Zone management utilities
local Config = require("tax_tracker/config")
local Debug = require("tax_tracker/debug")

local Zones = {}

-- Get all zones from API with fallback
function Zones.getAllZones(api)
  local list, nameToId = {}, {}
  
  local function add(nm, id)
    if nm and nm ~= "" then
      list[#list+1] = nm
      nameToId[nm] = id or nameToId[nm] or 323
    end
  end

  -- Try different API methods to get zones
  if api and api.Zone then
    if api.Zone.GetZones then
      local ok, res = pcall(function() return api.Zone:GetZones() end)
      if ok and type(res) == "table" then 
        for _, z in ipairs(res) do 
          add(z.name, z.id) 
        end 
      end
    elseif api.Zone.GetAllZones then
      local ok, res = pcall(function() return api.Zone:GetAllZones() end)
      if ok and type(res) == "table" then 
        for _, z in ipairs(res) do 
          add(z.name, z.id) 
        end 
      end
    elseif api.Zone.GetZoneNames then
      local ok, res = pcall(function() return api.Zone:GetZoneNames() end)
      if ok and type(res) == "table" then 
        for _, nm in ipairs(res) do 
          add(nm, 323) 
        end 
      end
    end
  end

  -- Use fallback zones if API failed
  if #list == 0 then
    Debug.info("Zones", "Using fallback zone list - API unavailable")
    for _, nm in ipairs(Config.FALLBACK_ZONES) do 
      add(nm, 323) 
    end
  else
    Debug.info("Zones", "Loaded zones from API", {count = #list})
  end
  
  table.sort(list)
  return list, nameToId, list[1]
end

-- Get zone ID by name
function Zones.getZoneId(zoneName, nameToIdMap)
  return nameToIdMap and nameToIdMap[zoneName] or 323
end

-- Validate zone name
function Zones.isValidZone(zoneName, zoneList)
  if not zoneName or not zoneList then return false end
  for _, zone in ipairs(zoneList) do
    if zone == zoneName then return true end
  end
  return false
end

return Zones