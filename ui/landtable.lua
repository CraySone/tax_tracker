-- tax_tracker/ui/landtable.lua - Traditional ScrollListCtrl Land Table Component
local api = require("api")
local Debug = require("tax_tracker/debug")
local TimeSystem = require("tax_tracker/timesystem")

local LandTable = {}

-- Helper function for colorizing labels (from original)
local function colorizeLabel(label, r, g, b, a)
  if label and label.style and label.style.SetColor then
    label.style:SetColor(r, g, b, a)
  end
end

-- Helper function for formatting numbers (from original)
local function fmt2(n)
  return string.format("%.2f", n or 0)
end

-- Create traditional land table with ScrollListCtrl
function LandTable.create(parent, id, width, landsData, onLandAction, onCountdownLabelCreated, customHeight, options)
  options = options or {}
  Debug.info("LandTable", "=== LANDTABLE CREATE START ===")
  Debug.info("LandTable", "Creating traditional land table", {
    id = id, 
    landCount = #landsData,
    parentExists = parent ~= nil,
    width = width,
    sampleLandData = landsData[1] and {
      id = landsData[1].id,
      name = landsData[1].name,
      character = landsData[1].character,
      landType = landsData[1].landType,
      zoneName = landsData[1].zoneName
    } or "No land data"
  })
  
  -- Debug: Check each land in the data
  Debug.info("LandTable", "=== RECEIVED LAND DATA ===")
  for i = 1, math.min(5, #landsData) do
    local land = landsData[i]
    Debug.info("LandTable", "Land " .. i .. " details", {
      id = land.id,
      name = land.name,
      character = land.character,
      landType = land.landType,
      zoneName = land.zoneName,
      base = land.base,
      tax = land.tax,
      nextPayment = land.nextPayment and "has timer" or "no timer"
    })
  end
  Debug.info("LandTable", "=== END RECEIVED DATA ===")
  
  -- Column definitions. Dropped the redundant Zone column (the embedded table
  -- is already shown under its zone header, so listing the zone on every row
  -- duplicates information and pushes the Actions column past the table edge,
  -- clipping the Del button). Combined widths now total ~1290 vs the
  -- ~1440 available, leaving headroom.
  local columns = {
    { name="ID",        field="id",        width=40,
      setFunc=function(s,i,set) if set then s:SetText(tostring(i.id)) end end },
    { name="Character", field="character", width=110,
      setFunc=function(s,i,set) if set then s:SetText(i.character or "") end end },
    { name="Name",      field="name",      width=150,
      setFunc=function(s,i,set) if set then s:SetText(i.name or "") end end },
    { name="Type",   field="landType",  width=170,
      setFunc=function(s,i,set) if set then s:SetText(i.landType or "") end end },
    { name="Base",   field="base",      width=60,
      setFunc=function(s,i,set) if set then s:SetText(fmt2(i.base or 0)) end end },
    { name="Hostile",field="hostile",   width=60,
      setFunc=function(s,i,set) if set then s:SetText(i.hostile and "Yes" or "No") end end },
    { name="Terr.",  field="territory", width=50,
      setFunc=function(s,i,set) if set then s:SetText(i.territory and "Yes" or "No") end end },
    { name="Exempt", field="taxExempt", width=60,
      setFunc=function(s,i,set) 
        if set then 
          local text = i.taxExempt and "Yes" or "No"
          s:SetText(text)
          -- Color code: green for exempt, default for non-exempt
          if i.taxExempt then
            colorizeLabel(s, 0.4, 1, 0.4, 1)  -- Green for tax exempt
          else
            colorizeLabel(s, 1, 1, 1, 1)  -- White for normal
          end
        end 
      end },
    { name="Next Payment", field="nextPayment", width=280,
      setFunc=function(s,i,set)
        if not set then return end
        -- Keep timer data as-is (don't convert to number)
        local timerData = i.nextPayment
        
        -- CRITICAL: Recalculate countdown each time setFunc is called (timer addon approach)
        local displayText = TimeSystem.formatCountdown(timerData)
        s:SetText(displayText)
        
        -- PERFORMANCE FIX: Store countdown label reference for efficient updates
        if onCountdownLabelCreated and i.id and s then
          onCountdownLabelCreated(i.id, s)
        end
        
        -- Get color from TimeSystem (also recalculated each time)
        local color = TimeSystem.getTimeColor(timerData)
        
        -- Override with bright red for overdue entries to make them more visible
        if displayText and displayText:find("OVERDUE:") then
          colorizeLabel(s, 1.0, 0.2, 0.2, 1.0) -- Bright red for overdue
        else
          colorizeLabel(s, color[1], color[2], color[3], color[4])
        end
      end },
    { name="Tax",    field="tax",       width=80,
      setFunc=function(s,i,set) if set then s:SetText(fmt2(i.tax or 0)) end end },

    { name="Actions", width=276, disableSort=true,
      setFunc=function(sub,info,set)
        if sub.map    then sub.map:Show(set)    end
        if sub.paid   then sub.paid:Show(set)   end
        if sub.unpaid then sub.unpaid:Show(set) end
        if sub.edit   then sub.edit:Show(set)   end
        if sub.del    then sub.del:Show(set)    end
        if sub.reset  then sub.reset:Show(set)  end
      end,
      layoutFunc=function(list,row,col,cell)
        -- Map button
        local map = cell:CreateChildWidget("button", cell:GetId()..".map", 0, true)
        map:AddAnchor("LEFT", cell, 2, 0)
        api.Interface:ApplyButtonSkin(map, BUTTON_CONTENTS.MAP_OPEN)
        map:SetExtent(24, 24)
        function map:OnClick()
          local d = list.GetRowData and list:GetRowData(row) or landsData[row]
          if not d then return end
          local lon, lat = d.coords and d.coords.lon, d.coords and d.coords.lat
          if lon and lat and api.Map and api.Map.ToggleMapWithPortal then
            local COEFF = 0.00097657363894522145695357130138029
            local function toX(dir,deg,min,sec) local x=deg+(min+(sec/60))/60; if dir=="W" then x=-x end; return (x+21)/COEFF end
            local function toY(dir,deg,min,sec) local y=deg+(min+(sec/60))/60; if dir=="S" then y=-y end; return (y+28)/COEFF end
            local x = toX(lon.dir or "E", tonumber(lon.deg or 0) or 0, tonumber(lon.min or 0) or 0, tonumber(lon.sec or 0) or 0)
            local y = toY(lat.dir or "N", tonumber(lat.deg or 0) or 0, tonumber(lat.min or 0) or 0, tonumber(lat.sec or 0) or 0)
            -- World map id (323) — matches tier_2_sextant. The land's stored
            -- d.zoneId can be 44/99/etc. which opens the correct zone but
            -- the marker — placed in world coords — ends up off-screen.
            api.Map:ToggleMapWithPortal(323, x, y, 100)
          end
        end
        map:SetHandler("OnClick", map.OnClick)
        cell.map = map

        -- Paid button
        local paid = cell:CreateChildWidget("button", cell:GetId()..".paid", 0, true)
        api.Interface:ApplyButtonSkin(paid, BUTTON_BASIC.DEFAULT)
        paid:SetText("Paid"); paid:SetExtent(48, 28); paid:AddAnchor("LEFT", map, "RIGHT", 4, 0)
        function paid:OnClick()
          local d = list.GetRowData and list:GetRowData(row) or landsData[row]
          if not d then 
            Debug.warn("LandTable", "Paid button clicked but no data found", {row = row})
            return 
          end
          
          Debug.info("LandTable", "Marking payment as paid", {landName = d.name, landId = d.id})
          
          -- Use TimeSystem for payment logic
          d.nextPayment = TimeSystem.markPaid(d.nextPayment)
          d.isOverdue = TimeSystem.isOverdue(d.nextPayment)
          
          -- Notify parent if callback provided
          if onLandAction then
            onLandAction("paid", d, row)
          end
          
          -- Save the data change immediately
          local api = require("api")
          local settings = api.GetSettings("tax_tracker") or {}
          if not settings.lands then settings.lands = {} end
          
          -- Find and update the land in settings
          for i, land in ipairs(settings.lands) do
            if land.id == d.id then
              settings.lands[i] = d
              break
            end
          end
          
          -- Save settings
          pcall(function() api.SaveSettings() end)
          
          -- Refresh only the affected row, not the entire list
          pcall(function()
            if list.SetRowData then
              list:SetRowData(row, d)
            else
              list:UpdateData() -- Fallback to full refresh
            end
          end)
        end
        paid:SetHandler("OnClick", paid.OnClick)
        cell.paid = paid

        -- Unpaid button
        local unpaid = cell:CreateChildWidget("button", cell:GetId()..".unpaid", 0, true)
        api.Interface:ApplyButtonSkin(unpaid, BUTTON_BASIC.DEFAULT)
        unpaid:SetText("Unpaid"); unpaid:SetExtent(52, 28); unpaid:AddAnchor("LEFT", paid, "RIGHT", 4, 0)
        function unpaid:OnClick()
          local d = list.GetRowData and list:GetRowData(row) or landsData[row]
          if not d then
            Debug.warn("LandTable", "Unpaid button clicked but no data found", {row = row})
            return
          end
          
          Debug.info("LandTable", "Marking payment as unpaid", {landName = d.name, landId = d.id})
          
          -- Use TimeSystem for unpaid logic 
          d.nextPayment = TimeSystem.markUnpaid(d.nextPayment)
          d.isOverdue = TimeSystem.isOverdue(d.nextPayment)
          
          -- Notify parent if callback provided
          if onLandAction then
            onLandAction("unpaid", d, row)
          end
          
          -- Save the data change immediately
          local api = require("api")
          local settings = api.GetSettings("tax_tracker") or {}
          if not settings.lands then settings.lands = {} end
          
          -- Find and update the land in settings
          for i, land in ipairs(settings.lands) do
            if land.id == d.id then
              settings.lands[i] = d
              break
            end
          end
          
          -- Save settings
          pcall(function() api.SaveSettings() end)
          
          -- Refresh only the affected row, not the entire list
          pcall(function()
            if list.SetRowData then
              list:SetRowData(row, d)
            else
              list:UpdateData() -- Fallback to full refresh
            end
          end)
        end
        unpaid:SetHandler("OnClick", unpaid.OnClick)
        cell.unpaid = unpaid

        -- Edit button
        local edit = cell:CreateChildWidget("button", cell:GetId()..".edit", 0, true)
        api.Interface:ApplyButtonSkin(edit, BUTTON_BASIC.DEFAULT)
        edit:SetText("Edit"); edit:SetExtent(42, 28); edit:AddAnchor("LEFT", unpaid, "RIGHT", 4, 0)
        function edit:OnClick()
          local d = list.GetRowData and list:GetRowData(row) or landsData[row]
          if not d then
            Debug.warn("LandTable", "Edit button clicked but no data found", {row = row})
            return
          end
          
          Debug.info("LandTable", "Edit button clicked for land", {landName = d.name, landId = d.id})
          
          -- FIXED: Open UIManager editor for this specific land
          local UIManager = require("tax_tracker/ui/uimanager_v2")
          
          if not UIManager.isInitialized then
            UIManager.initialize(nil, nil)
          end
          
          -- Set edit mode for this specific land
          UIManager.setEditMode(d, row)
          UIManager.showWindow()
          
          -- Also notify parent if callback provided
          if onLandAction then
            onLandAction("edit", d, row)
          end
        end
        edit:SetHandler("OnClick", edit.OnClick)
        cell.edit = edit

        -- Delete button
        local del = cell:CreateChildWidget("button", cell:GetId()..".del", 0, true)
        api.Interface:ApplyButtonSkin(del, BUTTON_BASIC.DEFAULT)
        del:SetText("Del"); del:SetExtent(38, 28); del:AddAnchor("LEFT", edit, "RIGHT", 4, 0)
        function del:OnClick()
          local d = list.GetRowData and list:GetRowData(row) or landsData[row]
          if not d then
            Debug.warn("LandTable", "Delete button clicked but no data found", {row = row})
            return
          end
          
          Debug.info("LandTable", "Delete button clicked for land", {landName = d.name, landId = d.id})
          
          -- FIXED: Actually delete the land from settings
          local api = require("api")
          local settings = api.GetSettings("tax_tracker") or {}
          if settings.lands then
            for i, land in ipairs(settings.lands) do
              if land.id == d.id then
                table.remove(settings.lands, i)
                Debug.info("LandTable", "Land removed from settings", {landId = d.id, index = i})
                
                -- Recalculate all remaining lands' taxes after deletion
                pcall(function()
                  local UIManager = require("tax_tracker/ui/uimanager_v2")
                  if UIManager.recalculateAllLandTaxes then
                    UIManager.recalculateAllLandTaxes()
                  end
                end)
                
                break
              end
            end
            
            -- Save settings
            pcall(function() api.SaveSettings() end)
            
            -- Delete any loans associated with this land
            pcall(function()
              local LoansSystem = require("tax_tracker/loanssystem")
              if LoansSystem and LoansSystem.deleteLoansForLand then
                LoansSystem.deleteLoansForLand(d.id)
                Debug.info("LandTable", "Deleted loans for land", {landId = d.id})
              end
            end)
            
            -- Refresh the SavedLandsWindow
            pcall(function()
              local SavedLandsWindow = require("tax_tracker/ui/savedlandswindow")
              if SavedLandsWindow and SavedLandsWindow.refreshData then
                SavedLandsWindow.refreshData()
              end
            end)
          end
          
          -- Notify parent if callback provided
          if onLandAction then
            onLandAction("delete", d, row)
          end
        end
        del:SetHandler("OnClick", del.OnClick)
        cell.del = del

        -- Reset Timer button
        local reset = cell:CreateChildWidget("button", cell:GetId()..".reset", 0, true)
        api.Interface:ApplyButtonSkin(reset, BUTTON_BASIC.DEFAULT)
        reset:SetText("Reset"); reset:SetExtent(52, 28); reset:AddAnchor("LEFT", del, "RIGHT", 4, 0)
        function reset:OnClick()
          local d = list.GetRowData and list:GetRowData(row) or landsData[row]
          if not d then
            Debug.warn("LandTable", "Reset timer button clicked but no data found", {row = row})
            return
          end

          Debug.info("LandTable", "Resetting payment timer", {landName = d.name, landId = d.id})

          d.nextPayment = nil
          d.isOverdue = false

          local api = require("api")
          local settings = api.GetSettings("tax_tracker") or {}
          if not settings.lands then settings.lands = {} end

          for i, land in ipairs(settings.lands) do
            if land.id == d.id then
              settings.lands[i] = d
              break
            end
          end

          pcall(function() api.SaveSettings() end)

          pcall(function()
            if list.SetRowData then
              list:SetRowData(row, d)
            else
              list:UpdateData()
            end
          end)

          pcall(function()
            local SavedLandsWindow = require("tax_tracker/ui/savedlandswindow")
            if SavedLandsWindow and SavedLandsWindow.refreshData then
              SavedLandsWindow.refreshData()
            end
          end)

          if onLandAction then
            onLandAction("reset_timer", d, row)
          end
        end
        reset:SetHandler("OnClick", reset.OnClick)
        cell.reset = reset
      end }
  }

  -- Create ScrollListCtrl using gui helper
  Debug.info("LandTable", "About to require gui and call AddScrollList")
  local guiSuccess, gui = pcall(require, "tax_tracker/gui")
  if not guiSuccess then
    Debug.error("LandTable", "Failed to require gui module", {error = gui})
    return nil
  end
  
  Debug.info("LandTable", "Gui module loaded, calling AddScrollList")
  local compactWidth = width

  -- Row height tuned to keep dense zones readable and buttons easy to hit.
  local rowHeight = options.rowHeight or 32
  local headerHeight = 28
  local maxRows = options.maxRows or 15
  local actualRows = math.max(1, #landsData)
  local visibleRows = math.min(actualRows, maxRows)
  local compactHeight = customHeight or (headerHeight + (visibleRows * rowHeight) + 10)

  -- CRITICAL: rowCount must match the displayed data count. The engine sizes
  -- the row container to fit exactly rowCount rows in the available height; if
  -- these numbers disagree, dense zones visibly squash or overlap.
  local scrollList = gui.AddScrollList(
    parent,
    id,
    columns,
    {point = "TOPLEFT", relativeTo = parent, offsetX = 0, offsetY = 0},
    {width = compactWidth, height = compactHeight},
    {
      rowCount = actualRows,
      rowHeight = rowHeight,
      enableColumns = true,
      enablePagination = false,
      hidePageControl = true,
      onSortChanged = options.onSortChanged,
    }
  )
  
  Debug.info("LandTable", "AddScrollList returned", {
    scrollListExists = scrollList ~= nil,
    scrollListType = type(scrollList)
  })
  
  if not scrollList then
    Debug.error("LandTable", "Failed to create ScrollListCtrl", {id = id})
    return nil
  end

  -- Set the data
  Debug.info("LandTable", "Setting data on scrollList", {dataCount = #landsData})
  scrollList:UpdateData(landsData)
  Debug.info("LandTable", "Data set on scrollList")
  
  -- Store references for external access
  scrollList.landTable = {
    columns = columns,
    landsData = landsData,
    onLandAction = onLandAction
  }
  
  -- Update data function
  function scrollList:UpdateLandData(newLandsData)
    scrollList.landTable.landsData = newLandsData
    scrollList:UpdateData(newLandsData)
    Debug.info("LandTable", "Land data updated", {landCount = #newLandsData})
  end
  
  Debug.info("LandTable", "Traditional land table created successfully", {
    id = id,
    columns = #columns,
    lands = #landsData
  })
  Debug.info("LandTable", "=== LANDTABLE CREATE END ===")
  
  return scrollList
end

return LandTable
