-- 개인 신뢰 핵심 (docs/DESIGN_PER_PLAYER_TRUST.md): 집단/개인 나누기, 무리의 일 보너스, 개인별 부탁,
-- 받은 사람에게만 보이는 줄, 대화 상한, 식음, 모드 전환
local T = {}

local function setup(personal)
    if personal then H.personalMode() end
    local a = H.addPlayer("alice", "Alice", "Ash")
    local b = H.addPlayer("bob", "Bob", "Birch")
    local pa, pb = StoryEngine.Store.player(a), StoryEngine.Store.player(b)
    pa.lang, pb.lang = "EN", "EN"
    return a, b, pa, pb
end

local function Tr() return StoryEngine.Trust end
local function ch(fid) return StoryEngine.Radio.channel(fid) end

local function storyAsk(p, ps, fid, tier)
    local q = StoryEngine.Quests.proposeCustom(p, ps, fid, { tier = tier or 2, why = "story", items = { { "Base.Bandage", 2 } } },
        StoryEngine.Sensor.now(), { silent = true, story = { faction = fid, node = fid .. "_2" } })
    q.state = "accepted"
    return q
end

function T.single_player_keeps_one_trust()
    local a, _, pa = setup(false)
    H.eq(Tr().personalMode(), false)
    SandboxVars.StoryEngine.TrustBenefits = 2
    H.eq(Tr().personalMode(), false, "single player never splits trust")
    H.eq(Tr().of("ray", pa.key), ch("ray").trust)
    Tr().apply("ray", 2, "donation", nil, pa.key)
    H.eq(ch("ray").trust, 32, "one trust moves")
end

function T.first_contact_takes_an_intro_share_of_group_trust()
    local _, _, pa = setup(true)
    ch("ray").trust = 70                 -- ray starts at 30
    H.eq(Tr().personal("ray", pa.key), 40, "preview: 30 + (70 - 30) x 25%")
    H.eq(Tr().known("ray", pa.key), false, "reading does not make them acquainted")
    H.eq(Tr().ensure("ray", pa.key), 40, "first contact")
    ch("ray").trust = 90
    H.eq(Tr().personal("ray", pa.key), 40, "fixed at first contact")
    H.eq(Tr().of("ray", pa.key), 40, "benefits read personal trust")
end

function T.personal_work_moves_only_that_person()
    local _, _, pa, pb = setup(true)
    local group = ch("ray").trust
    Tr().apply("ray", 3, "donation", nil, pa.key)
    H.eq(ch("ray").trust, group, "group trust untouched by personal work")
    H.eq(Tr().personal("ray", pa.key), 33)
    H.eq(Tr().personal("ray", pb.key), 30, "the other player gains nothing")
    Tr().apply("ray", 2, "crisis_chosen", nil, nil)
    H.eq(ch("ray").trust, group + 2, "group work moves group trust")
    H.eq(Tr().personal("ray", pa.key), 33)
end

function T.group_work_gives_helpers_a_bonus_and_no_penalty()
    local a, _, pa, pb = setup(true)
    local q = storyAsk(a, pa, "doc", 3)
    StoryEngine.Quests.addHelper(q, pa)
    local group = ch("doc").trust
    local before = Tr().personal("doc", pb.key)
    local aBefore = Tr().personal("doc", pa.key)
    StoryEngine.Quests.setState(q, "completed", StoryEngine.Sensor.now(), { ps = pa })
    H.eq(ch("doc").trust, group + 3, "group +tier")
    H.eq(Tr().personal("doc", pa.key), aBefore + 2, "helper +3 x 0.5 -> 2")
    H.ok(not Tr().known("doc", pb.key), "did not help: nothing (still a stranger)")
    H.ok(before ~= nil)
    -- 실패: 집단만
    local q2 = storyAsk(a, pa, "doc", 1)
    StoryEngine.Quests.addHelper(q2, pa)
    local mine = Tr().personal("doc", pa.key)
    q2.deadlineT = 0
    StoryEngine.Quests.track({}, StoryEngine.Sensor.now())
    H.eq(q2.state, "failed")
    H.ok(ch("doc").trust < group + 3, "group loses")
    H.eq(Tr().personal("doc", pa.key), mine, "no personal penalty for group work")
end

function T.personal_requests_come_to_each_player()
    local a, b, pa, pb = setup(true)
    local D = StoryEngine.Director
    D.personalAsks()
    H.ok(pa.pask and pa.pask.nextT, "first time just schedules (new character)")
    H.advanceDays(2)
    H.rolls = {}
    local okA, qa, whyA = pcall(D.personalAsk, a, pa, StoryEngine.Sensor.now(), false, "deliver")
    H.ok(okA and qa, "personal ask: " .. tostring(qa) .. " " .. tostring(whyA))
    D.personalAsks()
    local mine, theirs
    for _, q in pairs(StoryEngine.Store.data().quests) do
        if q.addressed == pa.key then mine = q end
        if q.addressed == pb.key then theirs = q end
    end
    H.ok(mine and theirs, "each player gets their own request")
    -- 받은 사람만 답한다
    local ok, why = StoryEngine.Quests.respond(b, mine.id, true)
    H.eq(ok, false)
    H.eq(why, "not_addressed")
    H.ok(StoryEngine.Quests.respond(a, mine.id, false), "the addressee can decline")
    H.ok(Tr().personal(mine.origin.faction, pa.key) < Tr().startOf(mine.origin.faction) + 20, "decline costs Alice")
    -- 다음 부탁은 2~5일 뒤
    local wait = (pa.pask.nextT - StoryEngine.Sensor.now().t) / (24 * 60)
    H.ok(wait >= 2 and wait <= 5, "next in 2-5 days: " .. tostring(wait))
end

function T.helpers_share_a_personal_request_success()
    local a, _, pa, pb = setup(true)
    local q = StoryEngine.Quests.propose(a, pa, "ray", 2, StoryEngine.Sensor.now(), { addressed = pa.key })
    H.ok(q, "request made")
    q.state = "accepted"
    StoryEngine.Quests.addHelper(q, pb)
    local bBefore = Tr().personal("ray", pb.key)
    StoryEngine.Quests.setState(q, "completed", StoryEngine.Sensor.now(), { ps = pa })
    H.eq(Tr().personal("ray", pa.key), 30 + q.tier, "addressee +tier")
    H.eq(Tr().personal("ray", pb.key), bBefore + 1, "helper x0.5 (min 1)")
    H.eq(ch("ray").trust, 30, "group trust untouched")
end

function T.private_lines_reach_only_the_addressee()
    local a, b, pa = setup(true)
    local q = StoryEngine.Quests.propose(a, pa, "ray", 1, StoryEngine.Sensor.now(), { addressed = pa.key })
    H.lastBridge("radio", "request").callback({ ok = true, json = { reply = "Alice, could you help me?" } })
    local toA, toB = H.sentTo(a, "radioMessage"), H.sentTo(b, "radioMessage")
    local lastA, lastB = toA[#toA].msg, toB[#toB].msg
    H.eq(lastA.text, "Alice, could you help me?")
    H.ok(lastB.privateNote and lastB.toName == "Alice Ash", "Bob only sees that Ray called Alice")
    local histB = StoryEngine.Radio.history("ray", StoryEngine.Store.playerKey(b))
    for _, m in ipairs(histB) do H.ok(m.text ~= "Alice, could you help me?", "history hides the line from Bob") end
    H.ok(q.id, "quest exists")
    -- 개인 신뢰 줄은 그 사람에게만
    Tr().addPersonal("ray", pa.key, 2, "donation")
    local sysB = H.sentTo(b, "radioMessage")
    H.ok(not (sysB[#sysB].msg.personal), "Bob does not see Alice's personal trust line")
end

function T.addressee_away_pauses_and_lapses_without_penalty()
    local a, _, pa = setup(true)
    local q = StoryEngine.Quests.propose(a, pa, "ray", 1, StoryEngine.Sensor.now(), { addressed = pa.key })
    -- 앨리스가 나감
    for i, p in ipairs(H.players) do if p == a then table.remove(H.players, i) end end
    local Q = StoryEngine.Quests
    Q.track({}, StoryEngine.Sensor.now())
    H.clockMin = H.clockMin + 6 * 60
    Q.track({}, StoryEngine.Sensor.now())
    H.eq(q.state, "proposed", "the clock is paused while away")
    H.clockMin = H.clockMin + 7 * 60
    Q.track({}, StoryEngine.Sensor.now())
    H.eq(q.state, "declined")
    H.ok(q.lapsed, "closed quietly")
    H.eq(Tr().personal("ray", pa.key), 30, "no penalty")
end

function T.chat_trust_stops_at_40()
    local a, _, pa = setup(true)
    local R = StoryEngine.Radio
    ch("ray").personal = { [pa.key] = 39 }
    R.say(a, "ray", "hello")
    H.lastBridge("radio").callback({ ok = true, json = { reply = "Hi.", trust_change = 1 } })
    H.eq(Tr().personal("ray", pa.key), 40)
    H.advanceDays(1)
    R.lastSay = {}
    R.say(a, "ray", "hello again")
    H.lastBridge("radio").callback({ ok = true, json = { reply = "Hi.", trust_change = 1 } })
    H.eq(Tr().personal("ray", pa.key), 40, "talk alone stops at 40")
    H.eq(ch("ray").trust, 30, "talk never moves group trust in personal mode")
end

function T.trust_fades_only_on_days_the_player_was_on()
    local _, _, pa = setup(true)
    ch("hunter").personal = { [pa.key] = 55 }      -- hunter starts at 0: floor 20 (below 60: the old fade, not upkeep)
    local online = { [pa.key] = true }
    for day = 1, 13 do Tr().daily(day, online) end
    H.eq(ch("hunter").personal[pa.key], 55, "13 idle days: nothing yet")
    Tr().daily(14, online)
    H.eq(ch("hunter").personal[pa.key], 54, "day 14: -1")
    Tr().daily(15, {})
    Tr().daily(16, {})
    H.eq(ch("hunter").personal[pa.key], 54, "offline days do not count")
    Tr().daily(15, online)
    Tr().daily(16, online)
    Tr().daily(17, online)
    H.eq(ch("hunter").personal[pa.key], 53, "then every 3 online days")
    Tr().touch("hunter", pa.key)
    local today = StoryEngine.Store.dayIndex(StoryEngine.Sensor.now().dayKey)
    Tr().daily(today, online)
    H.eq(ch("hunter").personalIdle[pa.key], 0, "contact resets the count")
end

function T.switching_modes_moves_trust_sensibly()
    local _, _, pa, pb = setup(false)
    isServer = function() return true end
    ch("ray").trust = 50
    Tr().checkMode()
    SandboxVars.StoryEngine.TrustBenefits = 2
    Tr().checkMode()
    H.eq(ch("ray").personal[pa.key], 50, "existing characters keep what they had")
    ch("ray").personal[pa.key] = 80
    ch("ray").personal[pb.key] = 60
    ch("ray").trust = 40
    SandboxVars.StoryEngine.TrustBenefits = 1
    Tr().checkMode()
    H.eq(ch("ray").trust, 70, "back to shared: max(group, average personal)")
end

function T.one_open_trade_per_person()
    local a, b, pa, pb = setup(true)
    local d = StoryEngine.Store.data()
    d.quests.QT = { id = "QT", kind = "trade", state = "proposed", origin = { faction = "ray" }, target = pa.key }
    H.ok(StoryEngine.Quests.openTrade("ray", pa.key), "Alice has one")
    H.eq(StoryEngine.Quests.openTrade("ray", pb.key), nil, "Bob is free to trade")
    H.ok(StoryEngine.Quests.openTrade("ray"), "no key: any trade (old behaviour)")
    H.ok(a and b, "players")
end

function T.forget_and_reset()
    local _, _, pa = setup(true)
    Tr().ensure("ray", pa.key)
    Tr().forget(pa.key)
    H.eq(ch("ray").personal[pa.key], nil, "a dead character's record is dropped")
    Tr().ensure("doc", pa.key)
    Tr().resetPersonal("doc")
    H.eq(ch("doc").personal[pa.key], nil, "successor: everyone starts over")
end

-- 검토 수정 (2026-10-09)
function T.someone_elses_trade_cannot_be_taken()
    local a, b, pa = setup(true)
    local d = StoryEngine.Store.data()
    d.quests.QT = { id = "QT", kind = "trade", state = "proposed", origin = { faction = "ray" }, target = pa.key,
                    targetName = "Alice Ash", tier = 2 }
    local ok, why = StoryEngine.Quests.respond(b, "QT", true)
    H.eq(ok, false)
    H.eq(why, "not_yours")
    H.eq(d.quests.QT.target, pa.key, "still Alice's")
    H.ok(a ~= nil)
end

function T.bonus_is_not_multiplied_twice()
    local a, _, pa = setup(true)
    SandboxVars.StoryEngine.TrustGainMult = 2
    local q = storyAsk(a, pa, "doc", 3)
    StoryEngine.Quests.addHelper(q, pa)
    local before = Tr().personal("doc", pa.key)
    local group = ch("doc").trust
    StoryEngine.Quests.setState(q, "completed", StoryEngine.Sensor.now(), { ps = pa })
    H.eq(ch("doc").trust, group + 6, "group +3 x 2")
    H.eq(Tr().personal("doc", pa.key), before + 3, "bonus = 6 x 0.5, not doubled again")
end

function T.dead_helpers_get_nothing()
    local a, _, pa, pb = setup(true)
    local q = storyAsk(a, pa, "doc", 2)
    StoryEngine.Quests.addHelper(q, pb)
    pb.dead = true
    Tr().forget(pb.key)
    StoryEngine.Quests.setState(q, "completed", StoryEngine.Sensor.now(), { ps = pa })
    H.eq(Tr().known("doc", pb.key), false, "a dead character's record is not revived")
end

function T.emergency_requests_still_come_in_personal_mode()
    local _, _, pa = setup(true)
    local ev = StoryEngine.Director.events.npc_emergency
    H.ok(ev.eligible({}, { ps = pa }), "eligible in personal mode")
    H.ok(not StoryEngine.Director.events.npc_request.eligible({}, { ps = pa }), "general requests go to personal asks")
end

function T.button_requests_count_as_contact()
    local a, _, pa = setup(true)
    H.eq(Tr().known("ray", pa.key), false)
    pcall(StoryEngine.Trade.ask, a, "ray", "food", 1)
    H.ok(Tr().known("ray", pa.key), "asking with the button is first contact")
end

function T.personal_asks_only_in_personal_mode()
    local a, _, pa = setup(false)
    local q, why = StoryEngine.Director.personalAsk(a, pa, StoryEngine.Sensor.now(), true, "deliver")
    H.eq(q, nil)
    H.eq(why, "not_personal")
end

-- 빚은 사람마다 (2026-10-09): 남의 빚이 내 빚을 막지 않고, 독촉은 빚진 사람 앞으로만, 떼먹은 감점도 그 사람에게
function T.debts_are_per_person()
    local a, b, pa, pb = setup(true)
    local W, ray = StoryEngine.Work, ch("ray")
    ray.personal = { [pa.key] = 60, [pb.key] = 60 }
    ray.favorOwedBy = { [pa.key] = { qid = "Q0", key = pa.key, name = pa.name, sinceT = -5000, tier = 1 } }
    H.ok(W.owed("ray", pa.key), "Alice owes Ray")
    H.eq(W.owed("ray", pb.key), nil, "Bob owes nothing")
    local ok, why = W.check("ray", "favor", nil, pb.key)
    H.ok(ok, "Alice's debt does not block Bob: " .. tostring(why))
    local okA, whyA = W.check("ray", "favor", nil, pa.key)
    H.eq(okA, false)
    H.eq(whyA, "owed")
    -- 독촉: 빚진 앨리스 앞으로
    W.callFavors(StoryEngine.Sensor.now())
    local call
    for _, q in pairs(StoryEngine.Store.data().quests) do if q.favorCall then call = q end end
    H.ok(call and call.addressed == pa.key and call.favorKey == pa.key, "the call is addressed to Alice")
    local okB, whyB = StoryEngine.Quests.respond(b, call.id, true)
    H.eq(okB, false)
    H.eq(whyB, "not_addressed", "Bob cannot answer Alice's debt")
    local bBefore = Tr().personal("ray", pb.key)
    H.ok(StoryEngine.Quests.respond(a, call.id, false))
    H.ok(Tr().personal("ray", pa.key) <= 30, "Alice broke the favor: big loss")
    H.eq(Tr().personal("ray", pb.key), bBefore, "Bob untouched")
    H.eq(W.owed("ray", pa.key), nil, "settled")
end

function T.debt_call_waits_for_the_debtor()
    local _, b, pa = setup(true)
    local W, ray = StoryEngine.Work, ch("ray")
    ray.favorOwedBy = { [pa.key] = { qid = "Q0", key = pa.key, name = pa.name, sinceT = -5000, tier = 1 } }
    for i, p in ipairs(H.players) do if StoryEngine.Store.playerKey(p) == pa.key then table.remove(H.players, i) end end
    W.callFavors(StoryEngine.Sensor.now())
    for _, q in pairs(StoryEngine.Store.data().quests) do H.ok(not q.favorCall, "no call to someone else while Alice is away") end
    H.ok(b ~= nil)
end

return T
