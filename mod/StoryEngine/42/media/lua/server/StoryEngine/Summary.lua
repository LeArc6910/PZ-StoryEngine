-- 스토리 로그 압축 (서버 측 전용).
--
-- 1. 주간 요약: 관측한 날이 7일 쌓이면 그 주의 하루 기록·일기 발췌를 브릿지(summary 모듈)로 요약해 ps.weeks 에 남긴다.
--    일지(지난주 흐름), 회고록(오래된 날 대신), 디렉터(최근 흐름)가 이 요약을 읽는다. 브릿지가 실패하면 규칙 기반 요약.
-- 2. 무전 기억: AI 에게는 채널의 최근 PROMPT_HISTORY 줄만 보내므로, 그 창 밖으로 밀려나는 대화를 요약해
--    ch.memory 에 합친다 (브릿지가 페르소나의 "What you remember from earlier talks" 로 넣는다). 실패하면 다음에 다시 한다.
-- 둘 다 게임 내 10분마다(Sensor tick) 확인하고, 요약 요청은 우선순위가 가장 낮다.

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Store"
require "StoryEngine/Bridge"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Radio"

local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Bridge = StoryEngine.Bridge
local Factions = StoryEngine.Factions
local Radio = StoryEngine.Radio
local log = StoryEngine.log

local Summary = {
    busy = {},        -- ps.key 또는 "radio:<fid>" -> true
}
StoryEngine.Summary = Summary

Summary.WEEK_DAYS = 7
Summary.MAX_WEEKS = 40
Summary.MEMORY_BATCH = 12        -- 창 밖으로 밀려난 메시지가 이만큼 쌓이면 요약한다
Summary.MAX_MEMORY_LINES = 40
Summary.TIMEOUT_MS = 120000

local function langOf(ps)
    if ps and ps.lang then return ps.lang end
    return StoryEngine.Journal and StoryEngine.Journal.serverLang() or "EN"
end

-- ---------------------------------------------------------------- weekly

-- 규칙 기반 주간 요약 (영어, 브릿지 실패 시)
function Summary.fallbackWeek(days)
    local counts, kills, harmed = {}, 0, 0
    for _, d in ipairs(days) do
        local s = d.summary or {}
        counts[s.class or "unknown"] = (counts[s.class or "unknown"] or 0) + 1
        kills = kills + (s.kills or 0)
        if s.harmed then harmed = harmed + 1 end
    end
    local parts = {}
    for class, n in pairs(counts) do parts[#parts + 1] = StoryEngine.intToString(n) .. " " .. class end
    table.sort(parts)
    return "Days " .. StoryEngine.intToString(days[1].day or 0) .. "-" .. StoryEngine.intToString(days[#days].day or 0)
        .. ": " .. table.concat(parts, ", ") .. "; killed " .. StoryEngine.intToString(kills) .. " zombies"
        .. (harmed > 0 and ("; hurt on " .. StoryEngine.intToString(harmed) .. " days") or "") .. "."
end

function Summary.checkWeeks(ps)
    if Summary.busy[ps.key] or ps.dead then return end
    ps.weeks = ps.weeks or {}
    local covered = ps.weekCovered or 0
    local pending = {}
    for _, d in ipairs(ps.days or {}) do
        if (d.day or 0) > covered then pending[#pending + 1] = d end
    end
    if #pending < Summary.WEEK_DAYS then return end
    local week = {}
    for i = 1, Summary.WEEK_DAYS do week[i] = pending[i] end
    local payload = {
        kind = "week", lang = langOf(ps),
        character = { name = ps.name, profession = ps.profession },
        days = {},
    }
    for _, d in ipairs(week) do
        local s = d.summary or {}
        payload.days[#payload.days + 1] = { day = d.day, date = d.date, class = s.class, kills = s.kills,
                                            harmed = s.harmed, diary = d.diary }
    end
    Summary.busy[ps.key] = true
    local from, to = week[1].day, week[#week].day
    Bridge.request("summary", payload, function(res)
        Summary.busy[ps.key] = nil
        local text = res.ok and type(res.text) == "string" and res.text ~= "" and string.sub(res.text, 1, 1200) or nil
        local entry = { from = from, to = to, text = text or Summary.fallbackWeek(week), fallback = text == nil or nil }
        Store.push(ps.weeks, entry, Summary.MAX_WEEKS)
        ps.weekCovered = to
        log("week summary", ps.name, "D" .. StoryEngine.intToString(from) .. "-" .. StoryEngine.intToString(to),
            text and "ok" or ("fallback " .. tostring(res.error)))
    end, { timeoutMs = Summary.TIMEOUT_MS })
end

-- 최근 주간 요약 문장들 (최근 것 n 개, 오래된 것부터)
function Summary.recentWeeks(ps, n)
    local out = {}
    local weeks = ps.weeks or {}
    for i = math.max(1, #weeks - n + 1), #weeks do out[#out + 1] = weeks[i] end
    return out
end

-- ---------------------------------------------------------------- radio memory

local function lineFor(m)
    if m.from == "player" then return tostring(m.name or "someone") .. ": " .. string.sub(tostring(m.text or ""), 1, 200) end
    if m.from == "npc" then return "You: " .. string.sub(tostring(m.text or ""), 1, 200) end
    if m.from == "system" and m.offer then return "(you offered them a trade)" end
    if m.from == "system" and m.revised then return "(you changed the terms of your trade offer after haggling)" end
    if m.from == "system" and m.swapped then return "(you offered different goods in your trade after haggling)" end
    if m.from == "system" and m.withdrawn then return "(you called off your trade offer)" end
    if m.from == "system" and m.trust then
        return "(your trust in them changed by " .. tostring(m.trust) .. ": " .. tostring(m.reason) .. ")"
    end
    return nil
end

function Summary.checkMemory(fid)
    local key = "radio:" .. fid
    if Summary.busy[key] then return end
    local ch = Radio.channel(fid)
    local upto = (ch.seq or 0) - Radio.PROMPT_HISTORY     -- 이 번호까지는 프롬프트 창 밖
    local from = ch.memorySeq or 0
    if upto - from < Summary.MEMORY_BATCH then return end
    local lines, last = {}, from
    for _, m in ipairs(ch.messages) do
        if m.n and m.n > from and m.n <= upto then
            local l = lineFor(m)
            if l then lines[#lines + 1] = "[" .. tostring(m.clock or "") .. "] " .. l end
            last = m.n
        end
    end
    if #lines == 0 then
        ch.memorySeq = upto
        return
    end
    while #lines > Summary.MAX_MEMORY_LINES do table.remove(lines, 1) end
    Summary.busy[key] = true
    Bridge.request("summary", { kind = "radio_memory", faction = fid, previous = ch.memory, lines = lines },
        function(res)
            Summary.busy[key] = nil
            if res.ok and type(res.text) == "string" and res.text ~= "" then
                ch.memory = string.sub(res.text, 1, 1500)
                ch.memorySeq = math.max(last, upto)
                log("radio memory", fid, "updated through", ch.memorySeq)
            else
                log("radio memory failed", fid, tostring(res.error))
            end
        end, { timeoutMs = Summary.TIMEOUT_MS })
end

-- ---------------------------------------------------------------- tick

Sensor.listeners.tick[#Sensor.listeners.tick + 1] = function(entries, now)
    for _, e in ipairs(entries) do
        local ok, err = pcall(Summary.checkWeeks, e.ps)
        if not ok then log("week summary error:", err) end
    end
    for _, f in ipairs(Factions.list) do
        local ok, err = pcall(Summary.checkMemory, f.id)
        if not ok then log("radio memory error:", err) end
    end
end

return Summary
