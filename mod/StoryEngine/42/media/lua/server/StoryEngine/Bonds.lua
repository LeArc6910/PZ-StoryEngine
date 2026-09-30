-- NPC 사이 관계 (서버 측 전용, 2026-09-30). 설계: docs/IDEAS_NEXT.md 7번
--
-- 관계는 "a 가 b 를 어떻게 보는가" 값 -3~+3. 시작값은 Stories.BONDS (없으면 0), 바뀐 값은 ModData 에 저장한다.
-- 플레이어의 선택으로 움직인다:
--   레이 보급       레이와 받은 NPC 서로 +1
--   위기 선택       선택받은 NPC 와 외면당한 NPC 서로 -1
--   나눔(NpcEvents) 받은 NPC 가 준 NPC 에게 +1
--   충돌(NpcEvents) 방위대와 빅 서로 -1
--   빅 교역소 완성  모두가 빅에게 +1
--   이야기 노드의 bonds = { { from, to, d, why } } (Stories.ARCS)
-- 쓰이는 곳: 관계 파급(Life.spill), 나눔·충돌 조건, 레이의 빅 보급 거절, 평판 vic_friend, 죽음 소식·사기 하락(Fate),
-- 거점 탭 좋아함/싫어함, AI 맥락(무전·공용 주파수: 지금 마음과 최근 변화).
-- 상태: d.bonds = { v = { [a] = { [b] = n } }, last = { [a] = { [b] = { d, text, day } } } }

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Stories"

local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Stories = StoryEngine.Stories
local log = StoryEngine.log

local Bonds = {}
StoryEngine.Bonds = Bonds

Bonds.MIN, Bonds.MAX = -3, 3

local function state()
    local d = Store.data()
    d.bonds = d.bonds or {}
    d.bonds.v = d.bonds.v or {}
    d.bonds.last = d.bonds.last or {}
    return d.bonds
end

function Bonds.get(a, b)
    if a == b then return 0 end
    local row = state().v[a]
    if row and row[b] ~= nil then return row[b] end
    return (Stories.BONDS[a] or {})[b] or 0
end

-- a 가 b 를 보는 마음을 바꾼다. text: AI 에게 넘기는 영어 한 줄 (왜 바뀌었는지). 반환: 실제로 바뀐 양
function Bonds.change(a, b, delta, text, mutual)
    if not Factions.byId[a] or not Factions.byId[b] or a == b or delta == 0 then return 0 end
    local s = state()
    local before = Bonds.get(a, b)
    local after = math.max(Bonds.MIN, math.min(Bonds.MAX, before + delta))
    s.v[a] = s.v[a] or {}
    s.v[a][b] = after
    if after ~= before then
        s.last[a] = s.last[a] or {}
        s.last[a][b] = { d = after - before, text = text, day = Store.dayIndex(Sensor.now().dayKey) }
        log("bond", a, "->", b, before, "->", after, text or "")
    end
    if mutual then Bonds.change(b, a, delta, text, false) end
    return after - before
end

-- 최근 변화 { d, text, day } (없으면 nil)
function Bonds.recent(a, b)
    local row = state().last[a]
    return row and row[b] or nil
end

-- a 가 좋아하는/싫어하는 NPC: { { id, v } } (값이 큰/작은 순)
function Bonds.of(a)
    local likes, dislikes = {}, {}
    for _, f in ipairs(Factions.list) do
        if f.id ~= a then
            local v = Bonds.get(a, f.id)
            if v > 0 then likes[#likes + 1] = { id = f.id, v = v } end
            if v < 0 then dislikes[#dislikes + 1] = { id = f.id, v = v } end
        end
    end
    table.sort(likes, function(x, y) return x.v > y.v end)
    table.sort(dislikes, function(x, y) return x.v < y.v end)
    return likes, dislikes
end

-- 이야기 노드에 들어설 때 (Social.moveTo)
function Bonds.onBeat(node)
    for _, b in ipairs(node and node.bonds or {}) do
        Bonds.change(b[1], b[2], b[3], b[4], false)
    end
end

-- 빅 교역소 완성: 모두가 빅을 조금 다시 본다
function Bonds.onTradingPost()
    for _, f in ipairs(Factions.list) do
        if f.id ~= "rats" then
            Bonds.change(f.id, "rats", 1, "Vic turned his crew's hideout into a trading post with the players' help", false)
        end
    end
end

-- 디버그 상태 줄
function Bonds.statusText()
    local parts = {}
    for a, row in pairs(state().v) do
        for b, v in pairs(row) do
            if v ~= ((Stories.BONDS[a] or {})[b] or 0) then parts[#parts + 1] = a .. ">" .. b .. "=" .. tostring(v) end
        end
    end
    table.sort(parts)
    return "bonds " .. (#parts > 0 and table.concat(parts, " ") or "unchanged")
end

return Bonds
