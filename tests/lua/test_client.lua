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

return T
