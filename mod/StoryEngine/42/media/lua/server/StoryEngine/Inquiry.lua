-- 조사 틀을 쓰는 정치 위기 (2026-10-13, docs/PLAN_COUNCIL_POLITICS.md 8단계, 확정안은 docs/IDEAS_COUNCIL_ERA.md 12-3).
--
--   warehouse E2 빼돌린 창고: 용의자 셋 가운데 범인을 찾아 공개 / 덮기 / 당사자에게만 알림
--   trial     E4 재판: 살인인가 사고인가 정당방위인가 -> 추방 / 배상 / 무죄
--   water     E6 오염된 물: 사체인가 사고인가 사람 짓인가 (사람 짓이면 재판으로 이어진다)
--   pirate    E17 해적 방송: 발신지가 누구인가 (불만 품은 NPC 면 부탁으로, 밖에서 온 사람이면 추방 표결로)
--
-- 진상은 게임이 미리 정한다 (AI 는 말투만 입힌다). 답 셋(answers) 가운데 하나가 진실(truth)이다.
-- 단서 여섯: 현장 둘(그 자리에 가서 머묾) / 물증 둘(그 자리에서 찾음) / 증언 둘(NPC 에게 묻기).
--   단서는 "○○ 은 아니다"(clears) 이거나 "○○ 을 가리킨다"(points). 증언 하나는 거짓이고 물증 하나와 모순된다:
--   그 물증을 찾은 뒤 다시 물으면(confront) 진짜 말을 한다. 신뢰 TALK_TRUST 미만인 NPC 는 입을 열지 않는다.
--   NEED(넷)을 모으면 판결할 수 있다. 수첩에는 사실만 쌓이고 결론은 플레이어가 낸다. 기한 DAYS(5일).
--   틀린 판결은 REVEAL_DAYS(30일) 뒤에 드러난다.
-- 빼돌린 창고를 덮으면 PROBE_DAYS(7일) 동안 의심하는 NPC 가 떠본다 (유도신문). 플레이어의 답은 브릿지의 judge 모듈이
--   none / hint / named 로 판정한다 (NPC 대사 쪽에는 범인 이름을 주지 않는다). named 한 번이나 hint 두 번이면 들킨다.
--   AI 가 없으면 메뉴의 세 가지 대답(모른다 / 얼버무린다 / 털어놓는다)으로 한다.
--
-- Crises.lua 의 틀에 얹힌다 (Crises.DEF 에 넷을 더한다). 상태는 d.crises.current.case 와 d.crises.fx.probe·reveal·sick.

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
require "StoryEngine/Bridge"
require "StoryEngine/Crises"

local Inquiry = {}
StoryEngine.Inquiry = Inquiry

local Net = StoryEngine.Net
local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Radio = StoryEngine.Radio
local Life = StoryEngine.Life
local Quests = StoryEngine.Quests
local Stories = StoryEngine.Stories
local Crises = StoryEngine.Crises
local log = StoryEngine.log

Inquiry.DAYS = 5
Inquiry.NEED = 4
Inquiry.TALK_TRUST = 40
Inquiry.REVEAL_DAYS = 30
Inquiry.SITE_MIN, Inquiry.SITE_MAX = 150, 350
Inquiry.SITE_RADIUS = 10
Inquiry.EVIDENCE = "StoryEngine.Evidence"
Inquiry.PROBE_DAYS = 7
Inquiry.PROBE_GAP_HOURS = 48
Inquiry.PROBE_ANSWER_HOURS = 24
Inquiry.PROBE_HINTS = 2
Inquiry.SICK_DAILY = 3
Inquiry.SICK_DAYS = 14
Inquiry.KINDS = { "warehouse", "trial", "water", "pirate" }
Inquiry.HOWS = { warehouse = { "public", "cover", "private" } }
Inquiry.FIXED = { trial = { "murder", "accident", "defence" }, water = { "carcass", "accident", "sabotage" } }

local function crises() return Crises.state() end

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

local function trust(fid, d, reason)
    if not Factions.byId[fid] or Factions.isGone(fid) or d == 0 then return 0 end
    return StoryEngine.Trust.apply(fid, d, reason)
end

local function notify(kind, args)
    args = args or {}
    args.kind = kind
    pcall(Net.toAll, "inquiryNotice", args)
end

local function news(text, now)
    if StoryEngine.Social and StoryEngine.Social.news then StoryEngine.Social.news("all", text) end
    for _, ps in pairs(Store.data().players) do
        if not ps.dead then Store.addNote(ps, { kind = "op", text = text, clock = now.clock }) end
    end
end

local function take(pool)
    if #pool == 0 then return nil end
    return table.remove(pool, ZombRand(#pool) + 1)
end

-- ---------------------------------------------------------------- 사건을 짠다

local function answersFor(kind)
    if Inquiry.FIXED[kind] then
        local out = {}
        for _, a in ipairs(Inquiry.FIXED[kind]) do out[#out + 1] = a end
        return out
    end
    local pool = living()
    if kind == "pirate" then
        -- 불만이 큰 사람들 (신뢰가 낮은 순) + 와 있으면 밖에서 온 사람 하나
        table.sort(pool, function(a, b) return trustOf(a) < trustOf(b) end)
        local out = { pool[1], pool[2] }
        local Out = StoryEngine.Outsiders
        local here = Out and Out.hereList() or {}
        out[3] = #here > 0 and here[ZombRand(#here) + 1] or pool[3]
        return out
    end
    return { take(pool), take(pool), take(pool) }
end

local function siteNear(player, i, n)
    local a = (i / n) * math.pi * 2 + ZombRand(60) * math.pi / 180
    local d = Inquiry.SITE_MIN + ZombRand(Inquiry.SITE_MAX - Inquiry.SITE_MIN + 1)
    return { x = math.floor(player:getX() + math.cos(a) * d), y = math.floor(player:getY() + math.sin(a) * d), name = "inquiry" }
end

-- 반환: 참 | 거짓 (열지 못함)
function Inquiry.open(kind, cur, now)
    local players = Sensor.players()
    if #players == 0 then return false end
    local answers = answersFor(kind)
    if not (answers[1] and answers[2] and answers[3]) then return false end
    local order = { 1, 2, 3 }
    local truth = answers[table.remove(order, ZombRand(3) + 1)]
    local framed = answers[table.remove(order, ZombRand(2) + 1)]
    local third = answers[order[1]]
    -- 증인 둘: 거짓말하는 쪽은 범인 자신(원래 NPC 일 때)이거나 감싸는 사람
    local pool = living()
    local liar = nil
    if Factions.byId[truth] and not Factions.isOutsider(truth) and not Factions.isGone(truth) then liar = truth end
    for i = #pool, 1, -1 do
        if pool[i] == liar then table.remove(pool, i) end
    end
    liar = liar or take(pool)
    local witness = take(pool)
    if not liar or not witness then return false end
    local case = { kind = kind, answers = answers, truth = truth, framed = framed, liar = liar, found = 0,
                   clues = {
                       { n = 1, kind = "site", clears = third },
                       { n = 2, kind = "site", points = truth },
                       { n = 3, kind = "item", clears = framed },          -- 거짓 증언과 모순되는 물증
                       { n = 4, kind = "item", points = truth },
                       { n = 5, kind = "word", fid = witness, clears = third },
                       { n = 6, kind = "word", fid = liar, lie = true, points = framed },
                   } }
    if kind == "trial" then
        local parties = living()
        case.victim, case.accused = take(parties), take(parties)
        if not case.victim or not case.accused then return false end
    end
    cur.case = case
    cur.untilT = now.t + Inquiry.DAYS * 24 * 60
    -- 현장과 물증: 가까운 네 자리
    local p = players[ZombRand(#players) + 1]
    local ps = Store.player(p)
    for i = 1, 4 do
        local clue = case.clues[i]
        local ok, q = pcall(Quests.createSite, "visit", ps, siteNear(p, i, 4), now,
            { inquiry = cur.seq, clue = i, source = "politics" }, { radius = Inquiry.SITE_RADIUS, tier = 2, deadlineT = cur.untilT })
        if ok and q then
            clue.qid = q.id
        else
            clue.found = true               -- 자리를 만들지 못했다: 소문으로 들은 것으로 친다
            case.found = case.found + 1
        end
    end
    local host = Factions.isGone("casey") and living()[1] or "casey"
    local topic = ({
        warehouse = "Supplies have been going missing from the council's common stores. Someone on the council is taking them. "
            .. "Ask the players to look into it quietly: there are places to check and people to ask.",
        trial = "Someone from " .. nameOf(case.accused or "") .. "'s place killed someone from " .. nameOf(case.victim or "")
            .. "'s place. Nobody agrees on what happened. The council wants the players to find out and judge it.",
        water = "People who drank the tap water are falling sick. Something is wrong upstream. Ask the players to find out what.",
        pirate = "Someone has been broadcasting at night, running down the council and the players. Ask the players to help you "
            .. "find where it comes from.",
    })[kind]
    if host and topic then pcall(Radio.react, host, "crisis", topic, nil, nil) end
    return true
end

local function clueOf(case, n) return case.clues[n] end

local function current()
    local cur = crises().current
    if cur and cur.case then return cur, cur.case end
    return nil, nil
end

local function markFound(case, clue, by)
    if clue.found then return false end
    clue.found = true
    clue.by = by
    case.found = case.found + 1
    notify("clue", { n = clue.n, kind = clue.kind, found = case.found })
    return true
end

-- 현장·물증 자리에 다녀왔다
local function onQuest(q, st)
    local cur, case = current()
    if not case or not q.origin or q.origin.inquiry ~= cur.seq then return end
    if st ~= "completed" then return end
    local clue = clueOf(case, q.origin.clue)
    if not clue then return end
    -- 다녀온 사람은 퀘스트 기록의 마지막 줄에 있다 (훅은 사람을 넘겨받지 않는다)
    local last = q.history and q.history[#q.history]
    local by = last and last.by or nil
    if markFound(case, clue, by) and clue.kind == "item" and by then
        for _, p in ipairs(Sensor.players()) do
            if Store.player(p).name == by then pcall(StoryEngine.Items.addTo, p:getInventory(), Inquiry.EVIDENCE) end
        end
    end
end
Quests.hooks[#Quests.hooks + 1] = function(q, st)
    local ok, err = pcall(onQuest, q, st)
    if not ok then log("inquiry quest hook error:", tostring(err)) end
end

-- ---------------------------------------------------------------- 묻기·다시 묻기·판결

local function wordClue(case, fid)
    for _, c in ipairs(case.clues) do
        if c.kind == "word" and c.fid == fid then return c end
    end
    return nil
end

function Inquiry.ask(player, fid)
    local cur, case = current()
    if not case then return false, "no_case" end
    local clue = wordClue(case, fid)
    if not clue or Factions.isGone(fid) then return false, "no_witness" end
    if not Factions.canTalk(player) then return false, "no_radio" end
    if clue.found then return false, "asked" end
    if trustOf(fid) < Inquiry.TALK_TRUST then return false, "silent" end
    local ps = Store.player(player)
    markFound(case, clue, ps.name)
    pcall(Radio.react, fid, "event", ps.name .. " asked you what you know about the trouble the council is looking into. "
        .. "Answer briefly and stay vague about names; what you told them is on record elsewhere.", nil, ps)
    return true
end

-- 물증과 어긋나는 증언을 짚어 다시 묻는다
function Inquiry.confront(player, fid)
    local cur, case = current()
    if not case then return false, "no_case" end
    local clue = wordClue(case, fid)
    if not clue or not clue.lie or not clue.found then return false, "nothing" end
    if clue.refuted then return false, "asked" end
    if not clueOf(case, 3).found then return false, "no_proof" end
    clue.refuted = true
    clue.points = case.truth
    trust(fid, -2, "caught_lying")
    notify("refuted", { fid = fid })
    return true
end

local RESOLVE = {}

-- 틀린 판결은 한 달 뒤에 드러난다
local function wrong(case, accused, now)
    crises().fx.reveal = { untilT = now.t + Inquiry.REVEAL_DAYS * 24 * 60, kind = case.kind, accused = accused, truth = case.truth,
                           victim = case.victim, party = case.accused }
end

local function reveal(f, now)
    for _, fid in ipairs(living()) do trust(fid, -3, "wrong_verdict") end
    if Factions.byId[f.accused] then trust(f.accused, -5, "wrong_verdict") end
    news("It has come out that the players judged wrongly in the council's inquiry a month ago. The county has not forgotten.", now)
    notify("reveal", { kind = f.kind, accused = f.accused, truth = f.truth })
end

function RESOLVE.warehouse(cur, case, answer, how, right, ps, now)
    if not right then
        trust(answer, -10, "falsely_accused")
        wrong(case, answer, now)
        news(nameOf(answer) .. " was named as the one taking from the council stores.", now)
        return
    end
    local culprit = case.truth
    if how == "public" then
        trust(culprit, -15, "exposed")
        for _, fid in ipairs(living()) do
            if fid ~= culprit then trust(fid, 2, "inquiry_fair") end
        end
        news(nameOf(culprit) .. " was shown before the council to have been taking from the common stores.", now)
    elseif how == "cover" then
        trust(culprit, 10, "covered_for")
        local askers = {}
        for _, fid in ipairs(living()) do
            if fid ~= culprit then askers[#askers + 1] = fid end
        end
        local picked = {}
        for _ = 1, 3 do
            local a = take(askers)
            if a then picked[#picked + 1] = a end
        end
        crises().fx.probe = { untilT = now.t + Inquiry.PROBE_DAYS * 24 * 60, culprit = culprit, suspects = case.answers,
                              askers = picked, hints = 0, n = 0, nextT = now.t + 12 * 60, by = ps.name }
    else
        -- 당사자에게만: 범인이 큰 부탁 하나를 거저 들어준다 (4등급 물건을 바로)
        trust(culprit, 3, "kept_quiet")
        local okL, goods = pcall(StoryEngine.Loot.roll, 4, culprit)
        local p = nil
        for _, x in ipairs(Sensor.players()) do
            if Store.playerKey(x) == ps.key then p = x end
        end
        if okL and p then
            for _, ft in ipairs(goods or {}) do pcall(StoryEngine.Items.addTo, p:getInventory(), ft) end
        end
        pcall(Radio.react, culprit, "event", ps.name .. " found out you were the one taking from the council stores and came to you "
            .. "alone instead of telling the council. You are ashamed and grateful; you have sent them a large gift.", nil, ps)
    end
end

-- 재판: 살인 = 추방, 사고 = 배상, 정당방위 = 무죄
function RESOLVE.trial(cur, case, answer, how, right, ps, now)
    local v, a = case.victim, case.accused
    if right then
        trust(v, 2, "inquiry_fair")
        trust(a, 2, "inquiry_fair")
        news("The council's trial ended in a verdict both settlements could live with.", now)
        return
    end
    local harsh = (answer == "murder") or (answer == "accident" and case.truth == "defence")
    local hurt = harsh and a or v
    trust(hurt, -10, "unjust_verdict")
    if StoryEngine.Bonds then pcall(StoryEngine.Bonds.change, v, a, -1, "the trial went badly between their people", true) end
    wrong(case, hurt, now)
    news("The council's trial ended in a verdict that left " .. nameOf(hurt) .. "'s people bitter.", now)
end

function RESOLVE.water(cur, case, answer, how, right, ps, now)
    if right then
        for _, fid in ipairs(living()) do pcall(Life.change, fid, "morale", 5, "crisis") end
        news("The players found what was fouling the water upstream, and the sickness is passing.", now)
        if case.truth == "sabotage" then
            -- 사람 짓이면 재판으로 이어진다
            crises().done.trial = nil
            crises().follow = { id = "trial", t = now.t + 2 * 24 * 60 }
        end
    else
        crises().fx.sick = { untilT = now.t + 7 * 24 * 60 }
        news("The players named the wrong cause for the fouled water. People are still falling sick.", now)
        notify("reveal", { kind = "water", truth = case.truth })
    end
end

function RESOLVE.pirate(cur, case, answer, how, right, ps, now)
    if not right then
        trust(answer, -10, "falsely_accused")
        for _, fid in ipairs(living()) do pcall(Life.change, fid, "morale", -5, "crisis") end
        wrong(case, answer, now)
        news(nameOf(answer) .. " was named as the voice behind the night broadcasts. The broadcasts went on.", now)
        return
    end
    local who = case.truth
    if Factions.isOutsider(who) then
        news("The night broadcasts against the council came from " .. nameOf(who) .. "'s people.", now)
        local Out = StoryEngine.Outsiders
        if Out and Out.callExpel then pcall(Out.callExpel, who, now) end
    else
        trust(who, 3, "heard_out")
        local players = Sensor.players()
        if #players > 0 then
            local p = players[1]
            pcall(Quests.propose, p, Store.player(p), who, 3, now)
        end
        news("The night broadcasts against the council came from " .. nameOf(who) .. ", who had a grievance nobody had listened to.", now)
    end
end

function Inquiry.judge(player, answer, how)
    local cur, case = current()
    if not case then return false, "no_case" end
    if case.found < Inquiry.NEED then return false, "few_clues" end
    if not has(case.answers, answer) then return false, "how" end
    local hows = Inquiry.HOWS[case.kind]
    if hows and not has(hows, how) then return false, "how" end
    local now = Sensor.now()
    local ps = Store.player(player)
    local right = answer == case.truth
    case.verdict = { answer = answer, how = how, by = ps.name, right = right }
    local ok, err = pcall(RESOLVE[case.kind], cur, case, answer, how, right, ps, now)
    if not ok then log("inquiry resolve error:", tostring(err)) end
    notify("verdict", { kind = case.kind, answer = answer, how = how })
    log("inquiry verdict", case.kind, tostring(answer), tostring(how), right and "right" or "wrong", "by", ps.name)
    Crises.close(now, "judged")
    return true
end

-- 기한을 넘겼다
function Inquiry.ignore(cur, now)
    local case = cur.case
    if not case then return end
    for _, c in ipairs(case.clues) do
        local q = c.qid and Store.data().quests[c.qid]
        if q and Quests.isActive(q) then pcall(Quests.setState, q, "failed", now) end
    end
    if case.kind == "warehouse" then
        for _, fid in ipairs(living()) do pcall(Life.change, fid, "food", -5, "crisis") end
        news("Nobody found who was taking from the council stores. The shelves keep emptying.", now)
    elseif case.kind == "trial" then
        trust(case.victim, -5, "no_verdict")
        trust(case.accused, -5, "no_verdict")
        if StoryEngine.Bonds then pcall(StoryEngine.Bonds.change, case.victim, case.accused, -1, "a killing nobody judged", true) end
        news("The killing between the two settlements was never judged. Both sides hold it against the council.", now)
    elseif case.kind == "water" then
        crises().fx.sick = { untilT = now.t + Inquiry.SICK_DAYS * 24 * 60 }
        news("Nobody found what was fouling the water. The sickness drags on.", now)
    else
        for _, fid in ipairs(living()) do pcall(Life.change, fid, "morale", -5, "crisis") end
        news("The night broadcasts against the council went on, unanswered.", now)
    end
    notify("lapsed", { kind = case.kind })
end

-- ---------------------------------------------------------------- 유도신문 (빼돌린 창고를 덮었을 때)

local METHODS = {
    "name the WRONG person as if you were sure, to see whether they correct you",
    "talk as if you already know who it was and only want them to confirm it",
    "offer them something in return for the name",
    "be sympathetic: say you understand why they would protect a friend",
}

local function exposed(f, now, quote)
    crises().fx.probe = nil
    trust(f.culprit, -10, "cover_blown")
    for _, fid in ipairs(living()) do trust(fid, -5, "cover_blown") end
    news("It came out that the players knew who was taking from the council stores and covered for them.", now)
    notify("exposed", { culprit = f.culprit, quote = quote })
    log("inquiry cover blown", tostring(f.culprit))
end

local function applyVerdict(f, verdict, text, now)
    local open = f.open
    f.open = nil
    if verdict == "named" then
        exposed(f, now, text)
    elseif verdict == "hint" then
        f.hints = f.hints + 1
        if f.hints >= Inquiry.PROBE_HINTS then exposed(f, now, text) else notify("hinted", { fid = open and open.fid }) end
    else
        notify("held", { fid = open and open.fid })
    end
end

-- 플레이어가 그 채널에 한 말 (Radio.say 가 부른다). 떠보는 중이면 판정에 부친다
function Inquiry.onSay(ps, fid, text)
    local s = Store.data().crises
    local f = s and s.fx and s.fx.probe
    if not f or not f.open or f.open.fid ~= fid or f.open.judging then return false end
    f.open.judging = true
    local names = {}
    for _, a in ipairs(f.suspects or {}) do names[#names + 1] = nameOf(a) end
    StoryEngine.Bridge.request("judge", { culprit = nameOf(f.culprit), suspects = names, asker = nameOf(fid),
                                           text = tostring(text), lang = ps.lang }, function(res)
        local cur = Store.data().crises
        local probe = cur and cur.fx and cur.fx.probe
        if probe ~= f or not f.open then return end
        f.open.judging = nil
        if not res or not res.ok or type(res.json) ~= "table" then return end     -- AI 가 없다: 메뉴의 대답으로
        local v = tostring(res.json.verdict)
        if v ~= "named" and v ~= "hint" then v = "none" end
        applyVerdict(f, v, tostring(text), Sensor.now())
    end)
    return true
end

-- AI 없이 고르는 대답: safe(모른다) | vague(얼버무린다) | frank(털어놓는다)
function Inquiry.answer(player, choice)
    local f = crises().fx.probe
    if not f or not f.open then return false, "no_probe" end
    local verdict = ({ safe = "none", vague = "hint", frank = "named" })[tostring(choice)]
    if not verdict then return false, "how" end
    applyVerdict(f, verdict, nil, Sensor.now())
    return true
end

local function probeTick(f, now)
    if f.open and now.t >= f.open.untilT then
        -- 대답하지 않았다
        trust(f.open.fid, -2, "probe_ignored")
        f.open = nil
    end
    if now.t >= f.untilT then
        crises().fx.probe = nil
        notify("probe_over", {})
        return
    end
    if f.open or now.t < (f.nextT or 0) then return end
    local pool = {}
    for _, fid in ipairs(f.askers or {}) do
        if not Factions.isGone(fid) then pool[#pool + 1] = fid end
    end
    if #pool == 0 then return end
    local fid = pool[f.n % #pool + 1]
    f.n = f.n + 1
    f.nextT = now.t + Inquiry.PROBE_GAP_HOURS * 60
    f.open = { fid = fid, untilT = now.t + Inquiry.PROBE_ANSWER_HOURS * 60 }
    -- NPC 대사 쪽에는 범인의 이름을 주지 않는다 (실수로 말하지 않게)
    pcall(Radio.react, fid, "crisis", "You suspect the players found out who was taking from the council stores and are keeping it "
        .. "to themselves. You do not know who it was. Try to get it out of them: " .. METHODS[ZombRand(#METHODS) + 1]
        .. ". Keep it short and in character.", nil, nil)
    notify("probe", { fid = fid })
end

-- ---------------------------------------------------------------- 시간마다 (Crises.tick 이 부른다)

function Inquiry.tick(now)
    local s = crises()
    local fx = s.fx
    if fx.probe then probeTick(fx.probe, now) end
    if fx.reveal and now.t >= fx.reveal.untilT then
        local f = fx.reveal
        fx.reveal = nil
        pcall(reveal, f, now)
    end
    -- 오염된 물: 조사하는 동안과 틀린 뒤에는 날마다 의약품이 준다
    local cur = s.current
    local sickNow = (cur and cur.case and cur.case.kind == "water") or (fx.sick ~= nil and now.t < fx.sick.untilT)
    if fx.sick and now.t >= fx.sick.untilT then fx.sick = nil end
    local day = Store.dayIndex(now.dayKey)
    if s.sickDay ~= day then
        if s.sickDay and sickNow then
            for _, fid in ipairs(living()) do pcall(Life.change, fid, "medical", -Inquiry.SICK_DAILY, "crisis") end
        end
        s.sickDay = day
    end
    -- 이어지는 위기 (오염된 물이 사람 짓이었다 -> 재판)
    if s.follow and not s.current and now.t >= s.follow.t then
        local id = s.follow.id
        s.follow = nil
        Crises.start(id, now)
    end
end

-- ---------------------------------------------------------------- 클라이언트로

function Inquiry.payload(cur, key)
    local case = cur.case
    local out = { kind = case.kind, answers = case.answers, found = case.found, need = Inquiry.NEED,
                  hows = Inquiry.HOWS[case.kind], victim = case.victim, accused = case.accused, clues = {}, words = {} }
    for _, c in ipairs(case.clues) do
        if c.found then
            out.clues[#out.clues + 1] = { n = c.n, kind = c.kind, clears = c.clears, points = (not c.clears) and c.points or nil,
                                          fid = c.fid, refuted = c.refuted, by = c.by }
        end
        if c.kind == "word" then
            local state = "ask"
            if Factions.isGone(c.fid) then state = "gone"
            elseif c.found and c.lie and not c.refuted and case.clues[3].found then state = "confront"
            elseif c.found then state = "asked"
            elseif trustOf(c.fid) < Inquiry.TALK_TRUST then state = "silent" end
            out.words[#out.words + 1] = { fid = c.fid, state = state }
        end
    end
    out.canJudge = case.found >= Inquiry.NEED
    return out
end

function Inquiry.probePayload()
    local s = Store.data().crises
    local f = s and s.fx and s.fx.probe
    if not f then return nil end
    local now = Sensor.now()
    return { days = math.max(0, math.ceil((f.untilT - now.t) / 60 / 24)), hints = f.hints, max = Inquiry.PROBE_HINTS,
             open = f.open and { fid = f.open.fid, hours = math.max(0, math.ceil((f.open.untilT - now.t) / 60)) } or nil }
end

-- ---------------------------------------------------------------- Crises 틀에 얹는다

for _, kind in ipairs(Inquiry.KINDS) do
    Crises.DEF[kind] = {
        options = {}, inquiry = true,
        when = function() return #living() >= 4 end,
        open = function(cur, now) return Inquiry.open(kind, cur, now) end,
        ignore = function(cur, now) Inquiry.ignore(cur, now) end,
    }
    Crises.ORDER[#Crises.ORDER + 1] = kind
end

return Inquiry
