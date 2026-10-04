-- 거래 목록 창 (2026-10-04): 교신 탭 [거래 요청] → 이 NPC 가 다루는 품목·등급과 등급마다 고를 수 있는 묶음, 지금 값.
-- 왼쪽: 품목·등급 (신뢰도가 모자란 등급은 회색 + 필요 신뢰도), 가운데 위: 그 등급의 묶음, 아래: 고른 묶음의 물건과 값.
-- [이 묶음 요청] → tradeAsk { faction, category, tier, bundle } (그 묶음 그대로), [무작위로 요청] → bundle 없이 (다른 모드 물건이
-- 섞일 수 있음). 서버(Trade.ask)가 신뢰도·형편·값을 다시 정한다.

if isServer() then return end

require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISRichTextPanel"
require "ISUI/ISButton"
require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/UIUtil"
require "StoryEngine/Factions"

local UI = StoryEngine.UI
local Net = StoryEngine.Net
local Factions = StoryEngine.Factions

local FONT_H = getTextManager():getFontHeight(UIFont.Small)
local PAD = 8
local LINE_H = FONT_H + 2
local ITEM_H = LINE_H * 2 + 10
local BUTTON_H = FONT_H + 12
local LEFT_W = 230

local COLOR_OK = { r = 0.9, g = 0.9, b = 0.9 }
local COLOR_LOCKED = { r = 0.5, g = 0.5, b = 0.5 }
local COLOR_SHORT = { r = 1, g = 0.75, b = 0.45 }

local function catName(cat) return getText("IGUI_StoryEngine_Cat_" .. tostring(cat)) end

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
    local c = data.color or COLOR_OK
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

-- 묶음 { { 아이템, 개수 } } -> "통조림 콩 x3, 주스 팩"
local function bundleText(items)
    local parts = {}
    for _, e in ipairs(items or {}) do
        local name = getItemNameFromFullType(e[1]) or e[1]
        parts[#parts + 1] = (e[2] or 1) > 1 and (name .. " x" .. StoryEngine.intToString(e[2])) or name
    end
    return table.concat(parts, ", ")
end

StoryEngineTradeCatalogWindow = ISCollapsableWindow:derive("StoryEngineTradeCatalogWindow")

function StoryEngineTradeCatalogWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local th = self:titleBarHeight()
    local rh = self:resizeWidgetHeight()
    local h = self.height - th - rh
    local top = th + PAD + LINE_H + PAD
    self.tiers = newList(PAD, top, LEFT_W, h - LINE_H - PAD * 4 - BUTTON_H, self, StoryEngineTradeCatalogWindow.onTier)
    self.tiers:setAnchorBottom(true)
    self:addChild(self.tiers)
    local x = PAD * 2 + LEFT_W
    local w = self.width - x - PAD
    local listH = math.floor((h - LINE_H - PAD * 4 - BUTTON_H) * 0.45)
    self.bundles = newList(x, top, w, listH, self, StoryEngineTradeCatalogWindow.onBundle)
    self.bundles:setAnchorRight(true)
    self:addChild(self.bundles)
    self.detail = ISRichTextPanel:new(x, top + listH + PAD, w, h - LINE_H - PAD * 5 - BUTTON_H - listH)
    self.detail:initialise()
    self.detail.autosetheight = false
    self.detail.clip = true
    self.detail.marginLeft = 10
    self.detail.marginRight = 10
    self.detail:addScrollBars()
    self.detail:setAnchorRight(true)
    self.detail:setAnchorBottom(true)
    self:addChild(self.detail)

    local by = self.height - rh - PAD - BUTTON_H
    self.askButton = ISButton:new(x, by, 170, BUTTON_H, getText("IGUI_StoryEngine_Catalog_Ask"), self,
        StoryEngineTradeCatalogWindow.onAsk)
    self.randomButton = ISButton:new(x + 170 + PAD, by, 170, BUTTON_H, getText("IGUI_StoryEngine_Catalog_Random"), self,
        StoryEngineTradeCatalogWindow.onRandom)
    self.randomButton.tooltip = getText("IGUI_StoryEngine_Catalog_RandomTip")
    for _, b in ipairs({ self.askButton, self.randomButton }) do
        b:initialise()
        b:setAnchorTop(false)
        b:setAnchorBottom(true)
        self:addChild(b)
    end
end

function StoryEngineTradeCatalogWindow:render()
    ISCollapsableWindow.render(self)
    local d = self.data or {}
    local wants = {}
    for _, w in ipairs(d.wants or {}) do wants[#wants + 1] = catName(w) end
    local text = getText("IGUI_StoryEngine_Catalog_Header", StoryEngine.intToString(d.trust or 0), table.concat(wants, ", "))
    if d.restockIn then
        text = text .. "  |  " .. getText("IGUI_StoryEngine_Catalog_Restock", StoryEngine.intToString(d.restockIn))
    end
    if d.reason == "open_deal" or d.reason == "negotiating" then
        text = text .. "  |  " .. getText("IGUI_StoryEngine_TradeAsk_OpenDeal")
    end
    self:drawText(fit(text, self.width - PAD * 2), PAD, self:titleBarHeight() + PAD, 0.6, 0.75, 0.6, 1, UIFont.Small)
end

-- 왼쪽 목록: 품목마다 1~최고 등급
function StoryEngineTradeCatalogWindow:fill()
    local d = self.data or {}
    self.tiers:clear()
    self.rows = {}
    for _, it in ipairs(d.items or {}) do
        for t = 1, #(it.needs or {}) do
            local need = it.needs[t] or 101
            local open = d.allowed and t <= (it.maxTier or 0)
            local sub
            if it.empty then
                sub = getText("IGUI_StoryEngine_TradeAsk_EmptyTip")
            elseif open and it.short then
                sub = getText("IGUI_StoryEngine_TradeAsk_Short")
            elseif open then
                sub = getText("IGUI_StoryEngine_Catalog_Open")
            elseif need > 100 then
                sub = getText("IGUI_StoryEngine_TradeAsk_Never")
            else
                sub = getText("IGUI_StoryEngine_TradeAsk_Need", StoryEngine.intToString(need))
            end
            local row = { category = it.category, tier = t, open = open, bundles = (it.tiers or {})[t] or {} }
            self.rows[#self.rows + 1] = row
            self.tiers:addItem(catName(it.category), {
                title = catName(it.category) .. "  " .. getText("IGUI_StoryEngine_TradeAsk_Tier", StoryEngine.intToString(t)),
                sub = sub, value = row,
                color = (not open and COLOR_LOCKED) or (it.short and COLOR_SHORT) or COLOR_OK,
            })
        end
    end
    self.row = nil
    for i, row in ipairs(self.rows) do
        if row.open then self.row = row; self.tiers.selected = i end
    end
    if not self.row and #self.rows > 0 then self.row = self.rows[1]; self.tiers.selected = 1 end
    self:fillBundles()
end

function StoryEngineTradeCatalogWindow:fillBundles()
    self.bundles:clear()
    self.bundle = nil
    local row = self.row
    local first = nil
    for i, b in ipairs(row and row.bundles or {}) do
        local price = b.sold and getText("IGUI_StoryEngine_Catalog_Sold")
            or (b.price and getText("IGUI_StoryEngine_Catalog_Price", StoryEngine.intToString(b.price)))
            or getText("IGUI_StoryEngine_Catalog_NoPrice")
        self.bundles:addItem(tostring(i), { title = getText("IGUI_StoryEngine_Catalog_Bundle", StoryEngine.intToString(i))
            .. "  -  " .. price, sub = bundleText(b.items), value = i, color = b.sold and COLOR_LOCKED or nil })
        if not first and not b.sold then first = i end
    end
    if row and #row.bundles > 0 then
        self.bundle = first or 1
        self.bundles.selected = self.bundle
    end
    self:showDetail()
end

function StoryEngineTradeCatalogWindow:showDetail()
    local parts = {}
    local line = function(text) parts[#parts + 1] = " <LINE> " .. UI.escape(text) end
    local row = self.row
    local d = self.data or {}
    if row then
        parts[#parts + 1] = " <H2> " .. UI.escape(catName(row.category) .. "  "
            .. getText("IGUI_StoryEngine_TradeAsk_Tier", StoryEngine.intToString(row.tier)))
        local b = self.bundle and row.bundles[self.bundle]
        if b then
            parts[#parts + 1] = " <LINE> <TEXT> "
            for _, e in ipairs(b.items or {}) do
                local name = getItemNameFromFullType(e[1]) or e[1]
                line("- " .. name .. ((e[2] or 1) > 1 and (" x" .. StoryEngine.intToString(e[2])) or ""))
            end
            parts[#parts + 1] = " <LINE> "
            if b.price then
                local wants = {}
                for _, w in ipairs(d.wants or {}) do wants[#wants + 1] = catName(w) end
                line(getText("IGUI_StoryEngine_Catalog_PriceLine", StoryEngine.intToString(b.price), table.concat(wants, ", ")))
            end
        end
        if b and b.sold then
            parts[#parts + 1] = " <LINE> <RGB:0.95,0.6,0.4> " .. UI.escape(getText("IGUI_StoryEngine_Catalog_SoldLine",
                StoryEngine.intToString(d.restockIn or 0)))
        end
        if not row.open then
            parts[#parts + 1] = " <LINE> <RGB:0.95,0.6,0.4> " .. UI.escape(getText("IGUI_StoryEngine_Catalog_Locked"))
        end
        parts[#parts + 1] = " <LINE> <RGB:0.6,0.6,0.6> " .. UI.escape(getText("IGUI_StoryEngine_Catalog_Note"))
    else
        parts[#parts + 1] = " <TEXT> " .. UI.escape(getText("IGUI_StoryEngine_Catalog_Empty"))
    end
    self.detail:setText(table.concat(parts))
    self.detail:paginate()
    self.detail:setYScroll(0)
    local can = row ~= nil and row.open and d.allowed == true and d.reason ~= "open_deal" and d.reason ~= "negotiating"
    local chosen = row and self.bundle and row.bundles[self.bundle] or nil
    local anyLeft = false
    for _, b in ipairs(row and row.bundles or {}) do
        if not b.sold then anyLeft = true end
    end
    self.askButton:setEnable(can and chosen ~= nil and not chosen.sold)
    self.randomButton:setEnable(can and anyLeft)
end

function StoryEngineTradeCatalogWindow:onTier(row)
    if not row then return end
    self.row = row
    self:fillBundles()
end

function StoryEngineTradeCatalogWindow:onBundle(i)
    self.bundle = i
    self:showDetail()
end

local function ask(self, bundle)
    local row = self.row
    local p = getSpecificPlayer(0)
    if not row or not p then return end
    Net.toServer(p, "tradeAsk", { faction = self.data.faction, category = row.category, tier = row.tier, bundle = bundle })
    self:close()
end

function StoryEngineTradeCatalogWindow:onAsk() ask(self, self.bundle) end
function StoryEngineTradeCatalogWindow:onRandom() ask(self, nil) end

function StoryEngineTradeCatalogWindow:close()
    UI.saveWindow("catalog", self)
    StoryEngineTradeCatalogWindow.instance = nil
    self:removeFromUIManager()
end

function StoryEngineTradeCatalogWindow:new(x, y, w, h, data)
    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.data = data
    o.title = getText("IGUI_StoryEngine_Catalog_Title", Factions.name(data.faction))
    o.resizable = true
    o.minimumWidth = 620
    o.minimumHeight = 380
    return o
end

-- 서버의 tradeOptions 답 (Trade.options)으로 연다
function StoryEngineTradeCatalogWindow.open(data)
    if not data or not data.faction then return end
    if StoryEngineTradeCatalogWindow.instance then StoryEngineTradeCatalogWindow.instance:close() end
    local x, y, w, h = UI.windowRect("catalog", 900, 580, 620, 380)
    local win = StoryEngineTradeCatalogWindow:new(x, y, w, h, data)
    win:initialise()
    win:addToUIManager()
    win:fill()
    StoryEngineTradeCatalogWindow.instance = win
end
