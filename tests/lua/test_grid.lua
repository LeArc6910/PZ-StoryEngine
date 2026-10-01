-- 전기·수도 복구 (Grid.lua, GridSync.lua): 샌드박스 끊김 날짜를 올리고, 다시 적용하고, 만료되면 되돌린다
local T = {}

-- 바닐라 SandboxOptions 흉내: set/getElecShutModifier/getWaterShutModifier/toLua/doesPowerGridExist
local function mockSandbox(elec, water)
    local so = { values = { ElecShutModifier = elec, WaterShutModifier = water }, sets = 0, hydro = nil }
    function so:set(name, v) self.values[name] = v; self.sets = self.sets + 1 end
    function so:getElecShutModifier() return self.values.ElecShutModifier end
    function so:getWaterShutModifier() return self.values.WaterShutModifier end
    function so:getTimeSinceApo() return 1 end
    function so:toLua() SandboxVars.ElecShutModifier = self.values.ElecShutModifier; SandboxVars.WaterShutModifier = self.values.WaterShutModifier end
    function so:doesPowerGridExist() return getGameTime():getWorldAgeHours() / 24 < self.values.ElecShutModifier end
    getSandboxOptions = function() return so end
    local world = {}
    function world:setHydroPowerOn(v) so.hydro = v end
    getWorld = function() return world end
    return so
end

local function setup(day)
    H.addPlayer("tester", "Gerald", "Kar")
    H.clockMin = (day or 20) * 1440
end

function T.restore_power_for_sixty_days_and_sync_clients()
    local so = mockSandbox(14, 10)
    setup(20)
    local W = StoryEngine.World
    H.ok(W.powerOff() and W.waterOff(), "both off on day 20")
    H.sent = {}
    H.ok(StoryEngine.Grid.restore("power", 60, "debug"))
    H.eq(so.values.ElecShutModifier, 80, "today 20 + 60")
    H.eq(so.values.WaterShutModifier, 10, "water untouched")
    H.eq(SandboxVars.ElecShutModifier, 80, "SandboxVars follows")
    H.eq(so.hydro, true, "hydro flag on")
    H.ok(not W.powerOff(), "power back on")
    local sync = H.sentOf("gridSync")[1]
    H.ok(sync and sync.power == 80 and sync.water == 10, "clients get the new values")
    H.eq(StoryEngine.Grid.daysLeft("power"), 60)
    H.ok(H.logHas("grid restored power until day 80"))
end

function T.reapply_after_restart_and_expire_back_to_original()
    local so = mockSandbox(14, 10)
    setup(20)
    local G = StoryEngine.Grid
    G.restore("water", 60, "debug")
    H.eq(so.values.WaterShutModifier, 80)
    so.values.WaterShutModifier = 10          -- 호스트 재시작: 서버 설정 파일 값으로 돌아감
    G.ensure()
    H.eq(so.values.WaterShutModifier, 80, "reapplied from save")
    H.ok(H.logHas("grid reapplied water"))
    H.clockMin = 81 * 1440
    G.ensure()
    H.eq(so.values.WaterShutModifier, 10, "back to the original day after 60 days")
    H.ok(StoryEngine.World.waterOff(), "water off again")
    H.ok(not G.isRestored("water"))
    H.ok(H.logHas("grid restore ended water"))
end

function T.reset_restores_original_values()
    local so = mockSandbox(-1, 14)
    setup(30)
    local G = StoryEngine.Grid
    G.restore("power", 60, "debug")
    G.restore("power", 60, "debug")            -- 두 번 복구해도 원래 값은 처음 것
    H.eq(so.values.ElecShutModifier, 90)
    G.reset(nil, "debug")
    H.eq(so.values.ElecShutModifier, -1, "original -1 (off from the start)")
    H.ok(StoryEngine.Grid.statusText():find("power=off", 1, true) ~= nil)
end

function T.debug_command_and_hello_sync()
    mockSandbox(14, 10)
    local p = H.addPlayer("admin", "Ada", "Min")
    H.clockMin = 20 * 1440
    H.sent = {}
    StoryEngine.Commands.hello(p, { lang = "EN" })
    local sync = H.sentOf("gridSync")[1]
    H.ok(sync and sync.power == 14, "hello sends current values")
    H.sent = {}
    StoryEngine.Commands.debugGrid(p, { kind = "power" })
    local st = H.sentOf("debugStatus")[1]
    H.ok(st and st.text:find("power=on(restored, 60d left)", 1, true) ~= nil, st and st.text or "no status")
    StoryEngine.Commands.debugGrid(p, { kind = "reset" })
    H.eq(getSandboxOptions():getElecShutModifier(), 14)
end

function T.cut_turns_off_now_and_reset_brings_it_back()
    local so = mockSandbox(30, 30)
    setup(5)
    local G = StoryEngine.Grid
    H.ok(not StoryEngine.World.powerOff(), "on before day 30")
    G.cut("power", "debug")
    H.eq(so.values.ElecShutModifier, 0, "cut = shut day 0")
    H.ok(StoryEngine.World.powerOff(), "off now")
    H.eq(so.hydro, false, "hydro flag off")
    so.values.ElecShutModifier = 30            -- 재시작: 설정 파일 값
    G.ensure()
    H.eq(so.values.ElecShutModifier, 0, "cut reapplied")
    G.restore("power", 60, "debug")            -- 끊은 뒤 복구
    H.eq(so.values.ElecShutModifier, 65)
    G.reset(nil, "debug")
    H.eq(so.values.ElecShutModifier, 30, "original value back")
end

function T.debug_world_power_cuts_for_real_without_double_event()
    local so = mockSandbox(30, 30)
    local p = H.addPlayer("admin", "Ada", "Min")
    H.clockMin = 5 * 1440
    StoryEngine.Commands.debugWorld(p, { event = "power" })
    H.eq(so.values.ElecShutModifier, 0)
    H.ok(StoryEngine.World.isDone("power"), "recorded under the real key")
    H.ok(H.logHas("world event power power"))
    H.advance(60)
    StoryEngine.World.tick()
    local n = 0
    for _, l in ipairs(H.logs) do if l:find("world event power", 1, true) then n = n + 1 end end
    H.eq(n, 1, "hourly tick does not fire it again")
end

return T
