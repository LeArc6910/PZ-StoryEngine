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
Social.SCENE_LOG = 12
Social.MAX_SCENE_LINES = 6
Social.SCENE_LINE_GAP = { 20, 40 }       -- 공용 주파수 장면은 한 줄씩 이 간격으로 (게임 분), 사이에 끼어들 수 있다
Social.REPLY_LINE_GAP = { 8, 12 }        -- 플레이어에게 답하는 장면: 첫 줄은 바로, 나머지는 조금 빨리

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
    end
    ch.story.flags = ch.story.flags or {}
    ch.story.past = ch.story.past or {}
    return ch.story
end

local function resolveNext(nextSpec, flags)
    if type(nextSpec) ~= "table" then return nextSpec end
    for flag, id in pairs(nextSpec.flags or {}) do
        if flags[flag] then return id end
    end
    return nextSpec.default
end

function Social.moveTo(fid, id, now)
    local st = Social.story(fid)
    local cur = Stories.node(fid, st.node)
    local nxt = Stories.node(fid, id)
    if not nxt then return end
    if cur then Store.push(st.past, cur.beat, 4) end
    st.node, st.since, st.told, st.questId = id, now.t, false, nil
    log("story", fid, "->", id)
    if StoryEngine.Life then
        local ok, err = pcall(StoryEngine.Life.onBeat, fid, nxt)
        if not ok then log("life beat error:", err) end
    end
    if StoryEngine.Bonds then
        local ok, err = pcall(StoryEngine.Bonds.onBeat, nxt)
        if not ok then log("bond beat error:", err) end
    end
    if nxt.final and StoryEngine.Fate then
        local ok, err = pcall(StoryEngine.Fate.onStoryFinal, fid, nxt)
        if not ok then log("fate final error:", err) end
    end
end

-- 이 NPC 에게 답을 기다리거나 진행 중인 부탁이 있는가
local function openQuestFor(fid)
    for _, q in pairs(Store.data().quests) do
        if q.origin and q.origin.faction == fid and (q.kind == "deliver" or q.kind == "horde")
            and (q.state == "proposed" or q.state == "accepted") then
            return q
        end
    end
    return nil
end

function Social.advance(fid, now)
    if Factions.isGone(fid) then return end
    local st = Social.story(fid)
    local node = Stories.node(fid, st.node)
    if not node or node.final then return end
    if node.quest then
        if st.questId then return end
        if now.t - st.since < (node.days or 1) * 24 * 60 then return end
        if openQuestFor(fid) then return end
        local player, ps = randomTarget()
        if not player then return end
        local q = StoryEngine.Quests.proposeCustom(player, ps, fid, node.quest, now,
            { story = { faction = fid, node = node.id } })
        if q then
            st.questId, st.told = q.id, true    -- 부탁하는 무전이 곧 이야기다
            log("story quest", fid, node.id, q.id)
        end
        return
    end
    if now.t - st.since >= (node.days or 2) * 24 * 60 then
        Social.moveTo(fid, resolveNext(node.next, st.flags), now)
    end
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
        local note = (Stories.RELATIONS[fid] or {})[other]
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
    Social.news("all", "Word on the radio is that " .. tostring(name) .. ", one of the survivors you know of, died"
        .. (town and (" near " .. tostring(town)) or "") .. ".")
end

function Social.onHelicopter()
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
        local st = Social.story(tag.faction)
        if st.node ~= tag.node or outcome == "accepted" then return end
        local node = Stories.node(tag.faction, tag.node)
        if not node then return end
        if outcome == "completed" then
            if StoryEngine.Fate then StoryEngine.Fate.onStoryResult(tag.faction, true) end
            if StoryEngine.Projects then StoryEngine.Projects.onStoryWin(tag.faction, q.targetName) end
            Social.moveTo(tag.faction, node.win, now)
        elseif outcome == "failed" or outcome == "declined" or outcome == "ignored" then
            if StoryEngine.Fate then StoryEngine.Fate.onStoryResult(tag.faction, false) end
            Social.moveTo(tag.faction, node.lose, now)
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
        for other, rel in pairs(Stories.RELATIONS) do
            if other ~= fid and rel[fid] then
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
            if Factions.isGone(o.faction) then alive = false end
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
            .. ". They can only help one of you and will choose in their quest log.", nil, ps)
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
                .. ". React in character, relieved or grateful.", nil, ps)
        elseif role == "spared" then
            -- 다른 쪽을 골랐지만 이 NPC 도 이해한다: 감점 없음
            st.flags[q.crisis .. "_spared"] = true
        else
            st.flags[q.crisis .. "_snubbed"] = true
            if Trust then Trust.apply(o.faction, -2, "crisis_snubbed", q.id, ps.key) end
            StoryEngine.Radio.react(o.faction, "event", "The players chose to help " .. nameOf(opt.faction)
                .. " instead of you. The situation was: " .. (c and c.situation or "a crisis")
                .. " React in character: how hurt, angry or understanding you are depends on how much you trust them.",
                nil, ps)
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
        if Trust then Trust.apply(o.faction, -1, "crisis_ignored", q.id) end
        StoryEngine.Radio.react(o.faction, "event", "Nobody answered when you asked for help: "
            .. tostring(q.situation) .. " React in character, briefly.", nil, nil)
    end
    log("crisis ignored", q.crisis)
end

-- ---------------------------------------------------------------- contacts

local function timely(fid, hour, s, now)
    if s.stormT and now.t - s.stormT < 6 * 60 and (fid == "guard" or fid == "casey") then
        return 6, "A storm is coming. Warn them to get inside and secure things."
    end
    if hour >= 6 and hour < 9 and (fid == "casey" or fid == "ray") then
        local cm = getClimateManager()
        local sky = {}
        if cm:isRaining() then sky[#sky + 1] = "raining" end
        if cm:getFogIntensity() > 0.3 then sky[#sky + 1] = "foggy" end
        local temp = math.floor(cm:getTemperature())
        return 4, "It is morning. Give them a quick weather and morning report the way you would ("
            .. (#sky > 0 and table.concat(sky, ", ") or "clear") .. ", about " .. StoryEngine.intToString(temp)
            .. " degrees Celsius) and ask about their plans."
    end
    if hour >= 20 and hour < 23 and (fid == "ray" or fid == "pike" or fid == "casey") then
        return 3, "It is getting dark. Check in with them before night falls."
    end
    return 0, nil
end

-- (fid, 가중치, 이유, 주제) 후보를 모아 하나 고른다
function Social.pickContact(now)
    local s = state()
    local hour = getGameTime():getHour()
    local cands, total = {}, 0
    local function add(fid, w, reason, topic, extra)
        w = w * (Stories.TALKATIVE[fid] or 1)
        if w <= 0 then return end
        cands[#cands + 1] = { fid = fid, w = w, reason = reason, topic = topic, extra = extra }
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
                add(fid, 10, "story", "Tell them what has been happening in your life lately: " .. node.beat)
            end
            local news = freshNews(fid, now)
            if #news > 0 then
                local n = news[#news]
                add(fid, 6, "news", "You heard something and want to talk about it: " .. n.text
                    .. " Call them about it the way you would (ask, worry, tease or warn).", n)
            end
            local w, topic = timely(fid, hour, s, now)
            if w > 0 then add(fid, w, "timely", topic) end
            if not ch.lastPlayerT or now.t - ch.lastPlayerT > Social.SILENT_MIN then
                add(fid, 3, "miss", "You have not heard from them in days. Check that they are alive and how they are doing.")
            end
            local rel = Stories.RELATIONS[fid] or {}
            local others = {}
            for other, _ in pairs(rel) do others[#others + 1] = other end
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
    StoryEngine.Radio.react(c.fid, "chat", c.topic, nil, ps)
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

-- 다음 예약 장면의 참가자와 주제를 정해 둔다 (NpcEvents: 나눔, 충돌)
function Social.queueTopic(ids, topic)
    state().queuedTopic = { ids = ids, topic = string.sub(tostring(topic), 1, 400) }
end

function Social.crisesUsedTable()
    return state().crisesUsed
end

-- 장면의 주제 (플레이어가 말하지 않았을 때)
local function sceneTopic(ids)
    local a, b = ids[1], ids[2]
    local roll = ZombRand(100)
    local relA = Stories.RELATIONS[a] or {}
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
        Radio.push(Social.OPEN, { from = "npc", npc = l.npc, text = l.text,
                                  clock = now.clock, day = Store.dayIndex(now.dayKey) })
    end
    if #p.lines == 0 then
        s.pending = nil
    else
        p.nextT = now.t + rand(p.gap or Social.SCENE_LINE_GAP)
    end
end

-- 게임 내 1분마다: 기다리던 줄을 내보낸다 (접속자가 없으면 멈춤)
function Social.release()
    local s = state()
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
    Social.sceneBusy = true
    local count = 2 + ZombRand(2)
    local ids = pickParticipants(count, nil)
    -- 정해 둔 화제가 있으면 (나눔·충돌) 그 사람들이 그 이야기를 한다
    local queued = nil
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
            queued = qt.topic
        end
    end
    local parts = {}
    for _, fid in ipairs(ids) do
        local ctx = Social.context(fid) or {}
        local rel = {}
        local Bonds = StoryEngine.Bonds
        for _, other in ipairs(ids) do
            local note = (Stories.RELATIONS[fid] or {})[other]
            local bond = Bonds and Bonds.get(fid, other) or 0
            local recent = Bonds and Bonds.recent(fid, other) or nil
            if other ~= fid and (note or bond ~= 0 or recent) then
                rel[#rel + 1] = { id = other, note = note, bond = bond, shift = recent and recent.text or nil }
            end
        end
        local life = StoryEngine.Life and StoryEngine.Life.npc(fid).res or nil
        parts[#parts + 1] = { id = fid, trust = Radio.channel(fid).trust, beat = ctx.beat, relations = rel, state = life }
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
        said = said and { name = said.name, text = said.text } or nil,
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
        local offers = res.json.offers
        if speakerPs and market and market.sellers and type(offers) == "table" and #offers > 0 then
            local selling = res.json.selling ~= "none" and res.json.selling or nil
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
function Social.onOpenSay(ps, text)
    local s = state()
    local cut = nil
    if s.pending then
        cut = s.pending.topic
        log("open scene interrupted,", #s.pending.lines, "lines dropped")
        s.pending = nil
    end
    Social.scene({ name = ps.name, text = text, key = ps.key }, cut)
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
