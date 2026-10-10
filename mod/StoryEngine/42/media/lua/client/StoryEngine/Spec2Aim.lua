-- 2차 특기 조준 창 (2026-10-10 사용자 요청으로 레이더 지도로 다시 만듦): 휘태커 포격·빅 대리 털이를 고르면
-- 내 둘레를 위에서 본 레이더 지도가 뜬다 (바닐라 지도는 열지 않는다).
--   지도: 건물(회색 사각형, 클라이언트 메타 그리드) · 좀비(빨간 점) · 사람(초록 점) · 나(흰 점) ·
--         서버가 불러 두지 않아 좀비를 모르는 곳(어둡게) · 포격 사거리 원 · 고른 자리(노란 십자와 포격 반경 원)
--   지도를 누르면 그 자리를 고르고, 서버가 그 자리 형편(반경 10타일 좀비 수, 밀집도, 가장 가까운 사람, 쓸 수 있는지)을
--   알려 주며, [요청] 을 누르면 그 자리로 spec2Use. 보는 범위는 60/120/240 타일.
--   레이더는 RADAR_MS 마다 서버에 다시 물어 점이 움직인다 (서버가 불러 둔 칸의 좀비만 안다).
-- (화면을 그 자리로 옮기는 실시간 보기는 안 됨: 게임이 매 프레임 카메라를 내 캐릭터로 되돌리고, 시야 밖 좀비는 그리지 않는다)

if isServer() then return end

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISCollapsableWindow"
require "ISUI/ISRichTextPanel"
require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Client"
require "StoryEngine/Places"
require "StoryEngine/UIUtil"

local Net = StoryEngine.Net
local Client = StoryEngine.Client
local UI = StoryEngine.UI

local Aim = {}
StoryEngine.Aim = Aim
Aim.MAP = 460                 -- 지도 한 변 (픽셀)
Aim.SIDE = 250                -- 오른쪽 글 칸 너비
Aim.RADAR_MS = 2500           -- 다시 묻는 간격 (실시간)
Aim.VIEWS = { 60, 120, 240 }  -- 보는 반경 (타일)
Aim.DEFAULT_VIEW = 240
Aim.STRIKE_RADIUS = 10        -- 포격 반경 (서버 Specialty2.ARTY_RADIUS 와 같게)
Aim.BUILDING_MOVE = 12        -- 가운데가 이만큼 움직이면 건물 목록을 다시 읽는다

local function num(v) return StoryEngine.intToString(math.floor(tonumber(v) or 0)) end

-- ---------------------------------------------------------------- 글

function Aim.body(state)
    local parts = {}
    local name = getText("IGUI_StoryEngine_Spec2_Name_" .. tostring(state.opt))
    parts[#parts + 1] = " <SIZE:medium> " .. UI.escape(name) .. " <SIZE:small> <LINE> "
    local info = state.info
    if not info then
        parts[#parts + 1] = " <RGB:0.8,0.8,0.8> " .. UI.escape(getText(state.waiting and "IGUI_StoryEngine_Aim_Scanning"
            or "IGUI_StoryEngine_Aim_Hint")) .. " <LINE> <LINE> <RGB:0.65,0.65,0.65> "
            .. UI.escape(getText("IGUI_StoryEngine_Aim_Legend"))
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
        local why = StoryEngine.UI.hasText(key) and getText(key, "0") or tostring(info.reason)
        parts[#parts + 1] = " <RGB:0.95,0.5,0.4> " .. UI.escape(getText("IGUI_StoryEngine_Aim_No", why))
    end
    return table.concat(parts)
end

-- ---------------------------------------------------------------- 좌표

-- 세계 좌표 -> 지도 안 픽셀 (북쪽이 위, 동쪽이 오른쪽)
function Aim.toMap(state, wx, wy)
    local k = (Aim.MAP / 2) / state.view
    return Aim.MAP / 2 + (wx - state.cx) * k, Aim.MAP / 2 + (wy - state.cy) * k
end

-- 지도 안 픽셀 -> 세계 좌표
function Aim.toWorld(state, mx, my)
    local k = (Aim.MAP / 2) / state.view
    return state.cx + (mx - Aim.MAP / 2) / k, state.cy + (my - Aim.MAP / 2) / k
end

-- 보는 범위 안의 건물 사각형 { x1, y1, x2, y2 } (클라이언트도 지도 전체의 건물 자리를 안다)
function Aim.readBuildings(state)
    local out = {}
    pcall(function()
        local list = ArrayList.new()
        local r = state.view
        getWorld():getMetaGrid():getBuildingsIntersecting(math.floor(state.cx - r), math.floor(state.cy - r), r * 2, r * 2, list)
        for i = 0, list:size() - 1 do
            local def = list:get(i)
            out[#out + 1] = { def:getX(), def:getY(), def:getX2(), def:getY2() }
        end
    end)
    state.buildings, state.bx, state.by, state.bview = out, state.cx, state.cy, state.view
end

-- ---------------------------------------------------------------- 지도 칸

StoryEngineRadarMap = ISPanel:derive("StoryEngineRadarMap")

function StoryEngineRadarMap:new(x, y, state)
    local o = ISPanel:new(x, y, Aim.MAP, Aim.MAP)
    setmetatable(o, self)
    self.__index = self
    o.state = state
    o.backgroundColor = { r = 0.04, g = 0.07, b = 0.05, a = 0.95 }
    o.borderColor = { r = 0.3, g = 0.5, b = 0.35, a = 1 }
    return o
end

local function circle(self, cx, cy, r, a, cr, cg, cb)
    if r < 2 then return end
    local steps = math.max(24, math.min(160, math.floor(r * 0.8)))
    for i = 0, steps - 1 do
        local t = i * 2 * math.pi / steps
        local x, y = cx + math.cos(t) * r, cy + math.sin(t) * r
        if x >= 0 and y >= 0 and x < Aim.MAP - 1 and y < Aim.MAP - 1 then self:drawRect(x, y, 2, 2, a, cr, cg, cb) end
    end
end

function StoryEngineRadarMap:render()
    ISPanel.render(self)
    local st, S = self.state, Aim.MAP
    local k = (S / 2) / st.view
    local radar = st.radar
    -- 서버가 모르는 곳 (칸이 안 불러짐): 어둡게
    if radar and radar.grid and radar.n and radar.n > 0 then
        local n, cell = radar.n, S / radar.n
        local scale = radar.r / st.view          -- 답이 온 범위와 지금 보는 범위가 다를 수 있다
        for gy = 0, n - 1 do
            for gx = 0, n - 1 do
                if string.sub(radar.grid, gy * n + gx + 1, gy * n + gx + 1) == "0" then
                    local x = S / 2 + (gx * cell - S / 2) * scale
                    local y = S / 2 + (gy * cell - S / 2) * scale
                    local w = cell * scale
                    if x < S and y < S and x + w > 0 and y + w > 0 then
                        local x1, y1 = math.max(0, x), math.max(0, y)
                        self:drawRect(x1, y1, math.min(S, x + w) - x1, math.min(S, y + w) - y1, 0.55, 0, 0, 0)
                    end
                end
            end
        end
    end
    -- 건물
    for _, b in ipairs(st.buildings or {}) do
        local x1, y1 = Aim.toMap(st, b[1], b[2])
        local x2, y2 = Aim.toMap(st, b[3], b[4])
        x1, y1, x2, y2 = math.max(0, x1), math.max(0, y1), math.min(S, x2), math.min(S, y2)
        if x2 - x1 >= 1 and y2 - y1 >= 1 then self:drawRect(x1, y1, x2 - x1, y2 - y1, 0.55, 0.42, 0.44, 0.4) end
    end
    -- 거리 고리 (60타일마다), 포격 사거리
    for d = 60, st.view, 60 do circle(self, S / 2, S / 2, d * k, 0.25, 0.4, 0.6, 0.45) end
    if st.range then circle(self, S / 2, S / 2, st.range * k, 0.6, 0.9, 0.6, 0.25) end
    self:drawRect(S / 2, 0, 1, S, 0.15, 0.4, 0.6, 0.45)
    self:drawRect(0, S / 2, S, 1, 0.15, 0.4, 0.6, 0.45)
    self:drawText("N", S / 2 - 3, 2, 0.6, 0.8, 0.65, 0.9, UIFont.Small)
    -- 좀비, 사람, 나
    if radar then
        local zx, zy = radar.zx or {}, radar.zy or {}
        local dot = st.view <= 60 and 3 or 2
        for i = 1, #zx do
            local x, y = Aim.toMap(st, radar.cx + (tonumber(zx[i]) or 0), radar.cy + (tonumber(zy[i]) or 0))
            if x >= 0 and y >= 0 and x < S and y < S then self:drawRect(x - 1, y - 1, dot, dot, 1, 0.95, 0.25, 0.2) end
        end
        local px, py = radar.px or {}, radar.py or {}
        for i = 1, #px do
            local x, y = Aim.toMap(st, radar.cx + (tonumber(px[i]) or 0), radar.cy + (tonumber(py[i]) or 0))
            if x >= 0 and y >= 0 and x < S and y < S then self:drawRect(x - 2, y - 2, 5, 5, 1, 0.3, 0.95, 0.4) end
        end
        self:drawText(getText("IGUI_StoryEngine_Aim_RadarCount", num(radar.total or #zx), num(st.view)), 4, S - 16,
            0.85, 0.85, 0.85, 1, UIFont.Small)
    end
    self:drawRect(S / 2 - 2, S / 2 - 2, 5, 5, 1, 1, 1, 1)
    -- 고른 자리
    if st.wantX then
        local x, y = Aim.toMap(st, st.wantX + 0.5, st.wantY + 0.5)
        if x >= 0 and y >= 0 and x < S and y < S then
            self:drawRect(x - 6, y, 13, 1, 1, 1, 0.9, 0.2)
            self:drawRect(x, y - 6, 1, 13, 1, 1, 0.9, 0.2)
            if st.opt == "artillery" then circle(self, x, y, Aim.STRIKE_RADIUS * k, 0.9, 1, 0.8, 0.2) end
        end
    end
end

function StoryEngineRadarMap:onMouseDown(x, y)
    local wx, wy = Aim.toWorld(self.state, x, y)
    Aim.pick(wx, wy)
    return true
end

-- ---------------------------------------------------------------- 창

StoryEngineAimWindow = ISCollapsableWindow:derive("StoryEngineAimWindow")
StoryEngineAimWindow.instance = nil
-- 예전 이름 (테스트·다른 파일)
StoryEngineAimPanel = StoryEngineAimWindow

function StoryEngineAimWindow:new(state)
    local w, h = Aim.MAP + Aim.SIDE + 30, Aim.MAP + 50
    local x, y = UI.windowRect("aim", w, h, w, h)
    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.state = state
    o.title = getText("IGUI_StoryEngine_Aim_Title")
    o.resizable = false
    return o
end

function StoryEngineAimWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local th = self:titleBarHeight()
    self.map = StoryEngineRadarMap:new(10, th + 8, self.state)
    self.map:initialise()
    self:addChild(self.map)
    local sx = Aim.MAP + 20
    local bh = 26
    self.text = ISRichTextPanel:new(sx, th + 8, Aim.SIDE, Aim.MAP - bh * 2 - 24)
    self.text:initialise()
    self.text.autosetheight = false
    self.text.background = false
    self.text.marginLeft = 4
    self.text.marginRight = 4
    self.text.marginTop = 2
    self:addChild(self.text)
    -- 보는 범위
    local zy = th + 8 + Aim.MAP - bh * 2 - 10
    local zw = math.floor((Aim.SIDE - 8) / #Aim.VIEWS)
    self.zoom = {}
    for i, v in ipairs(Aim.VIEWS) do
        local b = ISButton:new(sx + (i - 1) * (zw + 4), zy, zw, bh, getText("IGUI_StoryEngine_Aim_View", num(v)), self, self.onView)
        b:initialise()
        b.view = v
        self:addChild(b)
        self.zoom[i] = b
    end
    local by = th + 8 + Aim.MAP - bh
    local bw = math.floor((Aim.SIDE - 4) / 2)
    self.fire = ISButton:new(sx, by, bw, bh, getText("IGUI_StoryEngine_Aim_Fire"), self, self.onFire)
    self.fire:initialise()
    self:addChild(self.fire)
    self.cancel = ISButton:new(sx + bw + 4, by, bw, bh, getText("IGUI_StoryEngine_Aim_Cancel"), self, self.onCancel)
    self.cancel:initialise()
    self:addChild(self.cancel)
    self:refresh()
end

function StoryEngineAimWindow:refresh()
    self.text.text = Aim.body(self.state)
    self.text:paginate()
    local ok = self.state.info and self.state.info.ok
    self.fire:setEnable(ok == true)
    for _, b in ipairs(self.zoom or {}) do
        local on = b.view == self.state.view
        b.textColor = on and { r = 0.5, g = 1, b = 0.6, a = 1 } or { r = 0.9, g = 0.9, b = 0.9, a = 1 }
    end
end

function StoryEngineAimWindow:onView(button)
    Aim.setView(button.view)
end

-- 레이더와 고른 자리를 RADAR_MS 마다 다시 묻는다
function StoryEngineAimWindow:prerender()
    ISCollapsableWindow.prerender(self)
    Aim.tick()
end

function StoryEngineAimWindow:onFire()
    local info = self.state.info
    if not info or not info.ok then return end
    local p = getPlayer()
    if p then Net.toServer(p, "spec2Use", { faction = self.state.fid, x = info.x, y = info.y }) end
    self:close()
end

function StoryEngineAimWindow:onCancel()
    self:close()
end

function StoryEngineAimWindow:close()
    pcall(UI.saveWindow, "aim", self)
    self:setVisible(false)
    self:removeFromUIManager()
    if StoryEngineAimWindow.instance == self then StoryEngineAimWindow.instance = nil end
    Aim.state = nil
end

-- ---------------------------------------------------------------- 흐름

local function send(command, args)
    local p = getPlayer()
    if p then Net.toServer(p, command, args) end
end

function Aim.askRadar()
    local st = Aim.state
    if not st then return end
    st.radarMs = StoryEngine.nowMs()
    send("spec2Radar", { faction = st.fid, r = st.view })
end

-- 조준 시작: 레이더 지도 창을 띄운다
function Aim.start(fid, opt)
    if StoryEngineAimWindow.instance then StoryEngineAimWindow.instance:close() end
    local p = getPlayer()
    if not p then return end
    Aim.state = { fid = fid, opt = opt, view = Aim.DEFAULT_VIEW, cx = p:getX(), cy = p:getY() }
    Aim.readBuildings(Aim.state)
    local win = StoryEngineAimWindow:new(Aim.state)
    win:initialise()
    win:addToUIManager()
    StoryEngineAimWindow.instance = win
    Aim.askRadar()
end

function Aim.setView(view)
    local st = Aim.state
    if not st then return end
    st.view = view
    Aim.readBuildings(st)
    Aim.askRadar()
    if StoryEngineAimWindow.instance then StoryEngineAimWindow.instance:refresh() end
end

-- 지도에서 고른 자리
function Aim.pick(x, y)
    local st = Aim.state
    if not st then return end
    st.info, st.waiting = nil, true
    st.wantX, st.wantY = math.floor(x), math.floor(y)
    st.askedMs = StoryEngine.nowMs()
    send("spec2Scan", { faction = st.fid, x = st.wantX, y = st.wantY })
    if StoryEngineAimWindow.instance then StoryEngineAimWindow.instance:refresh() end
end

function Aim.tick()
    local st = Aim.state
    if not st then return end
    local now = StoryEngine.nowMs()
    if not st.radarMs or now - st.radarMs >= Aim.RADAR_MS then Aim.askRadar() end
    if st.info and not st.waiting and (not st.askedMs or now - st.askedMs >= Aim.RADAR_MS) then
        st.askedMs = now
        send("spec2Scan", { faction = st.fid, x = st.info.x, y = st.info.y, again = true })
    end
end

function Aim.active() return Aim.state ~= nil end

function Client.handlers.spec2ScanResult(args)
    local st = Aim.state
    if not st or tostring(args.faction) ~= tostring(st.fid) then return end
    -- 늦게 온 답(다른 자리를 이미 골랐으면)은 버린다
    if st.wantX and (tonumber(args.x) ~= st.wantX or tonumber(args.y) ~= st.wantY) then return end
    st.info, st.waiting = args, false
    if StoryEngineAimWindow.instance then StoryEngineAimWindow.instance:refresh() end
end

-- 레이더: 가운데는 서버가 본 내 자리 (지도가 나를 따라온다)
function Client.handlers.spec2RadarResult(args)
    local st = Aim.state
    if not st or tostring(args.faction) ~= tostring(st.fid) then return end
    st.radar = args
    st.range = tonumber(args.range)
    st.cx, st.cy = tonumber(args.cx) or st.cx, tonumber(args.cy) or st.cy
    if not st.bx or math.abs(st.cx - st.bx) > Aim.BUILDING_MOVE or math.abs(st.cy - st.by) > Aim.BUILDING_MOVE
        or st.bview ~= st.view then
        Aim.readBuildings(st)
    end
end

return Aim
