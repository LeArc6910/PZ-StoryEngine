-- 보급은 하나라도 가져가면 완료 (2026-10-06 사용자 요청), 찾아오기 꾸러미는 그대로 다 가져가야
local T = {}

function T.supply_drop_completes_when_anything_is_taken()
    H.addPlayer("tester", "Gerald", "Kar")
    local Q = StoryEngine.Quests
    local drop = { kind = "supply_drop", spawned = true, placed = { "Base.TinnedBeans", "Base.Bandage", "Base.Hammer" } }
    H.ok(not Q.takenEnough(drop, 3), "nothing taken yet")
    H.ok(Q.takenEnough(drop, 2), "one item taken is enough")
    H.ok(Q.takenEnough(drop, 0))
    H.ok(not Q.takenEnough(drop, nil), "square not loaded")
    H.ok(not Q.takenEnough({ kind = "supply_drop", spawned = false, placed = {} }, 0), "not placed yet")
    H.ok(not Q.takenEnough({ kind = "supply_drop", spawned = true }, 2), "old saves without the placed list: all of it")
    local fetch = { kind = "fetch", spawned = true, placed = { "StoryEngine.SealedParcel", "Base.Bandage" } }
    H.ok(not Q.takenEnough(fetch, 1), "fetch still needs everything")
    H.ok(Q.takenEnough(fetch, 0))
end

return T
