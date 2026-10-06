-- 캐릭터가 죽은 뒤의 관계 (서버 측 전용, 2026-09-30). 설계: docs/IDEAS_NEXT.md 6번
--
-- 신뢰도는 지금처럼 서버 전체(그룹 평판)이고 바꾸지 않는다. 대신 NPC 가 "누구"와 무엇을 했는지 기억한다:
--   Life.record 가 이름별로 센다 (Life.npc(fid).byWho[이름] = { n, kinds }), Radio.say 가 채널별 발언 수 (ch.talked[이름]).
-- 캐릭터가 죽으면 (Journal.onDeath): 그 이름과 함께한 일이 있는 NPC 가 함께한 만큼 (많은 순으로 최대 4명)
--   각자 무전으로 반응한다. 행적에 player_died.
-- 새 캐릭터가 어떤 NPC 에게 처음 말을 걸면: AI 맥락에 "처음 듣는 목소리, 함께 다니는 사람들, 최근 이 무리에서 죽은 사람과
--   그 사람과 나 사이의 일"을 넣는다 (Radio.request -> payload.newcomer).
-- 죽은 캐릭터의 이름이 붙은 행적에는 dead = true (거점 탭 "(고인)", AI 맥락 "now dead").

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

local Legacy = {}
StoryEngine.Legacy = Legacy

Legacy.MAX_REACT = 4
Legacy.CLOSE = 12
Legacy.KNEW = 4
Legacy.RECENT_DEAD_DAYS = 30
Legacy.NEWCOMER_DEAD = 3
Legacy.NEWCOMER_COMPANIONS = 3

-- 행적 종류별 무게 (함께한 정도)
Legacy.WEIGHT = {
    quest_completed = 3, trade_done = 2, donation = 2, project_gift = 2, crisis_helped = 3, crisis_ally = 2, project_done = 3,
    specialty = 1, ray_supply = 1, quest_accepted = 1, quest_failed = 1, quest_ignored = 1, quest_declined = 1,
    trade_failed = 1, crisis_snubbed = 1, insult = 1, volunteer = 2, volunteer_failed = 1, reward_waived = 2,
}

-- 행적 종류 -> AI 에게 넘기는 영어 (함께한 일 요약)
local KIND_WORDS = {
    quest_completed = "did jobs for you", trade_done = "traded with you", donation = "sent your people supplies",
    project_gift = "helped with your big project", crisis_helped = "took your side in a crisis", crisis_ally = "helped your people through someone else in a crisis",
    quest_failed = "let you down on a job", quest_ignored = "ignored your requests", quest_declined = "turned down your requests",
    trade_failed = "backed out of a trade", crisis_snubbed = "chose someone else over you in a crisis",
    specialty = "called on your help", insult = "insulted you",
    volunteer = "worked for you for nothing", volunteer_failed = "failed a job they offered to do for you",
    reward_waived = "left you the reward they had earned",
}

-- ---------------------------------------------------------------- 기록

-- Life.record 에서: 이름별로 센다
function Legacy.count(n, kind, who)
    if not who or who == "" then return end
    n.byWho = n.byWho or {}
    local e = n.byWho[who] or { n = 0, kinds = {} }
    e.n = e.n + (Legacy.WEIGHT[kind] or 0)
    e.kinds[kind] = (e.kinds[kind] or 0) + 1
    n.byWho[who] = e
end

-- Radio.say 에서: 채널별 발언 수
function Legacy.talked(fid, name)
    if not Factions.byId[fid] or not name then return end
    local ch = Radio.channel(fid)
    ch.talked = ch.talked or {}
    ch.talked[name] = (ch.talked[name] or 0) + 1
end

-- 죽은 이름인가 (같은 이름의 살아 있는 캐릭터가 없을 때만)
function Legacy.isDead(name)
    if not name then return false end
    local dead = false
    for _, e in ipairs(Store.data().deaths or {}) do
        if e.name == name then dead = true end
    end
    if not dead then return false end
    for _, ps in pairs(Store.data().players or {}) do
        if ps.name == name and not ps.dead then return false end
    end
    return true
end

-- 이 NPC 와 그 이름이 함께한 정도: 점수, 영어 요약
function Legacy.shared(fid, name)
    local n = StoryEngine.Life and StoryEngine.Life.npc(fid)
    local e = n and n.byWho and n.byWho[name]
    local kinds = {}
    local score = 0
    if e then
        score = e.n
        for k, c in pairs(e.kinds or {}) do kinds[k] = c end
    elseif n then
        -- 예전 세이브: 최근 행적에서라도 센다
        for _, r in ipairs(n.log or {}) do
            if r.who == name then
                score = score + (Legacy.WEIGHT[r.kind] or 0)
                kinds[r.kind] = (kinds[r.kind] or 0) + 1
            end
        end
    end
    local talks = (Radio.channel(fid).talked or {})[name] or 0
    score = score + math.floor(talks / 3)
    local bits = {}
    for k, c in pairs(kinds) do
        if KIND_WORDS[k] then
            bits[#bits + 1] = KIND_WORDS[k] .. (c > 1 and (" (" .. StoryEngine.intToString(c) .. " times)") or "")
        end
    end
    table.sort(bits)
    if talks > 0 then
        bits[#bits + 1] = "talked with you on the radio " .. StoryEngine.intToString(talks)
            .. (talks == 1 and " time" or " times")
    end
    return score, table.concat(bits, "; ")
end

-- ---------------------------------------------------------------- 죽음

function Legacy.onDeath(name, town)
    if not name then return 0 end
    local list = {}
    for _, f in ipairs(Factions.list) do
        if not Factions.isGone(f.id) then
            local score, what = Legacy.shared(f.id, name)
            if score >= 1 then list[#list + 1] = { fid = f.id, score = score, what = what } end
        end
    end
    table.sort(list, function(a, b) return a.score > b.score end)
    local where = town and (" near " .. tostring(town)) or ""
    for i = 1, math.min(#list, Legacy.MAX_REACT) do
        local e = list[i]
        local depth
        if e.score >= Legacy.CLOSE then
            depth = "You knew them well; this hits you hard. Say something personal about them, grieving in your own way."
        elseif e.score >= Legacy.KNEW then
            depth = "You knew them a little. Say a few words about them, in your own way."
        else
            depth = "You barely knew them. Keep it short, but you remember them."
        end
        local topic = "You just heard that " .. name .. ", one of the players, died" .. where .. ". What was between "
            .. name .. " and you: " .. (e.what ~= "" and e.what or "a few words over the radio") .. ". " .. depth
            .. " Do not invent things you did together beyond that."
        if StoryEngine.Life then StoryEngine.Life.record(e.fid, "player_died", name, 0) end
        Radio.react(e.fid, "event", topic, StoryEngine.Lines.fallback(e.fid, "player_died", name .. " is gone.",
            { { t = "s", v = name } }))
    end
    log("legacy death", name, #list, "contacts knew them")
    return math.min(#list, Legacy.MAX_REACT)
end

-- ---------------------------------------------------------------- 새 목소리

local function knownTo(fid, ps)
    local ch = Radio.channel(fid)
    ch.heard = ch.heard or {}
    if ch.heard[ps.key] then return true end
    if ((ch.talked or {})[ps.name] or 0) > 1 then return true end
    local n = StoryEngine.Life and StoryEngine.Life.npc(fid)
    if n and n.byWho and n.byWho[ps.name] then return true end
    -- 예전 세이브: 이 캐릭터가 이 채널에서 전에 말한 적이 있으면
    local lines = 0
    for _, l in ipairs(ps.radioLife or {}) do
        if l.faction == fid and l.from == "player" then lines = lines + 1 end
    end
    return lines > 1
end

-- 이 캐릭터가 이 NPC 에게 처음 말을 건다면 AI 에게 넘길 맥락 (아니면 nil). 한 번 넘기면 기억한다
function Legacy.newcomer(fid, ps)
    if not ps or not Factions.byId[fid] then return nil end
    if knownTo(fid, ps) then return nil end
    Radio.channel(fid).heard[ps.key] = true
    local now = Sensor.now()
    local today = Store.dayIndex(now.dayKey)
    local dead = {}
    local deaths = Store.data().deaths or {}
    for i = #deaths, 1, -1 do
        local e = deaths[i]
        if #dead < Legacy.NEWCOMER_DEAD and e.name ~= ps.name and Legacy.isDead(e.name)
            and today - (e.day or today) <= Legacy.RECENT_DEAD_DAYS then
            local score, what = Legacy.shared(fid, e.name)
            dead[#dead + 1] = { name = e.name, daysAgo = today - (e.day or today), town = e.town,
                                knew = score >= 1 or nil, what = what ~= "" and what or nil }
        end
    end
    local companions = {}
    for _, other in pairs(Store.data().players or {}) do
        if other.key ~= ps.key and not other.dead and other.name then
            companions[#companions + 1] = { name = other.name, met = (ps.met or {})[other.name] or 0 }
        end
    end
    table.sort(companions, function(a, b) return a.met > b.met end)
    local names = {}
    for i = 1, math.min(#companions, Legacy.NEWCOMER_COMPANIONS) do names[i] = companions[i].name end
    if #dead == 0 and #names == 0 then return nil end
    log("legacy newcomer", fid, ps.name, #dead, "dead", #names, "companions")
    return { name = ps.name, companions = names, dead = dead }
end

return Legacy
