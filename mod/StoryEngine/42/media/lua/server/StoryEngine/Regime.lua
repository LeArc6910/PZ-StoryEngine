-- 의회의 정치, 그 뒤 (2026-10-13, docs/PLAN_COUNCIL_POLITICS.md 10단계와 6단계의 나머지).
--
--   연립     NPC 의장이 서면 의장의 파벌과, 그 파벌과 사이가 가장 좋은 파벌이 다수파가 된다 (사이 평균이 0 이상일 때만,
--            의장의 파벌이 혼자 과반이면 혼자). 다수파가 낸 법안은 다수파 사람들의 찬성 기준이 PARTNER_NEED 만큼 내려가고,
--            다수파 밖에서 낸 법안은 OPPOSE_NEED 만큼 오른다. 두 파벌 사이 평균이 COLLAPSE_DAYS 날 내리 음수면 무너진다:
--            다수파가 통과시킨 법안이 모두 멈추고 의장 불신임이 올라온다. REFORM_DAYS 뒤 다시 짠다.
--            플레이어: 중재(Regime.mend, 두 파벌 대표를 모두 MEND_TRUST 이상 믿게 했을 때 가장 나쁜 사이 +1)와
--            이간(Regime.wedge, 다수파 한 사람의 약점을 상대 파벌에 흘림: 그 파벌 사람들이 그 사람을 -2).
--   불신임   의회의 표결 "noconf" (Politics.systemBill, owner = regime). 다수파가 무너지면 저절로, 또는 플레이어가
--            NOCONF_DAYS 에 한 번 (Regime.noConfidence). 통과하면 의장이 물러나고 하루 뒤 선거.
--   분열     국면 판정 때 지난 국면 동안 다수파가 SPLIT_COLLAPSES 번 무너졌거나 갈라서는 의회(E3)를 풀지 못했으면 의회가 둘이 된다.
--            법안·선거가 멈춘다. 한쪽 사람의 부탁을 해 주면 다른 쪽 대표가 -1 (주에 SPLIT_RIVAL_WEEK 까지).
--            한쪽은 전기를, 다른 쪽은 수도를 쥔다: 그쪽 사람들의 신뢰 평균이 SPLIT_CUT_TRUST 밑이면 끊고 SPLIT_BACK_TRUST 이상이면 잇는다.
--            벗어나는 길: 두 번째 카운티 회의 (Regime.reunite: 양쪽 대표의 큰 부탁을 모두 해낸다).
--   군정     총 파벌이 힘을 쥐었고(다수파이거나 독주이거나 가장 무거움) 30일 안에 의장이 불신임으로 물러났으며 큰 사건이 진행 중이면
--            휘태커(헤일 대령이 와 있으면 헤일)가 의회를 닫는다. 법안·선거가 없고 주마다 명령(징발·소탕)이 온다.
--            따르면 방위대 특기를 대기 없이(Regime.backed), 어기면 신뢰 -5 와 협박. 총 파벌이 아닌 사람들과의 거래는 값이 오른다.
--            MARTIAL_SETTLE 번 따르면 굳는다 (명령이 2주에 한 번). 끝내는 길: 청원 (Regime.petition, 나머지 NPC 과반이 PETITION_TRUST 이상).
--   시설     큰 사건 facility (Saga.lua) 의 결과. 지키면 그때 제안을 받은 파벌이 그 시설을 쥔다 (국면 판정의 무게 +1),
--            못 지키면 FACILITY_DOWN_DAYS 동안 고장.
--   증언     큰 사건이 끝난 뒤 TESTIFY_HOURS 동안 한 파벌의 말에 힘을 실어 준다 (Regime.testify): 그 파벌의 공 +1, 기울기 +5,
--            사건 때 제안을 받았던 다른 파벌의 대표는 -2.
--
-- 상태: d.politics.regime = { coalition, reformT, collapses, e3, noconfT, noconfDue, martial, blame, facility = { held, down }, reunions }
-- 국면은 d.politics.phase (kind = split | martial 이 여기서 온다).

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Radio"
require "StoryEngine/Trust"
require "StoryEngine/Quests"
require "StoryEngine/Stories"
require "StoryEngine/Politics"

local Regime = {}
StoryEngine.Regime = Regime

local Net = StoryEngine.Net
local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Radio = StoryEngine.Radio
local Quests = StoryEngine.Quests
local Stories = StoryEngine.Stories
local Politics = StoryEngine.Politics
local log = StoryEngine.log

Regime.COLLAPSE_DAYS = 3
Regime.REFORM_DAYS = 7
Regime.PARTNER_NEED = 10
Regime.OPPOSE_NEED = 5
Regime.MEND_TRUST = 60
Regime.MEND_DAYS = 14
Regime.WEDGE_BOND = 2
Regime.NOCONF_DAYS = 30
Regime.NOCONF_FAIL = 10
Regime.NOCONF_OUST = 5
Regime.IMPEACH_MEMORY_DAYS = 30
Regime.SPLIT_COLLAPSES = 2
Regime.SPLIT_CUT_TRUST, Regime.SPLIT_BACK_TRUST = 35, 45
Regime.SPLIT_RIVAL_COST, Regime.SPLIT_RIVAL_WEEK = 1, 3
Regime.SPLIT_SCENE_DAYS = 3
Regime.REUNITE_TIER = 4
Regime.REUNITE_DAYS = 7
Regime.REUNITE_RETRY_DAYS = 14
Regime.REUNITE_GAIN, Regime.REUNITE_FAIL = 3, 5
Regime.MARTIAL_ORDER_DAYS = 7
Regime.MARTIAL_SETTLED_DAYS = 14
Regime.MARTIAL_TIER = 3
Regime.MARTIAL_DEFY = 5
Regime.MARTIAL_OBEY = 2
Regime.MARTIAL_BACK_DAYS = 7
Regime.MARTIAL_PRICE = 1.15
Regime.MARTIAL_SETTLE = 4
Regime.PETITION_TRUST = 60
Regime.PETITION_COST = 10
Regime.FACILITY_DOWN_DAYS = 30
Regime.TESTIFY_HOURS = 48
Regime.TESTIFY_LEAN = 5
Regime.TESTIFY_COST = 2

local NPC_ASKS = { deliver = true, horde = true, fetch = true, named = true }

-- ---------------------------------------------------------------- 상태와 공통

local function state()
    local s = Politics.state()
    s.regime = s.regime or {}
    local r = s.regime
    r.facility = r.facility or {}
    r.facility.held = r.facility.held or {}
    r.facility.down = r.facility.down or {}
    return r
end

-- 만들지 않고 본다 (정치가 안 열렸으면 nil)
local function peek()
    local s = Store.data().politics
    if not s or not s.openT or not Politics.enabled() then return nil end
    return s.regime
end

function Regime.state() return state() end

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

local function nameOf(fid) return tostring(Stories.NAMES[fid] or (Factions.byId[fid] and Factions.byId[fid].name) or fid) end
local function trustOf(fid) return Radio.channel(fid).trust or 0 end

local function notify(kind, args)
    args = args or {}
    args.kind = kind
    pcall(Net.toAll, "politicsNotice", args)
end

local function news(text, now)
    if StoryEngine.Social and StoryEngine.Social.news then pcall(StoryEngine.Social.news, "all", text) end
    for _, ps in pairs(Store.data().players) do
        if not ps.dead then Store.addNote(ps, { kind = "op", text = text, clock = now.clock }) end
    end
end

local function trust(fid, d, reason, src)
    local Trust = StoryEngine.Trust
    if Trust and fid and not Factions.isGone(fid) and d ~= 0 then
        return Trust.apply(fid, d, reason, nil, nil, src)
    end
    return 0
end

local function sideNames(blocs)
    local out = {}
    for _, b in ipairs(blocs or {}) do out[#out + 1] = tostring(Politics.SIDE[b] or b) end
    return table.concat(out, " and ")
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

-- 두 파벌 사람들 사이의 마음 평균 (양쪽 방향). 한쪽이 비었으면 nil
local function cohesion(a, b)
    local Bonds = StoryEngine.Bonds
    local sum, n = 0, 0
    for _, x in ipairs(Politics.members(a)) do
        for _, y in ipairs(Politics.members(b)) do
            sum = sum + (Bonds and (Bonds.get(x, y) + Bonds.get(y, x)) or 0)
            n = n + 2
        end
    end
    if n == 0 then return nil end
    return sum / n
end
Regime.cohesion = cohesion

-- 그 파벌들에서 우리를 가장 믿는 사람
local function leaderOf(blocs)
    local best, top = nil, -1
    for _, b in ipairs(blocs or {}) do
        for _, fid in ipairs(Politics.members(b)) do
            if trustOf(fid) > top then best, top = fid, trustOf(fid) end
        end
    end
    return best
end

local function phase()
    local s = Store.data().politics
    return s and s.openT and s.phase or nil
end

-- 의회가 닫혔는가: "split" | "martial" | nil (Politics.tick 이 법안과 선거를 쉰다)
function Regime.closed()
    if not Politics.enabled() then return nil end
    local ph = phase()
    if ph and (ph.kind == "split" or ph.kind == "martial") then return ph.kind end
    return nil
end

-- ---------------------------------------------------------------- 전기·수도를 누가 막고 있는가

-- 시설 고장이나 갈라선 한쪽이 이것을 끊어 두었는가 (Crises 의 giveBack 이 묻는다)
function Regime.gridBlocked(kind)
    local r = peek()
    if not r then return false end
    local now = Sensor.now().t
    if r.facility and r.facility.down and r.facility.down[kind] and now < r.facility.down[kind] then return true end
    local ph = phase()
    if ph and ph.kind == "split" then
        for _, h in pairs(ph.halves or {}) do
            if h.hold == kind and h.cut then return true end
        end
    end
    return false
end

local function quietCut(kind)
    -- 단전·단수 사건(NPC 반응·일지)이 새로 나지 않게 이미 겪은 것으로 해 둔다
    local d = Store.data()
    d.world = d.world or {}
    d.world.done = d.world.done or {}
    if d.world.done[kind] == nil then d.world.done[kind] = -1 end
    if StoryEngine.Grid then pcall(StoryEngine.Grid.cut, kind, "regime") end
end

local function giveBack(kind)
    if Regime.gridBlocked(kind) then return false end
    local Cr = StoryEngine.Crises
    if Cr and Cr.holding and Cr.holding(kind) then return false end
    local Era = StoryEngine.Era
    if StoryEngine.Grid then pcall(StoryEngine.Grid.restore, kind, Era and Era.FOREVER_DAYS or 36500, "council") end
    return true
end

-- ---------------------------------------------------------------- 국면을 바로 바꾼다

function Regime.setPhase(kind, extra, now)
    local s = Politics.state()
    now = now or Sensor.now()
    local ph = { kind = kind, sinceT = now.t, day = Store.serverDays(), weights = Politics.weights(now) }
    for k, v in pairs(extra or {}) do ph[k] = v end
    s.phase = ph
    s.nextPhaseT = now.t + Politics.PHASE_DAYS * 24 * 60
    notify("phase", { phase = kind, bloc = ph.bloc, by = ph.by })
    log("regime phase", kind, tostring(ph.by or ph.bloc or ""))
    return ph
end

-- 의회를 닫는다: 걸린 법안(의회 스스로 올린 표결은 빼고)과 선거와 의장 자리를 비운다
local function shutCouncil()
    local s = Politics.state()
    if s.bill and not s.bill.system then s.bill = nil end
    s.election = nil
    s.chair = nil
    state().coalition = nil
end

local function reopenCouncil(now)
    local s = Politics.state()
    s.nextElectionT = now.t + 24 * 60
    s.nextBillT = now.t + 2 * 24 * 60
    state().reformT = nil
end

-- ---------------------------------------------------------------- 연립 (다수파)

function Regime.coalition()
    local r = peek()
    return r and r.coalition or nil
end

function Regime.formCoalition(now)
    local r = state()
    now = now or Sensor.now()
    local chair = Politics.chair()
    if not chair or chair.player or not chair.bloc or Regime.closed() then
        r.coalition = nil
        return nil
    end
    local lead = chair.bloc
    local blocs = { lead }
    if #Politics.members(lead) * 2 <= #living() then
        local best, top = nil, nil
        for _, b in ipairs(Politics.BLOCS) do
            if b ~= lead and #Politics.members(b) > 0 then
                local c = cohesion(lead, b)
                if c and c >= 0 and (top == nil or c > top) then best, top = b, c end
            end
        end
        if best then blocs[2] = best end
    end
    r.coalition = { blocs = blocs, sinceT = now.t, strain = 0, chairT = chair.sinceT }
    r.reformT = nil
    if #blocs == 2 then
        news("A majority has formed on the county council: " .. sideNames(blocs) .. " now vote together behind the chair, "
            .. nameOf(chair.fid) .. ".", now)
    end
    notify("coalition", { blocs = blocs })
    log("regime coalition", table.concat(blocs, "+"))
    return r.coalition
end

-- 표의 기준 보정 (Politics.need 가 더한다)
function Regime.need(bill, fid)
    local c = Regime.coalition()
    if not c or not bill.bloc or bill.system then return 0 end
    local mine = Politics.blocOf(fid)
    if not has(c.blocs, mine) then return 0 end
    if has(c.blocs, bill.bloc) then
        return mine ~= bill.bloc and -Regime.PARTNER_NEED or 0
    end
    return Regime.OPPOSE_NEED
end

local function openNoConfidence(now, who)
    local chair = Politics.chair()
    if not chair or not chair.fid or Factions.isGone(chair.fid) then return nil, "no_chair" end
    local c = state().coalition
    local gain, lose = {}, {}
    for _, fid in ipairs(living()) do
        local b = Politics.blocOf(fid)
        if b == chair.bloc then
            lose[#lose + 1] = fid
        elseif not (c and has(c.blocs, b)) then
            gain[#gain + 1] = fid
        end
    end
    local bill = Politics.systemBill("noconf", { target = chair.fid, owner = "regime", gain = gain, lose = lose,
        text = "a motion of no confidence in the chair, " .. nameOf(chair.fid) }, now)
    if not bill then return nil, "busy" end
    bill.who = who
    log("regime no-confidence opened", chair.fid, tostring(who or "auto"))
    return bill
end

-- 다수파가 무너진다. 반환: 무너졌는가
function Regime.collapse(now, why)
    local r = state()
    local c = r.coalition
    if not c then return false end
    now = now or Sensor.now()
    local s = Politics.state()
    local ended = {}
    for _, law in ipairs(s.laws or {}) do
        if law.bloc and has(c.blocs, law.bloc) then ended[#ended + 1] = law.id end
    end
    for _, id in ipairs(ended) do pcall(Politics.repeal, id, now, "collapse") end
    r.coalition = nil
    r.reformT = now.t + Regime.REFORM_DAYS * 24 * 60
    r.collapses = (r.collapses or 0) + 1
    r.collapsesAll = (r.collapsesAll or 0) + 1
    news("The majority on the county council has fallen apart: " .. sideNames(c.blocs) .. " are no longer voting together, "
        .. "and the measures they pushed through have lapsed.", now)
    notify("coalition_broken", { blocs = c.blocs, laws = #ended })
    local chair = Politics.chair()
    if chair and chair.fid then r.noconfDue = true end
    log("regime coalition broken", table.concat(c.blocs, "+"), tostring(why), "laws", #ended)
    return true
end

local function coalitionDaily(now)
    local r = state()
    if Regime.closed() then
        r.coalition = nil
        return
    end
    local chair = Politics.chair()
    local c = r.coalition
    -- 의장이 바뀌면 다수파도 새로 짠다
    if c and (not chair or chair.player or chair.sinceT ~= c.chairT) then
        r.coalition = nil
        c = nil
    end
    if not c then
        if chair and not chair.player and (not r.reformT or now.t >= r.reformT) then Regime.formCoalition(now) end
        return
    end
    if #c.blocs < 2 then return end
    local co = cohesion(c.blocs[1], c.blocs[2])
    if co == nil then
        r.coalition = nil
        return
    end
    c.cohesion = co
    if co < 0 then
        c.strain = (c.strain or 0) + 1
    else
        c.strain = math.max(0, (c.strain or 0) - 1)
    end
    if c.strain >= Regime.COLLAPSE_DAYS then Regime.collapse(now, "strain") end
end

-- 중재: 다수파 두 파벌의 대표가 모두 우리를 믿을 때, 둘 사이 가장 나쁜 마음을 한 칸 푼다
function Regime.mend(player)
    local r = peek()
    local c = r and r.coalition
    if not c or #c.blocs < 2 then return false, "no_coalition" end
    local now = Sensor.now()
    if r.mendT and now.t - r.mendT < Regime.MEND_DAYS * 24 * 60 then return false, "wait" end
    local la, lb = leaderOf({ c.blocs[1] }), leaderOf({ c.blocs[2] })
    if not la or not lb then return false, "no_coalition" end
    if trustOf(la) < Regime.MEND_TRUST or trustOf(lb) < Regime.MEND_TRUST then return false, "trust", Regime.MEND_TRUST end
    local Bonds = StoryEngine.Bonds
    if not Bonds then return false, "how" end
    local wx, wy, worst = nil, nil, nil
    for _, x in ipairs(Politics.members(c.blocs[1])) do
        for _, y in ipairs(Politics.members(c.blocs[2])) do
            local v = Bonds.get(x, y) + Bonds.get(y, x)
            if worst == nil or v < worst then wx, wy, worst = x, y, v end
        end
    end
    if not wx then return false, "no_coalition" end
    local ps = Store.player(player)
    Bonds.change(wx, wy, 1, tostring(ps.name) .. " sat them down and talked them round, for the sake of the council majority", true)
    c.strain = 0
    r.mendT = now.t
    notify("mend", { a = wx, b = wy, name = ps.name })
    log("regime mend", wx, wy, "by", ps.name)
    return true, wx, wy
end

-- 이간: 다수파 한 사람의 약점을 상대 파벌에 흘린다 (약점은 닳는다)
function Regime.wedge(player, fid)
    local r = peek()
    local c = r and r.coalition
    if not c or #c.blocs < 2 then return false, "no_coalition" end
    local mine = Politics.blocOf(fid)
    if not Factions.byId[fid] or Factions.isGone(fid) or not has(c.blocs, mine) then return false, "no_target" end
    local sec = Politics.secretOf(fid)
    if not sec then return false, "no_secret" end
    local Bonds = StoryEngine.Bonds
    if not Bonds then return false, "how" end
    local other = c.blocs[1] == mine and c.blocs[2] or c.blocs[1]
    local ps = Store.player(player)
    sec.used = true
    for _, y in ipairs(Politics.members(other)) do
        Bonds.change(y, fid, -Regime.WEDGE_BOND, "they were told what " .. nameOf(fid) .. " had been hiding from the council", false)
    end
    notify("wedge", { fid = fid, bloc = other, name = ps.name })
    log("regime wedge", fid, "told to", other, "by", ps.name)
    return true
end

-- ---------------------------------------------------------------- 불신임

function Regime.noConfidence(player)
    if not Politics.on() or Regime.closed() then return false, "closed" end
    local r = state()
    local now = Sensor.now()
    local ps = Store.player(player)
    if r.noconfT and now.t - r.noconfT < Regime.NOCONF_DAYS * 24 * 60 then return false, "wait" end
    local bill, why = openNoConfidence(now, ps.name)
    if not bill then return false, why end
    r.noconfT = now.t
    return true
end

-- Politics.vote 가 부른다 (owner = regime)
function Regime.onVote(bill, pass, now)
    if bill.id ~= "noconf" then return end
    local s = Politics.state()
    local r = state()
    local fid = bill.target
    if pass then
        if s.chair and s.chair.fid == fid then
            s.chair = nil
            s.nextElectionT = now.t + 24 * 60
        end
        s.impeachT = now.t
        r.noconfs = (r.noconfs or 0) + 1
        r.coalition = nil
        if bill.who then trust(fid, -Regime.NOCONF_OUST, "noconf_ousted") end
        news("The county council voted its chair, " .. nameOf(fid) .. ", out. A new chair will be chosen.", now)
        if not Factions.isGone(fid) then
            pcall(Radio.react, fid, "event", "The county council just voted you out of the chair. Say how you take it, briefly.",
                { text = "So that's how it is.", lt = { key = "IGUI_StoryEngine_Regime_Say_ousted" } }, nil)
        end
    elseif bill.who then
        trust(fid, -Regime.NOCONF_FAIL, "noconf_failed")
    end
    log("regime no-confidence", fid, pass and "passed" or "failed")
end

-- ---------------------------------------------------------------- 분열 (의회 둘)

local function halfOf(ph, fid)
    local b = Politics.blocOf(fid)
    for id, h in pairs(ph.halves or {}) do
        if has(h.blocs, b) then return id end
    end
    return nil
end

function Regime.halfOf(fid)
    local ph = phase()
    if not ph or ph.kind ~= "split" then return nil end
    return halfOf(ph, fid)
end

local function halfMembers(h)
    local out = {}
    for _, b in ipairs(h.blocs or {}) do
        for _, fid in ipairs(Politics.members(b)) do out[#out + 1] = fid end
    end
    return out
end

-- 어떻게 갈라서는가: 사이가 가장 나쁜 두 파벌이 양쪽의 중심이 되고, 남은 파벌은 사이가 나은 쪽에 붙는다
function Regime.splitHalves()
    local live = {}
    for _, b in ipairs(Politics.BLOCS) do
        if #Politics.members(b) > 0 then live[#live + 1] = b end
    end
    if #live < 2 then return nil end
    local x, y, worst = nil, nil, nil
    for i = 1, #live do
        for j = i + 1, #live do
            local c = cohesion(live[i], live[j]) or 0
            if worst == nil or c < worst then x, y, worst = live[i], live[j], c end
        end
    end
    local a, b = { blocs = { x } }, { blocs = { y } }
    for _, z in ipairs(live) do
        if z ~= x and z ~= y then
            local side = (cohesion(z, x) or 0) >= (cohesion(z, y) or 0) and a or b
            side.blocs[#side.blocs + 1] = z
        end
    end
    -- 총 파벌이 있는 쪽이 전기를, 다른 쪽이 수도를 쥔다
    if has(b.blocs, "gun") then a, b = b, a end
    a.hold, b.hold = "power", "water"
    return { a = a, b = b }
end

local function enterSplit(now, why)
    local halves = Regime.splitHalves()
    if not halves then return nil end
    shutCouncil()
    local ph = Regime.setPhase("split", { halves = halves, why = why }, now)
    news("The county council has broken in two and will not sit together: " .. sideNames(halves.a.blocs) .. " on one side, "
        .. sideNames(halves.b.blocs) .. " on the other. One side holds the power, the other the water. Nothing is voted on "
        .. "until someone brings them back to one table.", now)
    local la, lb = leaderOf(halves.a.blocs), leaderOf(halves.b.blocs)
    if la and lb and StoryEngine.Social and StoryEngine.Social.queueTopic then
        pcall(StoryEngine.Social.queueTopic, { la, lb }, "The county council has just broken in two. " .. nameOf(la) .. " and "
            .. nameOf(lb) .. " are on opposite sides and argue on the open channel over who walked out on whom.", "politics", nil)
    end
    return ph
end

local function leaveSplit(ph, now)
    for _, h in pairs(ph.halves or {}) do
        if h.cut then
            h.cut = false
            giveBack(h.hold)
        end
    end
end

-- Politics.judgePhase 가 부른다: 국면을 바꿔야 하면 새 국면, 아니면 nil
function Regime.overridePhase(computed, before, now)
    local r = state()
    if before and before.kind == "martial" and r.martial then
        before.weights = computed.weights
        return before
    end
    if before and before.kind == "split" then
        local alive = true
        for _, h in pairs(before.halves or {}) do
            if #halfMembers(h) == 0 then alive = false end
        end
        if alive then
            before.weights = computed.weights
            return before
        end
        leaveSplit(before, now)
        reopenCouncil(now)
    end
    local due = (r.collapses or 0) >= Regime.SPLIT_COLLAPSES or r.e3 == true
    r.collapses, r.e3 = 0, nil
    if due then
        local halves = Regime.splitHalves()
        if halves then
            shutCouncil()
            computed.kind, computed.bloc, computed.cold = "split", nil, nil
            computed.halves = halves
            return computed
        end
    end
    return nil
end

-- 국면이 바뀔 때의 소문 한 줄 (Politics.judgePhase). 견제·독주는 nil
function Regime.phaseText(ph)
    if ph.kind == "split" then
        return "The county council has broken in two and will not sit together: " .. sideNames(ph.halves.a.blocs)
            .. " on one side, " .. sideNames(ph.halves.b.blocs) .. " on the other. One side holds the power, the other the water."
    end
    if ph.kind == "martial" then
        return nameOf(ph.by) .. " has closed the county council and rules by order."
    end
    return nil
end

-- 갈라서는 의회(E3)를 풀지 못했다 (Crises.lua)
function Regime.onE3(why)
    if not Politics.on() then return end
    if why == "ignored" or why == "asks_failed" then state().e3 = true end
end

local function splitDaily(ph, now)
    for id, h in pairs(ph.halves or {}) do
        local members = halfMembers(h)
        if #members == 0 then
            leaveSplit(ph, now)
            reopenCouncil(now)
            Regime.setPhase("balance", {}, now)
            news("One half of the broken council is gone. What is left of the county council sits as one again.", now)
            return
        end
        local sum = 0
        for _, fid in ipairs(members) do sum = sum + trustOf(fid) end
        local avg = sum / #members
        h.avg = math.floor(avg + 0.5)
        if not h.cut and avg < Regime.SPLIT_CUT_TRUST then
            h.cut = true
            quietCut(h.hold)
            news(sideNames(h.blocs) .. " have shut off the " .. h.hold .. " to everyone who will not stand with them.", now)
            notify("split_cut", { half = id, hold = h.hold, blocs = h.blocs })
            local fid = leaderOf(h.blocs)
            if fid then
                pcall(Radio.react, fid, "event", "Your side of the broken council has just shut off the " .. h.hold
                    .. " to the players, because they have stood with the other side. Tell them, and what it would take to turn it back on.",
                    { text = "We have shut it off. You know why.", lt = { key = "IGUI_StoryEngine_Regime_Say_cut" } }, nil)
            end
        elseif h.cut and avg >= Regime.SPLIT_BACK_TRUST then
            h.cut = false
            giveBack(h.hold)
            notify("split_back", { half = id, hold = h.hold, blocs = h.blocs })
        end
    end
    -- 공용 주파수가 싸움터가 된다
    if not ph.sceneT or now.t - ph.sceneT >= Regime.SPLIT_SCENE_DAYS * 24 * 60 then
        ph.sceneT = now.t
        local la, lb = leaderOf(ph.halves.a.blocs), leaderOf(ph.halves.b.blocs)
        if la and lb and StoryEngine.Social and StoryEngine.Social.queueTopic then
            pcall(StoryEngine.Social.queueTopic, { la, lb }, "The county council is still broken in two. " .. nameOf(la) .. " and "
                .. nameOf(lb) .. " are on opposite sides; they trade blame on the open channel, each saying the other side "
                .. "walked out first.", "politics", nil)
        end
    end
end

-- 두 번째 카운티 회의: 양쪽 대표의 큰 부탁을 받아 온다
function Regime.reunite(player)
    local ph = phase()
    if not ph or ph.kind ~= "split" then return false, "no_split" end
    if ph.reunion then return false, "busy" end
    local now = Sensor.now()
    if ph.reuniteT and now.t - ph.reuniteT < Regime.REUNITE_RETRY_DAYS * 24 * 60 then return false, "wait" end
    local ps = Store.player(player)
    local asks = {}
    for _, id in ipairs({ "a", "b" }) do
        local fid = leaderOf(ph.halves[id].blocs)
        local q = fid and Quests.propose(player, ps, fid, Regime.REUNITE_TIER, now) or nil
        if q then
            q.reuniteAsk = id
            q.deadlineT = now.t + Regime.REUNITE_DAYS * 24 * 60
            Quests.respond(player, q.id, true)
            asks[id] = q.id
        end
    end
    if not (asks.a and asks.b) then return false, "no_ask" end
    ph.reunion = { asks = asks, untilT = now.t + Regime.REUNITE_DAYS * 24 * 60, by = ps.name }
    news(tostring(ps.name) .. " is trying to bring the two halves of the county council back to one table, and has taken on "
        .. "a hard job for each side to prove it.", now)
    notify("reunite", { name = ps.name })
    log("regime reunion started by", ps.name, asks.a, asks.b)
    return true
end

local function reunionResult(ph, now)
    local quests = Store.data().quests
    local all, failed = true, false
    for _, id in ipairs({ "a", "b" }) do
        local q = quests[ph.reunion.asks[id] or ""]
        if not q or q.state ~= "completed" then all = false end
        if q and (q.state == "failed" or q.state == "declined") then failed = true end
    end
    if all then
        local r = state()
        r.reunions = (r.reunions or 0) + 1
        leaveSplit(ph, now)
        reopenCouncil(now)
        for _, fid in ipairs(living()) do trust(fid, Regime.REUNITE_GAIN, "reunited") end
        Regime.setPhase("balance", { reunited = true }, now)
        news("Both halves of the county council got what they asked for and sat down at one table again: a second county "
            .. "council, in the same church. The power and the water are shared again.", now)
        notify("reunited", {})
        local fid = leaderOf({ "field", "gun", "market" })
        if fid and StoryEngine.Chronicle and StoryEngine.Chronicle.add then
            pcall(StoryEngine.Chronicle.add, fid, { kind = "council", v = "reunited" })
        end
        log("regime reunited")
    elseif failed then
        for _, id in ipairs({ "a", "b" }) do
            trust(leaderOf(ph.halves[id].blocs), -Regime.REUNITE_FAIL, "reunite_failed")
        end
        ph.reunion = nil
        ph.reuniteT = now.t
        notify("reunite_failed", {})
        log("regime reunion failed")
    end
end

-- ---------------------------------------------------------------- 군정

function Regime.martial()
    local r = peek()
    local ph = phase()
    if not r or not r.martial or not ph or ph.kind ~= "martial" then return nil end
    return r.martial
end

local function commander()
    local Out = StoryEngine.Outsiders
    if Out and Out.isHere and Out.isHere("hale") then return "hale" end
    if not Factions.isGone("guard") then return "guard" end
    return nil
end

local function gunStrong(now)
    if #Politics.members("gun") == 0 then return false end
    local c = Regime.coalition()
    if c and has(c.blocs, "gun") then return true end
    local ph = phase()
    if ph and ph.kind == "rule" and ph.bloc == "gun" then return true end
    local w = Politics.weights(now)
    return w.gun > 0 and w.gun >= w.field and w.gun >= w.market
end

-- 군정이 설 조건이 찼는가. 반환: 지휘관 | nil
function Regime.martialDue(now)
    local s = Politics.state()
    if Regime.closed() then return nil end
    if not s.impeachT or now.t - s.impeachT > Regime.IMPEACH_MEMORY_DAYS * 24 * 60 then return nil end
    if not (StoryEngine.Saga and StoryEngine.Saga.active()) then return nil end
    if not gunStrong(now) then return nil end
    return commander()
end

function Regime.enterMartial(by, now)
    local r = state()
    now = now or Sensor.now()
    shutCouncil()
    r.martial = { by = by, sinceT = now.t, nextOrderT = now.t + 24 * 60, obeyed = 0, defied = 0, orders = 0 }
    local against = (by == "hale" and not Factions.isGone("guard")) and "guard" or nil
    Regime.setPhase("martial", { by = by, against = against }, now)
    news(nameOf(by) .. " has closed the county council in the middle of the trouble and rules by order: no votes, no chair. "
        .. "Orders will come over the radio every week.", now)
    pcall(Radio.react, by, "event", "With the county in trouble and the council without a chair, you have just closed the "
        .. "council and taken command. There will be no votes. You will give the players orders, a levy or a sweep, every week. "
        .. "Tell them so, flatly.",
        { text = "The council is closed. You will take your orders from me.", lt = { key = "IGUI_StoryEngine_Regime_Say_martial" } }, nil)
    if against then
        pcall(Radio.react, against, "event", "Colonel Hale has just closed the county council and taken command. You refused "
            .. "orders like his once already. Tell the players you will not stand with him.",
            { text = "I'm not his man. Remember that.", lt = { key = "IGUI_StoryEngine_Regime_Say_against" } }, nil)
    end
    log("regime martial rule by", by)
    return r.martial
end

local function leaveMartial(now, why)
    local r = state()
    r.martial = nil
    reopenCouncil(now)
    Regime.setPhase("balance", {}, now)
    notify("martial_over", { why = why })
    log("regime martial rule over", tostring(why))
end

-- 따른 뒤 얼마 동안은 방위대가 대기 없이 돕는다 (Politics.dealt 가 묻는다)
function Regime.backed(fid)
    local m = Regime.martial()
    if not m or m.by ~= "guard" or fid ~= "guard" then return false end
    return m.backUntil ~= nil and Sensor.now().t < m.backUntil
end

-- 주마다 내려오는 명령: 징발과 소탕을 번갈아
local function martialOrder(m, now)
    local player, ps = anyPlayer()
    if not player then return nil end
    m.orders = (m.orders or 0) + 1
    local sweep = m.orders % 2 == 0
    local q = nil
    if sweep then q = Quests.proposeHorde(player, ps, m.by, Regime.MARTIAL_TIER, now, {}) end
    if not q then
        q = Quests.propose(player, ps, m.by, Regime.MARTIAL_TIER, now)
        sweep = false
    end
    m.nextOrderT = now.t + (m.settled and Regime.MARTIAL_SETTLED_DAYS or Regime.MARTIAL_ORDER_DAYS) * 24 * 60
    if not q then return nil end
    q.martial = true
    m.order = q.id
    notify("martial_order", { by = m.by, sweep = sweep })
    log("regime martial order", q.id, sweep and "sweep" or "levy")
    return q
end

local function martialResult(m, q, st, now)
    m.order = nil
    if st == "completed" then
        m.obeyed = (m.obeyed or 0) + 1
        m.backUntil = now.t + Regime.MARTIAL_BACK_DAYS * 24 * 60
        if m.by == "hale" then
            trust("hale", Regime.MARTIAL_OBEY, "martial_obeyed")
            trust("guard", -Regime.MARTIAL_OBEY, "martial_sided", "hale")
        end
        notify("martial_obeyed", { by = m.by, n = m.obeyed })
        if not m.settled and m.obeyed >= Regime.MARTIAL_SETTLE then
            m.settled = true
            news("The county has got used to taking orders. " .. nameOf(m.by) .. "'s rule is no longer called an emergency; "
                .. "it is simply how things are run.", now)
            notify("martial_settled", { by = m.by })
        end
    else
        m.defied = (m.defied or 0) + 1
        trust(m.by, -Regime.MARTIAL_DEFY, "martial_defied")
        notify("martial_defied", { by = m.by, n = m.defied })
        -- 어기면 협박 대상이 된다
        local on = not StoryEngine.Tuning or StoryEngine.Tuning.get("Extortion") ~= false
        local player = (q.target and playerByKey(q.target)) or anyPlayer()
        if on and player and not Quests.openFor(Store.playerKey(player), "extort") then
            pcall(Quests.demand, player, Store.player(player), m.by, 2, now)
        end
    end
end

-- 청원: 지휘관 말고 나머지 NPC 의 과반이 우리를 믿으면 의회를 다시 연다. 반환: true | false, 이유, 믿는 수, 필요한 수
function Regime.petition(player)
    local m = Regime.martial()
    if not m then return false, "no_martial" end
    local yes, n = 0, 0
    for _, fid in ipairs(living()) do
        if fid ~= m.by then
            n = n + 1
            if trustOf(fid) >= Regime.PETITION_TRUST then yes = yes + 1 end
        end
    end
    local need = math.floor(n / 2) + 1
    if n == 0 or yes < need then return false, "trust", yes, need end
    local now = Sensor.now()
    local ps = Store.player(player)
    trust(m.by, -Regime.PETITION_COST, "martial_ended")
    news(tostring(ps.name) .. " carried a petition from most of the county to " .. nameOf(m.by)
        .. ", and the county council sits again. A chair will be chosen.", now)
    pcall(Radio.react, m.by, "event", "Most of the county, led by " .. tostring(ps.name) .. ", has petitioned you to reopen the "
        .. "council, and you have given way. Say so, stiffly.",
        { text = "The council may sit again. I will remember who asked.", lt = { key = "IGUI_StoryEngine_Regime_Say_petition" } }, ps)
    leaveMartial(now, "petition")
    return true
end

local function martialTick(m, now)
    local by = m.by
    local gone = (by == "hale" and not (StoryEngine.Outsiders and StoryEngine.Outsiders.isHere("hale")))
        or (by ~= "hale" and Factions.isGone(by))
    if gone then
        news("With " .. nameOf(by) .. " gone, nobody is giving orders any more. The county council sits again.", now)
        leaveMartial(now, "gone")
        return
    end
    if m.order then
        local q = Store.data().quests[m.order]
        if not q or q.state == "completed" or q.state == "failed" or q.state == "declined" then
            m.order = nil      -- 훅을 못 받고 끝난 명령 (세이브를 넘긴 경우)
        end
        return
    end
    if now.t >= (m.nextOrderT or 0) and #Sensor.players() > 0 then martialOrder(m, now) end
end

-- ---------------------------------------------------------------- 보정 (Politics.mod 가 얹는다)

function Regime.mod(key, fid, a)
    local m = Regime.martial()
    if m and key == "price" and fid and not Factions.isOutsider(fid) and Politics.blocOf(fid) ~= "gun" then
        return Regime.MARTIAL_PRICE
    end
    return nil
end

-- 국면 판정의 무게: 쥔 시설 하나에 +1
function Regime.weight(bloc)
    local r = peek()
    local n = 0
    for _, h in pairs(r and r.facility and r.facility.held or {}) do
        if h.bloc == bloc then n = n + 1 end
    end
    return n
end

-- ---------------------------------------------------------------- 시설 (Saga.lua 의 facility)

-- 지금 일이 날 수 있는 시설: 의회가 살려 둔 것 가운데 고장 나지 않은 것
function Regime.facilityKinds()
    local out = {}
    if not Politics.on() or not StoryEngine.Grid then return out end
    for _, kind in ipairs({ "power", "water" }) do
        if StoryEngine.Grid.isRestored(kind) == true and not Regime.gridBlocked(kind) then out[#out + 1] = kind end
    end
    return out
end

-- 지켰다: 그때 제안을 받은 파벌이 그 시설을 쥔다 (없으면 아무도)
function Regime.holdFacility(kind, bloc, now)
    local r = state()
    now = now or Sensor.now()
    if bloc and bloc ~= "none" and has(Politics.BLOCS, bloc) then
        r.facility.held[kind] = { bloc = bloc, t = now.t }
        news(sideNames({ bloc }) .. " sent their people to the " .. (kind == "power" and "substation" or "water tower")
            .. " and have kept them there. It is theirs to run now.", now)
    else
        r.facility.held[kind] = nil
    end
    notify("facility_held", { what = kind, bloc = r.facility.held[kind] and bloc or nil })
end

-- 못 지켰다: FACILITY_DOWN_DAYS 동안 고장
function Regime.breakFacility(kind, now)
    local r = state()
    now = now or Sensor.now()
    r.facility.held[kind] = nil
    r.facility.down[kind] = now.t + Regime.FACILITY_DOWN_DAYS * 24 * 60
    quietCut(kind)
    notify("facility_lost", { what = kind, days = Regime.FACILITY_DOWN_DAYS })
    log("regime facility down", kind)
end

local function facilityTick(r, now)
    for _, kind in ipairs({ "power", "water" }) do
        local untilT = r.facility.down[kind]
        if untilT and now.t >= untilT then
            r.facility.down[kind] = nil
            if giveBack(kind) then notify("facility_back", { what = kind }) end
        end
    end
    -- 쥔 파벌의 사람이 모두 떠났으면 놓는다
    for kind, h in pairs(r.facility.held) do
        if #Politics.members(h.bloc) == 0 then r.facility.held[kind] = nil end
    end
end

-- ---------------------------------------------------------------- 증언 (큰 사건 뒤의 공과)

-- Politics.onSaga("done") 이 정산한 뒤 부른다. deal = 그때 제안을 받은 파벌 | "none" | nil
function Regime.onSagaDone(sg, deal, good)
    if not Politics.on() then return end
    local r = state()
    local now = Sensor.now()
    r.blame = { kind = sg.kind, deal = deal, good = good, untilT = now.t + Regime.TESTIFY_HOURS * 60 }
    local ids = {}
    for _, b in ipairs(Politics.BLOCS) do
        local fid = leaderOf({ b })
        if fid and #ids < 3 then ids[#ids + 1] = fid end
    end
    if #ids >= 2 and StoryEngine.Social and StoryEngine.Social.queueTopic then
        pcall(StoryEngine.Social.queueTopic, ids, "The trouble in the county (" .. tostring(sg.kind) .. ") is over and it ended "
            .. (good and "well" or "badly") .. ". On the open channel the camps argue over who did the work and who left "
            .. "the others to it. Each claims the credit for their own side" .. (good and "" or " and blames the others") .. ".",
            "politics", nil)
    end
    notify("testify_open", { saga = sg.kind, hours = Regime.TESTIFY_HOURS })
end

function Regime.testify(player, bloc)
    local r = peek()
    local b = r and r.blame
    local now = Sensor.now()
    if not b or now.t >= b.untilT then return false, "no_blame" end
    if b.used then return false, "done" end
    if not has(Politics.BLOCS, bloc) or #Politics.members(bloc) == 0 then return false, "no_target" end
    local s = Politics.state()
    local ps = Store.player(player)
    s.credit = s.credit or {}
    s.credit[bloc] = math.max(-Politics.CREDIT_MAX, math.min(Politics.CREDIT_MAX, (s.credit[bloc] or 0) + 1))
    s.lean[bloc] = math.max(-100, math.min(100, (s.lean[bloc] or 0) + Regime.TESTIFY_LEAN))
    b.used, b.by, b.bloc = true, ps.name, bloc
    if b.deal and b.deal ~= "none" and b.deal ~= bloc then
        trust(leaderOf({ b.deal }), -Regime.TESTIFY_COST, "testified_against")
    end
    local fid = leaderOf({ bloc })
    if fid then
        pcall(Radio.react, fid, "event", tostring(ps.name) .. " just spoke up on the open channel for your side's account of the "
            .. "trouble that is just over: that your people did the work. Thank them, briefly, in character.",
            { text = "You said it plain, and they heard it. I won't forget.", lt = { key = "IGUI_StoryEngine_Regime_Say_testified" } }, ps)
    end
    news(tostring(ps.name) .. " spoke up on the open channel for " .. sideNames({ bloc }) .. "'s account of the trouble that is just over.", now)
    notify("testified", { bloc = bloc, name = ps.name })
    log("regime testimony for", bloc, "by", ps.name)
    return true
end

-- ---------------------------------------------------------------- 퀘스트 결과

local function onQuest(q, st)
    local s = Store.data().politics
    if not s or not s.openT then return end
    if st ~= "completed" and st ~= "failed" and st ~= "declined" then return end
    local now = Sensor.now()
    local r = state()
    local ph = s.phase
    -- 군정의 명령
    if q.martial and r.martial and r.martial.order == q.id then martialResult(r.martial, q, st, now) end
    if not ph or ph.kind ~= "split" then return end
    -- 두 번째 카운티 회의
    if q.reuniteAsk and ph.reunion then
        reunionResult(ph, now)
        return
    end
    -- 한쪽을 도우면 다른 쪽이 식는다
    local fid = q.origin and q.origin.faction
    if st == "completed" and fid and NPC_ASKS[q.kind] and not Quests.isManaged(q) and q.origin.initiator == "npc" then
        local mine = halfOf(ph, fid)
        local other = mine == "a" and "b" or (mine == "b" and "a" or nil)
        if other then
            ph.rivalLog = ph.rivalLog or {}
            local keep = {}
            for _, t in ipairs(ph.rivalLog) do
                if now.t - t < 7 * 24 * 60 then keep[#keep + 1] = t end
            end
            ph.rivalLog = keep
            if #keep < Regime.SPLIT_RIVAL_WEEK then
                keep[#keep + 1] = now.t
                trust(leaderOf(ph.halves[other].blocs), -Regime.SPLIT_RIVAL_COST, "split_rival", fid)
            end
        end
    end
end

Quests.hooks[#Quests.hooks + 1] = function(q, st)
    local ok, err = pcall(onQuest, q, st)
    if not ok then log("regime quest hook error:", tostring(err)) end
end

-- ---------------------------------------------------------------- 날마다·시간마다

-- Politics.daily 가 부른다
function Regime.daily(now)
    if not Politics.on() then return end
    now = now or Sensor.now()
    local ok, err = pcall(coalitionDaily, now)
    if not ok then log("regime coalition error:", tostring(err)) end
    local ph = phase()
    if ph and ph.kind == "split" then
        local ok2, err2 = pcall(splitDaily, ph, now)
        if not ok2 then log("regime split error:", tostring(err2)) end
    end
end

-- Politics.tick 이 부른다 (한 시간마다, 접속자가 있을 때)
function Regime.tick(now)
    if not Politics.on() then return end
    now = now or Sensor.now()
    local r = state()
    facilityTick(r, now)
    if r.blame and now.t >= r.blame.untilT then r.blame = nil end
    -- 무너진 다수파 뒤의 불신임 (걸린 표결이 있으면 그것이 끝난 뒤)
    if r.noconfDue and not Regime.closed() then
        local bill, why = openNoConfidence(now, nil)
        if bill or why == "no_chair" then r.noconfDue = nil end
    end
    local ph = phase()
    if ph and ph.kind == "split" and ph.reunion and now.t >= ph.reunion.untilT then
        reunionResult(ph, now)
        if ph.reunion then          -- 기한이 지났는데 아직 열려 있다: 실패로
            for _, id in ipairs({ "a", "b" }) do
                trust(leaderOf(ph.halves[id].blocs), -Regime.REUNITE_FAIL, "reunite_failed")
            end
            ph.reunion = nil
            ph.reuniteT = now.t
            notify("reunite_failed", {})
        end
    end
    if r.martial then
        if ph and ph.kind == "martial" then martialTick(r.martial, now) else r.martial = nil end
    else
        local by = Regime.martialDue(now)
        if by then Regime.enterMartial(by, now) end
    end
end

-- ---------------------------------------------------------------- 클라이언트로, AI 로

function Regime.payload(key, now)
    local r = peek()
    if not r then return nil end
    now = now or Sensor.now()
    local out = {}
    local c = r.coalition
    if c then
        out.coalition = { blocs = c.blocs, strain = c.strain or 0, limit = Regime.COLLAPSE_DAYS,
                          cohesion = c.cohesion and math.floor(c.cohesion * 10 + 0.5) / 10 or nil,
                          mendWait = r.mendT and math.max(0, math.ceil((Regime.MEND_DAYS * 24 * 60 - (now.t - r.mendT)) / 60 / 24)) or 0,
                          members = {} }
        for _, b in ipairs(c.blocs) do
            for _, fid in ipairs(Politics.members(b)) do out.coalition.members[#out.coalition.members + 1] = fid end
        end
    end
    local chair = Politics.chair()
    if chair and chair.fid and not Regime.closed() then
        out.noconf = { fid = chair.fid,
                       wait = r.noconfT and math.max(0, math.ceil((Regime.NOCONF_DAYS * 24 * 60 - (now.t - r.noconfT)) / 60 / 24)) or 0 }
    end
    local ph = phase()
    if ph and ph.kind == "split" then
        out.split = { halves = {}, reunion = ph.reunion and { hours = math.max(0, math.ceil((ph.reunion.untilT - now.t) / 60)), by = ph.reunion.by } or nil,
                      wait = ph.reuniteT and math.max(0, math.ceil((Regime.REUNITE_RETRY_DAYS * 24 * 60 - (now.t - ph.reuniteT)) / 60 / 24)) or 0 }
        for _, id in ipairs({ "a", "b" }) do
            local h = ph.halves[id]
            out.split.halves[#out.split.halves + 1] = { id = id, blocs = h.blocs, hold = h.hold, cut = h.cut or nil, avg = h.avg,
                                                         members = halfMembers(h), leader = leaderOf(h.blocs) }
        end
    elseif ph and ph.kind == "martial" and r.martial then
        local m = r.martial
        local yes, n = 0, 0
        for _, fid in ipairs(living()) do
            if fid ~= m.by then
                n = n + 1
                if trustOf(fid) >= Regime.PETITION_TRUST then yes = yes + 1 end
            end
        end
        out.martial = { by = m.by, against = ph.against, obeyed = m.obeyed or 0, defied = m.defied or 0, settled = m.settled or nil,
                        order = m.order, days = math.max(0, math.ceil(((m.nextOrderT or now.t) - now.t) / 60 / 24)),
                        backed = Regime.backed("guard") or nil, yes = yes, need = math.floor(n / 2) + 1, settleAt = Regime.MARTIAL_SETTLE }
    end
    local fac = { held = {}, down = {} }
    local any = false
    for _, kind in ipairs({ "power", "water" }) do
        local h = r.facility.held[kind]
        if h then fac.held[#fac.held + 1] = { what = kind, bloc = h.bloc }; any = true end
        local d = r.facility.down[kind]
        if d and now.t < d then fac.down[#fac.down + 1] = { what = kind, days = math.max(0, math.ceil((d - now.t) / 60 / 24)) }; any = true end
    end
    if any then out.facility = fac end
    local b = r.blame
    if b and now.t < b.untilT then
        out.blame = { saga = b.kind, good = b.good, deal = b.deal, used = b.used or nil, bloc = b.bloc, by = b.by,
                      hours = math.max(0, math.ceil((b.untilT - now.t) / 60)) }
    end
    return out
end

-- AI 맥락에 얹는 것 (Politics.context): 이 사람이 다수파인지, 갈라선 어느 쪽인지, 군정에서 어떤 자리인지
function Regime.context(fid)
    local r = peek()
    if not r then return nil end
    local out = {}
    local c = r.coalition
    if c and #c.blocs == 2 then
        out.coalition = { blocs = c.blocs, mine = has(c.blocs, Politics.blocOf(fid)) or nil, strained = (c.strain or 0) > 0 or nil }
    end
    local ph = phase()
    if ph and ph.kind == "split" then
        local mine = halfOf(ph, fid)
        if mine then
            local other = mine == "a" and "b" or "a"
            out.split = { mine = ph.halves[mine].blocs, other = ph.halves[other].blocs, hold = ph.halves[mine].hold,
                          cut = ph.halves[mine].cut or nil, reunion = ph.reunion ~= nil or nil }
        end
    elseif ph and ph.kind == "martial" and r.martial then
        local m = r.martial
        out.martial = { by = nameOf(m.by), role = fid == m.by and "commander" or (fid == ph.against and "against"
                            or (Politics.blocOf(fid) == "gun" and "with" or "under")), settled = m.settled or nil }
    end
    for _ in pairs(out) do return out end
    return nil
end

-- 두 번째 연대기 (Politics.summary) 에 얹는 것
function Regime.summary()
    local r = peek()
    if not r then return nil end
    local ph = phase()
    return { collapses = r.collapsesAll or 0, noconfs = r.noconfs or 0, reunions = r.reunions or 0,
             split = ph and ph.kind == "split" or nil, martial = (ph and ph.kind == "martial" and r.martial) and nameOf(r.martial.by) or nil,
             settled = r.martial and r.martial.settled or nil }
end

-- ---------------------------------------------------------------- 디버그

-- what: coalition(다시 짬) collapse noconf split martial order(명령 바로) end(견제로) blame(증언 열기) facility(power|water 고장) reset
function Regime.debug(args, player)
    local now = Sensor.now()
    local r = state()
    local what = tostring(args.what or "")
    if what == "coalition" then
        r.reformT = nil
        Regime.formCoalition(now)
    elseif what == "collapse" then
        if not r.coalition then Regime.formCoalition(now) end
        Regime.collapse(now, "debug")
    elseif what == "noconf" then
        openNoConfidence(now, nil)
    elseif what == "split" then
        enterSplit(now, "debug")
    elseif what == "martial" then
        local by = commander()
        if by then Regime.enterMartial(by, now) end
    elseif what == "order" then
        if r.martial then
            r.martial.order = nil
            martialOrder(r.martial, now)
        end
    elseif what == "end" then
        local ph = phase()
        if ph and ph.kind == "split" then leaveSplit(ph, now) end
        r.martial = nil
        reopenCouncil(now)
        Regime.setPhase("balance", {}, now)
    elseif what == "blame" then
        Regime.onSagaDone({ kind = tostring(args.id or "migration") }, nil, true)
    elseif what == "facility" then
        Regime.breakFacility(args.id == "water" and "water" or "power", now)
    elseif what == "reset" then
        local ph = phase()
        if ph and ph.kind == "split" then leaveSplit(ph, now) end
        local down = r.facility.down
        Politics.state().regime = nil
        for kind in pairs(down) do giveBack(kind) end
    end
    return Regime.statusText()
end

function Regime.statusText()
    local r = peek()
    if not r then return "regime -" end
    local ph = phase()
    local c = r.coalition
    local held, down = {}, {}
    for kind, h in pairs(r.facility.held) do held[#held + 1] = kind .. "=" .. tostring(h.bloc) end
    for kind in pairs(r.facility.down) do down[#down + 1] = kind end
    table.sort(held)
    table.sort(down)
    return "regime phase=" .. tostring(ph and ph.kind or "none")
        .. " coalition=" .. (c and (table.concat(c.blocs, "+") .. " strain " .. StoryEngine.intToString(c.strain or 0)) or "none")
        .. " collapses=" .. StoryEngine.intToString(r.collapses or 0)
        .. (r.martial and (" martial by " .. tostring(r.martial.by) .. " obeyed " .. StoryEngine.intToString(r.martial.obeyed or 0)
            .. " defied " .. StoryEngine.intToString(r.martial.defied or 0)) or "")
        .. " held=" .. (#held > 0 and table.concat(held, ",") or "none") .. " down=" .. (#down > 0 and table.concat(down, ",") or "none")
end

Regime.enterSplit = enterSplit

return Regime
