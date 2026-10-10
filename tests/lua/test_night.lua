-- 야간 작전 (2026-10-10 사용자 결정): 소탕·경비·정찰·배달은 3등급부터 주간·야간을 고르고, 야간은 밤(21~05시)에만
-- 진행되며 보상 1.5배. 이야기 소탕은 일부가 밤 전용. 샌드박스 NightJobs / NightRewardMult / NightMinTier / NightStoryChance
local T = {}

-- 플레이어(10000,10000) 둘레에 건물 고리
local function mockBuildings()
    local defs = {}
    for _, d in ipairs({ 120, 160, 300, 380, 600, 700 }) do
        for i = 0, 7 do
            local a = i * math.pi / 4
            local x, y = math.floor(10000 + math.cos(a) * d), math.floor(10000 + math.sin(a) * d)
            local room = {}
            function room:getZ() return 0 end
            function room:getArea() return 100 end
            function room:getX() return x end
            function room:getY() return y end
            function room:getX2() return x + 9 end
            function room:getY2() return y + 9 end
            function room:getName() return "office" end
            local def = {}
            function def:getX() return x end
            function def:getY() return y end
            function def:getX2() return x + 9 end
            function def:getY2() return y + 9 end
            function def:getRooms() return H.list({ room }) end
            function def:isResidential() return false end
            defs[#defs + 1] = def
        end
    end
    ArrayList = { new = function() return H.list({}) end }
    local grid = {}
    function grid:getBuildingsIntersecting(x, y, w, h, list)
        for _, def in ipairs(defs) do
            if def:getX2() >= x and def:getX() <= x + w and def:getY2() >= y and def:getY() <= y + h then
                list.items[#list.items + 1] = def
            end
        end
    end
    function grid:getBuildingAt() return nil end
    local world = {}
    function world:getMetaGrid() return grid end
    getWorld = function() return world end
end

local spawned = {}
local function base()
    mockBuildings()
    spawned = {}
    addZombiesInOutfitArea = function(x1, y1, x2, y2, z, count)
        spawned[#spawned + 1] = count
        return H.list({})
    end
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    StoryEngine.Quests.SETTLE_MS = 0           -- 칸이 불러지면 바로 놓는다
    SandboxVars.StoryEngine.ModItemsRatio = 0
    StoryEngine.Life.daily()
    StoryEngine.Trade.FREE_CHANCE = 0
    return p, ps
end

local function Q() return StoryEngine.Quests end
local function W() return StoryEngine.Work end
local function quest(id) return StoryEngine.Store.data().quests[id] end
local function now() return StoryEngine.Sensor.now() end

-- 게임 시각을 다음 h 시로
local function setHour(h)
    local gt = getGameTime()
    local add = ((h - gt:getHour()) % 24) * 60 - gt:getMinutes()
    if add <= 0 then add = add + 1440 end
    H.advance(add)
end

-- 거래를 일로 갚는다 (등급을 정해서). 반환 p, ps, 거래, 일 퀘스트
local function job(kind, tier, night, fid)
    local p, ps = base()
    fid = fid or "ray"
    StoryEngine.Radio.channel(fid).trust = 65
    local trade = StoryEngine.Trade.fromReply(fid, ps, { action = "offer", category = "food", tier = 2,
                                                        pay_category = StoryEngine.Value.WANTS[fid][1] })
    H.ok(trade and trade.state == "proposed", "offer made")
    trade.tier = tier
    H.ok(W().choose(p, trade.id, "labor", kind, night))
    return p, ps, trade, quest(trade.workId)
end

local function overheadOf(key)
    local n = 0
    for _, o in ipairs(H.sentOf("radioOverhead")) do
        if o.lt and o.lt.key == "IGUI_StoryEngine_WorkNote_" .. key then n = n + 1 end
    end
    return n
end

local function deliveriesFor(qid)
    local out = {}
    for _, d in pairs(StoryEngine.Store.data().quests) do
        if d.kind == "supply_drop" and d.origin and d.origin.rewardFor == qid then out[#out + 1] = d end
    end
    return out
end

function T.night_is_a_choice_from_tier_three()
    base()
    H.ok(Q().nightAllowed(3) and Q().nightAllowed(5))
    H.ok(not Q().nightAllowed(2), "below the minimum tier")
    H.eq(Q().nightMult(), 1.5)
    SandboxVars.StoryEngine.NightMinTier = 2
    H.ok(Q().nightAllowed(2))
    SandboxVars.StoryEngine.NightMinTier = nil
    SandboxVars.StoryEngine.NightJobs = false
    H.ok(not Q().nightAllowed(5), "switched off in the sandbox")
    SandboxVars.StoryEngine.NightJobs = nil
end

function T.scout_is_by_day_unless_night_is_chosen()
    local p, ps, trade, child = job("scout", 3, nil)
    H.ok(not child.night and not trade.nightWork, "tier 3 scouting is no longer night-only")
    local e = { { player = p, ps = ps, s = { x = child.cx, y = child.cy, building = child.building } } }
    setHour(12)
    Q().trackSite(child, e, now())
    H.advance(10)
    Q().trackSite(child, e, now())
    H.ok((child.progress or 0) > 0 or child.point == 2, "daytime counts")
end

function T.night_scout_waits_for_dark_and_adds_a_day()
    local p, ps, trade, child = job("scout", 3, true)
    H.ok(child.night and trade.nightWork, "chosen by night")
    H.ok(child.deadlineT - child.createdT >= Q().deadlineMinutes(child.distance or 0) + 24 * 60, "a day more")
    local e = { { player = p, ps = ps, s = { x = child.cx, y = child.cy, building = child.building } } }
    setHour(12)
    Q().trackSite(child, e, now())
    H.advance(30)
    Q().trackSite(child, e, now())
    H.eq(child.progress or 0, 0, "daytime does not count")
    H.ok(child.waitNight)
end

function T.night_below_the_minimum_tier_is_a_day_job()
    local _, _, trade, child = job("guard", 2, true)
    H.ok(not child.night and not trade.nightWork, "tier 2 cannot be a night job")
end

function T.night_guard_only_counts_and_draws_packs_after_dark()
    local p, ps, trade, child = job("guard", 3, true, "pike")
    H.eq(child.kind, "defend")
    H.ok(child.night)
    local e = { { player = p, ps = ps, s = { x = child.cx, y = child.cy } } }
    setHour(12)
    Q().trackSite(child, e, now())
    H.advance(10)
    Q().trackSite(child, e, now())
    H.eq(child.progress, 0, "no watch by day")
    H.ok(child.waitNight)
    H.eq(overheadOf("night_wait"), 1, "told once to come back after dark")
    W().tick({}, now())
    H.eq(child.waves or 0, 0, "no pack by day")
    setHour(22)
    Q().trackSite(child, e, now())
    H.advance(10)
    Q().trackSite(child, e, now())
    H.eq(child.progress, 10, "the watch counts at night, from nightfall on")
    H.ok(not child.waitNight)
    W().tick({}, now())
    H.eq(child.waves, 1, "packs come at night")
end

function T.night_horde_appears_and_counts_only_at_night()
    local p, ps = base()
    StoryEngine.Store.STAGE_MAX_TIER = { 5, 5, 5 }
    local q = Q().proposeHorde(p, ps, "guard", 3, now())
    H.ok(q and q.state == "proposed")
    local item
    for _, it in ipairs(Q().listFor(ps.key, now())) do if it.id == q.id then item = it end end
    H.ok(item.nightChoice and item.nightMult == 1.5, "the quest tab offers day or night")
    local dayLen = Q().deadlineMinutes(q.distance or 0)
    setHour(12)
    H.ok(Q().respond(p, q.id, true, true))
    H.ok(q.night, "accepted by night")
    H.eq(q.deadlineT - now().t, dayLen + 24 * 60, "a day more")
    -- 낮에는 나타나지 않는다
    local sq = { getX = function() return q.x end, getY = function() return q.y end }
    H.cell.getGridSquare = function() return sq end
    for _ = 1, 3 do
        H.advance(1)
        Q().track({}, now())
    end
    H.ok(not q.spawned and q.waitNight, "nothing there by day")
    H.eq(#spawned, 0)
    setHour(22)
    for _ = 1, 3 do
        H.advance(1)
        Q().track({}, now())
    end
    H.ok(q.spawned, "they gather after dark")
    H.eq(spawned[1], q.size)
    -- 밤에 잡은 것만
    local zed = { getX = function() return q.cx end, getY = function() return q.cy end }
    Q().onZombieDead(zed)
    H.eq(q.killed, 1)
    setHour(10)
    Q().onZombieDead(zed)
    H.eq(q.killed, 1, "day kills do not count")
    H.eq(overheadOf("night_daykill"), 1)
    -- 다음 밤: 모자라면 다시 채운다
    setHour(22)
    local near = { { player = p, ps = ps, s = { x = q.cx, y = q.cy } } }
    Q().track(near, now())
    H.eq(spawned[2], q.killsNeeded - 1, "topped up to what is still needed")
    Q().track(near, now())
    H.eq(#spawned, 2, "once a night")
    -- 해내면 신뢰도·보상이 1.5배
    local trust = StoryEngine.Radio.channel("guard").trust
    local mults = {}
    local realRoll = StoryEngine.Loot.roll
    StoryEngine.Loot.roll = function(tier, fid, mult)
        mults[#mults + 1] = mult
        return realRoll(tier, fid, mult)
    end
    q.killed = q.killsNeeded - 1
    Q().onZombieDead(zed)
    StoryEngine.Loot.roll = realRoll
    H.eq(q.state, "completed")
    H.eq(mults[1], 1.5, "reward goods x1.5")
    H.eq(StoryEngine.Radio.channel("guard").trust - trust, 5, "trust 3 x 1.5 rounded up")
end

function T.accepting_by_day_stays_a_day_job()
    local p, ps = base()
    local q = Q().proposeHorde(p, ps, "guard", 3, now())
    local dayLen = Q().deadlineMinutes(q.distance or 0)
    H.ok(Q().respond(p, q.id, true, false))
    H.ok(not q.night)
    H.eq(q.deadlineT - now().t, dayLen)
    local low = Q().proposeHorde(p, ps, "ray", 2, now())
    H.ok(Q().respond(p, low.id, true, true))
    H.ok(not low.night, "tier 2 has no night version")
end

function T.some_story_clearings_are_night_only()
    local p, ps = base()
    SandboxVars.StoryEngine.NightStoryChance = 100
    local q = Q().proposeHorde(p, ps, "guard", 3, now(), { story = { faction = "guard", node = "guard2a_5" } })
    H.ok(q.night and q.nightForced, "night-only request")
    local item
    for _, it in ipairs(Q().listFor(ps.key, now())) do if it.id == q.id then item = it end end
    H.ok(item.nightForced and not item.nightChoice, "no choice to make")
    local b = H.lastBridge("radio", "request")
    H.ok(b and string.find(b.payload.topic, "after dark", 1, true), "the contact says so")
    H.ok(Q().respond(p, q.id, true, false))
    H.ok(q.night, "accepting does not undo it")
    SandboxVars.StoryEngine.NightStoryChance = 0
    local free = Q().proposeHorde(p, ps, "ray", 3, now(), { story = { faction = "ray", node = "ray2a_3" } })
    H.ok(not free.nightForced, "the rest are a choice")
    SandboxVars.StoryEngine.NightStoryChance = 100
    local low = Q().proposeHorde(p, ps, "doc", 2, now(), { story = { faction = "doc", node = "doc3_3" } })
    H.ok(not low.night, "not below the minimum tier")
    SandboxVars.StoryEngine.NightJobs = false
    local off = Q().proposeHorde(p, ps, "pike", 3, now(), { story = { faction = "pike", node = "pike3_4" } })
    H.ok(not off.night, "nothing is night-only when the option is off")
    SandboxVars.StoryEngine.NightJobs = nil
    SandboxVars.StoryEngine.NightStoryChance = nil
end

function T.night_courier_runs_within_the_night()
    local p, ps, trade, pickup = job("courier", 3, true)
    H.eq(pickup.kind, "fetch")
    H.ok(pickup.night, "the parcel is a night pick-up")
    -- 낮에는 꾸러미가 없다
    local sq = { getX = function() return pickup.x end, getY = function() return pickup.y end }
    H.cell.getGridSquare = function() return sq end
    setHour(12)
    for _ = 1, 3 do
        H.advance(1)
        Q().track({}, now())
    end
    H.ok(not pickup.spawned and pickup.waitNight, "no parcel by day")
    -- 밤에 챙겼다
    setHour(22)
    H.give(p, "StoryEngine.SealedParcel", { questTag = pickup.id })
    Q().setState(pickup, "retrieved", now(), { ps = ps })
    local drop = quest(trade.workId)
    H.ok(drop and drop.kind == "visit" and drop.night, "the drop-off is by night too")
    local here = { { player = p, ps = ps, s = { x = drop.cx, y = drop.cy } } }
    -- 동이 트면 꾸러미가 상한다 (한 번)
    setHour(6)
    W().parcelDawn(now())
    H.eq(drop.parcel, W().PARCEL_MAX - W().PARCEL_DAWN)
    W().parcelDawn(now())
    H.eq(drop.parcel, W().PARCEL_MAX - W().PARCEL_DAWN, "once per night")
    H.eq(overheadOf("parcel_dawn"), 1)
    -- 낮에는 건넬 수 없다
    Q().trackSite(drop, here, now())
    H.eq(drop.state, "accepted", "nobody takes it by day")
    H.ok(drop.waitNight)
    setHour(22)
    Q().trackSite(drop, here, now())
    H.eq(drop.state, "completed")
    H.eq(trade.state, "completed")
end

function T.night_work_pays_more_on_top()
    H.defineItem("Base.Pistol", "firearm", 30)
    H.defineItem("Base.Crisps", "food", 0.5)
    H.defineItem("Base.Beans", "food", 4)
    local Work = W()
    H.eq(#Work.scaleUp({ "Base.Beans", "Base.Beans" }, 1), 2, "no change by day")
    -- 8 의 절반(4) 만큼 새 묶음에서 더
    local out = Work.scaleUp({ "Base.Beans", "Base.Beans" }, 1.5, { "Base.Pistol", "Base.Beans", "Base.Crisps", "Base.Beans" })
    H.eq(#out, 3, "one more tin fits the extra half")
    H.eq(out[3], "Base.Beans")
    -- 물건 하나짜리 덤: 남은 몫이 값의 절반 이상이면 하나 더
    H.eq(#Work.scaleUp({ "Base.Beans" }, 1.5), 2)
    -- 일을 밤에 해내면 덤이 는다
    local p, ps, trade, child = job("horde", 3, true, "guard")
    H.ok(child.night and trade.nightWork)
    local rolls = 0
    local realBonus = Work.bonusGoods
    Work.bonusGoods = function(t)
        rolls = rolls + 1
        return { "Base.Beans", "Base.Beans" }
    end
    Q().completeHorde(child)
    Work.bonusGoods = realBonus
    H.eq(trade.state, "completed")
    H.eq(rolls, 2, "a second bundle to draw the extra from")
    H.eq(#trade.workBonus, 3, "two tins of extra became three")
    H.eq(#deliveriesFor(trade.id)[1].items, #trade.goods + 3, "the goods bought stay the same")
end

function T.night_volunteer_job_earns_more_trust()
    local p, ps = base()
    StoryEngine.Store.STAGE_MAX_TIER = { 5, 5, 5 }
    StoryEngine.Radio.channel("ray").trust = 45        -- 일거리 3등급
    local Work = W()
    local st = Work.volunteerStatus("ray", ps.key)
    H.eq(st.tier, 3)
    H.eq(st.gain, 6)
    H.eq(st.nightGain, 9, "night: 6 x 1.5")
    local ok, how = Work.volunteer(p, "ray", "guard", true)
    H.ok(ok and how == "guard")
    local parent
    for _, q in pairs(StoryEngine.Store.data().quests) do
        if q.kind == "volunteer" then parent = q end
    end
    H.ok(parent.nightWork and quest(parent.workId).night)
    H.eq(parent.gain, 9)
    local food = StoryEngine.Life.npc("ray").res.food
    Q().setState(quest(parent.workId), "completed", now(), nil)
    H.eq(StoryEngine.Radio.channel("ray").trust, 54, "trust +9")
    H.eq(StoryEngine.Life.npc("ray").res.food, math.min(100, food + 45), "resources x1.5 too")
    -- 등급이 안 되면 야간이 없다
    StoryEngine.Radio.channel("doc").trust = 25
    H.eq(Work.volunteerStatus("doc", ps.key).nightGain, nil)
end

return T
