-- NPC 형편이 사건으로 (NpcEvents.lua, 디렉터 npc_emergency, 위기 앞당김·충돌, 장면 화제)
local T = {}

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    for _, it in ipairs({ { "Base.Bandage", "medical", 3 }, { "Base.AlcoholWipes", "medical", 1 },
                          { "Base.Pills", "medical", 3 }, { "Base.Antibiotics", "medical", 8 },
                          { "Base.TinnedBeans", "food", 1.5 }, { "Base.WaterRationCan", "food", 1.5 },
                          { "Base.Battery", "misc", 0.2 } }) do
        H.defineItem(it[1], it[2], it[3])
    end
    return p, ps
end

local NE = function() return StoryEngine.NpcEvents end
local function res(fid, r) return StoryEngine.Life.npc(fid).res[r] end
local function setRes(fid, r, v) StoryEngine.Life.npc(fid).res[r] = v end

local function questsOf(fid)
    local out = {}
    for _, q in pairs(StoryEngine.Store.data().quests) do
        if q.origin and q.origin.faction == fid then out[#out + 1] = q end
    end
    return out
end

function T.urgent_request_asks_for_the_missing_resource()
    local p, ps = setup()
    H.eq(NE().emergency(), nil, "nobody is desperate at the start")
    setRes("doc", "medical", 10)
    local fid, r = NE().emergency()
    H.eq(fid, "doc")
    H.eq(r, "medical")
    StoryEngine.Director.run("debug", "npc_emergency", ps.name)
    local qs = questsOf("doc")
    H.eq(#qs, 1, "doc asked")
    local q = qs[1]
    H.ok(q.urgent, "marked urgent")
    H.eq(StoryEngine.Life.resourceOfItems(q.need), "medical", "asks for medicine even though tier 1 has none")
    local b = H.lastBridge("radio", "request")
    H.ok(b and string.find(b.payload.topic, "URGENT", 1, true), "urgent wording")
    H.ok(not NE().emergencyGapOk(StoryEngine.Sensor.now()), "one a day server-wide")
    H.eq(NE().emergency(), nil, "doc already has an open request")
    local now = StoryEngine.Sensor.now()
    H.ok(StoryEngine.Quests.respond(p, q.id, true))
    H.eq(q.deadlineT - now.t, 24 * 60, "one day to deliver")
    -- 목록에 [급함] 표시용 값
    local list = StoryEngine.Quests.listFor(ps.key, now)
    local urgent = false
    for _, item in ipairs(list.active or list) do if item.urgent then urgent = true end end
    H.ok(urgent, "listed as urgent")
end

function T.raid_crisis_is_brought_forward_when_pike_is_defenceless()
    setup()
    local Social = StoryEngine.Social
    Social.hourly()
    H.ok(not (Social.crisesUsedTable() or {}).raid, "not while pike is fine")
    setRes("pike", "safety", 10)
    Social.hourly()
    H.ok(Social.crisesUsedTable().raid, "raid crisis started")
    local choice
    for _, q in pairs(StoryEngine.Store.data().quests) do if q.kind == "choice" then choice = q end end
    H.eq(choice.crisis, "raid")
end

function T.sharing_between_friends_only()
    setup()
    local now = StoryEngine.Sensor.now()
    setRes("ray", "food", 90)
    setRes("casey", "food", 10)
    H.ok(NE().share(now))
    H.eq(res("ray", "food"), 75)
    H.eq(res("casey", "food"), 25)
    H.eq(StoryEngine.Store.data().social.queuedTopic.ids[1], "ray", "next scene is about it")
    setRes("ray", "food", 90)
    setRes("pike", "food", 5)
    H.ok(not NE().share(now), "two-day gap")
    -- 적대하는 사이는 나누지 않는다: 방위대 -> 빅
    H.advanceDays(3)
    for _, f in ipairs(StoryEngine.Factions.list) do setRes(f.id, "safety", 50) end
    setRes("ray", "food", 50)
    setRes("guard", "safety", 95)
    setRes("rats", "safety", 5)
    H.ok(not NE().share(StoryEngine.Sensor.now()), "guard never supplies Vic")
end

function T.clash_hits_both_and_sometimes_becomes_a_crisis()
    setup()
    local now = StoryEngine.Sensor.now()
    setRes("guard", "safety", 60)
    H.rolls = { 0 }
    H.ok(not NE().clash(now), "guard too weak to pick a fight")
    setRes("guard", "safety", 80)
    H.rolls = { 50 }
    H.ok(not NE().clash(now), "30% roll failed")
    H.rolls = { 10, 90 }
    H.ok(NE().clash(now))
    H.eq(res("guard", "safety"), 65)
    H.eq(res("rats", "safety"), 45)
    H.ok(not (StoryEngine.Social.crisesUsedTable() or {}).clash, "no crisis this time")
    H.advanceDays(6)
    setRes("guard", "safety", 80)
    H.rolls = { 10, 10 }
    H.ok(NE().clash(StoryEngine.Sensor.now()))
    H.ok(StoryEngine.Social.crisesUsedTable().clash, "clash crisis started")
end

function T.trigger_crises_never_come_at_random()
    setup()
    local Social = StoryEngine.Social
    Social.startCrisis(StoryEngine.Sensor.now())
    local used = Social.crisesUsedTable()
    for _, id in ipairs({ "truck", "fever", "signal", "raid" }) do used[id] = true end
    local ok, why = Social.startCrisis(StoryEngine.Sensor.now())
    H.eq(why, "no_crisis", "clash only comes from a real clash")
end

function T.queued_topic_drives_the_next_scene()
    setup()
    StoryEngine.Social.queueTopic({ "guard", "rats" }, "They blame each other.")
    StoryEngine.Social.scene(nil)
    local b = H.lastBridge("radio_scene")
    H.eq(b.payload.topic, "They blame each other.")
    H.eq(b.payload.participants[1].id, "guard")
    H.eq(b.payload.participants[2].id, "rats")
    H.eq(StoryEngine.Store.data().social.queuedTopic, nil, "used once")
end

function T.director_ai_sees_the_contacts_situation()
    setup()
    StoryEngine.Fate.apply("hunter", "gone", "debug")
    StoryEngine.Director.run("schedule")
    local b = H.lastBridge("director")
    H.ok(b, "director asked")
    H.eq(#b.payload.npcs, 7, "the seven still on the air")
    H.eq(b.payload.npcs[1].id, "ray")
    H.eq(b.payload.npcs[1].state.food, 45)
end

function T.daily_runs_share_and_clash()
    setup()
    local Life = StoryEngine.Life
    Life.daily()
    setRes("ray", "food", 95)
    setRes("casey", "food", 10)
    H.advanceDays(1)
    Life.daily()
    H.eq(res("casey", "food"), 25, "casey got food from ray on the day tick (10 + 15, no self-recovery below 20)")
end

return T
