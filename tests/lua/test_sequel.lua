-- 두 번째 이야기 (2026-10-07): 첫 결말 뒤 이어지는 이야기, 소탕·아는 얼굴·위기 노드, 이야기끼리 얽힘, 결말의 죽음·떠남
local T = {}

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    return p, ps
end

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

local function now() return StoryEngine.Sensor.now() end

-- fid 를 그 노드로 옮기고 머문 날을 충분히 지난 것으로
local function at(fid, node)
    local Social = StoryEngine.Social
    Social.moveTo(fid, node, now())
    Social.story(fid).since = now().t - 30 * 24 * 60
    return Social.story(fid)
end

local function openStoryQuest(fid, node)
    for _, q in pairs(StoryEngine.Store.data().quests) do
        local s = q.origin and q.origin.story
        if s and s.faction == fid and s.node == node then return q end
    end
    return nil
end

function T.sequel_starts_days_after_the_first_ending()
    setup()
    local Social = StoryEngine.Social
    local st = at("ray", "ray_6a")
    local wait = st.sequelAt - now().t
    H.ok(wait >= 7 * 24 * 60 and wait <= 14 * 24 * 60, "7 to 14 days later")
    st.wins, st.losses = 2, 1
    Social.advance("ray", now())
    H.eq(st.node, "ray_6a", "not yet")
    H.advanceDays(15)
    Social.advance("ray", now())
    H.eq(st.node, "ray2a_1", "the good ending leads to the road to Louisville")
    H.eq(st.arcs[1].ending, "ray_6a")
    H.eq(st.arcs[1].tone, "good")
    H.eq(st.wins, nil, "the second story keeps its own score")
    local list = StoryEngine.Chronicle.list("ray")
    local found = false
    for _, e in ipairs(list) do if e.k == "arc" and e.arc == "ray2a" then found = true end end
    H.ok(found, "a new chapter is written down")
    -- 나쁜 결말 뒤는 다른 이야기
    local cst = at("casey", "casey_5b")
    cst.sequelAt = now().t
    Social.advance("casey", now())
    H.eq(cst.node, "casey2b_1")
end

function T.story_quests_can_be_a_horde_or_a_known_face()
    mockBuildings()
    local p = setup()
    local Social = StoryEngine.Social
    at("ray", "ray2a_2")
    Social.advance("ray", now())
    local q = openStoryQuest("ray", "ray2a_2")
    H.ok(q, "the story asks for something")
    H.eq(q.kind, "horde", "a horde to clear")
    H.eq(q.origin.source, "story")
    q.state = "completed"
    Social.onQuest(q, "completed")
    H.eq(Social.story("ray").node, "ray2a_3", "won")
    -- 아는 얼굴: 레이의 딸
    at("ray", "ray2a_6")
    Social.advance("ray", now())
    local nq = openStoryQuest("ray", "ray2a_6")
    H.ok(nq, "asks to give Annie peace")
    H.eq(nq.kind, "named")
    H.eq(nq.person, "annie")
    -- 이야기 전용 사람은 무작위로 나오지 않는다
    for _, person in ipairs(StoryEngine.Named.candidates()) do
        H.ok(not person.storyOnly, "story-only people stay out of the random pool")
    end
    Social.onQuest(nq, "failed")
    H.eq(Social.story("ray").node, "ray2a_7x")
end

function T.stories_cross_when_another_contact_is_somewhere()
    setup()
    local Social = StoryEngine.Social
    at("dewey", "dewey_5a")                -- 방주가 달린다
    local st = at("ray", "ray2a_4")
    Social.onQuest({ kind = "deliver", origin = { faction = "ray", story = { faction = "ray", node = "ray2a_4" } } }, "completed")
    H.eq(st.node, "ray2a_5d", "Dewey drives the Ark to Louisville")
    at("dewey", "dewey2b_3x")              -- 방주를 팔았다
    st = at("ray", "ray2a_4")
    Social.onQuest({ kind = "deliver", origin = { faction = "ray", story = { faction = "ray", node = "ray2a_4" } } }, "completed")
    H.eq(st.node, "ray2a_5a", "Ray walks Annie home himself")
end

function T.crisis_nodes_wait_for_the_choice()
    local p = setup()
    local Social = StoryEngine.Social
    local st = at("ray", "ray2b_4")
    Social.advance("ray", now())
    H.eq(st.crisisAsked, "lily")
    local q
    for _, x in pairs(StoryEngine.Store.data().quests) do
        if x.kind == "choice" and x.crisis == "lily" then q = x end
    end
    H.ok(q, "the crisis is in the quest log")
    Social.advance("ray", now())
    H.eq(st.node, "ray2b_4", "waits for the players")
    local idx
    for i, o in ipairs(q.options) do if o.faction == "hunter" then idx = i end end
    H.ok(StoryEngine.Quests.choose(p, q.id, idx))
    H.ok(st.flags.lily_chose_hunter, "who was chosen is remembered")
    Social.advance("ray", now())
    H.eq(st.node, "ray2b_5h", "Hank was right")
    H.eq(Social.story("hunter").flags.lily_helped, true)
end

function T.second_story_endings_can_be_death_or_leaving()
    setup()
    local Social = StoryEngine.Social
    at("guard", "guard2a_5")
    Social.onQuest({ kind = "horde", origin = { faction = "guard", story = { faction = "guard", node = "guard2a_5" } } }, "failed")
    H.eq(Social.story("guard").node, "guard2a_6x")
    H.ok(H.logHas("fate scheduled guard gone guard2a_6x"))
    H.advanceDays(1)
    H.fire("EveryTenMinutes")
    H.eq(StoryEngine.Life.npc("guard").fate.kind, "gone")
    -- 첫 이야기의 "두 번 지면" 결말은 두 번째 이야기에 쓰지 않는다
    local st = at("doc", "doc2a_4")
    st.wins, st.losses = 0, 3
    Social.onQuest({ kind = "deliver", origin = { faction = "doc", story = { faction = "doc", node = "doc2a_4" } } }, "failed")
    H.eq(st.node, "doc2a_5x")
    H.ok(not StoryEngine.Store.data().fatePending or not StoryEngine.Store.data().fatePending.doc, "doc lives on")
end

function T.people_tab_gets_the_main_story()
    setup()
    local Social = StoryEngine.Social
    at("pike", "pike_5a")
    local info = Social.storyInfo("pike", now())
    H.eq(info.arc, "pike1")
    H.eq(info.chapter, 1)
    H.ok(info.final and info.tone == "good")
    H.ok(info.nextDays and info.nextDays >= 7, "days until the next story")
    Social.story("pike").sequelAt = now().t
    Social.advance("pike", now())
    local pike
    for _, n in ipairs(StoryEngine.Chronicle.payload()) do if n.id == "pike" then pike = n end end
    H.eq(pike.story.arc, "pike2a")
    H.eq(pike.story.chapter, 2)
    H.eq(pike.story.past[1].arc, "pike1")
    H.eq(StoryEngine.Stories.arcOf("ray", "ray_end_bad"), "ray1")
    H.eq(StoryEngine.Stories.arcOf("hunter", "hunter2b_5x"), "hunter2b")
end

-- 모든 두 번째 이야기 노드가 이어져 있는가 (다음 노드가 실제로 있고, 결말까지 닿는다)
function T.every_sequel_node_leads_somewhere()
    local Stories = StoryEngine.Stories
    local function ids(spec)
        if type(spec) ~= "table" then return { spec } end
        local out = { spec.default }
        for _, w in ipairs(spec.when or {}) do out[#out + 1] = w.go end
        for _, pair in ipairs(spec.list or {}) do out[#out + 1] = pair[2] end
        for _, id in pairs(spec.flags or {}) do out[#out + 1] = id end
        return out
    end
    for fid, list in pairs(Stories.SEQUELS) do
        for _, n in ipairs(list) do
            if not n.final then
                local nexts = {}
                for _, key in ipairs({ "next", "win", "lose" }) do
                    if n[key] then for _, id in ipairs(ids(n[key])) do nexts[#nexts + 1] = id end end
                end
                H.ok(#nexts > 0, n.id .. " goes nowhere")
                for _, id in ipairs(nexts) do H.ok(Stories.node(fid, id), n.id .. " -> missing " .. tostring(id)) end
                if n.crisis then H.ok(Stories.crisis(n.crisis), "crisis " .. n.crisis) end
                if n.quest and n.quest.kind == "named" then H.ok(StoryEngine.Named.byId[n.quest.person], n.quest.person) end
            else
                H.ok(n.tone, n.id .. " needs a tone")
            end
        end
    end
    for id, e in pairs(Stories.ENDINGS) do
        local fid = string.match(id, "^(%a+)_")
        H.ok(Stories.node(fid, id) and Stories.node(fid, e.sequel), id)
    end
end

return T
