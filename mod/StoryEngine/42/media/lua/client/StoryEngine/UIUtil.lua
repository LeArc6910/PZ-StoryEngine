-- 클라이언트 UI 공용 도우미. 문자열은 모두 번역 파일(getText)에서 가져온다 (Lua 소스에 비 ASCII 금지).

if isServer() then return end

require "StoryEngine/Core"

local UI = {}
StoryEngine.UI = UI

-- ISRichTextPanel 서식 태그 문자를 막고 줄바꿈을 <LINE> 으로 바꾼다.
function UI.escape(text)
    text = tostring(text or "")
    text = string.gsub(text, "<", "(")
    text = string.gsub(text, ">", ")")
    text = string.gsub(text, "\r", "")
    text = string.gsub(text, "\n", " <LINE> ")
    return text
end

-- 지도 기준 방위 (y 가 커질수록 남쪽)
function UI.direction(dx, dy)
    local angle = math.atan2(dy, dx) * 180 / math.pi   -- 0 = 동, 90 = 남
    local names = { "E", "SE", "S", "SW", "W", "NW", "N", "NE" }
    local idx = math.floor(((angle + 360 + 22.5) % 360) / 45) + 1
    return getText("IGUI_StoryEngine_Dir_" .. names[idx])
end

-- 바닐라 지도 번역으로 마을 이름 (예: MapLabel_EchoCreek)
function UI.townName(town)
    if not town then return "?" end
    local key = "MapLabel_" .. string.gsub(town, " ", "")
    local t = getText(key)
    return (t and t ~= key) and t or town
end

-- 보관함 종류 이름 (바닐라 IGUI_ContainerTitle_<type>)
function UI.containerName(ctype)
    local key = "IGUI_ContainerTitle_" .. tostring(ctype)
    local t = getText(key)
    return (t and t ~= key) and t or tostring(ctype)
end

-- { "Base.Bandage", "Base.Bandage", ... } -> "붕대 x2, ..."
function UI.itemList(fullTypes)
    local order, counts = {}, {}
    for _, ft in ipairs(fullTypes or {}) do
        if not counts[ft] then
            counts[ft] = 0
            order[#order + 1] = ft
        end
        counts[ft] = counts[ft] + 1
    end
    local parts = {}
    for _, ft in ipairs(order) do
        local name = getItemNameFromFullType(ft) or ft
        parts[#parts + 1] = counts[ft] > 1 and (name .. " x" .. StoryEngine.intToString(counts[ft])) or name
    end
    return table.concat(parts, ", ")
end

-- 가지고 있는 개수 (가방 속까지, 퀘스트 태그가 붙은 것은 빼고)
function UI.countHeld(player, fullType)
    if not player then return 0 end
    local list = player:getInventory():getAllTypeRecurse(fullType)
    local n = 0
    for i = 0, list:size() - 1 do
        local mod = list:get(i):getModData()
        if not (mod and mod.storyQuest) then n = n + 1 end
    end
    return n
end

-- 부탁 물건 { { type, count }, ... } -> "진통제 x2, 붕대 x3"
function UI.needText(need)
    local parts = {}
    for _, n in ipairs(need or {}) do
        local name = getItemNameFromFullType(n[1]) or n[1]
        parts[#parts + 1] = (n[2] or 1) > 1 and (name .. " x" .. StoryEngine.intToString(n[2])) or name
    end
    return table.concat(parts, ", ")
end

-- 서버가 보낸 번역 문장을 이 클라이언트의 언어로 만든다.
-- 멀티 서버는 모드 번역(IG_UI)을 getText 로 찾지 못하고(42.20.4 인게임 호스트 확인), 서버 언어와 플레이어 언어도
-- 다를 수 있어서 서버는 키와 인자만 보낸다.
-- lt = { key, alt = 키가 없을 때 쓸 키, args = { { t = "town"|"dir"|"item"|"need"|"num"|"npc"|"key"|"s", v = ... }, ... } }
--   npc = NPC 이름 (괄호 속 거점 이름 뺌), key = 다른 번역 문장
function UI.npcName(fid)
    local name = StoryEngine.Factions.name(fid)
    name = string.gsub(name, "%s*%(.*%)%s*$", "")
    return name
end

function UI.render(lt)
    if type(lt) ~= "table" or not lt.key then return "" end
    local key = lt.key
    if lt.alt and not getTextOrNull(key) then key = lt.alt end
    local a = {}
    for i, arg in ipairs(lt.args or {}) do
        local t, v = arg.t, arg.v
        if t == "town" then
            a[i] = UI.townName(v)
        elseif t == "dir" then
            a[i] = getText("IGUI_StoryEngine_Dir_" .. tostring(v))
        elseif t == "item" then
            a[i] = getItemNameFromFullType(v) or tostring(v)
        elseif t == "need" then
            a[i] = UI.needText(v)
        elseif t == "num" then
            a[i] = StoryEngine.intToString(tonumber(v) or 0)
        elseif t == "npc" then
            a[i] = UI.npcName(v)
        elseif t == "key" then
            a[i] = getText(tostring(v))
        else
            a[i] = tostring(v or "")
        end
    end
    local n = #a
    if n == 0 then return getText(key) end
    if n == 1 then return getText(key, a[1]) end
    if n == 2 then return getText(key, a[1], a[2]) end
    if n == 3 then return getText(key, a[1], a[2], a[3]) end
    return getText(key, a[1], a[2], a[3], a[4])
end

-- 메시지·일지 항목의 표시 문장: 번역 문장이 있으면 그것, 없으면 text
function UI.textOf(entry)
    if type(entry) ~= "table" then return "" end
    -- 여러 문장 (AI 없이 쓴 일기, Journal.fallbackText): 문단마다 줄을 바꾼다
    if type(entry.lts) == "table" then
        local parts = {}
        for _, lt in ipairs(entry.lts) do
            local s = UI.render(lt)
            if s ~= "" then parts[#parts + 1] = s end
        end
        return table.concat(parts, " ")
    end
    if entry.lt then return UI.render(entry.lt) end
    return tostring(entry.text or "")
end

-- 이 클라이언트의 게임 언어 코드 (KO, EN, ...)
function UI.lang()
    local ok, name = pcall(function() return tostring(Translator.getLanguage():name()) end)
    return ok and name or "EN"
end

function UI.distanceText(player, x, y)
    local dx, dy = x - player:getX(), y - player:getY()
    local distance = math.floor(math.sqrt(dx * dx + dy * dy) / 10) * 10
    return UI.direction(dx, dy), StoryEngine.intToString(distance)
end

return UI
