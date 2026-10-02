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
- `game_launch_map` must therefore launch the game itself from `BO3_GAME_ROOT` rather than drive the Launcher's Run. Expected command: `BlackOps3.exe +devmap <mapname>` (inferred from strings, `VERIFY` by launching).

### Open questions

- How does the game find maps built in the Mod Tools `usermaps/` folder when the two installs are separate? `BO3_GAME_ROOT` has no `usermaps/` or `mods/` folder. Check what the Launcher passes on the command line, or whether it relies on an environment variable or a junction (`VERIFY`).
- The game folder also contains third-party clients (`t7x.exe`, `ezzboiii.exe`, `boiii_players`). Note them for `game_launch_map`; do not assume stock `BlackOps3.exe` is the launch path.
- Still to do (needs Noah at the keyboard): Launcher command lines for compile, light, and link; whether Radiant reloads a `.map` changed on disk; how "Run Map" finds the game executable with the split install.
