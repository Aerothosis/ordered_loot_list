# OrderedLootList Bug Audit (2026-09-03)

Fresh-eyes static review of every non-library Lua file on branch `dev/v1.2.x` (commit 590074d), done without reference to the previous audit. Five parallel module reviews; every High and the load-bearing Medium claims were re-verified at the cited lines. No in-game testing was performed. Syntax check (`python tools/luacheck.py .`) passes on all 21 files.

The previous audit (2026-09-02, H1-H9 / M1-M23 / L1-L12) was fully addressed in PRs #6-#33 and is retained in git history only.

Severity: **High** = data loss, security, or raid-wide breakage. **Medium** = wrong behaviour in a realistic path. **Low** = edge case, dead code, cosmetic, docs.

Tags: **Owner** = intended behaviour confirmed with the maintainer on 2026-09-03 (see Decisions). **Suspected** = depends on WoW 12.0 runtime behaviour; verify in-game.

Sections are the intended PR grouping: one branch + PR per section into `dev/v1.2.x`, bugs before features, High first.

Totals: 11 High, 43 Medium, 58 Low (112 findings).

---

## A. Protocol trust and delivery

### A1. SESSION_START accepted from any group member; replaces receiver's loot counts and links (High, Owner)
- `Session.lua:975-1056`, `Comm.lua:168`. `senderIsLeader = Session.IsGroupLeaderOrOfficer(sender)` is computed but only used to skip join restrictions. Then `self.leaderName = payload.leaderName or sender`, `ns.LootCount:SetCountsTable(payload.counts)` (full replace of `db.global.lootCounts`) and `PlayerLinks:SetLinksTable(payload.links)` run unconditionally.
- `OnSessionResumeReceived` (3204) and `OnSessionTakeoverReceived` (3315) both gate on `IsGroupLeaderOrOfficer`; this one does not.
- Decision: require raid leader or officer.

### A2. SESSION_END has no sender check (High, Owner)
- `Session.lua:1101-1121`, `Comm.lua:238`. Any member ends the raid's session: cancels timers, sets IDLE, clears `sessionSettings`, nils `db.global.authorityRoll` (destroys the loot master's reload mirror).
- Decision: require raid leader or officer.

### A3. SESSION_JOIN validates sender only against the sender's own payload (High)
- `Session.lua:1061-1096`. `if not ns.NamesMatch(sender, payload.leaderName or "") then return end` — a player whispers SJ naming themselves as leader, becomes leader on the target client, and `SetCountsTable(payload.counts)` runs at :1081.

### A4. ROLL_RESPONSE attributed to `payload.player`, never checked against `sender` (High)
- `Session.lua:1821-1824`: `local player = payload.player or sender`. Any member can forge another player's Need, force a Pass, inject non-group names to trip `AllResponded` (C2), and the ACK at :1832 goes to the impersonated player, cancelling their own retry.
- `Comm:HandlePlayerCharList` (Comm.lua:366-377) shows the ownership-check pattern.

### A5. PLAYER_SELECTION_UPDATE unauthenticated (High, Owner)
- `Comm.lua:208-211`. Every other authority message goes through `_IsTrustedSender` (Comm.lua:401, 421). This one calls `ns.RollFrame:SetExternalSelection` directly, which clears the responded flag and submits a new choice.
- Decision: accept only from session leader or loot master.

### A6. No INSTANCE_CHAT anywhere; LFG/LFR groups receive nothing (Medium, was High)
- `Core.lua:343` `GetCommChannel`, `Session.lua:3518`, every `SendCommMessage` site. Grep finds zero `INSTANCE_CHAT` / `LE_PARTY_CATEGORY_INSTANCE`. In instance-category groups, RAID/PARTY addon messages fail silently. Maintainer confirmed PUG/LFG/5-man contexts are in scope.
- Downgraded: only Dungeon Finder / Raid Finder queue groups are instance-category. Premade Group Finder PUGs are home groups and already work.

### A7. SESSION_DELETE deletes an arbitrary session id plus every loot-history row carrying it, on every member (Medium)
- `Session.lua:3285-3307`. Gated only on raid rank; no confirmation, no undo. Combined with C15 (`sid = time()` collisions) can hit the wrong record.

### A8. `IsGroupLeaderOrOfficer` returns true when solo, so whispered leader-only messages are accepted from anyone (Medium)
- `Session.lua:116-141`; consumers at :3204, :3290, :3314. The solo shortcut exists for self-whisper testing; pair it with `ns.Comm:IsSelf(sender)`.

### A9. `ns.NamesMatch` strips realm, merging same-name players across realms (Medium)
- `Core.lua:357-363`. Load-bearing for `_IsTrustedSender` (Session.lua:1428), `IsGroupLeaderOrOfficer`, trade-queue winner match (`LootHandler.lua:410, 486, 492`), ready-check roster. Bob-RealmB passes trust checks meant for Bob-RealmA. `Comm:IsSelf` (Comm.lua:76-80) avoids this trap.

### A10. Protocol version `v` sent in every message and never read (Low)
- `Comm.lua:88-93`, `:160`. No mismatch warning; payload-shape changes between versions are processed silently.

### A11. ADDON_CHECK answered by anyone, no rate limit; checker's `version` field ignored (Low)
- `Comm.lua:304-310`.

### A12. Compressed message with non-string payload asserts inside LibDeflate (Low)
- `Comm.lua:144-152`. Only unguarded path in the receive chain.

### A13. `HandleLinksSync` wipes `playerLinks` when `payload.links` is absent (Low)
- `Comm.lua:284-299`. `SetLinksTable(nil)` becomes `{}`. START/RESUME guard with `if payload.links`; LINKS_SYNC does not.

---

## B. Debug and test sessions

### B1. Debug / Test Loot broadcasts a real session; members increment real loot counts (High, Owner)
- `Session.lua:3606`, `:3842` broadcast SESSION_START with a settings table lacking `lootCountEnabled`, so members resolve `nil ~= false` → true (:1035). `OnRollResultReceived` :2986 calls `ns.LootCount:IncrementCount(payload.winner)` on members' real tables.
- `Comm.lua:276` guards COUNT_SYNC with `if ns.Session.debugMode then return end` — the **receiver's** flag, always false on members. The comment at `Session.lua:2574` ("members guard on their side") is wrong. Leader's `_debugCounts` overlay values are written into every member's real table.
- No payload carries a debug flag.
- Decision: keep it a real session with real counts on members, but on end the session record is deleted and every client's counts revert to their pre-session values.

### B2. `LootCount:ResetAll` bypasses the debug overlay and wipes real counts (Medium)
- `LootCount.lua:128-130` `wipe(ns.db.global.lootCounts)`; every other mutator goes through `_GetTable()`. Reachable from `Settings.lua:160` during a debug session; `_debugCounts` stays populated so the UI still shows counts.

### B3. Opening the debug window twice overwrites `_savedState` with the debug session (Medium)
- `UI/DebugWindow.lua:226-233`, `Session.lua:3544-3576`. No `IsShown()` guard; Settings button stays clickable. `EndDebugSession` then "restores" the debug session as real (:3652-3670).

### B4. Debug session torn down whenever UIParent hides (Medium)
- `UI/DebugWindow.lua:201` `frame:SetScript("OnHide", ... EndDebugSession)`. `OnHide` fires on descendants during cinematics and pet battles; bypasses the session's own cinematic suspend logic and broadcasts SESSION_END.

### B5. `StartDebugSession` resets `bossHistory` but not `bossHistoryOrder` (Low)
- `Session.lua:3592`. `_ExecuteStartFresh` (656-657), `ResumeSession` (3105), `StartTestLoot` (3827) reset both.

### B6. Debug fake players appended to roster for historical bosses too (Low)
- `UI/LeaderFrame.lua:126-131`, `:1124`. Old bosses show the current fake roster as "waiting".

---

## C. Session state machine

### C1. Every member broadcasts TIMER_TICK once per second (High)
- `Session.lua:1768-1786` `_BroadcastTimerTick` has no authority gate. `OnLootTableReceived` (:1514) → `StartAllRolls` (:1556) → `_StartRollTimer` runs on all clients. 20-man raid = 20 msg/s for the roll duration. Receivers drop them via `_IsTrustedSender`, but ChatThrottleLib saturation delays LOOT_TABLE / ROLL_RESPONSE / ROLL_RESULT.
- Keep the local `LeaderFrame:OnTimerTick` / `RollFrame:OnTimerTick` calls; gate only the `Comm:Send`.

### C2. `AllResponded` compares raw response count to eligible-set size, not their intersection (Medium)
- `Session.lua:1972-1996`; `_AllRealPlayersResponded` (:3708) identical. A late joiner, a LeaderFrame-forced choice, or a forged name (A4) resolves the item while an eligible player is still deciding.

### C3. `TakeoverSession` transfers `leaderName` but not `sessionLootMaster` (Medium, Owner)
- `Session.lua:845-850`. `GetLootAuthorityName` (:2134) prefers `sessionLootMaster`, so `IsLootMasterActionAllowed` (:2155) blocks Resolve/Stop/Reroll/Reassign/ManualRoll and `LootHandler:LeaderHandleLoot` (LootHandler.lua:345) won't capture for the new leader.
- Decision: takeover inherits loot master only if the old loot master was also the old session leader; an explicitly assigned loot master keeps the role.

### C4. COUNT_SYNC delta keyed by alt character name while the value is the main's count (Medium)
- `Session.lua:2576-2584` `delta[r.winner] = ns.LootCount:GetCount(r.winner)` (GetCount resolves through `ResolveIdentity`). `LootCount:ApplyDelta` (LootCount.lua:154-160) writes `tbl[player] = count` raw. With `lootCountLockedToMain` (default) the main's count never updates on members and a junk `Alt-Realm` key accumulates, then rebroadcasts in the next SESSION_START.

### C5. SESSION_JOIN forces STATE_ACTIVE without cancelling roll timer, tick broadcaster or roll state (Medium)
- `Session.lua:1061-1096` vs `OnSessionStartReceived` (1002-1025) which does. Leader re-sends JOIN on any roster reappearance (:3504-3506); the rejoining member keeps a live timer and `OnTimerExpired` closure for a dead roll.

### C6. Raid-leader force-start sets IDLE before the resume popup and broadcasts no SESSION_END (Medium)
- `Session.lua:553-601`. Dismissing `OLL_RESUME_SESSION_LM` (OnCancel :165 only nils `_pendingResumableSession`) leaves the leader IDLE while members think a session runs; `activeSessionId` and `db.global.activeSession` still set. On success `_ExecuteStartFresh` inserts a new record (:673) while the old keeps `endTime == nil`, so `TakeoverSession`'s "most recent open" scan (838-843) can inherit the wrong id.

### C7. Single-item re-roll re-opens every already-answered item (Medium, Owner)
- `Session.lua:1612-1627` `_RefreshRollFrames` → `ShowAllItems` resets `_respondedItems = {}` in every frame. Old answers still stand in `Session.responses`; re-click sends a second ROLL_RESPONSE that silently overwrites (:1855). Large frame shows "—" for the player's own standing choices until the next delta (:1618-1623 restores `_choices` after `ShowAllItems` without a panel refresh).
- Decision: only the re-rolled item re-opens; other items stay locked showing the standing choice.

### C8. After leader `/reload`, `_SaveBossHistory` identity dedupe can never match → phantom "Boss (2)" (Medium)
- `Session.lua:2764-2789` compares `entry.items == self.currentItems`; `_PersistActiveSession` (:195-219) writes both as separate keys, and SavedVariables split the shared reference into two copies on restore (:460-466).

### C9. `SendChatMessage(..., "RAID")` in a 5-man party throws; synced `announceChannel` / `lootThreshold` / `autoPassBOE` never read from `sessionSettings` (Medium)
- Send sites: `Session.lua:1732, 2258, 2722, 2892, 858`. `announceChannel` defaults to `"RAID"` (Core.lua:73), Settings offers RAID / RAID_WARNING / PARTY / SAY, no PARTY mapping in a party.
- Leader broadcasts the three fields in `sessionSettings` (:695-696, :3169-3172) but every consumer reads `ns.db.profile.*` (incl. `LootHandler.lua:87, :291`). Dead payload.
- Open question: which Session Rules are meant to be authoritative for the raid.

### C10. Cinematic replay drops the manual roll's timer override (Medium)
- `Session.lua:3427-3439` calls `OnItemsCaptured(items, bossName, bossGUIDs)`; `_pendingCaptured*` (:1240-1242) never stores `rollTimer`, and `_rollTimerOverride` is nil'd at :1218.

### C11. `OnTimerExpired` also runs on members and fabricates local Pass rows (Low)
- `Session.lua:2040-2106`. Large frame (`_BuildSortedPlayerList` reads `Session.responses`) can briefly show players as Pass whom the authority resolved differently.

### C12. `EndSession` compares leader with raw `~=` and has no `IsActive` guard (Low)
- `Session.lua:739`. Every other identity comparison uses `ns.NamesMatch`; broadcasts SESSION_END unconditionally from any caller.

### C13. `StopRoll` wipes ready-check state before the permission check (Low)
- `Session.lua:2167-2169`. A non-authority clicking Stop cancels its own retry timer and clears `_readyCheckSerializable`.

### C14. Tiebreaker loop re-sorts the whole list but only re-checks positions i / i+1 (Low)
- `Session.lua:2636-2662`. Can exit after 20 attempts with duplicates; marks `tiebreakerRoll` on entries not re-rolled. Comparators themselves are strict.

### C15. Session id is `time()`; two sessions in the same second collide (Low)
- `Session.lua:670`. Keyed by `_UpsertSessionStub`, SESSION_SYNC, SESSION_DELETE (A7).

### C16. Party unit iteration uses `party1..partyN` (should be N-1); `_IsGuildMember` never checks the local player (Low)
- Correction: `_IsPlayerInGroup` (:2702-2706) does check the local player; only `_IsGuildMember` omits it.
- `Session.lua:928-940`, `:2692-2708`. Harmless today because `GetUnitName` returns nil for the extra index.

### C17. SESSION_RESUME with nil `sessionId` inserts `startTime = nil`; later "compare nil with number" (Low, Suspected)
- `Session.lua:3259-3268` insert; `:3062-3076` compare. Not reachable from current callers.

### C18. "Session leader left" notice reprints on every GROUP_ROSTER_UPDATE (Low)
- `Session.lua:3512-3538`. No debounce or one-shot flag.

### C19. `histEntry.itemId` is always 0; no item table ever carries `.id` (Low)
- `Session.lua:2444`, `:2514`. Item tables from `LootHandler.lua:107-115`, `:298-306` and every serializable copy carry `num/rollID/icon/name/link/quality/kind`. Documented as real in `LootHistory.lua:14`. Nothing reads it.

### C20. Hold-W popup "Disable" calls `AceConfigRegistry:NotifyChange`, a no-op; Settings toggle stays visibly on (Low)
- `Session.lua:876`. Should call `ns.Settings:RefreshSection("general")` as `OLL_HOLDW_CONFIRM` does (`Settings.lua:96-98`).

### C21. `Session.currentItemIdx` and `item.num` assigned in several places, never read (Low)
- Leftover from the one-item-at-a-time design.

---

## D. Loot window and trade

### D1. `MemberAutoPass` calls `LootSlot(i)` on every slot — takes the loot (Medium, Owner)
- `LootHandler.lua:138-147`. Name, file header and inline comment all say pass.
- Decision: only the loot master auto-loots; every other member auto-passes in the WoW loot UI. No assigned loot master means the session leader is loot master.

### D2. Stale `_pendingTradeTarget` routes one player's items into whoever trades you next (Medium)
- `UI/LeaderFrame.lua:1624-1634` sets it before `InitiateTrade`; `LootHandler.lua:383-384` consumes it in `OnTradeShow` with no partner check. Declined/failed/out-of-range trade leaves it armed for the next TRADE_SHOW from anyone.

### D3. Loot capture cannot distinguish boss loot from container/lockbox loot (Medium)
- `LootHandler.lua:53-64`, `:69-77`, `:82-133`. `isFromItem` only decides `CloseLoot`; capture happens in `LOOT_READY`, which has no such flag. Opening a satchel mid-session starts a raid-wide roll; members hit `MemberAutoPass` + `CloseLoot` on their own container.

### D4. Trade queue never shrinks; popup text says items drop off after the trade (Medium)
- `UI/LeaderFrame.lua:1500` note; `LootHandler.lua:493` only sets `entry.awarded = true`. Only `Session:_RevertResult` (:1674-1680, re-roll) removes entries. `tradeQueueBtn` stays enabled with a hidden 0 badge (LeaderFrame:601).
- Open question: audit trail (fix text) or remove on completion.

### D5. Re-opening a partially looted corpse after the roll resolves re-captures and starts a second roll (Low)
- `LootHandler.lua:82-133`; `OnItemsCaptured` guard `state == STATE_ACTIVE` (Session.lua:1210) is true again after `_CheckAllItemsResolved` (:2601).

### D6. `OnTradeClosed` counts bags synchronously; cancel indistinguishable from success (Low, Suspected)
- `LootHandler.lua:457-507`. If BAG_UPDATE has not landed, `missing` is 0 and the entry is never marked awarded. Confirm with a debug print of `#group.entries` vs `inBags` at :481.

### D7. Bag scans stop at bag 4; reagent bag (5) skipped (Low)
- `LootHandler.lua:424`, `:516`.

### D8. Dead code and stale header (Low)
- `LootHandler:IsGearItem` (:195) and `_IsItemInBags` (:528) have no callers. File header claims auto-pass logic lives here; it lives in `UI/RollFrame.lua:182-201, 764`.

---

## E. Loot counts, history, player links

### E1. "Sync to group" prints success but idle receivers drop the message (Medium)
- `Settings.lua:1430` (and `:163`). Receiver gate `_IsTrustedSender` (Comm.lua:274) requires `leaderName` set, i.e. an active session on the receiver.

### E2. Deleting a session does not undo its loot counts, though the dialog promises it (Medium)
- `UI/SessionHistoryFrame.lua:18-27` text "All associated loot data will also be removed"; `_ExecuteDelete` (:638-659) removes only the record and matching history rows. Also reads module-level `_selectedSessionId` at confirm time (:22, :639): changing selection while the dialog is open deletes the wrong session.
- Open question: roll back counts or reword.

### E3. Reassign by typed name is unvalidated; a typo creates a permanent phantom identity (Medium)
- `UI/LeaderFrame.lua:1744-1750` → `Session:ReassignItem` (:2826-2839). Only guard is raw `oldWinner == newWinner`. "Aerothos" vs "Aerothos-Illidan" passes: decrements one, increments the other, rewrites history, broadcasts the bogus winner.

### E4. Removing a character that is a main leaves its alt list dangling (Low)
- `PlayerLinks.lua:74-88` (`UnlinkCharacter`), `:171-185` (`RemoveMyCharacter`). Scans alt lists only; `links[name]` survives, so `ResolveIdentity` keeps mapping alts to a removed character.

### E5. `LinkCharacter` merge branch can leave an alt under two mains (Low)
- `PlayerLinks.lua:41-69` (`LinkCharacter`), `:119-121` (`SetLinksTable`). Correction: the merge branch is safe by construction (moved alts only ever lived under the key it just nilled). The real hole is `SetLinksTable` accepting a synced table with an alt under two mains verbatim; `ResolveIdentity` (:17-34) is then `pairs`-order dependent.

### E6. `MergePlayerCharList` change detection compares counts; a move (net zero) reports unchanged (Low)
- `PlayerLinks.lua:204-229`. No caller uses the return value yet.

### E7. `LootHistory:ExportCSV` does not quote `rollType`; `%d` errors on non-integer `rollValue` (Low)
- `LootHistory.lua:87-118` (`ExportCSV`, format at :105-113). Roll option names are user-editable and may contain commas.

### E8. Loot history unbounded; player identity frozen at insert while the filter resolves at query time (Low)
- `LootHistory.lua:18-22` (`AddEntry`), `:41-80` (`GetFiltered`, resolves at :50). Later link changes make old rows unfindable by the current main.

### E9. Roster CSV export has no quoting, omits alt rows, ignores the search filter; popup not in `UISpecialFrames` (Low)
- `Settings.lua:2042`, `:2049`, `:2086`. Edit box height fixed at 2000 regardless of rows.

---

## F. Roll frames (Small / Medium / Large)

### F1. Medium frame writes live results and choices onto boss-history rows (Medium)
- `UI/RollFrame.lua:624-635` `ShowResult`, `:559-578` `OnRollChoice`, `:591-596` `ResetItemChoice`. Small guards every mutation with `_viewingHistory` (SmallRollFrame.lua:286, 308, 321); Medium has none. "Pass all" in history view repaints history rows as chosen.

### F2. Timer expiry while viewing history: only Small auto-passes (Medium, Owner)
- `UI/SmallRollFrame.lua:331-340` auto-passes; `UI/RollFrame.lua:601-605` and `UI/LargeRollFrame.lua:601-603` return early.
- Decision: auto-pass remaining items in every frame size.

### F3. "Current roll" is a no-op unless state is ROLLING on Small/Medium (Medium)
- `UI/RollFrame.lua:640-650`, `UI/SmallRollFrame.lua:353-363`. After resolution the user is stuck on the history boss. Large (`:620-632`) refreshes unconditionally and is correct.

### F4. `/oll loot` after a cinematic-suspended roll rebuilds the frame as if Hold-W hid it (Medium)
- `UI/RollFrame.lua:790-795`, `:827-852`. `SuspendRoll` (Session.lua:2222) hides the frame while `state == ROLLING`; the router misreads `_active == nil` as Hold-W, resets responded state, shows a dead timer bar, and accepts responses the authority discards (Session.lua:1836).

### F5. `LargeRollFrame._choices` is the client-side choice cache for all sizes but only cleared by Large's `ShowAllItems` (Medium)
- `UI/LargeRollFrame.lua:579-589` `ApplyChoiceDelta` runs for every client (Comm `HandleChoicesUpdate`); wiped only at `:247` and `Reset`. `Session:OnRollResultReceived` (:2932-2947) builds `rankedCandidates` from it. Small/Medium users carry boss-A choices into boss-B results and `bossHistory`.

### F6. No `GET_ITEM_INFO_RECEIVED` retry anywhere; uncached items silently skip auto-pass rules and render without icon/quality (Medium)
- `UI/RollFrame.lua:104-123` (`_GetItemTypeLabelAndColor` → nil, `autoPassUnequippable` no-op), `:181-209` (`select(14, ...)` nil → `autoPassBOE` no-op). `UI/HistoryFrame.lua:403`, `UI/SessionHistoryFrame.lua:579-589`, `UI/LeaderFrame.lua:159, 1898` render grey/blank. First kill of a tier is exactly when the cache is cold.

### F7. "Pass all" closes the window on Small/Medium but not Large; tooltips differ (Low, Owner)
- `UI/LargeRollFrame.lua:74` vs `UI/RollFrame.lua:318-321`, `UI/SmallRollFrame.lua:53-56`.
- Decision: new profile setting "close loot roll frame when Pass All selected", default on, honoured by all three frames.

### F8. Medium lacks the off-screen position recovery Small and Large have (Low)
- `UI/RollFrame.lua:283-372` vs `SmallRollFrame.lua:142-150`, `LargeRollFrame.lua:208-216`.

### F9. Medium calls `ns.Session:GetBossHistory` without the nil guard the other two have (Low)
- `UI/RollFrame.lua:656`.

### F10. Feature divergence: Pass-all remaining count/disable only in Large; winner "Main: X" tooltip only in Medium (Low)
- `UI/LargeRollFrame.lua:286-296`; `UI/RollFrame.lua:436-441` vs Small `:189-195`, Large `:309-315`.

### F11. Scroll offset never reset between bosses (Low)
- All three `ShowAllItems` / `ShowBossHistory` / `_RefreshLeftPanel`. A short list after a long one renders blank.

### F12. `UnlockBossDropdown` clears `_viewingHistory` and relabels but never refreshes panels (Low)
- `UI/LargeRollFrame.lua:699-709`; called from Session.lua:2339, 2599, 3008.

### F13. `UpdateTimer` writes to the timer bar it just hid after `AutoPassAll` (Low)
- `UI/RollFrame.lua:607-619` and Small/Large equivalents.

### F14. Frame-size Preview drives the live roll frame and broadcasts ROLL_RESPONSE (Low)
- `Settings.lua:684-693`. Each segment click calls `Session:SubmitResponse`; preview window never closes itself.

### F15. No-`MenuUtil` fallback can call `onBoss(nil)` (Withdrawn)
- `UI/RollFrame.lua:251-253`. Re-verified 2026-09-03: `_cycle % (#keys+1)` never indexes past `#keys`; `onBoss(nil)` is unreachable. Not a bug.

---

## G. Leader frame

### G1. `ipairs` over a table with a nil hole: popups are never hidden on close or re-themed (High)
- `UI/LeaderFrame.lua:2228-2231` (Hide/Reset) and `:499-502` (ApplyTheme): `ipairs({ self._lootMasterPopup, self._manualRollPopup, ... })`. All five are lazily created; index 1 is nil unless the LM picker was opened, so the loop body never runs. Manual Roll / Trade Queue / Reassign / Loot Captured popups float ownerless after closing the Leader Frame.

### G2. A just-finished boss is drawn twice in the left panel until the next capture (Medium)
- `UI/LeaderFrame.lua:703-731`. `_CheckAllItemsResolved` (Session.lua:2570) stores `currentItems` into `bossHistory` and returns to ACTIVE without clearing it; the panel draws "CURRENT BOSS" and the history copy with different item keys.

### G3. Roster choice override and "Pass remaining" not permission-gated (Medium)
- `UI/LeaderFrame.lua:996-1013`, `:1052-1068` created on `isRollingItem` only. `LeaderFrame:Show()` (:2124) admits any `ns.IsLeader()` (raid assistants). Non-authority path writes local responses only, but still whispers PLAYER_SELECTION_UPDATE to the target, forcing a choice the authority never records.
- Open question: read-only frame for assistants, or not shown.

### G4. Every member constructs the full Leader Frame on first `Refresh` (Medium)
- `UI/LeaderFrame.lua:533-535` `GetFrame()` runs before the `IsShown` check; ~20 non-gated call sites in Session (e.g. :1877, :2537) plus `StartTimer` (:2252). Swap to `if not self._frame or not self._frame:IsShown() then return end`.

### G5. Manual-roll items and timer override discarded before `StartManualRoll` can reject them (Medium)
- `UI/LeaderFrame.lua:1983-1996`. `StartManualRoll` (Session.lua:3744-3756) has three bail-outs. Make it return a boolean and clear only on success.

### G6. Loot-master picker list has no mouse-wheel scrolling (Low)
- `UI/LeaderFrame.lua:1343-1349`.

### G7. Elapsed pill derives from session id; a resumed session shows time since original start (Low)
- `UI/LeaderFrame.lua:543` `FormatElapsed(session.activeSessionId)`. Correction: `rec.startTime == rec.id` (both `time()` at creation, neither bumped by `ResumeSession`), so switching to `startTime` changes nothing. Needs a `resumedAt` field set in `ResumeSession`.

### G8. Dead code (Low)
- `UI/LeaderFrame.lua:655` identical if/else branches; `_AcquireTexture` (:665-684) and `_tradeQueueRowPool` (:67) unused; `OnPendingRollReady(items, bossName)` (:2149) ignores both parameters.

---

## H. History windows, resume prompt, version check

### H1. Night-group header is clipped back to the 112px Date column (Medium)
- `UI/HistoryFrame.lua:378-386` sets width 400, then `tbl:Layout()` (:434) → `placeCell` (`UI/Widgets.lua:1023`) re-applies column width to every pooled row.

### H2. "To" date filter excludes the whole selected day (Medium)
- `UI/HistoryFrame.lua:492-497` parses local midnight; `LootHistory.lua:68-72` rejects `timestamp > dateTo`. Add 86399 or use 23:59:59.

### H3. Version check is string equality: newer peers and dev builds show as Outdated (Medium)
- `UI/CheckPartyFrame.lua:262` `theirVer == ns.VERSION`. `ns.VERSION == "dev"` for unpackaged builds (Core.lua:25).
- Open question: semver compare with a "Newer" state.

### H4. `SessionResumeFrame` height assumes the footer disappears when `canStartFresh` is false, but the footer bar stays (Medium)
- `UI/SessionResumeFrame.lua:155` vs `:106-108`, `:120`, `:147`. Non-raid-leader loot master with 4 sessions: last row clipped, no scroll affordance.

### H5. Item column sorts by raw hyperlink (colour hex then item ID), not name (Low)
- `UI/HistoryFrame.lua:340-347`.

### H6. Player filter menu shows stripped name, button shows full Name-Realm (Low)
- `UI/HistoryFrame.lua:186` vs `:83-86`.

### H7. Open history windows never refresh on new awards (Low)
- `HistoryFrame:Refresh` only from Show/Toggle/filters/theme; `SessionHistoryFrame:Refresh` only from `OnSessionDeleted`.

### H8. `%02x` formatted from float colour components (Low, Suspected)
- `UI/LeaderFrame.lua:942`, `UI/SessionHistoryFrame.lua:466`, `:489`. Lua 5.1 truncates; newer runtimes may raise "number has no integer representation". `math.floor` costs nothing.

### H9. `_IsSessionResumable` compares nil `startTime` with a number (Low)
- `UI/SessionHistoryFrame.lua:113-117`; `_GetSortedSessions` (:92) already anticipates nil.

### H10. CheckPartyFrame tally and lifecycle gaps (Low)
- `:311-313` "N of M pinged" mixes live roster with the frozen status snapshot; `:272-274` late responders outside the snapshot inflate rows; `:258-259` responses dropped while the window is closed and `Show()` re-pings everyone (:218). No combat hide / off-screen recovery unlike the roll frames.

### H11. `SessionResumeFrame:Hide()` does not clear `_pendingResumableSessions`; `n == 0` renders "0 sessions" (Low, latent)
- `UI/SessionResumeFrame.lua:186-188` vs X handler `:90-93`; `:149-152`. Every current `Hide()` caller nils the flag first and `Show()` is only called with `#resumables > 1`, so neither failure is reachable today. Hygiene only.

---

## I. Settings, Core, theme, widgets

### I1. "Counts for loot" toggle visibly snaps back on never-customised roll options (High)
- `Settings.lua:1149-1152`, `:1219`. Row holds the `DEFAULT_ROLL_OPTIONS` table; the write goes to the fresh copy from `_EnsureCustomOpts()` (:70-85); `MakeToggle`'s Refresh re-reads `row._opt.countsForLoot` from the default. Value is saved; the UI lies until the section is re-entered. `c.word` (:1247) stays stale too.

### I2. Realm built with `GetRealmName():gsub(" ", "")` while everything else uses `GetNormalizedRealmName` (High)
- `Settings.lua:794` `CurrentCharName`, `:1082` disenchanter "Use target". `GetNormalizedRealmName` strips all punctuation. On Mal'Ganis, Kil'jaeden, Zul'jin, Ner'zhul, Area 52 variants: "Use current" registers a second unlinked identity with its own count; `useBtn` (:934) never disables; disenchanter set via "Use target" won't match the stored roster name.
- Likely needs a `settingsVersion` 2 migration to merge duplicated keys.

### I3. `ns.RaiseFrame` adds 100 per click, never resets; passes the frame-level ceiling after ~100 focus clicks (Medium)
- `Core.lua:370-383`; called from every `MakeLedgerFrame` OnMouseDown (`UI/Widgets.lua:220`) and `Settings:Open()` (:220). Also flattens the resize grip's `+10` offset (`Widgets.lua:241`, `Core.lua:613`) to `+1`.

### I4. Custom button label colours wiped by the first `SetEnabled` (Medium)
- `Settings.lua:827` (Set main), `:1550` (Reset), `:1456` (red Reset-all). `ns.MakeButton` runs `ApplyTheme` on OnEnable/OnDisable (`UI/Widgets.lua:432-433`) which recolours `_text` unconditionally (:422-427). `paintRow` (:1588) and `RefreshChrome` (:1992) call `SetEnabled` immediately.

### I5. Roll-option Color picker persists a colour nothing renders (Medium)
- `Settings.lua:1250-1281`. `MakeSegmented:SetOptions` (`UI/Widgets.lua:502`) copies only name and priority; segments colour from `theme.choiceColors[priority]` (`UI/Theme.lua:260`). Only readers of `colorR` are the swatch and `_EnsureCustomOpts`.
- Open question: drive segment colours from it, or drop the column.

### I6. Minimap icon keeps the old profile's table after a profile switch (Medium)
- `MinimapButton.lua:79` registers `ns.db.profile.minimap`; `Settings.lua:511-512` `SetProfile` swaps the table. No `LDBIcon:Refresh` anywhere; `OnProfileChanged` (:462-468) reapplies theme only.

### I7. Minimap button cannot be hidden (Medium)
- No Settings toggle for `profile.minimap.hide` (only `Core.lua:78` default and the Register call). `MinimapButton.lua:45-55` OnClick consumes RightButton, so LibDBIcon's own hide menu never appears.

### I8. Session Rules banner promises lock icons the pane never shows; `rollTimer` edits mid-session silently ignored (Medium)
- `Settings.lua:959-982` text vs no `locked = true` rows in `_BuildSessionPane` (only Roster → Counting rules :1863-1914 have them). `Session:GetRollDuration` (:1566-1567) prefers the session-start snapshot; `lootMasterRestriction` and `disenchanter` push live (:1047-1049, :1066-1068).
- Open question: which rules apply mid-session (see C9).

### I9. Roster stepper clamps to 999 and writes it: one "+" on a synced count of 1500 writes 999 (Medium)
- `Settings.lua:1534` `MakeStepper(row, 0, 999, ...)`; `bump` (`UI/SettingsWidgets.lua:287-293`) `min(max, cur + step)` then `nv ~= cur` → write. Nothing clamps incoming COUNT_SYNC values.
- Open question: is 999 an intended cap.

### I10. `MigrateProfile` runs only in `OnInitialize`, not on profile switch (Low)
- `Core.lua:172`; `Settings.lua:462` `OnProfileChanged` does not call it. A switched-to old profile skips migration.

### I11. `ns.MakeResizableScrollFrame` and `_UpdateResizableScrollBars` are dead (zero callers); `CLAUDE.md` still documents them (Low)
- `Core.lua:476-640`. `MakeLedgerFrame`'s grip (`UI/Widgets.lua:247-254`) is a duplicate implementation.

### I12. Unused LibStub handles; AceDBOptions never referenced despite the comment saying it backs the picker (Low)
- `Core.lua:31-33` `ns.AConfig / ACDiag / AGUI` never used; `embeds.xml:8`; `Settings.lua:9` comment vs hand-rolled `MenuUtil` picker (:504-529). Unguarded `LibStub` calls would hard-error if libs were trimmed.

### I13. `ROSTER_TABS` declared, never used; roster sub-tab persisted unvalidated (Low)
- `Settings.lua:35`, `:212-216`. `OpenConfig("roster.anything")` renders the roster pane empty until a tab is clicked. `SECTIONS` is validated (:219).

### I14. Dead-but-wrong legacy branches (Low)
- `Settings.lua:1276-1279` ColorPicker `.func/.cancelFunc` (pre-10.2 API); `:2129` `InterfaceOptions_AddCategory` (removed 10.0); `:2126` `category.ID = ns.ADDON_NAME` overwrites the numeric id (Suspected impact).

### I15. `/oll resetframes` clears position but not the saved size (Low)
- `Core.lua:441-471`. `RestoreFramePosition` reapplies `w/h` (:422-424); reset only re-anchors.

### I16. `GetPlayerNameRealm` dead duplicate branch; can return `"Name-"`; errors before PLAYER_LOGIN (Low)
- `Core.lua:305-311`. `name` not nil-guarded; `"Name-"` would become a real key in `lootCounts` / `playerLinks`.

### I17. Shared font objects tinted with Ledger at load; Midnight/Basic profiles never re-apply at login (Low)
- `UI/Widgets.lua:1198` runs before `ns.db` exists; `Ledger.ApplyTheme` re-run only via `Theme:Set` or profile callbacks. Confirmed victim: `counts.empty` (`Settings.lua:1703`). Fix: `ns.Theme:ApplyToAll()` at the end of `OnInitialize`/`OnEnable`.

### I18. `_addCharName` captured without the `userInput` flag; refresh while typing resets the caret (Low)
- `Settings.lua:899` vs `:1402-1404` which gates on `user`; `:933` `SetText` on every refresh.

### I19. Dev and live TOC share `SavedVariables` and the hardcoded addon name (Low)
- `OrderedLootList-Dev.toc`, `Core.lua:8`. Both folders enabled at once: `NewAddon` errors on the second load, `_G.OLL_NS` clobbered, same SV written. `UI/Widgets.lua:19` already derives the folder from `...`.

### I20. Widget primitives (Low)
- `UI/Widgets.lua:1005` `MakeTable:_Resolve` errors on a column without `width` (`fixed + nil`).
- `UI/Widgets.lua:1130-1132`, `UI/CheckPartyFrame.lua:187-189` `th.columnHeaderHex:sub()` unguarded; one missing theme key breaks the whole `ApplyTheme` pass.
- `UI/Widgets.lua:421, 425`, `SessionResumeFrame.lua:197`, `CheckPartyFrame.lua:195, 199` hard-coded button hex colours bypass themes.
- `UI/Widgets.lua:867`, `UI/RollFrame.lua:425` `if not check:SetAtlas(...)` — `SetAtlas` returns nothing, so the fallback branch likely always runs (Suspected).
- `UI/Widgets.lua:906` vs `UI/RollFrame.lua:471` two owners size `row.rightSlot` with a 4px mismatch.
- `UI/Widgets.lua:1159-1166` `AttachFadeIn` replays the 120ms fade on every combat hide/show cycle.

### I21. Deprecated globals still used alongside `C_Item.*` (Low, Suspected)
- `GetItemInfo`: `UI/HistoryFrame.lua:403-404`, `UI/SessionHistoryFrame.lua:579, 586`, `UI/LeaderFrame.lua:1898, 1940`. `GetItemQualityColor`: `UI/Widgets.lua:67`, `UI/LargeRollFrame.lua:388, 662`, `UI/LeaderFrame.lua:822, 1669`. `GetLootSpecialization / GetSpecialization / GetSpecializationInfo`: `UI/RollFrame.lua:34-42`. `CanLootUnit` second-return assumption: `Session.lua:1502`.
- The rest of the code already uses `C_Item.GetItemInfo` (`LootHandler.lua:171`, `UI/RollFrame.lua:107, 185`, `UI/LeaderFrame.lua:159`). If 12.0 drops the wrappers these paths throw, and `_GetPlayerMainStat` returning nil silently disables stat pills and `autoPassOffSpec`. Drop-in renames; confirm on the client.

---

## Verified clean (no need to re-audit)

- Syntax: 21 files, 0 errors. `.toc` load order and `embeds.xml` order valid; `_G.OLL_NS` published before any other file runs; the only load-time cross-file calls (`UI/Widgets.lua:1198`, `UI/SettingsWidgets.lua:15/19`) are correctly ordered.
- Every `ns.*` symbol referenced is defined. Every `db.profile.*` / `db.global.*` key read (26 / 9) has a default of matching type; every Settings control writes the key its consumer reads.
- All three themes have byte-identical token sets; no UI file references a missing token.
- All 19 `Comm.MSG` types are both sent and handled; all `Session:On*Received` callees exist; `Session.IsGroupLeaderOrOfficer` correctly called with `.`. CHOICES_UPDATE, ROLL_RESULT, loot-history, session-history and trade-queue field names match on both sides. `ns.RollFrame` router implements all 10 forwarded methods.
- Every `table.sort` comparator checked (`Session.lua:2627, 2650`, `LargeRollFrame:464`, `CheckPartyFrame:316`, `LeaderFrame:1124`, `HistoryFrame:340`, `Settings.lua:1610, 2027`) is a strict weak ordering. No table mutation during `pairs()`.
- `ns.TimeUTC`, `GetLastWeeklyReset`, `LootCount:CheckWeeklyReset` boundary math correct. `ns.GetItemKey` field 13 = numBonusIDs correct. `C_Item.GetItemInfo` destructuring in `ClassifyItem` lands on 9/12/13.
- All AceEvent callback signatures correct (incl. `ENCOUNTER_END` 6-arg). `_InstallLiveHooks` idempotent; no duplicate event registration on re-enable.
- Roll-frame row pools set scripts and tooltips at creation only; `MakeSegmented:SetOptions` handles shrinking lists; `MakeTimerBar:SetProgress` guards zero duration; `GameTooltip` hidden on every OnLeave; `SetHyperlink` always behind a `|H` check. `Comm._lastTimerRemaining` is reset on LOOT_TABLE. `RF_HoldWAutoPass` keys match the leader's `"Name-Realm"` form.
- CheckPartyFrame party roster (`1..numMembers-1` + self) off-by-one handling correct.
- `MenuUtil.CreateContextMenu` used with the modern signature everywhere; no `UIDropDownMenu` taint.
- `MakeLedgerFrame` does not register `UISpecialFrames`, so Escape does not clobber the elapsed ticker or DebugWindow's OnHide.

---

## Decisions (2026-09-03, confirmed with maintainer)

- **Pass All (F7):** add profile setting "close loot roll frame when Pass All selected", default true, honoured by Small, Medium and Large.
- **Timer expiry while browsing history (F2):** auto-pass remaining items in every frame size.
- **Single-item re-roll (C7):** only the re-rolled item re-opens; answered items stay locked showing the standing choice.
- **PLAYER_SELECTION_UPDATE (A5):** accept only from the session leader or loot master.
- **SESSION_START / SESSION_END (A1, A2):** require raid leader or officer, same gate as SESSION_RESUME / SESSION_TAKEOVER.
- **Debug / Test Loot (B1):** stays a real session with real counts on members; on end the session record is deleted and every client's loot counts revert to their pre-session values.
- **Loot window (D1):** only the loot master auto-loots; every other member auto-passes in the WoW loot UI. No assigned loot master means the session leader is loot master.
- **Takeover (C3):** the new leader becomes loot master only if the old loot master was also the session leader; an explicitly assigned loot master keeps the role.
- **Scope:** guild raids, PUG/LFG/instance groups and 5-man parties are all in scope (A6, C9).

## Open questions

1. Roll-option Color picker (I5): drive roll-frame segment colours, or drop the column?
2. Which Session Rules apply mid-session (C9, I8): `rollTimer`, `lootThreshold`, `announceChannel`, `lootRollTriggering`?
3. Delete session (E2): roll back its loot counts, or reword the dialog?
4. Trade queue (D4): awarded entries stay as an audit trail, or drop on completion?
5. Leader Frame for raid assistants who are not loot authority (G3): read-only, or not shown?
6. Minimap button (I6, I7): add a Hide toggle? Move icon position to `global`?
7. Loot count cap (I9): is 999 intended?
8. Version check (H3): semver compare with a "Newer" state?

## Fix order (proposed)

1. **A** protocol trust: A1-A6 together (one trusted-sender predicate for leader/officer, one for authority; INSTANCE_CHAT channel selection). Then A7-A9.
2. **C1** timer-tick gate (one line) and **G1** popup loop (one line) — ship early, both are trivial.
3. **B** debug sessions per the B1 decision (debug flag in payloads, snapshot/revert counts on all clients, delete record on end), B2-B4.
4. **C** remaining session state: C2-C10.
5. **D** loot window and trade: D1 (per decision), D2-D4.
6. **I1, I2** (with key migration), then the rest of **I**.
7. **F** roll frames: F1-F6, F7 (new setting), then Low.
8. **G**, **H**, **E** Medium items.
9. Low items and the open questions once answered.

## Status

Re-verified 2026-09-03 against code: 104 confirmed as written, 7 corrected in place (A6 severity, C16, E4-E8 line numbers, E5 mechanism, G7 fix, H11 reachability), 1 withdrawn (F15).

All fixes live on the umbrella branch `fix/audit-2026-09` (based on `dev/v1.2.x` after PR #34), one commit per section, one PR into `dev/v1.2.x` at the end. Nothing has been tested in-game yet.

| Commit | Section | Fixed |
|---|---|---|
| PR #34 (merged) | A + C1 + G1 | A1-A6, A8, A9 (trust paths), A12, A13, C1, G1, C9 channel half |
| `fix(debug)` | B | B1 (member overlay), B2-B6 |
| `fix(session)` | C | C2-C20 |
| `fix(loot)` | D, E | D1-D8, E1-E9 |
| `fix(settings)` | I | I1-I21 (I5 column dropped, I7 toggle, I8 live sync), F7 setting |
| `fix(ui)` | F, G, H | F1-F7, F9, F12-F14, G2-G8, H1-H11 |
| `fix(protocol)` | A lows | A7 (record owner only), A10 (mismatch noted once, Debug level), A11 (5 s reply throttle), F11 (Medium) |

**Left as is** (cosmetic or no behaviour): C21 dead fields; F8 (RestoreFramePosition already discards off-screen offsets); F10 feature parity; F11 on Small/Large; I20 hard-coded button hex colours, rightSlot 4 px, fade replay; I21 `CanLootUnit` second return (confirm on the client).

**Open-question outcomes** (proceeded on the recorded recommendation; reversible):
1. I5: Color column removed; stored colorR/G/B untouched.
2. C9 / I8: `rollTimer` and `lootThreshold` are session-authoritative (snapshot + SETTINGS_SYNC on edit by the session leader); `announceChannel`, `autoPassBOE`, `lootRollTriggering` stay per client.
3. E2: dialog reworded (record + history rows; counts unchanged).
4. D4: awarded entries drop off the trade queue after the trade.
5. G3: assistants can open the Leader Frame but the choice override and "Pass remaining" are authority-only.
6. I6 / I7: minimap icon follows the profile; General > Minimap toggle added; position stays in the profile.
7. I9: roster stepper cap 9999; out-of-range values are left untouched.
8. H3: dotted-number compare; newer peers and dev builds count as current (no separate "Newer" state).

**Design notes**
- Member side of debug / test sessions uses the existing `LootCount` shadow overlay (`Session:_SetRemoteDebug`), flagged by `debug = true` in SESSION_START / SESSION_JOIN, not a persisted snapshot/revert.
- AceComm senders are canonicalised to `Name-Realm` once in `Comm:OnMessageReceived`; trust checks use `ns.NamesEqual`. `ns.NamesMatch` remains for display and trade-queue matching.
- `global.dataVersion` 1 merges realm-key variants (apostrophes / hyphens / spaces) across counts, links, my characters and loot history.

Branch base is `dev/v1.2.x`; v1.3.0 release remains on hold until the umbrella PR is tested in-game.
