-- 1년 이야기 1회차 (2026-10-07, docs/STORY_YEAR_PLAN.md): 3장 연결, 이야기 속도, 부탁 몰림 방지, 같은 장 안의 갈래,
-- 열 수 없는 위기, 후임 목소리, 곁가지 이야기
local T = {}

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    StoryEngine.Store.player(p).lang = "EN"
    return p
end

local function now() return StoryEngine.Sensor.now() end

local function at(fid, node)
    local Social = StoryEngine.Social
    Social.moveTo(fid, node, now())
    Social.story(fid).since = now().t - 60 * 24 * 60
    return Social.story(fid)
end

local function result(fid, node, outcome)
    StoryEngine.Social.onQuest({ kind = "deliver", origin = { faction = fid, story = { faction = fid, node = node } } }, outcome)
end

function T.chapter_two_endings_lead_into_chapter_three()
    setup()
    local Social = StoryEngine.Social
    local st = at("ray", "ray2b_5h")
    local wait = st.sequelAt - now().t
    H.ok(wait >= 14 * 24 * 60 and wait <= 21 * 24 * 60, "14 to 21 days before chapter three")
    st.sequelAt = now().t
    Social.advance("ray", now())
    H.eq(st.node, "ray3_1b", "Lily is in the opening")
    H.eq(Social.storyInfo("ray", now()).chapter, 3)
    -- 장 안에서 모인다
    Social.advance("ray", now())
    H.eq(st.node, "ray3_1b", "waits its days")
    st.since = now().t - 3 * 24 * 60
    Social.advance("ray", now())
    H.eq(st.node, "ray3_2", "joins the common line")
    -- 죽음·떠남 결말은 다음 장이 없다
    H.eq(StoryEngine.Stories.node("guard", "guard2a_6x").sequel, nil)
end

function T.story_pace_scales_days()
    setup()
    local Social = StoryEngine.Social
    SandboxVars.StoryEngine = SandboxVars.StoryEngine or {}
    SandboxVars.StoryEngine.StoryPace = 3
    H.eq(Social.pace(), 0.6)
    local st = at("casey", "casey2a_5a")
    H.ok(st.sequelAt - now().t <= math.floor(21 * 0.6 * 24 * 60), "fast pace shortens the wait")
    SandboxVars.StoryEngine.StoryPace = 2
end

function T.story_asks_are_spread_out()
    setup()
    local Social = StoryEngine.Social
    H.ok(Social.storyAskAllowed(now()))
    local d = StoryEngine.Store.data()
    d.quests.s1 = { id = "s1", kind = "deliver", state = "proposed", origin = { story = { faction = "ray", node = "ray3_5" } } }
    d.quests.s2 = { id = "s2", kind = "choice", state = "proposed", origin = {} }
    H.ok(not Social.storyAskAllowed(now()), "two open already")
    d.quests.s2.state = "completed"
    H.ok(Social.storyAskAllowed(now()))
    d.social.lastStoryAskT = now().t
    H.ok(not Social.storyAskAllowed(now()), "half a day between asks")
    H.advance(13 * 60)
    H.ok(Social.storyAskAllowed(now()))
end

function T.flags_split_a_chapter()
    setup()
    local Social = StoryEngine.Social
    at("doc", "doc3_3")
    result("doc", "doc3_3", "completed")
    H.eq(Social.story("doc").node, "doc3_4")
    H.ok(Social.story("doc").flags.doc3_herbs)
    at("doc", "doc3_5")
    result("doc", "doc3_5", "completed")
    H.eq(Social.story("doc").node, "doc3_6a", "the herb garden ending")
    local st = at("pike", "pike3_5")
    st.flags.pike3_feast = nil
    result("pike", "pike3_5", "completed")
    H.eq(st.node, "pike3_6b", "no feast: the simple wedding")
end

function T.a_crisis_that_cannot_open_takes_the_default()
    setup()
    local Social = StoryEngine.Social
    StoryEngine.Fate.apply("guard", "gone", "debug")
    local st = at("hunter", "hunter3_4")
    Social.forceAsk = true
    Social.advance("hunter", now())
    Social.forceAsk = nil
    H.ok(st.flags.thief_skipped, "skipped, not ignored")
    Social.advance("hunter", now())
    H.eq(st.node, "hunter3_6n", "the neutral ending")
end

function T.a_successor_takes_over_the_frequency()
    setup()
    local Social, Voices = StoryEngine.Social, StoryEngine.Voices
    StoryEngine.Radio.channel("ray").trust = 60
    at("ray", "ray3_2")
    StoryEngine.Fate.apply("ray", "dead", "debug")
    H.ok(StoryEngine.Factions.isGone("ray"))
    H.ok(StoryEngine.Store.data().voices.pending.ray, "someone will take over")
    H.advanceDays(11)
    H.fire("EveryTenMinutes")
    H.ok(not StoryEngine.Factions.isGone("ray"), "the channel is alive again")
    H.eq(Voices.of("ray"), "martha")
    H.eq(StoryEngine.Factions.voice.ray, "martha")
    H.eq(StoryEngine.Stories.NAMES.ray, "Martha Cole")
    H.eq(StoryEngine.Radio.channel("ray").trust, 30, "half the trust")
    H.eq(Social.story("ray").node, "martha1_1")
    local prev = StoryEngine.Life.npc("ray").prevVoices[1]
    H.eq(prev.fate, "dead")
    H.eq(prev.story.arc, "ray3", "Ray's story is kept")
    H.ok(#H.sentOf("npcVoices") > 0, "clients learn the new name")
    -- 브릿지는 페르소나를 바꾼다
    StoryEngine.Radio.say(H.players[1], "ray", "hello?")
    local b = H.lastBridge("radio")
    H.eq(b.payload.voices.ray, "martha")
    -- 인물 탭
    local entry
    for _, n in ipairs(StoryEngine.Chronicle.payload()) do if n.id == "ray" then entry = n end end
    H.eq(entry.voice, "martha")
    H.eq(entry.prevVoices[1].fate, "dead")
    -- 후임까지 떠나면 끝
    StoryEngine.Fate.apply("ray", "gone", "debug")
    H.eq(StoryEngine.Store.data().voices.pending.ray, nil, "only once")
end

function T.vic_is_followed_by_dutch_or_red()
    setup()
    local Voices = StoryEngine.Voices
    at("rats", "rats2a_5x")
    H.eq(Voices.pick("rats"), "dutch")
    at("rats", "rats2b_5g")
    H.eq(Voices.pick("rats"), "red", "Dutch died in that ending")
    StoryEngine.Radio.channel("rats").trust = 40
    StoryEngine.Fate.apply("rats", "dead", "debug")
    Voices.take("rats")
    H.eq(StoryEngine.Radio.channel("rats").trust, 12, "Red keeps a little")
end

function T.side_stories_fill_the_wait()
    setup()
    local Social, Stories = StoryEngine.Social, StoryEngine.Stories
    -- 시험용 곁가지
    local ep = { id = "raytest1", npc = "ray", when = { trust = 10 }, nodes = {
        { id = "raytest1_1", days = 1, next = "raytest1_2", beat = "A dog follows you home." },
        { id = "raytest1_2", final = true, tone = "good", beat = "The dog stays." } } }
    Stories.EPISODES[#Stories.EPISODES + 1] = ep
    for _, n in ipairs(ep.nodes) do
        n.chapter, n.episode = "ep", ep.id
        Stories.ARCS.ray[#Stories.ARCS.ray + 1] = n
    end
    StoryEngine.Radio.channel("ray").trust = 30
    local st = at("ray", "ray3_6a")
    H.eq(st.sequel, nil)
    H.eq(Social.pickEpisode(now()), "raytest1", "nothing comes after chapter three yet, so a side story fits")
    H.eq(st.node, "raytest1_1")
    H.eq(Social.pickEpisode(now()), nil, "one a day")
    local info = Social.storyInfo("ray", now())
    H.eq(info.chapter, "ep")
    H.ok(info.episode)
    st.since = now().t - 2 * 24 * 60
    Social.advance("ray", now())
    H.eq(st.node, "raytest1_2")
    st.told = true
    Social.advance("ray", now())
    H.eq(st.node, "ray3_6a", "back to the main story")
    H.eq(st.arcs[#st.arcs].arc, "raytest1")
    H.ok(st.epUsed.raytest1, "not again")
    -- 지나온 장면에 곁가지가 장 표시와 함께 남는다
    local seen = false
    for _, e in ipairs(Social.storyInfo("ray", now()).path) do
        if e.node == "raytest1_1" and e.chapter == "ep" then seen = true end
    end
    H.ok(seen)
    Stories.EPISODES[#Stories.EPISODES] = nil
end

-- 3장·후임 노드가 모두 이어져 있는가
function T.every_new_node_leads_somewhere()
    local Stories = StoryEngine.Stories
    local function ids(spec)
        if type(spec) ~= "table" then return { spec } end
        local out = { spec.default }
        for _, w in ipairs(spec.when or {}) do out[#out + 1] = w.go end
        for _, pair in ipairs(spec.list or {}) do out[#out + 1] = pair[2] end
        return out
    end
    for fid, list in pairs(Stories.CHAPTER3) do
        for _, n in ipairs(list) do
            if n.final then
                H.ok(n.tone, n.id .. " needs a tone")
            else
                local nexts = {}
                for _, key in ipairs({ "next", "win", "lose" }) do
                    if n[key] then for _, id in ipairs(ids(n[key])) do nexts[#nexts + 1] = id end end
                end
                H.ok(#nexts > 0, n.id .. " goes nowhere")
                for _, id in ipairs(nexts) do H.ok(Stories.node(fid, id), n.id .. " -> " .. tostring(id)) end
                if n.crisis then H.ok(Stories.crisis(n.crisis), n.crisis) end
            end
        end
    end
    for id, e in pairs(Stories.ENDINGS) do
        local fid = string.match(id, "^(%a+)")
        H.ok(Stories.node(fid, id), "ending " .. id)
        if e.sequel then H.ok(Stories.node(fid, e.sequel), id .. " -> " .. e.sequel) end
    end
    for vid, def in pairs(Stories.VOICES) do
        H.ok(Stories.node(def.npc, def.start), vid .. " start")
    end
end

return T
