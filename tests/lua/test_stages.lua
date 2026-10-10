-- 진행 단계 5개와 그에 묶인 것들 (2026-10-10 사용자 결정): 91일 뒤로도 커지게 181일·271일에 4·5단계,
-- 부탁 등급 확률과 최소 등급, 모금 물량, 작은 좀비 무리
local T = {}

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    return p, ps
end

-- 서버 경과 일수를 day 로
local function toDay(day)
    local Store = StoryEngine.Store
    H.advanceDays(day - Store.serverDays())
    H.eq(Store.serverDays(), day)
end

function T.five_stages_by_server_day()
    setup()
    local Store, Hunt = StoryEngine.Store, StoryEngine.Hunt
    H.eq(Store.stage(), 1)
    H.eq(Hunt.sizeNow(), 20)
    toDay(31)
    H.eq(Store.stage(), 2)
    toDay(91)
    H.eq(Store.stage(), 3)
    H.eq(Hunt.sizeNow(), 60)
    toDay(180)
    H.eq(Store.stage(), 3, "still the late stage")
    toDay(181)
    H.eq(Store.stage(), 4)
    H.eq(Hunt.sizeNow(), 80, "hordes keep growing after day 91")
    H.eq(Store.STAGE_MAX_TIER[4], 5)
    H.eq(Store.stageNeed(), 1.75)
    H.eq(Store.stagePack(), 2.5)
    toDay(271)
    H.eq(Store.stage(), 5)
    H.eq(Hunt.sizeNow(), 100)
    H.eq(StoryEngine.ALife.ATTACK_SIZE[5], 8, "a full A-Life squad")
    toDay(400)
    H.eq(Store.stage(), 5, "the last stage")
end

function T.stage_days_come_from_the_sandbox_in_order()
    setup()
    local Store, Tuning = StoryEngine.Store, StoryEngine.Tuning
    SandboxVars.StoryEngine.Stage4Day = 120
    SandboxVars.StoryEngine.Stage5Day = 100          -- 4단계보다 작으면 그다음 날
    Tuning.apply()
    H.eq(Store.STAGE_DAYS[3], 120)
    H.eq(Store.STAGE_DAYS[4], 121)
    SandboxVars.StoryEngine.Stage4Day, SandboxVars.StoryEngine.Stage5Day = nil, nil
    Tuning.apply()
    H.eq(Store.STAGE_DAYS[3], 181)
    H.eq(Store.STAGE_DAYS[4], 271)
end

function T.requests_lean_higher_in_later_stages()
    local p, ps = setup()
    local Director, Radio = StoryEngine.Director, StoryEngine.Radio
    -- 같은 주사위라도 단계가 오르면 등급이 오른다
    H.rolls = { 20 }
    H.eq(Director.randomIntensity(), 1, "early: 35 percent tier 1")
    toDay(91)
    H.rolls = { 20 }
    H.eq(Director.randomIntensity(), 2, "late: tier 1 is only 15 percent")
    toDay(271)
    H.rolls = { 20 }
    H.eq(Director.randomIntensity(), 3, "stage 5: 5 + 15 are below 20")
    H.rolls = { 99 }
    H.eq(Director.randomIntensity(), 5)
    -- 최소 등급: 5단계는 3, 다만 신뢰도 상한이 더 낮으면 상한
    Radio.channel("ray").trust = 80
    H.eq(Director.askTier(1, ps, "ray"), 3, "never below tier 3 in stage 5")
    H.eq(Director.askTier(5, ps, "ray"), 5)
    Radio.channel("rats").trust = 10
    H.eq(Director.askTier(1, ps, "rats"), 2, "a stranger still asks for little")
end

function T.early_requests_are_as_before()
    local p, ps = setup()
    local Director = StoryEngine.Director
    StoryEngine.Radio.channel("ray").trust = 80
    H.eq(Director.askTier(1, ps, "ray"), 1, "no floor early on")
    H.eq(Director.askTier(4, ps, "ray"), 2, "early stage caps at tier 2")
end

function T.collections_grow_with_the_stage()
    local p, ps = setup()
    local Quests = StoryEngine.Quests
    local need = { { "Base.Pipe", 4 }, { "Base.Wrench", 1 } }
    local q1 = Quests.createCollect(ps, need, StoryEngine.Sensor.now(), { source = "test" }, StoryEngine.Sensor.now().t + 1000)
    H.eq(q1.need[1][2], 4, "early: as written")
    toDay(91)
    local q3 = Quests.createCollect(ps, need, StoryEngine.Sensor.now(), { source = "test" }, StoryEngine.Sensor.now().t + 1000)
    H.eq(q3.need[1][2], 6, "late: x1.5")
    H.eq(q3.need[2][2], 2, "rounded up")
    toDay(271)
    local q5 = Quests.createCollect(ps, need, StoryEngine.Sensor.now(), { source = "test" }, StoryEngine.Sensor.now().t + 1000)
    H.eq(q5.need[1][2], 8, "stage 5: x2")
    H.eq(need[1][2], 4, "the table itself is untouched")
end

return T
