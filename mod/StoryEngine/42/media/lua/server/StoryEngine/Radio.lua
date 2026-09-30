-- 무전 교신 (서버 측 전용). 세력별 채널에 대화가 쌓이고, 모든 접속자가 같은 채널을 공유한다.
--
-- 플레이어 발언 -> 채널 기록 + 전체 방송 -> 브릿지(radio 모듈)로 답장 요청 -> 답장 기록 + 방송.
-- 답장을 기다리는 동안 다른 발언이 오면 모아 두었다가 답장 직후 한 번 더 요청한다.
-- 이 단계에서 AI 출력이 게임에 주는 영향은 신뢰도 -3~+3 뿐이다.
--
-- 먼저 연락하기: AI 가 "알아보고 다시 연락하겠다"고 하면 follow_up_hours / follow_up_topic 을 함께 돌려준다.
-- 채널에 예약(ch.followUp)을 하나 저장해 두고, 게임 시간이 되면 mode = "follow_up" 으로 요청해 AI 가 먼저 말하게 한다.
-- 연쇄 예약은 MAX_CHAIN 번까지, 먼저 거는 연락은 채널당 하루 FOLLOW_UP_PER_DAY 번까지.

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Store"
require "StoryEngine/Bridge"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"

local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Bridge = StoryEngine.Bridge
local Factions = StoryEngine.Factions
local Net = StoryEngine.Net
local log = StoryEngine.log

local Radio = {
    busy = {},        -- factionId -> 답장 대기 중
    again = {},       -- factionId -> 대기 중에 새 발언이 옴
    lastSay = {},     -- playerKey -> ms
    hourly = {},      -- playerKey -> { ms, ... }
    queue = {},       -- factionId -> { opts, ... } 채널이 바쁠 때 기다리는 반응·부탁
    speaker = {},     -- factionId -> 마지막으로 말한 플레이어의 PlayerState (거래 한도 계산용)
}
StoryEngine.Radio = Radio

Radio.COOLDOWN_MS = 3000
Radio.PER_HOUR = 60
Radio.MAX_TEXT = 200
Radio.MAX_REPLY = 600
Radio.KEEP = 200          -- 채널당 보관 메시지 수
Radio.PROMPT_HISTORY = 16
Radio.CLIENT_HISTORY = 100
Radio.MAX_CHAIN = 2
Radio.FOLLOW_UP_PER_DAY = 4
Radio.MAX_FOLLOW_UP_HOURS = 24

local function channels()
    local d = Store.data()
    d.radio = d.radio or { channels = {} }
    return d.radio.channels
end

Radio.OPEN = "open"      -- 공용 주파수: 모든 NPC 가 듣고 말한다 (Social.scene). 신뢰도·거래 없음

function Radio.channel(fid)
    local all = channels()
    local ch = all[fid]
    if not ch then
        local f = Factions.byId[fid]
        local start = f and f.trust or 0
        -- 샌드박스 시작 신뢰도 보정 (새로 만드는 채널만, 공용 주파수 제외)
        if f and StoryEngine.Tuning then start = math.max(0, math.min(100, start + StoryEngine.Tuning.num("TrustStart"))) end
        ch = { messages = {}, trust = start, seq = 0 }
        all[fid] = ch
    end
    return ch
end

local function broadcast(command, args)
    for _, p in ipairs(Sensor.players()) do
        local ok, err = pcall(Net.toClient, p, command, args)
        if not ok then log("radio broadcast failed:", err) end
    end
end

-- 예약된 연락까지 남은 게임 시간(시간 단위). 없으면 nil
function Radio.followUpIn(ch)
    if not ch.followUp then return nil end
    return math.max(0, math.ceil((ch.followUp.dueT - Sensor.now().t) / 60))
end

-- 일지·회고록용 교신 기록. ps.radioLog = 지난 일기 이후 (Journal 이 가져가고 비움),
-- ps.radioLife = 평생 최근 것 (회고록용). 줄마다 { clock, day, faction, from = "player" | "npc", text }
Radio.LOG_MAX = 30
Radio.LIFE_MAX = 60
Radio.LOG_TEXT = 220

function Radio.logLine(ps, fid, from, text, clock, day)
    if not ps or type(text) ~= "string" or text == "" then return end
    local line = { clock = clock, day = day, faction = fid, from = from, text = string.sub(text, 1, Radio.LOG_TEXT) }
    ps.radioLog = ps.radioLog or {}
    ps.radioLife = ps.radioLife or {}
    Store.push(ps.radioLog, line, Radio.LOG_MAX)
    Store.push(ps.radioLife, line, Radio.LIFE_MAX)
end

-- audience: 이 줄을 들은 사람 (ps). 없으면 NPC 가 먼저 한 말로 보고 접속한 모든 플레이어가 들은 것으로 남긴다.
local function push(fid, msg, audience)
    local ch = Radio.channel(fid)
    if not msg.day then msg.day = Store.dayIndex(Sensor.now().dayKey) end
    ch.seq = ch.seq + 1
    msg.n = ch.seq
    Store.push(ch.messages, msg, Radio.KEEP)
    if msg.from == "npc" and type(msg.text) == "string" then
        local who = msg.npc or fid       -- 공용 주파수에서는 말한 NPC
        if audience then
            Radio.logLine(audience, who, "npc", msg.text, msg.clock, msg.day)
        else
            for _, p in ipairs(Sensor.players()) do
                Radio.logLine(Store.player(p), who, "npc", msg.text, msg.clock, msg.day)
            end
        end
    end
    broadcast("radioMessage", { faction = fid, msg = msg, trust = ch.trust, followUpIn = Radio.followUpIn(ch) })
end
Radio.push = push   -- 퀘스트 소식 등 모드가 직접 보내는 세력 메시지

local function trim(s)
    return (string.gsub(string.gsub(s, "^%s+", ""), "%s+$", ""))
end

local function rateLimited(key)
    local now = StoryEngine.nowMs()
    if Radio.lastSay[key] and now - Radio.lastSay[key] < Radio.COOLDOWN_MS then return "cooldown" end
    local list = Radio.hourly[key] or {}
    local kept = {}
    for _, t in ipairs(list) do
        if now - t < 3600000 then kept[#kept + 1] = t end
    end
    if #kept >= Radio.PER_HOUR then
        Radio.hourly[key] = kept
        return "rate_limited"
    end
    kept[#kept + 1] = now
    Radio.hourly[key] = kept
    Radio.lastSay[key] = now
    return nil
end

-- opts: nil (플레이어 발언에 답장)
--     | { mode = "follow_up", topic, chain, retried }       약속한 연락 (예약)
--     | { mode = "event" | "request", topic, fallback }     퀘스트 결과에 대한 반응 / NPC 의 부탁
-- AI 가 먼저 거는 연락(mode 가 있는 것)은 실패해도 잡음을 남기지 않는다.
-- event / request 는 채널이 바쁘면 대기열에 넣었다가 지금 답장이 끝나면 보낸다.
function Radio.request(fid, lang, opts)
    -- 죽었거나 떠난 NPC 는 말하지 않는다 (Fate.lua)
    if Factions.isGone(fid) then return false end
    lang = lang or Radio.langFor(fid)
    local mode = opts and opts.mode or nil
    -- 플레이어 발언에 대한 답장에서만 거래를 다룬다 (B단계, Trade.lua)
    local speaker = (not mode) and Radio.speaker[fid] or nil
    local Trade = StoryEngine.Trade
    local trade = { allowed = false, reason = "not_now" }
    if speaker and Trade then
        local ok, ctx = pcall(Trade.context, fid, speaker)
        if ok and ctx then trade = ctx end
    end
    local followUp = mode == "follow_up"
    if Radio.busy[fid] then
        if not mode then
            Radio.again[fid] = true
        elseif not followUp then
            local list = Radio.queue[fid] or {}
            list[#list + 1] = opts
            Radio.queue[fid] = list
        end
        return false
    end
    Radio.busy[fid] = true
    local ch = Radio.channel(fid)
    local now = Sensor.now()
    local history = {}
    for i = math.max(1, #ch.messages - Radio.PROMPT_HISTORY + 1), #ch.messages do
        local m = ch.messages[i]
        if m.from == "player" or m.from == "npc" then
            history[#history + 1] = { from = m.from, name = m.name, clock = m.clock, text = m.text,
                                      auto = m.lt ~= nil or nil }
        end
    end
    local players = {}
    for _, p in ipairs(Sensor.players()) do players[#players + 1] = Store.characterName(p) end
    ch.lang = lang

    -- 이 NPC 의 이야기·다른 NPC 에 대한 생각·들은 소식 (Social.lua)
    local story = nil
    if StoryEngine.Social then
        local okS, ctx = pcall(StoryEngine.Social.context, fid)
        if okS then story = ctx end
    end

    -- 이 NPC 의 형편(생활 자원), 플레이어들과 있었던 일, 평판 (Life.lua)
    local life = nil
    if StoryEngine.Life then
        local okL, ctx = pcall(StoryEngine.Life.context, fid)
        if okL then life = ctx end
    end

    -- 이 NPC 에게 처음 말을 거는 캐릭터면: 함께 다니는 사람들과 최근 죽은 사람들 (Legacy.lua)
    local newcomer = nil
    if speaker and StoryEngine.Legacy then
        local okN, info = pcall(StoryEngine.Legacy.newcomer, fid, speaker)
        if okN then newcomer = info end
    end

    Bridge.request("radio", {
        story = story, life = life, newcomer = newcomer,
        faction = fid, lang = lang, trust = ch.trust, memory = ch.memory,
        day = Store.dayIndex(now.dayKey), date = now.date, clock = now.clock,
        players = players, history = history,
        mode = mode, topic = mode and opts.topic or nil, trade = trade,
    }, function(res)
        Radio.busy[fid] = false
        local t = Sensor.now()
        local json = res.ok and res.json or nil
        if type(json) == "table" and type(json.reply) == "string" and json.reply ~= "" then
            -- 대화만으로는 신뢰도가 조금만 움직인다 (-1~+1). 큰 변화는 퀘스트 결과로 (Trust.lua).
            local change = math.max(-1, math.min(1, math.floor(tonumber(json.trust_change) or 0)))
            ch.trust = math.max(0, math.min(100, ch.trust + change))
            if change < 0 and speaker then
                ch.lastOffender = speaker.key
                if StoryEngine.Life then pcall(StoryEngine.Life.record, fid, "insult", speaker.name, change) end
            end

            -- 다시 연락 예약. 약속한 연락과 플레이어 발언에 대한 답장에서만 받는다.
            -- 답장을 방송하기 전에 정해 두어야 남은 시간이 클라이언트에 같이 간다.
            local hours = math.floor(tonumber(json.follow_up_hours) or 0)
            local topic = type(json.follow_up_topic) == "string" and string.sub(json.follow_up_topic, 1, 200) or ""
            local chain = followUp and (opts.chain or 1) or 0
            if followUp then ch.followUp = nil end
            if (not mode or followUp) and hours > 0 and topic ~= "" and chain < Radio.MAX_CHAIN then
                hours = math.min(hours, Radio.MAX_FOLLOW_UP_HOURS)
                ch.followUp = { dueT = t.t + hours * 60, topic = topic, chain = chain + 1, lang = lang }
                log("radio follow-up scheduled", fid, hours .. "h", topic)
            end

            -- 플레이어 발언에 대한 답장은 말한 사람의 기록에, NPC 가 먼저 한 말은 접속한 모두의 기록에
            push(fid, { from = "npc", text = string.sub(json.reply, 1, Radio.MAX_REPLY), clock = t.clock,
                        day = Store.dayIndex(t.dayKey), followUp = followUp or nil }, (not mode) and speaker or nil)
            if opts and opts.overhead then Radio.overhead(opts.overhead, fid, string.sub(json.reply, 1, Radio.MAX_REPLY)) end
            -- 곁의 동료와 방금 들은 말을 두고 대화
            if not mode and speaker and StoryEngine.Banter then
                local okB, errB = pcall(StoryEngine.Banter.onRadio, speaker, fid, json.reply)
                if not okB then log("banter radio error:", errB) end
            end

            -- 거래 제안: 게임 규칙으로 다시 검증한 뒤 퀘스트로 만들고, 대화 기록에 조건을 남긴다
            local action = speaker and Trade and type(json.trade) == "table" and json.trade.action or nil
            if trade.negotiating then
                -- 답을 기다리는 제안에 대한 흥정: 조건 변경 또는 제안 철회
                if action == "counter" or action == "withdraw" then
                    local ok, q, how = pcall(Trade.negotiate, fid, speaker, json.trade)
                    if not ok then
                        log("trade haggle error:", q)
                    elseif q and how == "counter" then
                        push(fid, { from = "system", clock = t.clock, quest = q.id, revised = {
                            goods = q.goods, payCategory = q.payCategory, price = q.price,
                            oldPrice = q.oldPrice, oldPayCategory = q.oldPayCategory } })
                    elseif q and how == "withdraw" then
                        push(fid, { from = "system", clock = t.clock, quest = q.id, withdrawn = true })
                    end
                end
            elseif action == "offer" or action == "refuse" or action == "gift" then
                -- 물건을 청한 것으로 센다 (너무 잦으면 의심)
                local okR, errR = pcall(Trade.recordRequest, fid, speaker)
                if not okR then log("trade request count error:", errR) end
                local ok, deal, how, info
                if action == "refuse" then
                    -- 신뢰도 한도 때문에 거절했으면 무엇이 얼마나 모자란지 알린다
                    ok, info = pcall(Trade.blocked, fid, json.trade.category, json.trade.tier)
                    how = ok and info and "blocked" or nil
                else
                    ok, deal, how, info = pcall(Trade.fromReply, fid, speaker, json.trade)
                end
                if not ok then
                    log("trade error:", deal or info)
                elseif deal and how == "gift" then
                    push(fid, { from = "system", clock = t.clock, quest = deal.id, gift = { goods = deal.items } })
                elseif deal then
                    push(fid, { from = "system", clock = t.clock, quest = deal.id,
                                offer = { goods = deal.goods, payCategory = deal.payCategory, price = deal.price } })
                elseif how == "blocked" and info then
                    push(fid, { from = "system", clock = t.clock, blocked = info })
                end
            end
        elseif followUp then
            -- 약속한 연락이 실패하면 한 시간 뒤 한 번만 다시 시도한다
            log("radio follow-up failed:", fid, tostring(res.error))
            if not opts.retried then
                ch.followUp = { dueT = t.t + 60, topic = opts.topic, chain = opts.chain, lang = lang, retried = true }
            end
        elseif mode then
            -- 부탁처럼 꼭 전해야 하는 말은 준비된 문장으로 대신 보낸다
            log("radio " .. mode .. " failed:", fid, tostring(res.error))
            local fb = opts.fallback
            if type(fb) == "table" then
                push(fid, { from = "npc", text = fb.text, lt = fb.lt, clock = t.clock, day = Store.dayIndex(t.dayKey) })
                if opts.overhead then Radio.overhead(opts.overhead, fid, fb.text, fb.lt) end
            elseif fb then
                push(fid, { from = "npc", text = fb, clock = t.clock, day = Store.dayIndex(t.dayKey) })
                if opts.overhead then Radio.overhead(opts.overhead, fid, fb) end
            end
        else
            log("radio reply failed:", fid, tostring(res.error))
            push(fid, { from = "static", error = res.error or "bad_reply", clock = t.clock,
                        day = Store.dayIndex(t.dayKey) })
        end
        if Radio.again[fid] then
            Radio.again[fid] = false
            Radio.request(fid, lang)
        elseif Radio.queue[fid] and #Radio.queue[fid] > 0 then
            local nextOpts = table.remove(Radio.queue[fid], 1)
            Radio.request(fid, lang, nextOpts)
        end
    end, { timeoutMs = 60000 })
    return true
end

-- NPC 가 말할 언어. 대상 플레이어 > 이 채널에서 마지막으로 말한 사람 > 접속자 > 게임 언어 순.
-- (아무도 말한 적 없는 채널에서 NPC 가 먼저 말하면 영어로 나오던 문제, 42.20.4 확인)
function Radio.langFor(fid, ps)
    if ps and ps.lang then return ps.lang end
    for _, p in ipairs(Sensor.players()) do
        local lang = Store.player(p).lang
        if lang then return lang end
    end
    local ch = Radio.channel(fid)
    if ch.lang then return ch.lang end
    local ok, name = pcall(function() return tostring(Translator.getLanguage():name()) end)
    return ok and name or "EN"
end

-- NPC 가 먼저 말하게 한다. mode: "event" (일어난 일에 반응) | "request" (부탁)
-- topic 은 AI 에게 넘기는 상황 설명(영어), fallback 은 AI 가 실패했을 때 대신 보낼 문장
-- ({ text = AI 기록용 영어, lt = 클라이언트가 번역할 문장 }), ps 는 대상 플레이어.
-- extra.overhead: 그 말을 대상 플레이어 머리 위에도 띄운다 (특기 지원 답장, 2026-09-30)
function Radio.react(fid, mode, topic, fallback, ps, extra)
    if not Factions.byId[fid] then return end
    Radio.request(fid, Radio.langFor(fid, ps), { mode = mode, topic = topic, fallback = fallback,
        overhead = (extra and extra.overhead and ps) and ps.key or nil })
end

-- NPC 가 한 말을 그 플레이어 머리 위에도 (접속해 있을 때만)
function Radio.overhead(key, fid, text, lt)
    if not key then return end
    for _, p in ipairs(Sensor.players()) do
        if Store.player(p).key == key then
            local ok, err = pcall(Net.toClient, p, "radioOverhead", { faction = fid, text = text, lt = lt })
            if not ok then log("radio overhead failed:", err) end
            return
        end
    end
end

-- 예약 시각이 된 연락을 보낸다 (게임 내 10분마다)
function Radio.checkFollowUps()
    if #Sensor.players() == 0 then return end
    local now = Sensor.now()
    for _, f in ipairs(Factions.list) do
        local ch = Radio.channel(f.id)
        local fu = ch.followUp
        if fu and now.t >= fu.dueT and not Radio.busy[f.id] then
            if ch.followUpDay ~= now.dayKey then
                ch.followUpDay = now.dayKey
                ch.followUpCount = 0
            end
            if (ch.followUpCount or 0) >= Radio.FOLLOW_UP_PER_DAY then
                ch.followUp = nil
                log("radio follow-up dropped (daily cap)", f.id)
            else
                ch.followUpCount = (ch.followUpCount or 0) + 1
                log("radio follow-up firing", f.id, fu.topic)
                Radio.request(f.id, fu.lang or Radio.langFor(f.id),
                    { mode = "follow_up", topic = fu.topic, chain = fu.chain, retried = fu.retried })
            end
        end
    end
end

Events.EveryTenMinutes.Add(function()
    local ok, err = pcall(Radio.checkFollowUps)
    if not ok then log("radio follow-up error:", err) end
end)

-- 플레이어 발언. 성공하면 true, 실패하면 false, 오류 코드
function Radio.say(player, fid, text)
    if not Factions.byId[fid] and fid ~= Radio.OPEN then return false, "unknown_faction" end
    text = trim(string.sub(tostring(text or ""), 1, Radio.MAX_TEXT))
    if text == "" then return false, "empty" end
    if not Factions.canTalk(player) then return false, "no_radio" end
    local ps = Store.player(player)
    local limited = rateLimited(ps.key)
    if limited then return false, limited end

    local now = Sensor.now()
    local day = Store.dayIndex(now.dayKey)
    push(fid, { from = "player", name = ps.name, text = text, clock = now.clock, day = day })
    Radio.speaker[fid] = ps
    if StoryEngine.Legacy then StoryEngine.Legacy.talked(fid, ps.name) end
    -- 일지에는 실제 발언과 답장을 넘긴다 (Radio.logLine)
    Radio.logLine(ps, fid, "player", text, now.clock, day)
    Radio.channel(fid).lastPlayerT = now.t
    if Factions.isGone(fid) then
        push(fid, { from = "static", error = "gone", clock = now.clock, day = day })
        return true
    end
    if fid == Radio.OPEN then
        -- 공용 주파수: NPC 들이 각자 반응하고 서로 이야기한다
        if StoryEngine.Social then StoryEngine.Social.onOpenSay(ps, text) end
        return true
    end

    Radio.request(fid, ps.lang or Radio.langFor(fid))
    return true
end

function Radio.channelList()
    local open = Radio.channel(Radio.OPEN)
    local out = { { id = Radio.OPEN, freq = "121.5", open = true, seq = open.seq, busy = StoryEngine.Social
        and StoryEngine.Social.sceneBusy == true or false } }
    for _, f in ipairs(Factions.list) do
        local ch = Radio.channel(f.id)
        out[#out + 1] = { id = f.id, freq = f.freq, trust = ch.trust, seq = ch.seq, busy = Radio.busy[f.id] == true,
                          followUpIn = Radio.followUpIn(ch), gone = Factions.fateOf(f.id) }
    end
    return out
end

function Radio.history(fid)
    if not Factions.byId[fid] and fid ~= Radio.OPEN then return {} end
    local ch = Radio.channel(fid)
    local out = {}
    for i = math.max(1, #ch.messages - Radio.CLIENT_HISTORY + 1), #ch.messages do
        out[#out + 1] = ch.messages[i]
    end
    return out
end

return Radio
