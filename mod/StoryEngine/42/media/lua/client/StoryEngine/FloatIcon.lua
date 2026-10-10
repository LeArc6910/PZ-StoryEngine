-- 화면에 떠 있는 작은 아이콘 (2026-10-07 사용자 요청).
--
-- StoryEngineFloatBar: 왼쪽 점 손잡이로 끌어 옮기는 반투명 막대 (특기 아이콘 QuickSpecialty.lua 도 이것을 쓴다).
--   옮기면 자리를 windows.txt 의 saveName 으로 기억한다.
-- StoryEngineMainIcon: 누르면 메인 창을 열고, 열려 있으면 닫는다. 창이 닫혀 있는 동안 새로 온 NPC 무전 수를
--   주황 숫자로 보여 주고 창을 열면 지운다. 놓치면 NPC 를 잃을 수 있는 퀘스트(q.risk, 서버 Fate.questRisk)가
--   열려 있으면 "!" 와 붉은 주황 글자 (2026-10-10), 새로 생겼을 때는 누르면 퀘스트 탭이 열린다.
--   기본 자리는 특기 아이콘 바로 위(화면 오른쪽 y=270),
--   우클릭 "무전 아이콘 숨기기/보이기"(StoryEngine/ui.txt mainIcon, 기본 보임).

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "StoryEngine/Core"
require "StoryEngine/UIUtil"

local UI = StoryEngine.UI

StoryEngineFloatBar = ISPanel:derive("StoryEngineFloatBar")
local B = StoryEngineFloatBar
B.GRIP = 10
B.HEAD_H = 22

function B:new(x, y, w, h, saveName)
    local o = ISPanel.new(self, x, y, w, h)
    o.moveWithMouse = true
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.4 }
    o.borderColor = { r = 0.45, g = 0.45, b = 0.45, a = 0.5 }
    o.saveName = saveName
    return o
end

-- 머리 버튼 (손잡이 오른쪽)
function B:makeHead(onClick, tip)
    local head = ISButton:new(B.GRIP, 0, 60, B.HEAD_H, "", self, onClick)
    head:initialise()
    head:setBackgroundRGBA(0.08, 0.08, 0.08, 0.5)
    head:setBorderRGBA(0, 0, 0, 0)
    head.tooltip = tip
    self:addChild(head)
    return head
end

-- 왼쪽 손잡이 (점 두 줄)
function B:render()
    ISPanel.render(self)
    for yy = 5, B.HEAD_H - 6, 4 do
        self:drawRect(3, yy, 2, 2, 0.7, 0.75, 0.75, 0.75)
        self:drawRect(6, yy, 2, 2, 0.7, 0.75, 0.75, 0.75)
    end
end

function B:onMouseUp(x, y)
    local moved = self.moving
    ISPanel.onMouseUp(self, x, y)
    if moved and self.saveName then UI.saveWindow(self.saveName, self) end
end

function B:onMouseUpOutside(x, y)
    local moved = self.moving
    ISPanel.onMouseUpOutside(self, x, y)
    if moved and self.saveName then UI.saveWindow(self.saveName, self) end
end

-- 너비를 바꿀 때 오른쪽 끝을 그대로 둔다 (2026-10-09 사용자 요청: 펼치면 왼쪽으로 늘어나게, 화면 오른쪽에 붙여 쓰기)
function B:setBarWidth(w)
    local right = self:getX() + self:getWidth()
    self:setWidth(w)
    self:setX(right - w)
end

-- 저장된 자리 (없으면 기본 자리). 오른쪽 끝을 기억한 자리에 맞춘다: 처음 너비가 B.START_W 이므로 x = 오른쪽 끝 - B.START_W
B.START_W = 70
function B.placeOf(saveName, defX, defY)
    local x, y, w = UI.windowRect(saveName, B.START_W, B.HEAD_H, 40, B.HEAD_H)
    if not UI.windows or not UI.windows[saveName] then return defX, defY end
    return x + (w or B.START_W) - B.START_W, y
end

-- ---------------------------------------------------------------- 메인 창 아이콘

StoryEngineMainIcon = StoryEngineFloatBar:derive("StoryEngineMainIcon")
local M = StoryEngineMainIcon
M.unread = 0
M.critical = 0          -- 놓치면 NPC 를 잃을 수 있는 열린 퀘스트 수
M.criticalSeen = 0      -- 그중 이미 퀘스트 탭을 열어 본 수
M.synced = false        -- 퀘스트 목록을 한 번이라도 받았는가

function M:new(x, y)
    return StoryEngineFloatBar.new(self, x, y, B.START_W, B.HEAD_H, "mainIcon")
end

function M:createChildren()
    self.head = self:makeHead(M.onHead, getText("IGUI_StoryEngine_Float_MainTip"))
    self:refresh()
end

function M:onHead()
    if StoryEngineMainWindow and StoryEngineMainWindow.instance then
        StoryEngineMainWindow.instance:close()
    elseif StoryEngineMainWindow then
        -- 새로 생긴 중요한 퀘스트가 있으면 퀘스트 탭부터
        StoryEngineMainWindow.open(M.critical > M.criticalSeen and "quests" or "radio")
        M.criticalSeen = M.critical
    end
    M.unread = 0
    self:refresh()
end

-- 창이 열려 있으면 숫자를 지운다
function M:prerender()
    ISPanel.prerender(self)
    if M.unread > 0 and StoryEngineMainWindow and StoryEngineMainWindow.instance then
        M.unread = 0
        self:refresh()
    end
end

function M:refresh()
    if not self.head then return end
    local title = getText("IGUI_StoryEngine_Float_Main")
    if M.unread > 0 then title = title .. " " .. StoryEngine.intToString(math.min(M.unread, 99)) end
    if M.critical > 0 then title = title .. " !" end
    self.head:setTitle(title)
    if M.critical > 0 then
        self.head.textColor = { r = 1.0, g = 0.5, b = 0.3, a = 1 }
        self.head.tooltip = getText("IGUI_StoryEngine_Float_MainRiskTip", StoryEngine.intToString(M.critical))
    elseif M.unread > 0 then
        self.head.textColor = { r = 0.95, g = 0.75, b = 0.4, a = 1 }
        self.head.tooltip = getText("IGUI_StoryEngine_Float_MainTip")
    else
        self.head.textColor = { r = 0.9, g = 0.9, b = 0.88, a = 1 }
        self.head.tooltip = getText("IGUI_StoryEngine_Float_MainTip")
    end
    local width = getTextManager():MeasureStringX(UIFont.Small, title) + 16
    self.head:setWidth(width)
    self:setBarWidth(B.GRIP + width)
end

-- 새 무전 (Client.handlers.radioMessage 가 새 메시지일 때 부른다). NPC 말만 센다
function M.onRadio(msg)
    if not msg or msg.from ~= "npc" then return end
    if StoryEngineMainWindow and StoryEngineMainWindow.instance then return end
    M.unread = M.unread + 1
    if M.instance then M.instance:refresh() end
end

-- 퀘스트 목록을 받았다 (Client.handlers.questList): 놓치면 NPC 를 잃을 수 있는 열린 퀘스트를 센다
function M.onQuests(quests)
    local n = 0
    for _, q in ipairs(quests or {}) do
        if q.risk then n = n + 1 end
    end
    M.synced = true
    M.critical = n
    if M.criticalSeen > n then M.criticalSeen = n end
    if M.instance then M.instance:refresh() end
end

function M.show()
    local icon = M.instance
    if not icon then
        local x, y = B.placeOf("mainIcon", getCore():getScreenWidth() - 130, 270)
        icon = M:new(x, y)
        icon:initialise()
        icon:addToUIManager()
        M.instance = icon
    end
    icon:setVisible(true)
    icon:refresh()
    UI.setPref("mainIcon", "1")
end

function M.hide()
    local icon = M.instance
    if not icon then return end
    UI.saveWindow("mainIcon", icon)
    M.instance = nil
    icon:removeFromUIManager()
    UI.setPref("mainIcon", "0")
end

function M.toggle()
    if M.instance then M.hide() else M.show() end
end

Events.OnGameStart.Add(function()
    if UI.pref("mainIcon") ~= "0" then pcall(M.show) end
end)

-- 창을 열지 않아도 "!" 가 맞도록 퀘스트 목록을 받아 둔다: 처음 받을 때까지 게임 10분마다, 그 뒤로는 1시간마다
-- (자원 고갈처럼 퀘스트 상태가 안 바뀌어도 달라지는 경우가 있다)
local ticks = 0
Events.EveryTenMinutes.Add(function()
    if not M.instance then return end
    ticks = ticks + 1
    if M.synced and ticks % 6 ~= 0 then return end
    local player = getPlayer()
    if player and StoryEngine.Net then pcall(StoryEngine.Net.toServer, player, "questList", {}) end
end)
