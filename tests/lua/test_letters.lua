-- NPC 쪽지·편지 (Letters.lua, 아이디어 5번)
local T = {}

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "KO"
    return p, ps
end

local L = function() return StoryEngine.Letters end
local seq = 0
local function drop(fid, extra)
    seq = seq + 1
    local q = { id = "QT" .. seq, kind = "supply_drop", origin = { faction = fid }, items = { "Base.TinnedBeans" } }
    for k, v in pairs(extra or {}) do q.origin[k] = v end
    return q
end
local function now() return StoryEngine.Sensor.now() end
local function letterRequests()
    local out = {}
    for _, b in ipairs(H.bridge) do if b.module == "letter" then out[#out + 1] = b end end
    return out
end

function T.project_letter_waits_for_that_npcs_drop()
    local _, ps = setup()
    L().queue("ray", "project", "the greenhouse")
    H.eq(L().attach(drop("doc"), ps, now()), nil, "not in someone else's drop")
    local q = drop("ray")
    local rec = L().attach(q, ps, now())
    H.ok(rec, "rides with ray's next drop")
    H.eq(q.items[#q.items], "StoryEngine.Letter")
    H.eq(q.letterId, rec.id)
    H.eq(StoryEngine.Store.data().letters.byQuest[q.id], rec.id)
    local req = letterRequests()[1]
    H.eq(req.payload.faction, "ray")
    H.eq(req.payload.reason, "project")
    H.eq(req.payload.extra, "the greenhouse")
    H.eq(req.payload.lang, "KO")
    H.eq(req.payload.to, "Gerald Kar")
    H.eq(#StoryEngine.Store.data().letters.pending, 0)
end

function T.old_pending_letter_rides_with_any_drop()
    local _, ps = setup()
    L().queue("pike", "project", "the garden")
    H.eq(L().attach(drop("doc"), ps, now()), nil)
    H.advanceDays(3)
    local rec = L().attach(drop("doc"), ps, now())
    H.ok(rec and rec.from == "pike", "passed along after 3 days")
end

function T.farewell_letter_from_a_gone_npc()
    local _, ps = setup()
    StoryEngine.Fate.apply("dewey", "gone", "test")
    local pend = StoryEngine.Store.data().letters.pending
    H.eq(#pend, 1)
    H.eq(pend[1].reason, "farewell")
    H.ok(pend[1].extra and #pend[1].extra > 0, "fate text as context")
    local rec = L().attach(drop("ray"), ps, now())
    H.ok(rec and rec.from == "dewey", "any drop carries it")
end

function T.gift_letter_chance_needs_trust()
    local _, ps = setup()
    StoryEngine.Radio.channel("doc").trust = 50
    H.rolls = { 0 }
    H.eq(L().attach(drop("doc", { friend = true }), ps, now()), nil, "not close enough")
    H.rolls = {}
    StoryEngine.Radio.channel("doc").trust = 75
    H.rolls = { 99 }
    H.eq(L().attach(drop("doc", { friend = true }), ps, now()), nil, "70% of the time no letter")
    H.rolls = { 0 }
    local rec = L().attach(drop("doc", { friend = true }), ps, now())
    H.ok(rec and rec.reason == "gift")
    StoryEngine.Radio.channel("ray").trust = 80
    H.rolls = { 0 }
    rec = L().attach(drop("ray", { friend = true, project = true }), ps, now())
    H.eq(rec.reason, "greenhouse")
    H.eq(L().attach(drop("doc"), ps, now()), nil, "reward drops carry no random letter")
    H.eq(L().attach({ id = "Qd", kind = "deliver", origin = { faction = "doc" }, items = {} }, ps, now()), nil)
end

function T.reading_the_letter()
    local p, ps = setup()
    L().queue("doc", "gift")
    local q = drop("doc")
    local rec = L().attach(q, ps, now())
    local info = L().read(p, rec.id)
    H.ok(info.writing, "still being written")
    letterRequests()[1].callback({ ok = true, json = { title = "For Gerald", text = "Take care of that cough.\nJune" } })
    H.eq(rec.status, "ready")
    info = L().read(p, nil, q.id)
    H.eq(info.text, "Take care of that cough.\nJune", "found by quest id")
    H.eq(info.title, "For Gerald")
    H.eq(info.from, "doc")
    local notes = 0
    for _, n in ipairs(ps.notes or {}) do
        if n.kind == "letter_read" then notes = notes + 1; H.eq(n.faction, "doc") end
    end
    H.eq(notes, 1, "journal note once")
    H.eq(select(2, L().read(p, "L999")), "no_letter")
    -- 명령
    H.fire("OnClientCommand", StoryEngine.MODULE, "letterRead", p, { id = rec.id })
    local sent = H.sentOf("letterText")
    H.eq(sent[#sent].text, info.text)
    H.ok(string.find(L().statusText(), "letters 1 unread=0", 1, true), L().statusText())
end

function T.failed_writing_uses_prepared_letter()
    local p, ps = setup()
    L().queue("rats", "gift")
    local rec = L().attach(drop("rats"), ps, now())
    letterRequests()[1].callback({ ok = false, error = "timeout" })
    H.eq(rec.status, "failed")
    local info = L().read(p, rec.id)
    H.eq(info.text, nil)
    H.eq(info.writing, nil, "client shows the prepared letter")
    H.eq(info.reason, "gift")
end

function T.project_completion_queues_a_letter()
    setup()
    StoryEngine.Projects.add("casey", 1000)
    local pend = StoryEngine.Store.data().letters.pending
    H.eq(#pend, 1)
    H.eq(pend[1].fid, "casey")
    H.eq(pend[1].reason, "project")
end

function T.option_off()
    local _, ps = setup()
    SandboxVars.StoryEngine.Letters = false
    L().queue("doc", "gift")
    H.eq(L().attach(drop("doc"), ps, now()), nil)
    H.eq(StoryEngine.Store.data().letters, nil)
end

return T
