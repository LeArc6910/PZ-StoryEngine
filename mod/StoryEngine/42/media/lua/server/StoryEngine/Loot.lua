-- 보상 보급품 구성표 (서버 측 전용). 등급 1~5.
-- 2026-10-04부터 물건은 실시간으로 고른다 (아래 "실시간 보상", Trade.generate). 아래 고정 표는 아이템 풀이 비었을 때만 쓴다.
--
-- 모든 등급에 같은 종류(음식·물, 의약품, 도구, 근접 무기, 총기)가 나오되 품질과 양이 다르다.
--   1 (근처)       : 음식 조금, 붕대, 흔한 도구·근접 무기·권총(낱발) 중 하나
--   2 (같은 동네)   : 음식·음료, 진통제, 쓸 만한 도구, 근접 무기 또는 .45·.357·.44 권총·리볼버+탄약 상자
--   3 (마을 끝)     : 음식 넉넉히, 소독약, 쓸 만한 도구, 사냥소총(.308·.30-30)+탄약 상자
--   4 (교외)        : 많은 음식·물, 항생제, 희귀 도구, 산탄총+탄약 2상자
-- 다른 모드 총으로 바꿀 때의 총 등급은 탄약 등급 + 사격 방식 (ItemPool.AMMO_TIERS, ACTION_MOD)
--   5 (다른 도시)   : 대량의 음식·물, 의약품 세트, 희귀 도구 2개, 돌격소총+탄약 4상자 + 권총
-- 탄창을 쓰는 총에는 탄창을 함께 넣는다.

-- 다른 모드 아이템: 샌드박스 비율(기본 40%)로 음식·근접 무기는 비슷한 등급의 풀 아이템으로, 총 묶음은 같은 등급의
-- 풀 총(맞는 탄약·탄창 포함)으로 바꾼다 (ItemPool). 의약품·도구·음료는 바닐라 그대로.

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/ItemPool"

local Loot = {}
StoryEngine.Loot = Loot

Loot.MAX_TIER = 5

local SNACK = { "Base.TinnedBeans", "Base.CannedCorn", "Base.Crisps", "Base.GranolaBar", "Base.Chocolate" }
local CANNED = { "Base.TinnedBeans", "Base.CannedCorn", "Base.CannedChili", "Base.TinnedSoup", "Base.CannedCornedBeef",
                 "Base.PeanutButter", "Base.BeefJerky" }
local HEARTY = { "Base.CannedChili", "Base.CannedBolognese", "Base.CannedCornedBeef", "Base.TinnedSoup",
                 "Base.PeanutButter", "Base.BeefJerky", "Base.CannedPeaches", "Base.CannedPineapple",
                 "Base.CannedFruitCocktail" }

Loot.FOOD = { SNACK, CANNED, CANNED, HEARTY, HEARTY }
Loot.FOOD_COUNT = { 3, 5, 7, 9, 12 }

local JUICE = { "Base.JuiceBox", "Base.JuiceBoxApple", "Base.JuiceBoxOrange" }
local DRINK = { "Base.CannedFruitBeverage", "Base.JuiceBox", "Base.WaterRationCan" }
local WATER = { "Base.WaterRationCan", "Base.CannedFruitBeverage" }
Loot.DRINK = { JUICE, DRINK, DRINK, WATER, WATER }
Loot.DRINK_COUNT = { 1, 2, 3, 4, 6 }
Loot.TIN_OPENER_FROM = 3      -- 이 등급부터 캔따개를 넣는다

Loot.MEDICAL = {
    { { "Base.Bandage", 2 } },
    { { "Base.Bandage", 2 }, { "Base.Pills", 1 } },
    { { "Base.Bandage", 3 }, { "Base.Disinfectant", 1 }, { "Base.Pills", 1 } },
    { { "Base.Bandage", 3 }, { "Base.Disinfectant", 1 }, { "Base.AlcoholWipes", 1 }, { "Base.Pills", 1 },
      { "Base.Antibiotics", 1 } },
    { { "Base.Bandage", 4 }, { "Base.Disinfectant", 1 }, { "Base.AlcoholWipes", 2 }, { "Base.Pills", 2 },
      { "Base.Antibiotics", 2 }, { "Base.SutureNeedle", 1 }, { "Base.Splint", 1 } },
}

local COMMON_TOOL = { "Base.Screwdriver", "Base.Saw", "Base.Hammer", "Base.Pliers" }
local GOOD_TOOL = { "Base.Crowbar", "Base.Wrench", "Base.HandAxe", "Base.Shovel" }
local RARE_TOOL = { "Base.Sledgehammer", "Base.PipeWrench", "Base.WoodAxe", "Base.BlowTorch" }
Loot.TOOL = { COMMON_TOOL, GOOD_TOOL, GOOD_TOOL, RARE_TOOL, RARE_TOOL }
Loot.TOOL_COUNT = { 1, 1, 1, 1, 2 }

Loot.MELEE = {
    { "Base.KitchenKnife", "Base.BaseballBat" },
    { "Base.HuntingKnife", "Base.BaseballBat" },
    { "Base.Machete", "Base.HuntingKnife", "Base.Crowbar" },
    { "Base.Machete", "Base.Katana", "Base.Axe" },
    { "Base.Katana", "Base.Axe" },
}

-- 총 묶음: { { 아이템, 개수 }, ... }
local PISTOL_FEW = {
    { { "Base.Pistol", 1 }, { "Base.9mmClip", 1 }, { "Base.Bullets9mm", 12 } },
    { { "Base.Revolver_Short", 1 }, { "Base.Bullets38", 12 } },
}
local HANDGUN_BOX = {
    { { "Base.Pistol2", 1 }, { "Base.45Clip", 1 }, { "Base.Bullets45Box", 1 } },
    { { "Base.Revolver", 1 }, { "Base.Bullets357Box", 1 } },
    { { "Base.Pistol3", 1 }, { "Base.44Clip", 1 }, { "Base.Bullets44Box", 1 } },
    { { "Base.Revolver_Long", 1 }, { "Base.Bullets44Box", 1 } },
}
local HANDGUN_RIFLE = {
    { { "Base.HuntingRifle", 1 }, { "Base.308Box", 1 } },
    { { "Base.L94_Rifle", 1 }, { "Base.3030Box", 1 } },
    { { "Base.MSR7T_Rifle", 1 }, { "Base.308Box", 1 } },
}
local SHOTGUN = {
    { { "Base.Shotgun", 1 }, { "Base.ShotgunShellsBox", 2 } },
    { { "Base.DoubleBarrelShotgun", 1 }, { "Base.ShotgunShellsBox", 2 } },
}
local RIFLE_BIG = {
    { { "Base.AssaultRifle", 1 }, { "Base.556Clip", 2 }, { "Base.556Box", 4 },
      { "Base.Pistol3", 1 }, { "Base.44Clip", 1 }, { "Base.Bullets44Box", 1 } },
    { { "Base.AssaultRifle2", 1 }, { "Base.M14Clip", 2 }, { "Base.308Box", 4 },
      { "Base.Pistol2", 1 }, { "Base.45Clip", 1 }, { "Base.Bullets45Box", 1 } },
}
Loot.GUN = { PISTOL_FEW, HANDGUN_BOX, HANDGUN_RIFLE, SHOTGUN, RIFLE_BIG }

-- 등급별 도구·근접 무기·총기가 들어갈 확률 (%)
Loot.CHANCE = {
    { tool = 55, melee = 30, gun = 15 },     -- 1등급은 이 셋 중 하나만
    { tool = 100, melee = 65, gun = 35 },    -- 2등급은 근접 무기와 총 중 하나
    { tool = 100, melee = 50, gun = 70 },
    { tool = 100, melee = 60, gun = 100 },
    { tool = 100, melee = 70, gun = 100 },
}

local function pick(pool)
    return pool[ZombRand(#pool) + 1]
end

local ItemPool = StoryEngine.ItemPool

-- 보상 등급별 총 묶음의 탄약 (풀 총으로 바꿀 때)
Loot.GUN_AMMO = { { loose = 12 }, { boxes = 1 }, { boxes = 1 }, { boxes = 2 }, { boxes = 4, mags = 2 } }

local function add(out, fullType, count)
    for _ = 1, count or 1 do out[#out + 1] = fullType end
end

-- 음식·근접 무기를 넣는다. 한 개마다 일정 확률로 비슷한 등급의 다른 아이템으로 바꾼다
local function addMixed(out, fullType, count)
    for _ = 1, count or 1 do
        out[#out + 1] = ItemPool.roll() and ItemPool.substitute(fullType) or fullType
    end
end
Loot.addMixed = addMixed

-- 총 묶음. 일정 확률로 같은 등급의 풀 총 묶음으로 바꾼다
local function addGun(out, bundle, tier)
    if ItemPool.roll() then
        local modded = ItemPool.gunBundle(tier, Loot.GUN_AMMO[tier] or { boxes = 1 })
        if modded then bundle = modded end
    end
    for _, entry in ipairs(bundle) do add(out, entry[1], entry[2]) end
end
Loot.addGun = addGun

local function chance(percent)
    return ZombRand(100) < percent
end

-- 샌드박스 보상 배율: 음식·물·의약품·전문 묶음의 개수 (총·도구·근접 무기는 그대로)
local function scaled(n)
    local m = StoryEngine.Tuning and StoryEngine.Tuning.num("RewardMult") or 1
    if m == 1 or not n or n <= 0 then return n end
    local v = n * m
    local whole = math.floor(v)
    if v > whole and ZombRand(100) < (v - whole) * 100 then whole = whole + 1 end
    return math.max(1, whole)
end
Loot.scaled = scaled

-- 세력 전문 보상: 그 세력이 남기는 보급품(선물·대가)에 등급별로 한 묶음을 더 넣는다.
Loot.SPECIALTY = {
    ray = {   -- 농가: 통조림, 씨앗, 원예
        { { "Base.TinnedBeans", 2 }, { "Base.CarrotBagSeed2", 1 } },
        { { "Base.CannedCorn", 2 }, { "Base.CannedPeaches", 1 }, { "Base.TomatoBagSeed2", 1 }, { "Base.PotatoBagSeed2", 1 } },
        { { "Base.CannedCornedBeef", 3 }, { "Base.Honey", 1 }, { "Base.HandShovel", 1 }, { "Base.CarrotBagSeed2", 2 } },
        { { "Base.CannedCornedBeef", 4 }, { "Base.CannedPeaches", 3 }, { "Base.GardenHoe", 1 }, { "Base.BookFarming2", 1 },
          { "Base.TomatoBagSeed2", 2 } },
        { { "Base.CannedCornedBeef", 6 }, { "Base.Honey", 2 }, { "Base.GardenHoe", 1 }, { "Base.BookFarming3", 1 },
          { "Base.CarrotBagSeed2", 3 }, { "Base.PotatoBagSeed2", 3 }, { "Base.TomatoBagSeed2", 3 } },
    },
    casey = {   -- 전자기기: 배터리, 무전기, 손전등, 전기 부품
        { { "Base.Battery", 3 } },
        { { "Base.HandTorch", 1 }, { "Base.Battery", 4 } },
        { { "Base.WalkieTalkie3", 1 }, { "Base.Battery", 4 }, { "Base.ElectronicsScrap", 5 } },
        { { "Base.WalkieTalkie4", 1 }, { "Base.BookElectrician2", 1 }, { "Base.ElectricWire", 3 }, { "Base.Battery", 6 } },
        { { "Base.Generator", 1 }, { "Base.BookElectrician3", 1 }, { "Base.Battery", 6 } },
    },
    doc = {   -- 의약품
        { { "Base.Bandage", 2 }, { "Base.AlcoholWipes", 2 } },
        { { "Base.Pills", 1 }, { "Base.Disinfectant", 1 }, { "Base.Tweezers", 1 } },
        { { "Base.Antibiotics", 1 }, { "Base.SutureNeedle", 2 }, { "Base.SutureNeedleHolder", 1 } },
        { { "Base.Antibiotics", 2 }, { "Base.Splint", 2 }, { "Base.Scalpel", 1 }, { "Base.BookFirstAid2", 1 } },
        { { "Base.Bag_MedicalBag", 1 }, { "Base.Antibiotics", 3 }, { "Base.SutureNeedle", 3 }, { "Base.BookFirstAid3", 1 },
          { "Base.PillsVitamins", 2 } },
    },
    pike = {   -- 생필품: 물, 양초, 불, 식량
        { { "Base.WaterRationCan", 1 }, { "Base.Candle", 2 }, { "Base.Matches", 1 } },
        { { "Base.WaterRationCan", 2 }, { "Base.TinnedSoup", 2 }, { "Base.Candle", 2 } },
        { { "Base.WaterPurificationTablets", 1 }, { "Base.WaterRationCan", 3 }, { "Base.Lantern_Hurricane", 1 }, { "Base.Matches", 2 } },
        { { "Base.WaterRationCan", 4 }, { "Base.CannedChili", 3 }, { "Base.Coffee2", 1 }, { "Base.Sugar", 1 }, { "Base.Lighter", 1 } },
        { { "Base.WaterRationCan", 6 }, { "Base.CannedBolognese", 4 }, { "Base.CannedFruitCocktail", 3 },
          { "Base.Bag_BigHikingBag", 1 }, { "Base.Lantern_Hurricane", 1 } },
    },
    dewey = {   -- 차량 정비
        { { "Base.Wrench", 1 } },
        { { "Base.LugWrench", 1 }, { "Base.TirePump", 1 } },
        { { "Base.Jack", 1 }, { "Base.EngineParts", 5 } },
        { { "Base.CarBattery1", 1 }, { "Base.EngineParts", 8 }, { "Base.BookMechanic2", 1 } },
        { { "Base.CarBattery2", 1 }, { "Base.EngineParts", 12 }, { "Base.ModernTire1", 1 }, { "Base.BookMechanic3", 1 } },
    },
    guard = {   -- 군용: 탄약, 방호구, 군장
        { { "Base.Bullets9mm", 12 } },
        { { "Base.Bullets9mmBox", 1 }, { "Base.Hat_Army", 1 } },
        { { "Base.Bullets9mmBox", 1 }, { "Base.556Box", 1 }, { "Base.Vest_BulletPolice", 1 } },
        { { "Base.556Box", 2 }, { "Base.556Clip", 1 }, { "Base.Vest_BulletArmy", 1 }, { "Base.Bag_ALICEpack_Army", 1 } },
        { { "Base.AssaultRifle", 1 }, { "Base.556Clip", 2 }, { "Base.556Box", 3 }, { "Base.Vest_BulletArmy", 1 } },
    },
    rats = {   -- 약탈품: 공구, 담배, 술
        { { "Base.CigarettePack", 1 }, { "Base.DuctTape", 1 } },
        { { "Base.Crowbar", 1 }, { "Base.Whiskey", 1 } },
        { { "Base.Crowbar", 1 }, { "Base.NailsBox", 1 }, { "Base.ScrewsBox", 1 }, { "Base.CigarettePack", 2 } },
        { { "Base.Sledgehammer", 1 }, { "Base.BlowTorch", 1 }, { "Base.Whiskey", 2 } },
        { { "Base.Sledgehammer", 1 }, { "Base.PipeWrench", 1 }, { "Base.BlowTorch", 1 }, { "Base.PropaneTank", 1 },
          { "Base.Bag_DuffelBag", 1 } },
    },
    hunter = {   -- 사냥: 덫, 칼, 소총, 육포
        { { "Base.BeefJerky", 2 }, { "Base.TrapSnare", 1 } },
        { { "Base.HuntingKnife", 1 }, { "Base.TrapCage", 1 }, { "Base.Twine", 2 } },
        { { "Base.308Box", 1 }, { "Base.TrapCage", 1 }, { "Base.BookTrapping1", 1 }, { "Base.DehydratedMeatStick", 3 } },
        { { "Base.HuntingRifle", 1 }, { "Base.308Box", 2 }, { "Base.x2Scope", 1 } },
        { { "Base.HuntingRifle", 1 }, { "Base.x4Scope", 1 }, { "Base.308Box", 3 }, { "Base.WoodAxe", 1 }, { "Base.BookTrapping3", 1 } },
    },
}

-- ---------------------------------------------------------------- 실시간 보상 (2026-10-04 사용자 결정)
-- 거래 묶음과 같은 생성기(Trade.generate): 품목마다 그 등급 물건 1개 + 남은 예산을 그 등급 이하 물건으로 무작위로.
-- 구성(음식·음료·의약품, 등급별 확률로 도구·근접 무기·총)과 확률(Loot.CHANCE)은 예전 그대로이고, 물건만 실시간으로 고른다.
-- 예산은 예전 고정 보상의 가치에 맞췄다. 샌드박스 보상 배율(RewardMult)은 모든 품목과 전문 묶음 예산에 곱한다 (2026-10-07).
-- 전문 보상은 그 세력의 전문 품목(Loot.SPECIALTY_CAT, 케이시·듀이는 전자기기·차량 부품 풀)을 거래 예산의 절반으로.
-- 생성기가 물건을 못 고르면(아이템 풀이 비었을 때) 아래 예전 고정 표를 쓴다.
Loot.BUDGET = {
    food = { 3, 8, 11, 16, 22 }, medical = { 4, 8, 12, 18, 40 }, tools = { 2, 4, 8, 14, 40 },
    melee = { 3, 4, 5, 8, 12 }, firearm = { 35, 57, 70, 110, 220 },
}
Loot.SPECIALTY_CAT = { ray = "food", casey = "tools", doc = "medical", pike = "food", dewey = "tools",
                       guard = "ammo", rats = "tools", hunter = "melee" }
Loot.SPECIALTY_SHARE = 0.5

local function rewardMult()
    return StoryEngine.Tuning and StoryEngine.Tuning.num("RewardMult") or 1
end

-- 생성기로 한 품목 (실패하면 nil)
local function gen(category, tier, fid, budget)
    local Trade = StoryEngine.Trade
    if not Trade or not Trade.generate then return nil end
    local ok, goods = pcall(Trade.generate, category, tier, fid, budget)
    if ok and goods and #goods > 0 then return goods end
    if not ok then StoryEngine.log("loot generate failed:", category, tier, tostring(goods)) end
    return nil
end

local function append(out, list)
    for _, ft in ipairs(list) do out[#out + 1] = ft end
end

-- 등급(1~5)에 맞는 보상 목록 (전체 타입 이름 배열). fid 를 주면 그 세력의 전문 보상을 더한다.
function Loot.roll(tier, fid)
    tier = math.max(1, math.min(Loot.MAX_TIER, math.floor(tier or 1)))
    local out = Loot.rollBase(tier)
    local cat = fid and Loot.SPECIALTY_CAT[fid]
    local Trade = StoryEngine.Trade
    local made = cat and Trade and Trade.BUDGET and Trade.BUDGET[cat]
        and gen(cat, tier, fid, Trade.BUDGET[cat][tier] * Loot.SPECIALTY_SHARE * rewardMult()) or nil
    if made then
        append(out, made)
        return out
    end
    local special = fid and Loot.SPECIALTY[fid] and Loot.SPECIALTY[fid][tier]
    if special then
        for _, entry in ipairs(special) do add(out, entry[1], scaled(entry[2] or 1)) end
    end
    return out
end

-- 한 품목: 생성기로, 못 하면 fallback() (예전 고정 표)
local function part(out, category, tier, scale, fallback)
    -- 보상 배율은 모든 품목의 예산에 곱한다 (2026-10-07, 예전엔 음식·의약품만)
    local made = gen(category, tier, nil, Loot.BUDGET[category][tier] * rewardMult())
    if made then append(out, made) else fallback() end
end

function Loot.rollBase(tier)
    local out = {}
    part(out, "food", tier, true, function()
        for _ = 1, scaled(Loot.FOOD_COUNT[tier]) do addMixed(out, pick(Loot.FOOD[tier])) end
    end)
    for _ = 1, scaled(Loot.DRINK_COUNT[tier]) do add(out, pick(Loot.DRINK[tier])) end
    if tier >= Loot.TIN_OPENER_FROM then add(out, "Base.TinOpener") end
    part(out, "medical", tier, true, function()
        for _, entry in ipairs(Loot.MEDICAL[tier]) do add(out, entry[1], scaled(entry[2] or 1)) end
    end)

    local tool = function() part(out, "tools", tier, false, function() add(out, pick(Loot.TOOL[tier])) end) end
    local melee = function() part(out, "melee", tier, false, function() addMixed(out, pick(Loot.MELEE[tier])) end) end
    local gun = function() part(out, "firearm", tier, false, function() addGun(out, pick(Loot.GUN[tier]), tier) end) end
    local c = Loot.CHANCE[tier]
    if tier == 1 then
        -- 가까운 보급은 도구·근접 무기·권총 중 하나만
        local roll = ZombRand(100)
        if roll < c.gun then gun()
        elseif roll < c.gun + c.melee then melee()
        elseif roll < c.gun + c.melee + c.tool then tool() end
        return out
    end
    -- 도구는 한 묶음 (5등급 예산이면 둘)
    if chance(c.tool) then tool() end
    if tier == 2 then
        -- 같은 동네 보급은 근접 무기와 총 중 하나
        if chance(c.gun) then gun() else melee() end
        return out
    end
    if chance(c.gun) then gun() end
    if chance(c.melee) then melee() end
    return out
end

return Loot
