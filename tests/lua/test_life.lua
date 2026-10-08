-- NPC 생활 상태 1단계 (Life.lua 와 연결된 Quests·Trade·Needs·Social·Radio·Commands)
local T = {}

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "EN"
    local V = H.defineItem
    V("Base.TinnedBeans", "food", 1.5)
    V("Base.WaterRationCan", "food", 1.5)
    V("Base.Bandage", "medical", 3)
    V("Base.Pills", "medical", 3)
    V("Base.Antibiotics", "medical", 8)
    V("Base.Bullets9mmBox", "ammo", 15)
    V("Base.KitchenKnife", "melee", 5)
    V("Base.CigarettePack", "misc", 0.2)
    V("Base.Battery", "misc", 0.2)
    V("Base.Jacket", "misc", 0.2)
    V("Base.ElectronicsScrap", "misc", 0.2)
    return p, ps
end

local function trust(fid) return StoryEngine.Radio.channel(fid).trust end
local function res(fid, r) return StoryEngine.Life.npc(fid).res[r] end
local function lastRecord(fid)
    local log = StoryEngine.Life.npc(fid).log
    return log[#log]
end

function T.baseline_and_daily_drift()
    setup()
    local Life = StoryEngine.Life
    Life.daily()                                  -- 첫날: 기억만
    H.eq(res("ray", "food"), 45, "ray food baseline")
    Life.change("ray", "food", 20)                -- 65 (기준 45 위)
    Life.change("ray", "medical", -5)             -- 25 (기준 30 아래, 20 이상)
    Life.change("ray", "safety", -25)             -- 10 (20 미만)
    H.advanceDays(1)
    Life.daily()
    H.eq(res("ray", "food"), 60, "above base drifts down 5")
    H.eq(res("ray", "medical"), 30, "below base drifts up, capped at base")
    H.eq(res("ray", "safety"), 10, "under 20 does not recover")
    H.eq(Life.npc("ray").prev.food, 65, "prev keeps yesterday")
    Life.daily()                                  -- 같은 날 두 번째: 변화 없음
    H.eq(res("ray", "food"), 60, "once per day")
    H.eq(Life.change("ray", "morale", 200), 40, "clamped to 100")
end

function T.donate_values_trust_spill_and_cooldown()
    local p, ps = setup()
    local Life = StoryEngine.Life
    local ids = {}
    for _ = 1, 4 do ids[#ids + 1] = H.give(p, "Base.TinnedBeans"):getID() end
    for _ = 1, 2 do ids[#ids + 1] = H.give(p, "Base.Bandage"):getID() end
    ids[#ids + 1] = H.give(p, "Base.Bullets9mmBox"):getID()
    ids[#ids + 1] = H.give(p, "Base.CigarettePack"):getID()
    local held = H.give(p, "Base.KitchenKnife", { held = true })
    StoryEngine.Store.data().quests.Q1 = { id = "Q1", kind = "supply_drop", state = "offered" }   -- 진행 중인 퀘스트
    local tagged = H.give(p, "Base.Bandage", { questTag = "Q1" })
    local rotten = H.give(p, "Base.TinnedBeans", { classes = { "Food" }, rotten = true })
    H.give(p, "Base.Jacket", { worn = true })
    H.eq(#StoryEngine.Value.donatableItems(p), 8, "held, quest, rotten, worn and misc items are not offered")

    -- 보낼 수 없는 것도 섞어 보낸다 (서버가 걸러야 한다)
    ids[#ids + 1] = held:getID()
    ids[#ids + 1] = tagged:getID()
    ids[#ids + 1] = rotten:getID()
    local ok, info = Life.donate(p, "ray", ids)
    H.ok(ok, "donate ok: " .. tostring(info))
    -- 식량 6 -> +12, 의약품 6 -> +12, 안전 15 -> +30, 사기(담배 2) -> +4, 합계 29 -> 신뢰도 +2
    H.eq(res("ray", "food"), 57)
    H.eq(res("ray", "medical"), 42)
    H.eq(res("ray", "safety"), 65)
    H.eq(res("ray", "morale"), 64)
    H.eq(info.trust, 2, "trust gain")
    H.eq(trust("ray"), 32)
    H.eq(#p.items, 4, "only donated items removed (knife, quest bandage, rotten beans, jacket stay)")
    local rec = lastRecord("ray")
    H.eq(rec.kind, "donation")
    H.eq(rec.who, "Gerald Kar")
    H.eq(rec.d, 2)
    H.eq(Life.npc("ray").counts.medical_help, 1)
    -- 감사 무전 (AI) 과 일지 메모
    local b = H.lastBridge("radio", "event")
    H.ok(b and string.find(b.payload.topic, "Gerald Kar", 1, true), "thank-you radio request")
    H.ok(b.payload.life and b.payload.life.state.food == 57, "life context in radio payload")
    H.eq(ps.notes[#ps.notes].kind, "donation")
    -- 관계 파급: 레이를 좋아하는 케이시·파이크·듀이 +1
    H.eq(trust("casey"), 31)
    H.eq(trust("pike"), 21)
    H.eq(trust("dewey"), 16)
    H.eq(lastRecord("casey").kind, "spill_up")
    H.eq(lastRecord("casey").src, "ray")
    -- 3일 통 (2026-10-08): 같은 기간에 남은 한도까지 더 나눠 낸다. 안전은 +30 을 받아 10 남음
    local ok2, info2 = Life.donate(p, "ray", { H.give(p, "Base.Bullets9mmBox"):getID(), H.give(p, "Base.Bullets9mmBox"):getID() })
    H.ok(ok2)
    H.eq(info2.gains.safety, 10, "only the rest of the +40 safety limit")
    H.eq(info2.trust, 1, "value 29 + 15 crosses the 30 step")
    H.eq(#p.items, 5, "the second ammo box is not taken: safety is full for this period")
    for _ = 1, 4 do H.give(p, "Base.Bandage") end
    local fill = {}
    for _ = 1, 40 do fill[#fill + 1] = H.give(p, "Base.TinnedBeans"):getID() end
    H.ok(Life.donate(p, "ray", fill), "fill food")
    local m = {}
    for _ = 1, 20 do m[#m + 1] = H.give(p, "Base.Bandage"):getID() end
    H.ok(Life.donate(p, "ray", m), "fill medicine")
    local c = {}
    for _ = 1, 30 do c[#c + 1] = H.give(p, "Base.CigarettePack"):getID() end
    H.ok(Life.donate(p, "ray", c), "fill comforts")
    local ok3, why, wait = Life.donate(p, "ray", { H.give(p, "Base.Bandage"):getID() })
    H.eq(ok3, false)
    H.eq(why, "cooldown", "every resource is full for this period")
    H.eq(wait, 72)
    H.advanceDays(3)
    H.ok(Life.donate(p, "ray", { H.give(p, "Base.Bandage"):getID() }), "allowed in a new period")
end

function T.donate_small_gift_no_trust_no_spill()
    local p = setup()
    local Life = StoryEngine.Life
    local ok, info = Life.donate(p, "doc", { H.give(p, "Base.TinnedBeans"):getID() })
    H.ok(ok)
    H.eq(info.trust, 0, "value 1.5 < 5 gives no trust")
    H.eq(trust("casey"), 30, "no spill")
    local ok2, why = Life.donate(p, "doc", { H.give(p, "Base.Jacket"):getID() })
    H.eq(ok2, false)
end

function T.nothing_donatable()
    local p = setup()
    local ok, why = StoryEngine.Life.donate(p, "ray", { H.give(p, "Base.KitchenKnife", { held = true }):getID() })
    H.eq(ok, false)
    H.eq(why, "nothing")
end

function T.spill_rats_hidden_known_and_weekly_cap()
    setup()
    local Life = StoryEngine.Life
    H.rolls = { 50 }                        -- 30 이상: 몰래 (아무도 모름)
    Life.spill("rats", "Gerald Kar")
    H.eq(trust("ray"), 30, "hidden deal")
    H.ok(H.logHas("life spill hidden"))
    H.rolls = { 10 }                        -- 알려짐
    Life.spill("rats", "Gerald Kar")
    H.eq(trust("ray"), 29, "ray dislikes rats")
    H.eq(trust("doc"), 24, "doc dislikes rats")
    H.eq(trust("pike"), 20, "pike at floor 20 is not lowered")
    H.eq(trust("dewey"), 15, "dewey under floor")
    H.eq(Life.npc("ray").counts.rats_known, 1)
    H.rolls = { 10 }
    Life.spill("rats", "Gerald Kar")
    H.eq(trust("ray"), 28)
    H.rolls = { 10 }
    Life.spill("rats", "Gerald Kar")
    H.eq(trust("ray"), 28, "weekly cap -2")
    H.eq(Life.npc("ray").counts.rats_known, 3)
    local tags = Life.tags("ray")
    local found = false
    for _, t in ipairs(tags) do if t == "vic_friend" then found = true end end
    H.ok(found, "ray tags them as Vic's friends")
    local rtags = Life.tags("rats")
    for _, t in ipairs(rtags) do H.ok(t ~= "vic_friend", "rats never use that tag") end
    H.advanceDays(7)
    H.rolls = { 10 }
    Life.spill("rats", "Gerald Kar")
    H.eq(trust("ray"), 27, "cap resets after a week")
end

function T.quest_outcomes_resources_records_tags()
    setup()
    local Life = StoryEngine.Life
    local q = { id = "Q9", kind = "deliver", tier = 3, need = { { "Base.Antibiotics", 1 } },
                origin = { faction = "doc", initiator = "npc" }, targetName = "Gerald Kar" }
    Life.onQuest(q, "completed", 3)
    H.eq(res("doc", "medical"), 85, "tier 3 completion +30 to medical")
    H.eq(lastRecord("doc").kind, "quest_completed")
    H.eq(lastRecord("doc").d, 3)
    H.eq(trust("casey"), 31, "big job spills to casey")
    H.eq(trust("pike"), 21, "and pike")
    for i = 1, 3 do
        Life.onQuest({ id = "Q1" .. i, kind = "deliver", tier = 1, need = { { "Base.TinnedBeans", 3 } },
                       origin = { faction = "ray", initiator = "npc" }, targetName = "Gerald Kar" }, "failed", -2)
    end
    H.eq(res("ray", "food"), 15, "three failures -10 food each")
    H.eq(res("ray", "morale"), 45, "and -5 morale each")
    local tags = Life.tags("ray")
    H.eq(tags[1], "unreliable")
    -- 거래 성사: 대가 품목 자원 +10
    Life.onQuest({ id = "Q20", kind = "trade", tier = 1, payCategory = "medical", origin = { faction = "hunter" },
                   targetName = "Gerald Kar" }, "completed", 1)
    H.eq(res("hunter", "medical"), 35)
    H.eq(lastRecord("hunter").kind, "trade_done")
end

function T.quest_flow_through_quests_module()
    local p, ps = setup()
    local Quests = StoryEngine.Quests
    local q = Quests.propose(p, ps, "ray", 1, StoryEngine.Sensor.now())
    H.ok(q, "proposed")
    H.ok(H.lastBridge("radio", "request"), "request radio sent")
    H.ok(Quests.respond(p, q.id, false))
    local rec = lastRecord("ray")
    H.eq(rec.kind, "quest_declined")
    H.eq(rec.d, -1, "early-stage decline penalty recorded")
    H.eq(trust("ray"), 29)
end

function T.trade_scarcity_and_price()
    local p, ps = setup()
    local Life, Trade = StoryEngine.Life, StoryEngine.Trade
    SandboxVars.StoryEngine.ModItemsRatio = 0       -- 재고를 채울 때 다른 모드 아이템 섞기는 가짜 환경에서 못 돌린다
    Trade.JITTER = {}                               -- 값 계산을 보려고 재고 개수 흔들기는 끈다
    Life.npc("ray").res.food = 10
    local ctx = Trade.context("ray", ps)
    H.ok(ctx.allowed, "ray trades at trust 30")
    for _, g in ipairs(ctx.goods) do H.ok(g.category ~= "food", "no food when out of it") end
    local foodCat
    for _, c in ipairs(ctx.catalog) do if c.category == "food" then foodCat = c end end
    H.ok(foodCat.empty, "food marked empty")
    H.near(ctx.catMult.medical, 1.3, 0.001, "medical 30 is short")
    local q, how, info = Trade.fromReply("ray", ps, { action = "offer", category = "food", tier = 1, pay_category = "food" })
    H.eq(q, nil, "food offer refused")
    H.eq(info, nil, "no misleading trust line")
    local deal = Trade.fromReply("ray", ps, { action = "offer", category = "medical", tier = 1, pay_category = "food" })
    H.ok(deal, "medical offer made")
    -- 묶음 가치 x 신뢰 20~39 배율 2.0 x 부족 1.3 (묶음은 실시간으로 만들어진다)
    H.eq(deal.price, math.ceil(StoryEngine.Value.sum(deal.goods) * 2.0 * 1.3))
end

function T.needs_prefer_lowest_resource()
    setup()
    local Life = StoryEngine.Life
    Life.npc("doc").res.food = 10
    H.eq(Life.needPrefer("doc"), "food")
    for _ = 1, 10 do
        local n = StoryEngine.Needs.pick("doc", 1, "food")
        H.eq(n.items[1][1], "Base.TinnedBeans", "doc asks for food when out of it")
    end
    Life.npc("doc").res.food = 50
    H.eq(Life.needPrefer("doc"), "safety", "doc baseline safety 30 is short")
    Life.npc("doc").res.safety = 50
    H.eq(Life.needPrefer("doc"), nil, "nothing short, no preference")
end

function T.crisis_story_storm_hooks()
    local p, ps = setup()
    local Life = StoryEngine.Life
    local c = StoryEngine.Stories.crisis("fever")
    Life.onCrisis({ options = c.options }, "doc", "Gerald Kar")
    H.eq(res("doc", "medical"), 75)
    H.eq(res("doc", "morale"), 55)
    H.eq(res("pike", "medical"), 10, "pike snubbed")
    H.eq(res("guard", "medical"), 0, "guard snubbed, clamped")
    local plog = StoryEngine.Life.npc("pike").log
    H.eq(plog[#plog].kind, "crisis_snubbed", "pike snubbed record (crisis parties get no extra spillover)")
    H.eq(trust("casey"), 31, "crisis choice always known: casey likes doc")
    StoryEngine.Social.moveTo("ray", "ray_4b", StoryEngine.Sensor.now())
    H.eq(res("ray", "morale"), 45, "unhappy beat -15")
    StoryEngine.Social.onStorm()
    H.eq(res("ray", "morale"), 40, "storm -5")
    H.eq(res("hunter", "morale"), 45)
end

function T.radio_reply_insult_record_and_context()
    local p, ps = setup()
    StoryEngine.Radio.say(p, "doc", "you useless nurse")
    local b = H.lastBridge("radio")
    H.ok(b, "radio request sent")
    H.ok(b.payload.life and b.payload.life.state.medical == 55, "life state in payload")
    b.callback({ ok = true, json = { reply = "Watch your mouth.", trust_change = -1, follow_up_hours = 0,
                                     follow_up_topic = "", trade = { action = "none" } } })
    local rec = lastRecord("doc")
    H.eq(rec.kind, "insult")
    H.eq(rec.d, -1)
end

function T.commands_list_and_donate_roundtrip()
    local p = setup()
    local C = StoryEngine.Commands
    C.lifeList(p, {})
    local lists = H.sentOf("lifeList")
    H.eq(#lists, 1)
    local npcs = lists[1].npcs
    H.eq(#npcs, 8)
    local ray
    for _, n in ipairs(npcs) do if n.id == "ray" then ray = n end end
    H.eq(ray.key, "food")
    H.eq(ray.likes[1], "casey")
    H.eq(ray.dislikes[1], "rats")
    C.lifeDonate(p, { faction = "ray", items = { H.give(p, "Base.Bandage"):getID() } })
    local res1 = H.sentOf("lifeDonateResult")
    H.ok(res1[1].ok, "donate result ok")
    H.eq(res1[1].gains.medical, 6)
    C.lifeDonate(p, { faction = "ray", items = { H.give(p, "Base.Bandage"):getID() } })
    res1 = H.sentOf("lifeDonateResult")
    H.ok(res1[2].ok, "a second part in the same period")
    lists = H.sentOf("lifeList")
    for _, n in ipairs(lists[#lists].npcs) do if n.id == "ray" then ray = n end end
    H.eq(ray.donate.res.medical, 28, "40 - 6 - 6 left")
    H.eq(ray.donate.hours, 72)
    H.eq(ray.donateWait, 0)
    C.debugLife(p, { faction = "ray", set = 0 })
    H.eq(res("ray", "morale"), 0)
    C.debugLife(p, { faction = "ray", set = "base" })
    H.eq(res("ray", "morale"), 60)
end

return T
