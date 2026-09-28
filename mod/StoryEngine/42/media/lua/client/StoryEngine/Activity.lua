-- 일지용 행동 기록 (클라이언트 측). 제작·분해·요리·채집·낚시 같은 행동이 끝날 때(timed action 의 perform)
-- 종류와 대상을 모아 두었다가 게임 내 1분마다 서버에 보고한다 (activity). 서버는 에피소드·하루 요약에 붙인다.
--
-- B42 에서 perform 은 행동한 플레이어의 클라이언트(싱글 포함)에서 돌고, 멀티 서버는 complete 를 돈다.
-- 서사용 정보라 클라이언트 보고로 충분하다 (CLAUDE.md 신뢰 경계).
-- 대상(what)은 아이템 전체 이름("Base.Bass"), 레시피 이름("DismantleRadio") 또는 사람 이름. 표시 이름은 서버가 붙인다.

if isServer() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"

local Activity = {
    bufs = {},        -- playerNum -> { key -> { k, w, n } }
    counts = {},      -- playerNum -> 항목 수
    installed = false,
}
StoryEngine.Activity = Activity

Activity.MAX_BUF = 30

local function isLocalPlayer(chr)
    return chr ~= nil and instanceof(chr, "IsoPlayer") and chr:isLocalPlayer()
end

function Activity.add(chr, kind, what)
    if not isLocalPlayer(chr) or chr:isDead() then return end
    local num = chr:getPlayerNum()
    local buf = Activity.bufs[num] or {}
    Activity.bufs[num] = buf
    if what ~= nil then what = string.sub(tostring(what), 1, 60) end
    local key = kind .. "|" .. tostring(what or "")
    local e = buf[key]
    if e then
        e.n = e.n + 1
    else
        buf[key] = { k = kind, w = what, n = 1 }
        Activity.counts[num] = (Activity.counts[num] or 0) + 1
    end
    if Activity.counts[num] >= Activity.MAX_BUF then Activity.flush(num) end
end

function Activity.flush(num)
    local buf = Activity.bufs[num]
    if not buf or (Activity.counts[num] or 0) == 0 then return end
    local p = getSpecificPlayer(num)
    Activity.bufs[num], Activity.counts[num] = {}, 0
    if not p or p:isDead() then return end
    local list = {}
    for _, e in pairs(buf) do list[#list + 1] = e end
    StoryEngine.Net.toServer(p, "activity", { list = list })
end

function Activity.flushAll()
    for num, _ in pairs(Activity.bufs) do Activity.flush(num) end
end

-- ---------------------------------------------------------------- 분류

-- 레시피 이름 앞부분으로 분해·무시를 가른다 (대소문자 무시)
local SKIP_PREFIX = { "open", "unpack", "pack", "close", "put", "insert", "empty", "fill", "refill", "light" }
local DISMANTLE_PREFIX = { "dismantle", "disassemble", "scrap", "salvage", "rip", "takeapart", "take_apart", "breakdown" }
local SKIP_CATEGORY = { Packing = true }

local function startsWith(s, prefixes)
    for _, p in ipairs(prefixes) do
        if string.sub(s, 1, string.len(p)) == p then return true end
    end
    return false
end

function Activity.recipeKind(name, category)
    if not name then return nil end
    if category and SKIP_CATEGORY[category] then return nil end
    local low = string.lower(name)
    if startsWith(low, SKIP_PREFIX) then return nil end
    if startsWith(low, DISMANTLE_PREFIX) then return "dismantle" end
    if category == "Cooking" then return "cook" end
    return "craft"
end

local function call(obj, method)
    if not obj then return nil end
    local ok, v = pcall(function() return obj[method](obj) end)
    if ok then return v end
    return nil
end

local function fullType(item)
    return call(item, "getFullType")
end

local function characterName(chr)
    local desc = call(chr, "getDescriptor")
    if not desc then return nil end
    local first, last = call(desc, "getForename") or "", call(desc, "getSurname") or ""
    local name = string.gsub(first .. " " .. last, "^%s+", "")
    return name ~= "" and name or nil
end

-- 다른 사람을 치료했을 때만 (자기 치료는 부상 기록으로 이미 남는다)
local function treatOther(a)
    if a.otherPlayer and a.otherPlayer ~= a.character then return "treat_other", characterName(a.otherPlayer) end
    return nil
end

-- 행동 클래스 이름 -> function(action) return kind, what end. 없는 클래스는 건너뛴다 (버전·모드 차이).
Activity.HOOKS = {
    ISHandcraftAction = function(a)
        local r = a.craftRecipe
        local name = call(r, "getName")
        return Activity.recipeKind(name, tostring(call(r, "getCategory") or "")), name
    end,
    ISCraftAction = function(a)
        local r = a.recipe
        local name = call(r, "getOriginalname") or call(r, "getName")
        return Activity.recipeKind(name, tostring(call(r, "getCategory") or "")), name
    end,
    ISAddItemInRecipe = function(a) return "cook", fullType(a.baseItem) end,
    ISMoveablesAction = function(a)
        if a.mode ~= "scrap" then return nil end
        return "dismantle", a.moveProps and a.moveProps.name or nil
    end,
    ISDismantleAction = function(a) return "dismantle", call(a.thumpable, "getName") end,
    ISBuildAction = function(a)
        local item = a.item or {}
        local name = call(item.craftRecipe, "getName")
        if not name and item.objectInfo then name = call(call(item.objectInfo, "getScript"), "getName") end
        return "build", name or item.name
    end,
    ISForageAction = function(a) return "forage", a.itemType end,
    ISPickupFishAction = function(a) return "fish", fullType(a.item) end,
    ISCheckFishingNetAction = function(a) return "fish_net", nil end,
    ISChopTreeAction = function(a) return "chop", nil end,
    ISSeedActionNew = function(a) return "plant", a.typeOfSeed end,
    ISHarvestPlantAction = function(a) return "harvest", a.plant and a.plant.typeOfSeed or nil end,
    ISPlowAction = function(a) return "plow", nil end,
    ISWaterPlantAction = function(a) return "water_plants", nil end,
    ISPlaceTrap = function(a) return "trap", fullType(a.weapon) end,
    ISButcherAnimal = function(a) return "butcher", nil end,
    ISCutAnimalOnHook = function(a) return "butcher", nil end,
    ISRemoveMeatFromAnimal = function(a) return "butcher", nil end,
    ISMilkAnimal = function(a) return "animals", nil end,
    ISShearAnimal = function(a) return "animals", nil end,
    ISHutchGrabEgg = function(a) return "animals", nil end,
    ISFeedAnimalFromHand = function(a) return "animals", nil end,
    ISReadABook = function(a) return "read", fullType(a.item) end,
    ISApplyBandage = treatOther,
    ISStitch = treatOther,
    ISSplint = treatOther,
    ISDisinfect = treatOther,
    ISRepairClothing = function(a) return "sew", fullType(a.clothing) end,
    ISBarricadeAction = function(a) return "barricade", nil end,
    ISBuryCorpse = function(a) return "bury", nil end,
    ISBurnCorpseAction = function(a) return "burn_corpse", nil end,
    ISInstallVehiclePart = function(a) return "mechanic", call(a.part, "getId") end,
    ISUninstallVehiclePart = function(a) return "mechanic", call(a.part, "getId") end,
    ISRepairEngine = function(a) return "mechanic", "Engine" end,
    ISWriteSomething = function(a) return "write", nil end,
    ISFitnessAction = function(a) return "exercise", a.exercise end,
}

-- perform 을 감싼다. 자기 perform 이 있는 클래스만 (상속받은 것을 감싸면 두 번 센다).
local function wrap(className, describe)
    local cls = _G[className]
    if type(cls) ~= "table" or rawget(cls, "StoryEngineWrapped") then return false end
    local orig = rawget(cls, "perform")
    if type(orig) ~= "function" then return false end
    cls.perform = function(self, ...)
        local ok, kind, what = pcall(describe, self)
        if ok and kind then
            local okAdd, err = pcall(Activity.add, self.character, kind, what)
            if not okAdd then StoryEngine.log("activity error:", className, err) end
        end
        return orig(self, ...)
    end
    rawset(cls, "StoryEngineWrapped", true)
    return true
end

function Activity.install()
    if Activity.installed then return end
    Activity.installed = true
    local n, missing = 0, {}
    for name, describe in pairs(Activity.HOOKS) do
        if wrap(name, describe) then n = n + 1 else missing[#missing + 1] = name end
    end
    StoryEngine.log("activity hooks", n, #missing > 0 and ("missing: " .. table.concat(missing, ",")) or "")
end

Events.OnGameStart.Add(Activity.install)
Events.EveryOneMinute.Add(Activity.flushAll)

return Activity
