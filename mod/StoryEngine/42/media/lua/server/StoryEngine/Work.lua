-- 물건 대신 다른 대가로 거래하기 (2026-10-04). 거래 제안(trade 퀘스트)에 대가 방식을 고른다.
--
--   일로 갚기 (Work.LABOR, 2026-10-05 개편): 버튼 하나로 받고, 일의 종류는 서버가 무작위로 고른다.
--     소탕(horde) / 경비(guard = defend, 소탕 수의 1.5배를 시간에 나눠) /
--     정찰(scout: 지점 여러 곳, 좀비 있는 건물에 들어가 머물기, 3등급부터 밤에만) /
--     배달 대행(courier: 꾸러미를 찾아(fetch) 다른 건물까지(visit + carry). 챙기면 추적 무리, 다치면 꾸러미 손상, 짧은 기한)
--     찾아오기(fetch)는 정찰과 겹쳐 없앴다 (예전 세이브의 진행 중 찾아오기는 그대로 끝난다).
--     일 퀘스트는 복구 작전처럼 "관리되는 퀘스트"(Quests.isManaged)라 제 보상·신뢰도·반응이 없고, 결과만 거래로 넘긴다.
--     일을 마치면 거래한 물건 + 덤(한 등급 낮은 묶음)을 배송한다. 배달은 꾸러미 상태에 따라 덤·물건이 줄어든다.
--     일이 실패하면 거래도 실패 (대가를 안 낸 것과 같은 감점). 거래 가능한 등급이면 어느 등급이든 일로 갚을 수 있다.
--   외상 (credit): 물건을 먼저 받고 며칠 안에 대가를 낸다 (값 x1.1, 신뢰도 60 이상).
--   빚 (favor): 물건을 그냥 받고(신뢰도 변화 없음), 그 NPC 가 이틀 뒤 부탁을 하나 한다.
--   외상을 못 갚거나 빚 부탁을 거절·무시·실패하면 신뢰도가 크게 떨어지고(Work.DEFAULT_PENALTY, 등급별),
--   그 NPC 와는 2주 동안 외상·빚을 할 수 없다 (Work.BURN_MIN).
--
-- 모든 NPC 가 모든 방식을 받는다 (2026-10-05). 일·외상·빚은 합쳐서 NPC 마다 게임 7일에 Work.PER_WEEK 번.

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Radio"
require "StoryEngine/Quests"
require "StoryEngine/Lines"

local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Radio = StoryEngine.Radio
local Quests = StoryEngine.Quests
local log = StoryEngine.log

local Work = {}
StoryEngine.Work = Work

Work.PER_WEEK = 2
Work.WEEK_MIN = 7 * 24 * 60
Work.LABOR = { horde = true, scout = true, guard = true, courier = true }
Work.LABOR_LIST = { "horde", "scout", "guard", "courier" }
Work.BONUS = { horde = true, scout = true, guard = true, courier = true }   -- 덤을 받는 일 (예전 찾아오기는 없음)
Work.DEFAULT_PENALTY = { 10, 12, 15, 18, 20 }     -- 외상·빚을 안 갚았을 때 등급별 신뢰도 하락 (거래 실패 감점과 별도)
Work.BURN_MIN = 14 * 24 * 60                      -- 그 뒤 그 NPC 와 외상·빚을 못 하는 기간
Work.ORDER = { "labor", "credit", "favor" }       -- 퀘스트 탭 메뉴 순서
Work.ALL = { "horde", "scout", "guard", "courier", "credit", "favor" }
Work.KINDS = {
    ray = Work.ALL, casey = Work.ALL, doc = Work.ALL, pike = Work.ALL,
    dewey = Work.ALL, guard = Work.ALL, rats = Work.ALL, hunter = Work.ALL,
}
Work.CREDIT_TRUST = 60
Work.FAVOR_TRUST = 40
Work.CREDIT_INTEREST = 1.1
Work.CREDIT_DAYS = 14                            -- 외상 상환 기한 (게임 일, 2026-10-04: 2주)
-- 경비 (2026-10-05): 등급별 시간 동안 소탕 수(Quests.HORDE_SIZE)의 GUARD_TOTAL 배를 무리 여러 번에 나눠 보낸다.
-- 정비할 틈이 있어 소탕보다 많다. 무리 수 = 시간 / GUARD_WAVE (올림), 첫 무리는 도착하자마자
Work.GUARD_MIN = { 60, 90, 120, 180, 240 }        -- 등급별 경비 시간 (게임 분)
Work.GUARD_WAVE = 40                              -- 경비 중 무리 간격 (게임 분)
Work.GUARD_TOTAL = 1.5
-- 정찰 (2026-10-05): 지점 수, 지점마다 머물 시간, 건물 안 좀비 = 등급 x SCOUT_ZOMBIES, 3등급부터 밤에만
Work.SCOUT_POINTS = { 2, 2, 3, 3, 4 }
Work.SCOUT_STAY = 20
Work.SCOUT_ZOMBIES = 3
Work.SCOUT_NIGHT_TIER = 3
Work.SCOUT_HOP = { 60, 200 }                      -- 다음 지점까지 거리 (타일)
Work.SCOUT_HOP_HOURS = 12                         -- 지점이 하나 늘 때마다 기한 +
Work.SCOUT_NIGHT_HOURS = 24                       -- 밤에만일 때 기한 +
-- 배달 (2026-10-05): 챙기면 추적 무리 = 지금 추적 무리 크기 x (COURIER_HUNT[1] + COURIER_HUNT[2] x 등급),
-- 기한 x COURIER_DEADLINE, 꾸러미 상태 PARCEL_MAX(150)%에서 다칠 때마다 깎임.
-- 100% 이상이면 덤이 (상태-100)/50 만큼, 100% 미만이면 덤 없이 물건이 상태% 만큼
Work.COURIER_HUNT = { 0.2, 0.15 }
Work.COURIER_DEADLINE = 0.6
Work.PARCEL_MAX = 150
Work.PARCEL_HIT = { scratched = 10, cut = 20, deep = 30, bitten = 30, fracture = 40 }
Work.FAVOR_CALL_MIN = 2 * 24 * 60                 -- 빚을 진 뒤 부탁이 오기까지
Work.FAVOR_EXPIRE_MIN = 14 * 24 * 60              -- 부탁이 끝내 안 오면 빚은 사라진다
Work.PARCEL = "StoryEngine.SealedParcel"
Work.SCOUT_RADIUS = 10
Work.GUARD_RADIUS = 20

local function now() return Sensor.now() end

function Work.isWork(q)
    return q ~= nil and q.origin ~= nil and q.origin.work ~= nil
end

local function has(fid, how)
    for _, k in ipairs(Work.KINDS[fid] or {}) do
        if k == how or (how == "labor" and Work.LABOR[k]) then return true end
    end
    return false
end

-- 이번 주에 이 NPC 와 쓴 횟수 (일·외상·빚 합쳐서)
function Work.weekUsed(fid, t)
    local ch = Radio.channel(fid)
    local kept = {}
    for _, x in ipairs(ch.workLog or {}) do
        if t - x < Work.WEEK_MIN then kept[#kept + 1] = x end
    end
    ch.workLog = kept
    return #kept
end

-- 이 품목을 지금 몇 등급까지 거래할 수 있나 (신뢰도·생활 자원, Trade.offerContext)
function Work.maxTier(fid, category)
    local ctx = StoryEngine.Trade.offerContext(fid, Radio.channel(fid).trust)
    for _, g in ipairs(ctx.allowed and ctx.goods or {}) do
        if g.category == category then return g.maxTier end
    end
    return 0
end

-- 이 방식을 지금 쓸 수 있나. how = "labor"(일로 갚기, 종류는 무작위) | 일 종류 | "credit" | "favor"
-- 반환: true | false, 이유("trust" + 필요 신뢰도 | "week" | "kind" | "gone" | "owed" | "burned")
function Work.check(fid, how, q)
    if not has(fid, how) then return false, "kind" end
    if Factions.isGone(fid) then return false, "gone" end
    local trust = Radio.channel(fid).trust
    if (how == "credit" or how == "favor") and (Radio.channel(fid).workBurnT or 0) > now().t then return false, "burned" end
    if how == "credit" and trust < Work.CREDIT_TRUST then return false, "trust", Work.CREDIT_TRUST end
    if how == "favor" then
        if trust < Work.FAVOR_TRUST then return false, "trust", Work.FAVOR_TRUST end
        if Radio.channel(fid).favorOwed then return false, "owed" end
    end
    if Work.weekUsed(fid, now().t) >= Work.PER_WEEK then return false, "week" end
    return true
end

-- 퀘스트 탭에 보여 줄 방식 목록: 일로 갚기(하나) / 외상 / 빚
function Work.options(q)
    local fid = q.origin and q.origin.faction
    if not fid or not Work.KINDS[fid] then return nil end
    local out = {}
    for _, how in ipairs(Work.ORDER) do
        if has(fid, how) then
            local ok, why, need = Work.check(fid, how, q)
            out[#out + 1] = { how = how, ok = ok or nil, why = why, need = need }
        end
    end
    return out, math.max(0, Work.PER_WEEK - Work.weekUsed(fid, now().t))
end

-- 일로 갚기: 이 NPC 가 받는 일 종류를 무작위 순서로
function Work.laborKinds(fid)
    local list = {}
    for _, k in ipairs(Work.KINDS[fid] or {}) do
        if Work.LABOR[k] then list[#list + 1] = k end
    end
    for i = #list, 2, -1 do
        local j = ZombRand(i) + 1
        list[i], list[j] = list[j], list[i]
    end
    return list
end

local function playerOf(ps)
    for _, p in ipairs(Sensor.players()) do
        if Store.playerKey(p) == ps.key then return p end
    end
    return nil
end

local function nearestPlayer(x, y)
    local best, bestD = nil, nil
    for _, p in ipairs(Sensor.players()) do
        local dx, dy = p:getX() - x, p:getY() - y
        local d = math.sqrt(dx * dx + dy * dy)
        if not bestD or d < bestD then best, bestD = p, d end
    end
    return best, bestD
end

-- 일할 건물: 플레이어(또는 from)에서 거래 등급 거리
local function pickSite(x, y, tier, exclude)
    local found = Quests.findForTier(math.floor(x), math.floor(y), tier, exclude or {})
    if not found then return nil end
    local def = found.def
    return { x = math.floor((def:getX() + def:getX2()) / 2), y = math.floor((def:getY() + def:getY2()) / 2) },
        found.distance, found.key
end

local function childOrigin(trade, how, stage)
    return { source = "work", faction = trade.origin.faction, initiator = "npc", work = trade.id, workKind = how,
             stage = stage, volunteer = trade.kind == "volunteer" or nil }
end

-- 정찰 다음 지점들: 앞 지점에서 SCOUT_HOP 거리의 다른 건물
local function scoutHops(first, count, exclude)
    local out, from = {}, first
    for _ = 2, count do
        local keep = StoryEngine.Danger and StoryEngine.Danger.KEEP_QUEST or nil
        local found = Quests.findBuilding(from.x, from.y, Work.SCOUT_HOP[1], Work.SCOUT_HOP[2], exclude, nil, keep)
            or Quests.findBuilding(from.x, from.y, Work.SCOUT_HOP[2], Work.SCOUT_HOP[2] * 2, exclude, nil, keep)
            or Quests.findBuilding(from.x, from.y, Work.SCOUT_HOP[1], Work.SCOUT_HOP[2] * 2, exclude)
        if not found then break end
        exclude[found.key] = true
        local def = found.def
        local site = { x = math.floor((def:getX() + def:getX2()) / 2), y = math.floor((def:getY() + def:getY2()) / 2) }
        out[#out + 1] = site
        from = site
    end
    return out
end

-- 경비 무리: 소탕 수의 GUARD_TOTAL 배를 시간 안의 무리 수로 나눈다
function Work.guardPlan(tier)
    local total = Quests.zombieCount(Quests.HORDE_SIZE[tier] * Work.GUARD_TOTAL)
    local waves = math.max(1, math.ceil(Work.GUARD_MIN[tier] / Work.GUARD_WAVE))
    return math.max(1, math.ceil(total / waves)), waves, total
end

-- 일 퀘스트를 만든다. 반환: 퀘스트 | nil, 이유
function Work.startLabor(trade, how, player, ps, t)
    local tier = math.max(1, math.min(Quests.MAX_TIER, trade.tier or 1))
    local exclude = {}
    if ps.home and ps.home.building then exclude[ps.home.building] = true end
    local site, distance, key = pickSite(player:getX(), player:getY(), tier, exclude)
    if not site then return nil, "no_building" end
    if key then exclude[key] = true end
    local deadline = t.t + Quests.deadlineMinutes(distance)
    local opts = { tier = tier, building = true, search = 12, deadlineT = deadline }
    local kind = how
    if how == "horde" then
        opts.size = Quests.HORDE_SIZE[tier]
    elseif how == "fetch" then
        opts.item = Quests.FETCH_ITEMS[ZombRand(#Quests.FETCH_ITEMS) + 1]
    elseif how == "scout" then
        opts.radius = Work.SCOUT_RADIUS
        opts.more = scoutHops(site, Work.SCOUT_POINTS[tier], exclude)
        opts.stayMin = Work.SCOUT_STAY
        opts.zombies = tier * Work.SCOUT_ZOMBIES
        opts.night = tier >= Work.SCOUT_NIGHT_TIER or nil
        opts.deadlineT = deadline + #opts.more * Work.SCOUT_HOP_HOURS * 60
            + (opts.night and Work.SCOUT_NIGHT_HOURS * 60 or 0)
    elseif how == "guard" then
        kind = "defend"
        opts.needMin = Work.GUARD_MIN[tier]
        opts.radius = Work.GUARD_RADIUS
        opts.deadlineT = deadline + opts.needMin
    elseif how == "courier" then
        kind = "fetch"
        opts.item = Work.PARCEL
        opts.deadlineT = t.t + math.floor(Quests.deadlineMinutes(distance) * Work.COURIER_DEADLINE)
    end
    local q, why = Quests.createSite(kind, ps, site, t, childOrigin(trade, how, how == "courier" and "pickup" or nil), opts)
    if not q then return nil, why end
    q.tier, q.distance, q.siteKey = tier, math.floor(distance or 0), key
    if how == "guard" then q.waveSize, q.wavesMax = Work.guardPlan(tier) end
    return q
end

-- 배달 대행 2단계: 꾸러미를 챙겼으면 배달할 건물을 정하고, 꾸러미를 가진 사람에게 추적 무리를 붙인다
local function startDropoff(trade, pickup, t, carrier)
    local ps = Store.data().players[trade.target] or {}
    local site, distance = pickSite(pickup.cx, pickup.cy, math.max(1, (trade.tier or 1) - 1), { [pickup.building or ""] = true })
    if not site then return nil end
    local q = Quests.createSite("visit", ps.key and ps or nil, site, t, childOrigin(trade, "courier", "dropoff"),
        { tier = trade.tier, building = true, search = 12, radius = Work.SCOUT_RADIUS,
          deadlineT = t.t + math.floor(Quests.deadlineMinutes(distance) * Work.COURIER_DEADLINE) })
    if not q then return nil end
    q.carry = { qid = pickup.id, items = { Work.PARCEL } }
    q.parcel = Work.PARCEL_MAX
    q.distance = math.floor(distance or 0)
    trade.workId = q.id
    trade.deadlineT = q.deadlineT + 24 * 60
    log("work courier dropoff", trade.id, q.id, "from", pickup.id)
    q.helpers = q.helpers or {}
    for k, v in pairs(pickup.helpers or {}) do q.helpers[k] = v end
    Work.say(q, "courier_pickup", function(p) return where(q, p) end, "Got the parcel. Take it on.")
    local Hunt = StoryEngine.Hunt
    if carrier and Hunt then
        local tier = math.max(1, math.min(Quests.MAX_TIER, trade.tier or 1))
        local size = math.max(4, math.floor(Hunt.sizeNow() * (Work.COURIER_HUNT[1] + Work.COURIER_HUNT[2] * tier) + 0.5))
        local ok, err = pcall(Hunt.sendAt, carrier, "work_courier", size)
        if ok then q.hunted = size else log("work courier hunt error:", err) end
        log("work courier hunt", q.id, size)
    end
    return q
end

-- 꾸러미를 가진 플레이어인가 (배달 2단계)
local function holdsParcel(player, q)
    if not player or not q.carry then return false end
    return #Quests.findInInventory(player, { items = q.carry.items, id = q.carry.qid }) > 0
end

-- 목록에서 가치 share 만큼만 남긴다 (앞에서부터, 넘치는 것은 건너뛰고 더 싼 것을 계속 본다)
function Work.trim(list, share)
    if share >= 1 then return list end
    local Value = StoryEngine.Value
    local total = 0
    for _, ft in ipairs(list) do total = total + (Value.of(ft) or 0) end
    local budget, out, used = total * math.max(0, share), {}, 0
    for _, ft in ipairs(list) do
        local v = Value.of(ft) or 0
        if used + v <= budget + 0.001 then
            out[#out + 1] = ft
            used = used + v
        end
    end
    return out
end

-- 일로 갚을 때 더 받는 묶음 (한 등급 낮은 같은 품목)
function Work.bonusGoods(trade)
    local Trade = StoryEngine.Trade
    local fid = trade.origin and trade.origin.faction
    local ok, extra = pcall(Trade.rollFresh, trade.category, math.max(1, (trade.tier or 1) - 1), fid)
    return ok and extra or {}
end

local function deliver(trade, player, ps, goods, t)
    local distanceTier = (trade.tier or 1) <= 2 and 1 or 2
    return Quests.create("supply_drop", player, ps, distanceTier, t,
        { source = "reward", faction = trade.origin and trade.origin.faction, rewardFor = trade.id, rewardKind = "trade" }, goods)
end

local function where(q, player)
    local town, code, distance = Quests.whereFrom(q, player)
    return { { t = "town", v = q.place and q.place.town or town }, { t = "dir", v = code }, { t = "num", v = distance } }
end

local DIR_CODES = { "E", "SE", "S", "SW", "W", "NW", "N", "NE" }
local function dirCode(dx, dy)
    local angle = math.atan2(dy, dx) * 180 / math.pi
    return DIR_CODES[math.floor(((angle + 360 + 22.5) % 360) / 45) + 1]
end

-- ---------------------------------------------------------------- 진행 무전 (2026-10-05)
-- 일하는 사람 머리 위에 짧은 진행 소식 (퀘스트 창을 열지 않아도 되게). AI 를 쓰지 않는 준비된 문장
-- (IGUI_StoryEngine_WorkNote_<key>), 무전 기록에는 남기지 않는다. 받는 사람: 거래한 사람 + 일에 손을 보탠 사람(접속 중)
-- args = 인자 목록 또는 function(player) -> 인자 목록 (방향처럼 사람마다 다른 것)
function Work.say(q, key, args, english)
    local trade = Store.data().quests[q.origin.work]
    local keys = {}
    if trade and trade.target then keys[trade.target] = true end
    if q.target then keys[q.target] = true end
    for k, _ in pairs(q.helpers or {}) do keys[k] = true end
    local fid = q.origin.faction
    for _, p in ipairs(Sensor.players()) do
        local ps = Store.player(p)
        if keys[ps.key] then
            local a = type(args) == "function" and args(p) or args
            Radio.overhead(ps.key, fid, english or "", { key = "IGUI_StoryEngine_WorkNote_" .. key, args = a or {} })
        end
    end
    log("work note", q.id, key)
end

local function num(v) return { t = "num", v = math.floor(v or 0) } end

Quests.progressHooks[#Quests.progressHooks + 1] = function(q, event, info)
    if not Work.isWork(q) then return end
    if event == "kill" then
        local step = math.floor((q.killed or 0) * 4 / math.max(1, q.killsNeeded or 1)) * 25
        if step >= 25 and step < 100 and step > (q.notedPct or 0) then
            q.notedPct = step
            Work.say(q, "horde", { num(q.killed), num(q.killsNeeded) }, "Clearing: " .. tostring(q.killed) .. " down.")
        end
    elseif event == "scout_entered" then
        Work.say(q, "scout_entered", { num(q.stayMin) }, "Inside. Stay around a while.")
    elseif event == "scout_enter" then
        Work.say(q, "scout_enter", {}, "Now go inside the building.")
    elseif event == "scout_night" then
        Work.say(q, "scout_night", {}, "Wait for nightfall.")
    elseif event == "scout_next" then
        Work.say(q, "scout_next", function(p)
            local w = where(q, p)
            return { num(info.done), num(#(q.points or {})), w[1], w[2], w[3] }
        end, "Next point.")
    elseif event == "defend_pct" then
        Work.say(q, "guard_pct", { num(info.pct), num(info.left) }, "Holding.")
    end
end

local TOPIC = {
    horde = "they will clear out a pack of the dead around a building for you instead",
    fetch = "they will retrieve a sealed package from a building for you instead",
    scout = "they will scout several buildings for you instead: go inside each one (the dead are in there) and watch it for a while",
    guard = "they will stand guard at a building for you for a while instead, and packs of the dead will come",
    courier = "they will pick up a fragile parcel and carry it to another building for you instead, quickly; the dead will follow the carrier",
    credit = "you let them take the goods now and pay later, a little extra for the trouble",
    favor = "you let them have it now for nothing, but they owe you a favor and you will call it in soon",
}

-- 거래 제안에 대가 방식을 고른다. 반환: true, 정해진 방식 | false, 이유
-- force = 일 종류 고정 (테스트·디버그용, 클라이언트 명령은 넘기지 않는다)
function Work.choose(player, qid, how, force)
    local q = Store.data().quests[qid]
    if not q or q.kind ~= "trade" then return false, "no_quest" end
    if not (q.state == "proposed" or (q.state == "accepted" and not q.payKind)) then return false, "not_open" end
    if not Factions.canTalk(player) then return false, "no_radio" end
    local fid = q.origin and q.origin.faction
    local ok, why = Work.check(fid, how, q)
    if not ok then return false, why end
    local ps = Store.player(player)
    local t = now()
    local child = nil
    if how == "labor" or Work.LABOR[how] then
        -- 일로 갚기: 종류는 서버가 무작위로 (건물을 못 찾으면 다른 종류로). 고른 뒤에는 바꿀 수 없다
        why = "no_building"
        for _, kind in ipairs(force and { force } or Work.laborKinds(fid)) do
            child, why = Work.startLabor(q, kind, player, ps, t)
            if child then
                how = kind
                break
            end
        end
        if not child then return false, why or "no_building" end
    end
    if q.state == "proposed" then Quests.respond(player, qid, true) end
    q.target, q.targetName = ps.key, ps.name
    q.payKind = how
    local ch = Radio.channel(fid)
    ch.workLog = ch.workLog or {}
    ch.workLog[#ch.workLog + 1] = t.t
    local Lines = StoryEngine.Lines
    local topic = ps.name .. " agreed to the trade, but instead of paying with goods " .. TOPIC[how] .. "."
    if child then
        q.workId = child.id
        q.deadlineT = child.deadlineT + 24 * 60
        Radio.react(fid, "event", topic .. " Tell them briefly where (from them): it is in the quest log.",
            Lines.fallback(fid, "work_" .. how, "Do this for me and the goods are yours.", where(child, player)), ps,
            { overhead = true })
    elseif how == "credit" then
        q.credit = true
        q.price = math.ceil((q.price or 0) * Work.CREDIT_INTEREST)
        local days = Work.CREDIT_DAYS
        q.deadlineT = t.t + days * 24 * 60
        q.delivered = (deliver(q, player, ps, q.goods, t) or {}).id
        StoryEngine.Trade.markSold(fid, q.stockRef)
        Radio.react(fid, "event", topic .. " They must pay " .. StoryEngine.intToString(q.price) .. " within "
            .. StoryEngine.intToString(days) .. " days.",
            Lines.fallback(fid, "work_credit", "Take it now. Pay me within a few days.", { { t = "num", v = days } }), ps)
    elseif how == "favor" then
        q.favor, q.noTrust = true, true
        q.delivered = (deliver(q, player, ps, q.goods, t) or {}).id
        ch.favorOwed = { qid = q.id, key = ps.key, name = ps.name, sinceT = t.t, tier = q.tier or 1 }
        Quests.setState(q, "completed", t, { ps = ps })
        Radio.react(fid, "event", topic, Lines.fallback(fid, "work_favor", "Take it. You owe me one."), ps)
    end
    log("work chosen", q.id, fid, how, child and child.id or "", "by", ps.name)
    Quests.notify(q)
    return true, how
end

-- 일 퀘스트·거래·빚 부탁의 상태가 바뀌었다 (Quests 의 setState 끝에서 부른다)
function Work.onState(q, state, outcome, trustDelta)
    local t = now()
    if Work.isWork(q) then return Work.onChild(q, state, t) end
    if q.kind == "trade" and (state == "failed" or state == "declined") then
        -- 일하는 중에 거래가 끝났으면 일 퀘스트도 거둔다
        local child = q.workId and Store.data().quests[q.workId]
        if child and Quests.isActive(child) then
            child.state, child.endedT = "failed", t.t
            child.cleanup = true
        end
        if state == "failed" and q.credit then Work.default(q, "credit_default", t) end
    end
    if q.favorCall and (state == "completed" or state == "declined" or state == "failed") then
        local ch = Radio.channel(q.origin.faction)
        if state ~= "completed" then Work.default(q, "favor_broken", t) end
        ch.favorOwed = nil
        log("work favor settled", q.id, state)
    end
end

-- 외상·빚을 안 갚음: 등급별로 크게 깎고, 2주 동안 외상·빚 금지
function Work.default(q, reason, t)
    local fid = q.origin.faction
    local tier = math.max(1, math.min(#Work.DEFAULT_PENALTY, q.tier or 1))
    StoryEngine.Trust.apply(fid, -Work.DEFAULT_PENALTY[tier], reason, q.id, q.target)
    Radio.channel(fid).workBurnT = t.t + Work.BURN_MIN
    log("work default", fid, q.id, reason, -Work.DEFAULT_PENALTY[tier])
end

function Work.onChild(q, state, t)
    local trade = Store.data().quests[q.origin.work]
    if not trade or trade.state ~= "accepted" then return end
    local how = q.origin.workKind
    if trade.kind == "volunteer" and (state == "completed" or state == "failed")
        and not (state == "completed" and how == "courier" and q.origin.stage == "pickup") then
        return Work.volunteerEnd(trade, q, state, t)
    end
    if state == "retrieved" and how == "courier" then
        -- 꾸러미를 챙겼다: 회수 퀘스트는 끝내고 배달지로
        Quests.setState(q, "completed", t, nil)
        return
    end
    if state == "completed" and how == "courier" and q.origin.stage == "pickup" then
        local carrier = nil
        for _, p in ipairs(Sensor.players()) do
            if not carrier and #Quests.findInInventory(p, q) > 0 then carrier = p end
        end
        carrier = carrier or nearestPlayer(q.sx or q.cx or 0, q.sy or q.cy or 0)
        if not startDropoff(trade, q, t, carrier) then
            Quests.setState(trade, "failed", t, nil)
        end
        Quests.notify(trade)
        return
    end
    if state == "completed" then
        local player = nearestPlayer(q.cx or 0, q.cy or 0)
        local ps = player and Store.player(player) or Store.data().players[trade.target]
        local base = {}
        for _, g in ipairs(trade.goods or {}) do base[#base + 1] = g end
        local bonus = Work.BONUS[how] and Work.bonusGoods(trade) or {}
        if q.parcel then
            -- 배달: 꾸러미 상태 100% 이상이면 덤이 줄고, 그 아래면 덤 없이 물건이 준다
            local cond = math.max(0, math.min(Work.PARCEL_MAX, q.parcel))
            if cond >= 100 then
                bonus = Work.trim(bonus, (cond - 100) / (Work.PARCEL_MAX - 100))
            else
                bonus = {}
                base = Work.trim(base, cond / 100)
            end
            trade.parcel = cond
        end
        local goods = {}
        for _, g in ipairs(base) do goods[#goods + 1] = g end
        for _, g in ipairs(bonus) do goods[#goods + 1] = g end
        trade.workBonus = #bonus > 0 and bonus or nil
        if player and #goods > 0 then trade.delivered = (deliver(trade, player, ps, goods, t) or {}).id end
        if q.parcel and q.parcel < 100 then trade.goodsKept = base end
        Quests.setState(trade, "completed", t, ps and { ps = ps } or nil)
        local fid = trade.origin.faction
        local extra = #bonus > 0 and " plus a little extra for the hard work" or ""
        if q.parcel and q.parcel < 100 then
            extra = ", but the parcel arrived damaged so you sent less than agreed"
        elseif q.parcel and q.parcel < Work.PARCEL_MAX then
            extra = extra .. " (less extra: the parcel got knocked about)"
        end
        Radio.react(fid, "event", "The players finished the work they did instead of paying (" .. tostring(how)
            .. "). You sent the goods" .. extra .. "; the drop location comes in a separate call.",
            StoryEngine.Lines.fallback(fid, #bonus > 0 and "work_done" or "work_paid", "Good work. The goods are on the way."), ps,
            { overhead = true })
        log("work done", trade.id, how, "bonus", #bonus)
    elseif state == "failed" then
        Quests.setState(trade, "failed", t, nil)
        log("work failed", trade.id, how)
    end
end

-- ---------------------------------------------------------------- 일거리 청하기 (2026-10-06)
-- 거점 탭 [일거리 청하기]: 보수 없이 그 NPC 의 일을 해 주고 신뢰도를 얻는다. 일의 종류는 무작위(소탕·정찰·경비·배달),
-- 등급은 그 NPC 의 지금 신뢰도(VOLUNTEER_BANDS)와 진행 단계 상한 중 낮은 쪽. 완료하면 신뢰도 +등급 x 2,
-- 그 NPC 핵심 자원 +등급 x 10, 실패하면 신뢰도 -등급. NPC 마다 게임 7일에 두 번(서버 전체), 동시에 하나.
-- 일 퀘스트의 부모는 kind = "volunteer" 인 숨은 퀘스트 (위치·목록 없음, Quests.isManaged)
Work.VOLUNTEER_PER_WEEK = 2
Work.VOLUNTEER_TRUST = 2
Work.VOLUNTEER_LIFE = 10
Work.VOLUNTEER_BANDS = { 20, 40, 60, 80 }

function Work.volunteerTier(fid)
    local trust = Radio.channel(fid).trust
    local tier = 1
    for i, b in ipairs(Work.VOLUNTEER_BANDS) do
        if trust >= b then tier = i + 1 end
    end
    local cap = Store.STAGE_MAX_TIER[Store.stage()] or Quests.MAX_TIER
    return math.max(1, math.min(tier, cap, Quests.MAX_TIER))
end

function Work.volunteerUsed(fid, t)
    local ch = Radio.channel(fid)
    local kept = {}
    for _, x in ipairs(ch.volunteerLog or {}) do
        if t - x < Work.WEEK_MIN then kept[#kept + 1] = x end
    end
    ch.volunteerLog = kept
    return #kept
end

local function openVolunteer(fid)
    for _, q in pairs(Store.data().quests) do
        if q.kind == "volunteer" and q.origin and q.origin.faction == fid and q.state == "accepted" then return q end
    end
    return nil
end

-- 지금 일거리를 청할 수 있나 (거점 탭 버튼). 반환 { ok, why, tier, gain, left }
function Work.volunteerStatus(fid)
    local t = now().t
    local tier = Work.volunteerTier(fid)
    local out = { tier = tier, gain = tier * Work.VOLUNTEER_TRUST,
                  left = math.max(0, Work.VOLUNTEER_PER_WEEK - Work.volunteerUsed(fid, t)) }
    if Factions.isGone(fid) then out.why = "gone"
    elseif openVolunteer(fid) then out.why = "open"
    elseif out.left <= 0 then out.why = "week" end
    out.ok = out.why == nil or nil
    return out
end

function Work.volunteer(player, fid, force)
    if not Factions.byId[fid] then return false, "no_faction" end
    if not Factions.canTalk(player) then return false, "no_radio" end
    local st = Work.volunteerStatus(fid)
    if not st.ok then return false, st.why end
    local ps = Store.player(player)
    local t = now()
    local d = Store.data()
    d.questSeq = (d.questSeq or 0) + 1
    local parent = { id = "Q" .. StoryEngine.intToString(d.questSeq), kind = "volunteer", state = "accepted",
                     tier = st.tier, gain = st.gain, target = ps.key, targetName = ps.name, createdT = t.t,
                     deadlineT = t.t, origin = { source = "volunteer", faction = fid, initiator = "player" },
                     history = { { state = "accepted", t = t.t, by = ps.name } } }
    d.quests[parent.id] = parent
    local child, why = nil, "no_building"
    for _, kind in ipairs(force and { force } or Work.laborKinds(fid)) do
        child, why = Work.startLabor(parent, kind, player, ps, t)
        if child then
            parent.payKind = kind
            break
        end
    end
    if not child then
        d.quests[parent.id] = nil
        return false, why or "no_building"
    end
    parent.workId = child.id
    parent.deadlineT = child.deadlineT + 24 * 60
    local ch = Radio.channel(fid)
    ch.volunteerLog = ch.volunteerLog or {}
    ch.volunteerLog[#ch.volunteerLog + 1] = t.t
    Radio.react(fid, "event", ps.name .. " offered to help you for nothing, just to earn your trust. You gave them a job: "
        .. (TOPIC[parent.payKind] or "some work"):gsub(" instead", "") .. ". Tell them briefly where (from them): it is in the quest log. "
        .. "You cannot pay for it and you say so; you are grateful.",
        StoryEngine.Lines.fallback(fid, "volunteer_ask", "No pay, but it would mean a lot.", where(child, player)), ps,
        { overhead = true })
    log("volunteer", parent.id, fid, parent.payKind, "tier", parent.tier, child.id, "by", ps.name)
    Quests.notify(child)
    return true, parent.payKind
end

function Work.volunteerEnd(parent, q, state, t)
    local fid = parent.origin.faction
    local tier = math.max(1, math.min(Quests.MAX_TIER, parent.tier or 1))
    local player = nearestPlayer(q.cx or 0, q.cy or 0)
    local ps = player and Store.player(player) or Store.data().players[parent.target]
    Quests.setState(parent, state, t, ps and { ps = ps } or nil)
    local Life = StoryEngine.Life
    if state == "completed" then
        local gain = StoryEngine.Trust.apply(fid, tier * Work.VOLUNTEER_TRUST, "volunteer_done", parent.id, parent.target)
        if Life then
            Life.change(fid, Life.KEY[fid], tier * Work.VOLUNTEER_LIFE, "volunteer")
            Life.record(fid, "volunteer", ps and ps.name or parent.targetName, gain)
        end
        Radio.react(fid, "event", "The players did the job you gave them (" .. tostring(parent.payKind)
            .. ") without asking anything in return. Thank them warmly; you have nothing to give but your trust.",
            StoryEngine.Lines.fallback(fid, "volunteer_done", "You did it for nothing. I won't forget it."), ps,
            { overhead = true })
        log("volunteer done", parent.id, fid, "trust", gain)
    else
        local loss = StoryEngine.Trust.apply(fid, -tier, "volunteer_failed", parent.id, parent.target)
        if Life then Life.record(fid, "volunteer_failed", ps and ps.name or parent.targetName, loss) end
        log("volunteer failed", parent.id, fid, "trust", loss)
    end
end

-- 경비 무리 크기 (예전 세이브의 경비 퀘스트는 waveSize 가 없어 등급으로 다시 계산)
local function guardWave(q)
    if not q.waveSize then
        local tier = math.max(1, math.min(Quests.MAX_TIER, q.tier or 1))
        q.waveSize, q.wavesMax = Work.guardPlan(tier)
    end
    return q.waveSize, q.wavesMax
end

-- 배달 중 꾸러미를 가진 사람이 다치면 꾸러미가 상한다
function Work.parcelHarm(entries)
    for _, q in pairs(Store.data().quests) do
        if Work.isWork(q) and q.carry and q.parcel and Quests.isActive(q) then
            for _, e in ipairs(entries) do
                if #(e.newHarm or {}) > 0 and holdsParcel(e.player, q) then
                    local hit = 0
                    for _, h in ipairs(e.newHarm) do hit = hit + (Work.PARCEL_HIT[h.kind] or 10) end
                    q.parcel = math.max(0, q.parcel - hit)
                    log("work parcel damaged", q.id, "-" .. StoryEngine.intToString(hit), "now", q.parcel)
                    Work.say(q, q.parcel >= 100 and "parcel" or "parcel_low", { num(q.parcel) }, "The parcel got damaged.")
                    Quests.notify(q)
                end
            end
        end
    end
end

-- 게임 내 10분마다 (Sensor tick): 경비 중 무리, 꾸러미 손상, 빚 부탁 걸기
function Work.tick(entries, t)
    local players = Sensor.players()
    if #players == 0 then return end
    for _, q in pairs(Store.data().quests) do
        if Work.isWork(q) and q.kind == "defend" and Quests.isActive(q) and (q.present or 0) > 0
            and t.t >= (q.nextWaveT or 0) then
            local size, most = guardWave(q)
            local target = nearestPlayer(q.cx, q.cy)
            if target and StoryEngine.Hunt and (q.waves or 0) < most then
                local angle = ZombRandFloat(0, math.pi * 2)
                local d = ZombRand(45, 66)
                StoryEngine.Hunt.start(target, size, q.cx + math.cos(angle) * d, q.cy + math.sin(angle) * d, "work_guard")
                Work.say(q, "guard_wave", { num((q.waves or 0) + 1), num(most), num(size),
                    { t = "dir", v = dirCode(math.cos(angle), math.sin(angle)) } }, "A pack is coming.")
                q.waves = (q.waves or 0) + 1
                q.nextWaveT = t.t + Work.GUARD_WAVE
                log("work guard wave", q.id, q.waves, "/", most, size)
            end
        end
    end
    Work.parcelHarm(entries)
    Work.callFavors(t)
end

local function openFrom(fid)
    for _, q in pairs(Store.data().quests) do
        if q.origin and q.origin.faction == fid and (q.state == "proposed" or Quests.isActive(q))
            and (q.kind == "deliver" or q.kind == "horde") then
            return true
        end
    end
    return false
end

-- 빚을 진 지 이틀이 지나면 그 NPC 가 부탁을 한다 (빚진 사람이 접속해 있으면 그 사람에게)
function Work.callFavors(t)
    for _, f in ipairs(Factions.list) do
        local ch = Radio.channel(f.id)
        local owed = ch.favorOwed
        if owed and not owed.called then
            if Factions.isGone(f.id) or t.t - owed.sinceT >= Work.FAVOR_EXPIRE_MIN then
                ch.favorOwed = nil
            elseif t.t - owed.sinceT >= Work.FAVOR_CALL_MIN and not openFrom(f.id) then
                local player = nil
                for _, p in ipairs(Sensor.players()) do
                    if Store.playerKey(p) == owed.key then player = p end
                end
                player = player or Sensor.players()[1]
                if player then
                    local q = Quests.propose(player, Store.player(player), f.id, owed.tier or 1, t, { favor = owed.name })
                    if q then
                        owed.called = q.id
                        log("work favor called", f.id, q.id, "owed by", owed.name)
                    end
                end
            end
        end
    end
end

function Work.statusText()
    local parts = {}
    for _, f in ipairs(Factions.list) do
        local ch = Radio.channel(f.id)
        local used = Work.weekUsed(f.id, now().t)
        if used > 0 or ch.favorOwed then
            parts[#parts + 1] = f.id .. ":" .. StoryEngine.intToString(used) .. "/" .. StoryEngine.intToString(Work.PER_WEEK)
                .. (ch.favorOwed and (" owed=" .. tostring(ch.favorOwed.name) .. (ch.favorOwed.called and "*" or "")) or "")
        end
    end
    return "work " .. (#parts > 0 and table.concat(parts, " ") or "none")
end

Sensor.listeners.tick[#Sensor.listeners.tick + 1] = function(entries, t)
    local ok, err = pcall(Work.tick, entries, t)
    if not ok then log("work tick error:", err) end
end

return Work
