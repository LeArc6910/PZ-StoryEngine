-- 모든 서버 모듈이 게임 없이 불러와지는지
local T = {}

function T.all_server_modules_load()
    for _, name in ipairs({ "Store", "Sensor", "Radio", "Trust", "Quests", "Trade", "Social", "Stories", "Life",
                            "ALife", "Banter", "Journal", "Director", "Commands", "Value", "Factions", "Specialty" }) do
        H.ok(type(StoryEngine[name]) == "table", "missing module " .. name)
    end
end

function T.hourly_and_minute_events_run_without_players()
    H.fire("EveryOneMinute")
    H.fire("EveryTenMinutes")
    H.fire("EveryHours")
end

return T
