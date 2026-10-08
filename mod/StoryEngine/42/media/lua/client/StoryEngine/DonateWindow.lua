-- 물자 지원 창 (거점 탭). 인벤토리(가방 속까지)에서 NPC 가 받는 물건을 골라 보낸다.
-- 물건 -> 자원 분류와 가치는 shared/StoryEngine/Value.lua, 서버(Life.donate)가 같은 표로 다시 검증한다.
-- 미리보기: 자원별 증가(가치 x2, 자원당 최대 40)와 신뢰도(가치 5/15/30 이상 +1/+2/+3). 서버 값과 같은 규칙.

if isServer() then return end

require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISButton"
require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/UIUtil"
require "StoryEngine/Value"
require "StoryEngine/Factions"
require "StoryEngine/Tuning"

local Value = StoryEngine.Value

local FONT_H = getTextManager():getFontHeight(UIFont.Small)
local PAD = 8
local BUTTON_H = FONT_H + 12
local ROW_H = FONT_H + 10
local MULT, CAP = 2, 40
local TRUST_STEPS = { { 30, 3 }, { 15, 2 }, { 5, 1 } }
-- 프로젝트 지원 3일 통의 최대 점수 (서버 Projects.DONATE_CAP, 샌드박스 ProjectDonateCap)
local function projectCap()
    return math.max(10, math.floor(StoryEngine.Tuning.num("ProjectDonateCap")))
end

-- 이 통에 남은 한도 (서버 Life.donateStatus, 거점 목록의 npc.donate). 없으면 새 통
local function windowOf(npc)
    local d = npc and npc.donate or {}
    local res = {}
    for _, r in ipairs(Value.RESOURCES) do res[r] = (d.res or {})[r] or CAP end
    return { res = res, points = d.points or projectCap(), value = d.value or 0, trust = d.trust or 0 }
end

local function trustStep(value)
    for _, s in ipairs(TRUST_STEPS) do
        if value >= s[1] then return s[2] end
    end
    return 0
end

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
    local win = windowOf(self.npc)
    local gains = {}
    for _, r in ipairs(Value.RESOURCES) do
        if byRes[r] then
            gains[#gains + 1] = resName(r) .. " +" .. StoryEngine.intToString(math.min(win.res[r], math.floor(byRes[r] * MULT + 0.5)))
                .. " / " .. StoryEngine.intToString(win.res[r])
        end
    end
    -- 신뢰도는 이 통에서 낸 가치 합으로 단계마다 한 번씩 (나눠 내도 같다)
    local trust = math.max(0, trustStep(win.value + total) - win.trust)
    local y = self.sendButton:getY() - FONT_H * 2 - PAD
    local line1 = #gains > 0 and table.concat(gains, ", ") or getText("IGUI_StoryEngine_Life_PickItems")
    if self.mode == "project" and self.npc.project then
        -- 프로젝트 지원: 점수는 물건마다 Value.projectItem (서버와 같은 규칙)
        local pts = math.min(win.points, math.floor(points + 0.5))
        local goal = self.npc.project.goal or 1000
        local now = math.min(goal, (self.npc.project.points or 0) + pts)
        line1 = getText("IGUI_StoryEngine_Project_Preview", StoryEngine.intToString(pts), StoryEngine.intToString(now),
            StoryEngine.intToString(goal)) .. "  " .. getText("IGUI_StoryEngine_Project_WindowLeft", StoryEngine.intToString(win.points))
        if points >= win.points then line1 = line1 .. "  " .. getText("IGUI_StoryEngine_Project_CapReached") end
    end
    self:drawText(line1, PAD, y, 0.8, 0.9, 0.7, 1, UIFont.Small)
    -- 개인 모드: 지원으로 오르는 것은 내 신뢰 (3일 통도 사람마다)
    local previewKey = (self.npc and self.npc.personalMode) and "IGUI_StoryEngine_Life_PreviewPersonal" or "IGUI_StoryEngine_Life_Preview"
    local line2 = getText(previewKey, fmt(total), "+" .. StoryEngine.intToString(trust))
    if win.value > 0 then line2 = line2 .. "  " .. getText("IGUI_StoryEngine_Life_WindowSoFar", fmt(win.value)) end
    self:drawText(line2, PAD, y + FONT_H + 2, trust > 0 and 0.5 or 0.8, trust > 0 and 0.9 or 0.8, trust > 0 and 0.5 or 0.8, 1, UIFont.Small)
    self.sendButton:setEnable(total > 0)
end

function StoryEngineDonateWindow:onToggle(data)
    if not data then return end
    -- 같은 물건은 한 번에 Value.SAME_ITEM_CAP 개까지 (서버도 넘는 것은 가져가지 않는다)
    if not data.selected and data.ft then
        local same = 0
        for _, row in ipairs(self.list.items) do
            if row.item.selected and row.item.ft == data.ft then same = same + 1 end
        end
        if same >= Value.SAME_ITEM_CAP then return end
    end
    -- 이 통의 한도를 채웠으면 더 고르지 못한다 (고른 것을 빼는 건 된다, 서버도 넘는 물건은 가져가지 않는다)
    if not data.selected then
        local win = windowOf(self.npc)
        local byRes, _, points = self:totals()
        if self.mode == "project" then
            if points >= win.points then return end
        elseif data.resource and (byRes[data.resource] or 0) * MULT >= (win.res[data.resource] or 0) then
            return
        end
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
                           points = r.points, selected = false, ft = r.item:getFullType() }
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
                       selected = false, ft = r.item:getFullType() }
        self.list:addItem(data.name, data)
    end
end

function StoryEngineDonateWindow:close()
    StoryEngine.UI.saveWindow("donate", self)
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
    local x, y, width, height = StoryEngine.UI.windowRect("donate", 540, 560, 380, 300)
    local w = StoryEngineDonateWindow:new(x, y, width, height, npc, mode)
    w:initialise()
    w:addToUIManager()
    w:fill()
    StoryEngineDonateWindow.instance = w
end
