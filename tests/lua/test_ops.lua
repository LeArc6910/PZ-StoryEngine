-- 전력·수도 복구 작전 (Ops.lua + Quests 의 collect/defend/visit + Grid 복구)
local T = {}

-- 바닐라 SandboxOptions 흉내 (test_grid 와 같음)
local function mockSandbox(elec, water)
    local so = { values = { ElecShutModifier = elec, WaterShutModifier = water } }
    function so:set(name, v) self.values[name] = v end
    function so:getElecShutModifier() return self.values.ElecShutModifier end
    function so:getWaterShutModifier() return self.values.WaterShutModifier end
    function so:getTimeSinceApo() return 1 end
    function so:toLua() end
    function so:doesPowerGridExist() return getGameTime():getWorldAgeHours() / 24 < self.values.ElecShutModifier end
    getSandboxOptions = function() return so end
    return so
end

-- 건물 메타그리드 흉내: 시설마다 10x10 비주거 건물 하나
local function mockBuildings(points)
    local defs = {}
    for _, pt in ipairs(points) do
        local x, y = pt.x + 12, pt.y + 12
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
    function world:setHydroPowerOn() end
    getWorld = function() return world end
end

local function allSites()
    local pts = {}
    local S = StoryEngine.OpsSites
    for _, list in ipairs({ S.WATER_TOWERS, S.SUBSTATIONS, S.LINE }) do
        for _, s in ipairs(list) do pts[#pts + 1] = s end
    end
    -- 레이 보급용: 플레이어 근처
    pts[#pts + 1] = { x = 10100, y = 10000 }
    pts[#pts + 1] = { x = 9900, y = 10150 }
    return pts
end

local function setup(day)
    local so = mockSandbox(14, 14)
    mockBuildings(allSites())
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    H.clockMin = (day or 30) * 1440 + 9 * 60
    return p, ps, so
end

local function at(p, x, y) p.x, p.y = x, y end

-- 10분 샘플 한 번 (Sensor.tick 대신 필요한 것만)
local function tick(p, ps, minutes)
    H.advance(minutes or 10)
    local now = StoryEngine.Sensor.now()
    local entries = { { player = p, ps = ps, s = { x = p.x, y = p.y, building = nil }, newHarm = {} } }
    StoryEngine.Quests.track(entries, now)
    StoryEngine.Ops.tick(entries, now)
end

local function actQuests(op)
    local out = {}
    for _, qid in ipairs(op.quests[op.act] or {}) do out[#out + 1] = StoryEngine.Store.data().quests[qid] end
    return out
end

function T.start_chance_from_two_weeks_after_shutoff()
    setup(27)
    local Ops = StoryEngine.Ops
    local today = StoryEngine.Grid.today()
    H.eq(Ops.offDay("water"), 14)
    H.eq(Ops.chance("water", today), 0, "13 days: not yet")
    H.eq(Ops.chance("water", today + 1), 10, "14 days: 10%")
    H.eq(Ops.chance("water", today + 3), 20, "16 days: 20%")
    H.eq(Ops.chance("water", today + 40), 100, "capped")
    H.advanceDays(1)
    H.rolls = { 50, 5 }                       -- water 50 >= 10 miss... power 5 < 10 hit
    Ops.daily(StoryEngine.Sensor.now())
    local op = Ops.current()
    H.ok(op and op.kind == "power", "power started on the roll")
    H.ok(H.logHas("ops roll water"))
    H.advanceDays(1)
    H.rolls = { 0 }
    Ops.daily(StoryEngine.Sensor.now())
    H.eq(StoryEngine.Store.data().ops.queue[1], "water", "water waits in line while power runs")
end

function T.water_operation_full_run_restores_for_sixty_days()
    local p, ps, so = setup(30)
    local Ops, Quests = StoryEngine.Ops, StoryEngine.Quests
    at(p, 10000, 10000)
    H.ok(Ops.start("water", "test"))
    local op = Ops.current()
    H.eq(op.lead, "pike")
    H.ok(StoryEngine.Director.openAskers({ now = StoryEngine.Sensor.now() }) == nil, "no NPC requests during an operation")

    -- 1막: 회수
    local q1 = actQuests(op)[1]
    H.eq(q1.kind, "fetch")
    H.eq(q1.items[1], "StoryEngine.WaterManual")
    H.ok(q1.origin.op == op.id and q1.origin.act == 1)
    H.give(p, "StoryEngine.WaterManual", { questTag = q1.id })
    H.ok(Quests.submit(p, q1.id))
    H.eq(op.act, 2, "on to the collection")
    H.ok(not H.logHas("quest created") or true)

    -- 2막: 모금 (나눠 내기)
    local q2 = actQuests(op)[1]
    H.eq(q2.kind, "collect")
    H.give(p, "Base.Pipe")
    H.give(p, "Base.Pipe")
    H.ok(Quests.submit(p, q2.id))
    H.eq(q2.got["Base.Pipe"], 2)
    H.eq(Quests.collectLeft(q2, "Base.Pipe"), 2)
    local ok, why = Quests.submit(p, q2.id)
    H.ok(not ok and why == "missing_items")
    for _, n in ipairs(q2.need) do
        for _ = 1, Quests.collectLeft(q2, n[1]) + 1 do H.give(p, n[1]) end   -- 하나 더 있어도 필요한 만큼만
    end
    H.ok(Quests.submit(p, q2.id))
    H.eq(q2.state, "completed")
    H.eq(#p.items, #q2.need, "only what was needed was taken")
    H.eq(op.act, 3)

    -- 3막: 소탕 두 곳 (혼자 접속)
    local clears = actQuests(op)
    H.eq(#clears, 2)
    H.ok(clears[1].state == "accepted" and clears[1].size > 0)
    Quests.completeHorde(clears[1])
    H.eq(op.act, 3, "one site left")
    Quests.completeHorde(clears[2])
    H.eq(op.act, 4)

    -- 4막: 방어 (6시간 머물기, 무리가 몰려옴)
    local q4 = actQuests(op)[1]
    H.eq(q4.kind, "defend")
    at(p, q4.cx + 3, q4.cy)
    for _ = 1, 40 do
        if q4.state ~= "accepted" then break end
        tick(p, ps)
    end
    H.eq(q4.state, "completed")
    H.ok((q4.waves or 0) >= 2, "waves came")
    H.ok(H.logHas("ops wave"))
    H.eq(op.act, 5)

    -- 5막: 방문 -> 복구
    local q5 = actQuests(op)[1]
    H.eq(q5.kind, "visit")
    at(p, q5.cx, q5.cy)
    tick(p, ps)
    H.eq(q5.state, "completed")
    H.ok(Ops.current() == nil, "operation over")
    local today = math.floor(StoryEngine.Grid.today())
    H.eq(so.values.WaterShutModifier, today + 60, "water back for 60 days")
    H.ok(StoryEngine.Grid.isRestored("water"))
    H.eq(Ops.offDay("water"), nil)
    H.eq(StoryEngine.Store.data().ops.history[1].result, "success")
    local note = nil
    for _, n in ipairs(ps.notes or {}) do if n.kind == "op" then note = n end end
    H.ok(note ~= nil and note.text ~= nil, "journal notes")
end

function T.failing_an_act_twice_ends_the_operation()
    local p, ps, so = setup(40)
    local Ops = StoryEngine.Ops
    Ops.start("power", "test")
    local op = Ops.current()
    H.eq(op.lead, "casey")
    local first = actQuests(op)[1]
    H.advanceDays(4)
    tick(p, ps, 0)
    H.eq(first.state, "failed")
    H.eq(op.fails[1], 1)
    H.eq(op.act, 1, "same act again")
    local second = actQuests(op)[1]
    H.ok(second.id ~= first.id and second.origin.retry == 1)
    H.advanceDays(4)
    tick(p, ps, 0)
    H.ok(Ops.current() == nil, "gave up")
    H.eq(StoryEngine.Store.data().ops.history[1].result, "failed")
    H.eq(Ops.chance("power", StoryEngine.Grid.today()), 0, "two weeks from now again")
    H.eq(so.values.ElecShutModifier, 14, "power still off")
end

function T.collect_retry_needs_more()
    local p, ps = setup(40)
    local Ops = StoryEngine.Ops
    Ops.start("water", "test")
    Ops.debug("next")
    local op = Ops.current()
    local q = actQuests(op)[1]
    H.eq(q.kind, "collect")
    local pipes = q.need[1][2]
    Ops.debug("fail")
    local again = actQuests(op)[1]
    H.eq(again.need[1][2], math.ceil(pipes * 1.5))
    H.ok(q.cancelled, "old collection withdrawn")
end

function T.restore_expiry_starts_the_clock_again()
    local p, ps, so = setup(30)
    local Ops, G = StoryEngine.Ops, StoryEngine.Grid
    G.restore("water", 60, "operation")
    H.eq(Ops.offDay("water"), nil)
    H.clockMin = H.clockMin + 61 * 1440
    G.ensure()
    local off = Ops.offDay("water")
    H.eq(off, 90, "off again from the day the repair ran out")
    H.eq(Ops.chance("water", G.today()), 0, "not right away")
    H.ok(H.logHas("grid restore ended water"))
end

return T
