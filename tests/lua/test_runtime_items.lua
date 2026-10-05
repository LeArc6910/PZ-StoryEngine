-- 실행 중 자동 분류 (2026-10-05): 미리 만든 표에 없는 다른 모드 물건도 루팅표·레시피·이름으로 분류한다.
-- 따기 전 통조림·포장은 열면 나오는 음식의 배고픔+갈증 합계로 등급, 조리 재료(주식은 배고픔, 양념은 배고픔+루팅 희귀도)
local T = {}

-- 가짜 아이템 스크립트: dc, food = { hunger, thirst, spice, type, tags, cantEat }, notFood(포장)
local SCRIPTS = {
    ["MyMod.Canned"] = { dc = "Food", food = { hunger = 0, cantEat = true, tags = { HAS_METAL = true } } },
    ["MyMod.CannedOpen"] = { dc = "Food", food = { hunger = 0.3 } },
    ["MyMod.SnackBox"] = { dc = "Food", notFood = true },
    ["MyMod.Bar"] = { dc = "Food", food = { hunger = 0.08 } },
    ["MyMod.DriedBeans"] = { dc = "Food", food = { hunger = 0.6, cantEat = true, tags = { DRIED_FOOD = true } } },
    ["MyMod.Flour"] = { dc = "Food", food = { hunger = 0.6, cantEat = true, spice = true, type = "Thickener" } },
    ["MyMod.Ramen"] = { dc = "Food", food = { hunger = 0.1, thirst = -0.4, tags = { DRIED_FOOD = true } } },
    ["MyMod.Salt"] = { dc = "Food", food = { hunger = 0.1, thirst = -0.2, spice = true, tags = { MINOR_INGREDIENT = true } } },
    ["MyMod.Saffron"] = { dc = "Food", food = { hunger = 0.1, spice = true } },
    ["MyMod.Oil"] = { dc = "Food", food = { hunger = 0.3, spice = true } },
    ["MyMod.Yeast"] = { dc = "Food", food = { hunger = 0, spice = true } },
    ["MyMod.Wrench"] = { dc = "Tools" },
    ["MyMod.RareTool"] = { dc = "Tool" },
    ["MyMod.NoLootTool"] = { dc = "Tool" },
    ["MyMod.Painkillers"] = { dc = "Medical" },
    ["MyMod.SutureKit"] = { dc = "FirstAid" },
    ["MyMod.Gauze"] = { dc = "FirstAid" },
    ["MyMod.Tissues"] = { dc = "FirstAid" },
    ["MyMod.Walkie"] = { dc = "Communications" },
    ["MyMod.Tire"] = { dc = "CarParts" },
    ["MyMod.CrudeRadio"] = { dc = "Electronics" },
    ["MyMod.Chips"] = { dc = "Snacks", food = { hunger = 0.15 } },          -- 모드가 흔히 쓰는 음식 분류 이름
    ["MyMod.Jerky"] = { dc = "Provisions", food = { hunger = 0.25 } },      -- items.txt: category Provisions food
    ["MyMod.Ration"] = { dc = "SurvivalKit", food = { hunger = 0.4 } },     -- 처음 보는 이름: 수치로 자동 등록
    ["MyMod.RationBox"] = { dc = "SurvivalKit", notFood = true },
    ["MyMod.Lantern"] = { dc = "SurvivalKit" },
    ["MyMod.WheatSeed"] = { dc = "Gardening", food = { hunger = 0.05 } },   -- 바닐라 분류: 그대로
    ["MyMod.Bait"] = { dc = "Lure", food = { hunger = 0.05 } },             -- items.txt: category Lure none
    -- 처음 보는 분류 이름: 속성으로 종류를 정한다 (절반 이상)
    ["MyMod.Katana"] = { dc = "Swords", melee = { dmg = 2.5 } },
    ["MyMod.Saber"] = { dc = "Swords", melee = { dmg = 1.8 } },
    ["MyMod.SwordOil"] = { dc = "Swords" },
    ["MyMod.WoodSword"] = { dc = "Swords", melee = { dmg = 0.8 } },          -- 나뭇가지만으로 만든다 (1차 가공품)
    ["MyMod.Gauze2"] = { dc = "Remedies", props = { bandage = true } },
    ["MyMod.Pills2"] = { dc = "Remedies" },                                   -- 이름(Pills)
    ["MyMod.Scanner"] = { dc = "Gadgets", props = { radio = true } },
    ["MyMod.Lamp"] = { dc = "Gadgets", props = { light = 1.5 } },
    ["MyMod.Hood"] = { dc = "AutoBody", props = { mechanic = 2 } },
    ["MyMod.Notebook"] = { dc = "Stationery", props = {} },
    ["MyMod.Pillow"] = { dc = "Stationery", props = {} },
    ["MyMod.Pen"] = { dc = "Stationery", props = {} },
}
local LOOT = {
    ["MyMod.Gauze2"] = 60, ["MyMod.Pills2"] = 40, ["MyMod.Scanner"] = 300, ["MyMod.Lamp"] = 300, ["MyMod.Hood"] = 80,
    ["MyMod.Wrench"] = 500, ["MyMod.RareTool"] = 5, ["MyMod.Painkillers"] = 50, ["MyMod.SutureKit"] = 5,
    ["MyMod.Gauze"] = 80, ["MyMod.Tissues"] = 80, ["MyMod.Walkie"] = 400, ["MyMod.Tire"] = 80,
    ["MyMod.CrudeRadio"] = 30, ["MyMod.Salt"] = 900, ["MyMod.Oil"] = 400, ["MyMod.Saffron"] = 2,
}
-- 레시피: { 재료, 도구(keep), 결과 목록, 개수 }
local RECIPES = {
    { "MyMod.Canned", "Base.TinOpener", { "MyMod.CannedOpen" }, 1 },
    { "MyMod.SnackBox", nil, { "MyMod.Bar" }, 6 },
    { "MyMod.RationBox", nil, { "MyMod.Ration" }, 4 },
    { "Base.TreeBranch2", "Base.KitchenKnife", { "MyMod.WoodSword" }, 1 },
}

local function list(t)
    return { size = function() return #t end, get = function(_, i) return t[i + 1] end }
end

local function install()
    ItemTag = setmetatable({}, { __index = function(_, k) return k end })
    ResourceType = { Item = "item", Fluid = "fluid" }
    local function script(ft)
        local s = SCRIPTS[ft]
        if not s then return nil end
        local f = s.food or {}
        return {
            getFullName = function() return ft end,
            getModuleName = function() return string.match(ft, "^(.-)%.") end,
            getObsolete = function() return false end,
            isHidden = function() return false end,
            getDisplayCategory = function() return s.dc end,
            getActualWeight = function() return 0.5 end,
            getDoubleClickRecipe = function() return nil end,
            getDaysFresh = function() return 0 end,
            getReplaceOnUse = function() return nil end,
            isCantEat = function() return f.cantEat == true end,
            hasTag = function(_, tag) return (f.tags or {})[tag] == true end,
            isRanged = function() return false end,
            getAmmoType = function() return nil end,
        }
    end
    local all = {}
    for ft, _ in pairs(SCRIPTS) do all[#all + 1] = ft end
    table.sort(all)
    local scripts = {}
    for _, ft in ipairs(all) do scripts[#scripts + 1] = script(ft) end
    local function item(name) return { getFullName = function() return name end } end
    local recipes = {}
    for _, r in ipairs(RECIPES) do
        local inputs = { {
            getResourceType = function() return ResourceType.Item end, isTool = function() return false end,
            isKeep = function() return false end, getIntAmount = function() return 1 end,
            isAutomationOnly = function() return false end,
            getPossibleInputItems = function() return list({ item(r[1]) }) end,
        } }
        if r[2] then
            inputs[2] = {
                getResourceType = function() return ResourceType.Item end, isTool = function() return true end,
                isKeep = function() return true end, getIntAmount = function() return 1 end,
                isAutomationOnly = function() return false end,
                getPossibleInputItems = function() return list({ item(r[2]) }) end,
            }
        end
        local results = {}
        for _, o in ipairs(r[3]) do results[#results + 1] = item(o) end
        local out = {
            getResourceType = function() return ResourceType.Item end, getIntAmount = function() return r[4] end,
            getPossibleResultItems = function() return list(results) end, getOutputMapper = function() return nil end,
        }
        recipes[#recipes + 1] = { getInputs = function() return list(inputs) end, getOutputs = function() return list({ out }) end }
    end
    getScriptManager = function()
        return {
            FindItem = function(_, ft) return script(ft) end, getItem = function(_, ft) return script(ft) end,
            getAllItems = function() return list(scripts) end,
            getAllCraftRecipes = function() return list(recipes) end,
        }
    end
    ScriptManager = { instance = getScriptManager() }     -- Value 의 레시피 읽기도 같은 가짜를 쓰게
    instanceItem = function(ft)
        local s = SCRIPTS[ft]
        if not s then return nil end
        local isFood = s.food ~= nil and not s.notFood
        local classes = isFood and { "Food" } or {}
        if s.melee then classes = { "HandWeapon" } end
        if s.props and s.props.radio then classes = { "Radio" } end
        local it = H.newItem(ft, { classes = classes })
        local f = s.food or {}
        local m, pr = s.melee or {}, s.props or {}
        function it:isRanged() return false end
        function it:getMaxDamage() return m.dmg or 0 end
        function it:getMinDamage() return (m.dmg or 0) / 2 end
        function it:getConditionMax() return 10 end
        function it:getConditionLowerChance() return 10 end
        function it:getBaseSpeed() return 1 end
        function it:getMaxHitCount() return 1 end
        function it:isCanBandage() return pr.bandage == true end
        function it:getAlcoholPower() return 0 end
        function it:getReduceInfectionPower() return 0 end
        function it:getLightStrength() return pr.light or 0 end
        function it:isTorchCone() return false end
        function it:getMechanicType() return pr.mechanic or 0 end
        function it:isSpice() return f.spice == true end
        function it:getFoodType() return f.type or "NoExplicit" end
        function it:isbDangerousUncooked() return false end
        function it:isAlcoholic() return false end
        function it:getHungerChange() return -(f.hunger or 0) end
        function it:getThirstChange() return -(f.thirst or 0) end
        return it
    end
    -- 루팅표: 가중치가 두 목록에 나뉘어 들어간다 (합이 LOOT)
    ProceduralDistributions = { list = { ShelfA = { items = {} }, ShelfB = { items = {} } } }
    for ft, w in pairs(LOOT) do
        local a, b = ProceduralDistributions.list.ShelfA.items, ProceduralDistributions.list.ShelfB.items
        a[#a + 1] = ft
        a[#a + 1] = w / 2
        b[#b + 1] = ft
        b[#b + 1] = w / 2
    end
    getFileReader = function(path)
        if not string.find(path, "items.txt", 1, true) then return nil end
        local lines, i = { "category Provisions food", "category Lure none" }, 0
        return { readLine = function() i = i + 1 return lines[i] end, close = function() end }
    end
    local IP = StoryEngine.ItemPool
    IP.resetRuntime()
    IP.built = false
    IP.info, IP.pools = {}, {}
    IP.resetTradePools()
    StoryEngine.Value.cache = {}
    StoryEngine.Value.resetRaw()
    IP.build()
    return IP
end

function T.loot_weights_add_up_across_tables()
    local IP = install()
    H.eq(IP.lootWeights()["MyMod.Wrench"], 500)
    H.eq(IP.lootWeights()["MyMod.NoLootTool"], nil)
end

function T.sealed_can_uses_the_opened_food()
    local IP = install()
    local info = IP.info["MyMod.Canned"]
    H.ok(info and info.cat == "food", "the sealed can is tradable food")
    H.eq(info.tier, 4, "30 hunger once opened -> tier 4")
end

function T.package_tier_is_the_sum_of_what_is_inside()
    local IP = install()
    local info = IP.info["MyMod.SnackBox"]
    H.ok(info and info.pack, "the box is food too")
    H.eq(info.tier, 5, "6 bars x 8 hunger = 48 -> tier 5")
    H.eq(StoryEngine.Value.of("MyMod.SnackBox"), 3, "value is what is inside: 6 x 0.5")
    H.eq(StoryEngine.Value.categoryOf("MyMod.SnackBox"), "food")
    local inPool = false
    for _, ft in ipairs(IP.pools.food[5] or {}) do if ft == "MyMod.SnackBox" then inPool = true end end
    H.ok(inPool, "NPCs can sell the sealed box")
end

function T.staples_use_hunger()
    local IP = install()
    H.eq(IP.info["MyMod.DriedBeans"].tier, 5, "dried beans 60 hunger")
    H.eq(IP.info["MyMod.Flour"].tier, 5, "flour is a staple even though it counts as a spice")
    H.eq(IP.info["MyMod.Ramen"].tier, 2, "ramen 10 hunger (the thirst it adds does not count)")
end

function T.condiments_average_hunger_and_rarity()
    local IP = install()
    -- 양념 셋의 루팅 5분위 순위: 소금 900 -> 1, 기름 400 -> 2, 사프란 2 -> 4 (셋뿐이라 촘촘하다)
    local salt, oil, saffron = IP.info["MyMod.Salt"], IP.info["MyMod.Oil"], IP.info["MyMod.Saffron"]
    H.eq(salt.lootTier, 1)
    H.eq(salt.tier, 2, "salt: hunger+thirst relief 10 (tier 2) and common (1) -> 2 (1.5 rounds up)")
    H.eq(saffron.lootTier, 4)
    H.eq(saffron.tier, 3, "saffron: hunger tier 2 and rare (4) -> 3")
    H.ok(oil.tier <= 4, "oil: hunger tier 4 averaged with its rarity")
    H.eq(IP.info["MyMod.Yeast"], nil, "no hunger at all -> not traded")
end

function T.mod_tools_medical_electronics_and_car_parts_from_loot()
    local IP = install()
    H.eq(IP.runtime.tools["MyMod.Wrench"], 1, "common wrench")
    H.eq(IP.runtime.tools["MyMod.RareTool"], 5, "rare tool")
    H.eq(IP.runtime.tools["MyMod.NoLootTool"], nil, "not in any loot table: not sold")
    H.eq(StoryEngine.Value.categoryOf("MyMod.NoLootTool"), "tools", "still taken as payment")
    H.eq(StoryEngine.Value.of("MyMod.NoLootTool"), IP.TOOL_VALUE[IP.TOOL_UNKNOWN_TIER])
    H.eq(IP.runtime.medical["MyMod.Painkillers"], 2, "pills")
    H.eq(IP.runtime.medical["MyMod.SutureKit"], 3, "suture")
    H.eq(IP.runtime.medical["MyMod.Gauze"], 1)
    H.eq(IP.runtime.medical["MyMod.Tissues"], nil, "tissues are not medicine")
    H.eq(IP.runtime.electronics["MyMod.Walkie"], 1)
    H.eq(IP.runtime.electronics["MyMod.CrudeRadio"], nil, "hand-made electronics are not sold")
    H.eq(IP.runtime.vehicle["MyMod.Tire"], 1)
    local pool = IP.tradePool("tools")
    local found = false
    for _, ft in ipairs(pool[5] or {}) do if ft == "MyMod.RareTool" then found = true end end
    H.ok(found, "the rare mod tool is in the tier-5 trade pool")
    H.ok(StoryEngine.Value.pointKind("MyMod.Walkie") == "electronics", "counts for electronics requests")
end

function T.mod_food_categories_count_as_food()
    local IP = install()
    H.ok(IP.isFoodCategory("Snacks"), "common mod name")
    H.ok(IP.info["MyMod.Chips"] and IP.info["MyMod.Chips"].tier == 3, "Snacks: 15 hunger -> tier 3")
    H.ok(IP.isFoodCategory("Provisions"), "items.txt category line")
    H.ok(IP.info["MyMod.Jerky"] and IP.info["MyMod.Jerky"].tier == 4, "Provisions: 25 hunger -> tier 4")
    H.eq(StoryEngine.Value.categoryOf("MyMod.Jerky"), "food")
    H.eq(IP.unmapped["Provisions"], nil, "mapped categories are not reported")
end

function T.unknown_categories_with_real_food_become_food()
    local IP = install()
    H.ok(IP.autoKind["survivalkit"] and IP.autoKind["survivalkit"].kind == "food", "registered from its items")
    H.eq(IP.autoKind["survivalkit"].n, 1, "only the item that fills hunger counts")
    H.eq(IP.info["MyMod.Ration"].tier, 5, "40 hunger")
    H.ok(IP.info["MyMod.RationBox"] and IP.info["MyMod.RationBox"].pack, "the same category's package is food too")
    H.eq(IP.info["MyMod.Lantern"], nil, "non-food items of that category stay out")
    H.eq(IP.autoKind["gardening"], nil, "vanilla categories are never auto-registered")
    H.eq(IP.info["MyMod.WheatSeed"], nil)
    H.eq(IP.autoKind["lure"], nil, "items.txt 'none' stops it")
    H.eq(IP.unmapped["SurvivalKit"], nil, "not reported as unknown")
end

function T.unknown_categories_register_by_item_properties()
    local IP = install()
    H.eq(IP.autoKind["swords"].kind, "melee", "3 of 4 are melee weapons")
    H.ok(IP.info["MyMod.Katana"] and IP.info["MyMod.Katana"].cat == "melee")
    H.eq(IP.info["MyMod.SwordOil"], nil, "the non-weapon in that category is not a weapon")
    H.eq(IP.autoKind["remedies"].kind, "medical", "bandage + pill name")
    H.eq(IP.runtime.medical["MyMod.Pills2"], 2)
    H.eq(IP.autoKind["gadgets"].kind, "electronics", "radio + light")
    H.ok(IP.runtime.electronics["MyMod.Scanner"], "sold like electronics")
    H.eq(IP.autoKind["autobody"].kind, "vehicle")
    H.ok(IP.runtime.vehicle["MyMod.Hood"])
    H.eq(IP.autoKind["stationery"], nil, "no property in common: stays unknown")
    H.ok(IP.unmapped["Stationery"], "and is reported")
end

function T.forage_made_items_are_never_traded()
    local IP = install()
    local V = StoryEngine.Value
    H.eq(V.rawKind("MyMod.WoodSword"), "made", "a sword made only from a branch")
    H.ok(IP.info["MyMod.WoodSword"], "classified as a melee weapon")
    for _, list in pairs(IP.tradePool("melee")) do
        for _, ft in ipairs(list) do H.ok(ft ~= "MyMod.WoodSword", "but never sold") end
    end
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local item = H.give(p, "MyMod.WoodSword")
    H.ok(not V.payable(p, item, "melee"), "and never taken as payment")
    H.eq(V.donatable(p, item), nil, "or as a donation")
end

return T
