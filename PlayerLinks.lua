------------------------------------------------------------------------
-- OrderedLootList  –  PlayerLinks.lua
-- Maps alt characters to a canonical "main" identity
------------------------------------------------------------------------

local ns = _G.OLL_NS

local PlayerLinks = {}
ns.PlayerLinks = PlayerLinks

------------------------------------------------------------------------
-- Resolve a character name to its canonical (main) identity.
-- If the character isn't linked, returns itself.
-- @param name  string  "Name-Realm"
-- @return string  canonical name
------------------------------------------------------------------------
function PlayerLinks:ResolveIdentity(name)
    if not name then return name end
    local links = ns.db.global.playerLinks

    -- Check if 'name' IS a main
    if links[name] then return name end

    -- Check if 'name' is listed as an alt of any main
    for main, alts in pairs(links) do
        for _, alt in ipairs(alts) do
            if alt == name then
                return main
            end
        end
    end

    return name -- not linked anywhere
end

------------------------------------------------------------------------
-- Link an alt to a main.  Creates the main entry if needed.
-- @param main string  "Main-Realm"
-- @param alt  string  "Alt-Realm"
------------------------------------------------------------------------
function PlayerLinks:LinkCharacter(main, alt)
    if main == alt then return end
    local links = ns.db.global.playerLinks

    -- Make sure the alt isn't already a main with its own alts
    if links[alt] then
        -- Merge alt's alts into main
        local existingAlts = links[alt]
        links[alt] = nil
        if not links[main] then links[main] = {} end
        for _, a in ipairs(existingAlts) do
            self:_AddAltToList(links[main], a)
        end
        -- Also add 'alt' itself
        self:_AddAltToList(links[main], alt)
    else
        -- Remove alt from any existing main first
        self:UnlinkCharacter(alt)
        if not links[main] then links[main] = {} end
        self:_AddAltToList(links[main], alt)
    end
end

------------------------------------------------------------------------
-- Remove an alt from its current main link.
------------------------------------------------------------------------
function PlayerLinks:UnlinkCharacter(alt)
    local links = ns.db.global.playerLinks
    for main, alts in pairs(links) do
        for i, a in ipairs(alts) do
            if a == alt then
                table.remove(alts, i)
                -- Clean up empty main entries
                if #alts == 0 then
                    links[main] = nil
                end
                return
            end
        end
    end
end

------------------------------------------------------------------------
-- Get all alts for a main (returns empty table if none).
------------------------------------------------------------------------
function PlayerLinks:GetAlts(main)
    return ns.db.global.playerLinks[main] or {}
end

------------------------------------------------------------------------
-- Get all known mains.
------------------------------------------------------------------------
function PlayerLinks:GetAllMains()
    local mains = {}
    for main, _ in pairs(ns.db.global.playerLinks) do
        tinsert(mains, main)
    end
    table.sort(mains)
    return mains
end

------------------------------------------------------------------------
-- Get the full table (for syncing).
------------------------------------------------------------------------
function PlayerLinks:GetLinksTable()
    return ns.db.global.playerLinks
end

------------------------------------------------------------------------
-- Replace links table (from sync).
------------------------------------------------------------------------
function PlayerLinks:SetLinksTable(tbl)
    ns.db.global.playerLinks = tbl or {}
end

------------------------------------------------------------------------
-- Internal: add to list if not already present.
------------------------------------------------------------------------
function PlayerLinks:_AddAltToList(list, name)
    for _, v in ipairs(list) do
        if v == name then return end
    end
    tinsert(list, name)
end
