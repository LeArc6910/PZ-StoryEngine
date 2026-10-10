-- 신뢰도 유지 (Trust.lua, 2026-10-10 사용자 결정, PLAN_COUNCIL_POLITICS 1b단계):
-- T1 믿은 만큼 아프게, T2 높은 신뢰의 유지비(일만 쳐 줌), T3 어려울 때 외면, T6 초·중반 감점표, T7 높은 신뢰는 더디게
local T = {}

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    H.defineItem("Base.TinnedBeans", "food", 1.5)
    H.defineItem("Base.Bullets9mmBox", "ammo", 15)
    return p, ps
end

local function ch(fid) return StoryEngine.Radio.channel(fid) end
local function Tr() return StoryEngine.Trust end

local function toDay(day)
    H.advanceDays(day - StoryEngine.Store.serverDays())
end

-- NPC 가 청한 부탁 하나의 결과로 바뀐 신뢰
local function outcome(ps, fid, tier, result, trust)
    ch(fid).trust = trust
    local q = { id = "QX", kind = "deliver", tier = tier, target = ps.key, origin = { faction = fid, initiator = "npc" } }
    Tr().forQuest(q, result)
    return ch(fid).trust - trust
end

function T.early_and_mid_penalties_grow_with_the_tier()
    local p, ps = setup()
    toDay(40)                                              -- 중반
    H.eq(outcome(ps, "ray", 1, "failed", 50), -1, "a small favour let down costs little")
    H.eq(outcome(ps, "ray", 4, "failed", 50), -4, "a big one costs more")
    H.eq(outcome(ps, "ray", 3, "ignored", 50), -2)
    H.eq(outcome(ps, "ray", 5, "declined", 50), -3)
    H.eq(outcome(ps, "ray", 3, "completed", 50), 3, "gains are as before below 60")
    -- 끄면 예전 표 (작은 부탁일수록 크게)
    SandboxVars.StoryEngine.TrustUpkeep = false
    H.eq(outcome(ps, "ray", 1, "failed", 50), -5)
    H.eq(outcome(ps, "ray", 4, "failed", 50), -2)
end

function T.the_first_month_is_still_gentle()
    local p, ps = setup()
    H.eq(outcome(ps, "ray", 2, "failed", 50), -1, "half of -2")
    H.eq(outcome(ps, "ray", 1, "declined", 50), -1, "never less than one")
end

function T.trust_cuts_deeper_the_higher_it_is()
    local p, ps = setup()
    toDay(100)                                             -- 후반: 실패 -2/-4/-6/-8/-10
    H.eq(outcome(ps, "ray", 3, "failed", 50), -6)
    H.eq(outcome(ps, "ray", 3, "failed", 65), -9, "x1.5 from 60")
    H.eq(outcome(ps, "ray", 3, "failed", 85), -12, "x2 from 80")
    H.eq(outcome(ps, "ray", 2, "declined", 85), -4)
    -- 일거리 실패도
    ch("ray").trust = 85
    H.eq(Tr().pain("ray", ps.key, -4), -8)
    ch("ray").trust = 40
    H.eq(Tr().pain("ray", ps.key, -4), -4)
    H.eq(Tr().pain("ray", ps.key, 3), 3, "gains are not touched here")
    SandboxVars.StoryEngine.TrustUpkeep = false
    H.eq(outcome(ps, "ray", 3, "failed", 85), -6, "off: no multiplier")
end

function T.high_trust_grows_slowly()
    local p, ps = setup()
    local function gain(trust, d, reason)
        ch("doc").trust = trust
        return Tr().apply("doc", d, reason or "volunteer_done", nil, ps.key)
    end
    H.eq(gain(50, 10), 10)
    H.eq(gain(65, 10), 8, "three quarters from 60")
    H.eq(gain(85, 10), 5, "half from 80")
    H.eq(gain(85, 5), 3)
    H.eq(gain(85, 1), 1, "never nothing")
    H.eq(gain(85, 10, "debug"), 10, "debug is exact")
    H.eq(outcome(ps, "doc", 5, "completed", 82), 3, "a finished tier 5 request at 82")
    SandboxVars.StoryEngine.TrustUpkeep = false
    H.eq(gain(85, 10), 10)
end

function T.high_trust_cools_unless_you_do_things_for_them()
    local p, ps = setup()
    local online = { [ps.key] = true }
    ch("ray").trust = 85
    -- 날마다 말을 걸어도 일이 없으면 소용없다
    for day = 1, 4 do
        Tr().touch("ray", ps.key)
        Tr().daily(StoryEngine.Store.dayIndex(StoryEngine.Sensor.now().dayKey), online)
        H.advanceDays(1)
    end
    H.eq(ch("ray").trust, 85, "four days without a deed are fine")
    H.eq(Tr().upkeepInfo("ray").idle, 4)
    H.eq(Tr().upkeepInfo("ray").limit, 4)
    for day = 5, 7 do
        Tr().touch("ray", ps.key)
        Tr().daily(StoryEngine.Store.dayIndex(StoryEngine.Sensor.now().dayKey), online)
        H.advanceDays(1)
    end
    H.eq(ch("ray").trust, 82, "then one a day, talk or no talk")
    local last = ch("ray").messages[#ch("ray").messages]
    H.eq(last.reason, "upkeep")
    -- 일을 해 주면 다시 센다
    Tr().deed("ray", ps.key)
    Tr().daily(StoryEngine.Store.dayIndex(StoryEngine.Sensor.now().dayKey), online)
    H.eq(ch("ray").deedIdle, 0)
    H.eq(ch("ray").trust, 82)
    -- 60~79: 7일 뒤부터 이틀에 하나
    ch("doc").trust = 70
    ch("doc").deedIdle = 0                                 -- 위에서 흐른 날은 빼고 센다
    for day = 1, 11 do Tr().daily(1000 + day, online) end
    H.eq(ch("doc").trust, 68, "day 8 and day 10")
    -- 60 아래는 예전 식음 (연락만 해도 안 식는다, 바닥 있음)
    ch("pike").trust = 55
    for day = 1, 20 do
        Tr().touch("pike", ps.key)
        local today = StoryEngine.Store.dayIndex(StoryEngine.Sensor.now().dayKey)
        Tr().daily(today, online)
        H.advanceDays(1)
    end
    H.eq(ch("pike").trust, 55, "below 60 a word now and then is enough")
    H.eq(Tr().upkeepInfo("pike"), nil)
    -- 아무도 접속하지 않은 날은 세지 않는다
    ch("hunter").trust = 90
    for day = 1, 10 do Tr().daily(2000 + day, {}) end
    H.eq(ch("hunter").trust, 90)
end

function T.finishing_things_counts_as_a_deed()
    local p, ps = setup()
    local today = StoryEngine.Store.dayIndex(StoryEngine.Sensor.now().dayKey)
    -- 부탁을 끝냄
    outcome(ps, "ray", 2, "completed", 85)
    H.eq(ch("ray").deedDay, today)
    -- 거절은 일이 아니다
    outcome(ps, "doc", 2, "declined", 85)
    H.eq(ch("doc").deedDay, nil)
    -- 일거리, 위기에서 편듦
    Tr().apply("pike", 4, "volunteer_done", nil, ps.key)
    H.eq(ch("pike").deedDay, today)
    Tr().apply("guard", 2, "crisis_chosen")
    H.eq(ch("guard").deedDay, today)
    -- 말로 오른 것, 파급은 일이 아니다
    Tr().apply("hunter", 1, "spill_up", nil, ps.key)
    H.eq(ch("hunter").deedDay, nil)
    -- 선물 보급을 챙긴 것도 일이 아니다
    ch("casey").trust = 85
    Tr().forQuest({ id = "QG", kind = "supply_drop", tier = 1, target = ps.key, origin = { faction = "casey" } }, "completed")
    H.eq(ch("casey").deedDay, nil)
end

function T.a_small_gift_is_not_enough_for_a_close_friend()
    local p, ps = setup()
    local Life = StoryEngine.Life
    local today = StoryEngine.Store.dayIndex(StoryEngine.Sensor.now().dayKey)
    local function beans(n)
        local ids = {}
        for _ = 1, n do ids[#ids + 1] = H.give(p, "Base.TinnedBeans"):getID() end
        return ids
    end
    -- 그저 아는 사이: 작은 지원도 일이다
    ch("doc").trust = 50
    H.ok(Life.donate(p, "doc", beans(4)))                  -- 가치 6: 신뢰 1단계
    H.eq(ch("doc").deedDay, today)
    -- 아주 가까운 사이: 작은 지원은 형편을 도운 것일 뿐
    ch("ray").trust = 85
    H.ok(Life.donate(p, "ray", beans(4)))
    H.eq(ch("ray").deedDay, nil, "not a deed at 80 and up")
    H.eq(ch("ray").helpDay, today, "but it does count as help in need")
    -- 넉넉히 보내면 일이다 (같은 통에서 가치 15 이상: 2단계)
    H.ok(Life.donate(p, "ray", { H.give(p, "Base.Bullets9mmBox"):getID() }))
    H.eq(ch("ray").deedDay, today)
end

function T.leaving_them_in_need_costs_trust()
    local p, ps = setup()
    local Life = StoryEngine.Life
    local online = { [ps.key] = true }
    ch("ray").trust = 50                                   -- 레이의 핵심 자원은 식량
    Life.npc("ray").res.food = 10
    for day = 1, 3 do Tr().daily(day, online) end
    H.eq(ch("ray").trust, 50, "three days of grace")
    H.eq(ch("ray").lowDays, 3)
    Tr().daily(4, online)
    Tr().daily(5, online)
    H.eq(ch("ray").trust, 48, "then one a day")
    H.eq(ch("ray").messages[#ch("ray").messages].reason, "neglected")
    -- 도우면 다시 센다
    ch("ray").helpDay = 6
    Tr().daily(6, online)
    H.eq(ch("ray").lowDays, 0)
    H.eq(ch("ray").trust, 48)
    -- 형편이 나아지면 끝
    Life.npc("ray").res.food = 30
    Tr().daily(7, online)
    H.eq(ch("ray").lowDays, nil)
    -- 처음 값 아래로는 내리지 않는다 (모르는 사이를 벌주지 않는다)
    ch("guard").trust = 10                                 -- 처음 값 10
    Life.npc("guard").res.safety = 5
    for day = 10, 20 do Tr().daily(day, online) end
    H.eq(ch("guard").trust, 10)
    -- 목록에 실려 간다
    Life.npc("ray").res.food = 10
    Tr().daily(30, online)
    local row
    for _, n in ipairs(Life.list(ps.key)) do if n.id == "ray" then row = n end end
    H.eq(row.lowDays, 1)
end

return T
