-- 공동 결말 「카운티 회의」 (2026-10-07, docs/STORY_YEAR_PLAN.md F): 케이시 5장과 파이크 5장을 하나로 묶은 1년 이야기의
-- 마지막 큰 장면. 케이시(또는 후임 노라)의 방송으로, 파이크(또는 후임 에스더)의 교회에서 첫 카운티 회의를 연다.
--
-- 열리는 때(하루 한 번 확인): 케이시·파이크 채널 중 하나라도 준비됐고(처음 사람이 5장 대기 장면 casey5_1/pike5_1 에
-- 있거나, 후임이 자기 이야기를 마쳤음), 살아 있는 채널 중 Council.READY_MIN 명 이상이 4장(또는 후임 이야기)을 마쳤을 때,
-- 또는 다른 사람의 5장 결말이 처음 나온 지 Council.LATE_DAYS 일 x 이야기 속도가 지났을 때.
-- 단계: 준비 모금(collect, 4일) -> 회의 날 교회 사수(defend, 5일 안에) -> 회의(공용 주파수 장면) -> 결말.
-- 교회 사수 (2026-10-10 사용자 결정: 1년의 마지막답게 아주 어렵게, 대신 관계가 좋은 모든 NPC 가 적극 돕는다):
--   교회 둘레 SIEGE_RADIUS 타일에 누군가 SIEGE_MIN(6시간) 머무는 동안 회의가 진행되고, 그동안 SIEGE_WAVE(30분)마다
--   추적 무리가 12번 온다. 모두 합쳐 샌드박스 CouncilSiege(1000) x ZombieMult 마리 (한 무리는 최대 300).
--   신뢰도 SIEGE_HELP_TRUST(60) 이상인 NPC 가 돕는다: 길목에서 무리를 막아 줄이고(SIEGE_THIN, 80 이상이면 x1.25),
--   처음 도착하면 방위대 분대·파이크의 위로·레이의 스튜·케이시 정찰, 무리마다 한 사람씩 저격·미끼·분대(SIEGE_ROTA),
--   다치면 닥(Specialty.assist: 대기·비용 없음). 버텨 내면 5등급 보상 보급.
-- 결말: 모금을 70% 이상 채움 / 교회를 지켜 냄 / 살아 있는 NPC 평균 신뢰도 50 이상 중 둘 이상이면 "카운티 의회"
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
Council.HORDE_DAYS = 3                -- (예전 소탕 기한, 더 쓰지 않는다)
Council.SIEGE_DAYS = 5
Council.SIEGE_MIN = 360               -- 교회 둘레에 머문 시간 (게임 분)
Council.SIEGE_WAVE = 30               -- 무리 간격 (게임 분)
Council.SIEGE_RADIUS = 30
Council.SIEGE_HELP_TRUST = 60         -- 이 신뢰도 이상인 NPC 가 돕는다
Council.SIEGE_CLOSE_TRUST = 80        -- 이 이상이면 막아 주는 몫 x SIEGE_CLOSE
Council.SIEGE_CLOSE = 1.25
Council.SIEGE_THIN = { guard = 0.20, rats = 0.10, hunter = 0.10, dewey = 0.10, casey = 0.05 }
Council.SIEGE_THIN_MAX = 0.7
Council.SIEGE_ROTA = { "hunter", "rats", "guard", "hunter", "pike", "rats" }   -- 무리마다 현장에 오는 지원
Council.SIEGE_HEAL_GAP = 60
Council.SIEGE_HURT = 50
Council.SIEGE_STEW = "StoryEngine.Food_RayStew"
Council.SIEGE_REWARD_TIER = 5
Council.SIEGE_CONTEXT = "You are doing this to help hold the March Ridge church while the first county council meets "
    .. "inside; the dead are coming at it by the hundreds."
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

-- ---------------------------------------------------------------- 교회 사수

-- 몰려오는 망자의 총수 (샌드박스 CouncilSiege x ZombieMult, 무리 하나의 상한 300 과는 따로)
function Council.siegeTotal()
    local Tuning = StoryEngine.Tuning
    local n = Tuning and Tuning.num("CouncilSiege") or 1000
    local m = Tuning and tonumber(Tuning.get("ZombieMult")) or 1
    return math.max(50, math.floor(n * m + 0.5))
end

local function helps(fid)
    return not Factions.isGone(fid) and (Radio.channel(fid).trust or 0) >= Council.SIEGE_HELP_TRUST
end

-- 도우러 오는 NPC (신뢰도 SIEGE_HELP_TRUST 이상, 살아 있는)
function Council.helpers()
    local out = {}
    for _, f in ipairs(Factions.list) do
        if helps(f.id) then out[#out + 1] = f.id end
    end
    return out
end

-- 길목에서 막아 주는 몫 (0 ~ SIEGE_THIN_MAX)
function Council.thinning()
    local share = 0
    for fid, part in pairs(Council.SIEGE_THIN) do
        if helps(fid) then
            local close = (Radio.channel(fid).trust or 0) >= Council.SIEGE_CLOSE_TRUST
            share = share + part * (close and Council.SIEGE_CLOSE or 1)
        end
    end
    return math.min(Council.SIEGE_THIN_MAX, share)
end

function Council.startHorde(now)
    local s = state()
    local q = Store.data().quests[s.collectId or ""]
    s.prep = collectShare(q)
    s.stage = "horde"
    moveHosts("3", now)
    local pike = Factions.byId.pike
    local ps = anyPlayer()
    local total = Council.siegeTotal()
    local waves = math.max(1, math.ceil(Council.SIEGE_MIN / Council.SIEGE_WAVE))
    local hq = Quests.createSite("defend", ps, { x = pike.x, y = pike.y, name = "March Ridge church" }, now,
        { council = true, source = "council", faction = "pike" },
        { tier = 5, needMin = Council.SIEGE_MIN, radius = Council.SIEGE_RADIUS,
          deadlineT = now.t + math.floor(Council.SIEGE_DAYS * 24 * 60) })
    s.hordeId = hq and hq.id or nil
    if hq then hq.siege = { total = total, waves = waves, wave = math.ceil(total / waves), sent = 0, held = 0 } end
    local names = {}
    for _, fid in ipairs(Council.helpers()) do names[#names + 1] = tostring(Stories.NAMES[fid] or fid) end
    local host = hostOf()
    if host then
        Radio.react(host, "event", "The dead are converging on the March Ridge church for the county council: about "
            .. StoryEngine.intToString(total) .. " of them, coming in pack after pack. Ask the players to hold the church "
            .. "(stay close to it) for about six hours until the council is over. "
            .. (#names > 0 and ("Everyone on the radio who trusts them is coming to help: " .. table.concat(names, ", ") .. ".")
                or "Nobody on the radio trusts them enough to come; they will be alone."),
            { text = "The dead are coming at the church by the hundreds. Hold it until the council is over.",
              lt = original(host) and StoryEngine.Lines.story(Council.HOSTS[host] .. "3") or { key = "IGUI_StoryEngine_Council_HordeCall" } }, nil)
    end
    pcall(Net.toAll, "councilNotice", { stage = "horde" })
    log("council siege", s.hordeId, "prep", s.prep, "total", total, "waves", waves, "helpers", table.concat(Council.helpers(), ","))
end

local DIR_CODES = { "E", "SE", "S", "SW", "W", "NW", "N", "NE" }
local function dirCode(angle)
    local deg = angle * 180 / math.pi
    return DIR_CODES[math.floor(((deg + 360 + 22.5) % 360) / 45) + 1]
end

local function siegeNote(players, key, english, args)
    local host = hostOf() or "pike"
    for _, p in ipairs(players) do
        Radio.overhead(Store.player(p).key, host, english, { key = "IGUI_StoryEngine_Council_Siege_" .. key, args = args or {} })
    end
end

local function assist(fid, player)
    local Spec = StoryEngine.Specialty
    if not Spec or not helps(fid) then return false end
    local ok, done = pcall(Spec.assist, fid, player, { context = Council.SIEGE_CONTEXT })
    return ok and done == true
end

-- 게임 10분마다 (Sensor tick): 교회를 지키는 동안 무리와 지원
function Council.siegeTick(entries, now)
    local s = state()
    if s.stage ~= "horde" then return end
    local q = Store.data().quests[s.hordeId or ""]
    local sg = q and q.siege
    if not sg or not Quests.isActive(q) then return end
    local present = {}
    for _, p in ipairs(Sensor.players()) do
        if not p:isDead() then
            local dx, dy = p:getX() - q.cx, p:getY() - q.cy
            if math.sqrt(dx * dx + dy * dy) <= (q.radius or Council.SIEGE_RADIUS) + 10 then present[#present + 1] = p end
        end
    end
    if #present == 0 then return end
    local lead = present[ZombRand(#present) + 1]
    -- 처음 도착했을 때: 올 수 있는 사람은 다 온다
    if not sg.opened then
        sg.opened = true
        siegeNote(present, "Open", "Everyone is coming to the church. Hold on.",
            { { t = "num", v = #Council.helpers() } })
        assist("guard", lead)
        assist("pike", lead)
        if helps("ray") and StoryEngine.Items then
            for _, p in ipairs(present) do pcall(StoryEngine.Items.addTo, p:getInventory(), Council.SIEGE_STEW) end
            Radio.react("ray", "event", "You sent a pot of your stew to everyone holding the March Ridge church for the "
                .. "county council. Tell them to eat and hold on.",
                { text = "Sent you all a pot of stew. Eat, and hold on.", lt = { key = "IGUI_StoryEngine_Council_Siege_Stew" } },
                Store.player(lead), { overhead = true })
        end
        log("council siege opened", #present, "present")
    end
    -- 케이시: 버티는 동안 정찰 표시
    if helps("casey") and StoryEngine.Specialty and StoryEngine.Specialty.opScout then
        for _, p in ipairs(present) do pcall(StoryEngine.Specialty.opScout, p, q.deadlineT or (now.t + 60)) end
    end
    -- 닥: 크게 다친 사람
    sg.healT = sg.healT or {}
    for _, p in ipairs(present) do
        local key = Store.player(p).key
        local okH, hp = pcall(function() return p:getBodyDamage():getOverallBodyHealth() end)
        if okH and type(hp) == "number" and hp < Council.SIEGE_HURT and now.t >= (sg.healT[key] or 0) then
            if assist("doc", p) then sg.healT[key] = now.t + Council.SIEGE_HEAL_GAP end
        end
    end
    -- 무리
    if now.t >= (q.nextWaveT or 0) and (q.waves or 0) < sg.waves and StoryEngine.Hunt then
        local held = math.floor(sg.wave * Council.thinning() + 0.5)
        local size = math.max(4, sg.wave - held)
        local angle = ZombRandFloat(0, math.pi * 2)
        local d = ZombRand(45, 66)
        StoryEngine.Hunt.start(lead, size, q.cx + math.cos(angle) * d, q.cy + math.sin(angle) * d, "council")
        q.waves = (q.waves or 0) + 1
        q.nextWaveT = now.t + Council.SIEGE_WAVE
        sg.sent, sg.held = sg.sent + size, sg.held + held
        siegeNote(present, "Wave", "A pack is coming.",
            { { t = "num", v = q.waves }, { t = "num", v = sg.waves }, { t = "num", v = size }, { t = "dir", v = dirCode(angle) } })
        if held > 0 then
            siegeNote(present, "Held", "Your friends on the radio stopped some of them on the roads.", { { t = "num", v = held } })
        end
        local fid = Council.SIEGE_ROTA[(q.waves - 1) % #Council.SIEGE_ROTA + 1]
        assist(fid, lead)
        log("council wave", q.waves, "/", sg.waves, "size", size, "held", held, "assist", fid)
        Quests.notify(q)
    end
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
    -- 교회를 지켜 냈으면 큰 보상 보급 (교회에 가장 가까운 사람 근처)
    if s.cleared and hq and StoryEngine.Loot then
        local best, bestD = nil, nil
        for _, p in ipairs(Sensor.players()) do
            local dx, dy = p:getX() - (hq.cx or 0), p:getY() - (hq.cy or 0)
            local dd = dx * dx + dy * dy
            if not p:isDead() and (not bestD or dd < bestD) then best, bestD = p, dd end
        end
        if best then
            local giver = hostOf() or "pike"
            local okR, errR = pcall(Quests.create, "supply_drop", best, Store.player(best), 1, now,
                { source = "reward", faction = giver, rewardFor = hq.id, rewardKind = "horde" },
                StoryEngine.Loot.roll(Council.SIEGE_REWARD_TIER, giver))
            if not okR then log("council reward error:", tostring(errR)) end
        end
    end
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
    local text = "council " .. tostring(s.stage or "waiting") .. " ready " .. StoryEngine.intToString(done) .. "/"
        .. StoryEngine.intToString(living) .. (s.result and (" " .. s.result) or "")
    local q = Store.data().quests[s.hordeId or ""]
    if q and q.siege then
        text = text .. " siege " .. StoryEngine.intToString(q.waves or 0) .. "/" .. StoryEngine.intToString(q.siege.waves)
            .. " sent " .. StoryEngine.intToString(q.siege.sent) .. " held " .. StoryEngine.intToString(q.siege.held)
            .. " of " .. StoryEngine.intToString(q.siege.total) .. " helpers " .. table.concat(Council.helpers(), ",")
    end
    return text
end

Sensor.listeners.tick[#Sensor.listeners.tick + 1] = function(entries, now)
    local ok, err = pcall(Council.siegeTick, entries, now)
    if not ok then log("council siege error:", tostring(err)) end
end

Events.EveryHours.Add(function()
    local ok, err = pcall(Council.tick)
    if not ok then log("council tick error:", err) end
end)

return Council
