-- 무전 상대 세력. 게임 쪽에는 id, 주파수, 거점, 초기 신뢰도, 전문 분야만 둔다.
-- 이름은 번역 파일(IGUI_StoryEngine_Faction_<id>), 성격·말투는 브릿지(modules.py FACTIONS)에 있다.
-- 초기 신뢰도는 성향에 따라 0~30 (거래는 20부터 열린다, Trade.LIMITS). 이미 만들어진 채널은 세이브의 값을 쓴다.
-- threat = true 인 세력은 신뢰도가 아주 낮으면 협박한다 (Director extortion). 목사·간호사 같은 인물은 하지 않는다.
-- 전문 분야 보상은 Loot.SPECIALTY_CAT (실시간 생성, 고정 표 Loot.SPECIALTY 는 대비용), 전문 거래 품목은 Trade.FACTION_GOODS, 부탁은 Needs.TABLE.

require "StoryEngine/Core"

local Factions = {}
StoryEngine.Factions = Factions

Factions.list = {
    { id = "ray",    freq = "91.4",  x = 11654, y = 6864,  trust = 30, specialty = "farm" },         -- West Point
    { id = "casey",  freq = "107.7", x = 13447, y = 5278,  trust = 30, specialty = "electronics" },  -- Valley Station
    { id = "doc",    freq = "95.1",  x = 6450,  y = 5430,  trust = 25, specialty = "medical" },      -- Riverside
    { id = "pike",   freq = "99.9",  x = 10130, y = 12801, trust = 20, specialty = "provisions" },   -- March Ridge
    { id = "dewey",  freq = "101.5", x = 3589,  y = 10952, trust = 15, specialty = "vehicle" },      -- Echo Creek
    { id = "guard",  freq = "104.2", x = 12518, y = 4258,  trust = 10, specialty = "military", threat = true },  -- Knox Boundary Camp
    { id = "rats",   freq = "88.7",  x = 3486,  y = 8193,  trust = 5,  specialty = "salvage", threat = true },   -- Coalfield
    { id = "hunter", freq = "86.3",  x = 634,   y = 9746,  trust = 0,  specialty = "hunting" },      -- Ekron woods
}

Factions.byId = {}
for _, f in ipairs(Factions.list) do Factions.byId[f.id] = f end

-- 죽었거나 떠난 NPC 인가 (서버의 Fate.lua 가 채운다. 클라이언트는 목록의 gone 값을 본다)
function Factions.isGone(id) return false end
function Factions.fateOf(id) return nil end

-- 후임 목소리 (Voices.lua, 2026-10-07): 앞 사람이 죽거나 떠난 뒤 같은 주파수를 이어받은 사람. [채널] = 후임 id.
-- 서버는 Voices 가, 클라이언트는 npcVoices 알림이 채운다. 이름은 IGUI_StoryEngine_Voice_<후임>
Factions.voice = {}

function Factions.name(id)
    local v = Factions.voice[id]
    if v then return getText("IGUI_StoryEngine_Voice_" .. tostring(v)) end
    return getText("IGUI_StoryEngine_Faction_" .. tostring(id))
end

local function isTwoWay(obj)
    local ok, yes = pcall(function()
        local dd = obj:getDeviceData()
        return dd ~= nil and dd:getIsTwoWay()
    end)
    return ok and yes == true
end

-- 교신·제출·거래를 할 수 있는지. 샌드박스 StoryEngine.RequireRadio 가 켜져 있을 때만 무전기를 요구한다 (기본 꺼짐).
function Factions.canTalk(player)
    local vars = SandboxVars and SandboxVars.StoryEngine
    if not (vars and vars.RequireRadio == true) then return true end
    return Factions.hasTwoWayRadio(player)
end

-- 양방향 무전기(워키토키, 햄 라디오)를 가지고 있거나 2타일 안에 설치된 것이 있는지.
-- 클라이언트는 입력창 활성화에, 서버는 실제 허용 판단에 쓴다.
function Factions.hasTwoWayRadio(player)
    local items = player:getInventory():getItems()
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if instanceof(it, "Radio") and isTwoWay(it) then return true end
    end
    local sq = player:getCurrentSquare()
    if not sq then return false end
    local cell = getCell()
    for dx = -2, 2 do
        for dy = -2, 2 do
            local s = cell:getGridSquare(sq:getX() + dx, sq:getY() + dy, sq:getZ())
            if s then
                local objs = s:getObjects()
                for i = 0, objs:size() - 1 do
                    local o = objs:get(i)
                    if instanceof(o, "IsoWaveSignal") and isTwoWay(o) then return true end
                end
            end
        end
    end
    return false
end

return Factions
