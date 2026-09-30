-- 도구·기호품 분류 규칙 (2026-09-30 좁힘): ItemPool.classify 의 도구, Value.moraleValue
local T = {}

-- 가짜 아이템 스크립트: fullType -> { dc, weight, alcohol }
local SCRIPTS = {
    ["Base.Hammer"] = { dc = "ToolWeapon", weight = 1.5 },
    ["Base.Needle"] = { dc = "Tool", weight = 0.01 },
    ["Base.Pliers"] = { dc = "Tool", weight = 0.3 },
    ["Base.BlacksmithAnvil"] = { dc = "Tool", weight = 40 },
    ["Base.ClayCrudeBenchVisePartsMold"] = { dc = "Tool", weight = 0.3 },
    ["Base.CrudeBenchViseParts"] = { dc = "Tool", weight = 5 },
    ["Base.DebugFluid"] = { dc = "Tool", weight = 0.1 },
    ["Base.Tobacco"] = { dc = "Tool", weight = 0.2 },
    ["Base.TobaccoDried"] = { dc = "Tool", weight = 0.2 },
    ["Base.WeldingMask"] = { dc = "Tool", weight = 1 },
    ["Base.Axe"] = { dc = "ToolWeapon", weight = 3 },
    ["Base.Book_Art"] = { dc = "Literature", weight = 0.5 },
    ["Base.Magazine_Car"] = { dc = "Literature", weight = 0.2 },
    ["Base.BookCarpentry1"] = { dc = "SkillBook", weight = 0.8 },
    ["VFX.MagazineBaking1"] = { dc = "RecipeResource", weight = 0.1 },
    ["Base.Book_Prop"] = { dc = "Junk", weight = 0.5 },
    ["Base.Scotchtape"] = { dc = "Material", weight = 0.1 },
    ["Base.Whiskey"] = { dc = "Food", weight = 1, fluidAlcohol = 0.4 },     -- B42: 액체 용기
    ["VFX.WineMerlot"] = { dc = "Food", weight = 1, fluidAlcohol = 0.1 },
    ["Base.WaterBottle"] = { dc = "Food", weight = 1, fluidAlcohol = 0 },
    ["Base.BeerCan"] = { dc = "Food", weight = 0.3, alcohol = true },        -- 음식 isAlcoholic
    ["VFX.BeerBread"] = { dc = "Food", weight = 0.3 },
    ["Base.BeerEmpty"] = { dc = "WaterContainer", weight = 0.3 },
    ["Base.Cigar"] = { dc = "Junk", weight = 0.1 },
    ["Base.CigarBox"] = { dc = "Container", weight = 0.5 },
    ["Base.TobaccoSeed"] = { dc = "Gardening", weight = 0.1 },
}

-- 알코올 판정용 가짜 아이템: 액체 용기(fluidAlcohol) 또는 음식(alcohol)
function H.alcoholItem(ft, s, amount)
    local item = H.newItem(ft, { classes = s.fluidAlcohol and {} or { "Food" } })
    item.fluid = amount or 1
    function item:isAlcoholic() return s.alcohol == true end
    function item:isRotten() return false end
    if s.fluidAlcohol then
        function item:getFluidContainer()
            return { getAmount = function() return item.fluid end,
                     getProperties = function() return { getAlcohol = function() return s.fluidAlcohol * item.fluid end } end }
        end
    end
    return item
end

local function install()
    local function script(ft)
        local s = SCRIPTS[ft]
        if not s then return nil end
        return {
            getDisplayCategory = function() return s.dc end,
            getActualWeight = function() return s.weight end,
            getDoubleClickRecipe = function() return nil end,
            isRanged = function() return false end,
            getAmmoType = function() return nil end,
        }
    end
    getScriptManager = function()
        return { FindItem = function(_, ft) return script(ft) end, getItem = function(_, ft) return script(ft) end }
    end
    instanceItem = function(ft)
        local s = SCRIPTS[ft]
        if not s or s.dc ~= "Food" then return nil end
        return H.alcoholItem(ft, s)
    end
    StoryEngine.ItemPool.built = true     -- 전체 스캔은 건너뛴다
    StoryEngine.ItemPool.info["Base.Hammer"] = { cat = "melee", tier = 2, value = 4 }   -- 보상 근접 무기 풀에 있음
    StoryEngine.Value.cache = {}
end

function T.tools_by_weight_and_toolweapons_count_as_tools()
    install()
    local V = StoryEngine.Value
    H.eq(V.categoryOf("Base.Hammer"), "tools", "hammer trades as a tool even though it is in the melee pool")
    H.eq(V.of("Base.Hammer"), 8)
    H.eq(V.of("Base.Needle"), 2, "small")
    H.eq(V.of("Base.Pliers"), 8, "0.3kg is a normal tool")
    H.eq(V.of("Base.BlacksmithAnvil"), 20, "heavy")
    H.eq(V.of("Base.WeldingMask"), 20, "special")
    H.eq(V.of("Base.Axe"), 10, "special value kept")
    for _, ft in ipairs({ "Base.ClayCrudeBenchVisePartsMold", "Base.CrudeBenchViseParts", "Base.DebugFluid", "Base.Tobacco" }) do
        H.eq(V.categoryOf(ft), "misc", ft .. " is not a tool")
    end
    H.eq(V.resourceOf("Base.Hammer"), "safety")
    H.eq(V.resourceOf("Base.Tobacco"), nil, "fresh leaves are nothing")
    H.eq(V.resourceOf("Base.TobaccoDried"), "morale", "dried tobacco is a comfort")
end

function T.comforts_are_reading_alcohol_and_tobacco_only()
    install()
    local V = StoryEngine.Value
    local yes = { "Base.Book_Art", "Base.Magazine_Car", "Base.Whiskey", "VFX.WineMerlot", "Base.Cigar", "Base.Battery" }
    local no = { "Base.BookCarpentry1", "VFX.MagazineBaking1", "Base.Book_Prop", "Base.Scotchtape", "VFX.BeerBread",
                 "Base.BeerEmpty", "Base.CigarBox", "Base.TobaccoSeed" }
    table.insert(yes, "Base.BeerCan")
    table.insert(no, "Base.WaterBottle")
    for _, ft in ipairs(yes) do H.ok(V.moraleValue(ft), ft .. " should be a comfort") end
    for _, ft in ipairs(no) do H.eq(V.moraleValue(ft), nil, ft .. " should not be a comfort") end
    -- 다 마신 위스키병은 물자 지원·툴팁에서 빠진다
    local full = H.alcoholItem("Base.Whiskey", SCRIPTS["Base.Whiskey"], 1)
    local empty = H.alcoholItem("Base.Whiskey", SCRIPTS["Base.Whiskey"], 0)
    H.eq(V.donatable(nil, full), "morale")
    H.eq(V.donatable(nil, empty), nil, "empty bottle")
    H.eq(V.summary(empty), nil)
end

return T
