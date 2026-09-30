-- 물자 지원 창 (거점 탭). 인벤토리(가방 속까지)에서 NPC 가 받는 물건을 골라 보낸다.
-- 물건 -> 자원 분류와 가치는 shared/StoryEngine/Value.lua, 서버(Life.donate)가 같은 표로 다시 검증한다.
-- 미리보기: 자원별 증가(가치 x2, 자원당 최대 40)와 신뢰도(가치 5/15/30 이상 +1/+2/+3). 서버 값과 같은 규칙.

if isServer() then return end

require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISButton"
require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Value"
require "StoryEngine/Factions"

local Value = StoryEngine.Value

local FONT_H = getTextManager():getFontHeight(UIFont.Small)
local PAD = 8
local BUTTON_H = FONT_H + 12
local ROW_H = FONT_H + 10
local MULT, CAP = 2, 40
local TRUST_STEPS = { { 30, 3 }, { 15, 2 }, { 5, 1 } }
local PROJECT_CAP = 100              -- 프로젝트 지원 한 번에 최대 점수 (서버 Projects.DONATE_CAP)

StoryEngineDonateWindow = ISCollapsableWindow:derive("StoryEngineDonateWindow")
StoryEngineDonateWindow.instance = nil

local function fmt(n)
    local whole = math.floor(n * 10 + 0.5) / 10
    if whole == math.floor(whole) then return StoryEngine.intToString(whole) end
    return tostring(whole)
end

local function resName(r)
    return getText("IGUI_StoryEngine_Life_Res_" .. tostring(r))
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
    local v = data.points and getText("IGUI_StoryEngine_Project_Points", fmt(data.points))
        or (resName(data.resource) .. "  " .. getText("IGUI_StoryEngine_Trade_Value", fmt(data.value)))
    local w = getTextManager():MeasureStringX(UIFont.Small, v)
    self:drawText(v, self:getWidth() - w - 24, y + 5, 0.75, 0.85, 0.6, 1, UIFont.Small)
    return y + h
end

function StoryEngineDonateWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local th = self:titleBarHeight()
    local rh = self:resizeWidgetHeight()
    local listH = self.height - th - rh - PAD * 4 - BUTTON_H - FONT_H * 2
    self.list = ISScrollingListBox:new(PAD, th + PAD, self.width - PAD * 2, listH)
    self.list:initialise()
    self.list:instantiate()
    self.list.itemheight = ROW_H
    self.list.font = UIFont.Small
    self.list.drawBorder = true
    self.list.doDrawItem = drawRow
    self.list:setOnMouseDownFunction(self, StoryEngineDonateWindow.onToggle)
    self.list:setAnchorRight(true)
    self.list:setAnchorBottom(true)
    self:addChild(self.list)

    local by = self.height - rh - PAD - BUTTON_H
    self.sendButton = ISButton:new(self.width - PAD - 140, by, 140, BUTTON_H, getText("IGUI_StoryEngine_Life_Send"), self,
        StoryEngineDonateWindow.onSend)
    self.sendButton:initialise()
    self.sendButton:setAnchorTop(false)
    self.sendButton:setAnchorBottom(true)
    self.sendButton:setAnchorLeft(false)
    self.sendButton:setAnchorRight(true)
    self:addChild(self.sendButton)
end

-- 고른 물건의 자원별 가치 합과 전체 합
function StoryEngineDonateWindow:totals()
    local byRes, total, points = {}, 0, 0
    for _, row in ipairs(self.list.items) do
        local d = row.item
        if d.selected then
            byRes[d.resource] = (byRes[d.resource] or 0) + d.value
            total = total + d.value
            points = points + (d.points or 0)
        end
    end
    return byRes, total, points
end

function StoryEngineDonateWindow:render()
    ISCollapsableWindow.render(self)
    local byRes, total, points = self:totals()
    local gains = {}
    for _, r in ipairs(Value.RESOURCES) do
        if byRes[r] then
            gains[#gains + 1] = resName(r) .. " +" .. StoryEngine.intToString(math.min(CAP, math.floor(byRes[r] * MULT + 0.5)))
        end
    end
    local trust = 0
    for _, s in ipairs(TRUST_STEPS) do
        if total >= s[1] then
            trust = s[2]
            break
        end
    end
    local y = self.sendButton:getY() - FONT_H * 2 - PAD
    local line1 = #gains > 0 and table.concat(gains, ", ") or getText("IGUI_StoryEngine_Life_PickItems")
    if self.mode == "project" and self.npc.project then
        -- 프로젝트 지원: 점수는 물건마다 Value.projectItem (서버와 같은 규칙)
        local pts = math.min(PROJECT_CAP, math.floor(points + 0.5))
        local goal = self.npc.project.goal or 1000
        local now = math.min(goal, (self.npc.project.points or 0) + pts)
        line1 = getText("IGUI_StoryEngine_Project_Preview", StoryEngine.intToString(pts), StoryEngine.intToString(now),
            StoryEngine.intToString(goal))
        if points >= PROJECT_CAP then line1 = line1 .. "  " .. getText("IGUI_StoryEngine_Project_CapReached") end
    end
    self:drawText(line1, PAD, y, 0.8, 0.9, 0.7, 1, UIFont.Small)
    self:drawText(getText("IGUI_StoryEngine_Life_Preview", fmt(total), "+" .. StoryEngine.intToString(trust)),
        PAD, y + FONT_H + 2, trust > 0 and 0.5 or 0.8, trust > 0 and 0.9 or 0.8, trust > 0 and 0.5 or 0.8, 1, UIFont.Small)
    self.sendButton:setEnable(total > 0)
end

function StoryEngineDonateWindow:onToggle(data)
    if not data then return end
    -- 프로젝트: 한 번에 최대 점수를 채웠으면 더 고르지 못한다 (고른 것을 빼는 건 된다)
    if self.mode == "project" and not data.selected then
        local _, _, points = self:totals()
        if points >= PROJECT_CAP then return end
    end
    data.selected = not data.selected
end

function StoryEngineDonateWindow:onSend()
    local ids = {}
    for _, row in ipairs(self.list.items) do
        if row.item.selected then ids[#ids + 1] = row.item.id end
    end
    local player = getSpecificPlayer(0)
    if player and #ids > 0 then
        StoryEngine.Net.toServer(player, "lifeDonate", { faction = self.npc.id, items = ids, mode = self.mode })
    end
    self:close()
end

function StoryEngineDonateWindow:fill()
    self.list:clear()
    local player = getSpecificPlayer(0)
    if not player then return end
    if self.mode == "project" and self.npc.project then
        -- 프로젝트: NPC 마다 받는 물건 규칙 (듀이 차량 부품·정비 도구, 빅 무엇이든 x0.8), 점수 높은 것부터
        local pr = self.npc.project
        local rows = Value.projectItems(player, { res = pr.res, accept = pr.accept, mult = pr.mult })
        table.sort(rows, function(a, b) return a.points > b.points end)
        for i, r in ipairs(rows) do
            if i > 300 then break end
            local data = { id = r.item:getID(), name = r.item:getDisplayName(), resource = "project", value = r.value,
                           points = r.points, selected = false }
            self.list:addItem(data.name, data)
        end
        return
    end
    local rows = Value.donatableItems(player)
    table.sort(rows, function(a, b)
        if a.resource ~= b.resource then return a.resource < b.resource end
        return a.value > b.value
    end)
    for i, r in ipairs(rows) do
        if i > 300 then break end
        local data = { id = r.item:getID(), name = r.item:getDisplayName(), resource = r.resource, value = r.value,
                       selected = false }
        self.list:addItem(data.name, data)
    end
end

function StoryEngineDonateWindow:close()
    StoryEngineDonateWindow.instance = nil
    self:removeFromUIManager()
end

function StoryEngineDonateWindow:new(x, y, w, h, npc, mode)
    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.npc = npc
    o.mode = mode
    o.title = getText(mode == "project" and "IGUI_StoryEngine_Project_Title" or "IGUI_StoryEngine_Life_DonateTitle",
        StoryEngine.Factions.name(npc.id))
    o.resizable = true
    o.minimumWidth = 380
    o.minimumHeight = 320
    return o
end

-- mode: nil = 생활 지원, "project" = 장기 프로젝트 지원
function StoryEngineDonateWindow.open(npc, mode)
    if StoryEngineDonateWindow.instance then StoryEngineDonateWindow.instance:close() end
    local width, height = 460, 500
    local x = (getCore():getScreenWidth() - width) / 2 + 60
    local y = (getCore():getScreenHeight() - height) / 2
    local w = StoryEngineDonateWindow:new(x, y, width, height, npc, mode)
    w:initialise()
    w:addToUIManager()
    w:fill()
    StoryEngineDonateWindow.instance = w
end
