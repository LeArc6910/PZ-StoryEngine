# 개발 가이드

설계 원칙과 모듈 개요는 [CLAUDE.md](../CLAUDE.md)가 기준입니다. 이 문서는 **어떻게 만들고, 어디에 두고, 어떻게 테스트하는지**를 다룹니다.
아직 코드가 없는 단계에서 정한 규약이므로, 구현하면서 달라지는 부분은 이 문서를 먼저 고치세요.

---

## 1. 저장소 구조

```
ai 모드/
├─ CLAUDE.md                      설계 기준 문서
├─ docs/
│  └─ DEVELOPMENT.md              이 문서
├─ bridge/                        브릿지 프로세스 (Python 3.11+, mock 모드는 표준 라이브러리만)
│  ├─ bridge.py                   진입점: 요청 폴링 → LLM 호출 → 응답 쓰기, heartbeat
│  ├─ modules.py                  모듈별 프롬프트 조립 (게임 payload → LLM 요청)
│  ├─ providers/                  mock.py, anthropic_provider.py (공식 anthropic SDK)
│  ├─ prompts/                    모듈별 시스템 프롬프트 (debug.md, 이후 director.md 등)
│  ├─ tests/                      프로토콜 테스트 (unittest)
│  └─ config.example.toml         API 키·모델·한도 (실제 config.toml은 커밋 금지)
└─ mod/
   └─ StoryEngine/                → Zomboid/mods 또는 Workshop/…/Contents/mods 에 링크
      ├─ common/                  (B42 필수 폴더, 비워둬도 됨)
      └─ 42/
         ├─ mod.info
         └─ media/
            ├─ lua/
            │  ├─ shared/StoryEngine/   Core.lua (설정·로그), Json.lua, Net.lua (클라↔서버 전달)
            │  ├─ shared/Translate/     EN/, KO/ (ContextMenu.json, IG_UI.json)
            │  ├─ server/StoryEngine/   Bridge.lua, Commands.lua
            │  │                        이후 Sensor/, Aggregator/, StoryLog/, Director/, Radio/, Journal/, Monologue/
            │  └─ client/StoryEngine/   Client.lua (명령 수신·알림·디버그 메뉴), 이후 UI/, Reporter.lua
            └─ sandbox-options.txt      서버 옵션 (모듈 on/off, 한도)
```

B42 모드는 `mods/<이름>/42/`(버전 폴더)와 `mods/<이름>/common/`을 함께 둬야 인식됩니다.
설치된 워크샵 모드(`workshop/content/108600/1299328280/mods/More Traits/`)에서 확인한 구조입니다.
나중에 버전별 차이가 생기면 `42.20/`처럼 하위 버전 폴더를 추가합니다.

### Lua 네이밍 규칙

- 전역은 `StoryEngine` 테이블 하나만 만든다. 모든 모듈은 `StoryEngine.Director`, `StoryEngine.Sensor` 처럼 하위에 둔다.
- 네트워크 명령 module 이름은 `"StoryEngine"` 하나로 통일하고, command로 구분한다 (`"radioSend"`, `"sensorReport"`, `"journalShow"` …).
- 파일 상단에서 실행 측을 명시한다: `if isClient() then return end` (서버 전용), `if isServer() then return end` (클라 전용).
  싱글플레이는 두 조건이 모두 false이므로 **양쪽 코드가 모두 로드**된다는 점에 주의.

---

## 2. 전체 흐름

```
[Client]                     [Server Lua]                                  [Bridge]            [LLM]
Reporter ──sensorReport──▶  Sensor ─▶ Aggregator ─▶ StoryLog (ModData)
UI       ──radioSend─────▶  Radio ─┐
                            Director ├─▶ Core.Queue ─▶ requests/*.json ─▶ bridge.py ─HTTPS─▶ API
                            Journal ─┘                                        │
UI ◀──radioRecv/journal──  Core.Poll ◀── responses/*.json ◀──────────────────┘
```

- 게임 루프에서 블로킹 호출 금지. 요청은 파일을 쓰고 바로 반환, 응답은 주기 폴링으로 수거.
- LLM 결과가 게임 상태를 바꾸는 경로는 **Director → 화이트리스트 실행기** 하나뿐.

---

## 3. 브릿지 프로토콜 (파일 기반)

`getFileWriter`는 사용자 폴더의 `Zomboid/Lua/` 아래에 씁니다. 브릿지는 같은 폴더를 감시합니다.
인게임 호스트와 전용 서버에서 경로가 같은지는 **1단계에서 반드시 확인**하세요 (CLAUDE.md "확인 필요").

```
Zomboid/Lua/StoryEngine/
├─ requests/   <id>.json      게임 → 브릿지
├─ responses/  <id>.json      브릿지 → 게임
└─ heartbeat.json             브릿지가 5초마다 갱신 (게임은 이걸로 연결 상태 판정)
```

### B42 파일 API 제약 (게임 jar에서 확인)

- `getFileWriter(path, createIfNull, append)`: `Zomboid/Lua/` 기준 상대 경로. 상위 폴더를 자동으로 만들고 UTF-8로 쓴다.
- 쓸 수 있는 확장자는 **`ini`, `cfg`, `txt`, `log`, `json`뿐**이다. `..`가 들어간 경로는 거부된다.
- `getFileReader(path, false)`: 파일이 없으면 nil을 돌려준다.
- Lua에는 **파일 삭제나 이름 변경 API가 없다.** 정리는 전부 브릿지가 한다.

### 쓰기 규칙 (반쪽짜리 파일 방지)

- 게임: `requests/<id>.json`을 한 번에 쓰고 닫는다.
- 브릿지: JSON 파싱에 실패하면 쓰는 중으로 보고 5초 동안 기다린다. 그 뒤에도 실패하면 `bad_request` 응답을 쓴다. 파싱에 성공하면 요청 파일을 지우고 처리한다. 120초보다 오래된 요청은 버린다.
- 브릿지 응답: `<id>.json.tmp`에 쓰고 `os.replace`로 교체한다. 그래서 게임은 완성된 파일만 보게 된다.
- 게임은 응답을 읽은 뒤 **그 파일을 빈 파일로 덮어써서** 읽었음을 표시한다. 브릿지는 크기가 0인 응답 파일과 10분 넘게 남은 응답 파일을 지운다.
- 브릿지는 시작할 때 이전 세션의 응답 파일을 모두 지운다.

### 연결 상태 판정

- 브릿지는 2초마다 `heartbeat.json`의 `seq`를 1씩 올린다. 이 파일만은 `os.replace`가 아니라 제자리에 덮어쓴다. 교체하는 순간 게임이 파일을 열면 Windows 공유 위반이 나고, 게임이 콘솔에 스택 트레이스를 남기기 때문이다.
- 게임은 seq가 **바뀌는 것을 본 순간** 연결됨으로 판단한다. 처음 읽은 값은 이전 세션이 남긴 파일일 수 있어서 연결 판단에 쓰지 않는다.
- 15초 동안 seq가 바뀌지 않으면 연결 끊김으로 판단하고, 기다리던 요청을 모두 `bridge_offline`으로 실패 처리한다. 상태가 바뀔 때마다 모든 클라이언트에 알린다.

### 폴링 이벤트

- `OnTick`은 클라이언트 게임 루프(`IngameState`)에서만 발생한다. 그래서 전용 서버와 인게임 호스트의 서버 프로세스에서는 발생하지 않을 가능성이 높다.
- 서버 측 폴링은 `OnTick`, `EveryOneMinute`, `OnPlayerUpdate`에 모두 걸고, 실시간 500ms 간격으로 제한한다.
- 서버에서 `OnTick`이 정말 발생하지 않으면, 응답 지연은 게임 내 1분 단위로 늘어난다. 기본 하루 길이(1시간)에서는 실시간 약 2.5초다.

### 요청

```json
{
  "id": "D12-0930-dir-0001",
  "module": "director",
  "priority": 0,
  "created": {"day": 12, "hour": 9, "minute": 30},
  "player": null,
  "payload": { "...": "모듈별 입력 (아래 5장)" }
}
```

`priority`: 0 디렉터, 1 무전, 2 일지, 3 독백. 브릿지는 낮은 숫자부터 처리하고, 한도 초과 시 3→2 순서로 버린다.

### 응답

```json
{ "v": 1, "id": "debug-12345678-1", "ok": true, "text": "...", "model": "claude-opus-5", "ms": 1830,
  "json": { "event": "supply_drop", "intensity": 1, "reason": "..." } }
{ "v": 1, "id": "...", "ok": false, "error": "rate_limited" }
```

- 요청 id 형식: `<module>-<세션>-<순번>`. 파일 이름으로 쓰이므로 브릿지는 `[A-Za-z0-9_-]`만 허용한다.
- 한글은 `\u` 이스케이프 없이 UTF-8 그대로 쓴다.
- `json` 필드는 구조화 출력(JSON 스키마)을 요청한 모듈만 채운다.

오류 코드: `bridge_offline`, `timeout`, `write_failed` (게임 측), `bad_request`, `unknown_module`, `empty_text`, `rate_limited`, `auth`, `network`, `refusal`, `bad_json`, `server_error`, `internal` (브릿지 측).
게임은 `ok=false`를 받으면 **규칙 기반 폴백**으로 처리한다.

---

## 4. 관측 계층 데이터 스키마

모든 데이터는 전역 ModData `StoryEngine`에 저장한다 (세이브와 함께 저장되고 서버가 관리).

```lua
ModData.getOrCreate("StoryEngine") = {
  version  = 1,
  samples  = { [username] = { ...최근 N시간 롤링 버퍼 } },
  episodes = { ... },         -- 집계 완료된 에피소드
  quests   = { [questId] = { ... } },
  days     = { [day] = { [username] = DaySummary } },
  log      = { daily = {...}, weekly = {...} },   -- 압축된 스토리 로그
  home     = { [username] = {x=, y=, z=} },
}
```

### Sample (게임 내 10분마다, 플레이어별)

```lua
{ t = 1234,                  -- 게임 시작 후 경과 분
  x = 10632, y = 9812, z = 0,
  outside = false, building = "fire_station_rosewood",  -- 건물 ID/이름, 없으면 nil
  kills = 57,                -- 누적값 (차이는 집계기에서 계산)
  hp = 0.82, wounds = {"scratch_left_hand"},
  moodles = { Panic = 0, Bored = 2, Unhappy = 1 },
  zombiesNear = 3 }          -- 반경 30타일
```

### Episode

```lua
{ id = "E-12-03",
  day = 12, from = 9*60+10, to = 13*60+40,
  members = {"A", "B"},       -- 동행 클러스터
  place = "로즈우드 소방서",
  kills = { A = 11, B = 6 },
  harm  = { B = {"scratch"} },
  quest = { id = "Q12", event = "looted", by = "A" },
  interactions = { {type = "medical", from = "A", to = "B"} } }
```

### Quest

```lua
{ id = "Q12", kind = "supply_drop",
  target = {x=, y=, z=, building = "...", radius = 15},
  containerId = ..., itemTag = "Q12",
  state = "offered",  -- offered → approached → entered → looted → done | expired
  offeredAt = ..., expiresAt = ...,
  history = { {state = "approached", t = ..., by = "A", with = {"B"}} },
  combat = { kills = 0, harm = {} } }
```

- `approached` / `entered` 판정은 **서버 측 좌표**로 계산한다.
- `looted`는 서버가 상자 내용물에서 태그 아이템이 사라진 것 + 가져간 플레이어 인벤토리에 있는 것으로 판정한다.

### DaySummary와 하루 분류

| 분류 | 규칙 (초기값, 튜닝 대상) |
|---|---|
| `combat_day` | 킬 ≥ 15 또는 피해 발생 |
| `expedition` | 기지로부터 최대 거리 ≥ 300타일 |
| `local_scavenge` | 실외 체류 ≥ 60분 또는 최대 거리 ≥ 50타일 |
| `stayed_home` | 위 조건 모두 해당 없음 |

위에서부터 먼저 맞는 조건 하나로 분류한다. "집"은 멀티에서는 세이프하우스, 싱글에서는 최근 3일 동안 잠든 위치의 최빈값을 쓴다.

### 동행 클러스터링

- 샘플 시점마다 같은 z층, 20타일 이내 플레이어를 union-find로 묶는다.
- 같은 멤버 구성이 샘플 2회(20분) 이상 유지되면 에피소드를 열고, 구성이 바뀌면 닫는다.

---

## 5. 모듈별 구현 메모

### Director

- 호출: 게임 내 하루 2회 (08:00, 20:00). 싱글과 멀티 모두 서버에서 1개만 돈다.
- 입력: 플레이어별 `DaySummary` 최근 3일 + 서버 전체 요약 + **선택 가능한 이벤트 목록**. 무전으로 플레이어가 입력한 원문은 넣지 않는다.
- 출력 검증 순서: JSON 파싱 → 스키마 검사 → `event` 화이트리스트 확인 → `intensity` 범위 확인 → 대상 플레이어 존재 확인. 하나라도 실패하면 `quiet_day`로 처리.
- 이벤트는 `Director/Events/<name>.lua` 하나에 하나씩 둔다. 인터페이스:

```lua
return {
  name = "storm",
  canRun  = function(ctx) return true end,   -- 전제조건 (날씨 쿨다운 등)
  run     = function(ctx, intensity) end,     -- 실제 실행
  fallbackWeight = 1,                         -- 브릿지 불통 시 규칙 기반 선택 가중치
}
```

- 1차 화이트리스트: `quiet_day`, `storm`, `supply_drop`. 그다음 `horde_nearby`, `radio_distress`, `helicopter` 순서로 추가한다 (헬기는 API 확인 후).

### Radio

- 채널: `DynamicRadioChannel` 방식으로 AI 전용 주파수 채널을 추가한다 (`server/radio/ISDynamicRadio.lua`, `ISWeatherChannel.lua` 참고).
- 플레이어 발신은 커스텀 입력 UI → `sendClientCommand("radioSend")`.
- 수신 프롬프트에는 스토리 로그 발췌, 진행 중 퀘스트, 근처 실제 건물 목록을 넣는다. 좌표는 **모드가 준 것만** 언급하도록 프롬프트와 후처리 양쪽에서 강제한다.

### Journal

- 트리거: 게임 내 자정 (`Sensor.listeners.dayEnd`, 날짜가 바뀐 첫 샘플에서 어제를 닫기 직전. 자정에 접속해 있지 않았으면 다시 접속한 첫 샘플에서 마지막 날), 사망 시 (`OnPlayerDeath`).
- 열람: 일지 탭 왼쪽에 서버에서 일지를 쓴 모든 캐릭터(나 → 접속 중 → 이름순, 사망 표시), 고르면 그 사람의 최근 20편 (`journalList { key }`).
- 입력: 해당 플레이어가 포함된 에피소드만 발췌한다. 동행자 이름은 그대로 넣는다.
- 행동 기록: `client/StoryEngine/Activity.lua`가 행동이 끝날 때(timed action `perform`) 종류와 대상을 모아 1분마다 `activity`로 보고 → `Sensor.recordActivity`가 에피소드·하루의 `acts`에 누적 → 브릿지 "did: crafted: Craft Rope x2; caught fish: Bass". 확인: 콘솔 `activity hooks N missing: ...`(없는 클래스 목록), 무언가 만들고 분해하고 낚시한 뒤 자정 일지 요청의 브릿지 로그/일지에 반영되는지.
- 출력은 인게임 아이템(일기장)의 텍스트로 저장한다. 구현 방식은 추후 결정.

### Monologue

- 서버 `server/StoryEngine/Monologue.lua`가 게임 내 1분마다(`EveryOneMinute`) 플레이어를 `Sensor.sample`로 보고 계기를 하나 고른다. 우선순위: 깨어남 > 물림 > 체력 45 아래로 > 첫 킬 > 킬 이정표(10·25·50·100·200·500·1000) > 긁힘·찢김 > 처음 가 보는 마을(중심 250타일 안) > 무들 상승(공황·통증·아픔·스트레스·우울·지루함·배고픔·목마름·피로, 2단계 이상으로 오를 때). 다른 모듈의 계기: 디렉터 폭풍(`onStorm`), 보급품 회수 완료·소탕 완료(`onQuest`).
- 처음 본 캐릭터(접속 직후)는 지금 상태를 기준으로만 삼는다. 이미 있던 킬 수와 지금 있는 마을로는 말하지 않는다.
- 쿨다운: 플레이어별 최소 간격(샌드박스 `StoryEngine.MonologueGap`, 기본 게임 내 120분) + 계기별 간격(무들 6~12시간, 부상 3시간 등). 물림·체력 위험·첫 킬은 최소 간격을 무시한다. 요청 중에는 다음 계기를 버린다.
- 문장 풀: 무들·부상·폭풍은 한 번에 3문장을 받아 `ps.mono.pools`에 두고 하나씩 꺼낸다(3일 지나거나 언어가 바뀌면 버림). 풀용 요청에는 시각·장소·날씨·최근 사건을 넘기지 않는다(나중에 다른 때 쓰이므로). 사건 계기는 1문장을 상황과 함께 요청한다.
- 대체 문장: 브릿지 실패·오프라인이거나 샌드박스 `MonologueAI`를 끄면 `IGUI_StoryEngine_Mono_<계기>_1~3`에서 고른다. 응답이 45초보다 늦으면 말하지 않는다.
- 표시: 클라이언트 `monologue` 핸들러가 `addLineChatElement`로 옅은 파란색 글씨를 말한 사람 머리 위에 띄운다. 서버는 본인(`own`)과 60타일 안의 다른 접속자에게 `speaker`(online ID)와 함께 보내고, 다른 클라이언트는 `getPlayerByOnlineID`로 그 캐릭터를 찾아 그 머리 위에 띄운다. 멀티 확인: 두 사람이 가까이 있을 때 한 사람의 혼잣말(디버그 "독백 강제")이 다른 사람 화면에도 그 캐릭터 머리 위에 떠야 한다.
- 브릿지: `build_monologue`(계기 화이트리스트 `MONOLOGUE_TRIGGERS`, 스키마 `{lines: [...]}`), 프롬프트 `prompts/monologue.md`. mock은 `[mock] <계기> <번호>`를 돌려준다.

---

## 6. 개발 환경과 테스트

### 모드 링크

개발 폴더를 게임 모드 폴더에 심볼릭 링크로 연결합니다 (관리자 PowerShell).

```powershell
New-Item -ItemType SymbolicLink -Path "$env:USERPROFILE\Zomboid\mods\StoryEngine" -Target "K:\모드 개발\프로젝트 좀보이드\ai 모드\mod\StoryEngine"
```

> 참고: 이 PC의 `C:\Users\*\Zomboid` 폴더는 아직 확인되지 않았습니다. 게임을 한 번 실행한 뒤 실제 사용자 폴더 경로를 확인하세요.

### 디버그 실행

- `ProjectZomboid64.exe -debug`로 실행하면 디버그 메뉴를 쓸 수 있고, Lua 오류가 화면에 표시됩니다.
- 로그: `Zomboid/console.txt`. 모드 로그는 `[StoryEngine]` 접두어를 붙여서 필터링한다.
- Lua 파일을 수정하면 디버그 메뉴에서 해당 파일만 다시 불러올 수 있습니다. ModData 구조를 바꿨다면 새 세이브로 테스트하세요.

### 브릿지 실행

가장 간단한 방법은 저장소 루트의 배치 파일을 더블클릭하는 것이다. 콘솔 창이 열린 채로 로그를 보여 주고, Ctrl+C 또는 창 닫기로 멈춘다.

- `start_bridge.bat`: `bridge/config.toml` 설정대로 실제 AI를 호출한다. `OPENAI_API_KEY`가 없으면 경고한다.
- `start_bridge_mock.bat`: API 호출 없이 고정 응답을 준다 (게임 쪽 테스트용).
- 이미 브릿지가 떠 있으면 두 번째 실행은 막는다. 두 개가 동시에 돌면 요청 파일을 서로 가져가 버린다.

직접 실행하려면:

```powershell
cd bridge
copy config.example.toml config.toml     # 처음 한 번
python bridge.py --mock                  # API 호출 없이 고정 응답
python bridge.py                         # config.toml 의 모듈별 제공자 사용
python -m unittest discover -s tests     # 프로토콜 테스트
```

- 실제 Claude 호출: `pip install -r requirements.txt` 후 `ANTHROPIC_API_KEY` 환경 변수를 설정하고, `config.toml`의 `[modules.debug] provider`를 `"anthropic"`으로 바꾼다.
- `claude-opus-5` 요청은 server-side `fallbacks: "default"`를 켠다. 안전 정책으로 거절되면 서버가 다른 모델로 다시 실행한다. 끄려면 `[providers.anthropic] refusal_fallback = false`.

### 1단계 인게임 확인 절차 (싱글)

1. 브릿지를 `--mock`으로 실행한다.
2. 게임에서 StoryEngine 모드를 켜고 새 게임을 시작한다. 2~4초 안에 머리 위에 "AI 연결됨"이 떠야 한다.
3. 땅을 우클릭해서 "StoryEngine: 브릿지 테스트"를 누른다. 캐릭터가 `[mock] 수신 확인: ...`을 말해야 한다.
4. 브릿지를 끄면 15초 안에 "AI 연결 끊김"이 떠야 한다. 이 상태에서 테스트를 누르면 `AI 오류: bridge_offline`이 떠야 한다.
5. `console.txt`에서 `[StoryEngine]` 로그를 확인한다.

### 2단계 인게임 확인 절차 (싱글)

1. 브릿지를 `--mock`으로 실행한다. mock 응답에는 LLM에 보낸 사실 목록이 그대로 들어가므로, 관측 결과를 눈으로 확인할 수 있다.
2. 게임을 불러오고 잠시 돌아다니며 좀비를 잡는다. 샘플은 게임 내 10분마다(기본 설정에서 실시간 약 25초) 쌓인다.
3. 우클릭 → "StoryEngine: 관측 상태"를 누르면 즉시 한 번 샘플링하고, 캐릭터가 `이름 | D1 분류 | travel | home | out | kills | episodes | now ...`를 말한다.
4. "StoryEngine: 지금 일지 쓰기" 또는 침대에서 잠들기를 한다. "일지를 썼다" 알림이 떠야 한다. 잠들기로 쓰는 일지는 지난 일지에서 게임 시간 6시간이 지나야 다시 써진다.
5. 우클릭 → "생존 일지"로 창을 열어 항목을 확인한다. `Zomboid/Lua/StoryEngine/journals/<캐릭터 이름>.txt`에도 기록된다.
6. 브릿지를 끈 상태에서 일지를 쓰면 "(AI 없이 기록됨)" 표시와 함께 규칙 기반 문장이 기록되어야 한다.
7. 캐릭터가 죽으면 회고록이 기록된다 (창은 다음 캐릭터로 열 수 없다. 파일에서 확인).

### 3단계 인게임 확인 절차 (싱글)

1. 우클릭 → "StoryEngine: 보급 강제"를 누른다. 캐릭터가 `[무전] ... 근처, 여기서 X쪽으로 N타일쯤 ...`을 말하고, 이어서 퀘스트 상태(`Q1 offered ... spawned|waiting`)를 말한다.
2. 우클릭 → "퀘스트"로 퀘스트 창을 연다. 장소, 방향·거리, 건물(방 종류), 보관 위치, 물품, 남은 시간이 보여야 한다. "지도에서 보기"를 누르거나 M으로 지도를 열면 주황색 느낌표 마커가 있어야 한다.
3. 알려준 곳으로 이동한다. 건물 칸이 로드되면 방 안의 보관함(상자 > 선반 > 카운터 순으로 우선)에 아이템이 들어간다. 보관함이 없으면 바닥에 놓는다 (`console.txt`의 `supply spawned ... in <보관함>`). 이때 퀘스트 창의 보관 위치와 지도 마커가 정확한 칸으로 바뀐다.
3. 건물 근처(15타일), 건물 안, 아이템을 모두 집은 뒤 각각 "StoryEngine: 퀘스트 상태"를 누르면 `approached → entered → looted`로 바뀌어야 한다.
4. 일지를 쓰면 보급 소식과 발견이 "Other things that happened"로 들어간다.
5. "StoryEngine: 디렉터 실행"은 LLM에 판단을 맡긴다. `console.txt`의 `director: <이벤트> ... [llm|fallback]` 줄로 결과를 확인한다. 폭풍은 비가 오지 않고 최근 이틀 안에 폭풍이 없었을 때만 후보가 된다.
6. 정해진 시각 실행은 게임 내 08:00 / 20:00 이다.

### 4-A단계 인게임 확인 절차 (통합 창 + 교신)

1. 우클릭 → "무전 교신" / "퀘스트" / "생존 일지"로 통합 창을 연다. 상단 탭으로 전환된다.
2. 교신 탭: 왼쪽에서 주파수(세력)를 고른다. 워키토키가 없으면 입력창 위에 "양방향 무전기가 있어야..."가 뜨고, 말하면 "양방향 무전기가 없다" 알림이 뜬다. 디버그 모드에서는 아이템 스폰으로 `Base.WalkieTalkie1` 등을 얻는다.
3. 무전기를 들고 말하면 내 말이 기록에 뜨고, 상태 줄이 "응답을 기다리는 중"으로 바뀐 뒤 세력의 답장이 온다. 창을 닫고 있거나 다른 채널을 보고 있으면 "[무전] 이름" 알림과 목록의 읽지 않음 숫자가 뜬다.
4. 신뢰도는 상태 줄에 표시된다. 세이브를 다시 불러와도 대화 기록과 신뢰도가 남아 있어야 한다.
5. 퀘스트 탭: 왼쪽 목록에서 고르면 오른쪽에 상세가 뜨고, 진행 중인 퀘스트는 "지도에서 보기"가 켜진다.

### 5단계 인게임 확인 절차 (독백)

1. 우클릭 → "StoryEngine: 독백 강제"를 누를 때마다 계기가 차례로 바뀌며 머리 위에 옅은 파란 글씨가 뜬다(쿨다운 무시). 로그: `monologue <이름> <계기> llm|pool|fallback`.
2. 풀 계기(공황 등)를 한 바퀴 돌린 뒤 다시 누르면 `pool`로 바로 뜬다.
3. 평소 플레이: 좀비를 처음 죽이거나, 긁히거나, 다른 마을에 들어가거나, 배고픔·피로가 2단계로 오르면 혼잣말이 나온다. 연달아 나오지 않아야 한다(기본 게임 내 2시간 간격).
4. 브릿지를 끄고 강제하면 준비된 문장(`fallback bridge_offline`)이 뜬다. 샌드박스 옵션 StoryEngine 페이지에서 끄기·AI 끄기·간격을 바꿀 수 있다.

### 6단계 인게임 확인 절차 (멀티 — 인게임 호스트)

1. 브릿지를 먼저 띄운다(`start_bridge.bat`). 메인 메뉴 → 호스트 → 서버 설정의 모드 목록에 StoryEngine을 넣고 시작한다. 호스트도 클라이언트로 서버에 접속하는 구조라 혼자서도 서버/클라이언트 분리를 시험할 수 있다.
2. 접속 직후 "AI 연결됨" 알림이 뜨는지 본다. 안 뜨면 호스트 서버의 `Zomboid/Lua` 경로가 다른 것이다 (서버 로그의 `bridge state` 줄 확인).
3. 우클릭 → "StoryEngine: 멀티 진단". 화면에 `diag: N diff`가 뜨고 로그에 비교표가 남는다. 좀비를 몇 마리 잡고, 긁히고, 배고파진 뒤에 한 번 더 누른다.
4. 기능 확인: 보급 강제 → 보관함에 물건이 보이는지(`sendAddItemToContainer`), 부탁 강제 → 수락 → 제출 시 인벤토리에서 물건이 사라지는지(`sendRemoveItemFromContainer`), 디렉터로 폭풍(`transmitServerTriggerStorm`), 소탕 부탁 → 처치 수가 오르는지(서버 `OnZombieDead`), 교신, 독백, 잠들어서 일지.
5. 로그: 클라이언트 `Zomboid/console.txt`, 호스트 서버 `Zomboid/coop-console.txt`(없으면 `server-console.txt`).

### 다른 모드 아이템 확인 절차

1. 다른 모드(예: Vanilla Foods Expanded, ModernFirearmsSystem)를 켜고 시작하면 로그에 `item pool built: scanned N food N firearm N melee N` 이 찍힌다.
2. 우클릭 → "StoryEngine: 아이템 분류" → `Zomboid/Lua/StoryEngine/itempool.txt` 에 분류·등급별 목록과 총마다 낱발·상자·탄창이 나온다. 이상한 아이템은 `items.txt` 에 `exclude` 로 뺀다 (재시작 후 적용).
3. 보급 강제·거래로 받은 물건에 모드 아이템이 섞이는지, 모드 총에 맞는 탄약이 같이 오는지 본다. 샌드박스 "보상에 다른 모드 아이템 비율"을 100으로 두면 확인이 쉽다.

### NPC 사회생활 확인 절차

1. 디버그 "NPC가 먼저 연락": 교신 목록에 새 메시지가 오고 로그 `npc contact <세력> <이유>`. 게임 시간으로 하루 두면 4~6번 연락이 와야 한다.
2. 디버그 "○○ 이야기 다음 단계로"(교신 탭에서 고른 상대): 상태 줄 `stories` 에서 그 NPC 노드가 바뀐다. 퀘스트 노드면 [이야기] 부탁이 오고, 완료/거절에 따라 다음 노드가 갈린다(로그 `story <세력> -> <노드>`).
3. 교신 목록 맨 위 "공용 주파수"에서 아무 말이나 하면 NPC 2~3명이 각자 답하고 서로 이야기해야 한다(로그 `open scene reply`). 디버그 "공용 주파수 장면"은 플레이어 없이 장면을 만든다.
4. 디버그 "위기 선택지": 퀘스트 탭에 [위기] 퀘스트와 "○○ 돕기" 버튼 3개, 관련 NPC 셋이 각자 호소. 하나를 고르면 그 NPC +2, 나머지 -2 줄이 무전에 뜨고 [위기] 부탁이 바로 수락된 상태로 생긴다.

### Project A-Life 연동 확인 절차

A-Life(`ProjectALifeNPCs`)를 함께 켠 세이브에서:
1. 디버그 "A-Life 지원 테스트": 교신 탭에서 고른 상대의 대원 6명(구간 3)이 10~15타일 옆에 나타나 따라와야 한다. 로그 `alife squad support ... friendly`, `alife support arrived <세력> 6`. 좀비와 싸우고 플레이어를 공격하지 않아야 한다. 무전으로 출동 알림.
2. 약 4게임시간 뒤 `alife support leaving` → 대원이 떠나고, 멀어지면 `alife support removed`.
3. 디버그 "A-Life 습격 테스트": 45~60타일 밖에서 빅 패거리 쪽 무장 무리가 플레이어를 노리고 와야 한다(`alife squad attack ... hostile`).
4. 신뢰도 50 이상 상대를 골라 교신 탭 "지원 요청" → 같은 흐름. 50 미만이면 버튼이 꺼지고 툴팁에 이유.
5. 신뢰도 70 이상 상대가 있을 때 A-Life 강도를 당하거나(무기를 든 무리가 "손 들어") 좀비에 둘러싸여 크게 다치면 `alife auto support`로 자동 지원.
6. A-Life를 끈 세이브에서는 버튼이 안 보이고 협박 보복은 추적 호드여야 한다.

### 새 이벤트·전투 기록·로그 압축 확인 절차

1. 우클릭 → "StoryEngine: 새 이벤트 강제"를 누를 때마다 호드 유도 → 헬기 → 구조 신호 → 먼저 주는 보급(신뢰도 60 이상 세력 필요) → 협박(신뢰도 10 이하인 빅·휘태커 필요) 순서로 실행된다. 조건이 안 맞으면 "skipped"가 뜬다.
   - 협박: 퀘스트 탭에 "○○의 협박", 요구 물건을 제출하면 1등급 대가. 기한(36시간)을 넘기면 로그 `extort punishment`와 함께 좀비 무리나 헬기.
   - 거래 무상 제공: 신뢰도 60 이상 세력에게 작은 것을 청하면 35% 확률로 "대가 없이 보내 줌" 줄이 뜬다. 같은 세력에 일주일 3번째 요청부터 "요청이 너무 잦음" 신뢰도 -1.
   - 등급 막힘: 신뢰도가 낮은 세력에게 높은 등급(예: 신뢰 45에 수술 키트, 방위대 신뢰 60 미만에 총)을 명확히 청하면 NPC가 신뢰가 부족하다며 거절하고 "신뢰도 부족: N등급 ○○은(는) 신뢰도 M 이상부터" 줄이 뜬다. 하위 등급 제안이 대신 오면 안 된다. 로그 `trade offer blocked`는 AI가 규칙을 어겨 게임이 버린 경우.
   - 흥정: 거래 제안이 뜬 상태에서 같은 세력에게 "15로 해줘", "도구로 내도 돼?"처럼 말하면 "거래 조건 변경" 줄과 함께 상태 줄·퀘스트 상세의 가격이 바뀐다(로그 `trade revised`). 하한선 아래로는 안 내려가고, 3번 뒤에는 "더는 흥정할 수 없다". 터무니없는 값을 반복하면 NPC가 거래를 거둘 수 있다(로그 `trade withdrawn`, 퀘스트 "상대가 흥정 중에 거래를 거뒀다").
   - 호드 유도: 로그 `horde_nearby N from <방향>`, 무전으로 경고가 오고 잠시 뒤 좀비가 걸어온다.
   - 헬기: "머리 위로 헬리콥터 소리" 알림, 독백, 방위대 반응.
   - 구조 신호: 퀘스트 탭에 "○○ 구조 신호", 건물에 가면 좀비가 기다린다(로그 `rescue zombies`).
2. 퀘스트 장소 근처에서 싸우면 퀘스트 상세에 "근처 전투: 처치 N, 부상 M" 줄이 생기고, 완료 시 NPC 반응과 일지에 반영된다.
3. 7일을 관측하면 로그에 `week summary <이름> D1-7`, 무전을 많이 주고받으면 `radio memory <세력> updated`가 찍힌다.
4. 샌드박스 StoryEngine 페이지에서 디렉터·NPC 부탁·호드와 헬기·일지를 끌 수 있다.

### 브릿지 없이 테스트

- 브릿지의 `--mock` 모드는 LLM 대신 고정 응답을 돌려준다. API 비용 없이 파이프라인을 검증할 수 있다.
- 디렉터는 디버그 명령으로 특정 이벤트를 강제 실행할 수 있게 한다 (화이트리스트 실행기 단독 테스트).

### 단계별 완료 조건

| 단계 | 완료 조건 |
|---|---|
| 1. 브릿지 + 코어 | 싱글에서 디버그 명령 → 요청 파일 → mock 응답 → 인게임 텍스트 표시. 브릿지를 끄면 "AI 연결 끊김" 알림 |
| 2. 관측 + 일지 | 하루를 플레이한 뒤 DaySummary 분류가 맞음. 자정이 지나면 일기 생성, 다른 플레이어 일지 열람 |
| 3. 디렉터 | `quiet_day` / `storm` / `supply_drop` 3종이 실행되고, 잘못된 JSON은 `quiet_day`로 처리 |
| 4. 무전 | 보급 퀘스트가 `offered → looted`까지 추적되고, 무전으로 안내됨 |
| 5. 독백 | 캐시 풀 우선 동작, 쿨다운 준수 |
| 6. 멀티 | 인게임 호스트에서 서버/클라이언트 상태 일치, 보급·제출 동기화, 번역 (완료). 전용 서버는 당분간 대상 외 |

---

## 창작마당 업로드

- 업로드 폴더: `%USERPROFILE%\Zomboid\Workshop\StoryEngine\` (`preview.png` 256x256, `workshop.txt`, `Contents\mods\StoryEngine\{42,common}`)
- 모드를 고친 뒤 `sync_workshop.bat`로 저장소의 `mod\StoryEngine`을 업로드 폴더로 복사하고, 게임 메인 메뉴 → 창작마당 → 항목 만들기/업데이트에서 올린다. 첫 업로드 뒤 `workshop.txt`에 `id=`가 붙는다.
- `42/mod.info`: poster, icon, `versionMin=42.20`. B42는 `common` 폴더가 있어야 하고 빈 폴더는 업로드에서 빠지므로 `common/README.txt`를 둔다.
- 개발용 `Zomboid\mods\StoryEngine`(저장소 연결)와 업로드 폴더는 같은 모드 ID라 게임 목록에 둘 다 보일 수 있다. 친구와 멀티를 할 때는 호스트도 창작마당 버전을 쓰거나(연결 폴더 제거), 올린 버전과 로컬 파일이 같아야 접속 시 파일 불일치가 나지 않는다. 서버 설정의 `WorkshopItems`에 올린 항목 ID를 넣는다.
- 브릿지(API 키)는 업로드하지 않는다. 모드 폴더에는 게임 파일만 있다.

## 브릿지 배포판

- 빌드: `cd bridge` → `python build_release.py` (필요: `pip install pyinstaller openai anthropic`). 결과 `release/StoryEngineBridge-<버전>-win64.zip` + `.sha256`. 버전은 `bridge.py`의 `BRIDGE_VERSION`.
- PyInstaller onedir(백신 오탐이 onefile보다 적음). 프롬프트는 번들 안(`sys._MEIPASS/prompts`), 설정은 exe 옆 `config.toml`(`FROZEN`이면 `sys.executable` 기준).
- 첫 실행이면 설정 마법사(`setup_wizard.py`): 제공자(OpenAI / Anthropic / 테스트), 모델, API 키(숨김 입력, `config.toml`에만 저장, 비우면 환경 변수), 게임 데이터 폴더. `--setup`으로 다시 실행. 배포판은 종료·오류 시 Enter를 누를 때까지 창을 유지.
- zip 안: exe, `_internal`, `README_EN.md`/`README_KO.md`(`bridge/release_docs`), `config.example.toml`, 빌드 때 생성하는 `THIRD_PARTY_NOTICES.md`(openai·anthropic 의존성 라이선스), `source/`(파이썬 소스). `config.toml`이 들어가면 빌드가 실패한다.
- 호스팅은 GitHub Releases 권장. 창작마당 설명은 `docs/WORKSHOP_DESCRIPTION.txt`(영어·한국어 BBCode, `BRIDGE_DOWNLOAD_LINK`를 실제 링크로 바꿔 `workshop.txt`에 반영).
- 정책 근거: 좀보이드 모드 정책(비공식 표기, 유료화·후원자 전용 금지, 숨겨진 동작·사생활 침해 금지, 제3자 저작물 표기), 스팀 온라인 행동 수칙(악성 소프트웨어·광고 금지). 창작마당 링크는 스팀 검사로 최대 24시간 가려질 수 있다.

## 7. 보안·운영 체크리스트

- [ ] API 키는 `bridge/config.toml`에만 둔다. `.gitignore`에 등록하고 로그에 출력하지 않는다
- [ ] 무전 입력을 디렉터 프롬프트에 넣지 않는다
- [ ] 디렉터 출력은 스키마와 화이트리스트를 통과한 것만 실행한다
- [ ] 좌표·아이템 등 게임에 영향을 주는 값은 LLM 출력이 아니라 Lua가 결정한다
- [ ] 퀘스트 판정은 서버 측 데이터로만 한다
- [ ] 브릿지가 응답하지 않을 때 폴백이 동작하고 게임이 멈추지 않는다
- [ ] 시간당 호출 한도와 플레이어별 쿨다운을 샌드박스 옵션으로 조절할 수 있다
