-- 클라이언트 명령 처리 (서버 측 전용).

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Bridge"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Journal"
require "StoryEngine/Quests"
require "StoryEngine/Director"
require "StoryEngine/Factions"
require "StoryEngine/Radio"
require "StoryEngine/Trade"
require "StoryEngine/Monologue"
require "StoryEngine/Diag"
require "StoryEngine/Summary"
require "StoryEngine/Hunt"
require "StoryEngine/ALife"
require "StoryEngine/Banter"
require "StoryEngine/Social"
require "StoryEngine/Life"
require "StoryEngine/Specialty"
require "StoryEngine/Fate"
require "StoryEngine/Projects"
require "StoryEngine/NpcEvents"
require "StoryEngine/Bonds"
require "StoryEngine/Broadcast"
require "StoryEngine/World"
require "StoryEngine/Letters"
require "StoryEngine/Legacy"
require "StoryEngine/Voices"
require "StoryEngine/Council"
require "StoryEngine/AiTales"
require "StoryEngine/Tuning"
require "StoryEngine/Grid"
require "StoryEngine/Ops"
require "StoryEngine/Saga"
require "StoryEngine/Work"
require "StoryEngine/Chronicle"
require "StoryEngine/Named"
require "StoryEngine/Holiday"
StoryEngine.Tuning.safeApply()

local Net = StoryEngine.Net
local Bridge = StoryEngine.Bridge
local log = StoryEngine.log

local Commands = {}
StoryEngine.Commands = Commands

local PING_COOLDOWN_MS = 3000
local lastPing = {}   -- username -> ms

local function reply(player, command, args)
    local ok, err = pcall(Net.toClient, player, command, args)
    if not ok then log("reply failed:", command, err) end
end

-- 멀티에서는 디버그 권한(관리자 등)이 있는 플레이어만 테스트 호출을 할 수 있다 (API 비용 보호).
-- 인게임 호스트도 접속할 때는 role="user" 다 (42.20.4 확인). 거절하면 이유를 알려 준다.
local function canUseDebug(player)
    if not isServer() then return true end
    local ok, allowed = pcall(function()
        return player:getRole():hasCapability(Capability.UseDebugContextMenu)
    end)
    if ok and allowed == true then return true end
    log("debug denied", player:getUsername())
    reply(player, "debugDenied", {})
    return false
end

function Commands.ping(player, args)
    if not canUseDebug(player) then return end

    local name = player:getUsername() or "?"
    local now = StoryEngine.nowMs()
    if lastPing[name] and now - lastPing[name] < PING_COOLDOWN_MS then
        reply(player, "pingResult", { ok = false, error = "cooldown" })
        return
    end
    lastPing[name] = now

    local text = string.sub(tostring(args.text or ""), 1, 200)
    log("ping from", name, text)
    Bridge.request("debug", { text = text }, function(res)
        reply(player, "pingResult", {
            ok = res.ok == true,
            text = res.text,
            error = res.error,
            model = res.model,
            ms = StoryEngine.nowMs() - now,
        })
    end)
end

-- 접속(또는 싱글 시작) 시: 클라이언트 언어를 기억하고 연결 상태를 알려 준다.
-- 클라이언트가 알려 준 언어 코드를 기억한다 (hello, 무전 발언마다)
local function rememberLang(player, lang)
    if type(lang) == "string" and string.len(lang) >= 2 and string.len(lang) <= 8 and string.match(lang, "^%u+$") then
        StoryEngine.Store.player(player).lang = lang
    end
end

function Commands.hello(player, args)
    local ps = StoryEngine.Store.player(player)
    rememberLang(player, args.lang)
    reply(player, "status", { state = Bridge.state })
    StoryEngine.Grid.sendTo(player)
    -- 후임 목소리 이름표 (Voices.lua)
    pcall(StoryEngine.Voices.apply)
    pcall(StoryEngine.Voices.sendTo, player)
    -- 서버의 아이템 조정(items.txt)을 멀티 클라이언트에게 (점검 D1)
    if isServer() then
        local ok, lines = pcall(StoryEngine.ItemPool.overrideLinesForClients)
        if ok then reply(player, "itemOverrides", { lines = lines }) end
    end
end

-- 일지 목록. args.key 가 있으면 그 사람의 일지 (서버의 모든 플레이어 일지를 읽을 수 있다)
function Commands.journalList(player, args)
    local own = StoryEngine.Store.player(player)
    local ps = own
    if type(args.key) == "string" and StoryEngine.Store.data().players[args.key] then
        ps = StoryEngine.Store.data().players[args.key]
    end
    if args.memoir then
        -- 회고록과 살아 있는 사람들의 추모
        local m = StoryEngine.Journal.memoirOf(ps)
        reply(player, "journalList", {
            key = ps.key, own = own.key, memoir = true, name = ps.name,
            entries = m and { m } or {}, comments = ps.memoirComments or {},
            authors = StoryEngine.Journal.authors(own.key),
        })
        return
    end
    reply(player, "journalList", {
        key = ps.key, own = own.key, entries = StoryEngine.Journal.list(ps),
        authors = StoryEngine.Journal.authors(own.key),
    })
end

function Commands.radioChannels(player, args)
    reply(player, "radioChannels", {
        channels = StoryEngine.Radio.channelList(),
        hasRadio = StoryEngine.Factions.canTalk(player),
        support = StoryEngine.ALife.channelInfo(),     -- A-Life 연동이 켜져 있을 때만 (세력별 지원 가능 여부)
    })
end

-- A-Life 연동: 이 세력에 무장 지원을 요청한다
function Commands.supportRequest(player, args)
    local fid = tostring(args.faction or "")
    if not StoryEngine.Factions.canTalk(player) then
        reply(player, "supportResult", { ok = false, error = "no_radio", faction = fid })
        return
    end
    local ok, info, wait = StoryEngine.ALife.request(player, fid)
    reply(player, "supportResult", {
        ok = ok, faction = fid, error = (not ok) and tostring(info) or nil,
        count = ok and info.count or nil, wait = wait,
    })
    reply(player, "radioChannels", {
        channels = StoryEngine.Radio.channelList(), hasRadio = StoryEngine.Factions.canTalk(player),
        support = StoryEngine.ALife.channelInfo(),
    })
end

-- 거점 탭: NPC 생활 상태·행적·평판 (Life.lua)
function Commands.lifeList(player, args)
    reply(player, "lifeList", { npcs = StoryEngine.Life.list(StoryEngine.Store.playerKey(player)) })
end

-- 물자 지원: args = { faction, items = 아이템 ID 목록 }
function Commands.lifeDonate(player, args)
    local ids = {}
    for _, v in pairs(args.items or {}) do ids[#ids + 1] = v end
    local fid = tostring(args.faction or "")
    local ok, info, wait = StoryEngine.Life.donate(player, fid, ids, args.mode == "project" and "project" or nil)
    reply(player, "lifeDonateResult", {
        ok = ok, faction = fid, error = (not ok) and tostring(info) or nil, wait = wait,
        gains = ok and info.gains or nil, trust = ok and info.trust or nil, points = ok and info.points or nil,
    })
    reply(player, "lifeList", { npcs = StoryEngine.Life.list(StoryEngine.Store.playerKey(player)) })
end

-- 특기 지원: args = { faction, target (레이 보급 대상) }
function Commands.specialtyRequest(player, args)
    local fid = tostring(args.faction or "")
    local ok, info, wait = StoryEngine.Specialty.request(player, fid, { target = args.target })
    reply(player, "specialtyResult", {
        ok = ok, faction = fid, error = (not ok) and tostring(info) or nil, wait = wait,
        pending = ok and info.pending or nil,
    })
    reply(player, "lifeList", { npcs = StoryEngine.Life.list(StoryEngine.Store.playerKey(player)) })
end

-- 닥 치료: 클라이언트가 10초 동안 가만히 있었다
function Commands.specHealDone(player, args)
    local ok, info = StoryEngine.Specialty.healDone(player)
    reply(player, "specialtyResult", { ok = ok, faction = "doc", healed = ok and info or nil,
                                       error = (not ok) and tostring(info) or nil })
    reply(player, "lifeList", { npcs = StoryEngine.Life.list(StoryEngine.Store.playerKey(player)) })
end

-- 라디오 방송을 들었다 (BroadcastClient: 그 주파수에 맞춰 켠 라디오가 있다)
function Commands.broadcastHeard(player, args)
    StoryEngine.Broadcast.heard(player, tostring(args.id or ""))
end

-- 디버그: 오늘 저녁 방송을 지금 만든다 (이미 했어도). args.rerun 이면 마지막 방송을 다시 내보낸다
function Commands.debugBroadcast(player, args)
    if not canUseDebug(player) then return end
    local B = StoryEngine.Broadcast
    local ok, why
    if args.rerun then
        local last = StoryEngine.Store.data().broadcast and StoryEngine.Store.data().broadcast.last
        ok = last and B.air(last, true) or false
        why = last and "air failed" or "no broadcast yet"
    else
        ok, why = B.build(StoryEngine.Sensor.now(), true)
    end
    reply(player, "debugStatus", { text = (ok and "broadcast requested | " or ("broadcast: " .. tostring(why) .. " | "))
        .. B.statusText() })
end

-- 편지 읽기: args = { id = modData.storyLetter, qid = modData.storyQuest }
function Commands.letterRead(player, args)
    local info, why = StoryEngine.Letters.read(player, args.id, args.qid)
    reply(player, "letterText", info or { error = tostring(why) })
end

-- 디버그: 그 NPC 의 편지가 든 선물 보급을 바로 만든다
function Commands.debugLetter(player, args)
    if not canUseDebug(player) then return end
    local fid = tostring(args.faction or "")
    if not StoryEngine.Factions.byId[fid] then return end
    StoryEngine.Letters.queue(fid, tostring(args.reason or "gift"), args.reason == "project" and "a test project" or nil)
    local ps = StoryEngine.Store.player(player)
    local q, why = StoryEngine.Quests.create("supply_drop", player, ps, 1, StoryEngine.Sensor.now(),
        { source = "director", faction = fid, initiator = "gift", friend = true })
    reply(player, "debugStatus", { text = "letter " .. fid .. ": " .. (q and ("in " .. q.id) or tostring(why))
        .. " | " .. StoryEngine.Letters.statusText() })
end

-- 디버그: 아는 얼굴의 좀비 부탁 (신뢰도·간격 무시, 남은 사람 중 교신 탭 상대 먼저)
function Commands.debugNamed(player, args)
    if not canUseDebug(player) then return end
    local Named = StoryEngine.Named
    local fid = tostring(args.faction or "")
    local pick = nil
    for _, p in ipairs(Named.PEOPLE) do
        if not pick and p.npc == fid and not p.requires and not p.storyOnly then pick = p end
    end
    pick = pick or Named.PEOPLE[1]
    local q, why = Named.propose(player, StoryEngine.Store.player(player), pick, StoryEngine.Sensor.now())
    reply(player, "debugStatus", { text = "named " .. pick.id .. ": " .. (q and q.id or tostring(why)) .. " | "
        .. Named.statusText() })
end

-- 디버그: 명절 예고·잔치 바로 (args.id, args.stage = announce|feast). 지금 언어의 명절 목록에서 찾는다
function Commands.debugHoliday(player, args)
    if not canUseDebug(player) then return end
    local H = StoryEngine.Holiday
    local set, setName = H.set()
    local h = nil
    for _, x in ipairs(set) do if x.id == args.id then h = x end end
    if not h then
        reply(player, "debugStatus", { text = "holiday " .. tostring(args.id) .. " is not in the " .. setName .. " list" })
        return
    end
    local y = H.today()
    local u = { h = h, key = setName .. "_" .. h.id .. "_debug" .. StoryEngine.intToString(ZombRand(100000)), days = 0,
                date = { y, 1, 1 }, set = setName }
    local now = StoryEngine.Sensor.now()
    H.announce(u, now)
    if args.stage == "feast" then H.celebrate(u, now) end
    reply(player, "debugStatus", { text = H.statusText() })
end

-- 디버그: 세계 변화 사건을 바로 일으킨다 (이미 했어도). args.event = power|water|winter|snow|day30|day90|day180
function Commands.debugWorld(player, args)
    if not canUseDebug(player) then return end
    local W = StoryEngine.World
    local id = tostring(args.event or "")
    if not W.EVENTS[id] then return end
    local key = id .. "_debug_" .. StoryEngine.intToString(StoryEngine.Sensor.now().t)
    if id == "power" or id == "water" then
        -- 실제로도 끊는다 (2026-10-01). 아직 그 사건이 없었으면 진짜 키로 기록해 한 시간 뒤 자동 사건이 겹치지 않게
        StoryEngine.Grid.cut(id, "debug")
        if not W.isDone(id) then key = id end
    end
    local ok = W.fire(id, key)
    reply(player, "debugStatus", { text = "world " .. id .. (ok and " fired" or " failed") .. " | " .. W.statusText()
        .. " | " .. StoryEngine.Grid.statusText() })
end

-- 디버그: 전기·수도 복구 시험. args.kind = power | water | reset
function Commands.debugGrid(player, args)
    if not canUseDebug(player) then return end
    local G = StoryEngine.Grid
    local kind = tostring(args.kind or "")
    if kind == "reset" then
        G.reset(nil, "debug")
    elseif kind == "power" or kind == "water" then
        G.restore(kind, G.RESTORE_DAYS, "debug")
    else
        return
    end
    reply(player, "debugStatus", { text = G.statusText() .. " | " .. StoryEngine.World.statusText() })
end

-- 디버그: 복구 작전. args.action = start | next | fail | stop, args.kind = water | power
function Commands.debugOp(player, args)
    if not canUseDebug(player) then return end
    local ok, why = StoryEngine.Ops.debug(tostring(args.action or ""), tostring(args.kind or ""))
    reply(player, "debugStatus", { text = (ok and "" or ("op: " .. tostring(why) .. " | ")) .. StoryEngine.Ops.statusText()
        .. " | " .. StoryEngine.Grid.statusText() })
end

-- 디버그: 큰 사건. args.action = start | next | stop, args.kind = crash | migration | epidemic | blackout
function Commands.debugSaga(player, args)
    if not canUseDebug(player) then return end
    local ok, why = StoryEngine.Saga.debug(tostring(args.action or ""), tostring(args.kind or ""))
    reply(player, "debugStatus", { text = (ok and "" or ("saga: " .. tostring(why) .. " | ")) .. StoryEngine.Saga.statusText() })
end

-- 저격이 끝났다 (쓰러뜨린 수)
function Commands.specSnipeDone(player, args)
    StoryEngine.Specialty.snipeDone(player, tostring(args.faction or ""), args.kills)
end

-- 디버그: NPC 생활 자원 조절. args = { faction, delta } 또는 { faction, set = 숫자 | "base" }
function Commands.debugLife(player, args)
    if not canUseDebug(player) then return end
    local fid = tostring(args.faction or "")
    if not StoryEngine.Factions.byId[fid] then return end
    StoryEngine.Life.debugAdjust(fid, math.floor(tonumber(args.delta) or 0), args.set)
    if args.clearWait then StoryEngine.Life.npc(fid).donatedT = nil end
    if args.clearSpec then StoryEngine.Specialty.clearWait(fid) end
    if args.project then StoryEngine.Projects.debugAdd(fid, math.floor(tonumber(args.project) or 0)) end
    -- NPC 사이 사건 시험 (간격·확률 무시): share | clash | raid
    local NE = StoryEngine.NpcEvents
    local now = StoryEngine.Sensor.now()
    if args.npcEvent == "share" then
        StoryEngine.Store.data().npcEvents = StoryEngine.Store.data().npcEvents or {}
        StoryEngine.Store.data().npcEvents.lastShareT = nil
        reply(player, "debugStatus", { text = "share: " .. tostring(NE.share(now)) })
    elseif args.npcEvent == "clash" then
        local d = StoryEngine.Store.data()
        d.npcEvents = d.npcEvents or {}
        d.npcEvents.lastClashT = nil
        local chance = NE.CLASH_CHANCE
        NE.CLASH_CHANCE = 100
        local ok = NE.clash(now)
        NE.CLASH_CHANCE = chance
        reply(player, "debugStatus", { text = "clash: " .. tostring(ok) })
    elseif args.npcEvent == "raid" then
        local ok, why = StoryEngine.Social.startCrisis(now, "raid")
        reply(player, "debugStatus", { text = "raid: " .. tostring(ok and "started" or why) })
    elseif args.npcEvent == "emergency" then
        local d = StoryEngine.Store.data()
        d.npcEvents = d.npcEvents or {}
        d.npcEvents.lastEmergencyT = nil
        local ok, why = StoryEngine.Director.run("debug", "npc_emergency", StoryEngine.Store.player(player).name)
        reply(player, "debugStatus", { text = "emergency: " .. tostring(ok and (NE.emergency() or "sent") or why) })
    end
    -- 죽음·떠남 시험: fate = "dead" | "gone" | "revive" | "doom"(하루 뒤 이야기 결말처럼)
    if args.fate == "revive" then
        StoryEngine.Fate.revive(fid)
    elseif args.fate == "doom" then
        local st = StoryEngine.Social.story(fid)
        st.wins, st.losses = 0, StoryEngine.Fate.STORY_LOSSES
        StoryEngine.Fate.onStoryFinal(fid, { final = true })
        local p = (StoryEngine.Store.data().fatePending or {})[fid]
        if p then p.dueT = StoryEngine.Sensor.now().t end      -- 시험용: 하루 기다리지 않고 다음 10분에
    elseif args.fate == "dead" or args.fate == "gone" then
        StoryEngine.Fate.apply(fid, args.fate, "debug")
    end
    reply(player, "debugStatus", { text = StoryEngine.Life.statusText() .. " | " .. StoryEngine.Tuning.statusText() })
    reply(player, "lifeList", { npcs = StoryEngine.Life.list(StoryEngine.Store.playerKey(player)) })
end

-- 디버그: 세력 신뢰도 조절. args = { faction, delta } 또는 { faction, set }
function Commands.debugTrust(player, args)
    if not canUseDebug(player) then return end
    local fid = tostring(args.faction or "")
    if not StoryEngine.Factions.byId[fid] then
        reply(player, "debugStatus", { text = "trust: unknown faction " .. fid })
        return
    end
    local ch = StoryEngine.Radio.channel(fid)
    local delta = math.floor(tonumber(args.delta) or 0)
    if args.set ~= nil then delta = math.floor(tonumber(args.set) or ch.trust) - ch.trust end
    StoryEngine.Trust.apply(fid, delta, "debug", nil, StoryEngine.Store.playerKey(player))
    reply(player, "debugStatus", { text = "trust " .. fid .. " = " .. StoryEngine.intToString(ch.trust) })
    reply(player, "radioChannels", {
        channels = StoryEngine.Radio.channelList(), hasRadio = StoryEngine.Factions.canTalk(player),
        support = StoryEngine.ALife.channelInfo(),
    })
end

-- 디버그: 곁의 동료와 바로 잡담 (간격 무시)
function Commands.debugBanter(player, args)
    if not canUseDebug(player) then return end
    local ok, why = StoryEngine.Banter.debug(player)
    reply(player, "debugStatus", { text = ok and "banter requested" or ("banter: " .. tostring(why or "busy")) })
end

function Commands.debugALifeSupport(player, args)
    if not canUseDebug(player) then return end
    local fid = tostring(args.faction or "guard")
    local ok, info = StoryEngine.ALife.sendSupport(player, fid, "debug", nil, 3)
    reply(player, "debugStatus", { text = "alife support " .. fid .. ": " .. (ok and ("x" .. tostring(info.count)
        .. " " .. tostring(info.factionId)) or tostring(info)) })
end

function Commands.debugALifeAttack(player, args)
    if not canUseDebug(player) then return end
    local ok, info = StoryEngine.ALife.sendAttack(player, "rats")
    reply(player, "debugStatus", { text = "alife attack rats: " .. (ok and ("x" .. tostring(info.count) .. " "
        .. tostring(info.factionId)) or tostring(info)) })
end

function Commands.radioHistory(player, args)
    local fid = tostring(args.faction or "")
    reply(player, "radioHistory", { faction = fid, messages = StoryEngine.Radio.history(fid) })
end

function Commands.radioSay(player, args)
    rememberLang(player, args.lang)
    local intent = type(args.intent) == "string" and string.sub(args.intent, 1, 16) or nil
    local ok, why = StoryEngine.Radio.say(player, tostring(args.faction or ""), args.text, intent)
    if not ok then reply(player, "radioError", { faction = args.faction, error = why }) end
end

-- 버튼 거래 (Trade.ask): 메뉴에 보일 품목·등급, 그리고 요청
function Commands.tradeOptions(player, args)
    local fid = tostring(args.faction or "")
    if not StoryEngine.Trade.FACTIONS[fid] then return end
    reply(player, "tradeOptions", StoryEngine.Trade.options(fid, StoryEngine.Store.player(player)))
end

-- 인물 탭 (Chronicle.lua): NPC 프로필 변형과 지나온 일
function Commands.npcProfiles(player, args)
    reply(player, "npcProfiles", { npcs = StoryEngine.Chronicle.payload() })
end

-- 일거리 청하기 (Work.volunteer): 보수 없이 일해 주고 신뢰도를 얻는다
function Commands.volunteerAsk(player, args)
    local ok, why = StoryEngine.Work.volunteer(player, tostring(args.faction or ""))
    reply(player, "volunteerResult", { ok = ok, how = ok and why or nil, error = not ok and why or nil,
                                       faction = args.faction })
end

-- 보상 사양 (Quests.waiveReward)
function Commands.rewardWaive(player, args)
    local ok, why = StoryEngine.Quests.waiveReward(player, tostring(args.id or ""))
    reply(player, "rewardWaiveResult", { ok = ok, gain = ok and why or nil, error = not ok and why or nil })
end

-- 거래 대가를 물건 대신 일·외상·빚으로 (Work.lua)
function Commands.tradeWork(player, args)
    local ok, why = StoryEngine.Work.choose(player, tostring(args.id or ""), tostring(args.how or ""))
    reply(player, "tradeWorkResult", { ok = ok, how = ok and why or args.how, error = not ok and why or nil })
end

function Commands.tradeAsk(player, args)
    local ok, why = StoryEngine.Trade.ask(player, tostring(args.faction or ""), args.category, args.tier, args.bundle)
    if not ok then reply(player, "radioError", { faction = args.faction, error = why }) end
end

function Commands.questList(player, args)
    local ps = StoryEngine.Store.player(player)
    reply(player, "questList", { quests = StoryEngine.Quests.listFor(ps.key, StoryEngine.Sensor.now()) })
end

-- 일지용 행동 보고 (클라이언트 Activity.lua, 게임 내 1분마다 모아서)
function Commands.activity(player, args)
    StoryEngine.Sensor.recordActivity(player, args.list)
end

-- 멀티에서 서버 OnPlayerDeath 가 오지 않을 때를 대비한 클라이언트 보고
function Commands.died(player, args)
    StoryEngine.Journal.memoir(player, StoryEngine.Store.player(player))
end

function Commands.debugJournal(player, args)
    if not canUseDebug(player) then return end
    local ok, why = StoryEngine.Journal.write(player, StoryEngine.Store.player(player), "debug")
    reply(player, "debugStatus", { text = ok and "journal requested" or ("journal skipped: " .. tostring(why)) })
end

function Commands.debugDirector(player, args)
    if not canUseDebug(player) then return end
    local ok, why = StoryEngine.Director.run("debug")
    reply(player, "debugStatus", { text = ok and "director requested" or ("director skipped: " .. tostring(why)) })
end

function Commands.debugSupply(player, args)
    if not canUseDebug(player) then return end
    StoryEngine.Sensor.tick()
    local ok, why = StoryEngine.Director.run("debug", "supply_drop", StoryEngine.Store.characterName(player))
    reply(player, "debugStatus", { text = ok and StoryEngine.Director.statusText() or ("supply skipped: " .. tostring(why)) })
end

function Commands.debugFetch(player, args)
    if not canUseDebug(player) then return end
    StoryEngine.Sensor.tick()
    local ok, why = StoryEngine.Director.run("debug", "fetch_item", StoryEngine.Store.characterName(player))
    reply(player, "debugStatus", { text = ok and StoryEngine.Director.statusText() or ("fetch skipped: " .. tostring(why)) })
end

function Commands.debugRequest(player, args)
    if not canUseDebug(player) then return end
    StoryEngine.Sensor.tick()
    local ok, why = StoryEngine.Director.run("debug", "npc_request", StoryEngine.Store.characterName(player), "deliver")
    reply(player, "debugStatus", { text = ok and StoryEngine.Director.statusText() or ("request skipped: " .. tostring(why)) })
end

-- 새 디렉터 이벤트를 차례로 강제한다: 호드 유도 -> 헬기 -> 구조 신호
local EVENT_CYCLE = { "horde_nearby", "helicopter", "rescue_signal", "friend_gift", "extortion" }
local eventIndex = 0
function Commands.debugEvent(player, args)
    if not canUseDebug(player) then return end
    eventIndex = eventIndex % #EVENT_CYCLE + 1
    local ev = EVENT_CYCLE[eventIndex]
    StoryEngine.Sensor.tick()
    local ok, why = StoryEngine.Director.run("debug", ev, StoryEngine.Store.characterName(player))
    reply(player, "debugStatus", { text = ev .. (ok and " forced" or (" skipped: " .. tostring(why))) })
end

-- 추적 테스트: 10타일 떨어진 곳에 10마리 추적 무리를 바로 만든다
function Commands.debugHuntNear(player, args)
    if not canUseDebug(player) then return end
    local id, ok = StoryEngine.Hunt.startNear(player, 10, 10)
    reply(player, "debugStatus", { text = "hunt " .. tostring(id) .. (ok and " spawned 10 tiles away" or " failed (square not loaded)") })
end

function Commands.debugItems(player, args)
    if not canUseDebug(player) then return end
    local ok = StoryEngine.ItemPool.dump()
    local st = StoryEngine.ItemPool.stats
    reply(player, "debugStatus", { text = "item pool: food " .. tostring(st.food) .. ", firearm " .. tostring(st.firearm)
        .. ", melee " .. tostring(st.melee) .. ", excluded " .. tostring(st.excluded)
        .. (ok and " -> Zomboid/Lua/StoryEngine/itempool.txt" or " (write failed)") })
end

function Commands.debugSync(player, args)
    if not canUseDebug(player) then return end
    local lines = StoryEngine.Diag.compare(player, type(args.client) == "table" and args.client or {})
    reply(player, "debugSync", { lines = lines })
end

function Commands.debugMonologue(player, args)
    if not canUseDebug(player) then return end
    local trig = StoryEngine.Monologue.debug(player)
    log("debug monologue", trig)
end

function Commands.debugHorde(player, args)
    if not canUseDebug(player) then return end
    StoryEngine.Sensor.tick()
    local ok, why = StoryEngine.Director.run("debug", "npc_request", StoryEngine.Store.characterName(player), "horde")
    reply(player, "debugStatus", { text = ok and StoryEngine.Director.statusText() or ("horde skipped: " .. tostring(why)) })
end

function Commands.questRespond(player, args)
    local accept = args.accept == true
    local ok, why = StoryEngine.Quests.respond(player, tostring(args.id or ""), accept)
    reply(player, "questRespondResult", { ok = ok, accept = accept, error = not ok and why or nil })
end

-- 위기 선택: args = { id, index }
-- 공용 주파수 거래 제안 고르기도 같은 명령 (퀘스트 종류로 나눈다)
function Commands.questChoose(player, args)
    local Quests = StoryEngine.Quests
    local id = tostring(args.id or "")
    local q = StoryEngine.Store.data().quests[id]
    local ok, why
    if q and q.kind == "market" then
        ok, why = Quests.pickMarket(player, id, args.index)
    else
        ok, why = Quests.choose(player, id, args.index)
    end
    reply(player, "questRespondResult", { ok = ok, accept = true, error = not ok and why or nil })
end

-- 디버그: NPC 가 먼저 연락 / 공용 주파수 장면 / 위기
function Commands.debugContact(player, args)
    if not canUseDebug(player) then return end
    local ok, what = StoryEngine.Social.debugContact()
    reply(player, "debugStatus", { text = "contact: " .. tostring(what) })
end

function Commands.debugScene(player, args)
    if not canUseDebug(player) then return end
    local ok = StoryEngine.Social.scene(nil)
    reply(player, "debugStatus", { text = ok and "open channel scene requested" or "scene busy" })
end

function Commands.debugCrisis(player, args)
    if not canUseDebug(player) then return end
    local ok, what = StoryEngine.Social.startCrisis(StoryEngine.Sensor.now())
    reply(player, "debugStatus", { text = "crisis: " .. tostring(what) })
end

-- 디버그: 모든 NPC 이야기를 다음 단계로 (퀘스트 노드는 바로 부탁)
function Commands.debugStory(player, args)
    if not canUseDebug(player) then return end
    local Social, Stories = StoryEngine.Social, StoryEngine.Stories
    local now = StoryEngine.Sensor.now()
    local fid = tostring(args.faction or "")
    if StoryEngine.Factions.byId[fid] then
        local st = Social.story(fid)
        st.since = now.t - 30 * 24 * 60
        st.sequelAt = now.t          -- 결말에 있으면 다음 장을 바로
        Social.forceAsk = true       -- 이야기 부탁 몰림 방지를 건너뛴다
        local ok, err = pcall(Social.advance, fid, now)
        Social.forceAsk = nil
        if not ok then StoryEngine.log("debug story error:", err) end
    end
    reply(player, "debugStatus", { text = Social.debugStatus() })
end

-- 디버그: 고른 NPC 를 떠나보내고 후임이 바로 이어받는다 (Voices.lua)
function Commands.debugVoice(player, args)
    if not canUseDebug(player) then return end
    local fid = tostring(args.faction or "")
    if not StoryEngine.Factions.byId[fid] then return end
    local Fate, Voices = StoryEngine.Fate, StoryEngine.Voices
    if not Fate.isGone(fid) then Fate.apply(fid, "gone", "debug") end
    local ok = Voices.take(fid)
    reply(player, "debugStatus", { text = "voice " .. fid .. ": " .. tostring(ok) .. " | " .. Voices.statusText() })
end

-- 디버그: 카운티 회의를 지금 열거나 다음 단계로 (Council.lua)
function Commands.debugCouncil(player, args)
    if not canUseDebug(player) then return end
    local Council = StoryEngine.Council
    local now = StoryEngine.Sensor.now()
    local s = Council.state()
    if not s.stage or s.stage == "done" then
        if s.stage == "done" then s.stage = nil end
        Council.start(now)
    elseif s.stage == "collect" then
        Council.startHorde(now)
    elseif s.stage == "horde" then
        Council.finish(now)
    end
    reply(player, "debugStatus", { text = Council.statusText() })
end

-- 디버그: 곁가지를 지금 고른다 (하루 한 번 제한 무시)
function Commands.debugEpisode(player, args)
    if not canUseDebug(player) then return end
    local Social = StoryEngine.Social
    local soc = StoryEngine.Store.data().social
    if soc then soc.episodeDay = nil end
    local id = Social.pickEpisode(StoryEngine.Sensor.now())
    reply(player, "debugStatus", { text = "episode: " .. tostring(id or "none fits") })
end

-- 디버그: 교신 탭에서 고른 NPC 에게 AI 곁가지를 지금 청한다 (AiTales.lua). args.kind = quiet | items | horde
function Commands.debugAiTale(player, args)
    if not canUseDebug(player) then return end
    local fid = tostring(args.faction or "")
    if not StoryEngine.Factions.byId[fid] or fid == "open" then
        reply(player, "debugStatus", { text = "ai tale: pick a contact on the radio tab first" })
        return
    end
    local Social = StoryEngine.Social
    local st = Social.story(fid)
    if st.ep then Social.endEpisode(fid, StoryEngine.Sensor.now()) end
    local kind = (args.kind == "quiet" or args.kind == "items" or args.kind == "horde") and args.kind or nil
    local ok, why = StoryEngine.AiTales.request(fid, StoryEngine.Sensor.now(), kind)
    reply(player, "debugStatus", { text = "ai tale " .. fid .. ": " .. (ok and ("asked " .. tostring(why)) or tostring(why)) })
end

-- 거래 대가 제출: args.items = 아이템 ID 목록
function Commands.tradePay(player, args)
    local ids = {}
    for _, v in pairs(args.items or {}) do ids[#ids + 1] = v end
    local ok, why = StoryEngine.Trade.pay(player, tostring(args.id or ""), ids)
    reply(player, "tradePayResult", { ok = ok, error = not ok and why or nil })
end

function Commands.questSubmit(player, args)
    local ok, why = StoryEngine.Quests.submit(player, tostring(args.id or ""), type(args.items) == "table" and args.items or nil)
    reply(player, "questSubmitResult", { ok = ok, error = not ok and why or nil })
end

-- 디버그: 이 자리의 좀비 밀집도와 지역 기준 (Danger.lua, 마굴 거르기 기준 확인용)
function Commands.debugDanger(player, args)
    if not canUseDebug(player) then return end
    local text = StoryEngine.Danger.statusAt(player:getX(), player:getY())
    StoryEngine.log(text)
    reply(player, "debugStatus", { text = text })
end

function Commands.debugQuests(player, args)
    if not canUseDebug(player) then return end
    StoryEngine.Sensor.tick()
    reply(player, "debugStatus", { text = StoryEngine.Director.statusText() })
end

function Commands.debugStatus(player, args)
    if not canUseDebug(player) then return end
    StoryEngine.Sensor.tick()   -- 10분을 기다리지 않고 바로 한 번 샘플링
    reply(player, "debugStatus", { text = StoryEngine.Sensor.statusText(player) .. " | " .. StoryEngine.ALife.statusText()
        .. " | " .. StoryEngine.Social.debugStatus() .. " | " .. StoryEngine.Life.statusText()
        .. " | " .. StoryEngine.Fate.statusText() .. " | " .. StoryEngine.Projects.statusText()
        .. " | " .. StoryEngine.Bonds.statusText() .. " | " .. StoryEngine.Broadcast.statusText()
        .. " | " .. StoryEngine.World.statusText() .. " | " .. StoryEngine.Letters.statusText()
        .. " | " .. StoryEngine.Ops.statusText() .. " | " .. StoryEngine.Saga.statusText()
        .. " | " .. StoryEngine.Work.statusText() .. " | " .. StoryEngine.Named.statusText()
        .. " | " .. StoryEngine.AiTales.statusText()
        .. " | " .. StoryEngine.Holiday.statusText() })
end

local function onClientCommand(module, command, player, args)
    if module ~= StoryEngine.MODULE then return end
    local handler = Commands[command]
    if not handler then
        log("unknown command:", command)
        return
    end
    handler(player, args or {})
end

Events.OnClientCommand.Add(onClientCommand)

return Commands
