-- 내면 독백 (서버 측 전용). 무들 변화와 사건에 짧은 혼잣말로 반응한다.
--
-- 호출이 가장 잦은 모듈이라 세 겹으로 줄인다.
-- 1. 쿨다운: 플레이어별 최소 간격(샌드박스 옵션) + 계기별 간격. 물림 같은 큰 사건만 최소 간격을 무시한다.
-- 2. 문장 풀: 자주 오는 계기(무들, 부상, 폭풍)는 한 번에 여러 문장을 받아 두고 하나씩 꺼낸다.
--    풀은 POOL_TTL_MIN 이 지나거나 언어가 바뀌면 버린다 (캐릭터 상황이 바뀌었을 수 있어서).
-- 3. 대체 문장: 브릿지가 없거나 실패하면, 또는 샌드박스에서 AI 를 끄면 Translate 의 준비된 문장을 쓴다.
-- 계기 판정은 전부 여기 규칙으로 하고, AI 는 문장만 만든다. 표시는 클라이언트가 머리 위에 띄운다.

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Places"
require "StoryEngine/Store"
require "StoryEngine/Bridge"
require "StoryEngine/Sensor"

local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Places = StoryEngine.Places
local Bridge = StoryEngine.Bridge
local Net = StoryEngine.Net
local log = StoryEngine.log

local Monologue = {
    busy = {},       -- psKey -> 요청 시작 ms (메모리에만)
    seen = {},       -- psKey -> 지난 확인 때의 관측값 (메모리에만. 처음 본 값은 기준으로만 쓴다)
    debugIndex = 0,
}
StoryEngine.Monologue = Monologue

Monologue.DEFAULT_GAP_MIN = 120        -- 샌드박스 옵션이 없을 때 최소 간격 (게임 분)
Monologue.POOL_SIZE = 3
Monologue.POOL_TTL_MIN = 3 * 24 * 60
Monologue.STALE_MS = 45000             -- 응답이 이보다 늦으면 말하지 않는다
Monologue.TIMEOUT_MS = 40000
Monologue.MAX_SAID = 8
Monologue.MAX_BYTES = 300
Monologue.HEAR_RADIUS = 60              -- 이 거리(타일) 안의 다른 플레이어에게도 혼잣말이 보인다
Monologue.LOW_HEALTH = 45
Monologue.TOWN_RADIUS = 250
Monologue.KILL_MARKS = { 10, 25, 50, 100, 200, 500, 1000 }
Monologue.FALLBACK_COUNT = 3

-- gap: 같은 계기의 최소 간격(게임 분). pooled: 문장 풀 사용. urgent: 플레이어별 최소 간격 무시
Monologue.TRIGGERS = {
    bitten        = { gap = 60, urgent = true },
    low_health    = { gap = 12 * 60, urgent = true },
    first_kill    = { gap = 0, urgent = true },
    kills         = { gap = 0 },
    wounded       = { gap = 3 * 60, pooled = true },
    wake          = { gap = 12 * 60 },
    new_town      = { gap = 60 },
    supply_found  = { gap = 60 },
    horde_cleared = { gap = 60 },
    storm         = { gap = 12 * 60, pooled = true },
    helicopter    = { gap = 12 * 60, urgent = true },
    panic         = { moodle = "PANIC", gap = 6 * 60, pooled = true },
    pain          = { moodle = "PAIN", gap = 6 * 60, pooled = true },
    sick          = { moodle = "SICK", gap = 12 * 60, pooled = true },
    stress        = { moodle = "STRESS", gap = 12 * 60, pooled = true },
    unhappy       = { moodle = "UNHAPPY", gap = 12 * 60, pooled = true },
    bored         = { moodle = "BORED", gap = 12 * 60, pooled = true },
    hungry        = { moodle = "HUNGRY", gap = 12 * 60, pooled = true },
    thirsty       = { moodle = "THIRST", gap = 12 * 60, pooled = true },
    tired         = { moodle = "TIRED", gap = 12 * 60, pooled = true },
}
-- 무들 계기를 확인하는 순서 (앞쪽이 우선)
Monologue.MOODLE_ORDER = { "panic", "pain", "sick", "stress", "unhappy", "bored", "hungry", "thirsty", "tired" }
Monologue.MOODLE_MIN = 2
Monologue.DEBUG_ORDER = { "panic", "bitten", "first_kill", "kills", "wounded", "wake", "new_town", "storm",
    "supply_found", "horde_cleared", "helicopter", "low_health", "pain", "sick", "stress", "unhappy", "bored", "hungry",
    "thirsty", "tired" }

-- ---------------------------------------------------------------- options

local function option(name, default)
    local vars = SandboxVars and SandboxVars.StoryEngine
    local value = vars and vars[name]
    if value == nil then return default end
    return value
end

function Monologue.enabled()
    return option("Monologue", true) == true
end

local function useAI()
    return option("MonologueAI", true) == true
end

local function gapMin()
    return tonumber(option("MonologueGap", Monologue.DEFAULT_GAP_MIN)) or Monologue.DEFAULT_GAP_MIN
end

-- ---------------------------------------------------------------- state

local function state(ps)
    local m = ps.mono
    if not m then
        m = { last = {}, pools = {}, said = {}, towns = {} }
        ps.mono = m
    end
    m.last = m.last or {}
    m.pools = m.pools or {}
    m.said = m.said or {}
    m.towns = m.towns or {}
    return m
end

local function serverLang()
    local ok, name = pcall(function() return tostring(Translator.getLanguage():name()) end)
    return ok and name or "EN"
end

local function langOf(ps)
    return ps.lang or serverLang()
end

local function onlinePlayer(psKey)
    for _, p in ipairs(Sensor.players()) do
        if Store.playerKey(p) == psKey then return p end
    end
    return nil
end

-- ---------------------------------------------------------------- speak

local function clean(text)
    if type(text) ~= "string" then return nil end
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    text = string.gsub(text, "[\r\n]+", " ")
    -- 모델이 따옴표로 감싼 경우
    text = string.gsub(text, '^"(.*)"$', "%1")
    if text == "" or string.len(text) > Monologue.MAX_BYTES then return nil end
    return text
end

-- text 는 AI 문장(문자열) 또는 준비된 문장({ lt = 번역 문장 }). 준비된 문장은 클라이언트가 번역한다.
local function speak(player, ps, trig, text, source)
    local args = { trigger = trig }
    if type(text) == "table" then
        args.lt = text.lt
        log("monologue", ps.name, trig, source, text.lt.key)
    else
        args.text = text
        Store.push(state(ps).said, text, Monologue.MAX_SAID)
        log("monologue", ps.name, trig, source, text)
    end
    -- 멀티: 근처 플레이어에게도 보내 말한 사람 머리 위에 뜨게 한다 (클라이언트가 online ID 로 찾음)
    args.speaker = player:getOnlineID()
    local px, py = player:getX(), player:getY()
    for _, p in ipairs(Sensor.players()) do
        local dx, dy = p:getX() - px, p:getY() - py
        if p == player or dx * dx + dy * dy <= Monologue.HEAR_RADIUS * Monologue.HEAR_RADIUS then
            args.own = p == player or nil
            local ok, err = pcall(Net.toClient, p, "monologue", args)
            if not ok then log("monologue send failed:", err) end
        end
    end
end

-- 준비된 문장을 혼잣말처럼 (케이시 정찰 경고 등, 간격 제한 없이). lt = { key, args }
function Monologue.sayPrepared(player, ps, trig, lt)
    speak(player, ps, trig, { lt = lt }, "prepared")
end

function Monologue.fallbackText(trig, info)
    local key = "IGUI_StoryEngine_Mono_" .. trig .. "_" .. StoryEngine.intToString(ZombRand(Monologue.FALLBACK_COUNT) + 1)
    local args = {}
    if trig == "kills" then
        args = { { t = "num", v = info and info.kills or 0 } }
    elseif trig == "new_town" then
        args = { { t = "town", v = info and info.town or "?" } }
    end
    return { lt = { key = key, args = args } }
end

-- ---------------------------------------------------------------- request

local function recentNotes(ps)
    local out = {}
    local notes = ps.notes or {}
    for i = math.max(1, #notes - 3), #notes do out[#out + 1] = notes[i] end
    return out
end

local function lastDiary(ps)
    local last = ps.journal and ps.journal[#ps.journal]
    if last and last.kind == "daily" and last.text then return string.sub(last.text, 1, 400) end
    return nil
end

function Monologue.payload(player, ps, trig, info, count)
    local now = Sensor.now()
    local s = Sensor.sample(player, now, 0)
    local place = Places.describe(s.x, s.y)
    place.inside = s.building ~= nil
    place.rooms = s.rooms
    place.residential = s.residential
    local cm = getClimateManager()
    local payload = {
        lang = langOf(ps), trigger = trig, count = count, info = info or {},
        character = { name = ps.name, profession = ps.profession },
        day = Store.dayIndex(now.dayKey), clock = now.clock,
        place = { town = place.town, townDist = place.townDist, landmark = place.landmark, inside = place.inside,
                  rooms = place.rooms, residential = place.residential },
        health = s.hp, moodles = s.moodles,
        weather = { raining = cm:isRaining(), snowing = cm:isSnowing(), thunder = cm:getIsThunderStorming() },
        notes = recentNotes(ps),
        said = state(ps).said,
    }
    if trig == "wake" then payload.diary = lastDiary(ps) end
    return payload
end

local function request(player, ps, trig, info)
    local def = Monologue.TRIGGERS[trig]
    local count = def.pooled and Monologue.POOL_SIZE or 1
    local lang = langOf(ps)
    local key = ps.key
    local started = StoryEngine.nowMs()
    Monologue.busy[key] = started
    Bridge.request("monologue", Monologue.payload(player, ps, trig, info, count), function(res)
        Monologue.busy[key] = nil
        local lines = {}
        local list = res.ok and res.json and res.json.lines
        if type(list) == "table" then
            for _, text in ipairs(list) do
                local line = clean(text)
                if line and #lines < count then lines[#lines + 1] = line end
            end
        end
        local target = onlinePlayer(key)
        if not target then return end
        local first = table.remove(lines, 1)
        if StoryEngine.nowMs() - started > Monologue.STALE_MS then
            -- 늦게 온 문장은 지금 상황과 어긋날 수 있어 말하지 않고, 풀 계기면 다음을 위해 남겨 둔다
            log("monologue late", ps.name, trig)
            if first then table.insert(lines, 1, first) end
        elseif first then
            speak(target, ps, trig, first, "llm")
        else
            speak(target, ps, trig, Monologue.fallbackText(trig, info), "fallback " .. tostring(res.error or "empty"))
        end
        if def.pooled and #lines > 0 then
            state(ps).pools[trig] = { lines = lines, lang = lang, t = Sensor.now().t }
        end
    end, { timeoutMs = Monologue.TIMEOUT_MS })
end

-- 계기가 생겼을 때. force = true 면 쿨다운을 무시한다 (디버그). 말했거나 요청했으면 true
function Monologue.fire(player, ps, trig, info, force)
    local def = Monologue.TRIGGERS[trig]
    if not def or not player or ps.dead then return false end
    -- 동료가 곁에 있으면 혼잣말 대신 대화 (Banter.lua)
    if not force and StoryEngine.Banter and StoryEngine.Banter.onEvent(player, trig, info) then return true end
    if not Monologue.enabled() and not force then return false end
    local m = state(ps)
    local now = Sensor.now()
    if not force then
        if Monologue.busy[ps.key] then return false end
        local last = m.last[trig]
        if last and now.t - last < def.gap then return false end
        if not def.urgent and m.lastT and now.t - m.lastT < gapMin() then return false end
    end
    m.last[trig] = now.t
    m.lastT = now.t

    if not useAI() then
        speak(player, ps, trig, Monologue.fallbackText(trig, info), "fallback off")
        return true
    end
    if def.pooled then
        local pool = m.pools[trig]
        if pool and pool.lang == langOf(ps) and now.t - (pool.t or 0) < Monologue.POOL_TTL_MIN and #pool.lines > 0 then
            speak(player, ps, trig, table.remove(pool.lines, 1), "pool")
            return true
        end
        m.pools[trig] = nil
    end
    request(player, ps, trig, info)
    return true
end

-- ---------------------------------------------------------------- detection

local function newWounds(prev, cur)
    local bitten, wounded = nil, nil
    for w, _ in pairs(cur) do
        if not prev[w] then
            local sep = string.find(w, ":")
            local part, kind = string.sub(w, 1, sep - 1), string.sub(w, sep + 1)
            if kind == "bitten" then
                bitten = bitten or { part = part }
            elseif kind == "scratched" or kind == "cut" or kind == "deep" then
                wounded = wounded or { part = part, kind = kind }
            end
        end
    end
    return bitten, wounded
end

local function highestMark(kills)
    local mark = 0
    for _, n in ipairs(Monologue.KILL_MARKS) do
        if kills >= n then mark = n end
    end
    return mark
end

-- 한 플레이어를 확인해 이번에 말할 계기를 하나 고른다 (중요한 것부터). 반환: trig, info | nil
local function detect(player, ps, s, prev)
    local m = state(ps)

    -- 자다 깸 (자는 동안에는 다른 계기를 보지 않는다)
    if s.asleep then return nil end
    if prev.asleep then return "wake", nil end

    local bitten, wounded = newWounds(prev.wounds, s.wounds)
    if bitten then return "bitten", bitten end
    if s.hp < Monologue.LOW_HEALTH and prev.hp >= Monologue.LOW_HEALTH then return "low_health", nil end

    if s.kills > prev.kills then
        if not m.firstKill then
            m.firstKill = true
            return "first_kill", nil
        end
        local mark = highestMark(s.kills)
        if mark > (m.killMark or 0) then
            m.killMark = mark
            return "kills", { kills = mark }
        end
    end
    if wounded then return "wounded", wounded end

    local place = Places.describe(s.x, s.y)
    if place.townDist <= Monologue.TOWN_RADIUS and not m.towns[place.town] then
        m.towns[place.town] = true
        return "new_town", { town = place.town }
    end

    for _, trig in ipairs(Monologue.MOODLE_ORDER) do
        local name = Monologue.TRIGGERS[trig].moodle
        local level, before = s.moodles[name] or 0, prev.moodles[name] or 0
        if level >= Monologue.MOODLE_MIN and level > before then return trig, { level = level } end
    end
    return nil
end

-- 처음 본 캐릭터: 지금 상태를 기준으로 삼는다 (이미 있던 킬 수, 지금 있는 마을은 말하지 않음)
local function baseline(ps, s)
    local m = state(ps)
    if s.kills > 0 then m.firstKill = true end
    if not m.killMark then m.killMark = highestMark(s.kills) end
    local place = Places.describe(s.x, s.y)
    if place.townDist <= Monologue.TOWN_RADIUS then m.towns[place.town] = true end
end

function Monologue.check()
    -- 대화(Banter)도 같은 계기를 쓰므로 둘 중 하나라도 켜져 있으면 판정한다
    if not Monologue.enabled() and not (StoryEngine.Banter and StoryEngine.Banter.enabled()) then return end
    local players = Sensor.players()
    if #players == 0 then return end
    local now = Sensor.now()
    for _, p in ipairs(players) do
        local ok, err = pcall(function()
            local ps = Store.player(p)
            if ps.dead then return end
            local s = Sensor.sample(p, now, 0)
            local prev = Monologue.seen[ps.key]
            Monologue.seen[ps.key] = s
            if not prev then
                baseline(ps, s)
                return
            end
            local trig, info = detect(p, ps, s, prev)
            if trig then Monologue.fire(p, ps, trig, info) end
        end)
        if not ok then log("monologue check error:", err) end
    end
end

-- 다른 모듈에서 오는 계기 -------------------------------------------------

-- Director 폭풍
function Monologue.onStorm(entries)
    for _, e in ipairs(entries or {}) do
        if e.player and e.ps then Monologue.fire(e.player, e.ps, "storm", nil) end
    end
end

-- Director 헬기
function Monologue.onHelicopter(entries)
    for _, e in ipairs(entries or {}) do
        if e.player and e.ps then Monologue.fire(e.player, e.ps, "helicopter", nil) end
    end
end

-- Quests 상태 변화: 보급품을 다 챙겼을 때, 무리를 정리했을 때
function Monologue.onQuest(q, questState, entry)
    if questState ~= "completed" then return end
    local trig = (q.kind == "supply_drop" and "supply_found") or (q.kind == "horde" and "horde_cleared") or nil
    if not trig then return end
    local player, ps = entry and entry.player, entry and entry.ps
    if not player then
        ps = ps or Store.data().players[q.target]
        player = ps and onlinePlayer(ps.key)
    end
    if not player or not ps then return end
    Monologue.fire(player, ps, trig, {
        town = q.place and q.place.town,
        reward = q.origin and q.origin.source == "reward" or nil,
        faction = q.origin and q.origin.faction,
    })
end

-- 디버그: 계기를 차례로 돌려 가며 쿨다운 없이 말하게 한다
function Monologue.debug(player)
    local ps = Store.player(player)
    Monologue.debugIndex = Monologue.debugIndex % #Monologue.DEBUG_ORDER + 1
    local trig = Monologue.DEBUG_ORDER[Monologue.debugIndex]
    local info = nil
    if trig == "kills" then info = { kills = 50 } end
    if trig == "bitten" or trig == "wounded" then info = { part = "ForeArm_L", kind = "scratched" } end
    if trig == "new_town" then info = { town = Places.describe(player:getX(), player:getY()).town } end
    if Monologue.TRIGGERS[trig].moodle then info = { level = 2 } end
    Monologue.busy[ps.key] = nil
    Monologue.fire(player, ps, trig, info, true)
    return trig
end

Events.EveryOneMinute.Add(function()
    local ok, err = pcall(Monologue.check)
    if not ok then log("monologue tick error:", err) end
end)

return Monologue
