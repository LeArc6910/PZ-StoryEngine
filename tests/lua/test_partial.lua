-- 나눠 내기 (2026-10-08 사용자 요청): 거래 대가·부탁 물건을 여러 번에 걸쳐 낸다.
-- 기한까지 다 못 채우면 "낸 만큼 반영": 거래는 낸 비율만큼 물건을 줄여 받고, 신뢰도 감점·NPC 형편은 낸 비율만큼 덜
local T = {}

local function mockBuildings()
    local defs = {}
    for _, d in ipairs({ 120, 160, 300, 380, 600, 700 }) do
        for i = 0, 7 do
            local a = i * math.pi / 4
            local x, y = math.floor(10000 + math.cos(a) * d), math.floor(10000 + math.sin(a) * d)
            local room = {}
            function room:getZ() return 0 end
            function room:getArea() return 100 end
            function room:getX() return x end
            function room:getY() return y end
            function room:getX2() return x + 9 end
            function room:getY2() return y + 9 end
            function room:getName() return "office" end
            local def = {}
            function def:getX() return x end
            function def:getY() return y end
            function def:getX2() return x + 9 end
            function def:getY2() return y + 9 end
            function def:getRooms() return H.list({ room }) end
            function def:isResidential() return false end
            defs[#defs + 1] = def
        end
    end
    ArrayList = { new = function() return H.list({}) end }
    local grid = {}
    function grid:getBuildingsIntersecting(x, y, w, h, list)
        for _, def in ipairs(defs) do
            if def:getX2() >= x and def:getX() <= x + w and def:getY2() >= y and def:getY() <= y + h then
                list.items[#list.items + 1] = def
            end
        end
    end
    function grid:getBuildingAt() return nil end
    local world = {}
    function world:getMetaGrid() return grid end
    getWorld = function() return world end
end

local function setup()
    mockBuildings()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    SandboxVars.StoryEngine.ModItemsRatio = 0
    SandboxVars.StoryEngine.RequestPointsMult = 1
    SandboxVars.StoryEngine.RequestMinTier = 1
    StoryEngine.Life.daily()
    StoryEngine.Trade.FREE_CHANCE = 0
    H.defineItem("Base.TinnedBeans", "food", 1.5)
    H.defineItem("Base.Bandage", "medical", 3)
    return p, ps
end

local function trade(p, ps)
    StoryEngine.Radio.channel("ray").trust = 65
    local q = StoryEngine.Trade.fromReply("ray", ps, { action = "offer", category = "medical", tier = 2, pay_category = "food" })
    H.ok(q and q.state == "proposed", "offer made")
    H.ok(StoryEngine.Quests.respond(p, q.id, true))
    return q
end

local function beans(p, n)
    local ids = {}
    for _ = 1, n do ids[#ids + 1] = H.give(p, "Base.TinnedBeans"):getID() end
    return ids
end

local function count(p, ft)
    local n = 0
    for _, it in ipairs(p.items) do if it.fullType == ft then n = n + 1 end end
    return n
end

local function deliveriesFor(qid)
    local out = {}
    for _, d in pairs(StoryEngine.Store.data().quests) do
        if d.kind == "supply_drop" and d.origin and d.origin.rewardFor == qid then out[#out + 1] = d end
    end
    return out
end

function T.trade_is_paid_in_parts()
    local p, ps = setup()
    local q = trade(p, ps)
    local half = math.floor(q.price / 1.5 / 2)
    local ok, _, partial = StoryEngine.Trade.pay(p, q.id, beans(p, half))
    H.ok(ok and partial == "partial", "a part of the price")
    H.eq(q.state, "accepted")
    H.eq(q.paid, half * 1.5)
    H.eq(#deliveriesFor(q.id), 0, "no goods yet")
    -- 남은 값보다 많이 골라도 남은 값까지만 가져간다
    local more = beans(p, 40)
    H.ok(StoryEngine.Trade.pay(p, q.id, more))
    H.eq(q.state, "completed")
    H.eq(#deliveriesFor(q.id), 1, "goods sent once")
    local left = math.ceil((q.price - half * 1.5) / 1.5 - 0.0001)
    H.eq(count(p, "Base.TinnedBeans"), 40 - left, "only the rest of the price was taken")
    H.ok(q.payers and q.payers["Gerald Kar"], "who paid is kept")
end

function T.unfinished_trade_sends_goods_for_what_was_paid()
    local p, ps = setup()
    local q = trade(p, ps)
    local before = StoryEngine.Radio.channel("ray").trust
    local most = math.floor(q.price * 0.8 / 1.5)
    H.ok(StoryEngine.Trade.pay(p, q.id, beans(p, most)))
    q.deadlineT = 0
    StoryEngine.Quests.track({}, StoryEngine.Sensor.now())
    H.eq(q.state, "failed")
    H.ok(StoryEngine.Quests.paidShare(q) >= 0.7, "most of it was paid")
    H.eq(StoryEngine.Radio.channel("ray").trust, before, "the small unpaid share is forgiven")
    local d = deliveriesFor(q.id)
    H.eq(#d, 1, "goods for what was paid (a one-item bundle paid 80% rounds up)")
    H.ok(#(q.goodsKept or {}) >= 1 and #q.goodsKept <= #q.goods, "trimmed to the paid share")
end

function T.trade_paid_under_half_of_a_single_item_gets_nothing()
    local p, ps = setup()
    local q = trade(p, ps)
    q.goods = { "Base.Antibiotics" }
    H.ok(StoryEngine.Trade.pay(p, q.id, beans(p, 2)))
    q.deadlineT = 0
    StoryEngine.Quests.track({}, StoryEngine.Sensor.now())
    H.eq(q.state, "failed")
    H.eq(#deliveriesFor(q.id), 0, "less than half of one item")
    H.eq(#(q.goodsKept or {}), 0)
end

function T.partly_paid_trade_can_only_switch_to_credit()
    local p, ps = setup()
    local q = trade(p, ps)
    H.ok(StoryEngine.Trade.pay(p, q.id, beans(p, 1)))
    local ok, why = StoryEngine.Work.check("ray", "labor", q)
    H.eq(ok, false)
    H.eq(why, "paid")
    H.ok(StoryEngine.Work.check("ray", "credit", q), "credit for the rest is fine")
    local paid, price = q.paid, q.price
    H.ok(StoryEngine.Work.choose(p, q.id, "credit"))
    H.eq(q.price, paid + math.ceil((price - paid) * StoryEngine.Work.CREDIT_INTEREST), "interest only on the rest")
end

function T.request_items_are_sent_in_parts()
    local p, ps = setup()
    local q = StoryEngine.Quests.proposeCustom(p, ps, "doc", { tier = 1, why = "patients", items = { { "Base.Bandage", 4 } } },
        StoryEngine.Sensor.now(), { silent = true })
    q.state = "accepted"
    q.need = { { "Base.Bandage", 4 } }          -- 정해진 물건 방식으로 (점수 아님)
    H.give(p, "Base.Bandage")
    local ok, _, partial = StoryEngine.Quests.submit(p, q.id)
    H.ok(ok and partial == "partial")
    H.eq(q.got["Base.Bandage"], 1)
    H.eq(q.givers["Gerald Kar"], 1)
    for _ = 1, 5 do H.give(p, "Base.Bandage") end
    H.ok(StoryEngine.Quests.submit(p, q.id))
    H.eq(q.state, "completed")
    H.eq(count(p, "Base.Bandage"), 2, "only the 3 still needed were taken")
end

function T.half_done_request_loses_less_trust()
    local p, ps = setup()
    local function failed(sent)
        StoryEngine.Radio.channel("doc").trust = 50
        local q = StoryEngine.Quests.proposeCustom(p, ps, "doc", { tier = 1, why = "patients", items = { { "Base.Bandage", 4 } } },
            StoryEngine.Sensor.now(), { silent = true })
        q.state = "accepted"
        q.need = { { "Base.Bandage", 4 } }
        for _ = 1, sent do H.give(p, "Base.Bandage") end
        if sent > 0 then H.ok(StoryEngine.Quests.submit(p, q.id)) end
        q.deadlineT = 0
        StoryEngine.Quests.track({}, StoryEngine.Sensor.now())
        H.eq(q.state, "failed")
        return 50 - StoryEngine.Radio.channel("doc").trust
    end
    local full = failed(0)
    local half = failed(2)
    H.ok(full > 0, "an unpaid failure costs trust")
    H.ok(half < full, "half sent costs less: " .. tostring(half) .. " < " .. tostring(full))
end

return T
