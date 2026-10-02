# radiant-mcp

Live [Claude Code](https://claude.com/claude-code) integration for Radiant Black, the level editor in the Call of Duty: Black Ops III Mod Tools. The goal is to let Claude query and edit a map, run editor commands, see the viewport, and compile and launch maps, aimed at building custom Zombies maps.

Radiant has no official API, so this project provides one: an MCP server (TypeScript) that talks over a named pipe to a bridge DLL injected into the running editor at runtime.

**Status:** early. Phase 0 (research) is in progress. Nothing usable yet.

## Requirements

- A legally owned copy of Call of Duty: Black Ops III and the Black Ops III Mod Tools, both from Steam.
- Windows 11 x64.

## What this repo does not contain

This repository ships **no game code or assets**. It contains no Activision binaries, no decompiled code, no stock scripts, maps, or asset files. Everything here is original code plus notes such as addresses and byte patterns. You need your own Mod Tools install for anything to work.

The injected DLL is loaded into the editor at runtime only. Nothing in the game or Mod Tools install is patched on disk.

## License

[MIT](LICENSE). Call of Duty and Black Ops are trademarks of Activision Publishing, Inc. This project is not affiliated with or endorsed by Activision.
