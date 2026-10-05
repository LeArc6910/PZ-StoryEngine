-- AI 없이 쓰는 대사 (Lines.lua, 2026-10-03): NPC 말투별 대체 문장, 이야기 장면, 버튼 거래, 일기 템플릿,
-- 공용 주파수·동료 대화의 준비된 말
local T = {}

local OFFLINE = { ok = false, error = "bridge_offline" }

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    SandboxVars.StoryEngine.ModItemsRatio = 0
    StoryEngine.Life.daily()
    return p, ps
end

local function lastMsg(fid, from)
    local msgs = StoryEngine.Radio.channel(fid).messages
    for i = #msgs, 1, -1 do
        if not from or msgs[i].from == from then return msgs[i] end
    end
    return nil
end

local function startsWith(s, prefix) return type(s) == "string" and string.sub(s, 1, #prefix) == prefix end

function T.lines_pick_npc_key_with_generic_alt()
    local lt = StoryEngine.Lines.lt("doc", "request", { { t = "need", v = {} } })
    H.ok(startsWith(lt.key, "IGUI_StoryEngine_Line_doc_request_"), lt.key)
    H.eq(lt.alt, "IGUI_StoryEngine_RadioSay_request")
    -- 협박은 위협 세력만: 다른 NPC 는 공통 문장
    H.eq(StoryEngine.Lines.lt("pike", "extort").key, "IGUI_StoryEngine_RadioSay_extort")
    H.ok(startsWith(StoryEngine.Lines.lt("rats", "extort").key, "IGUI_StoryEngine_Line_rats_extort_"))
end

function T.player_talk_offline_gets_npc_reply_and_hint()
    local p = setup()
    StoryEngine.Radio.lastSay = {}
    H.ok(StoryEngine.Radio.say(p, "dewey", "hey dewey"))
    H.lastBridge("radio").callback(OFFLINE)
    local hint = lastMsg("dewey", "system")
    H.ok(hint and hint.offlineHint, "button hint line")
    local reply = lastMsg("dewey", "npc")
    H.ok(reply and startsWith(reply.lt.key, "IGUI_StoryEngine_Line_dewey_offline_reply_"), "npc short reply")
    H.ok(reply.quiet, "not written into the diary radio log")
    -- 두 번째는 안내 줄 없이 답만
    StoryEngine.Radio.lastSay = {}
    StoryEngine.Radio.say(p, "dewey", "again")
    H.lastBridge("radio").callback(OFFLINE)
    local n = 0
    for _, m in ipairs(StoryEngine.Radio.channel("dewey").messages) do if m.offlineHint then n = n + 1 end end
    H.eq(n, 1, "hint only once in a while")
end

function T.other_errors_stay_static()
    local p = setup()
    StoryEngine.Radio.lastSay = {}
    StoryEngine.Radio.say(p, "ray", "hello")
    H.lastBridge("radio").callback({ ok = false, error = "bad_json" })
    H.eq(lastMsg("ray").from, "static")
end

function T.quest_request_and_outcome_use_npc_lines()
    local p, ps = setup()
    local Quests = StoryEngine.Quests
    local q = Quests.propose(p, ps, "pike", 1, StoryEngine.Sensor.now())
    H.ok(q, "request made")
    H.lastBridge("radio", "request").callback(OFFLINE)
    H.ok(startsWith(lastMsg("pike", "npc").lt.key, "IGUI_StoryEngine_Line_pike_request_"))
    H.ok(Quests.respond(p, q.id, true))
    H.lastBridge("radio", "event").callback(OFFLINE)
    H.ok(startsWith(lastMsg("pike", "npc").lt.key, "IGUI_StoryEngine_Line_pike_q_accepted_"), "accepted reaction")
end

function T.story_contact_offline_tells_the_beat()
    setup()
    local Social = StoryEngine.Social
    local fb = Social.contactFallback({ fid = "ray", reason = "story", line = "ray_1", topic = "x" })
    H.eq(fb.lt.key, "IGUI_StoryEngine_Story_ray_1")
    local chat = Social.contactFallback({ fid = "casey", reason = "timely", line = "chat_morning" })
    H.ok(startsWith(chat.lt.key, "IGUI_StoryEngine_Line_casey_chat_morning_"))
    local news = Social.contactFallback({ fid = "doc", reason = "news" })
    H.ok(startsWith(news.lt.key, "IGUI_StoryEngine_Line_doc_chat_checkin_"), "news falls back to a check-in")
end

function T.story_request_offline_says_the_situation_first()
    local p, ps = setup()
    local q = StoryEngine.Quests.proposeCustom(p, ps, "casey", { tier = 1, why = "fever", items = { { "Base.Pills", 1 } } },
        StoryEngine.Sensor.now(), { story = { faction = "casey", node = "casey_2" } })
    H.ok(q)
    H.lastBridge("radio", "request").callback(OFFLINE)
    local msgs = StoryEngine.Radio.channel("casey").messages
    H.eq(msgs[#msgs - 1].lt.key, "IGUI_StoryEngine_Story_casey_2", "beat first")
    H.ok(startsWith(msgs[#msgs].lt.key, "IGUI_StoryEngine_Line_casey_request_"), "then the request")
end

function T.button_trade_makes_an_offer()
    local p, ps = setup()
    StoryEngine.Radio.channel("ray").trust = 65
    StoryEngine.Trade.FREE_CHANCE = 0
    H.ok(StoryEngine.Trade.ask(p, "ray", "food", 2))
    local deal = StoryEngine.Quests.openTrade("ray")
    H.ok(deal and deal.state == "proposed" and deal.category == "food" and deal.tier == 2, "offer quest")
    local asked, offer = nil, nil
    for _, m in ipairs(StoryEngine.Radio.channel("ray").messages) do
        if m.asked then asked = m end
        if m.offer then offer = m end
    end
    H.ok(asked and asked.asked.tier == 2, "asked line")
    H.ok(offer and offer.quest == deal.id, "offer line")
    H.lastBridge("radio", "event").callback(OFFLINE)
    H.ok(startsWith(lastMsg("ray", "npc").lt.key, "IGUI_StoryEngine_Line_ray_offer_"))
    -- 진행 중인 거래가 있으면 또 청할 수 없다
    local ok, why = StoryEngine.Trade.ask(p, "ray", "food", 1)
    H.ok(not ok and why == "open_deal")
end

function T.button_trade_low_trust_is_refused_with_reason()
    local p = setup()
    StoryEngine.Radio.channel("hunter").trust = 0
    H.ok(StoryEngine.Trade.ask(p, "hunter", "firearm", 2))
    H.ok(StoryEngine.Quests.openTrade("hunter") == nil, "no deal")
    H.ok(lastMsg("hunter", "system").blocked, "blocked line")
    H.lastBridge("radio", "event").callback(OFFLINE)
    H.ok(startsWith(lastMsg("hunter", "npc").lt.key, "IGUI_StoryEngine_Line_hunter_refuse_"))
    local opts = StoryEngine.Trade.options("hunter", StoryEngine.Store.player(p))
    H.eq(opts.reason, "low_trust")
    H.ok(#opts.items > 0, "catalog still listed")
end

function T.diary_template_has_several_sentences()
    local _, ps = setup()
    local summary = { class = "combat_day", kills = 20, harmed = true, moodlePeaks = { PANIC = 3 },
                      acts = { cook = { n = 2 }, read = { n = 5 } } }
    local notes = { { kind = "deliver_completed", faction = "ray" }, { kind = "death_of", by = "Kate" },
                    { kind = "deliver_completed", faction = "doc" }, { kind = "unknown_kind" } }
    local text, lt, lts = StoryEngine.Journal.fallbackText(ps, {}, summary, "July 9", notes)
    H.ok(text and lt, "old fields kept")
    local keys = {}
    for _, l in ipairs(lts) do keys[#keys + 1] = l.key end
    local all = table.concat(keys, " ")
    H.ok(string.find(all, "Diary_open_combat_day_", 1, true), all)
    H.ok(string.find(all, "Diary_kills_many", 1, true))
    H.ok(string.find(all, "Diary_hurt", 1, true))
    H.eq(keys[4], "IGUI_StoryEngine_Diary_act_read", "most done activity first")
    H.ok(string.find(all, "Diary_note_delivered", 1, true) and string.find(all, "Diary_note_death_of", 1, true))
    local delivered = 0
    for _, k in ipairs(keys) do if k == "IGUI_StoryEngine_Diary_note_delivered" then delivered = delivered + 1 end end
    H.eq(delivered, 1, "same sentence once")
    H.eq(keys[#keys], "IGUI_StoryEngine_Diary_mood_PANIC")
end

function T.memoir_template()
    local _, ps = setup()
    ps.met = { Kate = 300 }
    ps.radioLife = { { from = "player", faction = "doc" }, { from = "player", faction = "doc" }, { from = "player", faction = "doc" } }
    local lts = StoryEngine.Journal.fallbackMemoir(ps, 12, { { class = "expedition" }, { class = "expedition" } }, 140, "Riverside")
    local all = {}
    for _, l in ipairs(lts) do all[#all + 1] = l.key end
    all = table.concat(all, " ")
    for _, k in ipairs({ "FallbackMemoir", "Memoir_class_expedition", "Memoir_kills", "Memoir_friend", "Memoir_voice",
                         "Memoir_place", "Memoir_end_" }) do
        H.ok(string.find(all, k, 1, true), k .. " in " .. all)
    end
end

-- 공용 주파수 장면의 줄 (나간 첫 줄 + 기다리는 줄)
local function sceneLines()
    local out = {}
    local first = lastMsg("open", "npc")
    if first then out[#out + 1] = first end
    local s = StoryEngine.Store.data().social
    for _, l in ipairs(s and s.pending and s.pending.lines or {}) do out[#out + 1] = l end
    return out
end

local function sayOpen(p, text, intent)
    local Social = StoryEngine.Social
    Social.sceneBusy = false
    Social.lastReplyT = nil
    StoryEngine.Radio.lastSay = {}
    H.ok(StoryEngine.Radio.say(p, "open", text, intent))
    H.lastBridge("radio_scene").callback(OFFLINE)
    return sceneLines()
end

function T.open_channel_offline_answers_by_what_was_said()
    local p = setup()
    local lines = sayOpen(p, "anyone out there?")
    H.eq(#lines, 2, "two contacts answer")
    H.ok(startsWith(lines[1].lt.key, "IGUI_StoryEngine_Line_" .. lines[1].npc .. "_player_greet_"), "a greeting")
    H.eq(lines[1].lt.args[1].v, "Gerald Kar", "addressed by name")
    H.ok(startsWith(lines[2].lt.key, "IGUI_StoryEngine_Line_" .. lines[2].npc .. "_open_reply_"))
    H.ok(H.logHas("open scene offline"))
end

function T.open_channel_offline_uses_the_clients_intent()
    local p = setup()
    local lines = sayOpen(p, "(text in another language)", "trade")
    H.ok(startsWith(lines[1].lt.key, "IGUI_StoryEngine_Line_" .. lines[1].npc .. "_player_trade_"),
        "the client already knew it was a trade question")
    local L = StoryEngine.Lines
    H.eq(L.intentOf("I need some bandages"), "trade")
    H.eq(L.intentOf("help, I'm bitten"), "help")
    H.eq(L.intentOf("thanks a lot"), "thanks")
    H.eq(L.intentOf("nice day"), nil)
    H.eq(L.intentOf("abc XYZ", { info = { "xyz" } }), "info", "extra words from the client's language")
end

local function scheduledScene(ids)
    local Social = StoryEngine.Social
    Social.sceneBusy = false
    Social.scene(nil)
    H.lastBridge("radio_scene").callback(OFFLINE)
    return sceneLines()
end

function T.open_channel_offline_pair_talk_follows_their_bond()
    local p = setup()
    local Social = StoryEngine.Social
    StoryEngine.Bonds.change("ray", "doc", 2, "test", true)
    Social.queueTopic({ "ray", "doc" }, "they catch up")
    ZombRand = function() return 99 end         -- 최근 사건 화제를 고르지 않게
    local lines = scheduledScene()
    H.eq(#lines, 3, "open, reply, close")
    H.ok(startsWith(lines[1].lt.key, "IGUI_StoryEngine_Line_ray_duo_warm_open_"), lines[1].lt.key)
    H.eq(lines[1].lt.args[1].v, "doc", "talks to the other contact")
    H.ok(startsWith(lines[2].lt.key, "IGUI_StoryEngine_Line_doc_duo_warm_reply_"))
    H.ok(startsWith(lines[3].lt.key, "IGUI_StoryEngine_Line_ray_duo_warm_close_"))
    StoryEngine.Bonds.change("guard", "rats", -3, "test", true)
    Social.queueTopic({ "guard", "rats" }, "they argue")
    StoryEngine.Store.data().social.pending = nil
    lines = scheduledScene()
    H.ok(startsWith(lines[1].lt.key, "IGUI_StoryEngine_Line_guard_duo_cold_open_"), "cold when they dislike each other")
end

function T.open_channel_offline_talks_about_what_happened()
    local p = setup()
    local Social = StoryEngine.Social
    Social.queueTopic({ "guard", "rats" }, "firefight", "clash")
    local lines = scheduledScene()
    H.eq(#lines, 2)
    H.ok(startsWith(lines[1].lt.key, "IGUI_StoryEngine_Line_guard_topic_clash_"), lines[1].lt.key)
    H.ok(startsWith(lines[2].lt.key, "IGUI_StoryEngine_Line_rats_topic_reply_"))
    -- 최근 죽음은 저절로 화제가 된다
    StoryEngine.Store.data().social.pending = nil
    Social.onDeath("Ann Lee", "Riverside")
    ZombRand = function() return 0 end
    lines = scheduledScene()
    H.ok(string.find(lines[1].lt.key, "_topic_death_", 1, true), lines[1].lt.key)
    H.eq(lines[1].lt.args[2].v, "Ann Lee", "names the dead")
end

return T
