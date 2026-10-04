-- 실시간 거래 묶음 (2026-10-04 사용자 결정): 그 등급 물건 1개 + 남은 예산을 거래 등급 이하 물건으로 무작위로
local T = {}

-- 가짜 풀: fullType -> { 품목, 등급, 가치, 바닐라 }
local ITEMS = {
    ["Base.Bandage"] = { "medical", 1, 2, true }, ["Base.AlcoholWipes"] = { "medical", 1, 2, true },
    ["Base.Pills"] = { "medical", 2, 4, true }, ["Base.Antibiotics"] = { "medical", 2, 4, true },
    ["Base.SutureNeedle"] = { "medical", 3, 6, true }, ["Base.Splint"] = { "medical", 3, 6, true },
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

return T
