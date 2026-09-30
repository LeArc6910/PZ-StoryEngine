-- 샌드박스 세부 설정 (Tuning.lua: 난이도 프리셋, 모듈 상수 적용, 배율 hook)
local T = {}

local Tuning = function() return StoryEngine.Tuning end
local function set(values)
    for k, v in pairs(values) do SandboxVars.StoryEngine[k] = v end
    Tuning().apply()
end

function T.defaults_keep_the_old_constants()
    H.eq(Tuning().difficulty(), 1, "custom by default")
    H.eq(StoryEngine.Projects.GOAL, 1000)
    H.eq(StoryEngine.Projects.DONATE_CAP, 100)
    H.eq(StoryEngine.Social.CONTACT_GAP[1], 240)
    H.eq(StoryEngine.Social.CONTACT_GAP[2], 360)
    H.eq(StoryEngine.Social.SCENE_GAP[1], 300)
    H.eq(StoryEngine.Social.SCENE_GAP[2], 420)
    H.eq(StoryEngine.Banter.GAP_MIN, 180)
    H.eq(StoryEngine.Hunt.SIZE_BY_STAGE[3], 60)
    H.eq(StoryEngine.ALife.ATTACK_SIZE[2], 5)
    H.eq(StoryEngine.ALife.AUTO_TRUST, 70)
    H.eq(StoryEngine.Specialty.TIER_MIN[1], 40)
    H.eq(StoryEngine.Specialty.COOLDOWN_DAYS.guard, 7)
    H.eq(StoryEngine.Store.STAGE_DAYS[1], 31)
    H.eq(StoryEngine.Store.STAGE_DAYS[2], 91)
    H.eq(StoryEngine.Trade.FREE_CHANCE, 35)
    H.eq(StoryEngine.Director.HELI_GAP_MIN, 5 * 1440)
    H.eq(StoryEngine.Quests.deliverMinutes(1), 72 * 60)
    H.eq(StoryEngine.Quests.deadlineMinutes(100), 58 * 60)
    H.eq(StoryEngine.Radio.channel("ray").trust, 30, "starting trust unchanged")
end

function T.preset_overrides_individual_values_without_compounding()
    set({ Difficulty = 4, TrustGainMult = 2, HuntSizeMult = 0.5, ProjectGoal = 300 })
    H.eq(Tuning().get("TrustGainMult"), 0.75, "harsh preset wins")
    H.eq(StoryEngine.Projects.GOAL, 1500)
    H.eq(StoryEngine.Hunt.SIZE_BY_STAGE[1], 30)
    Tuning().apply()
    H.eq(StoryEngine.Hunt.SIZE_BY_STAGE[1], 30, "applying again does not compound")
    H.eq(StoryEngine.Specialty.COOLDOWN_DAYS.guard, 10.5)
    set({ Difficulty = 1 })
    H.eq(Tuning().get("TrustGainMult"), 2, "custom uses the individual value")
    H.eq(StoryEngine.Hunt.SIZE_BY_STAGE[1], 10)
    H.eq(StoryEngine.Hunt.SIZE_BY_STAGE[3], 30)
    H.eq(StoryEngine.Projects.GOAL, 300)
    H.eq(Tuning().get("Extortion"), true, "non-preset option keeps its default")
end

function T.trust_multipliers_skip_debug()
    set({ TrustGainMult = 2, TrustLossMult = 0.5 })
    local Trust = StoryEngine.Trust
    H.eq(Trust.apply("ray", 3, "quest"), 6, "gain doubled")
    H.eq(Trust.apply("ray", -1, "quest"), -1, "a loss stays at least 1")
    H.eq(Trust.apply("ray", -4, "quest"), -2, "loss halved")
    H.eq(Trust.apply("ray", 5, "debug"), 5, "debug unchanged")
    set({ TrustLossMult = 0 })
    H.eq(Trust.apply("ray", -5, "quest"), 0, "no loss at 0")
end

function T.starting_trust_applies_to_new_channels()
    set({ TrustStart = 10 })
    H.eq(StoryEngine.Radio.channel("hunter").trust, 10)
    H.eq(StoryEngine.Radio.channel("ray").trust, 40)
    set({ TrustStart = -30 })
    H.eq(StoryEngine.Radio.channel("rats").trust, 0, "clamped at 0")
    H.eq(StoryEngine.Radio.channel("ray").trust, 40, "existing channel keeps its trust")
end

function T.quest_time_reward_and_price()
    set({ QuestTimeMult = 2, RewardMult = 2 })
    H.eq(StoryEngine.Quests.deliverMinutes(1), 144 * 60)
    H.eq(StoryEngine.Quests.deadlineMinutes(100), 116 * 60)
    H.eq(StoryEngine.Loot.scaled(3), 6)
    set({ RewardMult = 0.5 })
    H.rolls = { 10 }
    H.eq(StoryEngine.Loot.scaled(3), 2, "1.5 rounds up by chance")
    H.rolls = { 90 }
    H.eq(StoryEngine.Loot.scaled(3), 1, "1.5 rounds down by chance")
    H.eq(StoryEngine.Loot.scaled(1), 1, "never below 1")
end

function T.life_loss_multiplier_and_exceptions()
    local Life = StoryEngine.Life
    Life.daily()
    set({ LifeLossMult = 2 })
    H.eq(Life.change("ray", "food", -5, "quest_failed"), -10, "loss doubled")
    H.eq(Life.change("ray", "food", -5, "specialty"), -5, "specialty cost unchanged")
    H.eq(Life.change("ray", "food", 5, "quest"), 5, "gains unchanged")
    set({ LifeLossMult = 0 })
    H.eq(Life.change("ray", "food", -5, "storm"), 0)
end

function T.spillover_off_changes_nobody()
    set({ Spillover = false })
    local before = {}
    for _, f in ipairs(StoryEngine.Factions.list) do before[f.id] = StoryEngine.Radio.channel(f.id).trust end
    StoryEngine.Life.spill("ray", nil, true)
    for _, f in ipairs(StoryEngine.Factions.list) do
        H.eq(StoryEngine.Radio.channel(f.id).trust, before[f.id], "no spill for " .. f.id)
    end
end

function T.fate_cause_choice()
    local Fate = StoryEngine.Fate
    H.ok(Fate.causeOn("story") and Fate.causeOn("starve"), "both by default")
    set({ NpcFateCause = 2 })
    H.ok(Fate.causeOn("story") and not Fate.causeOn("starve"), "story only")
    set({ NpcFateCause = 3 })
    H.ok(not Fate.causeOn("story") and Fate.causeOn("starve"), "running out only")
    set({ NpcFateCause = 1, NpcFate = false })
    H.ok(not Fate.causeOn("story") and not Fate.causeOn("starve"), "off overrides")
end

function T.ai_saver_doubles_the_pace()
    set({ AISaver = true, ContactHours = 4 })
    H.eq(StoryEngine.Social.CONTACT_GAP[1], 420)
    H.eq(StoryEngine.Social.CONTACT_GAP[2], 540)
    H.eq(StoryEngine.Banter.GAP_MIN, 360)
    H.eq(Tuning().saverFactor(), 2)
end

function T.stage_days_stay_ordered()
    set({ StageMidDay = 50, StageLateDay = 20 })
    H.eq(StoryEngine.Store.STAGE_DAYS[1], 50)
    H.eq(StoryEngine.Store.STAGE_DAYS[2], 51, "late after mid")
end

return T
