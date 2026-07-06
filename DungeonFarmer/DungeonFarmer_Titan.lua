local _, addon = ...

local TITAN_PLUGIN_ID = "DungeonFarmer"
local TITAN_PLUGIN_FRAME_NAME = "TitanPanel" .. TITAN_PLUGIN_ID .. "Button"
local TITAN_PLUGIN_ICON = "Interface\\Icons\\inv_misc_head_dragon_black"
local TITAN_REFRESH_SECONDS = 30
local TITAN_TOOLTIP_REFRESH_SECONDS = 1

local titanFrame
local titanEventFrame
local titanUpdateTicker
local titanTooltipTicker
local titanTooltipSnapshot

-- Titan availability and display helpers
local function IsTitanAvailable()
    return type(TitanUtils_PluginToRegister) == "function"
        and type(TitanPanelButton_UpdateButton) == "function"
        and type(TitanPanelButton_OnLoad) == "function"
        and type(TitanUtils_GetColoredText) == "function"
end

local function GetTitanDisplayInfo()
    if titanTooltipSnapshot then
        return addon.GetDisplayInfoFromSnapshot(titanTooltipSnapshot)
    end

    return addon.GetDisplayInfo()
end

local function GetTitanButtonText()
    local displayInfo = addon.GetDisplayInfo()
    local coloredText = TitanUtils_GetColoredText(displayInfo.shortCountText, displayInfo.color)
    return "", coloredText
end

local function GetTitanTooltipText()
    local displayInfo = GetTitanDisplayInfo()
    return string.format("%s\n%s", displayInfo.countText, displayInfo.nextLockoutText)
end

local function TitanPanelRightClickMenu_PrepareDungeonFarmerMenu()
    TitanPanelRightClickMenu_AddTitle(addon.TITLE)
    TitanPanelRightClickMenu_AddCommand(TITAN_PANEL_MENU_HIDE, TITAN_PLUGIN_ID, TITAN_PANEL_MENU_FUNC_HIDE)
end

local function HandleTitanClick(_, button)
    if button == "LeftButton" and addon.PrintDungeonLog then
        addon.PrintDungeonLog()
    end
end

local function UpdateTitanPlugin()
    if not IsTitanAvailable() or not titanFrame then
        return
    end

    if type(TitanPanelPluginHandle_OnUpdate) == "function" then
        TitanPanelPluginHandle_OnUpdate({ TITAN_PLUGIN_ID, TITAN_PANEL_UPDATE_ALL })
    else
        TitanPanelButton_UpdateButton(TITAN_PLUGIN_ID)
    end
end

-- Titan tooltip refresh while hovered
local function RefreshTitanTooltip(button)
    if TitanPanelTooltip and TitanPanelTooltip:IsOwned(button) then
        TitanPanelButton_UpdateTooltip(button)
    end
end

local function StopTitanTooltipRefresh()
    if titanTooltipTicker then
        titanTooltipTicker:Cancel()
        titanTooltipTicker = nil
    end

    titanTooltipSnapshot = nil
end

local function StartTitanTooltipRefresh(button)
    if not button then
        return
    end

    StopTitanTooltipRefresh()
    titanTooltipSnapshot = addon.CreateDisplaySnapshot()
    RefreshTitanTooltip(button)

    titanTooltipTicker = C_Timer.NewTicker(TITAN_TOOLTIP_REFRESH_SECONDS, function()
        if not TitanPanelTooltip or not TitanPanelTooltip:IsOwned(button) then
            StopTitanTooltipRefresh()
            return
        end

        RefreshTitanTooltip(button)
    end)
end

-- Titan plugin registration and lifecycle
local function CreateTitanPlugin()
    if titanFrame or not IsTitanAvailable() then
        return
    end

    titanFrame = CreateFrame("Button", TITAN_PLUGIN_FRAME_NAME, UIParent, "TitanPanelComboTemplate")
    titanFrame.registry = {
        id = TITAN_PLUGIN_ID,
        category = "General",
        version = addon.VERSION,
        menuText = addon.TITLE,
        tooltipTitle = addon.TITLE,
        tooltipTextFunction = GetTitanTooltipText,
        buttonTextFunction = GetTitanButtonText,
        icon = TITAN_PLUGIN_ICON,
        iconWidth = 16,
        notes = "Shows rolling dungeon lockout count and tooltip details.",
        savedVariables = {
            ShowIcon = 1,
            ShowLabelText = 0,
            ShowColoredText = 1,
            DisplayOnRightSide = 0,
        },
        menuTextFunction = TitanPanelRightClickMenu_PrepareDungeonFarmerMenu,
    }

    TitanPanelButton_OnLoad(titanFrame)
    titanFrame:SetScript("OnShow", function(self)
        TitanPanelButton_OnShow(self)
    end)
    titanFrame:HookScript("OnClick", HandleTitanClick)
    titanFrame:HookScript("OnEnter", function(self)
        StartTitanTooltipRefresh(self)
    end)
    titanFrame:HookScript("OnLeave", function()
        StopTitanTooltipRefresh()
    end)

    titanEventFrame = CreateFrame("Frame")
    titanEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    titanEventFrame:SetScript("OnEvent", function()
        UpdateTitanPlugin()
    end)

    titanUpdateTicker = C_Timer.NewTicker(TITAN_REFRESH_SECONDS, function()
        UpdateTitanPlugin()
    end)
end

local titanLoader = CreateFrame("Frame")
titanLoader:RegisterEvent("PLAYER_LOGIN")
titanLoader:SetScript("OnEvent", function()
    CreateTitanPlugin()
    UpdateTitanPlugin()
end)
