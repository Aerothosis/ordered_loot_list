# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Subagents v1.0

Spawn subagents to isolate context, parallelize independent work, or offload bulk mechanical tasks. Don't spawn when the parent needs the reasoning, when synthesis requires holding things together, or when spawn overhead dominates.

Pick the cheapest model that can do the subtask well:
- Haiku: bulk mechanical work, no judgment
- Sonnet: scoped research, code exploration, in-scope synthesis
- Opus: subtasks needing real planning or tradeoffs

If a subagent realizes it needs a higher tier than itself, return to the parent.

Parent owns final output and cross-spawn synthesis. User instructions override.

## What This Is

**OrderedLootList** is a World of Warcraft addon (interface 120005 / 120001, Midnight 12.0.x) that implements an "ordered loot list" system for raid groups. It manages loot sessions, coordinates roll responses across the group via AceComm, tracks loot counts per player, and maintains history.

## Build & Release

There are no local build steps — Lua runs directly inside WoW. Packaging for release uses the [BigWigsMods packager](https://github.com/BigWigsMods/packager) and is automated via GitHub Actions:

- **CI release**: push a `v*` tag → `.github/workflows/package_addon.yaml` packages and uploads a zip.
- **Manual run**: trigger the workflow with a version string (upload is skipped by default).
- The packager uses `.pkgmeta` to configure packaging. All libraries (Ace3, LibStub, LibDeflate, LibDataBroker, LibDBIcon) are committed under `Libs/` and loaded via `embeds.xml`; `.pkgmeta` declares no externals, so library updates are done by hand.
- `@project-version@` in the `.toc` files is replaced by the packager with the actual tag.

The dev notes file (`OrderedLootList-devnotes.txt`) has a local build command for testing:
```
./release.sh -m dev-pkgmeta.yaml -z
```

**Dev TOC**: `OrderedLootList-Dev.toc` is a separate `.toc` for local dev (ignored in packaging). The live `.toc` is `OrderedLootList.toc`.

## Architecture

### Shared Namespace (`ns` / `_G.OLL_NS`)

All modules share a single namespace table `ns` (also exposed globally as `_G.OLL_NS`). `Core.lua` creates and populates it; every other file does `local ns = _G.OLL_NS` at the top and attaches its own module table to `ns` (e.g. `ns.Session`, `ns.Comm`, `ns.LootHandler`).

### Module Responsibilities

| File | Role |
|---|---|
| `Core.lua` | AceAddon bootstrap, AceDB defaults, slash commands (`/oll`), shared helper functions, `ns` creation |
| `Comm.lua` | All AceComm message types, serialization, send/receive dispatch |
| `Session.lua` | Loot session state machine (IDLE → ACTIVE → ROLLING → RESOLVING), roll timer, per-boss loot tables |
| `LootHandler.lua` | WoW loot window hooks (`LOOT_READY`, `LOOT_OPENED`), auto-pass/need logic, trade queue |
| `LootCount.lua` | Per-player loot count tracking, weekly reset logic |
| `LootHistory.lua` | Persistent loot history records |
| `PlayerLinks.lua` | Alt/main character linking, identity resolution |
| `Settings.lua` | AceConfig options table, settings registration |
| `MinimapButton.lua` | LibDBIcon minimap button |
| `UI/Theme.lua` | Theme definitions ("Basic", "Midnight") and runtime switching |
| `UI/RollFrame.lua` | Medium roll frame (member view) |
| `UI/SmallRollFrame.lua` | Compact roll frame |
| `UI/LargeRollFrame.lua` | Large roll frame with all-player choices display |
| `UI/LeaderFrame.lua` | Loot master control panel |
| `UI/HistoryFrame.lua` | Per-item loot history browser |
| `UI/SessionHistoryFrame.lua` | Per-session history browser |
| `UI/SessionResumeFrame.lua` | Resume-session prompt UI |
| `UI/CheckPartyFrame.lua` | Addon version check UI |
| `UI/DebugWindow.lua` | Debug output window |

### Communication Protocol

Messages are sent via AceComm with prefix `"OLL"` and routed through `Core:OnCommReceived` → `Comm:OnMessageReceived`. Each message is a serialized table `{ t = msgType, p = payload, v = version }`. Message types are short 2-4 char codes defined in `Comm.MSG`.

Leader broadcasts to RAID/PARTY channel; targeted messages use WHISPER.

### Saved Variables

Single SavedVariable: `OrderedLootListDB` (AceDB-3.0).
- `profile.*` — per-character UI settings (theme, frame size, chat verbosity, timer, etc.)
- `global.*` — account-wide data: loot counts, player links, loot history, session history

### Frame Utilities (in `Core.lua`)

Reusable helpers worth knowing:
- `ns.MakeResizableScrollFrame(f, contentW, contentH)` — wraps a frame with scrollbars and a resize grip; returns the content panel to attach child widgets to
- `ns.SaveFramePosition` / `ns.RestoreFramePosition` — persist frame positions in `profile.framePositions`
- `ns.RaiseFrame` — brings a frame and all children to the top frame level
- `ns.AttachItemTooltip` / `ns.AttachAltTooltip` — standard tooltip attachment helpers

### Slash Commands

`/oll [start|stop|config|history|sessions|takeover|links|loot|resetframes]`
