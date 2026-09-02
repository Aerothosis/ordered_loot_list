# AGENTS.md

## Repo Overview

**OrderedLootList** is a World of Warcraft addon (interface 120005 / 120001, Midnight 12.0.x) that implements an "ordered loot list" system for raid groups. Lua code only — no type system, no test framework, no linter.

## Architecture

- **Shared namespace**: `ns` / `_G.OLL_NS` created by `Core.lua`; every module does `local ns = _G.OLL_NS` and attaches its own table (e.g. `ns.Session`, `ns.Comm`).
- **Slash commands**: `/oll [start|stop|config|history|sessions|takeover|links|loot|resetframes]`
- **SavedVariable**: `OrderedLootListDB` (AceDB-3.0). `profile.*` = per-character UI settings; `global.*` = account-wide data (loot counts, player links, history).
- **Communication**: AceComm prefix `"OLL"`, message format `{ t = msgType, p = payload, v = version }`. Leader broadcasts to RAID/PARTY; targeted messages use WHISPER.
- Full module table and frame utilities are in `CLAUDE.md`.

## Dev Workflow

- **No local build** — edit Lua files and reload in-game.
- **Dev TOC**: `OrderedLootList-Dev.toc` (ignored in packaging). **Live TOC**: `OrderedLootList.toc`.
- **Dev local package**: `./release.sh -m dev-pkgmeta.yaml -z`

## Packaging & Release

- **CI**: push a `v*` tag → `.github/workflows/package_addon.yaml` runs BigWigsMods/packager and publishes a GitHub Release.
- **Manual CI run**: trigger `package_addon.yaml` with a version string (upload skipped by default).
- **`.pkgmeta`** configures the packager; it declares no externals — every library is committed under `Libs/` and updated by hand. The packager replaces `@project-version@` in the `.toc` files.
- **Libraries**: Ace3 suite + LibStub + LibDeflate + LibDataBroker + LibDBIcon, all in `Libs/` and loaded via `embeds.xml`.

## Gotchas

- `OrderedLootList-Dev.toc` and `dev-pkgmeta.yaml` are swapped in their ignore lists — the dev TOC is excluded from the release package and vice versa.
- `OrderedLootListDB` is a single SavedVariable shared across all profiles; never assume profile data is isolated without checking `profile` vs `global` keys.
- UI frames use WoW's native frame positioning persistence (`ns.SaveFramePosition` / `ns.RestoreFramePosition`); frames may not appear where expected on first load.
