-- 월드 지도의 퀘스트 느낌표 (QuestMap.lua): 끝난 퀘스트의 표시가 남지 않는지
local T = { __client = true }

-- 가짜 지도: 심볼 목록 하나 (0부터 세는 바닐라 API 모양)
local function fakeMap()
    local list = {}
    local api = {}
    function api:getSymbolCount() return #list end
    function api:getSymbolByIndex(i) return list[i + 1] end
    function api:removeSymbolByIndex(i) table.remove(list, i + 1) end
    function api:addTexture(id, x, y)
        local s = { id = id, x = x, y = y, r = 0, g = 0, b = 0 }
        function s:isTexture() return true end
        function s:getSymbolID() return self.id end
        function s:getWorldX() return self.x end
        function s:getWorldY() return self.y end
        function s:getRed() return self.r end
        function s:getGreen() return self.g end
        function s:getBlue() return self.b end
        -- 저장된 색은 1/255 단위
        function s:setRGBA(r, g, b)
            self.r, self.g, self.b = math.floor(r * 255) / 255, math.floor(g * 255) / 255, math.floor(b * 255) / 255
        end
        function s:setAnchor() end
        function s:setScale() end
        list[#list + 1] = s
        return s
    end
    ISWorldMap_instance = { mapAPI = { getSymbolsAPIv2 = function() return api end }, isVisible = function() return true end }
    return api, list
end

local function at(list, x, y)
    for _, s in ipairs(list) do
        if math.abs(s.x - (x + 0.5)) < 0.05 and math.abs(s.y - (y + 0.5)) < 0.05 then return s end
    end
    return nil
end

function T.finished_quests_lose_their_marker()
    H.addPlayer("tester", "Gerald", "Kar")
    local QM = StoryEngine.QuestMap
    local api, list = fakeMap()
    QM.setQuests({ { id = "Q1", state = "accepted", x = 100, y = 200 }, { id = "Q2", state = "offered", x = 300, y = 400 } })
    H.eq(#list, 2)
    -- 끝나면 지워진다
    QM.setQuests({ { id = "Q1", state = "completed", x = 100, y = 200 }, { id = "Q2", state = "offered", x = 300, y = 400 } })
    H.eq(#list, 1)
    H.ok(at(list, 300, 400), "the open quest keeps its marker")
    ISWorldMap_instance = nil
end

function T.markers_go_even_when_the_quest_is_no_longer_listed()
    H.addPlayer("tester", "Gerald", "Kar")
    local QM = StoryEngine.QuestMap
    local api, list = fakeMap()
    QM.setQuests({ { id = "Q1", state = "accepted", x = 100, y = 200 } })
    H.eq(#list, 1)
    -- 끝난 지 오래돼 서버 목록(최근 20개)에서 밀려난 퀘스트
    QM.setQuests({})
    H.eq(#list, 0)
    -- 자리가 옮겨진 퀘스트 (아는 얼굴의 좀비, 정찰 다음 지점): 예전 자리에 남지 않는다
    QM.setQuests({ { id = "Q2", state = "accepted", x = 10, y = 10, spawned = true, sx = 12, sy = 14 } })
    QM.setQuests({ { id = "Q2", state = "accepted", x = 10, y = 10, spawned = true, sx = 40, sy = 44 } })
    H.eq(#list, 1)
    H.ok(at(list, 40, 44) and not at(list, 12, 14), "only the new spot is marked")
    ISWorldMap_instance = nil
end

function T.the_players_own_symbols_stay()
    H.addPlayer("tester", "Gerald", "Kar")
    local QM = StoryEngine.QuestMap
    local api, list = fakeMap()
    -- 플레이어가 빨간 펜으로 찍은 느낌표, 다른 모양 심볼
    api:addTexture("Exclamation", 50.5, 60.5):setRGBA(0.65, 0.054, 0.054, 1)
    api:addTexture("Skull", 70.5, 80.5):setRGBA(1.0, 0.55, 0.1, 1)
    QM.setScout({ { x = 500, y = 500, kind = "horde" } })
    QM.setQuests({ { id = "Q1", state = "accepted", x = 100, y = 200 } })
    H.eq(#list, 4)
    QM.setScout({})
    QM.setQuests({})
    H.eq(#list, 2)
    H.ok(at(list, 50, 60) and at(list, 70, 80), "hand-drawn symbols are left alone")
    ISWorldMap_instance = nil
end

return T
