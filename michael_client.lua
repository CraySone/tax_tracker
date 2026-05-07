local api = require("api")

local lib = {}
local addedButtons = {}
local addedTitles = {}

local function ensureMichaelClient()
    local configMenu = ADDON:GetContent(UIC.SYSTEM_CONFIG_FRAME)
    if not configMenu then return nil end

    if configMenu.michaelClient == nil then
        local michaelClient = configMenu:CreateChildWidget("label", "michaelClient", 0, true)
        michaelClient:AddAnchor("TOPLEFT", configMenu, -110, 5)
        michaelClient:SetExtent(110, 28)
        michaelClient:SetText("Addon Options")
        configMenu.michaelClient = michaelClient
        configMenu.michaelClient.addons = {}

        michaelClient.bg = michaelClient:CreateNinePartDrawable("ui/common/tab_list.dds", "background")
        michaelClient.bg:SetTextureInfo("bg_quest")
        michaelClient.bg:SetColor(0, 0, 0, 0.5)
        michaelClient.bg:AddAnchor("TOPLEFT", michaelClient, 0, 0)
        michaelClient.bg:AddAnchor("BOTTOMRIGHT", michaelClient, 0, 0)

        michaelClient.addonCount = 0
        function configMenu.michaelClient:AddAddon(title, callback)
            if self.addons[title] then return end

            self.addonCount = self.addonCount + 1
            local widgetName = "tax_tracker_addon_option_" .. tostring(self.addonCount)
            local addonButton = self:CreateChildWidget("button", widgetName, 0, true)
            addonButton:SetText(title)
            addonButton:AddAnchor("TOPLEFT", michaelClient, 5, self.addonCount * 30)
            addonButton:SetExtent(100, 28)
            addonButton:SetHandler("OnClick", function() callback() end)

            addonButton.bg = addonButton:CreateNinePartDrawable("ui/common/tab_list.dds", "background")
            addonButton.bg:SetTextureInfo("bg_quest")
            addonButton.bg:SetColor(0, 0, 0, 0.5)
            addonButton.bg:AddAnchor("TOPLEFT", addonButton, 0, 0)
            addonButton.bg:AddAnchor("BOTTOMRIGHT", addonButton, 0, 0)

            self.addons[title] = addonButton
            table.insert(addedButtons, addonButton)
            table.insert(addedTitles, title)

            local currentWidth = michaelClient.bg:GetWidth()
            michaelClient.bg:SetExtent(currentWidth, self.addonCount * 30)
            michaelClient.bg:RemoveAllAnchors()
            michaelClient.bg:AddAnchor("TOPLEFT", michaelClient, 0, 0)
            michaelClient.bg:AddAnchor("BOTTOMRIGHT", michaelClient, 0, self.addonCount * 30 + 10)
        end
    end

    return configMenu
end

function lib.initializeMichaelClient()
    return ensureMichaelClient()
end

function lib.OnUnload()
    for _, btn in ipairs(addedButtons) do
        if btn and btn.Show then btn:Show(false) end
    end
    local ok, configMenu = pcall(function() return ADDON:GetContent(UIC.SYSTEM_CONFIG_FRAME) end)
    if ok and configMenu and configMenu.michaelClient and configMenu.michaelClient.addons then
        for _, title in ipairs(addedTitles) do
            configMenu.michaelClient.addons[title] = nil
        end
    end
    addedButtons = {}
    addedTitles = {}
end

return lib
