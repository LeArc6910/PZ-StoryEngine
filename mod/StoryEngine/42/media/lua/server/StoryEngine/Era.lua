-- 카운티 회의의 결실 (2026-10-10 사용자 결정): 회의는 1년 이야기의 엔딩이라 5등급 보급 대신 뜻깊은 보상을 준다.
-- 보상을 조건마다 나눈다 (Council.finish 가 Era.onFinish 를 부른다):
--   의회가 섬(formed)  -> 의회 시대 (Era.begin): 전기·수도가 다시는 끊기지 않고(Grid.restore FOREVER_DAYS, 진행 중이던 복구
--                         작전은 조용히 거둠), NPC 는 고갈로 떠나지 않으며(Fate.daily -> Era.relief: 카운티가 나눠 줌),
--                         의회가 선 날이 해마다 명절이 되고(Holiday -> Era.holiday), 2차 특기를 언제든 바꿔 쓴다
--                         (Specialty2.changeWait 0). 위협(추적 무리·협박·습격)은 그대로다 (난이도 유지, 사용자 결정).
--   교회를 지킴(cleared) -> 생존자들의 선물 (Era.GIFTS): 신뢰도 GIFT_TRUST 이상인 NPC 가 저마다 이름 붙은 물건을 하나씩.
--                         교회에 있던 사람마다 받는다 (차·가축은 무리에 하나). 줄 사람이 없으면 예전처럼 5등급 보급.
--   결과와 무관          -> 카운티 헌장(아이템 StoryEngine.Charter, 살아 있는 NPC 의 서명 한 줄씩. 못 섰으면 초안: 신뢰도
--                         DRAFT_SIGN_TRUST 이상만 서명)과 에필로그 "카운티 연대기"(일지 탭, 브릿지 epilogue 모듈, 없으면
--                         클라이언트가 이야기 장면 문장으로), 그리고 호칭(무전 요청의 council: 교회를 지킨 사람).
-- 물건은 받는 사람이 접속해 있을 때 인벤토리로 (자리에 없으면 다음 접속 때, s.owed).
-- 이름 붙은 물건: modData seGiftFrom(세력)·seGiftVoice(준 사람이 후임이면 그 id)·seGiftKey -> 클라이언트가 툴팁 줄과 이름을 붙인다.
-- 상태는 d.council 안: era = { day, t, y, m, d }, defenders = { [key] = 이름 }, owed = { [key] = { gifts = {...}, charter } },
--   charterId, epilogue = { status, title, text, lang, day, result, held, npcs, players, siege }, giftCar, giftAnimals

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Bridge"
require "StoryEngine/Radio"
require "StoryEngine/Stories"
require "StoryEngine/Quests"
require "StoryEngine/Letters"
require "StoryEngine/Council"

local Net = StoryEngine.Net
local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Bridge = StoryEngine.Bridge
local Radio = StoryEngine.Radio
local Stories = StoryEngine.Stories
local Quests = StoryEngine.Quests
local Letters = StoryEngine.Letters
local Council = StoryEngine.Council
local log = StoryEngine.log

local Era = {}
StoryEngine.Era = Era

Era.FOREVER_DAYS = 36500                -- "다시는 끊기지 않는다" (100년)
Era.GIFT_TRUST = Council.SIEGE_HELP_TRUST
Era.DRAFT_SIGN_TRUST = 50               -- 의회가 못 섰을 때 초안에 이름을 올리는 신뢰도
Era.RELIEF_TO = 20                      -- 바닥난 NPC 에게 카운티가 채워 주는 선 (Life.SELF_MIN)
Era.CHARTER_ITEM = "StoryEngine.Charter"
Era.GIFT_CAR = "Base.OffRoad"
Era.HOLIDAY_FOOD = "StoryEngine.Food_CouncilBread"
Era.HOLIDAY_NEED = { { "Base.Flour2", 2 }, { "Base.TinnedSoup", 3 }, { "Base.Candle", 2 } }
Era.EPILOGUE_TEXT = 6000
Era.SIGN_TEXT = 240

-- 선물: 첫 물건이 이름 붙은 물건(표시). car = 무리에 한 대(받은 사람은 열쇠가 표시 물건, 나머지는 items), animals = 무리에 한 번
Era.GIFTS = {
    ray = { key = "seeds", animals = true,
            items = { "Base.PotatoBagSeed2", "Base.PotatoBagSeed2", "Base.CabbageBagSeed2", "Base.CabbageBagSeed2",
                      "Base.TomatoBagSeed2", "Base.TomatoBagSeed2", "Base.CarrotBagSeed2", "Base.CarrotBagSeed2" } },
    casey = { key = "radio", items = { "Base.HamRadio1" } },
    doc = { key = "bag",
            items = { "Base.Bag_MedicalBag", "Base.SutureNeedleHolder", "Base.SutureNeedle", "Base.SutureNeedle",
                      "Base.SutureNeedle", "Base.SutureNeedle", "Base.SutureNeedle", "Base.Antibiotics", "Base.Antibiotics",
                      "Base.Antibiotics" } },
    pike = { key = "cross", items = { "Base.Necklace_Crucifix" } },
    dewey = { key = "car", itemKey = "wrench", car = true, items = { "Base.LugWrench", "Base.Jack" } },
    guard = { key = "rifle",
              items = { "Base.AssaultRifle", "Base.556Clip", "Base.556Clip", "Base.556Box", "Base.556Box", "Base.556Box" } },
    rats = { key = "crate", loot = 4 },
    hunter = { key = "knife", items = { "Base.HuntingKnife", "Base.Venison", "Base.Venison", "Base.Venison" } },
}

local function state() return Council.state() end

function Era.active() return state().era ~= nil end
function Era.info() return state().era end

local function voiceOf(fid)
    return Factions.voice and Factions.voice[fid] or false
end

local function nameOf(fid)
    return tostring(Stories.NAMES[fid] or fid)
end

local function today()
    local gt = getGameTime()
    return gt:getYear(), gt:getMonth() + 1, gt:getDay() + 1
end

local function trustOf(fid)
    return Radio.channel(fid).trust or 0
end

local function playerByKey(key)
    for _, p in ipairs(Sensor.players()) do
        if Store.playerKey(p) == key then return p end
    end
    return nil
end

-- ---------------------------------------------------------------- 의회 시대

-- 의회가 섰다: 세계가 바뀐다 (한 번만)
function Era.begin(now)
    local s = state()
    if s.era then return false end
    local y, m, d = today()
    s.era = { day = Store.serverDays(), t = now.t, y = y, m = m, d = d }
    local Ops = StoryEngine.Ops
    if Ops and Ops.supersede then pcall(Ops.supersede, "council") end
    local Grid = StoryEngine.Grid
    if Grid then
        for _, kind in ipairs(Grid.KINDS) do
            local ok, err = pcall(Grid.restore, kind, Era.FOREVER_DAYS, "council")
            if not ok then log("era grid error:", tostring(err)) end
        end
    end
    local text = "The county council took over the substation and the water towers: the county has power and running "
        .. "water again, and this time people are posted there to keep it that way."
    if StoryEngine.Social and StoryEngine.Social.news then StoryEngine.Social.news("all", text) end
    for _, ps in pairs(Store.data().players) do
        if not ps.dead then Store.addNote(ps, { kind = "op", text = text, clock = now.clock }) end
    end
    pcall(Net.toAll, "eraNotice", { kind = "begin" })
    log("era begins", "day", s.era.day)
    return true
end

-- 바닥난 NPC (Fate.daily): 의회 시대에는 떠나지 않고 카운티가 나눠 준다. 처리했으면 true
function Era.relief(fid)
    if not Era.active() then return false end
    local Life = StoryEngine.Life
    if not Life then return false end
    local n = Life.npc(fid)
    for _, r in ipairs(Life.RESOURCES) do
        local v = n.res[r] or 0
        if v < Era.RELIEF_TO then Life.change(fid, r, Era.RELIEF_TO - v, "council") end
    end
    n.starve = 0
    Radio.react(fid, "event", "Your people had run out of almost everything, but the county council sent a wagon from "
        .. "the common stores: enough food, medicine and ammunition to get by. Tell the players, relieved and a little "
        .. "ashamed to have needed it. This is what the council is for.",
        { text = "The council sent a wagon. We'll get by.", lt = { key = "IGUI_StoryEngine_Era_Relief" } }, nil)
    if StoryEngine.Social and StoryEngine.Social.news then
        StoryEngine.Social.news("all", "The county council sent a wagon of supplies to " .. nameOf(fid) .. ", who had run out.")
    end
    log("era relief", fid)
    return true
end

-- 의회의 날: 의회가 선 날이 다음 해부터 명절 (Holiday.upcoming 이 덧붙인다)
function Era.holiday()
    local e = state().era
    if not e or not e.m then return nil end
    return { id = "councilday", date = { e.m, math.min(e.d or 1, 28) }, host = "pike", food = Era.HOLIDAY_FOOD,
             need = Era.HOLIDAY_NEED, fromYear = e.y }
end

-- ---------------------------------------------------------------- 선물

-- 선물을 줄 NPC (살아 있고 신뢰도 GIFT_TRUST 이상). { { fid, voice } }
function Era.givers()
    local out = {}
    for _, f in ipairs(Factions.list) do
        if Era.GIFTS[f.id] and not Factions.isGone(f.id) and trustOf(f.id) >= Era.GIFT_TRUST then
            out[#out + 1] = { fid = f.id, voice = voiceOf(f.id) }
        end
    end
    return out
end

local function tag(item, g, def)
    local mod = item:getModData()
    mod.seGiftFrom = g.fid
    mod.seGiftVoice = g.voice or nil
    mod.seGiftKey = def.key
    -- 영어 이름 (클라이언트가 자기 언어로 다시 붙인다). 안 되는 물건은 툴팁 줄만
    pcall(function()
        item:setName(nameOf(g.fid) .. ": " .. tostring(item:getDisplayName()))
        if item.setCustomName then item:setCustomName(true) end
    end)
end

local function put(inv, fullType, g, def, marked)
    local item = inv:AddItem(fullType)
    if not item then return nil end
    if marked then tag(item, g, def) end
    sendAddItemToContainer(inv, item)
    return item
end

-- 한 NPC 의 선물을 한 사람에게. 반환: 넣은 물건 수
function Era.giveGift(player, g)
    local def = Era.GIFTS[g.fid]
    if not def then return 0 end
    local s = state()
    local inv = player:getInventory()
    local n = 0
    local items = def.items
    if def.loot and StoryEngine.Loot then
        local ok, list = pcall(StoryEngine.Loot.roll, def.loot, g.fid)
        items = ok and list or {}
    end
    local marked = false
    if def.car and not s.giftCar and StoryEngine.Specialty2 and StoryEngine.Specialty2.giftVehicle then
        local ok, car, key = pcall(StoryEngine.Specialty2.giftVehicle, player, Era.GIFT_CAR)
        if ok and car then
            s.giftCar = true
            if key then
                inv:AddItem(key)
                tag(key, g, def)
                sendAddItemToContainer(inv, key)
                n = n + 1
            end
            log("era gift car for", Store.player(player).name)
            return math.max(1, n)
        end
        if not ok then log("era gift car error:", tostring(car)) end
    end
    local itemDef = { key = def.itemKey or def.key }
    for _, ft in ipairs(items or {}) do
        local okI, item = pcall(put, inv, ft, g, itemDef, not marked)
        if okI and item then
            marked = true
            n = n + 1
        elseif not okI then
            log("era gift item error:", ft, tostring(item))
        end
    end
    if def.animals and not s.giftAnimals and StoryEngine.Specialty2 and StoryEngine.Specialty2.giftAnimals then
        local ok, made = pcall(StoryEngine.Specialty2.giftAnimals, player)
        if ok and (made or 0) > 0 then s.giftAnimals = true end
    end
    return n
end

-- 교회를 지킨 사람들에게 줄 선물을 적어 둔다 (접속해 있으면 곧바로 Era.deliver)
function Era.queueGifts(keys)
    local s = state()
    local givers = Era.givers()
    if #givers == 0 then return 0 end
    s.owed = s.owed or {}
    local count = 0
    for key in pairs(keys) do
        local ps = Store.data().players[key]
        if ps and not ps.dead then
            s.owed[key] = s.owed[key] or {}
            s.owed[key].gifts = givers
            count = count + 1
        end
    end
    s.givers = givers
    log("era gifts queued for", count, "from", #givers)
    return #givers
end

-- ---------------------------------------------------------------- 헌장

-- 서명란: 살아 있는 NPC 는 서명(못 선 회의의 초안은 신뢰도 DRAFT_SIGN_TRUST 이상만), 떠났거나 죽은 채널은 빈칸
function Era.signers(formed)
    local signed, unsigned, blanks = {}, {}, {}
    for _, f in ipairs(Factions.list) do
        if Era.GIFTS[f.id] then
            if Factions.isGone(f.id) then
                blanks[#blanks + 1] = { fid = f.id, voice = voiceOf(f.id), fate = Factions.fateOf and Factions.fateOf(f.id) or "gone" }
            elseif formed or trustOf(f.id) >= Era.DRAFT_SIGN_TRUST then
                signed[#signed + 1] = { fid = f.id, voice = voiceOf(f.id) }
            else
                unsigned[#unsigned + 1] = { fid = f.id, voice = voiceOf(f.id) }
            end
        end
    end
    return signed, unsigned, blanks
end

function Era.writeCharter(now)
    local s = state()
    local formed = s.result == "formed"
    local signed, unsigned, blanks = Era.signers(formed)
    local rec = Letters.createPlain({
        from = "pike", charter = { formed = formed, day = Store.serverDays(), signed = signed, unsigned = unsigned,
                                   blanks = blanks, held = s.cleared == true },
    }, now)
    s.charterId = rec.id
    s.owed = s.owed or {}
    for key, ps in pairs(Store.data().players) do
        if not ps.dead then
            s.owed[key] = s.owed[key] or {}
            s.owed[key].charter = true
        end
    end
    log("era charter", rec.id, formed and "signed" or "draft", #signed, "signatures")
    return rec
end

local function giveCharter(player)
    local s = state()
    if not s.charterId then return false end
    local inv = player:getInventory()
    local item = inv:AddItem(Era.CHARTER_ITEM)
    if not item then return false end
    item:getModData().storyLetter = s.charterId
    sendAddItemToContainer(inv, item)
    return true
end

-- 받을 것이 남은 사람이 접속해 있으면 준다 (회의가 끝났을 때, 그 뒤 10분마다)
function Era.deliver()
    local s = state()
    if not s.owed then return 0 end
    local done = 0
    for key, owe in pairs(s.owed) do
        local player = playerByKey(key)
        if player and not player:isDead() then
            local got = {}
            if owe.charter then
                local ok, err = pcall(giveCharter, player)
                if not ok then log("era charter error:", tostring(err)) end
                got.charter = ok or nil
            end
            for _, g in ipairs(owe.gifts or {}) do
                local ok, n = pcall(Era.giveGift, player, g)
                if not ok then log("era gift error:", g.fid, tostring(n)) end
                if ok and n > 0 then got[#got + 1] = { faction = g.fid, voice = g.voice or nil } end
            end
            s.owed[key] = nil
            done = done + 1
            Net.toClient(player, "councilGifts", { gifts = got, charter = got.charter })
            if #got > 0 then
                local names = {}
                for _, g in ipairs(got) do names[#names + 1] = nameOf(g.faction) end
                Store.addNote(Store.player(player), { kind = "op", clock = Sensor.now().clock,
                    text = "after the church held, the people on the radio each sent a keepsake of their own: "
                        .. table.concat(names, ", ") })
            end
            log("era delivered to", Store.player(player).name, "gifts", #got, "charter", tostring(got.charter))
        end
    end
    return done
end

-- ---------------------------------------------------------------- 에필로그

-- 한 채널의 이야기를 한 줄씩 (AI 에게 넘기는 영어)
local function storyLines(fid)
    local Social = StoryEngine.Social
    local st = Social.story(fid)
    local out = {}
    for _, a in ipairs(st.arcs or {}) do
        local node = Stories.node(fid, a.ending)
        if node and node.beat and not node.episode then
            out[#out + 1] = "(" .. tostring(a.tone or "mixed") .. ") " .. tostring(node.beat)
        end
    end
    local now = Stories.node(fid, st.ep and st.ep.node or st.node)
    if now and now.beat then out[#out + 1] = "(now) " .. tostring(now.beat) end
    -- 길면 뒤쪽만
    while #out > 6 do table.remove(out, 1) end
    return out
end

-- 채널마다: 지금 사람, 큰 이야기의 마지막 장면, 앞 사람들
function Era.snapshot()
    local Social, Life = StoryEngine.Social, StoryEngine.Life
    local out = {}
    for _, f in ipairs(Factions.list) do
        local fid = f.id
        if Era.GIFTS[fid] and Social then
            local st = Social.story(fid)
            local node = Stories.node(fid, st.ep and st.ep.node or st.node)
            local row = { fid = fid, voice = voiceOf(fid) or nil, name = nameOf(fid),
                          gone = Factions.isGone(fid) and (Factions.fateOf and Factions.fateOf(fid) or "gone") or nil,
                          trust = trustOf(fid), node = node and node.id or nil,
                          arc = node and Stories.arcOf(fid, node.id) or nil, chapter = node and node.chapter or nil,
                          final = node and node.final == true or nil, tone = node and node.tone or nil,
                          lines = storyLines(fid), prev = {} }
            for _, pv in ipairs((Life and Life.npc(fid).prevVoices) or {}) do
                row.prev[#row.prev + 1] = { voice = pv.voice or false, fate = pv.fate }
            end
            out[#out + 1] = row
        end
    end
    return out
end

-- 살아 있는 캐릭터마다: 이름, 살아남은 날, 교회를 지켰는지, 가장 가까운 NPC 둘
function Era.people()
    local s = state()
    local Legacy = StoryEngine.Legacy
    local out = {}
    for key, ps in pairs(Store.data().players) do
        if not ps.dead and ps.name then
            local close = {}
            for _, f in ipairs(Factions.list) do
                if Legacy and Era.GIFTS[f.id] then
                    local ok, score, words = pcall(Legacy.shared, f.id, ps.name)
                    if ok and (score or 0) >= 4 then close[#close + 1] = { fid = f.id, score = score, words = words } end
                end
            end
            table.sort(close, function(a, b) return a.score > b.score end)
            local row = { name = ps.name, days = Store.daysSeen(ps),
                          defender = (s.defenders or {})[key] ~= nil or nil, close = {} }
            for i = 1, math.min(2, #close) do
                row.close[i] = { faction = close[i].fid, name = nameOf(close[i].fid), did = close[i].words }
            end
            out[#out + 1] = row
        end
    end
    table.sort(out, function(a, b) return tostring(a.name) < tostring(b.name) end)
    return out
end

function Era.writeEpilogue(now)
    local s = state()
    local hq = Store.data().quests[s.hordeId or ""]
    local sg = hq and hq.siege or nil
    local lang = StoryEngine.Broadcast and StoryEngine.Broadcast.language() or "EN"
    local ep = { status = "writing", lang = lang, day = Store.serverDays(), date = now.date, result = s.result,
                 held = s.cleared == true, prep = s.prep, npcs = Era.snapshot(), players = Era.people(),
                 siege = sg and { total = sg.total, sent = sg.sent, held = sg.held } or nil }
    s.epilogue = ep
    local signed = {}
    for _, g in ipairs(Era.signers(s.result == "formed")) do signed[#signed + 1] = g.fid end
    Bridge.request("epilogue", {
        lang = lang, day = ep.day, result = ep.result, held = ep.held, prep = ep.prep, siege = ep.siege,
        era = Era.active() or nil, npcs = ep.npcs, players = ep.players, signers = signed,
    }, function(res)
        local json = res.ok and res.json
        if type(json) == "table" and type(json.text) == "string" and json.text ~= "" then
            ep.text = string.sub(json.text, 1, Era.EPILOGUE_TEXT)
            ep.title = type(json.title) == "string" and string.sub(json.title, 1, 80) or nil
            ep.status = "ready"
            -- 헌장 서명 한 줄씩 (그 NPC 말투)
            local rec = s.charterId and Letters.find(s.charterId)
            local lines = {}
            for _, row in ipairs(type(json.signatures) == "table" and json.signatures or {}) do
                if type(row) == "table" and type(row.line) == "string" and row.line ~= "" then
                    lines[tostring(row.faction)] = string.sub(row.line, 1, Era.SIGN_TEXT)
                end
            end
            if rec and rec.charter then
                for _, g in ipairs(rec.charter.signed or {}) do
                    if lines[g.fid] and (g.voice or false) == voiceOf(g.fid) then g.text = lines[g.fid] end
                end
            end
            log("era epilogue written", lang)
        else
            ep.status = "failed"
            log("era epilogue failed, the client will tell it:", tostring(res.error))
        end
        pcall(Net.toAll, "journalNew", {})
    end, { timeoutMs = 120000 })
    return ep
end

-- 일지 탭에 보낼 에필로그 (없으면 nil)
function Era.epilogueFor()
    local ep = state().epilogue
    if not ep then return nil end
    return { status = ep.status, title = ep.title, text = ep.text, day = ep.day, date = ep.date, result = ep.result,
             held = ep.held, npcs = ep.npcs, players = ep.players, siege = ep.siege, era = Era.active() or nil }
end

-- 일지 탭 왼쪽 목록의 한 줄 (없으면 nil)
function Era.authorRow()
    local ep = state().epilogue
    if not ep then return nil end
    return { key = "council", epilogue = true, result = ep.result, lastDate = ep.date, day = ep.day }
end

-- ---------------------------------------------------------------- 호칭

-- 무전 요청에 넣는다: 회의가 어떻게 끝났고 이 사람이 교회를 지켰는지 (브릿지 format_council)
function Era.context(ps)
    local s = state()
    if s.stage ~= "done" then return nil end
    return { result = s.result, held = s.cleared == true, era = Era.active() or nil,
             days = math.max(0, Store.serverDays() - ((s.epilogue and s.epilogue.day) or Store.serverDays())),
             defender = ps and (s.defenders or {})[ps.key] ~= nil or nil,
             name = ps and (s.defenders or {})[ps.key] ~= nil and ps.name or nil }
end

-- ---------------------------------------------------------------- 회의가 끝났다

-- Council.finish 가 결과를 정한 뒤 부른다. hq = 교회 사수 퀘스트. 반환: 선물을 줄 NPC 수 (0 이면 예전 보급으로)
function Era.onFinish(hq, now)
    local s = state()
    -- 교회를 지킨 사람들 (사수하는 동안 교회에 있던 사람, 기록이 없으면 지금 접속한 사람)
    local keys = {}
    local any = false
    for key, name in pairs((hq and hq.siege and hq.siege.present) or {}) do
        keys[key], any = name, true
    end
    if not any then
        for _, p in ipairs(Sensor.players()) do
            local ps = Store.player(p)
            keys[ps.key] = ps.name
        end
    end
    s.defenders = s.cleared and keys or {}
    if s.result == "formed" then Era.begin(now) end
    local givers = 0
    if s.cleared then givers = Era.queueGifts(keys) end
    local okC, errC = pcall(Era.writeCharter, now)
    if not okC then log("era charter error:", tostring(errC)) end
    local okE, errE = pcall(Era.writeEpilogue, now)
    if not okE then log("era epilogue error:", tostring(errE)) end
    Era.deliver()
    return givers
end

-- 디버그: 회의의 결실을 모두 되돌린다 (전기·수도는 원래 값으로)
function Era.reset()
    local s = state()
    if s.era and StoryEngine.Grid then pcall(StoryEngine.Grid.reset, nil, "era reset") end
    s.era, s.owed, s.defenders, s.epilogue, s.charterId, s.givers, s.giftCar, s.giftAnimals = nil, nil, nil, nil, nil, nil, nil, nil
    log("era reset")
end

function Era.statusText()
    local s = state()
    local owed = 0
    for _ in pairs(s.owed or {}) do owed = owed + 1 end
    return "era " .. (s.era and ("since day " .. StoryEngine.intToString(s.era.day)) or "none")
        .. " epilogue " .. tostring(s.epilogue and s.epilogue.status or "none")
        .. " charter " .. tostring(s.charterId or "none") .. " owed " .. StoryEngine.intToString(owed)
end

Sensor.listeners.tick[#Sensor.listeners.tick + 1] = function(entries, now)
    local ok, err = pcall(Era.deliver)
    if not ok then log("era deliver error:", tostring(err)) end
end

return Era
