-- 감염 진단 키트 (2026-10-18): 쓰면 사라지고 감염 여부와 진행도를 알려 준다
local T = {}
local KIT = "StoryEngine.InfectionTestKit"

local function setup(infected, since, span)
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local body = p:getBodyDamage()
    function body:isInfected() return infected end
    function body:getInfectionTime() return since or 0 end
    function body:getInfectionMortalityDuration() return span or -1 end
    function p:getHoursSurvived() return 100 end
    return p
end

function T.kit_reads_infection_and_is_used_up()
    local p = setup(true, 70, 60)
    local kit = H.give(p, KIT)
    H.sent = {}
    StoryEngine.Commands.testKitUse(p, { id = kit:getID() })
    local r = H.sentOf("testKitResult")[1]
    H.ok(r and r.infected, "positive")
    H.eq(r.pct, 50, "30 of 60 hours")
    H.eq(#p.items, 0, "the kit is gone")
    -- 다 쓴 키트는 다시 못 씀
    H.sent = {}
    StoryEngine.Commands.testKitUse(p, { id = kit:getID() })
    H.eq(H.sentOf("testKitResult")[1].error, "missing")
end

function T.kit_on_a_healthy_body_is_negative()
    local p = setup(false)
    local kit = H.give(p, KIT)
    H.sent = {}
    StoryEngine.Commands.testKitUse(p, { id = kit:getID() })
    local r = H.sentOf("testKitResult")[1]
    H.ok(r and not r.infected and not r.error)
    H.eq(#p.items, 0)
    H.eq(StoryEngine.Value.of(KIT), 10, "worth 10")
end

function T.other_items_are_not_a_kit()
    local p = setup(true, 70, 60)
    local bandage = H.give(p, "Base.Bandage")
    H.sent = {}
    StoryEngine.Commands.testKitUse(p, { id = bandage:getID() })
    H.eq(H.sentOf("testKitResult")[1].error, "missing")
    H.eq(#p.items, 1, "nothing taken")
end

return T
