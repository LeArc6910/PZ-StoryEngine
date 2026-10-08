-- 세력 신뢰도 (서버 측 전용). 대화보다 행동(퀘스트 결과)으로 움직인다.
--
-- 누가 먼저 시작한 일인지에 따라 폭이 다르다. NPC 가 필요할 때 부탁한 일에 대한 응답은 오래 기억된다.
--   npc    : NPC 가 먼저 부탁 (전달 부탁, 회수 부탁)
--   player : 플레이어가 먼저 부탁 (B단계 거래)
--   gift   : NPC 가 호의로 알려 준 보급
-- 보상 보급(origin.source = "reward")은 신뢰도에 영향이 없다.
-- 대화로는 한 번에 -1~+1 만 움직인다 (Radio.lua).

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Radio"

local Radio = StoryEngine.Radio
local Factions = StoryEngine.Factions
local Sensor = StoryEngine.Sensor
local log = StoryEngine.log

local Trust = {}
StoryEngine.Trust = Trust

-- 퀘스트 결과별 신뢰도 변화 (등급 1~5 순서). 2026-09-27 사용자 결정: 완료하면 등급만큼 오른다.
-- 거절·무응답·실패 감점은 같은 규모로 작게, 어려운 부탁일수록 못 들어줘도 이해하므로 더 작다.
-- 감점에는 대상 플레이어의 진행 단계 배율(Store.STAGE_PENALTY)을 곱한다.
Trust.DELTA = {
    npc = {
        accepted = { 0, 0, 0, 0, 0 },
        declined = { -2, -2, -1, -1, -1 },
        ignored = { -3, -2, -2, -1, -1 },
        completed = { 1, 2, 3, 4, 5 },
        failed = { -5, -4, -3, -2, -1 },
    },
    player = {
        completed = { 1, 2, 3, 4, 5 },
        failed = { -2, -2, -1, -1, -1 },
    },
    gift = {
        completed = { 1, 1, 1, 1, 1 },
        failed = { -1, -1, -1, -1, -1 },
    },
    -- 협박에 응했을 때 (Quests.demand). 실패하면 신뢰도 대신 보복이 온다
    threat = {
        completed = { 1, 1, 1, 1, 1 },
    },
}

-- 후반(자원이 쌓인 뒤)의 감점: 등급이 높을수록 크다. 큰 일을 맡았다가 틀어지면 크게 잃는다 (2026-09-27 사용자 결정)
Trust.LATE = {
    npc = {
        declined = { -1, -2, -3, -4, -5 },
        ignored = { -2, -3, -4, -5, -6 },
        failed = { -2, -4, -6, -8, -10 },
    },
    player = { failed = { -1, -2, -3, -4, -5 } },
    gift = { failed = { -2, -2, -2, -2, -2 } },
}

function Trust.initiator(q)
    local o = q.origin or {}
    if o.initiator then return o.initiator end
    if o.source == "reward" then return nil end
    if q.kind == "supply_drop" then return "gift" end
    return "npc"
end

-- ---------------------------------------------------------------- 개인 신뢰 (2026-10-09, docs/DESIGN_PER_PLAYER_TRUST.md)
-- 멀티 + 샌드박스 TrustBenefits = 2 일 때만. 집단 신뢰(ch.trust)는 무리의 일로만, 개인 신뢰(ch.personal[캐릭터 키])는
-- 개인의 일 + 무리의 일에 손을 보탠 보너스로 움직이고, 혜택은 모두 개인 신뢰(Trust.of)로 판정한다.
-- 싱글·공유 모드는 지금 구조 (신뢰 하나): Trust.of 가 ch.trust 를 돌려주고 Trust.apply 가 ch.trust 를 바꾼다.

-- 이유별로 어느 신뢰에 들어가나 (개인 모드). 없는 이유는 byKey 가 있으면 개인, 없으면 집단
Trust.SCOPE = {
    crisis_chosen = "group", crisis_ally = "group", crisis_snubbed = "group", crisis_ignored = "group",
    saga = "group", holiday_help = "group", project_done = "group",
    debug = "both",
}

-- 개인별 부탁에서 도운 사람이 받는 몫을 주는 퀘스트 종류
Trust.HELPER_KINDS = { deliver = true, horde = true, fetch = true, named = true }

function Trust.personalMode()
    if not isServer() then return false end           -- 싱글은 늘 신뢰 하나
    local Tuning = StoryEngine.Tuning
    return Tuning ~= nil and Tuning.num("TrustBenefits") == 2
end

-- 모드가 바뀌었는지 서버가 뜬 뒤 처음 쓸 때 한 번 확인한다 (첫 EveryHours 전에 무전·거래해도 옮기기가 먼저 되게)
local function ensureMode()
    if Trust.modeChecked then return end
    Trust.modeChecked = true
    local ok, err = pcall(Trust.checkMode)
    if not ok then log("trust mode check error:", err) end
end

-- NPC 처음 값 (샌드박스 TrustStart 반영)
function Trust.startOf(fid)
    local f = Factions.byId[fid]
    local start = f and f.trust or 0
    if StoryEngine.Tuning then start = start + StoryEngine.Tuning.num("TrustStart") end
    return math.max(0, math.min(100, start))
end

function Trust.known(fid, key)
    local ch = Radio.channel(fid)
    return key ~= nil and ch.personal ~= nil and ch.personal[key] ~= nil
end

-- 처음 연락하면 받을 값: 처음 값 + (집단 - 처음 값) x 소개 비율 (0 미만이면 0)
local function introValue(fid)
    local ch = Radio.channel(fid)
    local start = Trust.startOf(fid)
    local intro = (StoryEngine.Tuning and StoryEngine.Tuning.num("TrustIntro") or 25) / 100
    local v = start + math.max(0, (ch.trust or 0) - start) * math.max(0, math.min(1, intro))
    return math.max(0, math.min(100, math.floor(v + 0.5)))
end

-- 처음 연락하는 순간 기록을 만든다 (무전으로 말함, 개인별 부탁을 받음, 그 NPC 의 일을 함, 개인 신뢰가 바뀜)
function Trust.ensure(fid, key)
    if not key or not Factions.byId[fid] then return nil end
    ensureMode()
    local ch = Radio.channel(fid)
    ch.personal = ch.personal or {}
    if ch.personal[key] == nil then
        ch.personal[key] = introValue(fid)
        log("personal trust first contact", fid, key, ch.personal[key])
    end
    return ch.personal[key]
end

-- 읽기만 한다: 아직 모르는 사이면 처음 연락할 때 받을 값을 보여 주고 기록은 만들지 않는다
-- (목록을 보거나 AI 맥락을 만드는 것만으로 "아는 사이"가 되지 않게: 파급·식음은 아는 사이에만)
function Trust.personal(fid, key)
    if not key or not Factions.byId[fid] then return 0 end
    local ch = Radio.channel(fid)
    local v = ch.personal and ch.personal[key]
    if v ~= nil then return v end
    return introValue(fid)
end

-- 혜택을 판정하는 신뢰: 개인 모드면 그 사람의 개인 신뢰, 아니면 신뢰 하나 (ch.trust)
function Trust.of(fid, key)
    ensureMode()
    if Trust.personalMode() and key then return Trust.personal(fid, key) end
    return Radio.channel(fid).trust or 0
end

-- 그 NPC 와 직접 무언가를 했다 (버튼 거래·특기·일거리·대가 방식 고르기 등): 상대한 날 + 개인 모드면 처음 연락
function Trust.contact(fid, key)
    if not key or not Factions.byId[fid] then return end
    Trust.touch(fid, key)
    if Trust.personalMode() then Trust.ensure(fid, key) end
end

-- 이 NPC 를 "상대했다" (식음 계산, 6절)
function Trust.touch(fid, key)
    if not Factions.byId[fid] then return end
    local ch = Radio.channel(fid)
    local day = StoryEngine.Store.dayIndex(Sensor.now().dayKey)
    ch.touchDay = day
    if key then
        ch.touchBy = ch.touchBy or {}
        ch.touchBy[key] = day
    end
end

local function scaled(delta, reason)
    local Tuning = StoryEngine.Tuning
    if Tuning and reason ~= "debug" then
        return Tuning.scale(delta, Tuning.num(delta > 0 and "TrustGainMult" or "TrustLossMult"))
    end
    return delta
end

-- 개인 신뢰를 바꾸고 그 사람에게만 보이는 기록 줄을 남긴다. 바뀐 양.
-- raw: 이미 배율이 적용된 값에서 나온 것 (보너스·대화)이라 TrustGainMult/LossMult 를 다시 곱하지 않는다
function Trust.addPersonal(fid, key, delta, reason, questId, src, raw)
    if not key or not Factions.byId[fid] or delta == 0 then return 0 end
    local ps = StoryEngine.Store.data().players[key]
    if ps and ps.dead then return 0 end                -- 죽은 캐릭터의 기록을 되살리지 않는다
    if not raw then delta = scaled(delta, reason) end
    if delta == 0 then return 0 end
    local ch = Radio.channel(fid)
    local before = Trust.ensure(fid, key)
    local after = math.max(0, math.min(100, before + delta))
    ch.personal[key] = after
    if delta < 0 then ch.lastOffender = key end
    Trust.touch(fid, key)
    local applied = after - before
    log("personal trust", fid, key, before, "->", after, reason, src or "")
    if applied ~= 0 then
        Radio.push(fid, { from = "system", trust = applied, personal = true, to = key, reason = reason, quest = questId,
                          src = src, clock = Sensor.now().clock })
    end
    return applied
end

local function applyGroup(fid, delta, reason, questId, byKey, src)
    delta = scaled(delta, reason)
    if delta == 0 then return 0 end
    local ch = Radio.channel(fid)
    if delta < 0 and byKey then ch.lastOffender = byKey end
    local before = ch.trust
    ch.trust = math.max(0, math.min(100, ch.trust + delta))
    local applied = ch.trust - before
    if applied > 0 and StoryEngine.Chronicle then pcall(StoryEngine.Chronicle.onTrust, fid, before, ch.trust) end
    log("trust", fid, before, "->", ch.trust, reason, src or "")
    if applied ~= 0 then
        Radio.push(fid, { from = "system", trust = applied, reason = reason, quest = questId, src = src,
                          group = Trust.personalMode() or nil, clock = Sensor.now().clock })
    end
    return applied
end

-- 신뢰도를 바꾸고 채널에 기록을 남긴다 (클라이언트가 "신뢰도 +10 (이유)" 로 보여 준다).
-- byKey: 이 변화의 원인이 된 플레이어 (감점이면 ch.lastOffender 로 기억해 협박 보복 대상으로 쓴다)
-- src: 관계 파급일 때 도움받은 NPC (클라이언트가 "빅을 도운 것" 처럼 보여 준다)
-- scope (개인 모드만): "group" | "personal" | "both". 없으면 Trust.SCOPE[reason], 그것도 없으면 byKey 가 있으면 개인
Trust.TRADE_WEEK_CAP = 5
Trust.TRADE_WEEK_MIN = 7 * 24 * 60

function Trust.apply(fid, delta, reason, questId, byKey, src, scope)
    if not Factions.byId[fid] or delta == 0 then return 0 end
    if byKey then Trust.touch(fid, byKey) end
    if not Trust.personalMode() then return applyGroup(fid, delta, reason, questId, byKey, src) end
    scope = scope or Trust.SCOPE[reason] or (byKey and "personal" or "group")
    if scope == "both" then
        local applied = applyGroup(fid, delta, reason, questId, byKey, src)
        if byKey then Trust.addPersonal(fid, byKey, delta, reason, questId, src) end
        return applied
    elseif scope == "personal" then
        if not byKey then
            log("personal trust change without a player dropped", fid, reason, delta)
            return 0
        end
        return Trust.addPersonal(fid, byKey, delta, reason, questId, src)
    end
    return applyGroup(fid, delta, reason, questId, byKey, src)
end

-- 무리의 일인가 (개인 모드에서 집단 신뢰로만 가는 퀘스트): 큰 이야기·곁가지·AI 곁가지·위기(후속 포함)·큰 사건·명절·회의·작전
function Trust.isGroupWork(q)
    local o = q and q.origin or {}
    if o.story or o.crisis or q.kind == "choice" then return true end
    if o.holiday or o.council or o.op then return true end
    local Quests = StoryEngine.Quests
    if Quests and Quests.isSaga and Quests.isSaga(q) then return true end
    return false
end

-- 손을 보탠 사람들(keys = { 키 -> 이름 })에게 개인 신뢰 보너스. gain 의 share 배, 최소 1. except: 뺄 키
function Trust.bonus(fid, keys, gain, share, reason, questId, except)
    if not Trust.personalMode() or not keys or gain <= 0 or share <= 0 then return 0 end
    local each = math.max(1, math.floor(gain * share + 0.5))
    local n = 0
    for key in pairs(keys) do
        local ps = StoryEngine.Store.data().players[key]
        if key ~= except and ps and not ps.dead then
            Trust.addPersonal(fid, key, each, reason, questId, nil, true)   -- gain 은 이미 배율이 적용됨
            n = n + 1
        end
    end
    return n
end

local function tradeWeek(ch, key, now)
    local tt
    if key then
        ch.tradeTrustBy = ch.tradeTrustBy or {}
        tt = ch.tradeTrustBy[key]
    else
        tt = ch.tradeTrust
    end
    if not tt or now - (tt.start or 0) >= Trust.TRADE_WEEK_MIN then
        tt = { start = now, gained = 0 }
        if key then ch.tradeTrustBy[key] = tt else ch.tradeTrust = tt end
    end
    return tt
end

-- outcome: accepted | declined | ignored | completed | failed
function Trust.forQuest(q, outcome)
    local fid = q.origin and q.origin.faction
    if not fid or q.noTrust then return 0 end      -- 빚으로 받은 거래 (Work.lua): 신뢰도 변화 없음
    if q.lapsed then return 0 end                  -- 받은 사람이 접속하지 않은 채 닫힌 개인별 부탁 (감점 없음)
    local who = Trust.initiator(q)
    local row = who and Trust.DELTA[who] and Trust.DELTA[who][outcome]
    if not row then return 0 end
    local tier = math.max(1, math.min(#row, math.floor(q.tier or 1)))
    local delta = row[tier]
    if delta < 0 then
        -- 진행 단계: 초반 x0.5(반올림, 최소 1), 중반 그대로, 후반은 등급이 높을수록 큰 Trust.LATE 표
        local Store = StoryEngine.Store
        local stage = Store.stage(Store.data().players[q.target])
        local late = Trust.LATE[who] and Trust.LATE[who][outcome]
        if stage >= 3 and late then
            delta = late[tier]
        else
            local mult = Store.STAGE_PENALTY[stage] or 1
            delta = -math.max(1, math.floor(-delta * mult + 0.5))
        end
        -- 나눠 내다 기한을 넘겼으면 못 낸 비율만큼만 깎는다 (2026-10-08 사용자 결정 "낸 만큼 반영")
        local share = outcome == "failed" and StoryEngine.Quests.paidShare and StoryEngine.Quests.paidShare(q) or 0
        if share > 0 then
            delta = -math.floor(-delta * (1 - share) + 0.5)
            if delta == 0 then
                log("quest failure forgiven (paid share)", q.id, share)
                return 0
            end
        end
    end
    local personal = Trust.personalMode()
    local Tuning = StoryEngine.Tuning
    if personal and Trust.isGroupWork(q) then
        -- 무리의 일: 집단 신뢰만. 성공하면 손을 보탠 사람에게 개인 보너스 (감점은 없음)
        local applied = applyGroup(fid, delta, who .. "_" .. outcome, q.id, nil, nil)
        if outcome == "completed" and applied > 0 then
            Trust.bonus(fid, q.helpers, applied, Tuning and Tuning.num("GroupHelperTrust") or 0.5, "group_help", q.id)
        end
        for key in pairs(q.helpers or {}) do Trust.touch(fid, key) end
        return applied
    end
    -- 개인의 일 (개인 모드: 받은 사람·거래한 사람) / 신뢰 하나 (싱글·공유)
    local key = personal and (q.addressed or q.target) or nil
    if personal and not key then return 0 end
    local function give(d)
        if personal then return Trust.addPersonal(fid, key, d, who .. "_" .. outcome, q.id) end
        return Trust.apply(fid, d, who .. "_" .. outcome, q.id, q.target)
    end
    -- 거래로 오르는 신뢰도는 NPC 마다(개인 모드는 사람마다) 게임 7일에 TRADE_WEEK_CAP 까지 (2026-10-03 점검)
    if who == "player" and q.kind == "trade" and delta > 0 then
        local tt = tradeWeek(StoryEngine.Radio.channel(fid), key, StoryEngine.Sensor.now().t)
        delta = math.min(delta, math.max(0, Trust.TRADE_WEEK_CAP - (tt.gained or 0)))
        if delta <= 0 then
            StoryEngine.log("trade trust capped", fid, q.id)
            return 0
        end
        local applied = give(delta)
        tt.gained = (tt.gained or 0) + math.max(0, applied)
        return applied
    end
    local applied = give(delta)
    -- 개인별 부탁을 도운 사람: 받은 사람이 얻은 신뢰의 HelperTrustShare 배 (감점은 받은 사람만)
    if personal and outcome == "completed" and applied > 0 and Trust.HELPER_KINDS[q.kind] then
        Trust.bonus(fid, q.helpers, applied, Tuning and Tuning.num("HelperTrustShare") or 0.5, "helped", q.id, key)
    end
    return applied
end

-- ---------------------------------------------------------------- 속도 조정·모드 전환·정리

-- 대화로 오르는 신뢰의 상한 (2026-10-08 6절: 말로는 경계를 푸는 데까지)
function Trust.chatMax()
    return StoryEngine.Tuning and StoryEngine.Tuning.num("ChatTrustMax") or 40
end

-- 무전 대화의 신뢰 변화 (Radio.request). 하루 +1 (개인 모드는 사람마다), +는 ChatTrustMax 미만일 때만. 바뀐 양
Trust.CHAT_PER_DAY = 1
function Trust.chat(fid, ps, change, day)
    if change == 0 then return 0 end
    local personal = Trust.personalMode() and ps ~= nil
    local ch = Radio.channel(fid)
    if change > 0 then
        local now = personal and Trust.personal(fid, ps.key) or ch.trust
        if now >= Trust.chatMax() then return 0 end
        local key = personal and ps.key or "_"
        ch.chatTrustBy = ch.chatTrustBy or {}
        local c = ch.chatTrustBy[key]
        if not c or c.day ~= day then
            c = { day = day, gain = 0 }
            ch.chatTrustBy[key] = c
        end
        if c.gain >= Trust.CHAT_PER_DAY then return 0 end
        c.gain = c.gain + change
    end
    if ps then Trust.touch(fid, ps.key) end
    -- 대화는 예전처럼 배율 없이 (공유 모드와 같게)
    if personal then return Trust.addPersonal(fid, ps.key, change, change > 0 and "chat" or "insult", nil, nil, true) end
    local before = ch.trust
    ch.trust = math.max(0, math.min(100, ch.trust + change))
    if change < 0 and ps then ch.lastOffender = ps.key end
    return ch.trust - before
end

-- 식음 (6절): 하루가 바뀔 때 (Trust.daily). online = { 키 = true }: 어제 접속한 캐릭터
local function fadeOne(fid, value, idle)
    local days = StoryEngine.Tuning and StoryEngine.Tuning.num("TrustFadeDays") or 14
    local every = math.max(1, StoryEngine.Tuning and StoryEngine.Tuning.num("TrustFadeEvery") or 3)
    if days <= 0 or idle < days or (idle - days) % every ~= 0 then return 0 end
    local floor = Trust.startOf(fid) + 20
    if value <= floor then return 0 end
    return -1
end

function Trust.daily(prevDay, online)
    local personal = Trust.personalMode()
    for _, f in ipairs(Factions.list) do
        if not Factions.isGone(f.id) then
            local ch = Radio.channel(f.id)
            if personal then
                ch.personalIdle = ch.personalIdle or {}
                for key in pairs(ch.personal or {}) do
                    if online[key] then
                        if (ch.touchBy or {})[key] == prevDay then
                            ch.personalIdle[key] = 0
                        else
                            local idle = (ch.personalIdle[key] or 0) + 1
                            ch.personalIdle[key] = idle
                            local d = fadeOne(f.id, ch.personal[key], idle)
                            if d ~= 0 then
                                ch.personal[key] = math.max(0, ch.personal[key] + d)
                                Radio.push(f.id, { from = "system", trust = d, personal = true, to = key, reason = "fade",
                                                   clock = Sensor.now().clock })
                                log("personal trust fades", f.id, key, idle, "days")
                            end
                        end
                    end
                end
            else
                local anyone = false
                for _ in pairs(online) do anyone = true end
                if anyone then
                    if ch.touchDay == prevDay then
                        ch.idleDays = 0
                    else
                        ch.idleDays = (ch.idleDays or 0) + 1
                        local d = fadeOne(f.id, ch.trust, ch.idleDays)
                        if d ~= 0 then
                            applyGroup(f.id, d, "fade", nil, nil, nil)
                            log("trust fades", f.id, ch.idleDays, "days")
                        end
                    end
                end
            end
        end
    end
end

-- 접속 기록과 하루 넘김 (EveryHours). 어제 접속한 캐릭터로 식음을 셈
function Trust.hourly()
    local Store = StoryEngine.Store
    local d = Store.data()
    local now = Sensor.now()
    local today = Store.dayIndex(now.dayKey)
    d.trustDays = d.trustDays or { day = today, online = {} }
    local st = d.trustDays
    if st.day ~= today then
        local ok, err = pcall(Trust.daily, st.day, st.online or {})
        if not ok then log("trust daily error:", err) end
        st.day, st.online = today, {}
    end
    for _, p in ipairs(Sensor.players()) do st.online[Store.playerKey(p)] = true end
    Trust.checkMode()
end

Events.OnServerStarted.Add(function()
    Trust.modeChecked = true
    local ok, err = pcall(Trust.checkMode)
    if not ok then log("trust mode check error:", err) end
end)

-- 모드가 바뀌었으면 옮긴다 (3절). 1 -> 2: 개인 기록이 없는 살아 있는 캐릭터의 개인 신뢰 = 그때의 집단 신뢰.
-- 2 -> 1: 집단 신뢰 = max(집단, 개인 신뢰가 있는 살아 있는 캐릭터들의 평균). 개인 기록은 남겨 둔다
function Trust.checkMode()
    if not isServer() then return end
    local Store = StoryEngine.Store
    local d = Store.data()
    local mode = Trust.personalMode() and 2 or 1
    if d.trustMode == mode then return end
    local was = d.trustMode
    d.trustMode = mode
    if was == nil and mode == 1 then return end
    if was == nil then
        -- 처음 보는 세이브: 이틀 넘게 진행한 세이브면 예전(공유) 세이브라 옮기고, 새 게임이면 옮길 것이 없다
        local old = (Store.serverDays() or 0) >= 2
        if not old then
            log("trust mode", mode, "(new save)")
            return
        end
    end
    local players = d.players or {}
    for _, f in ipairs(Factions.list) do
        local ch = Radio.channel(f.id)
        if mode == 2 then
            ch.personal = ch.personal or {}
            for key, ps in pairs(players) do
                if not ps.dead and ch.personal[key] == nil then ch.personal[key] = ch.trust end
            end
        else
            local sum, n = 0, 0
            for key, v in pairs(ch.personal or {}) do
                if players[key] and not players[key].dead then sum, n = sum + v, n + 1 end
            end
            if n > 0 then ch.trust = math.max(ch.trust, math.floor(sum / n + 0.5)) end
        end
    end
    log("trust mode", tostring(was), "->", mode)
end

-- 죽은 캐릭터의 개인 기록을 지운다 (2절)
function Trust.forget(key)
    if not key then return end
    for _, f in ipairs(Factions.list) do
        local ch = Radio.channel(f.id)
        for _, map in ipairs({ ch.personal, ch.personalIdle, ch.touchBy, ch.tradeTrustBy, ch.chatTrustBy,
                               ch.requestLogBy, ch.workLogBy, ch.volunteerLogBy, ch.workBurnBy }) do
            if map then map[key] = nil end
        end
        local Life = StoryEngine.Life
        local n = Life and Life.npc and Life.npc(f.id)
        if n and n.donateWinBy then n.donateWinBy[key] = nil end
    end
end

-- 후임이 이어받음: 모두의 개인 신뢰가 처음부터 (5-4절)
function Trust.resetPersonal(fid)
    local ch = Radio.channel(fid)
    ch.personal, ch.personalIdle, ch.touchBy, ch.tradeTrustBy, ch.chatTrustBy, ch.requestLogBy = {}, {}, {}, {}, {}, {}
    ch.workLogBy, ch.volunteerLogBy, ch.workBurnBy = {}, {}, {}
    local Life = StoryEngine.Life
    local n = Life and Life.npc and Life.npc(fid)
    if n then n.donateWinBy = {} end
end

-- AI 에 넘기는 "이 사람" (7절). 개인 모드에서만
function Trust.personContext(fid, ps)
    if not Trust.personalMode() or not ps then return nil end
    local v = Trust.personal(fid, ps.key)
    local known = (v >= 60 and "well") or (v >= Trust.startOf(fid) + 10 and "little") or "new"
    return { name = ps.name, trust = v, known = known }
end

Events.EveryHours.Add(function()
    local ok, err = pcall(Trust.hourly)
    if not ok then log("trust hourly error:", err) end
end)

return Trust
