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

-- 신뢰도를 바꾸고 채널에 기록을 남긴다 (클라이언트가 "신뢰도 +10 (이유)" 로 보여 준다).
-- byKey: 이 변화의 원인이 된 플레이어 (감점이면 ch.lastOffender 로 기억해 협박 보복 대상으로 쓴다)
-- src: 관계 파급일 때 도움받은 NPC (클라이언트가 "빅을 도운 것" 처럼 보여 준다)
function Trust.apply(fid, delta, reason, questId, byKey, src)
    if not Factions.byId[fid] or delta == 0 then return 0 end
    local ch = Radio.channel(fid)
    if delta < 0 and byKey then ch.lastOffender = byKey end
    local before = ch.trust
    ch.trust = math.max(0, math.min(100, ch.trust + delta))
    local applied = ch.trust - before
    log("trust", fid, before, "->", ch.trust, reason, src or "")
    if applied ~= 0 then
        Radio.push(fid, { from = "system", trust = applied, reason = reason, quest = questId, src = src,
                          clock = Sensor.now().clock })
    end
    return applied
end

-- outcome: accepted | declined | ignored | completed | failed
function Trust.forQuest(q, outcome)
    local fid = q.origin and q.origin.faction
    if not fid then return 0 end
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
    end
    return Trust.apply(fid, delta, who .. "_" .. outcome, q.id, q.target)
end

return Trust
