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

-- 돕겠다고 나선 사람 (2026-10-18): 당사자가 자기 방식을 고르면 돕던 사람은 외면이 아니다
function T.marcus_helpers_are_not_snubbed_when_june_decides()
    local p = setup()
    local pike, guard, doc = trust("pike"), trust("guard"), trust("doc")
    choose(p, "marcus", "doc")
    H.ok(trust("doc") > doc, "June chosen")
    H.eq(trust("pike"), pike, "Pike was helping June: no loss")
    H.eq(trust("guard"), guard, "Whitaker was helping June: no loss")
    H.eq(StoryEngine.Stories.crisisRole("marcus", "doc", "guard"), "helper")
    H.ok(flags("pike").marcus_spared and not flags("guard").marcus_snubbed)
    -- 휘태커가 마커스를 데려가는 걸 고르면 준은 여전히 외면당한다
    H.eq(StoryEngine.Stories.crisisRole("marcus", "guard", "doc"), "snubbed")
    local pre = StoryEngine.Stories.choicePreview("marcus", "doc")
    local by = {}
    for _, e in ipairs(pre) do by[e.faction] = e end
    H.ok(by.doc.trust == 2 and by.pike.role == "helper" and by.guard.trust == 0)
end

function T.commons_is_only_half_a_snub()
    local p = setup()
    local pike, rats, guard = trust("pike"), trust("rats"), trust("guard")
    choose(p, "commons", "ray")
    H.eq(trust("pike"), pike - 1)
    H.eq(trust("rats"), rats - 1)
    H.eq(trust("guard"), guard - 1)
    H.eq(StoryEngine.Stories.choicePreview("commons", "ray")[2].trust, -1)
end

function T.thief_hank_and_ray_understand_each_other()
    H.eq(StoryEngine.Stories.crisisRole("thief", "ray", "hunter"), "spared")
    H.eq(StoryEngine.Stories.crisisRole("thief", "hunter", "ray"), "spared")
    H.eq(StoryEngine.Stories.crisisRole("thief", "guard", "hunter"), "snubbed")
end

return T
