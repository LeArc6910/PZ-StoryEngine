-- 퀘스트 표시(modData.storyQuest) 이어 붙이기 (2026-10-03 점검).
-- 거래로 받은 물건은 표시가 남아 다시 거래 대가로 낼 수 없다 (싸게 사서 되파는 반복 방지, Value.payable).
-- 상자를 풀거나(탄약 상자 -> 낱발) 다시 담으면 새 아이템이 생겨 표시가 사라지므로, 손 제작(ISHandcraftAction)이
-- 결과물을 만들 때 소모된 재료에 표시가 있었으면 같은 표시를 결과물에도 붙인다.
-- performRecipe 는 싱글과 멀티 서버에서만 불린다 (멀티 클라이언트는 서버 결과를 받는다).

require "StoryEngine/Core"

local QuestTags = {}
StoryEngine.QuestTags = QuestTags

-- 소모된 재료 중 처음 보이는 퀘스트 표시
function QuestTags.fromConsumed(recipeData)
    local tag = nil
    pcall(function()
        local used = recipeData:getAllConsumedItems()
        for i = 0, used:size() - 1 do
            local mod = used:get(i):getModData()
            if mod and mod.storyQuest then
                tag = mod.storyQuest
                break
            end
        end
    end)
    return tag
end

function QuestTags.apply(character, items, tag)
    if not tag or not items then return 0 end
    local n = 0
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        local mod = item and item:getModData()
        if mod and not mod.storyQuest then
            mod.storyQuest = tag
            n = n + 1
            if syncItemModData and character then pcall(syncItemModData, character, item) end
        end
    end
    return n
end

function QuestTags.install()
    if not ISHandcraftAction or ISHandcraftAction.__storyTags then return end
    local original = ISHandcraftAction.performRecipe
    if type(original) ~= "function" then return end
    ISHandcraftAction.__storyTags = true
    ISHandcraftAction.performRecipe = function(self, ...)
        -- 재료는 레시피가 끝나면 사라지므로 먼저 표시를 읽어 둔다
        local tag = nil
        pcall(function()
            if self.logic and self.logic:getRecipeData() then tag = QuestTags.fromConsumed(self.logic:getRecipeData()) end
        end)
        local result = original(self, ...)
        if tag then
            pcall(function()
                local items = ArrayList.new()
                self.logic:getCreatedOutputItems(items)
                local n = QuestTags.apply(self.character, items, tag)
                if n > 0 then StoryEngine.log("quest tag carried to", n, "crafted items", tag) end
            end)
        end
        return result
    end
end

QuestTags.install()
if Events and Events.OnGameStart then Events.OnGameStart.Add(QuestTags.install) end
if Events and Events.OnServerStarted then Events.OnServerStarted.Add(QuestTags.install) end

return QuestTags
