-- NPC 들의 사회생활 (서버 측 전용): 먼저 거는 연락, 각자의 이야기, 소문, 공용 주파수, 위기 선택.
--
-- 1. 먼저 거는 연락: 서버 전체로 게임 시간 4~6시간마다 한 번 (하루 4~6번), 신뢰도와 상관없이.
--    이유를 골라 NPC 가 먼저 무전한다 (Radio mode "chat"): 이야기 진행 소식 > 들은 소문 > 시간대·날씨 >
--    오래 연락이 없음 > 다른 NPC 이야기 > 그냥 안부. NPC 마다 수다스러운 정도(Stories.TALKATIVE)로 가중치.
-- 2. 이야기: NPC 마다 Stories.ARCS 의 노드를 따라간다. 연계 퀘스트(부탁) 결과에 따라 분기하고,
--    위기 선택의 플래그로도 갈라진다. 현재 이야기와 지난 이야기는 모든 무전 요청에 들어간다 (Social.context).
-- 3. 소문: 다른 생존자의 죽음, 헬기, 폭풍, 퀘스트 결과, 플레이어가 NPC 거점 근처에 다녀간 일을
--    그 일을 알 만한 NPC 에게 소식으로 쌓는다 (d.social.news, 3일 뒤 잊음).
-- 4. 공용 주파수 (채널 "open"): 게임 시간 5~7시간마다 NPC 2~3명이 짧은 장면을 주고받는다 (하루 약 4번).
--    플레이어가 끼어들면 곧바로 NPC 들이 각자 반응하고 서로 이야기한다 (브릿지 radio_scene).
-- 5. 위기: 4~6일마다 여러 세력이 동시에 도움을 청한다 (Stories.CRISES). 퀘스트 탭에서 하나를 고르면
--    고른 세력의 부탁이 퀘스트가 되고, 모든 관련 NPC 의 이야기 흐름·신뢰도가 달라진다.

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Places"
require "StoryEngine/Bridge"
require "StoryEngine/Radio"
require "StoryEngine/Stories"

local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Places = StoryEngine.Places
local Bridge = StoryEngine.Bridge
local Radio = StoryEngine.Radio
local Stories = StoryEngine.Stories
local log = StoryEngine.log

local Social = {
    sceneBusy = false,
    sceneAgain = nil,       -- 장면을 만드는 동안 플레이어가 또 말하면 끝난 뒤 한 번 더 { said, cut }
}
StoryEngine.Social = Social

Social.OPEN = "open"
Social.CONTACT_GAP = { 240, 360 }        -- 먼저 거는 연락 사이 (게임 분): 하루 4~6번
Social.NPC_GAP_MIN = 8 * 60              -- 같은 NPC 가 다시 먼저 연락하기까지
Social.SCENE_GAP = { 300, 420 }          -- 공용 주파수 장면 사이: 하루 약 4번
Social.CRISIS_GAP_DAYS = { 4, 6 }
Social.CRISIS_FIRST_DAYS = 3
Social.NEWS_MAX = 6
Social.NEWS_TTL_MIN = 3 * 24 * 60
Social.NEAR_DIST = 600                   -- 이 거리 안에 다녀가면 그 NPC 가 소문을 듣는다
Social.SILENT_MIN = 3 * 24 * 60
Social.SCENE_LOG = 20      -- 장면에 보여 주는 최근 줄 (2026-10-04: 12 -> 20, 앞서 들은 대답이 너무 빨리 밀려났다)
Social.MAX_SCENE_LINES = 6
Social.SCENE_LINE_GAP = { 20, 40 }       -- 공용 주파수 장면은 한 줄씩 이 간격으로 (게임 분), 사이에 끼어들 수 있다
Social.REPLY_LINE_GAP = { 8, 12 }        -- 플레이어에게 답하는 장면: 첫 줄은 바로, 나머지는 조금 빨리
-- 1년 이야기 (2026-10-07, docs/STORY_YEAR_PLAN.md): 부탁 몰림 방지, 곁가지, 이야기 속도
Social.STORY_OPEN_MAX = 2                -- 서버 전체로 동시에 열린 이야기 부탁·위기
Social.STORY_ASK_GAP_MIN = 12 * 60       -- 새 이야기 부탁 사이 (게임 분)
Social.EPISODE_GAP_DAYS = 7              -- 같은 NPC 의 곁가지 사이
Social.EPISODE_TELL_DAYS = 2             -- 곁가지 결말을 들려주고(또는 이만큼 지나고) 큰 이야기로 돌아간다
Social.PACE = { 1.5, 1, 0.6 }            -- 샌드박스 StoryPace: 느림 / 보통 / 빠름

-- 이야기 속도 배율 (장면 일수·장 사이 대기·곁가지 간격·후임이 오기까지)
function Social.pace()
    local Tuning = StoryEngine.Tuning
    local v = Tuning and Tuning.num("StoryPace") or 2
    return Social.PACE[math.floor(v)] or 1
end

-- 결말(node)에서 다음 장이 시작되기까지 (게임 분)
-- 결말의 다음 장 첫 장면 (sequel 이 { default, list = {{플래그, id}} } 이면 그 NPC 의 플래그로 고른다)
-- 이 결말의 다음 장 정의 (살아남은 죽음·떠남 결말은 Stories.SURVIVED_SEQUEL, Fate.onStoryFate 가 적어 둔다)
function Social.sequelOf(fid, node)
    if not node then return nil end
    if node.sequel then return node.sequel end
    local sv = Social.story(fid).survivedSequel
    if sv and sv.node == node.id then return sv.to end
    return nil
end

function Social.sequelTarget(fid, node)
    local spec = Social.sequelOf(fid, node)
    if not spec then return nil end
    if type(spec) ~= "table" then return spec end
    return Social.resolveNext(spec, Social.story(fid).flags or {})
end

function Social.sequelDelay(fid, node)
    local target = Social.sequelTarget(fid, node)
    local nextNode = target and Stories.node(fid, target)
    local r = (nextNode and Stories.CHAPTER_GAP[nextNode.chapter or 2]) or Stories.SEQUEL_DAYS
    return math.floor((r[1] + ZombRand(r[2] - r[1] + 1)) * Social.pace() * 24 * 60)
end

function Social.enabled()
    return StoryEngine.option("Social", true) == true
end

local function state()
    local d = Store.data()
    d.social = d.social or {}
    local s = d.social
    s.news = s.news or {}
    s.crisesUsed = s.crisesUsed or {}
    return s
end

local function rand(range)
    return range[1] + ZombRand(range[2] - range[1] + 1)
end

local function nameOf(fid)
    return Stories.NAMES[fid] or fid
end

local function onlinePlayers()
    local out = {}
    for _, p in ipairs(Sensor.players()) do out[#out + 1] = p end
    return out
end

local function randomTarget()
    local players = onlinePlayers()
    if #players == 0 then return nil end
    local p = players[ZombRand(#players) + 1]
    return p, Store.player(p)
end

-- ---------------------------------------------------------------- story

function Social.story(fid)
    local ch = Radio.channel(fid)
    if not ch.story then
        local arc = Stories.ARCS[fid]
        -- 시작 시점을 흩어 모두가 같은 날 넘어가지 않게 한다
        ch.story = { node = arc and arc[1].id or nil, since = Sensor.now().t - ZombRand(2 * 24 * 60),
                     told = false, flags = {}, past = {} }
        if arc and arc[1] then
            ch.story.path = { { node = arc[1].id, day = Store.dayIndex(Sensor.now().dayKey) } }
        end
        -- 인물 탭의 지나온 일: 처음 이야기 (Chronicle.lua)
        if StoryEngine.Chronicle and arc and arc[1] then pcall(StoryEngine.Chronicle.onBeat, fid, arc[1]) end
    end
    ch.story.flags = ch.story.flags or {}
    ch.story.past = ch.story.past or {}
    return ch.story
end

-- 다음 노드: 문자열, 또는 { default, flags = { 플래그 = id }, list = { { 플래그, id }, ... } (앞에서부터),
-- when = { { npc, node | arc, go } } (다른 NPC 가 지금 그 노드·그 이야기에 있으면 — 이야기끼리 얽힘) }
local function resolveNext(nextSpec, flags)
    if type(nextSpec) ~= "table" then return nextSpec end
    for _, w in ipairs(nextSpec.when or {}) do
        if w.state then
            -- 그 NPC 가 지나온 장면 중 가장 최근에 state 에 있는 장면의 값 (결말로 판단, 점검 A7)
            local path = Social.storyPath(w.npc)
            for i = #path, 1, -1 do
                local v = w.state[path[i].node]
                if v ~= nil then
                    if v then return w.go end
                    break
                end
            end
        elseif not Factions.isGone(w.npc) then
            local ost = Social.story(w.npc)
            local other = ost.ep and ost.ep.node or ost.node      -- 곁가지 중이면 큰 이야기 자리로
            if other and ((w.node and other == w.node) or (w.arc and Stories.arcOf(w.npc, other) == w.arc)) then
                return w.go
            end
        end
    end
    for _, pair in ipairs(nextSpec.list or {}) do
        if flags[pair[1]] then return pair[2] end
    end
    for flag, id in pairs(nextSpec.flags or {}) do
        if flags[flag] then return id end
    end
    return nextSpec.default
end
Social.resolveNext = resolveNext

function Social.moveTo(fid, id, now)
    local st = Social.story(fid)
    local cur = Stories.node(fid, st.node)
    local nxt = Stories.node(fid, id)
    if not nxt then return end
    if cur then Store.push(st.past, cur.beat, 4) end
    Social.storyPath(fid)
    Store.push(st.path, { node = id, day = Store.dayIndex(now.dayKey) }, Social.PATH_MAX)
    st.node, st.since, st.told, st.questId, st.crisisAsked = id, now.t, false, nil, nil
    if nxt.flag then st.flags[nxt.flag] = true end       -- 같은 장 안의 갈래용 (Stories.CHAPTER3 등)
    if nxt.hurt then st.hurtUntil = now.t + math.floor(nxt.hurt * 24 * 60) end   -- 다쳐서 특기를 못 쓴다 (Specialty)
    if nxt.hitAll and StoryEngine.Life then
        for _, f in ipairs(Factions.list) do
            if f.id ~= fid and not Factions.isGone(f.id) then
                for res, d in pairs(nxt.hitAll) do
                    pcall(StoryEngine.Life.change, f.id, res, d, "story " .. fid)
                end
            end
        end
    end
    log("story", fid, "->", id)
    -- 결말: 다음 이야기가 있으면 그 날을 정해 둔다 (Stories.SEQUEL_DAYS)
    if nxt.final and Social.sequelOf(fid, nxt) then
        st.sequelAt = now.t + Social.sequelDelay(fid, nxt)
    end
    -- 곁가지 결말: 지난 이야기에 남긴다 (큰 이야기로는 Social.advance 가 돌려보낸다)
    if nxt.final and nxt.episode then
        st.arcs = st.arcs or {}
        st.arcs[#st.arcs + 1] = { arc = Stories.arcOf(fid, nxt.id), ending = nxt.id, tone = nxt.tone,
                                  day = Store.dayIndex(now.dayKey), episode = true }
    end
    if StoryEngine.Chronicle then
        local ok, err = pcall(StoryEngine.Chronicle.onBeat, fid, nxt)
        if not ok then log("chronicle beat error:", err) end
    end
    if StoryEngine.Life then
        local ok, err = pcall(StoryEngine.Life.onBeat, fid, nxt)
        if not ok then log("life beat error:", err) end
    end
    if StoryEngine.Bonds then
        local ok, err = pcall(StoryEngine.Bonds.onBeat, nxt)
        if not ok then log("bond beat error:", err) end
    end
    if nxt.final and StoryEngine.Fate and not nxt.chapter then
        local ok, err = pcall(StoryEngine.Fate.onStoryFinal, fid, nxt)
        if not ok then log("fate final error:", err) end
    end
    -- 두 번째 이야기의 결말이 죽음·떠남이면 하루 뒤 정말로 (Fate.onStoryFate)
    if nxt.fate and StoryEngine.Fate then
        local ok, err = pcall(StoryEngine.Fate.onStoryFate, fid, nxt)
        if not ok then log("fate story2 error:", err) end
    end
end

-- 첫 이야기 결말 뒤 두 번째 이야기를 연다
function Social.startSequel(fid, now)
    local st = Social.story(fid)
    local node = Stories.node(fid, st.node)
    local target = Social.sequelTarget(fid, node)
    if not target or not Stories.node(fid, target) then return false end
    st.arcs = st.arcs or {}
    st.arcs[#st.arcs + 1] = { arc = Stories.arcOf(fid, node.id), ending = node.id, tone = node.tone,
                              day = Store.dayIndex(now.dayKey), wins = st.wins, losses = st.losses }
    st.wins, st.losses, st.sequelAt = nil, nil, nil
    if StoryEngine.Chronicle then
        StoryEngine.Chronicle.add(fid, { k = "arc", arc = Stories.arcOf(fid, target), prev = Stories.arcOf(fid, node.id) })
    end
    log("story sequel", fid, node.id, "->", target)
    Social.moveTo(fid, target, now)
    return true
end

-- 이 NPC 에게 답을 기다리거나 진행 중인 부탁이 있는가
local function openQuestFor(fid)
    for _, q in pairs(Store.data().quests) do
        if q.origin and q.origin.faction == fid and (q.kind == "deliver" or q.kind == "horde" or q.kind == "named")
            and (q.state == "proposed" or q.state == "accepted") then
            return q
        end
    end
    return nil
end

-- 이야기 부탁을 낸다: 물건(기본) / 소탕(kind = "horde") / 아는 얼굴의 좀비(kind = "named").
-- 소탕 건물을 못 찾았거나 아는 얼굴의 좀비가 꺼져 있으면 물건 부탁(spec.items)으로
local function proposeStoryQuest(player, ps, fid, node, now)
    local spec = node.quest
    local story = { faction = fid, node = node.id }
    local q
    if spec.kind == "horde" then
        q = StoryEngine.Quests.proposeHorde(player, ps, fid, spec.tier, now, { story = story, why = spec.why })
    elseif spec.kind == "named" and StoryEngine.Named and StoryEngine.Named.enabled() then
        local person = StoryEngine.Named.byId[spec.person]
        if person then q = StoryEngine.Named.propose(player, ps, person, now, { story = story, why = spec.why }) end
    end
    if not q and spec.items then
        q = StoryEngine.Quests.proposeCustom(player, ps, fid, spec, now, { story = story })
    end
    return q
end

-- 이야기 속에서 다쳐 특기를 못 쓰는 중인가 (노드 hurt = 일수)
function Social.isHurt(fid, now)
    local st = Social.story(fid)
    return st.hurtUntil ~= nil and (now or Sensor.now()).t < st.hurtUntil
end

-- 새 이야기 부탁·위기를 낼 수 있는가 (서버 전체: 열린 것 STORY_OPEN_MAX 개 미만, 마지막 뒤 STORY_ASK_GAP_MIN).
-- Social.forceAsk 면 무시 (디버그)
function Social.storyAskAllowed(now)
    if Social.forceAsk then return true end
    local s = state()
    if s.lastStoryAskT and now.t - s.lastStoryAskT < Social.STORY_ASK_GAP_MIN then return false end
    local open = 0
    for _, q in pairs(Store.data().quests) do
        local tag = q.origin and q.origin.story
        if ((tag and tag.node) or q.kind == "choice")
            and (q.state == "proposed" or StoryEngine.Quests.isActive(q)) then
            open = open + 1
        end
    end
    return open < Social.STORY_OPEN_MAX
end

-- 계절 (게임 달력): spring 3~5월, summer 6~8월, fall 9~11월, winter 12~2월
function Social.season()
    local ok, m = pcall(function() return getGameTime():getMonth() end)
    m = ok and tonumber(m) or 6
    if m >= 2 and m <= 4 then return "spring" end
    if m >= 5 and m <= 7 then return "summer" end
    if m >= 8 and m <= 10 then return "fall" end
    return "winter"
end

-- 곁가지(Stories.EPISODES)를 이 NPC 에게 지금 열 수 있는가. when = { season = {..}, trust = n, alive = {..},
-- arcs = {..} (이 NPC 가 지나온 이야기 중 하나), nodes = {..} (지금 큰 이야기 노드), anyFlag = {..} (이 NPC 플래그 중 하나),
-- voice = id | false, world = 조건 }
function Social.episodeOk(def, fid, now)
    local w = def.when or {}
    local st = Social.story(fid)
    if (st.epUsed or {})[def.id] then return false end
    local voice = StoryEngine.Voices and StoryEngine.Voices.of(fid) or nil
    if w.voice ~= nil then
        if w.voice == false and voice then return false end
        if w.voice and w.voice ~= voice then return false end
    elseif voice then
        return false          -- 정해 두지 않은 곁가지는 처음 사람에게만
    end
    if w.season then
        local cur, ok = Social.season(), false
        for _, x in ipairs(w.season) do if x == cur then ok = true end end
        if not ok then return false end
    end
    if w.trust and (Radio.channel(fid).trust or 0) < w.trust then return false end
    -- 곁가지 글이 그 사람(처음 사람)을 부르므로, 후임이 이어받은 채널이면 안 맞는다 (점검 B4)
    for _, other in ipairs(w.alive or {}) do
        if Factions.isGone(other) or (Factions.voice and Factions.voice[other]) then return false end
    end
    if w.nodes then
        local ok = false
        for _, x in ipairs(w.nodes) do if st.node == x then ok = true end end
        if not ok then return false end
    end
    if w.anyFlag then
        local ok = false
        for _, x in ipairs(w.anyFlag) do if (st.flags or {})[x] then ok = true end end
        if not ok then return false end
    end
    if w.arcs then
        local seen = {}
        for _, e in ipairs(Social.storyPath(fid)) do seen[Stories.arcOf(fid, e.node)] = true end
        local ok = false
        for _, x in ipairs(w.arcs) do if seen[x] then ok = true end end
        if not ok then return false end
    end
    if w.world and StoryEngine.World and StoryEngine.World.conditions then
        local okW, conds = pcall(StoryEngine.World.conditions)
        local has = false
        for _, c in ipairs(okW and conds or {}) do if string.find(c, w.world, 1, true) then has = true end end
        if not has then return false end
    end
    return true
end

-- 곁가지 하나의 대략 길이 (일)
local function episodeDays(def)
    local d = 0
    for _, n in ipairs(def.nodes or {}) do d = d + (n.days or 1) + (n.quest and 2 or 0) end
    return d
end

-- 곁가지를 열 NPC 를 고른다 (Social.hourly 가 하루 한 번). 큰 이야기 결말에서 다음 장까지 시간이 넉넉하거나
-- 다음 장이 없을 때, 마지막 곁가지 뒤 EPISODE_GAP_DAYS 가 지났을 때
function Social.pickEpisode(now)
    local s = state()
    local day = Store.dayIndex(now.dayKey)
    if s.episodeDay == day or #Sensor.players() == 0 then return nil end
    s.episodeDay = day
    local pace = Social.pace()
    local cands, total = {}, 0
    local AiTales = StoryEngine.AiTales
    local aiOk = AiTales and AiTales.ready()
    for _, f in ipairs(Factions.list) do
        local fid = f.id
        local st = Social.story(fid)
        local node = Stories.node(fid, st.node)
        local doomed = StoryEngine.Fate and StoryEngine.Fate.doomed and StoryEngine.Fate.doomed(fid)
        local free = node and node.final and not node.episode and not Factions.isGone(fid) and not doomed
            and not (st.epEndT and now.t - st.epEndT < Social.EPISODE_GAP_DAYS * pace * 24 * 60)
        if free then
            local any = false
            for _, def in ipairs(Stories.EPISODES) do
                local npc = def.npc
                local fits = npc == fid
                if fits and Social.sequelOf(fid, node) and st.sequelAt then
                    fits = (st.sequelAt - now.t) >= (episodeDays(def) + 2) * pace * 24 * 60
                end
                if fits and Social.episodeOk(def, fid, now) then
                    local w = def.weight or 1
                    cands[#cands + 1] = { fid = fid, def = def, w = w }
                    total, any = total + w, true
                end
            end
            -- 정해 둔 곁가지가 남지 않은 NPC: 브릿지가 있으면 AI 곁가지 (AiTales.lua)
            local roomy = aiOk and (not (Social.sequelOf(fid, node) and st.sequelAt)
                or (st.sequelAt - now.t) >= (AiTales.DAYS + 2) * pace * 24 * 60)
            if not any and roomy then
                cands[#cands + 1] = { fid = fid, ai = true, w = 1 }
                total = total + 1
            end
        end
    end
    if total <= 0 then return nil end
    local roll = ZombRandFloat(0, total)
    for _, c in ipairs(cands) do
        roll = roll - c.w
        if roll <= 0 then
            if c.ai then
                local ok, arc = AiTales.request(c.fid, now)
                return ok and ("ai:" .. tostring(arc)) or nil
            end
            Social.startEpisode(c.fid, c.def, now)
            return c.def.id
        end
    end
    return nil
end

function Social.startEpisode(fid, def, now)
    local st = Social.story(fid)
    st.ep = { id = def.id, node = st.node, since = st.since, told = st.told }
    st.epUsed = st.epUsed or {}
    st.epUsed[def.id] = true
    log("story episode", fid, def.id)
    Social.moveTo(fid, def.nodes[1].id, now)
end

-- 곁가지에서 큰 이야기 결말 자리로 돌아간다 (결말 효과를 다시 내지 않게 moveTo 를 거치지 않는다)
function Social.endEpisode(fid, now)
    local st = Social.story(fid)
    local back = st.ep
    if not back then return end
    st.node, st.since, st.told, st.questId, st.crisisAsked = back.node, back.since, true, nil, nil
    st.ep, st.epEndT = nil, now.t
    if st.sequelAt then st.sequelAt = math.max(st.sequelAt, now.t + 2 * 24 * 60) end
    log("story episode done", fid, back.id)
end

-- 위기 노드: 결과가 나왔는가 (이 NPC 의 플래그로)
local function crisisSettled(flags, id)
    for _, suffix in ipairs({ "_done", "_failed", "_spared", "_snubbed", "_ignored", "_skipped" }) do
        if flags[id .. suffix] then return true end
    end
    return false
end

function Social.advance(fid, now)
    if Factions.isGone(fid) then return end
    local st = Social.story(fid)
    local node = Stories.node(fid, st.node)
    if not node then return end
    if node.final then
        -- 곁가지가 끝났다: 결말을 들려주었거나 며칠 지나면 큰 이야기의 자리로 돌아간다
        if node.episode then
            if st.told or now.t - st.since >= Social.EPISODE_TELL_DAYS * 24 * 60 then Social.endEpisode(fid, now) end
            return
        end
        -- 결말 뒤 다음 장 (예전 세이브는 결말에 머문 지금부터 센다)
        if Social.sequelOf(fid, node) then
            if not st.sequelAt then
                local r = Stories.SEQUEL_DAYS
                st.sequelAt = math.max(st.since or now.t, now.t - r[1] * 24 * 60) + (r[1] + ZombRand(r[2] - r[1] + 1)) * 24 * 60
            end
            if now.t >= st.sequelAt then Social.startSequel(fid, now) end
        end
        return
    end
    if node.crisis then
        local id = node.crisis
        if not st.crisisAsked then
            if now.t - st.since < (node.days or 1) * Social.pace() * 24 * 60 then return end
            if not Social.storyAskAllowed(now) then return end
            local ok, why = Social.startCrisis(now, id)
            if ok then
                st.crisisAsked, st.told = id, true
                state().lastStoryAskT = now.t
                log("story crisis", fid, node.id, id)
            elseif why ~= "no_players" then
                -- 위기를 열 수 없다 (관련 NPC 가 떠났거나 이미 쓴 위기): next.default 로
                st.crisisAsked = id
                st.flags[id .. "_skipped"] = true
                log("story crisis skipped", fid, id, why)
            end
            return
        end
        if crisisSettled(st.flags, id) then Social.moveTo(fid, resolveNext(node.next, st.flags), now) end
        return
    end
    if node.quest then
        if st.questId then return end
        if now.t - st.since < (node.days or 1) * Social.pace() * 24 * 60 then return end
        if openQuestFor(fid) then return end
        if not Social.storyAskAllowed(now) then return end
        local player, ps = randomTarget()
        if not player then return end
        local q = proposeStoryQuest(player, ps, fid, node, now)
        if q then
            st.questId, st.told = q.id, true    -- 부탁하는 무전이 곧 이야기다
            state().lastStoryAskT = now.t
            log("story quest", fid, node.id, q.id, q.kind)
        end
        return
    end
    if now.t - st.since >= (node.days or 2) * Social.pace() * 24 * 60 then
        Social.moveTo(fid, resolveNext(node.next, st.flags), now)
    end
end

-- 지나온 장면 (인물 탭에서 처음부터 지금까지). 예전 세이브는 지나온 일 기록의 장면으로 채운다
Social.PATH_MAX = 60
function Social.storyPath(fid)
    local st = Social.story(fid)
    if st.path then return st.path end
    st.path = {}
    if StoryEngine.Chronicle then
        for _, e in ipairs(StoryEngine.Chronicle.list(fid)) do
            if e.k == "beat" and e.node then st.path[#st.path + 1] = { node = e.node, day = e.day } end
        end
    end
    local last = st.path[#st.path]
    if st.node and (not last or last.node ~= st.node) then st.path[#st.path + 1] = { node = st.node } end
    return st.path
end

-- 인물 탭 "큰 이야기" (Chronicle.payload): 지금 이야기·몇 번째·지금 장면·끝났는지·다음 이야기까지·지난 이야기
function Social.storyInfo(fid, now)
    local st = Social.story(fid)
    local node = Stories.node(fid, st.node)
    if not node then return nil end
    now = now or Sensor.now()
    local info = { arc = Stories.arcOf(fid, node.id), chapter = node.chapter or 1, node = node.id,
                   final = node.final == true, tone = node.tone, asking = (st.questId or st.crisisAsked) and true or nil,
                   episode = node.episode ~= nil or nil, voice = StoryEngine.Voices and StoryEngine.Voices.of(fid) or nil,
                   past = {} }
    local main = st.ep and Stories.node(fid, st.ep.node) or node
    if main and main.final and Social.sequelOf(fid, main) and st.sequelAt then
        info.nextDays = math.max(0, math.ceil((st.sequelAt - now.t) / (24 * 60)))
        info.waiting = st.ep ~= nil or nil
    end
    for _, a in ipairs(st.arcs or {}) do
        info.past[#info.past + 1] = { arc = a.arc, ending = a.ending, tone = a.tone, day = a.day }
    end
    -- 처음부터 지금까지 지나온 장면 { node, day, arc }
    info.path = {}
    for _, e in ipairs(Social.storyPath(fid)) do
        local n = Stories.node(fid, e.node)
        -- tale·title: AI 곁가지(나중, docs/STORY_YEAR_PLAN.md D)는 번역 키 대신 글을 그대로 저장한다
        info.path[#info.path + 1] = { node = e.node, day = e.day, arc = Stories.arcOf(fid, e.node),
                                      chapter = n and n.chapter or e.chapter or 1,
                                      tale = e.tale or (n and n.tale), title = e.title or (n and n.title) }
    end
    return info
end

-- 무전 요청에 넣는 이 NPC 의 사정과 다른 NPC 에 대한 생각
function Social.context(fid)
    if not Factions.byId[fid] then return nil end
    local st = Social.story(fid)
    local node = Stories.node(fid, st.node)
    local others = {}
    local Bonds = StoryEngine.Bonds
    for _, f in ipairs(Factions.list) do
        local other = f.id
        local note = Stories.relationsOf(fid)[other]
        local bond = Bonds and Bonds.get(fid, other) or 0
        local recent = Bonds and Bonds.recent(fid, other) or nil
        if other ~= fid and (note or bond ~= 0 or recent) then
            local ost = Social.story(other)
            local onode = Stories.node(other, ost.node)
            others[#others + 1] = { id = other, note = note, trust = Radio.channel(other).trust,
                                    beat = onode and onode.beat or nil, gone = Factions.fateOf(other),
                                    bond = bond, shift = recent and recent.text or nil }
        end
    end
    -- 관계표에 적힌 사람 먼저 (브릿지는 앞의 6명만 쓴다)
    table.sort(others, function(a, b)
        if (a.note ~= nil) ~= (b.note ~= nil) then return a.note ~= nil end
        return math.abs(a.bond or 0) > math.abs(b.bond or 0)
    end)
    local news = {}
    for _, n in ipairs(state().news[fid] or {}) do news[#news + 1] = n.text end
    return { beat = node and node.beat or nil, past = st.past, others = others, news = news }
end

-- ---------------------------------------------------------------- news

function Social.news(fid, text)
    if fid == "all" then
        -- 모두가 알게 된 소식은 저녁 라디오 방송 재료도 된다 (Broadcast.lua)
        if StoryEngine.Broadcast then StoryEngine.Broadcast.note(text) end
        for _, f in ipairs(Factions.list) do Social.news(f.id, text) end
        return
    end
    local s = state()
    local list = s.news[fid] or {}
    Store.push(list, { t = Sensor.now().t, text = string.sub(text, 1, 300) }, Social.NEWS_MAX)
    s.news[fid] = list
end

local function freshNews(fid, now)
    local s = state()
    local kept = {}
    for _, n in ipairs(s.news[fid] or {}) do
        if now.t - n.t < Social.NEWS_TTL_MIN then kept[#kept + 1] = n end
    end
    s.news[fid] = kept
    return kept
end

-- 하루가 끝날 때: 그 플레이어가 어느 NPC 거점 근처에 다녀갔는지 (Sensor 의 day.near)
function Social.onDayEnd(player, ps, day)
    for fid, town in pairs(day.near or {}) do
        local text = tostring(ps.name) .. " was seen around " .. tostring(town) .. ", not far from your place"
        if (day.kills or 0) >= 15 then text = text .. ", and there was a lot of shooting and fighting" end
        Social.news(fid, text .. ".")
    end
end

function Social.onDeath(name, town)
    state().deathT, state().deathName = Sensor.now().t, tostring(name)
    Social.news("all", "Word on the radio is that " .. tostring(name) .. ", one of the survivors you know of, died"
        .. (town and (" near " .. tostring(town)) or "") .. ".")
end

function Social.onHelicopter()
    state().heliT = Sensor.now().t
    Social.news("all", "A helicopter flew low over the county today. Nobody knows who was flying it.")
end

function Social.onStorm()
    state().stormT = Sensor.now().t
    if StoryEngine.Life then pcall(StoryEngine.Life.onStorm) end
    Social.news("guard", "A heavy storm is rolling in over the county.")
    if StoryEngine.Broadcast then StoryEngine.Broadcast.note("A heavy storm rolled in over the county.") end
    Social.news("casey", "Your barometer is dropping fast: a heavy storm is coming.")
end

-- ---------------------------------------------------------------- quests

function Social.onQuest(q, outcome)
    local tag = q.origin and q.origin.story
    local now = Sensor.now()
    if tag and tag.node then
        -- 떠난 NPC 의 이야기는 움직이지 않는다 (거둬지지 않은 부탁이 늦게 끝나도, 점검 A3)
        if Factions.isGone(tag.faction) then return end
        local st = Social.story(tag.faction)
        if st.node ~= tag.node or outcome == "accepted" then return end
        local node = Stories.node(tag.faction, tag.node)
        if not node then return end
        if outcome == "completed" then
            if StoryEngine.Fate then StoryEngine.Fate.onStoryResult(tag.faction, true) end
            if StoryEngine.Projects then StoryEngine.Projects.onStoryWin(tag.faction, q.targetName, node, q.tier) end
            Social.moveTo(tag.faction, resolveNext(node.win, st.flags), now)
        elseif outcome == "failed" or outcome == "declined" or outcome == "ignored" then
            if StoryEngine.Fate then StoryEngine.Fate.onStoryResult(tag.faction, false) end
            Social.moveTo(tag.faction, resolveNext(node.lose, st.flags), now)
        end
    end
    if tag and tag.crisis and outcome ~= "accepted" then
        local flag = tag.crisis .. (outcome == "completed" and "_done" or "_failed")
        Social.story(q.origin.faction).flags[flag] = true
        -- 함께 도운 것이 된 NPC 도 같은 결과 (교회 습격: 방위대 순찰이 성공하면 교회도 지켜짐)
        local def = Stories.crisisOption(tag.crisis, q.origin.faction)
        for _, a in ipairs(def and def.allies or {}) do Social.story(a).flags[flag] = true end
    end
    if q.kind == "choice" and (outcome == "ignored" or outcome == "declined") then
        Social.onChoiceIgnored(q)
    end
    -- 소문: 사이가 있는 NPC 들이 듣는다
    local fid = q.origin and q.origin.faction
    if fid and q.kind ~= "choice" and (outcome == "completed" or outcome == "failed") then
        for _, f in ipairs(Factions.list) do
            local other = f.id
            if other ~= fid and Stories.relationsOf(other)[fid] then
                Social.news(other, "The players " .. (outcome == "completed" and "did a job for " or "let down ")
                    .. nameOf(fid) .. " recently.")
            end
        end
    end
end

-- ---------------------------------------------------------------- crisis

-- forceId: 이 위기를 고른다 (NpcEvents: 교회 습격 앞당김, 충돌). trigger = true 인 위기는 그렇게만 나온다
function Social.startCrisis(now, forceId)
    if not forceId and StoryEngine.Ops and StoryEngine.Ops.active() then return false, "operation" end
    if not forceId and StoryEngine.Saga and StoryEngine.Saga.active() then return false, "saga" end
    local s = state()
    local pool = {}
    for _, c in ipairs(Stories.CRISES) do
        local alive = true
        for _, o in ipairs(c.options) do
            local Fate = StoryEngine.Fate
            if Factions.isGone(o.faction) or (Fate and Fate.doomed and Fate.doomed(o.faction)) then alive = false end
            -- 위기 글은 처음 사람들을 부른다: 후임이 이어받은 채널이 끼면 열지 않는다 (점검 B3)
            if Factions.voice and Factions.voice[o.faction] then alive = false end
        end
        local wanted = (forceId and c.id == forceId) or (not forceId and not c.trigger)
        if not s.crisesUsed[c.id] and alive and wanted then pool[#pool + 1] = c end
    end
    if #pool == 0 then return false, "no_crisis" end
    local player, ps = randomTarget()
    if not player then return false, "no_players" end
    local c = pool[ZombRand(#pool) + 1]
    local q = StoryEngine.Quests.proposeChoice(player, ps, c, now)
    if not q then return false, "quest_failed" end
    s.crisesUsed[c.id] = true
    s.lastCrisisT = now.t
    for _, opt in ipairs(c.options) do
        local rivals = {}
        for _, o in ipairs(c.options) do
            if o.faction ~= opt.faction then rivals[#rivals + 1] = nameOf(o.faction) .. " wants them to " .. o.ask end
        end
        StoryEngine.Radio.react(opt.faction, "crisis", c.situation .. " You want the players to " .. opt.ask
            .. ". Others are asking them for help at the same time: " .. table.concat(rivals, "; ")
            .. ". They can only help one of you and will choose in their quest log.",
            StoryEngine.Lines.fallback(opt.faction, "crisis_appeal", "I need your help. Check your quest log.",
                { { t = "key", v = "IGUI_StoryEngine_Crisis_" .. c.id .. "_title" } }), ps)
    end
    log("crisis", c.id, "for", ps.name)
    return true, c.id
end

-- 플레이어가 한 세력을 골랐다 (Quests.choose)
function Social.onChoice(q, opt, player)
    local now = Sensor.now()
    local ps = Store.player(player)
    local c = Stories.crisis(q.crisis)
    local Trust = StoryEngine.Trust
    for _, o in ipairs(q.options) do
        local st = Social.story(o.faction)
        local role = Stories.crisisRole(q.crisis, opt.faction, o.faction)
        -- 누구를 골랐는지 (두 번째 이야기가 갈린다: <위기>_chose_<npc>)
        st.flags[q.crisis .. "_chose_" .. opt.faction] = true
        if StoryEngine.Chronicle then
            StoryEngine.Chronicle.add(o.faction, { k = "crisis", crisis = q.crisis, role = role, by = opt.faction })
        end
        if role == "chosen" then
            st.flags[q.crisis .. "_helped"] = true
            if StoryEngine.Fate then StoryEngine.Fate.onStoryResult(o.faction, true) end
            if StoryEngine.Projects then StoryEngine.Projects.onCrisisHelped(o.faction, ps.name) end
            if Trust then Trust.apply(o.faction, 2, "crisis_chosen", q.id) end
        elseif role == "ally" then
            -- 고른 쪽의 부탁이 이 NPC 의 바람도 이뤄 준다 (교회 습격에서 방위대 순찰 -> 교회 보호)
            st.flags[q.crisis .. "_helped"] = true
            if StoryEngine.Fate then StoryEngine.Fate.onStoryResult(o.faction, true) end
            if Trust then Trust.apply(o.faction, 1, "crisis_ally", q.id) end
            StoryEngine.Radio.react(o.faction, "event", "The players chose to help " .. nameOf(opt.faction)
                .. ", and that helps you too. The situation was: " .. (c and c.situation or "a crisis")
                .. " What " .. nameOf(opt.faction) .. " asked for: " .. tostring(opt.ask)
                .. ". React in character, relieved or grateful.",
                StoryEngine.Lines.fallback(o.faction, "crisis_thanks", "That helped us too. Thank you."), ps)
        elseif role == "spared" then
            -- 다른 쪽을 골랐지만 이 NPC 도 이해한다: 감점 없음
            st.flags[q.crisis .. "_spared"] = true
        else
            st.flags[q.crisis .. "_snubbed"] = true
            if Trust then Trust.apply(o.faction, -2, "crisis_snubbed", q.id, ps.key) end
            StoryEngine.Radio.react(o.faction, "event", "The players chose to help " .. nameOf(opt.faction)
                .. " instead of you. The situation was: " .. (c and c.situation or "a crisis")
                .. " React in character: how hurt, angry or understanding you are depends on how much you trust them.",
                StoryEngine.Lines.fallback(o.faction, "crisis_snub", "So you went with them. I see."), ps)
        end
    end
    -- NPC 사이 관계: 선택받은 쪽과 외면당한 쪽이 서로 조금 틀어진다 (Bonds)
    if StoryEngine.Bonds then
        for _, o in ipairs(q.options) do
            local role = Stories.crisisRole(q.crisis, opt.faction, o.faction)
            if role == "snubbed" then
                StoryEngine.Bonds.change(o.faction, opt.faction, -1, "the players chose to help " .. nameOf(opt.faction)
                    .. " over " .. nameOf(o.faction) .. " in a crisis", true)
            elseif role == "ally" then
                StoryEngine.Bonds.change(o.faction, opt.faction, 1, nameOf(opt.faction) .. " stepped in to help "
                    .. nameOf(o.faction) .. " in a crisis", false)
            end
        end
    end
    -- 고른 세력의 부탁이 퀘스트가 된다 (바로 수락)
    local fq = StoryEngine.Quests.proposeCustom(player, ps, opt.faction,
        { tier = opt.tier, why = opt.ask, items = opt.items }, now, { crisis = q.crisis, silent = true })
    if fq then StoryEngine.Quests.respond(player, fq.id, true) end
    if StoryEngine.Life then
        local ok, err = pcall(StoryEngine.Life.onCrisis, q, opt.faction, ps.name)
        if not ok then log("life crisis error:", err) end
    end
    for _, f in ipairs(Factions.list) do
        local involved = false
        for _, o in ipairs(q.options) do if o.faction == f.id then involved = true end end
        if not involved then
            Social.news(f.id, "When " .. (c and c.situation or "a crisis hit") .. " the players sided with "
                .. nameOf(opt.faction) .. ".")
        end
    end
    log("crisis chosen", q.crisis, opt.faction, "by", ps.name)
end

function Social.onChoiceIgnored(q)
    local Trust = StoryEngine.Trust
    for _, o in ipairs(q.options or {}) do
        Social.story(o.faction).flags[q.crisis .. "_ignored"] = true
        if StoryEngine.Chronicle then
            StoryEngine.Chronicle.add(o.faction, { k = "crisis", crisis = q.crisis, role = "ignored" })
        end
        if Trust then Trust.apply(o.faction, -1, "crisis_ignored", q.id) end
        StoryEngine.Radio.react(o.faction, "event", "Nobody answered when you asked for help: "
            .. tostring(q.situation) .. " React in character, briefly.",
            StoryEngine.Lines.fallback(o.faction, "crisis_ignored", "Nobody answered. Fine."), nil)
    end
    log("crisis ignored", q.crisis)
end

-- ---------------------------------------------------------------- contacts

local function timely(fid, hour, s, now)
    if s.stormT and now.t - s.stormT < 6 * 60 and (fid == "guard" or fid == "casey") then
        return 6, "A storm is coming. Warn them to get inside and secure things.", "chat_storm"
    end
    if hour >= 6 and hour < 9 and (fid == "casey" or fid == "ray") then
        local cm = getClimateManager()
        local sky = {}
        if cm:isRaining() then sky[#sky + 1] = "raining" end
        if cm:getFogIntensity() > 0.3 then sky[#sky + 1] = "foggy" end
        local temp = math.floor(cm:getTemperature())
        return 4, "It is morning. Give them a quick weather and morning report the way you would ("
            .. (#sky > 0 and table.concat(sky, ", ") or "clear") .. ", about " .. StoryEngine.intToString(temp)
            .. " degrees Celsius) and ask about their plans.", "chat_morning"
    end
    if hour >= 20 and hour < 23 and (fid == "ray" or fid == "pike" or fid == "casey") then
        return 3, "It is getting dark. Check in with them before night falls.", "chat_evening"
    end
    return 0, nil
end

-- (fid, 가중치, 이유, 주제) 후보를 모아 하나 고른다
function Social.pickContact(now)
    local s = state()
    local hour = getGameTime():getHour()
    local cands, total = {}, 0
    local function add(fid, w, reason, topic, extra, line)
        w = w * (Stories.TALKATIVE[fid] or 1)
        if w <= 0 then return end
        cands[#cands + 1] = { fid = fid, w = w, reason = reason, topic = topic, extra = extra, line = line }
        total = total + w
    end
    for _, f in ipairs(Factions.list) do
        local fid = f.id
        local ch = Radio.channel(fid)
        if not Factions.isGone(fid) and not Radio.busy[fid]
            and not (ch.lastChatT and now.t - ch.lastChatT < Social.NPC_GAP_MIN) then
            local st = Social.story(fid)
            local node = Stories.node(fid, st.node)
            if node and not st.told and not node.quest then
                add(fid, 10, "story", "Tell them what has been happening in your life lately: " .. node.beat, nil, node.id)
            end
            local news = freshNews(fid, now)
            if #news > 0 then
                local n = news[#news]
                add(fid, 6, "news", "You heard something and want to talk about it: " .. n.text
                    .. " Call them about it the way you would (ask, worry, tease or warn).", n)
            end
            local w, topic, line = timely(fid, hour, s, now)
            if w > 0 then add(fid, w, "timely", topic, nil, line) end
            if not ch.lastPlayerT or now.t - ch.lastPlayerT > Social.SILENT_MIN then
                add(fid, 3, "miss", "You have not heard from them in days. Check that they are alive and how they are doing.")
            end
            local rel = Stories.relationsOf(fid)
            local others = {}
            for other, _ in pairs(rel) do
                if not Factions.isGone(other) then others[#others + 1] = other end   -- 떠난 사람의 "요즘 사정"은 없다 (점검 D4)
            end
            if #others > 0 then
                local other = others[ZombRand(#others) + 1]
                local ost = Social.story(other)
                local onode = Stories.node(other, ost.node)
                add(fid, 2, "gossip", "Talk about " .. nameOf(other) .. " (" .. rel[other] .. ")."
                    .. (onode and (' What you have heard of their situation lately, in their own words ("you" means them): '
                        .. onode.beat) or ""))
            end
            add(fid, 1, "checkin", "You are just calling to talk: your day, the weather, how they are holding up.")
        end
    end
    if total <= 0 then return nil end
    local roll = ZombRandFloat(0, total)
    for _, c in ipairs(cands) do
        roll = roll - c.w
        if roll <= 0 then return c end
    end
    return cands[#cands]
end

-- AI 없이 쓰는 먼저 거는 말 (Lines.lua): 이야기는 그 장면을 직접 말하고, 나머지는 이유별 잡담.
-- 소문·다른 NPC 이야기는 내용을 번역할 수 없어서 안부로 대신한다
Social.CONTACT_LINES = { miss = "chat_miss", checkin = "chat_checkin", news = "chat_checkin", gossip = "chat_checkin" }

function Social.contactFallback(c)
    local Lines = StoryEngine.Lines
    if c.reason == "story" and c.line then
        -- AI 곁가지 장면은 번역 키가 없고 그 NPC 의 말을 그대로 저장해 둔다 (AiTales.lua)
        local node = Stories.node(c.fid, c.line)
        if node and node.say then return { text = node.say } end
        return { text = c.topic, lt = Lines.story(c.line) }
    end
    local kind = (c.reason == "timely" and c.line) or Social.CONTACT_LINES[c.reason] or "chat_checkin"
    return Lines.fallback(c.fid, kind, "Just checking in.")
end

function Social.contact(c, now)
    local ch = Radio.channel(c.fid)
    ch.lastChatT = now.t
    if c.reason == "story" then Social.story(c.fid).told = true end
    if c.reason == "news" and c.extra then
        local s = state()
        local kept = {}
        for _, n in ipairs(s.news[c.fid] or {}) do
            if n ~= c.extra then kept[#kept + 1] = n end
        end
        s.news[c.fid] = kept
    end
    local _, ps = randomTarget()
    log("npc contact", c.fid, c.reason)
    StoryEngine.Radio.react(c.fid, "chat", c.topic, Social.contactFallback(c), ps)
end

-- ---------------------------------------------------------------- open channel

local function openLog()
    local ch = Radio.channel(Social.OPEN)
    local out = {}
    for i = math.max(1, #ch.messages - Social.SCENE_LOG + 1), #ch.messages do
        local m = ch.messages[i]
        if m.from == "player" or m.from == "npc" then
            out[#out + 1] = { from = m.from, npc = m.npc, name = m.name, clock = m.clock, text = m.text }
        end
    end
    return out
end

local function pickParticipants(count, prefer)
    local chosen, used = {}, {}
    if prefer then
        chosen[1], used[prefer] = prefer, true
    end
    while #chosen < count do
        local total, pool = 0, {}
        for _, f in ipairs(Factions.list) do
            if not used[f.id] and not Factions.isGone(f.id) then
                local w = Stories.TALKATIVE[f.id] or 1
                pool[#pool + 1] = { id = f.id, w = w }
                total = total + w
            end
        end
        if #pool == 0 then break end
        local roll = ZombRandFloat(0, total)
        local pick = pool[#pool].id
        for _, it in ipairs(pool) do
            roll = roll - it.w
            if roll <= 0 then pick = it.id; break end
        end
        chosen[#chosen + 1], used[pick] = pick, true
    end
    return chosen
end

-- 다음 예약 장면의 참가자와 주제를 정해 둔다 (NpcEvents: 나눔, 충돌, World, Holiday).
-- key = AI 가 없을 때 쓰는 준비된 대화 화제 (Social.OFFLINE_TOPICS), arg = 그 대사의 두 번째 인자 (lt arg)
function Social.queueTopic(ids, topic, key, arg)
    state().queuedTopic = { ids = ids, topic = string.sub(tostring(topic), 1, 400), key = key, arg = arg }
end

-- ---------------------------------------------------------------- AI 없는 공용 주파수 (2026-10-05)
-- 브릿지가 없으면 준비된 대사로 짧은 대화를 만든다.
--   예약 장면: 화제(사건)가 있으면 A 가 그 이야기를 꺼내고(topic_<화제>) B 가 받고(topic_reply),
--             없으면 두 사람 사이(Bonds: 좋음 warm / 보통 plain /나쁨 cold)에 맞는 세 줄 (duo_<사이>_open/reply/close)
--   플레이어 발언: 말에 든 낱말로 종류를 골라(도움·거래·감사·소식·인사) 첫 사람이 그 대답(player_<종류>), 다음 사람이 짧은 대답
Social.OFFLINE_TOPICS = { storm = true, heli = true, death = true, power = true, water = true, winter = true,
                          share = true, clash = true, holiday = true }
Social.OFFLINE_RECENT_MIN = 24 * 60
-- 플레이어 말의 종류: 클라이언트가 자기 언어의 낱말로 고른 것(intent)을 먼저, 없으면 영어 낱말 (Lines.intentOf)
function Social.classifySaid(text, intent)
    if intent and StoryEngine.Lines.INTENT_KINDS[intent] then return intent end
    return StoryEngine.Lines.intentOf(text)
end

local function moodOf(a, b)
    local v = StoryEngine.Bonds and StoryEngine.Bonds.get(a, b) or 0
    if v >= 1 then return "warm" end
    if v <= -1 then return "cold" end
    return "plain"
end

-- 지금 이야깃거리 (화제, lt 인자). 최근 하루의 죽음·헬기·폭풍, 아니면 단전·단수·겨울. 없으면 nil
function Social.offlineTopic()
    local s = state()
    local now = Sensor.now().t
    local recent = Social.OFFLINE_RECENT_MIN
    if ZombRand(100) < 70 then
        if s.deathT and now - s.deathT < recent then return "death", { t = "s", v = s.deathName } end
        if s.heliT and now - s.heliT < recent then return "heli" end
        if s.stormT and now - s.stormT < recent then return "storm" end
    end
    local World = StoryEngine.World
    if World and ZombRand(100) < 30 then
        local list = {}
        if World.powerOff() then list[#list + 1] = "power" end
        if World.waterOff() then list[#list + 1] = "water" end
        if World.isWinter() then list[#list + 1] = "winter" end
        if #list > 0 then return list[ZombRand(#list) + 1] end
    end
    return nil
end

function Social.offlineLines(ids, said, key, arg)
    local Lines = StoryEngine.Lines
    local a, b = ids[1], ids[2]
    local function line(fid, kind, args)
        return { npc = fid, text = "(prepared line, no AI)", lt = Lines.lt(fid, kind, args), quiet = true }
    end
    local function npcArg(fid) return { t = "npc", v = fid } end
    if said then
        local kind = Social.classifySaid(said.text, said.intent)
        local out = { line(a, kind and ("player_" .. kind) or "open_reply", { { t = "s", v = said.name } }) }
        if b then out[2] = line(b, "open_reply", { { t = "s", v = said.name } }) end
        return out, kind or "reply"
    end
    if not b then return { line(a, "open_chat") }, "chat" end
    if not (key and Social.OFFLINE_TOPICS[key]) then key, arg = Social.offlineTopic() end
    if key and Lines.has(a, "topic_" .. key) then
        return { line(a, "topic_" .. key, { npcArg(b), arg }), line(b, "topic_reply", { npcArg(a) }) }, key
    end
    local ma, mb = moodOf(a, b), moodOf(b, a)
    return { line(a, "duo_" .. ma .. "_open", { npcArg(b) }), line(b, "duo_" .. mb .. "_reply", { npcArg(a) }),
             line(a, "duo_" .. ma .. "_close", { npcArg(b) }) }, ma
end

function Social.crisesUsedTable()
    return state().crisesUsed
end

-- 장면의 주제 (플레이어가 말하지 않았을 때)
local function sceneTopic(ids)
    local a, b = ids[1], ids[2]
    local roll = ZombRand(100)
    local relA = Stories.relationsOf(a)
    if roll < 35 and relA[b] then
        return nameOf(a) .. " and " .. nameOf(b) .. " get talking; " .. nameOf(a) .. " feels this way about "
            .. nameOf(b) .. ": " .. relA[b] .. "."
    end
    local news = freshNews(a, Sensor.now())
    if roll < 60 and #news > 0 then
        return "They talk about the news going around: " .. news[#news].text
    end
    if roll < 85 then
        return "They catch up on how each of them is doing, each mentioning what is going on in their own life."
    end
    return "Evening chatter on the open channel: the weather, supplies, the dead, and old times before the outbreak."
end

-- 장면의 다음 줄을 공용 주파수에 내보낸다. 남은 줄이 없으면 장면 끝
local function releaseLine(s, now)
    local p = s.pending
    if not p then return end
    local l = table.remove(p.lines, 1)
    if l then
        Radio.push(Social.OPEN, { from = "npc", npc = l.npc, text = l.text, lt = l.lt, quiet = l.quiet,
                                  clock = now.clock, day = Store.dayIndex(now.dayKey) })
    end
    if #p.lines == 0 then
        s.pending = nil
    else
        p.nextT = now.t + rand(p.gap or Social.SCENE_LINE_GAP)
    end
end

-- 게임 내 1분마다: 기다리던 줄을 내보낸다 (접속자가 없으면 멈춤)
Social.REPLY_SCENE_GAP = 5      -- 플레이어 발언 반응 장면 최소 간격 (게임 분)

function Social.release()
    local s = state()
    -- 미뤄 둔 플레이어 발언 반응 장면 (Social.REPLY_SCENE_GAP)
    if Social.sceneAgain and not Social.sceneBusy then
        local again = Social.sceneAgain
        local last = Social.lastReplyT
        if not last or Sensor.now().t - last >= Social.REPLY_SCENE_GAP then
            Social.sceneAgain = nil
            Social.scene(again.said, again.cut)
        end
    end
    if not s.pending or #Sensor.players() == 0 then return end
    local now = Sensor.now()
    if now.t >= (s.pending.nextT or 0) then releaseLine(s, now) end
end

-- 공용 주파수 장면. said = { name, text } 이면 플레이어의 말에 반응한다.
-- cut = 플레이어가 끼어들어 끊긴 대화의 주제 (AI 에게 알려 준다)
function Social.scene(said, cut)
    if StoryEngine.Saga and StoryEngine.Saga.radioDown("open") then return false end   -- 통신 두절 (Saga.lua)
    if Social.sceneBusy then
        if said then Social.sceneAgain = { said = said, cut = cut } end
        return false
    end
    if #Sensor.players() == 0 then return false end
    -- 플레이어 발언 반응은 게임 몇 분에 한 번으로 묶는다 (AI 호출 비용, 2026-10-03 점검). 그 사이 말은 기록에 남고 다음 장면이 함께 반응
    if said then
        local now = Sensor.now().t
        if Social.lastReplyT and now - Social.lastReplyT < Social.REPLY_SCENE_GAP then
            Social.sceneAgain = { said = said, cut = cut }
            return false
        end
        Social.lastReplyT = now
    end
    Social.sceneBusy = true
    local count = 2 + ZombRand(2)
    local ids = pickParticipants(count, nil)
    -- 정해 둔 화제가 있으면 (나눔·충돌) 그 사람들이 그 이야기를 한다
    local queued, queuedKey, queuedArg = nil, nil, nil
    local qt = state().queuedTopic
    if not said and qt then
        state().queuedTopic = nil
        local okIds = true
        for _, id in ipairs(qt.ids or {}) do
            if Factions.isGone(id) then okIds = false end
        end
        if okIds and #(qt.ids or {}) >= 2 then
            ids = {}
            for _, id in ipairs(qt.ids) do ids[#ids + 1] = id end
            queued, queuedKey, queuedArg = qt.topic, qt.key, qt.arg
        end
    end
    local parts = {}
    for _, fid in ipairs(ids) do
        local ctx = Social.context(fid) or {}
        local rel = {}
        local Bonds = StoryEngine.Bonds
        for _, other in ipairs(ids) do
            local note = Stories.relationsOf(fid)[other]
            local bond = Bonds and Bonds.get(fid, other) or 0
            local recent = Bonds and Bonds.recent(fid, other) or nil
            if other ~= fid and (note or bond ~= 0 or recent) then
                rel[#rel + 1] = { id = other, note = note, bond = bond, shift = recent and recent.text or nil }
            end
        end
        local life = StoryEngine.Life and StoryEngine.Life.npc(fid).res or nil
        local spec = nil
        if said and StoryEngine.Specialty then
            local okSp, st = pcall(StoryEngine.Specialty.status, fid)
            if okSp then spec = st end
        end
        parts[#parts + 1] = { id = fid, trust = Radio.channel(fid).trust, beat = ctx.beat, relations = rel, state = life,
                              specialty = spec }
    end
    local players = {}
    for _, p in ipairs(Sensor.players()) do players[#players + 1] = Store.characterName(p) end
    local now = Sensor.now()
    -- 플레이어가 말했으면 지금 거래할 수 있는 NPC 들(시장)을 함께 넘긴다. 물건을 청한 말이면 몇 명이 제안한다 (Trade.lua)
    local speakerPs = said and said.key and Store.data().players[said.key] or nil
    local speakerPlayer = nil
    for _, p in ipairs(speakerPs and Sensor.players() or {}) do
        if Store.playerKey(p) == said.key then speakerPlayer = p end
    end
    local market = nil
    if speakerPs and StoryEngine.Trade then
        local okM, m = pcall(StoryEngine.Trade.marketContext, speakerPs, speakerPlayer)
        if okM and m then market = m else log("market context error:", m) end
    end
    local payload = {
        lang = Radio.langFor(Social.OPEN), participants = parts, log = openLog(), players = players,
        said = said and { name = said.name, text = said.text, state = Radio.playerState(speakerPs) } or nil,
        topic = (not said) and (queued or sceneTopic(ids)) or nil, interrupted = cut,
        day = Store.dayIndex(now.dayKey), clock = now.clock, market = market,
    }
    log("open scene", said and "reply" or "scheduled", table.concat(ids, ","))
    Bridge.request("radio_scene", payload, function(res)
        Social.sceneBusy = false
        -- 만드는 동안 플레이어가 또 말했으면 이 장면은 버리고 그 말에 반응한다 (기록에 두 말이 모두 있다)
        if Social.sceneAgain then
            local again = Social.sceneAgain
            Social.sceneAgain = nil
            Social.scene(again.said, again.cut)
            return
        end
        local valid = {}
        for _, fid in ipairs(ids) do valid[fid] = true end
        for _, sl in ipairs(market and market.sellers or {}) do valid[sl.id] = true end
        local lines = res.ok and res.json and res.json.lines
        local queue = {}
        if type(lines) == "table" then
            for _, l in ipairs(lines) do
                if type(l) == "table" and valid[l.speaker] and type(l.text) == "string" and l.text ~= ""
                    and #queue < Social.MAX_SCENE_LINES then
                    queue[#queue + 1] = { npc = l.speaker, text = string.sub(l.text, 1, Radio.MAX_REPLY) }
                end
            end
        end
        if #queue == 0 and Radio.OFFLINE_ERRORS[tostring(res.error)] then
            -- AI 가 없으면 준비된 대사로 짧은 대화 (Social.offlineLines)
            local lines2, what = Social.offlineLines(ids, said, queuedKey, queuedArg)
            for _, l in ipairs(lines2) do queue[#queue + 1] = l end
            log("open scene offline", table.concat(ids, ","), tostring(what))
        end
        if #queue == 0 then
            log("open scene failed", tostring(res.error))
            return
        end
        -- 첫 줄은 바로, 나머지는 한 줄씩 (Social.release)
        local s = state()
        s.pending = {
            lines = queue,
            gap = said and Social.REPLY_LINE_GAP or Social.SCENE_LINE_GAP,
            topic = said and ("answering " .. tostring(said.name) .. ': "' .. string.sub(tostring(said.text), 1, 200) .. '"')
                or payload.topic,
        }
        releaseLine(s, Sensor.now())
        -- 거래 제안: 게임 규칙으로 다시 만들고, 고를 수 있는 퀘스트와 채널 안내 줄을 남긴다
        local offers = res.json and res.json.offers
        if speakerPs and market and market.sellers and type(offers) == "table" and #offers > 0 then
            local selling = res.json and res.json.selling ~= "none" and res.json.selling or nil
            local okO, deals = pcall(StoryEngine.Trade.marketOffers, speakerPs, offers, selling, speakerPlayer)
            if not okO then
                log("market offers error:", deals)
            elseif #deals > 0 then
                local t = Sensor.now()
                local q = StoryEngine.Quests.proposeMarket(speakerPs, deals, t)
                local list = {}
                for i, o in ipairs(deals) do
                    list[i] = { faction = o.faction, goods = o.goods, payCategory = o.payCategory, price = o.price }
                end
                Radio.push(Social.OPEN, { from = "system", clock = t.clock, quest = q.id, market = list,
                                          sell = q.selling or nil })
            end
        end
    end, { timeoutMs = 60000 })
    return true
end

-- 플레이어가 공용 주파수에서 말했다 (Radio.say). 아직 안 나간 줄은 버리고 그 말에 반응한다
function Social.onOpenSay(ps, text, intent)
    local s = state()
    local cut = nil
    if s.pending then
        cut = s.pending.topic
        log("open scene interrupted,", #s.pending.lines, "lines dropped")
        s.pending = nil
    end
    Social.scene({ name = ps.name, text = text, key = ps.key, intent = intent }, cut)
end

-- ---------------------------------------------------------------- ticks

function Social.tick()
    if not Social.enabled() then return end
    local now = Sensor.now()
    local s = state()
    if not s.nextContactT then s.nextContactT = now.t + rand({ 60, 180 }) end
    if not s.nextSceneT then s.nextSceneT = now.t + rand({ 120, 300 }) end
    if #Sensor.players() == 0 then return end
    if now.t >= s.nextContactT then
        local c = Social.pickContact(now)
        if c then Social.contact(c, now) end
        s.nextContactT = now.t + rand(Social.CONTACT_GAP)
    end
    if now.t >= s.nextSceneT and not Social.sceneBusy and not s.pending then
        Social.scene(nil)
        s.nextSceneT = now.t + rand(Social.SCENE_GAP)
    end
end

function Social.hourly()
    if not Social.enabled() then return end
    local now = Sensor.now()
    for _, f in ipairs(Factions.list) do
        local ok, err = pcall(Social.advance, f.id, now)
        if not ok then log("story advance error:", f.id, err) end
    end
    local okE, errE = pcall(Social.pickEpisode, now)
    if not okE then log("story episode error:", errE) end
    local s = state()
    if not s.nextCrisisT then s.nextCrisisT = now.t + Social.CRISIS_FIRST_DAYS * 24 * 60 end
    -- 파이크 안전이 바닥이면 교회 습격 위기를 앞당긴다 (NpcEvents)
    local NE = StoryEngine.NpcEvents
    if NE and #Sensor.players() > 0 and NE.raidDue(now, s) then
        local ok, why = Social.startCrisis(now, "raid")
        log("raid crisis brought forward", ok and "started" or tostring(why))
        if ok then s.nextCrisisT = now.t + rand(Social.CRISIS_GAP_DAYS) * 24 * 60 end
    end
    if now.t >= s.nextCrisisT and #Sensor.players() > 0 then
        local open = false
        for _, q in pairs(Store.data().quests) do
            if q.kind == "choice" and q.state == "proposed" then open = true end
        end
        if not open then
            local ok, why = Social.startCrisis(now)
            if not ok then log("crisis skipped", tostring(why)) end
        end
        s.nextCrisisT = now.t + rand(Social.CRISIS_GAP_DAYS) * 24 * 60
    end
end

-- 디버그
function Social.debugContact()
    local c = Social.pickContact(Sensor.now())
    if not c then return false, "no_candidate" end
    Social.contact(c, Sensor.now())
    return true, c.fid .. " " .. c.reason
end

function Social.debugStatus()
    local parts = {}
    for _, f in ipairs(Factions.list) do
        local st = Social.story(f.id)
        parts[#parts + 1] = f.id .. ":" .. tostring(st.node) .. (st.told and "" or "*")
    end
    return "stories " .. table.concat(parts, " ")
end

Events.EveryTenMinutes.Add(function()
    local ok, err = pcall(Social.tick)
    if not ok then log("social tick error:", err) end
end)
Events.EveryOneMinute.Add(function()
    local ok, err = pcall(Social.release)
    if not ok then log("social release error:", err) end
end)
Events.EveryHours.Add(function()
    local ok, err = pcall(Social.hourly)
    if not ok then log("social hourly error:", err) end
end)
if Sensor.listeners and Sensor.listeners.dayEnd then
    Sensor.listeners.dayEnd[#Sensor.listeners.dayEnd + 1] = function(player, ps, day)
        local ok, err = pcall(Social.onDayEnd, player, ps, day)
        if not ok then log("social day end error:", err) end
    end
end

return Social
