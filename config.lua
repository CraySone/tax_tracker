-- tax_tracker/config.lua - Configuration constants and settings
-- Use Debug safely to avoid circular dependencies
local Debug = nil
pcall(function() Debug = require("tax_tracker/debug") end)
if not Debug then
  Debug = { info = function() end, warn = function() end, error = function() end, debug = function() end, trace = function() end }
end

local Config = {}

-- =========================
-- Base tax rates (updated with correct values)
Config.BASE_TAX = {
  -- Farms
  ["Scarecrow Garden (8x8)"]           = 5,   -- base 5/wk
  ["P2W Farm (8x8)"]                   = 5,   -- Solar/Lunar/Stellar farm
  ["Storage Silo (8x8)"]               = 15,   -- base 5/wk, same as garden
  ["Workbench (8x8)"]                  = 5,   -- base 5/wk, same as garden
  ["Scarecrow Farm (16x16)"]           = 10,  -- base 10/wk
  ["Improved Scarecrow Farm (16x16)"]  = 10,  -- same footprint as 16x16
  ["P2W Scarecrow (16x16)"]            = 10,  -- Solar/Lunar/Stellar scarecrow farm
  ["Gazebo Farm (24x24)"]              = 15,  -- 24x24 farm
  ["P2W Gazebo (24x24)"]               = 15,  -- Solar/Lunar/Stellar pavilion farm
  ["Aquafarm (16x16)"]                 = 10,  -- underwater farm
  ["Pearl Aquafarm (24x24)"]           = 15,  -- larger underwater farm

  -- Small houses (16x16)
  ["Cottage (16x16)"]                  = 10,
  ["Raised Cottage (16x16)"]           = 15,

  -- Medium houses (24x24)
  ["Townhouse (24x24)"]                = 15,
  ["Manor (24x24)"]                    = 15,  -- western "Manor" (24x24)
  ["Thatched Farmhouse (24x24)"]       = 15,
  ["Upgraded Farmhouse (24x24)"]       = 25,  -- upgraded thatched
  ["Mushroom House (24x24)"]           = 15,
  -- 24x24 crafting variants — same base tax (25/wk). Townhouse and Manor
  -- variants of each crafting type are merged into one entry since they
  -- share tax and only differ cosmetically.
  ["Apothecary's Manor / Townhouse (24x24)"] = 25,
  ["Armorer's Manor / Townhouse (24x24)"]    = 25,
  ["Tradesman's Manor / Townhouse (24x24)"]  = 25,

  -- Large houses (28x28)
  ["Fellowship Plaza (28x28)"]         = 25,
  ["Manor (28x28)"]                    = 25,  -- often referred to as Chalet
  ["Chalet (28x28)"]                   = 25,
  ["Treehouse (28x28)"]                = 25,
  ["Raised Mushroom House (28x28)"]    = 25,
  -- 28x28 crafting variants — one Villa variant per crafting type, base 30/wk
  ["Apothecary's Villa (28x28)"]       = 30,
  ["Armorer's Villa (28x28)"]          = 30,
  ["Tradesman's Villa (28x28)"]        = 30,

  -- Mansions (44x44)
  ["Beanstalk House (44x44)"]          = 50,
  ["Mansion (44x44)"]                  = 50,  -- alias, same base tax
  ["Spired Chateau (44x44)"]           = 50,  -- same as beanstalk/mansion
}

-- Zone fallback data
Config.FALLBACK_ZONES = {
  -- Seas & special regions
  "Arcadian Sea","Sunspeck Sea","Castaway Strait","Halcyona Gulf","Sea of Graves",
  "Stormraw Sound","Whaleswell Straits","Feuille Sound","Shattered Sea",
  "Mirage Isle","Freedich Island","Growlgate Isle",

  -- Auroria
  "Diamond Shores","Golden Ruins","Sungold Fields","Calmlands","Marcala","Heedmar",
  "Nuimari","Exeloch","Reedwind","Mistmerrow","Whalesong Harbor","Aegis Island",

  -- Haranya (East)
  "Arcum Iris","Falcorth Plains","Hasla","Mahadevi","Perinoor Ruins","Rookborne Basin",
  "Silent Forest","Solis Headlands","Sunbite Wilds","Tigerspine Mountains",
  "Villanelle","Windscour Savannah","Ynystere","Rokhala Mountains",

  -- Nuia (West)
  "Aubre Cradle","Airain Rock","Ahnimar","Cinderstone Moor","Dewstone Plains",
  "Gweonid Forest","Halcyona","Hellswamp","Karkasse Ridgelands","Lilyut Hills",
  "Marianople","Sanddeep","Solzreed Peninsula","Two Crowns","White Arden"
}

-- Land type inference patterns
Config.LAND_TYPE_PATTERNS = {
  -- Houses
  -- Crafting variants must come BEFORE the generic townhouse/manor patterns
  -- below — first match wins, so specific keywords need priority. Townhouse
  -- and Manor variants of each crafting type resolve to the same merged
  -- entry (same tax, cosmetic-only difference).
  {"apothecary's townhouse", "Apothecary's Manor / Townhouse (24x24)"},
  {"apothecary's manor",     "Apothecary's Manor / Townhouse (24x24)"},
  {"armorer's townhouse",    "Armorer's Manor / Townhouse (24x24)"},
  {"armorer's manor",        "Armorer's Manor / Townhouse (24x24)"},
  {"tradesman's townhouse",  "Tradesman's Manor / Townhouse (24x24)"},
  {"tradesman's manor",      "Tradesman's Manor / Townhouse (24x24)"},
  -- 28x28 crafting variants (Villa)
  {"apothecary's villa",     "Apothecary's Villa (28x28)"},
  {"armorer's villa",        "Armorer's Villa (28x28)"},
  {"tradesman's villa",      "Tradesman's Villa (28x28)"},
  {"cottage", "Cottage (16x16)"},
  {"townhouse", "Townhouse (24x24)"},
  {"manor", "Manor (28x28)"},
  {"chalet", "Chalet (28x28)"},
  {"treehouse", "Treehouse (28x28)"},
  {"farmhouse", "Thatched Farmhouse (24x24)"},
  {"mansion", "Mansion (44x44)"},
  {"beanstalk", "Beanstalk House (44x44)"},
  {"chateau", "Spired Chateau (44x44)"},
  {"spired", "Spired Chateau (44x44)"},
  {"mushroom", "Mushroom House (24x24)"},
  {"raised", "Raised Cottage (16x16)"},
  
  -- Farms
  {"pavilion farm", "P2W Gazebo (24x24)"},
  {"pavillion farm", "P2W Gazebo (24x24)"},
  {"solar scarecrow farm", "P2W Scarecrow (16x16)"},
  {"lunar scarecrow farm", "P2W Scarecrow (16x16)"},
  {"stellar scarecrow farm", "P2W Scarecrow (16x16)"},
  {"solar farm", "P2W Farm (8x8)"},
  {"lunar farm", "P2W Farm (8x8)"},
  {"stellar farm", "P2W Farm (8x8)"},
  {"garden", "Scarecrow Garden (8x8)"},
  {"scarecrow", "Scarecrow Farm (16x16)"},
  {"improved", "Improved Scarecrow Farm (16x16)"},
  {"gazebo", "Gazebo Farm (24x24)"},
  {"aquafarm", "Aquafarm (16x16)"},
  {"pearl", "Pearl Aquafarm (24x24)"},
  
  -- Storage
  {"silo", "Storage Silo (8x8)"},
  {"storage", "Storage Silo (8x8)"},
  {"workbench", "Workbench (8x8)"},
  
  -- Workbench types (also 8x8)
  {"smelter", "Workbench (8x8)"},
  {"sawmill", "Workbench (8x8)"},
  {"masonry", "Workbench (8x8)"},
  {"masonary", "Workbench (8x8)"},  -- Common typo
  {"loom", "Workbench (8x8)"},
  {"tanner", "Workbench (8x8)"},
  {"farmer", "Workbench (8x8)"},
}

-- System configuration
Config.SYSTEM = {
  ADDON_ID = "tax_tracker",
  VERSION = "1.67",
  
  -- Update intervals
  UPDATE_INTERVAL = 1000,  -- 1 second
  TIMESTAMP_CHECK_INTERVAL = 5000,  -- 5 seconds
  
  -- Logout warning settings
  LOGOUT_WARNING = {
    enabled = true,
    warningThresholdHours = 24,  -- Show warning if any payment due within 24 hours
    criticalThresholdHours = 6,  -- Critical warning if payment due within 6 hours
    showOverdue = true           -- Always show overdue properties
  },
  
  -- UI settings
  UI = {
    TINT_ALPHA = 0.60,
    TITLE_BAR_HEIGHT = 36
  }
}

-- Verification function
function Config.verifyBaseTax()
  local count = 0
  for _ in pairs(Config.BASE_TAX) do count = count + 1 end
  if Debug and Debug.info then
    Debug.info("Config", "BASE_TAX verification", {count = count, hasEntries = count > 0})
  end
  return count > 0
end

-- Get all available land types
function Config.getLandTypes()
  local landTypes = {}
  for landType, _ in pairs(Config.BASE_TAX) do
    table.insert(landTypes, landType)
  end
  table.sort(landTypes)
  return landTypes
end

-- Get base tax for a land type
function Config.getBaseTax(landType)
  return Config.BASE_TAX[landType] or 0
end

-- Initialize function (no-op for config)
function Config.initialize()
  return true
end

return Config
