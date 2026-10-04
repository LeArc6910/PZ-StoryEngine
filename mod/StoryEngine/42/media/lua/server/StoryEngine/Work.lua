-- 물건 대신 다른 대가로 거래하기 (2026-10-04). 거래 제안(trade 퀘스트)에 대가 방식을 고른다.
--
--   일로 갚기 (Work.LABOR): 소탕(horde) / 찾아오기(fetch) / 정찰(scout = visit) / 경비(guard = defend) /
--                          배달 대행(courier = 꾸러미를 찾아(fetch) 다른 건물까지 가져가기(visit + carry))
--     일 퀘스트는 복구 작전처럼 "관리되는 퀘스트"(Quests.isManaged)라 제 보상·신뢰도·반응이 없고, 결과만 거래로 넘긴다.
--     일을 마치면 거래한 물건을 배송한다. 소탕·경비(Work.BONUS)는 한 등급 낮은 묶음을 하나 더 얹고,
--     쉬운 찾아오기·정찰·배달은 물건만 (사용자 결정 2026-10-04).
--     일이 실패하면 거래도 실패 (대가를 안 낸 것과 같은 감점).
--   외상 (credit): 물건을 먼저 받고 며칠 안에 대가를 낸다 (값 x1.1, 신뢰도 60 이상).
--   빚 (favor): 물건을 그냥 받고(신뢰도 변화 없음), 그 NPC 가 이틀 뒤 부탁을 하나 한다.
--   외상을 못 갚거나 빚 부탁을 거절·무시·실패하면 신뢰도가 크게 떨어지고(Work.DEFAULT_PENALTY, 등급별),
--   그 NPC 와는 2주 동안 외상·빚을 할 수 없다 (Work.BURN_MIN).
--
-- NPC 마다 어떤 방식을 받는지는 Work.KINDS (성격에 맞춰). 일·외상·빚은 합쳐서 NPC 마다 게임 7일에 Work.PER_WEEK 번.

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
Work.LABOR = { horde = true, fetch = true, scout = true, guard = true, courier = true }
Work.BONUS = { horde = true, guard = true }       -- 덤을 받는 일 (나머지는 물건만)
-- 쉬운 일(찾아오기·정찰·배달)은 그 품목의 지금 거래 가능 최고 등급보다 한 등급 아래 거래에서만 (2026-10-04 사용자 결정)
Work.EASY = { fetch = true, scout = true, courier = true }
Work.DEFAULT_PENALTY = { 10, 12, 15, 18, 20 }     -- 외상·빚을 안 갚았을 때 등급별 신뢰도 하락 (거래 실패 감점과 별도)
Work.BURN_MIN = 14 * 24 * 60                      -- 그 뒤 그 NPC 와 외상·빚을 못 하는 기간
Work.ORDER = { "horde", "fetch", "scout", "guard", "courier", "credit", "favor" }
Work.KINDS = {
    ray = { "fetch", "courier", "credit", "favor" },
    casey = { "scout", "fetch", "courier", "credit" },
    doc = { "courier", "fetch", "credit" },
    pike = { "guard", "courier", "favor" },
    dewey = { "fetch", "scout", "credit", "favor" },
    guard = { "horde", "guard", "scout", "favor" },
    rats = { "fetch", "horde", "courier", "credit", "favor" },
    hunter = { "horde", "scout", "favor" },
}
Work.CREDIT_TRUST = 60
Work.FAVOR_TRUST = 40
Work.CREDIT_INTEREST = 1.1
Work.CREDIT_DAYS = 14                            -- 외상 상환 기한 (게임 일, 2026-10-04: 2주)
Work.GUARD_MIN = { 60, 90, 120, 180, 240 }        -- 등급별 경비 시간 (게임 분)
Work.GUARD_WAVE = 40                              -- 경비 중 무리 간격 (게임 분)
Work.GUARD_SHARE = 0.3                            -- 무리 크기 = 지금 추적 무리 크기 x 이 값 (최소 4)
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
        if k == how then return true end
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

-- 이 방식을 지금 쓸 수 있나. q = 거래 (쉬운 일의 등급 제한에 쓴다)
-- 반환: true | false, 이유("trust" + 필요 신뢰도 | "tier" + 가능한 최고 등급 | "week" | "kind" | "gone" | "owed" | "burned")
function Work.check(fid, how, q)
    if not has(fid, how) then return false, "kind" end
    if Work.EASY[how] and q then
        local top = Work.maxTier(fid, q.category) - 1
        if (q.tier or 1) > top then return false, "tier", math.max(0, top) end
    end
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

-- 퀘스트 탭에 보여 줄 방식 목록
function Work.options(q)
    local fid = q.origin and q.origin.faction
    if not fid or not Work.KINDS[fid] then return nil end
    local out = {}
    for _, how in ipairs(Work.KINDS[fid]) do
        local ok, why, need = Work.check(fid, how, q)
        out[#out + 1] = { how = how, ok = ok or nil, why = why, need = need }
    end
    return out, math.max(0, Work.PER_WEEK - Work.weekUsed(fid, now().t))
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
             stage = stage }
end

-- 일 퀘스트를 만든다. 반환: 퀘스트 | nil, 이유
function Work.startLabor(trade, how, player, ps, t)
    local tier = math.max(1, math.min(Quests.MAX_TIER, trade.tier or 1))
    local exclude = {}
    if ps.home and ps.home.building then exclude[ps.home.building] = true end
    local site, distance, key = pickSite(player:getX(), player:getY(), tier, exclude)
    if not site then return nil, "no_building" end
    local deadline = t.t + Quests.deadlineMinutes(distance)
    local opts = { tier = tier, building = true, search = 12, deadlineT = deadline }
    local kind = how
    if how == "horde" then
        opts.size = Quests.HORDE_SIZE[tier]
    elseif how == "fetch" then
        opts.item = Quests.FETCH_ITEMS[ZombRand(#Quests.FETCH_ITEMS) + 1]
    elseif how == "scout" then
        kind = "visit"
        opts.radius = Work.SCOUT_RADIUS
    elseif how == "guard" then
        kind = "defend"
        opts.needMin = Work.GUARD_MIN[tier]
        opts.radius = Work.GUARD_RADIUS
        opts.deadlineT = deadline + opts.needMin
    elseif how == "courier" then
        kind = "fetch"
        opts.item = Work.PARCEL
    end
    local q, why = Quests.createSite(kind, ps, site, t, childOrigin(trade, how, how == "courier" and "pickup" or nil), opts)
    if not q then return nil, why end
    q.tier, q.distance, q.siteKey = tier, math.floor(distance or 0), key
    return q
end

-- 배달 대행 2단계: 꾸러미를 챙겼으면 배달할 건물을 정한다
local function startDropoff(trade, pickup, t)
    local ps = Store.data().players[trade.target] or {}
    local site, distance = pickSite(pickup.cx, pickup.cy, math.max(1, (trade.tier or 1) - 1), { [pickup.building or ""] = true })
    if not site then return nil end
    local q = Quests.createSite("visit", ps.key and ps or nil, site, t, childOrigin(trade, "courier", "dropoff"),
        { tier = trade.tier, building = true, search = 12, radius = Work.SCOUT_RADIUS,
          deadlineT = t.t + Quests.deadlineMinutes(distance) })
    if not q then return nil end
    q.carry = { qid = pickup.id, items = { Work.PARCEL } }
    q.distance = math.floor(distance or 0)
    trade.workId = q.id
    trade.deadlineT = q.deadlineT + 24 * 60
    log("work courier dropoff", trade.id, q.id, "from", pickup.id)
    return q
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

local TOPIC = {
    horde = "they will clear out a pack of the dead around a building for you instead",
    fetch = "they will retrieve a sealed package from a building for you instead",
    scout = "they will go and look over a building for you instead",
    guard = "they will stand guard at a building for you for a while instead",
    courier = "they will pick up a parcel and carry it to another building for you instead",
    credit = "you let them take the goods now and pay later, a little extra for the trouble",
    favor = "you let them have it now for nothing, but they owe you a favor and you will call it in soon",
}

-- 거래 제안에 대가 방식을 고른다. 반환: true | false, 이유
function Work.choose(player, qid, how)
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
    if Work.LABOR[how] then
        child, why = Work.startLabor(q, how, player, ps, t)
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
            Lines.fallback(fid, "work_" .. how, "Do this for me and the goods are yours.", where(child, player)), ps)
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
    return true
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
    if state == "retrieved" and how == "courier" then
        -- 꾸러미를 챙겼다: 회수 퀘스트는 끝내고 배달지로
        Quests.setState(q, "completed", t, nil)
        return
    end
    if state == "completed" and how == "courier" and q.origin.stage == "pickup" then
        if not startDropoff(trade, q, t) then
            Quests.setState(trade, "failed", t, nil)
        end
        Quests.notify(trade)
        return
    end
    if state == "completed" then
        local player = nearestPlayer(q.cx or 0, q.cy or 0)
        local ps = player and Store.player(player) or Store.data().players[trade.target]
        local goods = {}
        for _, g in ipairs(trade.goods or {}) do goods[#goods + 1] = g end
        local bonus = Work.BONUS[how] and Work.bonusGoods(trade) or {}
        for _, g in ipairs(bonus) do goods[#goods + 1] = g end
        trade.workBonus = #bonus > 0 and bonus or nil
        if player then trade.delivered = (deliver(trade, player, ps, goods, t) or {}).id end
        Quests.setState(trade, "completed", t, ps and { ps = ps } or nil)
        local fid = trade.origin.faction
        local extra = #bonus > 0 and " plus a little extra for the hard work" or ""
        Radio.react(fid, "event", "The players finished the work they did instead of paying (" .. tostring(how)
            .. "). You sent the goods" .. extra .. "; the drop location comes in a separate call.",
            StoryEngine.Lines.fallback(fid, #bonus > 0 and "work_done" or "work_paid", "Good work. The goods are on the way."), ps)
        log("work done", trade.id, how, "bonus", #bonus)
    elseif state == "failed" then
        Quests.setState(trade, "failed", t, nil)
        log("work failed", trade.id, how)
    end
end

-- 게임 내 10분마다 (Sensor tick): 경비 중 무리, 빚 부탁 걸기
function Work.tick(entries, t)
    local players = Sensor.players()
    if #players == 0 then return end
    for _, q in pairs(Store.data().quests) do
        if Work.isWork(q) and q.kind == "defend" and Quests.isActive(q) and (q.present or 0) > 0
            and t.t >= (q.nextWaveT or 0) then
            local target = nearestPlayer(q.cx, q.cy)
            if target and StoryEngine.Hunt then
                local size = math.max(4, math.floor(StoryEngine.Hunt.sizeNow() * Work.GUARD_SHARE + 0.5))
                local angle = ZombRandFloat(0, math.pi * 2)
                local d = ZombRand(45, 66)
                StoryEngine.Hunt.start(target, size, q.cx + math.cos(angle) * d, q.cy + math.sin(angle) * d, "work_guard")
                q.waves = (q.waves or 0) + 1
                q.nextWaveT = t.t + Work.GUARD_WAVE
                log("work guard wave", q.id, q.waves, size)
            end
        end
    end
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
