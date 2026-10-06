-- 퀘스트 (서버 측 전용). 물건은 AI 가 아니라 모드가 놓는다.
--
-- 종류
--   supply_drop : 건물 보관함의 보급품을 가져가면 완료. 보상 보급(origin.source = "reward")도 이 종류다.
--   fetch       : 건물에 놓인 전용 아이템(StoryEngine.*)을 찾아 무전으로 제출하면 완료, 보상 보급이 생긴다.
--   deliver     : NPC 가 먼저 부탁한 물건(Needs.lua)을 무전으로 전달. 위치가 없다.
--                 proposed(답변 대기) -> accepted | declined(거절/무응답) -> completed | failed
--   trade       : 플레이어가 먼저 요청한 거래 (Trade.lua). 위치가 없다. 수락 후 대가를 내면 물건이 보급 퀘스트로 온다.
--   collect     : 복구 작전의 모금 (Ops.lua). 위치 없음, 바로 accepted. 여러 사람이 무전으로 나눠 보낸다 (q.got)
--   defend      : 복구 작전의 방어. 현장 반경 안에 누군가 있으면 시간이 쌓이고 (q.progress 분), 다 차면 완료
--   visit       : 복구 작전의 마지막 방문. 현장 반경 안에 들어가면 완료
--   작전 퀘스트(origin.op)는 신뢰도·NPC 반응·생활 상태·보상을 건너뛰고 Ops.onQuest 가 막 진행을 맡는다
--   큰 사건 퀘스트(origin.saga, Saga.lua)도 같다 (Saga.onQuest)
--   horde       : NPC 가 부탁한 좀비 무리 소탕 (C단계). proposed -> accepted 가 되면 건물 주변에 무리를 배치하고,
--                 구역 안에서 죽은 좀비 수를 센다 (좀비 개별 태그는 청크가 내려가면 사라질 수 있어 쓰지 않는다).
--                 배치한 수의 80% 를 처치하면 완료, 보상 보급은 그 자리 근처. 기한을 넘기면 실패.
-- 상태
--   진행 중: offered -> approached(반경 15) -> entered(건물 진입) -> retrieved(fetch: 아이템을 집음)
--   끝남  : completed | failed (기한 초과). 실패하면 남은 퀘스트 아이템을 지운다.
-- 등급(tier) 1~5 가 클수록 멀리 생성되고, 기한은 거리에 비례한다.
--   1: 60~200타일 (근처)  2: 200~500 (같은 동네)  3: 500~1000 (마을 끝)
--   4: 1000~2000, 가장 가까운 마을에서 450타일 이상 떨어진 교외
--   5: 플레이어가 있는 마을이 아닌 다른 마을 (가까운 다른 마을 2~3곳 중 하나)

if isClient() then return end

require "StoryEngine/Items"
require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Places"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Radio"
require "StoryEngine/Loot"
require "StoryEngine/Needs"
require "StoryEngine/Trust"

local Store = StoryEngine.Store
local Places = StoryEngine.Places
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Radio = StoryEngine.Radio
local log = StoryEngine.log

local Quests = {
    ready = false,
    seen = {},       -- questId -> 목표 칸이 로드된 것을 처음 본 시각 (실시간 ms)
    attempts = {},   -- questId -> 건물이 덜 로드된 상태에서 기다린 횟수
    waiting = 0,     -- 아직 배치 전인 진행 중 퀘스트 수 (LoadGridsquare 조기 종료용)
}
StoryEngine.Quests = Quests

Quests.MAX_TIER = 5
Quests.RANGES = { { 60, 200 }, { 200, 500 }, { 500, 1000 }, { 1000, 2000 } }
Quests.RURAL_TOWN_DIST = 450      -- 4등급: 가장 가까운 마을 중심에서 이만큼 떨어진 곳
Quests.CITY_MIN_DIST = 1200       -- 5등급: 다른 마을까지 최소 거리
Quests.CITY_CHOICES = 3           -- 5등급: 가까운 다른 마을 몇 곳 중에서 고를지
Quests.CITY_RADIUS = 250          -- 5등급: 마을 중심에서 이 반경 안의 건물
Quests.RADIUS = 15
Quests.SETTLE_MS = 2000
Quests.MAX_ATTEMPTS = 5
Quests.HORDE_SIZE = { 12, 20, 30, 45, 65 }   -- 등급별 소탕 무리 (2026-10-02 늘림, 예전 8/14/20/30/45)
Quests.RESCUE_ZOMBIES = 2                    -- 구조 신호 건물 안 좀비 = (등급 + 1) x 이 값

-- 샌드박스 ZombieMult(모드 좀비 수 배율)를 곱한 실제 마릿수
function Quests.zombieCount(n)
    if StoryEngine.Tuning and StoryEngine.Tuning.zombies then return StoryEngine.Tuning.zombies(n) end
    return math.max(1, math.floor(n + 0.5))
end
Quests.HORDE_CLEAR = 0.8          -- 이 비율을 처치하면 완료
Quests.HORDE_SPREAD = 8           -- 건물 경계에서 이만큼 바깥까지 배치
Quests.HORDE_AREA = 25            -- 건물 경계에서 이만큼 바깥까지 처치를 센다
Quests.FETCH_ITEMS = { "StoryEngine.SealedDocuments", "StoryEngine.SealedParcel", "StoryEngine.PhotoAlbum" }

-- 보관함 우선순위. 조리 기구, 쓰레기통, 세탁기처럼 물자를 둘 곳이 아닌 것은 뺀다.
Quests.PREFERRED = { crate = 1, metal_shelves = 2, shelves = 3, counter = 4, wardrobe = 5, dresser = 6,
                     sidetable = 7, desk = 8, filingcabinet = 9, smallbox = 10 }
Quests.EXCLUDED = { stove = true, microwave = true, fridge = true, freezer = true, bin = true, toilet = true,
                    clothingwasher = true, clothingdryer = true, barbecue = true, fireplace = true, corpse = true }

local ACTIVE = { offered = true, approached = true, entered = true, retrieved = true, accepted = true }
Quests.RESPOND_MIN = 12 * 60      -- 부탁에 답할 시간 (게임 내 분)
Quests.EXTORT_MINUTES = 36 * 60   -- 협박 기한

local LEGACY = { looted = "completed", expired = "failed" }

local function all()
    return Store.data().quests
end

local function dist(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

local function buildingKey(def)
    return "b" .. StoryEngine.intToString(def:getX()) .. "_" .. StoryEngine.intToString(def:getY())
end

function Quests.isActive(q)
    return ACTIVE[q.state] == true
end

function Quests.activeFor(psKey, kind)
    for _, q in pairs(all()) do
        if q.target == psKey and Quests.isActive(q) and (not kind or q.kind == kind) then return q end
    end
    return nil
end

-- 거리에 비례한 기한 (게임 내 분): 기본 이틀 + 100타일당 10시간
local function timeMult()
    return StoryEngine.Tuning and StoryEngine.Tuning.num("QuestTimeMult") or 1
end

function Quests.deadlineMinutes(distance)
    return math.floor((48 + distance * 0.1) * 60 * timeMult())
end

-- 부탁 물건 전달 기한 (게임 내 분): 이틀 + 등급당 하루
function Quests.deliverMinutes(tier)
    return math.floor((48 + 24 * (tier or 1)) * 60 * timeMult())
end

local function itemName(fullType)
    local ok, name = pcall(getItemNameFromFullType, fullType)
    return (ok and name) or fullType
end

-- 건물 위치가 있는 퀘스트인가 (부탁·거래는 무전으로만 주고받아 위치가 없다)
local NO_LOCATION = { deliver = true, trade = true, extort = true, collect = true, market = true }
function Quests.hasLocation(q)
    return not NO_LOCATION[q.kind]
end

-- 복구 작전(Ops.lua) 퀘스트인가
function Quests.isOp(q)
    return q ~= nil and q.origin ~= nil and q.origin.op ~= nil
end

-- 큰 사건(Saga.lua) 퀘스트인가
function Quests.isSaga(q)
    return q ~= nil and q.origin ~= nil and q.origin.saga ~= nil
end

-- 거래 대가로 하는 일(Work.lua) 퀘스트인가
function Quests.isWork(q)
    return q ~= nil and q.origin ~= nil and q.origin.work ~= nil
end

-- 작전·큰 사건·거래 대가 일이 맡는 퀘스트 (신뢰도·반응·보상을 건너뛴다)
function Quests.isManaged(q)
    return Quests.isOp(q) or Quests.isSaga(q) or Quests.isWork(q)
        or (q ~= nil and q.origin ~= nil and (q.origin.holiday ~= nil or q.origin.source == "recover"))
end

-- 상태가 바뀔 때 부르는 함수들 (명절·유품 회수 등 다른 모듈이 등록한다). fn(q, state, outcome, trustDelta)
Quests.hooks = {}

-- 진행 중 일이 생길 때 부르는 함수들 (거래 대가 일의 머리 위 무전, Work.lua). fn(q, event, info)
--   kill(소탕 처치) / scout_entered / scout_enter(머물렀지만 아직 안 들어감) / scout_night / scout_next / defend_pct
Quests.progressHooks = {}
function Quests.onProgress(q, event, info)
    for _, fn in ipairs(Quests.progressHooks) do
        local ok, err = pcall(fn, q, event, info or {})
        if not ok then log("quest progress hook error:", err) end
    end
end

-- 아이템 목록 요약 ("권총, 9mm 탄약 상자 x2")
local function listText(list)
    local order, counts = {}, {}
    for _, ft in ipairs(list or {}) do
        if not counts[ft] then counts[ft] = 0; order[#order + 1] = ft end
        counts[ft] = counts[ft] + 1
    end
    local parts = {}
    for _, ft in ipairs(order) do
        local name = itemName(ft)
        parts[#parts + 1] = counts[ft] > 1 and (name .. " x" .. StoryEngine.intToString(counts[ft])) or name
    end
    return table.concat(parts, ", ")
end
Quests.listText = listText

-- ---------------------------------------------------------------- 품목 점수 부탁 (2026-10-04 사용자 결정)
-- 음식처럼 종류가 아주 많은 품목은 특정 물건을 갖고 있기 어려워서, 부탁을 만들 때 그 품목의 물건들을
-- "그 품목 가치 N점" 하나로 합친다. 부탁 항목 { "cat:food", N }: 그 품목(Value.categoryOf)의 물건 아무거나 가치 합 N 이상.
-- 음료(캔 음료·물 통조림)도 음식 품목이라 같이 합쳐진다. 근접 무기·총기도 종류가 많아 점수로 (같은 날 추가).
-- 의약품·도구·탄약 등은 그대로 특정 물건 (탄약은 총에 맞는 구경이 중요해서).
Quests.POINT_PREFIX = "cat:"

-- 부탁 항목이 품목 점수면 그 품목 이름, 아니면 nil
function Quests.pointCat(entry)
    local s = type(entry) == "table" and entry[1] or entry
    if type(s) ~= "string" or string.sub(s, 1, 4) ~= Quests.POINT_PREFIX then return nil end
    return string.sub(s, 5)
end

-- 샌드박스 부탁 난이도: 점수 배율(RequestPointsMult), 등급 하한(RequestMinTier: 1 없음 / 2 부탁 등급-2 / 3 부탁 등급-1 / 4 부탁 등급)
local function pointsMult()
    return StoryEngine.Tuning and StoryEngine.Tuning.num("RequestPointsMult") or 1
end

function Quests.pointMinTier(kind, tier)
    if kind == "comfort" then return nil end
    local opt = StoryEngine.Tuning and StoryEngine.Tuning.num("RequestMinTier") or 1
    if opt <= 1 then return nil end
    local min = (tier or 1) - (4 - opt)
    min = math.min(min, StoryEngine.Value.POINT_MAX_TIER[kind] or 5)
    if min <= 1 then return nil end
    return min
end

-- 등급별 요구량 (2026-10-06): 부탁 등급마다 품목별 기준 가치. 요구 점수 = 기준 x 배율(RequestPointsMult)이라
-- 같은 등급이면 어느 품목이든 비슷한 수고가 들고, 등급이 오르면 일정하게 늘어난다.
-- 대략 그 등급의 거래 묶음 하나. 총기는 x1.5 했을 때 그 등급 총 한 자루 (30/40/50/65/80)
Quests.POINT_BASE = {
    food = { 4, 8, 12, 18, 26 },
    medical = { 4, 8, 12, 20, 30 },
    tools = { 4, 8, 14, 22, 32 },
    electronics = { 4, 8, 14, 22, 32 },
    vehicle = { 4, 8, 14, 22, 32 },
    melee = { 3, 5, 8, 12, 16 },
    ammo = { 8, 12, 18, 28, 40 },
    firearm = { 20, 27, 34, 44, 54 },
    comfort = { 3, 6, 10, 15, 22 },
}
Quests.MATERIAL_BASE = Quests.POINT_BASE.tools
-- 그대로 받는 자재의 수고 (점수 품목과 나눌 때만 쓴다). 없으면 MATERIAL_DEFAULT
Quests.MATERIAL_VALUE = {
    ["Base.NailsBox"] = 4, ["Base.ScrewsBox"] = 3, ["Base.DuctTape"] = 2, ["Base.Matches"] = 1, ["Base.Sheet"] = 1,
    ["Base.SheetMetal"] = 3, ["Base.Twine"] = 1, ["Base.WeldingRods"] = 2, ["Base.WaterRationCan"] = 2,
    ["Base.Firewood"] = 1, ["Base.Battery"] = 1, ["Base.CarrotBagSeed2"] = 2, ["Base.PotatoBagSeed2"] = 2, ["Base.TomatoBagSeed2"] = 2,
}
Quests.MATERIAL_DEFAULT = 2
-- 점수 품목이어도 부탁에서는 그 물건 그대로 받는 것 (배터리: 기호품이지만 무전기·조명에 쓰라는 부탁이라, 2026-10-06)
Quests.EXACT_ITEMS = { ["Base.Battery"] = true }

-- 부탁 물건 목록을 품목 점수로 바꾼다 (2026-10-05: 점수 품목 전부, 자재는 특정 물건 그대로).
-- 항목 { "cat:<품목>", 점수, 등급 하한 }.
-- 등급(tier)이 있으면 (2026-10-06) 부탁 전체의 수고를 그 등급의 기준(POINT_BASE)에 맞춘다: 품목마다
-- 무게 = 원래 물건 가치 / 그 품목 기준, 자재도 MATERIAL_VALUE / MATERIAL_BASE 로 무게를 갖고, 품목 점수 =
-- 기준 x 배율 x (그 품목 무게 / 모든 무게 합). 물건이 한 품목뿐이면 기준 x 배율 그대로.
-- 등급이 없으면 예전처럼 원래 물건 가치 합 x 배율.
-- 등급 하한 = 부탁 등급 -1 (RequestMinTier) 이되 원래 청한 물건 중 가장 낮은 등급보다 높지 않다 (청한 그 물건은 늘 낼 수 있게).
-- 탄약의 하한은 청한 구경의 등급.
-- plain = 난이도(배율·하한·기준)를 걸지 않는다 (헬기 추락처럼 현장 상자의 물건으로 채우게 만든 부탁)
-- 샌드박스 RequestItemMode (2026-10-06): 1 품목 점수 / 2 음식·근접 무기·총만 점수(MODE2_KINDS) / 3 정해진 물건 그대로.
-- plain 부탁은 방식과 상관없이 점수 (현장 상자로 채우게 만든 부탁이라)
Quests.MODE2_KINDS = { food = true, melee = true, firearm = true }
function Quests.itemMode()
    local m = StoryEngine.Tuning and StoryEngine.Tuning.num("RequestItemMode") or 1
    m = math.floor(tonumber(m) or 1)
    if m < 1 or m > 3 then m = 1 end
    return m
end

function Quests.pointsNeed(items, tier, plain)
    local V = StoryEngine.Value
    local out, sums, lows, order = {}, {}, {}, {}
    local mode = plain and 1 or Quests.itemMode()
    if mode == 3 then
        for _, n in ipairs(items or {}) do out[#out + 1] = { n[1], n[2], n[3] } end
        return out
    end
    local matWeight = 0
    local t = tier and math.max(1, math.min(5, math.floor(tier))) or nil
    for _, n in ipairs(items or {}) do
        local kind = not Quests.pointCat(n) and not Quests.EXACT_ITEMS[n[1]] and V.pointKind(n[1]) or nil
        local keptKind = nil
        if kind and mode == 2 and not Quests.MODE2_KINDS[kind] then kind, keptKind = nil, kind end
        if kind then
            if not sums[kind] then order[#order + 1] = kind end
            sums[kind] = (sums[kind] or 0) + V.pointOf(n[1]) * (n[2] or 1)
            local it = V.pointTier(n[1])
            if it then lows[kind] = math.min(lows[kind] or it, it) end
        else
            out[#out + 1] = { n[1], n[2], n[3] }
            if t and keptKind then
                -- 방식 2 에서 그대로 받는 점수 품목 물건: 그 품목 기준으로 수고를 센다
                matWeight = matWeight + V.pointOf(n[1]) * (n[2] or 1) / Quests.POINT_BASE[keptKind][t]
            elseif t and not Quests.pointCat(n) then
                matWeight = matWeight + (Quests.MATERIAL_VALUE[n[1]] or Quests.MATERIAL_DEFAULT) * (n[2] or 1)
                    / Quests.MATERIAL_BASE[t]
            end
        end
    end
    local mult = plain and 1 or pointsMult()
    local scaled = t and not plain
    local weights, total = {}, matWeight
    if scaled then
        for _, kind in ipairs(order) do
            weights[kind] = math.max(0.01, sums[kind] / Quests.POINT_BASE[kind][t])
            total = total + weights[kind]
        end
    end
    for _, kind in ipairs(order) do
        local min
        if kind == "ammo" then
            min = lows.ammo
        elseif not plain then
            min = Quests.pointMinTier(kind, tier)
            if min and lows[kind] and lows[kind] < min then min = lows[kind] end
        end
        if min and min <= 1 then min = nil end
        local value = sums[kind]
        if scaled then value = Quests.POINT_BASE[kind][t] * weights[kind] / total end
        out[#out + 1] = { Quests.POINT_PREFIX .. kind, math.max(1, math.ceil(value * mult - 0.001)), min }
    end
    return out
end

Quests.POINT_WORDS = { tools = "tools", melee = "melee weapons", firearm = "firearms", ammo = "ammunition",
                       medical = "medical supplies", electronics = "electronics", vehicle = "car parts",
                       comfort = "comforts (alcohol, tobacco, reading, batteries, candles)" }

-- 부탁 물건 목록을 사람이 읽는 문장으로 ("진통제 x2, 붕대 x3", 품목 점수는 "any food worth 5 points")
function Quests.needText(q)
    local parts = {}
    for _, n in ipairs(q.need or {}) do
        local cat = Quests.pointCat(n)
        if cat then
            local words = Quests.POINT_WORDS[cat] or cat
            parts[#parts + 1] = "some " .. words .. " of any kind (worth about " .. StoryEngine.intToString(n[2])
                .. " value points" .. (n[3] and (", tier " .. StoryEngine.intToString(n[3]) .. " or better") or "") .. ")"
        else
            local name = itemName(n[1])
            parts[#parts + 1] = n[2] > 1 and (name .. " x" .. StoryEngine.intToString(n[2])) or name
        end
    end
    return table.concat(parts, ", ")
end

-- 진행 중이거나 답변을 기다리는 퀘스트
function Quests.openFor(psKey, kind)
    for _, q in pairs(all()) do
        if q.target == psKey and (Quests.isActive(q) or q.state == "proposed") and (not kind or q.kind == kind) then
            return q
        end
    end
    return nil
end

-- 이 세력과 진행 중이거나 답을 기다리는 거래 (서버 전체에서 세력당 하나)
function Quests.openTrade(fid)
    for _, q in pairs(all()) do
        if q.kind == "trade" and (Quests.isActive(q) or q.state == "proposed") and q.origin and q.origin.faction == fid then
            return q
        end
    end
    return nil
end

-- 퀘스트는 서버의 모든 플레이어가 함께 본다. 바뀌면 접속한 모두에게 알린다.
local function notifyTarget(q)
    for _, p in ipairs(Sensor.players()) do
        pcall(StoryEngine.Net.toClient, p, "questChanged", { id = q.id })
    end
end

-- ---------------------------------------------------------------- building search

local function groundRoom(def)
    local rooms = def:getRooms()
    for ri = 0, rooms:size() - 1 do
        local rd = rooms:get(ri)
        if rd:getZ() == 0 and rd:getArea() >= 6 then return rd end
    end
    return nil
end

-- 점 (px, py) 근처(반경 r)에서 조건에 맞는 건물 중 점에 가장 가까운 것.
-- accept(def, cx, cy) 가 false 면 건너뛴다. 반환: { def, room, key, distance(플레이어부터) } | nil
local function nearestBuilding(x, y, px, py, r, exclude, accept)
    local list = ArrayList.new()
    getWorld():getMetaGrid():getBuildingsIntersecting(math.floor(px - r), math.floor(py - r), r * 2, r * 2, list)
    local best, bestD = nil, nil
    for i = 0, list:size() - 1 do
        local def = list:get(i)
        local key = buildingKey(def)
        local cx, cy = (def:getX() + def:getX2()) / 2, (def:getY() + def:getY2()) / 2
        if not exclude[key] and (not accept or accept(def, cx, cy)) then
            local room = groundRoom(def)
            local fromPoint = dist(px, py, cx, cy)
            if room and (not bestD or fromPoint < bestD) then
                best, bestD = { def = def, room = room, key = key, distance = dist(x, y, cx, cy) }, fromPoint
            end
        end
    end
    return best
end

-- 무작위 방향으로 목표 거리 지점을 찍고, 그 근처에서 조건에 맞는 건물을 찾는다.
function Quests.findBuilding(x, y, minD, maxD, exclude, accept)
    for _ = 1, 12 do
        local angle = ZombRandFloat(0, math.pi * 2)
        local d = ZombRandFloat(minD, maxD)
        local px, py = x + math.cos(angle) * d, y + math.sin(angle) * d
        local found = nearestBuilding(x, y, px, py, 80, exclude, function(def, cx, cy)
            local fromPlayer = dist(x, y, cx, cy)
            if fromPlayer < minD * 0.8 or fromPlayer > maxD * 1.1 then return false end
            return not accept or accept(def, cx, cy)
        end)
        if found then return found end
    end
    return nil
end

-- 5등급: 플레이어가 있는 마을이 아닌, 가까운 다른 마을 몇 곳 중 하나의 안쪽 건물
function Quests.findInOtherTown(x, y, exclude)
    local here = Places.describe(x, y).town
    local towns = {}
    for _, t in ipairs(Places.towns) do
        local d = dist(x, y, t.x, t.y)
        if t.key ~= here and d >= Quests.CITY_MIN_DIST then towns[#towns + 1] = { town = t, d = d } end
    end
    table.sort(towns, function(a, b) return a.d < b.d end)
    local choices = math.min(#towns, Quests.CITY_CHOICES)
    if choices == 0 then return nil end
    for _ = 1, 8 do
        local t = towns[ZombRand(choices) + 1].town
        local px = t.x + ZombRandFloat(-Quests.CITY_RADIUS, Quests.CITY_RADIUS)
        local py = t.y + ZombRandFloat(-Quests.CITY_RADIUS, Quests.CITY_RADIUS)
        local found = nearestBuilding(x, y, px, py, 120, exclude, nil)
        if found then return found end
    end
    return nil
end

-- 등급에 맞는 퀘스트 건물. 4등급은 교외를 먼저 찾고, 없으면 거리만 맞춘다.
function Quests.findForTier(x, y, tier, exclude)
    if tier >= 5 then
        return Quests.findInOtherTown(x, y, exclude) or Quests.findBuilding(x, y, 2000, 3500, exclude)
    end
    local range = Quests.RANGES[tier]
    if tier == 4 then
        local rural = Quests.findBuilding(x, y, range[1], range[2], exclude, function(def, cx, cy)
            return Places.describe(cx, cy).townDist >= Quests.RURAL_TOWN_DIST
        end)
        if rural then return rural end
    end
    return Quests.findBuilding(x, y, range[1], range[2], exclude)
end

local function roomNames(def)
    local names, seen = {}, {}
    local rooms = def:getRooms()
    for i = 0, math.min(rooms:size(), 30) - 1 do
        local n = rooms:get(i):getName()
        if n and not seen[n] and #names < 5 then
            seen[n] = true
            names[#names + 1] = n
        end
    end
    return names
end

-- ---------------------------------------------------------------- spawn

-- 건물 1층 전체를 훑어 가장 적합한 보관함을 고른다. 반환: container | nil, 건물 칸이 모두 로드됐는지
local function pickContainer(q)
    local x1, y1, x2, y2 = q.bx1, q.by1, q.bx2, q.by2
    if not x1 then
        local def = getWorld():getMetaGrid():getBuildingAt(q.x, q.y)
        if not def then return nil, true end
        x1, y1, x2, y2 = def:getX(), def:getY(), def:getX2(), def:getY2()
    end
    local cell = getCell()
    local best, bestRank, missing = nil, 999, 0
    for x = x1, x2 do
        for y = y1, y2 do
            local sq = cell:getGridSquare(x, y, q.z)
            if not sq then
                missing = missing + 1
            else
                local b = sq:getBuilding()
                local def = b and b:getDef()
                if def and buildingKey(def) == q.building then
                    local objs = sq:getObjects()
                    for i = 0, objs:size() - 1 do
                        local obj = objs:get(i)
                        for ci = 0, obj:getContainerCount() - 1 do
                            local c = obj:getContainerByIndex(ci)
                            local t = c:getType()
                            if not Quests.EXCLUDED[t] then
                                local rank = Quests.PREFERRED[t] or 50
                                if rank < bestRank then best, bestRank = c, rank end
                            end
                        end
                    end
                end
            end
        end
    end
    return best, missing == 0
end

local function spawnAt(q, sq, container)
    local placed = {}
    if container then
        for _, fullType in ipairs(q.items) do
            local item = StoryEngine.Items.addTo(container, fullType, q.id)
            if item then
                if q.letterId and fullType == "StoryEngine.Letter" then item:getModData().storyLetter = q.letterId end
                placed[#placed + 1] = fullType
            end
        end
        container:setExplored(true)
        local parent = container:getParent()
        local csq = parent:getSquare()
        q.containerType = container:getType()
        q.containerSprite = parent:getSprite() and parent:getSprite():getName() or nil
        q.sx, q.sy, q.sz = csq:getX(), csq:getY(), csq:getZ()
    else
        local target = sq
        local room = sq:getRoom()
        if room then
            local free = room:getRoomDef():getFreeSquare()
            if free then target = free end
        end
        for _, fullType in ipairs(q.items) do
            local item = target:AddWorldInventoryItem(fullType, ZombRandFloat(0.2, 0.8), ZombRandFloat(0.2, 0.8), 0)
            if item then
                item:getModData().storyQuest = q.id
                if q.letterId and fullType == "StoryEngine.Letter" then item:getModData().storyLetter = q.letterId end
                placed[#placed + 1] = fullType
            end
        end
        q.containerType = nil
        q.sx, q.sy, q.sz = target:getX(), target:getY(), target:getZ()
    end
    q.placed = placed
    q.spawned = true
    if q.origin and q.origin.source == "rescue" and q.bx1 then
        local ok, zeds = pcall(addZombiesInOutfitArea, q.bx1, q.by1, q.bx2, q.by2, q.z or 0,
            Quests.zombieCount(((q.tier or 1) + 1) * Quests.RESCUE_ZOMBIES), nil, nil)
        log("rescue zombies", q.id, ok and zeds and zeds:size() or tostring(zeds))
    end
    log("quest spawned", q.id, q.kind, #placed, "items in", q.containerType or "floor", q.containerSprite or "",
        "at", q.sx, q.sy, q.sz)
    notifyTarget(q)
end

-- 칸이 로드되자마자 놓으면 건물의 나머지 칸과 가구가 아직 없어 보관함을 못 찾는다 (42.20.4 확인).
-- 목표 칸이 처음 로드된 것을 본 뒤 SETTLE_MS 이상 지나고, 건물 칸이 모두 로드됐을 때 놓는다.
local function trySpawn(q)
    if q.spawned or not Quests.isActive(q) or not Quests.hasLocation(q) then return end
    local sq = getCell():getGridSquare(q.x, q.y, q.z)
    if not sq then
        Quests.seen[q.id] = nil
        return
    end
    local now = StoryEngine.nowMs()
    if not Quests.seen[q.id] then
        Quests.seen[q.id] = now
        return
    end
    if now - Quests.seen[q.id] < Quests.SETTLE_MS then return end
    if q.kind == "horde" then
        Quests.spawnHorde(q)
        return
    end
    if q.kind == "named" then
        if StoryEngine.Named then StoryEngine.Named.spawn(q) end
        return
    end
    if q.kind == "scout" then
        Quests.spawnScout(q)
        return
    end
    local container, loaded = pickContainer(q)
    if not loaded then
        Quests.attempts[q.id] = (Quests.attempts[q.id] or 0) + 1
        if Quests.attempts[q.id] < Quests.MAX_ATTEMPTS then return end
    end
    spawnAt(q, sq, container)
end

-- 정찰 지점: 건물 안에 좀비를 둔다 (구조 신호 건물과 같은 방식)
function Quests.spawnScout(q)
    local n = Quests.zombieCount(q.zombies or 0)
    local count = 0
    if (q.zombies or 0) > 0 and q.bx1 then
        local ok, zeds = pcall(addZombiesInOutfitArea, q.bx1, q.by1, q.bx2, q.by2, q.z or 0, n, nil, nil)
        count = ok and zeds and zeds:size() or 0
    end
    q.spawned = true
    log("scout point spawned", q.id, q.point or 1, count, "zombies in", q.building or "?")
end

-- 소탕 퀘스트: 건물 주변에 좀비 무리를 배치한다
function Quests.spawnHorde(q)
    local spread = Quests.HORDE_SPREAD
    local list = addZombiesInOutfitArea(q.bx1 - spread, q.by1 - spread, q.bx2 + spread, q.by2 + spread, 0,
        q.size, nil, nil)
    q.spawned = true
    q.sx, q.sy = q.cx, q.cy
    log("horde spawned", q.id, list and list:size() or 0, "zombies around", q.cx, q.cy)
    notifyTarget(q)
end

-- ---------------------------------------------------------------- tagged items

local function isTagged(item, id)
    local mod = item and item:getModData()
    return mod ~= nil and mod.storyQuest == id
end

local function removeFromContainer(container, item)
    StoryEngine.Items.remove(item)
end

-- 놓은 자리에 남은 태그 아이템 수. 칸이 로드되지 않았으면 nil. remove=true 면 찾은 것을 지운다.
local function atSpot(q, remove)
    if not q.spawned then return 0 end
    local sq = getCell():getGridSquare(q.sx, q.sy, q.sz)
    if not sq then return nil end
    local count = 0
    if q.containerType then
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
            local obj = objs:get(i)
            for ci = 0, obj:getContainerCount() - 1 do
                local c = obj:getContainerByIndex(ci)
                local items = c:getItems()
                local found = {}
                for k = 0, items:size() - 1 do
                    if isTagged(items:get(k), q.id) then found[#found + 1] = items:get(k) end
                end
                count = count + #found
                if remove then
                    for _, it in ipairs(found) do removeFromContainer(c, it) end
                end
            end
        end
    else
        local objs = sq:getWorldObjects()
        local found = {}
        for i = 0, objs:size() - 1 do
            local wo = objs:get(i)
            if isTagged(wo:getItem(), q.id) then found[#found + 1] = wo end
        end
        count = #found
        if remove then
            for _, wo in ipairs(found) do sq:transmitRemoveItemFromSquare(wo) end
        end
    end
    return count
end

-- 플레이어가 가진 태그 아이템 (가방 속까지)
local function findInInventory(player, q)
    local out = {}
    for _, fullType in ipairs(q.items or {}) do
        local list = player:getInventory():getAllTypeRecurse(fullType)
        for i = 0, list:size() - 1 do
            local it = list:get(i)
            if isTagged(it, q.id) then out[#out + 1] = it end
        end
    end
    return out
end

Quests.findInInventory = findInInventory

-- 실패한 퀘스트의 아이템 정리. 끝나면 true
local function cleanup(q)
    local left = atSpot(q, true)
    if left == nil then return false end
    if q.kind == "fetch" then
        for _, p in ipairs(Sensor.players()) do
            for _, it in ipairs(findInInventory(p, q)) do
                local c = it:getContainer()
                if c then removeFromContainer(c, it) end
            end
        end
    end
    q.cleanup = nil
    log("quest cleaned", q.id)
    return true
end

-- ---------------------------------------------------------------- state

local function note(ps, kind, q, now, by)
    if not ps then return end
    Store.addNote(ps, {
        kind = kind, clock = now.clock, place = q.place, by = by,
        item = (q.kind == "fetch" and itemName(q.items[1])) or ((q.kind == "deliver" or q.kind == "extort") and Quests.needText(q))
            or (q.kind == "trade" and listText(q.goods)) or nil,
        faction = q.origin and q.origin.faction or nil,
        fight = q.fight and (q.fight.kills > 0 or q.fight.hurt > 0)
            and { kills = q.fight.kills, hurt = q.fight.hurt, bitten = q.fight.bitten } or nil,
    })
end

-- 일지 사건 이름의 앞부분 (구조 신호는 보급 퀘스트지만 따로 부른다)
function Quests.noteKind(q)
    if q.origin and q.origin.source == "rescue" then return "rescue" end
    return q.kind
end

-- NPC 가 퀘스트 결과에 무전으로 반응한다 (AI 에게 넘기는 상황 설명, 영어)
local REACT = {
    deliver = {
        accepted = "The players agreed to bring you %s.",
        declined = "The players refused your request for %s.",
        ignored = "The players never answered your request for %s.",
        completed = "The players delivered the %s you asked for. You already left their payment in a building and told them where.",
        failed = "The players promised to bring you %s but never did.",
    },
    fetch = {
        failed = "The players never brought back the %s you asked them to retrieve.",
    },
    trade = {
        failed = "The players agreed to trade for %s but never paid.",
    },
    horde = {
        accepted = "The players agreed to clear out the dead around %s.",
        declined = "The players refused to deal with the horde around %s.",
        ignored = "The players never answered when you asked them to clear the horde around %s.",
        completed = "The players cleared out the horde around %s. You left their reward close by and told them.",
        failed = "The players said they would clear the horde around %s but never did.",
    },
}
REACT.extort = {
    completed = "The players handed over what you demanded (%s). You leave them alone, for now.",
}
REACT.named = {
    accepted = "The players agreed to find %s, who turned, and put them to rest.",
    declined = "The players would not go after %s, who turned.",
    ignored = "The players never answered when you asked them to put %s to rest.",
    completed = "The players put %s to rest and brought back what they carried. Tell them what that person was like, in a few words.",
    failed = "The players never found %s. They are still out there somewhere.",
}
REACT.rescue = {
    completed = "The players reached the building near %s where the distress call came from. The survivor was already gone; they found only what was left behind.",
    failed = "Nobody went to check the distress call from near %s in time.",
}
local TRUST_STATES = { accepted = true, declined = true, completed = true, failed = true }

-- AI 없이 쓰는 반응 (Lines.lua 종류). 영어 문장은 AI 가 다음 교신에서 읽는 기록
local REACT_LINES = {
    deliver = { accepted = "q_accepted", declined = "q_declined", ignored = "q_ignored", completed = "q_thanks",
                failed = "q_failed" },
    fetch = { failed = "q_failed" },
    trade = { failed = "trade_failed" },
    horde = { accepted = "q_accepted", declined = "q_declined", ignored = "q_ignored", completed = "horde_thanks",
              failed = "q_failed" },
    extort = { completed = "extort_paid" },
    rescue = { completed = "rescue_done", failed = "rescue_failed" },
    named = { accepted = "q_accepted", declined = "q_declined", ignored = "q_ignored", completed = "named_thanks",
              failed = "q_failed" },
}
local REACT_TEXT = {
    q_accepted = "Thank you. I am counting on you.", q_declined = "All right. I understand.",
    q_ignored = "You never answered me.", q_thanks = "Got it. Thank you, truly.",
    q_failed = "You never came through.", horde_thanks = "You cleared them out. Thank you.",
    trade_failed = "You never paid. The deal is off.", rescue_done = "You went. That matters.",
    rescue_failed = "Nobody went for them.", extort_paid = "Smart. We will leave you be, for now.",
}

function Quests.react(q, outcome)
    local fid = q.origin and q.origin.faction
    local byKind = REACT[Quests.noteKind(q)]
    local template = byKind and byKind[outcome]
    if not fid or not template then return end
    local what = ((q.kind == "deliver" or q.kind == "extort") and Quests.needText(q)) or (q.kind == "trade" and listText(q.goods))
        or (q.kind == "horde" and (q.place.landmark or ("a building near " .. q.place.town)))
        or (Quests.noteKind(q) == "rescue" and q.place.town)
        or (q.kind == "named" and tostring(q.personName or "someone"))
        or itemName((q.items or {})[1] or "")
    local topic = string.format(template, what)
    local fight = outcome == "completed" and Quests.fightText(q) or nil
    if fight then topic = topic .. " On the way " .. fight .. "." end
    if outcome == "completed" then topic = topic .. Quests.creditText(q) end
    local lineKind = (REACT_LINES[Quests.noteKind(q)] or {})[outcome]
    local args = q.kind == "named" and { { t = "key", v = "IGUI_StoryEngine_Named_" .. tostring(q.person) .. "_name" } } or nil
    local fallback = lineKind and StoryEngine.Lines.fallback(fid, lineKind, REACT_TEXT[lineKind] or "...", args) or nil
    Radio.react(fid, "event", topic, fallback, Store.data().players[q.target])
end

-- outcome: 신뢰도·반응에 쓰는 결과 이름 (무응답은 state = declined, outcome = ignored)
local function setState(q, state, now, entry, outcome)
    q.state = state
    if entry and entry.ps and (state == "completed" or state == "retrieved" or state == "entered") then
        Quests.addHelper(q, entry.ps)
    end
    q.history = q.history or {}
    local by = entry and entry.ps.name or nil
    Store.push(q.history, { state = state, t = now.t, by = by }, 20)
    if state == "completed" or state == "failed" or state == "declined" then q.endedT = now.t end
    log("quest", q.id, q.kind, state, by or "")
    local kind = Quests.noteKind(q) .. "_" .. state
    if entry then
        note(entry.ps, kind, q, now, by)
        for _, name in ipairs(entry.companions or {}) do
            note(Store.findByName(name), kind, q, now, by)
        end
    end
    local targetPs = Store.data().players[q.target]
    if targetPs and (not entry or entry.ps ~= targetPs) then note(targetPs, kind, q, now, by) end
    local trustDelta = 0
    local isOp = Quests.isManaged(q)
    if Quests.isOp(q) and (state == "completed" or state == "failed") and StoryEngine.Ops then
        local ok, err = pcall(StoryEngine.Ops.onQuest, q, state)
        if not ok then log("ops quest error:", err) end
    end
    if Quests.isSaga(q) and (state == "completed" or state == "failed") and StoryEngine.Saga then
        local ok, err = pcall(StoryEngine.Saga.onQuest, q, state)
        if not ok then log("saga quest error:", err) end
    end
    if TRUST_STATES[state] and not isOp then
        local ok, err = pcall(StoryEngine.Trust.forQuest, q, outcome or state)
        if not ok then log("trust error:", err) else trustDelta = tonumber(err) or 0 end
        ok, err = pcall(Quests.react, q, outcome or state)
        if not ok then log("react error:", err) end
    end
    if StoryEngine.Life and TRUST_STATES[state] and not isOp then
        local ok, err = pcall(StoryEngine.Life.onQuest, q, outcome or state, trustDelta)
        if not ok then log("life quest error:", err) end
    end
    if q.kind == "extort" and state == "failed" then
        local ok, err = pcall(Quests.punish, q)
        if not ok then log("extort punish error:", err) end
    end
    if StoryEngine.Monologue then
        local ok, err = pcall(StoryEngine.Monologue.onQuest, q, state, entry)
        if not ok then log("monologue quest error:", err) end
    end
    if StoryEngine.Banter then
        local ok, err = pcall(StoryEngine.Banter.onQuest, q, state)
        if not ok then log("banter quest error:", err) end
    end
    if StoryEngine.Social and TRUST_STATES[state] and not isOp then
        local ok, err = pcall(StoryEngine.Social.onQuest, q, outcome or state)
        if not ok then log("social quest error:", err) end
    end
    for _, fn in ipairs(Quests.hooks) do
        local ok, err = pcall(fn, q, state, outcome or state, trustDelta)
        if not ok then log("quest hook error:", err) end
    end
    -- 거래 대가 일·외상·빚 (Work.lua)
    if StoryEngine.Work and (Quests.isWork(q) or q.kind == "trade" or q.favorCall) then
        local ok, err = pcall(StoryEngine.Work.onState, q, state, outcome or state, trustDelta)
        if not ok then log("work state error:", err) end
    end
    notifyTarget(q)
end
Quests.setState = function(q, state, now, entry, outcome) return setState(q, state, now, entry, outcome) end
Quests.notify = function(q) return notifyTarget(q) end

-- 죽거나 떠난 NPC 의 부탁·거래를 조용히 거둔다 (신뢰도·반응·생활 상태 변화 없음, Fate.lua).
-- 이미 놓인 보급(보상·선물)은 그대로 둔다.
local CANCELABLE = { deliver = true, trade = true, horde = true, extort = true }
function Quests.cancelFor(fid, now)
    for _, q in pairs(all()) do
        local job = Quests.isWork(q) and Quests.isActive(q)     -- 거래 대가로 하던 일 (Work.lua)
        if q.origin and q.origin.faction == fid and (job or (CANCELABLE[q.kind]
            and (q.state == "proposed" or q.state == "accepted"))) then
            q.state = "declined"
            q.cancelled = true
            q.endedT = now.t
            q.history = q.history or {}
            Store.push(q.history, { state = "cancelled", t = now.t }, 20)
            log("quest", q.id, q.kind, "cancelled (npc gone)", fid)
            notifyTarget(q)
        end
    end
end

function Quests.fail(q, now)
    setState(q, "failed", now, nil)
    q.cleanup = true
    cleanup(q)
end

-- ---------------------------------------------------------------- announce

-- 퀘스트 소식을 세력의 무전으로 전한다. 방향·거리는 대상 플레이어 기준.
-- 표시 문장은 클라이언트가 번역한다 (서버는 모드 번역을 못 찾고, 언어도 플레이어마다 다를 수 있다).
-- 반환: 마을(서버 언어 지도 이름, AI 용), 방향 코드("NE"), 거리(10 단위 숫자), 영어 방향
local DIR_CODES = { "E", "SE", "S", "SW", "W", "NW", "N", "NE" }
local DIR_WORDS = { E = "east", SE = "southeast", S = "south", SW = "southwest", W = "west", NW = "northwest",
                    N = "north", NE = "northeast" }
local function whereFrom(q, player)
    local dx, dy = q.cx - player:getX(), q.cy - player:getY()
    local angle = math.atan2(dy, dx) * 180 / math.pi
    local code = DIR_CODES[math.floor(((angle + 360 + 22.5) % 360) / 45) + 1]
    local distance = math.floor(math.sqrt(dx * dx + dy * dy) / 10) * 10
    local key = "MapLabel_" .. string.gsub(q.place.town, " ", "")
    local town = getText(key)
    if town == key then town = q.place.town end
    return town, code, distance, DIR_WORDS[code]
end
Quests.whereFrom = whereFrom

-- 보상 보급이 무엇의 대가인지 (예전 세이브는 rewardFor 로 찾는다)
function Quests.rewardKind(q)
    local origin = q.origin
    if not origin or origin.source ~= "reward" then return nil end
    if origin.rewardKind then return origin.rewardKind end
    local parent = origin.rewardFor and all()[origin.rewardFor]
    return parent and parent.kind or nil
end

function Quests.announce(q, player)
    local fid = q.origin and q.origin.faction
    if not fid or not Factions.byId[fid] then return end
    local _, code, distance, dirWord = whereFrom(q, player)
    local where = "a building near " .. q.place.town .. ", about " .. StoryEngine.intToString(distance)
        .. " tiles " .. dirWord .. " of you"

    local lt = { key = "IGUI_StoryEngine_RadioSay_" .. q.kind, args = {
        { t = "town", v = q.place.town }, { t = "dir", v = code }, { t = "num", v = distance },
        q.kind == "fetch" and { t = "item", v = q.items[1] } or { t = "s", v = "" } } }
    -- AI 가 다음 교신에서 읽는 기록 (영어)
    local text = "I left some supplies for you in " .. where .. "."
    if q.kind == "fetch" then
        text = "I need a " .. itemName(q.items[1]) .. " brought back from " .. where .. "."
    end
    if q.origin.source == "rescue" then
        lt.key = "IGUI_StoryEngine_RadioSay_rescue"
        text = "I picked up a distress call. Someone says they are trapped in " .. where
            .. ". I cannot get there. Can you check on them?"
    end
    local lineKind = q.kind
    if q.origin.source == "rescue" then lineKind = "rescue" end
    if q.origin.source == "reward" then
        lt.key = "IGUI_StoryEngine_RadioSay_reward"
        local kind = Quests.rewardKind(q)
        if kind then lt.alt, lt.key = lt.key, lt.key .. "_" .. kind end
        text = "Your payment is in " .. where .. "."
        lineKind = (kind == "trade" and "reward_trade") or (kind == "horde" and "reward_horde") or "reward"
    end
    -- 그 NPC 의 말투로 (Lines.lua). 없으면 위의 공통 문장
    local Lines = StoryEngine.Lines
    if Lines and Lines.has(fid, lineKind) then lt = Lines.lt(fid, lineKind, lt.args) end
    Radio.push(fid, { from = "npc", text = text, lt = lt, clock = Sensor.now().clock, quest = q.id })
end

-- ---------------------------------------------------------------- create / submit

-- kind: "supply_drop" | "fetch". origin: { source = "director"|"reward"|"debug", faction, rewardFor }
function Quests.create(kind, player, ps, tier, now, origin, itemsOverride)
    tier = math.max(1, math.min(Quests.MAX_TIER, math.floor(tier or 1)))
    local exclude = {}
    if ps.home and ps.home.building then exclude[ps.home.building] = true end
    if ps.prev and ps.prev.building then exclude[ps.prev.building] = true end
    local found = Quests.findForTier(math.floor(player:getX()), math.floor(player:getY()), tier, exclude)
    if not found then return nil, "no_building" end

    local d = Store.data()
    d.questSeq = d.questSeq + 1
    local def, room = found.def, found.room
    local cx = math.floor((def:getX() + def:getX2()) / 2)
    local cy = math.floor((def:getY() + def:getY2()) / 2)
    local place = Places.describe(cx, cy)
    place.inside = true
    place.rooms = roomNames(def)
    place.residential = def:isResidential() == true

    local items
    if itemsOverride then
        items = itemsOverride
    elseif kind == "fetch" then
        items = { Quests.FETCH_ITEMS[ZombRand(#Quests.FETCH_ITEMS) + 1] }
    else
        items = StoryEngine.Loot.roll(tier, origin and origin.faction)
    end
    origin = origin or { source = "debug" }
    origin.day = Store.dayIndex(now.dayKey)
    origin.date = now.date
    origin.clock = now.clock

    local q = {
        id = "Q" .. StoryEngine.intToString(d.questSeq),
        kind = kind, tier = tier, origin = origin,
        building = found.key, place = place,
        x = math.floor((room:getX() + room:getX2()) / 2),
        y = math.floor((room:getY() + room:getY2()) / 2),
        z = room:getZ(),
        cx = cx, cy = cy,
        bx1 = def:getX(), by1 = def:getY(), bx2 = def:getX2(), by2 = def:getY2(),
        radius = Quests.RADIUS, distance = math.floor(found.distance),
        target = ps.key, targetName = ps.name,
        state = "offered", createdT = now.t,
        deadlineT = now.t + Quests.deadlineMinutes(found.distance),
        spawned = false, items = items,
    }
    -- NPC 편지를 실을 수 있으면 물건에 더한다 (Letters.lua)
    if StoryEngine.Letters then
        local okL, errL = pcall(StoryEngine.Letters.attach, q, ps, now)
        if not okL then log("letter attach error:", errL) end
    end
    d.quests[q.id] = q
    Quests.waiting = Quests.waiting + 1
    trySpawn(q)
    note(ps, kind .. "_offered", q, now, nil)
    log("quest created", q.id, kind, "tier", tier, "for", ps.name, "at", q.x, q.y, place.town, "dist", q.distance)
    local ok, err = pcall(Quests.announce, q, player)
    if not ok then log("announce failed:", err) end
    notifyTarget(q)
    return q
end

-- 복구 작전 퀘스트를 정해진 장소(site = { x, y, name })에 만든다 (Ops.lua). 플레이어 위치와 상관없다.
-- kind: fetch(건물 보관함에 opts.item) | supply_drop(opts.items, 다 가져가면 완료) | horde(opts.size, 바로 accepted)
--       | defend(opts.needMin, opts.radius) | visit(opts.radius)
-- opts = { deadlineT, item, size, needMin, radius, building = 건물을 꼭 찾을지, search = 건물 찾는 반경 }
local function siteBuilding(site, opts)
    local found = nearestBuilding(site.x, site.y, site.x, site.y, opts.search or 60, {}, function(def)
        return not opts.nonResidential or def:isResidential() ~= true
    end)
    if not found and opts.nonResidential then
        found = nearestBuilding(site.x, site.y, site.x, site.y, opts.search or 60, {}, nil)
    end
    return found
end

-- 정찰 지점 하나: 건물 위치·경계·이름 (Quests.useScoutPoint 가 퀘스트에 옮긴다)
local function scoutPoint(found)
    local def, room = found.def, found.room
    local p = {
        building = found.key,
        x = math.floor((room:getX() + room:getX2()) / 2), y = math.floor((room:getY() + room:getY2()) / 2), z = room:getZ(),
        cx = math.floor((def:getX() + def:getX2()) / 2), cy = math.floor((def:getY() + def:getY2()) / 2),
        bx1 = def:getX(), by1 = def:getY(), bx2 = def:getX2(), by2 = def:getY2(),
    }
    p.place = Places.describe(p.cx, p.cy)
    p.place.rooms = roomNames(def)
    p.place.residential = def:isResidential() == true
    p.place.inside = true
    return p
end

-- 정찰 i번째 지점을 지금 목표로 (지도 표시·좀비 배치·진행은 이 지점 기준)
function Quests.useScoutPoint(q, i)
    local p = q.points and q.points[i]
    if not p then return end
    q.point = i
    q.building, q.x, q.y, q.z, q.cx, q.cy = p.building, p.x, p.y, p.z, p.cx, p.cy
    q.bx1, q.by1, q.bx2, q.by2 = p.bx1, p.by1, p.bx2, p.by2
    q.place = p.place
    q.sx, q.sy = p.cx, p.cy
    q.progress, q.entered, q.lastSiteT = 0, nil, nil
    q.spawned = false
    Quests.seen[q.id] = nil
    Quests.waiting = Quests.waiting + 1
end

function Quests.createSite(kind, ps, site, now, origin, opts)
    opts = opts or {}
    local found = siteBuilding(site, opts)
    if not found and (opts.building or kind == "scout") then return nil, "no_building" end
    local d = Store.data()
    d.questSeq = d.questSeq + 1
    local q = {
        id = "Q" .. StoryEngine.intToString(d.questSeq),
        kind = kind, tier = opts.tier or 3, origin = origin,
        radius = opts.radius or Quests.RADIUS, distance = 0,
        target = ps and ps.key or nil, targetName = ps and ps.name or nil,
        state = (kind == "fetch" or kind == "supply_drop") and "offered" or "accepted", createdT = now.t,
        deadlineT = opts.deadlineT or (now.t + 3 * 24 * 60), spawned = false,
    }
    origin.day = Store.dayIndex(now.dayKey)
    origin.date = now.date
    origin.clock = now.clock
    if found and (kind == "fetch" or kind == "horde" or kind == "supply_drop") then
        local def, room = found.def, found.room
        q.building = found.key
        q.x, q.y, q.z = math.floor((room:getX() + room:getX2()) / 2), math.floor((room:getY() + room:getY2()) / 2), room:getZ()
        q.cx, q.cy = math.floor((def:getX() + def:getX2()) / 2), math.floor((def:getY() + def:getY2()) / 2)
        q.bx1, q.by1, q.bx2, q.by2 = def:getX(), def:getY(), def:getX2(), def:getY2()
        q.place = Places.describe(q.cx, q.cy)
        q.place.rooms = roomNames(def)
        q.place.residential = def:isResidential() == true
    else
        -- 탑·설비처럼 건물이 아닌 곳: 그 자리 둘레를 구역으로
        q.x, q.y, q.z, q.cx, q.cy = site.x, site.y, 0, site.x, site.y
        q.bx1, q.by1, q.bx2, q.by2 = site.x - 4, site.y - 4, site.x + 4, site.y + 4
        q.place = Places.describe(site.x, site.y)
    end
    q.place.inside = kind == "fetch" or kind == "supply_drop"
    q.place.site = site.name
    if kind == "fetch" then
        q.items = { opts.item }
    elseif kind == "supply_drop" then
        q.items = opts.items or {}
    elseif kind == "horde" then
        q.size = Quests.zombieCount(opts.size or Quests.HORDE_SIZE[3])
        q.killsNeeded, q.killed = math.ceil(q.size * Quests.HORDE_CLEAR), 0
        q.radius = Quests.RADIUS
    elseif kind == "defend" then
        q.needMin, q.progress = opts.needMin or 360, 0
        q.radius = opts.radius or 20
        q.spawned = true
        q.sx, q.sy = q.cx, q.cy
    elseif kind == "visit" then
        q.radius = opts.radius or 10
        q.spawned = true
        q.sx, q.sy = q.cx, q.cy
    elseif kind == "scout" then
        -- 정찰 (Work.lua): 지점마다 좀비가 있는 건물에 들어가 정해진 시간 머문다. 3등급부터 밤에만 시간이 흐른다
        q.points = { scoutPoint(found) }
        for _, extra in ipairs(opts.more or {}) do
            local f = siteBuilding(extra, opts)
            if f then q.points[#q.points + 1] = scoutPoint(f) end
        end
        q.stayMin = opts.stayMin or 20
        q.night = opts.night or nil
        q.zombies = opts.zombies or 0
        q.radius = opts.radius or 10
        d.quests[q.id] = q
        Quests.useScoutPoint(q, 1)
    end
    d.quests[q.id] = q
    if not q.spawned then
        Quests.waiting = Quests.waiting + 1
        trySpawn(q)
    end
    log("op quest", q.id, kind, "at", q.cx, q.cy, tostring(q.place.town), site.name or "")
    notifyTarget(q)
    return q
end

-- 복구 작전 모금 (위치 없음). need = { { 아이템, 개수 } }
function Quests.createCollect(ps, need, now, origin, deadlineT)
    local d = Store.data()
    d.questSeq = d.questSeq + 1
    local items = {}
    for i, n in ipairs(need) do items[i] = { n[1], n[2] } end
    origin.day = Store.dayIndex(now.dayKey)
    origin.date = now.date
    origin.clock = now.clock
    local q = {
        id = "Q" .. StoryEngine.intToString(d.questSeq),
        kind = "collect", tier = 3, need = items, got = {}, origin = origin,
        target = ps and ps.key or nil, targetName = ps and ps.name or nil,
        state = "accepted", createdT = now.t, deadlineT = deadlineT,
    }
    d.quests[q.id] = q
    log("op quest", q.id, "collect", Quests.needText(q))
    notifyTarget(q)
    return q
end

-- 작전의 남은 퀘스트를 조용히 거둔다 (막 다시 시작·작전 끝). 놓은 물건은 정리한다
function Quests.cancelOp(opId, now, field)
    field = field or "op"
    for _, q in pairs(all()) do
        if q.origin and q.origin[field] == opId and Quests.isActive(q) then
            q.state = "declined"
            q.cancelled = true
            q.endedT = now.t
            q.history = q.history or {}
            Store.push(q.history, { state = "cancelled", t = now.t }, 20)
            if q.spawned and (q.kind == "fetch" or q.kind == "supply_drop") then q.cleanup = true end
            log("quest", q.id, q.kind, "cancelled (" .. field .. ")")
            notifyTarget(q)
        end
    end
end

-- 모금에 아직 필요한 수
function Quests.collectLeft(q, fullType)
    for _, n in ipairs(q.need or {}) do
        if n[1] == fullType then return math.max(0, n[2] - ((q.got or {})[fullType] or 0)) end
    end
    return 0
end

-- NPC 의 부탁 제안. entry: { player, ps }. 성공하면 퀘스트
-- opts = { prefer = 채울 자원, urgent = true } : 급한 부탁 (NpcEvents, 수락하면 기한 24시간)
function Quests.propose(player, ps, fid, tier, now, opts)
    opts = opts or {}
    tier = math.max(1, math.min(Quests.MAX_TIER, math.floor(tier or 1)))
    local prefer = opts.prefer or (StoryEngine.Life and StoryEngine.Life.needPrefer(fid)) or nil
    local need = opts.urgent and opts.prefer and StoryEngine.Needs.pick(fid, tier, opts.prefer, true) or nil
    if opts.when then
        need = StoryEngine.Needs.pick(fid, tier, nil, false, opts.when)
        if not need then return nil, "no_need" end
    end
    need = need or StoryEngine.Needs.pick(fid, tier, prefer)
    if not need then return nil, "no_need" end
    local d = Store.data()
    d.questSeq = d.questSeq + 1
    local items = Quests.pointsNeed(need.items, need.tier)
    local q = {
        id = "Q" .. StoryEngine.intToString(d.questSeq),
        kind = "deliver", tier = need.tier, need = items, why = need.why, urgent = opts.urgent or nil,
        favorCall = opts.favor and true or nil,
        origin = { source = "director", faction = fid, initiator = "npc",
                   day = Store.dayIndex(now.dayKey), date = now.date, clock = now.clock },
        target = ps.key, targetName = ps.name,
        state = "proposed", createdT = now.t, respondBy = now.t + Quests.RESPOND_MIN,
    }
    d.quests[q.id] = q
    note(ps, "deliver_proposed", q, now, nil)
    log("quest proposed", q.id, fid, Quests.needText(q), "for", ps.name)
    local tierWord = ({ "small", "modest", "good", "large", "huge" })[q.tier] or "small"
    local urgency = opts.urgent and (" This is URGENT: your people have almost run out and cannot wait; they have one day"
        .. " once they agree.") or ""
    if opts.favor then
        urgency = urgency .. " You are calling in the favor " .. tostring(opts.favor) .. " owes you from an earlier trade:"
            .. " you gave them goods for nothing. Remind them; refusing would be a real betrayal."
    end
    Radio.react(fid, "request", "You need " .. Quests.needText(q) .. " because " .. q.why
        .. "." .. urgency .. " Payment: a " .. tierWord .. " supply cache.",
        StoryEngine.Lines.fallback(fid, opts.favor and "favor_call" or "request",
            "Could you find me " .. Quests.needText(q) .. "? I will pay you back. Answer me on the radio.",
            { { t = "need", v = q.need } }), ps)
    notifyTarget(q)
    return q
end

-- 이야기 부탁의 대체 문장: 그 NPC 가 지금 사정을 먼저 말하고(이야기 장면 번역), 이어서 부탁한다
function Quests.storyFallback(fid, q, story)
    local fb = StoryEngine.Lines.fallback(fid, "request",
        "Could you find me " .. Quests.needText(q) .. "? I will pay you back. Answer me on the radio.",
        { { t = "need", v = q.need } })
    if type(fb) == "table" and story and story.node then
        fb.pre = { text = tostring(q.why or ""), lt = StoryEngine.Lines.story(story.node) }
    end
    return fb
end

-- 이야기·위기에서 정한 부탁 (Social.lua). spec = { tier, why, items }, extra = { story = {...} | crisis = id, silent }
function Quests.proposeCustom(player, ps, fid, spec, now, extra)
    extra = extra or {}
    local d = Store.data()
    d.questSeq = d.questSeq + 1
    local items = Quests.pointsNeed(spec.items, spec.tier)
    if #items == 0 then return nil end
    local q = {
        id = "Q" .. StoryEngine.intToString(d.questSeq),
        kind = "deliver", tier = math.max(1, math.min(Quests.MAX_TIER, spec.tier or 1)), need = items, why = spec.why,
        origin = { source = extra.crisis and "crisis" or "story", faction = fid, initiator = "npc",
                   story = extra.story or (extra.crisis and { crisis = extra.crisis }) or nil,
                   day = Store.dayIndex(now.dayKey), date = now.date, clock = now.clock },
        target = ps.key, targetName = ps.name,
        state = "proposed", createdT = now.t, respondBy = now.t + Quests.RESPOND_MIN,
    }
    d.quests[q.id] = q
    note(ps, "deliver_proposed", q, now, nil)
    log("quest proposed", q.id, fid, Quests.needText(q), "for", ps.name, extra.story and "story" or "crisis")
    if not extra.silent then
        local tierWord = ({ "small", "modest", "good", "large", "huge" })[q.tier] or "small"
        Radio.react(fid, "request", "You need " .. Quests.needText(q) .. " because " .. tostring(q.why)
            .. ". This is part of what is going on in your life right now. Payment: a " .. tierWord .. " supply cache.",
            Quests.storyFallback(fid, q, extra.story), ps)
    end
    notifyTarget(q)
    return q
end

-- 위기: 여러 세력이 동시에 부탁하고 플레이어가 하나를 고른다 (Social.startCrisis)
function Quests.proposeChoice(player, ps, crisis, now)
    local d = Store.data()
    d.questSeq = d.questSeq + 1
    local options, top = {}, 1
    for i, o in ipairs(crisis.options) do
        options[i] = { faction = o.faction, ask = o.ask, tier = o.tier, items = Quests.pointsNeed(o.items, o.tier, crisis.plain) }
        top = math.max(top, o.tier or 1)
    end
    local q = {
        id = "Q" .. StoryEngine.intToString(d.questSeq),
        kind = "choice", tier = top, crisis = crisis.id, situation = crisis.situation, options = options,
        origin = { source = "crisis", faction = crisis.options[1].faction, initiator = "crisis",
                   day = Store.dayIndex(now.dayKey), date = now.date, clock = now.clock },
        target = ps.key, targetName = ps.name,
        state = "proposed", createdT = now.t, respondBy = now.t + Quests.RESPOND_MIN,
    }
    d.quests[q.id] = q
    log("crisis proposed", q.id, crisis.id)
    notifyTarget(q)
    return q
end

-- 위기에서 한 세력을 고른다. 고른 부탁은 Social.onChoice 가 퀘스트로 만든다
function Quests.choose(player, qid, index)
    local q = all()[qid]
    if not q or q.kind ~= "choice" then return false, "no_quest" end
    if q.state ~= "proposed" then return false, "not_proposed" end
    local opt = q.options and q.options[math.floor(tonumber(index) or 0)]
    if not opt then return false, "bad_option" end
    local ps = Store.player(player)
    local now = Sensor.now()
    q.target, q.targetName = ps.key, ps.name
    q.chosen = opt.faction
    q.state = "completed"
    q.endedT = now.t
    q.history = q.history or {}
    Store.push(q.history, { state = "completed", t = now.t, by = ps.name }, 20)
    log("crisis choice", q.id, q.crisis, opt.faction, "by", ps.name)
    notifyTarget(q)
    if StoryEngine.Social then
        local ok, err = pcall(StoryEngine.Social.onChoice, q, opt, player)
        if not ok then log("crisis choice error:", err) end
    end
    return true
end

-- ---------------------------------------------------------------- 협박 (신뢰도가 아주 낮은 세력)

-- 세력이 물건을 내놓으라고 협박한다. 거절 버튼은 없다 (바로 accepted). 기한 안에 무전으로 제출하면 작은 대가,
-- 넘기지 못하면 보복(좀비 무리 또는 헬기)이 온다.
function Quests.demand(player, ps, fid, tier, now)
    tier = math.max(1, math.min(Quests.MAX_TIER, math.floor(tier or 1)))
    local need = StoryEngine.Needs.pick(fid, tier, StoryEngine.Life and StoryEngine.Life.needPrefer(fid) or nil)
    if not need then return nil, "no_need" end
    local d = Store.data()
    d.questSeq = d.questSeq + 1
    local items = Quests.pointsNeed(need.items, need.tier)
    local q = {
        id = "Q" .. StoryEngine.intToString(d.questSeq),
        kind = "extort", tier = need.tier, need = items, why = need.why,
        origin = { source = "director", faction = fid, initiator = "threat",
                   day = Store.dayIndex(now.dayKey), date = now.date, clock = now.clock },
        target = ps.key, targetName = ps.name,
        state = "accepted", createdT = now.t, deadlineT = now.t + Quests.EXTORT_MINUTES,
    }
    d.quests[q.id] = q
    note(ps, "extort_demanded", q, now, nil)
    log("extort", q.id, fid, Quests.needText(q), "for", ps.name)
    local hours = StoryEngine.intToString(math.floor(Quests.EXTORT_MINUTES / 60))
    Radio.react(fid, "event", "You have lost all patience with these players and you are extorting them. Demand "
        .. Quests.needText(q) .. ", handed over on the radio within " .. hours .. " hours, or you will make them pay: "
        .. "lure a horde of the dead onto them or bring a helicopter down on their heads. Be menacing and brief; "
        .. "do not ask politely and do not offer a trade.",
        StoryEngine.Lines.fallback(fid, "extort",
            "Hand over " .. Quests.needText(q) .. " within " .. hours .. " hours, or the dead come for you.",
            { { t = "need", v = q.need }, { t = "s", v = hours } }), ps)
    notifyTarget(q)
    return q
end

-- 협박 보복. 그 세력의 신뢰도를 가장 최근에 떨어뜨린 플레이어에게 간다 (없으면 협박받은 사람).
-- 대상이 접속해 있지 않으면 다음 접속 때 한다
function Quests.punish(q)
    local fid0 = q.origin and q.origin.faction
    if not q.punishKey then
        local ch = fid0 and Radio.channel(fid0)
        q.punishKey = (ch and ch.lastOffender) or q.target
    end
    local target = nil
    for _, p in ipairs(Sensor.players()) do
        if Store.playerKey(p) == q.punishKey then target = p end
    end
    if not target then
        q.punishPending = true
        return
    end
    q.punishPending = nil
    local ps = Store.player(target)
    local now = Sensor.now()
    local fid = q.origin and q.origin.faction
    local how
    -- 헬기는 무작위 플레이어에게 가므로 혼자 있을 때만 고른다
    if #Sensor.players() == 1 and ZombRand(2) == 0 then
        testHelicopter()
        how = "helicopter"
        for _, p in ipairs(Sensor.players()) do
            pcall(StoryEngine.Net.toClient, p, "directorNotice", { kind = "helicopter" })
        end
    else
        -- A-Life 가 있으면 그 세력의 무장 무리를 보낸다 (없거나 실패하면 추적 호드)
        local ALife = StoryEngine.ALife
        local okA, sent = false, false
        if ALife and fid then okA, sent = pcall(ALife.sendAttack, target, fid) end
        if okA and sent then
            how = "squad"
        else
            StoryEngine.Hunt.sendAt(target, "extort_punish")
            how = "horde"
        end
    end
    note(ps, "extort_punished", q, now, nil)
    log("extort punishment", q.id, how, "for", ps.name)
    if fid then
        local who = ps.name
        Radio.react(fid, "event", how == "squad"
            and ("They never paid what you demanded, so you sent your armed people after " .. who .. ", the one who last "
                .. "crossed you. They are on their way. Threaten them.")
            or how == "horde"
            and ("They never paid what you demanded, so you lured a pack of the dead onto " .. who .. ", the one who last "
                .. "crossed you. It will follow them. Tell them it is coming.")
            or ("They never paid what you demanded. A helicopter is now circling right over " .. who .. ", the one who last "
                .. "crossed you, drawing every dead thing around. Gloat."), nil, ps)
    end
end

-- 신뢰도가 높은 세력이 요청을 받고 대가 없이 준다 (Trade.fromReply). 가까운 건물(1등급 거리)에 둔다
function Quests.giftTrade(ps, fid, tier, goods, now)
    local player = nil
    for _, p in ipairs(Sensor.players()) do
        if Store.playerKey(p) == ps.key then player = p end
    end
    if not player then return nil end
    local q = Quests.create("supply_drop", player, ps, 1, now,
        { source = "gift_trade", faction = fid, initiator = "free" }, goods)
    if q then log("trade gift", q.id, fid, "tier", tier, "for", ps.name) end
    return q
end

-- 거래 제안 (Trade.fromReply 가 검증한 뒤 부른다). deal = { tier, category, goods, payCategory, price }
function Quests.proposeTrade(ps, fid, deal, now)
    local d = Store.data()
    d.questSeq = d.questSeq + 1
    local q = {
        id = "Q" .. StoryEngine.intToString(d.questSeq),
        kind = "trade", tier = deal.tier, category = deal.category, goods = deal.goods,
        payCategory = deal.payCategory, price = deal.price, basePrice = deal.price, haggles = 0, stockRef = deal.stockRef,
        origin = { source = "radio", faction = fid, initiator = "player",
                   day = Store.dayIndex(now.dayKey), date = now.date, clock = now.clock },
        target = ps.key, targetName = ps.name,
        state = "proposed", createdT = now.t, respondBy = now.t + Quests.RESPOND_MIN,
    }
    d.quests[q.id] = q
    log("trade proposed", q.id, fid, listText(q.goods), "for", q.payCategory, q.price)
    notifyTarget(q)
    return q
end

-- 흥정으로 바뀐 조건 (Trade.negotiate 가 검증한 뒤 부른다). 답할 시간은 다시 센다.
function Quests.reviseTrade(q, price, payCategory, now)
    q.oldPrice, q.oldPayCategory = q.price, q.payCategory
    q.price, q.payCategory = price, payCategory
    q.haggles = (q.haggles or 0) + 1
    q.respondBy = now.t + Quests.RESPOND_MIN
    log("trade revised", q.id, q.oldPrice, "->", price, payCategory, "round", q.haggles)
    notifyTarget(q)
end

-- 흥정 중에 물건을 바꾼다 (Trade.negotiate 가 신뢰도 한도·생활 자원을 검증한 뒤 부른다).
-- 새 물건의 값이 새 기준값이 되어, 그 뒤 흥정 하한선도 새 값을 기준으로 한다. 답할 시간은 다시 센다.
function Quests.swapTrade(q, category, tier, goods, price, payCategory, now)
    q.oldGoods, q.oldPrice, q.oldPayCategory = q.goods, q.price, q.payCategory
    q.category, q.tier, q.goods = category, tier, goods
    q.price, q.basePrice, q.payCategory = price, price, payCategory
    q.haggles = (q.haggles or 0) + 1
    q.respondBy = now.t + Quests.RESPOND_MIN
    log("trade swapped", q.id, listText(q.oldGoods), "->", listText(goods), "for", payCategory, price, "round", q.haggles)
    notifyTarget(q)
end

-- NPC 가 흥정 중에 제안을 거둔다. 플레이어가 거절한 것이 아니므로 신뢰도·반응 없이 끝낸다.
function Quests.withdrawTrade(q, now)
    q.state = "declined"
    q.withdrawn = true
    q.endedT = now.t
    q.history = q.history or {}
    Store.push(q.history, { state = "declined", t = now.t }, 20)
    log("trade withdrawn", q.id)
    notifyTarget(q)
end

-- 공용 주파수 거래: 여러 NPC 의 제안을 모은 퀘스트 (Trade.marketOffers 가 검증한 조건). 플레이어가 하나를 고른다.
-- 고르지 않아도 신뢰도·반응은 없다 (플레이어가 청한 것을 보여 줄 뿐). 새 제안이 오면 예전 것은 조용히 닫는다.
local function closeMarket(q, now, chosen, by)
    q.state = chosen and "completed" or "declined"
    q.chosen = chosen
    q.endedT = now.t
    q.history = q.history or {}
    Store.push(q.history, { state = q.state, t = now.t, by = by }, 20)
    log("market", q.id, chosen and ("chosen " .. chosen) or "closed", by or "")
    notifyTarget(q)
end

function Quests.proposeMarket(ps, deals, now)
    for _, old in pairs(all()) do
        if old.kind == "market" and old.state == "proposed" then closeMarket(old, now) end
    end
    local d = Store.data()
    d.questSeq = d.questSeq + 1
    local top = 1
    for _, o in ipairs(deals) do top = math.max(top, o.tier or 1) end
    local q = {
        id = "Q" .. StoryEngine.intToString(d.questSeq),
        kind = "market", tier = top, options = deals, selling = deals[1] and deals[1].selling and deals[1].payCategory or nil,
        origin = { source = "open", initiator = "player",
                   day = Store.dayIndex(now.dayKey), date = now.date, clock = now.clock },
        target = ps.key, targetName = ps.name,
        state = "proposed", createdT = now.t, respondBy = now.t + Quests.RESPOND_MIN,
    }
    d.quests[q.id] = q
    ps.lastMarketT = now.t
    log("market proposed", q.id, #deals, "offers for", ps.name)
    notifyTarget(q)
    return q
end

-- 제안 하나를 고른다. 그 NPC 와의 거래가 바로 수락된 상태로 생긴다 (대가 고르기·배송은 보통 거래와 같다).
function Quests.pickMarket(player, qid, index)
    local q = all()[qid]
    if not q or q.kind ~= "market" then return false, "no_quest" end
    if q.state ~= "proposed" then return false, "not_proposed" end
    local opt = q.options and q.options[math.floor(tonumber(index) or 0)]
    if not opt then return false, "bad_option" end
    local ps = Store.player(player)
    if Quests.openFor(ps.key, "trade") then return false, "open_deal" end
    if Factions.isGone(opt.faction) or Quests.openTrade(opt.faction) then return false, "seller_busy" end
    local now = Sensor.now()
    local trade = Quests.proposeTrade(ps, opt.faction, {
        tier = opt.tier, category = opt.category, goods = opt.goods, payCategory = opt.payCategory, price = opt.price,
        stockRef = opt.stockRef,
    }, now)
    trade.origin.source = "open"
    closeMarket(q, now, opt.faction, ps.name)
    -- 물건을 청한 것으로 센다 (고른 NPC 만, 판매는 세지 않음)
    if not q.selling and StoryEngine.Trade then
        local okR, errR = pcall(StoryEngine.Trade.recordRequest, opt.faction, ps)
        if not okR then log("trade request count error:", errR) end
    end
    q.tradeId = trade.id
    -- 그 NPC 채널에도 조건을 남긴다 (1:1 거래 제안과 같은 줄)
    StoryEngine.Radio.push(opt.faction, { from = "system", clock = now.clock, quest = trade.id,
        offer = { goods = trade.goods, payCategory = trade.payCategory, price = trade.price } })
    return Quests.respond(player, trade.id, true)
end

-- NPC 의 소탕 부탁. 위치를 먼저 정해 두고, 수락하면 무리를 배치한다.
function Quests.proposeHorde(player, ps, fid, tier, now)
    tier = math.max(1, math.min(Quests.MAX_TIER, math.floor(tier or 1)))
    local exclude = {}
    if ps.home and ps.home.building then exclude[ps.home.building] = true end
    if ps.prev and ps.prev.building then exclude[ps.prev.building] = true end
    local found = Quests.findForTier(math.floor(player:getX()), math.floor(player:getY()), tier, exclude)
    if not found then return nil, "no_building" end

    local d = Store.data()
    d.questSeq = d.questSeq + 1
    local def, room = found.def, found.room
    local cx = math.floor((def:getX() + def:getX2()) / 2)
    local cy = math.floor((def:getY() + def:getY2()) / 2)
    local place = Places.describe(cx, cy)
    place.inside = false
    place.rooms = roomNames(def)
    place.residential = def:isResidential() == true
    local size = Quests.zombieCount(Quests.HORDE_SIZE[tier])
    local q = {
        id = "Q" .. StoryEngine.intToString(d.questSeq),
        kind = "horde", tier = tier, building = found.key, place = place,
        x = math.floor((room:getX() + room:getX2()) / 2), y = math.floor((room:getY() + room:getY2()) / 2),
        z = room:getZ(), cx = cx, cy = cy,
        bx1 = def:getX(), by1 = def:getY(), bx2 = def:getX2(), by2 = def:getY2(),
        radius = Quests.RADIUS, distance = math.floor(found.distance),
        size = size, killsNeeded = math.ceil(size * Quests.HORDE_CLEAR), killed = 0,
        origin = { source = "director", faction = fid, initiator = "npc",
                   day = Store.dayIndex(now.dayKey), date = now.date, clock = now.clock },
        target = ps.key, targetName = ps.name,
        state = "proposed", createdT = now.t, respondBy = now.t + Quests.RESPOND_MIN,
        spawned = false,
    }
    d.quests[q.id] = q
    note(ps, "horde_proposed", q, now, nil)
    log("horde proposed", q.id, fid, size, "at", cx, cy, place.town, "dist", q.distance)
    local town, code, distance, dirEn = whereFrom(q, player)
    local tierWord = ({ "small", "modest", "good", "large", "huge" })[tier] or "small"
    -- AI 에게는 영어 방향과, 서버 언어로 된 마을 이름을 준다 (기준은 플레이어 위치)
    local spot = "a building near the town the players call " .. town
    if place.landmark then spot = spot .. " (landmark: " .. place.landmark .. ")" end
    Radio.react(fid, "request", "A horde of about " .. StoryEngine.intToString(size) .. " dead has gathered around "
        .. spot .. ". It is about " .. StoryEngine.intToString(distance) .. " tiles to the " .. dirEn .. " of the players (measured from them, "
        .. "not from you). Ask them to clear it out. Payment: a " .. tierWord .. " supply cache left near the spot. "
        .. "Use the town name as given.",
        StoryEngine.Lines.fallback(fid, "horde", "About " .. StoryEngine.intToString(size)
            .. " dead are gathered around a building near " .. place.town .. ", about " .. StoryEngine.intToString(distance)
            .. " tiles " .. dirEn .. " of you. Can you clear them out? I will leave you something for it.",
            { { t = "town", v = place.town }, { t = "dir", v = code }, { t = "num", v = distance }, { t = "num", v = size } }), ps)
    notifyTarget(q)
    return q
end

-- 퀘스트 전투 기록: 진행 중인 퀘스트 장소 반경 안에서 일어난 처치·부상을 붙인다 ("전투가 있었는지" 판정용)
Quests.FIGHT_RADIUS = 40

local function fightOf(q)
    q.fight = q.fight or { kills = 0, hurt = 0, bitten = false }
    return q.fight
end

local function nearQuest(q, x, y)
    if not Quests.isActive(q) or not Quests.hasLocation(q) then return false end
    return dist(x, y, q.cx or q.x, q.cy or q.y) <= Quests.FIGHT_RADIUS
end

-- 참여자: 퀘스트에 손을 보탠 플레이어 (장소 근처에 있었거나, 근처에서 좀비를 잡았거나, 물건을 꺼냈거나 제출함)
function Quests.addHelper(q, ps)
    if not q or not ps or not ps.key then return end
    q.helpers = q.helpers or {}
    q.helpers[ps.key] = ps.name
end

-- Sensor 10분 샘플: 진행 중인 위치 퀘스트 근처에 있던 플레이어를 참여자로 남긴다
function Quests.recordPresence(entries)
    for _, q in pairs(all()) do
        for _, e in ipairs(entries) do
            if nearQuest(q, e.s.x, e.s.y) then Quests.addHelper(q, e.ps) end
        end
    end
end

-- 참여하지 않은 사람이 그동안 한 일 (영어, AI 비아냥 재료)
function Quests.activityText(ps)
    local day = ps.day
    local class = day and Sensor.classify(day) or nil
    local town = ps.prev and Places.describe(ps.prev.x, ps.prev.y).town or nil
    local where = town and (" near " .. town) or ""
    if ps.prev and ps.prev.asleep then return "was asleep" .. where end
    if class == "stayed_home" then return "stayed home" .. where end
    if class == "local_scavenge" then return "was scavenging for themselves" .. where end
    if class == "expedition" then return "was off on their own long trip" .. where end
    if class == "combat_day" then
        return "was busy with their own fights" .. where .. " (" .. StoryEngine.intToString(day.kills or 0) .. " kills today)"
    end
    return "was somewhere else" .. where
end

-- Sensor 10분 샘플의 새 부상 (entries[i].newHarm)
function Quests.recordHarm(entries)
    for _, q in pairs(all()) do
        for _, e in ipairs(entries) do
            if #(e.newHarm or {}) > 0 and nearQuest(q, e.s.x, e.s.y) then
                local f = fightOf(q)
                for _, h in ipairs(e.newHarm) do
                    f.hurt = f.hurt + 1
                    if h.kind == "bitten" then f.bitten = true end
                end
            end
        end
    end
end

-- 전투 요약 (영어, AI 상황 설명용). 없으면 nil
function Quests.fightText(q)
    local f = q.fight
    if not f or (f.kills == 0 and f.hurt == 0) then return nil end
    local parts = {}
    if f.kills > 0 then parts[#parts + 1] = "they had to fight through about " .. StoryEngine.intToString(f.kills) .. " of the dead" end
    if f.bitten then parts[#parts + 1] = "someone was bitten"
    elseif f.hurt > 0 then parts[#parts + 1] = "someone got hurt" end
    return table.concat(parts, " and ")
end

-- 완료 반응에 붙일 참여 기록 (영어). 여러 명이 접속해 있을 때만 의미가 있다
function Quests.creditText(q)
    local helpers, names = q.helpers or {}, {}
    for _, name in pairs(helpers) do names[#names + 1] = name end
    table.sort(names)
    local idle = {}
    for _, p in ipairs(Sensor.players()) do
        local ps = Store.player(p)
        if not helpers[ps.key] then idle[#idle + 1] = ps.name .. " (" .. Quests.activityText(ps) .. ")" end
    end
    local text = ""
    if #names > 0 then
        text = " The ones who actually helped: " .. table.concat(names, ", ") .. ". Thank them by name."
    end
    if #idle > 0 then
        text = text .. " You MUST also call out by name each one who did not lift a finger, with one short jab each "
            .. "about what they were doing instead: " .. table.concat(idle, "; ") .. "."
    end
    return text
end

-- 좀비가 죽었을 때: 진행 중인 소탕 구역 안이면 세고, 가까운 퀘스트에는 전투로 기록한다
function Quests.onZombieDead(zombie)
    local zx, zy = zombie:getX(), zombie:getY()
    local killer, killerD = nil, nil
    for _, p in ipairs(Sensor.players()) do
        local d = dist(p:getX(), p:getY(), zx, zy)
        if d <= Quests.FIGHT_RADIUS and (not killerD or d < killerD) then killer, killerD = p, d end
    end
    for _, q in pairs(all()) do
        if nearQuest(q, zx, zy) then
            fightOf(q).kills = fightOf(q).kills + 1
            if killer then Quests.addHelper(q, Store.player(killer)) end
        end
    end
    local area = Quests.HORDE_AREA
    for _, q in pairs(all()) do
        if q.kind == "horde" and q.state == "accepted" and q.spawned
            and zx >= q.bx1 - area and zx <= q.bx2 + area and zy >= q.by1 - area and zy <= q.by2 + area then
            q.killed = (q.killed or 0) + 1
            if q.killed >= q.killsNeeded then
                Quests.completeHorde(q)
            else
                if q.killed % 3 == 0 then notifyTarget(q) end
                Quests.onProgress(q, "kill")
            end
        end
    end
end

-- 소탕 완료: 가장 가까운 플레이어 근처에 보상 보급
function Quests.completeHorde(q)
    local now = Sensor.now()
    local best, bestD = nil, nil
    for _, p in ipairs(Sensor.players()) do
        local d = dist(p:getX(), p:getY(), q.cx, q.cy)
        if not bestD or d < bestD then best, bestD = p, d end
    end
    local ps = best and Store.player(best) or Store.data().players[q.target]
    if best and not Quests.isManaged(q) then
        Quests.create("supply_drop", best, ps, 1, now,
            { source = "reward", faction = q.origin and q.origin.faction, rewardFor = q.id, rewardKind = q.kind }, StoryEngine.Loot.roll(q.tier, q.origin and q.origin.faction))
    end
    setState(q, "completed", now, ps and { ps = ps } or nil)
end

-- 대가를 다 받았을 때 (Trade.pay). 물건은 가까운 건물(1~2등급 거리)에 두고 간다.
function Quests.completeTrade(player, q)
    local now = Sensor.now()
    local ps = Store.player(player)
    Quests.addHelper(q, ps)
    local distanceTier = q.tier <= 2 and 1 or 2
    -- 외상(Work.lua)은 물건을 이미 보냈다
    local delivery = nil
    if not q.credit then
        delivery = Quests.create("supply_drop", player, ps, distanceTier, now,
            { source = "reward", faction = q.origin and q.origin.faction, rewardFor = q.id, rewardKind = q.kind }, q.goods)
    end
    setState(q, "completed", now, { ps = ps })
    return true, delivery
end

-- 부탁·거래 제안에 대한 수락/거절. 멀티에서는 답한 사람이 대상이 된다.
function Quests.respond(player, qid, accept)
    local q = all()[qid]
    if not q or (q.kind ~= "deliver" and q.kind ~= "trade" and q.kind ~= "horde" and q.kind ~= "named") then
        return false, "no_quest"
    end
    if q.state ~= "proposed" then return false, "not_proposed" end
    local ps = Store.player(player)
    local now = Sensor.now()
    q.target, q.targetName = ps.key, ps.name
    if accept then
        q.deadlineT = now.t + ((q.kind == "horde" or q.kind == "named") and Quests.deadlineMinutes(q.distance or 0)
            or (q.urgent and 24 * 60) or Quests.deliverMinutes(q.tier))
        setState(q, "accepted", now, { ps = ps })
    else
        setState(q, "declined", now, { ps = ps }, "declined")
    end
    return true
end

-- 품목 점수 항목에 낼 물건: chosen(플레이어가 고른 아이템 id 목록)이 있으면 그것만, 없으면 싼 것부터 자동으로.
-- 그 품목이고 낼 수 있는 물건(Value.payable: 퀘스트 물건·채집 재료·상한 것·입은 것 제외)만. 가치가 모자라면 nil
local function pointItems(player, cat, points, chosen, used, minTier)
    local V = StoryEngine.Value
    local list = {}
    if chosen and #chosen > 0 then
        local inv = player:getInventory()
        for _, id in ipairs(chosen) do
            local it = inv:getItemWithIDRecursiv(tonumber(id) or -1)
            if it and not used[it] and V.pointPayable(player, it, cat, minTier) then list[#list + 1] = it end
        end
    else
        for _, it in ipairs(V.pointItems(player, cat, minTier)) do
            if not used[it] and not player:isEquipped(it) then list[#list + 1] = it end
        end
        table.sort(list, function(a, b) return V.pointValue(a) < V.pointValue(b) end)
    end
    local out, total = {}, 0
    for _, it in ipairs(list) do
        if total >= points then break end
        out[#out + 1] = it
        total = total + V.pointValue(it)
    end
    if total + 0.001 < points then return nil end
    return out
end

-- 부탁 물건을 인벤토리에서 꺼낸다. 장착하지 않은 것부터 쓴다. 모자라면 아무것도 꺼내지 않고 false
-- 품목 점수 항목("cat:food")은 chosen(고른 아이템 id) 또는 자동으로 그 품목 물건을 가치 합만큼
local function takeNeed(player, need, chosen)
    local inv = player:getInventory()
    local plan, used = {}, {}
    for _, n in ipairs(need) do
        if Quests.pointCat(n) then
            local picked = pointItems(player, Quests.pointCat(n), n[2], chosen, used, n[3])
            if not picked then return false end
            for _, it in ipairs(picked) do used[it] = true end
            plan[#plan + 1] = picked
        end
    end
    for _, n in ipairs(need) do
        if not Quests.pointCat(n) then
            local list = inv:getAllTypeRecurse(n[1])
            local free, equipped = {}, {}
            for i = 0, list:size() - 1 do
                local it = list:get(i)
                local mod = it:getModData()
                local tagged = mod and mod.storyQuest and all()[mod.storyQuest]
                if not used[it] and not (tagged and Quests.isActive(tagged)) then
                    if player:isEquipped(it) then equipped[#equipped + 1] = it else free[#free + 1] = it end
                end
            end
            if #free + #equipped < n[2] then return false end
            local picked = {}
            for _, it in ipairs(free) do if #picked < n[2] then picked[#picked + 1] = it end end
            for _, it in ipairs(equipped) do if #picked < n[2] then picked[#picked + 1] = it end end
            plan[#plan + 1] = picked
        end
    end
    for _, picked in ipairs(plan) do
        for _, it in ipairs(picked) do
            StoryEngine.Items.remove(it, player)
        end
    end
    return true
end

-- 무전으로 제출 (회수 물건 / 부탁 물건). 성공하면 true, 보상 퀘스트 / 실패하면 false, 오류 코드
-- 모금: 가진 것 중 필요한 만큼 꺼낸다 (장착하지 않은 것부터). 보낸 개수
local function takeSome(player, q)
    local inv = player:getInventory()
    local gave = 0
    for _, n in ipairs(q.need or {}) do
        local left = Quests.collectLeft(q, n[1])
        if left > 0 then
            local list = inv:getAllTypeRecurse(n[1])
            local free, equipped = {}, {}
            for i = 0, list:size() - 1 do
                local it = list:get(i)
                local mod = it:getModData()
                if not (mod and mod.storyQuest) then
                    if player:isEquipped(it) then equipped[#equipped + 1] = it else free[#free + 1] = it end
                end
            end
            local chosen = {}
            for _, it in ipairs(free) do if #chosen < left then chosen[#chosen + 1] = it end end
            for _, it in ipairs(equipped) do if #chosen < left then chosen[#chosen + 1] = it end end
            for _, it in ipairs(chosen) do StoryEngine.Items.remove(it, player) end
            q.got[n[1]] = (q.got[n[1]] or 0) + #chosen
            gave = gave + #chosen
        end
    end
    return gave
end

function Quests.contribute(player, q)
    if q.state ~= "accepted" then return false, "not_active" end
    if not Factions.canTalk(player) then return false, "no_radio" end
    q.got = q.got or {}
    local gave = takeSome(player, q)
    if gave == 0 then return false, "missing_items" end
    local ps = Store.player(player)
    Quests.addHelper(q, ps)
    q.givers = q.givers or {}
    q.givers[ps.name] = (q.givers[ps.name] or 0) + gave
    log("op collect", q.id, ps.name, gave)
    local done = true
    for _, n in ipairs(q.need) do
        if Quests.collectLeft(q, n[1]) > 0 then done = false end
    end
    if done then
        setState(q, "completed", Sensor.now(), { ps = ps })
    else
        if StoryEngine.Ops and Quests.isOp(q) then pcall(StoryEngine.Ops.onContribution, q, ps, gave) end
        notifyTarget(q)
    end
    return true
end

-- itemIds: 품목 점수 부탁에 낼 물건으로 플레이어가 고른 아이템 id (없으면 싼 것부터 자동)
function Quests.submit(player, qid, itemIds)
    local q = all()[qid]
    if q and q.kind == "collect" then return Quests.contribute(player, q) end
    if not q or (q.kind ~= "fetch" and q.kind ~= "deliver" and q.kind ~= "extort" and q.kind ~= "named") then
        return false, "no_quest"
    end
    if q.kind == "deliver" or q.kind == "extort" then
        if q.state ~= "accepted" then return false, "not_active" end
        if not Factions.canTalk(player) then return false, "no_radio" end
        if not takeNeed(player, q.need, type(itemIds) == "table" and itemIds or nil) then return false, "missing_items" end
        local now = Sensor.now()
        local ps = Store.player(player)
        Quests.addHelper(q, Store.player(player))
        -- 협박에 응하면 작은 대가(1등급)만 준다
        local rewardTier = q.kind == "extort" and 1 or q.tier
        local reward = Quests.create("supply_drop", player, ps, rewardTier, now,
            { source = "reward", faction = q.origin and q.origin.faction, rewardFor = q.id, rewardKind = q.kind })
        setState(q, "completed", now, { ps = ps })
        return true, reward
    end
    if not Quests.isActive(q) then return false, "not_active" end
    if not Factions.canTalk(player) then return false, "no_radio" end
    local held = findInInventory(player, q)
    if #held == 0 then return false, "no_item" end
    Quests.addHelper(q, Store.player(player))
    for _, it in ipairs(held) do StoryEngine.Items.remove(it, player) end
    local now = Sensor.now()
    local ps = Store.player(player)
    setState(q, "completed", now, { ps = ps })
    if Quests.isManaged(q) then return true end
    local reward = Quests.create("supply_drop", player, ps, q.tier, now,
        { source = "reward", faction = q.origin and q.origin.faction, rewardFor = q.id, rewardKind = q.kind })
    return true, reward
end

-- ---------------------------------------------------------------- tracking

Quests.DEFEND_STEP_MAX = 15       -- 샘플 사이가 이보다 길면(접속 끊김 등) 이만큼만 쌓는다

-- 방어·방문: 현장 반경 안에 있는 사람 (10분 샘플)
-- 정찰 밤 시간 (게임 시각): 21:00 ~ 04:59
Quests.NIGHT_FROM, Quests.NIGHT_TO = 21, 5
function Quests.isNight()
    local h = getGameTime():getHour()
    return h >= Quests.NIGHT_FROM or h < Quests.NIGHT_TO
end

local function nearRect(q, x, y, r)
    local dx = math.max((q.bx1 or q.cx) - x, 0, x - (q.bx2 or q.cx))
    local dy = math.max((q.by1 or q.cy) - y, 0, y - (q.by2 or q.cy))
    return math.sqrt(dx * dx + dy * dy) <= r
end

-- 정찰: 지금 지점의 건물에 한 번 들어가고, 건물 둘레(반경)에 정해진 시간 머물면 다음 지점으로
function Quests.trackScout(q, entries, now)
    local here = {}
    for _, e in ipairs(entries) do
        if e.s.building == q.building or nearRect(q, e.s.x, e.s.y, q.radius or 10) then
            here[#here + 1] = e
            Quests.addHelper(q, e.ps)
            if e.s.building == q.building and not q.entered then
                q.entered = true
                Quests.onProgress(q, "scout_entered")
            end
        end
    end
    q.present = #here
    local step = math.min(Quests.DEFEND_STEP_MAX, math.max(0, now.t - (q.lastSiteT or now.t)))
    q.lastSiteT = now.t
    if #here == 0 then return end
    if q.night and not Quests.isNight() then
        q.waitNight = true
        if q.nightNoted ~= q.point then
            q.nightNoted = q.point
            Quests.onProgress(q, "scout_night")
        end
        return
    end
    q.waitNight = nil
    q.progress = math.min(q.stayMin or 20, (q.progress or 0) + step)
    if not q.entered and q.progress >= (q.stayMin or 20) and q.enterNoted ~= q.point then
        q.enterNoted = q.point
        Quests.onProgress(q, "scout_enter")
    end
    if q.entered and q.progress >= (q.stayMin or 20) then
        local done = q.point or 1
        log("scout point done", q.id, done, "/", #(q.points or {}))
        if done >= #(q.points or {}) then
            setState(q, "completed", now, here[1])
        else
            Quests.useScoutPoint(q, done + 1)
            notifyTarget(q)
            Quests.onProgress(q, "scout_next", { done = done })
        end
    end
end

function Quests.trackSite(q, entries, now)
    if q.kind == "scout" then return Quests.trackScout(q, entries, now) end
    local here = {}
    for _, e in ipairs(entries) do
        if dist(e.s.x, e.s.y, q.cx, q.cy) <= q.radius then
            here[#here + 1] = e
            Quests.addHelper(q, e.ps)
        end
    end
    q.present = #here
    if q.kind == "visit" then
        if #here > 0 and q.carry then
            -- 배달 대행 (Work.lua): 꾸러미를 가진 사람이 와야 끝난다. 꾸러미는 건네준다
            for _, e in ipairs(here) do
                local held = e.player and findInInventory(e.player, { items = q.carry.items, id = q.carry.qid }) or {}
                if #held > 0 then
                    for _, it in ipairs(held) do StoryEngine.Items.remove(it, e.player) end
                    setState(q, "completed", now, e)
                    return
                end
            end
            return
        end
        if #here > 0 then setState(q, "completed", now, here[1]) end
        return
    end
    local step = math.min(Quests.DEFEND_STEP_MAX, math.max(0, now.t - (q.lastSiteT or now.t)))
    q.lastSiteT = now.t
    if #here > 0 then
        local before = math.floor((q.progress or 0) * 4 / q.needMin)
        q.progress = (q.progress or 0) + step
        if q.progress >= q.needMin then
            setState(q, "completed", now, here[1])
        elseif math.floor(q.progress * 4 / q.needMin) > before then
            Quests.onProgress(q, "defend_pct", { pct = math.floor(q.progress * 4 / q.needMin) * 25,
                                                 left = math.ceil(q.needMin - q.progress) })
        end
    end
end

-- 놓은 물건을 챙겼나. 보급(supply_drop)은 하나라도 가져가면 완료 (2026-10-06, 나머지는 그대로 남는다),
-- 그 밖(찾아오기 꾸러미 등)은 모두 가져가야. left = 놓은 자리에 남은 태그 아이템 수 (칸이 안 로드됐으면 nil)
function Quests.takenEnough(q, left)
    if left == nil or not q.spawned then return false end
    if left == 0 then return true end
    return q.kind == "supply_drop" and q.placed ~= nil and left < #q.placed
end

function Quests.track(entries, now)
    local okHarm, errHarm = pcall(Quests.recordHarm, entries)
    if not okHarm then log("quest harm error:", errHarm) end
    local okP, errP = pcall(Quests.recordPresence, entries)
    if not okP then log("quest presence error:", errP) end
    if not Quests.ready then
        Quests.ready = true
        for _, q in pairs(all()) do
            if LEGACY[q.state] then q.state = LEGACY[q.state] end
            q.kind = q.kind or "supply_drop"
            q.deadlineT = q.deadlineT or q.expiresT or now.t
            -- 유품 회수 퀘스트는 없앴다 (2026-10-06): 예전 세이브에 남은 것은 조용히 거둔다
            if q.origin and q.origin.source == "recover" and Quests.isActive(q) then
                q.state, q.endedT = "declined", now.t
                q.history = q.history or {}
                Store.push(q.history, { state = "cancelled", t = now.t }, 20)
                if q.spawned then q.cleanup = true end
                log("old recover quest cancelled", q.id)
            end
        end
    end

    for _, q in pairs(all()) do
        if q.state == "proposed" and q.kind == "market" then
            if now.t > (q.respondBy or 0) then closeMarket(q, now) end
        elseif q.state == "proposed" then
            if now.t > (q.respondBy or 0) then setState(q, "declined", now, nil, "ignored") end
        elseif Quests.isActive(q) and not Quests.hasLocation(q) then
            if now.t > q.deadlineT then setState(q, "failed", now, nil) end
        elseif Quests.isActive(q) then
            trySpawn(q)
            for _, e in ipairs(entries) do
                if q.state == "offered" and dist(e.s.x, e.s.y, q.cx or q.x, q.cy or q.y) <= q.radius then
                    setState(q, "approached", now, e)
                end
                if (q.state == "offered" or q.state == "approached") and e.s.building == q.building then
                    setState(q, "entered", now, e)
                end
            end
            if q.kind == "defend" or q.kind == "visit" or q.kind == "scout" then Quests.trackSite(q, entries, now) end
            local left = (q.kind ~= "horde" and q.kind ~= "defend" and q.kind ~= "visit" and q.kind ~= "named"
                and q.kind ~= "scout")
                and atSpot(q, false) or nil
            if Quests.takenEnough(q, left) and q.state ~= "retrieved" then
                local best, bestD = nil, 40
                for _, e in ipairs(entries) do
                    local dd = dist(e.s.x, e.s.y, q.sx, q.sy)
                    if dd < bestD then best, bestD = e, dd end
                end
                if q.kind == "fetch" then
                    setState(q, "retrieved", now, best)
                else
                    setState(q, "completed", now, best)
                end
            end
            if Quests.isActive(q) and now.t > q.deadlineT then
                Quests.fail(q, now)
            end
        elseif q.cleanup then
            cleanup(q)
        end
        if q.punishPending then
            local ok, err = pcall(Quests.punish, q)
            if not ok then log("extort punish error:", err) end
        end
    end
end

-- 클라이언트 퀘스트 탭·지도용 목록: 서버의 모든 퀘스트 (진행 중 + 최근 끝난 것). 누가 받았든 함께 보고,
-- 누구나 수락·제출·지불할 수 있다. psKey 는 표시용 (내가 받은 퀘스트 구분)
function Quests.listFor(psKey, now)
    local active, done = {}, {}
    for _, q in pairs(all()) do
        do
            local state = LEGACY[q.state] or q.state
            local item = {
                id = q.id, kind = q.kind or "supply_drop", state = state, tier = q.tier or 1,
                origin = q.origin,
                town = q.place and q.place.town, landmark = q.place and q.place.landmark,
                rooms = q.place and q.place.rooms, residential = q.place and q.place.residential,
                x = q.cx or q.x, y = q.cy or q.y,
                spawned = q.spawned == true, container = q.containerType,
                sx = q.sx, sy = q.sy, sz = q.sz, containerSprite = q.containerSprite,
                rewardKind = Quests.rewardKind(q), fight = q.fight, helpers = q.helpers,
                items = q.placed or q.items, need = q.need,
                hoursLeft = math.max(0, math.floor(((q.deadlineT or q.expiresT or now.t) - now.t) / 60)),
                respondHours = q.respondBy and math.max(0, math.floor((q.respondBy - now.t) / 60)) or nil,
                created = q.createdT,
                owner = q.targetName, mine = q.target == psKey or nil,
            }
            if not Quests.hasLocation(q) then item.x, item.y = nil, nil end
            if q.kind == "trade" then
                item.goods, item.payCategory, item.price, item.category = q.goods, q.payCategory, q.price, q.category
                item.basePrice, item.withdrawn = q.basePrice, q.withdrawn
                local Trade = StoryEngine.Trade
                item.haggleLeft = Trade and math.max(0, Trade.MAX_HAGGLES - (q.haggles or 0)) or 0
                -- 다른 대가 (Work.lua)
                item.payKind, item.credit, item.favor, item.workId = q.payKind, q.credit, q.favor, q.workId
                item.workBonus = q.workBonus
                item.goodsKept, item.parcelEnd = q.goodsKept, q.parcel
                local Work = StoryEngine.Work
                if Work and (state == "proposed" or (state == "accepted" and not q.payKind)) then
                    item.workOptions, item.workWeekLeft = Work.options(q)
                end
            end
            if Quests.isWork(q) then
                item.work = { how = q.origin.workKind, stage = q.origin.stage, trade = q.origin.work,
                              faction = q.origin.faction }
                item.site = nil
            end
            if q.kind == "visit" or q.kind == "defend" then item.radius = q.radius end
            item.favorCall = q.favorCall
            if q.kind == "named" then item.person, item.slain = q.person, q.slain end
            if q.origin and q.origin.holiday then item.holiday = q.origin.holiday end
            if q.kind == "horde" then
                item.size, item.killed, item.killsNeeded = q.size, q.killed or 0, q.killsNeeded
            end
            if q.kind == "collect" then item.got, item.givers = q.got, q.givers end
            if q.kind == "defend" then
                item.progress, item.needMin, item.waves, item.present = q.progress or 0, q.needMin, q.waves or 0, q.present
            end
            if q.kind == "defend" or q.kind == "visit" or q.kind == "scout" then item.radius = q.radius end
            if q.kind == "scout" then
                item.point, item.points, item.progress, item.needMin = q.point or 1, #(q.points or {}), q.progress or 0, q.stayMin
                item.entered, item.night, item.waitNight, item.present = q.entered, q.night, q.waitNight, q.present
            end
            if q.carry then item.parcel = q.parcel end
            item.cancelled = q.cancelled
            if Quests.isOp(q) then
                item.op = { kind = q.origin.opKind, act = q.origin.act, acts = q.origin.acts, retry = q.origin.retry }
                item.site = q.place and q.place.site
            end
            if Quests.isSaga(q) then
                item.saga = { kind = q.origin.sagaKind, stage = q.origin.stage, stages = q.origin.stages,
                              stageId = q.origin.stageId, role = q.origin.role }
                item.site = q.place and q.place.site
            end
            if q.kind == "choice" then
                item.crisis, item.chosen, item.options = q.crisis, q.chosen, {}
                for i, o in ipairs(q.options or {}) do
                    item.options[i] = { faction = o.faction, tier = o.tier, need = o.items }
                end
            end
            if q.kind == "market" then
                item.chosen, item.offers, item.selling = q.chosen, {}, q.selling
                for i, o in ipairs(q.options or {}) do
                    item.offers[i] = { faction = o.faction, goods = o.goods, payCategory = o.payCategory,
                                       price = o.price, tier = o.tier, bonus = o.bonus }
                end
            end
            if q.origin and q.origin.story then item.story = q.origin.story.crisis and "crisis" or "story" end
            item.urgent = q.urgent
            if ACTIVE[state] or state == "proposed" then active[#active + 1] = item else done[#done + 1] = item end
        end
    end
    table.sort(active, function(a, b)
        local pa, pb = a.state == "proposed", b.state == "proposed"
        if pa ~= pb then return pa end
        return (a.created or 0) > (b.created or 0)
    end)
    table.sort(done, function(a, b) return (a.created or 0) > (b.created or 0) end)
    for i = 1, math.min(#done, 20) do active[#active + 1] = done[i] end
    return active
end

-- 디버그: 퀘스트 목록 요약
function Quests.statusText()
    local parts = {}
    for _, q in pairs(all()) do
        local spot = ""
        if q.spawned and q.sx and Quests.isActive(q) and q.kind ~= "horde" then
            local left = atSpot(q, false)
            spot = " " .. tostring(q.containerType or "floor") .. "@" .. q.sx .. "," .. q.sy .. " left="
                .. (left == nil and "unloaded" or tostring(left))
        end
        parts[#parts + 1] = q.id .. " " .. tostring(q.kind) .. " " .. q.state .. " " .. tostring(q.place and q.place.town)
            .. (q.spawned and " spawned" or " waiting") .. spot
    end
    if #parts == 0 then return "no quests" end
    return table.concat(parts, " | ")
end

Sensor.listeners.tick[#Sensor.listeners.tick + 1] = Quests.track

Events.OnZombieDead.Add(function(zombie)
    local ok, err = pcall(Quests.onZombieDead, zombie)
    if not ok then log("zombie dead error:", err) end
end)

-- 목표 칸이 로드된 순간을 기록만 하고, 실제 배치와 정리는 EveryOneMinute 에서 한다.
Events.LoadGridsquare.Add(function(sq)
    if not Quests.ready or Quests.waiting <= 0 then return end
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    for _, q in pairs(all()) do
        if not q.spawned and q.x == x and q.y == y and q.z == z and not Quests.seen[q.id] then
            Quests.seen[q.id] = StoryEngine.nowMs()
        end
    end
end)

Events.EveryOneMinute.Add(function()
    if not Quests.ready then return end
    local waiting = 0
    for _, q in pairs(all()) do
        local ok, err = true, nil
        if not q.spawned and Quests.isActive(q) and Quests.hasLocation(q) then
            ok, err = pcall(trySpawn, q)
            if not q.spawned then waiting = waiting + 1 end
        elseif q.cleanup then
            ok, err = pcall(cleanup, q)
        end
        if not ok then log("quest minute error:", err) end
    end
    Quests.waiting = waiting
end)

return Quests
