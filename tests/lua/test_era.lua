-- 카운티 회의의 결실 (Era.lua, 2026-10-10 사용자 결정): 의회가 서면 의회 시대(전기·수도, 고갈로 안 떠남, 의회의 날,
-- 2차 특기 바꾸기 자유), 교회를 지키면 생존자들의 선물, 결과와 상관없이 헌장과 에필로그
local T = {}

local function now() return StoryEngine.Sensor.now() end

-- 바닐라 SandboxOptions 흉내 (test_grid 와 같음)
local function mockSandbox(elec, water)
    local so = { values = { ElecShutModifier = elec, WaterShutModifier = water } }
    function so:set(name, v) self.values[name] = v end
    function so:getElecShutModifier() return self.values.ElecShutModifier end
    function so:getWaterShutModifier() return self.values.WaterShutModifier end
    function so:getTimeSinceApo() return 1 end
    function so:toLua() SandboxVars.ElecShutModifier = self.values.ElecShutModifier; SandboxVars.WaterShutModifier = self.values.WaterShutModifier end
    function so:doesPowerGridExist() return getGameTime():getWorldAgeHours() / 24 < self.values.ElecShutModifier end
    getSandboxOptions = function() return so end
    local world = {}
    function world:setHydroPowerOn() end
    getWorld = function() return world end
    return so
end

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    H.clockMin = 300 * 1440 + 8 * 60
    return p, ps
end

local function trustAll(v)
    for _, f in ipairs(StoryEngine.Factions.list) do StoryEngine.Radio.channel(f.id).trust = v end
end

-- 교회 사수까지 온 회의. held = 교회를 지켰는가, prep = 모금 비율
local function atSiege(ps, held, prep)
    local Council = StoryEngine.Council
    local s = Council.state()
    s.stage, s.prep, s.hordeId = "horde", prep or 1, "HQ"
    StoryEngine.Store.data().quests.HQ = {
        id = "HQ", kind = "defend", state = held and "completed" or "failed", cx = 100, cy = 100, origin = { council = true },
        siege = { total = 1000, waves = 12, wave = 84, sent = 600, held = 400, present = { [ps.key] = ps.name } },
    }
    return s
end

local function has(p, fullType)
    for _, it in ipairs(p.items) do
        if it.fullType == fullType then return it end
    end
    return nil
end

function T.a_council_that_forms_starts_the_council_era()
    local so = mockSandbox(14, 10)
    local p, ps = setup()
    local Era, Council = StoryEngine.Era, StoryEngine.Council
    trustAll(60)
    H.ok(not Era.active())
    atSiege(ps, true, 1)
    Council.finish(now())
    H.eq(Council.state().result, "formed")
    H.ok(Era.active(), "the council era begins")
    -- 전기·수도가 다시는 끊기지 않는다
    local today = math.floor(StoryEngine.Grid.today())
    H.eq(so.values.ElecShutModifier, today + Era.FOREVER_DAYS)
    H.eq(so.values.WaterShutModifier, today + Era.FOREVER_DAYS)
    H.ok(not StoryEngine.World.powerOff() and not StoryEngine.World.waterOff(), "power and water are back")
    H.eq(#H.sentOf("eraNotice"), 1)
    -- 2차 특기: 언제든 바꾼다
    ps.spec2 = { ray = { opt = "stew", t = now().t } }
    H.eq(StoryEngine.Specialty2.changeWait(ps, "ray", now().t), 0, "no thirty-day lock in the council era")
    -- 고갈: 떠나지 않고 카운티가 나눠 준다
    local Life = StoryEngine.Life
    for _, r in ipairs(Life.RESOURCES) do Life.npc("hunter").res[r] = 3 end
    for _ = 1, 5 do StoryEngine.Fate.daily() end
    H.ok(not StoryEngine.Factions.isGone("hunter"), "nobody leaves hungry in the council era")
    H.eq(Life.get("hunter", "food"), Era.RELIEF_TO)
    H.ok(H.logHas("era relief hunter"))
    -- 한 번만
    H.eq(Era.begin(now()), false)
end

function T.without_the_council_era_the_lock_and_hunger_stay()
    mockSandbox(14, 10)
    local p, ps = setup()
    local Era, Council = StoryEngine.Era, StoryEngine.Council
    trustAll(10)
    atSiege(ps, false, 0)
    Council.finish(now())
    H.eq(Council.state().result, "failed")
    H.ok(not Era.active())
    H.ok(StoryEngine.World.powerOff(), "the lights stay off")
    ps.spec2 = { ray = { opt = "stew", t = now().t } }
    H.ok(StoryEngine.Specialty2.changeWait(ps, "ray", now().t) > 0)
    H.eq(Era.relief("hunter"), false)
    H.eq(Era.holiday(), nil)
end

function T.those_who_trust_you_each_send_a_keepsake()
    mockSandbox(14, 10)
    local p, ps = setup()
    local Era, Council, Radio = StoryEngine.Era, StoryEngine.Council, StoryEngine.Radio
    trustAll(10)
    Radio.channel("guard").trust = 85
    Radio.channel("hunter").trust = 60
    Radio.channel("pike").trust = 70
    -- 자리에 없는 사람도 교회를 지켰다
    StoryEngine.Store.data().players.ghost = { key = "ghost", name = "Ghost", journal = {}, notes = {} }
    local s = atSiege(ps, true, 1)
    StoryEngine.Store.data().quests.HQ.siege.present.ghost = "Ghost"
    Council.finish(now())
    H.eq(#Era.givers(), 3)
    local rifle = has(p, "Base.AssaultRifle")
    H.ok(rifle, "Whitaker's rifle")
    H.eq(rifle.mod.seGiftFrom, "guard")
    H.eq(rifle.mod.seGiftKey, "rifle")
    H.ok(has(p, "Base.556Box") and not has(p, "Base.556Box").mod.seGiftFrom, "only the keepsake itself is marked")
    H.eq(has(p, "Base.HuntingKnife").mod.seGiftFrom, "hunter")
    H.eq(has(p, "Base.Necklace_Crucifix").mod.seGiftFrom, "pike")
    H.ok(not has(p, "Base.HamRadio1"), "Casey does not know them well enough")
    local sent = H.sentOf("councilGifts")
    H.eq(#sent, 1)
    H.eq(#sent[1].gifts, 3)
    H.ok(sent[1].charter, "and the charter")
    H.ok(has(p, "StoryEngine.Charter"))
    H.ok(s.defenders[ps.key], "remembered as someone who held the church")
    -- 5등급 보급은 선물로 바뀌었다
    for _, q in pairs(StoryEngine.Store.data().quests) do
        H.ok(q.kind ~= "supply_drop", "no supply drop when there are gifts")
    end
    -- 자리에 없던 사람은 다음에 접속하면 받는다
    H.ok(s.owed.ghost and #s.owed.ghost.gifts == 3, "kept for the one who is away")
    H.eq(s.owed[ps.key], nil)
    -- 다시 돌아도 두 번 주지 않는다
    local count = #p.items
    Era.deliver()
    H.eq(#p.items, count)
end

function T.dewey_gives_one_car_and_wrenches_to_the_rest()
    mockSandbox(14, 10)
    local p, ps = setup()
    local Era = StoryEngine.Era
    trustAll(10)
    StoryEngine.Radio.channel("dewey").trust = 90
    local key = H.newItem("Base.CarKey")
    local made = 0
    StoryEngine.Specialty2.giftVehicle = function(player, script)
        made = made + 1
        return { script = script }, key
    end
    local g = Era.givers()[1]
    H.eq(g.fid, "dewey")
    H.ok(Era.giveGift(p, g) >= 1)
    H.eq(made, 1)
    H.eq(key.mod.seGiftKey, "car", "the key is the keepsake")
    H.ok(not has(p, "Base.LugWrench"))
    -- 두 번째 사람은 렌치
    local p2 = H.addPlayer("second", "Ann", "Lee")
    H.ok(Era.giveGift(p2, g) >= 1)
    H.eq(made, 1, "one car for the group")
    H.eq(has(p2, "Base.LugWrench").mod.seGiftKey, "wrench")
end

function T.a_failed_council_leaves_a_draft_charter()
    mockSandbox(14, 10)
    local p, ps = setup()
    local Era, Council = StoryEngine.Era, StoryEngine.Council
    trustAll(10)
    StoryEngine.Radio.channel("ray").trust = 55
    StoryEngine.Life.npc("doc").fate = { kind = "dead", reason = "debug", day = 200 }
    atSiege(ps, false, 0)
    Council.finish(now())
    H.eq(Council.state().result, "failed")
    local charter = has(p, "StoryEngine.Charter")
    H.ok(charter and charter.mod.storyLetter, "even a failed council leaves its paper")
    local info = StoryEngine.Letters.read(p, charter.mod.storyLetter)
    H.ok(info and info.charter)
    H.eq(info.charter.formed, false)
    H.eq(#info.charter.signed, 1, "only Ray trusts them enough to sign a draft")
    H.eq(info.charter.signed[1].fid, "ray")
    H.eq(#info.charter.unsigned, 6)
    H.eq(#info.charter.blanks, 1)
    H.eq(info.charter.blanks[1].fid, "doc")
    H.eq(info.charter.blanks[1].fate, "dead")
    H.eq(#H.sentOf("councilGifts")[1].gifts, 0, "no gifts: the church fell")
    StoryEngine.Life.npc("doc").fate = nil
end

function T.the_epilogue_is_written_and_listed_in_the_journal()
    mockSandbox(14, 10)
    local p, ps = setup()
    local Era, Council = StoryEngine.Era, StoryEngine.Council
    trustAll(70)
    atSiege(ps, true, 1)
    Council.finish(now())
    local b = H.lastBridge("epilogue")
    H.ok(b, "asked the bridge for the chronicle")
    H.eq(b.payload.result, "formed")
    H.eq(b.payload.held, true)
    H.eq(#b.payload.npcs, 8)
    H.eq(#b.payload.signers, 8)
    H.eq(b.payload.players[1].name, ps.name)
    H.eq(b.payload.players[1].defender, true)
    H.eq(b.payload.siege.total, 1000)
    H.eq(Era.epilogueFor().status, "writing")
    -- 목록 맨 위 한 줄
    local authors = StoryEngine.Journal.authors(ps.key)
    H.ok(authors[1].epilogue, "the chronicle leads the journal list")
    b.callback({ ok = true, json = { title = "The Year at March Ridge", text = "It was a long year.",
                                     signatures = { { faction = "ray", line = "Signed, Ray." }, { faction = "nobody", line = "x" } } } })
    local ep = Era.epilogueFor()
    H.eq(ep.status, "ready")
    H.eq(ep.text, "It was a long year.")
    H.eq(ep.era, true)
    -- 서명 줄은 헌장으로
    local info = StoryEngine.Letters.read(p, Council.state().charterId)
    local ray
    for _, g in ipairs(info.charter.signed) do if g.fid == "ray" then ray = g end end
    H.eq(ray.text, "Signed, Ray.")
    H.eq(#info.charter.signed, 8)
    -- 일지 탭 요청
    H.sent = {}
    StoryEngine.Commands.journalList(p, { epilogue = true })
    local reply = H.sentOf("journalList")[1]
    H.ok(reply and reply.epilogue and reply.epilogue.text == "It was a long year.")
    -- 호칭: 교회를 지킨 사람
    local ctx = Era.context(ps)
    H.eq(ctx.result, "formed")
    H.eq(ctx.defender, true)
    H.eq(Era.context({ key = "stranger" }).defender, nil)
end

function T.the_epilogue_survives_a_missing_bridge()
    mockSandbox(14, 10)
    local p, ps = setup()
    local Era, Council = StoryEngine.Era, StoryEngine.Council
    trustAll(70)
    atSiege(ps, true, 1)
    Council.finish(now())
    H.lastBridge("epilogue").callback({ ok = false, error = "bridge_offline" })
    local ep = Era.epilogueFor()
    H.eq(ep.status, "failed")
    H.eq(ep.text, nil)
    H.ok(#ep.npcs == 8 and ep.npcs[1].fid, "the client can still tell it from the story so far")
end

function T.council_day_comes_round_the_next_year()
    mockSandbox(14, 10)
    local p, ps = setup()
    local Era, Council, Holiday = StoryEngine.Era, StoryEngine.Council, StoryEngine.Holiday
    trustAll(60)
    atSiege(ps, true, 1)
    Council.finish(now())
    local h = Era.holiday()
    H.ok(h and h.id == "councilday" and h.fromYear == 1993)
    local function found()
        for _, u in ipairs(Holiday.upcoming()) do
            if u.h.id == "councilday" then return u end
        end
        return nil
    end
    H.eq(found(), nil, "not in the year it was founded")
    local year = H.gt.getYear
    H.gt.getYear = function() return 1994 end
    local u = found()
    H.gt.getYear = year
    H.ok(u, "a holiday from the next year on")
    H.eq(u.days, 0)
end

function T.the_outcome_can_be_undone_for_testing()
    local so = mockSandbox(14, 10)
    local p, ps = setup()
    local Era, Council = StoryEngine.Era, StoryEngine.Council
    trustAll(60)
    atSiege(ps, true, 1)
    Council.finish(now())
    H.ok(Era.active())
    Era.reset()
    H.ok(not Era.active())
    H.eq(so.values.ElecShutModifier, 14, "the grid goes back to its own schedule")
    H.eq(Era.epilogueFor(), nil)
end

return T
