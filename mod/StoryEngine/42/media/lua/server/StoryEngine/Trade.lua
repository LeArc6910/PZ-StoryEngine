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
        wants = Value.wantsOf(fid),
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
        stretchMult = (not tradingPost) and rules.stretchMult or nil, goods = goods, catalog = catalog, wants = Value.wantsOf(fid), catMult = catMult,
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

-- 이 NPC 의 이 품목·등급 묶음 후보 (전문 품목이 있으면 그것)
function Trade.poolFor(category, tier, fid)
    local special = fid and Trade.FACTION_GOODS[fid] and Trade.FACTION_GOODS[fid][category]
    return (special and special[tier]) or (Trade.GOODS[category] and Trade.GOODS[category][tier]), special ~= nil
end

-- ---------------------------------------------------------------- 실시간 묶음 (2026-10-04 사용자 결정)
-- 묶음 = 그 등급 물건 1개(없으면 아래로 가장 높은 등급) + 남은 예산을 거래 등급 이하 물건으로 무작위로 채움.
-- 가치는 Value (등급을 따름). 모드 물건은 샌드박스 '모드 아이템 비율' 확률로 (ItemPool.pickMixed).
-- 총은 그 총 + 탄창 하나 + 남은 예산만큼 그 총의 탄약. 고정 표(Trade.GOODS·FACTION_GOODS)는 풀이 비었을 때만 쓴다.
Trade.BUDGET = {
    food = { 5, 10, 15, 25, 35 }, medical = { 6, 12, 20, 35, 60 }, tools = { 4, 8, 14, 24, 36 },
    melee = { 5, 8, 10, 16, 24 }, ammo = { 10, 20, 30, 50, 90 }, firearm = { 45, 60, 75, 100, 140 },
}
-- 전문가는 예산 x1.3: 닥 의약품, 행크 총·근접·음식, 케이시 전자기기, 듀이 차량 부품
Trade.SPECIALIST = { doc = { medical = 1.3 }, hunter = { firearm = 1.3, melee = 1.3, food = 1.3 },
                     casey = { tools = 1.3 }, dewey = { tools = 1.3 } }
-- 이 NPC 의 이 품목을 채우는 물건 풀 (ItemPool.tradePool 이름). 없으면 품목 이름 그대로
Trade.POOL_OF = { casey = { tools = "electronics" }, dewey = { tools = "vehicle" } }
Trade.FILL_MAX = 15          -- 고정 물건 말고 채우는 물건 최대 개수
Trade.FILL_KINDS = 5         -- 한 묶음의 물건 가짓수 (고정 물건 포함). 다 차면 넣은 물건을 더 넣는다

local fillCache = {}
-- 풀 name 의 1~tier 등급 물건을 가치 순으로 (바닐라·모드 따로). { van = { {ft, v} }, mod = { {ft, v} } }
local function fillList(name, tier)
    local key = name .. ":" .. tier
    if fillCache[key] then return fillCache[key] end
    local IP = StoryEngine.ItemPool
    local byTier = IP.tradePool(name) or {}
    local out = { van = {}, mod = {} }
    for t = 1, tier do
        for _, ft in ipairs(byTier[t] or {}) do
            local v = Value.of(ft)
            if v and v > 0 then
                local side = IP.isVanilla(ft) and out.van or out.mod
                side[#side + 1] = { ft, v }
            end
        end
    end
    for _, side in pairs(out) do table.sort(side, function(a, b) return a[2] < b[2] end) end
    fillCache[key] = out
    return out
end

-- 남은 예산 left 안의 물건 하나 (없으면 nil)
local function pickFill(lists, left)
    local function under(side)
        local n = 0
        for i, e in ipairs(side) do
            if e[2] > left then break end
            n = i
        end
        return n
    end
    local nv, nm = under(lists.van), under(lists.mod)
    if nv == 0 and nm == 0 then return nil end
    local side, n = lists.van, nv
    if nv == 0 or (nm > 0 and StoryEngine.ItemPool.roll()) then side, n = lists.mod, nm end
    return side[ZombRand(n) + 1]
end

-- 시험·디버그: 채움 목록을 다시 만들게 한다
function Trade.resetFill()
    fillCache = {}
end

-- 묶음 하나를 실시간으로 만든다. 반환: 물건 fullType 목록 | nil (풀이 비었음)
-- budget 을 주면 그 예산으로 (퀘스트 보상 Loot 가 쓴다), 아니면 거래 예산 x 전문가 배율
-- anchor 를 주면 그 물건을 첫 물건으로 (플레이어가 청한 물건, Trade.findItem)
function Trade.generate(category, tier, fid, budget, anchor)
    local IP = StoryEngine.ItemPool
    local name = (Trade.POOL_OF[fid] or {})[category] or category
    local byTier = IP.tradePool(name)
    if not byTier then return nil end
    budget = budget or ((Trade.BUDGET[category] or Trade.BUDGET.tools)[tier] or 10)
        * (((Trade.SPECIALIST[fid] or {})[category]) or 1)
    if not anchor then
        local top = nil
        for t = tier, 1, -1 do
            if byTier[t] and #byTier[t] > 0 then
                top = t
                break
            end
        end
        if not top then return nil end
        -- 첫 물건도 예산 안의 것으로 (붕대 상자처럼 비싼 묶음이 1등급 보상을 넘지 않게). 없으면 그 등급에서 가장 싼 것
        local fits, cheapest, cheapV = {}, nil, nil
        for _, ft in ipairs(byTier[top]) do
            local v = Value.of(ft) or 0
            if v <= budget then fits[#fits + 1] = ft end
            if not cheapV or v < cheapV then cheapest, cheapV = ft, v end
        end
        anchor = #fits > 0 and IP.pickMixed(fits) or cheapest
    end
    if not anchor then return nil end
    local out, total = { anchor }, Value.of(anchor)
    if category == "firearm" then
        local g = IP.guns[anchor]
        if g and g.mag then
            out[#out + 1] = g.mag
            total = total + Value.of(g.mag)
        end
        local ammo = g and (g.box or g.round)
        if ammo then
            local v, n = Value.of(ammo), 0
            repeat
                out[#out + 1] = ammo
                total, n = total + v, n + 1
            until v <= 0 or total + v > budget or n >= Trade.FILL_MAX
        end
        return out
    end
    local lists = fillList(name, tier)
    local kinds, seen = { { anchor, Value.of(anchor) } }, { [anchor] = true }
    for _ = 1, Trade.FILL_MAX do
        local left = budget - total
        local e = nil
        if #kinds >= Trade.FILL_KINDS then
            -- 가짓수가 찼으면 이미 넣은 물건을 더 (통조림 15종보다 3~5종 여러 개가 묶음답다)
            local fit = {}
            for _, k in ipairs(kinds) do
                if k[2] > 0 and k[2] <= left then fit[#fit + 1] = k end
            end
            if #fit > 0 then e = fit[ZombRand(#fit) + 1] end
        else
            e = pickFill(lists, left)
        end
        if not e then break end
        out[#out + 1] = e[1]
        total = total + e[2]
        if not seen[e[1]] then
            seen[e[1]] = true
            kinds[#kinds + 1] = e
        end
    end
    return out
end

-- ---------------------------------------------------------------- 청한 물건 (2026-10-04)
-- 플레이어가 특정 물건을 청하면 AI 가 영어 이름(item)과 플레이어가 쓴 말(item_said)을 준다. 이 NPC 가 취급하는 품목의
-- 물건 풀에서 아이템 이름(모듈 뺀 것)과 서버 언어의 표시 이름으로 찾고, 찾으면 그 물건을 묶음의 첫 물건으로 넣는다.
-- 못 찾으면 제안하지 않고 "그 물건은 없다" 줄을 남긴다 (AI 가 약속한 물건과 실제 묶음이 어긋나지 않게).
local function normName(s)
    s = string.lower(tostring(s or ""))
    return (string.gsub(s, "[%s%p]", ""))
end

local nameKeys = {}
local function keysOf(ft)
    local hit = nameKeys[ft]
    if hit then return hit end
    local keys = { normName(string.match(ft, "%.(.+)$") or ft) }
    local ok, shown = pcall(getItemNameFromFullType, ft)
    if ok and shown then keys[#keys + 1] = normName(shown) end
    nameKeys[ft] = keys
    return keys
end

-- 3 같음, 2 앞부분이 같음, 1 들어 있음, 0 아님 (3바이트보다 짧은 말은 맞추지 않는다)
local function nameScore(ft, want)
    if not want or string.len(want) < 3 then return 0 end
    local best = 0
    for _, k in ipairs(keysOf(ft)) do
        if string.len(k) >= 3 then
            if k == want then return 3 end
            if string.find(k, want, 1, true) == 1 or string.find(want, k, 1, true) == 1 then
                best = math.max(best, 2)
            elseif string.find(k, want, 1, true) or string.find(want, k, 1, true) then
                best = math.max(best, 1)
            end
        end
    end
    return best
end

-- 반환: { ft, category, tier(그 물건의 등급), maxTier(지금 줄 수 있는 최고 등급, 0 이면 못 줌) } | nil
-- goods = offerContext 의 goods (지금 줄 수 있는 품목과 최고 등급), prefer = AI 가 말한 품목
function Trade.findItem(fid, goods, prefer, item, said)
    local wants = { normName(item), normName(said) }
    if wants[1] == "" and wants[2] == "" then return nil end
    local rules = Trade.FACTIONS[fid] or { goods = {} }
    local maxOf = {}
    for _, g in ipairs(goods or {}) do maxOf[g.category] = g.maxTier end
    local IP = StoryEngine.ItemPool
    local best, bestKey = nil, nil
    for cat in pairs(rules.goods or {}) do
        local byTier = IP.tradePool((Trade.POOL_OF[fid] or {})[cat] or cat) or {}
        for t = 1, 5 do
            for _, ft in ipairs(byTier[t] or {}) do
                local s = math.max(nameScore(ft, wants[1]), nameScore(ft, wants[2]))
                if s > 0 then
                    -- 점수 > AI 가 말한 품목 > 낮은 등급 > 짧은 이름
                    local key = s * 1000 + (cat == prefer and 100 or 0) + (10 - t) * 5 - math.min(20, string.len(ft) / 4)
                    if not bestKey or key > bestKey then
                        best, bestKey = { ft = ft, category = cat, tier = t, maxTier = maxOf[cat] or 0 }, key
                    end
                end
            end
        end
    end
    return best
end

local function notCarried(trade)
    local said = type(trade.item_said) == "string" and trade.item_said ~= "" and trade.item_said or trade.item
    return { notCarried = true, item = tostring(said or ""), category = trade.category }
end

local function wantsItem(t)
    return type(t) == "table" and ((type(t.item) == "string" and t.item ~= "")
        or (type(t.item_said) == "string" and t.item_said ~= ""))
end

-- 묶음 하나를 새로 만든다 (실시간 생성, 풀이 비었으면 예전 고정 표). 재고를 채울 때와 일로 갚은 덤에 쓴다
function Trade.rollFresh(category, tier, fid)
    local ok, made = pcall(Trade.generate, category, tier, fid)
    if ok and made and #made > 0 then return made end
    if not ok then log("trade generate failed:", fid, category, tier, tostring(made)) end
    local pool, special = Trade.poolFor(category, tier, fid)
    if not pool then return nil end
    local out = {}
    local bundle = pool[ZombRand(#pool) + 1]
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

-- ---------------------------------------------------------------- 재고 (2026-10-04)
-- NPC 마다 품목·등급별로 묶음 Trade.STOCK_BUNDLES 개를 실시간으로 만들어 두고 Trade.STOCK_DAYS 일마다 새로 만든다.
-- 거래가 끝난 묶음은 다음 입고까지 품절. (JITTER: 고정 표를 쓸 때 소모품 개수를 -1~+1, 지금은 끔)
-- 거래 목록 창, 무작위 요청, AI 무전 거래, 흥정 중 교체, 공용 주파수 거래가 모두 이 재고에서 꺼낸다.
-- 세력당 열린 거래는 하나라서(Quests.openTrade) 같은 묶음이 두 번 나가지 않는다. 상태 Radio.channel(fid).stock
Trade.STOCK_DAYS = 3
Trade.STOCK_BUNDLES = 3
Trade.JITTER = {}

local function group(list)
    local out, at = {}, {}
    for _, ft in ipairs(list or {}) do
        if at[ft] then
            out[at[ft]][2] = out[at[ft]][2] + 1
        else
            out[#out + 1] = { ft, 1 }
            at[ft] = #out
        end
    end
    return out
end
Trade.group = group

local function expand(grouped)
    local out = {}
    for _, e in ipairs(grouped) do
        for _ = 1, e[2] do out[#out + 1] = e[1] end
    end
    return out
end

local function sameGoods(a, b)
    if #a ~= #b then return false end
    local ca = {}
    for _, ft in ipairs(a) do ca[ft] = (ca[ft] or 0) + 1 end
    for _, ft in ipairs(b) do
        ca[ft] = (ca[ft] or 0) - 1
        if ca[ft] < 0 then return false end
    end
    return true
end

-- 소모품은 2개 이상인 것만 -1~+1
local function jitter(category, goods)
    if not Trade.JITTER[category] then return goods end
    local g = group(goods)
    for _, e in ipairs(g) do
        if e[2] >= 2 then e[2] = math.max(1, e[2] + ZombRand(-1, 2)) end
    end
    return expand(g)
end

-- 빅 교역소(장기 프로젝트 완성, 2026-10-05): 묶음 5개, 2일마다 입고, 일주일마다 암시장 물건 하나
Trade.POST_BUNDLES = 5
Trade.POST_DAYS = 2
Trade.BLACK_DAYS = 7
Trade.BLACK_CATS = { "firearm", "tools" }
Trade.BLACK_MULT = 1.25           -- 암시장 값: 물건 가치 x 이 배율 x 샌드박스 가격 배율 (신뢰도 구간 배율 없음)

local function tradingPost(fid)
    return fid == "rats" and StoryEngine.Projects ~= nil and StoryEngine.Projects.done("rats")
end
Trade.tradingPost = tradingPost
Value.anyWantsFn = tradingPost      -- 교역소: 어떤 품목이든 대가로 받는다

local function stockBundles(fid) return tradingPost(fid) and Trade.POST_BUNDLES or Trade.STOCK_BUNDLES end
local STOCK_MIN = function(fid) return (tradingPost(fid) and Trade.POST_DAYS or Trade.STOCK_DAYS) * 24 * 60 end

-- 지금 재고 (없거나 입고일이 지났으면 새로 채운다)
function Trade.stock(fid)
    local rules = Trade.FACTIONS[fid]
    if not rules then return nil end
    local ch = Radio.channel(fid)
    local now = Sensor.now().t
    local st = ch.stock
    if not st or not st.t or now >= st.t + STOCK_MIN(fid) then
        st = { t = now, seq = (st and st.seq or 0) + 1, cats = {} }
        for cat, cap in pairs(rules.goods) do
            st.cats[cat] = {}
            for t = 1, cap do
                local list, tries = {}, 0
                while #list < stockBundles(fid) and tries < stockBundles(fid) * 4 do
                    tries = tries + 1
                    local goods = Trade.rollFresh(cat, t, fid)
                    if goods and #goods > 0 then
                        goods = jitter(cat, goods)
                        local dup = false
                        for _, b in ipairs(list) do
                            if sameGoods(b.goods, goods) then dup = true end
                        end
                        if not dup then list[#list + 1] = { goods = goods } end
                    end
                end
                st.cats[cat][t] = list
            end
        end
        ch.stock = st
        log("trade restock", fid, "seq", st.seq)
    end
    return st
end

-- 다음 입고까지 남은 날
function Trade.restockIn(fid)
    local st = Trade.stock(fid)
    return st and math.max(1, math.ceil((st.t + STOCK_MIN(fid) - Sensor.now().t) / (24 * 60))) or 0
end

-- 재고에서 묶음을 꺼낸다 (아직 팔린 것으로 치지 않음, 거래가 끝나면 Trade.markSold).
-- index 가 있으면 그 묶음, 없으면 남은 것 중 무작위. 반환: 물건 목록, 표시 { seq, category, tier, index } | nil, "sold_out"
function Trade.roll(category, tier, fid, index)
    local st = fid and Trade.stock(fid)
    local list = st and st.cats[category] and st.cats[category][tier]
    if not list then
        local fresh = Trade.rollFresh(category, tier, fid)
        return fresh, nil
    end
    local pick = nil
    if index then
        local b = list[index]
        if b and not b.sold then pick = index end
    else
        local open = {}
        for i, b in ipairs(list) do
            if not b.sold then open[#open + 1] = i end
        end
        if #open > 0 then pick = open[ZombRand(#open) + 1] end
    end
    if not pick then return nil, "sold_out" end
    local out = {}
    for _, ft in ipairs(list[pick].goods) do out[#out + 1] = ft end
    return out, { seq = st.seq, category = category, tier = tier, index = pick }
end

-- 암시장 물건 (빅 교역소): 일주일마다 5등급 총 또는 도구 묶음 하나. 신뢰도와 상관없이 살 수 있다. 상태 Radio.channel(fid).black
function Trade.black(fid)
    if not tradingPost(fid) then return nil end
    local ch = Radio.channel(fid)
    local now = Sensor.now().t
    local b = ch.black
    if not b or not b.t or now >= b.t + Trade.BLACK_DAYS * 24 * 60 then
        local cat = Trade.BLACK_CATS[ZombRand(#Trade.BLACK_CATS) + 1]
        local goods = Trade.rollFresh(cat, 5, fid)
        if not goods or #goods == 0 then return nil end
        b = { t = now, seq = (b and b.seq or 0) + 1, category = cat, tier = 5, goods = goods }
        ch.black = b
        log("trade black market", fid, cat, #goods, "items")
    end
    return b
end

function Trade.blackPrice(fid, b)
    local tune = StoryEngine.Tuning and StoryEngine.Tuning.num("PriceMult") or 1
    return math.ceil(Value.sum(b.goods) * Trade.BLACK_MULT * tune)
end

-- 거래 목록 창에 보여 줄 암시장 줄
function Trade.blackInfo(fid)
    local b = Trade.black(fid)
    if not b then return nil end
    return { category = b.category, tier = b.tier, items = group(b.goods), price = Trade.blackPrice(fid, b),
             sold = b.sold or nil, daysLeft = math.max(1, math.ceil((b.t + Trade.BLACK_DAYS * 24 * 60 - Sensor.now().t) / (24 * 60))) }
end

-- 거래가 끝났다: 그 묶음은 다음 입고까지 품절 (입고가 지나 재고가 바뀌었으면 아무 일 없음)
function Trade.markSold(fid, ref)
    if type(ref) ~= "table" then return end
    if ref.black then
        local b = Radio.channel(fid).black
        if b and b.seq == ref.black then
            b.sold = true
            log("trade black market sold", fid)
        end
        return
    end
    local st = Radio.channel(fid).stock
    if not st or st.seq ~= ref.seq then return end
    local b = st.cats[ref.category] and st.cats[ref.category][ref.tier] and st.cats[ref.category][ref.tier][ref.index]
    if b then
        b.sold = true
        log("trade stock sold", fid, ref.category, ref.tier, ref.index)
    end
end

-- 거래가 끝나면(대가를 냈거나 일로 갚았거나 빚으로 받음) 그 묶음은 품절
Quests.hooks[#Quests.hooks + 1] = function(q, state)
    if q.kind == "trade" and state == "completed" and q.stockRef and q.origin then
        Trade.markSold(q.origin.faction, q.stockRef)
    end
end

local function soldOut(fid, category, tier)
    return { category = category, tier = tier, soldOut = true, restock = Trade.restockIn(fid) }
end

-- AI 답장의 trade 필드로 거래 제안(offer) 또는 무상 제공(gift)을 만든다. 반환: 퀘스트, "offer" | "gift" / 없으면 nil
function Trade.fromReply(fid, ps, trade, ctx)
    if type(trade) ~= "table" or not ps then return nil end
    if trade.action ~= "offer" and trade.action ~= "gift" then return nil end
    ctx = ctx or Trade.context(fid, ps)
    if not ctx.allowed then
        log("trade offer ignored:", fid, ctx.reason)
        if ctx.reason == "low_trust" then return nil, "blocked", Trade.blocked(fid, trade.category, trade.tier) end
        return nil
    end
    -- 청한 물건이 있으면 그것을 첫 물건으로 (그 물건의 품목·등급으로 맞춘다)
    local wanted = nil
    if wantsItem(trade) then
        wanted = Trade.findItem(fid, ctx.goods, trade.category, trade.item, trade.item_said)
        if not wanted then
            log("trade item not carried:", fid, tostring(trade.item), tostring(trade.item_said))
            return nil, "blocked", notCarried(trade)
        end
        trade = { action = trade.action, category = wanted.category, pay_category = trade.pay_category,
                  tier = math.max(wanted.tier, math.min(math.floor(tonumber(trade.tier) or 1), wanted.maxTier)) }
        if wanted.tier > wanted.maxTier then
            log("trade item blocked:", fid, wanted.ft, "tier", wanted.tier, "max", wanted.maxTier)
            return nil, "blocked", Trade.blocked(fid, wanted.category, wanted.tier)
        end
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
        if not wanted or wanted.tier <= ctx.freeMaxTier then
            tier = math.min(tier, ctx.freeMaxTier)
            local gifts, gref
            if wanted then
                gifts = Trade.generate(trade.category, tier, fid, nil, wanted.ft)
            else
                gifts, gref = Trade.roll(trade.category, tier, fid, trade.bundle)
            end
            if not gifts then
                if gref == "sold_out" then return nil, "blocked", soldOut(fid, trade.category, tier) end
                return nil
            end
            local q = Quests.giftTrade(ps, fid, tier, gifts, Sensor.now())
            if q then
                Trade.markSold(fid, gref)
                -- 공짜로 내준 것도 그 NPC 몫에서 빠진다 (청한 물건 선물도, 점검 C9)
                local Life = StoryEngine.Life
                if Life then
                    Life.change(fid, Value.RESOURCE_OF[trade.category] or "safety", -Life.SOLD_PER_TIER * tier, "gift_sold")
                end
            end
            return q, "gift"
        end
        -- 청한 물건이 공짜로 주기엔 크면 보통 제안으로
    end
    local goods, ref
    if wanted then
        goods = Trade.generate(trade.category, tier, fid, nil, wanted.ft)
    else
        goods, ref = Trade.roll(trade.category, tier, fid, trade.bundle)
    end
    if not goods then
        if ref == "sold_out" then return nil, "blocked", soldOut(fid, trade.category, tier) end
        return nil
    end
    local price = math.ceil(Value.sum(goods) * priceMult(ctx, tier) * ((ctx.catMult or {})[trade.category] or 1))
    return Quests.proposeTrade(ps, fid, {
        tier = tier, category = trade.category, goods = goods, payCategory = payCategory, price = price,
        stockRef = type(ref) == "table" and ref or nil,
    }, Sensor.now()), "offer"
end

-- ---------------------------------------------------------------- 버튼 거래 (AI 없이도, 2026-10-03)
-- 교신 탭 [거래 요청] 버튼: 품목·등급을 골라 청하면 AI 답장과 같은 규칙(Trade.fromReply)으로 제안·선물·거절을 만든다.
-- 요청 횟수(의심)도 똑같이 센다. 대가 품목은 그 NPC 가 받는 것 중 플레이어가 가장 많이 가진 것.

-- 메뉴에 보여 줄 것: 취급 품목과 등급별 필요 신뢰도, 지금 막힌 이유
function Trade.options(fid, ps)
    local ctx = Trade.context(fid, ps)
    local out = { faction = fid, reason = ctx.reason, trust = ctx.trust, need = ctx.need, items = {} }
    if ctx.negotiating then out.reason = "negotiating" end
    local catalog = ctx.catalog
    if not catalog then
        local offer = Trade.offerContext(fid, ctx.trust or Radio.channel(fid).trust)
        catalog = offer.catalog
    end
    if not catalog then
        -- 아직 거래 전(신뢰도 부족)이어도 무엇을 얼마의 신뢰도에서 파는지는 보여 준다
        catalog = {}
        local rules = Trade.FACTIONS[fid] or { goods = {} }
        for _, cat in ipairs(Value.CATEGORIES) do
            local cap = rules.goods[cat] or 0
            if cap > 0 then
                local needs = {}
                for t = 1, cap do needs[t] = Trade.needTrust(fid, cat, t) or 101 end
                catalog[#catalog + 1] = { category = cat, maxTier = 0, needs = needs }
            end
        end
    end
    for _, c in ipairs(catalog or {}) do
        out.items[#out.items + 1] = { category = c.category, maxTier = ctx.allowed and c.maxTier or 0, needs = c.needs,
                                      empty = c.empty, short = c.short }
    end
    out.allowed = ctx.allowed == true
    -- 등급마다 고를 수 있는 묶음과 지금 값 (거래 목록 창, 2026-10-04)
    local offer = ctx.allowed and ctx or Trade.offerContext(fid, ctx.trust or Radio.channel(fid).trust)
    local st = Trade.stock(fid)
    out.restockIn = Trade.restockIn(fid)
    for _, it in ipairs(out.items) do
        it.tiers = {}
        for t = 1, #(it.needs or {}) do
            local stockList = st and st.cats[it.category] and st.cats[it.category][t] or {}
            local bundles = {}
            for i, b in ipairs(stockList) do
                local price = nil
                if offer.allowed then
                    price = math.ceil(Value.sum(b.goods) * priceMult(offer, t) * ((offer.catMult or {})[it.category] or 1))
                end
                bundles[i] = { items = group(b.goods), price = price, sold = b.sold or nil }
            end
            it.tiers[t] = bundles
        end
    end
    out.wants = Value.wantsOf(fid)
    out.black = Trade.blackInfo(fid, offer)
    return out
end

local function bestPay(wants, player)
    local stock = player and Trade.stockOf(player) or {}
    local best, value = wants[1], -1
    for _, w in ipairs(wants or {}) do
        local v = stock[w] or 0
        if v > value then best, value = w, v end
    end
    return best
end

-- 반환: true | false, 오류 코드
function Trade.ask(player, fid, category, tier, bundle)
    if not Factions.byId[fid] or not Trade.FACTIONS[fid] then return false, "no_trader" end
    if not Factions.canTalk(player) then return false, "no_radio" end
    if Factions.isGone(fid) then return false, "gone" end
    if StoryEngine.Saga and StoryEngine.Saga.radioDown(fid) then return false, "blackout" end
    if Radio.busy[fid] then return false, "busy" end
    tier = math.max(1, math.min(5, math.floor(tonumber(tier) or 1)))
    category = tostring(category or "")
    local ps = Store.player(player)
    local ctx = Trade.context(fid, ps)
    if ctx.negotiating or ctx.reason == "open_deal" then return false, "open_deal" end
    local now = Sensor.now()
    local day = Store.dayIndex(now.dayKey)
    Radio.push(fid, { from = "system", clock = now.clock, day = day, asked = { category = category, tier = tier,
                                                                             name = ps.name } })
    Radio.speaker[fid] = ps
    Radio.channel(fid).lastPlayerT = now.t
    local okR, errR = pcall(Trade.recordRequest, fid, ps)
    if not okR then log("trade request count error:", errR) end

    local Lines = StoryEngine.Lines
    local catText = category .. " (tier " .. StoryEngine.intToString(tier) .. ")"
    local deal, how, info = nil, nil, nil
    local black = bundle == "black" and Trade.black(fid) or nil
    if black and not black.sold then
        -- 암시장: 신뢰도와 상관없이, 정해진 값으로
        local goods = {}
        for _, ft in ipairs(black.goods) do goods[#goods + 1] = ft end
        deal = Quests.proposeTrade(ps, fid, { tier = black.tier, category = black.category, goods = goods,
            payCategory = bestPay(Value.wantsOf(fid), player), price = Trade.blackPrice(fid, black),
            stockRef = { black = black.seq } }, now)
        how = deal and "offer" or nil
        catText = "the black-market " .. black.category .. " (tier 5)"
    elseif bundle == "black" then
        info = { soldOut = true, category = category, tier = tier, restock = 7 }
        how = "blocked"
    elseif ctx.allowed then
        local action = ((ctx.freeMaxTier or 0) >= tier) and "gift" or "offer"
        deal, how, info = Trade.fromReply(fid, ps, { action = action, category = category, tier = tier,
                                                     pay_category = bestPay(ctx.wants or {}, player),
                                                     bundle = tonumber(bundle) }, ctx)
    else
        info = Trade.blocked(fid, category, tier)
        how = info and "blocked" or nil
    end
    if deal and how == "gift" then
        Radio.push(fid, { from = "system", clock = now.clock, quest = deal.id, gift = { goods = deal.items } })
        Radio.react(fid, "event", ps.name .. " asked you over the radio for " .. catText .. ". You decided to give it "
            .. "for free this time, because you trust them; it will be left in a building nearby. Tell them briefly.",
            Lines.fallback(fid, "gift", "This one is on me."), ps)
    elseif deal then
        Radio.push(fid, { from = "system", clock = now.clock, quest = deal.id,
                          offer = { goods = deal.goods, payCategory = deal.payCategory, price = deal.price } })
        Radio.react(fid, "event", ps.name .. " asked you over the radio for " .. catText .. ". You offer them: "
            .. Quests.listText(deal.goods) .. ", for " .. StoryEngine.intToString(deal.price) .. " worth of "
            .. tostring(deal.payCategory) .. ". The terms are already set; tell them the offer briefly in character "
            .. "and that they can accept or haggle.", Lines.fallback(fid, "offer", "Here is what I can do."), ps)
    else
        if how == "blocked" and info then
            Radio.push(fid, { from = "system", clock = now.clock, blocked = info })
        end
        Radio.react(fid, "event", ps.name .. " asked you over the radio for " .. catText .. ", but you will not trade "
            .. "that with them right now (" .. tostring(ctx.reason or "not enough trust or you are short yourself")
            .. "). Turn them down briefly in character.", Lines.fallback(fid, "refuse", "Not now."), ps)
    end
    log("trade ask", fid, category, tier, "by", ps.name, deal and (how or "offer") or "refused")
    return true
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
    for _, w in ipairs(Value.wantsOf(fid)) do
        if w == trade.pay_category then pay = w end
    end

    local category = trade.category
    local tier = math.floor(tonumber(trade.tier) or 0)
    -- 흥정 중에 특정 물건을 청하면 그 물건이 든 묶음으로 바꾼다
    local wanted = nil
    if wantsItem(trade) then
        local octx = Trade.offerContext(fid, trust)
        wanted = Trade.findItem(fid, octx.allowed and octx.goods or {}, category, trade.item, trade.item_said)
        if not wanted then
            log("trade swap item not carried:", q.id, tostring(trade.item), tostring(trade.item_said))
            return nil, "blocked", notCarried(trade)
        end
        category = wanted.category
        tier = math.max(wanted.tier, math.min(tier, wanted.maxTier))
    end
    local swap = wanted ~= nil or (type(category) == "string" and category ~= "" and category ~= "none"
        and (category ~= q.category or (tier > 0 and tier ~= q.tier)))
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
        local goods, ref
        if wanted then
            goods = Trade.generate(category, tier, fid, nil, wanted.ft)
        else
            goods, ref = Trade.roll(category, tier, fid)
        end
        if not goods then
            if ref == "sold_out" then return nil, "blocked", soldOut(fid, category, tier) end
            return nil, "same"
        end
        local price = math.ceil(Value.sum(goods) * priceMult(ctx, tier) * ((ctx.catMult or {})[category] or 1))
        Quests.swapTrade(q, category, tier, goods, math.max(1, price), pay, now)
        q.stockRef = type(ref) == "table" and ref or nil
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
        for _, item in ipairs(Value.payableItems(player, cat)) do total = total + Value.itemValue(item) end
        if total >= 1 then out[cat] = math.floor(total) end
    end
    return out
end

-- 지금 공용 주파수에서 제안할 수 있는 NPC 들. 플레이어에게 진행 중인 거래가 있으면 시장은 닫힌다.
-- player 가 있으면 가진 물건(stock)과 NPC 마다 모자란 품목(short)도 넘겨 판매 제안에 쓴다.
Trade.MARKET_GAP_MIN = 60     -- 공용 주파수 거래·판매 제안은 플레이어마다 게임 1시간에 한 번 (다시 굴리기 방지)

function Trade.marketContext(ps, player)
    if ps and Quests.openFor(ps.key, "trade") then return { closed = "open_deal" } end
    if ps and ps.lastMarketT and Sensor.now().t - ps.lastMarketT < Trade.MARKET_GAP_MIN then
        return { closed = "too_soon" }
    end
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
            -- 청한 물건: 이 NPC 에게 있고 지금 줄 수 있는 등급이면 그 물건이 든 묶음, 아니면 이 제안은 버린다
            local wanted = nil
            if wantsItem(o) and not sellCat then
                wanted = Trade.findItem(fid, ctx.allowed and ctx.goods or {}, o.category, o.item, o.item_said)
                if wanted and wanted.tier <= wanted.maxTier then
                    o = { faction = fid, category = wanted.category, pay_category = o.pay_category }
                    maxForCat = wanted.maxTier
                    tier = math.max(wanted.tier, math.min(tier, wanted.maxTier))
                else
                    log("market offer dropped:", fid, "no", tostring(o.item), tostring(o.item_said))
                    maxForCat, wanted = nil, false
                end
            end
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
                local goods, price, ref
                -- 판매: 플레이어가 가진 만큼만. 넘으면 등급을 하나씩 낮춰 다시 굴린다
                local lastPrice = nil
                while tier >= 1 do
                    if wanted then
                        goods, ref = Trade.generate(o.category, tier, fid, nil, wanted.ft), nil
                    else
                        goods, ref = Trade.roll(o.category, tier, fid)
                    end
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
                                      stockRef = type(ref) == "table" and ref or nil,
                                      payCategory = pay, price = price, selling = sellCat and true or nil,
                                      bonus = bonus > 1 and bonus or nil }
                    -- 요청 횟수(의심)는 플레이어가 고른 NPC 에게만 센다 (Quests.pickMarket, 2026-10-03 점검)
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
    if q.payKind and not q.credit then return false, "paying_with_work" end   -- 일로 갚는 중 (Work.lua)
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
                total = total + Value.itemValue(item)
            end
        end
    end
    if total < q.price then return false, "not_enough" end
    for _, item in ipairs(chosen) do StoryEngine.Items.remove(item, player) end
    log("trade paid", qid, total, "/", q.price)
    return Quests.completeTrade(player, q)
end

return Trade
