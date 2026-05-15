local api = require("api")

local Export = {}

local EXPORT_FILE = "tax_tracker_data.lua"

local function escapeString(value)
  value = tostring(value or "")
  value = string.gsub(value, "\\", "\\\\")
  value = string.gsub(value, "\n", "\\n")
  value = string.gsub(value, "\r", "\\r")
  value = string.gsub(value, "\t", "\\t")
  value = string.gsub(value, "\"", "\\\"")
  return "\"" .. value .. "\""
end

local function isArrayKeySet(tbl)
  local maxIndex = 0
  local count = 0
  for key, _ in pairs(tbl) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
      return false, 0
    end
    if key > maxIndex then maxIndex = key end
    count = count + 1
  end
  return count == maxIndex, maxIndex
end

local function sortedKeys(tbl)
  local keys = {}
  for key, _ in pairs(tbl) do
    table.insert(keys, key)
  end
  table.sort(keys, function(a, b)
    local ta, tb = type(a), type(b)
    if ta == tb then return tostring(a) < tostring(b) end
    return ta < tb
  end)
  return keys
end

local function serializeValue(value, indent, seen)
  local valueType = type(value)
  if valueType == "string" then
    return escapeString(value)
  elseif valueType == "number" or valueType == "boolean" then
    return tostring(value)
  elseif valueType ~= "table" then
    return "nil"
  end

  if seen[value] then return "{}" end
  seen[value] = true

  local nextIndent = indent .. "  "
  local lines = {"{"}
  local isArray, maxIndex = isArrayKeySet(value)

  if isArray then
    for i = 1, maxIndex do
      table.insert(lines, nextIndent .. serializeValue(value[i], nextIndent, seen) .. ",")
    end
  else
    for _, key in ipairs(sortedKeys(value)) do
      local keyType = type(key)
      local serializedKey = nil
      if keyType == "string" then
        serializedKey = "[" .. escapeString(key) .. "]"
      elseif keyType == "number" or keyType == "boolean" then
        serializedKey = "[" .. tostring(key) .. "]"
      end
      if serializedKey then
        table.insert(lines, nextIndent .. serializedKey .. " = " .. serializeValue(value[key], nextIndent, seen) .. ",")
      end
    end
  end

  table.insert(lines, indent .. "}")
  seen[value] = nil
  return table.concat(lines, "\n")
end

local function countItems(value)
  if type(value) ~= "table" then return 0 end
  return #value
end

function Export.exportTaxTrackerSettings()
  if not api or not api.File or not api.File.Write then
    return false, "api.File.Write unavailable"
  end

  local settings = api.GetSettings("tax_tracker") or {}
  local payload = "return " .. serializeValue(settings, "", {}) .. "\n"

  local ok, err = pcall(function()
    api.File:Write(EXPORT_FILE, payload)
  end)
  if not ok then
    return false, tostring(err or "write failed")
  end

  return true, {
    file = EXPORT_FILE,
    lands = countItems(settings.lands),
    farms = countItems(settings.farmTrackerData or settings.farms),
    loans = countItems(settings.loansData)
  }
end

return Export
