# OrderedLootList Changelog

## v1.3.0 — 2026-09-02

**Everyone in the raid must update to 1.3.0.** This release changes how clients talk to each other (new message types, session ids on every message, item categories). Mixing 1.2.x and 1.3.0 clients in one raid will produce missed rolls and mismatched loot counts. Use **Check Party** on the Leader Frame before the first pull to confirm versions.

### New look: Ledger

Every OLL window has been redesigned. The new **Ledger** theme is the default for new installs (existing characters keep their current theme; pick Ledger under Settings → UI Theme). Near-black surfaces, one brass accent, quality colours only on item names, and exactly one highlighted primary action per window.

- **Leader Frame**: a status pill with elapsed session time, `PARTY / LOG / OPTS` tool buttons, one contextual primary (Start Session → Start Roll → Stop Roll), a live `responded/total` count per item, an item hero with a 30pt countdown and responded figure, a roster table with choice dots and gear-count bars, waiting players collected as chips, and an award bar reading `ANNOUNCE <winner> · Need 92` with Re-roll / Reassign beside it. While a roll is live each roster row has a compact Need/Greed/Pass control for the loot master.
- **Roll windows** (small / medium / large): a segmented `NEED / GREED / PASS` control per item, 2px timer with the seconds in the header, stat and armour-type pills, auto-passed items shown dimmed with the reason, winners shown inline with a check. The large window's roster reflows when you resize it, and boss history is a header menu instead of a footer dropdown. The small window gets boss history too: click the boss name in its footer once the roll has resolved.
- **Loot History**: filters as menus and outlined date fields, awards grouped by raid night, sortable columns with the sorted one highlighted, Count before Choice.
- **Session History**: one metadata line per night, winner and `CHOICE ROLL` in fixed right-hand columns, runners-up summarised on one line (`… · 6 passed`).
- **Party Check**: a live tally strip (`Ready / Outdated / Missing / Checking`, `N of M pinged`), rows sorted so the players who need action are on top.
- **Resume Session**: explains what resuming means, the newest session's Resume is highlighted, and the close button now cancels instead of silently starting a fresh session.
- **Manual Roll**: choose a timer for a single roll (`Start roll · 15s`); members' countdowns match.
- **Trade Queue**: grouped per winner with a class-coloured disc, the first pending player's Open Trade highlighted, and a note that items leave the queue when the trade completes.
- New fonts (Spectral, Barlow Semi Condensed) and textures ship in the addon. **Restart the game client once** after updating — `/reload` will not pick up new font files and text would render blank.

### Highlights

- Loot counts, history and roll results are now consistent across every client. Several bugs made the leader's numbers drift from members' (double-counted wins, duplicate history rows, results members never received).
- Late joiners, whisper storms and frozen countdowns are fixed. Sessions are far lighter on the addon channel.
- A session now survives the leader reloading or disconnecting.
- Tier tokens and recipes go through the OLL roll. Cinematics pause a roll instead of handing everything to the leader.

### For raid leaders and loot masters

**Sessions**
- **Restore after `/reload` or disconnect.** The session leader's state is saved continuously. On login you are asked to *Restore* (re-syncs the whole group, re-opens any roll that was in flight) or *Discard* (the session stays resumable later via `/oll start`).
- **One loot authority.** The session loot master (or the session leader if none is set) is the only client that captures drops, records choices and resolves rolls. Raid assistants no longer accidentally start their own roll by opening a corpse. A leader who appoints a different loot master hands over the Manual Roll / Stop Roll / Reassign buttons until they take it back.
- **Loot master who is not the leader** now works end to end: members accept their timer ticks, choices and count updates, and the boss list on the session record is kept up to date. Their roll in flight survives a `/reload` or disconnect too: on logging back in they rejoin the session and the unresolved items re-open for the group with a fresh timer, keeping the choices already made and the items already awarded.
- **Party (5-man) groups**: resume, takeover and the Assign Loot Master list now recognise the party leader in any slot.
- Deleting a session record between raids now propagates to members.

**Rolls**
- **Re-roll a single item.** The Leader Frame's *Re-roll* button re-opens only that item; other items keep their winners. The previous winner's loot count, history row and trade-queue entry are reverted.
- **Cinematic mid-roll = pause, not payout.** The roll pauses (nothing awarded), then restarts with a fresh timer for the unresolved items when the cinematic ends.
- **Tier tokens and recipes** are rolled through OLL like gear. Two new settings under *Loot Count Settings* decide whether winning one counts toward the loot count (both default **off**). Mounts, pets and other non-gear items still stay with the loot master.
- Items that everyone passes on are now shown correctly on members' screens and recorded in their history.
- Reassigning an item updates members' history rows to the new winner.
- A player's random roll is assigned once per item; a resent choice or a changed choice keeps the same number.
- Trash and chest drops no longer trigger the boss lock-out check, so members are not wrongly auto-passed on them.

**Trade queue**
- Won items are found in your bags again (bag links and loot links differ in ways that used to defeat the match), so they auto-place in the trade window and are marked awarded only when actually traded. Two copies of the same item are awarded one at a time.

**Loot counts**
- **Reset Region** setting (Auto / NA / EU) under *Reset Schedule*. Weekly reset is Tuesday 15:00 UTC for NA and Wednesday 04:00 UTC for EU. Reset times are computed in UTC; previously they fired late by your local timezone offset.
- Loot count at time of win is recorded correctly when the loot-count system is disabled (it could go negative).

**Leader Frame / UI**
- Long raid nights no longer leak memory: the Leader Frame reuses its labels, the Reassign popup and the CSV export dialog instead of creating new ones every refresh or click.
- The Large roll frame no longer overlaps "You chose" with the result, and cannot be shrunk to the point where the Roll/Count columns disappear.
- Roll frames no longer reappear empty after combat if the roll ended while you were fighting.

### For members

- **Update to 1.3.0** or your rolls will not be seen.
- **Auto-pass is off by default.** Earlier versions silently passed on items whose main stat did not match your spec, and the toggle to stop it was greyed out. On first login with 1.3.0 every auto-pass option is turned off. If you want it, enable *Auto-Pass Off-Spec Loot*, *Auto-Pass Unequippable Items* and/or *Auto-Pass BoE* in Settings. All three toggles work.
- **Hold 'W' Mode** works: with it on, every roll is passed silently and no roll frame appears. `/oll loot` still opens the frame if you change your mind. When a session starts you are asked once whether to keep it on.
- Joining a raid after the session started now works (it used to throw an error on your screen and leave you out of the session).
- `/reload` or a disconnect mid-raid no longer drops you out of the session: on login your client asks the group and the leader puts you back in.
- The countdown keeps running on every roll, not just the first one of the night.
- If a roll is paused for a cinematic, your roll frame closes and comes back with a full timer afterwards; choose again.
- If the leader re-rolls an item, only that item re-opens on your screen.
- Your character list is only merged if it actually belongs to you; another player's client can no longer re-link your characters.
- Priests: one-handed swords are now correctly shown as unusable.

### Fixes (short list)

- Late-join crash (`SESSION_JOIN`), wrong-argument broadcasts for all-pass and reassign results.
- Leader processed its own broadcasts (double count increments, duplicate history/boss entries, timer restarts).
- Member countdown froze after the first roll; SESSION_JOIN whisper storm on the first roster change; ready-check whispers to addon-less players capped.
- Stale settings carried between sessions; session id now sent to members.
- Boss GUIDs taken from trash/chests caused false lock-outs.
- Solo/debug sessions no longer attempt whispers to nobody.
- Duplicate `order` values in Settings, dead `HISTORY_SYNC` message, bogus boss-history entries on members, saved sizes applied to non-resizable frames, CSV export box width, CI pre-release flag judged by branch instead of version.

### Upgrade notes

- **Restart the WoW client** (not just `/reload`) after installing 1.3.0 so the new fonts and textures are found.
- No SavedVariables migration is required. Auto-pass toggles are forced off once (tracked by a new `settingsVersion` field).
- New profile settings: `tokensCountAsLoot`, `recipesCountAsLoot`, `resetRegion`. New account-wide fields: `activeSession`, `authorityRoll`. `profile.theme` accepts `"Ledger"` (default for new installs).
