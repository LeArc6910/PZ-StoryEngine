-- 설치된 모든 아이템(바닐라 + 다른 모드)을 훑어 분류·등급을 매긴다. 서버(보상·거래)와 클라이언트(대가 가치)가 같이 쓴다.
--
-- 이름이 아니라 아이템 속성으로 판단한다 (모드마다 이름 규칙이 달라서).
--   food    : 먹을 수 있고 상하지 않는(또는 밀봉된) 음식. 향신료·재료(minoringredient)·상하는 음식·위험한 날것은 뺀다.
--             등급은 열량으로. 통조림 상자처럼 음식을 담은 묶음은 foodBox (대가로만 받는다)
--   firearm : 원거리 무기 + 등록된 탄약(AmmoType). 등급은 쓰는 탄약으로 정한다 (ItemPool.AMMO_TIERS, 2026-09-27 사용자 결정)
--             1 9mm·.38 / 2 .45·.357·.44 / 3 .30-30·.308 / 4 12게이지 / 5 5.56·5.45·5.8·.338
--             + 20발 이상 탄창을 쓰는 자동화기는 탄약과 관계없이 5 (총 아이템을 만들 수 있을 때만 알 수 있다)
--             .50 BMG·14.5mm·유탄·화염 연료를 쓰는 무기는 뺀다. 모르는 탄약은 3등급 (items.txt 의 ammo 줄로 지정)
--   ammo    : 총이 가리키는 낱발(AmmoType)·상자(AmmoBox)·탄창(MagazineType)
--   melee   : 근접 무기 (DisplayCategory Weapon). 등급은 피해 순위 5분위
-- 나머지(도구·의약품 등)는 DisplayCategory 로만 분류한다 (보상 목록은 바닐라 그대로).
--
-- 조정 파일 Zomboid/Lua/StoryEngine/items.txt (없으면 서버가 설명을 담아 만든다):
--   exclude <아이템 또는 접두어*>          예) exclude Base.DogfoodOpen   exclude VFX.Frozen*
--   include <food|melee> <등급> <아이템>   예) include food 3 VFX.CannedBeefRavioli
--   ammo <1-5|exclude> <낱발 아이템>       예) ammo 2 Base.CrossbowBolt   (그 탄약을 쓰는 총의 등급)

require "StoryEngine/Core"

local ItemPool = {
    built = false,
    info = {},         -- fullType -> { cat, tier, value, ... }
    pools = {},        -- cat -> tier -> { fullType, ... }
    guns = {},         -- fullType -> { tier, round, box, mag }
    gunsByTier = {},   -- tier -> { fullType, ... }
    ammoRole = {},     -- fullType -> "round" | "box" | "mag"
    excludes = {}, prefixes = {},
    stats = {},
}
StoryEngine.ItemPool = ItemPool

ItemPool.FILE = "StoryEngine/items.txt"
ItemPool.MIN_CALORIES = 100
ItemPool.FRESH_DAYS = 30            -- 이보다 빨리 상하면 보상에서 뺀다 (0 은 상하지 않음)
ItemPool.FOOD_TIERS = { 200, 350, 500, 700 }   -- 열량 경계 -> 1~5등급
ItemPool.AUTO_AMMO = 20             -- 이 이상 들어가는 탄창을 쓰면 자동화기 -> 5등급
ItemPool.UNKNOWN_AMMO_TIER = 3

-- 낱발 아이템(모듈 없이, 소문자) -> 총 등급. false 는 제외
ItemPool.AMMO_TIERS = {
    bullets9mm = 1, bullets38 = 1,
    bullets45 = 2, bullets357 = 2, bullets44 = 2,
    ["3030bullets"] = 3, ["308bullets"] = 3,
    shotgunshells = 4,
    ["556bullets"] = 5, ["545bullets"] = 5, a_58bullets = 5, bullets86 = 5,
    bullets50 = false, bullets145 = false, grenadeammo = false, flamefuel = false,
}
ItemPool.GUN_VALUE = { 30, 40, 50, 65, 80 }
ItemPool.MELEE_VALUE = { 3, 4, 5, 8, 12 }

-- ---------------------------------------------------------------- helpers

local function lower(s) return string.lower(tostring(s or "")) end

-- 바닐라처럼 ItemTag 상수로 확인한다 (예: ItemTag.MINOR_INGREDIENT)
local function hasTag(script, tagName)
    local ok, yes = pcall(function() return script:hasTag(ItemTag[tagName]) end)
    return ok and yes == true
end

local function findScript(fullType)
    if not fullType or fullType == "" then return nil end
    local ok, s = pcall(function() return getScriptManager():FindItem(fullType) end)
    return ok and s or nil
end

-- 모듈 없이 적힌 이름("308Box")을 전체 이름으로. 못 찾으면 nil
local function resolve(name, module)
    if not name or name == "" then return nil end
    if string.find(name, ".", 1, true) then
        return findScript(name) and name or nil
    end
    for _, m in ipairs({ module or "Base", "Base" }) do
        local ft = m .. "." .. name
        if findScript(ft) then return ft end
    end
    return nil
end

local function excluded(fullType)
    if ItemPool.excludes[fullType] then return true end
    for _, p in ipairs(ItemPool.prefixes) do
        if string.sub(fullType, 1, string.len(p)) == p then return true end
    end
    return false
end

local function tierByBounds(v, bounds)
    for i, b in ipairs(bounds) do
        if v < b then return i end
    end
    return #bounds + 1
end

-- 반환: item | nil, 오류 문자열
local function newInstance(fullType)
    local ok, item = pcall(instanceItem, fullType)
    if not ok then return nil, tostring(item) end
    return item, nil
end

-- ---------------------------------------------------------------- overrides file

local function readOverrides()
    ItemPool.excludes, ItemPool.prefixes = {}, {}
    local includes = {}
    local ok, reader = pcall(getFileReader, ItemPool.FILE, false)
    if not ok or not reader then return includes, false end
    local line = reader:readLine()
    while line do
        local words = {}
        for w in string.gmatch(line, "%S+") do words[#words + 1] = w end
        if words[1] == "exclude" and words[2] then
            local p = words[2]
            if string.sub(p, -1) == "*" then
                ItemPool.prefixes[#ItemPool.prefixes + 1] = string.sub(p, 1, -2)
            else
                ItemPool.excludes[p] = true
            end
        elseif words[1] == "ammo" and words[3] then
            local key = string.lower(string.match(words[3], "([^%.]+)$") or words[3])
            if words[2] == "exclude" then
                ItemPool.AMMO_TIERS[key] = false
            elseif tonumber(words[2]) then
                ItemPool.AMMO_TIERS[key] = math.max(1, math.min(5, math.floor(tonumber(words[2]))))
            end
        elseif words[1] == "include" and words[4] then
            includes[#includes + 1] = { cat = words[2], tier = tonumber(words[3]) or 3, fullType = words[4] }
        end
        line = reader:readLine()
    end
    reader:close()
    return includes, true
end

local function writeTemplate()
    pcall(function()
        local w = getFileWriter(ItemPool.FILE, true, false)
        if not w then return end
        w:write("# StoryEngine item overrides. One rule per line; lines starting with # are ignored.\n")
        w:write("#   exclude <FullType>        never use this item in rewards or trades (e.g. exclude Base.DogfoodOpen)\n")
        w:write("#   exclude <Prefix>*         exclude every item starting with it (e.g. exclude VFX.Frozen*)\n")
        w:write("#   include <food|melee> <tier 1-5> <FullType>   add an item the automatic rules skipped\n")
        w:write("#   ammo <tier 1-5|exclude> <RoundFullType>   gun tier for guns using this round (e.g. ammo 2 Base.CrossbowBolt)\n")
        w:write("# Changes apply after a restart. The debug menu 'StoryEngine: item pool' writes the result to itempool.txt.\n")
        w:close()
    end)
end

-- ---------------------------------------------------------------- classification

-- 총인가. 분류 이름은 모드가 바꿀 수 있어 원거리 여부로 본다
-- (ModernFirearmsSystem 은 시작할 때 모든 총의 DisplayCategory 를 "FireArm" 으로 바꾼다)
-- 탄창·탄약 상자도 AmmoType 을 갖고 있으므로 무기 분류일 때만 AmmoType 으로 인정한다
local function isGun(script, dc)
    if script:isRanged() then return true end
    local d = lower(dc)
    return (d == "weapon" or d == "firearm") and script:getAmmoType() ~= nil
end

-- 근접 무기 풀에 넣는 분류 (조리도구·의료도구·낚싯대는 뺀다)
local MELEE_CATEGORIES = { Weapon = true, ToolWeapon = true, SportsWeapon = true, GardeningWeapon = true,
                           MaterialWeapon = true, WeaponCrafted = true }

local function add(cat, tier, fullType)
    ItemPool.pools[cat] = ItemPool.pools[cat] or {}
    local list = ItemPool.pools[cat][tier] or {}
    list[#list + 1] = fullType
    ItemPool.pools[cat][tier] = list
end

-- 반환: info | nil, 거른 이유 (로그 집계용)
local function foodInfo(script, fullType)
    -- 요리 재료, 말린 곡물·콩(조리 필요). 향신료는 인스턴스로 본다
    -- (스크립트의 Item:isSpice 는 향신료 여부가 아니라 음식·소모품 종류면 참이다 — 42.20.4 바이트코드 확인)
    if hasTag(script, "MINOR_INGREDIENT") or hasTag(script, "DRIED_FOOD") then
        return nil, "ingredient"
    end
    local fresh = script:getDaysFresh()
    if fresh > 0 and fresh < ItemPool.FRESH_DAYS then return nil, "perishable" end
    -- 냄비·그릇·병 등 조리 도구에 담긴 음식 (먹으면 도구가 남는 것)
    local rep = findScript(resolve(script:getReplaceOnUse(), script:getModuleName()))
    if rep and string.sub(tostring(rep:getDisplayCategory()), 1, 7) == "Cooking" then return nil, "cookware" end
    -- 통조림 상자처럼 Food 가 아닌 묶음은 여기서 빠진다 (대가 가치는 classify 가 따로 매김)
    local item = newInstance(fullType)
    if not item or not instanceof(item, "Food") then return nil, "not_food" end
    if item:isSpice() then return nil, "spice" end
    -- 바로 먹을 수 없는 것은 밀봉 통조림(금속)과 과자·사탕 상자만 받는다 (믹스·재료 제외)
    if script:isCantEat() == true and not hasTag(script, "HAS_METAL") then
        local ft = tostring(item:getFoodType())
        if ft ~= "Snack" and ft ~= "Candy" then return nil, "cant_eat" end
    end
    local ok, bad = pcall(function() return item:isbDangerousUncooked() or item:isRotten() or item:isAlcoholic() end)
    if not ok then return nil, "check_error" end
    if bad then return nil, "unsafe" end
    local cal = item:getCalories()
    local hunger = math.abs(item:getHungerChange() or 0) * 100
    if cal < ItemPool.MIN_CALORIES and hunger < 10 then
        -- 물·주스처럼 갈증만 채우는 것은 대가로는 받되 음식 보상 풀에는 넣지 않는다
        local thirst = math.abs(item:getThirstChange() or 0) * 100
        if thirst >= 10 then return { cat = "drink", tier = 1, value = 1 } end
        return nil, "low_calories"
    end
    local tier = tierByBounds(math.max(cal, hunger * 20), ItemPool.FOOD_TIERS)
    return { cat = "food", tier = tier, value = math.max(0.5, math.min(4, cal / 250)) }
end

-- 한 번만 전체를 훑는다
function ItemPool.build()
    if ItemPool.built then return end
    ItemPool.built = true
    local includes, hasFile = readOverrides()
    if not hasFile and not isClient() then writeTemplate() end

    local all = getScriptManager():getAllItems()
    local guns, melee, unknownAmmo = {}, {}, {}
    local counts = { scanned = 0, food = 0, firearm = 0, melee = 0, excluded = 0 }
    local rejected, gunRejected = {}, {}
    for i = 0, all:size() - 1 do
        local script = all:get(i)
        local ok, err = pcall(function()
            local fullType = script:getFullName()
            counts.scanned = counts.scanned + 1
            if script:getObsolete() or script:isHidden() then return end
            if excluded(fullType) then
                counts.excluded = counts.excluded + 1
                return
            end
            local dc = script:getDisplayCategory()
            if dc == "Food" then
                local info, why = foodInfo(script, fullType)
                if why then rejected[why] = (rejected[why] or 0) + 1 end
                if info then
                    ItemPool.info[fullType] = info
                    if info.cat == "food" then
                        add("food", info.tier, fullType)
                        counts.food = counts.food + 1
                    end
                end
            elseif isGun(script, dc) then
                local item, err = newInstance(fullType)
                if not item or not instanceof(item, "HandWeapon") then
                    gunRejected.no_instance = (gunRejected.no_instance or 0) + 1
                    if gunRejected.no_instance <= 3 then
                        StoryEngine.log("item pool gun instance failed:", fullType, tostring(err))
                    end
                    item = nil
                end
                local at = item and item:getAmmoType() or script:getAmmoType()
                local round = at and at:getItemKey() or nil
                local roundScript = findScript(round)
                if not roundScript then
                    gunRejected.no_round = (gunRejected.no_round or 0) + 1
                    if gunRejected.no_round <= 3 then StoryEngine.log("item pool gun without round:", fullType, tostring(round)) end
                    return
                end
                if roundScript:getDisplayCategory() ~= "Ammo" then
                    gunRejected.round_not_ammo = (gunRejected.round_not_ammo or 0) + 1
                    return
                end
                local dmg = item and item:getMaxDamage() or script:getMaxDamage()
                if dmg <= 0 then   -- 장난감 총
                    gunRejected.toy = (gunRejected.toy or 0) + 1
                    return
                end
                local module = script:getModuleName()
                local ammoKey = lower(string.match(round, "([^%.]+)$") or round)
                local ammoTier = ItemPool.AMMO_TIERS[ammoKey]
                if ammoTier == false then
                    gunRejected.excluded_ammo = (gunRejected.excluded_ammo or 0) + 1
                    return
                end
                if ammoTier == nil then
                    unknownAmmo[round] = (unknownAmmo[round] or 0) + 1
                    ammoTier = ItemPool.UNKNOWN_AMMO_TIER
                end
                local g = { fullType = fullType, round = round, tier = ammoTier }
                if item then
                    -- 탄창·상자는 총 아이템에서만 알 수 있다. 20발 이상 탄창이면 자동화기로 5등급
                    g.box = resolve(item:getAmmoBox(), module)
                    g.mag = resolve(item:getMagazineType(), module)
                    if g.mag and item:getMaxAmmo() >= ItemPool.AUTO_AMMO then g.tier = 5 end
                else
                    g.box = resolve(round .. "Box", module)
                end
                guns[#guns + 1] = g
            elseif MELEE_CATEGORIES[dc] then
                local item = newInstance(fullType)
                if item and instanceof(item, "HandWeapon") and item:getMaxDamage() > 0.3 then
                    melee[#melee + 1] = { fullType = fullType, dmg = item:getMaxDamage() }
                end
            end
        end)
        if not ok then StoryEngine.log("item pool skip:", tostring(err)) end
    end

    -- 총 등급 (탄약 기준, 수집할 때 정함)
    for _, g in ipairs(guns) do
        local tier = g.tier
        ItemPool.guns[g.fullType] = { tier = tier, round = g.round, box = g.box, mag = g.mag }
        ItemPool.info[g.fullType] = { cat = "firearm", tier = tier, value = ItemPool.GUN_VALUE[tier] }
        local list = ItemPool.gunsByTier[tier] or {}
        list[#list + 1] = g.fullType
        ItemPool.gunsByTier[tier] = list
        counts.firearm = counts.firearm + 1
        -- 탄약 역할 (대가 가치용)
        ItemPool.ammoRole[g.round] = "round"
        if g.box then ItemPool.ammoRole[g.box] = "box" end
        if g.mag then ItemPool.ammoRole[g.mag] = "mag" end
    end

    -- 근접 무기 등급: 피해 순위 5분위
    table.sort(melee, function(a, b) return a.dmg < b.dmg end)
    for i, m in ipairs(melee) do
        local tier = math.min(5, math.floor((i - 1) * 5 / #melee) + 1)
        ItemPool.info[m.fullType] = { cat = "melee", tier = tier, value = ItemPool.MELEE_VALUE[tier] }
        add("melee", tier, m.fullType)
    end
    counts.melee = #melee

    for _, inc in ipairs(includes) do
        if findScript(inc.fullType) and (inc.cat == "food" or inc.cat == "melee") then
            local tier = math.max(1, math.min(5, math.floor(inc.tier)))
            ItemPool.info[inc.fullType] = { cat = inc.cat, tier = tier,
                value = inc.cat == "food" and 1.5 or ItemPool.MELEE_VALUE[tier] }
            add(inc.cat, tier, inc.fullType)
        end
    end
    ItemPool.stats = counts
    local function tally(t)
        local out = {}
        for k, n in pairs(t) do out[#out + 1] = k .. "=" .. tostring(n) end
        table.sort(out)
        return table.concat(out, " ")
    end
    StoryEngine.log("item pool built: scanned", counts.scanned, "food", counts.food, "firearm", counts.firearm,
        "melee", counts.melee, "excluded", counts.excluded, "| food skipped:", tally(rejected),
        "| guns skipped:", tally(gunRejected), "| unknown ammo (tier " .. ItemPool.UNKNOWN_AMMO_TIER .. "):", tally(unknownAmmo))
end

-- ---------------------------------------------------------------- queries

-- 보상·거래에서 바닐라 구성을 풀의 아이템으로 바꿀 확률 (샌드박스 StoryEngine.ModItemsRatio, 기본 40%)
function ItemPool.ratio()
    local vars = SandboxVars and SandboxVars.StoryEngine
    local v = vars and tonumber(vars.ModItemsRatio)
    if v == nil then return 40 end
    return math.max(0, math.min(100, v))
end

function ItemPool.roll()
    return ZombRand(100) < ItemPool.ratio()
end

-- 대가 가치용 분류. { category, value }
local AMMO_VALUE = { round = 0.5, box = 15, mag = 5 }

function ItemPool.classify(fullType)
    ItemPool.build()
    local info = ItemPool.info[fullType]
    if info then
        if info.cat == "food" or info.cat == "drink" then return { category = "food", value = info.value } end
        return { category = info.cat, value = info.value }
    end
    local role = ItemPool.ammoRole[fullType]
    if role then return { category = "ammo", value = AMMO_VALUE[role] } end
    local script = findScript(fullType)
    if not script then return { category = "misc", value = nil } end
    local dc = script:getDisplayCategory()
    if dc == "Food" then
        -- 통조림 상자처럼 음식을 담은 묶음 (열면 여러 개)
        local item = script:getDoubleClickRecipe() and newInstance(fullType) or nil
        if item and not instanceof(item, "Food") then
            return { category = "food", value = math.max(2, script:getActualWeight() * 2.5) }
        end
        return { category = "misc", value = nil }
    end
    if dc == "Ammo" then
        local name = lower(fullType)
        if string.find(name, "carton", 1, true) then return { category = "ammo", value = 60 } end
        if string.find(name, "box", 1, true) then return { category = "ammo", value = 15 } end
        if string.find(name, "clip", 1, true) or string.find(name, "mag", 1, true) then return { category = "ammo", value = 5 } end
        return { category = "ammo", value = 0.5 }
    end
    if isGun(script, dc) then return { category = "firearm", value = ItemPool.GUN_VALUE[3] } end
    if dc == "Explosives" then return { category = "explosive", value = nil } end
    if dc == "Tool" or dc == "ToolWeapon" then return { category = "tools", value = nil } end
    if dc == "FirstAid" or dc == "FirstAidWeapon" or dc == "Bandage" then return { category = "medical", value = nil } end
    if dc == "Weapon" then return { category = "melee", value = nil } end
    return { category = "misc", value = nil }
end

local function pickFrom(list)
    if not list or #list == 0 then return nil end
    return list[ZombRand(#list) + 1]
end

-- cat 의 tier 근처에서 하나. 없으면 nil
function ItemPool.pick(cat, tier)
    ItemPool.build()
    local byTier = ItemPool.pools[cat]
    if not byTier then return nil end
    for d = 0, 4 do
        local found = pickFrom(byTier[tier - d]) or pickFrom(byTier[tier + d])
        if found then return found end
    end
    return nil
end

-- 같은 분류·비슷한 등급의 다른 아이템 (음식·근접 무기만). 바꿀 수 없으면 원래 것
function ItemPool.substitute(fullType)
    ItemPool.build()
    local info = ItemPool.info[fullType]
    if not info or (info.cat ~= "food" and info.cat ~= "melee") then return fullType end
    return ItemPool.pick(info.cat, info.tier) or fullType
end

-- 등급에 맞는 총 묶음 { { 아이템, 개수 }, ... }. spec = { loose = 낱발 수 } 또는 { boxes = 상자 수, mags = 탄창 수 }
function ItemPool.gunBundle(tier, spec)
    ItemPool.build()
    local ft = nil
    for d = 0, 4 do
        ft = pickFrom(ItemPool.gunsByTier[tier - d])
        if ft then break end
    end
    if not ft then return nil end
    local g = ItemPool.guns[ft]
    local out = { { ft, 1 } }
    if g.mag then out[#out + 1] = { g.mag, spec.mags or 1 } end
    if spec.loose or not g.box then
        out[#out + 1] = { g.round, spec.loose or (spec.boxes or 1) * 20 }
    else
        out[#out + 1] = { g.box, spec.boxes or 1 }
    end
    return out
end

-- 등급에 맞는 탄약만 { { 아이템, 개수 }, ... } (그 등급의 아무 총에 맞는 것)
function ItemPool.ammoBundle(tier, boxes, loose)
    ItemPool.build()
    local ft = pickFrom(ItemPool.gunsByTier[tier]) or pickFrom(ItemPool.gunsByTier[math.max(1, tier - 1)])
    local g = ft and ItemPool.guns[ft]
    if not g then return nil end
    if loose or not g.box then return { { g.round, loose or boxes * 20 } } end
    return { { g.box, boxes } }
end

-- 디버그: 분류 결과를 Zomboid/Lua/StoryEngine/itempool.txt 로
function ItemPool.dump()
    ItemPool.build()
    local w = getFileWriter("StoryEngine/itempool.txt", true, false)
    if not w then return false end
    local s = ItemPool.stats
    w:write("scanned " .. tostring(s.scanned) .. " / food " .. tostring(s.food) .. " / firearm " .. tostring(s.firearm)
        .. " / melee " .. tostring(s.melee) .. " / excluded " .. tostring(s.excluded) .. "\n\n")
    for _, cat in ipairs({ "food", "melee" }) do
        for tier = 1, 5 do
            local list = (ItemPool.pools[cat] or {})[tier] or {}
            table.sort(list)
            w:write("[" .. cat .. " " .. tier .. "] " .. tostring(#list) .. "\n  " .. table.concat(list, ", ") .. "\n")
        end
        w:write("\n")
    end
    for tier = 1, 5 do
        local list = ItemPool.gunsByTier[tier] or {}
        table.sort(list)
        w:write("[firearm " .. tier .. "] " .. tostring(#list) .. "\n")
        for _, ft in ipairs(list) do
            local g = ItemPool.guns[ft]
            w:write("  " .. ft .. "  round=" .. tostring(g.round) .. " box=" .. tostring(g.box) .. " mag=" .. tostring(g.mag) .. "\n")
        end
    end
    w:close()
    return true
end

-- 전체를 훑는 데 시간이 걸리므로 플레이 중이 아니라 시작할 때 미리 만든다 (못 하면 처음 쓸 때 만든다)
local function prebuild()
    local ok, err = pcall(ItemPool.build)
    if not ok then StoryEngine.log("item pool build failed:", tostring(err)) end
end
if Events.OnGameStart then Events.OnGameStart.Add(prebuild) end
if Events.OnServerStarted then Events.OnServerStarted.Add(prebuild) end

return ItemPool
