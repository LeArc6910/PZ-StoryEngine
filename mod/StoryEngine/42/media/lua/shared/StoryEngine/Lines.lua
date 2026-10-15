-- AI 없이 쓰는 대사 (2026-10-03). 브릿지가 꺼져 있거나 AI 답이 실패했을 때 대신 내보내는 준비된 문장.
-- 문장은 번역 파일에만 있다 (Lua 문자열은 ASCII 만). 서버는 키와 인자(lt)만 보내고 클라이언트가 자기 언어로 그린다.
--
--   NPC 대사   IGUI_StoryEngine_Line_<npc>_<kind>_<n>   (NPC 마다 말투가 다르다. 개수는 Lines.COUNT)
--   이야기     IGUI_StoryEngine_Story_<노드 id>           (Stories.ARCS 의 beat 를 그 NPC 가 직접 말하는 문장)
--   동료 대화  IGUI_StoryEngine_Banter_<묶음>_<n>_a|b     (말 꺼내기 a, 받기 b)
--   일기       IGUI_StoryEngine_Diary_<...>               (Journal.fallbackText 가 여러 문장을 잇는다)
-- 번역 키가 빠졌는지는 tests/run_lua_tests.py 가 KO/EN 모두 검사한다.

require "StoryEngine/Core"
require "StoryEngine/LinesData"

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
    -- AI 없는 공용 주파수 대화 (2026-10-05, Social.offlineLines): 두 사람 사이(좋음·보통·나쁨)별 꺼내기·받기·맺기(%1 상대),
    -- 사건 화제 꺼내기(%1 상대, %2 사람·명절 이름)와 받기(%1 꺼낸 사람), 플레이어 말 종류별 대답(%1 플레이어)
    duo_warm_open = 2, duo_warm_reply = 2, duo_warm_close = 1,
    duo_plain_open = 2, duo_plain_reply = 2, duo_plain_close = 1,
    duo_cold_open = 2, duo_cold_reply = 2, duo_cold_close = 1,
    topic_storm = 1, topic_heli = 1, topic_death = 1, topic_power = 1, topic_water = 1, topic_winter = 1,
    topic_share = 1, topic_clash = 1, topic_holiday = 1, topic_reply = 3,
    topic_politics = 1,         -- 의회의 표결이 끝난 뒤 (Politics.vote -> Social.queueTopic)
    player_greet = 2, player_help = 1, player_trade = 1, player_info = 1, player_thanks = 1,
    -- 위협 세력만
    extort = 2, extort_paid = 1,
    -- 다른 대가 (Work.lua): 일 장소 안내(마을, 방향, 거리), 외상(기한 일수), 빚, 일 끝, 빚 부탁(물건 목록)
    work_horde = 1, work_fetch = 1, work_scout = 1, work_guard = 1, work_courier = 1, work_credit = 1, work_favor = 1,
    work_done = 1, work_paid = 1, favor_call = 1,
    -- 일거리 청하기·보상 사양 (2026-10-06): 일 장소 안내(마을, 방향, 거리), 끝난 뒤 감사, 보상을 남겨 준 데 감사
    volunteer_ask = 1, volunteer_done = 1, reward_waived = 1,
    -- 아는 얼굴의 좀비 (Named.lua): 부탁(이름, 마을, 방향, 거리), 끝난 뒤 감사(이름)
    named_ask = 1, named_thanks = 1,
    -- 명절 (Holiday.lua): 예고, 잔치 (명절 이름)
    holiday_soon = 1, holiday_feast = 1,
}
-- 이 종류는 이 NPC 들만. 다른 대가(work_*)는 2026-10-05부터 모든 NPC, 찾아오기는 예전 세이브용
Lines.ONLY = {
    extort = { guard = true, rats = true },
    extort_paid = { guard = true, rats = true },
    work_fetch = { ray = true, casey = true, doc = true, dewey = true, rats = true },
}

-- 후임 목소리(Voices.lua)의 대사 종류별 문장 수: IGUI_StoryEngine_Line_<후임>_<종류>_<n>.
-- 여기 없는 종류는 앞 사람(그 채널의 처음 NPC) 대사를 쓴다
Lines.VOICE_COUNT = {
    q_accepted = 1, q_declined = 1, q_ignored = 1, q_thanks = 1, q_failed = 1, request = 1,
    offer = 1, refuse = 1, offline_reply = 1, chat_checkin = 2, chat_morning = 1, chat_evening = 1,
    -- 2026-10-08: 나머지 종류도 후임 말투로 (아는 얼굴의 좀비·예전 찾아오기는 후임 채널에서 나오지 않음)
    supply_drop = 1, fetch = 1, rescue = 1, reward = 1, reward_trade = 1, reward_horde = 1, horde = 1,
    horde_warning = 1, horde_thanks = 1, trade_failed = 1, rescue_done = 1, rescue_failed = 1, donation = 1,
    heli = 1, npc_died = 1, player_died = 1, survived = 1, fate_warn = 1, fate_goodbye = 1, project_done = 1,
    project_progress = 1, crisis_appeal = 1, crisis_thanks = 1, crisis_snub = 1, crisis_ignored = 1,
    world_power = 1, world_water = 1, world_winter = 1, chat_storm = 1, chat_miss = 1, gift = 1,
    open_chat = 1, open_reply = 1, duo_warm_open = 1, duo_warm_reply = 1, duo_warm_close = 1,
    duo_plain_open = 1, duo_plain_reply = 1, duo_plain_close = 1, duo_cold_open = 1, duo_cold_reply = 1,
    duo_cold_close = 1, topic_storm = 1, topic_heli = 1, topic_death = 1, topic_power = 1, topic_water = 1,
    topic_winter = 1, topic_share = 1, topic_clash = 1, topic_holiday = 1, topic_reply = 1, player_greet = 1,
    topic_politics = 1,
    player_help = 1, player_trade = 1, player_info = 1, player_thanks = 1, extort = 1, extort_paid = 1,
    work_horde = 1, work_scout = 1, work_guard = 1, work_courier = 1, work_credit = 1, work_favor = 1,
    work_done = 1, work_paid = 1, favor_call = 1, volunteer_ask = 1, volunteer_done = 1, reward_waived = 1,
    holiday_soon = 1, holiday_feast = 1,
}
-- 이 종류는 이 후임들만 (협박은 방위대·빅 채널뿐)
Lines.VOICE_ONLY = {
    extort = { kowalski = true, red = true, dutch = true },
    extort_paid = { kowalski = true, red = true, dutch = true },
}
Lines.VOICES = { "martha", "nora", "sam", "esther", "lenny", "kowalski", "red", "dutch", "caleb" }

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

local function data() return StoryEngine.LinesData or {} end

-- ---------------------------------------------------------------- 고르는 방식 (2026-10-15)
-- 1. 다 쓰기 전엔 반복하지 않는다: 말한 사람·종류마다 쓴 문장을 기억해 두고(Lines.memoryFn, 서버는 세이브),
--    남은 것 중에서만 고른다. 다 쓰면 새로 한 바퀴 (방금 한 말은 빼고).
-- 2. 조건 꼬리표: LinesData.TAGS 의 "winter,warm" 같은 꼬리표가 붙은 문장은 그 조건일 때만 나오고, 맞으면 더 자주 나온다.
--    꼬리표 묶음(계절·시간·날씨·신뢰·단계)마다 하나라도 맞아야 한다. 꼬리표 없는 문장은 늘 나온다.
Lines.TAG_GROUP = {
    spring = "season", summer = "season", fall = "season", winter = "season",
    morning = "time", day = "time", evening = "time", night = "time",
    rain = "weather", snow = "weather", fog = "weather", clear = "weather",
    cold = "trust", mid = "trust", warm = "trust", early = "stage", late = "stage",
    nopower = "nopower", nowater = "nowater", council = "council",
}
Lines.TAG_WEIGHT = 3
-- 서버가 채운다: contextFn(fid) -> { season, time, weather, trust, stage, nopower, nowater, council }, memoryFn() -> 세이브 표
Lines.contextFn = nil
Lines.memoryFn = nil
local session = {}

local function memory()
    if Lines.memoryFn then
        local ok, m = pcall(Lines.memoryFn)
        if ok and type(m) == "table" then return m end
    end
    return session
end

function Lines.context(fid)
    if not Lines.contextFn then return nil end
    local ok, ctx = pcall(Lines.contextFn, fid)
    return ok and type(ctx) == "table" and ctx or nil
end

-- 꼬리표가 지금 맞나: 맞음, 꼬리표가 있었나
function Lines.fits(tags, ctx)
    if not tags or tags == "" then return true, false end
    local need = {}
    for t in string.gmatch(tags, "[^,%s]+") do
        local g = Lines.TAG_GROUP[t]
        if g then
            if need[g] == nil then need[g] = false end
            local v = ctx and ctx[g]
            if v == t or v == true then need[g] = true end
        end
    end
    for _, ok in pairs(need) do
        if not ok then return false, true end
    end
    return true, true
end

-- 1..n 중 하나. bagKey 마다 쓴 번호를 기억한다. tagsOf[i] = 꼬리표 문자열
function Lines.pick(bagKey, n, tagsOf, ctx)
    n = math.floor(tonumber(n) or 1)
    if n <= 1 then return 1 end
    local mem = memory()
    local bag = mem[bagKey]
    if type(bag) ~= "table" then
        bag = { u = {} }
        mem[bagKey] = bag
    end
    if type(bag.u) ~= "table" then bag.u = {} end
    local function choose(fresh, useTags)
        local total, list = 0, {}
        for i = 1, n do
            if (not fresh or not bag.u[i]) and i ~= bag.l then
                local ok, tagged = true, false
                if useTags then ok, tagged = Lines.fits(tagsOf and tagsOf[i], ctx) end
                if ok then
                    local w = tagged and Lines.TAG_WEIGHT or 1
                    list[#list + 1] = { i, w }
                    total = total + w
                end
            end
        end
        if total <= 0 then return nil end
        local r = ZombRand(math.floor(total * 100)) / 100
        for _, e in ipairs(list) do
            r = r - e[2]
            if r < 0 then return e[1] end
        end
        return list[#list][1]
    end
    local i = choose(true, true)
    if not i then
        bag.u = {}
        i = choose(true, true) or choose(true, false) or choose(false, false) or 1
    end
    bag.u[i] = true
    bag.l = i
    return i
end

function Lines.has(fid, kind)
    local c = data().COUNT and data().COUNT[fid]
    if c and (c[kind] or 0) > 0 then return true end
    if not Lines.COUNT[kind] then return false end
    local only = Lines.ONLY[kind]
    return not only or only[fid] == true
end

-- 이 말한 사람(NPC·후임·밖에서 온 사람)의 이 종류 문장 수
local function countOf(speaker, kind, fallback)
    local c = data().COUNT and data().COUNT[speaker]
    if c and (c[kind] or 0) > 0 then return c[kind] end
    return fallback
end

-- 번호를 골라 키를 만든다. fid 는 신뢰도 꼬리표를 볼 채널
local function lineKey(speaker, kind, n, fid)
    local tags = data().TAGS and data().TAGS[speaker] and data().TAGS[speaker][kind] or nil
    local i = Lines.pick(speaker .. ":" .. kind, n, tags, Lines.context(fid or speaker))
    return "IGUI_StoryEngine_Line_" .. tostring(speaker) .. "_" .. kind .. "_" .. StoryEngine.intToString(i)
end

-- 지금 이 채널에서 이 종류를 그 사람 말투로 말할 수 있나 (공통 문장 alt 는 빼고)
function Lines.speaks(fid, kind)
    local F = StoryEngine.Factions
    if F and F.isOutsider and F.isOutsider(fid) then
        return countOf(fid, kind, Lines.OUTSIDER_COUNT[kind]) ~= nil
    end
    local voice = F and F.voice and F.voice[fid]
    local vonly = Lines.VOICE_ONLY[kind]
    if voice and countOf(voice, kind, Lines.VOICE_COUNT[kind]) and (not vonly or vonly[voice]) then return true end
    return Lines.has(fid, kind)
end

-- NPC 대사 lt. 이 NPC 에게 없는 종류면 공통 문장(alt), 그것도 없으면 nil
-- 플레이어가 공용 주파수에 한 말의 종류 (AI 가 없을 때 준비된 대답을 고른다, 2026-10-05). 앞에서부터 처음 맞는 것.
-- 여기는 영어 낱말(ASCII). 클라이언트는 IGUI_StoryEngine_Intent_<종류>(쉼표로 나눈 자기 언어 낱말)도 더해 고른다
Lines.INTENTS = {
    { "help", { "help", "hurt", "bitten", "danger", "sos", "injured", "chased" } },
    { "trade", { "trade", "buy", "sell", "need", "have any", "looking for", "spare", "swap" } },
    { "thanks", { "thank", "thx", "appreciate" } },
    { "info", { "where", "news", "what's up", "whats up", "weather", "info", "how are" } },
    { "greet", { "hello", " hi ", "hey", "anyone", "anybody", "greetings", "is someone", "can you hear" } },
}
Lines.INTENT_KINDS = { help = true, trade = true, thanks = true, info = true, greet = true }

-- extra = { 종류 = { 낱말, ... } } (클라이언트의 자기 언어 낱말)
function Lines.intentOf(text, extra)
    local t = string.lower(" " .. tostring(text or "") .. " ")
    for _, row in ipairs(Lines.INTENTS) do
        for _, w in ipairs(row[2]) do
            if string.find(t, w, 1, true) then return row[1] end
        end
        for _, w in ipairs((extra or {})[row[1]] or {}) do
            if w ~= "" and string.find(t, string.lower(w), 1, true) then return row[1] end
        end
    end
    return nil
end

-- 밖에서 온 사람들의 준비된 대사 (한 줄씩). 여기 없는 종류는 공통 문장(alt)이나 영어 대체 문장으로
Lines.OUTSIDER_COUNT = {
    q_accepted = 1, q_declined = 1, q_ignored = 1, q_thanks = 1, q_failed = 1, request = 1, reward = 1,
    offline_reply = 1, chat_checkin = 1, volunteer_ask = 1, volunteer_done = 1,
    out_hello = 1, out_bye = 1, out_spec = 1, out_gift = 1, out_appeal = 1, out_cold = 1,
    reward_trade = 1, trade_failed = 1, reward_waived = 1, favor_call = 1,
    -- 공용 주파수 장면에서 원래 NPC 의 말을 받는 줄 (Social.offlineLines)
    open_reply = 1, topic_reply = 1, duo_plain_reply = 1, duo_cold_reply = 1,
}

function Lines.lt(fid, kind, args)
    local alt = Lines.ALT[kind]
    local F = StoryEngine.Factions
    if F and F.isOutsider and F.isOutsider(fid) then
        local n = countOf(fid, kind, Lines.OUTSIDER_COUNT[kind])
        if n then return { key = lineKey(fid, kind, n, fid), alt = alt, args = args } end
        return alt and { key = alt, args = args } or nil
    end
    local voice = F and F.voice and F.voice[fid]
    local vonly = Lines.VOICE_ONLY[kind]
    local vn = voice and countOf(voice, kind, Lines.VOICE_COUNT[kind])
    if vn and (not vonly or vonly[voice]) then
        return { key = lineKey(voice, kind, vn, fid), alt = alt, args = args }
    end
    if not Lines.has(fid, kind) then
        return alt and { key = alt, args = args } or nil
    end
    return { key = lineKey(fid, kind, countOf(fid, kind, Lines.COUNT[kind]), fid), alt = alt, args = args }
end

-- 혼잣말 대체 문장 키 (Monologue.fallbackText)
function Lines.monoKey(trig)
    local n = (data().MONO or {})[trig] or 3
    return "IGUI_StoryEngine_Mono_" .. tostring(trig) .. "_" .. StoryEngine.intToString(Lines.pick("mono:" .. tostring(trig), n))
end

-- 일기·회고록 문장 키. base = "Diary_kills_many" 처럼. 예전 키가 번호 없이 하나뿐이면 1번은 그 키,
-- 2번부터 _2, _3 ... (from1 이면 처음부터 _1). n0·from1 은 LinesData 가 없을 때의 값
function Lines.variant(base, n0, from1)
    local v = (data().VARIANTS or {})[base]
    local n = v and v[1] or n0 or 1
    if v then from1 = v[2] == true end
    local i = Lines.pick("var:" .. base, n)
    if i == 1 and not from1 then return "IGUI_StoryEngine_" .. base end
    return "IGUI_StoryEngine_" .. base .. "_" .. StoryEngine.intToString(i)
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
    local n = Lines.pick("banter:" .. group, (data().BANTER or {})[group] or Lines.BANTER[group] or 1)
    local base = "IGUI_StoryEngine_Banter_" .. group .. "_" .. StoryEngine.intToString(n)
    return { key = base .. "_a" }, { key = base .. "_b" }
end

return Lines
