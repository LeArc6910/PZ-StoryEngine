-- 간소화 무전 창과 단축키 (2026-10-07 사용자 요청).
--
-- 간소화 창(StoryEngineMiniRadio): 미니맵처럼 작게 띄워 두고, 어느 채널이든 새로 오간 무전(NPC 말·플레이어 말)만
-- 시간순으로 보여 준다. 다른 기능은 큰 창에서. [큰 창] 버튼은 마지막 무전의 채널로 큰 창을 연다.
-- 반투명, 크기·위치 기억(UI.windowRect "mini"), 켜 둔 채 게임을 끄면 다음에도 켜진다(StoryEngine/ui.txt).
--
-- 단축키 (바닐라 B42 모드 옵션 PZAPI.ModOptions, 옵션 화면의 "모드" 탭에서 바꿀 수 있다):
--   큰 창 열기·닫기 기본 K, 간소화 무전 창 켜기·끄기 기본 ; (세미콜론). 채팅이나 무전 입력 칸에 글을 쓰는 중에는 무시

require "ISUI/ISCollapsableWindow"
require "ISUI/ISRichTextPanel"
require "ISUI/ISButton"
require "StoryEngine/Core"
require "StoryEngine/UIUtil"
require "StoryEngine/Factions"

local UI = StoryEngine.UI
local Factions = StoryEngine.Factions

StoryEngineMiniRadio = ISCollapsableWindow:derive("StoryEngineMiniRadio")
StoryEngineMiniRadio.MAX = 40
StoryEngineMiniRadio.feed = {}
StoryEngineMiniRadio.STATE_FILE = "StoryEngine/ui.txt"

local function line(entry)
    local m, fid = entry.msg, entry.faction
    local clock = "[" .. tostring(m.clock or "") .. "] "
    if m.from == "npc" then
        local who = Factions.name(m.npc or fid)
        if m.npc and fid == "open" then who = who .. " (" .. Factions.name("open") .. ")" end
        return " <RGB:0.95,0.75,0.4> " .. UI.escape(clock .. who .. ": ")
            .. " <RGB:0.92,0.92,0.88> " .. UI.escape(UI.textOf(m)) .. " <LINE> "
    elseif m.from == "player" then
        return " <RGB:0.55,0.75,1> " .. UI.escape(clock .. tostring(m.name or "?") .. " > " .. Factions.name(fid) .. ": ")
            .. " <RGB:0.8,0.8,0.8> " .. UI.escape(UI.textOf(m)) .. " <LINE> "
    end
    return nil
end
StoryEngineMiniRadio.line = line

-- 무전 한 줄이 들어왔다 (Client.handlers.radioMessage 가 새 메시지일 때 부른다). 대화만 담는다
function StoryEngineMiniRadio.push(fid, msg)
    if not msg or (msg.from ~= "npc" and msg.from ~= "player") then return end
    local feed = StoryEngineMiniRadio.feed
    feed[#feed + 1] = { faction = fid, msg = msg }
    while #feed > StoryEngineMiniRadio.MAX do table.remove(feed, 1) end
    local w = StoryEngineMiniRadio.instance
    if w then w:refresh() end
end

function StoryEngineMiniRadio:createChildren()
    ISCollapsableWindow.createChildren(self)
    local th = self:titleBarHeight()
    local rh = self:resizeWidgetHeight()
    self.text = ISRichTextPanel:new(0, th, self.width, self.height - th - rh)
    self.text:initialise()
    self.text.autosetheight = false
    self.text.clip = true
    self.text.marginLeft = 6
    self.text.marginRight = 6
    self.text.marginTop = 4
    self.text.background = false
    self.text:addScrollBars()
    self.text:setAnchorRight(true)
    self.text:setAnchorBottom(true)
    self:addChild(self.text)
    local bw = 60
    self.openButton = ISButton:new(self.width - bw - 22, 1, bw, th - 2, getText("IGUI_StoryEngine_Mini_Open"), self,
        StoryEngineMiniRadio.onOpen)
    self.openButton:initialise()
    self.openButton:setAnchorLeft(false)
    self.openButton:setAnchorRight(true)
    self.openButton.tooltip = getText("IGUI_StoryEngine_Mini_OpenTip")
    self:addChild(self.openButton)
    self:refresh()
end

function StoryEngineMiniRadio:onOpen()
    local last = StoryEngineMiniRadio.feed[#StoryEngineMiniRadio.feed]
    if last and StoryEngine.Cache then StoryEngine.Cache.faction = last.faction end
    if StoryEngineMainWindow then StoryEngineMainWindow.open("radio") end
end

function StoryEngineMiniRadio:refresh()
    if not self.text then return end
    local parts = {}
    for _, e in ipairs(StoryEngineMiniRadio.feed) do
        local ok, s = pcall(line, e)
        if ok and s then parts[#parts + 1] = s end
    end
    if #parts == 0 then
        parts[1] = " <RGB:0.6,0.6,0.6> " .. UI.escape(getText("IGUI_StoryEngine_Mini_Empty"))
    end
    self.text:setText(table.concat(parts))
    self.text:paginate()
    local extra = self.text:getScrollHeight() - self.text:getHeight()
    self.text:setYScroll(extra > 0 and -extra or 0)
end

function StoryEngineMiniRadio:close()
    StoryEngineMiniRadio.hide()
end

function StoryEngineMiniRadio:new(x, y, w, h)
    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.title = getText("IGUI_StoryEngine_Mini_Title")
    o.resizable = true
    o.minimumWidth = 220
    o.minimumHeight = 90
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.45 }
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 0.5 }
    return o
end

local function saveState(open)
    pcall(function()
        local wr = getFileWriter(StoryEngineMiniRadio.STATE_FILE, true, false)
        if not wr then return end
        wr:write("miniRadio=" .. (open and "1" or "0") .. "\n")
        wr:close()
    end)
end

local function loadState()
    local open = false
    pcall(function()
        local r = getFileReader(StoryEngineMiniRadio.STATE_FILE, false)
        if not r then return end
        local l = r:readLine()
        while l do
            if string.match(l, "^miniRadio=1") then open = true end
            l = r:readLine()
        end
        r:close()
    end)
    return open
end

function StoryEngineMiniRadio.show()
    local w = StoryEngineMiniRadio.instance
    if not w then
        local sw = getCore():getScreenWidth()
        local x, y, width, height = UI.windowRect("mini", 380, 170, 220, 90)
        if not UI.windows or not UI.windows.mini then x, y = sw - width - 30, 120 end
        w = StoryEngineMiniRadio:new(x, y, width, height)
        w:initialise()
        w:addToUIManager()
        StoryEngineMiniRadio.instance = w
    end
    w:setVisible(true)
    w:refresh()
    saveState(true)
end

function StoryEngineMiniRadio.hide()
    local w = StoryEngineMiniRadio.instance
    if not w then return end
    UI.saveWindow("mini", w)
    StoryEngineMiniRadio.instance = nil
    w:removeFromUIManager()
    saveState(false)
end

function StoryEngineMiniRadio.toggle()
    if StoryEngineMiniRadio.instance then StoryEngineMiniRadio.hide() else StoryEngineMiniRadio.show() end
end

-- ---------------------------------------------------------------- 단축키 (PZAPI.ModOptions)

StoryEngineMiniRadio.options = nil
if PZAPI and PZAPI.ModOptions and PZAPI.ModOptions.create then
    local ok, opts = pcall(function()
        local o = PZAPI.ModOptions:create("StoryEngine", getText("IGUI_StoryEngine_Keys_Title"))
        o:addKeyBind("openWindow", getText("IGUI_StoryEngine_Keys_Open"), Keyboard.KEY_K, getText("IGUI_StoryEngine_Keys_OpenTip"))
        o:addKeyBind("miniRadio", getText("IGUI_StoryEngine_Keys_Mini"), Keyboard.KEY_SEMICOLON,
            getText("IGUI_StoryEngine_Keys_MiniTip"))
        return o
    end)
    if ok then StoryEngineMiniRadio.options = opts end
end

local function keyOf(id, default)
    local o = StoryEngineMiniRadio.options
    local opt = o and o:getOption(id)
    local ok, v = pcall(function() return opt and opt:getValue() end)
    v = ok and tonumber(v) or nil
    if v == nil then return default end
    return v
end

-- 글을 쓰는 중인가 (바닐라 채팅, 우리 무전 입력 칸)
local function typing()
    if ISChat and ISChat.focused then return true end
    local main = StoryEngineMainWindow and StoryEngineMainWindow.instance
    local radio = main and main.panels and main.panels.radio
    local entry = radio and radio.entry
    if entry then
        local ok, f = pcall(function() return entry:isFocused() end)
        if ok and f then return true end
    end
    return false
end

function StoryEngineMiniRadio.onKey(key)
    if not key or key <= 0 or typing() then return end
    if not getPlayer() then return end
    if key == keyOf("openWindow", Keyboard.KEY_K) then
        if StoryEngineMainWindow and StoryEngineMainWindow.instance then
            StoryEngineMainWindow.instance:close()
        elseif StoryEngineMainWindow then
            StoryEngineMainWindow.open("radio")
        end
    elseif key == keyOf("miniRadio", Keyboard.KEY_SEMICOLON) then
        StoryEngineMiniRadio.toggle()
    end
end

Events.OnKeyPressed.Add(StoryEngineMiniRadio.onKey)
Events.OnGameStart.Add(function()
    if loadState() then pcall(StoryEngineMiniRadio.show) end
end)
