-- Project A-Life [ALIFE NPCS] 연동 (서버 측 전용, 선택). A-Life 가 켜져 있을 때만 동작하고, 없으면 아무것도 하지 않는다.
--
-- A-Life 에는 공식 API 가 없어 전역 테이블 ProjectALife.* 의 서버 기능을 직접 부른다 (A-Life 1.3.0 기준, 모두 pcall).
--   스폰      DebugService.spawnEncounter(player, args) -> watchGroup(requestId, fn(outcome)) 의 outcome.actorUids
--   호위      DecisionLoop.setOrder(uid, generation, { kind = "follow" | "patrol", player | anchor, untilMs })
--   적대      memory.hostileOverride (true 적 / false 아군), 서로 싸우게 할 때 Relations.writeGrudge
--   정리      DebugService.purgeActor(actor)
--   A-Life 사건  ModuleRobbery.byPlayer[key] (강도), RaidDirector.state.targetUsername (습격), 행위자 memory 의 대상
--
-- 지원 (아군):  신뢰도 50 이상 세력에 무전으로 요청 (세력당 3일에 한 번), 신뢰도 70 이상이면 위험할 때 자동.
--   인원·전투력·지속 시간은 신뢰도 구간(50/60/70/80/90)으로 올라간다. 플레이어 10~15타일 옆에 바로 나타난다.
--   끝나면 원래 방향으로 걸어가고, 플레이어에게서 멀어지면 정리한다.
-- 공격 (적):   협박을 무시하면 추적 호드 대신 그 세력의 무장 무리 (Quests.punish). 45~60타일에서 출발한다
--   (추적 무리의 50~80 은 A-Life 시뮬레이션 창 가장자리라 나오자마자 오프라인으로 내려갔다, 2026-09-28 로그).

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Radio"

local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Radio = StoryEngine.Radio
local log = StoryEngine.log

local ALife = {
    pending = {},      -- requestId -> true (스폰 결과 대기, 메모리만)
}
StoryEngine.ALife = ALife

-- 우리 NPC -> A-Life 세력 (약한 쪽부터). 신뢰도가 높을수록 뒤쪽 세력에서, 그 안에서도 강한 대원을 보낸다.
ALife.FACTIONS = {
    ray = { "alife_hensley_family", "alife_bauer_family", "alife_gunclub" },
    casey = { "alife_radio_station", "alife_telephone_crew", "alife_preppers" },
    doc = { "alife_county_ems", "alife_army_medical" },
    pike = { "alife_church_volunteers", "alife_road_militia" },
    dewey = { "alife_lone_mechanic", "alife_crume", "alife_preppers" },
    guard = { "alife_guard_remnants", "alife_guard_infantry", "alife_guard" },
    rats = { "alife_cinder_raiders", "alife_ironhorse", "alife_scrapyard_reavers" },
    hunter = { "alife_otter_creek_trappers", "alife_gunclub" },
}

ALife.REQUEST_TRUST = 50
ALife.AUTO_TRUST = 70
-- 신뢰도 구간별 (50, 60, 70, 80, 90 이상): 인원, 지속 시간(게임 시간)
ALife.LEVEL_MIN = { 50, 60, 70, 80, 90 }
ALife.SIZE = { 4, 5, 6, 7, 8 }            -- A-Life 한 그룹 최대 8명
ALife.HOURS = { 2, 3, 4, 5, 6 }
ALife.FRIEND_DIST = { 10, 15 }            -- 아군은 바로 옆에
ALife.REQUEST_COOLDOWN_MIN = 3 * 24 * 60  -- 세력당 요청 간격 (3일)
ALife.AUTO_COOLDOWN_MIN = 7 * 24 * 60     -- 플레이어당 자동 지원 간격 (7일, 2026-09-29 변경)
ALife.HUNT_TRIGGER_DIST = 40              -- 우리 추적 무리(Hunt)가 이만큼 다가오면 자동 지원
ALife.DANGER_RADIUS = 15
ALife.DANGER_ZOMBIES = 10
ALife.DANGER_HP = 50
ALife.THREAT_RADIUS = 60                  -- A-Life 적대 행위자를 찾는 반경
ALife.LEAVE_DIST = 45                     -- 떠나는 대원이 모든 플레이어에게서 이만큼 멀어지면 정리
ALife.LEAVE_MAX_MIN = 3 * 60              -- 떠나기 시작하고 이 시간이 지나면 정리
ALife.ORDER_MS = 20 * 60 * 1000           -- 따라오기 명령 한 번의 길이 (실시간). 끝나기 전에 다시 건다
ALife.ATTACK_SIZE = { 3, 5, 7 }           -- 진행 단계별 공격 인원
ALife.ATTACK_DIST = { 45, 60 }            -- A-Life 자체 습격(45)과 비슷하게. 멀면 창 가장자리에서 바로 오프라인
ALife.ATTACK_RETRIES = 2                  -- 막힌 칸·시야 안이라 그룹 전체가 취소되면 다른 자리로 다시
ALife.STATUS_LOG_MIN = 5                  -- 지원 대원 상태를 로그에 남기는 간격 (게임 분)
ALife.PROTECT_MS = 500                    -- 아군 보호 주기 (실시간)
ALife.IGNORE_HOLD_MS = 3000               -- 플레이어를 무시 대상으로 거는 시간 (PROTECT_MS 마다 갱신)
ALife.ATTACK_LEVEL = { 1, 3, 5 }

local function PA() return ProjectALife end

function ALife.enabled()
    return StoryEngine.option("ALifeSupport", true) == true
end

-- A-Life 가 켜져 있고 필요한 기능이 모두 있는가
function ALife.available()
    local pa = PA()
    if type(pa) ~= "table" then return false end
    local svc = pa.DebugService
    if type(svc) ~= "table" or type(svc.spawnEncounter) ~= "function" or type(svc.watchGroup) ~= "function" then return false end
    if type(pa.ActorRegistry) ~= "table" or type(pa.Catalog) ~= "table" then return false end
    return pa.Runtime ~= nil and pa.Runtime.started == true
end

local function state()
    local d = Store.data()
    d.alife = d.alife or { active = {}, cooldown = {}, autoAt = {}, seq = 0 }
    return d.alife
end

local function nowMs() return StoryEngine.nowMs() end

local function dist(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

-- A-Life 가 쓰는 플레이어 키 (보통 계정 이름)
function ALife.playerKey(player)
    local pa = PA()
    local key
    if pa and pa.Reputation and type(pa.Reputation.playerKey) == "function" then
        pcall(function() key = pa.Reputation.playerKey(player) end)
    end
    if type(key) ~= "string" then pcall(function() key = player:getUsername() end) end
    return key
end

local function playerByKey(psKey)
    for _, p in ipairs(Sensor.players()) do
        if Store.playerKey(p) == psKey then return p end
    end
    return nil
end

-- 신뢰도 구간 (0 이면 지원 불가)
function ALife.level(trust)
    local level = 0
    for i, min in ipairs(ALife.LEVEL_MIN) do
        if trust >= min then level = i end
    end
    return level
end

-- ---------------------------------------------------------------- profiles

-- 전투력 점수: 사격 능력 + 총 여부 + 체력. 사격 6 이상은 A-Life 가 날짜와 상관없이 주무기를 쥐여 준다.
local function power(profile)
    local g = profile.general or {}
    local aim = tonumber(g.aiming) or 0
    local hp = tonumber(g.healthHP) or 50
    local primary = profile.weapons and profile.weapons.primary
    local gun = type(primary) == "string" and primary ~= "" and primary ~= "none"
    return aim * 2 + (gun and 6 or 0) + (aim >= 6 and gun and 6 or 0) + hp / 20
end

local function profilesOf(factionId)
    local pa = PA()
    local current = pa.Catalog.current
    local out = {}
    if not current or type(current.npcOrder) ~= "table" then return out end
    for _, p in ipairs(current.npcOrder) do
        local g = p.general
        -- 자연 스폰 가중치가 0 인 대원(예: alife_guard)도 직접 부를 수 있다. 시험용 프로필만 뺀다
        if g and g.faction == factionId and g.deleted ~= true and string.sub(tostring(p.id), 1, 5) ~= "test_" then
            out[#out + 1] = p
        end
    end
    return out
end

-- 세력 목록과 구간(1~5)으로 A-Life 세력 하나와 대원 count 명을 고른다. 구간이 높을수록 강한 대원 위주.
function ALife.pickSquad(fid, level, count)
    local list = ALife.FACTIONS[fid]
    if not list then return nil, "no_mapping" end
    level = math.max(1, math.min(5, level))
    local index = math.max(1, math.ceil(level * #list / 5))
    local factionId, pool
    for i = index, 1, -1 do
        pool = profilesOf(list[i])
        if #pool > 0 then
            factionId = list[i]
            break
        end
    end
    if not factionId then return nil, "no_profiles" end
    local scored = {}
    for _, p in ipairs(pool) do scored[#scored + 1] = { p = p, s = power(p) } end
    table.sort(scored, function(a, b) return a.s > b.s end)
    -- 구간 1 은 전체에서, 구간 5 는 가장 강한 대원들 중에서
    local n = #scored
    local window = math.max(math.min(count, n), n - math.floor((level - 1) * (n - 1) / 4))
    local ids = {}
    for i = 1, count do
        local pick = scored[ZombRand(window) + 1]
        ids[#ids + 1] = pick.p.id
    end
    return factionId, ids
end

-- ---------------------------------------------------------------- spawn

-- A-Life 가 스폰을 막는 곳인가: 플레이어 거점(BaseHeat)·세이프하우스 + 여유. spawnEncounter 는 항상 directed 라
-- 거점 검사를 건너뛸 수 없고, 한 명이라도 거점 안이면 그룹 전체가 취소된다 (scene_atomic_rollback,
-- inside_player_base — 2026-09-30 인게임 로그). 대원은 스폰 지점 반경 6 안에 흩어지므로 여유를 더 둔다
ALife.BASE_SPREAD = 8
ALife.FAR_SPOTS = { 20, 30, 45, 60 }      -- 가까운 곳이 모두 거점 안이면 이 거리에서 찾는다

function ALife.protectedAt(x, y, extra)
    extra = extra or ALife.BASE_SPREAD
    local sp = ProjectALife and ProjectALife.SpawnPolicy
    local margin = ((sp and tonumber(sp.safehouseMargin)) or 8) + extra
    if sp and type(sp.inPlayerBase) == "function" then
        local ok, inside = pcall(sp.inPlayerBase, { x = x + 0.5, y = y + 0.5, z = 0 }, margin)
        if ok and inside then return true end
    end
    local ok, hit = pcall(function()
        local list = SafeHouse and SafeHouse.getSafehouseList and SafeHouse.getSafehouseList()
        if not list then return false end
        for i = 0, list:size() - 1 do
            local s = list:get(i)
            local x1, y1 = s:getX(), s:getY()
            if x >= x1 - margin and x <= x1 + s:getW() + margin and y >= y1 - margin and y <= y1 + s:getH() + margin then
                return true
            end
        end
        return false
    end)
    return ok and hit == true
end

-- 스폰 지점: distRange 안에서 거점 밖을 먼저, 없으면 더 멀리. 반환: x, y, 거리, 거점 때문에 옮겼는가
function ALife.spawnSpot(px, py, distRange)
    local function at(angle, d)
        return math.floor(px + math.cos(angle) * d), math.floor(py + math.sin(angle) * d)
    end
    local angle = ZombRandFloat(0, math.pi * 2)
    local d = ZombRand(distRange[1], distRange[2] + 1)
    local x, y = at(angle, d)
    if not ALife.protectedAt(x, y) then return x, y, d, false end
    for i = 1, 11 do
        local a = angle + i * math.pi / 6
        local cx, cy = at(a, d)
        if not ALife.protectedAt(cx, cy) then return cx, cy, d, false end
    end
    for _, far in ipairs(ALife.FAR_SPOTS) do
        if far > distRange[1] then
            for i = 0, 11 do
                local cx, cy = at(angle + i * math.pi / 6, far)
                if not ALife.protectedAt(cx, cy) then return cx, cy, far, true end
            end
        end
    end
    return x, y, d, false
end

-- friendly: 아군(true) / 적(false). dist 는 { 최소, 최대 } 타일.
-- hooks.start(info) 는 스폰 요청 직전 (결과 콜백이 바로 올 수도 있어 먼저 등록해 둔다), hooks.done(outcome, info) 는 끝나면.
function ALife.spawnSquad(player, fid, level, count, friendly, distRange, tag, hooks)
    hooks = hooks or {}
    if not ALife.available() then return false, "alife_unavailable" end
    local factionId, ids = ALife.pickSquad(fid, level, count)
    if not factionId then return false, ids end
    local st = state()
    st.seq = (st.seq or 0) + 1
    local requestId = "storyengine:" .. tag .. ":" .. StoryEngine.intToString(st.seq) .. ":" .. tostring(nowMs())
    local px, py = player:getX(), player:getY()
    local x, y, d, moved = ALife.spawnSpot(px, py, distRange)
    local key = ALife.playerKey(player)
    local args = {
        requestId = requestId, encounterId = "storyengine_" .. tag,
        factionId = factionId, profileIds = ids, count = #ids,
        x = x, y = y, z = 0, distance = 0, separation = 1.5, radius = 6,
        mode = "assault", profile = "seek_destroy",
        atomicGroup = true, conducts = { "leader" }, animation = "normal",
        encounterPersistent = false, supportPolicy = "disabled",
        objectiveX = math.floor(px), objectiveY = math.floor(py),
        hostileOverride = not friendly, spawnStance = friendly and "friendly" or "hostile",
        targetUsername = (not friendly) and key or nil,
        playerKeepOut = friendly and 0 or nil,
        -- 아군은 A-Life 자체 지원 부대처럼 "backup" 역할로: 이게 없으면 seek_destroy(hunt) 행동이 적이 없을 때
        -- 가장 가까운 플레이어를 추격 대상으로 잡는다 (Programs.pursuitTarget, 2026-09-28 로그)
        supportRole = friendly and "backup" or nil,
    }
    local info = { requestId = requestId, factionId = factionId, x = x, y = y, count = #ids }
    ALife.installGuards()
    if hooks.start then hooks.start(info) end
    ALife.pending[requestId] = true
    local ok, okSpawn, reason = pcall(PA().DebugService.spawnEncounter, player, args)
    if not ok or not okSpawn then
        ALife.pending[requestId] = nil
        return false, ok and tostring(reason or "spawn_refused") or "spawn_error", info
    end
    pcall(PA().DebugService.watchGroup, requestId, function(outcome)
        ALife.pending[requestId] = nil
        if hooks.done then
            local okDone, err = pcall(hooks.done, outcome or {}, info)
            if not okDone then log("alife spawn callback error:", err) end
        end
    end)
    log("alife squad", tag, fid, factionId, "level", level, "x" .. #ids, friendly and "friendly" or "hostile",
        "at", x, y, "dist", d, moved and "(outside player base)" or "")
    return true, info
end

local function actor(uid)
    local ok, record = pcall(PA().ActorRegistry.read, uid)
    return ok and record or nil
end

local function alive(record)
    return record ~= nil and record.lifecycle ~= "dead" and record.lifecycle ~= "removed"
end

local function positionOf(record)
    local w = record and record.worldPosition
    if type(w) == "table" and tonumber(w.x) then return tonumber(w.x), tonumber(w.y) end
    return nil
end

-- 명령: 이미 같은 명령이 충분히 남아 있으면 다시 걸지 않는다 (setOrder 는 싸우던 대원도 멈추게 한다)
local function order(uid, o)
    local record = actor(uid)
    if not alive(record) or record.lifecycle ~= "active" then return false end
    local loop = PA().DecisionLoop
    if not loop or type(loop.setOrder) ~= "function" then return false end
    local cur = loop.orders and loop.orders[uid]
    if cur and cur.kind == o.kind and cur.generation == record.generation
        and (tonumber(cur.untilMs) or 0) - nowMs() > 2 * 60 * 1000 then
        return true
    end
    local ok, done, why = pcall(loop.setOrder, uid, record.generation, o)
    if not ok or done ~= true then
        ALife.orderFail = ALife.orderFail or {}
        local key = uid .. ":" .. o.kind
        if not ALife.orderFail[key] then
            ALife.orderFail[key] = true
            log("alife order failed", uid, o.kind, tostring(ok and why or done))
        end
        return false
    end
    return true
end

-- 아군 대원이 플레이어를 적으로 삼지 않게 한다.
-- A-Life 는 플레이어에게 맞으면 관계와 상관없이 그 플레이어에게 반격한다 (Perception.attackers -> retaliationTarget,
-- 2026-09-28 로그: 근접전 중 오사 뒤 relation=friendly 인데 kind=player 로 조준). 반격 목표는 Perception.ignore 로
-- 무시 대상이면 버려지므로, 접속한 플레이어 전원을 계속 무시 대상으로 걸고, 남은 반격 기록·원한·교전을 지운다.
local function isPlayerObj(obj)
    local ok, yes = pcall(instanceof, obj, "IsoPlayer")
    return ok and yes == true
end

function ALife.protect(sup)
    local uids = sup.uids or {}
    local pa = PA()
    local perception, loop, reg = pa.Perception, pa.DecisionLoop, pa.ActorRegistry
    local players = Sensor.players()
    for _, uid in ipairs(uids) do
        if perception and type(perception.ignore) == "function" then
            for _, p in ipairs(players) do pcall(perception.ignore, uid, p, ALife.IGNORE_HOLD_MS) end
            local held = type(perception.attackers) == "table" and perception.attackers[uid] or nil
            if held and isPlayerObj(held.attacker) then perception.attackers[uid] = nil end
        end
        local okS, errS = pcall(ALife.suppress, uid)
        if not okS then
            ALife.suppressLogged[uid .. "!"] = ALife.suppressLogged[uid .. "!"] or (log("alife suppressor error:", errS) or true)
        end
        local record = actor(uid)
        local m = record and record.memory
        if type(m) == "table" then
            local grudge = false
            if type(m.hostileToPlayerKeys) == "table" then
                for _, v in pairs(m.hostileToPlayerKeys) do if v then grudge = true end end
            end
            if grudge then
                pcall(reg.update, uid, record.revision, function(r)
                    if type(r.memory) == "table" then r.memory.hostileToPlayerKeys = nil end
                end)
                log("alife support grudge cleared", uid)
            end
            -- 이미 플레이어와 교전 중이면 명령을 다시 걸어 상태를 풀어 준다 (setOrder 는 상태를 idle 로 되돌린다)
            local st = loop and type(loop.states) == "table" and loop.states[uid] or nil
            if st and st.kind == "combat" and st.threatKind == "player" and record.lifecycle == "active"
                and type(loop.setOrder) == "function" then
                local target = playerByKey(sup.target)
                local o
                if sup.phase == "follow" and target then
                    o = { kind = "follow", player = target, untilMs = nowMs() + ALife.ORDER_MS, quiet = true }
                else
                    o = { kind = "patrol", anchor = sup.exit, untilMs = nowMs() + ALife.ORDER_MS, quiet = true }
                end
                pcall(loop.setOrder, uid, record.generation, o)
                ALife.resetLogAt = ALife.resetLogAt or {}
                if not ALife.resetLogAt[uid] or nowMs() - ALife.resetLogAt[uid] > 10000 then
                    ALife.resetLogAt[uid] = nowMs()
                    log("alife support stopped attacking a player", uid)
                end
            end
        end
    end
end

-- 우리 지원 대원인가 (행위자 기록, 또는 셸(IsoZombie) -> modData.ProjectALifeUID)
function ALife.isSupport(actorOrShell)
    local record = actorOrShell
    if type(record) ~= "table" then
        local uid
        pcall(function()
            local data = actorOrShell:getModData()
            uid = data and data.ProjectALifeUID
        end)
        record = type(uid) == "string" and actor(uid) or nil
    end
    local m = type(record) == "table" and record.memory or nil
    return type(m) == "table" and m.encounterKind == "storyengine_support"
end

-- A-Life 판정 함수를 감싼다 (한 번만):
--   Relations.hostileToPlayer / playerStance: 우리 지원 대원은 플레이어에게 절대 적대하지 않는다.
--     A-Life 는 평판 기록(플레이어가 그 세력을 공격한 적 있음)을 hostileOverride 보다 먼저 봐서, 방위대 대원을 한 번
--     때린 뒤로는 방위대 계열 지원이 도착하자마자 플레이어를 쐈다 (2026-09-28 로그).
--   Reputation.onPlayerDamagedActor / onPlayerKilledActor / onPlayerProvoked: 지원 대원에 대한 오사는 A-Life 평판에
--     남기지 않는다 (남으면 그 세력의 모든 NPC 가 플레이어에게 적대한다).
--   ModuleCareful.onHitByPlayer: 플레이어에게 한 대라도 맞으면 무리 전체를 적대로 돌리는데(turnGroup, 관계 무시),
--     근접전 중 옆에 붙은 지원 대원이 맞아 6명이 한꺼번에 돌아섰다 (2026-09-28 4차 로그). 지원 대원은 건너뛴다.
--     (Talk.onHitByPlayer 는 "조심해!" 같은 대사만 하므로 그대로 둔다)
function ALife.installGuards()
    if ALife.guardsInstalled then return end
    local pa = PA()
    local rel, rep = pa.Relations, pa.Reputation
    if type(rel) ~= "table" or type(rel.hostileToPlayer) ~= "function" then return end
    ALife.guardsInstalled = true
    local hostile = rel.hostileToPlayer
    rel.hostileToPlayer = function(a, player, ...)
        if ALife.isSupport(a) then return false end
        return hostile(a, player, ...)
    end
    if type(rel.playerStance) == "function" then
        local stance = rel.playerStance
        rel.playerStance = function(a, player, ...)
            if ALife.isSupport(a) then return "friendly" end
            return stance(a, player, ...)
        end
    end
    local careful = pa.ModuleCareful
    if type(careful) == "table" and type(careful.onHitByPlayer) == "function" then
        local onHit = careful.onHitByPlayer
        careful.onHitByPlayer = function(player, shell, a, ...)
            if ALife.isSupport(a or shell) then return false end
            return onHit(player, shell, a, ...)
        end
    end
    if type(rep) == "table" then
        for _, name in ipairs({ "onPlayerDamagedActor", "onPlayerKilledActor", "onPlayerProvoked" }) do
            local fn = rep[name]
            if type(fn) == "function" then
                rep[name] = function(player, target, ...)
                    if ALife.isSupport(target) then return false, "storyengine_support" end
                    return fn(player, target, ...)
                end
            end
        end
    end
    log("alife guards installed")
end

-- 서로 적으로 여기게 한다 (지원 대원 <-> 플레이어를 노리는 A-Life 행위자)
local function makeEnemies(ourUids, theirUids)
    local pa = PA()
    local rel, reg = pa.Relations, pa.ActorRegistry
    if not rel or type(rel.writeGrudge) ~= "function" then return end
    for _, their in ipairs(theirUids) do pcall(rel.writeGrudge, reg, ourUids, their) end
    for _, our in ipairs(ourUids) do pcall(rel.writeGrudge, reg, theirUids, our) end
end

-- ---------------------------------------------------------------- threats

-- 이 플레이어를 노리는 A-Life 행위자(강도·습격·교전 중) uid 목록과, 강도·습격이 진행 중인지
function ALife.threatsTo(player)
    local pa = PA()
    local key = ALife.playerKey(player)
    local out, event = {}, nil
    if not key then return out, nil end
    local robbery = pa.ModuleRobbery
    if robbery and type(robbery.byPlayer) == "table" and robbery.byPlayer[key] ~= nil then event = "robbery" end
    local raid = pa.RaidDirector and pa.RaidDirector.state
    if type(raid) == "table" and raid.targetUsername == key then event = event or "raid" end
    local px, py = player:getX(), player:getY()
    pcall(pa.ActorRegistry.each, function(record)
        if record.lifecycle ~= "active" then return end
        local m = record.memory or {}
        if m.encounterKind == "storyengine_support" then return end
        local targeting = m.targetUsername == key or m.combatTargetPlayerKey == key
            or (type(m.robbery) == "table" and m.robbery.playerKey == key)
        if not targeting then return end
        local x, y = positionOf(record)
        if x and dist(x, y, px, py) <= ALife.THREAT_RADIUS then
            out[#out + 1] = record.uid
            -- 이 모드가 보낸 무장 무리 (협박 보복)
            if m.encounterKind == "storyengine_attack" then event = event or "se_attack" end
        end
    end)
    if #out > 0 and not event then event = "attack" end
    return out, event
end

-- 플레이어에게 적대적인 A-Life 무리 위치 (케이시 정찰). 15타일 안끼리 한 무리로 묶는다: { x, y, n }
function ALife.hostileGroups(player, radius)
    local out = {}
    local pa = PA()
    local key = ALife.playerKey(player)
    if type(pa) ~= "table" or not key or type(pa.ActorRegistry) ~= "table" then return out end
    local rel = pa.Relations
    local px, py = player:getX(), player:getY()
    local pts = {}
    pcall(pa.ActorRegistry.each, function(record)
        if record.lifecycle ~= "active" then return end
        local m = record.memory or {}
        if m.encounterKind == "storyengine_support" then return end
        local hostile = m.targetUsername == key or m.combatTargetPlayerKey == key or m.encounterKind == "storyengine_attack"
        if not hostile and type(rel) == "table" and type(rel.hostileToPlayer) == "function" then
            local ok, yes = pcall(rel.hostileToPlayer, record, player)
            hostile = ok and yes == true
        end
        if not hostile then return end
        local x, y = positionOf(record)
        if x and dist(x, y, px, py) <= radius then pts[#pts + 1] = { x = x, y = y } end
    end)
    for _, pt in ipairs(pts) do
        local group = nil
        for _, g in ipairs(out) do
            if dist(g.x, g.y, pt.x, pt.y) <= 15 then group = g end
        end
        if group then
            group.sx, group.sy, group.n = group.sx + pt.x, group.sy + pt.y, group.n + 1
            group.x, group.y = group.sx / group.n, group.sy / group.n
        else
            out[#out + 1] = { x = pt.x, y = pt.y, sx = pt.x, sy = pt.y, n = 1 }
        end
    end
    return out
end

-- ---------------------------------------------------------------- suppressor

-- 지원 대원 총에 소음기: 총 인스턴스의 소음 반경·크기를 줄인다 (A-Life 는 쏠 때 getSoundRadius/Volume 로 addSound,
-- ALifeCombatFire.lua reportSound). 원래 값은 modData 에 두고, 대원이 죽으면 되돌린다 (떨어진 총을 주워 쓰지 않게).
-- 들리는 총소리는 그대로다.
ALife.SUPPRESS = 0.25
ALife.suppressLogged = {}

local function shellOf(uid)
    local wd = PA().Watchdog
    local b = type(wd) == "table" and type(wd.bindings) == "table" and wd.bindings[uid] or nil
    return b and b.shell or nil
end

-- 대원이 가진 총: 손에 든 것 + 인벤토리 (A-Life 는 교전 전에는 총을 손에 들지 않을 수 있다)
local function gunsOf(shell)
    local out = {}
    local function add(w)
        if w and w.isRanged and w:isRanged() then out[#out + 1] = w end
    end
    pcall(function() add(shell:getPrimaryHandItem()) end)
    pcall(function()
        local items = shell:getInventory():getItems()
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            if it ~= shell:getPrimaryHandItem() and instanceof(it, "HandWeapon") then add(it) end
        end
    end)
    return out
end

local function quiet(w)
    local md = w:getModData()
    if md.seSuppressed then return false end
    local r, v = w:getSoundRadius(), w:getSoundVolume()
    md.seOrigRadius, md.seOrigVolume, md.seSuppressed = r, v, true
    w:setSoundRadius(math.max(1, math.floor(r * ALife.SUPPRESS)))
    w:setSoundVolume(math.max(1, math.floor(v * ALife.SUPPRESS)))
    return true
end

function ALife.suppress(uid)
    local shell = shellOf(uid)
    local guns = shell and gunsOf(shell) or {}
    local changed = {}
    for _, w in ipairs(guns) do
        if quiet(w) then changed[#changed + 1] = tostring(w:getFullType()) .. " " .. tostring(w:getModData().seOrigRadius)
            .. "->" .. tostring(w:getSoundRadius()) end
    end
    -- 대원마다 한 번: 소음기를 달았는지, 못 달았으면 왜인지
    if #changed > 0 then
        log("alife suppressor", uid, table.concat(changed, ", "))
        ALife.suppressLogged[uid] = true
    elseif not ALife.suppressLogged[uid] then
        ALife.suppressLogged[uid] = true
        log("alife suppressor skipped", uid, shell and ("no gun (" .. tostring(#guns) .. ")") or "no shell binding")
    end
end

function ALife.unsuppress(w)
    if not w or not w.getModData then return end
    local md = w:getModData()
    if not md.seSuppressed then return end
    pcall(function()
        w:setSoundRadius(md.seOrigRadius)
        w:setSoundVolume(md.seOrigVolume)
    end)
    md.seSuppressed, md.seOrigRadius, md.seOrigVolume = nil, nil, nil
end

Events.OnZombieDead.Add(function(zombie)
    pcall(function()
        local md = zombie:getModData()
        if md and md.ProjectALifeUID and ALife.isSupport(zombie) then
            for _, w in ipairs(gunsOf(zombie)) do ALife.unsuppress(w) end
        end
    end)
end)

-- ---------------------------------------------------------------- support

local function activeFor(psKey)
    for id, s in pairs(state().active) do
        if s.target == psKey and s.phase ~= "done" then return id, s end
    end
    return nil
end

-- 지원을 정하는 신뢰: 위험한(청한) 그 사람의 신뢰 (개인 모드면 개인 신뢰, DESIGN_PER_PLAYER_TRUST 4절).
-- peek: 고르기만 할 때 (자동 지원 후보) 처음 연락을 정하지 않는다
local function trustOf(fid, key, peek)
    if key and peek and StoryEngine.Trade and StoryEngine.Trade.trustPeek then
        return StoryEngine.Trade.trustPeek(fid, key)
    end
    if key and StoryEngine.Trust then return StoryEngine.Trust.of(fid, key) end
    return Radio.channel(fid).trust
end

local function personalMode()
    return StoryEngine.Trust ~= nil and StoryEngine.Trust.personalMode()
end

-- 지원을 보낸다. how: "request" | "auto" | "debug". reason: 자동 지원의 이유 (AI 반응용)
-- countOverride: 인원을 직접 정할 때 (방위대 특기 분대 2/4/6)
-- opts (2차 특기, 2026-10-09): { hours = 머무는 시간, quiet = 출동 무전 없음 }
function ALife.sendSupport(player, fid, how, reason, levelOverride, retry, countOverride, opts)
    opts = opts or {}
    if not ALife.enabled() then return false, "disabled" end
    if not ALife.available() then return false, "alife_unavailable" end
    if not Factions.byId[fid] or not ALife.FACTIONS[fid] then return false, "no_faction" end
    if Factions.isGone(fid) then return false, "gone" end
    local ps = Store.player(player)
    if activeFor(ps.key) then return false, "active" end
    local level = levelOverride or ALife.level(trustOf(fid, ps.key))
    if level <= 0 then return false, "low_trust" end
    local count = countOverride or ALife.SIZE[level]
    -- 방위대 검문소 프로젝트 완성: +2명 (A-Life 그룹 최대 8)
    if fid == "guard" and StoryEngine.Projects and StoryEngine.Projects.done("guard") then
        count = math.min(8, count + 2)
    end
    -- 생활 상태: 안전(탄약·방어)이 부족하면 인원이 줄고, 바닥이면 보낼 수 없다 (Life.lua)
    local Life = StoryEngine.Life
    if Life then
        local safety = Life.get(fid, "safety")
        if safety < Life.SELF_MIN then return false, "no_safety" end
        if safety < Life.LOW then count = math.max(1, count - 2) end
    end
    local now = Sensor.now()
    local st = state()
    local ok, info, failed = ALife.spawnSquad(player, fid, level, count, true, ALife.FRIEND_DIST, "support", {
        start = function(info)
            st.active[info.requestId] = {
                id = info.requestId, fid = fid, target = ps.key, targetName = ps.name, how = how, level = level,
                count = info.count, alifeFaction = info.factionId, uids = {}, phase = "follow",
                untilT = now.t + math.floor((opts.hours or ALife.HOURS[level]) * 60), exit = { x = info.x, y = info.y, z = 0 }, startT = now.t,
            }
        end,
        done = function(outcome, info)
            local s = st.active[info.requestId]
            if not s then return end
            s.uids = {}
            for _, uid in ipairs(outcome.actorUids or {}) do s.uids[#s.uids + 1] = uid end
            if #s.uids == 0 then
                s.phase = "done"
                log("alife support failed to spawn", s.fid, tostring(outcome.reason))
                -- 막힌 칸·시야 문제로 그룹이 취소됐으면 다른 자리로 한 번 더 (대기 시간은 이미 기록됨)
                if not retry and not player:isDead() then
                    st.active[info.requestId] = nil
                    ALife.sendSupport(player, fid, how, reason, levelOverride, true, countOverride, opts)
                    return
                end
                -- 다시 불러도 못 나왔다: 쓴 대기 시간을 돌려주고, 이미 "보냈다"고 한 무전을 바로잡는다
                if how == "auto" then st.autoAt[ps.key] = nil end
                if how == "request" then st.cooldown[fid] = nil end
                if how == "specialty" and StoryEngine.Specialty then pcall(StoryEngine.Specialty.clearWait, fid, ps.key) end
                -- 2차 특기 빅 보디가드만 환불 (SOS 의 방위대원은 다른 지원이 이미 갔다)
                if how == "specialty2" and fid == "rats" and StoryEngine.Specialty2 then
                    pcall(StoryEngine.Specialty2.clearWait, "rats", ps.key)
                end
                log("alife support gave up, cooldown refunded", fid, how)
                if not player:isDead() then
                    pcall(Radio.react, fid, "event", "The armed people you sent to back up " .. tostring(ps.name)
                        .. " could not get through to them this time. Tell them briefly, sorry, they are on their own for now.",
                        nil, ps, { overhead = true })
                end
                return
            end
            log("alife support arrived", s.fid, #s.uids)
            ALife.refresh(s)
            if StoryEngine.Life and s.how == "auto" then
                pcall(StoryEngine.Life.record, s.fid, "rescued", s.targetName, 0)
            end
            if StoryEngine.Banter then
                pcall(StoryEngine.Banter.onEvent, player, "support_arrived", { faction = fid, count = #s.uids })
            end
        end,
    })
    if not ok then
        if failed then st.active[failed.requestId] = nil end
        return false, info
    end
    if retry or opts.quiet then return true, info end   -- 다시 부른 것 / 2차 특기 (무전은 Specialty2 가 따로)
    if how == "request" then st.cooldown[fid] = now.t end
    if how == "auto" then st.autoAt[ps.key] = now.t end
    Store.addNote(ps, { kind = "alife_support", faction = fid, count = info.count, clock = now.clock })
    local topic
    if how == "auto" then
        topic = "You saw " .. ps.name .. " in serious trouble (" .. tostring(reason or "surrounded and hurt")
            .. ") and sent " .. StoryEngine.intToString(info.count) .. " of your armed people without being asked. "
            .. "They are right there with them now and will stay about " .. StoryEngine.intToString(ALife.HOURS[level])
            .. " hours. Tell them to hang on."
    else
        topic = ps.name .. " asked you for backup and you sent " .. StoryEngine.intToString(info.count)
            .. " of your armed people. They are already next to them and will stay about "
            .. StoryEngine.intToString(ALife.HOURS[level]) .. " hours, then head home. Say so in a sentence or two."
    end
    pcall(Radio.react, fid, "event", topic, nil, ps)
    return true, info
end

-- 신뢰도·대기 시간을 따져 플레이어 요청을 처리한다 (무전 탭의 지원 요청)
function ALife.request(player, fid)
    if not ALife.enabled() then return false, "disabled" end
    if not ALife.available() then return false, "alife_unavailable" end
    if not Factions.byId[fid] then return false, "no_faction" end
    if trustOf(fid, Store.playerKey(player)) < ALife.REQUEST_TRUST then return false, "low_trust" end
    local last = state().cooldown[fid]
    local now = Sensor.now()
    if last and now.t - last < ALife.REQUEST_COOLDOWN_MIN then
        return false, "cooldown", math.ceil((ALife.REQUEST_COOLDOWN_MIN - (now.t - last)) / 60)
    end
    return ALife.sendSupport(player, fid, "request")
end

-- 지원 대원에게 따라오기(또는 떠나기) 명령을 유지하고, 끝난 지원을 정리한다
function ALife.refresh(s)
    local now = Sensor.now()
    local target = playerByKey(s.target)
    local living = {}
    for _, uid in ipairs(s.uids or {}) do
        if alive(actor(uid)) then living[#living + 1] = uid end
    end
    if s.uids and #s.uids > 0 and #living == 0 and s.phase ~= "done" then
        s.phase = "done"
        log("alife support wiped out", s.fid)
        return
    end
    if s.phase == "follow" and (now.t >= s.untilT or not target or target:isDead()) then
        s.phase = "leaving"
        s.leaveT = now.t
        log("alife support leaving", s.fid)
        if StoryEngine.Banter then
            pcall(StoryEngine.Banter.onEventFor, Store.data().players[s.target], "support_left", { faction = s.fid })
        end
        if target and not target:isDead() then
            pcall(Radio.react, s.fid, "event", "Your people who were backing up " .. tostring(s.targetName)
                .. " are heading home now. Tell them in a sentence.", nil, Store.data().players[s.target])
        end
    end
    if s.phase == "follow" and target then
        local parts = {}
        for _, uid in ipairs(living) do
            local okOrder = order(uid, { kind = "follow", player = target, untilMs = nowMs() + ALife.ORDER_MS, quiet = true })
            local record = actor(uid)
            local x, y = positionOf(record)
            parts[#parts + 1] = tostring(record and record.lifecycle) .. (okOrder and "+follow" or "-follow")
                .. (x and ("@" .. math.floor(dist(x, y, target:getX(), target:getY()))) or "")
        end
        if not s.lastLogT or now.t - s.lastLogT >= ALife.STATUS_LOG_MIN then
            s.lastLogT = now.t
            log("alife support status", s.fid, "for", tostring(s.targetName), table.concat(parts, " "),
                "left", StoryEngine.intToString(math.max(0, s.untilT - now.t)) .. "min")
        end
        -- 플레이어를 노리는 A-Life 무리와 서로 적으로
        local threats = ALife.threatsTo(target)
        if #threats > 0 and #living > 0 then makeEnemies(living, threats) end
    elseif s.phase == "leaving" then
        local far = true
        for _, uid in ipairs(living) do
            local x, y = positionOf(actor(uid))
            for _, p in ipairs(Sensor.players()) do
                if x and dist(x, y, p:getX(), p:getY()) < ALife.LEAVE_DIST then far = false end
            end
            order(uid, { kind = "patrol", anchor = s.exit, untilMs = nowMs() + ALife.ORDER_MS, quiet = true })
        end
        if far or now.t - (s.leaveT or now.t) >= ALife.LEAVE_MAX_MIN then
            for _, uid in ipairs(living) do
                pcall(PA().DebugService.purgeActor, actor(uid), "storyengine_support_done")
            end
            s.phase = "done"
            log("alife support removed", s.fid, #living)
        end
    end
end

-- ---------------------------------------------------------------- auto support

-- 보낼 수 있는 세력인가: A-Life 세력이 있고, 안전 자원이 바닥이 아니다 (Life.lua)
local function canSend(fid)
    if not ALife.FACTIONS[fid] or Factions.isGone(fid) then return false end
    local Life = StoryEngine.Life
    return not Life or Life.get(fid, "safety") >= Life.SELF_MIN
end

-- 가장 신뢰하는 세력 (AUTO_TRUST 이상). 같으면 무작위. key: 위험한 사람 (개인 모드면 그 사람의 개인 신뢰)
local function bestFriend(key)
    local top = ALife.AUTO_TRUST
    for _, f in ipairs(Factions.list) do
        if canSend(f.id) and trustOf(f.id, key, true) > top then top = trustOf(f.id, key, true) end
    end
    local best = {}
    for _, f in ipairs(Factions.list) do
        local t = canSend(f.id) and trustOf(f.id, key, true) or -1
        if t >= ALife.AUTO_TRUST and t == top then best[#best + 1] = f.id end
    end
    if #best == 0 then return nil end
    return best[ZombRand(#best) + 1]
end

local function nearbyZombies(player, radius)
    local list = getCell() and getCell():getZombieList()
    if not list then return 0 end
    local px, py, n = player:getX(), player:getY(), 0
    local r2 = radius * radius
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        local dx, dy = z:getX() - px, z:getY() - py
        if dx * dx + dy * dy <= r2 and not z:isDead() then n = n + 1 end
    end
    return n
end

local function badlyHurt(player)
    local bd = player:getBodyDamage()
    if bd:getOverallBodyHealth() < ALife.DANGER_HP then return true end
    local parts = bd:getBodyParts()
    for i = 0, parts:size() - 1 do
        local bp = parts:get(i)
        if bp:deepWounded() or bp:bleeding() then return true end
    end
    return false
end

-- 이 플레이어를 쫓는 우리 추적 무리(좀비 호드) 중 가까이 온 것
local function huntNear(player)
    local key = Store.playerKey(player)
    local px, py = player:getX(), player:getY()
    for _, h in pairs(Store.data().hunts or {}) do
        if h.target == key and (tonumber(h.remaining) or 0) > 0 and tonumber(h.x)
            and dist(h.x, h.y, px, py) <= ALife.HUNT_TRIGGER_DIST then
            return h
        end
    end
    return nil
end

-- 위험 판단: 좀비에 둘러싸여 크게 다쳤거나, 습격(A-Life 의 강도·습격·교전, 이 모드의 추적 호드·무장 무리)의 대상이 됐다
function ALife.danger(player)
    local _, event = ALife.threatsTo(player)
    if event == "se_attack" then return "an armed gang sent to hunt them down is attacking them" end
    if event == "robbery" then return "being robbed at gunpoint" end
    if event == "raid" then return "an armed gang is raiding them" end
    if event == "attack" then return "armed people are attacking them" end
    local h = huntNear(player)
    if h then
        return "a pack of about " .. StoryEngine.intToString(h.remaining) .. " of the dead is hunting them and almost on them"
    end
    local zombies = nearbyZombies(player, ALife.DANGER_RADIUS)
    if zombies >= ALife.DANGER_ZOMBIES and badlyHurt(player) then
        return "about " .. StoryEngine.intToString(zombies) .. " of the dead around them and badly hurt"
    end
    return nil
end

function ALife.checkAuto()
    if not ALife.enabled() or not ALife.available() then return end
    -- 개인 모드는 사람마다 그 사람이 가장 믿는 세력 (아래), 아니면 서버에 하나
    local personal = personalMode()
    local shared = nil
    if not personal then
        shared = bestFriend()
        if not shared then return end
    end
    local st = state()
    local now = Sensor.now()
    for _, p in ipairs(Sensor.players()) do
        local ps = Store.player(p)
        local last = st.autoAt[ps.key]
        local fid = shared
        if personal and not ps.dead then fid = bestFriend(ps.key) end
        if fid and not ps.dead and not activeFor(ps.key) and not (last and now.t - last < ALife.AUTO_COOLDOWN_MIN) then
            local reason = ALife.danger(p)
            if reason then
                local ok, why = ALife.sendSupport(p, fid, "auto", reason)
                log("alife auto support", ps.name, fid, reason, ok and "sent" or tostring(why))
            end
        end
    end
end

-- ---------------------------------------------------------------- attack

-- 적대 세력의 무장 무리를 보낸다 (협박 보복). 거리는 추적 무리와 같다.
function ALife.sendAttack(player, fid, tries)
    if not ALife.enabled() or not ALife.available() or not ALife.FACTIONS[fid] then return false, "unavailable" end
    if Factions.isGone(fid) then return false, "gone" end      -- 떠난 세력의 습격대는 없다 (점검 D4)
    tries = tries or 0
    local stage = Store.stage(Store.player(player))
    local ok, info = ALife.spawnSquad(player, fid, ALife.ATTACK_LEVEL[stage], ALife.ATTACK_SIZE[stage], false,
        ALife.ATTACK_DIST, "attack", {
            done = function(outcome)
                if (tonumber(outcome.active) or 0) > 0 then
                    log("alife attack arrived", fid, outcome.active)
                    if StoryEngine.Banter then
                        pcall(StoryEngine.Banter.onEvent, player, "armed_attack", { faction = fid, count = outcome.active })
                    end
                    return
                end
                -- 한 명이라도 못 나오면 그룹이 통째로 취소된다 (square_blocked, in_player_view)
                if tries < ALife.ATTACK_RETRIES and not player:isDead() then
                    log("alife attack spawn failed, retrying", fid, tostring(outcome.reason))
                    ALife.sendAttack(player, fid, tries + 1)
                elseif StoryEngine.Hunt and not player:isDead() then
                    log("alife attack spawn failed, sending a horde instead", fid, tostring(outcome.reason))
                    StoryEngine.Hunt.sendAt(player, "extort_punish")
                end
            end,
        })
    if ok and tries == 0 then
        local now = Sensor.now()
        Store.addNote(Store.player(player), { kind = "alife_attack", faction = fid, count = info.count, clock = now.clock })
    end
    return ok, info
end

-- ---------------------------------------------------------------- tick / status

function ALife.tick()
    if not ALife.available() then return end
    ALife.installGuards()
    local st = state()
    for id, s in pairs(st.active) do
        if s.phase == "done" then
            st.active[id] = nil
        elseif s.uids and #s.uids > 0 then
            local ok, err = pcall(ALife.refresh, s)
            if not ok then log("alife refresh error:", err) end
        elseif not ALife.pending[id] and Sensor.now().t - (s.startT or 0) > 30 then
            st.active[id] = nil        -- 스폰 결과를 못 받음 (재시작 등)
        end
    end
    local ok, err = pcall(ALife.checkAuto)
    if not ok then log("alife auto error:", err) end
end

-- 클라이언트 무전 탭용: 세력별 지원 가능 여부
function ALife.channelInfo()
    if not ALife.enabled() or not ALife.available() then return nil end
    local st, now = state(), Sensor.now()
    local out = {}
    for _, f in ipairs(Factions.list) do
        local last = st.cooldown[f.id]
        local wait = last and math.max(0, math.ceil((ALife.REQUEST_COOLDOWN_MIN - (now.t - last)) / 60)) or 0
        out[f.id] = { level = ALife.level(trustOf(f.id)), wait = wait }
    end
    return out
end

function ALife.statusText()
    if not ALife.available() then return "alife: off" end
    local parts = {}
    for _, s in pairs(state().active) do
        parts[#parts + 1] = s.fid .. "/" .. tostring(s.alifeFaction) .. " " .. tostring(s.phase) .. " x" .. #(s.uids or {})
            .. " for " .. tostring(s.targetName)
    end
    return "alife: " .. (#parts > 0 and table.concat(parts, ", ") or "no support")
end

Events.EveryOneMinute.Add(function()
    local ok, err = pcall(ALife.tick)
    if not ok then log("alife tick error:", err) end
end)

-- 아군 보호는 실시간으로 자주 (반격은 맞는 즉시 시작된다)
ALife.lastProtectMs = 0
Events.OnTick.Add(function()
    local now = nowMs()
    if now - ALife.lastProtectMs < ALife.PROTECT_MS then return end
    ALife.lastProtectMs = now
    local d = Store.data()
    if not d.alife or not ALife.available() then return end
    for _, s in pairs(d.alife.active) do
        if s.phase ~= "done" and s.uids and #s.uids > 0 then
            local ok, err = pcall(ALife.protect, s)
            if not ok then log("alife protect error:", err) end
        end
    end
end)

return ALife
