-- 가까이 가면 퀘스트 물건이 든 보관함 오브젝트를 색으로 강조한다.
-- 같은 건물에 비슷한 선반이 여러 개 있어도 어느 것인지 바로 알 수 있게.

if isServer() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"

local QuestHighlight = {
    RANGE = 25,          -- 이 거리 안에 들어오면 강조
    EVERY = 30,          -- 틱마다 한 번 검사
    COLOR = { 1.0, 0.55, 0.1, 1.0 },
    lit = {},            -- 지금 강조 중인 오브젝트
    ticks = 0,
    asked = false,
}
StoryEngine.QuestHighlight = QuestHighlight

local ACTIVE = { offered = true, approached = true, entered = true }

local function setLit(obj, on)
    if on then
        obj:setHighlightColor(QuestHighlight.COLOR[1], QuestHighlight.COLOR[2], QuestHighlight.COLOR[3],
            QuestHighlight.COLOR[4])
        obj:setHighlighted(true, false)
    else
        obj:setHighlighted(false, false)
    end
end

-- 퀘스트 보관 칸에서 기록된 보관함과 같은 오브젝트들
local function targets(q, out)
    local sq = getCell():getGridSquare(q.sx, q.sy, q.sz or 0)
    if not sq then return end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local obj = objs:get(i)
        local match = false
        for ci = 0, obj:getContainerCount() - 1 do
            if obj:getContainerByIndex(ci):getType() == q.container then match = true end
        end
        if match and q.containerSprite then
            local sprite = obj:getSprite()
            match = sprite ~= nil and sprite:getName() == q.containerSprite
        end
        if match then out[#out + 1] = obj end
    end
end

function QuestHighlight.update()
    local player = getPlayer()
    if not player then return end
    local quests = StoryEngine.QuestMap and StoryEngine.QuestMap.quests or {}
    if not QuestHighlight.asked then
        QuestHighlight.asked = true
        StoryEngine.Net.toServer(player, "questList", {})
    end
    local want = {}
    for _, q in ipairs(quests) do
        if ACTIVE[q.state] and q.spawned and q.container and q.sx and q.sy then
            local dx, dy = q.sx - player:getX(), q.sy - player:getY()
            if dx * dx + dy * dy <= QuestHighlight.RANGE * QuestHighlight.RANGE then targets(q, want) end
        end
    end
    local keep = {}
    for _, obj in ipairs(want) do
        keep[obj] = true
        if not QuestHighlight.lit[obj] then setLit(obj, true) end
    end
    for obj, _ in pairs(QuestHighlight.lit) do
        if not keep[obj] then setLit(obj, false) end
    end
    QuestHighlight.lit = keep
end

Events.OnTick.Add(function()
    QuestHighlight.ticks = QuestHighlight.ticks + 1
    if QuestHighlight.ticks < QuestHighlight.EVERY then return end
    QuestHighlight.ticks = 0
    local ok, err = pcall(QuestHighlight.update)
    if not ok then StoryEngine.log("highlight failed:", err) end
end)

return QuestHighlight
