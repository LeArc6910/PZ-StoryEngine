-- 개인 신뢰 모드의 무리의 일·물자 지원·후임·죽음·공용 주파수 알림·디버그 (docs/DESIGN_PER_PLAYER_TRUST.md)
-- Life(사람마다 지원 통, 아는 NPC 에게만 파급), Projects(완성 집단 +15), Ops(막마다 +1), Council(+2), Saga(보탠 사람 보너스),
-- Voices(후임이면 개인 신뢰 처음부터), Journal(죽으면 기록 지움), Social(무리의 부탁 공용 주파수 알림), Commands(디버그)
local T = {}

local function setup(personal)
    if personal ~= false then H.personalMode() end
    local a = H.addPlayer("alice", "Alice", "Ash")
    local b = H.addPlayer("bob", "Bob", "Birch")
    local pa, pb = StoryEngine.Store.player(a), StoryEngine.Store.player(b)
    pa.lang, pb.lang = "EN", "EN"
    local V = H.defineItem
    V("Base.TinnedBeans", "food", 1.5)
    V("Base.Bandage", "medical", 3)
    V("Base.Antibiotics", "medical", 8)
    V("Base.Bullets9mmBox", "ammo", 15)
    return a, b, pa, pb
end

local function Tr() return StoryEngine.Trust end
local function ch(fid) return StoryEngine.Radio.channel(fid) end
local function now() return StoryEngine.Sensor.now() end

local function give(p, ft, n)
    local ids = {}
    for _ = 1, n do ids[#ids + 1] = H.give(p, ft):getID() end
    return ids
end

-- 어디를 찾든 10x10 비주거 건물이 있는 메타그리드 (test_saga 와 같음)
local function mockAnywhereBuildings()
    ArrayList = { new = function() return H.list({}) end }
    local grid = {}
    function grid:getBuildingsIntersecting(x, y, w, h, list)
        local cx, cy = math.floor(x + w / 2), math.floor(y + h / 2)
        local room = {}
        function room:getZ() return 0 end
        function room:getArea() return 100 end
        function room:getX() return cx end
        function room:getY() return cy end
        function room:getX2() return cx + 9 end
        function room:getY2() return cy + 9 end
        function room:getName() return "office" end
        local def = {}
        function def:getX() return cx end
        function def:getY() return cy end
        function def:getX2() return cx + 9 end
        function def:getY2() return cy + 9 end
        function def:getRooms() return H.list({ room }) end
        function def:isResidential() return false end
        list.items[#list.items + 1] = def
    end
    function grid:getBuildingAt() return nil end
    local world = {}
    function world:getMetaGrid() return grid end
    function world:setHydroPowerOn() end
    getWorld = function() return world end
end

-- 바닐라 SandboxOptions 흉내 (test_ops 와 같음)
local function mockSandbox(elec, water)
    local so = { values = { ElecShutModifier = elec, WaterShutModifier = water } }
    function so:set(name, v) self.values[name] = v end
    function so:getElecShutModifier() return self.values.ElecShutModifier end
    function so:getWaterShutModifier() return self.values.WaterShutModifier end
    function so:getTimeSinceApo() return 1 end
    function so:toLua() end
    function so:doesPowerGridExist() return getGameTime():getWorldAgeHours() / 24 < self.values.ElecShutModifier end
    getSandboxOptions = function() return so end
    return so
end

local function allowDebug(p)
    Capability = Capability or {}
    Capability.UseDebugContextMenu = Capability.UseDebugContextMenu or "UseDebugContextMenu"
    function p:getRole() return { hasCapability = function() return true end } end
end

-- ---------------------------------------------------------------- Life: 물자 지원

function T.donation_window_and_trust_are_per_person()
    local a, b, pa, pb = setup()
    local Life = StoryEngine.Life
    -- 앨리스: 콩 10개(같은 물건 10개까지, 가치 15 -> 식량 +30) + 탄약 1상자(15) = 가치 30 -> 신뢰 +3 (개인)
    local ids = give(a, "Base.TinnedBeans", 10)
    ids[#ids + 1] = H.give(a, "Base.Bullets9mmBox"):getID()
    local ok, info = Life.donate(a, "ray", ids)
    H.ok(ok, "alice donates: " .. tostring(info))
    H.eq(info.trust, 3)
    H.eq(Tr().personal("ray", pa.key), 33, "donor's personal trust")
    H.eq(ch("ray").trust, 30, "group trust untouched")
    H.ok(StoryEngine.Life.npc("ray").donateWinBy[pa.key] ~= nil, "alice has her own window")
    H.eq(StoryEngine.Life.npc("ray").donateWin, nil, "no shared window")
    H.eq(Life.donateStatus("ray", now(), pa.key).res.food, 10, "alice used 30 of her food limit")
    H.eq(Life.donateStatus("ray", now(), pb.key).res.food, 40, "bob's window is fresh")
    -- 밥도 자기 통으로 식량을 보낸다
    local ok2, info2 = Life.donate(b, "ray", give(b, "Base.TinnedBeans", 4))
    H.ok(ok2, "bob donates: " .. tostring(info2))
    H.eq(info2.trust, 1, "bob gets his own first trust step")
    H.eq(Tr().personal("ray", pb.key), 31)
    H.eq(Tr().personal("ray", pa.key), 33, "alice unchanged by bob")
    -- 거점 목록: 보는 사람 기준
    local entry
    for _, e in ipairs(Life.list(pa.key)) do if e.id == "ray" then entry = e end end
    H.eq(entry.trust, 30, "trust = group")
    H.eq(entry.personal, 33)
    H.eq(entry.personalMode, true)
    H.eq(entry.personalKnown, true)
    H.eq(entry.donate.res.food, 10, "alice's window in her list")
    local hunter
    for _, e in ipairs(Life.list(pa.key)) do if e.id == "hunter" then hunter = e end end
    H.eq(hunter.personalKnown, false, "never talked to Hank")
    H.eq(Tr().known("hunter", pa.key), false, "viewing the list is not a first contact")
    -- 3일 뒤 새 통
    H.advanceDays(3)
    H.eq(Life.donateStatus("ray", now(), pa.key).res.food, 40)
end

function T.shared_mode_keeps_one_window()
    local a, b = setup(false)
    local Life = StoryEngine.Life
    H.ok(Life.donate(a, "ray", give(a, "Base.TinnedBeans", 10)))      -- 가치 15 -> 신뢰 +2
    H.ok(StoryEngine.Life.npc("ray").donateWin ~= nil, "one window per NPC")
    H.eq(StoryEngine.Life.npc("ray").donateWinBy, nil)
    H.eq(Life.donateStatus("ray", now(), "bob").res.food, 10, "bob sees the shared window")
    local ok, info = Life.donate(b, "ray", give(b, "Base.TinnedBeans", 2))
    H.ok(ok)
    H.eq(info.trust, 0, "the shared window already gave this step")
    H.eq(ch("ray").trust, 32, "one trust")
    local entry
    for _, e in ipairs(Life.list("bob")) do if e.id == "ray" then entry = e end end
    H.eq(entry.personal, nil, "no personal fields")
    H.eq(entry.personalMode, nil)
end

-- ---------------------------------------------------------------- Life: 관계 파급

local function bondedTo(fid, sign)
    local out = {}
    for _, f in ipairs(StoryEngine.Factions.list) do
        if f.id ~= fid then
            local v = StoryEngine.Bonds.get(f.id, fid)
            if (sign > 0 and v > 0) or (sign < 0 and v < 0) then out[#out + 1] = f.id end
        end
    end
    return out
end

function T.personal_spill_reaches_only_known_contacts()
    local _, _, pa = setup()
    local friends = bondedTo("ray", 1)
    H.ok(#friends >= 2, "ray has at least two friends")
    local known, unknown = friends[1], friends[2]
    Tr().ensure(known, pa.key)
    local before = Tr().personal(known, pa.key)
    local groupKnown, groupUnknown = ch(known).trust, ch(unknown).trust
    StoryEngine.Life.spill("ray", "Alice Ash", true, nil, pa.key)
    H.eq(Tr().personal(known, pa.key), before + 1, "known friend of Ray: personal +1")
    H.eq(Tr().known(unknown, pa.key), false, "no new personal record for someone Alice never met")
    H.eq(ch(known).trust, groupKnown, "group trust untouched by personal spill")
    H.eq(ch(unknown).trust, groupUnknown)
    -- 무리의 일에서 번진 파급 (byKey 없음): 집단 신뢰
    StoryEngine.Life.spill("ray", nil, true)
    H.eq(ch(unknown).trust, groupUnknown + 1, "group spill moves group trust")
    H.eq(Tr().personal(known, pa.key), before + 1, "group spill does not touch personal trust")
end

function T.personal_spill_floor_looks_at_personal_trust()
    local _, _, pa = setup()
    local foes = bondedTo("rats", -1)
    H.ok(#foes >= 1, "someone dislikes Vic")
    local foe = foes[1]
    ch(foe).trust = 10                         -- 집단은 바닥 아래지만
    ch(foe).personal = { [pa.key] = 50 }       -- 앨리스의 개인 신뢰는 넉넉하다
    H.rolls = { 0 }                            -- 빅과의 일이 알려진다 (30%)
    StoryEngine.Life.spill("rats", "Alice Ash", false, nil, pa.key)
    H.eq(ch(foe).personal[pa.key], 49, "the floor checks Alice's personal trust, not the group's")
    H.eq(ch(foe).trust, 10)
end

function T.story_quest_spill_is_group_and_request_spill_is_personal()
    local a, _, pa = setup()
    local friends = bondedTo("doc", 1)
    local f = friends[1]
    Tr().ensure(f, pa.key)
    local group, mine = ch(f).trust, Tr().personal(f, pa.key)
    StoryEngine.Life.onQuest({ kind = "deliver", tier = 3, target = pa.key, targetName = "Alice Ash",
        need = { { "Base.Bandage", 2 } }, origin = { faction = "doc", story = { faction = "doc", node = "doc_3" } } }, "completed", 3)
    H.eq(ch(f).trust, group + 1, "story work spills into group trust")
    H.eq(Tr().personal(f, pa.key), mine)
    StoryEngine.Store.data().life.npc[f].spill = {}
    StoryEngine.Life.onQuest({ kind = "deliver", tier = 3, target = pa.key, addressed = pa.key, targetName = "Alice Ash",
        need = { { "Base.Bandage", 2 } }, origin = { faction = "doc" } }, "completed", 3)
    H.eq(Tr().personal(f, pa.key), mine + 1, "personal request spills into the doer's personal trust")
    H.eq(ch(f).trust, group + 1)
end

-- ---------------------------------------------------------------- Projects

function T.project_completion_adds_group_trust_in_personal_mode()
    local _, _, pa = setup()
    local P = StoryEngine.Projects
    Tr().ensure("ray", pa.key)
    local mine = Tr().personal("ray", pa.key)
    P.add("ray", P.GOAL, "Alice Ash", "test")
    H.ok(P.done("ray"))
    H.eq(ch("ray").trust, 30 + P.GROUP_TRUST, "group +15")
    H.eq(Tr().personal("ray", pa.key), mine, "no personal change")
end

function T.project_completion_shared_mode_unchanged()
    setup(false)
    local P = StoryEngine.Projects
    P.add("ray", P.GOAL, "Alice Ash", "test")
    H.ok(P.done("ray"))
    H.eq(ch("ray").trust, 30, "shared mode: no trust from finishing")
end

-- ---------------------------------------------------------------- Ops

function T.ops_act_helpers_get_one_personal_with_the_lead()
    local so = mockSandbox(14, 14)
    mockAnywhereBuildings()
    local a, b, pa, pb = setup()
    H.clockMin = 30 * 1440 + 9 * 60
    local Ops, Quests = StoryEngine.Ops, StoryEngine.Quests
    H.ok(Ops.start("water", "test"))
    local op = Ops.current()
    H.eq(op.lead, "pike")
    local q1 = StoryEngine.Store.data().quests[op.quests[1][1]]
    Quests.addHelper(q1, pb)                      -- 밥은 근처에 있었다
    local groupBefore = ch("pike").trust
    H.give(a, "StoryEngine.WaterManual", { questTag = q1.id })
    H.ok(Quests.submit(a, q1.id))
    H.eq(op.act, 2, "act done")
    local start = Tr().startOf("pike")
    H.eq(Tr().personal("pike", pa.key), start + 1, "submitter +1")
    H.eq(Tr().personal("pike", pb.key), start + 1, "helper +1")
    H.eq(ch("pike").trust, groupBefore, "group trust unchanged")
    H.eq(Ops.rewardHelpers(op, 1), 0, "once per act per person")
    H.ok(so ~= nil)
end

function T.ops_act_helpers_nothing_in_shared_mode()
    mockSandbox(14, 14)
    mockAnywhereBuildings()
    local a = setup(false)
    H.clockMin = 30 * 1440 + 9 * 60
    local Ops, Quests = StoryEngine.Ops, StoryEngine.Quests
    H.ok(Ops.start("water", "test"))
    local op = Ops.current()
    local q1 = StoryEngine.Store.data().quests[op.quests[1][1]]
    local before = ch("pike").trust
    H.give(a, "StoryEngine.WaterManual", { questTag = q1.id })
    H.ok(Quests.submit(a, q1.id))
    H.eq(ch("pike").trust, before)
    H.eq(ch("pike").personal, nil, "no personal records")
end

-- ---------------------------------------------------------------- Council

function T.council_formed_gives_helpers_two_with_each_host()
    mockAnywhereBuildings()
    local _, _, pa, pb = setup()
    local Social, Council = StoryEngine.Social, StoryEngine.Council
    Social.moveTo("pike", "pike5_1", now())
    Council.start(now())
    local s = Council.state()
    local cq = StoryEngine.Store.data().quests[s.collectId]
    StoryEngine.Quests.addHelper(cq, pa)
    for _, n in ipairs(cq.need) do cq.got[n[1]] = n[2] end
    cq.state = "completed"
    Council.tick(now())
    H.eq(s.stage, "horde")
    local hq = StoryEngine.Store.data().quests[s.hordeId]
    StoryEngine.Quests.addHelper(hq, pa)
    hq.state = "completed"
    for _, f in ipairs(StoryEngine.Factions.list) do ch(f.id).trust = 60 end
    local casey, pike = Tr().personal("casey", pa.key), Tr().personal("pike", pa.key)
    Council.tick(now())
    H.eq(s.result, "formed")
    H.eq(Tr().personal("casey", pa.key), casey + 2, "Casey +2")
    H.eq(Tr().personal("pike", pa.key), pike + 2, "Pike +2")
    H.eq(Tr().known("casey", pb.key), false, "Bob did not help")
end

-- ---------------------------------------------------------------- Saga

function T.saga_ending_gives_helpers_a_bonus()
    mockAnywhereBuildings()
    local _, _, pa, pb = setup()
    H.clockMin = 30 * 1440 + 9 * 60
    local Saga = StoryEngine.Saga
    StoryEngine.Life.daily()
    Saga.start("epidemic", "test")
    Saga.debug("next")
    local sg = Saga.current()
    local mq = StoryEngine.Store.data().quests[sg.quests.medicine]
    H.eq(mq.kind, "collect")
    StoryEngine.Quests.addHelper(mq, pa)
    for _, n in ipairs(mq.need) do mq.got = mq.got or {}; mq.got[n[1]] = n[2] end
    local group = ch("doc").trust
    local mine = Tr().personal("doc", pa.key)
    local bob = Tr().personal("doc", pb.key)
    Saga.debug("next")
    Saga.debug("next")
    H.ok(not Saga.active(), "over")
    H.eq(StoryEngine.Store.data().saga.history[1].result, "cured")
    H.eq(ch("doc").trust, group + 3, "group +3 (saga)")
    H.eq(Tr().personal("doc", pa.key), mine + 2, "helper +3 x 0.5 -> 2")
    H.ok(not Tr().known("doc", pb.key), "Bob did not help: no bonus, still a stranger")
    H.ok(bob ~= nil)
end

-- ---------------------------------------------------------------- Voices / Journal

function T.successor_starts_personal_trust_over()
    local _, _, pa = setup()
    ch("ray").personal = { [pa.key] = 70 }
    ch("ray").touchBy = { [pa.key] = 1 }
    StoryEngine.Fate.apply("ray", "dead", "debug")
    H.ok(StoryEngine.Voices.take("ray", now()))
    -- 기록이 지워져 다음 연락 때 소개 몫으로 새로 (후임의 집단 신뢰 15 < 처음 값 30 -> 처음 값)
    H.eq(Tr().personal("ray", pa.key), Tr().startOf("ray"), "everyone starts over with the successor")
end

function T.death_forgets_personal_records()
    local _, _, pa, pb = setup()
    ch("ray").personal = { [pa.key] = 70, [pb.key] = 40 }
    ch("doc").personal = { [pa.key] = 50 }
    StoryEngine.Journal.onDeath(pa, { place = { town = "Riverside" }, x = 1, y = 1 }, now())
    H.eq(ch("ray").personal[pa.key], nil, "Alice's record is gone")
    H.eq(ch("doc").personal[pa.key], nil)
    H.eq(ch("ray").personal[pb.key], 40, "Bob keeps his")
end

-- ---------------------------------------------------------------- Social: 공용 주파수 알림

local function openLines(field)
    local out = {}
    for _, m in ipairs(ch("open").messages or {}) do
        if m[field] then out[#out + 1] = m end
    end
    return out
end

function T.story_request_is_announced_on_the_open_channel()
    setup()
    local Social = StoryEngine.Social
    Social.moveTo("ray", "ray_3", now())
    Social.story("ray").since = now().t - 10 * 24 * 60
    Social.advance("ray", now())
    local st = Social.story("ray")
    H.ok(st.questId, "Ray asked")
    local lines = openLines("groupAsk")
    H.eq(#lines, 1, "one open-channel line")
    H.eq(lines[1].groupAsk, "ray")
    H.eq(lines[1].quest, st.questId)
    H.eq(lines[1].from, "system")
    local qt = StoryEngine.Store.data().social.queuedTopic
    H.ok(qt and qt.ids[1] == "ray" and #qt.ids == 2, "queued for the next open-channel scene")
end

function T.crisis_is_announced_on_the_open_channel()
    setup()
    local ok, id = StoryEngine.Social.startCrisis(now())
    H.ok(ok, "crisis: " .. tostring(id))
    local lines = openLines("groupCrisis")
    H.eq(#lines, 1)
    H.ok(#lines[1].groupCrisis >= 2, "who is asking")
    H.ok(lines[1].quest ~= nil)
    local qt = StoryEngine.Store.data().social.queuedTopic
    H.ok(qt and #qt.ids >= 2, "scene topic")
end

function T.shared_mode_does_not_announce()
    setup(false)
    local Social = StoryEngine.Social
    Social.moveTo("ray", "ray_3", now())
    Social.story("ray").since = now().t - 10 * 24 * 60
    Social.advance("ray", now())
    H.ok(Social.story("ray").questId, "Ray asked")
    H.eq(#openLines("groupAsk"), 0)
    H.ok(StoryEngine.Social.startCrisis(now()))
    H.eq(#openLines("groupCrisis"), 0)
end

-- ---------------------------------------------------------------- Commands (디버그)

function T.debug_personal_trust_and_status()
    local a, _, pa = setup()
    allowDebug(a)
    local C = StoryEngine.Commands
    C.debugPersonalTrust(a, { faction = "ray", set = 55 })
    H.eq(Tr().personal("ray", pa.key), 55)
    H.eq(ch("ray").trust, 30, "group untouched")
    local st = H.sentTo(a, "debugStatus")
    H.ok(string.find(st[#st].text, "personal trust ray = 55", 1, true) ~= nil, st[#st].text)
    H.ok(string.find(st[#st].text, "personal ray: Alice Ash=55", 1, true) ~= nil, "status part: " .. st[#st].text)
    C.debugPersonalTrust(a, { faction = "ray", delta = -10 })
    H.eq(Tr().personal("ray", pa.key), 45)
    C.debugStatus(a, {})
    st = H.sentTo(a, "debugStatus")
    H.ok(string.find(st[#st].text, "personal ray: Alice Ash=45", 1, true) ~= nil, "debug status line")
end

function T.debug_personal_ask_makes_a_request()
    local a, _, pa = setup()
    allowDebug(a)
    StoryEngine.Commands.debugPersonalAsk(a, { kind = "deliver" })
    local st = H.sentTo(a, "debugStatus")
    local text = st[#st].text
    H.ok(string.find(text, "personal ask Q", 1, true) ~= nil, text)
    local mine = nil
    for _, q in pairs(StoryEngine.Store.data().quests) do
        if q.addressed == pa.key then mine = q end
    end
    H.ok(mine ~= nil and mine.kind == "deliver", "a request addressed to Alice")
end

function T.debug_personal_trust_refuses_outside_personal_mode()
    local a = setup(false)
    StoryEngine.Commands.debugPersonalTrust(a, { faction = "ray", set = 55 })
    local st = H.sentOf("debugStatus")
    H.ok(string.find(st[#st].text, "not in personal trust mode", 1, true) ~= nil)
end

return T
