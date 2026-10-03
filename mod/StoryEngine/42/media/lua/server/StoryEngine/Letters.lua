-- NPC 쪽지·편지 (서버 측 전용, 2026-09-30). 설계: docs/IDEAS_NEXT.md 5번
--
-- 편지는 모드 아이템 StoryEngine.Letter 로 보급품(supply_drop) 속에 들어간다. 글은 서버 ModData 에 두고
-- 아이템에는 번호만 (modData.storyLetter, 퀘스트 태그 storyQuest 도 같이) -> 읽으면 서버가 글을 보내 준다.
-- 언제:
--   gift      신뢰도 70 이상 NPC 의 선물 보급(friend_gift)에 30%
--   greenhouse 레이 온실(장기 프로젝트)의 식량 보급에 30%
--   project   장기 프로젝트 완성 -> 그 NPC 의 다음 보급에
--   farewell  떠나는 NPC 의 마지막 편지 (Fate "gone") -> 다음 보급 아무거나에 (누군가 전해 준다)
-- 기다리는 편지(pending)는 그 NPC 의 보급을 기다리다 3일이 지나면 아무 보급에나 실린다.
-- 글은 브릿지 letter 모듈(받는 캐릭터 언어, NPC 말투 수준 고정, 80~150단어). 실패하면 클라이언트의 준비된 짧은 편지.
-- 읽으면 그 캐릭터 일지에 letter_read (편지마다 한 번). 편지는 버리지 않는 한 남는다.
-- 상태: d.letters = { seq, list = { [id] = rec }, byQuest = { [qid] = id }, pending = { { fid, reason, extra, t } } }
--   rec = { id, from, reason, extra, to, toKey, lang, title, text, status = writing|ready|failed, day, qid, readBy }

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Bridge"
require "StoryEngine/Radio"

local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Bridge = StoryEngine.Bridge
local Radio = StoryEngine.Radio
local log = StoryEngine.log

local Letters = {}
StoryEngine.Letters = Letters

Letters.ITEM = "StoryEngine.Letter"
Letters.GIFT_TRUST = 70
Letters.GIFT_CHANCE = 30
Letters.PENDING_ANY_MIN = 3 * 24 * 60
Letters.MAX_TEXT = 1500
Letters.NOTE_TEXT = 300

function Letters.enabled() return StoryEngine.option("Letters", true) == true end

local function state()
    local d = Store.data()
    d.letters = d.letters or {}
    local s = d.letters
    s.seq = s.seq or 0
    s.list = s.list or {}
    s.byQuest = s.byQuest or {}
    s.pending = s.pending or {}
    return s
end

-- 나중에 보급에 실을 편지 (프로젝트 완성, 떠나는 NPC)
function Letters.queue(fid, reason, extra)
    if not Letters.enabled() or not Factions.byId[fid] then return end
    local s = state()
    s.pending[#s.pending + 1] = { fid = fid, reason = reason, extra = extra, t = Sensor.now().t }
    log("letter queued", fid, reason)
end

-- 편지를 쓴다 (브릿지). 받는 캐릭터 언어로
function Letters.write(rec, ps)
    local fid = rec.from
    local story, life = nil, nil
    if StoryEngine.Social then
        local ok, ctx = pcall(StoryEngine.Social.context, fid)
        if ok then story = ctx end
    end
    if StoryEngine.Life then
        local ok, ctx = pcall(StoryEngine.Life.context, fid)
        if ok then life = ctx end
    end
    local ch = Radio.channel(fid)
    local now = Sensor.now()
    Bridge.request("letter", {
        faction = fid, lang = rec.lang, reason = rec.reason, extra = rec.extra, to = rec.to,
        trust = ch.trust, memory = ch.memory, story = story, life = life,
        day = Store.dayIndex(now.dayKey),
    }, function(res)
        local json = res.ok and res.json
        if type(json) == "table" and type(json.text) == "string" and json.text ~= "" then
            rec.text = string.sub(json.text, 1, Letters.MAX_TEXT)
            rec.title = type(json.title) == "string" and string.sub(json.title, 1, 80) or nil
            rec.status = "ready"
            log("letter written", rec.id, fid, rec.reason)
        else
            rec.status = "failed"
            log("letter failed, using prepared text:", rec.id, tostring(res.error))
        end
    end, { timeoutMs = 60000 })
end

function Letters.create(q, ps, fid, reason, extra, now)
    local s = state()
    s.seq = s.seq + 1
    local id = "L" .. StoryEngine.intToString(s.seq)
    local rec = {
        id = id, from = fid, reason = reason, extra = extra, to = ps.name, toKey = ps.key,
        lang = ps.lang or Radio.langFor(fid, ps), status = "writing", day = Store.dayIndex(now.dayKey),
        qid = q.id, readBy = {},
    }
    s.list[id] = rec
    s.byQuest[q.id] = id
    q.items[#q.items + 1] = Letters.ITEM
    q.letterId = id
    log("letter", id, "from", fid, reason, "in", q.id)
    Letters.write(rec, ps)
    return rec
end

-- 유품 회수(Recover.lua)의 수첩: 죽은 캐릭터의 마지막 일기 몇 장을 그대로 (AI 없음). deadPs 가 없으면 빈 수첩
Letters.MEMORIAL_PAGES = 3
function Letters.createMemorial(q, ps, deadPs, death, now)
    local s = state()
    s.seq = s.seq + 1
    local id = "L" .. StoryEngine.intToString(s.seq)
    local pages = {}
    local journal = deadPs and deadPs.journal or {}
    for i = #journal, 1, -1 do
        local e = journal[i]
        if (e.kind == "daily" or e.kind == "memoir") and #pages < Letters.MEMORIAL_PAGES then
            table.insert(pages, 1, { date = e.date, text = e.text and string.sub(e.text, 1, Letters.MAX_TEXT) or nil,
                                     lt = e.lt, lts = e.lts, memoir = e.kind == "memoir" or nil })
        end
    end
    local rec = { id = id, memorial = death.name, pages = pages, to = ps.name, toKey = ps.key, status = "ready",
                  day = Store.dayIndex(now.dayKey), qid = q.id, readBy = {} }
    s.list[id] = rec
    s.byQuest[q.id] = id
    q.items[#q.items + 1] = Letters.ITEM
    q.letterId = id
    log("memorial note", id, death.name, #pages, "pages in", q.id)
    return rec
end

-- 보급을 만들 때 (Quests.create, 물건을 놓기 전): 실을 편지가 있으면 q.items 에 더한다
function Letters.attach(q, ps, now)
    if not Letters.enabled() or q.kind ~= "supply_drop" then return nil end
    local s = state()
    local fid = q.origin and q.origin.faction
    for i, p in ipairs(s.pending) do
        if p.fid == fid or Factions.isGone(p.fid) or now.t - p.t >= Letters.PENDING_ANY_MIN then
            table.remove(s.pending, i)
            return Letters.create(q, ps, p.fid, p.reason, p.extra, now)
        end
    end
    local o = q.origin or {}
    if fid and o.friend and not Factions.isGone(fid) and Radio.channel(fid).trust >= Letters.GIFT_TRUST
        and ZombRand(100) < Letters.GIFT_CHANCE then
        return Letters.create(q, ps, fid, o.project and "greenhouse" or "gift", nil, now)
    end
    return nil
end

-- 아이템의 편지 기록 (modData.storyLetter, 없으면 퀘스트 번호로)
function Letters.find(id, qid)
    local s = state()
    local rec = id and s.list[tostring(id)]
    if not rec and qid then
        local lid = s.byQuest[tostring(qid)]
        rec = lid and s.list[lid]
    end
    return rec
end

-- 읽기: 클라이언트에 보낼 내용. 처음 읽는 캐릭터는 일지 메모
function Letters.read(player, id, qid)
    local rec = Letters.find(id, qid)
    if not rec then return nil, "no_letter" end
    local ps = Store.player(player)
    rec.readBy = rec.readBy or {}
    if not rec.readBy[ps.key] then
        rec.readBy[ps.key] = true
        local text = rec.text and string.sub(rec.text, 1, Letters.NOTE_TEXT) or nil
        if rec.memorial then
            Store.addNote(ps, { kind = "memorial_read", by = rec.memorial, clock = Sensor.now().clock })
        else
            Store.addNote(ps, { kind = "letter_read", faction = rec.from, reason = rec.reason, text = text,
                                clock = Sensor.now().clock })
        end
        log("letter read", rec.id, "by", ps.name)
    end
    return {
        id = rec.id, from = rec.from, reason = rec.reason, to = rec.to, day = rec.day,
        title = rec.title, text = rec.text, writing = rec.status == "writing" or nil,
        memorial = rec.memorial, pages = rec.pages,
    }
end

function Letters.statusText()
    local s = state()
    local n, unread = 0, 0
    for _, rec in pairs(s.list) do
        n = n + 1
        local read = false
        for _ in pairs(rec.readBy or {}) do read = true end
        if not read then unread = unread + 1 end
    end
    local pend = {}
    for _, p in ipairs(s.pending) do pend[#pend + 1] = p.fid .. ":" .. tostring(p.reason) end
    return "letters " .. StoryEngine.intToString(n) .. " unread=" .. StoryEngine.intToString(unread)
        .. " pending=" .. (#pend > 0 and table.concat(pend, ",") or "none")
end

return Letters
