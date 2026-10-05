-- NPC 특기 지원 (서버 측 전용, 2026-09-29 2단계). 설계: docs/DESIGN_NPC_LIFE.md
--
-- 거점 탭의 [특기] 버튼으로 요청한다. 공통 조건: 신뢰도 40 이상(구간 40~59 = 1, 60~79 = 2, 80~ = 3), 핵심 생활 자원 20 이상,
-- NPC 별 대기 시간(서버 전체). 쓰면 핵심 자원 -10(구간 3은 -15), 행적·일지, NPC 무전 연기. 특기별 조건이 안 되면
-- 아무것도 쓰지 않고 이유만 알린다. 플레이어 대가는 없다.
--   guard  A-Life 분대(4/6/8명·2/4/6시간), A-Life 가 없으면 저격 10/20/30
--   doc    치료 (클라이언트에서 10초 가만히 있으면 specHealDone -> 서버가 상처를 고치고 syncBodyPart)
--   dewey  1~2시간 뒤 가까운 차량 수리
--   casey  3/6/12시간 정찰: 추적 무리 / + 적대 A-Life 무리 / + 좀비 밀집, 지도 표시와 혼잣말 경고
--   ray    다른 NPC 의 부족한 자원에 +20/30/45 (레이 식량 -15)
--   pike   스트레스·불행·지루함 감소, 구간 2 공포 없음 6시간, 구간 3 공포·근육통 없음 12시간
--   hunter 저격 10/20/30 (30분에 나눠)
--   rats   60~80타일 밖 미끼 소음
-- 저격은 요청한 클라이언트가 좀비를 쓰러뜨리고 총성은 그 플레이어만 듣는다 (실제 소음 판정 없음, 좀비를 끌지 않는다).

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Radio"
require "StoryEngine/Trust"
require "StoryEngine/Life"
require "StoryEngine/ALife"

local Net = StoryEngine.Net
local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Radio = StoryEngine.Radio
local Life = StoryEngine.Life
local ALife = StoryEngine.ALife
local log = StoryEngine.log

local Specialty = {
    healPending = {},     -- psKey -> { fid, tier, ms }
}
StoryEngine.Specialty = Specialty

Specialty.TIER_MIN = { 40, 60, 80 }
Specialty.COOLDOWN_DAYS = { guard = 7, doc = 7, dewey = 7, casey = 3, ray = 7, pike = 3, hunter = 3, rats = 1 }
-- 대기 범위 (2026-10-05 샌드박스 SpecialtyScope_<fid>): 1 서버 전체 / 2 개인별 / 3 둘 다 (다른 사람은 SHARED_GAP_DAYS)
-- 기본: 레이만 서버 전체 (보급이 다른 NPC 자원을 올리는 세계 효과라 개인별이면 여럿이 끌어올릴 수 있다), 나머지 개인별
Specialty.SCOPE = { ray = 1, casey = 2, doc = 2, pike = 2, dewey = 2, guard = 2, rats = 2, hunter = 2 }
Specialty.SHARED_GAP_DAYS = 1
Specialty.ANTENNA_COOLDOWN = 2 / 3                     -- 케이시 안테나 완성: 정찰 대기 x2/3 (기본 3 -> 2일)
Specialty.COST = { 10, 10, 15 }                        -- 구간별 핵심 자원 소모
Specialty.SQUAD_LEVEL = { 1, 3, 5 }                    -- 방위대 분대 시간: ALife.HOURS 의 칸 -> 2/4/6시간
Specialty.SQUAD_SIZE = { 2, 4, 6 }                     -- 방위대 분대 인원 (2026-09-30: 4/6/8 -> 2/4/6, 검문소 완성이면 +2)
-- 2026-09-29: 행크 10/15/20 -> 10/20/30. 2026-09-30: A-Life 없는 방위대는 행크의 2배를 4배 느리게 (4시간)
Specialty.SNIPE = { hunter = { 10, 20, 30 }, guard = { 20, 40, 60 } }
Specialty.SNIPE_SOUND = { hunter = "MSR788Shoot", guard = "M14Shoot" }
-- 이 게임 시간(분)에 나눠 쏜다 (2026-09-29 행크 60 -> 30). 방위대는 2배 수를 발사 간격 4배로 = 240분
Specialty.SNIPE_MIN = { hunter = 30, guard = 240 }
Specialty.SNIPE_PROJECT = { hunter = 10, guard = 20 }   -- 겨울 오두막 / 검문소 완성 (방위대는 A-Life 가 없을 때만)
Specialty.SNIPE_MAX_KILLS = 100                        -- 요청 수를 모를 때 (재접속 등)
Specialty.snipeCap = {}                                -- ps.key -> 이번 저격 요청 수 (메모리만)
Specialty.SNIPE_RADIUS = 30
Specialty.HEAL_WAIT_MS = 2 * 60 * 1000                 -- 치료 동작을 끝내야 하는 실시간
Specialty.HEAL_COST = 10                               -- 닥 치료 의약품 (가장 심각한 상처 하나)
Specialty.HEAL_PARTS_CLINIC = 2                        -- 진료소 완성 시 치료하는 부위 수 (2026-10-02, 예전: 의약품 절반)
Specialty.REPAIR = { { add = 30, max = 70 }, { add = 50, max = 85 }, { add = 100, max = 100 } }
Specialty.ENGINE_SHARE = 0.5                           -- 엔진은 수리량의 절반 (게임에서도 고치기 힘든 부품, 2026-09-30)
Specialty.REPAIR_DELAY = { 480, 600 }                  -- 듀이 도착 (2026-09-30: 1~2시간 -> 8~10시간)
Specialty.REPAIR_DELAY_ARK = { 30, 60 }                -- 듀이의 Ark 트럭 프로젝트 완성 후
Specialty.REPAIR_RADIUS = 10
Specialty.REPAIR_KEEP_MIN = 3 * 24 * 60                -- 차가 로드되지 않으면 이만큼 기다린다
Specialty.SCOUT_HOURS = { 3, 6, 12 }
Specialty.SCOUT_RADIUS = 150
Specialty.SCOUT_RADIUS_ANTENNA = 250                   -- 케이시 중계 안테나 완성 후 (정찰 대기도 3 -> 2일)
Specialty.SCOUT_REFRESH_MIN = 10
Specialty.WARN_DIST = 40
Specialty.WARN_GAP_MIN = 30
Specialty.CLUSTER_CELL = 10
Specialty.CLUSTER_MIN = 15
Specialty.RAY_SUPPLY = { 20, 30, 45 }
Specialty.RAY_COST = 15
Specialty.COMFORT = { 0.3, 0.5, 0.8 }                  -- 스트레스·불행·지루함 감소 비율
Specialty.NO_FEAR_HOURS = { 0, 6, 12 }
Specialty.COMFORT_RADIUS = 10
Specialty.DECOY_DIST = { 60, 80 }
Specialty.DECOY_RADIUS = { 80, 120, 160 }
Specialty.DECOY_MIN = { 10, 30 }
Specialty.DECOY_CLEAR = 50                             -- 소음 지점에서 이 거리 안에 플레이어가 없는 방향

local function state()
    local d = Store.data()
    d.spec = d.spec or {}
    local s = d.spec
    s.used = s.used or {}           -- fid -> 마지막으로 쓴 시각 (누구든)
    s.usedBy = s.usedBy or {}       -- fid -> { 플레이어 키 -> 그 사람이 마지막으로 쓴 시각 }
    s.jobs = s.jobs or {}
    s.scout = s.scout or {}
    s.comfort = s.comfort or {}
    s.decoys = s.decoys or {}
    return s
end

local function rand(range) return range[1] + ZombRand(range[2] - range[1] + 1) end

local function dist(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

local DIR_CODES = { "E", "SE", "S", "SW", "W", "NW", "N", "NE" }
local function dirCode(dx, dy)
    local angle = math.atan2(dy, dx) * 180 / math.pi
    return DIR_CODES[math.floor(((angle + 360 + 22.5) % 360) / 45) + 1]
end

local function projectDone(fid)
    return StoryEngine.Projects ~= nil and StoryEngine.Projects.done(fid)
end

-- NPC 별 대기 일수 (샌드박스 일수·배율, 장기 프로젝트 반영)
function Specialty.cooldownDays(fid)
    local days = Specialty.COOLDOWN_DAYS[fid] or 3
    if fid == "casey" and projectDone("casey") then days = days * Specialty.ANTENNA_COOLDOWN end
    return days
end

function Specialty.scope(fid)
    local v = StoryEngine.Tuning and StoryEngine.Tuning.num("SpecialtyScope_" .. tostring(fid)) or 0
    if v < 1 or v > 3 then v = Specialty.SCOPE[fid] or 1 end
    return math.floor(v)
end

-- 이 사람(psKey)이 기다려야 하는 분 (0 이면 지금 가능). 키가 없으면 서버 전체 기준
function Specialty.waitMinutes(fid, psKey, now)
    local s = state()
    local days = Specialty.cooldownDays(fid) * 24 * 60
    local function left(last, gap)
        if not last then return 0 end
        return math.max(0, gap - (now - last))
    end
    local scope = Specialty.scope(fid)
    local mine = psKey and (s.usedBy[fid] or {})[psKey] or nil
    if scope == 1 or not psKey then return left(s.used[fid], days) end
    if scope == 2 then return left(mine, days) end
    return math.max(left(mine, days), left(s.used[fid], math.min(days, Specialty.SHARED_GAP_DAYS * 24 * 60)))
end

local function scoutRadius()
    return projectDone("casey") and Specialty.SCOUT_RADIUS_ANTENNA or Specialty.SCOUT_RADIUS
end

local function playerByKey(key)
    for _, p in ipairs(Sensor.players()) do
        if Store.playerKey(p) == key then return p end
    end
    return nil
end

function Specialty.enabled()
    return StoryEngine.option("Specialty", true) == true
end

function Specialty.tier(trust)
    for t = #Specialty.TIER_MIN, 1, -1 do
        if trust >= Specialty.TIER_MIN[t] then return t end
    end
    return 0
end

-- 거점 탭 표시: { tier, wait(시간), scope, reason = nil | off | low_trust | cooldown | no_resource }
-- psKey = 보는 사람 (개인별 대기). 없으면 서버 전체 기준
function Specialty.status(fid, psKey)
    if not Factions.byId[fid] then return nil end
    local tier = Specialty.tier(Radio.channel(fid).trust)
    local now = Sensor.now()
    local wait = math.ceil(Specialty.waitMinutes(fid, psKey, now.t) / 60)
    local reason = nil
    if Factions.isGone(fid) then
        reason = "gone"
    elseif StoryEngine.Saga and StoryEngine.Saga.specialtyBlocked(fid) then
        reason = "ill"                                  -- 큰 사건 "열병 유행"에서 닥이 쓰러졌다
    elseif not Specialty.enabled() then
        reason = "off"
    elseif tier == 0 then
        reason = "low_trust"
    elseif wait > 0 then
        reason = "cooldown"
    elseif Life.get(fid, Life.KEY[fid] or "morale") < Life.SELF_MIN then
        reason = "no_resource"
    end
    return { tier = tier, wait = wait, reason = reason, scope = Specialty.scope(fid) }
end

-- 대기 초기화 (디버그, A-Life 지원 실패 환불). psKey 가 있으면 그 사람의 대기와 서버 전체 대기, 없으면 모두.
-- 듀이는 기다리는 수리도 바로 하게 한다 (디버그)
function Specialty.clearWait(fid, psKey)
    local s = state()
    s.used[fid] = nil
    if psKey then
        if s.usedBy[fid] then s.usedBy[fid][psKey] = nil end
        return
    end
    s.usedBy[fid] = nil
    if fid == "dewey" then
        local now = Sensor.now()
        for _, job in ipairs(state().jobs) do
            if job.kind == "repair" then job.dueT = math.min(job.dueT, now.t) end
        end
    end
end

-- 특기를 쓴 것으로 기록한다: 대기, 자원, 행적, 일지, 무전
function Specialty.commit(fid, ps, tier, info)
    local now = Sensor.now()
    local s = state()
    s.used[fid] = now.t
    if ps and ps.key then
        s.usedBy[fid] = s.usedBy[fid] or {}
        s.usedBy[fid][ps.key] = now.t
    end
    local cost = info.cost or Specialty.COST[tier] or 10
    Life.change(fid, info.costRes or Life.KEY[fid] or "morale", -cost, "specialty")
    Life.record(fid, "specialty", ps and ps.name or nil, 0, { spec = fid })
    if ps then
        Store.addNote(ps, { kind = info.note or ("specialty_" .. fid), faction = fid, clock = now.clock,
                            count = info.count, item = info.item })
    end
    if info.topic then
        Radio.react(fid, "event", info.topic .. " Keep it short and in character.",
            { text = info.fallbackText or "On it.", lt = { key = "IGUI_StoryEngine_RadioSay_spec_" .. fid } }, ps,
            { overhead = true })
    end
    log("specialty", fid, "tier", tier, "for", ps and ps.name or "?")
end

-- ---------------------------------------------------------------- 저격 (행크, A-Life 없는 방위대)

local function zombiesNear(x, y, radius)
    local out = {}
    local list = getCell() and getCell():getZombieList()
    if not list then return out end
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        if z and not z:isDead() and dist(z:getX(), z:getY(), x, y) <= radius then out[#out + 1] = z end
    end
    return out
end

local function snipe(player, ps, fid, tier)
    local count = Specialty.SNIPE[fid][tier]
    if projectDone(fid) then count = count + (Specialty.SNIPE_PROJECT[fid] or 0) end   -- 겨울 오두막 / 검문소
    if #zombiesNear(player:getX(), player:getY(), Specialty.SNIPE_RADIUS) == 0 then return false, "no_targets" end
    local minutes = Specialty.SNIPE_MIN[fid] or 30
    Specialty.snipeCap[ps.key] = count            -- 끝났을 때 보고한 처치 수를 이만큼으로 자른다
    Net.toClient(player, "specSnipe", { faction = fid, count = count, minutes = minutes,
                                        radius = Specialty.SNIPE_RADIUS, sound = Specialty.SNIPE_SOUND[fid] })
    local who = fid == "guard" and "Your squad's marksman is" or "You are"
    local span = minutes >= 120 and ("the next " .. StoryEngine.intToString(math.floor(minutes / 60)) .. " hours, slow and careful")
        or "the next half hour"
    return true, { count = count, note = "specialty_snipe_start",
                   topic = who .. " covering " .. tostring(ps.name) .. " with a rifle from far off for " .. span .. ", "
                       .. "taking down the dead around them (up to " .. StoryEngine.intToString(count) .. ")." }
end

-- 요청한 클라이언트가 저격을 마쳤다 (쓰러뜨린 수, 요청 수를 넘지 않게)
function Specialty.snipeDone(player, fid, kills)
    local ps = Store.player(player)
    local cap = Specialty.snipeCap[ps.key] or Specialty.SNIPE_MAX_KILLS
    Specialty.snipeCap[ps.key] = nil
    kills = math.max(0, math.min(cap, math.floor(tonumber(kills) or 0)))
    Store.addNote(ps, { kind = "specialty_snipe", faction = fid, count = kills, clock = Sensor.now().clock })
    log("specialty snipe done", fid, ps.name, kills)
end

-- ---------------------------------------------------------------- 닥: 치료

-- 고칠 수 있는 상처 목록 (구간별). 가장 심각한 것 하나만 고친다 (2026-09-30 사용자 결정: 전부 고치면 밸런스가 무너짐)
-- 심각도: 총알 9 > 골절 8 > 화상 7 > 깊은 상처 6 > 상처 감염 5 > (구간 2) 골절 절반 4.5 > 유리 4 > 베임 3 > 출혈 2 > 긁힘 1
-- 물림과 좀비 감염은 절대 건드리지 않는다
local function woundsOf(player, tier)
    local out = {}
    local parts = player:getBodyDamage():getBodyParts()
    for i = 0, parts:size() - 1 do
        local bp = parts:get(i)
        local function add(sev, kind, cond, action)
            if cond then out[#out + 1] = { sev = sev, kind = kind, bp = bp, action = action } end
        end
        add(1, "scratch", bp:scratched(), function() bp:setScratched(false, true); bp:setScratchTime(0); bp:setBleedingTime(0) end)
        add(3, "cut", bp:isCut(), function() bp:setCut(false); bp:setCutTime(0); bp:setBleedingTime(0) end)
        add(2, "bleeding", bp:getBleedingTime() > 0 and not bp:deepWounded() and not bp:isCut() and not bp:scratched(),
            function() bp:setBleedingTime(0) end)
        if tier >= 2 then
            add(6, "deep wound", bp:deepWounded(), function()
                bp:setDeepWoundTime(0)
                bp:setDeepWounded(false)
                bp:setBleedingTime(0)
            end)
            add(4, "glass shard", bp:haveGlass(), function() bp:setHaveGlass(false) end)
            add(5, "infected wound", bp:isInfectedWound(), function() bp:setWoundInfectionLevel(-1) end)
            add(4.5, "fracture (half)", tier == 2 and bp:getFractureTime() > 0,
                function() bp:setFractureTime(bp:getFractureTime() / 2) end)
        end
        if tier >= 3 then
            add(9, "bullet", bp:haveBullet(), function() bp:setHaveBullet(false, 0) end)
            add(7, "burn", bp:getBurnTime() > 0, function()
                bp:setBurnTime(0)
                bp:setNeedBurnWash(false)
            end)
            add(8, "fracture", bp:getFractureTime() > 0, function() bp:setFractureTime(0) end)
        end
    end
    table.sort(out, function(a, b) return a.sev > b.sev end)
    return out
end

-- 치료. apply 가 아니면 고칠 수 있는 상처 수만 센다. apply 면 서로 다른 부위 parts 곳(기본 1)에서 각각 가장 심각한
-- 상처 하나씩을 고치고, 고친 수와 종류(영어, 쉼표로 이음)를 돌려준다
function Specialty.treat(player, tier, apply, parts)
    local list = woundsOf(player, tier)
    if not apply then return #list end
    parts = math.max(1, math.floor(parts or 1))
    local done, kinds, used = 0, {}, {}
    for _, w in ipairs(list) do
        if done >= parts then break end
        if not used[w.bp] then
            used[w.bp] = true
            local ok, err = pcall(w.action)
            if not ok then log("treat error:", err) end
            pcall(function() w.bp:setAdditionalPain(tier >= 3 and 0 or w.bp:getAdditionalPain() * 0.5) end)
            pcall(syncBodyPart, w.bp, 0xFFFFFFFFFFF)
            done = done + 1
            kinds[#kinds + 1] = w.kind
        end
    end
    if done == 0 then return 0 end
    return done, table.concat(kinds, ", ")
end

local function heal(player, ps, fid, tier)
    if Specialty.treat(player, tier, false) == 0 then return false, "no_wounds" end
    Specialty.healPending[ps.key] = { fid = fid, tier = tier, ms = StoryEngine.nowMs() }
    log("specialty heal start", fid, "tier", tier, "for", ps.name)
    Net.toClient(player, "specHealStart", { faction = fid, tier = tier })
    return true, { pending = true }
end

-- 클라이언트가 10초 동안 가만히 있었다
function Specialty.healDone(player)
    local ps = Store.player(player)
    local p = Specialty.healPending[ps.key]
    Specialty.healPending[ps.key] = nil
    if not p or StoryEngine.nowMs() - p.ms > Specialty.HEAL_WAIT_MS then return false, "expired" end
    local st = Specialty.status(p.fid, ps.key)
    if st.reason then return false, st.reason end
    -- 진료소 확장: 서로 다른 두 부위를 치료한다
    local parts = projectDone("doc") and Specialty.HEAL_PARTS_CLINIC or 1
    local n, kind = Specialty.treat(player, p.tier, true, parts)
    if n == 0 then return false, "no_wounds" end
    local what = n > 1 and ("their worst injuries on " .. StoryEngine.intToString(n) .. " different parts of the body")
        or "their worst injury"
    Specialty.commit(p.fid, ps, p.tier, {
        count = n, cost = Specialty.HEAL_COST,
        topic = "You just talked " .. tostring(ps.name) .. " through treating " .. what .. " over the radio ("
            .. tostring(kind) .. "). Only " .. (n > 1 and "those are" or "that one is")
            .. " taken care of. Tell them how to look after it now, like a nurse would.",
    })
    return true, n
end

-- ---------------------------------------------------------------- 듀이: 차량 수리

-- 셀의 차량 목록. 멀티 서버(인게임 호스트)의 목록은 size 는 있어도 get 이 없다 (2026-09-29 로그
-- "Object tried to call nil in vehiclesNear") -> A-Life 처럼 toArray 를 먼저 쓴다.
-- (get 을 pcall 로 시도하면 막혀도 게임이 오류 기록을 남긴다)
local function eachVehicle(fn)
    local cell = getCell()
    local list = cell and cell:getVehicles()
    if not list then return end
    if list.toArray then
        for _, v in pairs(list:toArray()) do fn(v) end
        return
    end
    for i = 0, list:size() - 1 do fn(list:get(i)) end
end

local function vehiclesNear(x, y, radius)
    local out = {}
    eachVehicle(function(v)
        local d = v and dist(v:getX(), v:getY(), x, y)
        if d and d <= radius then out[#out + 1] = { v = v, d = d } end
    end)
    table.sort(out, function(a, b) return a.d < b.d end)
    return out
end

-- 아이템 칸이 없는 부품인가 (엔진). 칸은 있는데 비어 있으면 빠진 부품이라 고치지 않는다
local function structural(part)
    local ok, types = pcall(function() return part:getItemType() end)
    return ok and (types == nil or types:isEmpty())
end

function Specialty.repairVehicle(v, tier)
    local r = Specialty.REPAIR[tier] or Specialty.REPAIR[1]
    local fixed = 0
    for i = 0, v:getPartCount() - 1 do
        local part = v:getPartByIndex(i)
        local item = part and part:getInventoryItem()
        local engine = part and not item and structural(part)
        if part and (item or engine) then
            local cond = part:getCondition()
            local add = engine and math.floor(r.add * Specialty.ENGINE_SHARE) or r.add
            local target = math.min(r.max, cond + add)
            if target > cond then
                part:setCondition(target)
                if item then
                    pcall(function() item:setCondition(target) end)
                    pcall(function() part:doInventoryItemStats(item, part:getMechanicSkillInstaller()) end)
                    pcall(function() v:transmitPartItem(part) end)
                end
                -- 엔진은 바닐라 ISRepairEngine:complete 와 같이 상태만 바꾸고 보낸다
                pcall(function() v:transmitPartCondition(part) end)
                fixed = fixed + 1
            end
            if item and tier >= 3 and part:getId() == "Battery" then
                pcall(function() item:setCurrentUsesFloat(1.0) end)
                pcall(function() item:setUsedDelta(1.0) end)
                pcall(function() v:transmitPartItem(part) end)
            end
        end
    end
    pcall(function() v:updatePartStats() end)
    return fixed
end

local function repair(player, ps, fid, tier)
    local near = vehiclesNear(player:getX(), player:getY(), Specialty.REPAIR_RADIUS)
    if #near == 0 then return false, "no_vehicle" end
    local v = near[1].v
    local now = Sensor.now()
    -- 요청할 때 고른 차량을 기억한다: 세이브에도 유지되는 sqlId, 없으면 실행 중 id 와 위치
    local okSql, sql = pcall(function() return v:getSqlId() end)
    local delay = projectDone("dewey") and Specialty.REPAIR_DELAY_ARK or Specialty.REPAIR_DELAY
    local job = { kind = "repair", id = v:getId(), sql = okSql and sql or nil, x = v:getX(), y = v:getY(), tier = tier,
                  target = ps.key, dueT = now.t + rand(delay), madeT = now.t }
    local jobs = state().jobs
    jobs[#jobs + 1] = job
    local mins = job.dueT - now.t
    local when = mins >= 90 and ("about " .. StoryEngine.intToString(math.floor(mins / 60 + 0.5)) .. " hours")
        or ("about " .. StoryEngine.intToString(math.floor(mins / 10 + 0.5) * 10) .. " minutes")
    return true, { topic = "You are heading over to fix " .. tostring(ps.name) .. "'s vehicle. You will be there in "
        .. when .. " and they do not need to wait by it." }
end

-- 요청 때 고른 그 차량을 찾는다: sqlId 가 같으면 어디로 옮겨졌든 그 차 (로드돼 있을 때),
-- 없으면 실행 중 id(같은 자리 근처), 그래도 없으면 기억한 자리 5타일 안의 차
local function findVehicle(job)
    if job.sql then
        local found = nil
        eachVehicle(function(v)
            local ok, sql = pcall(function() return v:getSqlId() end)
            if ok and sql == job.sql then found = v end
        end)
        if found then return found end
    end
    local ok, v = pcall(getVehicleById, job.id)
    if ok and v and v.getX and dist(v:getX(), v:getY(), job.x, job.y) <= 5 then return v end
    local near = vehiclesNear(job.x, job.y, 5)
    return near[1] and near[1].v or nil
end

local function runJobs(now)
    local jobs = state().jobs
    local keep = {}
    for _, job in ipairs(jobs) do
        if job.kind == "repair" and now.t >= job.dueT then
            local v = findVehicle(job)
            if v then
                local fixed = Specialty.repairVehicle(v, job.tier)
                log("specialty repair done", job.target, "parts", fixed)
                local ps = Store.data().players[job.target]
                if ps then Store.addNote(ps, { kind = "specialty_dewey_done", faction = "dewey", clock = now.clock }) end
                Radio.react("dewey", "event", "You just finished fixing up " .. tostring(ps and ps.name or "their")
                    .. " vehicle (" .. StoryEngine.intToString(fixed) .. " parts). Tell them it is ready. Keep it short.",
                    { text = "Your ride's fixed.", lt = { key = "IGUI_StoryEngine_RadioSay_spec_dewey_done" } }, ps,
                    { overhead = true })
            elseif now.t - job.dueT < Specialty.REPAIR_KEEP_MIN then
                keep[#keep + 1] = job
            else
                log("specialty repair dropped", job.target)
            end
        else
            keep[#keep + 1] = job
        end
    end
    state().jobs = keep
end

-- ---------------------------------------------------------------- 케이시: 정찰

-- 지금 표시할 것들: { id, kind = hunt | hostile | horde, x, y, n }
function Specialty.scan(player, tier)
    local px, py = player:getX(), player:getY()
    local key = Store.playerKey(player)
    local marks = {}
    for id, h in pairs(Store.data().hunts or {}) do
        if h.target == key and (h.remaining or 0) > 0 and h.x and dist(h.x, h.y, px, py) <= scoutRadius() then
            marks[#marks + 1] = { id = "H" .. tostring(id), kind = "hunt", x = math.floor(h.x), y = math.floor(h.y), n = h.remaining }
        end
    end
    local radius = scoutRadius()
    if tier >= 2 and ALife.enabled() and ALife.available() then
        for _, g in ipairs(ALife.hostileGroups(player, radius)) do
            marks[#marks + 1] = { id = "A" .. math.floor(g.x / 20) .. "_" .. math.floor(g.y / 20), kind = "hostile",
                                  x = math.floor(g.x), y = math.floor(g.y), n = g.n }
        end
    end
    if tier >= 3 then
        local cells = {}
        local size = Specialty.CLUSTER_CELL
        for _, z in ipairs(zombiesNear(px, py, radius)) do
            local cx, cy = math.floor(z:getX() / size), math.floor(z:getY() / size)
            local k = cx .. "_" .. cy
            local c = cells[k] or { n = 0, sx = 0, sy = 0 }
            c.n, c.sx, c.sy = c.n + 1, c.sx + z:getX(), c.sy + z:getY()
            cells[k] = c
        end
        for k, c in pairs(cells) do
            if c.n >= Specialty.CLUSTER_MIN then
                marks[#marks + 1] = { id = "Z" .. k, kind = "horde", x = math.floor(c.sx / c.n), y = math.floor(c.sy / c.n), n = c.n }
            end
        end
    end
    return marks
end

local function scout(player, ps, fid, tier)
    local now = Sensor.now()
    local hours = Specialty.SCOUT_HOURS[tier]
    state().scout[ps.key] = { untilT = now.t + hours * 60, tier = tier, warned = {}, lastScanT = -1000 }
    Specialty.scoutTick(now)
    return true, { topic = "You are watching the area around " .. tostring(ps.name) .. " for the next "
        .. StoryEngine.intToString(hours) .. " hours and marked what you found on their map. You will warn them when something gets close." }
end

local function sendMarks(player, marks, untilT, now)
    Net.toClient(player, "scoutMarks", { marks = marks, hoursLeft = math.max(0, math.ceil((untilT - now.t) / 60)) })
end

local function warn(player, ps, m)
    local dx, dy = m.x - player:getX(), m.y - player:getY()
    local d = math.floor(math.sqrt(dx * dx + dy * dy) / 5) * 5
    local lt = { key = "IGUI_StoryEngine_Scout_Warn_" .. m.kind,
                 args = { { t = "dir", v = dirCode(dx, dy) }, { t = "num", v = d } } }
    if StoryEngine.Monologue and StoryEngine.Monologue.sayPrepared then
        StoryEngine.Monologue.sayPrepared(player, ps, "scout", lt)
    end
end

function Specialty.scoutTick(now)
    local s = state()
    for key, sc in pairs(s.scout) do
        local player = playerByKey(key)
        if now.t >= sc.untilT then
            s.scout[key] = nil
            if player then sendMarks(player, {}, sc.untilT, now) end
        elseif player and not player:isDead() then
            local refresh = now.t - (sc.lastScanT or -1000) >= Specialty.SCOUT_REFRESH_MIN
            local marks = Specialty.scan(player, sc.tier)
            if refresh then
                sc.lastScanT = now.t
                sendMarks(player, marks, sc.untilT, now)
            end
            local ps = Store.player(player)
            for _, m in ipairs(marks) do
                local last = sc.warned[m.id]
                if dist(m.x, m.y, player:getX(), player:getY()) <= Specialty.WARN_DIST
                    and (not last or now.t - last >= Specialty.WARN_GAP_MIN) then
                    sc.warned[m.id] = now.t
                    warn(player, ps, m)
                end
            end
        end
    end
end

-- ---------------------------------------------------------------- 레이: 다른 NPC 에 보급

local function supply(player, ps, fid, tier, args)
    local target = tostring(args.target or "")
    if target == fid or not Factions.byId[target] or Factions.isGone(target) then return false, "no_target" end
    -- 레이는 빅을 싫어하면(관계 음수) 구간 3 에서만 보낸다. 관계가 풀렸으면 (Bonds) 구간과 상관없이
    if target == "rats" and tier < 3 and StoryEngine.Bonds.get("ray", "rats") < 0 then return false, "ray_refuses" end
    local amount = Specialty.RAY_SUPPLY[tier]
    -- 가장 부족한 자원부터 5씩 채운다
    local gained = {}
    local left = amount
    while left > 0 do
        local r, v = Life.lowest(target)
        if v >= 100 then break end
        local got = Life.change(target, r, math.min(5, left), "ray_supply")
        if got <= 0 then break end
        gained[r] = (gained[r] or 0) + got
        left = left - got
    end
    StoryEngine.Trust.apply(target, 1, "ray_supply", nil, nil)
    StoryEngine.Bonds.change("ray", target, 1, "Ray drove a load of supplies over to them at the players' request", true)
    Life.record(target, "ray_supply", ps.name, 1)
    local name = StoryEngine.Stories.NAMES[target] or target
    Radio.react(target, "event", "Ray Mercer just drove a load of supplies over to your people because "
        .. tostring(ps.name) .. " asked him to. Thank them both, in character.",
        { text = "Ray dropped off supplies. Thank you.", lt = { key = "IGUI_StoryEngine_RadioSay_raysupply" } }, ps,
        { overhead = true })
    return true, { cost = Specialty.RAY_COST, costRes = "food", item = name, gained = gained,
                   topic = "You drove a load of supplies over to " .. name .. " because " .. tostring(ps.name)
                       .. " asked you to. Tell them it is done." }
end

-- ---------------------------------------------------------------- 파이크: 위로

-- 스트레스·불행·지루함을 비율만큼 줄인다 (서버에서)
Specialty.SOOTHE_STATS = { "STRESS", "UNHAPPINESS", "BOREDOM" }
function Specialty.soothe(p, reduce)
    local ok, err = pcall(function()
        local stats = p:getStats()
        for _, name in ipairs(Specialty.SOOTHE_STATS) do
            local stat = CharacterStat[name]
            stats:set(stat, stats:get(stat) * (1 - reduce))
        end
    end)
    if not ok then log("comfort stats error:", err) end
end

local function comfort(player, ps, fid, tier)
    local now = Sensor.now()
    local hours = Specialty.NO_FEAR_HOURS[tier]
    if projectDone("pike") then hours = hours * 1.5 end                           -- 교회 텃밭: 1.5배
    local targets = { player }
    for _, p in ipairs(Sensor.players()) do
        if p ~= player and not p:isDead() and p:getZ() == player:getZ()
            and dist(p:getX(), p:getY(), player:getX(), player:getY()) <= Specialty.COMFORT_RADIUS then
            targets[#targets + 1] = p
        end
    end
    for _, p in ipairs(targets) do
        -- 무들 수치는 서버가 정한다: 클라이언트에서만 바꾸면 멀티에서 서버 값으로 곧 돌아온다
        -- (2026-09-30 인게임: 매우 지루함이 사라졌다 바로 다시 생김). 바닐라 SFarmingSystem 도 서버에서 바꾼다
        Specialty.soothe(p, Specialty.COMFORT[tier])
        Net.toClient(p, "specComfort", { faction = fid, tier = tier, reduce = Specialty.COMFORT[tier], hours = hours })
        if hours > 0 then
            state().comfort[Store.playerKey(p)] = { untilT = now.t + hours * 60, stiff = tier >= 3 }
        end
    end
    return true, { count = #targets, topic = "You prayed with " .. tostring(ps.name) .. " over the radio and talked them "
        .. "through their fear" .. (#targets > 1 and ", with their companions listening" or "") .. "." }
end

-- 구간 3: 근육통을 계속 없앤다 (몸 상태는 서버에서 바꾸고 syncBodyPart, 바닐라 관리자 체력 패널과 같은 방식)
local function comfortTick(now)
    local s = state()
    for key, c in pairs(s.comfort) do
        if now.t >= c.untilT then
            s.comfort[key] = nil
        else
            local p = playerByKey(key)
            if p then
                -- 두려움 없음: 서버가 매분 공포를 0으로 (클라이언트도 매 틱)
                pcall(function() p:getStats():set(CharacterStat.PANIC, 0) end)
            end
            if p and c.stiff ~= false then   -- 근육통 없음은 구간 3 (예전 세이브의 기록은 stiff 가 없고 모두 구간 3)
                pcall(function()
                    local parts = p:getBodyDamage():getBodyParts()
                    for i = 0, parts:size() - 1 do
                        local bp = parts:get(i)
                        if bp:getStiffness() > 0 then
                            bp:setStiffness(0)
                            pcall(function() p:getFitness():removeStiffnessValue(BodyPartType.ToString(bp:getType())) end)
                            pcall(syncBodyPart, bp, 0xFFFFFFFFFFF)
                        end
                    end
                end)
            end
        end
    end
end

-- ---------------------------------------------------------------- 빅: 미끼 소음

local function decoy(player, ps, fid, tier)
    local px, py = player:getX(), player:getY()
    local players = Sensor.players()
    local best = nil
    local start = ZombRand(8)
    for i = 0, 7 do
        local angle = ((start + i) % 8) * math.pi / 4
        local d = rand(Specialty.DECOY_DIST)
        local x, y = px + math.cos(angle) * d, py + math.sin(angle) * d
        local clear = true
        for _, p in ipairs(players) do
            if dist(p:getX(), p:getY(), x, y) < Specialty.DECOY_CLEAR then clear = false end
        end
        if clear then
            best = { x = math.floor(x), y = math.floor(y), angle = angle }
            break
        end
    end
    if not best then return false, "no_spot" end
    local now = Sensor.now()
    local decoys = state().decoys
    decoys[#decoys + 1] = { x = best.x, y = best.y, radius = Specialty.DECOY_RADIUS[tier],
                            untilT = now.t + rand(Specialty.DECOY_MIN) }
    local code = dirCode(best.x - px, best.y - py)
    return true, { topic = "Your crew is making a racket (gunfire and firecrackers) about " .. StoryEngine.intToString(
        math.floor(dist(best.x, best.y, px, py) / 10) * 10) .. " tiles " .. code .. " of " .. tostring(ps.name)
        .. " to pull the dead away from them. Brag about it." }
end

local function decoyTick(now)
    local keep = {}
    for _, d in ipairs(state().decoys) do
        if now.t < d.untilT then
            pcall(addSound, nil, d.x, d.y, 0, d.radius, 100)
            keep[#keep + 1] = d
        end
    end
    state().decoys = keep
end

-- ---------------------------------------------------------------- 방위대: 분대 또는 저격

local function squad(player, ps, fid, tier)
    if ALife.enabled() and ALife.available() then
        local ok, why = ALife.sendSupport(player, fid, "specialty", nil, Specialty.SQUAD_LEVEL[tier], nil,
            Specialty.SQUAD_SIZE[tier])
        if not ok then return false, why end
        return true, { topic = "You sent a squad of your soldiers to back up " .. tostring(ps.name) .. ". Tell them to hold on." }
    end
    return snipe(player, ps, fid, tier)
end

Specialty.HANDLERS = {
    guard = squad, hunter = snipe, doc = heal, dewey = repair, casey = scout, ray = supply, pike = comfort, rats = decoy,
}

-- 요청. 반환: true, info / false, 오류 코드, 대기 시간
function Specialty.request(player, fid, args)
    if not Factions.byId[fid] then return false, "no_faction" end
    if not Factions.canTalk(player) then return false, "no_radio" end
    local ps = Store.player(player)
    local st = Specialty.status(fid, ps.key)
    if st.reason then return false, st.reason, st.wait end
    local handler = Specialty.HANDLERS[fid]
    if not handler then return false, "no_specialty" end
    local ok, info = handler(player, ps, fid, st.tier, args or {})
    if not ok then
        log("specialty refused", fid, tostring(info))
        return false, info
    end
    if not info.pending then Specialty.commit(fid, ps, st.tier, info) end
    return true, info
end

-- 복구 작전 중 NPC 가 스스로 돕는다 (Ops.lua, 2026-10-01). 대기 시간에 걸리지 않고 남기지도 않으며 자원도 쓰지 않는다.
-- 구간은 신뢰도대로, 낮아도 1 (물·전기는 모두에게 필요하다). 무전은 머리 위에도. 반환: true, info | false, 이유
function Specialty.assist(fid, player, args)
    if not Factions.byId[fid] or Factions.isGone(fid) or not Specialty.enabled() then return false, "unavailable" end
    if StoryEngine.Saga and StoryEngine.Saga.specialtyBlocked(fid) then return false, "ill" end
    local handler = Specialty.HANDLERS[fid]
    if not handler or not player or player:isDead() then return false, "no_specialty" end
    local ps = Store.player(player)
    local tier = math.max(1, Specialty.tier(Radio.channel(fid).trust))
    local ok, info = handler(player, ps, fid, tier, args or {})
    if not ok then
        log("ops assist refused", fid, tostring(info))
        return false, info
    end
    if not info.pending then
        local now = Sensor.now()
        Store.addNote(ps, { kind = info.note or ("specialty_" .. fid), faction = fid, clock = now.clock,
                            count = info.count, item = info.item })
        if info.topic then
            Radio.react(fid, "event", info.topic .. " You are doing this to help with the repair operation the whole "
                .. "county depends on. Keep it short and in character.",
                { text = info.fallbackText or "On it.", lt = { key = "IGUI_StoryEngine_RadioSay_spec_" .. fid } }, ps,
                { overhead = true })
        end
    end
    log("ops assist", fid, "tier", tier, "for", ps.name)
    return true, info
end

-- 작전 동안 케이시 정찰을 유지한다 (untilT 까지, 이미 있으면 늘리기만)
function Specialty.opScout(player, untilT)
    if Factions.isGone("casey") or not Specialty.enabled() then return false end
    local key = Store.playerKey(player)
    local s = state()
    local sc = s.scout[key]
    if sc then
        sc.untilT = math.max(sc.untilT, untilT)
    else
        s.scout[key] = { untilT = untilT, tier = math.max(1, Specialty.tier(Radio.channel("casey").trust)),
                         warned = {}, lastScanT = -1000 }
    end
    return true
end

Events.EveryOneMinute.Add(function()
    local now = Sensor.now()
    for _, fn in ipairs({ runJobs, Specialty.scoutTick, comfortTick, decoyTick }) do
        local ok, err = pcall(fn, now)
        if not ok then log("specialty tick error:", err) end
    end
end)

return Specialty
