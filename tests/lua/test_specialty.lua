-- NPC 특기 지원 2단계 (Specialty.lua, ALife 소음기)
local T = {}

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    return p, ps
end

local function setTrust(fid, v) StoryEngine.Radio.channel(fid).trust = v end
local function res(fid, r) return StoryEngine.Life.npc(fid).res[r] end
local S = function() return StoryEngine.Specialty end

function T.status_tiers_and_reasons()
    setup()
    local Sp = S()
    H.eq(Sp.status("hunter").reason, "low_trust")
    setTrust("hunter", 45)
    local st = Sp.status("hunter")
    H.eq(st.tier, 1)
    H.eq(st.reason, nil)
    setTrust("hunter", 65)
    H.eq(Sp.status("hunter").tier, 2)
    setTrust("hunter", 85)
    H.eq(Sp.status("hunter").tier, 3)
    StoryEngine.Life.npc("hunter").res.safety = 15
    H.eq(Sp.status("hunter").reason, "no_resource")
    StoryEngine.Life.npc("hunter").res.safety = 60
    SandboxVars.StoryEngine.Specialty = false
    H.eq(Sp.status("hunter").reason, "off")
end

function T.hunter_snipe_request_cooldown_and_cost()
    local p = setup()
    local Sp = S()
    setTrust("hunter", 65)
    local ok, why = Sp.request(p, "hunter", {})
    H.eq(ok, false)
    H.eq(why, "no_targets", "no zombies: refused")
    H.eq(Sp.status("hunter").wait, 0, "refusal costs nothing")
    H.newZombie(10010, 10010)
    H.ok(Sp.request(p, "hunter", {}), "sniping granted")
    local sent = H.sentOf("specSnipe")[1]
    H.eq(sent.count, 20, "tier 2 -> 20")
    H.eq(sent.minutes, 30, "spread over half an hour")
    H.eq(sent.sound, "MSR788Shoot")
    H.eq(sent.radius, 30)
    H.eq(Sp.status("hunter").wait, 72, "3 days")
    H.eq(res("hunter", "safety"), 50, "key resource -10")
    local log = StoryEngine.Life.npc("hunter").log
    H.eq(log[#log].kind, "specialty")
    H.ok(H.lastBridge("radio", "event"), "hank talks about it")
    Sp.snipeDone(p, "hunter", 99)
    local ps = StoryEngine.Store.player(p)
    H.eq(ps.notes[#ps.notes].kind, "specialty_snipe")
    H.eq(ps.notes[#ps.notes].count, 20, "kills clamped to what was asked")
end

function T.guard_without_alife_snipes_twice_hank_four_times_slower()
    local p = setup()
    setTrust("guard", 85)
    H.newZombie(10005, 10000)
    H.ok(S().request(p, "guard", {}))
    local sent = H.sentOf("specSnipe")[1]
    H.eq(sent.count, 60, "tier 3: twice Hank's 30")
    H.eq(sent.minutes, 240, "twice the shots at 4x the interval = 4 hours")
    H.near(sent.minutes / sent.count, 4 * (30 / 30), 0.001, "4x Hank's shot interval")
    H.eq(sent.sound, "M14Shoot")
    H.ok(string.find(H.lastBridge("radio", "event").payload.topic, "the next 4 hours", 1, true))
    H.eq(S().status("guard").wait, 7 * 24, "7 days")
    H.eq(res("guard", "safety"), 60, "tier 3 costs 15")
end

function T.doc_heal_flow_and_limits()
    local p = setup()
    local Sp = S()
    setTrust("doc", 65)                                -- 구간 2
    local ok, why = Sp.request(p, "doc", {})
    H.eq(why, "no_wounds")
    local arm = H.newBodyPart("arm", { scratch = true })
    local leg = H.newBodyPart("leg", { deep = true, bleed = 5 })
    local chest = H.newBodyPart("chest", { bullet = true })
    local hand = H.newBodyPart("hand", { bitten = true, infected = true, bleed = 3 })
    p.parts = { arm, leg, chest, hand }
    local info
    ok, info = Sp.request(p, "doc", {})
    H.ok(ok and info.pending, "waits for the client")
    H.eq(#H.sentOf("specHealStart"), 1)
    H.eq(Sp.status("doc").wait, 0, "not committed yet")
    local done, n = Sp.healDone(p)
    H.ok(done, "healed")
    -- 가장 심각한 상처 하나만: 깊은 상처 (긁힘·물린 손 출혈은 그대로, 2026-09-30)
    H.eq(n, 1)
    H.eq(leg.deep, false)
    H.eq(leg.bleed, 0)
    H.eq(arm.scratch, true, "only the worst wound")
    H.eq(chest.bullet, true, "bullets need tier 3")
    H.eq(hand.bit, true, "bite untouched")
    H.eq(hand.infected, true, "zombie infection untouched")
    H.ok(#H.synced >= 1, "body part synced")
    H.eq(Sp.status("doc").wait, 7 * 24)
    H.eq(res("doc", "medical"), 55 - 10, "fixed cost 10")
    local again, why2 = Sp.healDone(p)
    H.eq(again, false)
    H.eq(why2, "expired", "no pending treatment")
end

function T.doc_tier3_bullet_burn_fracture()
    local p = setup()
    setTrust("doc", 90)
    local chest = H.newBodyPart("chest", { bullet = true, burn = 20, fracture = 30, pain = 50 })
    p.parts = { chest }
    H.ok(S().request(p, "doc", {}))
    H.ok(S().healDone(p))
    H.eq(chest.bullet, false, "bullet first")
    H.eq(chest.burn, 20, "burn waits")
    H.eq(chest.fracture, 30, "fracture waits")
    H.eq(chest.pain, 0)
    local b = H.lastBridge("radio", "event")
    H.ok(string.find(b.payload.topic, "(bullet)", 1, true), "doc knows what was treated")
end

function T.doc_heal_expires()
    local p = setup()
    setTrust("doc", 45)
    p.parts = { H.newBodyPart("arm", { cut = true }) }
    H.ok(S().request(p, "doc", {}))
    H.realMs = H.realMs + 3 * 60 * 1000
    local ok, why = S().healDone(p)
    H.eq(ok, false)
    H.eq(why, "expired")
    H.eq(S().status("doc").wait, 0, "expired treatment costs nothing")
end

function T.dewey_repairs_after_delay()
    local p = setup()
    local Sp = S()
    setTrust("dewey", 45)
    local ok, why = Sp.request(p, "dewey", {})
    H.eq(why, "no_vehicle")
    local v = H.newVehicle(10005, 10000, { { id = "Engine", cond = 20 }, { id = "Tire", cond = 60 },
                                           { id = "EngineBlock", cond = 20, engine = true },
                                           { id = "Door", cond = 95 }, { id = "Battery", cond = 50 } })
    H.ok(Sp.request(p, "dewey", {}), "job scheduled")
    H.eq(Sp.status("dewey").wait, 7 * 24)
    H.advance(7 * 60)
    H.fire("EveryOneMinute")
    H.eq(v.parts[1].cond, 20, "not before 8 hours")
    H.advance(4 * 60)
    H.fire("EveryOneMinute")
    H.eq(v.parts[1].cond, 50, "+30")
    H.eq(v.parts[2].cond, 70, "capped at 70")
    H.eq(v.parts[3].cond, 35, "engine-type part: half of +30")
    H.eq(v.parts[4].cond, 95, "already better than the cap")
    H.ok(v.sent >= 3, "conditions transmitted")
    H.ok(H.lastBridge("radio", "event"), "dewey reports")
    local ps = StoryEngine.Store.player(p)
    H.eq(ps.notes[#ps.notes].kind, "specialty_dewey_done")
    H.eq(#StoryEngine.Store.data().spec.jobs, 0, "job done")
end

function T.dewey_repairs_the_chosen_car_even_if_moved()
    local p = setup()
    setTrust("dewey", 45)
    local chosen = H.newVehicle(10003, 10000, { { id = "Door", cond = 10 } })
    local far = H.newVehicle(10050, 10000, { { id = "Door", cond = 10 } })
    H.ok(S().request(p, "dewey", {}))
    -- 기다리는 동안 고른 차를 몰고 가고, 원래 자리에 다른 차가 선다
    chosen.x = 10400
    local other = H.newVehicle(10003, 10000, { { id = "Door", cond = 10 } })
    chosen.id, other.id = 99, 98          -- 다시 불러오면 실행 중 id 는 바뀐다
    H.advance(11 * 60)
    H.fire("EveryOneMinute")
    H.eq(chosen.parts[1].cond, 40, "the car chosen at request time, wherever it is")
    H.eq(other.parts[1].cond, 10, "not the car now parked at the old spot")
    H.eq(far.parts[1].cond, 10)
end

function T.dewey_debug_clear_makes_repair_due()
    local p = setup()
    setTrust("dewey", 45)
    local v = H.newVehicle(10003, 10000, { { id = "Engine", cond = 10 } })
    H.ok(S().request(p, "dewey", {}))
    StoryEngine.Commands.debugLife(p, { faction = "dewey", delta = 0, clearSpec = true })
    H.advance(1)
    H.fire("EveryOneMinute")
    H.eq(v.parts[1].cond, 40, "repaired right away after debug clear")
end

function T.dewey_tier3_full_and_battery()
    local p = setup()
    setTrust("dewey", 85)
    local v = H.newVehicle(10002, 10000, { { id = "Engine", cond = 20, engine = true }, { id = "Battery", cond = 50 },
                                           { id = "TireFrontLeft", cond = 0, missing = true } })
    H.ok(S().request(p, "dewey", {}))
    H.advance(11 * 60)
    H.fire("EveryOneMinute")
    H.eq(v.parts[1].cond, 70, "engine (no item slot) repaired at half: 20 + 50")
    H.eq(v.parts[3].cond, 0, "missing tire not replaced")
    H.eq(v.parts[2].item.charge, 1.0, "battery charged")
end

function T.casey_scout_marks_warnings_and_expiry()
    local p = setup()
    setTrust("casey", 85)
    local key = StoryEngine.Store.playerKey(p)
    local d = StoryEngine.Store.data()
    d.hunts = { H1 = { id = "H1", target = key, remaining = 12, x = 10100, y = 10000 } }
    for i = 1, 16 do H.newZombie(10050 + (i % 4), 10050 + math.floor(i / 4)) end
    H.ok(S().request(p, "casey", {}))
    local marks = H.sentOf("scoutMarks")[1].marks
    local kinds = {}
    for _, m in ipairs(marks) do kinds[m.kind] = (kinds[m.kind] or 0) + 1 end
    H.eq(kinds.hunt, 1, "hunt marked")
    H.eq(kinds.horde, 1, "zombie crowd marked")
    H.eq(#H.sentOf("monologue"), 0, "nothing close yet")
    d.hunts.H1.x = 10030
    H.advance(1)
    H.fire("EveryOneMinute")
    local mono = H.sentOf("monologue")
    H.eq(#mono, 1, "warned once")
    H.eq(mono[1].lt.key, "IGUI_StoryEngine_Scout_Warn_hunt")
    H.eq(mono[1].lt.args[1].v, "E")
    H.eq(mono[1].lt.args[2].v, 30)
    H.advance(1)
    H.fire("EveryOneMinute")
    H.eq(#H.sentOf("monologue"), 1, "not again within 30 minutes")
    H.advance(12 * 60)
    H.fire("EveryOneMinute")
    local all = H.sentOf("scoutMarks")
    H.eq(#all[#all].marks, 0, "marks cleared at the end")
end

function T.casey_tier1_only_hunts()
    local p = setup()
    setTrust("casey", 45)
    for i = 1, 16 do H.newZombie(10050 + (i % 4), 10050) end
    H.ok(S().request(p, "casey", {}))
    H.eq(#H.sentOf("scoutMarks")[1].marks, 0)
end

function T.ray_supplies_lowest_resources()
    local p = setup()
    local Sp = S()
    setTrust("ray", 65)
    local ok, why = Sp.request(p, "ray", { target = "rats" })
    H.eq(why, "ray_refuses", "not to Vic below tier 3")
    H.eq(Sp.status("ray").wait, 0)
    StoryEngine.Life.npc("doc").res.food = 10
    H.ok(Sp.request(p, "ray", { target = "doc" }))
    H.eq(res("doc", "food"), 35)
    H.eq(res("doc", "safety"), 35, "then the next lowest")
    H.eq(res("ray", "food"), 30, "ray pays 15 food")
    H.eq(StoryEngine.Radio.channel("doc").trust, 26, "doc trust +1")
    H.ok(H.lastBridge("radio", "event"), "someone thanks")
    local ps = StoryEngine.Store.player(p)
    H.eq(ps.notes[#ps.notes].kind, "specialty_ray")
end

function T.pike_comfort_companions_and_stiffness()
    local p = setup()
    local friend = H.addPlayer("friend", "Ann", "Lee")
    friend.x = 10004
    local far = H.addPlayer("far", "Bo", "Kim")
    far.x = 10500
    setTrust("pike", 85)
    friend.parts = { H.newBodyPart("back", { stiff = 40 }) }
    H.ok(S().request(p, "pike", {}))
    local sent = H.sentOf("specComfort")
    H.eq(#sent, 2, "requester and nearby friend (singleplayer dispatch records each)")
    H.eq(sent[1].hours, 12)
    H.near(sent[1].reduce, 0.8)
    H.advance(1)
    H.fire("EveryOneMinute")
    H.eq(friend.parts[1].stiff, 0, "muscle strain cleared")
    friend.parts[1].stiff = 30
    H.advance(13 * 60)
    H.fire("EveryOneMinute")
    H.eq(friend.parts[1].stiff, 30, "effect over after 12 hours")
end

function T.rats_decoy_noise()
    local p = setup()
    setTrust("rats", 45)
    H.ok(S().request(p, "rats", {}))
    H.advance(1)
    H.fire("EveryOneMinute")
    H.eq(#H.sounds, 1)
    local snd = H.sounds[1]
    H.eq(snd.radius, 80)
    local d = math.sqrt((snd.x - 10000) ^ 2 + (snd.y - 10000) ^ 2)
    H.ok(d >= 59 and d <= 81, "60-80 tiles away: " .. tostring(d))
    H.advance(40)
    H.fire("EveryOneMinute")
    local n = #H.sounds
    H.advance(1)
    H.fire("EveryOneMinute")
    H.eq(#H.sounds, n, "stops after 10-30 minutes")
end

function T.commands_and_life_list_spec()
    local p = setup()
    setTrust("hunter", 45)
    StoryEngine.Commands.lifeList(p, {})
    local hunter
    for _, n in ipairs(H.sentOf("lifeList")[1].npcs) do if n.id == "hunter" then hunter = n end end
    H.eq(hunter.spec.tier, 1)
    StoryEngine.Commands.specialtyRequest(p, { faction = "hunter" })
    local r = H.sentOf("specialtyResult")[1]
    H.eq(r.ok, false)
    H.eq(r.error, "no_targets")
    H.newZombie(10003, 10003)
    StoryEngine.Commands.specialtyRequest(p, { faction = "hunter" })
    H.ok(H.sentOf("specialtyResult")[2].ok)
    StoryEngine.Commands.debugLife(p, { faction = "hunter", delta = 0, clearSpec = true })
    H.eq(S().status("hunter").wait, 0, "debug clears cooldown")
end

local function gun(r, v)
    local w = { r = r, v = v, mod = {}, __classes = { HandWeapon = true, InventoryItem = true } }
    function w:isRanged() return true end
    function w:getSoundRadius() return self.r end
    function w:getSoundVolume() return self.v end
    function w:setSoundRadius(x) self.r = x end
    function w:setSoundVolume(x) self.v = x end
    function w:getModData() return self.mod end
    function w:getFullType() return "Base.AssaultRifle" end
    return w
end

function T.alife_suppressor_hand_and_inventory_and_restore()
    setup()
    local held, holstered = gun(170, 100), gun(80, 60)
    local knife = { __classes = { HandWeapon = true }, isRanged = function() return false end }
    local shell = { mod = { ProjectALifeUID = "u1" } }
    function shell:getPrimaryHandItem() return held end
    function shell:getInventory() return { getItems = function() return H.list({ held, holstered, knife }) end } end
    function shell:getModData() return self.mod end
    rawset(_G, "ProjectALife", { Watchdog = { bindings = { u1 = { shell = shell } } } })
    StoryEngine.ALife.suppress("u1")
    H.eq(held.r, 42, "held gun radius x0.25")
    H.eq(held.v, 25)
    H.eq(holstered.r, 20, "holstered gun too")
    H.ok(H.logHas("alife suppressor u1"), "logged")
    StoryEngine.ALife.suppress("u1")
    H.eq(held.r, 42, "not applied twice")
    StoryEngine.ALife.isSupport = function() return true end
    H.fire("OnZombieDead", shell)
    H.eq(held.r, 170, "restored on death")
    H.eq(holstered.v, 60)
end

function T.alife_suppressor_logs_why_not()
    setup()
    rawset(_G, "ProjectALife", { Watchdog = { bindings = {} } })
    StoryEngine.ALife.suppress("u9")
    H.ok(H.logHas("alife suppressor skipped u9 no shell binding"))
end


function T.specialty_reply_also_shows_overhead()
    local p = setup()
    setTrust("hunter", 65)
    H.newZombie(10010, 10010)
    H.ok(S().request(p, "hunter", {}))
    local req = H.lastBridge("radio", "event")
    req.callback({ ok = true, json = { reply = "On my way. Keep your head down." } })
    local o = H.sentOf("radioOverhead")
    H.eq(#o, 1, "reply goes over the requester's head")
    H.eq(o[1].faction, "hunter")
    H.eq(o[1].text, "On my way. Keep your head down.")
    -- AI 가 실패해도 준비된 문장이 뜬다
    setTrust("pike", 65)
    H.ok(S().request(p, "pike", {}))
    H.lastBridge("radio", "event").callback({ ok = false, error = "timeout" })
    o = H.sentOf("radioOverhead")
    H.eq(#o, 2)
    H.eq(o[2].lt.key, "IGUI_StoryEngine_RadioSay_spec_pike", "prepared line")
    -- 특기가 아닌 NPC 반응은 머리 위에 안 뜬다
    StoryEngine.Radio.react("ray", "event", "Say hi.", nil, StoryEngine.Store.player(p))
    H.lastBridge("radio", "event").callback({ ok = true, json = { reply = "Hi." } })
    H.eq(#H.sentOf("radioOverhead"), 2)
end


function T.alife_spawn_spot_avoids_player_base()
    -- 플레이어 거점: (9980..10020, 9980..10020). A-Life 는 거점 + 여유 안이면 그룹 전체를 취소한다
    ProjectALife = { SpawnPolicy = { safehouseMargin = 8, inPlayerBase = function(pos, margin)
        return pos.x >= 9980 - margin and pos.x <= 10020 + margin and pos.y >= 9980 - margin and pos.y <= 10020 + margin
    end } }
    local A = StoryEngine.ALife
    H.ok(A.protectedAt(10010, 10010), "inside the base")
    H.ok(A.protectedAt(10035, 10000), "inside the margin (8 + 8)")
    H.ok(not A.protectedAt(10040, 10000), "outside")
    local x, y, d, moved = A.spawnSpot(10000, 10000, { 10, 15 })
    H.ok(not A.protectedAt(x, y), "picked a spot outside the base")
    H.ok(moved, "had to go further out")
    H.ok(d >= 20, "far spot " .. tostring(d))
    -- 거점이 없으면 원래 거리 그대로
    ProjectALife = nil
    x, y, d, moved = A.spawnSpot(10000, 10000, { 10, 15 })
    H.ok(d >= 10 and d <= 15 and not moved)
end


function T.alife_support_gives_up_and_refunds_cooldown()
    local p, ps = setup()
    local watchers = {}
    ProjectALife = {
        Runtime = { started = true }, ActorRegistry = {}, Catalog = {},
        DebugService = {
            spawnEncounter = function() return true end,
            watchGroup = function(id, fn) watchers[#watchers + 1] = fn end,
        },
    }
    local A = StoryEngine.ALife
    A.pickSquad = function() return "alife_gunclub", { "a", "b", "c", "d" } end
    A.installGuards = function() end
    setTrust("ray", 75)
    H.ok(A.sendSupport(p, "ray", "auto", "surrounded"))
    local st = StoryEngine.Store.data().alife
    H.ok(st.autoAt[ps.key], "cooldown starts when sent")
    -- A-Life 가 그룹을 취소 (거점 안): 한 번 더 부른다
    watchers[1]({ actorUids = {}, reason = "inside_player_base" })
    H.eq(#watchers, 2, "retried once")
    H.ok(st.autoAt[ps.key], "still waiting on the retry")
    -- 또 취소되면 대기 시간을 돌려주고 무전으로 알린다
    watchers[2]({ actorUids = {}, reason = "inside_player_base" })
    H.eq(#watchers, 2, "no third try")
    H.eq(st.autoAt[ps.key], nil, "auto support cooldown refunded")
    H.ok(H.logHas("alife support gave up, cooldown refunded"))
    -- "보냈다" 무전이 끝나면 바로잡는 무전이 이어서 나간다 (채널 대기열)
    H.lastBridge("radio", "event").callback({ ok = true, json = { reply = "Sending my people." } })
    local b = H.lastBridge("radio", "event")
    H.ok(b and string.find(b.payload.topic, "could not get through", 1, true), "correction on the radio")
    ProjectALife = nil
end


function T.pike_comfort_changes_stats_on_the_server()
    local p = setup()
    CharacterStat = { STRESS = "STRESS", UNHAPPINESS = "UNHAPPINESS", BOREDOM = "BOREDOM", PANIC = "PANIC" }
    local values = { STRESS = 0.8, UNHAPPINESS = 60, BOREDOM = 90, PANIC = 50 }
    function p:getStats()
        return { get = function(_, k) return values[k] end, set = function(_, k, v) values[k] = v end }
    end
    setTrust("pike", 65)                                   -- 구간 2: 50% 감소, 6시간 두려움 없음
    H.ok(S().request(p, "pike", {}))
    H.eq(values.BOREDOM, 45, "boredom halved by the server (multiplayer keeps it)")
    H.eq(values.UNHAPPINESS, 30)
    H.near(values.STRESS, 0.4, 0.001)
    values.PANIC = 70
    H.advance(1)
    H.fire("EveryOneMinute")
    H.eq(values.PANIC, 0, "server keeps fear at zero")
    local c = StoryEngine.Store.data().spec.comfort[StoryEngine.Store.player(p).key]
    H.eq(c.stiff, false, "tier 2: no muscle strain effect")
    H.advance(7 * 60)
    H.fire("EveryOneMinute")
    values.PANIC = 70
    H.fire("EveryOneMinute")
    H.eq(values.PANIC, 70, "window over")
end


function T.guard_checkpoint_adds_20_snipes_without_alife()
    local p = setup()
    setTrust("guard", 45)
    H.newZombie(10005, 10000)
    StoryEngine.Projects.add("guard", 1000)
    H.ok(S().request(p, "guard", {}))
    H.eq(H.sentOf("specSnipe")[1].count, 40, "tier 1: 20 + 20")
end

-- 특기 대기 범위·일수 (2026-10-05 샌드박스): 레이만 서버 전체, 나머지 개인별, 둘 다, 일수 옵션
local function twoPlayers()
    local p1 = H.addPlayer("tester", "Gerald", "Kar")
    local p2 = H.addPlayer("other", "Ann", "Lee")
    for _, p in ipairs({ p1, p2 }) do StoryEngine.Store.player(p).lang = "EN" end
    return p1, p2, StoryEngine.Store.player(p1), StoryEngine.Store.player(p2)
end

function T.specialty_waits_are_per_player_except_ray()
    local p1, p2, ps1, ps2 = twoPlayers()
    local Sp = S()
    H.eq(Sp.scope("hunter"), 2)
    H.eq(Sp.scope("ray"), 1)
    setTrust("hunter", 65)
    Sp.commit("hunter", ps1, 2, {})
    H.eq(Sp.status("hunter", ps1.key).reason, "cooldown", "the user waits")
    H.eq(Sp.status("hunter", ps2.key).wait, 0, "someone else can still ask Hank")
    setTrust("ray", 65)
    Sp.commit("ray", ps1, 2, {})
    H.eq(Sp.status("ray", ps2.key).reason, "cooldown", "Ray's supplies wait for everyone")
end

function T.specialty_scope_both_and_days_option()
    local p1, p2, ps1, ps2 = twoPlayers()
    local Sp = S()
    SandboxVars.StoryEngine.SpecialtyScope_hunter = 3
    SandboxVars.StoryEngine.SpecialtyDays_hunter = 5
    StoryEngine.Tuning.apply()
    setTrust("hunter", 65)
    Sp.commit("hunter", ps1, 2, {})
    H.eq(Sp.status("hunter", ps1.key).wait, 5 * 24, "the user waits the option's days")
    H.eq(Sp.status("hunter", ps2.key).wait, 24, "everyone else one day")
    H.advanceDays(1)
    H.eq(Sp.status("hunter", ps2.key).wait, 0)
    H.ok(Sp.status("hunter", ps1.key).wait > 0)
    SandboxVars.StoryEngine.SpecialtyScope_hunter = 1
    H.ok(Sp.status("hunter", ps2.key).wait > 0, "server-wide: everyone waits the full days")
    SandboxVars.StoryEngine.SpecialtyDays_hunter = nil
    SandboxVars.StoryEngine.SpecialtyScope_hunter = nil
    StoryEngine.Tuning.apply()
end

function T.specialty_refund_clears_only_that_player()
    local p1, p2, ps1, ps2 = twoPlayers()
    local Sp = S()
    setTrust("guard", 65)
    Sp.commit("guard", ps1, 2, {})
    Sp.commit("guard", ps2, 2, {})
    Sp.clearWait("guard", ps1.key)
    H.eq(Sp.status("guard", ps1.key).wait, 0, "refunded")
    H.ok(Sp.status("guard", ps2.key).wait > 0, "the other player's wait stays")
    Sp.clearWait("guard")
    H.eq(Sp.status("guard", ps2.key).wait, 0, "debug clears everyone")
end

return T
