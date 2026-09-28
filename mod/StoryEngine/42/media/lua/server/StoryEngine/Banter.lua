-- 플레이어 캐릭터끼리의 짧은 대화 (서버 측 전용, 멀티).
--
-- 깨어 있는 캐릭터가 같은 층 RADIUS 타일 안에 둘 이상 모여 있으면 무리로 본다 (무리 = 이어진 캐릭터들).
--   주기: 같은 무리는 게임 시간 GAP_MIN 마다 한 번 잡담 ("chat"). 처음 모이면 30분 뒤.
--   사건: 사건이 생기면 주기와 상관없이 바로 (같은 사건은 무리마다 EVENT_GAP_MIN 간격).
--     혼잣말 계기(물림·부상·첫 킬·킬 이정표·새 마을·자다 깸·무들·폭풍·헬기·보급 발견·소탕 완료)는 동료가 곁에 있으면
--     혼잣말 대신 대화가 된다 (Monologue.fire -> Banter.onEvent).
--     그 밖에: 함께 싸운 뒤(fight), 추적 호드 접근(horde_near), 무장 무리(armed_attack), A-Life 지원 도착·철수,
--     퀘스트 수락·완료·실패, 무전 답장(radio), 다른 생존자의 죽음(death).
-- AI 는 2~4줄의 대사만 만든다 (브릿지 banter 모듈). 말한 캐릭터 머리 위에 차례로 뜨고 근처 플레이어도 본다.
-- 대화 내용은 참여한 사람들의 다음 일기에 들어간다 (notes kind = "banter").
-- 실제 사람의 캐릭터가 대신 말하므로 잡담·감정만 (약속·결정·거래 동의 금지, prompts/banter.md).

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

local Banter = {
    busy = {},        -- groupKey -> 요청 시작 ms (메모리에만)
    kills = {},       -- psKey -> 지난 확인 때의 킬 수
    fight = {},       -- groupKey -> { n, lastT } 함께 싸운 처치 누적
    huntSeen = {},    -- hunt id -> true (접근을 이미 말함)
}
StoryEngine.Banter = Banter

Banter.RADIUS = 10
Banter.GAP_MIN = 3 * 60                  -- 사건이 없을 때 같은 무리의 대화 간격 (게임 분)
Banter.FIRST_MIN = 30                    -- 처음 모인 뒤 첫 잡담까지
Banter.EVENT_GAP_MIN = 30                -- 같은 무리, 같은 사건의 간격
Banter.MAX_SPEAKERS = 3
Banter.MAX_LINES = 4
Banter.HEAR_RADIUS = 60
Banter.STALE_MS = 45000
Banter.TIMEOUT_MS = 40000
Banter.LINE_DELAY_MS = 2600
Banter.MAX_TEXT = 200
Banter.FIGHT_KILLS = 5                   -- 이만큼 함께 잡고 2분 조용하면 "fight"
Banter.HUNT_DIST = 40
Banter.MAX_SAID = 8

function Banter.enabled()
    return StoryEngine.option("Banter", true) == true
end

local function state()
    local d = Store.data()
    d.banter = d.banter or { last = {}, said = {}, eventAt = {} }
    d.banter.eventAt = d.banter.eventAt or {}
    return d.banter
end

local function serverLang()
    local ok, name = pcall(function() return tostring(Translator.getLanguage():name()) end)
    return ok and name or "EN"
end

local function dist(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

-- ---------------------------------------------------------------- groups

local function eligible(p)
    return p and not p:isDead() and not p:isAsleep()
end

-- 가까이 모인 캐릭터 무리들 (둘 이상)
function Banter.groups()
    local players = {}
    for _, p in ipairs(Sensor.players()) do
        if eligible(p) then players[#players + 1] = p end
    end
    local parent = {}
    for i = 1, #players do parent[i] = i end
    local function find(i)
        while parent[i] ~= i do i = parent[i] end
        return i
    end
    local r2 = Banter.RADIUS * Banter.RADIUS
    for i = 1, #players do
        for j = i + 1, #players do
            local a, b = players[i], players[j]
            if math.floor(a:getZ()) == math.floor(b:getZ()) then
                local dx, dy = a:getX() - b:getX(), a:getY() - b:getY()
                if dx * dx + dy * dy <= r2 then parent[find(i)] = find(j) end
            end
        end
    end
    local byRoot, out = {}, {}
    for i, p in ipairs(players) do
        local r = find(i)
        byRoot[r] = byRoot[r] or {}
        table.insert(byRoot[r], p)
    end
    for _, g in pairs(byRoot) do
        if #g >= 2 then out[#out + 1] = g end
    end
    return out
end

local function groupKey(group)
    local keys = {}
    for _, p in ipairs(group) do keys[#keys + 1] = Store.playerKey(p) end
    table.sort(keys)
    return table.concat(keys, "+")
end

local function groupOf(player)
    local key = Store.playerKey(player)
    for _, g in ipairs(Banter.groups()) do
        for _, p in ipairs(g) do
            if Store.playerKey(p) == key then return g end
        end
    end
    return nil
end

-- 말할 사람: 사건의 주인공 먼저, 그다음 가까운 순 (최대 MAX_SPEAKERS)
local function speakersOf(group, owner)
    local ownerKey = owner and Store.playerKey(owner)
    local first = nil
    for _, p in ipairs(group) do
        if Store.playerKey(p) == ownerKey then first = p end
    end
    first = first or group[ZombRand(#group) + 1]
    local rest = {}
    for _, p in ipairs(group) do
        if p ~= first then rest[#rest + 1] = { p = p, d = dist(p:getX(), p:getY(), first:getX(), first:getY()) } end
    end
    table.sort(rest, function(a, b) return a.d < b.d end)
    local out = { first }
    for i = 1, math.min(#rest, Banter.MAX_SPEAKERS - 1) do out[#out + 1] = rest[i].p end
    return out
end

-- ---------------------------------------------------------------- request

local function woundCount(s)
    local n = 0
    for _, _ in pairs(s.wounds or {}) do n = n + 1 end
    return n
end

local function recentRadio(speakers)
    local out = {}
    for _, p in ipairs(speakers) do
        local log2 = Store.player(p).radioLog or {}
        for i = math.max(1, #log2 - 2), #log2 do out[#out + 1] = log2[i] end
    end
    table.sort(out, function(a, b) return tostring(a.clock) < tostring(b.clock) end)
    while #out > 4 do table.remove(out, 1) end
    return out
end

function Banter.payload(key, speakers, event, info, owner)
    local now = Sensor.now()
    local list, names = {}, {}
    for _, p in ipairs(speakers) do
        local ps = Store.player(p)
        local s = Sensor.sample(p, now, 0)
        local met = {}
        for _, q in ipairs(speakers) do
            if q ~= p then
                local other = Store.player(q).name
                met[#met + 1] = { name = other, minutes = ps.met and ps.met[other] or 0 }
            end
        end
        list[#list + 1] = { name = ps.name, profession = ps.profession, lang = ps.lang or serverLang(),
                            hp = s.hp, moodles = s.moodles, wounds = woundCount(s), met = met }
        names[#names + 1] = ps.name
    end
    local first = speakers[1]
    local place = Places.describe(first:getX(), first:getY())
    place.inside = first:isOutside() ~= true
    local cm = getClimateManager()
    return {
        speakers = list, event = { kind = event, info = info or {}, who = owner and Store.player(owner).name or nil },
        day = Store.dayIndex(now.dayKey), clock = now.clock,
        place = { town = place.town, townDist = place.townDist, landmark = place.landmark, inside = place.inside },
        weather = { raining = cm:isRaining(), snowing = cm:isSnowing(), thunder = cm:getIsThunderStorming() },
        radio = recentRadio(speakers),
        said = state().said[key] or {},
    }, names
end

local function clean(text)
    if type(text) ~= "string" then return nil end
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    text = string.gsub(text, "[\r\n]+", " ")
    text = string.gsub(text, '^"(.*)"$', "%1")
    if text == "" then return nil end
    return string.sub(text, 1, Banter.MAX_TEXT)
end

-- 대사를 말한 캐릭터 머리 위에 차례로 띄운다 (근처 플레이어 모두)
local function show(speakers, lines)
    local byName = {}
    for _, p in ipairs(speakers) do byName[Store.player(p).name] = p end
    local out = {}
    for i, l in ipairs(lines) do
        local p = byName[l.speaker]
        out[#out + 1] = { speaker = p:getOnlineID(), name = l.speaker, text = l.text,
                          delay = (i - 1) * Banter.LINE_DELAY_MS }
    end
    local cx, cy = speakers[1]:getX(), speakers[1]:getY()
    for _, p in ipairs(Sensor.players()) do
        if dist(p:getX(), p:getY(), cx, cy) <= Banter.HEAR_RADIUS then
            local ok, err = pcall(Net.toClient, p, "banter", { lines = out })
            if not ok then log("banter send failed:", err) end
        end
    end
end

-- 대화를 시작한다. 요청했으면 true
function Banter.fire(group, event, info, owner, force)
    if not Banter.enabled() or not group or #group < 2 then return false end
    local key = groupKey(group)
    if Banter.busy[key] then return false end
    local st = state()
    local now = Sensor.now()
    if not force then
        if event == "chat" then
            if st.last[key] and now.t - st.last[key] < Banter.GAP_MIN then return false end
        else
            local ek = key .. "|" .. event
            if st.eventAt[ek] and now.t - st.eventAt[ek] < Banter.EVENT_GAP_MIN then return false end
            st.eventAt[ek] = now.t
        end
    end
    st.last[key] = now.t
    local speakers = speakersOf(group, owner)
    local payload, names = Banter.payload(key, speakers, event, info, owner)
    local started = StoryEngine.nowMs()
    Banter.busy[key] = started
    log("banter request", event, table.concat(names, ", "))
    Bridge.request("banter", payload, function(res)
        Banter.busy[key] = nil
        local valid = {}
        for _, n in ipairs(names) do valid[n] = true end
        local lines = {}
        local list = res.ok and res.json and res.json.lines
        if type(list) == "table" then
            for _, l in ipairs(list) do
                local text = type(l) == "table" and clean(l.text) or nil
                if text and valid[l.speaker] and #lines < Banter.MAX_LINES then
                    lines[#lines + 1] = { speaker = l.speaker, text = text }
                end
            end
        end
        if #lines == 0 then
            log("banter failed", event, tostring(res.error or "empty"))
            return
        end
        if StoryEngine.nowMs() - started > Banter.STALE_MS then
            log("banter late", event)
            return
        end
        -- 지금도 모여 있는 사람만 (응답을 기다리는 동안 흩어졌을 수 있다)
        local present = {}
        for _, p in ipairs(speakers) do
            if eligible(p) and dist(p:getX(), p:getY(), speakers[1]:getX(), speakers[1]:getY()) <= Banter.RADIUS * 2 then
                present[Store.player(p).name] = true
            end
        end
        local kept = {}
        for _, l in ipairs(lines) do
            if present[l.speaker] then kept[#kept + 1] = l end
        end
        if #kept == 0 then return end
        show(speakers, kept)

        -- 기록: 다시 하지 않도록, 그리고 참여한 사람들의 다음 일기에
        local said = st.said[key] or {}
        local transcript = {}
        for _, l in ipairs(kept) do
            Store.push(said, l.text, Banter.MAX_SAID)
            transcript[#transcript + 1] = l.speaker .. ": " .. l.text
        end
        st.said[key] = said
        local t = Sensor.now()
        for _, p in ipairs(speakers) do
            local ps = Store.player(p)
            local others = {}
            for _, n in ipairs(names) do
                if n ~= ps.name then others[#others + 1] = n end
            end
            Store.addNote(ps, { kind = "banter", with = others, event = event, lines = transcript, clock = t.clock })
        end
        log("banter", event, table.concat(transcript, " | "))
    end, { timeoutMs = Banter.TIMEOUT_MS })
    return true
end

-- 한 캐릭터에게 생긴 사건. 동료가 곁에 있어 대화를 시작했으면 true (혼잣말은 건너뛴다)
function Banter.onEvent(player, event, info, force)
    if not Banter.enabled() or not player then return false end
    local g = groupOf(player)
    if not g then return false end
    return Banter.fire(g, event, info, player, force)
end

-- 이 캐릭터(ps)가 접속해 있으면 그 사건으로 대화
function Banter.onEventFor(ps, event, info)
    if not ps then return false end
    for _, p in ipairs(Sensor.players()) do
        if Store.playerKey(p) == ps.key then return Banter.onEvent(p, event, info) end
    end
    return false
end

-- ---------------------------------------------------------------- hooks from other modules

local QUEST_WHAT = {
    supply_drop = "picking up supplies left for them",
    fetch = "bringing back something from a building",
    deliver = "delivering the things someone asked for",
    trade = "a trade",
    horde = "clearing out a pack of the dead around a building",
    extort = "paying off people who threatened them",
}

function Banter.onQuest(q, questState)
    if questState ~= "accepted" and questState ~= "completed" and questState ~= "failed" then return end
    if q.origin and q.origin.source == "reward" and questState ~= "completed" then return end
    local ps = Store.data().players[q.target]
    Banter.onEventFor(ps, "quest_" .. questState, {
        what = QUEST_WHAT[q.kind] or "a job", faction = q.origin and q.origin.faction,
        town = q.place and q.place.town, reward = q.origin and q.origin.source == "reward" or nil,
    })
end

function Banter.onRadio(ps, fid, reply)
    Banter.onEventFor(ps, "radio", { faction = fid, text = string.sub(tostring(reply or ""), 1, 200) })
end

function Banter.onDeath(deadName)
    for _, g in ipairs(Banter.groups()) do
        Banter.fire(g, "death", { name = deadName }, nil)
    end
end

-- ---------------------------------------------------------------- tick

function Banter.check()
    if not Banter.enabled() then return end
    local now = Sensor.now()
    local st = state()
    -- 킬 수 변화 (함께 싸움)
    local delta = {}
    for _, p in ipairs(Sensor.players()) do
        local key = Store.playerKey(p)
        local k = p:getZombieKills()
        if Banter.kills[key] then delta[key] = math.max(0, k - Banter.kills[key]) end
        Banter.kills[key] = k
    end
    for _, g in ipairs(Banter.groups()) do
        local key = groupKey(g)
        local fired = false
        -- 함께 싸운 뒤
        local n = 0
        for _, p in ipairs(g) do n = n + (delta[Store.playerKey(p)] or 0) end
        local f = Banter.fight[key] or { n = 0, lastT = now.t }
        if n > 0 then
            f.n, f.lastT = f.n + n, now.t
        elseif f.n >= Banter.FIGHT_KILLS and now.t - f.lastT >= 2 then
            fired = Banter.fire(g, "fight", { count = f.n }, nil)
            f.n = 0
        elseif now.t - f.lastT > 10 then
            f.n = 0
        end
        Banter.fight[key] = f
        -- 추적 호드 접근
        if not fired then
            for id, h in pairs(Store.data().hunts or {}) do
                if not Banter.huntSeen[id] and (tonumber(h.remaining) or 0) > 0 and tonumber(h.x) then
                    for _, p in ipairs(g) do
                        if Store.playerKey(p) == h.target and dist(h.x, h.y, p:getX(), p:getY()) <= Banter.HUNT_DIST then
                            Banter.huntSeen[id] = true
                            fired = Banter.fire(g, "horde_near", { count = h.remaining }, p)
                        end
                    end
                end
            end
        end
        -- 잡담
        if not fired then
            if not st.last[key] then st.last[key] = now.t - Banter.GAP_MIN + Banter.FIRST_MIN end
            Banter.fire(g, "chat", nil, nil)
        end
    end
end

-- 디버그: 가장 가까운 무리에서 바로 잡담
function Banter.debug(player)
    local g = groupOf(player)
    if not g then return false, "nobody_near" end
    return Banter.fire(g, "chat", nil, player, true)
end

Events.EveryOneMinute.Add(function()
    local ok, err = pcall(Banter.check)
    if not ok then log("banter tick error:", err) end
end)

return Banter
