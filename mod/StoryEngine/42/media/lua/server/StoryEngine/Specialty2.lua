-- NPC 2차 특기 (서버 측 전용, 2026-10-09). 설계: docs/IDEAS_SPECIALTY_2.md "최종안"
--
-- 그 NPC 의 2차 장기 프로젝트(Projects.lua, 2000점)가 끝나면 플레이어마다 선택지 셋 중 하나를 고른다
-- (서버 공유·개인 신뢰 모드와 상관없이 각자, ps.spec2[fid] = { opt, t }). 30일마다 바꿀 수 있다.
-- 쓰는 조건: 신뢰 80 이상(개인 모드면 내 신뢰), 그 NPC 핵심 자원 30 이상. 쓰면 자원 -20, 대기는 모두 개인별.
-- 세계에 영향을 주는 것(비·전기)은 누가 쓴 효과가 진행 중이면 아무도 못 쓴다 (겹쳐 쓰기 방지).
--
-- 1단계(이 파일): livestock stew praise sos power illness pain pharmacy reconcile baptism tuning bodyguard game
-- 나머지는 READY 에 없어 고를 수 없다 ("준비 중").

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Radio"
require "StoryEngine/Trust"
require "StoryEngine/Life"
require "StoryEngine/Specialty"
require "StoryEngine/Projects"

local Net = StoryEngine.Net
local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Radio = StoryEngine.Radio
local Life = StoryEngine.Life
local Specialty = StoryEngine.Specialty
local Projects = StoryEngine.Projects
local log = StoryEngine.log

local Specialty2 = {}
StoryEngine.Specialty2 = Specialty2

Specialty2.OPTIONS = {
    ray = { "livestock", "rain", "stew" },
    casey = { "praise", "sos", "power" },
    doc = { "illness", "pain", "pharmacy" },
    pike = { "reconcile", "refugees", "baptism" },
    dewey = { "tow", "reinforce", "tuning" },
    guard = { "artillery", "evac", "barricade" },
    rats = { "heist", "bodyguard", "camo" },
    hunter = { "suppressor", "game", "flare" },
}
-- 개인 대기 (일, 샌드박스 SpecialtyCooldownMult 를 곱한다)
Specialty2.DAYS = {
    livestock = 14, rain = 14, stew = 7, praise = 7, sos = 14, power = 14, illness = 14, pain = 14, pharmacy = 7,
    reconcile = 14, refugees = 7, baptism = 14, tow = 14, reinforce = 7, tuning = 14, artillery = 7, evac = 7,
    barricade = 14, heist = 14, bodyguard = 7, camo = 7, suppressor = 7, game = 7, flare = 7,
}
-- 지금 고를 수 있는 것 (나머지는 인게임 확인이 필요한 2·3단계)
Specialty2.READY = {
    livestock = true, stew = true, praise = true, sos = true, power = true, illness = true, pain = true,
    pharmacy = true, reconcile = true, baptism = true, tuning = true, bodyguard = true, game = true,
}
-- 진행 중이면 다른 사람도 못 쓰는 세계 효과
Specialty2.WORLD = { rain = true, power = true }

Specialty2.TRUST_MIN = 80
Specialty2.RES_MIN = 30
Specialty2.COST = 20
Specialty2.CHANGE_DAYS = 30
Specialty2.PRAISE_TRUST = 2
Specialty2.PRAISE_CAP = 90              -- 이 신뢰 이상인 NPC 는 칭찬 방송으로 오르지 않는다
Specialty2.PRAISE_HOUR = 7
Specialty2.SOS_MIN = 60
Specialty2.SOS_SNIPE = 15
Specialty2.SOS_GUARD_SNIPE = 5          -- A-Life 가 없을 때 방위대 몫
Specialty2.SOS_SNIPE_MIN = 5
Specialty2.POWER_DAYS = 3
Specialty2.ILLNESS_DAYS = 3
Specialty2.PAIN_DAYS = 3
Specialty2.BAPTISM_DAYS = 2
Specialty2.BAPTISM_SHARE = 1 / 3        -- 지구력이 이만큼만 줄어든다
Specialty2.STEW_HOURS = 24
Specialty2.RECONCILE_TRUST = 10
Specialty2.BODYGUARD_HOURS = 24
Specialty2.BODYGUARD_COUNT = 2
Specialty2.BODYGUARD_FALLBACK_HOURS = 12
Specialty2.BODYGUARD_FALLBACK_KILLS = 2  -- 10분마다
Specialty2.BODYGUARD_RADIUS = 8
Specialty2.TUNE_RADIUS = 10
Specialty2.TUNE_POWER = 1.3
Specialty2.TUNE_LOUD = 0.7
Specialty2.PAIN_REDUCTION = 100
Specialty2.SICK_STATS = { "FOOD_SICKNESS", "POISON", "SICKNESS" }
Specialty2.SICK_MIN = 0.05
Specialty2.ANIMAL_DIST = { 6, 12 }
Specialty2.ANIMAL_KITS = {
    { { "hen", "leghorn", 3 }, { "cockerel", "leghorn", 1 } },
    { { "cow", "holstein", 1 } },
}

Specialty2.STEW = "StoryEngine.Food_RayStew"
-- 약 조제 (2026-10-09 사용자 결정): 약초 개수, 한 번에 최대 2개
Specialty2.PHARMACY = {
    vitamins = { item = "Base.PillsVitamins", herbs = 6 },
    sleeping = { item = "Base.PillsSleepingTablets", herbs = 6 },
    beta = { item = "Base.PillsBeta", herbs = 6 },
    antidep = { item = "Base.PillsAntiDep", herbs = 6 },
    painkillers = { item = "Base.Pills", herbs = 6 },
    disinfectant = { item = "Base.Disinfectant", herbs = 6 },
    antibiotics = { item = "Base.Antibiotics", herbs = 8 },
}
Specialty2.PHARMACY_ORDER = { "vitamins", "sleeping", "beta", "antidep", "painkillers", "disinfectant", "antibiotics" }
Specialty2.PHARMACY_MAX = 2
-- 약초 = 바닐라 채집 분류 MedicinalPlants (forageSystem 이 없을 때의 목록)
Specialty2.HERBS = { "Base.Plantain", "Base.Comfrey", "Base.WildGarlic2", "Base.CommonMallow", "Base.LemonGrass",
                     "Base.BlackSage", "Base.Ginseng" }
-- 사냥감 나눔: 좋은 고기일수록 드물게 (가중치)
Specialty2.MEATS = {
    { "Base.Smallbirdmeat", 30 }, { "Base.Smallanimalmeat", 25 }, { "Base.Rabbitmeat", 20 }, { "Base.Chicken", 10 },
    { "Base.PorkChop", 4 }, { "Base.MuttonChop", 4 }, { "Base.Steak", 5 }, { "Base.Venison", 2 },
}
Specialty2.MEAT_COUNT = { 4, 8 }

local function state()
    local d = Store.data()
    d.spec2 = d.spec2 or {}
    local s = d.spec2
    s.usedBy = s.usedBy or {}        -- 플레이어 키 -> { fid -> 쓴 시각 }
    s.fx = s.fx or {}                -- 지속 효과 { kind, key, untilT, ... }
    s.world = s.world or {}          -- rain|power -> { untilT, key }
    s.praise = s.praise or {}        -- 키 -> { name, day } (다음 날 아침에 적용)
    return s
end
Specialty2.state = state

local function rand(range) return range[1] + ZombRand(range[2] - range[1] + 1) end

local function dist(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

local function playerByKey(key)
    for _, p in ipairs(Sensor.players()) do
        if Store.playerKey(p) == key then return p end
    end
    return nil
end

local function cooldownMult()
    local Tuning = StoryEngine.Tuning
    local m = Tuning and Tuning.num("SpecialtyCooldownMult") or 1
    if not m or m <= 0 then m = 1 end
    return m
end

function Specialty2.enabled()
    return StoryEngine.option("Specialty2", true) == true
end

function Specialty2.isOption(fid, opt)
    for _, o in ipairs(Specialty2.OPTIONS[fid] or {}) do
        if o == opt then return true end
    end
    return false
end

-- 이 사람이 고른 것 (없으면 nil)
function Specialty2.choiceOf(ps, fid)
    local c = ps and ps.spec2 and ps.spec2[fid]
    return c and c.opt or nil, c
end

local function trustOf(fid, key)
    if StoryEngine.Trade and StoryEngine.Trade.trustPeek then return StoryEngine.Trade.trustPeek(fid, key) end
    if StoryEngine.Trust then return StoryEngine.Trust.of(fid, key) end
    return Radio.channel(fid).trust or 0
end

function Specialty2.waitMinutes(fid, opt, key, now)
    local last = (state().usedBy[key] or {})[fid]
    if not last or not opt then return 0 end
    local gap = (Specialty2.DAYS[opt] or 7) * cooldownMult() * 24 * 60
    return math.max(0, gap - (now - last))
end

-- 세계 효과가 지금 진행 중인가 (rain|power)
function Specialty2.worldActive(kind, now)
    local w = state().world[kind]
    if not w then return false end
    if now and now >= w.untilT then return false end
    return true
end

local function fxOf(kind, key, now)
    for _, f in ipairs(state().fx) do
        if f.kind == kind and f.key == key and (not now or now < f.untilT) then return f end
    end
    return nil
end

local function addFx(fx)
    local list = state().fx
    for i = #list, 1, -1 do
        if list[i].kind == fx.kind and list[i].key == fx.key then table.remove(list, i) end
    end
    list[#list + 1] = fx
    return fx
end

-- 고르기를 바꿀 수 있을 때까지 남은 분 (처음 고르는 것은 0)
function Specialty2.changeWait(ps, fid, now)
    local _, c = Specialty2.choiceOf(ps, fid)
    if not c or not c.t then return 0 end
    return math.max(0, Specialty2.CHANGE_DAYS * 24 * 60 - (now - c.t))
end

-- 선택지별 추가 조건 (자원·신뢰·대기와 별도). nil 이면 괜찮음
local OPTION_CHECKS = {
    power = function(ps, now)
        if Specialty2.worldActive("power", now) then return "world_active" end
        local World = StoryEngine.World
        if World and not World.powerOff() then return "power_on" end
        if StoryEngine.Grid and StoryEngine.Grid.isRestored("power") then return "power_on" end
        return nil
    end,
    rain = function(ps, now)
        if Specialty2.worldActive("rain", now) then return "world_active" end
        return nil
    end,
}

-- 거점 탭 표시·요청 공통. 반환: { unlocked, options, ready, choice, wait(시간), change(시간), reason, active(시간) }
-- reason: off | gone | ill | hurt | locked | no_choice | not_ready | low_trust | cooldown | no_resource | 선택지별
function Specialty2.status(fid, ps)
    if not Specialty2.OPTIONS[fid] then return nil end
    local now = Sensor.now().t
    local key = ps and ps.key
    local opt = Specialty2.choiceOf(ps, fid)
    local ready = {}
    for _, o in ipairs(Specialty2.OPTIONS[fid]) do ready[#ready + 1] = Specialty2.READY[o] == true end
    local st = {
        unlocked = Projects.done2 ~= nil and Projects.done2(fid),
        options = Specialty2.OPTIONS[fid], ready = ready, choice = opt,
        wait = key and math.ceil(Specialty2.waitMinutes(fid, opt, key, now) / 60) or 0,
        change = math.ceil(Specialty2.changeWait(ps, fid, now) / 60),
    }
    local f = opt and key and fxOf(opt, key, now)
    if f then st.active = math.max(1, math.ceil((f.untilT - now) / 60)) end
    if not Specialty2.enabled() then
        st.reason = "off"
    elseif Factions.isGone(fid) then
        st.reason = "gone"
    elseif StoryEngine.Saga and StoryEngine.Saga.specialtyBlocked(fid) then
        st.reason = "ill"
    elseif StoryEngine.Social and StoryEngine.Social.isHurt(fid) then
        st.reason = "hurt"
    elseif not st.unlocked then
        st.reason = "locked"
    elseif not opt then
        st.reason = "no_choice"
    elseif not Specialty2.READY[opt] then
        st.reason = "not_ready"
    elseif OPTION_CHECKS[opt] and OPTION_CHECKS[opt](ps, now) then
        st.reason = OPTION_CHECKS[opt](ps, now)        -- 세계 효과 진행 중·전기 들어옴을 먼저 알린다
    elseif trustOf(fid, key) < Specialty2.TRUST_MIN then
        st.reason = "low_trust"
    elseif st.wait > 0 then
        st.reason = "cooldown"
    elseif Life.get(fid, Life.KEY[fid] or "morale") < Specialty2.RES_MIN then
        st.reason = "no_resource"
    end
    return st
end

-- 고르기 (처음이거나 30일이 지났을 때)
function Specialty2.choose(player, fid, opt)
    local ps = Store.player(player)
    if not Specialty2.OPTIONS[fid] then return false, "no_faction" end
    if not Specialty2.enabled() then return false, "off" end
    if Factions.isGone(fid) then return false, "gone" end
    if not Projects.done2(fid) then return false, "locked" end
    if not Specialty2.isOption(fid, opt) then return false, "bad_option" end
    if not Specialty2.READY[opt] then return false, "not_ready" end
    local now = Sensor.now().t
    local current = Specialty2.choiceOf(ps, fid)
    if current == opt then return false, "same" end
    if Specialty2.changeWait(ps, fid, now) > 0 then return false, "change_wait" end
    ps.spec2 = ps.spec2 or {}
    ps.spec2[fid] = { opt = opt, t = now }
    log("specialty2 chosen", fid, opt, "by", ps.name, current and ("(was " .. current .. ")") or "")
    return true, { option = opt }
end

-- 후임이 이어받으면 그 NPC 에게 고른 것을 모두 지운다 (Voices.take)
function Specialty2.forget(fid)
    for _, ps in pairs(Store.data().players or {}) do
        if ps.spec2 then ps.spec2[fid] = nil end
    end
    for _, used in pairs(state().usedBy) do used[fid] = nil end
end

-- 대기 초기화 (디버그, A-Life 실패 환불)
function Specialty2.clearWait(fid, key)
    local s = state()
    if key then
        if s.usedBy[key] then s.usedBy[key][fid] = nil end
        return
    end
    for _, used in pairs(s.usedBy) do used[fid] = nil end
end

-- ---------------------------------------------------------------- 보급 (스튜·약·고기)

local function deliver(player, ps, fid, opt, items)
    local now = Sensor.now()
    local ok, q = pcall(StoryEngine.Quests.create, "supply_drop", player, ps, 1, now,
        { source = "director", faction = fid, initiator = "gift", spec2 = opt }, items)
    if not ok or not q then
        log("specialty2 delivery failed", fid, opt, tostring(q))
        return nil
    end
    return q
end

-- ---------------------------------------------------------------- 레이

local function freeOutdoor(x, y, z)
    local sq = getCell() and getCell():getGridSquare(x, y, z)
    if not sq then return nil end
    local ok, good = pcall(function()
        return sq:isFree(false) and sq:getRoom() == nil and not sq:isSolid() and not sq:isSolidTrans()
    end)
    if ok and good then return sq end
    return nil
end

local function spawnAnimal(sq, kind, breedName)
    local ok, animal = pcall(function()
        local breed = nil
        local def = AnimalDefinitions and AnimalDefinitions.getDef and AnimalDefinitions.getDef(kind)
        if def and def.getBreedByName then breed = def:getBreedByName(breedName) end
        local a = addAnimal(getCell(), sq:getX(), sq:getY(), sq:getZ(), kind, breed)
        if a then a:addToWorld() end
        return a
    end)
    if not ok then log("specialty2 animal error:", tostring(animal)) return nil end
    return animal
end

local function livestock(player, ps, fid)
    local kit = Specialty2.ANIMAL_KITS[ZombRand(#Specialty2.ANIMAL_KITS) + 1]
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    local spot = nil
    local start = ZombRand(8)
    for i = 0, 15 do
        local angle = ((start + i) % 8) * math.pi / 4
        local d = rand(Specialty2.ANIMAL_DIST)
        local sq = freeOutdoor(math.floor(px + math.cos(angle) * d), math.floor(py + math.sin(angle) * d), pz)
        if sq then spot = sq break end
    end
    if not spot then return false, "no_spot" end
    local made = 0
    for _, entry in ipairs(kit) do
        for _ = 1, entry[3] do
            local sq = freeOutdoor(spot:getX() + ZombRand(3) - 1, spot:getY() + ZombRand(3) - 1, pz) or spot
            if spawnAnimal(sq, entry[1], entry[2]) then made = made + 1 end
        end
    end
    if made == 0 then return false, "no_spot" end
    local what = kit[1][1] == "cow" and "a milk cow" or "a few laying hens and a rooster"
    return true, { count = made, item = kit[1][1],
                   topic = "You and your neighbors drove " .. what .. " over to " .. tostring(ps.name)
                       .. " and left them nearby. Tell them to look after them." }
end

local function stew(player, ps, fid)
    if not deliver(player, ps, fid, "stew", { Specialty2.STEW }) then return false, "no_spot" end
    local now = Sensor.now()
    local f = addFx({ kind = "stew", key = ps.key, untilT = now.t + Specialty2.STEW_HOURS * 60 })
    pcall(function() f.last = player:getStats():get(CharacterStat.UNHAPPINESS) end)
    return true, { topic = "You invited " .. tostring(ps.name) .. " over for a home-cooked dinner and, since they could "
        .. "not come, sent a pot of your stew their way (the location is in their quest list). Talk like family." }
end

-- ---------------------------------------------------------------- 케이시

local function praise(player, ps, fid)
    local now = Sensor.now()
    state().praise[ps.key] = { name = ps.name, day = now.dayKey }
    if StoryEngine.Broadcast then
        pcall(StoryEngine.Broadcast.note, "Tonight's broadcast praises " .. tostring(ps.name)
            .. " for everything they have done for the county's survivors.")
    end
    return true, { topic = "You promised " .. tostring(ps.name) .. " to praise them on tonight's broadcast so every "
        .. "survivor in the county hears what they have done. Sound excited." }
end

-- 다음 날 아침: 칭찬을 들은 NPC 들의 신뢰 +2 (90 이상은 그대로)
local function praiseTick(now)
    local s = state()
    local hour = getGameTime():getHour()
    if hour < Specialty2.PRAISE_HOUR then return end
    for key, p in pairs(s.praise) do
        if p.day ~= now.dayKey then
            s.praise[key] = nil
            local count = 0
            for _, f in ipairs(Factions.list) do
                if not Factions.isGone(f.id) and trustOf(f.id, key) < Specialty2.PRAISE_CAP then
                    StoryEngine.Trust.apply(f.id, Specialty2.PRAISE_TRUST, "spec2_praise", nil, key)
                    count = count + 1
                end
            end
            log("specialty2 praise applied", p.name, count)
        end
    end
end

local function sos(player, ps, fid)
    local now = Sensor.now()
    local parts = {}
    local snipeCount = 0
    -- 1) 방위대원 1명 (A-Life) / 없으면 방위대 저격 몫
    if not Factions.isGone("guard") then
        local sent = false
        local ALife = StoryEngine.ALife
        if ALife and ALife.enabled() and ALife.available() then
            local ok = ALife.sendSupport(player, "guard", "specialty2", nil, 1, nil, 1,
                { hours = Specialty2.SOS_MIN / 60, quiet = true })
            sent = ok == true
        end
        if not sent then snipeCount = snipeCount + Specialty2.SOS_GUARD_SNIPE end
        parts[#parts + 1] = "a soldier from the guard"
    end
    -- 2) 행크 저격
    if not Factions.isGone("hunter") then
        snipeCount = snipeCount + Specialty2.SOS_SNIPE
        parts[#parts + 1] = "Hank's rifle"
    end
    if snipeCount > 0 then
        Specialty.snipeCap[ps.key] = snipeCount
        Net.toClient(player, "specSnipe", { faction = Factions.isGone("hunter") and "guard" or "hunter",
            count = snipeCount, minutes = Specialty2.SOS_SNIPE_MIN, radius = Specialty.SNIPE_RADIUS,
            sound = Specialty.SNIPE_SOUND.hunter })
    end
    -- 3) 미끼 소음 (빅)
    if not Factions.isGone("rats") and Specialty.HANDLERS.rats then
        local ok = pcall(Specialty.HANDLERS.rats, player, ps, "rats", 3)
        if ok then parts[#parts + 1] = "Vic's crew making noise to draw the dead off" end
    end
    -- 4) 긴장·근육통 (파이크) / 5) 통증 (닥): SOS_MIN 동안 매분
    local calm = not Factions.isGone("pike")
    local numb = not Factions.isGone("doc")
    if calm or numb then
        addFx({ kind = "sos", key = ps.key, untilT = now.t + Specialty2.SOS_MIN, calm = calm, numb = numb })
        Net.toClient(player, "spec2Fx", { kind = "sos", minutes = Specialty2.SOS_MIN, calm = calm, numb = numb })
        if calm then parts[#parts + 1] = "Pastor Pike talking them calm" end
        if numb then parts[#parts + 1] = "June's advice to fight through the pain" end
    end
    if #parts == 0 then return false, "no_help" end
    return true, { count = #parts, topic = tostring(ps.name) .. " pressed the SOS beacon you built. You relayed it and "
        .. "help is coming right now: " .. table.concat(parts, ", ") .. ". Talk fast and steady." }
end

local function power(player, ps, fid)
    local Grid = StoryEngine.Grid
    if not Grid then return false, "no_grid" end
    local now = Sensor.now()
    Grid.restore("power", Specialty2.POWER_DAYS, "casey_temp")
    state().world.power = { untilT = now.t + Specialty2.POWER_DAYS * 24 * 60, key = ps.key }
    return true, { topic = "You patched the dead power grid together with what you had. Power is back for about "
        .. StoryEngine.intToString(Specialty2.POWER_DAYS) .. " days, no longer. Tell " .. tostring(ps.name) .. " to use it." }
end

-- 임시 송전이 끝났다 (Grid.ensure): 작전 날짜를 건드리지 않고 조용히 알린다
function Specialty2.onTempPowerEnd()
    state().world.power = nil
    log("specialty2 temp power ended")
end

-- ---------------------------------------------------------------- 닥

local function sickness(player)
    local found = {}
    pcall(function()
        local stats = player:getStats()
        for _, name in ipairs(Specialty2.SICK_STATS) do
            local stat = CharacterStat[name]
            if stat and stats:get(stat) > Specialty2.SICK_MIN then found[#found + 1] = string.lower(name) end
        end
    end)
    pcall(function()
        local bd = player:getBodyDamage()
        if bd:isHasACold() then found[#found + 1] = "cold" end
    end)
    return found
end

local function cure(player)
    pcall(function()
        local stats = player:getStats()
        for _, name in ipairs(Specialty2.SICK_STATS) do
            local stat = CharacterStat[name]
            if stat then stats:set(stat, 0) end
        end
    end)
    pcall(function()
        local bd = player:getBodyDamage()
        bd:setHasACold(false)
        bd:setColdStrength(0)
        pcall(function() bd:setCatchACold(0) end)
    end)
    pcall(syncPlayerStats, player, 0x7FFFFFFF)
    pcall(sendDamage, player)
end

local function illness(player, ps, fid)
    local found = sickness(player)
    if #found == 0 then return false, "not_sick" end
    cure(player)
    addFx({ kind = "illness", key = ps.key, untilT = Sensor.now().t + Specialty2.ILLNESS_DAYS * 24 * 60 })
    return true, { item = table.concat(found, ","), topic = "You walked " .. tostring(ps.name) .. " through treating "
        .. "their sickness (" .. table.concat(found, ", ") .. ") and told them how to stay clear of it for a few days." }
end

local function numb(player)
    pcall(function()
        local bd = player:getBodyDamage()
        if bd:getPainReduction() < Specialty2.PAIN_REDUCTION then bd:setPainReduction(Specialty2.PAIN_REDUCTION) end
    end)
    pcall(function() player:getStats():set(CharacterStat.PAIN, 0) end)
    pcall(sendDamage, player)
end

local function pain(player, ps, fid)
    local now = Sensor.now()
    addFx({ kind = "pain", key = ps.key, untilT = now.t + Specialty2.PAIN_DAYS * 24 * 60 })
    numb(player)
    Net.toClient(player, "spec2Fx", { kind = "pain", minutes = Specialty2.PAIN_DAYS * 24 * 60, numb = true })
    return true, { topic = "You prescribed " .. tostring(ps.name) .. " a careful pain regimen for the next three days "
        .. "so the pain does not slow them down. Be clear about not overdoing it." }
end

-- 약초인가 (바닐라 채집 분류 MedicinalPlants)
local herbSet = nil
function Specialty2.isHerb(fullType)
    if not herbSet then
        local set, fromForage = {}, false
        pcall(function()
            for itemType, def in pairs(forageSystem and forageSystem.itemDefs or {}) do
                for _, cat in ipairs(def.categories or {}) do
                    if cat == "MedicinalPlants" then
                        set[def.type or itemType] = true
                        fromForage = true
                    end
                end
            end
        end)
        for _, ft in ipairs(Specialty2.HERBS) do set[ft] = true end
        herbSet = set
        if not fromForage then herbSet.__fallback = true end
    end
    return herbSet[fullType] == true
end

local function questItem(it)
    local mod = it:getModData()
    local Value = StoryEngine.Value
    return mod ~= nil and mod.storyQuest ~= nil and Value ~= nil and Value.isQuestActive(mod.storyQuest) == true
end

local function herbsOf(player)
    local out = {}
    local list = player:getInventory():getItems()
    for i = 0, list:size() - 1 do
        local it = list:get(i)
        if it and Specialty2.isHerb(it:getFullType()) and not player:isEquipped(it)
            and not questItem(it) then
            out[#out + 1] = it
        end
    end
    return out
end
Specialty2.herbsOf = herbsOf

local function pharmacy(player, ps, fid, args)
    local med = Specialty2.PHARMACY[tostring(args.med or "")]
    if not med then return false, "bad_option" end
    local count = math.max(1, math.min(Specialty2.PHARMACY_MAX, math.floor(tonumber(args.count) or 1)))
    local need = med.herbs * count
    local herbs = herbsOf(player)
    if #herbs < need then return false, "no_herbs" end
    local items = {}
    for _ = 1, count do items[#items + 1] = med.item end
    if not deliver(player, ps, fid, "pharmacy", items) then return false, "no_spot" end
    for i = 1, need do StoryEngine.Items.remove(herbs[i], player) end
    return true, { count = count, item = med.item, herbs = need,
                   topic = tostring(ps.name) .. " sent you " .. StoryEngine.intToString(need) .. " medicinal herbs and you "
                       .. "turned them into " .. StoryEngine.intToString(count) .. " " .. med.item:gsub("^Base%.", "")
                       .. ", now on the way to them. Sound proud of the work." }
end

-- ---------------------------------------------------------------- 파이크

local function reconcile(player, ps, fid)
    local worst, low = nil, 1000
    for _, f in ipairs(Factions.list) do
        if f.id ~= "pike" and not Factions.isGone(f.id) then
            local t = trustOf(f.id, ps.key)
            if t < low then worst, low = f.id, t end
        end
    end
    if not worst then return false, "no_target" end
    StoryEngine.Trust.apply(worst, Specialty2.RECONCILE_TRUST, "spec2_reconcile", nil, ps.key)
    local ch = Radio.channel(worst)
    if StoryEngine.Trust.personalMode() then
        if ch.workBurnBy then ch.workBurnBy[ps.key] = nil end
    else
        ch.workBurnT = nil
    end
    local n = Life.npc(worst)
    n.counts = n.counts or {}
    n.counts.crisis_snubbed, n.counts.broken = 0, 0
    return true, { item = worst, topic = "You went to " .. tostring(StoryEngine.Stories.NAMES[worst] or worst)
        .. " and made peace between them and " .. tostring(ps.name) .. ". Old grudges are set down. Say so gently." }
end

local function baptism(player, ps, fid)
    local now = Sensor.now()
    local f = addFx({ kind = "baptism", key = ps.key, untilT = now.t + Specialty2.BAPTISM_DAYS * 24 * 60 })
    pcall(function() f.last = player:getStats():get(CharacterStat.ENDURANCE) end)
    return true, { topic = "You baptized " .. tostring(ps.name) .. " over the radio. For two days they will tire far more "
        .. "slowly. Give a short blessing." }
end

-- ---------------------------------------------------------------- 듀이

local function tuning(player, ps, fid)
    local list = Specialty.vehiclesNear and Specialty.vehiclesNear(player:getX(), player:getY(), Specialty2.TUNE_RADIUS) or {}
    local target = nil
    for _, e in ipairs(list) do
        local md = e.v:getModData()
        if not md.seTuned then target = e.v break end
    end
    if not target then return false, #list > 0 and "already_tuned" or "no_vehicle" end
    local ok, err = pcall(function()
        local loud = target:getEngineLoudness()
        local power = target:getEnginePower()
        target:setEngineFeature(100, math.max(1, math.floor(loud * Specialty2.TUNE_LOUD)),
            math.floor(power * Specialty2.TUNE_POWER))
        target:transmitEngine()
    end)
    if not ok then
        log("specialty2 tuning error:", tostring(err))
        return false, "no_vehicle"
    end
    target:getModData().seTuned = true
    pcall(function() target:transmitModData() end)
    return true, { topic = "You talked " .. tostring(ps.name) .. " through tuning their vehicle's engine: more power, "
        .. "quieter, in top shape for good. Sound like a proud mechanic." }
end

-- ---------------------------------------------------------------- 빅

local function bodyguard(player, ps, fid)
    local now = Sensor.now()
    local ALife = StoryEngine.ALife
    if ALife and ALife.enabled() and ALife.available() then
        local ok, why = ALife.sendSupport(player, "rats", "specialty2", nil, 1, nil, Specialty2.BODYGUARD_COUNT,
            { hours = Specialty2.BODYGUARD_HOURS, quiet = true })
        if not ok then return false, why end
        return true, { topic = "You sent two of your crew to stick to " .. tostring(ps.name) .. " for a whole day as "
            .. "bodyguards. Make it sound like a favor they owe you." }
    end
    addFx({ kind = "bodyguard", key = ps.key, untilT = now.t + Specialty2.BODYGUARD_FALLBACK_HOURS * 60, nextT = now.t })
    return true, { topic = "You put two of your crew on " .. tostring(ps.name) .. " for half a day, shadowing them and "
        .. "taking out any dead that get close. Make it sound like a favor they owe you." }
end

-- ---------------------------------------------------------------- 행크

local function game(player, ps, fid)
    local total = 0
    for _, m in ipairs(Specialty2.MEATS) do total = total + m[2] end
    local items = {}
    for _ = 1, rand(Specialty2.MEAT_COUNT) do
        local roll = ZombRand(total)
        for _, m in ipairs(Specialty2.MEATS) do
            roll = roll - m[2]
            if roll < 0 then items[#items + 1] = m[1] break end
        end
    end
    if not deliver(player, ps, fid, "game", items) then return false, "no_spot" end
    return true, { count = #items, topic = "You shared the meat from your last hunt with " .. tostring(ps.name)
        .. " and left it nearby (it is in their quest list). Tell them to eat it before it turns." }
end

Specialty2.HANDLERS = {
    livestock = livestock, stew = stew, praise = praise, sos = sos, power = power, illness = illness, pain = pain,
    pharmacy = pharmacy, reconcile = reconcile, baptism = baptism, tuning = tuning, bodyguard = bodyguard, game = game,
}

-- ---------------------------------------------------------------- 쓰기

-- 반환: true, info / false, 이유, 대기(시간)
function Specialty2.use(player, fid, args)
    if not Specialty2.OPTIONS[fid] then return false, "no_faction" end
    if not Factions.canTalk(player) then return false, "no_radio" end
    local ps = Store.player(player)
    if StoryEngine.Trust then StoryEngine.Trust.contact(fid, ps.key) end
    local st = Specialty2.status(fid, ps)
    if st.reason then return false, st.reason, st.wait end
    local opt = st.choice
    local handler = Specialty2.HANDLERS[opt]
    if not handler then return false, "not_ready" end
    local ok, info = handler(player, ps, fid, args or {})
    if not ok then
        log("specialty2 refused", fid, opt, tostring(info))
        return false, info
    end
    local now = Sensor.now()
    local s = state()
    s.usedBy[ps.key] = s.usedBy[ps.key] or {}
    s.usedBy[ps.key][fid] = now.t
    Life.change(fid, Life.KEY[fid] or "morale", -Specialty2.COST, "specialty")
    Life.record(fid, "specialty2", ps.name, 0, { spec = opt })
    Store.addNote(ps, { kind = "specialty2_" .. opt, faction = fid, clock = now.clock, count = info.count,
                        item = info.item })
    if info.topic then
        Radio.react(fid, "event", info.topic .. " Keep it short and in character.",
            { text = "On it.", lt = { key = "IGUI_StoryEngine_RadioSay_spec2_" .. opt } }, ps, { overhead = true })
    end
    log("specialty2", fid, opt, "for", ps.name)
    return true, info
end

-- ---------------------------------------------------------------- 매분: 지속 효과

local function fxTick(now)
    local s = state()
    local keep = {}
    for _, f in ipairs(s.fx) do
        if now.t < f.untilT then
            keep[#keep + 1] = f
            local p = playerByKey(f.key)
            if p and not p:isDead() then
                local ok, err = pcall(Specialty2.FX[f.kind] or function() end, p, f, now)
                if not ok then log("specialty2 fx error", f.kind, tostring(err)) end
            end
        end
    end
    s.fx = keep
    for kind, w in pairs(s.world) do
        if now.t >= w.untilT then s.world[kind] = nil end
    end
end

Specialty2.FX = {
    -- 24시간 동안 불행이 오르지 않는다 (내려가는 것은 그대로)
    stew = function(p, f)
        local stats = p:getStats()
        local cur = stats:get(CharacterStat.UNHAPPINESS)
        if f.last and cur > f.last then
            stats:set(CharacterStat.UNHAPPINESS, f.last)
            pcall(syncPlayerStats, p, 0x7FFFFFFF)
        else
            f.last = cur
        end
    end,
    sos = function(p, f)
        local stats = p:getStats()
        if f.calm then
            stats:set(CharacterStat.PANIC, 0)
            stats:set(CharacterStat.STRESS, 0)
            local parts = p:getBodyDamage():getBodyParts()
            for i = 0, parts:size() - 1 do
                local bp = parts:get(i)
                if bp:getStiffness() > 0 then
                    bp:setStiffness(0)
                    pcall(syncBodyPart, bp, 0xFFFFFFFFFFF)
                end
            end
            pcall(syncPlayerStats, p, 0x7FFFFFFF)
        end
        if f.numb then numb(p) end
    end,
    illness = function(p, f, now)
        if f.nextT and now.t < f.nextT then return end
        f.nextT = now.t + 10
        if #sickness(p) > 0 then cure(p) end
    end,
    pain = function(p, f, now)
        if f.nextT and now.t < f.nextT then return end
        f.nextT = now.t + 10
        numb(p)
    end,
    -- 지구력이 줄어든 만큼의 2/3 을 돌려준다 (줄어드는 속도 1/3)
    baptism = function(p, f)
        local stats = p:getStats()
        local cur = stats:get(CharacterStat.ENDURANCE)
        if f.last and cur < f.last then
            local kept = f.last - (f.last - cur) * Specialty2.BAPTISM_SHARE
            stats:set(CharacterStat.ENDURANCE, kept)
            pcall(syncPlayerStats, p, 0x7FFFFFFF)
            f.last = kept
        else
            f.last = cur
        end
    end,
    -- A-Life 가 없을 때의 보디가드: 10분마다 가까이 온 좀비를 둘까지 (요청한 클라이언트가 쓰러뜨린다)
    bodyguard = function(p, f, now)
        if f.nextT and now.t < f.nextT then return end
        f.nextT = now.t + 10
        Net.toClient(p, "specSnipe", { faction = "rats", count = Specialty2.BODYGUARD_FALLBACK_KILLS, minutes = 1,
            radius = Specialty2.BODYGUARD_RADIUS, sound = "M9Shoot", quiet = true })
    end,
}

function Specialty2.tick(now)
    for _, fn in ipairs({ fxTick, praiseTick }) do
        local ok, err = pcall(fn, now)
        if not ok then log("specialty2 tick error:", err) end
    end
end

-- 거점 탭에 넘기는 상태 (보는 사람 기준)
function Specialty2.listFor(fid, psKey)
    local ps = psKey and Store.data().players and Store.data().players[psKey] or nil
    return Specialty2.status(fid, ps)
end

function Specialty2.statusText()
    local s = state()
    local parts = {}
    for _, f in ipairs(s.fx) do parts[#parts + 1] = f.kind .. ":" .. tostring(f.key) end
    for kind, w in pairs(s.world) do parts[#parts + 1] = "world " .. kind end
    return "spec2 " .. (#parts > 0 and table.concat(parts, " ") or "none")
end

Events.EveryOneMinute.Add(function()
    if not Specialty2.enabled() then return end
    Specialty2.tick(Sensor.now())
end)

return Specialty2
