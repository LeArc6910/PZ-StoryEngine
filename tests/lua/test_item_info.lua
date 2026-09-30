-- 아이템 툴팁 정보 (Value.summary, Value.WANTS) - 2026-09-30
local T = {}

function T.summary_trade_donation_and_wants()
    local V = StoryEngine.Value
    H.defineItem("Base.Hammer", "tools", 8)
    H.defineItem("Base.TinnedBeans", "food", 1.5)
    H.defineItem("Base.CigarettePack", "misc", 0.2)
    H.defineItem("Base.Rock", "misc", 0.2)
    local s = V.summary(H.newItem("Base.Hammer"))
    H.eq(s.category, "tools")
    H.eq(s.value, 8)
    H.eq(s.resource, "safety", "tools fill the weapons bar")
    H.eq(table.concat(s.wanted, ","), "ray,doc,pike,guard,rats,hunter")
    local beans = V.summary(H.newItem("Base.TinnedBeans", { classes = { "Food" }, rotten = true }))
    H.eq(beans.resource, "food")
    H.ok(beans.rotten, "rotten food is flagged")
    local cig = V.summary(H.newItem("Base.CigarettePack"))
    H.eq(cig.category, nil, "not a trade good")
    H.eq(cig.resource, "morale", "comforts donation")
    H.eq(V.summary(H.newItem("Base.Rock")), nil, "nothing to show")
    H.ok(V.summary(H.newItem("Base.Hammer", { questTag = "Q1" })).quest)
    -- 거래 규칙도 같은 표
    H.eq(StoryEngine.Trade.FACTIONS.rats.wants, V.WANTS.rats)
    H.eq(StoryEngine.Trade.FACTIONS.pike.priceMult, 0.8, "other trade rules kept")
end

return T
