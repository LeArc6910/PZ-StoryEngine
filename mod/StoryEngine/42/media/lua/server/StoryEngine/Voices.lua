-- 후임 목소리 (2026-10-07 사용자 결정, docs/STORY_YEAR_PLAN.md E).
-- NPC 가 죽거나 떠나면(Fate.apply) Voices.DELAY_DAYS 일 뒤 그 거점의 다른 사람이 같은 주파수를 이어받는다.
-- 거점·주파수·거래 품목·특기·생활 자원·장기 프로젝트는 그대로, 이름·성격·말투·이야기가 바뀐다.
-- 신뢰도는 앞 사람의 share 배(더치 0). 후임까지 죽거나 떠나면 그때는 정말 잡음(한 번만).
-- 방치·실패로 잃었으면(Fate.failed, 2026-10-08 사용자 결정) 샌드박스 SuccessorRule 에 따라:
-- 1 늘 같은 후임 / 2 냉랭한 후임(기본: 20~30일 뒤, 신뢰도 0, 자원 안 채움, 프로젝트 진행도 절반) / 3 후임 없음
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
Voices.COLD_DELAY_DAYS = { 20, 30 }

-- 샌드박스 SuccessorRule (Tuning): 1 늘 / 2 냉랭 / 3 없음
function Voices.rule()
    local Tuning = StoryEngine.Tuning
    local v = Tuning and Tuning.num("SuccessorRule") or 2
    v = math.floor(tonumber(v) or 2)
    if v < 1 or v > 3 then v = 2 end
    return v
end
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
    local node = st and (st.ep and st.ep.node or st.node)       -- 곁가지 중이었으면 큰 이야기의 결말로 (점검 A5)
    local current = Voices.of(fid)
    for _, id in ipairs(Stories.VOICE_ORDER[fid] or {}) do
        local def = Stories.VOICES[id]
        if def and id ~= current and (not def.ifNode or (node and def.ifNode[node])) then return id, def end
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
-- (Social 옵션이 꺼져 있어도 예약은 해 둔다. 이어받기는 옵션이 켜져 있을 때 tick 이 한다, 점검 D6)
function Voices.onFate(fid, kind, now, reason)
    if Voices.of(fid) then
        log("voice silent", fid, "the successor is gone too")
        return
    end
    if not Voices.pick(fid) then return end
    local Fate = StoryEngine.Fate
    local cold = Fate and Fate.failed and Fate.failed(reason) or false
    local rule = Voices.rule()
    if cold and rule == 3 then
        log("voice none", fid, "lost by failure:", tostring(reason))
        return
    end
    if rule == 1 then cold = false end
    local pace = StoryEngine.Social and StoryEngine.Social.pace() or 1
    local r = cold and Voices.COLD_DELAY_DAYS or Voices.DELAY_DAYS
    local days = (r[1] + ZombRand(r[2] - r[1] + 1)) * pace
    state().pending[fid] = { dueT = now.t + math.floor(days * 24 * 60), cold = cold or nil }
    log("voice scheduled", fid, "in", days, "days", cold and "(cold)" or "")
end

-- 이어받는다. cold = 방치·실패로 잃은 뒤 (예약에 적힌 값, 직접 부를 때는 인자로)
function Voices.take(fid, now, cold)
    now = now or Sensor.now()
    local pend = state().pending[fid]
    if cold == nil then cold = pend and pend.cold or false end
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
        story = Social.storyInfo(fid, now), cold = cold or nil,
    }
    n.voice, n.fate, n.starve = id, nil, nil
    if Store.data().fatePending then Store.data().fatePending[fid] = nil end
    Factions.voice[fid] = id
    Stories.NAMES[fid] = def.name
    -- 신뢰도: 앞 사람의 몫, 신뢰도 문턱 기록도 새로
    ch.trust = cold and 0 or math.max(0, math.floor((ch.trust or 0) * (def.share or 0.5)))
    ch.trustMarks = {}
    ch.followUp = nil
    -- 앞 사람의 무전 기억·대화·사람별 기억은 후임 것이 아니다 (2026-10-08 점검 B1·B6)
    ch.memory, ch.memorySeq, ch.voiceSeq = nil, ch.seq or 0, ch.seq or 0
    ch.talked, ch.heard, ch.requests, ch.lastOffender, ch.workBurnT, ch.tradeTrust = {}, {}, nil, nil, nil, nil
    ch.favorOwed, ch.favorOwedBy = nil, nil
    -- 개인 모드의 개인 신뢰도 모두 처음부터 (다음에 만나면 소개 몫으로 새로, DESIGN_PER_PLAYER_TRUST 5-4절)
    if StoryEngine.Trust and StoryEngine.Trust.resetPersonal then StoryEngine.Trust.resetPersonal(fid) end
    -- 2차 특기는 앞 사람이 익힌 것: 후임에게는 없다 (2차 프로젝트를 다시 채우면 다시 고른다)
    if StoryEngine.Specialty2 then StoryEngine.Specialty2.forget(fid) end
    if StoryEngine.Projects and StoryEngine.Projects.DEF2 and StoryEngine.Projects.DEF2[fid] then
        local p2 = StoryEngine.Life.npc(fid).project2
        if p2 and p2.done then p2.done, p2.points, p2.stage = nil, math.floor(StoryEngine.Projects.GOAL2 / 2), 0 end
    end
    n.byWho, n.log, n.counts = {}, {}, {}
    Radio.queue[fid], Radio.again[fid] = nil, nil
    if StoryEngine.Bonds and StoryEngine.Bonds.reset then pcall(StoryEngine.Bonds.reset, fid) end
    if StoryEngine.Letters and StoryEngine.Letters.onVoice then pcall(StoryEngine.Letters.onVoice, fid) end
    -- 새 이야기
    local startNode = Stories.node(fid, def.start)
    ch.story = { node = def.start, since = now.t, told = false, flags = {}, past = {},
                 path = { { node = def.start, day = Store.dayIndex(now.dayKey) } } }
    if StoryEngine.Chronicle then
        StoryEngine.Chronicle.add(fid, { k = "voice", voice = id, prev = n.prevVoices[#n.prevVoices].voice })
    end
    -- 바닥난 자원은 조금 채워서 시작 (그 거점의 다른 사람들이 모은 몫). 방치·실패로 잃었으면 겨우 버틸 만큼만
    -- (Life.SELF_MIN, 그 아래면 스스로 못 회복해 3일 뒤 또 떠난다 — 점검 A2), 장기 프로젝트도 절반이 무너진 채로
    local floor = cold and Life.SELF_MIN or Voices.MIN_RES
    for _, r in ipairs(Life.RESOURCES) do
        local v = Life.get(fid, r)
        if v < floor then Life.change(fid, r, floor - v, "voice") end
    end
    if cold and StoryEngine.Projects and StoryEngine.Projects.halve then pcall(StoryEngine.Projects.halve, fid) end
    Radio.push(fid, { from = "system", voice = id, cold = cold or nil, clock = now.clock })
    if startNode then
        local mood = cold and (" You have heard that when " .. tostring(prevName) .. " needed help most, the players "
            .. "did not come through. You do not trust them, you are curt and wary, and they will have to earn it from "
            .. "nothing.") or ""
        Radio.react(fid, "event", "You are " .. def.name .. ". " .. def.intro .. " You have just taken over this radio "
            .. "frequency after " .. tostring(prevName) .. " was gone." .. mood .. " Introduce yourself to the players, briefly. "
            .. "What is going on with you now: " .. startNode.beat,
            { text = startNode.beat, lt = StoryEngine.Lines.story(def.start) }, nil)
    end
    if Social.news then
        Social.news("all", "A new voice answers on " .. tostring(Factions.byId[fid].freq) .. " MHz: " .. def.name
            .. " took over from " .. tostring(prevName) .. ".")
    end
    pcall(Net.toAll, "npcVoices", { voices = Voices.list() })
    pcall(Net.toAll, "npcFate", { faction = fid, kind = "voice" })
    log("voice", fid, id, "took over from", tostring(prevName), cold and "(cold)" or "")
    return true
end

function Voices.tick()
    if not StoryEngine.option("Social", true) then return end
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
