-- NPC 사이 관계 변화 (Bonds.lua, 아이디어 7번)
local T = {}

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    return p, ps
end

local B = function() return StoryEngine.Bonds end
local function setTrust(fid, v) StoryEngine.Radio.channel(fid).trust = v end

function T.starts_from_story_table_and_clamps()
    setup()
    H.eq(B().get("ray", "rats"), -1, "starting value from Stories.BONDS")
    H.eq(B().get("casey", "hunter"), 0, "unknown pair is neutral")
    H.eq(B().change("ray", "rats", -5, "test", false), -2, "clamped at -3")
    H.eq(B().get("ray", "rats"), -3)
    H.eq(B().get("rats", "ray"), 0, "one-sided change")
    B().change("casey", "hunter", 1, "went hunting together", true)
    H.eq(B().get("hunter", "casey"), 2, "mutual change adds to hunter's existing +1")
    H.eq(B().recent("casey", "hunter").text, "went hunting together")
    H.ok(string.find(B().statusText(), "ray>rats=-3", 1, true), "status line shows changed pairs")
    local likes, dislikes = B().of("ray")
    H.eq(dislikes[1].id, "rats")
    H.eq(dislikes[1].v, -3)
    H.eq(#likes, 3)
end

function T.ray_supply_warms_both_and_unlocks_vic()
    local p = setup()
    local Sp = StoryEngine.Specialty
    setTrust("ray", 65)
    local _, why = Sp.request(p, "ray", { target = "rats" })
    H.eq(why, "ray_refuses", "ray still dislikes Vic")
    H.ok(Sp.request(p, "ray", { target = "doc" }))
    H.eq(B().get("ray", "doc"), 1)
    H.eq(B().get("doc", "ray"), 1)
    -- 관계가 풀리면 구간과 상관없이 빅에게도 보낸다
    B().change("ray", "rats", 1, "test", false)
    StoryEngine.Store.data().spec.used = {}
    H.ok(Sp.request(p, "ray", { target = "rats" }), "no longer refuses at tier 2")
    H.eq(B().get("ray", "rats"), 1, "0 -> +1 after the supply run")
end

function T.crisis_choice_sours_rivals()
    local p = setup()
    local Social = StoryEngine.Social
    H.ok(Social.startCrisis(StoryEngine.Sensor.now(), "clash"))
    local q
    for _, x in pairs(StoryEngine.Store.data().quests) do if x.kind == "choice" then q = x end end
    H.ok(q, "crisis quest")
    local idx
    for i, o in ipairs(q.options) do if o.faction == "doc" then idx = i end end
    H.ok(StoryEngine.Quests.choose(p, q.id, idx))
    H.eq(B().get("guard", "doc"), -1)
    H.eq(B().get("doc", "guard"), -2, "doc already disliked the squad a little")
    H.eq(B().get("rats", "doc"), -1)
    H.ok(string.find(B().recent("doc", "rats").text, "over Vic", 1, true), "reason names the rival")
end

function T.story_node_and_trading_post()
    setup()
    StoryEngine.Social.moveTo("dewey", "dewey_4s", StoryEngine.Sensor.now())
    H.eq(B().get("casey", "dewey"), -1)
    H.ok(StoryEngine.Store.data().bonds.last.casey.dewey, "reason recorded")
    B().onTradingPost()
    H.eq(B().get("ray", "rats"), 0)
    H.eq(B().get("guard", "rats"), 0)
    H.eq(B().get("casey", "rats"), 1)
end

function T.clash_needs_hostility_and_deepens_it()
    setup()
    local NE = StoryEngine.NpcEvents
    StoryEngine.Life.npc("guard").res.safety = 90
    B().change("guard", "rats", 2, "truce", false)
    H.ok(not NE.clash(StoryEngine.Sensor.now()), "no fight after a truce")
    B().change("guard", "rats", -2, "truce broke", false)
    H.rolls = { 0, 99 }
    H.ok(NE.clash(StoryEngine.Sensor.now()))
    H.eq(B().get("guard", "rats"), -2)
    H.eq(B().get("rats", "guard"), -2)
end

function T.share_follows_current_bonds()
    setup()
    local NE = StoryEngine.NpcEvents
    local Life = StoryEngine.Life
    for _, f in ipairs(StoryEngine.Factions.list) do Life.npc(f.id).res.food = 50 end
    Life.npc("ray").res.food = 90
    Life.npc("rats").res.food = 5
    H.ok(not NE.share(StoryEngine.Sensor.now()), "ray won't feed Vic while they are at odds")
    B().change("ray", "rats", 1, "test", false)
    H.ok(NE.share(StoryEngine.Sensor.now()))
    H.eq(Life.npc("rats").res.food, 20)
    H.eq(B().get("rats", "ray"), 1, "Vic is grateful")
end

function T.spill_and_list_use_dynamic_bonds()
    setup()
    B().change("casey", "guard", 2, "the squad escorted Casey", false)
    local list = StoryEngine.Life.list()
    local casey
    for _, n in ipairs(list) do if n.id == "casey" then casey = n end end
    H.ok(casey, "casey in list")
    local found = false
    for _, id in ipairs(casey.likes) do if id == "guard" then found = true end end
    H.ok(found, "guard now liked")
    H.eq(casey.bondVals.guard, 2)
    -- 무전 맥락: 관계표에 없는 방위대도 마음이 생겼으니 들어간다
    local ctx = StoryEngine.Social.context("casey")
    local g
    for _, o in ipairs(ctx.others) do if o.id == "guard" then g = o end end
    H.ok(g, "guard in casey's context")
    H.eq(g.bond, 2)
    H.eq(g.shift, "the squad escorted Casey")
end

return T
