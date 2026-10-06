-- NPC 생활 상태 (서버 측 전용, 2026-09-29 1단계). 설계: docs/DESIGN_NPC_LIFE.md
--
-- 자원 4종(식량·의약품·안전·사기, 0~100)이 NPC 마다 있고, 기준값(시작값) 쪽으로 매일 조금씩 돌아간다.
-- 20 아래로 떨어지면 스스로 회복하지 못해 플레이어의 물자 지원이 필요하다. 부탁·위기·이야기·폭풍으로 크게 움직인다.
-- 물자 지원: 인벤토리의 물건을 원격으로 보내 자원과 신뢰도를 올린다 (NPC 당 3일, 서버 전체).
-- 관계 파급: 누군가를 크게 도우면 그를 좋아하는 NPC 는 +1, 싫어하는 NPC 는 -1 (Stories.BONDS).
-- 행적 기록·평판: NPC 별로 플레이어들과 있었던 일을 남기고, AI 와 거점 탭에 보여 준다.
-- 상태는 ModData d.life = { npc = { [fid] = { res, prev, log, counts, spill, donatedT } }, lastDay }

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Items"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Value"
require "StoryEngine/Radio"
require "StoryEngine/Trust"
require "StoryEngine/Stories"

local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Value = StoryEngine.Value
local Radio = StoryEngine.Radio
local Stories = StoryEngine.Stories
local log = StoryEngine.log

local Life = {}
StoryEngine.Life = Life

Life.RESOURCES = { "food", "medical", "safety", "morale" }
-- 기준값 = 시작값. 매일 이쪽으로 돌아간다
Life.BASE = {
    ray = { food = 45, medical = 30, safety = 35, morale = 60 },
    guard = { food = 50, medical = 20, safety = 75, morale = 40 },
    rats = { food = 50, medical = 35, safety = 60, morale = 55 },
    casey = { food = 35, medical = 20, safety = 30, morale = 45 },
    doc = { food = 40, medical = 55, safety = 30, morale = 45 },
    pike = { food = 35, medical = 30, safety = 30, morale = 70 },
    dewey = { food = 40, medical = 30, safety = 50, morale = 60 },
    hunter = { food = 70, medical = 25, safety = 60, morale = 50 },
}
-- 특기(2단계)에 쓰는 핵심 자원
Life.KEY = { ray = "food", guard = "safety", rats = "safety", casey = "morale", doc = "medical", pike = "morale",
             dewey = "safety", hunter = "safety" }
Life.DRIFT = 5                        -- 하루에 기준값 쪽으로 움직이는 양
Life.SELF_MIN = 20                    -- 이 아래면 스스로 회복하지 못한다
Life.LOW = 40                         -- 이 아래면 부족 (부탁·값에 반영)
Life.PLENTY = 70                      -- 이 이상이면 넉넉
Life.DONATE_GAP_MIN = 3 * 24 * 60     -- 물자 지원 간격 (NPC 당, 서버 전체)
Life.DONATE_MULT = 2                  -- 물건 가치 1 = 자원 +2
Life.DONATE_CAP = 40                  -- 한 번에 자원 하나당 최대
Life.DONATE_TRUST = { { 30, 3 }, { 15, 2 }, { 5, 1 } }
Life.RECORD_MAX = 30
Life.SPILL_BIG_TIER = 3               -- 이 등급 이상 부탁 완료가 "큰 일"
Life.SPILL_WEEK_MIN = 7 * 24 * 60
Life.SPILL_WEEK_CAP = 2               -- 파급 감점은 NPC 당 한 주 최대 -2
Life.SPILL_FLOOR = 20                 -- 파급으로는 이 아래로 내리지 않는다
Life.RATS_KNOWN = 30                  -- 빅과의 일이 다른 NPC 에게 알려질 확률 (%)

-- 평판: 누적 횟수가 min 이상이면 붙는다. only = 이 NPC 들에게만 (빅을 싫어하는 사람들)
Life.TAGS = {
    { id = "reliable", count = "quest_completed", min = 5 },
    { id = "healer", count = "medical_help", min = 3 },
    { id = "abandoner", count = "crisis_snubbed", min = 2 },
    { id = "unreliable", count = "broken", min = 3 },
    { id = "generous", count = "donation", min = 3 },
    { id = "vic_friend", count = "rats_known", min = 3 },
}

local function state()
    local d = Store.data()
    d.life = d.life or { npc = {} }
    d.life.npc = d.life.npc or {}
    return d.life
end

local function copy(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

function Life.npc(fid)
    local s = state()
    local n = s.npc[fid]
    if not n then
        local base = Life.BASE[fid] or { food = 40, medical = 30, safety = 40, morale = 50 }
        n = { res = copy(base), prev = copy(base), log = {}, counts = {}, spill = {} }
        s.npc[fid] = n
    end
    n.log = n.log or {}
    n.counts = n.counts or {}
    n.spill = n.spill or {}
    return n
end

function Life.get(fid, res)
    if not Factions.byId[fid] then return 50 end
    return Life.npc(fid).res[res] or 0
end

-- 자원을 바꾼다. 실제로 바뀐 양을 돌려준다
Life.PLAIN_LOSS = { debug = true, specialty = true, share = true, trade_sold = true }
Life.SOLD_PER_TIER = 4

function Life.change(fid, res, delta, reason)
    if not Factions.byId[fid] or not res or delta == 0 then return 0 end
    -- 샌드박스 손실 배율 (특기 사용 비용·NPC 나눔·디버그는 그대로)
    if delta < 0 and StoryEngine.Tuning and not Life.PLAIN_LOSS[reason or ""] then
        delta = StoryEngine.Tuning.scale(delta, StoryEngine.Tuning.num("LifeLossMult"))
        if delta == 0 then return 0 end
    end
    local n = Life.npc(fid)
    local before = n.res[res] or 0
    n.res[res] = math.max(0, math.min(100, before + delta))
    local applied = n.res[res] - before
    if applied ~= 0 then log("life", fid, res, before, "->", n.res[res], reason or "") end
    return applied
end

-- 지금의 기준값 (장기 프로젝트가 완성되면 +20, Projects.lua)
function Life.base(fid, res)
    local b = (Life.BASE[fid] or {})[res] or 40
    if StoryEngine.Projects then b = b + StoryEngine.Projects.baseBonus(fid, res) end
    return b
end

-- 가장 부족한 자원과 값
function Life.lowest(fid)
    local n = Life.npc(fid)
    local best, value = nil, 101
    for _, r in ipairs(Life.RESOURCES) do
        if (n.res[r] or 0) < value then best, value = r, n.res[r] or 0 end
    end
    return best, value
end

-- 부탁을 고를 때 우선할 자원 (부족한 것이 있을 때만)
function Life.needPrefer(fid)
    local r, v = Life.lowest(fid)
    if v < Life.LOW then return r end
    return nil
end

-- 물건 목록({ { fullType, n } })이 주로 채우는 자원
function Life.resourceOfItems(items)
    local sum = {}
    for _, e in ipairs(items or {}) do
        local ft = type(e) == "table" and e[1] or e
        local n = type(e) == "table" and (e[2] or 1) or 1
        local res, value
        local pc = type(ft) == "string" and string.sub(ft, 1, 4) == "cat:" and string.sub(ft, 5) or nil
        if pc then
            res, value = Value.RESOURCE_OF[pc] or Value.POINT_RESOURCE[pc], 1      -- 품목 점수 부탁 ("cat:food", 점수)
        else
            res, value = Value.resourceOf(ft)
        end
        if res then sum[res] = (sum[res] or 0) + (value or 1) * n end
    end
    local best, top = nil, -1
    for r, v in pairs(sum) do
        if v > top then best, top = r, v end
    end
    return best
end

-- ---------------------------------------------------------------- 매일

-- 서버 날짜가 바뀌면 한 번: 어제 값 기억(화살표용), 기준값 쪽으로 이동 (20 미만은 스스로 못 올라감)
function Life.daily()
    local s = state()
    local now = Sensor.now()
    local day = Store.dayIndex(now.dayKey)
    if s.lastDay == day then return end
    local first = s.lastDay == nil
    s.lastDay = day
    for _, f in ipairs(Factions.list) do
        local n = Life.npc(f.id)
        n.prev = copy(n.res)
        if not first and not n.fate then
            for _, r in ipairs(Life.RESOURCES) do
                local v, b = n.res[r] or 0, Life.base(f.id, r)
                if v > b then
                    n.res[r] = math.max(b, v - Life.DRIFT)
                elseif v < b and v >= Life.SELF_MIN then
                    n.res[r] = math.min(b, v + Life.DRIFT)
                end
            end
        end
    end
    -- 장기 프로젝트 효과 (레이 온실의 식량 보급)
    if not first and StoryEngine.Projects then
        local ok, err = pcall(StoryEngine.Projects.daily)
        if not ok then log("project daily error:", err) end
    end
    -- NPC 사이 사건: 나눔·충돌 (NpcEvents)
    if not first and StoryEngine.NpcEvents then
        local ok, err = pcall(StoryEngine.NpcEvents.daily)
        if not ok then log("npc events daily error:", err) end
    end
    -- 겨울: 모든 NPC 식량이 더 준다 (World.lua)
    if not first and StoryEngine.World then
        local ok, err = pcall(StoryEngine.World.dailyExtra)
        if not ok then log("world daily error:", err) end
    end
    -- 형편 고갈: 모두 바닥이면 날을 센다 (Fate.lua)
    if not first and StoryEngine.Fate then
        local ok, err = pcall(StoryEngine.Fate.daily)
        if not ok then log("fate daily error:", err) end
    end
end

-- ---------------------------------------------------------------- 행적 기록

-- kind: quest_completed | quest_failed | quest_declined | quest_ignored | quest_accepted | trade_done | trade_failed
--       | crisis_helped | crisis_snubbed | crisis_ignored | donation | insult | spill_up | spill_down | rescued
--       | specialty (특기를 써 줌) | ray_supply (레이가 보급을 가져옴)
--       | volunteer (보수 없이 일해 줌) | volunteer_failed | reward_waived (보상을 사양함)
function Life.record(fid, kind, who, delta, extra)
    if not Factions.byId[fid] then return end
    local n = Life.npc(fid)
    local now = Sensor.now()
    local e = { day = Store.dayIndex(now.dayKey), t = now.t, kind = kind, who = who, d = delta ~= 0 and delta or nil }
    for k, v in pairs(extra or {}) do e[k] = v end
    Store.push(n.log, e, Life.RECORD_MAX)
    n.counts[kind] = (n.counts[kind] or 0) + 1
    -- 이름별로도 센다: 캐릭터가 죽은 뒤 NPC 가 그 사람과 함께한 일을 기억한다 (Legacy.lua)
    if StoryEngine.Legacy then StoryEngine.Legacy.count(n, kind, who) end
    if kind == "quest_failed" or kind == "quest_ignored" or kind == "trade_failed" then
        n.counts.broken = (n.counts.broken or 0) + 1
    end
end

function Life.count(fid, key, add)
    local n = Life.npc(fid)
    n.counts[key] = (n.counts[key] or 0) + (add or 1)
end

function Life.tags(fid)
    local n = Life.npc(fid)
    local out = {}
    for _, t in ipairs(Life.TAGS) do
        if (n.counts[t.count] or 0) >= t.min then
            -- 빅과 어울린다는 평판은 빅을 싫어하는 사람만 붙인다
            if t.id ~= "vic_friend" or StoryEngine.Bonds.get(fid, "rats") < 0 then out[#out + 1] = t.id end
        end
    end
    return out
end

-- ---------------------------------------------------------------- 관계 파급

local function weekSpill(n, now)
    local kept, total = {}, 0
    for _, e in ipairs(n.spill) do
        if now.t - e.t < Life.SPILL_WEEK_MIN then
            kept[#kept + 1] = e
            total = total + e.d
        end
    end
    n.spill = kept
    return total
end

-- 플레이어들이 fid 를 크게 도왔다. always = 소문 확률 없이 항상 알려짐 (위기 선택)
-- skip: 이미 따로 반응한 NPC (위기 선택지의 당사자들) 는 파급에서 뺀다
function Life.spill(fid, who, always, skip)
    if StoryEngine.Tuning and StoryEngine.Tuning.get("Spillover") ~= true then return end
    local now = Sensor.now()
    local Trust = StoryEngine.Trust
    local Social = StoryEngine.Social
    if fid == "rats" and not always then
        if ZombRand(100) >= Life.RATS_KNOWN then
            log("life spill hidden", fid)
            return
        end
    end
    for _, f in ipairs(Factions.list) do
        local other = f.id
        local bond = other ~= fid and not Factions.isGone(other) and not (skip and skip[other])
            and StoryEngine.Bonds.get(other, fid) or 0
        if bond ~= 0 then
            local n = Life.npc(other)
            local delta = bond > 0 and 1 or -1
            local trust = Radio.channel(other).trust
            if delta < 0 and (weekSpill(n, now) <= -Life.SPILL_WEEK_CAP or trust <= Life.SPILL_FLOOR) then
                delta = 0
            end
            if delta < 0 and fid == "rats" and StoryEngine.Projects and StoryEngine.Projects.done("rats") then
                delta = 0
            end
            if fid == "rats" then Life.count(other, "rats_known") end
            if delta ~= 0 and Trust then
                local applied = Trust.apply(other, delta, delta > 0 and "spill_up" or "spill_down", nil, nil, fid)
                if applied ~= 0 then
                    Store.push(n.spill, { t = now.t, d = applied }, 20)
                    Life.record(other, applied > 0 and "spill_up" or "spill_down", who, applied, { src = fid })
                end
            end
            if Social then
                local name = Stories.NAMES[fid] or fid
                Social.news(other, "The players went out of their way to help " .. name .. " recently"
                    .. (bond > 0 and ", which you are glad to hear." or ", which does not sit well with you."))
            end
        end
    end
end

-- ---------------------------------------------------------------- 사건 훅

local NPC_KINDS = { deliver = true, horde = true, extort = true }

-- 퀘스트 결과 (Quests setState). trustDelta: 이 결과로 바뀐 신뢰도
function Life.onQuest(q, outcome, trustDelta)
    local fid = q.origin and q.origin.faction
    if not fid or not Factions.byId[fid] then return end
    if q.kind == "choice" then
        if outcome == "ignored" or outcome == "declined" then Life.onCrisisIgnored(q) end
        return
    end
    local who = q.targetName
    local tier = math.max(1, math.floor(q.tier or 1))
    if q.kind == "trade" then
        if outcome == "completed" then
            Life.change(fid, Value.RESOURCE_OF[q.payCategory] or "safety", 10, "trade")
            -- 내준 물건만큼 그 품목 자원이 준다 (등급 x SOLD_PER_TIER, 2026-10-03 점검)
            Life.change(fid, Value.RESOURCE_OF[q.category] or "safety", -Life.SOLD_PER_TIER * tier, "trade_sold")
            Life.record(fid, "trade_done", who, trustDelta)
            if tier >= Life.SPILL_BIG_TIER then Life.spill(fid, who) end
        elseif outcome == "failed" then
            Life.record(fid, "trade_failed", who, trustDelta)
        end
        return
    end
    if not NPC_KINDS[q.kind] then return end
    local res = q.kind == "horde" and "safety" or Life.resourceOfItems(q.need) or "morale"
    if outcome == "completed" then
        Life.change(fid, res, math.min(40, 10 * tier), "quest")
        if res == "medical" then Life.count(fid, "medical_help") end
        Life.record(fid, "quest_completed", who, trustDelta)
        if tier >= Life.SPILL_BIG_TIER and q.kind ~= "extort" then
            -- 위기 후속 부탁이면 그 위기의 당사자는 이미 선택 때 반응했다 (두 번 깎지 않는다)
            local tag = q.origin and q.origin.story
            local c = tag and tag.crisis and StoryEngine.Stories and StoryEngine.Stories.crisis(tag.crisis)
            local involved = nil
            if c then
                involved = {}
                for _, o in ipairs(c.options) do involved[o.faction] = true end
            end
            Life.spill(fid, who, false, involved)
        end
        if q.kind ~= "extort" and StoryEngine.Projects then StoryEngine.Projects.onBigQuest(q, who) end
    elseif outcome == "failed" or outcome == "declined" or outcome == "ignored" then
        if q.kind ~= "extort" then
            Life.change(fid, res, -10, "quest_" .. outcome)
            Life.change(fid, "morale", -5, "quest_" .. outcome)
        end
        Life.record(fid, "quest_" .. outcome, who, trustDelta)
    elseif outcome == "accepted" then
        Life.record(fid, "quest_accepted", who, trustDelta)
    end
end

-- 위기에서 한 세력을 골랐다 (Social.onChoice)
function Life.onCrisis(q, chosen, who)
    local Stories = StoryEngine.Stories
    for _, o in ipairs(q.options or {}) do
        local res = Life.resourceOfItems(o.items) or "morale"
        local role = Stories and Stories.crisisRole(q.crisis, chosen, o.faction)
            or (o.faction == chosen and "chosen" or "snubbed")
        if role == "chosen" then
            Life.change(o.faction, res, 20, "crisis_helped")
            Life.change(o.faction, "morale", 10, "crisis_helped")
            Life.record(o.faction, "crisis_helped", who, 2)
        elseif role == "ally" then
            Life.change(o.faction, "morale", 10, "crisis_ally")
            Life.record(o.faction, "crisis_ally", who, 1)
        elseif role == "spared" then
            -- 이해한다: 변화 없음
        else
            Life.change(o.faction, res, -20, "crisis_snubbed")
            Life.change(o.faction, "morale", -10, "crisis_snubbed")
            Life.record(o.faction, "crisis_snubbed", who, -2)
        end
    end
    local involved = {}
    for _, o in ipairs(q.options or {}) do involved[o.faction] = true end
    Life.spill(chosen, who, true, involved)
end

function Life.onCrisisIgnored(q)
    for _, o in ipairs(q.options or {}) do
        Life.change(o.faction, Life.resourceOfItems(o.items) or "morale", -10, "crisis_ignored")
        Life.record(o.faction, "crisis_ignored", nil, -1)
    end
end

-- 이야기 노드에 들어섰다 (Social.moveTo)
function Life.onBeat(fid, node)
    for res, delta in pairs(node and node.hit or {}) do Life.change(fid, res, delta, "story " .. tostring(node.id)) end
end

function Life.onStorm()
    for _, f in ipairs(Factions.list) do Life.change(f.id, "morale", -5, "storm") end
end

-- ---------------------------------------------------------------- 물자 지원

function Life.donateWait(fid, now)
    local last = Life.npc(fid).donatedT
    if not last then return 0 end
    return math.max(0, math.ceil((Life.DONATE_GAP_MIN - (now.t - last)) / 60))
end

local RES_WORDS = { food = "food", medical = "medicine", safety = "weapons and ammunition", morale = "comforts" }

-- player 가 fid 에게 물건을 보낸다. itemIds: 클라이언트가 고른 아이템 ID. 반환: true, { gains, trust } / false, 오류
function Life.donate(player, fid, itemIds, mode)
    if not Factions.byId[fid] then return false, "no_faction" end
    if Factions.isGone(fid) then return false, "gone" end
    local Projects = StoryEngine.Projects
    local project = mode == "project"
    if project and (not Projects or not Projects.DEF[fid]) then return false, "no_project" end
    if project and Projects.done(fid) then return false, "project_done" end
    if not Factions.canTalk(player) then return false, "no_radio" end
    local now = Sensor.now()
    local wait = Life.donateWait(fid, now)
    if wait > 0 then return false, "cooldown", wait end
    local inv = player:getInventory()
    local chosen, seen, byRes, total, names = {}, {}, {}, 0, {}
    local rule = project and Projects.rule(fid) or nil
    local projectPoints = 0
    local sameType = {}
    for _, id in ipairs(itemIds or {}) do
        local n = math.floor(tonumber(id) or -1)
        if not seen[n] then
            seen[n] = true
            local item = inv:getItemWithIDRecursiv(n)
            local res, value = nil, nil
            -- 같은 물건은 한 번에 Value.SAME_ITEM_CAP 개까지 (넘는 것은 가져가지 않는다, 2026-10-03)
            if item then
                local ft = item:getFullType()
                sameType[ft] = (sameType[ft] or 0) + 1
                if sameType[ft] > Value.SAME_ITEM_CAP then item = nil end
            end
            if item and project and projectPoints >= Projects.DONATE_CAP then
                item = nil       -- 한 번에 최대 점수를 채웠다: 나머지 물건은 가져가지 않는다
            end
            if item and project then
                -- 프로젝트: NPC 마다 받는 물건 규칙 (듀이 차량 부품, 빅 무엇이든 x0.8)
                local pts
                pts, value = Value.projectItem(player, item, rule)
                if pts then
                    res = "project"
                    projectPoints = projectPoints + pts
                end
            elseif item then
                res, value = Value.donatable(player, item)
            end
            if res then
                chosen[#chosen + 1] = item
                byRes[res] = (byRes[res] or 0) + value
                total = total + value
                local nm = item:getDisplayName()
                names[nm] = (names[nm] or 0) + 1
            end
        end
    end
    if #chosen == 0 or total <= 0 then return false, "nothing" end
    for _, item in ipairs(chosen) do StoryEngine.Items.remove(item, player) end

    local ps = Store.player(player)
    local n = Life.npc(fid)
    local wasLow = {}
    local gains = {}
    local points = 0
    if project then
        -- 프로젝트 지원: 자원 대신 진행도로 (받는 자원의 물건 1점, 나머지 0.5점)
        points = Projects.add(fid, math.min(Projects.DONATE_CAP, math.floor(projectPoints + 0.5)), ps.name, "donation")
    else
        for res, value in pairs(byRes) do
            if (n.res[res] or 0) < Life.LOW then wasLow[#wasLow + 1] = RES_WORDS[res] end
            gains[res] = Life.change(fid, res, math.min(Life.DONATE_CAP, math.floor(value * Life.DONATE_MULT + 0.5)), "donation")
            if res == "medical" then Life.count(fid, "medical_help") end
        end
    end
    local trust = 0
    for _, row in ipairs(Life.DONATE_TRUST) do
        if total >= row[1] then
            trust = row[2]
            break
        end
    end
    local applied = trust > 0 and StoryEngine.Trust.apply(fid, trust, "donation", nil, nil) or 0
    n.donatedT = now.t
    Life.record(fid, project and "project_gift" or "donation", ps.name, applied)
    if applied >= 2 then Life.spill(fid, ps.name) end

    -- 목록 문장 (AI·일지용, 영어 이름이 아니어도 된다)
    local list = {}
    for nm, c in pairs(names) do list[#list + 1] = c > 1 and (tostring(c) .. " x " .. nm) or nm end
    table.sort(list)
    local summary = table.concat(list, ", ")
    if string.len(summary) > 200 then summary = string.sub(summary, 1, 200) .. "..." end
    Store.addNote(ps, { kind = project and "project_donation" or "donation", faction = fid, item = summary, clock = now.clock })
    local topic = tostring(ps.name) .. " just sent your people supplies over the radio network (" .. summary .. ")."
    if project and not Projects.done(fid) then
        topic = tostring(ps.name) .. " just sent supplies for your big project, " .. Projects.DEF[fid].name .. " ("
            .. summary .. "). It is now about " .. StoryEngine.intToString(Projects.info(fid).percent) .. "% done."
    end
    if #wasLow > 0 then
        topic = topic .. " You were running low on " .. table.concat(wasLow, " and ") .. ", so this really helps."
    end
    topic = topic .. " Thank them in character, by name."
    -- 프로젝트를 완성시킨 지원이면 완성 무전이 따로 가므로 감사 무전은 생략
    if not (project and Projects.done(fid)) then
        Radio.react(fid, "event", topic, StoryEngine.Lines.fallback(fid, "donation", "Got your supplies. Thank you."), ps)
    end
    log(project and "project donation" or "donation", fid, "by", ps.name, "value", total, "trust", applied, "points", points)
    return true, { gains = gains, trust = applied, points = project and points or nil }
end

-- ---------------------------------------------------------------- AI·클라이언트

-- 무전 요청에 넣는 이 NPC 의 형편, 플레이어들과의 최근 일, 평판
function Life.context(fid)
    if not Factions.byId[fid] then return nil end
    local n = Life.npc(fid)
    local records = {}
    for i = math.max(1, #n.log - 5), #n.log do
        local e = n.log[i]
        records[#records + 1] = { day = e.day, kind = e.kind, who = e.who, d = e.d, src = e.src,
                                  dead = StoryEngine.Legacy and StoryEngine.Legacy.isDead(e.who) or nil }
    end
    return { state = copy(n.res), records = records, tags = Life.tags(fid),
             project = StoryEngine.Projects and StoryEngine.Projects.info(fid) or nil }
end

-- 거점 탭 목록 (psKey = 보는 사람, 특기의 개인별 대기)
function Life.list(psKey)
    local now = Sensor.now()
    local out = {}
    for _, f in ipairs(Factions.list) do
        local n = Life.npc(f.id)
        local recs = {}
        for i = #n.log, math.max(1, #n.log - 19), -1 do
            local e = n.log[i]
            recs[#recs + 1] = { day = e.day, kind = e.kind, who = e.who, d = e.d, src = e.src,
                                dead = StoryEngine.Legacy and StoryEngine.Legacy.isDead(e.who) or nil }
        end
        -- NPC 사이 관계 (Bonds.lua): 이름 목록과 값
        local likes, dislikes, bondVals = {}, {}, {}
        local lk, dk = StoryEngine.Bonds.of(f.id)
        for _, e in ipairs(lk) do likes[#likes + 1] = e.id; bondVals[e.id] = e.v end
        for _, e in ipairs(dk) do dislikes[#dislikes + 1] = e.id; bondVals[e.id] = e.v end
        out[#out + 1] = {
            id = f.id, trust = Radio.channel(f.id).trust, res = copy(n.res), prev = copy(n.prev),
            donateWait = Life.donateWait(f.id, now), records = recs, tags = Life.tags(f.id),
            likes = likes, dislikes = dislikes, bondVals = bondVals, key = Life.KEY[f.id], fate = n.fate and n.fate.kind or nil,
            fateDay = n.fate and n.fate.day or nil, starve = n.starve,
            spec = StoryEngine.Specialty and StoryEngine.Specialty.status(f.id, psKey) or nil,
            project = StoryEngine.Projects and StoryEngine.Projects.info(f.id) or nil,
            volunteer = StoryEngine.Work and StoryEngine.Work.volunteerStatus(f.id) or nil,
        }
    end
    return out
end

-- 디버그: 모든 자원 delta 또는 set
function Life.debugAdjust(fid, delta, set)
    local n = Life.npc(fid)
    for _, r in ipairs(Life.RESOURCES) do
        if set then
            n.res[r] = set == "base" and Life.base(fid, r) or math.max(0, math.min(100, set))
        else
            Life.change(fid, r, delta, "debug")
        end
    end
end

function Life.statusText()
    local parts = {}
    for _, f in ipairs(Factions.list) do
        local r = Life.npc(f.id).res
        parts[#parts + 1] = f.id .. ":" .. table.concat({ StoryEngine.intToString(r.food or 0), StoryEngine.intToString(r.medical or 0),
            StoryEngine.intToString(r.safety or 0), StoryEngine.intToString(r.morale or 0) }, "/")
    end
    return "life " .. table.concat(parts, " ")
end

Events.EveryHours.Add(function()
    local ok, err = pcall(Life.daily)
    if not ok then log("life daily error:", err) end
end)

return Life
