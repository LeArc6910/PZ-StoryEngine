-- 월드 지도(M) 마커.
--
-- symbolsAPI:addTexture 로 추가한 심볼은 플레이어 지도에 저장된다. 그래서 지도를 열 때마다
-- 우리가 찍었던 자리(진행 중 + 최근 끝난 퀘스트 위치)의 마커를 지우고, 진행 중인 퀘스트만 다시 찍는다.

if isServer() then return end

require "ISUI/Maps/ISMap"
require "ISUI/Maps/ISWorldMap"
require "StoryEngine/Core"
require "StoryEngine/Net"

local QuestMap = {
    quests = {},        -- 서버에서 받은 최근 목록
}
StoryEngine.QuestMap = QuestMap

QuestMap.SYMBOL = "Exclamation"
QuestMap.COLOR = { 1.0, 0.55, 0.1 }

local ACTIVE = { offered = true, approached = true, entered = true, retrieved = true, accepted = true }

-- 보관 위치를 알면 그 칸, 아직 생성 전이면 건물 중심
function QuestMap.markerPos(q)
    if q.spawned and q.sx and q.sy then return q.sx + 0.5, q.sy + 0.5 end
    return q.x + 0.5, q.y + 0.5
end

local function near(a, b)
    return math.abs(a - b) < 0.05
end

function QuestMap.sync()
    local map = ISWorldMap_instance
    if not map or not map.mapAPI then return end
    local api = map.mapAPI:getSymbolsAPIv2()

    local known = {}
    for _, q in ipairs(QuestMap.quests) do
        if q.x and q.y then known[#known + 1] = { q.x + 0.5, q.y + 0.5 } end
        if q.sx and q.sy then known[#known + 1] = { q.sx + 0.5, q.sy + 0.5 } end
    end
    for i = api:getSymbolCount() - 1, 0, -1 do
        local sym = api:getSymbolByIndex(i)
        if sym:isTexture() and sym:getSymbolID() == QuestMap.SYMBOL then
            local sx, sy = sym:getWorldX(), sym:getWorldY()
            for _, k in ipairs(known) do
                if near(sx, k[1]) and near(sy, k[2]) then
                    api:removeSymbolByIndex(i)
                    break
                end
            end
        end
    end

    for _, q in ipairs(QuestMap.quests) do
        if ACTIVE[q.state] and q.x and q.y then
            local x, y = QuestMap.markerPos(q)
            local s = api:addTexture(QuestMap.SYMBOL, x, y)
            s:setRGBA(QuestMap.COLOR[1], QuestMap.COLOR[2], QuestMap.COLOR[3], 1.0)
            s:setAnchor(0.5, 0.5)
            s:setScale(ISMap.SCALE)
        end
    end
end

function QuestMap.setQuests(quests)
    QuestMap.quests = quests or {}
    if ISWorldMap_instance and ISWorldMap_instance:isVisible() then
        local ok, err = pcall(QuestMap.sync)
        if not ok then StoryEngine.log("map sync failed:", err) end
    end
end

-- 지도를 열 때마다 마커를 맞추고, 최신 목록을 받아 한 번 더 맞춘다.
local originalShow = ISWorldMap.ShowWorldMap
ISWorldMap.ShowWorldMap = function(playerNum, centerX, centerY, zoom)
    originalShow(playerNum, centerX, centerY, zoom)
    local ok, err = pcall(QuestMap.sync)
    if not ok then StoryEngine.log("map sync failed:", err) end
    local player = getSpecificPlayer(playerNum or 0)
    if player then StoryEngine.Net.toServer(player, "questList", {}) end
end

return QuestMap
