-- AI 디렉터 (서버 측 전용). 게임 내 08:00, 20:00 에 이벤트 하나를 고른다.
--
-- 1. 실행 가능한 이벤트만 추린다 (각 이벤트의 canRun).
-- 2. 플레이어 요약 + 이벤트 목록을 브릿지(director 모듈)에 보낸다. 브릿지는 이 목록으로 JSON 스키마를 만든다.
-- 3. 응답을 여기서 다시 검증한다 (이벤트 화이트리스트, 강도 1~3, 대상 이름). 실패하면 규칙 기반 가중치로 고른다.
-- 4. 미리 구현된 Lua 함수로 실행하고, 결과를 기록과 다음 일지 사건으로 남긴다.

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Places"
require "StoryEngine/Store"
require "StoryEngine/Bridge"
require "StoryEngine/Sensor"
require "StoryEngine/Quests"
require "StoryEngine/Factions"
require "StoryEngine/Radio"

local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Places = StoryEngine.Places
local Quests = StoryEngine.Quests
local Bridge = StoryEngine.Bridge
local Net = StoryEngine.Net
local log = StoryEngine.log

local Director = {
    busy = false,
    events = {},
    order = { "quiet_day", "storm", "supply_drop", "fetch_item", "npc_request", "npc_emergency", "horde_nearby", "helicopter",
              "rescue_signal", "friend_gift", "extortion" },
}
StoryEngine.Director = Director

Director.SLOTS = { [8] = true, [20] = true }
Director.STORM_GAP_MIN = 2 * 24 * 60
-- 간격은 모두 서버 전체 기준 (2026-09-27 사용자 결정)
Director.SUPPLY_GAP_MIN = 24 * 60
-- NPC 가 먼저 청하는 일(부탁·회수·구조 신호·협박)은 NPC(세력)마다 4일 간격. 4일이 지나면 그날 50%, 다음 날 60% ...
-- 하루마다 +10% 로 그 NPC 의 관문이 열린다. 서버 전체로는 하루에 하나만 (2026-09-28 사용자 결정)
Director.ASK_GAP_DAYS = 4
Director.ASK_BASE = 50
Director.ASK_STEP = 10
Director.ASK_SERVER_GAP_DAYS = 2             -- 서버 전체로 NPC 가 먼저 청하는 일은 이 날수에 하나 (2026-09-28: 이틀에 하나)
Director.HORDE_SHARE = 40
Director.STORM_HOURS = { 6, 12, 18, 24, 36 }
Director.MAX_INTENSITY = 5
Director.HORDE_NEAR_GAP_MIN = 2 * 24 * 60
Director.HELI_GAP_MIN = 5 * 24 * 60
Director.MIN_DAYS = 2                        -- 서버 경과 일수가 이보다 적으면 호드·헬기·협박을 보내지 않는다
Director.FRIEND_TRUST = 60                   -- 이 신뢰도 이상인 세력은 가끔 먼저 낮은 등급 보급을 준다
Director.FRIEND_MAX_TIER = 2
Director.FRIEND_GAP_MIN = 3 * 24 * 60
Director.EXTORT_TRUST = 10                   -- 이 신뢰도 이하인 협박 가능 세력은 가끔 협박한다

local function state()
    return Store.data().director
end

local function notifyAll(command, args)
    for _, p in ipairs(Sensor.players()) do
        local ok, err = pcall(Net.toClient, p, command, args)
        if not ok then log("notify failed:", err) end
    end
end

local function hasBite(sample)
    if not sample or not sample.wounds then return false end
    for w, _ in pairs(sample.wounds) do
        if string.find(w, ":bitten") then return true end
    end
    return false
end

-- ---------------------------------------------------------------- events

Director.events.quiet_day = {
    canRun = function(ctx) return true end,
    weight = function(ctx, entry) return 3 end,
    run = function(ctx, entry, intensity) return true end,
}

Director.events.storm = {
    canRun = function(ctx)
        local cm = getClimateManager()
        if cm:isRaining() or cm:isSnowing() or cm:getIsThunderStorming() then return false end
        local last = state().lastStormT
        return not last or ctx.now.t - last >= Director.STORM_GAP_MIN
    end,
    weight = function(ctx, entry) return 1 end,
    run = function(ctx, entry, intensity)
        local hours = Director.STORM_HOURS[intensity] or 6
        -- 멀티 서버: transmitServerTriggerStorm 이 폭풍을 만들고 클라이언트에 날씨를 보낸다 (jar 확인).
        -- 싱글에는 서버가 없어 그 함수가 아무 일도 하지 않으므로 직접 만든다.
        if isServer() then
            getClimateManager():transmitServerTriggerStorm(hours)
        else
            getClimateManager():triggerCustomWeatherStage(WeatherPeriod.STAGE_STORM, hours)
        end
        state().lastStormT = ctx.now.t
        for _, e in ipairs(ctx.entries) do
            Store.addNote(e.ps, { kind = "storm", clock = ctx.now.clock })
        end
        notifyAll("directorNotice", { kind = "storm" })
        if StoryEngine.Social then pcall(StoryEngine.Social.onStorm) end
        if StoryEngine.Monologue then
            local ok, err = pcall(StoryEngine.Monologue.onStorm, ctx.entries)
            if not ok then log("monologue storm error:", err) end
        end
        return true
    end,
}

-- 이 플레이어(와 이 세력)에게 줄 수 있는 최고 등급: 진행 단계 상한과 세력 신뢰도 상한 중 낮은 쪽.
-- 개인 모드는 그 사람의 개인 신뢰로 (DESIGN_PER_PLAYER_TRUST 4절)
function Director.tierCap(ps, fid)
    local cap = Store.STAGE_MAX_TIER[Store.stage(ps)] or Director.MAX_INTENSITY
    if fid and StoryEngine.Factions.byId[fid] then
        local trust = StoryEngine.Trust.of(fid, ps and ps.key)
        for _, row in ipairs(Store.TRUST_MAX_TIER) do
            if trust >= row.min then
                cap = math.min(cap, row.tier)
                break
            end
        end
    end
    return cap
end

-- 퀘스트를 전해 줄 세력을 신뢰도 가중치로 고른다 (신뢰가 높은 세력일수록 연락이 잦다).
-- only: { fid = true } 가 있으면 그 세력들 중에서만 (NPC 가 먼저 청하는 일은 관문이 열린 세력만)
function Director.pickFaction(only)
    local Factions, Radio = StoryEngine.Factions, StoryEngine.Radio
    local total, weights = 0, {}
    for _, f in ipairs(Factions.list) do
        if (not only or only[f.id]) and not Factions.isGone(f.id) then
            local w = Radio.channel(f.id).trust + 10
            weights[#weights + 1] = { id = f.id, w = w }
            total = total + w
        end
    end
    if #weights == 0 then return nil end
    local roll = ZombRandFloat(0, total)
    for _, it in ipairs(weights) do
        roll = roll - it.w
        if roll <= 0 then return it.id end
    end
    return weights[#weights].id
end

-- 서버 전체 간격: state()[key] 로부터 gap 분이 지났는가
local function serverGap(ctx, key, gap)
    local last = state()[key]
    return not last or ctx.now.t - last >= gap
end

-- 세력별 관문 상태. 처음 보는 세력은 마지막 요청을 0~ASK_GAP_DAYS 일 전으로 흩어 두어 한꺼번에 열리지 않게 한다
-- (예전 세이브의 서버 공통 lastAskT 가 있으면 그 시각 기준).
local function askState(ctx, fid)
    local st = state()
    st.asks = st.asks or {}
    local a = st.asks[fid]
    if not a then
        local base = st.lastAskT or ctx.now.t
        a = { lastT = base - ZombRand(Director.ASK_GAP_DAYS + 1) * 24 * 60 }
        st.asks[fid] = a
    end
    return a
end

-- 오늘 먼저 청할 수 있는 세력들 { fid = true } (없으면 nil). 서버 전체로 최근 ASK_SERVER_GAP_DAYS 일 안에
-- 이미 하나 나갔으면 nil (예: 2 면 3일에 청했을 때 5일부터 다시). 세력마다 마지막 요청 뒤 ASK_GAP_DAYS 일이 지나면
-- 하루 한 번 확률을 굴린다.
function Director.openAskers(ctx)
    -- 복구 작전 중에는 NPC 가 먼저 청하는 일(부탁·찾기·구조 신호·협박)을 쉰다 (Ops.lua)
    if StoryEngine.Ops and StoryEngine.Ops.active() then return nil end
    if StoryEngine.Saga and StoryEngine.Saga.active() then return nil end
    local st = state()
    if st.lastAskDay and Store.dayIndex(ctx.now.dayKey) - Store.dayIndex(st.lastAskDay) < Director.ASK_SERVER_GAP_DAYS then
        return nil
    end
    local open, any = {}, false
    for _, f in ipairs(StoryEngine.Factions.list) do
        local a = askState(ctx, f.id)
        local days = math.floor((ctx.now.t - a.lastT) / (24 * 60))
        if days >= Director.ASK_GAP_DAYS and not StoryEngine.Factions.isGone(f.id) then
            if a.rollDay ~= ctx.now.dayKey then
                a.rollDay = ctx.now.dayKey
                local chance = math.min(100, Director.ASK_BASE + Director.ASK_STEP * (days - Director.ASK_GAP_DAYS))
                a.open = ZombRand(100) < chance
                log("npc ask roll:", f.id, days, "days since last,", chance .. "%", a.open and "open" or "closed")
            end
            if a.open then
                open[f.id] = true
                any = true
            end
        end
    end
    if any then return open end
    return nil
end

function Director.askOpen(ctx)
    return Director.openAskers(ctx) ~= nil
end

-- NPC 가 먼저 청하는 일에 쓸 세력: 관문이 열린 세력 중 신뢰도 가중치로. 디버그 강제 실행이면 아무 세력이나
function Director.pickAsker(ctx)
    local open = Director.openAskers(ctx)
    if not open and ctx.forced then return Director.pickFaction() end
    if not open then return nil end
    return Director.pickFaction(open)
end

-- 이 세력이 먼저 청했다: 그 세력의 간격을 다시 세고, 서버 전체로 ASK_SERVER_GAP_DAYS 일 동안 더 청하지 않는다
function Director.markAsked(ctx, fid)
    local st = state()
    st.lastAskDay = ctx.now.dayKey
    if fid then
        local a = askState(ctx, fid)
        a.lastT = ctx.now.t
        a.open = false
    end
end

local function questEligible(kind)
    return function(ctx, entry)
        return not Quests.activeFor(entry.ps.key, kind)
    end
end

local function anyEligible(eligible, gate)
    return function(ctx)
        if gate and not gate(ctx) then return false end
        for _, e in ipairs(ctx.entries) do
            if eligible(ctx, e) then return true end
        end
        return false
    end
end

local function stayedHomeDays(entry)
    local home = 0
    for i = math.max(1, #entry.ps.days - 2), #entry.ps.days do
        local d = entry.ps.days[i]
        if d and d.summary and d.summary.class == "stayed_home" then home = home + 1 end
    end
    return home
end

-- done(ctx): 성공한 뒤 서버 전체 간격을 기록한다
local function questRunner(kind, done, picker)
    return function(ctx, entry, intensity)
        local fid
        if picker then fid = picker(ctx) else fid = Director.pickFaction() end
        if not fid then return false end
        intensity = Director.askTier(intensity, entry.ps, fid)
        local q, why = Quests.create(kind, entry.player, entry.ps, intensity, ctx.now,
            { source = "director", faction = fid })
        if not q then
            log(kind .. " failed:", why)
            return false
        end
        done(ctx, fid)
        return true
    end
end

-- NPC 의 부탁: 이미 답을 기다리거나 진행 중인 부탁이 있으면 새로 하지 않는다
local function openRequestFor(ctx, entry)
    return not (Quests.openFor(entry.ps.key, "deliver") or Quests.openFor(entry.ps.key, "horde"))
end

local function requestEligible(ctx, entry)
    -- 개인 모드는 사람마다 따로 오는 개인별 부탁(Director.personalAsks)이 맡는다 (급한 부탁은 그대로 서버 전체)
    if StoryEngine.Trust.personalMode() then return false end
    return openRequestFor(ctx, entry)
end

Director.events.npc_request = {
    canRun = anyEligible(requestEligible, Director.askOpen),
    weight = function(ctx, entry) return 1 end,
    eligible = requestEligible,
    run = function(ctx, entry, intensity)
        -- 물건 부탁 60%, 좀비 무리 소탕 부탁 40% (둘 다 NPC 의 부탁이라 빈도 제한을 같이 쓴다)
        local fid = Director.pickAsker(ctx)
        if not fid then return false end
        intensity = Director.askTier(intensity, entry.ps, fid)
        local q, why
        if ctx.forceKind == "horde" or (not ctx.forceKind and ZombRand(100) < Director.HORDE_SHARE) then
            q, why = Quests.proposeHorde(entry.player, entry.ps, fid, intensity, ctx.now)
        else
            q, why = Quests.propose(entry.player, entry.ps, fid, intensity, ctx.now)
        end
        if not q then
            log("npc_request failed:", why)
            return false
        end
        Director.markAsked(ctx, fid)
        return true
    end,
}

-- 급한 부탁: 핵심 자원이 바닥인 NPC 가 NPC 별 관문을 무시하고 청한다 (NpcEvents, 서버 전체 하루 간격)
Director.events.npc_emergency = {
    canRun = anyEligible(openRequestFor, function(ctx)
        local NE = StoryEngine.NpcEvents
        return NE ~= nil and NE.emergencyGapOk(ctx.now) and NE.emergency() ~= nil
    end),
    weight = function(ctx, entry) return 4 end,
    eligible = openRequestFor,
    run = function(ctx, entry, intensity)
        local NE = StoryEngine.NpcEvents
        local fid, res = NE.emergency()
        if not fid then return false end
        intensity = Director.askTier(intensity, entry.ps, fid)
        local q, why = Quests.propose(entry.player, entry.ps, fid, intensity, ctx.now, { prefer = res, urgent = true })
        if not q then
            log("npc_emergency failed:", why)
            return false
        end
        NE.markEmergency(ctx.now)
        return true
    end,
}

local supplyEligible = questEligible("supply_drop")
Director.events.supply_drop = {
    canRun = anyEligible(supplyEligible, function(ctx) return serverGap(ctx, "lastSupplyT", Director.SUPPLY_GAP_MIN) end),
    -- 최근 이틀 이상 집에만 있었으면 나갈 이유를 준다
    weight = function(ctx, entry) return stayedHomeDays(entry) >= 2 and 3 or 1 end,
    eligible = supplyEligible,
    run = questRunner("supply_drop", function(ctx) state().lastSupplyT = ctx.now.t end),
}

-- 회수 부탁도 NPC 가 청하는 일이라 공통 관문을 쓴다
local fetchEligible0 = questEligible("fetch")
local function fetchEligible(ctx, entry)
    if StoryEngine.Trust.personalMode() then return false end      -- 개인별 부탁이 맡는다
    return fetchEligible0(ctx, entry)
end
Director.events.fetch_item = {
    canRun = anyEligible(fetchEligible, Director.askOpen),
    weight = function(ctx, entry) return 1 end,
    eligible = fetchEligible,
    run = questRunner("fetch", Director.markAsked, Director.pickAsker),
}

-- ---------------------------------------------------------------- horde / helicopter / rescue

local DIR_CODES = { "E", "SE", "S", "SW", "W", "NW", "N", "NE" }
local DIR_WORDS = { E = "east", SE = "southeast", S = "south", SW = "southwest", W = "west", NW = "northwest",
                    N = "north", NE = "northeast" }

-- 서버 경과 일수 (예전 호출 모양을 유지하려고 인자는 무시한다)
local function daysSeen()
    return Store.serverDays()
end

-- 호드 유도: 접속한 모든 플레이어에게 각각 추적 무리 (서버 간격)
local function hordeNearEligible(ctx, entry)
    if daysSeen() <= Director.MIN_DAYS then return false end
    return serverGap(ctx, "lastHordeNearT", Director.HORDE_NEAR_GAP_MIN)
end

Director.events.horde_nearby = {
    canRun = anyEligible(hordeNearEligible),
    -- 집에만 있던 사람에게 긴장을 준다
    weight = function(ctx, entry) return stayedHomeDays(entry) >= 2 and 2 or 1 end,
    eligible = hordeNearEligible,
    run = function(ctx, entry, intensity)
        local Hunt = StoryEngine.Hunt
        local size = Hunt.sizeNow()
        local angle = 0
        for _, e in ipairs(ctx.entries) do
            local a = Hunt.sendAt(e.player, "horde_nearby", size)
            if e == entry then angle = a end
            Store.addNote(e.ps, { kind = "horde_nearby", clock = ctx.now.clock, count = size })
        end
        state().lastHordeNearT = ctx.now.t
        -- 오는 방향 (대상 플레이어 기준, 무리가 있는 쪽). 다른 사람들에게도 각자 한 무리씩 간다
        local deg = angle * 180 / math.pi
        local code = DIR_CODES[math.floor(((deg + 360 + 22.5) % 360) / 45) + 1]
        log("horde_nearby", size, "from", code, "for", entry.ps.name)
        local fid = Director.pickFaction()
        local each = #ctx.entries > 1 and " Each of the players has a pack like that on their trail." or ""
        StoryEngine.Radio.react(fid, "event", "You spotted a pack of about " .. StoryEngine.intToString(size)
            .. " dead moving toward " .. entry.ps.name .. " from the " .. DIR_WORDS[code] .. " (as seen from them), maybe "
            .. "half an hour away, and they will not stop following." .. each .. " Warn them quickly.",
            StoryEngine.Lines.fallback(fid, "horde_warning", "Heads up. About " .. StoryEngine.intToString(size)
                .. " of the dead are heading your way from the " .. DIR_WORDS[code] .. ".",
                { { t = "num", v = size }, { t = "dir", v = code } }), entry.ps)
        return true
    end,
}

local function heliEligible(ctx, entry)
    if daysSeen() <= Director.MIN_DAYS + 1 then return false end
    local last = state().lastHeliT
    return not last or ctx.now.t - last >= Director.HELI_GAP_MIN
end

Director.events.helicopter = {
    canRun = anyEligible(heliEligible),
    weight = function(ctx, entry) return 1 end,
    eligible = heliEligible,
    run = function(ctx, entry, intensity)
        -- 서버·싱글에서 testHelicopter 는 월드의 헬기를 무작위 플레이어에게 보낸다 (멀티 클라이언트면 /chopper start)
        testHelicopter()
        state().lastHeliT = ctx.now.t
        if StoryEngine.Social then pcall(StoryEngine.Social.onHelicopter) end
        for _, e in ipairs(ctx.entries) do
            Store.addNote(e.ps, { kind = "helicopter", clock = ctx.now.clock })
        end
        notifyAll("directorNotice", { kind = "helicopter" })
        if StoryEngine.Monologue then pcall(StoryEngine.Monologue.onHelicopter, ctx.entries) end
        -- 방위대가 떠났으면 다른 사람이 알린다 (점검 D4)
        local fid = not StoryEngine.Factions.isGone("guard") and "guard" or Director.pickFaction()
        StoryEngine.Radio.react(fid, "event", "A helicopter is flying low over the county, circling. The noise will pull "
            .. "every dead thing for miles toward wherever it goes. You have no idea who is flying it.",
            StoryEngine.Lines.fallback(fid, "heli", "A helicopter is circling low. Stay out of its way."), entry.ps)
        return true
    end,
}

-- 무전 구조 신호: 누군가 건물에 갇혔다는 신호를 세력이 전해 준다. 가 보면 생존자는 이미 돌아서 있고 남긴 물건만 있다
local function openRescue(ps)
    for _, q in pairs(Store.data().quests) do
        if q.target == ps.key and q.origin and q.origin.source == "rescue" and Quests.isActive(q) then return true end
    end
    return false
end

local function rescueEligible(ctx, entry)
    return not openRescue(entry.ps)
end

Director.events.rescue_signal = {
    canRun = anyEligible(rescueEligible, Director.askOpen),
    -- 집에만 있거나 지루해하면 밖으로 나갈 이유를 준다
    weight = function(ctx, entry)
        local s = entry.ps.prev
        local bored = s and s.moodles and (s.moodles.BORED or 0) >= 2
        return (stayedHomeDays(entry) >= 2 or bored) and 3 or 1
    end,
    eligible = rescueEligible,
    run = function(ctx, entry, intensity)
        local fid = Director.pickAsker(ctx)
        if not fid then return false end
        intensity = Director.askTier(intensity, entry.ps, fid)
        local q, why = Quests.create("supply_drop", entry.player, entry.ps, intensity, ctx.now,
            { source = "rescue", faction = fid, initiator = "gift" }, StoryEngine.Loot.roll(intensity))
        if not q then
            log("rescue_signal failed:", why)
            return false
        end
        Director.markAsked(ctx, fid)
        return true
    end,
}

-- 신뢰하는 세력이 먼저 챙겨 주는 보급 (낮은 등급만). 개인 모드는 그 사람의 개인 신뢰로, 사람마다 3일 간격
local function friendFaction(key)
    local list = {}
    for _, f in ipairs(StoryEngine.Factions.list) do
        if StoryEngine.Trust.of(f.id, key) >= Director.FRIEND_TRUST and not StoryEngine.Factions.isGone(f.id) then
            list[#list + 1] = f.id
        end
    end
    if #list == 0 then return nil end
    return list[ZombRand(#list) + 1]
end

local function friendEligible(ctx, entry)
    if StoryEngine.Trust.personalMode() then
        local last = entry.ps.friendGiftT
        if last and ctx.now.t - last < Director.FRIEND_GAP_MIN then return false end
    elseif not serverGap(ctx, "lastFriendT", Director.FRIEND_GAP_MIN) then
        return false
    end
    return friendFaction(entry.ps.key) ~= nil
end

Director.events.friend_gift = {
    canRun = anyEligible(friendEligible),
    weight = function(ctx, entry) return 2 end,
    eligible = friendEligible,
    run = function(ctx, entry, intensity)
        local fid = friendFaction(entry.ps.key)
        if not fid then return false end
        local tier = math.min(intensity, Director.FRIEND_MAX_TIER, Director.tierCap(entry.ps, fid))
        local q, why = Quests.create("supply_drop", entry.player, entry.ps, tier, ctx.now,
            { source = "director", faction = fid, initiator = "gift", friend = true })
        if not q then
            log("friend_gift failed:", why)
            return false
        end
        state().lastFriendT = ctx.now.t
        entry.ps.friendGiftT = ctx.now.t
        return true
    end,
}

-- 신뢰도가 바닥인 험한 세력의 협박. open 이 있으면 관문이 열린 세력 중에서만.
-- 개인 모드는 그 사람(key)의 개인 신뢰가 바닥일 때 그 사람을 (DESIGN_PER_PLAYER_TRUST 4절)
local function threatFaction(open, key)
    local best, bestTrust = nil, nil
    for _, f in ipairs(StoryEngine.Factions.list) do
        local trust = StoryEngine.Trust.of(f.id, key)
        -- 장기 프로젝트: 빅 교역소 완성이면 협박 중단, 방위대 검문소 완성이면 빅의 협박이 절반
        local P = StoryEngine.Projects
        local quiet = f.id == "rats" and P ~= nil and (P.done("rats") or P.ratsQuietToday())
        if f.threat and not quiet and trust <= Director.EXTORT_TRUST and (not open or open[f.id]) and not StoryEngine.Factions.isGone(f.id)
            and (not bestTrust or trust < bestTrust) then
            best, bestTrust = f.id, trust
        end
    end
    return best
end

local function extortEligible(ctx, entry)
    if daysSeen() <= Director.MIN_DAYS then return false end
    if Quests.openFor(entry.ps.key, "extort") then return false end
    local open = Director.openAskers(ctx)
    if not open and not ctx.forced then return false end
    return threatFaction(open, entry.ps.key) ~= nil
end

Director.events.extortion = {
    canRun = anyEligible(extortEligible, Director.askOpen),
    weight = function(ctx, entry) return 1 end,
    eligible = extortEligible,
    run = function(ctx, entry, intensity)
        local fid = threatFaction(Director.openAskers(ctx), entry.ps.key)
        if not fid and ctx.forced then fid = threatFaction(nil, entry.ps.key) end
        if not fid then return false end
        local q, why = Quests.demand(entry.player, entry.ps, fid, Director.askTier(intensity, entry.ps), ctx.now)
        if not q then
            log("extortion failed:", why)
            return false
        end
        Director.markAsked(ctx, fid)
        return true
    end,
}

-- ---------------------------------------------------------------- context

local function dayRecord(d)
    local s = d.summary or {}
    return { day = d.day, class = s.class, kills = s.kills, harmed = s.harmed, maxFromHome = s.maxFromHome }
end

local function buildContext()
    local now = Sensor.now()
    local entries = {}
    for _, p in ipairs(Sensor.players()) do
        local ps = Store.player(p)
        if not ps.dead then entries[#entries + 1] = { player = p, ps = ps } end
    end
    return { now = now, entries = entries }
end

local function playerSummary(e)
    local ps, s = e.ps, e.ps.prev
    local out = { name = ps.name, days = {} }
    for i = math.max(1, #ps.days - 1), #ps.days do
        if ps.days[i] then out.days[#out.days + 1] = dayRecord(ps.days[i]) end
    end
    if ps.day then
        out.days[#out.days + 1] = dayRecord({ day = ps.day.index, summary = Sensor.daySummary(ps.day) })
    end
    if s then
        local wounds = 0
        for _ in pairs(s.wounds or {}) do wounds = wounds + 1 end
        out.hp = s.hp
        out.wounds = wounds
        out.bitten = hasBite(s)
        out.inside = s.building ~= nil
        out.zombiesNear = s.zombies
        out.moodles = s.moodles
        out.town = Places.describe(s.x, s.y).town
    end
    out.activeQuest = Quests.activeFor(ps.key) ~= nil
    out.stage = math.min(3, Store.stage(ps))       -- 브릿지는 세 단계만 안다 (4·5단계도 "후반"으로)
    out.maxIntensity = Director.tierCap(ps)
    local weeks = ps.weeks or {}
    if #weeks > 0 then out.lastWeek = string.sub(weeks[#weeks].text or "", 1, 400) end
    return out
end

-- 샌드박스로 끈 이벤트
local function disabledByOption(id)
    if (id == "npc_request" or id == "npc_emergency") and StoryEngine.option("NpcRequests", true) ~= true then return true end
    if (id == "horde_nearby" or id == "helicopter" or id == "extortion")
        and StoryEngine.option("DangerEvents", true) ~= true then return true end
    if id == "extortion" and StoryEngine.Tuning and StoryEngine.Tuning.get("Extortion") ~= true then return true end
    return false
end

local function allowedEvents(ctx)
    local ids = {}
    for _, id in ipairs(Director.order) do
        if not disabledByOption(id) then
            local ok, can = pcall(Director.events[id].canRun, ctx)
            if ok and can then ids[#ids + 1] = id end
        end
    end
    return ids
end

-- ---------------------------------------------------------------- choose & run

local function findEntry(ctx, name)
    for _, e in ipairs(ctx.entries) do
        if e.ps.name == name then return e end
    end
    return nil
end

-- LLM 응답 검증. 통과하면 { event, intensity, entry, reason }
function Director.validate(ctx, allowed, json)
    if type(json) ~= "table" then return nil, "not_object" end
    local ok = false
    for _, id in ipairs(allowed) do
        if json.event == id then ok = true end
    end
    if not ok then return nil, "event_not_allowed" end
    local intensity = tonumber(json.intensity) or 1
    intensity = math.max(1, math.min(Director.MAX_INTENSITY, math.floor(intensity)))
    local entry = type(json.target) == "string" and findEntry(ctx, json.target) or nil
    if not entry then entry = ctx.entries[1] end
    local reason = type(json.reason) == "string" and string.sub(json.reason, 1, 200) or ""
    return { event = json.event, intensity = intensity, entry = entry, reason = reason }
end

-- 규칙 기반 선택에서 쓰는 강도: 높을수록 드물게 (1: 35%, 2: 30%, 3: 20%, 4: 10%, 5: 5%).
-- 2026-10-10 사용자 결정: 진행 단계가 오를수록 낮은 등급이 줄고 높은 등급이 는다 (상한은 Director.tierCap 그대로)
Director.INTENSITY_WEIGHTS = { 35, 30, 20, 10, 5 }
Director.INTENSITY_BY_STAGE = {
    { 35, 30, 20, 10, 5 },
    { 25, 30, 25, 15, 5 },
    { 15, 25, 30, 20, 10 },
    { 10, 20, 30, 25, 15 },
    { 5, 15, 30, 30, 20 },
}
-- NPC 가 청하는 일·협박·구조 신호의 최소 등급 (AI 가 낮게 골라도 이만큼은. 상한이 더 낮으면 상한)
Director.INTENSITY_FLOOR = { 1, 1, 2, 2, 3 }

function Director.askTier(intensity, ps, fid)
    local floor = Director.INTENSITY_FLOOR[Store.stage(ps)] or 1
    return math.min(math.max(intensity or 1, floor), Director.tierCap(ps, fid))
end

function Director.randomIntensity()
    local weights = Director.INTENSITY_BY_STAGE[Store.stage()] or Director.INTENSITY_WEIGHTS
    local roll = ZombRand(100)
    for i, w in ipairs(weights) do
        if roll < w then return i end
        roll = roll - w
    end
    return 1
end

-- 규칙 기반 선택 (브릿지 불통, 잘못된 응답)
function Director.fallback(ctx, allowed)
    local options, total = {}, 0
    for _, id in ipairs(allowed) do
        local ev = Director.events[id]
        for _, e in ipairs(ctx.entries) do
            if not ev.eligible or ev.eligible(ctx, e) then
                local w = ev.weight(ctx, e)
                if w > 0 then
                    options[#options + 1] = { event = id, entry = e, w = w }
                    total = total + w
                end
            end
        end
    end
    if total <= 0 then return { event = "quiet_day", intensity = 1, entry = ctx.entries[1], reason = "no options" } end
    local roll = ZombRandFloat(0, total)
    for _, o in ipairs(options) do
        roll = roll - o.w
        if roll <= 0 then
            return { event = o.event, intensity = Director.randomIntensity(), entry = o.entry, reason = "rule-based" }
        end
    end
    local o = options[#options]
    return { event = o.event, intensity = 1, entry = o.entry, reason = "rule-based" }
end

function Director.execute(ctx, choice, source)
    local ev = Director.events[choice.event]
    local entry = choice.entry
    -- 대상이 이 이벤트를 받을 수 없으면 받을 수 있는 다른 플레이어로 바꾼다
    if ev.eligible and entry and source ~= "debug" and not ev.eligible(ctx, entry) then
        entry = nil
        for _, e in ipairs(ctx.entries) do
            if ev.eligible(ctx, e) then entry = e; break end
        end
    end
    local ok, result = false, false
    if entry then
        choice.intensity = math.max(1, math.min(choice.intensity or 1, Director.tierCap(entry.ps)))
        ok, result = pcall(ev.run, ctx, entry, choice.intensity)
    end
    if not ok or not result then
        log("director event failed:", choice.event, tostring(result))
        choice = { event = "quiet_day", intensity = 1, entry = choice.entry, reason = "fallback after failure" }
        entry = choice.entry
    end
    local st = state()
    Store.push(st.history, {
        day = Store.dayIndex(ctx.now.dayKey), clock = ctx.now.clock, event = choice.event,
        intensity = choice.intensity, target = entry and entry.ps.name or nil,
        source = source, reason = choice.reason,
    }, 30)
    log("director:", choice.event, "x" .. StoryEngine.intToString(choice.intensity),
        "->", entry and entry.ps.name or "-", "[" .. source .. "]", choice.reason or "")
    return choice
end

-- reason: "schedule" | "debug". forced: 이벤트 id 를 주면 LLM 없이 바로 실행 (디버그)
function Director.run(reason, forced, forcedEntryName, forceKind)
    if Director.busy then return false, "busy" end
    local ctx = buildContext()
    ctx.forceKind = forceKind
    if #ctx.entries == 0 then return false, "no_players" end
    local allowed = allowedEvents(ctx)

    if forced then
        if not Director.events[forced] then return false, "unknown_event" end
        local entry = forcedEntryName and findEntry(ctx, forcedEntryName) or ctx.entries[1]
        ctx.forced = true
        Director.execute(ctx, { event = forced, intensity = 1, entry = entry, reason = "forced" }, "debug")
        return true
    end

    local players, recent = {}, {}
    for _, e in ipairs(ctx.entries) do players[#players + 1] = playerSummary(e) end
    local hist = state().history
    for i = math.max(1, #hist - 5), #hist do recent[#recent + 1] = hist[i] end
    local events = {}
    for _, id in ipairs(allowed) do events[#events + 1] = { id = id } end
    local cm = getClimateManager()
    local payload = {
        day = Store.dayIndex(ctx.now.dayKey), date = ctx.now.date, clock = ctx.now.clock,
        weather = { raining = cm:isRaining(), snowing = cm:isSnowing(), thunder = cm:getIsThunderStorming(),
                    temp = math.floor(cm:getTemperature()) },
        players = players, recent = recent, events = events,
        npcs = StoryEngine.NpcEvents and StoryEngine.NpcEvents.directorSummary() or nil,
        world = StoryEngine.World and StoryEngine.World.conditions() or nil,
    }

    Director.busy = true
    log("director request", reason, "allowed", table.concat(allowed, ","))
    Bridge.request("director", payload, function(res)
        Director.busy = false
        -- 응답을 기다리는 동안 접속자가 바뀌었을 수 있으니 컨텍스트를 새로 만든다
        local fresh = buildContext()
        if #fresh.entries == 0 then return end
        local choice, why = nil, res.error
        if res.ok then choice, why = Director.validate(fresh, allowed, res.json) end
        if choice then
            Director.execute(fresh, choice, "llm")
        else
            log("director fallback:", tostring(why))
            Director.execute(fresh, Director.fallback(fresh, allowedEvents(fresh)), "fallback")
        end
    end, { timeoutMs = 120000 })
    return true
end

function Director.statusText()
    local hist = state().history
    local last = hist[#hist]
    local parts = { "quests: " .. Quests.statusText() }
    if StoryEngine.Hunt then parts[#parts + 1] = "hunts: " .. StoryEngine.Hunt.statusText() end
    if last then
        parts[#parts + 1] = "last: D" .. StoryEngine.intToString(last.day or 0) .. " " .. tostring(last.clock)
            .. " " .. tostring(last.event) .. " -> " .. tostring(last.target) .. " [" .. tostring(last.source) .. "]"
    end
    return table.concat(parts, " | ")
end

-- ---------------------------------------------------------------- 개인별 부탁 (개인 모드, DESIGN_PER_PLAYER_TRUST 5-3절)
-- 디렉터 사건(서버 전체 이틀에 하나) 대신 접속자마다 PersonalAskMinDays~MaxDays 일에 하나. 받은 사람만 수락·거절하고,
-- 결과는 그 사람의 개인 신뢰로 (도운 사람은 HelperTrustShare 배). 상태 ps.pask = { nextT, last = { fid = t } }
Director.PERSONAL_FIRST_DAYS = 2           -- 새 캐릭터는 처음 이만큼 없음
Director.PERSONAL_NPC_GAP_DAYS = 4         -- 같은 NPC 가 같은 사람에게
Director.PERSONAL_KINDS = { { "deliver", 45 }, { "horde", 30 }, { "fetch", 15 }, { "named", 10 } }

local function askDays()
    local T = StoryEngine.Tuning
    local lo = math.max(0.5, T and T.num("PersonalAskMinDays") or 2)
    local hi = math.max(lo, T and T.num("PersonalAskMaxDays") or 5)
    return lo + ZombRandFloat(0, hi - lo)
end

local function openPersonal(key)
    for _, q in pairs(Store.data().quests) do
        if q.addressed == key and (q.state == "proposed" or Quests.isActive(q)) then return q end
    end
    return nil
end

-- 그 사람에게 청할 NPC: 개인 신뢰 가중치(+10), 같은 NPC 는 PERSONAL_NPC_GAP_DAYS 간격
local function personalAsker(ps, now)
    local Factions, Trust = StoryEngine.Factions, StoryEngine.Trust
    local last = ps.pask and ps.pask.last or {}
    local total, list = 0, {}
    for _, f in ipairs(Factions.list) do
        local t = last[f.id]
        if not Factions.isGone(f.id) and not (t and now.t - t < Director.PERSONAL_NPC_GAP_DAYS * 24 * 60) then
            local w = Trust.of(f.id, ps.key) + 10
            list[#list + 1] = { id = f.id, w = w }
            total = total + w
        end
    end
    if #list == 0 then return nil end
    local roll = ZombRandFloat(0, total)
    for _, it in ipairs(list) do
        roll = roll - it.w
        if roll <= 0 then return it.id end
    end
    return list[#list].id
end

local function pickKind()
    local total = 0
    for _, k in ipairs(Director.PERSONAL_KINDS) do total = total + k[2] end
    local r = ZombRand(total)
    for _, k in ipairs(Director.PERSONAL_KINDS) do
        r = r - k[2]
        if r < 0 then return k[1] end
    end
    return "deliver"
end

-- 한 사람에게 개인별 부탁 하나. force: 간격 무시 (디버그). 반환: 퀘스트 | nil, 이유
function Director.personalAsk(player, ps, now, force, forceKind)
    local Trust = StoryEngine.Trust
    if not Trust.personalMode() then return nil, "not_personal" end
    if openPersonal(ps.key) then return nil, "open" end
    if not force then
        if StoryEngine.Ops and StoryEngine.Ops.active() then return nil, "ops" end
        if StoryEngine.Saga and StoryEngine.Saga.active() then return nil, "saga" end
    end
    local fid = personalAsker(ps, now)
    if not fid then return nil, "no_npc" end
    local tier = Director.askTier(Director.randomIntensity(), ps, fid)
    local kind = forceKind or pickKind()
    local q, why
    -- 건물을 못 찾는 등으로 안 되면 물건 부탁으로 (오류도 막는다)
    local function try(fn, ...)
        local ok, a, b = pcall(fn, ...)
        if not ok then
            log("personal ask " .. kind .. " error:", a)
            return nil, "error"
        end
        return a, b
    end
    if kind == "named" and StoryEngine.Named and StoryEngine.Named.enabled() then
        local list = StoryEngine.Named.candidates(ps.key)
        local person = nil
        for _, p in ipairs(list) do if p.npc == fid then person = p end end
        person = person or list[1]
        if person then
            q, why = try(StoryEngine.Named.propose, player, ps, person, now, { addressed = ps.key })
            if q then fid = person.npc end
        end
    elseif kind == "horde" then
        q, why = try(Quests.proposeHorde, player, ps, fid, tier, now, { addressed = ps.key })
    elseif kind == "fetch" then
        q, why = try(Quests.create, "fetch", player, ps, tier, now, { source = "director", faction = fid, addressed = ps.key })
    end
    if not q then q, why = Quests.propose(player, ps, fid, tier, now, { addressed = ps.key }) end
    if not q then return nil, why end
    ps.pask = ps.pask or { last = {} }
    ps.pask.last = ps.pask.last or {}
    ps.pask.last[fid] = now.t
    ps.pask.nextT = now.t + math.floor(askDays() * 24 * 60)
    Trust.ensure(fid, ps.key)          -- 개인별 부탁을 받는 것도 처음 연락이다
    log("personal ask", q.id, q.kind, fid, "for", ps.name, "next in", StoryEngine.intToString(math.floor((ps.pask.nextT - now.t) / 60)), "h")
    return q
end

-- 게임 내 1시간마다: 접속자마다 차례가 됐으면
function Director.personalAsks()
    local Trust = StoryEngine.Trust
    if not Trust.personalMode() then return end
    if StoryEngine.option("Director", true) ~= true or StoryEngine.option("NpcRequests", true) ~= true then return end
    local now = Sensor.now()
    for _, p in ipairs(Sensor.players()) do
        local ps = Store.player(p)
        if ps and not ps.dead then
            ps.pask = ps.pask or { last = {} }
            if not ps.pask.nextT then
                ps.pask.nextT = now.t + Director.PERSONAL_FIRST_DAYS * 24 * 60
            elseif now.t >= ps.pask.nextT and not openPersonal(ps.key) then
                local ok, q, why = pcall(Director.personalAsk, p, ps, now)
                if not ok then
                    log("personal ask error:", q)
                elseif not q then
                    ps.pask.nextT = now.t + 6 * 60          -- 못 냈으면 6시간 뒤 다시
                    log("personal ask skipped", ps.name, tostring(why))
                end
            end
        end
    end
end

Events.EveryHours.Add(function()
    local ok, err = pcall(Director.personalAsks)
    if not ok then log("personal asks error:", err) end
end)

-- 08:00 / 20:00 (EveryTenMinutes 는 매시 00~09분 사이에 한 번 온다)
Events.EveryTenMinutes.Add(function()
    if StoryEngine.option("Director", true) ~= true then return end
    local gt = getGameTime()
    local hour = gt:getHour()
    if not Director.SLOTS[hour] or gt:getMinutes() >= 10 then return end
    local now = Sensor.now()
    local slot = now.dayKey * 100 + hour
    local st = state()
    if st.lastSlot == slot then return end
    st.lastSlot = slot
    local ok, err = pcall(Director.run, "schedule")
    if not ok then
        Director.busy = false
        log("director error:", err)
    end
end)

return Director
