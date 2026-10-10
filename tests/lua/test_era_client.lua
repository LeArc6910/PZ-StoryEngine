-- 카운티 회의의 결실, 클라이언트 쪽 (Gifts.lua, LetterWindow 헌장, 일지 탭 연대기, 2차 특기 메뉴)
local T = { __client = true }

local function gift(fullType, from, key, voice)
    local it = H.newItem(fullType)
    it.mod.seGiftFrom, it.mod.seGiftKey, it.mod.seGiftVoice = from, key, voice
    it.name = fullType
    function it:getName() return self.name end
    function it:setName(n) self.name = n end
    function it:setCustomName(v) self.custom = v end
    return it
end

function T.gifts_get_a_name_and_a_tooltip_line()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local Gifts = StoryEngine.Gifts
    local rifle = gift("Base.AssaultRifle", "guard", "rifle")
    rifle.container = p.inv
    p.items[#p.items + 1] = rifle
    p.items[#p.items + 1] = H.newItem("Base.Hammer")
    H.eq(Gifts.of(H.newItem("Base.Hammer")), nil)
    H.eq(Gifts.tip(rifle), "IGUI_StoryEngine_Tip_Gift|IGUI_StoryEngine_Faction_guard")
    -- 후임이 준 선물은 그 사람 이름으로
    H.eq(Gifts.giver("guard", "kowalski"), "IGUI_StoryEngine_Voice_kowalski")
    -- 툴팁 맨 위 줄
    StoryEngine.Value.cache["Base.AssaultRifle"] = { category = "firearm", value = 80, tier = 5 }
    local lines = StoryEngine.ItemTooltip.lines(rifle)
    H.ok(string.find(lines[1][1], "IGUI_StoryEngine_Tip_Gift", 1, true), lines[1][1])
    H.ok(#lines > 1, "the usual lines follow")
    -- 이름표: 번역이 있을 때만 붙인다
    local had = getTextOrNull
    getTextOrNull = function(key) return key end
    H.eq(Gifts.relabel(p), 1)
    getTextOrNull = had
    H.eq(rifle.name, "IGUI_StoryEngine_Gift_Name_rifle|IGUI_StoryEngine_Faction_guard")
    H.eq(rifle.custom, true)
    -- 알림
    StoryEngine.Client.handlers.councilGifts({ charter = true, gifts = { { faction = "guard" } } })
    StoryEngine.Client.handlers.eraNotice({ kind = "begin" })
end

function T.the_charter_shows_signatures_and_empty_lines()
    local body = StoryEngineLetterWindow.body({ charter = {
        formed = true, day = 300, held = true,
        signed = { { fid = "ray", text = "Signed, Ray." }, { fid = "guard", voice = "kowalski" } },
        unsigned = {}, blanks = { { fid = "rats", fate = "dead" }, { fid = "hunter", fate = "gone" } },
    } })
    H.ok(string.find(body, "IGUI_StoryEngine_Charter_Title", 1, true))
    H.ok(string.find(body, "IGUI_StoryEngine_Charter_Preamble|300", 1, true))
    H.ok(string.find(body, "Signed, Ray.", 1, true), "the line the contact wrote")
    H.ok(string.find(body, "IGUI_StoryEngine_Voice_kowalski", 1, true), "a successor signs under their own name")
    H.ok(string.find(body, "IGUI_StoryEngine_Charter_Line_default", 1, true), "a prepared line when nothing was written")
    H.ok(string.find(body, "IGUI_StoryEngine_Charter_Blank_dead|IGUI_StoryEngine_Faction_rats", 1, true))
    H.ok(string.find(body, "IGUI_StoryEngine_Charter_Blank_gone|IGUI_StoryEngine_Faction_hunter", 1, true))
    H.ok(string.find(body, "IGUI_StoryEngine_Charter_Held", 1, true))
    local draft = StoryEngineLetterWindow.body({ charter = { formed = false, day = 300, signed = {},
                                                             unsigned = { { fid = "doc" } }, blanks = {} } })
    H.ok(string.find(draft, "IGUI_StoryEngine_Charter_Draft", 1, true))
    H.ok(string.find(draft, "IGUI_StoryEngine_Charter_Unsigned|IGUI_StoryEngine_Faction_doc", 1, true))
    -- 인벤토리에서 읽을 수 있다
    H.ok(StoryEngineLetterWindow.letterOf({ H.newItem("StoryEngine.Charter") }))
end

function T.the_county_chronicle_reads_with_or_without_the_ai()
    local text = StoryEngineJournalPanel.epilogueText
    local ep = { status = "ready", title = "The Year", text = "It was a long year.", day = 300, date = "1994-05-01",
                 result = "formed", held = true, era = true,
                 npcs = { { fid = "ray", arc = "ray5", node = "ray5_9a", final = true, tone = "good" } },
                 players = { { name = "Gerald Kar", defender = true }, { name = "Ann Lee" } } }
    local out = text(ep)
    H.ok(string.find(out, "The Year", 1, true))
    H.ok(string.find(out, "It was a long year.", 1, true))
    H.ok(string.find(out, "IGUI_StoryEngine_Epilogue_Result_formed", 1, true))
    H.ok(string.find(out, "IGUI_StoryEngine_Epilogue_Held", 1, true))
    H.ok(string.find(out, "IGUI_StoryEngine_Epilogue_Era", 1, true))
    H.ok(string.find(out, "Gerald Kar", 1, true) and not string.find(out, "Ann Lee", 1, true), "only those who held the church")
    -- AI 글이 없으면 채널마다 이야기의 끝을 적는다
    ep.text, ep.title, ep.status = nil, nil, "failed"
    ep.npcs[2] = { fid = "doc", gone = "dead", arc = "doc2b", node = "doc2b_5x", final = true, tone = "bad" }
    out = text(ep)
    H.ok(string.find(out, "IGUI_StoryEngine_Epilogue_Title", 1, true))
    H.ok(string.find(out, "IGUI_StoryEngine_Faction_ray", 1, true))
    H.ok(string.find(out, "IGUI_StoryEngine_People_Tone_good", 1, true))
    H.ok(string.find(out, "IGUI_StoryEngine_Fate_dead", 1, true), "the dead are named too")
    -- 아직 받는 중
    H.ok(string.find(text({ status = "loading" }), "IGUI_StoryEngine_Epilogue_Writing", 1, true))
    -- 서버 답을 받으면 보관한다
    StoryEngine.Client.handlers.journalList({ key = "council", own = "me", epilogue = ep, authors = {} })
    H.eq(StoryEngine.Cache.journalEpilogue, ep)
    StoryEngine.Client.handlers.journalList({ key = "me", own = "me", entries = {}, authors = {} })
    H.eq(StoryEngine.Cache.journalEpilogue, nil)
end

return T
