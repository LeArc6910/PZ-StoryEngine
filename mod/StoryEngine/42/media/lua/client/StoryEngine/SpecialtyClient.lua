-- 특기 지원의 클라이언트 쪽 (Specialty.lua 가 보낸 명령).
--   specHealStart  닥 치료: 10초 동안 움직이거나 다치지 않으면 specHealDone 을 보낸다 (끊기면 아무것도 쓰지 않음)
--   specSnipe      행크·방위대 저격: 한 시간(게임) 동안 나눠 가까운 바깥 좀비를 쓰러뜨린다.
--                  총성은 이 플레이어만 듣는 UI 소리라 좀비를 끌지 않는다. 멀티에서는 좀비를 맡은 클라이언트가 이 플레이어일 때
--                  확실하다 (근처 좀비는 보통 가까운 플레이어가 맡는다, 인게임 확인 필요)
--   scoutMarks     케이시 정찰 지도 표시 (QuestMap)
--   specComfort    파이크 위로: 스트레스·불행·지루함 감소, 정해진 시간 동안 공포 0

if isServer() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Client"
require "StoryEngine/QuestMap"

local Net = StoryEngine.Net
local Client = StoryEngine.Client
local log = StoryEngine.log

local SpecClient = {
    heal = nil,
    snipes = {},
}
StoryEngine.SpecClient = SpecClient

SpecClient.HEAL_MS = 10000
SpecClient.HEAL_MOVE = 0.8          -- 이만큼 움직이면 끊긴다 (타일)
SpecClient.HEAL_HIT = 15            -- 10초 안에 체력이 이만큼 떨어지면 (크게 맞음) 끊긴다

local function worldHours() return getGameTime():getWorldAgeHours() end

-- ---------------------------------------------------------------- 치료

-- 상처가 있는 부위 수 (긁힘·베임·깊은 상처·물림·총알). 새로 맞으면 늘어난다
local function woundCount(p)
    local n = 0
    local ok = pcall(function()
        local parts = p:getBodyDamage():getBodyParts()
        for i = 0, parts:size() - 1 do
            local bp = parts:get(i)
            if bp:scratched() or bp:isCut() or bp:deepWounded() or bp:bitten() or bp:haveBullet() then n = n + 1 end
        end
    end)
    return ok and n or 0
end
SpecClient.woundCount = woundCount

function Client.handlers.specHealStart(args)
    local p = getPlayer()
    if not p then return end
    SpecClient.heal = { faction = args.faction, start = getTimestampMs(), x = p:getX(), y = p:getY(),
                        hp = p:getBodyDamage():getOverallBodyHealth(), wounds = woundCount(p) }
    HaloTextHelper.addText(p, getText("IGUI_StoryEngine_Spec_HealStart"))
end

-- 치료가 끊기는 이유 (없으면 nil). 출혈로 체력이 서서히 주는 것은 끊지 않는다 (2026-09-30 수정)
local function healBreak(p, h)
    if p:isDead() then return "dead" end
    local dx, dy = p:getX() - h.x, p:getY() - h.y
    if dx * dx + dy * dy > SpecClient.HEAL_MOVE * SpecClient.HEAL_MOVE then return "moved" end
    if woundCount(p) > h.wounds then return "new_wound" end
    if p:getBodyDamage():getOverallBodyHealth() < h.hp - SpecClient.HEAL_HIT then return "big_hit" end
    return nil
end

local function healTick(p)
    local h = SpecClient.heal
    if not h then return end
    local why = healBreak(p, h)
    if why then
        SpecClient.heal = nil
        StoryEngine.log("specialty heal cancelled:", why)
        HaloTextHelper.addBadText(p, getText("IGUI_StoryEngine_Spec_HealCancelled"))
        return
    end
    if getTimestampMs() - h.start >= SpecClient.HEAL_MS then
        SpecClient.heal = nil
        Net.toServer(p, "specHealDone", {})
    end
end

-- ---------------------------------------------------------------- 저격

function Client.handlers.specSnipe(args)
    local p = getPlayer()
    if not p then return end
    local now = worldHours()
    local count = math.max(1, math.floor(tonumber(args.count) or 1))
    local hours = (tonumber(args.minutes) or 60) / 60
    local interval = hours / count
    SpecClient.snipes[#SpecClient.snipes + 1] = {
        faction = args.faction, left = count, kills = 0, interval = interval,
        nextH = now + math.min(interval, 2 / 60), endH = now + hours + 5 / 60,
        radius = tonumber(args.radius) or 30, sound = args.sound,
    }
    HaloTextHelper.addGoodText(p, getText("IGUI_StoryEngine_Spec_SnipeStart", StoryEngine.Factions.name(args.faction)))
end

local function nearestTarget(p, radius)
    local list = getCell() and getCell():getZombieList()
    if not list then return nil end
    local best, bestD = nil, radius * radius
    local px, py = p:getX(), p:getY()
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        -- A-Life NPC(아군 지원 대원·일반 생존자·적 습격대 모두)는 쏘지 않는다
        if z and not z:isDead() and z:isOutside() and not StoryEngine.isALifeNpc(z) then
            local dx, dy = z:getX() - px, z:getY() - py
            local d = dx * dx + dy * dy
            if d <= bestD then best, bestD = z, d end
        end
    end
    return best
end

-- 쓰러뜨린다. 처치자는 비워 둬 플레이어 처치 수에 들어가지 않게 한다 (안 되면 체력 0)
local function drop(z)
    pcall(function() z:Kill(nil) end)
    if not z:isDead() then pcall(function() z:setHealth(0) end) end
    return z:isDead() or z:getHealth() <= 0
end

local function snipeTick(p)
    local now = worldHours()
    local keep = {}
    for _, s in ipairs(SpecClient.snipes) do
        if now >= s.nextH and s.left > 0 then
            local z = nearestTarget(p, s.radius)
            if z and drop(z) then
                s.kills, s.left = s.kills + 1, s.left - 1
                if s.sound then pcall(function() getSoundManager():playUISound(s.sound) end) end
                s.nextH = now + s.interval
            else
                s.nextH = now + s.interval / 2
            end
        end
        if s.left <= 0 or now >= s.endH or p:isDead() then
            Net.toServer(p, "specSnipeDone", { faction = s.faction, kills = s.kills })
            HaloTextHelper.addText(p, getText("IGUI_StoryEngine_Spec_SnipeDone", StoryEngine.Factions.name(s.faction),
                StoryEngine.intToString(s.kills)))
        else
            keep[#keep + 1] = s
        end
    end
    SpecClient.snipes = keep
end

-- ---------------------------------------------------------------- 정찰

function Client.handlers.scoutMarks(args)
    local marks = args.marks or {}
    local first = #(StoryEngine.QuestMap.scout or {}) == 0 and #marks > 0
    StoryEngine.QuestMap.setScout(marks)
    local p = getPlayer()
    if p and first then
        HaloTextHelper.addGoodText(p, getText("IGUI_StoryEngine_Spec_ScoutMarked", StoryEngine.intToString(#marks)))
    end
end

-- ---------------------------------------------------------------- 위로

-- 스트레스·불행·지루함은 서버가 줄인다 (Specialty.soothe, 멀티에서 클라이언트 값은 서버 값으로 덮인다)
function Client.handlers.specComfort(args)
    local p = getPlayer()
    if not p then return end
    local hours = tonumber(args.hours) or 0
    if hours > 0 then p:getModData().seNoFearUntil = worldHours() + hours end
    HaloTextHelper.addGoodText(p, getText("IGUI_StoryEngine_Spec_Comforted"))
end

local function comfortTick(p)
    local untilH = p:getModData().seNoFearUntil
    if not untilH then return end
    if worldHours() >= untilH then
        p:getModData().seNoFearUntil = nil
        return
    end
    pcall(function() p:getStats():set(CharacterStat.PANIC, 0) end)
end

-- ---------------------------------------------------------------- 결과 알림

function Client.handlers.specialtyResult(args)
    local p = getPlayer()
    if not p then return end
    local name = StoryEngine.Factions.name(args.faction)
    if args.ok then
        if args.healed then
            HaloTextHelper.addGoodText(p, getText("IGUI_StoryEngine_Spec_Healed", StoryEngine.intToString(args.healed)))
        elseif not args.pending then
            HaloTextHelper.addGoodText(p, getText("IGUI_StoryEngine_Spec_Sent", name))
        end
        return
    end
    local key = "IGUI_StoryEngine_Spec_Error_" .. tostring(args.error)
    local text = getTextOrNull(key) and getText(key, StoryEngine.intToString(args.wait or 0))
        or getText("IGUI_StoryEngine_Error", tostring(args.error))
    HaloTextHelper.addBadText(p, text)
end

-- ---------------------------------------------------------------- 2차 특기 (Specialty2.lua)

-- 결과 알림
function Client.handlers.spec2Result(args)
    local p = getPlayer()
    if not p then return end
    if args.ok then
        if args.chosen then
            HaloTextHelper.addGoodText(p, getText("IGUI_StoryEngine_Spec2_Chosen",
                getText("IGUI_StoryEngine_Spec2_Name_" .. tostring(args.chosen))))
        elseif args.used then
            HaloTextHelper.addGoodText(p, getText("IGUI_StoryEngine_Spec_Sent", StoryEngine.Factions.name(args.faction)))
        end
        return
    end
    local key = "IGUI_StoryEngine_Spec2_Error_" .. tostring(args.error)
    local text = getTextOrNull(key) and getText(key, StoryEngine.intToString(args.wait or 0))
    if not text then
        local key1 = "IGUI_StoryEngine_Spec_Error_" .. tostring(args.error)
        text = getTextOrNull(key1) and getText(key1, StoryEngine.intToString(args.wait or 0))
            or getText("IGUI_StoryEngine_Error", tostring(args.error))
    end
    HaloTextHelper.addBadText(p, text)
end

-- SOS·진통: 서버가 매분 정하지만, 그 사이에도 이 클라이언트가 공포·통증을 0으로 둔다 (위로의 공포 0 과 같은 방식)
SpecClient.fx = {}
function Client.handlers.spec2Fx(args)
    local untilH = worldHours() + (tonumber(args.minutes) or 60) / 60
    SpecClient.fx[#SpecClient.fx + 1] = { kind = args.kind, untilH = untilH, calm = args.calm, numb = args.numb }
end

local function spec2Tick(p)
    if #SpecClient.fx == 0 then return end
    local now = worldHours()
    local keep = {}
    for _, f in ipairs(SpecClient.fx) do
        if now < f.untilH then
            keep[#keep + 1] = f
            local stats = p:getStats()
            if f.calm then pcall(function() stats:set(CharacterStat.PANIC, 0) end) end
            if f.numb then pcall(function() stats:set(CharacterStat.PAIN, 0) end) end
        end
    end
    SpecClient.fx = keep
end

-- ---------------------------------------------------------------- 틱

SpecClient.tickN = 0
Events.OnTick.Add(function()
    SpecClient.tickN = SpecClient.tickN + 1
    if SpecClient.tickN % 10 ~= 0 then return end
    local p = getPlayer()
    if not p then return end
    local ok, err = pcall(healTick, p)
    if not ok then log("heal tick error:", err) end
    if #SpecClient.snipes > 0 then
        ok, err = pcall(snipeTick, p)
        if not ok then log("snipe tick error:", err) end
    end
    ok, err = pcall(comfortTick, p)
    if not ok then log("comfort tick error:", err) end
    ok, err = pcall(spec2Tick, p)
    if not ok then log("spec2 tick error:", err) end
end)

return SpecClient
