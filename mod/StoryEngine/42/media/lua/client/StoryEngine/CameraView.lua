-- 실시간 보기 시험 (디버그, 2026-10-09): 캐릭터는 그 자리에 두고 화면(카메라)만 지도에서 고른 곳으로 옮긴다.
-- 바닐라 IsoDummyCameraCharacter(x, y, z) 가 카메라 대상이 된다 (jar: Lua 노출, 생성자가 IsoCamera.setCameraCharacter).
-- 바닐라 Lua 에서 쓰는 곳이 없어 인게임 시험용. 게임은 내 캐릭터 둘레만 불러 두므로 먼 곳은 검게 보일 수 있다.
-- 돌아오기: 창의 [돌아가기], 캐릭터가 다치거나 죽으면 바로.

if isServer() then return end

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "StoryEngine/Core"

local log = StoryEngine.log

local Cam = { dummy = nil }
StoryEngine.CameraView = Cam
Cam.STEP = 10

StoryEngineCameraPanel = ISPanel:derive("StoryEngineCameraPanel")
StoryEngineCameraPanel.instance = nil

local function num(v) return StoryEngine.intToString(math.floor(tonumber(v) or 0)) end

local function loadedAt(x, y, z)
    local ok, sq = pcall(function() return getCell():getGridSquare(math.floor(x), math.floor(y), z or 0) end)
    return ok and sq ~= nil
end

-- 카메라를 내 캐릭터로 되돌린다
local function restoreCamera(p)
    local ok = p and pcall(function() IsoCamera.setCameraCharacter(p) end)
    if not ok then pcall(function() IsoCamera.clearCameraCharacter() end) end
end

function Cam.info()
    local d = Cam.dummy
    if not d then return nil end
    local x, y = d:getX(), d:getY()
    local p = getPlayer()
    local dist = p and math.sqrt((p:getX() - x) ^ 2 + (p:getY() - y) ^ 2) or 0
    return { x = x, y = y, z = d:getZ(), loaded = loadedAt(x, y, d:getZ()), dist = dist }
end

function Cam.start(x, y, z)
    local p = getPlayer()
    if not p then return end
    if Cam.dummy then Cam.stop("restart") end
    z = z or 0
    local ok, d = pcall(function() return IsoDummyCameraCharacter.new(x + 0.5, y + 0.5, z) end)
    if not ok or not d then
        log("camera view failed to create:", tostring(d))
        HaloTextHelper.addBadText(p, "camera view failed: " .. tostring(d))
        return
    end
    pcall(function() IsoCamera.setCameraCharacter(d) end)
    Cam.dummy = d
    Cam.hp = p:getHealth()
    Cam.wounds = p:getBodyDamage():getNumPartsBleeding()
    pcall(function() if ISWorldMap_instance and ISWorldMap_instance:isReallyVisible() then ISWorldMap.HideWorldMap(0) end end)
    local i = Cam.info()
    log("camera view start", num(x), num(y), num(z), "loaded", tostring(i.loaded), "dist", num(i.dist))
    local panel = StoryEngineCameraPanel:new()
    panel:initialise()
    panel:addToUIManager()
    panel:setAlwaysOnTop(true)
    StoryEngineCameraPanel.instance = panel
end

function Cam.move(dx, dy)
    local d = Cam.dummy
    if not d then return end
    pcall(function()
        d:setX(d:getX() + dx)
        d:setY(d:getY() + dy)
        d:setLx(d:getX())
        d:setLy(d:getY())
    end)
    local i = Cam.info()
    log("camera view moved", num(i.x), num(i.y), "loaded", tostring(i.loaded), "dist", num(i.dist))
end

function Cam.stop(why)
    local p = getPlayer()
    restoreCamera(p)
    if Cam.dummy then pcall(function() Cam.dummy:removeFromWorld() end) end
    Cam.dummy = nil
    local panel = StoryEngineCameraPanel.instance
    StoryEngineCameraPanel.instance = nil
    if panel then
        panel:setVisible(false)
        panel:removeFromUIManager()
    end
    log("camera view end", tostring(why))
end

-- 보는 동안 캐릭터가 다치거나 죽으면 돌아온다
Events.OnTick.Add(function()
    if not Cam.dummy then return end
    local p = getPlayer()
    if not p or p:isDead() then Cam.stop("dead") return end
    local ok, hurt = pcall(function()
        return p:getHealth() < (Cam.hp or 100) - 0.5 or p:getBodyDamage():getNumPartsBleeding() > (Cam.wounds or 0)
    end)
    if ok and hurt then Cam.stop("hurt") end
end)

function StoryEngineCameraPanel:new()
    local w, h = 300, 170
    local o = ISPanel:new(math.floor((getCore():getScreenWidth() - w) / 2), 40, w, h)
    setmetatable(o, self)
    self.__index = self
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.8 }
    o.borderColor = { r = 0.4, g = 0.7, b = 0.9, a = 1 }
    o.moveWithMouse = true
    return o
end

function StoryEngineCameraPanel:createChildren()
    ISPanel.createChildren(self)
    local s, bw, bh = Cam.STEP, 60, 24
    local cx = math.floor(self.width / 2)
    local function btn(x, y, w, text, fn)
        local b = ISButton:new(x, y, w, bh, text, self, fn)
        b:initialise()
        self:addChild(b)
        return b
    end
    -- 아이소 화면 기준: 위 = 북서(-y), 오른쪽 = 북동(+x)
    btn(cx - bw / 2, 52, bw, "N -" .. s, function() Cam.move(0, -s) end)
    btn(cx - bw / 2, 104, bw, "S +" .. s, function() Cam.move(0, s) end)
    btn(cx - bw * 1.5 - 6, 78, bw, "W -" .. s, function() Cam.move(-s, 0) end)
    btn(cx + bw / 2 + 6, 78, bw, "E +" .. s, function() Cam.move(s, 0) end)
    btn(10, self.height - bh - 8, self.width - 20, getText("IGUI_StoryEngine_Camera_Back"), function() Cam.stop("button") end)
end

function StoryEngineCameraPanel:render()
    ISPanel.render(self)
    local i = Cam.info()
    if not i then return end
    local line = num(i.x) .. ", " .. num(i.y) .. "  |  " .. num(i.dist) .. " tiles  |  "
        .. (i.loaded and getText("IGUI_StoryEngine_Camera_Loaded") or getText("IGUI_StoryEngine_Camera_Unloaded"))
    self:drawText(getText("IGUI_StoryEngine_Camera_Title"), 10, 6, 0.6, 0.85, 1, 1, UIFont.Small)
    self:drawText(line, 10, 24, i.loaded and 0.6 or 1, i.loaded and 1 or 0.5, i.loaded and 0.6 or 0.4, 1, UIFont.Small)
end

return Cam
