-- 후임 목소리 (2026-10-07 사용자 결정, docs/STORY_YEAR_PLAN.md E).
-- NPC 가 죽거나 떠나면(Fate.apply) Voices.DELAY_DAYS 일 뒤 그 거점의 다른 사람이 같은 주파수를 이어받는다.
-- 거점·주파수·거래 품목·특기·생활 자원·장기 프로젝트는 그대로, 이름·성격·말투·이야기가 바뀐다.
-- 신뢰도는 앞 사람의 share 배(더치 0). 후임까지 죽거나 떠나면 그때는 정말 잡음(한 번만).
-- 후임 정의는 Stories.VOICES (이야기는 Stories.ARCS 에 붙은 <후임>1_* 노드), 브릿지는 요청마다 payload.voices 로
-- 페르소나를 바꾼다(Bridge.request). 상태: Life.npc(fid).voice, .prevVoices(앞 사람 기록), d.voices.pending[fid]

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Radio"
require "StoryEngine/Stories"
require "StoryEngine/Life"

local Net = StoryEngine.Net
local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Radio = StoryEngine.Radio
local Stories = StoryEngine.Stories
local Life = StoryEngine.Life
local log = StoryEngine.log

local Voices = {}
StoryEngine.Voices = Voices

Voices.DELAY_DAYS = { 5, 10 }
Voices.MIN_RES = 30               -- 이어받을 때 바닥난 자원은 여기까지 (다른 사람들이 모은 몫)

-- 원래 이름 (후임이 생기면 Stories.NAMES 를 바꾸고, 되살리기 등에 대비해 남긴다)
Voices.BASE_NAMES = {}
for fid, name in pairs(Stories.NAMES) do Voices.BASE_NAMES[fid] = name end

local function state()
    local d = Store.data()
    d.voices = d.voices or {}
    d.voices.pending = d.voices.pending or {}
    return d.voices
end

function Voices.of(fid)
    return Life.npc(fid).voice
end

-- 이 채널의 후임 (정의 순서대로, ifNode 가 있으면 앞 사람 이야기가 그 노드에서 끝났을 때만)
function Voices.pick(fid)
    local st = StoryEngine.Social and StoryEngine.Social.story(fid)
    for _, id in ipairs(Stories.VOICE_ORDER[fid] or {}) do
        local def = Stories.VOICES[id]
        if def and (not def.ifNode or (st and def.ifNode[st.node])) then return id, def end
    end
    return nil
end

-- 세이브의 후임을 이름표에 반영 (서버 시작·접속 때)
function Voices.apply()
    for _, f in ipairs(Factions.list) do
        local v = Voices.of(f.id)
        Factions.voice[f.id] = v
        local def = v and Stories.VOICES[v]
        Stories.NAMES[f.id] = def and def.name or Voices.BASE_NAMES[f.id]
    end
end

function Voices.list()
    local out = {}
    for _, f in ipairs(Factions.list) do
        local v = Voices.of(f.id)
        if v then out[f.id] = v end
    end
    return out
end

function Voices.sendTo(player)
    if player then Net.toClient(player, "npcVoices", { voices = Voices.list() }) end
end

-- Fate.apply 가 부른다: 처음 사람이면 후임을 예약, 후임이었으면 끝
function Voices.onFate(fid, kind, now)
    if not StoryEngine.option("Social", true) then return end
    if Voices.of(fid) then
        log("voice silent", fid, "the successor is gone too")
        return
    end
    if not Voices.pick(fid) then return end
    local pace = StoryEngine.Social and StoryEngine.Social.pace() or 1
    local r = Voices.DELAY_DAYS
    local days = (r[1] + ZombRand(r[2] - r[1] + 1)) * pace
    state().pending[fid] = { dueT = now.t + math.floor(days * 24 * 60) }
    log("voice scheduled", fid, "in", days, "days")
end

-- 이어받는다
function Voices.take(fid, now)
    now = now or Sensor.now()
    state().pending[fid] = nil
    local id, def = Voices.pick(fid)
    if not id then return false end
    local Social = StoryEngine.Social
    local n = Life.npc(fid)
    local ch = Radio.channel(fid)
    local st = Social.story(fid)
    local prevName = Stories.NAMES[fid]
    -- 앞 사람 기록 (인물 탭 아래쪽)
    n.prevVoices = n.prevVoices or {}
    n.prevVoices[#n.prevVoices + 1] = {
        voice = n.voice, fate = n.fate and n.fate.kind or nil, reason = n.fate and n.fate.reason or nil,
        day = n.fate and n.fate.day or Store.dayIndex(now.dayKey), trust = ch.trust,
        story = Social.storyInfo(fid, now),
    }
    n.voice, n.fate, n.starve = id, nil, nil
    if Store.data().fatePending then Store.data().fatePending[fid] = nil end
    Factions.voice[fid] = id
    Stories.NAMES[fid] = def.name
    -- 신뢰도: 앞 사람의 몫, 신뢰도 문턱 기록도 새로
    ch.trust = math.max(0, math.floor((ch.trust or 0) * (def.share or 0.5)))
    ch.trustMarks = {}
    ch.followUp = nil
    -- 새 이야기
    local startNode = Stories.node(fid, def.start)
    ch.story = { node = def.start, since = now.t, told = false, flags = {}, past = {},
                 path = { { node = def.start, day = Store.dayIndex(now.dayKey) } } }
    if StoryEngine.Chronicle then
        StoryEngine.Chronicle.add(fid, { k = "voice", voice = id, prev = n.prevVoices[#n.prevVoices].voice })
    end
    -- 바닥난 자원은 조금 채워서 시작 (그 거점의 다른 사람들이 모은 몫)
    for _, r in ipairs(Life.RESOURCES) do
        local v = Life.get(fid, r)
        if v < Voices.MIN_RES then Life.change(fid, r, Voices.MIN_RES - v, "voice") end
    end
    Radio.push(fid, { from = "system", voice = id, clock = now.clock })
    if startNode then
        Radio.react(fid, "event", "You are " .. def.name .. ". " .. def.intro .. " You have just taken over this radio "
            .. "frequency after " .. tostring(prevName) .. " was gone. Introduce yourself to the players, briefly. "
            .. "What is going on with you now: " .. startNode.beat,
            { text = startNode.beat, lt = StoryEngine.Lines.story(def.start) }, nil)
    end
    if Social.news then
        Social.news("all", "A new voice answers on " .. tostring(Factions.byId[fid].freq) .. " MHz: " .. def.name
            .. " took over from " .. tostring(prevName) .. ".")
    end
    pcall(Net.toAll, "npcVoices", { voices = Voices.list() })
    pcall(Net.toAll, "npcFate", { faction = fid, kind = "voice" })
    log("voice", fid, id, "took over from", tostring(prevName))
    return true
end

function Voices.tick()
    if not Voices.applied then
        Voices.applied = true
        Voices.apply()
    end
    local now = Sensor.now()
    for fid, p in pairs(state().pending) do
        if now.t >= p.dueT and Factions.isGone(fid) then Voices.take(fid, now) end
    end
end

function Voices.statusText()
    local parts = {}
    for _, f in ipairs(Factions.list) do
        local v = Voices.of(f.id)
        local p = state().pending[f.id]
        if v then parts[#parts + 1] = f.id .. "=" .. v end
        if p then parts[#parts + 1] = f.id .. ":due" .. StoryEngine.intToString(math.max(0, math.floor((p.dueT - Sensor.now().t) / 60))) .. "h" end
    end
    return "voices " .. (#parts > 0 and table.concat(parts, " ") or "none")
end

Events.EveryTenMinutes.Add(function()
    local ok, err = pcall(Voices.tick)
    if not ok then log("voice tick error:", err) end
end)

return Voices
