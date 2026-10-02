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

### Mod Tools environment variables (2026-10-02, verified from batch files)

`modtools_launcher.bat` sets `TA_GAME_PATH`, `TA_TOOLS_PATH` (both the Mod Tools root, with trailing `\`) and `TA_LOCAL_ASSET_CACHE` (`share\assetconvert\`), persists them with `setx`, then runs `bin\modlauncher.exe`. `modtools_setenv.bat` does the same without launching. On this machine none of the `TA_*` variables are currently set in `HKCU\Environment` or the system environment. Build tool wrappers should set them explicitly for child processes rather than rely on the user environment. Whether the tools need them at all is still `VERIFY` (see Launcher capture below).

### `bin/` inventory (2026-10-02, verified with PowerShell `VersionInfo` and `dumpbin`)

Executables: `Radiant_modtools.exe` (70 MB), `asseteditor_modtools.exe` (APE), `cod2map64.exe`, `linker_modtools.exe`, `modlauncher.exe`, `export2bin.exe`, `umbraconvert.exe`, `GdtDBTray.exe`, `GdtDBTrayLauncher.exe`, `CrashUploader.exe`. None carry version resources.

Third-party DLLs, all renamed with a `64r` suffix: Qt 5 (see below), ICU 53.1 (`icu*64r53.dll`), zlib 1.2.8, sqlite, pcre, freetype, harfbuzz, libpng, libjpeg, libtiff, openexr, embree 2.3.3, ispc_texcomp, AngelScript, ANGLE (`libEGL64r`, `libGLESv264r`), `libGLSLang64r`, `jansson64r`. Microsoft: `D3DCOMPILER_46.dll`, `D3DCOMPIL64_47.dll`, `dbghelp.dll` 6.11. Valve: `steam_api64.dll`. Subfolders: `avx/`, `Qt5Modules64r/plugins/` (Qt plugins: `platforms/qwindows.dll`, image formats, sql drivers, styles, etc.). No `qt.conf`.

### Qt (2026-10-02, verified, confidence high)

- **Qt 5.3.2** (FileVersion `5.3.2.0`, "Digia Plc") for `Qt5Core64r`, `Qt5Gui64r`, `Qt5Widgets64r`, `Qt5Network64r`, `Qt5Sql64r`, `Qt5Concurrent64r`.
- **DLL names are non-standard** (`Qt5Core64r.dll`, not `Qt5Core.dll`). To link the bridge against Radiant's Qt we need import libs generated for these exact names (`dumpbin /exports` -> `.def` -> `lib /def`), or resolve symbols at runtime with `GetProcAddress`. Headers must be Qt 5.3.2.
- **No `QT_NAMESPACE`**: exports are plain (`??0QObject@@QEAA@PEAV0@@Z`, `?staticMetaObject@QObject@@2UQMetaObject@@B`, `qVersion`). `Qt5Core64r.dll` exports 6575 symbols.
- Qt DLLs import `MSVCR110.dll`/`MSVCP110.dll`, so Qt was built with VS2012 like Radiant.

### `Radiant_modtools.exe` PE facts (2026-10-02, verified with `dumpbin /headers /dependents`)

| Field | Value |
|---|---|
| Machine | x64 |
| Timestamp | `0x5DF45023` (2019-12-13) |
| Linker | 11.00 (Visual Studio 2012); CRT `MSVCR110.dll` + `MSVCP110.dll` |
| Subsystem | Windows GUI |
| Image base | `0x140000000`, size `0x6D95000` |
| Entry point RVA | `0x18F6828` |
| DLL characteristics | `0x8120`: high-entropy VA, NX, terminal-server aware. **No `DYNAMIC_BASE`** |
| Relocations | **Stripped** (base relocation directory is empty) |
| CFG | Not enabled |
| Exports | None |
| Debug directory | RSDS, PDB path `Q:\t7\pc\tools\bin\Radiant_ModTools.pdb` (internal build path). No PDB ships with the install. |

Implications:
- The exe always loads at `0x140000000`, so static addresses are stable for this build. We still resolve by byte pattern per CLAUDE.md, and the pattern scanner can sanity-check its result against the recorded address.
- Radiant imports `Qt5Widgets64r`, `Qt5Core64r`, `Qt5Gui64r`, `Qt5Concurrent64r`, `Qt5Sql64r`, plus D3D9, D3D11/DXGI, `dbghelp`, `WS2_32`, `WLDAP32`, zlib, sqlite, openexr, embree, `ispc_texcomp64r`, `D3DCOMPILER_46`.
- C++ ABI risk: our bridge will be built with a modern MSVC (v14.5x) while Radiant and Qt use VS2012 (v11). MSVC name mangling and class layout are compatible across these versions for Qt's API, but we must never pass CRT or STL objects (`std::string`, `FILE*`, heap memory freed on the other side) across the boundary. Only Qt types allocated and freed by Qt itself.

### `.map` format (2026-10-02, from stock samples, confidence medium; full spec goes in `docs/map-format.md` in Phase 1)

- 718 `.map` files under `map_source/`. `map_source/zm/` holds only `zm_giant.map` (190 KB). The rest are prefabs under `_prefabs/`, `_props/`, `mp/`.
- **Plaintext, CRLF line endings.** First line is always `iwmap 4` (all 718 files).
- Header after `iwmap 4`: `"script_startingnumber" 0`, then one line per layer: `"<layer/path>" flags <flag words>`, e.g. `"000_Global/DO NOT COMPILE" flags hidden ignore `. Flag words seen: `expanded`, `active`, `hidden`, `ignore`, `prefab`. Many lines have a **trailing space**, and one has a double space (`flags  active`), so round-trip must preserve whitespace exactly.
- Entities: `// entity N` comment, `{`, `guid "{GUID}"`, optional `layer "<path>"`, then `"key" "value"` lines, then nested brushes and patches, `}`. Entity 0 is `worldspawn`.
- Brushes: `// brush N`, `{`, ` guid "{GUID}"` (**leading space**), `layer "<path>"` (no leading space), optional ` contents <words>;` and `toolFlags;` lines, then one face per line: ` ( x y z ) ( x y z ) ( x y z ) <material> <w> <h> <xoff> <yoff> <rot> <?> lightmap_gray <lw> <lh> <lxoff> <lyoff> <lrot> <?>`. Floats appear both as integers and with up to 7+ decimals, so the writer must keep the original text.
- Patches: `curve { ... }` and `mesh { ... }` blocks inside brush-level `{}`. They contain optional `contents ...;` and `toolFlags;` lines, the material, `lightmap_gray`, a 4-number dimension line (e.g. `9 3 16 1`), then rows `( ... )` of `v x y z t u v lu lv` vertices, **tab-indented**.
- Prefab references are entities with `"classname" "misc_prefab"`, `"model" "_prefabs/.../name.map"`, `"origin" "x y z"`.
- Some prefab file names contain spaces (e.g. under `_prefabs/mp/mp_combine/...`). Tools must quote paths.

### Prior art (2026-10-02)

- [iw3xo-radiant](https://github.com/xoxor4d/iw3xo-radiant) (xoxor4d): CoD4 Radiant modification, C++. CoD4 Radiant is MFC, not Qt, so its hooks will not transfer, but its approach (DLL loaded into the editor, live game-to-editor sync) is the reference design.
- No public hook, plugin, or injected-DLL project for BO3 Radiant (`Radiant_modtools.exe`) was found in a web search. Community forums (ModMe, Mappers United) not yet searched in depth.

### Launcher "Run" with the split install (2026-10-02, verified)

- With only **Run** ticked, clicking Build in the Launcher does nothing: no child process starts and no error is shown.
- Cause: `modlauncher.exe` launches `%1/BlackOps3.exe` where `%1` is `TA_GAME_PATH` (the Mod Tools root). Strings in `modlauncher.exe`: `%1/BlackOps3.exe`, `+devmap`, `-fs_game`, `fs_game`, `%1/usermaps/%2`, `TA_GAME_PATH`. `BlackOps3.exe` does not exist under the Mod Tools root, so Run silently fails. This is Steam's default install of app 455130, not a user mistake.
- Fix applied with Noah's approval: a directory junction `BO3_GAME_ROOT/usermaps` -> `BO3_ROOT/usermaps` (`New-Item -ItemType Junction`). No existing files changed; removing the junction fully reverts it. The game folder now sees built zones (`usermaps/zm_mcp_test/zone/zm_mcp_test.ff`, `.xpak`).
- `game_launch_map` must therefore launch the game itself rather than drive the Launcher's Run.

### Launching the game directly (2026-10-02, partially verified)

- Running `BO3_GAME_ROOT/BlackOps3.exe +devmap zm_mcp_test` directly: the process exits within seconds and **Steam relaunches it** (Steam restart-if-necessary behaviour). Steam preserved the arguments.
- On this machine Steam's BO3 launch options wrap the game in Noah's own `BO3Z_Tool_AutoAttach\Trigger.cmd %command%`. The relaunched process was `blackops3.exe  +devmap zm_mcp_test` (PID seen, ~1.3 GB working set). Any launch tool must tolerate a launch-option wrapper sitting between Steam and the game.
- Plan for `game_launch_map`: `steam.exe -applaunch 311210 +devmap <map>` (`VERIFY`), so launch options apply and no exit-and-relaunch happens.
- **Result: `+devmap` did not take effect.** The game showed the "press Enter to start" screen and then stopped at the main menu, not in the map. The in-game console (`~`) would not open either.
- Not yet known why. Things to try next session, one at a time:
  1. From the main menu, load the map through the in-game UI (Zombies -> custom maps / Mods menu), to confirm the built zone is valid and visible through the junction at all.
  2. `steam.exe -applaunch 311210 +devmap zm_mcp_test` instead of the direct exe (the restart may drop or reorder args, or the wrapper may).
  3. Launch with the Steam launch options temporarily cleared, to rule out the AutoAttach wrapper (ask Noah first; it is his setup).
  4. Check whether the console needs to be enabled (e.g. a `+set` dvar on the command line) before `devmap` can run.
  5. Look for a game console log under `BO3_GAME_ROOT` (e.g. `players/`, `boiii_players/`, `console_mp.log`-style files) written during the launch.

### Launcher build command lines (2026-10-02, verified by process capture)

Captured with `scripts/watch-processes.ps1` while Noah built `zm_mcp_test` from the ZM template with Compile + Light + Link ticked. `<BO3_ROOT>` stands for the Mod Tools root. Note the Launcher emits doubled backslashes and a stray `\/` after the root; the tools accept them.

Steam starts the tools with `steam.exe -silent -applaunch 455130`, which runs `cmd /c modtools_launcher.bat` (sets `TA_*` via `setx`), which runs `bin\modlauncher.exe`. On start `modlauncher.exe` runs `gdtdb\gdtdb.exe /update`.

| Step | Parent | Command line |
|---|---|---|
| Pre-build | modlauncher | `<BO3_ROOT>\gdtdb\gdtdb.exe /update` |
| Compile | modlauncher | `<BO3_ROOT>\bin\cod2map64.exe -platform pc -navmesh -navvolume -loadFrom "<BO3_ROOT>\map_source\zm\zm_mcp_test.map" "<BO3_ROOT>\share\raw\maps\zm\zm_mcp_test.d3dbsp"` |
| Light | modlauncher | `<BO3_ROOT>\bin\radiant_modtools.exe -ledSilent +high +localprobes +forceclean +recompute "<BO3_ROOT>/map_source/zm/zm_mcp_test.map"` |
| (inside Light) | Radiant | `<BO3_ROOT>\gdtDB\gdtdb.exe /verbose /update` |
| Link | modlauncher | `<BO3_ROOT>\bin\linker_modtools.exe -language english -modsource zm_mcp_test` |
| (inside Link) | linker | `<BO3_ROOT>\bin\UmbraConvert -input_scene=c:\UmbraDebug\zm_mcp_test_linker.scene -input_params=c:\UmbraDebug\zm_mcp_test_linker.params -output_tome=c:\UmbraDebug\zm_mcp_test.tome -compress -use_all_cores -disable_sndbs` |
| (inside Link) | linker | `<BO3_ROOT>\sound\snd_convert.exe pc usermaps\zm_mcp_test usermaps\zm_mcp_test zone_source usermaps\zm_mcp_test all zm_mcp_test` |
| (inside Link) | linker | `<BO3_ROOT>\bin\linker_modtools.exe -language english -modsource -spawnedchild -localized zm_mcp_test` |
| (inside child linker) | linker | `<BO3_ROOT>\sound\snd_convert.exe pc usermaps\zm_mcp_test usermaps\zm_mcp_test zone_source usermaps\zm_mcp_test english zm_mcp_test` |

Notes:
- **Lighting is Radiant itself** running headless (`-ledSilent`). The injector must not attach to, or be confused by, a lighting-mode Radiant process. Tell them apart by the `-ledSilent` argument.
- The compile output goes to `share\raw\maps\zm\<map>.d3dbsp` under the Mod Tools root.
- UmbraConvert uses a hard-coded `c:\UmbraDebug\` scratch folder.
- `snd_convert` paths are relative, so the linker's working directory is the Mod Tools root (`VERIFY` when writing the wrapper).
- Timing on this machine for the empty ZM template: compile + light ~35 s, link ~1.5 min.
- Build output: `usermaps/zm_mcp_test/zone/` with `zm_mcp_test.ff` (24 MB), `zm_mcp_test.xpak` (146 MB), `en_zm_mcp_test.ff`, `en_zm_mcp_test.xpak`, `loadingimage.png`, `previewimage.png`, `snd/`.
- The Launcher's "New" map (ZM template) created `map_source/zm/zm_mcp_test.map` and `usermaps/zm_mcp_test/`.

### Open questions

- How does the game find maps built in the Mod Tools `usermaps/` folder when the two installs are separate? `BO3_GAME_ROOT` has no `usermaps/` or `mods/` folder. Check what the Launcher passes on the command line, or whether it relies on an environment variable or a junction (`VERIFY`).
- The game folder also contains third-party clients (`t7x.exe`, `ezzboiii.exe`, `boiii_players`). Note them for `game_launch_map`; do not assume stock `BlackOps3.exe` is the launch path.
- Still to do (needs Noah at the keyboard), to close Phase 0:
  1. Get `zm_mcp_test` loading in game (see "Launching the game directly" above).
  2. Whether Radiant reloads a `.map` changed on disk: Noah opens `zm_mcp_test` in Radiant, Claude backs the map up to `backups/` and makes a harmless on-disk edit, Noah reports whether Radiant notices. Close Radiant without saving afterwards.
  3. Optional: search ModMe and Mappers United for BO3 Radiant prior art.
