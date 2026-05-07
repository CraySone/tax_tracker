-- tax_tracker/ui/hybrid_list.lua - Hybrid list with category expansion to show traditional tables
local api = require("api")
local Debug = require("tax_tracker/debug")
local LandTable = require("tax_tracker/ui/landtable")
local TimeSystem = require("tax_tracker/timesystem")

local HybridList = {}
local ZONE_PAGE_SIZE = 15
local LAND_ROW_HEIGHT = 32
local LAND_HEADER_HEIGHT = 28
local LAND_SCROLL_MARGIN = 10
local LAND_PAGER_HEIGHT = 34

-- Create hybrid list: categories that expand to show traditional ScrollListCtrl tables
function HybridList.create(parent, id, width, hierarchicalData, onLandSelected, maxHeight)
  Debug.info("HybridList", "Creating hybrid list with embedded tables", {id = id, dataCount = #hierarchicalData})
  
  -- Create main container that fills the window area
  local container = parent:CreateChildWidget("emptywidget", id, 0, true)
  container:SetExtent(width, 700) -- Initial height, will be resized dynamically
  -- Fill from below the header toolbar to bottom-right of window.
  container:AddAnchor("TOPLEFT", parent, 10, 82)
  container:AddAnchor("BOTTOMRIGHT", parent, -10, -10)
  
  -- Add background
  local bg = container:CreateChildWidget("emptywidget", id .. "_bg", 0, true)
  bg:AddAnchor("TOPLEFT", container, 0, 0)
  bg:AddAnchor("BOTTOMRIGHT", container, 0, 0)
  if bg.SetColor then bg:SetColor(0.05, 0.05, 0.05, 0.9) end
  
  -- Store original data and current visible data
  local originalData = hierarchicalData
  local zoneGroups = {} -- Store zone data separately for table creation
  local displaySeq = 0  -- Bumped each redraw so widget IDs never collide with hidden ghosts
  local zonePages = {}
  local zoneSorts = {}

  -- Extract zone groups from hierarchical data
  local function extractZoneGroups()
    zoneGroups = {}
    local currentZone = nil
    local currentLands = {}

    for _, item in ipairs(originalData) do
      if item.isZoneHeader then
        if currentZone then
          zoneGroups[currentZone.zoneName] = { zoneInfo = currentZone, lands = currentLands }
        end
        currentZone = item
        currentLands = {}
      elseif item.landData and currentZone then
        table.insert(currentLands, item.landData)
      end
    end

    if currentZone then
      zoneGroups[currentZone.zoneName] = { zoneInfo = currentZone, lands = currentLands }
    end
  end

  -- Initialize data structure
  for i, item in ipairs(originalData) do
    if not item.tier then item.tier = 0 end
    if item.expanded == nil then item.expanded = false end
    if not item.id then item.id = i end
  end

  extractZoneGroups()

  local function cloneLands(lands)
    local copy = {}
    for i, land in ipairs(lands or {}) do
      copy[i] = land
    end
    return copy
  end

  local function sortValue(land, field)
    if not land or not field then return nil end
    if field == "nextPayment" then
      if not land.nextPayment then return nil end
      local ok, remaining = pcall(function() return TimeSystem.getRemainingSeconds(land.nextPayment) end)
      return ok and remaining or nil
    end
    local value = land[field]
    if type(value) == "boolean" then
      return value and 1 or 0
    end
    if field == "base" or field == "tax" or field == "id" then
      return tonumber(value) or 0
    end
    return value
  end

  local function compareSortValues(a, b, ascending)
    if a == nil and b == nil then return false end
    if a == nil then return false end
    if b == nil then return true end
    if type(a) == "number" or type(b) == "number" then
      local na = tonumber(a) or 0
      local nb = tonumber(b) or 0
      if ascending then return na < nb end
      return na > nb
    end
    local sa = tostring(a):lower()
    local sb = tostring(b):lower()
    if ascending then return sa < sb end
    return sa > sb
  end

  local function sortedZoneLands(zoneName, lands)
    local result = cloneLands(lands)
    local sortState = zoneSorts[zoneName]
    if sortState and sortState.field then
      table.sort(result, function(a, b)
        local av = sortValue(a, sortState.field)
        local bv = sortValue(b, sortState.field)
        if av == bv then
          return tostring(a and a.name or ""):lower() < tostring(b and b.name or ""):lower()
        end
        return compareSortValues(av, bv, sortState.ascending)
      end)
    end
    return result
  end

  local function pagedZoneLands(zoneName, lands)
    local sorted = sortedZoneLands(zoneName, lands)
    local totalPages = math.max(1, math.ceil(#sorted / ZONE_PAGE_SIZE))
    local page = zonePages[zoneName] or 1
    if page > totalPages then page = totalPages end
    if page < 1 then page = 1 end
    zonePages[zoneName] = page

    local startIndex = ((page - 1) * ZONE_PAGE_SIZE) + 1
    local endIndex = math.min(startIndex + ZONE_PAGE_SIZE - 1, #sorted)
    local pageRows = {}
    for i = startIndex, endIndex do
      table.insert(pageRows, sorted[i])
    end
    return pageRows, page, totalPages, #sorted
  end
  
  -- Create scroll container for the list items
  local scrollContainer = container:CreateChildWidget("emptywidget", id .. "_scroll", 0, true)
  scrollContainer:AddAnchor("TOPLEFT", container, 5, 5)
  scrollContainer:AddAnchor("BOTTOMRIGHT", container, -5, -5)
  
  -- Store menu items and embedded tables
  local menuItems = {}
  local embeddedTables = {}
  
  -- PERFORMANCE FIX: Direct widget references for efficient updates
  local countdownLabels = {} -- landId -> countdown label widget
  local zoneHeaders = {} -- zoneName -> zone header button widget  
  local overdueStatusCache = {} -- landId -> current overdue status
  
  -- Store content height for dynamic window sizing
  local contentHeight = 0
  local routesStartY = 50 -- Store starting Y position for dynamic resizing
  
  -- Expose embeddedTables for external access (needed for timer updates)
  container.embeddedTables = embeddedTables
  container.getContentHeight = function() return contentHeight end
  container.getRoutesStartY = function() return routesStartY end
  
  -- Dynamic window resize helper
  local function resizeWindowToContent()
    local WIN_MIN_H = 400
    local WIN_MAX_H = 900
    local WIN_PADDING = 30
    
    local newWindowHeight = math.max(WIN_MIN_H, math.min(contentHeight + routesStartY + WIN_PADDING, WIN_MAX_H))
    
    if parent and parent.SetExtent then
      local currentWidth = parent:GetWidth() or 1500
      parent:SetExtent(currentWidth, newWindowHeight)
    end
  end
  
  -- Destroy widgets (don't just hide). Hidden widgets keep their anchors and the
  -- engine reuses cached widgets when CreateChildWidget is called with the same
  -- ID, which causes ghost rows that overlap the new layout.
  local function destroyWidget(w)
    if not w then return end
    pcall(function()
      if w.Show then w:Show(false) end
      if w.RemoveAllAnchors then w:RemoveAllAnchors() end
      if w.Destroy then w:Destroy() end
    end)
  end

  local function cleanupAllWidgets()
    for _, itemBtn in ipairs(menuItems) do
      destroyWidget(itemBtn)
    end
    for _, widget in pairs(embeddedTables) do
      destroyWidget(widget)
    end

    menuItems = {}
    embeddedTables = {}
    countdownLabels = {}
    zoneHeaders = {}
    overdueStatusCache = {}
    container.embeddedTables = embeddedTables
  end

  -- Forward declaration so the click handlers below can call it.
  local createMenuItems

  -- Mutate originalData expansion flags and rebuild the menu. Click handlers
  -- call this directly instead of going through UpdateData, because UpdateData
  -- preserves the user's expansion state across external refreshes — which
  -- would override the click and immediately re-collapse the zone.
  local function setExpandedZone(zoneName)
    for _, item in ipairs(originalData) do
      if item.isZoneHeader then
        item.expanded = (zoneName ~= nil and item.zoneName == zoneName)
      end
    end
    cleanupAllWidgets()
    createMenuItems()
  end
  
  -- Assigns to the forward-declared local above; do NOT use `local function`
  -- here or it will shadow the reference setExpandedZone captured.
  createMenuItems = function()
    cleanupAllWidgets()

    if #originalData == 0 then return end

    -- Bump sequence so widget IDs differ from the ones we just destroyed.
    displaySeq = displaySeq + 1
    local seq = displaySeq
    local function uid(stem) return id .. "_" .. stem .. "_s" .. seq end

    local itemHeight = 32
    local yOffset = 5
    contentHeight = 0

    -- Separate collapsed and expanded categories: collapsed go to top, expanded to bottom
    local collapsedCategories = {}
    local expandedCategory = nil

    for _, item in ipairs(originalData) do
      if item.isZoneHeader then
        if item.expanded then
          expandedCategory = item
        else
          table.insert(collapsedCategories, item)
        end
      end
    end

    -- STEP 1: Create all collapsed categories at the top
    for i, item in ipairs(collapsedCategories) do
      local itemBtn = scrollContainer:CreateChildWidget("button", uid("zone_collapsed_" .. i), 0, true)
      api.Interface:ApplyButtonSkin(itemBtn, BUTTON_BASIC.DEFAULT)
      itemBtn:SetExtent(width - 20, itemHeight)
      itemBtn:AddAnchor("TOPLEFT", scrollContainer, 5, yOffset)
      
      local displayName = "[+] " .. (item.name or "Unknown Zone")
      itemBtn:SetText(displayName)
      
      -- PERFORMANCE FIX: Store direct reference to zone header button
      zoneHeaders[item.zoneName] = itemBtn
      
      -- Color coding
      local color = {1, 1, 1, 1}
      if item.priority then
        if item.priority == "red" then
          color = {1, 0.3, 0.3, 1}
        elseif item.priority == "yellow" then
          color = {1, 1, 0.3, 1}
        elseif item.priority == "green" then
          color = {0.3, 1, 0.3, 1}
        end
      end
      
      if itemBtn.style then
        itemBtn.style:SetAlign(ALIGN.LEFT)
        itemBtn:SetTextColor(color[1], color[2], color[3], color[4])
      end
      
      -- Click handler: expand this category (moves it to bottom)
      function itemBtn:OnClick()
        setExpandedZone(item.zoneName)
      end
      itemBtn:SetHandler("OnClick", itemBtn.OnClick)
      
      -- Hover effects
      function itemBtn:OnEnter()
        if itemBtn.style then itemBtn:SetTextColor(1, 1, 0.9, 1) end
      end
      itemBtn:SetHandler("OnEnter", itemBtn.OnEnter)
      
      function itemBtn:OnLeave()
        if itemBtn.style then itemBtn:SetTextColor(color[1], color[2], color[3], color[4]) end
      end
      itemBtn:SetHandler("OnLeave", itemBtn.OnLeave)
      
      table.insert(menuItems, itemBtn)
      yOffset = yOffset + itemHeight + 5
    end
    
    -- STEP 2: Add visual separator if there's an expanded category
    if expandedCategory then
      local separator = scrollContainer:CreateChildWidget("label", uid("separator"), 0, true)
      separator:SetText("--------------------------------")
      separator:SetExtent(width - 20, 20)
      separator:AddAnchor("TOPLEFT", scrollContainer, 5, yOffset)
      if separator.style then
        separator.style:SetAlign(ALIGN.CENTER)
        separator.style:SetColor(0.5, 0.5, 0.5, 1)
      end
      separator:Show(true)
      table.insert(menuItems, separator)
      yOffset = yOffset + 25
    end

    -- STEP 3: Create expanded category at the bottom with its table
    if expandedCategory then
      local itemBtn = scrollContainer:CreateChildWidget("button", uid("zone_expanded"), 0, true)
      api.Interface:ApplyButtonSkin(itemBtn, BUTTON_BASIC.DEFAULT)
      itemBtn:SetExtent(width - 20, itemHeight)
      itemBtn:AddAnchor("TOPLEFT", scrollContainer, 5, yOffset)
      
      local displayName = "[-] " .. (expandedCategory.name or "Unknown Zone")
      itemBtn:SetText(displayName)
      
      -- PERFORMANCE FIX: Store direct reference to expanded zone header button
      zoneHeaders[expandedCategory.zoneName] = itemBtn
      
      -- Color coding for expanded category
      local color = {0.8, 0.9, 1, 1} -- Light blue to show it's expanded
      if expandedCategory.priority then
        if expandedCategory.priority == "red" then
          color = {1, 0.5, 0.5, 1}
        elseif expandedCategory.priority == "yellow" then
          color = {1, 1, 0.5, 1}
        elseif expandedCategory.priority == "green" then
          color = {0.5, 1, 0.5, 1}
        end
      end
      
      if itemBtn.style then
        itemBtn.style:SetAlign(ALIGN.LEFT)
        itemBtn:SetTextColor(color[1], color[2], color[3], color[4])
      end
      
      -- Click handler: collapse this category (moves it back to top)
      function itemBtn:OnClick()
        setExpandedZone(nil)
      end
      itemBtn:SetHandler("OnClick", itemBtn.OnClick)
      
      -- Hover effects
      function itemBtn:OnEnter()
        if itemBtn.style then itemBtn:SetTextColor(1, 1, 0.9, 1) end
      end
      itemBtn:SetHandler("OnEnter", itemBtn.OnEnter)
      
      function itemBtn:OnLeave()
        if itemBtn.style then itemBtn:SetTextColor(color[1], color[2], color[3], color[4]) end
      end
      itemBtn:SetHandler("OnLeave", itemBtn.OnLeave)
      
      table.insert(menuItems, itemBtn)
      yOffset = yOffset + itemHeight + 10
      
      -- STEP 4: Create the compact table directly under the expanded category
      if zoneGroups[expandedCategory.zoneName] then
        local zoneLands = zoneGroups[expandedCategory.zoneName].lands

        if #zoneLands > 0 then
          local compactWidth = width - 70 -- Account for anchors and scrollbar

          local pageRows, currentZonePage, totalZonePages, totalZoneRows = pagedZoneLands(expandedCategory.zoneName, zoneLands)
          local visibleRows = math.min(math.max(#pageRows, 1), ZONE_PAGE_SIZE)
          local tableHeight = LAND_HEADER_HEIGHT + (visibleRows * LAND_ROW_HEIGHT) + LAND_SCROLL_MARGIN
          local pagerHeight = totalZonePages > 1 and LAND_PAGER_HEIGHT or 0
          local tableContainerHeight = tableHeight + pagerHeight + 20

          -- Container provides visual containment + a single widget to destroy on cleanup
          local tableContainer = scrollContainer:CreateChildWidget("emptywidget", uid("table_container"), 0, true)
          tableContainer:SetExtent(compactWidth + 20, tableContainerHeight)
          tableContainer:AddAnchor("TOPLEFT", scrollContainer, 20, yOffset)

          local tableBg = tableContainer:CreateChildWidget("emptywidget", uid("table_bg"), 0, true)
          tableBg:AddAnchor("TOPLEFT", tableContainer, 0, 0)
          tableBg:AddAnchor("BOTTOMRIGHT", tableContainer, 0, 0)
          if tableBg.SetColor then tableBg:SetColor(0.1, 0.1, 0.1, 0.8) end

          local function onCountdownLabelCreated(landId, countdownLabel)
            if landId and countdownLabel then
              countdownLabels[landId] = countdownLabel
            end
          end

          local embeddedTable = LandTable.create(
            tableContainer,
            uid("table_expanded"),
            compactWidth,
            pageRows,
            nil,  -- onLandAction: actions handle themselves via settings + refresh
            onCountdownLabelCreated,
            tableHeight,
            {
              maxRows = ZONE_PAGE_SIZE,
              rowHeight = LAND_ROW_HEIGHT,
              onSortChanged = function(_, column, ascending)
                local field = column and column.field or nil
                local previous = zoneSorts[expandedCategory.zoneName]
                local nextAscending = true
                if previous and previous.field == field then
                  nextAscending = not previous.ascending
                else
                  nextAscending = ascending and true or false
                end
                zoneSorts[expandedCategory.zoneName] = {
                  field = field,
                  columnName = column and column.name or nil,
                  ascending = nextAscending,
                }
                zonePages[expandedCategory.zoneName] = 1
                cleanupAllWidgets()
                createMenuItems()
              end,
            }
          )

          if embeddedTable then
            -- Don't add another anchor here. LandTable -> gui.AddScrollList
            -- already anchored the scroll list to TOPLEFT of tableContainer at
            -- (0,0). Adding a second TOPLEFT anchor at (10,10) creates two
            -- conflicting anchors which makes the engine size/position the
            -- list unpredictably (was visible as overlapping rows).
            embeddedTable:Show(true)
            embeddedTables[expandedCategory.zoneName] = embeddedTable
            embeddedTables[expandedCategory.zoneName .. "_container"] = tableContainer
            container.embeddedTables = embeddedTables

            if totalZonePages > 1 then
              local prevBtn = tableContainer:CreateChildWidget("button", uid("page_prev"), 0, true)
              api.Interface:ApplyButtonSkin(prevBtn, BUTTON_BASIC.DEFAULT)
              prevBtn:SetExtent(70, 26)
              prevBtn:AddAnchor("TOPLEFT", tableContainer, 8, tableHeight + 6)
              prevBtn:SetText("Prev")
              if prevBtn.Enable then prevBtn:Enable(currentZonePage > 1) end
              function prevBtn:OnClick()
                zonePages[expandedCategory.zoneName] = math.max(1, (zonePages[expandedCategory.zoneName] or 1) - 1)
                cleanupAllWidgets()
                createMenuItems()
              end
              prevBtn:SetHandler("OnClick", prevBtn.OnClick)
              prevBtn:Show(true)
              table.insert(menuItems, prevBtn)

              local pageLbl = tableContainer:CreateChildWidget("label", uid("page_lbl"), 0, true)
              pageLbl:SetExtent(220, 24)
              pageLbl:SetText(string.format("Page %d / %d  (%d lands)", currentZonePage, totalZonePages, totalZoneRows))
              pageLbl:AddAnchor("TOP", tableContainer, 0, tableHeight + 8)
              if pageLbl.style then pageLbl.style:SetAlign(ALIGN.CENTER); pageLbl.style:SetFontSize(FONT_SIZE.SMALL or 14) end
              if ApplyTextColor and FONT_COLOR then ApplyTextColor(pageLbl, FONT_COLOR.DEFAULT) end
              pageLbl:Show(true)
              table.insert(menuItems, pageLbl)

              local nextBtn = tableContainer:CreateChildWidget("button", uid("page_next"), 0, true)
              api.Interface:ApplyButtonSkin(nextBtn, BUTTON_BASIC.DEFAULT)
              nextBtn:SetExtent(70, 26)
              nextBtn:AddAnchor("TOPRIGHT", tableContainer, -8, tableHeight + 6)
              nextBtn:SetText("Next")
              if nextBtn.Enable then nextBtn:Enable(currentZonePage < totalZonePages) end
              function nextBtn:OnClick()
                zonePages[expandedCategory.zoneName] = math.min(totalZonePages, (zonePages[expandedCategory.zoneName] or 1) + 1)
                cleanupAllWidgets()
                createMenuItems()
              end
              nextBtn:SetHandler("OnClick", nextBtn.OnClick)
              nextBtn:Show(true)
              table.insert(menuItems, nextBtn)
            end

            -- Advance past the container with a small gap before the next item.
            yOffset = yOffset + tableContainerHeight
          end
        end
      end
    end
    
    -- Update content height and resize window
    contentHeight = yOffset + 100
    container:SetExtent(width, math.max(yOffset + 100, maxHeight or 600))
    
    -- Resize parent window dynamically
    resizeWindowToContent()
  end
  
  -- Update list data while preserving the user's current expansion state.
  -- The caller (savedlandswindow) rebuilds the hierarchical data from scratch
  -- on every refresh tick with expanded=false on every zone, so we have to
  -- snapshot the existing originalData FIRST and re-apply the user's flags.
  function container:UpdateData(newData)
    -- Handle empty data case: clear widgets when last land is deleted
    if not newData or #newData == 0 then
      cleanupAllWidgets()
      originalData = {}
      zoneGroups = {}
      return
    end

    -- 1. Snapshot which zones the user has currently expanded.
    local preservedExpansion = {}
    for _, item in ipairs(originalData) do
      if item.isZoneHeader and item.zoneName then
        preservedExpansion[item.zoneName] = item.expanded or false
      end
    end

    -- 2. Apply the snapshot to newData and normalize fields.
    for i, item in ipairs(newData) do
      if not item.tier then item.tier = 0 end
      if not item.id then item.id = i end
      if item.isZoneHeader and item.zoneName and preservedExpansion[item.zoneName] ~= nil then
        item.expanded = preservedExpansion[item.zoneName]
      elseif item.expanded == nil then
        item.expanded = false
      end
    end

    -- 3. Decide whether the structure changed enough to warrant a full rebuild.
    local needsFullRecreation = (#originalData ~= #newData)
    if not needsFullRecreation then
      for i, item in ipairs(newData) do
        local oldItem = originalData[i]
        if not oldItem
            or oldItem.isZoneHeader ~= item.isZoneHeader
            or (item.isZoneHeader and oldItem.zoneName ~= item.zoneName)
            or (item.isZoneHeader and oldItem.expanded ~= item.expanded) then
          needsFullRecreation = true
          break
        end
      end
    end

    originalData = newData
    extractZoneGroups()

    if needsFullRecreation then
      cleanupAllWidgets()
      createMenuItems()
    else
      -- Only land data changed: refresh the embedded tables in place.
      local hasExpandedTables = false
      for _, t in pairs(embeddedTables) do
        if t and t.Show then hasExpandedTables = true break end
      end
      if hasExpandedTables then
        container:UpdateLandTablesOnly()
      end
    end
  end
  
  -- LIGHTWEIGHT: Update only countdown displays without rebuilding tables (PERFORMANCE FIX)
  function container:UpdateCountdownsOnly()
    Debug.trace("HybridList", "UpdateCountdownsOnly - lightweight countdown refresh")
    
    local TimeSystem = require("tax_tracker/timesystem")
    local countdownsUpdated = 0
    
    -- Update countdown displays in embedded tables only
    for zoneName, embeddedTable in pairs(embeddedTables) do
      if embeddedTable and embeddedTable.content and zoneGroups[zoneName] then
        local success = pcall(function()
          -- Get fresh land data for this zone
          local zoneLands = zoneGroups[zoneName].lands
          local landIndex = 1
          
          -- Iterate through table rows and update countdown displays
          for i = 1, embeddedTable.content:GetChildCount() do
            local child = embeddedTable.content:GetChildByIndex(i)
            if child and landIndex <= #zoneLands then
              local land = zoneLands[landIndex]
              
              -- Find countdown label in this row and update it
              for j = 1, child:GetChildCount() do
                local subChild = child:GetChildByIndex(j)
                if subChild and subChild:GetUIClass() == "widget.label" then
                  local text = subChild:GetText()
                  -- Check if this is a countdown label
                  if text and (string.find(text, "day") or string.find(text, "hour") or string.find(text, "min")) then
                    if land and land.nextPayment then
                      local newCountdown = TimeSystem.getTimeLeft(land.nextPayment)
                      subChild:SetText(newCountdown)
                      countdownsUpdated = countdownsUpdated + 1
                    end
                    break
                  end
                end
              end
              landIndex = landIndex + 1
            end
          end
        end)
        
        if not success then
          Debug.error("HybridList", "Failed to update countdowns for zone", {zoneName = zoneName})
        end
      end
    end
    
    Debug.trace("HybridList", "Lightweight countdown update completed", {countdownsUpdated = countdownsUpdated})
  end

  -- NEW PERFORMANCE METHODS: Granular updates using direct widget references
  
  -- Update a single countdown display by landId
  function container:UpdateCountdownById(landId, newCountdownText)
    local label = countdownLabels[landId]
    if label and label.SetText then
      label:SetText(newCountdownText)
      Debug.trace("HybridList", "Updated countdown for land", {landId = landId, newText = newCountdownText})
      return true
    end
    return false
  end
  
  -- Update zone header status (color, priority, text)
  function container:UpdateZoneHeaderById(zoneName, statusData)
    local header = zoneHeaders[zoneName]
    if not header then return false end
    
    -- Update text if provided
    if statusData.text then
      header:SetText(statusData.text)
    end
    
    -- Update color if provided
    if statusData.color and header.SetTextColor then
      local c = statusData.color
      header:SetTextColor(c[1], c[2], c[3], c[4] or 1)
    end
    
    Debug.trace("HybridList", "Updated zone header", {zoneName = zoneName, statusData = statusData})
    return true
  end
  
  -- Update overdue status for a single land (track changes)
  function container:UpdateOverdueStatusById(landId, isOverdue)
    local wasOverdue = overdueStatusCache[landId]
    overdueStatusCache[landId] = isOverdue
    
    -- Only return true if status actually changed
    if wasOverdue ~= isOverdue then
      Debug.trace("HybridList", "Overdue status changed", {landId = landId, wasOverdue = wasOverdue, isOverdue = isOverdue})
      return true
    end
    return false
  end
  
  -- Batch update all countdowns for expanded categories only
  function container:BatchUpdateCountdowns(landData)
    local updated = 0
    local TimeSystem = require("tax_tracker/timesystem")
    
    -- Only update lands that have countdown labels (are in expanded categories)
    for _, land in ipairs(landData) do
      if land.id and countdownLabels[land.id] and land.nextPayment then
        local newCountdown = TimeSystem.formatCountdown(land.nextPayment)
        if container:UpdateCountdownById(land.id, newCountdown) then
          updated = updated + 1
        end
      end
    end
    
    Debug.trace("HybridList", "Batch countdown update", {totalLands = #landData, updatedCountdowns = updated})
    return updated
  end

  -- HEAVY: Full embedded table rebuild (for when data structure changes)
  function container:UpdateLandTablesOnly()
    Debug.info("HybridList", "UpdateLandTablesOnly - FULL REBUILD of embedded tables", {
      embeddedTablesExists = embeddedTables ~= nil,
      zoneGroupsExists = zoneGroups ~= nil
    })

    local success, err = pcall(function()
      cleanupAllWidgets()
      createMenuItems()
    end)

    if not success then
      Debug.error("HybridList", "Failed to rebuild embedded land tables", {error = tostring(err)})
      return 0
    end

    Debug.info("HybridList", "Full embedded table rebuild completed")
    return 1
  end
  
  function container:CollapseAll()
    setExpandedZone(nil)
  end

  function container:ExpandZone(zoneName)
    setExpandedZone(zoneName)
  end
  
  -- Initialize
  createMenuItems()
  
  parent[id] = container
  return container
end

return HybridList
