# 소개 영상·스크린샷 대본 (영어판)

창작마당 소개용. 화면에 나오는 글자, 무전에 치는 말, 자막은 모두 영어로 한다. 이 문서의 설명은 한국어, 따옴표 안은 그대로 쓸 영어 문장이다.

## 0. 촬영 전 준비

### 게임

- 게임 언어를 **English**로 둔다. 모드 화면 글자와 NPC의 대답 언어가 이것을 따른다(NPC는 말을 건 캐릭터의 언어로 답한다).
- 창 모드 또는 테두리 없는 창, **1920x1080**. 전체 화면 독점 모드는 캡처가 안 될 수 있다.
- 촬영 전용 새 세이브 하나(예: `Showcase`). 시작 위치는 **West Point** (레이 머서의 거점이 가까워 이야기가 자연스럽다).
- 게임을 `-debug`로 켠다. 디버그 메뉴(`Story Engine (debug)`)로 장면을 부르되, **메뉴를 여는 모습은 찍지 않는다.** 장면을 부른 뒤 녹화를 시작한다.
- 시간은 낮, 날씨는 맑게. 녹화 중에는 바닐라 채팅 창을 닫는다.
- 메인 창(`K`)은 크게 띄운다. 기본 1000x640보다 키워 두면 글씨가 잘 읽힌다(크기는 기억된다).

### 브릿지

- **mock 말고 실제 모델**로. 대답은 매번 달라지므로 마음에 드는 대답이 나올 때까지 같은 장면을 몇 번 다시 찍는다.
- 브릿지 콘솔, `config.toml`, 환경 변수 창이 화면에 나오지 않게 한다(API 키).

### 녹화

- OBS, 1080p 60fps, 게임 창만 캡처.
- 글을 읽어야 하는 장면은 일반 게임 영상보다 2~3배 오래 보여 준다. 자막은 한 줄당 최소 2.5초.
- 음악은 저작권 없는 것(YouTube 오디오 보관함 등). 게임 소리는 낮게.

### 촬영 전 디버그로 맞춰 둘 것

| 할 일 | 메뉴 |
|---|---|
| 레이 신뢰도를 60 정도로 | NPCs > `set trust (Ray Mercer, ...)` (교신 탭에서 레이를 고른 뒤) |
| 레이의 형편을 보기 좋게 | NPCs > `set supplies (...)` > `reset to baseline` |
| 공용 주파수, 위기, 방송 장면을 미리 한 번씩 돌려 대답 확인 | 아래 각 장면 참고 |

## 1. 트레일러 (약 90초)

흐름: **"말을 걸었더니 → 실제 장소에서 일이 생기고 → 해결하면 → 그날 밤 일기가 된다."** 한 사건을 끝까지 보여 준 뒤 나머지 기능은 빠른 몽타주로.

### 장면 1. 첫마디 (0:00–0:12)

- 화면: 메인 창의 **Radio** 탭, Ray Mercer 채널.
- 플레이어가 무전 칸에 천천히 친다:
  > "Ray, you there? I'm in West Point. Dead quiet out here, and I'm down to my last can of beans."
- 레이의 대답이 뜨는 데까지 그대로 둔다(기다리는 시간은 편집에서 자른다).
- 자막: **"Talk to survivors over the radio."** → **"They answer. In character."**

### 장면 2. 부탁 (0:12–0:24)

- 미리: Director & quests > `force horde request` (레이가 나올 때까지 다시. 신뢰도를 올려 두면 레이가 잘 뽑힌다).
- 화면: 레이가 실제 건물 이름과 방향을 대며 소탕을 부탁하는 무전 → **Quests** 탭의 수락 대기 → 수락.
- 자막: **"Their requests point to real places on your map."**

### 장면 3. 지도 (0:24–0:30)

- 화면: 지도를 열면 그 건물에 느낌표. 살짝 확대.
- 자막: **"No invented coordinates. The mod picks the spot, the AI tells the story."**

### 장면 4. 현장 (0:30–0:45) — 직접 플레이

- 그 건물에 가서 좀비 무리와 싸운다. 짧게 잘라 리듬감 있게.
- 끝나면 레이의 감사 무전(머리 위 글이나 무전 창), 신뢰도가 오르는 시스템 줄.
- 자막: **"Help them, and they remember."**

### 장면 5. 보상 (0:45–0:52)

- 화면: 보상 보급이 놓인 건물에서 **주황색으로 빛나는 보관함** → 열어서 물건.
- 자막: **"Rewards are real items, placed in the world."**

### 장면 6. 그날 밤의 일기 (0:52–1:05) — 가장 중요한 장면

- 미리: Checks > `write journal now` (실제로는 자정에 써진다).
- 화면: **Journal** 탭, 방금의 일(레이의 부탁, 싸움, 보급)이 담긴 일기. 천천히 스크롤하거나 한 문단을 오래 보여 준다.
- 자막: **"Every night, your day becomes a journal entry."**

### 장면 7. 몽타주 (1:05–1:22) — 장면당 2~3초

순서대로 빠르게. 각 장면은 미리 디버그로 부르고 대답을 확인해 둔다.

| # | 장면 | 미리 부르는 메뉴 | 자막 |
|---|---|---|---|
| a | 공용 주파수에서 NPC 셋이 서로 이야기 | NPCs > `open channel scene now` | "Survivors talk to each other." |
| b | 위기 선택지 (누구를 도울지 버튼 셋) | NPCs > `crisis choice now` | "Choose who to help. Others won't forget." |
| c | 바닐라 라디오를 105.4에 맞춰 저녁 뉴스 | World & events > `radio evening news now` | "Tune in to the evening news." |
| d | 캐릭터 머리 위 혼잣말 | Character > `force monologue` | "Your character thinks out loud." |
| e | **People** 탭의 큰 이야기 문단 | (그대로) | "Every contact has a story that changes with you." |
| f | **Bases** 탭의 형편 막대·프로젝트 | (그대로) | "They live on what you bring them." |
| g | **Council** 탭의 표결 | NPCs > Council politics > `Open politics now` → `A camp proposes a bill` | "Late game: county politics." |

### 장면 8. 마무리 카드 (1:22–1:30)

검은 화면이나 흐린 게임 화면 위에 글자만:

> **AI Story Engine**
> for Project Zomboid Build 42
>
> Claude · ChatGPT · Gemini · DeepSeek
> Singleplayer & hosted multiplayer
> Plays without AI too — prepared lines for every contact
>
> Free companion app + your own API key

마지막 줄은 꼭 넣는다. 설치 전에 API 키가 필요하다는 걸 알아야 실망한 평이 덜 달린다.

## 2. 스크린샷 (8장)

장마다 하나만 말한다. 아래 문구는 이미지 위에 작게 넣거나 창작마당 스크린샷 설명에 쓴다.

| # | 화면 | 문구 |
|---|---|---|
| 1 | Radio 탭, 레이와 자연스럽게 오간 대화 | "Talk to survivors over the radio — they answer in character." |
| 2 | 지도 느낌표 + 주황 보관함 (두 장을 나란히) | "Every request points to a real place." |
| 3 | Journal 탭의 일기 한 편 | "Your day, written as a journal entry every night." |
| 4 | People 탭의 큰 이야기 문단 | "Eight survivors, each with a story that changes with your choices." |
| 5 | 공용 주파수 장면 (NPC 셋) | "They talk to each other — and about you." |
| 6 | 위기 선택 버튼 | "Help one, disappoint another." |
| 7 | Bases 탭 (자원 막대, 프로젝트 진척) | "They live on what you bring them." |
| 8 | Council 탭 표결 | "Late game: bills, votes and elections." |

대표 이미지(preview): 정사각형, **1MB 미만**. 무전기 사진이나 Radio 탭 일부 + 큰 글자 "AI Story Engine" 정도로 단순하게.

## 3. 무전에 쳐 볼 영어 문장

대답이 좋게 나오기 쉬운 문장들. 장소·상황을 하나 넣고, 질문은 하나만.

- Ray: "Ray, how's the farm holding up? Saw smoke out past West Point this morning."
- June (Doc): "Doc, I took a nasty cut on my arm clearing a house. What should I do?"
- Casey: "Casey, anything on the scanners tonight? It's way too quiet here."
- Brother Pike: "Pastor, do you ever wonder if anyone's coming for us?"
- Dewey: "Dewey, my truck's been coughing all day. Any idea what that is?"
- Sgt. Whitaker: "Sergeant, is Knox still sending anyone out?"
- Vic: "Vic, I hear you're the guy to ask for tools. What's it gonna cost me?"
- Hank: "Hank, you seen any big groups moving through the woods?"
- Open channel: "Anyone out there? I've got spare canned food if someone needs it."

마지막 문장은 공용 주파수 판매 시장을 보여 준다(여러 NPC가 각자 제안).

## 4. 설치 안내 영상 (따로, 2~3분)

트레일러와 나눈다.

1. 창작마당에서 구독
2. GitHub 릴리스에서 브릿지 zip 받기 → 압축 풀기
3. 설정 마법사에서 제공자 고르고 API 키 넣기 (**키는 화면에서 가린다**)
4. 브릿지 켠 채로 게임 시작 → 우클릭 메뉴의 Radio → 첫 무전
5. AI 없이 쓰는 방법(브릿지를 안 켜도 준비된 대사로 돌아감)
6. 멀티플레이: 호스트 PC에서 브릿지 실행

## 5. 편집 메모

- 첫 5초 안에 "AI와 무전한다"가 보여야 한다. 로고나 긴 인트로는 넣지 않는다.
- 대답이 뜨기 전 기다리는 시간은 자르거나 2배속.
- 글을 읽는 장면에는 천천히 확대(살짝 줌 인)를 줘서 정지 화면처럼 보이지 않게.
- 자막 글꼴은 굵은 산세리프, 아래 가운데, 반투명 검은 띠.
