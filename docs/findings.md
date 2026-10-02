# Findings

The project's memory. Every address, signature, path, format detail, and dead end goes here, with evidence and a confidence level.

Paths below are relative to `BO3_ROOT` (Mod Tools install) or `BO3_GAME_ROOT` (game install) from `.env`.

## Phase 0: Recon

### Install layout (2026-10-02, verified)

The Mod Tools are **not** installed inside the game folder on this machine. Steam installed them as a separate app:

| Steam app | ID | `installdir` (from `appmanifest_*.acf`) |
|---|---|---|
| Call of Duty: Black Ops III | 311210 | `Call of Duty Black Ops III` |
| Call of Duty: Black Ops III - Mod Tools | 455130 | `Call of Duty Black Ops III 455130` |

Consequence: the project needs two roots. `BO3_ROOT` points at the Mod Tools folder (Radiant, build tools, `map_source`, `share/raw`). `BO3_GAME_ROOT` points at the game folder (`BlackOps3.exe`). Every tool that launches the game or looks for compiled `usermaps` output must decide which root it means.

Paths listed as `VERIFY` in CLAUDE.md, checked under `BO3_ROOT`:

| Path | Exists | Notes |
|---|---|---|
| `bin/radiant_modtools.exe` | yes | Actual on-disk casing is `bin/Radiant_modtools.exe`. Windows is case-insensitive, but match the real casing in code and logs. |
| `bin/linker_modtools.exe` | yes | |
| `bin/cod2map64.exe` | yes | |
| `map_source/` | yes | Subfolders: `_prefabs`, `_prefabs_maya`, `_props`, `mp`, `zm` |
| `share/raw/scripts/` | yes | |
| `usermaps/` | yes | Under the Mod Tools root, not the game root. |

Other top-level folders in the Mod Tools root: `AssetWorks`, `archetypes`, `bin`, `deffiles`, `docs_modtools`, `gdtdb`, `model_export`, `radiant`, `rex`, `share`, `sound`, `source_data`, `sw4`, `texture_assets`, `zone`, `zone_source`, `win64`, plus `modtools_launcher.bat` and `modtools_setenv.bat`.

### Open questions

- How does the game find maps built in the Mod Tools `usermaps/` folder when the two installs are separate? `BO3_GAME_ROOT` has no `usermaps/` or `mods/` folder. Check what the Launcher passes on the command line, or whether it relies on an environment variable or a junction (`VERIFY`).
- The game folder also contains third-party clients (`t7x.exe`, `ezzboiii.exe`, `boiii_players`). Note them for `game_launch_map`; do not assume stock `BlackOps3.exe` is the launch path.
- Still to do: `bin/` DLL inventory and Qt version, compiler/runtime from PE headers, `.map` format from samples, Launcher command lines, reload-on-disk-change behaviour, community prior art.
