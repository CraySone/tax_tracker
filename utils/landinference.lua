-- tax_tracker/utils/land_inference.lua - Land type inference utilities
local Config = require("tax_tracker/config")
local Debug = require("tax_tracker/debug")

local LandInference = {}

-- Infer land type from target name
function LandInference.inferFromName(targetName)
  if not targetName or targetName == "" then return nil end
  
  local name = targetName:lower()
  
  -- Check patterns from config
  for _, pattern in ipairs(Config.LAND_TYPE_PATTERNS) do
    if name:find(pattern[1]) then
      Debug.debug("LandInference", "Land type inferred from name pattern", {
        targetName = targetName,
        pattern = pattern[1],
        inferredType = pattern[2]
      })
      return pattern[2]
    end
  end
  
  Debug.debug("LandInference", "Could not infer land type from name", {targetName = targetName})
  return nil
end

-- Parse footprint from land type name
function LandInference.parseFootprint(name)
  if not name then return 0, 0 end
  
  -- Extract dimensions from parentheses like "(16x16)" or "(24x24)"
  local w, h = name:match("%((%d+)x(%d+)%)")
  if w and h then
    return tonumber(w) or 0, tonumber(h) or 0
  end
  
  return 0, 0
end

-- Calculate area from land type
function LandInference.calculateArea(landType)
  local w, h = LandInference.parseFootprint(landType)
  return w * h
end

-- Categorize land type (Farm, House, Storage, etc.)
function LandInference.categorize(landType)
  if not landType then return "Unknown" end
  
  local lower = landType:lower()
  
  if lower:find("garden") or lower:find("farm") or lower:find("aquafarm") or lower:find("gazebo") then
    return "Farm"
  elseif lower:find("cottage") or lower:find("townhouse") or lower:find("manor") or
         lower:find("chalet") or lower:find("treehouse") or lower:find("farmhouse") or
         lower:find("mansion") or lower:find("beanstalk") or lower:find("mushroom") or
         lower:find("villa") then
    return "House"
  elseif lower:find("silo") or lower:find("storage") or lower:find("workbench") then
    return "Storage"
  else
    return "Other"
  end
end

return LandInference