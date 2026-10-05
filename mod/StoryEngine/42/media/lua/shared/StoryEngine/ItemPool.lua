-- 설치된 모든 아이템(바닐라 + 다른 모드)을 훑어 분류·등급을 매긴다. 서버(보상·거래)와 클라이언트(대가 가치)가 같이 쓴다.
--
-- 이름이 아니라 아이템 속성으로 판단한다 (모드마다 이름 규칙이 달라서).
--   food    : 먹을 수 있고 상하지 않는(또는 밀봉된) 음식. 향신료·재료(minoringredient)·상하는 음식·위험한 날것은 뺀다.
--             통조림 상자처럼 음식을 담은 묶음은 foodBox (대가로만 받는다)
--   firearm : 원거리 무기 + 등록된 탄약(AmmoType).
--   ammo    : 총이 가리키는 낱발(AmmoType)·상자(AmmoBox)·탄창(MagazineType)
--   melee   : 근접 무기 (DisplayCategory Weapon)
-- 나머지(도구·의약품 등)는 DisplayCategory 로만 분류한다 (보상 목록은 바닐라 그대로).
-- 도구 (2026-09-30 좁힘): Tool·ToolWeapon (망치·렌치·쇠지렛대처럼 무기 겸 도구도 거래·물자 지원에서는 도구, 보상 근접 무기
--   풀은 그대로). 디버그·틀·굽지 않은 것·부품·씨앗 반죽·담뱃잎은 도구가 아니다.
--
-- 등급 기준 (2026-10-04 사용자 결정, 가치도 등급을 따른다. 게임 밖에서만 알 수 있는 값은 ItemTiers.lua 표):
--   음식    : 배고픔 + 갈증이 줄어드는 양 (따기 전 통조림·상자는 안에 든 음식 x 개수). 10 미만 / 10~14 / 15~24 / 25~39 / 40+
--   의약품  : 1 덮기·소독 / 2 먹는 약 / 3 큰 상처 처치 (ItemTiers.MEDICAL). 휴지·청진기·설압자는 의약품 아님
--   도구    : 바닐라 루팅표 등장 가중치 (ItemTiers.TOOLS, 흔할수록 낮음). 손으로 만드는 도구·낡은 변형은 거래 안 함
--   근접 무기: 실전 점수 = 평균 피해 x 속도^0.5 x 수명^1 x 타격 수^0.5 (수명 = 최대 내구도 x 내구 감소 확률 분모)의
--             5분위 (도구 겸 무기는 빼고 나눈 경계로). 부서진 무기·재료(손잡이·쇠스랑 머리 등)·맨손은 빼고,
--             판자·금속 파이프·납 파이프·강철 봉·장작은 넣는다
--   탄약    : 구경 위력. 1 .38·9mm·.45·석궁 화살 / 2 .357·.44 / 3 5.45·5.56·5.8 / 4 .30-30·12게이지·.308 / 5 .338.
--             .50 BMG·14.5mm·유탄·화염 연료는 뺀다. 모르는 탄약은 3등급 (items.txt 의 ammo 줄로 지정)
--   총기    : 탄약 등급 + 자동 사격 가능 +2, 수동 장전(볼트·레버·더블 배럴) -2, 펌프 산탄총·반자동·리볼버는 그대로
--
-- 조정 파일 Zomboid/Lua/StoryEngine/items.txt (없으면 서버가 설명을 담아 만든다):
--   exclude <아이템 또는 접두어*>          예) exclude Base.DogfoodOpen   exclude VFX.Frozen*
--   include <food|melee> <등급> <아이템>   예) include food 3 VFX.CannedBeefRavioli
--   ammo <1-5|exclude> <낱발 아이템>       예) ammo 2 Base.CrossbowBolt   (그 탄약을 쓰는 총의 등급)
--   category <분류 이름> <종류>            예) category MyModMeds medical   (모드가 쓰는 DisplayCategory 를 종류로)
--       종류: tools | medical | explosive | melee | ammo | literature (기호품 읽을거리) | vehicle | none
-- 분류 이름은 바닐라 이름 말고도 모드가 흔히 쓰는 이름(Tools, Medical, Medicine, Explosive, Melee, Book, CarParts ...)을
-- 대소문자 없이 받는다 (ItemPool.CATEGORY_KINDS, 2026-09-30). 모드 아이템 중 어디에도 안 맞는 분류 이름은
-- 로그와 itempool.txt 에 모아 보여 준다 (ItemPool.unmapped).

require "StoryEngine/Core"
require "StoryEngine/ItemTiers"

local ItemPool = {
    built = false,
    info = {},         -- fullType -> { cat, tier, value, ... }
    pools = {},        -- cat -> tier -> { fullType, ... }
    guns = {},         -- fullType -> { tier, round, box, mag }
    gunsByTier = {},   -- tier -> { fullType, ... }
    ammoRole = {},     -- fullType -> "round" | "box" | "mag"
    ammoTier = {},     -- 낱발·상자·탄창 fullType -> 탄약(구경) 등급
    excludes = {}, prefixes = {},
    stats = {},
}
StoryEngine.ItemPool = ItemPool

ItemPool.FILE = "StoryEngine/items.txt"
ItemPool.FRESH_DAYS = 30            -- 이보다 빨리 상하면 보상에서 뺀다 (0 은 상하지 않음)
ItemPool.FOOD_TIERS = { 10, 15, 25, 40 }   -- 배고픔 + 갈증 해소 경계 -> 1~5등급
ItemPool.UNKNOWN_AMMO_TIER = 3

-- 낱발 아이템(모듈 없이, 소문자) -> 탄약(구경) 등급. false 는 제외
ItemPool.AMMO_TIERS = {
    bullets38 = 1, bullets9mm = 1, bullets45 = 1, crossbowbolt = 1,
    bullets357 = 2, bullets44 = 2,
    ["545bullets"] = 3, ["556bullets"] = 3, a_58bullets = 3,
    ["3030bullets"] = 4, shotgunshells = 4, ["308bullets"] = 4,
    bullets86 = 5,
    bullets50 = false, bullets145 = false, grenadeammo = false, flamefuel = false,
}
-- 총 등급 = 탄약 등급 + 사격 방식 + 기본 탄창 용량 (1~5로 자름)
ItemPool.ACTION_MOD = { auto = 2, manual = -2, pump = 0, semi = 0 }
-- 탄창 용량 (2026-10-05 사용자 요청: 많이 들어가는 탄창은 희귀). 총에 끼워져 나오는 탄창(또는 총의 장탄수)이
-- 이 발 수 이상이면 등급 +1/+2/+3. 9mm 권총 17발 0, 30발 연장 탄창 +1, 50발 드럼 +2, 100발 드럼 +3.
-- 같은 탄창을 따로 볼 때(대가 가치)도 탄창 값을 그만큼 높인다 (ItemPool.magBonus)
ItemPool.CAPACITY_MOD = { { 60, 3 }, { 36, 2 }, { 21, 1 } }
ItemPool.magBonus = {}     -- 탄창 fullType -> 용량 보정

function ItemPool.capacityMod(rounds)
    rounds = tonumber(rounds) or 0
    for _, row in ipairs(ItemPool.CAPACITY_MOD) do
        if rounds >= row[1] then return row[2] end
    end
    return 0
end
ItemPool.MANUAL_RELOAD = { boltactionnomag = true, leveraction = true, doublebarrelshotgun = true,
                           doublebarrelshotgunsawn = true }
-- 분류 이름(DisplayCategory, 소문자) -> 종류
ItemPool.CATEGORY_KINDS = {
    tools = { "tool", "tools", "toolweapon", "toolkit", "hardware" },
    medical = { "firstaid", "firstaidweapon", "bandage", "medical", "medicine", "medic", "medkit", "pharmacy",
                "health", "healthcare" },
    explosive = { "explosives", "explosive", "bomb", "bombs", "grenade", "grenades" },
    melee = { "weapon", "melee", "meleeweapon", "weaponmelee", "sportsweapon", "gardeningweapon", "materialweapon",
              "weaponcrafted", "blade", "blades", "blunt" },
    ammo = { "ammo", "ammunition" },
    literature = { "literature", "book", "books", "magazine", "magazines", "reading" },
    vehicle = { "vehiclemaintenance", "vehiclemaintenanceweapon", "vehicle", "vehicleparts", "carparts", "carpart",
                "autoparts" },
}
ItemPool.KIND_NAMES = { tools = true, medical = true, explosive = true, melee = true, ammo = true, literature = true,
                        vehicle = true, none = true, comfort = true }
-- 모드 아이템이 이 분류면 "모르는 분류"로 알리지 않는다 (거래·지원과 상관없는 바닐라 분류)
ItemPool.KNOWN_OTHER = {
    food = true, clothing = true, material = true, accessory = true, furniture = true, protectivegear = true,
    memento = true, container = true, reciperesource = true, skillbook = true, gardening = true, junk = true, bag = true,
    zeddmg = true, animalpart = true, wound = true, cooking = true, camping = true, electronics = true,
    appearance = true, household = true, watercontainer = true, lightsource = true, paint = true, fishing = true,
    communications = true, cartography = true, weaponpart = true, sports = true, trapping = true, security = true,
    hidden = true, cookingweapon = true, householdweapon = true, junkweapon = true, instrumentweapon = true,
    animalpartweapon = true, firearm = true, animal = true, badger = true, bear = true, beaver = true,
    brokenweapon = true, bug = true, bunny = true, corpse = true, dog = true, duck = true, ears = true,
    entertainment = true, eye = true, firesource = true, fishingweapon = true, fox = true, frog = true, generic = true,
    goblin = true, hedgehog = true, instrument = true, malebody = true, mole = true, raccoon = true, spider = true,
    squirrel = true, tail = true, teddy = true, water = true, weaponimprovised = true,
    ["teddy bear"] = true,        -- 42.21 에 생긴 바닐라 분류 (이름에 빈칸)
}
ItemPool.categoryOverrides = {}     -- items.txt 'category': 소문자 분류 이름 -> 종류
ItemPool.unmapped = {}              -- 모드 아이템의 모르는 분류 이름 -> { n, example }

local KIND_OF = {}
for kind, names in pairs(ItemPool.CATEGORY_KINDS) do
    for _, n in ipairs(names) do KIND_OF[n] = kind end
end

-- 등급별 가치
ItemPool.GUN_VALUE = { 30, 40, 50, 65, 80 }
ItemPool.MELEE_VALUE = { 3, 4, 5, 8, 12 }
ItemPool.FOOD_VALUE = { 0.5, 1, 1.5, 2.5, 4 }
ItemPool.MEDICAL_VALUE = { 2, 4, 6 }
ItemPool.TOOL_VALUE = { 2, 4, 8, 14, 20 }
ItemPool.AMMO_BOX_VALUE = { 10, 13, 15, 20, 30 }   -- 상자 하나 (낱발 = 상자 / 상자 속 발 수, 카톤 = 상자 x 개수)
ItemPool.AMMO_MAG_VALUE = { 3, 4, 5, 6, 8 }
ItemPool.TOOL_UNKNOWN_TIER = 3       -- 루팅표를 모르는 모드 도구
ItemPool.MEDICAL_UNKNOWN_TIER = 1    -- 표에 없는 의약품
ItemPool.TOOL_NOT = { "Debug", "Mold", "Unfired", "Parts", "SeedPaste", "Tobacco" }   -- 이름에 들어가면 도구가 아님
-- 손으로 만드는 도구·낡은 변형 (모드 도구에도 같은 이름 규칙): 거래·물자 지원에서 도구로 치지 않는다
ItemPool.TOOL_HANDMADE = { "Forged", "Stone", "Bone", "Crude", "Carved", "Flint", "Improvised", "Crafted", "_Scrap",
                           "Knapping", "_Wood", "_Old", "Old" }
-- 근접 무기 실전 점수의 비중 (거래 핵심 표 편집기에서 정한 값)
ItemPool.MELEE_WEIGHTS = { life = 1, speed = 0.5, hits = 0.5 }
ItemPool.MELEE_MATERIAL_OK = { ["Base.Plank"] = true, ["Base.MetalPipe"] = true, ["Base.LeadPipe"] = true,
                               ["Base.MetalBar"] = true, ["Base.Firewood"] = true }
ItemPool.MELEE_OVERRIDE = {}         -- fullType -> 등급 (편집기 '직접 지정')
ItemPool.meleeBounds = nil           -- 근접 무기 점수 경계 4개 (build 가 정함)

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
    ItemPool.categoryOverrides = {}
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
        elseif words[1] == "category" and words[3] then
            local kind = string.lower(words[3])
            if kind == "comfort" then kind = "literature" end
            if ItemPool.KIND_NAMES[kind] then
                ItemPool.categoryOverrides[string.lower(words[2])] = kind
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
        w:write("#   category <DisplayCategory> <tools|medical|explosive|melee|ammo|literature|vehicle|none>   treat a mod's item category as this kind\n")
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

-- 분류 이름의 종류 (tools | medical | explosive | melee | ammo | literature | vehicle | nil)
function ItemPool.categoryKind(dc)
    if not dc or dc == "" then return nil end
    local key = lower(dc)
    local o = ItemPool.categoryOverrides[key]
    if o then return o ~= "none" and o or nil end
    return KIND_OF[key]
end

-- 근접 무기 풀에 넣는 분류 (근접 무기 종류 + 무기 겸 도구. 조리도구·의료도구·낚싯대는 뺀다)
function ItemPool.meleeCandidate(dc)
    return ItemPool.categoryKind(dc) == "melee" or lower(dc) == "toolweapon"
end

-- 총의 사격 방식: auto (자동 사격 가능) | manual (볼트·레버·더블 배럴) | pump | semi (반자동·리볼버)
function ItemPool.gunAction(item)
    local action = "semi"
    pcall(function()
        local modes = tostring(item:getFireModePossibilities() or "") .. " " .. tostring(item:getFireMode() or "")
        local reload = lower(item:getWeaponReloadType())
        if string.find(lower(modes), "auto", 1, true) then
            action = "auto"
        elseif reload == "shotgun" then
            action = "pump"      -- 펌프 산탄총은 등급을 바꾸지 않는다 (2026-10-04 사용자 결정)
        elseif item:isRackAfterShoot() or ItemPool.MANUAL_RELOAD[reload] then
            action = "manual"
        end
    end)
    return action
end

-- 거래·보상에서 빼는 근접 무기: 맨손, 부서진 무기, 무기 재료(손잡이·쇠스랑 머리·막대 등, 많이 쓰는 다섯 개는 넣음)
function ItemPool.meleeExcluded(fullType, dc)
    local name = string.match(fullType, "%.(.+)$") or fullType
    if name == "BareHands" or string.find(name, "Broken", 1, true) then return true end
    return lower(dc) == "materialweapon" and not ItemPool.MELEE_MATERIAL_OK[fullType]
end

-- 실전 점수 = 평균 피해 x 속도^w x 수명^w x 타격 수^w (수명 = 최대 내구도 x 내구 감소 확률 분모)
function ItemPool.meleeScore(item)
    local w = ItemPool.MELEE_WEIGHTS
    local score = 0
    pcall(function()
        local avg = ((item:getMinDamage() or 0) + (item:getMaxDamage() or 0)) / 2
        local life = math.max(1, (item:getConditionMax() or 1) * math.max(1, item:getConditionLowerChance() or 1))
        local speed = item:getBaseSpeed() or 1
        if speed <= 0 then speed = 1 end
        local hits = math.max(1, item:getMaxHitCount() or 1)
        score = avg * speed ^ w.speed * life ^ w.life * hits ^ w.hits
    end)
    return score
end

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
    local hunger, thirst = ItemPool.foodRelief(item, fullType)
    if hunger <= 0 and thirst <= 0 then return nil, "no_relief" end
    if hunger < 5 and thirst >= 10 then
        -- 물·주스처럼 갈증만 채우는 것은 대가로는 받되 음식 보상 풀에는 넣지 않는다
        return { cat = "drink", tier = 1, value = ItemPool.FOOD_VALUE[1] }
    end
    local tier = tierByBounds(hunger + thirst, ItemPool.FOOD_TIERS)
    return { cat = "food", tier = tier, value = ItemPool.FOOD_VALUE[tier] }
end

-- 음식 하나가 줄여 주는 배고픔·갈증 (0~100 단위, 갈증을 늘리면 0). 따기 전 통조림·상자처럼 수치가 없으면
-- 안에 든 음식(ItemTiers.CONTENTS) x 개수
function ItemPool.foodRelief(item, fullType, depth)
    local h, t = 0, 0
    pcall(function()
        h = -(item:getHungerChange() or 0) * 100
        t = -(item:getThirstChange() or 0) * 100
    end)
    h, t = math.max(0, h), math.max(0, t)
    if h > 0 or t > 0 or (depth or 0) >= 2 then return h, t end
    local inside = StoryEngine.ItemTiers.CONTENTS[fullType]
    if not inside then return h, t end
    local child = newInstance(inside[1])
    if not child then return h, t end
    local ch, ct = ItemPool.foodRelief(child, inside[1], (depth or 0) + 1)
    return ch * inside[2], ct * inside[2]
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
            -- 바닐라 분류는 모두 KNOWN_OTHER 나 CATEGORY_KINDS 에 있어 여기 걸리는 것은 모드가 만든 분류 이름이다
            -- (모드가 Base 모듈에 아이템을 넣기도 해서 모듈 이름으로 거르지 않는다)
            if dc and not ItemPool.categoryKind(dc) and not ItemPool.KNOWN_OTHER[lower(dc)]
                and not ItemPool.categoryOverrides[lower(dc)] and not isGun(script, dc) then
                local u = ItemPool.unmapped[dc] or { n = 0, example = fullType }
                u.n = u.n + 1
                ItemPool.unmapped[dc] = u
            end
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
                local g = { fullType = fullType, round = round, ammoTier = ammoTier, tier = ammoTier, action = "semi" }
                if item then
                    -- 탄창·상자·사격 방식은 총 아이템에서만 알 수 있다
                    g.box = resolve(item:getAmmoBox(), module)
                    g.mag = resolve(item:getMagazineType(), module)
                    g.action = ItemPool.gunAction(item)
                    -- 장탄수: 탄창이 있으면 그 탄창, 없으면 총 (리볼버 실린더·관형 탄창)
                    local rounds = 0
                    local magItem = g.mag and newInstance(g.mag) or nil
                    if magItem then pcall(function() rounds = magItem:getMaxAmmo() end) end
                    if (tonumber(rounds) or 0) <= 0 then pcall(function() rounds = item:getMaxAmmo() end) end
                    g.rounds = tonumber(rounds) or 0
                    g.capMod = ItemPool.capacityMod(g.rounds)
                    g.tier = math.max(1, math.min(5, ammoTier + ItemPool.ACTION_MOD[g.action] + g.capMod))
                else
                    g.box = resolve(round .. "Box", module)
                end
                guns[#guns + 1] = g
            elseif ItemPool.meleeCandidate(dc) then
                local item = newInstance(fullType)
                if item and instanceof(item, "HandWeapon") and item:getMaxDamage() > 0.3
                    and not ItemPool.meleeExcluded(fullType, dc) then
                    melee[#melee + 1] = { fullType = fullType, score = ItemPool.meleeScore(item),
                                          tool = lower(dc) == "toolweapon" }
                end
            end
        end)
        if not ok then StoryEngine.log("item pool skip:", tostring(err)) end
    end

    -- 총 등급 (탄약 + 사격 방식, 수집할 때 정함)
    for _, g in ipairs(guns) do
        local tier = g.tier
        ItemPool.guns[g.fullType] = { tier = tier, round = g.round, box = g.box, mag = g.mag, ammoTier = g.ammoTier,
                                      action = g.action, rounds = g.rounds, capMod = g.capMod }
        if g.mag and g.capMod and g.capMod > 0 then ItemPool.magBonus[g.mag] = g.capMod end
        ItemPool.ammoTier[g.round] = g.ammoTier
        if g.box then ItemPool.ammoTier[g.box] = g.ammoTier end
        if g.mag then ItemPool.ammoTier[g.mag] = g.ammoTier end
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

    -- 근접 무기 등급: 실전 점수 5분위. 경계는 도구 겸 무기를 뺀 근접 무기로 정하고 도구 겸 무기도 그 경계로 나눈다
    local ranked = {}
    for _, m in ipairs(melee) do
        if not m.tool then ranked[#ranked + 1] = m.score end
    end
    table.sort(ranked)
    if #ranked >= 5 then
        ItemPool.meleeBounds = {}
        for q = 1, 4 do ItemPool.meleeBounds[q] = ranked[math.ceil(q * #ranked / 5) + 1] end
    end
    for _, m in ipairs(melee) do
        local tier = ItemPool.MELEE_OVERRIDE[m.fullType]
            or (ItemPool.meleeBounds and tierByBounds(m.score, ItemPool.meleeBounds)) or 3
        ItemPool.info[m.fullType] = { cat = "melee", tier = tier, value = ItemPool.MELEE_VALUE[tier], score = m.score,
                                      tool = m.tool }
        add("melee", tier, m.fullType)
    end
    counts.melee = #melee

    for _, inc in ipairs(includes) do
        if findScript(inc.fullType) and (inc.cat == "food" or inc.cat == "melee") then
            local tier = math.max(1, math.min(5, math.floor(inc.tier)))
            ItemPool.info[inc.fullType] = { cat = inc.cat, tier = tier,
                value = inc.cat == "food" and ItemPool.FOOD_VALUE[tier] or ItemPool.MELEE_VALUE[tier] }
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
    local unmapped = {}
    for dc, u in pairs(ItemPool.unmapped) do unmapped[#unmapped + 1] = dc .. "=" .. tostring(u.n) .. " (" .. u.example .. ")" end
    table.sort(unmapped)
    if #unmapped > 0 then
        StoryEngine.log("item pool: mod item categories not used for trade/donation (map them with items.txt 'category'):",
            table.concat(unmapped, ", "))
    end
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

-- 대가 가치용 분류. { category, value, tier }

-- 탄약 아이템(낱발·상자·탄창·카톤)의 구경 등급. 모르면 nil, 빼는 탄이면 false
function ItemPool.ammoTierOf(fullType)
    local t = ItemPool.ammoTier[fullType]
    if t then return t end
    local inside = StoryEngine.ItemTiers.CONTENTS[fullType]    -- 카톤 -> 상자 -> 낱발
    if inside then return ItemPool.ammoTierOf(inside[1]) end
    local key = lower(string.match(fullType, "([^%.]+)$") or fullType)
    return ItemPool.AMMO_TIERS[key]
end

-- 도구 분류와 가치 (도구가 아니면 nil)
local function toolClass(script, fullType, dc)
    if ItemPool.categoryKind(dc) ~= "tools" then return nil end
    local name = string.match(fullType, "%.(.+)$") or fullType
    for _, word in ipairs(ItemPool.TOOL_NOT) do
        if string.find(name, word, 1, true) then return { category = "misc", value = nil } end
    end
    local Tiers = StoryEngine.ItemTiers
    if Tiers.TOOL_EXCLUDED[fullType] then return { category = "misc", value = nil } end
    local tier = Tiers.TOOLS[fullType]
    if not tier then
        for _, word in ipairs(ItemPool.TOOL_HANDMADE) do
            if string.find(name, word, 1, true) then return { category = "misc", value = nil } end
        end
        tier = ItemPool.TOOL_UNKNOWN_TIER
    end
    return { category = "tools", value = ItemPool.TOOL_VALUE[tier], tier = tier }
end

-- 의약품 등급과 가치. 의약품으로 치지 않는 것이면 misc
local function medicalClass(fullType)
    local Tiers = StoryEngine.ItemTiers
    if Tiers.MEDICAL_NO_USE[fullType] then return { category = "misc", value = nil } end
    local tier = Tiers.MEDICAL[fullType] or ItemPool.MEDICAL_UNKNOWN_TIER
    return { category = "medical", value = ItemPool.MEDICAL_VALUE[tier], tier = tier }
end

-- 탄약 가치: 상자 = 등급 값, 탄창 = 등급 값, 낱발·카톤은 Value.ammoValue 가 상자에서 나눈다/곱한다
local function ammoClass(fullType, role)
    local tier = ItemPool.ammoTierOf(fullType)
    if tier == false then return { category = "misc", value = nil } end
    tier = tier or ItemPool.UNKNOWN_AMMO_TIER
    local name = lower(fullType)
    if not role then
        if string.find(name, "box", 1, true) then role = "box"
        elseif string.find(name, "clip", 1, true) or string.find(name, "mag", 1, true)
            or string.find(name, "drum", 1, true) then role = "mag"
        elseif string.find(name, "carton", 1, true) then role = "carton"
        else role = "round" end
    end
    local value = ItemPool.AMMO_BOX_VALUE[tier]
    if role == "mag" then
        value = ItemPool.AMMO_MAG_VALUE[math.min(#ItemPool.AMMO_MAG_VALUE, tier + (ItemPool.magBonus[fullType] or 0))]
    end
    if role == "carton" then value = ItemPool.AMMO_BOX_VALUE[tier] * 12 end
    if role == "round" then value = ItemPool.AMMO_BOX_VALUE[tier] / 20 end
    return { category = "ammo", value = value, tier = tier, role = role }
end

function ItemPool.classify(fullType)
    ItemPool.build()
    -- 도구는 근접 무기 풀에 들어 있어도 도구로 친다
    local tscript = findScript(fullType)
    local tool = tscript and toolClass(tscript, fullType, tscript:getDisplayCategory()) or nil
    if tool then return tool end
    local info = ItemPool.info[fullType]
    if info then
        if info.cat == "food" or info.cat == "drink" then return { category = "food", value = info.value, tier = info.tier } end
        return { category = info.cat, value = info.value, tier = info.tier }
    end
    local role = ItemPool.ammoRole[fullType]
    if role then return ammoClass(fullType, role) end
    local script = findScript(fullType)
    if not script then return { category = "misc", value = nil } end
    local dc = script:getDisplayCategory()
    if dc == "Food" then
        -- 통조림 상자처럼 음식을 담은 묶음 (열면 여러 개). 안에 든 것을 알면 Value 가 개수만큼 곱한다
        local item = script:getDoubleClickRecipe() and newInstance(fullType) or nil
        if item and not instanceof(item, "Food") then
            return { category = "food", value = math.max(2, script:getActualWeight() * 2.5) }
        end
        return { category = "misc", value = nil }
    end
    local kind = ItemPool.categoryKind(dc)
    if kind == "ammo" then return ammoClass(fullType, nil) end
    if isGun(script, dc) then return { category = "firearm", value = ItemPool.GUN_VALUE[3], tier = 3 } end
    if kind == "explosive" then return { category = "explosive", value = nil } end
    if kind == "medical" then return medicalClass(fullType) end
    if kind == "melee" then
        -- 근접 무기 풀에 없는 것 (부서진 무기·재료·맨손, 피해가 아주 낮은 것)은 거래하지 않는다
        return { category = "misc", value = nil }
    end
    -- 전자기기(케이시)·차량 부품(듀이): 대가 품목은 아니지만 파는 물건이라 등급 가치가 있다
    local lt = StoryEngine.ItemTiers.ELECTRONICS[fullType] or StoryEngine.ItemTiers.VEHICLE[fullType]
    if lt then return { category = "misc", value = ItemPool.TOOL_VALUE[lt], tier = lt } end
    return { category = "misc", value = nil }
end

-- ---------------------------------------------------------------- 거래 묶음용 (Trade.generate)

local vanillaCache = {}
-- 바닐라 아이템인가 (모드가 덮어쓴 바닐라 아이템도 바닐라). 모르면 Base 모듈이면 바닐라로 본다
function ItemPool.isVanilla(fullType)
    local hit = vanillaCache[fullType]
    if hit ~= nil then return hit end
    local yes = nil
    local script = findScript(fullType)
    if script then
        local ok, v = pcall(function() return script:getExistsAsVanilla() end)
        if ok and type(v) == "boolean" then yes = v end
    end
    if yes == nil then yes = string.sub(fullType, 1, 5) == "Base." end
    vanillaCache[fullType] = yes
    return yes
end

-- 목록에서 하나: 바닐라·모드 물건이 둘 다 있으면 샌드박스 '모드 아이템 비율' 확률로 모드 쪽에서
function ItemPool.pickMixed(list)
    if not list or #list == 0 then return nil end
    local van, mod = {}, {}
    for _, ft in ipairs(list) do
        if ItemPool.isVanilla(ft) then van[#van + 1] = ft else mod[#mod + 1] = ft end
    end
    local from = van
    if #van == 0 or (#mod > 0 and ItemPool.roll()) then from = mod end
    return from[ZombRand(#from) + 1]
end

local tradePools = {}
-- 거래에서 파는 물건 풀: tier -> { fullType, ... }
--   food·melee(도구 겸 무기 제외)·firearm 은 build 결과, ammo 는 총이 쓰는 상자(없으면 낱발)의 구경 등급,
--   medical·tools·electronics·vehicle 은 ItemTiers 표 (vehicle 에는 듀이의 정비 도구도)
function ItemPool.tradePool(name)
    ItemPool.build()
    if tradePools[name] then return tradePools[name] end
    local out = {}
    local function put(tier, ft)
        if not tier or not findScript(ft) then return end
        out[tier] = out[tier] or {}
        local list = out[tier]
        for _, x in ipairs(list) do if x == ft then return end end
        list[#list + 1] = ft
    end
    local Tiers = StoryEngine.ItemTiers
    if name == "food" then
        for t, list in pairs(ItemPool.pools.food or {}) do for _, ft in ipairs(list) do put(t, ft) end end
    elseif name == "melee" then
        for t, list in pairs(ItemPool.pools.melee or {}) do
            for _, ft in ipairs(list) do
                if not (ItemPool.info[ft] and ItemPool.info[ft].tool) then put(t, ft) end
            end
        end
    elseif name == "firearm" then
        for t, list in pairs(ItemPool.gunsByTier) do for _, ft in ipairs(list) do put(t, ft) end end
    elseif name == "ammo" then
        for _, g in pairs(ItemPool.guns) do put(g.ammoTier, g.box or g.round) end
    elseif name == "medical" then
        for ft, t in pairs(Tiers.MEDICAL) do put(t, ft) end
    elseif name == "tools" then
        for ft, t in pairs(Tiers.TOOLS) do put(t, ft) end
    elseif name == "electronics" then
        for ft, t in pairs(Tiers.ELECTRONICS) do put(t, ft) end
    elseif name == "vehicle" then
        for ft, t in pairs(Tiers.VEHICLE) do put(t, ft) end
        local Value = StoryEngine.Value
        for ft in pairs(Value and Value.VEHICLE_TOOLS or {}) do put(Tiers.TOOLS[ft], ft) end
    end
    for _, list in pairs(out) do table.sort(list) end
    tradePools[name] = out
    return out
end

-- 시험·디버그: 풀을 다시 만들게 한다
function ItemPool.resetTradePools()
    tradePools, vanillaCache = {}, {}
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
    local unmapped = {}
    for dc, u in pairs(ItemPool.unmapped) do unmapped[#unmapped + 1] = { dc = dc, n = u.n, example = u.example } end
    table.sort(unmapped, function(a, b) return a.n > b.n end)
    w:write("[mod categories not used] " .. tostring(#unmapped)
        .. "  (map one with a line in items.txt: category <name> <tools|medical|explosive|melee|ammo|literature|vehicle|none>)\n")
    for _, u in ipairs(unmapped) do
        w:write("  " .. u.dc .. "  x" .. tostring(u.n) .. "  e.g. " .. u.example .. "\n")
    end
    w:write("\n")
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
            w:write("  " .. ft .. "  round=" .. tostring(g.round) .. " box=" .. tostring(g.box) .. " mag=" .. tostring(g.mag)
                .. " rounds=" .. tostring(g.rounds) .. " cap=+" .. tostring(g.capMod or 0) .. " " .. tostring(g.action) .. "\n")
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
