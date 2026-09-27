# Project Zomboid B42 — LLM 스토리 엔진 모드

Claude.ai 대화에서 정리한 설계를 Claude Code로 이어받기 위한 문서입니다.
구현 전에 이 문서 전체를 읽고, "확인 필요" 표시된 항목은 실제 B42 코드/문서로 검증한 뒤 진행하세요.

## 목표

Project Zomboid Build 42용 모드. Claude/ChatGPT 등 LLM API를 연결해 하나의 "생존 서사"를 만드는 네 개 모듈을 묶는다.
NPC 엔진(B42에서 아직 불완전)에 의존하지 않는 것이 핵심 설계 방향.

- 싱글플레이와 멀티플레이(인게임 호스트, 직접 운영하는 전용 서버) 모두 지원
- 처음부터 서버 중심 구조로 작성 → 싱글도 같은 코드로 동작

## 모듈

1. **무전기 교신 (Radio)**
   워키토키/햄 라디오로 가상의 생존자와 대화. 실체 NPC 없음.
   스토리 로그와 실제 맵 정보(좌표, 건물)를 프롬프트에 넣어 게임과 연결된 정보·간단한 퀘스트 제공.
   디렉터 이벤트를 플레이어에게 전달하는 창구 역할도 함.
   멀티: 같은 주파수를 듣는 플레이어들이 교신을 공유(브로드캐스트).

2. **AI 디렉터 (Director)**
   게임 내 하루 1~2회, 플레이어 상태 요약 + 선택 가능한 이벤트 목록을 LLM에 보내고 하나를 고르게 함.
   LLM은 JSON만 반환: `{"event": "horde_nearby", "intensity": 2, "reason": "..."}`
   실행은 미리 구현된 Lua 함수가 담당. 화이트리스트에 없는 이벤트는 무시.
   이벤트 후보: 소규모 호드 유도, 폭우/폭풍, 헬기 이벤트, 근처 건물 보급품 배치, 무전 구조 신호, 조용한 하루.
   멀티: 서버 전체 디렉터 1개, 이벤트는 플레이어/그룹 위치 단위로 적용. 플레이어별 요약 + 서버 전체 요약을 함께 전달.

3. **생존 일지 (Journal)**
   잠들 때 그날의 스토리 로그로 일기 생성. 사망 시 전체 로그로 회고록 생성.
   멀티: 플레이어별로 작성하되 공유 스토리 로그를 참고해 다른 플레이어가 등장할 수 있음.

4. **내면 독백 (Monologue)**
   무들(공포, 우울, 지루함)이나 사건(첫 킬, 물림)에 짧게 반응하는 혼잣말 (`Say()` 계열).
   호출이 가장 잦음 → 저렴한 모델, 캐싱된 문장 풀 우선, 강한 쿨다운.

## 아키텍처

```
[Client Lua] --sendClientCommand--> [Server Lua] --파일 I/O--> [Bridge 프로세스] --HTTPS--> [LLM API]
[Client Lua] <--sendServerCommand-- [Server Lua] <--파일 I/O-- [Bridge 프로세스]
```

- **코어 (서버 측)**
  - 상태 수집기: 체력/부상, 식량·탄약, 기지 상태, 좀비 조우 빈도, 무들, 경과 일수, 날씨, 전기·수도 여부
  - 브릿지 통신: 요청 큐 파일 쓰기 → 응답 파일 폴링 (비동기, 게임 루프 블로킹 금지)
  - 월드 스토리 로그: 모든 모듈이 읽고 쓰는 공유 기억. 길어지면 주기적으로 요약·압축
- **브릿지**: 서버 머신에서 실행되는 별도 프로세스 (Python 또는 Node 권장). API 키는 브릿지에만 둠. 클라이언트는 키 불필요.
- **LLM 호출은 서버에서만.** 클라이언트는 요청과 표시만 담당.

## 관측·기록 계층

원칙: **AI는 게임을 보지 못한다. 모드가 사실을 기록하고, AI는 요약된 기록만 읽는다.**
판정(퀘스트 성공, 하루 분류, 동행 여부)은 전부 Lua 규칙이 하고, LLM은 서사만 입힌다.

```
[1. 센서]        이벤트 훅 + 주기 샘플링 → 원시 사실 (좌표, 킬, 피해, 아이템 이동)
[2. 집계기]      원시 사실 → 에피소드 (누가 / 언제 / 어디서 / 누구와 / 무슨 일)
[3. 스토리 로그]  에피소드 요약문 → LLM 프롬프트
```

LLM에는 3층만 전달. 1층 원시 데이터는 절대 프롬프트에 직접 넣지 않는다 (토큰 비용 + 환각 방지).

### 1층: 센서

- **이벤트 훅** (바닐라에서 사용 확인됨): `OnZombieDead`, `OnHitZombie`, `OnPlayerDeath`, `OnPlayerMove`,
  `OnContainerUpdate`, `OnProcessTransaction`, `OnWeaponHitXp`, `AcceptedTrade`, `AcceptedMedicalCheck`,
  `AcceptedSafehouseInvite`, `OnWeatherPeriodStart`, `OnThunderEvent`
- **주기 샘플링** (게임 내 10분, `EveryTenMinutes`): 플레이어별 좌표, 실내/실외(`isOutside`), 현재 건물(`getBuilding`),
  누적 킬(`getZombieKills`), 체력·부상(`getBodyDamage`), 무들(`getMoodles`), 주변 좀비 수
- 샘플은 롤링 버퍼(최근 N시간)에만 보관하고, 집계 후 버린다.

### 2층: 집계기

- **퀘스트 추적** — 보급품은 AI가 아니라 **모드가 스폰**한다.
  1. 디렉터가 `supply_drop` 선택 → Lua가 실제 건물 목록에서 위치 선정 → 상자·아이템 스폰, `modData.questId` 태그
  2. 무전 AI는 해당 위치 정보를 받아 서사만 입힘 (AI가 좌표를 지어낼 수 없음)
  3. 상태 머신: `offered → approached(반경 N타일) → entered(건물 진입) → looted(태그 아이템 인벤토리 이동) → done | expired`
  4. 진행 중 반경 내 킬·피해·물림을 퀘스트에 첨부 → "전투가 있었는지" 판정
- **하루 분류** — 이벤트가 "없었음"은 샘플 집계로 판단.
  - "집" 정의: 멀티 = 세이프하우스, 싱글 = 가장 자주 잠든/오래 머문 위치 자동 추정
  - 하루 요약: 이동거리, 기지로부터 최대 거리, 실외 체류 시간, 킬, 피해, 무들
  - 규칙 분류: `stayed_home` / `local_scavenge` / `expedition` / `combat_day`
  - 디렉터는 이 분류를 입력으로 받는다 (예: 3일 연속 `stayed_home` + 지루함 → 무전 구조 신호)
- **동행 판정 (멀티)** — 서버가 모든 플레이어 위치를 알고 있으므로 서버에서 계산.
  - 샘플마다 거리 기반 클러스터링(예: 20타일 이내 = 같은 그룹), 연속 유지되면 파티 에피소드 생성
  - 킬·피해·퀘스트 회수 발생 시 반경 내 다른 플레이어를 "동석자"로 함께 기록
  - 직접 상호작용(거래, 치료, 세이프하우스 초대)은 이벤트로 별도 기록

### 3층: 스토리 로그

- 에피소드 단위 한 줄 요약. 예: `D12 09:10~13:40 | A·B 동행 | 로즈우드 소방서 | 킬 A11/B6 | B 긁힘 | Q12 회수(A)`
- 일지: 해당 플레이어가 포함된 에피소드만 발췌 → 다른 플레이어가 자연스럽게 등장
- 디렉터: 플레이어별 하루 분류 + 서버 전체 요약
- 길어지면 일 단위 → 주 단위로 요약 압축

### 신뢰 경계

- 서사용 정보(킬 수, 무들)는 클라이언트 보고로 충분
- 게임 로직·보상에 영향을 주는 판정(퀘스트 회수, 위치 도달)은 **서버가 직접 검증** (상자 내용물, 서버 측 플레이어 좌표)
- 저장: 게임 상태(퀘스트, 에피소드, 스토리 로그)는 전역 `ModData`(세이브와 함께 저장, 서버 권위). 파일 I/O는 브릿지 통신 전용

## 멀티플레이 / 호스팅

- B42 멀티는 42.20 안정화 버전(2026-07-29)부터 stable 브랜치에 포함됨
- 인게임 "호스트" 방식도 호스트 PC에서 서버 프로세스를 따로 띄우는 구조라 동작함 → 호스트 PC에서 브릿지를 같이 실행
- 임대 서버 호스팅 업체는 별도 프로세스 실행이 막혀 있는 경우가 많음 → 지원 대상 외로 간주
- 브릿지 미응답 시: 게임 내 "AI 연결 끊김" 알림 + 규칙 기반 폴백으로 전환

## 배포 (2026-09-27)

- 창작마당: https://steamcommunity.com/sharedfiles/filedetails/?id=3808950035 (업로드 폴더 `%USERPROFILE%\Zomboid\Workshop\StoryEngine`, 갱신은 `sync_workshop.bat` 후 게임 업로더)
- 모드 저장소(공개): https://github.com/skditjdqja12/PZ-StoryEngine — 이 폴더. `bridge/`는 `.gitignore`로 제외
- 브릿지 저장소(공개): https://github.com/skditjdqja12/PZ-StoryEngine-Bridge — `bridge/` 폴더가 별도 git 저장소. 릴리스 v0.1.0에 Windows zip(+SHA256). 새 버전은 `BRIDGE_VERSION` 올리고 `python build_release.py` → `gh release create`
- 창작마당 설명 원본: `docs/WORKSHOP_DESCRIPTION.txt` (바꾸면 `workshop.txt`의 description 줄에 반영)

## 다른 모드와의 호환

- LootRemover(같은 개발자의 루팅 삭제 모드, `K:\모드 개발\프로젝트 좀보이드\remover 모드`): `OnFillContainer`에서 보관함 아이템을 삭제하므로 퀘스트 물건이 지워질 수 있다. 수정안(LootRemover 쪽에서 `modData.storyQuest`가 붙은 아이템을 건너뛰기, `remover 모드\StoryEngine_호환_수정안.md`)은 **LootRemover 세션에서 적용 완료** (2026-09-27). 그 세션의 jar 확인: `setExplored(true)`는 바닐라 루팅 생성(칸 로드, 싱글 창 열기, 멀티 `RequestItemsForContainerPacket`)을 실제로 막고, 루팅 재생성은 `isHasBeenLooted()`인 보관함에서만 일어난다. StoryEngine의 `modData.storyQuest` 표시 이름을 바꾸면 이 호환이 깨진다.

## 운영/안전 설계

- 모듈별 모델 분리: 디렉터·일지 = 상위 모델, 독백 = 경량 모델
- 현재 사용 모델: 모든 모듈 OpenAI `gpt-6-luna` (Responses API, `bridge/config.toml`). 키는 `OPENAI_API_KEY` 사용자 환경 변수. 제공자는 `mock` / `anthropic` / `openai` 중 모듈별로 선택
- 서버 옵션(SandboxVars 등): 모듈별 on/off, 시간당 호출 한도, 플레이어별 쿨다운
- 요청 큐 우선순위: 디렉터 > 무전 > 일지 > 독백
- 프롬프트 인젝션 방지: 무전기 플레이어 입력은 디렉터 판단 프롬프트에 직접 넣지 않음
- 게임 로직에 영향을 주는 출력은 JSON 스키마 + 화이트리스트로 검증
- 반복 콘텐츠(방송성 텍스트, 독백 풀)는 캐싱

## B42 API 확인 결과 (바닐라 Lua 기준)

게임 설치 경로: `E:\SteamLibrary\steamapps\common\ProjectZomboid` (바닐라 Lua: `media/lua/{client,server,shared}`)

- **확인됨** 네트워크 명령
  - `sendClientCommand(player, module, command, args)` → 서버 `Events.OnClientCommand.Add(function(module, command, player, args) end)` (`server/ClientCommands.lua`)
  - `sendServerCommand(player, module, command, args)` / player 생략 시 전체 → 클라 `Events.OnServerCommand.Add(function(module, command, args) end)` (`client/ServerCommands.lua`)
- **확인됨** 싱글플레이 동작 (jar 바이트코드): `sendClientCommand`는 `SinglePlayerClient`를 거쳐 `OnClientCommand`로 전달된다. `sendServerCommand`는 `GameServer.server`일 때만 동작하므로, 싱글에서는 클라이언트 핸들러를 직접 호출한다 (`StoryEngine.Net`)
- **확인됨** 파일 I/O (jar 바이트코드): `getFileWriter(name, createIfNull, append)`, `getFileReader(name, createIfNull)`. `Zomboid/Lua` 기준 상대 경로이고, 상위 폴더를 자동 생성하며 UTF-8로 읽고 쓴다. **확장자는 ini/cfg/txt/log/json만 허용**되고 `..` 경로는 거부된다. 삭제 API는 없다
- **확인됨** `OnTick`은 `IngameState`(클라이언트 게임 루프)에서만 발생한다. 서버 측 폴링은 `EveryOneMinute`(GameTime)도 함께 건다
- **확인됨** 알림: `HaloTextHelper.addText/addGoodText/addBadText(player, text)`. 번역은 `media/lua/shared/Translate/<언어>/*.json` (B42는 JSON 형식)
- **확인됨** 날씨: `getClimateManager():triggerCustomWeatherStage(WeatherPeriod.STAGE_STORM, dur)` (싱글),
  `transmitTriggerStorm(dur)` / `transmitTriggerTropical` / `transmitTriggerBlizzard` / `transmitStopWeather()` (멀티) — `client/ISUI/AdminPanel/ISAdmPanelWeather.lua`
- **확인됨** 라디오: `DynamicRadioChannel.new(name, freq, category, uuid)` + `Events.OnLoadRadioScripts` / `EveryHours` — `server/radio/ISDynamicRadio.lua`, `ISWeatherChannel.lua` 참고. 커스텀 UI 없이 기존 라디오 시스템에 채널 추가 가능성 높음
- **인게임 확인 (42.20.4)** Kahlua에는 표준 함수 `next`가 **없다** (`Object tried to call nil`). 테이블이 비었는지는 `pairs` 루프로 확인한다. `select`, `string.byte`, `string.char`, `table.concat`은 동작한다
- **인게임 확인 (42.20.4)** `.lua` 소스 파일 안의 **비 ASCII 문자열 리터럴(한글, `·` 등)은 깨진다**. Lua 코드에는 ASCII만 쓰고, 표시 문자열은 `Translate/*.json` + `getText`, 현지어 지명 등은 브릿지(Python)에서 붙인다. 게임에서 받은 문자열(캐릭터 이름 등)과 파일 I/O의 한글은 정상이다
- **인게임 확인 (42.20.4)** 싱글에서 `getFileWriter` → 브릿지 → 응답 파일 왕복과 heartbeat 기반 연결 판정이 동작한다
- **확인됨 (jar 바이트코드, 2026-09-27)** 서버에서 아이템 넣기·빼기: `container:AddItem` 뒤 `sendAddItemToContainer(container, item)`, `container:Remove(item)` 뒤 `sendRemoveItemFromContainer(container, item)` (바닐라 `server/ClientCommands.lua`, `ISBuildUtil.lua`와 같은 순서, 싱글에서도 안전). `ItemContainer:removeItemOnServer`는 `GameClient.client`일 때만 동작하는 클라이언트용이라 **서버에서는 아무 일도 안 함** → `server/StoryEngine/Items.lua`로 통일. `IsoGridSquare:AddWorldInventoryItem(String, x, y, z)`는 서버에서 `transmitCompleteItemToClients`를 스스로 부르고, 바닥 아이템 제거는 `transmitRemoveItemFromSquare`(바닐라 서버 코드와 같음)
- **확인됨 (jar 바이트코드)** 멀티 서버의 폭풍은 `getClimateManager():transmitServerTriggerStorm(hours)` (`GameServer.server`일 때 `triggerCustomWeatherStage` + `updateOnTick` + 클라이언트 전송). `transmitTriggerStorm`은 클라이언트→서버 관리자 요청용
- **인게임 확인 (42.20.4 인게임 호스트, 2026-09-27)** 호스트 서버 프로세스는 모드 파일은 읽지만 **모드의 IG_UI 번역을 `getText`로 찾지 못한다** (`Missing translation "IGUI_StoryEngine_..."`, 바닐라 `MapLabel_*`와 아이템 이름은 됨). 서버 언어와 플레이어 언어도 다를 수 있으므로 **서버는 표시 문장을 만들지 않고 `lt = { key, alt, args = { {t=town|dir|item|need|num|s, v} } }`만 보낸다** → 클라이언트 `UI.render`/`UI.textOf`가 번역. AI가 읽는 무전 기록에는 서버가 만든 영어 `text`를 함께 둔다. 대상: 퀘스트 무전 알림, 부탁·소탕 대체 문장, 독백 대체 문장, 대체 일지·회고록
- **인게임 확인 (42.20.4 인게임 호스트)** 호스트 서버도 `Zomboid/Lua` 경로가 같아 브릿지가 그대로 연결된다. 서버에서 `OnTick`(초당 약 10회)·`EveryOneMinute`·`EveryTenMinutes`·`OnZombieDead`·`OnHitZombie`가 발생하고, `OnPlayerUpdate`는 서버에서 발생하지 않는다. 서버가 보는 위치·체력·킬 수·수면·실내외·부상은 클라이언트 값과 같았다 (무들은 둘 다 없음 상태에서만 비교됨). 서버 로그는 `Zomboid/coop-console.txt`
- **인게임 확인 (42.20.4 인게임 호스트)** 호스트 본인도 접속할 때 `role="user"`다(세션마다 다시 관리자 권한을 받아야 함). 우리 디버그 명령은 `Capability.UseDebugContextMenu`가 있어야 하고, 없으면 `debugDenied`로 이유를 알린다. 접속 기록: `Zomboid/Logs/<시각>_connections.txt`(role), `_admin.txt`, `_cmd.txt`(클라이언트 명령)
- **사용처 발견, 인자 미확인**: 호드 `createHordeFromTo` (`client/LastStand/Challenge1.lua`), 아이템 `AddWorldInventoryItem`
- **확인됨 (jar 바이트코드)** 헬기: `testHelicopter()`는 서버·싱글에서 `IsoWorld.helicopter:pickRandomTarget()`(무작위 플레이어), 멀티 클라이언트에서는 `/chopper start` 전송. 특정 대상 지정 API는 Lua에 없음. 호드: `createHordeFromTo(x1, y1, x2, y2, count)` (ZombiePopulationManager, 한 지점에서 만들어 목표로 걷게 함)

## 확인 필요 (런타임 테스트로 검증할 것)

- 파일 쓰기 경로(`Zomboid/Lua` 아래)가 인게임 호스트와 전용 서버에서 동일한지
- 전용 서버에서 `OnTick`이 정말 발생하지 않는지. 발생하지 않으면 `EveryOneMinute` 기반 폴링의 지연이 괜찮은지
- Kahlua에서 `Json.lua`가 정상 동작하는지 (한글 문자열, `string.char`로 만드는 `\u` 이스케이프, 큰 정수)
- 센서 이벤트(`OnZombieDead`, `OnHitZombie`, `OnContainerUpdate`, `OnPlayerMove` 등)가 멀티에서 **서버/클라이언트 중 어디서 발생**하는지 → 클라에서만 발생하면 클라가 `sendClientCommand`로 보고
- `OnZombieDead`에서 킬한 플레이어를 알아낼 방법
- 폴링 주기에 쓸 이벤트 (`Events.OnTick`, `EveryOneMinute`, `EveryTenMinutes` 등)의 실제 비용

## 제안 구현 순서

1. 브릿지 + 코어 통신 (싱글에서 요청/응답 왕복 확인) — **싱글 mock 왕복 확인됨 (2026-09-27, 42.20.4, 575ms)**. 남은 확인: 브릿지 종료 시 끊김 알림, 실제 Claude 호출
2. 관측 계층(센서·집계기) + 스토리 로그 + 일지 모듈 (가장 단순, 전체 파이프라인 검증용) — **싱글 mock으로 관측 → 일지 요청 → 저장까지 확인됨 (2026-09-27)**. 수면 트리거와 하루 마감도 확인됨. 실제 LLM(OpenAI `gpt-6-luna`)으로 일지 생성 확인 — 사실 충실, 문체는 다소 건조. 남은 확인: 회고록, 오프라인 대체 문장. 서버: `Sensor.lua`(샘플·에피소드·하루 분류·집 추정), `Store.lua`(ModData), `Journal.lua`(수면 시 일기, 사망 시 회고록, 오프라인 대체 문장, `journals/<이름>.txt`). 지명은 `shared/StoryEngine/Places.lua`(바닐라 지도 라벨 좌표). 프롬프트 조립은 `bridge/modules.py` `build_journal`
3. 디렉터 (화이트리스트 이벤트 2~3개로 시작) — **구현 완료, 인게임 미검증** (브릿지 경유 `gpt-6-luna` 판단은 확인). `Director.lua`(08:00/20:00, 이벤트 `quiet_day`·`storm`·`supply_drop`, 응답 재검증, 규칙 기반 폴백), `Quests.lua`(보급 건물 선정·지연 생성·`offered→approached→entered→looted|expired` 추적). 브릿지 `build_director`가 허용 이벤트·플레이어 이름으로 JSON 스키마 enum을 매번 생성. 디렉터 사건은 `ps.notes`로 다음 일지에 들어감. 보급 위치 알림은 무전 모듈 전까지 `directorNotice`(Say + halo)로 임시 전달. 보급품은 건물 1층 전체를 훑어 보관함에 우선 배치. **`LoadGridsquare` 순간에는 건물의 나머지 칸·가구가 아직 없어 보관함을 못 찾는다(42.20.4 확인)** → 목표 칸 로드를 본 뒤 2초 이상 지나고 건물 칸이 모두 로드됐을 때 `EveryOneMinute`에서 배치(최대 5회 대기). 클라이언트 `QuestWindow.lua`(장소·방향·보관함·물품)와 `QuestMap.lua`(`ISWorldMap.ShowWorldMap`을 감싸 지도를 열 때마다 `Exclamation` 마커 동기화 — 추가한 심볼은 플레이어 지도에 저장되므로 우리가 찍은 좌표의 마커를 지우고 다시 찍음)
4. 무전기 (디렉터 이벤트 전달 연동) — 사용자 요구로 확장됨 (2026-09-27). 결정 사항:
   - 무전기 조건 (2026-09-27 변경): 기본은 **무전기 없이** 교신·제출·거래 가능. 샌드박스 `StoryEngine.RequireRadio`를 켜면 양방향 무전기 필요 (인벤토리의 `Radio` + `getDeviceData():getIsTwoWay()`, 또는 2타일 안의 `IsoWaveSignal`). 판단은 `Factions.canTalk`
   - 대화 상대는 **8명** (2026-09-27 확장, 초기 신뢰도는 성향에 따라 0~30, 이미 있는 채널은 세이브 값 유지): `ray`(레이 머서, 91.4, 웨스트 포인트, 30, 농가: 통조림·씨앗) / `casey`(케이시 리우, 16세 햄 무전사, 107.7, 밸리 스테이션, 30, 전자기기) / `doc`(준 애들러, 간호사, 95.1, 리버사이드 진료소, 25, 의약품) / `pike`(에이머스 파이크 목사, 99.9, 마치 리지 교회, 20, 생필품·물, 값 0.8배) / `dewey`(듀이 홀리스, 정비공, 101.5, 에코 크릭, 15, 차량 부품) / `guard`(휘태커 병장, 104.2, 녹스 경계 캠프, 10, 군용: 탄약·방호구) / `rats`(빅/콜필드 패거리, 88.7, 콜필드, 5, 약탈품: 공구·담배·술) / `hunter`(행크 톨리버, 86.3, 에크론 숲, 0, 사냥: 소총·칼·덫·육포). 게임 쪽 `shared/StoryEngine/Factions.lua`(id·주파수·거점·초기 신뢰도·전문 분야), 페르소나와 세력별 거래 등급 설명(`trade_tiers`)은 `bridge/modules.py FACTIONS`. **전문 보상**: 그 세력이 남기는 보급품(선물·대가)에 등급별 전문 묶음을 더함(`Loot.SPECIALTY`, `Loot.roll(tier, fid)`). **전문 거래 품목**: `Trade.FACTION_GOODS`(doc 의약품, dewey·casey 도구 = 차량 부품·전자기기, hunter 총·근접·음식)가 기본 목록 대신 쓰임. 부탁은 세력마다 `Needs.TABLE`
   - 멀티: 채널(세력)별 대화는 모든 접속자가 공유, 답장 대기 중 들어온 발언은 모아서 한 번 더 요청
   - 거래 보상은 **근처 건물 보관함 보급 퀘스트**로 전달, 대가는 인벤토리에서 직접 제출
   - 희귀도: 5 총기·탄약·폭발물 > 4 도구·**의약품** > 3 근접 무기 > 2 음식 > 1 기타. 분류는 아이템 스크립트 `DisplayCategory`(총기 = `Weapon` + `AmmoType`)
   - 진행 단계: **A** 통합 창(탭: 교신/퀘스트/일지) + 세력 교신 — 구현 완료, 인게임 미검증 / **B** 희귀도·가치표, AI 거래 제안·거절, Lua 가치 검증, 대가 제출 창, 보상 보급 / **C** 좀비 무리 소탕 등 과제 퀘스트
   - **B단계 거래 (2026-09-27 구현, 인게임 미검증)**: 플레이어가 무전으로 물건을 요청하면 `Radio.request`가 발언자 기준 `Trade.context`(신뢰도별 한도·세력 성향·줄 수 있는 품목과 등급·받는 대가 품목)를 브릿지에 넘기고, AI는 답장과 함께 `trade = { action: none|offer|refuse, category, tier, pay_category }`를 반환. `Trade.fromReply`가 한도로 재검증(넘으면 등급을 낮추거나 버림)하고 실제 물건(`Trade.GOODS`, 총기는 `Loot.GUN`)과 가격(물건 가치 × 신뢰도 배율)을 게임이 정해 `trade` 퀘스트(proposed→accepted→completed|failed, 위치 없음)를 만듦. 수락 후 퀘스트 탭 "대가 고르기" → `TradePayWindow`(요구 품목 아이템만, 자동 선택, 가치 합계) → `tradePay`로 서버가 아이템 ID·품목·가치를 다시 검증하고 제거 → 물건은 1~2등급 거리 보급 퀘스트로 배송, 신뢰도 +3 (미지불 실패 -4, 등급 배율)
     - 신뢰도 한도: 0~19 거래 거부, 20~39 2등급·가격 2배, 40~59 3등급·1.5배, 60~79 4등급·1.2배, 80~100 5등급·1배
     - 세력: ray(음식 5·의약품 4·도구 3·근접 2·총기 1·탄약 2 / 받는 것 음식·의약품·도구·탄약), guard(총기·탄약 5까지지만 신뢰 60 이상에서만 / 의약품·도구·음식), rats(도구·근접 5, 총기·탄약 4, 신뢰 한도보다 1등급 위도 팔되 1.5배 더 비쌈 / 탄약·총기·의약품·도구)
     - 아이템 가치 `shared/StoryEngine/Value.lua`(서버·UI 공용): 총기 50, 탄약 상자 15(낱발 0.5, 탄창 5), 폭발물 20, 도구 8(희귀 20), 의약품 3(항생제 8), 근접 5(카타나 12), 음식 1.5, 기타 0.2. 분류는 `DisplayCategory`(총기 = Weapon + `isRanged`)
     - 한 제안은 한 품목만. 두 가지를 요청받으면 하나만 제안하고 나머지는 따로 (프롬프트로 강제, 실제 모델로 확인)
   - **C단계 좀비 무리 소탕 (2026-09-27 구현, 인게임 미검증)**: `horde` 퀘스트. NPC 부탁(`npc_request`)이 발동하면 물건 부탁 60% / 소탕 부탁 40%(`Director.HORDE_SHARE`, 빈도 제한 공유). `Quests.proposeHorde`가 등급 거리의 건물을 먼저 정하고 무전으로 부탁(proposed) → 수락하면 칸 로드 후 `addZombiesInOutfitArea`로 건물 경계 +8타일 사각형에 무리 배치(등급별 8/14/20/30/45마리) → `OnZombieDead`에서 건물 경계 +25타일 구역 안의 사망을 셈(좀비 개별 태그는 청크 언로드 시 사라질 수 있어 안 씀) → 80% 처치 시 완료, 가장 가까운 플레이어 근처(1등급 거리)에 해당 등급 보상 보급, 신뢰도 npc 규칙. 기한 = 거리 기반(`deadlineMinutes`), 넘기면 실패(좀비는 남겨 둠). 부탁 문장에는 영어 방향(플레이어 기준 명시)과 게임 언어 마을 이름을 넘김. 디버그 "소탕 부탁 강제"
   - 퀘스트 체계 (2026-09-27 개편): 종류 `supply_drop`(보관함 물품 모두 가져가면 완료, 보상 보급 포함) / `fetch`(전용 아이템 `StoryEngine.SealedDocuments|SealedParcel|PhotoAlbum`을 찾아 퀘스트 탭 "무전으로 제출" → 완료 + 보상 보급). 상태 `offered→approached→entered(→retrieved)` / 끝 `completed|failed`. **모든 퀘스트는 기한이 있고 넘기면 실패, 남은 퀘스트 아이템은 삭제**(칸이 안 로드됐으면 로드될 때 삭제, fetch는 플레이어 인벤토리의 것도). 등급 1~5 (2026-09-27 확장): 거리 1: 60~200(근처), 2: 200~500(같은 동네), 3: 500~1000(마을 끝), 4: 1000~2000 중 가장 가까운 마을에서 450타일 이상인 교외, 5: 플레이어가 있는 마을이 아닌 가까운 다른 마을 2~3곳 중 하나(중심 250타일 안). 기한 = 48시간 + 100타일당 10시간(이전의 2배), 부탁 답변 12시간, 부탁 전달 48 + 24×등급 시간. 퀘스트 소식은 경위(`origin`: source·faction·date)와 함께 **세력 무전 메시지**로 전달(디렉터가 신뢰도 가중치로 세력 선택). 디렉터 이벤트에 `fetch_item` 추가. 보상 구성은 `server/StoryEngine/Loot.lua`(5등급): 모든 등급에 같은 종류(음식·물, 의약품, 도구, 근접 무기, 총기)가 나오되 품질·양이 다름 — 1 흔한 도구·권총+낱발 중 하나, 2 쓸 만한 도구 + 근접 무기 또는 권총+상자, 3 좋은 권총 또는 사냥/바민트 소총+상자(70%), 4 희귀 도구(대형망치)·산탄총+2상자·항생제 (2026-09-27 사용자 요청으로 산탄총 4등급, 소총 3등급), 5 희귀 도구 2개·돌격소총+탄약 4상자+권총·의약품 세트. 탄창 총에는 탄창 포함. 디렉터 강도도 1~5(대부분 1~3, 4는 장거리 준비된 생존자, 5는 드물게), 규칙 기반 폴백 강도는 35/30/20/10/5%
   - 보상 보급(2026-09-27): `origin.rewardKind`(fetch/deliver/trade/horde)로 경위 문구·무전 문구를 구분(예전 세이브는 `rewardFor`로 추정). 물건을 넣은 보관함은 `setExplored(true)`로 표시해 처음 열 때 바닐라 루팅이 섞이지 않게 하고, 스프라이트 이름을 `q.containerSprite`로 기록. 클라이언트 `QuestHighlight.lua`가 25타일 안에서 그 보관함 오브젝트를 주황색으로 강조(`setHighlighted(true, false)`). 디버그 퀘스트 상태에 `left=N`(놓은 칸에 남은 태그 아이템 수) 표시. 세이브 확인: 태그 아이템은 `Saves/<모드>/<세이브>/map/<x/8>/<y/8>.bin` 안에 `storyQuest` 문자열로 남는다
   - 먼저 연락하기: 무전 응답 JSON에 `follow_up_hours`(0,1,2,3,4,6,8,12,24) + `follow_up_topic`. AI가 "알아보고 연락하겠다"고 하면 채널에 예약(`ch.followUp`, 채널당 1개) → 게임 시간이 되면 `mode = "follow_up"`으로 요청해 AI가 먼저 말함. 연쇄 예약 2번, 채널당 하루 4번까지. 콜백 보고는 구체적 관찰(좀비 수, 건물 상태 등)은 말하되 특정 물건·연료가 **있다고 단정하지 않도록** 프롬프트로 제한(게임 세계와 어긋나지 않게). 상태 줄에 "약 N시간 뒤 연락 예정" 표시
   - 신뢰도 (2026-09-27 개편, `server/StoryEngine/Trust.lua`): 대화로는 -1~+1만, 주로 **퀘스트 결과**로 움직임. **등급별 표 (2026-09-27 사용자 결정, `Trust.DELTA`)**: 완료 = +등급(1~5). npc(NPC가 먼저 부탁) 수락 0 / 거절 -2,-2,-1,-1,-1 / 무응답 -3,-2,-2,-1,-1 / 실패 -5,-4,-3,-2,-1, player(내가 청한 거래) 실패 -2,-2,-1,-1,-1, gift(NPC가 준 보급·구조 신호) 완료 +1 / 실패 -1, 보상 보급은 영향 없음. 변화는 채널에 `from = "system"` 줄로 기록. 거래 한도(20/40/60/80)까지 퀘스트 여러 개가 필요해짐. **진행 단계 (2026-09-27 사용자 결정, `Store.stage`)**: **서버(월드) 경과 일수**로 초반(1~30일)·중반(31~90)·후반(91~), 모든 플레이어 공통(`Store.serverDays`). 퀘스트·이벤트 최고 등급 2/4/5. 신뢰도 감점: 초반 x0.5(반올림, 최소 1), 중반 기본 표, **후반은 등급이 높을수록 큰 `Trust.LATE` 표**(npc 실패 -2/-4/-6/-8/-10, 무응답 -2~-6, 거절 -1~-5, 거래 실패 -1~-5, 보급 놓침 -2). 세력이 정하는 퀘스트는 세력 신뢰도로도 제한(0~19 → 2, 20~39 → 3, 40~59 → 4, 60+ → 5), 실제 등급 = 둘 중 낮은 쪽(`Director.tierCap`). 디렉터 AI에 단계와 상한을 알려 주고, 응답 강도도 다시 자름. **관계 시스템 (2026-09-27)**: 플레이어가 물건을 청하면 기본적으로 대가를 요구(프롬프트). 같은 세력에 **서버 전체 합산** 게임 시간 7일 안에 3번째 요청부터 매번 신뢰도 -1 + AI에 "의심" 전달(`Trade.recordRequest`, `ch.requests`). 신뢰도 60 이상이면 요청마다 35% 확률로 게임이 "이번엔 공짜"를 정해 AI에 알리고(AI에 맡기면 0/4로 거의 안 줌), AI가 `trade.action = "gift"`로 답하면 2등급 이하를 가까운 건물에 무상 배송(`Quests.giftTrade`, `origin.source = "gift_trade"`). 디렉터 `friend_gift`: 신뢰도 60 이상 세력이 3일 간격으로 2등급 이하 보급을 먼저 줌. 디렉터 `extortion`(DangerEvents 옵션): `threat = true` 세력(rats, guard) 중 신뢰도 10 이하인 곳이 5일 간격으로 협박 — `extort` 퀘스트(바로 accepted, 36시간, 요구 물건은 Needs), 제출하면 1등급 대가 + 신뢰도 +1, 기한을 넘기면 보복: 그 세력의 신뢰도를 **가장 최근에 떨어뜨린 플레이어**(`ch.lastOffender`, 퀘스트 감점·요청 과다·대화 -1에서 기록)에게, 혼자 접속 중이면 50% 헬기, 아니면 추적 무리. 대상이 접속해 있지 않으면 다음 접속 때. `Needs.lua`의 부탁은 세력마다 1~5등급 (4·5등급 예: 레이 트럭 수리·햄 라디오, 방위대 발전기·의료 키트, 패거리 소총·금고 털이 장비). 말투는 신뢰도 구간(0~19 적대, 20~39 경계, 40~59 중립, 60~79 호감, 80~100 친구)별 태도 지침을 프롬프트에 넣어 조절(`modules.py TRUST_TONES`, 세력 성격은 유지). NPC가 먼저 말할 때 언어는 대상 플레이어 > 접속자 > 채널 마지막 언어 > 서버 언어 순(`Radio.langFor`). **영어 답장 수정 (2026-09-27)**: 멀티에서 캐릭터 생성 직후 `hello`가 서버에 안 닿으면 `ps.lang`이 비어 발언이 `EN`으로 요청됐고, 그 값이 `ch.lang`에 남아 이후 NPC 발언도 영어가 됨 → 클라이언트가 무전 발언마다 `lang`을 보내고 게임 시작 후 `hello`를 한 번 더 보냄, 발언 폴백은 `langFor`, 접속자 언어를 채널 언어보다 먼저 봄. AI 기록의 영어 요약(번역 문장이 있는 자동 메시지)은 `auto`로 표시하고, 요청 끝에 "Speak only <언어>, 영어 단어 섞지 말 것"을 붙임. 브릿지 로그에 `lang=` 표시. NPC 부탁은 플레이어별로 받은 뒤 3.5~7일 간격(일주일에 1~2번), 새 캐릭터는 처음 2~4일 없음
   - NPC의 부탁 (`deliver` 퀘스트): 디렉터 이벤트 `npc_request` → 게임이 `server/StoryEngine/Needs.lua`(세력별·등급별 필요 물건과 사정)에서 고르고 AI가 무전으로 부탁(`mode = "request"`, 실패 시 준비된 문장). 상태 `proposed`(6시간 안에 교신 탭/퀘스트 탭의 수락·거절, 무응답이면 `declined` + ignored) → `accepted`(기한 24+12×등급 시간) → "무전으로 제출"로 물건을 넘기면 `completed` + 보상 보급, 기한 초과면 `failed`. 수락·거절·완료·실패마다 NPC가 무전으로 반응(`mode = "event"`, `Radio.react`, 채널이 바쁘면 대기열). 전달은 장착하지 않은 아이템부터, 손에 든 것은 `removeFromHands` 후 제거. 액체 용기(병, 기름통)는 빈 통 문제로 부탁 목록에서 제외
   - **다른 모드 아이템 (2026-09-27 구현, 인게임 미검증)**: `shared/StoryEngine/ItemPool.lua`가 시작할 때 설치된 전체 아이템을 속성으로 분류 (모드 출처 API가 없어 바닐라·모드 구분 없이). 음식 = 먹을 수 있고 상하지 않거나 밀봉(향신료·`minoringredient`·`driedfood`·위험한 날것·술·조리도구에 담긴 것 제외, `CantEat`은 금속 통조림과 Snack·Candy 상자만), 열량으로 1~5등급. 총 = `script:isRanged()`(또는 Weapon·FireArm 분류 + AmmoType) + 등록된 `AmmoType`(탄이 `Ammo` 분류). 분류 이름으로 판정하지 않는다: **MFS는 OnGameBoot/OnGameStart에 모든 총의 DisplayCategory를 `FireArm`으로 바꾼다**(`SetWeaponPartCategory.lua`). **등급은 쓰는 탄약 기준**(사용자 결정, `ItemPool.AMMO_TIERS`): 1 9mm·.38 / 2 .45·.357·.44 / 3 .30-30·.308 / 4 12게이지 / 5 5.56·5.45·5.8·.338, + 20발 이상 탄창 자동화기는 5, .50·14.5mm·유탄·화염연료 제외, 모르는 탄약은 3(로그에 표시, `items.txt`의 `ammo <등급|exclude> <낱발>`로 지정). 총 아이템 생성이 서버에서 실패하면(MFS 의심) 스크립트 정보만으로(탄창 모름, 상자는 `<낱발>Box`). **42.20.4 확인**: 스크립트 `Item:isSpice()`는 향신료가 아니라 음식 종류면 참 → 인스턴스 `Food:isSpice()` 사용, 태그는 `script:hasTag(ItemTag.MINOR_INGREDIENT)`. 탄약은 총의 `AmmoType:getItemKey()`(낱발)·`AmmoBox`·`MagazineType`으로 짝지음(상자 없으면 낱발). 근접 무기 = 피해 5분위. 보상(`Loot`)·거래(`Trade.roll`)에서 샌드박스 `StoryEngine.ModItemsRatio`(기본 40%) 확률로 음식·근접 무기는 한 개씩 비슷한 등급으로, 총은 묶음째 교체. 의약품·도구·음료·NPC 부탁(`Needs`)은 바닐라 그대로. 대가 가치(`Value`)도 같은 분류: 음식 = 열량/250(0.5~4), 음식 묶음(통조림 상자) = 무게×2.5, 총 = 등급별 30~80, 상한 음식 불가. 조정 파일 `Zomboid/Lua/StoryEngine/items.txt`(exclude/include, 없으면 설명과 함께 생성), 디버그 "아이템 분류"가 `itempool.txt`로 결과 출력. 오프라인 규칙 미리보기(바닐라+VFE+MFS): 음식 306개, 총 1등급 15·2등급 14·3등급 27·4등급 26·5등급 101, 제외 9
   - A단계 파일: `server/StoryEngine/Radio.lua`, `client/StoryEngine/MainWindow.lua`(기존 QuestWindow·JournalWindow 흡수), 브릿지 `build_radio` + `prompts/radio.md`. 이 단계에서 AI 출력이 게임에 주는 영향은 신뢰도 -3~+3 뿐
**남은 설계 항목 (2026-09-27 구현, 인게임 미검증)**:
   - 디렉터 이벤트 추가: `horde_nearby`(건강한 대상에게 50~80타일 밖에서 좀비 6/10/15/22/30마리가 걸어옴, 세력이 무전으로 경고, 2일 간격, 관측 2일 뒤부터), `helicopter`(`testHelicopter`, 서버 전체 5일 간격, 헬기 알림·독백·방위대 반응), `rescue_signal`(세력이 구조 신호를 전해 줌 = `supply_drop` + `origin.source = "rescue"`, 물건을 놓을 때 건물 안에 좀비 등급+1마리, 일지 사건 `rescue_*`, 3일 간격, 집에만 있거나 지루하면 가중치 3). 디버그 "새 이벤트 강제"
   - **추적 무리 (2026-09-27, `server/StoryEngine/Hunt.lua`)**: 호드 유도·협박 보복 무리는 `createHordeFromTo`(목표 지점 한 번만 받음, 추적 안 함) 대신 추적 무리로 만든다. ModData `hunts`에 남은 수·위치를 기억하고, 실제 좀비가 로드돼 있으면 게임 내 1분마다 `pathToCharacter`(12타일 안이면 `spotted`)로 대상을 다시 쫓게 함. 대상이 멀어져 좀비가 내려가면 가상으로 2타일/분 속도로 따라가다가 45타일 안·칸 로드 시 남은 수만큼 다시 만든다(30타일보다 가까우면 물려서, 세이브에 남은 같은 무리 좀비 `modData.storyHunt`는 재사용). 모두 처치하거나 대상이 죽으면 끝, 대상이 오프라인이면 멈춤. 디버그 상태 줄에 `hunts:`. **42.20.4 인게임 호스트 확인**: 서버에서 `IsoMovingObject:isExistInTheWorld()`는 살아 있는 좀비에도 거짓 → 무리 좀비는 매번 셀 좀비 목록에서 `modData.storyHunt`로 찾음. `addZombiesInOutfitArea`로 20마리 생성·태그·재발견은 확인됨. 로그 `hunt chasing <id> N zombies at x y dist D`(5분마다)로 추적 확인. **멀티 추적 (미검증)**: 인게임 호스트에서 서버의 `pathToCharacter`가 먹히지 않음(무리 위치 고정) → 좀비는 소유 클라이언트(`IsoZombie:getOwnerPlayer`)가 움직이는 구조로 보고, 서버가 무리 좀비를 소유자별로 묶어 `huntChase { ids = 좀비 online ID, target = 대상 online ID }`를 보내면 `client/StoryEngine/HuntClient.lua`가 20틱마다 그 좀비에게 `pathToCharacter`/`spotted`. 디버그 "추적 무리 테스트"(`debugHuntNear`): 10타일 거리에 10마리 바로 생성. **인게임 호스트 확인 (2026-09-27)**: 클라이언트 추적으로 무리가 따라옴(22 → 15타일). 테스트 중 무리가 사라진 것은 사용자가 디버그로 좀비를 지운 것(설계대로 재생성됨). 소유권 이동 등으로 잠깐 안 보일 경우를 대비해 3분 연속 안 보이고 마지막 위치가 대상에게서 50타일 이상일 때만 가상으로 전환, 가까운데 30분 안 보이면 추적 종료. 멀티에서 서버가 좀비 경로를 바꿀 수 있는지는 미확인
   - **멀티 규칙 (2026-09-27 사용자 결정)**: 디렉터 이벤트 간격은 모두 서버 전체 기준(`director` 상태의 `lastSupplyT`·`lastFriendT`·`lastHordeNearT`·`lastHeliT`). NPC가 먼저 청하는 일(npc_request·fetch_item·rescue_signal·extortion)은 하나의 관문(`Director.askOpen`): 마지막 요청 뒤 4일이 지나면 하루 한 번 50%, 다음 날 60% … +10%씩 굴려 그날 열림. 호드 규모는 진행 단계별 20/40/60(`Hunt.SIZE_BY_STAGE`), 호드 유도는 접속한 모든 플레이어에게 각각 추적 무리. 한 곳에 오래 머물기: 반경 150타일 안에 4일 이상이면 하루 한 번 30%, +10%/일로 굴려 당첨 시 그 플레이어에게 추적 무리 + "무언가 몰려온다" 알림(DangerEvents 옵션). 퀘스트 참여자(`q.helpers`): 진행 중 장소 40타일 안에 있었거나, 근처에서 좀비를 잡았거나, 진입·완료·제출·지불한 사람. 완료 반응에서 NPC가 참여자에게 이름으로 감사하고, 접속 중인 비참여자에게는 그날 한 일(집에만 있음·혼자 파밍·원정·자기 싸움·잠)로 비아냥. 퀘스트 창에 "참여:" 줄
   - 퀘스트 전투 기록: 진행 중인 위치 퀘스트 반경 40타일 안의 처치(`OnZombieDead`)·부상(Sensor 새 부상)을 `q.fight = { kills, hurt, bitten }`로 붙임 → 일지 사건("a fight: ..."), NPC 완료 반응 설명, 퀘스트 창 "근처 전투" 줄
   - 스토리 로그 압축 (`server/StoryEngine/Summary.lua`, 브릿지 `summary` 모듈, 설정 없으면 journal 설정): 관측 7일마다 주간 요약(`ps.weeks`, 영어 90단어, 실패 시 규칙 요약) → 일기(지난주), 회고록(요약된 주 + 이후 날), 디렉터(지난주). 무전 채널이 프롬프트 창(16줄) 밖으로 12줄 밀려나면 NPC 기억 메모(`ch.memory`, 140단어)로 합침
   - 서버 옵션(샌드박스 StoryEngine 페이지): AI 디렉터, 디렉터 NPC 부탁, 디렉터 호드·헬기, 생존 일지 켜기/끄기 (`StoryEngine.option`)
5. 독백 — **구현 완료, 인게임 미검증 (2026-09-27)**. `server/StoryEngine/Monologue.lua`: 게임 내 1분마다 계기 판정(깨어남·물림·체력 위험·첫 킬·킬 이정표·부상·처음 가 보는 마을·무들 2단계 이상 상승, 디렉터 폭풍, 보급 회수·소탕 완료), 플레이어별 최소 간격(샌드박스 `StoryEngine.MonologueGap` 기본 120분, 물림·체력 위험·첫 킬은 무시) + 계기별 간격, 무들·부상·폭풍은 3문장 풀(`ps.mono.pools`, 3일 만료, 풀용 요청에는 시각·장소·날씨·최근 사건을 넣지 않음), 실패·오프라인·`MonologueAI` 끔이면 `IGUI_StoryEngine_Mono_<계기>_1~3` 대체 문장. 표시는 클라이언트 `addLineChatElement`(옅은 파란색, 다른 플레이어에게 안 보임). 브릿지 `build_monologue` + `prompts/monologue.md`, 모델은 `gpt-6-luna` effort low (경량 모델로 바꿀 후보). 샌드박스 옵션 첫 도입: `media/sandbox-options.txt` + `Translate/<언어>/Sandbox.json`. 멀티에서 서버 측 무들·부상 값이 정확한지는 6단계에서 확인
6. 멀티플레이 테스트 — **인게임 호스트 검증 완료 (2026-09-27, 42.20.4)**: 브릿지 연결, 서버/클라이언트 상태 일치(위치·체력·킬·수면·실내외·부상·무들), 서버 이벤트, 보급 표시·제출 시 인벤토리 차감, 클라이언트 번역, 독백·일지·부탁·소탕·신뢰도. 남은 확인: 무전기 없이 교신·제출(`RequireRadio` 기본 꺼짐). **전용 서버는 당분간 지원·테스트하지 않음**(사용자 결정: 인게임 호스트만 사용). 나중에 한다면 확인할 것: 서버 설치 경로와 `-cachedir`에 따른 브릿지 `data_dir`, `OnTick` 발생 여부, 서버 언어. 서버 아이템 동기화(`Items.lua`)와 서버용 폭풍 함수로 수정. 진단 명령 "StoryEngine: 멀티 진단"(`debugSync`, `server/StoryEngine/Diag.lua`): 서버가 보는 위치·체력·킬·수면·실내외·부상 수·무들을 클라이언트 값과 비교하고, 서버에서 실제로 오는 이벤트 수(`OnTick`·`EveryOneMinute`·`OnPlayerUpdate`·`OnZombieDead`·`OnHitZombie`·`OnPlayerDeath`), 서버 언어, 파일 쓰기 가능 여부를 로그로 남김. 알려진 문제: 서버에서 `getText`로 만드는 문장(무전 템플릿, 대체 문장, 방향 단어)은 **서버 언어**로 나옴 — 전용 서버는 보통 EN
