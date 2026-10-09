-- NPC 2차 특기 (Specialty2.lua, 2차 장기 프로젝트 Projects.add2, 2026-10-09)
local T = {}

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

local values
local function setup()
    mockBuildings()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    CharacterStat = { STRESS = "STRESS", UNHAPPINESS = "UNHAPPINESS", BOREDOM = "BOREDOM", PANIC = "PANIC",
                      PAIN = "PAIN", ENDURANCE = "ENDURANCE", FOOD_SICKNESS = "FOOD_SICKNESS", POISON = "POISON",
                      SICKNESS = "SICKNESS" }
    values = { STRESS = 0, UNHAPPINESS = 10, BOREDOM = 0, PANIC = 0, PAIN = 0, ENDURANCE = 1, FOOD_SICKNESS = 0,
               POISON = 0, SICKNESS = 0 }
    function p:getStats()
        return { get = function(_, k) return values[k] end, set = function(_, k, v) values[k] = v end }
    end
    return p, ps
end

local function S() return StoryEngine.Specialty2 end
local function setTrust(fid, v) StoryEngine.Radio.channel(fid).trust = v end

-- 그 NPC 의 1차·2차 프로젝트를 끝낸다
local function finish(fid)
    local Pr = StoryEngine.Projects
    Pr.add(fid, Pr.GOAL)
    Pr.add(fid, Pr.GOAL2)
    H.ok(Pr.done2(fid), "second project done")
end

local function ready(p, fid, opt)
    finish(fid)
    setTrust(fid, 85)
    H.ok(S().choose(p, fid, opt))
end

function T.second_project_opens_after_the_first()
    local p = setup()
    local Pr = StoryEngine.Projects
    H.eq(Pr.add2("ray", 50), 0, "nothing before the first project is done")
    Pr.add("ray", Pr.GOAL)
    H.ok(Pr.done("ray"))
    H.eq(Pr.info("ray").phase, 2)
    H.eq(Pr.info("ray").goal, 2000)
    Pr.add("ray", 600)
    H.eq(Pr.of2("ray").stage, 1, "30% progress call")
    Pr.add("ray", 2000)
    H.ok(Pr.done2("ray"))
    H.ok(Pr.allDone("ray"))
    local ok, why = StoryEngine.Life.donate(p, "ray", {}, "project")
    H.eq(why, "project_done", "nothing left to support")
    H.eq(H.sentOf("projectDone")[#H.sentOf("projectDone")].phase, 2)
end

function T.each_player_picks_and_can_switch_every_30_days()
    local p, ps = setup()
    local q = H.addPlayer("other", "Ann", "Lee")
    local ok, why = S().choose(p, "hunter", "game")
    H.eq(why, "locked", "only after the second project")
    finish("hunter")
    H.eq(S().status("hunter", ps).reason, "no_choice")
    StoryEngine.Specialty2.READY.flare = nil
    ok, why = S().choose(p, "hunter", "flare")
    H.eq(why, "not_ready", "options not marked ready cannot be picked")
    H.ok(S().choose(p, "hunter", "game"))
    H.ok(S().choose(q, "hunter", "game"), "another player picks their own")
    H.eq(S().choiceOf(ps, "hunter"), "game")
    ok, why = S().choose(p, "hunter", "flare")
    H.eq(why, "not_ready")
    StoryEngine.Specialty2.READY.flare = true
    ok, why = S().choose(p, "hunter", "flare")
    H.eq(why, "change_wait", "no switching within 30 days")
    H.advanceDays(30)
    H.ok(S().choose(p, "hunter", "flare"))
end

function T.use_conditions_cost_and_personal_cooldown()
    local p, ps = setup()
    local q = H.addPlayer("other", "Ann", "Lee")
    finish("hunter")
    H.ok(S().choose(p, "hunter", "game"))
    H.ok(S().choose(q, "hunter", "game"))
    setTrust("hunter", 70)
    H.eq(S().status("hunter", ps).reason, "low_trust")
    setTrust("hunter", 85)
    StoryEngine.Life.npc("hunter").res.safety = 25
    H.eq(S().status("hunter", ps).reason, "no_resource")
    StoryEngine.Life.npc("hunter").res.safety = 60
    H.ok(S().use(p, "hunter", {}))
    H.eq(StoryEngine.Life.npc("hunter").res.safety, 40, "key resource -20")
    H.eq(S().status("hunter", ps).reason, "cooldown")
    H.eq(S().status("hunter", ps).wait, 7 * 24)
    H.eq(S().status("hunter", StoryEngine.Store.player(q)).reason, nil, "the other player's wait is their own")
end

function T.shared_game_sends_weighted_meat()
    local p, ps = setup()
    ready(p, "hunter", "game")
    local before = #p.items
    H.ok(S().use(p, "hunter", {}))
    for _, q in pairs(StoryEngine.Store.data().quests) do
        H.ok(not (q.origin and q.origin.spec2 == "game"), "no supply drop any more")
    end
    -- 바로 인벤토리로
    local meat = 0
    for i = before + 1, #p.items do
        local it = p.items[i]:getFullType()
        meat = meat + 1
        H.ok(string.find(it, "meat", 1, true) or string.find(it, "Chop", 1, true)
            or it == "Base.Steak" or it == "Base.Venison" or it == "Base.Chicken", "meat " .. it)
    end
    H.ok(meat >= 4 and meat <= 8, "4 to 8 pieces in the inventory")
end

function T.praise_raises_trust_next_morning_up_to_90()
    local p, ps = setup()
    ready(p, "casey", "praise")
    setTrust("ray", 50)
    setTrust("doc", 95)
    H.ok(S().use(p, "casey", {}))
    H.eq(StoryEngine.Radio.channel("ray").trust, 50, "not yet")
    H.advanceDays(1)
    H.fire("EveryOneMinute")
    H.eq(StoryEngine.Radio.channel("ray").trust, 52, "+2 the next morning")
    H.eq(StoryEngine.Radio.channel("doc").trust, 95, "90 or more stays")
end

function T.sos_sends_five_kinds_of_help_and_skips_who_left()
    local p, ps = setup()
    ready(p, "casey", "sos")
    StoryEngine.Life.npc("rats").fate = { kind = "gone", day = 1 }
    H.ok(S().use(p, "casey", {}))
    local snipe = H.sentOf("specSnipe")[1]
    H.eq(snipe.count, 20, "Hank 15 + guard marksman 5 without A-Life")
    H.eq(snipe.minutes, 5)
    local fx = H.sentOf("spec2Fx")[1]
    H.ok(fx.calm and fx.numb, "calm and pain help")
    local spec = StoryEngine.Store.data().spec
    H.eq(#((spec and spec.decoys) or {}), 0, "Vic left: no decoy")
    values.PANIC, values.PAIN = 80, 60
    H.advance(1)
    H.fire("EveryOneMinute")
    H.eq(values.PANIC, 0)
    H.eq(values.PAIN, 0)
    H.advance(61)
    H.fire("EveryOneMinute")
    values.PANIC = 80
    H.fire("EveryOneMinute")
    H.eq(values.PANIC, 80, "an hour only")
end

function T.temporary_power_blocks_others_and_ends_quietly()
    local p, ps = setup()
    local q = H.addPlayer("other", "Ann", "Lee")
    finish("casey")
    setTrust("casey", 85)
    H.ok(S().choose(p, "casey", "power"))
    H.ok(S().choose(q, "casey", "power"))
    local off = false
    StoryEngine.World.powerOff = function() return off end
    H.eq(S().status("casey", ps).reason, "power_on", "only after the grid is down")
    off = true
    local restored
    local real = StoryEngine.Grid.restore
    StoryEngine.Grid.restore = function(kind, days, why) restored = { kind, days, why } return true end
    H.ok(S().use(p, "casey", {}))
    StoryEngine.Grid.restore = real
    H.eq(restored[1], "power")
    H.eq(restored[2], 3)
    H.eq(restored[3], "casey_temp")
    H.eq(S().status("casey", StoryEngine.Store.player(q)).reason, "world_active", "no stacking by another player")
end

function T.pharmacy_turns_herbs_into_medicine()
    local p, ps = setup()
    ready(p, "doc", "pharmacy")
    for _ = 1, 10 do H.give(p, "Base.Plantain") end
    local ok, why = S().use(p, "doc", { med = "antibiotics", count = 2 })
    H.eq(why, "no_herbs", "16 needed")
    H.eq(S().status("doc", ps).reason, nil, "refusal costs nothing")
    H.ok(S().use(p, "doc", { med = "painkillers", count = 1 }))
    local left = 0
    local list = p:getInventory():getItems()
    for i = 0, list:size() - 1 do if list:get(i):getFullType() == "Base.Plantain" then left = left + 1 end end
    H.eq(left, 4, "6 herbs taken")
    list = p:getInventory():getItems()
    local pills = 0
    for i = 0, list:size() - 1 do if list:get(i):getFullType() == "Base.Pills" then pills = pills + 1 end end
    H.eq(pills, 1, "medicine in the inventory")
end

function T.illness_needs_a_sickness_and_keeps_it_away()
    local p, ps = setup()
    ready(p, "doc", "illness")
    local ok, why = S().use(p, "doc", {})
    H.eq(why, "not_sick")
    values.FOOD_SICKNESS = 0.6
    H.ok(S().use(p, "doc", {}))
    H.eq(values.FOOD_SICKNESS, 0)
    values.POISON = 0.4
    H.advance(10)
    H.fire("EveryOneMinute")
    H.eq(values.POISON, 0, "kept away for three days")
end

function T.reconcile_helps_the_lowest_trust()
    local p, ps = setup()
    ready(p, "pike", "reconcile")
    for _, f in ipairs(StoryEngine.Factions.list) do setTrust(f.id, 60) end
    setTrust("pike", 85)
    setTrust("rats", 12)
    StoryEngine.Radio.channel("rats").workBurnT = 999999
    StoryEngine.Life.npc("rats").counts.broken = 5
    H.ok(S().use(p, "pike", {}))
    H.eq(StoryEngine.Radio.channel("rats").trust, 22)
    H.eq(StoryEngine.Radio.channel("rats").workBurnT, nil, "credit ban lifted")
    H.eq(StoryEngine.Life.npc("rats").counts.broken, 0)
end

function T.baptism_slows_endurance_loss_to_a_third()
    local p, ps = setup()
    ready(p, "pike", "baptism")
    values.ENDURANCE = 0.9
    H.ok(S().use(p, "pike", {}))
    values.ENDURANCE = 0.6
    H.advance(1)
    H.fire("EveryOneMinute")
    H.near(values.ENDURANCE, 0.8, 0.001, "lost 0.3, kept only a third of the loss")
end

function T.stew_keeps_unhappiness_from_rising()
    local p, ps = setup()
    ready(p, "ray", "stew")
    values.UNHAPPINESS = 20
    H.ok(S().use(p, "ray", {}))
    values.UNHAPPINESS = 35
    H.advance(1)
    H.fire("EveryOneMinute")
    H.eq(values.UNHAPPINESS, 20, "does not rise")
    values.UNHAPPINESS = 5
    H.advance(1)
    H.fire("EveryOneMinute")
    H.eq(values.UNHAPPINESS, 5, "can still go down")
end

function T.successor_forgets_the_choice()
    local p, ps = setup()
    ready(p, "hunter", "game")
    StoryEngine.Specialty2.forget("hunter")
    H.eq(S().choiceOf(ps, "hunter"), nil)
end

return T
