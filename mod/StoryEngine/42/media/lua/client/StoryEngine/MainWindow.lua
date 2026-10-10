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
require "StoryEngine/Tuning"
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
local COLOR_RISK = { r = 1.0, g = 0.5, b = 0.3 }       -- 놓치면 NPC 를 잃을 수 있는 퀘스트
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

-- 개인 모드에서 다른 사람 앞으로 온 개인별 부탁, 다른 사람의 거래 (받은·거래한 사람만 수락·거절한다)
local function othersRequest(q)
    if q == nil then return false end
    if q.addressed == true and not q.forMe then return true end
    return q.personalMode == true and q.kind == "trade" and not q.mine
end

-- 이 퀘스트에 내가 수락·거절할 수 있나
local function canRespond(q)
    return q ~= nil and not othersRequest(q)
end

-- 이 세력이 답을 기다리는 부탁·거래 제안 (남 앞으로 온 개인별 부탁은 빼고)
local function pendingProposal(fid)
    for _, q in ipairs(Cache.quests) do
        if (q.kind == "deliver" or q.kind == "trade" or q.kind == "horde") and q.state == "proposed"
            and q.origin and q.origin.faction == fid and not othersRequest(q) then
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
    -- 중요한 퀘스트: 왼쪽에 굵은 띠, 둘째 줄도 같은 색
    if data.risk then self:drawRect(1, y + 1, 4, h - 3, 1, COLOR_RISK.r, COLOR_RISK.g, COLOR_RISK.b) end
    self:drawText(fit(data.title, w), 10, y + 5, c.r, c.g, c.b, 1, UIFont.Small)
    if data.risk then
        self:drawText(fit(data.sub, w), 10, y + 5 + LINE_H, COLOR_RISK.r, COLOR_RISK.g, COLOR_RISK.b, 0.85, UIFont.Small)
    else
        self:drawText(fit(data.sub, w), 10, y + 5 + LINE_H, 0.6, 0.6, 0.6, 1, UIFont.Small)
    end
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
    local segments = nil
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
        local my, group = UI.trustPair(fid, ch)
        if my then
            -- 개인 모드: 크게 "내 신뢰 35", 작게 "무리 60" (혜택은 내 신뢰로)
            segments = {
                { getText("IGUI_StoryEngine_Radio_StatusFreq", f and f.freq or "?") .. "  |  ", UIFont.Small },
                { getText("IGUI_StoryEngine_Trust_Mine", StoryEngine.intToString(my)), UIFont.Medium, 0.6, 0.95, 0.6 },
                { "  " .. getText("IGUI_StoryEngine_Trust_Group", StoryEngine.intToString(group)), UIFont.Small, 0.6, 0.6, 0.6 },
            }
            text = ""
        else
            text = getText("IGUI_StoryEngine_Radio_Status", f and f.freq or "?",
                StoryEngine.intToString(ch and ch.trust or (f and f.trust) or 0))
        end
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
    if not segments then
        self:drawText(text, self.history:getX(), rowY + (BUTTON_H - FONT_H) / 2, r, g, b, 1, UIFont.Small)
        return
    end
    -- 글꼴이 다른 조각을 이어 그린다 (세로 가운데 맞춤)
    segments[#segments + 1] = { text, UIFont.Small }
    local tm = getTextManager()
    local x = self.history:getX()
    for _, seg in ipairs(segments) do
        local font = seg[2]
        local fh = tm:getFontHeight(font)
        self:drawText(seg[1], x, rowY + (BUTTON_H - fh) / 2, seg[3] or r, seg[4] or g, seg[5] or b, 1, font)
        x = x + tm:MeasureStringX(font, seg[1])
    end
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
    request("radioSay", { faction = Cache.faction, text = text, lang = UI.lang(),
                          intent = Cache.faction == "open" and UI.intentOf(text) or nil })
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
    end
    local text
    if b.category and tier then
        text = getText("IGUI_StoryEngine_Trade_Blocked", tier, catName(b.category), StoryEngine.intToString(b.need or 0))
    else
        text = getText("IGUI_StoryEngine_Trade_BlockedAll", StoryEngine.intToString(b.need or 0))
    end
    -- 개인 모드: 판정한 내 신뢰 (Trade.blocked 의 have)
    if b.have then text = text .. " " .. getText("IGUI_StoryEngine_Trade_BlockedHave", StoryEngine.intToString(b.have)) end
    return text
end

local function messageLine(fid, m)
    local clock = "[" .. tostring(m.clock or "") .. "] "
    if m.from == "npc" then
        return " <RGB:0.95,0.75,0.4> " .. UI.escape(clock .. Factions.nameAs(m.npc or fid, m.voice) .. ": ")
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
    elseif m.from == "system" and m.voice then
        local line = getText("IGUI_StoryEngine_Voice_Line", getText("IGUI_StoryEngine_Voice_" .. tostring(m.voice)))
        if m.cold then line = line .. " " .. getText("IGUI_StoryEngine_Voice_Cold") end
        return " <RGB:0.55,0.85,1> " .. UI.escape(clock .. line) .. " <LINE> "
    elseif m.from == "system" and m.fate then
        return " <RGB:0.75,0.6,0.9> " .. UI.escape(clock .. getText("IGUI_StoryEngine_Fate_Line_" .. tostring(m.fate),
            Factions.nameAs(fid, m.voice))) .. " <LINE> "
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
    elseif m.from == "system" and m.privateNote then
        -- 개인 모드: 다른 사람 앞으로 온 개인별 부탁 (내용은 받은 사람에게만)
        return " <RGB:0.6,0.6,0.65> " .. UI.escape(clock .. getText("IGUI_StoryEngine_Radio_PrivateNote",
            UI.npcName(m.npc or fid), tostring(m.toName or "?"))) .. " <LINE> "
    elseif m.from == "system" and m.groupAsk then
        -- 개인 모드: 무리의 부탁을 공용 주파수에도 알린다
        return " <RGB:1,0.85,0.45> " .. UI.escape(clock .. getText("IGUI_StoryEngine_Open_GroupAsk",
            UI.npcName(m.groupAsk))) .. " <LINE> "
    elseif m.from == "system" and m.groupCrisis then
        local names = {}
        local list = type(m.groupCrisis) == "table" and m.groupCrisis or { m.groupCrisis }
        for _, f in ipairs(list) do
            local id = type(f) == "table" and (f.faction or f.id) or f
            if id then names[#names + 1] = UI.npcName(id) end
        end
        return " <RGB:1,0.85,0.45> " .. UI.escape(clock .. getText("IGUI_StoryEngine_Open_GroupCrisis",
            table.concat(names, getText("IGUI_StoryEngine_NameJoin")))) .. " <LINE> "
    elseif m.from == "system" then
        local delta = tonumber(m.trust) or 0
        local sign = delta > 0 and ("+" .. StoryEngine.intToString(delta)) or StoryEngine.intToString(delta)
        local key = "IGUI_StoryEngine_TrustReason_" .. tostring(m.reason)
        local reason = m.src and getText(key, Factions.name(m.src)) or getText(key)
        if reason == key then reason = tostring(m.reason) end
        local color = delta >= 0 and "0.5,0.85,0.5" or "0.95,0.45,0.4"
        -- 개인 모드: 내 신뢰(나에게만 온 줄) / 무리 신뢰. 공유·싱글은 지금처럼 "신뢰도"
        local lineKey = (m.personal and "IGUI_StoryEngine_Trust_LinePersonal")
            or (m.group and "IGUI_StoryEngine_Trust_LineGroup") or "IGUI_StoryEngine_Trust_Line"
        if m.personal then color = delta >= 0 and "0.55,0.95,0.75" or "0.95,0.5,0.55" end
        return " <RGB:" .. color .. "> " .. UI.escape(clock .. getText(lineKey, sign, reason)) .. " <LINE> "
    elseif m.from == "static" then
        local key = (m.error == "gone" and "IGUI_StoryEngine_Radio_StaticGone")
            or (m.error == "blackout" and "IGUI_StoryEngine_Radio_StaticBlackout") or "IGUI_StoryEngine_Radio_Static"
        return " <RGB:0.5,0.5,0.5> " .. UI.escape(clock .. getText(key)) .. " <LINE> "
    end
    return " <RGB:0.55,0.75,1> " .. UI.escape(clock .. tostring(m.name or "?") .. ": ")
        .. " <RGB:0.85,0.85,0.85> " .. UI.escape(m.text) .. " <LINE> "
end

StoryEngineRadioPanel.messageLine = messageLine     -- 테스트용

function StoryEngineRadioPanel:refresh()
    local selectedIndex = 1
    self.list:clear()
    -- 공용 주파수를 맨 위에
    local rows = { { id = "open", freq = "121.5", open = true } }
    for _, f in ipairs(Factions.list) do rows[#rows + 1] = f end
    for i, f in ipairs(rows) do
        local unread = Cache.unread[f.id] or 0
        local sub = f.open and getText("IGUI_StoryEngine_Radio_OpenSub") or getText("IGUI_StoryEngine_Radio_ListSub", f.freq)
        -- 개인 모드: 주파수 옆에 내 신뢰·무리 신뢰 (목록 툴팁은 계속 떠서 방해가 되어 2026-10-09 뺌)
        local pair = not f.open and UI.trustPairText(f.id, Cache.channels[f.id]) or nil
        if pair then
            sub = sub .. "  |  " .. pair
        end
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
    self.tradeButton.tooltip = getText("IGUI_StoryEngine_TradeAsk_Tooltip")
    if UI.trustPair(Cache.faction, chSel) then
        self.tradeButton.tooltip = self.tradeButton.tooltip .. " <LINE> " .. getText("IGUI_StoryEngine_Trust_BenefitTip")
    end

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
-- others: 개인 모드에서 다른 사람 앞으로 온 개인별 부탁 (2026-10-09, 개인 모드에서만 버튼이 보이고 처음엔 고르지 않음)
local QUEST_GROUPS = { "proposed", "active", "reward", "completed", "failed", "others" }

-- 가서 물건만 챙기면 되는 보급 (보상·선물·디렉터 보급·거래 배송). 작전·큰 사건 현장과 구조 신호(안에 좀비)는 진행 중에 둔다
local TASK_SOURCES = { op = true, saga = true, rescue = true }
local function isRewardPickup(q)
    return q.kind == "supply_drop" and not (q.origin and TASK_SOURCES[q.origin.source])
end

local function questGroup(q)
    if othersRequest(q) then return "others" end
    if q.state == "proposed" then return "proposed" end
    if ACTIVE[q.state] and isRewardPickup(q) then return "reward" end
    if ACTIVE[q.state] then return "active" end
    if q.state == "completed" then return "completed" end
    return "failed"      -- failed, declined (거절·무응답·취소·철회)
end

function StoryEngineQuestPanel:createChildren()
    local h = self.height
    -- 묶음 버튼 2개씩 (5개 = 3줄)
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
    local rows = math.ceil(#QUEST_GROUPS / 2)
    local top = PAD + rows * (BUTTON_H + 4) + PAD
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
    -- 보상 사양 (Quests.waiveReward): 보상 보급을 챙기지 않고 NPC 에게 남겨 신뢰도를 얻는다
    self.waiveButton = newButton(x + 160 + PAD, h - PAD - BUTTON_H, 200, "", self, function(panel)
        local q = findQuest(Cache.questId)
        if q then request("rewardWaive", { id = q.id }) end
    end)
    self.waiveButton.tooltip = getText("IGUI_StoryEngine_Waive_Tooltip")
    self.waiveButton:setVisible(false)
    self:addChild(self.waiveButton)
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
        -- 나눠 낸다 (2026-10-08): 남은 항목 중 하나라도 가진 게 있으면 낼 수 있다
        for _, n in ipairs(q.need or {}) do
            if UI.needLeft(q, n) > 0.001 then
                local cat = UI.pointCat(n)
                if cat then
                    if UI.pointsHeld(p, cat, n[3]) > 0 then return true end
                elseif UI.countHeld(p, n[1]) > 0 then
                    return true
                end
            end
        end
        return false
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
        -- 이미 낸 값은 빼고 남은 값만 (나눠 내기, 2026-10-08)
        StoryEngineTradePayWindow.open({ id = q.id, payCategory = q.payCategory, price = q.price, paid = q.paid or 0 })
        return
    end
    -- 품목 점수 부탁: 낼 물건을 고르는 창 (거래 대가 창과 같은 것, 고른 물건 id 를 questSubmit 으로)
    -- 이미 다 채운 항목은 건너뛰고, 남은 가치만큼 (나눠 내기)
    if q.kind == "deliver" or q.kind == "extort" then
        for _, n in ipairs(q.need or {}) do
            local cat = UI.pointCat(n)
            if cat and UI.needLeft(q, n) > 0.001 then
                StoryEngineTradePayWindow.open({ id = q.id, payCategory = cat, price = n[2] or 1,
                                                 paid = (q.got or {})[n[1]] or 0, points = true,
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
    if q.council then return getText("IGUI_StoryEngine_QTitle_council_" .. tostring(q.kind)) end
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
        if q.work.volunteer then
            -- 일거리 청하기 (보수 없는 일)
            key = "IGUI_StoryEngine_Volunteer_Title_" .. tostring(q.work.how) .. (q.work.stage and ("_" .. q.work.stage) or "")
            title = getText(key, UI.npcName(q.work.faction))
        end
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
    if q.risk then return COLOR_RISK end
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
    if q.work then
        sub = getText(q.work.volunteer and "IGUI_StoryEngine_Volunteer_Tag" or "IGUI_StoryEngine_Work_Tag") .. " " .. sub
    end
    if q.holiday then sub = getText("IGUI_StoryEngine_Holiday_Tag") .. " " .. sub end
    if q.council then sub = getText("IGUI_StoryEngine_Council_Tag") .. " " .. sub end
    if q.favorCall then sub = getText("IGUI_StoryEngine_Work_FavorTag") .. " " .. sub end
    -- 다른 사람이 받은 퀘스트는 누가 받았는지 붙인다 (퀘스트는 서버 전체가 함께 본다)
    if q.owner and not q.mine then sub = sub .. "  -  " .. tostring(q.owner) end
    if q.risk then sub = getText("IGUI_StoryEngine_Quest_RiskTag") .. " " .. sub end
    return sub
end

-- 놓치면 그 NPC 를 잃을 수 있는 퀘스트의 경고 문장 (서버 Fate.questRisk -> q.risk)
local function riskText(q)
    local r = q.risk
    if not r then return nil end
    local who = r.faction and Factions.byId[r.faction] and Factions.name(r.faction) or ""
    if r.why == "starve" then
        return getText("IGUI_StoryEngine_Quest_Risk_starve", who, StoryEngine.intToString(r.days or 1))
    elseif r.why == "fever" then
        return getText("IGUI_StoryEngine_Quest_Risk_fever")
    end
    return getText("IGUI_StoryEngine_Quest_Risk_" .. tostring(r.why) .. "_" .. tostring(r.kind), who)
end

local function riskLine(q)
    local text = riskText(q)
    if not text then return "" end
    return " <RGB:1,0.5,0.3> " .. UI.escape(getText("IGUI_StoryEngine_Quest_RiskTag") .. " " .. text) .. " <LINE> "
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
        local got = (q.got or {})[n[1]] or 0
        local text
        if cat then
            text = getText("IGUI_StoryEngine_Quest_NeedPoints", UI.pointText(cat, n[2], n[3]),
                StoryEngine.intToString(math.floor(UI.pointsHeld(p, cat, n[3]))))
        else
            local name = getItemNameFromFullType(n[1]) or n[1]
            text = getText("IGUI_StoryEngine_Quest_NeedHave", name, StoryEngine.intToString(n[2] or 1),
                StoryEngine.intToString(UI.countHeld(p, n[1])))
        end
        -- 나눠 낸 만큼 (2026-10-08)
        if got > 0 then
            text = text .. "  " .. getText(UI.needLeft(q, n) <= 0.001 and "IGUI_StoryEngine_Quest_NeedDone"
                or "IGUI_StoryEngine_Quest_NeedGot", StoryEngine.intToString(math.floor(got + 0.5)))
        end
        line(text)
    end
    if q.givers then
        local who = {}
        for name, c in pairs(q.givers) do who[#who + 1] = tostring(name) .. " " .. StoryEngine.intToString(c) end
        table.sort(who)
        if #who > 0 then line(getText("IGUI_StoryEngine_Quest_Givers", table.concat(who, ", "))) end
    end
    if q.state == "accepted" and #(q.need or {}) > 0 then line(getText("IGUI_StoryEngine_Quest_PartialHint")) end
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
    -- 나눠 낸 대가 (2026-10-08)
    if (q.paid or 0) > 0 then
        local who = {}
        for name, v in pairs(q.payers or {}) do who[#who + 1] = tostring(name) .. " " .. StoryEngine.intToString(math.floor(v + 0.5)) end
        table.sort(who)
        line(getText("IGUI_StoryEngine_Trade_PaidSoFar", StoryEngine.intToString(math.floor(q.paid + 0.5)),
            StoryEngine.intToString(q.price or 0), table.concat(who, ", ")))
        if q.state == "failed" and not q.credit and not q.parcelEnd then
            line(getText("IGUI_StoryEngine_Trade_PartialGoods", UI.itemList(q.goodsKept or {})))
        end
    end
    if q.state == "accepted" and not q.payKind then line(getText("IGUI_StoryEngine_Trade_PartialHint")) end
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

-- 개인 모드 (2026-10-09): 결과가 어느 신뢰에 들어가는지, 누구 앞으로 온 부탁인지
local PERSONAL_WORK = { deliver = true, horde = true, fetch = true, named = true, trade = true, extort = true }
local function personalLines(q)
    if not q.personalMode then return "" end
    local parts = {}
    local open = q.state == "proposed" or ACTIVE[q.state] == true
    local line = function(color, text) parts[#parts + 1] = " <LINE> <RGB:" .. color .. "> " .. UI.escape(text) end
    if q.group then
        line("0.95,0.8,0.45", getText("IGUI_StoryEngine_Quest_GroupWork"))
    elseif q.addressed then
        line("0.6,0.8,1", getText("IGUI_StoryEngine_Quest_AddressedTo", tostring(q.addressedName or q.owner or "?")))
        if q.forMe then
            line("0.55,0.95,0.75", getText("IGUI_StoryEngine_Quest_PersonalWork"))
        elseif open then
            local share = StoryEngine.Tuning and StoryEngine.Tuning.num("HelperTrustShare") or 0.5
            line("0.7,0.7,0.7", getText("IGUI_StoryEngine_Quest_NotAddressed", UI.shareText(share)))
        end
    elseif PERSONAL_WORK[q.kind] and not q.work then
        if q.owner and not q.mine then
            line("0.7,0.7,0.7", getText("IGUI_StoryEngine_Quest_PersonalWorkOf", tostring(q.owner)))
        else
            line("0.55,0.95,0.75", getText("IGUI_StoryEngine_Quest_PersonalWork"))
        end
    end
    if q.lapsed then line("0.6,0.6,0.6", getText("IGUI_StoryEngine_Quest_Lapsed")) end
    return table.concat(parts)
end

local function questDetail(q)
    return riskLine(q) .. questDetailBase(q) .. personalLines(q) .. ownerLine(q) .. fightLine(q) .. helpersLine(q)
end

-- 테스트용
StoryEngineQuestPanel.questDetail = function(q) return questDetail(q) end
StoryEngineQuestPanel.questGroup = function(q) return questGroup(q) end
StoryEngineQuestPanel.questSub = function(q) return questSub(q) end
StoryEngineQuestPanel.riskText = function(q) return riskText(q) end
StoryEngineQuestPanel.canRespond = function(q) return canRespond(q) end
StoryEngineRadioPanel.pendingProposal = function(fid) return pendingProposal(fid) end

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
    if q.council then
        header = getText("IGUI_StoryEngine_Council_Header")
    elseif q.holiday then
        header = getText("IGUI_StoryEngine_Holiday_Header", getText("IGUI_StoryEngine_Holiday_" .. tostring(q.holiday)))
    elseif q.work and q.work.volunteer then
        header = getText("IGUI_StoryEngine_Volunteer_Header", Factions.name(q.work.faction),
            StoryEngine.intToString(q.work.gain or 0))
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
            goal = "IGUI_StoryEngine_" .. (q.work.volunteer and "Volunteer" or "Work") .. "_Goal_" .. tostring(q.work.how)
                .. (q.work.stage and ("_" .. q.work.stage) or "")
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
    if q.op or q.saga or q.work or q.holiday or q.council then return opDetail(q) end
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
    -- 묶음별 개수. 처음 열면 진행 중 > 보상 > 수락 대기 > 완료 > 실패 순으로 퀘스트가 있는 묶음
    local counts, risky = {}, {}
    local personalMode = false
    for _, q in ipairs(Cache.quests) do
        local g = questGroup(q)
        counts[g] = (counts[g] or 0) + 1
        if q.risk then risky[g] = true end
        if q.personalMode then personalMode = true end
    end
    -- "다른 사람 부탁" 묶음은 개인 모드에서만 (싱글·공유는 지금 그대로)
    if Cache.questGroup == "others" and not personalMode then Cache.questGroup = nil end
    if not Cache.questGroup then
        for _, g in ipairs({ "active", "reward", "proposed", "completed", "failed" }) do
            if not Cache.questGroup and (counts[g] or 0) > 0 then Cache.questGroup = g end
        end
        Cache.questGroup = Cache.questGroup or "active"
    end
    for g, b in pairs(self.groupButtons or {}) do
        if g == "others" then
            b:setVisible(personalMode)
            b.tooltip = getText("IGUI_StoryEngine_QGroup_others_tip")
        end
        -- 중요한 퀘스트가 든 묶음은 "!" 와 글자색으로 알린다
        b:setTitle(getText("IGUI_StoryEngine_QGroup_" .. g, StoryEngine.intToString(counts[g] or 0)) .. (risky[g] and " !" or ""))
        b.textColor = risky[g] and { r = COLOR_RISK.r, g = COLOR_RISK.g, b = COLOR_RISK.b, a = 1 } or { r = 1, g = 1, b = 1, a = 1 }
        if g == Cache.questGroup then
            b.backgroundColor = { r = 0.25, g = 0.4, b = 0.25, a = 1 }
        else
            b.backgroundColor = { r = 0, g = 0, b = 0, a = 1 }
        end
    end
    -- 중요한 퀘스트를 맨 위로 (나머지 순서는 그대로)
    local shown = {}
    for _, q in ipairs(Cache.quests) do
        if q.risk and questGroup(q) == Cache.questGroup then shown[#shown + 1] = q end
    end
    for _, q in ipairs(Cache.quests) do
        if not q.risk and questGroup(q) == Cache.questGroup then shown[#shown + 1] = q end
    end
    local selected, selectedIndex = nil, nil
    for i, q in ipairs(shown) do
        self.list:addItem(questTitle(q), { title = questTitle(q), sub = questSub(q), color = questColor(q), value = q,
                                           risk = q.risk and true or nil })
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
    -- 개인 모드: 남 앞으로 온 개인별 부탁은 받은 사람만 답한다 (상세에 안내 줄)
    local respondable = proposed and not choosing and canRespond(selected)
    self.acceptButton:setVisible(respondable)
    self.declineButton:setVisible(respondable)
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
    local canWaive = selected ~= nil and active and selected.waiveGain ~= nil
    self.waiveButton:setVisible(canWaive)
    if canWaive then
        self.waiveButton:setTitle(getText("IGUI_StoryEngine_Waive_Button", StoryEngine.intToString(selected.waiveGain)))
        self.waiveButton:setX(located and (self.mapButton:getRight() + PAD) or self.mapButton:getX())
    end
    self.workButton:setVisible(canWork)
    if canWork then
        local after = (respondable and self.declineButton) or (canSubmit and self.submitButton) or nil
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

-- ================================================================ people tab (2026-10-07)
-- NPC 인물 이야기: 이름·나이·성별·가족·사는 곳·하던 일·이야기, 그리고 지나온 일 (서버 Chronicle.lua).
-- 가족·사는 곳은 이야기 노드에 따라 바뀐다 (profile 변형 -> IGUI_StoryEngine_Profile_<npc>_<칸>_<변형>)

StoryEnginePeoplePanel = derivePanel("StoryEnginePeoplePanel")
StoryEnginePeoplePanel.LABELS = { "IGUI_StoryEngine_People_Age", "IGUI_StoryEngine_People_Gender", "IGUI_StoryEngine_People_Family",
    "IGUI_StoryEngine_People_Home", "IGUI_StoryEngine_People_Job", "IGUI_StoryEngine_People_Radio",
    "IGUI_StoryEngine_People_Trust", "IGUI_StoryEngine_People_Project" }

-- 이름 칸 너비: 잰 값과, 한글처럼 3바이트 이상인 글자를 글꼴 높이만큼으로 어림한 값 중 큰 쪽
function StoryEnginePeoplePanel.labelWidth(text, font)
    local tm = getTextManager()
    local measured, h = 0, 16
    local ok, w = pcall(function() return tm:MeasureStringX(font, text) end)
    if ok and type(w) == "number" then measured = w end
    local okH, fh = pcall(function() return tm:getFontHeight(font) end)
    if okH and type(fh) == "number" and fh > 0 then h = fh end
    local codes = {}
    for i = 1, #text do codes[i] = string.byte(text, i) end
    local wide, keep = StoryEnginePeoplePanel.splitWide(codes)
    local narrow = {}
    for _, i in ipairs(keep) do narrow[#narrow + 1] = string.sub(text, i, i) end
    local rest = 0
    if #narrow > 0 then
        local s = table.concat(narrow)
        local ok2, w2 = pcall(function() return tm:MeasureStringX(font, s) end)
        rest = (ok2 and type(w2) == "number") and w2 or #narrow * h * 0.5
    end
    return math.max(measured, wide * h + rest)
end

-- 넓은 글자 수와 좁은 글자 자리. 게임(Kahlua)의 문자열은 Java 문자열이라 한 글자가 한 칸이고 string.byte 가 코드값
-- (한글 44032~)을 준다. 표준 Lua(테스트)는 UTF-8 바이트라 3바이트 이상 묶음을 한 글자로 센다
function StoryEnginePeoplePanel.splitWide(codes)
    local wide, keep = 0, {}
    local javaChars = false
    for _, c in ipairs(codes) do if c > 255 then javaChars = true end end
    local i, n = 1, #codes
    while i <= n do
        local c = codes[i]
        if javaChars then
            if c >= 4352 then wide = wide + 1 else keep[#keep + 1] = i end
            i = i + 1
        else
            local len = (c >= 240 and 4) or (c >= 224 and 3) or (c >= 192 and 2) or 1
            if len >= 3 then wide = wide + 1 else keep[#keep + 1] = i end
            i = i + len
        end
    end
    return wide, keep
end

local function peopleOf(fid)
    for _, n in ipairs(Cache.people or {}) do
        if n.id == fid then return n end
    end
    return nil
end

local function profileText(fid, field, variant)
    if variant then
        local key = "IGUI_StoryEngine_Profile_" .. fid .. "_" .. field .. "_" .. tostring(variant)
        local t = getText(key)
        if t ~= key then return t end
    end
    local key = "IGUI_StoryEngine_Profile_" .. fid .. "_" .. field
    local t = getText(key)
    if t == key then return "" end
    return t
end

local function chronicleLine(fid, e)
    local day = "D" .. StoryEngine.intToString(e.day or 0) .. "  "
    local k = e.k
    if k == "beat" then
        local key = "IGUI_StoryEngine_Story_" .. tostring(e.node)
        local t = getText(key)
        if t == key then return nil end
        return day .. getText("IGUI_StoryEngine_Chron_beat", UI.npcName(fid), t), "0.85,0.85,0.8"
    elseif k == "trust" then
        return day .. getText("IGUI_StoryEngine_Chron_trust_" .. StoryEngine.intToString(e.v or 0)), "0.5,0.85,0.5"
    elseif k == "crisis" then
        local title = getText("IGUI_StoryEngine_Crisis_" .. tostring(e.crisis) .. "_title")
        local color = (e.role == "snubbed" or e.role == "ignored") and "0.95,0.55,0.45" or "0.95,0.8,0.45"
        return day .. getText("IGUI_StoryEngine_Chron_crisis_" .. tostring(e.role), title), color
    elseif k == "project" then
        local name = getText("IGUI_StoryEngine_Project_Name_" .. fid)
        if e.done then return day .. getText("IGUI_StoryEngine_Chron_project_done", name), "0.5,0.85,0.5" end
        return day .. getText("IGUI_StoryEngine_Chron_project_pct", name, StoryEngine.intToString(e.pct or 0)), "0.75,0.85,0.75"
    elseif k == "fate" then
        return day .. getText("IGUI_StoryEngine_Chron_fate_" .. tostring(e.kind)), "0.75,0.6,0.9"
    elseif k == "revived" then
        return day .. getText("IGUI_StoryEngine_Chron_revived"), "0.75,0.6,0.9"
    elseif k == "death" then
        return day .. getText("IGUI_StoryEngine_Chron_death_" .. StoryEngine.intToString(e.close or 0), tostring(e.who or "?")),
            "0.7,0.7,0.75"
    elseif k == "rec" then
        local key = "IGUI_StoryEngine_Life_Rec_" .. tostring(e.kind)
        local t = getText(key)
        if t == key then return nil end
        return day .. t, "0.75,0.85,0.75"
    elseif k == "council" then
        return day .. getText("IGUI_StoryEngine_Chron_council_" .. tostring(e.result)), "1,0.86,0.55"
    elseif k == "voice" then
        return day .. getText("IGUI_StoryEngine_Chron_voice"), "0.55,0.85,1"
    elseif k == "arc" then
        return day .. getText("IGUI_StoryEngine_Chron_arc", getText("IGUI_StoryEngine_Arc_Quote",
            getText("IGUI_StoryEngine_Arc_" .. tostring(e.arc)))), "0.95,0.75,0.4"
    end
    return nil
end

local TONE_COLOR = { good = "0.5,0.9,0.5", mixed = "0.95,0.8,0.45", bad = "0.95,0.5,0.45" }

local function arcTitle(arc)
    return getText("IGUI_StoryEngine_Arc_Quote", getText("IGUI_StoryEngine_Arc_" .. tostring(arc)))
end

-- 인물 탭 "큰 이야기" (서버 Social.storyInfo): 처음부터 지금까지. 이야기마다 제목·몇 번째·진행 중 또는 결말,
-- 그 아래 지나온 장면을 플레이어 입장의 일지처럼 이어 쓴 글 (IGUI_StoryEngine_Tale_<노드>, 어느 장면으로 갔는지가
-- 곧 도왔는지·못 도왔는지라 결과가 담겨 있다. 지금 장면은 밝게), 도움을 청하는 중인지, 다음 이야기까지 며칠.
-- 색 바꿈 태그 옆 공백은 지워지므로 띄어쓰기는 <SPACE> 로
function StoryEnginePeoplePanel.storyText(fid, st, noHeader)
    if not st then return nil end
    local parts = {}
    if not noHeader then
        parts[#parts + 1] = " <RGB:1,0.78,0.35> <H2> " .. UI.escape(getText("IGUI_StoryEngine_People_BigStory")) .. " <LINE> "
    end
    -- 지나온 장면을 이야기별로 묶는다 (나온 순서대로)
    local groups, byArc = {}, {}
    for _, e in ipairs(st.path or {}) do
        local arc = e.arc or st.arc
        if not byArc[arc] then
            byArc[arc] = { arc = arc, scenes = {}, chapter = e.chapter, title = e.title }
            groups[#groups + 1] = byArc[arc]
        end
        local list = byArc[arc].scenes
        if not list[#list] or list[#list].node ~= e.node then list[#list + 1] = e end
    end
    if not byArc[st.arc] then
        byArc[st.arc] = { arc = st.arc, scenes = { { node = st.node } }, chapter = st.chapter }
        groups[#groups + 1] = byArc[st.arc]
    end
    local tones = {}
    for _, a in ipairs(st.past or {}) do tones[a.arc] = a.tone or "mixed" end
    for gi, g in ipairs(groups) do
        local current = g.arc == st.arc
        local chapter = g.chapter or (current and st.chapter) or gi
        chapter = type(chapter) == "number" and StoryEngine.intToString(chapter) or tostring(chapter)
        local stateText, stateColor
        if current and not st.final then
            stateText, stateColor = getText("IGUI_StoryEngine_People_StoryOngoing"), "0.55,0.85,1"
        else
            local tone = current and (st.tone or "mixed") or tones[g.arc] or "mixed"
            stateText, stateColor = getText("IGUI_StoryEngine_People_Tone_" .. tone), TONE_COLOR[tone] or TONE_COLOR.mixed
        end
        if gi > 1 then parts[#parts + 1] = " <LINE> " end
        local title = g.title and getText("IGUI_StoryEngine_Arc_Quote", g.title) or arcTitle(g.arc)
        parts[#parts + 1] = " <RGB:1,0.86,0.55> " .. UI.escape(title) .. " <SPACE> <RGB:0.7,0.7,0.65> "
            .. UI.escape(getText("IGUI_StoryEngine_People_Chapter_" .. chapter)) .. " <SPACE> - <SPACE> "
            .. " <RGB:" .. stateColor .. "> " .. UI.escape(stateText) .. " <LINE> "
        -- 지나온 장면을 한 문단으로 (지금 장면은 밝게)
        local before, nowText = {}, nil
        for si, e in ipairs(g.scenes) do
            local key = "IGUI_StoryEngine_Tale_" .. tostring(e.node)
            local tale = e.tale or getText(key)
            if tale ~= key then
                if current and si == #g.scenes and not st.final then nowText = tale else before[#before + 1] = tale end
            end
        end
        parts[#parts + 1] = " <INDENT:12> "
        if #before > 0 then
            parts[#parts + 1] = " <RGB:0.85,0.85,0.8> " .. UI.escape(table.concat(before, " "))
            if nowText then parts[#parts + 1] = " <SPACE> " end
        end
        if nowText then parts[#parts + 1] = " <RGB:1,1,0.95> " .. UI.escape(nowText) end
        parts[#parts + 1] = " <LINE> <INDENT:0> "
    end
    if st.asking then
        parts[#parts + 1] = " <RGB:0.5,0.9,0.5> " .. UI.escape(getText("IGUI_StoryEngine_People_Asking")) .. " <LINE> "
    end
    if st.nextDays and (st.final or st.waiting) then
        parts[#parts + 1] = " <RGB:0.55,0.85,1> " .. UI.escape(getText("IGUI_StoryEngine_People_NextStory",
            StoryEngine.intToString(math.max(1, st.nextDays)))) .. " <LINE> "
    elseif st.final then
        parts[#parts + 1] = " <RGB:0.7,0.7,0.65> " .. UI.escape(getText("IGUI_StoryEngine_People_StoryOver")) .. " <LINE> "
    end
    return table.concat(parts)
end

function StoryEnginePeoplePanel:createChildren()
    self.list = newList(PAD, PAD, LIST_W, self.height - PAD * 2, self, StoryEnginePeoplePanel.onSelect)
    self.list:setAnchorBottom(true)
    self:addChild(self.list)
    local x = PAD * 2 + LIST_W
    self.text = newRichText(x, PAD, self.width - x - PAD, self.height - PAD * 2)
    self.text:setAnchorRight(true)
    self.text:setAnchorBottom(true)
    self:addChild(self.text)
end

function StoryEnginePeoplePanel:onSelect(fid)
    if not fid then return end
    Cache.peopleFaction = fid
    self:refresh()
end

function StoryEnginePeoplePanel:refresh()
    self.list:clear()
    if not Cache.peopleFaction then Cache.peopleFaction = Factions.list[1] and Factions.list[1].id end
    local selectedIndex = 0
    for i, f in ipairs(Factions.list) do
        local n = peopleOf(f.id)
        local sub = getText("IGUI_StoryEngine_Radio_ListSub", f.freq)
        local color = nil
        if n and n.fate then
            sub = getText("IGUI_StoryEngine_Fate_" .. tostring(n.fate))
            color = COLOR_DECLINED
        end
        self.list:addItem(Factions.name(f.id), { title = Factions.name(f.id), sub = sub, value = f.id, color = color })
        if f.id == Cache.peopleFaction then selectedIndex = i end
    end
    self.list.selected = selectedIndex
    local fid = Cache.peopleFaction
    if not fid then return end
    local n = peopleOf(fid) or { profile = {}, chronicle = {} }
    local prof = n.profile or {}
    local who = n.voice or fid           -- 후임 목소리면 그 사람의 프로필 (IGUI_StoryEngine_Profile_<후임>_*)
    local parts = {}
    -- 이름 칸 너비 (가장 긴 이름 + 여백). 값은 그 자리부터 (색 바꿈 태그 옆 공백은 지워지므로 <SETX:>)
    -- MeasureStringX 는 한글 폭을 작게 재서 (2026-10-09 "가족·곁의 사람"이 값과 겹침) labelWidth 로 어림한다
    local labelW = 0
    for _, key in ipairs(StoryEnginePeoplePanel.LABELS) do
        local w = StoryEnginePeoplePanel.labelWidth(getText(key), self.text.defaultFont or UIFont.NewSmall)
        if w > labelW then labelW = w end
    end
    local valueX = StoryEngine.intToString(math.floor(labelW + 16))
    local function row(label, value)
        if value and value ~= "" then
            parts[#parts + 1] = " <RGB:0.65,0.65,0.6> " .. UI.escape(getText(label)) .. " <SETX:" .. valueX .. "> <RGB:0.92,0.92,0.88> "
                .. UI.escape(value) .. " <LINE> "
        end
    end
    parts[#parts + 1] = " <H2> " .. UI.escape(Factions.name(fid)) .. " <LINE> "
    if n.fate then
        parts[#parts + 1] = " <RGB:0.75,0.6,0.9> " .. UI.escape(getText("IGUI_StoryEngine_Fate_Line_" .. tostring(n.fate),
            Factions.name(fid)) .. "  (D" .. StoryEngine.intToString(n.fateDay or 0) .. ")") .. " <LINE> "
    end
    row("IGUI_StoryEngine_People_Age", profileText(who, "age"))
    row("IGUI_StoryEngine_People_Gender", profileText(who, "gender"))
    row("IGUI_StoryEngine_People_Family", profileText(who, "family", prof.family))
    row("IGUI_StoryEngine_People_Home", profileText(who, "home", prof.home))
    row("IGUI_StoryEngine_People_Job", profileText(who, "job", prof.job))
    local f = Factions.byId[fid]
    row("IGUI_StoryEngine_People_Radio", f and getText("IGUI_StoryEngine_Radio_ListSub", f.freq) or nil)
    -- 개인 모드: "내 신뢰 35  무리 60" (지나온 일의 신뢰 20/40/60/80 은 무리 신뢰 기준)
    local pair = UI.trustPairText(fid, n.trust and n or nil)
    if pair then
        row("IGUI_StoryEngine_People_Trust", pair)
    elseif n.trust then
        row("IGUI_StoryEngine_People_Trust", StoryEngine.intToString(n.trust))
    end
    if n.project then
        local p = n.project
        row("IGUI_StoryEngine_People_Project", getText("IGUI_StoryEngine_Project_Name_" .. fid) .. "  "
            .. (p.done and getText("IGUI_StoryEngine_People_ProjectDone")
                or (StoryEngine.intToString(p.percent or 0) .. "%")))
    end
    parts[#parts + 1] = " <LINE> <RGB:0.95,0.75,0.4> " .. UI.escape(getText("IGUI_StoryEngine_People_Story"))
        .. " <LINE> <RGB:0.88,0.88,0.84> " .. UI.escape(profileText(who, "bio")) .. " <LINE> "
    -- 큰 이야기: 처음부터 지금까지 (이야기 소개 아래)
    local storyText = StoryEnginePeoplePanel.storyText(fid, n.story)
    if storyText then parts[#parts + 1] = " <LINE> " .. storyText end
    -- 앞 사람 (후임 목소리, 가장 최근이 위): 이름·어떻게 떠났는지와 그 사람의 큰 이야기
    local prevs = n.prevVoices or {}
    for i = #prevs, 1, -1 do
        local pv = prevs[i]
        local name = pv.voice and getText("IGUI_StoryEngine_Voice_" .. tostring(pv.voice))
            or getText("IGUI_StoryEngine_Faction_" .. fid)
        parts[#parts + 1] = " <LINE> <RGB:0.75,0.6,0.9> " .. UI.escape(getText("IGUI_StoryEngine_People_Prev",
            name, getText("IGUI_StoryEngine_Fate_" .. tostring(pv.fate or "gone")), StoryEngine.intToString(pv.day or 0))) .. " <LINE> "
        local prevText = StoryEnginePeoplePanel.storyText(fid, pv.story, true)
        if prevText then parts[#parts + 1] = prevText end
    end
    parts[#parts + 1] = " <LINE> <RGB:0.95,0.75,0.4> " .. UI.escape(getText("IGUI_StoryEngine_People_History")) .. " <LINE> "
    local any = false
    for _, e in ipairs(n.chronicle or {}) do
        local ok, text, color = false, nil, nil
        if e.k ~= "beat" and e.k ~= "arc" then ok, text, color = pcall(chronicleLine, fid, e) end
        if ok and text then
            any = true
            parts[#parts + 1] = " <RGB:" .. (color or "0.85,0.85,0.85") .. "> " .. UI.escape(text) .. " <LINE> "
        end
    end
    if not any then
        parts[#parts + 1] = " <RGB:0.6,0.6,0.6> " .. UI.escape(getText("IGUI_StoryEngine_People_NoHistory")) .. " <LINE> "
    end
    self.text:setText(table.concat(parts))
    self.text:paginate()
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
local VOLUNTEER_W = 150

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
    local trust = UI.trustPairText(n.id, n) or getText("IGUI_StoryEngine_Life_Trust", StoryEngine.intToString(n.trust or 0))
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
    -- 2차 특기 (Specialty2): 프로젝트 버튼 자리 (두 프로젝트가 다 끝나면 프로젝트 버튼이 사라진다)
    self.spec2Button = newButton(x + DONATE_W + SPEC_W + PAD * 2, h - PAD - BUTTON_H, PROJECT_W, "",
        self, StoryEngineLifePanel.onSpecialty2)
    self:addChild(self.spec2Button)
    -- 일거리 청하기 (Work.volunteer): 보수 없이 일해 주고 신뢰도를 얻는다
    self.volunteerButton = newButton(x + DONATE_W + SPEC_W + PROJECT_W + PAD * 3, h - PAD - BUTTON_H, VOLUNTEER_W,
        getText("IGUI_StoryEngine_Volunteer_Button"), self, function(panel)
            local n = lifeOf(Cache.lifeFaction)
            if n then request("volunteerAsk", { faction = n.id }) end
        end)
    self:addChild(self.volunteerButton)
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

-- 2차 특기: 쓰기(약 조제는 약 고르기) + 고르기/바꾸기
local function spec2Tip(option, text)
    local tip = ISToolTip:new()
    tip:initialise()
    tip:setVisible(false)
    tip.description = text
    option.toolTip = tip
end

local function spec2ErrorText(reason, wait)
    local key = "IGUI_StoryEngine_Spec2_Error_" .. tostring(reason)
    if getTextOrNull(key) then return getText(key, StoryEngine.intToString(wait or 0)) end
    return tostring(reason)
end

StoryEngineLifePanel.PHARMACY = { { "vitamins", 6 }, { "sleeping", 6 }, { "beta", 6 }, { "antidep", 6 },
                                  { "painkillers", 6 }, { "disinfectant", 6 }, { "antibiotics", 8 } }
StoryEngineLifePanel.HERBS = { ["Base.Plantain"] = true, ["Base.Comfrey"] = true, ["Base.WildGarlic2"] = true,
                               ["Base.CommonMallow"] = true, ["Base.LemonGrass"] = true, ["Base.BlackSage"] = true,
                               ["Base.Ginseng"] = true }

local function herbCount()
    local p = getPlayer()
    if not p then return 0 end
    local n = 0
    local list = p:getInventory():getItems()
    for i = 0, list:size() - 1 do
        local it = list:get(i)
        if it and StoryEngineLifePanel.HERBS[it:getFullType()] and not p:isEquipped(it) then n = n + 1 end
    end
    return n
end

function StoryEngineLifePanel.fillSpec2(menu, n)
    local s2 = n.spec2
    if not s2 then return end
    local fid = n.id
    if s2.choice then
        local name = getText("IGUI_StoryEngine_Spec2_Name_" .. s2.choice)
        local use = menu:addOption(getText("IGUI_StoryEngine_Spec2_Use", name), fid, function(id)
            if (s2.choice == "artillery" or s2.choice == "heist") and StoryEngine.Aim then
                StoryEngine.Aim.start(id, s2.choice)
            else
                request("spec2Use", { faction = id })
            end
        end)
        local desc = getText("IGUI_StoryEngine_Spec2_Desc_" .. s2.choice)
        if s2.reason then
            use.notAvailable = true
            desc = spec2ErrorText(s2.reason, s2.wait) .. " <LINE> " .. desc
        end
        spec2Tip(use, desc)
        if s2.choice == "pharmacy" and not s2.reason then
            use.onSelect = nil
            local sub = ISContextMenu:getNew(menu)
            menu:addSubMenu(use, sub)
            local have = herbCount()
            sub:addOption(getText("IGUI_StoryEngine_Spec2_PharmacyHave", StoryEngine.intToString(have)), nil, nil).notAvailable = true
            for _, m in ipairs(StoryEngineLifePanel.PHARMACY) do
                for count = 1, 2 do
                    local need = m[2] * count
                    local o = sub:addOption(getText("IGUI_StoryEngine_Spec2_PharmacyItem",
                        getText("IGUI_StoryEngine_Spec2_Med_" .. m[1]), StoryEngine.intToString(count),
                        StoryEngine.intToString(need)), fid, function(id)
                            request("spec2Use", { faction = id, med = m[1], count = count })
                        end)
                    if have < need then o.notAvailable = true end
                end
            end
        end
    end
    -- 고르기 / 바꾸기 (30일마다)
    local label = s2.choice and ((s2.change or 0) > 0
        and getText("IGUI_StoryEngine_Spec2_ChangeWait", StoryEngine.intToString(s2.change))
        or getText("IGUI_StoryEngine_Spec2_Change")) or getText("IGUI_StoryEngine_Spec2_ChooseButton")
    local pick = menu:addOption(label, nil, nil)
    local sub = ISContextMenu:getNew(menu)
    menu:addSubMenu(pick, sub)
    for i, opt in ipairs(s2.options or {}) do
        local text = getText("IGUI_StoryEngine_Spec2_Name_" .. opt)
        local ready = (s2.ready or {})[i] == true
        if opt == s2.choice then text = text .. " " .. getText("IGUI_StoryEngine_Spec2_Current") end
        if not ready then text = text .. " " .. getText("IGUI_StoryEngine_Spec2_NotReady") end
        local o = sub:addOption(text, opt, function(chosen)
            request("spec2Choose", { faction = fid, option = chosen })
        end)
        if not ready or opt == s2.choice or (s2.choice and (s2.change or 0) > 0) then o.notAvailable = true end
        spec2Tip(o, getText("IGUI_StoryEngine_Spec2_Desc_" .. opt) .. " <LINE> " .. getText("IGUI_StoryEngine_Spec2_Common"))
    end
end

function StoryEngineLifePanel:onSpecialty2()
    local n = lifeOf(Cache.lifeFaction)
    if not n or not n.spec2 then return end
    local menu = ISContextMenu.get(0, getMouseX(), getMouseY())
    StoryEngineLifePanel.fillSpec2(menu, n)
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
    local my, group = UI.trustPair(n.id, n)
    if my then
        -- 개인 모드: 크게 내 신뢰, 그 오른쪽에 작게 무리 신뢰
        local tm = getTextManager()
        local gt = getText("IGUI_StoryEngine_Trust_Group", StoryEngine.intToString(group))
        local mt = getText("IGUI_StoryEngine_Trust_Mine", StoryEngine.intToString(my))
        local gw = tm:MeasureStringX(UIFont.Small, gt)
        local mw = tm:MeasureStringX(UIFont.Medium, mt)
        local mh = tm:getFontHeight(UIFont.Medium)
        self:drawText(gt, x + w - gw, y, 0.6, 0.6, 0.6, 1, UIFont.Small)
        self:drawText(mt, x + w - gw - PAD - mw, math.max(0, y + FONT_H - mh), 0.6, 0.95, 0.6, 1, UIFont.Medium)
    else
        local trust = getText("IGUI_StoryEngine_Life_Trust", StoryEngine.intToString(n.trust or 0))
        local tw = getTextManager():MeasureStringX(UIFont.Small, trust)
        self:drawText(trust, x + w - tw, y, 0.75, 0.85, 0.75, 1, UIFont.Small)
    end
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
    -- 물자 지원 통 (3일 동안 한도까지 나눠 낸다, 2026-10-08)
    local d = n.donate
    if not n.fate and d and d.hours then
        local text
        if (n.donateWait or 0) > 0 then
            text = getText("IGUI_StoryEngine_Life_DonateWait", StoryEngine.intToString(n.donateWait))
        else
            text = getText("IGUI_StoryEngine_Life_DonateWindow", StoryEngine.intToString(d.hours))
        end
        self:drawText(text, self.volunteerButton:getRight() + PAD, self.donateButton:getY() + (BUTTON_H - FONT_H) / 2,
            0.7, 0.7, 0.7, 1, UIFont.Small)
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
    self.spec2Button:setVisible(false)
    self.volunteerButton:setVisible(n ~= nil and n.volunteer ~= nil and not n.fate)
    if n and n.volunteer then
        local v = n.volunteer
        local tip = getText(n.personalMode and "IGUI_StoryEngine_Volunteer_Tooltip_Personal" or "IGUI_StoryEngine_Volunteer_Tooltip", StoryEngine.intToString(v.tier or 1),
            StoryEngine.intToString(v.gain or 0), StoryEngine.intToString(v.left or 0))
        if v.why then tip = getText("IGUI_StoryEngine_Volunteer_Why_" .. tostring(v.why)) .. " <LINE> " .. tip end
        self.volunteerButton.tooltip = tip
        self.volunteerButton:setEnable(v.ok == true)
    end
    if not n then
        self.detail:setText(" <TEXT> " .. UI.escape(getText("IGUI_StoryEngine_Life_Empty")))
        self.detail:paginate()
        return
    end
    local proj = n.project
    self.projectButton:setVisible(proj ~= nil and not proj.done and not n.fate)
    self.projectButton:setEnable((n.projectWait or 0) == 0)
    self.projectButton.tooltip = getText(n.personalMode and "IGUI_StoryEngine_Project_Tooltip_Personal" or "IGUI_StoryEngine_Project_Tooltip")
    if n.fate then
        self.donateButton:setVisible(false)
        self.specButton:setVisible(false)
    end
    self.donateButton:setEnable((n.donateWait or 0) == 0)
    self.donateButton.tooltip = getText(n.personalMode and "IGUI_StoryEngine_Life_DonateTooltip_Personal" or "IGUI_StoryEngine_Life_DonateTooltip")
    -- 2차 특기: 2차 프로젝트가 끝나면 프로젝트 버튼 자리에
    local s2 = n.spec2
    if s2 and s2.unlocked and not n.fate and not self.projectButton:isVisible() and s2.reason ~= "off" then
        self.spec2Button:setVisible(true)
        local title = s2.choice and getText("IGUI_StoryEngine_Spec2_Button",
            getText("IGUI_StoryEngine_Spec2_Name_" .. s2.choice)) or getText("IGUI_StoryEngine_Spec2_ChooseButton")
        self.spec2Button:setTitle(title)
        local tip2 = s2.choice and getText("IGUI_StoryEngine_Spec2_Desc_" .. s2.choice)
            or getText("IGUI_StoryEngine_Spec2_Tooltip_Pick")
        if s2.active then tip2 = getText("IGUI_StoryEngine_Spec2_Active", StoryEngine.intToString(s2.active)) .. " <LINE> " .. tip2 end
        if s2.choice and s2.reason then tip2 = spec2ErrorText(s2.reason, s2.wait) .. " <LINE> " .. tip2 end
        self.spec2Button.tooltip = tip2 .. " <LINE> " .. getText("IGUI_StoryEngine_Spec2_Common")
    end
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
    if UI.trustPair(n.id, n) then tip = tip .. " <LINE> " .. getText("IGUI_StoryEngine_Trust_BenefitTip") end
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
        local two = pr.phase == 2
        local head = getText((two and "IGUI_StoryEngine_Project2_Name_" or "IGUI_StoryEngine_Project_Name_") .. n.id)
        if two then
            -- 1차는 끝났다: 그 효과를 먼저 한 줄로
            parts[#parts + 1] = " <RGB:0.5,0.9,0.6> " .. UI.escape(getText("IGUI_StoryEngine_Project_Done",
                getText("IGUI_StoryEngine_Project_Name_" .. n.id))) .. " <LINE> "
            parts[#parts + 1] = " <RGB:0.65,0.65,0.65> " .. UI.escape(getText("IGUI_StoryEngine_Project_Effect_" .. n.id))
                .. " <LINE> "
        end
        if pr.done then
            parts[#parts + 1] = " <RGB:0.5,0.9,0.6> " .. UI.escape(getText(two and "IGUI_StoryEngine_Project2_Done"
                or "IGUI_StoryEngine_Project_Done", head)) .. " <LINE> "
        else
            local needs = pr.accept and getText("IGUI_StoryEngine_Project_Accept_" .. tostring(pr.accept))
                or getText("IGUI_StoryEngine_Life_Res_" .. tostring(pr.res))
            parts[#parts + 1] = " <RGB:0.85,0.8,0.55> " .. UI.escape(getText(two and "IGUI_StoryEngine_Project2_Line"
                or "IGUI_StoryEngine_Project_Line", head, bar,
                StoryEngine.intToString(pts), StoryEngine.intToString(goal), needs)) .. " <LINE> "
        end
        parts[#parts + 1] = " <RGB:0.65,0.65,0.65> " .. UI.escape(getText(two and "IGUI_StoryEngine_Project2_Effect"
            or ("IGUI_StoryEngine_Project_Effect_" .. n.id))) .. " <LINE> <LINE> "
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
StoryEngineMainWindow.TABS = { "radio", "quests", "journal", "life", "people" }

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
        people = StoryEnginePeoplePanel:new(0, 0, self.width, vh),
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
    request("npcProfiles")
end

-- 열려 있을 때만 새로 그린다.
function StoryEngineMainWindow.refreshIfOpen(key)
    local w = StoryEngineMainWindow.instance
    if w then w:refresh(key) end
end
