-- 2026-10-08 전체 점검 (docs/AUDIT_2026-10-08.md) 수정 확인
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

-- A2: 고갈로 잃은 뒤 온 냉랭한 후임이 3일 뒤 또 떠나지 않는다
function T.a_cold_successor_does_not_starve_again()
    setup()
    local Life, Fate = StoryEngine.Life, StoryEngine.Fate
    for _, r in ipairs(Life.RESOURCES) do Life.change("ray", r, 5 - Life.get("ray", r), "debug") end
    Fate.apply("ray", "gone", "starve")
    H.ok(StoryEngine.Voices.take("ray", now()))
    for _ = 1, 4 do Fate.daily() end
    H.eq(Fate.isGone("ray"), false, "Martha is still on the air")
end

-- A3: 고른 NPC 가 죽어 위기 후속 부탁이 거둬지면 함께 도운 NPC 이야기가 넘어간다. 빚 독촉·아는 얼굴도 거둔다
function T.cancel_releases_crisis_allies_debts_and_named()
    setup()
    local Social, Quests, Store = StoryEngine.Social, StoryEngine.Quests, StoryEngine.Store
    local d = Store.data()
    d.questSeq = (d.questSeq or 0) + 1
    local follow = { id = "QX1", kind = "deliver", state = "accepted", tier = 2, need = { { "Base.Sheet", 2 } },
                     origin = { faction = "pike", story = { crisis = "lily" } } }
    d.quests[follow.id] = follow
    local named = { id = "QX2", kind = "named", state = "accepted", tier = 2, origin = { faction = "pike" } }
    d.quests[named.id] = named
    local choice = { id = "QX3", kind = "choice", state = "proposed", crisis = "truck",
                     options = { { faction = "pike" }, { faction = "ray" }, { faction = "doc" } }, origin = { faction = "pike" } }
    d.quests[choice.id] = choice
    StoryEngine.Radio.channel("pike").favorOwed = { qid = "Q0", called = true }
    Quests.cancelFor("pike", now())
    H.eq(follow.state, "declined")
    H.ok(Social.story("ray").flags.lily_failed, "Ray (ally) can move on")
    H.eq(named.state, "declined", "known-face quests are taken back too")
    H.eq(#choice.options, 2, "Pike's option is dropped from the open crisis")
    H.eq(choice.state, "proposed")
    H.eq(StoryEngine.Radio.channel("pike").favorOwed, nil, "the called favour no longer blocks the channel")
end

-- A4: 10번째 AI 곁가지도 제 이름으로
function T.arc_ids_with_two_digits()
    local Stories = StoryEngine.Stories
    H.eq(Stories.arcOf("ray", "rayai10_1"), "rayai10")
    H.eq(Stories.arcOf("ray", "ray2a_5a"), "ray2a")
    H.eq(Stories.arcOf("ray", "ray_3"), "ray1")
end

-- A5: 죽거나 떠나기로 정해진 NPC 에게는 곁가지가 열리지 않고, 곁가지 중이었어도 큰 이야기 결말로 후임을 고른다
function T.no_side_story_while_a_fate_is_pending()
    setup()
    local Social = StoryEngine.Social
    local st = at("rats", "rats2b_5g")
    H.ok(StoryEngine.Fate.doomed("rats"), "the ending booked Vic's departure")
    st.epUsed = {}
    StoryEngine.Bridge.state = "disconnected"
    for _, f in ipairs(StoryEngine.Factions.list) do
        if f.id ~= "rats" then at(f.id, Social.story(f.id).node) end
    end
    local id = Social.pickEpisode(now())
    H.ok(not (id and string.find(id, "^rats")), "no side story for Vic, got " .. tostring(id))
    st.ep = { id = "ratsep1", node = "rats2b_5g" }
    st.node = "ratsep1_1"
    H.eq(StoryEngine.Voices.pick("rats"), "red", "the main-story ending decides the successor")
    st.ep, st.node = nil, "rats2b_5g"
end

-- A6: NPC 죽음을 끄면 죽음·떠남 결말 뒤에도 다음 장이 온다
function T.survived_endings_lead_on()
    setup()
    SandboxVars.StoryEngine.NpcFateCause = 3
    local Social = StoryEngine.Social
    local st = at("ray", "ray2a_7x")
    H.eq(StoryEngine.Fate.isGone("ray"), false)
    H.ok(st.sequelAt, "a next chapter is booked")
    st.sequelAt = now().t
    Social.advance("ray", now())
    H.eq(st.node, "ray3_1c")
    SandboxVars.StoryEngine.NpcFateCause = nil
end

-- A7: 방주가 달리는지는 듀이 이야기의 결말로
function T.the_ark_depends_on_how_deweys_story_ended()
    setup()
    local Social = StoryEngine.Social
    local function rayResult(path)
        Social.story("dewey").path = path
        local st = at("ray", "ray2a_4")
        Social.onQuest({ kind = "deliver", origin = { faction = "ray", story = { faction = "ray", node = "ray2a_4" } } }, "completed")
        return st.node
    end
    H.eq(rayResult({ { node = "dewey_5a" }, { node = "dewey2a_1" }, { node = "dewey2a_5x" } }), "ray2a_5a", "the Ark crashed")
    H.eq(rayResult({ { node = "dewey_5a" }, { node = "dewey2a_5a" }, { node = "dewey3_1a" } }), "ray2a_5d", "the Ark runs")
    H.eq(rayResult({ { node = "dewey_5b" } }), "ray2a_5a", "the Ark was shelved")
end

-- A8: 떠나기로 정해진 NPC 는 위기 선택지에 들지 않고, 골라도 받지 않는다
function T.doomed_npcs_stay_out_of_crises()
    local p = setup()
    local Quests = StoryEngine.Quests
    local d = StoryEngine.Store.data()
    d.fatePending = { pike = { dueT = now().t + 600, kind = "dead", reason = "story" } }
    local q = { id = "QX9", kind = "choice", state = "proposed", crisis = "truck",
                options = { { faction = "pike" }, { faction = "ray" } }, origin = { faction = "pike" } }
    d.quests[q.id] = q
    local ok, why = Quests.choose(p, "QX9", 1)
    H.eq(ok, false)
    H.eq(why, "gone")
    d.fatePending = {}
end

-- B1·B2·B6: 후임에게는 앞 사람의 대화·기억·관계가 넘어가지 않고, 앞 사람의 줄은 앞 사람 이름으로 남는다
function T.a_successor_starts_with_a_clean_slate()
    setup()
    local Radio, Bonds = StoryEngine.Radio, StoryEngine.Bonds
    local ch = Radio.channel("ray")
    Radio.push("ray", { from = "npc", text = "Annie is out there somewhere.", clock = "10:00" })
    ch.memory = "Promised to look for Annie."
    H.eq(ch.messages[#ch.messages].voice, false, "Ray's own line")
    H.ok(Bonds.get("ray", "rats") < 0, "Ray dislikes Vic")
    StoryEngine.Fate.apply("ray", "gone", "debug")
    StoryEngine.Voices.take("ray", now())
    H.eq(ch.memory, nil, "Martha does not remember Ray's talks")
    H.eq(Bonds.get("ray", "rats"), 0, "and has no quarrel with Coalfield yet")
    H.eq(Bonds.get("rats", "ray"), 0)
    Radio.push("ray", { from = "npc", text = "Martha here.", clock = "11:00" })
    H.eq(ch.messages[#ch.messages].voice, "martha")
    H.eq(StoryEngine.Factions.nameAs("ray", false) ~= StoryEngine.Factions.nameAs("ray", "martha"), true)
    Radio.busy.ray, Radio.queue.ray = false, nil       -- Ray 의 작별 무전 요청은 끝난 것으로
    StoryEngine.Radio.request("ray", "EN", { mode = "chat", topic = "hi" })
    local b = H.lastBridge("radio")
    for _, m in ipairs(b and b.payload.history or {}) do
        H.ok(not string.find(m.text or "", "Annie", 1, true), "history: " .. tostring(m.n) .. " " .. tostring(m.text))
    end
end

-- B3: 위기 글이 처음 사람들을 부르므로, 후임이 낀 위기는 열리지 않는다
function T.crises_that_name_the_original_people_wait()
    setup()
    StoryEngine.Fate.apply("ray", "gone", "debug")
    StoryEngine.Voices.take("ray", now())
    local ok = StoryEngine.Social.startCrisis(now(), "truck")
    H.eq(ok, false, "the truck crisis asks Ray, not Martha")
end

-- B5: 앞 사람이 남긴 편지는 앞 사람 이름으로, 후임 채널을 기다리지 않고 실린다
function T.a_farewell_letter_keeps_its_writer()
    setup()
    local Letters = StoryEngine.Letters
    StoryEngine.Fate.apply("ray", "gone", "debug")
    local pend = StoryEngine.Store.data().letters
    H.ok(pend and #pend.pending > 0, "Ray's farewell is waiting")
    H.eq(pend.pending[1].voice, false)
    StoryEngine.Voices.take("ray", now())
    local q = { id = "QL1", kind = "supply_drop", items = {}, origin = { faction = "doc" } }
    local rec = Letters.attach(q, StoryEngine.Store.player(H.players[1]), now())
    H.ok(rec, "it goes out with the next supply drop")
    H.eq(rec.from, "ray")
    H.eq(rec.voice, false, "signed by Ray, not Martha")
    local b = H.lastBridge("letter")
    H.eq(b.payload.voices.ray, nil, "written in Ray's voice")
end

-- B8: 이야기 결과와 어긋나는 부탁은 나오지 않는다
function T.requests_follow_the_story()
    setup()
    local Social, Needs = StoryEngine.Social, StoryEngine.Needs
    Social.story("casey").path = { { node = "casey_1" }, { node = "casey_5b" } }
    for _ = 1, 40 do
        local n = Needs.pick("casey", 3)
        H.ok(n and not string.find(n.why, "heart", 1, true), "no medicine for a father who died")
    end
    at("ray", "ray2a_1")
    for _ = 1, 40 do
        local n = Needs.pick("ray", 5)
        H.ok(n and not string.find(n.why, "daughter", 1, true), "Ray already went for Annie")
    end
end

-- C2: 외상을 떼먹으면 신뢰도가 30 아래로
function T.defaulting_drops_trust_below_thirty()
    setup()
    StoryEngine.Radio.channel("doc").trust = 85
    StoryEngine.Work.default({ id = "QD", tier = 2, category = "medical", origin = { faction = "doc" } }, "credit_default", now())
    H.ok(StoryEngine.Radio.channel("doc").trust <= 30, "trust " .. tostring(StoryEngine.Radio.channel("doc").trust))
end

-- C3: 좋은 쪽 파급도 주 +2 까지
function T.positive_spill_is_capped()
    setup()
    SandboxVars.StoryEngine.Spillover = true
    local Life, Bonds = StoryEngine.Life, StoryEngine.Bonds
    Bonds.change("pike", "ray", 3, "test", false)
    local before = StoryEngine.Radio.channel("pike").trust
    for _ = 1, 6 do Life.spill("ray", "Gerald", true) end
    H.eq(StoryEngine.Radio.channel("pike").trust - before, Life.SPILL_UP_WEEK_CAP)
end

-- C4: 부탁을 외면한 뒤 한동안은 형편이 저절로 나아지지 않는다
function T.neglect_keeps_a_camp_down()
    setup()
    local Life = StoryEngine.Life
    Life.daily()
    Life.change("doc", "medical", 30 - Life.get("doc", "medical"), "debug")
    Life.onQuest({ kind = "deliver", tier = 1, need = { { "Base.Bandage", 2 } }, origin = { faction = "doc" } }, "ignored", -1)
    local low = Life.get("doc", "medical")
    for _ = 1, 3 do
        H.advanceDays(1)
        Life.daily()
    end
    H.eq(Life.get("doc", "medical"), low, "no recovery right after being ignored")
    H.advanceDays(8)
    Life.daily()
    H.ok(Life.get("doc", "medical") > low, "it recovers after a week")
end

-- C5: 남의 보상은 사양할 수 없다
function T.only_the_receiver_can_waive()
    local p = setup()
    local other = H.addPlayer("other", "Ann", "Lee")
    local d = StoryEngine.Store.data()
    d.quests.QP = { id = "QP", kind = "deliver", tier = 2, state = "completed", target = StoryEngine.Store.playerKey(p),
                    origin = { faction = "doc" } }
    d.quests.QR = { id = "QR", kind = "supply_drop", tier = 1, state = "offered", target = StoryEngine.Store.playerKey(p),
                    origin = { source = "reward", faction = "doc", rewardFor = "QP", rewardKind = "deliver" } }
    local ok, why = StoryEngine.Quests.waiveReward(other, "QR")
    H.eq(ok, false)
    H.eq(why, "not_yours")
end

-- C6: 곁가지 부탁은 프로젝트에 등급만큼만
function T.side_story_project_points_scale_with_tier()
    setup()
    local Projects = StoryEngine.Projects
    local before = Projects.of("doc").points
    Projects.onStoryWin("doc", "Gerald", { chapter = "ep" }, 2)
    H.eq(Projects.of("doc").points - before, 30)
    Projects.onStoryWin("doc", "Gerald", { chapter = 3 }, 2)
    H.eq(Projects.of("doc").points - before, 30 + Projects.STORY_POINTS)
end

-- D4: 협박한 NPC 가 떠났으면 보복은 없다
function T.no_revenge_from_a_gone_npc()
    setup()
    StoryEngine.Fate.apply("rats", "gone", "debug")
    local q = { id = "QE", kind = "extort", origin = { faction = "rats" }, target = "nobody", punishPending = true }
    StoryEngine.Quests.punish(q)
    H.eq(q.punishPending, nil)
end

return T
