-- 밖에서 온 사람들 (Outsiders.lua, docs/PLAN_COUNCIL_POLITICS.md 7단계): 등장과 표결, 신뢰, 특기 여덟, 충성 시험, 떠남·추방
local T = {}

local function now() return StoryEngine.Sensor.now() end
local function P() return StoryEngine.Politics end
local function O() return StoryEngine.Outsiders end
local function trust(fid) return StoryEngine.Radio.channel(fid).trust end
local function setTrust(fid, v) StoryEngine.Radio.channel(fid).trust = v end
local function trustAll(v)
    for _, f in ipairs(StoryEngine.Factions.list) do setTrust(f.id, v) end
end

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

-- 의회가 서고 정치가 열린 세계
local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    H.clockMin = 300 * 1440 + 8 * 60
    StoryEngine.Council.state().era = { day = 300, t = now().t }
    P().debug({ open = true })
    P().state().bill = nil
    P().state().nextBillT = now().t + 999 * 1440
    P().state().nextElectionT = now().t + 999 * 1440
    return p, ps
end

local function here(id) O().debug({ what = "arrive", id = id }) end

local function count(p, fullType)
    local n = 0
    for _, it in ipairs(p.items) do
        if it.fullType == fullType then n = n + 1 end
    end
    return n
end

function T.strangers_call_and_the_council_votes()
    setup()
    local Out, F = O(), StoryEngine.Factions
    H.ok(F.isOutsider("hale") and not F.isOutsider("ray"))
    H.ok(F.isGone("hale"), "nobody is here yet")
    H.eq(#F.all(), 8)
    Out.tick()
    H.eq(Out.state().pending, nil, "not for another two weeks or so")
    Out.state().queue = { "hale", "odell", "okafor", "abigail" }
    H.advanceDays(Out.FIRST_DAYS + 1)
    P().state().nextBillT = now().t + 999 * 1440
    P().state().nextElectionT = now().t + 999 * 1440
    Out.tick()
    H.eq(Out.state().pending, "hale")
    local bill = P().state().bill
    H.eq(bill.id, "admit")
    H.eq(bill.target, "hale")
    H.ok(bill.system)
    H.eq(P().need(bill, "guard"), 70, "those wary of them need more convincing")
    H.eq(P().need(bill, "ray"), 50)
    H.ok(F.isGone("hale"), "not until the vote")
    trustAll(60)
    local tally = P().vote(now())
    H.ok(tally.pass, "five of eight")
    H.eq(tally.no, 3)
    H.ok(not F.isGone("hale"))
    H.eq(trust("hale"), Out.START_TRUST)
    H.eq(#F.all(), 9)
    H.eq(Out.state().pending, nil)
    H.eq(#P().state().laws, 0, "admitting someone is not a law")
    local found = false
    for _, c in ipairs(StoryEngine.Radio.channelList("tester")) do
        if c.id == "hale" then found = c.outsider == true end
    end
    H.ok(found, "the new frequency is in the list")
    H.ok(#H.sentOf("outsiders") > 0)
    H.ok(H.lastBridge("radio"), "they introduce themselves")
    -- 다음 무리는 두 주 넘게 뒤에
    H.ok(Out.state().nextT - now().t >= Out.GAP_MIN_DAYS * 1440)
    H.advanceDays(5)
    Out.tick()
    H.eq(Out.state().pending, nil)
end

function T.a_refused_group_knocks_once_more()
    setup()
    local Out = O()
    Out.state().queue = { "odell" }
    Out.state().nextT = now().t
    Out.tick()
    H.eq(P().state().bill.id, "admit")
    trustAll(40)
    H.ok(not P().vote(now()).pass)
    H.ok(StoryEngine.Factions.isGone("odell"))
    H.eq(Out.state().queue[1], "odell", "they will ask again")
    Out.state().nextT = now().t
    Out.tick()
    P().vote(now())
    H.eq(#Out.state().queue, 0, "twice refused, they move on")
end

function T.specialties_open_with_trust_and_cost_the_wary()
    local p, ps = setup()
    mockBuildings()
    local Out, Quests = O(), StoryEngine.Quests
    here("hale")
    trustAll(60)
    H.eq(Out.status("hale", 1, ps.key).why, "trust", "35 is not enough")
    setTrust("hale", 45)
    H.ok(Out.status("hale", 1, ps.key).ok)
    H.eq(Out.status("hale", 2, ps.key).why, "trust", "the second one opens at 70")
    -- 대리 작전: 진행 중인 소탕을 대신 끝낸다
    local q = Quests.proposeHorde(p, ps, "ray", 2, now())
    H.ok(select(1, Out.use(p, "hale", 1, { quest = q.id })) == false, "not a job in progress yet")
    Quests.respond(p, q.id, true)
    H.ok(Quests.isActive(q))
    H.eq(Out.proxyList(ps.key)[1].id, q.id)
    q.night = true
    local ok, info = Out.use(p, "hale", 1, { quest = q.id })
    H.ok(ok, tostring(info))
    H.eq(q.state, "completed")
    H.eq(q.proxy, "hale")
    H.eq(Quests.bonusMult(q), 1, "no night bonus for a job done by proxy")
    H.eq(trust("guard"), 58, "each of the three wary of Hale loses two")
    H.eq(trust("rats"), 58)
    H.eq(trust("hunter"), 58)
    H.eq(trust("doc"), 60)
    local st = Out.status("hale", 1, ps.key)
    H.eq(st.why, "wait")
    H.ok(st.wait > 13 * 1440)
    H.eq(select(2, Out.use(p, "hale", 1, { quest = q.id })), "wait")
end

function T.the_airdrop_flies_you_and_sends_cover()
    local p, ps = setup()
    local Out = O()
    here("hale")
    setTrust("hale", 75)
    H.eq(select(2, Out.use(p, "hale", 2, { x = 10005, y = 10000 })), "out_near")
    H.eq(select(2, Out.use(p, "hale", 2, { x = 10500, y = 10000 })), "out_far")
    H.ok(Out.scan(p, 10100, 10000).ok)
    H.ok(select(1, Out.use(p, "hale", 2, { x = 10100, y = 10000 })))
    H.eq(#H.sentOf("spec2Teleport"), 0, "the helicopter needs ten minutes")
    H.advance(Out.AIRDROP_DELAY + 1)
    H.fire("EveryOneMinute")
    local tp = H.sentOf("spec2Teleport")
    H.eq(#tp, 1)
    H.eq(tp[1].x, 10100)
    H.advance(3)
    H.fire("EveryOneMinute")
    H.eq(#H.sentOf("specSnipe"), 1, "without A-Life the escort is covering fire")
    H.eq(H.sentOf("specSnipe")[1].count, Out.ESCORT_SNIPE)
end

function T.odell_takes_orders_and_buys_jewellery()
    local p, ps = setup()
    local Out, Value, Quests = O(), StoryEngine.Value, StoryEngine.Quests
    here("odell")
    H.defineItem("Base.Hammer", "tools", 4, 2)
    H.defineItem("Base.TinnedBeans", "food", 5, 2)
    StoryEngine.ItemPool.tradePool = function(cat)
        if cat == "tools" then return { [2] = { "Base.Hammer" } } end
        return {}
    end
    setTrust("odell", 36)
    local opts = StoryEngine.Trade.options("odell", ps)
    H.ok(opts.order and not opts.allowed, "the window opens but nothing can be ordered yet")
    setTrust("odell", 45)
    trustAll(50)
    opts = StoryEngine.Trade.options("odell", ps)
    H.ok(opts.allowed)
    H.eq(opts.items[1].category, "tools")
    H.eq(opts.items[1].tiers[2][1].price, 8, "twice what it is worth")
    H.eq(opts.items[1].tiers[2][1].items[1][1], "Base.Hammer")
    H.ok(StoryEngine.Trade.ask(p, "odell", "tools", 2, 1))
    local q = Quests.openTrade("odell", ps.key)
    H.ok(q, "a trade is open")
    H.eq(q.payCategory, "any")
    H.eq(q.price, 8)
    H.eq(trust("rats"), 48, "ordering is a use of the specialty")
    H.eq(Out.status("odell", 1, ps.key).why, "wait")
    -- 아무 품목이나 대가로
    local beans = H.give(p, "Base.TinnedBeans")
    H.ok(Value.payable(p, beans, "any"))
    H.ok(not Value.payable(p, beans, "tools"))
    -- 귀중품 수집
    setTrust("odell", 75)
    H.eq(Out.jewelValue("Base.Ring_Right_RingFinger_GoldDiamond"), 12)
    H.eq(Out.jewelValue("Base.Necklace_Silver"), 2)
    H.eq(Out.jewelValue("Base.Necklace_DogTag"), nil)
    H.eq(Out.jewelValue("Base.Hammer"), nil)
    H.eq(select(2, Out.use(p, "odell", 2)), "no_jewels")
    H.give(p, "Base.Ring_Right_RingFinger_GoldDiamond")
    H.give(p, "Base.Necklace_Silver")
    H.give(p, "Base.Earring_Dangly_Ruby", { worn = true })
    local ok, info = Out.use(p, "odell", 2)
    H.ok(ok, tostring(info))
    H.eq(info.info.scrip, 14)
    H.eq(count(p, "StoryEngine.Scrip"), 14)
    H.eq(count(p, "Base.Earring_Dangly_Ruby"), 1, "what you wear stays on you")
    local scrip
    for _, it in ipairs(p.items) do
        if it.fullType == "StoryEngine.Scrip" then scrip = it end
    end
    H.ok(Value.payable(p, scrip, "medical"), "scrip pays for anything")
    H.ok(Value.payable(p, scrip, "any"))
    H.ok(not Value.giftable(p, scrip), "but it is no gift")
    H.eq(Value.of("StoryEngine.Scrip"), 1)
end

function T.okafor_holds_the_infection_and_tunes_the_body()
    local p, ps = setup()
    local Out = O()
    here("okafor")
    setTrust("okafor", 75)
    H.eq(select(2, Out.use(p, "okafor", 1)), "not_infected")
    local bd = p:getBodyDamage()
    local sick = true
    function bd:IsInfected() return sick end
    function bd:isInfected() return sick end
    function bd:setInfected(v) sick = v end
    function bd:setInfectionLevel() end
    function bd:setInfectionTime() end
    function bd:setInfectionMortalityDuration() end
    H.ok(select(1, Out.use(p, "okafor", 1)))
    local fx = H.sentOf("outsiderFx")
    H.eq(fx[#fx].kind, "retard")
    H.eq(fx[#fx].minutes, Out.RETARD_DAYS * 1440)
    H.ok(sick, "it holds, it does not cure")
    H.ok(select(1, Out.use(p, "okafor", 2)))
    fx = H.sentOf("outsiderFx")
    H.eq(fx[#fx].kind, "regimen")
    H.eq(select(2, Out.use(p, "okafor", 2)), "wait")
    -- 오카포 편을 들었으면 (E11) 물리지 않고 옮은 감염은 고친다
    H.advanceDays(8)
    Out.state().here.okafor.sided = "out"
    H.ok(select(1, Out.use(p, "okafor", 1)))
    H.ok(not sick, "caught from a scratch: cured")
    sick = true
    H.advanceDays(8)
    p.parts[1] = { bitten = function() return true end, SetInfected = function() end }
    H.ok(select(1, Out.use(p, "okafor", 1)))
    H.ok(sick, "a bite can only be held")
    -- 떠나면 붙잡아 둔 것이 풀린다
    Out.leave("okafor", "left")
    fx = H.sentOf("outsiderFx")
    H.eq(fx[#fx].minutes, 0)
    H.eq(#Out.state().fx, 0)
end

function T.abigail_prays_and_lightens_the_load()
    local p, ps = setup()
    local Out = O()
    here("abigail")
    setTrust("abigail", 75)
    trustAll(50)
    H.eq(Out.miracle(p), false, "no prayer, no miracle")
    H.ok(select(1, Out.use(p, "abigail", 1)))
    H.eq(trust("pike"), 48)
    H.eq(Out.status("abigail", 1, ps.key).why, "armed", "it waits on you; the wait starts when it fires")
    H.ok(Out.payload(ps.key).list[1].armed)
    H.advanceDays(20)
    H.ok(Out.miracle(p))
    local fx = H.sentOf("outsiderFx")
    H.eq(fx[#fx].kind, "miracle")
    H.eq(fx[#fx].minutes, Out.MIRACLE_MIN)
    H.eq(Out.status("abigail", 1, ps.key).why, "wait")
    H.eq(Out.miracle(p), false, "only once")
    H.ok(select(1, Out.use(p, "abigail", 2)))
    fx = H.sentOf("outsiderFx")
    H.eq(fx[#fx].kind, "burden")
    H.eq(fx[#fx].minutes, Out.BURDEN_DAYS * 1440)
    -- 다시 접속하면 걸려 있는 효과를 다시 알려 준다
    local before = #H.sentOf("outsiderFx")
    Out.resend(p)
    H.ok(#H.sentOf("outsiderFx") > before)
end

function T.gifts_raise_trust_in_three_day_windows()
    local p, ps = setup()
    local Out = O()
    here("hale")
    H.defineItem("Base.TinnedBeans", "food", 6, 2)
    local ids = {}
    for i = 1, 3 do ids[i] = H.give(p, "Base.TinnedBeans"):getID() end
    local ok, info = Out.gift(p, "hale", ids)
    H.ok(ok, tostring(info))
    H.eq(info.value, 18)
    H.eq(trust("hale"), 37, "18 value is the second step")
    H.eq(count(p, "Base.TinnedBeans"), 0)
    ids = { H.give(p, "Base.TinnedBeans"):getID(), H.give(p, "Base.TinnedBeans"):getID() }
    H.ok(select(1, Out.gift(p, "hale", ids)))
    H.eq(trust("hale"), 38, "30 in all: the third step, once")
    ids = { H.give(p, "Base.TinnedBeans"):getID() }
    H.eq(select(2, Out.gift(p, "hale", ids)), "wait")
    H.eq(count(p, "Base.TinnedBeans"), 1, "nothing is taken when it would not count")
    H.advanceDays(Out.GIFT_DAYS)
    H.ok(select(1, Out.gift(p, "hale", ids)))
    H.eq(trust("hale"), 39)
    H.eq(select(2, Out.gift(p, "ray", {})), "gone", "only for those from outside")
end

function T.choosing_between_the_stranger_and_the_neighbour()
    local p, ps = setup()
    local Out, Spec = O(), StoryEngine.Specialty
    here("okafor")
    here("abigail")
    trustAll(60)
    Out.debug({ what = "test", id = "okafor" })
    local row = Out.payload(ps.key).list[1]
    H.eq(row.id, "okafor")
    H.eq(row.test.rival, "doc")
    H.eq(Out.side(p, "okafor", "maybe"), false)
    -- 밖에서 온 사람을 고르면: 닥의 1차 특기가 막힌다 (오카포가 머무는 동안)
    H.ok(Out.side(p, "okafor", "out"))
    H.ok(P().mod("specBlock", "doc"))
    H.eq(Spec.status("doc", ps.key).reason, "sided")
    H.ok(not P().mod("specBlock", "pike"))
    H.ok(not Out.hard("okafor"))
    Out.leave("okafor", "left")
    H.ok(not P().mod("specBlock", "doc"), "undone when they go")
    -- 원래 NPC 를 고르면: 얻는 것은 없고 그 사람이 식는다
    Out.debug({ what = "test", id = "abigail" })
    H.ok(Out.side(p, "abigail", "home"))
    H.ok(Out.hard("abigail"))
    H.ok(not P().mod("specBlock", "pike"))
    setTrust("abigail", 50)
    H.eq(StoryEngine.Trust.apply("abigail", 3, "quest_done"), 2, "half of what you earn, rounded up")
    local day = StoryEngine.Store.dayIndex(now().dayKey)
    Out.daily(now(), day)
    H.eq(trust("abigail"), 52, "one idle day is not yet two")
    Out.daily(now(), day + 1)
    H.eq(trust("abigail"), 51, "every second idle day costs one")
    -- 신뢰 30 미만이 사흘이면 떠난다
    setTrust("abigail", 29)
    Out.daily(now(), day + 2)
    Out.daily(now(), day + 3)
    H.ok(not StoryEngine.Factions.isGone("abigail"))
    Out.daily(now(), day + 4)
    H.ok(StoryEngine.Factions.isGone("abigail"), "three days under thirty")
    H.eq(Out.state().left.abigail.why, "left")
end

function T.sides_change_the_specialties()
    local p, ps = setup()
    local Out = O()
    here("hale")
    here("odell")
    trustAll(60)
    setTrust("hale", 75)
    Out.debug({ what = "test", id = "hale" })
    Out.side(p, "hale", "out")
    H.eq(P().mod("specWait", "guard"), 2)
    H.eq(P().mod("specCost", "guard"), 1.5)
    H.eq(P().mod("specWait", "ray"), 1)
    Out.state().here.hale.used[ps.key] = { [2] = now().t }
    H.ok(Out.status("hale", 2, ps.key).wait <= 4 * 1440, "the airdrop comes back in four days")
    Out.debug({ what = "test", id = "odell" })
    Out.side(p, "odell", "out")
    H.ok(P().mod("tradeBlock", "rats", "tools"), "Vic stops trading")
    local Life = StoryEngine.Life
    local before = {}
    for _, f in ipairs(StoryEngine.Factions.list) do before[f.id] = Life.npc(f.id).res.food end
    Out.daily(now(), 1)
    local hit = 0
    for _, f in ipairs(StoryEngine.Factions.list) do
        if Life.npc(f.id).res.food < before[f.id] then hit = hit + 1 end
    end
    H.eq(hit, 1, "and raids someone every week")
    H.eq(Life.npc("rats").res.food, before.rats)
end

function T.an_unanswered_test_costs_both()
    local p = setup()
    local Out = O()
    here("hale")
    trustAll(60)
    setTrust("hale", 50)
    Out.debug({ what = "test", id = "hale" })
    H.advance(Out.TEST_HOURS * 60 + 60)
    P().state().nextBillT = now().t + 999 * 1440
    P().state().nextElectionT = now().t + 999 * 1440
    Out.tick()
    H.eq(trust("hale"), 45)
    H.eq(trust("guard"), 55)
    H.eq(Out.state().here.hale.test, nil)
    H.ok(Out.state().here.hale.testT > now().t, "they will ask again")
end

function T.those_who_turn_away_stay_home_and_call_a_vote()
    local p, ps = setup()
    local Out = O()
    here("hale")
    trustAll(60)
    setTrust("guard", 20)
    H.ok(Out.absent("guard"))
    H.ok(not Out.absent("ray"))
    P().debug({ bill = "canteen" })
    local t = P().forecast(P().state().bill)
    H.eq(t.yes + t.no, 7, "one seat is empty")
    P().state().bill = nil
    -- 셋이 모두 등을 돌리면 추방 표결
    setTrust("rats", 20)
    setTrust("hunter", 20)
    Out.tick()
    local bill = P().state().bill
    H.eq(bill.id, "expel")
    H.eq(bill.target, "hale")
    H.eq(P().forecast(bill).yes, 3, "the three who want them gone do come to this vote")
    H.ok(not P().forecast(bill).pass)
    H.eq(select(2, P().lobby(p, "ray", "persuade", "for")), "no_lobby")
    H.ok(Out.stance(p, "hale", "expel"))
    H.ok(P().forecast(bill).pass, "those who trust us follow")
    H.ok(Out.stance(p, "hale", "keep"))
    H.ok(not P().forecast(bill).pass)
    P().vote(now())
    H.ok(not StoryEngine.Factions.isGone("hale"), "kept")
    H.eq(trust("hale"), Out.START_TRUST, "we spoke up, so nobody blames us for standing aside")
    Out.tick()
    H.eq(P().state().bill, nil, "no second vote for a month")
    -- 물러서 있으면 양쪽이 서운해한다
    Out.state().here.hale.expelT = nil
    Out.tick()
    P().vote(now())
    H.eq(trust("hale"), Out.START_TRUST - Out.ABSTAIN_COST)
    H.eq(trust("guard"), 15)
    -- 내보내자
    Out.state().here.hale.expelT = nil
    Out.tick()
    Out.stance(p, "hale", "expel")
    P().vote(now())
    H.ok(StoryEngine.Factions.isGone("hale"))
    H.eq(Out.state().left.hale.why, "expelled")
end

function T.outsiders_ask_for_things_and_the_ai_is_told()
    local p, ps = setup()
    mockBuildings()
    local Out, Quests = O(), StoryEngine.Quests
    here("okafor")
    trustAll(60)
    Out.state().here.okafor.askT = now().t
    Out.state().here.okafor.testT = now().t + 999 * 1440
    Out.tick()
    local q
    for _, x in pairs(StoryEngine.Store.data().quests) do
        if x.origin and x.origin.faction == "okafor" then q = x end
    end
    H.ok(q, "a request from the research team")
    H.ok(q.tier >= 3, "their asks are never small")
    H.ok(Out.state().here.okafor.askT > now().t)
    local before = trust("okafor")
    Quests.respond(p, q.id, false)
    H.ok(trust("okafor") < before, "turning them down costs trust like anyone else")
    -- 해 주면 여느 부탁처럼 신뢰가 오르고 보상이 온다
    SandboxVars.StoryEngine.RequestItemMode = 3
    Out.state().here.okafor.askT = now().t
    Out.tick()
    local q2
    for _, x in pairs(StoryEngine.Store.data().quests) do
        if x.origin and x.origin.faction == "okafor" and x.state == "proposed" then q2 = x end
    end
    H.ok(q2, "another request")
    Quests.respond(p, q2.id, true)
    for _, need in ipairs(q2.need) do
        for _ = 1, need[2] do H.give(p, need[1]) end
    end
    before = trust("okafor")
    local okS, whyS = Quests.submit(p, q2.id)
    H.ok(okS, tostring(whyS))
    H.eq(q2.state, "completed")
    H.ok(trust("okafor") > before)
    H.eq(StoryEngine.Radio.channel("okafor").deedDay, StoryEngine.Store.dayIndex(now().dayKey), "and it counts as a deed")
    SandboxVars.StoryEngine.RequestItemMode = nil
    -- AI 맥락
    local ctx = Out.context("doc")
    H.eq(ctx.here[1].id, "okafor")
    H.ok(ctx.here[1].disliked and ctx.here[1].rival)
    H.eq(Out.context("ray").here[1].disliked, nil)
    local self = Out.context("okafor").self
    H.eq(self.rival, StoryEngine.Stories.NAMES.doc)
    H.eq(#self.dislike, 3)
    -- 준비된 대사
    local lt = StoryEngine.Lines.lt("okafor", "request", {})
    H.eq(lt.key, "IGUI_StoryEngine_Line_okafor_request_1")
    H.eq(StoryEngine.Lines.lt("okafor", "horde_thanks", {}), nil, "kinds they have no line for fall back")
    -- 끄면 아무도 오지 않는다
    SandboxVars.StoryEngine.Outsiders = false
    H.ok(not Out.enabled())
    H.eq(Out.payload(ps.key), nil)
    SandboxVars.StoryEngine.Outsiders = nil
end

function T.volunteering_for_an_outsider_works()
    local p, ps = setup()
    mockBuildings()
    local Out, Work = O(), StoryEngine.Work
    here("hale")
    setTrust("hale", 25)            -- 2등급 일거리 (가까운 건물)
    local ok, kind = Work.volunteer(p, "hale", "horde")
    H.ok(ok, tostring(kind))
    local parent, child
    for _, q in pairs(StoryEngine.Store.data().quests) do
        if q.kind == "volunteer" then parent = q end
        if q.origin and q.origin.volunteer then child = q end
    end
    H.ok(parent and child)
    Work.volunteerEnd(parent, child, "completed", now())
    H.ok(trust("hale") > 25, "trust is all they can give")
end

return T
