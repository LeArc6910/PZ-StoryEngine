-- 의회의 자리 셋 (2026-10-14, docs/PLAN_COUNCIL_POLITICS.md 5단계의 나머지). 의장은 Politics.lua 가 맡는다.
--
--   store   창고지기  : 우리를 믿으면(WARM 이상) 주마다 작은 보급 / 미워하면(COLD 미만) 모든 거래 값 x1.1
--   captain 경비대장  : 믿으면 방위대·행크 특기 대기 x0.5 / 미워하면 x2
--   air     방송 담당 : 믿으면 저녁 방송 다음 날 무작위 NPC 신뢰 +1 / 미워하면 -1
--
-- 정치가 열린 뒤 15·30·45일에 처음 뽑고 임기는 TERM_DAYS(60일). 표결은 VOTE_DAYS(3일) 뒤, 의장 선거와 같은 셈
-- (자기 파벌 후보 30 + 후보와의 사이 x10 + 플레이어가 지지한 후보면 신뢰도 x0.5). 후보는 파벌마다 한 명:
-- 아직 자리가 없는 사람 가운데 우리를 가장 믿는 사람. 한 사람은 자리를 하나만 가진다.
-- 공개 지지(Offices.back, 번복 불가): 그 파벌 쪽으로 기울기 +5, 지지한 후보가 지면 당선된 사람 신뢰 -2.
-- 자리를 가진 사람이 죽거나 떠나면 VACANT_DAYS 뒤에 다시 뽑는다.
-- 효과는 Offices.mod 로 (Politics.mod 가 곱한다). 상태: d.politics.offices = { held, nextT, vote, giftT, airDay }

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

local Offices = {}
StoryEngine.Offices = Offices

local Net = StoryEngine.Net
local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Radio = StoryEngine.Radio
local Stories = StoryEngine.Stories
local Politics = StoryEngine.Politics
local log = StoryEngine.log

Offices.ORDER = { "store", "captain", "air" }
Offices.FIRST_DAYS = { store = 15, captain = 30, air = 45 }
Offices.TERM_DAYS = 60
Offices.VOTE_DAYS = 3
Offices.VACANT_DAYS = 3
Offices.WARM, Offices.COLD = 60, 30
Offices.STORE_GIFT_DAYS = 7
Offices.STORE_PRICE = 1.1
Offices.CAPTAIN_WARM, Offices.CAPTAIN_COLD = 0.5, 2
Offices.CAPTAIN_FIDS = { guard = true, hunter = true }
Offices.BACK_LEAN, Offices.BACK_COST = 5, 2
Offices.TITLE = { store = "storekeeper", captain = "captain of the county guard", air = "voice of the evening broadcast" }

local function state()
    local s = Politics.state()
    s.offices = s.offices or {}
    local o = s.offices
    o.held = o.held or {}
    o.nextT = o.nextT or {}
    return o
end

local function nameOf(fid) return tostring(Stories.NAMES[fid] or fid) end
local function trustOf(fid) return Radio.channel(fid).trust or 0 end

local function notify(kind, args)
    args = args or {}
    args.kind = kind
    pcall(Net.toAll, "politicsNotice", args)
end

-- 그 자리를 지금 가진 사람 (없거나 떠났거나 임기가 끝났으면 nil)
function Offices.holder(id, now)
    local s = Store.data().politics
    local h = s and s.offices and s.offices.held and s.offices.held[id]
    if not h then return nil end
    if Factions.isGone(h.fid) or (now or Sensor.now().t) >= (h.untilT or 0) then return nil end
    return h
end

-- warm | cold | nil
function Offices.mood(id, now)
    local h = Offices.holder(id, now)
    if not h then return nil end
    local t = trustOf(h.fid)
    if t >= Offices.WARM then return "warm" end
    if t < Offices.COLD then return "cold" end
    return nil
end

-- 이 사람이 이미 자리를 가졌는가 (의장 포함)
function Offices.busy(fid, now)
    local c = Politics.chair()
    if c and c.fid == fid then return true end
    for _, id in ipairs(Offices.ORDER) do
        local h = Offices.holder(id, now)
        if h and h.fid == fid then return true end
    end
    return false
end

-- Politics.mod 가 곱하는 값 (없으면 nil)
function Offices.mod(key, fid, a)
    if not Politics.on() then return nil end
    if key == "price" then
        if Offices.mood("store") == "cold" then return Offices.STORE_PRICE end
    elseif key == "specWait" and fid and Offices.CAPTAIN_FIDS[fid] then
        local m = Offices.mood("captain")
        if m == "warm" then return Offices.CAPTAIN_WARM end
        if m == "cold" then return Offices.CAPTAIN_COLD end
    end
    return nil
end

local function candidates(now)
    local out, any = {}, false
    for _, b in ipairs(Politics.BLOCS) do
        local best, top = nil, -1
        for _, fid in ipairs(Politics.members(b)) do
            if not Offices.busy(fid, now) and trustOf(fid) > top then best, top = fid, trustOf(fid) end
        end
        out[b] = best
        if best then any = true end
    end
    return out, any
end

function Offices.forecast(vote)
    return Politics.electionForecast({ cands = vote.cands, backed = vote.backed })
end

-- 선거를 연다. 반환: vote | nil
function Offices.open(id, now)
    local o = state()
    if o.vote then return nil end
    now = now or Sensor.now()
    local cands, any = candidates(now.t)
    if not any then
        o.nextT[id] = now.t + Offices.VACANT_DAYS * 24 * 60
        return nil
    end
    o.vote = { office = id, t = now.t, voteT = now.t + Offices.VOTE_DAYS * 24 * 60, cands = cands }
    local names = {}
    for _, b in ipairs(Politics.BLOCS) do
        if cands[b] then names[#names + 1] = nameOf(cands[b]) end
    end
    local text = "The county council is choosing its " .. Offices.TITLE[id] .. ". Standing: " .. table.concat(names, ", ")
        .. ". The vote is in " .. StoryEngine.intToString(Offices.VOTE_DAYS) .. " days."
    if StoryEngine.Social and StoryEngine.Social.news then StoryEngine.Social.news("all", text) end
    notify("office_vote", { office = id })
    log("offices vote open", id)
    return o.vote
end

-- 공개 지지 (번복 불가)
function Offices.back(player, bloc)
    local o = state()
    local v = o.vote
    if not Politics.on() or not v then return false, "no_election" end
    if v.backed then return false, "backed" end
    if not v.cands[bloc] then return false, "no_target" end
    local ps = Store.player(player)
    v.backed, v.backedBy = bloc, ps.name
    local lean = Politics.state().lean
    lean[bloc] = math.max(-100, math.min(100, (lean[bloc] or 0) + Offices.BACK_LEAN))
    Radio.react(v.cands[bloc], "event", tostring(ps.name) .. " just backed you, in the open, for " .. Offices.TITLE[v.office]
        .. " of the county. Thank them in your own way.",
        { text = "I won't forget that.", lt = { key = "IGUI_StoryEngine_Politics_Say_Backed" } }, ps)
    log("offices backed", v.office, bloc, "by", ps.name)
    return true
end

-- 표결. 반환: 당선된 사람 | nil
function Offices.decide(now)
    local o = state()
    local v = o.vote
    if not v then return nil end
    now = now or Sensor.now()
    local f = Offices.forecast(v)
    o.vote = nil
    local fid = f.winner and v.cands[f.winner] or nil
    if not fid or Factions.isGone(fid) then
        o.nextT[v.office] = now.t + Offices.VACANT_DAYS * 24 * 60
        return nil
    end
    local untilT = now.t + Offices.TERM_DAYS * 24 * 60
    o.held[v.office] = { fid = fid, bloc = f.winner, sinceT = now.t, untilT = untilT }
    o.nextT[v.office] = untilT - Offices.VOTE_DAYS * 24 * 60
    -- 지지한 후보가 졌으면 당선된 사람이 꺼린다
    if v.backed and v.backed ~= f.winner and StoryEngine.Trust then
        StoryEngine.Trust.apply(fid, -Offices.BACK_COST, "office_against")
    end
    local text = nameOf(fid) .. " was chosen " .. Offices.TITLE[v.office] .. " by the county council for the next two months."
    if StoryEngine.Social and StoryEngine.Social.news then StoryEngine.Social.news("all", text) end
    for _, ps in pairs(Store.data().players) do
        if not ps.dead then Store.addNote(ps, { kind = "op", text = text, clock = now.clock }) end
    end
    Radio.react(fid, "event", "The county council just chose you as its " .. Offices.TITLE[v.office] .. " for the next two "
        .. "months. Say briefly what that will mean for the players, given how much you trust them.",
        { text = "The job is mine now.", lt = { key = "IGUI_StoryEngine_Politics_Say_Office" } }, nil)
    notify("office", { office = v.office, fid = fid, bloc = f.winner })
    log("offices chosen", v.office, fid)
    return fid
end

function Offices.tick(now)
    if not Politics.on() then return end
    now = now or Sensor.now()
    local o = state()
    local openT = Politics.state().openT or now.t
    for _, id in ipairs(Offices.ORDER) do
        local h = o.held[id]
        if h and (Factions.isGone(h.fid) or now.t >= h.untilT) then
            -- 떠났으면 사흘 뒤에 다시 뽑는다 (임기가 끝난 자리는 이미 선거 날짜가 잡혀 있다)
            if Factions.isGone(h.fid) then o.nextT[id] = now.t + Offices.VACANT_DAYS * 24 * 60 end
            o.held[id] = nil
            notify("office_vacant", { office = id })
        end
    end
    if #Sensor.players() == 0 then return end
    if o.vote and now.t >= o.vote.voteT then Offices.decide(now) end
    if not o.vote then
        for _, id in ipairs(Offices.ORDER) do
            local at = o.nextT[id] or (openT + Offices.FIRST_DAYS[id] * 24 * 60)
            if now.t >= at then
                Offices.open(id, now)
                break
            end
        end
    end
end

-- 날마다 (Politics.daily): 창고지기의 보급, 방송 담당의 말
function Offices.daily(now)
    if not Politics.on() then return end
    now = now or Sensor.now()
    local o = state()
    local players = Sensor.players()
    local store = Offices.holder("store", now.t)
    if store and Offices.mood("store", now.t) == "warm" and #players > 0
        and (not o.giftT or now.t - o.giftT >= Offices.STORE_GIFT_DAYS * 24 * 60) then
        local player = players[ZombRand(#players) + 1]
        local ok, q = pcall(StoryEngine.Quests.create, "supply_drop", player, Store.player(player), 1, now,
            { source = "director", faction = store.fid, initiator = "gift", friend = true, office = true })
        if ok and q then
            o.giftT = now.t
            log("offices storekeeper gift", tostring(q.id))
        end
    end
    -- 방송이 나간 다음 날
    local air = Offices.holder("air", now.t)
    local b = Store.data().broadcast
    local aired = b and b.lastDay or nil
    if air and aired and o.airDay ~= aired then
        o.airDay = aired
        local mood = Offices.mood("air", now.t)
        if mood and StoryEngine.Trust then
            local pool = {}
            for _, f in ipairs(Factions.list) do
                if f.id ~= air.fid and not Factions.isGone(f.id) then pool[#pool + 1] = f.id end
            end
            if #pool > 0 then
                local fid = pool[ZombRand(#pool) + 1]
                StoryEngine.Trust.apply(fid, mood == "warm" and 1 or -1, mood == "warm" and "air_praise" or "air_smear", nil, nil, air.fid)
            end
        end
    end
end

function Offices.payload(key, now)
    if not Politics.on() then return nil end
    now = now or Sensor.now()
    local o = state()
    local openT = Politics.state().openT or now.t
    local out = { list = {} }
    for _, id in ipairs(Offices.ORDER) do
        local h = Offices.holder(id, now.t)
        local row = { id = id }
        if h then
            row.fid, row.bloc = h.fid, h.bloc
            row.days = math.max(0, math.ceil((h.untilT - now.t) / 60 / 24))
            row.mood = Offices.mood(id, now.t)
        else
            local at = o.nextT[id] or (openT + Offices.FIRST_DAYS[id] * 24 * 60)
            row.voteIn = math.max(0, math.ceil((at - now.t) / 60 / 24))
        end
        out.list[#out.list + 1] = row
    end
    local v = o.vote
    if v then
        local f = Offices.forecast(v)
        out.vote = { office = v.office, hours = math.max(0, math.ceil((v.voteT - now.t) / 60)), cands = v.cands,
                     votes = f.votes, winner = f.winner, backed = v.backed, backedBy = v.backedBy }
    end
    return out
end

-- 디버그: 그 자리의 선거를 열거나, 열려 있으면 바로 표결
function Offices.debug(id)
    local o = state()
    local now = Sensor.now()
    if o.vote then return Offices.decide(now) end
    if not Offices.FIRST_DAYS[id] then id = "store" end
    o.held[id] = nil
    return Offices.open(id, now)
end

return Offices
