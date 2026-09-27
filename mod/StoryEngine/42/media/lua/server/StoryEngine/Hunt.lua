-- 추적 무리 (서버 측 전용). 이 모드가 만든 무리만 대상 플레이어를 끝까지 쫓는다.
--
-- 게임은 플레이어 근처(로드된 칸)에만 실제 좀비를 두고, 멀어지면 좀비를 내려 버린다. 그래서 무리를
-- "기억된 무리"(ModData hunts)로 관리한다.
--   실제: 좀비가 로드돼 있다 -> 게임 내 1분마다 대상에게 경로를 다시 준다 (pathToCharacter, 가까우면 spotted)
--   가상: 좀비가 없다(아직 멀거나 내려감) -> 남은 수와 위치만 기억하고 걷는 속도로 대상 쪽으로 옮긴다.
--         대상에게 SPAWN_DIST 안으로 들어오고 그 칸이 로드돼 있으면 남은 수만큼 실제 좀비로 만든다
--         (세이브에 남은 같은 무리의 좀비가 근처에 있으면 새로 만들지 않고 다시 데려온다)
-- 끝: 모두 처치(OnZombieDead, 좀비 modData.storyHunt), 대상 캐릭터 사망. 대상이 접속해 있지 않으면 멈춘다.
-- 멀티: 좀비는 근처 플레이어의 클라이언트가 소유하고 움직인다(IsoZombie:getOwnerPlayer). 서버가 내린 경로는 무시되는 것으로
-- 보여서(42.20.4 인게임 호스트: 무리 위치가 전혀 변하지 않음) 무리 좀비를 소유자별로 묶어 그 클라이언트에 "huntChase"
-- (좀비 online ID 목록 + 대상 플레이어 online ID)를 보내고, 클라이언트가 직접 쫓게 한다 (client/StoryEngine/HuntClient.lua).

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Net"

local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local log = StoryEngine.log

local Hunt = {
    live = {},      -- id -> { zombies = { IsoZombie, ... } }  (메모리에만)
}
StoryEngine.Hunt = Hunt

Hunt.SPEED = 2            -- 가상 이동 속도 (타일 / 게임 분)
Hunt.SPAWN_DIST = 45      -- 이 거리 안에 들어오면 실제 좀비로
Hunt.MIN_SPAWN_DIST = 30  -- 눈앞에 생기지 않도록 이보다 가까우면 이 거리까지 물려서 만든다
Hunt.SPOT_DIST = 12       -- 이보다 가까우면 경로 대신 "발견" 상태로
Hunt.ADOPT_RADIUS = 60
-- 무리가 서버 좀비 목록에서 잠깐 안 보일 때가 있다 (42.20.4 인게임 호스트: 15타일 거리에서 1분 동안 사라졌다가 다시 보임,
-- 소유권 이동 등으로 추정). 바로 다시 만들면 중복이 생기므로:
Hunt.MISSING_TICKS = 3        -- 이만큼(게임 분) 연속으로 안 보여야 사라진 것으로 본다
Hunt.UNLOAD_DIST = 50         -- 마지막 위치가 대상에게서 이보다 가까우면 내려갔을 리 없다 -> 다시 만들지 않고 기다린다
Hunt.LOST_TICKS = 30          -- 가까운데 이만큼 계속 안 보이면 (기록 없이 죽었거나 잃어버림) 추적을 끝낸다
Hunt.SIZE_BY_STAGE = { 20, 40, 60 }   -- 진행 단계(서버 경과 일수)별 한 무리의 좀비 수 (플레이어마다 한 무리)
Hunt.START_DIST = { 50, 80 }          -- 대상에게서 이 거리의 무작위 방향에서 출발
-- 한 곳에 오래 머물기: STAY_RADIUS 안에 STAY_DAYS 이상 있으면 매일 확률을 올려 가며 추적 무리를 보낸다
Hunt.STAY_RADIUS = 150
Hunt.STAY_DAYS = 4
Hunt.STAY_BASE = 30                   -- 4일째 확률(%), 이후 하루마다 +STAY_STEP
Hunt.STAY_STEP = 10

function Hunt.sizeNow()
    return Hunt.SIZE_BY_STAGE[Store.stage()] or Hunt.SIZE_BY_STAGE[1]
end

-- player 에게 무작위 방향 START_DIST 거리에서 출발하는 추적 무리를 붙인다
function Hunt.sendAt(player, reason, size)
    local angle = ZombRandFloat(0, math.pi * 2)
    local d = ZombRand(Hunt.START_DIST[1], Hunt.START_DIST[2] + 1)
    local sx, sy = player:getX() + math.cos(angle) * d, player:getY() + math.sin(angle) * d
    Hunt.start(player, size or Hunt.sizeNow(), sx, sy, reason)
    return angle
end

local function hunts()
    local d = Store.data()
    d.hunts = d.hunts or {}
    d.huntSeq = d.huntSeq or 0
    return d.hunts
end

local function dist(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

local function targetOf(h)
    for _, p in ipairs(Sensor.players()) do
        if Store.playerKey(p) == h.target then return p end
    end
    return nil
end

-- 새 추적 무리. (x, y) 에서 출발해 player 를 쫓는다
function Hunt.start(player, count, x, y, reason)
    local d = Store.data()
    local all = hunts()
    d.huntSeq = d.huntSeq + 1
    local id = "H" .. StoryEngine.intToString(d.huntSeq)
    all[id] = { id = id, target = Store.playerKey(player), remaining = count, x = x, y = y, z = 0,
                lastT = Sensor.now().t, reason = reason }
    log("hunt start", id, count, "for", Store.playerKey(player), reason or "")
    return id
end

-- 살아 있는 무리 좀비. 서버에서는 isExistInTheWorld 가 살아 있는 좀비에도 거짓을 돌려줘서(42.20.4 인게임 호스트 로그),
-- 객체 참조 대신 매번 셀의 좀비 목록에서 표시(modData.storyHunt)로 찾는다
local function tagged(id)
    local out = {}
    pcall(function()
        local list = getCell():getZombieList()
        for i = 0, list:size() - 1 do
            local z = list:get(i)
            local mod = z:getModData()
            if mod and mod.storyHunt == id and not z:isDead() then out[#out + 1] = z end
        end
    end)
    return out
end

local function aliveZombies(id)
    local out = tagged(id)
    if #out > 0 then Hunt.live[id] = { zombies = out } end
    return out
end

-- 멀티 서버: 무리 좀비를 소유한 클라이언트마다 추적 명령을 보낸다
local function sendChase(zombies, target)
    if not isServer() then return end
    local byOwner = {}
    for _, z in ipairs(zombies) do
        local ok, owner = pcall(function() return z:getOwnerPlayer() end)
        local key = (ok and owner) and owner or target
        byOwner[key] = byOwner[key] or {}
        table.insert(byOwner[key], z:getOnlineID())
    end
    for owner, ids in pairs(byOwner) do
        pcall(StoryEngine.Net.toClient, owner, "huntChase", { ids = ids, target = target:getOnlineID() })
    end
end

local function chase(z, target)
    pcall(function()
        if dist(z:getX(), z:getY(), target:getX(), target:getY()) <= Hunt.SPOT_DIST then
            z:spotted(target, true)
        else
            z:pathToCharacter(target)
        end
    end)
end

-- 세이브에 남아 있던 같은 무리의 좀비를 다시 데려온다
local function adopt(h)
    return tagged(h.id)
end

local function materialize(h, target, exact)
    local tx, ty = target:getX(), target:getY()
    local d = dist(h.x, h.y, tx, ty)
    local sx, sy = h.x, h.y
    if not exact and d < Hunt.MIN_SPAWN_DIST and d > 0 then
        sx = tx + (h.x - tx) / d * Hunt.MIN_SPAWN_DIST
        sy = ty + (h.y - ty) / d * Hunt.MIN_SPAWN_DIST
    end
    local zombies = adopt(h)
    local need = h.remaining - #zombies
    if need > 0 then
        local sq = getCell():getGridSquare(math.floor(sx), math.floor(sy), 0)
        if not sq then return false end   -- 칸이 아직 로드되지 않았다
        local list = addZombiesInOutfitArea(math.floor(sx) - 2, math.floor(sy) - 2, math.floor(sx) + 2, math.floor(sy) + 2,
            0, need, nil, nil)
        for i = 0, (list and list:size() or 0) - 1 do
            local z = list:get(i)
            z:getModData().storyHunt = h.id
            zombies[#zombies + 1] = z
        end
    end
    if #zombies == 0 then return false end
    Hunt.live[h.id] = { zombies = zombies }
    for _, z in ipairs(zombies) do chase(z, target) end
    sendChase(zombies, target)
    log("hunt materialized", h.id, #zombies, "at", math.floor(sx), math.floor(sy))
    return true
end

function Hunt.tick()
    local now = Sensor.now()
    local all = hunts()
    local done = {}
    for id, h in pairs(all) do
        local ps = Store.data().players[h.target]
        local target = targetOf(h)
        if (ps and ps.dead) or h.remaining <= 0 then
            done[#done + 1] = id
        elseif target and not target:isDead() then
            local elapsed = math.max(0, now.t - (h.lastT or now.t))
            h.lastT = now.t
            local zombies = aliveZombies(id)
            if #zombies > 0 then h.missing = 0 end
            local wasReal = Hunt.live[id] ~= nil
            if #zombies == 0 and wasReal then
                h.missing = (h.missing or 0) + 1
                local near = dist(h.x, h.y, target:getX(), target:getY()) < Hunt.UNLOAD_DIST
                if h.missing >= Hunt.LOST_TICKS and near then
                    log("hunt lost", id, "remaining", h.remaining)
                    h.remaining = 0
                elseif h.missing < Hunt.MISSING_TICKS or near then
                    -- 잠깐 안 보이는 것. 기다린다
                    zombies = nil
                end
            end
            if zombies == nil or h.remaining <= 0 then
                -- 기다리거나 끝난 무리: 다음 틱에 다시 본다
            elseif #zombies > 0 then
                -- 실제 무리: 위치를 기억하고 다시 쫓게 한다
                local sx, sy = 0, 0
                for _, z in ipairs(zombies) do
                    sx, sy = sx + z:getX(), sy + z:getY()
                    chase(z, target)
                end
                sendChase(zombies, target)
                h.x, h.y = sx / #zombies, sy / #zombies
                h.logN = (h.logN or 0) + 1
                if h.logN % 5 == 1 then
                    log("hunt chasing", id, #zombies, "zombies at", math.floor(h.x), math.floor(h.y), "dist",
                        math.floor(dist(h.x, h.y, target:getX(), target:getY())), "to", h.target)
                end
            else
                if Hunt.live[id] then
                    Hunt.live[id] = nil
                    log("hunt unloaded", id, "remaining", h.remaining)
                end
                -- 가상 무리: 대상 쪽으로 걸어간다
                local tx, ty = target:getX(), target:getY()
                local d = dist(h.x, h.y, tx, ty)
                local step = math.min(d, Hunt.SPEED * elapsed)
                if d > 0 then
                    h.x = h.x + (tx - h.x) / d * step
                    h.y = h.y + (ty - h.y) / d * step
                end
                if dist(h.x, h.y, tx, ty) <= Hunt.SPAWN_DIST then materialize(h, target) end
            end
        else
            h.lastT = now.t   -- 대상이 접속해 있지 않으면 멈춘다
        end
    end
    for _, id in ipairs(done) do
        log("hunt over", id, "remaining", all[id].remaining)
        all[id] = nil
        Hunt.live[id] = nil
    end
end

-- 추적 무리의 좀비가 죽으면 남은 수를 줄인다
function Hunt.onZombieDead(zombie)
    local mod = zombie:getModData()
    local id = mod and mod.storyHunt
    if not id then return end
    local h = hunts()[id]
    if h then h.remaining = math.max(0, h.remaining - 1) end
end

-- 한 곳에 오래 머물기 (Sensor 10분 샘플마다 위치 갱신, 하루 한 번 확률)
local function checkStay(e, now)
    local ps, s = e.ps, e.s
    local stay = ps.stay
    if not stay or dist(stay.x, stay.y, s.x, s.y) > Hunt.STAY_RADIUS then
        ps.stay = { x = s.x, y = s.y, sinceT = now.t }
        return
    end
    if ps.stay.rollDay == now.dayKey then return end
    ps.stay.rollDay = now.dayKey
    local days = math.floor((now.t - stay.sinceT) / (24 * 60))
    if days < Hunt.STAY_DAYS then return end
    if StoryEngine.option("DangerEvents", true) ~= true then return end
    local chance = math.min(100, Hunt.STAY_BASE + Hunt.STAY_STEP * (days - Hunt.STAY_DAYS))
    local hit = ZombRand(100) < chance
    log("stay roll", ps.name, days, "days", chance .. "%", hit and "hit" or "miss")
    if not hit then return end
    Hunt.sendAt(e.player, "stay")
    ps.stay.sinceT = now.t    -- 다시 4일이 지나야 한다
    Store.addNote(ps, { kind = "stay_horde", clock = now.clock, count = Hunt.sizeNow() })
    pcall(StoryEngine.Net.toClient, e.player, "directorNotice", { kind = "horde_sense" })
end

Sensor.listeners.tick[#Sensor.listeners.tick + 1] = function(entries, now)
    for _, e in ipairs(entries) do
        local ok, err = pcall(checkStay, e, now)
        if not ok then log("stay check error:", err) end
    end
end

-- 디버그: player 에게서 d 타일 떨어진 곳에 count 마리 추적 무리를 바로 만든다
function Hunt.startNear(player, count, d)
    local angle = ZombRandFloat(0, math.pi * 2)
    local x, y = player:getX() + math.cos(angle) * d, player:getY() + math.sin(angle) * d
    local id = Hunt.start(player, count, x, y, "debug_near")
    local ok = materialize(hunts()[id], player, true)
    return id, ok
end

function Hunt.statusText()
    local parts = {}
    for id, h in pairs(hunts()) do
        parts[#parts + 1] = id .. " " .. StoryEngine.intToString(h.remaining) .. " left"
            .. (Hunt.live[id] and " (real)" or " (virtual)")
    end
    if #parts == 0 then return "no hunts" end
    return table.concat(parts, ", ")
end

Events.EveryOneMinute.Add(function()
    local ok, err = pcall(Hunt.tick)
    if not ok then log("hunt tick error:", err) end
end)
Events.OnZombieDead.Add(function(zombie)
    local ok, err = pcall(Hunt.onZombieDead, zombie)
    if not ok then log("hunt dead error:", err) end
end)

return Hunt
