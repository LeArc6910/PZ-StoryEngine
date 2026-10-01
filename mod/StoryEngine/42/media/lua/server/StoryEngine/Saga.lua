-- 여러 날 이어지는 큰 사건 (2026-10-01, 설계 docs/IDEAS_WORLD_EVENTS.md 위쪽 ①②③ + 통신 두절).
--
-- 사건 = 단계들의 연결 (전조 -> 발생 -> 고비). 단계는 시간이 지나면 넘어가고, 핵심 퀘스트를 일찍 끝내면 빨리 끝나기도 한다.
-- 결말은 해낸 퀘스트로 판정해 NPC 형편·관계·운명이 바뀌고 모두의 일지·라디오 방송·공용 주파수에 남는다.
-- 판정은 전부 Lua, AI 는 무전·장면·방송·일지에 서사만 입힌다.
--   crash     군 헬기 추락 (방위대·빅·닥): 현장 상자의 서류·탄약·의약품을 누구에게 넘길지 위기 선택, 고비에 큰 무리(+A-Life 약탈자)
--   migration 대이동 (행크·레이·파이크): 레이 농가·교회가 매일 무기(안전) -10, 방어 자재 모금, 고비에 접속자마다 2배 무리
--   epidemic  열병 유행 (닥·파이크): 매일 NPC 1~2곳 의약품·기호품 하락, 약품 모금, 닥이 쓰러져 특기를 못 씀, 결과에 따라 회복 또는 죽음
--   blackout  통신 두절 (케이시): 중계탑이 멈춰 케이시 말고는 무전이 잡음뿐, 중계탑 소탕 + 부품 모금으로 되살림
-- 빈도: 서버 25일째부터, 끝난 뒤 14~21일마다 하나, 같은 사건은 60일 안에 다시 안 나온다. 복구 작전과 동시에 하지 않는다.
-- 사건 중에는 NPC 가 먼저 청하는 일(부탁·협박)과 무작위 위기를 쉰다.

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Places"
require "StoryEngine/Factions"
require "StoryEngine/Radio"
require "StoryEngine/Quests"
require "StoryEngine/Hunt"
require "StoryEngine/Life"
require "StoryEngine/OpsSites"

local Net = StoryEngine.Net
local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Places = StoryEngine.Places
local Factions = StoryEngine.Factions
local Radio = StoryEngine.Radio
local Quests = StoryEngine.Quests
local Life = StoryEngine.Life
local Sites = StoryEngine.OpsSites
local log = StoryEngine.log

local Saga = {}
StoryEngine.Saga = Saga

Saga.FIRST_DAY = 25          -- 서버 경과 일수
Saga.GAP_DAYS = { 14, 21 }   -- 사건 사이
Saga.REPEAT_DAYS = 60        -- 같은 사건은 이만큼 지나야 다시
Saga.CRASH_DIST = { 500, 900 }

Saga.DEF = {
    crash = { npcs = { "guard", "rats", "doc" },
              stages = { { id = "omen", hours = 24 }, { id = "crash", hours = 48 }, { id = "swarm", hours = 24 } } },
    migration = { npcs = { "hunter", "ray", "pike" },
                  stages = { { id = "omen", hours = 24 }, { id = "pressure", hours = 48 }, { id = "horde", hours = 24 } } },
    epidemic = { npcs = { "doc", "pike" },
                 stages = { { id = "omen", hours = 24 }, { id = "spread", hours = 48 }, { id = "docill", hours = 48 } } },
    blackout = { npcs = { "casey" },
                 stages = { { id = "omen", hours = 12 }, { id = "silence", hours = 72 } } },
}
Saga.KINDS = { "crash", "migration", "epidemic", "blackout" }

Saga.CRASH_CRATE = { "StoryEngine.SealedDocuments", "Base.556Box", "Base.556Box", "Base.556Box", "Base.Antibiotics",
                     "Base.Antibiotics", "Base.Bandage", "Base.Bandage", "Base.Bandage", "Base.Bandage", "Base.Bandage",
                     "Base.Bandage", "Base.Bullets9mmBox" }
Saga.BARRICADE = {
    ray = { { "Base.Plank", 8 }, { "Base.NailsBox", 1 }, { "Base.Bullets9mmBox", 1 } },
    pike = { { "Base.Plank", 8 }, { "Base.NailsBox", 1 }, { "Base.Hammer", 1 } },
}
Saga.MEDICINE = { { "Base.Antibiotics", 4 }, { "Base.Pills", 6 }, { "Base.Bandage", 8 } }
Saga.RELAY_PARTS = { { "Base.ElectricWire", 4 }, { "Base.ElectronicsScrap", 8 }, { "Base.Amplifier", 1 }, { "Base.Battery", 4 } }
Saga.DRAIN = 10                     -- 대이동: 막지 못한 거점의 무기(안전) 하루 감소
Saga.FEVER = { medical = 8, morale = 5 }

-- ---------------------------------------------------------------- 상태와 공통

local function state()
    local d = Store.data()
    d.saga = d.saga or {}
    local s = d.saga
    s.seq = s.seq or 0
    s.history = s.history or {}
    s.lastDay = s.lastDay or {}
    return s
end

function Saga.enabled() return StoryEngine.option("Sagas", true) == true end
function Saga.current() return state().current end
function Saga.active() return state().current ~= nil end

local function dist(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

local function alive(fid) return Factions.byId[fid] ~= nil and not Factions.isGone(fid) end

local function nameOf(fid) return StoryEngine.Stories and StoryEngine.Stories.NAMES[fid] or fid end

local function noteAll(text, now)
    for _, ps in pairs(Store.data().players) do
        if not ps.dead then Store.addNote(ps, { kind = "op", text = text, clock = now.clock }) end
    end
end

local function say(fid, topic, fallbackKey, ps)
    if not fid or not alive(fid) then return end
    Radio.react(fid, "event", topic .. " Keep it short and in character.",
        { text = "...", lt = { key = "IGUI_StoryEngine_RadioSay_saga_" .. fallbackKey } }, ps)
end

local function spread(ids, text)
    if not StoryEngine.Social then return end
    pcall(StoryEngine.Social.news, "all", text)
    local list = {}
    for _, fid in ipairs(ids or {}) do if alive(fid) then list[#list + 1] = fid end end
    for _, f in ipairs(Factions.list) do
        if #list >= 2 then break end
        if alive(f.id) then
            local dup = false
            for _, x in ipairs(list) do if x == f.id then dup = true end end
            if not dup then list[#list + 1] = f.id end
        end
    end
    if #list >= 2 then pcall(StoryEngine.Social.queueTopic, list, text .. " They talk about it.") end
end

local function notice(event, sg)
    pcall(Net.toAll, "sagaNotice", { event = event, kind = sg.kind, stage = sg.stage,
                                      stages = #Saga.DEF[sg.kind].stages, stageId = sg.stageId, result = sg.result })
end

local function anchor()
    local sx, sy, n = 0, 0, 0
    for _, p in ipairs(Sensor.players()) do
        if not p:isDead() then sx, sy, n = sx + p:getX(), sy + p:getY(), n + 1 end
    end
    if n > 0 then return sx / n, sy / n end
    return 10754, 9926
end

local function nearestPlayer(x, y)
    local best, bestD = nil, nil
    for _, p in ipairs(Sensor.players()) do
        if not p:isDead() then
            local d = dist(p:getX(), p:getY(), x, y)
            if not bestD or d < bestD then best, bestD = p, d end
        end
    end
    return best, bestD
end

local function targetPs(sg)
    return Store.data().players[sg.target]
end

function Saga.origin(sg, role, faction)
    local st = Saga.DEF[sg.kind].stages[sg.stage]
    return { source = "saga", saga = sg.id, sagaKind = sg.kind, stage = sg.stage, stages = #Saga.DEF[sg.kind].stages,
             stageId = st.id, role = role, faction = faction }
end

local function remember(sg, role, q)
    if q then sg.quests[role] = q.id end
    return q
end

local function questOf(sg, role)
    local id = sg.quests[role]
    return id and Store.data().quests[id] or nil
end

-- 모금이 얼마나 찼는지 (0~1)
local function collectShare(q)
    if not q then return 0 end
    local got, need = 0, 0
    for _, n in ipairs(q.need or {}) do
        need = need + n[2]
        got = got + math.min(n[2], (q.got or {})[n[1]] or 0)
    end
    if q.state == "completed" then return 1 end
    return need > 0 and got / need or 0
end

local function lifeChange(fid, res, delta, why)
    if alive(fid) then Life.change(fid, res, delta, why) end
end

-- ---------------------------------------------------------------- ① 군 헬기 추락

local Crash = {}

function Crash.omen(sg, now)
    local caller = alive("casey") and "casey" or "guard"
    say(caller, "You just caught a military distress call: a helicopter is losing altitude somewhere over the county. "
        .. "Tell the players. Nobody knows yet where it will come down.", "crash_omen", targetPs(sg))
    if caller ~= "guard" then
        say("guard", "Your unit's channel is buzzing about one of your helicopters in trouble. You are on edge and want "
            .. "to know where it goes down.", "crash_omen", targetPs(sg))
    end
    noteAll("a military helicopter's distress call came over the radio", now)
    spread({ "casey", "guard" }, "A military helicopter sent out a distress call over the county.")
end

function Crash.crash(sg, now)
    local ax, ay = anchor()
    local q = nil
    for _ = 1, 10 do
        local angle = ZombRandFloat(0, math.pi * 2)
        local d = ZombRandFloat(Saga.CRASH_DIST[1], Saga.CRASH_DIST[2])
        local site = { x = math.floor(ax + math.cos(angle) * d), y = math.floor(ay + math.sin(angle) * d), name = "crash_site" }
        q = Quests.createSite("supply_drop", targetPs(sg), site, now, Saga.origin(sg, "crate", "guard"),
            { items = Saga.CRASH_CRATE, search = 150, building = true, deadlineT = sg.endT, tier = 4 })
        if q then break end
    end
    if not q then
        log("saga crash: no site")
        return false
    end
    remember(sg, "crate", q)
    sg.data.site = { x = q.cx, y = q.cy, town = q.place and q.place.town }
    local Social = StoryEngine.Social
    if Social then
        Social.crisesUsedTable()["heli_crash"] = nil
        local ok, why = Social.startCrisis(now, "heli_crash")
        if not ok then log("saga crash crisis:", tostring(why)) end
    end
    local caller = alive("casey") and "casey" or "guard"
    say(caller, "The helicopter came down near " .. tostring(q.place and q.place.town) .. ". The wreck's cargo crate is in a "
        .. "building there. Tell the players to look at their quest log, and warn them the crash noise will draw the dead.",
        "crash_down", targetPs(sg))
    noteAll("the military helicopter came down near " .. tostring(q.place and q.place.town), now)
    spread({ "guard", "rats", "doc" }, "A military helicopter crashed near " .. tostring(q.place and q.place.town) .. ".")
    return true
end

function Crash.swarm(sg, now)
    local site = sg.data.site
    if not site then return end
    local p = nearestPlayer(site.x, site.y)
    if p then
        local size = math.floor(StoryEngine.Hunt.sizeNow() * 1.5 + 0.5)
        StoryEngine.Hunt.start(p, size, site.x + ZombRand(-20, 21), site.y + ZombRand(-20, 21), "saga_crash")
        if StoryEngine.ALife and StoryEngine.ALife.sendAttack then pcall(StoryEngine.ALife.sendAttack, p, "rats") end
    end
    say("guard", "The dead are swarming the crash site near " .. tostring(site.town) .. " now, and you hear armed looters "
        .. "are heading there too. Warn the players.", "crash_swarm", targetPs(sg))
end

-- 위기에서 누구를 골랐고 그 부탁을 해냈는지
local function crashChoice(sg)
    local chosen, delivered = nil, false
    for _, q in pairs(Store.data().quests) do
        if q.kind == "choice" and q.crisis == "heli_crash" and (q.createdT or 0) >= sg.startT then chosen = q.chosen end
        local story = q.origin and q.origin.story
        if story and story.crisis == "heli_crash" and (q.createdT or 0) >= sg.startT and q.state == "completed" then
            delivered = true
        end
    end
    return chosen, delivered
end

function Crash.finish(sg, now)
    local chosen, delivered = crashChoice(sg)
    local Bonds = StoryEngine.Bonds
    local outcome
    if chosen == "guard" and delivered then
        outcome = "guard"
        if StoryEngine.Projects then pcall(StoryEngine.Projects.add, "guard", 50, nil, "saga") end
        if Bonds then Bonds.change("rats", "guard", -1, "the army got the wreck's papers instead of him") end
        say("guard", "Command has its papers back thanks to the players. You owe them. The wreck is closed for you.",
            "crash_end", targetPs(sg))
        spread({ "guard", "rats" }, "The army recovered the sealed papers from the helicopter wreck with the players' help.")
    elseif chosen == "rats" and delivered then
        outcome = "rats"
        lifeChange("rats", "safety", 30, "saga")
        if Bonds then Bonds.change("guard", "rats", -1, "Vic's crew walked off with the army's ammunition", true) end
        say("rats", "Your crew is armed to the teeth now with the army's ammunition. Gloat a little and thank the players.",
            "crash_end", targetPs(sg))
        spread({ "rats", "guard" }, "Vic's crew walked off with the ammunition from the helicopter wreck.")
    elseif chosen == "doc" and delivered then
        outcome = "doc"
        lifeChange("doc", "medical", 30, "saga")
        for _, f in ipairs(Factions.list) do lifeChange(f.id, "morale", 5, "saga") end
        say("doc", "The medical supplies from the wreck are already helping people. Thank the players warmly.",
            "crash_end", targetPs(sg))
        spread({ "doc", "pike" }, "June got the medical supplies from the helicopter wreck to the people who needed them.")
    else
        outcome = "none"
        if Bonds then Bonds.change("guard", "rats", -1, "both sides fought over the helicopter wreck", true) end
        lifeChange("guard", "safety", -10, "saga")
        lifeChange("rats", "safety", -10, "saga")
        say("guard", "Nobody secured the wreck in time; Vic's crew and your squad traded shots over it. Tell the players "
            .. "how it went, bitter.", "crash_end", targetPs(sg))
        spread({ "guard", "rats" }, "The army and Vic's crew fought over the helicopter wreck and nobody came out ahead.")
    end
    noteAll("the business with the crashed military helicopter ended (" .. outcome .. ")", now)
    return outcome
end

-- ---------------------------------------------------------------- ② 대이동

local Migration = {}

function Migration.omen(sg, now)
    local caller = alive("hunter") and "hunter" or "ray"
    say(caller, "Every animal in the woods is running south. Something huge is moving down through the county from the "
        .. "north. Warn the players to get ready.", "migration_omen", targetPs(sg))
    noteAll("word came over the radio that the animals were fleeing south ahead of something big", now)
    spread({ "hunter", "ray" }, "The animals are fleeing south; something big is moving down through the county.")
end

function Migration.pressure(sg, now)
    sg.data.held = sg.data.held or {}
    for _, fid in ipairs({ "ray", "pike" }) do
        if alive(fid) then
            local q = Quests.createCollect(targetPs(sg), Saga.BARRICADE[fid], now, Saga.origin(sg, fid, fid), sg.endT)
            remember(sg, fid, q)
            say(fid, "The horde is coming down right past your place. Ask everyone to send boards, nails and "
                .. (fid == "ray" and "ammunition" or "a hammer") .. " over the radio so you can barricade in time. "
                .. "Anyone can chip in.", "migration_ask", targetPs(sg))
        end
    end
    sg.data.nextDrainT = now.t
    noteAll("the dead began moving down through the county; Ray's farm and Brother Pike's church are in the way", now)
end

function Migration.tick(sg, now)
    if not sg.data.nextDrainT or now.t < sg.data.nextDrainT then return end
    sg.data.nextDrainT = now.t + 24 * 60
    for _, fid in ipairs({ "ray", "pike" }) do
        if not (sg.data.held or {})[fid] then lifeChange(fid, "safety", -Saga.DRAIN, "migration") end
    end
end

function Migration.horde(sg, now)
    local size = math.floor(StoryEngine.Hunt.sizeNow() * 2 + 0.5)
    for _, p in ipairs(Sensor.players()) do
        if not p:isDead() then
            StoryEngine.Hunt.start(p, size, p:getX() + ZombRand(-30, 31), p:getY() - 70, "saga_migration")
            if StoryEngine.Specialty then pcall(StoryEngine.Specialty.opScout, p, sg.stageEndT) end
        end
    end
    local caller = alive("casey") and "casey" or "hunter"
    say(caller, "The main body of the horde is passing right by the players now, coming from the north. You are marking "
        .. "it on their maps. Tell them to hold tight.", "migration_horde", targetPs(sg))
end

function Migration.onQuest(sg, q, outcome)
    if q.kind == "collect" and outcome == "completed" then
        sg.data.held = sg.data.held or {}
        sg.data.held[q.origin.role] = true
        say(q.origin.role, "Your place is barricaded now thanks to what the players sent. Thank them.", "migration_held",
            Store.data().players[q.target])
    end
end

function Migration.finish(sg, now)
    local held = sg.data.held or {}
    local parts = {}
    for _, fid in ipairs({ "ray", "pike" }) do
        if alive(fid) then
            if held[fid] then
                lifeChange(fid, "safety", 20, "saga")
                lifeChange(fid, "morale", 15, "saga")
                Life.record(fid, "saga_saved", nil, 0)
                parts[#parts + 1] = nameOf(fid) .. "'s place held"
            else
                lifeChange(fid, "safety", -30, "saga")
                parts[#parts + 1] = nameOf(fid) .. "'s place was overrun and stripped"
            end
        end
    end
    local text = "The great horde passed through the county: " .. table.concat(parts, ", ") .. "."
    spread({ "ray", "pike" }, text)
    noteAll("the great horde passed; " .. table.concat(parts, ", "), now)
    for _, fid in ipairs({ "ray", "pike" }) do
        say(fid, text .. " Tell the players how your people came through it.", "migration_end", targetPs(sg))
    end
    return (held.ray and held.pike) and "both" or ((held.ray or held.pike) and "one" or "none")
end

-- ---------------------------------------------------------------- ③ 열병 유행

local Epidemic = {}

function Epidemic.omen(sg, now)
    say("pike", "More and more of the refugees at your church are coughing and running a fever. You are worried and "
        .. "tell the players.", "epidemic_omen", targetPs(sg))
    noteAll("Brother Pike said the refugees at his church were coming down with a fever", now)
    spread({ "pike", "doc" }, "A fever is spreading among the refugees at Brother Pike's church.")
end

function Epidemic.spread(sg, now)
    local q = Quests.createCollect(targetPs(sg), Saga.MEDICINE, now, Saga.origin(sg, "medicine", "doc"), sg.endT)
    remember(sg, "medicine", q)
    say("doc", "The fever is spreading across the county. Ask everyone to send antibiotics, pills and bandages over "
        .. "the radio; every bit helps and it can be shared out.", "epidemic_ask", targetPs(sg))
    sg.data.nextFeverT = now.t
end

function Epidemic.tick(sg, now)
    if not sg.data.nextFeverT or now.t < sg.data.nextFeverT or sg.data.cured then return end
    sg.data.nextFeverT = now.t + 24 * 60
    local pool = {}
    for _, f in ipairs(Factions.list) do if alive(f.id) then pool[#pool + 1] = f.id end end
    for _ = 1, math.min(#pool, 1 + ZombRand(2)) do
        local fid = table.remove(pool, ZombRand(#pool) + 1)
        lifeChange(fid, "medical", -Saga.FEVER.medical, "fever")
        lifeChange(fid, "morale", -Saga.FEVER.morale, "fever")
        if StoryEngine.Social then pcall(StoryEngine.Social.news, fid, "The fever reached your people; several are sick.") end
    end
end

function Epidemic.docill(sg, now)
    if sg.data.cured or not alive("doc") then return end
    sg.data.docIll = true
    if StoryEngine.Social then pcall(StoryEngine.Social.news, "doc", "You caught the fever yourself and can barely stand.") end
    say("pike", "June Adler, the nurse, has collapsed with the fever herself. She cannot treat anyone right now. "
        .. "Tell the players, worried.", "epidemic_docill", targetPs(sg))
    noteAll("June Adler, the nurse, caught the fever herself", now)
end

function Epidemic.onQuest(sg, q, outcome)
    if q.kind == "collect" and outcome == "completed" then
        local wasIll = sg.data.docIll == true
        sg.data.cured = true
        sg.data.docIll = false
        say("doc", "With everything the players sent, the fever is finally breaking" .. (wasIll and ", even for you" or "")
            .. ". Thank them.", "epidemic_cured", Store.data().players[q.target])
    end
end

function Epidemic.finish(sg, now)
    sg.data.docIll = false
    local share = collectShare(questOf(sg, "medicine"))
    local outcome
    if share >= 1 then
        outcome = "cured"
        for _, f in ipairs(Factions.list) do lifeChange(f.id, "medical", 20, "saga") end
        if StoryEngine.Trust and alive("doc") then StoryEngine.Trust.apply("doc", 3, "saga", nil, nil) end
        spread({ "doc", "pike" }, "The fever has broken across the county thanks to the medicine the players gathered.")
    elseif share >= 0.5 then
        outcome = "partial"
        for _, f in ipairs(Factions.list) do lifeChange(f.id, "medical", 5, "saga") end
        spread({ "doc", "pike" }, "The fever has passed, but it was close; there was barely enough medicine.")
    else
        outcome = "lost"
        for _, f in ipairs(Factions.list) do lifeChange(f.id, "morale", -10, "saga") end
        local Fate = StoryEngine.Fate
        local victim, low = nil, 999
        for _, f in ipairs(Factions.list) do
            if alive(f.id) and f.id ~= "doc" then
                local v = Life.get(f.id, "medical")
                if v < low then victim, low = f.id, v end
            end
        end
        if victim and Fate and Fate.enabled() and ZombRand(100) < 50 then
            outcome = "death"
            pcall(Fate.apply, victim, "dead", "fever")
        end
        spread({ "doc", "pike" }, "The fever burned through the county with too little medicine; people died.")
    end
    say("doc", "The fever is over (" .. outcome .. "). Tell the players how it ended.", "epidemic_end", targetPs(sg))
    noteAll("the fever ran its course (" .. outcome .. ")", now)
    return outcome
end

-- ---------------------------------------------------------------- ④ 통신 두절

local Blackout = {}

function Blackout.omen(sg, now)
    say("casey", "The relay mast that carries everyone's signal across the county is glitching. Signals keep cutting "
        .. "out. You are scared it will die completely. Tell the players.", "blackout_omen", targetPs(sg))
    noteAll("Casey warned that the radio relay mast was failing", now)
end

function Blackout.silence(sg, now)
    local ax, ay = anchor()
    local mast = Sites.byDistance(Sites.RADIO_TOWERS, ax, ay)[1]
    sg.data.mast = { x = mast.x, y = mast.y }
    sg.data.radioDown = true
    local stage = Store.stage()
    local size = math.floor((Quests.HORDE_SIZE[math.min(Quests.MAX_TIER, stage + 1)] or 14) + 0.5)
    remember(sg, "mast", Quests.createSite("horde", targetPs(sg), { x = mast.x, y = mast.y, name = "relay_mast" }, now,
        Saga.origin(sg, "mast", "casey"), { deadlineT = sg.endT, size = size, search = 40, tier = 3 }))
    remember(sg, "parts", Quests.createCollect(targetPs(sg), Saga.RELAY_PARTS, now, Saga.origin(sg, "parts", "casey"), sg.endT))
    say("casey", "The relay mast is dead. Only your own rig still reaches the players; nobody else can be heard. The dead "
        .. "are crowding the mast and you need wire, electronics, an amplifier and batteries to fix it. Ask them for help.",
        "blackout_down", targetPs(sg))
    noteAll("the radio went silent across the county; only Casey's rig still came through", now)
end

function Blackout.done(sg)
    local mastQ, partsQ = questOf(sg, "mast"), questOf(sg, "parts")
    return mastQ ~= nil and partsQ ~= nil and mastQ.state == "completed" and partsQ.state == "completed"
end

function Blackout.finish(sg, now)
    sg.data.radioDown = false
    local fixed = Blackout.done(sg)
    if fixed then
        if StoryEngine.Projects then pcall(StoryEngine.Projects.add, "casey", 50, nil, "saga") end
        for _, f in ipairs(Factions.list) do lifeChange(f.id, "morale", 5, "saga") end
        say("casey", "The relay mast is back up thanks to the players. Everyone can hear each other again. Celebrate.",
            "blackout_end", targetPs(sg))
    else
        lifeChange("casey", "morale", -15, "saga")
        say("casey", "You finally jury-rigged the mast yourself, barely. The signal is back but weak. Tell the players.",
            "blackout_end", targetPs(sg))
    end
    spread({ "casey", "dewey" }, fixed and "The radio relay mast is fixed and everyone can talk again."
        or "The radio came back after days of silence, barely patched.")
    noteAll("the radio came back across the county", now)
    return fixed and "fixed" or "patched"
end

-- ---------------------------------------------------------------- 엔진

Saga.ENTER = {
    crash = { omen = Crash.omen, crash = Crash.crash, swarm = Crash.swarm },
    migration = { omen = Migration.omen, pressure = Migration.pressure, horde = Migration.horde },
    epidemic = { omen = Epidemic.omen, spread = Epidemic.spread, docill = Epidemic.docill },
    blackout = { omen = Blackout.omen, silence = Blackout.silence },
}
Saga.TICK = { migration = Migration.tick, epidemic = Epidemic.tick }
Saga.ON_QUEST = { migration = Migration.onQuest, epidemic = Epidemic.onQuest }
Saga.DONE = { blackout = { silence = Blackout.done } }
Saga.FINISH = { crash = Crash.finish, migration = Migration.finish, epidemic = Epidemic.finish, blackout = Blackout.finish }

-- 통신 두절 중 막힌 무전 (케이시 말고 전부, 공용 주파수 포함)
function Saga.radioDown(fid)
    local sg = state().current
    return sg ~= nil and sg.kind == "blackout" and sg.data.radioDown == true and fid ~= "casey"
end

-- 열병에 쓰러진 닥은 특기를 못 쓴다
function Saga.specialtyBlocked(fid)
    local sg = state().current
    return sg ~= nil and sg.kind == "epidemic" and sg.data.docIll == true and fid == "doc"
end

function Saga.enterStage(n)
    local sg = state().current
    if not sg then return end
    local now = Sensor.now()
    local st = Saga.DEF[sg.kind].stages[n]
    sg.stage, sg.stageId = n, st.id
    sg.stageStartT = now.t
    sg.stageEndT = now.t + st.hours * 60
    log("saga stage", sg.id, sg.kind, n, st.id)
    local enter = Saga.ENTER[sg.kind][st.id]
    if enter then
        local ok, err = pcall(enter, sg, now)
        if not ok then log("saga enter error:", err) end
        if ok and err == false then
            Saga.finish("no_site")
            return
        end
    end
    notice("stage", sg)
end

function Saga.start(kind, why)
    local s = state()
    if s.current then return false, "busy" end
    if not Saga.DEF[kind] then return false, "no_kind" end
    local players = Sensor.players()
    if #players == 0 then return false, "no_players" end
    local now = Sensor.now()
    s.seq = s.seq + 1
    local total = 0
    for _, st in ipairs(Saga.DEF[kind].stages) do total = total + st.hours end
    s.current = {
        id = "SG" .. StoryEngine.intToString(s.seq), kind = kind, why = why, startT = now.t,
        endT = now.t + total * 60, target = Store.playerKey(players[ZombRand(#players) + 1]),
        stage = 0, data = {}, quests = {},
    }
    log("saga start", s.current.id, kind, why or "")
    Saga.enterStage(1)
    return true, s.current
end

function Saga.finish(why)
    local s = state()
    local sg = s.current
    if not sg then return end
    local now = Sensor.now()
    local fin = Saga.FINISH[sg.kind]
    local result = nil
    if fin and why ~= "no_site" then
        local ok, res = pcall(fin, sg, now)
        if ok then result = res else log("saga finish error:", res) end
    end
    s.current = nil
    Quests.cancelOp(sg.id, now, "saga")
    sg.result = result or why
    Store.push(s.history, { id = sg.id, kind = sg.kind, result = sg.result, day = Store.dayIndex(now.dayKey) }, 20)
    s.lastDay[sg.kind] = Store.serverDays()
    s.nextT = now.t + (Saga.GAP_DAYS[1] + ZombRand(Saga.GAP_DAYS[2] - Saga.GAP_DAYS[1] + 1)) * 24 * 60
    notice("done", sg)
    log("saga finish", sg.id, sg.kind, tostring(sg.result))
end

-- 10분마다 (접속자가 있을 때)
function Saga.tick(now)
    local sg = state().current
    if not sg then return end
    local tick = Saga.TICK[sg.kind]
    if tick then
        local ok, err = pcall(tick, sg, now)
        if not ok then log("saga tick error:", err) end
    end
    local done = Saga.DONE[sg.kind] and Saga.DONE[sg.kind][sg.stageId]
    local early = false
    if done then
        local ok, res = pcall(done, sg)
        early = ok and res == true
    end
    if early or now.t >= sg.stageEndT then
        if sg.stage < #Saga.DEF[sg.kind].stages then
            Saga.enterStage(sg.stage + 1)
        else
            Saga.finish(early and "early" or nil)
        end
    end
end

function Saga.onQuest(q, outcome)
    local sg = state().current
    if not sg or q.origin.saga ~= sg.id then return end
    local fn = Saga.ON_QUEST[sg.kind]
    if fn then fn(sg, q, outcome) end
end

-- 오늘 일어날 수 있는 사건 (관련 NPC 가 모두 살아 있고 최근에 없던 것)
function Saga.candidates()
    local s = state()
    local days = Store.serverDays()
    local out = {}
    for _, kind in ipairs(Saga.KINDS) do
        local ok = true
        for _, fid in ipairs(Saga.DEF[kind].npcs) do if not alive(fid) then ok = false end end
        local last = s.lastDay[kind]
        if last and days - last < Saga.REPEAT_DAYS then ok = false end
        if ok then out[#out + 1] = kind end
    end
    return out
end

-- 하루 한 번: 때가 되면 사건 하나
function Saga.daily(now)
    if not Saga.enabled() or #Sensor.players() == 0 then return end
    local s = state()
    if s.rollDay == now.dayKey then return end
    s.rollDay = now.dayKey
    if s.current or (StoryEngine.Ops and StoryEngine.Ops.active()) then return end
    if Store.serverDays() < Saga.FIRST_DAY then return end
    if not s.nextT then
        s.nextT = now.t + ZombRand(8) * 24 * 60        -- 첫 사건은 25일째부터 일주일 안에 흩어서
        return
    end
    if now.t < s.nextT then return end
    local pool = Saga.candidates()
    if #pool == 0 then return end
    Saga.start(pool[ZombRand(#pool) + 1], "schedule")
end

function Saga.statusText()
    local s = state()
    local sg = s.current
    local text = "saga"
    if sg then
        text = text .. " " .. sg.id .. " " .. sg.kind .. " " .. StoryEngine.intToString(sg.stage) .. "/"
            .. StoryEngine.intToString(#Saga.DEF[sg.kind].stages) .. " " .. tostring(sg.stageId) .. " "
            .. StoryEngine.intToString(math.max(0, math.floor((sg.stageEndT - Sensor.now().t) / 60))) .. "h left"
            .. (sg.data.radioDown and " radio-down" or "") .. (sg.data.docIll and " doc-ill" or "")
    else
        local wait = s.nextT and math.max(0, math.floor((s.nextT - Sensor.now().t) / (24 * 60))) or nil
        text = text .. " none" .. (wait and (" next~" .. StoryEngine.intToString(wait) .. "d") or "")
    end
    local last = s.history[#s.history]
    if last then text = text .. " | last " .. last.kind .. " " .. tostring(last.result) end
    return text
end

-- 디버그: start(kind) | next(다음 단계) | stop(지금 결말)
function Saga.debug(action, kind)
    local s = state()
    if action == "start" then
        if s.current then Saga.finish("debug_replace") end
        if StoryEngine.Ops and StoryEngine.Ops.active() then return false, "operation_running" end
        return Saga.start(Saga.DEF[kind] and kind or "crash", "debug")
    end
    local sg = s.current
    if not sg then return false, "no_saga" end
    if action == "next" then
        if sg.stage < #Saga.DEF[sg.kind].stages then Saga.enterStage(sg.stage + 1) else Saga.finish("debug") end
        return true
    elseif action == "stop" then
        Saga.finish("debug")
        return true
    end
    return false, "unknown"
end

Sensor.listeners.tick[#Sensor.listeners.tick + 1] = function(entries, now)
    local ok, err = pcall(Saga.tick, now)
    if not ok then log("saga tick error:", err) end
end

Events.EveryHours.Add(function()
    local ok, err = pcall(Saga.daily, Sensor.now())
    if not ok then log("saga daily error:", err) end
end)

return Saga
