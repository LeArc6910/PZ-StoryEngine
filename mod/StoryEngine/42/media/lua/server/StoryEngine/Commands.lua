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
    local ok, why = StoryEngine.Radio.say(player, tostring(args.faction or ""), args.text)
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
function Commands.questChoose(player, args)
    local ok, why = StoryEngine.Quests.choose(player, tostring(args.id or ""), args.index)
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
        Social.advance(fid, now)
    end
    reply(player, "debugStatus", { text = Social.debugStatus() })
end

-- 거래 대가 제출: args.items = 아이템 ID 목록
function Commands.tradePay(player, args)
    local ids = {}
    for _, v in pairs(args.items or {}) do ids[#ids + 1] = v end
    local ok, why = StoryEngine.Trade.pay(player, tostring(args.id or ""), ids)
    reply(player, "tradePayResult", { ok = ok, error = not ok and why or nil })
end

function Commands.questSubmit(player, args)
    local ok, why = StoryEngine.Quests.submit(player, tostring(args.id or ""))
    reply(player, "questSubmitResult", { ok = ok, error = not ok and why or nil })
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
        .. " | " .. StoryEngine.Social.debugStatus() })
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
