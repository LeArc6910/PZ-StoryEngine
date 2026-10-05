-- NPC 형편이 사건으로 드러나게 한다 (서버 측 전용, 2026-09-30). 설계: docs/IDEAS_NEXT.md 3번
--
--   급한 부탁   핵심 자원이 15 미만인 NPC 가 NPC 별 관문을 무시하고 그 자원 물건을 청한다 (디렉터 이벤트 npc_emergency,
--               수락하면 기한 24시간, 서버 전체 하루 간격)
--   습격 앞당김 파이크 안전 20 미만 + 빅 생존 + 교회 습격 위기(raid)를 아직 안 썼으면, 마지막 위기에서 2일이 지났을 때 바로 발동
--   나눔        어떤 자원이 80 이상인 NPC 가, 적대하지 않는 NPC 중 그 자원이 20 미만인 사람에게 15를 나눈다 (서버 전체 2일 간격)
--   충돌        방위대 안전 70 이상 + 빅 생존: 하루 30% 로 충돌, 둘 다 안전 -15 (5일 간격). 40% 로 "충돌" 위기(clash)
--   디렉터 판단 디렉터 AI 요청에 NPC 형편 요약 (Director.run -> payload.npcs)
-- 상태: d.npcEvents = { lastShareT, lastClashT }

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Radio"
require "StoryEngine/Stories"
require "StoryEngine/Life"

local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Stories = StoryEngine.Stories
local Life = StoryEngine.Life
local log = StoryEngine.log

local NpcEvents = {}
StoryEngine.NpcEvents = NpcEvents

NpcEvents.EMERGENCY_BELOW = 15
NpcEvents.EMERGENCY_GAP_MIN = 24 * 60
NpcEvents.EMERGENCY_DEADLINE_MIN = 24 * 60
NpcEvents.RAID_SAFETY_BELOW = 20
NpcEvents.RAID_AFTER_CRISIS_MIN = 2 * 24 * 60
NpcEvents.SHARE_FROM = 80
NpcEvents.SHARE_TO = 20
NpcEvents.SHARE_AMOUNT = 15
NpcEvents.SHARE_GAP_MIN = 2 * 24 * 60
NpcEvents.CLASH_SAFETY = 70
NpcEvents.CLASH_CHANCE = 30
NpcEvents.CLASH_HIT = 15
NpcEvents.CLASH_GAP_MIN = 5 * 24 * 60
NpcEvents.CLASH_CRISIS_CHANCE = 40

local RES_WORDS = { food = "food", medical = "medicine", safety = "ammunition", morale = "comforts" }

local function state()
    local d = Store.data()
    d.npcEvents = d.npcEvents or {}
    return d.npcEvents
end

local function alive(fid) return Factions.byId[fid] ~= nil and not Factions.isGone(fid) end
local function nameOf(fid) return Stories.NAMES[fid] or fid end

-- 이 NPC 에게 답을 기다리거나 진행 중인 부탁이 있는가
local function openRequest(fid)
    for _, q in pairs(Store.data().quests) do
        if q.origin and q.origin.faction == fid and (q.kind == "deliver" or q.kind == "horde")
            and (q.state == "proposed" or q.state == "accepted") then
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------- 급한 부탁

-- 핵심 자원이 가장 바닥인 NPC (15 미만, 살아 있고, 진행 중인 부탁이 없는). 반환: fid, 자원
function NpcEvents.emergency()
    local best, bestV, bestRes = nil, 101, nil
    for _, f in ipairs(Factions.list) do
        local res = Life.KEY[f.id]
        local v = res and Life.get(f.id, res)
        if res and alive(f.id) and v < NpcEvents.EMERGENCY_BELOW and v < bestV and not openRequest(f.id) then
            best, bestV, bestRes = f.id, v, res
        end
    end
    return best, bestRes
end

function NpcEvents.emergencyGapOk(now)
    local last = state().lastEmergencyT
    return not last or now.t - last >= NpcEvents.EMERGENCY_GAP_MIN
end

function NpcEvents.markEmergency(now) state().lastEmergencyT = now.t end

-- ---------------------------------------------------------------- 습격 앞당김

local function openChoice()
    for _, q in pairs(Store.data().quests) do
        if q.kind == "choice" and q.state == "proposed" then return true end
    end
    return false
end

-- 교회 습격 위기를 지금 바로 일으킬까 (Social.hourly)
function NpcEvents.raidDue(now, social)
    if not alive("pike") or not alive("rats") then return false end
    if Life.get("pike", "safety") >= NpcEvents.RAID_SAFETY_BELOW then return false end
    if (social.crisesUsed or {}).raid or openChoice() then return false end
    return not social.lastCrisisT or now.t - social.lastCrisisT >= NpcEvents.RAID_AFTER_CRISIS_MIN
end

-- ---------------------------------------------------------------- 나눔·충돌 (하루 한 번, Life.daily)

function NpcEvents.share(now)
    local s = state()
    if s.lastShareT and now.t - s.lastShareT < NpcEvents.SHARE_GAP_MIN then return false end
    for _, r in ipairs(Life.RESOURCES) do
        for _, giver in ipairs(Factions.list) do
            if alive(giver.id) and Life.get(giver.id, r) >= NpcEvents.SHARE_FROM then
                local taker, low = nil, NpcEvents.SHARE_TO
                for _, f in ipairs(Factions.list) do
                    local bond = StoryEngine.Bonds.get(giver.id, f.id)
                    if f.id ~= giver.id and alive(f.id) and bond >= 0 and Life.get(f.id, r) < low then
                        taker, low = f.id, Life.get(f.id, r)
                    end
                end
                if taker then
                    Life.change(giver.id, r, -NpcEvents.SHARE_AMOUNT, "share")
                    Life.change(taker, r, NpcEvents.SHARE_AMOUNT, "share")
                    StoryEngine.Bonds.change(taker, giver.id, 1, nameOf(giver.id) .. " sent your people "
                        .. RES_WORDS[r] .. " when you had run out", false)
                    s.lastShareT = now.t
                    local text = nameOf(giver.id) .. " sent some " .. RES_WORDS[r] .. " over to " .. nameOf(taker)
                        .. ", who had run out."
                    local Social = StoryEngine.Social
                    if Social then
                        Social.news(taker, nameOf(giver.id) .. " sent your people some " .. RES_WORDS[r]
                            .. " when you had run out. You are grateful.")
                        Social.news(giver.id, "You sent some of your spare " .. RES_WORDS[r] .. " to " .. nameOf(taker) .. ".")
                        Social.queueTopic({ giver.id, taker }, text .. " They talk about it.", "share")
                    end
                    log("npc share", giver.id, "->", taker, r)
                    return true
                end
            end
        end
    end
    return false
end

function NpcEvents.clash(now)
    local s = state()
    if not alive("guard") or not alive("rats") then return false end
    if Life.get("guard", "safety") < NpcEvents.CLASH_SAFETY then return false end
    if StoryEngine.Bonds.get("guard", "rats") >= 0 then return false end
    if s.lastClashT and now.t - s.lastClashT < NpcEvents.CLASH_GAP_MIN then return false end
    if ZombRand(100) >= NpcEvents.CLASH_CHANCE then return false end
    s.lastClashT = now.t
    Life.change("guard", "safety", -NpcEvents.CLASH_HIT, "clash")
    Life.change("rats", "safety", -NpcEvents.CLASH_HIT, "clash")
    StoryEngine.Bonds.change("guard", "rats", -1, "the squad and Vic's crew traded fire near Coalfield", true)
    local Social = StoryEngine.Social
    if Social then
        Social.news("all", "Sergeant Whitaker's squad and Vic's crew traded fire near Coalfield. Both sides took losses.")
        Social.queueTopic({ "guard", "rats" }, "Whitaker's squad and Vic's crew just had a firefight near Coalfield. "
            .. "They blame each other on the open channel.", "clash")
    end
    log("npc clash guard rats")
    -- 가끔은 플레이어가 편을 들게 한다
    if Social and ZombRand(100) < NpcEvents.CLASH_CRISIS_CHANCE and not (Social.crisesUsedTable() or {}).clash then
        local ok, why = Social.startCrisis(now, "clash")
        if not ok then log("clash crisis skipped", tostring(why)) end
    end
    return true
end

function NpcEvents.daily()
    local now = Sensor.now()
    for _, fn in ipairs({ NpcEvents.share, NpcEvents.clash }) do
        local ok, err = pcall(fn, now)
        if not ok then log("npc event error:", err) end
    end
end

-- ---------------------------------------------------------------- 디렉터 판단

-- 디렉터 AI 에게 넘기는 NPC 형편 (살아 있는 NPC 만)
function NpcEvents.directorSummary()
    local out = {}
    for _, f in ipairs(Factions.list) do
        if alive(f.id) then
            local n = Life.npc(f.id)
            out[#out + 1] = { id = f.id, state = { food = n.res.food, medical = n.res.medical, safety = n.res.safety,
                                                   morale = n.res.morale }, key = Life.KEY[f.id],
                              trust = StoryEngine.Radio.channel(f.id).trust }
        end
    end
    return out
end

return NpcEvents
