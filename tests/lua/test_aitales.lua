-- AI 곁가지 (AiTales.lua, docs/STORY_YEAR_PLAN.md D): 정해 둔 곁가지가 없을 때만, 브릿지가 있을 때만,
-- 게임이 정한 종류·물건으로 AI 가 쓴 글을 노드로 저장하고 큰 이야기처럼 굴린다
local T = {}

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    StoryEngine.Store.player(p).lang = "KO"
    StoryEngine.Bridge.state = "connected"
    StoryEngine.AiTales.pending = nil
    return p
end

local function now() return StoryEngine.Sensor.now() end

-- 큰 이야기를 마친 레이 (다음 장 없음), 정해 둔 곁가지는 모두 씀
local function rayDone()
    local Social, Stories = StoryEngine.Social, StoryEngine.Stories
    Social.moveTo("ray", "ray5_6a", now())
    local st = Social.story("ray")
    st.since = now().t - 60 * 24 * 60
    st.epUsed = {}
    for _, def in ipairs(Stories.EPISODES) do
        if def.npc == "ray" then st.epUsed[def.id] = true end
    end
    return st
end

local function scene(tag)
    return { beat = "You " .. tag .. ".", say = tag .. " (said)", tale = "Ray " .. tag .. "." }
end

local function answer(kind)
    if kind == "quiet" then
        return { title = "The Fence", start = scene("mends the fence"), ["end"] = scene("finished the fence"), tone = "good" }
    end
    return { title = "Dry Well", start = scene("needs water"), why = "the well ran dry",
             win = scene("got water"), lose = scene("went thirsty") }
end

function T.only_when_written_ones_are_used_up()
    setup()
    local Social = StoryEngine.Social
    Social.moveTo("ray", "ray5_6a", now())
    Social.story("ray").since = now().t - 60 * 24 * 60
    local id = Social.pickEpisode(now())
    H.ok(id and string.find(id, "^rayep"), "a written side story first, got " .. tostring(id))
    H.eq(H.lastBridge("episode"), nil)
end

function T.asks_the_bridge_and_runs_the_story()
    setup()
    local Social, Stories, AiTales = StoryEngine.Social, StoryEngine.Stories, StoryEngine.AiTales
    local st = rayDone()
    local id = Social.pickEpisode(now())
    H.eq(id, "ai:rayai1")
    local b = H.lastBridge("episode")
    H.ok(b, "asked the bridge")
    H.eq(b.payload.faction, "ray")
    H.eq(b.payload.lang, "KO")
    H.ok(b.payload.kind == "quiet" or b.payload.kind == "items" or b.payload.kind == "horde")
    H.ok(AiTales.pending, "waits for the answer")
    H.eq(Social.pickEpisode(now()), nil, "one a day")
    -- 물건 부탁으로 다시 (결과를 정해 두려고)
    AiTales.pending = nil
    local ok, arc = AiTales.request("ray", now(), "items")
    H.ok(ok)
    H.eq(arc, "rayai2")
    b = H.lastBridge("episode")
    H.eq(b.payload.kind, "items")
    H.ok(#b.payload.items > 0, "the game picked the items")
    b.callback({ ok = true, json = answer("items") })
    H.eq(AiTales.pending, nil)
    H.eq(st.node, "rayai2_1")
    local n = Stories.node("ray", "rayai2_1")
    H.ok(n and n.quest, "asking scene")
    H.eq(n.quest.why, "the well ran dry")
    H.eq(Stories.arcOf("ray", n.id), "rayai2")
    -- 먼저 거는 말이 없을 때는 AI 가 쓴 말을 그대로
    local fb = Social.contactFallback({ fid = "ray", reason = "story", line = "rayai2_1", topic = "x" })
    H.eq(fb.text, "needs water (said)")
    H.eq(fb.lt, nil)
    -- 부탁 -> 해냄 -> 결말 -> 큰 이야기로
    Social.forceAsk = true
    st.since = now().t - 5 * 24 * 60
    Social.advance("ray", now())
    Social.forceAsk = nil
    H.ok(st.questId, "the request became a quest")
    local q = StoryEngine.Store.data().quests[st.questId]
    H.eq(q.why, "the well ran dry")
    Social.onQuest({ kind = "deliver", origin = { faction = "ray", story = { faction = "ray", node = "rayai2_1" } } }, "completed")
    H.eq(st.node, "rayai2_2")
    local info = Social.storyInfo("ray", now())
    H.eq(info.chapter, "ep")
    local seen = false
    for _, e in ipairs(info.path) do
        if e.node == "rayai2_2" then
            seen = true
            H.eq(e.tale, "Ray got water.")
            H.eq(e.title, "Dry Well")
        end
    end
    H.ok(seen, "the People tab gets the written text")
    st.told = true
    Social.advance("ray", now())
    H.eq(st.node, "ray5_6a", "back to where the big story ended")
    H.eq(st.arcs[#st.arcs].arc, "rayai2")
end

function T.bad_answers_are_dropped()
    setup()
    local AiTales = StoryEngine.AiTales
    local st = rayDone()
    AiTales.request("ray", now(), "quiet")
    local b = H.lastBridge("episode")
    b.callback({ ok = true, json = { title = "Half", start = scene("starts") } })
    H.eq(st.node, "ray5_6a", "no end scene, nothing started")
    H.eq(AiTales.pending, nil)
    AiTales.request("ray", now(), "quiet")
    H.lastBridge("episode").callback({ ok = false, error = "timeout" })
    H.eq(st.node, "ray5_6a")
    -- 기다리는 동안 이야기가 움직였으면 버린다
    AiTales.request("ray", now(), "quiet")
    b = H.lastBridge("episode")
    st.ep = { id = "rayep1", node = "ray5_6a" }
    b.callback({ ok = true, json = answer("quiet") })
    H.ok(st.node ~= "rayai3_1", "dropped")
    st.ep = nil
end

function T.no_bridge_no_ai_story()
    setup()
    local Social = StoryEngine.Social
    rayDone()
    StoryEngine.Bridge.state = "disconnected"
    H.eq(Social.pickEpisode(now()), nil)
    H.eq(H.lastBridge("episode"), nil)
end

function T.old_tales_leave_their_text_in_the_path()
    setup()
    local Social, AiTales = StoryEngine.Social, StoryEngine.AiTales
    local st = rayDone()
    local keep = AiTales.KEEP
    AiTales.KEEP = 1
    AiTales.request("ray", now(), "quiet")
    H.lastBridge("episode").callback({ ok = true, json = answer("quiet") })
    H.eq(st.node, "rayai1_1")
    Social.endEpisode("ray", now())
    AiTales.request("ray", now(), "quiet")
    H.lastBridge("episode").callback({ ok = true, json = answer("quiet") })
    H.eq(st.node, "rayai2_1")
    H.eq(st.ai.tales.rayai1, nil, "the oldest one was pruned")
    local kept = false
    for _, e in ipairs(st.path) do
        if e.node == "rayai1_1" then kept = e.tale == "Ray mends the fence." and e.title == "The Fence" end
    end
    H.ok(kept, "its text stays in the path")
    AiTales.KEEP = keep
end

return T
