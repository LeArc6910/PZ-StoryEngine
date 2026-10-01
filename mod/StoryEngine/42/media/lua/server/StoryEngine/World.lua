-- 게임 날짜에 맞춘 세계 변화 (서버 측 전용, 2026-09-30). 설계: docs/IDEAS_NEXT.md 4번
--
-- 좀보이드의 시간 흐름을 NPC 들도 겪는다. 각 계기는 서버 전체에 한 번(겨울·첫눈은 해마다 한 번):
--   power    전기 끊김 (샌드박스 ElecShutModifier, 바닐라 ISWeatherChannel 과 같은 계산) - 케이시 사기 -15, 닥 의약품 -10,
--            배터리·손전등 부탁(when = "power") 가중치
--   water    수도 끊김 (WaterShutModifier) - 모든 NPC 식량 -10, 물 부탁(when = "water") 가중치
--   winter   12~2월 - 매일 모든 NPC 식량 -2 더 (Life.daily -> World.dailyExtra), 파이크가 난방 물건을 청함
--   snow     그 겨울 첫눈 (기후 isSnowing) - 공용 주파수 장면 화제
--   day30/90/180  서버 경과 일수 - 회고 장면 화제
-- 공통: 소문(Social.news "all", 라디오 방송 재료도 됨), NPC 2~3명 무전 반응, 모든 살아 있는 캐릭터 일지 world_<id>.
-- 끊김은 켜진 것을 본 뒤 꺼져야 사건이 된다 (처음부터 꺼져 있거나 모드를 늦게 넣은 세이브는 조용히 넘어감).
-- 경과 일수도 지난 지 3일이 넘은 것은 조용히 넘어간다.
-- 상태: d.world = { done = { [key] = day }, seen = { power = true, water = true } }

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Radio"
require "StoryEngine/Stories"

local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Radio = StoryEngine.Radio
local Stories = StoryEngine.Stories
local log = StoryEngine.log

local World = {}
StoryEngine.World = World

World.MILESTONES = { 30, 90, 180 }
World.MILESTONE_LATE_DAYS = 3
World.WINTER_MONTHS = { [11] = true, [0] = true, [1] = true }     -- getMonth() 는 0부터
World.WINTER_FOOD = 2
World.HEAT_TIER = 2

-- 사건마다: 자원 변화, 무전으로 반응하는 NPC, 소문, 반응 주제(영어), 장면에 나올 NPC
World.EVENTS = {
    power = {
        hits = { { "casey", "morale", -15 }, { "doc", "medical", -10 } },
        react = { "casey", "doc" },
        news = "The power grid went down across the county today. Every light and fridge is dead.",
        topic = "The power grid just went down across the county. Every light and fridge is dead, and it is not coming back. "
            .. "React to it the way you would, and say what it means for your people.",
        scene = { "casey", "doc" },
    },
    water = {
        all = { "food", -10 },
        react = { "ray", "pike" },
        news = "The water stopped running from the taps today. Nobody knows if it will come back.",
        topic = "The taps just ran dry across the county. Clean water is now something you have to find, boil or collect. "
            .. "React to it the way you would, and say what it means for your people.",
        scene = { "ray", "pike" },
    },
    winter = {
        react = { "hunter", "ray" },
        news = "Winter has set in over the county. The nights are freezing.",
        topic = "Winter has set in. The nights are freezing and food will be harder to find until spring. "
            .. "React to it the way you would.",
        scene = { "hunter", "ray" },
    },
    snow = {
        react = {},
        news = "The first snow of the winter fell over the county.",
        sceneTopic = "The first snow of the winter is falling over the county. They talk about it: the cold, the quiet, "
            .. "tracks in the snow, whether the dead slow down, what the winter will bring.",
        scene = { "casey", "hunter" },
    },
    day30 = {
        react = {},
        news = "It has been a month since the outbreak.",
        sceneTopic = "It has been a month since the outbreak. They look back on how the first weeks went, "
            .. "who they lost and how they are still here.",
    },
    day90 = {
        react = {},
        news = "It has been three months since the outbreak.",
        sceneTopic = "It has been three months since the outbreak. They look back on what changed, what they learned "
            .. "and whether anyone is coming for them.",
    },
    day180 = {
        react = {},
        news = "It has been half a year since the outbreak.",
        sceneTopic = "It has been half a year since the outbreak. They look back on everything since the Knox Event "
            .. "and talk about what the next half year might look like.",
    },
}

function World.enabled() return StoryEngine.option("WorldChanges", true) == true end

local function state()
    local d = Store.data()
    d.world = d.world or {}
    d.world.done = d.world.done or {}
    d.world.seen = d.world.seen or {}
    return d.world
end

local function alive(fid) return Factions.byId[fid] ~= nil and not Factions.isGone(fid) end

-- ---------------------------------------------------------------- 판정

local function sandboxDay(name)
    local ok, v = pcall(function()
        local so = getSandboxOptions()
        if name == "Elec" then return so:getElecShutModifier() end
        return so:getWaterShutModifier()
    end)
    if ok and type(v) == "number" then return v end
    return tonumber(SandboxVars and SandboxVars[name .. "ShutModifier"])
end

-- 아포칼립스 경과 일수 (바닐라: worldAge / 24 + (TimeSinceApo - 1) * 30)
local function apoDay()
    local since = 1
    local ok, v = pcall(function() return getSandboxOptions():getTimeSinceApo() end)
    if ok and type(v) == "number" then since = v end
    return getGameTime():getWorldAgeHours() / 24 + (since - 1) * 30
end
World.apoDay = apoDay

function World.isDone(key) return state().done[key] ~= nil end

local function utilityOff(name)
    local day = sandboxDay(name)
    if not day then return false end
    if day < 0 then return true end
    return apoDay() >= day
end

function World.powerOff() return utilityOff("Elec") end
function World.waterOff() return utilityOff("Water") end

function World.isWinter()
    return World.WINTER_MONTHS[getGameTime():getMonth()] == true
end

-- 이번 겨울의 이름 (12월이면 그 해, 1·2월이면 전 해)
local function seasonYear()
    local gt = getGameTime()
    return gt:getMonth() == 11 and gt:getYear() or gt:getYear() - 1
end

-- 부탁 표의 when 조건 (Needs.pick)
function World.active(cond)
    if cond == "power" then return World.powerOff() end
    if cond == "water" then return World.waterOff() end
    if cond == "winter" then return World.isWinter() end
    return false
end

-- ---------------------------------------------------------------- 사건

local function livingPlayers()
    local out = {}
    for _, ps in pairs(Store.data().players or {}) do
        if not ps.dead then out[#out + 1] = ps end
    end
    return out
end

local function openRequest(fid)
    for _, q in pairs(Store.data().quests or {}) do
        if q.origin and q.origin.faction == fid and (q.kind == "deliver" or q.kind == "horde")
            and (q.state == "proposed" or q.state == "accepted") then
            return true
        end
    end
    return false
end

-- 파이크가 난방 물건을 청한다 (접속자 중 한 명에게, 진행 중 부탁이 없을 때)
function World.askHeat(now)
    if not alive("pike") or openRequest("pike") then return false, "busy" end
    local players = Sensor.players()
    if #players == 0 then return false, "nobody" end
    local p = players[ZombRand(#players) + 1]
    local ps = Store.player(p)
    local tier = World.HEAT_TIER
    if StoryEngine.Director and StoryEngine.Director.tierCap then
        tier = math.min(tier, StoryEngine.Director.tierCap(ps, "pike"))
    end
    local q, why = StoryEngine.Quests.propose(p, ps, "pike", tier, now, { when = "winter" })
    return q ~= nil, why
end

-- 사건을 일으킨다 (서버 전체 한 번). key 는 기록용 (겨울은 해마다 다름)
function World.fire(id, key, now)
    local ev = World.EVENTS[id]
    if not ev then return false end
    local s = state()
    key = key or id
    if s.done[key] then return false end
    now = now or Sensor.now()
    s.done[key] = Store.dayIndex(now.dayKey)
    local Life = StoryEngine.Life
    if Life then
        for _, h in ipairs(ev.hits or {}) do
            if alive(h[1]) then Life.change(h[1], h[2], h[3], "world " .. id) end
        end
        if ev.all then
            for _, f in ipairs(Factions.list) do
                if alive(f.id) then Life.change(f.id, ev.all[1], ev.all[2], "world " .. id) end
            end
        end
    end
    local Social = StoryEngine.Social
    if Social then
        Social.news("all", ev.news)
        local ids = {}
        for _, fid in ipairs(ev.scene or {}) do
            if alive(fid) and #ids < 2 then ids[#ids + 1] = fid end
        end
        if #ids < 2 then
            for _, f in ipairs(Factions.list) do
                local dup = false
                for _, x in ipairs(ids) do if x == f.id then dup = true end end
                if not dup and alive(f.id) and #ids < 2 then ids[#ids + 1] = f.id end
            end
        end
        if #ids >= 2 then Social.queueTopic(ids, ev.sceneTopic or (ev.news .. " They talk about it.")) end
    end
    -- 무전 반응: 정해진 NPC + 살아 있는 다른 한 명
    if ev.topic then
        local who = {}
        for _, fid in ipairs(ev.react) do
            if alive(fid) then who[#who + 1] = fid end
        end
        local others = {}
        for _, f in ipairs(Factions.list) do
            local dup = false
            for _, x in ipairs(who) do if x == f.id then dup = true end end
            if not dup and alive(f.id) then others[#others + 1] = f.id end
        end
        if #others > 0 then who[#who + 1] = others[ZombRand(#others) + 1] end
        for _, fid in ipairs(who) do Radio.react(fid, "event", ev.topic, nil) end
    end
    for _, ps in ipairs(livingPlayers()) do
        Store.addNote(ps, { kind = "world_" .. id, clock = now.clock })
    end
    if id == "winter" then
        local ok, why = World.askHeat(now)
        if not ok then log("world winter: pike heat request skipped", tostring(why)) end
    end
    log("world event", id, key)
    return true
end

-- 게임 내 한 시간마다 (접속자가 있을 때)
function World.tick()
    if not World.enabled() or #Sensor.players() == 0 then return end
    local s = state()
    local now = Sensor.now()
    for _, u in ipairs({ { "power", World.powerOff }, { "water", World.waterOff } }) do
        local id, off = u[1], u[2]()
        if not off then
            s.seen[id] = true
        elseif not s.done[id] then
            if s.seen[id] then
                World.fire(id, id, now)
            else
                s.done[id] = -1      -- 처음부터 꺼져 있었다: 사건 없음
                log("world", id, "already off, skipped")
            end
        end
    end
    if World.isWinter() then
        local year = StoryEngine.intToString(seasonYear())
        World.fire("winter", "winter_" .. year, now)
        local okSnow, snowing = pcall(function() return getClimateManager():isSnowing() end)
        if okSnow and snowing then World.fire("snow", "snow_" .. year, now) end
    end
    local days = Store.serverDays()
    for _, m in ipairs(World.MILESTONES) do
        local key = "day" .. StoryEngine.intToString(m)
        if days >= m and not s.done[key] then
            if days - m > World.MILESTONE_LATE_DAYS then
                s.done[key] = -1
            else
                World.fire(key, key, now)
            end
        end
    end
end

-- 매일 (Life.daily): 겨울에는 모든 NPC 식량이 더 준다
function World.dailyExtra()
    if not World.enabled() or not World.isWinter() then return end
    local Life = StoryEngine.Life
    for _, f in ipairs(Factions.list) do
        if alive(f.id) then Life.change(f.id, "food", -World.WINTER_FOOD, "winter") end
    end
end

-- AI 맥락용 한 줄 (디렉터·라디오 방송): 지금 세계 형편
function World.conditions()
    local out = {}
    if World.powerOff() then out[#out + 1] = "no power" end
    if World.waterOff() then out[#out + 1] = "no running water" end
    if World.isWinter() then out[#out + 1] = "winter" end
    return out
end

function World.statusText()
    local s = state()
    local done = {}
    for k, v in pairs(s.done) do done[#done + 1] = k .. (v == -1 and "(skip)" or "") end
    table.sort(done)
    return "world power=" .. (World.powerOff() and "off" or "on") .. " water=" .. (World.waterOff() and "off" or "on")
        .. (World.isWinter() and " winter" or "") .. " done=" .. (#done > 0 and table.concat(done, ",") or "none")
end

Events.EveryHours.Add(function()
    local ok, err = pcall(World.tick)
    if not ok then log("world tick error:", err) end
end)

return World
