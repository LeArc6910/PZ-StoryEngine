-- 아는 얼굴의 좀비 (Named.lua), 유품 회수 (Recover.lua), 명절 (Holiday.lua)
local T = {}

local OFFLINE = { ok = false, error = "bridge_offline" }

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

-- 좀비 만들기 흉내: 인벤토리가 있는 좀비
local function mockZombies()
    H.spawned = {}
    addZombiesInOutfitArea = function(x1, y1, x2, y2, z, count, outfit, female)
        local out = {}
        for _ = 1, count do
            local zed = H.newZombie(x1, y1, true)
            zed.outfit = outfit
            local inv = { items = {} }
            function inv:AddItem(ft)
                local it = H.newItem(ft)
                it.container = inv
                inv.items[#inv.items + 1] = it
                return it
            end
            function zed:getInventory() return inv end
            out[#out + 1] = zed
            H.spawned[#H.spawned + 1] = zed
        end
        return H.list(out)
    end
end

local function setup(lang)
    mockBuildings()
    mockZombies()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = lang or "EN"
    SandboxVars.StoryEngine.ModItemsRatio = 0
    StoryEngine.Life.daily()
    return p, ps
end

local function quest(id) return StoryEngine.Store.data().quests[id] end

-- ---------------------------------------------------------------- named

function T.named_flow_spawn_slay_and_hand_over()
    local p, ps = setup()
    local Named = StoryEngine.Named
    local person = Named.byId.jim
    local q = Named.propose(p, ps, person, StoryEngine.Sensor.now())
    H.ok(q and q.kind == "named" and q.state == "proposed", "asked")
    H.lastBridge("radio", "request").callback(OFFLINE)
    local msgs = StoryEngine.Radio.channel("ray").messages
    H.ok(string.find(msgs[#msgs].lt.key, "Line_ray_named_ask_", 1, true), "ray asks in his own words")
    H.ok(StoryEngine.Quests.respond(p, q.id, true))
    Named.spawn(q)
    local z = H.spawned[1]
    H.eq(z.outfit, "Farmer")
    H.eq(z:getModData().storyNamed, q.id)
    H.eq(z:getInventory().items[1].fullType, person.item, "keepsake on the zombie")
    H.eq(z:getInventory().items[1]:getModData().storyQuest, q.id)
    -- 지도 표시가 좀비를 따라간다
    z.x, z.y = z.x + 30, z.y + 5
    Named.tick({}, StoryEngine.Sensor.now())
    H.eq(q.cx, math.floor(z.x))
    z.dead = true
    Named.onZombieDead(z)
    H.ok(q.slain, "slain")
    H.give(p, person.item, { questTag = q.id })
    H.ok(StoryEngine.Quests.submit(p, q.id))
    H.eq(q.state, "completed")
    H.ok(StoryEngine.Store.data().named.used.jim, "used once")
end

function T.named_candidates_need_trust_and_story_end()
    setup()
    local Named = StoryEngine.Named
    for _, f in ipairs(StoryEngine.Factions.list) do StoryEngine.Radio.channel(f.id).trust = 0 end
    H.eq(#Named.candidates(), 0, "nobody trusts you enough")
    StoryEngine.Radio.channel("casey").trust = 50
    local c = Named.candidates()
    H.eq(#c, 1)
    H.eq(c[1].id, "leed", "father only after casey's sad ending")
    StoryEngine.Social.story("casey").node = "casey_5b"
    c = Named.candidates()
    H.eq(c[1].id, "dad", "story ending comes first")
end

-- ---------------------------------------------------------------- recover

function T.recover_points_new_character_to_the_old_one()
    local p, ps = setup()
    local d = StoryEngine.Store.data()
    d.players["tester|Old Timer"] = { key = "tester|Old Timer", name = "Old Timer", dead = true,
        journal = { { kind = "daily", date = "July 10", text = "We found a farm." },
                    { kind = "daily", date = "July 11", text = "The dead came at night." } } }
    d.deaths = { { key = "tester|Old Timer", name = "Old Timer", x = 10050, y = 10020, t = StoryEngine.Sensor.now().t,
                   town = "Muldraugh" } }
    local Recover = StoryEngine.Recover
    local entries = { { player = p, ps = ps, s = { x = 10000, y = 10000 } } }
    Recover.tick(entries, StoryEngine.Sensor.now())
    H.ok(ps.recoverAt, "scheduled")
    H.advance(61)
    Recover.tick(entries, StoryEngine.Sensor.now())
    local q = nil
    for _, x in pairs(d.quests) do if x.origin and x.origin.source == "recover" then q = x end end
    H.ok(q and q.origin.dead == "Old Timer", "recovery quest")
    H.ok(StoryEngine.Quests.isManaged(q), "no trust or reward of its own")
    local found = false
    for _, ft in ipairs(q.items) do if ft == "StoryEngine.Letter" then found = true end end
    H.ok(found, "notebook placed")
    local info = StoryEngine.Letters.read(p, q.letterId, q.id)
    H.eq(info.memorial, "Old Timer")
    H.eq(#info.pages, 2)
    H.eq(info.pages[2].text, "The dead came at night.")
    H.ok(d.deaths[1].recovered, "only once")
    -- 다른 계정의 죽음은 안 한다
    local p2 = H.addPlayer("other", "Ann", "Lee")
    H.ok(Recover.findDeath(StoryEngine.Store.player(p2), StoryEngine.Sensor.now()) == nil)
end

-- ---------------------------------------------------------------- holidays

local function setDate(y, m, d, hour)
    H.gt.getYear = function() return y end
    H.gt.getMonth = function() return m - 1 end
    H.gt.getDay = function() return d - 1 end
    H.gt.getHour = function() return hour or 10 end
end

function T.lunar_table_and_thanksgiving()
    setup()
    local H2 = StoryEngine.Holiday
    local ch = H2.dateOf({ lunar = "chuseok" }, 1993)
    H.ok(ch[2] == 9 and ch[3] == 30, "chuseok 1993-09-30")
    local s = H2.dateOf({ lunar = "seollal" }, 1997)
    H.ok(s[2] == 2 and s[3] == 8, "Korean seollal 1997 is Feb 8")
    local tg = H2.dateOf({ rule = "thanksgiving" }, 1993)
    H.ok(tg[2] == 11 and tg[3] == 25, "thanksgiving 1993-11-25")
end

function T.korean_players_get_korean_holidays()
    local p, ps = setup("KO")
    setDate(1993, 9, 28, 10)
    local list = StoryEngine.Holiday.upcoming()
    H.eq(#list, 1)
    H.eq(list[1].h.id, "chuseok")
    H.eq(list[1].days, 2)
    ps.lang = "EN"
    setDate(1993, 11, 24, 10)
    list = StoryEngine.Holiday.upcoming()
    H.eq(list[1].h.id, "thanksgiving")
end

function T.announce_then_feast()
    local p, ps = setup("KO")
    local Holiday = StoryEngine.Holiday
    setDate(1993, 9, 28, 10)
    Holiday.hourly(StoryEngine.Sensor.now())
    local inst = StoryEngine.Store.data().holiday.done["KO_chuseok_1993"]
    H.ok(inst and inst.collect, "announced with a collection")
    local q = quest(inst.collect)
    H.eq(q.kind, "collect")
    H.ok(StoryEngine.Quests.isManaged(q))
    -- 재료를 다 보낸다
    for _, n in ipairs(q.need) do
        for _ = 1, n[2] do H.give(p, n[1]) end
    end
    H.ok(StoryEngine.Quests.contribute(p, q))
    H.eq(q.state, "completed")
    local morale = StoryEngine.Life.get("pike", "morale")
    local trust = StoryEngine.Radio.channel("pike").trust
    setDate(1993, 9, 30, 10)
    Holiday.hourly(StoryEngine.Sensor.now())
    H.eq(inst.stage, "celebrated")
    H.ok(StoryEngine.Life.get("pike", "morale") > morale, "feast lifts spirits")
    H.eq(StoryEngine.Radio.channel("pike").trust, trust + 1, "giver gains trust with the host")
    local food = 0
    for _, x in pairs(StoryEngine.Store.data().quests) do
        if x.origin and x.origin.source == "holiday" then
            for _, ft in ipairs(x.items) do if ft == "StoryEngine.Food_Songpyeon" then food = food + 1 end end
        end
    end
    H.eq(food, 3, "three songpyeon for the player")
    local noted = false
    for _, n in ipairs(ps.notes) do if n.kind == "holiday" and n.holiday == "chuseok" then noted = true end end
    H.ok(noted, "journal note")
end

function T.new_year_bow_gives_money_once()
    local p, ps = setup("KO")
    setDate(1994, 2, 10, 8)        -- 설날
    StoryEngine.Radio.channel("ray").trust = 60
    StoryEngine.Radio.lastSay = {}
    H.ok(StoryEngine.Radio.say(p, "ray", "새해 복 많이 받으세요"))
    local money = 0
    for _, it in ipairs(p.items) do if it.fullType == "Base.Money" then money = money + 1 end end
    H.eq(money, 3, "trust 60 -> 3 bills")
    StoryEngine.Radio.lastSay = {}
    StoryEngine.Radio.say(p, "ray", "또 왔어요")
    local again = 0
    for _, it in ipairs(p.items) do if it.fullType == "Base.Money" then again = again + 1 end end
    H.eq(again, 3, "only once per contact")
    StoryEngine.Radio.lastSay = {}
    StoryEngine.Radio.say(p, "casey", "케이시도 새해 복 많이 받아")
    local food = 0
    for _, it in ipairs(p.items) do if it.fullType == "StoryEngine.Food_Tteokguk" then food = food + 1 end end
    H.eq(food, 1, "casey is the kid: rice cake soup instead of money")
end

return T
