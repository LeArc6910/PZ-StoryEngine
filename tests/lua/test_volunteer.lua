-- 일거리 청하기 (Work.volunteer) 와 보상 사양 (Quests.waiveReward), 2026-10-06 사용자 요청:
-- 보수 없이 일해 주고 신뢰도 +등급 x 2 (NPC 마다 주 2번, 실패하면 -등급), 보상 보급을 남겨 주면 신뢰도 +부탁 등급
local T = {}

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

local function setup(trust)
    mockBuildings()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    StoryEngine.Life.daily()
    StoryEngine.Radio.channel("ray").trust = trust or 30
    return p, ps
end

local function quest(id) return StoryEngine.Store.data().quests[id] end

local function listed(p, id)
    for _, item in ipairs(StoryEngine.Quests.listFor(StoryEngine.Store.playerKey(p), StoryEngine.Sensor.now())) do
        if item.id == id then return item end
    end
    return nil
end

function T.tier_follows_trust_and_stage()
    setup(30)
    local Work = StoryEngine.Work
    H.eq(Work.volunteerTier("ray"), 2, "trust 30 -> tier 2")
    StoryEngine.Radio.channel("ray").trust = 85
    H.eq(Work.volunteerTier("ray"), 2, "early stage caps it at 2")
    StoryEngine.Store.STAGE_MAX_TIER = { 5, 5, 5 }
    H.eq(Work.volunteerTier("ray"), 5)
    StoryEngine.Radio.channel("ray").trust = 5
    H.eq(Work.volunteerTier("ray"), 1)
end

function T.volunteer_job_raises_trust_when_done()
    local p = setup(30)
    local Work = StoryEngine.Work
    local ok, how = Work.volunteer(p, "ray", "horde")
    H.ok(ok and how == "horde", "a clearing job")
    local parent = nil
    for _, q in pairs(StoryEngine.Store.data().quests) do
        if q.kind == "volunteer" then parent = q end
    end
    H.ok(parent and parent.workId, "hidden parent with a job")
    H.ok(listed(p, parent.id) == nil, "the parent is not in the quest list")
    local item = listed(p, parent.workId)
    H.ok(item and item.work and item.work.volunteer and item.work.gain == 4, "the job shows trust +4")
    local ok2, why = Work.volunteer(p, "ray", "horde")
    H.ok(not ok2 and why == "open", "one job at a time")
    local food = StoryEngine.Life.npc("ray").res.food
    StoryEngine.Quests.setState(quest(parent.workId), "completed", StoryEngine.Sensor.now(), nil)
    H.eq(parent.state, "completed")
    H.eq(StoryEngine.Radio.channel("ray").trust, 34, "tier 2 x 2")
    H.eq(StoryEngine.Life.npc("ray").res.food, math.min(100, food + 20), "ray's food +10 x tier")
    H.eq(StoryEngine.Work.volunteerStatus("ray").left, 1)
end

function T.failed_volunteer_job_costs_trust_and_week_is_limited()
    local p = setup(30)
    local Work = StoryEngine.Work
    H.ok(Work.volunteer(p, "ray", "horde"))
    local child = nil
    for _, q in pairs(StoryEngine.Store.data().quests) do
        if q.kind == "volunteer" then child = quest(q.workId) end
    end
    StoryEngine.Quests.setState(child, "failed", StoryEngine.Sensor.now(), nil)
    H.eq(StoryEngine.Radio.channel("ray").trust, 28, "minus the tier")
    H.ok(Work.volunteer(p, "ray", "horde"), "second this week")
    for _, q in pairs(StoryEngine.Store.data().quests) do
        if q.kind == "volunteer" and q.state == "accepted" then
            StoryEngine.Quests.setState(quest(q.workId), "completed", StoryEngine.Sensor.now(), nil)
        end
    end
    local ok, why = Work.volunteer(p, "ray", "horde")
    H.ok(not ok and why == "week", "two a week")
    H.advance(7 * 24 * 60 + 1)
    H.ok(Work.volunteer(p, "ray", "horde"), "a week later")
end

function T.npc_reward_can_be_left_to_them()
    local p, ps = setup(30)
    local Q = StoryEngine.Quests
    local now = StoryEngine.Sensor.now()
    local d = StoryEngine.Store.data()
    d.quests.Q800 = { id = "Q800", kind = "deliver", state = "completed", tier = 3, origin = { source = "director", faction = "ray" } }
    local reward = Q.create("supply_drop", p, ps, 1, now,
        { source = "reward", faction = "ray", rewardFor = "Q800", rewardKind = "deliver" }, { "Base.TinnedBeans" })
    H.ok(reward, "reward drop")
    H.eq(Q.waiveTier(reward), 3, "the request's tier")
    H.eq(listed(p, reward.id).waiveGain, 3)
    local ok, gain = Q.waiveReward(p, reward.id)
    H.ok(ok and gain == 3, "trust +3")
    H.eq(reward.state, "declined")
    H.ok(reward.waived)
    H.eq(StoryEngine.Radio.channel("ray").trust, 33)
    H.ok(not Q.waiveReward(p, reward.id), "only once")
    -- 거래로 산 물건은 사양할 수 없다
    d.quests.Q801 = { id = "Q801", kind = "trade", state = "completed", tier = 2, origin = { source = "radio", faction = "ray" } }
    local bought = Q.create("supply_drop", p, ps, 1, now,
        { source = "reward", faction = "ray", rewardFor = "Q801", rewardKind = "trade" }, { "Base.TinnedBeans" })
    H.eq(Q.waiveTier(bought), nil)
    local ok2, why = Q.waiveReward(p, bought.id)
    H.ok(not ok2 and why == "not_waivable")
end

return T
