-- 거래 등급 기준 (2026-10-04 사용자 결정): 음식 배고픔+갈증, 의약품 3단계, 도구 루팅표, 근접 무기 실전 점수,
-- 탄약 구경, 총 = 탄약 + 사격 방식. 가치도 등급을 따른다
local T = {}

local SCRIPTS = {
    ["Base.Bandage"] = { dc = "FirstAid" }, ["Base.Antibiotics"] = { dc = "FirstAid" },
    ["Base.SutureNeedle"] = { dc = "FirstAid" }, ["Base.BandageBox"] = { dc = "FirstAid" },
    ["Base.Tissue"] = { dc = "FirstAid" }, ["MyMod.Salve"] = { dc = "FirstAid" },
    ["Base.Bullets9mm"] = { dc = "Ammo" }, ["Base.Bullets9mmBox"] = { dc = "Ammo" },
    ["Base.Bullets9mmCarton"] = { dc = "Ammo" }, ["Base.308Box"] = { dc = "Ammo" }, ["Base.308Bullets"] = { dc = "Ammo" },
    ["Base.9mmClip"] = { dc = "Ammo" }, ["Base.Bullets50"] = { dc = "Ammo" },
    ["Base.WoodenStick_Broken_Nails"] = { dc = "WeaponCrafted" }, ["Base.Handle"] = { dc = "MaterialWeapon" },
}

local function install()
    getScriptManager = function()
        local function script(ft)
            local s = SCRIPTS[ft]
            if not s then return nil end
            return { getDisplayCategory = function() return s.dc end, getActualWeight = function() return 0.1 end,
                     getDoubleClickRecipe = function() return nil end, isRanged = function() return false end,
                     getAmmoType = function() return nil end }
        end
        return { FindItem = function(_, ft) return script(ft) end, getItem = function(_, ft) return script(ft) end,
                 getAllCraftRecipes = function() return H.list({}) end }
    end
    StoryEngine.ItemPool.built = true
    StoryEngine.ItemPool.info = {}
    StoryEngine.ItemPool.ammoRole = {}
    StoryEngine.ItemPool.ammoTier = {}
    StoryEngine.Value.cache = {}
end

function T.medical_tiers_and_boxes()
    install()
    local V = StoryEngine.Value
    H.eq(V.of("Base.Bandage"), 2, "dressing is tier 1")
    H.eq(V.of("Base.Antibiotics"), 4, "taken by mouth is tier 2")
    H.eq(V.of("Base.SutureNeedle"), 6, "wound care is tier 3")
    H.eq(V.of("Base.BandageBox"), 24, "a box is the bandages inside")
    H.eq(V.categoryOf("Base.Tissue"), "misc", "no healing use")
    H.eq(V.of("MyMod.Salve"), 2, "unknown medical is tier 1")
end

function T.ammo_value_follows_caliber()
    install()
    StoryEngine.ItemPool.ammoTier["Base.9mmClip"] = 1     -- build 가 총에서 알아내는 탄창의 구경
    local V = StoryEngine.Value
    H.eq(V.of("Base.Bullets9mmBox"), 10, "9mm box tier 1")
    H.near(V.of("Base.Bullets9mm"), 0.2, 0.001, "50 rounds a box")
    H.eq(V.of("Base.Bullets9mmCarton"), 120, "12 boxes")
    H.eq(V.of("Base.308Box"), 20, ".308 tier 4")
    H.eq(V.of("Base.308Bullets"), 1, "20 rounds a box")
    H.eq(V.of("Base.9mmClip"), 3)
    H.eq(V.categoryOf("Base.Bullets50"), "misc", ".50 BMG is not traded")
end

local function gun(modes, mode, reload, rack)
    return {
        getFireModePossibilities = function() return modes end, getFireMode = function() return mode end,
        getWeaponReloadType = function() return reload end, isRackAfterShoot = function() return rack end,
    }
end

function T.gun_action_and_tier()
    local IP = StoryEngine.ItemPool
    H.eq(IP.gunAction(gun("[Auto, Single]", "Auto", "boltaction", false)), "auto")
    H.eq(IP.gunAction(gun(nil, "Single", "boltactionnomag", true)), "manual", "bolt rifle")
    H.eq(IP.gunAction(gun(nil, nil, "doublebarrelshotgun", false)), "manual", "double barrel")
    H.eq(IP.gunAction(gun(nil, nil, "shotgun", true)), "pump", "pump shotgun keeps its tier")
    H.eq(IP.gunAction(gun(nil, nil, "handgun", false)), "semi")
    H.eq(IP.gunAction(gun(nil, nil, "revolver", false)), "semi")
    H.eq(IP.AMMO_TIERS["308bullets"] + IP.ACTION_MOD.manual, 2, ".308 bolt rifle is tier 2")
    H.eq(math.min(5, IP.AMMO_TIERS["556bullets"] + IP.ACTION_MOD.auto), 5, "5.56 automatic is tier 5")
    H.eq(IP.AMMO_TIERS.shotgunshells + IP.ACTION_MOD.pump, 4, "pump shotgun stays tier 4")
end

function T.melee_exclusions_and_score()
    local IP = StoryEngine.ItemPool
    H.ok(IP.meleeExcluded("Base.BareHands", "Weapon"), "bare hands")
    H.ok(IP.meleeExcluded("Base.WoodenStick_Broken_Nails", "WeaponCrafted"), "broken")
    H.ok(IP.meleeExcluded("Base.Handle", "MaterialWeapon"), "weapon part")
    H.ok(not IP.meleeExcluded("Base.MetalPipe", "MaterialWeapon"), "metal pipe is a real weapon")
    H.ok(not IP.meleeExcluded("Base.Katana", "Weapon"))
    local function w(minD, maxD, cond, chance, speed, hits)
        return { getMinDamage = function() return minD end, getMaxDamage = function() return maxD end,
                 getConditionMax = function() return cond end, getConditionLowerChance = function() return chance end,
                 getBaseSpeed = function() return speed end, getMaxHitCount = function() return hits end }
    end
    local glassSpear = IP.meleeScore(w(1.2, 2.0, 2, 2, 1, 1))
    local railSpike = IP.meleeScore(w(0.3, 0.4, 15, 30, 1, 1))
    H.ok(railSpike > glassSpear, "a weapon that lasts beats a strong one that breaks at once")
    H.near(IP.meleeScore(w(1, 1, 10, 10, 1, 1)), 100, 0.001, "damage x life")
end

function T.food_relief_uses_what_is_inside_a_sealed_can()
    local IP = StoryEngine.ItemPool
    local opened = { getHungerChange = function() return -0.24 end, getThirstChange = function() return 0 end }
    instanceItem = function(ft) if ft == "Base.OpenBeans" then return opened end end
    local can = { getHungerChange = function() return 0 end, getThirstChange = function() return 0 end }
    local h, t = IP.foodRelief(can, "Base.TinnedBeans")
    H.near(h, 24, 0.001)
    H.eq(t, 0)
    local salty = { getHungerChange = function() return -0.1 end, getThirstChange = function() return 0.2 end }
    h, t = IP.foodRelief(salty, "Base.Crisps")
    H.near(h, 10, 0.001)
    H.eq(t, 0, "salty food does not count thirst")
end

return T
