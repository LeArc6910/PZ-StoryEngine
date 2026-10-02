-- 플레이어가 먼저 요청하는 거래 (서버 측 전용, B단계).
--
-- 1. 플레이어가 무전으로 물건을 요청하면, Radio 가 Trade.context 로 계산한 "지금 가능한 거래 한도"를 AI 에 넘긴다.
-- 2. AI 는 답장과 함께 trade = { action, category, tier, pay_category } 를 돌려준다.
-- 3. Trade.fromReply 가 한도로 다시 검증하고(넘으면 낮추지 않고 버림 + "신뢰도 N 필요" 안내), 실제 물건과 가격은
--    게임이 정해 거래 제안을 만든다. AI 가 한도 때문에 거절하면 Trade.blocked 로 필요한 신뢰도를 알린다.
-- 3-1. 제안이 답을 기다리는 동안 플레이어는 무전으로 흥정할 수 있다 (Trade.negotiate). AI 가 action = "counter" 로
--    새 가격·대가 품목을 내면 게임이 신뢰도별 하한선(HAGGLE)과 횟수(MAX_HAGGLES)로 검증해 조건을 바꾼다.
--    "withdraw" 면 NPC 가 제안을 거둔다 (신뢰도 변화 없음).
-- 4. 플레이어가 수락하면 대가 제출 창에서 아이템을 골라 보낸다 (Trade.pay). 가치를 채우면 물건이 보급 퀘스트로 온다.
-- 신뢰도: 성사 +3, 수락 후 미지불 -4 (Trust.lua, initiator = "player").

if isClient() then return end

require "StoryEngine/Items"
require "StoryEngine/Core"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Value"
require "StoryEngine/Radio"
require "StoryEngine/Loot"
require "StoryEngine/Quests"

local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Value = StoryEngine.Value
local Radio = StoryEngine.Radio
local Quests = StoryEngine.Quests
local log = StoryEngine.log

local Trade = {}
StoryEngine.Trade = Trade

-- 신뢰도별 한도: 이 신뢰도 이상이면 maxTier 등급까지, 가격 배율 mult
Trade.LIMITS = {
    { min = 80, maxTier = 5, mult = 1.0 },
    { min = 60, maxTier = 4, mult = 1.2 },
    { min = 40, maxTier = 3, mult = 1.5 },
    { min = 20, maxTier = 2, mult = 2.0 },
    { min = 0, maxTier = 0, mult = nil },       -- 거래 거부, 대화만
}

-- 세력 성향: 줄 수 있는 품목별 최고 등급, 대가로 받는 품목
--   guard: 총기·탄약은 신뢰도 gunTrust 이상에서만
--   rats : 신뢰도 한도보다 stretch 등급 높은 것도 팔지만 그만큼은 stretchMult 배 비싸다
--   pike : 값을 덜 받는다 (priceMult)
--   haggle: 흥정 하한선 보정 (+ 면 덜 깎아 준다)
Trade.FACTIONS = {
    ray = { goods = { food = 5, medical = 3, tools = 3, melee = 2, firearm = 1, ammo = 2 } },
    casey = { goods = { tools = 5, food = 1, medical = 1 } },
    doc = { goods = { medical = 5, food = 2, tools = 2 } },
    pike = { goods = { food = 5, medical = 2, tools = 2, melee = 1 }, priceMult = 0.8, haggle = -0.05 },
    dewey = { goods = { tools = 5, melee = 3, food = 1 } },
    hunter = { goods = { firearm = 4, ammo = 4, melee = 4, food = 3 } },
    guard = { goods = { food = 3, medical = 3, tools = 3, melee = 3, firearm = 5, ammo = 5 }, gunTrust = 60, haggle = 0.05 },
    rats = { goods = { food = 3, medical = 3, tools = 5, melee = 5, firearm = 4, ammo = 4 }, stretch = 1, stretchMult = 1.5, haggle = 0.1 },
}
-- 대가로 받는 품목은 공용 Value.WANTS (클라이언트 툴팁·교신 탭도 같은 표를 쓴다)
for fid, rules in pairs(Trade.FACTIONS) do rules.wants = Value.WANTS[fid] or {} end

-- 품목·등급별로 건네는 물건 묶음 ({ 아이템, 개수 } 목록 중 하나를 고른다)
local L = StoryEngine.Loot
Trade.GOODS = {
    food = {
        { { { "Base.TinnedBeans", 3 }, { "Base.JuiceBox", 1 } } },
        { { { "Base.CannedChili", 3 }, { "Base.TinnedSoup", 2 }, { "Base.WaterRationCan", 2 } } },
        { { { "Base.CannedCornedBeef", 4 }, { "Base.BeefJerky", 2 }, { "Base.CannedChili", 2 }, { "Base.WaterRationCan", 3 },
            { "Base.TinOpener", 1 } } },
        { { { "Base.CannedBolognese", 5 }, { "Base.CannedCornedBeef", 4 }, { "Base.PeanutButter", 3 },
            { "Base.WaterRationCan", 5 } } },
        { { { "Base.CannedBolognese", 7 }, { "Base.CannedCornedBeef", 6 }, { "Base.PeanutButter", 3 }, { "Base.BeefJerky", 2 },
            { "Base.WaterRationCan", 8 }, { "Base.TinOpener", 1 } } },
    },
    medical = {
        { { { "Base.Bandage", 3 } } },
        { { { "Base.Bandage", 3 }, { "Base.Pills", 1 }, { "Base.Disinfectant", 1 } } },
        { { { "Base.Bandage", 4 }, { "Base.Disinfectant", 1 }, { "Base.AlcoholWipes", 2 }, { "Base.Antibiotics", 1 } } },
        { { { "Base.Bandage", 5 }, { "Base.Disinfectant", 1 }, { "Base.Antibiotics", 2 }, { "Base.SutureNeedle", 2 },
            { "Base.Splint", 1 } } },
        { { { "Base.Bandage", 8 }, { "Base.Disinfectant", 2 }, { "Base.Pills", 2 }, { "Base.Antibiotics", 4 },
            { "Base.SutureNeedle", 3 }, { "Base.Splint", 2 } } },
    },
    tools = {
        { { { "Base.Screwdriver", 1 } }, { { "Base.Saw", 1 } }, { { "Base.Hammer", 1 } } },
        { { { "Base.Crowbar", 1 } }, { { "Base.Wrench", 1 } }, { { "Base.HandAxe", 1 } } },
        { { { "Base.Crowbar", 1 }, { "Base.Saw", 1 } }, { { "Base.Shovel", 1 }, { "Base.Hammer", 1 } } },
        { { { "Base.Sledgehammer", 1 } }, { { "Base.WoodAxe", 1 } }, { { "Base.BlowTorch", 1 } } },
        { { { "Base.Sledgehammer", 1 }, { "Base.PipeWrench", 1 } }, { { "Base.WoodAxe", 1 }, { "Base.BlowTorch", 1 } } },
    },
    melee = {
        { { { "Base.KitchenKnife", 1 } }, { { "Base.BaseballBat", 1 } } },
        { { { "Base.HuntingKnife", 1 } }, { { "Base.BaseballBat", 1 } } },
        { { { "Base.Machete", 1 } }, { { "Base.Crowbar", 1 } } },
        { { { "Base.Katana", 1 } }, { { "Base.Axe", 1 } } },
        { { { "Base.Katana", 1 }, { "Base.Machete", 1 } } },
    },
    firearm = L.GUN,
    ammo = {
        { { { "Base.Bullets9mm", 24 } }, { { "Base.ShotgunShells", 12 } } },
        { { { "Base.Bullets9mmBox", 1 } }, { { "Base.ShotgunShellsBox", 1 } } },
        { { { "Base.Bullets9mmBox", 2 } }, { { "Base.Bullets45Box", 2 } }, { { "Base.308Box", 2 } } },
        { { { "Base.ShotgunShellsBox", 3 } }, { { "Base.308Box", 3 } }, { { "Base.556Box", 3 } } },
        { { { "Base.556Box", 5 }, { "Base.308Box", 3 } } },
    },
}

-- 세력 전문 거래 품목: 이 품목은 기본 목록(Trade.GOODS) 대신 이것을 쓴다
Trade.FACTION_GOODS = {
    doc = {
        medical = {
            { { { "Base.Bandage", 4 }, { "Base.AlcoholWipes", 2 } } },
            { { { "Base.Bandage", 4 }, { "Base.Pills", 2 }, { "Base.Disinfectant", 1 }, { "Base.Tweezers", 1 } } },
            { { { "Base.Antibiotics", 2 }, { "Base.SutureNeedle", 2 }, { "Base.SutureNeedleHolder", 1 }, { "Base.Disinfectant", 1 },
                { "Base.Bandage", 4 } } },
            { { { "Base.Antibiotics", 3 }, { "Base.SutureNeedle", 3 }, { "Base.Splint", 2 }, { "Base.Scalpel", 1 },
                { "Base.Bandage", 6 }, { "Base.PillsVitamins", 1 } } },
            { { { "Base.Bag_MedicalBag", 1 }, { "Base.Antibiotics", 5 }, { "Base.SutureNeedle", 4 }, { "Base.SutureNeedleHolder", 1 },
                { "Base.Splint", 3 }, { "Base.Bandage", 10 }, { "Base.Disinfectant", 2 }, { "Base.Pills", 3 } } },
        },
    },
    dewey = {
        tools = {
            { { { "Base.Screwdriver", 1 } }, { { "Base.Wrench", 1 } } },
            { { { "Base.LugWrench", 1 }, { "Base.Jack", 1 } }, { { "Base.TirePump", 1 }, { "Base.Wrench", 1 } } },
            { { { "Base.EngineParts", 5 }, { "Base.Wrench", 1 } }, { { "Base.CarBattery1", 1 } } },
            { { { "Base.CarBattery2", 1 }, { "Base.EngineParts", 10 } }, { { "Base.BlowTorch", 1 }, { "Base.WeldingMask", 1 },
                { "Base.WeldingRods", 2 } } },
            { { { "Base.CarBattery3", 1 }, { "Base.EngineParts", 15 }, { "Base.BookMechanic3", 1 } },
              { { "Base.BlowTorch", 1 }, { "Base.WeldingMask", 1 }, { "Base.PropaneTank", 1 }, { "Base.Toolbox", 1 } } },
        },
    },
    casey = {
        tools = {
            { { { "Base.Battery", 4 } }, { { "Base.HandTorch", 1 }, { "Base.Battery", 2 } } },
            { { { "Base.WalkieTalkie3", 1 }, { "Base.Battery", 4 } }, { { "Base.RadioBlack", 1 }, { "Base.Battery", 4 } } },
            { { { "Base.ElectronicsScrap", 10 }, { "Base.ElectricWire", 3 }, { "Base.BookElectrician1", 1 } },
              { { "Base.WalkieTalkie4", 1 }, { "Base.Battery", 6 } } },
            { { { "Base.HamRadio1", 1 } }, { { "Base.Amplifier", 1 }, { "Base.ElectronicsScrap", 15 }, { "Base.ElectricWire", 5 } } },
            { { { "Base.Generator", 1 } }, { { "Base.HamRadio1", 1 }, { "Base.WalkieTalkie5", 1 }, { "Base.BookElectrician3", 1 } } },
        },
    },
    hunter = {
        firearm = {
            { { { "Base.Revolver_Short", 1 }, { "Base.Bullets38", 12 } } },
            { { { "Base.Revolver", 1 }, { "Base.Bullets357Box", 1 } }, { { "Base.Revolver_Long", 1 }, { "Base.Bullets44Box", 1 } } },
            { { { "Base.HuntingRifle", 1 }, { "Base.308Box", 1 } }, { { "Base.L94_Rifle", 1 }, { "Base.3030Box", 1 } } },
            { { { "Base.HuntingRifle", 1 }, { "Base.308Box", 2 }, { "Base.x4Scope", 1 } },
              { { "Base.DoubleBarrelShotgun", 1 }, { "Base.ShotgunShellsBox", 2 } } },
        },
        melee = {
            { { { "Base.KitchenKnife", 1 } } },
            { { { "Base.HuntingKnife", 1 } } },
            { { { "Base.HandAxe", 1 }, { "Base.HuntingKnife", 1 } } },
            { { { "Base.WoodAxe", 1 } }, { { "Base.Machete", 1 }, { "Base.HuntingKnife", 1 } } },
        },
        food = {
            { { { "Base.BeefJerky", 2 }, { "Base.DehydratedMeatStick", 2 } } },
            { { { "Base.BeefJerky", 4 }, { "Base.WaterRationCan", 2 } } },
            { { { "Base.BeefJerky", 6 }, { "Base.DehydratedMeatStick", 4 }, { "Base.WaterRationCan", 3 } } },
        },
    },
}

-- 요청 빈도: 같은 세력에게 서버 전체(모든 플레이어 합산)가 게임 시간 일주일 안에 3번째 요청부터 의심해서 신뢰도 -1
Trade.REQUEST_WINDOW_MIN = 7 * 24 * 60
Trade.SUSPICIOUS_COUNT = 3
-- 신뢰도가 높으면 낮은 등급 요청은 가끔 대가 없이 준다 (AI 가 action = "gift" 로 고른다)
Trade.FREE_TRUST = 60
Trade.FREE_MAX_TIER = 2
Trade.FREE_CHANCE = 35     -- 요청마다 게임이 굴린다. 맡기면 AI 가 거의 주지 않아서 (모델 테스트 0/4)

local function requestTimes(fid, now)
    local ch = Radio.channel(fid)
    local kept = {}
    for _, t in ipairs(ch.requestLog or {}) do
        if now.t - t < Trade.REQUEST_WINDOW_MIN then kept[#kept + 1] = t end
    end
    ch.requestLog = kept
    return kept
end

function Trade.recentRequests(fid)
    return #requestTimes(fid, Sensor.now())
end

-- 플레이어가 물건을 청했다 (AI 가 제안·거절·선물 중 하나로 답함). 일주일에 SUSPICIOUS_COUNT 번째부터 신뢰도 -1
function Trade.recordRequest(fid, ps)
    local now = Sensor.now()
    local list = requestTimes(fid, now)
    list[#list + 1] = now.t
    if #list >= Trade.SUSPICIOUS_COUNT and StoryEngine.Trust then
        StoryEngine.Trust.apply(fid, -1, "suspicious", nil, ps and ps.key)
    end
    return #list
end

-- 흥정: 신뢰도별로 처음 제안 가격의 몇 %까지 깎아 주는지 (세력 haggle 로 보정), 제안 하나에 몇 번까지
Trade.HAGGLE = {
    { min = 80, floor = 0.6 },
    { min = 60, floor = 0.7 },
    { min = 40, floor = 0.8 },
    { min = 0, floor = 0.9 },
}
Trade.MAX_HAGGLES = 3

local function limitFor(trust)
    for _, row in ipairs(Trade.LIMITS) do
        if trust >= row.min then return row end
    end
    return Trade.LIMITS[#Trade.LIMITS]
end

local function isGunCat(category)
    return category == "firearm" or category == "ammo"
end

-- 이 품목·등급을 거래하려면 필요한 신뢰도. 이 세력이 아예 취급하지 않으면 nil
function Trade.needTrust(fid, category, tier)
    local rules = Trade.FACTIONS[fid]
    if not rules or tier > (rules.goods[category] or 0) then return nil end
    local need = nil
    for _, row in ipairs(Trade.LIMITS) do        -- 높은 신뢰도부터: 조건을 만족하는 마지막 줄이 가장 낮은 신뢰도
        if row.maxTier > 0 and row.maxTier + (rules.stretch or 0) >= tier then need = row.min end
    end
    if need and rules.gunTrust and isGunCat(category) then need = math.max(need, rules.gunTrust) end
    return need
end

local function minTradeTrust()
    local low = 100
    for _, row in ipairs(Trade.LIMITS) do
        if row.maxTier > 0 then low = math.min(low, row.min) end
    end
    return low
end

-- 신뢰도 때문에 거래할 수 없는 요청이면 안내 정보를 돌려준다.
-- { category, tier, need = 필요한 신뢰도 } | { category, tier?, never = true } (취급 안 함) | { need } (아예 거래 전) | nil
function Trade.blocked(fid, category, tier)
    local rules = Trade.FACTIONS[fid]
    if not rules then return nil end
    local trust = Radio.channel(fid).trust
    local known = false
    for _, cat in ipairs(Value.CATEGORIES) do
        if cat == category then known = true end
    end
    if not known then
        local low = minTradeTrust()
        if trust < low then return { need = low } end
        return nil
    end
    if (rules.goods[category] or 0) <= 0 then return { category = category, never = true } end
    tier = math.max(1, math.min(5, math.floor(tonumber(tier) or 1)))
    local need = Trade.needTrust(fid, category, tier)
    if not need then return { category = category, tier = tier, never = true } end
    if trust >= need then return nil end
    return { category = category, tier = tier, need = need }
end

-- 흥정해도 내려가지 않는 가격
function Trade.haggleFloor(fid, trust, base)
    local rules = Trade.FACTIONS[fid] or {}
    local f = Trade.HAGGLE[#Trade.HAGGLE].floor
    for _, row in ipairs(Trade.HAGGLE) do
        if trust >= row.min then
            f = row.floor
            break
        end
    end
    f = math.max(0.5, math.min(1, f + (rules.haggle or 0)))
    return math.max(1, math.ceil(base * f))
end

-- 답을 기다리는 거래 제안에 대해 흥정할 때 AI 에 넘기는 조건
-- 흥정 중에도 물건을 바꿔 줄 수 있으므로(Trade.negotiate 의 교체), 지금 줄 수 있는 품목·등급(goods)을 함께 넘긴다.
local function haggleContext(fid, q, trust, offer)
    local rules = Trade.FACTIONS[fid]
    local base = q.basePrice or q.price
    local haggles = q.haggles or 0
    return {
        allowed = false, reason = "negotiating", negotiating = true, trust = trust,
        deal = { category = q.category, tier = q.tier, price = q.price, basePrice = base, payCategory = q.payCategory },
        floor = Trade.haggleFloor(fid, trust, base),
        haggles = haggles, haggleLeft = math.max(0, Trade.MAX_HAGGLES - haggles),
        wants = rules.wants,
        goods = offer and offer.allowed and offer.goods or nil,
        catalog = offer and offer.catalog or nil,
    }
end

-- 이 세력이 지금 이 플레이어와 할 수 있는 거래. AI 에 넘기고, 제안 검증에도 쓴다.
function Trade.context(fid, ps)
    local rules = Trade.FACTIONS[fid]
    if not rules or Factions.isGone(fid) then return { allowed = false, reason = "no_trader" } end
    local trust = Radio.channel(fid).trust
    -- 거래는 모두가 함께 보는 퀘스트라 세력당 하나씩. 답을 기다리는 제안이면 누구든 흥정할 수 있다.
    local open = Quests.openTrade(fid)
    if open and open.state == "proposed" then return haggleContext(fid, open, trust, Trade.offerContext(fid, trust)) end
    if open or (ps and Quests.openFor(ps.key, "trade")) then
        return { allowed = false, reason = "open_deal", trust = trust }
    end
    return Trade.offerContext(fid, trust)
end

-- 신뢰도·생활 자원으로 정해지는 지금 줄 수 있는 물건과 값 (열린 거래와 상관없이). 새 제안과 흥정 중 물건 교체가 함께 쓴다.
function Trade.offerContext(fid, trust)
    local rules = Trade.FACTIONS[fid]
    if not rules then return { allowed = false, reason = "no_trader" } end
    local limit = limitFor(trust)
    if limit.maxTier == 0 then return { allowed = false, reason = "low_trust", trust = trust, need = minTradeTrust() } end

    -- goods: 지금 줄 수 있는 것 (검증용). catalog: 취급하는 모든 품목과 등급별 필요 신뢰도 (AI 가 한도를 말하도록)
    -- 생활 자원(Life.lua): 그 품목의 자원이 바닥(20 미만)이면 팔지 않고, 부족(40 미만)하면 x1.3, 넉넉(70 이상)하면 x0.85
    local Life = StoryEngine.Life
    local goods, catalog, catMult = {}, {}, {}
    for _, cat in ipairs(Value.CATEGORIES) do
        local cap = rules.goods[cat] or 0
        local best = math.min(cap, limit.maxTier + (rules.stretch or 0))
        if rules.gunTrust and isGunCat(cat) and trust < rules.gunTrust then best = 0 end
        local level = Life and Life.get(fid, Value.RESOURCE_OF[cat] or "safety") or 50
        local empty = Life ~= nil and cap > 0 and level < Life.SELF_MIN
        if empty then best = 0 end
        catMult[cat] = Life and ((level < Life.LOW and 1.3) or (level >= Life.PLENTY and 0.85)) or 1
        if best > 0 then goods[#goods + 1] = { category = cat, maxTier = best } end
        if cap > 0 then
            local needs = {}
            for t = 1, cap do needs[t] = Trade.needTrust(fid, cat, t) or 101 end
            catalog[#catalog + 1] = { category = cat, maxTier = best, needs = needs, empty = empty or nil,
                                      short = (Life ~= nil and not empty and level < Life.LOW) or nil }
        end
    end
    if #goods == 0 then return { allowed = false, reason = "nothing", trust = trust } end
    local recent = Trade.recentRequests(fid)
    local suspicious = recent + 1 >= Trade.SUSPICIOUS_COUNT
    -- 빅 교역소(장기 프로젝트)가 완성되면 한도보다 높은 등급도 웃돈 없이 판다
    local tradingPost = fid == "rats" and StoryEngine.Projects and StoryEngine.Projects.done("rats")
    return {
        recentRequests = recent, suspicious = suspicious,
        freeMaxTier = (trust >= Trade.FREE_TRUST and not suspicious and ZombRand(100) < Trade.FREE_CHANCE)
            and Trade.FREE_MAX_TIER or 0,
        allowed = true, trust = trust, maxTier = limit.maxTier,
        mult = limit.mult * (rules.priceMult or 1) * (StoryEngine.Tuning and StoryEngine.Tuning.num("PriceMult") or 1),
        stretchMult = (not tradingPost) and rules.stretchMult or nil, goods = goods, catalog = catalog, wants = rules.wants, catMult = catMult,
    }
end

-- 등급별 가격 배율 (패거리의 한도 초과 등급은 더 비싸다)
local function priceMult(ctx, tier)
    local mult = ctx.mult or 1
    if tier > ctx.maxTier and ctx.stretchMult then mult = mult * ctx.stretchMult end
    return mult
end

-- 다른 모드 아이템도 섞는다 (Loot 와 같은 비율): 총은 같은 등급의 풀 총 묶음, 탄약은 그 등급 총에 맞는 탄약,
-- 음식·근접 무기는 한 개씩 비슷한 등급으로.
Trade.AMMO_BOXES = { 0, 1, 2, 3, 5 }     -- 탄약 거래 등급별 상자 수 (1등급은 낱발 24)

function Trade.roll(category, tier, fid)
    local special = fid and Trade.FACTION_GOODS[fid] and Trade.FACTION_GOODS[fid][category]
    local pool = (special and special[tier]) or (Trade.GOODS[category] and Trade.GOODS[category][tier])
    if not pool then return nil end
    local bundle = pool[ZombRand(#pool) + 1]
    local out = {}
    if category == "firearm" and not special then
        StoryEngine.Loot.addGun(out, bundle, tier)
        return out
    end
    if category == "ammo" and not special and StoryEngine.ItemPool.roll() then
        local boxes = Trade.AMMO_BOXES[tier] or 1
        local modded = StoryEngine.ItemPool.ammoBundle(tier, boxes, boxes == 0 and 24 or nil)
        if modded then bundle = modded end
    end
    for _, entry in ipairs(bundle) do
        if not special and (category == "food" or category == "melee") then
            StoryEngine.Loot.addMixed(out, entry[1], entry[2])
        else
            for _ = 1, entry[2] do out[#out + 1] = entry[1] end
        end
    end
    return out
end

-- AI 답장의 trade 필드로 거래 제안(offer) 또는 무상 제공(gift)을 만든다. 반환: 퀘스트, "offer" | "gift" / 없으면 nil
function Trade.fromReply(fid, ps, trade)
    if type(trade) ~= "table" or not ps then return nil end
    if trade.action ~= "offer" and trade.action ~= "gift" then return nil end
    local ctx = Trade.context(fid, ps)
    if not ctx.allowed then
        log("trade offer ignored:", fid, ctx.reason)
        if ctx.reason == "low_trust" then return nil, "blocked", Trade.blocked(fid, trade.category, trade.tier) end
        return nil
    end
    local maxForCat = nil
    for _, g in ipairs(ctx.goods) do
        if g.category == trade.category then maxForCat = g.maxTier end
    end
    local tier = math.max(1, math.min(5, math.floor(tonumber(trade.tier) or 1)))
    if trade.action == "gift" and maxForCat then tier = math.min(tier, maxForCat) end
    -- 한도를 넘는 제안은 낮춰서 만들지 않는다. 무엇이 막혔는지 플레이어에게 알린다.
    if not maxForCat or tier > maxForCat then
        log("trade offer blocked:", fid, tostring(trade.category), tier, "max", tostring(maxForCat))
        return nil, "blocked", Trade.blocked(fid, trade.category, tier)
    end
    local payCategory = ctx.wants[1]
    for _, w in ipairs(ctx.wants) do
        if w == trade.pay_category then payCategory = w end
    end

    if trade.action == "gift" then
        -- 무상 제공은 신뢰도가 높을 때 낮은 등급만. 조건이 안 되면 무시한다 (AI 가 규칙을 어긴 경우)
        if (ctx.freeMaxTier or 0) <= 0 then
            log("trade gift ignored: not allowed", fid)
            return nil
        end
        tier = math.min(tier, ctx.freeMaxTier)
        local gifts = Trade.roll(trade.category, tier, fid)
        if not gifts then return nil end
        local q = Quests.giftTrade(ps, fid, tier, gifts, Sensor.now())
        return q, "gift"
    end
    local goods = Trade.roll(trade.category, tier, fid)
    if not goods then return nil end
    local price = math.ceil(Value.sum(goods) * priceMult(ctx, tier) * ((ctx.catMult or {})[trade.category] or 1))
    return Quests.proposeTrade(ps, fid, {
        tier = tier, category = trade.category, goods = goods, payCategory = payCategory, price = price,
    }, Sensor.now()), "offer"
end

-- 대가 제출. itemIds 는 클라이언트가 고른 아이템 ID 목록. 성공하면 true, 배송 퀘스트 / 실패하면 false, 오류 코드
-- 흥정 결과를 반영한다. trade = AI 의 { action = "counter" | "withdraw" | "none", category, tier, price, pay_category }
-- counter 에 지금 거래와 다른 category·tier 가 있으면 물건을 바꾼다(교체): 새 물건을 굴리고 값을 다시 매긴다.
-- 돌려주는 값: q, "counter" | "swap" | "withdraw" / 바뀐 것이 없으면 nil, 이유("same" | "no_rounds" | "blocked" | "no_deal"), 막힘 정보
function Trade.negotiate(fid, ps, trade)
    local q = Quests.openTrade(fid)
    if not q or q.state ~= "proposed" or not ps then return nil, "no_deal" end
    if type(trade) ~= "table" then return nil, "same" end
    local now = Sensor.now()
    if trade.action == "withdraw" then
        Quests.withdrawTrade(q, now)
        return q, "withdraw"
    end
    if trade.action ~= "counter" then return nil, "same" end
    if (q.haggles or 0) >= Trade.MAX_HAGGLES then
        log("trade haggle ignored: no rounds left", q.id)
        return nil, "no_rounds"
    end
    local trust = Radio.channel(fid).trust
    local rules = Trade.FACTIONS[fid] or {}
    local pay = q.payCategory
    for _, w in ipairs(rules.wants or {}) do
        if w == trade.pay_category then pay = w end
    end

    local category = trade.category
    local tier = math.floor(tonumber(trade.tier) or 0)
    local swap = type(category) == "string" and category ~= "" and category ~= "none"
        and (category ~= q.category or (tier > 0 and tier ~= q.tier))
    if swap then
        if tier <= 0 then tier = q.tier end
        tier = math.max(1, math.min(5, tier))
        local ctx = Trade.offerContext(fid, trust)
        local maxForCat = nil
        for _, g in ipairs(ctx.allowed and ctx.goods or {}) do
            if g.category == category then maxForCat = g.maxTier end
        end
        if not maxForCat or tier > maxForCat then
            log("trade swap blocked:", q.id, tostring(category), tier, "max", tostring(maxForCat))
            return nil, "blocked", Trade.blocked(fid, category, tier)
        end
        local goods = Trade.roll(category, tier, fid)
        if not goods then return nil, "same" end
        local price = math.ceil(Value.sum(goods) * priceMult(ctx, tier) * ((ctx.catMult or {})[category] or 1))
        Quests.swapTrade(q, category, tier, goods, math.max(1, price), pay, now)
        return q, "swap"
    end

    local base = q.basePrice or q.price
    local floor = Trade.haggleFloor(fid, trust, base)
    local price = math.floor(tonumber(trade.price) or 0)
    if price <= 0 then price = q.price end
    price = math.max(floor, math.min(base, price))
    if price == q.price and pay == q.payCategory then return nil, "same" end
    Quests.reviseTrade(q, price, pay, now)
    return q, "counter"
end

-- ---------------------------------------------------------------- 공용 주파수 거래 (여러 NPC 의 제안 중 고르기)
-- 플레이어가 공용 주파수에서 물건을 청하면 지금 거래할 수 있는 NPC 들(sellers)을 AI 에 넘기고, AI 가 고른 최대
-- MARKET_MAX 명의 제안을 게임이 1:1 거래와 같은 규칙(신뢰도 한도, 생활 자원, 가격)으로 다시 만든다.
-- 플레이어는 퀘스트 탭에서 하나를 고르고(Quests.pickMarket), 고른 NPC 와의 거래가 바로 수락된 상태로 생긴다.
Trade.MARKET_MAX = 3

-- 판매 시장 (2026-10-02): 플레이어가 가진 물건을 내놓으면, 그 품목을 대가로 받는 NPC 들이 자기 물건을 제안한다.
-- 그 품목의 생활 자원이 모자란 NPC 일수록 후하게 쳐 준다 (가격 / SELL_BONUS). 플레이어가 낼 수 있는 양을 넘는 제안은
-- 등급을 낮추고, 1등급도 못 내면 버린다.
Trade.SELL_BONUS = { { below = 20, mult = 1.5 }, { below = 40, mult = 1.3 } }

local function sellBonus(fid, category)
    local Life = StoryEngine.Life
    if not Life then return 1 end
    local level = Life.get(fid, Value.RESOURCE_OF[category] or "safety")
    for _, row in ipairs(Trade.SELL_BONUS) do
        if level < row.below then return row.mult end
    end
    return 1
end

-- 플레이어가 대가로 낼 수 있는 물건의 품목별 가치 합 (채집·벌목 재료와 퀘스트 물건은 빠진다, Value.payable)
function Trade.stockOf(player)
    local out = {}
    if not player then return out end
    for _, cat in ipairs(Value.CATEGORIES) do
        local total = 0
        for _, item in ipairs(Value.payableItems(player, cat)) do total = total + Value.of(item:getFullType()) end
        if total >= 1 then out[cat] = math.floor(total) end
    end
    return out
end

-- 지금 공용 주파수에서 제안할 수 있는 NPC 들. 플레이어에게 진행 중인 거래가 있으면 시장은 닫힌다.
-- player 가 있으면 가진 물건(stock)과 NPC 마다 모자란 품목(short)도 넘겨 판매 제안에 쓴다.
function Trade.marketContext(ps, player)
    if ps and Quests.openFor(ps.key, "trade") then return { closed = "open_deal" } end
    local sellers = {}
    for _, f in ipairs(Factions.list) do
        if Trade.FACTIONS[f.id] and not Factions.isGone(f.id) and not Quests.openTrade(f.id) then
            local trust = Radio.channel(f.id).trust
            local ctx = Trade.offerContext(f.id, trust)
            if ctx.allowed then
                local short = {}
                for _, w in ipairs(ctx.wants or {}) do
                    if sellBonus(f.id, w) > 1 then short[#short + 1] = w end
                end
                sellers[#sellers + 1] = { id = f.id, trust = trust, goods = ctx.goods, wants = ctx.wants,
                                          short = #short > 0 and short or nil }
            end
        end
    end
    if #sellers == 0 then return { closed = "no_sellers" } end
    return { sellers = sellers, max = Trade.MARKET_MAX, stock = player and Trade.stockOf(player) or nil }
end

-- AI 의 offers = { { faction, category, tier, pay_category } } 를 검증해 실제 거래 조건으로 만든다.
-- 한도를 넘거나 같은 NPC 가 두 번 낸 제안은 버린다. 제안한 NPC 마다 요청 횟수를 센다(너무 잦으면 의심).
-- selling = 플레이어가 내놓은 품목 (판매): 대가는 그 품목으로 고정, 그것을 받는 NPC 만, 모자란 NPC 는 후하게,
-- 플레이어가 가진 가치(player 의 stock) 안에서만. 판매는 요청 횟수를 세지 않는다.
function Trade.marketOffers(ps, offers, selling, player)
    local out, seen = {}, {}
    if not ps or type(offers) ~= "table" or Quests.openFor(ps.key, "trade") then return out end
    local sellCat = nil
    for _, c in ipairs(Value.CATEGORIES) do
        if c == selling then sellCat = c end
    end
    local have = sellCat and (Trade.stockOf(player)[sellCat] or 0) or nil
    if sellCat and have < 1 then
        log("market sell dropped: nothing to sell in", sellCat)
        return out
    end
    for _, o in ipairs(offers) do
        local fid = type(o) == "table" and o.faction or nil
        if #out < Trade.MARKET_MAX and type(fid) == "string" and Trade.FACTIONS[fid] and not seen[fid]
            and not Factions.isGone(fid) and not Quests.openTrade(fid) then
            local ctx = Trade.offerContext(fid, Radio.channel(fid).trust)
            local maxForCat = nil
            for _, g in ipairs(ctx.allowed and ctx.goods or {}) do
                if g.category == o.category then maxForCat = g.maxTier end
            end
            local tier = math.max(1, math.min(5, math.floor(tonumber(o.tier) or 1)))
            local accepts = not sellCat
            for _, w in ipairs(ctx.wants or {}) do
                if w == sellCat then accepts = true end
            end
            if not maxForCat then
                log("market offer dropped:", fid, tostring(o.category), "not offered")
            elseif not accepts then
                log("market offer dropped:", fid, "does not take", tostring(sellCat))
            else
                tier = math.min(tier, maxForCat)
                local pay = ctx.wants[1]
                for _, w in ipairs(ctx.wants) do
                    if w == o.pay_category then pay = w end
                end
                if sellCat then pay = sellCat end
                local bonus = sellCat and sellBonus(fid, sellCat) or 1
                local goods, price
                -- 판매: 플레이어가 가진 만큼만. 넘으면 등급을 하나씩 낮춰 다시 굴린다
                local lastPrice = nil
                while tier >= 1 do
                    goods = Trade.roll(o.category, tier, fid)
                    price = goods and math.max(1, math.ceil(Value.sum(goods) * priceMult(ctx, tier)
                        * ((ctx.catMult or {})[o.category] or 1) / bonus)) or nil
                    lastPrice = price or lastPrice
                    if not sellCat or (price and price <= have) then break end
                    tier = tier - 1
                    goods = nil
                end
                if goods and #goods > 0 then
                    seen[fid] = true
                    out[#out + 1] = { faction = fid, category = o.category, tier = tier, goods = goods,
                                      payCategory = pay, price = price, selling = sellCat and true or nil,
                                      bonus = bonus > 1 and bonus or nil }
                    if not sellCat then
                        local okR, errR = pcall(Trade.recordRequest, fid, ps)
                        if not okR then log("trade request count error:", errR) end
                    end
                elseif sellCat then
                    log("market sell offer dropped:", fid, "player has", have, sellCat, "cheapest", tostring(lastPrice))
                end
            end
        end
    end
    return out
end

function Trade.pay(player, qid, itemIds)
    local q = Store.data().quests[qid]
    if not q or q.kind ~= "trade" then return false, "no_quest" end
    if q.state ~= "accepted" then return false, "not_active" end
    if not Factions.canTalk(player) then return false, "no_radio" end
    local inv = player:getInventory()
    local chosen, seen, total = {}, {}, 0
    for _, id in ipairs(itemIds or {}) do
        local n = math.floor(tonumber(id) or -1)
        if not seen[n] then
            seen[n] = true
            local item = inv:getItemWithIDRecursiv(n)
            if item and Value.payable(player, item, q.payCategory) then
                chosen[#chosen + 1] = item
                total = total + Value.of(item:getFullType())
            end
        end
    end
    if total < q.price then return false, "not_enough" end
    for _, item in ipairs(chosen) do StoryEngine.Items.remove(item, player) end
    log("trade paid", qid, total, "/", q.price)
    return Quests.completeTrade(player, q)
end

return Trade
