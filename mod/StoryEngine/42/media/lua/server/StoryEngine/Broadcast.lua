-- 게임 속 라디오 방송 (서버 측 전용, 2026-09-30). 설계: docs/IDEAS_NEXT.md 2번
--
-- 케이시의 저녁 소식 "Valley Station Evening News": 매일 19:00, 다음 날 07:00 재방송.
-- 바닐라 라디오 시스템에 채널을 하나 더한다 (server/radio/ISDynamicRadio.lua, ISWeatherChannel.lua 와 같은 방식):
--   OnLoadRadioScripts 에서 DynamicRadioChannel 등록 → RadioBroadCast + RadioLine 으로 방송을 채워 setAiringBroadcast.
--   라디오 스크립트는 서버(싱글)에서만 돌고 줄은 서버가 클라이언트로 보낸다 (jar: ZomboidRadio.Init 은 클라이언트면
--   서버 데이터를 요청만 하고 OnLoadRadioScripts 를 부르지 않는다, RadioChannel.update -> SendTransmission).
-- 재료(서버가 모음): 모든 NPC 에게 퍼진 소식(Social.news "all": 죽음, 헬기, 충돌, 프로젝트 완성, NPC 의 죽음·떠남),
--   폭풍, 지난 24시간에 끝난 퀘스트·위기 선택, 핵심 자원이 바닥인 NPC, 돌아다니는 추적 무리, 내일 날씨(기후 예보).
-- 브릿지 broadcast 모듈이 진행자 말투로 6~10줄을 쓴다. 방송 줄은 한 언어(접속자 중 가장 많은 언어)다.
-- AI 가 실패하면 그날 방송은 쉰다. 케이시가 없으면 레이가 이어받고, 둘 다 없으면 잡음만.
-- 들은 사람(라디오를 그 주파수에 맞추고 켜 둔 사람, 클라이언트 BroadcastClient 가 확인)의 일지에 broadcast_heard 메모.
-- 상태: d.broadcast = { lastDay, facts = { {t, text} }, last = { airId, host, lang, lines, rerun, dayKey, t, airedT, heard } }
--       주파수는 GameTime ModData (라디오 초기화 때 전역 ModData 보다 먼저 읽을 수 있다, 바닐라 DynamicRadio 와 같음)

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Net"
require "StoryEngine/Bridge"
require "StoryEngine/Radio"
require "StoryEngine/Stories"

local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Net = StoryEngine.Net
local Bridge = StoryEngine.Bridge
local Radio = StoryEngine.Radio
local Stories = StoryEngine.Stories
local log = StoryEngine.log

local Broadcast = {}
StoryEngine.Broadcast = Broadcast

Broadcast.FREQ = 105400                 -- 105.4 MHz. 라디오는 0.2 MHz 단위로만 맞출 수 있다
Broadcast.FREQ_MIN, Broadcast.FREQ_MAX = 88000, 108000
Broadcast.UUID = "STORYENGINE-VALLEY-711993"
Broadcast.NAME = "Valley Station Evening News"
Broadcast.HOUR = 19
Broadcast.REPEAT_HOUR = 7
Broadcast.REPEAT_WITHIN_MIN = 18 * 60   -- 저녁 방송 뒤 이 안에서만 재방송
Broadcast.LISTEN_MIN = 60               -- 방송이 시작된 뒤 이만큼 동안 들은 사람을 받는다
Broadcast.HOSTS = { "casey", "ray" }
Broadcast.MAX_LINES = 10
Broadcast.MAX_LINE = 200
Broadcast.FACTS_MAX = 12
Broadcast.FACT_TTL_MIN = 24 * 60
Broadcast.NOTE_LINES = 4
Broadcast.COLOR = { 0.6, 0.85, 1.0 }

local RES_WORDS = { food = "food", medical = "medicine", safety = "ammunition and defenses", morale = "hope" }
local KIND_DONE = {
    deliver = "brought what was needed to", fetch = "recovered a lost package for", horde = "cleared out a pack of the dead for",
    supply_drop = "picked up a supply cache from", trade = "closed a trade with", extort = "paid off a threat from",
}
local KIND_FAIL = {
    deliver = "a delivery for", fetch = "a search for a lost package for", horde = "a job clearing the dead for",
    supply_drop = "a supply cache from", trade = "a trade with", extort = "a payment demanded by",
}

function Broadcast.enabled() return StoryEngine.option("Broadcast", true) == true end

local function state()
    local d = Store.data()
    d.broadcast = d.broadcast or {}
    d.broadcast.facts = d.broadcast.facts or {}
    return d.broadcast
end

local function nameOf(fid) return Stories.NAMES[fid] or fid end
local function clip(s, n) s = tostring(s or ""); return #s > n and string.sub(s, 1, n) or s end

-- "105.4"
function Broadcast.freqText(freq)
    freq = freq or Broadcast.freq or Broadcast.FREQ
    local mhz = math.floor(freq / 1000)
    local dec = math.floor((freq % 1000) / 100)
    return StoryEngine.intToString(mhz) .. "." .. StoryEngine.intToString(dec)
end

-- ---------------------------------------------------------------- 채널 등록

-- 다른 채널이 쓰지 않는 주파수 (같은 uuid 는 우리 것)
local function freeFreq(scriptManager, want)
    local used = {}
    local ok = pcall(function()
        local list = scriptManager:getChannelsList()
        for i = 0, list:size() - 1 do
            local ch = list:get(i)
            if ch and ch:getGUID() ~= Broadcast.UUID then used[ch:GetFrequency()] = true end
        end
    end)
    if not ok then return want end
    local f = want
    for _ = 1, 50 do
        if not used[f] then return f end
        f = f + 200
        if f > Broadcast.FREQ_MAX then f = Broadcast.FREQ_MIN + 400 end
    end
    return want
end

function Broadcast.onLoadRadioScripts(scriptManager, isNewGame)
    local ok, err = pcall(function()
        local md = getGameTime():getModData()
        local freq = freeFreq(scriptManager, tonumber(md.storyEngineBroadcastFreq) or Broadcast.FREQ)
        md.storyEngineBroadcastFreq = freq
        local ch = DynamicRadioChannel.new(Broadcast.NAME, freq, ChannelCategory.Radio, Broadcast.UUID)
        scriptManager:AddChannel(ch, false)
        Broadcast.channel = ch
        Broadcast.freq = freq
        log("broadcast channel", Broadcast.freqText(freq))
    end)
    if not ok then log("broadcast channel error:", err) end
end

Events.OnLoadRadioScripts.Add(Broadcast.onLoadRadioScripts)

-- ---------------------------------------------------------------- 재료

-- 모두가 알게 된 소식 (Social.news "all", 폭풍)
function Broadcast.note(text)
    Store.push(state().facts, { t = Sensor.now().t, text = clip(text, 300) }, Broadcast.FACTS_MAX * 2)
end

local function aliveHost()
    for _, fid in ipairs(Broadcast.HOSTS) do
        if Factions.byId[fid] and not Factions.isGone(fid) then return fid end
    end
    return nil
end
Broadcast.host = aliveHost

local function questFacts(now, out)
    local list = {}
    for _, q in pairs(Store.data().quests or {}) do
        if q.endedT and now.t - q.endedT <= Broadcast.FACT_TTL_MIN then list[#list + 1] = q end
    end
    table.sort(list, function(a, b) return a.endedT > b.endedT end)
    for _, q in ipairs(list) do
        local fid = q.origin and q.origin.faction
        local who = q.targetName or "the players"
        local town = q.place and q.place.town
        local where = town and (" near " .. tostring(town)) or ""
        if q.kind == "choice" and q.chosen then
            local c = Stories.crisis and Stories.crisis(q.crisis)
            out[#out + 1] = "When " .. (c and c.situation and clip(c.situation, 160) or "a crisis hit") .. ", "
                .. who .. " chose to help " .. nameOf(q.chosen) .. "."
        elseif fid and q.state == "completed" and KIND_DONE[q.kind] then
            out[#out + 1] = who .. " " .. KIND_DONE[q.kind] .. " " .. nameOf(fid) .. where .. "."
        elseif fid and q.state == "failed" and KIND_FAIL[q.kind] then
            out[#out + 1] = "Things went wrong with " .. KIND_FAIL[q.kind] .. " " .. nameOf(fid) .. where .. "."
        end
    end
end

local function lifeFacts(out)
    local Life = StoryEngine.Life
    if not Life then return end
    local n = 0
    for _, f in ipairs(Factions.list) do
        local res = Life.KEY[f.id]
        if res and not Factions.isGone(f.id) and Life.get(f.id, res) < 20 and n < 3 then
            out[#out + 1] = nameOf(f.id) .. "'s people are running short of " .. RES_WORDS[res] .. "."
            n = n + 1
        end
    end
end

-- 지난 24시간의 사실 (영어, 새것 먼저)
function Broadcast.gather(now)
    local out = {}
    local s = state()
    local kept = {}
    for _, f in ipairs(s.facts) do
        if now.t - f.t <= Broadcast.FACT_TTL_MIN then kept[#kept + 1] = f end
    end
    s.facts = kept
    for i = #kept, 1, -1 do out[#out + 1] = kept[i].text end
    questFacts(now, out)
    lifeFacts(out)
    local hunts = 0
    for _ in pairs(Store.data().hunts or {}) do hunts = hunts + 1 end
    if hunts > 0 then out[#out + 1] = "A large pack of the dead is roaming the county, following someone's trail." end
    local seen, uniq = {}, {}
    for _, t in ipairs(out) do
        if not seen[t] and #uniq < Broadcast.FACTS_MAX then seen[t] = true; uniq[#uniq + 1] = t end
    end
    return uniq
end

-- 내일 날씨 (영어 한 줄, 실패하면 nil)
function Broadcast.weather()
    local ok, text = pcall(function()
        local fc = getClimateManager():getClimateForecaster():getForecast(1)
        if not fc then return nil end
        local t = fc:getTemperature()
        local bits = { "Tomorrow: " .. StoryEngine.intToString(t:getTotalMin()) .. " to "
            .. StoryEngine.intToString(t:getTotalMax()) .. " C" }
        if fc:isHasHeavyRain() then bits[#bits + 1] = "heavy rain" end
        if fc:isHasStorm() then bits[#bits + 1] = "a storm" end
        if fc:isHasTropicalStorm() then bits[#bits + 1] = "a tropical storm" end
        if fc:isHasBlizzard() then bits[#bits + 1] = "a blizzard" end
        if fc:isHasFog() then bits[#bits + 1] = "fog" end
        if fc:isChanceOnSnow() then bits[#bits + 1] = "a chance of snow" end
        if #bits == 1 then bits[#bits + 1] = fc:isWeatherStarts() and "some rain" or "mostly dry" end
        return table.concat(bits, ", ")
    end)
    return ok and text or nil
end

-- 접속자 중 가장 많은 언어
function Broadcast.language(host)
    local count, best, bestN = {}, nil, 0
    for _, p in ipairs(Sensor.players()) do
        local lang = Store.player(p).lang
        if lang then
            count[lang] = (count[lang] or 0) + 1
            if count[lang] > bestN then best, bestN = lang, count[lang] end
        end
    end
    return best or Radio.langFor(host or "casey")
end

-- ---------------------------------------------------------------- 방송

local function newId() return "SE-" .. StoryEngine.intToString(ZombRand(100000, 999999)) end

local function airLines(lines)
    if not Broadcast.channel then
        log("broadcast: no radio channel (OnLoadRadioScripts did not run)")
        return false
    end
    local c = Broadcast.COLOR
    local ok, err = pcall(function()
        local bc = RadioBroadCast.new(newId(), -1, -1)
        for _, text in ipairs(lines) do bc:AddRadioLine(RadioLine.new(text, c[1], c[2], c[3])) end
        Broadcast.channel:setAiringBroadcast(bc)
    end)
    if not ok then log("broadcast air error:", err) end
    return ok
end

-- 저장된 방송을 내보낸다 (rerun 이면 재방송 안내 줄을 먼저)
function Broadcast.air(b, rerun)
    local lines = {}
    if rerun and b.rerun then lines[1] = b.rerun end
    for _, l in ipairs(b.lines) do lines[#lines + 1] = l end
    if not airLines(lines) then return false end
    local now = Sensor.now()
    b.airId = newId()
    b.airedT = now.t
    if rerun then b.repeatDay = now.dayKey end
    Net.toAll("broadcastAir", { id = b.airId, freq = Broadcast.freq or Broadcast.FREQ, host = b.host,
                                minutes = Broadcast.LISTEN_MIN, rerun = rerun or nil })
    log("broadcast aired", b.host, rerun and "rerun" or "evening", #lines, "lines on", Broadcast.freqText())
    return true
end

-- 오늘 저녁 방송을 만든다. 반환: ok, 이유
function Broadcast.build(now, force)
    local s = state()
    if Broadcast.busy then return false, "busy" end
    s.lastDay = now.dayKey
    local host = aliveHost()
    if not host then
        airLines({ "<fzzt>", "...", "<bzzt>" })
        log("broadcast: nobody left to host, static only")
        return false, "no_host"
    end
    local lang = Broadcast.language(host)
    local ctx = StoryEngine.Social and StoryEngine.Social.context(host) or {}
    local payload = {
        host = host, lang = lang, day = Store.dayIndex(now.dayKey), clock = now.clock,
        freq = Broadcast.freqText(), facts = Broadcast.gather(now), weather = Broadcast.weather(), beat = ctx.beat,
        conditions = StoryEngine.World and StoryEngine.World.conditions() or nil,
    }
    Broadcast.busy = true
    log("broadcast requested", host, lang, #payload.facts, "facts")
    Bridge.request("broadcast", payload, function(res)
        Broadcast.busy = false
        local lines = {}
        local json = res.ok and res.json
        for _, l in ipairs(type(json) == "table" and type(json.lines) == "table" and json.lines or {}) do
            if type(l) == "string" and l ~= "" and #lines < Broadcast.MAX_LINES then
                lines[#lines + 1] = clip(l, Broadcast.MAX_LINE)
            end
        end
        if #lines == 0 then
            log("broadcast failed, no show tonight:", tostring(res.error))
            return
        end
        local b = { host = host, lang = lang, lines = lines, dayKey = Sensor.now().dayKey, t = Sensor.now().t,
                    rerun = type(json.rerun) == "string" and json.rerun ~= "" and clip(json.rerun, Broadcast.MAX_LINE) or nil,
                    heard = {} }
        state().last = b
        Broadcast.air(b, false)
        if StoryEngine.Social then
            StoryEngine.Social.news(host, "You read the evening news on " .. Broadcast.freqText() .. " tonight: "
                .. clip(table.concat(lines, " "), 220))
        end
    end, { timeoutMs = 60000 })
    return true
end

-- 게임 내 10분마다
function Broadcast.tick()
    if not Broadcast.enabled() or #Sensor.players() == 0 then return end
    local now = Sensor.now()
    local hour = getGameTime():getHour()
    local s = state()
    if hour >= Broadcast.HOUR and s.lastDay ~= now.dayKey then
        Broadcast.build(now)
        return
    end
    local b = s.last
    if b and hour >= Broadcast.REPEAT_HOUR and hour < 12 and b.dayKey ~= now.dayKey and b.repeatDay ~= now.dayKey
        and now.t - b.t <= Broadcast.REPEAT_WITHIN_MIN then
        Broadcast.air(b, true)
    end
end

-- 클라이언트: 이 플레이어가 라디오로 방송을 들었다
function Broadcast.heard(player, airId)
    local s = state()
    local b = s.last
    if not b or b.airId ~= airId then return false, "stale" end
    local now = Sensor.now()
    if now.t - (b.airedT or 0) > Broadcast.LISTEN_MIN + 10 then return false, "late" end
    local ps = Store.player(player)
    b.heard = b.heard or {}
    if b.heard[ps.key] then return false, "dup" end
    b.heard[ps.key] = true
    local lines = {}
    for i = 1, math.min(Broadcast.NOTE_LINES, #b.lines) do lines[i] = b.lines[i] end
    Store.addNote(ps, { kind = "broadcast_heard", faction = b.host, clock = now.clock, lines = lines })
    log("broadcast heard by", ps.name)
    return true
end

function Broadcast.statusText()
    local s = state()
    local b = s.last
    local heard = 0
    for _ in pairs(b and b.heard or {}) do heard = heard + 1 end
    return "broadcast " .. Broadcast.freqText() .. (Broadcast.channel and "" or " (no channel)")
        .. " host=" .. tostring(aliveHost()) .. " facts=" .. StoryEngine.intToString(#s.facts)
        .. (b and (" last=" .. tostring(b.dayKey) .. " heard=" .. StoryEngine.intToString(heard)) or " last=none")
end

Events.EveryTenMinutes.Add(function()
    local ok, err = pcall(Broadcast.tick)
    if not ok then log("broadcast tick error:", err) end
end)

return Broadcast
