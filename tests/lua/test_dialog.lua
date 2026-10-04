-- 대화 맥락 (2026-10-04): 말한 플레이어의 몸 상태와 NPC 특기 상태를 AI 에 넘긴다 (같은 것을 계속 캐묻지 않게)
local T = {}

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "KO"
    StoryEngine.Life.daily()
    return p, ps
end

function T.one_to_one_reply_carries_state_and_specialty()
    local p = setup()
    StoryEngine.Radio.lastSay = {}
    H.ok(StoryEngine.Radio.say(p, "doc", "칼에 찔렸어요"))
    local b = H.lastBridge("radio")
    H.ok(type(b.payload.speakerState) == "table", "speaker state sent")
    H.ok(type(b.payload.speakerState.wounds) == "table")
    H.ok(type(b.payload.specialty) == "table" and b.payload.specialty.tier ~= nil, "specialty status sent")
end

function T.npc_first_calls_do_not_carry_player_state()
    setup()
    StoryEngine.Radio.request("ray", "KO", { mode = "chat", topic = "weather" })
    local b = H.lastBridge("radio", "chat")
    H.ok(b.payload.speakerState == nil and b.payload.specialty == nil)
end

function T.open_channel_reply_carries_state_and_longer_log()
    local p = setup()
    H.eq(StoryEngine.Social.SCENE_LOG, 20)
    StoryEngine.Social.sceneBusy = false
    StoryEngine.Social.lastReplyT = nil
    StoryEngine.Radio.lastSay = {}
    H.ok(StoryEngine.Radio.say(p, "open", "다들 무사해요?"))
    local b = H.lastBridge("radio_scene")
    H.ok(b.payload.said and type(b.payload.said.state) == "table", "player state in the scene")
    local withSpec = 0
    for _, x in ipairs(b.payload.participants) do if x.specialty then withSpec = withSpec + 1 end end
    H.eq(withSpec, #b.payload.participants, "each participant's specialty status")
end

return T
