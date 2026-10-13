-- 정치 위기 (2026-10-13, docs/PLAN_COUNCIL_POLITICS.md 8단계, 확정안은 docs/IDEAS_COUNCIL_ERA.md 12-3).
--
-- 의회의 정치가 열린 뒤 FIRST_DAYS 일, 그 뒤 GAP_MIN~GAP_MAX 일마다 하나씩. 한 번에 하나, 같은 위기는 한 번만
-- (배급은 겨울마다). 큰 사건이나 밖에서 온 사람의 충성 시험이 열려 있는 동안에는 시작하지 않는다.
-- 답할 시간은 ANSWER_HOURS(72시간). 답하지 않으면 위기마다 정해 둔 나쁜 쪽으로 간다.
--
-- 여기 있는 것 (택일·배분·모금):
--   split      E3 갈라서는 의회: 밭 편 / 총 편 / 양쪽의 큰 부탁을 모두 해냄. 갈라지면 SPLIT_DAYS 동안 가결 기준이 3분의 2,
--              외면당한 쪽이 전기(총)나 수도(밭)를 쥔다
--   transformer E5 타 버린 변압기: 부품 모금. 못 채우면 NIGHT_DAYS 동안 밤에만 전기
--   ration     E7 배급 (겨울): 모자란 식량을 누구 몫에서 줄일지 나눈다
--   refugees   E8 난민 행렬: 백 명을 어느 거점에 몇 명씩 받을지, 나머지는 돌려보낸다
--   quarantine E9 격리: 봉쇄 / 열어 두고 닥을 보냄 (닥 특기 QUARANTINE_DAYS 쉼, 두 곳에 번짐)
--   boat       E15 케이시의 배 (오델이 와 있을 때): 붙잡음 / 보냄 (BOAT_DAYS 뒤 돌아와 바깥 소식과 새 거래 길)
--   tribunal   E16 휘태커의 군법회의 (헤일이 와 있을 때): 증언 / 숨김 / 의회 이름으로 거부 (표결)
-- 조사 틀을 쓰는 위기(E2 빼돌린 창고, E4 재판, E6 오염된 물, E17 해적 방송)는 Inquiry.lua.
--
-- 이어지는 효과는 Crises.mod(key, fid, a) 로 읽는다 (Politics.mod 가 얹는다).
-- 상태: d.crises = { seq, nextT, done[id] = day, current = { id, t, untilT, ... }, fx = { split, night, quarantine, boat, route } }

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Radio"
require "StoryEngine/Trust"
require "StoryEngine/Life"
require "StoryEngine/Quests"
require "StoryEngine/Stories"
require "StoryEngine/Grid"

local Crises = {}
StoryEngine.Crises = Crises

local Net = StoryEngine.Net
local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Radio = StoryEngine.Radio
local Life = StoryEngine.Life
local Quests = StoryEngine.Quests
local Stories = StoryEngine.Stories
local log = StoryEngine.log

Crises.FIRST_DAYS = 7
Crises.GAP_MIN_DAYS = 10
Crises.GAP_MAX_DAYS = 14
Crises.ANSWER_HOURS = 72
Crises.ORDER = { "split", "transformer", "ration", "refugees", "quarantine", "boat", "tribunal" }

Crises.SPLIT_DAYS = 30
Crises.SPLIT_LEAN = 20
Crises.SPLIT_GAIN = 2
Crises.SPLIT_LOSS = 5
Crises.SPLIT_ASK_DAYS = 5
Crises.SPLIT_ASK_TIER = 4
Crises.SPLIT_HOLD = { field = "water", gun = "power" }     -- 외면당한 쪽이 쥐는 것
Crises.TRANSFORMER_DAYS = 5
Crises.TRANSFORMER_NEED = { { "Base.ElectricWire", 6 }, { "Base.ElectronicsScrap", 10 }, { "Base.Screwdriver", 1 } }
Crises.TRANSFORMER_REPAIR_MIN = 120                         -- 부품이 모인 뒤 변전소 둘레에 머물러야 하는 시간 (분)
Crises.TRANSFORMER_SITE_DAYS = 3
Crises.TRANSFORMER_RADIUS = 20
Crises.NIGHT_DAYS = 30
Crises.NIGHT_FROM, Crises.NIGHT_TO = 20, 6                 -- 이 사이에만 전기
Crises.RATION_PER = 10                                     -- 살아 있는 NPC 한 사람당 모자란 양
Crises.RATION_STEP = 5
Crises.RATION_MAX = 30
Crises.REFUGEES = 100
Crises.REFUGEE_STEP = 10
Crises.REFUGEE_MAX = 40
Crises.REFUGEE_FOOD = 5                                    -- 열 명당 그 거점 식량
Crises.REFUGEE_PROJECT = 30                                -- 열 명당 프로젝트 점수
Crises.QUARANTINE_DAYS = 14
Crises.QUARANTINE_SEAL = 15
Crises.QUARANTINE_TRUST = 10
Crises.BOAT_DAYS = 60
Crises.BOAT_HOLD = 15
Crises.ROUTE_PRICE = 0.75                                  -- 새 거래 길: 오델의 주문 값
Crises.TRIBUNAL_DAYS = 14

local function state()
    local d = Store.data()
    d.crises = d.crises or {}
    local s = d.crises
    s.seq = s.seq or 0
    s.done = s.done or {}
    s.fx = s.fx or {}
    return s
end

function Crises.state() return state() end

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

local function nameOf(fid) return tostring(Stories.NAMES[fid] or fid) end
local function trustOf(fid) return Radio.channel(fid).trust or 0 end

local function notify(kind, args)
    args = args or {}
    args.kind = kind
    pcall(Net.toAll, "crisisNotice", args)
end

local function news(text, now)
    if StoryEngine.Social and StoryEngine.Social.news then StoryEngine.Social.news("all", text) end
    for _, ps in pairs(Store.data().players) do
        if not ps.dead then Store.addNote(ps, { kind = "op", text = text, clock = now.clock }) end
    end
end

local function randDays(a, b) return (a + ZombRand(b - a + 1)) * 24 * 60 end

local function trust(fid, d, reason)
    if Factions.isGone(fid) or d == 0 then return 0 end
    return StoryEngine.Trust.apply(fid, d, reason)
end

local function leaderOf(bloc)
    local best, bt = nil, -1
    for _, fid in ipairs(StoryEngine.Politics.members(bloc)) do
        if trustOf(fid) > bt then best, bt = fid, trustOf(fid) end
    end
    return best
end

function Crises.enabled()
    local Pol = StoryEngine.Politics
    return Pol ~= nil and Pol.on() and (StoryEngine.option == nil or StoryEngine.option("PoliticalCrises") ~= false)
end

-- ---------------------------------------------------------------- 이어지는 효과

local function fxOn(name, now)
    local s = Store.data().crises
    local f = s and s.fx and s.fx[name]
    if not f then return nil end
    if f.untilT and (now or Sensor.now().t) >= f.untilT then return nil end
    return f
end

function Crises.split() return fxOn("split") end

-- Politics.mod 가 얹는 값: 곱할 값 | 참 | nil
function Crises.mod(key, fid, a)
    if key == "supermajority" then return fxOn("split") ~= nil or nil end
    if key == "specBlock" then
        if fid == "doc" and fxOn("quarantine") then return true end
        if fid == "casey" and fxOn("boat") then return true end
        if fid == "guard" and fxOn("tribunal") then return true end
    end
    if key == "tradeBlock" and fid == "casey" and fxOn("boat") then return true end
    return nil
end

-- 오델의 주문 값에 곱한다 (Outsiders.order): 케이시가 터 온 새 거래 길이 있으면 싸다
function Crises.orderMult()
    local s = Store.data().crises
    if s and s.fx and s.fx.route then return Crises.ROUTE_PRICE end
    return 1
end

-- 1차 특기가 막힌 까닭 (Specialty.status): nursing | upriver | confined | nil
function Crises.blockReason(fid)
    if fid == "doc" and fxOn("quarantine") then return "nursing" end
    if fid == "casey" and fxOn("boat") then return "upriver" end
    if fid == "guard" and fxOn("tribunal") then return "confined" end
    return nil
end

local function quietCut(kind)
    -- 단전·단수 사건(NPC 반응·일지)이 새로 나지 않게 이미 겪은 것으로 해 둔다
    local d = Store.data()
    d.world = d.world or {}
    d.world.done = d.world.done or {}
    if d.world.done[kind] == nil then d.world.done[kind] = -1 end
    pcall(StoryEngine.Grid.cut, kind, "crisis")
end

local function giveBack(kind)
    local Era = StoryEngine.Era
    pcall(StoryEngine.Grid.restore, kind, Era and Era.FOREVER_DAYS or 36500, "council")
end

-- ---------------------------------------------------------------- 위기별: 조건, 열기, 고르기, 무시

local DEF = {}

-- E3 갈라서는 의회
local function splitApart(snubbed, now, why)
    local s = state()
    local hold = snubbed == "both" and (ZombRand(2) == 0 and "water" or "power") or Crises.SPLIT_HOLD[snubbed]
    s.fx.split = { untilT = now.t + Crises.SPLIT_DAYS * 24 * 60, snubbed = snubbed, hold = hold }
    if hold then quietCut(hold) end
    news("The county council has split in two: the farms and the church on one side, the soldiers and hunters on the other. "
        .. "For a month nothing passes without two votes in three" .. (hold and (", and one side has shut off the " .. hold) or "") .. ".", now)
    notify("split", { snubbed = snubbed, hold = hold, why = why })
    log("crisis split", tostring(snubbed), tostring(hold), tostring(why))
end

DEF.split = {
    options = { "field", "gun", "both" },
    when = function()
        local P = StoryEngine.Politics
        return #P.members("field") >= 2 and #P.members("gun") >= 2
    end,
    open = function(cur, now)
        local a, b = leaderOf("field"), leaderOf("gun")
        cur.leaders = { field = a, gun = b }
        pcall(Radio.react, a, "crisis", "You and the others of the farms and the church have had enough of sitting in council with "
            .. "the soldiers and hunters. You mean to meet on your own from now on. Tell the players and ask them to stand with you.", nil, nil)
        pcall(Radio.react, b, "crisis", "You and the other soldiers and hunters have had enough of the farms and the church "
            .. "talking the council in circles. You mean to meet on your own from now on. Tell the players and ask them to stand with you.", nil, nil)
    end,
    choose = function(cur, opt, player, ps, now)
        local P = StoryEngine.Politics
        if opt == "both" then
            -- 양쪽의 큰 부탁을 모두 해내면 갈라서지 않는다
            cur.asks = {}
            for _, bloc in ipairs({ "field", "gun" }) do
                local fid = cur.leaders[bloc] or leaderOf(bloc)
                local q = fid and Quests.propose(player, ps, fid, Crises.SPLIT_ASK_TIER, now) or nil
                if q then
                    q.splitAsk = bloc
                    q.deadlineT = now.t + Crises.SPLIT_ASK_DAYS * 24 * 60
                    Quests.respond(player, q.id, true)
                    cur.asks[bloc] = q.id
                end
            end
            if not (cur.asks.field and cur.asks.gun) then return false, "no_ask" end
            cur.waiting = true
            cur.untilT = now.t + (Crises.SPLIT_ASK_DAYS + 1) * 24 * 60
            return true, true
        end
        local other = opt == "field" and "gun" or "field"
        for _, fid in ipairs(P.members(opt)) do trust(fid, Crises.SPLIT_GAIN, "split_chosen") end
        for _, fid in ipairs(P.members(other)) do trust(fid, -Crises.SPLIT_LOSS, "split_snubbed") end
        P.state().lean[opt] = math.min(100, (P.state().lean[opt] or 0) + Crises.SPLIT_LEAN)
        splitApart(other, now, "chosen")
        return true
    end,
    ignore = function(cur, now)
        for _, bloc in ipairs({ "field", "gun" }) do
            for _, fid in ipairs(StoryEngine.Politics.members(bloc)) do trust(fid, -Crises.SPLIT_LOSS, "split_snubbed") end
        end
        splitApart("both", now, cur.waiting and "asks_failed" or "ignored")
    end,
}

-- E5 타 버린 변압기
DEF.transformer = {
    options = {},
    when = function() return StoryEngine.Grid.isRestored("power") == true end,
    open = function(cur, now)
        local players = Sensor.players()
        local ps = players[1] and Store.player(players[1])
        if not ps then return false end
        local ok, q = pcall(Quests.createCollect, ps, Crises.TRANSFORMER_NEED, now,
            { politics = "transformer", source = "politics", faction = "casey" }, now.t + Crises.TRANSFORMER_DAYS * 24 * 60)
        if not ok or not q then return false end
        cur.collect = q.id
        cur.untilT = now.t + Crises.TRANSFORMER_DAYS * 24 * 60
        local host = Factions.isGone("casey") and living()[1] or "casey"
        if host then
            pcall(Radio.react, host, "crisis", "The big transformer burned out now that the county is drawing power again. Without "
                .. "wire, electronics and tools to rebuild it, the power will only run at night for a month. Ask the players to gather the parts.", nil, nil)
        end
        return true
    end,
    done = function(cur, now)
        local quests = Store.data().quests
        local q = quests[cur.collect or ""]
        if not (q and q.state == "completed") then return false end
        if cur.noSite then return true end
        if not cur.site then
            -- 부품이 모였다: 가장 가까운 변전소에 가서 수리하는 동안 곁을 지킨다
            local players = Sensor.players()
            local p = players[1]
            local Sites = StoryEngine.OpsSites
            local site = p and Sites and Sites.byDistance(Sites.SUBSTATIONS, p:getX(), p:getY())[1] or nil
            local ok, sq = false, nil
            if site then
                ok, sq = pcall(Quests.createSite, "defend", Store.player(p), { x = site.x, y = site.y, name = "substation" }, now,
                    { crisis2 = "transformer", source = "politics", faction = "casey" },
                    { needMin = Crises.TRANSFORMER_REPAIR_MIN, radius = Crises.TRANSFORMER_RADIUS, tier = 3,
                      deadlineT = now.t + Crises.TRANSFORMER_SITE_DAYS * 24 * 60 })
            end
            if ok and sq then
                cur.site = sq.id
                cur.untilT = now.t + Crises.TRANSFORMER_SITE_DAYS * 24 * 60
                local host = Factions.isGone("casey") and living()[1] or "casey"
                if host then
                    pcall(Radio.react, host, "crisis", "The parts for the burned transformer are in. Now someone has to stand at the "
                        .. "substation for a couple of hours while it is rebuilt. Tell the players where (it is in their quest log).", nil, nil)
                end
                notify("transformer_site", {})
                return false
            end
            cur.noSite = true           -- 자리를 만들지 못했다: 부품만으로 끝난 것으로 친다
            return true
        end
        local sq = quests[cur.site]
        return sq ~= nil and sq.state == "completed"
    end,
    finish = function(cur, now)
        for _, fid in ipairs(living()) do pcall(Life.change, fid, "morale", 5, "crisis") end
        news("The burned transformer was rebuilt with parts the survivors gathered. The lights stay on.", now)
        notify("transformer_done", {})
    end,
    ignore = function(cur, now)
        for _, id in ipairs({ cur.collect or "", cur.site or "" }) do
            local q = Store.data().quests[id]
            if q and Quests.isActive(q) then pcall(Quests.setState, q, "failed", now) end
        end
        state().fx.night = { untilT = now.t + Crises.NIGHT_DAYS * 24 * 60 }
        news("Nobody rebuilt the burned transformer. For a month the county has power only at night.", now)
        notify("night", { days = Crises.NIGHT_DAYS })
    end,
}

-- E7 배급 (겨울)
local function rationApply(cur, shares, now, by)
    for fid, cut in pairs(shares) do
        if cut > 0 then
            pcall(Life.change, fid, "food", -cut, "crisis")
            trust(fid, -math.floor(cut / 10), "ration_cut")
        end
    end
    news("The winter stores ran short and the council " .. (by and ("let " .. by .. " decide") or "argued over") .. " whose share to cut.", now)
    notify("ration_done", {})
end

DEF.ration = {
    options = {},
    allot = true,
    repeatKey = function()
        local W = StoryEngine.World
        local ok, y = pcall(function() return W.winterYear and W.winterYear() or getGameTime():getYear() end)
        return "ration_" .. tostring(ok and y or 0)
    end,
    when = function()
        local W = StoryEngine.World
        local ok, winter = pcall(function() return W.WINTER_MONTHS[getGameTime():getMonth()] == true end)
        return ok and winter == true
    end,
    open = function(cur, now)
        local ids = living()
        cur.rows = ids
        cur.total = #ids * Crises.RATION_PER
        cur.step, cur.max = Crises.RATION_STEP, Crises.RATION_MAX
        local host = Factions.isGone("ray") and ids[1] or "ray"
        pcall(Radio.react, host, "crisis", "The county's winter food is short. Someone's share has to be cut, and the council "
            .. "wants the players to decide whose and by how much. Say so plainly; nobody will thank them for it.", nil, nil)
    end,
    allotOk = function(cur, shares)
        local sum = 0
        for fid, n in pairs(shares) do
            if not has(cur.rows, fid) or n < 0 or n > cur.max or n % cur.step ~= 0 then return false, "bad_share" end
            sum = sum + n
        end
        if sum ~= cur.total then return false, "bad_total" end
        return true
    end,
    choose = function(cur, shares, player, ps, now)
        rationApply(cur, shares, now, ps.name)
        return true
    end,
    ignore = function(cur, now)
        -- 아무도 정하지 않았다: 고르게 줄고, 모두가 서운해한다
        local shares = {}
        for _, fid in ipairs(cur.rows) do
            shares[fid] = Crises.RATION_PER
            trust(fid, -1, "ration_cut")
        end
        rationApply(cur, shares, now, nil)
    end,
}

-- E8 난민 행렬
DEF.refugees = {
    options = {},
    allot = true,
    when = function() return #living() >= 3 end,
    open = function(cur, now)
        cur.rows = living()
        cur.total, cur.step, cur.max, cur.partial = Crises.REFUGEES, Crises.REFUGEE_STEP, Crises.REFUGEE_MAX, true
        local host = Factions.isGone("pike") and cur.rows[1] or "pike"
        pcall(Radio.react, host, "crisis", "About a hundred refugees have come to the county line with nothing. The council wants "
            .. "the players to decide whether to take them in, and which settlement takes how many. Plead for them.", nil, nil)
    end,
    allotOk = function(cur, shares)
        local sum = 0
        for fid, n in pairs(shares) do
            if not has(cur.rows, fid) or n < 0 or n > cur.max or n % cur.step ~= 0 then return false, "bad_share" end
            sum = sum + n
        end
        if sum > cur.total then return false, "bad_total" end
        return true
    end,
    choose = function(cur, shares, player, ps, now)
        local taken = 0
        for fid, n in pairs(shares) do
            if n > 0 then
                taken = taken + n
                local tens = n / Crises.REFUGEE_STEP
                pcall(Life.change, fid, "food", -Crises.REFUGEE_FOOD * tens, "crisis")
                if StoryEngine.Projects then pcall(StoryEngine.Projects.add, fid, Crises.REFUGEE_PROJECT * tens, ps.name, "refugees") end
                if n > 20 then trust(fid, -1, "refugee_burden") end
            end
        end
        local away = Crises.REFUGEES - taken
        local loss = math.min(5, math.floor(away / 20))
        if loss > 0 then
            trust("pike", -loss, "refugees_turned")
            trust("doc", -loss, "refugees_turned")
        elseif taken > 0 then
            trust("pike", 1, "refugees_taken")
            trust("doc", 1, "refugees_taken")
        end
        news(StoryEngine.intToString(taken) .. " of the hundred refugees at the county line were taken in"
            .. (away > 0 and ("; the other " .. StoryEngine.intToString(away) .. " were turned away.") or "."), now)
        notify("refugees_done", { taken = taken, away = away })
        return true
    end,
    ignore = function(cur, now)
        trust("pike", -5, "refugees_turned")
        trust("doc", -5, "refugees_turned")
        news("Nobody answered for the refugees at the county line. They moved on.", now)
        notify("refugees_done", { taken = 0, away = Crises.REFUGEES })
    end,
}

-- E9 격리
local function quarantineOpen(cur, now)
    state().fx.quarantine = { untilT = now.t + Crises.QUARANTINE_DAYS * 24 * 60 }
    local pool = {}
    for _, fid in ipairs(living()) do
        if fid ~= cur.sick and fid ~= "doc" then pool[#pool + 1] = fid end
    end
    local spread = {}
    for _ = 1, 2 do
        if #pool > 0 then
            local fid = table.remove(pool, ZombRand(#pool) + 1)
            spread[#spread + 1] = fid
            pcall(Life.change, fid, "medical", -15, "crisis")
            pcall(Life.change, fid, "morale", -10, "crisis")
        end
    end
    cur.spread = spread
    local names = {}
    for _, fid in ipairs(spread) do names[#names + 1] = nameOf(fid) end
    news("The fever at " .. nameOf(cur.sick) .. "'s place was not sealed off. Doc Adler went to nurse them and is out of reach for "
        .. "two weeks, and it spread to " .. (#names > 0 and table.concat(names, " and ") or "nobody else") .. ".", now)
    notify("quarantine_open", { sick = cur.sick, spread = spread })
end

DEF.quarantine = {
    options = { "seal", "open" },
    when = function() return not Factions.isGone("doc") and #living() >= 3 end,
    open = function(cur, now)
        local pool = {}
        for _, fid in ipairs(living()) do
            if fid ~= "doc" then pool[#pool + 1] = fid end
        end
        cur.sick = pool[ZombRand(#pool) + 1]
        pcall(Radio.react, cur.sick, "crisis", "A fever is going through your people. Some on the council want your place sealed "
            .. "off until it burns out. You want Doc Adler sent instead. Ask the players not to shut you in.", nil, nil)
        pcall(Radio.react, "doc", "crisis", "A fever is going through " .. nameOf(cur.sick) .. "'s people. You can go and nurse "
            .. "them, but you would be gone two weeks and it may spread. Sealing them off is safer and crueller. Lay out both, as a nurse.", nil, nil)
    end,
    choose = function(cur, opt, player, ps, now)
        if opt == "seal" then
            for _, res in ipairs({ "food", "medical", "safety", "morale" }) do
                pcall(Life.change, cur.sick, res, -Crises.QUARANTINE_SEAL, "crisis")
            end
            trust(cur.sick, -Crises.QUARANTINE_TRUST, "quarantine_sealed")
            news(nameOf(cur.sick) .. "'s place was sealed off until the fever burned out. They will not forget who shut the gate.", now)
            notify("quarantine_seal", { sick = cur.sick })
        else
            trust(cur.sick, 2, "quarantine_helped")
            quarantineOpen(cur, now)
        end
        return true
    end,
    ignore = function(cur, now)
        trust(cur.sick, -3, "quarantine_ignored")
        quarantineOpen(cur, now)
    end,
}

-- E15 케이시의 배
DEF.boat = {
    options = { "hold", "let" },
    when = function()
        return not Factions.isGone("casey") and not (Factions.voice and Factions.voice.casey)
            and StoryEngine.Outsiders ~= nil and StoryEngine.Outsiders.isHere("odell")
    end,
    open = function(cur, now)
        pcall(Radio.react, "casey", "crisis", "Captain Odell's barges are heading upriver and you want to go with them: there is "
            .. "said to be a working station out there. You would be gone two months. Ask the players what they think; you want to go.", nil, nil)
    end,
    choose = function(cur, opt, player, ps, now)
        if opt == "hold" then
            pcall(Life.change, "casey", "morale", -Crises.BOAT_HOLD, "crisis")
            news("Casey wanted to go upriver with the barges to look for another station. She was talked out of it.", now)
            notify("boat_hold", {})
        else
            state().fx.boat = { untilT = now.t + Crises.BOAT_DAYS * 24 * 60, t = now.t }
            trust("casey", 3, "boat_let")
            news("Casey went upriver on Odell's barges to look for another station. Her frequency will be thin for two months.", now)
            notify("boat_let", { days = Crises.BOAT_DAYS })
        end
        return true
    end,
    ignore = function(cur, now)
        pcall(Life.change, "casey", "morale", -Crises.BOAT_HOLD, "crisis")
        trust("casey", -2, "boat_ignored")
        notify("boat_hold", {})
    end,
}

-- E16 휘태커의 군법회의
local function tribunalTestify(now)
    trust("hale", 5, "tribunal_hale")
    trust("guard", -10, "tribunal_betrayed")
    state().fx.tribunal = { untilT = now.t + Crises.TRIBUNAL_DAYS * 24 * 60 }
    news("Colonel Hale court-martialled Sergeant Whitaker for refusing orders. Whitaker is confined to quarters for two weeks.", now)
    notify("tribunal_testify", {})
end

DEF.tribunal = {
    options = { "testify", "hide", "refuse" },
    when = function()
        return not Factions.isGone("guard") and not (Factions.voice and Factions.voice.guard)
            and StoryEngine.Outsiders ~= nil and StoryEngine.Outsiders.isHere("hale")
    end,
    open = function(cur, now)
        pcall(Radio.react, "hale", "crisis", "Sergeant Whitaker refused a lawful order when the Guard was first cut off. You mean to "
            .. "court-martial him and you want the players to testify to what they have seen of him.", nil, nil)
        pcall(Radio.react, "guard", "crisis", "Colonel Hale means to court-martial you for an order you refused when the county was "
            .. "cut off. You would do it again. Ask the players, stiffly, not to hand him what he wants.", nil, nil)
    end,
    choose = function(cur, opt, player, ps, now)
        if opt == "testify" then
            tribunalTestify(now)
        elseif opt == "hide" then
            trust("guard", 5, "tribunal_guard")
            trust("hale", -10, "tribunal_refused")
            news("The players would not testify against Sergeant Whitaker. Colonel Hale dropped the court-martial, for now.", now)
            notify("tribunal_hide", {})
        else
            -- 의회 이름으로 거부: 표결이 통과돼야 한다
            local bill = StoryEngine.Politics.systemBill("refuse", { target = "hale", gain = { "guard" }, owner = "crises",
                text = "refusing, in the council's name, to let Colonel Hale court-martial Sergeant Whitaker" }, now)
            if not bill then return false, "bill_busy" end
            cur.waiting, cur.vote = true, true
            cur.untilT = now.t + (StoryEngine.Politics.PREP_DAYS + 1) * 24 * 60
            return true, true
        end
        return true
    end,
    ignore = function(cur, now)
        if cur.vote then return end                      -- 표결이 정한다 (Crises.onVote)
        trust("guard", -3, "tribunal_ignored")
        tribunalTestify(now)
    end,
}

Crises.DEF = DEF

-- 의회 표결의 결과 (Politics.vote, owner = "crises")
function Crises.onVote(bill, pass, now)
    local s = state()
    local cur = s.current
    if bill.id ~= "refuse" or not cur or cur.id ~= "tribunal" then return end
    if pass then
        trust("hale", -5, "tribunal_refused")
        trust("guard", 3, "tribunal_guard")
        for _, fid in ipairs(living()) do
            if fid ~= "guard" then trust(fid, 1, "tribunal_council") end
        end
        news("The county council refused, in its own name, to let Colonel Hale court-martial Sergeant Whitaker.", now)
        notify("tribunal_refused", {})
    else
        tribunalTestify(now)
    end
    Crises.close(now, "voted")
end

-- ---------------------------------------------------------------- 엔진

function Crises.close(now, why)
    local s = state()
    local cur = s.current
    if not cur then return end
    local def = DEF[cur.id]
    s.done[def.repeatKey and def.repeatKey() or cur.id] = Store.serverDays()
    s.current = nil
    s.nextT = now.t + randDays(Crises.GAP_MIN_DAYS, Crises.GAP_MAX_DAYS)
    log("crisis closed", cur.id, tostring(why))
end

local function available(id)
    local s = state()
    local def = DEF[id]
    if not def then return false end
    if s.done[def.repeatKey and def.repeatKey() or id] then return false end
    local ok, yes = pcall(def.when)
    return ok and yes == true
end

-- 연다. id 가 없으면 지금 열 수 있는 것 가운데 무작위. 반환: cur | nil
function Crises.start(id, now)
    local s = state()
    if s.current then return nil end
    now = now or Sensor.now()
    if not id then
        local pool = {}
        for _, x in ipairs(Crises.ORDER) do
            if available(x) then pool[#pool + 1] = x end
        end
        if #pool == 0 then return nil end
        id = pool[ZombRand(#pool) + 1]
    end
    local def = DEF[id]
    if not def then return nil end
    s.seq = s.seq + 1
    local cur = { id = id, seq = s.seq, t = now.t, untilT = now.t + Crises.ANSWER_HOURS * 60 }
    s.current = cur
    local ok, res = pcall(def.open, cur, now)
    if not ok or res == false then
        log("crisis open failed", id, tostring(res))
        s.current = nil
        return nil
    end
    notify("open", { id = id })
    log("crisis open", id)
    return cur
end

-- 고른다. what = 선택지 id (택일) 또는 { [fid] = 몫 } (배분). 반환: true | false, 이유
function Crises.choose(player, what)
    local s = state()
    local cur = s.current
    if not cur then return false, "no_crisis" end
    if cur.waiting then return false, "waiting" end
    local def = DEF[cur.id]
    local now = Sensor.now()
    local ps = Store.player(player)
    if def.inquiry then return false, "inquiry" end      -- 조사는 묻고 판결하는 것으로 (Inquiry.judge)
    if def.allot then
        if type(what) ~= "table" then return false, "how" end
        local shares = {}
        for fid, n in pairs(what) do shares[tostring(fid)] = math.floor(tonumber(n) or 0) end
        local okA, whyA = def.allotOk(cur, shares)
        if not okA then return false, whyA end
        what = shares
    else
        if not has(def.options, what) then return false, "how" end
    end
    local ok, res, keep = pcall(def.choose, cur, what, player, ps, now)
    if not ok then
        log("crisis choose error:", cur.id, tostring(res))
        return false, "error"
    end
    if res == false then return false, keep end
    cur.chosen, cur.by = type(what) == "table" and "allot" or what, ps.name
    if not keep then Crises.close(now, "chosen") end
    return true
end

-- 갈라서는 의회에서 양쪽 부탁을 모두 해냈는가
local function onQuest(q, st)
    local s = Store.data().crises
    local cur = s and s.current
    if not cur or cur.id ~= "split" or not cur.asks or not q.splitAsk then return end
    if st ~= "completed" and st ~= "failed" and st ~= "declined" then return end
    local now = Sensor.now()
    local all, failed = true, false
    for _, bloc in ipairs({ "field", "gun" }) do
        local x = Store.data().quests[cur.asks[bloc] or ""]
        if not x or x.state ~= "completed" then all = false end
        if x and (x.state == "failed" or x.state == "declined") then failed = true end
    end
    if all then
        for _, bloc in ipairs({ "field", "gun" }) do
            for _, fid in ipairs(StoryEngine.Politics.members(bloc)) do trust(fid, Crises.SPLIT_GAIN, "split_mended") end
        end
        news("Both sides of the council got what they asked for, and nobody walked out. The council holds.", now)
        notify("split_mended", {})
        Crises.close(now, "mended")
    elseif failed then
        DEF.split.ignore(cur, now)
        Crises.close(now, "asks_failed")
    end
end
Quests.hooks[#Quests.hooks + 1] = function(q, st)
    local ok, err = pcall(onQuest, q, st)
    if not ok then log("crisis quest hook error:", tostring(err)) end
end

local function fxTick(now)
    local s = state()
    local fx = s.fx
    -- 갈라선 의회가 다시 모인다
    if fx.split and now.t >= fx.split.untilT then
        if fx.split.hold then giveBack(fx.split.hold) end
        fx.split = nil
        news("The two halves of the county council sat down together again.", now)
        notify("split_over", {})
    end
    -- 밤에만 전기
    if fx.night then
        if now.t >= fx.night.untilT then
            fx.night = nil
            giveBack("power")
            notify("night_over", {})
        else
            local hour = getGameTime():getHour()
            local on = hour >= Crises.NIGHT_FROM or hour < Crises.NIGHT_TO
            if fx.night.on == nil or on ~= fx.night.on then
                fx.night.on = on
                if on then giveBack("power") else quietCut("power") end
            end
        end
    end
    if fx.quarantine and now.t >= fx.quarantine.untilT then fx.quarantine = nil end
    -- 조사 틀: 유도신문, 한 달 뒤 드러나는 틀린 판결, 오염된 물 (Inquiry.lua)
    if StoryEngine.Inquiry then StoryEngine.Inquiry.tick(now) end
    if fx.tribunal and now.t >= fx.tribunal.untilT then fx.tribunal = nil end
    -- 케이시가 돌아온다
    if fx.boat and now.t >= fx.boat.untilT then
        fx.boat = nil
        if not Factions.isGone("casey") then
            fx.route = { t = now.t }
            for _, fid in ipairs(living()) do pcall(Life.change, fid, "morale", 10, "crisis") end
            trust("casey", 5, "boat_back")
            pcall(Radio.react, "casey", "event", "You are back from two months upriver on Odell's barges. You found the station, and "
                .. "people, and a trade route that makes river goods cheaper. Tell the players, breathless.", nil, nil)
            news("Casey came back from upriver with news of another station and a new trade route on the river.", now)
            notify("boat_back", {})
        end
    end
end

function Crises.tick(now)
    now = now or Sensor.now()
    if not Crises.enabled() then return end
    local s = state()
    local ok, err = pcall(fxTick, now)
    if not ok then log("crisis fx error:", tostring(err)) end
    if #Sensor.players() == 0 then return end
    local Pol = StoryEngine.Politics
    s.nextT = s.nextT or ((Pol.state().openT or now.t) + Crises.FIRST_DAYS * 24 * 60)
    local cur = s.current
    if cur then
        local def = DEF[cur.id]
        if def.done and def.done(cur, now) then
            pcall(def.finish, cur, now)
            Crises.close(now, "done")
        elseif now.t >= cur.untilT then
            local okI, errI = pcall(def.ignore, cur, now)
            if not okI then log("crisis ignore error:", cur.id, tostring(errI)) end
            if s.current == cur then Crises.close(now, "ignored") end
        end
        return
    end
    if now.t < s.nextT then return end
    if StoryEngine.Saga and StoryEngine.Saga.active() then return end
    local Out = StoryEngine.Outsiders
    if Out then
        for _, id in ipairs(Out.hereList()) do
            if Out.state().here[id].test then return end
        end
    end
    if not Crises.start(nil, now) then s.nextT = now.t + 24 * 60 end
end

-- ---------------------------------------------------------------- 클라이언트로

function Crises.payload(key, now)
    if not Crises.enabled() then return nil end
    local s = state()
    now = now or Sensor.now()
    local out = { fx = {} }
    for _, name in ipairs({ "split", "night", "quarantine", "boat", "tribunal", "sick" }) do
        local f = fxOn(name, now.t)
        if f then
            out.fx[#out.fx + 1] = { id = name, days = math.max(0, math.ceil((f.untilT - now.t) / 60 / 24)),
                                    snubbed = f.snubbed, hold = f.hold }
        end
    end
    if s.fx.route then out.fx[#out.fx + 1] = { id = "route" } end
    local cur = s.current
    if cur then
        local def = DEF[cur.id]
        local c = { id = cur.id, hours = math.max(0, math.ceil((cur.untilT - now.t) / 60)), options = def.options,
                    waiting = cur.waiting, vote = cur.vote, sick = cur.sick, leaders = cur.leaders, collect = cur.collect,
                    site = cur.site }
        if def.allot then
            c.allot = { total = cur.total, step = cur.step, max = cur.max, partial = cur.partial, rows = {} }
            for _, fid in ipairs(cur.rows or {}) do
                c.allot.rows[#c.allot.rows + 1] = { fid = fid, trust = trustOf(fid), food = Life.get(fid, "food") }
            end
        end
        if cur.case and StoryEngine.Inquiry then c.case = StoryEngine.Inquiry.payload(cur, key) end
        out.current = c
    end
    if StoryEngine.Inquiry then out.probe = StoryEngine.Inquiry.probePayload() end
    return out
end

Crises.LABEL = {
    split = "the council nearly splitting in two", transformer = "the burned transformer", ration = "the winter rationing",
    refugees = "the refugee column at the county line", quarantine = "the fever and the quarantine", boat = "Casey's trip upriver",
    tribunal = "the court-martial of Sergeant Whitaker", warehouse = "the thefts from the council stores",
    trial = "the trial over a killing between two settlements", water = "the fouled water", pirate = "the pirate broadcasts",
}

-- 지나간 위기 (두 번째 연대기). 반환: id 목록, 영어 문장 목록
function Crises.history()
    local s = Store.data().crises
    local ids, texts, seen = {}, {}, {}
    for _, id in ipairs(Crises.ORDER) do
        for key in pairs(s and s.done or {}) do
            if not seen[id] and (key == id or string.sub(key, 1, #id + 1) == id .. "_") then
                seen[id] = true
                ids[#ids + 1] = id
                texts[#texts + 1] = Crises.LABEL[id] or id
            end
        end
    end
    return ids, texts
end

function Crises.debug(args)
    local s = state()
    local now = Sensor.now()
    local what = tostring(args.what or "")
    if what == "start" then
        if s.current then Crises.close(now, "debug") end
        local id = tostring(args.id or "")
        s.done[id] = nil
        if DEF[id] and DEF[id].repeatKey then s.done[DEF[id].repeatKey()] = nil end
        if not Crises.start(DEF[id] and id or nil, now) then return "crisis: could not start " .. id end
    elseif what == "expire" and s.current then
        s.current.untilT = now.t
        Crises.tick(now)
    elseif what == "reset" then
        local fx = s.fx
        if fx.split and fx.split.hold then giveBack(fx.split.hold) end
        if fx.night then giveBack("power") end
        Store.data().crises = nil
    end
    return Crises.statusText()
end

function Crises.statusText()
    local s = Store.data().crises
    if not s then return "crises -" end
    local fx = {}
    for name in pairs(s.fx or {}) do fx[#fx + 1] = name end
    table.sort(fx)
    local now = Sensor.now()
    return "crises current=" .. tostring(s.current and s.current.id or "none") .. " fx=" .. (#fx > 0 and table.concat(fx, ",") or "none")
        .. " next=" .. tostring(s.nextT and math.floor((s.nextT - now.t) / (24 * 60)) or nil) .. "d"
end

Events.EveryHours.Add(function()
    local ok, err = pcall(Crises.tick)
    if not ok then log("crisis tick error:", tostring(err)) end
end)

return Crises
