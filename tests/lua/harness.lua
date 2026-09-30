-- 게임 없이 서버 Lua 를 돌리기 위한 가짜 게임 환경 (lupa 의 Lua 5.1, tests/run_lua_tests.py 가 불러온다).
--
-- 원칙: 테스트가 보는 게임 기능(시계, ModData, 이벤트, 플레이어·인벤토리, 번역, 난수, 브릿지)은 여기서 제대로 흉내 내고,
-- 그 밖의 게임 전역(UI, 셀, 기후 등)은 무엇이든 받아 주는 Dummy 로 대신한다. 쓰인 Dummy 전역은 H.unknown 에 모인다.
-- Kahlua 처럼 next 는 없다 (쓰면 오류).
-- PY_READ(상대 경로) 는 파이썬이 넣어 준다 (한글 경로라 Lua io.open 대신).

H = {
    unknown = {},
    logs = {},
    moddata = {},
    sent = {},           -- 서버 -> 클라이언트 명령 { command, args }
    bridge = {},         -- 브릿지 요청 { module, payload, callback }
    rolls = {},          -- ZombRand 가 먼저 돌려줄 값 (테스트가 넣는다)
    clockMin = 8 * 60,   -- 게임 시각 (월드 경과 분)
    realMs = 1000000,
    players = {},
    echo = false,        -- true 면 로그를 바로 출력
}

-- ---------------------------------------------------------------- Dummy / 전역

local Dummy
Dummy = setmetatable({}, {
    __index = function() return Dummy end,
    __call = function() return Dummy end,
    __tostring = function() return "Dummy" end,
    __concat = function(a, b) return tostring(a) .. tostring(b) end,
})
H.Dummy = Dummy

-- 전역으로 없을 때 Dummy 가 아니라 nil 이어야 하는 것 (다른 모드, Kahlua 에 없는 함수)
H.NILS = { StoryEngine = true, ProjectALife = true, next = true, StoryEngineMainWindow = true }

local realPrint = print
next = nil
setmetatable(_G, {
    __index = function(t, k)
        if H.NILS[k] then return nil end
        H.unknown[k] = true
        return Dummy
    end,
})

-- ---------------------------------------------------------------- require (shared, server 순)

local loaded = {}
function require(name)
    if loaded[name] ~= nil then return loaded[name] end
    for _, dir in ipairs({ "shared", "server" }) do
        local rel = dir .. "/" .. name .. ".lua"
        local src = PY_READ(rel)
        if src then
            local chunk, err = loadstring(src, "@" .. rel)
            if not chunk then error(err, 0) end
            loaded[name] = true
            local r = chunk()
            if r ~= nil then loaded[name] = r end
            return loaded[name]
        end
    end
    loaded[name] = true      -- 바닐라 모듈 (ISUI 등)
    return true
end

-- ---------------------------------------------------------------- 기본 게임 함수

function isClient() return false end
function isServer() return false end
function getDebug() return false end
SandboxVars = { StoryEngine = {} }

function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, " ")
    H.logs[#H.logs + 1] = line
    if H.echo then realPrint(line) end
end

function H.logHas(text)
    for _, l in ipairs(H.logs) do
        if string.find(l, text, 1, true) then return true end
    end
    return false
end

-- 시계: H.clockMin (분)
H.gt = {}
function H.gt:getWorldAgeHours() return H.clockMin / 60 end
function H.gt:getHour() return math.floor(H.clockMin / 60) % 24 end
function H.gt:getMinutes() return H.clockMin % 60 end
function H.gt:getDay() return math.floor(H.clockMin / 1440) % 28 end
function H.gt:getMonth() return 6 + math.floor(H.clockMin / 1440 / 28) end
function H.gt:getYear() return 1993 end
function H.gt:getTimeOfDay() return (H.clockMin % 1440) / 60 end
function getGameTime() return H.gt end
function getTimestampMs()
    H.realMs = H.realMs + 1
    return H.realMs
end

function H.advance(minutes) H.clockMin = H.clockMin + minutes end

-- GameTime ModData (라디오 주파수 저장)
H.gtModData = {}
function H.gt:getModData() return H.gtModData end

-- 라디오: DynamicRadioChannel / RadioBroadCast / RadioLine. H.radio.aired 에 방송된 줄 목록을 모은다
H.radio = { aired = {} }
ChannelCategory = { Radio = "Radio", Television = "Television", Amateur = "Amateur", Other = "Other" }
DynamicRadioChannel = {}
function DynamicRadioChannel.new(name, freq, cat, uuid)
    local ch = { name = name, freq = freq, cat = cat, uuid = uuid }
    function ch:GetFrequency() return self.freq end
    function ch:getGUID() return self.uuid end
    function ch:setAiringBroadcast(bc)
        local texts = {}
        for _, l in ipairs(bc.lines) do texts[#texts + 1] = l.text end
        H.radio.aired[#H.radio.aired + 1] = { freq = self.freq, lines = texts }
    end
    return ch
end
RadioBroadCast = {}
function RadioBroadCast.new(id)
    local bc = { id = id, lines = {} }
    function bc:AddRadioLine(line) self.lines[#self.lines + 1] = line end
    return bc
end
RadioLine = {}
function RadioLine.new(text, r, g, b) return { text = text, r = r, g = g, b = b } end
-- 라디오 스크립트 관리자 흉내: channels = { {freq, uuid} }
function H.scriptManager(channels)
    local list = {}
    for _, c in ipairs(channels or {}) do list[#list + 1] = DynamicRadioChannel.new("x", c.freq, "Radio", c.uuid) end
    local sm = { added = {} }
    function sm:getChannelsList() return H.list(list) end
    function sm:AddChannel(ch) self.added[#self.added + 1] = ch end
    return sm
end

-- 날씨: 맑음, 20도 (Social.timely 의 아침 날씨 연락 등)
H.climate = { raining = false, fog = 0, temp = 20 }
function getClimateManager()
    return {
        isRaining = function() return H.climate.raining end,
        getFogIntensity = function() return H.climate.fog end,
        getTemperature = function() return H.climate.temp end,
        isSnowing = function() return H.climate.snow == true end,
        getIsThunderStorming = function() return false end,
        getClimateForecaster = function()
            return { getForecast = function(_, days)
                local f = H.climate.forecast or {}
                return {
                    getTemperature = function() return { getTotalMin = function() return f.min or 15 end,
                                                         getTotalMax = function() return f.max or 25 end } end,
                    isHasHeavyRain = function() return f.heavyRain == true end,
                    isHasStorm = function() return f.storm == true end,
                    isHasTropicalStorm = function() return false end,
                    isHasBlizzard = function() return false end,
                    isHasFog = function() return f.fog == true end,
                    isChanceOnSnow = function() return false end,
                    isWeatherStarts = function() return f.rain == true end,
                }
            end }
        end,
    }
end
function H.advanceDays(days) H.clockMin = H.clockMin + days * 1440 end

-- 난수: H.rolls 에 넣은 값을 먼저 쓴다
math.randomseed(42)
function ZombRand(a, b)
    if #H.rolls > 0 then return table.remove(H.rolls, 1) end
    if b then return a + math.random(0, math.max(0, b - a - 1)) end
    if not a or a <= 0 then return 0 end
    return math.random(0, a - 1)
end
function ZombRandFloat(a, b)
    if #H.rolls > 0 then return table.remove(H.rolls, 1) end
    return a + math.random() * (b - a)
end

-- 번역: 키와 인자를 그대로 이어 붙인다 (서버는 원래 모드 번역을 못 찾는다)
function getText(key, ...)
    local parts = { key }
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    return table.concat(parts, "|")
end
function getTextOrNull(key) return nil end

ModData = {}
function ModData.getOrCreate(name)
    H.moddata[name] = H.moddata[name] or {}
    return H.moddata[name]
end
function ModData.get(name) return H.moddata[name] end
function ModData.exists(name) return H.moddata[name] ~= nil end
function ModData.transmit() end

-- 이벤트: Events.X.Add(fn). H.fire("X", ...) 로 부른다
Events = setmetatable({}, {
    __index = function(t, k)
        local e = { handlers = {} }
        function e.Add(fn) e.handlers[#e.handlers + 1] = fn end
        function e.Remove() end
        rawset(t, k, e)
        return e
    end,
})
function H.fire(name, ...)
    for _, fn in ipairs(Events[name].handlers) do fn(...) end
end

-- 파일: 읽을 파일은 없고, 쓰기는 H.files 에 모은다 (브릿지 요청 파일 등)
H.files = {}
function getFileReader(path, create) return nil end
function getFileWriter(path, create, append)
    local w = { path = path, parts = {} }
    function w:write(text) self.parts[#self.parts + 1] = tostring(text) end
    function w:writeln(text) self.parts[#self.parts + 1] = tostring(text) .. "\n" end
    function w:close() H.files[self.path] = table.concat(self.parts) end
    return w
end
function getItemNameFromFullType(ft) return string.match(tostring(ft), "%.(.+)$") or tostring(ft) end

function sendServerCommand(...) end
function sendClientCommand(...) end
function sendAddItemToContainer() end
function sendRemoveItemFromContainer() end
function triggerEvent() end

function instanceof(obj, cls)
    return type(obj) == "table" and obj.__classes ~= nil and obj.__classes[cls] == true
end

-- ArrayList 흉내
function H.list(t)
    local l = { items = t }
    function l:size() return #self.items end
    function l:get(i) return self.items[i + 1] end
    function l:isEmpty() return #self.items == 0 end
    return l
end

-- ---------------------------------------------------------------- 플레이어·아이템

local nextId = 100

-- 아이템: classes = { "Food", "Radio" ... }, opts = { rotten, worn, held, questTag }
function H.newItem(fullType, opts)
    opts = opts or {}
    nextId = nextId + 1
    local classes = { InventoryItem = true }
    for _, c in ipairs(opts.classes or {}) do classes[c] = true end
    local item = { __classes = classes, id = nextId, fullType = fullType, opts = opts, mod = {} }
    if opts.questTag then item.mod.storyQuest = opts.questTag end
    function item:getID() return self.id end
    function item:getFullType() return self.fullType end
    function item:getType() return string.match(self.fullType, "%.(.+)$") or self.fullType end
    function item:getDisplayName() return opts.name or self:getType() end
    function item:getModData() return self.mod end
    function item:isRotten() return self.opts.rotten == true end
    function item:getContainer() return self.container end
    return item
end

-- 가치표: Value.cache 에 직접 넣어 ItemPool(게임 스크립트 필요)을 건너뛴다
function H.defineItem(fullType, category, value)
    StoryEngine.Value.cache[fullType] = { category = category, value = value }
end

function H.newPlayer(user, first, last)
    local p = { user = user, first = first, last = last, items = {}, x = 10000, y = 10000, z = 0, dead = false }
    local inv = { owner = p }
    function inv:getItemWithIDRecursiv(id)
        for _, it in ipairs(p.items) do
            if it.id == id then return it end
        end
        return nil
    end
    function inv:getAllEvalRecurse(fn)
        local out = {}
        for _, it in ipairs(p.items) do
            if fn(it) then out[#out + 1] = it end
        end
        return H.list(out)
    end
    function inv:getItems() return H.list(p.items) end
    function inv:getAllTypeRecurse(ft)
        local out = {}
        for _, it in ipairs(p.items) do
            if it.fullType == ft then out[#out + 1] = it end
        end
        return H.list(out)
    end
    function inv:Remove(item)
        for i, it in ipairs(p.items) do
            if it == item then
                table.remove(p.items, i)
                item.container = nil
                return
            end
        end
    end
    function inv:AddItem(ft)
        local it = H.newItem(ft)
        it.container = inv
        p.items[#p.items + 1] = it
        return it
    end
    p.inv = inv
    local desc = {}
    function desc:getForename() return p.first end
    function desc:getSurname() return p.last end
    function desc:getCharacterProfession() return { getName = function() return "unemployed" end } end
    function p:getUsername() return self.user end
    function p:getDescriptor() return desc end
    function p:getInventory() return self.inv end
    function p:isEquippedClothing(item) return item.opts.worn == true end
    function p:isEquipped(item) return item.opts.worn == true or item.opts.held == true end
    function p:removeFromHands(item) item.opts.held = false end
    function p:getX() return self.x end
    function p:getY() return self.y end
    function p:getZ() return self.z end
    function p:isDead() return self.dead end
    function p:isAlive() return not self.dead end
    function p:isAsleep() return false end
    function p:getOnlineID() return 0 end
    function p:isOutside() return true end
    function p:getCurrentSquare() return nil end
    function p:getSquare() return nil end
    function p:getBuilding() return nil end
    function p:getZombieKills() return 0 end
    function p:Say() end
    p.mod = {}
    function p:getModData() return self.mod end
    p.parts = {}
    p.hp = 100
    local body = {}
    function body:getBodyParts() return H.list(p.parts) end
    function body:getOverallBodyHealth() return p.hp end
    function p:getBodyDamage() return body end
    function p:getFitness() return { removeStiffnessValue = function() end } end
    p.__classes = { IsoPlayer = true, IsoGameCharacter = true }
    return p
end

function H.give(p, fullType, opts)
    local it = H.newItem(fullType, opts)
    it.container = p.inv
    p.items[#p.items + 1] = it
    return it
end

function getNumActivePlayers() return #H.players end
function getSpecificPlayer(i) return H.players[i + 1] end
function getPlayer() return H.players[1] end
function getOnlinePlayers() return H.list(H.players) end

function H.addPlayer(user, first, last)
    local p = H.newPlayer(user, first, last)
    H.players[#H.players + 1] = p
    return p
end

-- ---------------------------------------------------------------- 몸 상태 (닥 치료, 파이크 근육통)

-- 부위: 필드를 바로 들고 있고, 게임과 같은 이름의 메서드로 읽고 쓴다
function H.newBodyPart(name, f)
    f = f or {}
    local bp = { name = name, scratch = f.scratch or false, cut = f.cut or false, bleed = f.bleed or 0,
                 deep = f.deep or false, glass = f.glass or false, woundInf = f.woundInf or false,
                 fracture = f.fracture or 0, bullet = f.bullet or false, burn = f.burn or 0, pain = f.pain or 0,
                 stiff = f.stiff or 0, bit = f.bitten or false, infected = f.infected or false }
    function bp:scratched() return self.scratch end
    function bp:setScratched(v) self.scratch = v end
    function bp:setScratchTime() end
    function bp:isCut() return self.cut end
    function bp:setCut(v) self.cut = v end
    function bp:setCutTime() end
    function bp:getBleedingTime() return self.bleed end
    function bp:setBleedingTime(v) self.bleed = v end
    function bp:deepWounded() return self.deep end
    function bp:setDeepWounded(v) self.deep = v end
    function bp:setDeepWoundTime() end
    function bp:haveGlass() return self.glass end
    function bp:setHaveGlass(v) self.glass = v end
    function bp:isInfectedWound() return self.woundInf end
    function bp:setWoundInfectionLevel(v) self.woundInf = v > 0 end
    function bp:getFractureTime() return self.fracture end
    function bp:setFractureTime(v) self.fracture = v end
    function bp:haveBullet() return self.bullet end
    function bp:setHaveBullet(v) self.bullet = v end
    function bp:getBurnTime() return self.burn end
    function bp:setBurnTime(v) self.burn = v end
    function bp:setNeedBurnWash() end
    function bp:getAdditionalPain() return self.pain end
    function bp:setAdditionalPain(v) self.pain = v end
    function bp:getStiffness() return self.stiff end
    function bp:setStiffness(v) self.stiff = v end
    function bp:bitten() return self.bit end
    function bp:IsInfected() return self.infected end
    function bp:getType() return self.name end
    return bp
end

H.synced = {}
function syncBodyPart(bp) H.synced[#H.synced + 1] = bp end

-- ---------------------------------------------------------------- 셀: 좀비, 차량, 소리

H.zombies, H.vehicles, H.sounds = {}, {}, {}

function H.newZombie(x, y, outside)
    local z = { x = x, y = y, outside = outside ~= false, dead = false, mod = {} }
    z.__classes = { IsoZombie = true, IsoGameCharacter = true }
    function z:getX() return self.x end
    function z:getY() return self.y end
    function z:getZ() return 0 end
    function z:isDead() return self.dead end
    function z:isOutside() return self.outside end
    function z:getModData() return self.mod end
    function z:getPrimaryHandItem() return self.weapon end
    function z:Kill() self.dead = true end
    H.zombies[#H.zombies + 1] = z
    return z
end

function H.newVehicle(x, y, parts)
    local v = { x = x, y = y, id = #H.vehicles + 1, parts = {}, sent = 0 }
    for _, spec in ipairs(parts or {}) do
        local item = { cond = spec.cond, charge = 0.1 }
        function item:setCondition(c) self.cond = c end
        function item:setUsedDelta(d) self.charge = d end
        -- engine = true: 아이템 칸이 없는 부품(엔진), missing = true: 칸은 있는데 빠진 부품
        local part = { id = spec.id, cond = spec.cond, item = item, slot = not spec.engine }
        if spec.missing or spec.engine then part.item = nil end
        function part:getInventoryItem() return self.item end
        function part:getItemType()
            if not self.slot then return nil end
            return { isEmpty = function() return false end }
        end
        function part:getCondition() return self.cond end
        function part:setCondition(c) self.cond = c end
        function part:getId() return self.id end
        function part:doInventoryItemStats() end
        function part:getMechanicSkillInstaller() return 0 end
        v.parts[#v.parts + 1] = part
    end
    function v:getX() return self.x end
    function v:getY() return self.y end
    function v:getId() return self.id end
    v.sql = 5000 + v.id
    function v:getSqlId() return self.sql end
    function v:getPartCount() return #self.parts end
    function v:getPartByIndex(i) return self.parts[i + 1] end
    function v:transmitPartCondition() self.sent = self.sent + 1 end
    function v:transmitPartItem() end
    function v:updatePartStats() end
    H.vehicles[#H.vehicles + 1] = v
    return v
end

function getVehicleById(id)
    for _, v in ipairs(H.vehicles) do
        if v.id == id then return v end
    end
    return nil
end

H.cell = setmetatable({}, { __index = function() return function() return nil end end })
function H.cell:getZombieList() return H.list(H.zombies) end
-- 멀티 서버의 차량 목록처럼 size 와 toArray 만 있고 get 은 없다 (2026-09-29 인게임 호스트 로그)
function H.cell:getVehicles()
    local l = { items = H.vehicles }
    function l:size() return #self.items end
    function l:toArray() return self.items end
    return l
end
function getCell() return H.cell end

function addSound(src, x, y, z, radius, volume)
    H.sounds[#H.sounds + 1] = { x = x, y = y, radius = radius, volume = volume }
end

-- ---------------------------------------------------------------- 서버 모듈 불러오기

-- 모든 서버 모듈을 불러오고(Commands 가 전부 require 한다), 브릿지와 클라이언트 전송을 가로챈다.
function H.boot()
    require "StoryEngine/Commands"
    StoryEngine.Client = { dispatch = function(command, args) H.sent[#H.sent + 1] = { command = command, args = args } end }
    StoryEngine.Bridge.request = function(module, payload, callback, opts)
        H.bridge[#H.bridge + 1] = { module = module, payload = payload, callback = callback }
        return "req" .. tostring(#H.bridge)
    end
end

-- 클라이언트 쪽 불러오기 (UI 클래스는 Dummy). 핸들러 로직만 확인한다. 서버 모듈과 한 환경에 섞지 않는다.
function H.bootClient()
    isClient = function() return true end
    local mt = getmetatable(Dummy)
    local num = function() return 10 end
    mt.__add, mt.__sub, mt.__mul, mt.__div, mt.__unm = num, num, num, num, num
    local dirs = { "shared", "client" }
    local loadedC = {}
    require = function(name)
        if loadedC[name] ~= nil then return loadedC[name] end
        for _, dir in ipairs(dirs) do
            local rel = dir .. "/" .. name .. ".lua"
            local src = PY_READ(rel)
            if src then
                local chunk, err = loadstring(src, "@" .. rel)
                if not chunk then error(err, 0) end
                loadedC[name] = true
                local r = chunk()
                if r ~= nil then loadedC[name] = r end
                return loadedC[name]
            end
        end
        loadedC[name] = true
        return true
    end
    for _, name in ipairs(PY_LIST_CLIENT()) do require(name) end
    StoryEngine.Net.toServer = function(player, command, args)
        H.toServer = H.toServer or {}
        H.toServer[#H.toServer + 1] = { command = command, args = args }
    end
end

-- 브릿지 요청 중 조건에 맞는 마지막 것
function H.lastBridge(module, mode)
    for i = #H.bridge, 1, -1 do
        local b = H.bridge[i]
        if b.module == module and (mode == nil or b.payload.mode == mode) then return b end
    end
    return nil
end

function H.sentOf(command)
    local out = {}
    for _, s in ipairs(H.sent) do
        if s.command == command then out[#out + 1] = s.args end
    end
    return out
end

-- ---------------------------------------------------------------- 검사

function H.eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end
function H.ok(cond, msg)
    if not cond then error(msg or "assertion failed", 2) end
end
function H.near(actual, expected, tol, msg)
    if math.abs(actual - expected) > (tol or 0.001) then
        error((msg or "not close") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end
