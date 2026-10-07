-- NPC 인물 이야기 (2026-10-07 사용자 요청): 교신 창 "인물" 탭에서 NPC 의 이름·나이·성별·가족·사는 곳·하던 일과
-- 지나온 일을 읽는다. 고정 정보는 번역 키(IGUI_StoryEngine_Profile_<npc>_<칸>)이고, 이야기가 흘러가면 바뀐다:
-- 이야기 노드의 profile = { family = "<변형>", home = "<변형>" } 이 Social.story(fid).profile 에 남고, 클라이언트는
-- IGUI_StoryEngine_Profile_<npc>_<칸>_<변형> 을 쓴다.
--
-- 지나온 일(Radio.channel(fid).chronicle, 최근 MAX 개): 이야기 장면(beat), 위기에서의 처지(crisis), 신뢰도 문턱
-- (trust 20/40/60/80, 처음 넘을 때 한 번), 장기 프로젝트(project), 운명(fate), 캐릭터의 죽음(death),
-- 행적 일부(rec: 복구 작전·큰 사건·살아남음 — Life.record 에서), 새 큰 이야기의 시작(arc, Social.startSequel).
-- 표시 문장은 클라이언트가 번역한다. 인물 탭 위쪽 "큰 이야기" 칸은 Social.storyInfo (payload 의 story).

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Radio"

local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Radio = StoryEngine.Radio

local Chronicle = {}
StoryEngine.Chronicle = Chronicle

Chronicle.MAX = 40
Chronicle.TRUST_MARKS = { 20, 40, 60, 80 }
-- Life.record 의 이 종류는 지나온 일에도 남긴다 (문장은 행적과 같은 IGUI_StoryEngine_Life_Rec_<종류>)
Chronicle.FROM_RECORD = { operation_done = true, saga_saved = true, survived = true }

function Chronicle.list(fid)
    local ch = Radio.channel(fid)
    ch.chronicle = ch.chronicle or {}
    return ch.chronicle
end

function Chronicle.add(fid, e)
    if not Factions.byId[fid] or fid == "open" then return end
    local now = Sensor.now()
    e.day = Store.dayIndex(now.dayKey)
    e.t = now.t
    Store.push(Chronicle.list(fid), e, Chronicle.MAX)
end

-- 이야기 노드에 들어섬 (Social.moveTo, 처음 이야기를 만들 때)
function Chronicle.onBeat(fid, node)
    if not node then return end
    Chronicle.add(fid, { k = "beat", node = node.id })
    if node.profile then
        local st = StoryEngine.Social.story(fid)
        st.profile = st.profile or {}
        for field, v in pairs(node.profile) do st.profile[field] = v end
    end
end

-- 신뢰도가 문턱을 처음 넘음 (Trust.apply)
function Chronicle.onTrust(fid, before, after)
    if not after or not before or after <= before then return end
    local ch = Radio.channel(fid)
    ch.trustMarks = ch.trustMarks or {}
    for _, m in ipairs(Chronicle.TRUST_MARKS) do
        if before < m and after >= m and not ch.trustMarks[m] then
            ch.trustMarks[m] = true
            Chronicle.add(fid, { k = "trust", v = m })
        end
    end
end

function Chronicle.onRecord(fid, kind, who)
    if Chronicle.FROM_RECORD[kind] then Chronicle.add(fid, { k = "rec", kind = kind, who = who }) end
end

-- 인물 탭 목록 (클라이언트로)
function Chronicle.payload()
    local out = {}
    local Life, Social = StoryEngine.Life, StoryEngine.Social
    for _, f in ipairs(Factions.list) do
        local ch = Radio.channel(f.id)
        local st = Social and Social.story(f.id) or {}
        local fate = Life and Life.npc(f.id).fate or nil
        local list = {}
        for i = #Chronicle.list(f.id), 1, -1 do list[#list + 1] = Chronicle.list(f.id)[i] end
        out[#out + 1] = {
            id = f.id, freq = f.freq, trust = ch.trust, profile = st.profile or {},
            fate = fate and fate.kind or nil, fateReason = fate and fate.reason or nil, fateDay = fate and fate.day or nil,
            project = StoryEngine.Projects and StoryEngine.Projects.info(f.id) or nil,
            story = Social and Social.storyInfo(f.id) or nil,
            chronicle = list,
        }
    end
    return out
end

return Chronicle
