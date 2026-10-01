-- 전기·수도 끊김 날짜(샌드박스 ElecShutModifier / WaterShutModifier)를 이 프로세스에 적용한다. 서버·클라이언트 공용.
--
-- B42 확인 (2026-10-01, jar): 전기는 SandboxOptions.doesPowerGridExist() = 경과 일수 < ElecShutModifier,
-- 수도는 IsoObject.isWaterInfinite() 가 물을 쓸 때마다 WaterShutModifier 와 비교한다. 범위 -1 ~ 2147483647.
-- 바닐라 Lua(MainScreen, SandboxOptions)도 getSandboxOptions():set("ElecShutModifier", n) 으로 바꾼다.
-- applySettings() 는 게임 시작 날짜·하루 길이를 다시 쓰므로 부르지 않고, toLua() 로 SandboxVars 만 맞춘다.
-- 서버가 바꾼 샌드박스를 클라이언트에 보내는 Lua 함수가 없어서, 서버가 gridSync 명령으로 같은 값을 보내 각자 적용한다.

require "StoryEngine/Core"

local GridSync = {}
StoryEngine.GridSync = GridSync

GridSync.OPTION = { power = "ElecShutModifier", water = "WaterShutModifier" }

function GridSync.get(kind)
    local opt = GridSync.OPTION[kind]
    if not opt then return nil end
    local ok, v = pcall(function()
        local so = getSandboxOptions()
        if kind == "power" then return so:getElecShutModifier() end
        return so:getWaterShutModifier()
    end)
    if ok and type(v) == "number" then return v end
    return tonumber(SandboxVars and SandboxVars[opt])
end

-- values = { power = 날짜, water = 날짜 } (없는 것은 그대로). 실제로 바뀐 것이 있으면 true
function GridSync.apply(values)
    local changed = false
    for kind, opt in pairs(GridSync.OPTION) do
        local v = tonumber(values and values[kind])
        if v and GridSync.get(kind) ~= v then
            v = math.max(-1, math.floor(v))
            local ok, err = pcall(function() getSandboxOptions():set(opt, v) end)
            if not ok then StoryEngine.log("grid set failed", opt, tostring(err)) end
            if SandboxVars then SandboxVars[opt] = v end
            changed = true
        end
    end
    if changed then
        pcall(function() getSandboxOptions():toLua() end)
        -- 전력 플래그는 바닐라가 주기적으로 다시 계산하지만, 바로 반영되도록 한 번 맞춘다
        pcall(function() getWorld():setHydroPowerOn(getSandboxOptions():doesPowerGridExist()) end)
    end
    return changed
end

return GridSync
