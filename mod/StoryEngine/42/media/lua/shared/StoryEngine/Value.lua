-- 아이템 분류와 거래 가치. 서버(가격·검증)와 클라이언트(대가 제출 창)가 같은 표를 쓴다.
--
-- 희귀도: 총기·탄약·폭발물 > 도구·의약품 > 근접 무기 > 음식 > 기타
-- 분류는 ItemPool.classify (다른 모드 아이템 포함): 음식은 열량, 총은 구조로 정한 등급, 탄약은 총이 가리키는 낱발·상자·탄창.
-- 향신료·재료·상하는 음식은 대가로 받지 않는다.

require "StoryEngine/Core"
require "StoryEngine/ItemPool"

local Value = {
    cache = {},    -- fullType -> { category, value }
}
StoryEngine.Value = Value

Value.CATEGORIES = { "firearm", "ammo", "tools", "medical", "melee", "food" }

Value.BASE = {
    firearm = 50, explosive = 20, tools = 8, medical = 3, melee = 5, food = 1.5, misc = 0.2,
}

-- 기본값과 다른 아이템
Value.SPECIAL = {
    ["Base.Antibiotics"] = 8, ["Base.SutureNeedle"] = 4, ["Base.Splint"] = 3, ["Base.Disinfectant"] = 4,
    ["Base.Katana"] = 12, ["Base.Machete"] = 10, ["Base.Axe"] = 10,
    ["Base.Sledgehammer"] = 20, ["Base.Sledgehammer2"] = 20, ["Base.PipeWrench"] = 20, ["Base.WoodAxe"] = 20,
    ["Base.BlowTorch"] = 20, ["Base.Generator"] = 60, ["Base.CarBattery1"] = 15, ["Base.CarBattery2"] = 15,
    ["Base.EngineParts"] = 3, ["Base.HamRadio1"] = 40, ["Base.HamRadio2"] = 40,
}

local function lookup(fullType)
    local hit = Value.cache[fullType]
    if hit then return hit end
    local ok, c = pcall(StoryEngine.ItemPool.classify, fullType)
    if not ok or not c then c = { category = "misc" } end
    local value = Value.SPECIAL[fullType] or c.value or Value.BASE[c.category] or Value.BASE.misc
    hit = { category = c.category, value = value }
    Value.cache[fullType] = hit
    return hit
end

function Value.categoryOf(fullType)
    return lookup(fullType).category
end

function Value.of(fullType)
    return lookup(fullType).value
end

-- 목록의 총 가치 (fullType 배열)
function Value.sum(list)
    local total = 0
    for _, ft in ipairs(list or {}) do total = total + Value.of(ft) end
    return total
end

-- 대가로 낼 수 있는 아이템인가: 분류가 맞고, 퀘스트 아이템이 아니고, 입고 있는 옷이 아니다
function Value.payable(player, item, category)
    local mod = item:getModData()
    if mod and mod.storyQuest then return false end
    if player and player:isEquippedClothing(item) then return false end
    if instanceof(item, "Food") and item:isRotten() then return false end
    return Value.categoryOf(item:getFullType()) == category
end

-- 플레이어 인벤토리(가방 속까지)에서 해당 분류로 낼 수 있는 아이템들
function Value.payableItems(player, category)
    local out = {}
    local list = player:getInventory():getAllEvalRecurse(function(item)
        return Value.payable(player, item, category)
    end)
    for i = 0, list:size() - 1 do out[#out + 1] = list:get(i) end
    return out
end

return Value
