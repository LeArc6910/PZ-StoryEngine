-- 준비된 대사 고르는 방식 (2026-10-15): 다 쓰기 전엔 반복하지 않음, 조건 꼬리표, 말한 사람별 문장 수,
-- 사실을 끼우는 안부, 말의 종류에 맞는 1:1 답
local T = {}

local OFFLINE = { ok = false, error = "bridge_offline" }

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    StoryEngine.Life.daily()
    return p, ps
end

local function num(key) return tonumber(string.match(key, "_(%d+)$")) end

-- 시험 동안만 쓰는 LinesData
local function withData(d, fn)
    local old = StoryEngine.LinesData
    StoryEngine.LinesData = d
    local ok, err = pcall(fn)
    StoryEngine.LinesData = old
    if not ok then error(err, 0) end
end

function T.no_line_repeats_before_all_are_used()
    setup()
    withData({ COUNT = { ray = { chat_checkin = 6 } }, TAGS = {} }, function()
        local seen = {}
        for _ = 1, 6 do
            local i = num(StoryEngine.Lines.lt("ray", "chat_checkin").key)
            H.ok(not seen[i], "line " .. tostring(i) .. " came twice in one round")
            seen[i] = true
        end
        -- 새 바퀴의 첫 줄은 방금 한 말이 아니다
        local last
        for i = 1, 6 do if seen[i] then last = StoryEngine.Store.data().lineBag["ray:chat_checkin"].l end end
        H.ok(num(StoryEngine.Lines.lt("ray", "chat_checkin").key) ~= last)
    end)
    -- 기억은 세이브에 남는다
    H.ok(StoryEngine.Store.data().lineBag["ray:chat_checkin"] ~= nil)
end

function T.tagged_lines_only_when_they_fit()
    setup()
    local L = StoryEngine.Lines
    H.ok(L.fits("winter", { season = "winter" }))
    H.ok(not L.fits("winter", { season = "summer" }))
    H.ok(L.fits("winter,summer", { season = "summer" }), "any tag of one group")
    H.ok(not L.fits("winter,warm", { season = "winter", trust = "cold" }), "every group must fit")
    H.ok(L.fits("nopower", { nopower = true }))
    H.ok(not L.fits("nopower", { nopower = false }))
    H.ok(L.fits("", {}))
    local season = "summer"
    local old = L.contextFn
    L.contextFn = function() return { season = season, trust = "mid" } end
    withData({ COUNT = { doc = { chat_morning = 4 } }, TAGS = { doc = { chat_morning = { [2] = "winter", [3] = "winter" } } } },
        function()
            for _ = 1, 8 do
                local i = num(L.lt("doc", "chat_morning").key)
                H.ok(i ~= 2 and i ~= 3, "a winter line in summer: " .. i)
            end
            season = "winter"
            local got = {}
            for _ = 1, 4 do got[num(L.lt("doc", "chat_morning").key)] = true end
            H.ok(got[2] or got[3], "winter lines show up in winter")
        end)
    L.contextFn = old
end

function T.server_context_reads_the_world()
    setup()
    local ctx = StoryEngine.Lines.context("ray")
    H.ok(ctx ~= nil)
    H.ok(ctx.season ~= nil and ctx.time ~= nil and ctx.trust ~= nil)
    StoryEngine.Radio.channel("ray").trust = 85
    H.eq(StoryEngine.Lines.context("ray").trust, "warm")
    StoryEngine.Radio.channel("ray").trust = 5
    H.eq(StoryEngine.Lines.context("ray").trust, "cold")
end

function T.counts_per_speaker_and_new_kinds()
    setup()
    withData({ COUNT = { ray = { chat_news = 3 }, martha = { chat_checkin = 5 } }, TAGS = {} }, function()
        local L = StoryEngine.Lines
        H.ok(L.speaks("ray", "chat_news"))
        H.ok(not L.speaks("doc", "chat_news"), "no data, no line")
        local k = L.lt("ray", "chat_news").key
        H.ok(string.find(k, "IGUI_StoryEngine_Line_ray_chat_news_", 1, true) ~= nil, k)
        -- 후임은 자기 문장 수
        StoryEngine.Factions.voice.ray = "martha"
        local seen = {}
        for _ = 1, 5 do seen[num(L.lt("ray", "chat_checkin").key)] = true end
        local n = 0
        for _ in pairs(seen) do n = n + 1 end
        H.eq(n, 5)
        StoryEngine.Factions.voice.ray = nil
    end)
end

function T.variants_keep_the_old_first_key()
    setup()
    local L = StoryEngine.Lines
    withData({ COUNT = {}, TAGS = {}, VARIANTS = { Diary_hurt = { 3, false }, Diary_end = { 5, true } } }, function()
        local seen = {}
        for _ = 1, 3 do seen[L.variant("Diary_hurt")] = true end
        H.ok(seen["IGUI_StoryEngine_Diary_hurt"], "variant 1 is the old key")
        H.ok(seen["IGUI_StoryEngine_Diary_hurt_2"] and seen["IGUI_StoryEngine_Diary_hurt_3"])
        local k = L.variant("Diary_end", 3, true)
        H.ok(string.match(k, "^IGUI_StoryEngine_Diary_end_%d$") ~= nil, k)
    end)
    -- 데이터가 없으면 예전 그대로
    withData({ COUNT = {}, TAGS = {}, VARIANTS = {} }, function()
        H.eq(L.variant("Diary_hurt"), "IGUI_StoryEngine_Diary_hurt")
        H.ok(string.match(L.variant("Diary_open_expedition", 2, true), "^IGUI_StoryEngine_Diary_open_expedition_[12]$") ~= nil)
    end)
end

function T.gossip_and_checkin_use_real_facts()
    setup()
    local Social = StoryEngine.Social
    withData({ COUNT = { ray = { chat_other_warm = 2, chat_other_cold = 2, chat_other_plain = 2, chat_short_food = 2,
                                 chat_recent = 2, chat_project = 2, chat_news = 2 } }, TAGS = {} }, function()
        StoryEngine.Bonds.change("ray", "rats", -3, "test")
        local fb = Social.contactFallback({ fid = "ray", reason = "gossip", extra = "rats", topic = "x" })
        H.ok(string.find(fb.lt.key, "chat_other_cold", 1, true) ~= nil, fb.lt.key)
        H.eq(fb.lt.args[1].t, "npc")
        H.eq(fb.lt.args[1].v, "rats")
        fb = Social.contactFallback({ fid = "ray", reason = "news", topic = "x" })
        H.ok(string.find(fb.lt.key, "chat_news", 1, true) ~= nil, fb.lt.key)
        -- 식량이 바닥이면 안부 대신 그 이야기 (확률이라 여러 번)
        StoryEngine.Life.npc("ray").res.food = 5
        local short = false
        for _ = 1, 20 do
            fb = Social.contactFallback({ fid = "ray", reason = "checkin", topic = "x" })
            if string.find(fb.lt.key, "chat_short_food", 1, true) then short = true end
        end
        H.ok(short)
        -- 최근에 일을 끝낸 사람에게 다시 고맙다고
        StoryEngine.Life.npc("ray").res.food = 80
        StoryEngine.Radio.channel("ray").lastHelp = { t = StoryEngine.Sensor.now().t, name = "Gerald Kar" }
        local recent
        for _ = 1, 20 do
            fb = Social.contactFallback({ fid = "ray", reason = "checkin", topic = "x" })
            if string.find(fb.lt.key, "chat_recent", 1, true) then recent = fb end
        end
        H.ok(recent ~= nil)
        H.eq(recent.lt.args[1].v, "Gerald Kar")
    end)
end

function T.completed_requests_are_remembered_for_thanks()
    local p, ps = setup()
    StoryEngine.Social.hookHelp()
    local q = { id = "Q1", kind = "deliver", origin = { faction = "doc" }, targetName = "Gerald Kar" }
    for _, h in ipairs(StoryEngine.Quests.hooks) do pcall(h, q, "completed") end
    H.eq(StoryEngine.Radio.channel("doc").lastHelp.name, "Gerald Kar")
end

function T.private_offline_reply_follows_what_was_said()
    local p = setup()
    withData({ COUNT = { dewey = { reply_trade = 3 } }, TAGS = {} }, function()
        StoryEngine.Radio.lastSay = {}
        H.ok(StoryEngine.Radio.say(p, "dewey", "got anything to trade?", "trade"))
        H.lastBridge("radio").callback(OFFLINE)
        local msgs = StoryEngine.Radio.channel("dewey").messages
        local reply
        for i = #msgs, 1, -1 do if msgs[i].from == "npc" then reply = msgs[i]; break end end
        H.ok(reply and string.find(reply.lt.key, "reply_trade", 1, true) ~= nil, reply and reply.lt.key)
        -- 종류를 모르면 예전처럼
        StoryEngine.Radio.lastSay = {}
        H.ok(StoryEngine.Radio.say(p, "dewey", "hmm", nil))
        H.lastBridge("radio").callback(OFFLINE)
        for i = #msgs, 1, -1 do if msgs[i].from == "npc" then reply = msgs[i]; break end end
        H.ok(string.find(reply.lt.key, "offline_reply", 1, true) ~= nil, reply.lt.key)
    end)
end

function T.monologue_and_banter_use_bags()
    setup()
    withData({ COUNT = {}, TAGS = {}, MONO = { bitten = 4 }, BANTER = { chat = 3 } }, function()
        local seen = {}
        for _ = 1, 4 do seen[StoryEngine.Lines.monoKey("bitten")] = true end
        local n = 0
        for _ in pairs(seen) do n = n + 1 end
        H.eq(n, 4)
        local a = StoryEngine.Lines.banter("chat")
        H.ok(string.match(a.key, "^IGUI_StoryEngine_Banter_chat_[123]_a$") ~= nil, a.key)
    end)
end

return T
