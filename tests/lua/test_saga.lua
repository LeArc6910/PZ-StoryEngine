-- 여러 날 이어지는 큰 사건 (Saga.lua): 일정, 헬기 추락, 대이동, 열병, 통신 두절
local T = {}

-- 어디를 찾든 그 자리에 10x10 비주거 건물이 하나 있는 메타그리드
local function mockAnywhereBuildings()
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

local function setup()
    mockAnywhereBuildings()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    H.clockMin = 30 * 1440 + 9 * 60
    -- 가짜 환경에서 값을 모르는 물건은 총기로 분류되므로 부탁에 쓰는 의약품은 정해 둔다 (품목 점수로 바뀌지 않게)
    H.defineItem("Base.Antibiotics", "medical", 4)
    H.defineItem("Base.Bandage", "medical", 2)
    return p, ps
end

local function tick(minutes)
    H.advance(minutes or 10)
    StoryEngine.Saga.tick(StoryEngine.Sensor.now())
end

local function role(sg, r) return StoryEngine.Store.data().quests[sg.quests[r]] end
local function res(fid, r) return StoryEngine.Life.npc(fid).res[r] end

function T.schedule_waits_for_day_25_then_starts_one()
    setup()
    local Saga, Store = StoryEngine.Saga, StoryEngine.Store
    local d = Store.data()
    d.dayCount = 10
    Store.serverDays = function() return 10 end
    Saga.daily(StoryEngine.Sensor.now())
    H.ok(not Saga.active() and d.saga.nextT == nil, "too early")
    Store.serverDays = function() return 26 end
    H.advanceDays(1)
    H.rolls = { 0 }
    Saga.daily(StoryEngine.Sensor.now())
    H.ok(d.saga.nextT ~= nil and not Saga.active(), "first one scheduled within a week")
    H.advanceDays(1)
    Saga.daily(StoryEngine.Sensor.now())
    H.ok(Saga.active(), "started")
    H.ok(StoryEngine.Director.openAskers({ now = StoryEngine.Sensor.now() }) == nil, "no NPC requests during an event")
end

function T.crash_choice_doc_gets_the_medicine()
    local p, ps = setup()
    local Saga, Quests = StoryEngine.Saga, StoryEngine.Quests
    H.ok(Saga.start("crash", "test"))
    local sg = Saga.current()
    H.eq(sg.stageId, "omen")
    Saga.debug("next")
    H.eq(sg.stageId, "crash")
    local crate = role(sg, "crate")
    H.ok(crate and crate.kind == "supply_drop" and #crate.items == #Saga.CRASH_CRATE, "crate at the wreck")
    local choice
    for _, q in pairs(StoryEngine.Store.data().quests) do
        if q.kind == "choice" and q.crisis == "heli_crash" then choice = q end
    end
    H.ok(choice, "who gets the cargo")
    H.ok(Quests.choose(p, choice.id, 3))
    H.eq(choice.chosen, "doc")
    local follow
    for _, q in pairs(StoryEngine.Store.data().quests) do
        if q.kind == "deliver" and q.origin.story and q.origin.story.crisis == "heli_crash" then follow = q end
    end
    H.ok(follow and follow.state == "accepted")
    -- 현장 상자에서 꺼낸 물건(끝난 퀘스트 태그)도 낼 수 있다
    crate.state = "completed"
    H.give(p, "Base.Antibiotics", { questTag = crate.id })
    for _ = 1, 4 do H.give(p, "Base.Bandage", { questTag = crate.id }) end
    H.ok(Quests.submit(p, follow.id))
    local before = res("doc", "medical")
    Saga.debug("next")
    H.eq(sg.stageId, "swarm")
    H.ok(H.logHas("hunt start"), "the dead swarm the wreck")
    Saga.debug("next")
    H.ok(not Saga.active())
    H.eq(StoryEngine.Store.data().saga.history[1].result, "doc")
    H.eq(res("doc", "medical"), math.min(100, before + 30))
end

function T.migration_unbarricaded_base_is_stripped()
    setup()
    local Saga, Quests = StoryEngine.Saga, StoryEngine.Quests
    StoryEngine.Life.daily()
    Saga.start("migration", "test")
    local sg = Saga.current()
    Saga.debug("next")
    H.eq(sg.stageId, "pressure")
    local rayQ, pikeQ = role(sg, "ray"), role(sg, "pike")
    H.ok(rayQ.kind == "collect" and pikeQ.kind == "collect")
    local ray0, pike0 = res("ray", "safety"), res("pike", "safety")
    tick()
    H.eq(res("ray", "safety"), ray0 - 10, "first day drain")
    rayQ.got = {}
    for _, n in ipairs(rayQ.need) do rayQ.got[n[1]] = n[2] end
    rayQ.state = "accepted"
    -- 마지막 하나를 보낸 것처럼 완료
    local p = H.players[1]
    rayQ.got[rayQ.need[1][1]] = rayQ.need[1][2] - 1
    H.give(p, rayQ.need[1][1])
    H.ok(Quests.submit(p, rayQ.id))
    H.eq(rayQ.state, "completed")
    H.ok(sg.data.held.ray)
    tick(24 * 60)
    H.eq(res("ray", "safety"), ray0 - 10, "held: no more drain")
    H.eq(res("pike", "safety"), math.max(0, pike0 - 20), "pike keeps losing")
    Saga.debug("next")
    H.eq(sg.stageId, "horde")
    Saga.debug("next")
    H.eq(StoryEngine.Store.data().saga.history[1].result, "one")
    H.eq(res("ray", "safety"), math.min(100, ray0 - 10 + 20))
end

function T.epidemic_doc_falls_ill_and_too_little_medicine_kills()
    setup()
    local Saga = StoryEngine.Saga
    StoryEngine.Life.daily()
    Saga.start("epidemic", "test")
    Saga.debug("next")
    local sg = Saga.current()
    H.eq(sg.stageId, "spread")
    H.ok(role(sg, "medicine").kind == "collect")
    Saga.debug("next")
    H.eq(sg.stageId, "docill")
    H.eq(StoryEngine.Specialty.status("doc").reason, "ill")
    StoryEngine.Life.change("hunter", "medical", -50, "test")
    H.rolls = { 10 }                           -- 50% 죽음 판정
    Saga.debug("next")
    H.ok(not Saga.active())
    H.eq(StoryEngine.Store.data().saga.history[1].result, "death")
    H.ok(StoryEngine.Factions.isGone("hunter"), "the weakest did not make it")
    H.ok(StoryEngine.Specialty.status("doc").reason ~= "ill", "doc recovered")
end

function T.blackout_silences_everyone_but_casey_until_fixed()
    local p, ps = setup()
    local Saga, Quests, Radio = StoryEngine.Saga, StoryEngine.Quests, StoryEngine.Radio
    Saga.start("blackout", "test")
    Saga.debug("next")
    local sg = Saga.current()
    H.eq(sg.stageId, "silence")
    H.ok(Saga.radioDown("ray") and not Saga.radioDown("casey"))
    H.ok(Radio.say(p, "ray", "anyone there?"))
    local msgs = Radio.channel("ray").messages
    H.eq(msgs[#msgs].error, "blackout", "static on ray's channel")
    H.eq(Radio.request("ray", "EN"), false, "ray cannot answer")
    Quests.completeHorde(role(sg, "mast"))
    local parts = role(sg, "parts")
    for _, n in ipairs(parts.need) do for _ = 1, n[2] do H.give(p, n[1]) end end
    H.ok(Quests.submit(p, parts.id))
    tick()
    H.ok(not Saga.active(), "ends early once both are done")
    H.eq(StoryEngine.Store.data().saga.history[1].result, "fixed")
    H.ok(not Saga.radioDown("ray"))
end

function T.events_and_operations_do_not_overlap()
    setup()
    local Saga, Ops = StoryEngine.Saga, StoryEngine.Ops
    Saga.start("blackout", "test")
    local ok, why = Saga.debug("start", "crash")
    H.ok(Saga.current().kind == "crash", "debug replaces the current event")
    Saga.debug("stop")
    local so = { values = { ElecShutModifier = 14, WaterShutModifier = 14 } }
    function so:set(n, v) self.values[n] = v end
    function so:getElecShutModifier() return self.values.ElecShutModifier end
    function so:getWaterShutModifier() return self.values.WaterShutModifier end
    function so:getTimeSinceApo() return 1 end
    function so:toLua() end
    function so:doesPowerGridExist() return false end
    getSandboxOptions = function() return so end
    Saga.start("crash", "test")
    H.rolls = { 0, 0 }
    Ops.daily(StoryEngine.Sensor.now())
    H.ok(not Ops.active(), "operation waits for the event")
    H.ok(#StoryEngine.Store.data().ops.queue > 0, "queued")
end

return T
