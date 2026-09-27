-- 멀티플레이 진단 (서버 측 전용). 6단계 테스트용.
--
-- 서버에서 어떤 이벤트가 실제로 오는지 세고, 서버가 보는 플레이어 상태를 클라이언트가 보는 것과 비교한다.
-- 결과는 서버 로그와, 요청한 클라이언트의 console.txt 양쪽에 남는다.

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Bridge"

local Sensor = StoryEngine.Sensor
local log = StoryEngine.log

local Diag = {
    counts = { OnTick = 0, EveryOneMinute = 0, EveryTenMinutes = 0, OnPlayerUpdate = 0, OnZombieDead = 0,
               OnPlayerDeath = 0, OnHitZombie = 0 },
    startedMs = nil,
}
StoryEngine.Diag = Diag

local function counter(name)
    return function()
        Diag.counts[name] = Diag.counts[name] + 1
        if not Diag.startedMs then Diag.startedMs = StoryEngine.nowMs() end
    end
end

for name, _ in pairs(Diag.counts) do
    if Events[name] then Events[name].Add(counter(name)) end
end

local function moodleText(moodles)
    local parts = {}
    for name, level in pairs(moodles or {}) do parts[#parts + 1] = name .. "=" .. tostring(level) end
    table.sort(parts)
    return table.concat(parts, ",")
end

local function countKeys(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

-- client: 클라이언트가 본 값 { x, y, hp, kills, asleep, outside, wounds, moodles, events = {...}, lang }
function Diag.compare(player, client)
    client = client or {}
    local now = Sensor.now()
    local s = Sensor.sample(player, now, 0)
    local lines = {}
    local function add(text) lines[#lines + 1] = text end
    local function cmp(name, sv, cv)
        local same = tostring(sv) == tostring(cv)
        add(name .. " server=" .. tostring(sv) .. " client=" .. tostring(cv) .. (same and "" or "  <-- DIFF"))
    end
    add("role isServer=" .. tostring(isServer()) .. " isClient=" .. tostring(isClient())
        .. " bridge=" .. tostring(StoryEngine.Bridge.state))
    add("server lang=" .. StoryEngine.Journal.serverLang() .. " client lang=" .. tostring(client.lang)
        .. " sample getText=" .. getText("IGUI_StoryEngine_Mono_bored_1"))
    cmp("pos", s.x .. "," .. s.y .. "," .. s.z, tostring(client.x) .. "," .. tostring(client.y) .. "," .. tostring(client.z))
    cmp("hp", s.hp, client.hp)
    cmp("kills", s.kills, client.kills)
    cmp("asleep", s.asleep, client.asleep)
    cmp("outside", s.outside, client.outside)
    cmp("wounds", countKeys(s.wounds), client.wounds)
    cmp("moodles", moodleText(s.moodles), moodleText(client.moodles))
    local secs = Diag.startedMs and math.floor((StoryEngine.nowMs() - Diag.startedMs) / 1000) or 0
    local ev = {}
    for name, n in pairs(Diag.counts) do ev[#ev + 1] = name .. "=" .. StoryEngine.intToString(n) end
    table.sort(ev)
    add("server events in " .. StoryEngine.intToString(secs) .. "s: " .. table.concat(ev, " "))
    local cev = {}
    for name, n in pairs(client.events or {}) do cev[#cev + 1] = name .. "=" .. tostring(n) end
    table.sort(cev)
    add("client events: " .. table.concat(cev, " "))
    local ok, wrote = pcall(function()
        local w = getFileWriter(StoryEngine.Config.dataDir .. "diag.txt", true, false)
        if not w then return false end
        w:write(table.concat(lines, "\n") .. "\n")
        w:close()
        return true
    end)
    add("file write " .. tostring(ok and wrote) .. " (Zomboid/Lua/StoryEngine/diag.txt on the server machine)")
    for _, line in ipairs(lines) do log("diag", line) end
    return lines
end

return Diag
