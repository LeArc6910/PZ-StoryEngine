-- 인물 탭 (Chronicle.lua, 2026-10-07): 지나온 일 기록과 이야기에 따라 바뀌는 프로필
local T = {}

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    StoryEngine.Store.player(p).lang = "EN"
    return p
end

local function kinds(fid)
    local out = {}
    for _, e in ipairs(StoryEngine.Chronicle.list(fid)) do out[#out + 1] = e.k end
    return table.concat(out, ",")
end

local function last(fid)
    local list = StoryEngine.Chronicle.list(fid)
    return list[#list]
end

function T.story_beats_are_recorded_and_change_the_profile()
    setup()
    local Social = StoryEngine.Social
    Social.story("ray")
    H.eq(last("ray").k, "beat")
    H.eq(last("ray").node, "ray_1", "the first beat is written down")
    Social.moveTo("ray", "ray_4a", StoryEngine.Sensor.now())
    H.eq(last("ray").node, "ray_4a")
    H.eq(Social.story("ray").profile.family, "alive", "Annie is alive now")
    Social.moveTo("ray", "ray_6a", StoryEngine.Sensor.now())
    local prof = Social.story("ray").profile
    H.eq(prof.home, "road", "Ray is on the road")
    H.eq(prof.family, "alive", "earlier changes stay")
end

function T.trust_thresholds_are_written_once()
    setup()
    local ch = StoryEngine.Radio.channel("hunter")
    ch.trust = 15
    StoryEngine.Trust.apply("hunter", 30, "debug")
    H.eq(last("hunter").k, "trust")
    H.eq(last("hunter").v, 40, "crossed 20 and 40")
    local n = #StoryEngine.Chronicle.list("hunter")
    StoryEngine.Trust.apply("hunter", -30, "debug")
    StoryEngine.Trust.apply("hunter", 30, "debug")
    H.eq(#StoryEngine.Chronicle.list("hunter"), n, "only the first time")
end

function T.crisis_roles_fate_and_deaths_are_recorded()
    local p = setup()
    H.ok(StoryEngine.Social.startCrisis(StoryEngine.Sensor.now(), "raid"))
    local q
    for _, x in pairs(StoryEngine.Store.data().quests) do
        if x.kind == "choice" and x.crisis == "raid" then q = x end
    end
    local idx
    for i, o in ipairs(q.options) do if o.faction == "guard" then idx = i end end
    H.ok(StoryEngine.Quests.choose(p, q.id, idx))
    local roles = {}
    for _, fid in ipairs({ "guard", "pike", "rats" }) do
        for _, e in ipairs(StoryEngine.Chronicle.list(fid)) do
            if e.k == "crisis" then roles[fid] = e.role end
        end
    end
    H.eq(roles.guard, "chosen")
    H.eq(roles.pike, "ally")
    H.eq(roles.rats, "snubbed")
    StoryEngine.Fate.apply("doc", "gone", "starve")
    H.eq(last("doc").k, "fate")
    H.eq(last("doc").kind, "gone")
end

function T.payload_for_the_people_tab()
    setup()
    StoryEngine.Social.story("casey")
    StoryEngine.Social.moveTo("casey", "casey_5b", StoryEngine.Sensor.now())
    local out = StoryEngine.Chronicle.payload()
    local casey
    for _, n in ipairs(out) do if n.id == "casey" then casey = n end end
    H.ok(casey and casey.freq, "every contact with their frequency")
    H.eq(casey.profile.family, "dead")
    H.eq(casey.chronicle[1].node, "casey_5b", "newest first")
    H.ok(string.find(kinds("casey"), "beat", 1, true))
end

return T
