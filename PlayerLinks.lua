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

------------------------------------------------------------------------
-- My Characters: player-owned character list
------------------------------------------------------------------------

function PlayerLinks:GetMyMain()
    return ns.db.global.myCharacters.main or ""
end

function PlayerLinks:SetMyMain(name)
    ns.db.global.myCharacters.main = name or ""
    self:MergePlayerCharList(self:GetMyCharactersPayload())
end

function PlayerLinks:GetMyCharacters()
    return ns.db.global.myCharacters.chars
end

function PlayerLinks:AddMyCharacter(name)
    if not name or name == "" then return end
    local chars = ns.db.global.myCharacters.chars
    for _, v in ipairs(chars) do
        if v == name then return end -- already present
    end
    tinsert(chars, name)
    self:MergePlayerCharList(self:GetMyCharactersPayload())
end

function PlayerLinks:RemoveMyCharacter(name)
    local chars = ns.db.global.myCharacters.chars
    for i, v in ipairs(chars) do
        if v == name then
            table.remove(chars, i)
            -- Clear main if the removed character was the main
            if ns.db.global.myCharacters.main == name then
                ns.db.global.myCharacters.main = ""
            end
            -- Remove from playerLinks as well
            self:UnlinkCharacter(name)
            return
        end
    end
end

-- Returns the payload table to whisper to the session leader.
function PlayerLinks:GetMyCharactersPayload()
    return {
        main  = ns.db.global.myCharacters.main or "",
        chars = ns.db.global.myCharacters.chars,
    }
end

-- Leader-side: merge a received player character list into playerLinks.
-- Returns true if the links table was changed, false if nothing new was added.
function PlayerLinks:MergePlayerCharList(payload)
    local main = payload and payload.main
    local chars = payload and payload.chars
    if not main or main == "" or not chars or #chars == 0 then
        return false
    end

    -- Count total alts before merging to detect changes
    local before = 0
    for _, alts in pairs(ns.db.global.playerLinks) do
        before = before + #alts
    end

    for _, char in ipairs(chars) do
        if char ~= main then
            self:LinkCharacter(main, char)
        end
    end

    local after = 0
    for _, alts in pairs(ns.db.global.playerLinks) do
        after = after + #alts
    end

    return after > before
end
