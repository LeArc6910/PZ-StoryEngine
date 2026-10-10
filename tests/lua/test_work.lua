-- 물건 대신 다른 대가 (Work.lua): 일로 갚기(무작위: 소탕·정찰·경비·배달, 모두 덤), 외상, 빚, 주 2회 제한,
-- 외상·빚을 안 갚으면 크게 감점 + 2주 금지 (2026-10-05 개편: 모든 NPC, 등급 제한 없음)
local T = {}

-- 플레이어(10000,10000) 둘레에 건물 고리 (등급 1·2 거리)
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
    local by, n = {}, 0
    for _, o in ipairs(opts) do
        by[o.how] = o
        n = n + 1
    end
    H.eq(n, 3, "work (one button), credit, favor")
    H.ok(by.labor and by.labor.ok and by.credit and by.credit.ok and by.favor and by.favor.ok)
    H.eq(left, 2)
    StoryEngine.Radio.channel("ray").trust = 45
    opts = StoryEngine.Work.options(q)
    for _, o in ipairs(opts) do by[o.how] = o end
    H.ok(not by.credit.ok and by.credit.why == "trust" and by.credit.need == 60, "credit needs 60")
end

function T.every_npc_takes_every_method()
    for _, f in ipairs(StoryEngine.Factions.list) do
        for _, how in ipairs({ "labor", "horde", "scout", "guard", "courier", "credit", "favor" }) do
            H.ok(select(2, StoryEngine.Work.check(f.id, how)) ~= "kind", f.id .. " " .. how)
        end
        H.ok(select(2, StoryEngine.Work.check(f.id, "fetch")) == "kind", "fetch is gone")
    end
end

function T.labor_picks_a_random_job()
    local p, _, q = setup("ray", 65)
    local ok, how = StoryEngine.Work.choose(p, q.id, "labor")
    H.ok(ok and StoryEngine.Work.LABOR[how], "a labor kind was picked")
    H.eq(q.payKind, how)
    H.eq(quest(q.workId).origin.workKind, how)
    local ok2, why = StoryEngine.Work.choose(p, q.id, "labor")
    H.ok(not ok2 and why == "not_open", "no rerolling")
end

function T.any_tradable_tier_can_be_paid_with_work()
    local p, ps, q = setup("ray", 45)          -- 신뢰도 45: 음식은 3등급까지
    q.tier = 3
    H.ok(StoryEngine.Work.check("ray", "labor", q), "top tier is fine")
    H.ok(StoryEngine.Work.choose(p, q.id, "labor", "courier"))
end

function T.scout_visits_points_inside_and_pays_with_a_bonus()
    local p, ps, q = setup("ray", 65)
    H.ok(StoryEngine.Work.choose(p, q.id, "labor", "scout"))
    local child = quest(q.workId)
    H.eq(child.kind, "scout")
    H.eq(#child.points, StoryEngine.Work.SCOUT_POINTS[2], "tier 2: two points")
    H.eq(child.zombies, 2 * StoryEngine.Work.SCOUT_ZOMBIES)
    H.ok(not child.night, "a day job unless night is chosen")
    local function at(inside)
        return { { player = p, ps = ps, s = { x = child.cx, y = child.cy, building = inside and child.building or nil } } }
    end
    StoryEngine.Quests.trackSite(child, at(false), StoryEngine.Sensor.now())
    for _ = 1, 3 do
        H.advance(10)
        StoryEngine.Quests.trackSite(child, at(false), StoryEngine.Sensor.now())
    end
    H.eq(child.point, 1, "staying is not enough without going inside")
    StoryEngine.Quests.trackSite(child, at(true), StoryEngine.Sensor.now())
    H.eq(child.point, 2, "inside + 20 minutes -> next point")
    H.eq(child.spawned, false, "zombies for the next building")
    StoryEngine.Quests.trackSite(child, at(true), StoryEngine.Sensor.now())
    for _ = 1, 2 do
        H.advance(10)
        StoryEngine.Quests.trackSite(child, at(true), StoryEngine.Sensor.now())
    end
    H.eq(child.state, "completed")
    H.eq(q.state, "completed")
    local deliveries = deliveriesFor(q.id)
    H.eq(#deliveries, 1)
    H.ok(#deliveries[1].items > #q.goods and q.workBonus, "scouting gets the extra too")
end

function T.scout_chosen_by_night_only_counts_at_night()
    local p, ps, q = setup("ray", 45)
    q.tier = 3
    H.ok(StoryEngine.Work.choose(p, q.id, "labor", "scout", true))
    local child = quest(q.workId)
    H.ok(child.night, "night only")
    H.ok(#child.points >= 2, "several points (as many as the test map has)")
    local e = { { player = p, ps = ps, s = { x = child.cx, y = child.cy, building = child.building } } }
    StoryEngine.Quests.trackSite(child, e, StoryEngine.Sensor.now())
    H.advance(30)
    StoryEngine.Quests.trackSite(child, e, StoryEngine.Sensor.now())
    H.eq(child.progress, 0, "daytime does not count")
    H.ok(child.waitNight)
    local hour = getGameTime():getHour()
    H.advance(((22 - hour) % 24) * 60)
    StoryEngine.Quests.trackSite(child, e, StoryEngine.Sensor.now())
    H.advance(10)
    StoryEngine.Quests.trackSite(child, e, StoryEngine.Sensor.now())
    H.advance(10)
    StoryEngine.Quests.trackSite(child, e, StoryEngine.Sensor.now())
    H.eq(child.point, 2, "night: done")
end

function T.horde_work_completes_without_its_own_reward()
    local p, ps, q = setup("guard", 70)
    H.ok(StoryEngine.Work.choose(p, q.id, "labor", "horde"))
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
    local ok, why = StoryEngine.Work.choose(p, q.id, "labor")
    H.ok(not ok and why == "week")
    H.advanceDays(7)
    H.ok(StoryEngine.Work.check("ray", "labor"), "a week later it opens again")
end

local function courierToDropoff(p, ps, q)
    H.ok(StoryEngine.Work.choose(p, q.id, "labor", "courier"))
    local pickup = quest(q.workId)
    H.eq(pickup.origin.stage, "pickup")
    local full = StoryEngine.Quests.deadlineMinutes(pickup.distance or 0)
    H.ok(pickup.deadlineT - StoryEngine.Sensor.now().t <= math.floor(full * 0.6) + 10, "short deadline")
    H.give(p, "StoryEngine.SealedParcel", { questTag = pickup.id })
    StoryEngine.Quests.setState(pickup, "retrieved", StoryEngine.Sensor.now(), { ps = ps })
    H.eq(pickup.state, "completed")
    local drop = quest(q.workId)
    H.ok(drop and drop.kind == "visit" and drop.carry and drop.carry.qid == pickup.id, "dropoff with the parcel")
    H.eq(drop.parcel, StoryEngine.Work.PARCEL_MAX)
    H.ok(H.logHas("work courier hunt"), "a pack follows the carrier")
    return pickup, drop
end

function T.courier_pickup_then_dropoff_with_the_parcel()
    local p, ps, q = setup("ray", 65)
    local _, drop = courierToDropoff(p, ps, q)
    local now = StoryEngine.Sensor.now()
    local parcel = p.items[#p.items]
    p.items[#p.items] = nil
    -- 꾸러미 없이 가면 안 끝난다
    StoryEngine.Quests.trackSite(drop, { { player = p, ps = ps, s = { x = drop.cx, y = drop.cy } } }, now)
    H.eq(drop.state, "accepted")
    p.items[#p.items + 1] = parcel
    StoryEngine.Quests.trackSite(drop, { { player = p, ps = ps, s = { x = drop.cx, y = drop.cy } } }, now)
    H.eq(drop.state, "completed")
    H.eq(q.state, "completed")
    H.ok(q.workBonus, "an intact parcel gets the full extra")
end

function T.courier_parcel_damage_cuts_the_extra_then_the_goods()
    local p, ps, q = setup("ray", 65)
    local _, drop = courierToDropoff(p, ps, q)
    local hurt = { { player = p, ps = ps, s = { x = 0, y = 0 }, newHarm = { { kind = "deep" }, { kind = "fracture" } } } }
    StoryEngine.Work.parcelHarm(hurt)
    H.eq(drop.parcel, 80, "150 - 30 - 40")
    local other = H.addPlayer("other", "Ann", "Lee")
    StoryEngine.Work.parcelHarm({ { player = other, ps = StoryEngine.Store.player(other), s = {}, newHarm = { { kind = "cut" } } } })
    H.eq(drop.parcel, 80, "only the carrier's wounds count")
    StoryEngine.Quests.trackSite(drop, { { player = p, ps = ps, s = { x = drop.cx, y = drop.cy } } }, StoryEngine.Sensor.now())
    H.eq(q.state, "completed")
    H.ok(q.workBonus == nil, "below 100%: no extra")
    local deliveries = deliveriesFor(q.id)
    local sent = deliveries[1] and #deliveries[1].items or 0
    H.ok(sent < #q.goods, "below 100%: fewer goods")
    H.eq(q.parcel, 80)
end

function T.trim_keeps_value_share()
    H.defineItem("Base.Pistol", "firearm", 30)
    H.defineItem("Base.Crisps", "food", 0.5)
    local list = { "Base.Pistol", "Base.Crisps", "Base.Crisps" }
    H.eq(#StoryEngine.Work.trim(list, 1), 3)
    H.eq(#StoryEngine.Work.trim(list, 0.5), 2, "pistol does not fit, the crisps do")
    H.eq(#StoryEngine.Work.trim(list, 0), 0)
end

function T.guard_work_brings_waves_while_present()
    local p, ps, q = setup("pike", 65)
    H.ok(StoryEngine.Work.choose(p, q.id, "labor", "guard"))
    local child = quest(q.workId)
    H.eq(child.kind, "defend")
    H.eq(child.needMin, StoryEngine.Work.GUARD_MIN[2])
    local size, waves, total = StoryEngine.Work.guardPlan(2)
    H.eq(total, StoryEngine.Quests.zombieCount(StoryEngine.Quests.HORDE_SIZE[2] * 1.5), "1.5x a clearing")
    H.eq(waves, 3, "90 minutes / 40 -> 3 waves")
    H.eq(size, 10)
    H.eq(child.waveSize, size)
    child.present = 1
    for _ = 1, 5 do
        StoryEngine.Work.tick({}, StoryEngine.Sensor.now())
        H.advance(40)
    end
    H.eq(child.waves, 3, "stops after the planned waves")
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
    H.ok(StoryEngine.Work.check("ray", "labor"), "work is still fine")
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
    H.ok(StoryEngine.Work.choose(p, q.id, "labor", "horde"))
    local child = quest(q.workId)
    q.deadlineT = 0
    child.deadlineT = 10 ^ 9
    StoryEngine.Quests.track({}, StoryEngine.Sensor.now())
    H.eq(q.state, "failed")
    H.eq(child.state, "failed")
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

-- 진행 무전 (2026-10-05): 일하는 사람 머리 위에 준비된 문장
local function notes(key)
    local out = {}
    for _, a in ipairs(H.sentOf("radioOverhead")) do
        if a.lt and a.lt.key == "IGUI_StoryEngine_WorkNote_" .. key then out[#out + 1] = a end
    end
    return out
end

function T.progress_notes_for_horde()
    local p, ps, q = setup("guard", 70)
    H.ok(StoryEngine.Work.choose(p, q.id, "labor", "horde"))
    local child = quest(q.workId)
    child.spawned = true
    for _ = 1, math.ceil(child.killsNeeded / 4) do
        StoryEngine.Quests.onZombieDead(H.newZombie(child.cx, child.cy))
    end
    H.eq(#notes("horde"), 1, "25% note")
    StoryEngine.Quests.onZombieDead(H.newZombie(child.cx, child.cy))
    H.eq(#notes("horde"), 1, "not every kill")
end

function T.progress_notes_for_guard()
    local p2, ps2, q2 = setup("pike", 65)
    H.ok(StoryEngine.Work.choose(p2, q2.id, "labor", "guard"))
    local g = quest(q2.workId)
    g.present = 1
    StoryEngine.Work.tick({}, StoryEngine.Sensor.now())
    H.eq(#notes("guard_wave"), 1, "wave warning")
    local e = { { player = p2, ps = ps2, s = { x = g.cx, y = g.cy } } }
    StoryEngine.Quests.trackSite(g, e, StoryEngine.Sensor.now())
    for _ = 1, 3 do
        H.advance(10)
        StoryEngine.Quests.trackSite(g, e, StoryEngine.Sensor.now())
    end
    H.ok(#notes("guard_pct") >= 1, "time progress")
end

function T.progress_notes_for_scout()
    local p, ps, q = setup("ray", 65)
    H.ok(StoryEngine.Work.choose(p, q.id, "labor", "scout"))
    local child = quest(q.workId)
    local e = { { player = p, ps = ps, s = { x = child.cx, y = child.cy, building = child.building } } }
    StoryEngine.Quests.trackSite(child, e, StoryEngine.Sensor.now())
    H.eq(#notes("scout_entered"), 1)
    for _ = 1, 2 do
        H.advance(10)
        StoryEngine.Quests.trackSite(child, e, StoryEngine.Sensor.now())
    end
    local next = notes("scout_next")
    H.eq(#next, 1, "next point with directions")
    H.eq(#next[1].lt.args, 5)
end

function T.progress_notes_for_courier()
    local p2, ps2, q2 = setup("ray", 65)
    H.ok(StoryEngine.Work.choose(p2, q2.id, "labor", "courier"))
    local pickup = quest(q2.workId)
    H.give(p2, "StoryEngine.SealedParcel", { questTag = pickup.id })
    StoryEngine.Quests.setState(pickup, "retrieved", StoryEngine.Sensor.now(), { ps = ps2 })
    H.eq(#notes("courier_pickup"), 1, "drop-off directions")
    StoryEngine.Work.parcelHarm({ { player = p2, ps = ps2, s = {}, newHarm = { { kind = "cut" } } } })
    H.eq(#notes("parcel"), 1)
    StoryEngine.Work.parcelHarm({ { player = p2, ps = ps2, s = {}, newHarm = { { kind = "fracture" } } } })
    H.eq(#notes("parcel_low"), 1)
end

return T
