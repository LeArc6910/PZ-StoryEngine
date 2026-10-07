-- 아는 얼굴의 좀비 (2026-10-04). NPC 가 "옛 이웃이 변해서 근처를 떠돈다, 편히 보내 주고 유품을 찾아다 줘"라고 부탁한다.
-- 퀘스트 종류 named: 수락하면 그 사람 복장의 좀비 하나(+ 따라다니는 몇 마리)를 놓고, 유품(바닐라 아이템, 퀘스트 표시)을
-- 그 좀비 인벤토리에 넣는다. 쓰러뜨리면 q.slain, 유품을 챙겨 [무전으로 제출]하면 완료 (보상 보급, 신뢰도는 부탁 규칙).
-- 좀비가 청크 언로드로 사라졌으면(가까이 있는데 30분 넘게 안 보이면) 마지막으로 본 자리에 다시 놓는다. 지도 표시는 좀비를 따라간다.
--
-- 언제: 관측 10일째부터, 서버 전체로 Named.GAP_DAYS 일 간격, 하루 한 번 Named.CHANCE %. 신뢰도 30 이상인 NPC 중,
-- 아직 그 NPC 의 사람이 남아 있으면. 이야기 결말에 따라 나오는 사람(requires = 노드 id)이 있으면 그 사람이 먼저.

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Radio"
require "StoryEngine/Quests"
require "StoryEngine/Lines"

local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Radio = StoryEngine.Radio
local Quests = StoryEngine.Quests
local log = StoryEngine.log

local Named = {}
StoryEngine.Named = Named

Named.START_DAY = 10
Named.GAP_DAYS = 6
Named.CHANCE = 30
Named.MIN_TRUST = 30
Named.TIER = 2                 -- 거리 등급 (200~500타일)
Named.ESCORTS = { 3, 6 }       -- 같이 떠도는 좀비
Named.MISSING_TICKS = 3        -- 이만큼(10분 샘플) 안 보이면 다시 놓는다
Named.NEAR = 35                -- 플레이어가 이만큼 가까워야 "안 보인다"를 센다

-- bio: AI 에게 주는 사람 설명 (영어). female: 여자일 확률 % (addZombiesInOutfitArea)
Named.PEOPLE = {
    { id = "jim", name = "Jim Baldwin", npc = "ray", outfit = "Farmer", female = 0, item = "Base.Ring_Left_RingFinger_Gold",
      bio = "Jim Baldwin, your neighbor of twenty years, a quiet farmer who helped you rebuild your barn after the '88 storm. "
          .. "He wore his late wife's wedding ring on a cord. You saw him turned, wandering the fields." },
    { id = "leed", name = "Mrs. Leed", npc = "casey", outfit = "Teacher", female = 100, item = "StoryEngine.PhotoAlbum",
      bio = "Mrs. Leed, your high school science teacher, who gave you your first radio kit and stayed after class to help "
          .. "you solder it. She kept a photo album of her students. Someone saw her turned near her house." },
    { id = "dad", name = "your father", npc = "casey", outfit = "OfficeWorker", female = 0, item = "Base.WristWatch_Left_ClassicBrown",
      requires = "casey_5b",
      bio = "Your own father. He died of the infection in his bed, and you could not bring yourself to stop him from getting "
          .. "up again; he walked out of the radio shack. He always wore the brown watch you gave him." },
    { id = "maria", name = "Maria Ortega", npc = "doc", outfit = "Nurse", female = 100, item = "Base.WristWatch_Left_ClassicBrown",
      bio = "Maria Ortega, a nurse who worked night shifts beside you at the hospital. She went back in for the patients "
          .. "on the last day. Her watch was a gift from her daughter." },
    { id = "eleanor", name = "Eleanor Hayes", npc = "pike", outfit = "Generic_Skirt", female = 100, item = "Base.Necklace_Crucifix",
      bio = "Eleanor Hayes, the church organist who played every Sunday for thirty years. She never took off her silver "
          .. "crucifix. She was lost the night the dead came to the church doors." },
    { id = "tommy", name = "Tommy Reed", npc = "dewey", outfit = "Mechanic", female = 0, item = "Base.Wrench",
      bio = "Tommy Reed, your old partner at the garage, who taught you engines. His wrench has his initials scratched in it." },
    { id = "reyes", name = "Private Reyes", npc = "guard", outfit = "ArmyCamoGreen", female = 0, item = "Base.Necklace_DogTag",
      bio = "Private Luis Reyes of your squad, nineteen years old, bitten on a supply run and left behind. His dog tags "
          .. "belong to his family, if any of them are alive." },
    { id = "joey", name = "Joey", npc = "rats", outfit = "Punk", female = 0, item = "Base.Locket",
      bio = "Joey, the youngest of your crew, a loudmouth kid you took in. He carried his mother's locket everywhere. "
          .. "He turned after a job went wrong; you will not admit it hurts." },
    { id = "earl", name = "Earl Tate", npc = "hunter", outfit = "Hunter", female = 0, item = "Base.HuntingKnife",
      bio = "Earl Tate, your hunting partner for forty years. His knife has a bone handle he carved himself." },
    -- 두 번째 이야기에서만 (storyOnly: 무작위로는 나오지 않는다, Stories.SEQUELS 의 quest.person)
    { id = "annie", name = "Annie", npc = "ray", outfit = "Student", female = 100, item = "Base.Ring_Left_RingFinger_Silver",
      storyOnly = true,
      bio = "Your daughter Annie. She fled the Louisville shelter with a group heading south and turned on the road. She "
          .. "wore a yellow raincoat and the silver ring her mother left her." },
    { id = "ruth", name = "Ruth Hale", npc = "pike", outfit = "Teacher", female = 100, item = "Base.Necklace_Gold",
      storyOnly = true,
      bio = "Ruth Hale, who taught Sunday school at your church and was one of the three people lost the night the dead "
          .. "broke in. She always wore her grandmother's gold necklace." },
}
Named.byId = {}
for _, p in ipairs(Named.PEOPLE) do Named.byId[p.id] = p end

function Named.enabled() return StoryEngine.option("Named", true) == true end

local function state()
    local d = Store.data()
    d.named = d.named or {}
    local s = d.named
    s.used = s.used or {}
    return s
end

local function anyOpen()
    for _, q in pairs(Store.data().quests) do
        if q.kind == "named" and (q.state == "proposed" or Quests.isActive(q)) then return q end
    end
    return nil
end

-- 지금 부탁할 수 있는 사람 (NPC 가 살아 있고 신뢰도가 되고 아직 안 쓴 사람). 이야기 결말이 필요한 사람이 먼저
function Named.candidates()
    local s = state()
    local first, rest = {}, {}
    for _, p in ipairs(Named.PEOPLE) do
        local ok = not p.storyOnly and not s.used[p.id] and not Factions.isGone(p.npc)
            and Radio.channel(p.npc).trust >= Named.MIN_TRUST
        if ok and p.requires then
            local st = StoryEngine.Social and StoryEngine.Social.story(p.npc)
            ok = st ~= nil and st.node == p.requires
            if ok then first[#first + 1] = p end
        elseif ok then
            rest[#rest + 1] = p
        end
    end
    return #first > 0 and first or rest
end

-- 부탁한다. 반환: 퀘스트 | nil, 이유
-- opts.story = { faction, node }: 이야기 부탁 (Social.advance). opts.why: 그 사정을 AI 에게 덧붙인다
function Named.propose(player, ps, person, now, opts)
    opts = opts or {}
    local found = Quests.findForTier(math.floor(player:getX()), math.floor(player:getY()), Named.TIER,
        { [ps.home and ps.home.building or ""] = true })
    if not found then return nil, "no_building" end
    local d = Store.data()
    d.questSeq = d.questSeq + 1
    local def, room = found.def, found.room
    local cx = math.floor((def:getX() + def:getX2()) / 2)
    local cy = math.floor((def:getY() + def:getY2()) / 2)
    local place = StoryEngine.Places.describe(cx, cy)
    place.inside = false
    local q = {
        id = "Q" .. StoryEngine.intToString(d.questSeq),
        kind = "named", tier = Named.TIER, person = person.id, personName = person.name,
        outfit = person.outfit, female = person.female, items = { person.item },
        building = found.key, place = place,
        x = math.floor((room:getX() + room:getX2()) / 2), y = math.floor((room:getY() + room:getY2()) / 2), z = 0,
        cx = cx, cy = cy, bx1 = def:getX(), by1 = def:getY(), bx2 = def:getX2(), by2 = def:getY2(),
        radius = Quests.RADIUS, distance = math.floor(found.distance),
        origin = { source = opts.story and "story" or "director", faction = person.npc, initiator = "npc", story = opts.story,
                   day = Store.dayIndex(now.dayKey), date = now.date, clock = now.clock },
        target = ps.key, targetName = ps.name,
        state = "proposed", createdT = now.t, respondBy = now.t + Quests.RESPOND_MIN, spawned = false,
    }
    d.quests[q.id] = q
    state().used[person.id] = q.id
    state().lastT = now.t
    local town, code, distance, dirEn = Quests.whereFrom(q, player)
    Radio.react(person.npc, "request", "Someone you knew has turned and wanders near " .. town .. ", about "
        .. StoryEngine.intToString(distance) .. " tiles to the " .. dirEn .. " of the players (from them): " .. person.bio
        .. " Ask the players to find them, put them to rest and bring back what they carried. Speak from the heart, "
        .. "briefly. Payment: a modest supply cache."
        .. (opts.why and (" This is part of what is going on in your life right now: " .. opts.why .. ".") or ""),
        StoryEngine.Lines.fallback(person.npc, "named_ask", "Someone I knew is out there, turned. Please put them to rest.",
            { { t = "key", v = "IGUI_StoryEngine_Named_" .. person.id .. "_name" }, { t = "town", v = place.town },
              { t = "dir", v = code }, { t = "num", v = distance } }), ps)
    log("named proposed", q.id, person.id, person.npc, "at", cx, cy, "for", ps.name)
    Quests.notify(q)
    return q
end

-- 하루 한 번 (EveryHours 에서 날짜가 바뀌면)
function Named.daily(now)
    if not Named.enabled() then return end
    local s = state()
    local day = Store.dayIndex(now.dayKey)
    if s.rollDay == day then return end
    s.rollDay = day
    if day < Named.START_DAY or anyOpen() then return end
    if s.lastT and now.t - s.lastT < Named.GAP_DAYS * 24 * 60 then return end
    if ZombRand(100) >= Named.CHANCE then return end
    local list = Named.candidates()
    local players = Sensor.players()
    if #list == 0 or #players == 0 then return end
    local person = list[ZombRand(#list) + 1]
    local player = players[ZombRand(#players) + 1]
    Named.propose(player, Store.player(player), person, now)
end

local function tagged(qid)
    local out = nil
    pcall(function()
        local list = getCell():getZombieList()
        for i = 0, list:size() - 1 do
            local z = list:get(i)
            local mod = z:getModData()
            if mod and mod.storyNamed == qid and not z:isDead() then out = z end
        end
    end)
    return out
end

-- 그 사람 좀비를 놓는다 (Quests 의 trySpawn 이 칸이 로드되면 부른다, 다시 놓을 때도)
function Named.spawn(q, x, y)
    x, y = x or q.cx, y or q.cy
    local ok, list = pcall(addZombiesInOutfitArea, x - 1, y - 1, x + 1, y + 1, 0, 1, q.outfit, q.female or 0)
    local z = ok and list and list:size() > 0 and list:get(0) or nil
    if not z then
        log("named spawn failed", q.id, tostring(list))
        return false
    end
    z:getModData().storyNamed = q.id
    local inv = z:getInventory()
    for _, ft in ipairs(q.items or {}) do StoryEngine.Items.addTo(inv, ft, q.id) end
    if not q.spawned then
        local n = Quests.zombieCount(ZombRand(Named.ESCORTS[1], Named.ESCORTS[2] + 1))
        pcall(addZombiesInOutfitArea, x - 6, y - 6, x + 6, y + 6, 0, n, nil, nil)
    end
    q.spawned = true
    q.sx, q.sy, q.missing = math.floor(z:getX()), math.floor(z:getY()), 0
    log("named spawned", q.id, q.person, q.outfit, "at", q.sx, q.sy)
    Quests.notify(q)
    return true
end

-- 게임 내 10분마다: 좀비를 찾아 표시를 옮기고, 오래 안 보이면 다시 놓는다
function Named.tick(entries, now)
    for _, q in pairs(Store.data().quests) do
        if q.kind == "named" and q.spawned and not q.slain and Quests.isActive(q) then
            local z = tagged(q.id)
            if z then
                q.sx, q.sy, q.missing = math.floor(z:getX()), math.floor(z:getY()), 0
                q.cx, q.cy = q.sx, q.sy
            else
                local near = false
                for _, e in ipairs(entries or {}) do
                    local dx, dy = e.s.x - q.sx, e.s.y - q.sy
                    if dx * dx + dy * dy <= Named.NEAR * Named.NEAR then near = true end
                end
                if near and getCell():getGridSquare(q.sx, q.sy, 0) then
                    q.missing = (q.missing or 0) + 1
                    if q.missing >= Named.MISSING_TICKS then
                        log("named missing, placing again", q.id)
                        Named.spawn(q, q.sx, q.sy)
                    end
                end
            end
        end
    end
end

function Named.onZombieDead(zombie)
    local mod = zombie and zombie:getModData()
    local qid = mod and mod.storyNamed
    if not qid then return end
    local q = Store.data().quests[qid]
    if not q or q.slain or not Quests.isActive(q) then return end
    q.slain = true
    q.sx, q.sy = math.floor(zombie:getX()), math.floor(zombie:getY())
    q.cx, q.cy = q.sx, q.sy
    log("named slain", q.id, q.person)
    Quests.notify(q)
end

function Named.statusText()
    local s = state()
    local used = {}
    for id, qid in pairs(s.used) do used[#used + 1] = id .. "=" .. tostring(qid) end
    table.sort(used)
    local open = anyOpen()
    return "named " .. (#used > 0 and table.concat(used, " ") or "none")
        .. (open and (" open " .. open.id .. (open.slain and " slain" or "")) or "")
end

Sensor.listeners.tick[#Sensor.listeners.tick + 1] = function(entries, now)
    local ok, err = pcall(Named.tick, entries, now)
    if not ok then log("named tick error:", err) end
end

Events.EveryHours.Add(function()
    local ok, err = pcall(Named.daily, Sensor.now())
    if not ok then log("named daily error:", err) end
end)

Events.OnZombieDead.Add(function(zombie)
    local ok, err = pcall(Named.onZombieDead, zombie)
    if not ok then log("named dead error:", err) end
end)

return Named
