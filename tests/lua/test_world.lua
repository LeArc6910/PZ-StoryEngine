-- 게임 날짜에 맞춘 세계 변화 (World.lua, 아이디어 4번)
local T = {}

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    SandboxVars.ElecShutModifier = 1000
    SandboxVars.WaterShutModifier = 1000
    return p, ps
end

local W = function() return StoryEngine.World end
local function res(fid, r) return StoryEngine.Life.npc(fid).res[r] end
local function radioEvents(fid)
    local n = 0
    for _, b in ipairs(H.bridge) do
        if b.module == "radio" and b.payload.faction == fid and b.payload.mode == "event" then n = n + 1 end
    end
    return n
end
local function noteKinds(ps)
    local out = {}
    for _, n in ipairs(ps.notes or {}) do out[n.kind] = (out[n.kind] or 0) + 1 end
    return out
end

function T.power_goes_out_after_being_seen_on()
    local _, ps = setup()
    SandboxVars.ElecShutModifier = 3
    W().tick()
    H.eq(StoryEngine.Store.data().world.seen.power, true, "saw the power on")
    local morale, med, ray = res("casey", "morale"), res("doc", "medical"), res("ray", "food")
    H.advanceDays(3)
    H.ok(W().powerOff())
    W().tick()
    H.eq(res("casey", "morale"), morale - 15)
    H.eq(res("doc", "medical"), med - 10)
    H.eq(res("ray", "food"), ray, "only casey and doc hit")
    H.eq(radioEvents("casey"), 1, "casey reacts")
    H.eq(radioEvents("doc"), 1, "doc reacts")
    H.eq(noteKinds(ps).world_power, 1, "journal note")
    local qt = StoryEngine.Store.data().social.queuedTopic
    H.ok(qt and qt.ids[1] == "casey" and qt.ids[2] == "doc", "scene topic for casey and doc")
    local facts = table.concat(StoryEngine.Broadcast.gather(StoryEngine.Sensor.now()), " ")
    H.ok(string.find(facts, "power grid went down", 1, true), "goes into the radio news")
    local count = #H.bridge
    W().tick()
    H.eq(#H.bridge, count, "only once")
    H.ok(string.find(W().statusText(), "power=off", 1, true), W().statusText())
end

function T.already_off_is_skipped_quietly()
    local _, ps = setup()
    SandboxVars.WaterShutModifier = -1
    local food = res("ray", "food")
    W().tick()
    H.eq(StoryEngine.Store.data().world.done.water, -1)
    H.eq(noteKinds(ps).world_water, nil)
    H.eq(res("ray", "food"), food)
end

function T.water_hits_everyone_and_changes_requests()
    local _, ps = setup()
    SandboxVars.WaterShutModifier = 2
    W().tick()
    local before = {}
    for _, f in ipairs(StoryEngine.Factions.list) do before[f.id] = res(f.id, "food") end
    -- 물이 나올 때는 물 부탁(when = water)이 표에 없다
    local function waterNeeds()
        local n = 0
        for _, e in ipairs(StoryEngine.Needs.available("ray")) do if e.when == "water" then n = n + 1 end end
        return n
    end
    H.eq(waterNeeds(), 0)
    H.advanceDays(2)
    W().tick()
    for _, f in ipairs(StoryEngine.Factions.list) do
        H.eq(res(f.id, "food"), math.max(0, before[f.id] - 10), f.id .. " food -10")
    end
    H.eq(waterNeeds(), 3, "water request weighted x3")
    H.eq(noteKinds(ps).world_water, 1)
end

function T.winter_snow_heating_and_daily_cost()
    local _, ps = setup()
    H.advanceDays(140)          -- 테스트 시계는 28일 = 한 달, 7월(6)부터 140일 뒤가 12월(11)
    H.eq(getGameTime():getMonth(), 11)
    W().tick()
    local done = StoryEngine.Store.data().world.done
    H.ok(done.winter_1993, "winter this season")
    H.eq(done.day30, -1, "long past milestones skipped")
    H.eq(done.day90, -1)
    H.eq(noteKinds(ps).world_winter, 1)
    H.eq(radioEvents("hunter"), 1)
    local heat
    for _, q in pairs(StoryEngine.Store.data().quests) do
        if q.origin and q.origin.faction == "pike" then heat = q end
    end
    H.ok(heat, "pike asks for heating")
    local item = heat.need[1][1]
    H.ok(item == "Base.Firewood" or item == "Base.Sheet", "heating items: " .. tostring(item))
    H.eq(select(2, W().askHeat(StoryEngine.Sensor.now())), "busy", "one heating request at a time")
    local food = res("ray", "food")
    W().dailyExtra()
    H.eq(res("ray", "food"), food - 2, "winter costs food every day")
    -- 첫눈
    H.ok(not done.snow_1993)
    H.climate.snow = true
    W().tick()
    H.ok(done.snow_1993, "first snow")
    H.eq(noteKinds(ps).world_snow, 1)
    W().tick()
    H.eq(noteKinds(ps).world_snow, 1, "once per winter")
end

function T.milestone_day30_scene()
    local _, ps = setup()
    H.advanceDays(29)
    W().tick()
    H.eq(noteKinds(ps).world_day30, 1)
    local qt = StoryEngine.Store.data().social.queuedTopic
    H.ok(qt and string.find(qt.topic, "a month since the outbreak", 1, true), "look-back scene")
    H.eq(radioEvents("ray"), 0, "no separate radio reactions for milestones")
end

function T.option_off_and_debug()
    local p, ps = setup()
    SandboxVars.StoryEngine.WorldChanges = false
    SandboxVars.ElecShutModifier = -1
    W().tick()
    H.eq(StoryEngine.Store.data().world, nil, "disabled: nothing recorded")
    W().dailyExtra()
    SandboxVars.StoryEngine.WorldChanges = true
    H.fire("OnClientCommand", StoryEngine.MODULE, "debugWorld", p, { event = "day90" })
    H.eq(noteKinds(ps).world_day90, 1, "debug command fires it (single player)")
    H.ok(W().fire("day90", "day90_debug_1"))
    H.eq(noteKinds(ps).world_day90, 2, "forced again with a new key")
    H.ok(not W().fire("day90", "day90_debug_1"), "same key only once")
end

return T
