local api = require("api")

--[[
==========================================================================
                           UI HELPER FUNCTIONS
==========================================================================
This module provides modular functions for creating common UI elements
with consistent styling and behavior.
==========================================================================
]]

--[[
==========================================================================
                           UTILITY FUNCTIONS
==========================================================================
Helper functions for consistent styling and hierarchy management
==========================================================================
]]

--[[
Returns appropriate color for level-based display.

@param level (number) The level (0, 1, 2, etc.)
@return (table) FONT_COLOR constant for the specified level

USAGE EXAMPLES:
    local color0 = GetTierColor(0)      -- Returns FONT_COLOR.WHITE
    local color1 = GetTierColor(1)      -- Returns FONT_COLOR.YELLOW
    local color2 = GetTierColor(2)      -- Returns FONT_COLOR.ORANGE
    ApplyTextColor(myLabel, GetTierColor(1))
]]
local function GetTierColor(level)
    local tierColors = {
        [0] = FONT_COLOR.WHITE,
        [1] = FONT_COLOR.YELLOW,
        [2] = FONT_COLOR.ORANGE,
        [3] = FONT_COLOR.GRAY
    }
    return tierColors[level] or FONT_COLOR.DEFAULT
end

--[[
Generates formatted display names with expansion indicators.

@param node (table) Node object containing: {name, buy, children}
@param isExpanded (boolean) Whether the node is currently expanded
@return (string) Formatted display name

USAGE EXAMPLES:
    local node1 = {name = "Item A", buy = true}
    local displayName = GetHierarchyDisplayName(node1, false)
    -- Returns: "--- Item A ---"
    
    local node2 = {name = "Item B", buy = false, children = {{}, {}}}
    local displayName = GetHierarchyDisplayName(node2, false)
    -- Returns: "[+] Item B"
]]
local function GetHierarchyDisplayName(node, isExpanded)
    local displayName = node.name
    
    if node.buy then
        displayName = "--- " .. displayName .. " ---"
    elseif node.children and #node.children > 0 then
        if isExpanded then
            displayName = "[-] " .. displayName
        else
            displayName = "[+] " .. displayName  
        end
    end
    
    return displayName
end

--[[
Returns appropriate color for status indication.

@param node (table) Node object containing status: {buy = boolean}
@return (table) FONT_COLOR constant

USAGE EXAMPLES:
    local item1 = {name = "Item A", buy = true}
    local color = GetStatusColor(item1)  -- Returns FONT_COLOR.GREEN
    
    local item2 = {name = "Item B", buy = false}
    local color = GetStatusColor(item2)  -- Returns FONT_COLOR.RED
]]
local function GetStatusColor(node)
    if node.buy then
        return FONT_COLOR.GREEN
    else
        return FONT_COLOR.RED
    end
end


--[[
Debug utility function to inspect and log all available methods and properties of a UI control.
Useful for discovering what functionality is available on unfamiliar widgets.

@param control (widget) The UI widget/control to inspect
@param controlName (string) Descriptive name for logging identification

USAGE EXAMPLES:
    -- Inspect a button to see available methods
    local myButton = parent:CreateChildWidget("button", "testBtn", 0, false)
    PrintControl(myButton, "TestButton")
    -- Logs all available methods like SetText, SetExtent, etc.
    
    -- Inspect a scroll list
    local scrollList = W_CTRL.CreatePageScrollListCtrl("list", parent)
    PrintControl(scrollList, "ScrollList")
    -- Logs methods like UpdateData, InsertColumn, etc.
    
    -- Check if a control is nil
    PrintControl(nil, "MissingControl")
    -- Logs: "Debug: MissingControl is nil"
]]
local function PrintControl(control, controlName)
    if not control then
        api.Log:Info("Debug: " .. controlName .. " is nil")
        return
    end
    api.Log:Info("Debug: Inspecting methods and properties for " .. controlName)
    local methods = {}
    local count = 0
    for key, value in pairs(getmetatable(control).__index or control) do
        if type(key) == "string" then
            methods[#methods + 1] = key .. " (" .. type(value) .. ")"
            count = count + 1
        end
    end
    table.sort(methods)
    api.Log:Info("Debug: Found " .. count .. " methods/properties for " .. controlName .. ":")
    for i, method in ipairs(methods) do
        api.Log:Info("Debug: [" .. i .. "] " .. method)
    end
end

local function CreateStyledWindow(id, titleText, width, height, options)
    local window = api.Interface:CreateEmptyWindow(id, "UIParent")
    local rawSetExtent = window.SetExtent
    local w = width or 620
    local h = height or 760
    local headerH = (options and options.headerHeight) or 36
    local titleSize = (options and options.titleFontSize) or 18
    window:AddAnchor("CENTER", "UIParent", 0, 0)

    local border = window:CreateColorDrawable(0, 0, 0, 0.96, "background")
    border:AddAnchor("TOPLEFT", window, 0, 0)
    border:AddAnchor("BOTTOMRIGHT", window, 0, 0)
    border:Show(true)

    local body = window:CreateColorDrawable(0.06, 0.06, 0.068, 0.96, "background")
    body:AddAnchor("TOPLEFT", window, 1, 1)
    body:AddAnchor("BOTTOMRIGHT", window, -1, -1)
    body:Show(true)

    local header = window:CreateColorDrawable(0.09, 0.09, 0.11, 0.98, "background")
    header:AddAnchor("TOPLEFT", window, 1, 1)
    header:Show(true)

    local title = window:CreateChildWidget("label", id .. "_title", 0, true)
    title:AddAnchor("TOP", window, 0, 6)
    title:SetText(titleText or "")
    if title.SetAutoResize then title:SetAutoResize(false) end
    if title.style then
        title.style:SetFontSize(titleSize)
        title.style:SetAlign(ALIGN.CENTER)
        title.style:SetColor(1, 0.84, 0, 1)
    end
    title:Show(true)

    local closeBtn = window:CreateChildWidget("button", id .. "_close", 0, true)
    closeBtn:SetExtent(24, 22)
    closeBtn:AddAnchor("TOPRIGHT", window, -10, 8)
    closeBtn:SetText("")
    local closeBorder = closeBtn:CreateColorDrawable(0, 0, 0, 0.92, "background")
    closeBorder:AddAnchor("TOPLEFT", closeBtn, 0, 0)
    closeBorder:AddAnchor("BOTTOMRIGHT", closeBtn, 0, 0)
    closeBorder:Show(true)
    local closeBg = closeBtn:CreateColorDrawable(0.14, 0.14, 0.16, 0.95, "background")
    closeBg:AddAnchor("TOPLEFT", closeBtn, 1, 1)
    closeBg:AddAnchor("BOTTOMRIGHT", closeBtn, -1, -1)
    closeBg:Show(true)
    local closeLabel = closeBtn:CreateChildWidget("label", id .. "_close_label", 0, true)
    closeLabel:SetExtent(24, 20)
    closeLabel:AddAnchor("TOPLEFT", closeBtn, 0, 1)
    closeLabel:SetText("X")
    if closeLabel.style then
        closeLabel.style:SetFontSize(11)
        closeLabel.style:SetAlign(ALIGN.CENTER)
        closeLabel.style:SetColor(1, 1, 1, 1)
    end
    if closeLabel.EnablePick then closeLabel:EnablePick(false) end
    closeLabel:Show(true)
    closeBtn:SetHandler("OnClick", function() window:Show(false) end)
    closeBtn:Show(true)
    if closeBtn.Raise then closeBtn:Raise() end

    local function refreshSize(nextW, nextH)
        w = nextW or w
        h = nextH or h
        rawSetExtent(window, w, h)
        header:SetExtent(math.max(1, w - 2), headerH)
        title:SetExtent(math.max(1, w - 90), math.max(1, headerH - 8))
    end

    function window:SetExtent(nextW, nextH)
        refreshSize(nextW, nextH)
    end

    local function startDrag()
        if window.StartMoving then window:StartMoving() end
        if api.Cursor and api.Cursor.ClearCursor then api.Cursor:ClearCursor() end
        if api.Cursor and api.Cursor.SetCursorImage and CURSOR_PATH and CURSOR_PATH.MOVE then
            api.Cursor:SetCursorImage(CURSOR_PATH.MOVE, 0, 0)
        end
    end

    local function stopDrag()
        if window.StopMovingOrSizing then window:StopMovingOrSizing() end
        if api.Cursor and api.Cursor.ClearCursor then api.Cursor:ClearCursor() end
    end

    if window.Clickable then window:Clickable(true) end
    if window.EnableDrag then window:EnableDrag(true) end
    window:SetHandler("OnDragStart", startDrag)
    window:SetHandler("OnDragStop", stopDrag)
    if title.EnableDrag then title:EnableDrag(true) end
    title:SetHandler("OnDragStart", startDrag)
    title:SetHandler("OnDragStop", stopDrag)
    if window.SetCloseOnEscape then window:SetCloseOnEscape(true) end
    window:SetHandler("OnCloseByEsc", function() window:Show(false) return true end)

    window.styledTitle = title
    window.styledCloseButton = closeBtn
    refreshSize(w, h)
    window:Show(false)
    return window
end

local function CreateCategoryPanel(parent, id, x, y, width, height, titleText)
    if not (parent and parent.CreateChildWidget) then return nil end
    local panel = parent:CreateChildWidget("emptywidget", id, 0, true)
    panel:SetExtent(width, height)
    panel:AddAnchor("TOPLEFT", parent, x, y)

    local border = panel:CreateColorDrawable(0, 0, 0, 0.92, "background")
    border:AddAnchor("TOPLEFT", panel, 0, 0)
    border:AddAnchor("BOTTOMRIGHT", panel, 0, 0)
    border:Show(true)

    local bg = panel:CreateColorDrawable(0.045, 0.045, 0.052, 0.82, "background")
    bg:AddAnchor("TOPLEFT", panel, 1, 1)
    bg:AddAnchor("BOTTOMRIGHT", panel, -1, -1)
    bg:Show(true)

    local header = panel:CreateColorDrawable(0.09, 0.09, 0.11, 0.95, "background")
    header:SetExtent(math.max(1, width - 2), 28)
    header:AddAnchor("TOPLEFT", panel, 1, 1)
    header:Show(true)

    local accent = panel:CreateColorDrawable(1, 0.84, 0, 0.85, "background")
    accent:SetExtent(4, 28)
    accent:AddAnchor("TOPLEFT", panel, 1, 1)
    accent:Show(true)

    local title = panel:CreateChildWidget("label", id .. "_title", 0, true)
    title:SetText(titleText or "")
    title:SetExtent(math.max(1, width - 24), 18)
    title:AddAnchor("TOPLEFT", panel, 14, 7)
    if title.style then
        title.style:SetFontSize(13)
        title.style:SetAlign(ALIGN.LEFT)
        title.style:SetColor(1, 0.84, 0, 1)
    end
    title:Show(true)

    panel.categoryTitle = title
    panel:Show(true)
    return panel
end


--[[
Generic function to add a button to a UI window with full customization options.

PARAMETERS:
@param parentwindow    (UI Window object) The parent window to which this button will belong.
                       The button will be created as a child of this window.

@param name           (string) Unique identifier for the button within the parent window.
                      This is used internally by the UI system and also stored as
                      parentwindow[name] for easy programmatic access later.

@param text           (string, optional) The text that will be displayed on the button.
                      If nil or not provided, defaults to empty string.

@param anchorPoint    (string, optional) The anchor point of the button that will be positioned.
                      Common values: "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT",
                      "CENTER", "LEFT", "RIGHT", "TOP", "BOTTOM". If nil, no anchoring is applied.

@param relativeTo     (UI Widget object, optional) The widget or window that this button will be
                      positioned relative to. Required if anchorPoint is provided.
                      Can be the parent window or any other UI element.

@param offsetX        (number, optional) Horizontal offset in pixels from the anchor point.
                      Positive values move right, negative values move left. Defaults to 0.

@param offsetY        (number, optional) Vertical offset in pixels from the anchor point.
                      Positive values move down, negative values move up. Defaults to 0.

@param skin           (table/constant, optional) Defines the visual appearance/style of the button.
                      Should be a BUTTON_BASIC constant (e.g., BUTTON_BASIC.DEFAULT,
                      BUTTON_BASIC.PLUS, BUTTON_BASIC.MINUS). If nil, uses BUTTON_BASIC.DEFAULT.

@param clickFunc      (function, optional) Callback function to execute when the button is clicked.
                      Function signature: function(buttonWidget, clickArguments)
                      - buttonWidget: reference to the button that was clicked
                      - clickArguments: additional data passed by the click event

@param width          (number, optional) Width of the button in pixels. Defaults to 120.

@param height         (number, optional) Height of the button in pixels. Defaults to 30.

RETURNS:
@return (UI Button Widget) The created button widget for additional customization if needed.

USAGE EXAMPLES:
    -- Basic save button
    local saveBtn = AddButton(mainWindow, "saveBtn", "Save", "BOTTOM", mainWindow, 0, -10,
                             BUTTON_BASIC.DEFAULT, function(btn) api.Log:Info("Button clicked") end, 100, 30)
    
    -- Close button with string skin shortcut
    local closeBtn = AddButton(mainWindow, "closeBtn", "X", "TOPRIGHT", mainWindow, -5, 5,
                              "close", function(btn) btn:GetParent():Show(false) end, 25, 25)
    
    -- Action button
    local actionBtn = AddButton(toolbar, "actionBtn", "Action", "LEFT", saveBtn, -110, 0,
                               BUTTON_BASIC.PLUS, function(btn, args)
                                   api.Log:Info("Action performed")
                               end, 120, 30)
]]
local function AddButton(parentwindow, name, text, anchorPoint, relativeTo, offsetX, offsetY, skin, clickFunc, width, height)
    -- Create the button widget as a child of the parent window
    local btn = parentwindow:CreateChildWidget("button", name, 0, false)
    
    -- Set the text displayed on the button
    btn:SetText(text or "") -- fallback to empty string if text is nil
    
    -- Set button size (default to reasonable dimensions if not provided)
    btn:SetExtent(width or 120, height or 30)
    
    -- Apply anchoring if anchorPoint and relativeTo are provided
    -- This determines where the button is positioned relative to another UI element
    if anchorPoint and relativeTo then
        btn:AddAnchor(anchorPoint, relativeTo, offsetX or 0, offsetY or 0)
    end
    
    -- Apply a visual skin to the button using proper API constants
    -- Enhanced to handle different button types more robustly
    local buttonSkin = skin
    if buttonSkin == nil then
        buttonSkin = BUTTON_BASIC.DEFAULT
    elseif type(buttonSkin) == "string" then
        -- Allow string shortcuts for common button types
        local skinMap = {
            ["default"] = BUTTON_BASIC.DEFAULT,
            ["plus"] = BUTTON_BASIC.PLUS,
            ["minus"] = BUTTON_BASIC.MINUS,
            ["close"] = BUTTON_BASIC.WINDOW_CLOSE,
            ["settings"] = BUTTON_BASIC.WINDOW_SETTING
        }
        buttonSkin = skinMap[buttonSkin:lower()] or BUTTON_BASIC.DEFAULT
    end
    ApplyButtonSkin(btn, buttonSkin)
    
    -- Add click handler if provided
    if clickFunc and type(clickFunc) == "function" then
        function btn:OnClick(arg)
            clickFunc(self, arg)
        end
        btn:SetHandler("OnMouseUp", btn.OnClick)
    end
    
    -- Make sure button is visible
    btn:Show(true)
    
    -- Store a reference to the button on the parent window
    -- This allows easy access later via parentwindow[name]
    parentwindow[name] = btn
    
    -- Return the button object in case the caller wants to modify it further
    return btn
end



--[[
Generic function to add a text label to a UI window with comprehensive styling options.

PARAMETERS:
@param parentwindow   (UI Window object) The parent window to which this label will belong.
                      The label will be created as a child of this window.

@param name          (string) Unique identifier for the label within the parent window.
                     Used internally and stored as parentwindow[name] for easy access.

@param text          (string) The text content to be displayed in the label.
                     Can be empty string but should not be nil.

@param anchorPoint   (string, optional) The anchor point of the label for positioning.
                     Values: "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT", "CENTER", etc.
                     If nil, no anchoring is applied.

@param relativeTo    (UI Widget object, optional) The widget this label will be positioned
                     relative to. Required if anchorPoint is provided.

@param offsetX       (number, optional) Horizontal offset in pixels from anchor point.
                     Positive = right, negative = left. Defaults to 0.

@param offsetY       (number, optional) Vertical offset in pixels from anchor point.
                     Positive = down, negative = up. Defaults to 0.

@param fontSize      (number, optional) Size of the font for the text.
                     Use FONT_SIZE constants (e.g., FONT_SIZE.LARGE, FONT_SIZE.SMALL).
                     Defaults to FONT_SIZE.DEFAULT.

@param align         (number, optional) Text alignment within the label.
                     1 = LEFT, 2 = CENTER, 3 = RIGHT. Defaults to 1 (LEFT).

@param color         (table/constant, optional) Font color for the text.
                     Should be a FONT_COLOR constant or RGBA table.
                     Defaults to FONT_COLOR.DEFAULT.

@param padding       (number, optional) Extra width in pixels added to the calculated text width.
                     Helps prevent text cutoff. Defaults to 14.

RETURNS:
@return (UI Label Widget) The created label widget for additional customization.

USAGE EXAMPLES:
    -- Main window title
    local titleLabel = AddLabel(mainWindow, "title", "My Application", "TOP", mainWindow,
                               0, 10, FONT_SIZE.LARGE, "center", FONT_COLOR.WHITE, 30)
    
    -- Status label
    local statusLabel = AddLabel(mainWindow, "status", "Ready", "TOPLEFT", titleLabel,
                                0, 30, FONT_SIZE.DEFAULT, "left", FONT_COLOR.YELLOW, 10)
    
    -- Dynamic content label
    local infoLabel = AddLabel(infoPanel, "info", "Information", "CENTER", infoPanel,
                              0, 0, FONT_SIZE.DEFAULT, "center", FONT_COLOR.DEFAULT, 20)
]]
local function AddLabel(parentwindow, name, text, anchorPoint, relativeTo, offsetX, offsetY, fontSize, align, color, padding)
    -- Create the label widget as a child of the parent window
    local lbl = parentwindow:CreateChildWidget("label", name, 0, true)
    
    -- Apply anchoring if specified
    if anchorPoint and relativeTo then
        lbl:AddAnchor(anchorPoint, relativeTo, offsetX or 0, offsetY or 0)
    end

    -- Set the text content of the label
    lbl:SetText(text or "")
    
    -- Set the label height based on font size
    lbl:SetHeight(fontSize or FONT_SIZE.DEFAULT)
    
    -- Set the label width based on text width plus optional padding
    local extraPadding = padding or 14
    local width = lbl.style:GetTextWidth(text or "") + extraPadding
    lbl:SetWidth(width)
    
    -- Set font size
    lbl.style:SetFontSize(fontSize or FONT_SIZE.DEFAULT)
    
    -- Set text alignment using proper ALIGN constants
    local alignment = align
    if type(align) == "number" then
        -- Convert legacy numeric alignment to proper constants
        local alignMap = {[1] = ALIGN.LEFT, [2] = ALIGN.CENTER, [3] = ALIGN.RIGHT}
        alignment = alignMap[align] or ALIGN.LEFT
    elseif type(align) == "string" then
        -- Allow string shortcuts for alignment
        local alignMap = {
            ["left"] = ALIGN.LEFT,
            ["center"] = ALIGN.CENTER, 
            ["right"] = ALIGN.RIGHT
        }
        alignment = alignMap[align:lower()] or ALIGN.LEFT
    else
        alignment = alignment or ALIGN.LEFT
    end
    lbl.style:SetAlign(alignment)
    
    -- Apply text color
    ApplyTextColor(lbl, color or FONT_COLOR.DEFAULT)
    
    -- Store label reference on parent window for easy access
    parentwindow[name] = lbl
    
    return lbl
end

--[[
Comprehensive function to create a styled checkbox with optional text label and full customization.

PARAMETERS:
@param parent        (UI Window object) The parent window that will contain this checkbox.

@param id            (string) Unique identifier for the checkbox. Used internally and for
                     parent[id] storage. Also used as base for sub-element IDs.

@param text          (string, optional) Text label to display next to the checkbox.
                     If nil, no label is created.

@param checked       (boolean, optional) Initial checked state of the checkbox.
                     true = checked, false = unchecked. Defaults to false.

@param anchorPoint   (string, optional) Anchor point for positioning the checkbox itself.
                     Common values: "TOPLEFT", "CENTER", etc.

@param relativeTo    (UI Widget object, optional) Widget to position the checkbox relative to.
                     Required if anchorPoint is provided.

@param offsetX       (number, optional) Horizontal positioning offset in pixels. Defaults to 0.

@param offsetY       (number, optional) Vertical positioning offset in pixels. Defaults to 0.

@param padding       (number, optional) Space in pixels between checkbox and label text.
                     Only used when text is provided. Defaults to 0.

@param style         (string, optional) Visual style of the checkbox. Options:
                     - "eyeShape": Special eye-shaped checkbox (27x18)
                     - "soft_brown": Brown-tinted checkbox (18x17)
                     - "quest_notifier": Quest-specific styling (18x17)
                     - "tutorial": Tutorial-specific styling (18x18)
                     - nil/other: Default style (18x17)

@param labelSide     (string, optional) Which side of checkbox to place the label.
                     "left" = label on left side, "right" = label on right side.
                     Defaults to "right". Note: eyeShape style forces left placement.

@param fontSize      (number, optional) Font size for the label text.
                     Uses FONT_SIZE constants. Defaults to FONT_SIZE.DEFAULT.

RETURNS:
@return (UI Checkbox Widget) The created checkbox widget with the following additional methods:
    - SetOnCheckChanged(callback): Set a function to call when checked state changes
    - GetLabelText(): Returns the text of the associated label
    - SetEnableCheckButton(enable): Enable/disable the checkbox and label

CALLBACK SIGNATURE:
The callback function passed to SetOnCheckChanged should have this signature:
function(isChecked, checkboxWidget)
    - isChecked: boolean indicating new checked state
    - checkboxWidget: reference to the checkbox that changed

USAGE EXAMPLES:
    -- Simple checkbox
    local enableOption = AddCheckbox(settingsPanel, "option1", "Enable Feature", false, 
                                    "TOP", settingsPanel, 0, 20)
    enableOption:SetOnCheckChanged(function(isChecked, widget)
        api.Log:Info("Feature " .. (isChecked and "enabled" or "disabled"))
    end)
    
    -- Checkbox with custom styling
    local option2 = AddCheckbox(settingsPanel, "option2", "Option 2", true, 
                               "TOPLEFT", enableOption, 0, 35, 10, "soft_brown", "right", FONT_SIZE.DEFAULT)
    option2:SetOnCheckChanged(function(checked, widget)
        api.Log:Info("Option 2 changed to: " .. tostring(checked))
    end)
]]
local function AddCheckbox(parent, id, text, checked, anchorPoint, relativeTo, offsetX, offsetY, padding, style, labelSide, fontSize)
    padding = padding or 0
    labelSide = labelSide or "right"
    fontSize = fontSize or FONT_SIZE.DEFAULT

    -- Helper functions (replicated from original)
    local function GetButtonDefaultFontColor()
        local color = {}
        color.normal = {ConvertColor(104), ConvertColor(68), ConvertColor(18), 1}
        color.highlight = {ConvertColor(154), ConvertColor(96), ConvertColor(16), 1}
        color.pushed = {ConvertColor(104), ConvertColor(68), ConvertColor(18), 1}
        color.disabled = {ConvertColor(92), ConvertColor(92), ConvertColor(92), 1}
        return color
    end

    local function GetDefaultCheckButtonFontColor()
        local color = {}
        color.normal = FONT_COLOR.DEFAULT
        color.highlight = FONT_COLOR.DEFAULT
        color.pushed = FONT_COLOR.DEFAULT
        color.disabled = {0.42, 0.42, 0.42, 1}
        return color
    end

    local function SetButtonFontColor(button, color)
        local n = color.normal
        local h = color.highlight
        local p = color.pushed
        local d = color.disabled
        button:SetTextColor(n[1], n[2], n[3], n[4])
        button:SetHighlightTextColor(h[1], h[2], h[3], h[4])
        button:SetPushedTextColor(p[1], p[2], p[3], p[4])
        button:SetDisabledTextColor(d[1], d[2], d[3], d[4])
    end

    -- 1) Create the main checkbox widget
    local checkbox = api.Interface:CreateWidget("checkbutton", id, parent)

    -- 2) Create background drawables (6 states like original)
    checkbox.bgs = {}
    local path = "ui/button/check_button.dds"
    for i = 1, 6 do
        checkbox.bgs[i] = checkbox:CreateImageDrawable(path, "background")
        checkbox.bgs[i]:SetExtent(16, 16)
        checkbox.bgs[i]:AddAnchor("CENTER", checkbox, 0, 0)
        if checkbox.bgs[i].SetTexture then
            checkbox.bgs[i]:SetTexture(path)
        end
    end

    -- 3) Create text button if text is provided (like original)
    if text ~= nil then
        local textButton = api.Interface:CreateWidget("button", id .. ".textButton", checkbox)
        
        -- Position label based on labelSide parameter
        if labelSide == "left" then
            textButton:AddAnchor("RIGHT", checkbox, "LEFT", -padding, 0)
        else -- default to "right"
            textButton:AddAnchor("LEFT", checkbox, "RIGHT", padding, 0)
        end
        
        -- Apply button styling
        textButton:RegisterForClicks("LeftButton")
        textButton:RegisterForClicks("RightButton", false)
        textButton.style:SetAlign(ALIGN.CENTER)
        textButton.style:SetSnap(true)
        SetButtonFontColor(textButton, GetButtonDefaultFontColor())
        
        textButton:SetAutoResize(true)
        textButton:SetHeight(fontSize)
        textButton:SetText(text)
        textButton.style:SetAlign(labelSide == "left" and ALIGN.RIGHT or ALIGN.LEFT)
        textButton.style:SetFontSize(fontSize)
        
        checkbox.textButton = textButton

        -- Handle text button clicks
        function textButton:OnClick()
            if checkbox:IsEnabled() then
                checkbox:SetChecked(not checkbox:GetChecked())
            end
        end
        textButton:SetHandler("OnClick", textButton.OnClick)
    end

    -- 4) Implement SetButtonStyle function (replicated from original)
    function checkbox:SetButtonStyle(styleType)
        local coords = {}
        if styleType == "eyeShape" then
            self:SetExtent(27, 18)
            if self.textButton ~= nil then
                self.textButton:RemoveAllAnchors()
                -- Always place text on left for eyeShape style, but respect padding
                local eyePadding = padding > 0 and -padding or -5  -- Use padding if specified, otherwise default -5
                self.textButton:AddAnchor("RIGHT", self, "LEFT", eyePadding, 0)
                self.textButton.style:SetAlign(ALIGN.RIGHT)
                SetButtonFontColor(self.textButton, GetDefaultCheckButtonFontColor())
            end
            coords[1] = {37, 0, 27, 18}
            coords[2] = {37, 0, 27, 18}
            coords[3] = {37, 0, 27, 18}
            coords[4] = {37, 36, 27, 18}
            coords[5] = {37, 18, 27, 18}
            coords[6] = {37, 36, 27, 18}
        elseif styleType == "soft_brown" then
            if self.textButton ~= nil then
                self.textButton:RemoveAllAnchors()
                -- Respect labelSide parameter for other styles
                if labelSide == "left" then
                    self.textButton:AddAnchor("RIGHT", self, "LEFT", -padding, 0)
                    self.textButton.style:SetAlign(ALIGN.RIGHT)
                else
                    self.textButton:AddAnchor("LEFT", self, "RIGHT", padding, 0)
                    self.textButton.style:SetAlign(ALIGN.LEFT)
                end
                SetButtonFontColor(self.textButton, GetDefaultCheckButtonFontColor())
            end
            self:SetExtent(18, 17)
            coords[1] = {0, 0, 18, 17}
            coords[2] = {0, 0, 18, 17}
            coords[3] = {0, 0, 18, 17}
            coords[4] = {0, 17, 18, 17}
            coords[5] = {18, 0, 18, 17}
            coords[6] = {18, 17, 18, 17}
        elseif styleType == "quest_notifier" then
            if self.textButton ~= nil then
                self.textButton:RemoveAllAnchors()
                if labelSide == "left" then
                    self.textButton:AddAnchor("RIGHT", self, "LEFT", -padding, 0)
                    self.textButton.style:SetAlign(ALIGN.RIGHT)
                else
                    self.textButton:AddAnchor("LEFT", self, "RIGHT", padding, 0)
                    self.textButton.style:SetAlign(ALIGN.LEFT)
                end
                SetButtonFontColor(self.textButton, GetDefaultCheckButtonFontColor())
            end
            self:SetExtent(18, 17)
            coords[1] = {57, 54, 7, 10}
            coords[2] = {0, 0, 18, 17}
            coords[3] = {0, 0, 18, 17}
            coords[4] = {0, 17, 18, 17}
            coords[5] = {18, 0, 18, 17}
            coords[6] = {18, 17, 18, 17}
        elseif styleType == "tutorial" then
            if self.textButton ~= nil then
                self.textButton:RemoveAllAnchors()
                if labelSide == "left" then
                    self.textButton:AddAnchor("RIGHT", self, "LEFT", -padding, 0)
                    self.textButton.style:SetAlign(ALIGN.RIGHT)
                else
                    self.textButton:AddAnchor("LEFT", self, "RIGHT", padding, 0)
                    self.textButton.style:SetAlign(ALIGN.LEFT)
                end
                SetButtonFontColor(self.textButton, GetDefaultCheckButtonFontColor())
            end
            self:SetExtent(18, 18)
            coords[1] = {0, 0, 18, 17}
            coords[2] = {0, 0, 18, 17}
            coords[3] = {0, 0, 18, 17}
            coords[4] = {0, 17, 18, 17}
            coords[5] = {18, 0, 18, 17}
            coords[6] = {18, 17, 18, 17}
        else
            -- Default style
            if self.textButton ~= nil then
                self.textButton:RemoveAllAnchors()
                if labelSide == "left" then
                    self.textButton:AddAnchor("RIGHT", self, "LEFT", -padding, 0)
                    self.textButton.style:SetAlign(ALIGN.RIGHT)
                else
                    self.textButton:AddAnchor("LEFT", self, "RIGHT", padding, 0)
                    self.textButton.style:SetAlign(ALIGN.LEFT)
                end
                SetButtonFontColor(self.textButton, GetDefaultCheckButtonFontColor())
            end
            self:SetExtent(18, 17)
            coords[1] = {0, 0, 18, 17}
            coords[2] = {0, 0, 18, 17}
            coords[3] = {0, 0, 18, 17}
            coords[4] = {0, 17, 18, 17}
            coords[5] = {18, 0, 18, 17}
            coords[6] = {18, 17, 18, 17}
        end
        
        -- Apply coordinates to backgrounds
        for i = 1, #coords do
            if coords[i] then
                self.bgs[i]:SetExtent(coords[i][3], coords[i][4])
                self.bgs[i]:SetCoords(coords[i][1], coords[i][2], coords[i][3], coords[i][4])
            end
        end
    end

    -- 5) Apply the specified style (or default)
    checkbox:SetButtonStyle(style)

    -- 6) Set background drawables
    checkbox:SetNormalBackground(checkbox.bgs[1])
    checkbox:SetHighlightBackground(checkbox.bgs[2])
    checkbox:SetPushedBackground(checkbox.bgs[3])
    checkbox:SetDisabledBackground(checkbox.bgs[4])
    if checkbox.bgs[5] then checkbox:SetCheckedBackground(checkbox.bgs[5]) end
    if checkbox.bgs[6] then checkbox:SetDisabledCheckedBackground(checkbox.bgs[6]) end

    -- 7) Add SetEnableCheckButton method (like original)
    function checkbox:SetEnableCheckButton(enable)
        self:Enable(enable, true)
        if self.textButton ~= nil then self.textButton:Enable(enable) end
    end

    -- 8) Handle OnCheckChanged events
    function checkbox:OnCheckChanged()
        if self.CheckBtnCheckChagnedProc ~= nil then
            local isChecked = self:GetChecked()
            -- Ensure we pass a boolean value, not a table
            if type(isChecked) == "table" then
                isChecked = isChecked[1] or false  -- Try to get first element, or default to false
            elseif type(isChecked) ~= "boolean" then
                isChecked = isChecked and true or false  -- Convert to boolean
            end
            -- Pass both the checked state and the checkbox itself
            self.CheckBtnCheckChagnedProc(isChecked, self)
        end
    end
    checkbox:SetHandler("OnCheckChanged", checkbox.OnCheckChanged)

    -- 8b) Add SetOnCheckChanged method for easier callback setup
    function checkbox:SetOnCheckChanged(callback)
        self.CheckBtnCheckChagnedProc = callback
    end

    -- 8c) Add convenience method to get label text
    function checkbox:GetLabelText()
        if self.textButton then
            return self.textButton:GetText()
        end
        return ""
    end

    -- 9) Apply positioning
    if anchorPoint and relativeTo then
        checkbox:AddAnchor(anchorPoint, relativeTo, offsetX or 0, offsetY or 0)
    end

    -- 10) Set initial checked state
    checkbox:SetChecked(checked or false)

    -- 11) Store references on parent window
    parent[id] = checkbox
    if text then
        parent[id .. "_textButton"] = checkbox.textButton
    end

    return checkbox
end

--[[
Comprehensive function to create a text input field (editbox) with optional label and full customization.

PARAMETERS:
@param parent         (UI Window object) The parent window that will contain this editbox.

@param name          (string) Unique identifier for the editbox. Used internally and stored
                     as parent[name] for easy access.

@param anchorPoint   (string, optional) Anchor point for positioning. If a label is provided,
                     this applies to the label and the editbox is positioned relative to the label.
                     If no label, this applies directly to the editbox.

@param relativeTo    (UI Widget object, optional) Widget to position relative to.
                     Required if anchorPoint is provided.

@param offsetX       (number, optional) Horizontal positioning offset in pixels. Defaults to 0.

@param offsetY       (number, optional) Vertical positioning offset in pixels. Defaults to 0.

@param width         (number, optional) Width of the editbox in pixels. Defaults to 120.

@param height        (number, optional) Height of the editbox in pixels. Defaults to 20.

@param maxLength     (number, optional) Maximum number of characters that can be typed.
                     If nil, no limit is applied.

@param defaultText   (string, optional) Initial text to display in the editbox.
                     Defaults to empty string.

@param labelText     (string, optional) Text for an optional label to display next to the editbox.
                     If provided, creates a label positioned according to anchorPoint/relativeTo,
                     and positions the editbox to the right of the label.

@param skin          (table/constant, optional) Visual styling for the editbox.
                     Uses BUTTON_BASIC constants for appearance.

@param labelOffsetY  (number, optional) Additional vertical offset for fine-tuning label/editbox
                     alignment. Positive moves editbox down relative to label. Defaults to 0.

@param fontSize      (number, optional) Font size for both label and editbox text.
                     Uses FONT_SIZE constants. Defaults to FONT_SIZE.DEFAULT.

@param onTextChange  (function, optional) Callback function called when text content changes.
                     Function signature: function(editboxWidget, newText)
                     - editboxWidget: reference to the editbox that changed
                     - newText: the new text content as a string

RETURNS:
@return (UI Editbox Widget) The created editbox widget with the following properties:
    - .label: Reference to associated label widget (if labelText was provided)
    - Standard editbox methods like GetText(), SetText(), etc.

USAGE EXAMPLES:
    -- Player name input with placeholder text
    local nameInput = AddEditBox(inputPanel, "playerName", "TOP", inputPanel, 0, 20, 
                                200, 30, 50, "Enter player name...", nil, nil, 0, FONT_SIZE.DEFAULT)
    
    -- Item ID input with label and validation
    local itemIdInput = AddEditBox(searchPanel, "itemId", "TOPLEFT", searchPanel, 10, 50, 
                                  120, 25, 10, "12345", "Item ID:", BUTTON_BASIC.DEFAULT, 0, FONT_SIZE.DEFAULT,
                                  function(widget, text)
                                      local itemId = tonumber(text)
                                      if itemId and itemId > 0 then
                                          api.Log:Info("Valid item ID entered: " .. itemId)
                                      else
                                          api.Log:Info("Invalid item ID: " .. text)
                                      end
                                  end)
    
    -- Price input with currency formatting
    local priceInput = AddEditBox(pricePanel, "price", "LEFT", itemIdInput.label, 20, 0,
                                 100, 25, 15, "0", "Max Price:", nil, 2, FONT_SIZE.DEFAULT,
                                 function(widget, text)
                                     local price = tonumber(text:gsub("[^%d%.]", "")) or 0
                                     api.Log:Info("Price filter set to: " .. price .. "g")
                                 end)
    
    -- Search box without label (positioned manually later)
    local searchBox = AddEditBox(filterPanel, "search", nil, nil, 0, 0, 
                                180, 20, 100, "Search items...", nil, nil, 0, FONT_SIZE.SMALL)
    -- Manual positioning: searchBox:AddAnchor("CENTER", filterPanel, 0, 0)
]]
local function AddEditBox(parent, name, anchorPoint, relativeTo, offsetX, offsetY, width, height, maxLength, defaultText, labelText, skin, labelOffsetY, fontSize, onTextChange)
    -- Set default values for optional parameters
    width = width or 120
    height = height or 20
    offsetX = offsetX or 0
    offsetY = offsetY or 0
    defaultText = defaultText or ""
    labelOffsetY = labelOffsetY or 0
    fontSize = fontSize or FONT_SIZE.DEFAULT

    -- Create optional label if labelText is provided
    local label
    if labelText then
        label = AddLabel(parent, name .. "_label", labelText, anchorPoint, relativeTo, offsetX, offsetY, fontSize)
    end

    -- Create the editbox widget
    local editbox = W_CTRL.CreateEdit(name, parent)
    editbox:SetExtent(width, height)
    
    -- Set initial text if provided
    if defaultText ~= "" then
        editbox:SetText(defaultText)
    end
    
    -- Apply character limit if specified
    if maxLength then
        editbox:SetMaxTextLength(maxLength)
    end
    
    -- Apply visual skin if provided
    if skin then
        api.Interface:ApplyButtonSkin(editbox, skin)
    end
    
    -- Set font size if the editbox supports it
    if editbox.style and editbox.style.SetFontSize then
        editbox.style:SetFontSize(fontSize)
    end
    
    -- Make editbox visible
    editbox:Show(true)

    -- Position the editbox
    if label then
        -- Position editbox relative to label
        editbox:AddAnchor("LEFT", label, label:GetWidth() + 5, 0)
        local labelHeight = label:GetHeight() or height
        local verticalOffset = math.floor((labelHeight - height) / 2) + labelOffsetY
        editbox:AddAnchor("TOP", label, 0, verticalOffset)
    else
        -- Position editbox directly using provided anchor info
        editbox:AddAnchor(anchorPoint, relativeTo, offsetX, offsetY)
    end

    -- Store reference to label for easy access
    editbox.label = label
    
    -- Store editbox reference on parent window
    parent[name] = editbox

    -- Set up text change callback if provided
    if onTextChange then
        editbox:SetHandler("OnTextChanged", function(self)
            local text = self:GetText()
            onTextChange(self, text)  -- call the user-provided function
        end)
    end

    return editbox
end

--[[
Comprehensive function to create a styled, sortable scroll list with columns and advanced features.
This creates a powerful data grid with sorting, custom column layouts, and data management capabilities.

PARAMETERS:
@param parent        (UI Window object) The parent window that will contain this scroll list.

@param id            (string) Unique identifier for the scroll list. Used internally and stored
                     as parent[id] for programmatic access.

@param columns       (table array) Array of column definition objects. Each column object can contain:
                     - name (string): Display name for the column header
                     - width (number): Width of the column in pixels
                     - setFunc (function): Function to populate cell data
                       Signature: function(subItem, rowData, setValue)
                       - subItem: the UI element for this cell
                       - rowData: the data object for this row
                       - setValue: boolean indicating if data should be set (true) or hidden (false)
                     - layoutFunc (function, optional): Function to create custom cell layouts (buttons, etc.)
                       Signature: function(listWidget, rowIndex, columnIndex, subItem)
                     - listType (number, optional): Column type override (defaults to options.listType)
                     - disableSort (boolean, optional): If true, this column won't be sortable

@param anchorInfo    (table) Positioning information for the scroll list:
                     - point (string): Anchor point ("TOPLEFT", "CENTER", etc.)
                     - relativeTo (UI Widget): Widget to position relative to
                     - offsetX (number, optional): Horizontal offset, defaults to 0
                     - offsetY (number, optional): Vertical offset, defaults to 0

@param dimensions    (table) Size information for the scroll list:
                     - width (number or function): Width in pixels, or function returning width
                     - height (number or function): Height in pixels, or function returning height

@param options       (table, optional) Additional configuration options:
                     - listType (number): Default column type for all columns (default: 3)
                     - rowCount (number): Number of rows to create (default: 20)
                     - columnHeight (number): Height of column headers in pixels (default: 35)
                     - enableColumns (boolean): Whether column headers are clickable (default: false)
                     - underlineColor (table): Custom RGBA color for header underline (default: brown)
                     - separatorColor (table): Custom RGBA color for column separators (default: brown-gold)
                     - bottomAnchor (table, optional): Additional bottom anchor for responsive sizing
                       Format: {point, relativeTo, offsetX, offsetY}

RETURNS:
@return (UI ScrollList Widget) Enhanced scroll list widget with the following additional methods:

DATA MANAGEMENT METHODS:
    - UpdateData(dataArray): Replace all data with new array and refresh display
    - ClearData(): Remove all data and reset sort states
    - SetRowData(rowIndex, dataObject): Update a specific row's data
    - GetRowData(rowIndex): Get data object for a specific row
    - AddRow(dataObject): Add a new row to the end of the data
    - DeleteRow(rowIndex): Remove a specific row and refresh display
    - SwapRows(row1Index, row2Index): Exchange positions of two rows

SORTING METHODS:
    - SortByColumn(columnIndex, ascending): Sort data by specified column
    - sortState: Array tracking sort direction for each column ("none", "asc", "desc")

PROPERTIES:
    - dataSource: Array containing all row data objects
    - parentWidget: Reference to parent window for creating child elements

COLUMN SORTING:
Columns are automatically sortable unless marked with disableSort = true.
Clicking column headers toggles between ascending/descending sort.
Supports intelligent number parsing for formatted numeric data (handles commas, currency symbols, etc.).

DATA FORMAT:
Data should be provided as an array of objects where each object represents a row.
Field names in the objects should match what your column setFunc functions expect.

USAGE EXAMPLES:
    -- Basic scroll list with sortable columns
    local columns = {
        {name = "ID", width = 60, setFunc = function(item, data, setValue) 
            if setValue then item:SetText(tostring(data.id)) end 
        end},
        {name = "Name", width = 120, setFunc = function(item, data, setValue) 
            if setValue then item:SetText(data.name) end 
        end},
        {name = "Score", width = 80, setFunc = function(item, data, setValue) 
            if setValue then item:SetText(tostring(data.score)) end 
        end}
    }
    
    local dataList = AddScrollList(mainWindow, "playerList", columns,
        {point = "TOPLEFT", relativeTo = titleLabel, offsetX = 0, offsetY = 50},
        {width = 400, height = 300},
        {rowCount = 15, enableColumns = true}
    )
    
    -- Populate with data
    local players = {
        {id = 1, name = "Alice", score = 1500},
        {id = 2, name = "Bob", score = 1200},
        {id = 3, name = "Charlie", score = 1800}
    }
    dataList:UpdateData(players)
    
    -- Real-world example: Player inventory management
    local inventoryColumns = {
        {name = "ID", width = 60, setFunc = function(item, data, setValue) 
            if setValue then 
                item:SetText(tostring(data.itemId)) 
                ApplyTextColor(item, FONT_COLOR.GRAY)
            end 
        end},
        {name = "Item Name", width = 180, setFunc = function(item, data, setValue) 
            if setValue then 
                item:SetText(data.name)
                local color = data.rarity == "rare" and FONT_COLOR.BLUE or FONT_COLOR.DEFAULT
                ApplyTextColor(item, color)
            end 
        end},
        {name = "Quantity", width = 80, setFunc = function(item, data, setValue) 
            if setValue then 
                item:SetText(tostring(data.quantity))
                local color = data.quantity < 10 and FONT_COLOR.RED or FONT_COLOR.DEFAULT
                ApplyTextColor(item, color)
            end 
        end},
        {name = "Value", width = 100, setFunc = function(item, data, setValue) 
            if setValue then 
                item:SetText(data.value .. "g")
                ApplyTextColor(item, FONT_COLOR.GREEN)
            end 
        end},
        {name = "Actions", width = 100, disableSort = true,
            setFunc = function(item, data, setValue)
                if item.sellBtn then item.sellBtn:Show(setValue) end
                if item.trashBtn then item.trashBtn:Show(setValue) end
            end,
            layoutFunc = function(list, rowIndex, colIndex, subItem)
                local sellBtn = mainWindow:CreateChildWidget("button", subItem:GetId() .. ".sell", 0, true)
                sellBtn:SetExtent(40, 18)
                sellBtn:AddAnchor("LEFT", subItem, 2, 0)
                sellBtn:SetText("Sell")
                ApplyButtonSkin(sellBtn, BUTTON_BASIC.DEFAULT)
                subItem.sellBtn = sellBtn
                
                local trashBtn = mainWindow:CreateChildWidget("button", subItem:GetId() .. ".trash", 0, true)
                trashBtn:SetExtent(40, 18)
                trashBtn:AddAnchor("LEFT", sellBtn, "RIGHT", 5, 0)
                trashBtn:SetText("Del")
                ApplyButtonSkin(trashBtn, BUTTON_BASIC.MINUS)
                subItem.trashBtn = trashBtn
                
                function sellBtn:OnClick()
                    local data = list.dataSource[rowIndex]
                    api.Log:Info("Selling " .. data.quantity .. "x " .. data.name .. " for " .. data.value .. "g each")
                end
                sellBtn:SetHandler("OnMouseUp", sellBtn.OnClick)
                
                function trashBtn:OnClick()
                    local data = list.dataSource[rowIndex]
                    api.Log:Info("Deleting " .. data.name .. " from inventory")
                    list:DeleteRow(rowIndex)
                end
                trashBtn:SetHandler("OnMouseUp", trashBtn.OnClick)
            end
        }
    }
    
    local inventoryList = AddScrollList(mainWindow, "inventory", inventoryColumns,
        {point = "TOPLEFT", relativeTo = titleLabel, offsetX = 20, offsetY = 50},
        {width = 520, height = 300},
        {rowCount = 12, enableColumns = true, enablePagination = true, pageSize = 50}
    )
    
    -- Sample inventory data
    local inventoryData = {
        {itemId = 8318, name = "Iron Ingot", quantity = 25, value = 15, rarity = "common"},
        {itemId = 8319, name = "Sturdy Ingot", quantity = 8, value = 45, rarity = "rare"},
        {itemId = 3411, name = "Copper Ore", quantity = 150, value = 2, rarity = "common"},
        {itemId = 17774, name = "Silver Ingot", quantity = 3, value = 120, rarity = "rare"},
        {itemId = 19450, name = "Opaque Polish", quantity = 12, value = 8, rarity = "common"}
    }
    inventoryList:UpdateData(inventoryData)
    
    -- Add more items dynamically
    inventoryList:AddRow({itemId = 99999, name = "Mystery Item", quantity = 1, value = 500, rarity = "legendary"})
]]
-- local function AddScrollList(parent, id, columns, anchorInfo, dimensions, options)
--     -- Set default values for optional parameters
--     options = options or {}
--     local listType = options.listType or 3
--     local rowCount = options.rowCount or 20
--     local columnHeight = options.columnHeight or 35
--     local rowHeight = options.rowHeight or 20
--     local enableColumns = options.enableColumns or false
    
--     -- Helper functions for consistent styling across all scroll lists
--     local function SetButtonFontColor(button, color)
--         local n = color.normal
--         local h = color.highlight
--         local p = color.pushed
--         local d = color.disabled
--         button:SetTextColor(n[1], n[2], n[3], n[4])
--         button:SetHighlightTextColor(h[1], h[2], h[3], h[4])
--         button:SetPushedTextColor(p[1], p[2], p[3], p[4])
--         button:SetDisabledTextColor(d[1], d[2], d[3], d[4])
--     end

--     local function GetButtonDefaultFontColor()
--         local color = {}
--         color.normal = {ConvertColor(104), ConvertColor(68), ConvertColor(18), 1}
--         color.highlight = {ConvertColor(154), ConvertColor(96), ConvertColor(16), 1}
--         color.pushed = {ConvertColor(104), ConvertColor(68), ConvertColor(18), 1}
--         color.disabled = {ConvertColor(92), ConvertColor(92), ConvertColor(92), 1}
--         return color
--     end

--     local function SettingListColumn(listCtrl, column)
--         listCtrl:SetColumnHeight(columnHeight)
--         listCtrl:SetHeight(rowHeight)
--         api.Interface:ApplyButtonSkin(column, BUTTON_BASIC.LISTCTRL_COLUMN)
--         column.style:SetShadow(false)
--         column.style:SetFontSize(FONT_SIZE.LARGE)
--         SetButtonFontColor(column, GetButtonDefaultFontColor())
--     end

--     -- Creates the underline decoration beneath column headers
--     local function DrawListCtrlUnderLine(listCtrl, offsetY, colorWhite, offsetX)
--         if colorWhite == nil then
--             colorWhite = false
--         end
--         local width = listCtrl:GetWidth()
--         if offsetX == nil then
--             offsetX = 0
--         end
        
--         -- Create two-part underline graphic
--         local underLine_1 = listCtrl:CreateImageDrawable(TEXTURE_PATH.TAB_LIST, "artwork")
--         underLine_1:SetCoords(0, 6, 256, 3)
--         underLine_1:SetExtent(width / 2, 3)
--         local underLine_2 = listCtrl:CreateImageDrawable(TEXTURE_PATH.TAB_LIST, "artwork")
--         underLine_2:SetCoords(256, 6, -256, 3)
--         underLine_2:SetExtent(width / 2, 3)
        
--         -- Apply custom color or default brown
--         if options.underlineColor then
--             underLine_1:SetColor(options.underlineColor[1], options.underlineColor[2], options.underlineColor[3], options.underlineColor[4] or 1)
--             underLine_2:SetColor(options.underlineColor[1], options.underlineColor[2], options.underlineColor[3], options.underlineColor[4] or 1)
--         elseif not colorWhite then
--             underLine_1:SetColor(ConvertColor(73), ConvertColor(45), ConvertColor(11), 1)
--             underLine_2:SetColor(ConvertColor(73), ConvertColor(45), ConvertColor(11), 1)
--         end
        
--         -- Position the underline
--         if offsetY == nil then
--             underLine_1:AddAnchor("TOPLEFT", listCtrl, offsetX, options.columnHeight - 2)
--             underLine_2:AddAnchor("TOPRIGHT", listCtrl, -offsetX, options.columnHeight - 2)
--         else
--             underLine_1:AddAnchor("TOPLEFT", listCtrl, offsetX, offsetY)
--             underLine_2:AddAnchor("TOPRIGHT", listCtrl, -offsetX, offsetY)
--         end
--     end

--     -- Creates visual separator lines between columns
--     local function DrawListCtrlColumnSperatorLine(widget, totalCount, count, colorWhite)
--         local inset = 3
--         if colorWhite == nil then
--             colorWhite = false
--         end
--         local divideLine
--         if count < totalCount then
--             divideLine = widget:CreateImageDrawable("ui/common/tab_list.dds", "overlay")
            
--             -- Different separator graphics based on column position
--             if count % 3 == 1 then
--                 divideLine:SetExtent(24, 55)
--                 divideLine:SetCoords(182, 9, 24, 55)
--                 divideLine:AddAnchor("BOTTOMLEFT", widget, "BOTTOMRIGHT", 0, 33)
--             elseif count % 3 == 2 then
--                 divideLine:SetExtent(25, 51)
--                 divideLine:SetCoords(206, 9, 25, 51)
--                 divideLine:AddAnchor("BOTTOMLEFT", widget, "BOTTOMRIGHT", 0, 22)
--             else
--                 divideLine:SetExtent(25, 15)
--                 divideLine:SetCoords(231, 9, 25, 15)
--                 divideLine:AddAnchor("BOTTOMLEFT", widget, "BOTTOMRIGHT", 0, 0)
--             end
            
--             -- Apply custom color or default brown-gold
--             if options.separatorColor then
--                 divideLine:SetColor(options.separatorColor[1], options.separatorColor[2], options.separatorColor[3], options.separatorColor[4] or 1)
--             elseif not colorWhite then
--                 divideLine:SetColor(ConvertColor(114), ConvertColor(94), ConvertColor(50), 1)
--             end
--         end
--         return divideLine
--     end

--     -- ADVANCED SORTING HELPER FUNCTIONS
--     -- These functions provide intelligent sorting for various data types including formatted numbers
    
--     --[[
--     Detects whether a value should be treated as a number or string for sorting purposes.
--     Handles formatted numbers with commas, currency symbols, parentheses, etc.
    
--     @param value: The value to analyze
--     @return string: "number" if value appears to be numeric, "string" otherwise
--     ]]
--     local function detectDataType(value)
--         if type(value) == "number" then
--             return "number"
--         elseif type(value) == "string" then
--             -- More comprehensive cleaning for formatted numbers
--             local cleanValue = tostring(value)
--             -- Remove common formatting: commas, spaces, currency symbols, parentheses
--             cleanValue = cleanValue:gsub("[,%s%$%(%)]", "")
--             -- Handle negative numbers with leading minus or trailing negative indicators
--             local isNegative = cleanValue:match("%-") or value:match("^%(.+%)$")
--             cleanValue = cleanValue:gsub("%-", "")
            
--             local numValue = tonumber(cleanValue)
--             if numValue then
--                 return "number"
--             else
--                 return "string"
--             end
--         else
--             return "string"  -- Default to string
--         end
--     end

--     --[[
--     Parses a potentially formatted number string into a numeric value.
--     Handles various formatting including currency symbols, commas, parentheses for negatives.
    
--     @param value: The value to parse (number or string)
--     @return number: Parsed numeric value, or 0 if unparseable
--     ]]
--     local function parseNumber(value)
--         if type(value) == "number" then
--             return value
--         end
        
--         local str = tostring(value)
        
--         -- Handle negative numbers in parentheses format: (123,456)
--         local isNegative = false
--         if str:match("^%(.+%)$") then
--             isNegative = true
--             str = str:gsub("[%(%)]", "")
--         elseif str:match("^%-") then
--             isNegative = true
--         end
        
--         -- Remove all non-digit characters except decimal point
--         str = str:gsub("[^%d%.]", "")
        
--         local num = tonumber(str) or 0
--         return isNegative and -num or num
--     end

--     --[[
--     Compares two values for sorting, handling both numeric and string comparisons intelligently.
    
--     @param a: First value to compare
--     @param b: Second value to compare
--     @param dataType: "number" or "string" - determines comparison method
--     @param ascending: boolean - true for ascending sort, false for descending
--     @return boolean: true if a should come before b in the sort order
--     ]]
--     local function compareValues(a, b, dataType, ascending)
--         if dataType == "number" then
--             -- Convert to numbers for comparison using improved parsing
--             local numA = parseNumber(a)
--             local numB = parseNumber(b)
            
--             -- Debug logging for troubleshooting sort issues
--             api.Log:Info("Comparing numbers: " .. tostring(a) .. " (" .. numA .. ") vs " .. tostring(b) .. " (" .. numB .. ")")
            
--             if ascending then
--                 return numA < numB
--             else
--                 return numA > numB
--             end
--         else
--             -- String comparison (case-insensitive)
--             local strA = tostring(a):lower()
--             local strB = tostring(b):lower()
--             if ascending then
--                 return strA < strB
--             else
--                 return strA > strB
--             end
--         end
--     end

--     -- CREATE THE MAIN SCROLL LIST WIDGET
--     local scrollList = W_CTRL.CreatePageScrollListCtrl(id, parent)
--     scrollList:Show(true)
    
--     -- store rowHeight from options so we can use it later
--     scrollList.rowHeight = rowHeight

--     -- Store reference to parent widget for creating child elements (like buttons in cells)
--     scrollList.parentWidget = parent
    
--     -- Initialize sorting state tracking for each column
--     scrollList.sortState = {}  -- Track sort direction for each column
    
--     -- SET DIMENSIONS (supports both static values and dynamic functions)
--     local width, height
--     if type(dimensions.width) == "function" then
--         width = dimensions.width()
--     else
--         width = dimensions.width
--     end
--     if type(dimensions.height) == "function" then
--         height = dimensions.height()
--     else
--         height = dimensions.height
--     end
--     scrollList:SetExtent(width, height)
    
--     -- APPLY POSITIONING
--     if anchorInfo then
--         scrollList:AddAnchor(anchorInfo.point, anchorInfo.relativeTo, anchorInfo.offsetX or 0, anchorInfo.offsetY or 0)
        
--         -- Add secondary anchor for responsive sizing if specified
--         if options.bottomAnchor then
--             scrollList:AddAnchor(options.bottomAnchor.point, options.bottomAnchor.relativeTo, 
--                                 options.bottomAnchor.offsetX or 0, options.bottomAnchor.offsetY or 0)
--         end
--     end
    
--     -- INSERT COLUMNS with automatic sorting functionality
--     for i, column in ipairs(columns) do
--         scrollList:InsertColumn(
--             column.name,                    -- column title displayed in header
--             column.width,                   -- column width in pixels
--             column.listType or listType,    -- column type (affects rendering)
--             column.setFunc,                 -- function to populate cell data
--             nil,                           -- unused parameter
--             nil,                           -- unused parameter
--             column.layoutFunc              -- optional function to create custom cell layouts
--         )
        
--         -- Initialize sort state for this column (none/asc/desc)
--         scrollList.sortState[i] = "none"
--     end
    
--     -- CREATE ROWS
--     scrollList:InsertRows(rowCount, false)

--     -- Add debugging for listCtrl
--     if scrollList.listCtrl then
--         --PrintControl(scrollList.listCtrl, "ListCtrl")
--     else
--         api.Log:Info("Debug: scrollList.listCtrl is nil")
--     end
    
--     -- APPLY VISUAL STYLING AND SETUP SORTING
--     DrawListCtrlUnderLine(scrollList.listCtrl)
--     for i = 1, #scrollList.listCtrl.column do
--         SettingListColumn(scrollList.listCtrl, scrollList.listCtrl.column[i])
--         DrawListCtrlColumnSperatorLine(scrollList.listCtrl.column[i], #scrollList.listCtrl.column, i)
        
--         -- Enable column clicking for sorting functionality
--         scrollList.listCtrl.column[i]:Enable(true)
        
--         -- Setup sorting click handler for each column header
--         local columnButton = scrollList.listCtrl.column[i]
--         columnButton.columnIndex = i
--         columnButton.scrollList = scrollList
        
--         function columnButton:OnClick()
--             api.Log:Info("Column clicked: " .. tostring(self.columnIndex))
            
--             local colIndex = self.columnIndex
--             local list = self.scrollList
--             local column = columns[colIndex]
            
--             api.Log:Info("Column name: " .. tostring(column.name))
            
--             -- Skip sorting for action columns or explicitly disabled columns
--             if column.name == "Actions" or column.name == "Move" or column.disableSort then
--                 api.Log:Info("Skipping sort for column: " .. column.name)
--                 return
--             end
            
--             -- Toggle sort direction: none -> asc -> desc -> asc -> ...
--             local oldState = list.sortState[colIndex]
--             if list.sortState[colIndex] == "asc" then
--                 list.sortState[colIndex] = "desc"
--             else
--                 list.sortState[colIndex] = "asc"
--             end
            
--             api.Log:Info("Sort state changed from " .. tostring(oldState) .. " to " .. list.sortState[colIndex])
            
--             -- Reset other columns to unsorted state
--             for j = 1, #list.sortState do
--                 if j ~= colIndex then
--                     list.sortState[j] = "none"
--                 end
--             end
            
--             api.Log:Info("Calling SortByColumn...")
            
--             -- Perform the actual sort
--             list:SortByColumn(colIndex, list.sortState[colIndex] == "asc")
            
--             api.Log:Info("Sort completed")
--         end
        
--         columnButton:SetHandler("OnClick", columnButton.OnClick)
--     end
    
--     -- Initialize data storage
--     scrollList.dataSource = {}
    
--     --[[
--     ENHANCED SORTING METHOD
--     Intelligently sorts the scroll list data by the specified column with comprehensive
--     number parsing and data type detection.
    
--     @param columnIndex: Index of the column to sort by (1-based)
--     @param ascending: boolean - true for ascending sort, false for descending
--     ]]
--     function scrollList:SortByColumn(columnIndex, ascending)
--         if not self.dataSource or #self.dataSource == 0 then
--             api.Log:Info("No data to sort")
--             return
--         end
        
--         local column = columns[columnIndex]
--         local fieldName = nil
        
--         -- Map column names to data field names
--         -- This mapping should be customized based on your data structure
--         if column.name == "ID" then
--             fieldName = "id"
--         elseif column.name == "Name" then
--             fieldName = "name"
--         elseif column.name == "Cost" then
--             fieldName = "cost"
--         elseif column.name == "Value" then
--             fieldName = "value"
--         elseif column.name == "Profit" then
--             fieldName = "profit"
--         else
--             api.Log:Info("Unknown column for sorting: " .. tostring(column.name))
--             return
--         end
        
--         api.Log:Info("Sorting by field: " .. fieldName .. ", ascending: " .. tostring(ascending))
--         api.Log:Info("Data count before sort: " .. #self.dataSource)
        
--         -- Log sample data for debugging
--         for i = 1, math.min(3, #self.dataSource) do
--             local row = self.dataSource[i]
--             api.Log:Info("Sample row " .. i .. " - " .. fieldName .. ": '" .. tostring(row[fieldName]) .. "' (type: " .. type(row[fieldName]) .. ")")
--         end
        
--         -- Automatically detect whether this column contains numbers or strings
--         local dataType = "string"
--         for _, row in ipairs(self.dataSource) do
--             if row[fieldName] ~= nil then
--                 dataType = detectDataType(row[fieldName])
--                 api.Log:Info("Detected data type for '" .. column.name .. "': " .. dataType .. " from value: " .. tostring(row[fieldName]))
--                 break
--             end
--         end
        
--         -- Perform the sort using intelligent comparison
--         table.sort(self.dataSource, function(a, b)
--             local valueA = a[fieldName]
--             local valueB = b[fieldName]
            
--             -- Handle nil/missing values (always sort to end)
--             if valueA == nil and valueB == nil then
--                 return false
--             elseif valueA == nil then
--                 return not ascending  -- nil values go to end
--             elseif valueB == nil then
--                 return ascending      -- nil values go to end
--             else
--                 return compareValues(valueA, valueB, dataType, ascending)
--             end
--         end)
        
--         -- Log results for debugging
--         api.Log:Info("Data after sort (first 3 rows):")
--         for i = 1, math.min(3, #self.dataSource) do
--             local row = self.dataSource[i]
--             api.Log:Info("Row " .. i .. " - " .. fieldName .. ": " .. tostring(row[fieldName]))
--         end
        
--         api.Log:Info("Data sorted successfully, now updating display...")
        
--         -- Refresh the visual display with sorted data
--         self:DeleteAllDatas()
        
--         -- Repopulate with sorted data
--         for rowIndex, rowData in ipairs(self.dataSource) do
--             if rowIndex <= rowCount then
--                 self:InsertRowData(rowIndex, #columns, rowData)
--             end
--         end
        
--         -- Force visual refresh
--         self:UpdateView()
        
--         api.Log:Info("Display update completed")
--     end
    
--     -- ENHANCED DATA MANAGEMENT METHODS
--     -- These provide a clean API for managing the scroll list data
    
--     --[[
--     Replaces all data in the scroll list with new data array.
--     Automatically clears existing data and refreshes the display.
    
--     @param data: Array of data objects to display
--     ]]
--     function scrollList:UpdateData(data)
--         -- Store the data source for sorting and other operations
--         self.dataSource = data or {}
        
--         -- Clear existing display data
--         self:DeleteAllDatas()
        
--         -- Populate with new data
--         if data and #data > 0 then
--             for rowIndex, rowData in ipairs(data) do
--                 if rowIndex <= rowCount then
--                     self:InsertRowData(rowIndex, #columns, rowData)
--                 end
--             end
--             self:UpdateView()  -- Refresh the visual display
--         end
--     end
    


--     --[[
--     Clears all data from the scroll list and resets sort states.
--     ]]
--     function scrollList:ClearData()
--         -- Clear data source and reset sorting states
--         self.dataSource = {}
--         for i = 1, #self.sortState do
--             self.sortState[i] = "none"
--         end
        
--         -- Clear visual display
--         self:DeleteAllDatas()
--         self:UpdateView()
--     end
    
--     --[[
--     Updates the data for a specific row and refreshes the display.
    
--     @param rowIndex: Index of the row to update (1-based)
--     @param data: New data object for this row
--     ]]
--     function scrollList:SetRowData(rowIndex, data)
--         -- Update the stored data
--         self.dataSource[rowIndex] = data
        
--         -- Update the visual display for this row
--         self:InsertRowData(rowIndex, #columns, data)

--         self:UpdateView()
--     end

 
    
--     --[[
--     Retrieves the data object for a specific row.
    
--     @param rowIndex: Index of the row to get data for (1-based)
--     @return: Data object for the specified row, or nil if not found
--     ]]
--     function scrollList:GetRowData(rowIndex)
--         return self.dataSource[rowIndex]
--     end
    
--     --[[
--     Swaps the positions of two rows in the list.
--     Useful for manual reordering functionality.
    
--     @param row1: Index of first row to swap
--     @param row2: Index of second row to swap
--     ]]
--     function scrollList:SwapRows(row1, row2)
--         if self.dataSource[row1] and self.dataSource[row2] then
--             -- Swap in data source
--             self.dataSource[row1], self.dataSource[row2] = self.dataSource[row2], self.dataSource[row1]
--             -- Refresh the entire display to show changes
--             self:UpdateData(self.dataSource)
--         end
--     end
    
--     --[[
--     Removes a row from the list and refreshes the display.
    
--     @param rowIndex: Index of the row to delete (1-based)
--     ]]
--     function scrollList:DeleteRow(rowIndex)
--         if self.dataSource[rowIndex] then
--             -- Remove from data source
--             table.remove(self.dataSource, rowIndex)
--             -- Refresh the entire list to show changes
--             self:UpdateData(self.dataSource)
--         end
--     end
    
--     --[[
--     Adds a new row to the end of the list.
    
--     @param data: Data object for the new row
--     ]]
--     function scrollList:AddRow(data)
--         -- Add to data source
--         table.insert(self.dataSource, data)
--         -- Refresh if within visible row limit
--         if #self.dataSource <= rowCount then
--             self:UpdateData(self.dataSource)
--         end
--     end


    
        
--     -- Store reference on parent window for easy access
--     parent[id] = scrollList
    
--     return scrollList
-- end

--SCRTOLL WORKS BUT DOESNT OPOULATE!!!
local function AddScrollList(parent, id, columns, anchorInfo, dimensions, options)
    -- Set default values for optional parameters
    options = options or {}
    local listType = options.listType or 3
    local rowCount = options.rowCount or 20
    local columnHeight = options.columnHeight or 35
    local rowHeight = options.rowHeight or 20
    local enableColumns = options.enableColumns or false
    local enablePagination = options.enablePagination ~= false  -- Default to true
    local pageSize = options.pageSize or 1000  -- Large default for scrolling
    
    -- Helper functions for consistent styling across all scroll lists
    local function SetButtonFontColor(button, color)
        local n = color.normal
        local h = color.highlight
        local p = color.pushed
        local d = color.disabled
        button:SetTextColor(n[1], n[2], n[3], n[4])
        button:SetHighlightTextColor(h[1], h[2], h[3], h[4])
        button:SetPushedTextColor(p[1], p[2], p[3], p[4])
        button:SetDisabledTextColor(d[1], d[2], d[3], d[4])
    end

    local function GetButtonDefaultFontColor()
        local color = {}
        color.normal = {ConvertColor(104), ConvertColor(68), ConvertColor(18), 1}
        color.highlight = {ConvertColor(154), ConvertColor(96), ConvertColor(16), 1}
        color.pushed = {ConvertColor(104), ConvertColor(68), ConvertColor(18), 1}
        color.disabled = {ConvertColor(92), ConvertColor(92), ConvertColor(92), 1}
        return color
    end

    local function SettingListColumn(listCtrl, column)
        listCtrl:SetColumnHeight(columnHeight)
        listCtrl:SetHeight(rowHeight)
        api.Interface:ApplyButtonSkin(column, BUTTON_BASIC.LISTCTRL_COLUMN)
        column.style:SetShadow(false)
        column.style:SetFontSize(FONT_SIZE.LARGE)
        SetButtonFontColor(column, GetButtonDefaultFontColor())
    end

    -- Creates the underline decoration beneath column headers
    local function DrawListCtrlUnderLine(listCtrl, offsetY, colorWhite, offsetX, columnHeight)
        if colorWhite == nil then
            colorWhite = false
        end
        local width = listCtrl:GetWidth()
        if offsetX == nil then
            offsetX = 0
        end
        
        -- Create two-part underline graphic
        local underLine_1 = listCtrl:CreateImageDrawable(TEXTURE_PATH.TAB_LIST, "artwork")
        underLine_1:SetCoords(0, 6, 256, 3)
        underLine_1:SetExtent(width / 2, 3)
        local underLine_2 = listCtrl:CreateImageDrawable(TEXTURE_PATH.TAB_LIST, "artwork")
        underLine_2:SetCoords(256, 6, -256, 3)
        underLine_2:SetExtent(width / 2, 3)
        
        -- Apply custom color or default brown
        if options.underlineColor then
            underLine_1:SetColor(options.underlineColor[1], options.underlineColor[2], options.underlineColor[3], options.underlineColor[4] or 1)
            underLine_2:SetColor(options.underlineColor[1], options.underlineColor[2], options.underlineColor[3], options.underlineColor[4] or 1)
        elseif not colorWhite then
            underLine_1:SetColor(ConvertColor(73), ConvertColor(45), ConvertColor(11), 1)
            underLine_2:SetColor(ConvertColor(73), ConvertColor(45), ConvertColor(11), 1)
        end
        
        -- Position the underline - SAFE VERSION with fallback
        if offsetY == nil then
            -- SAFE: Use columnHeight if provided, otherwise fallback to default
            local safeColumnHeight = columnHeight or 35 -- Default fallback
            if type(safeColumnHeight) ~= "number" then
                safeColumnHeight = 35 -- Emergency fallback
            end
            underLine_1:AddAnchor("TOPLEFT", listCtrl, offsetX, safeColumnHeight - 2)
            underLine_2:AddAnchor("TOPRIGHT", listCtrl, -offsetX, safeColumnHeight - 2)
        else
            underLine_1:AddAnchor("TOPLEFT", listCtrl, offsetX, offsetY)
            underLine_2:AddAnchor("TOPRIGHT", listCtrl, -offsetX, offsetY)
        end
    end

    -- Creates visual separator lines between columns
    local function DrawListCtrlColumnSperatorLine(widget, totalCount, count, colorWhite)
        local inset = 3
        if colorWhite == nil then
            colorWhite = false
        end
        local divideLine
        if count < totalCount then
            divideLine = widget:CreateImageDrawable("ui/common/tab_list.dds", "overlay")
            
            -- Different separator graphics based on column position
            if count % 3 == 1 then
                divideLine:SetExtent(24, 55)
                divideLine:SetCoords(182, 9, 24, 55)
                divideLine:AddAnchor("BOTTOMLEFT", widget, "BOTTOMRIGHT", 0, 33)
            elseif count % 3 == 2 then
                divideLine:SetExtent(25, 51)
                divideLine:SetCoords(206, 9, 25, 51)
                divideLine:AddAnchor("BOTTOMLEFT", widget, "BOTTOMRIGHT", 0, 22)
            else
                divideLine:SetExtent(25, 15)
                divideLine:SetCoords(231, 9, 25, 15)
                divideLine:AddAnchor("BOTTOMLEFT", widget, "BOTTOMRIGHT", 0, 0)
            end
            
            -- Apply custom color or default brown-gold
            if options.separatorColor then
                divideLine:SetColor(options.separatorColor[1], options.separatorColor[2], options.separatorColor[3], options.separatorColor[4] or 1)
            elseif not colorWhite then
                divideLine:SetColor(ConvertColor(114), ConvertColor(94), ConvertColor(50), 1)
            end
        end
        return divideLine
    end

    -- ADVANCED SORTING HELPER FUNCTIONS
    local function detectDataType(value)
        if type(value) == "number" then
            return "number"
        elseif type(value) == "string" then
            local cleanValue = tostring(value)
            cleanValue = cleanValue:gsub("[,%s%$%(%)]", "")
            local isNegative = cleanValue:match("%-") or value:match("^%(.+%)$")
            cleanValue = cleanValue:gsub("%-", "")
            
            local numValue = tonumber(cleanValue)
            if numValue then
                return "number"
            else
                return "string"
            end
        else
            return "string"
        end
    end

    local function parseNumber(value)
        if type(value) == "number" then
            return value
        end
        
        local str = tostring(value)
        local isNegative = false
        if str:match("^%(.+%)$") then
            isNegative = true
            str = str:gsub("[%(%)]", "")
        elseif str:match("^%-") then
            isNegative = true
        end
        
        str = str:gsub("[^%d%.]", "")
        local num = tonumber(str) or 0
        return isNegative and -num or num
    end

    local function compareValues(a, b, dataType, ascending)
        if dataType == "number" then
            local numA = parseNumber(a)
            local numB = parseNumber(b)
            
            if ascending then
                return numA < numB
            else
                return numA > numB
            end
        else
            local strA = tostring(a):lower()
            local strB = tostring(b):lower()
            if ascending then
                return strA < strB
            else
                return strA > strB
            end
        end
    end

    -- CREATE THE MAIN SCROLL LIST WIDGET
    local scrollList = W_CTRL.CreatePageScrollListCtrl(id, parent)
    scrollList:Show(true)

    if not enablePagination or options.hidePageControl then
        for _, key in ipairs({"pageControl", "pageCtrl", "pageController", "page"}) do
            local pager = scrollList[key]
            if pager and type(pager) ~= "function" then
                pcall(function()
                    if pager.Show then pager:Show(false) end
                    if pager.Enable then pager:Enable(false) end
                end)
            end
        end
    end
    
    -- Store configuration
    scrollList.rowHeight = rowHeight
    scrollList.parentWidget = parent
    scrollList.sortState = {}
    scrollList.pageSize = pageSize
    scrollList.enablePagination = enablePagination
    
    -- SET DIMENSIONS
    local width, height
    if type(dimensions.width) == "function" then
        width = dimensions.width()
    else
        width = dimensions.width
    end
    if type(dimensions.height) == "function" then
        height = dimensions.height()
    else
        height = dimensions.height
    end
    scrollList:SetExtent(width, height)
    
    -- APPLY POSITIONING
    if anchorInfo then
        scrollList:AddAnchor(anchorInfo.point, anchorInfo.relativeTo, anchorInfo.offsetX or 0, anchorInfo.offsetY or 0)
        
        if options.bottomAnchor then
            scrollList:AddAnchor(options.bottomAnchor.point, options.bottomAnchor.relativeTo, 
                                options.bottomAnchor.offsetX or 0, options.bottomAnchor.offsetY or 0)
        end
    end
    
    -- SETUP SCROLL BAR POSITIONING (Critical for proper scrolling)
    if scrollList.scroll then
        scrollList.scroll:AddAnchor("TOPRIGHT", scrollList, 0, 0)
        scrollList.scroll:AddAnchor("BOTTOMRIGHT", scrollList, 0, 0)
    end
    
    -- INSERT COLUMNS
    for i, column in ipairs(columns) do
        scrollList:InsertColumn(
            column.name,
            column.width,
            column.listType or listType,
            column.setFunc,
            nil,
            nil,
            column.layoutFunc
        )
        scrollList.sortState[i] = "none"
    end
    
    -- CREATE ROWS
    scrollList:InsertRows(rowCount, false)

    -- APPLY VISUAL STYLING AND SETUP SORTING
    if scrollList.listCtrl then
        DrawListCtrlUnderLine(scrollList.listCtrl, nil, nil, nil, columnHeight)
        for i = 1, #scrollList.listCtrl.column do
            SettingListColumn(scrollList.listCtrl, scrollList.listCtrl.column[i])
            DrawListCtrlColumnSperatorLine(scrollList.listCtrl.column[i], #scrollList.listCtrl.column, i)
            
            scrollList.listCtrl.column[i]:Enable(true)
            
            local columnButton = scrollList.listCtrl.column[i]
            columnButton.columnIndex = i
            columnButton.scrollList = scrollList
            
            function columnButton:OnClick()
                local colIndex = self.columnIndex
                local list = self.scrollList
                local column = columns[colIndex]
                
                if column.name == "Actions" or column.name == "Move" or column.disableSort then
                    return
                end
                
                if list.sortState[colIndex] == "asc" then
                    list.sortState[colIndex] = "desc"
                else
                    list.sortState[colIndex] = "asc"
                end
                
                for j = 1, #list.sortState do
                    if j ~= colIndex then
                        list.sortState[j] = "none"
                    end
                end

                if options.onSortChanged then
                    options.onSortChanged(colIndex, column, list.sortState[colIndex] == "asc")
                    return
                end
                
                list:SortByColumn(colIndex, list.sortState[colIndex] == "asc")
            end
            
            columnButton:SetHandler("OnClick", columnButton.OnClick)
        end
    end
    
    -- Initialize data storage
    scrollList.dataSource = {}
    
    -- Fill data function adapted for multi-column support
    local function fillScrollData(scrollList, pageIndex, searchText)
        scrollList:DeleteAllDatas()
        
        if not scrollList.dataSource or #scrollList.dataSource == 0 then
            return
        end
        
        -- Calculate pagination like dress-up addon
        local startingIndex = 1
        local endingIndex = #scrollList.dataSource
        if pageIndex > 1 then 
            startingIndex = ((pageIndex - 1) * pageSize) + 1 
            endingIndex = math.min(startingIndex + pageSize - 1, #scrollList.dataSource)
        end
        
        local count = 1
        for dataIndex = startingIndex, endingIndex do
            local rowData = scrollList.dataSource[dataIndex]
            if rowData then
                -- Apply search filter if needed
                if searchText == nil or (rowData.name and string.find(rowData.name:lower(), searchText:lower())) then
                    -- FIXED: Insert data for each column individually
                    for columnIndex = 1, #columns do
                        scrollList:InsertData(count, columnIndex, rowData, false)
                    end
                    count = count + 1
                end
            end
        end
        
        scrollList:UpdateView()
    end

    -- ENHANCED SCROLLING DATA MANAGEMENT
    function scrollList:UpdateData(data)
        self.dataSource = data or {}
        
        -- Setup pagination for scrolling when we have more data than visible rows
        if enablePagination and #self.dataSource > 0 then
            -- Set up pagination with actual data count - key for scrolling
            self:SetPageByItemCount(#self.dataSource, pageSize)
        end
        
        -- Fill initial data
        fillScrollData(self, 1, nil)
    end
    
    -- Setup page change handler for scrolling (this is the key!)
    function scrollList:OnPageChangedProc(curPageIdx)
        fillScrollData(self, curPageIdx, nil)
    end

    function scrollList:SortByColumn(columnIndex, ascending)
        if not self.dataSource or #self.dataSource == 0 then
            return
        end
        
        local column = columns[columnIndex]
        local fieldName = nil
        
        -- Prefer explicit column fields, fall back to older hard-coded names.
        if column.field then
            fieldName = column.field
        elseif column.name == "ID" then
            fieldName = "id"
        elseif column.name == "Name" then
            fieldName = "name"
        elseif column.name == "Cost" then
            fieldName = "cost"
        elseif column.name == "Value" then
            fieldName = "value"
        elseif column.name == "Profit" then
            fieldName = "profit"
        else
            return
        end
        
        -- Detect data type
        local dataType = "string"
        for _, row in ipairs(self.dataSource) do
            if row[fieldName] ~= nil then
                dataType = detectDataType(row[fieldName])
                break
            end
        end
        
        -- Sort the data
        table.sort(self.dataSource, function(a, b)
            local valueA = a[fieldName]
            local valueB = b[fieldName]
            
            if valueA == nil and valueB == nil then
                return false
            elseif valueA == nil then
                return not ascending
            elseif valueB == nil then
                return ascending
            else
                return compareValues(valueA, valueB, dataType, ascending)
            end
        end)
        
        -- Refresh current page with sorted data
        local currentPage = 1
        if self.enablePagination then
            -- Try to maintain current page if possible
            currentPage = self.pageControl and self.pageControl:GetCurrentPageIndex() or 1
        end
        self:RefreshPage(currentPage)
    end
    
    function scrollList:ClearData()
        self.dataSource = {}
        for i = 1, #self.sortState do
            self.sortState[i] = "none"
        end
        self:DeleteAllDatas()
        self:UpdateView()
    end
    
    -- CRITICAL FIX: Add missing RefreshPage method
    function scrollList:RefreshPage(pageIndex)
        pageIndex = pageIndex or 1
        fillScrollData(self, pageIndex, nil)
    end
    
    function scrollList:SetRowData(rowIndex, data)
        self.dataSource[rowIndex] = data
        self:RefreshPage(1) -- Refresh to show changes
    end

    function scrollList:GetRowData(rowIndex)
        return self.dataSource[rowIndex]
    end
    
    function scrollList:SwapRows(row1, row2)
        if self.dataSource[row1] and self.dataSource[row2] then
            self.dataSource[row1], self.dataSource[row2] = self.dataSource[row2], self.dataSource[row1]
            self:UpdateData(self.dataSource)
        end
    end
    
    function scrollList:DeleteRow(rowIndex)
        if self.dataSource[rowIndex] then
            table.remove(self.dataSource, rowIndex)
            self:UpdateData(self.dataSource)
        end
    end
    
    function scrollList:AddRow(data)
        table.insert(self.dataSource, data)
        self:UpdateData(self.dataSource)
    end
    
    -- Store reference on parent window for easy access
    parent[id] = scrollList
    
    return scrollList
end



--[[
Creates a hierarchical tree view widget for displaying nested data structures.
Useful for displaying folder structures, recipe trees, skill trees, etc.

@param parent (widget) Parent window to contain the tree view
@param id (string) Unique identifier for the tree view
@param anchorConfig (table) Positioning configuration:
    - point, relativeTo, offsetX, offsetY (primary anchor)
    - point2, relativeTo2, offsetX2, offsetY2 (optional secondary anchor)
@param sizeConfig (table) Size configuration: {width, height}
@param options (table, optional) Display options:
    - itemFontSize: Font size for main items
    - childFontSize: Font size for child items  
    - color: Text color for items
    - rowHeight: Height of each row
@param data (table, optional) Tree data to display
@param builderFunc (function, optional) Function to convert data to tree format

USAGE EXAMPLES:
    -- Simple skill tree display
    local skillTreeData = {
        {text = "Combat Skills", value = "combat", subTexts = {
            {text = "Sword Mastery", value = "sword_1"},
            {text = "Shield Defense", value = "shield_1"},
            {text = "Heavy Armor", value = "armor_1"}
        }},
        {text = "Magic Skills", value = "magic", subTexts = {
            {text = "Fire Magic", value = "fire_1"},
            {text = "Healing", value = "heal_1"}
        }}
    }
    
    local skillTree = AddTreeView(skillPanel, "skills",
        {point = "TOPLEFT", relativeTo = skillPanel, offsetX = 10, offsetY = 30},
        {width = 250, height = 400},
        {itemFontSize = FONT_SIZE.LARGE, childFontSize = FONT_SIZE.DEFAULT, rowHeight = 20},
        skillTreeData
    )
    
    -- Recipe tree with builder function
    local recipeData = {
        {name = "Steel Sword", materials = {
            {name = "Steel Ingot", quantity = 2},
            {name = "Leather Grip", quantity = 1}
        }}
    }
    
    local function recipeTreeBuilder(recipes)
        local treeData = {}
        for _, recipe in ipairs(recipes) do
            local node = {text = recipe.name, value = recipe.name, subTexts = {}}
            for _, mat in ipairs(recipe.materials) do
                table.insert(node.subTexts, {text = mat.name .. " (" .. mat.quantity .. ")", value = mat.name})
            end
            table.insert(treeData, node)
        end
        return treeData
    end
    
    local recipeTree = AddTreeView(recipePanel, "recipes",
        {point = "CENTER", relativeTo = recipePanel, offsetX = 0, offsetY = 0},
        {width = 300, height = 200},
        {color = FONT_COLOR.YELLOW},
        recipeData, recipeTreeBuilder
    )
]]
function AddTreeView(parent, id, anchorConfig, sizeConfig, options, data, builderFunc)
    -- 1) Create the treeview
    local treeView = W_CTRL.CreateScrollListBox(id, parent)

    -- 2) Anchor it
    if anchorConfig then
        if anchorConfig.point and anchorConfig.relativeTo and anchorConfig.offsetX and anchorConfig.offsetY then
            treeView:AddAnchor(anchorConfig.point, anchorConfig.relativeTo, anchorConfig.offsetX, anchorConfig.offsetY)
        end
        if anchorConfig.point2 and anchorConfig.relativeTo2 and anchorConfig.offsetX2 and anchorConfig.offsetY2 then
            treeView:AddAnchor(anchorConfig.point2, anchorConfig.relativeTo2, anchorConfig.offsetX2, anchorConfig.offsetY2)
        end
    end

    -- 3) Set dimensions
    if sizeConfig then
        local w = sizeConfig.width or 300
        local h = sizeConfig.height or 200
        treeView:SetWidth(w)
        treeView:SetHeight(h)
    end

    -- 4) Configure tree content
    local content = treeView.content
    content:UseChildStyle(true)
    content:EnableSelectParent(true)
    content:SetInset(0, 0, 0, 0)
    content.itemStyle:SetFontSize(options and options.itemFontSize or FONT_SIZE.LARGE)
    content.childStyle:SetFontSize(options and options.childFontSize or FONT_SIZE.LARGE)
    content.itemStyle:SetAlign(ALIGN.LEFT)
    content:SetTreeTypeIndent(true, 0)
    content:SetHeight(options and options.rowHeight or 15)
    content:ShowTooltip(true)
    content:SetSubTextOffset(-100, 0, true)
    
    local color = (options and options.color) or FONT_COLOR.BLACK
    content:SetDefaultItemTextColor(color[1], color[2], color[3], color[4])
    content.childStyle:SetColor(color[1], color[2], color[3], color[4])

    -- 5) If data is provided, process it
    if data then
        local treeData
        if builderFunc then
            -- Use builder function to convert source data into tree format
            treeData = builderFunc(data)
        else
            -- Assume data is already in proper treeview format
            treeData = data
        end

        treeView:SetItemTrees(treeData)
        treeView:SetMinMaxValues(0, treeView:GetMaxTop())
    end

    return treeView
end




--[[
==========================================================================
                              MODULE EXPORTS
==========================================================================
Export all functions for use in other modules
==========================================================================
]]
return {
    CreateStyledWindow = CreateStyledWindow,
    CreateCategoryPanel = CreateCategoryPanel,
    AddButton = AddButton,
    AddLabel = AddLabel,
    AddCheckbox = AddCheckbox,
    AddEditBox = AddEditBox,
    AddScrollList = AddScrollList,
    AddTreeView = AddTreeView,
    PrintControl = PrintControl,
    -- Utility functions for hierarchy display
    GetTierColor = GetTierColor,
    GetHierarchyDisplayName = GetHierarchyDisplayName,
    GetStatusColor = GetStatusColor
}
