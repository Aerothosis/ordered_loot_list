------------------------------------------------------------------------
-- OrderedLootList  –  MinimapButton.lua
-- LibDataBroker + LibDBIcon minimap button
-- Left-click : toggle history / settings
-- Right-click: toggle roll frame
------------------------------------------------------------------------

local ns = _G.OLL_NS

local MinimapButton = {}
ns.MinimapButton = MinimapButton

function MinimapButton:Init()
    local LDB = LibStub("LibDataBroker-1.1", true)
    local LDBIcon = LibStub("LibDBIcon-1.0", true)

    if not LDB or not LDBIcon then
        -- Libraries not available – skip minimap button
        return
    end

    local dataObject = LDB:NewDataObject(ns.ADDON_NAME, {
        type          = "launcher",
        label         = ns.ADDON_NAME,
        icon          = "Interface\\Icons\\INV_Misc_Coin_02",
        OnClick       = function(_, button)
            if button == "LeftButton" then
                -- Toggle history / settings
                if ns.HistoryFrame and ns.HistoryFrame:IsVisible() then
                    ns.HistoryFrame:Hide()
                elseif ns.Settings then
                    ns.Settings:OpenConfig()
                end
            elseif button == "RightButton" then
                -- Toggle roll frame
                if ns.RollFrame then
                    ns.RollFrame:Toggle()
                end
            end
        end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine("|cff00ff00OrderedLootList|r v" .. ns.VERSION)
            tooltip:AddLine(" ")
            if ns.Session and ns.Session:IsActive() then
                tooltip:AddLine("Session: |cff00ff00ACTIVE|r")
                tooltip:AddLine("Leader: " .. (ns.Session.leaderName or "Unknown"))
            else
                tooltip:AddLine("Session: |cffff0000Inactive|r")
            end
            tooltip:AddLine(" ")
            tooltip:AddDoubleLine("|cffffffffLeft-Click|r", "History / Settings")
            tooltip:AddDoubleLine("|cffffffffRight-Click|r", "Roll Window")
        end,
    })

    LDBIcon:Register(ns.ADDON_NAME, dataObject, ns.db.profile.minimap)
end

------------------------------------------------------------------------
-- Init on addon load
------------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    MinimapButton:Init()
end)
