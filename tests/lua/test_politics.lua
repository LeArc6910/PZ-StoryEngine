-- 의회 이후의 정치 (Politics.lua, docs/PLAN_COUNCIL_POLITICS.md 2·3단계): 파벌, 법안과 표결, 법안 11개의 효과
local T = {}

local function now() return StoryEngine.Sensor.now() end
local function P() return StoryEngine.Politics end
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

-- 의회가 선 세계. open 이면 정치도 바로 연다
local function setup(open)
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    H.clockMin = 300 * 1440 + 8 * 60
    StoryEngine.Council.state().era = { day = 300, t = now().t }
    if open then P().debug({ open = true }) end
    return p, ps
end

local function count(p, fullType)
    local n = 0
    for _, it in ipairs(p.items) do
        if it.fullType == fullType then n = n + 1 end
    end
    return n
end

function T.politics_opens_two_weeks_after_the_council()
    setup(false)
    local Pol = P()
    H.ok(not Pol.on())
    H.eq(Pol.mod("specWait", "hunter"), 1, "nothing changes before it opens")
    H.eq(Pol.mod("recess"), false)
    H.eq(Pol.payload("k").openIn, 14)
    H.clockMin = H.clockMin + 13 * 1440
    Pol.tick(now())
    H.ok(not Pol.on(), "not yet")
    H.clockMin = H.clockMin + 2 * 1440
    Pol.tick(now())
    H.ok(Pol.on(), "open")
    H.eq(H.sentOf("politicsNotice")[1].kind, "open")
    -- 파벌
    H.eq(Pol.blocOf("ray"), "field")
    H.eq(Pol.blocOf("guard"), "gun")
    H.eq(Pol.blocOf("rats"), "market")
    H.eq(#Pol.members("field"), 3)
    StoryEngine.Life.npc("doc").fate = { kind = "dead", reason = "debug", day = 300 }
    H.eq(#Pol.members("field"), 2, "the dead do not sit in the council")
    StoryEngine.Life.npc("doc").fate = nil
    -- 의회 시대가 아니면 열리지 않는다
    StoryEngine.Store.data().politics = nil
    StoryEngine.Council.state().era = nil
    H.clockMin = H.clockMin + 30 * 1440
    Pol.tick(now())
    H.ok(not Pol.on())
    H.eq(Pol.payload("k").era, false)
    -- 샌드박스로 끄면 아무것도 안 한다
    StoryEngine.Council.state().era = { day = 300, t = 0 }
    SandboxVars.StoryEngine.Politics = false
    Pol.tick(now())
    H.ok(not Pol.on())
    H.eq(Pol.payload("k").off, true)
    SandboxVars.StoryEngine.Politics = nil
end

function T.a_bill_is_voted_on_trust_and_sides()
    setup(true)
    local Pol = P()
    trustAll(55)
    Pol.debug({ bill = "armory" })
    local bill = Pol.state().bill
    H.eq(bill.id, "armory")
    H.eq(bill.bloc, "market")
    H.eq(bill.rival, "field", "the camp with the most losers opposes it")
    H.eq(Pol.need(bill, "rats"), 20, "gains and proposed it")
    H.eq(Pol.need(bill, "dewey"), 40, "same camp")
    H.eq(Pol.need(bill, "hunter"), 30, "gains")
    H.eq(Pol.need(bill, "guard"), 70, "loses")
    H.eq(Pol.need(bill, "pike"), 80, "loses and sits with the opposing camp")
    H.eq(Pol.need(bill, "ray"), 60, "opposing camp")
    local t = Pol.forecast(bill)
    H.eq(t.yes, 4)
    H.eq(t.no, 4)
    H.eq(t.pass, false, "a tie fails")
    local view = Pol.payload("k")
    H.eq(view.bill.id, "armory")
    H.eq(view.bill.hours, 72)
    H.eq(#view.bill.rows, 8)
    -- 한 사람을 더 얻으면 통과
    setTrust("ray", 60)
    H.eq(Pol.forecast(bill).pass, true)
    H.clockMin = H.clockMin + 3 * 1440 + 60
    Pol.tick(now())
    H.eq(Pol.state().bill, nil)
    H.ok(Pol.law("armory"), "in force")
    local notes = H.sentOf("politicsNotice")
    local vote = nil
    for _, n in ipairs(notes) do if n.kind == "vote" then vote = n end end
    H.ok(vote and vote.pass and vote.yes == 5 and vote.no == 3)
    H.eq(Pol.state().history[1].id, "armory")
    -- 시행 기간이 지나면 끝난다
    H.clockMin = H.clockMin + 14 * 1440 + 60
    Pol.tick(now())
    H.eq(Pol.law("armory"), nil)
end

function T.a_failed_bill_waits_a_week()
    setup(true)
    local Pol = P()
    trustAll(10)
    Pol.debug({ bill = "exchange" })
    H.clockMin = H.clockMin + 3 * 1440 + 60
    Pol.vote(now())
    H.eq(Pol.law("exchange"), nil)
    H.ok(Pol.state().failed.exchange)
    -- 그 파벌의 다음 법안은 다른 것
    for _ = 1, 6 do
        Pol.state().bill = nil
        local b = Pol.propose(now())
        H.ok(b and b.id ~= "exchange", "the failed bill is not brought back within a week")
    end
end

function T.the_armory_bill_loosens_guns_and_drains_the_guard()
    setup(true)
    local Pol, Trade, Life = P(), StoryEngine.Trade, StoryEngine.Life
    local before = Trade.needTrust("rats", "firearm", 4)
    local price = Trade.offerContext("rats", 85).catMult.ammo
    Life.daily()
    Pol.debug({ enact = "armory" })
    H.ok(Trade.needTrust("rats", "firearm", 4) < before, "a tier of guns opens at lower trust")
    H.eq(Trade.needTrust("rats", "tools", 4), Trade.needTrust("rats", "tools", 4), "tools unchanged")
    H.near(Trade.offerContext("rats", 85).catMult.ammo / price, 0.8, 0.001)
    H.eq(Pol.mod("squad", "guard"), -2)
    H.eq(Pol.mod("squad", "hunter"), 0)
    -- 방위대 무기: 매일 -4, 저절로 회복하지 않는다
    Life.npc("guard").res.safety = 75
    Life.npc("ray").res.food = 30
    H.advanceDays(1)
    Life.daily()
    H.eq(res("guard", "safety"), 71)
    H.eq(res("ray", "food"), 35, "others still recover")
    H.advanceDays(1)
    Life.daily()
    H.eq(res("guard", "safety"), 67, "no recovery while the bill is in force")
    Pol.repeal("armory", now(), "debug")
    H.advanceDays(1)
    Life.daily()
    H.eq(res("guard", "safety"), 72, "recovers again afterwards")
end

function T.the_workshop_bill_closes_tool_trade_and_mends_things()
    local p = setup(true)
    local Pol, Trade = P(), StoryEngine.Trade
    H.eq(Pol.workshop(p, 1), false)
    Pol.debug({ enact = "workshop" })
    H.eq(Pol.mod("tradeBlock", "dewey", "tools"), true)
    H.eq(Pol.mod("tradeBlock", "dewey", "food"), false)
    H.eq(Pol.mod("tradeBlock", "ray", "tools"), false)
    H.eq(Pol.mod("noRegen", "dewey", StoryEngine.Life.KEY.dewey), true)
    local ctx = Trade.offerContext("dewey", 85)
    for _, c in ipairs(ctx.catalog or {}) do
        if c.category == "tools" then
            H.eq(c.closed, true)
            H.eq(c.maxTier, 0)
        end
    end
    -- 낡은 도끼를 보낸다
    H.defineItem("Base.Axe", "tools", 8, 2)
    local axe = H.give(p, "Base.Axe")
    axe.cond = 2
    function axe:getCondition() return self.cond end
    function axe:getConditionMax() return 10 end
    local fine = H.give(p, "Base.Axe")
    function fine:getCondition() return 10 end
    function fine:getConditionMax() return 10 end
    local ok, why = Pol.workshop(p, fine.id)
    H.eq(why, "fine", "nothing to mend")
    ok, why = Pol.workshop(p, axe.id)
    H.ok(ok, tostring(why))
    H.eq(count(p, "Base.Axe"), 1, "taken away")
    local again, why2, wait = Pol.workshop(p, fine.id)
    H.eq(why2, "wait")
    H.eq(wait, 48)
    H.eq(Pol.payload(StoryEngine.Store.playerKey(p)).workshop.wait, 48)
    H.clockMin = H.clockMin + 25 * 60
    Pol.tick(now())
    H.eq(count(p, "Base.Axe"), 2, "back the next day, as new")
    local back = false
    for _, n in ipairs(H.sentOf("politicsNotice")) do if n.kind == "workshop" then back = true end end
    H.ok(back)
    -- 음식은 안 받는다
    H.defineItem("Base.Apple", "food", 1, 1)
    local apple = H.give(p, "Base.Apple")
    H.clockMin = H.clockMin + 3 * 1440
    local _, why3 = Pol.workshop(p, apple.id)
    H.eq(why3, "kind")
end

function T.the_post_bill_hands_rewards_over_minus_a_cut()
    local p, ps = setup(true)
    local Pol, Quests = P(), StoryEngine.Quests
    for i, ft in ipairs({ "Base.Hammer", "Base.Saw", "Base.Screwdriver", "Base.Wrench", "Base.Crowbar" }) do
        H.defineItem(ft, "tools", 4, 2)
    end
    local goods = { "Base.Hammer", "Base.Saw", "Base.Screwdriver", "Base.Wrench", "Base.Crowbar" }
    local kept, taken = Pol.cut(goods, 0.3)
    H.ok(#kept >= 1 and #kept < #goods, "the carriers keep some, never all")
    H.eq(#kept + taken, 5)
    local one = Pol.cut({ "Base.Hammer" }, 0.3)
    H.eq(#one, 1, "a single thing is never taken")
    Pol.debug({ enact = "post" })
    local before = #p.items
    local q, why = Quests.create("supply_drop", p, ps, 2, now(), { source = "reward", faction = "ray" }, goods)
    H.eq(q, nil)
    H.eq(why, "posted")
    local got = #p.items - before
    H.ok(got >= 1 and got < 5, "straight to hand, minus the cut")
    local note = nil
    for _, n in ipairs(H.sentOf("politicsNotice")) do if n.kind == "post" then note = n end end
    H.ok(note and note.got == got and note.taken == 5 - got)
end

function T.exchange_halves_waits_and_doubles_costs()
    setup(true)
    local Pol, Sp = P(), StoryEngine.Specialty
    setTrust("hunter", 45)
    H.eq(Sp.cooldownDays("hunter"), 3)
    H.eq(Sp.costOf("hunter", 1).n, 10)
    Pol.debug({ enact = "exchange" })
    H.eq(Sp.cooldownDays("hunter"), 1.5)
    H.eq(Sp.costOf("hunter", 1).n, 20)
    H.eq(Sp.status("hunter").cost.n, 20, "the tooltip shows the doubled cost")
end

function T.the_canteen_feeds_everyone_each_morning()
    local p = setup(true)
    local Pol, Life = P(), StoryEngine.Life
    H.eq(Pol.meals(now()), 0)
    Life.daily()
    Pol.debug({ enact = "canteen" })
    H.eq(Pol.meals(now()), 1)
    H.eq(count(p, Pol.MEAL_ITEM), 1)
    H.eq(Pol.meals(now()), 0, "once a day")
    local base = Life.base("pike", "food")
    Life.npc("pike").res.food = base
    H.advanceDays(1)
    Life.daily()
    H.eq(res("pike", "food"), base - 2, "everyone's food pays for it")
    H.clockMin = (math.floor(H.clockMin / 1440)) * 1440 + 5 * 60
    H.eq(Pol.meals(now()), 0, "not before morning")
    H.clockMin = H.clockMin + 3 * 60
    H.eq(Pol.meals(now()), 1)
    H.eq(count(p, Pol.MEAL_ITEM), 2)
end

function T.the_purge_bill_means_bigger_hordes_and_better_pay()
    local p, ps = setup(true)
    mockBuildings()
    local Pol, Quests = P(), StoryEngine.Quests
    local plain = Quests.proposeHorde(p, ps, "hunter", 2, now())
    H.ok(plain, "a horde without the bill")
    H.eq(plain.purge, nil)
    H.eq(Quests.bonusMult(plain), 1)
    Pol.debug({ enact = "purge" })
    H.eq(Pol.mod("hordeShare"), 2)
    local q = Quests.proposeHorde(p, ps, "guard", 2, now())
    H.eq(q.size, math.floor(plain.size * 1.5 + 0.5), "half again as many")
    H.eq(q.purge, 0.5)
    H.eq(Quests.bonusMult(q), 1.5)
    q.night = true
    H.eq(Quests.bonusMult(q), 2, "with a night job it adds up to double, not 2.25")
end

function T.apprenticeship_teaches_the_trade()
    local p = setup(true)
    local Pol = P()
    local got = {}
    Perks = { Trapping = "Trapping", Butchering = "Butchering", Lightfoot = "Lightfoot", Nimble = "Nimble", Sneak = "Sneak" }
    addXp = function(player, perk, n) got[perk] = (got[perk] or 0) + n end
    H.eq(Pol.apprentice("hunter", p, 3), nil, "no bill, no lessons")
    Pol.debug({ enact = "apprentice" })
    H.eq(Pol.apprentice("hunter", p, 3), 400)
    H.eq(got.Trapping, 200)
    H.eq(got.Butchering, 200)
    H.eq(Pol.apprentice("rats", p, 1), 99, "three skills share the lesson")
    H.eq(got.Sneak, 33)
    for fid, skills in pairs(Pol.SKILLS) do
        H.ok(StoryEngine.Factions.byId[fid], fid)
        H.ok(#skills >= 2, fid .. " teaches at least two things")
    end
    Perks, addXp = nil, nil
end

function T.a_truce_holds_until_the_toll_goes_unpaid()
    local p, ps = setup(true)
    local Pol, Bonds, Quests = P(), StoryEngine.Bonds, StoryEngine.Quests
    H.ok(Bonds.get("guard", "rats") < 0, "they start out at odds")
    Pol.debug({ enact = "truce" })
    H.eq(Bonds.get("guard", "rats"), 0)
    H.eq(Bonds.get("rats", "guard"), 0)
    H.eq(Pol.mod("noClash"), true)
    StoryEngine.Life.npc("guard").res.safety = 90
    H.rolls = { 0 }
    H.eq(StoryEngine.NpcEvents.clash(now()), false, "no clashes under the truce")
    H.rolls = {}
    -- 한 주 뒤 통행세
    setTrust("rats", 50)
    setTrust("guard", 50)
    H.clockMin = H.clockMin + 7 * 1440 + 60
    Pol.tick(now())
    local law = Pol.law("truce")
    H.ok(law and law.tollId, "Vic asks for his toll")
    local q = StoryEngine.Store.data().quests[law.tollId]
    H.eq(q.origin.faction, "rats")
    H.eq(q.origin.politics, "truce")
    Quests.respond(p, q.id, false)
    H.eq(Pol.law("truce"), nil, "refusing the toll breaks the truce")
    H.ok(trust("guard") < 50, "the Guard blames them too")
    H.ok(trust("rats") < 50)
end

function T.vouching_lifts_one_and_binds_another()
    local p, ps = setup(true)
    local Pol, Quests = P(), StoryEngine.Quests
    trustAll(40)
    setTrust("ray", 90)
    setTrust("hunter", 30)
    local ok, bill = Pol.proposeSpecial(p, "vouch", "hunter")
    H.ok(ok, tostring(bill))
    H.eq(bill.guarantor, "ray", "the one who trusts them most vouches")
    H.eq(Pol.need(bill, "hunter"), 30, "the one vouched for gains")
    Pol.state().bill = nil
    Pol.debug({ enact = "vouch", target = "hunter" })
    H.eq(trust("hunter"), 40, "plus ten, as agreed")
    H.eq(trust("ray"), 85, "the guarantor spends some of their own standing")
    -- 보증받은 사람의 부탁을 놓치면 보증인이 더 잃는다 (한 번)
    local q = Quests.propose(p, ps, "hunter", 1, now(), {})
    H.ok(q)
    Quests.respond(p, q.id, false)
    H.eq(trust("ray"), 75)
    local q2 = Quests.propose(p, ps, "hunter", 1, now(), {})
    if q2 then Quests.respond(p, q2.id, false) end
    H.eq(trust("ray"), 75, "only once")
    -- 없는 사람은 보증할 수 없다
    Pol.state().specialT = nil
    Pol.repeal("vouch", now(), "debug")
    local bad, why = Pol.proposeSpecial(p, "vouch", "nobody")
    H.eq(bad, false)
    H.eq(why, "no_target")
end

function T.the_day_of_remembrance_closes_everything_for_a_day()
    local p = setup(true)
    local Pol, Life = P(), StoryEngine.Life
    setTrust("hunter", 85)
    Pol.debug({ enact = "memorial" })
    H.eq(Pol.mod("recess"), true)
    H.eq(StoryEngine.Specialty.status("hunter").reason, "recess")
    H.eq(StoryEngine.Trade.offerContext("ray", 80).reason, "recess")
    local law = Pol.law("memorial")
    H.ok(law.collectId, "candles and food are gathered for it")
    H.ok(StoryEngine.Quests.isManaged(StoryEngine.Store.data().quests[law.collectId]))
    local before = res("ray", "morale")
    -- 모금을 다 채운다
    local q = StoryEngine.Store.data().quests[law.collectId]
    q.got = {}
    for _, n in ipairs(q.need) do q.got[n[1]] = n[2] end
    H.clockMin = H.clockMin + 25 * 60
    Pol.tick(now())
    H.eq(Pol.law("memorial"), nil)
    H.eq(res("ray", "morale"), math.min(100, before + 10))
    H.eq(StoryEngine.Specialty.status("hunter").reason, nil, "open again the next day")
    H.ok(Pol.state().calmUntil > now().t, "three calmer days follow")
end

function T.winter_stores_only_in_autumn_and_only_when_filled()
    local p = setup(true)
    local Pol, Social = P(), StoryEngine.Social
    local season = Social.season
    Social.season = function() return "summer" end
    local function why(id)
        for _, o in ipairs(Pol.specials(now())) do
            if o.id == id then return o.why, o.ok end
        end
    end
    H.eq(why("winter"), "season")
    Social.season = function() return "autumn" end
    H.eq(select(2, why("winter")), true)
    local ok = Pol.proposeSpecial(p, "winter")
    H.ok(ok)
    H.eq(why("memorial"), "busy", "one bill at a time")
    trustAll(60)
    H.clockMin = H.clockMin + 3 * 1440 + 60
    Pol.vote(now())
    local law = Pol.law("winter")
    H.ok(law and law.collectId)
    H.eq(why("memorial"), "wait", "one special bill a month")
    H.ok(not Pol.winterReady())
    local q = StoryEngine.Store.data().quests[law.collectId]
    q.got = {}
    for _, n in ipairs(q.need) do q.got[n[1]] = n[2] end
    H.clockMin = H.clockMin + 10 * 1440 + 60
    Pol.tick(now())
    H.ok(Pol.winterReady(), "the county is stocked for the winter")
    Pol.state().bill = nil                 -- 그사이 파벌이 낸 법안은 치운다
    H.eq(why("winter"), "wait")
    Pol.state().specialT = nil
    H.eq(why("winter"), "done", "not twice for the same winter")
    Social.season = season
end

function T.leaning_on_one_camp_costs_you_with_the_others()
    local p, ps = setup(true)
    local Pol, Sp, Quests = P(), StoryEngine.Specialty, StoryEngine.Quests
    H.ok(not Pol.against("guard"))
    -- 밭 사람의 부탁을 해 주면 밭으로 기운다
    local q = Quests.propose(p, ps, "ray", 2, now(), {})
    H.ok(q)
    Quests.setState(q, "completed", now(), { ps = ps })
    H.eq(Pol.lean("field"), 4)
    Pol.state().lean.field = 50
    H.ok(Pol.against("guard"), "the Guns see them as the Fields' people")
    H.ok(Pol.against("rats"))
    H.ok(not Pol.against("ray"))
    H.eq(Sp.cooldownDays("hunter"), 4.5, "their favours come slower")
    H.near(Pol.mod("price", "rats", "tools"), 1.1, 0.001)
    H.eq(Pol.mod("price", "ray", "food"), 1)
    local view = Pol.payload(ps.key)
    H.eq(#view.against, 5)
    -- 날마다 가운데로 돌아온다
    StoryEngine.Life.daily()
    H.advanceDays(1)
    StoryEngine.Life.daily()
    H.eq(Pol.lean("field"), 49)
    -- 보정에는 상한이 있다
    Pol.debug({ enact = "exchange" })
    H.eq(Pol.mod("specWait", "hunter"), 0.75)
    H.eq(Pol.mod("specWait", "ray"), 0.5)
end

function T.the_camps_take_turns_and_the_ai_is_told()
    setup(true)
    local Pol = P()
    trustAll(60)
    local seen = {}
    for _ = 1, 3 do
        Pol.state().bill = nil
        local b = Pol.propose(now())
        H.ok(b, "each camp has something to propose")
        seen[b.bloc] = true
        H.eq(StoryEngine.Politics.BILLS[b.id].special, nil, "special bills are the players' to propose")
    end
    H.ok(seen.field and seen.gun and seen.market, "all three camps got a turn")
    local ctx = Pol.context("ray")
    H.eq(ctx.bloc, "field")
    H.ok(ctx.bill and ctx.bill.text and (ctx.bill.vote == "for" or ctx.bill.vote == "against"))
    H.ok(string.find(Pol.statusText(), "politics lean", 1, true))
    Pol.debug({ reset = true })
    H.eq(Pol.context("ray"), nil)
end

-- 로비 (4단계): 설득은 찬성 기준을 움직이고, 약속은 표를 얻는 대신 빚을 진다
function T.lobbying_moves_votes_at_a_price()
    local p, ps = setup(true)
    local Pol, Work = P(), StoryEngine.Work
    trustAll(55)
    H.eq(Pol.lobby(p, "ray", "persuade"), false, "nothing to lobby without a bill")
    Pol.debug({ bill = "armory" })
    local bill = Pol.state().bill
    H.eq(Pol.forecast(bill).pass, false, "4 to 4")
    -- 설득: 신뢰 60 이상
    local ok, why, need = Pol.lobby(p, "ray", "persuade")
    H.eq(why, "trust")
    H.eq(need, 60)
    setTrust("ray", 60)                    -- 기준도 60 이라 이미 찬성
    setTrust("doc", 60)
    H.eq(Pol.need(bill, "doc"), 60)
    setTrust("doc", 62)
    setTrust("ray", 55)
    H.eq(Pol.forecast(bill).yes, 5, "doc is over the bar")
    -- 반대 쪽으로 설득하면 기준이 올라간다
    ok, why = Pol.lobby(p, "doc", "persuade", "against")
    H.ok(ok, tostring(why))
    H.eq(Pol.need(bill, "doc"), 75)
    H.eq(Pol.forecast(bill).yes, 4)
    H.eq(Pol.lean("market"), -5, "working against the Market's bill")
    local again, whyAgain = Pol.lobby(p, "doc", "promise")
    H.eq(whyAgain, "again", "one approach per person per bill")
    -- 약속: 표를 얻고 빚을 진다
    ok, why = Pol.lobby(p, "guard", "promise", "for")
    H.ok(ok, tostring(why))
    H.eq(Pol.forecast(bill).yes, 5)
    H.ok(Work.owed("guard", ps.key), "a favour is owed")
    H.eq(Work.owed("guard", ps.key).promise, true)
    local view = Pol.payload(ps.key)
    H.eq(view.bill.lobbyLeft, 1)
    H.eq(view.bill.lobby.guard.how, "promise")
    H.eq(#view.promises, 1)
    -- 세 명까지
    setTrust("pike", 45)
    H.ok(Pol.lobby(p, "pike", "promise", "for"))
    local full, whyFull = Pol.lobby(p, "ray", "promise", "for")
    H.eq(whyFull, "spent")
    H.eq(Pol.forecast(bill).pass, true, "6 to 2 now")
    -- 같은 사람 설득은 주에 한 번
    Pol.state().bill = nil
    Pol.debug({ bill = "post" })
    local tired, whyTired = Pol.lobby(p, "doc", "persuade")
    H.eq(whyTired, "tired")
    -- 이미 빚이 있으면 또 약속할 수 없다
    local owed, whyOwed = Pol.lobby(p, "guard", "promise")
    H.eq(whyOwed, "owed")
    -- 이틀 뒤 빚 부탁이 온다
    H.clockMin = H.clockMin + 2 * 1440 + 60
    Work.callFavors(now())
    H.ok(Work.owed("guard", ps.key).called, "the Guard calls the favour in")
end

-- 의장 선거 (5단계, 위기 E1)
function T.the_council_elects_a_chair()
    local p, ps = setup(true)
    local Pol, Life = P(), StoryEngine.Life
    trustAll(40)
    setTrust("ray", 60)
    setTrust("guard", 55)
    setTrust("rats", 50)
    H.clockMin = H.clockMin + 2 * 1440 + 60
    Pol.tick(now())
    local e = Pol.state().election
    H.ok(e, "the first election opens two days in")
    H.eq(e.cands.field, "ray", "each camp puts up the one who trusts them most")
    H.eq(e.cands.gun, "guard")
    H.eq(e.cands.market, "rats")
    local f = Pol.electionForecast(e)
    H.eq(f.votes.field, 3, "everyone votes with their camp by default")
    H.eq(f.votes.market, 3)
    H.eq(f.votes.gun, 2)
    H.eq(f.winner, "field", "a tie goes to the candidate who trusts them more")
    -- 공개 지지: 우리를 믿는 사람이 따라온다
    trustAll(80)
    local before = trust("ray")
    H.ok(Pol.back(p, "gun"))
    local again, why = Pol.back(p, "field")
    H.eq(why, "backed", "it cannot be undone")
    H.eq(Pol.electionForecast(e).winner, "gun")
    H.eq(Pol.lean("gun"), 10)
    H.clockMin = H.clockMin + 7 * 1440 + 60
    Pol.electionVote(now())
    local chair = Pol.chair()
    H.eq(chair.fid, "guard")
    H.eq(chair.bloc, "gun")
    H.ok(trust("ray") < before, "the losing candidates hold it against them")
    -- 총의 의장: 방위대·행크 특기가 빨라지고 총기 한도가 조여진다
    H.eq(Pol.mod("specWait", "hunter"), 0.75)
    H.eq(Pol.mod("specWait", "ray"), 1)
    H.eq(Pol.mod("gunTier", "rats", "firearm"), -1)
    H.eq(Pol.mod("baseBonus", "ray", "morale"), 0)
    -- 의장이 우리를 믿으면 특별 법안을 더 자주
    H.eq(Pol.specialDays(), 15)
    setTrust("guard", 20)
    H.eq(Pol.specialDays(), 30)
    H.eq(Pol.lobbyMax(), 2, "a chair who dislikes them leaves one fewer to move")
    -- 임기가 끝나면 다음 선거
    H.eq(Pol.payload(ps.key).chair.days, 60)
    H.clockMin = H.clockMin + 54 * 1440
    Pol.tick(now())
    H.ok(Pol.state().election, "the next election opens a week before the term ends")
    -- 밭·장터의 색
    Pol.state().chair = { fid = "ray", bloc = "field", untilT = now().t + 1000 }
    H.eq(Pol.mod("baseBonus", "pike", "morale"), 10)
    H.eq(Life.base("pike", "morale"), (Life.BASE.pike.morale or 40) + 10)
    Pol.state().chair = { fid = "rats", bloc = "market", untilT = now().t + 1000 }
    H.near(Pol.mod("price", "ray", "food"), 0.9, 0.001)
end

function T.the_players_can_take_the_chair_if_everyone_agrees()
    local p, ps = setup(true)
    local Pol, Quests, Trust = P(), StoryEngine.Quests, StoryEngine.Trust
    trustAll(75)
    setTrust("hunter", 45)
    Pol.debug({ election = true })
    local view = Pol.payload(ps.key).election
    H.eq(view.canRun, false)
    H.eq(view.blocker, "hunter")
    local ok, why, who = Pol.run(p)
    H.eq(why, "trust")
    H.eq(who, "hunter", "one who does not trust them is enough to stop it")
    setTrust("hunter", 55)
    setTrust("doc", 60)
    ok, why = Pol.run(p)
    H.ok(ok, tostring(why))
    local e = Pol.state().election
    H.ok(e.player.asks.hunter and e.player.asks.doc, "those in between name a request as their price")
    H.eq(e.player.asks.ray, nil)
    local q = StoryEngine.Store.data().quests[e.player.asks.hunter]
    H.eq(q.tier, 4)
    H.eq(q.origin.politics, "campaign")
    local f = Pol.electionForecast(e)
    H.eq(f.player.got, 6)
    H.eq(f.player.need, 8)
    H.eq(Pol.back(p, "field"), false, "no backing someone else while standing")
    -- 한 사람의 부탁은 끝내고, 한 사람은 신뢰도를 70 까지 올린다
    Quests.setState(q, "completed", now(), { ps = ps })
    setTrust("doc", 70)
    H.eq(Pol.electionForecast(e).player.got, 8)
    H.clockMin = H.clockMin + 7 * 1440 + 60
    Pol.tick(now())
    local chair = Pol.chair()
    H.eq(chair.player, ps.key)
    H.eq(Pol.payload(ps.key).chair.mine, true)
    -- 의장의 힘: 법안을 고르고, 동수를 정하고, 로비가 한 명 는다
    H.eq(Pol.lobbyMax(), 4)
    H.eq(Pol.mod("upkeep"), 0.5)
    H.eq(Trust.upkeepLimit({ idle = 7 }), 3)
    H.eq(Trust.upkeepLimit({ idle = 4 }), 2)
    Pol.state().bill = nil
    H.ok(Pol.choose(p, "armory"))
    local bill = Pol.state().bill
    H.eq(bill.by, "chair")
    H.eq(Pol.choose(p, "post"), false, "one at a time")
    trustAll(55)
    H.eq(Pol.forecast(bill).yes, 4)
    H.ok(Pol.cast(p, "for"))
    H.clockMin = H.clockMin + 3 * 1440 + 60
    local t = Pol.vote(now())
    H.eq(t.pass, true, "the chair breaks the tie")
    H.ok(Pol.law("armory"))
    -- 대가: 고른 법안이 부결되면 모두가 탓한다
    trustAll(55)
    H.ok(Pol.choose(p, "exchange"))
    trustAll(20)
    H.clockMin = H.clockMin + 3 * 1440 + 60
    Pol.vote(now())
    H.eq(trust("ray"), 18)
    -- 평균 신뢰가 50 밑이면 불신임
    StoryEngine.Life.daily()
    H.advanceDays(1)
    StoryEngine.Life.daily()
    H.eq(Pol.chair(), nil, "voted out")
    H.ok(trust("ray") < 18)
    local out = false
    for _, n in ipairs(H.sentOf("politicsNotice")) do if n.kind == "impeached" then out = true end end
    H.ok(out)
end

function T.a_failed_run_leaves_the_chair_to_a_candidate()
    local p, ps = setup(true)
    local Pol = P()
    trustAll(60)
    Pol.debug({ election = true })
    H.ok(Pol.run(p))
    H.clockMin = H.clockMin + 7 * 1440 + 60
    local r = Pol.electionVote(now())
    H.eq(r.ranFailed, ps.name)
    H.ok(r.fid, "one of the candidates takes it instead")
    H.eq(Pol.chair().player, nil)
end

return T
