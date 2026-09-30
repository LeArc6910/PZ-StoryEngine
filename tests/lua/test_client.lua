-- 클라이언트 모듈이 불러와지고, 특기 핸들러가 도는지 (UI 는 Dummy)
local T = { __client = true }

function T.client_modules_load()
    H.ok(StoryEngine.Client and StoryEngine.Client.handlers.specSnipe, "specialty handlers registered")
    H.ok(StoryEngine.Client.handlers.lifeList, "life handlers registered")
end

function T.snipe_kills_nearest_outdoor_zombies()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local near = H.newZombie(10005, 10000, true)
    local inside = H.newZombie(10002, 10000, false)
    local far = H.newZombie(10100, 10000, true)
    StoryEngine.Client.handlers.specSnipe({ faction = "hunter", count = 2, minutes = 60, radius = 30, sound = "MSR788Shoot" })
    for _ = 1, 70 do
        H.advance(1)
        for _ = 1, 10 do H.fire("OnTick") end
    end
    H.eq(near.dead, true, "nearest outdoor zombie shot")
    H.eq(inside.dead, false, "not through walls")
    H.eq(far.dead, false, "out of range")
    local done
    for _, c in ipairs(H.toServer or {}) do if c.command == "specSnipeDone" then done = c.args end end
    H.ok(done, "reported to server")
    H.eq(done.kills, 1)
end

local function healDones()
    local n = 0
    for _, c in ipairs(H.toServer or {}) do if c.command == "specHealDone" then n = n + 1 end end
    return n
end

function T.heal_countdown_sends_done_or_cancels()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    StoryEngine.Client.handlers.specHealStart({ faction = "doc", tier = 1 })
    H.realMs = H.realMs + 11000
    for _ = 1, 10 do H.fire("OnTick") end
    H.eq(healDones(), 1)
    StoryEngine.Client.handlers.specHealStart({ faction = "doc", tier = 1 })
    p.x = p.x + 2
    for _ = 1, 10 do H.fire("OnTick") end
    H.realMs = H.realMs + 11000
    for _ = 1, 10 do H.fire("OnTick") end
    H.eq(healDones(), 1, "moving cancels the treatment")
end

function T.comfort_sets_no_fear_window()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    StoryEngine.Client.handlers.specComfort({ faction = "pike", tier = 2, reduce = 0.5, hours = 6 })
    H.ok(p.mod.seNoFearUntil ~= nil, "no-fear window set")
    H.advance(7 * 60)
    for _ = 1, 10 do H.fire("OnTick") end
    H.eq(p.mod.seNoFearUntil, nil, "window ends")
end


function T.broadcast_listen_check_reports_once()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local radio = H.newItem("Base.RadioRed", { classes = { "Radio" } })
    local dd = { on = true, ch = 100000 }
    function radio:getDeviceData()
        return { getIsTurnedOn = function() return dd.on end, getChannel = function() return dd.ch end }
    end
    p.items[#p.items + 1] = radio
    local BC = StoryEngine.BroadcastClient
    H.ok(not BC.listening(p, 105400), "tuned elsewhere")
    StoryEngine.Client.handlers.broadcastAir({ id = "SE-1", freq = 105400, host = "casey", minutes = 3 })
    local function heard()
        local n = 0
        for _, c in ipairs(H.toServer or {}) do if c.command == "broadcastHeard" then n = n + 1 end end
        return n
    end
    H.eq(heard(), 0)
    dd.ch = 105400
    H.fire("EveryOneMinute")
    H.eq(heard(), 1, "heard after tuning in")
    H.fire("EveryOneMinute")
    H.eq(heard(), 1, "reported once")
    dd.on = false
    H.ok(not BC.listening(p, 105400), "radio off")
    for _ = 1, 5 do H.fire("EveryOneMinute") end
    H.eq(BC.current, nil, "stops after the window")
    H.eq(BC.freqText(105400), "105.4")
end


function T.letter_window_text_and_menu()
    local W = StoryEngineLetterWindow
    local body = W.body({ from = "doc", reason = "gift", text = "Take care.\nJune", title = "For you", to = "Gerald", day = 12 })
    H.ok(string.find(body, "Take care. <LINE> June", 1, true), body)
    H.ok(string.find(body, "For you", 1, true))
    H.ok(string.find(body, "IGUI_StoryEngine_Letter_To|Gerald|12", 1, true))
    local fallback = W.body({ from = "doc", reason = "farewell" })
    H.ok(string.find(fallback, "IGUI_StoryEngine_Letter_Fallback_farewell|", 1, true), "prepared letter when AI failed")
    H.ok(string.find(W.body({ from = "doc", reason = "gift", writing = true }), "Letter_Writing", 1, true))
    local letter = H.newItem("StoryEngine.Letter")
    local beans = H.newItem("Base.TinnedBeans")
    H.eq(W.letterOf({ beans, { items = { letter } } }), letter, "stacked entry")
    H.eq(W.letterOf({ beans }), nil)
end

return T
