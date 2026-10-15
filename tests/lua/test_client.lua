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

-- 특기 퀵 메뉴 (QuickSpecialty.lua, 2026-10-07)
local function fakeMenu()
    local m = { options = {}, subs = {} }
    function m:addOption(name, target, fn) local o = { name = name, target = target, fn = fn }; self.options[#self.options + 1] = o; return o end
    function m:addSubMenu(opt, sub) opt.sub = sub end
    return m
end

function T.quick_specialty_menu_lists_contacts()
    H.addPlayer("tester", "Gerald", "Kar")
    local Q = StoryEngineQuickSpecialty
    StoryEngine.Cache.life = {
        { id = "hunter", spec = { tier = 2 }, res = {} },
        { id = "doc", spec = { tier = 1, reason = "cooldown", wait = 5 }, res = {} },
        { id = "ray", spec = { tier = 1 }, res = { food = 50 } },
        { id = "casey", spec = { tier = 1 }, res = { food = 10, medical = 50, safety = 50, morale = 50 } },
    }
    ISContextMenu = { getNew = function() return fakeMenu() end }
    ISToolTip = { new = function() return { initialise = function() end, setVisible = function() end } end }
    local m = fakeMenu()
    Q.fill(m)
    H.eq(#m.options, 4)
    H.ok(not m.options[1].notAvailable, "hank is ready")
    H.ok(m.options[2].notAvailable, "june is on cooldown")
    H.ok(m.options[3].sub and #m.options[3].sub.options >= 1, "ray asks who gets the supplies")
    H.toServer = {}
    m.options[1].fn(m.options[1].target)
    local sent = nil
    for _, c in ipairs(H.toServer) do if c.command == "specialtyRequest" then sent = c.args end end
    H.ok(sent and sent.faction == "hunter", "requests the specialty")
    -- 목록이 없으면 받은 뒤 연다
    StoryEngine.Cache.life = {}
    Q.open()
    H.ok(Q.pending, "waits for the camp list")
end

-- 2차 특기 메뉴 (2026-10-09): 쓰기 + 약 조제 하위 메뉴 + 고르기
function T.second_specialty_menu()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    ISContextMenu = { getNew = function() return fakeMenu() end }
    ISToolTip = { new = function() return { initialise = function() end, setVisible = function() end } end }
    for _ = 1, 7 do H.give(p, "Base.Plantain") end
    local n = { id = "doc", spec2 = { unlocked = true, options = { "illness", "pain", "pharmacy" },
                                     ready = { true, true, true }, choice = "pharmacy", change = 100 } }
    local m = fakeMenu()
    StoryEngineLifePanel.fillSpec2(m, n)
    H.eq(#m.options, 2, "use + switch")
    local meds = m.options[1].sub
    H.ok(meds, "pharmacy picks a medicine")
    H.ok(meds.options[1].notAvailable, "header line")
    local single, double = meds.options[2], meds.options[3]
    H.ok(not single.notAvailable, "7 herbs: one vitamin pack")
    H.ok(double.notAvailable, "not enough for two")
    H.toServer = {}
    single.fn(single.target)
    H.eq(H.toServer[#H.toServer].command, "spec2Use")
    H.eq(H.toServer[#H.toServer].args.med, "vitamins")
    local pick = m.options[2].sub
    H.ok(pick.options[3].notAvailable, "current pick")
    H.ok(pick.options[1].notAvailable, "switching waits 30 days")
    -- 아직 고르지 않음: 고르기만
    n.spec2.choice, n.spec2.change = nil, 0
    m = fakeMenu()
    StoryEngineLifePanel.fillSpec2(m, n)
    H.eq(#m.options, 1)
    H.ok(not m.options[1].sub.options[1].notAvailable, "can pick")
end

-- 특기 아이콘 (2026-10-07): 접힌 버튼의 숫자와 펼친 줄
function T.quick_dock_rows_and_hotkey()
    H.addPlayer("tester", "Gerald", "Kar")
    local Q = StoryEngineQuickSpecialty
    local life = {
        { id = "hunter", spec = { tier = 2 }, res = {} },
        { id = "doc", spec = { tier = 1, reason = "cooldown", wait = 5 }, res = {} },
        { id = "guard", spec = { tier = 0, reason = "low_trust" }, res = {} },
        { id = "pike", fate = "dead", res = {} },
        { id = "ray", spec = { tier = 1 }, res = { food = 50 } },
    }
    local rows = Q.rowsOf(life)
    H.eq(#rows, 4, "dead contacts get no row")
    H.eq(Q.readyCount(rows), 2, "hank and ray are ready")
    H.eq(rows[1].id, "hunter")
    H.ok(rows[1].usable and string.find(rows[1].left, "**", 1, true), "tier stars next to the name")
    H.ok(not rows[2].usable and rows[2].right ~= rows[1].right, "doc shows the wait")
    H.ok(string.find(rows[3].tip, "IGUI_StoryEngine_Spec_Error_low_trust", 1, true), "why it is blocked")
    H.ok(not Q.dockShown(), "nothing built in tests")
    -- 단축키는 아이콘을 펼친다
    local toggled = 0
    local old = Q.toggleDock
    Q.toggleDock = function() toggled = toggled + 1 end
    Keyboard = { KEY_K = 37, KEY_SEMICOLON = 39, KEY_APOSTROPHE = 40 }
    ISChat = { focused = false }
    StoryEngineMiniRadio.onKey(Keyboard.KEY_APOSTROPHE)
    Q.toggleDock = old
    H.eq(toggled, 1)
end

-- 2차 특기 아이콘 (2026-10-09): 2차가 열린 NPC 만, 고르지 않았으면 "고르기"
function T.second_specialty_dock_rows()
    H.addPlayer("tester", "Gerald", "Kar")
    local Q = StoryEngineQuickSpecialty
    local life = {
        { id = "hunter", spec2 = { unlocked = true, choice = "game" } },
        { id = "doc", spec2 = { unlocked = true, choice = "pharmacy", reason = "cooldown", wait = 30 } },
        { id = "ray", spec2 = { unlocked = true } },
        { id = "pike", spec2 = { unlocked = false } },
        { id = "rats", fate = "dead", spec2 = { unlocked = true, choice = "bodyguard" } },
    }
    H.ok(Q.anyUnlocked(life))
    local rows = Q.rows2Of(life)
    H.eq(#rows, 3, "locked and dead contacts get no row")
    H.ok(rows[1].usable and not rows[1].menu, "hank: use right away")
    H.ok(not rows[2].usable and rows[2].menu, "doc on cooldown, pharmacy opens a menu")
    H.ok(rows[3].usable and rows[3].menu, "ray: pick first")
    H.eq(Q.readyCount(rows), 2)
    H.ok(not Q.anyUnlocked({ { id = "pike", spec2 = { unlocked = false } } }))
    H.ok(StoryEngineQuickDock2.rows ~= StoryEngineQuickDock.rows, "own rows")
    -- 특기 아이콘이 떠 있어도 2차 아이콘은 따로 (예전: 상속으로 특기 아이콘을 2차 아이콘으로 보고 숨기면 지웠다)
    local removed = false
    -- 게임의 derive 처럼 자식 클래스에 없는 필드는 부모에서 읽는다 (테스트 틀의 derive 는 그렇지 않아서 직접)
    local mt = getmetatable(StoryEngineQuickDock2)
    setmetatable(StoryEngineQuickDock2, { __index = StoryEngineQuickDock })
    StoryEngineQuickDock.instance = { removeFromUIManager = function() removed = true end }
    H.ok(not Q.dock2Shown(), "the first dock is not the second")
    Q.hideDock2()
    H.ok(not removed, "hiding the second dock leaves the first alone")
    StoryEngineQuickDock.instance = nil
    setmetatable(StoryEngineQuickDock2, mt)
end

-- 2차 특기 2단계 클라이언트 효과 (2026-10-09): 포격 처치, 위장, 소음기
function T.evac_lands_on_free_floor_inside_the_safehouse()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local h = StoryEngine.Client.handlers
    local SC = StoryEngine.SpecClient
    local squares = {}
    local function sq(x, y, free, room)
        squares[x .. "," .. y] = { getX = function() return x end, getY = function() return y end, getZ = function() return 0 end,
            isFree = function() return free end, isSolidTrans = function() return false end,
            getRoom = function() return room and {} or nil end }
    end
    local realCell = H.cell.getGridSquare
    H.cell.getGridSquare = function(_, x, y, z) return squares[x .. "," .. y] end
    -- 아직 칸이 안 불러짐
    local got, why = SC.findLanding(H.cell, 100, 100, 0, { 98, 98, 102, 102 })
    H.eq(why, "unloaded")
    sq(100, 100, false, true)       -- 가운데는 벽
    sq(101, 100, true, false)       -- 바깥 칸(방 아님)
    sq(99, 102, true, true)         -- 방 안 빈 칸
    sq(105, 100, true, true)        -- 세이프하우스 밖
    got = SC.findLanding(H.cell, 100, 100, 0, { 98, 98, 102, 102 })
    H.eq(got:getX(), 99, "room square first")
    -- 사각형이 없으면 둘레에서 가장 가까운 방 안 칸
    squares["99,102"] = nil
    got = SC.findLanding(H.cell, 100, 100, 0, nil)
    H.eq(got:getX(), 105)
    -- 받은 뒤 틱에서 그 칸으로 옮긴다
    local moves = {}
    function p:teleportTo(x, y, z) moves[#moves + 1] = { x, y, z } end
    function p:getCurrentSquare() return nil end
    h.spec2Teleport({ x = 100, y = 100, z = 0, rect = { 98, 98, 102, 102 } })
    H.eq(moves[1][1], 100.5)
    for _ = 1, 10 do H.fire("OnTick") end
    H.eq(moves[2] and moves[2][1], 101.5, "moved onto the free floor")
    H.eq(SC.landing, nil)
    H.cell.getGridSquare = realCell
end

function T.second_specialty_client_effects()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local h = StoryEngine.Client.handlers
    local near, far = H.newZombie(10003, 10000), H.newZombie(10050, 10000)
    h.spec2Strike({ x = 10000, y = 10000, radius = 10 })
    H.ok(near.dead and not far.dead, "only inside the radius")
    -- 위장: 나를 쫓던 좀비의 표적을 지운다
    local z = H.newZombie(10004, 10000)
    z.target = p
    function z:getTarget() return self.target end
    function z:setTarget(t) self.target = t end
    function z:isUseless() return self.useless == true end
    function z:setUseless(v) self.useless = v end
    function p:isSprinting() return false end
    function p:getStats() return { set = function() end } end
    h.spec2Fx({ kind = "camo", minutes = 240 })
    StoryEngine.SpecClient.fx[#StoryEngine.SpecClient.fx].untilH = 1e9
    local camo = StoryEngine.SpecClient.fx[#StoryEngine.SpecClient.fx]
    H.eq(camo.kind, "camo")
    for _ = 1, 10 do H.fire("OnTick") end
    H.ok(z.useless, "nearby zombie stops noticing me")
    H.eq(z.target, nil)
    camo.untilH = 0
    for _ = 1, 10 do H.fire("OnTick") end
    H.eq(z.useless, false, "back to normal when camo ends")
    -- 소음기: 내 총 소음이 줄고, 끝나면 되돌아온다
    local gun = H.newItem("Base.Pistol")
    gun.__classes = { HandWeapon = true }
    gun.r, gun.v = 100, 80
    function gun:isRanged() return true end
    function gun:getSoundRadius() return self.r end
    function gun:setSoundRadius(v) self.r = v end
    function gun:getSoundVolume() return self.v end
    function gun:setSoundVolume(v) self.v = v end
    p.items[#p.items + 1] = gun
    StoryEngine.SpecClient.suppress(p, true)
    H.eq(gun.r, 30)
    StoryEngine.SpecClient.suppress(p, false)
    H.eq(gun.r, 100, "restored")
    H.eq(gun:getModData().seSupOrig, nil)
end

-- 메인 창 아이콘 (2026-10-07): 창이 닫혀 있는 동안 새로 온 NPC 무전을 센다
function T.main_icon_counts_unread_npc_messages()
    H.addPlayer("tester", "Gerald", "Kar")
    local M = StoryEngineMainIcon
    M.unread = 0
    local saved = StoryEngineMainWindow.instance
    StoryEngineMainWindow.instance = nil
    local h = StoryEngine.Client.handlers
    h.radioMessage({ faction = "ray", msg = { n = 9001, from = "npc", text = "hi" } })
    h.radioMessage({ faction = "ray", msg = { n = 9002, from = "player", name = "Gerald", text = "yo" } })
    h.radioMessage({ faction = "ray", msg = { n = 9003, from = "system", text = "x" } })
    H.eq(M.unread, 1, "only contact lines count")
    StoryEngineMainWindow.instance = { refresh = function() end }
    h.radioMessage({ faction = "ray", msg = { n = 9004, from = "npc", text = "again" } })
    H.eq(M.unread, 1, "not while the window is open")
    StoryEngineMainWindow.instance = saved
    H.ok(StoryEngineQuickDock.GRIP == StoryEngineFloatBar.GRIP, "the skills icon shares the bar")
end

-- 번역이 있는지 물을 때는 빈 인자를 채운다: 인자 없이 물으면 %1 이 든 문장마다 게임이 경고를 남겼다 (2026-10-10)
function T.translation_checks_do_not_format_without_arguments()
    local real = getTextOrNull
    local bare = 0
    getTextOrNull = function(key, ...)
        if select("#", ...) == 0 then bare = bare + 1 end
        return key ~= "IGUI_Missing" and key or nil
    end
    local UI = StoryEngine.UI
    H.eq(UI.hasText("IGUI_Anything"), true)
    H.eq(UI.hasText("IGUI_Missing"), false)
    H.eq(UI.render({ key = "IGUI_Line", alt = "IGUI_Alt", args = { { t = "num", v = 3 } } }), "IGUI_Line|3")
    H.eq(UI.render({ key = "IGUI_Missing", alt = "IGUI_Alt", args = { { t = "num", v = 3 } } }), "IGUI_Alt|3")
    getTextOrNull = real
    H.eq(bare, 0, "never asked without arguments")
end

-- 놓치면 NPC 를 잃을 수 있는 퀘스트가 열려 있으면 무전 아이콘에 "!" (2026-10-10)
function T.main_icon_marks_critical_quests()
    H.addPlayer("tester", "Gerald", "Kar")
    local M = StoryEngineMainIcon
    local saved = StoryEngineMainWindow.instance
    StoryEngineMainWindow.instance = nil
    M.unread, M.critical, M.criticalSeen = 0, 0, 0
    local head = { setTitle = function(self, t) self.title = t end, setWidth = function() end }
    local icon = { head = head, refresh = M.refresh, setBarWidth = function() end }
    M.instance = icon
    local h = StoryEngine.Client.handlers
    local function quest(id, risk)
        return { id = id, kind = "deliver", state = "accepted", need = {}, origin = { faction = "dewey" }, risk = risk }
    end
    h.questList({ quests = { quest("Q1"), quest("Q2", { why = "fail", kind = "gone", faction = "dewey" }) } })
    H.eq(M.critical, 1)
    H.ok(string.find(head.title, "!", 1, true), "marked: " .. tostring(head.title))
    H.ok(string.find(head.tooltip, "IGUI_StoryEngine_Float_MainRiskTip|1", 1, true), "the tooltip says why")
    -- 새로 생긴 것이면 누를 때 퀘스트 탭부터, 본 뒤로는 평소처럼 교신 탭
    local opened = {}
    local realOpen = StoryEngineMainWindow.open
    StoryEngineMainWindow.open = function(key) opened[#opened + 1] = key end
    M.onHead(icon)
    M.onHead(icon)
    H.eq(opened[1], "quests")
    H.eq(opened[2], "radio")
    StoryEngineMainWindow.open = realOpen
    -- 끝나면 사라진다
    h.questList({ quests = { quest("Q1") } })
    H.eq(M.critical, 0)
    H.ok(not string.find(head.title, "!", 1, true), "cleared")
    M.instance = nil
    StoryEngineMainWindow.instance = saved
end

-- 2026-10-09: MeasureStringX 가 한글 폭을 작게 재서 인물 탭 "가족·곁의 사람" 이 값과 겹쳤다
function T.people_label_width_counts_wide_letters()
    local real = getTextManager
    getTextManager = function()
        return {
            MeasureStringX = function(_, _, s) return #s end,     -- 바이트 수 (한글은 3바이트라도 작게)
            getFontHeight = function() return 20 end,
        }
    end
    local w = StoryEnginePeoplePanel.labelWidth("\234\176\128\236\161\177 ab", UIFont.NewSmall)
    getTextManager = real
    H.ok(w >= 2 * 20 + 3, "two wide letters count as the font height each: " .. tostring(w))
end

-- 게임(Kahlua)에서는 string.byte 가 한글 한 글자의 코드값을 준다: "가족·곁의 사람"
function T.people_label_width_counts_java_chars()
    local wide, keep = StoryEnginePeoplePanel.splitWide({ 44032, 51313, 183, 44273, 51032, 32, 49324, 46988 })
    H.eq(wide, 6, "six hangul letters")
    H.eq(#keep, 2, "the dot and the space are narrow")
end

-- 인물 탭 "큰 이야기" (2026-10-07): 처음부터 지금까지, 이야기별로 묶은 장면
function T.people_tab_main_story_box()
    local P = StoryEnginePeoplePanel
    local realGetText = getText
    getText = function(key, ...)
        local parts = { key }
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        if string.find(key, "IGUI_StoryEngine_Tale_", 1, true) then return "tale " .. string.sub(key, 23) end
        return table.concat(parts, "|")
    end
    local text = P.storyText("ray", { arc = "ray2a", chapter = 2, node = "ray2a_2", final = false, asking = true,
        past = { { arc = "ray1", tone = "good" } },
        path = { { node = "ray_1", day = 1, arc = "ray1" }, { node = "ray_6a", day = 12, arc = "ray1" },
                 { node = "ray2a_1", day = 20, arc = "ray2a" }, { node = "ray2a_2", day = 22, arc = "ray2a" } } })
    H.ok(string.find(text, "IGUI_StoryEngine_People_BigStory", 1, true), "titled")
    local first = string.find(text, "IGUI_StoryEngine_Arc_ray1", 1, true)
    local second = string.find(text, "IGUI_StoryEngine_Arc_ray2a", 1, true)
    H.ok(first and second and first < second, "both stories, oldest first")
    H.ok(string.find(text, "tale ray_1 tale ray_6a", 1, true), "the first story as one paragraph")
    H.ok(string.find(text, "tale ray2a_1%s+<SPACE>%s+<RGB:1,1,0.95>%s+tale ray2a_2"), "the current scene stands out")
    H.ok(not string.find(text, "D12", 1, true), "no day numbers")
    H.ok(string.find(text, "IGUI_StoryEngine_People_Tone_good", 1, true), "how the first story ended")
    H.ok(string.find(text, "IGUI_StoryEngine_People_Asking", 1, true), "asking for help")
    local ended = P.storyText("ray", { arc = "ray1", chapter = 1, node = "ray_6a", final = true, tone = "good", nextDays = 9 })
    H.ok(string.find(ended, "IGUI_StoryEngine_People_NextStory|9", 1, true), "days until the next story")
    local over = P.storyText("ray", { arc = "ray2a", chapter = 2, node = "ray2a_5a", final = true, tone = "good" })
    H.ok(string.find(over, "IGUI_StoryEngine_People_StoryOver", 1, true))
    H.eq(P.storyText("ray", nil), nil)
    getText = realGetText
end

-- 큰 이야기: 곁가지·이어받은 이야기 장 표시, 저장된 서술(AI 곁가지 자리)
function T.people_tab_side_story_labels()
    local P = StoryEnginePeoplePanel
    local text = P.storyText("ray", { arc = "rayx1", chapter = "ep", node = "rayx1_2", final = false,
        path = { { node = "ray3_6a", arc = "ray3", chapter = 3 },
                 { node = "rayx1_1", arc = "rayx1", chapter = "ep", tale = "A dog followed us home.", title = "The Dog" },
                 { node = "rayx1_2", arc = "rayx1", chapter = "ep", tale = "The dog stayed." } } })
    H.ok(string.find(text, "IGUI_StoryEngine_People_Chapter_3", 1, true), "chapter three")
    H.ok(string.find(text, "IGUI_StoryEngine_People_Chapter_ep", 1, true), "side story")
    H.ok(string.find(text, "A dog followed us home.", 1, true), "stored narration is used")
    H.ok(string.find(text, "IGUI_StoryEngine_Arc_Quote|The Dog", 1, true), "stored title is used")
    H.ok(not string.find(text, "IGUI_StoryEngine_People_BigStory", 1, true) == false)
    H.ok(not string.find(P.storyText("ray", { arc = "ray1", node = "ray_1", path = {} }, true), "BigStory", 1, true),
        "no header for an earlier voice")
end


function T.aim_panel_scans_then_fires_at_the_picked_spot()
    H.addPlayer("tester", "Gerald", "Kar")
    local Aim = StoryEngine.Aim
    -- 바닐라 ISPanel 메서드는 틀에 없어 비워 둔다 (창 그리기는 인게임에서)
    for _, m in ipairs({ "initialise", "addToUIManager", "setAlwaysOnTop", "setVisible", "removeFromUIManager", "refresh" }) do
        StoryEngineAimPanel[m] = function() end
    end
    H.toServer = {}
    Aim.start("guard", "artillery")
    H.ok(Aim.active())
    H.eq(H.toServer[#H.toServer].command, "spec2Radar", "asks for the radar as soon as it opens")
    H.eq(H.toServer[#H.toServer].args.r, 240)
    H.ok(string.find(Aim.body(Aim.state), "IGUI_StoryEngine_Aim_Hint", 1, true), "hint before a spot is picked")
    Aim.pick(10060.4, 10000.7)
    local scan = H.toServer[#H.toServer]
    H.eq(scan.command, "spec2Scan")
    H.eq(scan.args.x, 10060)
    StoryEngine.Client.handlers.spec2ScanResult({ faction = "guard", opt = "artillery", x = 10060, y = 10000, dist = 60,
        loaded = true, zombies = 7, density = "high", nearest = 60, ok = true })
    local body = Aim.body(Aim.state)
    H.ok(string.find(body, "IGUI_StoryEngine_Aim_Zombies", 1, true), "zombie count shown")
    H.ok(string.find(body, "IGUI_StoryEngine_Aim_Ok", 1, true))
    StoryEngineAimPanel.instance:onFire()
    local use = H.toServer[#H.toServer]
    H.eq(use.command, "spec2Use")
    H.eq(use.args.faction, "guard")
    H.eq(use.args.y, 10000)
    H.ok(not Aim.active(), "closed after firing")
end

function T.radar_map_coordinates_and_click()
    H.addPlayer("tester", "Gerald", "Kar")
    local Aim = StoryEngine.Aim
    for _, m in ipairs({ "initialise", "addToUIManager", "setVisible", "removeFromUIManager", "refresh" }) do
        StoryEngineAimWindow[m] = function() end
    end
    H.toServer = {}
    Aim.start("guard", "artillery")
    local st = Aim.state
    -- 서버가 본 내 자리가 지도 가운데 (북쪽 위, 동쪽 오른쪽)
    StoryEngine.Client.handlers.spec2RadarResult({ faction = "guard", cx = 10000, cy = 10000, r = 240, range = 240,
        zx = { 100 }, zy = { -50 }, px = {}, py = {}, total = 1, grid = string.rep("1", 256), n = 16 })
    H.eq(st.range, 240)
    local x, y = Aim.toMap(st, 10000, 10000)
    H.eq(x, Aim.MAP / 2)
    H.eq(y, Aim.MAP / 2)
    x, y = Aim.toMap(st, 10240, 9760)
    H.eq(x, Aim.MAP, "east edge")
    H.eq(y, 0, "north edge")
    -- 지도를 누르면 그 자리를 고른다
    local wx, wy = Aim.toWorld(st, Aim.MAP / 2 + 115, Aim.MAP / 2)
    H.near(wx, 10120, 0.5)
    StoryEngineRadarMap.onMouseDown({ state = st }, Aim.MAP / 2 + 115, Aim.MAP / 2 - 115)
    local scan = H.toServer[#H.toServer]
    H.eq(scan.command, "spec2Scan")
    H.eq(scan.args.x, 10120)
    H.eq(scan.args.y, 9880)
    -- 가까이 보기
    Aim.setView(60)
    H.eq(H.toServer[#H.toServer].command, "spec2Radar")
    H.eq(H.toServer[#H.toServer].args.r, 60)
    x = Aim.toMap(st, 10060, 10000)
    H.eq(x, Aim.MAP, "60 tiles is the edge now")
    StoryEngineAimWindow.instance:close()
end


function T.mod_item_names_are_restored_after_eating()
    local IN = StoryEngine.ItemNames
    IN.items = { ["StoryEngine.Food_RayStew"] = { name = "Ray Stew KO", fallback = "Ray's Stew" } }
    local it = { ft = "StoryEngine.Food_RayStew", name = "StoryEngine.Food_RayStew" }
    function it:getFullType() return self.ft end
    function it:getName() return self.name end
    function it:setName(v) self.name = v end
    H.ok(IN.fixItem(it))
    H.eq(it.name, "Ray Stew KO", "full type name replaced by the translation")
    it.name = "Ray's Stew"
    H.ok(IN.fixItem(it), "English fallback replaced too")
    it.name = "My Stew"
    H.ok(not IN.fixItem(it), "a name the player chose is kept")
end

-- 신뢰도 유지 (서버 Trust.lua 1b단계): 거점 탭에 며칠째 해 준 일이 없는지, 형편이 바닥인데 돕지 않았는지
function T.base_tab_shows_trust_upkeep()
    local lines = StoryEngineLifePanel.upkeepLines
    H.eq(#lines({ id = "ray" }), 0, "below 60 there is nothing to keep up")
    local fine = lines({ id = "ray", upkeep = { idle = 1, limit = 4 } })
    H.eq(fine[1][1], "IGUI_StoryEngine_Upkeep_Fine|3")
    local soon = lines({ id = "ray", upkeep = { idle = 4, limit = 4 } })
    H.eq(soon[1][1], "IGUI_StoryEngine_Upkeep_Soon|4")
    local fading = lines({ id = "ray", upkeep = { idle = 6, limit = 4 }, lowDays = 2 })
    H.eq(fading[1][1], "IGUI_StoryEngine_Upkeep_Fading|6")
    H.eq(fading[2][1], "IGUI_StoryEngine_Upkeep_Neglect|2")
    H.eq(#lines({ id = "ray", fate = "dead", upkeep = { idle = 9, limit = 4 } }), 0, "not for the dead")
end

-- 특기 툴팁에 쓰면 드는 자원 (2026-10-11): 거점 탭 버튼·특기 아이콘 줄·우클릭 메뉴·2차 특기
function T.specialty_tooltips_show_the_cost()
    H.addPlayer("tester", "Gerald", "Kar")
    local UI = StoryEngine.UI
    H.eq(UI.specCostText(nil, {}), nil, "an older server sends no cost")
    H.eq(UI.specCostText({ res = "safety", n = 15, min = 20 }, { safety = 62.4 }),
        "IGUI_StoryEngine_Spec_Cost_Now|IGUI_StoryEngine_Life_Res_safety|15|62|20")
    H.eq(UI.specCostText({ res = "food", n = 15 }, nil), "IGUI_StoryEngine_Spec_Cost|IGUI_StoryEngine_Life_Res_food|15")
    local Q = StoryEngineQuickSpecialty
    local rows = Q.rowsOf({
        { id = "hunter", spec = { tier = 3, cost = { res = "safety", n = 15, min = 20 } }, res = { safety = 60 } },
        { id = "doc", spec = { tier = 1, reason = "cooldown", wait = 5 }, res = {} },
    })
    H.ok(string.find(rows[1].tip, "IGUI_StoryEngine_Spec_Cost_Now|IGUI_StoryEngine_Life_Res_safety|15|60|20", 1, true), rows[1].tip)
    H.ok(not string.find(rows[2].tip, "Spec_Cost", 1, true), "no line without a cost")
    local rows2 = Q.rows2Of({
        { id = "hunter", res = { safety = 44 },
          spec2 = { unlocked = true, choice = "game", cost = { res = "safety", n = 20, min = 30 } } },
    })
    H.ok(string.find(rows2[1].tip, "IGUI_StoryEngine_Spec_Cost_Now|IGUI_StoryEngine_Life_Res_safety|20|44|30", 1, true), rows2[1].tip)
end

-- 의회 탭 (2026-10-13, PoliticsClient.lua): 서버가 보낸 상태를 글로, 알림, 작업장에 보낼 물건
function T.council_tab_tells_the_state_of_politics()
    H.addPlayer("tester", "Gerald", "Kar")
    local PC = StoryEngine.PoliticsClient
    local function has(text, key) return string.find(text, key, 1, true) ~= nil end
    H.ok(has(PC.textOf(nil), "IGUI_StoryEngine_Politics_Loading"))
    H.ok(has(PC.textOf({ off = true }), "IGUI_StoryEngine_Politics_Off"))
    H.ok(has(PC.textOf({ era = false }), "IGUI_StoryEngine_Politics_NoEra"))
    H.ok(has(PC.textOf({ era = true, openIn = 9 }), "IGUI_StoryEngine_Politics_OpenIn|9"))
    local d = {
        era = true, on = true,
        blocs = { { id = "field", lean = 30, members = { "ray", "pike" } }, { id = "gun", lean = 0, members = { "guard" } },
                  { id = "market", lean = -25, members = { "rats" } } },
        against = { "guard" },
        bill = { id = "armory", bloc = "market", by = "rats", hours = 30, yes = 5, no = 3, pass = true,
                 gain = { "rats", "hunter" }, lose = { "guard" },
                 rows = { { fid = "ray", bloc = "field", trust = 60, need = 60, yes = true },
                          { fid = "guard", bloc = "gun", trust = 40, need = 70, yes = false } } },
        laws = { { id = "winter", hours = 100, share = 40 }, { id = "vouch", hours = 20, target = "hunter", guarantor = "ray" },
                 { id = "workshop", hours = 200 } },
        workshop = { wait = 0 },
        history = { { id = "truce", pass = false, yes = 3, no = 5, day = 320 } },
        specials = { { id = "memorial", ok = true }, { id = "winter", ok = false, why = "season", wait = 0 },
                     { id = "vouch", ok = true, target = true } },
    }
    local text = PC.textOf(d)
    H.ok(has(text, "IGUI_StoryEngine_Politics_Bloc_field"))
    H.ok(has(text, "+30"), "the leaning shows with its sign")
    H.ok(has(text, "IGUI_StoryEngine_Politics_Against"))
    H.ok(has(text, "IGUI_StoryEngine_Politics_Bill|IGUI_StoryEngine_Bill_armory"))
    H.ok(has(text, "IGUI_StoryEngine_Bill_armory_Desc"))
    H.ok(has(text, "IGUI_StoryEngine_Politics_Forecast|5|3|IGUI_StoryEngine_Politics_Pass"))
    H.ok(has(text, "IGUI_StoryEngine_Politics_Hours|30"))
    H.ok(has(text, "IGUI_StoryEngine_Politics_Days|4"), "long waits in days")
    H.ok(has(text, "IGUI_StoryEngine_Politics_Share|40"))
    H.ok(has(text, "IGUI_StoryEngine_Politics_Vouch"))
    H.ok(has(text, "IGUI_StoryEngine_Politics_Workshop_Hint"))
    H.ok(has(text, "IGUI_StoryEngine_Politics_Failed|IGUI_StoryEngine_Bill_truce|3|5|320"))
    d.bill = nil
    d.nextIn = 6
    H.ok(has(PC.textOf(d), "IGUI_StoryEngine_Politics_NextIn|6"))
    -- 특별 법안 메뉴
    local rows = PC.specialRows(d)
    H.eq(#rows, 3)
    H.ok(rows[1].ok and not rows[2].ok)
    H.ok(has(rows[2].tip, "IGUI_StoryEngine_Politics_Why_season"))
    H.eq(rows[3].target, true)
    -- 알림
    local t, good = PC.noticeText({ kind = "vote", id = "armory", pass = false, yes = 2, no = 6 })
    H.ok(has(t, "IGUI_StoryEngine_Politics_Notice_fail|IGUI_StoryEngine_Bill_armory|2|6"))
    H.eq(good, false)
    H.ok(has(PC.noticeText({ kind = "post", got = 3, taken = 1 }), "IGUI_StoryEngine_Politics_Notice_post|3|1"))
    H.ok(has(PC.noticeText({ kind = "ended", id = "truce", why = "broken" }), "IGUI_StoryEngine_Politics_Notice_broken"))
    StoryEngine.Client.handlers.politicsState({ politics = d })
    H.eq(StoryEngine.Cache.politics, d)
    H.toServer = {}
    StoryEngine.Client.handlers.politicsNotice({ kind = "meal" })
    H.eq(H.toServer[#H.toServer].command, "politicsState", "a notice asks for the fresh state")
    StoryEngine.Client.handlers.politicsResult({ what = "workshop", ok = false, error = "wait", wait = 12 })
    StoryEngine.Client.handlers.politicsResult({ what = "propose", ok = false, error = "busy" })
    -- 작업장에 보낼 수 있는 물건: 닳은 도구·무기·총만
    StoryEngine.Value.cache["Base.Axe"] = { category = "tools", value = 8, tier = 2 }
    StoryEngine.Value.cache["Base.Apple"] = { category = "food", value = 1, tier = 1 }
    local worn = H.newItem("Base.Axe")
    function worn:getCondition() return 3 end
    function worn:getConditionMax() return 10 end
    local fine = H.newItem("Base.Axe")
    function fine:getCondition() return 10 end
    function fine:getConditionMax() return 10 end
    local apple = H.newItem("Base.Apple")
    H.ok(PC.workshopItem(worn))
    H.ok(not PC.workshopItem(fine))
    H.ok(not PC.workshopItem(apple))
    H.eq(StoryEngineMainWindow.TABS[#StoryEngineMainWindow.TABS], "politics")
end

function T.council_tab_lobby_menu()
    H.addPlayer("tester", "Gerald", "Kar")
    local PC = StoryEngine.PoliticsClient
    local d = { era = true, on = true, blocs = {},
        bill = { id = "armory", bloc = "market", by = "rats", hours = 30, yes = 1, no = 2, pass = false, lobbyLeft = 2,
                 lobby = { guard = { how = "promise", side = "for", who = "Gerald Kar" } },
                 rows = { { fid = "ray", bloc = "field", trust = 65, need = 60, yes = true },
                          { fid = "doc", bloc = "field", trust = 45, need = 60, yes = false },
                          { fid = "guard", bloc = "gun", trust = 70, need = 70, yes = true } } } }
    local rows = PC.lobbyRows(d)
    H.eq(#rows, 3)
    H.ok(rows[1].persuade.ok and rows[1].promise.ok, "ray can be persuaded or promised")
    H.ok(not rows[2].persuade.ok and rows[2].promise.ok, "doc trusts too little to be persuaded")
    H.ok(string.find(rows[2].persuade.tip, "IGUI_StoryEngine_Politics_Lobby_Error_trust|60", 1, true))
    H.ok(rows[3].done and not rows[3].promise.ok, "already spoken to")
    local text = PC.textOf(d)
    H.ok(string.find(text, "IGUI_StoryEngine_Politics_Lobbied_promise|Gerald Kar", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Politics_LobbyLeft|2", 1, true))
    d.bill.lobbyLeft = 0
    H.ok(not PC.lobbyRows(d)[1].persuade.ok, "nobody left to move")
    StoryEngine.Client.handlers.politicsResult({ what = "lobby", ok = true, how = "promise", faction = "ray" })
    StoryEngine.Client.handlers.politicsResult({ what = "lobby", ok = false, error = "trust", need = 60 })
end

function T.council_tab_election_and_chair()
    H.addPlayer("tester", "Gerald", "Kar")
    local PC = StoryEngine.PoliticsClient
    local d = { era = true, on = true, blocs = {}, laws = {},
        chair = { fid = "guard", bloc = "gun", days = 40 },
        election = { hours = 100, cands = { field = "ray", gun = "guard", market = "rats" }, votes = { field = 3, gun = 2, market = 3 },
                     winner = "field", canRun = false, blocker = "hunter", rows = {} } }
    local text = PC.textOf(d)
    H.ok(string.find(text, "IGUI_StoryEngine_Politics_Chair|IGUI_StoryEngine_Faction_guard|40", 1, true), text)
    H.ok(string.find(text, "IGUI_StoryEngine_Politics_Chair_gun", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Politics_Election|", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Politics_Candidate|IGUI_StoryEngine_Faction_ray|IGUI_StoryEngine_Politics_Bloc_field|3", 1, true))
    local rows = PC.electionRows(d)
    H.eq(#rows, 4, "three candidates to back and the run")
    H.ok(rows[1].ok)
    H.eq(rows[1].args.bloc, "field")
    H.ok(not rows[4].ok, "cannot stand: someone does not trust them")
    H.ok(string.find(rows[4].tip, "IGUI_StoryEngine_Politics_Run_Blocked", 1, true))
    d.election.backed, d.election.backedBy = "gun", "Gerald Kar"
    H.ok(not PC.electionRows(d)[1].ok, "already backed someone")
    H.ok(string.find(PC.textOf(d), "IGUI_StoryEngine_Politics_Backed|Gerald Kar", 1, true))
    -- 우리가 의장일 때: 법안 고르기와 한 표
    local mine = { era = true, on = true, blocs = {}, laws = {},
        chair = { player = "Gerald Kar", mine = true, days = 30, bills = { { id = "post", ok = true }, { id = "armory", ok = false } } } }
    rows = PC.electionRows(mine)
    H.eq(#rows, 2)
    H.eq(rows[1].args.what, "choose")
    H.ok(rows[1].ok and not rows[2].ok)
    H.ok(string.find(PC.textOf(mine), "IGUI_StoryEngine_Politics_Chair_Player", 1, true))
    mine.chair.bills = nil
    mine.bill = { id = "post", bloc = "market", by = "chair", who = "Gerald Kar", hours = 10, yes = 4, no = 4, pass = false, rows = {}, cast = "for" }
    rows = PC.electionRows(mine)
    H.eq(#rows, 2)
    H.eq(rows[1].args.side, "for")
    H.ok(string.find(rows[1].label, "IGUI_StoryEngine_Politics_Cast_Set", 1, true))
    local t, good = PC.noticeText({ kind = "elected", fid = "guard", bloc = "gun" })
    H.ok(string.find(t, "IGUI_StoryEngine_Politics_Notice_elected", 1, true) and good)
    H.ok(string.find(PC.noticeText({ kind = "elected", player = "Gerald Kar" }), "elected_player", 1, true))
    StoryEngine.Client.handlers.politicsResult({ what = "run", ok = false, error = "trust", faction = "hunter" })
    StoryEngine.Client.handlers.politicsResult({ what = "back", ok = true })
end

function T.council_tab_crisis_offers()
    H.addPlayer("tester", "Gerald", "Kar")
    local PC = StoryEngine.PoliticsClient
    local d = { era = true, on = true, blocs = {}, laws = {},
        crisis = { saga = "migration", hours = 12, open = true, offers = { field = "pike", gun = "hunter", market = "rats" } } }
    local text = PC.textOf(d)
    H.ok(string.find(text, "IGUI_StoryEngine_Politics_Crisis|", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Politics_Offer_gun|IGUI_StoryEngine_Faction_hunter", 1, true), text)
    local rows = PC.electionRows(d)
    H.eq(#rows, 4, "three offers and going alone")
    H.eq(rows[2].args.what, "deal")
    H.eq(rows[2].args.bloc, "gun")
    H.eq(rows[4].args.bloc, "none")
    d.crisis.deal, d.crisis.by, d.crisis.open = "gun", "Gerald Kar", false
    H.ok(string.find(PC.textOf(d), "IGUI_StoryEngine_Politics_Deal_With|IGUI_StoryEngine_Politics_Bloc_gun|Gerald Kar", 1, true))
    H.eq(#PC.electionRows(d), 0)
    local t, good = PC.noticeText({ kind = "settled", bloc = "field", good = false })
    H.ok(string.find(t, "IGUI_StoryEngine_Politics_Notice_blame", 1, true))
    H.eq(good, false)
    H.ok(string.find(PC.noticeText({ kind = "deal", bloc = "none", name = "Gerald Kar" }), "deal_none", 1, true))
end

-- 밖에서 온 사람들 (OutsidersClient.lua): 의회 탭의 글과 메뉴, 알림, 효과
function T.outsiders_show_in_the_council_tab()
    H.addPlayer("tester", "Gerald", "Kar")
    local OC = StoryEngine.OutsidersClient
    local F = StoryEngine.Factions
    H.eq(#F.all(), 8)
    StoryEngine.Client.handlers.outsiders({ present = { "hale", "abigail" } })
    H.eq(#F.all(), 10)
    H.ok(F.present.hale and not F.present.odell)
    H.eq(OC.textOf(nil), "")
    H.eq(OC.textOf({ list = {} }), "")
    local o = { pending = "odell", jobs = { { id = "Q7", kind = "horde", tier = 3, faction = "ray" } }, list = {
        { id = "hale", trust = 72, days = 12, rival = "guard", dislike = { "guard", "rats", "hunter" },
          spec = { { kind = "proxy", n = 1, need = 40, ok = true }, { kind = "airdrop", n = 2, need = 70, ok = false, why = "wait", wait = 300 } },
          gift = { value = 6, trust = 1 }, volunteer = { ok = true },
          test = { hours = 40, rival = "guard" } },
        { id = "abigail", trust = 28, days = 30, hard = true, low = 2, rival = "pike", dislike = { "pike", "doc", "casey" },
          spec = { { kind = "miracle", n = 1, need = 40, ok = false, why = "trust" }, { kind = "burden", n = 2, need = 70, ok = false, why = "trust" } },
          expel = { stance = "abstain" } } } }
    local text = OC.textOf(o)
    H.ok(string.find(text, "IGUI_StoryEngine_Out_Pending|IGUI_StoryEngine_Faction_odell", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Out_Row|IGUI_StoryEngine_Faction_hale|72|12", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Out_SpecLine|1|IGUI_StoryEngine_Out_Spec_proxy|IGUI_StoryEngine_Out_Ready", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Out_Hours|5", 1, true), "five hours until the airdrop is back")
    H.ok(string.find(text, "IGUI_StoryEngine_Out_Test|IGUI_StoryEngine_Faction_hale|IGUI_StoryEngine_Faction_guard|40", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Out_Hard", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Out_Leaving|2", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Out_NeedTrust|40", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Out_Expel", 1, true))
    local rows = OC.rows(o)
    H.eq(#rows, 2)
    local hale = rows[1].items
    H.eq(hale[1].sub[1].args.quest, "Q7", "the proxy job is picked from a list")
    H.eq(hale[2].what, "aim")
    H.ok(not hale[2].ok)
    H.eq(hale[3].what, "gift")
    H.eq(hale[4].what, "volunteer")
    H.eq(hale[5].args.side, "out")
    H.eq(hale[6].args.side, "home")
    local ab = rows[2].items
    H.eq(ab[#ab].args.stance, "abstain")
    H.ok(not ab[#ab].ok, "that is already our stance")
    H.ok(ab[#ab - 1].ok)
    -- 맡길 일이 없으면 대리 작전은 꺼진다
    o.jobs = {}
    H.ok(not OC.rows(o)[1].items[1].ok)
    -- 메뉴에서 고른 일
    H.toServer = {}
    OC.act(hale[1].sub[1])
    H.eq(H.toServer[1].command, "outsiderUse")
    H.eq(H.toServer[1].args.quest, "Q7")
    OC.act(hale[5])
    H.eq(H.toServer[2].command, "outsiderSide")
    OC.act({ what = "order" })
    H.eq(H.toServer[3].command, "tradeOptions")
    H.eq(H.toServer[3].args.faction, "odell")
    -- 알림과 결과
    local msg, good = OC.noticeText({ kind = "hail", id = "odell" })
    H.ok(string.find(msg, "IGUI_StoryEngine_Out_Notice_hail|IGUI_StoryEngine_Faction_odell", 1, true) and good)
    msg = OC.noticeText({ kind = "left", id = "hale", why = "expelled" })
    H.ok(string.find(msg, "Out_Notice_expelled", 1, true))
    msg = OC.noticeText({ kind = "sided", id = "hale", side = "home", rival = "guard" })
    H.ok(string.find(msg, "IGUI_StoryEngine_Faction_guard", 1, true))
    msg = OC.resultText({ what = "use", ok = true, kind = "jewels", info = { taken = 2, scrip = 14 } })
    H.ok(string.find(msg, "IGUI_StoryEngine_Out_Done_jewels|2|14", 1, true))
    msg, good = OC.resultText({ what = "use", ok = false, error = "wait", wait = 125 })
    H.ok(string.find(msg, "IGUI_StoryEngine_Out_Error_wait|3", 1, true) and not good)
    -- 의회가 올린 표결과 불참
    local PC = StoryEngine.PoliticsClient
    local d = { era = true, on = true, blocs = {}, bill = { id = "admit", system = true, by = "council", target = "odell", hours = 30,
        yes = 1, no = 0, pass = true, rows = { { fid = "ray", bloc = "field", trust = 60, need = 50, yes = true },
                                               { fid = "guard", bloc = "gun", trust = 20, need = 70, yes = false, absent = true } } } }
    text = PC.textOf(d)
    H.ok(string.find(text, "IGUI_StoryEngine_Bill_admit_Desc|IGUI_StoryEngine_Faction_odell", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Politics_ByCouncil", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Politics_Absent", 1, true))
    StoryEngine.Client.handlers.outsiders({ present = {} })
    H.eq(#F.all(), 8)
end

function T.outsider_effects_run_on_the_client()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local OC = StoryEngine.OutsidersClient
    local hours = 100
    getGameTime = function() return { getWorldAgeHours = function() return hours end } end
    -- 짐을 든 자: 무게 한도 두 배, 끝나면 되돌린다
    local base = 8
    function p:getMaxWeightBase() return base end
    function p:setMaxWeightBase(v) base = v end
    StoryEngine.Client.handlers.outsiderFx({ kind = "burden", minutes = 120 })
    H.eq(base, 16)
    H.eq(p:getModData().seBurdenBase, 8)
    StoryEngine.Client.handlers.outsiderFx({ kind = "burden", minutes = 100 })
    H.eq(base, 16, "told again, not doubled again")
    hours = 103
    OC.tick()
    H.eq(base, 8)
    H.eq(p:getModData().seBurdenBase, nil)
    -- 체질 관리: 배고픔이 절반 속도로 오른다
    local hunger, weight = 0.2, 90
    CharacterStat = { HUNGER = "HUNGER", THIRST = "THIRST", PAIN = "PAIN" }
    function p:getStats()
        return { get = function(_, s) return s == "HUNGER" and hunger or 0 end,
                 set = function(_, s, v) if s == "HUNGER" then hunger = v end end }
    end
    function p:getNutrition()
        return { getWeight = function() return weight end, setWeight = function(_, v) weight = v end }
    end
    StoryEngine.Client.handlers.outsiderFx({ kind = "regimen", minutes = 600 })
    OC.tick()
    hunger = 0.3
    OC.tick()
    H.ok(math.abs(hunger - 0.25) < 0.0001, "half of the rise is taken back")
    H.ok(weight < 90, "and the weight creeps toward eighty")
    -- 지연제: 감염이 더 나아가지 않는다
    local level = 30
    local bd = p:getBodyDamage()
    function bd:getInfectionLevel() return level end
    function bd:setInfectionLevel(v) level = v end
    function bd:getInfectionTime() return 0 end
    function bd:setInfectionTime() end
    StoryEngine.Client.handlers.outsiderFx({ kind = "retard", minutes = 600 })
    OC.tick()
    level = 34
    OC.tick()
    H.eq(level, 30)
    StoryEngine.Client.handlers.outsiderFx({ kind = "retard", minutes = 0 })
    level = 40
    OC.tick()
    H.eq(level, 40, "once it is lifted the infection runs again")
    -- 기도를 받아 둔 사람: 체력이 바닥에 닿으면 서버에 알린다
    H.toServer = {}
    StoryEngine.Client.handlers.outsiderFx({ kind = "armed", minutes = 9999 })
    p.hp = 60
    for _ = 1, 10 do OC.watch(p) end
    H.eq(#H.toServer, 0)
    p.hp = 12
    for _ = 1, 10 do OC.watch(p) end
    H.eq(H.toServer[1].command, "outsiderMiracle")
    for _ = 1, 10 do OC.watch(p) end
    H.eq(#H.toServer, 1, "once")
    CharacterStat = nil
end

-- 정치 위기 (CrisesClient.lua): 의회 탭의 글, 선택 메뉴, 배분 계산
function T.political_crises_in_the_council_tab()
    H.addPlayer("tester", "Gerald", "Kar")
    local CC = StoryEngine.CrisesClient
    H.eq(CC.textOf(nil), "")
    H.eq(#CC.rows(nil), 0)
    local e = { fx = { { id = "split", days = 12, snubbed = "gun", hold = "power" }, { id = "route" } },
                current = { id = "quarantine", hours = 50, options = { "seal", "open" }, sick = "ray" } }
    local text = CC.textOf(e)
    H.ok(string.find(text, "IGUI_StoryEngine_Crisis2_Head|IGUI_StoryEngine_Crisis2_quarantine|50", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Crisis2_quarantine_Desc|IGUI_StoryEngine_Faction_ray", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Crisis2_Fx_split|12|IGUI_StoryEngine_Crisis2_Hold_power", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Crisis2_Fx_route", 1, true))
    local rows = CC.rows(e)
    H.eq(#rows, 2)
    H.eq(rows[1].option, "seal")
    H.ok(string.find(rows[1].label, "IGUI_StoryEngine_Crisis2_quarantine_seal|IGUI_StoryEngine_Faction_ray", 1, true))
    H.toServer = {}
    CC.act(rows[2])
    H.eq(H.toServer[1].command, "crisisChoose")
    H.eq(H.toServer[1].args.option, "open")
    -- 기다리는 동안에는 고를 것이 없다
    e.current.waiting, e.current.vote = true, true
    H.eq(#CC.rows(e), 0)
    H.ok(string.find(CC.textOf(e), "IGUI_StoryEngine_Crisis2_WaitVote", 1, true))
    -- 배분: 배급은 남김없이
    local allot = { total = 30, step = 5, max = 15, rows = { { fid = "ray" }, { fid = "guard" }, { fid = "rats" } } }
    local c = { id = "ration", hours = 70, options = {}, allot = allot }
    rows = CC.rows({ current = c })
    H.eq(#rows, 1)
    H.ok(rows[1].allot == c)
    local shares = {}
    H.ok(CC.bump(allot, shares, "ray", 1))
    H.ok(not CC.bump(allot, shares, "guard", -1), "nothing to take back")
    H.eq(CC.left(allot, shares), 25)
    H.ok(not CC.canSend(allot, shares))
    CC.bump(allot, shares, "ray", 1)
    CC.bump(allot, shares, "ray", 1)
    H.ok(not CC.bump(allot, shares, "ray", 1), "fifteen is the most for one place")
    shares = CC.even(allot)
    H.eq(shares.ray, 10)
    H.eq(shares.guard, 10)
    H.eq(shares.rats, 10)
    H.ok(CC.canSend(allot, shares))
    H.ok(not CC.bump(allot, shares, "ray", 1), "nothing left to hand out")
    -- 난민은 남겨도 된다 (남은 사람은 돌려보낸다)
    local ref = { total = 100, step = 10, max = 40, partial = true, rows = { { fid = "ray" }, { fid = "pike" } } }
    shares = { ray = 20 }
    H.ok(CC.canSend(ref, shares))
    H.eq(CC.left(ref, shares), 80)
    shares = CC.even(ref)
    H.eq(shares.ray, 40)
    H.eq(shares.pike, 40)
    -- 알림
    local msg, good = CC.noticeText({ kind = "open", id = "split" })
    H.ok(string.find(msg, "IGUI_StoryEngine_Crisis2_Notice_open|IGUI_StoryEngine_Crisis2_split", 1, true) and not good)
    msg, good = CC.noticeText({ kind = "refugees_done", taken = 60, away = 40 })
    H.ok(string.find(msg, "refugees_done|60|40", 1, true) and good)
    msg, good = CC.noticeText({ kind = "boat_back" })
    H.ok(good)
    H.eq(CC.noticeText({ kind = "nonsense" }), nil)
    -- 갈라선 의회의 표결
    local PC = StoryEngine.PoliticsClient
    local d = { era = true, on = true, blocs = {}, bill = { id = "canteen", bloc = "field", by = "ray", hours = 30, yes = 5, no = 3,
        pass = false, two3 = true, rows = {} } }
    H.ok(string.find(PC.textOf(d), "IGUI_StoryEngine_Politics_Two3", 1, true))
end

-- 조사 (CrisesClient.lua): 수사 수첩, 묻기·다시 묻기·판결, 유도신문의 대답
function T.inquiries_in_the_council_tab()
    H.addPlayer("tester", "Gerald", "Kar")
    local CC = StoryEngine.CrisesClient
    local case = { kind = "warehouse", answers = { "ray", "guard", "rats" }, found = 3, need = 4, hows = { "public", "cover", "private" },
                   clues = { { n = 1, kind = "site", clears = "rats" }, { n = 3, kind = "item", clears = "guard" },
                             { n = 6, kind = "word", fid = "ray", points = "guard" } },
                   words = { { fid = "doc", state = "silent" }, { fid = "ray", state = "confront" } }, canJudge = false }
    local e = { fx = {}, current = { id = "warehouse", hours = 100, options = {}, case = case } }
    local text = CC.textOf(e)
    H.ok(string.find(text, "IGUI_StoryEngine_Inq_Count|3|4", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Inq_Clue_site_clears|IGUI_StoryEngine_Faction_rats", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Inq_Clue_word_points|IGUI_StoryEngine_Faction_ray|IGUI_StoryEngine_Faction_guard", 1, true))
    local rows = CC.rows(e)
    H.eq(#rows, 2 + 9, "two witnesses, three suspects times three ways")
    H.ok(not rows[1].ok, "Doc will not talk yet")
    H.eq(rows[2].inquiry.what, "confront")
    H.ok(not rows[3].ok, "no verdict before four clues")
    case.canJudge = true
    rows = CC.rows(e)
    H.ok(rows[3].ok)
    H.eq(rows[3].inquiry.answer, "ray")
    H.eq(rows[3].inquiry.how, "public")
    H.toServer = {}
    CC.act(rows[3])
    H.eq(H.toServer[1].command, "inquiryAct")
    H.eq(H.toServer[1].args.what, "judge")
    -- 재판: 답이 사람이 아니라 사건의 성격
    local trial = { kind = "trial", answers = { "murder", "accident", "defence" }, found = 4, need = 4, accused = "rats", victim = "pike",
                    clues = { { n = 6, kind = "word", fid = "doc", points = "murder", refuted = true } }, words = {}, canJudge = true }
    e = { fx = {}, current = { id = "trial", hours = 50, options = {}, case = trial } }
    text = CC.textOf(e)
    H.ok(string.find(text, "IGUI_StoryEngine_Crisis2_trial_Desc|IGUI_StoryEngine_Faction_rats|IGUI_StoryEngine_Faction_pike", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Inq_Clue_word_refuted|IGUI_StoryEngine_Faction_doc|IGUI_StoryEngine_Inq_Answer_murder", 1, true))
    rows = CC.rows(e)
    H.eq(#rows, 3)
    H.ok(string.find(rows[1].label, "IGUI_StoryEngine_Inq_Judge|IGUI_StoryEngine_Inq_Answer_murder", 1, true))
    -- 유도신문: 떠보는 사람에게 메뉴로 대답
    e = { fx = {}, probe = { days = 5, hints = 1, max = 2, open = { fid = "doc", hours = 20 } } }
    text = CC.textOf(e)
    H.ok(string.find(text, "IGUI_StoryEngine_Inq_Probe|5|1|2", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Inq_Probe_Open|IGUI_StoryEngine_Faction_doc|20", 1, true))
    rows = CC.rows(e)
    H.eq(#rows, 3)
    H.eq(rows[2].inquiry.choice, "vague")
    local msg, good = CC.inquiryText({ kind = "exposed", quote = "it was Ray" })
    H.ok(string.find(msg, "IGUI_StoryEngine_Inq_Notice_quote|it was Ray", 1, true) and not good)
    msg, good = CC.inquiryText({ kind = "clue", found = 2 })
    H.ok(string.find(msg, "Inq_Notice_clue|2", 1, true) and good)
    H.eq(CC.inquiryText({ kind = "nonsense" }), nil)
end

-- 의회 탭: 압박·몰아세움, 자리 셋, 두 번째 연대기
function T.council_tab_press_call_and_posts()
    H.addPlayer("tester", "Gerald", "Kar")
    local PC = StoryEngine.PoliticsClient
    local d = { era = true, on = true, blocs = {}, secrets = { "guard" },
        phase = { kind = "rule", bloc = "field", days = 20, cold = { "hunter" } },
        bill = { id = "canteen", bloc = "field", by = "ray", hours = 30, yes = 1, no = 2, pass = false, lobbyLeft = 2, plea = "rats",
                 calls = { ray = "for" },
                 rows = { { fid = "ray", bloc = "field", trust = 20, need = 40, yes = false },
                          { fid = "guard", bloc = "gun", trust = 30, need = 80, yes = false },
                          { fid = "doc", bloc = "field", trust = 70, need = 50, yes = true } } },
        offices = { list = { { id = "store", fid = "rats", bloc = "market", days = 40, mood = "cold" },
                             { id = "captain", voteIn = 12 }, { id = "air" } },
                    vote = { office = "air", hours = 50, cands = { field = "pike", market = "casey" }, votes = { market = 5, field = 3 },
                             winner = "market" } } }
    local rows = PC.lobbyRows(d)
    H.ok(not rows[1].press.ok and rows[1].call.ok, "Ray can be called out on his signature")
    H.eq(rows[1].call.side, "for")
    H.ok(rows[2].press.ok and not rows[2].call.ok, "we hold something over the Guard")
    H.ok(string.find(rows[3].press.tip, "IGUI_StoryEngine_Politics_Lobby_Error_no_secret", 1, true))
    H.ok(string.find(rows[3].call.tip, "IGUI_StoryEngine_Politics_Lobby_Error_no_pledge", 1, true))
    local text = PC.textOf(d)
    H.ok(string.find(text, "IGUI_StoryEngine_Politics_Secrets|IGUI_StoryEngine_Faction_guard", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Politics_Phase_cold|IGUI_StoryEngine_Faction_hunter", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Politics_Plea|IGUI_StoryEngine_Faction_rats", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Office_Held|IGUI_StoryEngine_Office_store|IGUI_StoryEngine_Faction_rats|40", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Office_store_cold", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Office_Empty|IGUI_StoryEngine_Office_captain|12", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Office_Vote|IGUI_StoryEngine_Office_air", 1, true))
    local erows = PC.electionRows(d)
    H.eq(#erows, 2, "one row for each candidate for the post")
    H.eq(erows[1].args.what, "office")
    H.eq(erows[1].args.bloc, "field")
    H.ok(erows[1].ok)
    d.offices.vote.backed = "field"
    H.ok(not PC.electionRows(d)[2].ok, "one backing only")
    local msg = PC.noticeText({ kind = "office", office = "store", fid = "rats" })
    H.ok(string.find(msg, "IGUI_StoryEngine_Office_Notice_chosen|IGUI_StoryEngine_Faction_rats|IGUI_StoryEngine_Office_store", 1, true))
    msg = PC.noticeText({ kind = "moved", fid = "doc", to = "gun" })
    H.ok(string.find(msg, "IGUI_StoryEngine_Politics_Notice_moved|IGUI_StoryEngine_Faction_doc", 1, true))
    H.ok(PC.noticeText({ kind = "secret", fid = "guard" }))
    H.ok(PC.noticeText({ kind = "plea", fid = "rats" }))
end

function T.second_chronicle_in_the_journal()
    H.addPlayer("tester", "Gerald", "Kar")
    local J = StoryEngineJournalPanel
    local ep = { status = "failed", second = true, date = "1994-07-01", day = 665,
        politics = { days = 351, phase = { kind = "rule", bloc = "market" }, chair = { fid = "rats" }, passed = { "post", "armory" },
                     failed = 2, moved = { { fid = "doc", to = "gun" } }, camps = { ray = "field" },
                     outsiders = { { id = "hale", state = "expelled" }, { id = "odell", state = "here" } },
                     crises = { "ration", "pirate" }, offices = { { id = "store", fid = "dewey" } } },
        npcs = { { fid = "ray", trust = 72 }, { fid = "doc", trust = 40, gone = "dead" } }, players = {} }
    local text = J.epilogueText(ep)
    H.ok(string.find(text, "IGUI_StoryEngine_Epilogue2_Title", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Epilogue2_Days|351", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Epilogue2_Phase_rule|IGUI_StoryEngine_Politics_Bloc_market", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Epilogue2_Chair|IGUI_StoryEngine_Faction_rats", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Epilogue2_Passed|IGUI_StoryEngine_Bill_post, IGUI_StoryEngine_Bill_armory", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Epilogue2_Failed|2", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Epilogue2_Moved|IGUI_StoryEngine_Faction_doc|IGUI_StoryEngine_Politics_Bloc_gun", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Epilogue2_Out_expelled|IGUI_StoryEngine_Faction_hale", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Epilogue2_Crises|IGUI_StoryEngine_Crisis2_ration, IGUI_StoryEngine_Crisis2_pirate", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Epilogue2_Standing|IGUI_StoryEngine_Politics_Bloc_field|72", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Fate_dead", 1, true))
    -- AI 가 쓴 글이 있으면 그 글만
    ep.status, ep.title, ep.text = "ready", "A Year of Votes", "They argued, and the lights stayed on."
    text = J.epilogueText(ep)
    H.ok(string.find(text, "A Year of Votes", 1, true))
    H.ok(string.find(text, "They argued, and the lights stayed on.", 1, true))
    H.ok(not string.find(text, "IGUI_StoryEngine_Epilogue2_Days", 1, true))
    -- 첫 연대기는 그대로
    local first = J.epilogueText({ status = "ready", result = "formed", held = true, text = "The church held.", npcs = {}, players = {} })
    H.ok(string.find(first, "The church held.", 1, true))
    H.ok(not string.find(first, "Epilogue2", 1, true))
end

function T.council_tab_majority_split_and_rule_by_order()
    H.addPlayer("tester", "Gerald", "Kar")
    local PC, RC = StoryEngine.PoliticsClient, StoryEngine.RegimeClient
    H.ok(RC, "the module loads")
    H.eq(RC.textOf(nil), "")
    H.eq(#RC.rows({ on = true }), 0)
    -- 다수파: 중재와 이간, 불신임
    local d = { era = true, on = true, secrets = { "rats", "guard" },
        blocs = { { id = "field", members = { "ray" } }, { id = "gun", members = { "guard" } }, { id = "market", members = {} } },
        chair = { fid = "ray", bloc = "field", days = 30 },
        regime = { coalition = { blocs = { "field", "market" }, strain = 2, limit = 3, mendWait = 0, members = { "ray", "rats" } },
                   noconf = { fid = "ray", wait = 0 },
                   facility = { held = { { what = "power", bloc = "gun" } }, down = { { what = "water", days = 12 } } },
                   blame = { saga = "migration", hours = 30 } } }
    local text = RC.textOf(d)
    H.ok(string.find(text, "IGUI_StoryEngine_Regime_Coalition|IGUI_StoryEngine_Politics_Bloc_field + IGUI_StoryEngine_Politics_Bloc_market", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Regime_Coalition_Strain|2|3", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Regime_Facility_Held|IGUI_StoryEngine_Regime_Power|IGUI_StoryEngine_Politics_Bloc_gun", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Regime_Facility_Down|IGUI_StoryEngine_Regime_Water|12", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Regime_Blame|", 1, true))
    local rows = RC.rows(d)
    local by = {}
    for _, r in ipairs(rows) do by[r.args.what] = (by[r.args.what] or 0) + 1 end
    H.eq(by.testify, 2, "one row for each camp that still has people")
    H.eq(by.mend, 1)
    H.eq(by.wedge, 1, "only a secret about someone inside the majority")
    H.eq(by.noconf, 1)
    for _, r in ipairs(rows) do
        if r.args.what == "wedge" then H.eq(r.args.fid, "rats") end
        if r.args.what == "noconf" then H.ok(r.ok) end
    end
    d.bill = { id = "canteen", rows = {} }
    for _, r in ipairs(RC.rows(d)) do
        if r.args.what == "noconf" then H.ok(not r.ok, "a bill is already before the council") end
    end
    d.bill = nil
    d.regime.blame.used, d.regime.blame.by, d.regime.blame.bloc = true, "Gerald Kar", "field"
    H.ok(string.find(RC.textOf(d), "IGUI_StoryEngine_Regime_Blame_Used|Gerald Kar", 1, true))
    -- 분열
    d.phase = { kind = "split" }
    d.regime = { split = { wait = 0, halves = {
        { id = "a", blocs = { "gun" }, hold = "power", cut = true, avg = 30, members = { "guard" }, leader = "guard" },
        { id = "b", blocs = { "field", "market" }, hold = "water", avg = 55, members = { "ray", "rats" }, leader = "ray" } } } }
    text = PC.textOf(d) .. RC.textOf(d)
    H.ok(string.find(text, "IGUI_StoryEngine_Politics_Phase_split", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Politics_Shut", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Regime_Split_Half|IGUI_StoryEngine_Politics_Bloc_gun|IGUI_StoryEngine_Faction_guard|IGUI_StoryEngine_Regime_Power|30", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Regime_Split_Cut|IGUI_StoryEngine_Regime_Power", 1, true))
    rows = RC.rows(d)
    H.eq(rows[1].args.what, "reunite")
    H.ok(rows[1].ok)
    d.regime.split.reunion = { hours = 60, by = "Gerald Kar" }
    H.ok(not RC.rows(d)[1].ok)
    H.ok(string.find(RC.textOf(d), "IGUI_StoryEngine_Regime_Reunion|Gerald Kar", 1, true))
    -- 군정
    d.phase = { kind = "martial", by = "guard" }
    d.regime = { martial = { by = "guard", obeyed = 1, defied = 2, days = 3, yes = 2, need = 4, settleAt = 4, backed = true } }
    text = PC.textOf(d) .. RC.textOf(d)
    H.ok(string.find(text, "IGUI_StoryEngine_Politics_Phase_martial|IGUI_StoryEngine_Faction_guard", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Regime_Martial_Count|1|2|4", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Regime_Martial_Backed", 1, true))
    rows = RC.rows(d)
    H.eq(rows[1].args.what, "petition")
    H.ok(not rows[1].ok)
    d.regime.martial.yes = 4
    H.ok(RC.rows(d)[1].ok)
    -- 알림
    local msg, good = PC.noticeText({ kind = "phase", phase = "split" })
    H.ok(string.find(msg, "IGUI_StoryEngine_Politics_Notice_split", 1, true) and good == false)
    msg = PC.noticeText({ kind = "phase", phase = "martial", by = "guard" })
    H.ok(string.find(msg, "IGUI_StoryEngine_Politics_Notice_martial|IGUI_StoryEngine_Faction_guard", 1, true))
    msg, good = PC.noticeText({ kind = "coalition_broken", blocs = { "field", "market" }, laws = 2 })
    H.ok(string.find(msg, "IGUI_StoryEngine_Regime_Notice_coalition_broken|", 1, true) and good == false)
    H.eq(PC.noticeText({ kind = "coalition", blocs = { "gun" } }), nil, "a camp alone is not news")
    msg = PC.noticeText({ kind = "facility_held", what = "water", bloc = "gun" })
    H.ok(string.find(msg, "IGUI_StoryEngine_Regime_Notice_facility_held_bloc|IGUI_StoryEngine_Regime_Water", 1, true))
    msg = PC.noticeText({ kind = "martial_order", by = "guard", sweep = true })
    H.ok(string.find(msg, "IGUI_StoryEngine_Regime_Notice_martial_order_sweep", 1, true))
    H.ok(PC.noticeText({ kind = "testified", name = "Gerald Kar", bloc = "field" }))
    -- 결과
    StoryEngine.Client.handlers.regimeResult({ what = "petition", ok = false, error = "trust", a = 1, b = 4 })
    StoryEngine.Client.handlers.regimeResult({ what = "mend", ok = true })
end

function T.council_tab_rule_colours_and_shared_posts()
    H.addPlayer("tester", "Gerald", "Kar")
    local PC, RC = StoryEngine.PoliticsClient, StoryEngine.RegimeClient
    local d = { era = true, on = true, blocs = {}, phase = { kind = "rule", bloc = "gun", days = 10 },
                regime = { rule = { bloc = "gun" } },
                offices = { list = {}, vote = { office = "store", hours = 40, cands = { market = "rats" }, votes = {}, share = "market" } } }
    local text = RC.textOf(d)
    H.ok(string.find(text, "IGUI_StoryEngine_Regime_Rule_gun_good", 1, true))
    H.ok(string.find(text, "IGUI_StoryEngine_Regime_Rule_gun_bad", 1, true))
    H.ok(string.find(PC.textOf(d), "IGUI_StoryEngine_Office_Share|IGUI_StoryEngine_Politics_Bloc_market", 1, true))
    d.phase.bloc, d.regime.rule = "field", { bloc = "field", titheDays = 4 }
    H.ok(string.find(RC.textOf(d), "IGUI_StoryEngine_Regime_Tithe_Next|4", 1, true))
    d.regime.rule.tithe = "Q7"
    H.ok(string.find(RC.textOf(d), "IGUI_StoryEngine_Regime_Tithe <", 1, true))
    local msg, good = PC.noticeText({ kind = "curfew_caught", fid = "guard" })
    H.ok(string.find(msg, "IGUI_StoryEngine_Regime_Notice_curfew_caught|IGUI_StoryEngine_Faction_guard", 1, true) and good == false)
    msg, good = PC.noticeText({ kind = "tithe_paid", fid = "hunter" })
    H.ok(msg and good == true)
    H.ok(PC.noticeText({ kind = "post_snub", bloc = "market" }))
    H.ok(PC.noticeText({ kind = "tithe", fid = "ray" }))
end

function T.item_tooltip_shows_the_trade_lock()
    StoryEngine.Value.cache["Base.Hammer"] = { category = "tools", value = 8 }
    StoryEngine.Cache.quests = { { id = "Q5", state = "accepted" } }
    local item = H.newItem("Base.Hammer", { questTag = "Q5" })
    item:getModData().storyQuestT = StoryEngine.Value.nowMinutes()
    local lines = StoryEngine.ItemTooltip.lines(item)
    H.eq(#lines, 1)
    H.ok(string.find(lines[1][1], "IGUI_StoryEngine_Tip_Quest", 1, true), "still in a quest")
    -- 퀘스트가 끝나면 거래 제한 줄과 보통 툴팁
    StoryEngine.Cache.quests = { { id = "Q5", state = "completed" } }
    lines = StoryEngine.ItemTooltip.lines(item)
    H.ok(string.find(lines[1][1], "IGUI_StoryEngine_Tip_Lock|7", 1, true), lines[1][1])
    H.ok(string.find(lines[2][1], "IGUI_StoryEngine_Tip_Trade|", 1, true), lines[2][1])
    H.ok(not StoryEngine.Value.payable(nil, item, "tools"))
    -- 가진 개수에는 끝난 퀘스트의 물건도 센다 (부탁에 낼 수 있다)
    local p = H.addPlayer("tester", "Gerald", "Kar")
    H.give(p, "Base.Hammer", { questTag = "Q5" })
    H.give(p, "Base.Hammer", { questTag = "Q6" })
    StoryEngine.Cache.quests = { { id = "Q5", state = "completed" }, { id = "Q6", state = "accepted" } }
    H.eq(StoryEngine.UI.countHeld(p, "Base.Hammer"), 1)
    StoryEngine.Cache.quests = nil
end

return T
