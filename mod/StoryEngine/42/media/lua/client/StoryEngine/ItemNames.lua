-- 모드 아이템 이름 지키기 (2026-10-09 인게임: 레이네 스튜를 일부 먹자 이름이 "StoryEngine.Food_RayStew" 로 바뀜).
-- 바닐라 스크립트 Item.getDisplayName 은 표시 이름이 비어 있으면 전체 이름을 돌려준다 (jar). 먹은 뒤 다시 정하는 이름이
-- 이것을 쓰므로, 스크립트 표시 이름을 이 클라이언트 언어의 번역으로 채우고(스크립트의 DisplayName 은 영어 대비용),
-- 인벤토리에 이미 바뀐 이름(전체 이름·영어 대비 이름)이 있으면 번역 이름으로 되돌린다.

if isServer() then return end

require "StoryEngine/Core"

local log = StoryEngine.log

local ItemNames = { fixedScripts = false }
StoryEngine.ItemNames = ItemNames
ItemNames.MODULE = "StoryEngine"
ItemNames.SWEEP_TICKS = 120

-- StoryEngine 모듈 아이템: { 전체 이름 = { script, name(번역), fallback(스크립트 영어) } }
function ItemNames.collect()
    local out = {}
    local ok, list = pcall(function() return getScriptManager():getAllItems() end)
    if not ok or not list then return out end
    for i = 0, list:size() - 1 do
        local sc = list:get(i)
        local okN, ft = pcall(function() return sc:getFullName() end)
        if okN and ft and string.sub(ft, 1, #ItemNames.MODULE + 1) == ItemNames.MODULE .. "." then
            local name = getItemNameFromFullType(ft)
            out[ft] = { script = sc, name = name, fallback = sc:getDisplayName() }
        end
    end
    return out
end

function ItemNames.fixScripts()
    ItemNames.items = ItemNames.collect()
    local n = 0
    for ft, e in pairs(ItemNames.items) do
        if e.name and e.name ~= "" and e.name ~= ft then
            pcall(function() e.script:setDisplayName(e.name) end)
            n = n + 1
        end
    end
    ItemNames.fixedScripts = true
    log("item names set from translations", n)
end

-- 이 아이템의 이름이 잘못 바뀌었으면 번역 이름으로
function ItemNames.fixItem(item)
    local e = ItemNames.items and ItemNames.items[item:getFullType()]
    if not e or not e.name or e.name == "" then return false end
    local cur = item:getName()
    if cur == e.name then return false end
    if cur == item:getFullType() or (e.fallback and cur == e.fallback and e.fallback ~= e.name) then
        item:setName(e.name)
        return true
    end
    return false
end

local function sweep(container, depth)
    local items = container and container:getItems()
    for i = 0, (items and items:size() or 0) - 1 do
        local it = items:get(i)
        if it then
            if ItemNames.fixItem(it) then log("item name restored", it:getFullType()) end
            if depth < 2 and it.getInventory and it:getInventory() then sweep(it:getInventory(), depth + 1) end
        end
    end
end

ItemNames.tick = 0
Events.OnTick.Add(function()
    ItemNames.tick = ItemNames.tick + 1
    if ItemNames.tick % ItemNames.SWEEP_TICKS ~= 0 then return end
    local p = getPlayer()
    if not p then return end
    if not ItemNames.fixedScripts then pcall(ItemNames.fixScripts) end
    local ok, err = pcall(sweep, p:getInventory(), 0)
    if not ok then log("item name sweep error:", err) end
end)

return ItemNames
