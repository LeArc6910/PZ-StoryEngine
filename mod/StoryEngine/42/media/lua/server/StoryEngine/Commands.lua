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

function Commands.journalList(player, args)
    local ps = StoryEngine.Store.player(player)
    reply(player, "journalList", { entries = StoryEngine.Journal.list(ps) })
end

function Commands.radioChannels(player, args)
    reply(player, "radioChannels", {
        channels = StoryEngine.Radio.channelList(),
        hasRadio = StoryEngine.Factions.canTalk(player),
    })
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
    reply(player, "debugStatus", { text = StoryEngine.Sensor.statusText(player) })
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
