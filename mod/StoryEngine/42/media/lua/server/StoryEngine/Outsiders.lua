-- 밖에서 온 사람들 (2026-10-13, docs/PLAN_COUNCIL_POLITICS.md 7단계, 확정안은 docs/IDEAS_COUNCIL_ERA.md 12-2·12-5).
--
-- 의회의 정치가 열린 뒤 네 무리가 무작위 순서로 찾아온다 (첫 무리는 FIRST_DAYS 뒤, 그 뒤로 GAP_MIN~GAP_MAX 일마다,
-- 넷이 함께 머물 수 있다). 받아들일지는 의회가 표결한다 (Politics.systemBill "admit").
--   hale 헤일 대령 호송대 / odell 오델 선장 강 상인단 / okafor 오카포 박사 연구팀 / abigail 아비게일 어머니 순례단
-- 원래 여덟의 표(Factions.list)에는 넣지 않는다. Factions.outsiders 에 있고, 와 있을 때만 Factions.present[id] 가 참이다
-- (없으면 Factions.isGone 이 참이라 무전·부탁이 모두 막힌다). 생활 자원·장기 프로젝트·이야기 장은 없다.
--
-- 신뢰: 처음 START_TRUST(35), 늘 무리 신뢰 하나 (개인 신뢰 모드에서도). 올리는 길 = 그 사람의 부탁, 일거리 청하기,
--   오델과의 거래, 선물(물자 지원처럼 사흘 통, 신뢰만).
-- 특기: 1차 신뢰 40, 2차 신뢰 70. 쓸 때마다 꺼리는 원래 NPC 마다 신뢰 -USE_COST (R1).
--   hale   proxy 대리 작전 (소탕·경비·정찰 하나를 대신 끝냄) / airdrop 공수 작전 (고른 자리로 옮기고 호위)
--   odell  order 주문 (원하는 물건 하나, 값은 가치의 2배, 아무 품목이나 대가) / jewels 귀중품 수집 (장신구 -> 화폐)
--   okafor retard 지연제 (감염 진행을 7일 멈춤) / regimen 체질 관리 (5일 배고픔·갈증 절반, 체중을 80 쪽으로)
--   abigail miracle 기적 (체력 15% 이하에서 발동, 2시간 출혈 멈춤·통증 없음) / burden 짐을 든 자 (2일 무게 +100%)
-- 충성 시험 (E10~E13): 받아들인 지 TEST_MIN~TEST_MAX 일 뒤 한 번. 밖에서 온 사람을 고르면 특기가 세지고 맞선 NPC 가 값을 치른다
--   (Outsiders.mod, 머무는 동안 계속). 원래 NPC 를 고르면 얻는 것은 없고 그 사람이 힘든 쪽이 된다
--   (일을 해 주지 않은 날 이틀마다 -1, 얻는 신뢰 절반). 고르지 않으면 양쪽 -TEST_IGNORE.
-- 떠남: 신뢰 LEAVE_TRUST 미만이 LEAVE_DAYS 일. 등 돌림 (R5): 꺼리는 NPC 의 신뢰가 ABSENT_TRUST 밑이면 그 NPC 는 표결에
--   안 나오고, 셋 다 그러면 추방 재투표 (E14, Politics.systemBill "expel").
--
-- 상태: d.outsiders = { queue, nextT, pending, here[id] = { sinceT, day, idle, low, hard, sided, testT, test, askT,
--                       used[key][n] = t, gift, expelT, refused }, left[id], fx, armed[key], jobs, day, raidT }

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Radio"
require "StoryEngine/Trust"
require "StoryEngine/Fate"
require "StoryEngine/Quests"
require "StoryEngine/Stories"
require "StoryEngine/Value"
require "StoryEngine/ItemPool"

local Outsiders = {}
StoryEngine.Outsiders = Outsiders

local Net = StoryEngine.Net
local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Radio = StoryEngine.Radio
local Quests = StoryEngine.Quests
local Stories = StoryEngine.Stories
local Value = StoryEngine.Value
local log = StoryEngine.log

Outsiders.DEFS = {
    hale = { rival = "guard", dislike = { "guard", "rats", "hunter" }, name = "Colonel Hale",
             who = "Colonel Hale's army convoy, about thirty soldiers with trucks who came down the highway" },
    odell = { rival = "rats", dislike = { "rats", "ray", "dewey" }, name = "Captain Odell",
              who = "Captain Odell's river traders, three barges that tie up along the Ohio" },
    okafor = { rival = "doc", dislike = { "doc", "pike", "hunter" }, name = "Dr. Okafor",
               who = "Dr. Okafor's research team, a handful of scientists with a field lab" },
    abigail = { rival = "pike", dislike = { "pike", "doc", "casey" }, name = "Mother Abigail",
                who = "Mother Abigail's pilgrims, a walking congregation that follows her" },
}
Outsiders.ORDER = { "hale", "odell", "okafor", "abigail" }
Outsiders.SPECS = {
    hale = { "proxy", "airdrop" }, odell = { "order", "jewels" },
    okafor = { "retard", "regimen" }, abigail = { "miracle", "burden" },
}

Outsiders.FIRST_DAYS = 16             -- 정치가 열린 뒤 (의회가 선 뒤 30일쯤)
Outsiders.GAP_MIN_DAYS = 14
Outsiders.GAP_MAX_DAYS = 28
Outsiders.START_TRUST = 35
Outsiders.SPEC_TRUST = { 40, 70 }
Outsiders.USE_COST = 2
Outsiders.HARD_EVERY = 2
Outsiders.LEAVE_TRUST = 30
Outsiders.LEAVE_DAYS = 3
Outsiders.TEST_MIN_DAYS = 10
Outsiders.TEST_MAX_DAYS = 14
Outsiders.TEST_HOURS = 72
Outsiders.TEST_IGNORE = 5
Outsiders.ABSENT_TRUST = 30
Outsiders.EXPEL_COOLDOWN_DAYS = 30
Outsiders.ABSTAIN_COST = 5
Outsiders.FOLLOW_TRUST = 50           -- 추방 표결: 이만큼 믿는 NPC 는 플레이어의 뜻을 따른다
Outsiders.ASK_MIN_DAYS = 3
Outsiders.ASK_MAX_DAYS = 5
Outsiders.GIFT_DAYS = 3
Outsiders.GIFT_STEPS = { { 5, 1 }, { 15, 2 }, { 30, 3 } }
Outsiders.RAID_DAYS = 7               -- E12: 빅이 주마다 무작위 NPC 하나를 턴다
Outsiders.RAID_LOSS = 10

-- 특기 대기 (일). sided = 충성 시험에서 밖에서 온 사람을 골랐을 때
Outsiders.WAIT = { proxy = 14, airdrop = 7, order = 7, jewels = 7, retard = 7, regimen = 14, miracle = 14, burden = 7 }
Outsiders.WAIT_SIDED = { proxy = 7, airdrop = 4, miracle = 7 }
Outsiders.RETARD_DAYS = 7
Outsiders.REGIMEN_DAYS = 5
Outsiders.MIRACLE_MIN = 120
Outsiders.MIRACLE_HEALTH = 15
Outsiders.MIRACLE_RADIUS = 5
Outsiders.BURDEN_DAYS = 2
Outsiders.BURDEN_DAYS_SIDED = 3
Outsiders.JEWEL_CAP = 60
Outsiders.JEWEL_CAP_SIDED = 80
Outsiders.ORDER_PRICE = 2
Outsiders.ORDER_SHOWN = 40            -- 주문 창에 등급마다 보여 줄 물건 수
Outsiders.AIRDROP_RANGE = 240
Outsiders.AIRDROP_DELAY = 10
Outsiders.AIRDROP_MIN_DIST = 30
Outsiders.ESCORT_COUNT = 4
Outsiders.ESCORT_HOURS = 3
Outsiders.ESCORT_SNIPE = 30
Outsiders.SCRIP = "StoryEngine.Scrip"
Outsiders.PROXY_KINDS = { horde = true, defend = true, scout = true }

-- 그 사람의 부탁 (Needs.TABLE 에 더한다). 늘 큰 부탁이다
Outsiders.NEEDS = {
    hale = {
        { tier = 3, why = "the convoy is short of rifle ammunition after the road south", items = { { "Base.556Box", 2 } } },
        { tier = 3, why = "two of his drivers are down with infected wounds", items = { { "Base.Antibiotics", 1 }, { "Base.Bandage", 4 } } },
        { tier = 4, why = "a truck threw its engine and the column cannot move without it", items = { { "Base.EngineParts", 6 }, { "Base.Wrench", 1 } } },
        { tier = 4, why = "his men have been on half rations for a week", items = { { "Base.TinnedBeans", 8 }, { "Base.CannedCornedBeef", 4 } } },
    },
    odell = {
        { tier = 3, why = "a barge is taking on water and needs patching before the river rises", items = { { "Base.SheetMetal", 3 }, { "Base.DuctTape", 3 } } },
        { tier = 3, why = "his crew wants something to drink and smoke after weeks on the water", items = { { "Base.Whiskey", 2 }, { "Base.CigarettePack", 3 } } },
        { tier = 4, why = "the barges are running on fumes and he needs tools to strip an engine", items = { { "Base.Wrench", 1 }, { "Base.Screwdriver", 1 }, { "Base.EngineParts", 4 } } },
        { tier = 4, why = "river pirates hit him upstream and he wants shells for the deck guns", items = { { "Base.ShotgunShellsBox", 3 } } },
    },
    okafor = {
        { tier = 3, why = "the field lab is out of sterile dressings and disinfectant", items = { { "Base.Disinfectant", 2 }, { "Base.Bandage", 5 } } },
        { tier = 3, why = "the lab's instruments run on batteries and they are nearly flat", items = { { "Base.Battery", 6 } } },
        { tier = 4, why = "he needs surgical tools to take samples safely", items = { { "Base.SutureNeedle", 2 }, { "Base.Tweezers", 1 }, { "Base.Scalpel", 1 } } },
        { tier = 4, why = "the cold chain failed and the team needs a generator's worth of wiring to rebuild it", items = { { "Base.ElectricWire", 5 }, { "Base.ElectronicsScrap", 8 } } },
    },
    abigail = {
        { tier = 3, why = "the pilgrims walked in on bleeding feet and have nothing to bind them", items = { { "Base.Bandage", 6 }, { "Base.Disinfectant", 1 } } },
        { tier = 3, why = "there are children among them who have not had a full meal in days", items = { { "Base.TinnedSoup", 6 } } },
        { tier = 4, why = "the nights are cold and the congregation sleeps in the open", items = { { "Base.Sheet", 8 }, { "Base.Matches", 2 } } },
        { tier = 4, why = "her people carry everything by hand and their old ones are failing", items = { { "Base.Pills", 3 }, { "Base.WaterRationCan", 6 } } },
    },
}

for id, def in pairs(Outsiders.DEFS) do
    Stories.NAMES[id] = Stories.NAMES[id] or def.name
end
if StoryEngine.Needs then
    for id, list in pairs(Outsiders.NEEDS) do
        StoryEngine.Needs.TABLE[id] = StoryEngine.Needs.TABLE[id] or list
    end
end

-- ---------------------------------------------------------------- 상태

local function state()
    local d = Store.data()
    d.outsiders = d.outsiders or {}
    local s = d.outsiders
    s.here = s.here or {}
    s.left = s.left or {}
    s.fx = s.fx or {}
    s.armed = s.armed or {}
    s.jobs = s.jobs or {}
    return s
end

function Outsiders.state() return state() end

local function has(list, v)
    for _, x in ipairs(list or {}) do
        if x == v then return true end
    end
    return false
end

local function count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

local function nameOf(fid)
    return tostring(Stories.NAMES[fid] or fid)
end

local function trustOf(fid)
    return Radio.channel(fid).trust or 0
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
    pcall(Net.toAll, "outsiderNotice", args)
end

local function option()
    return StoryEngine.option == nil or StoryEngine.option("Outsiders") ~= false
end

function Outsiders.enabled()
    local Pol = StoryEngine.Politics
    return option() and Pol ~= nil and Pol.on()
end

function Outsiders.isHere(id)
    local s = Store.data().outsiders
    return s ~= nil and s.here ~= nil and s.here[id] ~= nil
end

function Outsiders.hereList()
    local out = {}
    local s = state()
    for _, id in ipairs(Outsiders.ORDER) do
        if s.here[id] then out[#out + 1] = id end
    end
    return out
end

-- 와 있는 사람만 무전 상대다. 원래 여덟은 Fate 가 정한 값 그대로
local baseGone, baseFate = Factions.isGone, Factions.fateOf
function Factions.isGone(id)
    if Outsiders.DEFS[id] then return not Outsiders.isHere(id) end
    return baseGone(id)
end
function Factions.fateOf(id)
    if Outsiders.DEFS[id] then return nil end
    return baseFate(id)
end

local function syncPresent()
    local s = state()
    local list = {}
    for _, id in ipairs(Outsiders.ORDER) do
        Factions.present[id] = s.here[id] ~= nil or nil
        if s.here[id] then list[#list + 1] = id end
    end
    return list
end

function Outsiders.broadcast(player)
    local args = { present = syncPresent() }
    if player then
        pcall(Net.toClient, player, "outsiders", args)
    else
        pcall(Net.toAll, "outsiders", args)
    end
end

function Outsiders.sided(id)
    local s = Store.data().outsiders
    local o = s and s.here and s.here[id]
    return o ~= nil and o.sided == "out"
end

function Outsiders.hard(id)
    local s = Store.data().outsiders
    local o = s and s.here and s.here[id]
    return o ~= nil and o.hard == true
end

-- 이 원래 NPC 를 꺼리게 만드는, 지금 와 있는 사람들
function Outsiders.dislikedBy(fid)
    local out = {}
    for _, id in ipairs(Outsiders.hereList()) do
        if has(Outsiders.DEFS[id].dislike, fid) then out[#out + 1] = id end
    end
    return out
end

-- 등 돌림 (R5): 와 있는 사람을 꺼리는 NPC 의 신뢰가 바닥이면 표결에 나오지 않는다
function Outsiders.absent(fid)
    if not Outsiders.enabled() then return false end
    if #Outsiders.dislikedBy(fid) == 0 then return false end
    return trustOf(fid) < Outsiders.ABSENT_TRUST
end

-- 정치 보정에 얹는 값 (Politics.mod 가 부른다): 곱할 값 | 참 | nil
function Outsiders.mod(key, fid, a)
    if not fid then return nil end
    if fid == "guard" and Outsiders.sided("hale") then
        if key == "specWait" then return 2 end
        if key == "specCost" then return 1.5 end
    end
    if fid == "rats" and Outsiders.sided("odell") and key == "tradeBlock" then return true end
    if key == "specBlock" then
        if fid == "doc" and Outsiders.sided("okafor") then return true end
        if fid == "pike" and Outsiders.sided("abigail") then return true end
    end
    return nil
end

-- 얻는 신뢰 (Trust.apply 가 부른다): 힘든 쪽이면 절반 (올림)
function Outsiders.gain(fid, delta)
    if delta > 0 and Outsiders.hard(fid) then return math.max(1, math.ceil(delta / 2 - 0.001)) end
    return delta
end

-- ---------------------------------------------------------------- 등장과 떠남

local function randDays(a, b)
    return (a + ZombRand(b - a + 1)) * 24 * 60
end

local function shuffled()
    local list = {}
    for _, id in ipairs(Outsiders.ORDER) do list[#list + 1] = id end
    for i = #list, 2, -1 do
        local j = ZombRand(i) + 1
        list[i], list[j] = list[j], list[i]
    end
    return list
end

local function admitText(id)
    return "letting " .. Outsiders.DEFS[id].who .. " stay in the county and join the radio net"
end

-- 낯선 호출이 잡히고, 받아들일지가 의회에 올라간다. 반환: bill | nil
function Outsiders.arrive(id, now)
    local s = state()
    local Pol = StoryEngine.Politics
    if s.here[id] or s.pending or not Outsiders.DEFS[id] then return nil end
    local bill = Pol.systemBill("admit", { target = id, lose = Outsiders.DEFS[id].dislike, text = admitText(id) }, now)
    if not bill then return nil end
    s.pending = id
    local text = "A strange call came over the radio: " .. Outsiders.DEFS[id].who .. " are asking to stay in the county. "
        .. "The council votes on it in " .. StoryEngine.intToString(Pol.PREP_DAYS) .. " days."
    if StoryEngine.Social and StoryEngine.Social.news then StoryEngine.Social.news("all", text) end
    notify("hail", { id = id })
    log("outsider hail", id)
    return bill
end

local function admit(id, now)
    local s = state()
    local ch = Radio.channel(id)
    ch.trust = Outsiders.START_TRUST
    s.here[id] = { sinceT = now.t, day = Store.serverDays(), idle = 0, low = 0, used = {},
                   testT = now.t + randDays(Outsiders.TEST_MIN_DAYS, Outsiders.TEST_MAX_DAYS),
                   askT = now.t + randDays(1, 2) }
    s.left[id] = nil
    Outsiders.broadcast()
    local text = nameOf(id) .. " was allowed to stay: " .. Outsiders.DEFS[id].who .. " are in the county now."
    if StoryEngine.Social and StoryEngine.Social.news then StoryEngine.Social.news("all", text) end
    for _, ps in pairs(Store.data().players) do
        if not ps.dead then Store.addNote(ps, { kind = "op", text = text, clock = now.clock }) end
    end
    Radio.react(id, "event", "The county council just voted to let you and your people stay. This is your first call to the "
        .. "players on your own frequency: say who you are, what you can do for them, and that you know not everyone here "
        .. "wanted you.", StoryEngine.Lines.fallback(id, "out_hello", "We are grateful for the welcome. You will not regret it."), nil)
    notify("admitted", { id = id })
    log("outsider admitted", id)
end

-- 떠난다. why: left(신뢰가 바닥) | expelled(추방) | debug
function Outsiders.leave(id, why, now)
    local s = state()
    local o = s.here[id]
    if not o then return false end
    now = now or Sensor.now()
    if why ~= "debug" then
        pcall(Radio.react, id, "event", why == "expelled"
            and "The county council just voted to send you and your people away. Say goodbye; you are bitter but you go."
            or "You and your people are moving on: these people stopped coming to you and you see no reason to stay. Say goodbye.",
            StoryEngine.Lines.fallback(id, "out_bye", "We are moving on. Look after yourselves."), nil)
    end
    s.here[id] = nil
    s.left[id] = { day = Store.serverDays(), why = why }
    -- 그 사람이 걸어 둔 효과는 함께 사라진다 (지연제로 멈춰 둔 감염이 다시 흐른다)
    for i = #s.fx, 1, -1 do
        local f = s.fx[i]
        if f.oid == id then
            local p = playerByKey(f.key)
            if p then pcall(Net.toClient, p, "outsiderFx", { kind = f.kind, minutes = 0 }) end
            table.remove(s.fx, i)
        end
    end
    if id == "abigail" then s.armed = {} end
    pcall(Quests.cancelFor, id)
    local Pol = StoryEngine.Politics
    local bill = Pol and Pol.state().bill
    if bill and bill.target == id and (bill.id == "expel" or bill.id == "admit") then Pol.state().bill = nil end
    Outsiders.broadcast()
    local text = nameOf(id) .. (why == "expelled" and " was sent away by the council." or " and their people left the county.")
    if StoryEngine.Social and StoryEngine.Social.news then StoryEngine.Social.news("all", text) end
    for _, ps in pairs(Store.data().players) do
        if not ps.dead then Store.addNote(ps, { kind = "op", text = text, clock = now.clock }) end
    end
    notify("left", { id = id, why = why })
    log("outsider left", id, tostring(why))
    return true
end

-- 표결 결과 (Politics.vote 가 부른다)
function Outsiders.onVote(bill, pass, now)
    local s = state()
    local id = bill.target
    if bill.id == "admit" then
        s.pending = nil
        s.nextT = now.t + randDays(Outsiders.GAP_MIN_DAYS, Outsiders.GAP_MAX_DAYS)
        if pass then
            admit(id, now)
        else
            -- 한 번은 다시 문을 두드린다
            s.refused = s.refused or {}
            s.refused[id] = (s.refused[id] or 0) + 1
            if s.refused[id] < 2 then s.queue[#s.queue + 1] = id end
            s.left[id] = { day = Store.serverDays(), why = "refused" }
            notify("refused", { id = id })
            log("outsider refused", id)
        end
    elseif bill.id == "expel" then
        local o = s.here[id]
        if not o then return end
        o.expelT = now.t
        local stance = bill.stance
        if stance ~= "keep" and stance ~= "expel" then
            -- 물러서 있었다: 양쪽 모두 서운해한다
            StoryEngine.Trust.apply(id, -Outsiders.ABSTAIN_COST, "expel_abstain")
            for _, fid in ipairs(Outsiders.DEFS[id].dislike) do
                if not Factions.isGone(fid) then StoryEngine.Trust.apply(fid, -Outsiders.ABSTAIN_COST, "expel_abstain", nil, nil, id) end
            end
        end
        if pass then Outsiders.leave(id, "expelled", now) else notify("kept", { id = id }) end
    end
end

-- 추방 표결의 표 (bill.pledged): 꺼리는 쪽은 내보내자, 나머지는 플레이어의 뜻을 따르거나 남기자
function Outsiders.expelVotes(bill)
    local id = bill.target
    local def = Outsiders.DEFS[id]
    local Bonds = StoryEngine.Bonds
    local sided = Outsiders.sided(id)
    bill.pledged = {}
    for _, f in ipairs(Factions.list) do
        local fid = f.id
        if not Factions.isGone(fid) then
            local out = has(def.dislike, fid)
            -- 충성 시험에서 밖에서 온 사람을 골랐으면, 맞선 NPC 를 좋아하는 쪽도 내보내자에 선다
            if not out and sided and Bonds and Bonds.get(fid, def.rival) > 0 then out = true end
            if not out and bill.stance == "expel" and trustOf(fid) >= Outsiders.FOLLOW_TRUST then out = true end
            if out and bill.stance == "keep" and not has(def.dislike, fid) and fid ~= def.rival
                and trustOf(fid) >= Outsiders.FOLLOW_TRUST then
                out = false
            end
            bill.pledged[fid] = out
        end
    end
end

-- 플레이어의 뜻: keep | expel | abstain
function Outsiders.stance(player, id, stance)
    local Pol = StoryEngine.Politics
    local bill = Pol and Pol.state().bill
    if not bill or bill.id ~= "expel" or bill.target ~= id then return false, "no_vote" end
    if stance ~= "keep" and stance ~= "expel" and stance ~= "abstain" then return false, "how" end
    bill.stance = stance
    bill.who = Store.player(player).name
    Outsiders.expelVotes(bill)
    return true
end

local function openExpel(id, now)
    local Pol = StoryEngine.Politics
    local bill = Pol.systemBill("expel", { target = id, text = "sending " .. Outsiders.DEFS[id].who .. " away from the county" }, now)
    if not bill then return nil end
    Outsiders.expelVotes(bill)
    for _, fid in ipairs(Outsiders.DEFS[id].dislike) do
        if not Factions.isGone(fid) then
            pcall(Radio.react, fid, "event", "You have had enough of " .. nameOf(id) .. " and their people. You and the others who "
                .. "feel the same just called a council vote to send them away. Tell the players why, and that you will "
                .. "remember where they stand.", nil, nil)
            break
        end
    end
    notify("expel", { id = id })
    log("outsider expel vote", id)
    return bill
end

-- 해적 방송의 발신지가 이 사람들이었다 (Inquiry.lua E17): 추방 표결을 올린다
function Outsiders.callExpel(id, now)
    local o = state().here[id]
    if not o then return nil end
    o.expelT = (now or Sensor.now()).t
    return openExpel(id, now or Sensor.now())
end

-- ---------------------------------------------------------------- 충성 시험 (E10~E13)

local TEST_TOPIC = {
    hale = { out = "Whitaker and the Guard refuse to take orders from you. You want the players to say, in front of everyone, that your column commands the county's defence.",
             home = "Colonel Hale wants your men under his command. You want the players to say plainly that the county's defence is yours." },
    odell = { out = "Vic's crew is undercutting you and leaning on your buyers. You want the players to trade the river's way and say so.",
              home = "Captain Odell is beating down your prices with river goods. You want the players to stand with the crew that was here first." },
    okafor = { out = "You need samples from the infected and Doc Adler will not let you near her patients. You want the players to back the research.",
               home = "Dr. Okafor wants to take samples from your patients, the living ones too. You want the players to say no for you." },
    abigail = { out = "Pastor Pike's pews are emptying toward your pilgrims and he preaches against you. You want the players to say your people may gather freely.",
                home = "Mother Abigail's pilgrims are emptying your church. You want the players to stand with the church that held through the siege." },
}

local function openTest(id, now)
    local s = state()
    local o = s.here[id]
    local rival = Outsiders.DEFS[id].rival
    if Factions.isGone(rival) then
        o.testT = nil               -- 맞설 사람이 없다
        return false
    end
    o.test = { untilT = now.t + Outsiders.TEST_HOURS * 60, rival = rival }
    pcall(Radio.react, id, "crisis", TEST_TOPIC[id].out .. " Ask them to choose you over " .. nameOf(rival) .. ". They have three days.",
        StoryEngine.Lines.fallback(id, "out_appeal", "It is them or us. I need to know where you stand."), nil)
    pcall(Radio.react, rival, "crisis", TEST_TOPIC[id].home .. " Ask them to choose you over " .. nameOf(id) .. ". They have three days.",
        nil, nil)
    notify("test", { id = id, rival = rival })
    log("outsider loyalty test", id, "vs", rival)
    return true
end

-- side: "out"(밖에서 온 사람) | "home"(원래 NPC)
function Outsiders.side(player, id, side)
    local s = state()
    local o = s.here[id]
    if not o or not o.test then return false, "no_test" end
    if side ~= "out" and side ~= "home" then return false, "how" end
    local ps = Store.player(player)
    local rival = o.test.rival
    o.test, o.testT = nil, nil
    o.sided = side
    o.sidedBy = ps.name
    if side == "home" then o.hard = true end
    local chosen, other = (side == "out") and id or rival, (side == "out") and rival or id
    pcall(Radio.react, chosen, "event", ps.name .. " and the players chose you over " .. nameOf(other) .. ". Thank them; "
        .. "say what it means to your people.", nil, ps)
    pcall(Radio.react, other, "event", ps.name .. " and the players chose " .. nameOf(chosen) .. " over you. "
        .. (side == "out" and "You will not make it easy for them from now on." or "You are cold now: they will have to work "
            .. "much harder to keep you here, and you say so."),
        Factions.isOutsider(other) and StoryEngine.Lines.fallback(other, "out_cold", "So that is how it is. Then expect less of us.") or nil, ps)
    local text = "The players sided with " .. nameOf(chosen) .. " against " .. nameOf(other) .. "."
    if StoryEngine.Social and StoryEngine.Social.news then StoryEngine.Social.news("all", text) end
    Store.addNote(ps, { kind = "op", text = text, clock = Sensor.now().clock })
    notify("sided", { id = id, side = side, rival = rival })
    log("outsider sided", id, side, "by", ps.name)
    return true
end

local function testIgnored(id, now)
    local o = state().here[id]
    local rival = o.test.rival
    o.test, o.testT = nil, nil
    StoryEngine.Trust.apply(id, -Outsiders.TEST_IGNORE, "loyalty_ignored")
    if not Factions.isGone(rival) then StoryEngine.Trust.apply(rival, -Outsiders.TEST_IGNORE, "loyalty_ignored", nil, nil, id) end
    o.testT = now.t + randDays(Outsiders.TEST_MIN_DAYS, Outsiders.TEST_MAX_DAYS)      -- 다시 묻는다
    notify("test_ignored", { id = id, rival = rival })
    log("outsider loyalty test ignored", id)
end

-- ---------------------------------------------------------------- 특기: 공통

local function sidedWait(kind, id)
    if Outsiders.sided(id) and Outsiders.WAIT_SIDED[kind] then return Outsiders.WAIT_SIDED[kind] end
    return Outsiders.WAIT[kind]
end

local function waitMinutes(kind, id)
    local Tuning = StoryEngine.Tuning
    if Tuning and Tuning.outsiderDays then
        return math.floor(Tuning.outsiderDays(kind, Outsiders.sided(id)) * 24 * 60)   -- 샌드박스 OutsiderDays_<특기>
    end
    local mult = Tuning and Tuning.num("SpecialtyCooldownMult") or 1
    if mult <= 0 then mult = 1 end
    return math.floor(sidedWait(kind, id) * 24 * 60 * mult)
end

local function fxOf(kind, key, now)
    for _, f in ipairs(state().fx) do
        if f.kind == kind and f.key == key and (not now or now < f.untilT) then return f end
    end
    return nil
end

local function sendFx(f, player, now)
    if not player then return end
    local left = math.max(0, f.untilT - now.t)
    pcall(Net.toClient, player, "outsiderFx", { kind = f.kind, minutes = left, cure = f.cure, radius = f.radius })
end

local function addFx(fx, player)
    local list = state().fx
    for i = #list, 1, -1 do
        if list[i].kind == fx.kind and list[i].key == fx.key then table.remove(list, i) end
    end
    list[#list + 1] = fx
    sendFx(fx, player, Sensor.now())
    return fx
end

-- 접속했을 때·10분마다 다시 알린다 (클라이언트 효과는 클라이언트가 기억하지 않는다)
function Outsiders.resend(player)
    local s = state()
    local now = Sensor.now()
    local key = Store.playerKey(player)
    for _, f in ipairs(s.fx) do
        if f.key == key and now.t < f.untilT then sendFx(f, player, now) end
    end
    if s.armed[key] then pcall(Net.toClient, player, "outsiderFx", { kind = "armed", minutes = 60 * 24 * 365 }) end
end

-- 특기 상태: { kind, ok, why = away|trust|wait|armed|active, need, wait(분) }
function Outsiders.status(id, n, key, now)
    now = now or Sensor.now().t
    local kind = Outsiders.SPECS[id] and Outsiders.SPECS[id][n]
    local out = { kind = kind, n = n, need = Outsiders.SPEC_TRUST[n], ok = false }
    if kind then out.days = waitMinutes(kind, id) / (24 * 60) end      -- 툴팁에 보일 대기 (일)
    if not kind then
        out.why = "away"
        return out
    end
    local o = state().here[id]
    if not o then
        out.why = "away"
        return out
    end
    if trustOf(id) < out.need then
        out.why = "trust"
        return out
    end
    if kind == "miracle" and key and state().armed[key] then
        out.why = "armed"
        return out
    end
    local last = key and o.used[key] and o.used[key][n] or nil
    if last then
        local left = waitMinutes(kind, id) - (now - last)
        if left > 0 then
            out.why, out.wait = "wait", left
            return out
        end
    end
    out.ok = true
    return out
end

local HANDLERS = {}

-- 쓴다. 반환: true, 정보 | false, 이유, 남은 분
function Outsiders.use(player, id, n, args)
    if not Outsiders.enabled() then return false, "closed" end
    if not Outsiders.DEFS[id] then return false, "no_faction" end
    if not Factions.canTalk(player) then return false, "no_radio" end
    n = math.floor(tonumber(n) or 0)
    local ps = Store.player(player)
    local now = Sensor.now()
    local st = Outsiders.status(id, n, ps.key, now.t)
    if not st.ok then return false, st.why, st.wait end
    local ok, info = HANDLERS[st.kind](player, ps, id, args or {}, now)
    if not ok then return false, info end
    info = info or {}
    local o = state().here[id]
    if not info.later then
        o.used[ps.key] = o.used[ps.key] or {}
        o.used[ps.key][n] = now.t
    end
    Outsiders.pay(id, ps)
    if StoryEngine.Trust.touch then pcall(StoryEngine.Trust.touch, id, ps.key) end
    if info.topic then
        pcall(Radio.react, id, "event", info.topic, StoryEngine.Lines.fallback(id, "out_spec", "It is done."), ps, { overhead = true })
    end
    Store.addNote(ps, { kind = "op", text = nameOf(id) .. " " .. (info.note or ("helped " .. ps.name .. " (" .. st.kind .. ")")) .. ".",
                        clock = now.clock })
    log("outsider specialty", id, st.kind, "by", ps.name)
    return true, { kind = st.kind, info = info.info }
end

-- 특기의 값은 관계 (R1): 꺼리는 원래 NPC 마다 신뢰가 깎인다
function Outsiders.pay(id, ps)
    for _, fid in ipairs(Outsiders.DEFS[id].dislike) do
        if not Factions.isGone(fid) then
            StoryEngine.Trust.apply(fid, -Outsiders.USE_COST, "outsider_used", nil, ps and ps.key or nil, id)
        end
    end
end

-- ---------------------------------------------------------------- 헤일: 대리 작전·공수 작전

function Outsiders.proxyList(key)
    local out = {}
    for _, q in pairs(Store.data().quests or {}) do
        if Outsiders.PROXY_KINDS[q.kind] and Quests.isActive(q) and not Quests.isOp(q) and not Quests.isSaga(q)
            and not (q.origin and q.origin.council) and not q.siege then
            out[#out + 1] = { id = q.id, kind = q.kind, tier = q.tier, faction = q.origin and q.origin.faction or nil }
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function HANDLERS.proxy(player, ps, id, args, now)
    local q = Store.data().quests[tostring(args.quest or "")]
    local okQ = false
    for _, row in ipairs(Outsiders.proxyList(ps.key)) do
        if q and row.id == q.id then okQ = true end
    end
    if not okQ then return false, "no_job" end
    q.proxy = id            -- 도제 수업의 경험치와 야간 작전 보너스는 없다 (Work.volunteerEnd, Quests.bonusMult)
    Quests.addHelper(q, ps)
    if q.kind == "horde" and not Quests.isManaged(q) then
        Quests.completeHorde(q)             -- NPC 가 청한 소탕: 보상 보급까지
    else
        Quests.setState(q, "completed", now, { ps = ps })
    end
    return true, { note = "sent soldiers to finish a " .. tostring(q.kind) .. " job in " .. ps.name .. "'s place",
                   topic = "Your soldiers just finished a job (" .. tostring(q.kind) .. ") that " .. ps.name
                       .. " had taken on for someone in the county. Report it done, short and military." }
end

local function teleportBlocked()
    if not isServer() then return false end
    local ok, v = pcall(function() return getServerOptions():getInteger("AntiCheatSpeed") end)
    if not ok or v == nil then return false end
    return v == 1 or v == 2
end

-- 조준 창이 묻는다: 고른 자리에 내릴 수 있는가
function Outsiders.scan(player, x, y)
    x, y = math.floor(tonumber(x) or 0), math.floor(tonumber(y) or 0)
    local dx, dy = x - player:getX(), y - player:getY()
    local dist = math.floor(math.sqrt(dx * dx + dy * dy))
    local out = { faction = "hale", x = x, y = y, dist = dist, ok = true }
    if dist > Outsiders.AIRDROP_RANGE then
        out.ok, out.reason = false, "out_far"
    elseif dist < Outsiders.AIRDROP_MIN_DIST then
        out.ok, out.reason = false, "out_near"
    end
    local sq = getCell() and getCell():getGridSquare(x, y, 0)
    if sq then
        out.loaded = true
        local n = 0
        local list = getCell():getZombieList()
        for i = 0, (list and list:size() or 0) - 1 do
            local z = list:get(i)
            if z and not z:isDead() and math.abs(z:getX() - x) <= 15 and math.abs(z:getY() - y) <= 15 then n = n + 1 end
        end
        out.zombies = n
    end
    return out
end

function HANDLERS.airdrop(player, ps, id, args, now)
    if teleportBlocked() then return false, "anticheat" end
    local scan = Outsiders.scan(player, args.x, args.y)
    if not scan.ok then return false, scan.reason end
    local jobs = state().jobs
    jobs[#jobs + 1] = { kind = "airdrop", key = ps.key, dueT = now.t + Outsiders.AIRDROP_DELAY, x = scan.x, y = scan.y }
    return true, { note = "flew " .. ps.name .. " across the county with an escort",
                   topic = "A helicopter from your column is on its way to pick up " .. ps.name .. " and set them down where "
                       .. "they asked, with four of your best soldiers. About ten minutes out. Tell them to be ready." }
end

local function runAirdrop(job, now)
    local p = playerByKey(job.key)
    if not p or p:isDead() then return now.t - job.dueT > 60 end
    pcall(Net.toClient, p, "spec2Teleport", { x = job.x, y = job.y, z = 0 })
    local jobs = state().jobs
    jobs[#jobs + 1] = { kind = "escort", key = job.key, dueT = now.t + 2 }
    log("outsider airdrop", job.key, job.x, job.y)
    return true
end

local function runEscort(job, now)
    local p = playerByKey(job.key)
    if not p or p:isDead() then return true end
    local sent = false
    local ALife = StoryEngine.ALife
    if ALife and ALife.enabled() and ALife.available() and not baseGone("guard") then
        -- 헤일이 보내는 군인은 모두 자동화기를 든 기관총 역할 (2026-10-19 사용자 요청)
        local ok = ALife.sendSupport(p, "guard", "specialty2", nil, 5, nil, Outsiders.ESCORT_COUNT,
            { hours = Outsiders.ESCORT_HOURS, quiet = true, extra = true, armed = true,
              conducts = ALife.squadConducts(Outsiders.ESCORT_COUNT, Outsiders.ESCORT_COUNT, true) })
        sent = ok == true
    end
    if not sent then
        -- A-Life 가 없으면 휘태커의 특기처럼 먼 곳에서 쏴 준다
        local Spec = StoryEngine.Specialty
        if Spec and Spec.snipeCap then Spec.snipeCap[job.key] = Outsiders.ESCORT_SNIPE end
        pcall(Net.toClient, p, "specSnipe", { faction = "guard", count = Outsiders.ESCORT_SNIPE, minutes = 60,
                                              radius = Spec and Spec.SNIPE_RADIUS or 30,
                                              sound = Spec and Spec.SNIPE_SOUND and Spec.SNIPE_SOUND.guard or nil })
    end
    log("outsider escort", job.key, sent and "alife" or "snipe")
    return true
end

-- ---------------------------------------------------------------- 오델: 주문·귀중품 수집

-- 주문 값의 배율: 가치의 2배, 케이시가 터 온 새 거래 길(Crises.lua E15)이 있으면 그 3/4
function Outsiders.orderPrice()
    local Cr = StoryEngine.Crises
    return Outsiders.ORDER_PRICE * (Cr and Cr.orderMult() or 1)
end

local function orderCount()
    return Outsiders.sided("odell") and 2 or 1
end

-- 거래 목록 창(TradeCatalogWindow)이 그대로 그리는 모양 (Trade.options 와 같다). 묶음 하나 = 물건 하나
function Outsiders.orderOptions(ps)
    local key = ps and ps.key or nil
    local st = Outsiders.status("odell", 1, key)
    local out = { faction = "odell", trust = trustOf("odell"), need = Outsiders.SPEC_TRUST[1], items = {},
                  allowed = st.ok, reason = (not st.ok) and st.why or nil, wait = st.wait, order = true,
                  wants = Value.CATEGORIES }
    local n = orderCount()
    for _, cat in ipairs(Value.CATEGORIES) do
        local pool = StoryEngine.ItemPool.tradePool(cat)
        local row = { category = cat, maxTier = st.ok and 5 or 0, needs = {}, tiers = {} }
        local any = false
        for t = 1, 5 do
            row.needs[t] = Outsiders.SPEC_TRUST[1]
            local bundles = {}
            local list = {}
            for _, ft in ipairs(pool[t] or {}) do list[#list + 1] = ft end
            table.sort(list)
            for i = 1, math.min(#list, Outsiders.ORDER_SHOWN) do
                local ft = list[i]
                bundles[#bundles + 1] = { items = { { ft, n } }, ft = ft,
                                          price = math.ceil(Value.of(ft) * n * Outsiders.orderPrice()) }
                any = true
            end
            row.tiers[t] = bundles
        end
        if any then out.items[#out.items + 1] = row end
    end
    return out
end

-- 주문: 그 물건을 가치의 2배 값에, 아무 품목이나 대가로
function Outsiders.order(player, category, tier, index)
    if not Outsiders.enabled() then return false, "closed" end
    if not Factions.canTalk(player) then return false, "no_radio" end
    local ps = Store.player(player)
    local now = Sensor.now()
    local st = Outsiders.status("odell", 1, ps.key, now.t)
    if not st.ok then return false, st.why, st.wait end
    if Quests.openTrade and Quests.openTrade("odell", ps.key) then return false, "open_deal" end
    tier = math.max(1, math.min(5, math.floor(tonumber(tier) or 1)))
    local list = {}
    for _, ft in ipairs((StoryEngine.ItemPool.tradePool(tostring(category or ""))[tier]) or {}) do list[#list + 1] = ft end
    table.sort(list)
    local ft = list[math.floor(tonumber(index) or 0)]
    if not ft then return false, "no_item" end
    local goods = {}
    for _ = 1, orderCount() do goods[#goods + 1] = ft end
    local q = Quests.proposeTrade(ps, "odell", { tier = tier, category = category, goods = goods, payCategory = "any",
                                                 price = math.ceil(Value.sum(goods) * Outsiders.orderPrice()) }, now)
    if not q then return false, "no_item" end
    q.order = true
    local o = state().here.odell
    o.used[ps.key] = o.used[ps.key] or {}
    o.used[ps.key][1] = now.t
    Outsiders.pay("odell", ps)
    pcall(Radio.react, "odell", "event", ps.name .. " just ordered " .. tostring(ft) .. " from your barges. You can get it; the price "
        .. "is double what it is worth and you take anything in trade. Confirm the order like a river trader.",
        StoryEngine.Lines.fallback("odell", "out_spec", "It is done."), ps)
    log("outsider order", ft, "by", ps.name)
    return true, q
end

local JEWEL_PREFIX = { "Ring_", "Necklace_", "NecklaceLong_", "Necklace_Choker", "Earring_", "Bracelet_", "NoseRing_",
                       "NoseStud_", "BellyButton_" }
local JEWEL_NOT = { "DogTag", "YingYang", "Crucifix", "Cross" }
local JEWEL_GEMS = { { "Diamond", 8 }, { "Ruby", 6 }, { "Emerald", 6 }, { "Sapphire", 6 }, { "Pearl", 4 } }

-- 장신구의 값 (화폐 장수). 장신구가 아니면 nil
function Outsiders.jewelValue(fullType)
    local name = tostring(fullType):gsub("^.-%.", "")
    local is = false
    for _, p in ipairs(JEWEL_PREFIX) do
        if name:sub(1, #p) == p then is = true end
    end
    if not is then return nil end
    for _, w in ipairs(JEWEL_NOT) do
        if name:find(w, 1, true) then return nil end
    end
    local v = 1
    if name:find("Gold", 1, true) then v = 4 elseif name:find("Silver", 1, true) then v = 2 end
    for _, g in ipairs(JEWEL_GEMS) do
        if name:find(g[1], 1, true) then v = v + g[2] end
    end
    return v
end

function HANDLERS.jewels(player, ps, id, args, now)
    local cap = Outsiders.sided("odell") and Outsiders.JEWEL_CAP_SIDED or Outsiders.JEWEL_CAP
    local found = {}
    local list = player:getInventory():getAllEvalRecurse(function(item)
        if StoryEngine.Value.questLock(item) then return false end
        if player:isEquippedClothing(item) then return false end
        return Outsiders.jewelValue(item:getFullType()) ~= nil
    end)
    for i = 0, list:size() - 1 do
        local it = list:get(i)
        found[#found + 1] = { item = it, v = Outsiders.jewelValue(it:getFullType()) }
    end
    table.sort(found, function(a, b) return a.v > b.v end)
    local total, taken = 0, 0
    for _, f in ipairs(found) do
        if total + f.v <= cap then
            StoryEngine.Items.remove(f.item, player)
            total, taken = total + f.v, taken + 1
        end
    end
    if taken == 0 then return false, "no_jewels" end
    for _ = 1, total do StoryEngine.Items.addTo(player:getInventory(), Outsiders.SCRIP) end
    return true, { info = { scrip = total, taken = taken },
                   note = "bought " .. StoryEngine.intToString(taken) .. " pieces of jewellery from " .. ps.name .. " for river scrip",
                   topic = ps.name .. " just handed your crew " .. StoryEngine.intToString(taken) .. " pieces of jewellery and you "
                       .. "paid them " .. StoryEngine.intToString(total) .. " in your river scrip, which the others in the county "
                       .. "will take for anything. Say so, pleased with the deal." }
end

-- ---------------------------------------------------------------- 오카포: 지연제·체질 관리

local function infected(player)
    local ok, yes = pcall(function()
        local bd = player:getBodyDamage()
        return bd:IsInfected() or bd:isInfected()
    end)
    if ok and yes then return true end
    local ok2, yes2 = pcall(function() return player:getBodyDamage():isInfected() end)
    return ok2 and yes2 == true
end

local function bitten(player)
    local ok, yes = pcall(function()
        local parts = player:getBodyDamage():getBodyParts()
        for i = 0, parts:size() - 1 do
            if parts:get(i):bitten() then return true end
        end
        return false
    end)
    return ok and yes == true
end

-- E11: 물리지 않고 긁힘·찢긴 상처로 옮은 감염은 고친다
local function cure(player)
    pcall(function()
        local bd = player:getBodyDamage()
        bd:setInfected(false)
        bd:setInfectionLevel(0)
        bd:setInfectionTime(-1)
        bd:setInfectionMortalityDuration(-1)
        local parts = bd:getBodyParts()
        for i = 0, parts:size() - 1 do
            local bp = parts:get(i)
            bp:SetInfected(false)
            pcall(function() syncBodyPart(bp, 0xFFFFFFFF) end)
        end
    end)
end

function HANDLERS.retard(player, ps, id, args, now)
    if not infected(player) then return false, "not_infected" end
    local cured = Outsiders.sided("okafor") and not bitten(player)
    if cured then
        cure(player)
        pcall(Net.toClient, player, "outsiderFx", { kind = "retard", minutes = 0, cure = true })
        return true, { info = { cured = true }, note = "cured the infection " .. ps.name .. " had caught from a scratch",
                       topic = "Your serum worked on " .. ps.name .. ": the infection came from a scratch, not a bite, and it is "
                           .. "gone. Say so, clinical and a little proud." }
    end
    addFx({ kind = "retard", key = ps.key, oid = id, untilT = now.t + Outsiders.RETARD_DAYS * 24 * 60 }, player)
    return true, { note = "gave " .. ps.name .. " a retardant that holds the infection still for a week",
                   topic = "You just sent " .. ps.name .. " a dose of your retardant. It does not cure the bite; it holds the "
                       .. "infection still for seven days, and they will need another dose before it runs out. Say that plainly." }
end

function HANDLERS.regimen(player, ps, id, args, now)
    if fxOf("regimen", ps.key, now.t) then return false, "active" end
    addFx({ kind = "regimen", key = ps.key, oid = id, untilT = now.t + Outsiders.REGIMEN_DAYS * 24 * 60 }, player)
    return true, { note = "put " .. ps.name .. " on a regimen that halves hunger and thirst for five days",
                   topic = "You just put " .. ps.name .. " on your metabolic regimen: for five days they will need half the food "
                       .. "and water, and their weight will settle. Explain it briefly." }
end

-- ---------------------------------------------------------------- 아비게일: 기적·짐을 든 자

function HANDLERS.miracle(player, ps, id, args, now)
    state().armed[ps.key] = now.t
    pcall(Net.toClient, player, "outsiderFx", { kind = "armed", minutes = 60 * 24 * 365 })
    return true, { later = true, note = "prayed over " .. ps.name,
                   topic = "You just prayed over " .. ps.name .. " on the radio: when death is closest to them, they will be "
                       .. "given one more chance. Say it as a blessing, not a promise." }
end

-- 체력이 바닥에 닿았다 (클라이언트가 알린다): 기적이 일어난다
function Outsiders.miracle(player)
    local s = state()
    local ps = Store.player(player)
    if not s.armed[ps.key] or not s.here.abigail then return false, "not_armed" end
    local now = Sensor.now()
    s.armed[ps.key] = nil
    local o = s.here.abigail
    o.used[ps.key] = o.used[ps.key] or {}
    o.used[ps.key][1] = now.t                 -- 대기는 발동한 뒤부터
    addFx({ kind = "miracle", key = ps.key, oid = "abigail", untilT = now.t + Outsiders.MIRACLE_MIN,
            radius = Outsiders.MIRACLE_RADIUS }, player)
    -- 먼 곳의 소리로 둘레의 좀비를 끌어낸다
    pcall(function()
        local ang = ZombRand(360) * math.pi / 180
        local x, y = math.floor(player:getX() + math.cos(ang) * 40), math.floor(player:getY() + math.sin(ang) * 40)
        addSound(nil, x, y, 0, 60, 60)
    end)
    pcall(Radio.react, "abigail", "event", ps.name .. " was a breath from death just now and something held the dead back from "
        .. "them. You felt it. Say a few quiet words to them.", StoryEngine.Lines.fallback("abigail", "out_spec", "It is done."),
        ps, { overhead = true })
    Store.addNote(ps, { kind = "op", text = "At the edge of death " .. ps.name .. " was spared: the dead fell back and the bleeding "
        .. "stopped, as Mother Abigail had prayed.", clock = now.clock })
    log("outsider miracle", ps.name)
    return true
end

function HANDLERS.burden(player, ps, id, args, now)
    if fxOf("burden", ps.key, now.t) then return false, "active" end
    local days = Outsiders.sided("abigail") and Outsiders.BURDEN_DAYS_SIDED or Outsiders.BURDEN_DAYS
    addFx({ kind = "burden", key = ps.key, oid = id, untilT = now.t + days * 24 * 60 }, player)
    return true, { note = "blessed " .. ps.name .. " to carry twice the load for a while",
                   topic = "You just blessed " .. ps.name .. " as a bearer of burdens: for " .. StoryEngine.intToString(days)
                       .. " days they will carry twice what they could. Say it as a blessing." }
end

-- 매분: 기적의 출혈 멈춤·통증 없음, 지연제 (서버가 아는 몸에도 적용)
local function fxMinute(now)
    local s = state()
    for i = #s.fx, 1, -1 do
        local f = s.fx[i]
        if now.t >= f.untilT then
            table.remove(s.fx, i)
        else
            local p = playerByKey(f.key)
            if p and not p:isDead() and f.kind == "miracle" then
                pcall(function()
                    local parts = p:getBodyDamage():getBodyParts()
                    for k = 0, parts:size() - 1 do
                        local bp = parts:get(k)
                        if bp:getBleedingTime() > 0 then
                            bp:setBleedingTime(0)
                            pcall(function() syncBodyPart(bp, 0xFFFFFFFF) end)
                        end
                    end
                    p:getStats():set(CharacterStat.PAIN, 0)
                end)
            end
        end
    end
end

-- ---------------------------------------------------------------- 선물

-- 물자 지원처럼 사흘 통으로 신뢰만 오른다 (자원은 없다). 반환: true, { trust, value } | false, 이유
function Outsiders.gift(player, id, itemIds)
    if not Outsiders.enabled() then return false, "closed" end
    local s = state()
    local o = s.here[id]
    if not o then return false, "gone" end
    if not Factions.canTalk(player) then return false, "no_radio" end
    local now = Sensor.now()
    local ps = Store.player(player)
    local inv = player:getInventory()
    local chosen, seen, total = {}, {}, 0
    for _, v in ipairs(itemIds or {}) do
        local n = math.floor(tonumber(v) or -1)
        if not seen[n] then
            seen[n] = true
            local item = inv:getItemWithIDRecursiv(n)
            if item and Outsiders.giftable(player, item) then
                chosen[#chosen + 1] = item
                total = total + Value.itemValue(item)
            end
        end
    end
    if #chosen == 0 or total <= 0 then return false, "nothing" end
    if not o.gift or now.t - o.gift.t >= Outsiders.GIFT_DAYS * 24 * 60 then o.gift = { t = now.t, value = 0, trust = 0 } end
    local top = Outsiders.GIFT_STEPS[#Outsiders.GIFT_STEPS][2]
    if o.gift.trust >= top then return false, "wait", Outsiders.GIFT_DAYS * 24 * 60 - (now.t - o.gift.t) end
    for _, item in ipairs(chosen) do StoryEngine.Items.remove(item, player) end
    o.gift.value = o.gift.value + total
    local step = 0
    for _, row in ipairs(Outsiders.GIFT_STEPS) do
        if o.gift.value >= row[1] then step = row[2] end
    end
    local gain = 0
    if step > o.gift.trust then
        gain = StoryEngine.Trust.apply(id, step - o.gift.trust, "gift_given", nil, ps.key)
        o.gift.trust = step
        StoryEngine.Trust.deed(id, ps.key)
        pcall(Radio.react, id, "event", ps.name .. " just sent your people a gift of supplies. Thank them in your own way.",
            StoryEngine.Lines.fallback(id, "out_gift", "Thank you. My people will remember it."), ps)
    end
    log("outsider gift", id, total, "trust", gain, "by", ps.name)
    return true, { trust = gain, value = total }
end

function Outsiders.giftable(player, item)
    return Value.giftable(player, item)
end

function Outsiders.giftStatus(id, now)
    local o = state().here[id]
    if not o then return nil end
    local g = o.gift
    if not g or now - g.t >= Outsiders.GIFT_DAYS * 24 * 60 then return { value = 0, trust = 0 } end
    return { value = g.value, trust = g.trust, left = Outsiders.GIFT_DAYS * 24 * 60 - (now - g.t) }
end

-- ---------------------------------------------------------------- 날마다·시간마다

local function openQuestOf(id)
    for _, q in pairs(Store.data().quests or {}) do
        if q.origin and q.origin.faction == id and (q.state == "proposed" or Quests.isActive(q)) and q.kind ~= "supply_drop" then
            return q
        end
    end
    return nil
end

local function ask(id, o, now)
    local players = Sensor.players()
    if #players == 0 or openQuestOf(id) then return end
    local p = players[ZombRand(#players) + 1]
    local tier = 3 + ZombRand(2)
    local q = Quests.propose(p, Store.player(p), id, tier, now)
    o.askT = now.t + randDays(Outsiders.ASK_MIN_DAYS, Outsiders.ASK_MAX_DAYS)
    if q then log("outsider request", id, q.id) end
end

local function raid(now)
    local s = state()
    if not Outsiders.sided("odell") or baseGone("rats") then return end
    if s.raidT and now.t - s.raidT < Outsiders.RAID_DAYS * 24 * 60 then return end
    s.raidT = now.t
    local pool = {}
    for _, f in ipairs(Factions.list) do
        if f.id ~= "rats" and not baseGone(f.id) then pool[#pool + 1] = f.id end
    end
    if #pool == 0 then return end
    local victim = pool[ZombRand(#pool) + 1]
    local Life = StoryEngine.Life
    if Life then
        for _, res in ipairs({ "food", "medical", "safety", "morale" }) do
            pcall(Life.change, victim, res, -Outsiders.RAID_LOSS, "raid")
        end
    end
    local text = "Vic's crew, cut out of the river trade, raided " .. nameOf(victim) .. " and took what they could carry."
    if StoryEngine.Social and StoryEngine.Social.news then StoryEngine.Social.news("all", text) end
    notify("raid", { victim = victim })
    log("outsider raid by rats on", victim)
end

function Outsiders.daily(now, prevDay)
    local s = state()
    for _, id in ipairs(Outsiders.hereList()) do
        local o = s.here[id]
        local ch = Radio.channel(id)
        -- 힘든 쪽: 일을 해 주지 않은 날이 이틀 쌓일 때마다 -1
        if ch.deedDay and prevDay and ch.deedDay >= prevDay then
            o.idle = 0
        else
            o.idle = (o.idle or 0) + 1
            if o.hard and o.idle % Outsiders.HARD_EVERY == 0 then StoryEngine.Trust.apply(id, -1, "out_cold") end
        end
        -- 떠남
        if trustOf(id) < Outsiders.LEAVE_TRUST then
            o.low = (o.low or 0) + 1
            if o.low >= Outsiders.LEAVE_DAYS then Outsiders.leave(id, "left", now) end
        else
            o.low = 0
        end
    end
    pcall(raid, now)
end

function Outsiders.tick(now)
    now = now or Sensor.now()
    if not Outsiders.enabled() then return end
    local s = state()
    local Pol = StoryEngine.Politics
    local ps = Pol.state()
    syncPresent()
    if not s.queue then s.queue = shuffled() end
    s.nextT = s.nextT or ((ps.openT or now.t) + Outsiders.FIRST_DAYS * 24 * 60)
    if #Sensor.players() == 0 then return end
    local day = Store.dayIndex(now.dayKey)
    if s.day ~= day then
        local prev = s.day
        s.day = day
        if prev then
            local ok, err = pcall(Outsiders.daily, now, prev)
            if not ok then log("outsider daily error:", tostring(err)) end
        end
    end
    -- 다음 무리
    if not s.pending and #s.queue > 0 and now.t >= s.nextT and not ps.bill then
        local id = table.remove(s.queue, 1)
        if not Outsiders.arrive(id, now) then table.insert(s.queue, 1, id) end
    end
    for _, id in ipairs(Outsiders.hereList()) do
        local o = s.here[id]
        if o.test and now.t >= o.test.untilT then
            testIgnored(id, now)
        elseif not o.test and not o.sided and o.testT and now.t >= o.testT then
            local busy = false
            for _, other in ipairs(Outsiders.hereList()) do
                if s.here[other].test then busy = true end
            end
            if not busy then openTest(id, now) end
        end
        if o.askT and now.t >= o.askT then
            local ok, err = pcall(ask, id, o, now)
            if not ok then log("outsider ask error:", tostring(err)) end
        end
        -- 추방 재투표 (E14): 꺼리는 NPC 셋이 모두 등을 돌렸다
        local turned, alive = 0, 0
        for _, fid in ipairs(Outsiders.DEFS[id].dislike) do
            if not baseGone(fid) then
                alive = alive + 1
                if trustOf(fid) < Outsiders.ABSENT_TRUST then turned = turned + 1 end
            end
        end
        if alive >= 2 and turned >= alive and not ps.bill
            and (not o.expelT or now.t - o.expelT >= Outsiders.EXPEL_COOLDOWN_DAYS * 24 * 60) then
            o.expelT = now.t
            openExpel(id, now)
        end
    end
end

local function minute()
    local s = Store.data().outsiders
    if not s then return end
    local now = Sensor.now()
    if #(s.fx or {}) > 0 then pcall(fxMinute, now) end
    local jobs = s.jobs or {}
    for i = #jobs, 1, -1 do
        local job = jobs[i]
        if now.t >= job.dueT then
            local ok, done = pcall(job.kind == "airdrop" and runAirdrop or runEscort, job, now)
            if not ok or done then table.remove(jobs, i) end
        end
    end
    s.resendT = s.resendT or now.t
    if now.t - s.resendT >= 10 then
        s.resendT = now.t
        for _, p in ipairs(Sensor.players()) do pcall(Outsiders.resend, p) end
    end
end

-- ---------------------------------------------------------------- 클라이언트·AI 로

function Outsiders.payload(key, now)
    local s = Store.data().outsiders
    if not s or not Outsiders.enabled() then return nil end
    now = now or Sensor.now()
    local Pol = StoryEngine.Politics
    local bill = Pol.state().bill
    local out = { list = {}, pending = s.pending }
    for _, id in ipairs(Outsiders.hereList()) do
        local o = s.here[id]
        local row = { id = id, trust = trustOf(id), hard = o.hard or nil, sided = o.sided, days = Store.serverDays() - (o.day or 0),
                      low = (o.low or 0) > 0 and o.low or nil, rival = Outsiders.DEFS[id].rival,
                      dislike = Outsiders.DEFS[id].dislike, spec = {}, gift = Outsiders.giftStatus(id, now.t),
                      armed = (id == "abigail" and key and s.armed[key]) and true or nil }
        for n = 1, 2 do row.spec[n] = Outsiders.status(id, n, key, now.t) end
        if o.test then row.test = { hours = math.max(0, math.ceil((o.test.untilT - now.t) / 60)), rival = o.test.rival } end
        if bill and bill.id == "expel" and bill.target == id then row.expel = { stance = bill.stance or "abstain" } end
        local Work = StoryEngine.Work
        if Work and Work.volunteerStatus then
            local ok, v = pcall(Work.volunteerStatus, id, key)
            if ok then row.volunteer = v end
        end
        out.list[#out.list + 1] = row
    end
    if key then out.jobs = Outsiders.proxyList(key) end
    return out
end

-- 무전 요청에 넣는 맥락 (브릿지 format_outsiders)
function Outsiders.context(fid)
    if not Outsiders.enabled() then return nil end
    local s = state()
    local here = Outsiders.hereList()
    if #here == 0 and not s.pending then return nil end
    local out = { here = {}, pending = s.pending and nameOf(s.pending) or nil }
    for _, id in ipairs(here) do
        local o = s.here[id]
        out.here[#out.here + 1] = { id = id, name = nameOf(id), who = Outsiders.DEFS[id].who, trust = trustOf(id),
                                    disliked = has(Outsiders.DEFS[id].dislike, fid) or nil,
                                    rival = Outsiders.DEFS[id].rival == fid or nil, sided = o.sided }
    end
    local def = Outsiders.DEFS[fid]
    if def then
        local o = s.here[fid]
        out.self = { who = def.who, rival = nameOf(def.rival), hard = o and o.hard or nil, sided = o and o.sided or nil, dislike = {} }
        for _, d in ipairs(def.dislike) do out.self.dislike[#out.self.dislike + 1] = nameOf(d) end
    end
    return out
end

-- 누가 왔고 어떻게 됐는가 (두 번째 연대기): { { id, name, state = here|left|expelled|refused, sided } }
function Outsiders.history()
    local s = Store.data().outsiders
    local out = {}
    if not s then return out end
    for _, id in ipairs(Outsiders.ORDER) do
        local o = s.here and s.here[id]
        local l = s.left and s.left[id]
        if o then
            out[#out + 1] = { id = id, name = nameOf(id), state = "here", sided = o.sided, rival = nameOf(Outsiders.DEFS[id].rival) }
        elseif l and l.why ~= "debug" then
            out[#out + 1] = { id = id, name = nameOf(id), state = l.why == "expelled" and "expelled" or (l.why == "refused" and "refused" or "left") }
        end
    end
    return out
end

function Outsiders.debug(args, player)
    local s = state()
    local now = Sensor.now()
    local what = tostring(args.what or "")
    local id = tostring(args.id or "")
    if what == "arrive" then
        if not Outsiders.DEFS[id] or s.here[id] then return "outsider: bad id or already here" end
        s.queue = s.queue or shuffled()
        for i = #s.queue, 1, -1 do
            if s.queue[i] == id then table.remove(s.queue, i) end
        end
        if s.pending then
            local Pol = StoryEngine.Politics
            if Pol.state().bill and Pol.state().bill.id == "admit" then Pol.state().bill = nil end
            s.pending = nil
        end
        admit(id, now)
    elseif what == "leave" then
        Outsiders.leave(id, "debug", now)
    elseif what == "trust" and s.here[id] then
        Radio.channel(id).trust = math.max(0, math.min(100, math.floor(tonumber(args.v) or 70)))
    elseif what == "test" and s.here[id] then
        s.here[id].sided, s.here[id].hard = nil, nil
        openTest(id, now)
    elseif what == "expel" and s.here[id] then
        openExpel(id, now)
    elseif what == "ready" and s.here[id] then
        s.here[id].used = {}
        s.here[id].gift = nil
    elseif what == "reset" then
        for _, x in ipairs(Outsiders.hereList()) do Outsiders.leave(x, "debug", now) end
        Store.data().outsiders = nil
        Outsiders.broadcast()
    end
    return Outsiders.statusText()
end

function Outsiders.statusText()
    local s = Store.data().outsiders
    if not s then return "outsiders -" end
    local parts = {}
    for _, id in ipairs(Outsiders.ORDER) do
        local o = s.here and s.here[id]
        if o then
            parts[#parts + 1] = id .. "=" .. StoryEngine.intToString(trustOf(id)) .. (o.hard and "(hard)" or "")
                .. (o.sided and (":" .. o.sided) or "") .. (o.test and ":test" or "")
        end
    end
    local now = Sensor.now()
    local nextIn = s.nextT and math.floor((s.nextT - now.t) / (24 * 60)) or nil
    return "outsiders " .. (#parts > 0 and table.concat(parts, " ") or "none") .. " pending=" .. tostring(s.pending)
        .. " queue=" .. table.concat(s.queue or {}, ",") .. " next=" .. tostring(nextIn) .. "d"
end

Events.EveryHours.Add(function()
    local ok, err = pcall(Outsiders.tick)
    if not ok then log("outsider tick error:", tostring(err)) end
end)
Events.EveryOneMinute.Add(function()
    local ok, err = pcall(minute)
    if not ok then log("outsider minute error:", tostring(err)) end
end)

return Outsiders
