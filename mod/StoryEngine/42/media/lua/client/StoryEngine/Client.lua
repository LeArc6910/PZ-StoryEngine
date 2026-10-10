-- 클라이언트 측: 서버 명령 수신 -> StoryEngine.Cache 갱신 -> 통합 창 갱신, 알림, 우클릭 메뉴.

if isServer() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/MainWindow"
require "StoryEngine/QuestMap"
require "StoryEngine/UIUtil"
require "StoryEngine/Factions"
require "StoryEngine/GridSync"

local Net = StoryEngine.Net
local log = StoryEngine.log

local Cache = StoryEngine.Cache

-- 멀티 클라이언트: 빅 교역소처럼 어떤 품목이든 대가로 받는지는 서버가 교신 목록(anyWants)으로 알려 준다.
-- 싱글은 서버 코드(Trade.lua)와 같은 Lua 상태라 서버 판정을 그대로 쓴다
if isClient() then
    require "StoryEngine/Value"
    StoryEngine.Value.anyWantsFn = function(fid)
        local ch = Cache.channels[fid]
        return ch ~= nil and ch.anyWants == true
    end
end

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
    Cache.journalAuthors = args.authors or Cache.journalAuthors or {}
    Cache.journalKey = args.key
    Cache.journalOwn = args.own
    Cache.journalMemoir = args.memoir == true
    Cache.journalComments = args.comments or {}
    Cache.journalName = args.name
    StoryEngineMainWindow.refreshIfOpen("journal")
end

-- 누군가의 새 일지. 내 일지면 알림, 창이 열려 있으면 보고 있는 사람의 목록을 새로 받는다.
function Client.handlers.journalNew(args)
    local player = getPlayer()
    if not player then return end
    if args.own then HaloTextHelper.addGoodText(player, getText("IGUI_StoryEngine_JournalWritten")) end
    if StoryEngineMainWindow.instance then
        Net.toServer(player, "journalList", { key = Cache.journalKey, memoir = Cache.journalMemoir or nil })
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
        HaloTextHelper.addGoodText(player, getText(args.partial and "IGUI_StoryEngine_Quest_Submit_partial"
            or "IGUI_StoryEngine_Quest_Submit_ok"))
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
        HaloTextHelper.addGoodText(player, getText(args.partial and "IGUI_StoryEngine_Trade_PaidPartial"
            or "IGUI_StoryEngine_Trade_Paid"))
    else
        local key = "IGUI_StoryEngine_Trade_Error_" .. tostring(args.error)
        local text = getText(key)
        if text == key then text = getText("IGUI_StoryEngine_Error", tostring(args.error)) end
        HaloTextHelper.addBadText(player, text)
    end
    Net.toServer(player, "questList", {})
end

-- 명절 예고·당일 (Holiday.lua)
function Client.handlers.holidayNotice(args)
    local player = getPlayer()
    if not player then return end
    local name = getText("IGUI_StoryEngine_Holiday_" .. tostring(args.id))
    if (args.days or 0) <= 0 then
        HaloTextHelper.addGoodText(player, getText("IGUI_StoryEngine_Holiday_NoticeToday", name))
    else
        HaloTextHelper.addGoodText(player, getText("IGUI_StoryEngine_Holiday_Notice", name, StoryEngine.intToString(args.days)))
    end
    Net.toServer(player, "questList", {})
end

-- 일거리 청하기 (Work.volunteer)
function Client.handlers.volunteerResult(args)
    local player = getPlayer()
    if not player then return end
    if args.ok then
        HaloTextHelper.addGoodText(player, getText("IGUI_StoryEngine_Volunteer_Chosen_" .. tostring(args.how)))
    else
        local key = "IGUI_StoryEngine_Volunteer_Why_" .. tostring(args.error)
        local text = getText(key)
        if text == key then
            key = "IGUI_StoryEngine_Work_Error_" .. tostring(args.error)
            text = getText(key)
            if text == key then text = getText("IGUI_StoryEngine_Error", tostring(args.error)) end
        end
        HaloTextHelper.addBadText(player, text)
    end
    Net.toServer(player, "questList", {})
    Net.toServer(player, "lifeList", {})
end

-- 보상 사양 (Quests.waiveReward)
function Client.handlers.rewardWaiveResult(args)
    local player = getPlayer()
    if not player then return end
    if args.ok then
        HaloTextHelper.addGoodText(player, getText("IGUI_StoryEngine_Waive_Done", StoryEngine.intToString(args.gain or 0)))
    else
        local key = "IGUI_StoryEngine_Waive_Error_" .. tostring(args.error)
        local text = getText(key)
        if text == key then text = getText("IGUI_StoryEngine_Error", tostring(args.error)) end
        HaloTextHelper.addBadText(player, text)
    end
    Net.toServer(player, "questList", {})
end

-- 거래 대가를 일·외상·빚으로 (Work.lua)
function Client.handlers.tradeWorkResult(args)
    local player = getPlayer()
    if not player then return end
    if args.ok then
        HaloTextHelper.addGoodText(player, getText("IGUI_StoryEngine_Work_Chosen_" .. tostring(args.how)))
    else
        local key = "IGUI_StoryEngine_Work_Error_" .. tostring(args.error)
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
        local key = "IGUI_StoryEngine_Quest_Error_" .. tostring(args.error)
        local text = getTextOrNull(key) and getText(key) or getText("IGUI_StoryEngine_Error", tostring(args.error))
        HaloTextHelper.addBadText(player, text)
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
    Cache.support = args.support         -- A-Life 연동 (없으면 nil)
    for _, ch in ipairs(args.channels or {}) do Cache.channels[ch.id] = ch end
    StoryEngineMainWindow.refreshIfOpen("radio")
end

-- 거래 목록 창 (TradeCatalogWindow.lua)
function Client.handlers.tradeOptions(args)
    if StoryEngineTradeCatalogWindow then StoryEngineTradeCatalogWindow.open(args) end
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
        -- 간소화 무전 창 (MiniRadio.lua)
        if StoryEngineMiniRadio then pcall(StoryEngineMiniRadio.push, fid, msg) end
        -- 메인 창 아이콘의 새 무전 수 (FloatIcon.lua)
        if StoryEngineMainIcon then pcall(StoryEngineMainIcon.onRadio, msg) end
    end
    Cache.messages[fid] = list
    local ch = Cache.channels[fid] or { id = fid }
    ch.trust = args.trust or ch.trust
    ch.personal = args.personal         -- 개인 모드에서만 (보는 사람의 개인 신뢰), 공유·싱글은 nil
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
    -- 신뢰도가 바뀌면 거점 탭 숫자도 새로 받는다
    if msg.from == "system" and msg.trust and StoryEngineMainWindow.instance then
        local player = getPlayer()
        if player then Net.toServer(player, "lifeList", {}) end
    end
end

-- 캐릭터끼리의 대화: 말한 캐릭터 머리 위에 차례로 (Banter.lua)
Client.BANTER_COLOR = { 1.0, 0.93, 0.75 }
Client.banterQueue = {}

local function findSpeaker(line)
    if line.speaker and line.speaker >= 0 then
        local ok, p = pcall(getPlayerByOnlineID, line.speaker)
        if ok and p then return p end
    end
    -- 화면 분할처럼 online ID 가 없으면 이름으로
    for i = 0, getNumActivePlayers() - 1 do
        local p = getSpecificPlayer(i)
        if p then
            local d = p:getDescriptor()
            if d and (d:getForename() .. " " .. d:getSurname()) == line.name then return p end
        end
    end
    return nil
end

function Client.handlers.banter(args)
    local now = getTimestampMs()
    for _, l in ipairs(args.lines or {}) do
        Client.banterQueue[#Client.banterQueue + 1] = { at = now + (tonumber(l.delay) or 0), line = l }
    end
end

Events.OnTick.Add(function()
    if #Client.banterQueue == 0 then return end
    local now = getTimestampMs()
    local keep = {}
    for _, q in ipairs(Client.banterQueue) do
        if now >= q.at then
            local p = findSpeaker(q.line)
            if p and not p:isDead() then
                local c = Client.BANTER_COLOR
                local text = q.line.lt and StoryEngine.UI.render(q.line.lt) or tostring(q.line.text)
                local ok = pcall(function() p:addLineChatElement(text, c[1], c[2], c[3]) end)
                if not ok then pcall(function() p:Say(text) end) end
            end
        else
            keep[#keep + 1] = q
        end
    end
    Client.banterQueue = keep
end)

-- 장기 프로젝트 완성 (Projects.lua)
function Client.handlers.projectDone(args)
    local player = getPlayer()
    if not player then return end
    local nameKey = (args.phase == 2 and "IGUI_StoryEngine_Project2_Name_" or "IGUI_StoryEngine_Project_Name_")
        .. tostring(args.faction)
    HaloTextHelper.addGoodText(player, getText("IGUI_StoryEngine_Project_DoneHalo", StoryEngine.Factions.name(args.faction),
        getText(nameKey)))
    Net.toServer(player, "lifeList", {})
end

-- NPC 가 죽거나 떠났다 (Fate.lua): 알림, 목록 새로 받기
-- 카운티 회의 알림 (서버 Council.lua)
function Client.handlers.councilNotice(args)
    local player = getPlayer()
    if not player then return end
    local key = "IGUI_StoryEngine_Council_Notice_" .. tostring(args.stage)
    if args.result then key = key .. "_" .. tostring(args.result) end
    if args.result == "failed" then HaloTextHelper.addBadText(player, getText(key))
    else HaloTextHelper.addGoodText(player, getText(key)) end
end

-- 후임 목소리 이름표 (서버 Voices.lua): 채널 -> 후임 id
function Client.handlers.npcVoices(args)
    local voice = StoryEngine.Factions.voice
    for k in pairs(voice) do voice[k] = nil end
    for fid, v in pairs(args.voices or {}) do voice[fid] = v end
    if StoryEngineMainWindow and StoryEngineMainWindow.instance then StoryEngineMainWindow.instance:refresh() end
end

function Client.handlers.npcFate(args)
    local player = getPlayer()
    if not player then return end
    local line = getText("IGUI_StoryEngine_Fate_Line_" .. tostring(args.kind), StoryEngine.Factions.name(args.faction))
    if args.kind == "revived" then
        HaloTextHelper.addGoodText(player, line)
    else
        HaloTextHelper.addBadText(player, line)
    end
    Net.toServer(player, "radioChannels", {})
    Net.toServer(player, "lifeList", {})
end

-- 거점 탭: NPC 생활 상태 (Life.lua)
function Client.handlers.lifeList(args)
    Cache.life = args.npcs or {}
    StoryEngineMainWindow.refreshIfOpen("life")
    if StoryEngineQuickSpecialty and StoryEngineQuickSpecialty.onLifeList then
        pcall(StoryEngineQuickSpecialty.onLifeList)
    end
end

-- 인물 탭 (Chronicle.lua)
function Client.handlers.npcProfiles(args)
    Cache.people = args.npcs or {}
    StoryEngineMainWindow.refreshIfOpen("people")
end

function Client.handlers.lifeDonateResult(args)
    local player = getPlayer()
    if not player then return end
    local name = StoryEngine.Factions.name(args.faction)
    if args.ok then
        if args.points then
            HaloTextHelper.addGoodText(player, getText("IGUI_StoryEngine_Project_Added", name,
                StoryEngine.intToString(args.points)))
        else
            HaloTextHelper.addGoodText(player, getText("IGUI_StoryEngine_Life_Donated", name))
        end
        return
    end
    local key = "IGUI_StoryEngine_Life_Error_" .. tostring(args.error)
    local text = getTextOrNull(key) and getText(key, StoryEngine.intToString(args.wait or 0))
        or getText("IGUI_StoryEngine_Error", tostring(args.error))
    HaloTextHelper.addBadText(player, text)
end

-- A-Life 지원 요청 결과
function Client.handlers.supportResult(args)
    local player = getPlayer()
    if not player then return end
    local name = StoryEngine.Factions.name(args.faction)
    if args.ok then
        HaloTextHelper.addGoodText(player, getText("IGUI_StoryEngine_Support_Sent", name,
            StoryEngine.intToString(args.count or 0)))
        return
    end
    local key = "IGUI_StoryEngine_Support_Error_" .. tostring(args.error)
    local text = getTextOrNull(key) and getText(key, StoryEngine.intToString(args.wait or 0))
        or getText("IGUI_StoryEngine_Support_Error", tostring(args.error))
    HaloTextHelper.addBadText(player, text)
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

-- 혼잣말: 말한 사람 머리 위에 띄운다. 멀티에서는 근처 플레이어도 받아서 그 사람 머리 위에 본다.
function Client.handlers.monologue(args)
    local speaker = nil
    if args.own then
        speaker = getPlayer()
    elseif args.speaker then
        local ok, found = pcall(getPlayerByOnlineID, args.speaker)
        if ok then speaker = found end
    end
    speaker = speaker or (not args.speaker and getPlayer()) or nil
    local text = StoryEngine.UI.textOf(args)
    if not speaker or text == "" or speaker:isDead() then return end
    local c = Client.MONO_COLOR
    local ok = pcall(function() speaker:addLineChatElement(text, c[1], c[2], c[3]) end)
    if not ok and args.own then speaker:Say(text) end
end

-- 특기 지원 등의 무전 답장을 내 머리 위에도 띄운다 (2026-09-30 사용자 요청: 교신 창을 열지 않아도 보이게).
-- 긴 답장은 문장 단위로 나눠 몇 초 간격으로, 첫 줄에 NPC 이름.
Client.OVERHEAD_COLOR = { 0.62, 0.92, 0.68 }
Client.OVERHEAD_GAP_MS = 3500
Client.OVERHEAD_CHUNK = 150          -- 바이트 (한글 약 50자)
Client.overheadQueue = {}

-- 문장 끝(. ! ? … 줄바꿈) 뒤에서 자르고, 짧은 문장은 이어 붙인다
function Client.splitOverhead(text, limit)
    local sentences = {}
    local pos, len = 1, string.len(text)
    while pos <= len do
        local _, e = string.find(text, "[%.!%?\n]+", pos)
        if not e then
            sentences[#sentences + 1] = string.sub(text, pos)
            break
        end
        sentences[#sentences + 1] = string.sub(text, pos, e)
        pos = e + 1
    end
    local out, cur = {}, ""
    for _, s in ipairs(sentences) do
        s = string.gsub(string.gsub(s, "^%s+", ""), "%s+$", "")
        if s ~= "" then
            if cur == "" then
                cur = s
            elseif string.len(cur) + 1 + string.len(s) <= limit then
                cur = cur .. " " .. s
            else
                out[#out + 1] = cur
                cur = s
            end
        end
    end
    if cur ~= "" then out[#out + 1] = cur end
    return out
end

function Client.handlers.radioOverhead(args)
    local text = StoryEngine.UI.textOf(args)
    if text == "" then return end
    local name = StoryEngine.Factions.name(tostring(args.faction))
    local now = getTimestampMs()
    for i, part in ipairs(Client.splitOverhead(text, Client.OVERHEAD_CHUNK)) do
        Client.overheadQueue[#Client.overheadQueue + 1] = {
            at = now + (i - 1) * Client.OVERHEAD_GAP_MS,
            text = (i == 1) and ("[" .. name .. "] " .. part) or part,
        }
    end
end

Events.OnTick.Add(function()
    if #Client.overheadQueue == 0 then return end
    local now = getTimestampMs()
    local p = getPlayer()
    local keep = {}
    for _, q in ipairs(Client.overheadQueue) do
        if now >= q.at then
            if p and not p:isDead() then
                local c = Client.OVERHEAD_COLOR
                local ok = pcall(function() p:addLineChatElement(q.text, c[1], c[2], c[3]) end)
                if not ok then pcall(function() p:Say(q.text) end) end
            end
        else
            keep[#keep + 1] = q
        end
    end
    Client.overheadQueue = keep
end)

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

-- 복구 작전 소식 (막 시작·다시·성공·실패)
function Client.handlers.opNotice(args)
    local player = getPlayer()
    if not player then return end
    local name = getText("IGUI_StoryEngine_Op_" .. tostring(args.kind))
    local actName = getText("IGUI_StoryEngine_OpAct_" .. tostring(args.kind) .. "_" .. tostring(args.act))
    local event = tostring(args.event)
    local text = getText("IGUI_StoryEngine_Op_Notice_" .. event, name, StoryEngine.intToString(args.act or 1),
        StoryEngine.intToString(args.acts or 5), actName)
    if event == "failed" then HaloTextHelper.addBadText(player, text) else HaloTextHelper.addGoodText(player, text) end
    Net.toServer(player, "questList", {})
end

-- 큰 사건 소식 (단계가 바뀜·끝남)
function Client.handlers.sagaNotice(args)
    local player = getPlayer()
    if not player then return end
    local name = getText("IGUI_StoryEngine_Saga_" .. tostring(args.kind))
    local text
    if args.event == "done" then
        text = getText("IGUI_StoryEngine_Saga_Notice_done", name)
    else
        text = getText("IGUI_StoryEngine_Saga_Notice_stage", name, StoryEngine.intToString(args.stage or 1),
            StoryEngine.intToString(args.stages or 3), getText("IGUI_StoryEngine_Saga_" .. tostring(args.kind) .. "_"
            .. tostring(args.stageId)))
    end
    HaloTextHelper.addText(player, text)
    Net.toServer(player, "questList", {})
end

-- 서버의 전기·수도 끊김 날짜 (복구 중이면 늘어난 값)
-- 서버의 아이템 조정 (점검 D1): 툴팁·대가 창·지원 창이 서버와 같은 분류·가치를 쓰게
function Client.handlers.itemOverrides(args)
    if not isClient() or not StoryEngine.ItemPool then return end
    local ok, changed = pcall(StoryEngine.ItemPool.useServerLines, args.lines)
    if ok and changed then StoryEngine.log("item overrides from server", #(args.lines or {})) end
end

function Client.handlers.gridSync(args)
    if StoryEngine.GridSync.apply(args) then
        log("grid sync power", tostring(args.power), "water", tostring(args.water))
    end
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

-- 디버그 메뉴는 게임을 디버그 모드(-debug)로 켰을 때만 보인다 (2026-10-03: 예전엔 싱글에서 늘 보였다).
-- 멀티에서는 서버가 권한(Capability.UseDebugContextMenu)을 다시 확인한다.
function Client.showDebugMenu()
    local ok, on = pcall(getDebug)
    return ok and on == true
end

-- 번역 문장 앞의 "StoryEngine: " 은 하위 메뉴 안에서는 뺀다
local function label(key, ...)
    local text = getText(key, ...)
    text = string.gsub(text, "^StoryEngine:%s*", "")
    return text
end

local function subMenu(context, parent, text)
    local option = parent:addOption(text, nil, nil)
    local sub = parent:getNew(parent)
    context:addSubMenu(option, sub)
    return sub
end

-- 우클릭 메뉴 "스토리 엔진 (디버그)" 하나 아래에 분류별로
local function fillDebugMenu(context, worldobjects, playerNum)
    local function toServer(command, args)
        return function()
            local p = getSpecificPlayer(playerNum)
            if p then Net.toServer(p, command, args or {}) end
        end
    end
    local root = subMenu(context, context, getText("ContextMenu_StoryEngine_Debug"))
    local fid = Cache.faction
    local npcName = StoryEngine.Factions.name(fid)

    -- 점검
    local check = subMenu(context, root, getText("ContextMenu_StoryEngine_DebugCat_check"))
    check:addOption(label("ContextMenu_StoryEngine_Ping"), worldobjects, send("ping"), playerNum)
    check:addOption(label("ContextMenu_StoryEngine_Status"), worldobjects, send("debugStatus"), playerNum)
    check:addOption(label("ContextMenu_StoryEngine_Sync"), worldobjects, send("debugSync"), playerNum)
    check:addOption(label("ContextMenu_StoryEngine_Quests"), worldobjects, send("debugQuests"), playerNum)
    check:addOption(label("ContextMenu_StoryEngine_DebugDanger"), worldobjects, send("debugDanger"), playerNum)
    check:addOption(label("ContextMenu_StoryEngine_ItemPool"), worldobjects, send("debugItems"), playerNum)

    -- 디렉터·퀘스트
    local quests = subMenu(context, root, getText("ContextMenu_StoryEngine_DebugCat_quests"))
    quests:addOption(label("ContextMenu_StoryEngine_Director"), worldobjects, send("debugDirector"), playerNum)
    quests:addOption(label("ContextMenu_StoryEngine_Supply"), worldobjects, send("debugSupply"), playerNum)
    quests:addOption(label("ContextMenu_StoryEngine_Fetch"), worldobjects, send("debugFetch"), playerNum)
    quests:addOption(label("ContextMenu_StoryEngine_Request"), worldobjects, send("debugRequest"), playerNum)
    quests:addOption(label("ContextMenu_StoryEngine_Horde"), worldobjects, send("debugHorde"), playerNum)
    quests:addOption(label("ContextMenu_StoryEngine_Event"), worldobjects, send("debugEvent"), playerNum)
    quests:addOption(label("ContextMenu_StoryEngine_HuntNear"), worldobjects, send("debugHuntNear"), playerNum)
    quests:addOption(label("ContextMenu_StoryEngine_Crisis"), worldobjects, send("debugCrisis"), playerNum)

    -- NPC (교신 탭에서 고른 상대 / 생활 자원은 거점 탭에서 고른 상대)
    local npc = subMenu(context, root, getText("ContextMenu_StoryEngine_DebugCat_npc"))
    npc:addOption(getText("ContextMenu_StoryEngine_MaxAll"), worldobjects, toServer("debugMaxAll", {}))
    local tsub = subMenu(context, npc, label("ContextMenu_StoryEngine_Trust", npcName))
    tsub:addOption("+10", worldobjects, toServer("debugTrust", { faction = fid, delta = 10 }))
    tsub:addOption("-10", worldobjects, toServer("debugTrust", { faction = fid, delta = -10 }))
    for _, v in ipairs({ 0, 20, 40, 50, 60, 70, 80, 90, 100 }) do
        tsub:addOption("= " .. tostring(v), worldobjects, toServer("debugTrust", { faction = fid, set = v }))
    end
    -- 개인 신뢰 (서버가 개인 모드가 아니면 이유를 알려 준다)
    local psub = subMenu(context, npc, label("ContextMenu_StoryEngine_PersonalTrust", npcName))
    psub:addOption("+10", worldobjects, toServer("debugPersonalTrust", { faction = fid, delta = 10 }))
    psub:addOption("-10", worldobjects, toServer("debugPersonalTrust", { faction = fid, delta = -10 }))
    for _, v in ipairs({ 0, 20, 40, 60, 80, 100 }) do
        psub:addOption("= " .. tostring(v), worldobjects, toServer("debugPersonalTrust", { faction = fid, set = v }))
    end
    local asub = subMenu(context, npc, getText("ContextMenu_StoryEngine_PersonalAsk"))
    for _, kind in ipairs({ "deliver", "horde", "fetch", "named" }) do
        asub:addOption(kind, worldobjects, toServer("debugPersonalAsk", { kind = kind }))
    end
    local lfid = Cache.lifeFaction or fid
    if not StoryEngine.Factions.byId[lfid] then lfid = "ray" end
    local lsub = subMenu(context, npc, label("ContextMenu_StoryEngine_Life", StoryEngine.Factions.name(lfid)))
    local function life(args)
        args.faction = lfid
        return toServer("debugLife", args)
    end
    lsub:addOption("+20", worldobjects, life({ delta = 20 }))
    lsub:addOption("-20", worldobjects, life({ delta = -20 }))
    for _, v in ipairs({ 0, 10, 50, 100 }) do
        lsub:addOption("= " .. tostring(v), worldobjects, life({ set = v }))
    end
    lsub:addOption(label("ContextMenu_StoryEngine_LifeBase"), worldobjects, life({ set = "base" }))
    lsub:addOption(label("ContextMenu_StoryEngine_LifeClearWait"), worldobjects, life({ delta = 0, clearWait = true }))
    lsub:addOption(label("ContextMenu_StoryEngine_SpecClearWait"), worldobjects, life({ delta = 0, clearSpec = true }))
    lsub:addOption(label("ContextMenu_StoryEngine_Spec2Rush"), worldobjects, life({ delta = 0, spec2Now = true }))
    lsub:addOption(label("ContextMenu_StoryEngine_ProjectAdd"), worldobjects, life({ delta = 0, project = 100 }))
    lsub:addOption(label("ContextMenu_StoryEngine_ProjectDone"), worldobjects, life({ delta = 0, project = 5000 }))   -- 지금 채우는 프로젝트(1차, 끝났으면 2차)를 끝낸다
    lsub:addOption(label("ContextMenu_StoryEngine_NpcShare"), worldobjects, life({ delta = 0, npcEvent = "share" }))
    lsub:addOption(label("ContextMenu_StoryEngine_NpcClash"), worldobjects, life({ delta = 0, npcEvent = "clash" }))
    lsub:addOption(label("ContextMenu_StoryEngine_NpcRaid"), worldobjects, life({ delta = 0, npcEvent = "raid" }))
    lsub:addOption(label("ContextMenu_StoryEngine_NpcEmergency"), worldobjects, life({ delta = 0, npcEvent = "emergency" }))
    lsub:addOption(label("ContextMenu_StoryEngine_FateDoom"), worldobjects, life({ delta = 0, fate = "doom" }))
    lsub:addOption(label("ContextMenu_StoryEngine_FateDead"), worldobjects, life({ delta = 0, fate = "dead" }))
    lsub:addOption(label("ContextMenu_StoryEngine_FateGone"), worldobjects, life({ delta = 0, fate = "gone" }))
    lsub:addOption(label("ContextMenu_StoryEngine_FateRevive"), worldobjects, life({ delta = 0, fate = "revive" }))
    npc:addOption(label("ContextMenu_StoryEngine_Story", npcName), worldobjects, toServer("debugStory", { faction = fid }))
    npc:addOption(label("ContextMenu_StoryEngine_Contact"), worldobjects, send("debugContact"), playerNum)
    npc:addOption(label("ContextMenu_StoryEngine_DebugNamed"), worldobjects, toServer("debugNamed", { faction = fid }))
    npc:addOption(label("ContextMenu_StoryEngine_DebugVoice"), worldobjects, toServer("debugVoice", { faction = fid }))
    npc:addOption(label("ContextMenu_StoryEngine_DebugEpisode"), worldobjects, toServer("debugEpisode", {}))
    npc:addOption(label("ContextMenu_StoryEngine_DebugCouncil"), worldobjects, toServer("debugCouncil", {}))
    local aiSub = subMenu(context, npc, label("ContextMenu_StoryEngine_DebugAiTale", npcName))
    for _, k in ipairs({ "any", "quiet", "items", "horde" }) do
        aiSub:addOption(label("ContextMenu_StoryEngine_DebugAiTale_" .. k), worldobjects,
            toServer("debugAiTale", { faction = fid, kind = k }))
    end
    npc:addOption(label("ContextMenu_StoryEngine_Scene"), worldobjects, send("debugScene"), playerNum)
    npc:addOption(label("ContextMenu_StoryEngine_Letter", npcName), worldobjects, toServer("debugLetter", { faction = fid }))
    npc:addOption(label("ContextMenu_StoryEngine_LetterFarewell", npcName), worldobjects,
        toServer("debugLetter", { faction = fid, reason = "farewell" }))

    -- 캐릭터 (일지, 혼잣말, 동료 대화)
    local char = subMenu(context, root, getText("ContextMenu_StoryEngine_DebugCat_character"))
    char:addOption(label("ContextMenu_StoryEngine_WriteJournal"), worldobjects, send("debugJournal"), playerNum)
    char:addOption(label("ContextMenu_StoryEngine_Monologue"), worldobjects, send("debugMonologue"), playerNum)
    char:addOption(label("ContextMenu_StoryEngine_Banter"), worldobjects, send("debugBanter"), playerNum)

    -- 세계 (세계 변화·전기 수도, 큰 사건, 복구 작전, 라디오 방송)
    local world = subMenu(context, root, getText("ContextMenu_StoryEngine_DebugCat_world"))
    local wsub = subMenu(context, world, label("ContextMenu_StoryEngine_World"))
    for _, ev in ipairs({ "power", "water", "winter", "snow", "day30", "day90", "day180" }) do
        wsub:addOption(label("ContextMenu_StoryEngine_World_" .. ev), worldobjects, toServer("debugWorld", { event = ev }))
    end
    for _, kind in ipairs({ "power", "water", "reset" }) do
        wsub:addOption(label("ContextMenu_StoryEngine_Grid_" .. kind), worldobjects, toServer("debugGrid", { kind = kind }))
    end
    local ssub = subMenu(context, world, label("ContextMenu_StoryEngine_Saga"))
    for _, entry in ipairs({ { "start", "crash" }, { "start", "migration" }, { "start", "epidemic" }, { "start", "blackout" },
                             { "next" }, { "stop" } }) do
        ssub:addOption(label("ContextMenu_StoryEngine_Saga_" .. entry[1] .. (entry[2] and ("_" .. entry[2]) or "")),
            worldobjects, toServer("debugSaga", { action = entry[1], kind = entry[2] }))
    end
    local osub = subMenu(context, world, label("ContextMenu_StoryEngine_Op"))
    for _, entry in ipairs({ { "start", "water" }, { "start", "power" }, { "next" }, { "fail" }, { "stop" } }) do
        osub:addOption(label("ContextMenu_StoryEngine_Op_" .. entry[1] .. (entry[2] and ("_" .. entry[2]) or "")),
            worldobjects, toServer("debugOp", { action = entry[1], kind = entry[2] }))
    end
    world:addOption(label("ContextMenu_StoryEngine_Broadcast"), worldobjects, send("debugBroadcast"), playerNum)
    local hsub = subMenu(context, world, label("ContextMenu_StoryEngine_DebugHoliday"))
    for _, id in ipairs({ "newyear", "seollal", "daeboreum", "dano", "chuseok", "dongji", "christmas", "july4", "halloween",
                          "thanksgiving" }) do
        local hname = getText("IGUI_StoryEngine_Holiday_" .. id)
        hsub:addOption(label("ContextMenu_StoryEngine_DebugHolidayAnnounce", hname), worldobjects,
            toServer("debugHoliday", { id = id, stage = "announce" }))
        hsub:addOption(label("ContextMenu_StoryEngine_DebugHolidayFeast", hname), worldobjects,
            toServer("debugHoliday", { id = id, stage = "feast" }))
    end
    world:addOption(label("ContextMenu_StoryEngine_BroadcastRerun"), worldobjects, toServer("debugBroadcast", { rerun = true }))

    -- A-Life 연동
    local alife = subMenu(context, root, getText("ContextMenu_StoryEngine_DebugCat_alife"))
    alife:addOption(label("ContextMenu_StoryEngine_ALifeSupport"), worldobjects, toServer("debugALifeSupport", { faction = fid }))
    alife:addOption(label("ContextMenu_StoryEngine_ALifeAttack"), worldobjects, send("debugALifeAttack"), playerNum)
end

local function onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    if test then return end
    context:addOption(getText("ContextMenu_StoryEngine_Radio"), worldobjects, function() StoryEngineMainWindow.open("radio") end)
    context:addOption(getText("ContextMenu_StoryEngine_QuestLog"), worldobjects, function() StoryEngineMainWindow.open("quests") end)
    context:addOption(getText("ContextMenu_StoryEngine_Journal"), worldobjects, function() StoryEngineMainWindow.open("journal") end)
    context:addOption(getText("ContextMenu_StoryEngine_Life_Open"), worldobjects, function() StoryEngineMainWindow.open("life") end)
    if StoryEngineQuickSpecialty then
        -- 특기 빠른 사용 (QuickSpecialty.lua): 하위 메뉴로 바로
        local opt = context:addOption(getText("ContextMenu_StoryEngine_QuickSpecialty"), worldobjects, nil)
        local sub = ISContextMenu:getNew(context)
        context:addSubMenu(opt, sub)
        pcall(StoryEngineQuickSpecialty.fill, sub)
        Net.toServer(getSpecificPlayer(playerNum) or getPlayer(), "lifeList", {})
        -- 특기 아이콘 보이기·숨기기
        context:addOption(getText(StoryEngineQuickSpecialty.dockShown() and "ContextMenu_StoryEngine_QuickDockHide"
            or "ContextMenu_StoryEngine_QuickDockShow"), worldobjects, function()
            if StoryEngineQuickSpecialty.dockShown() then StoryEngineQuickSpecialty.hideDock()
            else StoryEngineQuickSpecialty.showDock() end
        end)
        -- 2차 특기 아이콘: 2차 특기가 열린 NPC 가 있거나 이미 떠 있을 때만
        if StoryEngineQuickSpecialty.dock2Shown()
            or StoryEngineQuickSpecialty.anyUnlocked((StoryEngine.Cache or {}).life) then
            context:addOption(getText(StoryEngineQuickSpecialty.dock2Shown() and "ContextMenu_StoryEngine_QuickDock2Hide"
                or "ContextMenu_StoryEngine_QuickDock2Show"), worldobjects, function()
                if StoryEngineQuickSpecialty.dock2Shown() then StoryEngineQuickSpecialty.hideDock2()
                else StoryEngineQuickSpecialty.showDock2() end
            end)
        end
    end
    if StoryEngineMainIcon then
        context:addOption(getText(StoryEngineMainIcon.instance and "ContextMenu_StoryEngine_MainIconHide"
            or "ContextMenu_StoryEngine_MainIconShow"), worldobjects, function() StoryEngineMainIcon.toggle() end)
    end
    if StoryEngineMiniRadio then
        context:addOption(getText(StoryEngineMiniRadio.instance and "ContextMenu_StoryEngine_MiniHide"
            or "ContextMenu_StoryEngine_MiniShow"), worldobjects, function() StoryEngineMiniRadio.toggle() end)
    end
    if Client.showDebugMenu() then fillDebugMenu(context, worldobjects, playerNum) end
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnCreatePlayer.Add(onCreatePlayer)
Events.OnPlayerDeath.Add(onPlayerDeath)
Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)

return Client
