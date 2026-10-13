-- 조사 틀을 쓰는 정치 위기 (Inquiry.lua): 단서 여섯, 거짓 증언, 판결, 유도신문
local T = {}

local function now() return StoryEngine.Sensor.now() end
local function P() return StoryEngine.Politics end
local function C() return StoryEngine.Crises end
local function I() return StoryEngine.Inquiry end
local function trust(fid) return StoryEngine.Radio.channel(fid).trust end
local function setTrust(fid, v) StoryEngine.Radio.channel(fid).trust = v end
local function trustAll(v)
    for _, f in ipairs(StoryEngine.Factions.list) do setTrust(f.id, v) end
end
local function res(fid, r) return StoryEngine.Life.npc(fid).res[r] end

local function mockBuildings()
    local defs = {}
    for _, d in ipairs({ 120, 160, 300, 380 }) do
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

local function quiet()
    P().state().bill = nil
    P().state().nextBillT = now().t + 999 * 1440
    P().state().nextElectionT = now().t + 999 * 1440
    C().state().nextT = now().t + 999 * 1440
end

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    H.clockMin = 300 * 1440 + 8 * 60
    StoryEngine.Council.state().era = { day = 300, t = now().t }
    P().debug({ open = true })
    quiet()
    mockBuildings()
    trustAll(50)
    return p, ps
end

local function open(kind)
    H.ok(C().start(kind), "the inquiry opens: " .. kind)
    local cur = C().state().current
    return cur, cur.case
end

-- 현장·물증 자리에 다녀온다
local function visit(case, n, ps)
    local q = StoryEngine.Store.data().quests[case.clues[n].qid]
    H.ok(q, "a place to go for clue " .. tostring(n))
    StoryEngine.Quests.setState(q, "completed", now(), { ps = ps })
end

function T.six_clues_and_a_lie()
    local p, ps = setup()
    local Inq, Quests = I(), StoryEngine.Quests
    local cur, case = open("warehouse")
    H.eq(#case.answers, 3)
    H.ok(case.truth ~= case.framed)
    H.eq(case.liar, case.truth, "the thief is the one who lies")
    H.eq(case.found, 0)
    for n = 1, 4 do
        local q = StoryEngine.Store.data().quests[case.clues[n].qid]
        H.eq(q.kind, "visit")
        H.ok(Quests.isManaged(q), "no trust or reward of its own")
    end
    H.eq(select(2, C().choose(p, "public")), "inquiry")
    H.eq(select(2, Inq.judge(p, case.truth, "public")), "few_clues")
    -- 현장 둘
    visit(case, 1, ps)
    visit(case, 2, ps)
    H.eq(case.found, 2)
    -- 증언: 신뢰가 낮으면 입을 열지 않는다
    local witness = case.clues[5].fid
    setTrust(witness, 30)
    H.eq(select(2, Inq.ask(p, witness)), "silent")
    setTrust(witness, 50)
    H.ok(Inq.ask(p, witness))
    H.eq(select(2, Inq.ask(p, witness)), "asked")
    H.eq(select(2, Inq.ask(p, "nobody")), "no_witness")
    -- 거짓 증언: 물증을 찾기 전에는 따질 수 없다
    H.ok(Inq.ask(p, case.liar))
    H.eq(case.found, 4)
    local pay = Inq.payload(cur, ps.key)
    H.ok(pay.canJudge)
    local lie
    for _, c in ipairs(pay.clues) do
        if c.fid == case.liar then lie = c end
    end
    H.eq(lie.points, case.framed, "the lie points at an innocent")
    H.eq(pay.truth, nil, "the client is never told the answer")
    H.eq(select(2, Inq.confront(p, case.liar)), "no_proof")
    visit(case, 3, ps)
    H.eq(p.items[#p.items].fullType, Inq.EVIDENCE, "evidence in hand")
    local state
    for _, w in ipairs(Inq.payload(cur, ps.key).words) do
        if w.fid == case.liar then state = w.state end
    end
    H.eq(state, "confront")
    local before = trust(case.liar)
    H.ok(Inq.confront(p, case.liar))
    H.eq(trust(case.liar), before - 2)
    H.eq(case.clues[6].points, case.truth, "now they tell it straight")
    H.eq(select(2, Inq.confront(p, case.liar)), "asked")
end

local function solve(case, ps, p)
    for n = 1, 4 do visit(case, n, ps) end
end

function T.the_stores_made_public_or_kept_between_two()
    local p, ps = setup()
    local Inq = I()
    local cur, case = open("warehouse")
    solve(case, ps, p)
    H.eq(select(2, Inq.judge(p, case.truth, "loudly")), "how")
    H.ok(Inq.judge(p, case.truth, "public"))
    H.eq(trust(case.truth), 35)
    for _, f in ipairs(StoryEngine.Factions.list) do
        if f.id ~= case.truth then H.eq(trust(f.id), 52, f.id) end
    end
    H.eq(C().state().current, nil)
    -- 당사자에게만: 큰 선물이 온다
    C().state().done.warehouse = nil
    trustAll(50)
    cur, case = open("warehouse")
    solve(case, ps, p)
    local items = #p.items
    H.ok(Inq.judge(p, case.truth, "private"))
    H.eq(trust(case.truth), 53)
    H.ok(#p.items > items, "a gift straight to hand")
end

function T.a_wrong_verdict_comes_out_a_month_later()
    local p, ps = setup()
    local Inq = I()
    local cur, case = open("warehouse")
    solve(case, ps, p)
    H.ok(Inq.judge(p, case.framed, "public"))
    H.eq(trust(case.framed), 40, "an innocent pays first")
    H.eq(trust(case.truth), 50)
    H.ok(C().state().fx.reveal)
    H.advanceDays(Inq.REVEAL_DAYS + 1)
    quiet()
    C().tick()
    H.eq(C().state().fx.reveal, nil)
    H.eq(trust(case.truth), 47, "then everyone remembers")
    H.eq(trust(case.framed), 32)
end

function T.covering_up_brings_leading_questions()
    local p, ps = setup()
    local Inq = I()
    local cur, case = open("warehouse")
    solve(case, ps, p)
    H.ok(Inq.judge(p, case.truth, "cover"))
    H.eq(trust(case.truth), 60)
    local probe = C().state().fx.probe
    H.ok(probe and #probe.askers >= 2)
    H.eq(Inq.answer(p, "safe"), false, "nobody has asked yet")
    H.advance(13 * 60)
    quiet()
    C().tick()
    H.ok(probe.open, "someone starts fishing")
    local asker = probe.open.fid
    H.ok(asker ~= case.truth)
    local b = H.lastBridge("radio")
    H.ok(not string.find(tostring(b.payload.topic or ""), StoryEngine.Stories.NAMES[case.truth], 1, true),
        "the one fishing is never given the name")
    -- 그 주파수에서 한 대답은 따로 판정에 부친다
    StoryEngine.Radio.say(p, asker, "I have no idea who it was.")
    local j = H.lastBridge("judge")
    H.ok(j, "the reply goes to the judge")
    H.eq(j.payload.culprit, StoryEngine.Stories.NAMES[case.truth])
    H.eq(#j.payload.suspects, 3)
    -- AI 없이 메뉴로: 모른다고 하면 아무 일도 없다
    probe.open.judging = nil
    H.ok(Inq.answer(p, "safe"))
    H.eq(probe.open, nil)
    H.eq(probe.hints, 0)
    -- 얼버무리면 한 번은 넘어가고 두 번이면 들킨다
    H.advance(Inq.PROBE_GAP_HOURS * 60)
    quiet()
    C().tick()
    H.ok(Inq.answer(p, "vague"))
    H.eq(probe.hints, 1)
    H.ok(C().state().fx.probe, "one hint is not enough")
    H.advance(Inq.PROBE_GAP_HOURS * 60)
    quiet()
    C().tick()
    trustAll(50)
    H.ok(Inq.answer(p, "vague"))
    H.eq(C().state().fx.probe, nil)
    H.eq(trust(case.truth), 35, "five like everyone, ten more for the one who was covered")
    H.eq(trust(asker), 45)
    local n = H.sentOf("inquiryNotice")
    H.eq(n[#n].kind, "exposed")
end

function T.staying_silent_or_lasting_the_week()
    local p, ps = setup()
    local Inq = I()
    local cur, case = open("warehouse")
    solve(case, ps, p)
    Inq.judge(p, case.truth, "cover")
    local probe = C().state().fx.probe
    H.advance(13 * 60)
    quiet()
    C().tick()
    local asker = probe.open.fid
    trustAll(50)
    H.advance(Inq.PROBE_ANSWER_HOURS * 60 + 60)
    quiet()
    C().tick()
    H.eq(trust(asker), 48, "no answer costs a little with the one who asked")
    H.advanceDays(Inq.PROBE_DAYS)
    quiet()
    C().tick()
    H.eq(C().state().fx.probe, nil, "after a week they let it lie")
    H.eq(trust(case.truth), 50)
end

function T.the_trial_weighs_three_stories()
    local p, ps = setup()
    local Inq = I()
    local cur, case = open("trial")
    H.ok(case.victim and case.accused and case.victim ~= case.accused)
    H.eq(Inq.payload(cur, ps.key).hows, nil)
    solve(case, ps, p)
    H.ok(Inq.judge(p, case.truth))
    H.eq(trust(case.victim), 52)
    H.eq(trust(case.accused), 52)
    -- 틀리면 억울한 쪽이 남는다
    C().state().done.trial = nil
    trustAll(50)
    cur, case = open("trial")
    case.truth = "defence"
    solve(case, ps, p)
    H.ok(Inq.judge(p, "murder"))
    H.eq(trust(case.accused), 40, "exile for a man who only defended himself")
    H.eq(trust(case.victim), 50)
    H.ok(C().state().fx.reveal)
end

function T.fouled_water_sickens_until_solved()
    local p, ps = setup()
    local Inq = I()
    local cur, case = open("water")
    case.truth = "sabotage"
    local before = res("ray", "medical")
    C().tick()
    H.advanceDays(1)
    quiet()
    C().tick()
    H.eq(res("ray", "medical"), math.max(0, before - Inq.SICK_DAILY), "every day it is unsolved")
    solve(case, ps, p)
    H.ok(Inq.judge(p, "sabotage"))
    H.eq(C().state().current, nil)
    H.ok(C().state().follow, "someone did this: a trial follows")
    H.advanceDays(3)
    quiet()
    C().state().nextT = now().t + 999 * 1440
    C().tick()
    H.eq(C().state().current.id, "trial")
    -- 틀리면 더 앓는다
    C().close(now(), "test")
    C().state().done.water = nil
    cur, case = open("water")
    case.truth = "carcass"
    solve(case, ps, p)
    H.ok(Inq.judge(p, "accident"))
    H.ok(C().state().fx.sick)
end

function T.the_pirate_broadcast()
    local p, ps = setup()
    local Inq, Out = I(), StoryEngine.Outsiders
    setTrust("hunter", 10)
    setTrust("rats", 20)
    local cur, case = open("pirate")
    H.ok(case.answers[1] == "hunter" and case.answers[2] == "rats", "the most aggrieved are the first suspects")
    case.truth = "hunter"
    solve(case, ps, p)
    H.ok(Inq.judge(p, "hunter"))
    H.eq(trust("hunter"), 13, "heard out at last")
    local asked
    for _, q in pairs(StoryEngine.Store.data().quests) do
        if q.origin and q.origin.faction == "hunter" and q.state == "proposed" then asked = q end
    end
    H.ok(asked, "and the grievance becomes a favour to do")
    -- 밖에서 온 사람이었다면 추방 표결
    Out.debug({ what = "arrive", id = "hale" })
    Out.state().here.hale.testT = now().t + 999 * 1440
    C().state().done.pirate = nil
    cur, case = open("pirate")
    H.eq(case.answers[3], "hale")
    case.truth = "hale"
    solve(case, ps, p)
    H.ok(Inq.judge(p, "hale"))
    H.eq(P().state().bill.id, "expel")
    H.eq(P().state().bill.target, "hale")
end

function T.an_inquiry_nobody_finishes()
    local p, ps = setup()
    local Inq = I()
    local cur, case = open("trial")
    visit(case, 1, ps)
    H.advanceDays(Inq.DAYS + 1)
    quiet()
    C().state().nextT = nil
    C().tick()
    H.eq(C().state().current, nil)
    H.eq(trust(case.victim), 45)
    H.eq(trust(case.accused), 45)
    local q = StoryEngine.Store.data().quests[case.clues[2].qid]
    H.ok(not StoryEngine.Quests.isActive(q), "the places to check are closed")
end

return T
