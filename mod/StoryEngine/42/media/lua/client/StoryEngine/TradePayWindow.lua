-- 거래 대가 제출 창. 인벤토리(가방 속까지)에서 요구 품목의 아이템을 골라 보낸다.
-- 가치는 shared/StoryEngine/Value.lua 로 계산하고, 서버가 같은 표로 다시 검증한다.

if isServer() then return end

require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISButton"
require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Value"

local Value = StoryEngine.Value

local FONT_H = getTextManager():getFontHeight(UIFont.Small)
local PAD = 8
local BUTTON_H = FONT_H + 12
local ROW_H = FONT_H + 10

StoryEngineTradePayWindow = ISCollapsableWindow:derive("StoryEngineTradePayWindow")
StoryEngineTradePayWindow.instance = nil

local function fmt(n)
    local whole = math.floor(n * 10 + 0.5) / 10
    if whole == math.floor(whole) then return StoryEngine.intToString(whole) end
    return tostring(whole)
end

local function drawRow(self, y, item, alt)
    local h = self.itemheight
    if y + self:getYScroll() + h < 0 or y + self:getYScroll() >= self.height then return y + h end
    local data = item.item
    if data.selected then
        self:drawRect(0, y, self:getWidth(), h - 1, 0.35, 0.3, 0.55, 0.3)
    elseif self.mouseoverselected == item.index and self:isMouseOver() and not self:isMouseOverScrollBar() then
        self:drawMouseOverHighlight(0, y, self:getWidth(), h - 1)
    end
    self:drawRectBorder(0, y, self:getWidth(), h, 0.4, self.borderColor.r, self.borderColor.g, self.borderColor.b)
    local mark = data.selected and "[v] " or "[  ] "
    self:drawText(mark .. data.name, 10, y + 5, 0.9, 0.9, 0.9, 1, UIFont.Small)
    local v = getText("IGUI_StoryEngine_Trade_Value", fmt(data.value))
    local w = getTextManager():MeasureStringX(UIFont.Small, v)
    self:drawText(v, self:getWidth() - w - 24, y + 5, 0.75, 0.85, 0.6, 1, UIFont.Small)
    return y + h
end

function StoryEngineTradePayWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local th = self:titleBarHeight()
    local rh = self:resizeWidgetHeight()
    local listH = self.height - th - rh - PAD * 4 - BUTTON_H - FONT_H
    self.list = ISScrollingListBox:new(PAD, th + PAD, self.width - PAD * 2, listH)
    self.list:initialise()
    self.list:instantiate()
    self.list.itemheight = ROW_H
    self.list.font = UIFont.Small
    self.list.drawBorder = true
    self.list.doDrawItem = drawRow
    self.list:setOnMouseDownFunction(self, StoryEngineTradePayWindow.onToggle)
    self.list:setAnchorRight(true)
    self.list:setAnchorBottom(true)
    self:addChild(self.list)

    local by = self.height - rh - PAD - BUTTON_H
    self.autoButton = ISButton:new(PAD, by, 120, BUTTON_H, getText("IGUI_StoryEngine_Trade_Auto"), self,
        StoryEngineTradePayWindow.onAuto)
    self.sendButton = ISButton:new(self.width - PAD - 140, by, 140, BUTTON_H, getText("IGUI_StoryEngine_Trade_Send"), self,
        StoryEngineTradePayWindow.onSend)
    for _, b in ipairs({ self.autoButton, self.sendButton }) do
        b:initialise()
        b:setAnchorTop(false)
        b:setAnchorBottom(true)
        self:addChild(b)
    end
    self.sendButton:setAnchorLeft(false)
    self.sendButton:setAnchorRight(true)
end

function StoryEngineTradePayWindow:selectedValue()
    local total = 0
    for _, row in ipairs(self.list.items) do
        if row.item.selected then total = total + row.item.value end
    end
    return total
end

function StoryEngineTradePayWindow:render()
    ISCollapsableWindow.render(self)
    local total = self:selectedValue()
    local enough = total >= (self.quest.price or 0)
    local text = getText("IGUI_StoryEngine_Trade_Total", fmt(total), fmt(self.quest.price or 0))
    local y = self.sendButton:getY() - FONT_H - PAD
    self:drawText(text, PAD, y, enough and 0.5 or 0.95, enough and 0.9 or 0.55, enough and 0.5 or 0.45, 1, UIFont.Small)
    self.sendButton:setEnable(enough)
end

function StoryEngineTradePayWindow:onToggle(data)
    if data then data.selected = not data.selected end
end

-- 싼 것부터 골라 필요한 가치를 채운다
function StoryEngineTradePayWindow:onAuto()
    local rows = {}
    for _, row in ipairs(self.list.items) do
        row.item.selected = false
        rows[#rows + 1] = row.item
    end
    table.sort(rows, function(a, b) return a.value < b.value end)
    local total = 0
    for _, data in ipairs(rows) do
        if total >= (self.quest.price or 0) then break end
        data.selected = true
        total = total + data.value
    end
end

function StoryEngineTradePayWindow:onSend()
    local ids = {}
    for _, row in ipairs(self.list.items) do
        if row.item.selected then ids[#ids + 1] = row.item.id end
    end
    local player = getSpecificPlayer(0)
    if player and #ids > 0 then
        StoryEngine.Net.toServer(player, "tradePay", { id = self.quest.id, items = ids })
    end
    self:close()
end

function StoryEngineTradePayWindow:fill()
    self.list:clear()
    local player = getSpecificPlayer(0)
    if not player then return end
    local items = Value.payableItems(player, self.quest.payCategory)
    table.sort(items, function(a, b) return Value.of(a:getFullType()) > Value.of(b:getFullType()) end)
    for i, it in ipairs(items) do
        if i > 200 then break end
        local data = { id = it:getID(), name = it:getDisplayName(), value = Value.of(it:getFullType()), selected = false }
        self.list:addItem(data.name, data)
    end
end

function StoryEngineTradePayWindow:close()
    StoryEngineTradePayWindow.instance = nil
    self:removeFromUIManager()
end

function StoryEngineTradePayWindow:new(x, y, w, h, quest)
    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.quest = quest
    o.title = getText("IGUI_StoryEngine_Trade_PayTitle",
        getText("IGUI_StoryEngine_Cat_" .. tostring(quest.payCategory)))
    o.resizable = true
    o.minimumWidth = 360
    o.minimumHeight = 300
    return o
end

function StoryEngineTradePayWindow.open(quest)
    if StoryEngineTradePayWindow.instance then StoryEngineTradePayWindow.instance:close() end
    local width, height = 440, 480
    local x = (getCore():getScreenWidth() - width) / 2 + 60
    local y = (getCore():getScreenHeight() - height) / 2
    local w = StoryEngineTradePayWindow:new(x, y, width, height, quest)
    w:initialise()
    w:addToUIManager()
    w:fill()
    StoryEngineTradePayWindow.instance = w
end
