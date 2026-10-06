-- 마굴 거르기 (Danger.lua): 지역 안 좀비 밀집도 순위로 보상 보급은 아래 50%, 위치 퀘스트는 아래 70% 건물만 (2026-10-07)
-- 은신처 둘레 (Hunt.pushOut): 추적 무리는 세이프하우스 둘레 SafehouseRadius 타일 안에서 생기지 않는다
local T = {}

-- 20 개 건물이 50 타일 간격, 밀집도 = (x - 10000) / 50 (건물 i 의 밀집도 = i)
local function mockMap()
    local defs = {}
    for i = 0, 19 do
        local x, y = 10000 + i * 50, 10000
        local def = {}
        function def:getX() return x end
        function def:getY() return y end
        function def:getX2() return x + 9 end
        function def:getY2() return y + 9 end
        defs[#defs + 1] = def
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
    function grid:getChunkDataFromTile(x, y)
        local chunk = {}
        function chunk:getUnadjustedZombieIntensity() return math.max(0, math.floor((x - 10000) / 50)) end
        return chunk
    end
    function grid:getBuildingAt() return nil end
    local world = {}
    function world:getMetaGrid() return grid end
    getWorld = function() return world end
    return defs
end

function T.hotspots_are_left_out_by_local_rank()
    H.addPlayer("tester", "Gerald", "Kar")
    local defs = mockMap()
    local D = StoryEngine.Danger
    D.cache, D.byBuilding = {}, {}
    D.REGION_CELL, D.REGION = 2000, 1500
    H.eq(D.ofBuilding(defs[6]), 5, "a building's density")
    H.ok(D.allowed(defs[10], D.KEEP_REWARD), "density 9: lower half")
    H.ok(not D.allowed(defs[12], D.KEEP_REWARD), "density 11: upper half, no rewards here")
    H.ok(D.allowed(defs[12], D.KEEP_QUEST), "but fine for a quest (lower 70%)")
    H.ok(not D.allowed(defs[18], D.KEEP_QUEST), "density 17: top 30%, no quests either")
    H.ok(D.allowed(defs[20], 1), "no filter")
    H.ok(StoryEngine.Quests.isPickupOrigin("supply_drop", { source = "reward" }))
    H.ok(not StoryEngine.Quests.isPickupOrigin("supply_drop", { source = "rescue" }), "rescue signals are tasks")
end

function T.unreadable_density_does_not_filter()
    H.addPlayer("tester", "Gerald", "Kar")
    local defs = mockMap()
    local grid = getWorld():getMetaGrid()
    grid.getChunkDataFromTile = nil
    local D = StoryEngine.Danger
    D.cache, D.byBuilding = {}, {}
    H.ok(D.allowed(defs[20], D.KEEP_REWARD), "no data: allowed")
end

function T.hunts_appear_outside_safehouses()
    H.addPlayer("tester", "Gerald", "Kar")
    local sh = {}
    function sh:getX() return 10000 end
    function sh:getY() return 10000 end
    function sh:getW() return 10 end
    function sh:getH() return 10 end
    SafeHouse = { getSafehouseList = function() return H.list({ sh }) end }
    local Hunt = StoryEngine.Hunt
    local x, y, moved = Hunt.pushOut(10020, 10005)
    H.ok(moved, "10 tiles from the house is inside the buffer")
    H.ok(x - 10010 >= 30, "pushed out to the buffer edge, east of the house")
    local x2, y2, moved2 = Hunt.pushOut(10100, 10005)
    H.ok(not moved2 and x2 == 10100, "far away: as is")
    SandboxVars.StoryEngine.SafehouseRadius = 0
    local _, _, moved3 = Hunt.pushOut(10012, 10005)
    H.ok(not moved3, "0 = off")
end

return T
