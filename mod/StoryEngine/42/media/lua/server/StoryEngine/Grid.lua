-- 전기·수도 복구 (2026-10-01, 설계 docs/IDEAS_WORLD_EVENTS.md "전력·수도 복구 작전"의 1단계: 복구 자체가 되는지 인게임 확인용).
--
-- 복구 = 샌드박스 끊김 날짜를 "오늘 + 60일"로 올린다 (GridSync). 서버 권위:
-- * 상태 d.grid = { restored = { power|water = { untilDay, day, why } }, orig = { power|water = 복구 전 값 } }
-- * 호스트를 다시 켜면 서버 설정 파일 값으로 돌아갈 수 있어 ModData 기준으로 다시 적용한다 (Grid.ensure)
-- * 클라이언트는 gridSync 명령으로 같은 값을 받는다 (접속 hello 때와 바뀔 때)
-- * 기간이 끝나면 복구 전 값으로 되돌린다 (그 날이 지났으면 다시 끊긴다)
-- 아직은 디버그 메뉴로만 쓴다. 복구 작전(퀘스트)은 이 확인 뒤에 만든다.
-- 끊기(Grid.cut)도 같은 방식: 끊김 날짜를 0 으로 내린다 (디버그 "전기 끊김"·"수도 끊김"이 실제로도 끊게, 2026-10-01).

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Store"
require "StoryEngine/GridSync"
require "StoryEngine/World"

local Net = StoryEngine.Net
local Store = StoryEngine.Store
local GridSync = StoryEngine.GridSync
local log = StoryEngine.log

local Grid = {}
StoryEngine.Grid = Grid

Grid.RESTORE_DAYS = 60       -- 복구 유지 기간 (사용자 결정, 2026-10-01)
Grid.KINDS = { "power", "water" }

local function state()
    local d = Store.data()
    d.grid = d.grid or {}
    d.grid.restored = d.grid.restored or {}
    d.grid.orig = d.grid.orig or {}
    d.grid.cut = d.grid.cut or {}
    return d.grid
end

-- 끊김 판정과 같은 단위의 오늘 (아포칼립스 경과 일수)
function Grid.today()
    return StoryEngine.World.apoDay()
end

function Grid.values()
    return { power = GridSync.get("power"), water = GridSync.get("water") }
end

function Grid.broadcast()
    Net.toAll("gridSync", Grid.values())
end

function Grid.sendTo(player)
    Net.toClient(player, "gridSync", Grid.values())
end

-- kind 를 days 일 동안 되살린다
function Grid.restore(kind, days, why)
    if not GridSync.OPTION[kind] then return false end
    local s = state()
    if s.orig[kind] == nil then s.orig[kind] = GridSync.get(kind) end
    local today = Grid.today()
    local untilDay = math.floor(today) + math.max(1, math.floor(days or Grid.RESTORE_DAYS))
    s.restored[kind] = { untilDay = untilDay, day = math.floor(today), why = why }
    s.cut[kind] = nil
    GridSync.apply({ [kind] = untilDay })
    log("grid restored", kind, "until day", untilDay, "(was", tostring(s.orig[kind]) .. ")", why or "",
        "now", tostring(GridSync.get(kind)))
    Grid.broadcast()
    return true
end

-- kind 를 지금 바로 끊는다. 끊김 날짜 0 = 바닐라 판정(경과 일수 < 날짜)으로 항상 꺼짐
function Grid.cut(kind, why)
    if not GridSync.OPTION[kind] then return false end
    local s = state()
    if s.orig[kind] == nil then s.orig[kind] = GridSync.get(kind) end
    s.restored[kind] = nil
    s.cut[kind] = { value = 0, day = math.floor(Grid.today()), why = why }
    GridSync.apply({ [kind] = 0 })
    log("grid cut", kind, "(was", tostring(s.orig[kind]) .. ")", why or "", "now", tostring(GridSync.get(kind)))
    Grid.broadcast()
    return true
end

-- 복구·끊기를 끝내고 원래 값으로 (kind 가 없으면 둘 다)
function Grid.reset(kind, why)
    local s = state()
    local changed = false
    for _, k in ipairs(Grid.KINDS) do
        if (not kind or kind == k) and (s.restored[k] or s.cut[k] or s.orig[k] ~= nil) then
            local o = s.orig[k]
            s.restored[k] = nil
            s.cut[k] = nil
            s.orig[k] = nil
            if o ~= nil then GridSync.apply({ [k] = o }) end
            log("grid reset", k, "to", tostring(o), why or "")
            changed = true
        end
    end
    if changed then Grid.broadcast() end
    return changed
end

-- 다시 적용·만료 (서버 시작, 매 시간)
function Grid.ensure()
    local s = state()
    local today = Grid.today()
    local changed = false
    for _, k in ipairs(Grid.KINDS) do
        local r = s.restored[k]
        if r then
            if today >= r.untilDay then
                log("grid restore ended", k, "day", math.floor(today))
                s.endedDay = s.endedDay or {}
                s.endedDay[k] = r.untilDay          -- 복구 작전의 "끊긴 날" (Ops.offDay)
                Grid.reset(k, "expired")
                if StoryEngine.Ops then pcall(StoryEngine.Ops.onGridLost, k) end
            elseif GridSync.get(k) ~= r.untilDay then
                GridSync.apply({ [k] = r.untilDay })
                log("grid reapplied", k, "until day", r.untilDay)
                changed = true
            end
        elseif s.cut[k] and GridSync.get(k) ~= s.cut[k].value then
            GridSync.apply({ [k] = s.cut[k].value })
            log("grid reapplied cut", k)
            changed = true
        end
    end
    if changed then Grid.broadcast() end
end

function Grid.isRestored(kind)
    return state().restored[kind] ~= nil
end

function Grid.daysLeft(kind)
    local r = state().restored[kind]
    if not r then return nil end
    return math.max(0, math.floor(r.untilDay - Grid.today()))
end

function Grid.statusText()
    local World = StoryEngine.World
    local parts = {}
    for _, k in ipairs(Grid.KINDS) do
        local off
        if k == "power" then off = World.powerOff() else off = World.waterOff() end
        local left = Grid.daysLeft(k)
        parts[#parts + 1] = k .. "=" .. (off and "off" or "on")
            .. (left and ("(restored, " .. StoryEngine.intToString(left) .. "d left)") or "")
            .. (state().cut[k] and "(cut)" or "")
            .. " shut=" .. tostring(GridSync.get(k))
    end
    return "grid " .. table.concat(parts, " ") .. " today=" .. StoryEngine.intToString(math.floor(Grid.today()))
end

local function safeEnsure()
    local ok, err = pcall(Grid.ensure)
    if not ok then log("grid ensure error:", err) end
end

if Events.OnInitGlobalModData then Events.OnInitGlobalModData.Add(safeEnsure) end
if Events.OnServerStarted then Events.OnServerStarted.Add(safeEnsure) end
Events.EveryHours.Add(safeEnsure)

return Grid
