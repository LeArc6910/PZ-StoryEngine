-- 관측 계층 1·2층: 샘플링(센서)과 에피소드·하루 요약(집계기). 서버 측 전용.
--
-- 게임 내 10분마다(EveryTenMinutes) 살아 있는 모든 플레이어를 샘플링한다.
-- 장소(건물 또는 야외 마을 권역)나 동행 구성이 바뀌면 에피소드를 끊는다.
-- 판정은 전부 여기 규칙으로 하고, LLM 에는 결과만 넘긴다.

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Places"
require "StoryEngine/Store"

local Store = StoryEngine.Store
local Places = StoryEngine.Places
local log = StoryEngine.log

local Sensor = {
    buildingCache = {},   -- buildingKey -> { rooms = {...}, residential = bool }
    listeners = { sleep = {}, tick = {} },   -- tick(entries, now): 집계 후 호출
}
StoryEngine.Sensor = Sensor

Sensor.COMPANION_RADIUS = 20
Sensor.ZOMBIE_RADIUS = 30
Sensor.MAX_GAP_MIN = 30        -- 샘플 간격이 이보다 크면 이동거리·연속성 계산에서 뺀다

local MOODLES = { "PANIC", "BORED", "UNHAPPY", "STRESS", "TIRED", "HUNGRY", "THIRST", "SICK", "PAIN", "INJURED" }

-- ---------------------------------------------------------------- helpers

local function dist(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function pad2(n)
    n = math.floor(n)
    return (n < 10 and "0" or "") .. StoryEngine.intToString(n)
end

function Sensor.now()
    local gt = getGameTime()
    local month, day = gt:getMonth() + 1, gt:getDay() + 1
    return {
        t = math.floor(gt:getWorldAgeHours() * 60),
        clock = pad2(gt:getHour()) .. ":" .. pad2(gt:getMinutes()),
        dayKey = gt:getYear() * 10000 + month * 100 + day,
        date = StoryEngine.intToString(month) .. "/" .. StoryEngine.intToString(day),
    }
end

function Sensor.players()
    local out = {}
    if isServer() then
        local list = getOnlinePlayers()
        if list then
            for i = 0, list:size() - 1 do out[#out + 1] = list:get(i) end
        end
    else
        for i = 0, getNumActivePlayers() - 1 do
            local p = getSpecificPlayer(i)
            if p then out[#out + 1] = p end
        end
    end
    local alive = {}
    for _, p in ipairs(out) do
        if not p:isDead() then alive[#alive + 1] = p end
    end
    return alive
end

local function buildingInfo(def)
    local key = "b" .. StoryEngine.intToString(def:getX()) .. "_" .. StoryEngine.intToString(def:getY())
    local info = Sensor.buildingCache[key]
    if not info then
        local rooms, seen = {}, {}
        local list = def:getRooms()
        for i = 0, math.min(list:size(), 30) - 1 do
            local name = list:get(i):getName()
            if name and not seen[name] and #rooms < 5 then
                seen[name] = true
                rooms[#rooms + 1] = name
            end
        end
        info = { key = key, rooms = rooms, residential = def:isResidential() == true }
        Sensor.buildingCache[key] = info
    end
    return info
end

local function woundsOf(player)
    local wounds = {}
    local parts = player:getBodyDamage():getBodyParts()
    for i = 0, parts:size() - 1 do
        local bp = parts:get(i)
        local part = tostring(bp:getType())
        if bp:bitten() then wounds[part .. ":bitten"] = true end
        if bp:scratched() then wounds[part .. ":scratched"] = true end
        if bp:isCut() then wounds[part .. ":cut"] = true end
        if bp:deepWounded() then wounds[part .. ":deep"] = true end
        if bp:getFractureTime() > 0 then wounds[part .. ":fracture"] = true end
    end
    return wounds
end

local function moodlesOf(player)
    local m = player:getMoodles()
    local out = {}
    for _, name in ipairs(MOODLES) do
        local ok, level = pcall(function() return m:getMoodleLevel(MoodleType[name]) end)
        if ok and level and level > 0 then out[name] = level end
    end
    return out
end

-- 좀비 목록을 한 번만 돌면서 플레이어별 주변 좀비 수를 센다.
local function zombieCounts(players)
    local counts = {}
    for i = 1, #players do counts[i] = 0 end
    local ok = pcall(function()
        local list = getCell():getZombieList()
        local r2 = Sensor.ZOMBIE_RADIUS * Sensor.ZOMBIE_RADIUS
        for zi = 0, list:size() - 1 do
            local z = list:get(zi)
            local zx, zy = z:getX(), z:getY()
            for i, p in ipairs(players) do
                local dx, dy = zx - p:getX(), zy - p:getY()
                if dx * dx + dy * dy <= r2 then counts[i] = counts[i] + 1 end
            end
        end
    end)
    if not ok then return {} end
    return counts
end

function Sensor.sample(player, now, zombies)
    local s = {
        t = now.t, clock = now.clock,
        x = math.floor(player:getX()), y = math.floor(player:getY()), z = math.floor(player:getZ()),
        outside = player:isOutside() == true,
        kills = player:getZombieKills(),
        hp = math.floor(player:getBodyDamage():getOverallBodyHealth()),
        asleep = player:isAsleep() == true,
        zombies = zombies or 0,
        wounds = woundsOf(player),
        moodles = moodlesOf(player),
    }
    local sq = player:getCurrentSquare()
    local b = sq and sq:getBuilding()
    local def = b and b:getDef()
    if def then
        local info = buildingInfo(def)
        s.building, s.rooms, s.residential = info.key, info.rooms, info.residential
    end
    local room = sq and sq:getRoom()
    if room then s.room = room:getName() end
    return s
end

-- ---------------------------------------------------------------- home & day

local function updateHome(player, ps, s)
    local ok, sh = pcall(function() return SafeHouse.hasSafehouse(player) end)
    if ok and sh then
        ps.home = { x = math.floor((sh:getX() + sh:getX2()) / 2), y = math.floor((sh:getY() + sh:getY2()) / 2), z = 0, safehouse = true }
        return
    end
    -- 최근 잠든 위치 중 가장 많이 잔 건물(없으면 가장 최근 위치)
    if #ps.sleeps > 0 then
        local count, best, bestN = {}, nil, 0
        for _, sp in ipairs(ps.sleeps) do
            local k = sp.building or (StoryEngine.intToString(math.floor(sp.x / 10)) .. "_" .. StoryEngine.intToString(math.floor(sp.y / 10)))
            count[k] = (count[k] or 0) + 1
            if count[k] >= bestN then best, bestN = sp, count[k] end
        end
        ps.home = { x = best.x, y = best.y, z = best.z, building = best.building }
    elseif not ps.home then
        ps.home = { x = s.x, y = s.y, z = s.z, building = s.building }
    end
end

local function newDay(now)
    return {
        key = now.dayKey, index = Store.dayIndex(now.dayKey), date = now.date,
        travel = 0, maxFromHome = 0, outsideMin = 0, kills = 0, harmed = false, moodlePeaks = {},
    }
end

function Sensor.classify(day)
    if day.kills >= 15 or day.harmed then return "combat_day" end
    if day.maxFromHome >= 300 then return "expedition" end
    if day.outsideMin >= 60 or day.maxFromHome >= 50 then return "local_scavenge" end
    return "stayed_home"
end

function Sensor.daySummary(day)
    return {
        class = Sensor.classify(day),
        travel = math.floor(day.travel), maxFromHome = math.floor(day.maxFromHome),
        outsideMin = day.outsideMin, kills = day.kills, harmed = day.harmed,
        moodlePeaks = day.moodlePeaks,
    }
end

local function closeDay(ps)
    local day = ps.day
    if not day then return end
    Store.push(ps.days, {
        day = day.index, date = day.date, summary = Sensor.daySummary(day), diary = day.diary,
    }, Store.MAX_DAYS)
    log("day closed", ps.name, "D" .. StoryEngine.intToString(day.index), Sensor.classify(day))
    ps.day = nil
end

-- ---------------------------------------------------------------- episodes

local function placeOf(s)
    local p = Places.describe(s.x, s.y)
    p.inside = s.building ~= nil
    if s.building then
        p.building = s.building
        p.rooms = s.rooms
        p.residential = s.residential
    end
    return p
end

local function newSegment(key, s, companions)
    return {
        key = key, from = s.clock, to = s.clock, firstT = s.t, lastT = s.t,
        place = placeOf(s), with = companions, kills = 0, zombiesNear = s.zombies, harm = {},
        slept = s.asleep,
    }
end

-- 에피소드를 닫아 pending 에 넣는다. 같은 동행의 연속된 야외 에피소드는 하나로 합친다(이동 구간).
function Sensor.closeSegment(ps, seg)
    if not seg then return end
    local ep = {
        from = seg.from, to = seg.to, place = seg.place, with = seg.with,
        kills = seg.kills, zombiesNear = seg.zombiesNear, harm = seg.harm, slept = seg.slept,
        withKey = table.concat(seg.with, ","), lastT = seg.lastT,
    }
    local last = ps.pending[#ps.pending]
    if last and not last.place.inside and not ep.place.inside and last.withKey == ep.withKey
        and seg.firstT - (last.lastT or 0) <= Sensor.MAX_GAP_MIN then
        last.to = ep.to
        last.lastT = ep.lastT
        last.kills = last.kills + ep.kills
        last.zombiesNear = math.max(last.zombiesNear or 0, ep.zombiesNear or 0)
        for _, h in ipairs(ep.harm) do last.harm[#last.harm + 1] = h end
        if ep.place.town ~= last.place.town then
            last.place.via = last.place.via or {}
            local via = last.place.via
            if via[#via] ~= ep.place.town then via[#via + 1] = ep.place.town end
        end
        return
    end
    Store.push(ps.pending, ep, Store.MAX_PENDING)
end

-- 현재 열린 에피소드를 닫고 같은 자리에서 새로 연다 (일지 작성 직전에 사용).
function Sensor.flush(ps)
    local seg = ps.seg
    if not seg then return end
    Sensor.closeSegment(ps, seg)
    ps.seg = nil
end

-- ---------------------------------------------------------------- tick

local function process(player, ps, s, companions, harmNearby, now)
    -- 날짜가 바뀌면 어제를 닫는다
    if ps.day and ps.day.key ~= now.dayKey then closeDay(ps) end
    if not ps.day then ps.day = newDay(now) end
    local day = ps.day
    local prev = ps.prev
    local continuous = prev and (s.t - prev.t) <= Sensor.MAX_GAP_MIN

    updateHome(player, ps, s)

    local killsDelta = 0
    if continuous then
        day.travel = day.travel + dist(prev, s)
        if s.outside then day.outsideMin = day.outsideMin + (s.t - prev.t) end
        killsDelta = math.max(0, s.kills - prev.kills)
    end
    day.kills = day.kills + killsDelta
    if ps.home then day.maxFromHome = math.max(day.maxFromHome, dist(ps.home, s)) end
    for name, level in pairs(s.moodles) do
        if level > (day.moodlePeaks[name] or 0) then day.moodlePeaks[name] = level end
    end
    if #harmNearby > 0 then
        for _, h in ipairs(harmNearby) do
            if h.who == ps.name then day.harmed = true end
        end
    end

    -- 잠들기 시작
    if s.asleep and not (prev and prev.asleep) then
        Store.push(ps.sleeps, { x = s.x, y = s.y, z = s.z, building = s.building, t = s.t }, 10)
        for _, fn in ipairs(Sensor.listeners.sleep) do
            local ok, err = pcall(fn, player, ps, s)
            if not ok then log("sleep listener error:", err) end
        end
    end

    -- 에피소드 구분: 건물 또는 야외 마을 권역 + 동행 구성
    local town = Places.describe(s.x, s.y).town
    local placeKey = s.building or ("out:" .. town)
    local key = placeKey .. "|" .. table.concat(companions, ",")
    local seg = ps.seg
    if seg and seg.key == key and (s.t - seg.lastT) <= Sensor.MAX_GAP_MIN then
        seg.to = s.clock
        seg.lastT = s.t
        seg.kills = seg.kills + killsDelta
        seg.zombiesNear = math.max(seg.zombiesNear, s.zombies)
        seg.slept = seg.slept or s.asleep
    else
        Sensor.closeSegment(ps, seg)
        seg = newSegment(key, s, companions)
        seg.kills = killsDelta
        ps.seg = seg
    end
    for _, h in ipairs(harmNearby) do seg.harm[#seg.harm + 1] = h end

    ps.prev = s
end

function Sensor.tick()
    local players = Sensor.players()
    if #players == 0 then return end
    local now = Sensor.now()
    local zombies = zombieCounts(players)

    -- 1차: 샘플과 새 부상
    local entries = {}
    for i, p in ipairs(players) do
        local ok, err = pcall(function()
            local ps = Store.player(p)
            if ps.dead then return end
            local s = Sensor.sample(p, now, zombies[i])
            local newHarm = {}
            local prevWounds = ps.prev and ps.prev.wounds or {}
            for w, _ in pairs(s.wounds) do
                if not prevWounds[w] then
                    local sep = string.find(w, ":")
                    newHarm[#newHarm + 1] = { who = ps.name, part = string.sub(w, 1, sep - 1), kind = string.sub(w, sep + 1) }
                end
            end
            entries[#entries + 1] = { player = p, ps = ps, s = s, newHarm = newHarm }
        end)
        if not ok then log("sample error:", err) end
    end

    -- 2차: 동행 판정(같은 층, 20타일)과 주변 부상 공유 후 집계
    local r = Sensor.COMPANION_RADIUS
    for _, e in ipairs(entries) do
        local companions, harmNearby = {}, {}
        for _, h in ipairs(e.newHarm) do harmNearby[#harmNearby + 1] = h end
        for _, o in ipairs(entries) do
            if o ~= e and o.s.z == e.s.z and dist(o.s, e.s) <= r then
                companions[#companions + 1] = o.ps.name
                for _, h in ipairs(o.newHarm) do harmNearby[#harmNearby + 1] = h end
            end
        end
        table.sort(companions)
        e.companions = companions
        local ok, err = pcall(process, e.player, e.ps, e.s, companions, harmNearby, now)
        if not ok then log("process error:", err) end
    end

    for _, fn in ipairs(Sensor.listeners.tick) do
        local ok, err = pcall(fn, entries, now)
        if not ok then log("tick listener error:", err) end
    end
end

-- 디버그: 현재 관측 상태 한 줄 요약
function Sensor.statusText(player)
    local ps = Store.player(player)
    local day = ps.day
    local parts = { ps.name }
    if day then
        parts[#parts + 1] = "D" .. StoryEngine.intToString(day.index) .. " " .. Sensor.classify(day)
        parts[#parts + 1] = "travel " .. StoryEngine.intToString(math.floor(day.travel))
        parts[#parts + 1] = "home " .. StoryEngine.intToString(math.floor(day.maxFromHome))
        parts[#parts + 1] = "out " .. StoryEngine.intToString(day.outsideMin) .. "m"
        parts[#parts + 1] = "kills " .. StoryEngine.intToString(day.kills)
    else
        parts[#parts + 1] = "no samples yet"
    end
    parts[#parts + 1] = "episodes " .. StoryEngine.intToString(#ps.pending)
    if ps.seg then
        local p = ps.seg.place
        parts[#parts + 1] = "now " .. tostring(p.town) .. (p.inside and " (inside)" or " (outside)") .. " since " .. ps.seg.from
    end
    return table.concat(parts, " | ")
end

Events.EveryTenMinutes.Add(function()
    local ok, err = pcall(Sensor.tick)
    if not ok then log("sensor tick error:", err) end
end)

return Sensor
