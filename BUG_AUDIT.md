# OrderedLootList Bug Audit (2026-09-02)

Full static review of every non-library Lua file on branch `dev/v1.2.x` (commit 4ea6151). No in-game testing was performed; "Confirmed" means the defect is provable from the code alone, "Suspected" means it depends on WoW runtime behaviour that should be verified in-game.

Severity: **High** = breaks core loot flow or corrupts data. **Medium** = wrong behaviour in a realistic scenario. **Low** = cosmetic, dead code, docs.

---

## High

### H1. Late-join handler crashes: `ns.Session.STATE.ACTIVE` does not exist
- `Session.lua:628` — `self.state = ns.Session.STATE.ACTIVE`. The constants are `Session.STATE_ACTIVE`, etc.; `Session.STATE` is nil, so every `SESSION_JOIN` whisper throws "attempt to index a nil value" on the receiving client. Anyone who joins the raid after the session starts (or receives the storm in H6) never joins the session.
- Confirmed.

### H2. `BroadcastRollResult` called with shifted arguments (all-pass / disenchant path)
- `Session.lua:1703` — `ns.Comm:BroadcastRollResult(itemIdx, recipient, 0, rollType, histEntry)`. Signature is `(itemIdx, winner, roll, tiebreakerRoll, choice, entry)` (`Comm.lua:390`). Members receive `tiebreakerRoll = "Passed"`, `choice = <history table>`, `entry = nil`.
- Effect on members: `UI/RollFrame.lua:811` and `UI/LargeRollFrame.lua:838` concatenate `result.choice` (a table) → Lua error; no history entry is written for passed/disenchanted items on member clients.
- Confirmed.

### H3. `BroadcastRollResult` called with shifted arguments (reassign path)
- `Session.lua:2050` — `ns.Comm:BroadcastRollResult(itemIdx, newWinner, result.roll, result.choice, newCount)`. Members get `tiebreakerRoll = choice`, `choice = newCount` (a number), `entry = nil`. Member history entries are never updated to the new winner (only counts are re-synced).
- Confirmed.

### H4. Leader processes its own group broadcasts (no self-echo filter)
- WoW delivers RAID/PARTY addon messages back to the sender. `Comm.lua:100` `OnMessageReceived` never checks `sender == me`. The code *relies* on the echo in some places (`Session.lua:1136` for ROLL_RESPONSE; `Comm.lua:357` → `LargeRollFrame:ApplyChoiceDelta` is only fed via echo; `Session.lua:2454` has an explicit echo guard for TAKEOVER) but not others. Consequences on the leader's client:
  - **ROLL_RESULT echo** (`Session.lua:2085-2161`): `results[itemIdx]` is overwritten (loses `newCount`, `_countedForLoot`), `LootCount:IncrementCount(winner)` runs a **second** time (2137), `LootHistory:AddEntry(payload.entry)` writes a **duplicate history row** (2146), and `_SaveBossHistory()` runs again creating "Boss (2)" (2158). Leader's loot counts drift +1 per win and are then pushed to everyone at next session start.
  - **LOOT_TABLE echo** (`Session.lua:995-1034`): wipes `responses`/`results`, re-runs `CanLootUnit` against the leader (who may have already looted the corpse → possible self-lockout auto-pass), and calls `StartAllRolls()` again, restarting the timer and tick broadcaster.
  - **SESSION_START / SESSION_RESUME echo** (`Session.lua:538-618`, `2341-2416`): full state reset on the leader right after starting; for resume, `currentItems = {}` (2363) discards the pendingRoll restored at 2293-2307 so "Start Roll" then reports "No items to roll on".
  - **SESSION_END echo**: prints "Loot session ended by leader." a second time.
- Fix must add a sender-is-me guard while explicitly routing ROLL_RESPONSE, CHOICES_UPDATE and TIMER_TICK to the local handlers.
- Confirmed (echo behaviour is standard WoW; code comments acknowledge it).

### H5. Member timer display freezes after the first roll of a session
- `Comm.lua:341-351` — stale-tick filter drops any tick where `remaining > _lastTimerRemaining + 0.5`. `_lastTimerRemaining` is only reset on SESSION_START/SESSION_JOIN (`Comm.lua:184, 335`), never on a new LOOT_TABLE. Second roll starts at 30 > ~0 → every tick discarded for the rest of the session.
- Confirmed.

### H6. Whisper storm on the first roster event after session start
- `Session.lua:2623-2637` — `_lastGroupSnapshot` is nil after `_ExecuteStartFresh`/`ResumeSession`, so the first `GROUP_ROSTER_UPDATE` (fires on any roster/role/ready-check change) whispers `SESSION_JOIN` to **every** member. Each member (if H1 didn't crash them) rebroadcasts `PLAYER_CHAR_LIST` with `wantResponse`, and every other member whispers back (`Comm.lua:326-331`): O(N²) whispers in a raid, throttled by ChatThrottleLib for a long time. Matches the "comm overload" history in git log.
- Confirmed.

### H7. Two independent loot-capture paths with different "who is the leader" rules
- `LootHandler.lua:53-63` (`LOOT_READY` → `LeaderHandleLoot`) gates on `ns.IsLeader()` = raid leader **or any assistant**, ignoring `Session.sessionLootMaster`. `LootHandler.lua:225-296` (`START_LOOT_ROLL`) correctly gates on `sessionLootMaster`.
- Any assistant who opens a corpse while a session is active loots every slot, captures items, and `Session:OnItemsCaptured` (whose only guard is `state == ACTIVE`, true on every client) starts a roll on **their** client: LeaderFrame shown, LOOT_TABLE broadcast (members drop it via `_IsTrustedSender`, but the assistant's client is now ROLLING with its own timer and out of sync).
- When the LM loots the corpse both paths fire; the second `OnItemsCaptured` is only dropped because state is no longer ACTIVE. Fragile.
- Confirmed.

### H8. "Re-roll" button restarts the whole boss roll
- `UI/LeaderFrame.lua:839-843` clears one item's responses/result then calls `Session:StartAllRolls()`, which resets `responses[idx] = {}` for **every** item (`Session.lua:1066-1068`), re-shows the roll frame for all items on every client, and restarts the shared timer. Already-resolved items keep their result but lose their recorded responses.
- Confirmed.

### H9. Members silently auto-pass off-stat items (found during H8 fix)
- `Core.lua:65` defaults `autoPassOffSpec = true`; the startup "migration" at `Core.lua:147-154` only assigns when the value is nil, which never happens with AceDB defaults, so it is dead code (see L1). `UI/RollFrame.lua:449`, `UI/SmallRollFrame.lua:198`, `UI/LargeRollFrame.lua:398` all run `if ns.db.profile.autoPassOffSpec ~= false` and auto-submit "Pass" for any item whose primary stat differs from the player's spec. The Settings toggle is disabled, so players cannot turn it off. Likely a major contributor to the "members auto-passed" symptom. Decision needed: remove the auto-pass code entirely (per commit f37a016 "removing autopass logic") or set the default to false and re-enable the toggle. Confirmed.

---

## Medium

### M1. `IsGroupLeaderOrOfficer` wrong in 5-man parties
- `Session.lua:110-112` only checks `party1`. A party leader in slot 2-4 (or the local player) fails the check; `OnSessionResumeReceived` (2343) and `OnSessionTakeoverReceived` (2448) then silently drop the message. Solo returns true. Confirmed.

### M2. Non-boss loot GUIDs sent as `bossGUIDs` → members wrongly locked out
- `LootHandler.lua:96-105` back-fills `_encounterBossGUIDs` from `GetLootSourceInfo` whenever it is empty, including trash mobs/chests. Members then run `CanLootUnit(guid)` (`Session.lua:1018-1027`) on a mob they have no loot rights to and are auto-passed on everything. Suspected (depends on `CanLootUnit` semantics; verify in-game).

### M3. Trade automation compares raw hyperlinks
- `LootHandler.lua:395, 457` use `info.hyperlink == itemLink`. Loot-window links and bag links commonly differ in the level/spec fields of the link, so auto-placing in the trade window can fail, and `_IsItemInBags` returns false → `OnTradeClosed` marks the entry awarded even if the trade was cancelled. Should compare item ID + bonus IDs. Suspected.

### M4. Non-gear boss drops never reach the OLL roll
- `LootHandler.lua:164-185` `IsGearItem` accepts only Armor/Weapon. Tier tokens (class Miscellaneous), mounts, pets, recipes are excluded. Meanwhile `LootHandler.lua:283-294` makes every non-LM auto-**pass** the WoW roll on every item and the LM auto-Need, so the LM simply keeps all such items with no OLL roll and no history. Design decision needed (see questions).

### M5. Cinematic mid-roll awards everything to the leader
- `Session.lua:2524-2527` calls `StopRoll()` on `CINEMATIC_START`; `StopRoll` forces all responses to Pass and resolves, writing "Passed → leader" rows to history and the trade queue. Items are not re-rolled after the cinematic (`_pendingCapturedItems` only covers items captured *during* it). Confirmed.

### M6. Sessions cannot be recovered after leader /reload or disconnect
- Session state lives only in memory (except `pendingRoll`). A record whose `endTime` is nil is excluded from `_GetResumableSessions` (`Session.lua:2220`), so a session interrupted by reload/dc can never be resumed and stays open forever. Force-restarting (`Session.lua:193-209`) also orphans the previous open record. Confirmed.

### M7. Raid assistants act as leader for ACK / CHOICES_UPDATE
- `Session.lua:1169, 1192, 1385` use `ns.IsLeader()`. Every assistant ACKs every ROLL_RESPONSE (cancelling the member's retry even if the real leader missed it) and broadcasts CHOICES_UPDATE (members filter by leaderName, but traffic scales with #assistants). Confirmed.

### M8. Retried/duplicate ROLL_RESPONSE re-rolls the random number
- `Session.lua:1182-1186` overwrites the response with a fresh `math.random` on every receipt. A network retry (`_StartRollResponseAckTimer`) or double-click changes a roll that CHOICES_UPDATE already displayed. Confirmed.

### M9. Loot-count reset time computed in local time, not UTC
- `LootCount.lua:185-193, 205, 216` pass UTC date components to `time{}` which interprets them as local time; the reset fires late by the client's UTC offset. `Core.lua:569` also hard-codes the NA reset (Tuesday 15:00 UTC); EU is Wednesday 04:00 UTC. Confirmed.

### M10. Session deletion only propagates while a session is active
- `UI/SessionHistoryFrame.lua:743` guards the SESSION_DELETE broadcast on `state ~= IDLE`; deletions are almost always done while idle, so members keep the record and its loot rows. Confirmed.

### M11. LeaderFrame leaks UI objects
- `UI/LeaderFrame.lua:605-668, 730-813` create new FontStrings/Textures on every `Refresh()` (called on every roll response). `ShowReassignPopup` (2013) creates a new named frame each click. `Hide()`/`Reset()` (2651-2671) never hide `_reassignPopup`. Confirmed.

### M12. `GetGroupLeaders` returns only the local player in a party
- `UI/LeaderFrame.lua:1469-1493` — non-raid branch ignores party members, so the Assign Loot Master popup can't list them. Confirmed.

### M13. Roll frames reopen empty after combat
- `UI/RollFrame.lua:965-1015`, `UI/SmallRollFrame.lua:464-491`, `UI/LargeRollFrame.lua:1248-1279` set `_hiddenForCombat` on `PLAYER_REGEN_DISABLED` and re-show on `PLAYER_REGEN_ENABLED`; `Hide()`/`Reset()` never clear the flag, so a roll that ends during combat pops an empty frame afterwards. Confirmed.

### M14. History export creates a new dialog frame on every click
- `UI/HistoryFrame.lua:527-578`. Confirmed.

### M15. LargeRollFrame layout defects
- `UI/LargeRollFrame.lua:829-869` result label shown without hiding "You chose" label → overlap. Lines 15-30/106/258-269: fixed 400px right panel with columns at x=180/290/360 but frame can shrink to 500px total with no horizontal scroll → Roll/Count columns unreachable. Confirmed.

### M16. `lootCountAtWin` can go negative when loot counting is disabled
- `Session.lua:1624` and `2044` subtract 1 whenever the option `countsForLoot`, even if `IsLootCountEnabled()` is false and no increment happened. Confirmed.

### M17. Stale session state carried into a new session
- `Session.lua:246-322` `_ExecuteStartFresh` does not clear `sessionSettings`, `_lockedOutOfCurrentBoss`, `_rollEligiblePlayers`, `_lastTimerRemaining` (in Comm). `StartAllRolls` (1077) prefers `sessionSettings.rollTimer`, so a leader who was previously a member uses the old leader's timer. Currently masked by the SESSION_START echo (H4); will surface once H4 is fixed. Confirmed.

### M18. Player link merging edge cases and trust
- `PlayerLinks.lua:264-273` — when a player switches main from A to B, `LinkCharacter(B, A)` adds B to its own alt list. `MergePlayerCharList` (414) is applied for any group member's PLAYER_CHAR_LIST with no validation, so any peer can relink other players' characters and thereby merge/split loot counts. Confirmed.

### M19. Solo/debug sends go to `WHISPER` with a nil target
- `Core.lua:291-298` returns "WHISPER" when solo and `Comm.lua:93` sends with no target. Every broadcast while solo (TIMER_TICK each second, SESSION_START, LOOT_TABLE in debug) is a malformed send; depending on client version this is a silent failure or a Lua error. Suspected.

### M20. Ready-check retry spams players without the addon
- `Session.lua:907-930` re-whispers LOOT_TABLE_READY_CHECK every second to every un-acked player for the whole roll. Players without OLL never ack → N whispers/second for 30 s per roll. Confirmed.

### M21. CI prerelease flag uses branch name on manual dispatch
- `.github/workflows/package_addon.yaml:52-65` — `prerelease:` checks `github.ref_name` (the branch, e.g. `dev/v1.2.x`) rather than the entered version. Confirmed.

---

### M22. Non-leader loot master has no `activeSessionId` (found during H7 fix)
- Members never receive the session id in `SESSION_START` (only in `SESSION_RESUME`/`SESSION_JOIN` payloads via `sessionId`), so when the loot master is not the session leader, `OnItemsCaptured` cannot append bosses to the session record and `_GetSessionSnapshot` returns nil, skipping `SESSION_SYNC`. Fix: include `sessionId` in `SESSION_START` and store it on members. Confirmed.

### M23. Duplicate identical wins share one bag check (found during M3 fix)
- `LootHandler:OnTradeClosed` marks an entry awarded when no matching item remains in bags. If one player wins two copies of the same item, trading one copy still leaves a match in bags, so neither is marked awarded; trading both marks both at once. Needs a count of matching bag items vs. un-awarded queue entries. Low impact. Confirmed.

## Low

- **L1.** `Core.lua:147-154` "force auto-pass off" migration is dead (AceDB never returns nil for defaulted keys); `Settings.lua:290-346` still shows the four auto-pass toggles permanently disabled. Leftover from commit f37a016.
- **L2.** `Settings.lua:66-225` duplicate `order` values (theme/joinRestrictions = 5, lootFrameSize/myCharacters = 6) → unstable widget order.
- **L3.** `UI/RollFrame.lua:120` Priest proficiency table includes 1H Sword (index 7).
- **L4.** `Comm.MSG.HISTORY_SYNC` handler exists but nothing ever sends it; `LootHistory:SetHistoryTable` would wipe a member's own history if it did.
- **L5.** `Session.lua:2153-2160` member with empty `currentItems` (missed LOOT_TABLE) treats every ROLL_RESULT as "all resolved" and saves a spurious boss-history entry each time.
- **L6.** `Core.lua:355-357` `RestoreFramePosition` applies saved width/height to frames that were never resizable.
- **L7.** `Session.lua:2561` `OnCinematicStop` re-calls `OnItemsCaptured` without the `bossGUIDs` argument (lockout check disabled for that roll).
- **L8.** `UI/SmallRollFrame.lua` has no boss-history dropdown / count display; medium `RollFrame:ShowAllItems` never calls `ns.RaiseFrame` unlike small/large.
- **L9.** `Settings.lua:1228` CSV editbox width measured before layout (always 380). `UI/CheckPartyFrame.lua:365` dead `or ""` fallback.
- **L10.** Docs: `CLAUDE.md` says interface 120001 / The War Within; TOC is `120005 120001` (Midnight). `CLAUDE.md` says the packager pulls Ace3 externals; `.pkgmeta` has no `externals:` — libs are committed in `Libs/`.
- **L12.** `autoPassBOE` and `holdWMode` have no consumer: nothing reads `autoPassBOE`, and `Session.lua` `_ShowHoldWModeSessionPopup` is defined but never called, while no roll frame checks `holdWMode`. Their Settings toggles are hidden by the H9 fix until the features are implemented (found during H9 fix).
- **L11.** `Session.lua:1145` uses `ns.IsLeader()` to decide whether to wait for an ACK; a raid assistant who is a plain member never retries lost responses.

---

## Decisions (2026-09-02, confirmed with maintainer)

- **Loot method:** Group Loot only. No Personal Loot support.
- **Leader rule:** the session loot master is the single authority for capturing loot, ACKing responses, broadcasting CHOICES_UPDATE and resolving. Fallback is the session leader. `ns.IsLeader()` (raid leader/assistant) is no longer used for any of these paths. Resolves H7, M7, L11.
- **Non-gear drops (M4):** tier tokens and recipes go through the OLL roll. Add two profile settings, both default **false**: "tokens count toward loot count" and "recipes count toward loot count". Mounts, pets and other items stay with the LM and are handled manually.
- **Cinematic mid-roll (M5):** cancel the roll without awarding anything, re-queue the items, restart the roll on CINEMATIC_STOP.
- **Leader /reload or disconnect (M6):** persist active session state (session id, settings, current roll, trade queue) to SavedVariables and offer resume on login.
- **Loot-count reset (M9):** add a region setting, NA (Tue 15:00 UTC) or EU (Wed 04:00 UTC), and compute in UTC.
- **Auto-pass (H9 / L1):** keep the auto-pass features but default every toggle (`autoPassBOE`, `autoPassOffSpec`, `autoPassUnequippable`, `holdWMode`) to **false**, add a real one-time migration that forces existing profiles to false, and re-enable the Settings toggles so players can opt in.
- **Boss lockout check (M2):** only GUIDs captured at `ENCOUNTER_START` (or recovered at login mid-encounter) are sent as `bossGUIDs`; the `LOOT_READY` back-fill is removed and GUIDs are cleared once consumed by a roll. Trash/chest rolls carry no GUIDs, so members get the benefit of the doubt.
- **Symptoms seen in the last raid:** Lua errors on members; rolls never started / members auto-passed; comm flood / frozen timer; trade queue / auto-trade failed. These map to H1/H2, M2/H7, H5/H6 and M3.

## Fix order (agreed)

1. H1, H2, H3 (one-line signature/constant fixes; unblock members).
2. H4 + H5 + M17 together (comm echo filter with local routing for ROLL_RESPONSE / CHOICES_UPDATE / TIMER_TICK, per-roll state reset).
3. H6 + M20 (comm volume).
4. H7 + M7 + L11 (single "am I the loot master" predicate used everywhere).
5. M3 trade queue (compare item ID + bonus IDs, not raw hyperlink); verify in-game.
6. H8, M1, M2, M12 and remaining Medium items.
7. New features from the decisions above: token/recipe settings, cinematic re-roll, session persistence, NA/EU reset.
8. Low items.

Work happens on `dev/v1.2.x` in small reviewable commits, bugs before features.

## Status (as of 2026-09-02)

All items below were fixed in PRs into `dev/v1.2.x`; none have been verified in-game yet — each PR carries a manual test plan.

| PR | Items |
|---|---|
| #6 | H1, H2, H3 |
| #7 | H4, H5, M17 |
| #8 | H6, M20 |
| #9 | H7, M7, L11 |
| #10 | M3 |
| #11 | H8, M22 |
| #12 | H9, L1 |
| #13 | M1, M12 |
| #14 | M2 |
| #15 | M8, M10, M16, M19 |
| #16 | M11, M13, M14, M15 |
| #17 | M4 (tokens/recipes + count settings) |
| #18 | M5 (cinematic pause/resume) |
| #19 | M9 (NA/EU reset, UTC) |
| #20 | M6 (session persistence) |
| #21 | M18, M21, M23 |
| this PR | L2, L3, L4, L5, L6, L7, L8 (medium-frame raise), L9, L10 (docs) |

**Loot-master reload gap** closed 2026-09-03: `Session:_PersistAuthorityRoll` mirrors a non-leader loot master's roll into `global.authorityRoll`; `SESSION_REQUEST` on login makes the leader whisper `SESSION_JOIN` to any reloading member; `_MaybeRestoreAuthorityRoll` re-opens the roll via the shared `_ReopenUnresolvedRoll` (also used by the leader restore). **L8** implemented 2026-09-03: Small roll frame footer boss name is a menu button (`SmallRollFrame:_OpenHistoryMenu` / `ShowBossHistory`, locked while rolling like Medium/Large); the gear count was already in the footer. **L12** implemented 2026-09-03: BoE rule in `RF_AutoPassScan`, Hold 'W' Mode handled in the roll-frame router (`RF_HoldWAutoPass`), session popup wired via `Session:_MaybeShowHoldWPopup`; both toggles visible again.
