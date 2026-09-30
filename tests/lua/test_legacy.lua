-- 캐릭터가 죽은 뒤의 관계 (Legacy.lua, 아이디어 6번)
local T = {}

local Lg = function() return StoryEngine.Legacy end

local function player(user, first, last)
    local p = H.addPlayer(user, first, last)
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    return p, ps
end

local function radioEvents()
    local out = {}
    for _, b in ipairs(H.bridge) do
        if b.module == "radio" and b.payload.mode == "event" then out[b.payload.faction] = b.payload.topic end
    end
    return out
end

local function kill(p, ps)
    ps.dead = true
    p.dead = true
    StoryEngine.Journal.onDeath(ps, { place = { town = "Riverside" } }, StoryEngine.Sensor.now())
end

function T.counts_by_name()
    local _, ps = player("a", "Gerald", "Kar")
    local Life = StoryEngine.Life
    Life.record("ray", "quest_completed", ps.name, 3)
    Life.record("ray", "trade_done", ps.name, 1)
    Life.record("ray", "quest_completed", "Someone Else", 1)
    local e = Life.npc("ray").byWho[ps.name]
    H.eq(e.n, 5)
    H.eq(e.kinds.quest_completed, 1)
    for _ = 1, 6 do Lg().talked("ray", ps.name) end
    local score, what = Lg().shared("ray", ps.name)
    H.eq(score, 7, "5 + 6 talks / 3")
    H.ok(string.find(what, "did jobs for you", 1, true), what)
    H.ok(string.find(what, "talked with you on the radio 6 times", 1, true), what)
    H.eq((Lg().shared("doc", ps.name)), 0)
end

function T.contacts_react_by_how_well_they_knew_the_dead()
    local p, ps = player("a", "Gerald", "Kar")
    player("b", "Mina", "Park")
    local Life = StoryEngine.Life
    for _ = 1, 4 do Life.record("ray", "quest_completed", ps.name, 2) end
    Life.record("doc", "donation", ps.name, 1)
    Life.record("guard", "trade_done", ps.name, 1)
    Life.record("guard", "trade_done", ps.name, 1)
    kill(p, ps)
    local ev = radioEvents()
    H.ok(ev.ray and string.find(ev.ray, "knew them well", 1, true), "ray was close")
    H.ok(string.find(ev.ray, "near Riverside", 1, true))
    H.ok(ev.guard and string.find(ev.guard, "knew them a little", 1, true), "guard knew them")
    H.ok(ev.doc and string.find(ev.doc, "barely knew them", 1, true), "doc barely")
    H.eq(ev.pike, nil, "pike never dealt with them")
    H.ok(Lg().isDead(ps.name))
    local last = Life.npc("ray").log[#Life.npc("ray").log]
    H.eq(last.kind, "player_died")
    -- 거점 탭: 고인 표시
    local ray
    for _, n in ipairs(Life.list()) do if n.id == "ray" then ray = n end end
    H.eq(ray.records[2].dead, true, "their records are marked")
    H.eq(Life.context("ray").records[1].dead, true)
end

function T.at_most_four_react_and_gone_npcs_stay_quiet()
    local p, ps = player("a", "Gerald", "Kar")
    for _, f in ipairs(StoryEngine.Factions.list) do StoryEngine.Life.record(f.id, "quest_completed", ps.name, 1) end
    StoryEngine.Fate.apply("hunter", "gone", "test")
    H.bridge = {}
    H.eq(Lg().onDeath(ps.name, nil), 4)
    H.eq(radioEvents().hunter, nil)
end

function T.new_voice_gets_context_once()
    local p, ps = player("a", "Gerald", "Kar")
    StoryEngine.Life.record("ray", "quest_completed", ps.name, 2)
    kill(p, ps)
    local p2 = player("b", "Mina", "Park")
    local _, ps3 = player("c", "Minsu", "Kim")
    StoryEngine.Store.player(p2).met = { ["Minsu Kim"] = 300 }
    -- 죽음 반응 무전이 끝나야 채널이 빈다
    local pending = H.bridge
    H.bridge = {}
    for _, b in ipairs(pending) do if b.module == "radio" then b.callback({ ok = false, error = "timeout" }) end end
    H.bridge = {}
    H.ok(StoryEngine.Radio.say(p2, "ray", "Hello? Anyone there?"))
    local req = H.lastBridge("radio")
    local nc = req.payload.newcomer
    H.ok(nc, "newcomer context")
    H.eq(nc.name, "Mina Park")
    H.eq(nc.companions[1], "Minsu Kim")
    H.eq(nc.dead[1].name, "Gerald Kar")
    H.eq(nc.dead[1].knew, true)
    H.ok(string.find(nc.dead[1].what, "did jobs for you", 1, true))
    req.callback({ ok = true, json = { reply = "Who's this?" } })
    H.realMs = H.realMs + 60000     -- 발언 간격
    H.ok(StoryEngine.Radio.say(p2, "ray", "Mina. I was with Gerald."))
    H.eq(H.lastBridge("radio").payload.newcomer, nil, "only the first time")
    H.lastBridge("radio").callback({ ok = true, json = { reply = "Sorry about Gerald." } })
    -- 예전부터 말하던 캐릭터는 새 목소리가 아니다
    ps3.radioLife = { { faction = "doc", from = "player", text = "hi" }, { faction = "doc", from = "player", text = "again" } }
    H.ok(StoryEngine.Radio.say(H.players[3], "doc", "Doc, it's Minsu."))
    H.eq(H.lastBridge("radio").payload.newcomer, nil, "known from before the update")
end

function T.no_context_without_history()
    local p = player("a", "Gerald", "Kar")
    H.ok(StoryEngine.Radio.say(p, "ray", "Hi"))
    H.eq(H.lastBridge("radio").payload.newcomer, nil, "first survivor, nobody lost yet")
end

return T
