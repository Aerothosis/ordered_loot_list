------------------------------------------------------------------------
-- OrderedLootList  –  MinimapButton.lua
-- LibDataBroker + LibDBIcon minimap button
-- Left-click        : toggle history / settings
-- Shift+Left-click  : start session
-- Right-click       : toggle roll frame
-- Shift+Right-click : toggle leader frame
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
            if button == "LeftButton" and IsShiftKeyDown() then
                -- Shift+Left-click: start a session (leader only)
                if ns.Session then
                    ns.Session:StartSession()
                end
            elseif button == "LeftButton" then
                -- Left-click: toggle history / settings
                if ns.HistoryFrame and ns.HistoryFrame:IsVisible() then
                    ns.HistoryFrame:Hide()
                elseif ns.Settings then
                    ns.Settings:OpenConfig()
                end
            elseif button == "RightButton" and IsShiftKeyDown() then
                -- Shift+Right-click: toggle leader frame
                if ns.LeaderFrame then
                    ns.LeaderFrame:Toggle()
                end
            elseif button == "RightButton" then
                -- Right-click: toggle roll frame
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
            tooltip:AddDoubleLine("|cffffffffShift+Left-Click|r", "Start Session")
            tooltip:AddDoubleLine("|cffffffffRight-Click|r", "Roll Window")
            tooltip:AddDoubleLine("|cffffffffShift+Right-Click|r", "Leader Frame")
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
