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
    H.ok(H.logHas("specialty2 say ray rain_start"), "Ray says when it starts")
    H.ok(H.logHas("specialty2 say ray rain_stop"), "and when it stops")
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
    H.ok(H.logHas("specialty2 say dewey tow_here"), "Dewey says the truck is there")
    H.ok(not H.logHas("tow_here_"), "hooked and key handed over")
    p.x, p.y = 20000, 20000                        -- 멀리 떠남
    tick(48 * 60)
    H.ok(truck.removed, "taken back after two days")
    H.ok(H.logHas("specialty2 say dewey tow_soon"), "warned a few hours before")
    H.ok(H.logHas("specialty2 say dewey tow_back"))
end

function T.reinforce_holds_part_condition()
    local p, ps = setup()
    ready(p, "dewey", "reinforce")
    local car = H.newVehicle(10002, 10002, { { id = "Door", cond = 80 } })
    car.power, car.quality, car.loud = 200, 70, 50
    function car:getEnginePower() return self.power end
    function car:getEngineQuality() return self.quality end
    function car:getEngineLoudness() return self.loud end
    function car:setEngineFeature(q, l, pw) self.quality, self.loud, self.power = q, l, pw end
    function car:transmitEngine() end
    H.ok(S().use(p, "dewey", {}))
    H.eq(car.power, 300, "engine power x1.5 while reinforced")
    local fx = H.sentOf("spec2Fx")
    H.eq(fx[#fx].kind, "reinforce")
    H.eq(fx[#fx].vid, car:getId())
    car.parts[1].cond = 20
    tick(1)
    H.eq(car.parts[1].cond, 80, "repaired back")
    tick(6 * 60 + 1)
    H.eq(car.power, 200, "power back to normal when it ends")
    H.eq(car.quality, 70)
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
    local realSH = SafeHouse
    SafeHouse = { hasSafehouse = function() return nil end }
    ps.home = { x = 10050, y = 10000, z = 0 }
    local ok, why = S().use(p, "guard", {})
    H.eq(why, "home_near")
    ps.home = { x = 10500, y = 10000, z = 0 }
    H.ok(S().use(p, "guard", {}))
    tick(21)
    local tp = H.sentOf("spec2Teleport")[1]
    H.ok(tp and tp.x == 10500, "flown home")
    H.eq(tp.rect, nil, "no safehouse, no rectangle")
    -- 세이프하우스가 있으면 그 사각형을 넘긴다 (클라이언트가 그 안의 빈 바닥을 고름)
    SafeHouse = { hasSafehouse = function() return { getX = function() return 10490 end, getY = function() return 9990 end,
                                                     getX2 = function() return 10510 end, getY2 = function() return 10010 end } end }
    S().clearWait("guard", ps.key)
    H.ok(S().use(p, "guard", {}))
    tick(21)
    local sent = H.sentOf("spec2Teleport")
    local tp2 = sent[#sent]
    H.ok(tp2.rect and tp2.rect[1] == 10490 and tp2.rect[4] == 10010, "safehouse rectangle")
    SafeHouse = realSH
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
    -- 디버그: 예약을 지금 바로 (기다리지 않고 받는다)
    local before = #p.items
    H.eq(S().debugRushJobs(ps.key), 1)
    local loot = #p.items - before
    H.ok(loot >= 1 and loot <= 6, "straight into the inventory, minus Vic's cut: " .. tostring(loot))
    H.ok(H.logHas("specialty2 heist done"), "logged with value and cut")
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
    -- 큰 수확일수록 몫이 커진다 (누진): 가치 100 이면 빅이 56, 남는 것 44
    local many = {}
    for i = 1, 50 do many[i] = "Base.Pot" end
    local kept2, total, taken = S().takeCut(many)
    H.eq(total, 100)
    H.eq(taken, 56)
    H.eq(#kept2, 22)
    H.eq(S().cutOf(200), 6 + 15 + 35 + 85)
    -- 비싼 것부터가 아니라 무작위로 집는다 (2026-10-10): 순서에 따라 산탄총이 남기도 한다
    H.defineItem("Base.Shotgun", "firearm", 60)
    local haul = { "Base.Shotgun", "Base.Pot", "Base.Pot", "Base.Pot", "Base.Pot", "Base.Pot",
                   "Base.Pot", "Base.Pot", "Base.Pot", "Base.Pot", "Base.Pot" }
    H.rolls = { 0, 9, 8, 7, 6, 5, 4, 3, 2, 1 }           -- 섞은 순서: 산탄총이 맨 뒤
    local kept3, _, taken3 = S().takeCut(haul)
    H.eq(#kept3, 1, "something is always left")
    H.eq(kept3[1], "Base.Shotgun", "the shotgun stayed with the player")
    H.eq(taken3, 20)
    H.rolls = { 10, 9, 8, 7, 6, 5, 4, 3, 2, 1 }          -- 섞은 순서 그대로: 산탄총이 맨 앞
    local kept4, _, taken4 = S().takeCut(haul)
    H.eq(#kept4, 10, "this time Vic picked the shotgun and nothing else")
    H.eq(taken4, 60)
    -- 여러 번 굴리면 산탄총이 남는 때도, 가져가는 때도 있다
    local left, gone = 0, 0
    for _ = 1, 60 do
        local has = false
        for _, ft in ipairs(S().takeCut(haul)) do if ft == "Base.Shotgun" then has = true end end
        if has then left = left + 1 else gone = gone + 1 end
    end
    H.ok(left > 5 and gone > 5, "random either way: left " .. left .. " gone " .. gone)
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


function T.livestock_is_mostly_hens_and_says_which_animal()
    local p, ps = setup()
    ready(p, "ray", "livestock")
    -- 묶음 확률: 0~79 닭, 80~89 돼지, 90~99 소
    H.rolls = { 10 }
    H.eq(S().pickKit().say, "hens")
    H.rolls = { 85 }
    H.eq(S().pickKit().say, "pig")
    H.rolls = { 95 }
    H.eq(S().pickKit().say, "cow")
    local made = {}
    addAnimal = function(_, x, y, z, kind) made[#made + 1] = kind return { addToWorld = function() end } end
    H.rolls = { 85 }
    local ok, info = S().HANDLERS.livestock(p, ps, "ray", {})
    H.ok(ok)
    H.eq(info.say, "pig", "the radio line names the animal")
    H.eq(made[1], "sow")
    H.ok(string.find(info.topic, "a sow", 1, true), "AI is told which animal")
end

function T.scan_reports_the_spot_before_firing()
    local p, ps = setup()
    ready(p, "guard", "artillery")
    local info = S().scan(p, "guard", 10500, 10000)
    H.eq(info.reason, "too_far", "past 240 tiles")
    H.eq(S().scan(p, "guard", 10200, 10000).reason, nil, "200 tiles is in range now")
    H.ok(not info.ok)
    info = S().scan(p, "guard", 10005, 10000)
    H.eq(info.reason, "too_close", "the player is standing there")
    H.newZombie(10063, 10000)
    H.newZombie(10058, 10004)
    H.newZombie(10090, 10000)
    info = S().scan(p, "guard", 10060, 10000)
    H.ok(info.ok, tostring(info.reason))
    H.eq(info.zombies, 2, "zombies within 10 tiles")
    H.ok(H.logHas("specialty2 scan"))
    -- 레이더 지도: 내 자리 기준 좀비·다른 사람 점, 불러진 칸 표
    local q = H.addPlayer("other", "Mia", "Lee")
    q.x, q.y = 10020, 9990
    H.newZombie(10400, 10000)
    local radar = S().radar(p, "guard", 240)
    H.eq(radar.cx, 10000)
    H.eq(radar.range, 240, "artillery range for the circle")
    H.eq(radar.total, 3, "the zombie 400 tiles out is not on it")
    local seen = {}
    for i = 1, #radar.zx do seen[radar.zx[i] .. "," .. radar.zy[i]] = true end
    H.ok(seen["63,0"] and seen["58,4"] and seen["90,0"])
    H.eq(#radar.px, 1, "the other player, not me")
    H.eq(radar.px[1], 20)
    H.eq(radar.py[1], -10)
    H.eq(#radar.grid, radar.n * radar.n)
    H.eq(#S().radar(p, "guard", 60).zx, 1, "a 60-tile view keeps only the one 58 tiles out")
    H.eq(info.nearest, 60)
    H.eq(info.opt, "artillery")
end

function T.engineers_also_repair_walls_fences_and_windows()
    local p, ps = setup()
    ready(p, "guard", "barricade")
    ps.home = { x = 10105, y = 10105, z = 0 }
    p.x, p.y = 10105, 10105
    local room = {}
    function room:getZ() return 0 end
    function room:getX() return 10100 end
    function room:getY() return 10100 end
    function room:getX2() return 10110 end
    function room:getY2() return 10110 end
    function room:getName() return "kitchen" end
    local def = {}
    function def:getRooms() return H.list({ room }) end
    grid.buildingAt = function() return def end
    IsoObjectChange = { STATE = "STATE" }
    local fence = { __classes = { IsoThumpable = true }, hp = 40, max = 100 }
    function fence:getHealth() return self.hp end
    function fence:getMaxHealth() return self.max end
    function fence:setHealth(v) self.hp = v end
    function fence:syncIsoObject() end
    local glass = { __classes = { IsoWindow = true }, smashed = true }
    function glass:isSmashed() return self.smashed end
    function glass:isGlassRemoved() return false end
    function glass:setSmashed(v) self.smashed = v end
    function glass:setGlassRemoved() end
    function glass:isBarricaded() return true end
    function glass:syncIsoObject() self.synced = true end
    square(10095, 10095, 0, { objs = { fence } })
    square(10100, 10103, 0, { objs = { glass } })
    H.ok(S().use(p, "guard", {}), "repairs count even with no opening left to barricade")
    H.eq(fence.hp, 100, "fence repaired")
    H.eq(glass.smashed, false, "window re-glazed")
    H.ok(glass.synced, "clients told")
    H.ok(H.logHas("specialty2 repair around home"))
end


function T.debug_max_all_readies_every_npc()
    local p, ps = setup()
    StoryEngine.Fate.apply("pike", "gone", "debug")
    StoryEngine.Commands.debugMaxAll(p, {})
    for _, fid in ipairs({ "ray", "casey", "doc", "dewey", "guard", "rats", "hunter" }) do
        H.eq(StoryEngine.Radio.channel(fid).trust, 100, fid .. " trust")
        H.eq(StoryEngine.Life.npc(fid).res.food, 100, fid .. " resources")
        H.ok(StoryEngine.Projects.done(fid) and StoryEngine.Projects.done2(fid), fid .. " both projects")
        H.eq(S().status(fid, ps).reason, "no_choice", fid .. " second specialty unlocked, waiting for a pick")
    end
    H.ok(StoryEngine.Radio.channel("pike").trust < 100, "NPCs who left are skipped")
    -- 쓴 뒤 다시 누르면 대기도 풀린다
    H.ok(S().choose(p, "hunter", "game"))
    H.ok(S().use(p, "hunter", {}))
    H.eq(S().status("hunter", ps).reason, "cooldown")
    StoryEngine.Commands.debugMaxAll(p, {})
    H.eq(S().status("hunter", ps).reason, nil, "wait cleared")
end


function T.heist_follows_sandbox_loot_rarity_and_loot_remover()
    setup()
    SuburbsDistributions = { kitchen = { counter = { procedural = true, procList = { { name = "KitchenStuff" } } } } }
    ProceduralDistributions = { list = { KitchenStuff = { rolls = 20, items = { "TinnedBeans", 100, "Base.Pot", 100 } } } }
    H.defineItem("Base.TinnedBeans", "food", 1.5)
    H.defineItem("Base.Pot", "tools", 2)
    -- 샌드박스에서 음식 루팅을 없애면 (배율 0) 콩은 안 나온다
    ItemPickerJava = { getLootModifier = function(name) return name == "TinnedBeans" and 0 or 1 end }
    local out = {}
    S().rollRoom("kitchen", out, 40)
    H.ok(#out > 0)
    for _, ft in ipairs(out) do H.ok(ft ~= "Base.TinnedBeans", "food loot off in the sandbox") end
    ItemPickerJava = nil
    -- LootRemover 100%면 모두 지워지고, 없으면 그대로
    local items = { "Base.Pot", "Base.Pot", "Base.Pot" }
    local kept, removed = S().lootRemover(items)
    H.eq(#kept, 3, "no LootRemover installed")
    LootRemover = { getChance = function() return 100 end, affectContainers = function() return true end }
    kept, removed = S().lootRemover(items)
    H.eq(#kept, 0)
    H.eq(removed, 3)
    LootRemover.affectContainers = function() return false end
    kept = S().lootRemover(items)
    H.eq(#kept, 3, "LootRemover set to skip containers")
    LootRemover = nil
end


function T.engineers_hang_a_wooden_door_in_an_empty_outer_frame()
    setup()
    local room = {}
    function room:getX() return 10100 end
    function room:getY() return 10100 end
    function room:getX2() return 10110 end
    function room:getY2() return 10110 end
    local def = {}
    function def:getRooms() return H.list({ room }) end
    IsoObjectType = { doorFrN = "doorFrN", doorFrW = "doorFrW" }
    local function frame(t)
        local f = {}
        function f:getType() return t end
        function f:getSprite() return nil end
        return f
    end
    local made = {}
    IsoDoor = { new = function(_, sq, sprite, north)
        local d = { __classes = { IsoDoor = true }, sprite = sprite, north = north }
        function d:getNorth() return self.north end
        function d:transmitCompleteItemToClients() self.sent = true end
        made[#made + 1] = d
        return d
    end }
    -- 바깥 문틀 (안쪽 칸은 방, 북쪽 칸은 바깥) 에 문이 없음
    local inside = square(10105, 10100, 0, { objs = { frame("doorFrN") }, room = {} })
    function inside:AddSpecialObject(o) table.insert(self.objs, o) end
    square(10105, 10099, 0, {})
    -- 안쪽 통로 문틀 (양쪽 다 방) 은 그대로
    local hall = square(10103, 10105, 0, { objs = { frame("doorFrW") }, room = {} })
    function hall:AddSpecialObject(o) table.insert(self.objs, o) end
    square(10102, 10105, 0, { room = {} })
    local n = S().rebuildDoors(def)
    H.eq(n, 1)
    H.eq(made[1].sprite, "fixtures_doors_01_1")
    H.ok(made[1].north and made[1].sent, "north door, sent to clients")
    H.eq(#hall.objs, 1, "inner doorway left alone")
    H.eq(S().rebuildDoors(def), 0, "a door is there now")
end

-- ---- 전·후 멘트 (2026-10-10 사용자 요청)

local SAY = "IGUI_StoryEngine_RadioSay_spec2_"
local function overheadOf(stage)
    local found = nil
    for _, o in ipairs(H.sentOf("radioOverhead")) do
        if o.lt and o.lt.key == SAY .. stage then found = o end
    end
    return found
end

-- 기다리는 무전 요청을 모두 실패시킨다 (AI 없음: 준비된 문장이 나간다)
local function failRadio()
    for _ = 1, 20 do
        local any = false
        for i = 1, #H.bridge do
            local b = H.bridge[i]
            if b.module == "radio" and not b.failed then
                b.failed, any = true, true
                b.callback({ ok = false, error = "timeout" })
            end
        end
        if not any then break end
        H.fire("EveryOneMinute")
    end
end

function T.artillery_reports_impact_or_a_scrubbed_mission()
    local p, ps = setup()
    ready(p, "guard", "artillery")
    IsoTrap = { new = function() return { place = function() end, triggerExplosion = function() end } end }
    H.ok(S().use(p, "guard", { x = 10060, y = 10000 }))
    tick(11)
    H.ok(H.logHas("specialty2 say guard artillery_done"), "impact confirmed on the radio")
    failRadio()
    H.ok(overheadOf("artillery"), "the line when the request is taken")
    H.ok(overheadOf("artillery_done"), "the prepared line when the AI is away")
    -- 표적 옆에 사람이 있으면 취소하고 알린다, 대기는 돌려준다
    S().clearWait("guard", ps.key)
    H.ok(S().use(p, "guard", { x = 10060, y = 10000 }))
    p.x = 10055
    tick(30)
    H.ok(H.logHas("specialty2 say guard artillery_off"))
    H.eq(S().status("guard", ps).reason, nil, "wait refunded")
end

function T.heist_says_what_came_back_and_the_cut()
    local p, ps = setup()
    ready(p, "rats", "heist")
    grid.buildingAt = function() return building({ "kitchen" }) end
    SuburbsDistributions = { kitchen = { counter = { procedural = true, procList = { { name = "KitchenStuff" } } } } }
    ProceduralDistributions = { list = { KitchenStuff = { rolls = 4, items = { "TinnedBeans", 100, "Base.Pot", 100 } } } }
    H.defineItem("Base.TinnedBeans", "food", 1.5)
    H.defineItem("Base.Pot", "tools", 2)
    H.ok(S().use(p, "rats", { x = 10105, y = 10105 }))
    local before = #p.items
    H.eq(S().debugRushJobs(ps.key), 1)
    H.ok(H.logHas("specialty2 say rats heist_done"))
    failRadio()
    local o = overheadOf("heist_done")
    H.ok(o, "prepared line")
    H.eq(o.lt.args[1].v, #p.items - before, "how many things were handed over")
    H.ok(o.lt.args[2].v >= 0 and o.lt.args[2].v <= 100, "Vic's cut in percent")
end

function T.heist_with_nothing_to_carry_says_so()
    local p, ps = setup()
    ready(p, "rats", "heist")
    grid.buildingAt = function() return building({ "kitchen" }) end
    SuburbsDistributions = { kitchen = {} }
    ProceduralDistributions = { list = {} }
    H.ok(S().use(p, "rats", { x = 10105, y = 10105 }))
    H.eq(S().debugRushJobs(ps.key), 1)
    H.ok(H.logHas("specialty2 say rats heist_empty"))
    H.ok(not H.logHas("specialty2 say rats heist_done"))
end

function T.evac_confirms_the_landing()
    local p, ps = setup()
    ready(p, "guard", "evac")
    local realSH = SafeHouse
    SafeHouse = { hasSafehouse = function() return nil end }
    ps.home = { x = 10500, y = 10000, z = 0 }
    H.ok(S().use(p, "guard", {}))
    tick(21)
    SafeHouse = realSH
    H.ok(H.logHas("specialty2 say guard evac_done"))
end

function T.lasting_effects_say_when_they_end()
    local p, ps = setup()
    ready(p, "rats", "camo")
    H.ok(S().use(p, "rats", {}))
    S().camoEnd(p)
    tick(1)
    H.ok(overheadOf("camo_broken"), "blown cover is not a timeout")
    H.eq(overheadOf("camo_end"), nil)
    S().clearWait("rats", ps.key)
    H.ok(S().use(p, "rats", {}))
    tick(4 * 60 + 1)
    H.ok(overheadOf("camo_end"), "worn off")
    ready(p, "hunter", "flare")
    H.ok(S().use(p, "hunter", {}))
    tick(6 * 60 + 1)
    H.ok(overheadOf("flare_end"))
    -- 피난민 일손: 치운 시신 수를 말한다
    ps.home = { x = 10000, y = 10000, z = 0 }
    ready(p, "pike", "refugees")
    square(10005, 10003, 0, { bodies = { {}, {}, {} } })
    H.ok(S().use(p, "pike", {}))
    tick(24 * 60 + 1)
    local o = overheadOf("refugees_end")
    H.ok(o, "the hands came back")
    H.eq(o.lt.args[1].v, 3)
    -- 머리 위에만 뜬다: 무전 요청은 만들지 않는다
    H.ok(not H.logHas("specialty2 say pike"))
end

function T.engineers_and_pike_put_real_numbers_and_names_in_the_line()
    local p, ps = setup()
    ready(p, "pike", "reconcile")
    for _, f in ipairs(StoryEngine.Factions.list) do StoryEngine.Radio.channel(f.id).trust = 60 end
    StoryEngine.Radio.channel("pike").trust = 85
    StoryEngine.Radio.channel("rats").trust = 12
    StoryEngine.Life.npc("rats").counts = StoryEngine.Life.npc("rats").counts or {}
    H.ok(S().use(p, "pike", {}))
    failRadio()
    local o = overheadOf("reconcile")
    H.ok(o and o.lt.args[1].t == "npc" and o.lt.args[1].v == "rats", "names who was reconciled")
end

return T
