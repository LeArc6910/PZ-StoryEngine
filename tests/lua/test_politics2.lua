-- 의회의 정치, 나머지 (Politics.lua·Offices.lua): 파벌 옮김, 압박·몰아세움, 약점, 표 부탁, 자리 셋, 선별 방어, 밀려난 NPC
local T = {}

local function now() return StoryEngine.Sensor.now() end
local function P() return StoryEngine.Politics end
local function O() return StoryEngine.Offices end
local function trust(fid) return StoryEngine.Radio.channel(fid).trust end
local function setTrust(fid, v) StoryEngine.Radio.channel(fid).trust = v end
local function trustAll(v)
    for _, f in ipairs(StoryEngine.Factions.list) do setTrust(f.id, v) end
end
local function res(fid, r) return StoryEngine.Life.npc(fid).res[r] end

local function quiet()
    local s = P().state()
    s.bill = nil
    s.nextBillT = now().t + 999 * 1440
    s.nextElectionT = now().t + 999 * 1440
    s.nextPhaseT = now().t + 999 * 1440
    if StoryEngine.Crises then StoryEngine.Crises.state().nextT = now().t + 999 * 1440 end
    if StoryEngine.Outsiders then StoryEngine.Outsiders.state().nextT = now().t + 999 * 1440 end
end

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    H.clockMin = 300 * 1440 + 8 * 60
    StoryEngine.Council.state().era = { day = 300, t = now().t }
    P().debug({ open = true })
    quiet()
    trustAll(50)
    return p, ps
end

local function sumTrust()
    local n = 0
    for _, f in ipairs(StoryEngine.Factions.list) do n = n + trust(f.id) end
    return n
end

function T.someone_who_falls_out_with_their_camp_changes_sides()
    setup()
    local Pol, Bonds = P(), StoryEngine.Bonds
    local function set(a, b, v)
        local guard = 0
        while Bonds.get(a, b) ~= v and guard < 10 do
            Bonds.change(a, b, Bonds.get(a, b) < v and 1 or -1, "test")
            guard = guard + 1
        end
    end
    H.eq(Pol.blocOf("doc"), "field")
    -- 닥이 밭 사람들과 틀어지고 총 사람들과 가까워진다
    set("doc", "ray", -1)
    set("doc", "pike", -1)
    set("doc", "guard", 1)
    set("doc", "hunter", 1)
    -- 다른 사람들은 제자리에 있게
    Pol.state().moved = {}
    for _, f in ipairs(StoryEngine.Factions.list) do
        if f.id ~= "doc" then Pol.state().moved[f.id] = now().t end
    end
    H.eq(Pol.moveBlocs(now()), "doc")
    H.eq(Pol.blocOf("doc"), "gun")
    local moved = false
    for _, n in ipairs(H.sentOf("politicsNotice")) do
        if n.kind == "moved" and n.fid == "doc" and n.to == "gun" then moved = true end
    end
    H.ok(moved)
    H.eq(Pol.summary().moved[1].fid, "doc")
    -- 60일에 한 번까지
    set("doc", "guard", -1)
    set("doc", "hunter", -1)
    set("doc", "ray", 1)
    set("doc", "pike", 1)
    H.eq(Pol.moveBlocs(now()), nil, "not twice in two months")
    H.advanceDays(Pol.MOVE_DAYS + 1)
    for _, f in ipairs(StoryEngine.Factions.list) do
        if f.id ~= "doc" then Pol.state().moved[f.id] = now().t end
    end
    H.eq(Pol.moveBlocs(now()), "doc")
    H.eq(Pol.blocOf("doc"), "field")
    H.eq(Pol.summary().moved[1], nil, "back home is not a move worth telling")
end

function T.pressing_with_a_secret_and_calling_out_a_signature()
    local p, ps = setup()
    local Pol = P()
    Pol.debug({ bill = "canteen" })
    local bill = Pol.state().bill
    H.eq(bill.id, "canteen")
    -- 압박: 약점이 없으면 안 된다
    H.eq(select(2, Pol.lobby(p, "guard", "press", "for")), "no_secret")
    H.ok(Pol.learnSecret("guard", "tip", "ray"))
    H.ok(not Pol.learnSecret("guard", "tip", "ray"), "one secret per person")
    H.eq(Pol.payload(ps.key).secrets[1], "guard")
    H.ok(Pol.lobby(p, "guard", "press", "for"))
    H.eq(bill.pledged.guard, true)
    H.eq(trust("guard"), 50 - Pol.PRESS_COST)
    H.eq(Pol.secretOf("guard"), nil, "a secret is spent once used")
    H.eq(#Pol.payload(ps.key).secrets, 0)
    -- 몰아세움: 공동 식당은 "나눔"을 받든다. 레이는 나눔에 서명했다
    H.eq(Pol.pledgeOf("ray"), "share")
    setTrust("ray", 10)
    H.ok(Pol.callable(bill, "ray", "for"), "he signed for sharing and is voting against a common kitchen")
    H.ok(not Pol.callable(bill, "pike", "for"), "Pike signed for something else")
    H.eq(Pol.payload(ps.key).bill.calls.ray, "for")
    local need = Pol.need(bill, "ray")
    local morale = res("ray", "morale")
    H.ok(Pol.lobby(p, "ray", "call", "for"))
    H.eq(Pol.need(bill, "ray"), need - Pol.CALL_NUDGE)
    H.eq(res("ray", "morale"), math.max(0, morale - Pol.CALL_MORALE))
    H.eq(select(2, Pol.lobby(p, "pike", "call", "for")), "no_pledge")
    -- 해치는 쪽: 공동 식당은 "장사"를 해친다. 빅이 찬성하고 있으면 반대하라고 몰아세울 수 있다
    setTrust("rats", 95)
    H.ok(Pol.callable(bill, "rats", "against"))
    setTrust("rats", 10)
    H.ok(not Pol.callable(bill, "rats", "against"), "already voting no")
end

function T.a_trusting_contact_tips_you_off()
    setup()
    local Pol, Bonds = P(), StoryEngine.Bonds
    -- 모두 사이가 나쁘지 않게 해 두고 방위대만 빅을 싫어하게
    for _, a in ipairs(StoryEngine.Factions.list) do
        for _, b in ipairs(StoryEngine.Factions.list) do
            local guard = 0
            while a.id ~= b.id and Bonds.get(a.id, b.id) < 0 and guard < 10 do
                Bonds.change(a.id, b.id, 1, "test")
                guard = guard + 1
            end
        end
    end
    Bonds.change("guard", "rats", -1, "test")
    H.eq(Pol.tip(now(), true), nil, "nobody trusts us that much")
    setTrust("guard", 85)
    H.eq(Pol.tip(now(), true), "rats")
    H.eq(Pol.secretOf("rats").by, "guard")
    H.ok(H.lastBridge("radio"), "the tipper says so on the radio")
    H.eq(Pol.tip(now(), true), nil, "nothing more to tell")
end

function T.the_other_side_asks_for_help_against_a_bill()
    local p = setup()
    local Pol = P()
    Pol.debug({ bill = "canteen" })
    local bill = Pol.state().bill
    Pol.plea(now())
    H.eq(bill.pleaAsked, nil, "not on the first day")
    H.advanceDays(1)
    local tries = 0
    while not bill.plea and tries < 40 do
        bill.pleaAsked = nil
        Pol.plea(now())
        tries = tries + 1
    end
    H.eq(bill.plea, "rats", "the first of those it would cost")
    H.eq(Pol.payload("tester").bill.plea, "rats")
    setTrust("ray", 70)
    H.ok(Pol.lobby(p, "ray", "persuade", "against"))
    local before = trust("rats")
    Pol.vote(now())
    H.eq(trust("rats"), before + Pol.PLEA_GAIN)
end

function T.three_posts_are_filled_in_turn()
    local p, ps = setup()
    local Pol, Off = P(), O()
    Off.tick(now())
    H.eq(Pol.payload(ps.key).offices.vote, nil, "nothing for two weeks")
    H.eq(Pol.payload(ps.key).offices.list[1].voteIn, Off.FIRST_DAYS.store)
    H.advanceDays(Off.FIRST_DAYS.store)
    quiet()
    setTrust("rats", 80)
    setTrust("ray", 70)
    Off.tick(now())
    local v = Pol.state().offices.vote
    H.eq(v.office, "store")
    H.eq(v.cands.market, "rats")
    H.eq(v.cands.field, "ray")
    H.eq(select(2, Off.back(p, "nobody")), "no_target")
    H.ok(Off.back(p, "field"))
    H.eq(Pol.lean("field"), Off.BACK_LEAN)
    H.eq(select(2, Off.back(p, "market")), "backed")
    H.advanceDays(Off.VOTE_DAYS)
    quiet()
    Off.tick(now())
    local h = Off.holder("store")
    H.ok(h, "someone holds the stores now")
    H.ok(Off.busy(h.fid))
    H.eq(Pol.payload(ps.key).offices.list[1].fid, h.fid)
    -- 창고지기가 우리를 미워하면 모든 값이 오른다
    setTrust(h.fid, 20)
    H.eq(Off.mood("store"), "cold")
    H.near(Pol.mod("price", "doc", "medical"), Off.STORE_PRICE, 0.001)
    setTrust(h.fid, 50)
    H.eq(Pol.mod("price", "doc", "medical"), 1)
    -- 경비대장
    Pol.state().offices.vote = nil
    Pol.state().offices.held.captain = { fid = "hunter", bloc = "gun", sinceT = now().t, untilT = now().t + 60 * 1440 }
    setTrust("hunter", 70)
    H.eq(Pol.mod("specWait", "guard"), Off.CAPTAIN_WARM)
    H.eq(Pol.mod("specWait", "ray"), 1)
    setTrust("hunter", 10)
    H.eq(Pol.mod("specWait", "guard"), Off.CAPTAIN_COLD)
    -- 자리를 가진 사람은 다른 자리의 후보가 되지 않는다
    Pol.state().offices.nextT.captain = now().t + 999 * 1440
    Pol.state().offices.nextT.air = now().t
    Off.tick(now())
    local v2 = Pol.state().offices.vote
    H.eq(v2.office, "air")
    for _, b in ipairs(Pol.BLOCS) do
        H.ok(v2.cands[b] ~= h.fid and v2.cands[b] ~= "hunter", "one post each")
    end
    -- 떠나면 자리가 빈다
    Pol.state().offices.vote = nil
    StoryEngine.Fate.apply("hunter", "gone", "debug")
    Off.tick(now())
    H.eq(Off.holder("captain"), nil)
    H.eq(Pol.mod("specWait", "guard"), 1)
end

function T.the_broadcaster_speaks_for_or_against_us()
    setup()
    local Pol, Off = P(), O()
    Off.payload("tester")
    Pol.state().offices.held.air = { fid = "casey", bloc = "market", sinceT = now().t, untilT = now().t + 60 * 1440 }
    setTrust("casey", 70)
    StoryEngine.Store.data().broadcast = { lastDay = "1993-07-20" }
    local sum = sumTrust()
    Off.daily(now())
    H.eq(sumTrust(), sum + 1, "one of them thinks a little better of us")
    Off.daily(now())
    H.eq(sumTrust(), sum + 1, "once per broadcast")
    setTrust("casey", 10)
    local cold = sumTrust()
    StoryEngine.Store.data().broadcast.lastDay = "1993-07-21"
    Off.daily(now())
    H.eq(sumTrust(), cold - 1, "and a hostile voice costs one")
end

function T.only_the_camp_you_dealt_with_helps_and_guards_its_own()
    local p = setup()
    local Pol, Spec = P(), StoryEngine.Specialty
    H.ok(Pol.willHelp("guard"), "no trouble: everyone helps as before")
    H.ok(not Pol.shielded("guard"))
    Pol.onSaga("start", { id = "SG1", kind = "migration" })
    H.ok(not Pol.willHelp("guard"), "until we choose, nobody moves")
    H.eq(select(2, Spec.assist("guard", p)), "politics")
    H.ok(Pol.deal(p, "gun"))
    H.ok(Pol.willHelp("guard") and Pol.willHelp("hunter"))
    H.ok(not Pol.willHelp("ray"))
    H.ok(Pol.shielded("hunter") and not Pol.shielded("pike"))
    Pol.onSaga("done", { id = "SG1", kind = "migration", result = "held" })
    H.ok(Pol.willHelp("ray"))
end

function T.the_sidelined_leave_if_nothing_changes()
    setup()
    local Pol = P()
    local s = Pol.state()
    s.chair = { fid = "ray", bloc = "field", untilT = now().t + 200 * 1440 }
    s.credit = { field = 2 }
    setTrust("hunter", 20)
    Pol.judgePhase(now())
    H.eq(Pol.phase().kind, "rule")
    H.eq(Pol.phase().cold[1], "hunter")
    H.eq(Pol.payload("tester").phase.cold[1], "hunter")
    H.ok(not StoryEngine.Factions.isGone("hunter"), "one phase is a warning")
    -- 다시 믿게 되면 남는다
    setTrust("hunter", 40)
    setTrust("guard", 20)
    H.advanceDays(Pol.PHASE_DAYS)
    Pol.judgePhase(now())
    H.ok(not StoryEngine.Factions.isGone("hunter"))
    H.ok(not StoryEngine.Factions.isGone("guard"), "newly cold: warned, not gone")
    H.advanceDays(Pol.PHASE_DAYS)
    Pol.judgePhase(now())
    H.ok(StoryEngine.Factions.isGone("guard"), "two phases pushed aside and cold")
    local sum = Pol.summary()
    H.eq(sum.phase.bloc, "field")
    H.eq(sum.chair.fid, "ray")
end

local function mockBuildings()
    ArrayList = { new = function() return H.list({}) end }
    local grid = {}
    function grid:getBuildingsIntersecting() end
    function grid:getBuildingAt() return nil end
    local world = {}
    function world:getMetaGrid() return grid end
    getWorld = function() return world end
end

function T.the_transformer_needs_someone_at_the_substation()
    local p, ps = setup()
    mockBuildings()
    local Cr = StoryEngine.Crises
    StoryEngine.Grid.isRestored = function() return true end
    StoryEngine.Grid.cut = function() return true end
    StoryEngine.Grid.restore = function() return true end
    H.ok(Cr.start("transformer"))
    local cur = Cr.state().current
    StoryEngine.Store.data().quests[cur.collect].state = "completed"
    Cr.state().nextT = nil
    Cr.tick()
    H.ok(Cr.state().current, "parts alone do not finish it")
    local site = StoryEngine.Store.data().quests[cur.site]
    H.ok(site, "a place to stand guard")
    H.eq(site.kind, "defend")
    H.eq(site.needMin, Cr.TRANSFORMER_REPAIR_MIN)
    H.ok(StoryEngine.Quests.isManaged(site))
    H.eq(Cr.payload("tester").current.site, site.id)
    local best, bestD = nil, nil
    for _, s in ipairs(StoryEngine.OpsSites.SUBSTATIONS) do
        local d = (s.x - p:getX()) ^ 2 + (s.y - p:getY()) ^ 2
        if not bestD or d < bestD then best, bestD = s, d end
    end
    H.eq(site.cx, best.x, "the nearest substation")
    -- 수리 시간을 채우면 끝난다
    StoryEngine.Quests.setState(site, "completed", now(), { ps = ps })
    Cr.tick()
    H.eq(Cr.state().current, nil)
    H.eq(Cr.state().fx.night, nil)
    -- 변전소를 지키지 못하면 밤에만 전기
    Cr.state().done.transformer = nil
    Cr.start("transformer")
    cur = Cr.state().current
    StoryEngine.Store.data().quests[cur.collect].state = "completed"
    Cr.state().nextT = nil
    Cr.tick()
    H.advanceDays(Cr.TRANSFORMER_SITE_DAYS + 1)
    quiet()
    Cr.state().nextT = nil
    Cr.tick()
    H.ok(Cr.state().fx.night, "nobody held the substation")
    H.ok(not StoryEngine.Quests.isActive(StoryEngine.Store.data().quests[cur.site]))
end

function T.a_year_on_a_second_chronicle_is_written()
    local p, ps = setup()
    local Era, Pol, Out = StoryEngine.Era, P(), StoryEngine.Outsiders
    H.eq(Era.secondChronicle(now()), nil, "not before a year has passed")
    Out.debug({ what = "arrive", id = "odell" })
    Out.state().left.hale = { day = 320, why = "expelled" }
    local s = Pol.state()
    s.history[#s.history + 1] = { id = "post", bloc = "market", pass = true, day = 310 }
    s.history[#s.history + 1] = { id = "canteen", bloc = "field", pass = false, day = 330 }
    StoryEngine.Crises.state().done.quarantine = 320
    StoryEngine.Crises.state().done.ration_1993 = 340
    StoryEngine.Council.state().era.day = StoryEngine.Store.serverDays() - Era.CHRONICLE2_DAYS
    local ep = Era.secondChronicle(now())
    H.ok(ep, "one year after the council formed")
    H.eq(Era.secondChronicle(now()), nil, "only once")
    local b = H.lastBridge("epilogue")
    H.eq(b.payload.chapter, 2)
    local pol = b.payload.politics
    H.eq(pol.passed[1], "post")
    H.eq(pol.passedText[1], Pol.TEXT.post)
    H.eq(pol.failed, 1)
    H.eq(pol.camps.ray, "field")
    local seen = {}
    for _, o in ipairs(pol.outsiders) do seen[o.id] = o.state end
    H.eq(seen.odell, "here")
    H.eq(seen.hale, "expelled")
    H.eq(#pol.crises, 2)
    H.eq(pol.crises[1], "ration")
    -- 일지 탭: 두 번째 줄이 맨 위에
    StoryEngine.Council.state().epilogue = { status = "ready", result = "formed", date = "1993-07-01", day = 300 }
    local authors = StoryEngine.Journal.authors(ps.key)
    H.ok(authors[1].second, "the second chronicle sits on top")
    H.ok(authors[2].epilogue and not authors[2].second)
    local second = Era.epilogueFor(true)
    H.ok(second.second)
    H.eq(second.politics.failed, 1)
    H.ok(not Era.epilogueFor().second)
    Era.reset()
    H.eq(Era.epilogueFor(true), nil)
end

function T.outsiders_appear_among_the_people()
    setup()
    local Out = StoryEngine.Outsiders
    local function has(id)
        for _, row in ipairs(StoryEngine.Chronicle.payload()) do
            if row.id == id then return row end
        end
        return nil
    end
    H.eq(has("okafor"), nil)
    Out.debug({ what = "arrive", id = "okafor" })
    local row = has("okafor")
    H.ok(row and row.outsider)
    H.eq(row.trust, Out.START_TRUST)
    for _, kind in ipairs({ "reward_trade", "trade_failed", "reward_waived", "favor_call" }) do
        H.ok(string.find(StoryEngine.Lines.lt("okafor", kind, {}).key, "IGUI_StoryEngine_Line_okafor_" .. kind .. "_", 1, true) == 1)
    end
end

function T.rivals_set_conditions_that_cannot_both_be_met()
    local p, ps = setup()
    local Pol, Quests, Bonds = P(), StoryEngine.Quests, StoryEngine.Bonds
    local quests = StoryEngine.Store.data().quests
    trustAll(75)
    setTrust("guard", 60)
    setTrust("rats", 60)
    H.ok(Bonds.get("rats", "guard") < 0, "they start out as enemies")
    Pol.debug({ election = true })
    H.ok(Pol.run(p))
    local e = Pol.state().election
    H.ok(e.player.asks.guard and e.player.asks.rats)
    Quests.setState(quests[e.player.asks.guard], "completed", now(), { ps = ps })
    H.eq(e.player.votes.guard, true)
    H.eq(e.player.spurned.rats, "guard", "doing the Guard a favour costs Vic's")
    H.eq(Pol.payload(ps.key).election.spurned.rats, "guard")
    -- 빅의 부탁을 들어줘도 이제 표는 오지 않고, 방위대의 표는 그대로다
    Quests.setState(quests[e.player.asks.rats], "completed", now(), { ps = ps })
    H.ok(not e.player.votes.rats)
    H.eq(e.player.votes.guard, true)
    H.eq(Pol.electionForecast(e).player.got, 7)
    setTrust("rats", 70)
    H.eq(Pol.electionForecast(e).player.got, 8, "only trust wins him now")
    -- AI 가 없을 때의 표결 화제
    H.ok(string.find(StoryEngine.Lines.lt("guard", "topic_politics", {}).key, "IGUI_StoryEngine_Line_guard_topic_politics_", 1, true) == 1)
    H.ok(StoryEngine.Social.OFFLINE_TOPICS.politics)
end

return T
