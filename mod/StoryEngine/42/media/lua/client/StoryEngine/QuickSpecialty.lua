-- NPC 특기 퀵 메뉴 (2026-10-07 사용자 요청): 위급할 때 거점 탭까지 가지 않고 바로 특기를 부른다.
--
-- 특기 아이콘 (StoryEngineQuickDock, 같은 날 추가): 화면에 늘 떠 있는 작은 버튼 "특기 N"(N = 지금 바로 쓸 수 있는 NPC 수).
-- 누르거나 단축키(모드 옵션 "특기 아이콘", 기본 ' 작은따옴표)를 누르면 아래로 NPC 한 줄씩 펼쳐진다:
-- 왼쪽 이름·구간(*), 오른쪽 상태(바로 / N시간 / 불가). 쓸 수 없는 줄은 회색, 줄마다 이유 툴팁.
-- 줄을 누르면 특기를 부르고 접힌다(레이는 보급 받을 NPC 메뉴). 사망·연락 끊김 NPC는 줄을 만들지 않는다.
-- 왼쪽 손잡이를 끌어 옮기고(StoryEngineFloatBar, FloatIcon.lua) 자리는 windows.txt "quick" 에 기억, 숨기기·보이기는 우클릭 메뉴(StoryEngine/ui.txt quickDock).
-- 상태는 거점 목록(Cache.life). 펼쳐 있으면 게임 10분마다, 접혀 있으면 1시간마다 새로 받는다.
--
-- 우클릭 메뉴 "특기 빠른 사용" 하위 메뉴(Q.fill)도 그대로 있다.
--
-- 2차 특기 아이콘 (StoryEngineQuickDock2, 2026-10-09): 같은 모양의 "2차 N". 2차 장기 프로젝트가 끝난 NPC 가 하나라도
-- 생기면 저절로 나타난다(우클릭으로 숨기면 다시 안 나옴, ui.txt quickDock2). 줄을 누르면 그 2차 특기를 쓰고,
-- 아직 고르지 않았거나 약 조제면 거점 탭과 같은 메뉴(StoryEngineLifePanel.fillSpec2)를 연다. 기본 자리는 무전 아이콘 위.

require "ISUI/ISContextMenu"
require "ISUI/ISToolTip"
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/UIUtil"
require "StoryEngine/Factions"
require "StoryEngine/FloatIcon"

local UI = StoryEngine.UI
local Net = StoryEngine.Net
local Factions = StoryEngine.Factions

StoryEngineQuickSpecialty = {}
local Q = StoryEngineQuickSpecialty
Q.pending = false

local RESOURCES = { "food", "medical", "safety", "morale" }

local function cache() return StoryEngine.Cache or {} end
local function num(n) return StoryEngine.intToString(n or 0) end

local function send(command, args)
    local p = getPlayer()
    if p then Net.toServer(p, command, args or {}) end
end

local function stars(n)
    local spec = n.spec or {}
    if (spec.tier or 0) > 0 then return " " .. string.rep("*", spec.tier) end
    return ""
end

local function label(n)
    local spec = n.spec or {}
    local text = getText("IGUI_StoryEngine_Spec_Name_" .. n.id) .. " - " .. UI.npcName(n.id) .. stars(n)
    if n.fate then
        text = text .. "  (" .. getText("IGUI_StoryEngine_Fate_" .. tostring(n.fate)) .. ")"
    elseif spec.reason == "cooldown" then
        text = text .. "  (" .. getText("IGUI_StoryEngine_Quick_Wait", num(spec.wait)) .. ")"
    elseif spec.reason then
        text = text .. "  (" .. getText("IGUI_StoryEngine_Quick_No") .. ")"
    else
        text = text .. "  (" .. getText("IGUI_StoryEngine_Quick_Ready") .. ")"
    end
    return text
end

-- 특기 설명 + 지금 못 쓰는 이유 (툴팁)
local function description(n)
    local desc = getText("IGUI_StoryEngine_Spec_Desc_" .. n.id)
    if n.spec and n.spec.reason then
        desc = getText("IGUI_StoryEngine_Spec_Error_" .. tostring(n.spec.reason), num(n.spec.wait)) .. " <LINE> " .. desc
    end
    -- 개인 모드: 특기 구간은 내 신뢰로 정한다
    local pair = UI.trustPairText(n.id, n)
    if pair then desc = desc .. " <LINE> " .. pair .. " <LINE> " .. getText("IGUI_StoryEngine_Trust_BenefitTip") end
    return desc
end

local function usable(n)
    return n.spec ~= nil and n.spec.reason == nil and not n.fate
end

local function tooltipFor(menu, option, text)
    local tip = ISToolTip:new()
    tip:initialise()
    tip:setVisible(false)
    tip.description = text
    option.toolTip = tip
end

-- 레이 보급을 받을 NPC 고르기 (가장 부족한 자원 표시). after 는 고른 뒤 부른다
function Q.fillRay(menu, life, after)
    for _, other in ipairs(life) do
        if other.id ~= "ray" and not other.fate then
            local low, value = nil, 101
            for _, r in ipairs(RESOURCES) do
                local v = (other.res or {})[r] or 0
                if v < value then low, value = r, v end
            end
            local text = Factions.name(other.id)
            if low then
                text = text .. "  (" .. getText("IGUI_StoryEngine_Life_Res_" .. low) .. " " .. num(value) .. ")"
            end
            menu:addOption(text, other.id, function(target)
                send("specialtyRequest", { faction = "ray", target = target })
                if after then after() end
            end)
        end
    end
end

-- 메뉴 채우기 (menu 는 ISContextMenu 또는 하위 메뉴)
function Q.fill(menu)
    local life = cache().life or {}
    if #life == 0 then
        local o = menu:addOption(getText("IGUI_StoryEngine_Quick_Loading"), nil, nil)
        o.notAvailable = true
        return
    end
    for _, n in ipairs(life) do
        if n.spec ~= nil or n.fate then
            local ok = usable(n)
            if n.id == "ray" and ok then
                local opt = menu:addOption(label(n), nil, nil)
                local sub = ISContextMenu:getNew(menu)
                menu:addSubMenu(opt, sub)
                tooltipFor(menu, opt, description(n))
                Q.fillRay(sub, life)
            else
                local opt = menu:addOption(label(n), n.id, function(f)
                    send("specialtyRequest", { faction = f })
                end)
                if not ok then opt.notAvailable = true end
                tooltipFor(menu, opt, description(n))
            end
        end
    end
end

-- 마우스 자리에 메뉴를 연다. 목록이 없으면 받은 뒤 연다
function Q.open()
    local p = getPlayer()
    if not p then return end
    send("lifeList", {})
    if #(cache().life or {}) == 0 then
        Q.pending = true
        return
    end
    Q.show()
end

function Q.show()
    Q.pending = false
    local menu = ISContextMenu.get(0, getMouseX(), getMouseY())
    menu:addOption(getText("IGUI_StoryEngine_Quick_Title"), nil, nil).notAvailable = true
    Q.fill(menu)
end

-- ---------------------------------------------------------------- 특기 아이콘

local GREEN = { r = 0.55, g = 0.95, b = 0.55 }
local WHITE = { r = 0.9, g = 0.9, b = 0.88 }
local GREY = { r = 0.5, g = 0.5, b = 0.5 }
local AMBER = { r = 0.95, g = 0.75, b = 0.4 }

-- 아이콘에 펼칠 줄 (살아 있고 특기가 있는 NPC)
function Q.rowsOf(life)
    local rows = {}
    for _, n in ipairs(life or {}) do
        if n.spec ~= nil and not n.fate then
            local ok = usable(n)
            local right, color
            if ok then
                right, color = getText("IGUI_StoryEngine_Quick_ShortReady"), GREEN
            elseif n.spec.reason == "cooldown" then
                right, color = getText("IGUI_StoryEngine_Quick_ShortWait", num(n.spec.wait)), AMBER
            else
                right, color = getText("IGUI_StoryEngine_Quick_ShortNo"), GREY
            end
            rows[#rows + 1] = {
                id = n.id, usable = ok, left = UI.npcName(n.id) .. stars(n), right = right, color = color,
                tip = getText("IGUI_StoryEngine_Spec_Name_" .. n.id) .. stars(n) .. " <LINE> " .. description(n),
            }
        end
    end
    return rows
end

function Q.readyCount(rows)
    local n = 0
    for _, r in ipairs(rows) do if r.usable then n = n + 1 end end
    return n
end

-- 줄 하나 (이름은 왼쪽, 상태는 오른쪽)
StoryEngineQuickRow = ISButton:derive("StoryEngineQuickRow")

function StoryEngineQuickRow:render()
    ISButton.render(self)
    local row = self.row
    if not row then return end
    local fh = getTextManager():getFontHeight(UIFont.Small)
    local y = (self.height - fh) / 2
    local lc = row.usable and WHITE or GREY
    self:drawText(row.left, 6, y, lc.r, lc.g, lc.b, 1, UIFont.Small)
    self:drawTextRight(row.right, self.width - 6, y, row.color.r, row.color.g, row.color.b, 1, UIFont.Small)
end

-- 손잡이·옮기기·자리 기억은 StoryEngineFloatBar (FloatIcon.lua)
StoryEngineQuickDock = StoryEngineFloatBar:derive("StoryEngineQuickDock")
local D = StoryEngineQuickDock
D.GRIP = StoryEngineFloatBar.GRIP
D.HEAD_H = StoryEngineFloatBar.HEAD_H
D.ROW_H = 20

function D:new(x, y)
    local o = StoryEngineFloatBar.new(self, x, y, StoryEngineFloatBar.START_W, D.HEAD_H, "quick")
    o.expanded = false
    o.buttons = {}
    return o
end

function D:createChildren()
    self.head = self:makeHead(D.onHead, getText(self.tipKey or "IGUI_StoryEngine_Quick_DockTip"))
    self:refresh()
end

-- 펼칠 줄 (2차 아이콘은 덮어쓴다)
function D:rows(life)
    return Q.rowsOf(life)
end

function D:onHead()
    self:setExpanded(not self.expanded)
end

function D:setExpanded(on)
    self.expanded = on and true or false
    if self.expanded then send("lifeList", {}) end
    self:refresh()
end

function D:onRow(button)
    local row = button.row
    if not row or not row.usable then return end
    if row.id == "ray" then
        local menu = ISContextMenu.get(0, getMouseX(), getMouseY())
        menu:addOption(getText("IGUI_StoryEngine_Spec_Name_ray"), nil, nil).notAvailable = true
        Q.fillRay(menu, cache().life or {}, function() self:setExpanded(false) end)
        return
    end
    send("specialtyRequest", { faction = row.id })
    self:setExpanded(false)
end

function D:refresh()
    if not self.head then return end
    local tm = getTextManager()
    local life = cache().life or {}
    local rows = self:rows(life)
    local ready = Q.readyCount(rows)
    local title = getText(self.titleKey or "IGUI_StoryEngine_Quick_Dock")
    if ready > 0 then title = title .. " " .. num(ready) end
    self.head:setTitle(title)
    local c = ready > 0 and GREEN or WHITE
    self.head.textColor = { r = c.r, g = c.g, b = c.b, a = 1 }
    if #life == 0 and self.expanded then
        rows = { { left = getText("IGUI_StoryEngine_Quick_Waiting"), right = "", color = GREY, usable = false } }
    end

    local width = tm:MeasureStringX(UIFont.Small, title) + 16
    if self.expanded then
        for _, r in ipairs(rows) do
            width = math.max(width, tm:MeasureStringX(UIFont.Small, r.left) + tm:MeasureStringX(UIFont.Small, r.right) + 26)
        end
    end
    self.head:setWidth(width)

    for i, r in ipairs(self.expanded and rows or {}) do
        local b = self.buttons[i]
        if not b then
            b = StoryEngineQuickRow:new(D.GRIP, 0, width, D.ROW_H, "", self, self.onRow)
            b:initialise()
            b:setBackgroundRGBA(0.05, 0.05, 0.05, 0.55)
            b:setBorderRGBA(0.3, 0.3, 0.3, 0.4)
            self:addChild(b)
            self.buttons[i] = b
        end
        b.row = r
        b.tooltip = r.tip
        b:setEnable(r.usable)
        b:setX(D.GRIP)
        b:setY(D.HEAD_H + 1 + (i - 1) * (D.ROW_H + 1))
        b:setWidth(width)
        b:setVisible(true)
    end
    local shown = self.expanded and #rows or 0
    for i = shown + 1, #self.buttons do
        local b = self.buttons[i]
        b:setVisible(false)
        if b.tooltipUI then
            b.tooltipUI:setVisible(false)
            b.tooltipUI:removeFromUIManager()
        end
    end
    self:setBarWidth(D.GRIP + width)
    self:setHeight(D.HEAD_H + (shown > 0 and (shown * (D.ROW_H + 1) + 1) or 0))
end

function Q.showDock()
    local d = D.instance
    if not d then
        local x, y = StoryEngineFloatBar.placeOf("quick", getCore():getScreenWidth() - 130, 300)
        d = D:new(x, y)
        d:initialise()
        d:addToUIManager()
        D.instance = d
    end
    d:setVisible(true)
    d:refresh()
    UI.setPref("quickDock", "1")
    return d
end

function Q.hideDock()
    local d = D.instance
    if not d then return end
    UI.saveWindow("quick", d)
    D.instance = nil
    d:removeFromUIManager()
    UI.setPref("quickDock", "0")
end

function Q.dockShown()
    return D.instance ~= nil
end

-- 단축키: 아이콘을 펼치거나 접는다 (숨겨져 있으면 보이고 펼친다)
function Q.toggleDock()
    if not getPlayer() then return end
    local d = D.instance
    if not d then
        d = Q.showDock()
        d:setExpanded(true)
        return
    end
    d:setExpanded(not d.expanded)
end

-- ---------------------------------------------------------------- 2차 특기 아이콘

-- 2차 특기 줄: 2차 프로젝트가 끝난 NPC 마다 (고르지 않았으면 "고르기")
function Q.rows2Of(life)
    local rows = {}
    for _, n in ipairs(life or {}) do
        local s2 = n.spec2
        if s2 and s2.unlocked and not n.fate and s2.reason ~= "off" then
            local row = { id = n.id, n = n }
            if not s2.choice then
                row.usable, row.menu = true, true
                row.left = UI.npcName(n.id)
                row.right, row.color = getText("IGUI_StoryEngine_Quick2_Pick"), AMBER
                row.tip = getText("IGUI_StoryEngine_Spec2_Tooltip_Pick")
            else
                local name = getText("IGUI_StoryEngine_Spec2_Name_" .. s2.choice)
                row.usable = s2.reason == nil
                row.menu = s2.choice == "pharmacy"
                row.left = UI.npcName(n.id) .. " - " .. name
                if row.usable then
                    row.right, row.color = getText("IGUI_StoryEngine_Quick_ShortReady"), GREEN
                elseif s2.reason == "cooldown" then
                    row.right, row.color = getText("IGUI_StoryEngine_Quick_ShortWait", num(s2.wait)), AMBER
                else
                    row.right, row.color = getText("IGUI_StoryEngine_Quick_ShortNo"), GREY
                end
                local tip = getText("IGUI_StoryEngine_Spec2_Desc_" .. s2.choice)
                if s2.active then tip = getText("IGUI_StoryEngine_Spec2_Active", num(s2.active)) .. " <LINE> " .. tip end
                if s2.reason then
                    local key = "IGUI_StoryEngine_Spec2_Error_" .. tostring(s2.reason)
                    tip = (getTextOrNull(key) and getText(key, num(s2.wait)) or tostring(s2.reason)) .. " <LINE> " .. tip
                end
                row.tip = name .. " <LINE> " .. tip
            end
            rows[#rows + 1] = row
        end
    end
    return rows
end

function Q.anyUnlocked(life)
    for _, n in ipairs(life or {}) do
        if n.spec2 and n.spec2.unlocked and not n.fate and n.spec2.reason ~= "off" then return true end
    end
    return false
end

-- 아이콘 인스턴스는 Q.dock2 에 둔다: D2.instance 로 두면 D2 에 없을 때 상속으로 특기 아이콘(D.instance)이 읽혀
-- 2차 아이콘을 숨기면 특기 아이콘이 지워졌다 (2026-10-09 인게임)
StoryEngineQuickDock2 = StoryEngineQuickDock:derive("StoryEngineQuickDock2")
local D2 = StoryEngineQuickDock2

function D2:new(x, y)
    local o = StoryEngineFloatBar.new(self, x, y, StoryEngineFloatBar.START_W, D.HEAD_H, "quick2")
    o.expanded = false
    o.buttons = {}
    o.titleKey = "IGUI_StoryEngine_Quick2_Dock"
    o.tipKey = "IGUI_StoryEngine_Quick2_DockTip"
    return o
end

function D2:rows(life)
    return Q.rows2Of(life)
end

function D2:onRow(button)
    local row = button.row
    if not row or not row.usable then return end
    local choice = row.n and row.n.spec2 and row.n.spec2.choice
    if row.menu and StoryEngineLifePanel and StoryEngineLifePanel.fillSpec2 then
        local menu = ISContextMenu.get(0, getMouseX(), getMouseY())
        StoryEngineLifePanel.fillSpec2(menu, row.n)
    elseif (choice == "artillery" or choice == "heist") and StoryEngine.Aim then
        StoryEngine.Aim.start(row.id, choice)
    else
        send("spec2Use", { faction = row.id })
    end
    self:setExpanded(false)
end

function Q.showDock2()
    local d = Q.dock2
    if not d then
        local x, y = StoryEngineFloatBar.placeOf("quick2", getCore():getScreenWidth() - 130, 240)
        d = D2:new(x, y)
        d:initialise()
        d:addToUIManager()
        Q.dock2 = d
    end
    d:setVisible(true)
    d:refresh()
    UI.setPref("quickDock2", "1")
    return d
end

function Q.hideDock2()
    local d = Q.dock2
    if not d then return end
    UI.saveWindow("quick2", d)
    Q.dock2 = nil
    d:removeFromUIManager()
    UI.setPref("quickDock2", "0")
end

function Q.dock2Shown()
    return Q.dock2 ~= nil
end

-- 거점 목록이 왔다 (Client.handlers.lifeList)
function Q.onLifeList()
    if Q.pending then Q.show() end
    if D.instance then D.instance:refresh() end
    -- 2차 특기가 처음 열리면 아이콘을 저절로 띄운다 (우클릭으로 숨겼으면 그대로)
    if not Q.dock2 and UI.pref("quickDock2") ~= "0" and Q.anyUnlocked(cache().life) then pcall(Q.showDock2) end
    if Q.dock2 then Q.dock2:refresh() end
end

-- 펼쳐 있으면 게임 10분마다, 접혀 있으면 1시간마다 상태를 새로 받는다
Q.tick = 0
Events.EveryTenMinutes.Add(function()
    local d, d2 = D.instance, Q.dock2
    if (not d and not d2) or not getPlayer() then return end
    Q.tick = Q.tick + 1
    if (d and d.expanded) or (d2 and d2.expanded) or Q.tick % 6 == 0 then send("lifeList", {}) end
end)

Events.OnGameStart.Add(function()
    if UI.pref("quickDock") ~= "0" then pcall(Q.showDock) end
    if UI.pref("quickDock2") == "1" then pcall(Q.showDock2) end
end)
