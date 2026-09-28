# StoryEngine — AI Story Engine for Project Zomboid (Build 42)

Radio contacts you can talk to, an AI director that throws events at you, quests with real rewards,
a survival journal and an inner monologue. Unofficial fan-made mod, not affiliated with The Indie Stone.

한국어: 무전으로 대화하는 생존자들, 사건을 일으키는 AI 디렉터, 실제 보상이 있는 퀘스트, 생존 일지와 혼잣말을 더하는 프로젝트 좀보이드 B42 모드입니다.

- Steam Workshop: https://steamcommunity.com/sharedfiles/filedetails/?id=3808950035
- AI bridge (optional, host PC only): https://github.com/LeArc6910/PZ-StoryEngine-Bridge

## Features

- 8 radio contacts with their own personality, trust, specialty rewards and trades
- Contacts call you on their own, have branching personal stories, gossip about what you did, and talk among themselves on an open channel
- Crises where several groups ask for help at once and your choice changes their stories
- Characters standing together talk to each other (multiplayer)
- AI director: supply drops, storms, requests, distress calls, hordes that follow you, helicopters, threats
- Quests with deadlines and tiers, shared by everyone on the server; rewards placed in real containers and marked on the map
- Survival journal every in-game midnight (readable by everyone on the server), memoir when you die, inner monologue
- Uses items from other mods for rewards (tested with Vanilla Foods Expanded, Modern Firearms System)
- Optional Project A-Life [ALIFE NPCS] integration: armed backup from trusted contacts, armed men from hostile ones
- Sandbox options for each part

Without the bridge the mod runs rule-based events and prepared lines. The AI features need the
[StoryEngine Bridge](https://github.com/LeArc6910/PZ-StoryEngine-Bridge) running on the host / server PC with your own API key.

## Repository layout

| Path | Purpose |
|---|---|
| `mod/StoryEngine/42/` | the mod (Lua, scripts, translations, sandbox options) |
| `mod/StoryEngine/common/` | required by Build 42 |
| `docs/DEVELOPMENT.md` | development guide (protocol, test procedures) |
| `docs/WORKSHOP_DESCRIPTION.txt` | Steam Workshop description (BBCode) |
| `CLAUDE.md` | design notes and verified Build 42 API facts |
| `sync_workshop.bat` | copy the mod into `%USERPROFILE%\Zomboid\Workshop\StoryEngine` for uploading |
| `start_zomboid_debug.bat` | start the game in debug mode |

The bridge lives in its own repository. Clone it into `bridge/` if you want to use `start_bridge.bat` from this folder.

## Install for development

Link or copy `mod/StoryEngine` into `%USERPROFILE%\Zomboid\mods\StoryEngine` and enable "AI Story Engine [DEV]" in the game's mod list
(the repo copy uses the id `StoryEngineDev` so it does not clash with the Workshop release `StoryEngine`; `sync_workshop.bat`
switches the uploaded copy back to the release id). Do not enable both at once. Run the bridge next to the game (`python bridge.py --mock` works without an API key).
