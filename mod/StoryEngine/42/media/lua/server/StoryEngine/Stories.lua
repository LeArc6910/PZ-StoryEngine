-- NPC 각자의 이야기, NPC 사이 관계, 여러 세력이 얽히는 위기 (서버 측 전용, 데이터만).
-- 진행은 Social.lua 가 한다. 문장은 전부 AI 에게 넘기는 영어 사실이다 (Lua 문자열은 ASCII 만).
--
-- 이야기 노드:
--   beat   지금 그 NPC 의 삶에서 일어나는 일 (NPC 가 먼저 연락해서 들려준다)
--   days   이 노드에 머무는 최소 게임 일수 (지나면 next 로)
--   next   다음 노드 id, 또는 { default = id, flags = { 플래그 = id, ... } } (먼저 맞는 플래그)
--   quest  연계 퀘스트 { tier, why, items } -> 완료면 win, 실패·거절·무응답이면 lose 로
--   final  끝 (계속 그 상태로 이야기한다)
--   hit    이 노드에 들어설 때 그 NPC 의 생활 자원 변화 (Life.onBeat): 불행은 -, 행운은 +
--   bonds  이 노드에 들어설 때 NPC 사이 관계 변화 { { from, to, d, why } } (Bonds.onBeat)
-- 플래그는 위기 선택으로 붙는다: <위기id>_helped (선택받음) / _snubbed (선택받지 못함) / _ignored,
-- 선택받은 쪽의 후속 퀘스트 결과로 <위기id>_done / _failed.
-- 선택지의 allies = 이 선택이 그 NPC 의 바람도 이뤄 준다 (함께 도운 것으로: _helped, 신뢰도 +1, 결과 플래그도 같이)
--          spares = 이 선택을 그 NPC 가 이해한다 (외면 감점 없음) — 2026-09-30 점검 (교회 습격에서 방위대를 고르면
--          교회가 외면당한 것으로 처리되던 문제)

if isClient() then return end

require "StoryEngine/Core"

local Stories = {}
StoryEngine.Stories = Stories

Stories.ARCS = {
    ray = {
        { id = "ray_1", days = 2, next = "ray_2",
          beat = "You keep a notebook of radio frequencies and spend the evenings trying to raise anyone in Louisville, where your daughter Annie lived. No answer yet." },
        { id = "ray_2", days = 2, next = "ray_3",
          beat = "Your vegetable patch is finally coming in, but raccoons and the dead keep trampling it. You talk about planting extra for when Annie comes home." },
        { id = "ray_3", days = 1, win = "ray_4a", lose = "ray_4b",
          beat = "Last night you heard a faint woman's voice on the radio that might have come from Louisville. You need batteries to keep listening through the night.",
          quest = { tier = 1, why = "he heard a voice that might be his daughter and needs batteries to keep the radio on all night", items = { { "Base.Battery", 3 } } } },
        { id = "ray_4a", days = 3, next = { default = "ray_5", flags = { truck_helped = "ray_4t" } },
          beat = "With the batteries you caught the voice again: it was Annie, alive, at a church shelter in Louisville. You are overjoyed and scared at the same time." },
        { id = "ray_4t", hit = { food = 15, morale = 10 }, days = 2, next = "ray_5",
          beat = "The food from the crashed truck fed your neighbours for a week, and they promised to watch the farm while you go to Louisville." },
        { id = "ray_4b", hit = { morale = -15 }, days = 3, next = "ray_5b",
          beat = "The batteries died and the voice was lost. You blame yourself, sleep badly and have been drinking at night." },
        { id = "ray_5", days = 1, win = "ray_6a", lose = "ray_6b",
          beat = "You are fixing your old pickup to drive to Louisville for Annie, but the battery is dead.",
          quest = { tier = 3, why = "he is fixing his pickup to drive to Louisville for his daughter and the battery is dead", items = { { "Base.CarBattery1", 1 } } } },
        { id = "ray_5b", days = 1, win = "ray_4a", lose = "ray_end_bad",
          beat = "You want to try once more to reach Louisville, but your radio needs parts to reach that far.",
          quest = { tier = 2, why = "he wants one more try at reaching his daughter in Louisville and his radio needs parts", items = { { "Base.ElectronicsScrap", 4 }, { "Base.Battery", 2 } } } },
        { id = "ray_6a", final = true,
          beat = "You left the farm in your pickup to find Annie in Louisville. You radio in from the road when you can, full of hope and nerves." },
        { id = "ray_6b", hit = { morale = -10 }, final = true,
          beat = "The pickup never started. You stay on the farm, tending the garden for a daughter you may never see again." },
        { id = "ray_end_bad", hit = { morale = -20 }, final = true,
          beat = "You gave up on reaching Louisville. You talk less than you used to and sometimes leave the radio off for days." },
    },
    casey = {
        { id = "casey_1", days = 2, next = "casey_2",
          beat = "Your father has been coughing for days and runs a fever at night. You read medical books from the library between broadcasts." },
        { id = "casey_2", days = 1, win = "casey_3a", lose = "casey_3b",
          beat = "Your father's fever is climbing and you have nothing to bring it down.",
          quest = { tier = 1, why = "their sick father's fever keeps climbing", items = { { "Base.Pills", 2 }, { "Base.WaterRationCan", 2 } } } },
        { id = "casey_3a", days = 3, next = { default = "casey_4", flags = { signal_helped = "casey_4s", signal_snubbed = "casey_4x" } },
          beat = "The fever broke a little. Feeling braver, you are building a bigger antenna on the roof to reach more people." },
        { id = "casey_3b", hit = { medical = -10, morale = -10 }, days = 2, next = "casey_4b",
          beat = "Your father got worse. You barely sleep, and you keep the radio on just to hear another voice." },
        { id = "casey_4s", hit = { morale = 15 }, days = 2, next = "casey_4",
          beat = "With the players' help your boosted signal reached a group of survivors in Brandenburg. You talk to them every night and cannot stop smiling." },
        { id = "casey_4x", hit = { morale = -10 }, days = 2, next = "casey_4",
          beat = "The strange signal went silent before you could answer it. You are hurt that nobody helped you, but you try not to show it." },
        { id = "casey_4", days = 1, win = "casey_5a", lose = "casey_5b",
          beat = "Your father's cough turned into an infection in his chest. You need real medicine now.",
          quest = { tier = 3, why = "their father's chest infection needs antibiotics", items = { { "Base.Antibiotics", 1 } } } },
        { id = "casey_4b", days = 1, win = "casey_5a", lose = "casey_5b",
          beat = "Your father is fighting for breath. You are terrified and ask anyone who will listen for medicine.",
          quest = { tier = 3, why = "their father is fighting for breath and needs antibiotics and painkillers", items = { { "Base.Antibiotics", 1 }, { "Base.Pills", 2 } } } },
        { id = "casey_5a", final = true,
          beat = "Your father is recovering. You are teaching him Morse code from his bed and you sound younger and happier than before." },
        { id = "casey_5b", hit = { morale = -20 }, final = true,
          beat = "Your father died. You are alone in the radio shack, and you keep broadcasting so that nobody else has to feel alone." },
    },
    doc = {
        { id = "doc_1", days = 2, next = "doc_2",
          beat = "Your clinic has four patients, including a teenage boy with a badly broken leg who asks you every morning when he can walk." },
        { id = "doc_2", days = 1, win = "doc_3a", lose = "doc_3b",
          beat = "The boy's leg needs to be set properly and you are out of splints.",
          quest = { tier = 2, why = "she has to set a boy's broken leg and is out of splints and bandages", items = { { "Base.Splint", 2 }, { "Base.Bandage", 4 } } } },
        { id = "doc_3a", hit = { morale = 10 }, days = 3, next = { default = "doc_4", flags = { fever_helped = "doc_4f", fever_snubbed = "doc_4x" } },
          beat = "The boy is walking with a crutch and teasing the other patients. You allowed yourself a laugh for the first time in weeks." },
        { id = "doc_3b", hit = { morale = -10 }, days = 3, next = "doc_4",
          beat = "The leg healed crooked. The boy will limp for life, and you are bitter about how little you have to work with." },
        { id = "doc_4f", hit = { medical = 10, morale = 10 }, days = 2, next = "doc_4",
          beat = "The medicine the players brought stopped the fever in your clinic. Nobody died, and you have not stopped saying so." },
        { id = "doc_4x", hit = { medical = -15, morale = -10 }, days = 2, next = "doc_4",
          beat = "The fever took one of your patients because the medicine went somewhere else. You are cold and quiet about it." },
        { id = "doc_4", days = 1, win = "doc_5a", lose = "doc_5b",
          beat = "A stranger stumbled into the clinic with a deep gash, and you have nothing left to close it with.",
          quest = { tier = 2, why = "a stranger came in with a deep gash and she has nothing to close it with", items = { { "Base.SutureNeedle", 2 }, { "Base.Disinfectant", 2 } } } },
        { id = "doc_5a", final = true,
          beat = "The clinic is stable. You are training your recovered patients as helpers and have started to sleep a little." },
        { id = "doc_5b", hit = { morale = -20 }, final = true,
          beat = "You lost the stranger. You are thinking about closing the clinic, and you sound exhausted." },
    },
    pike = {
        { id = "pike_1", days = 2, next = "pike_2",
          beat = "Twelve refugees sleep in your church. There was a quarrel over rations last night and you had to step between two men." },
        { id = "pike_2", days = 1, win = "pike_3a", lose = "pike_3b",
          beat = "The pantry is nearly empty and there are children to feed.",
          quest = { tier = 2, why = "his church pantry is nearly empty and there are children to feed", items = { { "Base.TinnedBeans", 4 }, { "Base.TinnedSoup", 2 } } } },
        { id = "pike_3a", hit = { food = 10 }, days = 3, next = { default = "pike_4", flags = { raid_helped = "pike_4r", raid_snubbed = "pike_4x" } },
          beat = "Your flock is fed. They started a garden behind the church and sing while they work." },
        { id = "pike_3b", hit = { food = -10, morale = -10 }, days = 3, next = "pike_4",
          beat = "Two hungry families left for the city. You pray for them every night." },
        { id = "pike_4r", bonds = { { "rats", "pike", -1, "the preacher's church held against your crew" } }, hit = { safety = 10, morale = 10 }, days = 2, next = "pike_4",
          beat = "Thanks to the players the church held when Vic's crew came sniffing around. Your people call the players friends now." },
        { id = "pike_4x", bonds = { { "pike", "rats", -1, "Vic's crew cleaned out the church storeroom" } }, hit = { food = -20, safety = -10 }, days = 2, next = "pike_4",
          beat = "Vic's crew cleaned out the church storeroom. You have forgiven them, but your people are frightened." },
        { id = "pike_4", days = 1, win = "pike_5a", lose = "pike_5b",
          beat = "The dead pressed against the church doors last night. You need to board the windows before they come back.",
          quest = { tier = 2, why = "the dead pressed against his church doors and he needs to board the windows", items = { { "Base.NailsBox", 1 }, { "Base.Hammer", 1 } } } },
        { id = "pike_5a", final = true,
          beat = "The church is a real refuge now. You ring the bell on Sundays and people come from miles around." },
        { id = "pike_5b", hit = { safety = -20, morale = -20 }, final = true,
          beat = "The dead broke in one night and three of your people died. You blame yourself and moved everyone into the basement." },
    },
    dewey = {
        { id = "dewey_1", days = 2, next = "dewey_2",
          beat = "You are building a truck you call the Ark out of three wrecks, big enough to carry a dozen people out of the county." },
        { id = "dewey_2", days = 1, win = "dewey_3a", lose = "dewey_3b",
          beat = "The Ark's engine needs parts you cannot find.",
          quest = { tier = 2, why = "the engine of the truck he is building needs parts", items = { { "Base.EngineParts", 2 }, { "Base.DuctTape", 2 } } } },
        { id = "dewey_3a", hit = { morale = 10 }, days = 3, next = { default = "dewey_4", flags = { signal_helped = "dewey_4s" } },
          beat = "The Ark's engine turned over for the first time. You whooped so loud the dead came to the fence." },
        { id = "dewey_3b", hit = { morale = -10 }, days = 3, next = "dewey_4",
          beat = "The Ark's engine seized. You swear about it constantly and it set you back weeks." },
        { id = "dewey_4s", bonds = { { "casey", "dewey", -1, "Dewey stripped the relay tower Casey wanted to use" } }, days = 2, next = "dewey_4",
          beat = "The wire from the relay tower let you rig lights and a radio into the Ark. It looks like a real rescue truck now." },
        { id = "dewey_4", days = 1, win = "dewey_5a", lose = "dewey_5b",
          beat = "The Ark needs a battery and armor plating before it can leave the garage.",
          quest = { tier = 3, why = "his rescue truck needs a battery and armor plating", items = { { "Base.CarBattery1", 1 }, { "Base.SheetMetal", 2 } } } },
        { id = "dewey_5a", final = true,
          beat = "The Ark runs. You offer rides and dream out loud about a convoy out of the county." },
        { id = "dewey_5b", hit = { morale = -10 }, final = true,
          beat = "The Ark is shelved. You fix other people's cars instead, grumbling, but you still talk about it." },
    },
    guard = {
        { id = "guard_1", days = 2, next = "guard_2",
          beat = "Your squad is down to seven soldiers. Command has not answered in weeks, but you keep the watch schedule anyway." },
        { id = "guard_2", days = 2, next = "guard_3",
          beat = "Two privates were overheard talking about deserting. You put them on double watch and said nothing more." },
        { id = "guard_3", days = 1, win = "guard_4a", lose = "guard_4b",
          beat = "A fever is spreading through the camp and the aid kit is empty.",
          quest = { tier = 3, why = "a fever is spreading through his camp", items = { { "Base.Antibiotics", 2 } } } },
        { id = "guard_4a", days = 3, next = { default = "guard_5", flags = { truck_helped = "guard_4t" } },
          beat = "The fever is beaten and the squad is loyal again. You grudgingly admit civilians came through for you." },
        { id = "guard_4b", hit = { safety = -15, morale = -10 }, days = 3, next = "guard_5",
          beat = "One soldier died of the fever and two deserted in the night. You are stone-faced about it." },
        { id = "guard_4t", bonds = { { "ray", "guard", -1, "the soldiers took the truck's cargo that could have fed families" } }, hit = { safety = 20 }, days = 2, next = "guard_5",
          beat = "The military cargo from the crashed truck restocked the camp. You are planning a push to clear the highway checkpoint." },
        { id = "guard_5", days = 1, win = "guard_6a", lose = "guard_6b",
          beat = "You are planning an operation to clear the highway checkpoint and need ammunition and field dressings.",
          quest = { tier = 4, why = "he is planning an operation to clear the highway checkpoint", items = { { "Base.556Box", 1 }, { "Base.Bandage", 4 } } } },
        { id = "guard_6a", hit = { safety = 10, morale = 10 }, final = true,
          beat = "The squad cleared the highway checkpoint. You let civilians pass through it safely and sound almost proud." },
        { id = "guard_6b", hit = { safety = -20, morale = -15 }, final = true,
          beat = "The operation failed and the squad fell back to the camp. You are more closed off than ever." },
    },
    rats = {
        { id = "rats_1", days = 2, next = "rats_2",
          beat = "Your crew is six people. Your second, Dutch, keeps saying you should rob survivors instead of scavenging." },
        { id = "rats_2", days = 2, next = "rats_3",
          beat = "Dutch took two men out on a 'job' without asking you. You are uneasy and pretend you are not." },
        { id = "rats_3", days = 1, win = "rats_4a", lose = "rats_4b",
          beat = "Payday is coming and the crew is restless. You need something to hand out to keep them loyal.",
          quest = { tier = 2, why = "he needs something to pay his restless crew to keep them loyal", items = { { "Base.ShotgunShellsBox", 1 } } } },
        { id = "rats_4a", days = 3, next = { default = "rats_5", flags = { raid_helped = "rats_4r" } },
          beat = "You kept the crew in line. Dutch is sulking in a corner, which suits you fine." },
        { id = "rats_4b", hit = { safety = -10, morale = -10 }, days = 3, next = "rats_5",
          beat = "Dutch challenged you openly and half the crew listened to him." },
        { id = "rats_4r", bonds = { { "pike", "rats", -1, "Vic's crew robbed the church storeroom" }, { "rats", "pike", -1, "you robbed the preacher's storeroom" } }, hit = { food = 10, morale = 10 }, days = 2, next = "rats_5",
          beat = "The church job paid off and the crew loves you again. Dutch has gone quiet." },
        { id = "rats_5", days = 1, win = "rats_6a", lose = "rats_6b",
          beat = "You want to crack the old bank vault in Coalfield, a big score to prove you are still the boss.",
          quest = { tier = 3, why = "he wants to crack a bank vault to prove he is still the boss", items = { { "Base.Crowbar", 1 }, { "Base.Sledgehammer", 1 } } } },
        { id = "rats_6a", final = true,
          beat = "The vault score made you untouchable. You are turning the crew into traders and raiding less." },
        { id = "rats_6b", hit = { morale = -15 }, final = true,
          beat = "Dutch took over the crew. You still call sometimes, but your voice is lower and the crew is more dangerous." },
    },
    hunter = {
        { id = "hunter_1", days = 2, next = "hunter_2",
          beat = "A big black bear keeps raiding your trap lines, and you are tracking it." },
        { id = "hunter_2", days = 3, next = "hunter_3",
          beat = "You found a dead hiker in the woods and buried him. You do not say more than that." },
        { id = "hunter_3", days = 1, win = "hunter_4a", lose = "hunter_4b",
          beat = "The bear hurt your dog. You mean to finish it, and you are low on rifle ammunition.",
          quest = { tier = 3, why = "a bear hurt his dog and he is low on rifle ammunition", items = { { "Base.308Box", 1 } } } },
        { id = "hunter_4a", hit = { food = 15 }, days = 3, next = { default = "hunter_5", flags = { signal_helped = "hunter_4s" } },
          beat = "You got the bear. There is smoked meat for weeks, and you almost smiled telling it." },
        { id = "hunter_4b", hit = { morale = -15 }, days = 3, next = "hunter_5",
          beat = "The bear killed your dog. You buried it by the creek and you are colder than ever." },
        { id = "hunter_4s", days = 2, next = "hunter_5",
          beat = "You scouted the signal tower yourself. It was bait set by bandits. You told only the players." },
        { id = "hunter_5", days = 1, win = "hunter_6a", lose = "hunter_6b",
          beat = "Winter will come early in the woods and you need to set new trap lines.",
          quest = { tier = 2, why = "he needs to set new trap lines before winter", items = { { "Base.HuntingKnife", 1 }, { "Base.Twine", 2 } } } },
        { id = "hunter_6a", final = true,
          beat = "You are ready for winter. You call the players 'neighbor' now, which is a lot, coming from you." },
        { id = "hunter_6b", hit = { food = -15, morale = -10 }, final = true,
          beat = "Your winter preparations failed. You are thinking about leaving the county for good." },
    },
}

-- NPC 사이 관계: relation 은 AI 가 읽는 한 줄 (내가 그 사람을 어떻게 보는지)
Stories.RELATIONS = {
    ray = {
        casey = "you worry about that kid like your own and talk to them most nights",
        pike = "an old friend; you trade seeds for prayers",
        rats = "you think Vic's crew are vultures picking over the dead",
        dewey = "you like him and hope his truck could get you to Louisville",
    },
    casey = {
        ray = "he is like an uncle on the radio and you trust him completely",
        doc = "you admire June and ask her medical questions about your father",
        hunter = "Hank scares you a little but he once warned you about raiders",
        guard = "you are nervous around the soldiers' radio procedure",
    },
    doc = {
        pike = "you respect how he looks after people, though you do not share his faith",
        guard = "you resent that the soldiers hoard medicine",
        casey = "you worry about that kid alone with a sick father",
        rats = "you have patched up Vic's crew before and never been thanked",
    },
    pike = {
        rats = "you pray for Vic's crew, and you lock the storeroom",
        ray = "an old friend and a good man",
        doc = "a blessing to the county, though she works herself too hard",
        guard = "you are wary of men with guns who answer to nobody",
    },
    dewey = {
        rats = "Vic sells you parts and cheats you on every one",
        ray = "he keeps asking about the truck and you like the man",
        hunter = "Hank fixed your rifle once without a word; you respect him",
        casey = "the kid helps you with wiring over the radio",
    },
    guard = {
        rats = "you consider Vic's crew armed looters and would arrest them if you could",
        hunter = "you suspect Tolliver knows more about the raiders than he says",
        doc = "you need her skills but she will not play by your rules",
        casey = "you monitor the kid's broadcasts; too much chatter on the air",
    },
    rats = {
        guard = "the soldiers would shoot your crew on sight and you know it",
        pike = "the preacher has a full storeroom and too few guns",
        dewey = "Dewey is a good customer who complains too much",
        doc = "June patched up your men once; you owe her, which you hate",
    },
    hunter = {
        guard = "soldiers with no orders are the most dangerous thing in the county",
        rats = "Vic's men set snares on your land; you have a score to settle",
        casey = "the kid talks too much on the air, but you keep an eye out for them",
        dewey = "Dewey is decent; he does not waste your time",
    },
}

-- NPC 사이 관계를 숫자로 (관계 파급, Life.spill): [그 NPC][다른 NPC] = +1 친함 / -1 적대. RELATIONS 문장과 맞춘다.
-- 누군가를 크게 도우면 그를 좋아하는 NPC 는 신뢰도 +1, 싫어하는 NPC 는 -1.
Stories.BONDS = {
    ray = { casey = 1, pike = 1, rats = -1, dewey = 1 },
    casey = { ray = 1, doc = 1 },
    doc = { pike = 1, guard = -1, casey = 1, rats = -1 },
    pike = { rats = -1, ray = 1, doc = 1, guard = -1 },
    dewey = { rats = -1, ray = 1, hunter = 1, casey = 1 },
    guard = { rats = -1, hunter = -1 },
    rats = { guard = -1 },
    hunter = { guard = -1, rats = -1, casey = 1, dewey = 1 },
}

-- AI 에게 넘기는 영어 이름 (소문·위기 문장에 쓴다)
Stories.NAMES = {
    ray = "Ray Mercer", casey = "Casey Liu", doc = "June Adler (the Riverside nurse)", pike = "Brother Amos Pike",
    dewey = "Dewey Hollis", guard = "Sergeant Whitaker's squad", rats = "Vic's Coalfield Crew", hunter = "Hank Tolliver",
}

-- 이야기할 때 얼마나 자주 먼저 연락하는지 (가중치)
Stories.TALKATIVE = { casey = 3, ray = 3, pike = 2, doc = 2, dewey = 2, rats = 1.5, guard = 1, hunter = 0.7 }

-- 여러 세력이 동시에 부탁하는 위기. 플레이어는 하나만 고른다.
-- trigger = true: 무작위로는 나오지 않고 사건이 일어날 때만 (NpcEvents: clash)
Stories.CRISES = {
    -- 큰 사건 "군 헬기 추락"(Saga.lua)의 고비에서만. 추락 현장 상자에 서류·탄약·의약품이 함께 들어 있다
    { id = "heli_crash", trigger = true, plain = true,     -- plain: 현장 상자 물건으로 채우게 (부탁 점수 난이도 없음)
      situation = "A military helicopter came down in the county. Its cargo (sealed papers, ammunition and medical supplies) is in a crate at the wreck, and the dead are drawn to it.",
      options = {
          { faction = "guard", ask = "bring the sealed military papers from the wreck to the camp before anyone else reads them",
            tier = 3, items = { { "StoryEngine.SealedDocuments", 1 } } },
          { faction = "rats", ask = "bring him the ammunition from the wreck first; he promises to share",
            tier = 3, items = { { "Base.556Box", 2 } } },
          { faction = "doc", ask = "bring the medical supplies from the wreck, in case the crew or anyone hurt nearby survived",
            tier = 3, items = { { "Base.Antibiotics", 1 }, { "Base.Bandage", 4 } }, spares = { "guard" } },
      } },
    { id = "clash", trigger = true,
      situation = "Sergeant Whitaker's squad and Vic's crew traded fire near Coalfield. Both sides have wounded and both want the players on their side.",
      options = {
          { faction = "guard", ask = "bring ammunition so the squad can finish what they started with Vic's crew",
            tier = 3, items = { { "Base.556Box", 1 } } },
          { faction = "rats", ask = "bring bandages and painkillers for his wounded crew",
            tier = 2, items = { { "Base.Bandage", 4 }, { "Base.Pills", 2 } }, spares = { "doc" } },
          { faction = "doc", ask = "bring dressings so she can patch up the wounded from both sides",
            tier = 2, items = { { "Base.Bandage", 4 }, { "Base.Disinfectant", 1 } }, spares = { "guard", "rats" } },
      } },
    { id = "truck",
      situation = "A military supply truck overturned on the highway south of Muldraugh. Its cargo is scattered and the dead are gathering around it.",
      options = {
          { faction = "ray", ask = "bring him the canned food from the truck for the families near his farm",
            tier = 2, items = { { "Base.TinnedBeans", 4 } } },
          { faction = "rats", ask = "strip the truck before anyone else and bring him the tools",
            tier = 2, items = { { "Base.Crowbar", 1 }, { "Base.Hammer", 1 } } },
          { faction = "guard", ask = "secure the military medical supplies and bring them to the camp",
            tier = 3, items = { { "Base.Bandage", 4 }, { "Base.Antibiotics", 1 } } },
      } },
    { id = "fever",
      situation = "A fever is spreading through the county. Everyone who still has antibiotics is holding on to them.",
      options = {
          { faction = "doc", ask = "bring medicine for the sick patients in her clinic",
            tier = 3, items = { { "Base.Antibiotics", 1 }, { "Base.Pills", 2 } } },
          { faction = "pike", ask = "bring medicine and clean water for the sick children in his church",
            tier = 2, items = { { "Base.Pills", 2 }, { "Base.WaterRationCan", 3 } } },
          { faction = "guard", ask = "bring antibiotics for his sick soldiers",
            tier = 3, items = { { "Base.Antibiotics", 2 } } },
      } },
    { id = "signal",
      situation = "A strong unknown signal is broadcasting from a relay tower near Valley Station. Nobody knows who is sending it.",
      options = {
          { faction = "casey", ask = "bring batteries and parts so they can boost their rig and answer the signal",
            tier = 2, items = { { "Base.Battery", 4 }, { "Base.ElectronicsScrap", 3 } } },
          { faction = "dewey", ask = "strip the tower for wire and screws for his truck before anyone else does",
            tier = 2, items = { { "Base.ElectricWire", 3 }, { "Base.ScrewsBox", 1 } }, spares = { "hunter" } },
          { faction = "hunter", ask = "bring him rifle ammunition so he can scout the tower himself, because he thinks it is a trap",
            tier = 3, items = { { "Base.308Box", 1 } }, spares = { "casey" } },
      } },
    { id = "raid",
      situation = "Vic's crew is planning to hit Brother Pike's church storeroom in March Ridge.",
      options = {
          { faction = "pike", ask = "bring nails and a hammer to board up the church storeroom before they come",
            tier = 2, items = { { "Base.NailsBox", 1 }, { "Base.Hammer", 1 } }, spares = { "guard" } },
          { faction = "rats", ask = "look the other way and bring him a crowbar for the storeroom door, for a cut of the take",
            tier = 1, items = { { "Base.Crowbar", 1 } } },
          { faction = "guard", ask = "supply shotgun shells so he can send a patrol to protect the church",
            tier = 2, items = { { "Base.ShotgunShellsBox", 1 } }, allies = { "pike" } },
      } },
}

function Stories.node(fid, id)
    for _, n in ipairs(Stories.ARCS[fid] or {}) do
        if n.id == id then return n end
    end
    return nil
end

-- 위기 선택지 정의 (fid 의 선택지)
function Stories.crisisOption(id, fid)
    local c = Stories.crisis(id)
    for _, o in ipairs(c and c.options or {}) do
        if o.faction == fid then return o end
    end
    return nil
end

-- 이 선택(chosen)에서 fid 는 어떤 처지인가: "chosen" | "ally" | "spared" | "snubbed"
function Stories.crisisRole(id, chosen, fid)
    if fid == chosen then return "chosen" end
    local o = Stories.crisisOption(id, chosen) or {}
    for _, a in ipairs(o.allies or {}) do if a == fid then return "ally" end end
    for _, a in ipairs(o.spares or {}) do if a == fid then return "spared" end end
    return "snubbed"
end

function Stories.crisis(id)
    for _, c in ipairs(Stories.CRISES) do
        if c.id == id then return c end
    end
    return nil
end

return Stories
