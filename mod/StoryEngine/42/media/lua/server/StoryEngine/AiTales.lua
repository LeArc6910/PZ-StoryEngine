-- AI 곁가지 (서버 측 전용, docs/STORY_YEAR_PLAN.md D). 정해 둔 곁가지(Stories.EPISODES)를 다 썼거나 맞는 것이 없는
-- NPC 에게, 브릿지가 있을 때만 AI 가 짧은 곁가지를 쓴다 (Social.pickEpisode 가 고른다).
--
-- 게임이 정하는 것: 종류(조용한 일 / 물건 부탁 / 소탕 부탁), 등급, 부탁 물건(Needs 표), 결말 갈래, 신뢰도·보상.
-- AI 가 쓰는 것: 제목, 장면마다 beat(영어, AI 용) · say(그 NPC 가 직접 하는 말) · tale(플레이어 입장의 일지 한두 문장),
-- 부탁 사정(why). 번역 키가 없으므로 글을 노드에 그대로 저장한다 (Social.story(fid).ai.tales[arc]).
-- 노드 id 는 <npc>ai<n>_<k> (곁가지 id <npc>ai<n>), Stories.node 가 못 찾으면 AiTales.node 로 찾는다.
-- 글은 요청한 때 접속자가 가장 많이 쓰는 언어 하나로 쓴다.

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Bridge"
require "StoryEngine/Radio"
require "StoryEngine/Stories"
require "StoryEngine/Needs"

local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Bridge = StoryEngine.Bridge
local Radio = StoryEngine.Radio
local Stories = StoryEngine.Stories
local log = StoryEngine.log

local AiTales = { pending = nil }       -- pending = { fid, t } (한 번에 하나)
StoryEngine.AiTales = AiTales

AiTales.KINDS = { { "quiet", 4 }, { "items", 4 }, { "horde", 2 } }
AiTales.DAYS = 5                        -- 곁가지 하나의 대략 길이 (다음 장까지 이만큼 + 2일 여유가 있어야)
AiTales.KEEP = 30                       -- NPC 마다 글을 남겨 두는 곁가지 수 (넘으면 오래된 것의 글을 지나온 장면에 옮기고 지움)
AiTales.RECENT = 6                      -- AI 에 넘기는 지난 AI 곁가지 (되풀이하지 않게)
AiTales.TIMEOUT_MS = 90000
AiTales.LIMIT = { title = 80, beat = 500, say = 600, tale = 700, why = 240 }

function AiTales.enabled()
    return StoryEngine.option("AiSideStories", true) == true
end

-- 브릿지가 붙어 있어 AI 곁가지를 청할 수 있는가
function AiTales.ready()
    return AiTales.enabled() and Bridge.state == "connected" and AiTales.pending == nil
end

local function aiState(fid)
    local st = StoryEngine.Social.story(fid)
    st.ai = st.ai or { seq = 0, tales = {}, order = {} }
    st.ai.tales = st.ai.tales or {}
    st.ai.order = st.ai.order or {}
    return st.ai
end

-- Stories.node 가 정해 둔 이야기에서 못 찾은 노드
function AiTales.node(fid, id)
    if type(id) ~= "string" then return nil end
    local arc = string.match(id, "^(%a+ai%d+)_")
    if not arc then return nil end
    local ch = Radio.channel(fid)
    local tale = ch.story and ch.story.ai and ch.story.ai.tales and ch.story.ai.tales[arc]
    for _, n in ipairs(tale and tale.nodes or {}) do
        if n.id == id then return n end
    end
    return nil
end
Stories.extraNode = AiTales.node

-- 등급: 신뢰도 25마다 하나 (1~5), 진행 단계 상한
function AiTales.tierFor(fid)
    local trust = Radio.channel(fid).trust or 0
    local tier = math.max(1, math.min(5, 1 + math.floor(trust / 25)))
    local cap = Store.STAGE_MAX_TIER[Store.stage()] or 5
    return math.min(tier, cap)
end

local function rollKind()
    local total = 0
    for _, k in ipairs(AiTales.KINDS) do total = total + k[2] end
    local r = ZombRandFloat(0, total)
    for _, k in ipairs(AiTales.KINDS) do
        r = r - k[2]
        if r <= 0 then return k[1] end
    end
    return "quiet"
end

local function language(fid)
    if StoryEngine.Broadcast and StoryEngine.Broadcast.language then
        local ok, lang = pcall(StoryEngine.Broadcast.language, fid)
        if ok and lang then return lang end
    end
    return Radio.langFor(fid)
end

local function clip(v, n)
    if type(v) ~= "string" then return nil end
    v = string.gsub(v, "^%s+", "")
    v = string.gsub(v, "%s+$", "")
    if v == "" then return nil end
    return string.sub(v, 1, n)
end

-- 장면 하나 { beat, say, tale } 를 검사한다
local function scene(t)
    if type(t) ~= "table" then return nil end
    local s = { beat = clip(t.beat, AiTales.LIMIT.beat), say = clip(t.say, AiTales.LIMIT.say),
                tale = clip(t.tale, AiTales.LIMIT.tale) }
    if not (s.beat and s.say and s.tale) then return nil end
    return s
end

-- 받은 JSON 으로 노드를 만든다 (spec = 요청 때 게임이 정한 것). 형식이 어긋나면 nil
function AiTales.build(fid, arc, spec, json)
    if type(json) ~= "table" then return nil end
    local title = clip(json.title, AiTales.LIMIT.title)
    local start = scene(json.start)
    if not (title and start) then return nil end
    local function node(k, s, extra)
        local n = { id = arc .. "_" .. k, beat = s.beat, say = s.say, tale = s.tale, title = title,
                    chapter = "ep", episode = arc, ai = true }
        for key, v in pairs(extra) do n[key] = v end
        return n
    end
    if spec.kind == "quiet" then
        local fin = scene(json["end"])
        if not fin then return nil end
        local tone = (json.tone == "good" or json.tone == "mixed" or json.tone == "bad") and json.tone or "good"
        return title, {
            node(1, start, { days = 2, next = arc .. "_2" }),
            node(2, fin, { final = true, tone = tone, hit = { morale = tone == "bad" and -5 or 5 } }),
        }
    end
    local win, lose = scene(json.win), scene(json.lose)
    if not (win and lose) then return nil end
    local why = clip(json.why, AiTales.LIMIT.why) or spec.why
    local quest = { tier = spec.tier, why = why, items = spec.items }
    if spec.kind == "horde" then quest.kind = "horde" end
    return title, {
        node(1, start, { days = 1, win = arc .. "_2", lose = arc .. "_3", quest = quest }),
        node(2, win, { final = true, tone = "good", hit = { morale = 10 } }),
        node(3, lose, { final = true, tone = "mixed", hit = { morale = -5 } }),
    }
end

-- 오래된 AI 곁가지의 글을 지나온 장면 기록으로 옮기고 지운다 (인물 탭은 기록의 tale·title 을 쓴다)
function AiTales.prune(fid)
    local ai = aiState(fid)
    local st = StoryEngine.Social.story(fid)
    while #ai.order > AiTales.KEEP do
        local arc = table.remove(ai.order, 1)
        local tale = ai.tales[arc]
        if tale and st.node and string.find(st.node, arc .. "_", 1, true) == 1 then
            table.insert(ai.order, 1, arc)       -- 지금 진행 중이면 남긴다
            break
        end
        local byId = {}
        for _, n in ipairs(tale and tale.nodes or {}) do byId[n.id] = n end
        for _, e in ipairs(st.path or {}) do
            local n = byId[e.node]
            if n then e.tale, e.title, e.chapter = n.tale, n.title, "ep" end
        end
        ai.tales[arc] = nil
    end
end

-- AI 에 넘기는 맥락
local function payloadFor(fid, spec, lang)
    local ch = Radio.channel(fid)
    local Social = StoryEngine.Social
    local story, life, world = nil, nil, nil
    local ok, ctx = pcall(Social.context, fid)
    if ok then story = ctx end
    if StoryEngine.Life then
        local okL, l = pcall(StoryEngine.Life.context, fid)
        if okL then life = l end
    end
    if StoryEngine.World and StoryEngine.World.conditions then
        local okW, w = pcall(StoryEngine.World.conditions)
        if okW then world = w end
    end
    local st = Social.story(fid)
    local ai = aiState(fid)
    local recent = {}
    for i = #ai.order, math.max(1, #ai.order - AiTales.RECENT + 1), -1 do
        local t = ai.tales[ai.order[i]]
        if t then
            local n1 = t.nodes and t.nodes[1]
            recent[#recent + 1] = { title = t.title, beat = n1 and n1.beat or nil }
        end
    end
    -- 지난 곁가지(정해 둔 것)의 첫 장면: 같은 이야기를 되풀이하지 않게
    for _, a in ipairs(st.arcs or {}) do
        if a.episode and #recent < AiTales.RECENT * 2 then
            local n = Stories.node(fid, (a.arc or "") .. "_1")
            if n and not n.ai then recent[#recent + 1] = { beat = n.beat } end
        end
    end
    local items = {}
    for _, it in ipairs(spec.items or {}) do items[#items + 1] = { item = it[1], count = it[2] } end
    local players = {}
    for _, p in ipairs(Sensor.players()) do players[#players + 1] = Store.player(p).name end
    return {
        faction = fid, lang = lang, kind = spec.kind, tier = spec.tier, why = spec.why, items = items,
        trust = ch.trust, memory = ch.memory, story = story, life = life, world = world,
        season = Social.season(), recent = recent, players = players,
        day = Store.dayIndex(Sensor.now().dayKey),
    }
end

-- 이 NPC 에게 AI 곁가지를 청한다. 답이 오면 바로 곁가지를 연다. kind 를 주면 그 종류로 (디버그)
function AiTales.request(fid, now, kind)
    if AiTales.pending then return false, "pending" end
    if Bridge.state == "disconnected" then return false, "bridge_offline" end
    local spec = { kind = kind or rollKind(), tier = AiTales.tierFor(fid) }
    if spec.kind ~= "quiet" then
        local need = StoryEngine.Needs.pick(fid, spec.tier)
        if not need then
            spec.kind = "quiet"
        else
            spec.tier, spec.why, spec.items = need.tier, need.why, need.items
        end
    end
    local ai = aiState(fid)
    ai.seq = (ai.seq or 0) + 1
    local arc = fid .. "ai" .. StoryEngine.intToString(ai.seq)
    local lang = language(fid)
    AiTales.pending = { fid = fid, t = now.t, arc = arc }
    log("ai tale requested", fid, arc, spec.kind, spec.tier)
    local id = Bridge.request("episode", payloadFor(fid, spec, lang), function(res)
        AiTales.pending = nil
        AiTales.receive(fid, arc, spec, lang, res)
    end, { timeoutMs = AiTales.TIMEOUT_MS })
    if not id then AiTales.pending = nil end
    return id ~= nil, arc
end

function AiTales.receive(fid, arc, spec, lang, res)
    local Social = StoryEngine.Social
    if not (res and res.ok) then
        log("ai tale failed", fid, arc, tostring(res and res.error))
        return false
    end
    local title, nodes = AiTales.build(fid, arc, spec, res.json)
    if not nodes then
        log("ai tale rejected (bad shape)", fid, arc)
        return false
    end
    local st = Social.story(fid)
    local main = Stories.node(fid, st.node)
    -- 기다리는 동안 이야기가 움직였거나 NPC 가 떠났으면 버린다
    local doomed = StoryEngine.Fate and StoryEngine.Fate.doomed and StoryEngine.Fate.doomed(fid)
    if Factions.isGone(fid) or doomed or st.ep or not (main and main.final) then
        log("ai tale dropped, story moved", fid, arc)
        return false
    end
    local ai = aiState(fid)
    ai.tales[arc] = { title = title, lang = lang, nodes = nodes, day = Store.dayIndex(Sensor.now().dayKey) }
    ai.order[#ai.order + 1] = arc
    AiTales.prune(fid)
    Social.startEpisode(fid, { id = arc, npc = fid, nodes = nodes }, Sensor.now())
    log("ai tale started", fid, arc, spec.kind, title)
    return true
end

function AiTales.statusText()
    local parts = { "aitales" .. (AiTales.enabled() and "" or "(off)") }
    if AiTales.pending then parts[#parts + 1] = "pending=" .. tostring(AiTales.pending.arc) end
    for _, f in ipairs(Factions.list) do
        local ch = Radio.channel(f.id)
        local ai = ch.story and ch.story.ai
        if ai and #(ai.order or {}) > 0 then parts[#parts + 1] = f.id .. "=" .. StoryEngine.intToString(#ai.order) end
    end
    return table.concat(parts, " ")
end

return AiTales
