-- NPC 장기 프로젝트 (서버 측 전용, 2026-09-30). 설계: docs/IDEAS_NEXT.md 1번 (사용자 확정 수치)
--
-- NPC 마다 목표 하나(1000점, 2026-09-30 사용자 결정). 거점 탭 [프로젝트 지원]으로 물건을 보내면 받는 물건은 가치 1 = 1점,
-- 다른 물건은 0.5점 (듀이는 차량 부품·정비 도구, 빅은 무엇이든 x0.8 — Value.projectItem),
-- 그 NPC 의 이야기 부탁 완료 +100, 위기에서 그 NPC 편 +50, 3등급 이상 부탁 완료 +25.
-- 30%·60%에서 진척 무전, 100%에서 완성 무전·소문·모든 캐릭터 일지·영구 효과. 완성은 이야기 성공으로 쳐서 최악 결말을 막는다.
-- 진행도는 줄지 않고, NPC 가 죽거나 떠나면 멈춘다. 상태: Life.npc(fid).project = { points, stage, done, doneDay }
--
-- 완성 효과 (각 모듈이 Projects.done(fid) 로 확인한다):
--   ray    온실 농장     식량 기준값 +20, 7일마다 작은 식량 보급(1등급)
--   casey  중계 안테나   정찰 반경 150 -> 250, 정찰 대기 3 -> 2일
--   doc    진료소 확장   의약품 기준값 +20, 치료 때 서로 다른 두 부위 (2026-10-02, 예전: 의약품 절반)
--   pike   교회 텃밭     식량 기준값 +20, 위로의 공포·근육통 없음 시간 1.5배
--   dewey  Ark 트럭      수리 도착 8~10시간 -> 30~60분
--   guard  검문소 탈환   안전 기준값 +20, 분대·자동 지원 +2명(특기 분대는 기본 2/4/6 -> 4/6/8), 빅 패거리 협박 절반
--   hunter 겨울 오두막   안전 기준값 +20, 저격 +10마리
--   rats   교역소 전향   어떤 품목이든 대가로, 묶음 5개·2일 입고, 주간 암시장 물건(Trade.black), 한도 초과 등급의 1.5배 웃돈 없음,
--                         협박 영구 중단, 빅을 도와도 다른 NPC 가 언짢아하지 않음

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

local Projects = {}
StoryEngine.Projects = Projects

Projects.GOAL = 1000
Projects.STAGES = { 30, 60 }          -- 진척 무전을 보내는 % (점수가 아니라 비율)
Projects.STORY_POINTS = 100           -- 2026-09-30: 15 -> 50 -> 100
Projects.DONATE_CAP = 100             -- 프로젝트 지원 한 번에 최대 점수 (2026-09-30). 넘는 물건은 보내지 않는다
Projects.CRISIS_POINTS = 50           -- 2026-09-30: 10 -> 50
Projects.BIG_QUEST_POINTS = 25        -- 2026-09-30: 10 -> 25
Projects.BIG_QUEST_TIER = 3
-- 개인 모드(멀티 + TrustBenefits 2)에서 완성하면 그 NPC 의 집단 신뢰 + (DESIGN_PER_PLAYER_TRUST 5-1·6절: 개인 모드의
-- 집단 신뢰는 무리의 일로만 올라 이야기만으로는 카운티 회의 조건에 못 미친다). 싱글·공유 모드는 없음
Projects.GROUP_TRUST = 15
Projects.BASE_BONUS = 20
Projects.RAY_GIFT_DAYS = 7

-- name: AI 에게 넘기는 영어 이름. res: 받는 자원 / accept = "vehicle"(차량 부품·정비 도구) | "any"(무엇이든, mult 배)
-- base: 완성 시 기준값 +20 되는 자원
Projects.DEF = {
    ray = { name = "a greenhouse farm behind the farmhouse", res = "food", base = "food" },
    casey = { name = "a relay antenna on the radio shack roof", res = "morale" },
    doc = { name = "an expanded clinic with a proper medicine store", res = "medical", base = "medical" },
    pike = { name = "a vegetable garden behind the church", res = "food", base = "food" },
    dewey = { name = "the Ark, an armored rescue truck", accept = "vehicle" },
    guard = { name = "retaking the highway checkpoint", res = "safety", base = "safety" },
    hunter = { name = "a winter-proof cabin with a smokehouse", res = "safety", base = "safety" },
    rats = { name = "turning the crew's hideout into a trading post", accept = "any", mult = 0.8 },
}

function Projects.of(fid)
    if not Projects.DEF[fid] then return nil end
    local n = Life.npc(fid)
    n.project = n.project or { points = 0, stage = 0 }
    return n.project
end

function Projects.done(fid)
    local p = Projects.DEF[fid] and Life.npc(fid).project
    return p ~= nil and p.done == true
end

-- 완성 효과가 반영된 기준값 (Life.daily, 디버그, 되살리기)
function Projects.baseBonus(fid, res)
    local def = Projects.DEF[fid]
    if def and def.base == res and Projects.done(fid) then return Projects.BASE_BONUS end
    return 0
end

local function pct(points) return math.floor(math.min(Projects.GOAL, points) * 100 / Projects.GOAL) end
local function percent(p) return pct(p.points) end

-- 물건을 받는 규칙 (Value.projectItem 에 넘긴다)
function Projects.rule(fid)
    local def = Projects.DEF[fid]
    if not def then return nil end
    return { res = def.res, accept = def.accept, mult = def.mult }
end

local function livingPlayers()
    local out = {}
    for _, ps in pairs(Store.data().players) do
        if not ps.dead then out[#out + 1] = ps end
    end
    return out
end

local function complete(fid, who)
    local p = Projects.of(fid)
    local now = Sensor.now()
    p.done, p.doneDay = true, Store.dayIndex(now.dayKey)
    if StoryEngine.Chronicle then StoryEngine.Chronicle.add(fid, { k = "project", done = true, who = who }) end
    local def = Projects.DEF[fid]
    log("project done", fid, who or "")
    local Trust = StoryEngine.Trust
    local gained = 0
    if Trust and Trust.personalMode() then
        gained = Trust.apply(fid, Projects.GROUP_TRUST, "project_done", nil, nil, nil, "group")
    end
    Life.record(fid, "project_done", who, gained)
    -- 기준값이 오른 자원은 바로 새 기준까지 끌어올린다
    if def.base then
        local target = (Life.BASE[fid] or {})[def.base] or 40
        target = target + Projects.BASE_BONUS
        if Life.get(fid, def.base) < target then Life.change(fid, def.base, target - Life.get(fid, def.base), "project") end
    end
    if StoryEngine.Fate then StoryEngine.Fate.onStoryResult(fid, true) end
    if fid == "rats" and StoryEngine.Bonds then StoryEngine.Bonds.onTradingPost() end
    Radio.react(fid, "event", "Your big project is finished: " .. def.name .. ". The players' help made it possible. "
        .. "Tell them, proud and grateful in your own way, and say what it changes for your people.",
        StoryEngine.Lines.fallback(fid, "project_done", "We finished it. Thank you."), nil)
    if StoryEngine.Social then
        StoryEngine.Social.news("all", (Stories.NAMES[fid] or fid) .. " finished " .. def.name .. " with the players' help.")
    end
    for _, ps in ipairs(livingPlayers()) do
        Store.addNote(ps, { kind = "project_done", faction = fid, item = def.name, clock = now.clock })
    end
    pcall(Net.toAll, "projectDone", { faction = fid })
    -- 그 NPC 의 다음 보급에 감사 편지 (Letters.lua)
    if StoryEngine.Letters then StoryEngine.Letters.queue(fid, "project", def.name) end
end

-- 진행도를 반으로 (방치·실패로 잃은 NPC 의 후임이 이어받을 때, Voices.lua). 끝난 프로젝트는 그대로
function Projects.halve(fid)
    local p = Projects.DEF[fid] and Projects.of(fid)
    if not p or p.done then return end
    p.points = math.floor((p.points or 0) / 2)
    local stage = 0
    for i, s in ipairs(Projects.STAGES) do
        if pct(p.points) >= s then stage = i end
    end
    p.stage = stage
    log("project halved", fid, p.points)
end

-- 진행도를 더한다. 반환: 실제로 더한 점수
function Projects.add(fid, points, who, why)
    local def = Projects.DEF[fid]
    if not def or points <= 0 or Factions.isGone(fid) then return 0 end
    local p = Projects.of(fid)
    if p.done then return 0 end
    local before = p.points
    p.points = math.min(Projects.GOAL, p.points + points)
    local added = p.points - before
    log("project", fid, before, "->", p.points, why or "")
    if p.points >= Projects.GOAL then
        complete(fid, who)
        return added
    end
    for i, stage in ipairs(Projects.STAGES) do
        if pct(before) < stage and pct(p.points) >= stage and (p.stage or 0) < i then
            p.stage = i
            if StoryEngine.Chronicle then StoryEngine.Chronicle.add(fid, { k = "project", pct = percent(p) }) end
            Radio.react(fid, "event", "Progress on your big project (" .. def.name .. "): about "
                .. StoryEngine.intToString(percent(p)) .. "% done, thanks to the players. Tell them how it is going.",
                StoryEngine.Lines.fallback(fid, "project_progress", "The project is coming along.",
                    { { t = "num", v = percent(p) } }), nil)
        end
    end
    return added
end

-- ---------------------------------------------------------------- 훅

-- 이야기 부탁 완료 (Social.onQuest)
Projects.EPISODE_POINTS_PER_TIER = 15       -- 곁가지 부탁 완료 (점검 C6)
function Projects.onStoryWin(fid, who, node, tier)
    if node and (node.chapter == "ep" or node.ai) then
        Projects.add(fid, Projects.EPISODE_POINTS_PER_TIER * math.max(1, tier or 1), who, "episode")
        return
    end
    Projects.add(fid, Projects.STORY_POINTS, who, "story")
end
-- 위기에서 그 NPC 편 (Social.onChoice)
function Projects.onCrisisHelped(fid, who) Projects.add(fid, Projects.CRISIS_POINTS, who, "crisis") end
-- 3등급 이상 부탁 완료 (Life.onQuest, 이야기 부탁은 onStoryWin 으로 따로)
function Projects.onBigQuest(q, who)
    if (q.tier or 0) >= Projects.BIG_QUEST_TIER and not (q.origin and q.origin.story and q.origin.story.node) then
        Projects.add(q.origin.faction, Projects.BIG_QUEST_POINTS, who, "quest")
    end
end

-- 레이 온실: 7일마다 작은 식량 보급 (접속한 사람 중 한 명에게)
function Projects.daily()
    if not Projects.done("ray") or Factions.isGone("ray") then return end
    local p = Projects.of("ray")
    local now = Sensor.now()
    if p.lastGiftT and now.t - p.lastGiftT < Projects.RAY_GIFT_DAYS * 24 * 60 then return end
    local players = Sensor.players()
    if #players == 0 then return end
    local player = players[ZombRand(#players) + 1]
    local ps = Store.player(player)
    local ok, q = pcall(StoryEngine.Quests.create, "supply_drop", player, ps, 1, now,
        { source = "director", faction = "ray", initiator = "gift", friend = true, project = true })
    if ok and q then
        p.lastGiftT = now.t
        log("project ray gift", q.id, ps.name)
    end
end

-- 방위대 검문소: 빅 패거리의 협박이 절반만 (하루 단위로 굴린다)
function Projects.ratsQuietToday()
    if not Projects.done("guard") then return false end
    local p = Projects.of("guard")
    local day = Sensor.now().dayKey
    if p.quietDay ~= day then
        p.quietDay = day
        p.quiet = ZombRand(100) < 50
    end
    return p.quiet == true
end

-- 거점 탭·AI 에 넘기는 정보
function Projects.info(fid)
    local def = Projects.DEF[fid]
    if not def then return nil end
    local p = Projects.of(fid)
    return { points = p.points, goal = Projects.GOAL, done = p.done or nil, res = def.res, accept = def.accept,
             mult = def.mult, name = def.name, percent = percent(p) }
end

function Projects.debugAdd(fid, points)
    Projects.add(fid, points, "debug", "debug")
end

function Projects.statusText()
    local parts = {}
    for fid, _ in pairs(Projects.DEF) do
        local p = Projects.of(fid)
        if p.points > 0 then parts[#parts + 1] = fid .. ":" .. (p.done and "done" or tostring(p.points)) end
    end
    table.sort(parts)
    return "projects " .. (#parts > 0 and table.concat(parts, " ") or "none")
end

return Projects
