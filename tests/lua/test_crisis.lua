-- 위기 선택지의 당사자 처지 (2026-09-30 점검): 고른 쪽 / 함께 도운 것(allies) / 이해함(spares) / 외면
local T = {}

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    StoryEngine.Store.player(p).lang = "EN"
    return p
end

local function trust(fid) return StoryEngine.Radio.channel(fid).trust end
local function flags(fid) return StoryEngine.Social.story(fid).flags end

local function choose(p, crisis, fid)
    H.ok(StoryEngine.Social.startCrisis(StoryEngine.Sensor.now(), crisis))
    local q
    for _, x in pairs(StoryEngine.Store.data().quests) do
        if x.kind == "choice" and x.crisis == crisis then q = x end
    end
    local idx
    for i, o in ipairs(q.options) do if o.faction == fid then idx = i end end
    H.ok(StoryEngine.Quests.choose(p, q.id, idx))
    return q
end

function T.raid_guard_patrol_also_helps_the_church()
    local p = setup()
    local pike, guard, rats = trust("pike"), trust("guard"), trust("rats")
    choose(p, "raid", "guard")
    H.ok(trust("guard") > guard, "guard chosen")
    H.ok(trust("pike") > pike, "pike helped too, no snub or spillover")
    H.ok(trust("rats") < rats, "Vic snubbed")
    H.ok(flags("pike").raid_helped, "church story: held")
    H.eq(flags("pike").raid_snubbed, nil)
    H.eq(StoryEngine.Stories.crisisRole("raid", "guard", "pike"), "ally")
    -- 방위대 순찰이 끝나면 교회도 같은 결과
    local fq
    for _, x in pairs(StoryEngine.Store.data().quests) do
        local tag = x.origin and x.origin.story
        if tag and tag.crisis == "raid" and x.origin.faction == "guard" and x.kind ~= "choice" then fq = x end
    end
    H.ok(fq, "guard's follow-up request")
    StoryEngine.Social.onQuest(fq, "completed", StoryEngine.Sensor.now())
    H.ok(flags("guard").raid_done)
    H.ok(flags("pike").raid_done, "the church shares the outcome")
    local log = StoryEngine.Life.npc("pike").log
    H.eq(log[#log].kind, "crisis_ally")
end

function T.raid_pike_spares_guard()
    local p = setup()
    local guard, rats = trust("guard"), trust("rats")
    choose(p, "raid", "pike")
    H.eq(trust("guard"), guard, "guard wanted the church safe too")
    H.ok(flags("guard").raid_spared)
    H.ok(trust("rats") < rats, "Vic snubbed")
end

function T.clash_doc_spares_both_sides()
    local p = setup()
    local guard, rats = trust("guard"), trust("rats")
    choose(p, "clash", "doc")
    H.eq(trust("guard"), guard)
    H.eq(trust("rats"), rats)
    H.eq(StoryEngine.Bonds.get("guard", "doc"), 0, "no grudge")
end

function T.truck_is_a_real_competition()
    local p = setup()
    local ray, rats = trust("ray"), trust("rats")
    choose(p, "truck", "guard")
    H.ok(trust("ray") < ray)
    H.ok(trust("rats") < rats)
end

return T
