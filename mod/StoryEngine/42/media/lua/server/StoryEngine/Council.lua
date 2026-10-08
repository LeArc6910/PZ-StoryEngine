-- 공동 결말 「카운티 회의」 (2026-10-07, docs/STORY_YEAR_PLAN.md F): 케이시 5장과 파이크 5장을 하나로 묶은 1년 이야기의
-- 마지막 큰 장면. 케이시(또는 후임 노라)의 방송으로, 파이크(또는 후임 에스더)의 교회에서 첫 카운티 회의를 연다.
--
-- 열리는 때(하루 한 번 확인): 케이시·파이크 채널 중 하나라도 준비됐고(처음 사람이 5장 대기 장면 casey5_1/pike5_1 에
-- 있거나, 후임이 자기 이야기를 마쳤음), 살아 있는 채널 중 Council.READY_MIN 명 이상이 4장(또는 후임 이야기)을 마쳤을 때,
-- 또는 다른 사람의 5장 결말이 처음 나온 지 Council.LATE_DAYS 일 x 이야기 속도가 지났을 때.
-- 단계: 준비 모금(collect, 4일) -> 회의 날 교회로 몰려드는 망자 소탕(horde, 3일) -> 회의(공용 주파수 장면) -> 결말.
-- 결말: 모금을 70% 이상 채움 / 소탕 성공 / 살아 있는 NPC 평균 신뢰도 50 이상 중 둘 이상이면 "카운티 의회"
-- (모든 NPC 사기 +15, 케이시·파이크와 모두의 사이 +1), 아니면 다툼으로 끝남(사기 -10, 휘태커·빅 사이 -1).
-- 케이시·파이크의 이야기는 단계마다 <npc>5_2 / 5_3 / 5_9a|5_9b 로 함께 움직인다 (처음 사람만, 늦게 5장에 온 쪽은 결과로 바로).
-- 상태: d.council = { stage, startT, collectId, hordeId, prep, cleared, result, doneT, firstFinalT }

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Radio"
require "StoryEngine/Stories"
require "StoryEngine/Quests"

local Net = StoryEngine.Net
local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Radio = StoryEngine.Radio
local Stories = StoryEngine.Stories
local Quests = StoryEngine.Quests
local log = StoryEngine.log

local Council = {}
StoryEngine.Council = Council

Council.READY_MIN = 6
Council.LATE_DAYS = 30
Council.COLLECT_DAYS = 4
Council.HORDE_DAYS = 3
Council.PREP_SHARE = 0.7
Council.TRUST_AVG = 50
Council.NEED = { { "Base.TinnedSoup", 6 }, { "Base.Candle", 6 }, { "Base.Battery", 4 }, { "Base.Sheet", 4 } }
Council.HOSTS = { casey = "casey5_", pike = "pike5_" }

local function state()
    local d = Store.data()
    d.council = d.council or {}
    return d.council
end

function Council.state() return state() end

local function Social() return StoryEngine.Social end

local function original(fid)
    return not (StoryEngine.Voices and StoryEngine.Voices.of(fid))
end

-- 이 채널의 이야기가 4장(또는 후임 이야기)을 마쳤는가
local function finishedFour(fid)
    if Factions.isGone(fid) then return false end
    local S = Social()
    local st = S.story(fid)
    local node = Stories.node(fid, st.ep and st.ep.node or st.node)
    if not node then return false end
    local ch = node.chapter
    if ch == 5 then return true end
    if (ch == 4 or ch == "s") and node.final then return true end
    return false
end

-- 케이시·파이크 채널이 회의를 열 준비가 됐는가
local function hostReady(fid)
    if Factions.isGone(fid) then return false end
    local st = Social().story(fid)
    if original(fid) then return st.node == Council.HOSTS[fid] .. "1" end
    local node = Stories.node(fid, st.node)
    return node ~= nil and node.final == true
end

function Council.readyCount()
    local done, living = 0, 0
    for _, f in ipairs(Factions.list) do
        if not Factions.isGone(f.id) then
            living = living + 1
            if finishedFour(f.id) then done = done + 1 end
        end
    end
    return done, living
end

-- 다른 사람의 5장 결말을 처음 본 때 (늦게라도 회의를 연다)
local function noteFirstFinal(now)
    local s = state()
    if s.firstFinalT then return end
    for _, f in ipairs(Factions.list) do
        if not Council.HOSTS[f.id] then
            local node = Stories.node(f.id, Social().story(f.id).node)
            if node and node.chapter == 5 and node.final then s.firstFinalT = now.t return end
        end
    end
end

function Council.shouldStart(now)
    local s = state()
    if s.stage then return false end
    if not (hostReady("casey") or hostReady("pike")) then return false end
    local done, living = Council.readyCount()
    if done >= math.min(Council.READY_MIN, living) then return true end
    local pace = Social().pace and Social().pace() or 1
    return s.firstFinalT ~= nil and now.t - s.firstFinalT >= Council.LATE_DAYS * pace * 24 * 60
end

-- 케이시·파이크(처음 사람)의 이야기를 이 단계 장면으로
local function moveHosts(step, now)
    for fid, prefix in pairs(Council.HOSTS) do
        if not Factions.isGone(fid) and original(fid) then
            local st = Social().story(fid)
            local node = Stories.node(fid, st.node)
            if node and node.chapter == 5 and not node.final then Social().moveTo(fid, prefix .. step, now) end
        end
    end
end

local function hostOf()
    for _, fid in ipairs({ "pike", "casey" }) do
        if not Factions.isGone(fid) then return fid end
    end
    return nil
end

local function anyPlayer()
    local players = Sensor.players()
    if #players == 0 then return nil end
    return Store.player(players[ZombRand(#players) + 1])
end

-- 다른 사람들의 5장 결과 (회의 안건, AI 에게 넘기는 영어)
function Council.agenda()
    local out = {}
    for _, f in ipairs(Factions.list) do
        if not Council.HOSTS[f.id] and not Factions.isGone(f.id) then
            local node = Stories.node(f.id, Social().story(f.id).node)
            if node and node.chapter == 5 then
                out[#out + 1] = tostring(Stories.NAMES[f.id]) .. ": " .. tostring(node.beat)
            end
        end
    end
    return out
end

function Council.start(now)
    local s = state()
    s.stage, s.startT = "collect", now.t
    s.prep, s.cleared, s.result = nil, nil, nil
    moveHosts("2", now)
    local ps = anyPlayer()
    local q = Quests.createCollect(ps, Council.NEED, now, { council = true, source = "council", faction = hostOf() or "pike" },
        now.t + math.floor(Council.COLLECT_DAYS * 24 * 60))
    s.collectId = q and q.id or nil
    for _, fid in ipairs({ "casey", "pike" }) do
        local ready = original(fid) and Social().story(fid).node == Council.HOSTS[fid] .. "2"
        local voiced = not original(fid)
        if not Factions.isGone(fid) and (ready or voiced) then
            local other = fid == "casey" and "pike" or "casey"
            local partner = not Factions.isGone(other) and tostring(Stories.NAMES[other]) or nil
            Radio.react(fid, "event", (partner and ("You and " .. partner .. " are calling") or "You are calling")
                .. " the first county council since the fall, at the March Ridge church, broadcast on the radio. "
                .. "Everyone on the air is invited. Ask the players to help gather food, candles, batteries and blankets for it "
                .. "(they can send them in the quest log).",
                { text = "We are calling a county council at the church. Help us get ready.",
                  lt = ready and StoryEngine.Lines.story(Council.HOSTS[fid] .. "2") or { key = "IGUI_StoryEngine_Council_Call" } }, nil)
        end
    end
    if Social().news then
        local callers = {}
        for _, fid in ipairs({ "casey", "pike" }) do
            if not Factions.isGone(fid) then callers[#callers + 1] = tostring(Stories.NAMES[fid]) end
        end
        Social().news("all", (#callers > 0 and table.concat(callers, " and ") or "People on the radio")
            .. " are calling the first county council at the March Ridge church.")
    end
    pcall(Net.toAll, "councilNotice", { stage = "collect" })
    log("council start", s.collectId)
end

local function collectShare(q)
    if not q then return 0 end
    local need, got = 0, 0
    for _, n in ipairs(q.need or {}) do
        need = need + n[2]
        got = got + math.min(n[2], (q.got or {})[n[1]] or 0)
    end
    return need > 0 and got / need or 0
end

function Council.startHorde(now)
    local s = state()
    local q = Store.data().quests[s.collectId or ""]
    s.prep = collectShare(q)
    s.stage = "horde"
    moveHosts("3", now)
    local pike = Factions.byId.pike
    local ps = anyPlayer()
    local hq = Quests.createSite("horde", ps, { x = pike.x, y = pike.y, name = "March Ridge church" }, now,
        { council = true, source = "council", faction = "pike" },
        { tier = 3, size = Quests.HORDE_SIZE[3], building = true, search = 40,
          deadlineT = now.t + math.floor(Council.HORDE_DAYS * 24 * 60) })
    s.hordeId = hq and hq.id or nil
    if hq then hq.tier = 3 end
    local host = hostOf()
    if host then
        Radio.react(host, "event", "The dead are gathering around the March Ridge church the day before the county council. "
            .. "Ask the players to clear them so people can come safely.",
            { text = "The dead are gathering around the church before the council.",
              lt = original(host) and StoryEngine.Lines.story(Council.HOSTS[host] .. "3") or { key = "IGUI_StoryEngine_Council_HordeCall" } }, nil)
    end
    pcall(Net.toAll, "councilNotice", { stage = "horde" })
    log("council horde", s.hordeId, "prep", s.prep)
end

function Council.avgTrust()
    local sum, n = 0, 0
    for _, f in ipairs(Factions.list) do
        if not Factions.isGone(f.id) then
            sum, n = sum + (Radio.channel(f.id).trust or 0), n + 1
        end
    end
    return n > 0 and sum / n or 0
end

-- 개인 모드 (DESIGN_PER_PLAYER_TRUST 5-1절, 2026-10-09 사용자 결정): 회의가 서면 회의 퀘스트(준비 모금·교회 소탕)에
-- 손을 보탠 사람마다 회의를 연 케이시·파이크(남아 있는 쪽, 후임 포함)에게 개인 신뢰 +2. 싱글·공유 모드는 없음
Council.HELPER_TRUST = 2

function Council.rewardHelpers()
    local Trust = StoryEngine.Trust
    if not Trust or not Trust.personalMode() then return 0 end
    local s = state()
    local keys = {}
    for _, id in pairs({ collect = s.collectId or false, horde = s.hordeId or false }) do
        local q = id and Store.data().quests[id]
        for key in pairs(q and q.helpers or {}) do keys[key] = true end
    end
    local count = 0
    for _, fid in ipairs({ "casey", "pike" }) do
        if not Factions.isGone(fid) then
            for key in pairs(keys) do
                local ps = Store.data().players[key]
                if ps and not ps.dead then
                    Trust.addPersonal(fid, key, Council.HELPER_TRUST, "council_help")
                    count = count + 1
                end
            end
        end
    end
    if count > 0 then log("council helpers", count) end
    return count
end

function Council.finish(now)
    local s = state()
    local hq = Store.data().quests[s.hordeId or ""]
    s.cleared = hq ~= nil and hq.state == "completed"
    local score = 0
    if (s.prep or 0) >= Council.PREP_SHARE then score = score + 1 end
    if s.cleared then score = score + 1 end
    if Council.avgTrust() >= Council.TRUST_AVG then score = score + 1 end
    s.result = score >= 2 and "formed" or "failed"
    s.stage, s.doneT = "done", now.t
    local Life, Bonds = StoryEngine.Life, StoryEngine.Bonds
    for _, f in ipairs(Factions.list) do
        if not Factions.isGone(f.id) and Life then
            pcall(Life.change, f.id, "morale", s.result == "formed" and 15 or -10, "council")
        end
    end
    if Bonds then
        if s.result == "formed" then
            for _, f in ipairs(Factions.list) do
                for _, host in ipairs({ "casey", "pike" }) do
                    if f.id ~= host and not Factions.isGone(f.id) then
                        pcall(Bonds.change, f.id, host, 1, "the county council " .. tostring(Stories.NAMES[host] or host)
                            .. " helped call came together", false)
                    end
                end
            end
        else
            pcall(Bonds.change, "guard", "rats", -1, "the county council broke up in a shouting match", true)
        end
    end
    if s.result == "formed" then Council.rewardHelpers() end
    local suffix = s.result == "formed" and "9a" or "9b"
    for fid, prefix in pairs(Council.HOSTS) do
        if not Factions.isGone(fid) and original(fid) then
            local node = Stories.node(fid, Social().story(fid).node)
            if node and node.chapter == 5 and not node.final then Social().moveTo(fid, prefix .. suffix, now) end
        end
    end
    -- 회의 장면 (공용 주파수): 참석자들이 차례로 말한다
    local agenda = Council.agenda()
    local topic = (s.result == "formed"
        and "The first county council just met at the March Ridge church, broadcast on the radio, and it worked: they agreed to meet every month."
        or "The first county council at the March Ridge church broke up in arguments.")
        .. (#agenda > 0 and (" On the agenda: " .. table.concat(agenda, " | ")) or "")
    local ids = {}
    for _, f in ipairs(Factions.list) do
        if not Factions.isGone(f.id) and #ids < 3 then ids[#ids + 1] = f.id end
    end
    if Social().queueTopic then Social().queueTopic(ids, topic, "holiday", nil) end
    if Social().news then Social().news("all", topic) end
    if StoryEngine.Chronicle then
        for _, fid in ipairs({ "casey", "pike" }) do
            if not Factions.isGone(fid) then StoryEngine.Chronicle.add(fid, { k = "council", result = s.result }) end
        end
    end
    for _, ps in pairs(Store.data().players) do
        -- 일지: 브릿지가 문장을 그대로 쓰는 op 메모 (format_note)
        if not ps.dead then Store.addNote(ps, { kind = "op", text = topic, clock = now.clock }) end
    end
    pcall(Net.toAll, "councilNotice", { stage = "done", result = s.result })
    log("council done", s.result, "prep", s.prep, "cleared", tostring(s.cleared), "trust", Council.avgTrust())
end

-- 회의가 끝난 뒤 늦게 5장 대기 장면에 온 쪽은 결과로 바로
local function catchUp(now)
    local s = state()
    if s.stage ~= "done" then return end
    local suffix = s.result == "formed" and "9a" or "9b"
    for fid, prefix in pairs(Council.HOSTS) do
        if not Factions.isGone(fid) and original(fid) and Social().story(fid).node == prefix .. "1" then
            Social().moveTo(fid, prefix .. suffix, now)
        end
    end
end

function Council.tick(now)
    now = now or Sensor.now()
    if not StoryEngine.option("Social", true) then return end
    local s = state()
    noteFirstFinal(now)
    if not s.stage then
        if Council.shouldStart(now) and #Sensor.players() > 0 then Council.start(now) end
        return
    end
    if s.stage == "collect" then
        local q = Store.data().quests[s.collectId or ""]
        if not q or not Quests.isActive(q) or now.t >= (q.deadlineT or 0) then Council.startHorde(now) end
    elseif s.stage == "horde" then
        local q = Store.data().quests[s.hordeId or ""]
        if not q or not Quests.isActive(q) or now.t >= (q.deadlineT or 0) then Council.finish(now) end
    end
    catchUp(now)
end

function Council.statusText()
    local s = state()
    local done, living = Council.readyCount()
    return "council " .. tostring(s.stage or "waiting") .. " ready " .. StoryEngine.intToString(done) .. "/"
        .. StoryEngine.intToString(living) .. (s.result and (" " .. s.result) or "")
end

Events.EveryHours.Add(function()
    local ok, err = pcall(Council.tick)
    if not ok then log("council tick error:", err) end
end)

return Council
