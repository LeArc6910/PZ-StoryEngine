-- 공용 주파수 거래 (Trade.marketContext/marketOffers, Quests.proposeMarket/pickMarket, Social.scene 의 offers)
local T = {}

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    SandboxVars.StoryEngine.ModItemsRatio = 0       -- 다른 모드 아이템 섞기는 가짜 환경에서 못 돌린다
    StoryEngine.Life.daily()
    StoryEngine.Radio.channel("ray").trust = 65
    StoryEngine.Radio.channel("doc").trust = 50
    return p, ps
end

-- 플레이어가 공용 주파수에서 말하고, AI 가 장면과 제안으로 답한다
local function ask(p, offers, lines, selling, keepGaps)
    StoryEngine.Radio.lastSay = {}
    StoryEngine.Social.sceneBusy = false
    if not keepGaps then
        -- 빈도 제한(장면 5분, 제안 1시간)은 따로 시험한다
        StoryEngine.Social.lastReplyT = nil
        StoryEngine.Store.player(p).lastMarketT = nil
    end
    H.ok(StoryEngine.Radio.say(p, "open", "anyone got food to trade?"))
    local b = H.lastBridge("radio_scene")
    H.ok(b ~= nil, "scene requested")
    b.callback({ ok = true, json = {
        lines = lines or { { speaker = "ray", text = "I can spare some cans." } },
        offers = offers or {}, selling = selling or "none",
    } })
    return b
end

local function marketQuest()
    for _, q in pairs(StoryEngine.Store.data().quests) do
        if q.kind == "market" and q.state == "proposed" then return q end
    end
    return nil
end

local function lastOpen()
    local msgs = StoryEngine.Radio.channel("open").messages
    for i = #msgs, 1, -1 do
        if msgs[i].from == "system" then return msgs[i] end
    end
    return nil
end

function T.market_context_lists_traders()
    local p = setup()
    local b = ask(p, {})
    local ids = {}
    for _, s in ipairs(b.payload.market.sellers or {}) do ids[s.id] = s end
    H.ok(ids.ray and ids.doc, "ray and doc can trade")
    H.ok(not ids.hunter, "hunter (trust 0) cannot")
    H.ok(marketQuest() == nil, "no offers, no quest")
end

function T.offers_become_a_pick_quest()
    local p, ps = setup()
    ask(p, {
        { faction = "ray", category = "food", tier = 2, pay_category = "medical" },
        { faction = "doc", category = "medical", tier = 5, pay_category = "food" },     -- 한도 넘으면 낮춘다
        { faction = "ray", category = "melee", tier = 1, pay_category = "food" },       -- 같은 사람 두 번
        { faction = "hunter", category = "food", tier = 1, pay_category = "food" },     -- 거래 불가
        { faction = "doc", category = "firearm", tier = 1, pay_category = "food" },
    }, { { speaker = "ray", text = "Cans, sure." }, { speaker = "doc", text = "I have bandages." } })
    local q = marketQuest()
    H.ok(q ~= nil, "market quest")
    H.eq(#q.options, 2)
    H.eq(q.options[1].faction, "ray")
    H.eq(q.options[2].faction, "doc")
    H.ok(q.options[2].tier < 5, "doc's tier clamped to what she can offer")
    H.ok(#q.options[1].goods > 0 and q.options[1].price > 0)
    local m = lastOpen()
    H.ok(m and m.market and #m.market == 2, "open channel announces the offers")
    local msgs = StoryEngine.Radio.channel("open").messages
    local doc = false
    for _, msg in ipairs(msgs) do if msg.npc == "doc" then doc = true end end
    H.ok(doc or #StoryEngine.Store.data().social.pending.lines > 0, "doc may speak although not a participant")
end

function T.picking_starts_an_accepted_trade()
    local p, ps = setup()
    ask(p, { { faction = "ray", category = "food", tier = 2, pay_category = "medical" },
             { faction = "doc", category = "medical", tier = 2, pay_category = "food" } })
    local q = marketQuest()
    local trustBefore = StoryEngine.Radio.channel("ray").trust
    H.ok(StoryEngine.Quests.pickMarket(p, q.id, 2))
    H.eq(q.state, "completed")
    H.eq(q.chosen, "doc")
    local trade = StoryEngine.Quests.openTrade("doc")
    H.ok(trade and trade.state == "accepted", "doc's trade is accepted")
    H.eq(trade.goods, q.options[2].goods)
    H.eq(trade.price, q.options[2].price)
    H.ok(StoryEngine.Quests.openTrade("ray") == nil, "ray's offer was not taken")
    H.eq(StoryEngine.Radio.channel("ray").trust, trustBefore, "no penalty for the others")
    local docMsgs = StoryEngine.Radio.channel("doc").messages
    H.ok(docMsgs[#docMsgs].offer ~= nil or #docMsgs > 0, "terms written on doc's channel")
    -- 진행 중인 거래가 있으니 다음 요청에는 시장이 닫혀 있다
    local b = ask(p, {})
    H.eq(b.payload.market.closed, "open_deal")
end

function T.unpicked_offers_close_quietly()
    local p, ps = setup()
    ask(p, { { faction = "ray", category = "food", tier = 1, pay_category = "medical" } })
    local q = marketQuest()
    local trust = StoryEngine.Radio.channel("ray").trust
    H.advance(13 * 60)
    StoryEngine.Quests.track({}, StoryEngine.Sensor.now())
    H.eq(q.state, "declined")
    H.eq(StoryEngine.Radio.channel("ray").trust, trust, "ignoring offers costs no trust")
    -- 새 제안이 오면 예전 제안은 닫힌다
    ask(p, { { faction = "ray", category = "food", tier = 1, pay_category = "medical" } })
    local first = marketQuest()
    ask(p, { { faction = "doc", category = "medical", tier = 1, pay_category = "food" } })
    H.eq(first.state, "declined")
    H.eq(marketQuest().options[1].faction, "doc")
end

function T.questChoose_routes_to_market()
    local p = setup()
    ask(p, { { faction = "ray", category = "food", tier = 1, pay_category = "medical" } })
    local q = marketQuest()
    StoryEngine.Commands.questChoose(p, { id = q.id, index = 1 })
    H.eq(q.chosen, "ray")
end

-- 판매 시장: 플레이어가 가진 물건을 내놓으면 그것을 받는 NPC 들이 자기 물건을 제안한다
local function cans(p, n)
    StoryEngine.Value.cache["Base.TestCan"] = { category = "food", value = 3 }
    for _ = 1, n do H.give(p, "Base.TestCan") end
end

function T.selling_food_gets_buyers()
    local p, ps = setup()
    cans(p, 100)                                                 -- 음식 가치 300 (가짜 환경은 물건 가치가 커서 넉넉히)
    StoryEngine.Life.change("doc", "food", -100, "test")          -- 닥은 음식이 바닥: 후하게
    local b = ask(p, {
        { faction = "doc", category = "medical", tier = 1, pay_category = "tools" },
        { faction = "ray", category = "tools", tier = 1, pay_category = "food" },
        { faction = "hunter", category = "food", tier = 1, pay_category = "medical" },   -- 음식을 안 받는 사람
    }, nil, "food")
    H.eq(b.payload.market.stock.food, 300, "stock sent to the AI")
    local q = marketQuest()
    local why = {}
    if not q then for _, l in ipairs(H.logs) do if string.find(l, "market", 1, true) or string.find(l, "error", 1, true) then why[#why + 1] = l end end end
    H.ok(q ~= nil, "buyers: " .. table.concat(why, " | "))
    H.eq(q.selling, "food")
    H.eq(#q.options, 2)
    for _, o in ipairs(q.options) do
        H.eq(o.payCategory, "food", "payment is what the player sells")
        H.ok(o.price <= 300, "within what the player has")
    end
    H.eq(q.options[1].bonus, 1.5, "doc is out of food and pays more")
    local m = lastOpen()
    H.ok(m.market and m.sell == "food", "open channel says these are buyers")
    H.ok(StoryEngine.Quests.pickMarket(p, q.id, 2))
    local trade = StoryEngine.Quests.openTrade("ray")
    H.ok(trade and trade.state == "accepted" and trade.payCategory == "food")
end

function T.selling_more_than_you_have_lowers_or_drops_offers()
    local p = setup()
    cans(p, 1)                                                   -- 음식 가치 3뿐
    ask(p, { { faction = "ray", category = "tools", tier = 3, pay_category = "food" } }, nil, "food")
    local q = marketQuest()
    if q then
        H.ok(q.options[1].price <= 3 and q.options[1].tier < 3, "tier lowered to what the player can pay")
    else
        H.ok(H.logHas("market sell offer dropped"), "or dropped")
    end
    -- 가진 게 없는 품목을 판다고 하면 제안이 없다
    StoryEngine.Store.data().quests = {}
    ask(p, { { faction = "ray", category = "tools", tier = 1, pay_category = "medical" } }, nil, "medical")
    H.ok(marketQuest() == nil)
    H.ok(H.logHas("nothing to sell in"))
end

function T.open_channel_rate_limits()
    local p, ps = setup()
    ask(p, { { faction = "ray", category = "food", tier = 1, pay_category = "medical" } })
    H.ok(marketQuest() ~= nil)
    -- 같은 게임 시간 안에 또 말하면 장면은 미뤄지고(5분), 시장은 1시간 동안 닫힌다
    StoryEngine.Radio.lastSay = {}
    local before = #H.bridge
    H.ok(StoryEngine.Radio.say(p, "open", "anything else?"))
    H.eq(#H.bridge, before, "reply scene waits")
    H.ok(StoryEngine.Social.sceneAgain ~= nil)
    H.advance(6)
    StoryEngine.Social.release()
    local b = H.lastBridge("radio_scene")
    H.eq(#H.bridge, before + 1, "runs after the gap")
    H.eq(b.payload.market.closed, "too_soon", "no new offers within the hour")
    -- 공용 주파수 거래는 고른 NPC 에게만 의심 횟수를 센다
    local q = marketQuest()
    local before2 = StoryEngine.Trade.recentRequests("doc")
    H.ok(StoryEngine.Quests.pickMarket(p, q.id, 1))
    H.eq(StoryEngine.Trade.recentRequests("doc"), before2, "offers that were not picked do not count")
    H.eq(StoryEngine.Trade.recentRequests("ray"), 1, "the picked one counts")
end

return T
