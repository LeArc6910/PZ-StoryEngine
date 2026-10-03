-- 유품 회수 (2026-10-04): 캐릭터가 죽고 같은 계정의 새 캐릭터가 나타나면, 앞 캐릭터를 가장 잘 알던 NPC 가
-- "그 친구가 쓰러진 곳에 짐이 남아 있을 거야"라며 죽은 자리를 알려 준다. 그 자리에는 앞 캐릭터의 마지막 일기가 적힌
-- 수첩(StoryEngine.Letter, 편지 창으로 읽음, Letters.createMemorial)이 놓인다. 실제 시체·짐은 게임에 원래 남아 있다.
--
-- 퀘스트는 supply_drop (origin.source = "recover", Quests.isManaged: 신뢰도·보상 없음), 수첩을 챙기면 완료 -> NPC 반응,
-- 새 캐릭터 일지 메모 recover_found. 죽은 지 Recover.MAX_DAYS 일이 지났거나 위치를 모르면 하지 않는다. 한 죽음에 한 번.

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Radio"
require "StoryEngine/Quests"
require "StoryEngine/Lines"

local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Radio = StoryEngine.Radio
local Quests = StoryEngine.Quests
local log = StoryEngine.log

local Recover = {}
StoryEngine.Recover = Recover

Recover.MAX_DAYS = 30
Recover.DELAY_MIN = 60              -- 새 캐릭터가 나타나고 이만큼 뒤에 연락
Recover.DEADLINE_DAYS = 7

function Recover.enabled() return StoryEngine.option("Recover", true) == true end

local function account(key) return string.match(tostring(key or ""), "^(.*)|") or "" end

-- 이 캐릭터의 앞 캐릭터 죽음 (같은 계정, 다른 이름, 아직 안 찾음, 최근)
function Recover.findDeath(ps, now)
    local mine = account(ps.key)
    local deaths = Store.data().deaths or {}
    for i = #deaths, 1, -1 do
        local e = deaths[i]
        if account(e.key) == mine and e.name ~= ps.name and not e.recovered and e.x and e.y
            and (not e.t or now.t - e.t <= Recover.MAX_DAYS * 24 * 60) then
            return e
        end
    end
    return nil
end

-- 죽은 사람을 가장 잘 알던 살아 있는 NPC (없으면 케이시, 그도 없으면 아무나)
function Recover.whoKnew(name)
    local best, bestScore = nil, 0
    for _, f in ipairs(Factions.list) do
        if not Factions.isGone(f.id) and StoryEngine.Legacy then
            local ok, score = pcall(StoryEngine.Legacy.shared, f.id, name)
            if ok and score and score > bestScore then best, bestScore = f.id, score end
        end
    end
    if best then return best, bestScore end
    if not Factions.isGone("casey") then return "casey", 0 end
    for _, f in ipairs(Factions.list) do
        if not Factions.isGone(f.id) then return f.id, 0 end
    end
    return nil, 0
end

-- 게임 내 10분마다: 새로 나타난 캐릭터를 보고, 시간이 되면 유품 퀘스트를 건다
function Recover.tick(entries, now)
    if not Recover.enabled() then return end
    for _, e in ipairs(entries or {}) do
        local ps = e.ps
        if not ps.recoverChecked then
            ps.recoverChecked = true
            local death = Recover.findDeath(ps, now)
            if death then
                ps.recoverAt = now.t + Recover.DELAY_MIN
                ps.recoverName = death.name
                log("recover scheduled", ps.name, "for", death.name)
            end
        elseif ps.recoverAt and now.t >= ps.recoverAt then
            ps.recoverAt = nil
            local ok, err = pcall(Recover.start, e.player, ps, now)
            if not ok then log("recover error:", err) end
        end
    end
end

function Recover.start(player, ps, now)
    local death = Recover.findDeath(ps, now)
    if not death then return nil end
    local fid, score = Recover.whoKnew(death.name)
    if not fid then return nil end
    local q = Quests.createSite("supply_drop", ps, { x = death.x, y = death.y }, now,
        { source = "recover", faction = fid, dead = death.name, deadKey = death.key },
        { items = {}, search = 3, deadlineT = now.t + Recover.DEADLINE_DAYS * 24 * 60, tier = 1 })
    if not q then return nil end
    q.state = "offered"
    death.recovered = q.id
    if StoryEngine.Letters then
        StoryEngine.Letters.createMemorial(q, ps, Store.data().players[death.key], death, now)
    end
    local town, code, distance = Quests.whereFrom(q, player)
    local _, what = 0, ""
    if StoryEngine.Legacy then _, what = StoryEngine.Legacy.shared(fid, death.name) end
    Radio.react(fid, "event", "A new voice is on the radio: " .. ps.name .. ". " .. death.name .. ", whom you "
        .. ((score or 0) > 0 and ("knew (" .. tostring(what) .. ")") or "heard about")
        .. ", died near " .. tostring(death.town or town) .. ". You know roughly where; their things may still be there, "
        .. "about " .. StoryEngine.intToString(distance) .. " tiles from " .. ps.name .. ". Tell them gently, and that it "
        .. "is marked on their map. Do not invent anything about " .. death.name .. " beyond what you know.",
        StoryEngine.Lines.fallback(fid, "recover_ask", death.name .. "'s things may still be out there.",
            { { t = "s", v = death.name }, { t = "town", v = q.place and q.place.town or town }, { t = "dir", v = code },
              { t = "num", v = distance } }), ps)
    log("recover quest", q.id, "for", ps.name, "of", death.name, "via", fid)
    return q
end

-- 수첩을 챙기면 (Quests.hooks)
function Recover.onState(q, state)
    if not (q.origin and q.origin.source == "recover") or state ~= "completed" then return end
    local fid = q.origin.faction
    local ps = Store.data().players[q.target]
    if ps then Store.addNote(ps, { kind = "recover_found", by = q.origin.dead, clock = Sensor.now().clock }) end
    if fid then
        Radio.react(fid, "event", "The new survivor found what was left of " .. tostring(q.origin.dead)
            .. ", including a notebook with their last diary pages. Say something short and kind.",
            StoryEngine.Lines.fallback(fid, "recover_found", "You found it. Keep it close.",
                { { t = "s", v = tostring(q.origin.dead) } }), ps)
    end
end

Quests.hooks[#Quests.hooks + 1] = Recover.onState

Sensor.listeners.tick[#Sensor.listeners.tick + 1] = function(entries, now)
    local ok, err = pcall(Recover.tick, entries, now)
    if not ok then log("recover tick error:", err) end
end

return Recover
