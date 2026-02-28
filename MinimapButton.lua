------------------------------------------------------------------------
-- OrderedLootList  –  MinimapButton.lua
-- LibDataBroker + LibDBIcon minimap button
-- Left-click        : open loot history
-- Middle-click      : open settings
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
                -- Left-click: open loot history
                if ns.HistoryFrame then
                    ns.HistoryFrame:Toggle()
                end
            elseif button == "MiddleButton" then
                -- Middle-click: open settings
                if ns.Settings then
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
            if ns.LootCount then
                local myCount = ns.LootCount:GetCount(ns.GetPlayerNameRealm())
                tooltip:AddLine("Your Loot Count: |cffffff00" .. myCount .. "|r")
            end
            tooltip:AddLine(" ")
            tooltip:AddDoubleLine("|cffffffffLeft-Click|r", "Loot History")
            tooltip:AddDoubleLine("|cffffffffMiddle-Click|r", "Settings")
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
