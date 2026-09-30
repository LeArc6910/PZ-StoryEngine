-- NPC 의 죽음과 떠남 (서버 측 전용, 2026-09-30 3단계). 설계: docs/DESIGN_NPC_LIFE.md
--
-- 전투나 운으로는 일어나지 않는다. 두 가지 경우만:
--   ① 이야기 최악 결말: 그 NPC 의 이야기 부탁을 하나도 성공하지 못하고(위기에서 편들어 준 것도 성공으로 친다)
--      두 번 이상 실패·거절·무응답한 채 마지막 단계에 이르면, 하루 뒤 NPC 별 결말(Fate.DOOM: 죽음 또는 떠남)
--   ② 형편 고갈: 네 자원이 모두 10 미만으로 하루가 끝나면 날을 센다. 1·2일째 경고 무전, 3일째 떠남.
--      어느 자원이든 20 이상이 되면 다시 센다.
-- 샌드박스 StoryEngine.NpcFate(기본 켬)를 끄면 ①은 "크게 다쳤지만 살아 있음"(자원 20으로 복구), ②는 경고만.
-- 결과: 채널은 잡음뿐, 모든 기능에서 빠진다(Factions.isGone), 떠나면 작별 무전, 죽으면 친한 NPC 가 소식을 전함,
-- 모든 캐릭터의 일지, 다른 NPC 사기 하락·소문, 그 NPC 의 진행 중 부탁·거래는 페널티 없이 취소. 되살리기는 디버그로만.
-- 상태: Life.npc(fid).fate = { kind = "dead" | "gone", reason, day, t }, .starve (고갈 일수), d.fatePending[fid]

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Radio"
require "StoryEngine/Stories"
require "StoryEngine/Life"

local Net = StoryEngine.Net
local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Radio = StoryEngine.Radio
local Stories = StoryEngine.Stories
local Life = StoryEngine.Life
local log = StoryEngine.log

local Fate = {}
StoryEngine.Fate = Fate

Fate.DELAY_MIN = 24 * 60          -- 이야기 결말 뒤 실제로 죽거나 떠나기까지
Fate.STORY_LOSSES = 2             -- 이야기 부탁을 이만큼 이상 잃고 한 번도 성공하지 못했을 때
Fate.STARVE_ALL = 10              -- 네 자원이 모두 이 아래면 고갈
Fate.STARVE_RESET = 20            -- 어느 자원이든 이 이상이면 다시 센다
Fate.STARVE_DAYS = 3
Fate.MORALE_HIT = 15              -- 다른 NPC 의 죽음·떠남에 사기 하락 (친하면 FRIEND_HIT)
Fate.FRIEND_HIT = 25

-- 이야기 최악 결말 (AI 에게 넘기는 영어 사실)
Fate.DOOM = {
    ray = { kind = "gone", text = "Ray Mercer gave up on everything and drove off alone toward Louisville. Nobody knows if he made it." },
    casey = { kind = "gone", text = "After their father died, Casey Liu stopped broadcasting and left the radio shack in Valley Station. The frequency is silent." },
    doc = { kind = "dead", text = "June Adler caught the fever from her own patients and died in the Riverside clinic." },
    pike = { kind = "dead", text = "The dead broke into the March Ridge church at night. Brother Pike held the door so the others could run, and did not survive." },
    dewey = { kind = "gone", text = "Dewey Hollis drove his unfinished truck out of the county and never came back on the air." },
    guard = { kind = "gone", text = "Sergeant Whitaker's squad abandoned the Knox boundary camp and pulled out north. Their frequency went dead." },
    rats = { kind = "dead", text = "Dutch took over the Coalfield Crew, and Vic was killed in the fight." },
    hunter = { kind = "gone", text = "Hank Tolliver walked into the woods for the winter and never came back." },
}

function Fate.enabled()
    return StoryEngine.option("NpcFate", true) == true
end

-- 원인별로 켜져 있는지 (샌드박스 NpcFateCause: 1 둘 다, 2 이야기만, 3 고갈만)
function Fate.causeOn(cause)
    if not Fate.enabled() then return false end
    local c = StoryEngine.Tuning and StoryEngine.Tuning.num("NpcFateCause") or 1
    if c == 2 then return cause == "story" end
    if c == 3 then return cause == "starve" end
    return true
end

local function nameOf(fid) return Stories.NAMES[fid] or fid end

function Fate.of(fid)
    if not Factions.byId[fid] then return nil end
    return Life.npc(fid).fate
end

function Fate.isGone(fid)
    return Fate.of(fid) ~= nil
end

-- 모든 모듈이 이것으로 거른다 (Factions 는 공용 파일이라 서버에서 채운다)
Factions.isGone = Fate.isGone
Factions.fateOf = function(fid)
    local f = Fate.of(fid)
    return f and f.kind or nil
end

local function pending()
    local d = Store.data()
    d.fatePending = d.fatePending or {}
    return d.fatePending
end

local function livingPlayers()
    local out = {}
    for _, ps in pairs(Store.data().players) do
        if not ps.dead then out[#out + 1] = ps end
    end
    return out
end

-- ---------------------------------------------------------------- 이야기

-- 이야기 부탁 결과 (Social.onQuest) / 위기에서 편들어 줌 (Social.onChoice)
function Fate.onStoryResult(fid, won)
    local st = StoryEngine.Social and StoryEngine.Social.story(fid)
    if not st then return end
    if won then st.wins = (st.wins or 0) + 1 else st.losses = (st.losses or 0) + 1 end
end

-- 이야기가 마지막 단계에 이르렀다 (Social.moveTo)
function Fate.onStoryFinal(fid, node)
    if Fate.isGone(fid) or not Fate.DOOM[fid] then return end
    local st = StoryEngine.Social.story(fid)
    if (st.wins or 0) > 0 or (st.losses or 0) < Fate.STORY_LOSSES then return end
    local now = Sensor.now()
    if not Fate.causeOn("story") then
        -- 끄면 최악 결말도 "크게 다쳤지만 살아 있음"
        for _, r in ipairs(Life.RESOURCES) do
            if Life.get(fid, r) < Life.SELF_MIN then Life.change(fid, r, Life.SELF_MIN - Life.get(fid, r), "survived") end
        end
        Life.record(fid, "survived", nil, 0)
        Radio.react(fid, "event", "You came very close to the end: " .. Fate.DOOM[fid].text
            .. " But you survived it, badly hurt. Tell the players what happened, shaken.", nil, nil)
        log("fate survived", fid)
        return
    end
    pending()[fid] = { dueT = now.t + Fate.DELAY_MIN, kind = Fate.DOOM[fid].kind, reason = "story" }
    log("fate scheduled", fid, Fate.DOOM[fid].kind)
end

-- ---------------------------------------------------------------- 고갈

-- 하루가 끝날 때 (Life.daily 가 부른다)
function Fate.daily()
    for _, f in ipairs(Factions.list) do
        local fid = f.id
        if not Fate.isGone(fid) and not pending()[fid] then
            local n = Life.npc(fid)
            local all, any = true, false
            for _, r in ipairs(Life.RESOURCES) do
                local v = n.res[r] or 0
                if v >= Fate.STARVE_ALL then all = false end
                if v >= Fate.STARVE_RESET then any = true end
            end
            if all then
                n.starve = (n.starve or 0) + 1
                if n.starve >= Fate.STARVE_DAYS and Fate.causeOn("starve") then
                    Fate.apply(fid, "gone", "starve")
                else
                    if n.starve >= Fate.STARVE_DAYS then n.starve = Fate.STARVE_DAYS - 1 end
                    log("fate starving", fid, n.starve)
                    Radio.react(fid, "event", "Your people have run out of almost everything: food, medicine, "
                        .. "ammunition and hope are all nearly gone. Tell the players you cannot hold out much longer "
                        .. "and will have to abandon your place soon unless something changes.",
                        { text = "We're out of everything. We can't hold out much longer.",
                          lt = { key = "IGUI_StoryEngine_RadioSay_fate_warn" } }, nil)
                end
            elseif any then
                n.starve = 0
            end
        end
    end
end

-- ---------------------------------------------------------------- 결말

local function fateText(fid, kind, reason)
    if reason == "story" and Fate.DOOM[fid] then return Fate.DOOM[fid].text end
    return nameOf(fid) .. "'s people ran out of everything and left their place to find somewhere else. They are off the air."
end

-- 소식을 전할 NPC: 이 NPC 를 좋아하던 사람 우선, 없으면 아무나 (살아 있는)
local function announcer(fid)
    local friends, others = {}, {}
    for _, f in ipairs(Factions.list) do
        if f.id ~= fid and not Fate.isGone(f.id) then
            if StoryEngine.Bonds.get(f.id, fid) > 0 then friends[#friends + 1] = f.id else others[#others + 1] = f.id end
        end
    end
    local pool = #friends > 0 and friends or others
    if #pool == 0 then return nil end
    return pool[ZombRand(#pool) + 1]
end

function Fate.apply(fid, kind, reason)
    if Fate.isGone(fid) then return end
    local now = Sensor.now()
    local text = fateText(fid, kind, reason)
    -- 떠나는 사람은 마지막으로 직접 말한다 (죽음 처리 전에 요청해야 걸러지지 않는다)
    if kind == "gone" then
        Radio.react(fid, "event", "This is your last call before you go off the air for good: " .. text
            .. " Say goodbye to the players in character.",
            { text = "This is my last call. Take care of yourselves.", lt = { key = "IGUI_StoryEngine_RadioSay_fate_goodbye" } }, nil)
    end
    -- 떠나는 사람의 마지막 편지는 다음 보급에 실려 온다 (Letters.lua)
    if kind == "gone" and StoryEngine.Letters then StoryEngine.Letters.queue(fid, "farewell", text) end
    local n = Life.npc(fid)
    n.fate = { kind = kind, reason = reason, day = Store.dayIndex(now.dayKey), t = now.t }
    pending()[fid] = nil
    Radio.push(fid, { from = "system", fate = kind, clock = now.clock })
    log("fate", fid, kind, reason)

    if kind == "dead" then
        local who = announcer(fid)
        if who then
            Radio.react(who, "event", "You just heard terrible news: " .. text
                .. " Tell the players, grieving or shaken in your own way.", nil, nil)
        end
    end
    -- 다른 NPC: 사기 하락, 소문
    for _, f in ipairs(Factions.list) do
        if f.id ~= fid and not Fate.isGone(f.id) then
            local friend = StoryEngine.Bonds.get(f.id, fid) > 0
            Life.change(f.id, "morale", -(friend and Fate.FRIEND_HIT or Fate.MORALE_HIT), "fate " .. fid)
        end
    end
    if StoryEngine.Social then
        StoryEngine.Social.news("all", "Word on the radio: " .. text)
    end
    -- 모든 캐릭터의 다음 일지
    for _, ps in ipairs(livingPlayers()) do
        Store.addNote(ps, { kind = "npc_" .. kind, faction = fid, clock = now.clock })
    end
    -- 그 NPC 의 진행 중 부탁·거래는 페널티 없이 취소
    if StoryEngine.Quests and StoryEngine.Quests.cancelFor then
        local ok, err = pcall(StoryEngine.Quests.cancelFor, fid, now)
        if not ok then log("fate cancel error:", err) end
    end
    pcall(Net.toAll, "npcFate", { faction = fid, kind = kind })
end

-- 디버그: 되살린다 (자원은 기준값, 고갈 날수와 이야기 성적도 초기화)
function Fate.revive(fid)
    local n = Life.npc(fid)
    n.fate, n.starve = nil, nil
    pending()[fid] = nil
    for _, r in ipairs(Life.RESOURCES) do n.res[r] = Life.base(fid, r) end
    if StoryEngine.Social then
        local st = StoryEngine.Social.story(fid)
        st.wins, st.losses = nil, nil
    end
    Radio.push(fid, { from = "system", fate = "revived", clock = Sensor.now().clock })
    log("fate revived", fid)
end

function Fate.tick()
    local now = Sensor.now()
    for fid, p in pairs(pending()) do
        if now.t >= p.dueT then Fate.apply(fid, p.kind, p.reason) end
    end
end

function Fate.statusText()
    local parts = {}
    for _, f in ipairs(Factions.list) do
        local fate = Fate.of(f.id)
        local n = Life.npc(f.id)
        if fate then
            parts[#parts + 1] = f.id .. ":" .. fate.kind
        elseif pending()[f.id] then
            parts[#parts + 1] = f.id .. ":doomed"
        elseif (n.starve or 0) > 0 then
            parts[#parts + 1] = f.id .. ":starving" .. tostring(n.starve)
        end
    end
    return "fate " .. (#parts > 0 and table.concat(parts, " ") or "all alive")
end

Events.EveryTenMinutes.Add(function()
    local ok, err = pcall(Fate.tick)
    if not ok then log("fate tick error:", err) end
end)

return Fate
