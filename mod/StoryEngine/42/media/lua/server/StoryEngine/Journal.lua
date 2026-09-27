-- 생존 일지 (서버 측 전용). 잠들 때 일기, 사망 시 회고록.
--
-- 지난 일지 이후 쌓인 에피소드를 브릿지(journal 모듈)에 보내고, 결과를 ModData 와
-- Zomboid/Lua/StoryEngine/journals/<캐릭터>.txt 에 남긴다. 브릿지가 실패하면 규칙 기반 문장으로 대신 쓴다.

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Places"
require "StoryEngine/Store"
require "StoryEngine/Bridge"
require "StoryEngine/Sensor"

local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Places = StoryEngine.Places
local Bridge = StoryEngine.Bridge
local Net = StoryEngine.Net
local log = StoryEngine.log

local Journal = {
    busy = {},            -- playerKey -> true (세이브에 남지 않게 메모리에만)
}
StoryEngine.Journal = Journal

Journal.MIN_GAP_MIN = 6 * 60     -- 낮잠으로 일지가 여러 번 써지지 않도록
Journal.TIMEOUT_MS = 120000

function Journal.serverLang()
    local ok, name = pcall(function() return tostring(Translator.getLanguage():name()) end)
    return ok and name or "EN"
end

-- ModData 의 장소 테이블에서 보낼 필드만 복사한다 (원본은 건드리지 않음).
-- 현지어 마을 이름은 브릿지가 lang 을 보고 붙인다 (Lua 소스에 비 ASCII 문자열을 두지 않기 위해).
local function localizePlace(p, lang)
    if not p then return nil end
    return {
        town = p.town, townDist = p.townDist, landmark = p.landmark, via = p.via,
        inside = p.inside, rooms = p.rooms, residential = p.residential,
    }
end

local function localizeEpisodes(episodes, lang)
    local out = {}
    for i, ep in ipairs(episodes) do
        out[i] = {
            from = ep.from, to = ep.to, place = localizePlace(ep.place, lang), with = ep.with,
            kills = ep.kills, zombiesNear = ep.zombiesNear, harm = ep.harm, slept = ep.slept,
        }
    end
    return out
end

local function homePlace(ps, lang)
    if not ps.home then return nil end
    local p = Places.describe(ps.home.x, ps.home.y)
    p.inside = ps.home.building ~= nil or ps.home.safehouse == true
    return localizePlace(p, lang)
end

-- 주간 요약 문장 (Summary.lua). 최근 n 개
local function weekTexts(ps, n)
    local out = {}
    local weeks = ps.weeks or {}
    for i = math.max(1, #weeks - n + 1), #weeks do
        out[#out + 1] = { from = weeks[i].from, to = weeks[i].to, text = weeks[i].text }
    end
    return out
end

local function lastText(ps)
    local last = ps.journal[#ps.journal]
    return last and string.sub(last.text or "", 1, 400) or nil
end

local function safeFileName(name)
    local bad = { ["/"] = true, ["\\"] = true, [":"] = true, ["*"] = true, ["?"] = true, ['"'] = true,
                  ["<"] = true, [">"] = true, ["|"] = true, ["."] = true }
    local out = {}
    for i = 1, string.len(name) do
        local ch = string.sub(name, i, i)
        out[#out + 1] = bad[ch] and "_" or ch
    end
    local s = table.concat(out)
    if s == "" then s = "survivor" end
    return s
end

function Journal.appendFile(ps, entry)
    local ok, err = pcall(function()
        local path = StoryEngine.Config.dataDir .. "journals/" .. safeFileName(ps.name) .. ".txt"
        local w = getFileWriter(path, true, true)
        if not w then return end
        local header = "[" .. tostring(entry.date) .. " D" .. StoryEngine.intToString(entry.day or 0) .. "]"
        if entry.kind == "memoir" then header = header .. " MEMOIR" end
        if entry.fallback then header = header .. " (offline)" end
        w:write(header .. "\n" .. tostring(entry.text) .. "\n\n")
        w:close()
    end)
    if not ok then log("journal file write failed:", err) end
end

-- 플레이어가 접속해 있으면 새 일지를 알린다.
function Journal.notify(ps, entry, player)
    local target = player
    if not target then
        for _, p in ipairs(Sensor.players()) do
            if Store.playerKey(p) == ps.key then target = p end
        end
    end
    if target then
        local ok, err = pcall(Net.toClient, target, "journalNew", { entry = entry })
        if not ok then log("journal notify failed:", err) end
    end
end

-- 브릿지 없이 쓰는 일기. 표시 문장은 클라이언트가 번역하고(lt), text 는 파일과 다음 일지 요청용 영어 요약이다.
function Journal.fallbackText(ps, episodes, summary, date)
    local kills = summary and summary.kills or 0
    local place = ps.home and Places.describe(ps.home.x, ps.home.y) or nil
    local town = place and place.town or "?"
    local text = tostring(date) .. ", near " .. town .. ": killed " .. StoryEngine.intToString(kills)
        .. " zombies, " .. StoryEngine.intToString(#episodes) .. " outings. (written without the AI)"
    local lt = { key = "IGUI_StoryEngine_FallbackDiary", args = { { t = "s", v = tostring(date) },
        { t = "town", v = town }, { t = "num", v = kills }, { t = "num", v = #episodes } } }
    return text, lt
end

local function store(ps, entry, player)
    Store.push(ps.journal, entry, Store.MAX_JOURNAL)
    Journal.appendFile(ps, entry)
    Journal.notify(ps, entry, player)
end

-- 일기 쓰기. reason: "sleep" | "debug"
function Journal.write(player, ps, reason)
    if Journal.busy[ps.key] then return false, "busy" end
    local now = Sensor.now()
    if reason ~= "debug" and ps.lastJournalT and now.t - ps.lastJournalT < Journal.MIN_GAP_MIN then
        return false, "too_soon"
    end

    Sensor.flush(ps)
    local episodes = ps.pending
    if #episodes == 0 and #(ps.notes or {}) == 0 and reason ~= "debug" then return false, "empty" end
    ps.pending = {}
    ps.lastJournalT = now.t
    Journal.busy[ps.key] = true

    local lang = ps.lang or Journal.serverLang()
    local summary = ps.day and Sensor.daySummary(ps.day) or {}
    local dayIndex = ps.day and ps.day.index or Store.dayIndex(now.dayKey)
    local payload = {
        kind = "daily", lang = lang,
        character = { name = ps.name, profession = ps.profession },
        date = now.date, day = dayIndex,
        home = homePlace(ps, lang),
        summary = summary,
        episodes = localizeEpisodes(episodes, lang),
        notes = ps.notes or {},
        previous = lastText(ps),
        weeks = weekTexts(ps, 1),
    }
    ps.notes = {}
    log("journal request", ps.name, reason, "episodes", #episodes)

    Bridge.request("journal", payload, function(res)
        Journal.busy[ps.key] = nil
        local text = res.ok and res.text or nil
        local entry = { kind = "daily", day = dayIndex, date = now.date }
        if text and text ~= "" then
            entry.text = text
        else
            entry.text, entry.lt = Journal.fallbackText(ps, episodes, summary, now.date)
            entry.fallback = true
            entry.error = res.error
        end
        if ps.day then ps.day.diary = string.sub(entry.text, 1, 400) end
        store(ps, entry)
        log("journal written", ps.name, entry.fallback and ("fallback " .. tostring(res.error)) or "ok")
    end, { timeoutMs = Journal.TIMEOUT_MS })
    return true
end

-- 회고록. 사망은 서버 OnPlayerDeath 와 클라이언트 보고 양쪽에서 올 수 있어 ps.dead 로 한 번만 처리한다.
function Journal.memoir(player, ps)
    if ps.dead then return end
    ps.dead = true
    if StoryEngine.option("Journal", true) ~= true then return end
    Sensor.flush(ps)

    local now = Sensor.now()
    local lang = ps.lang or Journal.serverLang()
    local days = {}
    local covered = ps.weekCovered or 0
    for _, d in ipairs(ps.days) do
        if (d.day or 0) > covered then
            days[#days + 1] = { day = d.day, date = d.date, class = d.summary and d.summary.class, diary = d.diary }
        end
    end
    if ps.day then
        days[#days + 1] = { day = ps.day.index, date = ps.day.date, class = Sensor.classify(ps.day), diary = ps.day.diary }
    end

    local harm = {}
    if ps.prev and ps.prev.wounds then
        for w, _ in pairs(ps.prev.wounds) do
            local sep = string.find(w, ":")
            harm[#harm + 1] = { part = string.sub(w, 1, sep - 1), kind = string.sub(w, sep + 1) }
        end
    end
    local deathPlace = Places.describe(math.floor(player:getX()), math.floor(player:getY()))
    deathPlace.inside = player:isOutside() ~= true

    local recent = {}
    for i = math.max(1, #ps.pending - 4), #ps.pending do recent[#recent + 1] = ps.pending[i] end

    local survived = #days + covered
    local payload = {
        kind = "memoir", lang = lang,
        character = { name = ps.name, profession = ps.profession },
        daysSurvived = survived,
        weeks = weekTexts(ps, 40),
        death = { date = now.date, place = localizePlace(deathPlace, lang), harm = harm },
        days = days,
        episodes = localizeEpisodes(recent, lang),
    }
    log("memoir request", ps.name, "days", #days)

    Bridge.request("journal", payload, function(res)
        local entry = { kind = "memoir", day = survived, date = now.date }
        if res.ok and res.text and res.text ~= "" then
            entry.text = res.text
        else
            entry.text = ps.name .. " survived " .. StoryEngine.intToString(survived) .. " days. (written without the AI)"
            entry.lt = { key = "IGUI_StoryEngine_FallbackMemoir", args = { { t = "s", v = ps.name }, { t = "num", v = survived } } }
            entry.fallback = true
            entry.error = res.error
        end
        store(ps, entry, player)
        log("memoir written", ps.name, entry.fallback and "fallback" or "ok")
    end, { timeoutMs = Journal.TIMEOUT_MS })
end

-- 클라이언트에 보낼 일지 목록 (최근 것부터 최대 20개)
function Journal.list(ps)
    local out = {}
    for i = #ps.journal, math.max(1, #ps.journal - 19), -1 do
        out[#out + 1] = ps.journal[i]
    end
    return out
end

Sensor.listeners.sleep[#Sensor.listeners.sleep + 1] = function(player, ps, s)
    if StoryEngine.option("Journal", true) ~= true then return end
    Journal.write(player, ps, "sleep")
end

Events.OnPlayerDeath.Add(function(player)
    local ok, err = pcall(function() Journal.memoir(player, Store.player(player)) end)
    if not ok then log("memoir error:", err) end
end)

return Journal
