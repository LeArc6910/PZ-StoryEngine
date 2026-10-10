-- NPC 편지 (Letters.lua). 인벤토리의 StoryEngine.Letter 우클릭 "편지 읽기" -> 서버에 글을 받아 창으로 보여 준다.
-- AI 가 쓴 글이 없으면(실패) 준비된 짧은 편지 IGUI_StoryEngine_Letter_Fallback_<이유>.

if isServer() then return end

require "ISUI/ISCollapsableWindow"
require "ISUI/ISRichTextPanel"
require "StoryEngine/UIUtil"
require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Client"
require "StoryEngine/Factions"
require "StoryEngine/UIUtil"

local Net = StoryEngine.Net
local Client = StoryEngine.Client
local UI = StoryEngine.UI

local LETTER = "StoryEngine.Letter"
local CHARTER = "StoryEngine.Charter"

StoryEngineLetterWindow = ISCollapsableWindow:derive("StoryEngineLetterWindow")
StoryEngineLetterWindow.instance = nil

-- 창에 넣을 글 (서식 태그 포함)
-- 유품 수첩 (예전 유품 회수 퀘스트, 2026-10-06 없앰. 이미 받은 수첩은 계속 읽힌다): 죽은 캐릭터의 마지막 일기들
local function memorialBody(info)
    local parts = {}
    parts[#parts + 1] = " <CENTRE> <SIZE:medium> " .. UI.escape(getText("IGUI_StoryEngine_Memorial_Title", tostring(info.memorial)))
        .. " <SIZE:small> <LEFT> <LINE> <LINE> "
    local pages = info.pages or {}
    if #pages == 0 then
        parts[#parts + 1] = " <RGB:0.7,0.7,0.7> " .. UI.escape(getText("IGUI_StoryEngine_Memorial_Empty"))
    end
    for _, page in ipairs(pages) do
        local head = page.memoir and getText("IGUI_StoryEngine_Memorial_Memoir") or tostring(page.date or "")
        parts[#parts + 1] = " <RGB:0.75,0.7,0.6> " .. UI.escape(head) .. " <LINE> <RGB:0.92,0.88,0.78> "
            .. UI.escape(UI.textOf(page)) .. " <LINE> <LINE> "
    end
    return table.concat(parts)
end

-- 카운티 헌장 (서버 Era.lua): 머리말, 서명 한 줄씩, 서명하지 않은 사람, 떠났거나 죽은 사람의 빈칸
local function signerName(g)
    return StoryEngine.Factions.nameAs(tostring(g.fid), g.voice or false)
end

local function charterBody(info)
    local c = info.charter
    local day = StoryEngine.intToString(tonumber(c.day) or 0)
    local parts = {}
    parts[#parts + 1] = " <CENTRE> <SIZE:medium> "
        .. UI.escape(getText(c.formed and "IGUI_StoryEngine_Charter_Title" or "IGUI_StoryEngine_Charter_Draft"))
        .. " <SIZE:small> <LEFT> <LINE> <LINE> <RGB:0.92,0.88,0.78> "
        .. getText(c.formed and "IGUI_StoryEngine_Charter_Preamble" or "IGUI_StoryEngine_Charter_DraftPreamble", day)
        .. " <LINE> <LINE> "
    for _, g in ipairs(c.signed or {}) do
        local line = g.text
        if not line or line == "" then
            local key = "IGUI_StoryEngine_Charter_Line_" .. tostring(g.voice or g.fid)
            line = getText(UI.hasText(key) and key or "IGUI_StoryEngine_Charter_Line_default")
        end
        parts[#parts + 1] = " <RGB:0.75,0.7,0.6> " .. UI.escape(signerName(g)) .. " <LINE> <INDENT:12> <RGB:0.92,0.88,0.78> "
            .. UI.escape(line) .. " <LINE> <INDENT:0> "
    end
    for _, g in ipairs(c.unsigned or {}) do
        parts[#parts + 1] = " <RGB:0.55,0.55,0.55> "
            .. UI.escape(getText("IGUI_StoryEngine_Charter_Unsigned", signerName(g))) .. " <LINE> "
    end
    for _, g in ipairs(c.blanks or {}) do
        local key = "IGUI_StoryEngine_Charter_Blank_" .. (g.fate == "dead" and "dead" or "gone")
        parts[#parts + 1] = " <RGB:0.55,0.55,0.55> " .. UI.escape(getText(key, signerName(g))) .. " <LINE> "
    end
    if c.held then
        parts[#parts + 1] = " <LINE> <RGB:0.6,0.6,0.6> " .. UI.escape(getText("IGUI_StoryEngine_Charter_Held"))
    end
    return table.concat(parts)
end

function StoryEngineLetterWindow.body(info)
    if info.memorial then return memorialBody(info) end
    if info.charter then return charterBody(info) end
    local name = StoryEngine.Factions.nameAs(tostring(info.from), info.voice)
    local parts = {}
    if info.title and info.title ~= "" then
        parts[#parts + 1] = " <CENTRE> <SIZE:medium> " .. UI.escape(info.title) .. " <SIZE:small> <LEFT> <LINE> <LINE> "
    end
    if info.text and info.text ~= "" then
        parts[#parts + 1] = " <RGB:0.92,0.88,0.78> " .. UI.escape(info.text)
    elseif info.writing then
        parts[#parts + 1] = " <RGB:0.7,0.7,0.7> " .. UI.escape(getText("IGUI_StoryEngine_Letter_Writing"))
    else
        -- 준비된 편지는 번역 파일의 <LINE> 을 그대로 쓴다
        parts[#parts + 1] = " <RGB:0.92,0.88,0.78> " .. getText("IGUI_StoryEngine_Letter_Fallback_" .. tostring(info.reason), name)
    end
    if info.to then
        parts[#parts + 1] = " <LINE> <LINE> <RGB:0.6,0.6,0.6> "
            .. UI.escape(getText("IGUI_StoryEngine_Letter_To", tostring(info.to), StoryEngine.intToString(tonumber(info.day) or 0)))
    end
    return table.concat(parts)
end

function StoryEngineLetterWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local th = self:titleBarHeight()
    local rh = self:resizeWidgetHeight()
    self.text = ISRichTextPanel:new(0, th, self.width, self.height - th - rh)
    self.text:initialise()
    self.text.autosetheight = false
    self.text.clip = true
    self.text.marginLeft = 16
    self.text.marginRight = 16
    self.text.marginTop = 12
    self.text:addScrollBars()
    self.text:setAnchorRight(true)
    self.text:setAnchorBottom(true)
    self:addChild(self.text)
end

function StoryEngineLetterWindow:setInfo(info)
    self.info = info
    self.title = info.memorial and getText("IGUI_StoryEngine_Memorial_Title", tostring(info.memorial))
        or (info.charter and getText(info.charter.formed and "IGUI_StoryEngine_Charter_Title" or "IGUI_StoryEngine_Charter_Draft"))
        or getText("IGUI_StoryEngine_Letter_Title", StoryEngine.Factions.nameAs(tostring(info.from), info.voice))
    self.text.text = StoryEngineLetterWindow.body(info)
    self.text:paginate()
    self.text:setYScroll(0)
end

function StoryEngineLetterWindow:close()
    StoryEngine.UI.saveWindow("letter", self)
    StoryEngineLetterWindow.instance = nil
    ISCollapsableWindow.close(self)
    self:removeFromUIManager()
end

function StoryEngineLetterWindow:new(x, y, w, h)
    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.resizable = true
    o.minimumWidth = 320
    o.minimumHeight = 240
    return o
end

function StoryEngineLetterWindow.open(info)
    local w = StoryEngineLetterWindow.instance
    if not w then
        local x, y, width, height = StoryEngine.UI.windowRect("letter", 500, 480, 320, 260)
        w = StoryEngineLetterWindow:new(x, y, width, height)
        w:initialise()
        w:addToUIManager()
        StoryEngineLetterWindow.instance = w
    end
    w:setInfo(info)
    w:bringToTop()
end

function Client.handlers.letterText(args)
    local p = getPlayer()
    if args.error then
        if p then HaloTextHelper.addBadText(p, getText("IGUI_StoryEngine_Letter_Missing")) end
        return
    end
    StoryEngineLetterWindow.open(args)
end

-- 인벤토리 우클릭: 편지 읽기
local function letterOf(items)
    for _, v in ipairs(items or {}) do
        local it = v
        if type(v) == "table" and v.items then it = v.items[1] end
        if it and it.getFullType and (it:getFullType() == LETTER or it:getFullType() == CHARTER) then return it end
    end
    return nil
end
StoryEngineLetterWindow.letterOf = letterOf

local function onFillInventory(playerNum, context, items)
    local it = letterOf(items)
    if not it then return end
    context:addOption(getText("ContextMenu_StoryEngine_ReadLetter"), it, function(item)
        local p = getSpecificPlayer(playerNum)
        local mod = item:getModData()
        if p then Net.toServer(p, "letterRead", { id = mod.storyLetter, qid = mod.storyQuest }) end
    end)
end

Events.OnFillInventoryObjectContextMenu.Add(onFillInventory)

return StoryEngineLetterWindow
