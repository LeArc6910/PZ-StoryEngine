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
-- 2단계 (2026-10-09): camo(좀비 표적 지우기)·flare(빛)·suppressor(내 총 소음)·reinforce(밀고 나가기, 운전자)
SpecClient.fx = {}
SpecClient.SUPPRESS = 0.3
SpecClient.PLOW_MASS = 2.5
SpecClient.PLOW_BUMP = 0.4          -- 한 틱에 속도가 이만큼(비율) 넘게 떨어지면 부딪힌 것: 되돌리지 않는다
SpecClient.CAMO_RADIUS = 25

local function sameFx(a, b)
    return a.kind == b.kind and (a.target or -1) == (b.target or -1)
end

function Client.handlers.spec2Fx(args)
    local entry = { kind = args.kind, untilH = worldHours() + (tonumber(args.minutes) or 60) / 60, calm = args.calm,
                    numb = args.numb, target = args.target, vid = args.vid, radius = args.radius }
    local keep = {}
    for _, f in ipairs(SpecClient.fx) do
        if sameFx(f, entry) then
            entry.light, entry.lx, entry.ly, entry.mass = f.light, f.lx, f.ly, f.mass   -- 이어 쓰기
        else
            keep[#keep + 1] = f
        end
    end
    if (tonumber(args.minutes) or 0) > 0 then
        keep[#keep + 1] = entry
    elseif entry.light then
        pcall(function() getCell():removeLamppost(entry.light) end)
    end
    SpecClient.fx = keep
end

-- 효과 대상 (멀티: online ID, 싱글: 나)
local function targetOf(f)
    if f.target == nil then return getPlayer() end
    return getPlayerByOnlineID and getPlayerByOnlineID(f.target) or nil
end

local function isMe(f)
    local p = getPlayer()
    local t = targetOf(f)
    return p ~= nil and t == p
end

-- 위장: 대상에게 달려드는 좀비의 표적을 지운다 (좀비는 맡은 클라이언트가 움직이므로 모든 클라이언트가 한다)
local function camoTick(f)
    local t = targetOf(f)
    if not t then return end
    if isMe(f) and t:isSprinting() then
        f.untilH = 0
        Net.toServer(t, "spec2CamoEnd", {})
        return
    end
    local list = getCell() and getCell():getZombieList()
    if not list then return end
    local tx, ty = t:getX(), t:getY()
    local r2 = SpecClient.CAMO_RADIUS * SpecClient.CAMO_RADIUS
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        if z and not z:isDead() and z:getTarget() == t then
            local dx, dy = z:getX() - tx, z:getY() - ty
            if dx * dx + dy * dy <= r2 then z:setTarget(nil) end
        end
    end
end

-- 조명: 대상이 한 타일 넘게 움직이면 빛을 옮긴다
local function flareTick(f, ending)
    local cell = getCell()
    if ending then
        if f.light then pcall(function() cell:removeLamppost(f.light) end) end
        f.light = nil
        return
    end
    local t = targetOf(f)
    if not t then return end
    local x, y, z = math.floor(t:getX()), math.floor(t:getY()), math.floor(t:getZ())
    if f.light and f.lx == x and f.ly == y then return end
    if f.light then pcall(function() cell:removeLamppost(f.light) end) end
    f.light = cell:addLamppost(x, y, z, 1.0, 0.85, 0.6, f.radius or 12)
    f.lx, f.ly = x, y
end

-- 소음기: 내 인벤토리의 총 소음을 줄이고, 원래 값은 총에 적어 둔다 (끝나면 되돌린다)
local function eachGun(p, fn)
    local items = p:getInventory():getItems()
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it and instanceof(it, "HandWeapon") and it:isRanged() then fn(it) end
    end
end

function SpecClient.suppress(p, on)
    eachGun(p, function(gun)
        local md = gun:getModData()
        if on and not md.seSupOrig then
            md.seSupOrig = { r = gun:getSoundRadius(), v = gun:getSoundVolume() }
            gun:setSoundRadius(math.max(1, math.floor(gun:getSoundRadius() * SpecClient.SUPPRESS)))
            gun:setSoundVolume(math.max(1, math.floor(gun:getSoundVolume() * SpecClient.SUPPRESS)))
        elseif not on and md.seSupOrig then
            gun:setSoundRadius(md.seSupOrig.r)
            gun:setSoundVolume(md.seSupOrig.v)
            md.seSupOrig = nil
        end
    end)
end

-- 밀고 나가기 (운전하는 사람만): 가속 중 서서히 떨어진 속도를 되돌린다, 크게 부딪히면 그대로
function SpecClient.plowTick(p, f)
    local v = p:getVehicle()
    if not v or v:getId() ~= f.vid or v:getDriver() ~= p then
        f.lastSpeed = nil
        return
    end
    if not f.mass then
        f.mass = v:getMass()
        v:setMass(v:getInitialMass() * SpecClient.PLOW_MASS)
    end
    local speed = v:getCurrentSpeedKmHour()
    local last = f.lastSpeed
    if last and v:isGasPedalPressed() and not v:isBrakePedalPressed() and math.abs(speed) < math.abs(last) then
        local drop = (math.abs(last) - math.abs(speed)) / math.max(1, math.abs(last))
        if drop < SpecClient.PLOW_BUMP then
            v:setSpeedKmHour(last)
            speed = last
        end
    end
    f.lastSpeed = speed
end

local function plowEnd(p, f)
    if not f.mass then return end
    local v = getVehicleById and getVehicleById(f.vid)
    if v then pcall(function() v:setMass(f.mass) end) end
    f.mass = nil
end

-- 포격: 이 클라이언트가 보는 좀비 중 반경 안의 것을 쓰러뜨린다 (A-Life NPC 제외)
function Client.handlers.spec2Strike(args)
    local list = getCell() and getCell():getZombieList()
    if not list then return end
    local x, y, r = tonumber(args.x) or 0, tonumber(args.y) or 0, tonumber(args.radius) or 10
    local kills = 0
    for i = list:size() - 1, 0, -1 do
        local z = list:get(i)
        if z and not z:isDead() and not StoryEngine.isALifeNpc(z) then
            local dx, dy = z:getX() - x, z:getY() - y
            if dx * dx + dy * dy <= r * r then
                local ok = pcall(function() z:Kill(nil) end)
                if not ok then pcall(function() z:setHealth(0) end) end
                kills = kills + 1
            end
        end
    end
    log("spec2 strike", x, y, kills)
end

-- 헬기 후송: 서버가 정한 집으로 옮긴다 (차에 타 있으면 teleportTo 가 내리게 한다)
function Client.handlers.spec2Teleport(args)
    local p = getPlayer()
    if not p then return end
    p:teleportTo(math.floor(tonumber(args.x) or p:getX()), math.floor(tonumber(args.y) or p:getY()),
        math.floor(tonumber(args.z) or 0))
    HaloTextHelper.addGoodText(p, getText("IGUI_StoryEngine_Spec2_EvacDone"))
end

-- 위장 중 공격하면 풀린다
Events.OnPlayerAttackFinished.Add(function(character)
    local p = getPlayer()
    if not p or character ~= p then return end
    for _, f in ipairs(SpecClient.fx) do
        if f.kind == "camo" and isMe(f) and f.untilH > worldHours() then
            f.untilH = 0
            Net.toServer(p, "spec2CamoEnd", {})
        end
    end
end)

SpecClient.supChecked = false
local function spec2Tick(p)
    local now = worldHours()
    local keep = {}
    local suppressed = false
    for _, f in ipairs(SpecClient.fx) do
        if now < f.untilH then
            keep[#keep + 1] = f
            local stats = p:getStats()
            if f.calm then pcall(function() stats:set(CharacterStat.PANIC, 0) end) end
            if f.numb then pcall(function() stats:set(CharacterStat.PAIN, 0) end) end
            if f.kind == "camo" then pcall(camoTick, f)
            elseif f.kind == "flare" then pcall(flareTick, f)
            elseif f.kind == "suppressor" and isMe(f) then suppressed = true
            end
        else
            if f.kind == "flare" then pcall(flareTick, f, true) end
            if f.kind == "reinforce" then pcall(plowEnd, p, f) end
        end
    end
    SpecClient.fx = keep
    -- 소음기: 켜져 있으면 새로 주운 총도(가끔), 꺼졌으면 남은 표시를 되돌린다 (처음 한 번은 지난 접속의 것도)
    SpecClient.supN = (SpecClient.supN or 0) + 1
    local due = SpecClient.supN % 10 == 0
    if (suppressed and due) or not SpecClient.supChecked or (SpecClient.supWas and not suppressed) then
        pcall(SpecClient.suppress, p, suppressed)
        SpecClient.supChecked = true
    end
    SpecClient.supWas = suppressed
end

-- 밀고 나가기는 매 틱 (속도는 순간마다 바뀐다)
Events.OnTick.Add(function()
    local p = getPlayer()
    if not p then return end
    for _, f in ipairs(SpecClient.fx) do
        if f.kind == "reinforce" and f.untilH > worldHours() then
            local ok, err = pcall(SpecClient.plowTick, p, f)
            if not ok then log("plow tick error:", err) end
        end
    end
end)

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


-- ---------------------------------------------------------------- 2차 특기: 지도 우클릭 (포격·대리 털이)

-- 지금 쓸 수 있는 지도 2차 특기 (거점 목록 기준): { { fid, opt } }
function SpecClient.mapOptions()
    local out = {}
    for _, n in ipairs((StoryEngine.Cache or {}).life or {}) do
        local s2 = n.spec2
        if s2 and s2.unlocked and s2.reason == nil and (s2.choice == "artillery" or s2.choice == "heist") then
            out[#out + 1] = { fid = n.id, opt = s2.choice }
        end
    end
    return out
end

function SpecClient.addMapOptions(context, wx, wy)
    for _, e in ipairs(SpecClient.mapOptions()) do
        context:addOption(getText("IGUI_StoryEngine_Spec2_Map_" .. e.opt), e, function(entry)
            local p = getPlayer()
            if p then Net.toServer(p, "spec2Use", { faction = entry.fid, x = math.floor(wx), y = math.floor(wy) }) end
        end)
    end
end

local function hookWorldMap()
    if not ISWorldMap or ISWorldMap.seSpec2Hooked then return end
    ISWorldMap.seSpec2Hooked = true
    local orig = ISWorldMap.onRightMouseUp
    function ISWorldMap:onRightMouseUp(x, y)
        local entries = SpecClient.mapOptions()
        if #entries == 0 then return orig(self, x, y) end
        if self.symbolsUI and self.symbolsUI:onRightMouseUpMap(x, y) then return true end
        local wx = self.mapAPI:uiToWorldX(x, y)
        local wy = self.mapAPI:uiToWorldY(x, y)
        -- 관리자·디버그 메뉴가 열리면 거기에 더하고, 아니면 우리 메뉴를 연다
        local captured = nil
        local realGet = ISContextMenu.get
        ISContextMenu.get = function(...)
            local c = realGet(...)
            captured = c
            return c
        end
        local ok, res = pcall(orig, self, x, y)
        ISContextMenu.get = realGet
        local context = captured or ISContextMenu.get(0, x + self:getAbsoluteX(), y + self:getAbsoluteY())
        SpecClient.addMapOptions(context, wx, wy)
        if ok and res ~= nil then return res end
        return true
    end
end

Events.OnGameStart.Add(function() pcall(hookWorldMap) end)

return SpecClient
