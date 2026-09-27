-- 플레이어가 먼저 요청하는 거래 (서버 측 전용, B단계).
--
-- 1. 플레이어가 무전으로 물건을 요청하면, Radio 가 Trade.context 로 계산한 "지금 가능한 거래 한도"를 AI 에 넘긴다.
-- 2. AI 는 답장과 함께 trade = { action, category, tier, pay_category } 를 돌려준다.
-- 3. Trade.fromReply 가 한도로 다시 검증하고(넘으면 낮추거나 버림), 실제 물건과 가격은 게임이 정해 거래 제안을 만든다.
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
Trade.FACTIONS = {
    ray = { goods = { food = 5, medical = 3, tools = 3, melee = 2, firearm = 1, ammo = 2 },
            wants = { "food", "medical", "tools", "ammo" } },
    casey = { goods = { tools = 5, food = 1, medical = 1 },
              wants = { "food", "medical" } },
    doc = { goods = { medical = 5, food = 2, tools = 2 },
            wants = { "food", "tools", "melee" } },
    pike = { goods = { food = 5, medical = 2, tools = 2, melee = 1 },
             wants = { "medical", "tools", "food" }, priceMult = 0.8 },
    dewey = { goods = { tools = 5, melee = 3, food = 1 },
              wants = { "food", "medical", "ammo" } },
    hunter = { goods = { firearm = 4, ammo = 4, melee = 4, food = 3 },
               wants = { "medical", "tools" } },
    guard = { goods = { food = 3, medical = 3, tools = 3, melee = 3, firearm = 5, ammo = 5 },
              wants = { "medical", "tools", "food" }, gunTrust = 60 },
    rats = { goods = { food = 3, medical = 3, tools = 5, melee = 5, firearm = 4, ammo = 4 },
             wants = { "ammo", "firearm", "medical", "tools" }, stretch = 1, stretchMult = 1.5 },
}

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

local function limitFor(trust)
    for _, row in ipairs(Trade.LIMITS) do
        if trust >= row.min then return row end
    end
    return Trade.LIMITS[#Trade.LIMITS]
end

-- 이 세력이 지금 이 플레이어와 할 수 있는 거래. AI 에 넘기고, 제안 검증에도 쓴다.
function Trade.context(fid, ps)
    local rules = Trade.FACTIONS[fid]
    if not rules then return { allowed = false, reason = "no_trader" } end
    local trust = Radio.channel(fid).trust
    local limit = limitFor(trust)
    if limit.maxTier == 0 then return { allowed = false, reason = "low_trust", trust = trust } end
    if ps and Quests.openFor(ps.key, "trade") then return { allowed = false, reason = "open_deal", trust = trust } end

    local goods = {}
    for _, cat in ipairs(Value.CATEGORIES) do
        local best = math.min(rules.goods[cat] or 0, limit.maxTier + (rules.stretch or 0))
        if rules.gunTrust and (cat == "firearm" or cat == "ammo") and trust < rules.gunTrust then best = 0 end
        if best > 0 then goods[#goods + 1] = { category = cat, maxTier = best } end
    end
    if #goods == 0 then return { allowed = false, reason = "nothing", trust = trust } end
    local recent = Trade.recentRequests(fid)
    local suspicious = recent + 1 >= Trade.SUSPICIOUS_COUNT
    return {
        recentRequests = recent, suspicious = suspicious,
        freeMaxTier = (trust >= Trade.FREE_TRUST and not suspicious and ZombRand(100) < Trade.FREE_CHANCE)
            and Trade.FREE_MAX_TIER or 0,
        allowed = true, trust = trust, maxTier = limit.maxTier, mult = limit.mult * (rules.priceMult or 1),
        stretchMult = rules.stretchMult, goods = goods, wants = rules.wants,
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
        return nil
    end
    local maxForCat = nil
    for _, g in ipairs(ctx.goods) do
        if g.category == trade.category then maxForCat = g.maxTier end
    end
    if not maxForCat then
        log("trade offer ignored: category not allowed", fid, tostring(trade.category))
        return nil
    end
    local tier = math.max(1, math.min(maxForCat, math.floor(tonumber(trade.tier) or 1)))
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
    local price = math.ceil(Value.sum(goods) * priceMult(ctx, tier))
    return Quests.proposeTrade(ps, fid, {
        tier = tier, category = trade.category, goods = goods, payCategory = payCategory, price = price,
    }, Sensor.now()), "offer"
end

-- 대가 제출. itemIds 는 클라이언트가 고른 아이템 ID 목록. 성공하면 true, 배송 퀘스트 / 실패하면 false, 오류 코드
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
