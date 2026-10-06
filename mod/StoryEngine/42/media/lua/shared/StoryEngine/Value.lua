-- 아이템 분류와 거래 가치. 서버(가격·검증)와 클라이언트(대가 제출 창)가 같은 표를 쓴다.
--
-- 희귀도: 총기·탄약·폭발물 > 도구·의약품 > 근접 무기 > 음식 > 기타
-- 분류는 ItemPool.classify (다른 모드 아이템 포함): 음식은 열량, 총은 구조로 정한 등급, 탄약은 총이 가리키는 낱발·상자·탄창.
-- 향신료·재료·상하는 음식은 대가로 받지 않는다.

require "StoryEngine/Core"
require "StoryEngine/ItemPool"
require "StoryEngine/Factions"

local Value = {
    cache = {},    -- fullType -> { category, value }
}
StoryEngine.Value = Value

Value.CATEGORIES = { "firearm", "ammo", "tools", "medical", "melee", "food" }

Value.BASE = {
    firearm = 50, explosive = 20, tools = 8, medical = 3, melee = 5, food = 1.5, misc = 0.2,
}

-- 기본값과 다른 아이템. 지금은 없다: 음식·의약품·도구·근접 무기·총·탄약·전자기기·차량 부품은 등급이 가치를 정한다
-- (2026-10-04, 예전 발전기 60·햄 라디오 40·차량 배터리 15 등은 등급 값으로)
Value.SPECIAL = {}

-- 폭발물 (2026-10-03 점검): 군용 수류탄만 가치 20, 직접 만드는 화염병·폭죽·트랩 류는 3
Value.MILITARY_EXPLOSIVES = { ["Base.BombBig"] = true, ["Base.BombSmall"] = true }
Value.CRAFTED_EXPLOSIVE = 3
-- 의약품으로 치지 않는 것 (2026-10-03 점검): 쓰고 난 붕대, 옷을 찢은 천, 수술용 옷, 계속 쓰는 도구
Value.NOT_MEDICAL = {
    ["Base.BandageDirty"] = true, ["Base.Gloves_Surgical"] = true, ["Base.Hat_SurgicalCap"] = true,
    ["Base.Hat_SurgicalMask"] = true, ["Base.MortarPestle"] = true, ["Base.CeramicMortarandPestle"] = true,
}

local function lookup(fullType)
    local hit = Value.cache[fullType]
    if hit then return hit end
    local ok, c = pcall(StoryEngine.ItemPool.classify, fullType)
    if not ok or not c then c = { category = "misc" } end
    local category = c.category
    local value = Value.SPECIAL[fullType] or c.value or Value.BASE[category] or Value.BASE.misc
    if category == "explosive" and not Value.MILITARY_EXPLOSIVES[fullType] then value = Value.CRAFTED_EXPLOSIVE end
    if category == "medical" and (Value.NOT_MEDICAL[fullType] or string.find(fullType, "RippedSheets", 1, true)) then
        category, value = "misc", Value.BASE.misc
    end
    hit = { category = category, value = value, tier = c.tier }
    Value.cache[fullType] = hit    -- 상자 안의 물건을 찾다가 같은 것을 다시 부르지 않게 먼저 넣는다
    if category == "ammo" then
        hit.value = Value.ammoValue(fullType, value)
    elseif category ~= "misc" then
        -- 상자·묶음은 안에 든 물건 x 개수 (붕대 상자 = 붕대 12개, 그래놀라 바 상자 = 5개)
        local inside = StoryEngine.ItemPool.contentsOf(fullType)
        if inside and inside[2] >= 2 and lookup(inside[1]).category == category then
            hit.value = lookup(inside[1]).value * inside[2]
            -- 음식 포장은 열면 나오는 것의 합계로 등급을 정해 두었다 (ItemPool). 그 밖은 안에 든 것의 등급
            hit.tier = (category == "food" and hit.tier) or lookup(inside[1]).tier
        end
    end
    return hit
end

-- 탄약 (2026-10-03 점검, 2026-10-04 등급별): 상자 하나 = 구경 등급의 값 (ItemPool.AMMO_BOX_VALUE),
-- 낱발 = 상자 가치 / 상자 속 발 수 (상자 풀기 레시피의 개수, 9mm 등 50발·소총탄 20발·산탄 25발), 카톤 = 상자 x 12.
-- 상자를 풀든 다시 담든 가치가 같다. 개수를 모르는 낱발은 상자 / 20.
local boxRounds = nil   -- 상자 fullType -> 발 수, 낱발 fullType -> 상자 하나의 발 수

local function scanBoxes()
    local out = {}
    local sm = (ScriptManager and ScriptManager.instance) or (getScriptManager and getScriptManager()) or nil
    if not sm then return out end
    local ok, recipes = pcall(function() return sm:getAllCraftRecipes() end)
    if not ok or not recipes then return out end
    local okN, count = pcall(function() return recipes:size() end)
    if not okN or type(count) ~= "number" then return out end
    for i = 0, count - 1 do
        pcall(function()
            local recipe = recipes:get(i)
            local inputs, outputs = recipe:getInputs(), recipe:getOutputs()
            if inputs:size() ~= 1 or outputs:size() ~= 1 then return end
            local boxes = inputs:get(0):getPossibleInputItems()
            local output = outputs:get(0)
            local amount = output:getAmount()
            local results = output:getPossibleResultItems()
            if not boxes or not results or not amount or amount < 2 then return end
            for b = 0, boxes:size() - 1 do
                local bt = boxes:get(b):getFullName()
                if string.find(bt, "Box", 1, true) then
                    out[bt] = amount
                    for r = 0, results:size() - 1 do out[results:get(r):getFullName()] = amount end
                end
            end
        end)
    end
    return out
end

local function roundsPerBox()
    if boxRounds then return boxRounds end
    boxRounds = scanBoxes()
    local all = {}
    for box, inside in pairs(StoryEngine.ItemPool.contentsAll()) do all[box] = inside end
    for box, inside in pairs(StoryEngine.ItemTiers.CONTENTS) do all[box] = inside end
    for box, inside in pairs(all) do
        if string.find(box, "Box", 1, true) then
            boxRounds[box] = inside[2]
            boxRounds[inside[1]] = boxRounds[inside[1]] or inside[2]
        end
    end
    return boxRounds
end

function Value.ammoValue(fullType, default)
    local IP = StoryEngine.ItemPool
    local inside = IP.contentsOf(fullType)
    if inside and not string.find(fullType, "Box", 1, true) then     -- 카톤: 상자 x 개수
        return Value.of(inside[1]) * inside[2]
    end
    local name = string.lower(fullType)
    if string.find(name, "box", 1, true) or string.find(name, "clip", 1, true) or string.find(name, "mag", 1, true)
        or string.find(name, "drum", 1, true) then
        return default
    end
    local n = roundsPerBox()[fullType]
    local tier = IP.ammoTierOf(fullType)
    if n and tier then return IP.AMMO_BOX_VALUE[tier] / n end
    return default
end

function Value.categoryOf(fullType)
    return lookup(fullType).category
end

-- 물건 상태 비율 0~1 (2026-10-03 점검): 내구도, 남은 사용량(약통·배터리 등), 액체 용기에 남은 양(의약품·술),
-- 먹다 남은 음식. 부서진 물건은 0 (거래·지원·프로젝트에 못 냄)
function Value.ratio(item)
    local r = 1
    pcall(function()
        if item:isBroken() then r = 0 end
    end)
    if r == 0 then return 0 end
    pcall(function()
        local max = item:getConditionMax()
        if max and max > 0 then r = r * math.max(0, math.min(1, item:getCondition() / max)) end
    end)
    pcall(function()
        if instanceof(item, "DrainableComboItem") then r = r * math.max(0, math.min(1, item:getCurrentUsesFloat())) end
    end)
    pcall(function()
        local fc = item.getFluidContainer and item:getFluidContainer() or nil
        local cat = Value.categoryOf(item:getFullType())
        if fc and fc:getCapacity() > 0 and (cat == "medical" or Value.ALCOHOL[item:getFullType()]) then
            r = r * math.max(0, math.min(1, fc:getAmount() / fc:getCapacity()))
        end
    end)
    pcall(function()
        if instanceof(item, "Food") then
            local base = item:getBaseHunger()
            if base and base < 0 then r = r * math.max(0, math.min(1, item:getHungChange() / base)) end
        end
    end)
    if r < 0.01 then return 0 end
    return r
end

-- 이 물건 하나의 실제 가치 (종류 가치 x 상태 비율)
function Value.itemValue(item)
    return Value.of(item:getFullType()) * Value.ratio(item)
end

-- 퀘스트 표시가 붙은 물건이 아직 진행 중인 퀘스트 것인가. 서버는 퀘스트 데이터로 직접 보고,
-- 클라이언트는 MainWindow 가 퀘스트 목록으로 바꿔 끼운다. 모르면 진행 중으로 본다 (서버가 다시 검증한다)
Value.isQuestActive = function(id)
    local Quests, Store = StoryEngine.Quests, StoryEngine.Store
    if Quests and Store and Store.data then
        local q = Store.data().quests[id]
        return q ~= nil and (q.state == "proposed" or Quests.isActive(q))
    end
    return true
end

-- 물자 지원·프로젝트에서 막는 퀘스트 물건: 진행 중인 퀘스트 것만 (끝난 퀘스트의 보상·거래 물건은 된다, 2026-10-03)
-- 거래 대가(Value.payable)는 끝난 퀘스트 물건도 계속 막는다 (싸게 사서 되파는 반복 방지)
local function activeQuestItem(item)
    local mod = item:getModData()
    return mod ~= nil and mod.storyQuest ~= nil and Value.isQuestActive(mod.storyQuest) == true
end

-- 같은 물건은 한 번에 이만큼만 받는다 (물자 지원·프로젝트, 책 더미 방지, 2026-10-03)
Value.SAME_ITEM_CAP = 10

function Value.of(fullType)
    return lookup(fullType).value
end

-- 목록의 총 가치 (fullType 배열)
function Value.sum(list)
    local total = 0
    for _, ft in ipairs(list or {}) do total = total + Value.of(ft) end
    return total
end

-- ---------------------------------------------------------------- 채집·벌목 재료와 그 1차 가공품 (2026-10-02 사용자 요청)
-- 거래 대가·물자 지원·장기 프로젝트에 쓸 수 없다.
-- raw: 나뭇가지·돌·통나무·약초·열매처럼 채집이나 벌목으로 쉽게 얻는 재료. 바닐라 채집 정의(forageSystem.itemDefs, 다른
--   모드가 더한 것 포함)에서 자연물 분류에 속한 아이템 + 벌목·목공으로 바로 나오는 것(RAW_EXTRA).
--   공예 재료·숲의 희귀품·쓰레기·옷·탄약 같은 채집 분류에는 진짜 도구·물건이 섞여 있어 넣지 않는다.
-- made: 소모 재료 칸마다 raw 로 채울 수 있는 제작 레시피의 결과물 (예: 나뭇가지·묘목 + 칼(남는 도구) -> 나무창).
--   한 단계만 본다. 재료 칸은 "아무거나 하나"라서 (창: 긴 막대기·묘목·갈퀴·걸레…) raw 가 하나라도 들어가면 채울 수 있다고 본다.
--   아이템 종류로만 판정하므로, 상점에서도 흔히 나오는 쓸모 있는 물건(밧줄·노끈 등)은 RAW_MADE_ALLOW 로 뺀다.
Value.RAW_FORAGE = {
    Firewood = true, Stones = true, Bones = true, Animals = true, DeadAnimals = true, Insects = true,
    Herbs = true, MedicinalPlants = true, WildPlants = true, Berries = true, Mushrooms = true,
    Fruits = true, Vegetables = true,
}
Value.RAW_EXTRA = {
    "Base.Log", "Base.LogStacks2", "Base.LogStacks3", "Base.LogStacks4", "Base.Plank", "Base.Firewood",
    "Base.UnusableWood", "Base.Twigs", "Base.TreeBranch2", "Base.LargeBranch", "Base.Branch_Broken", "Base.Sapling",
    "Base.Pinecone", "Base.Stone2", "Base.SharpedStone", "Base.FlintNodule", "Base.Limestone", "Base.LargeStone",
    "Base.FlatStone", "Base.Clay",
}
-- 1차 가공품으로 보지 않는 것 (바닐라 루팅에도 흔하고 쓸모 있는 재료·물건)
Value.RAW_MADE_ALLOW = {
    ["Base.Rope"] = true, ["Base.Twine"] = true, ["Base.BurlapPiece"] = true, ["Base.EggCarton"] = true,
    ["Base.CuttingBoardWooden"] = true,
}

local rawSet = nil     -- fullType -> "raw" | "made"

local function scriptManager()
    if ScriptManager and ScriptManager.instance then return ScriptManager.instance end
    return getScriptManager and getScriptManager() or nil
end

-- 소모 재료 칸마다 raw 로 채울 수 있는 레시피의 결과물을 set 에 "made" 로 넣는다 (B42 CraftRecipe)
local function addMade(set)
    local sm = scriptManager()
    if not sm then return end
    local ok, recipes = pcall(function() return sm:getAllCraftRecipes() end)
    if not ok or not recipes then return end
    local okN, count = pcall(function() return recipes:size() end)
    if not okN or type(count) ~= "number" then return end
    for i = 0, count - 1 do
        local okR, outs = pcall(function()
            local recipe = recipes:get(i)
            local consumed = 0
            local inputs = recipe:getInputs()
            for j = 0, inputs:size() - 1 do
                local input = inputs:get(j)
                if input:getResourceType() == ResourceType.Item and not input:isTool() and not input:isKeep()
                    and not input:isAutomationOnly() then
                    local items = input:getPossibleInputItems()
                    local fits = false
                    for k = 0, (items and items:size() or 0) - 1 do
                        if set[items:get(k):getFullName()] == "raw" then fits = true end
                    end
                    if not fits then return nil end
                    consumed = consumed + 1
                end
            end
            if consumed == 0 then return nil end
            local list = {}
            local outputs = recipe:getOutputs()
            for j = 0, outputs:size() - 1 do
                local output = outputs:get(j)
                if output:getResourceType() == ResourceType.Item then
                    local results = output:getPossibleResultItems()
                    for k = 0, (results and results:size() or 0) - 1 do list[#list + 1] = results:get(k):getFullName() end
                end
            end
            return list
        end)
        if okR and outs then
            for _, ft in ipairs(outs) do
                if not set[ft] and not Value.RAW_MADE_ALLOW[ft] then set[ft] = "made" end
            end
        end
    end
end

local function buildRaw()
    local set = {}
    for _, ft in ipairs(Value.RAW_EXTRA) do set[ft] = "raw" end
    local defs = forageSystem and forageSystem.itemDefs
    local any = false
    if type(defs) == "table" then
        for key, def in pairs(defs) do
            any = true
            local ft = type(def) == "table" and def.type or key
            for _, c in ipairs(type(def) == "table" and def.categories or {}) do
                if Value.RAW_FORAGE[c] and type(ft) == "string" then set[ft] = "raw" end
            end
        end
    end
    -- 말린 약초·열매 (채집 재료를 건조대에서 말린 것, 2026-10-03 점검): 이름 뒤에 Dried
    local dried = {}
    for ft, k in pairs(set) do
        if k == "raw" then dried[#dried + 1] = ft .. "Dried" end
    end
    for _, ft in ipairs(dried) do set[ft] = set[ft] or "raw" end
    addMade(set)
    -- 채집 정의는 지도 구역을 불러온 뒤(OnLoadedMapZones) 생긴다. 아직이면 다음에 다시 만든다
    if any then
        rawSet = set
        local raw, made = 0, 0
        for _, k in pairs(set) do
            if k == "raw" then raw = raw + 1 else made = made + 1 end
        end
        StoryEngine.log("raw materials:", raw, "made from them:", made)
    end
    return set
end

-- "raw" (채집·벌목 재료) | "made" (그것만으로 만든 1차 가공품) | nil
function Value.rawKind(fullType)
    return (rawSet or buildRaw())[fullType]
end

function Value.isRaw(fullType)
    return Value.rawKind(fullType) ~= nil
end

-- 시험·디버그: 다시 만들게 한다
function Value.resetRaw()
    rawSet = nil
end

-- 대가로 낼 수 있는 아이템인가: 분류가 맞고, 퀘스트 아이템이 아니고, 입고 있는 옷이 아니고, 채집·벌목 재료가 아니다
function Value.payable(player, item, category)
    local mod = item:getModData()
    if mod and mod.storyQuest then return false end
    if Value.isRaw(item:getFullType()) then return false end
    if Value.ratio(item) <= 0 then return false end
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

-- NPC 가 거래 대가로 받는 품목 (Trade.lua 가 쓰고, 클라이언트 툴팁·교신 탭이 보여 준다). 순서 = 선호 순
Value.WANTS = {
    ray = { "food", "medical", "tools", "ammo" },
    casey = { "food", "medical" },
    doc = { "food", "tools", "melee" },
    pike = { "medical", "tools", "food" },
    dewey = { "food", "medical", "ammo" },
    hunter = { "medical", "tools" },
    guard = { "medical", "tools", "food" },
    rats = { "ammo", "firearm", "medical", "tools" },
}

-- 어떤 품목이든 대가로 받는 NPC인가 (빅 교역소 완성, 2026-10-05). 서버는 Projects 가, 클라이언트는 교신 목록(anyWants)이 정한다
Value.anyWantsFn = function(fid) return false end

-- 이 NPC 가 지금 대가로 받는 품목
function Value.wantsOf(fid)
    if Value.anyWantsFn(fid) then return Value.CATEGORIES end
    return Value.WANTS[fid] or {}
end

-- 이 품목을 대가로 받는 NPC id 목록 (Factions.list 순서)
function Value.wantedBy(category)
    local out = {}
    for _, f in ipairs(StoryEngine.Factions and StoryEngine.Factions.list or {}) do
        for _, w in ipairs(Value.wantsOf(f.id)) do
            if w == category then out[#out + 1] = f.id end
        end
    end
    return out
end

-- ---------------------------------------------------------------- NPC 생활 자원 (Life.lua, 물자 지원 창)
-- 물건이 NPC 의 어느 자원을 채우는지: 음식 -> 식량, 의약품 -> 의약품, 총·탄약·근접 무기·폭발물·도구 -> 무기(safety),
-- 술·담배·읽을거리·배터리·초 -> 기호품(morale). 그 외는 받지 않는다.
Value.RESOURCES = { "food", "medical", "safety", "morale" }
Value.RESOURCE_OF = {
    food = "food", medical = "medical",
    firearm = "safety", ammo = "safety", melee = "safety", explosive = "safety", tools = "safety",
}
-- 기호품 (2026-09-30 좁힘): 술 = 알코올이 든 것(음식 isAlcoholic 또는 B42 액체 용기의 알코올, 이름 무관.
-- 위스키·와인·맥주병은 Food 가 아니라 FluidContainer 라 액체로 본다. 빈 병은 아이템마다 확인해 뺀다), 담배 = 이름이 Cigarette·Cigar·Tobacco 로 시작하는
-- 잡동사니(Junk) 분류, 읽을거리 = Literature 분류(소설·잡지·만화·신문. 기술서 SkillBook·레시피 잡지·소품 책은 아님),
-- 그리고 아래 특별 목록(배터리·양초·담배·말린 담뱃잎)
Value.TOBACCO_PREFIX = { "Cigarette", "Cigar", "Tobacco" }
Value.MORALE_SPECIAL = {
    ["Base.Battery"] = 1, ["Base.Candle"] = 0.5, ["Base.CigaretteCarton"] = 8, ["Base.CigarettePack"] = 2,
    ["Base.CigaretteSingle"] = 0.2, ["Base.CigaretteRolled"] = 0.2, ["Base.TobaccoDried"] = 0.5,
}
Value.MORALE_DEFAULT = 1

local moraleCache = {}
Value.ALCOHOL = {}     -- 술이라서 기호품인 fullType (아이템마다 비었는지 다시 본다)

-- 이 아이템에 알코올이 들어 있는가 (음식 isAlcoholic, 또는 액체 용기에 알코올)
function Value.hasAlcohol(item)
    local ok, yes = pcall(function()
        if instanceof(item, "Food") and item:isAlcoholic() then return true end
        local fc = item.getFluidContainer and item:getFluidContainer() or nil
        if not fc or fc:getAmount() <= 0 then return false end
        return fc:getProperties():getAlcohol() > 0
    end)
    return ok and yes == true
end

-- 사기 물건이면 가치, 아니면 nil
function Value.moraleValue(fullType)
    local hit = moraleCache[fullType]
    if hit ~= nil then return hit or nil end
    local value = Value.MORALE_SPECIAL[fullType]
    if not value then
        local ok, cat = pcall(function() return getScriptManager():getItem(fullType):getDisplayCategory() end)
        cat = ok and cat or nil
        local name = string.match(fullType, "%.(.+)$") or fullType
        if StoryEngine.ItemPool.categoryKind(cat) == "literature" then
            value = Value.MORALE_DEFAULT
        elseif cat == "Junk" then
            for _, prefix in ipairs(Value.TOBACCO_PREFIX) do
                if string.sub(name, 1, string.len(prefix)) == prefix then value = Value.MORALE_DEFAULT end
            end
        elseif StoryEngine.ItemPool.isFoodCategory(cat) then
            local okI, item = pcall(instanceItem, fullType)
            if okI and item and Value.hasAlcohol(item) then
                value = Value.MORALE_DEFAULT
                Value.ALCOHOL[fullType] = true
            end
        end
    end
    moraleCache[fullType] = value or false
    return value
end

-- ---------------------------------------------------------------- 품목 점수 부탁 (2026-10-04, 2026-10-05 확장)
-- NPC 가 먼저 하는 부탁의 물건을 "그 품목 아무거나 가치 N점"으로 받는다. 거래 품목 6가지 + 전자기기·차량 부품
-- (ItemTiers 등급) + 기호품(Value.moraleValue). 자재(못·나사·금속판·장작·씨앗 등)는 특정 물건 그대로.
-- 등급 하한(minTier): 그 등급 이상인 물건만 점수로 센다 (탄약은 청한 구경의 등급, 기호품은 등급이 없다)
Value.POINT_KINDS = { food = true, melee = true, firearm = true, medical = true, tools = true, ammo = true,
                      electronics = true, vehicle = true, comfort = true }
Value.POINT_TRADE = { food = true, melee = true, firearm = true, medical = true, tools = true, ammo = true }
Value.POINT_MAX_TIER = { medical = 3 }
Value.POINT_RESOURCE = { electronics = "morale", vehicle = "safety", comfort = "morale" }

-- 이 물건이 어느 점수 품목인가 (아니면 nil)
-- 채집·벌목 재료(장작 등)는 점수 품목이 아니다 (자재로 그 물건 그대로 받는다, 2026-10-06).
-- 기호품 특별 값이 있는 물건(배터리·양초·담배)은 다른 분류보다 기호품이 먼저다
function Value.pointKind(fullType)
    if Value.isRaw(fullType) then return nil end
    if Value.MORALE_SPECIAL[fullType] then return "comfort" end
    local cat = Value.categoryOf(fullType)
    if Value.POINT_TRADE[cat] then return cat end
    local IP = StoryEngine.ItemPool
    if IP.lootTierOf(fullType, "electronics") then return "electronics" end
    if IP.lootTierOf(fullType, "vehicle") then return "vehicle" end
    if Value.moraleValue(fullType) then return "comfort" end
    return nil
end

-- 점수 품목 안에서의 등급 (없으면 nil)
function Value.pointTier(fullType)
    local kind = Value.pointKind(fullType)
    if kind == "electronics" or kind == "vehicle" then return StoryEngine.ItemPool.lootTierOf(fullType, kind) end
    if kind == "comfort" then return nil end
    return lookup(fullType).tier
end

-- 종류 가치 (기호품은 기호품 가치)
function Value.pointOf(fullType)
    if Value.pointKind(fullType) == "comfort" then return Value.moraleValue(fullType) or 0 end
    return Value.of(fullType) or 0
end

-- 물건 하나의 점수 (종류 가치 x 상태 비율)
function Value.pointValue(item)
    return Value.pointOf(item:getFullType()) * Value.ratio(item)
end

-- 이 물건을 이 점수 부탁에 낼 수 있나: 진행 중인 퀘스트 물건·채집 재료·부서진 것·입은 옷·상한 음식·빈 술병이 아니고,
-- 품목이 맞고 등급이 하한 이상
function Value.pointPayable(player, item, kind, minTier)
    if activeQuestItem(item) then return false end
    local ft = item:getFullType()
    if Value.isRaw(ft) then return false end
    if Value.ratio(item) <= 0 then return false end
    if player and player:isEquippedClothing(item) then return false end
    if instanceof(item, "Food") and item:isRotten() then return false end
    if instanceof(item, "InventoryContainer") then return false end
    if Value.pointKind(ft) ~= kind then return false end
    if kind == "comfort" and Value.ALCOHOL[ft] and not Value.hasAlcohol(item) then return false end
    if minTier and minTier > 1 and (Value.pointTier(ft) or 0) < minTier then return false end
    return true
end

function Value.pointItems(player, kind, minTier)
    local out = {}
    local list = player:getInventory():getAllEvalRecurse(function(item)
        return Value.pointPayable(player, item, kind, minTier)
    end)
    for i = 0, list:size() - 1 do out[#out + 1] = list:get(i) end
    return out
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
    if activeQuestItem(item) then return nil end
    if player and (player:isEquippedClothing(item) or player:isEquipped(item)) then return nil end
    if instanceof(item, "Food") and item:isRotten() then return nil end
    if instanceof(item, "InventoryContainer") then return nil end
    local ft = item:getFullType()
    if Value.isRaw(ft) then return nil end
    local res, v = Value.resourceOf(ft)
    -- 다 마신 술병은 받지 않는다
    if res == "morale" and Value.ALCOHOL[ft] and not Value.hasAlcohol(item) then return nil end
    if not res then return nil end
    local ratio = Value.ratio(item)
    if ratio <= 0 then return nil end
    return res, v * ratio
end

-- 아이템 툴팁용 요약 (클라이언트 ItemTooltip). 모드와 상관없는 물건이면 nil
--   { category, value, wanted = { fid... }, resource, resValue, vehicle = 듀이 프로젝트 점수, rotten, quest }
function Value.summary(item)
    local ft = item:getFullType()
    local mod = item:getModData()
    if mod and mod.storyQuest then return { quest = true } end
    local kind = Value.rawKind(ft)
    if kind and (Value.categoryOf(ft) ~= "misc" or Value.resourceOf(ft) or Value.vehicleValue(ft)) then
        return { raw = kind }
    end
    local cat = Value.categoryOf(ft)
    local out = {}
    local any = false
    local ratio = Value.ratio(item)
    if cat ~= "misc" then
        out.category, out.value = cat, Value.of(ft) * ratio
        out.wanted = Value.wantedBy(cat)
        any = true
    end
    local res, rv = Value.resourceOf(ft)
    if res == "morale" and Value.ALCOHOL[ft] and not Value.hasAlcohol(item) then res = nil end
    if res then out.resource, out.resValue = res, rv * ratio; any = true end
    local vv = Value.vehicleValue(ft)
    if vv then out.vehicle = vv; any = true end
    -- 종류와 등급 (2026-10-07): 거래 품목은 그 등급, 거래 품목이 아닌 전자기기·차량 부품은 따로 한 줄
    -- (기호품은 등급이 없고 물자 지원 줄에 이미 나온다)
    local okK, kind = pcall(Value.pointKind, ft)
    if okK and kind and kind ~= "comfort" then
        local okT, tier = pcall(Value.pointTier, ft)
        out.tier = okT and tier or nil
        if not out.category then out.kind = kind; any = true end
    end
    if not any then return nil end
    if instanceof(item, "Food") and item:isRotten() then out.rotten = true end
    if ratio <= 0 then out.broken = true elseif ratio < 1 then out.worn = math.floor(ratio * 100 + 0.5) end
    return out
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
        if ok and StoryEngine.ItemPool.categoryKind(cat) == "vehicle" then
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
    if activeQuestItem(item) then return true end
    if player and (player:isEquippedClothing(item) or player:isEquipped(item)) then return true end
    if instanceof(item, "Food") and item:isRotten() then return true end
    if instanceof(item, "InventoryContainer") then return true end
    if Value.isRaw(item:getFullType()) then return true end
    if Value.ratio(item) <= 0 then return true end
    return false
end

-- 이 물건이 프로젝트에 몇 점인가. 반환: 점수, 물건 가치 (신뢰도 계산용) / 받지 않으면 nil
function Value.projectItem(player, item, rule)
    if not rule or locked(player, item) then return nil end
    local ft = item:getFullType()
    local ratio = Value.ratio(item)
    local res, value = Value.resourceOf(ft)
    if res == "morale" and Value.ALCOHOL[ft] and not Value.hasAlcohol(item) then res, value = nil, nil end
    if value then value = value * ratio end
    if rule.accept == "vehicle" then
        local vv = Value.vehicleValue(ft)
        if vv then return vv * ratio, vv * ratio end
        if res then return value * 0.5, value end
        return nil
    elseif rule.accept == "any" then
        if not res then
            local vv = Value.vehicleValue(ft)
            if vv then res, value = "vehicle", vv * ratio end
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
