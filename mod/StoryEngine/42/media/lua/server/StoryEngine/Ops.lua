-- 전력·수도 복구 작전 (2026-10-01, 설계 docs/IDEAS_WORLD_EVENTS.md "전력·수도 복구 작전").
--
-- 시작: 바닐라 단전·단수(또는 복구가 끝나 다시 끊긴 날)부터 14일 뒤, 하루 한 번 10% + 하루 5%씩 (사용자 결정).
--       수도·전력은 따로 굴리고 작전은 동시에 하나만. 다른 쪽이 당첨되면 줄을 서서 지금 작전이 끝난 뒤 다음 날 시작.
-- 구성: 둘 다 5막, 약 12~14일, 여러 마을을 돈다 (같은 난이도, 사용자 결정). 막마다 기한, 넘기면 그 막을 다시 (더 어렵게),
--       같은 막 두 번 실패면 작전 실패 -> 그날부터 다시 14일. 성공하면 Grid.restore 60일.
--   1 fetch   다른 마을 시설 근처 건물에서 자료 회수 (WaterManual / GridSchematic)
--   2 collect 여럿이 나눠 내는 모금 (무전 제출)
--   3 clear   두세 곳 시설 주변 무리 소탕 (동시에, 나눠 맡기)
--   4 defend  시설에서 정해진 시간 버티기 (머무는 동안 추적 무리가 몰려옴)
--   5 visit   마지막 시설 방문 -> 복구
-- 장소는 바닐라 지도의 실제 급수탑·송전탑·변압 설비 (OpsSites.lua).
-- NPC 지원 (대기 시간과 무관, Specialty.assist): 레이 막마다 보급, 케이시 작전 내내 정찰, 듀이 2막 차량 수리,
--   방위대 소탕·방어 현장에 처음 다가갈 때, 행크 첫 무리, 빅 두 번째 무리, 닥 크게 다쳤을 때 막마다 한 번, 파이크 방어 끝.
-- 판정은 전부 여기(Lua)서 하고, AI 는 무전·일지에 서사만 입힌다.

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Places"
require "StoryEngine/Factions"
require "StoryEngine/Radio"
require "StoryEngine/Quests"
require "StoryEngine/Hunt"
require "StoryEngine/World"
require "StoryEngine/Grid"
require "StoryEngine/GridSync"
require "StoryEngine/OpsSites"
require "StoryEngine/Specialty"

local Net = StoryEngine.Net
local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Places = StoryEngine.Places
local Factions = StoryEngine.Factions
local Radio = StoryEngine.Radio
local Quests = StoryEngine.Quests
local Grid = StoryEngine.Grid
local GridSync = StoryEngine.GridSync
local Sites = StoryEngine.OpsSites
local log = StoryEngine.log

local Ops = {}
StoryEngine.Ops = Ops

Ops.START_DAYS = 14          -- 끊긴 뒤 이만큼 지나야 굴리기 시작 (사용자 결정)
Ops.START_CHANCE = 10        -- 14일째 확률(%)
Ops.START_STEP = 5           -- 하루마다 +
Ops.RESTORE_DAYS = 60        -- 복구 유지 (사용자 결정)
Ops.MAX_FAILS = 2            -- 같은 막을 이만큼 실패하면 작전 실패
Ops.RETRY_NEED = 1.5         -- 다시 하는 모금은 1.5배
Ops.RETRY_SIZE = 1.25        -- 다시 하는 소탕은 1.25배
Ops.CLEAR_MULT = 1.5         -- 작전 소탕 = 일반 소탕(진행 단계 + 2 등급)의 1.5배
Ops.GUARD_DIST = 60          -- 방위대가 엄호하러 오는 거리
Ops.HURT_HEALTH = 50         -- 닥이 치료하러 오는 체력
Ops.THANKS_GAP = 120         -- 모금 감사 무전 간격 (게임 분)
Ops.ASSIST_TRIES = 6         -- 저격은 쏠 좀비가 있어야 해서 10분마다 다시 시도하는 횟수

-- need: { 아이템, 개수 }. 액체 용기(빈 통 문제)는 쓰지 않는다
Ops.DEF = {
    water = {
        lead = "pike", grid = "water",
        acts = {
            { id = "survey", kind = "fetch", days = 3, site = "fetch", item = "StoryEngine.WaterManual" },
            { id = "supplies", kind = "collect", days = 3, dewey = true,
              need = { { "Base.Pipe", 4 }, { "Base.PipeWrench", 1 }, { "Base.RubberHose", 2 }, { "Base.DuctTape", 3 },
                       { "Base.SheetMetal", 4 }, { "Base.Glue", 2 } } },
            { id = "network", kind = "clear", days = 3, site = "clear" },
            { id = "plant", kind = "defend", days = 3, site = "defend", hours = 6, wave = 45, waveShare = 0.4 },
            { id = "restart", kind = "visit", days = 2, site = "visit" },
        },
    },
    power = {
        lead = "casey", grid = "power",
        acts = {
            { id = "signal", kind = "fetch", days = 3, site = "fetch", item = "StoryEngine.GridSchematic" },
            { id = "equipment", kind = "collect", days = 3, dewey = true,
              need = { { "Base.ElectricWire", 6 }, { "Base.ElectronicsScrap", 15 }, { "Base.Amplifier", 2 },
                       { "Base.Pliers", 1 }, { "Base.Screwdriver", 1 }, { "Base.CarBattery1", 1 } } },
            { id = "line", kind = "clear", days = 3, site = "clear" },
            { id = "substation", kind = "defend", days = 3, site = "defend", hours = 8, wave = 40, waveShare = 0.5 },
            { id = "control", kind = "visit", days = 2, site = "visit" },
        },
    },
}
Ops.KINDS = { "water", "power" }

-- AI 에게 넘기는 막 설명 (영어). %s = 마을 이름(들)
Ops.TOPIC = {
    water = {
        survey = "The county water repair is starting. A former waterworks worker among the people you shelter says the "
            .. "water system's operating manual is in an office near the water tower in %s. Ask the players to bring it back.",
        supplies = "The manual is in hand. To patch the pumps you need pipes, a pipe wrench, rubber hose, duct tape, "
            .. "sheet metal and glue. Ask everyone to send what they can over the radio; it can be shared out.",
        network = "Before the water can flow, the dead swarming the water towers at %s must be cleared. The players can split up.",
        plant = "Now the hard part: someone has to hold out at the water works by the tower in %s for hours while the pumps "
            .. "are patched. The noise will draw the dead in waves.",
        restart = "Everything is ready. Someone just needs to get to the tower in %s and open the main valves.",
    },
    power = {
        signal = "You picked up an old power company work crew frequency. They mention a county grid schematic left at "
            .. "a site office near the substation in %s. Ask the players to bring it back.",
        equipment = "With the schematic you know what is broken. You need electrical wire, electronics scrap, amplifiers, "
            .. "pliers, a screwdriver and a car battery. Ask everyone to send what they can over the radio.",
        line = "The main line runs on pylons across the county. The dead have gathered around the pylons near %s; "
            .. "they must be cleared before the line can be checked. The players can split up.",
        substation = "Someone has to hold the substation near %s for hours while it is repaired. The hum and the work "
            .. "will draw the dead in waves.",
        control = "The line is patched. Someone needs to reach the control yard at the substation near %s and throw the switch.",
    },
}

-- ---------------------------------------------------------------- 상태

local function state()
    local d = Store.data()
    d.ops = d.ops or {}
    local s = d.ops
    s.seq = s.seq or 0
    s.history = s.history or {}
    s.retryFrom = s.retryFrom or {}
    s.queue = s.queue or {}
    return s
end

function Ops.enabled()
    return StoryEngine.option("Operations", true) == true
end

function Ops.current()
    return state().current
end

function Ops.active()
    return state().current ~= nil
end

local function timeMult()
    return StoryEngine.Tuning and StoryEngine.Tuning.num("QuestTimeMult") or 1
end

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

local function townOf(site)
    return site and Places.describe(site.x, site.y).town or "?"
end

-- 이끄는 NPC (떠났으면 다른 살아 있는 NPC)
function Ops.leadOf(kind)
    local lead = Ops.DEF[kind].lead
    if not Factions.isGone(lead) then return lead end
    for _, f in ipairs(Factions.list) do
        if not Factions.isGone(f.id) then return f.id end
    end
    return nil
end

-- 모든 캐릭터 일지에 한 줄 (영어, 브릿지 "op" 메모)
local function noteAll(text, now)
    for _, ps in pairs(Store.data().players) do
        if not ps.dead then Store.addNote(ps, { kind = "op", text = text, clock = now.clock }) end
    end
end

local function notice(event, op, extra)
    local args = { event = event, kind = op.kind, act = op.act, acts = #Ops.DEF[op.kind].acts }
    for k, v in pairs(extra or {}) do args[k] = v end
    pcall(Net.toAll, "opNotice", args)
end

local function say(fid, topic, fallbackKey, ps)
    if not fid then return end
    Radio.react(fid, "event", topic .. " Keep it short and in character.",
        { text = "...", lt = { key = "IGUI_StoryEngine_RadioSay_" .. fallbackKey } }, ps)
end

-- 소문(라디오 방송 재료)과 다음 공용 주파수 장면 화제 (이끄는 NPC + 살아 있는 둘)
local function spread(lead, text)
    if not StoryEngine.Social then return end
    pcall(StoryEngine.Social.news, "all", text)
    local ids = {}
    if lead then ids[1] = lead end
    for _, f in ipairs(Factions.list) do
        if #ids >= 3 then break end
        if f.id ~= lead and not Factions.isGone(f.id) then ids[#ids + 1] = f.id end
    end
    if #ids >= 2 then pcall(StoryEngine.Social.queueTopic, ids, text .. " They talk about it.") end
end

-- ---------------------------------------------------------------- 시작 조건

-- 끊긴 날 (아포칼립스 경과 일수). 켜져 있으면 nil
function Ops.offDay(kind)
    local off
    if kind == "power" then off = StoryEngine.World.powerOff() else off = StoryEngine.World.waterOff() end
    if not off or Grid.isRestored(kind) then return nil end
    local g = Store.data().grid or {}
    local day
    local cut = g.cut and g.cut[kind]
    if cut then
        day = cut.day or 0
    else
        local v = GridSync.get(kind)
        day = (v and v >= 0) and v or 0
    end
    day = math.max(day, (g.endedDay or {})[kind] or 0, state().retryFrom[kind] or 0)
    return day
end

-- 오늘 시작할 확률(%) (아직 이르면 0)
function Ops.chance(kind, today)
    local off = Ops.offDay(kind)
    if not off then return 0 end
    local days = math.floor(today - off)
    if days < Ops.START_DAYS then return 0 end
    return math.min(100, Ops.START_CHANCE + Ops.START_STEP * (days - Ops.START_DAYS))
end

-- 하루 한 번 (접속자가 있을 때): 굴려서 시작하거나 줄을 세운다
function Ops.daily(now)
    if not Ops.enabled() or #Sensor.players() == 0 then return end
    local s = state()
    if s.rollDay == now.dayKey then return end
    s.rollDay = now.dayKey
    local today = Grid.today()
    -- 줄 선 작전: 지금 작전이 없고 여전히 끊겨 있으면 시작
    if not s.current and #s.queue > 0 and not (StoryEngine.Saga and StoryEngine.Saga.active()) then
        local kind = table.remove(s.queue, 1)
        if Ops.offDay(kind) then
            Ops.start(kind, "queued")
            return
        end
    end
    for _, kind in ipairs(Ops.KINDS) do
        local chance = Ops.chance(kind, today)
        local queued = false
        for _, k in ipairs(s.queue) do if k == kind then queued = true end end
        local running = s.current and s.current.kind == kind
        if chance > 0 and not queued and not running then
            local hit = ZombRand(100) < chance
            log("ops roll", kind, "day", math.floor(today - Ops.offDay(kind)), chance .. "%", hit and "hit" or "miss")
            if hit then
                if s.current or (StoryEngine.Saga and StoryEngine.Saga.active()) then
                    s.queue[#s.queue + 1] = kind
                    log("ops queued", kind)
                else
                    Ops.start(kind, "roll")
                end
            end
        end
    end
end

-- ---------------------------------------------------------------- 장소

-- 접속자들의 가운데 (없으면 대상 캐릭터의 마지막 위치)
local function anchor()
    local sx, sy, n = 0, 0, 0
    for _, p in ipairs(Sensor.players()) do
        if not p:isDead() then sx, sy, n = sx + p:getX(), sy + p:getY(), n + 1 end
    end
    if n > 0 then return sx / n, sy / n end
    return 10754, 9926      -- 멀드로
end

function Ops.pickSites(kind, ax, ay, clearCount)
    local sites = {}
    if kind == "water" then
        local towers = Sites.byDistance(Sites.WATER_TOWERS, ax, ay)
        local plant = towers[1]
        sites.defend = { x = plant.x, y = plant.y, name = "water_plant" }
        local main = Sites.spread(Sites.WATER_TOWERS, plant.x, plant.y, 1, 300, { plant })[1] or plant
        sites.visit = { x = main.x, y = main.y, name = "water_main" }
        local far = Sites.spread(Sites.WATER_TOWERS, ax, ay, 1, 600, { plant, main })[1] or main
        sites.fetch = { x = far.x, y = far.y, name = "water_office" }
        sites.clear = {}
        for _, t in ipairs(Sites.spread(Sites.WATER_TOWERS, plant.x, plant.y, clearCount, 300, { plant })) do
            sites.clear[#sites.clear + 1] = { x = t.x, y = t.y, name = "water_tower" }
        end
    else
        local subs = Sites.byDistance(Sites.SUBSTATIONS, ax, ay)
        local sub = subs[1]
        sites.defend = { x = sub.x, y = sub.y, name = "substation" }
        local control = nil
        for _, s in ipairs(subs) do
            if s ~= sub and s.main then control = s; break end
        end
        control = control or subs[2] or sub
        sites.visit = { x = control.x, y = control.y, name = "control_yard" }
        local far = Sites.spread(Sites.SUBSTATIONS, ax, ay, 1, 600, { sub, control })[1] or control
        sites.fetch = { x = far.x, y = far.y, name = "grid_office" }
        sites.clear = {}
        for _, t in ipairs(Sites.spread(Sites.LINE, ax, ay, clearCount, 400, nil)) do
            sites.clear[#sites.clear + 1] = { x = t.x, y = t.y, name = "pylon" }
        end
    end
    return sites
end

-- ---------------------------------------------------------------- 막

local function act(op, n) return Ops.DEF[op.kind].acts[n or op.act] end

local function originFor(op, n)
    return { source = "op", op = op.id, opKind = op.kind, act = n, acts = #Ops.DEF[op.kind].acts,
             retry = op.fails[n] or 0, faction = op.lead }
end

local function clearSize(op, n)
    local stage = Store.stage()
    local base = Quests.HORDE_SIZE[math.min(Quests.MAX_TIER, stage + 2)] or 20
    local mult = Ops.CLEAR_MULT   -- 샌드박스 ZombieMult 는 Quests.createSite 가 곱한다
    for _ = 1, (op.fails[n] or 0) do mult = mult * Ops.RETRY_SIZE end
    return math.max(6, math.floor(base * mult + 0.5))
end

local function siteTowns(list)
    local names, seen = {}, {}
    for _, site in ipairs(list) do
        local t = townOf(site)
        if not seen[t] then seen[t] = true; names[#names + 1] = t end
    end
    return table.concat(names, " and ")
end

-- 막마다: 레이 보급, 케이시 정찰, (모금 막) 듀이 차량 수리
local function actSupport(op, a, now, retry)
    local players = Sensor.players()
    if #players == 0 then return end
    local p = playerByKey(op.target) or players[ZombRand(#players) + 1]
    local ps = Store.player(p)
    if not Factions.isGone("ray") and not retry then       -- 다시 하는 막에는 보급이 또 오지 않는다 (점검 C7)
        local ok, err = pcall(Quests.create, "supply_drop", p, ps, 1, now,
            { source = "reward", faction = "ray", rewardKind = "op" }, StoryEngine.Loot.roll(1, "ray"))
        if not ok then log("ops ray supply error:", err) end
    end
    for _, pl in ipairs(players) do
        pcall(StoryEngine.Specialty.opScout, pl, op.actDeadlineT)
    end
    if a.dewey then
        local okD, why = StoryEngine.Specialty.assist("dewey", p)
        if not okD then log("ops dewey skipped", tostring(why)) end
    end
end

function Ops.startAct(n, retry)
    local s = state()
    local op = s.current
    if not op then return false end
    local now = Sensor.now()
    local a = act(op, n)
    op.act = n
    op.actStartT = now.t
    op.actDeadlineT = now.t + math.floor(a.days * 24 * 60 * timeMult())
    op.quests[n] = {}
    op.assisted[n] = {}
    local ps = Store.data().players[op.target]
    local origin = function() return originFor(op, n) end
    local made = op.quests[n]
    local where
    if a.kind == "fetch" then
        local q = Quests.createSite("fetch", ps, op.sites.fetch, now, origin(),
            { deadlineT = op.actDeadlineT, item = a.item, nonResidential = true, search = 150, building = true, tier = 4 })
        if q then made[#made + 1] = q.id end
        where = townOf(op.sites.fetch)
    elseif a.kind == "collect" then
        local mult = (op.fails[n] or 0) > 0 and Ops.RETRY_NEED or 1
        local need = {}
        for i, nd in ipairs(a.need) do need[i] = { nd[1], math.max(1, math.ceil(nd[2] * mult)) } end
        local q = Quests.createCollect(ps, need, now, origin(), op.actDeadlineT)
        made[#made + 1] = q.id
    elseif a.kind == "clear" then
        local size = clearSize(op, n)
        for _, site in ipairs(op.sites.clear) do
            local q = Quests.createSite("horde", ps, site, now, origin(),
                { deadlineT = op.actDeadlineT, size = size, search = 40, tier = 4 })
            if q then made[#made + 1] = q.id end
        end
        where = siteTowns(op.sites.clear)
    elseif a.kind == "defend" then
        local q = Quests.createSite("defend", ps, op.sites.defend, now, origin(),
            { deadlineT = op.actDeadlineT, needMin = a.hours * 60, radius = 20, tier = 5 })
        if q then made[#made + 1] = q.id end
        where = townOf(op.sites.defend)
    elseif a.kind == "visit" then
        local q = Quests.createSite("visit", ps, op.sites.visit, now, origin(),
            { deadlineT = op.actDeadlineT, radius = 10, tier = 3 })
        if q then made[#made + 1] = q.id end
        where = townOf(op.sites.visit)
    end
    if #made == 0 then
        log("ops act could not start", op.kind, n)
        Ops.finish(false, "no_site")
        return false
    end
    local topic = string.format(Ops.TOPIC[op.kind][a.id], tostring(where or ""))
    if retry then
        topic = "The last attempt at this step failed and now it is harder. Ask them to try again. " .. topic
    end
    say(op.lead, topic, retry and "op_retry" or "op_act", ps)
    noteAll("the " .. op.kind .. " repair operation moved on: " .. topic, now)
    spread(op.lead, "The " .. op.kind .. " repair operation: " .. topic)
    notice(retry and "retry" or "act", op)
    pcall(actSupport, op, a, now, retry)
    log("ops act", op.id, op.kind, n, a.id, retry and "retry" or "", #made, "quests")
    return true
end

function Ops.start(kind, why)
    local s = state()
    if s.current then return false, "busy" end
    if not Ops.DEF[kind] then return false, "no_kind" end
    local players = Sensor.players()
    if #players == 0 then return false, "no_players" end
    local now = Sensor.now()
    s.seq = s.seq + 1
    local ax, ay = anchor()
    local clearCount = #players >= 2 and 3 or 2
    local op = {
        id = "OP" .. StoryEngine.intToString(s.seq), kind = kind, state = "active", why = why,
        startT = now.t, startDay = Store.dayIndex(now.dayKey), act = 0,
        lead = Ops.leadOf(kind), target = Store.playerKey(players[1]),
        sites = Ops.pickSites(kind, ax, ay, clearCount), fails = {}, quests = {}, assisted = {},
    }
    s.current = op
    log("ops start", op.id, kind, why or "", "lead", tostring(op.lead))
    noteAll("word went out over the radio that the survivors are going to try to bring the county's "
        .. (kind == "water" and "running water" or "power grid") .. " back", now)
    Ops.startAct(1)
    return true, op
end

-- 개인 모드 (DESIGN_PER_PLAYER_TRUST 5-1절, 2026-10-09 사용자 결정): 막을 끝내면 그 막 퀘스트에 손을 보탠 사람마다
-- 작전을 이끄는 NPC 에게 개인 신뢰 +1 (막마다 한 사람 한 번). 집단 신뢰는 그대로. 싱글·공유 모드는 아무것도 안 함
Ops.HELPER_TRUST = 1

function Ops.rewardHelpers(op, n)
    local Trust = StoryEngine.Trust
    if not Trust or not Trust.personalMode() then return 0 end
    local fid = op.lead
    if not fid or not Factions.byId[fid] or Factions.isGone(fid) then return 0 end
    op.rewarded = op.rewarded or {}
    local done = op.rewarded[n] or {}
    op.rewarded[n] = done
    local count = 0
    for _, qid in ipairs(op.quests[n] or {}) do
        local q = Store.data().quests[qid]
        for key in pairs(q and q.helpers or {}) do
            local ps = Store.data().players[key]
            if not done[key] and ps and not ps.dead then
                done[key] = true
                Trust.addPersonal(fid, key, Ops.HELPER_TRUST, "op_help", qid)
                count = count + 1
            end
        end
    end
    if count > 0 then log("ops act helpers", op.id, n, count) end
    return count
end

function Ops.actDone()
    local op = state().current
    if not op then return end
    local now = Sensor.now()
    local a = act(op)
    log("ops act done", op.id, op.act, a.id)
    Ops.rewardHelpers(op, op.act)
    if a.kind == "defend" then
        -- 파이크가 버틴 사람들을 위로한다
        for _, qid in ipairs(op.quests[op.act] or {}) do
            local q = Store.data().quests[qid]
            for key in pairs(q and q.helpers or {}) do
                local p = playerByKey(key)
                if p then
                    pcall(StoryEngine.Specialty.assist, "pike", p)
                    break
                end
            end
        end
    end
    if op.act >= #Ops.DEF[op.kind].acts then
        Ops.finish(true)
        return
    end
    Ops.startAct(op.act + 1)
end

function Ops.actFailed(why)
    local s = state()
    local op = s.current
    if not op then return end
    local now = Sensor.now()
    local n = op.act
    Quests.cancelOp(op.id, now)
    op.fails[n] = (op.fails[n] or 0) + 1
    log("ops act failed", op.id, n, why or "", "fails", op.fails[n])
    if op.fails[n] >= Ops.MAX_FAILS then
        Ops.finish(false, why)
        return
    end
    Ops.startAct(n, true)
end

-- 작전 퀘스트가 끝났다 (Quests.setState)
function Ops.onQuest(q, outcome)
    local op = state().current
    if not op or q.origin.op ~= op.id or q.origin.act ~= op.act then return end
    if outcome == "failed" then
        Ops.actFailed("quest_failed")
        return
    end
    for _, qid in ipairs(op.quests[op.act] or {}) do
        local other = Store.data().quests[qid]
        if not other or other.state ~= "completed" then
            -- 소탕을 나눠 맡을 때 한 곳씩 끝나면 짧게 알린다
            if q.kind == "horde" then
                say(op.lead, "The players cleared the dead around one of the sites (" .. tostring(q.place and q.place.town)
                    .. "). The others still need doing.", "op_progress", Store.data().players[q.target])
            end
            return
        end
    end
    Ops.actDone()
end

-- 모금에 무언가 보냈다 (Quests.contribute)
function Ops.onContribution(q, ps, gave)
    local op = state().current
    if not op then return end
    local now = Sensor.now()
    if op.thanksT and now.t - op.thanksT < Ops.THANKS_GAP then return end
    op.thanksT = now.t
    say(op.lead, tostring(ps.name) .. " just sent " .. StoryEngine.intToString(gave) .. " of the things you need for the "
        .. op.kind .. " repair. Thank them and say what is still missing: " .. Quests.needText(q) .. " (some already in).",
        "op_thanks", ps)
end

function Ops.finish(success, why)
    local s = state()
    local op = s.current
    if not op then return end
    local now = Sensor.now()
    s.current = nil
    Quests.cancelOp(op.id, now)
    op.state = success and "success" or "failed"
    op.endT = now.t
    Store.push(s.history, { id = op.id, kind = op.kind, result = op.state, day = Store.dayIndex(now.dayKey), why = why }, 20)
    local what = op.kind == "water" and "running water" or "power"
    if success then
        Grid.restore(op.kind, Ops.RESTORE_DAYS, "operation")
        local Life = StoryEngine.Life
        if Life then
            for _, f in ipairs(Factions.list) do
                if not Factions.isGone(f.id) then
                    Life.change(f.id, "morale", 15, "operation")
                    if op.kind == "water" then Life.change(f.id, "food", 10, "operation") end
                    Life.record(f.id, "operation_done", nil, 0)
                end
            end
        end
        say(op.lead, "It worked: the county has " .. what .. " again, for now (the repair should hold about two months). "
            .. "Celebrate with the players and thank them.", "op_done", Store.data().players[op.target])
        noteAll("the survivors got the county's " .. what .. " working again", now)
        spread(op.lead, "The survivors brought the county's " .. what .. " back.")
    else
        s.retryFrom[op.kind] = math.floor(Grid.today())
        local Life = StoryEngine.Life
        if Life then
            for _, f in ipairs(Factions.list) do
                if not Factions.isGone(f.id) then Life.change(f.id, "morale", -10, "operation_failed") end
            end
        end
        say(op.lead, "The " .. op.kind .. " repair failed and had to be abandoned. Tell the players it is over for now; "
            .. "maybe they can try again in a couple of weeks.", "op_failed", Store.data().players[op.target])
        noteAll("the attempt to bring back the county's " .. what .. " failed", now)
        spread(op.lead, "The attempt to bring back the county's " .. what .. " failed.")
    end
    notice(success and "done" or "failed", op)
    log("ops finish", op.id, op.kind, op.state, why or "")
end

-- 60일 복구가 끝나 다시 끊겼다 (Grid.ensure)
function Ops.onGridLost(kind)
    local now = Sensor.now()
    local lead = Ops.leadOf(kind)
    local what = kind == "water" and "running water" or "power"
    say(lead, "The repaired " .. what .. " just failed again; the patch-up did not last. Tell the players.", "op_lost", nil)
    noteAll("the county's " .. what .. " failed again; the repair did not last", now)
    spread(lead, "The county's " .. what .. " failed again.")
end

-- ---------------------------------------------------------------- 10분마다: 방어 무리, NPC 지원

-- 한 번만 하는 지원. 저격처럼 대상이 없어 거절되면 다음 샘플에 다시 (ASSIST_TRIES 번까지)
local function assistOnce(assisted, key, fid, player)
    local tries = assisted[key]
    if tries == true or (tries or 0) >= Ops.ASSIST_TRIES then return end
    local ok, done = pcall(StoryEngine.Specialty.assist, fid, player)
    assisted[key] = (ok and done) and true or ((tries or 0) + 1)
end

local function nearest(players, x, y, radius)
    local best, bestD = nil, radius
    for _, p in ipairs(players) do
        if not p:isDead() then
            local d = dist(p:getX(), p:getY(), x, y)
            if d <= bestD then best, bestD = p, d end
        end
    end
    return best
end

function Ops.tick(entries, now)
    local op = state().current
    if not op or op.act == 0 then return end
    local players = Sensor.players()
    if #players == 0 then return end
    local a = act(op)
    local assisted = op.assisted[op.act]
    for _, p in ipairs(players) do pcall(StoryEngine.Specialty.opScout, p, op.actDeadlineT) end
    for _, qid in ipairs(op.quests[op.act] or {}) do
        local q = Store.data().quests[qid]
        if q and Quests.isActive(q) and (q.kind == "horde" or q.kind == "defend") then
            -- 방위대: 현장에 처음 다가갈 때 한 번
            local near = nearest(players, q.cx, q.cy, Ops.GUARD_DIST)
            if near then assistOnce(assisted, "guard_" .. qid, "guard", near) end
            -- 방어: 머무는 동안 무리가 몰려온다. 첫 무리에 행크, 두 번째에 빅
            if q.kind == "defend" and (q.present or 0) > 0 and now.t >= (q.nextWaveT or 0) then
                local target = nearest(players, q.cx, q.cy, q.radius + 10) or near
                if target then
                    local size = math.max(4, math.floor(StoryEngine.Hunt.sizeNow() * (a.waveShare or 0.4) + 0.5))
                    local angle = ZombRandFloat(0, math.pi * 2)
                    local d = ZombRand(45, 66)
                    StoryEngine.Hunt.start(target, size, q.cx + math.cos(angle) * d, q.cy + math.sin(angle) * d, "operation")
                    q.waves = (q.waves or 0) + 1
                    q.nextWaveT = now.t + (a.wave or 45)
                    log("ops wave", op.id, q.waves, size)
                    if q.waves == 2 then assistOnce(assisted, "rats", "rats", target) end
                end
            end
            -- 행크: 첫 무리가 온 뒤, 쏠 좀비가 가까이 오면
            if q.kind == "defend" and (q.waves or 0) >= 1 and near then assistOnce(assisted, "hunter", "hunter", near) end
        end
    end
    -- 닥: 작전 현장 근처에서 크게 다치면 막마다 한 번
    if assisted.doc ~= true then
        for _, p in ipairs(players) do
            local okH, hp = pcall(function() return p:getBodyDamage():getOverallBodyHealth() end)
            if okH and type(hp) == "number" and hp < Ops.HURT_HEALTH then
                assistOnce(assisted, "doc", "doc", p)
                break
            end
        end
    end
end

-- ---------------------------------------------------------------- 표시

function Ops.statusText()
    local s = state()
    local op = s.current
    local parts = {}
    local today = Grid.today()
    for _, kind in ipairs(Ops.KINDS) do
        local off = Ops.offDay(kind)
        parts[#parts + 1] = kind .. (off and ("=off" .. StoryEngine.intToString(math.floor(today - off)) .. "d "
            .. StoryEngine.intToString(Ops.chance(kind, today)) .. "%") or "=on")
    end
    local text = "ops " .. table.concat(parts, " ")
    if #s.queue > 0 then text = text .. " queue=" .. table.concat(s.queue, ",") end
    if op then
        local left = math.max(0, math.floor((op.actDeadlineT - Sensor.now().t) / 60))
        text = text .. " | " .. op.id .. " " .. op.kind .. " act " .. StoryEngine.intToString(op.act) .. "/"
            .. StoryEngine.intToString(#Ops.DEF[op.kind].acts) .. " " .. act(op).id .. " fails="
            .. StoryEngine.intToString(op.fails[op.act] or 0) .. " " .. StoryEngine.intToString(left) .. "h left"
    end
    local last = s.history[#s.history]
    if last then text = text .. " | last " .. last.id .. " " .. last.kind .. " " .. last.result end
    return text
end

-- 디버그: start(kind) | next(이번 막 끝) | fail(이번 막 실패) | stop(작전 중단)
function Ops.debug(action, kind)
    local s = state()
    if action == "start" then
        if s.current then Ops.finish(false, "debug_replace") end
        return Ops.start(kind == "power" and "power" or "water", "debug")
    end
    local op = s.current
    if not op then return false, "no_operation" end
    if action == "next" then
        local now = Sensor.now()
        for _, qid in ipairs(op.quests[op.act] or {}) do
            local q = Store.data().quests[qid]
            if q and Quests.isActive(q) then
                q.state = "completed"
                q.endedT = now.t
                if q.kind == "fetch" then q.cleanup = true end
            end
        end
        Ops.actDone()
        return true
    elseif action == "fail" then
        Ops.actFailed("debug")
        return true
    elseif action == "stop" then
        Ops.finish(false, "debug")
        return true
    end
    return false, "unknown"
end

Sensor.listeners.tick[#Sensor.listeners.tick + 1] = function(entries, now)
    local ok, err = pcall(Ops.tick, entries, now)
    if not ok then log("ops tick error:", err) end
end

Events.EveryHours.Add(function()
    local ok, err = pcall(Ops.daily, Sensor.now())
    if not ok then log("ops daily error:", err) end
end)

return Ops
