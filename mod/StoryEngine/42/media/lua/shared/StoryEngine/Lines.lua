-- AI 없이 쓰는 대사 (2026-10-03). 브릿지가 꺼져 있거나 AI 답이 실패했을 때 대신 내보내는 준비된 문장.
-- 문장은 번역 파일에만 있다 (Lua 문자열은 ASCII 만). 서버는 키와 인자(lt)만 보내고 클라이언트가 자기 언어로 그린다.
--
--   NPC 대사   IGUI_StoryEngine_Line_<npc>_<kind>_<n>   (NPC 마다 말투가 다르다. 개수는 Lines.COUNT)
--   이야기     IGUI_StoryEngine_Story_<노드 id>           (Stories.ARCS 의 beat 를 그 NPC 가 직접 말하는 문장)
--   동료 대화  IGUI_StoryEngine_Banter_<묶음>_<n>_a|b     (말 꺼내기 a, 받기 b)
--   일기       IGUI_StoryEngine_Diary_<...>               (Journal.fallbackText 가 여러 문장을 잇는다)
-- 번역 키가 빠졌는지는 tests/run_lua_tests.py 가 KO/EN 모두 검사한다.

require "StoryEngine/Core"

local Lines = {}
StoryEngine.Lines = Lines

-- NPC 대사 종류별 문장 수 (모든 NPC 가 같은 수). only = 이 NPC 들만 (나머지는 alt 로)
Lines.COUNT = {
    -- 퀘스트 위치 안내 (AI 와 상관없이 늘 이 문장): 인자 마을, 방향, 거리, 물건|빈칸
    supply_drop = 2, fetch = 2, rescue = 2, reward = 2, reward_trade = 2, reward_horde = 2,
    -- 부탁 (인자 물건 목록), 소탕 부탁 (마을, 방향, 거리, 수), 무리 경고 (수, 방향)
    request = 2, horde = 2, horde_warning = 2,
    -- 퀘스트 결과에 대한 반응
    q_accepted = 2, q_declined = 2, q_ignored = 2, q_thanks = 2, q_failed = 2, horde_thanks = 2,
    trade_failed = 2, rescue_done = 1, rescue_failed = 1,
    -- 그 밖의 사건
    donation = 2, heli = 2, npc_died = 2, player_died = 2, survived = 1,
    fate_warn = 1, fate_goodbye = 1, project_done = 1, project_progress = 2,
    crisis_appeal = 2, crisis_thanks = 2, crisis_snub = 2, crisis_ignored = 1,
    world_power = 1, world_water = 1, world_winter = 1,
    -- 먼저 거는 잡담 (Social.pickContact 의 이유)
    chat_morning = 2, chat_evening = 2, chat_storm = 1, chat_miss = 2, chat_checkin = 3,
    -- 플레이어가 말했는데 AI 가 없을 때, 버튼 거래 (Trade.ask)
    offline_reply = 2, offer = 2, gift = 1, refuse = 1,
    -- 공용 주파수 (예약 장면, 플레이어 말에 반응)
    open_chat = 3, open_reply = 2,
    -- 위협 세력만
    extort = 2, extort_paid = 1,
    -- 다른 대가 (Work.lua): 일 장소 안내(마을, 방향, 거리), 외상(기한 일수), 빚, 일 끝, 빚 부탁(물건 목록)
    work_horde = 1, work_fetch = 1, work_scout = 1, work_guard = 1, work_courier = 1, work_credit = 1, work_favor = 1,
    work_done = 1, work_paid = 1, favor_call = 1,
    -- 아는 얼굴의 좀비 (Named.lua): 부탁(이름, 마을, 방향, 거리), 끝난 뒤 감사(이름)
    named_ask = 1, named_thanks = 1,
    -- 유품 회수 (Recover.lua): 알려 주기(죽은 사람, 마을, 방향, 거리), 찾은 뒤(죽은 사람)
    recover_ask = 1, recover_found = 1,
    -- 명절 (Holiday.lua): 예고, 잔치 (명절 이름)
    holiday_soon = 1, holiday_feast = 1,
}
-- 이 종류는 이 NPC 들만. 다른 대가(work_*)는 2026-10-05부터 모든 NPC, 찾아오기는 예전 세이브용
Lines.ONLY = {
    extort = { guard = true, rats = true },
    extort_paid = { guard = true, rats = true },
    work_fetch = { ray = true, casey = true, doc = true, dewey = true, rats = true },
}

-- 이 NPC 대사가 없을 때 쓰는 공통 문장 (예전 키)
Lines.ALT = {
    supply_drop = "IGUI_StoryEngine_RadioSay_supply_drop", fetch = "IGUI_StoryEngine_RadioSay_fetch",
    rescue = "IGUI_StoryEngine_RadioSay_rescue", reward = "IGUI_StoryEngine_RadioSay_reward",
    reward_trade = "IGUI_StoryEngine_RadioSay_reward_trade", reward_horde = "IGUI_StoryEngine_RadioSay_reward_horde",
    request = "IGUI_StoryEngine_RadioSay_request", horde = "IGUI_StoryEngine_RadioSay_horde",
    horde_warning = "IGUI_StoryEngine_RadioSay_horde_warning", extort = "IGUI_StoryEngine_RadioSay_extort",
    donation = "IGUI_StoryEngine_RadioSay_donation", fate_warn = "IGUI_StoryEngine_RadioSay_fate_warn",
    fate_goodbye = "IGUI_StoryEngine_RadioSay_fate_goodbye", project_done = "IGUI_StoryEngine_RadioSay_project_done",
    favor_call = "IGUI_StoryEngine_RadioSay_request",
}

-- 동료 대화 묶음별 문장 쌍 수 (Banter 대체). 혼잣말 계기는 a 대신 그 혼잣말 문장(Mono)을 쓰고 b 만 쓴다
Lines.BANTER = { chat = 4, fight = 3, danger = 3, hurt = 3, mood = 3, good = 3, bad = 2, death = 2, help = 2, radio = 2 }
Lines.BANTER_GROUP = {
    chat = "chat", fight = "fight",
    horde_near = "danger", armed_attack = "danger", helicopter = "danger", storm = "danger", support_left = "danger",
    bitten = "hurt", wounded = "hurt", low_health = "hurt", pain = "hurt", sick = "hurt",
    panic = "mood", stress = "mood", unhappy = "mood", bored = "mood", hungry = "mood", thirsty = "mood", tired = "mood",
    first_kill = "good", kills = "good", supply_found = "good", horde_cleared = "good", quest_completed = "good",
    new_town = "good", wake = "good",
    quest_accepted = "help", support_arrived = "help",
    quest_failed = "bad", death = "death", radio = "radio",
}
-- 혼잣말 계기(Monologue.TRIGGERS)면 말을 꺼내는 쪽은 그 혼잣말 대체 문장 (Monologue.fallbackText)

local function roll(n)
    if n <= 1 then return 1 end
    return ZombRand(n) + 1
end

function Lines.has(fid, kind)
    if not Lines.COUNT[kind] then return false end
    local only = Lines.ONLY[kind]
    return not only or only[fid] == true
end

-- NPC 대사 lt. 이 NPC 에게 없는 종류면 공통 문장(alt), 그것도 없으면 nil
function Lines.lt(fid, kind, args)
    local alt = Lines.ALT[kind]
    if not Lines.has(fid, kind) then
        return alt and { key = alt, args = args } or nil
    end
    local key = "IGUI_StoryEngine_Line_" .. tostring(fid) .. "_" .. kind .. "_" .. StoryEngine.intToString(roll(Lines.COUNT[kind]))
    return { key = key, alt = alt, args = args }
end

-- Radio.react 의 fallback 형태: { text = AI 기록용 영어, lt }
function Lines.fallback(fid, kind, text, args)
    local lt = Lines.lt(fid, kind, args)
    if not lt then return text end
    return { text = text, lt = lt }
end

-- 이야기 장면을 그 NPC 가 직접 말하는 문장
function Lines.story(nodeId)
    return { key = "IGUI_StoryEngine_Story_" .. tostring(nodeId) }
end

-- 동료 대화 한 쌍: a, b (lt). 혼잣말 계기면 부르는 쪽이 a 를 혼잣말 문장으로 바꾼다
function Lines.banter(event)
    local group = Lines.BANTER_GROUP[event] or "chat"
    local n = roll(Lines.BANTER[group] or 1)
    local base = "IGUI_StoryEngine_Banter_" .. group .. "_" .. StoryEngine.intToString(n)
    return { key = base .. "_a" }, { key = base .. "_b" }
end

return Lines
