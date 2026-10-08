-- 클라이언트 UI 공용 도우미. 문자열은 모두 번역 파일(getText)에서 가져온다 (Lua 소스에 비 ASCII 금지).

if isServer() then return end

require "StoryEngine/Core"
require "StoryEngine/Lines"

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

-- 공용 주파수에 한 말의 종류 (도움·거래·감사·소식·인사). 이 클라이언트 언어의 낱말(IGUI_StoryEngine_Intent_<종류>,
-- 쉼표로 나눔)과 영어 낱말로 고른다. 서버는 AI 가 없을 때 이것으로 준비된 대답을 고른다
local intentWords = nil
function UI.intentOf(text)
    if not intentWords then
        intentWords = {}
        for kind, _ in pairs(StoryEngine.Lines.INTENT_KINDS) do
            local key = "IGUI_StoryEngine_Intent_" .. kind
            local raw = getText(key)
            local list = {}
            if raw and raw ~= key then
                for w in string.gmatch(raw, "[^,]+") do
                    local t = string.gsub(w, "^%s+", "")
                    t = string.gsub(t, "%s+$", "")
                    if t ~= "" then list[#list + 1] = t end
                end
            end
            intentWords[kind] = list
        end
    end
    return StoryEngine.Lines.intentOf(text, intentWords)
end

-- 가지고 있는 개수 (가방 속까지, 퀘스트 태그가 붙은 것은 빼고)
-- 품목 점수 부탁 항목 ("cat:food", 점수) 이면 품목 이름, 아니면 nil (서버 Quests.pointCat 와 같음)
function UI.pointCat(entry)
    local s = type(entry) == "table" and entry[1] or entry
    if type(s) ~= "string" or string.sub(s, 1, 4) ~= "cat:" then return nil end
    return string.sub(s, 5)
end

-- 부탁 항목에서 아직 남은 양 (나눠 낸 q.got 을 뺀 것, 서버 Quests.needLeft 와 같음)
function UI.needLeft(q, n)
    return math.max(0, (n[2] or 1) - ((q.got or {})[n[1]] or 0))
end

-- 그 품목으로 낼 수 있는 물건의 점수 합 (Value.pointPayable, 등급 하한 minTier)
function UI.pointsHeld(player, cat, minTier)
    if not player or not StoryEngine.Value then return 0 end
    local total = 0
    for _, it in ipairs(StoryEngine.Value.pointItems(player, cat, minTier)) do total = total + StoryEngine.Value.pointValue(it) end
    return total
end

-- 품목 점수 문장 ("음식 아무거나 가치 5", 등급 하한이 있으면 "(3등급 이상)")
function UI.pointText(cat, points, minTier)
    local text = getText("IGUI_StoryEngine_Need_Points", getText("IGUI_StoryEngine_Cat_" .. tostring(cat)),
        StoryEngine.intToString(points or 1))
    if minTier and minTier > 1 then
        text = text .. " " .. getText("IGUI_StoryEngine_Need_MinTier", StoryEngine.intToString(minTier))
    end
    return text
end

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
        local cat = UI.pointCat(n)
        if cat then
            parts[#parts + 1] = UI.pointText(cat, n[2], n[3])
        else
            local name = getItemNameFromFullType(n[1]) or n[1]
            parts[#parts + 1] = (n[2] or 1) > 1 and (name .. " x" .. StoryEngine.intToString(n[2])) or name
        end
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

-- ---------------------------------------------------------------- 개인 신뢰 (2026-10-09, docs/DESIGN_PER_PLAYER_TRUST.md 9절)
-- 멀티 + 샌드박스 TrustBenefits = 2 일 때만 서버가 personal(보는 사람의 개인 신뢰)을 함께 보낸다.
-- entry: 채널(channelList)·거점(lifeList)·인물 항목처럼 trust = 무리 신뢰, personal = 내 신뢰인 표.
-- 내 신뢰, 무리 신뢰를 돌려준다. 개인 모드가 아니면 nil (싱글·공유 모드는 지금처럼 신뢰 하나)
function UI.trustPair(fid, entry)
    local C = StoryEngine.Cache or {}
    local function pick(e)
        if type(e) == "table" and e.personal ~= nil then return tonumber(e.personal) or 0, tonumber(e.trust) end
        return nil
    end
    local my, group = pick(entry)
    if my == nil and fid then my, group = pick((C.channels or {})[fid]) end
    if my == nil and fid then
        for _, n in ipairs(C.life or {}) do
            if n.id == fid then my, group = pick(n) end
        end
    end
    if my == nil then return nil end
    if group == nil and fid then group = tonumber(((C.channels or {})[fid] or {}).trust) end
    return my, group or 0
end

-- "내 신뢰 35  무리 60" (개인 모드), 아니면 nil
function UI.trustPairText(fid, entry)
    local my, group = UI.trustPair(fid, entry)
    if my == nil then return nil end
    return getText("IGUI_StoryEngine_Trust_Mine", StoryEngine.intToString(my)) .. "  "
        .. getText("IGUI_StoryEngine_Trust_Group", StoryEngine.intToString(group))
end

-- 0.5 -> "0.5", 1 -> "1"
function UI.shareText(v)
    v = math.floor((tonumber(v) or 0) * 100 + 0.5) / 100
    if v == math.floor(v) then return StoryEngine.intToString(v) end
    return tostring(v)
end

-- ---------------------------------------------------------------- 창 위치·크기 기억 (2026-10-04)
-- 닫을 때 저장하고 다음에 열 때 그 자리·크기로 연다. 게임을 다시 켜도 남도록 Zomboid/Lua/StoryEngine/windows.txt 에 쓴다
-- (한 줄에 "이름=x,y,w,h"). 화면이 작아졌으면 화면 안으로 줄인다.
UI.WINDOW_FILE = "StoryEngine/windows.txt"

local function readWindows()
    if UI.windowsLoaded then return UI.windows end
    UI.windowsLoaded, UI.windows = true, {}
    pcall(function()
        local r = getFileReader(UI.WINDOW_FILE, false)
        if not r then return end
        local line = r:readLine()
        while line do
            local name, x, y, w, h = string.match(line, "^([%w_]+)=(%-?%d+),(%-?%d+),(%d+),(%d+)")
            if name then UI.windows[name] = { x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h) } end
            line = r:readLine()
        end
        r:close()
    end)
    return UI.windows
end

-- 창을 열 자리와 크기: 저장된 값, 없으면 화면 가운데 기본 크기
function UI.windowRect(name, w, h, minW, minH)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local saved = readWindows()[name]
    if saved then w, h = saved.w, saved.h end
    w = math.max(minW or 200, math.min(w, sw - 20))
    h = math.max(minH or 150, math.min(h, sh - 20))
    local x, y
    if saved then
        x = math.max(0, math.min(saved.x, sw - w))
        y = math.max(0, math.min(saved.y, sh - h))
    else
        x, y = (sw - w) / 2, (sh - h) / 2
    end
    return math.floor(x), math.floor(y), math.floor(w), math.floor(h)
end

-- 지금 창의 자리·크기를 기억한다 (창의 close 에서 부른다)
function UI.saveWindow(name, win)
    local list = readWindows()
    list[name] = { x = math.floor(win:getX()), y = math.floor(win:getY()), w = math.floor(win:getWidth()),
                   h = math.floor(win:getHeight()) }
    pcall(function()
        local wr = getFileWriter(UI.WINDOW_FILE, true, false)
        if not wr then return end
        for k, v in pairs(list) do
            wr:write(k .. "=" .. StoryEngine.intToString(v.x) .. "," .. StoryEngine.intToString(v.y) .. ","
                .. StoryEngine.intToString(v.w) .. "," .. StoryEngine.intToString(v.h) .. "\n")
        end
        wr:close()
    end)
end

-- 작은 화면 설정 (켜 둔 창 등): StoryEngine/ui.txt 의 "이름=값" 줄
UI.PREF_FILE = "StoryEngine/ui.txt"

local function readPrefs()
    if UI.prefsLoaded then return UI.prefs end
    UI.prefsLoaded, UI.prefs = true, {}
    pcall(function()
        local r = getFileReader(UI.PREF_FILE, false)
        if not r then return end
        local line = r:readLine()
        while line do
            local k, v = string.match(line, "^([%w_]+)=(.*)$")
            if k then UI.prefs[k] = v end
            line = r:readLine()
        end
        r:close()
    end)
    return UI.prefs
end

function UI.pref(key)
    return readPrefs()[key]
end

function UI.setPref(key, value)
    local prefs = readPrefs()
    prefs[key] = value ~= nil and tostring(value) or nil
    pcall(function()
        local wr = getFileWriter(UI.PREF_FILE, true, false)
        if not wr then return end
        for k, v in pairs(prefs) do wr:write(k .. "=" .. v .. "\n") end
        wr:close()
    end)
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
