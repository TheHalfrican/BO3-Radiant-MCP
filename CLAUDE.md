# radiant-mcp

Live Claude Code integration for Radiant Black (Call of Duty: Black Ops III Mod Tools), for building custom Zombies maps.

## Goal

Give Claude Code the same kind of control over Radiant that Blender MCP gives over Blender: query the scene, create and edit brushes and entities, run editor commands, see the viewport, and compile and launch maps. There is no official API. We build one by injecting a DLL into `radiant_modtools.exe`.

## Ground rules

1. **Verify, never assume.** Everything in this file marked `VERIFY` is a belief, not a fact. Confirm it against the real install before building on it, then record the result in `docs/findings.md`.
2. **Log every discovery.** Addresses, signatures, Qt object names, file format details, dead ends. `docs/findings.md` is the project's memory. Read it at the start of every session.
3. **Never modify the BO3 install in place.** Do not patch `radiant_modtools.exe` on disk. Injection is runtime only. Do not edit stock files under `share/raw`.
4. **Never touch a .map without a backup.** Copy to `backups/<name>.<timestamp>.map` before any write. Test only on maps under `map_source/zm/zm_mcp_test*`.
5. **No Activision code in this repo.** No binaries, no decompiled function bodies, no stock scripts. Commit only our own code plus addresses, signatures, and byte patterns.
6. **Ask before anything destructive or irreversible.** Deleting maps, mass edits, force-killing Radiant with unsaved work.
7. **Stop and report when stuck.** If an RE target resists after a reasonable effort, write up what was tried in findings and ask, rather than guessing at a signature and shipping a crash.

## Environment

- Windows 11, x64. Dev machine: i9-14900K, RTX 4090.
- Two install roots, both set in `.env`. Never hardcode either. On this machine Steam installed the Mod Tools as a separate app, not inside the game folder (see `docs/findings.md`).
  - `BO3_ROOT`: the Mod Tools install (Steam app 455130, folder `Call of Duty Black Ops III 455130`).
  - `BO3_GAME_ROOT`: the game install (Steam app 311210, folder `Call of Duty Black Ops III`), which holds `BlackOps3.exe`.
- Toolchain: MSVC (Visual Studio Build Tools, x64), CMake, Node.js LTS, Ghidra.
- Key paths under `BO3_ROOT` (all verified to exist on 2026-10-02):
  - `bin/Radiant_modtools.exe`: the target (note the capital R on disk)
  - `bin/linker_modtools.exe`, `bin/cod2map64.exe`: build tools
  - `map_source/`: .map files
  - `share/raw/scripts/`: stock GSC/CSC, read-only reference
  - `usermaps/<mapname>/`: per-map zone files, scripts, sound

## Architecture

```
Claude Code <--stdio--> MCP server (TypeScript) <--named pipe, JSON-RPC--> bridge DLL (C++) inside Radiant
                              |
                              +--> .map parser, build tools (CLI), screenshot capture
```

- **`server/`**: TypeScript MCP server. Owns tool definitions, the .map parser, build tool wrappers, and the pipe client. Must work with Radiant closed (file and build tools only) and degrade cleanly when the pipe is down.
- **`bridge/`**: C++ DLL injected into Radiant. Runs a pipe listener thread, marshals every command onto Radiant's main thread, and returns JSON results.
- **`injector/`**: small C++ exe that launches or attaches to Radiant and loads the DLL.
- **`re/`**: Ghidra scripts and exported notes. No decompiled bodies.
- **`docs/`**: `findings.md`, `protocol.md` (pipe message schema), `map-format.md`.

### Threading rule (most important rule in the bridge)

The pipe thread never touches Radiant or Qt state. It only queues work onto the main thread and waits for the result. Any direct call from the pipe thread is a bug even if it appears to work.

### Protocol

JSON-RPC 2.0, newline-delimited, over `\\.\pipe\radiant-mcp`. Every request has a timeout. Every bridge handler is wrapped so an exception returns an error object instead of crashing Radiant. Schema lives in `docs/protocol.md` and is the single source of truth for both sides.

## Phases

Do them in order. Do not start a phase until the previous one meets its exit criteria.

### Phase 0: Recon (no code)

- Inventory `bin/`: list DLLs, confirm whether Radiant uses Qt and which exact version (`VERIFY`: believed Qt 5; read version info from the DLLs).
- Identify compiler and runtime from the PE headers and imports.
- Confirm .map files are plaintext and document the format from real samples in `map_source/` (`VERIFY`).
- Capture the exact command lines the Launcher uses for compile, light, and link (watch process creation while building a stock map).
- Check whether Radiant reloads a .map changed on disk, and how (`VERIFY`).
- Check for any existing community hooks into BO3 Radiant. Prior art for CoD4: iw3xo-radiant.
- **Exit:** `docs/findings.md` answers all of the above with evidence.

### Phase 1: File and build tools (no injection)

- .map parser and writer with lossless round-trip (parse then write must be byte-identical on stock maps).
- MCP tools: `map_list_entities`, `map_get_entity`, `map_set_kvp`, `map_add_entity`, `map_delete_entity`, `map_add_brush_box`, `build_compile`, `build_link`, `game_launch_map`, `viewport_screenshot`.
- Build tools return parsed errors, not raw log dumps.
- **Exit:** Claude can add a spawner and a zone volume to the test map, compile, link, and launch it, entirely through MCP tools. Test layers 1 to 4 and 6 are green in CI or locally as applicable.

### Phase 2: Injection and Qt surface

- Injector plus bridge DLL with pipe listener and main-thread dispatch. First command: `ping`.
- Enumerate the Qt object tree: windows, widgets, QActions with names, shortcuts, and enabled state.
- MCP tools: `radiant_list_actions`, `radiant_trigger_action`, `radiant_get_open_map`, `radiant_save`, `radiant_reload`.
- **Exit:** Claude can trigger any menu command by name and survive 100 consecutive commands without a crash.

### Phase 3: Internal hooks

- Locate in Ghidra, in priority order: selection get/set, entity KVP get/set, entity create/delete, brush create from bounds, transform selection, camera get/set, undo push.
- Identify each function by byte pattern, not fixed address, and resolve at load. Record both in findings.
- Every mutation must go through Radiant's own undo system. If undo cannot be reached for an operation, say so and gate that tool behind a confirmation.
- MCP tools: `scene_query`, `scene_select`, `entity_create`, `entity_set_kvp`, `brush_create`, `selection_transform`, `camera_set`, `camera_screenshot`.
- **Exit:** Claude can block out a small room with spawners and a zone, live in Radiant, with every step undoable.

### Phase 4: Zombies workflow tools

Higher-level tools built on the above: zone setup and adjacency, spawner and riser placement, perk and wallbuy prefabs, zone file and sound alias generation, GSC/CSC scaffolding checked against stock scripts.

## Reverse engineering workflow

1. State the target behavior ("the function that creates a brush from two points").
2. Find anchors: Qt action names, strings, error messages, imports.
3. Trace from anchor to candidate functions. Record candidates and why.
4. Confirm with a read-only hook (log arguments) before ever calling it.
5. Only then call it, on the test map, with a backup.
6. Write the findings entry: purpose, pattern, signature, calling convention, threading requirements, confidence level.

## Code conventions

- **C++:** C++20, MSVC, `/W4`, no exceptions crossing the hook boundary. MinHook for detours, nlohmann/json for JSON. If linking Qt, the headers must match Radiant's exact Qt version.
- **TypeScript:** strict mode, official MCP SDK, zod schemas for every tool input. Tool descriptions state units, coordinate system, and whether the tool needs Radiant running.
- **Tools are small and composable.** Return structured JSON. Errors say what failed and what to try next.

## Testing

A full test suite is a requirement, not a nice-to-have. No tool, parser feature, or bridge handler is done until it has tests, and no phase exits with a red suite.

### Layers

1. **Server unit tests (Vitest).** .map parser and writer, build log parsers, tool input schemas, error mapping. Include property-based tests (fast-check) for the parser: generated maps must survive parse, write, parse with identical structure.
2. **Protocol tests.** The server's pipe client against a mock bridge: happy paths, timeouts, malformed responses, pipe drop mid-request, reconnect. The mock is generated from `docs/protocol.md` so the schema cannot drift.
3. **Bridge unit tests (Catch2).** Everything in the DLL that does not need Radiant is built as a static lib and tested in a normal exe: JSON dispatch, the main-thread work queue, the pattern scanner (against fixture byte buffers), error wrapping.
4. **MCP tool tests.** Each tool called through the MCP SDK's in-memory client, with the file system pointed at a temp dir and the bridge mocked.
5. **Live integration tests.** Tagged `live`. Require a real Radiant with the bridge injected and operate only on `zm_mcp_test*` maps. Each test restores the map from backup afterwards. Cover every bridge handler, undo for every mutation, and a 100-command soak.
6. **End-to-end.** Tagged `e2e`. Add entities, compile, link, and confirm the build artifacts exist. Launching the game is a manual smoke step in `docs/smoke.md`.

### Fixtures

- Stock maps are Activision content and must never be committed. Committed fixtures are handmade maps under `server/test/fixtures/`, created by us in Radiant, covering brushes, patches, entities, prefab references, and odd formatting.
- Lossless round-trip tests against stock maps read from `BO3_ROOT` at test time and skip with a clear message when it is not set.
- Build log fixtures are trimmed to our own maps' output.

### Rules

- Layers 1 to 4 run with no BO3 install and no Radiant. They must pass in CI on a clean Windows runner.
- Layers 5 and 6 run locally before any push that touches `bridge/`, `injector/`, or a live tool.
- A bug fix starts with a failing test that reproduces it.
- Coverage target: 90% lines on `server/`, and every bridge handler exercised by at least one live test. Report coverage in CI; do not chase the number with meaningless tests.
- Flaky tests get fixed or deleted, never retried into passing.

## Source control and remotes

Gitea is the single source of truth. GitHub is a backup copy:

- `origin`: the repo on Noah's Gitea instance. The only remote we push to. URL in `.env` as `GITEA_REMOTE`.
- GitHub: a **public** repo that Gitea push-mirrors to automatically. URL in `.env` as `GITHUB_REMOTE` for reference only. Never add it as a remote and never push to it directly.

Because of the mirror, **anything pushed to `origin` becomes public on GitHub**, so the public pre-push check guards every push to `origin`.

If a repo, remote, or mirror is missing or broken, ask Noah to fix it. Do not create repos, change mirror settings, or change visibility yourself.

### Workflow

- Work on short-lived branches, merge to `main` when the suite is green.
- Push `main` to `origin` after every merged step, with the public pre-push check passing. Gitea mirrors it to GitHub.
- Conventional commit messages (`feat:`, `fix:`, `re:`, `test:`, `docs:`).
- Tag phase completions: `phase-0`, `phase-1`, and so on.

### Public pre-push check (`scripts/check-public.*`, also a pre-push hook)

Every push to `origin` is mirrored to the public GitHub repo, so ground rule 5 is enforced mechanically on every push. The check fails the push if the diff contains any of:

- Files from the BO3 install: `.exe`, `.dll`, `.ff`, `.xpak`, `.gsc`/`.csc` copied from `share/raw`, stock `.map` or `.gdt` files.
- Decompiled or disassembled function bodies (Ghidra export formats, large pseudo-C blocks under `re/`).
- `.env`, local paths containing a username, Gitea hostnames or internal IPs, tokens.
- Anything under `backups/`.

`.gitignore` covers the same list, but the check is the backstop. If it fails, fix the commit; never bypass with `--no-verify`.

### CI

- GitHub Actions on `windows-latest`: build server, bridge static lib, and injector; run layers 1 to 4; publish coverage.
- Mirror the workflow to Gitea Actions if the instance has a Windows runner (`VERIFY`); otherwise GitHub CI is the gate.
- Live and e2e layers never run in CI.

### Public repo hygiene

- `README.md` explains what the project is, that it requires a legally owned copy of BO3 and its Mod Tools, and that it ships no game code or assets.
- `LICENSE`: MIT.

## Commands

Fill these in as they are created. Keep this list current.

- Build bridge and injector: `TODO`
- Build server: `TODO`
- Run unit, protocol, and tool tests: `TODO`
- Run bridge unit tests: `TODO`
- Run live tests (Radiant running, bridge injected): `TODO`
- Run e2e tests: `TODO`
- Run public pre-push check: `bash scripts/check-public.sh` (checks commits not yet on `origin/main`; pass a range to check other commits)
- Install the pre-push hook (once per clone): `git config core.hooksPath scripts/hooks`
- Push: `git push origin main` (Gitea mirrors to GitHub)
- Inject into running Radiant: `TODO`
- Capture process command lines (RE helper, keep the output out of the repo): `pwsh scripts/watch-processes.ps1 -OutFile <scratch file> -Seconds 1800`

## Session checklist

1. Read `docs/findings.md`.
2. Check which phase is active and what its exit criteria are.
3. Work in small steps. Write the tests with the code. Commit after each working step.
4. Run the suite. Push `main` to `origin` (the pre-push hook runs the public check; Gitea mirrors to GitHub).
5. Update findings and this file's Commands section before ending.
