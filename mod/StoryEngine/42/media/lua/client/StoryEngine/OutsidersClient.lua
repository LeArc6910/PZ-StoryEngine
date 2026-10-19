-- 밖에서 온 사람들, 클라이언트 쪽 (서버 Outsiders.lua): 누가 와 있는지, 의회 탭의 글과 메뉴, 특기 효과.
-- 효과 가운데 내 몸에 닿는 것(지연제·체질 관리·기적)은 여기서 매분 적용한다. 서버가 10분마다 다시 알려 준다.
-- 짐을 든 자의 운반 무게는 서버가 바꾼다 (Outsiders.updateCarry). 멀티에서 운반 한도는 서버 값이 오므로 여기서는 손대지 않는다.

if isServer() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Factions"
require "StoryEngine/UIUtil"
require "StoryEngine/Client"

local Net = StoryEngine.Net
local Factions = StoryEngine.Factions
local UI = StoryEngine.UI
local Client = StoryEngine.Client
local Cache = StoryEngine.Cache

local Out = {}
StoryEngine.OutsidersClient = Out

Out.ORDER = { "hale", "odell", "okafor", "abigail" }
Out.MIRACLE_HEALTH = 15
Out.WEIGHT_TARGET = 80
Out.WEIGHT_PER_DAY = 2
Out.fx = {}             -- [kind] = { untilH, ... }
Out.NOTICES = { hail = true, admitted = true, refused = true, kept = true, expel = true }
Out.ERRORS = { closed = true, away = true, trust = true, wait = true, armed = true, active = true, no_radio = true,
               no_job = true, anticheat = true, out_far = true, out_near = true, no_jewels = true, not_infected = true,
               nothing = true, gone = true, no_test = true, no_vote = true }

-- 충성 시험에서 밖에서 온 사람 편을 들 때 얻는 것: 줄어드는 대기는 샌드박스 OutsiderDays_<특기> 값으로
function Out.sideTip(id)
    local key = "IGUI_StoryEngine_Out_Side_Out_" .. tostring(id)
    local Tuning = StoryEngine.Tuning
    if not (Tuning and Tuning.outsiderDays) then return getText(key) end
    local d = function(kind, sided) return UI.daysText(Tuning.outsiderDays(kind, sided)) end
    if id == "hale" then return getText(key, d("proxy"), d("proxy", true), d("airdrop"), d("airdrop", true)) end
    if id == "abigail" then return getText(key, d("miracle"), d("miracle", true)) end
    return getText(key)
end
Out.minutes = 0

local function num(n) return StoryEngine.intToString(math.floor((n or 0) + 0.5)) end

local function worldHours() return getGameTime():getWorldAgeHours() end

local function hoursText(minutes)
    local h = math.ceil((minutes or 0) / 60)
    if h >= 48 then return getText("IGUI_StoryEngine_Out_Days", num(math.ceil(h / 24))) end
    return getText("IGUI_StoryEngine_Out_Hours", num(h))
end

local function line(parts, text, rgb)
    parts[#parts + 1] = " <RGB:" .. (rgb or "0.9,0.9,0.9") .. "> " .. UI.escape(text) .. " <LINE> "
end

local function names(list)
    local out = {}
    for _, fid in ipairs(list or {}) do out[#out + 1] = UI.npcName(fid) end
    return table.concat(out, ", ")
end

function Out.specName(kind) return getText("IGUI_StoryEngine_Out_Spec_" .. tostring(kind)) end

-- 특기 한 줄의 상태 글
function Out.specState(st)
    if st.ok then return getText("IGUI_StoryEngine_Out_Ready"), true end
    if st.why == "trust" then return getText("IGUI_StoryEngine_Out_NeedTrust", num(st.need)), false end
    if st.why == "wait" then return hoursText(st.wait), false end
    if st.why == "armed" then return getText("IGUI_StoryEngine_Out_Armed"), false end
    return getText("IGUI_StoryEngine_Out_Away"), false
end

-- 의회 탭에 덧붙이는 글. o = 서버 Outsiders.payload
function Out.textOf(o)
    local parts = {}
    if not o or (#(o.list or {}) == 0 and not o.pending) then return "" end
    parts[#parts + 1] = " <LINE> "
    line(parts, getText("IGUI_StoryEngine_Out_Title"), "1,0.86,0.55")
    if o.pending then line(parts, getText("IGUI_StoryEngine_Out_Pending", UI.npcName(o.pending)), "0.85,0.8,0.6") end
    for _, row in ipairs(o.list or {}) do
        local head = getText("IGUI_StoryEngine_Out_Row", UI.npcName(row.id), num(row.trust), num(row.days))
        if row.hard then head = head .. "  [" .. getText("IGUI_StoryEngine_Out_Hard") .. "]" end
        if row.sided == "out" then head = head .. "  [" .. getText("IGUI_StoryEngine_Out_SidedOut", UI.npcName(row.rival)) .. "]" end
        line(parts, head, row.low and "0.95,0.6,0.45" or "0.9,0.9,0.9")
        if row.low then line(parts, getText("IGUI_StoryEngine_Out_Leaving", num(row.low)), "0.95,0.5,0.4") end
        line(parts, getText("IGUI_StoryEngine_Out_Dislike", names(row.dislike)), "0.75,0.7,0.65")
        for n = 1, 2 do
            local st = (row.spec or {})[n]
            if st then
                local text, ok = Out.specState(st)
                line(parts, getText("IGUI_StoryEngine_Out_SpecLine", num(n), Out.specName(st.kind), text),
                    ok and "0.7,0.9,0.7" or "0.7,0.7,0.7")
            end
        end
        if row.test then
            line(parts, getText("IGUI_StoryEngine_Out_Test", UI.npcName(row.id), UI.npcName(row.test.rival),
                num(row.test.hours)), "1,0.6,0.4")
            line(parts, getText("IGUI_StoryEngine_Out_Test_" .. row.id), "0.9,0.8,0.7")
        end
        if row.expel then
            line(parts, getText("IGUI_StoryEngine_Out_Expel", UI.npcName(row.id),
                getText("IGUI_StoryEngine_Out_Stance_" .. tostring(row.expel.stance))), "1,0.6,0.4")
        end
    end
    return table.concat(parts)
end

-- 의회 탭 [밖에서 온 사람들] 버튼의 메뉴. 반환: { { id, label, items = { { label, tip, ok, what, args, sub } } } }
function Out.rows(o)
    local rows = {}
    for _, row in ipairs(o and o.list or {}) do
        local items = {}
        for n = 1, 2 do
            local st = (row.spec or {})[n]
            if st then
                local text, ok = Out.specState(st)
                local waitText = st.days and (" " .. getText(st.kind == "miracle" and "IGUI_StoryEngine_Out_WaitAfterFire"
                    or "IGUI_StoryEngine_Spec_WaitDays", UI.daysText(st.days))) or ""
                local item = { label = getText("IGUI_StoryEngine_Out_Use", Out.specName(st.kind), text), ok = ok,
                               tip = getText("IGUI_StoryEngine_Out_Spec_" .. tostring(st.kind) .. "_Tip") .. waitText .. " <LINE> "
                                   .. getText("IGUI_StoryEngine_Out_Cost", names(row.dislike)),
                               what = "use", args = { id = row.id, n = n } }
                if st.kind == "proxy" then
                    item.sub = {}
                    for _, j in ipairs(o.jobs or {}) do
                        item.sub[#item.sub + 1] = {
                            label = getText("IGUI_StoryEngine_Out_Job", getText("IGUI_StoryEngine_Out_Job_" .. tostring(j.kind)),
                                num(j.tier), j.faction and UI.npcName(j.faction) or "?"),
                            ok = ok, what = "use", args = { id = row.id, n = n, quest = j.id } }
                    end
                    if #item.sub == 0 then
                        item.sub, item.ok = nil, false
                        item.label = getText("IGUI_StoryEngine_Out_Use", Out.specName(st.kind), getText("IGUI_StoryEngine_Out_NoJob"))
                    end
                elseif st.kind == "airdrop" then
                    item.what = "aim"
                elseif st.kind == "order" then
                    item.what = "order"
                    item.ok = true          -- 창은 언제든 열어 볼 수 있다 (요청은 서버가 다시 본다)
                end
                items[#items + 1] = item
            end
        end
        local g = row.gift or {}
        items[#items + 1] = { label = getText("IGUI_StoryEngine_Out_Gift"), ok = (g.trust or 0) < 3, what = "gift",
                              tip = getText("IGUI_StoryEngine_Out_Gift_Tip"), args = { id = row.id, gift = g } }
        local v = row.volunteer
        if v then
            items[#items + 1] = { label = getText("IGUI_StoryEngine_Out_Volunteer"), ok = v.ok == true, what = "volunteer",
                                  tip = getText("IGUI_StoryEngine_Out_Volunteer_Tip",
                                      StoryEngine.intToString(math.max(0, math.floor(UI.tune("VolunteerPerWeek", 2))))),
                                  args = { faction = row.id } }
        end
        if row.test then
            items[#items + 1] = { label = getText("IGUI_StoryEngine_Out_Side", UI.npcName(row.id)), ok = true, what = "side",
                                  tip = Out.sideTip(row.id), args = { id = row.id, side = "out" } }
            items[#items + 1] = { label = getText("IGUI_StoryEngine_Out_Side", UI.npcName(row.test.rival)), ok = true, what = "side",
                                  tip = getText("IGUI_StoryEngine_Out_Side_Home"), args = { id = row.id, side = "home" } }
        end
        if row.expel then
            for _, s in ipairs({ "keep", "expel", "abstain" }) do
                items[#items + 1] = { label = getText("IGUI_StoryEngine_Out_Stance_Say", getText("IGUI_StoryEngine_Out_Stance_" .. s)),
                                      ok = row.expel.stance ~= s, what = "stance",
                                      tip = getText("IGUI_StoryEngine_Out_Stance_Tip_" .. s), args = { id = row.id, stance = s } }
            end
        end
        rows[#rows + 1] = { id = row.id, label = getText("IGUI_StoryEngine_Out_MenuRow", UI.npcName(row.id), num(row.trust)),
                            items = items }
    end
    return rows
end

-- 메뉴에서 고른 일을 한다
function Out.act(item)
    local p = getPlayer()
    if not p or not item then return end
    local what, args = item.what, item.args or {}
    if what == "use" then
        Net.toServer(p, "outsiderUse", args)
    elseif what == "aim" then
        if StoryEngine.Aim then StoryEngine.Aim.start("hale", "airdrop") end
    elseif what == "order" then
        Net.toServer(p, "tradeOptions", { faction = "odell" })
    elseif what == "gift" then
        if StoryEngineDonateWindow then StoryEngineDonateWindow.open({ id = args.id, gift = args.gift }, "gift") end
    elseif what == "volunteer" then
        Net.toServer(p, "volunteerAsk", args)
    elseif what == "side" then
        Net.toServer(p, "outsiderSide", args)
    elseif what == "stance" then
        Net.toServer(p, "outsiderStance", args)
    end
end

-- ---------------------------------------------------------------- 알림

function Out.noticeText(args)
    local kind = tostring(args.kind)
    local name = args.id and UI.npcName(args.id) or ""
    if kind == "raid" then return getText("IGUI_StoryEngine_Out_Notice_raid", UI.npcName(args.victim)), false end
    if kind == "test" or kind == "sided" or kind == "test_ignored" then
        if kind == "sided" then
            local chosen = args.side == "out" and name or UI.npcName(args.rival)
            return getText("IGUI_StoryEngine_Out_Notice_sided", chosen), true
        end
        return getText("IGUI_StoryEngine_Out_Notice_" .. kind, name, UI.npcName(args.rival)), false
    end
    if kind == "left" then
        return getText(args.why == "expelled" and "IGUI_StoryEngine_Out_Notice_expelled" or "IGUI_StoryEngine_Out_Notice_left", name), false
    end
    if not Out.NOTICES[kind] then return nil end
    return getText("IGUI_StoryEngine_Out_Notice_" .. kind, name), kind == "admitted" or kind == "kept" or kind == "hail"
end

function Client.handlers.outsiderNotice(args)
    local p = getPlayer()
    if not p then return end
    local text, good = Out.noticeText(args or {})
    if text then
        if good then HaloTextHelper.addGoodText(p, text) else HaloTextHelper.addBadText(p, text) end
    end
    Net.toServer(p, "politicsState", {})
end

function Out.resultText(args)
    if args.ok then
        if args.what == "use" then
            if args.kind == "jewels" and args.info then
                return getText("IGUI_StoryEngine_Out_Done_jewels", num(args.info.taken), num(args.info.scrip)), true
            end
            if args.kind == "retard" and args.info and args.info.cured then return getText("IGUI_StoryEngine_Out_Done_cured"), true end
            return getText("IGUI_StoryEngine_Out_Done_" .. tostring(args.kind)), true
        elseif args.what == "gift" then
            return getText("IGUI_StoryEngine_Out_Gift_Done", num(args.value), num(args.trust)), true
        end
        return nil
    end
    if not Out.ERRORS[tostring(args.error)] then return tostring(args.error), false end
    return getText("IGUI_StoryEngine_Out_Error_" .. tostring(args.error), num(math.ceil((args.wait or 0) / 60))), false
end

function Client.handlers.outsiderResult(args)
    local p = getPlayer()
    if not p then return end
    local text, good = Out.resultText(args or {})
    if text then
        if good then HaloTextHelper.addGoodText(p, text) else HaloTextHelper.addBadText(p, text) end
    end
end

-- 누가 와 있는지 (서버가 바뀔 때마다·접속 때 알린다)
function Client.handlers.outsiders(args)
    for _, id in ipairs(Out.ORDER) do Factions.present[id] = nil end
    for _, id in pairs(args.present or {}) do Factions.present[id] = true end
    if StoryEngineMainWindow and StoryEngineMainWindow.refreshIfOpen then
        StoryEngineMainWindow.refreshIfOpen("radio")
        StoryEngineMainWindow.refreshIfOpen("politics")
    end
end

-- ---------------------------------------------------------------- 효과

-- 0.4.8 까지 이 파일이 멀티 클라이언트에서 기본 무게를 두 배로 바꾸고 원래 값을 modData seBurdenBase 에 적어 두었다.
-- 그 값이 정확히 남아 있으면 이 클라이언트의 몸만 한 번 되돌리고 키를 지운다 (싱글은 서버 코드가 정리한다).
Out.legacyCleaned = false
function Out.cleanLegacyBurden(p)
    if Out.legacyCleaned or not p or not isClient() then return end
    Out.legacyCleaned = true
    pcall(function()
        local md = p:getModData()
        if md.seBurdenBase == nil then return end
        local old = tonumber(md.seBurdenBase)
        md.seBurdenBase = nil
        if old and old > 0 and p:getMaxWeightBase() == math.floor(old * 2) then p:setMaxWeightBase(old) end
    end)
end

local function cure(p)
    pcall(function()
        local bd = p:getBodyDamage()
        bd:setInfected(false)
        bd:setInfectionLevel(0)
        bd:setInfectionTime(-1)
        bd:setInfectionMortalityDuration(-1)
        local parts = bd:getBodyParts()
        for i = 0, parts:size() - 1 do parts:get(i):SetInfected(false) end
    end)
end

function Client.handlers.outsiderFx(args)
    local kind = tostring(args.kind)
    local minutes = tonumber(args.minutes) or 0
    local p = getPlayer()
    if args.cure and p then cure(p) end
    if minutes <= 0 then
        Out.fx[kind] = nil
        return
    end
    local f = Out.fx[kind] or {}
    f.untilH = worldHours() + minutes / 60
    f.radius = args.radius
    Out.fx[kind] = f
end

-- 지연제: 감염이 더 나아가지 못하게 붙잡아 둔다
local function holdInfection(p, f)
    pcall(function()
        local bd = p:getBodyDamage()
        local nowH = worldHours()
        if f.level == nil then f.level, f.lastH = bd:getInfectionLevel(), nowH end
        pcall(function() bd:setInfectionTime(bd:getInfectionTime() + (nowH - f.lastH)) end)
        if bd:getInfectionLevel() > f.level then bd:setInfectionLevel(f.level) end
        f.lastH = nowH
    end)
end

-- 체질 관리: 배고픔·갈증이 절반 속도로 오르고, 체중이 80 쪽으로 간다
local function regimen(p, f)
    pcall(function()
        local st = p:getStats()
        for _, name in ipairs({ "HUNGER", "THIRST" }) do
            local stat = CharacterStat[name]
            local cur, last = st:get(stat), f[name]
            if last and cur > last then
                cur = last + (cur - last) / 2
                st:set(stat, cur)
            end
            f[name] = cur
        end
    end)
    pcall(function()
        local nut = p:getNutrition()
        local w, step = nut:getWeight(), Out.WEIGHT_PER_DAY / 1440
        if w > Out.WEIGHT_TARGET + step then nut:setWeight(w - step) elseif w < Out.WEIGHT_TARGET - step then nut:setWeight(w + step) end
    end)
end

-- 기적: 둘레의 좀비가 쓰러지고, 두 시간 동안 피가 멎고 아픔이 없다
local function miracle(p, f)
    if not f.struck then
        f.struck = true
        local r = tonumber(f.radius) or 5
        pcall(function()
            local list = getCell():getZombieList()
            for i = 0, list:size() - 1 do
                local z = list:get(i)
                if z and not z:isDead() and not (StoryEngine.isALifeNpc and StoryEngine.isALifeNpc(z))
                    and math.abs(z:getX() - p:getX()) <= r and math.abs(z:getY() - p:getY()) <= r then
                    pcall(function() z:setStaggerBack(true) end)
                    pcall(function() z:knockDown(true) end)
                end
            end
        end)
    end
    pcall(function()
        local parts = p:getBodyDamage():getBodyParts()
        for i = 0, parts:size() - 1 do
            local bp = parts:get(i)
            if bp:getBleedingTime() > 0 then bp:setBleedingTime(0) end
        end
        p:getStats():set(CharacterStat.PAIN, 0)
    end)
end

function Out.tick()
    local p = getPlayer()
    if not p or p:isDead() then return end
    Out.minutes = Out.minutes + 1
    local now = worldHours()
    for kind, f in pairs(Out.fx) do
        if now >= f.untilH then
            Out.fx[kind] = nil
        elseif kind == "retard" then holdInfection(p, f)
        elseif kind == "regimen" then regimen(p, f)
        elseif kind == "miracle" then miracle(p, f)
        end
    end
    if Out.minutes == 3 then Out.cleanLegacyBurden(p) end
end

-- 기도를 받아 둔 사람: 체력이 바닥에 닿으면 서버에 알린다
local ticks = 0
function Out.watch(p)
    if not Out.fx.armed or p ~= getPlayer() then return end
    ticks = ticks + 1
    if ticks % 10 ~= 0 then return end
    local ok, hp = pcall(function() return p:getBodyDamage():getOverallBodyHealth() end)
    if ok and hp and hp > 0 and hp <= Out.MIRACLE_HEALTH and not p:isDead() then
        Out.fx.armed = nil
        Net.toServer(p, "outsiderMiracle", {})
    end
end

Events.EveryOneMinute.Add(function() pcall(Out.tick) end)
Events.OnPlayerUpdate.Add(function(p) pcall(Out.watch, p) end)

return Out
