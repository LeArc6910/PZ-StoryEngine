-- NPC 장기 프로젝트 (Projects.lua 와 각 효과)
local T = {}

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    H.defineItem("Base.TinnedBeans", "food", 1.5)
    H.defineItem("Base.Bandage", "medical", 3)
    H.defineItem("Base.Bullets9mmBox", "ammo", 15)
    return p, ps
end

local P = function() return StoryEngine.Projects end
local function res(fid, r) return StoryEngine.Life.npc(fid).res[r] end
local function setTrust(fid, v) StoryEngine.Radio.channel(fid).trust = v end

local function give(p, ft, n)
    local ids = {}
    for _ = 1, n do ids[#ids + 1] = H.give(p, ft):getID() end
    return ids
end

function T.project_donation_points_trust_and_no_resources()
    local p, ps = setup()
    local ids = give(p, "Base.TinnedBeans", 10)                 -- 식량 15 -> 15점 (레이가 받는 자원)
    for _, id in ipairs(give(p, "Base.Bandage", 2)) do ids[#ids + 1] = id end   -- 의약품 6 -> 3점
    local foodBefore = res("ray", "food")
    local ok, info = StoryEngine.Life.donate(p, "ray", ids, "project")
    H.ok(ok, tostring(info))
    H.eq(info.points, 18)
    H.eq(P().of("ray").points, 18)
    H.eq(res("ray", "food"), foodBefore, "project gifts do not raise supplies")
    H.eq(info.trust, 2, "trust follows the donation rule (value 21)")
    local log = StoryEngine.Life.npc("ray").log
    H.eq(log[#log].kind, "project_gift")
    H.eq(ps.notes[#ps.notes].kind, "project_donation")
    local b = H.lastBridge("radio", "event")
    H.ok(b and string.find(b.payload.topic, "big project", 1, true), "ray talks about the project")
    H.ok(b.payload.life.project and b.payload.life.project.points == 18, "project in AI context")
    -- 3일 통 (2026-10-08): 같은 기간에 더 나눠 낼 수 있고, 신뢰도는 가치 합이 새 단계를 넘을 때만
    local ok2, info2 = StoryEngine.Life.donate(p, "ray", give(p, "Base.TinnedBeans", 7), "project")
    H.ok(ok2, tostring(info2))
    H.eq(info2.points, 11, "7 x 1.5 = 10.5, rounded")
    H.eq(info2.trust, 1, "value 21 + 10.5 crosses the 30 step: +1 more")
    local ok3, info3 = StoryEngine.Life.donate(p, "ray", give(p, "Base.TinnedBeans", 2), "project")
    H.ok(ok3)
    H.eq(info3.trust, 0, "no more trust steps this period")
    -- 물자 지원과 같은 통: 물자 지원도 신뢰도 단계는 이미 다 받았다
    local ok4, info4 = StoryEngine.Life.donate(p, "ray", give(p, "Base.TinnedBeans", 4))
    H.ok(ok4)
    H.eq(info4.trust, 0, "supplies share the trust steps")
end

function T.project_points_refill_after_the_period()
    local p = setup()
    local ok, info = StoryEngine.Life.donate(p, "guard", give(p, "Base.Bullets9mmBox", 4), "project")
    H.ok(ok)
    H.eq(info.points, 60)
    ok, info = StoryEngine.Life.donate(p, "guard", give(p, "Base.Bullets9mmBox", 4), "project")
    H.ok(ok)
    H.eq(info.points, 40, "only 40 left in this period")
    local ok3, why, wait = StoryEngine.Life.donate(p, "guard", give(p, "Base.Bullets9mmBox", 1), "project")
    H.eq(why, "cooldown", "period limit reached")
    H.eq(wait, 72)
    H.advanceDays(3)
    ok, info = StoryEngine.Life.donate(p, "guard", give(p, "Base.Bullets9mmBox", 1), "project")
    H.ok(ok, "a new period")
    H.eq(info.points, 15)
end

function T.one_delivery_is_capped_at_100_points()
    local p = setup()
    local ids = give(p, "Base.Bullets9mmBox", 10)                 -- 10 x 15 = 150점어치
    local ok, info = StoryEngine.Life.donate(p, "guard", ids, "project")
    H.ok(ok, tostring(info))
    H.eq(info.points, 100, "capped at 100")
    H.eq(P().of("guard").points, 100)
    local left = 0
    for _, it in ipairs(p.items) do if it.fullType == "Base.Bullets9mmBox" then left = left + 1 end end
    H.eq(left, 3, "7 boxes taken (105 points' worth), 3 stay in the inventory")
end

function T.stages_and_completion()
    local p, ps = setup()
    local Pr = P()
    local n0 = #H.bridge
    Pr.add("ray", 290, "Gerald Kar")
    H.eq(#H.bridge, n0, "no call below 30%")
    Pr.add("ray", 20, "Gerald Kar")
    H.ok(string.find(H.lastBridge("radio", "event").payload.topic, "Progress", 1, true), "30% call")
    Pr.add("ray", 300, "Gerald Kar")
    H.eq(Pr.of("ray").stage, 2, "60% call")
    StoryEngine.Life.npc("ray").res.food = 30
    Pr.add("ray", 1000, "Gerald Kar")
    H.ok(Pr.done("ray"))
    H.eq(Pr.of("ray").points, 1000)
    H.eq(StoryEngine.Life.base("ray", "food"), 65, "food baseline +20")
    H.eq(res("ray", "food"), 65, "raised to the new baseline right away")
    H.eq(StoryEngine.Social.story("ray").wins, 1, "counts as a story win")
    H.eq(ps.notes[#ps.notes].kind, "project_done")
    H.eq(#H.sentOf("projectDone"), 1)
    -- 1차가 끝나면 점수는 2차 프로젝트로 (2026-10-09)
    H.eq(Pr.add("ray", 10), 10, "after the first project, points go to the second")
    H.eq(Pr.of2("ray").points, 10)
    H.eq(Pr.info("ray").phase, 2)
    local ok = StoryEngine.Life.donate(p, "ray", give(p, "Base.TinnedBeans", 1), "project")
    H.ok(ok, "project support now fills the second project")
    -- 완성 뒤 매일 기준값 65 쪽으로
    StoryEngine.Life.daily()
    StoryEngine.Life.npc("ray").res.food = 90
    H.advanceDays(1)
    StoryEngine.Life.daily()
    H.eq(res("ray", "food"), 85, "drifts toward 65, not 45")
end

function T.points_from_story_crisis_and_big_quests()
    setup()
    local Pr = P()
    local Social = StoryEngine.Social
    Social.story("doc").node = "doc_2"
    Social.onQuest({ kind = "deliver", tier = 2, targetName = "Gerald Kar",
                     origin = { faction = "doc", story = { faction = "doc", node = "doc_2" } } }, "completed")
    H.eq(Pr.of("doc").points, 100, "story request +100")
    StoryEngine.Life.onQuest({ id = "Q5", kind = "deliver", tier = 3, need = { { "Base.Bandage", 1 } },
                               origin = { faction = "doc", initiator = "npc" }, targetName = "Gerald Kar" }, "completed", 3)
    H.eq(Pr.of("doc").points, 125, "tier 3 request +25")
    Pr.onCrisisHelped("doc", "Gerald Kar")
    H.eq(Pr.of("doc").points, 175, "crisis +50")
end

function T.gone_npc_project_stops()
    setup()
    StoryEngine.Fate.apply("pike", "dead", "debug")
    H.eq(P().add("pike", 500), 0)
end

function T.effect_casey_radius_and_cooldown()
    local p = setup()
    setTrust("casey", 45)
    P().add("casey", 1000)
    H.eq(StoryEngine.Specialty.cooldownDays("casey"), 2)
    local key = StoryEngine.Store.playerKey(p)
    StoryEngine.Store.data().hunts = { H1 = { id = "H1", target = key, remaining = 5, x = 10200, y = 10000 } }
    H.ok(StoryEngine.Specialty.request(p, "casey", {}))
    H.eq(#H.sentOf("scoutMarks")[1].marks, 1, "a pack 200 tiles away is marked with the antenna")
    H.eq(StoryEngine.Specialty.status("casey").wait, 48)
end

-- 진료소: 서로 다른 두 부위를 치료한다 (2026-10-02, 예전: 의약품 절반)
function T.effect_doc_two_body_parts()
    local p = setup()
    setTrust("doc", 45)
    P().add("doc", 1000)
    H.eq(res("doc", "medical"), 75, "medicine baseline 55 + 20")
    local arm = H.newBodyPart("arm", { scratch = true, cut = true })      -- 같은 부위 두 상처: 하나만
    local leg = H.newBodyPart("leg", { cut = true })
    local hand = H.newBodyPart("hand", { scratch = true })
    p.parts = { arm, leg, hand }
    H.ok(StoryEngine.Specialty.request(p, "doc", {}))
    local ok, n = StoryEngine.Specialty.healDone(p)
    H.ok(ok)
    H.eq(n, 2, "two parts")
    H.eq(arm.cut, false, "arm: worst wound (cut)")
    H.eq(arm.scratch, true, "one wound per part")
    H.eq(leg.cut, false, "leg: second part")
    H.eq(hand.scratch, true, "third part untouched")
    H.eq(res("doc", "medical"), 75 - 10, "normal cost 10")
end

function T.effect_pike_longer_comfort()
    local p = setup()
    setTrust("pike", 85)
    P().add("pike", 1000)
    H.ok(StoryEngine.Specialty.request(p, "pike", {}))
    H.eq(H.sentOf("specComfort")[1].hours, 18)
end

function T.effect_dewey_fast_arrival()
    local p = setup()
    setTrust("dewey", 45)
    P().add("dewey", 1000)
    local v = H.newVehicle(10003, 10000, { { id = "Door", cond = 10 } })
    H.ok(StoryEngine.Specialty.request(p, "dewey", {}))
    H.advance(61)
    H.fire("EveryOneMinute")
    H.eq(v.parts[1].cond, 40, "arrives within an hour")
end

function T.effect_hunter_more_snipes_and_safety()
    local p = setup()
    setTrust("hunter", 45)
    P().add("hunter", 1000)
    H.eq(StoryEngine.Life.base("hunter", "safety"), 80)
    H.newZombie(10005, 10000)
    H.ok(StoryEngine.Specialty.request(p, "hunter", {}))
    H.eq(H.sentOf("specSnipe")[1].count, 20, "10 + 10")
end

function T.effect_rats_trading_post()
    local p, ps = setup()
    setTrust("rats", 45)
    local before = StoryEngine.Trade.context("rats", ps).mult
    P().add("rats", 1000)
    local ctx = StoryEngine.Trade.context("rats", ps)
    H.near(ctx.mult, before, 0.001, "base prices unchanged")
    H.eq(ctx.stretchMult, nil, "no markup above the trust limit")
    H.rolls = { 10 }
    StoryEngine.Life.spill("rats", "Gerald Kar")
    H.eq(StoryEngine.Radio.channel("ray").trust, 30, "nobody minds helping Vic any more")
end

function T.effect_ray_greenhouse_gift_every_7_days()
    local p = setup()
    P().add("ray", 1000)
    local calls = 0
    StoryEngine.Quests.create = function() calls = calls + 1; return { id = "Qx" } end
    local Life = StoryEngine.Life
    Life.daily()
    H.advanceDays(1)
    Life.daily()
    H.eq(calls, 1, "first gift")
    for _ = 1, 6 do
        H.advanceDays(1)
        Life.daily()
    end
    H.eq(calls, 1, "not again within 7 days")
    H.advanceDays(1)
    Life.daily()
    H.eq(calls, 2, "again after 7 days")
end

function T.dewey_takes_car_parts_and_mechanic_tools()
    local p = setup()
    H.defineItem("Base.EngineParts", "misc", 0.2)
    H.defineItem("Base.Wrench", "tools", 8)
    H.defineItem("Base.CarBattery1", "misc", 0.2)
    local rule = P().rule("dewey")
    local parts = H.give(p, "Base.EngineParts")
    local battery = H.give(p, "Base.CarBattery1")
    local wrench = H.give(p, "Base.Wrench")
    local beans = H.give(p, "Base.TinnedBeans")
    H.eq(StoryEngine.Value.projectItem(p, parts, rule), 3, "engine parts 3")
    H.eq(StoryEngine.Value.projectItem(p, battery, rule), 15, "car battery 15")
    H.eq(StoryEngine.Value.projectItem(p, wrench, rule), 8, "wrench counts as a mechanic tool")
    H.eq(StoryEngine.Value.projectItem(p, beans, rule), 0.75, "other things count half")
    local ok, info = StoryEngine.Life.donate(p, "dewey", { parts:getID(), battery:getID(), wrench:getID() }, "project")
    H.ok(ok, tostring(info))
    H.eq(info.points, 26)
    H.eq(#StoryEngine.Value.donatableItems(p), 1, "car parts are not normal supplies (only the beans are)")
end

function T.vic_takes_anything_at_point_eight()
    local p = setup()
    local rule = P().rule("rats")
    H.near(StoryEngine.Value.projectItem(p, H.give(p, "Base.Bullets9mmBox"), rule), 12, 0.001, "ammo 15 x0.8")
    H.near(StoryEngine.Value.projectItem(p, H.give(p, "Base.TinnedBeans"), rule), 1.2, 0.001, "food 1.5 x0.8")
    H.near(StoryEngine.Value.projectItem(p, H.give(p, "Base.Bandage"), rule), 2.4, 0.001, "medicine 3 x0.8")
end

function T.guard_squad_sizes_with_and_without_checkpoint()
    local p = setup()
    local ALife = StoryEngine.ALife
    ALife.available = function() return true end
    local sizes = {}
    ALife.spawnSquad = function(player, fid, level, count) sizes[#sizes + 1] = count; return false, "stub" end
    for tier, trust in ipairs({ 45, 65, 85 }) do
        StoryEngine.Radio.channel("guard").trust = trust
        StoryEngine.Specialty.clearWait("guard")
        StoryEngine.Specialty.request(p, "guard", {})
    end
    H.eq(sizes[1], 2); H.eq(sizes[2], 4); H.eq(sizes[3], 6)
    P().add("guard", 1000)
    sizes = {}
    for _, trust in ipairs({ 45, 65, 85 }) do
        StoryEngine.Radio.channel("guard").trust = trust
        StoryEngine.Specialty.clearWait("guard")
        StoryEngine.Specialty.request(p, "guard", {})
    end
    H.eq(sizes[1], 4); H.eq(sizes[2], 6); H.eq(sizes[3], 8, "tier 3 now benefits too")
end

function T.commands_project_mode_and_list()
    local p = setup()
    local C = StoryEngine.Commands
    C.lifeDonate(p, { faction = "guard", mode = "project", items = give(p, "Base.Bullets9mmBox", 1) })
    local r = H.sentOf("lifeDonateResult")[1]
    H.ok(r.ok)
    H.eq(r.points, 15)
    local guard
    for _, n in ipairs(H.sentOf("lifeList")[1].npcs) do if n.id == "guard" then guard = n end end
    H.eq(guard.project.points, 15)
    H.eq(guard.project.goal, 1000)
    C.debugLife(p, { faction = "guard", delta = 0, project = 1000 })
    H.ok(P().done("guard"))
end

return T
