-- 좀비 밀집도로 위험한 건물(일명 마굴: 교도소, 큰 쇼핑몰 등)을 피한다 (2026-10-07 사용자 요청).
--
-- 밀집도 = 게임 지도의 좀비 분포 값 (IsoMetaGrid:getChunkDataFromTile(x, y) -> IsoMetaChunk:getUnadjustedZombieIntensity,
-- 바닐라가 좀비를 뿌릴 때 쓰는 값, jar 확인). 건물 하나의 밀집도 = 건물 둘레 MARGIN 타일까지 넓힌 사각형의
-- 가운데·네 모서리 중 가장 높은 값 (큰 몰은 안쪽이, 교도소 담 옆 집은 바깥쪽이 높다).
--
-- "상위 X%" 는 그 지역 순위: 건물 둘레 REGION 타일 안의 건물(최대 SAMPLE 개)의 밀집도 분포에서 아래 (1 - X) 까지만 고른다.
-- 지도 전체로 순위를 매기면 도시 건물은 거의 다 상위에 들어 도시에서는 걸러 낼 게 없어진다.
--   보상·선물·거래 배송 보급 = 아래 50% (Danger.KEEP_REWARD), 소탕·정찰·찾아오기 등 위치 퀘스트 = 아래 70% (KEEP_QUEST).
-- 지역 분포는 REGION_CELL 크기 격자마다 한 번 계산해 둔다 (세션 동안). 값을 못 읽으면 거르지 않는다.

if isClient() then return end

require "StoryEngine/Core"

local log = StoryEngine.log

local Danger = {}
StoryEngine.Danger = Danger

Danger.KEEP_REWARD = 0.5
Danger.KEEP_QUEST = 0.7
Danger.MARGIN = 10
Danger.REGION = 450          -- 순위를 매길 지역 반경 (타일)
Danger.REGION_CELL = 300     -- 지역 분포를 나눠 기억하는 격자
Danger.SAMPLE = 400          -- 지역 분포에 쓰는 건물 수 상한
Danger.cache = {}            -- 격자 키 -> 정렬된 밀집도 목록
Danger.byBuilding = {}       -- 건물 키 -> 밀집도

local function readAt(x, y)
    local ok, v = pcall(function()
        local chunk = getWorld():getMetaGrid():getChunkDataFromTile(math.floor(x), math.floor(y))
        if not chunk then return nil end
        local okU, u = pcall(function() return chunk:getUnadjustedZombieIntensity() end)
        if okU and u ~= nil then return tonumber(u) end
        return tonumber(chunk:getZombieIntensity())
    end)
    if ok then return v end
    return nil
end
Danger.at = readAt

local function keyOf(def)
    return StoryEngine.intToString(def:getX()) .. "_" .. StoryEngine.intToString(def:getY())
end

-- 건물 하나의 밀집도 (못 읽으면 nil)
function Danger.ofBuilding(def)
    local key = keyOf(def)
    local hit = Danger.byBuilding[key]
    if hit ~= nil then return hit or nil end
    local m = Danger.MARGIN
    local x1, y1, x2, y2 = def:getX() - m, def:getY() - m, def:getX2() + m, def:getY2() + m
    local best = nil
    for _, p in ipairs({ { (x1 + x2) / 2, (y1 + y2) / 2 }, { x1, y1 }, { x2, y1 }, { x1, y2 }, { x2, y2 } }) do
        local v = readAt(p[1], p[2])
        if v and (not best or v > best) then best = v end
    end
    Danger.byBuilding[key] = best or false
    return best
end

-- 이 자리 둘레 지역의 밀집도 분포 (정렬됨). 건물이 너무 적으면 nil
function Danger.region(x, y)
    local cell = Danger.REGION_CELL
    local gx, gy = math.floor(x / cell), math.floor(y / cell)
    local key = StoryEngine.intToString(gx) .. "_" .. StoryEngine.intToString(gy)
    local hit = Danger.cache[key]
    if hit ~= nil then return hit or nil end
    local cx, cy = (gx + 0.5) * cell, (gy + 0.5) * cell
    local r = Danger.REGION
    local values = {}
    pcall(function()
        local list = ArrayList.new()
        getWorld():getMetaGrid():getBuildingsIntersecting(math.floor(cx - r), math.floor(cy - r), r * 2, r * 2, list)
        local n = list:size()
        local step = math.max(1, math.floor(n / Danger.SAMPLE))
        for i = 0, n - 1, step do
            local v = Danger.ofBuilding(list:get(i))
            if v then values[#values + 1] = v end
        end
    end)
    if #values < 10 then
        Danger.cache[key] = false
        return nil
    end
    table.sort(values)
    Danger.cache[key] = values
    log("danger region", key, #values, "buildings", "p50", values[math.max(1, math.floor(#values * 0.5))],
        "p70", values[math.max(1, math.floor(#values * 0.7))], "max", values[#values])
    return values
end

-- 지역 분포에서 아래 keep 비율의 경계값 (이 값 이하만 고른다)
function Danger.cut(x, y, keep)
    local values = Danger.region(x, y)
    if not values then return nil end
    return values[math.max(1, math.min(#values, math.floor(#values * keep)))]
end

-- 이 건물을 골라도 되나. keep = 아래 몇 % 까지 (0.5 / 0.7). 값을 못 읽으면 true
function Danger.allowed(def, keep)
    if not keep or keep >= 1 then return true end
    local v = Danger.ofBuilding(def)
    if not v then return true end
    local cx, cy = (def:getX() + def:getX2()) / 2, (def:getY() + def:getY2()) / 2
    local cut = Danger.cut(cx, cy, keep)
    if not cut then return true end
    return v <= cut
end

-- 지역 안 순위 (0 = 가장 낮음, 1 = 가장 높음), 디버그용
function Danger.rank(x, y, v)
    local values = Danger.region(x, y)
    if not values or not v then return nil end
    local below = 0
    for _, w in ipairs(values) do if w < v then below = below + 1 end end
    return below / #values
end

-- 디버그 한 줄: 이 자리·이 건물의 밀집도와 지역 경계
function Danger.statusAt(x, y)
    local here = readAt(x, y)
    local def = nil
    pcall(function() def = getWorld():getMetaGrid():getBuildingAt(math.floor(x), math.floor(y)) end)
    local b = def and Danger.ofBuilding(def) or nil
    local p50, p70 = Danger.cut(x, y, Danger.KEEP_REWARD), Danger.cut(x, y, Danger.KEEP_QUEST)
    local values = Danger.region(x, y)
    local rank = Danger.rank(x, y, b or here)
    return "danger here=" .. tostring(here) .. " building=" .. tostring(b)
        .. " rank=" .. (rank and (StoryEngine.intToString(math.floor(rank * 100)) .. "%") or "?")
        .. " cut50=" .. tostring(p50) .. " cut70=" .. tostring(p70)
        .. " region=" .. tostring(values and #values or 0) .. " max=" .. tostring(values and values[#values])
end

return Danger
