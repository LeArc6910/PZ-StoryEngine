-- 정치 위기 (Crises.lua, docs/PLAN_COUNCIL_POLITICS.md 8단계): 택일·배분·모금 위기 일곱
local T = {}

local function now() return StoryEngine.Sensor.now() end
local function P() return StoryEngine.Politics end
local function C() return StoryEngine.Crises end
local function trust(fid) return StoryEngine.Radio.channel(fid).trust end
local function setTrust(fid, v) StoryEngine.Radio.channel(fid).trust = v end
local function trustAll(v)
    for _, f in ipairs(StoryEngine.Factions.list) do setTrust(f.id, v) end
end
local function res(fid, r) return StoryEngine.Life.npc(fid).res[r] end

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

-- 전기·수도를 끊고 돌려주는 것을 적어 둔다
local grid
local function mockGrid()
    grid = { cut = {}, back = {} }
    StoryEngine.Grid.cut = function(kind) grid.cut[#grid.cut + 1] = kind return true end
    StoryEngine.Grid.restore = function(kind) grid.back[#grid.back + 1] = kind return true end
    StoryEngine.Grid.isRestored = function() return true end
end

local function quiet()
    P().state().bill = nil
    P().state().nextBillT = now().t + 999 * 1440
    P().state().nextElectionT = now().t + 999 * 1440
end

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    H.clockMin = 300 * 1440 + 8 * 60
    StoryEngine.Council.state().era = { day = 300, t = now().t }
    P().debug({ open = true })
    quiet()
    mockGrid()
    trustAll(50)
    return p, ps
end

function T.crises_come_one_at_a_time_after_a_week()
    setup()
    local Cr = C()
    Cr.tick()
    H.eq(Cr.state().current, nil, "not in the first week")
    H.advanceDays(Cr.FIRST_DAYS + 1)
    quiet()
    Cr.tick()
    local cur = Cr.state().current
    H.ok(cur, "one opens")
    H.ok(#H.sentOf("crisisNotice") > 0)
    H.eq(Cr.start("quarantine"), nil, "never two at once")
    Cr.close(now(), "test")
    H.ok(Cr.state().nextT - now().t >= Cr.GAP_MIN_DAYS * 1440)
    H.ok(Cr.state().done[cur.id], "and each only once")
    Cr.tick()
    H.eq(Cr.state().current, nil)
    -- 끄면 오지 않는다
    SandboxVars.StoryEngine.PoliticalCrises = false
    H.ok(not Cr.enabled())
    H.eq(Cr.payload("tester"), nil)
    SandboxVars.StoryEngine.PoliticalCrises = nil
end

function T.taking_a_side_splits_the_council()
    local p = setup()
    local Cr = C()
    H.ok(Cr.start("split"))
    H.eq(select(2, Cr.choose(p, "nobody")), "how")
    H.ok(Cr.choose(p, "field"))
    H.eq(trust("ray"), 52)
    H.eq(trust("guard"), 45)
    H.eq(trust("rats"), 50, "the Market is not part of this quarrel")
    H.eq(P().lean("field"), Cr.SPLIT_LEAN)
    H.eq(Cr.state().current, nil)
    H.eq(Cr.split().snubbed, "gun")
    H.eq(grid.cut[1], "power", "the side left out holds the power")
    -- 갈라선 동안에는 셋 가운데 둘이 찬성해야 한다
    P().debug({ bill = "canteen" })
    local bill = P().state().bill
    bill.pledged = { ray = true, pike = true, doc = true, casey = true, dewey = true, guard = false, hunter = false, rats = false }
    local t = P().forecast(bill)
    H.eq(t.yes, 5)
    H.ok(t.two3 and not t.pass, "five of eight is not two thirds")
    bill.pledged.rats = true
    H.ok(P().forecast(bill).pass, "six of eight is")
    P().state().bill = nil
    -- 한 달 뒤 다시 모인다
    H.advanceDays(Cr.SPLIT_DAYS + 1)
    quiet()
    Cr.state().nextT = now().t + 999 * 1440
    Cr.tick()
    H.eq(Cr.split(), nil)
    H.eq(grid.back[#grid.back], "power")
end

function T.doing_both_sides_a_favour_keeps_the_council_whole()
    local p, ps = setup()
    mockBuildings()
    local Cr, Quests = C(), StoryEngine.Quests
    SandboxVars.StoryEngine.RequestItemMode = 3
    Cr.start("split")
    H.ok(Cr.choose(p, "both"))
    local cur = Cr.state().current
    H.ok(cur.waiting and cur.asks.field and cur.asks.gun, "one favour for each side")
    H.eq(select(2, Cr.choose(p, "field")), "waiting")
    for _, bloc in ipairs({ "field", "gun" }) do
        local q = StoryEngine.Store.data().quests[cur.asks[bloc]]
        H.eq(q.state, "accepted")
        H.eq(q.tier, Cr.SPLIT_ASK_TIER)
        for _, need in ipairs(q.need) do
            for _ = 1, need[2] do H.give(p, need[1]) end
        end
        local ok, why = Quests.submit(p, q.id)
        H.ok(ok, tostring(why))
    end
    H.eq(Cr.state().current, nil)
    H.eq(Cr.split(), nil, "nobody walked out")
    H.eq(#grid.cut, 0)
    -- 하나라도 못 하면 양쪽 다 등을 돌린 채 갈라선다
    Cr.state().done.split = nil
    trustAll(50)
    Cr.start("split")
    Cr.choose(p, "both")
    cur = Cr.state().current
    Quests.setState(StoryEngine.Store.data().quests[cur.asks.gun], "failed", now())
    H.eq(Cr.split().snubbed, "both")
    H.ok(trust("ray") < 50 and trust("guard") < 50)
    SandboxVars.StoryEngine.RequestItemMode = nil
end

function T.the_burned_transformer()
    local p = setup()
    local Cr = C()
    H.ok(Cr.start("transformer"))
    local cur = Cr.state().current
    local q = StoryEngine.Store.data().quests[cur.collect]
    H.eq(q.kind, "collect")
    H.ok(StoryEngine.Quests.isManaged(q))
    H.eq(#Cr.payload("tester").current.options, 0, "nothing to choose: gather the parts")
    -- 못 채우면 한 달 동안 밤에만 전기
    H.advanceDays(Cr.TRANSFORMER_DAYS + 1)
    H.clockMin = math.floor(H.clockMin / 1440) * 1440 + 12 * 60
    quiet()
    Cr.tick()
    H.ok(Cr.state().fx.night)
    H.eq(Cr.state().current, nil)
    Cr.tick()
    H.eq(grid.cut[#grid.cut], "power", "off by day")
    local cuts = #grid.cut
    Cr.tick()
    H.eq(#grid.cut, cuts, "not cut again every hour")
    H.clockMin = math.floor(H.clockMin / 1440) * 1440 + 22 * 60
    Cr.tick()
    H.eq(grid.back[#grid.back], "power", "on at night")
    H.advanceDays(Cr.NIGHT_DAYS + 1)
    quiet()
    Cr.state().nextT = now().t + 999 * 1440
    Cr.tick()
    H.eq(Cr.state().fx.night, nil)
    -- 채우면 아무 일도 없다
    Cr.state().done.transformer = nil
    Cr.start("transformer")
    cur = Cr.state().current
    StoryEngine.Store.data().quests[cur.collect].state = "completed"
    Cr.tick()
    H.eq(Cr.state().current, nil)
    H.eq(Cr.state().fx.night, nil)
end

function T.rationing_is_shared_out()
    local p = setup()
    local Cr = C()
    Cr.debug({ what = "start", id = "ration" })
    local c = Cr.payload("tester").current
    H.eq(c.id, "ration")
    H.eq(c.allot.total, 8 * Cr.RATION_PER)
    H.eq(#c.allot.rows, 8)
    H.eq(select(2, Cr.choose(p, "seal")), "how")
    H.eq(select(2, Cr.choose(p, { ray = 30, guard = 30 })), "bad_total")
    H.eq(select(2, Cr.choose(p, { ray = 35, guard = 30, rats = 15 })), "bad_share")
    local before = res("guard", "food")
    local rayFood = res("ray", "food")
    H.ok(Cr.choose(p, { guard = 30, rats = 30, hunter = 20 }))
    H.eq(res("guard", "food"), math.max(0, before - 30))
    H.eq(res("ray", "food"), rayFood, "the farms keep their share")
    H.eq(trust("guard"), 47)
    H.eq(trust("hunter"), 48)
    H.eq(trust("ray"), 50)
    H.eq(Cr.state().current, nil)
    -- 답하지 않으면 고르게, 모두가 서운해한다
    for k in pairs(Cr.state().done) do Cr.state().done[k] = nil end
    trustAll(50)
    Cr.debug({ what = "start", id = "ration" })
    Cr.debug({ what = "expire" })
    H.eq(trust("ray"), 48, "one for the cut and one for nobody deciding")
    H.eq(trust("doc"), 48)
end

function T.refugees_are_taken_in_or_turned_away()
    local p = setup()
    local Cr = C()
    Cr.start("refugees")
    H.eq(select(2, Cr.choose(p, { ray = 50 })), "bad_share")
    local before = res("ray", "food")
    H.ok(Cr.choose(p, { ray = 30, pike = 20 }))
    H.eq(res("ray", "food"), math.max(0, before - 15))
    H.eq(trust("ray"), 49, "thirty is more than a farm wants")
    H.eq(trust("pike"), 48, "fifty were turned away: two for that")
    H.eq(trust("doc"), 48)
    local n = H.sentOf("crisisNotice")
    H.eq(n[#n].taken, 50)
    H.eq(n[#n].away, 50)
    -- 모두 받으면 파이크와 닥이 고마워한다
    Cr.state().done.refugees = nil
    trustAll(50)
    Cr.start("refugees")
    H.ok(Cr.choose(p, { ray = 20, pike = 20, doc = 20, casey = 20, dewey = 20 }))
    H.eq(trust("pike"), 51)
    H.eq(trust("doc"), 51)
end

function T.quarantine_seals_or_sends_doc()
    local p, ps = setup()
    local Cr, Spec = C(), StoryEngine.Specialty
    Cr.start("quarantine")
    local sick = Cr.state().current.sick
    H.ok(sick and sick ~= "doc")
    local before = res(sick, "medical")
    H.ok(Cr.choose(p, "seal"))
    H.eq(trust(sick), 40)
    H.eq(res(sick, "medical"), math.max(0, before - Cr.QUARANTINE_SEAL))
    H.ok(not P().mod("specBlock", "doc"))
    Cr.state().done.quarantine = nil
    trustAll(50)
    Cr.start("quarantine")
    sick = Cr.state().current.sick
    H.ok(Cr.choose(p, "open"))
    H.eq(trust(sick), 52)
    H.ok(P().mod("specBlock", "doc"))
    H.eq(Spec.status("doc", ps.key).reason, "nursing")
    local n = H.sentOf("crisisNotice")
    H.eq(#n[#n].spread, 2, "and it spreads to two more")
    H.advanceDays(Cr.QUARANTINE_DAYS + 1)
    quiet()
    Cr.state().nextT = now().t + 999 * 1440
    Cr.tick()
    H.ok(not P().mod("specBlock", "doc"), "Doc is back after two weeks")
    -- 답하지 않아도 열어 둔 것이 된다
    Cr.state().done.quarantine = nil
    Cr.start("quarantine")
    Cr.debug({ what = "expire" })
    H.ok(P().mod("specBlock", "doc"))
end

function T.caseys_boat_and_the_new_route()
    local p, ps = setup()
    local Cr, Out, Spec = C(), StoryEngine.Outsiders, StoryEngine.Specialty
    H.ok(not Cr.DEF.boat.when(), "only while Odell is here")
    Out.debug({ what = "arrive", id = "odell" })
    Out.state().here.odell.testT = now().t + 999 * 1440
    Out.state().here.odell.askT = now().t + 999 * 1440
    H.ok(Cr.DEF.boat.when())
    H.eq(Out.orderPrice(), 2)
    Cr.start("boat")
    local morale = res("casey", "morale")
    H.ok(Cr.choose(p, "hold"))
    H.eq(res("casey", "morale"), math.max(0, morale - Cr.BOAT_HOLD))
    H.ok(not P().mod("specBlock", "casey"))
    Cr.state().done.boat = nil
    Cr.start("boat")
    H.ok(Cr.choose(p, "let"))
    H.eq(trust("casey"), 53)
    H.eq(Spec.status("casey", ps.key).reason, "upriver")
    H.ok(P().mod("tradeBlock", "casey", "tools"))
    H.eq(Cr.payload("tester").fx[1].id, "boat")
    -- 두 달 뒤 돌아온다
    H.advanceDays(Cr.BOAT_DAYS + 1)
    quiet()
    Cr.state().nextT = now().t + 999 * 1440
    Out.state().nextT = now().t + 999 * 1440
    Cr.tick()
    H.ok(not P().mod("specBlock", "casey"))
    H.eq(trust("casey"), 58)
    H.eq(Out.orderPrice(), 1.5, "the new route makes river goods cheaper")
    H.eq(Cr.payload("tester").fx[1].id, "route")
end

function T.the_court_martial()
    local p, ps = setup()
    local Cr, Out, Spec = C(), StoryEngine.Outsiders, StoryEngine.Specialty
    Out.debug({ what = "arrive", id = "hale" })
    Out.state().here.hale.testT = now().t + 999 * 1440
    setTrust("hale", 50)
    Cr.start("tribunal")
    H.ok(Cr.choose(p, "testify"))
    H.eq(trust("hale"), 55)
    H.eq(trust("guard"), 40)
    H.eq(Spec.status("guard", ps.key).reason, "confined")
    -- 숨겨 준다
    Cr.state().done.tribunal = nil
    Cr.state().fx.tribunal = nil
    trustAll(50)
    setTrust("hale", 50)
    Cr.start("tribunal")
    H.ok(Cr.choose(p, "hide"))
    H.eq(trust("guard"), 55)
    H.eq(trust("hale"), 40)
    -- 의회 이름으로 거부: 표결에 부친다
    Cr.state().done.tribunal = nil
    trustAll(50)
    setTrust("hale", 50)
    Cr.start("tribunal")
    H.ok(Cr.choose(p, "refuse"))
    local bill = P().state().bill
    H.eq(bill.id, "refuse")
    H.ok(Cr.state().current.waiting)
    H.eq(P().need(bill, "guard"), 30, "the man on trial wants it most")
    H.ok(P().vote(now()).pass)
    H.eq(trust("hale"), 45)
    H.eq(trust("guard"), 53)
    H.eq(trust("ray"), 51)
    H.eq(Cr.state().current, nil)
    H.eq(Cr.state().fx.tribunal, nil)
    -- 부결되면 재판이 열린다
    Cr.state().done.tribunal = nil
    trustAll(20)
    setTrust("hale", 50)
    Cr.start("tribunal")
    Cr.choose(p, "refuse")
    H.ok(not P().vote(now()).pass)
    H.ok(Cr.state().fx.tribunal, "voted down: the trial goes ahead")
end

return T
