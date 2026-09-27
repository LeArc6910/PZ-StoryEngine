-- 월드 스토리 로그 저장소 (서버 측 전용). 전역 ModData 라서 세이브와 함께 저장된다.
--
-- ModData "StoryEngine" = {
--   version = 1,
--   dayCount = 0, dayIndex = { [dayKey] = n },       -- 모드가 관측한 날 순번 (D1, D2, ...)
--   players = { [playerKey] = PlayerState },
-- }
-- PlayerState = {
--   name, profession, lang,
--   prev = Sample, seg = 열린 에피소드, pending = { 일지에 아직 안 쓴 에피소드 },
--   day = 오늘 누적값, days = { 지난날 요약 }, journal = { 일지 항목 },
--   home = { x, y, z, building }, sleeps = { 최근 잠든 위치 }, lastJournalT, dead,
--   notes = { 다음 일지에 넣을 사건 (폭풍, 보급 소식 등) },
-- }
-- quests = { [questId] = Quest }   (Quests.lua)
-- director = { history = {...}, lastSlot, lastStormT }   (Director.lua)

if isClient() then return end

require "StoryEngine/Core"

local Store = {}
StoryEngine.Store = Store

Store.MAX_PENDING = 60
Store.MAX_DAYS = 120
Store.MAX_JOURNAL = 100
Store.MAX_NOTES = 30

function Store.data()
    local d = ModData.getOrCreate("StoryEngine")
    if not d.version then
        d.version = 1
        d.dayCount = 0
        d.dayIndex = {}
        d.players = {}
    end
    d.quests = d.quests or {}
    d.questSeq = d.questSeq or 0
    d.director = d.director or { history = {} }
    return d
end

function Store.characterName(player)
    local desc = player:getDescriptor()
    if not desc then return player:getUsername() or "?" end
    return (desc:getForename() or "") .. " " .. (desc:getSurname() or "")
end

-- 멀티에서는 같은 계정이 죽고 새 캐릭터를 만들 수 있으므로 계정 + 캐릭터 이름으로 구분한다.
function Store.playerKey(player)
    return (player:getUsername() or "?") .. "|" .. Store.characterName(player)
end

function Store.player(player)
    local d = Store.data()
    local key = Store.playerKey(player)
    local ps = d.players[key]
    if not ps then
        ps = { pending = {}, days = {}, journal = {}, sleeps = {} }
        d.players[key] = ps
    end
    ps.key = key
    ps.name = Store.characterName(player)
    ps.notes = ps.notes or {}
    if not ps.profession then
        local ok, prof = pcall(function() return player:getDescriptor():getCharacterProfession():getName() end)
        if ok and prof then ps.profession = tostring(prof) end
    end
    return ps
end

function Store.dayIndex(dayKey)
    local d = Store.data()
    local idx = d.dayIndex[dayKey]
    if not idx then
        d.dayCount = d.dayCount + 1
        idx = d.dayCount
        d.dayIndex[dayKey] = idx
    end
    return idx
end

-- ---------------------------------------------------------------- 진행 단계 (밸런스)
-- 서버(월드) 경과 일수로 초반·중반·후반을 나눈다 (모든 플레이어 공통). 초반에는 큰 보상을 주지 않고 실패 부담도 작게,
-- 자원이 쌓인 후반에는 큰 보상이 나오는 대신 실패하면 신뢰를 크게 잃는다 (2026-09-27 사용자 결정).
Store.STAGE_DAYS = { 31, 91 }            -- 이 날부터 중반(1개월 뒤), 후반(3개월 뒤)
Store.STAGE_MAX_TIER = { 2, 4, 5 }       -- 단계별 퀘스트·이벤트 최고 등급
Store.STAGE_PENALTY = { 0.5, 1 }         -- 초반·중반 신뢰도 감점 배율 (후반은 Trust.LATE 표)
-- 세력 신뢰도별 최고 등급: 낯선 사람은 큰 보급을 주지도, 큰 부탁을 하지도 않는다
Store.TRUST_MAX_TIER = { { min = 60, tier = 5 }, { min = 40, tier = 4 }, { min = 20, tier = 3 }, { min = 0, tier = 2 } }

function Store.daysSeen(ps)
    return #(ps.days or {}) + (ps.day and 1 or 0)
end

-- 월드가 시작된 뒤 지난 날 (1일째부터)
function Store.serverDays()
    return math.floor(getGameTime():getWorldAgeHours() / 24) + 1
end

-- 1 초반 / 2 중반 / 3 후반. 서버 경과 일수 기준이라 ps 는 쓰지 않는다 (예전 호출과 맞추려고 받기만 한다)
function Store.stage(ps)
    local d = Store.serverDays()
    if d >= Store.STAGE_DAYS[2] then return 3 end
    if d >= Store.STAGE_DAYS[1] then return 2 end
    return 1
end

-- 다음 일지에 들어갈 사건을 남긴다.
function Store.addNote(ps, note)
    ps.notes = ps.notes or {}
    Store.push(ps.notes, note, Store.MAX_NOTES)
end

-- 이름으로 PlayerState 찾기 (살아 있는 캐릭터 우선)
function Store.findByName(name)
    for _, ps in pairs(Store.data().players) do
        if ps.name == name and not ps.dead then return ps end
    end
    return nil
end

-- 배열 끝에 추가하고 최대 길이를 넘으면 앞에서 버린다.
function Store.push(list, item, max)
    list[#list + 1] = item
    while #list > max do
        table.remove(list, 1)
    end
end

return Store
