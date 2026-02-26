------------------------------------------------------------------------
-- OrderedLootList  –  Settings.lua
-- AceConfig options panel: general settings, roll option editor,
-- loot count viewer, character link manager
------------------------------------------------------------------------

local ns                     = _G.OLL_NS

local Settings               = {}
ns.Settings                  = Settings

-- Loot Counts tab sort state (defaults: sort by count, descending)
Settings._lootCountSortField = "count"
Settings._lootCountSortAsc   = false

-- Loot History tab sort state (defaults: sort by date, descending)
Settings._histSortField = "timestamp"
Settings._histSortAsc   = false

------------------------------------------------------------------------
-- Get current roll options (fallback to defaults)
------------------------------------------------------------------------
function Settings:GetRollOptions()
    return ns.db.profile.rollOptions or ns.DEFAULT_ROLL_OPTIONS
end

------------------------------------------------------------------------
-- Set roll options
------------------------------------------------------------------------
function Settings:SetRollOptions(opts)
    ns.db.profile.rollOptions = opts
end

------------------------------------------------------------------------
-- Build AceConfig options table
------------------------------------------------------------------------
function Settings:BuildOptions()
    local options = {
        name = "OrderedLootList",
        handler = ns.addon,
        type = "group",
        childGroups = "tab",
        args = {
            ----------------------------------------------------------------
            -- Tab 1: General
            ----------------------------------------------------------------
            general = {
                type = "group",
                name = "General",
                order = 1,
                args = {
                    lootThreshold = {
                        type = "select",
                        name = "Loot Threshold",
                        desc = "Minimum item quality to trigger roll window.",
                        values = {
                            [2] = "|cff1eff00Uncommon|r",
                            [3] = "|cff0070ddRare|r",
                            [4] = "|cffa335eeEpic|r",
                            [5] = "|cffff8000Legendary|r",
                        },
                        get = function() return ns.db.profile.lootThreshold end,
                        set = function(_, v) ns.db.profile.lootThreshold = v end,
                        order = 1,
                    },
                    rollTimer = {
                        type = "range",
                        name = "Roll Timer (seconds)",
                        desc = "Time players have to respond to a roll.",
                        min = 10,
                        max = 300,
                        step = 5,
                        get = function() return ns.db.profile.rollTimer end,
                        set = function(_, v) ns.db.profile.rollTimer = v end,
                        order = 2,
                    },
                    autoPassBOE = {
                        type = "toggle",
                        name = "Auto-Pass BoE",
                        desc = "Automatically pass on Bind on Equip items.",
                        get = function() return ns.db.profile.autoPassBOE end,
                        set = function(_, v) ns.db.profile.autoPassBOE = v end,
                        order = 3,
                    },
                    announceChannel = {
                        type = "select",
                        name = "Announce Channel",
                        desc = "Channel to announce roll winners.",
                        values = {
                            RAID         = "Raid",
                            PARTY        = "Party",
                            RAID_WARNING = "Raid Warning",
                            SAY          = "Say",
                        },
                        get = function() return ns.db.profile.announceChannel end,
                        set = function(_, v) ns.db.profile.announceChannel = v end,
                        order = 4,
                    },
                    disenchanter = {
                        type = "input",
                        name = "Disenchanter",
                        desc =
                        "Designated disenchanter player (Name-Realm). Used by the Disenchant button in the Reassign popup.",
                        get = function() return ns.db.profile.disenchanter or "" end,
                        set = function(_, v)
                            ns.db.profile.disenchanter = v
                            if ns.Session and ns.Session:IsActive() and ns.IsLeader() then
                                ns.Session:UpdateSessionDisenchanter(v)
                            end
                        end,
                        order = 5,
                        width = "double",
                    },
                    disenchanterTarget = {
                        type = "execute",
                        name = "Copy Target",
                        desc = "Copy your current target's Name-Realm into the Disenchanter field.",
                        order = 6,
                        func = function()
                            local name, realm = UnitName("target")
                            if not name then
                                ns.addon:Print("No target selected.")
                                return
                            end
                            if not realm or realm == "" then
                                realm = GetRealmName():gsub(" ", "")
                            end
                            local fullName = name .. "-" .. realm
                            ns.db.profile.disenchanter = fullName
                            if ns.Session and ns.Session:IsActive() and ns.IsLeader() then
                                ns.Session:UpdateSessionDisenchanter(fullName)
                            end
                            LibStub("AceConfigRegistry-3.0"):NotifyChange(ns.ADDON_NAME)
                        end,
                    },
                    theme = {
                        type = "select",
                        name = "UI Theme",
                        desc = "Visual style for all OLL frames. Applies immediately and is saved per-character.",
                        values = {
                            Basic    = "Basic",
                            Midnight = "Midnight",
                        },
                        sorting = { "Basic", "Midnight" },
                        get = function() return ns.db.profile.theme or "Basic" end,
                        set = function(_, v)
                            if ns.Theme then ns.Theme:Set(v) end
                        end,
                        order = 7,
                    },
                    joinRestrictionsGroup = {
                        type = "group",
                        name = "Join Session Restrictions",
                        inline = true,
                        order = 8,
                        args = {
                            joinRestrictDesc = {
                                type = "description",
                                name = "Only join loot sessions hosted by players who match the selected categories. "
                                    .. "If neither box is checked, you will join any session.",
                                order = 1,
                            },
                            joinFriends = {
                                type = "toggle",
                                name = "Friends",
                                desc = "Only join sessions hosted by players on your friends list.",
                                get = function()
                                    local r = ns.db.profile.joinRestrictions
                                    return r and r.friends or false
                                end,
                                set = function(_, v)
                                    ns.db.profile.joinRestrictions.friends = v
                                end,
                                order = 2,
                            },
                            joinGuild = {
                                type = "toggle",
                                name = "Guild",
                                desc = "Only join sessions hosted by players in your guild.",
                                get = function()
                                    local r = ns.db.profile.joinRestrictions
                                    return r and r.guild or false
                                end,
                                set = function(_, v)
                                    ns.db.profile.joinRestrictions.guild = v
                                end,
                                order = 3,
                            },
                        },
                    },
                    debugSpacer = {
                        type = "description",
                        name = "\n",
                        order = 9,
                    },
                    debugMode = {
                        type = "execute",
                        name = "|cffff4444Debug / Test Mode|r",
                        desc = "Open a debug window to simulate loot drops without affecting loot counts or history.",
                        order = 10,
                        func = function()
                            if ns.DebugWindow then
                                ns.DebugWindow:Show()
                            end
                        end,
                    },
                    checkPartySpacer = {
                        type  = "description",
                        name  = "",
                        order = 11,
                    },
                    checkParty = {
                        type  = "execute",
                        name  = "Check Party",
                        desc  = "Open the Party Check window to see which players have OLL installed and whether their version matches yours.",
                        order = 12,
                        func  = function()
                            if ns.CheckPartyFrame then
                                ns.CheckPartyFrame:Show()
                            end
                        end,
                    },
                },
            },

            ----------------------------------------------------------------
            -- Tab 2: Roll Options
            ----------------------------------------------------------------
            rollOptions = {
                type = "group",
                name = "Roll Options",
                order = 2,
                args = {
                    rollDesc = {
                        type = "description",
                        name = "Configure the roll buttons shown to players.  "
                            .. "Pass is always present and cannot be removed.  "
                            .. "Priority 1 is highest.  Lower priority tiers can "
                            .. "only win if nobody in a higher tier rolled.",
                        order = 1,
                    },
                    rollOptionsList = {
                        type = "group",
                        name = "Current Options",
                        inline = true,
                        order = 2,
                        args = {}, -- populated dynamically
                    },
                    addRollOption = {
                        type = "execute",
                        name = "Add Roll Option",
                        order = 3,
                        func = function()
                            -- Copy to avoid modifying defaults
                            if not ns.db.profile.rollOptions then
                                ns.db.profile.rollOptions = {}
                                for _, o in ipairs(ns.DEFAULT_ROLL_OPTIONS) do
                                    tinsert(ns.db.profile.rollOptions, {
                                        name = o.name,
                                        priority = o.priority,
                                        countsForLoot = o.countsForLoot,
                                        colorR = o.colorR,
                                        colorG = o.colorG,
                                        colorB = o.colorB,
                                    })
                                end
                            end
                            tinsert(ns.db.profile.rollOptions, {
                                name = "New Option",
                                priority = #ns.db.profile.rollOptions + 1,
                                countsForLoot = false,
                                colorR = 0.5,
                                colorG = 0.5,
                                colorB = 0.5,
                            })
                            -- Rebuild and refresh the config UI
                            Settings:OpenConfig("rollOptions")
                        end,
                    },
                },
            },

            ----------------------------------------------------------------
            -- Tab 3: Loot Counts
            ----------------------------------------------------------------
            lootCounts = {
                type = "group",
                name = "Loot Counts",
                order = 3,
                args = {
                    resetAllCounts = {
                        type = "execute",
                        name = "Reset All Loot Counts",
                        confirm = true,
                        confirmText = "Are you sure you want to reset all loot counts?",
                        order = 1,
                        func = function()
                            ns.LootCount:ResetAll()
                            ns.addon:Print("All loot counts have been reset.")
                            Settings:OpenConfig("lootCounts")
                        end,
                    },
                    sortSpacer = {
                        type = "description",
                        name = "\n|cffffd100Sort By:|r",
                        order = 2,
                        fontSize = "medium",
                    },
                    sortByName = {
                        type = "execute",
                        name = function()
                            if Settings._lootCountSortField == "name" then
                                return "Name " .. (Settings._lootCountSortAsc and "▲" or "▼")
                            end
                            return "Name"
                        end,
                        order = 3,
                        func = function()
                            if Settings._lootCountSortField == "name" then
                                Settings._lootCountSortAsc = not Settings._lootCountSortAsc
                            else
                                Settings._lootCountSortField = "name"
                                Settings._lootCountSortAsc = true
                            end
                            Settings:OpenConfig("lootCounts")
                        end,
                        width = 0.6,
                    },
                    sortByCount = {
                        type = "execute",
                        name = function()
                            if Settings._lootCountSortField == "count" then
                                return "Count " .. (Settings._lootCountSortAsc and "▲" or "▼")
                            end
                            return "Count"
                        end,
                        order = 4,
                        func = function()
                            if Settings._lootCountSortField == "count" then
                                Settings._lootCountSortAsc = not Settings._lootCountSortAsc
                            else
                                Settings._lootCountSortField = "count"
                                Settings._lootCountSortAsc = false -- default count to descending
                            end
                            Settings:OpenConfig("lootCounts")
                        end,
                        width = 0.6,
                    },
                    countList = {
                        type = "description",
                        name = function()
                            return Settings:_BuildLootCountDisplay()
                        end,
                        order = 10,
                        fontSize = "medium",
                    },
                },
            },

            ----------------------------------------------------------------
            -- Tab 4: Character Links
            ----------------------------------------------------------------
            characterLinks = {
                type = "group",
                name = "Character Links",
                order = 4,
                args = {
                    desc = {
                        type = "description",
                        name = "Link alt characters to a main so they share a loot count. "
                            .. "Enter names as Name-Realm (e.g. Slarty-Benediction).",
                        order = 1,
                    },
                    mainName = {
                        type = "input",
                        name = "Main Character",
                        desc = "The main character name (Name-Realm).",
                        order = 2,
                        get = function() return Settings._linkMain or "" end,
                        set = function(_, v) Settings._linkMain = v end,
                    },
                    altName = {
                        type = "input",
                        name = "Alt Character",
                        desc = "The alt character to link (Name-Realm).",
                        order = 3,
                        get = function() return Settings._linkAlt or "" end,
                        set = function(_, v) Settings._linkAlt = v end,
                    },
                    linkBtn = {
                        type = "execute",
                        name = "Link Characters",
                        order = 4,
                        func = function()
                            if Settings._linkMain and Settings._linkAlt
                                and Settings._linkMain ~= "" and Settings._linkAlt ~= "" then
                                ns.PlayerLinks:LinkCharacter(Settings._linkMain, Settings._linkAlt)
                                ns.addon:Print("Linked " .. Settings._linkAlt .. " → " .. Settings._linkMain)
                                Settings._linkMain = ""
                                Settings._linkAlt = ""
                            end
                        end,
                    },
                    unlinkName = {
                        type = "input",
                        name = "Unlink Alt",
                        desc = "Enter alt name to unlink (Name-Realm).",
                        order = 5,
                        get = function() return Settings._unlinkAlt or "" end,
                        set = function(_, v) Settings._unlinkAlt = v end,
                    },
                    unlinkBtn = {
                        type = "execute",
                        name = "Unlink",
                        order = 6,
                        func = function()
                            if Settings._unlinkAlt and Settings._unlinkAlt ~= "" then
                                ns.PlayerLinks:UnlinkCharacter(Settings._unlinkAlt)
                                ns.addon:Print("Unlinked " .. Settings._unlinkAlt)
                                Settings._unlinkAlt = ""
                            end
                        end,
                    },
                    currentLinks = {
                        type = "description",
                        name = function()
                            local lines = { "\n|cffffd100Current Links:|r\n" }
                            local mains = ns.PlayerLinks:GetAllMains()
                            if #mains == 0 then
                                tinsert(lines, "  No links configured.")
                            end
                            for _, main in ipairs(mains) do
                                local alts = ns.PlayerLinks:GetAlts(main)
                                local altStr = table.concat(alts, ", ")
                                tinsert(lines, "  " .. main .. " ← " .. altStr)
                            end
                            return table.concat(lines, "\n")
                        end,
                        order = 10,
                        fontSize = "medium",
                    },
                },
            },

            ----------------------------------------------------------------
            -- Tab 5: Loot History
            ----------------------------------------------------------------
            lootHistory = {
                type = "group",
                name = "Loot History",
                order = 5,
                args = {
                    desc = {
                        type = "description",
                        name = "All loot awarded across every session. "
                            .. "History is stored globally and is visible on all characters on this account.",
                        order = 1,
                    },
                    openViewer = {
                        type = "execute",
                        name = "Open History Viewer",
                        desc = "Open the full loot history window with filtering, sorting, and CSV export.",
                        order = 2,
                        func = function()
                            if ns.HistoryFrame then
                                ns.HistoryFrame:Show()
                            end
                        end,
                    },
                    clearHistory = {
                        type = "execute",
                        name = "Clear All History",
                        desc = "Permanently delete all loot history records.",
                        order = 3,
                        confirm = true,
                        confirmText = "Are you sure you want to clear all loot history? This cannot be undone.",
                        func = function()
                            ns.LootHistory:ClearAll()
                            ns.addon:Print("Loot history cleared.")
                            Settings:OpenConfig("lootHistory")
                        end,
                    },
                    sortSpacer = {
                        type = "description",
                        name = "\n|cffffd100Sort By:|r",
                        order = 4,
                        fontSize = "medium",
                    },
                    sortByDate = {
                        type = "execute",
                        name = function()
                            if Settings._histSortField == "timestamp" then
                                return "Date " .. (Settings._histSortAsc and "▲" or "▼")
                            end
                            return "Date"
                        end,
                        order = 5,
                        func = function()
                            if Settings._histSortField == "timestamp" then
                                Settings._histSortAsc = not Settings._histSortAsc
                            else
                                Settings._histSortField = "timestamp"
                                Settings._histSortAsc = false
                            end
                            Settings:OpenConfig("lootHistory")
                        end,
                        width = 0.6,
                    },
                    sortByBoss = {
                        type = "execute",
                        name = function()
                            if Settings._histSortField == "bossName" then
                                return "Boss " .. (Settings._histSortAsc and "▲" or "▼")
                            end
                            return "Boss"
                        end,
                        order = 6,
                        func = function()
                            if Settings._histSortField == "bossName" then
                                Settings._histSortAsc = not Settings._histSortAsc
                            else
                                Settings._histSortField = "bossName"
                                Settings._histSortAsc = true
                            end
                            Settings:OpenConfig("lootHistory")
                        end,
                        width = 0.6,
                    },
                    sortByPlayer = {
                        type = "execute",
                        name = function()
                            if Settings._histSortField == "player" then
                                return "Player " .. (Settings._histSortAsc and "▲" or "▼")
                            end
                            return "Player"
                        end,
                        order = 7,
                        func = function()
                            if Settings._histSortField == "player" then
                                Settings._histSortAsc = not Settings._histSortAsc
                            else
                                Settings._histSortField = "player"
                                Settings._histSortAsc = true
                            end
                            Settings:OpenConfig("lootHistory")
                        end,
                        width = 0.6,
                    },
                    sortByItem = {
                        type = "execute",
                        name = function()
                            if Settings._histSortField == "itemLink" then
                                return "Item " .. (Settings._histSortAsc and "▲" or "▼")
                            end
                            return "Item"
                        end,
                        order = 8,
                        func = function()
                            if Settings._histSortField == "itemLink" then
                                Settings._histSortAsc = not Settings._histSortAsc
                            else
                                Settings._histSortField = "itemLink"
                                Settings._histSortAsc = true
                            end
                            Settings:OpenConfig("lootHistory")
                        end,
                        width = 0.6,
                    },
                    historyList = {
                        type = "description",
                        name = function()
                            return Settings:_BuildLootHistoryDisplay()
                        end,
                        order = 20,
                        fontSize = "medium",
                    },
                },
            },
        },
    }

    -- Dynamically populate roll options list
    self:_PopulateRollOptions(options.args.rollOptions.args.rollOptionsList.args)

    return options
end

------------------------------------------------------------------------
-- Populate roll option sub-entries in the config panel
------------------------------------------------------------------------
function Settings:_PopulateRollOptions(args)
    wipe(args)
    local opts = self:GetRollOptions()
    for i = 1, #opts do
        local key = "opt" .. i
        args[key .. "_name"] = {
            type = "input",
            name = "Name",
            order = i * 10,
            get = function() return self:GetRollOptions()[i].name end,
            set = function(_, v) self:_EnsureCustomOpts()[i].name = v end,
            width = "normal",
        }
        args[key .. "_priority"] = {
            type = "range",
            name = "Priority",
            order = i * 10 + 1,
            min = 1,
            max = 10,
            step = 1,
            get = function() return self:GetRollOptions()[i].priority end,
            set = function(_, v) self:_EnsureCustomOpts()[i].priority = v end,
            width = "half",
        }
        args[key .. "_counts"] = {
            type = "toggle",
            name = "Counts for Loot",
            order = i * 10 + 2,
            get = function() return self:GetRollOptions()[i].countsForLoot end,
            set = function(_, v) self:_EnsureCustomOpts()[i].countsForLoot = v end,
            width = "normal",
        }
        args[key .. "_delete"] = {
            type = "execute",
            name = "Delete",
            order = i * 10 + 3,
            confirm = true,
            func = function()
                table.remove(self:_EnsureCustomOpts(), i)
                -- Rebuild and refresh the config UI
                Settings:OpenConfig("rollOptions")
            end,
            width = "half",
        }
        args[key .. "_spacer"] = {
            type = "description", name = "", order = i * 10 + 4,
        }
    end
end

------------------------------------------------------------------------
-- Ensure we have a mutable copy of roll options
------------------------------------------------------------------------
function Settings:_EnsureCustomOpts()
    if not ns.db.profile.rollOptions then
        ns.db.profile.rollOptions = {}
        for _, o in ipairs(ns.DEFAULT_ROLL_OPTIONS) do
            tinsert(ns.db.profile.rollOptions, {
                name = o.name,
                priority = o.priority,
                countsForLoot = o.countsForLoot,
                colorR = o.colorR,
                colorG = o.colorG,
                colorB = o.colorB,
            })
        end
    end
    return ns.db.profile.rollOptions
end

------------------------------------------------------------------------
-- Build the loot count display string (sorted list)
------------------------------------------------------------------------
function Settings:_BuildLootCountDisplay()
    local counts = ns.db.global.lootCounts or {}
    local entries = {}

    for name, count in pairs(counts) do
        tinsert(entries, { name = name, count = count })
    end

    if #entries == 0 then
        return "\n|cff888888No loot counts recorded.|r"
    end

    local field = self._lootCountSortField or "count"
    local asc   = self._lootCountSortAsc

    table.sort(entries, function(a, b)
        if field == "name" then
            if asc then return a.name < b.name end
            return a.name > b.name
        else -- "count"
            if a.count ~= b.count then
                if asc then return a.count < b.count end
                return a.count > b.count
            end
            return a.name < b.name -- tiebreak: name ascending
        end
    end)

    local lines = { "\n" }
    for _, e in ipairs(entries) do
        tinsert(lines, string.format("  |cffffffff%s|r  —  |cffffd100%d|r", e.name, e.count))
    end
    return table.concat(lines, "\n")
end

------------------------------------------------------------------------
-- Build the loot history display string (sorted list, capped at 200)
------------------------------------------------------------------------
function Settings:_BuildLootHistoryDisplay()
    local history = ns.db.global.lootHistory or {}
    if #history == 0 then
        return "\n|cff888888No loot history recorded.|r"
    end

    local field = self._histSortField or "timestamp"
    local asc   = self._histSortAsc

    -- Sort a shallow copy so we don't mutate the saved variable
    local sorted = {}
    for i = 1, #history do sorted[i] = history[i] end

    table.sort(sorted, function(a, b)
        local av = a[field] or ""
        local bv = b[field] or ""
        if type(av) == "number" and type(bv) == "number" then
            if av ~= bv then
                return asc and av < bv or av > bv
            end
        else
            av = tostring(av):lower()
            bv = tostring(bv):lower()
            if av ~= bv then
                return asc and av < bv or av > bv
            end
        end
        -- tiebreak: most recent first
        return (a.timestamp or 0) > (b.timestamp or 0)
    end)

    local MAX_DISPLAY = 200
    local total       = #sorted
    local truncated   = total > MAX_DISPLAY

    local lines = { "\n" }
    local limit = truncated and MAX_DISPLAY or total
    for i = 1, limit do
        local e        = sorted[i]
        local dateStr  = e.timestamp and tostring(date("%Y-%m-%d %H:%M", e.timestamp)) or "?"
        local bossStr  = e.bossName or "Unknown"
        -- Use the raw item link so WoW renders it as a colored item name
        local itemDisp = e.itemLink or "Unknown"
        local player   = e.player or "?"
        local rollInfo
        if e.rollValue and e.rollValue > 0 then
            rollInfo = string.format("%s (%d)", e.rollType or "?", e.rollValue)
        else
            rollInfo = e.rollType or "?"
        end
        local count = e.lootCountAtWin or 0

        local line = string.format(
            "  |cff888888%s|r  |cffffd100%s|r  —  %s  —  |cffffffff%s|r  %s  |cff888888[%d]|r",
            dateStr, bossStr, itemDisp, player, rollInfo, count
        )
        tinsert(lines, line)
    end

    if truncated then
        tinsert(lines, string.format(
            "\n|cffff8000Showing %d of %d entries. Use the History Viewer for the full list.|r",
            MAX_DISPLAY, total
        ))
    end

    return table.concat(lines, "\n")
end

------------------------------------------------------------------------
-- Register and open
------------------------------------------------------------------------
function Settings:Register()
    local opts = self:BuildOptions()
    ns.AConfig:RegisterOptionsTable(ns.ADDON_NAME, opts)
    ns.ACDiag:SetDefaultSize(ns.ADDON_NAME, 620, 700)
    self.optionsFrame = ns.ACDiag:AddToBlizOptions(ns.ADDON_NAME, ns.ADDON_NAME)
end

function Settings:OpenConfig(group)
    -- Rebuild dynamic entries before showing
    local opts = self:BuildOptions()
    ns.AConfig:RegisterOptionsTable(ns.ADDON_NAME, opts)

    if group then
        ns.ACDiag:SelectGroup(ns.ADDON_NAME, group)
    end
    ns.ACDiag:Open(ns.ADDON_NAME)
end
