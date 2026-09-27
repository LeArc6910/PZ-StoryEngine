-- 클라이언트 측: 서버 명령 수신 -> StoryEngine.Cache 갱신 -> 통합 창 갱신, 알림, 우클릭 메뉴.

if isServer() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/MainWindow"
require "StoryEngine/QuestMap"
require "StoryEngine/UIUtil"
require "StoryEngine/Factions"

local Net = StoryEngine.Net
local log = StoryEngine.log

local Cache = StoryEngine.Cache

local Client = {
    state = "unknown",
    handlers = {},
}
StoryEngine.Client = Client

function Client.handlers.pingResult(args)
    local player = getPlayer()
    if not player then return end
    if args.ok then
        log("ping ok", tostring(args.model), tostring(args.ms) .. "ms", tostring(args.text))
        player:Say(tostring(args.text or ""))
    else
        log("ping failed", tostring(args.error))
        HaloTextHelper.addBadText(player, getText("IGUI_StoryEngine_Error", tostring(args.error)))
    end
end

function Client.handlers.status(args)
    local previous = Client.state
    Client.state = args.state or "unknown"
    if previous == Client.state then return end

    local player = getPlayer()
    if not player then return end
    if Client.state == "connected" then
        HaloTextHelper.addGoodText(player, getText("IGUI_StoryEngine_Connected"))
    elseif Client.state == "disconnected" then
        HaloTextHelper.addBadText(player, getText("IGUI_StoryEngine_Disconnected"))
    end
end

-- 서버에서 온 명령 (싱글플레이에서는 Net 이 직접 호출)
function Client.dispatch(command, args)
    local handler = Client.handlers[command]
    if handler then handler(args or {}) end
end

local function onServerCommand(module, command, args)
    if module == StoryEngine.MODULE then
        Client.dispatch(command, args)
    end
end

function Client.handlers.journalList(args)
    Cache.journal = args.entries or {}
    StoryEngineMainWindow.refreshIfOpen("journal")
end

function Client.handlers.journalNew(args)
    local player = getPlayer()
    if player then
        HaloTextHelper.addGoodText(player, getText("IGUI_StoryEngine_JournalWritten"))
        if StoryEngineMainWindow.instance then Net.toServer(player, "journalList", {}) end
    end
end

-- 디렉터 사건 알림. 보급 소식은 무전으로 들은 것처럼 보여 준다.
function Client.handlers.directorNotice(args)
    local player = getPlayer()
    if not player then return end
    if args.kind == "storm" then
        HaloTextHelper.addBadText(player, getText("IGUI_StoryEngine_Notice_Storm"))
    elseif args.kind == "helicopter" then
        HaloTextHelper.addBadText(player, getText("IGUI_StoryEngine_Notice_Helicopter"))
    elseif args.kind == "horde_sense" then
        HaloTextHelper.addBadText(player, getText("IGUI_StoryEngine_Notice_HordeSense"))
    elseif args.kind == "supply_drop" and args.x and args.y then
        local dir, dist = StoryEngine.UI.distanceText(player, args.x, args.y)
        HaloTextHelper.addGoodText(player, getText("IGUI_StoryEngine_Notice_Radio"))
        player:Say(getText("IGUI_StoryEngine_Notice_Supply", StoryEngine.UI.townName(args.town), dir, dist))
        Net.toServer(player, "questList", {})
    end
end

function Client.handlers.questList(args)
    Cache.quests = args.quests or {}
    StoryEngine.QuestMap.setQuests(Cache.quests)
    StoryEngineMainWindow.refreshIfOpen("quests")
    StoryEngineMainWindow.refreshIfOpen("radio")   -- 부탁 수락/거절 버튼
end

function Client.handlers.questSubmitResult(args)
    local player = getPlayer()
    if not player then return end
    if args.ok then
        HaloTextHelper.addGoodText(player, getText("IGUI_StoryEngine_Quest_Submit_ok"))
    else
        local key = "IGUI_StoryEngine_Quest_Submit_" .. tostring(args.error)
        local text = getText(key)
        if text == key then text = getText("IGUI_StoryEngine_Error", tostring(args.error)) end
        HaloTextHelper.addBadText(player, text)
    end
    Net.toServer(player, "questList", {})
end

function Client.handlers.tradePayResult(args)
    local player = getPlayer()
    if not player then return end
    if args.ok then
        HaloTextHelper.addGoodText(player, getText("IGUI_StoryEngine_Trade_Paid"))
    else
        local key = "IGUI_StoryEngine_Trade_Error_" .. tostring(args.error)
        local text = getText(key)
        if text == key then text = getText("IGUI_StoryEngine_Error", tostring(args.error)) end
        HaloTextHelper.addBadText(player, text)
    end
    Net.toServer(player, "questList", {})
end

function Client.handlers.questRespondResult(args)
    local player = getPlayer()
    if not player then return end
    if args.ok then
        HaloTextHelper.addGoodText(player, getText(args.accept and "IGUI_StoryEngine_Quest_Accepted" or "IGUI_StoryEngine_Quest_Declined"))
    else
        HaloTextHelper.addBadText(player, getText("IGUI_StoryEngine_Error", tostring(args.error)))
    end
    Net.toServer(player, "questList", {})
end

-- 보급품 생성, 상태 변경 등. 최신 목록을 다시 받는다.
function Client.handlers.questChanged(args)
    local player = getPlayer()
    if player then Net.toServer(player, "questList", {}) end
end

-- ---------------------------------------------------------------- radio

function Client.handlers.radioChannels(args)
    Cache.hasRadio = args.hasRadio == true
    for _, ch in ipairs(args.channels or {}) do Cache.channels[ch.id] = ch end
    StoryEngineMainWindow.refreshIfOpen("radio")
end

function Client.handlers.radioHistory(args)
    if args.faction then Cache.messages[args.faction] = args.messages or {} end
    StoryEngineMainWindow.refreshIfOpen("radio")
end

function Client.handlers.radioMessage(args)
    local fid, msg = args.faction, args.msg
    if not fid or not msg then return end
    local list = Cache.messages[fid] or {}
    local last = list[#list]
    if not last or not last.n or not msg.n or msg.n > last.n then
        list[#list + 1] = msg
        while #list > 100 do table.remove(list, 1) end
    end
    Cache.messages[fid] = list
    local ch = Cache.channels[fid] or { id = fid }
    ch.trust = args.trust or ch.trust
    ch.busy = msg.from == "player"
    ch.followUpIn = args.followUpIn
    Cache.channels[fid] = ch

    local watching = StoryEngineMainWindow.instance and Cache.faction == fid
    if msg.from == "npc" and not watching then
        Cache.unread[fid] = (Cache.unread[fid] or 0) + 1
        local player = getPlayer()
        if player then
            HaloTextHelper.addGoodText(player, getText("IGUI_StoryEngine_Radio_Incoming", StoryEngine.Factions.name(fid)))
        end
    end
    StoryEngineMainWindow.refreshIfOpen("radio")
end

function Client.handlers.radioError(args)
    local player = getPlayer()
    if not player then return end
    local key = "IGUI_StoryEngine_Radio_Error_" .. tostring(args.error)
    local text = getText(key)
    if text == key then text = getText("IGUI_StoryEngine_Error", tostring(args.error)) end
    HaloTextHelper.addBadText(player, text)
    if args.error == "no_radio" then
        Cache.hasRadio = false
        StoryEngineMainWindow.refreshIfOpen("radio")
    end
end

-- 내면 독백: 머리 위에 옅은 색으로 띄운다. addLineChatElement 는 이 클라이언트에만 그리므로
-- 멀티에서도 다른 플레이어에게 보이지 않는다. 실패하면 Say 로 대신한다.
Client.MONO_COLOR = { 0.72, 0.82, 1.0 }

function Client.handlers.monologue(args)
    local player = getPlayer()
    local text = StoryEngine.UI.textOf(args)
    if not player or text == "" or player:isDead() then return end
    local c = Client.MONO_COLOR
    local ok = pcall(function() player:addLineChatElement(text, c[1], c[2], c[3]) end)
    if not ok then player:Say(text) end
end

-- 멀티 진단: 클라이언트가 보는 값과 이벤트 수
Client.diag = { OnZombieDead = 0, OnHitZombie = 0, OnPlayerDeath = 0 }
for name, _ in pairs(Client.diag) do
    Events[name].Add(function() Client.diag[name] = Client.diag[name] + 1 end)
end

local DIAG_MOODLES = { "PANIC", "BORED", "UNHAPPY", "STRESS", "TIRED", "HUNGRY", "THIRST", "SICK", "PAIN", "INJURED" }

function Client.diagView(player)
    local moodles = {}
    for _, name in ipairs(DIAG_MOODLES) do
        local ok, level = pcall(function() return player:getMoodles():getMoodleLevel(MoodleType[name]) end)
        if ok and level and level > 0 then moodles[name] = level end
    end
    local wounds = 0
    local parts = player:getBodyDamage():getBodyParts()
    for i = 0, parts:size() - 1 do
        local bp = parts:get(i)
        if bp:bitten() then wounds = wounds + 1 end
        if bp:scratched() then wounds = wounds + 1 end
        if bp:isCut() then wounds = wounds + 1 end
        if bp:deepWounded() then wounds = wounds + 1 end
        if bp:getFractureTime() > 0 then wounds = wounds + 1 end
    end
    local lang = "EN"
    pcall(function() lang = tostring(Translator.getLanguage():name()) end)
    return {
        x = math.floor(player:getX()), y = math.floor(player:getY()), z = math.floor(player:getZ()),
        hp = math.floor(player:getBodyDamage():getOverallBodyHealth()), kills = player:getZombieKills(),
        asleep = player:isAsleep() == true, outside = player:isOutside() == true,
        wounds = wounds, moodles = moodles, events = Client.diag, lang = lang,
    }
end

function Client.handlers.debugSync(args)
    for _, line in ipairs(args.lines or {}) do log("diag", tostring(line)) end
    local player = getPlayer()
    if not player then return end
    local diffs = 0
    for _, line in ipairs(args.lines or {}) do
        if string.find(tostring(line), "DIFF", 1, true) then diffs = diffs + 1 end
    end
    HaloTextHelper.addText(player, "StoryEngine diag: " .. StoryEngine.intToString(diffs) .. " diff (console.txt)")
end

function Client.handlers.debugDenied(args)
    local player = getPlayer()
    if player then HaloTextHelper.addBadText(player, getText("IGUI_StoryEngine_DebugDenied")) end
end

function Client.handlers.debugStatus(args)
    local text = tostring(args.text or "")
    log("status", text)
    local player = getPlayer()
    if player then player:Say(text) end
end

local function currentLang()
    return StoryEngine.UI.lang()
end

-- 캐릭터가 생길 때마다(시작, 접속, 사망 후 새 캐릭터) 언어를 알리고 연결 상태를 받아 온다.
-- 멀티에서는 캐릭터 생성 직후의 명령이 서버에 닿지 않을 수 있어 게임 시작 후에도 한 번 더 보낸다.
local function onCreatePlayer(playerNum, player)
    if player then
        Net.toServer(player, "hello", { lang = currentLang() })
    end
end

local function onGameStart()
    local player = getPlayer()
    if player then Net.toServer(player, "hello", { lang = currentLang() }) end
end
Events.OnGameStart.Add(onGameStart)

-- 싱글에서는 서버 쪽 OnPlayerDeath 가 처리한다. 멀티에서는 클라이언트가 보고한다.
local function onPlayerDeath(player)
    if isClient() and player and player:isLocalPlayer() then
        Net.toServer(player, "died", {})
    end
end

-- ---------------------------------------------------------------- context menu

local function send(command)
    return function(worldobjects, playerNum)
        local player = getSpecificPlayer(playerNum)
        if not player then return end
        local args = {}
        if command == "ping" then args.text = getText("IGUI_StoryEngine_PingText") end
        if command == "debugSync" then args.client = Client.diagView(player) end
        Net.toServer(player, command, args)
    end
end

local function onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    if test then return end
    context:addOption(getText("ContextMenu_StoryEngine_Radio"), worldobjects, function() StoryEngineMainWindow.open("radio") end)
    context:addOption(getText("ContextMenu_StoryEngine_QuestLog"), worldobjects, function() StoryEngineMainWindow.open("quests") end)
    context:addOption(getText("ContextMenu_StoryEngine_Journal"), worldobjects, function() StoryEngineMainWindow.open("journal") end)
    -- 디버그 메뉴: 싱글에서는 항상, 멀티에서는 디버그 모드나 관리자일 때만 (서버에서 권한을 다시 확인한다)
    if isClient() and not (getDebug() or isAdmin()) then return end
    context:addOption(getText("ContextMenu_StoryEngine_Ping"), worldobjects, send("ping"), playerNum)
    context:addOption(getText("ContextMenu_StoryEngine_Status"), worldobjects, send("debugStatus"), playerNum)
    context:addOption(getText("ContextMenu_StoryEngine_WriteJournal"), worldobjects, send("debugJournal"), playerNum)
    context:addOption(getText("ContextMenu_StoryEngine_Director"), worldobjects, send("debugDirector"), playerNum)
    context:addOption(getText("ContextMenu_StoryEngine_Supply"), worldobjects, send("debugSupply"), playerNum)
    context:addOption(getText("ContextMenu_StoryEngine_Fetch"), worldobjects, send("debugFetch"), playerNum)
    context:addOption(getText("ContextMenu_StoryEngine_Request"), worldobjects, send("debugRequest"), playerNum)
    context:addOption(getText("ContextMenu_StoryEngine_Horde"), worldobjects, send("debugHorde"), playerNum)
    context:addOption(getText("ContextMenu_StoryEngine_Event"), worldobjects, send("debugEvent"), playerNum)
    context:addOption(getText("ContextMenu_StoryEngine_HuntNear"), worldobjects, send("debugHuntNear"), playerNum)
    context:addOption(getText("ContextMenu_StoryEngine_Monologue"), worldobjects, send("debugMonologue"), playerNum)
    context:addOption(getText("ContextMenu_StoryEngine_Sync"), worldobjects, send("debugSync"), playerNum)
    context:addOption(getText("ContextMenu_StoryEngine_ItemPool"), worldobjects, send("debugItems"), playerNum)
    context:addOption(getText("ContextMenu_StoryEngine_Quests"), worldobjects, send("debugQuests"), playerNum)
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnCreatePlayer.Add(onCreatePlayer)
Events.OnPlayerDeath.Add(onPlayerDeath)
Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)

return Client
