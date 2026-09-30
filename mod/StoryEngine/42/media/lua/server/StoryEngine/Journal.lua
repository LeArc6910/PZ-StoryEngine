-- 생존 일지 (서버 측 전용). 게임 내 자정마다 그날의 일기, 사망 시 회고록.
--
-- 지난 일지 이후 쌓인 에피소드를 브릿지(journal 모듈)에 보내고, 결과를 ModData 와
-- Zomboid/Lua/StoryEngine/journals/<캐릭터>.txt 에 남긴다. 브릿지가 실패하면 규칙 기반 문장으로 대신 쓴다.
-- 일지는 서버의 모든 플레이어가 서로 읽을 수 있다 (Journal.authors / Journal.list).
-- 자정에 접속해 있지 않던 플레이어는 다시 접속했을 때 마지막으로 활동한 날의 일기가 써진다 (Sensor dayEnd).
-- 누군가 죽으면 살아 있는 모든 캐릭터의 다음 일기에 그 죽음이 들어가고(notes death_of, 함께 보낸 시간 포함),
-- 함께한 시간이 긴 순으로 최대 MAX_COMMENTERS 명이 짧은 추모를 남긴다 (회고록 아래 코멘트, ps.memoirComments).

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

Journal.TIMEOUT_MS = 120000
Journal.MAX_COMMENTERS = 8
Journal.MAX_COMMENTS = 12

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
            kills = ep.kills, zombiesNear = ep.zombiesNear, harm = ep.harm, slept = ep.slept, acts = ep.acts,
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

-- 새 일지를 접속한 모든 플레이어에게 알린다 (서로의 일지를 읽을 수 있으므로). 쓴 사람에게만 알림 문구가 뜬다.
function Journal.notify(ps, entry, player)
    local targets = Sensor.players()
    if player then
        local found = false
        for _, p in ipairs(targets) do
            if p == player then found = true end
        end
        if not found then targets[#targets + 1] = player end    -- 사망 직후처럼 목록에서 빠진 경우
    end
    for _, p in ipairs(targets) do
        local ok, err = pcall(Net.toClient, p, "journalNew",
            { key = ps.key, name = ps.name, kind = entry.kind, own = Store.playerKey(p) == ps.key })
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

-- 일기에 쓴 내용을 그날 기록에 남긴다 (회고록·아침 독백용). 자정 일지는 날이 이미 닫혀 ps.days 로 옮겨져 있다.
local function rememberDiary(ps, day, dayIndex, text)
    local short = string.sub(text, 1, 400)
    if day then day.diary = short end
    for i = #ps.days, 1, -1 do
        if ps.days[i].day == dayIndex then
            ps.days[i].diary = short
            return
        end
    end
end

-- 일기 쓰기. reason: "midnight" (그날을 닫을 때) | "debug" (지금까지의 오늘)
-- day: 일기를 쓸 날 (Sensor 의 day 테이블, 없으면 오늘)
function Journal.write(player, ps, reason, day)
    if Journal.busy[ps.key] then return false, "busy" end
    local now = Sensor.now()
    day = day or ps.day

    Sensor.flush(ps)
    local episodes = ps.pending
    if #episodes == 0 and #(ps.notes or {}) == 0 and reason ~= "debug" then return false, "empty" end
    ps.pending = {}
    ps.lastJournalT = now.t
    Journal.busy[ps.key] = true

    local lang = ps.lang or Journal.serverLang()
    local summary = day and Sensor.daySummary(day) or {}
    local dayIndex = day and day.index or Store.dayIndex(now.dayKey)
    local date = day and day.date or now.date
    local radio = ps.radioLog or {}
    ps.radioLog = {}
    local payload = {
        radio = radio,
        kind = "daily", lang = lang,
        character = { name = ps.name, profession = ps.profession },
        date = date, day = dayIndex,
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
        local entry = { kind = "daily", day = dayIndex, date = date }
        if text and text ~= "" then
            entry.text = text
        else
            entry.text, entry.lt = Journal.fallbackText(ps, episodes, summary, date)
            entry.fallback = true
            entry.error = res.error
        end
        rememberDiary(ps, day, dayIndex, entry.text)
        store(ps, entry)
        log("journal written", ps.name, entry.fallback and ("fallback " .. tostring(res.error)) or "ok")
    end, { timeoutMs = Journal.TIMEOUT_MS })
    return true
end

-- 추모에 쓸, 쓴 사람의 일기 중 죽은 사람이 나온 부분 (최근 것부터 2개)
local function mentionsOf(ps, name)
    local out = {}
    for i = #(ps.journal or {}), 1, -1 do
        local e = ps.journal[i]
        if e.kind == "daily" and type(e.text) == "string" and string.find(e.text, name, 1, true) then
            out[#out + 1] = { date = e.date, text = string.sub(e.text, 1, 300) }
            if #out >= 2 then break end
        end
    end
    return out
end

-- 살아 있는 생존자 cps 가 죽은 dps 에게 남기는 짧은 추모
function Journal.comment(cps, dps, death, now)
    local lang = cps.lang or Journal.serverLang()
    local together = cps.met and cps.met[dps.name] or 0
    local payload = {
        kind = "comment", lang = lang,
        character = { name = cps.name, profession = cps.profession },
        dead = { name = dps.name, profession = dps.profession, daysSurvived = death.survived,
                 place = localizePlace(death.place, lang), harm = death.harm, date = now.date },
        together = together,
        mentions = mentionsOf(cps, dps.name),
    }
    log("eulogy request", cps.name, "for", dps.name, "together", together)
    Bridge.request("journal", payload, function(res)
        if not (res.ok and type(res.text) == "string" and res.text ~= "") then
            log("eulogy failed", cps.name, tostring(res.error))
            return
        end
        dps.memoirComments = dps.memoirComments or {}
        Store.push(dps.memoirComments, { key = cps.key, name = cps.name, text = string.sub(res.text, 1, 600),
                                         date = now.date, together = together }, Journal.MAX_COMMENTS)
        Journal.appendFile(dps, { kind = "comment", date = now.date, day = death.survived,
                                  text = "-- " .. tostring(cps.name) .. ": " .. res.text })
        Journal.notify(dps, { kind = "comment" })
        log("eulogy written", cps.name, "for", dps.name)
    end, { timeoutMs = Journal.TIMEOUT_MS })
end

-- 누군가 죽었다: 살아 있는 모든 캐릭터의 다음 일기에 알리고, 가까웠던 사람들이 추모를 남긴다
function Journal.onDeath(ps, death, now)
    local d = Store.data()
    d.deaths = d.deaths or {}
    Store.push(d.deaths, { key = ps.key, name = ps.name, date = now.date, day = Store.dayIndex(now.dayKey),
                           town = death.place and death.place.town }, 50)
    local others = {}
    for key, other in pairs(d.players) do
        if key ~= ps.key and not other.dead and other.name and other.name ~= ps.name then
            local together = other.met and other.met[ps.name] or 0
            Store.addNote(other, { kind = "death_of", by = ps.name, place = localizePlace(death.place),
                                   together = together, clock = now.clock })
            others[#others + 1] = { ps = other, together = together }
        end
    end
    table.sort(others, function(a, b) return a.together > b.together end)
    for i = 1, math.min(#others, Journal.MAX_COMMENTERS) do
        local ok, err = pcall(Journal.comment, others[i].ps, ps, death, now)
        if not ok then log("eulogy error:", err) end
    end
    log("death noted", ps.name, "for", #others, "survivors")
    if StoryEngine.Social then
        pcall(StoryEngine.Social.onDeath, ps.name, death.place and death.place.town)
    end
    -- 함께한 일이 있는 NPC 들이 각자 반응 (Legacy.lua)
    if StoryEngine.Legacy then
        local ok, err = pcall(StoryEngine.Legacy.onDeath, ps.name, death.place and death.place.town)
        if not ok then log("legacy death error:", err) end
    end
    if StoryEngine.Banter then
        local ok, err = pcall(StoryEngine.Banter.onDeath, ps.name)
        if not ok then log("banter death error:", err) end
    end
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
    local okDeath, errDeath = pcall(Journal.onDeath, ps, { place = deathPlace, harm = harm, survived = survived }, now)
    if not okDeath then log("death note error:", errDeath) end
    local life = {}
    local all = ps.radioLife or {}
    for i = math.max(1, #all - 11), #all do life[#life + 1] = all[i] end
    local payload = {
        radio = life,
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

-- 일지를 읽을 수 있는 사람 목록 (이 서버에서 일지가 하나라도 있는 캐릭터 + 요청한 본인)
function Journal.authors(selfKey)
    local online = {}
    for _, p in ipairs(Sensor.players()) do online[Store.playerKey(p)] = true end
    local out = {}
    for key, ps in pairs(Store.data().players) do
        local count = #(ps.journal or {})
        if count > 0 or key == selfKey then
            local last = ps.journal and ps.journal[count]
            out[#out + 1] = {
                key = key, name = ps.name or "?", count = count, dead = ps.dead == true,
                online = online[key] == true, lastDate = last and last.date or nil,
            }
        end
    end
    table.sort(out, function(a, b)
        if (a.key == selfKey) ~= (b.key == selfKey) then return a.key == selfKey end
        if a.online ~= b.online then return a.online end
        return tostring(a.name) < tostring(b.name)
    end)
    -- 회고록: 죽은 캐릭터마다 따로 한 줄 (목록 끝, 최근 사망 먼저)
    local memoirs = {}
    for key, ps in pairs(Store.data().players) do
        local m = Journal.memoirOf(ps)
        if m then
            memoirs[#memoirs + 1] = { key = key, name = ps.name or "?", memoir = true, dead = true,
                                      count = #(ps.memoirComments or {}), lastDate = m.date, day = m.day }
        end
    end
    table.sort(memoirs, function(a, b) return tostring(a.lastDate) > tostring(b.lastDate) end)
    for _, m in ipairs(memoirs) do out[#out + 1] = m end
    return out
end

-- 이 캐릭터의 회고록 (없으면 nil)
function Journal.memoirOf(ps)
    for i = #(ps.journal or {}), 1, -1 do
        if ps.journal[i].kind == "memoir" then return ps.journal[i] end
    end
    return nil
end

-- 자정: 어제 하루의 일기를 쓴다
Sensor.listeners.dayEnd[#Sensor.listeners.dayEnd + 1] = function(player, ps, day)
    if StoryEngine.option("Journal", true) ~= true then return end
    local ok, why = Journal.write(player, ps, "midnight", day)
    if not ok then log("journal skipped", ps.name, "D" .. StoryEngine.intToString(day.index or 0), tostring(why)) end
end

Events.OnPlayerDeath.Add(function(player)
    local ok, err = pcall(function() Journal.memoir(player, Store.player(player)) end)
    if not ok then log("memoir error:", err) end
end)

return Journal
