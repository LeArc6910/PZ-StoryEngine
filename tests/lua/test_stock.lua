-- 거래 재고 (2026-10-04): NPC 마다 품목·등급별 묶음 재고, 3일마다 입고, 거래가 끝난 묶음은 품절
local T = {}

-- 플레이어(10000,10000) 둘레에 건물 고리 (등급 1·2 거리)
local function mockBuildings()
    local defs = {}
    for _, d in ipairs({ 120, 160, 300, 380 }) do
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

local function setup(trust)
    mockBuildings()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    SandboxVars.StoryEngine.ModItemsRatio = 0
    StoryEngine.Life.daily()
    StoryEngine.Trade.FREE_CHANCE = 0
    StoryEngine.Radio.channel("doc").trust = trust or 65
    return p, ps
end

local function quest(id) return StoryEngine.Store.data().quests[id] end

function T.stock_is_kept_for_three_days_then_restocked()
    setup()
    local Trade = StoryEngine.Trade
    local st = Trade.stock("doc")
    H.ok(st.cats.medical and #st.cats.medical[2] >= 1 and #st.cats.medical[2] <= Trade.STOCK_BUNDLES, "bundles per tier")
    local seq = st.seq
    H.advanceDays(1)
    H.eq(Trade.stock("doc").seq, seq, "same stock the next day")
    H.ok(Trade.restockIn("doc") >= 1)
    H.advanceDays(Trade.STOCK_DAYS)
    H.eq(Trade.stock("doc").seq, seq + 1, "new stock after the restock days")
end

function T.list_window_shows_the_stock()
    local p, ps = setup()
    local Trade = StoryEngine.Trade
    local opts = Trade.options("doc", ps)
    H.ok(opts.restockIn and opts.restockIn >= 1, "restock countdown")
    local med
    for _, it in ipairs(opts.items) do if it.category == "medical" then med = it end end
    local st = Trade.stock("doc")
    H.eq(#med.tiers[2], #st.cats.medical[2], "the list is the stock")
    local listed = 0
    for _, e in ipairs(med.tiers[2][1].items) do listed = listed + e[2] end
    H.eq(listed, #st.cats.medical[2][1].goods)
end

function T.traded_bundle_is_sold_out_until_restock()
    local p, ps = setup()
    local Trade, Quests = StoryEngine.Trade, StoryEngine.Quests
    H.ok(Trade.ask(p, "doc", "medical", 2, 1))
    local q = Quests.openTrade("doc")
    H.ok(q.stockRef and q.stockRef.index == 1, "deal remembers its bundle")
    Quests.completeTrade(p, q)
    H.ok(Trade.stock("doc").cats.medical[2][1].sold, "sold out")
    local med
    for _, it in ipairs(Trade.options("doc", ps).items) do if it.category == "medical" then med = it end end
    H.ok(med.tiers[2][1].sold, "shown as sold out")
    -- 같은 묶음을 다시 청하면 품절 안내 (앞 무전 반응이 끝난 뒤)
    StoryEngine.Radio.busy = {}
    H.ok(Trade.ask(p, "doc", "medical", 2, 1))
    H.ok(Quests.openTrade("doc") == nil, "no deal for a sold-out bundle")
    local blocked
    for _, m in ipairs(StoryEngine.Radio.channel("doc").messages) do if m.blocked then blocked = m.blocked end end
    H.ok(blocked and blocked.soldOut and blocked.restock >= 1, "sold-out line")
    -- 입고 뒤에는 다시
    H.advanceDays(Trade.STOCK_DAYS)
    H.ok(not Trade.stock("doc").cats.medical[2][1].sold, "fresh stock")
end

function T.random_request_takes_what_is_left()
    local p, ps = setup()
    local Trade = StoryEngine.Trade
    local list = Trade.stock("doc").cats.medical[1]
    for i = 2, #list do list[i].sold = true end
    local goods, ref = Trade.roll("medical", 1, "doc")
    H.eq(ref.index, 1, "only the unsold bundle")
    list[1].sold = true
    local none, why = Trade.roll("medical", 1, "doc")
    H.ok(none == nil and why == "sold_out")
end

function T.credit_marks_the_bundle_sold_right_away()
    local p, ps = setup(70)
    local Trade = StoryEngine.Trade
    H.ok(Trade.ask(p, "doc", "medical", 2, 2))
    local q = StoryEngine.Quests.openTrade("doc")
    H.ok(StoryEngine.Work.choose(p, q.id, "credit"))
    H.ok(Trade.stock("doc").cats.medical[2][2].sold, "goods already handed over")
end

return T
