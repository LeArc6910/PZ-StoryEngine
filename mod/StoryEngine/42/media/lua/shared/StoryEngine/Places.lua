-- 좌표 → 사람이 읽을 수 있는 지명.
-- 좌표는 바닐라 media/maps/Muldraugh, KY/worldmap-annotations.lua 의 지도 라벨(text-town / text-place / text-building)에서 가져왔다.
-- Lua 소스의 비 ASCII 문자열은 Kahlua 에서 깨지므로(42.20.4 확인) 한국어 이름은 브릿지(modules.py)에 둔다.

require "StoryEngine/Core"

local Places = {}
StoryEngine.Places = Places

Places.towns = {
    { key = "Brandenburg",   x = 2056,  y = 6070 },
    { key = "Echo Creek",    x = 3589,  y = 10952 },
    { key = "Ekron",         x = 634,   y = 9746 },
    { key = "Fallas Lake",   x = 7253,  y = 8279 },
    { key = "Irvington",     x = 2427,  y = 14185 },
    { key = "Louisville",    x = 13077, y = 2238 },
    { key = "March Ridge",   x = 10130, y = 12801 },
    { key = "Muldraugh",     x = 10754, y = 9926 },
    { key = "Riverside",     x = 6450,  y = 5430 },
    { key = "Rosewood",      x = 8159,  y = 11661 },
    { key = "Valley Station", x = 13447, y = 5278 },
    { key = "West Point",    x = 11654, y = 6864 },
}

Places.landmarks = {
    { name = "Brandenburg Detention Center", x = 1385, y = 5877 },
    { name = "Crossroads Mall", x = 13936, y = 5832 },
    { name = "Kentucky State Prison", x = 7683, y = 11877 },
    { name = "Louisville International Airport", x = 15466, y = 2914 },
    { name = "Louisville General Hospital", x = 12958, y = 2042 },
    { name = "Louisville State University", x = 12412, y = 2257 },
    { name = "Pondview Shopping Center", x = 1910, y = 6370 },
    { name = "St. Peregrin Hospital", x = 12414, y = 3674 },
    { name = "Sunderland Hills Sanatorium", x = 4038, y = 6490 },
    { name = "West Maple Country Club", x = 5726, y = 6509 },
    { name = "Bright Valley Trailer Park", x = 2733, y = 6286 },
    { name = "Camp Arthur", x = 8313, y = 14590 },
    { name = "Camp Camus", x = 4795, y = 7925 },
    { name = "Camp Fitzgerald", x = 13814, y = 6703 },
    { name = "Coalfield", x = 3486, y = 8193 },
    { name = "Dixie Trailer Park", x = 11625, y = 8830 },
    { name = "Irvington Speedway", x = 928, y = 13044 },
    { name = "Knox Boundary Camp", x = 12518, y = 4258 },
    { name = "McCoy's Logging", x = 10321, y = 9331 },
    { name = "Meadshire Estate", x = 4121, y = 9415 },
    { name = "Pony Roam-O", x = 8532, y = 8527 },
    { name = "Scenic Grove Trailer Park", x = 5381, y = 6006 },
    { name = "Muldraugh Trainyard", x = 11651, y = 9890 },
}

local LANDMARK_RADIUS = 250

local function dist(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

-- { town = "Muldraugh", townDist = 120, landmark = "Muldraugh Trainyard" | nil }
function Places.describe(x, y)
    local best, bestDist = nil, nil
    for _, t in ipairs(Places.towns) do
        local d = dist(x, y, t.x, t.y)
        if not bestDist or d < bestDist then best, bestDist = t, d end
    end
    local out = { town = best.key, townDist = math.floor(bestDist) }
    local lmDist = LANDMARK_RADIUS
    for _, l in ipairs(Places.landmarks) do
        local d = dist(x, y, l.x, l.y)
        if d < lmDist then out.landmark, lmDist = l.name, d end
    end
    return out
end

return Places
