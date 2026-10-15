-- 의회 이후의 정치 (2026-10-13, docs/PLAN_COUNCIL_POLITICS.md 2·3단계, 확정안은 docs/IDEAS_COUNCIL_ERA.md 12장).
--
-- 의회가 선 뒤 OPEN_DAYS 일이 지나면 열린다 (샌드박스 Politics). 그 전에는 아무것도 바꾸지 않는다.
--
-- 파벌 셋: 밭 field (레이·파이크·닥) / 총 gun (휘태커·행크) / 장터 market (빅·듀이·케이시). 후임은 앞 사람 자리를 잇는다.
--   lean[파벌] = 플레이어 무리가 그 파벌에 기운 정도 (-100~100, 그 파벌 NPC 의 부탁을 해 주면 오르고 날마다 0 쪽으로).
--   한 파벌에 크게 기울면 (차이 LEAN_GAP 이상) 맞서는 파벌 NPC 의 특기 대기 x1.5, 거래 값 x1.1.
--
-- 법안: BILL_DAYS(10일)마다 파벌이 하나 낸다 -> PREP_DAYS(3일) 준비 -> 표결 -> 과반이면 LAW_DAYS(14일) 시행.
--   표: NPC 마다 찬성 기준(기본 50, 득 보는 사람 30, 손해 보는 사람 70, 낸 파벌 -10, 맞서는 파벌 +10)과 지금 신뢰도.
--   특별 법안(위령제·겨울 대비·보증)은 플레이어가 SPECIAL_DAYS(30일)에 한 번 낸다.
--
-- 보정은 모두 Politics.mod(key, fid, a) 한곳에서 읽는다 (Trade·Specialty·Life·Quests·Director·NpcEvents·Work·World 가 부른다).
--   정치가 열리지 않았거나 시행 중인 법안이 없으면 기본값(배율 1, 더하기 0, 거짓)이라 모든 값이 예전과 같다.
--
-- 법안 11개 (IDEAS_COUNCIL_ERA 12-1):
--   workshop 공동 작업장 / post 카운티 우편 / armory 무기고 개방 / exchange 특기 품앗이 (장터)
--   canteen 공동 식당 / truce 휴전 협정 (밭) / purge 정화 작업 / apprentice 도제 수업 (총)
--   memorial 위령제 / winter 겨울 대비 / vouch 보증 (특별)
-- 자원이 매일 줄어드는 법안(workshop·armory·canteen)은 시행 중 그 자원의 자연 회복을 멈춘다 (noRegen).
--
-- 상태: d.politics = { openT, seq, turn, lean, bill, laws, failed, history, nextBillT, specialT,
--                      workshop = { used[key], jobs }, meal[key] = day, calmUntil, winterUntil, moved[fid] }

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Radio"
require "StoryEngine/Stories"
require "StoryEngine/Quests"
require "StoryEngine/Life"
require "StoryEngine/Items"

local Net = StoryEngine.Net
local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Radio = StoryEngine.Radio
local Stories = StoryEngine.Stories
local Quests = StoryEngine.Quests
local Life = StoryEngine.Life
local Items = StoryEngine.Items
local log = StoryEngine.log

local Politics = {}
StoryEngine.Politics = Politics

Politics.OPEN_DAYS = 14
Politics.BLOCS = { "field", "gun", "market" }
Politics.HOME = { ray = "field", pike = "field", doc = "field", guard = "gun", hunter = "gun",
                  rats = "market", dewey = "market", casey = "market" }
Politics.BILL_DAYS = 10
Politics.PREP_DAYS = 3
Politics.LAW_DAYS = 14
Politics.RETRY_DAYS = 7                -- 부결된 법안을 다시 낼 수 있기까지
Politics.SPECIAL_DAYS = 30             -- 플레이어가 특별 법안을 낼 수 있는 간격 (서버 전체)
Politics.YES, Politics.GAIN, Politics.LOSE, Politics.PARTY = 50, 30, 70, 10
Politics.LEAN_GAP, Politics.LEAN_WAIT, Politics.LEAN_PRICE = 40, 1.5, 1.1
Politics.LEAN_PER_TIER = 2
Politics.CAPS = { specWait = { 0.5, 2 }, price = { 0.7, 1.5 }, specCost = { 0.5, 3 } }
Politics.HISTORY = 20
Politics.LOBBY_MAX = 3                 -- 법안 하나에 움직일 수 있는 사람 수 (무리가 나눠 쓴다)
Politics.PERSUADE_TRUST, Politics.PERSUADE_NUDGE, Politics.PERSUADE_DAYS = 60, 15, 7
Politics.PROMISE_TRUST, Politics.PROMISE_TIER = 40, 2
Politics.LOBBY_LEAN = 5
-- 압박: 그 NPC 의 약점을 쥐고 있을 때. 표를 얻지만 신뢰가 크게 깎이고 약점은 한 번 쓰면 닳는다
Politics.PRESS_COST = 10
-- 몰아세움: 법안이 그 NPC 가 헌장에 서명하며 지키겠다고 한 것과 맞닿을 때. 공개로 기준을 20 움직이고 기호품이 깎인다
Politics.CALL_NUDGE, Politics.CALL_MORALE = 20, 10
-- 약점을 얻는 길: 신뢰 TIP_TRUST 이상인 NPC 가 사이 나쁜 사람의 것을 귀띔 (날마다 TIP_CHANCE %), 조사에서 덮어 주거나 조용히 알린 범인
Politics.TIP_TRUST, Politics.TIP_CHANCE = 80, 10
-- 표 부탁: NPC 가 낸 법안에 맞서는 사람이 하루 뒤 "막아 달라"고 청한다. 반대 쪽으로 로비해 주면 그 사람 신뢰 +PLEA_GAIN
Politics.PLEA_CHANCE, Politics.PLEA_GAIN = 50, 2
-- 파벌 옮김: 자기 파벌 사람들과의 사이 평균이 음수이고 다른 파벌과 +1 이상이면 옮긴다 (MOVE_DAYS 에 한 번)
Politics.MOVE_DAYS = 60
-- 헌장에 서명하며 지키겠다고 한 것 (후임은 그 채널의 것을 잇는다)
Politics.PLEDGE = { ray = "share", pike = "open", doc = "care", guard = "order", hunter = "order",
                    rats = "trade", dewey = "trade", casey = "open" }
-- 법안이 받드는 것과 해치는 것
Politics.SERVES = { workshop = "share", post = "trade", armory = "trade", exchange = "trade", canteen = "share",
                    truce = "open", purge = "order", apprentice = "order", memorial = "care", winter = "share", vouch = "open" }
Politics.HARMS = { workshop = "trade", armory = "order", truce = "order", canteen = "trade", exchange = "care", purge = "care" }
-- 독주 국면에서 밀려난 채 신뢰가 이보다 낮은 NPC 는 다음 판정 때도 그대로면 카운티를 떠난다
Politics.SIDELINE_TRUST = 30
Politics.DEAL_HOURS = 12               -- 큰 사건: 파벌의 제안에 답할 시간
Politics.DEAL_WAIT_HOURS = 6           -- 받은 파벌의 특기 대기 (사건 동안)
Politics.DEAL_LEAN, Politics.DEAL_TIER = 10, 3
Politics.GOUGE = 1.25                  -- 사건 동안 장터 파벌의 값
Politics.CREDIT_NEED, Politics.CREDIT_MAX = 5, 2
Politics.SAGA_BAD = { none = true, lost = true, death = true, patched = true }
Politics.OFFER = {
    field = "your people will treat their wounded, steady their nerves and send supplies for as long as it lasts.",
    gun = "your people will send a squad and cover them with rifles for as long as it lasts.",
    market = "your people will scout for them, draw the dead away and fix their vehicle for as long as it lasts, and "
        .. "you will not raise your prices on them the way you will on everyone else.",
}
Politics.SIDE = { field = "the Fields", gun = "the Guns", market = "the Market" }
Politics.TERM_DAYS = 60                -- 의장 임기
Politics.ELECTION_FIRST_DAYS = 2       -- 정치가 열린 뒤 첫 선거까지
Politics.ELECTION_DAYS = 7
Politics.ELECT_SHARE = 40              -- 다수파가 자리를 나눠 주기로 한 후보 (Regime.shareOf)
Politics.ELECT_BLOC, Politics.ELECT_BOND, Politics.ELECT_BACK = 30, 10, 0.5    -- 신뢰 60 을 넘게 믿는 사람은 지지한 후보를 따른다
Politics.RUN_YES, Politics.RUN_ASK, Politics.RUN_TIER = 70, 50, 4
Politics.BACK_COST, Politics.BACK_LEAN = 5, 10
Politics.CHAIR_WARM, Politics.CHAIR_COLD = 60, 30
Politics.CHAIR_MORALE, Politics.CHAIR_WAIT, Politics.CHAIR_PRICE = 10, 0.75, 0.9
Politics.CHAIR_UPKEEP = 0.5            -- 플레이어 의장: 신뢰 유지 기준(일 없이 버티는 날)이 절반
Politics.CHAIR_BLAME, Politics.CHAIR_OUT_TRUST, Politics.CHAIR_OUT_COST = 2, 50, 5

Politics.POST_CUT = 0.3
Politics.MEAL_ITEM = "StoryEngine.Food_CouncilMeal"
Politics.MEAL_HOUR = 7
Politics.WORKSHOP_GAP_DAYS = 2
Politics.WORKSHOP_HOURS = 24
Politics.WORKSHOP_CATS = { tools = true, melee = true, firearm = true }
Politics.TOLL_DAYS = 7
Politics.TOLL_TIER = 2
Politics.TRUCE_BREAK = 3
Politics.VOUCH_GAIN, Politics.VOUCH_COST, Politics.VOUCH_BROKEN = 10, 5, 10
Politics.MEMORIAL_NEED = { { "Base.Candle", 4 }, { "Base.TinnedSoup", 4 } }
Politics.MEMORIAL_MORALE = 10
Politics.MEMORIAL_SHARE = 0.7
Politics.CALM_DAYS, Politics.CALM = 3, 0.3
Politics.WINTER_NEED = { { "Base.Firewood", 20 }, { "Base.TinnedSoup", 12 } }
Politics.WINTER_DAYS = 150             -- 채운 겨울 대비가 듣는 기간 (다가오는 겨울을 덮는다)
-- 도제 수업: 일거리를 마치면 그 NPC 분야의 기술 경험치 (등급 1~5, 그 NPC 의 기술들에 나눠 준다)
Politics.APPRENTICE_XP = { 100, 200, 400, 700, 1000 }
Politics.SKILLS = {
    ray = { "Farming", "Husbandry" }, dewey = { "Mechanics", "MetalWelding" }, doc = { "Doctor", "Tailoring" },
    hunter = { "Trapping", "Butchering" }, guard = { "Aiming", "Reloading" }, casey = { "Electricity", "Cooking" },
    pike = { "Fishing", "PlantScavenging" }, rats = { "Lightfoot", "Nimble", "Sneak" },
}

-- drain: 매일 깎는 자원 (res = "key" 는 그 NPC 의 핵심 자원). 시행 중 그 자원은 저절로 회복하지 않는다.
Politics.BILLS = {
    -- 의회가 스스로 올리는 표결 (Politics.systemBill): 법으로 남지 않는다
    admit = { system = true }, expel = { system = true },
    noconf = { system = true },         -- 의장 불신임 (Regime.lua)
    refuse = { system = true },         -- 군법회의를 의회 이름으로 거부 (Crises.lua E16)
    workshop = { bloc = "market", gain = { "dewey", "casey", "hunter" }, lose = { "rats" },
                 drain = { { fid = "dewey", res = "key", n = 4 } }, block = { dewey = "tools", casey = "tools" } },
    post = { bloc = "market", gain = { "casey", "dewey", "ray" }, lose = { "rats" }, post = true },
    armory = { bloc = "market", gain = { "rats", "hunter" }, lose = { "guard", "pike" },
               drain = { { fid = "guard", res = "safety", n = 4 } }, gunTier = 1, ammoPrice = 0.8, squad = -2 },
    exchange = { bloc = "market", gain = { "casey", "hunter", "rats" }, lose = { "ray", "doc" }, specWait = 0.5, specCost = 2 },
    canteen = { bloc = "field", gain = { "pike", "ray" }, lose = { "rats", "guard" },
                drain = { { all = true, res = "food", n = 2 } }, meal = true },
    truce = { bloc = "field", gain = { "doc", "pike" }, lose = { "guard", "rats" }, noClash = true },
    purge = { bloc = "gun", gain = { "guard", "hunter", "pike" }, lose = { "doc" },
              hordeShare = 2, hordeSize = 1.5, hordeBonus = 0.5 },
    apprentice = { bloc = "gun", gain = { "doc", "dewey", "hunter" }, lose = { "rats" }, apprentice = true },
    memorial = { special = true, bloc = "field", gain = { "pike", "ray", "casey" }, lose = {}, days = 1, recess = true },
    winter = { special = true, bloc = "field", gain = { "ray", "pike", "hunter" }, lose = {}, days = 10, season = "autumn" },
    vouch = { special = true, target = true, gain = {}, lose = {}, days = 14 },
}
Politics.ORDER = { "workshop", "post", "armory", "exchange", "canteen", "truce", "purge", "apprentice",
                   "memorial", "winter", "vouch" }

local MULT = { price = true, specWait = true, specCost = true, hordeSize = true, hordeShare = true, upkeep = true, donate = true }
local ADD = { gunTier = true, squad = true, hordeBonus = true, baseBonus = true }

local function state()
    local d = Store.data()
    d.politics = d.politics or {}
    local s = d.politics
    s.seq = s.seq or 0
    s.lean = s.lean or {}
    s.laws = s.laws or {}
    s.failed = s.failed or {}
    s.history = s.history or {}
    s.moved = s.moved or {}
    s.blocs = s.blocs or {}
    s.workshop = s.workshop or { used = {}, jobs = {} }
    s.meal = s.meal or {}
    return s
end

function Politics.state() return state() end

local function num(name, default)
    local Tuning = StoryEngine.Tuning
    local v = Tuning and Tuning.num(name) or 0
    if v <= 0 then return default end
    return v
end

function Politics.billDays() return num("BillDays", Politics.BILL_DAYS) end
function Politics.lawDays() return num("BillWeeks", Politics.LAW_DAYS / 7) * 7 end

local function has(list, v)
    for _, x in ipairs(list or {}) do
        if x == v then return true end
    end
    return false
end

local function living()
    local out = {}
    for _, f in ipairs(Factions.list) do
        if not Factions.isGone(f.id) then out[#out + 1] = f.id end
    end
    return out
end

local function nameOf(fid)
    return tostring(Stories.NAMES[fid] or fid)
end

local function trustOf(fid)
    return Radio.channel(fid).trust or 0
end

local function anyPlayer()
    local players = Sensor.players()
    if #players == 0 then return nil, nil end
    local p = players[ZombRand(#players) + 1]
    return p, Store.player(p)
end

local function playerByKey(key)
    for _, p in ipairs(Sensor.players()) do
        if Store.playerKey(p) == key then return p end
    end
    return nil
end

local function notify(kind, args)
    args = args or {}
    args.kind = kind
    pcall(Net.toAll, "politicsNotice", args)
end

-- ---------------------------------------------------------------- 열림

function Politics.enabled()
    return StoryEngine.option("Politics", true) == true
end

-- 정치가 열렸는가 (의회가 서고 OPEN_DAYS 가 지남)
function Politics.on()
    if not Politics.enabled() then return false end
    return Store.data().politics ~= nil and Store.data().politics.openT ~= nil
end

function Politics.openIn(now)
    local Era = StoryEngine.Era
    local era = Era and Era.info and Era.info() or nil
    if not era then return nil end
    return math.max(0, era.t + Politics.OPEN_DAYS * 24 * 60 - now.t)
end

local function open(now)
    local s = state()
    s.openT = now.t
    s.nextBillT = now.t + 24 * 60
    local text = "Two weeks after the county council formed, the people on the radio have settled into three camps: "
        .. "the farms and the church, the soldiers and the hunters, and the traders. From now on they will put "
        .. "proposals to the council and vote on them."
    if StoryEngine.Social and StoryEngine.Social.news then StoryEngine.Social.news("all", text) end
    for _, ps in pairs(Store.data().players) do
        if not ps.dead then Store.addNote(ps, { kind = "op", text = text, clock = now.clock }) end
    end
    notify("open")
    log("politics open")
end

-- ---------------------------------------------------------------- 파벌

function Politics.blocOf(fid)
    local s = Store.data().politics
    return (s and s.blocs and s.blocs[fid]) or Politics.HOME[fid]
end

function Politics.members(bloc)
    local out = {}
    for _, f in ipairs(Factions.list) do
        if Politics.blocOf(f.id) == bloc and not Factions.isGone(f.id) then out[#out + 1] = f.id end
    end
    return out
end

function Politics.lean(bloc)
    local s = Store.data().politics
    return (s and s.lean and s.lean[bloc]) or 0
end

local function addLean(bloc, d)
    local s = state()
    s.lean[bloc] = math.max(-100, math.min(100, (s.lean[bloc] or 0) + d))
end

-- 플레이어 무리가 이 NPC 의 파벌과 맞서는 쪽에 크게 기울었는가
function Politics.against(fid)
    if not Politics.on() then return false end
    local mine = Politics.blocOf(fid)
    if not mine then return false end
    local best = nil
    for _, b in ipairs(Politics.BLOCS) do
        if b ~= mine then
            local v = Politics.lean(b)
            if not best or v > best then best = v end
        end
    end
    return best ~= nil and best - Politics.lean(mine) >= Politics.LEAN_GAP
end

-- ---------------------------------------------------------------- 보정 한곳

function Politics.law(id)
    local s = Store.data().politics
    if not s or not s.openT then return nil end
    for _, law in ipairs(s.laws or {}) do
        if law.id == id then return law end
    end
    return nil
end

local function drains(def, fid, res)
    for _, dr in ipairs(def.drain or {}) do
        local r = dr.res == "key" and (Life.KEY[fid] or "morale") or dr.res
        if (dr.all or dr.fid == fid) and r == res then return true end
    end
    return false
end

-- key: price(fid, 품목) specWait(fid) specCost(fid) hordeSize hordeShare (배율)
--      gunTier(fid, 품목) squad(fid) hordeBonus (더하기)
--      tradeBlock(fid, 품목) noRegen(fid, 자원) noClash recess post apprentice (참·거짓)
function Politics.mod(key, fid, a)
    local v = MULT[key] and 1 or (ADD[key] and 0 or false)
    local s = Store.data().politics
    if not s or not s.openT or not Politics.enabled() then return v end
    for _, law in ipairs(s.laws or {}) do
        local def = Politics.BILLS[law.id]
        if def then
            if key == "price" then
                if def.ammoPrice and a == "ammo" then v = v * def.ammoPrice end
            elseif key == "gunTier" then
                if def.gunTier and (a == "firearm" or a == "ammo") then v = v + def.gunTier end
            elseif key == "squad" then
                if def.squad and fid == "guard" then v = v + def.squad end
            elseif key == "tradeBlock" then
                if def.block and def.block[fid] == a then v = true end
            elseif key == "noRegen" then
                if drains(def, fid, a) then v = true end
            elseif MULT[key] then
                if def[key] then v = v * def[key] end
            elseif ADD[key] then
                if def[key] then v = v + def[key] end
            elseif def[key] then
                v = true
            end
        end
    end
    -- 큰 사건 (6단계): 장터 사람들은 값을 올린다 (장터의 제안을 받았으면 올리지 않는다)
    local crisis = s.crisis
    if key == "price" and fid and crisis and not crisis.done and crisis.deal ~= "market"
        and Politics.blocOf(fid) == "market" then
        v = v * Politics.GOUGE
    end
    -- 의장의 색 (5단계)
    local chair = s.chair
    if chair and Sensor.now().t < (chair.untilT or 0) then
        if chair.player then
            if key == "upkeep" then v = v * Politics.CHAIR_UPKEEP end
        elseif chair.bloc == "field" then
            if key == "baseBonus" and a == "morale" then v = v + Politics.CHAIR_MORALE end
        elseif chair.bloc == "gun" then
            if key == "specWait" and (fid == "guard" or fid == "hunter") then v = v * Politics.CHAIR_WAIT end
            if key == "gunTier" and (a == "firearm" or a == "ammo") then v = v - 1 end
        elseif chair.bloc == "market" then
            if key == "price" then v = v * Politics.CHAIR_PRICE end
        end
    end
    -- 자리 셋 (Offices.lua): 창고지기·경비대장이 우리를 어떻게 보는가
    local Off = StoryEngine.Offices
    if Off and MULT[key] then
        local m = Off.mod(key, fid, a)
        if m then v = v * m end
    end
    -- 군정과 독주의 색 (Regime.lua)
    local Rg = StoryEngine.Regime
    if Rg and Rg.mod then
        local m = Rg.mod(key, fid, a)
        if m == true then
            v = true
        elseif m and MULT[key] then
            v = v * m
        elseif m and ADD[key] then
            v = v + m
        end
    end
    -- 국면 (9단계): 독주하는 파벌은 기세가 오르고 밀려난 파벌은 시든다. 견제 국면은 손이 많이 간다
    local phase = s.phase
    if phase then
        if phase.kind == "rule" and fid then
            local mine = Politics.blocOf(fid) == phase.bloc
            if key == "baseBonus" and a == "morale" then v = v + (mine and Politics.RULE_BASE or -Politics.RULE_BASE) end
            if key == "specWait" and not mine then v = v * Politics.RULE_WAIT end
        elseif phase.kind == "balance" and key == "upkeep" then
            v = v * Politics.BALANCE_UPKEEP
        end
    end
    -- 편들기의 대가
    if fid and (key == "specWait" or key == "price") and Politics.against(fid) then
        v = v * (key == "specWait" and Politics.LEAN_WAIT or Politics.LEAN_PRICE)
    end
    -- 밖에서 온 사람과의 충성 시험에서 치르는 값 (Outsiders.lua E10~E13)
    local Out = StoryEngine.Outsiders
    if Out and fid then
        local extra = Out.mod(key, fid, a)
        if extra == true then
            v = true
        elseif extra and MULT[key] then
            v = v * extra
        end
    end
    -- 정치 위기가 남긴 것 (Crises.lua: 격리 중인 닥, 강을 올라간 케이시, 영창의 휘태커)
    local Cr = StoryEngine.Crises
    if Cr and fid and Cr.mod(key, fid, a) == true then v = true end
    local cap = Politics.CAPS[key]
    if cap then v = math.max(cap[1], math.min(cap[2], v)) end
    return v
end

-- ---------------------------------------------------------------- 국면 (9단계)

-- PHASE_DAYS(60일)마다 정치가 어디로 흘렀는지 본다. 파벌마다 무게를 센다:
--   의장 자리 +2, 지난 국면 동안 통과시킨 법안 하나에 +1, 큰 사건의 공과(credit), 플레이어 무리의 기울기 20 이상 +1·40 이상 +2.
-- 가장 무거운 파벌이 둘째보다 PHASE_GAP(3) 이상 앞서면 그 파벌의 독주(rule), 아니면 견제(balance).
--   독주: 그 파벌 사람들의 기호품 기준 +10. 밀려난 파벌 사람들은 기호품 기준 -10, 특기 대기 1.25배.
--   견제: 모두 남지만 손이 많이 간다 (높은 신뢰를 지키는 기한이 0.8배).
Politics.PHASE_DAYS = 60
Politics.PHASE_GAP = 3
Politics.RULE_BASE = 10
Politics.RULE_WAIT = 1.25
Politics.BALANCE_UPKEEP = 0.8

function Politics.weights(now)
    local s = state()
    local out = {}
    local since = s.phase and s.phase.day or 0
    for _, b in ipairs(Politics.BLOCS) do
        local w = 0
        local chair = s.chair
        if chair and not chair.player and chair.bloc == b and now.t < (chair.untilT or 0) then w = w + 2 end
        for _, h in ipairs(s.history or {}) do
            if h.pass and h.bloc == b and (h.day or 0) >= since then w = w + 1 end
        end
        w = w + ((s.credit or {})[b] or 0)
        if StoryEngine.Regime and StoryEngine.Regime.weight then w = w + StoryEngine.Regime.weight(b) end
        local lean = s.lean[b] or 0
        if lean >= 40 then w = w + 2 elseif lean >= 20 then w = w + 1 end
        out[b] = w
    end
    return out
end

function Politics.phase()
    local s = Store.data().politics
    return s and s.phase or nil
end

-- 국면을 다시 정한다. 반환: phase
function Politics.judgePhase(now)
    local s = state()
    now = now or Sensor.now()
    local w = Politics.weights(now)
    local order = {}
    for _, b in ipairs(Politics.BLOCS) do order[#order + 1] = b end
    table.sort(order, function(a, b) return w[a] > w[b] end)
    local top, second = order[1], order[2]
    local before = s.phase
    local phase = { kind = "balance", sinceT = now.t, day = Store.serverDays(), weights = w }
    if #Politics.members(top) > 0 and w[top] - w[second] >= Politics.PHASE_GAP then
        phase.kind, phase.bloc = "rule", top
    end
    -- 분열·군정 (Regime.lua): 다수파가 거듭 무너졌으면 의회가 둘로 갈리고, 군정과 분열은 풀릴 때까지 이어진다
    local R = StoryEngine.Regime
    if R and R.overridePhase then
        local okR, over = pcall(R.overridePhase, phase, before, now)
        if not okR then
            log("politics regime phase error:", tostring(over))
        elseif over then
            phase = over
        end
    end
    -- 같은 파벌의 독주가 이어지면: 지난 판정 때도 지금도 밀려난 채 우리를 못 믿는 사람은 떠난다
    local Fate = StoryEngine.Fate
    if before and before.kind == "rule" and phase.kind == "rule" and before.bloc == phase.bloc and Fate and Fate.enabled() then
        for _, fid in ipairs(before.cold or {}) do
            if not Factions.isGone(fid) and Politics.blocOf(fid) ~= phase.bloc and trustOf(fid) < Politics.SIDELINE_TRUST then
                log("politics sidelined contact leaves", fid)
                pcall(Fate.apply, fid, "gone", "sidelined")
            end
        end
    end
    if phase.kind == "rule" then
        phase.cold = {}
        for _, fid in ipairs(living()) do
            if Politics.blocOf(fid) ~= phase.bloc and trustOf(fid) < Politics.SIDELINE_TRUST then phase.cold[#phase.cold + 1] = fid end
        end
    end
    s.phase = phase
    s.nextPhaseT = now.t + Politics.PHASE_DAYS * 24 * 60
    local changed = not before or before.kind ~= phase.kind or before.bloc ~= phase.bloc
    if changed then
        local text = (R and R.phaseText and R.phaseText(phase)) or (phase.kind == "rule"
            and ("County politics has tipped: " .. tostring(Politics.SIDE[phase.bloc] or phase.bloc) .. " now run the council, and the other camps are being pushed aside.")
            or "County politics is balanced for now: no camp runs the council alone, and everyone wants a little more from the players.")
        if StoryEngine.Social and StoryEngine.Social.news then StoryEngine.Social.news("all", text) end
        for _, ps in pairs(Store.data().players) do
            if not ps.dead then Store.addNote(ps, { kind = "op", text = text, clock = now.clock }) end
        end
        notify("phase", { phase = phase.kind, bloc = phase.bloc, by = phase.by })
        -- 기호품 기준이 바뀐다: 지금 값이 새 기준보다 높으면 그대로 두고 날마다 기준 쪽으로 간다
    end
    log("politics phase", phase.kind, tostring(phase.bloc), "weights", tostring(w.field), tostring(w.gun), tostring(w.market))
    return phase
end

-- ---------------------------------------------------------------- 법안: 표

local function gainOf(bill)
    if bill.id == "vouch" then return { bill.target } end
    return bill.gain or Politics.BILLS[bill.id].gain or {}
end

local function loseOf(bill)
    if bill.id == "vouch" then return bill.lose or {} end
    return bill.lose or Politics.BILLS[bill.id].lose or {}
end

-- 이 NPC 의 찬성 기준
function Politics.need(bill, fid)
    local need = Politics.YES
    if has(gainOf(bill), fid) then
        need = Politics.GAIN
    elseif has(loseOf(bill), fid) then
        need = Politics.LOSE
    end
    local bloc = Politics.blocOf(fid)
    if bill.bloc and bloc == bill.bloc then
        need = need - Politics.PARTY
    elseif bill.rival and bloc == bill.rival then
        need = need + Politics.PARTY
    end
    -- 큰 사건의 공과 (6단계): 낸 파벌의 공이 있으면 모두의 기준이 내려가고, 책임이 있으면 올라간다
    local s = Store.data().politics
    local credit = bill.bloc and s and s.credit and s.credit[bill.bloc] or 0
    need = need - credit * Politics.CREDIT_NEED
    -- 다수파 (Regime.lua): 다수파가 낸 법안은 다수파 사람들이 밀어 주고, 밖에서 낸 법안은 꺼린다
    local R = StoryEngine.Regime
    if R and R.need then need = need + R.need(bill, fid) end
    return need + ((bill.nudge or {})[fid] or 0)
end

-- 지금 표를 세면: { rows = { { fid, yes, need, trust } }, yes, no, pass }
function Politics.forecast(bill)
    local rows, yes, no = {}, 0, 0
    local Out = StoryEngine.Outsiders
    for _, fid in ipairs(living()) do
        local need, trust = Politics.need(bill, fid), trustOf(fid)
        local vote = (bill.pledged or {})[fid] == true or trust >= need
        if (bill.pledged or {})[fid] == false then vote = false end
        -- 등 돌림 (Outsiders.lua R5): 밖에서 온 사람을 꺼리는 NPC 의 신뢰가 바닥이면 표결에 나오지 않는다.
        -- 그 사람을 내보내자는 표결에는 나온다
        local absent = bill.id ~= "expel" and Out ~= nil and Out.absent(fid) or nil
        rows[#rows + 1] = { fid = fid, yes = vote, need = need, trust = trust, bloc = Politics.blocOf(fid), absent = absent }
        if not absent then
            if vote then yes = yes + 1 else no = no + 1 end
        end
    end
    -- 갈라선 의회 (Crises.lua E3): 셋 가운데 둘이 찬성해야 통과한다
    local Cr = StoryEngine.Crises
    local two3 = Cr ~= nil and Cr.mod("supermajority") == true
    local pass = yes > (yes + no) / 2
    if two3 then pass = yes > 0 and yes * 3 >= (yes + no) * 2 end
    return { rows = rows, yes = yes, no = no, pass = pass, two3 = two3 or nil }
end

local function rivalOf(bill)
    local count = {}
    for _, fid in ipairs(loseOf(bill)) do
        local b = Politics.blocOf(fid)
        if b and b ~= bill.bloc then count[b] = (count[b] or 0) + 1 end
    end
    local best, n = nil, 0
    for _, b in ipairs(Politics.BLOCS) do
        if (count[b] or 0) > n then best, n = b, count[b] end
    end
    return best
end

-- ---------------------------------------------------------------- 법안: 내기

local function available(id, now)
    local s = state()
    local def = Politics.BILLS[id]
    if not def or Politics.law(id) then return false end
    if s.failed[id] and now.t - s.failed[id] < Politics.RETRY_DAYS * 24 * 60 then return false end
    return true
end

local function billTopic(bill)
    return "council bill \"" .. tostring(bill.id) .. "\""
end

local function announce(bill, now)
    local speaker = (bill.by ~= "player" and bill.by ~= "chair") and bill.by or nil
    local text = (speaker and (nameOf(speaker) .. " put a proposal to the county council")
        or "The players put a proposal to the county council") .. ": " .. Politics.describe(bill)
        .. " The vote is in " .. StoryEngine.intToString(Politics.PREP_DAYS) .. " days."
    if speaker then
        Radio.react(speaker, "event", "You just put this proposal to the county council on behalf of your side: "
            .. Politics.describe(bill) .. " Tell the players why you want it and ask them to back it. The vote is in "
            .. StoryEngine.intToString(Politics.PREP_DAYS) .. " days.",
            { text = "We are putting a proposal to the council.",
              lt = { key = "IGUI_StoryEngine_Politics_Say_Propose",
                     args = { { t = "key", v = "IGUI_StoryEngine_Bill_" .. bill.id } } } }, nil)
    end
    if StoryEngine.Social and StoryEngine.Social.news then StoryEngine.Social.news("all", text) end
    notify("bill", { id = bill.id, by = bill.by, target = bill.target })
end

-- 법안 한 줄 설명 (AI 에게 넘기는 영어)
Politics.TEXT = {
    workshop = "a shared workshop at Dewey's garage that takes in worn-out tools and weapons and returns them good as new, paid for out of the garage's own stores",
    post = "a county post that brings bought goods and rewards straight to people's hands, the carriers keeping about a third",
    armory = "opening the Guard's armory so guns and ammunition are easier to buy, at the cost of the Guard's own stocks",
    exchange = "trading favours: the people on the radio help twice as often, but each time costs them twice as much",
    canteen = "a common kitchen that feeds every survivor a hot meal each morning out of everyone's food",
    truce = "a truce between the Guard and Vic's crew, with a weekly toll paid to Vic",
    purge = "a clearing campaign: more hordes to clear, bigger ones, and better pay for it",
    apprentice = "apprenticeships: whoever does a job for someone on the radio is taught that person's trade instead of being owed a favour",
    memorial = "a day of remembrance for the dead and the gone: no trade and no favours that day, candles and food gathered for it",
    winter = "laying in firewood and food for the winter together",
    vouch = "one of them vouching for another before the council",
}

function Politics.describe(bill)
    local text = bill.text or Politics.TEXT[bill.id] or bill.id
    if bill.id == "vouch" then
        text = nameOf(bill.guarantor) .. " vouching for " .. nameOf(bill.target) .. " before the council"
    end
    return text .. "."
end

local function newBill(id, bloc, by, now)
    local s = state()
    s.seq = s.seq + 1
    local bill = { seq = s.seq, id = id, bloc = bloc, by = by, t = now.t,
                   voteT = now.t + Politics.PREP_DAYS * 24 * 60, nudge = {}, pledged = {} }
    bill.rival = rivalOf(bill)
    return bill
end

-- 의회가 스스로 올리는 표결 (밖에서 온 사람을 받아들일지 admit, 내보낼지 expel: Outsiders.lua).
-- 법으로 남지 않고 결과만 Outsiders.onVote 로 넘긴다. 걸린 법안이 있으면 nil (나중에 다시)
function Politics.systemBill(id, opts, now)
    if not Politics.on() then return nil end
    local s = state()
    if s.bill then return nil end
    opts = opts or {}
    now = now or Sensor.now()
    local bill = newBill(id, nil, "council", now)
    bill.target, bill.text, bill.system, bill.owner = opts.target, opts.text, true, opts.owner
    bill.gain, bill.lose = opts.gain or {}, opts.lose or {}
    bill.rival = nil
    s.bill = bill
    if StoryEngine.Social and StoryEngine.Social.news then
        StoryEngine.Social.news("all", "The county council will vote in " .. StoryEngine.intToString(Politics.PREP_DAYS)
            .. " days on " .. Politics.describe(bill))
    end
    notify("bill", { id = id, by = "council", target = bill.target })
    log("politics system bill", id, tostring(bill.target))
    return bill
end

-- 파벌이 법안을 낸다. 반환: bill | nil
function Politics.propose(now)
    local s = state()
    if s.bill then return nil end
    s.turn = s.turn or ZombRand(#Politics.BLOCS)
    for step = 1, #Politics.BLOCS do
        local bloc = Politics.BLOCS[(s.turn + step - 1) % #Politics.BLOCS + 1]
        local members = Politics.members(bloc)
        local options = {}
        for _, id in ipairs(Politics.ORDER) do
            local def = Politics.BILLS[id]
            if def.bloc == bloc and not def.special and available(id, now) then options[#options + 1] = id end
        end
        if #members > 0 and #options > 0 then
            s.turn = (s.turn + step) % #Politics.BLOCS
            local id = options[ZombRand(#options) + 1]
            local bill = newBill(id, bloc, members[ZombRand(#members) + 1], now)
            s.bill = bill
            s.nextBillT = now.t + Politics.billDays() * 24 * 60
            announce(bill, now)
            log("politics bill", id, "by", bill.by, bloc, "rival", tostring(bill.rival))
            return bill
        end
    end
    s.nextBillT = now.t + 24 * 60
    return nil
end

-- 플레이어가 낼 수 있는 특별 법안: { { id, ok, why, wait } }
function Politics.specials(now)
    local s = state()
    local out = {}
    local wait = s.specialT and math.max(0, Politics.specialDays() * 24 * 60 - (now.t - s.specialT)) or 0
    for _, id in ipairs(Politics.ORDER) do
        local def = Politics.BILLS[id]
        if def.special then
            local why = nil
            if s.bill then
                why = "busy"
            elseif wait > 0 then
                why = "wait"
            elseif Politics.law(id) then
                why = "active"
            elseif not available(id, now) then
                why = "failed"
            elseif def.season and StoryEngine.Social and StoryEngine.Social.season() ~= def.season then
                why = "season"
            elseif id == "winter" and s.winterUntil and now.t < s.winterUntil then
                why = "done"
            end
            out[#out + 1] = { id = id, ok = why == nil, why = why, wait = math.ceil(wait / 60 / 24), target = def.target or nil }
        end
    end
    return out
end

-- 보증인: 가장 믿는 NPC (보증받을 사람 말고)
function Politics.guarantor(target)
    local best, top = nil, -1
    for _, fid in ipairs(living()) do
        if fid ~= target and trustOf(fid) > top then best, top = fid, trustOf(fid) end
    end
    return best
end

-- 특별 법안 발의. 반환: true, bill | false, 이유
function Politics.proposeSpecial(player, id, target)
    if not Politics.on() then return false, "closed" end
    if StoryEngine.Regime and StoryEngine.Regime.closed() then return false, "shut" end
    local now = Sensor.now()
    local def = Politics.BILLS[id]
    if not def or not def.special then return false, "no_bill" end
    for _, o in ipairs(Politics.specials(now)) do
        if o.id == id and not o.ok then return false, o.why end
    end
    local s = state()
    local bill = newBill(id, def.bloc, "player", now)
    if def.target then
        if not Factions.byId[target] or Factions.isGone(target) then return false, "no_target" end
        local g = Politics.guarantor(target)
        if not g then return false, "no_guarantor" end
        bill.target, bill.guarantor, bill.lose = target, g, {}
        local Bonds = StoryEngine.Bonds
        for _, fid in ipairs(living()) do
            if fid ~= g and fid ~= target and Bonds and Bonds.get(fid, g) < 0 then bill.lose[#bill.lose + 1] = fid end
        end
        bill.bloc = Politics.blocOf(g)
        bill.rival = rivalOf(bill)
    end
    bill.who = player and Store.player(player).name or nil
    s.bill = bill
    s.specialT = now.t
    announce(bill, now)
    log("politics special bill", id, tostring(target), "by", tostring(bill.who))
    return true, bill
end

-- ---------------------------------------------------------------- 로비 (4단계)

-- 준비 기간 동안 NPC 를 한 명씩 움직인다. 법안 하나에 LOBBY_MAX 번 (무리가 나눠 쓴다), 한 사람에게는 한 번.
--   설득 persuade: 신뢰도 PERSUADE_TRUST 이상. 그 사람의 찬성 기준을 15 움직인다. 같은 사람은 주에 한 번
--   약속 promise : 신뢰도 PROMISE_TRUST 이상. 그 사람이 표를 준다. 대신 빚 부탁 하나가 생긴다 (Work.owe)
-- 압박 press    : 그 사람의 약점을 쥐고 있을 때. 표를 준다. 신뢰 -PRESS_COST, 약점은 닳는다
-- 몰아세움 call  : 법안이 그 사람이 헌장에 서명하며 지키겠다고 한 것과 맞닿을 때 (Politics.callable). 기준을 20 움직인다
-- side: "for"(통과시키려고) | "against"(막으려고). 반환: true | false, 이유

-- 이 NPC 가 헌장에서 지키겠다고 한 것
function Politics.pledgeOf(fid)
    return Politics.PLEDGE[fid]
end

-- 몰아세울 수 있는가: 그 사람이 지키겠다던 것을 법안이 받드는데 반대하고 있거나(for), 해치는데 찬성하고 있을 때(against)
function Politics.callable(bill, fid, side)
    local pledge = Politics.pledgeOf(fid)
    if not pledge or bill.system then return false end
    local votesFor = (bill.pledged or {})[fid] == true or ((bill.pledged or {})[fid] == nil and trustOf(fid) >= Politics.need(bill, fid))
    if side == "against" then return Politics.HARMS[bill.id] == pledge and votesFor end
    return Politics.SERVES[bill.id] == pledge and not votesFor
end

function Politics.secretOf(fid)
    local s = Store.data().politics
    local sec = s and s.secrets and s.secrets[fid]
    if sec and not sec.used then return sec end
    return nil
end

-- 약점을 하나 알게 된다. how: tip(귀띔) | inquiry(조사). 반환: 새로 알았는가
function Politics.learnSecret(fid, how, by)
    if not Politics.on() or not Factions.byId[fid] or Factions.isOutsider(fid) then return false end
    local s = state()
    s.secrets = s.secrets or {}
    if s.secrets[fid] then return false end
    s.secrets[fid] = { how = how, by = by, day = Store.serverDays() }
    notify("secret", { fid = fid, how = how, by = by })
    log("politics secret learned", fid, tostring(how), tostring(by))
    return true
end

local LOBBY_TOPIC = {
    persuade = "They argued well and you are reconsidering. Say what would still hold you back, briefly.",
    promise = "You agreed, on the understanding that they now owe you a favour you will call in soon. Say so.",
    press = "They let you know they are holding something over you that you would not want said in council. You will vote "
        .. "their way this once, and you will not forget how they got it. Say so, cold; do not say what the secret is.",
    call = "They reminded you, on the open frequency, of what you signed your name to in the county charter. You are "
        .. "stung and you are reconsidering. Say so, briefly.",
}
local LOBBY_LINE = { persuade = "I'll think it over.", promise = "You'll have my vote. You owe me one.",
                     press = "You'll have my vote. I won't forget how.", call = "You've made your point. In front of everyone." }

function Politics.lobby(player, fid, how, side)
    if not Politics.on() then return false, "closed" end
    local s = state()
    local bill = s.bill
    if not bill then return false, "no_bill" end
    if not Factions.byId[fid] or Factions.isGone(fid) then return false, "no_target" end
    if Factions.isOutsider(fid) then return false, "no_target" end      -- 밖에서 온 사람은 표가 없다
    if bill.id == "expel" then return false, "no_lobby" end             -- 추방 표결은 뜻을 밝히는 것으로만 (Outsiders.stance)
    side = side == "against" and "against" or "for"
    bill.lobby = bill.lobby or {}
    local used = 0
    for _ in pairs(bill.lobby) do used = used + 1 end
    if used >= Politics.lobbyMax() then return false, "spent" end
    if bill.lobby[fid] then return false, "again" end
    local now = Sensor.now()
    local ps = Store.player(player)
    local Trust = StoryEngine.Trust
    local trust = Trust and Trust.of(fid, ps.key) or trustOf(fid)
    if how == "persuade" then
        if trust < Politics.PERSUADE_TRUST then return false, "trust", Politics.PERSUADE_TRUST end
        s.persuaded = s.persuaded or {}
        local last = s.persuaded[fid]
        if last and now.t - last < Politics.PERSUADE_DAYS * 24 * 60 then return false, "tired" end
        s.persuaded[fid] = now.t
        bill.nudge[fid] = (bill.nudge[fid] or 0) + (side == "for" and -Politics.PERSUADE_NUDGE or Politics.PERSUADE_NUDGE)
    elseif how == "promise" then
        if trust < Politics.PROMISE_TRUST then return false, "trust", Politics.PROMISE_TRUST end
        local Work = StoryEngine.Work
        if not Work or not Work.owe(fid, ps.key, ps.name, Politics.PROMISE_TIER, now.t) then return false, "owed" end
        bill.pledged[fid] = side == "for"
        s.promises = s.promises or {}
        Store.push(s.promises, { fid = fid, bill = bill.id, side = side, who = ps.name, day = Store.serverDays() }, 12)
    elseif how == "press" then
        local sec = Politics.secretOf(fid)
        if not sec then return false, "no_secret" end
        sec.used = true
        bill.pledged[fid] = side == "for"
        if Trust then Trust.apply(fid, -Politics.PRESS_COST, "pressed", nil, ps.key) end
    elseif how == "call" then
        if not Politics.callable(bill, fid, side) then return false, "no_pledge" end
        bill.nudge[fid] = (bill.nudge[fid] or 0) + (side == "for" and -Politics.CALL_NUDGE or Politics.CALL_NUDGE)
        pcall(Life.change, fid, "morale", -Politics.CALL_MORALE, "called_out")
    else
        return false, "how"
    end
    bill.lobby[fid] = { how = how, side = side, who = ps.name }
    if Trust then Trust.contact(fid, ps.key) end
    -- 편들기: 그 법안을 낸 파벌 쪽으로 (막으려 했으면 반대로)
    if bill.bloc then addLean(bill.bloc, side == "for" and Politics.LOBBY_LEAN or -Politics.LOBBY_LEAN) end
    Radio.react(fid, "event", tostring(ps.name) .. " came to you about the proposal before the council ("
        .. Politics.describe(bill) .. ") and asked you to vote " .. (side == "for" and "for" or "against") .. " it. "
        .. LOBBY_TOPIC[how],
        { text = LOBBY_LINE[how], lt = { key = "IGUI_StoryEngine_Politics_Say_" .. how } }, ps)
    log("politics lobby", how, side, fid, "by", ps.name, "bill", bill.id)
    return true
end

-- ---------------------------------------------------------------- 법안: 통과와 끝

local function collect(need, days, tag, fid, now)
    local _, ps = anyPlayer()
    if not ps then return nil end
    local ok, q = pcall(Quests.createCollect, ps, need, now, { politics = tag, source = "politics", faction = fid },
        now.t + math.floor(days * 24 * 60))
    if not ok then
        log("politics collect error:", tostring(q))
        return nil
    end
    return q and q.id or nil
end

local function share(qid)
    local q = qid and Store.data().quests[qid]
    if not q then return 0 end
    local need, got = 0, 0
    for _, n in ipairs(q.need or {}) do
        need = need + n[2]
        got = got + math.min(n[2], (q.got or {})[n[1]] or 0)
    end
    return need > 0 and got / need or 0
end

local function closeQuest(qid, now)
    local q = qid and Store.data().quests[qid]
    if q and Quests.isActive(q) then pcall(Quests.setState, q, "completed", now, nil) end
end

local PASS = {}
local END = {}

function PASS.truce(law, now)
    local Bonds = StoryEngine.Bonds
    if Bonds then
        for _, pair in ipairs({ { "guard", "rats" }, { "rats", "guard" } }) do
            local v = Bonds.get(pair[1], pair[2])
            if v ~= 0 then pcall(Bonds.change, pair[1], pair[2], -v, "the council made them agree to a truce", false) end
        end
    end
    law.tollT = now.t + Politics.TOLL_DAYS * 24 * 60
end

function PASS.memorial(law, now)
    law.collectId = collect(Politics.MEMORIAL_NEED, 1, "memorial", "pike", now)
end

function END.memorial(law, now)
    local got = share(law.collectId)
    closeQuest(law.collectId, now)
    local full = got >= Politics.MEMORIAL_SHARE
    for _, fid in ipairs(living()) do
        pcall(Life.change, fid, "morale", full and Politics.MEMORIAL_MORALE or math.floor(Politics.MEMORIAL_MORALE / 2), "memorial")
    end
    local Bonds = StoryEngine.Bonds
    if full and Bonds then
        local a, b, low = nil, nil, 0
        local ids = living()
        for _, x in ipairs(ids) do
            for _, y in ipairs(ids) do
                if x ~= y and Bonds.get(x, y) < low then a, b, low = x, y, Bonds.get(x, y) end
            end
        end
        if a then pcall(Bonds.change, a, b, 1, "they stood side by side at the county's day of remembrance", true) end
    end
    state().calmUntil = now.t + Politics.CALM_DAYS * 24 * 60
    Politics.calm()
    local text = "The county held its day of remembrance for the dead and the gone"
        .. (full and ", with candles and a shared meal." or ", though there was little to put on the table.")
    if StoryEngine.Social and StoryEngine.Social.news then StoryEngine.Social.news("all", text) end
    for _, ps in pairs(Store.data().players) do
        if not ps.dead then Store.addNote(ps, { kind = "op", text = text, clock = now.clock }) end
    end
end

function PASS.winter(law, now)
    law.collectId = collect(Politics.WINTER_NEED, Politics.BILLS.winter.days, "winter", "ray", now)
end

function END.winter(law, now)
    local got = share(law.collectId)
    closeQuest(law.collectId, now)
    if got >= 1 then
        state().winterUntil = now.t + Politics.WINTER_DAYS * 24 * 60
        if StoryEngine.Social and StoryEngine.Social.news then
            StoryEngine.Social.news("all", "The county laid in enough firewood and food together to see everyone through the winter.")
        end
    end
    notify("winter", { ready = got >= 1 })
    log("politics winter stores", got)
end

function PASS.vouch(law, now)
    local Trust = StoryEngine.Trust
    if not Trust then return end
    -- 정해 둔 값 그대로 (높은 신뢰의 더딤·배율을 다시 곱하지 않는다)
    local ch = Radio.channel(law.target)
    local before = ch.trust or 0
    ch.trust = math.min(100, before + Politics.VOUCH_GAIN)
    if ch.trust ~= before then
        Radio.push(law.target, { from = "system", trust = ch.trust - before, reason = "vouched", src = law.guarantor,
                                 clock = now.clock })
    end
    Trust.apply(law.guarantor, -Politics.VOUCH_COST, "vouch_cost")
end

-- 특별 법안이 아닌데도 따로 정리할 것이 있는 법안은 여기에
local function enact(bill, now)
    local s = state()
    local def = Politics.BILLS[bill.id]
    local days = def.days or Politics.lawDays()
    local law = { id = bill.id, seq = bill.seq, sinceT = now.t, untilT = now.t + math.floor(days * 24 * 60),
                  bloc = bill.bloc, by = bill.by, target = bill.target, guarantor = bill.guarantor }
    s.laws[#s.laws + 1] = law
    if PASS[bill.id] then
        local ok, err = pcall(PASS[bill.id], law, now)
        if not ok then log("politics pass error:", bill.id, tostring(err)) end
    end
    return law
end

function Politics.repeal(id, now, why)
    local s = state()
    for i, law in ipairs(s.laws) do
        if law.id == id then
            table.remove(s.laws, i)
            if why ~= "broken" and END[id] then
                local ok, err = pcall(END[id], law, now)
                if not ok then log("politics end error:", id, tostring(err)) end
            end
            notify("ended", { id = id, why = why })
            log("politics law ended", id, tostring(why))
            return law
        end
    end
    return nil
end

-- 표결. 반환: 결과 표
function Politics.vote(now)
    local s = state()
    local bill = s.bill
    if not bill then return nil end
    local tally = Politics.forecast(bill)
    local credit = bill.bloc and s.credit and s.credit[bill.bloc] or 0
    if credit ~= 0 then s.credit[bill.bloc] = credit + (credit > 0 and -1 or 1) end
    if tally.yes == tally.no and bill.cast and Politics.chair() and Politics.chair().player then
        tally.pass = bill.cast == "for"
        tally.cast = bill.cast
    end
    s.bill = nil
    -- 표 부탁: 막아 달라던 사람 편에서 한 번이라도 움직였으면 고마워한다
    if bill.plea and not Factions.isGone(bill.plea) and StoryEngine.Trust then
        for _, l in pairs(bill.lobby or {}) do
            if l.side == "against" then
                StoryEngine.Trust.apply(bill.plea, Politics.PLEA_GAIN, "plea_heard")
                break
            end
        end
    end
    local entry = { seq = bill.seq, id = bill.id, bloc = bill.bloc, by = bill.by, day = Store.serverDays(),
                    pass = tally.pass, yes = tally.yes, no = tally.no, target = bill.target }
    Store.push(s.history, entry, Politics.HISTORY)
    local yesNames, noNames, firstNo = {}, {}, nil
    for _, r in ipairs(tally.rows) do
        if r.yes then
            yesNames[#yesNames + 1] = nameOf(r.fid)
        else
            noNames[#noNames + 1] = nameOf(r.fid)
            firstNo = firstNo or r.fid
        end
    end
    if bill.system then
        local Owner = (bill.owner == "crises" and StoryEngine.Crises) or (bill.owner == "regime" and StoryEngine.Regime)
            or StoryEngine.Outsiders
        if Owner then
            local okO, errO = pcall(Owner.onVote, bill, tally.pass, now)
            if not okO then log("politics system vote error:", tostring(errO)) end
        end
    elseif tally.pass then
        enact(bill, now)
    else
        s.failed[bill.id] = now.t
        if bill.by == "chair" and StoryEngine.Trust then
            for _, fid in ipairs(living()) do StoryEngine.Trust.apply(fid, -Politics.CHAIR_BLAME, "chair_blame") end
        end
    end
    -- 크게 갈린 표결은 낸 사람과 맞선 사람의 사이를 깎는다 (30일에 한 번까지)
    local Bonds = StoryEngine.Bonds
    if Bonds and bill.by ~= "player" and bill.by ~= "chair" and firstNo and tally.yes >= 2 and tally.no >= 2
        and (not s.riftT or now.t - s.riftT >= 30 * 24 * 60) then
        s.riftT = now.t
        pcall(Bonds.change, bill.by, firstNo, -1, "they voted against each other at the council over " .. billTopic(bill), true)
    end
    local topic = "The county council just voted on this proposal: " .. Politics.describe(bill) .. " It "
        .. (tally.pass and "PASSED" or "was VOTED DOWN") .. ", " .. StoryEngine.intToString(tally.yes) .. " to "
        .. StoryEngine.intToString(tally.no) .. ". For: " .. (#yesNames > 0 and table.concat(yesNames, ", ") or "nobody")
        .. ". Against: " .. (#noNames > 0 and table.concat(noNames, ", ") or "nobody") .. "."
    local Social = StoryEngine.Social
    if Social then
        local ids = {}
        if bill.by ~= "player" and bill.by ~= "chair" and not Factions.isGone(bill.by) then ids[#ids + 1] = bill.by end
        if firstNo and not has(ids, firstNo) then ids[#ids + 1] = firstNo end
        for _, r in ipairs(tally.rows) do
            if #ids < 3 and not has(ids, r.fid) then ids[#ids + 1] = r.fid end
        end
        if Social.queueTopic then pcall(Social.queueTopic, ids, topic, "politics", nil) end
        if Social.news then Social.news("all", topic) end
    end
    for _, ps in pairs(Store.data().players) do
        if not ps.dead then Store.addNote(ps, { kind = "op", text = topic, clock = now.clock }) end
    end
    notify("vote", { id = bill.id, pass = tally.pass, yes = tally.yes, no = tally.no, target = bill.target })
    log("politics vote", bill.id, tally.pass and "pass" or "fail", tally.yes, tally.no)
    return tally
end

-- ---------------------------------------------------------------- 법안별 일

-- 공동 식당: 아침마다 접속한 사람에게 한 끼
function Politics.meals(now)
    if not Politics.law("canteen") or getGameTime():getHour() < Politics.MEAL_HOUR then return 0 end
    local s = state()
    local day = Store.dayIndex(now.dayKey)
    local n = 0
    for _, p in ipairs(Sensor.players()) do
        local key = Store.playerKey(p)
        if s.meal[key] ~= day and not p:isDead() then
            s.meal[key] = day
            local ok, item = pcall(Items.addTo, p:getInventory(), Politics.MEAL_ITEM)
            if ok and item then
                n = n + 1
                Net.toClient(p, "politicsNotice", { kind = "meal" })
            end
        end
    end
    return n
end

-- 위령제 뒤의 평안: 접속한 사람의 불행·스트레스를 조금 덜어 준다
function Politics.calm()
    local Specialty = StoryEngine.Specialty
    if not Specialty or not Specialty.soothe then return end
    for _, p in ipairs(Sensor.players()) do
        if not p:isDead() then pcall(Specialty.soothe, p, Politics.CALM) end
    end
end

-- 우편: 보상·산 물건을 바로 인벤토리로. 배달꾼이 가치의 POST_CUT 을 가져간다 (하나는 꼭 남긴다).
-- 반환: 남은 물건, 가져간 물건 수
function Politics.cut(items, part)
    local Value = StoryEngine.Value
    local vals, total = {}, 0
    for i, ft in ipairs(items) do
        vals[i] = Value and Value.of(ft) or 1
        total = total + vals[i]
    end
    local target = total * part
    local idx = {}
    for i = 1, #items do idx[i] = i end
    for i = #idx, 2, -1 do
        local j = ZombRand(i) + 1
        idx[i], idx[j] = idx[j], idx[i]
    end
    local drop, taken, left = {}, 0, #items
    for _, i in ipairs(idx) do
        if taken >= target or left <= 1 then break end
        if vals[i] <= (target - taken) * 2 then
            drop[i] = true
            taken = taken + vals[i]
            left = left - 1
        end
    end
    local kept = {}
    for i, ft in ipairs(items) do
        if not drop[i] then kept[#kept + 1] = ft end
    end
    return kept, #items - #kept
end

-- 반환: 처리했으면 true (부른 쪽은 보급 퀘스트를 만들지 않는다)
function Politics.post(player, ps, items, origin)
    if not Politics.mod("post") or not player or player:isDead() or not items or #items == 0 then return false end
    local kept, taken = Politics.cut(items, Politics.POST_CUT)
    local inv = player:getInventory()
    local given = 0
    for _, ft in ipairs(kept) do
        local ok, item = pcall(Items.addTo, inv, ft, "post")
        if ok and item then given = given + 1 end
    end
    if given == 0 then return false end
    Net.toClient(player, "politicsNotice", { kind = "post", got = given, taken = taken, faction = origin and origin.faction })
    if ps then
        Store.addNote(ps, { kind = "op", clock = Sensor.now().clock,
            text = "the county post brought what was owed straight to hand; the carriers kept their share" })
    end
    log("politics post", ps and ps.name or "?", "given", given, "taken", taken)
    return true
end

-- 공동 작업장: 낡은 도구·무기·총을 보내면 하루 뒤 새것으로. 반환: true, 대기 시간 | false, 이유, 남은 시간
function Politics.workshop(player, itemId)
    if not Politics.law("workshop") then return false, "no_law" end
    if Factions.isGone("dewey") then return false, "gone" end
    local s = state()
    local now = Sensor.now()
    local key = Store.playerKey(player)
    local last = s.workshop.used[key]
    local gap = Politics.WORKSHOP_GAP_DAYS * 24 * 60
    if last and now.t - last < gap then return false, "wait", math.ceil((gap - (now.t - last)) / 60) end
    local inv = player:getInventory()
    local ok, item = pcall(function() return inv:getItemWithIDRecursiv(tonumber(itemId) or -1) end)
    if not ok or not item then return false, "no_item" end
    local ft = item:getFullType()
    local Value = StoryEngine.Value
    local cat = Value and Value.categoryOf(ft) or nil
    if not Politics.WORKSHOP_CATS[cat or ""] then return false, "kind" end
    local tag = item:getModData().storyQuest
    if tag and Value and Value.isQuestActive and Value.isQuestActive(tag) then return false, "quest" end
    local okC, cond, max = pcall(function() return item:getCondition(), item:getConditionMax() end)
    if not okC or not max or max <= 0 or cond >= max then return false, "fine" end
    -- 총: 탄과 부품을 떼고 보내야 한다 (새 총으로 바꿔 주므로 함께 사라진다)
    local okL, loaded = pcall(function()
        return (item.getCurrentAmmoCount and item:getCurrentAmmoCount() > 0) or (item.isContainsClip and item:isContainsClip())
    end)
    if okL and loaded then return false, "loaded" end
    local okP, parts = pcall(function()
        local list = item.getAllWeaponParts and item:getAllWeaponParts() or nil
        return list ~= nil and list:size() > 0
    end)
    if okP and parts then return false, "parts" end
    Items.remove(item, player)
    s.workshop.used[key] = now.t
    s.workshop.jobs[#s.workshop.jobs + 1] = { key = key, item = ft, dueT = now.t + Politics.WORKSHOP_HOURS * 60 }
    log("politics workshop took", ft, "from", Store.player(player).name)
    return true, Politics.WORKSHOP_HOURS
end

local function workshopReturns(now)
    local s = state()
    local keep = {}
    for _, job in ipairs(s.workshop.jobs) do
        local p = now.t >= job.dueT and playerByKey(job.key) or nil
        local done = false
        if p and not p:isDead() then
            local ok, item = pcall(Items.addTo, p:getInventory(), job.item)
            if ok and item then
                done = true
                Net.toClient(p, "politicsNotice", { kind = "workshop", item = job.item })
            end
        end
        if not done then keep[#keep + 1] = job end
    end
    s.workshop.jobs = keep
end

-- 휴전 협정: 빅이 주마다 통행세를 청한다. 거절·무시·실패하면 협정이 깨진다
local function truceToll(now)
    local law = Politics.law("truce")
    if not law or Factions.isGone("rats") or now.t < (law.tollT or 0) then return end
    local open = law.tollId and Store.data().quests[law.tollId]
    if open and (Quests.isActive(open) or open.state == "proposed") then return end
    local p, ps = anyPlayer()
    if not p then return end
    law.tollT = now.t + Politics.TOLL_DAYS * 24 * 60
    local ok, q = pcall(Quests.propose, p, ps, "rats", Politics.TOLL_TIER, now, {})
    if ok and q then
        q.origin.politics = "truce"
        law.tollId = q.id
        log("politics truce toll", q.id)
    end
end

local function breakTruce(now)
    if not Politics.repeal("truce", now, "broken") then return end
    local Trust = StoryEngine.Trust
    for _, fid in ipairs({ "guard", "rats" }) do
        if Trust and not Factions.isGone(fid) then Trust.apply(fid, -Politics.TRUCE_BREAK, "truce_broken") end
    end
    if StoryEngine.Social and StoryEngine.Social.news then
        StoryEngine.Social.news("all", "The truce between the Guard and Vic's crew fell apart when the toll went unpaid.")
    end
end

-- 도제 수업: 일거리를 마친 사람에게 그 NPC 분야의 경험치. 반환: 준 경험치 (법안이 없으면 nil)
function Politics.apprentice(fid, player, tier)
    if not Politics.mod("apprentice") then return nil end
    local skills = Politics.SKILLS[fid]
    if not skills or not player then return 0 end
    local total = Politics.APPRENTICE_XP[math.max(1, math.min(#Politics.APPRENTICE_XP, tier or 1))]
    local each = math.floor(total / #skills)
    local given = 0
    for _, name in ipairs(skills) do
        local perk = Perks and Perks[name]
        if perk then
            local ok = pcall(addXp, player, perk, each)
            if not ok then ok = pcall(function() player:getXp():AddXP(perk, each) end) end
            if ok then given = given + each end
        end
    end
    Net.toClient(player, "politicsNotice", { kind = "apprentice", faction = fid, xp = given })
    log("politics apprentice", fid, "tier", tier, "xp", given)
    return given
end

-- 겨울 대비를 채워 두었는가 (World.lua 가 묻는다)
function Politics.winterReady()
    local s = Store.data().politics
    return s ~= nil and s.winterUntil ~= nil and Sensor.now().t < s.winterUntil
end

-- ---------------------------------------------------------------- 큰 사건에 끼어드는 정치 (6단계)

-- 의회 이후의 큰 사건(Saga)은 모두가 뭉쳐 막지 않는다. 시작되면 파벌마다 그 파벌의 대표(우리를 가장 믿는 사람)가
-- 조건을 단 제안을 한다. DEAL_HOURS 안에 하나를 받거나, 아무것도 받지 않고 혼자 간다.
--   받으면: 그 파벌 사람들의 1차 특기가 사건 동안 DEAL_WAIT_HOURS 마다, 자원을 쓰지 않고 온다. 기울기 +DEAL_LEAN.
--           대신 대표에게 빚을 진다 (Work.owe, 이틀쯤 뒤 큰 부탁).
--   장터는 사건 동안 값을 올린다 (GOUGE). 장터의 제안을 받았으면 올리지 않는다.
-- 끝나면 공과 정산: 받은 파벌은 사건이 잘 끝나면 공(+1), 나쁘게 끝나면 책임(-1). 공은 그 파벌이 내는 다음 법안의
-- 찬성 기준을 CREDIT_NEED 만큼 내리고(책임이면 올리고) 한 번 쓰이면 닳는다.

local function crisisNow()
    local s = Store.data().politics
    local c = s and s.openT and s.crisis or nil
    if not c or c.done then return nil end
    return c
end

function Politics.crisis() return crisisNow() end

-- 이 NPC 의 파벌과 거래를 맺었는가 (Specialty: 사건 동안 대기가 짧고 자원을 쓰지 않는다)
function Politics.dealt(fid)
    local R = StoryEngine.Regime
    if R and R.backed and R.backed(fid) then return true end       -- 군정의 명령을 따른 뒤 (Regime.lua)
    local c = crisisNow()
    return c ~= nil and c.deal ~= nil and c.deal == Politics.blocOf(fid)
end

-- 큰 사건 동안 이 NPC 가 저절로 도우러 오는가: 의회 이후에는 제안을 받은 파벌의 사람만
function Politics.willHelp(fid)
    local c = crisisNow()
    if not c then return true end
    return c.deal ~= nil and c.deal == Politics.blocOf(fid)
end

-- 선별 방어: 제안을 받은 파벌은 사건 동안 자기 사람들의 거점을 지킨다 (그 사람들의 사건 피해가 절반)
function Politics.shielded(fid)
    local c = crisisNow()
    return c ~= nil and c.deal ~= nil and c.deal == Politics.blocOf(fid)
end

local function leaderOf(bloc)
    local best, top = nil, -1
    for _, fid in ipairs(Politics.members(bloc)) do
        if trustOf(fid) > top then best, top = fid, trustOf(fid) end
    end
    return best
end

function Politics.onSaga(event, sg)
    if not Politics.on() or not sg then return end
    local s = state()
    local now = Sensor.now()
    if event == "start" then
        local c = { id = sg.id, kind = sg.kind, t = now.t, untilT = now.t + Politics.DEAL_HOURS * 60, offers = {} }
        for _, b in ipairs(Politics.BLOCS) do c.offers[b] = leaderOf(b) end
        s.crisis = c
        for _, b in ipairs(Politics.BLOCS) do
            local fid = c.offers[b]
            if fid then
                Radio.react(fid, "event", "Trouble has started in the county (" .. tostring(sg.kind) .. "). Nobody is pulling together "
                    .. "the way they did at the church. Make the players an offer on behalf of your side: " .. Politics.OFFER[b]
                    .. " In return they will owe you a favour you will call in afterwards. They can take one side's offer only, "
                    .. "in the Council tab, within " .. StoryEngine.intToString(Politics.DEAL_HOURS) .. " hours.",
                    { text = "We can help. It will cost you a favour.", lt = { key = "IGUI_StoryEngine_Politics_Say_Offer_" .. b } }, nil)
            end
        end
        notify("crisis", { saga = sg.kind })
        log("politics crisis offers", sg.id, sg.kind)
    elseif event == "done" then
        local c = s.crisis
        if not c or c.id ~= sg.id then return end
        c.done = true
        local good = not Politics.SAGA_BAD[tostring(sg.result)]
        if c.deal and c.deal ~= "none" then
            s.credit = s.credit or {}
            local v = (s.credit[c.deal] or 0) + (good and 1 or -1)
            s.credit[c.deal] = math.max(-Politics.CREDIT_MAX, math.min(Politics.CREDIT_MAX, v))
            local text = good and ("When the trouble was over, people gave the credit to " .. Politics.SIDE[c.deal] .. ", who had stepped in.")
                or ("When the trouble ended badly, people blamed " .. Politics.SIDE[c.deal] .. ", who had promised to handle it.")
            if StoryEngine.Social and StoryEngine.Social.news then StoryEngine.Social.news("all", text) end
            notify("settled", { bloc = c.deal, good = good })
        end
        log("politics crisis settled", sg.id, tostring(c.deal), good and "good" or "bad")
        s.crisis = nil
        -- 누가 공을 가져가는지를 두고 다툰다: 플레이어는 한쪽의 말에 힘을 실어 줄 수 있다 (Regime.testify)
        if StoryEngine.Regime and StoryEngine.Regime.onSagaDone then
            pcall(StoryEngine.Regime.onSagaDone, sg, c.deal, good)
        end
    end
end

-- 제안을 받는다 (bloc = "none" 이면 혼자 간다). 반환: true | false, 이유
function Politics.deal(player, bloc)
    local c = crisisNow()
    if not c then return false, "no_crisis" end
    if c.deal then return false, "done" end
    local now = Sensor.now()
    if now.t >= c.untilT then return false, "late" end
    local ps = Store.player(player)
    if bloc ~= "none" then
        local fid = c.offers[bloc]
        if not fid or Factions.isGone(fid) then return false, "no_target" end
        local Work = StoryEngine.Work
        if not Work or not Work.owe(fid, ps.key, ps.name, Politics.DEAL_TIER, now.t) then return false, "owed" end
        addLean(bloc, Politics.DEAL_LEAN)
        Radio.react(fid, "event", tostring(ps.name) .. " took your side's offer of help in the trouble, and owes you for it. "
            .. "Tell them your people are on it, and that you will be calling the favour in.",
            { text = "Then it's settled. My people are on it.", lt = { key = "IGUI_StoryEngine_Politics_Say_Deal" } }, ps)
    end
    c.deal, c.by = bloc, ps.name
    notify("deal", { bloc = bloc, name = ps.name })
    log("politics crisis deal", bloc, "by", ps.name)
    return true
end

-- ---------------------------------------------------------------- 의장 선거 (5단계, 위기 E1)

-- 정치가 열리고 ELECTION_FIRST_DAYS 뒤 첫 선거, 그 뒤 임기(TERM_DAYS)마다. 기간은 ELECTION_DAYS.
-- 후보는 파벌마다 한 명 (그 파벌에서 플레이어 무리를 가장 믿는 사람). NPC 는 자기 파벌 후보, 후보와의 사이,
-- 플레이어가 지지한 후보(자기 신뢰도만큼)를 따져 한 표를 던진다.
-- 플레이어는 한 후보를 공개 지지하거나(번복 불가) 직접 출마한다. 출마는 살아 있는 NPC 전원의 표가 있어야 한다:
--   신뢰도 RUN_YES(70) 이상이면 표를 주고, RUN_ASK(50) 이상이면 큰 부탁 하나를 조건으로 건다. 50 미만이 있으면 출마 불가.
-- 의장의 색 (NPC 의장): 밭 = 모든 NPC 기호품 기준 +10 / 총 = 방위대·행크 특기 대기 x0.75, 총기·탄약 한도 한 등급 조임
--   / 장터 = 거래 값 x0.9. 의장이 우리를 믿으면(60 이상) 특별 법안을 15일마다, 미워하면(30 미만) 로비가 한 명 준다.
-- 플레이어 의장: 다음 법안을 고르고(Politics.choose), 동수일 때 정하고(Politics.cast), 로비가 한 명 는다.
--   대가: 신뢰 유지 기준이 절반으로 빡빡해지고, 고른 법안이 부결되면 모두 -2, 평균 신뢰가 50 밑이면 불신임(모두 -5).

function Politics.chair()
    local s = Store.data().politics
    local c = s and s.openT and s.chair or nil
    if c and Sensor.now().t >= (c.untilT or 0) then return nil end
    return c
end

local function chairKey()
    local c = Politics.chair()
    return c and c.player or nil
end

function Politics.lobbyMax()
    local c = Politics.chair()
    local n = Politics.LOBBY_MAX
    if c and c.player then
        n = n + 1
    elseif c and c.fid and not Factions.isGone(c.fid) and trustOf(c.fid) < Politics.CHAIR_COLD then
        n = n - 1
    end
    return n
end

function Politics.specialDays()
    local c = Politics.chair()
    if c and c.fid and not Factions.isGone(c.fid) and trustOf(c.fid) >= Politics.CHAIR_WARM then
        return math.floor(Politics.SPECIAL_DAYS / 2)
    end
    return Politics.SPECIAL_DAYS
end

-- 파벌마다 후보: 그 파벌에서 신뢰도가 가장 높은 사람
local function candidates()
    local out = {}
    for _, b in ipairs(Politics.BLOCS) do
        local best, top = nil, -1
        for _, fid in ipairs(Politics.members(b)) do
            if trustOf(fid) > top then best, top = fid, trustOf(fid) end
        end
        out[b] = best
    end
    return out
end

local function runTrust(fid, key)
    local Trust = StoryEngine.Trust
    return Trust and key and Trust.of(fid, key) or trustOf(fid)
end

-- 출마한 플레이어에게 이 NPC 가 표를 주는가
local function granted(e, fid)
    return e.player ~= nil and ((e.player.votes or {})[fid] == true or runTrust(fid, e.player.key) >= Politics.RUN_YES)
end

-- 지금 표를 세면: { rows = { { fid, pick(파벌) } }, votes = { 파벌 = 수 }, winner = 파벌, player = { got, need } }
function Politics.electionForecast(e)
    local Bonds = StoryEngine.Bonds
    local rows, votes = {}, {}
    for _, fid in ipairs(living()) do
        local pick, top = nil, nil
        for _, b in ipairs(Politics.BLOCS) do
            local c = e.cands[b]
            if c and not Factions.isGone(c) then
                local score = (Politics.blocOf(fid) == b and Politics.ELECT_BLOC or 0)
                    + (Bonds and c ~= fid and Bonds.get(fid, c) * Politics.ELECT_BOND or 0)
                    + (c == fid and 100 or 0)
                    + (e.backed == b and trustOf(fid) * Politics.ELECT_BACK or 0)
                    + ((e.share and e.share.bloc == b and has(e.share.blocs, Politics.blocOf(fid))) and Politics.ELECT_SHARE or 0)
                if not top or score > top then pick, top = b, score end
            end
        end
        rows[#rows + 1] = { fid = fid, pick = pick, bloc = Politics.blocOf(fid), mine = e.player and granted(e, fid) or nil }
        if pick then votes[pick] = (votes[pick] or 0) + 1 end
    end
    local winner, most = nil, -1
    for _, b in ipairs(Politics.BLOCS) do
        local n = votes[b] or 0
        local c = e.cands[b]
        if c and (n > most or (n == most and winner and trustOf(c) > trustOf(e.cands[winner]))) then winner, most = b, n end
    end
    local out = { rows = rows, votes = votes, winner = winner }
    if e.player then
        local got = 0
        for _, r in ipairs(rows) do if r.mine then got = got + 1 end end
        out.player = { got = got, need = #rows }
    end
    return out
end

function Politics.electionOpen(now)
    local s = state()
    if s.election then return s.election end
    local e = { t = now.t, voteT = now.t + Politics.ELECTION_DAYS * 24 * 60, cands = candidates() }
    local any = false
    for _, b in ipairs(Politics.BLOCS) do if e.cands[b] then any = true end end
    if not any then return nil end
    s.election = e
    local names = {}
    for _, b in ipairs(Politics.BLOCS) do
        if e.cands[b] then names[#names + 1] = nameOf(e.cands[b]) end
    end
    local text = "The county council is choosing a chair for the next two months. Standing: " .. table.concat(names, ", ")
        .. ". The vote is in " .. StoryEngine.intToString(Politics.ELECTION_DAYS) .. " days."
    if StoryEngine.Social and StoryEngine.Social.news then StoryEngine.Social.news("all", text) end
    for _, b in ipairs(Politics.BLOCS) do
        local c = e.cands[b]
        if c then
            Radio.react(c, "event", "You are standing for chair of the county council; the vote is in "
                .. StoryEngine.intToString(Politics.ELECTION_DAYS) .. " days. Tell the players what you would do with the "
                .. "chair and ask for their public backing.",
                { text = "I'm standing for chair. I could use your backing.", lt = { key = "IGUI_StoryEngine_Politics_Say_Stand" } }, nil)
            break
        end
    end
    notify("election", { cands = e.cands })
    log("politics election open")
    return e
end

-- 공개 지지 (번복 불가, 출마했으면 못 한다)
function Politics.back(player, bloc)
    local s = state()
    local e = s.election
    if not Politics.on() or not e then return false, "no_election" end
    if e.backed then return false, "backed" end
    if e.player then return false, "running" end
    if not e.cands[bloc] then return false, "no_target" end
    e.backed, e.backedBy = bloc, Store.player(player).name
    addLean(bloc, Politics.BACK_LEAN)
    Radio.react(e.cands[bloc], "event", tostring(e.backedBy) .. " just backed you for chair of the county council, in the open, "
        .. "on the radio. Thank them in your own way.",
        { text = "I won't forget that.", lt = { key = "IGUI_StoryEngine_Politics_Say_Backed" } }, Store.player(player))
    log("politics backed", bloc, "by", e.backedBy)
    return true
end

-- 출마. 반환: true | false, 이유, 막는 NPC
function Politics.run(player)
    local s = state()
    local e = s.election
    if not Politics.on() or not e then return false, "no_election" end
    if e.backed then return false, "backed" end
    if e.player then return false, "running" end
    local ps = Store.player(player)
    for _, fid in ipairs(living()) do
        if runTrust(fid, ps.key) < Politics.RUN_ASK then return false, "trust", fid end
    end
    local now = Sensor.now()
    e.player = { key = ps.key, name = ps.name, votes = {}, asks = {} }
    for _, fid in ipairs(living()) do
        if runTrust(fid, ps.key) < Politics.RUN_YES then
            -- 조건: 큰 부탁 하나. 못 만들면 표결 때까지 신뢰도를 RUN_YES 로 올려야 한다
            local ok, q = pcall(Quests.propose, player, ps, fid, Politics.RUN_TIER, now, {})
            if ok and q then
                q.origin.politics = "campaign"
                e.player.asks[fid] = q.id
            end
        end
    end
    if StoryEngine.Social and StoryEngine.Social.news then
        StoryEngine.Social.news("all", tostring(ps.name) .. " is standing for chair of the county council, which takes every vote on the radio.")
    end
    notify("run", { name = ps.name })
    log("politics player runs", ps.name)
    return true
end

local function setChair(c, now)
    local s = state()
    c.sinceT, c.untilT = now.t, now.t + Politics.TERM_DAYS * 24 * 60
    s.chair = c
    s.nextElectionT = c.untilT - Politics.ELECTION_DAYS * 24 * 60
end

function Politics.electionVote(now)
    local s = state()
    local e = s.election
    if not e then return nil end
    local f = Politics.electionForecast(e)
    s.election = nil
    local Trust = StoryEngine.Trust
    local result = { winner = f.winner, fid = f.winner and e.cands[f.winner] or nil }
    if e.player and f.player and f.player.got >= f.player.need and f.player.need > 0 then
        setChair({ player = e.player.key, name = e.player.name }, now)
        result = { player = e.player.name }
    else
        if e.player then result.ranFailed = e.player.name end
        if result.fid then setChair({ fid = result.fid, bloc = result.winner }, now) end
        -- 공개 지지의 값: 이긴 쪽을 밀었으면 진 후보들이, 진 쪽을 밀었으면 의장이 꺼린다
        if e.backed and Trust then
            for _, b in ipairs(Politics.BLOCS) do
                local c = e.cands[b]
                if c and not Factions.isGone(c) then
                    if e.backed == result.winner and b ~= result.winner then
                        Trust.apply(c, -Politics.BACK_COST, "election_lost")
                    elseif e.backed ~= result.winner and b == result.winner then
                        Trust.apply(c, -Politics.BACK_COST, "election_against")
                    end
                end
            end
        end
    end
    local text = result.player and (tostring(result.player) .. " was chosen chair of the county council by every voice on the radio.")
        or (result.fid and (nameOf(result.fid) .. " was chosen chair of the county council for the next two months.")
            or "The county council could not agree on a chair.")
    if StoryEngine.Social and StoryEngine.Social.news then StoryEngine.Social.news("all", text) end
    for _, ps in pairs(Store.data().players) do
        if not ps.dead then Store.addNote(ps, { kind = "op", text = text, clock = now.clock }) end
    end
    if result.fid and not result.player then
        Radio.react(result.fid, "event", "You were just chosen chair of the county council for the next two months. "
            .. "Say what changes now, briefly.",
            { text = "The chair is mine. Things change now.", lt = { key = "IGUI_StoryEngine_Politics_Say_Won" } }, nil)
    end
    notify("elected", { fid = result.fid, bloc = result.winner, player = result.player, ranFailed = result.ranFailed })
    log("politics elected", tostring(result.player or result.fid))
    return result
end

-- 의장인 플레이어가 다음 법안을 고른다
function Politics.choose(player, id)
    local s = state()
    local now = Sensor.now()
    local ps = Store.player(player)
    if chairKey() ~= ps.key then return false, "not_chair" end
    if s.bill then return false, "busy" end
    local def = Politics.BILLS[id]
    if not def or def.special then return false, "no_bill" end
    if not available(id, now) then return false, "failed" end
    local bill = newBill(id, def.bloc, "chair", now)
    bill.who = ps.name
    s.bill = bill
    s.nextBillT = now.t + Politics.billDays() * 24 * 60
    announce(bill, now)
    log("politics chair picks", id, ps.name)
    return true
end

-- 의장의 한 표: 동수일 때만 쓰인다
function Politics.cast(player, side)
    local s = state()
    if chairKey() ~= Store.player(player).key then return false, "not_chair" end
    if not s.bill then return false, "no_bill" end
    s.bill.cast = side == "against" and "against" or "for"
    return true
end

-- 플레이어 의장의 불신임 (날마다)
local function chairDaily(now)
    local c = Politics.chair()
    if not c or not c.player then return end
    local sum, n = 0, 0
    for _, fid in ipairs(living()) do
        sum, n = sum + runTrust(fid, c.player), n + 1
    end
    if n > 0 and sum / n < Politics.CHAIR_OUT_TRUST then
        local s = state()
        s.chair = nil
        s.nextElectionT = now.t + 24 * 60
        s.impeachT = now.t
        local Trust = StoryEngine.Trust
        for _, fid in ipairs(living()) do
            if Trust then Trust.apply(fid, -Politics.CHAIR_OUT_COST, "chair_out") end
        end
        if StoryEngine.Social and StoryEngine.Social.news then
            StoryEngine.Social.news("all", "The county council voted its chair, " .. tostring(c.name) .. ", out: too few of them still trusted the chair.")
        end
        notify("impeached", { name = c.name })
        log("politics chair voted out", tostring(c.name))
    end
end

-- ---------------------------------------------------------------- 퀘스트 결과

local NPC_ASKS = { deliver = true, horde = true, fetch = true, named = true }

local function onQuest(q, st, outcome)
    local s = Store.data().politics
    if not s or not s.openT then return end
    local fid = q.origin and q.origin.faction
    local now = Sensor.now()
    local ended = st == "completed" or st == "failed" or st == "declined"
    if not ended then return end
    -- 기울기: 그 파벌 사람의 부탁을 해 줬다
    if st == "completed" and fid and NPC_ASKS[q.kind] and not Quests.isManaged(q) and q.origin.initiator == "npc" then
        local bloc = Politics.blocOf(fid)
        if bloc then addLean(bloc, Politics.LEAN_PER_TIER * math.max(1, q.tier or 1)) end
    end
    -- 출마의 조건으로 건 부탁
    local e = s.election
    if e and e.player and q.origin and q.origin.politics == "campaign" and fid then
        e.player.spurned = e.player.spurned or {}
        e.player.votes[fid] = st == "completed" and not e.player.spurned[fid]
        -- 사이 나쁜 사람의 부탁을 들어줬다: 그 사람을 싫어하는 쪽은 부탁으로 얻은 표를 거두고, 신뢰 RUN_YES 로만 표를 준다
        local Bonds = StoryEngine.Bonds
        if st == "completed" and Bonds and not e.player.spurned[fid] then
            for _, other in ipairs(living()) do
                if other ~= fid and e.player.asks[other] and Bonds.get(other, fid) < 0 and not e.player.spurned[other] then
                    e.player.spurned[other] = fid
                    e.player.votes[other] = nil
                    notify("spurned", { fid = other, over = fid })
                    log("politics campaign: helping", fid, "cost the ask-vote of", other)
                end
            end
        end
    end
    -- 휴전의 통행세
    if q.origin and q.origin.politics == "truce" and st ~= "completed" then breakTruce(now) end
    -- 보증: 보증받은 사람의 부탁을 놓쳤다
    local vouch = Politics.law("vouch")
    if vouch and not vouch.broken and fid == vouch.target and st ~= "completed" and NPC_ASKS[q.kind]
        and not Quests.isManaged(q) and not q.cancelled then
        vouch.broken = true
        local Trust = StoryEngine.Trust
        if Trust and not Factions.isGone(vouch.guarantor) then
            Trust.apply(vouch.guarantor, -Politics.VOUCH_BROKEN, "vouch_broken", q.id)
        end
    end
end

Quests.hooks[#Quests.hooks + 1] = onQuest

-- ---------------------------------------------------------------- 날마다·시간마다

-- Life.daily 가 자원을 기준값 쪽으로 옮긴 뒤 부른다
function Politics.daily()
    local s = Store.data().politics
    if not s or not s.openT or not Politics.enabled() then return end
    local now = Sensor.now()
    for _, law in ipairs(s.laws) do
        local def = Politics.BILLS[law.id]
        for _, dr in ipairs(def and def.drain or {}) do
            for _, fid in ipairs(living()) do
                if dr.all or dr.fid == fid then
                    local res = dr.res == "key" and (Life.KEY[fid] or "morale") or dr.res
                    pcall(Life.change, fid, res, -dr.n, "law")
                end
            end
        end
    end
    for _, b in ipairs(Politics.BLOCS) do
        local v = s.lean[b] or 0
        if v > 0 then s.lean[b] = v - 1 elseif v < 0 then s.lean[b] = v + 1 end
    end
    if s.calmUntil and now.t < s.calmUntil then Politics.calm() end
    local okC, errC = pcall(chairDaily, now)
    if not okC then log("politics chair error:", tostring(errC)) end
    local okM, errM = pcall(Politics.moveBlocs, now)
    if not okM then log("politics move error:", tostring(errM)) end
    local okT, errT = pcall(Politics.tip, now)
    if not okT then log("politics tip error:", tostring(errT)) end
    if StoryEngine.Offices then
        local okO, errO = pcall(StoryEngine.Offices.daily, now)
        if not okO then log("politics offices daily error:", tostring(errO)) end
    end
    if StoryEngine.Regime then
        local okR, errR = pcall(StoryEngine.Regime.daily, now)
        if not okR then log("politics regime daily error:", tostring(errR)) end
    end
    if StoryEngine.Era and StoryEngine.Era.secondChronicle then
        local okE, errE = pcall(StoryEngine.Era.secondChronicle, now)
        if not okE then log("politics second chronicle error:", tostring(errE)) end
    end
end

-- 파벌 옮김: 하루에 한 사람까지. 반환: 옮긴 사람 | nil
function Politics.moveBlocs(now)
    local s = state()
    local Bonds = StoryEngine.Bonds
    if not Bonds then return nil end
    local function avg(fid, bloc)
        local sum, n = 0, 0
        for _, m in ipairs(Politics.members(bloc)) do
            if m ~= fid then sum, n = sum + Bonds.get(fid, m), n + 1 end
        end
        if n == 0 then return nil end
        return sum / n
    end
    for _, fid in ipairs(living()) do
        local last = s.moved[fid]
        if not last or now.t - last >= Politics.MOVE_DAYS * 24 * 60 then
            local mine = Politics.blocOf(fid)
            local own = avg(fid, mine)
            if own ~= nil and own < 0 then
                local best, top = nil, nil
                for _, b in ipairs(Politics.BLOCS) do
                    local v = b ~= mine and avg(fid, b) or nil
                    if v and v >= 1 and (not top or v > top) then best, top = b, v end
                end
                if best then
                    s.blocs[fid], s.moved[fid] = best, now.t
                    local text = nameOf(fid) .. " has fallen out with " .. tostring(Politics.SIDE[mine]) .. " and sits with "
                        .. tostring(Politics.SIDE[best]) .. " at the county council now."
                    if StoryEngine.Social and StoryEngine.Social.news then StoryEngine.Social.news("all", text) end
                    notify("moved", { fid = fid, from = mine, to = best })
                    log("politics bloc move", fid, mine, "->", best)
                    return fid
                end
            end
        end
    end
    return nil
end

-- 귀띔: 우리를 깊이 믿는 NPC 가 사이 나쁜 사람의 약점을 알려 준다. force = 확률 무시 (디버그·테스트)
function Politics.tip(now, force)
    local Bonds = StoryEngine.Bonds
    if not Bonds then return nil end
    if not force and ZombRand(100) >= Politics.TIP_CHANCE then return nil end
    local s = state()
    local pairsOut = {}
    for _, a in ipairs(living()) do
        if trustOf(a) >= Politics.TIP_TRUST then
            for _, b in ipairs(living()) do
                if a ~= b and Bonds.get(a, b) < 0 and not (s.secrets and s.secrets[b]) then
                    pairsOut[#pairsOut + 1] = { a, b }
                end
            end
        end
    end
    if #pairsOut == 0 then return nil end
    local pick = pairsOut[ZombRand(#pairsOut) + 1]
    if not Politics.learnSecret(pick[2], "tip", pick[1]) then return nil end
    Radio.react(pick[1], "event", "You trust the players enough to tell them, quietly, that you know something about "
        .. nameOf(pick[2]) .. " that " .. nameOf(pick[2]) .. " would never want said in council. Tell them they could lean on "
        .. nameOf(pick[2]) .. " with it, once, if a vote ever mattered enough. Do NOT say what it is.",
        { text = "There's something you should know about them. Use it carefully.",
          lt = { key = "IGUI_StoryEngine_Politics_Say_Tip", args = { { t = "npc", v = pick[2] } } } }, nil)
    return pick[2]
end

-- 표 부탁: NPC 가 낸 법안에 맞서는 사람이 하루 뒤 플레이어에게 막아 달라고 청한다
local function plea(now)
    local s = state()
    local bill = s.bill
    if not bill or bill.pleaAsked or bill.system or bill.by == "player" or bill.by == "chair" then return end
    if now.t < bill.t + 24 * 60 then return end
    bill.pleaAsked = true
    if ZombRand(100) >= Politics.PLEA_CHANCE then return end
    local who = nil
    for _, fid in ipairs(loseOf(bill)) do
        if not who and not Factions.isGone(fid) and Factions.byId[fid] and not Factions.isOutsider(fid) then who = fid end
    end
    if not who then return end
    bill.plea = who
    Radio.react(who, "event", nameOf(bill.by) .. " has put this before the county council: " .. Politics.describe(bill)
        .. " It would cost your people. Quietly ask the players to help you stop it: they can talk others out of it in the "
        .. "Council tab before the vote.",
        { text = "That proposal will hurt us. Help me stop it.", lt = { key = "IGUI_StoryEngine_Politics_Say_Plea" } }, nil)
    notify("plea", { fid = who, id = bill.id })
end
Politics.plea = plea

-- 두 번째 연대기와 인물 탭에 넘기는 요약: 정치가 어떻게 흘렀는가
function Politics.summary()
    local s = Store.data().politics
    if not s or not s.openT then return nil end
    local now = Sensor.now()
    local out = { days = math.floor((now.t - s.openT) / (24 * 60)), passed = {}, failed = 0, moved = {} }
    if s.phase then out.phase = { kind = s.phase.kind, bloc = s.phase.bloc } end
    local c = Politics.chair()
    if c then out.chair = { fid = c.fid, bloc = c.bloc, player = c.name } end
    local seen = {}
    for _, h in ipairs(s.history or {}) do
        if h.pass and not seen[h.id] and Politics.TEXT[h.id] then
            seen[h.id] = true
            out.passed[#out.passed + 1] = h.id
        elseif not h.pass then
            out.failed = out.failed + 1
        end
    end
    for fid, b in pairs(s.blocs or {}) do
        if b ~= Politics.HOME[fid] then out.moved[#out.moved + 1] = { fid = fid, to = b } end
    end
    table.sort(out.moved, function(a, b) return a.fid < b.fid end)
    out.lean = {}
    for _, b in ipairs(Politics.BLOCS) do out.lean[b] = Politics.lean(b) end
    if StoryEngine.Regime and StoryEngine.Regime.summary then out.regime = StoryEngine.Regime.summary() end
    return out
end

function Politics.tick(now)
    now = now or Sensor.now()
    if not Politics.enabled() then return end
    local Era = StoryEngine.Era
    if not (Era and Era.active and Era.active()) then return end
    local s = state()
    if not s.openT then
        local left = Politics.openIn(now)
        if left and left <= 0 and #Sensor.players() > 0 then open(now) end
        return
    end
    -- 끝난 법안
    for i = #s.laws, 1, -1 do
        local law = s.laws[i]
        if now.t >= law.untilT then Politics.repeal(law.id, now, "expired") end
    end
    if #Sensor.players() == 0 then return end
    -- 국면: 60일마다 다시 본다
    s.nextPhaseT = s.nextPhaseT or (s.openT + Politics.PHASE_DAYS * 24 * 60)
    if now.t >= s.nextPhaseT then
        local okPh, errPh = pcall(Politics.judgePhase, now)
        if not okPh then
            log("politics phase error:", tostring(errPh))
            s.nextPhaseT = now.t + 24 * 60
        end
    end
    -- 연립·불신임·분열·군정·시설 (Regime.lua)
    local R = StoryEngine.Regime
    if R then
        local okR, errR = pcall(R.tick, now)
        if not okR then log("politics regime error:", tostring(errR)) end
    end
    -- 의회가 닫혀 있으면(분열·군정) 선거와 법안이 없다. 의회가 스스로 올린 표결만 마저 한다
    local shut = R and R.closed and R.closed() or nil
    if shut then
        s.election = nil
        if s.bill and not s.bill.system then s.bill = nil end
    else
        -- 의장 선거
        if s.election and now.t >= s.election.voteT then Politics.electionVote(now) end
        if not s.election and now.t >= (s.nextElectionT or (s.openT + Politics.ELECTION_FIRST_DAYS * 24 * 60)) then
            Politics.electionOpen(now)
        end
    end
    if s.bill and now.t >= s.bill.voteT then Politics.vote(now) end
    -- 플레이어가 의장이면 법안은 의장이 고른다 (닷새 넘게 안 고르면 파벌이 낸다)
    local waitChair = chairKey() ~= nil and now.t < (s.nextBillT or 0) + 5 * 24 * 60
    if not shut and not s.bill and now.t >= (s.nextBillT or 0) and not waitChair then Politics.propose(now) end
    Politics.meals(now)
    workshopReturns(now)
    truceToll(now)
    local okP, errP = pcall(plea, now)
    if not okP then log("politics plea error:", tostring(errP)) end
    if StoryEngine.Offices and not shut then
        local okO, errO = pcall(StoryEngine.Offices.tick, now)
        if not okO then log("politics offices error:", tostring(errO)) end
    end
end

-- ---------------------------------------------------------------- 클라이언트로

function Politics.payload(psKey, now)
    now = now or Sensor.now()
    local s = Store.data().politics
    local Era = StoryEngine.Era
    if not Politics.enabled() then return { off = true } end
    if not (Era and Era.active and Era.active()) then return { era = false } end
    if not s or not s.openT then
        return { era = true, openIn = math.ceil((Politics.openIn(now) or 0) / 60 / 24) }
    end
    local out = { era = true, on = true, blocs = {}, laws = {}, history = {} }
    for _, b in ipairs(Politics.BLOCS) do
        out.blocs[#out.blocs + 1] = { id = b, lean = Politics.lean(b), members = Politics.members(b) }
    end
    local against = {}
    for _, fid in ipairs(living()) do
        if Politics.against(fid) then against[#against + 1] = fid end
    end
    out.against = against
    if StoryEngine.Offices then
        local okF, info = pcall(StoryEngine.Offices.payload, psKey, now)
        if okF then out.offices = info else log("politics offices payload error:", tostring(info)) end
    end
    out.secrets = {}
    for fid, sec in pairs(s.secrets or {}) do
        if not sec.used and not Factions.isGone(fid) then out.secrets[#out.secrets + 1] = fid end
    end
    table.sort(out.secrets)
    if s.phase then
        out.phase = { kind = s.phase.kind, bloc = s.phase.bloc, weights = s.phase.weights, cold = s.phase.cold, by = s.phase.by,
                      days = math.max(0, math.ceil(((s.nextPhaseT or now.t) - now.t) / 60 / 24)) }
    else
        out.phaseIn = math.max(0, math.ceil(((s.nextPhaseT or (s.openT + Politics.PHASE_DAYS * 24 * 60)) - now.t) / 60 / 24))
    end
    if StoryEngine.Outsiders then
        local okO, info = pcall(StoryEngine.Outsiders.payload, psKey, now)
        if okO then out.outsiders = info else log("politics outsiders payload error:", tostring(info)) end
    end
    if StoryEngine.Crises then
        local okC2, info = pcall(StoryEngine.Crises.payload, psKey, now)
        if okC2 then out.event = info else log("politics crises payload error:", tostring(info)) end
    end
    if StoryEngine.Regime then
        local okR, info = pcall(StoryEngine.Regime.payload, psKey, now)
        if okR then out.regime = info else log("politics regime payload error:", tostring(info)) end
    end
    if s.bill then
        local t = Politics.forecast(s.bill)
        out.bill = { id = s.bill.id, bloc = s.bill.bloc, by = s.bill.by, who = s.bill.who, target = s.bill.target,
                     guarantor = s.bill.guarantor, hours = math.max(0, math.ceil((s.bill.voteT - now.t) / 60)),
                     rows = t.rows, yes = t.yes, no = t.no, pass = t.pass, two3 = t.two3, lobby = s.bill.lobby,
                     cast = s.bill.cast,
                     lobbyLeft = Politics.lobbyMax() - (function() local n = 0 for _ in pairs(s.bill.lobby or {}) do n = n + 1 end return n end)(),
                     gain = gainOf(s.bill), lose = loseOf(s.bill), system = s.bill.system, stance = s.bill.stance,
                     plea = s.bill.plea }
        -- 몰아세울 수 있는 사람과 방향 (헌장의 서명)
        out.bill.calls = {}
        for _, fid in ipairs(living()) do
            if Politics.callable(s.bill, fid, "for") then out.bill.calls[fid] = "for"
            elseif Politics.callable(s.bill, fid, "against") then out.bill.calls[fid] = "against" end
        end
    else
        out.nextIn = math.max(0, math.ceil(((s.nextBillT or now.t) - now.t) / 60 / 24))
    end
    for _, law in ipairs(s.laws) do
        local row = { id = law.id, hours = math.max(0, math.ceil((law.untilT - now.t) / 60)), target = law.target,
                      guarantor = law.guarantor, bloc = law.bloc }
        if law.collectId then row.share = math.floor(share(law.collectId) * 100 + 0.5) end
        out.laws[#out.laws + 1] = row
    end
    for i = #s.history, math.max(1, #s.history - 5), -1 do
        out.history[#out.history + 1] = s.history[i]
    end
    out.specials = Politics.specials(now)
    local c = Politics.chair()
    if c then
        out.chair = { fid = c.fid, bloc = c.bloc, player = c.name, mine = c.player ~= nil and c.player == psKey or nil,
                      days = math.max(0, math.ceil((c.untilT - now.t) / 60 / 24)) }
        if out.chair.mine and not s.bill then
            out.chair.bills = {}
            for _, id in ipairs(Politics.ORDER) do
                if not Politics.BILLS[id].special then
                    out.chair.bills[#out.chair.bills + 1] = { id = id, ok = available(id, now) }
                end
            end
        end
    end
    local cr = crisisNow()
    if cr then
        out.crisis = { saga = cr.kind, hours = math.max(0, math.ceil((cr.untilT - now.t) / 60)), offers = cr.offers,
                       deal = cr.deal, by = cr.by, open = cr.deal == nil and now.t < cr.untilT }
    end
    out.credit = s.credit
    if s.election then
        local e = s.election
        local f = Politics.electionForecast(e)
        out.election = { hours = math.max(0, math.ceil((e.voteT - now.t) / 60)), cands = e.cands, backed = e.backed,
                         backedBy = e.backedBy, rows = f.rows, votes = f.votes, winner = f.winner, player = f.player,
                         running = e.player and e.player.name or nil, spurned = e.player and e.player.spurned or nil }
        if not e.backed and not e.player then
            local low = nil
            for _, fid in ipairs(living()) do
                if runTrust(fid, psKey) < Politics.RUN_ASK then low = fid end
            end
            out.election.canRun = low == nil
            out.election.blocker = low
        end
    end
    out.promises = s.promises
    if Politics.law("workshop") and psKey then
        local last = s.workshop.used[psKey]
        local gap = Politics.WORKSHOP_GAP_DAYS * 24 * 60
        out.workshop = { wait = last and math.max(0, math.ceil((gap - (now.t - last)) / 60)) or 0 }
    end
    return out
end

-- AI 맥락: 이 NPC 의 파벌과 지금 걸린 일 (브릿지 format_politics, 없으면 nil)
function Politics.context(fid)
    if not Politics.on() then return nil end
    local s = state()
    local out = { bloc = Politics.blocOf(fid), lean = {}, laws = {}, against = Politics.against(fid) or nil }
    if s.phase then out.phase = { kind = s.phase.kind, bloc = s.phase.bloc } end
    if StoryEngine.Regime and StoryEngine.Regime.context then
        local okR, info = pcall(StoryEngine.Regime.context, fid)
        if okR then out.regime = info end
    end
    for _, b in ipairs(Politics.BLOCS) do out.lean[b] = Politics.lean(b) end
    for _, law in ipairs(s.laws) do out.laws[#out.laws + 1] = Politics.TEXT[law.id] or law.id end
    if s.bill then
        local need = Politics.need(s.bill, fid)
        out.bill = { text = Politics.describe(s.bill), mine = s.bill.by == fid or nil,
                     vote = trustOf(fid) >= need and "for" or "against",
                     days = math.max(0, math.ceil((s.bill.voteT - Sensor.now().t) / 60 / 24)) }
    end
    return out
end

-- ---------------------------------------------------------------- 디버그

-- 디버그: 정치를 바로 연다 (의회 시대가 아니어도), 법안을 내거나 표결하거나 바로 시행한다
function Politics.debug(args, player)
    local now = Sensor.now()
    local s = state()
    if args.phase then Politics.judgePhase(Sensor.now()) end
    if type(args.regime) == "table" and StoryEngine.Regime then StoryEngine.Regime.debug(args.regime, player) end
    if args.secret and Factions.byId[args.secret] then Politics.learnSecret(args.secret, "tip", nil) end
    if args.chronicle and StoryEngine.Era then StoryEngine.Era.secondChronicle(now, true) end
    if args.office and StoryEngine.Offices then StoryEngine.Offices.debug(args.office) end
    if args.open then
        if not s.openT then open(now) end
    elseif args.reset then
        Store.data().politics = nil
    elseif args.bill then
        if not s.openT then open(now) end
        s.bill = nil
        s.nextBillT = now.t
        if Politics.BILLS[args.bill] and not Politics.BILLS[args.bill].special then
            local def = Politics.BILLS[args.bill]
            local members = Politics.members(def.bloc)
            s.bill = newBill(args.bill, def.bloc, members[1] or "player", now)
            s.nextBillT = now.t + Politics.billDays() * 24 * 60
            announce(s.bill, now)
        else
            Politics.propose(now)
        end
    elseif args.vote then
        Politics.vote(now)
    elseif args.election then
        if not s.openT then open(now) end
        if s.election then Politics.electionVote(now) else Politics.electionOpen(now) end
    elseif args.enact and Politics.BILLS[args.enact] then
        if not s.openT then open(now) end
        Politics.repeal(args.enact, now, "debug")
        local def = Politics.BILLS[args.enact]
        local bill = newBill(args.enact, def.bloc, "player", now)
        if def.target then
            bill.target = args.target or "hunter"
            bill.guarantor = Politics.guarantor(bill.target)
        end
        enact(bill, now)
    elseif args.repeal then
        Politics.repeal(args.repeal, now, "debug")
    end
    return Politics.statusText()
end

function Politics.statusText()
    local s = Store.data().politics
    if not s or not s.openT then return "politics closed" end
    local laws = {}
    for _, law in ipairs(s.laws) do laws[#laws + 1] = law.id end
    local lean = {}
    for _, b in ipairs(Politics.BLOCS) do lean[#lean + 1] = b .. "=" .. StoryEngine.intToString(Politics.lean(b)) end
    return "politics lean " .. table.concat(lean, " ") .. " bill " .. tostring(s.bill and s.bill.id or "none")
        .. " laws " .. (#laws > 0 and table.concat(laws, ",") or "none")
        .. (StoryEngine.Regime and (" | " .. StoryEngine.Regime.statusText()) or "")
end

Events.EveryHours.Add(function()
    local ok, err = pcall(Politics.tick)
    if not ok then log("politics tick error:", tostring(err)) end
end)

return Politics
