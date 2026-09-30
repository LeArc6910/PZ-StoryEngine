-- 라디오 방송의 클라이언트 쪽 (Broadcast.lua 가 보낸 broadcastAir).
--   방송이 시작되면 알림(진행자·주파수)을 띄우고, 한 시간(게임) 동안 매분 이 플레이어가 그 주파수에 맞춰 켠 라디오를
--   가지고 있는지(인벤토리, 5타일 안에 놓인 라디오, 타고 있는 차의 라디오) 확인해 들었으면 broadcastHeard 를 한 번 보낸다.

if isServer() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Client"
require "StoryEngine/Factions"

local Net = StoryEngine.Net
local Client = StoryEngine.Client

local BroadcastClient = { current = nil }
StoryEngine.BroadcastClient = BroadcastClient

BroadcastClient.RANGE = 5

local function freqText(freq)
    local mhz = math.floor(freq / 1000)
    local dec = math.floor((freq % 1000) / 100)
    return StoryEngine.intToString(mhz) .. "." .. StoryEngine.intToString(dec)
end
BroadcastClient.freqText = freqText

local function tunedTo(device, freq)
    local ok, yes = pcall(function()
        local dd = device:getDeviceData()
        return dd ~= nil and dd:getIsTurnedOn() and dd:getChannel() == freq
    end)
    return ok and yes == true
end

-- 이 플레이어가 지금 freq 방송을 들을 수 있는가
function BroadcastClient.listening(player, freq)
    local items = player:getInventory():getItems()
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if instanceof(it, "Radio") and tunedTo(it, freq) then return true end
    end
    local okV, inCar = pcall(function()
        local v = player:getVehicle()
        local part = v and v:getPartById("Radio")
        return part ~= nil and tunedTo(part, freq)
    end)
    if okV and inCar then return true end
    local sq = player:getCurrentSquare()
    if not sq then return false end
    local cell = getCell()
    local r = BroadcastClient.RANGE
    for dx = -r, r do
        for dy = -r, r do
            local s = cell:getGridSquare(sq:getX() + dx, sq:getY() + dy, sq:getZ())
            if s then
                local objs = s:getObjects()
                for i = 0, objs:size() - 1 do
                    local o = objs:get(i)
                    if instanceof(o, "IsoWaveSignal") and tunedTo(o, freq) then return true end
                end
            end
        end
    end
    return false
end

function Client.handlers.broadcastAir(args)
    local freq = tonumber(args.freq)
    if not freq or not args.id then return end
    BroadcastClient.current = { id = args.id, freq = freq, left = tonumber(args.minutes) or 60, sent = {} }
    local p = getPlayer()
    if p then
        local key = args.rerun and "IGUI_StoryEngine_Broadcast_Rerun" or "IGUI_StoryEngine_Broadcast_OnAir"
        HaloTextHelper.addText(p, getText(key, StoryEngine.Factions.name(tostring(args.host)), freqText(freq)))
    end
    BroadcastClient.check()
end

function BroadcastClient.check()
    local cur = BroadcastClient.current
    if not cur then return end
    for i = 0, getNumActivePlayers() - 1 do
        local p = getSpecificPlayer(i)
        if p and not p:isDead() and not cur.sent[i] and BroadcastClient.listening(p, cur.freq) then
            cur.sent[i] = true
            Net.toServer(p, "broadcastHeard", { id = cur.id })
        end
    end
end

Events.EveryOneMinute.Add(function()
    local cur = BroadcastClient.current
    if not cur then return end
    cur.left = cur.left - 1
    if cur.left < 0 then
        BroadcastClient.current = nil
        return
    end
    local ok, err = pcall(BroadcastClient.check)
    if not ok then StoryEngine.log("broadcast listen check error:", err) end
end)

return BroadcastClient
