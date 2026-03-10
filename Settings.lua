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
Settings._csvExportPopup     = nil  -- lazy-created CSV export popup


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
            -- Tab 1: Player Settings
            ----------------------------------------------------------------
            general = {
                type = "group",
                name = "Player Settings",
                order = 1,
                args = {
                    --------------------------------------------------------
                    -- Player Settings
                    --------------------------------------------------------
                    playerSettingsGroup = {
                        type   = "group",
                        name   = "Player Settings",
                        inline = true,
                        order  = 1,
                        args   = {
                            autoPassBOE = {
                                type = "toggle",
                                name = "Auto-Pass BoE",
                                desc = "Automatically pass on Bind on Equip items.",
                                get  = function() return ns.db.profile.autoPassBOE end,
                                set  = function(_, v) ns.db.profile.autoPassBOE = v end,
                                order = 1,
                            },
                            autoPassOffSpec = {
                                type = "toggle",
                                name = "Auto-Pass Off-Spec Loot",
                                desc = "Automatically pass on items whose primary stat (Strength, Agility, or Intellect) does not match your current specialization.",
                                get  = function() return ns.db.profile.autoPassOffSpec ~= false end,
                                set  = function(_, v) ns.db.profile.autoPassOffSpec = v end,
                                order = 2,
                            },
                            autoPassUnequippable = {
                                type = "toggle",
                                name = "Auto-Pass Unequippable Items",
                                desc = "Automatically pass on items your class cannot use — wrong armor type (e.g. Plate for a Priest) or a weapon type your class cannot equip.",
                                get  = function() return ns.db.profile.autoPassUnequippable == true end,
                                set  = function(_, v) ns.db.profile.autoPassUnequippable = v end,
                                order = 3,
                            },
                            showStatBadge = {
                                type = "toggle",
                                name = "Show Primary Stat Label",
                                desc = "Show the STR / AGI / INT badge on each item in the roll frame.",
                                get  = function() return ns.db.profile.showStatBadge ~= false end,
                                set  = function(_, v) ns.db.profile.showStatBadge = v end,
                                order = 4,
                            },
                            theme = {
                                type   = "select",
                                name   = "UI Theme",
                                desc   = "Visual style for all OLL frames. Applies immediately and is saved per-character.",
                                values = {
                                    Basic    = "Basic",
                                    Midnight = "Midnight",
                                },
                                sorting = { "Basic", "Midnight" },
                                get  = function() return ns.db.profile.theme or "Basic" end,
                                set  = function(_, v)
                                    if ns.Theme then ns.Theme:Set(v) end
                                end,
                                order = 5,
                            },
                            joinRestrictionsGroup = {
                                type   = "group",
                                name   = "Join Session Restrictions",
                                inline = true,
                                order  = 5,
                                args   = {
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
                                        get  = function()
                                            local r = ns.db.profile.joinRestrictions
                                            return r and r.friends or false
                                        end,
                                        set  = function(_, v)
                                            ns.db.profile.joinRestrictions.friends = v
                                        end,
                                        order = 2,
                                    },
                                    joinGuild = {
                                        type = "toggle",
                                        name = "Guild",
                                        desc = "Only join sessions hosted by players in your guild.",
                                        get  = function()
                                            local r = ns.db.profile.joinRestrictions
                                            return r and r.guild or false
                                        end,
                                        set  = function(_, v)
                                            ns.db.profile.joinRestrictions.guild = v
                                        end,
                                        order = 3,
                                    },
                                },
                            },
                            myCharactersGroup = {
                                type   = "group",
                                name   = "My Characters",
                                inline = true,
                                order  = 6,
                                args   = {
                                    -- Line 0: Section description
                                    myCharsDesc = {
                                        type  = "description",
                                        name  = "Add all characters you play here, then select your main. "
                                             .. "When you join a session, your character list is sent to the leader "
                                             .. "so loot is correctly attributed across all your characters.",
                                        order = 0,
                                    },
                                    -- Line 1: Main Character dropdown (full row)
                                    selectMain = {
                                        type   = "select",
                                        name   = "Main Character",
                                        desc   = "Select which character is your main for loot tracking. "
                                              .. "All loot won by any of your characters will be attributed to this character.",
                                        values = function()
                                            local chars = ns.PlayerLinks:GetMyCharacters()
                                            local vals  = {}
                                            for _, name in ipairs(chars) do
                                                vals[name] = name
                                            end
                                            return vals
                                        end,
                                        get    = function() return ns.PlayerLinks:GetMyMain() end,
                                        set    = function(_, v) ns.PlayerLinks:SetMyMain(v) end,
                                        width  = "full",
                                        order  = 1,
                                    },
                                    -- Line 2: Add Character input + Add button
                                    addCharName = {
                                        type  = "input",
                                        name  = "Add Character",
                                        desc  = "Enter a character name in Name-Realm format (e.g. Arthas-Icecrown) and click Add.",
                                        get   = function() return Settings._addCharName or "" end,
                                        set   = function(_, v) Settings._addCharName = v end,
                                        width = "double",
                                        order = 2,
                                    },
                                    addCharBtn = {
                                        type  = "execute",
                                        name  = "Add",
                                        func  = function()
                                            local name = Settings._addCharName
                                            if name and name:trim() ~= "" then
                                                ns.PlayerLinks:AddMyCharacter(name:trim())
                                                Settings._addCharName = ""
                                            end
                                        end,
                                        order = 3,
                                    },
                                    -- Line 3: Remove Character dropdown + Remove button
                                    removeChar = {
                                        type   = "select",
                                        name   = "Remove Character",
                                        desc   = "Select a character to remove from your list.",
                                        values = function()
                                            local chars = ns.PlayerLinks:GetMyCharacters()
                                            local vals  = {}
                                            for _, name in ipairs(chars) do
                                                vals[name] = name
                                            end
                                            return vals
                                        end,
                                        get    = function() return Settings._removeChar end,
                                        set    = function(_, v) Settings._removeChar = v end,
                                        width  = "double",
                                        order  = 4,
                                    },
                                    removeCharBtn = {
                                        type  = "execute",
                                        name  = "Remove",
                                        func  = function()
                                            if Settings._removeChar then
                                                ns.PlayerLinks:RemoveMyCharacter(Settings._removeChar)
                                                Settings._removeChar = nil
                                            end
                                        end,
                                        order = 5,
                                    },
                                },
                            },
                        },
                    },
                    --------------------------------------------------------
                    -- Tools
                    --------------------------------------------------------
                    toolsGroup = {
                        type   = "group",
                        name   = "Tools",
                        inline = true,
                        order  = 3,
                        args   = {
                            debugMode = {
                                type  = "execute",
                                name  = "|cffff4444Debug / Test Mode|r",
                                desc  = "Open a debug window to simulate loot drops without affecting loot counts or history.",
                                order = 1,
                                func  = function()
                                    if ns.DebugWindow then
                                        ns.DebugWindow:Show()
                                    end
                                end,
                            },
                            checkParty = {
                                type  = "execute",
                                name  = "Check Party",
                                desc  = "Open the Party Check window to see which players have OLL installed and whether their version matches yours.",
                                order = 2,
                                func  = function()
                                    if ns.CheckPartyFrame then
                                        ns.CheckPartyFrame:Show()
                                    end
                                end,
                            },
                            openHistoryViewer = {
                                type  = "execute",
                                name  = "Open History Viewer",
                                desc  = "Open the full loot history window with filtering, sorting, and CSV export.",
                                order = 3,
                                func  = function()
                                    if ns.HistoryFrame then
                                        ns.HistoryFrame:Show()
                                    end
                                end,
                            },
                            openSessionHistory = {
                                type  = "execute",
                                name  = "Session History",
                                desc  = "Open the session history window to browse past loot sessions by date and boss.",
                                order = 4,
                                func  = function()
                                    if ns.SessionHistoryFrame then
                                        ns.SessionHistoryFrame:Show()
                                    end
                                end,
                            },
                        },
                    },
                },
            },

            ----------------------------------------------------------------
            -- Tab 2: Session Settings
            ----------------------------------------------------------------
            sessionSettings = {
                type = "group",
                name = "Session Settings",
                order = 2,
                args = {
                    sessionSettingsGroup = {
                        type   = "group",
                        name   = "Session Settings",
                        inline = true,
                        order  = 1,
                        args   = {
                            lootThreshold = {
                                type   = "select",
                                name   = "Loot Threshold",
                                desc   = "Minimum item quality to trigger roll window.",
                                values = {
                                    [2] = "|cff1eff00Uncommon|r",
                                    [3] = "|cff0070ddRare|r",
                                    [4] = "|cffa335eeEpic|r",
                                    [5] = "|cffff8000Legendary|r",
                                },
                                get  = function() return ns.db.profile.lootThreshold end,
                                set  = function(_, v) ns.db.profile.lootThreshold = v end,
                                order = 1,
                            },
                            rollTimer = {
                                type = "range",
                                name = "Roll Timer (seconds)",
                                desc = "Time players have to respond to a roll.",
                                min  = 10,
                                max  = 300,
                                step = 5,
                                get  = function() return ns.db.profile.rollTimer end,
                                set  = function(_, v) ns.db.profile.rollTimer = v end,
                                order = 2,
                            },
                            announceChannel = {
                                type   = "select",
                                name   = "Announce Channel",
                                desc   = "Channel to announce roll winners.",
                                values = {
                                    RAID         = "Raid",
                                    PARTY        = "Party",
                                    RAID_WARNING = "Raid Warning",
                                    SAY          = "Say",
                                },
                                get  = function() return ns.db.profile.announceChannel end,
                                set  = function(_, v) ns.db.profile.announceChannel = v end,
                                order = 3,
                            },
                            disenchanterGroup = {
                                type   = "group",
                                name   = "Target Disenchanter",
                                inline = true,
                                order  = 4,
                                args   = {
                                    disenchanterDesc = {
                                        type = "description",
                                        name = "The designated player who receives items that all players passed on. "
                                            .. "They will appear as an option in the Reassign popup when resolving loot. "
                                            .. "Leave blank to skip disenchanter logic.",
                                        order = 0,
                                    },
                                    disenchanter = {
                                        type  = "input",
                                        name  = "Disenchanter",
                                        desc  = "Designated disenchanter player (Name-Realm). Used by the Disenchant button in the Reassign popup.",
                                        get   = function() return ns.db.profile.disenchanter or "" end,
                                        set   = function(_, v)
                                            ns.db.profile.disenchanter = v
                                            if ns.Session and ns.Session:IsActive() and ns.IsLeader() then
                                                ns.Session:UpdateSessionDisenchanter(v)
                                            end
                                        end,
                                        order = 1,
                                        width = "normal",
                                    },
                                    disenchanterTarget = {
                                        type  = "execute",
                                        name  = "Copy Target",
                                        desc  = "Copy your current target's Name-Realm into the Disenchanter field.",
                                        order = 2,
                                        func  = function()
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
                                        width = "normal",
                                    },
                                },
                            },
                            lootCountGroup = {
                                type   = "group",
                                name   = "Loot Count Settings",
                                inline = true,
                                order  = 5,
                                args   = {
                                    lootCountGroupDesc = {
                                        type  = "description",
                                        name  = "Controls how loot counts are tracked for players. Counts can be shared across a player's linked characters (consolidated to their main), or tracked individually per character. Cannot be changed during an active session.",
                                        order = 0,
                                        width = "full",
                                    },
                                    lootCountEnabled = {
                                        type = "toggle",
                                        name = function()
                                            return ns.db.profile.lootCountEnabled ~= false and "Enabled" or "Disabled"
                                        end,
                                        desc     = "Enable or disable the loot count tracking system. Cannot be changed during an active session.",
                                        get      = function() return ns.db.profile.lootCountEnabled ~= false end,
                                        set      = function(_, v) ns.db.profile.lootCountEnabled = v end,
                                        disabled = function() return ns.Session and ns.Session:IsActive() end,
                                        order    = 1,
                                    },
                                    lootCountMode = {
                                        type    = "select",
                                        name    = "Count Attribution",
                                        desc    = "Determines how loot counts are attributed when a player has linked characters. 'Shared (Linked Characters)' consolidates all counts to the player's main — alts share the same count pool. 'Per Character' tracks each character independently, regardless of any links.",
                                        values  = {
                                            lockedToMain = "Shared (Linked Characters)",
                                            perCharacter = "Per Character",
                                        },
                                        sorting  = { "lockedToMain", "perCharacter" },
                                        get      = function()
                                            return ns.db.profile.lootCountLockedToMain ~= false and "lockedToMain" or "perCharacter"
                                        end,
                                        set      = function(_, v)
                                            ns.db.profile.lootCountLockedToMain = (v == "lockedToMain")
                                        end,
                                        hidden   = function() return ns.db.profile.lootCountEnabled == false end,
                                        disabled = function() return ns.Session and ns.Session:IsActive() end,
                                        order    = 2,
                                        width    = "normal",
                                    },
                                    resetScheduleGroup = {
                                        type   = "group",
                                        name   = "Reset Schedule",
                                        inline = true,
                                        order  = 3,
                                        hidden = function() return ns.db.profile.lootCountEnabled == false end,
                                        args   = {
                                            resetScheduleDesc = {
                                                type  = "description",
                                                name  = "Select when the loot count should be reset for the group.",
                                                order = 0,
                                                width = "full",
                                            },
                                            resetSchedule = {
                                                type    = "select",
                                                name    = "Reset Day",
                                                values  = {
                                                    weekly  = "Weekly, Tuesday 8am PT",
                                                    monthly = "Monthly, 1st at 8am PT",
                                                    manual  = "Manual",
                                                },
                                                sorting = { "weekly", "monthly", "manual" },
                                                get     = function() return ns.db.profile.resetSchedule or "weekly" end,
                                                set     = function(_, v) ns.db.profile.resetSchedule = v end,
                                                order   = 1,
                                                width   = "normal",
                                            },
                                            resetScheduleSelectionDesc = {
                                                type  = "description",
                                                name  = function()
                                                    local v = ns.db.profile.resetSchedule or "weekly"
                                                    if v == "monthly" then
                                                        return "Resets on the 1st of the month at 8am PT, even if that isn't a Tuesday."
                                                    elseif v == "manual" then
                                                        return "Disables automatic loot count reset."
                                                    else
                                                        return "Resets every week on Tuesday at 8am PT. This is the normal weekly reset time for raids."
                                                    end
                                                end,
                                                order = 2,
                                                width = "double",
                                            },
                                        },
                                    },
                                },
                            },
                            lootMasterRestrictionGroup = {
                                type   = "group",
                                name   = "Loot Master",
                                inline = true,
                                order  = 6,
                                args   = {
                                    lootMasterRestrictionDesc = {
                                        type  = "description",
                                        name  = "Controls who is allowed to trigger a Manual Roll or stop a roll in progress. "
                                            .. "\"Only Loot Master\" restricts these actions to the designated loot master. "
                                            .. "\"Any Leader/Assist\" allows any raid leader or raid assist to perform them.",
                                        order = 1,
                                    },
                                    lootMasterRestriction = {
                                        type    = "select",
                                        name    = "Who Can Manage Rolls",
                                        desc    = "Restrict who can trigger Manual Rolls and stop rolls in progress.",
                                        values  = {
                                            anyLeader      = "Any Leader/Assist",
                                            onlyLootMaster = "Only Loot Master",
                                        },
                                        sorting = { "anyLeader", "onlyLootMaster" },
                                        get     = function()
                                            return ns.db.profile.lootMasterRestriction or "anyLeader"
                                        end,
                                        set     = function(_, v)
                                            ns.db.profile.lootMasterRestriction = v
                                            if ns.Session and ns.Session:IsActive() and ns.IsLeader() then
                                                ns.Session:UpdateSessionLootMasterRestriction(v)
                                            end
                                        end,
                                        order = 2,
                                    },
                                },
                            },
                        },
                    },
                },
            },

            ----------------------------------------------------------------
            -- Tab 3: Roll Options
            ----------------------------------------------------------------
            rollOptions = {
                type = "group",
                name = "Roll Options",
                order = 3,
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
            -- Tab 4: Loot Counts
            ----------------------------------------------------------------
            lootCounts = {
                type = "group",
                name = "Loot Counts",
                order = 4,
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
                            if ns.Session and ns.Session:IsActive() and ns.IsLeader() then
                                ns.Comm:Send(ns.Comm.MSG.COUNT_SYNC,
                                    { counts = ns.LootCount:GetCountsTable() })
                            end
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
                                return "Name " .. (Settings._lootCountSortAsc and "^" or "v")
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
                                return "Count " .. (Settings._lootCountSortAsc and "^" or "v")
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
                    exportToCSV = {
                        type = "execute",
                        name = "Export to CSV",
                        order = 6,
                        func = function()
                            Settings:_ShowExportCSVPopup()
                        end,
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
            -- Tab 5: Character Links
            ----------------------------------------------------------------
            characterLinks = {
                type = "group",
                name = "Character Links",
                order = 5,
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
                                local filtered = {}
                                for _, alt in ipairs(alts) do
                                    if alt ~= main then
                                        tinsert(filtered, alt)
                                    end
                                end
                                if #filtered > 0 then
                                    tinsert(lines, "  " .. main .. " <- " .. table.concat(filtered, ", "))
                                end
                            end
                            return table.concat(lines, "\n")
                        end,
                        order = 10,
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
-- Build CSV string from current loot counts (same sort as display)
------------------------------------------------------------------------
function Settings:_BuildLootCountCSV()
    local counts = ns.db.global.lootCounts or {}
    local entries = {}

    for name, count in pairs(counts) do
        tinsert(entries, { name = name, count = count })
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
            return a.name < b.name
        end
    end)

    local lines = { "Player name,Loot count" }
    for _, e in ipairs(entries) do
        tinsert(lines, string.format("%s,%d", e.name, e.count))
    end
    return table.concat(lines, "\n")
end

------------------------------------------------------------------------
-- Show (or reuse) the CSV export popup
------------------------------------------------------------------------
function Settings:_ShowExportCSVPopup()
    if not self._csvExportPopup then
        local theme = ns.Theme:GetCurrent()

        local popup = CreateFrame("Frame", "OLLExportCSVPopup", UIParent, "BackdropTemplate")
        popup:SetSize(440, 340)
        popup:SetPoint("CENTER")
        popup:SetBackdrop({
            bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        popup:SetBackdropColor(unpack(theme.frameBgColor))
        popup:SetBackdropBorderColor(unpack(theme.frameBorderColor))
        popup:SetMovable(true)
        popup:EnableMouse(true)
        popup:RegisterForDrag("LeftButton")
        popup:SetScript("OnDragStart", popup.StartMoving)
        popup:SetScript("OnDragStop", popup.StopMovingOrSizing)
        popup:SetFrameStrata("DIALOG")
        popup:SetClampedToScreen(true)
        popup:SetScript("OnMouseDown", function(f) ns.RaiseFrame(f) end)

        local closeBtn = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -4, -4)
        closeBtn:SetScript("OnClick", function() popup:Hide() end)

        local title = popup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", popup, "TOP", 0, -12)
        title:SetText("Export Loot Counts — CSV")

        local hint = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        hint:SetPoint("TOP", title, "BOTTOM", 0, -4)
        hint:SetText("Ctrl+A  then  Ctrl+C  to copy")
        hint:SetTextColor(0.65, 0.65, 0.65)

        local div = popup:CreateTexture(nil, "ARTWORK")
        div:SetColorTexture(0.4, 0.4, 0.4, 0.5)
        div:SetHeight(1)
        div:SetPoint("TOPLEFT",  popup, "TOPLEFT",  8, -52)
        div:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -8, -52)

        local scroll = CreateFrame("ScrollFrame", nil, popup, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT",     popup, "TOPLEFT",     10, -60)
        scroll:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -30, 10)

        local editBox = CreateFrame("EditBox", "OLLExportCSVEditBox", scroll)
        editBox:SetWidth(scroll:GetWidth() > 0 and scroll:GetWidth() or 380)
        editBox:SetHeight(2000)
        editBox:SetMultiLine(true)
        editBox:SetAutoFocus(false)
        editBox:SetFontObject(GameFontHighlightSmall)
        editBox:SetMaxLetters(0)
        editBox:SetScript("OnEscapePressed", function() popup:Hide() end)
        scroll:SetScrollChild(editBox)
        popup.editBox = editBox

        self._csvExportPopup = popup
    end

    local csv = self:_BuildLootCountCSV()
    self._csvExportPopup.editBox:SetText(csv)
    self._csvExportPopup.editBox:SetFocus()
    self._csvExportPopup.editBox:SetCursorPosition(0)
    self._csvExportPopup.editBox:HighlightText()
    self._csvExportPopup:Show()
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

    -- If the Blizzard settings panel is open, refresh the embedded panel
    -- instead of opening the standalone window
    local blizWidget = ns.ACDiag.BlizOptions
        and ns.ACDiag.BlizOptions[ns.ADDON_NAME]
        and ns.ACDiag.BlizOptions[ns.ADDON_NAME][ns.ADDON_NAME]
    if blizWidget and SettingsPanel and SettingsPanel:IsShown() then
        ns.ACDiag:Open(ns.ADDON_NAME, blizWidget)
    else
        if group then
            ns.ACDiag:SelectGroup(ns.ADDON_NAME, group)
        end
        ns.ACDiag:Open(ns.ADDON_NAME)
    end
end
