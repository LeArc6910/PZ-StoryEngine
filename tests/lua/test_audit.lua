-- 2026-10-03 점검 수정 (docs/AUDIT_2026-10-03.md): 물건 상태, 폭발물·의약품 가치, 탄약 상자, 받은 물건,
-- 신뢰도 상한(대화·거래), NPC 재고, 같은 물건 10개, 퀘스트 표시 이어 붙이기
local T = {}

local function V() return StoryEngine.Value end

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    StoryEngine.Life.daily()
    return p, ps
end

-- 내구도가 있는 가짜 아이템
local function worn(p, fullType, cond, max, opts)
    local it = H.give(p, fullType, opts)
    it.getCondition = function() return cond end
    it.getConditionMax = function() return max end
    it.isBroken = function() return cond <= 0 end
    return it
end

function T.condition_scales_value_and_broken_items_are_refused()
    local p = setup()
    H.defineItem("Base.TestGun", "firearm", 50)
    local good = worn(p, "Base.TestGun", 10, 10)
    local half = worn(p, "Base.TestGun", 5, 10)
    local broken = worn(p, "Base.TestGun", 0, 10)
    H.eq(V().itemValue(good), 50)
    H.eq(V().itemValue(half), 25, "half condition, half value")
    H.ok(V().payable(p, half, "firearm"))
    H.ok(not V().payable(p, broken, "firearm"), "broken gun is not payment")
    H.ok(V().summary(broken).broken, "tooltip says broken")
    H.eq(V().summary(half).worn, 50)
    -- 다 쓴 약통 (DrainableComboItem)
    H.defineItem("Base.TestPills", "medical", 3)
    local pills = H.give(p, "Base.TestPills", { classes = { "DrainableComboItem" } })
    pills.getCurrentUsesFloat = function() return 0.2 end
    H.eq(V().itemValue(pills), 3 * 0.2)
end

function T.crafted_explosives_and_medical_junk()
    StoryEngine.ItemPool.classify = (function(orig)
        return function(ft)
            if ft == "Base.Molotov" or ft == "Base.BombBig" then return { category = "explosive" } end
            if ft == "Base.BandageDirty" or ft == "Base.RippedSheets" or ft == "Base.Bandage" then return { category = "medical" } end
            return orig(ft)
        end
    end)(StoryEngine.ItemPool.classify)
    V().cache = {}
    H.eq(V().of("Base.Molotov"), 3, "crafted explosive")
    H.eq(V().of("Base.BombBig"), 20, "military grenade keeps 20")
    H.eq(V().categoryOf("Base.BandageDirty"), "misc", "dirty bandage is not medical")
    H.eq(V().categoryOf("Base.RippedSheets"), "misc")
    H.eq(V().categoryOf("Base.Bandage"), "medical")
end

function T.dried_herbs_are_raw()
    forageSystem = { itemDefs = { Plantain = { type = "Base.Plantain", categories = { "MedicinalPlants" } } } }
    V().resetRaw()
    H.ok(V().isRaw("Base.Plantain"))
    H.ok(V().isRaw("Base.PlantainDried"), "dried herb")
    forageSystem = nil
    V().resetRaw()
end

function T.finished_quest_items_can_be_donated_but_not_paid()
    local p = setup()
    H.defineItem("Base.TestCan", "food", 2)
    local d = StoryEngine.Store.data()
    d.quests.Q90 = { id = "Q90", kind = "supply_drop", state = "completed" }
    d.quests.Q91 = { id = "Q91", kind = "supply_drop", state = "offered" }
    local done = H.give(p, "Base.TestCan", { questTag = "Q90" })
    local active = H.give(p, "Base.TestCan", { questTag = "Q91" })
    H.ok(V().donatable(p, done) ~= nil, "finished quest item can be donated")
    H.ok(V().donatable(p, active) == nil, "active quest item cannot")
    H.ok(not V().payable(p, active, "food"), "an item of a quest in progress never pays for a trade")
    H.ok(V().payable(p, done, "food"), "an old item with no date on it is free once its quest is over")
    -- 놓인 시각이 찍힌 물건은 7일 동안 거래 대가로 못 낸다
    V().stamp(done, "Q90")
    H.ok(not V().payable(p, done, "food"), "not as trade payment for a week")
    H.ok(V().donatable(p, done) ~= nil, "donating still works")
    H.eq(V().summary(done).lock, 7)
    H.advanceDays(6)
    H.ok(not V().payable(p, done, "food"))
    H.eq(V().summary(done).lock, 1)
    H.advanceDays(1)
    H.ok(V().payable(p, done, "food"), "free after seven days")
    H.eq(V().summary(done).lock, nil)
    H.eq(V().questLock(done), nil)
    -- 선물(밖에서 온 사람)도 같은 제한
    V().stamp(done, "Q90")
    H.ok(not V().giftable(p, done))
    -- 샌드박스로 0일이면 바로
    SandboxVars.StoryEngine.RewardLockDays = 0
    H.ok(V().payable(p, done, "food"))
    SandboxVars.StoryEngine.RewardLockDays = 3
    H.eq(V().questLock(done), 3 * 1440)
    SandboxVars.StoryEngine.RewardLockDays = nil
    H.eq(V().questLock(done), V().QUEST_LOCK_DAYS * 1440)
end

function T.the_server_dates_what_it_hands_out()
    local p = setup()
    local t = StoryEngine.Sensor.now().t
    -- 우편으로 바로 받은 보상에도 날짜가 붙는다
    local item = StoryEngine.Items.addTo(p:getInventory(), "Base.TestCan", "post")
    H.eq(item:getModData().storyQuest, "post")
    H.eq(item:getModData().storyQuestT, t)
    H.eq(V().questLock(item), V().QUEST_LOCK_DAYS * 1440, "nothing called post is ever in progress")
    local plain = StoryEngine.Items.addTo(p:getInventory(), "Base.TestCan", nil)
    H.eq(plain:getModData().storyQuest, nil)
    H.eq(V().questLock(plain), nil)
end

function T.chat_trust_is_capped_per_day_and_npc_lines_do_not_move_it()
    local p = setup()
    local Radio = StoryEngine.Radio
    local ch = Radio.channel("ray")
    local start = ch.trust
    for _ = 1, 3 do
        Radio.lastSay = {}
        H.ok(Radio.say(p, "ray", "you're the best, Ray"))
        H.lastBridge("radio").callback({ ok = true, json = { reply = "Thanks.", trust_change = 1 } })
    end
    H.eq(ch.trust, start + 1, "only +1 a day from talk")
    -- 하루가 지나면 다시 +1
    H.advanceDays(1)
    Radio.lastSay = {}
    Radio.say(p, "ray", "hi again")
    H.lastBridge("radio").callback({ ok = true, json = { reply = "Hi.", trust_change = 1 } })
    H.eq(ch.trust, start + 2)
    -- NPC 가 먼저 한 말로는 움직이지 않는다
    Radio.request("ray", "EN", { mode = "chat", topic = "weather" })
    H.lastBridge("radio", "chat").callback({ ok = true, json = { reply = "Rain soon.", trust_change = -1 } })
    H.eq(ch.trust, start + 2, "chat mode ignores trust_change")
end

function T.trade_trust_weekly_cap_and_npc_stock()
    setup()
    local Trust, Life = StoryEngine.Trust, StoryEngine.Life
    local ch = StoryEngine.Radio.channel("ray")
    local start = ch.trust
    local food = Life.get("ray", "food")
    local tools = Life.get("ray", "tools") or Life.get("ray", "safety")
    for i = 1, 3 do
        local q = { id = "T" .. i, kind = "trade", tier = 3, category = "food", payCategory = "tools",
                    origin = { faction = "ray", initiator = "player" }, target = "tester|Gerald Kar", targetName = "Gerald Kar" }
        Trust.forQuest(q, "completed")
        Life.onQuest(q, "completed", 0)
    end
    H.eq(ch.trust, start + 5, "trade trust capped at +5 a week (3+3+3 -> 5)")
    H.ok(H.logHas("trade trust capped"))
    H.ok(Life.get("ray", "food") < food, "selling food lowers ray's food")
    -- 일주일이 지나면 다시 오른다
    H.advanceDays(7)
    Trust.forQuest({ id = "T9", kind = "trade", tier = 2, origin = { faction = "ray", initiator = "player" },
                     target = "tester|Gerald Kar" }, "completed")
    H.eq(ch.trust, start + 7)
end

function T.same_item_cap_in_donations()
    local p = setup()
    H.defineItem("Base.TestBook", "misc", 1)
    V().moraleValue = (function(orig)
        return function(ft) if ft == "Base.TestBook" then return 1 end return orig(ft) end
    end)(V().moraleValue)
    local ids = {}
    for _ = 1, 15 do ids[#ids + 1] = H.give(p, "Base.TestBook"):getID() end
    StoryEngine.Life.npc("casey").donatedT = nil
    H.ok(StoryEngine.Life.donate(p, "casey", ids))
    local left = 0
    for _, it in ipairs(p.items) do if it.fullType == "Base.TestBook" and it.container then left = left + 1 end end
    H.ok(left >= 5, "only 10 of the same item were taken (" .. left .. " left)")
end

function T.quest_tag_follows_crafted_items()
    require "StoryEngine/QuestTags"
    local made = H.newItem("Base.Bullets9mm")
    local box = H.newItem("Base.Bullets9mmBox", { questTag = "Q77" })
    box:getModData().storyQuestT = 4321
    ISHandcraftAction = { performRecipe = function(self) self.done = true end }
    ArrayList = { new = function()
        local l = H.list({})
        function l:add(x) self.items[#self.items + 1] = x end
        return l
    end }
    StoryEngine.QuestTags.install()
    local action = { character = nil, logic = {
        getRecipeData = function() return { getAllConsumedItems = function() return H.list({ box }) end } end,
        getCreatedOutputItems = function(_, list) list:add(made) end,
    } }
    ISHandcraftAction.performRecipe(action)
    H.ok(action.done, "original craft ran")
    H.eq(made:getModData().storyQuest, "Q77", "unpacked rounds keep the quest tag")
    H.eq(made:getModData().storyQuestT, 4321, "and the date it was handed out")
end

return T
