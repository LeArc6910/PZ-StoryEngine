-- 개인 신뢰 화면 (2026-10-09, docs/DESIGN_PER_PLAYER_TRUST.md 9절): 개인 모드에서만 두 값·안내 줄, 공유·싱글은 지금 그대로
local T = { __client = true }

local function has(text, part, msg)
    H.ok(text and string.find(text, part, 1, true), (msg or "missing") .. ": " .. part .. " in " .. tostring(text))
end
local function hasnt(text, part, msg)
    H.ok(not (text and string.find(text, part, 1, true)), (msg or "unexpected") .. ": " .. part .. " in " .. tostring(text))
end

local function line(fid, m)
    m.clock = m.clock or "08:00"
    return StoryEngineRadioPanel.messageLine(fid, m)
end

function T.trust_lines_personal_group_and_shared()
    local mine = line("ray", { from = "system", trust = 2, personal = true, to = "k1", reason = "chat" })
    has(mine, "IGUI_StoryEngine_Trust_LinePersonal|+2|chat", "my trust line")
    local group = line("ray", { from = "system", trust = 3, group = true, reason = "npc_completed" })
    has(group, "IGUI_StoryEngine_Trust_LineGroup|+3|", "group trust line")
    local down = line("ray", { from = "system", trust = -1, personal = true, reason = "fade" })
    has(down, "IGUI_StoryEngine_Trust_LinePersonal|-1|fade")
    -- 공유·싱글: 지금처럼 "신뢰도"
    local shared = line("ray", { from = "system", trust = 3, reason = "npc_completed" })
    has(shared, "IGUI_StoryEngine_Trust_Line|+3|")
    hasnt(shared, "LinePersonal")
    hasnt(shared, "LineGroup")
end

function T.private_note_and_open_frequency_lines()
    local note = line("ray", { from = "system", privateNote = true, toName = "Gerald Kar" })
    has(note, "IGUI_StoryEngine_Radio_PrivateNote|")
    has(note, "|Gerald Kar", "addressee name")
    hasnt(note, "Trust_Line", "not a trust line")
    local viaNpc = line("open", { from = "system", privateNote = true, toName = "Bob", npc = "doc" })
    has(viaNpc, "IGUI_StoryEngine_Faction_doc", "named after the npc field")
    local ask = line("open", { from = "system", groupAsk = "ray", quest = "Q1" })
    has(ask, "IGUI_StoryEngine_Open_GroupAsk|")
    has(ask, "IGUI_StoryEngine_Faction_ray")
    local crisis = line("open", { from = "system", groupCrisis = { "ray", "doc", "rats" }, quest = "Q2" })
    has(crisis, "IGUI_StoryEngine_Open_GroupCrisis|")
    has(crisis, "IGUI_StoryEngine_Faction_doc")
    has(crisis, "IGUI_StoryEngine_Faction_rats")
end

local function request(extra)
    local q = { id = "Q7", kind = "deliver", state = "proposed", tier = 2, need = {},
                origin = { faction = "ray", date = "7/10", clock = "08:00" }, respondHours = 12 }
    for k, v in pairs(extra or {}) do q[k] = v end
    return q
end

function T.quest_detail_for_someone_elses_request()
    H.addPlayer("tester", "Gerald", "Kar")
    local P = StoryEngineQuestPanel
    local q = request({ personalMode = true, addressed = true, addressedName = "Bob Smith" })
    local text = P.questDetail(q)
    has(text, "IGUI_StoryEngine_Quest_AddressedTo|Bob Smith")
    has(text, "IGUI_StoryEngine_Quest_NotAddressed|0.5", "helpers' share")
    hasnt(text, "IGUI_StoryEngine_Quest_PersonalWork", "not my result")
    H.eq(P.canRespond(q), false, "accept/decline hidden for others")
    H.eq(P.questGroup(q), "others", "other people's requests group")
    -- 내 앞으로 온 부탁
    local mine = request({ personalMode = true, addressed = true, addressedName = "Gerald Kar", forMe = true })
    local mt = P.questDetail(mine)
    has(mt, "IGUI_StoryEngine_Quest_AddressedTo|Gerald Kar")
    has(mt, "IGUI_StoryEngine_Quest_PersonalWork")
    hasnt(mt, "NotAddressed")
    H.eq(P.canRespond(mine), true)
    H.eq(P.questGroup(mine), "proposed")
    -- 답할 시간 동안 접속하지 않아 닫힘
    local lapsed = request({ personalMode = true, addressed = true, addressedName = "Bob", state = "declined", lapsed = true })
    local lt = P.questDetail(lapsed)
    has(lt, "IGUI_StoryEngine_Quest_Lapsed")
    hasnt(lt, "NotAddressed", "no help hint once closed")
end

function T.quest_detail_group_and_personal_work()
    H.addPlayer("tester", "Gerald", "Kar")
    local P = StoryEngineQuestPanel
    local story = request({ personalMode = true, group = true, story = "story" })
    local st = P.questDetail(story)
    has(st, "IGUI_StoryEngine_Quest_GroupWork")
    hasnt(st, "PersonalWork")
    H.eq(P.canRespond(story), true, "anyone answers group work")
    local trade = { id = "T1", kind = "trade", state = "accepted", personalMode = true, goods = {}, payCategory = "food",
                    price = 5, origin = { faction = "ray", date = "7/10" }, owner = "Bob", mine = false }
    has(P.questDetail(trade), "IGUI_StoryEngine_Quest_PersonalWorkOf|Bob")
    trade.mine, trade.owner = true, "Gerald"
    has(P.questDetail(trade), "IGUI_StoryEngine_Quest_PersonalWork")
end

function T.shared_mode_looks_as_before()
    H.addPlayer("tester", "Gerald", "Kar")
    local P = StoryEngineQuestPanel
    local q = request()
    local text = P.questDetail(q)
    for _, k in ipairs({ "GroupWork", "AddressedTo", "PersonalWork", "NotAddressed", "Lapsed" }) do hasnt(text, k) end
    H.eq(P.questGroup(q), "proposed")
    H.eq(P.canRespond(q), true)
    -- 신뢰 표시도 하나 그대로
    StoryEngine.Cache.channels.ray = { id = "ray", trust = 40 }
    H.eq(StoryEngine.UI.trustPairText("ray"), nil, "no pair without personal")
    H.eq(StoryEngine.UI.trustPair("ray", { trust = 40 }), nil)
end

function T.radio_tab_skips_others_requests()
    H.addPlayer("tester", "Gerald", "Kar")
    local Cache = StoryEngine.Cache
    Cache.quests = { request({ personalMode = true, addressed = true, addressedName = "Bob" }) }
    H.eq(StoryEngineRadioPanel.pendingProposal("ray"), nil, "no accept bar for someone else's request")
    Cache.quests[2] = request({ id = "Q8", personalMode = true, addressed = true, forMe = true })
    H.eq(StoryEngineRadioPanel.pendingProposal("ray").id, "Q8")
    Cache.quests = {}
end

function T.personal_trust_from_channels_and_messages()
    H.addPlayer("tester", "Gerald", "Kar")
    local h = StoryEngine.Client.handlers
    local Cache = StoryEngine.Cache
    h.radioChannels({ hasRadio = true, channels = { { id = "ray", trust = 60, personal = 35 }, { id = "doc", trust = 25 } } })
    local my, group = StoryEngine.UI.trustPair("ray")
    H.eq(my, 35)
    H.eq(group, 60)
    has(StoryEngine.UI.trustPairText("ray"), "IGUI_StoryEngine_Trust_Mine|35")
    has(StoryEngine.UI.trustPairText("ray"), "IGUI_StoryEngine_Trust_Group|60")
    H.eq(StoryEngine.UI.trustPair("doc"), nil, "doc entry has no personal value")
    h.radioMessage({ faction = "ray", trust = 61, personal = 37,
                     msg = { n = 5, from = "system", trust = 2, personal = true, reason = "chat" } })
    H.eq(Cache.channels.ray.personal, 37)
    H.eq(Cache.channels.ray.trust, 61)
    -- 거점 목록 항목 (lifeList)
    has(StoryEngine.UI.trustPairText("hunter", { id = "hunter", trust = 10, personal = 4, personalMode = true }),
        "IGUI_StoryEngine_Trust_Mine|4")
    -- 거래 목록 창 머리줄 (personal = true, trust = 내 신뢰)
    local head = StoryEngineTradeCatalogWindow.headerText({ faction = "ray", trust = 37, personal = true }, "food")
    has(head, "IGUI_StoryEngine_Catalog_HeaderPersonal|")
    has(head, "Trust_Mine|37")
    has(head, "Trust_Group|61")
    has(StoryEngineTradeCatalogWindow.headerText({ faction = "ray", trust = 37 }, "food"), "IGUI_StoryEngine_Catalog_Header|37|food")
end

function T.blocked_line_shows_my_trust()
    local text = line("ray", { from = "system", blocked = { category = "medical", tier = 3, need = 40, have = 35 } })
    has(text, "IGUI_StoryEngine_Trade_Blocked|3|")
    has(text, "IGUI_StoryEngine_Trade_BlockedHave|35")
    hasnt(line("ray", { from = "system", blocked = { category = "medical", tier = 3, need = 40 } }), "BlockedHave")
end

return T
