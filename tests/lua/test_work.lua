-- 물건 대신 다른 대가 (Work.lua): 일로 갚기(소탕·찾아오기·정찰·경비·배달), 외상, 빚, 주 2회 제한,
-- 덤은 소탕·경비만, 외상·빚을 안 갚으면 크게 감점 + 2주 금지
local T = {}

-- 플레이어(10000,10000) 둘레에 건물 고리 (등급 1·2 거리)
local function mockBuildings()
    local defs = {}
    for _, d in ipairs({ 120, 160, 300, 380 }) do
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

local function setup(fid, trust)
    mockBuildings()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    SandboxVars.StoryEngine.ModItemsRatio = 0
    StoryEngine.Life.daily()
    StoryEngine.Trade.FREE_CHANCE = 0
    fid = fid or "ray"
    StoryEngine.Radio.channel(fid).trust = trust or 65
    local category = fid == "guard" and "food" or (fid == "hunter" and "melee" or "food")
    local q = StoryEngine.Trade.fromReply(fid, ps, { action = "offer", category = category, tier = 2,
                                                    pay_category = StoryEngine.Value.WANTS[fid][1] })
    H.ok(q and q.state == "proposed", "offer made")
    return p, ps, q
end

local function quest(id) return StoryEngine.Store.data().quests[id] end

local function deliveriesFor(qid)
    local out = {}
    for _, d in pairs(StoryEngine.Store.data().quests) do
        if d.kind == "supply_drop" and d.origin and d.origin.rewardFor == qid then out[#out + 1] = d end
    end
    return out
end

local function hasReason(fid, reason)
    for _, m in ipairs(StoryEngine.Radio.channel(fid).messages) do
        if m.from == "system" and m.reason == reason then return true end
    end
    return false
end

function T.options_follow_the_npc_and_trust()
    local _, _, q = setup("ray", 65)
    local opts, left = StoryEngine.Work.options(q)
    local by = {}
    for _, o in ipairs(opts) do by[o.how] = o end
    H.ok(by.fetch and by.fetch.ok and by.courier and by.credit and by.credit.ok and by.favor and by.favor.ok)
    H.ok(by.horde == nil, "ray does not take horde clearing")
    H.eq(left, 2)
    StoryEngine.Radio.channel("ray").trust = 45
    opts = StoryEngine.Work.options(q)
    for _, o in ipairs(opts) do by[o.how] = o end
    H.ok(not by.credit.ok and by.credit.why == "trust" and by.credit.need == 60, "credit needs 60")
end

function T.fetch_work_pays_the_trade_without_a_bonus()
    local p, ps, q = setup("ray", 65)
    local trust0 = StoryEngine.Radio.channel("ray").trust
    H.ok(StoryEngine.Work.choose(p, q.id, "fetch"))
    H.eq(q.state, "accepted")
    H.eq(q.payKind, "fetch")
    local child = quest(q.workId)
    H.ok(child and child.kind == "fetch" and child.origin.work == q.id, "fetch job")
    H.ok(StoryEngine.Quests.isManaged(child), "no reward of its own")
    StoryEngine.Quests.setState(child, "completed", StoryEngine.Sensor.now(), { ps = ps })
    H.eq(q.state, "completed", "trade paid by work")
    local deliveries = deliveriesFor(q.id)
    H.eq(#deliveries, 1, "one delivery")
    H.eq(#deliveries[1].items, #q.goods, "easy job: goods only")
    H.ok(q.workBonus == nil)
    H.eq(#deliveriesFor(child.id), 0, "no reward cache for the job")
    H.ok(StoryEngine.Radio.channel("ray").trust > trust0, "trade trust as usual")
end

function T.horde_work_completes_without_its_own_reward()
    local p, ps, q = setup("guard", 70)
    H.ok(StoryEngine.Work.choose(p, q.id, "horde"))
    local child = quest(q.workId)
    H.eq(child.kind, "horde")
    H.eq(child.size, StoryEngine.Quests.zombieCount(StoryEngine.Quests.HORDE_SIZE[2]))
    StoryEngine.Quests.completeHorde(child)
    H.eq(q.state, "completed")
    H.eq(#deliveriesFor(child.id), 0)
    local deliveries = deliveriesFor(q.id)
    H.eq(#deliveries, 1)
    H.ok(#deliveries[1].items > #q.goods and q.workBonus, "hard job: goods plus extra")
end

function T.weekly_limit_two_per_npc()
    local p, _, q = setup("ray", 65)
    local ch = StoryEngine.Radio.channel("ray")
    local t = StoryEngine.Sensor.now().t
    ch.workLog = { t - 10, t - 20 }
    local ok, why = StoryEngine.Work.choose(p, q.id, "fetch")
    H.ok(not ok and why == "week")
    H.advanceDays(7)
    H.ok(StoryEngine.Work.check("ray", "fetch"), "a week later it opens again")
end

function T.courier_pickup_then_dropoff_with_the_parcel()
    local p, ps, q = setup("ray", 65)
    H.ok(StoryEngine.Work.choose(p, q.id, "courier"))
    local pickup = quest(q.workId)
    H.eq(pickup.origin.stage, "pickup")
    StoryEngine.Quests.setState(pickup, "retrieved", StoryEngine.Sensor.now(), { ps = ps })
    H.eq(pickup.state, "completed")
    local drop = quest(q.workId)
    H.ok(drop and drop.kind == "visit" and drop.carry and drop.carry.qid == pickup.id, "dropoff with the parcel")
    local now = StoryEngine.Sensor.now()
    -- 꾸러미 없이 가면 안 끝난다
    StoryEngine.Quests.trackSite(drop, { { player = p, ps = ps, s = { x = drop.cx, y = drop.cy } } }, now)
    H.eq(drop.state, "accepted")
    H.give(p, "StoryEngine.SealedParcel", { questTag = pickup.id })
    StoryEngine.Quests.trackSite(drop, { { player = p, ps = ps, s = { x = drop.cx, y = drop.cy } } }, now)
    H.eq(drop.state, "completed")
    H.eq(q.state, "completed")
end

function T.guard_work_brings_waves_while_present()
    local p, ps, q = setup("pike", 65)
    H.ok(StoryEngine.Work.choose(p, q.id, "guard"))
    local child = quest(q.workId)
    H.eq(child.kind, "defend")
    H.eq(child.needMin, StoryEngine.Work.GUARD_MIN[2])
    child.present = 1
    StoryEngine.Work.tick({}, StoryEngine.Sensor.now())
    H.eq(child.waves, 1)
    H.ok(H.logHas("work guard wave"))
end

function T.credit_delivers_now_and_defaulting_costs_double()
    local p, ps, q = setup("ray", 65)
    local price = q.price
    H.ok(StoryEngine.Work.choose(p, q.id, "credit"))
    H.eq(q.price, math.ceil(price * 1.1), "a little interest")
    H.eq(#deliveriesFor(q.id), 1, "goods sent now")
    H.eq(q.state, "accepted", "still owes the payment")
    local before = StoryEngine.Radio.channel("ray").trust
    H.advance(13 * 24 * 60)
    StoryEngine.Quests.track({}, StoryEngine.Sensor.now())
    H.eq(q.state, "accepted", "two weeks to pay")
    H.advance(2 * 24 * 60)
    StoryEngine.Quests.track({}, StoryEngine.Sensor.now())
    H.eq(q.state, "failed")
    H.ok(hasReason("ray", "credit_default"), "extra penalty line")
    H.ok(before - StoryEngine.Radio.channel("ray").trust >= StoryEngine.Work.DEFAULT_PENALTY[2], "big drop")
    local ok, why = StoryEngine.Work.check("ray", "credit")
    H.ok(not ok and why == "burned", "no credit for two weeks")
    H.ok(StoryEngine.Work.check("ray", "fetch"), "work is still fine")
end

function T.credit_paid_does_not_deliver_twice()
    local p, ps, q = setup("ray", 65)
    H.ok(StoryEngine.Work.choose(p, q.id, "credit"))
    StoryEngine.Quests.completeTrade(p, q)
    H.eq(q.state, "completed")
    H.eq(#deliveriesFor(q.id), 1)
end

function T.favor_is_called_in_and_refusing_costs_double()
    local p, ps, q = setup("ray", 65)
    local trust0 = StoryEngine.Radio.channel("ray").trust
    H.ok(StoryEngine.Work.choose(p, q.id, "favor"))
    H.eq(q.state, "completed")
    H.eq(StoryEngine.Radio.channel("ray").trust, trust0, "no trust for a free deal")
    local ch = StoryEngine.Radio.channel("ray")
    H.ok(ch.favorOwed and ch.favorOwed.key == ps.key)
    local ok, why = StoryEngine.Work.check("ray", "favor")
    H.ok(not ok and why == "owed", "one favor at a time")
    H.advanceDays(2)
    StoryEngine.Work.callFavors(StoryEngine.Sensor.now())
    local call = quest(ch.favorOwed.called)
    H.ok(call and call.kind == "deliver" and call.favorCall, "favor called in")
    local before = ch.trust
    H.ok(StoryEngine.Quests.respond(p, call.id, false))
    H.ok(ch.favorOwed == nil, "settled")
    H.ok(hasReason("ray", "favor_broken"))
    H.ok(before - ch.trust >= StoryEngine.Work.DEFAULT_PENALTY[1], "big drop")
    H.eq(select(2, StoryEngine.Work.check("ray", "favor")), "burned")
end

function T.trade_failing_cancels_the_job()
    local p, ps, q = setup("ray", 65)
    H.ok(StoryEngine.Work.choose(p, q.id, "fetch"))
    local child = quest(q.workId)
    q.deadlineT = 0
    child.deadlineT = 10 ^ 9
    StoryEngine.Quests.track({}, StoryEngine.Sensor.now())
    H.eq(q.state, "failed")
    H.eq(child.state, "failed")
end


function T.easy_jobs_only_below_the_top_tier()
    local p, ps, q = setup("ray", 45)          -- 신뢰도 45: 음식은 3등급까지
    q.tier = 3
    local ok, why, top = StoryEngine.Work.check("ray", "fetch", q)
    H.ok(not ok and why == "tier" and top == 2, "tier 3 is the top, easy jobs need tier 2 or lower")
    H.eq(select(2, StoryEngine.Work.check("ray", "courier", q)), "tier")
    q.tier = 2
    H.ok(StoryEngine.Work.check("ray", "fetch", q))
end

function T.hard_jobs_have_no_tier_limit()
    local _, _, gq = setup("guard", 70)
    gq.tier = StoryEngine.Work.maxTier("guard", gq.category)
    H.ok(StoryEngine.Work.check("guard", "horde", gq))
end

function T.catalog_lists_bundles_and_asking_for_one_gives_it_exactly()
    mockBuildings()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    SandboxVars.StoryEngine.ModItemsRatio = 0
    StoryEngine.Life.daily()
    StoryEngine.Trade.FREE_CHANCE = 0
    StoryEngine.Radio.channel("doc").trust = 65
    local opts = StoryEngine.Trade.options("doc", ps)
    local med = nil
    for _, it in ipairs(opts.items) do if it.category == "medical" then med = it end end
    H.ok(med and #med.tiers == 5, "five medical tiers listed")
    local b = med.tiers[2][1]
    H.ok(b.items and b.price and b.price > 0, "bundle with a price")
    H.ok(med.tiers[5][1].price, "locked tiers still show their bundles")
    H.ok(StoryEngine.Trade.ask(p, "doc", "medical", 2, 1))
    local deal = StoryEngine.Quests.openTrade("doc")
    local want = {}
    for _, e in ipairs(b.items) do want[e[1]] = (want[e[1]] or 0) + e[2] end
    local got = {}
    for _, ft in ipairs(deal.goods) do got[ft] = (got[ft] or 0) + 1 end
    for ft, n in pairs(want) do H.eq(got[ft], n, ft) end
    H.eq(deal.price, b.price, "same price as the list")
end

return T
