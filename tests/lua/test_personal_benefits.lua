-- 개인 신뢰의 혜택 (docs/DESIGN_PER_PLAYER_TRUST.md 3·4·5-2절): 거래 한도·흥정, (NPC, 사람)마다 거래 하나,
-- 요청 횟수, 일로 갚기·외상·일거리 청하기, 특기 구간·대기 범위, 레이 보급, 선물 편지, 명절
local T = {}

-- 플레이어(10000,10000) 둘레에 건물 고리 (등급 1~4 거리)
local function mockBuildings()
    local defs = {}
    for _, d in ipairs({ 120, 160, 300, 380, 600, 700, 1200, 1500 }) do
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

local function Tr() return StoryEngine.Trust end
local function ch(fid) return StoryEngine.Radio.channel(fid) end

-- 두 사람 (개인 모드면 먼저 켠다)
local function setup(personal)
    if personal ~= false then H.personalMode() end
    mockBuildings()
    local a = H.addPlayer("alice", "Alice", "Ash")
    local b = H.addPlayer("bob", "Bob", "Birch")
    local pa, pb = StoryEngine.Store.player(a), StoryEngine.Store.player(b)
    pa.lang, pb.lang = "EN", "EN"
    SandboxVars.StoryEngine.ModItemsRatio = 0
    StoryEngine.Life.daily()
    StoryEngine.Trade.FREE_CHANCE = 0
    return a, b, pa, pb
end

-- 개인 신뢰를 정해 둔다 (처음 연락 후 값을 바꾼 것처럼)
local function setPersonal(fid, key, v)
    Tr().ensure(fid, key)
    ch(fid).personal[key] = v
end

local function quest(id) return StoryEngine.Store.data().quests[id] end

local function maxTierOf(ctx, cat)
    for _, g in ipairs(ctx.goods or {}) do
        if g.category == cat then return g.maxTier end
    end
    return 0
end

-- ---------------------------------------------------------------- 거래

function T.trade_limits_follow_each_players_personal_trust()
    local _, _, pa, pb = setup()
    ch("ray").trust = 90                             -- 무리의 신뢰는 혜택과 상관없다
    setPersonal("ray", pa.key, 65)
    setPersonal("ray", pb.key, 25)
    local ca = StoryEngine.Trade.context("ray", pa)
    local cb = StoryEngine.Trade.context("ray", pb)
    H.eq(ca.trust, 65)
    H.eq(maxTierOf(ca, "food"), 4, "alice 65 -> tier 4")
    H.eq(cb.trust, 25)
    H.eq(maxTierOf(cb, "food"), 2, "bob 25 -> tier 2")
    H.ok(ca.mult < cb.mult, "bob pays more")
    local blocked = StoryEngine.Trade.blocked("ray", "food", 4, pb.key)
    H.ok(blocked and blocked.need == 60 and blocked.have == 25, "bob is told his own trust")
    H.eq(StoryEngine.Trade.blocked("ray", "food", 4, pa.key), nil, "alice is not blocked")
    -- 버튼 거래 목록도 그 사람의 신뢰로
    local oa = StoryEngine.Trade.options("ray", pa)
    local ob = StoryEngine.Trade.options("ray", pb)
    H.eq(oa.trust, 65)
    H.eq(ob.trust, 25)
    H.ok(oa.personal, "catalog marks personal trust")
end

function T.offer_above_personal_limit_is_blocked()
    local _, _, pa, pb = setup()
    ch("ray").trust = 90
    setPersonal("ray", pb.key, 25)
    local q, how, info = StoryEngine.Trade.fromReply("ray", pb, { action = "offer", category = "food", tier = 3,
                                                                  pay_category = "medical" })
    H.eq(q, nil)
    H.eq(how, "blocked")
    H.ok(info and info.need == 40 and info.have == 25, "blocked by bob's own trust")
    setPersonal("ray", pa.key, 45)
    local qa = StoryEngine.Trade.fromReply("ray", pa, { action = "offer", category = "food", tier = 3,
                                                        pay_category = "medical" })
    H.ok(qa and qa.state == "proposed", "alice can")
end

function T.one_open_trade_per_person()
    local _, _, pa, pb = setup()
    setPersonal("ray", pa.key, 65)
    setPersonal("ray", pb.key, 65)
    local qa = StoryEngine.Trade.fromReply("ray", pa, { action = "offer", category = "food", tier = 2, pay_category = "medical" })
    H.ok(qa and qa.stockRef, "alice's offer from the stock")
    -- 재고는 NPC 공유: 알리스가 잡아 둔 묶음은 밥에게 나가지 않는다 (가짜 환경의 2등급 음식 재고는 한 묶음)
    local st = StoryEngine.Trade.stock("ray")
    H.eq(#st.cats.food[2], 1)
    H.ok(StoryEngine.Trade.reserved("ray", "food", 2, qa.stockRef.index), "alice's bundle is held for her")
    local none, how0, info0 = StoryEngine.Trade.fromReply("ray", pb, { action = "offer", category = "food", tier = 2,
                                                                       pay_category = "medical" })
    H.ok(none == nil and how0 == "blocked" and info0.soldOut, "bob: sold out while alice holds it")
    local foodRow = nil
    for _, it in ipairs(StoryEngine.Trade.options("ray", pb).items) do
        if it.category == "food" then foodRow = it end
    end
    H.ok(foodRow and foodRow.tiers[2][1].sold, "catalog shows it taken for bob")
    local qb = StoryEngine.Trade.fromReply("ray", pb, { action = "offer", category = "food", tier = 1, pay_category = "medical" })
    H.ok(qb and qb ~= qa, "bob gets his own offer even though alice has one open")
    H.eq(StoryEngine.Quests.openTrade("ray", pa.key), qa)
    H.eq(StoryEngine.Quests.openTrade("ray", pb.key), qb)
    -- 흥정은 자기 거래만
    local ctx = StoryEngine.Trade.context("ray", pb)
    H.ok(ctx.negotiating and ctx.deal.price == qb.price, "bob haggles over his own deal")
    local q, how = StoryEngine.Trade.negotiate("ray", pb, { action = "withdraw" })
    H.eq(q, qb)
    H.eq(how, "withdraw")
    H.eq(qa.state, "proposed", "alice's deal untouched")
end

function T.shared_mode_keeps_one_trade_per_npc()
    local _, _, pa, pb = setup(false)
    ch("ray").trust = 65
    local qa = StoryEngine.Trade.fromReply("ray", pa, { action = "offer", category = "food", tier = 2, pay_category = "medical" })
    H.ok(qa, "offer made")
    local ctx = StoryEngine.Trade.context("ray", pb)
    H.ok(ctx.negotiating and ctx.deal.price == qa.price, "bob sees alice's offer to haggle over")
    H.eq(StoryEngine.Trade.reserved("ray", "food", 2, qa.stockRef.index), false, "no reservation needed")
end

function T.request_counting_is_per_person()
    local _, _, pa, pb = setup()
    setPersonal("ray", pa.key, 50)
    setPersonal("ray", pb.key, 50)
    local group = ch("ray").trust
    local Trade = StoryEngine.Trade
    Trade.recordRequest("ray", pa)
    Trade.recordRequest("ray", pa)
    H.eq(Trade.recentRequests("ray", pa.key), 2)
    H.eq(Trade.recentRequests("ray", pb.key), 0, "bob's count is his own")
    H.eq(Tr().personal("ray", pa.key), 50, "two requests are fine")
    Trade.recordRequest("ray", pa)
    H.eq(Tr().personal("ray", pa.key), 49, "third request: alice -1")
    H.eq(Tr().personal("ray", pb.key), 50)
    H.eq(ch("ray").trust, group, "group trust untouched")
    H.ok(Trade.offerContext("ray", 50, pa.key).suspicious, "alice looks suspicious")
    H.ok(not Trade.offerContext("ray", 50, pb.key).suspicious, "bob does not")
end

function T.market_uses_the_speakers_trust_without_first_contact()
    local _, _, pa, pb = setup()
    setPersonal("doc", pa.key, 70)
    local m = StoryEngine.Trade.marketContext(pa)
    local doc = nil
    for _, s in ipairs(m.sellers or {}) do if s.id == "doc" then doc = s end end
    H.ok(doc and doc.trust == 70, "alice's own trust with doc")
    H.eq(Tr().known("ray", pa.key), false, "listing sellers is not first contact")
    local mb = StoryEngine.Trade.marketContext(pb)
    local docB = nil
    for _, s in ipairs(mb.sellers or {}) do if s.id == "doc" then docB = s end end
    H.ok(not docB or docB.trust < 70, "bob does not borrow alice's trust")
end

-- ---------------------------------------------------------------- 다른 대가·일거리

function T.credit_and_favor_need_the_choosers_trust_and_week_is_per_person()
    local a, b, pa, pb = setup()
    setPersonal("ray", pa.key, 65)
    setPersonal("ray", pb.key, 45)
    local Work = StoryEngine.Work
    H.eq(Work.check("ray", "credit", nil, pa.key), true, "alice 65: credit")
    local ok, why, need = Work.check("ray", "credit", nil, pb.key)
    H.ok(not ok and why == "trust" and need == 60, "bob 45: no credit")
    H.eq(Work.check("ray", "favor", nil, pb.key), true, "bob 45: favor")
    local qa = StoryEngine.Trade.fromReply("ray", pa, { action = "offer", category = "food", tier = 1, pay_category = "medical" })
    -- 남의 거래에는 대가 방식을 고를 수 없다
    local okB, whyB = Work.choose(b, qa.id, "credit")
    H.ok(not okB and whyB == "not_yours", "bob cannot pick for alice's deal")
    H.ok(Work.choose(a, qa.id, "credit"), "alice takes it on credit")
    H.eq(Work.weekUsed("ray", StoryEngine.Sensor.now().t, pa.key), 1)
    H.eq(Work.weekUsed("ray", StoryEngine.Sensor.now().t, pb.key), 0, "bob's week is his own")
    ch("ray").workLogBy[pa.key] = { StoryEngine.Sensor.now().t, StoryEngine.Sensor.now().t }
    local okW, whyW = Work.check("ray", "labor", nil, pa.key)
    H.ok(not okW and whyW == "week", "alice used her two")
    H.eq(Work.check("ray", "labor", nil, pb.key), true, "bob still can")
end

function T.default_burns_only_the_debtor()
    local a, _, pa, pb = setup()
    setPersonal("ray", pa.key, 70)
    setPersonal("ray", pb.key, 70)
    local group = ch("ray").trust
    local qa = StoryEngine.Trade.fromReply("ray", pa, { action = "offer", category = "food", tier = 1, pay_category = "medical" })
    H.ok(StoryEngine.Work.choose(a, qa.id, "credit"))
    StoryEngine.Quests.setState(qa, "failed", StoryEngine.Sensor.now(), nil)
    H.ok(Tr().personal("ray", pa.key) <= StoryEngine.Work.DEFAULT_TRUST_TO, "alice drops to 30 or below")
    H.eq(Tr().personal("ray", pb.key), 70, "bob untouched")
    H.eq(ch("ray").trust, group, "group untouched")
    local ok, why = StoryEngine.Work.check("ray", "credit", nil, pa.key)
    H.ok(not ok, "alice cannot take credit again soon (" .. tostring(why) .. ")")
    H.eq(StoryEngine.Work.check("ray", "credit", nil, pb.key), true, "bob is not burned")
end

function T.volunteer_tier_and_week_are_per_person()
    local a, b, pa, pb = setup()
    StoryEngine.Store.STAGE_MAX_TIER = { 5, 5, 5 }
    setPersonal("ray", pa.key, 65)
    setPersonal("ray", pb.key, 25)
    local Work = StoryEngine.Work
    H.eq(Work.volunteerStatus("ray", pa.key).tier, 4, "alice 65 -> tier 4")
    H.eq(Work.volunteerStatus("ray", pb.key).tier, 2, "bob 25 -> tier 2")
    H.ok(Work.volunteer(a, "ray", "horde"), "alice takes a job")
    H.ok(Work.volunteer(b, "ray", "horde"), "bob takes his own job at the same time")
    H.eq(Work.volunteerStatus("ray", pa.key).why, "open")
    H.eq(Work.volunteerStatus("ray", pa.key).left, 1)
    H.eq(Work.volunteerStatus("ray", pb.key).left, 1)
    local parentA = nil
    for _, q in pairs(StoryEngine.Store.data().quests) do
        if q.kind == "volunteer" and q.target == pa.key then parentA = q end
    end
    local group = ch("ray").trust
    StoryEngine.Quests.setState(quest(parentA.workId), "completed", StoryEngine.Sensor.now(), nil)
    H.eq(Tr().personal("ray", pa.key), 73, "alice +tier 4 x 2")
    H.eq(Tr().personal("ray", pb.key), 25)
    H.eq(ch("ray").trust, group, "group untouched")
end

function T.volunteer_status_does_not_make_first_contact()
    local _, _, pa = setup()
    StoryEngine.Work.volunteerStatus("hunter", pa.key)
    H.eq(Tr().known("hunter", pa.key), false)
end

-- ---------------------------------------------------------------- 특기

function T.specialty_tier_follows_the_requesters_trust()
    local _, _, pa, pb = setup()
    ch("hunter").trust = 0
    setPersonal("hunter", pa.key, 85)
    setPersonal("hunter", pb.key, 45)
    local Sp = StoryEngine.Specialty
    H.eq(Sp.status("hunter", pa.key).tier, 3)
    H.eq(Sp.status("hunter", pb.key).tier, 1)
    H.eq(Sp.status("hunter").reason, "low_trust", "no key: group trust")
    Sp.status("casey", pa.key)
    H.eq(Tr().known("casey", pa.key), false, "looking at the base tab is not first contact")
end

function T.server_wide_specialty_scope_becomes_both()
    local a, _, pa, pb = setup()
    local Sp = StoryEngine.Specialty
    H.eq(Sp.scope("ray"), 3, "ray's server-wide scope counts as both")
    H.eq(Sp.scope("hunter"), 2, "personal scope kept")
    setPersonal("ray", pa.key, 65)
    setPersonal("ray", pb.key, 65)
    local doc0 = Tr().personal("doc", pa.key)
    local docB = Tr().personal("doc", pb.key)
    local group = ch("doc").trust
    H.ok(Sp.request(a, "ray", { target = "doc" }), "ray's supply run")
    H.eq(Sp.status("ray", pb.key).wait, 24, "bob only waits a day")
    H.ok(Sp.status("ray", pa.key).wait > 24, "alice waits the full cooldown")
    H.eq(Tr().personal("doc", pa.key), doc0 + 1, "doc's +1 goes to alice")
    H.eq(Tr().personal("doc", pb.key), docB)
    H.eq(ch("doc").trust, group, "doc's group trust untouched")
end

function T.shared_mode_specialty_scope_unchanged()
    local a = setup(false)
    local Sp = StoryEngine.Specialty
    H.eq(Sp.scope("ray"), 1)
    ch("ray").trust = 65
    local group = ch("doc").trust
    H.ok(Sp.request(a, "ray", { target = "doc" }))
    H.eq(ch("doc").trust, group + 1, "shared: doc's single trust +1")
end

function T.ops_assist_uses_group_trust()
    local _, _, pa = setup()
    ch("hunter").trust = 85
    setPersonal("hunter", pa.key, 10)
    H.newZombie(10010, 10010)
    local a = H.players[1]
    H.ok(StoryEngine.Specialty.assist("hunter", a), "hank helps the operation")
    local sent = H.sentOf("specSnipe")
    H.eq(sent[#sent].count, 30, "tier 3 from group trust 85")
end

-- ---------------------------------------------------------------- 편지·명절

function T.gift_letter_needs_the_receivers_trust()
    local _, _, pa, pb = setup()
    StoryEngine.Letters.GIFT_CHANCE = 100
    ch("ray").trust = 90
    setPersonal("ray", pa.key, 80)
    setPersonal("ray", pb.key, 30)
    local now = StoryEngine.Sensor.now()
    local qa = { id = "QA", kind = "supply_drop", origin = { faction = "ray", friend = true }, target = pa.key, items = {} }
    local qb = { id = "QB", kind = "supply_drop", origin = { faction = "ray", friend = true }, target = pb.key, items = {} }
    H.ok(StoryEngine.Letters.attach(qa, pa, now), "alice gets a letter")
    H.eq(StoryEngine.Letters.attach(qb, pb, now), nil, "bob does not")
end

local function setDate(y, m, d, hour)
    H.gt.getYear = function() return y end
    H.gt.getMonth = function() return m - 1 end
    H.gt.getDay = function() return d - 1 end
    H.gt.getHour = function() return hour or 10 end
end

function T.holiday_help_is_group_work_with_a_helper_bonus()
    local a, _, pa, pb = setup()
    pa.lang, pb.lang = "KO", "KO"
    local Holiday = StoryEngine.Holiday
    setDate(1993, 9, 28, 10)
    Holiday.hourly(StoryEngine.Sensor.now())
    local inst = StoryEngine.Store.data().holiday.done["KO_chuseok_1993"]
    local q = quest(inst.collect)
    for _, n in ipairs(q.need) do
        for _ = 1, n[2] do H.give(a, n[1]) end
    end
    H.ok(StoryEngine.Quests.contribute(a, q))
    H.eq(q.state, "completed")
    local host = inst.host
    local group = ch(host).trust
    local mine = Tr().personal(host, pa.key)
    local bobs = Tr().personal(host, pb.key)
    setDate(1993, 9, 30, 10)
    Holiday.hourly(StoryEngine.Sensor.now())
    H.eq(inst.stage, "celebrated")
    H.eq(ch(host).trust, group + 1, "host group trust +1 once")
    H.eq(Tr().personal(host, pa.key), mine + 1, "the giver gets the helper bonus")
    H.eq(Tr().personal(host, pb.key), bobs, "bob gave nothing")
end

function T.holiday_small_gift_comes_from_each_players_friend()
    local a, b, pa, pb = setup()
    local Holiday = StoryEngine.Holiday
    setDate(1993, 11, 23, 10)
    Holiday.hourly(StoryEngine.Sensor.now())
    setPersonal("hunter", pa.key, 80)              -- 알리스만 행크와 친하다 (무리 신뢰는 낮다)
    setDate(1993, 11, 25, 10)
    Holiday.hourly(StoryEngine.Sensor.now())
    local from = {}
    for _, x in pairs(StoryEngine.Store.data().quests) do
        if x.origin and x.origin.source == "holiday" then from[x.target] = x.origin.faction end
    end
    H.eq(from[pa.key], "hunter", "alice's gift comes from hank")
    H.ok(from[pb.key] ~= "hunter", "bob's does not")
end

function T.new_year_money_follows_the_greeters_trust()
    local a, b, pa, pb = setup()
    pa.lang, pb.lang = "KO", "KO"
    setDate(1994, 2, 10, 8)        -- 설날
    ch("ray").trust = 90
    setPersonal("ray", pa.key, 60)
    setPersonal("ray", pb.key, 10)
    StoryEngine.Radio.lastSay = {}
    H.ok(StoryEngine.Radio.say(a, "ray", "happy new year"))
    StoryEngine.Radio.lastSay = {}
    H.ok(StoryEngine.Radio.say(b, "ray", "happy new year"))
    local function money(p)
        local n = 0
        for _, it in ipairs(p.items) do if it.fullType == "Base.Money" then n = n + 1 end end
        return n
    end
    H.eq(money(a), 3, "alice 60 -> 3 bills")
    H.eq(money(b), 1, "bob 10 -> 1 bill")
end

return T
