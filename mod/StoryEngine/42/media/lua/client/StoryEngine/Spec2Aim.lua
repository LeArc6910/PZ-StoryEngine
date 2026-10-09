-- 2차 특기 조준 창 (2026-10-09 사용자 요청): 휘태커 포격·빅 대리 털이를 고르면 지도와 함께 작은 창이 뜬다.
-- 지도에서 우클릭 -> "여기 조준" -> 서버가 그 자리 형편(반경 10타일 좀비 수, 밀집도, 가장 가까운 사람, 쓸 수 있는지)을 알려 주고
-- [요청] 을 누르면 그 자리로 spec2Use. 지도를 닫으면 창도 닫힌다.

if isServer() then return end

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISRichTextPanel"
require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Client"
require "StoryEngine/Places"
require "StoryEngine/UIUtil"

local Net = StoryEngine.Net
local Client = StoryEngine.Client
local UI = StoryEngine.UI

StoryEngineAimPanel = ISPanel:derive("StoryEngineAimPanel")
StoryEngineAimPanel.instance = nil
StoryEngineAimPanel.W = 420
StoryEngineAimPanel.H = 210

local Aim = {}
StoryEngine.Aim = Aim

local function num(v) return StoryEngine.intToString(tonumber(v) or 0) end

-- 창에 넣을 글 (서식 태그)
function Aim.body(state)
    local parts = {}
    local name = getText("IGUI_StoryEngine_Spec2_Name_" .. tostring(state.opt))
    parts[#parts + 1] = " <SIZE:medium> " .. UI.escape(name) .. " <SIZE:small> <LINE> "
    local info = state.info
    if not info then
        parts[#parts + 1] = " <RGB:0.8,0.8,0.8> " .. UI.escape(getText(state.waiting and "IGUI_StoryEngine_Aim_Scanning"
            or "IGUI_StoryEngine_Aim_Hint"))
        return table.concat(parts)
    end
    local place = StoryEngine.Places and StoryEngine.Places.describe(info.x, info.y)
    local town = place and UI.townName(place.town) or ""
    parts[#parts + 1] = " <RGB:0.9,0.9,0.9> " .. UI.escape(getText("IGUI_StoryEngine_Aim_Where", town, num(info.x), num(info.y),
        num(info.dist))) .. " <LINE> "
    if info.loaded and info.zombies then
        parts[#parts + 1] = UI.escape(getText("IGUI_StoryEngine_Aim_Zombies", num(info.zombies))) .. " <LINE> "
    else
        parts[#parts + 1] = " <RGB:0.7,0.7,0.7> " .. UI.escape(getText("IGUI_StoryEngine_Aim_Unseen")) .. " <RGB:0.9,0.9,0.9> <LINE> "
    end
    if info.density then
        parts[#parts + 1] = UI.escape(getText("IGUI_StoryEngine_Aim_Density",
            getText("IGUI_StoryEngine_Aim_Density_" .. tostring(info.density)))) .. " <LINE> "
    end
    if info.nearest then
        parts[#parts + 1] = UI.escape(getText("IGUI_StoryEngine_Aim_Nearest", num(info.nearest))) .. " <LINE> "
    end
    if info.rooms then
        parts[#parts + 1] = UI.escape(getText("IGUI_StoryEngine_Aim_Rooms", num(info.rooms))) .. " <LINE> "
    end
    if info.ok then
        parts[#parts + 1] = " <RGB:0.5,0.9,0.5> " .. UI.escape(getText("IGUI_StoryEngine_Aim_Ok"))
    else
        local key = "IGUI_StoryEngine_Spec2_Error_" .. tostring(info.reason)
        local why = getTextOrNull(key) and getText(key, "0") or tostring(info.reason)
        parts[#parts + 1] = " <RGB:0.95,0.5,0.4> " .. UI.escape(getText("IGUI_StoryEngine_Aim_No", why))
    end
    return table.concat(parts)
end

function StoryEngineAimPanel:new(state)
    local w, h = StoryEngineAimPanel.W, StoryEngineAimPanel.H
    local o = ISPanel:new(math.floor((getCore():getScreenWidth() - w) / 2), 60, w, h)
    setmetatable(o, self)
    self.__index = self
    o.state = state
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.85 }
    o.borderColor = { r = 0.8, g = 0.6, b = 0.3, a = 1 }
    o.moveWithMouse = true
    return o
end

function StoryEngineAimPanel:createChildren()
    ISPanel.createChildren(self)
    local bh = 26
    self.text = ISRichTextPanel:new(0, 0, self.width, self.height - bh - 16)
    self.text:initialise()
    self.text.autosetheight = false
    self.text.background = false
    self.text.marginLeft = 12
    self.text.marginRight = 12
    self.text.marginTop = 8
    self:addChild(self.text)
    local bw = math.floor((self.width - 36) / 2)
    self.fire = ISButton:new(12, self.height - bh - 8, bw, bh, getText("IGUI_StoryEngine_Aim_Fire"), self, self.onFire)
    self.fire:initialise()
    self:addChild(self.fire)
    self.cancel = ISButton:new(24 + bw, self.height - bh - 8, bw, bh, getText("IGUI_StoryEngine_Aim_Cancel"), self, self.onCancel)
    self.cancel:initialise()
    self:addChild(self.cancel)
    self:refresh()
end

function StoryEngineAimPanel:refresh()
    self.text.text = Aim.body(self.state)
    self.text:paginate()
    local ok = self.state.info and self.state.info.ok
    self.fire:setEnable(ok == true)
end

-- 지도가 닫히면 창도 닫는다
function StoryEngineAimPanel:prerender()
    ISPanel.prerender(self)
    local ok, open = pcall(function() return ISWorldMap_instance ~= nil and ISWorldMap_instance:isReallyVisible() end)
    if ok and not open then self:close() end
end

function StoryEngineAimPanel:onFire()
    local info = self.state.info
    if not info or not info.ok then return end
    local p = getPlayer()
    if p then Net.toServer(p, "spec2Use", { faction = self.state.fid, x = info.x, y = info.y }) end
    self:close()
    pcall(function()
        if ISWorldMap_instance and ISWorldMap_instance:isReallyVisible() then ISWorldMap.HideWorldMap(0) end
    end)
end

function StoryEngineAimPanel:onCancel()
    self:close()
end

function StoryEngineAimPanel:close()
    self:setVisible(false)
    self:removeFromUIManager()
    if StoryEngineAimPanel.instance == self then StoryEngineAimPanel.instance = nil end
    Aim.state = nil
end

-- 조준 시작: 지도를 열고 창을 띄운다
function Aim.start(fid, opt)
    if StoryEngineAimPanel.instance then StoryEngineAimPanel.instance:close() end
    local p = getPlayer()
    if not p then return end
    Aim.state = { fid = fid, opt = opt }
    pcall(ISWorldMap.ShowWorldMap, 0, p:getX(), p:getY())
    local panel = StoryEngineAimPanel:new(Aim.state)
    panel:initialise()
    panel:addToUIManager()
    panel:setAlwaysOnTop(true)
    StoryEngineAimPanel.instance = panel
end

-- 지도에서 고른 자리
function Aim.pick(x, y)
    local st = Aim.state
    if not st then return end
    st.info, st.waiting = nil, true
    local p = getPlayer()
    if p then Net.toServer(p, "spec2Scan", { faction = st.fid, x = math.floor(x), y = math.floor(y) }) end
    if StoryEngineAimPanel.instance then StoryEngineAimPanel.instance:refresh() end
end

function Aim.active() return Aim.state ~= nil end

function Client.handlers.spec2ScanResult(args)
    local st = Aim.state
    if not st or tostring(args.faction) ~= tostring(st.fid) then return end
    st.info, st.waiting = args, false
    if StoryEngineAimPanel.instance then StoryEngineAimPanel.instance:refresh() end
end

return Aim
