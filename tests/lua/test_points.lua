-- 품목 점수 부탁 (2026-10-04 사용자 결정, 2026-10-05 확장): NPC 가 먼저 하는 부탁은 특정 물건 대신 "음식 가치 N점"처럼
-- 받는다 (자재는 그대로). 샌드박스 점수 배율(기본 1.5)·등급 하한(기본 부탁 등급-1).
-- 2026-10-06: 등급이 있으면 요구량은 등급별 기준(Quests.POINT_BASE)을 따르고, 하한은 청한 물건의 등급을 넘지 않는다
local T = {}

-- 플레이어(10000,10000) 둘레에 건물 고리 (등급 1·2 거리)
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

local function setup()
    mockBuildings()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    SandboxVars.StoryEngine.RequestPointsMult = 1     -- 아래 예전 테스트는 배율·하한 없이
    SandboxVars.StoryEngine.RequestMinTier = 1
    local V = H.defineItem
    V("Base.NailsBox", "misc", 0.2)
    V("Base.TinnedBeans", "food", 1.5)
    V("Base.CannedChili", "food", 1.5)
    V("Base.Crisps", "food", 0.5)
    V("Base.Pills", "medical", 4)
    V("Base.HuntingKnife", "melee", 8)
    V("Base.HuntingRifle", "firearm", 40)
    V("Base.Pistol", "firearm", 30)
    V("Base.308Box", "ammo", 20)
    return p, ps
end

local function ask(p, ps, items, tier)
    local q = StoryEngine.Quests.proposeCustom(p, ps, "doc", { tier = tier or 1, why = "hungry patients", items = items },
        StoryEngine.Sensor.now(), { silent = true })
    q.state = "accepted"
    return q
end

local function count(p, ft)
    local n = 0
    for _, it in ipairs(p.items) do if it.fullType == ft then n = n + 1 end end
    return n
end

function T.food_items_become_category_points()
    setup()
    local need = StoryEngine.Quests.pointsNeed({ { "Base.TinnedBeans", 3 }, { "Base.NailsBox", 2 } })
    H.eq(need[1][1], "Base.NailsBox", "materials stay as items")
    H.eq(need[2][1], "cat:food")
    H.eq(need[2][2], 5, "3 cans x 1.5 = 4.5, rounded up")
    H.ok(string.find(StoryEngine.Quests.needText({ need = need }), "food of any kind", 1, true), "AI hears it as any food")
end

function T.melee_guns_medical_and_ammo_become_points()
    setup()
    H.defineItem("Base.308Box", "ammo", 20, 4)
    local need = StoryEngine.Quests.pointsNeed({ { "Base.HuntingRifle", 1 }, { "Base.308Box", 1 }, { "Base.HuntingKnife", 1 },
                                                 { "Base.Pills", 2 } })
    local by, min = {}, {}
    for _, n in ipairs(need) do
        by[n[1]] = n[2]
        min[n[1]] = n[3]
    end
    H.eq(by["cat:ammo"], 20)
    H.eq(min["cat:ammo"], 4, "ammo of the requested caliber tier or better")
    H.eq(by["cat:firearm"], 40)
    H.eq(by["cat:melee"], 8)
    H.eq(by["cat:medical"], 8)
end

function T.default_difficulty_multiplies_and_sets_a_minimum_tier()
    setup()
    SandboxVars.StoryEngine.RequestPointsMult = nil
    SandboxVars.StoryEngine.RequestMinTier = nil
    local need = StoryEngine.Quests.pointsNeed({ { "Base.TinnedBeans", 3 } }, 3)
    H.eq(need[1][2], 18, "tier 3 food base 12 x 1.5")
    H.eq(need[1][3], 2, "tier 3 request: tier 2 or better")
    H.eq(StoryEngine.Quests.pointMinTier("medical", 5), 3, "medical only goes to tier 3")
    H.eq(StoryEngine.Quests.pointMinTier("comfort", 5), nil, "comforts have no tier")
    H.eq(StoryEngine.Quests.pointMinTier("food", 2), nil, "tier 1 minimum is no minimum")
    SandboxVars.StoryEngine.RequestMinTier = 4
    H.eq(StoryEngine.Quests.pointMinTier("food", 3), 3, "request tier or better")
    SandboxVars.StoryEngine.RequestMinTier = 1
    H.eq(StoryEngine.Quests.pointMinTier("food", 5), nil, "off")
    local plain = StoryEngine.Quests.pointsNeed({ { "Base.TinnedBeans", 3 } }, 3, true)
    H.eq(plain[1][2], 5, "plain requests skip the multiplier and the tier scale (3 x 1.5 = 4.5)")
end

function T.minimum_tier_filters_cheap_items()
    local p, ps = setup()
    H.defineItem("Base.Crisps", "food", 0.5, 1)
    H.defineItem("Base.CannedChili", "food", 1.5, 2)
    local q = ask(p, ps, { { "Base.TinnedBeans", 2 } })
    q.need = { { "cat:food", 3, 2 } }
    for _ = 1, 10 do H.give(p, "Base.Crisps") end
    local ok, why = StoryEngine.Quests.submit(p, q.id)
    H.ok(not ok and why == "missing_items", "ten tier-1 snacks do not count")
    for _ = 1, 2 do H.give(p, "Base.CannedChili") end
    H.ok(StoryEngine.Quests.submit(p, q.id), "tier-2 food does")
    H.eq(count(p, "Base.Crisps"), 10, "the snacks stay")
end

function T.electronics_vehicle_and_comforts_have_points()
    setup()
    H.defineItem("Base.Generator", "misc", 20)
    H.defineItem("Base.CarBattery1", "misc", 14)
    H.defineItem("Base.CigarettePack", "misc", 0.2)
    local V = StoryEngine.Value
    H.eq(V.pointKind("Base.Generator"), "electronics")
    H.eq(V.pointTier("Base.Generator"), 5)
    H.eq(V.pointKind("Base.CarBattery1"), "vehicle")
    H.eq(V.pointKind("Base.CigarettePack"), "comfort")
    H.eq(V.pointOf("Base.CigarettePack"), 2, "comforts use their comfort value")
    H.eq(V.pointKind("Base.NailsBox"), nil)
    -- 둘을 섞으면 무게(가치 / 기준)로 등급 기준을 나눈다: 기호품 4/22, 전자기기 20/32
    local need = StoryEngine.Quests.pointsNeed({ { "Base.CigarettePack", 2 }, { "Base.Generator", 1 } }, 5)
    local by = {}
    for _, n in ipairs(need) do by[n[1]] = n[2] end
    H.eq(by["cat:comfort"], 5, "22 x 0.18 / 0.81")
    H.eq(by["cat:electronics"], 25, "32 x 0.63 / 0.81")
end

function T.any_gun_worth_the_points_is_accepted()
    local p, ps = setup()
    local q = ask(p, ps, { { "Base.HuntingRifle", 1 } }, 3)
    H.eq(q.need[1][1], "cat:firearm")
    H.eq(q.need[1][2], 34, "tier 3 firearm base")
    H.give(p, "Base.Pistol")
    local ok = StoryEngine.Quests.submit(p, q.id)
    H.ok(not ok, "one pistol (30) is not worth a tier 3 gun request (34)")
    H.give(p, "Base.Pistol")
    H.ok(StoryEngine.Quests.submit(p, q.id), "two pistols are")
    H.eq(count(p, "Base.Pistol"), 0)
end

function T.any_food_worth_the_points_is_accepted()
    local p, ps = setup()
    local q = ask(p, ps, { { "Base.TinnedBeans", 3 } })
    H.eq(q.need[1][1], "cat:food", "the request asks for food points")
    for _ = 1, 2 do H.give(p, "Base.CannedChili") end
    for _ = 1, 4 do H.give(p, "Base.Crisps") end
    H.eq(q.need[1][2], 4, "tier 1 food base")
    H.ok(StoryEngine.Quests.submit(p, q.id), "chili and crisps cover 4 points")
    H.eq(q.state, "completed")
end

function T.chosen_items_must_cover_the_points()
    local p, ps = setup()
    local q = ask(p, ps, { { "Base.TinnedBeans", 3 } })
    local ids = {}
    for _ = 1, 4 do ids[#ids + 1] = H.give(p, "Base.CannedChili"):getID() end
    local ok, why = StoryEngine.Quests.submit(p, q.id, { ids[1], ids[2] })
    H.ok(not ok and why == "missing_items", "3 points is not enough")
    H.eq(count(p, "Base.CannedChili"), 4, "nothing taken when short")
    H.ok(StoryEngine.Quests.submit(p, q.id, ids))
    H.eq(count(p, "Base.CannedChili"), 1, "only as many chosen cans as the 4 points need")
end

function T.not_enough_food_is_refused()
    local p, ps = setup()
    local q = ask(p, ps, { { "Base.TinnedBeans", 3 } })
    H.give(p, "Base.Crisps")
    local ok, why = StoryEngine.Quests.submit(p, q.id)
    H.ok(not ok and why == "missing_items")
    H.eq(count(p, "Base.Crisps"), 1)
end

function T.points_follow_the_tier_scale()
    setup()
    local Q = StoryEngine.Quests
    for t = 1, 5 do
        H.eq(Q.pointsNeed({ { "Base.TinnedBeans", 3 } }, t)[1][2], Q.POINT_BASE.food[t], "food tier " .. t)
        H.eq(Q.pointsNeed({ { "Base.Pills", 9 } }, t)[1][2], Q.POINT_BASE.medical[t], "the count does not matter")
    end
    -- 자재와 섞이면 자재 몫만큼 줄어든다: 의약품 4/8, 못 상자 2 x 4/8
    local need = Q.pointsNeed({ { "Base.Pills", 1 }, { "Base.NailsBox", 2 } }, 2)
    H.eq(need[1][1], "Base.NailsBox")
    H.eq(need[2][2], 3, "8 x 0.5 / 1.5 = 2.7")
end

function T.minimum_tier_never_above_the_requested_items()
    setup()
    SandboxVars.StoryEngine.RequestMinTier = nil      -- 기본: 부탁 등급 -1
    H.defineItem("Base.Hammer", "tools", 2, 1)
    H.defineItem("Base.Sledgehammer", "tools", 20, 5)
    local Q = StoryEngine.Quests
    H.eq(Q.pointsNeed({ { "Base.Sledgehammer", 1 } }, 4)[1][3], 3, "tier 4 request: tier 3 or better")
    H.eq(Q.pointsNeed({ { "Base.Hammer", 1 } }, 4)[1][3], nil, "a hammer (tier 1) is always enough to count")
    H.eq(Q.pointsNeed({ { "Base.Sledgehammer", 1 }, { "Base.Hammer", 1 } }, 5)[1][3], nil, "the lowest item sets it")
end

function T.batteries_stay_items_candles_are_comforts_firewood_is_a_material()
    setup()
    H.defineItem("Base.Battery", "misc", 2)
    H.defineItem("Base.Candle", "misc", 2)
    local V = StoryEngine.Value
    H.eq(V.pointKind("Base.Battery"), "comfort")
    H.eq(V.pointKind("Base.Candle"), "comfort")
    H.eq(V.pointOf("Base.Candle"), 0.5)
    -- 배터리는 기호품 점수로 낼 수는 있지만, 배터리를 청한 부탁은 배터리 그대로 받는다
    local bat = StoryEngine.Quests.pointsNeed({ { "Base.Battery", 3 } }, 1)
    H.eq(bat[1][1], "Base.Battery")
    H.eq(bat[1][2], 3)
    H.eq(StoryEngine.Quests.pointsNeed({ { "Base.Candle", 6 } }, 1)[1][1], "cat:comfort", "candles still become points")
    H.defineItem("Base.Firewood", "melee", 3, 1)
    H.ok(V.isRaw("Base.Firewood"), "firewood is a raw material")
    H.eq(V.pointKind("Base.Firewood"), nil, "not 'any melee weapon'")
    local need = StoryEngine.Quests.pointsNeed({ { "Base.Firewood", 6 } }, 2)
    H.eq(need[1][1], "Base.Firewood")
    H.eq(need[1][2], 6)
end

function T.item_mode_food_melee_guns_only()
    setup()
    SandboxVars.StoryEngine.RequestItemMode = 2
    local Q = StoryEngine.Quests
    local need = Q.pointsNeed({ { "Base.TinnedBeans", 3 }, { "Base.Pills", 1 } }, 2)
    H.eq(need[1][1], "Base.Pills", "medical stays the exact item")
    H.eq(need[1][2], 1)
    H.eq(need[2][1], "cat:food")
    H.eq(need[2][2], 5, "food base 8 x (4.5/8) / (4.5/8 + 4/8) = 4.2")
    H.eq(Q.pointsNeed({ { "Base.HuntingKnife", 1 } }, 3)[1][1], "cat:melee")
end

function T.item_mode_exact_items()
    local p, ps = setup()
    SandboxVars.StoryEngine.RequestItemMode = 3
    local Q = StoryEngine.Quests
    local need = Q.pointsNeed({ { "Base.TinnedBeans", 3 }, { "Base.HuntingRifle", 1 } }, 4)
    H.eq(need[1][1], "Base.TinnedBeans")
    H.eq(need[1][2], 3)
    H.eq(need[2][1], "Base.HuntingRifle")
    H.eq(Q.pointsNeed({ { "Base.TinnedBeans", 3 } }, 3, true)[1][1], "cat:food", "plain requests still take points")
    local q = ask(p, ps, { { "Base.TinnedBeans", 2 } })
    for _ = 1, 4 do H.give(p, "Base.CannedChili") end
    H.ok(not StoryEngine.Quests.submit(p, q.id), "other food does not count")
    for _ = 1, 2 do H.give(p, "Base.TinnedBeans") end
    H.ok(StoryEngine.Quests.submit(p, q.id), "the exact cans do")
end

return T
