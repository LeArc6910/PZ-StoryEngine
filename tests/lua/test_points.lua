-- 품목 점수 부탁 (2026-10-04 사용자 결정): 음식처럼 종류가 많은 품목은 특정 물건 대신 "음식 가치 N점"으로 받는다
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
    local V = H.defineItem
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

local function ask(p, ps, items)
    local q = StoryEngine.Quests.proposeCustom(p, ps, "doc", { tier = 1, why = "hungry patients", items = items },
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
    local need = StoryEngine.Quests.pointsNeed({ { "Base.TinnedBeans", 3 }, { "Base.Pills", 2 } })
    H.eq(need[1][1], "Base.Pills", "other categories stay as items")
    H.eq(need[2][1], "cat:food")
    H.eq(need[2][2], 5, "3 cans x 1.5 = 4.5, rounded up")
    H.ok(string.find(StoryEngine.Quests.needText({ need = need }), "food of any kind", 1, true), "AI hears it as any food")
end

function T.melee_and_guns_become_points_but_ammo_stays()
    setup()
    local need = StoryEngine.Quests.pointsNeed({ { "Base.HuntingRifle", 1 }, { "Base.308Box", 1 }, { "Base.HuntingKnife", 1 } })
    local by = {}
    for _, n in ipairs(need) do by[n[1]] = n[2] end
    H.eq(by["Base.308Box"], 1, "ammo stays a specific item (the caliber matters)")
    H.eq(by["cat:firearm"], 40)
    H.eq(by["cat:melee"], 8)
end

function T.any_gun_worth_the_points_is_accepted()
    local p, ps = setup()
    local q = ask(p, ps, { { "Base.HuntingRifle", 1 } })
    H.eq(q.need[1][1], "cat:firearm")
    H.give(p, "Base.Pistol")
    local ok = StoryEngine.Quests.submit(p, q.id)
    H.ok(not ok, "one pistol (30) is not worth a hunting rifle (40)")
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
    H.ok(StoryEngine.Quests.submit(p, q.id), "chili and crisps cover 5 points")
    H.eq(q.state, "completed")
    H.eq(count(p, "Base.CannedChili") + count(p, "Base.Crisps"), 0, "all of it went (5 points exactly)")
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
    H.eq(count(p, "Base.CannedChili"), 0, "the chosen cans went")
end

function T.not_enough_food_is_refused()
    local p, ps = setup()
    local q = ask(p, ps, { { "Base.TinnedBeans", 3 } })
    H.give(p, "Base.Crisps")
    local ok, why = StoryEngine.Quests.submit(p, q.id)
    H.ok(not ok and why == "missing_items")
    H.eq(count(p, "Base.Crisps"), 1)
end

return T
