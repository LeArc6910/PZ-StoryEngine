-- 거래 흥정 (Trade.negotiate + Radio 의 흥정 처리): 가격 조정, 흥정 중 물건 교체, 말뿐인 흥정의 "조건 그대로" 줄
local T = {}

local function setup(trust)
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    SandboxVars.StoryEngine.ModItemsRatio = 0       -- 다른 모드 아이템 섞기는 가짜 환경에서 못 돌린다
    StoryEngine.Life.daily()
    StoryEngine.Radio.channel("ray").trust = trust or 65
    local q = StoryEngine.Trade.fromReply("ray", ps,
        { action = "offer", category = "food", tier = 2, pay_category = "medical" })
    H.ok(q and q.state == "proposed", "offer made")
    return p, ps, q
end

-- 플레이어가 무전으로 말하고, AI 가 trade 로 답한다
local function haggle(p, trade, reply)
    StoryEngine.Radio.lastSay = {}                 -- 실시간 발언 간격은 시험에서 넘긴다
    H.ok(StoryEngine.Radio.say(p, "ray", "can I get something else?"))
    local b = H.lastBridge("radio")
    H.ok(b and b.payload.trade.negotiating, "haggle context sent")
    b.callback({ ok = true, json = { reply = reply or "Let me see.", trust_change = 0, trade = trade } })
    return b
end

local function lastSystem()
    local msgs = StoryEngine.Radio.channel("ray").messages
    for i = #msgs, 1, -1 do
        if msgs[i].from == "system" then return msgs[i] end
    end
    return nil
end

function T.haggle_context_lists_goods_to_swap_to()
    local p = setup(65)
    local b = haggle(p, { action = "none" })
    local cats = {}
    for _, g in ipairs(b.payload.trade.goods or {}) do cats[g.category] = g.maxTier end
    H.eq(cats.melee, 2, "ray can swap to melee up to tier 2")
    H.eq(cats.food, 4, "food limited by trust 65")
end

function T.swap_changes_goods_and_reprices()
    local p, ps, q = setup(65)
    local oldGoods = q.goods
    haggle(p, { action = "counter", category = "melee", tier = 2, price = 0, pay_category = "tools" })
    H.eq(q.category, "melee")
    H.eq(q.tier, 2)
    H.ok(q.goods ~= oldGoods and #q.goods > 0, "new goods rolled")
    H.eq(q.payCategory, "tools")
    H.eq(q.basePrice, q.price, "fresh price is the new base")
    H.eq(q.haggles, 1)
    local m = lastSystem()
    H.ok(m and m.swapped and m.swapped.oldGoods == oldGoods, "swapped line with the old goods")
    H.ok(H.logHas("trade swapped"))
end

function T.swap_above_the_limit_is_blocked()
    local p, ps, q = setup(65)
    local goods = q.goods
    haggle(p, { action = "counter", category = "firearm", tier = 3, price = 0 })
    H.eq(q.goods, goods, "goods kept")
    H.eq(q.category, "food")
    local m = lastSystem()
    H.ok(m and m.blocked, "blocked line explains why")
end

function T.words_only_leave_an_unchanged_line()
    local p, ps, q = setup(65)
    local price = q.price
    haggle(p, { action = "none" }, "Fine, I'll throw in a knife instead.")
    H.eq(q.price, price)
    local m = lastSystem()
    H.ok(m and m.unchanged and m.unchanged.price == price, "terms unchanged line")
end

function T.price_counter_still_works_and_rounds_run_out()
    local p, ps, q = setup(65)
    local base = q.price
    haggle(p, { action = "counter", category = "food", tier = 2, price = base - 1, pay_category = "medical" })
    H.eq(q.price, math.max(StoryEngine.Trade.haggleFloor("ray", 65, base), base - 1))
    H.ok(lastSystem().revised, "revised line")
    q.haggles = StoryEngine.Trade.MAX_HAGGLES
    haggle(p, { action = "counter", category = "food", tier = 2, price = 1 })
    local m = lastSystem()
    H.ok(m.unchanged and m.unchanged.noRounds, "no rounds left is shown")
end

-- 가짜 B42 레시피 (CraftRecipe: getInputs/getOutputs)
local function fakeRecipe(inputs, outputs)
    local function list(t) return H.list(t) end
    local function script(ft) return { getFullName = function() return ft end } end
    local ins = {}
    for _, i in ipairs(inputs) do
        local items = {}
        for _, ft in ipairs(i.items) do items[#items + 1] = script(ft) end
        ins[#ins + 1] = {
            getResourceType = function() return ResourceType.Item end,
            isTool = function() return false end, isKeep = function() return i.keep == true end,
            isAutomationOnly = function() return false end,
            getPossibleInputItems = function() return list(items) end,
        }
    end
    local outs = {}
    for _, ft in ipairs(outputs) do
        outs[#outs + 1] = { getResourceType = function() return ResourceType.Item end,
                            getPossibleResultItems = function() return list({ script(ft) }) end }
    end
    return { getInputs = function() return list(ins) end, getOutputs = function() return list(outs) end }
end

function T.foraged_and_chopped_materials_are_not_payment()
    ResourceType = ResourceType or { Item = "Item" }
    ScriptManager = { instance = { getAllCraftRecipes = function() return H.list({
        -- 바닐라 CarveSpear 처럼 재료 칸 하나가 여러 물건 중 아무거나 (묘목은 채집 재료)
        fakeRecipe({ { items = { "Base.LongStick", "Base.Sapling", "Base.Rake", "Base.Mop" } },
                     { items = { "Base.KitchenKnife" }, keep = true } }, { "Base.SpearCrafted" }),
        fakeRecipe({ { items = { "Base.TreeBranch2" } } }, { "Base.Twine" }),
        fakeRecipe({ { items = { "Base.TreeBranch2" } }, { items = { "Base.Twine" } } }, { "Base.AxeStone" }),
        fakeRecipe({ { items = { "Base.Plantain" } } }, { "Base.PlantainCataplasm" }),
    }) end } }
    StoryEngine.Value.resetRaw()
    forageSystem = { itemDefs = {
        ModTwig = { type = "Mod.FancyTwig", categories = { "Firewood" } },
        Berry = { type = "Base.BerryBlack", categories = { "Berries" } },
        Whetstone = { type = "Base.Whetstone", categories = { "CraftingMaterials" } },
    } }
    local Value = StoryEngine.Value
    H.ok(Value.isRaw("Base.TreeBranch2"), "branch")
    H.ok(Value.isRaw("Base.Stone2") and Value.isRaw("Base.Plank") and Value.isRaw("Base.Log"), "stone, plank, log")
    H.ok(Value.isRaw("Mod.FancyTwig"), "mod forage item in a natural category")
    H.ok(Value.isRaw("Base.BerryBlack"))
    H.ok(not Value.isRaw("Base.Whetstone"), "real tools found while foraging still count")
    H.ok(not Value.isRaw("Base.Hammer"))
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local branch = H.give(p, "Base.TreeBranch2")
    H.ok(not Value.payable(p, branch, Value.categoryOf("Base.TreeBranch2")), "branch is not payment")
    local hammer = H.give(p, "Base.Hammer")
    H.ok(Value.payable(p, hammer, Value.categoryOf("Base.Hammer")), "hammer still is")
    -- 1차 가공품: 소모 재료가 모두 채집 재료인 레시피의 결과물
    H.eq(Value.rawKind("Base.TreeBranch2"), "raw")
    H.eq(Value.rawKind("Base.SpearCrafted"), "made", "sapling (one of the choices) + knife (kept) -> spear")
    H.eq(Value.rawKind("Base.Twine"), nil, "common store items stay allowed")
    H.eq(Value.rawKind("Base.AxeStone"), nil, "twine is not a foraged material")
    -- 약초는 바닐라 정의에 없으면 raw 가 아니므로 습포도 그대로
    H.eq(Value.rawKind("Base.PlantainCataplasm"), nil)
    local spear = H.give(p, "Base.SpearCrafted")
    H.ok(not Value.payable(p, spear, Value.categoryOf("Base.SpearCrafted")), "spear is not payment")
    H.ok(Value.donatable(p, spear) == nil, "nor a donation")
    H.ok(Value.projectItem(p, spear, { accept = "any", mult = 0.8 }) == nil, "nor project material")
    local s = Value.summary(spear)
    H.ok(s == nil or s.raw == "made", "tooltip marks it")
    forageSystem, ScriptManager = nil, nil
    Value.resetRaw()
end

return T
