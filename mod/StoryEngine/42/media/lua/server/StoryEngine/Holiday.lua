-- 명절 (2026-10-04, 사용자 결정): 게임 언어가 한국어면 한국 명절, 그 밖이면 미국 명절로 같은 흐름을 돌린다.
--   한국: 신정·설날·정월대보름·단오·추석·동지·성탄절 / 미국: 새해·독립기념일·핼러윈·추수감사절·크리스마스
--   (접속자 중 가장 많은 언어, Broadcast.language. 한 번 예고한 명절은 그 해에는 그대로)
-- 흐름: 이틀 전 예고(주관 NPC 무전, 소문·방송, 명절 음식 모금 퀘스트) -> 당일 09시 잔치(모금을 다 채우면 NPC 기호품 +15·식량 +5,
--   낸 사람은 주관 NPC 신뢰도 +1, 접속자마다 명절 음식 3개와 가장 친한 NPC(신뢰도 50+)의 작은 선물 / 못 채우면 기호품 +5, 음식 1개),
--   공용 주파수 잔치 장면, 모든 캐릭터 일지 메모 holiday.
-- 세배(설날·신정, 미국은 새해·크리스마스): 그날 NPC 에게 처음 무전하면 세뱃돈(돈, 신뢰도만큼)이나 명절 음식을 준다 (NPC 마다 한 번).
-- 명절 음식은 모드 아이템(StoryEngine.Food_*)이라 먹으면 불행·지루함·스트레스가 준다 (스크립트 속성, 코드 없음).
-- 음력 명절 날짜는 Meeus 공식으로 계산한 표 (KST, 1990~2035). 1997 설날 2월 8일(중국은 7일)까지 확인.

if isClient() then return end

require "StoryEngine/Core"
require "StoryEngine/Store"
require "StoryEngine/Sensor"
require "StoryEngine/Factions"
require "StoryEngine/Radio"
require "StoryEngine/Quests"
require "StoryEngine/Lines"

local Store = StoryEngine.Store
local Sensor = StoryEngine.Sensor
local Factions = StoryEngine.Factions
local Radio = StoryEngine.Radio
local Quests = StoryEngine.Quests
local log = StoryEngine.log

local Holiday = {}
StoryEngine.Holiday = Holiday

Holiday.ANNOUNCE_DAYS = 2
Holiday.FEAST_HOUR = 9
Holiday.COLLECT_HOUR = 9           -- 모금 마감: 당일 이 시각
Holiday.FEAST_FOOD = 3
Holiday.PARTIAL_FOOD = 1
Holiday.FRIEND_TRUST = 50

Holiday.KO = {
    { id = "newyear", date = { 1, 1 }, host = "casey", greet = "money", food = "StoryEngine.Food_Tteokguk",
      need = { { "Base.Rice", 2 }, { "Base.Egg", 3 } } },
    { id = "seollal", lunar = "seollal", host = "ray", greet = "money", food = "StoryEngine.Food_Tteokguk",
      need = { { "Base.Rice", 3 }, { "Base.Egg", 4 }, { "Base.Seaweed", 2 }, { "Base.SesameOil", 1 } } },
    { id = "daeboreum", lunar = "daeboreum", host = "hunter", food = "StoryEngine.Food_Bureom",
      need = { { "Base.Peanuts", 4 }, { "Base.Soybeans", 2 }, { "Base.Rice", 2 } } },
    { id = "dano", lunar = "dano", host = "doc", food = "StoryEngine.Food_Surichwitteok",
      need = { { "Base.Rice", 2 }, { "Base.Sugar", 1 }, { "Base.Flour2", 1 } } },
    { id = "chuseok", lunar = "chuseok", host = "pike", food = "StoryEngine.Food_Songpyeon",
      need = { { "Base.Rice", 3 }, { "Base.Flour2", 1 }, { "Base.Sugar", 1 }, { "Base.Apple", 3 }, { "Base.Pear", 3 } } },
    { id = "dongji", lunar = "dongji", host = "dewey", food = "StoryEngine.Food_Patjuk",
      need = { { "Base.DriedBlackBeans", 2 }, { "Base.Rice", 2 }, { "Base.Sugar", 1 } } },
    { id = "christmas", date = { 12, 25 }, host = "pike", food = "StoryEngine.Food_ChristmasCake",
      need = { { "Base.Flour2", 2 }, { "Base.Sugar", 2 }, { "Base.Egg", 4 } } },
}
Holiday.EN = {
    { id = "newyear", date = { 1, 1 }, host = "casey", greet = "food", food = "StoryEngine.Food_NewYearCake",
      need = { { "Base.Flour2", 1 }, { "Base.Sugar", 1 }, { "Base.Egg", 2 } } },
    { id = "july4", date = { 7, 4 }, host = "guard", food = "StoryEngine.Food_ApplePie",
      need = { { "Base.BunsHamburger", 4 }, { "Base.Ham", 1 } } },
    { id = "halloween", date = { 10, 31 }, host = "rats", food = "StoryEngine.Food_HalloweenCandy",
      need = { { "Base.Pumpkin", 2 }, { "Base.Sugar", 2 } } },
    { id = "thanksgiving", rule = "thanksgiving", host = "ray", food = "StoryEngine.Food_PumpkinPie",
      need = { { "Base.Pumpkin", 2 }, { "Base.Flour2", 1 }, { "Base.Sugar", 1 }, { "Base.Egg", 3 }, { "Base.Apple", 2 } } },
    { id = "christmas", date = { 12, 25 }, host = "pike", greet = "food", food = "StoryEngine.Food_ChristmasCookies",
      need = { { "Base.Flour2", 2 }, { "Base.Sugar", 2 }, { "Base.Egg", 4 } } },
}
-- AI 에게 주는 명절 설명 (영어)
Holiday.ABOUT = {
    newyear = "New Year's Day", seollal = "Seollal, the Korean Lunar New Year (rice cake soup, bowing to elders, small gifts of money)",
    daeboreum = "Jeongwol Daeboreum, the first full moon of the lunar year (cracking nuts for luck, five-grain rice)",
    dano = "Dano, a Korean early-summer festival (herb rice cakes, swings, wrestling)",
    chuseok = "Chuseok, the Korean harvest festival (half-moon rice cakes, fruit, remembering the dead, the full moon)",
    dongji = "Dongji, the Korean winter solstice (red bean porridge to ward off bad luck)",
    christmas = "Christmas", july4 = "the Fourth of July", halloween = "Halloween", thanksgiving = "Thanksgiving",
}

-- 음력 명절 양력 날짜 (KST). [해] = { 이름 = { 월, 일 } }
Holiday.LUNAR = {
    [1990] = { seollal = {1, 27}, daeboreum = {2, 10}, dano = {5, 28}, chuseok = {10, 3}, dongji = {12, 22} },
    [1991] = { seollal = {2, 15}, daeboreum = {3, 1}, dano = {6, 16}, chuseok = {9, 22}, dongji = {12, 22} },
    [1992] = { seollal = {2, 4}, daeboreum = {2, 18}, dano = {6, 5}, chuseok = {9, 11}, dongji = {12, 21} },
    [1993] = { seollal = {1, 23}, daeboreum = {2, 6}, dano = {6, 24}, chuseok = {9, 30}, dongji = {12, 22} },
    [1994] = { seollal = {2, 10}, daeboreum = {2, 24}, dano = {6, 13}, chuseok = {9, 20}, dongji = {12, 22} },
    [1995] = { seollal = {1, 31}, daeboreum = {2, 14}, dano = {6, 2}, chuseok = {9, 9}, dongji = {12, 22} },
    [1996] = { seollal = {2, 19}, daeboreum = {3, 4}, dano = {6, 20}, chuseok = {9, 27}, dongji = {12, 21} },
    [1997] = { seollal = {2, 8}, daeboreum = {2, 22}, dano = {6, 9}, chuseok = {9, 16}, dongji = {12, 22} },
    [1998] = { seollal = {1, 28}, daeboreum = {2, 11}, dano = {5, 30}, chuseok = {10, 5}, dongji = {12, 22} },
    [1999] = { seollal = {2, 16}, daeboreum = {3, 2}, dano = {6, 18}, chuseok = {9, 24}, dongji = {12, 22} },
    [2000] = { seollal = {2, 5}, daeboreum = {2, 19}, dano = {6, 6}, chuseok = {9, 12}, dongji = {12, 21} },
    [2001] = { seollal = {1, 24}, daeboreum = {2, 7}, dano = {6, 25}, chuseok = {10, 1}, dongji = {12, 22} },
    [2002] = { seollal = {2, 12}, daeboreum = {2, 26}, dano = {6, 15}, chuseok = {9, 21}, dongji = {12, 22} },
    [2003] = { seollal = {2, 1}, daeboreum = {2, 15}, dano = {6, 4}, chuseok = {9, 11}, dongji = {12, 22} },
    [2004] = { seollal = {1, 22}, daeboreum = {2, 5}, dano = {6, 22}, chuseok = {9, 28}, dongji = {12, 21} },
    [2005] = { seollal = {2, 9}, daeboreum = {2, 23}, dano = {6, 11}, chuseok = {9, 18}, dongji = {12, 22} },
    [2006] = { seollal = {1, 29}, daeboreum = {2, 12}, dano = {5, 31}, chuseok = {10, 6}, dongji = {12, 22} },
    [2007] = { seollal = {2, 18}, daeboreum = {3, 4}, dano = {6, 19}, chuseok = {9, 25}, dongji = {12, 22} },
    [2008] = { seollal = {2, 7}, daeboreum = {2, 21}, dano = {6, 8}, chuseok = {9, 14}, dongji = {12, 21} },
    [2009] = { seollal = {1, 26}, daeboreum = {2, 9}, dano = {5, 28}, chuseok = {10, 3}, dongji = {12, 22} },
    [2010] = { seollal = {2, 14}, daeboreum = {2, 28}, dano = {6, 16}, chuseok = {9, 22}, dongji = {12, 22} },
    [2011] = { seollal = {2, 3}, daeboreum = {2, 17}, dano = {6, 6}, chuseok = {9, 12}, dongji = {12, 22} },
    [2012] = { seollal = {1, 23}, daeboreum = {2, 6}, dano = {6, 24}, chuseok = {9, 30}, dongji = {12, 21} },
    [2013] = { seollal = {2, 10}, daeboreum = {2, 24}, dano = {6, 13}, chuseok = {9, 19}, dongji = {12, 22} },
    [2014] = { seollal = {1, 31}, daeboreum = {2, 14}, dano = {6, 2}, chuseok = {9, 8}, dongji = {12, 22} },
    [2015] = { seollal = {2, 19}, daeboreum = {3, 5}, dano = {6, 20}, chuseok = {9, 27}, dongji = {12, 22} },
    [2016] = { seollal = {2, 8}, daeboreum = {2, 22}, dano = {6, 9}, chuseok = {9, 15}, dongji = {12, 21} },
    [2017] = { seollal = {1, 28}, daeboreum = {2, 11}, dano = {5, 30}, chuseok = {10, 4}, dongji = {12, 22} },
    [2018] = { seollal = {2, 16}, daeboreum = {3, 2}, dano = {6, 18}, chuseok = {9, 24}, dongji = {12, 22} },
    [2019] = { seollal = {2, 5}, daeboreum = {2, 19}, dano = {6, 7}, chuseok = {9, 13}, dongji = {12, 22} },
    [2020] = { seollal = {1, 25}, daeboreum = {2, 8}, dano = {6, 25}, chuseok = {10, 1}, dongji = {12, 21} },
    [2021] = { seollal = {2, 12}, daeboreum = {2, 26}, dano = {6, 14}, chuseok = {9, 21}, dongji = {12, 22} },
    [2022] = { seollal = {2, 1}, daeboreum = {2, 15}, dano = {6, 3}, chuseok = {9, 10}, dongji = {12, 22} },
    [2023] = { seollal = {1, 22}, daeboreum = {2, 5}, dano = {6, 22}, chuseok = {9, 29}, dongji = {12, 22} },
    [2024] = { seollal = {2, 10}, daeboreum = {2, 24}, dano = {6, 10}, chuseok = {9, 17}, dongji = {12, 21} },
    [2025] = { seollal = {1, 29}, daeboreum = {2, 12}, dano = {5, 31}, chuseok = {10, 6}, dongji = {12, 22} },
    [2026] = { seollal = {2, 17}, daeboreum = {3, 3}, dano = {6, 19}, chuseok = {9, 25}, dongji = {12, 22} },
    [2027] = { seollal = {2, 7}, daeboreum = {2, 21}, dano = {6, 9}, chuseok = {9, 15}, dongji = {12, 22} },
    [2028] = { seollal = {1, 27}, daeboreum = {2, 10}, dano = {5, 28}, chuseok = {10, 3}, dongji = {12, 21} },
    [2029] = { seollal = {2, 13}, daeboreum = {2, 27}, dano = {6, 16}, chuseok = {9, 22}, dongji = {12, 21} },
    [2030] = { seollal = {2, 3}, daeboreum = {2, 17}, dano = {6, 5}, chuseok = {9, 12}, dongji = {12, 22} },
    [2031] = { seollal = {1, 23}, daeboreum = {2, 6}, dano = {6, 24}, chuseok = {10, 1}, dongji = {12, 22} },
    [2032] = { seollal = {2, 11}, daeboreum = {2, 25}, dano = {6, 12}, chuseok = {9, 19}, dongji = {12, 21} },
    [2033] = { seollal = {1, 31}, daeboreum = {2, 14}, dano = {6, 1}, chuseok = {10, 7}, dongji = {12, 21} },
    [2034] = { seollal = {1, 20}, daeboreum = {2, 3}, dano = {6, 20}, chuseok = {9, 27}, dongji = {12, 22} },
    [2035] = { seollal = {2, 8}, daeboreum = {2, 22}, dano = {6, 10}, chuseok = {9, 16}, dongji = {12, 22} },
}

function Holiday.enabled() return StoryEngine.option("Holidays", true) == true end

local function state()
    local d = Store.data()
    d.holiday = d.holiday or {}
    local s = d.holiday
    s.done = s.done or {}
    return s
end

-- 날짜 계산: 율리우스 일수 (정수)
local function jdn(y, m, d)
    local a = math.floor((14 - m) / 12)
    local yy = y + 4800 - a
    local mm = m + 12 * a - 3
    return d + math.floor((153 * mm + 2) / 5) + 365 * yy + math.floor(yy / 4) - math.floor(yy / 100)
        + math.floor(yy / 400) - 32045
end
Holiday.jdn = jdn

-- 11월 넷째 목요일
local function thanksgiving(y)
    local first = jdn(y, 11, 1)
    local wd = (first + 1) % 7            -- 0 = 일요일
    local offset = (4 - wd + 7) % 7       -- 첫 목요일까지
    return 1 + offset + 21
end

-- 그 해 이 명절의 날짜 { y, m, d } | nil (음력 표 밖)
function Holiday.dateOf(h, y)
    if h.date then return { y, h.date[1], h.date[2] } end
    if h.rule == "thanksgiving" then return { y, 11, thanksgiving(y) } end
    local row = Holiday.LUNAR[y]
    local md = row and row[h.lunar]
    return md and { y, md[1], md[2] } or nil
end

function Holiday.today()
    local gt = getGameTime()
    return gt:getYear(), gt:getMonth() + 1, gt:getDay() + 1, gt:getHour()
end

-- 이번 명절 목록: 한국어가 가장 많으면 한국 명절
function Holiday.set()
    local lang = StoryEngine.Broadcast and StoryEngine.Broadcast.language() or "EN"
    return lang == "KO" and Holiday.KO or Holiday.EN, lang == "KO" and "KO" or "EN"
end

-- 다가오는 명절: { h, key, days, date } 목록 (오늘 포함, ANNOUNCE_DAYS 안)
function Holiday.upcoming()
    local y, m, d = Holiday.today()
    local today = jdn(y, m, d)
    local set, setName = Holiday.set()
    local out = {}
    for _, h in ipairs(set) do
        for _, yy in ipairs({ y, y + 1 }) do
            local dt = Holiday.dateOf(h, yy)
            if dt then
                local diff = jdn(dt[1], dt[2], dt[3]) - today
                if diff >= 0 and diff <= Holiday.ANNOUNCE_DAYS then
                    out[#out + 1] = { h = h, key = setName .. "_" .. h.id .. "_" .. StoryEngine.intToString(dt[1]),
                                      days = diff, date = dt, set = setName }
                end
            end
        end
    end
    return out
end

local function alive(fid)
    if fid and Factions.byId[fid] and not Factions.isGone(fid) then return fid end
    for _, f in ipairs(Factions.list) do
        if not Factions.isGone(f.id) then return f.id end
    end
    return nil
end

local function nameKey(id) return "IGUI_StoryEngine_Holiday_" .. id end

local function livingPlayers()
    local out = {}
    for _, ps in pairs(Store.data().players) do
        if not ps.dead then out[#out + 1] = ps end
    end
    return out
end

-- 예고: 주관 NPC 무전, 소문, 명절 음식 모금
function Holiday.announce(u, now)
    local s = state()
    local inst = { id = u.h.id, set = u.set, host = alive(u.h.host), stage = "announced", date = u.date }
    s.done[u.key] = inst
    local players = Sensor.players()
    local about = Holiday.ABOUT[u.h.id] or u.h.id
    local korean = u.set == "KO" and u.h.id ~= "christmas" and u.h.id ~= "newyear"
    if inst.host then
        local _, _, _, hour = Holiday.today()
        local minutes = u.days * 24 * 60 + (Holiday.COLLECT_HOUR - hour) * 60
        if #players > 0 and minutes > 60 then
            local ps = Store.player(players[1])
            local q = Quests.createCollect(ps, u.h.need, now, { holiday = u.h.id, holidayKey = u.key, faction = inst.host },
                now.t + minutes)
            inst.collect = q and q.id or nil
        end
        Radio.react(inst.host, "event", about .. " is " .. (u.days == 0 and "today" or ("in " .. StoryEngine.intToString(u.days)
            .. " days")) .. "." .. (korean and " It is a Korean holiday one of the players told everyone about, and you want "
            .. "to celebrate it with them this year." or "") .. " Tell the players briefly, and ask them to send ingredients "
            .. "for the holiday meal (it is in their quest log).",
            StoryEngine.Lines.fallback(inst.host, "holiday_soon", about .. " is coming.", { { t = "key", v = nameKey(u.h.id) } }))
    end
    if StoryEngine.Social then StoryEngine.Social.news("all", "Everyone is getting ready for " .. about .. ".") end
    pcall(StoryEngine.Net.toAll, "holidayNotice", { id = u.h.id, days = u.days })
    log("holiday announced", u.key, "host", tostring(inst.host), "collect", tostring(inst.collect))
    return inst
end

local function giveFood(player, ps, fid, foods, extra, h, now)
    local items = {}
    for _ = 1, foods do items[#items + 1] = h.food end
    for _, ft in ipairs(extra or {}) do items[#items + 1] = ft end
    return Quests.create("supply_drop", player, ps, 1, now,
        { source = "holiday", faction = fid, holiday = h.id, friend = true }, items)
end

-- 당일: 잔치
function Holiday.celebrate(u, now)
    local s = state()
    local inst = s.done[u.key] or Holiday.announce(u, now)
    if inst.stage == "celebrated" then return end
    inst.stage = "celebrated"
    local q = inst.collect and Store.data().quests[inst.collect]
    local full = q ~= nil and q.state == "completed"
    if q and Quests.isActive(q) then
        q.cancelled = true
        Quests.setState(q, "declined", now, nil)
    end
    local Life = StoryEngine.Life
    for _, f in ipairs(Factions.list) do
        if Life and not Factions.isGone(f.id) then
            Life.change(f.id, "morale", full and 15 or 5, "holiday")
            if full then Life.change(f.id, "food", 5, "holiday") end
        end
    end
    if full and inst.host then
        for name, _ in pairs(q.givers or {}) do
            local ps = Store.findByName(name)
            StoryEngine.Trust.apply(inst.host, 1, "holiday_help", q.id, ps and ps.key or nil)
        end
    end
    -- 접속자마다 명절 음식, 가장 친한 NPC 의 작은 선물
    for _, p in ipairs(Sensor.players()) do
        local ps = Store.player(p)
        local friend, best = nil, Holiday.FRIEND_TRUST - 1
        for _, f in ipairs(Factions.list) do
            local t = Radio.channel(f.id).trust
            if not Factions.isGone(f.id) and t > best then friend, best = f.id, t end
        end
        local extra = friend and StoryEngine.Loot.roll(1, friend) or nil
        local okG, errG = pcall(giveFood, p, ps, friend or inst.host, full and Holiday.FEAST_FOOD or Holiday.PARTIAL_FOOD,
            extra, u.h, now)
        if not okG then log("holiday gift error:", errG) end
    end
    local about = Holiday.ABOUT[u.h.id] or u.h.id
    if inst.host then
        Radio.react(inst.host, "event", "Today is " .. about .. ". " .. (full and "Thanks to the players there is a real "
            .. "holiday meal for everyone." or "There was not enough for a proper meal, but you celebrate anyway.")
            .. " Wish them a good holiday, warmly and briefly; a little holiday food is on its way to them.",
            StoryEngine.Lines.fallback(inst.host, "holiday_feast", "Happy holidays.", { { t = "key", v = nameKey(u.h.id) } }))
    end
    if StoryEngine.Social then
        local other = nil
        for _, f in ipairs(Factions.list) do
            if f.id ~= inst.host and not Factions.isGone(f.id) and (not other or ZombRand(2) == 0) then other = f.id end
        end
        if inst.host and other then
            StoryEngine.Social.queueTopic({ inst.host, other }, "It is " .. about .. ". The contacts celebrate together on "
                .. "the open channel: what they ate, old memories of the holiday, wishing each other well.", "holiday",
                { t = "key", v = nameKey(u.h.id) })
            pcall(StoryEngine.Social.scene, nil)
        end
    end
    for _, ps in ipairs(livingPlayers()) do
        Store.addNote(ps, { kind = "holiday", holiday = u.h.id, faction = inst.host, full = full or nil, clock = now.clock })
    end
    log("holiday celebrated", u.key, full and "feast" or "small")
end

-- 매시간 (접속자가 있을 때)
function Holiday.hourly(now)
    if not Holiday.enabled() or #Sensor.players() == 0 then return end
    local s = state()
    local _, _, _, hour = Holiday.today()
    for _, u in ipairs(Holiday.upcoming()) do
        local inst = s.done[u.key]
        if not inst then inst = Holiday.announce(u, now) end
        if u.days == 0 and hour >= Holiday.FEAST_HOUR and inst.stage ~= "celebrated" then
            Holiday.celebrate(u, now)
        end
    end
end

-- 오늘이 세배(인사) 명절이면 { h, key }
function Holiday.greetToday()
    for _, u in ipairs(Holiday.upcoming()) do
        if u.days == 0 and u.h.greet then return u end
    end
    return nil
end

-- 플레이어가 NPC 에게 무전했다 (Radio.say). 그날 그 NPC 에게 처음이면 세뱃돈·명절 음식
function Holiday.onSay(player, ps, fid)
    if not Holiday.enabled() or not Factions.byId[fid] or Factions.isGone(fid) then return end
    local u = Holiday.greetToday()
    if not u then return end
    local s = state()
    s.greeted = s.greeted or {}
    local k = u.key .. "|" .. ps.key .. "|" .. fid
    if s.greeted[k] then return end
    s.greeted[k] = true
    local trust = Radio.channel(fid).trust
    local items = {}
    -- 케이시(16세)는 세뱃돈 대신 음식. 이어받은 노라는 어른이다 (점검 B7)
    if u.h.greet == "money" and (fid ~= "casey" or (Factions.voice and Factions.voice.casey)) then
        for _ = 1, math.max(1, math.min(5, 1 + math.floor(trust / 25))) do items[#items + 1] = "Base.Money" end
    else
        items[1] = u.h.food
    end
    local inv = player:getInventory()
    for _, ft in ipairs(items) do StoryEngine.Items.addTo(inv, ft, nil) end
    local now = Sensor.now()
    Radio.push(fid, { from = "system", clock = now.clock, holidayGift = { holiday = u.h.id, items = items,
                                                                           money = u.h.greet == "money" or nil } })
    if StoryEngine.Social then
        StoryEngine.Social.news(fid, "Today is " .. (Holiday.ABOUT[u.h.id] or u.h.id) .. ". " .. ps.name
            .. " called to wish you a good holiday" .. (u.h.greet == "money" and " (a New Year's bow)" or "")
            .. " and you gave them a small holiday gift.")
    end
    log("holiday greet", u.key, ps.name, fid, #items)
end

function Holiday.statusText()
    local s = state()
    local parts = {}
    for k, inst in pairs(s.done) do parts[#parts + 1] = k .. "=" .. tostring(inst.stage) end
    table.sort(parts)
    local y, m, d = Holiday.today()
    local _, setName = Holiday.set()
    return "holiday " .. setName .. " " .. StoryEngine.intToString(y) .. "-" .. StoryEngine.intToString(m) .. "-"
        .. StoryEngine.intToString(d) .. " " .. (#parts > 0 and table.concat(parts, " ") or "none")
end

Events.EveryHours.Add(function()
    local ok, err = pcall(Holiday.hourly, Sensor.now())
    if not ok then log("holiday hourly error:", err) end
end)

return Holiday
