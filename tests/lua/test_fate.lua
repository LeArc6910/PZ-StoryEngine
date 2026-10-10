-- NPC 죽음·떠남 3단계 (Fate.lua 와 모든 기능의 걸러내기)
local T = {}

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    H.defineItem("Base.TinnedBeans", "food", 1.5)
    return p, ps
end

local function res(fid, r) return StoryEngine.Life.npc(fid).res[r] end
local function gone(fid) return StoryEngine.Factions.isGone(fid) end

-- fid 의 이야기 부탁 노드에서 결과를 낸다
local function storyResult(fid, node, outcome)
    local Social = StoryEngine.Social
    Social.story(fid).node = node
    Social.onQuest({ kind = "deliver", origin = { faction = fid, story = { faction = fid, node = node } } }, outcome)
end

local function doomPike()
    storyResult("pike", "pike_2", "failed")        -- -> pike_3b
    storyResult("pike", "pike_4", "ignored")       -- -> pike_5b (마지막)
end

function T.story_doom_kills_after_a_day_and_filters_everything()
    local p, ps = setup()
    local q = StoryEngine.Quests.propose(p, ps, "pike", 1, StoryEngine.Sensor.now())
    H.ok(q and q.state == "proposed", "an open request from pike")
    q.respondBy = q.respondBy + 3 * 24 * 60          -- 하루 기다리는 동안 무응답으로 끝나지 않게
    local trustBefore = StoryEngine.Radio.channel("pike").trust
    doomPike()
    H.eq(StoryEngine.Social.story("pike").node, "pike_5b")
    H.ok(not gone("pike"), "not yet: a day later")
    H.ok(H.logHas("fate scheduled pike dead"))
    H.advanceDays(1)
    H.fire("EveryTenMinutes")
    H.ok(gone("pike"), "pike died")
    H.eq(StoryEngine.Life.npc("pike").fate.kind, "dead")
    -- 진행 중 부탁은 조용히 취소
    H.eq(q.state, "declined")
    H.ok(q.cancelled)
    H.eq(StoryEngine.Radio.channel("pike").trust, trustBefore, "no trust change from the cancel")
    -- 다른 NPC: 친한 레이 -25, 빅 -15
    H.eq(res("ray", "morale"), 60 - 25)
    H.eq(res("rats", "morale"), 55 - 15)
    -- 소식을 전하는 NPC, 일지, 클라이언트 알림
    local b = H.lastBridge("radio", "event")
    H.ok(b and string.find(b.payload.topic, "terrible news", 1, true), "someone announces it")
    H.ok(b.payload.faction ~= "pike")
    H.eq(ps.notes[#ps.notes].kind, "npc_dead")
    H.eq(#H.sentOf("npcFate"), 1)
    -- 걸러내기
    local n = #H.bridge
    StoryEngine.Radio.say(p, "pike", "Brother Pike, are you there?")
    H.eq(#H.bridge, n, "no AI request for the dead")
    local msgs = StoryEngine.Radio.channel("pike").messages
    H.eq(msgs[#msgs].from, "static")
    H.eq(msgs[#msgs].error, "gone")
    for _ = 1, 30 do
        local c = StoryEngine.Social.pickContact(StoryEngine.Sensor.now())
        H.ok(not c or c.fid ~= "pike", "pike never calls")
        H.ok(StoryEngine.Director.pickFaction() ~= "pike", "director never picks pike")
    end
    local ok, why = StoryEngine.Life.donate(p, "pike", { H.give(p, "Base.TinnedBeans"):getID() })
    H.eq(why, "gone")
    H.eq(StoryEngine.Specialty.status("pike").reason, "gone")
    H.eq(StoryEngine.Trade.context("pike", ps).reason, "no_trader")
    local pike
    for _, c in ipairs(StoryEngine.Radio.channelList()) do if c.id == "pike" then pike = c end end
    H.eq(pike.gone, "dead")
    for _, e in ipairs(StoryEngine.Life.list()) do
        if e.id == "pike" then H.eq(e.fate, "dead") end
    end
    -- 다른 NPC 가 AI 요청에서 그 죽음을 안다
    StoryEngine.Radio.say(p, "ray", "hello")
    local rb = H.lastBridge("radio")
    local seen = false
    for _, o in ipairs(rb.payload.story.others) do
        if o.id == "pike" then seen = o.gone == "dead" end
    end
    H.ok(seen, "ray's context says pike is dead")
end

function T.a_single_win_prevents_doom()
    setup()
    storyResult("doc", "doc_2", "completed")        -- -> doc_3a
    storyResult("doc", "doc_4", "failed")           -- -> doc_5b (마지막)
    H.advanceDays(2)
    H.fire("EveryTenMinutes")
    H.ok(not gone("doc"), "one success keeps her alive")
end

function T.crisis_help_counts_as_a_win()
    setup()
    StoryEngine.Fate.onStoryResult("pike", true)
    doomPike()
    H.advanceDays(2)
    H.fire("EveryTenMinutes")
    H.ok(not gone("pike"))
end

function T.departing_npc_says_goodbye_first()
    local p = setup()
    storyResult("ray", "ray_3", "declined")          -- -> ray_4b
    StoryEngine.Social.story("ray").node = "ray_5b"
    storyResult("ray", "ray_5b", "failed")           -- -> ray_end_bad
    H.advanceDays(1)
    H.fire("EveryTenMinutes")
    H.ok(gone("ray"))
    local found = false
    for _, b in ipairs(H.bridge) do
        if b.payload.faction == "ray" and string.find(tostring(b.payload.topic), "last call", 1, true) then found = true end
    end
    H.ok(found, "ray's farewell was requested")
end

function T.starvation_warns_twice_then_leaves()
    setup()
    local Life = StoryEngine.Life
    Life.daily()
    for _, r in ipairs(Life.RESOURCES) do Life.npc("dewey").res[r] = 5 end
    for _, r in ipairs(Life.RESOURCES) do Life.npc("hunter").res[r] = 5 end
    for day = 1, 2 do
        H.advanceDays(1)
        Life.daily()
        H.eq(Life.npc("dewey").starve, day)
        H.ok(not gone("dewey"), "still there on day " .. day)
    end
    H.ok(H.lastBridge("radio", "event"), "warning calls")
    -- 헌터는 이틀째에 누가 물자를 보내 줌 -> 다시 센다
    Life.npc("hunter").res.food = 25
    H.advanceDays(1)
    Life.daily()
    H.ok(gone("dewey"), "dewey leaves on day 3")
    H.eq(Life.npc("dewey").fate.reason, "starve")
    H.eq(Life.npc("hunter").starve, 0, "hunter's count reset")
    H.ok(not gone("hunter"))
end

function T.sandbox_off_survives_and_only_warns()
    setup()
    SandboxVars.StoryEngine.NpcFate = false
    local Life = StoryEngine.Life
    for _, r in ipairs(Life.RESOURCES) do Life.npc("pike").res[r] = 5 end
    doomPike()
    H.advanceDays(2)
    H.fire("EveryTenMinutes")
    H.ok(not gone("pike"), "badly hurt but alive")
    H.ok(res("pike", "food") >= 20, "resources brought back to 20")
    local log = Life.npc("pike").log
    H.eq(log[#log].kind, "survived")
    Life.daily()
    for _, r in ipairs(Life.RESOURCES) do Life.npc("dewey").res[r] = 5 end
    for _ = 1, 5 do
        H.advanceDays(1)
        Life.daily()
    end
    H.ok(not gone("dewey"), "only warnings")
    H.eq(Life.npc("dewey").starve, 2)
end

function T.revive_and_debug_commands()
    local p = setup()
    local C = StoryEngine.Commands
    C.debugLife(p, { faction = "hunter", delta = 0, fate = "gone" })
    H.ok(gone("hunter"))
    -- 떠나면서 예약된 후임과 작별 편지 (2026-10-10 인게임: 되살려도 남아 있었음)
    local d = StoryEngine.Store.data()
    H.ok(d.voices and d.voices.pending.hunter, "a successor was scheduled")
    local farewell = 0
    for _, l in ipairs(d.letters and d.letters.pending or {}) do if l.fid == "hunter" then farewell = farewell + 1 end end
    H.eq(farewell, 1, "a farewell letter was waiting")
    -- 떠났다는 소문·방송 재료·일기 메모도 퍼져 있다
    local function count()
        local news, facts, notes = 0, 0, 0
        for _, list in pairs(d.social.news) do
            for _, item in ipairs(list) do if string.find(item.text, "Hank", 1, true) then news = news + 1 end end
        end
        for _, f in ipairs(d.broadcast and d.broadcast.facts or {}) do
            if string.find(f.text, "Hank", 1, true) then facts = facts + 1 end
        end
        for _, ps in pairs(d.players) do
            for _, note in ipairs(ps.notes or {}) do
                if note.kind == "npc_gone" and note.faction == "hunter" then notes = notes + 1 end
            end
        end
        return news, facts, notes
    end
    local news, facts, notes = count()
    H.ok(news > 0 and facts > 0 and notes > 0, "word got around: " .. news .. " " .. facts .. " " .. notes)
    StoryEngine.Social.news("ray", "Someone saw smoke over the river.")
    C.debugLife(p, { faction = "hunter", delta = 0, fate = "revive" })
    H.ok(not gone("hunter"))
    H.eq(res("hunter", "food"), 70, "back to baseline")
    H.eq(d.voices.pending.hunter, nil, "no successor is coming any more")
    news, facts, notes = count()
    H.eq(news + facts + notes, 0, "rumours, broadcast material and diary notes are withdrawn")
    H.eq(#d.social.news.ray, 1, "other news stays")
    H.ok(H.logHas("fate news withdrawn hunter"))
    for _, l in ipairs(d.letters.pending) do H.ok(l.fid ~= "hunter", "the farewell letter is withdrawn") end
    local told = H.sentOf("npcFate")
    H.eq(told[#told].kind, "revived", "everyone's lists refresh")
    -- 멀쩡한 NPC 에게 누르면 자원·이야기 성적은 그대로, 남은 예약만 거둔다 (2026-10-10 인게임)
    local Life = StoryEngine.Life
    Life.npc("ray").res.food = 33
    StoryEngine.Social.story("ray").wins = 1
    d.voices.pending.ray = { dueT = 999999 }
    C.debugLife(p, { faction = "ray", delta = 0, fate = "revive" })
    H.eq(res("ray", "food"), 33, "a living contact keeps what they have")
    H.eq(StoryEngine.Social.story("ray").wins, 1)
    H.eq(d.voices.pending.ray, nil, "leftovers are still cleared")
    H.eq(#H.sentOf("npcFate"), #told, "no announcement")
    C.debugLife(p, { faction = "rats", delta = 0, fate = "doom" })
    H.advance(10)
    H.fire("EveryTenMinutes")
    H.ok(gone("rats"), "debug doom comes due right away")
    H.eq(StoryEngine.Life.npc("rats").fate.kind, "dead")
end

function T.crises_with_a_gone_npc_are_skipped()
    setup()
    local s = StoryEngine.Store.data().social or {}
    StoryEngine.Store.data().social = s
    StoryEngine.Fate.apply("doc", "dead", "debug")
    local social = StoryEngine.Social
    social.startCrisis(StoryEngine.Sensor.now())       -- 상태 테이블을 만든다
    local used = StoryEngine.Store.data().social.crisesUsed
    for _, id in ipairs({ "truck", "signal", "raid" }) do used[id] = true end
    local ok, why = social.startCrisis(StoryEngine.Sensor.now())
    H.eq(ok, false)
    H.eq(why, "no_crisis", "the fever crisis needs doc")
end

-- 놓치면 NPC 를 잃을 수 있는 퀘스트 (2026-10-10 사용자 요청: 퀘스트 탭에서 강조)
function T.quests_that_can_cost_a_contact_are_flagged()
    local p, ps = setup()
    local Fate, Social, Life = StoryEngine.Fate, StoryEngine.Social, StoryEngine.Life
    local function story(fid, node, state)
        return { kind = "deliver", state = state or "accepted",
                 origin = { faction = fid, initiator = "npc", story = { faction = fid, node = node } } }
    end
    -- 첫 이야기: 한 번도 돕지 못했고 이번에 놓치면 두 번째 실패
    local st = Social.story("pike")
    st.node = "pike_4"
    H.eq(Fate.questRisk(story("pike", "pike_4")), nil, "the first miss is not the end")
    st.losses = 1
    local r = Fate.questRisk(story("pike", "pike_4"))
    H.ok(r and r.why == "fail" and r.kind == "dead" and r.faction == "pike", "one more miss and Pike dies")
    H.ok(Fate.questRisk(story("pike", "pike_4", "proposed")), "also while it waits for an answer")
    H.eq(Fate.questRisk(story("pike", "pike_4", "completed")), nil, "not once it is over")
    st.wins = 1
    H.eq(Fate.questRisk(story("pike", "pike_4")), nil, "one earlier success is enough")
    st.wins = nil
    H.eq(Fate.questRisk(story("pike", "pike_2")), nil, "not the scene the story is on")
    -- 뒤 이야기: 실패한 갈래가 떠나는 결말
    Social.story("guard").node = "guard2a_5"
    Social.story("guard").wins = 3
    r = Fate.questRisk(story("guard", "guard2a_5"))
    H.ok(r and r.why == "fail" and r.kind == "gone", "losing this one ends with Whitaker pulling out")
    -- 위기: 고르기에 따라 떠난다
    Social.story("guard").node = "guard4_3"
    r = Fate.questRisk({ kind = "choice", state = "proposed", crisis = "knox", origin = { faction = "guard" } })
    H.ok(r and r.why == "outcome" and r.kind == "gone" and r.faction == "guard", "the Knox call can take Whitaker away")
    H.eq(Fate.questRisk({ kind = "choice", state = "proposed", crisis = "truck", origin = { faction = "ray" } }), nil)
    -- 고갈: 네 자원이 모두 바닥
    local n = Life.npc("dewey")
    for _, res in ipairs(Life.RESOURCES) do n.res[res] = 5 end
    local ask = { kind = "deliver", state = "accepted", origin = { faction = "dewey", initiator = "npc" } }
    r = Fate.questRisk(ask)
    H.ok(r and r.why == "starve" and r.days == Fate.STARVE_DAYS, "three days left")
    n.starve = 2
    H.eq(Fate.questRisk(ask).days, 1)
    H.eq(Fate.questRisk({ kind = "trade", state = "accepted", origin = { faction = "dewey", initiator = "player" } }), nil,
        "a trade is not a rescue")
    -- 열병 약품 모금
    r = Fate.questRisk({ kind = "collect", state = "accepted", origin = { sagaKind = "epidemic" } })
    H.ok(r and r.why == "fever" and r.kind == "dead")
    -- 퀘스트 목록에 실려 간다
    local q = StoryEngine.Quests.propose(p, ps, "dewey", 1, StoryEngine.Sensor.now())
    H.ok(q, "dewey asks for something")
    local found
    for _, item in ipairs(StoryEngine.Quests.listFor(ps.key, StoryEngine.Sensor.now())) do
        if item.id == q.id then found = item end
    end
    H.ok(found and found.risk and found.risk.why == "starve", "the quest tab is told")
    -- 죽음·떠남을 끈 서버에서는 표시하지 않는다
    SandboxVars.StoryEngine.NpcFate = false
    H.eq(Fate.questRisk(ask), nil)
    SandboxVars.StoryEngine.NpcFate = nil
end

return T
