-- NPC 2차 특기 2단계 (Specialty2.lua 2단계, 2026-10-09): 기우제·피난민·견인·보강·포격·후송·바리케이드·털이·위장·소음기·조명
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
    grid.buildingAt = nil
    function grid:getBuildingAt(x, y) return grid.buildingAt and grid.buildingAt(x, y) or nil end
    local world = {}
    function world:getMetaGrid() return grid end
    getWorld = function() return world end
    return grid
end

-- 칸: 기본은 비어 있는 바깥 칸, squares 에 넣어 둔 칸은 그것
local squares
local function square(x, y, z, opts)
    opts = opts or {}
    local sq = { x = x, y = y, z = z or 0, bodies = opts.bodies or {}, objs = opts.objs or {}, room = opts.room }
    function sq:getX() return self.x end
    function sq:getY() return self.y end
    function sq:getZ() return self.z end
    function sq:isFree() return true end
    function sq:getRoom() return self.room end
    function sq:isSolid() return false end
    function sq:isSolidTrans() return false end
    function sq:getDeadBodys() return H.list(self.bodies) end
    function sq:removeCorpse(body)
        for i, b in ipairs(self.bodies) do if b == body then table.remove(self.bodies, i) return end end
    end
    function sq:getObjects() return H.list(self.objs) end
    squares[x .. "," .. y .. "," .. (z or 0)] = sq
    return sq
end

local grid
local values
local function setup()
    grid = mockBuildings()
    squares = {}
    H.cell.getGridSquare = function(_, x, y, z)
        return squares[x .. "," .. y .. "," .. (z or 0)] or square(x, y, z)
    end
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    CharacterStat = { PAIN = "PAIN", PANIC = "PANIC", STRESS = "STRESS" }
    values = { PAIN = 0, PANIC = 0, STRESS = 0 }
    function p:getStats() return { get = function(_, k) return values[k] end, set = function(_, k, v) values[k] = v end } end
    return p, ps
end

local function S() return StoryEngine.Specialty2 end

local function ready(p, fid, opt)
    local Pr = StoryEngine.Projects
    Pr.add(fid, Pr.GOAL)
    Pr.add(fid, Pr.GOAL2)
    StoryEngine.Radio.channel(fid).trust = 85
    for _, r in ipairs({ "food", "medical", "safety", "morale" }) do StoryEngine.Life.npc(fid).res[r] = 80 end
    H.ok(S().choose(p, fid, opt))
end

local function tick(minutes)
    for _ = 1, minutes do
        H.advance(1)
        H.fire("EveryOneMinute")
    end
end

function T.rain_starts_next_morning_and_blocks_others()
    local p, ps = setup()
    local q = H.addPlayer("other", "Ann", "Lee")
    ready(p, "ray", "rain")
    H.ok(S().choose(q, "ray", "rain"))
    local admin = {}
    local floats = {}
    local function float(id)
        floats[id] = floats[id] or { setEnableAdmin = function(_, on) admin[id] = on end, setAdminValue = function() end }
        return floats[id]
    end
    ClimateManager = { FLOAT_PRECIPITATION_INTENSITY = 3, FLOAT_CLOUD_INTENSITY = 8 }
    local realCM = getClimateManager
    getClimateManager = function() return { getClimateFloat = function(_, id) return float(id) end } end
    H.ok(S().use(p, "ray", {}))
    H.eq(S().status("ray", StoryEngine.Store.player(q)).reason, "world_active", "no stacking")
    H.ok(not admin[3], "not raining yet")
    tick(36 * 60)
    H.eq(admin[3], false, "rained and stopped within a day and a half")
    H.eq(#S().state().jobs, 0)
    getClimateManager = realCM
end

function T.refugees_clear_bodies_near_home()
    local p, ps = setup()
    ps.home = { x = 10000, y = 10000, z = 0 }
    ready(p, "pike", "refugees")
    local bodies = {}
    for i = 1, 12 do bodies[i] = {} end
    square(10005, 10003, 0, { bodies = bodies })
    H.ok(S().use(p, "pike", {}))
    tick(1)
    H.eq(#bodies, 2, "ten bodies per round")
    tick(10)
    H.eq(#bodies, 0)
end

function T.refugees_need_a_home()
    local p, ps = setup()
    ps.home = nil
    ready(p, "pike", "refugees")
    H.eq(S().status("pike", ps).reason, "no_home")
end

function T.tow_sends_a_truck_and_takes_it_back()
    local p, ps = setup()
    ready(p, "dewey", "tow")
    local car = H.newVehicle(10003, 10003, { { id = "Engine", cond = 10, engine = true } })
    local truck = H.newVehicle(0, 0, {})
    function truck:createVehicleKey() return nil end
    function truck:getPartById() return nil end
    function truck:getDriver() return nil end
    function truck:addPointConstraint(player, other, a, b) self.towing = { other, a, b } end
    function truck:permanentlyRemove() self.removed = true end
    function car:getDriver() return nil end
    IsoDirections = { N = "N" }
    addVehicleDebug = function(script, dir, skin, sq)
        truck.x, truck.y, truck.script = sq:getX(), sq:getY(), script
        return truck
    end
    H.ok(S().use(p, "dewey", {}))
    tick(130)
    H.eq(truck.script, "Base.PickUpTruck", "truck arrived")
    H.ok(truck.towing and truck.towing[1] == car and truck.towing[2] == "trailer", "hooked to the car")
    p.x, p.y = 20000, 20000                        -- 멀리 떠남
    tick(48 * 60)
    H.ok(truck.removed, "taken back after two days")
end

function T.reinforce_holds_part_condition()
    local p, ps = setup()
    ready(p, "dewey", "reinforce")
    local car = H.newVehicle(10002, 10002, { { id = "Door", cond = 80 } })
    H.ok(S().use(p, "dewey", {}))
    local fx = H.sentOf("spec2Fx")
    H.eq(fx[#fx].kind, "reinforce")
    H.eq(fx[#fx].vid, car:getId())
    car.parts[1].cond = 20
    tick(1)
    H.eq(car.parts[1].cond, 80, "repaired back")
end

function T.artillery_checks_the_spot_and_fires_later()
    local p, ps = setup()
    ready(p, "guard", "artillery")
    local ok, why = S().use(p, "guard", { x = 10300, y = 10000 })
    H.eq(why, "too_far")
    ok, why = S().use(p, "guard", { x = 10010, y = 10000 })
    H.eq(why, "too_close", "the player is 10 tiles away")
    local shells = 0
    IsoTrap = { new = function() return { place = function() end, triggerExplosion = function() shells = shells + 1 end } end }
    H.ok(S().use(p, "guard", { x = 10060, y = 10000 }))
    tick(9)
    H.eq(#H.sentOf("spec2Strike"), 0, "ten minutes out")
    tick(2)
    local strike = H.sentOf("spec2Strike")[1]
    H.ok(strike and strike.x == 10060 and strike.radius == 10)
    H.eq(shells, 3)
    H.ok(#H.sounds > 0, "very loud")
end

function T.evac_needs_a_far_home_and_server_anticheat()
    local p, ps = setup()
    ready(p, "guard", "evac")
    ps.home = { x = 10050, y = 10000, z = 0 }
    local ok, why = S().use(p, "guard", {})
    H.eq(why, "home_near")
    ps.home = { x = 10500, y = 10000, z = 0 }
    H.ok(S().use(p, "guard", {}))
    tick(21)
    local tp = H.sentOf("spec2Teleport")[1]
    H.ok(tp and tp.x == 10500, "flown home")
    -- 멀티: 속도 안티치트가 강퇴(2)면 막힌다
    local realServer = isServer
    isServer = function() return true end
    getServerOptions = function() return { getInteger = function() return 2 end } end
    H.eq(S().status("guard", ps).reason, "anticheat")
    getServerOptions = function() return { getInteger = function() return 4 end } end
    H.ok(S().teleportAllowed())
    isServer = realServer
end

function T.barricade_needs_to_be_near_home()
    local p, ps = setup()
    ready(p, "guard", "barricade")
    ps.home = nil
    H.eq(S().status("guard", ps).reason, "no_home")
    ps.home = { x = 10500, y = 10000, z = 0 }
    local ok, why = S().use(p, "guard", {})
    H.eq(why, "not_home")
end

local function building(names, area)
    local rooms = {}
    for _, n in ipairs(names) do
        local r = {}
        function r:getName() return n end
        function r:getArea() return area or 50 end
        rooms[#rooms + 1] = r
    end
    local def = {}
    function def:getRooms() return H.list(rooms) end
    function def:getX() return 10100 end
    function def:getY() return 10100 end
    function def:getX2() return 10110 end
    function def:getY2() return 10110 end
    return def
end

function T.heist_target_rules()
    setup()
    H.eq(select(2, S().heistTarget(1, 1)), "no_building")
    grid.buildingAt = function() return building({ "gunstore", "office" }) end
    H.eq(select(2, S().heistTarget(10105, 10105)), "guarded_building")
    grid.buildingAt = function() return building({ "kitchen" }, 2000) end
    H.eq(select(2, S().heistTarget(10105, 10105)), "big_building")
    grid.buildingAt = function() return building({ "kitchen", "bedroom" }) end
    H.ok(S().heistTarget(10105, 10105), "an ordinary house")
end

function T.heist_rolls_loot_takes_a_cut_and_empties_the_building()
    local p, ps = setup()
    ready(p, "rats", "heist")
    grid.buildingAt = function() return building({ "kitchen" }) end
    SuburbsDistributions = { kitchen = { counter = { procedural = true, procList = { { name = "KitchenStuff" } } } } }
    ProceduralDistributions = { list = { KitchenStuff = { rolls = 4, items = { "TinnedBeans", 100, "Base.Pot", 100 } } } }
    H.defineItem("Base.TinnedBeans", "food", 1.5)
    H.defineItem("Base.Pot", "tools", 2)
    H.ok(S().use(p, "rats", { x = 10105, y = 10105 }))
    local ok, why = S().use(p, "rats", { x = 10105, y = 10105 })
    H.eq(why, "cooldown")
    tick(10 * 60 + 1)
    local found
    for _, q in pairs(StoryEngine.Store.data().quests) do
        if q.origin and q.origin.spec2 == "heist" then found = q end
    end
    H.ok(found, "loot delivered")
    local loot = 0
    for _, it in ipairs(found.items) do if it ~= "StoryEngine.Letter" then loot = loot + 1 end end
    H.ok(loot >= 1 and loot <= 5, "six rolled, Vic kept about 30%: " .. tostring(loot))
    H.eq(select(2, S().heistTarget(10105, 10105)), "already_heisted")
    -- 나중에 로드되는 칸의 보관함은 비운다
    local cont = { items = { H.newItem("Base.Pot") }, explored = false }
    function cont:getItems() return H.list(self.items) end
    function cont:Remove(it) for i, x in ipairs(self.items) do if x == it then table.remove(self.items, i) end end end
    function cont:setExplored(v) self.explored = v end
    local obj = { mod = {} }
    function obj:getContainer() return cont end
    function obj:getContainerCount() return 1 end
    function obj:getContainerByIndex() return cont end
    function obj:getModData() return self.mod end
    local sq = square(10104, 10104, 0, { objs = { obj } })
    S().onLoadSquare(sq)
    H.eq(#cont.items, 0, "emptied")
    H.ok(cont.explored, "no fresh loot")
end

function T.rolling_a_room_uses_vanilla_tables()
    setup()
    SuburbsDistributions = { bedroom = { wardrobe = { procedural = true, procList = { { name = "Clothes", weightChance = 100 } } } } }
    ProceduralDistributions = { list = { Clothes = { rolls = 2, items = { "Base.Pot", 100 } } } }
    H.defineItem("Base.Pot", "tools", 2)
    local out = {}
    S().rollRoom("bedroom", out, 40)
    H.ok(#out >= 1, "rolled something")
    H.eq(out[1], "Base.Pot")
    local kept = S().takeCut({ "Base.Pot", "Base.Pot", "Base.Pot", "Base.Pot", "Base.Pot",
                               "Base.Pot", "Base.Pot", "Base.Pot", "Base.Pot", "Base.Pot" })
    H.eq(#kept, 7, "30% by value")
end

function T.camo_suppressor_and_flare_are_client_effects()
    local p, ps = setup()
    ready(p, "rats", "camo")
    H.ok(S().use(p, "rats", {}))
    local fx = H.sentOf("spec2Fx")
    H.eq(fx[#fx].kind, "camo")
    H.eq(fx[#fx].minutes, 4 * 60)
    S().camoEnd(p)
    fx = H.sentOf("spec2Fx")
    H.eq(fx[#fx].minutes, 0, "sprinting or attacking breaks it for everyone")
    ready(p, "hunter", "suppressor")
    H.ok(S().use(p, "hunter", {}))
    fx = H.sentOf("spec2Fx")
    H.eq(fx[#fx].kind, "suppressor")
    -- 다시 접속해도 이어지게 10분마다 다시 알린다
    local n = #H.sentOf("spec2Fx")
    tick(11)
    H.ok(#H.sentOf("spec2Fx") > n, "resent")
end

return T
