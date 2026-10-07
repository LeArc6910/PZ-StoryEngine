-- 브릿지 프로세스와의 파일 기반 통신 (서버 측 전용).
--
-- Zomboid/Lua/StoryEngine/
--   requests/<id>.json    게임 → 브릿지 (브릿지가 읽고 삭제)
--   responses/<id>.json   브릿지 → 게임 (게임이 읽고 빈 파일로 덮어씀 → 브릿지가 삭제)
--   heartbeat.json        브릿지가 2초마다 seq 를 올림
--
-- B42 확인 사항: getFileWriter 는 Zomboid/Lua 기준 상대 경로에 하위 폴더를 만들어 주고 UTF-8 로 쓴다.
-- 확장자는 ini/cfg/txt/log/json 만 허용되고, ".." 이 들어간 경로는 거부된다. 파일 삭제 API 는 없다.
--
-- 폴링: OnTick 은 클라이언트 게임 루프(IngameState)에서만 발생하므로 전용 서버에서는 오지 않을 수 있다.
-- 그래서 OnTick / OnPlayerUpdate / EveryOneMinute 에 모두 걸고 실시간 기준으로 호출 간격을 제한한다.

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Json"
require "StoryEngine/Net"

local Json = StoryEngine.Json
local Config = StoryEngine.Config
local log = StoryEngine.log

local Bridge = {
    pending = {},          -- id -> { callback = fn, deadline = ms }
    seq = 0,
    session = nil,
    state = "unknown",     -- unknown | connected | disconnected
    hbSeq = nil,
    hbChangedMs = 0,
    startedMs = nil,
    lastPollMs = 0,
    lastHbCheckMs = 0,
}
StoryEngine.Bridge = Bridge

-- 요청 큐 우선순위: 디렉터 > 무전 > 일지 > 독백 > 요약 (숫자가 작을수록 먼저)
local PRIORITY = { director = 0, debug = 0, radio = 1, journal = 2, monologue = 3, summary = 4 }

local function rel(sub)
    return Config.dataDir .. sub
end

local function readFile(path)
    local reader = getFileReader(path, false)
    if not reader then return nil end
    local lines = {}
    local line = reader:readLine()
    while line do
        lines[#lines + 1] = line
        line = reader:readLine()
    end
    reader:close()
    return table.concat(lines, "\n")
end

local function writeFile(path, text, create)
    local writer = getFileWriter(path, create, false)
    if not writer then return false end
    writer:write(text)
    writer:close()
    return true
end

local function ensureInit()
    if Bridge.startedMs then return end
    Bridge.startedMs = StoryEngine.nowMs()
    Bridge.session = StoryEngine.intToString(math.floor(Bridge.startedMs / 1000) % 100000000)
    log("bridge init, session", Bridge.session)
end

local function safeCallback(callback, result)
    local ok, err = pcall(callback, result)
    if not ok then log("callback error:", err) end
end

local function setState(state)
    if Bridge.state == state then return end
    log("bridge state", Bridge.state, "->", state)
    Bridge.state = state
    if state == "disconnected" then
        -- 기다리던 요청은 폴백으로 넘긴다.
        local failed = {}
        for id, entry in pairs(Bridge.pending) do failed[#failed + 1] = { id = id, entry = entry } end
        for _, f in ipairs(failed) do
            Bridge.pending[f.id] = nil
            safeCallback(f.entry.callback, { ok = false, error = "bridge_offline" })
        end
    end
    StoryEngine.Net.toAll("status", { state = state })
end

-- 브릿지에 요청을 보낸다. callback(result) 는 반드시 한 번 호출된다.
-- result: { ok = true, text = "...", json = {...}, model = "..." } 또는 { ok = false, error = "code" }
-- 모든 요청에 붙이는 것: 후임 목소리 (브릿지가 그 채널의 페르소나를 바꾼다, Voices.lua)
function Bridge.decorate(payload)
    payload = payload or {}
    local voices, any = {}, false
    for fid, v in pairs(StoryEngine.Factions.voice or {}) do voices[fid], any = v, true end
    if any and payload.voices == nil then payload.voices = voices end
    return payload
end

function Bridge.request(module, payload, callback, opts)
    ensureInit()
    opts = opts or {}
    if Bridge.state == "disconnected" then
        safeCallback(callback, { ok = false, error = "bridge_offline" })
        return nil
    end

    Bridge.seq = Bridge.seq + 1
    local id = module .. "-" .. Bridge.session .. "-" .. StoryEngine.intToString(Bridge.seq)
    payload = Bridge.decorate(payload)
    local body = {
        v = 1,
        id = id,
        module = module,
        priority = opts.priority or PRIORITY[module] or 9,
        payload = payload,
    }

    local ok, written = pcall(writeFile, rel("requests/" .. id .. ".json"), Json.encode(body), true)
    if not ok or not written then
        log("request write failed:", id, tostring(written))
        safeCallback(callback, { ok = false, error = "write_failed" })
        return nil
    end

    Bridge.pending[id] = {
        callback = callback,
        deadline = StoryEngine.nowMs() + (opts.timeoutMs or Config.requestTimeoutMs),
    }
    return id
end

function Bridge.checkHeartbeat(now)
    local ok, text = pcall(readFile, rel("heartbeat.json"))
    local hb = ok and text and Json.decode(text) or nil
    local seq = hb and hb.seq or nil

    if seq ~= nil and seq ~= Bridge.hbSeq then
        local firstSight = Bridge.hbSeq == nil
        Bridge.hbSeq = seq
        -- 처음 본 값은 이전 세션이 남긴 파일일 수 있으니, 값이 바뀌는 걸 봐야 연결로 인정한다.
        if not firstSight then
            Bridge.hbChangedMs = now
            setState("connected")
            return
        end
    end

    local since = Bridge.state == "connected" and Bridge.hbChangedMs or Bridge.startedMs
    if now - since > Config.heartbeatTimeoutMs then
        setState("disconnected")
    end
end

function Bridge.collect(now)
    local done = {}
    for id, entry in pairs(Bridge.pending) do
        local path = rel("responses/" .. id .. ".json")
        local ok, text = pcall(readFile, path)
        if ok and text and text ~= "" then
            local res = Json.decode(text)
            if res then
                done[#done + 1] = { id = id, entry = entry, result = res }
            end
        elseif now > entry.deadline then
            done[#done + 1] = { id = id, entry = entry, result = { ok = false, error = "timeout" } }
        end
    end

    for _, d in ipairs(done) do
        Bridge.pending[d.id] = nil
        if d.result.error ~= "timeout" then
            -- 읽음 표시: 파일을 비우면 브릿지가 지운다.
            pcall(writeFile, rel("responses/" .. d.id .. ".json"), "", false)
        end
        safeCallback(d.entry.callback, d.result)
    end
end

-- Kahlua 에는 표준 함수 next 가 없다 (42.20 인게임에서 "tried to call nil" 확인).
local function hasPending()
    for _ in pairs(Bridge.pending) do
        return true
    end
    return false
end

function Bridge.tick()
    ensureInit()
    local now = StoryEngine.nowMs()
    if now - Bridge.lastPollMs < Config.pollMs then return end
    Bridge.lastPollMs = now

    if now - Bridge.lastHbCheckMs >= Config.heartbeatCheckMs then
        Bridge.lastHbCheckMs = now
        Bridge.checkHeartbeat(now)
    end
    if hasPending() then
        Bridge.collect(now)
    end
end

local function onAnyTick()
    Bridge.tick()
end

-- 바닐라 서버 파일도 OnTick / EveryOneMinute 을 등록한다. OnPlayerUpdate 는 서버 측 사용 예가 없어 존재를 확인하고 건다.
Events.OnTick.Add(onAnyTick)
Events.EveryOneMinute.Add(onAnyTick)
if Events.OnPlayerUpdate then
    Events.OnPlayerUpdate.Add(onAnyTick)
end

return Bridge
