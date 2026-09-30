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

-- ---------------------------------------------------------------- NPC 생활 자원 (Life.lua, 물자 지원 창)
-- 물건이 NPC 의 어느 자원을 채우는지: 음식 -> 식량, 의약품 -> 의약품, 총·탄약·근접 무기·폭발물·도구 -> 안전,
-- 술·담배·책·잡지·배터리·초 -> 사기. 그 외는 받지 않는다.
Value.RESOURCES = { "food", "medical", "safety", "morale" }
Value.RESOURCE_OF = {
    food = "food", medical = "medical",
    firearm = "safety", ammo = "safety", melee = "safety", explosive = "safety", tools = "safety",
}
-- 사기 물건: 아이템 이름 앞부분 (다른 모드의 비슷한 이름도 잡힌다)
Value.MORALE_PREFIX = { "Cigarette", "Cigar", "Tobacco", "Beer", "Wine", "Whiskey", "Vodka", "Rum", "Bourbon",
                        "Scotch", "Brandy", "Tequila", "Champagne", "Magazine", "ComicBook", "Book_", "BookFancy" }
Value.MORALE_SPECIAL = {
    ["Base.Battery"] = 1, ["Base.Candle"] = 0.5, ["Base.CigaretteCarton"] = 8, ["Base.CigarettePack"] = 2,
    ["Base.CigaretteSingle"] = 0.2, ["Base.CigaretteRolled"] = 0.2,
}
Value.MORALE_DEFAULT = 1

local moraleCache = {}

-- 사기 물건이면 가치, 아니면 nil
function Value.moraleValue(fullType)
    local hit = moraleCache[fullType]
    if hit ~= nil then return hit or nil end
    local value = Value.MORALE_SPECIAL[fullType]
    if not value then
        local name = string.match(fullType, "%.(.+)$") or fullType
        for _, prefix in ipairs(Value.MORALE_PREFIX) do
            if string.sub(name, 1, string.len(prefix)) == prefix then value = Value.MORALE_DEFAULT end
        end
        if not value then
            local ok, cat = pcall(function() return getScriptManager():getItem(fullType):getDisplayCategory() end)
            if ok and (cat == "Literature" or cat == "SkillBook") then value = Value.MORALE_DEFAULT end
        end
    end
    moraleCache[fullType] = value or false
    return value
end

-- 물건 -> (자원, 가치). 받지 않는 물건이면 nil
function Value.resourceOf(fullType)
    local res = Value.RESOURCE_OF[Value.categoryOf(fullType)]
    if res then return res, Value.of(fullType) end
    local mv = Value.moraleValue(fullType)
    if mv then return "morale", mv end
    return nil
end

-- 물자 지원으로 보낼 수 있는 아이템인가: 퀘스트 아이템·입은 옷·가방·상한 음식이 아니고 받는 자원이 있다
function Value.donatable(player, item)
    local mod = item:getModData()
    if mod and mod.storyQuest then return nil end
    if player and (player:isEquippedClothing(item) or player:isEquipped(item)) then return nil end
    if instanceof(item, "Food") and item:isRotten() then return nil end
    if instanceof(item, "InventoryContainer") then return nil end
    return Value.resourceOf(item:getFullType())
end

-- ---------------------------------------------------------------- 장기 프로젝트 물건 (Projects.lua, 물자 지원 창 프로젝트 모드)
-- rule = { res = 받는 자원 } | { accept = "vehicle" } (듀이: 차량 부품·정비 도구) | { accept = "any", mult } (빅: 무엇이든 x0.8)
-- 받는 물건은 가치 1 = 1점, 다른 물건은 0.5점.

-- 차량 정비 도구 (DisplayCategory 가 VehicleMaintenance 가 아닌 것)
Value.VEHICLE_TOOLS = {
    ["Base.Wrench"] = true, ["Base.Screwdriver"] = true, ["Base.Ratchet"] = true, ["Base.PipeWrench"] = true,
    ["Base.BlowTorch"] = true, ["Base.WeldingMask"] = true, ["Base.WeldingRods"] = true, ["Base.Multitool"] = true,
}
Value.VEHICLE_VALUE = {
    ["Base.EngineParts"] = 3, ["Base.CarBattery1"] = 15, ["Base.CarBattery2"] = 15, ["Base.CarBattery3"] = 15,
    ["Base.CarBatteryCharger"] = 10, ["Base.PetrolCan"] = 3, ["Base.WeldingRods"] = 2,
}
-- 차량 부품: 이름에 들어간 말로 가치 (타이어 6 등), 그 밖의 부품 4
Value.VEHICLE_WORDS = { { "Tire", 6 }, { "Brake", 5 }, { "Suspension", 5 }, { "GasTank", 6 }, { "Muffler", 4 },
                        { "Door", 5 }, { "Hood", 5 }, { "Trunk", 4 }, { "Windshield", 4 }, { "Window", 3 }, { "Seat", 3 } }
Value.VEHICLE_DEFAULT = 4

local vehicleCache = {}

-- 차량 관련 물건이면 가치, 아니면 nil
function Value.vehicleValue(fullType)
    local hit = vehicleCache[fullType]
    if hit ~= nil then return hit or nil end
    local value = Value.VEHICLE_VALUE[fullType]
    if not value and Value.VEHICLE_TOOLS[fullType] then value = math.max(2, Value.of(fullType)) end
    if not value then
        local ok, cat = pcall(function() return getScriptManager():getItem(fullType):getDisplayCategory() end)
        if ok and cat == "VehicleMaintenance" then
            local name = string.match(fullType, "%.(.+)$") or fullType
            value = Value.VEHICLE_DEFAULT
            for _, w in ipairs(Value.VEHICLE_WORDS) do
                if string.find(name, w[1], 1, true) then
                    value = w[2]
                    break
                end
            end
        end
    end
    vehicleCache[fullType] = value or false
    return value
end

-- 보낼 수 없는 물건: 퀘스트 아이템·입거나 든 것·가방·상한 음식
local function locked(player, item)
    local mod = item:getModData()
    if mod and mod.storyQuest then return true end
    if player and (player:isEquippedClothing(item) or player:isEquipped(item)) then return true end
    if instanceof(item, "Food") and item:isRotten() then return true end
    if instanceof(item, "InventoryContainer") then return true end
    return false
end

-- 이 물건이 프로젝트에 몇 점인가. 반환: 점수, 물건 가치 (신뢰도 계산용) / 받지 않으면 nil
function Value.projectItem(player, item, rule)
    if not rule or locked(player, item) then return nil end
    local ft = item:getFullType()
    local res, value = Value.resourceOf(ft)
    if rule.accept == "vehicle" then
        local vv = Value.vehicleValue(ft)
        if vv then return vv, vv end
        if res then return value * 0.5, value end
        return nil
    elseif rule.accept == "any" then
        if not res then
            local vv = Value.vehicleValue(ft)
            if vv then res, value = "vehicle", vv end
        end
        if res then return value * (rule.mult or 0.8), value end
        return nil
    end
    if not res then return nil end
    return value * (res == rule.res and 1 or 0.5), value
end

-- 프로젝트에 보낼 수 있는 아이템들: { item, points, value }
function Value.projectItems(player, rule)
    local out = {}
    local list = player:getInventory():getAllEvalRecurse(function(item)
        return Value.projectItem(player, item, rule) ~= nil
    end)
    for i = 0, list:size() - 1 do
        local item = list:get(i)
        local pts, value = Value.projectItem(player, item, rule)
        if pts then out[#out + 1] = { item = item, points = pts, value = value } end
    end
    return out
end

-- 플레이어 인벤토리(가방 속까지)에서 보낼 수 있는 아이템들: { item, resource, value }
function Value.donatableItems(player)
    local out = {}
    local list = player:getInventory():getAllEvalRecurse(function(item)
        return Value.donatable(player, item) ~= nil
    end)
    for i = 0, list:size() - 1 do
        local item = list:get(i)
        local res, value = Value.donatable(player, item)
        if res then out[#out + 1] = { item = item, resource = res, value = value } end
    end
    return out
end

return Value
