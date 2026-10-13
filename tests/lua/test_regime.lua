-- 의회의 정치, 그 뒤 (Regime.lua): 다수파와 불신임, 분열과 두 번째 회의, 군정, 시설 사건, 증언, 공용 주파수의 밖에서 온 사람
local T = {}

local function now() return StoryEngine.Sensor.now() end
local function P() return StoryEngine.Politics end
local function R() return StoryEngine.Regime end
local function trust(fid) return StoryEngine.Radio.channel(fid).trust end
local function setTrust(fid, v) StoryEngine.Radio.channel(fid).trust = v end
local function trustAll(v)
    for _, f in ipairs(StoryEngine.Factions.list) do setTrust(f.id, v) end
end

local function quiet()
    local s = P().state()
    s.bill = nil
    s.nextBillT = now().t + 999 * 1440
    s.nextElectionT = now().t + 999 * 1440
    s.nextPhaseT = now().t + 999 * 1440
    if StoryEngine.Crises then StoryEngine.Crises.state().nextT = now().t + 999 * 1440 end
    if StoryEngine.Outsiders then StoryEngine.Outsiders.state().nextT = now().t + 999 * 1440 end
    if StoryEngine.Offices then
        local o = s.offices or {}
        s.offices = o
        o.nextT = { store = now().t + 999 * 1440, captain = now().t + 999 * 1440, air = now().t + 999 * 1440 }
    end
end

-- 어디를 찾든 그 자리에 10x10 비주거 건물이 하나 있는 메타그리드 (소탕·시설 현장)
local function mockBuildings()
    ArrayList = { new = function() return H.list({}) end }
    local function building(cx, cy)
        local x, y = math.floor(cx), math.floor(cy)
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
        return def
    end
    local grid = {}
    function grid:getBuildingsIntersecting(x, y, w, h, list)
        list.items[#list.items + 1] = building(x + w / 2, y + h / 2)
    end
    function grid:getBuildingAt() return nil end
    local world = {}
    function world:getMetaGrid() return grid end
    function world:setHydroPowerOn() end
    getWorld = function() return world end
end

local grid = { cut = {}, restore = {} }
local function mockGrid()
    grid = { cut = {}, restore = {} }
    StoryEngine.Grid.isRestored = function() return true end
    StoryEngine.Grid.cut = function(kind) grid.cut[#grid.cut + 1] = kind; return true end
    StoryEngine.Grid.restore = function(kind) grid.restore[#grid.restore + 1] = kind; return true end
end

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    H.clockMin = 300 * 1440 + 8 * 60
    StoryEngine.Council.state().era = { day = 300, t = now().t }
    P().debug({ open = true })
    quiet()
    trustAll(50)
    mockGrid()
    return p, ps
end

-- 두 파벌 사람들 사이의 마음을 모두 v 로
local function setBonds(a, b, v)
    local Bonds = StoryEngine.Bonds
    local function set(x, y)
        local guard = 0
        while Bonds.get(x, y) ~= v and guard < 10 do
            Bonds.change(x, y, Bonds.get(x, y) < v and 1 or -1, "test")
            guard = guard + 1
        end
    end
    for _, x in ipairs(P().members(a)) do
        for _, y in ipairs(P().members(b)) do
            set(x, y)
            set(y, x)
        end
    end
end

local function seat(fid)
    local Pol = P()
    Pol.state().chair = { fid = fid, bloc = Pol.blocOf(fid), sinceT = now().t, untilT = now().t + 60 * 1440 }
end

local function noticed(kind)
    for _, n in ipairs(H.sentOf("politicsNotice")) do
        if n.kind == kind then return n end
    end
    return nil
end

local function has(list, v)
    for _, x in ipairs(list or {}) do
        if x == v then return true end
    end
    return false
end

function T.a_majority_forms_behind_the_chair_and_backs_its_own()
    setup()
    local Pol, Reg = P(), R()
    setBonds("field", "market", 1)
    setBonds("field", "gun", -1)
    setBonds("gun", "market", 0)
    H.eq(Reg.coalition(), nil, "no chair, no majority")
    seat("ray")
    Reg.daily(now())
    local c = Reg.coalition()
    H.ok(c, "a majority behind the chair")
    H.eq(c.blocs[1], "field")
    H.eq(c.blocs[2], "market", "the camp it gets on with best")
    H.ok(noticed("coalition"))
    -- 다수파가 낸 법안: 같은 다수파의 다른 파벌이 밀어 준다
    local bill = { id = "canteen", bloc = "field", nudge = {}, pledged = {} }
    H.eq(Reg.need(bill, "casey"), -Reg.PARTNER_NEED)
    H.eq(Reg.need(bill, "ray"), 0, "their own camp already backs it")
    H.eq(Reg.need(bill, "guard"), 0, "outside the majority nothing changes")
    -- 다수파 밖에서 낸 법안은 꺼린다
    local out = { id = "purge", bloc = "gun", nudge = {}, pledged = {} }
    H.eq(Reg.need(out, "ray"), Reg.OPPOSE_NEED)
    H.eq(Reg.need(out, "hunter"), 0)
    local base = Pol.YES
    H.eq(Pol.need({ id = "post", bloc = "market", nudge = {}, pledged = {} }, "pike"), base - Reg.PARTNER_NEED)
    local pl = Pol.payload("tester").regime
    H.eq(pl.coalition.blocs[2], "market")
    H.eq(pl.noconf.fid, "ray")
    -- 의장이 플레이어면 다수파가 없다
    Pol.state().chair = { player = "tester", name = "Gerald Kar", sinceT = now().t, untilT = now().t + 60 * 1440 }
    Reg.daily(now())
    H.eq(Reg.coalition(), nil)
    -- 사이가 좋은 파벌이 없으면 혼자
    seat("guard")
    setBonds("gun", "market", -1)
    Reg.daily(now())
    H.eq(#Reg.coalition().blocs, 1)
end

function T.the_majority_falls_when_its_camps_fall_out()
    setup()
    local Pol, Reg = P(), R()
    setBonds("field", "market", 1)
    setBonds("field", "gun", -1)
    seat("ray")
    Reg.daily(now())
    Pol.debug({ enact = "canteen" })
    Pol.debug({ enact = "purge" })
    H.ok(Pol.law("canteen") and Pol.law("purge"))
    setBonds("field", "market", -1)
    Reg.daily(now())
    Reg.daily(now())
    H.eq(Reg.coalition().strain, 2)
    H.ok(Pol.payload("tester").regime.coalition.strain == 2)
    Reg.daily(now())
    H.eq(Reg.coalition(), nil, "three bad days in a row")
    H.eq(Pol.law("canteen"), nil, "the majority's law lapses")
    H.ok(Pol.law("purge"), "a law from outside the majority stays")
    H.eq(Reg.state().collapses, 1)
    local n = noticed("coalition_broken")
    H.ok(n and n.laws == 1)
    -- 불신임이 올라온다
    Reg.tick(now())
    local bill = Pol.state().bill
    H.ok(bill and bill.id == "noconf" and bill.target == "ray" and bill.system)
    H.ok(has(bill.lose, "pike") and has(bill.gain, "guard") and has(bill.gain, "casey"), "with the majority gone everyone else is free")
    -- 밖의 사람들이 우리를 믿으면 통과한다
    for _, fid in ipairs({ "guard", "hunter", "rats", "dewey", "casey" }) do setTrust(fid, 40) end
    for _, fid in ipairs({ "ray", "pike", "doc" }) do setTrust(fid, 60) end
    H.ok(Pol.forecast(bill).pass)
    Pol.vote(now())
    H.eq(Pol.chair(), nil, "the chair is out")
    H.ok(Pol.state().impeachT)
    H.eq(trust("ray"), 60, "nobody blames the players for a vote they did not call")
    -- 한 주 뒤에야 다시 짠다
    seat("pike")
    setBonds("field", "market", 1)
    Reg.daily(now())
    H.eq(Reg.coalition(), nil)
    H.advanceDays(Reg.REFORM_DAYS)
    quiet()
    seat("pike")
    Reg.daily(now())
    H.ok(Reg.coalition())
end

function T.players_can_mend_or_wedge_the_majority()
    local p = setup()
    local Pol, Reg, Bonds = P(), R(), StoryEngine.Bonds
    setBonds("field", "market", 0)
    setBonds("field", "gun", -1)
    seat("ray")
    Reg.daily(now())
    H.eq(Reg.coalition().blocs[2], "market")
    -- 중재: 두 대표가 모두 우리를 믿어야 한다
    local ok, why, need = Reg.mend(p)
    H.ok(not ok and why == "trust" and need == Reg.MEND_TRUST)
    trustAll(65)
    Bonds.change("ray", "rats", -1, "test", true)
    Reg.coalition().strain = 2
    ok = Reg.mend(p)
    H.ok(ok)
    H.eq(Bonds.get("ray", "rats"), 0, "the worst feeling between the two camps eases")
    H.eq(Reg.coalition().strain, 0)
    ok, why = Reg.mend(p)
    H.ok(not ok and why == "wait")
    -- 이간: 약점이 있어야 한다
    ok, why = Reg.wedge(p, "rats")
    H.ok(not ok and why == "no_secret")
    ok, why = Reg.wedge(p, "guard")
    H.ok(not ok and why == "no_target", "not in the majority")
    Pol.learnSecret("rats", "tip", nil)
    H.ok(Reg.wedge(p, "rats"))
    H.eq(Bonds.get("ray", "rats"), -Reg.WEDGE_BOND)
    H.eq(Bonds.get("pike", "rats") <= -2, true)
    H.eq(Pol.secretOf("rats"), nil, "the secret is spent")
    H.ok(noticed("wedge"))
end

function T.a_no_confidence_motion_costs_the_mover_if_it_fails()
    local p = setup()
    local Pol, Reg = P(), R()
    local ok, why = Reg.noConfidence(p)
    H.ok(not ok and why == "no_chair")
    seat("guard")
    H.ok(Reg.noConfidence(p))
    local bill = Pol.state().bill
    H.eq(bill.id, "noconf")
    H.eq(bill.who, "Gerald Kar")
    ok, why = Reg.noConfidence(p)
    H.ok(not ok and why == "wait")
    -- 모두 50: 의장 파벌(기준 70)은 반대, 나머지(기준 30)는 찬성 -> 통과
    H.ok(Pol.forecast(bill).pass)
    trustAll(20)
    setTrust("guard", 50)
    H.ok(not Pol.forecast(bill).pass)
    Pol.vote(now())
    H.ok(Pol.chair(), "the chair stays")
    H.eq(trust("guard"), 50 - Reg.NOCONF_FAIL)
    H.eq(Pol.state().impeachT, nil)
    -- 통과하면 물러난 의장이 우리를 탓한다
    H.advanceDays(Reg.NOCONF_DAYS)
    quiet()
    seat("guard")
    trustAll(50)
    H.ok(Reg.noConfidence(p))
    Pol.vote(now())
    H.eq(Pol.chair(), nil)
    H.eq(trust("guard"), 50 - Reg.NOCONF_OUST)
    H.ok(Pol.state().impeachT)
end

function T.two_collapses_break_the_council_in_two()
    local p, ps = setup()
    local Pol, Reg, Quests = P(), R(), StoryEngine.Quests
    setBonds("field", "market", 1)
    setBonds("field", "gun", -2)
    setBonds("gun", "market", 0)
    seat("ray")
    Pol.debug({ bill = "canteen" })
    H.ok(Pol.state().bill)
    Reg.state().collapses = Reg.SPLIT_COLLAPSES
    local ph = Pol.judgePhase(now())
    H.eq(ph.kind, "split")
    H.eq(Reg.closed(), "split")
    H.ok(has(ph.halves.a.blocs, "gun"), "the half with the guns")
    H.eq(ph.halves.a.hold, "power")
    H.eq(ph.halves.b.hold, "water")
    H.ok(has(ph.halves.b.blocs, "field") and has(ph.halves.b.blocs, "market"), "the market sits with the camp it gets on with")
    H.eq(Reg.halfOf("guard"), "a")
    H.eq(Reg.halfOf("casey"), "b")
    H.eq(Pol.state().bill, nil, "nothing is voted on")
    H.eq(Pol.chair(), nil)
    H.eq(Reg.state().collapses, 0)
    local n = noticed("phase")
    H.ok(n and n.phase == "split")
    local ok, why = Pol.proposeSpecial(p, "memorial")
    H.ok(not ok and why == "shut")
    -- 닫힌 의회: 선거도 법안도 열리지 않는다
    Pol.state().nextBillT = now().t
    Pol.state().nextElectionT = now().t
    Pol.tick(now())
    H.eq(Pol.state().bill, nil)
    H.eq(Pol.state().election, nil)
    -- 한쪽을 도우면 다른 쪽 대표가 식는다
    setTrust("guard", 55)
    local q = Quests.propose(p, ps, "ray", 2, now())
    Quests.respond(p, q.id, true)
    local before = trust("guard")
    Quests.setState(q, "completed", now(), { ps = ps })
    H.eq(trust("guard"), before - Reg.SPLIT_RIVAL_COST)
    -- 다음 판정에도 이어진다
    H.eq(Pol.judgePhase(now()).kind, "split")
    -- 한쪽이 우리를 못 믿으면 쥔 것을 끊는다
    setTrust("guard", 20)
    setTrust("hunter", 20)
    Reg.daily(now())
    H.ok(ph.halves.a.cut)
    H.eq(grid.cut[#grid.cut], "power")
    H.ok(Reg.gridBlocked("power") and not Reg.gridBlocked("water"))
    H.ok(noticed("split_cut"))
    local pl = Pol.payload("tester")
    H.eq(pl.phase.kind, "split")
    H.ok(pl.regime.split.halves[1].cut)
    setTrust("guard", 50)
    setTrust("hunter", 50)
    Reg.daily(now())
    H.ok(not ph.halves.a.cut)
    H.eq(grid.restore[#grid.restore], "power")
    -- AI 맥락
    local ctx = Pol.context("guard").regime
    H.eq(ctx.split.hold, "power")
    H.ok(has(ctx.split.other, "field"))
end

function T.an_unsolved_walkout_also_splits_the_council()
    setup()
    local Pol, Reg = P(), R()
    Reg.onE3("chosen")
    H.eq(Pol.judgePhase(now()).kind ~= "split", true, "picking a side is not a failure")
    Reg.onE3("ignored")
    H.eq(Pol.judgePhase(now()).kind, "split")
end

function T.a_second_county_council_mends_the_split()
    local p, ps = setup()
    local Pol, Reg, Quests = P(), R(), StoryEngine.Quests
    H.defineItem("Base.Antibiotics", "medical", 4)
    setBonds("field", "gun", -2)
    Reg.debug({ what = "split" })
    local ph = Pol.state().phase
    H.eq(ph.kind, "split")
    setTrust("guard", 70)
    setTrust("ray", 70)
    H.ok(Reg.reunite(p))
    local asks = ph.reunion.asks
    local qa, qb = StoryEngine.Store.data().quests[asks.a], StoryEngine.Store.data().quests[asks.b]
    H.ok(qa and qb)
    H.eq(qa.state, "accepted")
    H.eq(qa.origin.faction, "guard")
    H.eq(qa.tier <= Reg.REUNITE_TIER, true)
    local ok, why = Reg.reunite(p)
    H.ok(not ok and why == "busy")
    Quests.setState(qa, "completed", now(), { ps = ps })
    H.eq(Pol.state().phase.kind, "split", "one side is not enough")
    local before = trust("dewey")
    Quests.setState(qb, "completed", now(), { ps = ps })
    H.eq(Pol.state().phase.kind, "balance")
    H.eq(Reg.closed(), nil)
    H.ok(trust("dewey") >= before + Reg.REUNITE_GAIN)
    H.ok(noticed("reunited"))
    H.eq(Reg.state().reunions, 1)
    H.eq(Pol.summary().regime.reunions, 1)
    -- 하나라도 놓치면 깨진다
    Reg.debug({ what = "split" })
    ph = Pol.state().phase
    H.ok(Reg.reunite(p))
    qa = StoryEngine.Store.data().quests[ph.reunion.asks.a]
    local g = trust("guard")
    Quests.setState(qa, "failed", now(), { ps = ps })
    H.eq(ph.reunion, nil)
    H.ok(trust("guard") <= g - Reg.REUNITE_FAIL)
    ok, why = Reg.reunite(p)
    H.ok(not ok and why == "wait")
end

function T.rule_by_order_when_the_guns_take_the_council()
    local p, ps = setup()
    mockBuildings()
    local Pol, Reg, Quests = P(), R(), StoryEngine.Quests
    H.defineItem("Base.Antibiotics", "medical", 4)
    H.eq(Reg.martialDue(now()), nil)
    Pol.state().impeachT = now().t
    H.eq(Reg.martialDue(now()), nil, "not without trouble in the county")
    StoryEngine.Saga.active = function() return true end
    H.eq(Reg.martialDue(now()), nil, "not unless the guns are strong")
    Pol.state().lean.gun = 40
    H.eq(Reg.martialDue(now()), "guard")
    seat("ray")
    Pol.debug({ bill = "canteen" })
    local price = Pol.mod("price", "ray", "food")
    Pol.tick(now())
    H.eq(Pol.state().phase.kind, "martial")
    H.eq(Pol.state().phase.by, "guard")
    H.eq(Reg.closed(), "martial")
    H.eq(Pol.chair(), nil)
    H.eq(Pol.state().bill, nil)
    H.ok(noticed("phase").phase)
    -- 총 파벌이 아닌 사람들과의 거래는 값이 오른다
    H.ok(math.abs(Pol.mod("price", "ray", "food") - price * Reg.MARTIAL_PRICE) < 0.0001)
    H.eq(Pol.mod("price", "hunter", "food"), 1)
    -- 하루 뒤 첫 명령 (징발)
    H.advanceDays(1)
    quiet()
    Reg.tick(now())
    local m = Reg.martial()
    local q = StoryEngine.Store.data().quests[m.order]
    H.ok(q and q.martial and q.origin.faction == "guard")
    H.eq(q.state, "proposed")
    H.ok(noticed("martial_order"))
    -- 따르면 방위대가 대기 없이 돕는다
    H.ok(not Pol.dealt("guard"))
    Quests.respond(p, q.id, true)
    Quests.setState(q, "completed", now(), { ps = ps })
    H.eq(m.obeyed, 1)
    H.ok(Reg.backed("guard") and Pol.dealt("guard"))
    H.ok(not Pol.dealt("hunter"))
    -- 어기면 신뢰가 깎이고 협박이 온다
    H.advanceDays(Reg.MARTIAL_ORDER_DAYS)
    quiet()
    Reg.tick(now())
    q = StoryEngine.Store.data().quests[m.order]
    H.ok(q)
    local before = trust("guard")
    Quests.respond(p, q.id, false)
    H.eq(m.defied, 1)
    H.ok(trust("guard") <= before - Reg.MARTIAL_DEFY)
    H.ok(Quests.openFor(ps.key, "extort"), "defiance draws a demand")
    -- 청원: 나머지의 과반이 우리를 믿어야 한다
    local ok, why, yes, need = Reg.petition(p)
    H.ok(not ok and why == "trust" and yes == 0 and need == 4)
    for _, fid in ipairs({ "ray", "pike", "doc", "casey" }) do setTrust(fid, 60) end
    local g = trust("guard")
    H.ok(Reg.petition(p))
    H.eq(Reg.closed(), nil)
    H.eq(Pol.state().phase.kind, "balance")
    H.eq(trust("guard"), g - Reg.PETITION_COST)
    H.ok(noticed("martial_over"))
end

function T.obeying_long_enough_settles_the_rule_and_hale_outranks_whitaker()
    local p, ps = setup()
    local Pol, Reg, Quests = P(), R(), StoryEngine.Quests
    H.defineItem("Base.Antibiotics", "medical", 4)
    Reg.enterMartial("guard", now())
    local m = Reg.martial()
    m.obeyed = Reg.MARTIAL_SETTLE - 1
    H.advanceDays(1)
    quiet()
    Reg.tick(now())
    local q = StoryEngine.Store.data().quests[m.order]
    Quests.respond(p, q.id, true)
    Quests.setState(q, "completed", now(), { ps = ps })
    H.ok(m.settled)
    H.ok(noticed("martial_settled"))
    H.eq(Pol.judgePhase(now()).kind, "martial", "it does not lapse by itself")
    H.eq(Pol.context("ray").regime.martial.role, "under")
    H.eq(Pol.context("guard").regime.martial.role, "commander")
    H.eq(Pol.context("hunter").regime.martial.role, "with")
    -- 지휘관이 떠나면 끝난다
    StoryEngine.Factions.isGone = function(id) return id == "guard" end
    Reg.tick(now())
    H.eq(Reg.closed(), nil)
    StoryEngine.Factions.isGone = function() return false end
    -- 헤일 대령이 와 있으면 헤일이 지휘관이고 휘태커는 맞선다
    StoryEngine.Outsiders.debug({ what = "arrive", id = "hale" })
    Pol.state().impeachT = now().t
    Pol.state().lean.gun = 40
    StoryEngine.Saga.active = function() return true end
    H.eq(Reg.martialDue(now()), "hale")
    Reg.enterMartial("hale", now())
    H.eq(Pol.state().phase.against, "guard")
    H.eq(Pol.context("guard").regime.martial.role, "against")
    H.ok(not Reg.backed("guard"))
end

function T.the_works_are_held_or_lost()
    local p, ps = setup()
    mockBuildings()
    local Pol, Reg, Saga, Quests = P(), R(), StoryEngine.Saga, StoryEngine.Quests
    H.ok(has(Saga.candidates(), "facility"))
    StoryEngine.Grid.isRestored = function() return false end
    H.ok(not has(Saga.candidates(), "facility"), "nothing to defend")
    StoryEngine.Grid.isRestored = function() return true end
    H.ok(Saga.start("facility", "test"))
    local sg = Saga.current()
    H.ok(sg.data.what == "power" or sg.data.what == "water")
    H.ok(sg.data.site and sg.data.caller)
    -- 파벌의 제안을 받는다
    H.ok(Pol.deal(p, "gun"))
    Saga.debug("next")
    local q = StoryEngine.Store.data().quests[sg.quests.facility]
    H.ok(q and q.kind == "defend")
    H.eq(q.needMin, Saga.FACILITY_MIN)
    H.ok(Quests.isManaged(q))
    -- 머무는 동안 무리가 온다
    local hunts = 0
    StoryEngine.Hunt.start = function() hunts = hunts + 1 end
    q.present = 1
    H.advance(10)
    Saga.tick(now())
    H.eq(hunts, 1)
    H.eq(q.waves, 1)
    Saga.tick(now())
    H.eq(hunts, 1, "one pack every forty minutes")
    -- 지켰다: 제안을 받은 파벌이 쥔다
    local what = sg.data.what
    Quests.setState(q, "completed", now(), { ps = ps })
    H.advance(10)
    Saga.tick(now())
    H.ok(not Saga.active())
    H.eq(StoryEngine.Store.data().saga.history[1].result, "held")
    H.eq(Reg.state().facility.held[what].bloc, "gun")
    H.eq(Reg.weight("gun"), 1)
    H.eq(Pol.weights(now()).gun >= 2, true, "the works and the credit")
    H.eq(Pol.payload("tester").regime.facility.held[1].bloc, "gun")
    -- 못 지켰다: 한 달 고장
    StoryEngine.Store.data().saga.lastDay = {}
    H.ok(Saga.start("facility", "test"))
    sg = Saga.current()
    Saga.debug("next")
    what = sg.data.what
    Saga.debug("stop")
    H.eq(StoryEngine.Store.data().saga.history[2].result, "lost")
    H.eq(Reg.state().facility.held[what], nil)
    H.ok(Reg.gridBlocked(what))
    H.eq(grid.cut[#grid.cut], what)
    H.ok(noticed("facility_lost"))
    H.eq(Pol.payload("tester").regime.facility.down[1].what, what)
    local restored = #grid.restore
    H.advanceDays(Reg.FACILITY_DOWN_DAYS + 1)
    quiet()
    Reg.tick(now())
    H.ok(not Reg.gridBlocked(what))
    H.eq(#grid.restore, restored + 1)
    H.eq(grid.restore[#grid.restore], what)
end

function T.speaking_up_after_the_trouble()
    local p = setup()
    local Pol, Reg = P(), R()
    local ok, why = Reg.testify(p, "field")
    H.ok(not ok and why == "no_blame")
    -- 사건이 끝나면 공과를 두고 다툰다
    Pol.onSaga("start", { id = "SG9", kind = "migration" })
    H.ok(Pol.deal(p, "market"))
    Pol.onSaga("done", { id = "SG9", kind = "migration", result = "saved" })
    H.ok(noticed("testify_open"))
    H.eq(Pol.payload("tester").regime.blame.deal, "market")
    local leader = nil
    for _, n in ipairs(H.sentOf("politicsNotice")) do if n.kind == "deal" then leader = n end end
    local before, market = (Pol.state().credit or {}).field or 0, nil
    local top = -1
    for _, fid in ipairs(Pol.members("market")) do
        if trust(fid) > top then market, top = fid, trust(fid) end
    end
    local leanBefore = Pol.lean("field")
    H.ok(Reg.testify(p, "field"))
    H.eq(Pol.state().credit.field, before + 1)
    H.eq(Pol.lean("field"), leanBefore + Reg.TESTIFY_LEAN)
    H.eq(trust(market), top - Reg.TESTIFY_COST, "the camp that did the work hears you credit another")
    ok, why = Reg.testify(p, "gun")
    H.ok(not ok and why == "done")
    H.ok(Pol.payload("tester").regime.blame.used)
    -- 이틀이 지나면 닫힌다
    H.advance(Reg.TESTIFY_HOURS * 60 + 60)
    quiet()
    Reg.tick(now())
    H.eq(Reg.state().blame, nil)
end

function T.outsiders_join_the_open_channel()
    setup()
    local Social, F = StoryEngine.Social, StoryEngine.Factions
    -- 아무도 와 있지 않으면 주사위도 굴리지 않는다
    H.eq(Social.pickGuest(false), nil)
    StoryEngine.Outsiders.debug({ what = "arrive", id = "odell" })
    H.ok(not F.isGone("odell"))
    Social.GUEST_CHANCE = 100
    H.ok(Social.scene())
    local b = H.lastBridge("radio_scene")
    local guest, local1 = nil, nil
    for _, part in ipairs(b.payload.participants) do
        if part.id == "odell" then guest = part else local1 = local1 or part end
    end
    H.ok(guest and guest.guest, "the stranger is on the channel")
    H.eq(guest.state, nil, "no farm, no stores")
    H.ok(#b.payload.participants <= 3)
    local saw = false
    for _, r in ipairs(local1.relations or {}) do
        if r.id == "odell" and r.note then saw = true end
    end
    H.ok(saw, "the locals know who the stranger is")
    -- AI 가 없으면 원래 사람이 말을 꺼내고 밖에서 온 사람이 받는다
    b.callback({ ok = false, error = "bridge_offline" })
    local pending = StoryEngine.Store.data().social.pending
    local msgs = StoryEngine.Radio.channel(Social.OPEN).messages
    local first = msgs[#msgs]
    H.ok(first.npc ~= "odell")
    H.ok(pending and pending.lines[1].npc == "odell")
    H.ok(string.find(pending.lines[1].lt.key, "IGUI_StoryEngine_Line_odell_", 1, true))
    H.ok(string.find(pending.lines[1].lt.key, "_reply_1", 1, true))
    -- 꺼리는 사이면 차갑게
    local lines = Social.offlineLines({ "rats", "odell" }, nil, nil, nil)
    H.eq(lines[1].npc, "rats")
    H.ok(string.find(lines[1].lt.key, "duo_cold_open", 1, true))
    H.eq(lines[2].lt.key, "IGUI_StoryEngine_Line_odell_duo_cold_reply_1")
    lines = Social.offlineLines({ "odell", "casey" }, nil, nil, nil)
    H.eq(lines[1].npc, "casey", "the local always speaks first")
    H.eq(lines[2].lt.key, "IGUI_StoryEngine_Line_odell_duo_plain_reply_1")
    lines = Social.offlineLines({ "casey", "ray", "odell" }, { name = "Gerald", text = "hello there" }, nil, nil)
    H.eq(lines[2].npc, "odell")
    H.eq(lines[2].lt.key, "IGUI_StoryEngine_Line_odell_open_reply_1")
end

local function rule(bloc)
    P().state().phase = { kind = "rule", bloc = bloc, sinceT = now().t, day = StoryEngine.Store.serverDays() }
end

function T.a_county_run_by_the_fields_shares_and_tithes()
    local p, ps = setup()
    local Pol, Reg, Quests, Life = P(), R(), StoryEngine.Quests, StoryEngine.Life
    H.defineItem("Base.Antibiotics", "medical", 4)
    local price = Pol.mod("price", "doc", "medical")
    local base = Life.base("doc", "food")
    H.eq(Reg.ruling(), nil)
    rule("field")
    H.eq(Reg.ruling(), "field")
    H.near(Pol.mod("price", "doc", "medical"), price * Reg.RULE_PRICE, 0.001)
    H.eq(Life.base("doc", "food"), base + Reg.RULE_FOOD)
    H.eq(Pol.mod("tradeBlock", "rats", "tools"), true, "the market is shut")
    H.eq(Pol.mod("tradeBlock", "dewey", "tools"), false)
    H.eq(Pol.mod("noExtort"), false)
    -- 십일조는 한 주 뒤부터
    Reg.daily(now())
    H.eq(Reg.state().rule.tithe, nil)
    H.eq(Pol.payload("tester").regime.rule.titheDays, Reg.TITHE_DAYS)
    H.advanceDays(Reg.TITHE_DAYS)
    quiet()
    Reg.daily(now())
    local quests = StoryEngine.Store.data().quests
    local q = quests[Reg.state().rule.tithe]
    H.ok(q and q.tithe and q.noReward, "the tithe is due")
    H.eq(q.state, "accepted")
    H.eq(q.origin.faction, "ray")
    H.ok(noticed("tithe"))
    Reg.daily(now())
    H.eq(Reg.state().rule.tithe, q.id, "one at a time")
    -- 안 내면 밭 사람들이 식는다 (다른 감점은 없다)
    local before, vic = trust("pike"), trust("rats")
    Quests.setState(q, "failed", now(), { ps = ps })
    H.eq(trust("pike"), before - Reg.TITHE_COST)
    H.eq(trust("ray"), 50 - Reg.TITHE_COST)
    H.eq(trust("rats"), vic)
    H.eq(Reg.state().rule.tithe, nil)
    H.ok(noticed("tithe_unpaid"))
    -- 내면 신뢰는 그대로고 가장 모자란 곳으로 간다
    H.advanceDays(Reg.TITHE_DAYS)
    quiet()
    Reg.daily(now())
    q = quests[Reg.state().rule.tithe]
    H.ok(q)
    Life.npc("hunter").res.food = 5
    before = trust("ray")
    Quests.setState(q, "completed", now(), { ps = ps })
    H.eq(trust("ray"), before)
    H.eq(Life.get("hunter", "food"), 5 + Reg.TITHE_SHARE)
    H.ok(noticed("tithe_paid"))
    -- 독주가 끝나면 사라진다
    Pol.state().phase = { kind = "balance" }
    Reg.daily(now())
    H.eq(Reg.state().rule, nil)
    H.eq(Pol.mod("tradeBlock", "rats", "tools"), false)
end

function T.a_county_run_by_the_guns_keeps_order_and_a_curfew()
    local p, ps = setup()
    local Pol, Reg, Quests, Life = P(), R(), StoryEngine.Quests, StoryEngine.Life
    H.ok(Quests.nightAllowed(5))
    rule("gun")
    H.eq(Pol.mod("noExtort"), true)
    H.eq(Pol.mod("squad", "guard"), Reg.RULE_SQUAD)
    H.near(Pol.mod("specWait", "hunter"), Reg.RULE_WAIT, 0.001)
    H.near(Pol.mod("specWait", "ray"), Pol.RULE_WAIT, 0.001)
    H.eq(Pol.mod("tradeBlock", "rats", "firearm"), true, "only the Guard sells guns")
    H.eq(Pol.mod("tradeBlock", "rats", "tools"), false)
    H.eq(Pol.mod("tradeBlock", "guard", "firearm"), false)
    H.eq(Pol.mod("noRegen", "ray", "food"), true)
    H.eq(Pol.mod("noRegen", "hunter", "food"), false)
    -- 날마다 밭 쪽 식량을 징발한다
    local food, own = Life.get("ray", "food"), Life.get("hunter", "food")
    Reg.daily(now())
    H.ok(Life.get("ray", "food") < food)
    H.eq(Life.get("hunter", "food"), own)
    -- 야간 작전이 없다
    H.eq(Quests.nightAllowed(5), false)
    -- 야간 통행 제한
    ps.home = { x = p:getX(), y = p:getY(), z = 0 }
    local far = { { player = p, ps = ps, s = { x = p:getX() + 100, y = p:getY(), outside = true, asleep = false } } }
    local g = trust("guard")
    Reg.curfewTick(far, now())
    H.eq(ps.curfew, nil, "daytime")
    H.clockMin = 301 * 1440 + 23 * 60
    Reg.curfewTick({ { player = p, ps = ps, s = { x = p:getX() + 10, y = p:getY(), outside = true } } }, now())
    H.eq(ps.curfew, nil, "close to home")
    Reg.curfewTick({ { player = p, ps = ps, s = { x = p:getX() + 100, y = p:getY(), outside = false } } }, now())
    H.eq(ps.curfew, nil, "indoors")
    Reg.curfewTick(far, now())
    H.eq(ps.curfew.n, 1)
    H.eq(trust("guard"), g, "a warning first")
    Reg.curfewTick(far, now())
    H.eq(trust("guard"), g - Reg.CURFEW_COST)
    Reg.curfewTick(far, now())
    H.eq(trust("guard"), g - Reg.CURFEW_COST, "once a night")
    H.clockMin = 302 * 1440 + 2 * 60
    Reg.curfewTick(far, now())
    H.eq(trust("guard"), g - Reg.CURFEW_COST, "still the same night after midnight")
    H.clockMin = 302 * 1440 + 23 * 60
    Reg.curfewTick(far, now())
    H.eq(ps.curfew.n, 1, "a new night, a new warning")
end

function T.a_county_run_by_the_market_sells_everything_and_gives_nothing()
    setup()
    local Pol, Reg, Life, Trade, Value = P(), R(), StoryEngine.Life, StoryEngine.Trade, StoryEngine.Value
    H.ok(not Trade.bazaar())
    H.ok(not Value.anyWantsFn("ray"))
    rule("market")
    H.ok(Trade.bazaar())
    H.eq(Pol.mod("noGift"), true)
    H.near(Pol.mod("donate", "ray"), Reg.RULE_DONATE, 0.001)
    H.ok(Value.anyWantsFn("ray"), "anything is taken in payment")
    H.ok(not Value.anyWantsFn("odell"))
    H.eq(Pol.mod("noRegen", "pike", "morale"), true)
    H.eq(Pol.mod("noRegen", "ray", "morale"), false)
    local pike, doc, ray = Life.get("pike", "morale"), Life.get("doc", "morale"), Life.get("ray", "morale")
    Reg.daily(now())
    H.ok(Life.get("pike", "morale") < pike and Life.get("doc", "morale") < doc, "the church and the clinic wither")
    H.eq(Life.get("ray", "morale"), ray)
    H.eq(Pol.payload("tester").regime.rule.bloc, "market")
end

function T.the_majority_shares_out_the_posts()
    setup()
    local Pol, Reg, Off = P(), R(), StoryEngine.Offices
    H.eq(Reg.shareOf(), nil)
    setBonds("field", "market", 1)
    setBonds("field", "gun", -1)
    setBonds("gun", "market", 0)
    seat("ray")
    Reg.daily(now())
    H.eq(Reg.shareOf(), "market", "the camp without the chair is owed a post")
    Off.debug("store")
    local v = Pol.state().offices.vote
    H.ok(v)
    H.eq(v.share.bloc, "market")
    H.eq(Off.forecast(v).winner, "market", "the whole majority votes for the promised candidate")
    H.eq(Pol.payload("tester").offices.vote.share, "market")
    Reg.coalition().strain = 1
    Off.debug("store")
    H.eq(Off.holder("store").bloc, "market")
    H.eq(Reg.coalition().strain, 0, "a kept promise eases the strain")
    -- 약속한 자리가 다른 데로 가면 금이 간다
    Reg.onPost("market", "gun", now())
    H.eq(Reg.coalition().strain, 1)
    H.ok(noticed("post_snub"))
    Reg.coalition().strain = Reg.COLLAPSE_DAYS - 1
    Reg.onPost("field", "gun", now())
    H.eq(Reg.coalition(), nil, "one snub too many")
end

return T
