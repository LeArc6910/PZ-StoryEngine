-- 샌드박스 세부 설정 (2026-09-30). 난이도 프리셋과 개별 값을 모아, 각 모듈의 상수에 적용하거나 배율을 돌려준다.
--
-- 난이도 (StoryEngine.Difficulty): 1 사용자 지정(샌드박스의 개별 값) / 2 편안함 / 3 보통 / 4 가혹.
--   2~4 를 고르면 PRESETS 에 있는 항목(설정 화면에서 ★ 표시)은 개별 값 대신 프리셋 값을 쓴다.
--   개별 값의 기본은 모두 지금까지의 고정값이라, 아무것도 바꾸지 않으면 동작이 그대로다.
-- 적용: Tuning.apply() 가 모듈 상수(Projects.GOAL, Social.CONTACT_GAP ...)를 바꾼다 (게임 시작·서버 시작·매 시간).
--   배율(신뢰도·가격·보상·기한·NPC 손실)은 쓰는 곳에서 Tuning.get 으로 읽는다.

require "StoryEngine/Core"

local Tuning = {}
StoryEngine.Tuning = Tuning

-- 개별 값의 기본 (= 예전 고정값)
Tuning.DEFAULTS = {
    Difficulty = 1,
    TrustStart = 0, TrustGainMult = 1, TrustLossMult = 1, SuspiciousRequests = 3, Spillover = true,
    RequestGapDays = 4, RequestServerGapDays = 2, QuestTimeMult = 1, RewardMult = 1,
    StageMidDay = 31, StageLateDay = 91, PriceMult = 1, GiftChance = 35,
    RequestPointsMult = 1.5, RequestMinTier = 3,
    -- 특기 대기 (2026-10-05): 범위 1 서버 전체 / 2 개인별 / 3 둘 다, 일수
    SpecialtyScope_ray = 1, SpecialtyScope_casey = 2, SpecialtyScope_doc = 2, SpecialtyScope_pike = 2,
    SpecialtyScope_dewey = 2, SpecialtyScope_guard = 2, SpecialtyScope_rats = 2, SpecialtyScope_hunter = 2,
    SpecialtyDays_ray = 7, SpecialtyDays_casey = 3, SpecialtyDays_doc = 7, SpecialtyDays_pike = 3,
    SpecialtyDays_dewey = 7, SpecialtyDays_guard = 7, SpecialtyDays_rats = 1, SpecialtyDays_hunter = 3,
    ZombieMult = 1, HuntSizeMult = 1, Extortion = true, StayHorde = true, StayHordeDays = 4, HeliGapDays = 5, RaidSizeMult = 1,
    LifeDrift = 5, LifeLossMult = 1, StarveDays = 3, NpcFateCause = 1,
    ProjectGoal = 1000, ProjectDonateCap = 100, DonateGapDays = 3,
    SpecialtyCooldownMult = 1, SpecialtyTrustOffset = 0, AutoSupportTrust = 70, AutoSupportDays = 7,
    AISaver = false, ContactHours = 5, SceneHours = 6, BanterHours = 3, LetterChance = 30,
    BroadcastHour = 19, BroadcastRerun = true,
}

-- 난이도 프리셋 { 편안함, 보통, 가혹 }
Tuning.PRESETS = {
    TrustStart = { 15, 0, -10 },
    TrustGainMult = { 1.5, 1, 0.75 },
    TrustLossMult = { 0.5, 1, 1.5 },
    QuestTimeMult = { 1.5, 1, 0.75 },
    RewardMult = { 1.3, 1, 0.75 },
    PriceMult = { 0.75, 1, 1.3 },
    RequestPointsMult = { 1.2, 1.5, 2 },
    HuntSizeMult = { 0.6, 1, 1.5 },
    RaidSizeMult = { 0.7, 1, 1.4 },
    LifeDrift = { 8, 5, 3 },
    LifeLossMult = { 0.6, 1, 1.4 },
    StarveDays = { 5, 3, 2 },
    ProjectGoal = { 700, 1000, 1500 },
    SpecialtyCooldownMult = { 0.6, 1, 1.5 },
}

function Tuning.difficulty()
    local vars = SandboxVars and SandboxVars.StoryEngine
    local d = vars and tonumber(vars.Difficulty) or 1
    return math.max(1, math.min(4, math.floor(d)))
end

function Tuning.get(name)
    local preset = Tuning.PRESETS[name]
    local d = Tuning.difficulty()
    if preset and d >= 2 then return preset[d - 1] end
    local vars = SandboxVars and SandboxVars.StoryEngine
    local v = vars and vars[name]
    if v == nil then return Tuning.DEFAULTS[name] end
    return v
end

function Tuning.num(name)
    return tonumber(Tuning.get(name)) or tonumber(Tuning.DEFAULTS[name]) or 0
end

-- 배율을 정수 변화량에 적용한다 (0 이 아니면 최소 1, 배율 0 이면 0)
function Tuning.scale(delta, mult)
    if delta == 0 or mult == 1 then return delta end
    if mult <= 0 then return 0 end
    local v = delta * mult
    local r = v >= 0 and math.floor(v + 0.5) or -math.floor(-v + 0.5)
    if r == 0 then r = delta > 0 and 1 or -1 end
    return r
end

local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

local BASE = {}

-- 모듈 상수에 적용한다 (몇 번 불러도 같은 결과: 원래 값은 처음 한 번 저장)
function Tuning.apply()
    local S = StoryEngine
    local saver = Tuning.get("AISaver") == true and 2 or 1
    if S.Trade then
        S.Trade.SUSPICIOUS_COUNT = math.max(2, math.floor(Tuning.num("SuspiciousRequests")))
        S.Trade.FREE_CHANCE = math.max(0, math.min(100, Tuning.num("GiftChance")))
    end
    if S.Director then
        S.Director.ASK_GAP_DAYS = math.max(1, Tuning.num("RequestGapDays"))
        S.Director.ASK_SERVER_GAP_DAYS = math.max(0, Tuning.num("RequestServerGapDays"))
        S.Director.HELI_GAP_MIN = math.max(1, Tuning.num("HeliGapDays")) * 24 * 60
    end
    if S.Store then
        local mid = math.max(2, math.floor(Tuning.num("StageMidDay")))
        local late = math.max(mid + 1, math.floor(Tuning.num("StageLateDay")))
        S.Store.STAGE_DAYS = { mid, late }
    end
    if S.Hunt then
        BASE.huntSize = BASE.huntSize or copy(S.Hunt.SIZE_BY_STAGE)
        local m = Tuning.num("HuntSizeMult")
        local sizes = {}
        for i, v in ipairs(BASE.huntSize) do sizes[i] = Tuning.zombies(v * m) end
        S.Hunt.SIZE_BY_STAGE = sizes
        S.Hunt.STAY_DAYS = math.max(1, Tuning.num("StayHordeDays"))
    end
    if S.ALife then
        BASE.attack = BASE.attack or copy(S.ALife.ATTACK_SIZE)
        local m = Tuning.num("RaidSizeMult")
        local sizes = {}
        for i, v in ipairs(BASE.attack) do sizes[i] = math.max(1, math.min(8, math.floor(v * m + 0.5))) end
        S.ALife.ATTACK_SIZE = sizes
        S.ALife.AUTO_TRUST = math.max(50, math.min(100, Tuning.num("AutoSupportTrust")))
        S.ALife.AUTO_COOLDOWN_MIN = math.max(1, Tuning.num("AutoSupportDays")) * 24 * 60
    end
    if S.Life then
        S.Life.DRIFT = math.max(0, Tuning.num("LifeDrift"))
        S.Life.DONATE_GAP_MIN = math.max(0, Tuning.num("DonateGapDays")) * 24 * 60
    end
    if S.Fate then S.Fate.STARVE_DAYS = math.max(1, Tuning.num("StarveDays")) end
    if S.Projects then
        S.Projects.GOAL = math.max(100, math.floor(Tuning.num("ProjectGoal")))
        S.Projects.DONATE_CAP = math.max(10, math.floor(Tuning.num("ProjectDonateCap")))
    end
    if S.Specialty then
        BASE.cooldown = BASE.cooldown or copy(S.Specialty.COOLDOWN_DAYS)
        BASE.tiers = BASE.tiers or copy(S.Specialty.TIER_MIN)
        local m = Tuning.num("SpecialtyCooldownMult")
        local cd = {}
        -- 특기마다 대기 일수 (SpecialtyDays_<fid>, 기본 = 예전 고정값) x 배율
        for fid, days in pairs(BASE.cooldown) do
            local own = Tuning.get("SpecialtyDays_" .. fid)
            if own == nil then own = days end
            cd[fid] = math.max(0, (tonumber(own) or days) * m)
        end
        S.Specialty.COOLDOWN_DAYS = cd
        local off = Tuning.num("SpecialtyTrustOffset")
        local tiers = {}
        for i, v in ipairs(BASE.tiers) do tiers[i] = math.max(0, math.min(100, v + off)) end
        S.Specialty.TIER_MIN = tiers
    end
    if S.Social then
        local c = math.max(1, Tuning.num("ContactHours")) * 60 * saver
        local sc = math.max(1, Tuning.num("SceneHours")) * 60 * saver
        S.Social.CONTACT_GAP = { math.max(30, c - 60), c + 60 }
        S.Social.SCENE_GAP = { math.max(30, sc - 60), sc + 60 }
    end
    if S.Banter then S.Banter.GAP_MIN = math.max(1, Tuning.num("BanterHours")) * 60 * saver end
    if S.Letters then S.Letters.GIFT_CHANCE = math.max(0, math.min(100, Tuning.num("LetterChance"))) end
    if S.Broadcast then S.Broadcast.HOUR = math.max(0, math.min(23, math.floor(Tuning.num("BroadcastHour")))) end
end

-- 모드가 만드는 좀비 무리 하나의 수: 모든 무리(소탕 퀘스트, 구조 신호 건물, 추적 무리, 작전·사건)에 ZombieMult 를 곱한다.
-- 프리셋에는 없어 난이도와 상관없이 적용된다. 한 번에 너무 많이 만들지 않도록 ZOMBIE_CAP 에서 자른다.
Tuning.ZOMBIE_CAP = 300
function Tuning.zombies(n)
    local m = tonumber(Tuning.get("ZombieMult")) or 1
    return math.max(1, math.min(Tuning.ZOMBIE_CAP, math.floor((tonumber(n) or 0) * m + 0.5)))
end

-- AI 절약 모드: 혼잣말 최소 간격도 두 배 (Monologue)
function Tuning.saverFactor()
    return Tuning.get("AISaver") == true and 2 or 1
end

-- 지금 값 한 줄 (디버그 상태 줄)
function Tuning.statusText()
    local names = { "Difficulty", "TrustGainMult", "TrustLossMult", "QuestTimeMult", "RewardMult", "PriceMult",
                    "ZombieMult", "HuntSizeMult", "LifeLossMult", "ProjectGoal", "SpecialtyCooldownMult", "AISaver" }
    local parts = {}
    for _, n in ipairs(names) do parts[#parts + 1] = n .. "=" .. tostring(Tuning.get(n)) end
    return "tuning " .. table.concat(parts, " ")
end

local function safeApply()
    if isClient and isClient() then return end     -- 서버 모듈 상수만 바꾼다 (클라이언트는 get/num 만 쓴다)
    local ok, err = pcall(Tuning.apply)
    if not ok then StoryEngine.log("tuning apply error:", err) end
end
Tuning.safeApply = safeApply

if Events then
    if Events.OnGameStart then Events.OnGameStart.Add(safeApply) end
    if Events.OnServerStarted then Events.OnServerStarted.Add(safeApply) end
    if Events.OnInitGlobalModData then Events.OnInitGlobalModData.Add(safeApply) end
    if Events.EveryHours then Events.EveryHours.Add(safeApply) end
end

return Tuning
