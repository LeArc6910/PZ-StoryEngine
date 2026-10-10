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

-- 뒤 장으로 갈수록 이야기 부탁 등급이 오른다 (2026-10-10 사용자 요청, 샌드박스 StoryRamp)
function T.later_chapters_ask_for_more()
    local p = setup()
    local Social, Stories = StoryEngine.Social, StoryEngine.Stories
    H.eq(Social.rampTier(2, 0, 5), 2)
    H.eq(Social.rampTier(3, 2, 4), 4, "capped")
    H.eq(Social.rampTier(4, 1, 3), 4, "a cap never lowers what the story wrote")
    -- 장마다: 물건 부탁 장면 하나씩 골라 본다
    local function questNode(fid, chapter)
        for _, n in ipairs(Stories.ARCS[fid]) do
            if n.chapter == chapter and n.quest and n.quest.items and not n.quest.kind then return n end
        end
    end
    local want = { [2] = 0, [3] = 1, [4] = 2, [5] = 2 }
    for chapter, add in pairs(want) do
        local node = questNode("ray", chapter)
        H.ok(node, "ray has an item request in chapter " .. chapter)
        local cap = chapter == 4 and 4 or 5
        H.eq(Social.storyTier("ray", node), math.max(node.quest.tier, math.min(cap, node.quest.tier + add)),
            "chapter " .. chapter)
    end
    local first = nil
    for _, n in ipairs(Stories.ARCS.ray) do
        if not n.chapter and n.quest and not first then first = n end
    end
    H.eq(Social.storyTier("ray", first), first.quest.tier, "the first story is as written")
    -- 실제 부탁에 반영된다
    local node = questNode("ray", 5)
    local st = at("ray", node.id)
    Social.forceAsk = true
    Social.advance("ray", now())
    Social.forceAsk = nil
    local q = StoryEngine.Store.data().quests[st.questId]
    H.ok(q, "the request went out")
    H.eq(q.tier, math.min(5, node.quest.tier + 2), "chapter five asks two tiers more")
    H.ok(H.logHas("story tier ray " .. node.id))
    -- 곁가지: 그 NPC 의 큰 이야기가 몇 장인지에 따라, 최고 4등급
    local ep = { chapter = "ep", quest = { tier = 1 } }
    H.eq(Social.mainChapter("ray"), 5)
    H.eq(Social.storyTier("ray", ep), 3, "chapter five: side stories +2")
    H.eq(Social.storyTier("ray", { chapter = "ep", quest = { tier = 3 } }), 4, "side stories stop at tier 4")
    H.eq(Social.storyTier("ray", { chapter = "ep", ai = true, quest = { tier = 1 } }), 1, "AI side stories keep their own tier")
    H.eq(Social.mainChapter("casey"), 1)
    H.eq(Social.storyTier("casey", ep), 1, "first story: side stories as written")
    -- 끄면 그대로
    SandboxVars.StoryEngine.StoryRamp = false
    H.eq(Social.storyTier("ray", node), node.quest.tier)
    SandboxVars.StoryEngine.StoryRamp = nil
end

-- 뒤 장의 이야기가 여는 위기도 선택지 등급이 오른다
function T.later_crises_ask_for_more()
    local p = setup()
    local ps = StoryEngine.Store.player(p)
    local Quests, Stories = StoryEngine.Quests, StoryEngine.Stories
    local crisis = Stories.crisis("knox")
    H.ok(crisis, "the Knox crisis")
    local plain = Quests.proposeChoice(p, ps, crisis, now())
    local raised = Quests.proposeChoice(p, ps, crisis, now(), 2, 4)
    for i, o in ipairs(plain.options) do
        H.eq(raised.options[i].tier, math.max(o.tier, math.min(4, o.tier + 2)), "option " .. i)
    end
    H.ok(raised.tier >= plain.tier)
    local add, cap = StoryEngine.Social.tierAdd("guard", Stories.node("guard", "guard4_3"))
    H.eq(add, 2)
    H.eq(cap, 4, "chapter four stops at tier 4")
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
    local saved = Stories.EPISODES
    Stories.EPISODES = { ep }
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
    Stories.EPISODES = saved
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
    local groups = {}
    for fid, list in pairs(Stories.CHAPTER3) do groups[#groups + 1] = { fid, list } end
    for fid, list in pairs(Stories.CHAPTER4) do groups[#groups + 1] = { fid, list } end
    for fid, list in pairs(Stories.CHAPTER5) do groups[#groups + 1] = { fid, list } end
    for k, list in pairs(Stories.VOICE_CHAPTERS) do groups[#groups + 1] = { k == "rats_dutch" and "rats" or k, list } end
    for _, g in ipairs(groups) do
        local fid, list = g[1], g[2]
        for _, n in ipairs(list) do
            if n.final then
                H.ok(n.tone, n.id .. " needs a tone")
            elseif (n.days or 0) >= 3650 then
                -- 카운티 회의 대기 장면 (Council.lua 가 움직인다)
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
        for _, seq in ipairs(e.sequel and ids(e.sequel) or {}) do H.ok(Stories.node(fid, seq), id .. " -> " .. seq) end
    end
    for vid, def in pairs(Stories.VOICES) do
        local first = Stories.node(def.npc, def.start)
        H.ok(first, vid .. " start")
        H.ok(first.next and Stories.node(def.npc, first.next), vid .. " leads into the taking-over chapter")
    end
end

-- 2회차: 4장 첫 장면은 함께 사는 사람으로, hitAll·hurt, 휘태커가 떠나면 코왈스키, 후임 대사
function T.chapter_four_opens_by_who_lives_with_ray()
    setup()
    local Social = StoryEngine.Social
    local st = at("ray", "ray3_1a")
    H.ok(st.flags.ray_annie)
    st = at("ray", "ray3_6a")
    st.sequelAt = now().t
    Social.advance("ray", now())
    H.eq(st.node, "ray4_1a", "Annie is there for the winter")
    local cst = at("casey", "casey3_6b")
    cst.sequelAt = now().t
    Social.advance("casey", now())
    H.eq(cst.node, "casey4_1b")
end

function T.story_events_can_hit_everyone_and_hurt_a_contact()
    setup()
    local Life = StoryEngine.Life
    Life.daily()
    local before = Life.get("ray", "morale")
    at("casey", "casey4_4x")
    H.eq(Life.get("ray", "morale"), before - 5, "the county felt the silence")
    at("dewey", "dewey4_4x")
    H.eq(StoryEngine.Specialty.status("dewey").reason, "hurt", "pinned under the truck")
    H.advanceDays(8)
    H.ok(StoryEngine.Specialty.status("dewey").reason ~= "hurt", "healed after a week")
end

function T.whitaker_leaves_for_knox_and_kowalski_takes_over()
    setup()
    local Social = StoryEngine.Social
    local st = at("guard", "guard4_3")
    st.crisisAsked = "knox"
    st.flags.knox_done = true
    Social.advance("guard", now())
    H.eq(st.node, "guard4_4l")
    H.advanceDays(1)
    H.fire("EveryTenMinutes")
    H.eq(StoryEngine.Life.npc("guard").fate.kind, "gone")
    H.advanceDays(11)
    H.fire("EveryTenMinutes")
    H.eq(StoryEngine.Voices.of("guard"), "kowalski")
    local kst = Social.story("guard")
    H.eq(kst.node, "kowalski1_1")
    kst.since = now().t - 3 * 24 * 60
    Social.advance("guard", now())
    H.eq(kst.node, "kowalski1_2", "the taking-over chapter goes on")
    -- AI 없을 때 후임 대사
    local lt = StoryEngine.Lines.lt("guard", "q_thanks")
    H.ok(string.find(lt.key, "IGUI_StoryEngine_Line_kowalski_q_thanks_", 1, true), "his own line")
    local other = StoryEngine.Lines.lt("guard", "horde")
    H.ok(string.find(other.key, "IGUI_StoryEngine_Line_kowalski_horde_", 1, true), "his own lines for the rest too")
    local named = StoryEngine.Lines.lt("guard", "named_ask")
    H.ok(string.find(named.key, "IGUI_StoryEngine_Line_guard_named_ask_", 1, true), "known faces never come up for him")
end

-- 3회차: 5장 연결, 레이 농장 위기(선택지 넷), 카운티 회의
local function mockAnyBuilding()
    ArrayList = { new = function() return H.list({}) end }
    local grid = {}
    function grid:getBuildingsIntersecting(x, y, w, h, list)
        local cx, cy = math.floor(x + w / 2), math.floor(y + h / 2)
        local room = {}
        function room:getZ() return 0 end
        function room:getArea() return 100 end
        function room:getX() return cx end
        function room:getY() return cy end
        function room:getX2() return cx + 9 end
        function room:getY2() return cy + 9 end
        function room:getName() return "church" end
        local def = {}
        function def:getX() return cx end
        function def:getY() return cy end
        function def:getX2() return cx + 9 end
        function def:getY2() return cy + 9 end
        function def:getRooms() return H.list({ room }) end
        function def:isResidential() return false end
        list.items[#list.items + 1] = def
    end
    function grid:getBuildingAt() return nil end
    local world = {}
    function world:getMetaGrid() return grid end
    getWorld = function() return world end
end

function T.chapter_five_follows_chapter_four()
    setup()
    local Social = StoryEngine.Social
    local st = at("ray", "ray4_6a")
    st.sequelAt = now().t
    Social.advance("ray", now())
    H.eq(st.node, "ray5_1a")
    local cst = at("casey", "casey4_6b")
    cst.sequelAt = now().t
    Social.advance("casey", now())
    H.eq(cst.node, "casey5_1", "Casey waits for the council")
    -- 레이의 농장: 파이크를 고르면 레이도 함께 도운 것
    local p = H.players[1]
    st = at("ray", "ray5_3")
    Social.forceAsk = true
    Social.advance("ray", now())
    Social.forceAsk = nil
    local q
    for _, x in pairs(StoryEngine.Store.data().quests) do if x.crisis == "commons" then q = x end end
    H.eq(#q.options, 4, "four ways for the farm")
    local idx
    for i, o in ipairs(q.options) do if o.faction == "pike" then idx = i end end
    H.ok(StoryEngine.Quests.choose(p, q.id, idx))
    st.flags.commons_done = true
    Social.advance("ray", now())
    H.eq(st.node, "ray5_4p")
    H.ok(st.flags.ray5_commons)
end

function T.the_county_council_brings_the_year_together()
    setup()
    mockAnyBuilding()
    local Social, Council = StoryEngine.Social, StoryEngine.Council
    at("casey", "casey5_1")
    at("pike", "pike4_5")
    for _, n in ipairs({ { "ray", "ray4_6a" }, { "doc", "doc4_6a" }, { "dewey", "dewey4_6a" }, { "guard", "guard4_6a" },
                         { "rats", "rats4_6a" }, { "hunter", "hunter4_6a" } }) do
        at(n[1], n[2])
    end
    for _, f in ipairs(StoryEngine.Factions.list) do StoryEngine.Radio.channel(f.id).trust = 60 end
    StoryEngine.Life.daily()
    local morale = StoryEngine.Life.get("ray", "morale")
    H.ok(Council.shouldStart(now()), "six contacts finished winter and Casey is ready")
    Council.tick(now())
    local s = Council.state()
    H.eq(s.stage, "collect")
    H.eq(Social.story("casey").node, "casey5_2")
    local cq = StoryEngine.Store.data().quests[s.collectId]
    H.ok(cq and cq.kind == "collect" and cq.origin.council, "a council collection in the quest log")
    for _, n in ipairs(cq.need) do cq.got[n[1]] = n[2] end
    cq.state = "completed"
    Council.tick(now())
    H.eq(s.stage, "horde")
    H.eq(s.prep, 1)
    H.eq(Social.story("casey").node, "casey5_3")
    local hq = StoryEngine.Store.data().quests[s.hordeId]
    H.ok(hq and hq.kind == "defend" and hq.siege, "the church has to be held")
    hq.state = "completed"
    Council.tick(now())
    H.eq(s.result, "formed")
    H.eq(Social.story("casey").node, "casey5_9a")
    H.eq(StoryEngine.Life.get("ray", "morale"), math.min(100, morale + 15), "everyone's spirits rise")
    H.ok(#H.sentOf("councilNotice") >= 3)
    -- 늦게 5장에 온 파이크는 결과로 바로
    at("pike", "pike5_1")
    Council.tick(now())
    H.eq(Social.story("pike").node, "pike5_9a")
end

-- 회의 날 교회 사수 (2026-10-10 사용자 결정): 망자가 천 단위로, 신뢰가 두터운 NPC 가 모두 돕는다
function T.the_council_siege_comes_in_packs_and_friends_thin_them()
    local p = setup()
    mockAnyBuilding()
    local Council, Radio = StoryEngine.Council, StoryEngine.Radio
    at("pike", "pike5_1")
    Council.start(now())
    local s = Council.state()
    StoryEngine.Store.data().quests[s.collectId].state = "completed"
    Council.tick(now())
    local hq = StoryEngine.Store.data().quests[s.hordeId]
    H.eq(hq.kind, "defend")
    H.eq(hq.tier, 5)
    H.eq(hq.needMin, 360, "six hours at the church")
    H.eq(hq.siege.total, 1000, "a thousand of the dead")
    H.eq(hq.siege.waves, 12)
    H.eq(hq.siege.wave, 84)
    -- 관계가 없으면 아무도 안 온다
    for _, f in ipairs(StoryEngine.Factions.list) do Radio.channel(f.id).trust = 10 end
    H.eq(#Council.helpers(), 0)
    H.eq(Council.thinning(), 0)
    -- 신뢰가 두터운 사람들이 길목에서 막는다 (80 이상이면 더)
    Radio.channel("guard").trust = 85
    Radio.channel("hunter").trust = 60
    Radio.channel("ray").trust = 70
    H.eq(#Council.helpers(), 3)
    H.near(Council.thinning(), 0.20 * 1.25 + 0.10, 0.0001)
    for _, f in ipairs(StoryEngine.Factions.list) do Radio.channel(f.id).trust = 90 end
    H.near(Council.thinning(), 0.6875, 0.0001, "everyone at their best")
    Radio.channel("rats").trust, Radio.channel("dewey").trust, Radio.channel("casey").trust = 10, 10, 10
    Radio.channel("hunter").trust = 60
    -- 아무도 없으면 무리가 오지 않는다
    p.x, p.y = hq.cx + 500, hq.cy
    Council.siegeTick({}, now())
    H.eq(hq.waves or 0, 0, "nobody at the church")
    -- 교회에 있으면: 처음에 다 오고, 30분마다 한 무리
    p.x, p.y = hq.cx, hq.cy
    local before = #p.items
    Council.siegeTick({}, now())
    H.eq(hq.waves, 1)
    local held = math.floor(84 * (0.25 + 0.10) + 0.5)
    H.eq(hq.siege.held, held, "Whitaker and Hank stopped some on the roads")
    H.eq(hq.siege.sent, 84 - held)
    H.ok(H.logHas("council siege opened"))
    H.ok(#p.items > before, "Ray's stew for everyone holding the church")
    local wave, heldNote = 0, 0
    for _, o in ipairs(H.sentOf("radioOverhead")) do
        if o.lt and o.lt.key == "IGUI_StoryEngine_Council_Siege_Wave" then wave = wave + 1 end
        if o.lt and o.lt.key == "IGUI_StoryEngine_Council_Siege_Held" then heldNote = heldNote + 1 end
    end
    H.eq(wave, 1)
    H.eq(heldNote, 1)
    Council.siegeTick({}, now())
    H.eq(hq.waves, 1, "not before half an hour")
    for _ = 1, 20 do
        H.advance(30)
        Council.siegeTick({}, now())
    end
    H.eq(hq.waves, 12, "twelve packs and no more")
    H.eq(hq.siege.sent + hq.siege.held, 12 * 84)
    -- 목록에 실려 간다
    local item
    for _, it in ipairs(StoryEngine.Quests.listFor(StoryEngine.Store.player(p).key, now())) do
        if it.id == hq.id then item = it end
    end
    H.ok(item and item.siege and item.siege.total == 1000, "the quest tab shows the siege")
    H.eq(#item.siegeHelpers, 5, "Ray, June, Pike, Whitaker and Hank are coming")
    -- 샌드박스
    SandboxVars.StoryEngine.CouncilSiege = 2000
    SandboxVars.StoryEngine.ZombieMult = 1.5
    H.eq(Council.siegeTotal(), 3000)
    SandboxVars.StoryEngine.CouncilSiege, SandboxVars.StoryEngine.ZombieMult = nil, nil
end

function T.a_council_without_help_falls_apart()
    setup()
    mockAnyBuilding()
    local Social, Council = StoryEngine.Social, StoryEngine.Council
    at("pike", "pike5_1")
    Council.start(now())
    local s = Council.state()
    H.advanceDays(5)
    Council.tick(now())
    H.eq(s.stage, "horde", "the collection ran out of time")
    H.eq(s.prep, 0)
    H.advanceDays(4)
    StoryEngine.Store.data().quests[s.hordeId].state = "failed"
    for _, f in ipairs(StoryEngine.Factions.list) do StoryEngine.Radio.channel(f.id).trust = 10 end
    Council.tick(now())
    H.eq(s.result, "failed")
    H.eq(Social.story("pike").node, "pike5_9b")
end

-- 4회차 곁가지: 모두 이어지고 결말이 있으며, NPC 마다 다섯 개 이상, 후임마다 두 개
function T.every_side_story_is_complete()
    local Stories = StoryEngine.Stories
    local per, voices = {}, {}
    for _, def in ipairs(Stories.EPISODES) do
        local ids = {}
        for _, n in ipairs(def.nodes) do ids[n.id] = n end
        for _, n in ipairs(def.nodes) do
            H.ok(Stories.node(def.npc, n.id) == n, n.id .. " is attached")
            H.eq(Stories.arcOf(def.npc, n.id), def.id, n.id .. " belongs to its side story")
            H.eq(n.episode, def.id)
            if n.final then
                H.ok(n.tone, n.id .. " has a tone")
            else
                for _, x in ipairs({ n.next, n.win, n.lose }) do H.ok(ids[x], n.id .. " leads to " .. tostring(x)) end
                if n.quest then H.ok(n.win and n.lose and #n.quest.items > 0, n.id .. " can be asked") end
            end
        end
        local w = def.when or {}
        if w.voice then voices[w.voice] = (voices[w.voice] or 0) + 1
        else per[def.npc] = (per[def.npc] or 0) + 1 end
    end
    for _, f in ipairs(StoryEngine.Factions.list) do
        if f.id ~= "open" then H.ok((per[f.id] or 0) >= 5, f.id .. " has five side stories") end
    end
    for v in pairs(Stories.VOICES) do H.eq(voices[v], 2, v .. " has two side stories") end
end

function T.side_story_conditions()
    setup()
    local Social, Stories = StoryEngine.Social, StoryEngine.Stories
    local function def(id)
        for _, d in ipairs(Stories.EPISODES) do if d.id == id then return d end end
    end
    local season, voiceOf = Social.season, StoryEngine.Voices.of
    Social.season = function() return "winter" end
    local sled = def("rayep4")
    H.eq(Social.episodeOk(sled, "ray", now()), false, "nobody at the farm to build a sled for")
    Social.story("ray").flags.ray_lily = true
    H.eq(Social.episodeOk(sled, "ray", now()), true, "Lily lives at the farm")
    Social.season = function() return "summer" end
    H.eq(Social.episodeOk(sled, "ray", now()), false, "no snow in summer")
    H.eq(Social.episodeOk(def("rayep1"), "ray", now()), true)
    -- 후임의 곁가지는 그 후임에게만, 처음 사람의 곁가지는 후임에게 안 열린다
    H.eq(Social.episodeOk(def("marthaep1"), "ray", now()), false)
    StoryEngine.Voices.of = function(fid) if fid == "ray" then return "martha" end end
    H.eq(Social.episodeOk(def("marthaep1"), "ray", now()), true)
    H.eq(Social.episodeOk(def("rayep1"), "ray", now()), false)
    Social.season, StoryEngine.Voices.of = season, voiceOf
end

-- 방치·실패로 잃은 NPC 의 후임은 냉랭하게 (2026-10-08, 샌드박스 SuccessorRule 기본 2)
function T.a_contact_lost_by_neglect_gets_a_cold_successor()
    setup()
    local Life, Voices, Projects = StoryEngine.Life, StoryEngine.Voices, StoryEngine.Projects
    StoryEngine.Radio.channel("ray").trust = 80
    Projects.of("ray").points = 400
    Life.change("ray", "food", 5 - Life.get("ray", "food"), "debug")
    StoryEngine.Fate.apply("ray", "gone", "starve")
    local p = StoryEngine.Store.data().voices.pending.ray
    H.ok(p and p.cold, "a cold successor is booked")
    H.ok(p.dueT - now().t >= 20 * 24 * 60, "and takes 20 days or more")
    H.ok(Voices.take("ray", now()))
    H.eq(StoryEngine.Radio.channel("ray").trust, 0, "trust starts from nothing")
    H.eq(Life.get("ray", "food"), Life.SELF_MIN, "only enough to hold on (not the usual 30)")
    H.eq(Projects.of("ray").points, 200, "half the project fell apart")
    local ch = StoryEngine.Radio.channel("ray")
    H.ok(ch.messages[#ch.messages].cold or ch.messages[#ch.messages - 1].cold, "the takeover line says so")
end

function T.choices_are_not_failures()
    local Fate = StoryEngine.Fate
    H.eq(Fate.failed("story2:guard4_4l"), false, "Whitaker chose Fort Knox")
    H.eq(Fate.failed("story2:rats2b_5g"), false, "the players sided with the soldiers")
    H.eq(Fate.failed("story2:rats2b_5x"), true)
    H.eq(Fate.failed("story2:hunter2b_5x"), true)
    H.eq(Fate.failed("starve"), true)
    H.eq(Fate.failed("story"), true)
    H.eq(Fate.failed("debug"), false)
end

function T.successor_rule_options()
    setup()
    SandboxVars.StoryEngine.SuccessorRule = 3
    StoryEngine.Fate.apply("doc", "dead", "starve")
    H.eq(((StoryEngine.Store.data().voices or {}).pending or {}).doc, nil, "no successor after a failure")
    SandboxVars.StoryEngine.SuccessorRule = 1
    StoryEngine.Fate.apply("pike", "dead", "starve")
    local p = StoryEngine.Store.data().voices.pending.pike
    H.ok(p and not p.cold, "the usual successor")
    SandboxVars.StoryEngine.SuccessorRule = nil
end

-- 후임은 앞 사람의 개인 사정·관계 메모·아는 사람·말투를 쓰지 않는다 (2026-10-08)
function T.successors_have_their_own_needs_notes_people_and_lines()
    setup()
    local Stories, Needs, Lines = StoryEngine.Stories, StoryEngine.Needs, StoryEngine.Lines
    StoryEngine.Fate.apply("ray", "gone", "debug")
    H.ok(StoryEngine.Voices.take("ray", now()))
    H.eq(Needs.listOf("ray"), Needs.VOICE_TABLE.martha, "Martha's own requests")
    for _ = 1, 40 do
        local n = Needs.pick("ray", 5)
        H.ok(n and not string.find(n.why, "daughter", 1, true), "no talk of Ray's daughter")
    end
    H.eq(Needs.listOf("doc"), Needs.TABLE.doc, "June keeps hers")
    local mine = Stories.relationsOf("ray")
    H.eq(mine.pike, Stories.VOICE_RELATIONS.martha.pike)
    H.eq(mine.dewey, nil, "Ray's hopes about Dewey's truck are not Martha's")
    local casey = Stories.relationsOf("casey")
    H.ok(string.find(casey.ray, "took over", 1, true), "Casey's note about Ray now speaks of a newcomer")
    local ctx = StoryEngine.Social.context("casey")
    for _, o in ipairs(ctx.others) do
        if o.id == "ray" then H.ok(not string.find(o.note or "", "uncle", 1, true)) end
    end
    for _, f in ipairs(StoryEngine.Factions.list) do StoryEngine.Radio.channel(f.id).trust = 100 end
    for _, person in ipairs(StoryEngine.Named.candidates()) do
        H.ok(person.npc ~= "ray", "nobody from Ray's past is asked for")
    end
    H.ok(string.find(Lines.lt("ray", "supply_drop").key, "Line_martha_supply_drop_", 1, true))
    H.ok(string.find(Lines.lt("ray", "duo_warm_open").key, "Line_martha_duo_warm_open_", 1, true))
    StoryEngine.Fate.apply("rats", "gone", "debug")
    StoryEngine.Voices.take("rats", now())
    local v = StoryEngine.Voices.of("rats")
    H.ok(string.find(Lines.lt("rats", "extort").key, "Line_" .. v .. "_extort_", 1, true), "the Coalfield successor threatens in their own words")
end

return T
