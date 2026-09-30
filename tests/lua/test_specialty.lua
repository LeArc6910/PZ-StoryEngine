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
    H.eq(ps.notes[#ps.notes].count, 30, "kills clamped")
end

function T.guard_without_alife_snipes_30_at_tier3()
    local p = setup()
    setTrust("guard", 85)
    H.newZombie(10005, 10000)
    H.ok(S().request(p, "guard", {}))
    local sent = H.sentOf("specSnipe")[1]
    H.eq(sent.count, 30)
    H.eq(sent.sound, "M14Shoot")
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
    -- 긁힘 1 + 깊은 상처 1 + 물린 손 출혈 1 (물림·감염은 그대로)
    H.eq(n, 3)
    H.eq(arm.scratch, false)
    H.eq(leg.deep, false)
    H.eq(leg.bleed, 0)
    H.eq(chest.bullet, true, "bullets need tier 3")
    H.eq(hand.bit, true, "bite untouched")
    H.eq(hand.infected, true, "zombie infection untouched")
    H.ok(#H.synced >= 3, "body parts synced")
    H.eq(Sp.status("doc").wait, 7 * 24)
    H.eq(res("doc", "medical"), 55 - 20, "cost 5 + 5 per injury, max 20")
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
    H.eq(chest.bullet, false)
    H.eq(chest.burn, 0)
    H.eq(chest.fracture, 0)
    H.eq(chest.pain, 0)
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

return T
