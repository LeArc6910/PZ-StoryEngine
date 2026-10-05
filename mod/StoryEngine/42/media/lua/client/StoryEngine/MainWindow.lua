-- StoryEngine 통합 창: 상단 탭 [교신] [퀘스트] [일지] [거점]
--
-- 교신: 왼쪽 주파수(세력) 목록, 오른쪽 대화 기록 + 입력창. 무전기가 있어야 말할 수 있다.
-- 퀘스트: 왼쪽 목록(완료 초록, 실패 빨강), 오른쪽 경위·할 일·상세 + "지도에서 보기" / "무전으로 제출".
-- 일지: 최근 일지 항목.
-- 데이터는 StoryEngine.Cache 에 모이고, Client.lua 의 서버 명령 핸들러가 채운 뒤 refresh 를 부른다.

if isServer() then return end

require "ISUI/ISCollapsableWindow"
require "ISUI/ISPanel"
require "ISUI/ISTabPanel"
require "ISUI/ISRichTextPanel"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTextEntryBox"
require "ISUI/ISButton"
require "ISUI/Maps/ISWorldMap"
require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/UIUtil"
require "StoryEngine/QuestMap"
require "StoryEngine/Factions"
require "StoryEngine/Value"
require "StoryEngine/TradePayWindow"
require "StoryEngine/DonateWindow"
require "StoryEngine/TradeCatalogWindow"

local UI = StoryEngine.UI
local Net = StoryEngine.Net
local Factions = StoryEngine.Factions

local FONT_H = getTextManager():getFontHeight(UIFont.Small)
local PAD = 8
local LIST_W = 250
local LINE_H = FONT_H + 2
local ITEM_H = LINE_H * 2 + 10
local BUTTON_H = FONT_H + 12
local ENTRY_H = FONT_H * 3 + 14      -- 입력창: 긴 문장은 칸 안에서 줄바꿈된다
local SEND_W = 90

local COLOR_DEFAULT = { r = 0.9, g = 0.9, b = 0.9 }
local COLOR_DONE = { r = 0.45, g = 0.9, b = 0.45 }
local COLOR_FAILED = { r = 0.95, g = 0.4, b = 0.35 }
local COLOR_PROPOSED = { r = 1.0, g = 0.85, b = 0.45 }
local COLOR_DECLINED = { r = 0.6, g = 0.6, b = 0.6 }
local COLOR_MEMOIR = { r = 0.85, g = 0.75, b = 0.95 }
local SMALL_W = 80
local SUPPORT_W = 120
local TRADE_W = 110

StoryEngine.Cache = StoryEngine.Cache or {
    quests = {}, journal = {}, channels = {}, messages = {}, unread = {},
    hasRadio = false, faction = "ray", questId = nil,
}
local Cache = StoryEngine.Cache

local function player()
    return getSpecificPlayer(0)
end

local function request(command, args)
    local p = player()
    if p then Net.toServer(p, command, args or {}) end
end

local ACTIVE = { offered = true, approached = true, entered = true, retrieved = true, accepted = true }

-- 물자 지원·프로젝트 창에서 진행 중인 퀘스트 물건만 빼도록 Value 에 알려 준다 (목록에 없으면 끝난 퀘스트로 봄, 서버가 다시 검증)
if StoryEngine.Value then
    StoryEngine.Value.isQuestActive = function(id)
        for _, q in ipairs(StoryEngine.Cache and StoryEngine.Cache.quests or {}) do
            if q.id == id then return ACTIVE[q.state] == true or q.state == "proposed" end
        end
        return false
    end
end

-- 이 세력이 답을 기다리는 부탁·거래 제안
local function pendingProposal(fid)
    for _, q in ipairs(Cache.quests) do
        if (q.kind == "deliver" or q.kind == "trade" or q.kind == "horde") and q.state == "proposed"
            and q.origin and q.origin.faction == fid then
            return q
        end
    end
    return nil
end

local function catName(cat)
    return getText("IGUI_StoryEngine_Cat_" .. tostring(cat))
end

-- 낼 수 있는 가치 (대가 품목 기준)
local function payableValue(q)
    local p = getSpecificPlayer(0)
    if not p or not q.payCategory then return 0 end
    local total = 0
    for _, it in ipairs(StoryEngine.Value.payableItems(p, q.payCategory)) do
        total = total + StoryEngine.Value.itemValue(it)
    end
    return math.floor(total)
end

local function respond(q, accept)
    if q then request("questRespond", { id = q.id, accept = accept }) end
end

local function newRichText(x, y, w, h)
    local rt = ISRichTextPanel:new(x, y, w, h)
    rt:initialise()
    rt.autosetheight = false
    rt.clip = true
    rt.marginLeft = 10
    rt.marginRight = 10
    rt:addScrollBars()
    return rt
end

-- 폭을 넘는 글자는 "..." 로 줄인다
local function fit(text, width)
    text = tostring(text or "")
    local tm = getTextManager()
    if tm:MeasureStringX(UIFont.Small, text) <= width then return text end
    local s = text
    while string.len(s) > 0 and tm:MeasureStringX(UIFont.Small, s .. "...") > width do
        s = string.sub(s, 1, string.len(s) - 1)
    end
    return s .. "..."
end

-- 두 줄 항목: 첫 줄 제목(색 지정 가능), 둘째 줄 부가 정보. item.item = { title, sub, color, value }
local function drawTwoLine(self, y, item, alt)
    local h = self.itemheight
    if y + self:getYScroll() + h < 0 or y + self:getYScroll() >= self.height then return y + h end
    if self.selected == item.index then
        self:drawSelection(0, y, self:getWidth(), h - 1)
    elseif self.mouseoverselected == item.index and self:isMouseOver() and not self:isMouseOverScrollBar() then
        self:drawMouseOverHighlight(0, y, self:getWidth(), h - 1)
    end
    self:drawRectBorder(0, y, self:getWidth(), h, 0.5, self.borderColor.r, self.borderColor.g, self.borderColor.b)
    local data = item.item
    local c = data.color or COLOR_DEFAULT
    local w = self:getWidth() - 28
    self:drawText(fit(data.title, w), 10, y + 5, c.r, c.g, c.b, 1, UIFont.Small)
    self:drawText(fit(data.sub, w), 10, y + 5 + LINE_H, 0.6, 0.6, 0.6, 1, UIFont.Small)
    return y + h
end

local function newList(x, y, w, h, target, onSelect)
    local l = ISScrollingListBox:new(x, y, w, h)
    l:initialise()
    l:instantiate()
    l.itemheight = ITEM_H
    l.font = UIFont.Small
    l.drawBorder = true
    l.doDrawItem = drawTwoLine
    l:setOnMouseDownFunction(target, function(t, data) onSelect(t, data and data.value) end)
    return l
end

local function scrollToBottom(rt)
    local extra = rt:getScrollHeight() - rt:getHeight()
    rt:setYScroll(extra > 0 and -extra or 0)
end

local function newButton(x, y, w, title, target, onClick)
    local b = ISButton:new(x, y, w, BUTTON_H, title, target, onClick)
    b:initialise()
    b:setAnchorTop(false)
    b:setAnchorBottom(true)
    return b
end

local function derivePanel(name)
    local cls = ISPanel:derive(name)
    function cls:new(x, y, w, h)
        local o = ISPanel:new(x, y, w, h)
        setmetatable(o, self)
        self.__index = self
        o.background = false
        return o
    end
    return cls
end

-- ================================================================ radio tab

StoryEngineRadioPanel = derivePanel("StoryEngineRadioPanel")

function StoryEngineRadioPanel:createChildren()
    local h = self.height
    self.list = newList(PAD, PAD, LIST_W, h - PAD * 2, self, StoryEngineRadioPanel.onSelect)
    self.list:setAnchorBottom(true)
    self:addChild(self.list)

    local x = PAD * 2 + LIST_W
    local w = self.width - x - PAD
    self.history = newRichText(x, PAD, w, h - PAD * 4 - ENTRY_H - BUTTON_H)
    self.history:setAnchorRight(true)
    self.history:setAnchorBottom(true)
    self:addChild(self.history)

    self.entry = ISTextEntryBox:new("", x, h - PAD - ENTRY_H, w - SEND_W - PAD, ENTRY_H)
    self.entry:initialise()
    self.entry:instantiate()
    self.entry:setMaxTextLength(200)
    -- 긴 문장은 칸 안에서 줄바꿈해 보여 준다. 논리적 줄은 1줄이라 엔터는 그대로 전송이다
    -- (UITextBox2.onKeyEnter: 줄 수가 maxLines 에 닿으면 onCommandEntered 를 부른다).
    self.entry:setMultipleLine(true)
    self.entry:setMaxLines(1)
    pcall(function() self.entry.javaObject:setWrapLines(true) end)
    self.entry.radioPanel = self
    self.entry.onCommandEntered = function(entry) entry.radioPanel:send() end
    self.entry:setAnchorTop(false)
    self.entry:setAnchorBottom(true)
    self.entry:setAnchorRight(true)
    self:addChild(self.entry)

    self.sendButton = ISButton:new(self.width - PAD - SEND_W, h - PAD - ENTRY_H, SEND_W, ENTRY_H,
        getText("IGUI_StoryEngine_Radio_Send"), self, StoryEngineRadioPanel.send)
    self.sendButton:initialise()
    self.sendButton:setAnchorLeft(false)
    self.sendButton:setAnchorRight(true)
    self.sendButton:setAnchorTop(false)
    self.sendButton:setAnchorBottom(true)
    self:addChild(self.sendButton)

    -- 부탁이 오면 상태 줄 오른쪽에 수락/거절 버튼
    local rowY = h - PAD * 2 - ENTRY_H - BUTTON_H
    self.acceptButton = ISButton:new(self.width - PAD * 2 - SMALL_W * 2, rowY, SMALL_W, BUTTON_H,
        getText("IGUI_StoryEngine_Quest_Accept"), self, function() respond(pendingProposal(Cache.faction), true) end)
    self.declineButton = ISButton:new(self.width - PAD - SMALL_W, rowY, SMALL_W, BUTTON_H,
        getText("IGUI_StoryEngine_Quest_Decline"), self, function() respond(pendingProposal(Cache.faction), false) end)
    -- A-Life 연동: 무장 지원 요청 (신뢰도 50 이상, 세력당 하루 한 번). A-Life 가 없으면 숨김
    self.supportButton = ISButton:new(self.width - PAD * 3 - SMALL_W * 2 - SUPPORT_W, rowY, SUPPORT_W, BUTTON_H,
        getText("IGUI_StoryEngine_Support_Button"), self, function()
            request("supportRequest", { faction = Cache.faction })
        end)
    -- 버튼 거래 (Trade.ask): 품목·등급을 메뉴에서 골라 청한다. AI 없이도 된다
    self.tradeButton = ISButton:new(self.width - PAD - TRADE_W, rowY, TRADE_W, BUTTON_H,
        getText("IGUI_StoryEngine_TradeAsk_Button"), self, function()
            request("tradeOptions", { faction = Cache.faction })
        end)
    self.tradeButton.tooltip = getText("IGUI_StoryEngine_TradeAsk_Tooltip")
    for _, b in ipairs({ self.acceptButton, self.declineButton, self.supportButton, self.tradeButton }) do
        b:initialise()
        b:setAnchorLeft(false)
        b:setAnchorRight(true)
        b:setAnchorTop(false)
        b:setAnchorBottom(true)
        b:setVisible(false)
        self:addChild(b)
    end
end

function StoryEngineRadioPanel:render()
    ISPanel.render(self)
    local fid = Cache.faction
    local ch = Cache.channels[fid]
    local text, r, g, b
    local proposal = pendingProposal(fid)
    if proposal and proposal.kind == "trade" then
        text, r, g, b = getText("IGUI_StoryEngine_Trade_Bar", UI.itemList(proposal.goods), catName(proposal.payCategory),
            StoryEngine.intToString(proposal.price or 0)), 1, 0.85, 0.45
        if (proposal.haggleLeft or 0) > 0 then
            text = text .. "  |  " .. getText("IGUI_StoryEngine_Trade_HaggleLeft", StoryEngine.intToString(proposal.haggleLeft))
        end
    elseif proposal and proposal.kind == "horde" then
        text, r, g, b = getText("IGUI_StoryEngine_Horde_Bar", Factions.name(fid), UI.townName(proposal.town),
            StoryEngine.intToString(proposal.size or 0)), 1, 0.85, 0.45
    elseif proposal then
        text, r, g, b = getText("IGUI_StoryEngine_Request_Bar", Factions.name(fid), UI.needText(proposal.need)), 1, 0.85, 0.45
    elseif ch and ch.gone then
        text, r, g, b = getText("IGUI_StoryEngine_Fate_Status_" .. tostring(ch.gone), Factions.name(fid)), 0.6, 0.6, 0.6
    elseif not Cache.hasRadio then
        text, r, g, b = getText("IGUI_StoryEngine_Radio_NoRadio"), 0.9, 0.45, 0.3
    elseif fid == "open" then
        text, r, g, b = getText(ch and ch.busy and "IGUI_StoryEngine_Open_Busy" or "IGUI_StoryEngine_Open_Status"), 0.6, 0.75, 0.9
    elseif ch and ch.busy then
        text, r, g, b = getText("IGUI_StoryEngine_Radio_Waiting", Factions.name(fid)), 0.7, 0.7, 0.7
    else
        local f = Factions.byId[fid]
        text = getText("IGUI_StoryEngine_Radio_Status", f and f.freq or "?",
            StoryEngine.intToString(ch and ch.trust or (f and f.trust) or 0))
        if ch and ch.followUpIn then
            text = text .. "  |  " .. getText("IGUI_StoryEngine_Radio_FollowUp",
                StoryEngine.intToString(math.max(1, ch.followUpIn)))
        end
        -- 이 NPC 가 거래 대가로 받는 품목 (Value.WANTS)
        local wants = {}
        for _, w in ipairs(StoryEngine.Value.wantsOf(fid)) do wants[#wants + 1] = catName(w) end
        if #wants > 0 then text = text .. "  |  " .. getText("IGUI_StoryEngine_Radio_Wants", table.concat(wants, ", ")) end
        r, g, b = 0.6, 0.75, 0.6
    end
    local rowY = self.entry:getY() - PAD - BUTTON_H
    self:drawText(text, self.history:getX(), rowY + (BUTTON_H - FONT_H) / 2, r, g, b, 1, UIFont.Small)
end

function StoryEngineRadioPanel:onSelect(fid)
    if not fid then return end
    Cache.faction = fid
    Cache.unread[fid] = 0
    request("radioHistory", { faction = fid })
    self:refresh()
end

function StoryEngineRadioPanel:send()
    local text = self.entry:getText()
    if not text then return end
    text = string.gsub(text, "\n", " ")
    if text == "" then return end
    request("radioSay", { faction = Cache.faction, text = text, lang = UI.lang() })
    self.entry:setText("")
end

-- 신뢰도 한도에 막힌 요청 안내 (Trade.blocked)
local function blockedText(b)
    local tier = b.tier and StoryEngine.intToString(b.tier) or nil
    if b.soldOut then
        return getText("IGUI_StoryEngine_Trade_SoldOut", tier or "?", catName(b.category), StoryEngine.intToString(b.restock or 0))
    end
    if b.notCarried then
        return getText("IGUI_StoryEngine_Trade_NotCarried", tostring(b.item or "?"))
    end
    if b.never and tier then
        return getText("IGUI_StoryEngine_Trade_BlockedNeverTier", tier, catName(b.category))
    elseif b.never then
        return getText("IGUI_StoryEngine_Trade_BlockedNever", catName(b.category))
    elseif b.category and tier then
        return getText("IGUI_StoryEngine_Trade_Blocked", tier, catName(b.category), StoryEngine.intToString(b.need or 0))
    end
    return getText("IGUI_StoryEngine_Trade_BlockedAll", StoryEngine.intToString(b.need or 0))
end

local function messageLine(fid, m)
    local clock = "[" .. tostring(m.clock or "") .. "] "
    if m.from == "npc" then
        return " <RGB:0.95,0.75,0.4> " .. UI.escape(clock .. Factions.name(m.npc or fid) .. ": ")
            .. " <RGB:0.9,0.9,0.85> " .. UI.escape(UI.textOf(m)) .. " <LINE> "
    elseif m.from == "system" and m.gift then
        return " <RGB:0.5,0.9,0.6> " .. UI.escape(clock .. getText("IGUI_StoryEngine_Trade_GiftLine",
            UI.itemList(m.gift.goods))) .. " <LINE> "
    elseif m.from == "system" and m.offer then
        return " <RGB:1,0.85,0.45> " .. UI.escape(clock .. getText("IGUI_StoryEngine_Trade_OfferLine",
            UI.itemList(m.offer.goods), catName(m.offer.payCategory), StoryEngine.intToString(m.offer.price or 0))) .. " <LINE> "
    elseif m.from == "system" and m.revised then
        local r = m.revised
        return " <RGB:1,0.85,0.45> " .. UI.escape(clock .. getText("IGUI_StoryEngine_Trade_RevisedLine",
            catName(r.payCategory), StoryEngine.intToString(r.price or 0), catName(r.oldPayCategory or r.payCategory),
            StoryEngine.intToString(r.oldPrice or 0))) .. " <LINE> "
    elseif m.from == "system" and m.market then
        local names = {}
        for _, o in ipairs(m.market) do names[#names + 1] = Factions.name(o.faction) end
        return " <RGB:1,0.85,0.45> " .. UI.escape(clock .. getText(m.sell and "IGUI_StoryEngine_Market_LineSell"
            or "IGUI_StoryEngine_Market_Line", StoryEngine.intToString(#m.market), table.concat(names, ", "))) .. " <LINE> "
    elseif m.from == "system" and m.swapped then
        local r = m.swapped
        return " <RGB:1,0.85,0.45> " .. UI.escape(clock .. getText("IGUI_StoryEngine_Trade_SwappedLine",
            UI.itemList(r.goods), catName(r.payCategory), StoryEngine.intToString(r.price or 0),
            UI.itemList(r.oldGoods or {}))) .. " <LINE> "
    elseif m.from == "system" and m.unchanged then
        local r = m.unchanged
        local key = r.noRounds and "IGUI_StoryEngine_Trade_UnchangedNoRounds" or "IGUI_StoryEngine_Trade_UnchangedLine"
        return " <RGB:0.7,0.7,0.65> " .. UI.escape(clock .. getText(key,
            UI.itemList(r.goods or {}), catName(r.payCategory), StoryEngine.intToString(r.price or 0))) .. " <LINE> "
    elseif m.from == "system" and m.withdrawn then
        return " <RGB:0.95,0.45,0.4> " .. UI.escape(clock .. getText("IGUI_StoryEngine_Trade_WithdrawnLine")) .. " <LINE> "
    elseif m.from == "system" and m.fate then
        return " <RGB:0.75,0.6,0.9> " .. UI.escape(clock .. getText("IGUI_StoryEngine_Fate_Line_" .. tostring(m.fate),
            Factions.name(fid))) .. " <LINE> "
    elseif m.from == "system" and m.asked then
        local a = m.asked
        return " <RGB:0.55,0.75,1> " .. UI.escape(clock .. getText("IGUI_StoryEngine_TradeAsk_Line", tostring(a.name or "?"),
            StoryEngine.intToString(a.tier or 1), catName(a.category))) .. " <LINE> "
    elseif m.from == "system" and m.holidayGift then
        local g = m.holidayGift
        local hname = getText("IGUI_StoryEngine_Holiday_" .. tostring(g.holiday))
        local text = g.money and getText("IGUI_StoryEngine_Holiday_GiftMoney", Factions.name(fid), UI.itemList(g.items or {}))
            or getText("IGUI_StoryEngine_Holiday_GiftFood", Factions.name(fid), hname, UI.itemList(g.items or {}))
        return " <RGB:0.5,0.9,0.6> " .. UI.escape(clock .. text) .. " <LINE> "
    elseif m.from == "system" and m.offlineHint then
        return " <RGB:0.6,0.6,0.6> " .. UI.escape(clock .. getText("IGUI_StoryEngine_Radio_OfflineHint")) .. " <LINE> "
    elseif m.from == "system" and m.blocked then
        return " <RGB:0.95,0.6,0.4> " .. UI.escape(clock .. blockedText(m.blocked)) .. " <LINE> "
    elseif m.from == "system" then
        local delta = tonumber(m.trust) or 0
        local sign = delta > 0 and ("+" .. StoryEngine.intToString(delta)) or StoryEngine.intToString(delta)
        local key = "IGUI_StoryEngine_TrustReason_" .. tostring(m.reason)
        local reason = m.src and getText(key, Factions.name(m.src)) or getText(key)
        if reason == key then reason = tostring(m.reason) end
        local color = delta >= 0 and "0.5,0.85,0.5" or "0.95,0.45,0.4"
        return " <RGB:" .. color .. "> " .. UI.escape(clock .. getText("IGUI_StoryEngine_Trust_Line", sign, reason)) .. " <LINE> "
    elseif m.from == "static" then
        local key = (m.error == "gone" and "IGUI_StoryEngine_Radio_StaticGone")
            or (m.error == "blackout" and "IGUI_StoryEngine_Radio_StaticBlackout") or "IGUI_StoryEngine_Radio_Static"
        return " <RGB:0.5,0.5,0.5> " .. UI.escape(clock .. getText(key)) .. " <LINE> "
    end
    return " <RGB:0.55,0.75,1> " .. UI.escape(clock .. tostring(m.name or "?") .. ": ")
        .. " <RGB:0.85,0.85,0.85> " .. UI.escape(m.text) .. " <LINE> "
end

function StoryEngineRadioPanel:refresh()
    local selectedIndex = 1
    self.list:clear()
    -- 공용 주파수를 맨 위에
    local rows = { { id = "open", freq = "121.5", open = true } }
    for _, f in ipairs(Factions.list) do rows[#rows + 1] = f end
    for i, f in ipairs(rows) do
        local unread = Cache.unread[f.id] or 0
        local sub = f.open and getText("IGUI_StoryEngine_Radio_OpenSub") or getText("IGUI_StoryEngine_Radio_ListSub", f.freq)
        if unread > 0 then sub = sub .. "   " .. getText("IGUI_StoryEngine_Radio_Unread", StoryEngine.intToString(unread)) end
        local gone = Cache.channels[f.id] and Cache.channels[f.id].gone
        local color = unread > 0 and { r = 1, g = 0.85, b = 0.45 } or nil
        if gone then
            sub = getText("IGUI_StoryEngine_Fate_" .. tostring(gone))
            color = COLOR_DECLINED
        end
        self.list:addItem(Factions.name(f.id), {
            title = Factions.name(f.id), sub = sub, value = f.id, color = color,
        })
        if f.id == Cache.faction then selectedIndex = i end
    end
    self.list.selected = selectedIndex

    local msgs = Cache.messages[Cache.faction] or {}
    local parts = {}
    for _, m in ipairs(msgs) do parts[#parts + 1] = messageLine(Cache.faction, m) end
    if #parts == 0 then
        parts[1] = " <RGB:0.6,0.6,0.6> " .. UI.escape(getText("IGUI_StoryEngine_Radio_Empty", Factions.name(Cache.faction)))
    end
    self.history:setText(table.concat(parts))
    self.history:paginate()
    scrollToBottom(self.history)
    local proposal = pendingProposal(Cache.faction) ~= nil
    self.acceptButton:setVisible(proposal)
    self.declineButton:setVisible(proposal)
    local chSel = Cache.channels[Cache.faction]
    local trades = #(StoryEngine.Value.WANTS[Cache.faction] or {}) > 0 or StoryEngine.Value.anyWantsFn(Cache.faction)
    self.tradeButton:setVisible(trades and not proposal and not (chSel and chSel.gone))

    -- 지원 요청 버튼은 2026-09-29부터 숨긴다: 방위대 특기(거점 탭)로 옮겼고, A-Life 자동 지원만 남았다
    local support = nil
    self.supportButton:setVisible(false)
    if support then
        local ready = (support.level or 0) > 0 and (support.wait or 0) == 0
        self.supportButton:setEnable(ready)
        if (support.level or 0) == 0 then
            self.supportButton.tooltip = getText("IGUI_StoryEngine_Support_Error_low_trust")
        elseif (support.wait or 0) > 0 then
            self.supportButton.tooltip = getText("IGUI_StoryEngine_Support_Error_cooldown", StoryEngine.intToString(support.wait))
        else
            self.supportButton.tooltip = getText("IGUI_StoryEngine_Support_Tooltip")
        end
    end
end

-- ================================================================ quest tab

local findQuest
local namedDetail

StoryEngineQuestPanel = derivePanel("StoryEngineQuestPanel")

-- 퀘스트 묶음 (2026-10-04 사용자 요청): 목록 위 버튼으로 수락 대기 / 진행 중 / 실패·거절 / 완료를 나눠 본다
local QUEST_GROUPS = { "proposed", "active", "failed", "completed" }

local function questGroup(q)
    if q.state == "proposed" then return "proposed" end
    if ACTIVE[q.state] then return "active" end
    if q.state == "completed" then return "completed" end
    return "failed"      -- failed, declined (거절·무응답·취소·철회)
end

function StoryEngineQuestPanel:createChildren()
    local h = self.height
    -- 묶음 버튼 2줄 x 2개
    self.groupButtons = {}
    local gw = math.floor((LIST_W - PAD) / 2)
    for i, g in ipairs(QUEST_GROUPS) do
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        local b = ISButton:new(PAD + col * (gw + PAD), PAD + row * (BUTTON_H + 4), gw, BUTTON_H, "", self, function(panel)
            Cache.questGroup = g
            panel:refresh()
        end)
        b:initialise()
        self:addChild(b)
        self.groupButtons[g] = b
    end
    local top = PAD + 2 * BUTTON_H + 4 + PAD
    self.list = newList(PAD, top, LIST_W, h - top - PAD, self, StoryEngineQuestPanel.onSelect)
    self.list:setAnchorBottom(true)
    self:addChild(self.list)

    local x = PAD * 2 + LIST_W
    local w = self.width - x - PAD
    self.detail = newRichText(x, PAD, w, h - PAD * 3 - BUTTON_H)
    self.detail:setAnchorRight(true)
    self.detail:setAnchorBottom(true)
    self:addChild(self.detail)

    self.mapButton = newButton(x, h - PAD - BUTTON_H, 160, getText("IGUI_StoryEngine_Quest_ShowOnMap"),
        self, StoryEngineQuestPanel.onShowMap)
    self:addChild(self.mapButton)
    self.submitButton = newButton(x + 160 + PAD, h - PAD - BUTTON_H, 180, getText("IGUI_StoryEngine_Quest_Submit"),
        self, StoryEngineQuestPanel.onSubmit)
    self:addChild(self.submitButton)
    self.acceptButton = newButton(x, h - PAD - BUTTON_H, 120, getText("IGUI_StoryEngine_Quest_Accept"),
        self, function(panel) respond(findQuest(Cache.questId), true) end)
    self:addChild(self.acceptButton)
    self.declineButton = newButton(x + 120 + PAD, h - PAD - BUTTON_H, 120, getText("IGUI_StoryEngine_Quest_Decline"),
        self, function(panel) respond(findQuest(Cache.questId), false) end)
    self:addChild(self.declineButton)
    -- 다른 대가 (Work.lua): 일·외상·빚을 고르는 메뉴
    self.workButton = newButton(x, h - PAD - BUTTON_H, 150, getText("IGUI_StoryEngine_Work_Button"),
        self, StoryEngineQuestPanel.onWork)
    self.workButton.tooltip = getText("IGUI_StoryEngine_Work_Tooltip")
    self.workButton:setVisible(false)
    self:addChild(self.workButton)
    -- 위기 선택 버튼 (선택지마다 하나)
    self.choiceButtons = {}
    for i = 1, 3 do
        local b = newButton(x + (i - 1) * (170 + PAD), h - PAD - BUTTON_H, 170, "", self, function(panel)
            local q = findQuest(Cache.questId)
            if q then request("questChoose", { id = q.id, index = i }) end
        end)
        b:setVisible(false)
        self:addChild(b)
        self.choiceButtons[i] = b
    end
end

findQuest = function(id)
    for _, q in ipairs(Cache.quests) do
        if q.id == id then return q end
    end
    return nil
end

-- 퀘스트 아이템을 가지고 있는지 (가방 속까지)
local function holdsQuestItem(q)
    local p = player()
    if not p then return false end
    if q.kind == "deliver" or q.kind == "extort" then
        for _, n in ipairs(q.need or {}) do
            local cat = UI.pointCat(n)
            if cat then
                if UI.pointsHeld(p, cat, n[3]) + 0.001 < (n[2] or 1) then return false end
            elseif UI.countHeld(p, n[1]) < (n[2] or 1) then
                return false
            end
        end
        return true
    end
    if q.kind == "collect" then
        for _, n in ipairs(q.need or {}) do
            local left = (n[2] or 1) - ((q.got or {})[n[1]] or 0)
            if left > 0 and UI.countHeld(p, n[1]) > 0 then return true end
        end
        return false
    end
    if q.kind ~= "fetch" and q.kind ~= "named" then return false end
    for _, fullType in ipairs(q.items or {}) do
        local list = p:getInventory():getAllTypeRecurse(fullType)
        for i = 0, list:size() - 1 do
            local mod = list:get(i):getModData()
            if mod and mod.storyQuest == q.id then return true end
        end
    end
    return false
end

function StoryEngineQuestPanel:onSelect(q)
    Cache.questId = q and q.id
    self:refresh()
end

-- 다른 대가 메뉴: 이 NPC 가 받는 방식, 안 되는 것은 회색 + 이유
function StoryEngineQuestPanel:onWork()
    local q = findQuest(Cache.questId)
    if not q or not q.workOptions then return end
    local context = ISContextMenu.get(0, getMouseX(), getMouseY())
    for _, o in ipairs(q.workOptions) do
        local opt = context:addOption(getText("IGUI_StoryEngine_Work_" .. tostring(o.how)), nil, function()
            request("tradeWork", { id = q.id, how = o.how })
        end)
        local tt = ISToolTip:new()
        tt:initialise()
        tt:setVisible(false)
        local text = getText("IGUI_StoryEngine_Work_" .. tostring(o.how) .. "_desc")
        if not o.ok then
            opt.notAvailable = true
            local why = getText("IGUI_StoryEngine_Work_Why_" .. tostring(o.why), StoryEngine.intToString(o.need or 0))
            text = why .. " <LINE> " .. text
        end
        tt.description = text
        opt.toolTip = tt
    end
    local left = context:addOption(getText("IGUI_StoryEngine_Work_WeekLeft", StoryEngine.intToString(q.workWeekLeft or 0)), nil, nil)
    left.notAvailable = true
end

function StoryEngineQuestPanel:onShowMap()
    local q = findQuest(Cache.questId)
    if not q then return end
    local x, y = StoryEngine.QuestMap.markerPos(q)
    ISWorldMap.ShowWorldMap(0, x, y, 18.0)
end

function StoryEngineQuestPanel:onSubmit()
    local q = findQuest(Cache.questId)
    if not q then return end
    if q.kind == "trade" then
        StoryEngineTradePayWindow.open(q)
        return
    end
    -- 품목 점수 부탁: 낼 물건을 고르는 창 (거래 대가 창과 같은 것, 고른 물건 id 를 questSubmit 으로)
    if q.kind == "deliver" or q.kind == "extort" then
        for _, n in ipairs(q.need or {}) do
            local cat = UI.pointCat(n)
            if cat then
                StoryEngineTradePayWindow.open({ id = q.id, payCategory = cat, price = n[2] or 1, points = true,
                                                 minTier = n[3], command = "questSubmit",
                                                 titleKey = "IGUI_StoryEngine_Need_PickTitle" })
                return
            end
        end
    end
    request("questSubmit", { id = q.id })
end

-- 복구 작전 이름과 막 이름
local function opName(op) return getText("IGUI_StoryEngine_Op_" .. tostring(op.kind)) end
local function opActName(op) return getText("IGUI_StoryEngine_OpAct_" .. tostring(op.kind) .. "_" .. tostring(op.act)) end

local function sagaName(sg) return getText("IGUI_StoryEngine_Saga_" .. tostring(sg.kind)) end
local function sagaStageName(sg) return getText("IGUI_StoryEngine_Saga_" .. tostring(sg.kind) .. "_" .. tostring(sg.stageId)) end

local function questTitle(q)
    local src = q.origin and q.origin.source
    if q.kind == "named" then
        return getText("IGUI_StoryEngine_QTitle_named", getText("IGUI_StoryEngine_Named_" .. tostring(q.person) .. "_name"),
            UI.townName(q.town))
    end
    if q.holiday and q.kind == "collect" then
        return getText("IGUI_StoryEngine_QTitle_holiday_collect", getText("IGUI_StoryEngine_Holiday_" .. tostring(q.holiday)))
    end
    if q.holiday then
        return getText("IGUI_StoryEngine_QTitle_holiday", getText("IGUI_StoryEngine_Holiday_" .. tostring(q.holiday)),
            UI.townName(q.town))
    end
    if src == "recover" then
        return getText("IGUI_StoryEngine_QTitle_recover", tostring(q.origin.dead or "?"), UI.townName(q.town))
    end
    if q.work then
        local key = "IGUI_StoryEngine_Work_Title_" .. tostring(q.work.how) .. (q.work.stage and ("_" .. q.work.stage) or "")
        local title = getText(key, UI.npcName(q.work.faction))
        if q.town then title = title .. " - " .. UI.townName(q.town) end
        return title
    end
    if q.op then
        local title = opActName(q.op)
        if q.town and q.kind ~= "collect" then title = title .. " - " .. UI.townName(q.town) end
        return title
    end
    if q.saga then
        local title = getText("IGUI_StoryEngine_SagaRole_" .. tostring(q.saga.role))
        if q.town and q.kind ~= "collect" then title = title .. " - " .. UI.townName(q.town) end
        return title
    end
    if q.kind == "market" then
        return getText(q.selling and "IGUI_StoryEngine_QTitle_market_sell" or "IGUI_StoryEngine_QTitle_market",
            StoryEngine.intToString(#(q.offers or {})))
    end
    if q.kind == "choice" then
        return getText("IGUI_StoryEngine_QTitle_choice", getText("IGUI_StoryEngine_Crisis_" .. tostring(q.crisis) .. "_title"))
    end
    if q.kind == "horde" then
        return getText("IGUI_StoryEngine_QTitle_horde", UI.townName(q.town))
    end
    if q.kind == "trade" then
        return getText("IGUI_StoryEngine_QTitle_trade", UI.itemList(q.goods))
    end
    if q.kind == "deliver" then
        return getText("IGUI_StoryEngine_QTitle_deliver", UI.needText(q.need))
    end
    if q.kind == "extort" then
        local fid = q.origin and q.origin.faction
        return getText("IGUI_StoryEngine_QTitle_extort", fid and Factions.byId[fid] and Factions.name(fid) or "?")
    end
    local town = UI.townName(q.town)
    if q.kind == "fetch" then
        return getText("IGUI_StoryEngine_QTitle_fetch", UI.itemList({ (q.items or {})[1] }), town)
    end
    if q.origin and q.origin.source == "reward" then
        return getText("IGUI_StoryEngine_QTitle_reward", town)
    end
    if q.origin and q.origin.source == "rescue" then
        return getText("IGUI_StoryEngine_QTitle_rescue", town)
    end
    return getText("IGUI_StoryEngine_QTitle_supply_drop", town)
end

local function questColor(q)
    if q.state == "completed" then return COLOR_DONE end
    if q.state == "failed" then return COLOR_FAILED end
    if q.state == "proposed" then return COLOR_PROPOSED end
    if q.state == "declined" then return COLOR_DECLINED end
    return nil
end

local function questSub(q)
    local fid = q.origin and q.origin.faction
    local who = fid and Factions.byId[fid] and Factions.name(fid) or getText("IGUI_StoryEngine_Quest_Unknown")
    if q.kind == "market" then who = getText("IGUI_StoryEngine_Market_Channel") end
    local sub = who .. "  -  " .. tostring(q.origin and q.origin.date or "")
    if q.kind == "choice" or q.story == "crisis" then
        sub = getText("IGUI_StoryEngine_Quest_CrisisTag") .. " " .. sub
    elseif q.story == "story" then
        sub = getText("IGUI_StoryEngine_Quest_StoryTag") .. " " .. sub
    end
    if q.urgent then sub = getText("IGUI_StoryEngine_Quest_UrgentTag") .. " " .. sub end
    if q.op then
        sub = getText("IGUI_StoryEngine_Op_Tag") .. " " .. getText("IGUI_StoryEngine_Op_Header", opName(q.op),
            StoryEngine.intToString(q.op.act or 1), StoryEngine.intToString(q.op.acts or 5))
    end
    if q.saga then
        sub = getText("IGUI_StoryEngine_Saga_Tag") .. " " .. sagaName(q.saga) .. " - " .. sagaStageName(q.saga)
    end
    if q.work then sub = getText("IGUI_StoryEngine_Work_Tag") .. " " .. sub end
    if q.holiday then sub = getText("IGUI_StoryEngine_Holiday_Tag") .. " " .. sub end
    if q.favorCall then sub = getText("IGUI_StoryEngine_Work_FavorTag") .. " " .. sub end
    -- 다른 사람이 받은 퀘스트는 누가 받았는지 붙인다 (퀘스트는 서버 전체가 함께 본다)
    if q.owner and not q.mine then sub = sub .. "  -  " .. tostring(q.owner) end
    return sub
end

local function deliverDetail(q)
    local parts = {}
    local origin = q.origin or {}
    local fid = origin.faction
    local who = fid and Factions.byId[fid] and Factions.name(fid) or getText("IGUI_StoryEngine_Quest_Unknown")
    local line = function(text) parts[#parts + 1] = " <LINE> " .. UI.escape(text) end
    parts[#parts + 1] = " <H2> " .. UI.escape(questTitle(q))
    if q.state == "completed" then
        parts[#parts + 1] = " <LINE> <RGB:0.45,0.9,0.45> " .. UI.escape(getText("IGUI_StoryEngine_Quest_Result_completed"))
    elseif q.state == "failed" then
        parts[#parts + 1] = " <LINE> <RGB:0.95,0.4,0.35> " .. UI.escape(getText("IGUI_StoryEngine_Quest_Result_failed_" .. q.kind))
    elseif q.state == "declined" then
        parts[#parts + 1] = " <LINE> <RGB:0.6,0.6,0.6> " .. UI.escape(getText("IGUI_StoryEngine_Quest_Result_declined"))
    end
    parts[#parts + 1] = " <LINE> <TEXT> " .. UI.escape(getText("IGUI_StoryEngine_Quest_From_" .. q.kind, who,
        tostring(origin.date or "?"), tostring(origin.clock or "")))
    if q.state == "proposed" then
        line(getText("IGUI_StoryEngine_Quest_Goal_proposed"))
    elseif q.state == "accepted" then
        line(getText("IGUI_StoryEngine_Quest_Goal_" .. q.kind))
    end
    parts[#parts + 1] = " <LINE> "
    local p = player()
    for _, n in ipairs(q.need or {}) do
        local cat = UI.pointCat(n)
        if cat then
            line(getText("IGUI_StoryEngine_Quest_NeedPoints", UI.pointText(cat, n[2], n[3]),
                StoryEngine.intToString(math.floor(UI.pointsHeld(p, cat, n[3])))))
        else
            local name = getItemNameFromFullType(n[1]) or n[1]
            line(getText("IGUI_StoryEngine_Quest_NeedHave", name, StoryEngine.intToString(n[2] or 1),
                StoryEngine.intToString(UI.countHeld(p, n[1]))))
        end
    end
    local rewardTier = q.kind == "extort" and 1 or (q.tier or 1)
    line(getText("IGUI_StoryEngine_Quest_Reward", getText("IGUI_StoryEngine_Quest_Tier_" .. tostring(rewardTier))))
    if q.state == "proposed" then
        line(getText("IGUI_StoryEngine_Quest_RespondBy", StoryEngine.intToString(q.respondHours or 0)))
    elseif q.state == "accepted" then
        line(getText("IGUI_StoryEngine_Quest_Deadline", StoryEngine.intToString(q.hoursLeft or 0)))
    end
    return table.concat(parts)
end

local function tradeDetail(q)
    local parts = {}
    local origin = q.origin or {}
    local fid = origin.faction
    local who = fid and Factions.byId[fid] and Factions.name(fid) or getText("IGUI_StoryEngine_Quest_Unknown")
    local line = function(text) parts[#parts + 1] = " <LINE> " .. UI.escape(text) end
    parts[#parts + 1] = " <H2> " .. UI.escape(questTitle(q))
    if q.state == "completed" then
        parts[#parts + 1] = " <LINE> <RGB:0.45,0.9,0.45> " .. UI.escape(getText("IGUI_StoryEngine_Trade_Result_completed"))
    elseif q.state == "failed" then
        parts[#parts + 1] = " <LINE> <RGB:0.95,0.4,0.35> " .. UI.escape(getText("IGUI_StoryEngine_Trade_Result_failed"))
    elseif q.state == "declined" then
        parts[#parts + 1] = " <LINE> <RGB:0.6,0.6,0.6> " .. UI.escape(getText(q.withdrawn
            and "IGUI_StoryEngine_Trade_Result_withdrawn" or "IGUI_StoryEngine_Quest_Result_declined"))
    end
    parts[#parts + 1] = " <LINE> <TEXT> " .. UI.escape(getText("IGUI_StoryEngine_Quest_From_trade", who,
        tostring(origin.date or "?"), tostring(origin.clock or "")))
    if q.state == "proposed" then
        line(getText("IGUI_StoryEngine_Trade_Goal_proposed"))
        if (q.haggleLeft or 0) > 0 then
            line(getText("IGUI_StoryEngine_Trade_Goal_haggle", StoryEngine.intToString(q.haggleLeft)))
        else
            line(getText("IGUI_StoryEngine_Trade_Goal_noHaggle"))
        end
    elseif q.state == "accepted" and q.payKind and q.payKind ~= "credit" then
        line(getText("IGUI_StoryEngine_Work_Goal_trade", getText("IGUI_StoryEngine_Work_" .. tostring(q.payKind))))
    elseif q.state == "accepted" and q.credit then
        line(getText("IGUI_StoryEngine_Work_Goal_credit"))
    elseif q.state == "accepted" then
        line(getText("IGUI_StoryEngine_Trade_Goal_pay"))
    end
    if q.workOptions then line(getText("IGUI_StoryEngine_Work_Hint")) end
    if q.favor then line(getText("IGUI_StoryEngine_Work_FavorOwed")) end
    parts[#parts + 1] = " <LINE> "
    line(getText("IGUI_StoryEngine_Trade_Goods", UI.itemList(q.goods)))
    if q.workBonus and #q.workBonus > 0 then line(getText("IGUI_StoryEngine_Work_Bonus", UI.itemList(q.workBonus))) end
    if q.parcelEnd and q.parcelEnd < 100 then
        line(getText("IGUI_StoryEngine_Work_ParcelKept", StoryEngine.intToString(math.floor(q.parcelEnd)),
            UI.itemList(q.goodsKept or {})))
    end
    line(getText("IGUI_StoryEngine_Trade_Price", catName(q.payCategory), StoryEngine.intToString(q.price or 0),
        StoryEngine.intToString(payableValue(q))))
    if q.basePrice and q.basePrice ~= q.price then
        line(getText("IGUI_StoryEngine_Trade_BasePrice", StoryEngine.intToString(q.basePrice)))
    end
    if q.state == "proposed" then
        line(getText("IGUI_StoryEngine_Quest_RespondBy", StoryEngine.intToString(q.respondHours or 0)))
    elseif q.state == "accepted" then
        line(getText("IGUI_StoryEngine_Quest_Deadline", StoryEngine.intToString(q.hoursLeft or 0)))
    end
    return table.concat(parts)
end

-- 아는 얼굴의 좀비 (Named.lua)
namedDetail = function(q)
    local parts = {}
    local origin = q.origin or {}
    local fid = origin.faction
    local who = fid and Factions.byId[fid] and Factions.name(fid) or getText("IGUI_StoryEngine_Quest_Unknown")
    local line = function(text) parts[#parts + 1] = " <LINE> " .. UI.escape(text) end
    local active = ACTIVE[q.state] == true
    local name = getText("IGUI_StoryEngine_Named_" .. tostring(q.person) .. "_name")
    local keep = UI.itemList(q.items or {})
    parts[#parts + 1] = " <H2> " .. UI.escape(questTitle(q))
    if q.state == "completed" then
        parts[#parts + 1] = " <LINE> <RGB:0.45,0.9,0.45> " .. UI.escape(getText("IGUI_StoryEngine_Quest_Result_completed"))
    elseif q.state == "failed" then
        parts[#parts + 1] = " <LINE> <RGB:0.95,0.4,0.35> " .. UI.escape(getText("IGUI_StoryEngine_Quest_Result_failed"))
    elseif q.state == "declined" then
        parts[#parts + 1] = " <LINE> <RGB:0.6,0.6,0.6> " .. UI.escape(getText("IGUI_StoryEngine_Quest_Result_declined"))
    end
    parts[#parts + 1] = " <LINE> <RGB:0.95,0.75,0.4> " .. UI.escape(who .. "  -  " .. tostring(origin.date or ""))
    parts[#parts + 1] = " <LINE> <TEXT> " .. UI.escape(getText("IGUI_StoryEngine_Named_" .. tostring(q.person) .. "_desc"))
    parts[#parts + 1] = " <LINE> "
    if q.state == "proposed" then
        line(getText("IGUI_StoryEngine_Quest_Goal_proposed"))
    elseif active and q.slain then
        parts[#parts + 1] = " <LINE> <RGB:0.5,0.9,0.6> " .. UI.escape(getText("IGUI_StoryEngine_Named_Slain", name, keep))
    elseif active then
        line(getText("IGUI_StoryEngine_Named_Goal", name, keep))
    end
    line(getText("IGUI_StoryEngine_Quest_Location", UI.townName(q.town)))
    local p = player()
    if p and active and q.x then
        local x, y = StoryEngine.QuestMap.markerPos(q)
        local dir, dist = UI.distanceText(p, x, y)
        line(getText("IGUI_StoryEngine_Quest_Direction", dir, dist))
    end
    if q.state == "proposed" then
        line(getText("IGUI_StoryEngine_Quest_RespondBy", StoryEngine.intToString(q.respondHours or 0)))
    elseif active then
        line(getText("IGUI_StoryEngine_Quest_Deadline", StoryEngine.intToString(q.hoursLeft or 0)))
    end
    return table.concat(parts)
end

local function hordeDetail(q)
    local parts = {}
    local origin = q.origin or {}
    local fid = origin.faction
    local who = fid and Factions.byId[fid] and Factions.name(fid) or getText("IGUI_StoryEngine_Quest_Unknown")
    local line = function(text) parts[#parts + 1] = " <LINE> " .. UI.escape(text) end
    parts[#parts + 1] = " <H2> " .. UI.escape(questTitle(q))
    if q.state == "completed" then
        parts[#parts + 1] = " <LINE> <RGB:0.45,0.9,0.45> " .. UI.escape(getText("IGUI_StoryEngine_Horde_Result_completed"))
    elseif q.state == "failed" then
        parts[#parts + 1] = " <LINE> <RGB:0.95,0.4,0.35> " .. UI.escape(getText("IGUI_StoryEngine_Horde_Result_failed"))
    elseif q.state == "declined" then
        parts[#parts + 1] = " <LINE> <RGB:0.6,0.6,0.6> " .. UI.escape(getText("IGUI_StoryEngine_Quest_Result_declined"))
    end
    parts[#parts + 1] = " <LINE> <TEXT> " .. UI.escape(getText("IGUI_StoryEngine_Quest_From_horde", who,
        tostring(origin.date or "?"), tostring(origin.clock or "")))
    if q.state == "proposed" then
        line(getText("IGUI_StoryEngine_Horde_Goal_proposed"))
    elseif q.state == "accepted" then
        line(getText("IGUI_StoryEngine_Horde_Goal"))
    end
    line(getText("IGUI_StoryEngine_Quest_Reward", getText("IGUI_StoryEngine_Quest_Tier_" .. tostring(q.tier or 1))))
    parts[#parts + 1] = " <LINE> "
    local where = getText("IGUI_StoryEngine_Quest_Location", UI.townName(q.town))
    if q.landmark then where = where .. "  (" .. getText("IGUI_StoryEngine_Quest_Landmark", q.landmark) .. ")" end
    line(where)
    local p = player()
    if p and (q.state == "proposed" or q.state == "accepted") and q.x then
        local x, y = StoryEngine.QuestMap.markerPos(q)
        local dir, dist = UI.distanceText(p, x, y)
        line(getText("IGUI_StoryEngine_Quest_Direction", dir, dist))
    end
    line(getText("IGUI_StoryEngine_Horde_Progress", StoryEngine.intToString(q.killed or 0),
        StoryEngine.intToString(q.killsNeeded or 0), StoryEngine.intToString(q.size or 0)))
    if q.state == "proposed" then
        line(getText("IGUI_StoryEngine_Quest_RespondBy", StoryEngine.intToString(q.respondHours or 0)))
    elseif q.state == "accepted" then
        line(getText("IGUI_StoryEngine_Quest_Deadline", StoryEngine.intToString(q.hoursLeft or 0)))
    end
    return table.concat(parts)
end

-- 퀘스트 장소 근처에서 싸운 기록 한 줄
local function fightLine(q)
    local f = q.fight
    if not f or ((f.kills or 0) == 0 and (f.hurt or 0) == 0) then return "" end
    local key = f.bitten and "IGUI_StoryEngine_Quest_Fight_bitten" or "IGUI_StoryEngine_Quest_Fight"
    return " <LINE> <RGB:0.95,0.7,0.45> " .. UI.escape(getText(key, StoryEngine.intToString(f.kills or 0),
        StoryEngine.intToString(f.hurt or 0)))
end

local questDetailBase

-- 참여한 사람 한 줄
local function helpersLine(q)
    local names = {}
    for _, name in pairs(q.helpers or {}) do names[#names + 1] = tostring(name) end
    if #names == 0 then return "" end
    table.sort(names)
    return " <LINE> <RGB:0.6,0.8,1> " .. UI.escape(getText("IGUI_StoryEngine_Quest_Helpers", table.concat(names, ", ")))
end

-- 받은 사람 한 줄 (부탁·제안은 수락한 사람으로 바뀐다)
local function ownerLine(q)
    if not q.owner then return "" end
    return " <LINE> <RGB:0.6,0.8,1> " .. UI.escape(getText("IGUI_StoryEngine_Quest_Owner", tostring(q.owner)))
end

local function questDetail(q)
    return questDetailBase(q) .. ownerLine(q) .. fightLine(q) .. helpersLine(q)
end

-- 위기: 여러 세력이 동시에 부탁, 하나만 고른다
local function choiceDetail(q)
    local parts = {}
    local line = function(text) parts[#parts + 1] = " <LINE> " .. UI.escape(text) end
    parts[#parts + 1] = " <H2> " .. UI.escape(questTitle(q))
    if q.state == "completed" and q.chosen then
        parts[#parts + 1] = " <LINE> <RGB:0.45,0.9,0.45> " .. UI.escape(getText("IGUI_StoryEngine_Crisis_Chosen", Factions.name(q.chosen)))
    elseif q.state == "declined" then
        parts[#parts + 1] = " <LINE> <RGB:0.6,0.6,0.6> " .. UI.escape(getText("IGUI_StoryEngine_Crisis_Ignored"))
    end
    parts[#parts + 1] = " <LINE> <TEXT> " .. UI.escape(getText("IGUI_StoryEngine_Crisis_" .. tostring(q.crisis)))
    if q.state == "proposed" then line(getText("IGUI_StoryEngine_Crisis_Goal")) end
    parts[#parts + 1] = " <LINE> "
    for _, o in ipairs(q.options or {}) do
        local mark = (q.chosen == o.faction) and "> " or "- "
        parts[#parts + 1] = " <LINE> <RGB:0.95,0.75,0.4> " .. UI.escape(mark .. Factions.name(o.faction))
        line(getText("IGUI_StoryEngine_Crisis_" .. tostring(q.crisis) .. "_" .. tostring(o.faction)))
        line(getText("IGUI_StoryEngine_Crisis_Need", UI.needText(o.need)))
    end
    if q.state == "proposed" then
        parts[#parts + 1] = " <LINE> "
        line(getText("IGUI_StoryEngine_Quest_RespondBy", StoryEngine.intToString(q.respondHours or 0)))
    end
    return table.concat(parts)
end

-- 공용 주파수 거래: 여러 NPC 의 제안 중 하나를 고른다
local function marketDetail(q)
    local parts = {}
    local line = function(text) parts[#parts + 1] = " <LINE> " .. UI.escape(text) end
    parts[#parts + 1] = " <H2> " .. UI.escape(questTitle(q))
    if q.state == "completed" and q.chosen then
        parts[#parts + 1] = " <LINE> <RGB:0.45,0.9,0.45> " .. UI.escape(getText("IGUI_StoryEngine_Market_Chosen", Factions.name(q.chosen)))
    elseif q.state == "declined" then
        parts[#parts + 1] = " <LINE> <RGB:0.6,0.6,0.6> " .. UI.escape(getText("IGUI_StoryEngine_Market_Closed"))
    end
    if q.state == "proposed" then
        parts[#parts + 1] = " <LINE> <TEXT> " .. UI.escape(getText(q.selling and "IGUI_StoryEngine_Market_GoalSell"
            or "IGUI_StoryEngine_Market_Goal"))
    end
    parts[#parts + 1] = " <LINE> "
    for _, o in ipairs(q.offers or {}) do
        local mark = (q.chosen == o.faction) and "> " or "- "
        parts[#parts + 1] = " <LINE> <RGB:0.95,0.75,0.4> " .. UI.escape(mark .. Factions.name(o.faction))
        line(getText("IGUI_StoryEngine_Market_Offer", UI.itemList(o.goods or {}), catName(o.payCategory),
            StoryEngine.intToString(o.price or 0)))
        if o.bonus then line(getText("IGUI_StoryEngine_Market_Bonus")) end
    end
    if q.state == "proposed" then
        parts[#parts + 1] = " <LINE> "
        line(getText("IGUI_StoryEngine_Quest_RespondBy", StoryEngine.intToString(q.respondHours or 0)))
    end
    return table.concat(parts)
end

-- 복구 작전·큰 사건 퀘스트 (회수·보급·모금·소탕·방어·방문)
local function opDetail(q)
    local parts = {}
    local line = function(text) parts[#parts + 1] = " <LINE> " .. UI.escape(text) end
    local active = ACTIVE[q.state] == true
    local header
    if q.holiday then
        header = getText("IGUI_StoryEngine_Holiday_Header", getText("IGUI_StoryEngine_Holiday_" .. tostring(q.holiday)))
    elseif q.work then
        header = getText("IGUI_StoryEngine_Work_Header", Factions.name(q.work.faction),
            getText("IGUI_StoryEngine_Work_" .. tostring(q.work.how)))
    elseif q.op then
        header = getText("IGUI_StoryEngine_Op_Header", opName(q.op), StoryEngine.intToString(q.op.act or 1),
            StoryEngine.intToString(q.op.acts or 5))
    else
        header = getText("IGUI_StoryEngine_Saga_Header", sagaName(q.saga), StoryEngine.intToString(q.saga.stage or 1),
            StoryEngine.intToString(q.saga.stages or 3), sagaStageName(q.saga))
    end
    parts[#parts + 1] = " <H2> " .. UI.escape(questTitle(q))
    if q.state == "completed" then
        parts[#parts + 1] = " <LINE> <RGB:0.45,0.9,0.45> " .. UI.escape(getText("IGUI_StoryEngine_Quest_Result_completed"))
    elseif q.state == "failed" then
        parts[#parts + 1] = " <LINE> <RGB:0.95,0.4,0.35> " .. UI.escape(getText("IGUI_StoryEngine_Quest_Result_failed"))
    elseif q.state == "declined" then
        parts[#parts + 1] = " <LINE> <RGB:0.6,0.6,0.6> " .. UI.escape(getText("IGUI_StoryEngine_Op_Cancelled"))
    end
    parts[#parts + 1] = " <LINE> <RGB:0.95,0.75,0.4> " .. UI.escape(header)
    if q.saga then
        parts[#parts + 1] = " <LINE> <TEXT> " .. UI.escape(getText("IGUI_StoryEngine_SagaRole_" .. tostring(q.saga.role) .. "_desc"))
    end
    if q.op and (q.op.retry or 0) > 0 then
        parts[#parts + 1] = " <LINE> <RGB:0.95,0.6,0.35> " .. UI.escape(getText("IGUI_StoryEngine_Op_Retry",
            StoryEngine.intToString(q.op.retry)))
    end
    parts[#parts + 1] = " <TEXT> "
    if active then
        local goal = "IGUI_StoryEngine_Op_Goal_" .. q.kind
        if q.kind == "supply_drop" then goal = "IGUI_StoryEngine_Quest_Goal_supply_drop" end
        if q.work then
            goal = "IGUI_StoryEngine_Work_Goal_" .. tostring(q.work.how) .. (q.work.stage and ("_" .. q.work.stage) or "")
        end
        if q.holiday and q.kind == "collect" then goal = "IGUI_StoryEngine_Holiday_CollectGoal" end
        line(getText(goal, StoryEngine.intToString(q.radius or 0)))
    end
    parts[#parts + 1] = " <LINE> "
    if q.kind ~= "collect" then
        local where = getText("IGUI_StoryEngine_Quest_Location", UI.townName(q.town))
        if q.site then where = where .. "  (" .. getText("IGUI_StoryEngine_Op_Site_" .. tostring(q.site)) .. ")" end
        line(where)
        local p = player()
        if p and active and q.x then
            local x, y = StoryEngine.QuestMap.markerPos(q)
            local dir, dist = UI.distanceText(p, x, y)
            line(getText("IGUI_StoryEngine_Quest_Direction", dir, dist))
        end
    end
    if q.kind == "fetch" then
        if active and q.state ~= "retrieved" then
            if q.spawned and q.container then
                line(getText("IGUI_StoryEngine_Quest_Storage", UI.containerName(q.container)))
                line(getText("IGUI_StoryEngine_Quest_Storage_Highlight"))
            elseif q.spawned then
                line(getText("IGUI_StoryEngine_Quest_Storage_Floor"))
            else
                line(getText("IGUI_StoryEngine_Quest_Storage_Unknown"))
            end
        end
        line(getText("IGUI_StoryEngine_Quest_Target", UI.itemList(q.items)))
    elseif q.kind == "supply_drop" then
        if active and q.spawned and q.container then
            line(getText("IGUI_StoryEngine_Quest_Storage", UI.containerName(q.container)))
            line(getText("IGUI_StoryEngine_Quest_Storage_Highlight"))
        elseif active and q.spawned then
            line(getText("IGUI_StoryEngine_Quest_Storage_Floor"))
        elseif active then
            line(getText("IGUI_StoryEngine_Quest_Storage_Unknown"))
        end
        line(getText("IGUI_StoryEngine_Quest_Items", UI.itemList(q.items)))
    elseif q.kind == "collect" then
        local p = player()
        for _, n in ipairs(q.need or {}) do
            local name = getItemNameFromFullType(n[1]) or n[1]
            line(getText("IGUI_StoryEngine_Op_Need", name, StoryEngine.intToString((q.got or {})[n[1]] or 0),
                StoryEngine.intToString(n[2] or 1), StoryEngine.intToString(UI.countHeld(p, n[1]))))
        end
        local givers = {}
        for name, count in pairs(q.givers or {}) do givers[#givers + 1] = tostring(name) .. " " .. StoryEngine.intToString(count) end
        table.sort(givers)
        if #givers > 0 then line(getText("IGUI_StoryEngine_Op_Givers", table.concat(givers, ", "))) end
    elseif q.kind == "horde" then
        line(getText("IGUI_StoryEngine_Horde_Progress", StoryEngine.intToString(q.killed or 0),
            StoryEngine.intToString(q.killsNeeded or 0), StoryEngine.intToString(q.size or 0)))
    elseif q.kind == "defend" then
        line(getText("IGUI_StoryEngine_Op_Progress", string.format("%.1f", (q.progress or 0) / 60),
            StoryEngine.intToString(math.floor((q.needMin or 0) / 60))))
        line(getText("IGUI_StoryEngine_Op_Waves", StoryEngine.intToString(q.waves or 0)))
    elseif q.kind == "scout" then
        line(getText("IGUI_StoryEngine_Work_ScoutPoint", StoryEngine.intToString(q.point or 1),
            StoryEngine.intToString(q.points or 1)))
        line(getText(q.entered and "IGUI_StoryEngine_Work_ScoutEntered" or "IGUI_StoryEngine_Work_ScoutNotEntered"))
        line(getText("IGUI_StoryEngine_Work_ScoutStay", StoryEngine.intToString(math.floor(q.progress or 0)),
            StoryEngine.intToString(q.needMin or 0)))
        if q.night then
            line(getText(q.waitNight and "IGUI_StoryEngine_Work_ScoutNightWait" or "IGUI_StoryEngine_Work_ScoutNight"))
        end
    end
    if q.parcel then
        line(getText("IGUI_StoryEngine_Work_Parcel", StoryEngine.intToString(math.floor(q.parcel))))
    end
    if active then
        line(getText("IGUI_StoryEngine_Quest_Deadline", StoryEngine.intToString(q.hoursLeft or 0)))
    end
    return table.concat(parts)
end

questDetailBase = function(q)
    if q.op or q.saga or q.work or q.holiday then return opDetail(q) end
    if q.kind == "named" then return namedDetail(q) end
    if q.kind == "choice" then return choiceDetail(q) end
    if q.kind == "market" then return marketDetail(q) end
    if q.kind == "horde" then return hordeDetail(q) end
    if q.kind == "trade" then return tradeDetail(q) end
    if q.kind == "deliver" or q.kind == "extort" then return deliverDetail(q) end
    local parts = {}
    local active = ACTIVE[q.state] == true
    local origin = q.origin or {}
    local fid = origin.faction
    local who = fid and Factions.byId[fid] and Factions.name(fid) or getText("IGUI_StoryEngine_Quest_Unknown")
    local line = function(text) parts[#parts + 1] = " <LINE> " .. UI.escape(text) end

    parts[#parts + 1] = " <H2> " .. UI.escape(questTitle(q))
    if q.state == "completed" then
        parts[#parts + 1] = " <LINE> <RGB:0.45,0.9,0.45> " .. UI.escape(getText("IGUI_StoryEngine_Quest_Result_completed"))
    elseif q.state == "failed" then
        parts[#parts + 1] = " <LINE> <RGB:0.95,0.4,0.35> " .. UI.escape(getText("IGUI_StoryEngine_Quest_Result_failed"))
    end

    -- 경위와 할 일
    local fromKey = "IGUI_StoryEngine_Quest_From_" .. ((origin.source == "reward" or origin.source == "rescue"
        or origin.source == "gift_trade") and origin.source or q.kind)
    if origin.friend then fromKey = "IGUI_StoryEngine_Quest_From_friend" end
    if origin.source == "reward" and q.rewardKind then
        local byKind = fromKey .. "_" .. q.rewardKind
        if getTextOrNull(byKind) then fromKey = byKind end
    end
    if not origin.faction then fromKey = "IGUI_StoryEngine_Quest_From_debug" end
    parts[#parts + 1] = " <LINE> <TEXT> " .. UI.escape(getText(fromKey, who,
        tostring(origin.date or "?"), tostring(origin.clock or "")))
    if active then
        line(getText("IGUI_StoryEngine_Quest_Goal_" .. (origin.source == "rescue" and "rescue" or q.kind)))
    end
    if q.kind == "fetch" then
        line(getText("IGUI_StoryEngine_Quest_Reward", getText("IGUI_StoryEngine_Quest_Tier_" .. tostring(q.tier or 1))))
    end
    parts[#parts + 1] = " <LINE> "

    -- 위치와 물건
    local where = getText("IGUI_StoryEngine_Quest_Location", UI.townName(q.town))
    if q.landmark then where = where .. "  (" .. getText("IGUI_StoryEngine_Quest_Landmark", q.landmark) .. ")" end
    line(where)
    local p = player()
    if p and active then
        local x, y = StoryEngine.QuestMap.markerPos(q)
        local dir, dist = UI.distanceText(p, x, y)
        line(getText("IGUI_StoryEngine_Quest_Direction", dir, dist))
    end
    local rooms = table.concat(q.rooms or {}, ", ")
    line(q.residential and getText("IGUI_StoryEngine_Quest_House", rooms) or getText("IGUI_StoryEngine_Quest_Building", rooms))
    if active and q.state ~= "retrieved" then
        if q.spawned and q.container then
            line(getText("IGUI_StoryEngine_Quest_Storage", UI.containerName(q.container)))
            line(getText("IGUI_StoryEngine_Quest_Storage_Highlight"))
        elseif q.spawned then
            line(getText("IGUI_StoryEngine_Quest_Storage_Floor"))
        else
            line(getText("IGUI_StoryEngine_Quest_Storage_Unknown"))
        end
    end
    if q.kind == "fetch" then
        line(getText("IGUI_StoryEngine_Quest_Target", UI.itemList(q.items)))
    else
        line(getText("IGUI_StoryEngine_Quest_Items", UI.itemList(q.items)))
    end
    if active then
        line(getText("IGUI_StoryEngine_Quest_Deadline", StoryEngine.intToString(q.hoursLeft or 0)))
    end
    return table.concat(parts)
end

function StoryEngineQuestPanel:refresh()
    self.list:clear()
    -- 묶음별 개수. 처음 열면 진행 중 > 수락 대기 > 완료 > 실패 순으로 퀘스트가 있는 묶음
    local counts = {}
    for _, q in ipairs(Cache.quests) do
        local g = questGroup(q)
        counts[g] = (counts[g] or 0) + 1
    end
    if not Cache.questGroup then
        for _, g in ipairs({ "active", "proposed", "completed", "failed" }) do
            if not Cache.questGroup and (counts[g] or 0) > 0 then Cache.questGroup = g end
        end
        Cache.questGroup = Cache.questGroup or "active"
    end
    for g, b in pairs(self.groupButtons or {}) do
        b:setTitle(getText("IGUI_StoryEngine_QGroup_" .. g, StoryEngine.intToString(counts[g] or 0)))
        if g == Cache.questGroup then
            b.backgroundColor = { r = 0.25, g = 0.4, b = 0.25, a = 1 }
        else
            b.backgroundColor = { r = 0, g = 0, b = 0, a = 1 }
        end
    end
    local shown = {}
    for _, q in ipairs(Cache.quests) do
        if questGroup(q) == Cache.questGroup then shown[#shown + 1] = q end
    end
    local selected, selectedIndex = nil, nil
    for i, q in ipairs(shown) do
        self.list:addItem(questTitle(q), { title = questTitle(q), sub = questSub(q), color = questColor(q), value = q })
        if q.id == Cache.questId then selected, selectedIndex = q, i end
    end
    if not selected and #shown > 0 then
        selected, selectedIndex = shown[1], 1
        Cache.questId = selected.id
    end
    self.list.selected = selectedIndex or 0
    if selected then
        self.detail:setText(questDetail(selected))
    else
        self.detail:setText(" <TEXT> " .. UI.escape(getText(#Cache.quests > 0 and "IGUI_StoryEngine_Quest_EmptyGroup"
            or "IGUI_StoryEngine_Quest_Empty")))
    end
    self.detail:paginate()
    self.detail:setYScroll(0)
    local active = selected ~= nil and ACTIVE[selected.state] == true
    local proposed = selected ~= nil and selected.state == "proposed"
    local located = selected ~= nil and selected.kind ~= "deliver" and selected.kind ~= "trade" and selected.kind ~= "extort"
        and selected.kind ~= "choice" and selected.kind ~= "collect" and selected.kind ~= "market"
    self.mapButton:setVisible(located)
    self.mapButton:setEnable(active)
    -- 위기 선택지와 공용 주파수 거래 제안은 같은 버튼 줄을 쓴다
    local market = selected ~= nil and selected.kind == "market"
    local options = selected and (market and selected.offers or selected.options) or nil
    local choosing = proposed and (selected.kind == "choice" or market)
    self.acceptButton:setVisible(proposed and not choosing)
    self.declineButton:setVisible(proposed and not choosing)
    local canWork = selected ~= nil and selected.kind == "trade" and selected.workOptions ~= nil
        and (proposed or (selected.state == "accepted" and not selected.payKind))
    -- 선택지 버튼: 오른쪽 칸 너비를 나눠 쓰고, 이름은 괄호(거점) 없이 짧게, 전체 이름은 툴팁으로
    local count = 0
    for i = 1, #(self.choiceButtons or {}) do
        if choosing and options and options[i] then count = i end
    end
    local left = self.detail:getX()
    local bw = count > 0 and math.floor((self.width - left - PAD - PAD * (count - 1)) / count) or 0
    for i, b in ipairs(self.choiceButtons or {}) do
        local opt = choosing and options and options[i] or nil
        b:setVisible(opt ~= nil)
        if opt then
            local full = Factions.name(opt.faction)
            local short = full
            local cut = string.find(full, " (", 1, true)
            if cut and cut > 1 then short = string.sub(full, 1, cut - 1) end
            b:setX(left + (i - 1) * (bw + PAD))
            b:setWidth(bw)
            local key = market and "IGUI_StoryEngine_Market_Choose" or "IGUI_StoryEngine_Crisis_Choose"
            b:setTitle(fit(getText(key, short), bw - 12))
            b.tooltip = getText(key, full)
        end
    end
    local canSubmit = selected ~= nil and active
        and (selected.kind == "fetch" or selected.kind == "deliver" or selected.kind == "trade" or selected.kind == "extort"
            or selected.kind == "collect" or selected.kind == "named")
    -- 배달 대행 꾸러미는 무전으로 내지 않고 배달지로 가져간다 / 일로 갚는 거래는 물건으로 내지 않는다
    if canSubmit and selected.work and selected.work.how == "courier" then canSubmit = false end
    if canSubmit and selected.kind == "trade" and selected.payKind and selected.payKind ~= "credit" then canSubmit = false end
    self.submitButton:setVisible(canSubmit)
    if canSubmit then
        self.submitButton:setTitle(getText((selected.kind == "trade" and "IGUI_StoryEngine_Trade_PayButton")
            or (selected.kind == "collect" and "IGUI_StoryEngine_Op_Send") or "IGUI_StoryEngine_Quest_Submit"))
    end
    if canSubmit then
        -- 부탁 퀘스트는 지도 버튼이 없으니 제출 버튼을 왼쪽으로
        self.submitButton:setX(located and (self.mapButton:getRight() + PAD) or self.mapButton:getX())
    end
    self.submitButton:setEnable(selected ~= nil and (selected.kind == "trade" or holdsQuestItem(selected)))
    self.workButton:setVisible(canWork)
    if canWork then
        local after = (proposed and self.declineButton) or (canSubmit and self.submitButton) or nil
        self.workButton:setX(after and (after:getRight() + PAD) or self.detail:getX())
    end
end

-- ================================================================ journal tab

StoryEngineJournalPanel = derivePanel("StoryEngineJournalPanel")

function StoryEngineJournalPanel:createChildren()
    -- 왼쪽: 일지를 쓴 사람들 (나, 접속 중, 그 외 순), 오른쪽: 고른 사람의 일지
    self.list = newList(PAD, PAD, LIST_W, self.height - PAD * 2, self, StoryEngineJournalPanel.onSelect)
    self.list:setAnchorBottom(true)
    self:addChild(self.list)

    local x = PAD * 2 + LIST_W
    self.text = newRichText(x, PAD, self.width - x - PAD, self.height - PAD * 2)
    self.text:setAnchorRight(true)
    self.text:setAnchorBottom(true)
    self:addChild(self.text)
end

-- 목록 값: 일지 = 캐릭터 키, 회고록 = "m:" .. 키
function StoryEngineJournalPanel:onSelect(value)
    if not value then return end
    local memoir = string.sub(value, 1, 2) == "m:"
    local key = memoir and string.sub(value, 3) or value
    if key == Cache.journalKey and memoir == (Cache.journalMemoir == true) then return end
    Cache.journalKey, Cache.journalMemoir = key, memoir
    Cache.journal, Cache.journalComments = {}, {}
    request("journalList", { key = key, memoir = memoir or nil })
    self:refresh()
end

local function authorSub(a)
    local parts = {}
    if a.key == Cache.journalOwn then parts[#parts + 1] = getText("IGUI_StoryEngine_Journal_Me") end
    if a.dead then
        parts[#parts + 1] = getText("IGUI_StoryEngine_Journal_Dead")
    elseif a.online then
        parts[#parts + 1] = getText("IGUI_StoryEngine_Journal_Online")
    end
    parts[#parts + 1] = getText("IGUI_StoryEngine_Journal_Count", StoryEngine.intToString(a.count or 0))
    return table.concat(parts, "  |  ")
end

function StoryEngineJournalPanel:refresh()
    self.list:clear()
    local selectedIndex = 0
    for i, a in ipairs(Cache.journalAuthors or {}) do
        if a.memoir then
            local title = getText("IGUI_StoryEngine_Journal_MemoirOf", tostring(a.name))
            local sub = tostring(a.lastDate or "?") .. "  |  "
                .. getText("IGUI_StoryEngine_Journal_Comments", StoryEngine.intToString(a.count or 0))
            self.list:addItem(title, { title = title, sub = sub, value = "m:" .. a.key, color = COLOR_MEMOIR })
            if Cache.journalMemoir and a.key == Cache.journalKey then selectedIndex = i end
        else
            local color = nil
            if a.dead then color = COLOR_DECLINED elseif a.key == Cache.journalOwn then color = COLOR_PROPOSED end
            self.list:addItem(tostring(a.name), { title = tostring(a.name), sub = authorSub(a), value = a.key, color = color })
            if not Cache.journalMemoir and a.key == Cache.journalKey then selectedIndex = i end
        end
    end
    self.list.selected = selectedIndex

    if Cache.journalMemoir then
        self:showMemoir()
        return
    end

    local parts = {}
    for _, e in ipairs(Cache.journal) do
        local title = tostring(e.date or "?") .. "  -  D" .. tostring(e.day or "?")
        if e.kind == "memoir" then title = getText("IGUI_StoryEngine_Memoir") .. "  -  " .. title end
        parts[#parts + 1] = " <H2> " .. UI.escape(title)
        if e.fallback then
            parts[#parts + 1] = " <RGB:0.8,0.5,0.3> " .. UI.escape(getText("IGUI_StoryEngine_Offline"))
        end
        parts[#parts + 1] = " <LINE> <TEXT> " .. UI.escape(UI.textOf(e)) .. " <BR> "
    end
    if #parts == 0 then
        parts[1] = " <TEXT> " .. UI.escape(getText("IGUI_StoryEngine_JournalEmpty"))
    end
    self.text:setText(table.concat(parts))
    self.text:paginate()
    self.text:setYScroll(0)
end

-- 회고록 한 편과 그 아래 살아 있는 사람들의 추모
function StoryEngineJournalPanel:showMemoir()
    local parts = {}
    local e = Cache.journal[1]
    parts[#parts + 1] = " <H1> " .. UI.escape(getText("IGUI_StoryEngine_Journal_MemoirOf", tostring(Cache.journalName or "?")))
    if e then
        parts[#parts + 1] = " <LINE> <RGB:0.6,0.6,0.6> " .. UI.escape(tostring(e.date or "?") .. "  -  "
            .. getText("IGUI_StoryEngine_Journal_Survived", StoryEngine.intToString(e.day or 0)))
        parts[#parts + 1] = " <LINE> <TEXT> " .. UI.escape(UI.textOf(e)) .. " <BR> "
    else
        parts[#parts + 1] = " <LINE> <TEXT> " .. UI.escape(getText("IGUI_StoryEngine_Journal_MemoirPending"))
    end
    parts[#parts + 1] = " <LINE> <H2> " .. UI.escape(getText("IGUI_StoryEngine_Journal_Remembered"))
    local comments = Cache.journalComments or {}
    if #comments == 0 then
        parts[#parts + 1] = " <LINE> <RGB:0.6,0.6,0.6> " .. UI.escape(getText("IGUI_StoryEngine_Journal_NoComments"))
    end
    for _, c in ipairs(comments) do
        parts[#parts + 1] = " <LINE> <RGB:0.6,0.8,1> " .. UI.escape(tostring(c.name or "?") .. "  (" .. tostring(c.date or "") .. ")")
        parts[#parts + 1] = " <LINE> <TEXT> " .. UI.escape(tostring(c.text or "")) .. " <BR> "
    end
    self.text:setText(table.concat(parts))
    self.text:paginate()
    self.text:setYScroll(0)
end

-- ================================================================ life tab (거점: NPC 생활 상태)

StoryEngineLifePanel = derivePanel("StoryEngineLifePanel")

local RESOURCES = { "food", "medical", "safety", "morale" }
local BAR_ROW = FONT_H + 8
local LIFE_HEADER_H = LINE_H + PAD + BAR_ROW * 4
local RES_LABEL_W = 90
local DONATE_W = 150
local SPEC_W = 190
local PROJECT_W = 150

local function levelOf(v)
    if v < 20 then return "empty" end
    if v < 40 then return "low" end
    if v < 70 then return "ok" end
    return "plenty"
end

local LEVEL_COLOR = {
    empty = { 0.9, 0.3, 0.25 }, low = { 0.95, 0.6, 0.25 }, ok = { 0.9, 0.8, 0.35 }, plenty = { 0.45, 0.85, 0.45 },
}

local function lifeOf(fid)
    for _, n in ipairs(Cache.life or {}) do
        if n.id == fid then return n end
    end
    return nil
end

-- 목록 둘째 줄: 가장 급한 자원 하나
local function lifeSub(n)
    local low, value = nil, 101
    for _, r in ipairs(RESOURCES) do
        local v = (n.res or {})[r] or 0
        if v < value then low, value = r, v end
    end
    local trust = getText("IGUI_StoryEngine_Life_Trust", StoryEngine.intToString(n.trust or 0))
    if low and value < 40 then
        return trust .. "  |  " .. getText("IGUI_StoryEngine_Life_Res_" .. low) .. " "
            .. getText("IGUI_StoryEngine_Life_Level_" .. levelOf(value))
    end
    return trust .. "  |  " .. getText("IGUI_StoryEngine_Life_Fine")
end

function StoryEngineLifePanel:createChildren()
    local h = self.height
    self.list = newList(PAD, PAD, LIST_W, h - PAD * 2, self, StoryEngineLifePanel.onSelect)
    self.list:setAnchorBottom(true)
    self:addChild(self.list)

    local x = PAD * 2 + LIST_W
    local w = self.width - x - PAD
    self.detail = newRichText(x, PAD + LIFE_HEADER_H + PAD, w, h - LIFE_HEADER_H - PAD * 4 - BUTTON_H)
    self.detail:setAnchorRight(true)
    self.detail:setAnchorBottom(true)
    self:addChild(self.detail)

    self.donateButton = newButton(x, h - PAD - BUTTON_H, DONATE_W, getText("IGUI_StoryEngine_Life_Donate"),
        self, StoryEngineLifePanel.onDonate)
    self:addChild(self.donateButton)
    self.specButton = newButton(x + DONATE_W + PAD, h - PAD - BUTTON_H, SPEC_W, "", self, StoryEngineLifePanel.onSpecialty)
    self:addChild(self.specButton)
    self.projectButton = newButton(x + DONATE_W + SPEC_W + PAD * 2, h - PAD - BUTTON_H, PROJECT_W,
        getText("IGUI_StoryEngine_Project_Button"), self, StoryEngineLifePanel.onProject)
    self:addChild(self.projectButton)
end

function StoryEngineLifePanel:onProject()
    local n = lifeOf(Cache.lifeFaction)
    if n and n.project and StoryEngineDonateWindow then StoryEngineDonateWindow.open(n, "project") end
end

-- 특기 요청. 레이는 보급을 보낼 상대를 고른다
function StoryEngineLifePanel:onSpecialty()
    local n = lifeOf(Cache.lifeFaction)
    if not n then return end
    if n.id ~= "ray" then
        request("specialtyRequest", { faction = n.id })
        return
    end
    local menu = ISContextMenu.get(0, getMouseX(), getMouseY())
    for _, other in ipairs(Cache.life or {}) do
        if other.id ~= "ray" then
            local low, value = nil, 101
            for _, r in ipairs(RESOURCES) do
                local v = (other.res or {})[r] or 0
                if v < value then low, value = r, v end
            end
            local label = Factions.name(other.id)
            if low then
                label = label .. "  (" .. getText("IGUI_StoryEngine_Life_Res_" .. low) .. " "
                    .. StoryEngine.intToString(value) .. ")"
            end
            menu:addOption(label, other.id, function(target)
                request("specialtyRequest", { faction = "ray", target = target })
            end)
        end
    end
end

function StoryEngineLifePanel:onSelect(fid)
    if not fid then return end
    Cache.lifeFaction = fid
    self:refresh()
end

function StoryEngineLifePanel:onDonate()
    local n = lifeOf(Cache.lifeFaction)
    if n and StoryEngineDonateWindow then StoryEngineDonateWindow.open(n) end
end

-- 위쪽: 이름·신뢰도, 자원 막대 4개 (숫자, 어제 대비)
function StoryEngineLifePanel:render()
    ISPanel.render(self)
    local n = lifeOf(Cache.lifeFaction)
    if not n then return end
    local x = self.detail:getX()
    local w = self.detail:getWidth()
    local y = PAD
    self:drawText(Factions.name(n.id), x, y, 1, 0.9, 0.6, 1, UIFont.Small)
    local trust = getText("IGUI_StoryEngine_Life_Trust", StoryEngine.intToString(n.trust or 0))
    local tw = getTextManager():MeasureStringX(UIFont.Small, trust)
    self:drawText(trust, x + w - tw, y, 0.75, 0.85, 0.75, 1, UIFont.Small)
    y = y + LINE_H + PAD
    local barX = x + RES_LABEL_W
    local barW = math.max(40, w - RES_LABEL_W - 110)
    for _, r in ipairs(RESOURCES) do
        local v = (n.res or {})[r] or 0
        local prev = (n.prev or {})[r] or v
        local lvl = levelOf(v)
        local c = LEVEL_COLOR[lvl]
        local label = getText("IGUI_StoryEngine_Life_Res_" .. r)
        if r == n.key then label = label .. " *" end
        self:drawText(label, x, y + 4, 0.85, 0.85, 0.85, 1, UIFont.Small)
        self:drawRect(barX, y + 3, barW, BAR_ROW - 6, 0.6, 0.12, 0.12, 0.12)
        self:drawRect(barX, y + 3, math.floor(barW * v / 100), BAR_ROW - 6, 0.85, c[1], c[2], c[3])
        self:drawRectBorder(barX, y + 3, barW, BAR_ROW - 6, 0.5, 0.5, 0.5, 0.5)
        local diff = v - prev
        local text = StoryEngine.intToString(v) .. "  " .. getText("IGUI_StoryEngine_Life_Level_" .. lvl)
        if diff ~= 0 then text = text .. "  " .. (diff > 0 and "+" or "") .. StoryEngine.intToString(diff) end
        self:drawText(text, barX + barW + 8, y + 4, c[1], c[2], c[3], 1, UIFont.Small)
        y = y + BAR_ROW
    end
    -- 물자 지원 대기
    if not n.fate and (n.donateWait or 0) > 0 then
        self:drawText(getText("IGUI_StoryEngine_Life_DonateWait", StoryEngine.intToString(n.donateWait)),
            self.projectButton:getRight() + PAD, self.donateButton:getY() + (BUTTON_H - FONT_H) / 2, 0.7, 0.7, 0.7, 1, UIFont.Small)
    end
end

local function recordText(e)
    local key = "IGUI_StoryEngine_Life_Rec_" .. tostring(e.kind)
    local text = e.src and getText(key, Factions.name(e.src)) or getText(key)
    if text == key then text = tostring(e.kind) end
    local line = "D" .. StoryEngine.intToString(e.day or 0) .. "  "
    if e.who then
        line = line .. tostring(e.who) .. (e.dead and (" " .. getText("IGUI_StoryEngine_Life_Deceased")) or "") .. ": "
    end
    line = line .. text
    local d = tonumber(e.d) or 0
    if d ~= 0 then line = line .. "  (" .. (d > 0 and "+" or "") .. StoryEngine.intToString(d) .. ")" end
    return line, d
end

function StoryEngineLifePanel:refresh()
    self.list:clear()
    local selectedIndex = 0
    local npcs = Cache.life or {}
    if not lifeOf(Cache.lifeFaction) and npcs[1] then Cache.lifeFaction = npcs[1].id end
    for i, n in ipairs(npcs) do
        local low = false
        for _, r in ipairs(RESOURCES) do
            if ((n.res or {})[r] or 0) < 20 then low = true end
        end
        local sub = n.fate and getText("IGUI_StoryEngine_Fate_" .. tostring(n.fate)) or lifeSub(n)
        local color = low and COLOR_FAILED or nil
        if n.fate then color = COLOR_DECLINED end
        self.list:addItem(Factions.name(n.id), { title = Factions.name(n.id), sub = sub, value = n.id, color = color })
        if n.id == Cache.lifeFaction then selectedIndex = i end
    end
    self.list.selected = selectedIndex

    local n = lifeOf(Cache.lifeFaction)
    self.donateButton:setVisible(n ~= nil)
    self.specButton:setVisible(n ~= nil)
    self.projectButton:setVisible(false)
    if not n then
        self.detail:setText(" <TEXT> " .. UI.escape(getText("IGUI_StoryEngine_Life_Empty")))
        self.detail:paginate()
        return
    end
    local proj = n.project
    self.projectButton:setVisible(proj ~= nil and not proj.done and not n.fate)
    self.projectButton:setEnable((n.donateWait or 0) == 0)
    self.projectButton.tooltip = getText("IGUI_StoryEngine_Project_Tooltip")
    if n.fate then
        self.donateButton:setVisible(false)
        self.specButton:setVisible(false)
    end
    self.donateButton:setEnable((n.donateWait or 0) == 0)
    self.donateButton.tooltip = getText("IGUI_StoryEngine_Life_DonateTooltip")
    -- 특기: 구간 1~3, 막힌 이유는 툴팁으로
    local spec = n.spec or {}
    self.specButton:setVisible(n.spec ~= nil and not n.fate)
    local specName = getText("IGUI_StoryEngine_Spec_Name_" .. n.id)
    local tierText = (spec.tier or 0) > 0 and (" " .. string.rep("*", spec.tier)) or ""
    self.specButton:setTitle(getText("IGUI_StoryEngine_Spec_Button", specName) .. tierText)
    self.specButton:setEnable(spec.reason == nil)
    local tip = getText("IGUI_StoryEngine_Spec_Desc_" .. n.id)
    if spec.reason then
        tip = getText("IGUI_StoryEngine_Spec_Error_" .. tostring(spec.reason), StoryEngine.intToString(spec.wait or 0))
            .. " <LINE> " .. tip
    end
    if spec.scope then tip = tip .. " <LINE> " .. getText("IGUI_StoryEngine_Spec_Scope_" .. tostring(spec.scope)) end
    self.specButton.tooltip = tip

    local parts = {}
    if n.fate then
        parts[#parts + 1] = " <RGB:0.75,0.6,0.9> " .. UI.escape(getText("IGUI_StoryEngine_Fate_Line_" .. tostring(n.fate),
            Factions.name(n.id)) .. "  (D" .. StoryEngine.intToString(n.fateDay or 0) .. ")") .. " <LINE> <LINE> "
    elseif (n.starve or 0) > 0 then
        parts[#parts + 1] = " <RGB:0.95,0.4,0.35> " .. UI.escape(getText("IGUI_StoryEngine_Fate_Starving",
            StoryEngine.intToString(n.starve))) .. " <LINE> <LINE> "
    end
    if n.project then
        local pr = n.project
        local goal = pr.goal or 1000
        local pts = math.min(goal, pr.points or 0)
        local filled = math.floor(pts * 10 / goal)
        local bar = "[" .. string.rep("#", filled) .. string.rep("-", 10 - filled) .. "]"
        local head = getText("IGUI_StoryEngine_Project_Name_" .. n.id)
        if pr.done then
            parts[#parts + 1] = " <RGB:0.5,0.9,0.6> " .. UI.escape(getText("IGUI_StoryEngine_Project_Done", head)) .. " <LINE> "
        else
            local needs = pr.accept and getText("IGUI_StoryEngine_Project_Accept_" .. tostring(pr.accept))
                or getText("IGUI_StoryEngine_Life_Res_" .. tostring(pr.res))
            parts[#parts + 1] = " <RGB:0.85,0.8,0.55> " .. UI.escape(getText("IGUI_StoryEngine_Project_Line", head, bar,
                StoryEngine.intToString(pts), StoryEngine.intToString(goal), needs)) .. " <LINE> "
        end
        parts[#parts + 1] = " <RGB:0.65,0.65,0.65> " .. UI.escape(getText("IGUI_StoryEngine_Project_Effect_" .. n.id))
            .. " <LINE> <LINE> "
    end
    local names = function(list)
        local out = {}
        for _, id in ipairs(list or {}) do
            local v = (n.bondVals or {})[id]
            local mark = v and (" (" .. (v > 0 and "+" or "") .. StoryEngine.intToString(v) .. ")") or ""
            out[#out + 1] = Factions.name(id) .. mark
        end
        return table.concat(out, ", ")
    end
    if #(n.likes or {}) > 0 then
        parts[#parts + 1] = " <RGB:0.5,0.85,0.5> " .. UI.escape(getText("IGUI_StoryEngine_Life_Likes", names(n.likes))) .. " <LINE> "
    end
    if #(n.dislikes or {}) > 0 then
        parts[#parts + 1] = " <RGB:0.95,0.5,0.4> " .. UI.escape(getText("IGUI_StoryEngine_Life_Dislikes", names(n.dislikes))) .. " <LINE> "
    end
    if #(n.tags or {}) > 0 then
        local tags = {}
        for _, t in ipairs(n.tags) do tags[#tags + 1] = getText("IGUI_StoryEngine_Life_Tag_" .. tostring(t)) end
        parts[#parts + 1] = " <RGB:1,0.85,0.5> " .. UI.escape(getText("IGUI_StoryEngine_Life_Tags", table.concat(tags, ", "))) .. " <LINE> "
    end
    parts[#parts + 1] = " <LINE> <H2> " .. UI.escape(getText("IGUI_StoryEngine_Life_Records")) .. " <LINE> "
    if #(n.records or {}) == 0 then
        parts[#parts + 1] = " <RGB:0.6,0.6,0.6> " .. UI.escape(getText("IGUI_StoryEngine_Life_NoRecords")) .. " <LINE> "
    end
    for _, e in ipairs(n.records or {}) do
        local line, d = recordText(e)
        local color = d > 0 and "0.6,0.85,0.6" or (d < 0 and "0.95,0.55,0.45" or "0.8,0.8,0.8")
        parts[#parts + 1] = " <RGB:" .. color .. "> " .. UI.escape(line) .. " <LINE> "
    end
    self.detail:setText(table.concat(parts))
    self.detail:paginate()
end

-- ================================================================ window

StoryEngineMainWindow = ISCollapsableWindow:derive("StoryEngineMainWindow")
StoryEngineMainWindow.instance = nil
StoryEngineMainWindow.TABS = { "radio", "quests", "journal", "life" }

function StoryEngineMainWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local th = self:titleBarHeight()
    local rh = self:resizeWidgetHeight()
    self.tabs = ISTabPanel:new(0, th, self.width, self.height - th - rh)
    self.tabs:initialise()
    self.tabs:setAnchorRight(true)
    self.tabs:setAnchorBottom(true)
    self.tabs:setEqualTabWidth(false)
    self:addChild(self.tabs)

    local vh = self.tabs.height - self.tabs.tabHeight
    self.panels = {
        radio = StoryEngineRadioPanel:new(0, 0, self.width, vh),
        quests = StoryEngineQuestPanel:new(0, 0, self.width, vh),
        journal = StoryEngineJournalPanel:new(0, 0, self.width, vh),
        life = StoryEngineLifePanel:new(0, 0, self.width, vh),
    }
    for _, key in ipairs(StoryEngineMainWindow.TABS) do
        local p = self.panels[key]
        p:initialise()
        p:setAnchorRight(true)
        p:setAnchorBottom(true)
        self.tabs:addView(getText("IGUI_StoryEngine_Tab_" .. key), p)
    end
end

function StoryEngineMainWindow:refresh(key)
    if key then
        if self.panels[key] then self.panels[key]:refresh() end
        return
    end
    for _, k in ipairs(StoryEngineMainWindow.TABS) do self.panels[k]:refresh() end
end

function StoryEngineMainWindow:showTab(key)
    self.tabs:activateView(getText("IGUI_StoryEngine_Tab_" .. key))
end

function StoryEngineMainWindow:close()
    UI.saveWindow("main", self)          -- 다음에 열 때 같은 자리·크기로 (UIUtil)
    StoryEngineMainWindow.instance = nil
    self:removeFromUIManager()
end

function StoryEngineMainWindow:new(x, y, w, h)
    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.title = getText("IGUI_StoryEngine_Title")
    o.resizable = true
    o.minimumWidth = 640
    o.minimumHeight = 400
    return o
end

-- 창을 열고(이미 열려 있으면 앞으로) 해당 탭을 보여 준다. 최신 데이터를 서버에 요청한다.
function StoryEngineMainWindow.open(key)
    local w = StoryEngineMainWindow.instance
    if not w then
        local x, y, width, height = UI.windowRect("main", 1000, 640, 640, 400)
        w = StoryEngineMainWindow:new(x, y, width, height)
        w:initialise()
        w:addToUIManager()
        StoryEngineMainWindow.instance = w
    end
    w:setVisible(true)
    w:bringToTop()
    w:showTab(key or "radio")
    w:refresh()
    if key == "radio" or not key then Cache.unread[Cache.faction] = 0 end
    request("radioChannels")
    request("radioHistory", { faction = Cache.faction })
    request("questList")
    request("journalList", { key = Cache.journalKey, memoir = Cache.journalMemoir or nil })
    request("lifeList")
end

-- 열려 있을 때만 새로 그린다.
function StoryEngineMainWindow.refreshIfOpen(key)
    local w = StoryEngineMainWindow.instance
    if w then w:refresh(key) end
end
