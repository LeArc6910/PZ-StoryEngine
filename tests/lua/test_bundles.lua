-- 실시간 거래 묶음 (2026-10-04 사용자 결정): 그 등급 물건 1개 + 남은 예산을 거래 등급 이하 물건으로 무작위로
local T = {}

-- 가짜 풀: fullType -> { 품목, 등급, 가치, 바닐라 }
local ITEMS = {
    ["Base.Bandage"] = { "medical", 1, 2, true }, ["Base.AlcoholWipes"] = { "medical", 1, 2, true },
    ["Base.Pills"] = { "medical", 2, 4, true }, ["Base.Antibiotics"] = { "medical", 2, 4, true },
    ["Base.SutureNeedle"] = { "medical", 3, 6, true }, ["Base.Splint"] = { "medical", 3, 6, true },
    ["Base.Tweezers"] = { "medical", 3, 6, true },
    ["Base.TinnedBeans"] = { "food", 3, 1.5, true }, ["Base.Crisps"] = { "food", 1, 0.5, true },
    ["VFX.Granola"] = { "food", 3, 1.5, false }, ["VFX.Chips"] = { "food", 1, 0.5, false },
    ["Base.Pistol"] = { "firearm", 1, 30, true }, ["Base.9mmClip"] = { "ammo", 1, 3, true },
    ["Base.Bullets9mmBox"] = { "ammo", 1, 10, true },
    ["Base.Battery"] = { "electronics", 1, 2, true }, ["Base.Generator"] = { "electronics", 5, 20, true },
}

local saved = {}
local function install()
    local IP, Tiers = StoryEngine.ItemPool, StoryEngine.ItemTiers
    for _, k in ipairs({ "MEDICAL", "ELECTRONICS", "TOOLS", "VEHICLE" }) do
        saved[k] = saved[k] or Tiers[k]
        Tiers[k] = {}
    end
    getScriptManager = function()
        return { FindItem = function(_, ft)
            local d = ITEMS[ft]
            if not d then return nil end
            return { getExistsAsVanilla = function() return d[4] end, getDisplayCategory = function() return "x" end }
        end }
    end
    IP.built = true
    IP.pools = { food = {} }
    IP.guns, IP.gunsByTier = {}, {}
    for ft, d in pairs(ITEMS) do
        H.defineItem(ft, d[1] == "electronics" and "misc" or d[1], d[3])
        if d[1] == "medical" then Tiers.MEDICAL[ft] = d[2] end
        if d[1] == "electronics" then Tiers.ELECTRONICS[ft] = d[2] end
        if d[1] == "food" then
            IP.pools.food[d[2]] = IP.pools.food[d[2]] or {}
            table.insert(IP.pools.food[d[2]], ft)
        end
    end
    IP.guns["Base.Pistol"] = { tier = 1, ammoTier = 1, round = "Base.Bullets9mm", box = "Base.Bullets9mmBox", mag = "Base.9mmClip" }
    IP.gunsByTier[1] = { "Base.Pistol" }
    IP.resetTradePools()
    StoryEngine.Trade.resetFill()
end

local function restore()
    for k, v in pairs(saved) do StoryEngine.ItemTiers[k] = v end
end

local function tierOf(ft) return ITEMS[ft][2] end

function T.anchor_of_the_tier_then_fill_within_budget()
    install()
    local Trade, V = StoryEngine.Trade, StoryEngine.Value
    for _ = 1, 30 do
        local b = Trade.generate("medical", 2, "ray")
        H.eq(tierOf(b[1]), 2, "first item is of the trade tier")
        H.ok(V.sum(b) <= Trade.BUDGET.medical[2], "within the budget")
        for _, ft in ipairs(b) do H.ok(tierOf(ft) <= 2, ft .. " is not above the trade tier") end
        H.ok(#b >= 2, "filled up")
    end
    restore()
end

function T.highest_existing_tier_when_the_tier_has_nothing()
    install()
    local b = StoryEngine.Trade.generate("medical", 5, "ray")
    H.eq(tierOf(b[1]), 3, "medical only goes up to tier 3")
    H.ok(StoryEngine.Value.sum(b) <= StoryEngine.Trade.BUDGET.medical[5])
    restore()
end

function T.specialist_gets_a_bigger_budget()
    install()
    local Trade, V = StoryEngine.Trade, StoryEngine.Value
    local most = 0
    for _ = 1, 30 do most = math.max(most, V.sum(Trade.generate("medical", 2, "doc"))) end
    H.ok(most > Trade.BUDGET.medical[2], "doc's bundles can go past the normal budget")
    H.ok(most <= Trade.BUDGET.medical[2] * 1.3)
    restore()
end

function T.gun_comes_with_its_magazine_and_ammo()
    install()
    local b = StoryEngine.Trade.generate("firearm", 1, "ray")
    H.eq(b[1], "Base.Pistol")
    H.eq(b[2], "Base.9mmClip")
    H.eq(b[3], "Base.Bullets9mmBox")
    H.ok(StoryEngine.Value.sum(b) <= StoryEngine.Trade.BUDGET.firearm[1])
    restore()
end

function T.mod_items_follow_the_sandbox_ratio()
    install()
    local Trade = StoryEngine.Trade
    SandboxVars.StoryEngine.ModItemsRatio = 0
    for _ = 1, 20 do
        for _, ft in ipairs(Trade.generate("food", 3, "ray")) do H.ok(ITEMS[ft][4], ft .. " should be vanilla at 0%") end
    end
    SandboxVars.StoryEngine.ModItemsRatio = 100
    for _ = 1, 20 do
        for _, ft in ipairs(Trade.generate("food", 3, "ray")) do H.ok(not ITEMS[ft][4], ft .. " should be a mod item at 100%") end
    end
    restore()
end

function T.casey_sells_electronics_as_her_tools()
    install()
    local b = StoryEngine.Trade.generate("tools", 5, "casey")
    H.eq(b[1], "Base.Generator", "tier 5 electronics")
    for _, ft in ipairs(b) do H.eq(ITEMS[ft][1], "electronics") end
    restore()
end

function T.quest_rewards_are_generated()
    install()
    local Loot, V = StoryEngine.Loot, StoryEngine.Value
    for _ = 1, 20 do
        local out = Loot.roll(2, "doc")
        local med, has2 = 0, false
        for _, ft in ipairs(out) do
            local d = ITEMS[ft]
            if d and d[1] == "medical" then
                med = med + d[3]
                if d[2] == 2 then has2 = true end
            end
        end
        H.ok(has2, "a tier 2 medical item leads the medical part")
        -- 의약품 보상 예산 8 + 닥 전문 묶음(거래 예산 12의 절반)
        H.ok(med <= Loot.BUDGET.medical[2] + StoryEngine.Trade.BUDGET.medical[2] * Loot.SPECIALTY_SHARE, "within the budgets")
    end
    -- 1등급은 도구·근접 무기·총 중 하나만이고, 총이면 탄창·탄약과 함께
    SandboxVars.StoryEngine.ModItemsRatio = 0
    local sawGun = false
    for _ = 1, 60 do
        local out = Loot.roll(1)
        for i, ft in ipairs(out) do
            if ft == "Base.Pistol" then
                sawGun = true
                H.eq(out[i + 1], "Base.9mmClip")
            end
        end
    end
    H.ok(sawGun, "a pistol shows up now and then")
    restore()
end

local function tradeSetup(trust)
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    StoryEngine.Life.daily()
    StoryEngine.Trade.FREE_CHANCE = 0
    StoryEngine.Radio.channel("doc").trust = trust
    return p, ps
end

function T.requested_item_leads_the_deal()
    install()
    local _, ps = tradeSetup(65)
    local q, how = StoryEngine.Trade.fromReply("doc", ps,
        { action = "offer", category = "medical", tier = 1, pay_category = "food", item = "tweezers", item_said = "핀셋" })
    H.eq(how, "offer")
    H.eq(q.goods[1], "Base.Tweezers", "the asked-for item comes first")
    H.eq(q.tier, 3, "the deal takes the item's tier")
    H.eq(q.stockRef, nil, "made to order, not from the stock")
    restore()
end

function T.item_they_do_not_carry_makes_no_offer()
    install()
    local _, ps = tradeSetup(65)
    local q, how, info = StoryEngine.Trade.fromReply("doc", ps,
        { action = "offer", category = "medical", tier = 2, pay_category = "food", item = "chainsaw", item_said = "전기톱" })
    H.eq(q, nil)
    H.eq(how, "blocked")
    H.ok(info.notCarried and info.item == "전기톱", "they are told it is not carried")
    restore()
end

function T.item_above_trust_is_blocked_with_the_trust_needed()
    install()
    local _, ps = tradeSetup(25)
    local q, how, info = StoryEngine.Trade.fromReply("doc", ps,
        { action = "offer", category = "medical", tier = 1, pay_category = "food", item = "splint", item_said = "" })
    H.eq(q, nil)
    H.eq(how, "blocked")
    H.eq(info.tier, 3, "blocked at the splint's tier")
    restore()
end

function T.stock_uses_generated_bundles()
    install()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    StoryEngine.Store.player(p).lang = "EN"
    local st = StoryEngine.Trade.stock("doc")
    local list = st.cats.medical[2]
    H.eq(#list, StoryEngine.Trade.STOCK_BUNDLES)
    for _, b in ipairs(list) do H.eq(tierOf(b.goods[1]), 2) end
    restore()
end

-- 감염 진단 키트 (2026-10-18): 닥의 3등급 이상 의약품 거래에만, 가치 10. 다른 NPC·보상에는 없음
function T.test_kit_only_in_docs_trades()
    install()
    local KIT = "StoryEngine.InfectionTestKit"
    local Trade, IP = StoryEngine.Trade, StoryEngine.ItemPool
    local find = getScriptManager().FindItem
    getScriptManager = function()
        return { FindItem = function(self, ft)
            if ft == KIT then
                return { getExistsAsVanilla = function() return false end, getDisplayCategory = function() return "FirstAid" end }
            end
            return find(self, ft)
        end }
    end
    H.defineItem(KIT, "medical", 10, 3)
    IP.resetTradePools()
    Trade.resetFill()
    local function has(list, ft) for _, x in ipairs(list or {}) do if x == ft then return true end end return false end
    H.ok(has(IP.tradePool("medical_doc")[3], KIT), "in Doc's tier 3 pool")
    H.ok(not has(IP.tradePool("medical")[3], KIT), "not in the shared medical pool")
    local seen = false
    for _ = 1, 80 do
        if has(Trade.generate("medical", 3, "doc"), KIT) then seen = true end
        H.ok(not has(Trade.generate("medical", 2, "doc"), KIT), "not below tier 3")
        H.ok(not has(Trade.generate("medical", 3, "ray"), KIT), "only Doc sells it")
        H.ok(not has(Trade.generate("medical", 3, "doc", 20), KIT), "not in rewards")
    end
    H.ok(seen, "Doc's tier 3 bundles sometimes have it")
    restore()
end

-- 백신 모드 물건 (2026-10-18): 알부민 3등급 10, 기본 백신 4등급 30, 품질 백신 5등급 60. 닥만, 재고에는 등급마다 한 묶음만,
-- 닥에게서 사기만 하고 대가·지원으로는 못 낸다
local LAB = { ["LabItems.CmpAlbuminPills"] = { 3, 10 }, ["LabItems.CmpSyringeWithPlainVaccine"] = { 4, 30 },
              ["LabItems.CmpSyringeWithQualityVaccine"] = { 5, 60 } }
local function installLab()
    install()
    local IP = StoryEngine.ItemPool
    local find = getScriptManager().FindItem
    getScriptManager = function()
        return { FindItem = function(self, ft)
            if LAB[ft] then
                return { getExistsAsVanilla = function() return false end, getDisplayCategory = function() return "Laboratory" end }
            end
            return find(self, ft)
        end }
    end
    for ft, d in pairs(LAB) do H.defineItem(ft, "medical", d[2], d[1]) end
    IP.resetTradePools()
    StoryEngine.Trade.resetFill()
end
local function count(goods, ft)
    local n = 0
    for _, x in ipairs(goods or {}) do if x == ft then n = n + 1 end end
    return n
end
local PLAIN, QUALITY = "LabItems.CmpSyringeWithPlainVaccine", "LabItems.CmpSyringeWithQualityVaccine"

function T.vaccines_are_one_bundle_per_restock_at_doc()
    installLab()
    H.addPlayer("tester", "Gerald", "Kar")
    local Trade = StoryEngine.Trade
    for _ = 1, 10 do
        StoryEngine.Radio.channel("doc").stock = nil
        local st = Trade.stock("doc")
        for tier, ft in pairs({ [4] = PLAIN, [5] = QUALITY }) do
            local with = 0
            for _, b in ipairs(st.cats.medical[tier]) do
                if count(b.goods, ft) > 0 then with = with + 1 end
                H.ok(count(b.goods, PLAIN) + count(b.goods, QUALITY) <= 1, "one vaccine at most in a bundle")
            end
            H.eq(with, 1, "one bundle of tier " .. tier .. " has the vaccine")
        end
        for _, b in ipairs(st.cats.medical[3]) do
            H.eq(count(b.goods, PLAIN) + count(b.goods, QUALITY), 0, "no vaccine below tier 4")
        end
    end
    StoryEngine.Radio.channel("ray").stock = nil
    for _, list in pairs(Trade.stock("ray").cats.medical or {}) do
        for _, b in ipairs(list) do H.eq(count(b.goods, PLAIN) + count(b.goods, QUALITY), 0, "only Doc sells vaccines") end
    end
    -- 재고 밖의 생성(보상·덤·청한 물건의 채움)에는 백신이 없다
    for _ = 1, 30 do
        H.eq(count(Trade.generate("medical", 5, "doc", 80), QUALITY), 0, "not in rewards")
        H.eq(count(Trade.rollFresh("medical", 5, "doc"), QUALITY) + count(Trade.rollFresh("medical", 4, "doc"), PLAIN), 0,
            "not in work bonuses")
        H.eq(count(Trade.generate("medical", 5, "doc", nil, "Base.Tweezers"), QUALITY), 0, "not as filler")
    end
    restore()
end

function T.asking_for_a_vaccine_takes_the_stock_bundle()
    installLab()
    H.addPlayer("tester", "Gerald", "Kar")
    local Trade = StoryEngine.Trade
    StoryEngine.Radio.channel("doc").stock = nil
    local wanted = { ft = PLAIN, category = "medical", tier = 4, maxTier = 5 }
    local goods, ref, tier = Trade.wantedGoods("medical", 5, "doc", wanted)
    H.ok(goods and count(goods, PLAIN) == 1, "the bundle with the vaccine")
    H.eq(tier, 4)
    H.ok(type(ref) == "table" and ref.tier == 4)
    Trade.markSold("doc", ref)
    local again, why = Trade.wantedGoods("medical", 5, "doc", wanted)
    H.eq(again, nil)
    H.eq(why, "sold_out", "until the next restock")
    restore()
end

function T.vaccines_cannot_be_handed_over()
    installLab()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local V = StoryEngine.Value
    for ft in pairs(LAB) do
        local it = H.give(p, ft)
        H.eq(V.payable(p, it, "medical"), false, ft .. " not as payment")
        H.eq(V.donatable(p, it), nil, "not as support")
        H.eq(V.pointPayable(p, it, "medical"), false, "not for requests")
        H.eq(V.giftable(p, it), false, "not as a gift")
        H.eq(V.projectItem(p, it, { res = "medical" }), nil, "not for projects")
        local s = V.summary(it)
        H.ok(s and s.sellOnly, "tooltip says so")
    end
    H.eq(V.of(PLAIN), 30)
    H.eq(V.of(QUALITY), 60)
    H.eq(V.of("LabItems.CmpAlbuminPills"), 10)
    local c = StoryEngine.ItemPool.classify(QUALITY)
    H.ok(c.category == "medical" and c.tier == 5, "medical tier 5 whatever its category name")
    V.cache[PLAIN] = nil
    H.eq(V.of(PLAIN), 30, "value from the table")
    restore()
end

return T
