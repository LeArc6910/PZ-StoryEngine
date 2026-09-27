-- 추적 무리의 클라이언트 쪽 (멀티 전용).
--
-- 멀티에서는 좀비를 소유한 클라이언트가 좀비를 움직이므로, 서버가 보낸 "huntChase"(좀비 online ID 목록, 대상 플레이어 online ID)를
-- 받아 이 클라이언트가 가진 그 좀비들에게 대상 플레이어를 쫓게 한다. 싱글에서는 서버 쪽 Hunt.lua 가 직접 한다.

if isServer() then return end

require "StoryEngine/Core"
require "StoryEngine/Client"

local HuntClient = {
    orders = {},      -- zombie online ID -> { target = player online ID, untilMs }
    ticks = 0,
    EVERY = 20,       -- 틱마다 한 번
    KEEP_MS = 15000,  -- 서버가 이 시간 동안 다시 보내지 않으면 명령을 버린다
    SPOT_DIST = 12,
}
StoryEngine.HuntClient = HuntClient

StoryEngine.Client.handlers.huntChase = function(args)
    local untilMs = getTimestampMs() + HuntClient.KEEP_MS
    for _, id in ipairs(args.ids or {}) do
        HuntClient.orders[id] = { target = args.target, untilMs = untilMs }
    end
end

local function update()
    local now = getTimestampMs()
    local any = false
    for id, o in pairs(HuntClient.orders) do
        if now > o.untilMs then HuntClient.orders[id] = nil else any = true end
    end
    if not any then return end
    local list = getCell():getZombieList()
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        local o = HuntClient.orders[z:getOnlineID()]
        if o and not z:isDead() then
            local target = getPlayerByOnlineID(o.target)
            if target and not target:isDead() then
                local dx, dy = z:getX() - target:getX(), z:getY() - target:getY()
                if dx * dx + dy * dy <= HuntClient.SPOT_DIST * HuntClient.SPOT_DIST then
                    z:spotted(target, true)
                else
                    z:pathToCharacter(target)
                end
            end
        end
    end
end

Events.OnTick.Add(function()
    HuntClient.ticks = HuntClient.ticks + 1
    if HuntClient.ticks < HuntClient.EVERY then return end
    HuntClient.ticks = 0
    local ok, err = pcall(update)
    if not ok then StoryEngine.log("hunt client error:", err) end
end)

return HuntClient
