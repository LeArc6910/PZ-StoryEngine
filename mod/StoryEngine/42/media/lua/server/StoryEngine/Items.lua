-- 서버 측 아이템 넣기·빼기 (서버 측 전용).
--
-- 멀티에서는 서버가 보관함·인벤토리를 바꾼 뒤 클라이언트에 알려야 한다. 바닐라 B42 서버 코드
-- (server/ClientCommands.lua, BuildingObjects/ISBuildUtil.lua)와 같은 순서: 바꾸고 -> send...
-- ItemContainer:removeItemOnServer 는 클라이언트에서 서버로 보내는 함수라 서버에서는 아무 일도 하지 않는다 (jar 확인).
-- 싱글에서도 send... 는 안전하다 (바닐라 서버 파일이 싱글에서도 그대로 부른다).

if isClient() then return end

require "StoryEngine/Core"

local Items = {}
StoryEngine.Items = Items

-- 보관함에 새 아이템을 넣는다. tag 가 있으면 클라이언트에 알리기 전에 modData.storyQuest 로 붙인다.
function Items.addTo(container, fullType, tag)
    local item = container:AddItem(fullType)
    if not item then return nil end
    if tag then item:getModData().storyQuest = tag end
    sendAddItemToContainer(container, item)
    return item
end

-- 아이템을 들어 있는 곳(보관함, 인벤토리, 가방)에서 뺀다. player 를 주면 손에 든 것은 먼저 내려놓는다.
function Items.remove(item, player)
    if player and player:isEquipped(item) then player:removeFromHands(item) end
    local container = item:getContainer()
    if not container then return false end
    container:Remove(item)
    sendRemoveItemFromContainer(container, item)
    return true
end

return Items
