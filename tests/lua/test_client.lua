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

-- A-Life NPC 는 좀비 목록에 섞여 있지만 저격하지 않는다 (2026-10-07)
function T.snipe_skips_alife_npcs()
    H.addPlayer("tester", "Gerald", "Kar")
    local npc = H.newZombie(10002, 10000, true)
    npc.mod.ProjectALifeUID = "actor-1"
    local tagged = H.newZombie(10003, 10000, true)
    function tagged:GetVariable(name) return name == "ALifeUID" and "actor-2" or "" end
    local zed = H.newZombie(10010, 10000, true)
    StoryEngine.Client.handlers.specSnipe({ faction = "hunter", count = 3, minutes = 60, radius = 30 })
    for _ = 1, 70 do
        H.advance(1)
        for _ = 1, 10 do H.fire("OnTick") end
    end
    H.eq(npc.dead, false, "A-Life NPC (modData) left alone")
    H.eq(tagged.dead, false, "A-Life NPC (animation variable) left alone")
    H.eq(zed.dead, true, "the real zombie behind them is shot")
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

function T.heal_ignores_bleeding_but_not_new_wounds()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    p.hp = 80
    p.parts = { H.newBodyPart("ForeArm_L", { cut = true, bleed = 5 }), H.newBodyPart("Hand_R") }
    -- 출혈로 체력이 서서히 줄어도 끊기지 않는다 (2026-09-30 버그)
    StoryEngine.Client.handlers.specHealStart({ faction = "doc", tier = 1 })
    for _ = 1, 5 do p.hp = p.hp - 1; H.fire("OnTick") end
    H.realMs = H.realMs + 11000
    for _ = 1, 10 do H.fire("OnTick") end
    H.eq(healDones(), 1, "bleeding alone does not cancel")
    -- 새 상처가 생기면 끊긴다
    StoryEngine.Client.handlers.specHealStart({ faction = "doc", tier = 1 })
    p.parts[2].scratch = true
    for _ = 1, 10 do H.fire("OnTick") end
    H.realMs = H.realMs + 11000
    for _ = 1, 10 do H.fire("OnTick") end
    H.eq(healDones(), 1, "a new wound cancels")
    -- 크게 맞으면 끊긴다
    StoryEngine.Client.handlers.specHealStart({ faction = "doc", tier = 1 })
    p.hp = p.hp - 20
    for _ = 1, 10 do H.fire("OnTick") end
    H.realMs = H.realMs + 11000
    for _ = 1, 10 do H.fire("OnTick") end
    H.eq(healDones(), 1, "a big hit cancels")
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


function T.item_tooltip_lines()
    StoryEngine.Value.cache["Base.Hammer"] = { category = "tools", value = 8 }
    StoryEngine.Cache.channels = { guard = { gone = "dead" } }
    local lines = StoryEngine.ItemTooltip.lines(H.newItem("Base.Hammer"))
    H.eq(#lines, 3)
    H.ok(string.find(lines[1][1], "IGUI_StoryEngine_Tip_Trade|IGUI_StoryEngine_Cat_tools|8", 1, true), lines[1][1])
    H.ok(string.find(lines[2][1], "IGUI_StoryEngine_Tip_Wanted|", 1, true))
    H.ok(not string.find(lines[2][1], "Whitaker", 1, true), "gone contacts left out: " .. lines[2][1])
    H.ok(string.find(lines[3][1], "IGUI_StoryEngine_Life_Res_safety", 1, true), lines[3][1])
    StoryEngine.Value.cache["Base.Rock"] = { category = "misc", value = 0.2 }
    H.eq(#StoryEngine.ItemTooltip.lines(H.newItem("Base.Rock")), 0)
    -- 등급이 있으면 종류와 함께 보인다 (2026-10-07)
    StoryEngine.Value.cache["Base.Saw"] = { category = "tools", value = 8, tier = 3 }
    local saw = StoryEngine.ItemTooltip.lines(H.newItem("Base.Saw"))
    H.ok(string.find(saw[1][1], "IGUI_StoryEngine_Tip_CatTier|IGUI_StoryEngine_Cat_tools|3", 1, true), saw[1][1])
end


function T.radio_overhead_splits_into_timed_lines()
    local C = StoryEngine.Client
    local parts = C.splitOverhead("Hold still. I'm walking you through it. First, press on the wound hard! Then wrap it.", 40)
    H.eq(parts[1], "Hold still. I'm walking you through it.", "short sentences join up to the limit")
    H.eq(parts[2], "First, press on the wound hard!")
    H.eq(parts[#parts], "Then wrap it.")
    H.eq(#C.splitOverhead("no punctuation at all", 150), 1)
    H.addPlayer("tester", "Gerald", "Kar")
    C.overheadQueue = {}
    C.handlers.radioOverhead({ faction = "doc", text = "Hold still. Breathe." })
    H.eq(#C.overheadQueue, 1, "short reply stays one line")
    H.ok(string.find(C.overheadQueue[1].text, "] Hold still. Breathe.", 1, true), C.overheadQueue[1].text)
    for _ = 1, 3 do H.fire("OnTick") end
    H.eq(#C.overheadQueue, 0, "shown")
end


-- AI 없이 쓴 일기(여러 문장)와 새 인자 종류 (Lines.lua, 2026-10-03)
function T.renders_sentence_lists_and_npc_names()
    local UI = StoryEngine.UI
    local text = UI.textOf({ lts = { { key = "IGUI_A" }, { key = "IGUI_B" } } })
    H.ok(string.find(text, "IGUI_A", 1, true) and string.find(text, "IGUI_B", 1, true), text)
    local npc = UI.render({ key = "IGUI_X", args = { { t = "npc", v = "doc" }, { t = "key", v = "IGUI_Y" } } })
    H.ok(string.find(npc, "IGUI_Y", 1, true), npc)
    H.ok(StoryEngine.Client.handlers.tradeOptions, "trade menu handler")
end

-- 간소화 무전 창 (MiniRadio.lua): 대화만 시간순으로 담는다 (2026-10-07)
function T.mini_radio_feed_keeps_only_talk()
    H.addPlayer("tester", "Gerald", "Kar")
    local Mini = StoryEngineMiniRadio
    Mini.feed = {}
    StoryEngine.Client.handlers.radioMessage({ faction = "ray", msg = { n = 1, from = "npc", text = "Morning.", clock = "08:00" } })
    StoryEngine.Client.handlers.radioMessage({ faction = "ray", msg = { n = 2, from = "system", trust = 1, reason = "x" } })
    StoryEngine.Client.handlers.radioMessage({ faction = "doc", msg = { n = 1, from = "player", name = "Gerald", text = "Hi doc" } })
    StoryEngine.Client.handlers.radioMessage({ faction = "ray", msg = { n = 1, from = "npc", text = "dup" } })
    H.eq(#Mini.feed, 2, "npc and player lines, no system line, no duplicate")
    H.ok(string.find(Mini.line(Mini.feed[1]), "Morning.", 1, true))
    H.ok(string.find(Mini.line(Mini.feed[2]), "Gerald", 1, true))
    for i = 1, 50 do
        StoryEngine.Client.handlers.radioMessage({ faction = "casey", msg = { n = i, from = "npc", text = "m" .. i } })
    end
    H.eq(#Mini.feed, Mini.MAX, "keeps the latest only")
end

return T
