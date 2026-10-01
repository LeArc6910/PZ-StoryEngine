-- 전력·수도 복구 작전의 실제 장소 (2026-10-01). 바닐라 지도(media/maps/Muldraugh, KY)의 world_*.lotpack 칸 데이터에서
-- 타일 이름으로 뽑았다 (스크래치패드 sites/scan.py: 셀 256타일, 청크 8타일, 칸마다 개수·방 번호·타일 번호).
-- 바닐라 지도에는 이름 붙은 발전소·정수장이 없어서, 실제로 서 있는 시설에 역할을 붙인다.
--   WATER_TOWERS  급수탑 (water_tank 타일 16~34개, 높이 6층). 루이빌 빌딩 옥상 물탱크는 뺐다
--   SUBSTATIONS   변전소처럼 변압 설비가 모인 곳 (electricity_pylon_176/181 묶음)
--   LINE          송전탑 (electricity_pylon_0, 한 기에 2칸). 하나로 이어진 간선:
--                 밸리 스테이션 변전소(14768,4085) -> 남쪽 x=14771 -> 서쪽 y=7924 -> 남쪽 x=9497/9759 -> 서쪽 y=12527
--                 -> 로즈우드 남쪽 변전소(7182,12532). 송전탑은 약 300타일 간격

require "StoryEngine/Core"

local OpsSites = {}
StoryEngine.OpsSites = OpsSites

OpsSites.WATER_TOWERS = {
    { x = 531, y = 9485 }, { x = 1960, y = 10867 }, { x = 3586, y = 10944 }, { x = 5453, y = 9623 },
    { x = 5793, y = 5382 }, { x = 6803, y = 7688 }, { x = 7118, y = 8463 }, { x = 8024, y = 11885 },
    { x = 10278, y = 9508 }, { x = 10605, y = 10622 }, { x = 11283, y = 6957 }, { x = 15310, y = 3303 },
}

OpsSites.SUBSTATIONS = {
    { x = 7182, y = 12532, main = true }, { x = 14768, y = 4085, main = true }, { x = 10388, y = 10092 },
    { x = 12098, y = 1751 }, { x = 6768, y = 6840 }, { x = 1882, y = 10880 }, { x = 2191, y = 13893 },
    { x = 2128, y = 6393 },
}

OpsSites.LINE = {
    { x = 7253, y = 12527 }, { x = 7342, y = 12527 }, { x = 7657, y = 12527 }, { x = 7950, y = 12527 },
    { x = 8257, y = 12527 }, { x = 8554, y = 12527 }, { x = 8874, y = 12527 }, { x = 9140, y = 12527 },
    { x = 9392, y = 12527 }, { x = 9497, y = 8563 }, { x = 9497, y = 8845 }, { x = 9497, y = 9159 },
    { x = 9497, y = 9465 }, { x = 9497, y = 9779 }, { x = 9497, y = 10055 }, { x = 9497, y = 10365 },
    { x = 9497, y = 10670 }, { x = 9497, y = 10959 }, { x = 9497, y = 11388 }, { x = 9759, y = 11651 },
    { x = 9759, y = 11854 }, { x = 9759, y = 12160 }, { x = 10136, y = 7924 }, { x = 10357, y = 7924 },
    { x = 10628, y = 7924 }, { x = 10941, y = 7924 }, { x = 11249, y = 7924 }, { x = 11555, y = 7924 },
    { x = 11858, y = 7924 }, { x = 12157, y = 7924 }, { x = 12453, y = 7924 }, { x = 12754, y = 7924 },
    { x = 13060, y = 7924 }, { x = 13331, y = 7924 }, { x = 13647, y = 7924 }, { x = 13943, y = 7924 },
    { x = 14241, y = 7924 }, { x = 14535, y = 7924 }, { x = 14771, y = 4108 }, { x = 14771, y = 4367 },
    { x = 14771, y = 4656 }, { x = 14771, y = 4961 }, { x = 14771, y = 5260 }, { x = 14771, y = 5563 },
    { x = 14771, y = 5857 }, { x = 14771, y = 6152 }, { x = 14771, y = 6450 }, { x = 14771, y = 6745 },
    { x = 14771, y = 7061 }, { x = 14771, y = 7344 }, { x = 14771, y = 7688 },
}

-- 큰 라디오 탑 (radio_tower 타일 60개 이상, 높이 7~8층). 루이빌 빌딩 옥상 안테나는 뺐다 (통신 두절 사건, Saga.lua)
OpsSites.RADIO_TOWERS = {
    { x = 888, y = 12787 }, { x = 1512, y = 14865 }, { x = 1627, y = 5747 }, { x = 2712, y = 10962 },
    { x = 4841, y = 6271 }, { x = 5539, y = 12441 }, { x = 6119, y = 5226 }, { x = 10271, y = 8743 },
    { x = 15262, y = 3181 }, { x = 15381, y = 2586 },
}

local function d2(a, x, y)
    local dx, dy = a.x - x, a.y - y
    return dx * dx + dy * dy
end

-- list 를 (x, y) 에서 가까운 순으로 (원본은 그대로)
function OpsSites.byDistance(list, x, y)
    local out = {}
    for i, s in ipairs(list) do out[i] = s end
    table.sort(out, function(a, b) return d2(a, x, y) < d2(b, x, y) end)
    return out
end

-- (x, y) 에서 가까운 순으로, 서로 minGap 이상 떨어진 n 곳 (exclude 근처 minGap 안도 뺀다)
function OpsSites.spread(list, x, y, n, minGap, exclude)
    local out = {}
    local gap2 = minGap * minGap
    for _, s in ipairs(OpsSites.byDistance(list, x, y)) do
        local ok = true
        for _, o in ipairs(out) do if d2(o, s.x, s.y) < gap2 then ok = false end end
        for _, o in ipairs(exclude or {}) do if d2(o, s.x, s.y) < gap2 then ok = false end end
        if ok then out[#out + 1] = s end
        if #out >= n then break end
    end
    return out
end

return OpsSites
