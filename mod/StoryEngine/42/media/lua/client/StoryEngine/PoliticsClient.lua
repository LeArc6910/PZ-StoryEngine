-- 의회의 정치, 클라이언트 쪽 (서버 Politics.lua): 알림, 특별 법안 발의 결과, 공동 작업장에 물건 보내기.
-- 의회 탭의 글은 MainWindow.lua 의 StoryEnginePoliticsPanel 이 Politics.textOf 로 만든다.

if isServer() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Factions"
require "StoryEngine/UIUtil"
require "StoryEngine/Client"

local Net = StoryEngine.Net
local Factions = StoryEngine.Factions
local UI = StoryEngine.UI
local Client = StoryEngine.Client
local Cache = StoryEngine.Cache

local Politics = {}
StoryEngine.PoliticsClient = Politics

Politics.BILLS = { "workshop", "post", "armory", "exchange", "canteen", "truce", "purge", "apprentice",
                   "memorial", "winter", "vouch" }
Politics.WORKSHOP_CATS = { tools = true, melee = true, firearm = true }

local function num(n) return StoryEngine.intToString(math.floor((n or 0) + 0.5)) end

function Politics.billName(id)
    return getText("IGUI_StoryEngine_Bill_" .. tostring(id))
end

local function names(list)
    local out = {}
    for _, fid in ipairs(list or {}) do out[#out + 1] = UI.npcName(fid) end
    return table.concat(out, ", ")
end

local function hoursText(h)
    if (h or 0) >= 48 then return getText("IGUI_StoryEngine_Politics_Days", num(h / 24)) end
    return getText("IGUI_StoryEngine_Politics_Hours", num(h))
end

local function line(parts, text, rgb)
    parts[#parts + 1] = " <RGB:" .. (rgb or "0.9,0.9,0.9") .. "> " .. UI.escape(text) .. " <LINE> "
end

-- 의회 탭의 글 (서식 글). d = 서버 Politics.payload
function Politics.textOf(d)
    local parts = {}
    if not d then
        line(parts, getText("IGUI_StoryEngine_Politics_Loading"), "0.6,0.6,0.6")
        return table.concat(parts)
    end
    if d.off then
        line(parts, getText("IGUI_StoryEngine_Politics_Off"), "0.6,0.6,0.6")
        return table.concat(parts)
    end
    if not d.era then
        line(parts, getText("IGUI_StoryEngine_Politics_NoEra"), "0.6,0.6,0.6")
        return table.concat(parts)
    end
    if not d.on then
        line(parts, getText("IGUI_StoryEngine_Politics_OpenIn", num(d.openIn)), "0.85,0.8,0.6")
        return table.concat(parts)
    end
    -- 파벌
    line(parts, getText("IGUI_StoryEngine_Politics_Blocs"), "1,0.86,0.55")
    for _, b in ipairs(d.blocs or {}) do
        local lean = b.lean or 0
        local leanText = (lean > 0 and "+" or "") .. num(lean)
        line(parts, getText("IGUI_StoryEngine_Politics_BlocLine", getText("IGUI_StoryEngine_Politics_Bloc_" .. tostring(b.id)),
            names(b.members), leanText), lean >= 20 and "0.55,0.9,0.55" or (lean <= -20 and "0.95,0.5,0.4" or "0.9,0.9,0.9"))
    end
    if #(d.against or {}) > 0 then
        line(parts, getText("IGUI_StoryEngine_Politics_Against", names(d.against)), "0.95,0.6,0.4")
    end
    -- 의장과 선거
    local ch = d.chair
    if ch then
        local who = ch.player or UI.npcName(ch.fid)
        local tail = ch.player and getText("IGUI_StoryEngine_Politics_Chair_Player")
            or getText("IGUI_StoryEngine_Politics_Chair_" .. tostring(ch.bloc))
        line(parts, getText("IGUI_StoryEngine_Politics_Chair", who, num(ch.days)) .. "  " .. tail, "0.85,0.8,0.6")
    end
    -- 국면 (60일마다 다시 본다)
    if d.phase then
        local ph = d.phase
        if ph.kind == "rule" then
            line(parts, getText("IGUI_StoryEngine_Politics_Phase_rule", getText("IGUI_StoryEngine_Politics_Bloc_" .. tostring(ph.bloc)),
                num(ph.days)), "0.95,0.7,0.5")
            if #(ph.cold or {}) > 0 then
                line(parts, getText("IGUI_StoryEngine_Politics_Phase_cold", names(ph.cold)), "0.95,0.5,0.4")
            end
        else
            line(parts, getText("IGUI_StoryEngine_Politics_Phase_balance", num(ph.days)), "0.7,0.85,0.9")
        end
    elseif d.phaseIn then
        line(parts, getText("IGUI_StoryEngine_Politics_Phase_none", num(d.phaseIn)), "0.6,0.6,0.6")
    end
    -- 자리 셋 (창고지기·경비대장·방송 담당)
    local of = d.offices
    if of then
        for _, row in ipairs(of.list or {}) do
            local title = getText("IGUI_StoryEngine_Office_" .. tostring(row.id))
            if row.fid then
                local text = getText("IGUI_StoryEngine_Office_Held", title, UI.npcName(row.fid), num(row.days))
                if row.mood then text = text .. "  " .. getText("IGUI_StoryEngine_Office_" .. row.id .. "_" .. row.mood) end
                line(parts, text, row.mood == "warm" and "0.7,0.9,0.7" or (row.mood == "cold" and "0.95,0.6,0.45" or "0.85,0.8,0.6"))
            elseif not (of.vote and of.vote.office == row.id) then
                line(parts, getText("IGUI_StoryEngine_Office_Empty", title, num(row.voteIn)), "0.6,0.6,0.6")
            end
        end
        local v = of.vote
        if v then
            line(parts, getText("IGUI_StoryEngine_Office_Vote", getText("IGUI_StoryEngine_Office_" .. tostring(v.office)),
                hoursText(v.hours)), "1,0.86,0.55")
            for _, b in ipairs({ "field", "gun", "market" }) do
                local c = (v.cands or {})[b]
                if c then
                    local text = getText("IGUI_StoryEngine_Politics_Candidate", UI.npcName(c),
                        getText("IGUI_StoryEngine_Politics_Bloc_" .. b), num((v.votes or {})[b] or 0))
                    if v.backed == b then text = text .. "  [" .. getText("IGUI_StoryEngine_Politics_Backed", tostring(v.backedBy or "?")) .. "]" end
                    line(parts, text, v.winner == b and "0.75,0.95,0.75" or "0.9,0.9,0.9")
                end
            end
        end
    end
    if #(d.secrets or {}) > 0 then
        line(parts, getText("IGUI_StoryEngine_Politics_Secrets", names(d.secrets)), "0.85,0.7,0.9")
    end
    -- 큰 사건: 파벌의 제안
    local cr = d.crisis
    if cr then
        parts[#parts + 1] = " <LINE> "
        if cr.deal then
            line(parts, cr.deal == "none" and getText("IGUI_StoryEngine_Politics_Deal_Alone", tostring(cr.by or "?"))
                or getText("IGUI_StoryEngine_Politics_Deal_With", getText("IGUI_StoryEngine_Politics_Bloc_" .. tostring(cr.deal)),
                    tostring(cr.by or "?")), "0.75,0.95,0.75")
        elseif cr.open then
            line(parts, getText("IGUI_StoryEngine_Politics_Crisis", hoursText(cr.hours)), "1,0.6,0.4")
            for _, b in ipairs({ "field", "gun", "market" }) do
                local fid = (cr.offers or {})[b]
                if fid then
                    line(parts, getText("IGUI_StoryEngine_Politics_Offer_" .. b, UI.npcName(fid)))
                end
            end
        else
            line(parts, getText("IGUI_StoryEngine_Politics_Deal_Late"), "0.6,0.6,0.6")
        end
    end
    local el = d.election
    if el then
        parts[#parts + 1] = " <LINE> "
        line(parts, getText("IGUI_StoryEngine_Politics_Election", hoursText(el.hours)), "1,0.86,0.55")
        for _, b in ipairs({ "field", "gun", "market" }) do
            local c = (el.cands or {})[b]
            if c then
                local text = getText("IGUI_StoryEngine_Politics_Candidate", UI.npcName(c),
                    getText("IGUI_StoryEngine_Politics_Bloc_" .. b), num((el.votes or {})[b] or 0))
                if el.backed == b then text = text .. "  [" .. getText("IGUI_StoryEngine_Politics_Backed", tostring(el.backedBy or "?")) .. "]" end
                line(parts, text, el.winner == b and "0.75,0.95,0.75" or "0.9,0.9,0.9")
            end
        end
        if el.running then
            line(parts, getText("IGUI_StoryEngine_Politics_Running", tostring(el.running), num(el.player and el.player.got or 0),
                num(el.player and el.player.need or 0)), "0.7,0.8,0.9")
            local missing = {}
            for _, r in ipairs(el.rows or {}) do
                if not r.mine then missing[#missing + 1] = UI.npcName(r.fid) end
            end
            if #missing > 0 then line(parts, getText("IGUI_StoryEngine_Politics_Running_Missing", table.concat(missing, ", ")), "0.9,0.7,0.65") end
            for fid, over in pairs(el.spurned or {}) do
                line(parts, getText("IGUI_StoryEngine_Politics_Running_Spurned", UI.npcName(fid), UI.npcName(over)), "0.95,0.6,0.45")
            end
        end
    end
    parts[#parts + 1] = " <LINE> "
    -- 걸린 법안
    local bill = d.bill
    if bill then
        line(parts, getText("IGUI_StoryEngine_Politics_Bill", Politics.billName(bill.id)), "1,0.86,0.55")
        if bill.id == "vouch" then
            line(parts, getText("IGUI_StoryEngine_Politics_Vouch", UI.npcName(bill.guarantor), UI.npcName(bill.target)))
        elseif bill.system then
            line(parts, getText("IGUI_StoryEngine_Bill_" .. bill.id .. "_Desc", UI.npcName(bill.target)))
        else
            line(parts, getText("IGUI_StoryEngine_Bill_" .. bill.id .. "_Desc"))
        end
        local by = (bill.by == "player" or bill.by == "chair") and getText("IGUI_StoryEngine_Politics_ByPlayers", tostring(bill.who or "?"))
            or (bill.system and getText("IGUI_StoryEngine_Politics_ByCouncil"))
            or getText("IGUI_StoryEngine_Politics_By", UI.npcName(bill.by),
                getText("IGUI_StoryEngine_Politics_Bloc_" .. tostring(bill.bloc)))
        line(parts, by .. "  |  " .. getText("IGUI_StoryEngine_Politics_VoteIn", hoursText(bill.hours)), "0.7,0.8,0.9")
        if #(bill.gain or {}) > 0 then line(parts, getText("IGUI_StoryEngine_Politics_Gain", names(bill.gain)), "0.6,0.85,0.6") end
        if #(bill.lose or {}) > 0 then line(parts, getText("IGUI_StoryEngine_Politics_Lose", names(bill.lose)), "0.9,0.6,0.5") end
        line(parts, getText("IGUI_StoryEngine_Politics_Forecast", num(bill.yes), num(bill.no),
            getText(bill.pass and "IGUI_StoryEngine_Politics_Pass" or "IGUI_StoryEngine_Politics_Fail")),
            bill.pass and "0.55,0.9,0.55" or "0.95,0.5,0.4")
        if bill.two3 then line(parts, getText("IGUI_StoryEngine_Politics_Two3"), "0.95,0.7,0.5") end
        if bill.plea then line(parts, getText("IGUI_StoryEngine_Politics_Plea", UI.npcName(bill.plea)), "0.85,0.8,0.6") end
        for _, r in ipairs(bill.rows or {}) do
            local row = getText("IGUI_StoryEngine_Politics_Row", UI.npcName(r.fid),
                getText("IGUI_StoryEngine_Politics_Bloc_" .. tostring(r.bloc)), num(r.trust), num(r.need),
                getText(r.absent and "IGUI_StoryEngine_Politics_Absent"
                    or (r.yes and "IGUI_StoryEngine_Politics_Yes" or "IGUI_StoryEngine_Politics_No")))
            local moved = (bill.lobby or {})[r.fid]
            if moved then
                row = row .. "  [" .. getText("IGUI_StoryEngine_Politics_Lobbied_" .. tostring(moved.how), tostring(moved.who or "?")) .. "]"
            end
            line(parts, row, r.yes and "0.7,0.9,0.7" or "0.9,0.7,0.65")
        end
        line(parts, getText("IGUI_StoryEngine_Politics_LobbyLeft", num(bill.lobbyLeft or 0)), "0.7,0.8,0.9")
    else
        line(parts, getText("IGUI_StoryEngine_Politics_NextIn", num(d.nextIn)), "0.7,0.8,0.9")
    end
    parts[#parts + 1] = " <LINE> "
    -- 시행 중
    line(parts, getText("IGUI_StoryEngine_Politics_Laws"), "1,0.86,0.55")
    if #(d.laws or {}) == 0 then line(parts, getText("IGUI_StoryEngine_Politics_NoLaws"), "0.6,0.6,0.6") end
    for _, law in ipairs(d.laws or {}) do
        line(parts, Politics.billName(law.id) .. "  (" .. getText("IGUI_StoryEngine_Politics_Left", hoursText(law.hours)) .. ")",
            "0.75,0.95,0.75")
        if law.id == "vouch" then
            line(parts, getText("IGUI_StoryEngine_Politics_Vouch", UI.npcName(law.guarantor), UI.npcName(law.target)))
        else
            line(parts, getText("IGUI_StoryEngine_Bill_" .. law.id .. "_Desc"))
        end
        if law.share then line(parts, getText("IGUI_StoryEngine_Politics_Share", num(law.share)), "0.85,0.8,0.6") end
        if law.id == "workshop" and d.workshop then
            line(parts, (d.workshop.wait or 0) > 0 and getText("IGUI_StoryEngine_Politics_Workshop_Wait", num(d.workshop.wait))
                or getText("IGUI_StoryEngine_Politics_Workshop_Hint"), "0.7,0.8,0.9")
        end
    end
    -- 지난 표결
    if #(d.history or {}) > 0 then
        parts[#parts + 1] = " <LINE> "
        line(parts, getText("IGUI_StoryEngine_Politics_History"), "1,0.86,0.55")
        for _, h in ipairs(d.history) do
            line(parts, getText(h.pass and "IGUI_StoryEngine_Politics_Passed" or "IGUI_StoryEngine_Politics_Failed",
                Politics.billName(h.id), num(h.yes), num(h.no), num(h.day)), h.pass and "0.7,0.85,0.7" or "0.75,0.65,0.6")
        end
    end
    return table.concat(parts)
end

-- 선거·의장 메뉴의 줄: { { label, ok, tip, args } } (args 는 politicsElection 에 그대로 보낸다)
function Politics.electionRows(d)
    local rows = {}
    local cr = d and d.crisis
    if cr and cr.open then
        for _, b in ipairs({ "field", "gun", "market" }) do
            local fid = (cr.offers or {})[b]
            if fid then
                rows[#rows + 1] = { label = getText("IGUI_StoryEngine_Politics_Deal_Take", getText("IGUI_StoryEngine_Politics_Bloc_" .. b)),
                    ok = true, tip = getText("IGUI_StoryEngine_Politics_Offer_" .. b, UI.npcName(fid)), args = { what = "deal", bloc = b } }
            end
        end
        rows[#rows + 1] = { label = getText("IGUI_StoryEngine_Politics_Deal_None"), ok = true,
                            tip = getText("IGUI_StoryEngine_Politics_Deal_None_Tip"), args = { what = "deal", bloc = "none" } }
    end
    local el = d and d.election
    if el then
        local free = not el.backed and not el.running
        for _, b in ipairs({ "field", "gun", "market" }) do
            local c = (el.cands or {})[b]
            if c then
                rows[#rows + 1] = { label = getText("IGUI_StoryEngine_Politics_Back", UI.npcName(c)), ok = free,
                    tip = getText("IGUI_StoryEngine_Politics_Back_Tip") .. " <LINE> " .. getText("IGUI_StoryEngine_Politics_Chair_" .. b),
                    args = { what = "back", bloc = b } }
            end
        end
        local tip = getText("IGUI_StoryEngine_Politics_Run_Tip")
        if free and el.canRun == false and el.blocker then
            tip = getText("IGUI_StoryEngine_Politics_Run_Blocked", UI.npcName(el.blocker)) .. " <LINE> " .. tip
        end
        rows[#rows + 1] = { label = getText("IGUI_StoryEngine_Politics_Run"), ok = free and el.canRun == true, tip = tip,
                            args = { what = "run" } }
    end
    local ov = d and d.offices and d.offices.vote
    if ov then
        for _, b in ipairs({ "field", "gun", "market" }) do
            local c = (ov.cands or {})[b]
            if c then
                rows[#rows + 1] = { label = getText("IGUI_StoryEngine_Office_Back", getText("IGUI_StoryEngine_Office_" .. tostring(ov.office)),
                        UI.npcName(c)), ok = ov.backed == nil,
                    tip = getText("IGUI_StoryEngine_Office_Back_Tip") .. " <LINE> " .. getText("IGUI_StoryEngine_Office_" .. tostring(ov.office) .. "_Tip"),
                    args = { what = "office", bloc = b } }
            end
        end
    end
    local ch = d and d.chair
    if ch and ch.mine then
        for _, b in ipairs(ch.bills or {}) do
            rows[#rows + 1] = { label = getText("IGUI_StoryEngine_Politics_Choose", Politics.billName(b.id)), ok = b.ok == true,
                                tip = getText("IGUI_StoryEngine_Bill_" .. b.id .. "_Desc"), args = { what = "choose", id = b.id } }
        end
        if d.bill then
            for _, side in ipairs({ "for", "against" }) do
                rows[#rows + 1] = { label = getText("IGUI_StoryEngine_Politics_Cast_" .. side)
                    .. (d.bill.cast == side and (" " .. getText("IGUI_StoryEngine_Politics_Cast_Set")) or ""), ok = true,
                    tip = getText("IGUI_StoryEngine_Politics_Cast_Tip"), args = { what = "cast", side = side } }
            end
        end
    end
    return rows
end

-- 로비 메뉴의 줄: NPC 마다 { fid, label, done, persuade = { ok, tip }, promise = { ok, tip } }
Politics.PERSUADE_TRUST, Politics.PROMISE_TRUST = 60, 40
function Politics.lobbyRows(d)
    local rows = {}
    local bill = d and d.bill
    if not bill then return rows end
    local spent = (bill.lobbyLeft or 0) <= 0
    for _, r in ipairs(bill.rows or {}) do
        local done = (bill.lobby or {})[r.fid] ~= nil
        local function way(need, key)
            local ok = not spent and not done and (r.trust or 0) >= need
            local tip = getText("IGUI_StoryEngine_Politics_Lobby_" .. key .. "_Tip")
            if spent then tip = getText("IGUI_StoryEngine_Politics_Lobby_Error_spent") .. " <LINE> " .. tip
            elseif done then tip = getText("IGUI_StoryEngine_Politics_Lobby_Error_again") .. " <LINE> " .. tip
            elseif (r.trust or 0) < need then
                tip = getText("IGUI_StoryEngine_Politics_Lobby_Error_trust", num(need)) .. " <LINE> " .. tip
            end
            return { ok = ok, tip = tip }
        end
        local row = { fid = r.fid, label = UI.npcName(r.fid) .. "  (" .. getText(r.yes and "IGUI_StoryEngine_Politics_Yes"
            or "IGUI_StoryEngine_Politics_No") .. ")", done = done,
            persuade = way(Politics.PERSUADE_TRUST, "persuade"), promise = way(Politics.PROMISE_TRUST, "promise") }
        -- 압박: 약점을 쥐고 있을 때만 (신뢰도와 무관)
        local held = false
        for _, fid in ipairs(d.secrets or {}) do
            if fid == r.fid then held = true end
        end
        row.press = way(0, "press")
        if not held then
            row.press.ok = false
            row.press.tip = getText("IGUI_StoryEngine_Politics_Lobby_Error_no_secret") .. " <LINE> " .. getText("IGUI_StoryEngine_Politics_Lobby_press_Tip")
        end
        -- 몰아세움: 법안이 그 사람의 헌장 서명과 맞닿을 때만, 방향은 정해져 있다
        local side = (bill.calls or {})[r.fid]
        row.call = way(0, "call")
        row.call.side = side
        if not side then
            row.call.ok = false
            row.call.tip = getText("IGUI_StoryEngine_Politics_Lobby_Error_no_pledge") .. " <LINE> " .. getText("IGUI_StoryEngine_Politics_Lobby_call_Tip")
        end
        rows[#rows + 1] = row
    end
    return rows
end

-- 특별 법안 메뉴의 줄: { { id, label, ok, tip, target } }
function Politics.specialRows(d)
    local rows = {}
    for _, o in ipairs((d and d.specials) or {}) do
        local tip = getText("IGUI_StoryEngine_Bill_" .. o.id .. "_Desc")
        if not o.ok then
            tip = getText("IGUI_StoryEngine_Politics_Why_" .. tostring(o.why), num(o.wait)) .. " <LINE> " .. tip
        end
        rows[#rows + 1] = { id = o.id, label = Politics.billName(o.id), ok = o.ok == true, tip = tip, target = o.target }
    end
    return rows
end

local function refresh()
    local p = getPlayer()
    if p then Net.toServer(p, "politicsState", {}) end
end

function Client.handlers.politicsState(args)
    Cache.politics = args.politics or {}
    if StoryEngineMainWindow then StoryEngineMainWindow.refreshIfOpen("politics") end
end

-- 알림 문장 (화면 위 글). 반환: 문장, 좋은 소식인가
function Politics.noticeText(args)
    local kind = tostring(args.kind)
    if kind == "open" then return getText("IGUI_StoryEngine_Politics_Notice_open"), true end
    if kind == "phase" then
        if args.phase == "rule" then
            return getText("IGUI_StoryEngine_Politics_Notice_rule", getText("IGUI_StoryEngine_Politics_Bloc_" .. tostring(args.bloc))), false
        end
        return getText("IGUI_StoryEngine_Politics_Notice_balance"), true
    end
    if kind == "bill" then return getText("IGUI_StoryEngine_Politics_Notice_bill", Politics.billName(args.id)), true end
    if kind == "vote" then
        return getText(args.pass and "IGUI_StoryEngine_Politics_Notice_pass" or "IGUI_StoryEngine_Politics_Notice_fail",
            Politics.billName(args.id), num(args.yes), num(args.no)), args.pass == true
    end
    if kind == "ended" then
        return getText(args.why == "broken" and "IGUI_StoryEngine_Politics_Notice_broken" or "IGUI_StoryEngine_Politics_Notice_ended",
            Politics.billName(args.id)), args.why ~= "broken"
    end
    if kind == "crisis" then return getText("IGUI_StoryEngine_Politics_Notice_crisis"), true end
    if kind == "deal" then
        if args.bloc == "none" then return getText("IGUI_StoryEngine_Politics_Notice_deal_none", tostring(args.name)), true end
        return getText("IGUI_StoryEngine_Politics_Notice_deal", tostring(args.name),
            getText("IGUI_StoryEngine_Politics_Bloc_" .. tostring(args.bloc))), true
    end
    if kind == "settled" then
        return getText(args.good and "IGUI_StoryEngine_Politics_Notice_credit" or "IGUI_StoryEngine_Politics_Notice_blame",
            getText("IGUI_StoryEngine_Politics_Bloc_" .. tostring(args.bloc))), args.good == true
    end
    if kind == "election" then return getText("IGUI_StoryEngine_Politics_Notice_election"), true end
    if kind == "secret" then return getText("IGUI_StoryEngine_Politics_Notice_secret", UI.npcName(args.fid)), true end
    if kind == "moved" then
        return getText("IGUI_StoryEngine_Politics_Notice_moved", UI.npcName(args.fid),
            getText("IGUI_StoryEngine_Politics_Bloc_" .. tostring(args.to))), true
    end
    if kind == "plea" then return getText("IGUI_StoryEngine_Politics_Notice_plea", UI.npcName(args.fid)), true end
    if kind == "office_vote" then
        return getText("IGUI_StoryEngine_Office_Notice_vote", getText("IGUI_StoryEngine_Office_" .. tostring(args.office))), true
    end
    if kind == "office" then
        return getText("IGUI_StoryEngine_Office_Notice_chosen", UI.npcName(args.fid),
            getText("IGUI_StoryEngine_Office_" .. tostring(args.office))), true
    end
    if kind == "office_vacant" then
        return getText("IGUI_StoryEngine_Office_Notice_vacant", getText("IGUI_StoryEngine_Office_" .. tostring(args.office))), false
    end
    if kind == "run" then return getText("IGUI_StoryEngine_Politics_Notice_run", tostring(args.name)), true end
    if kind == "spurned" then
        return getText("IGUI_StoryEngine_Politics_Notice_spurned", UI.npcName(args.fid), UI.npcName(args.over)), false
    end
    if kind == "elected" then
        if args.player then return getText("IGUI_StoryEngine_Politics_Notice_elected_player", tostring(args.player)), true end
        if args.fid then
            return getText("IGUI_StoryEngine_Politics_Notice_elected", UI.npcName(args.fid)), args.ranFailed == nil
        end
        return nil, true
    end
    if kind == "impeached" then return getText("IGUI_StoryEngine_Politics_Notice_impeached", tostring(args.name)), false end
    if kind == "meal" then return getText("IGUI_StoryEngine_Politics_Notice_meal"), true end
    if kind == "post" then return getText("IGUI_StoryEngine_Politics_Notice_post", num(args.got), num(args.taken)), true end
    if kind == "workshop" then
        local ok, name = pcall(getItemNameFromFullType, args.item)
        return getText("IGUI_StoryEngine_Politics_Notice_workshop", ok and name or tostring(args.item)), true
    end
    if kind == "apprentice" then
        return getText("IGUI_StoryEngine_Politics_Notice_apprentice", UI.npcName(args.faction), num(args.xp)), true
    end
    if kind == "winter" then
        return getText(args.ready and "IGUI_StoryEngine_Politics_Notice_winter_ready" or "IGUI_StoryEngine_Politics_Notice_winter_short"),
            args.ready == true
    end
    return nil, true
end

function Client.handlers.politicsNotice(args)
    local player = getPlayer()
    if not player then return end
    local text, good = Politics.noticeText(args or {})
    if text then
        if good then HaloTextHelper.addGoodText(player, text) else HaloTextHelper.addBadText(player, text) end
    end
    refresh()
end

function Client.handlers.politicsResult(args)
    local player = getPlayer()
    if not player then return end
    if args.what == "workshop" then
        if args.ok then
            HaloTextHelper.addGoodText(player, getText("IGUI_StoryEngine_Workshop_Sent", num(args.hours)))
        else
            HaloTextHelper.addBadText(player, getText("IGUI_StoryEngine_Workshop_Error_" .. tostring(args.error), num(args.wait)))
        end
        refresh()
    elseif args.what == "back" or args.what == "run" or args.what == "choose" or args.what == "cast"
        or args.what == "deal" or args.what == "office" then
        if args.ok then
            HaloTextHelper.addGoodText(player, getText("IGUI_StoryEngine_Politics_Election_Done_" .. tostring(args.what)))
        else
            HaloTextHelper.addBadText(player, getText("IGUI_StoryEngine_Politics_Election_Error_" .. tostring(args.error),
                args.faction and UI.npcName(args.faction) or ""))
        end
    elseif args.what == "lobby" then
        if args.ok then
            HaloTextHelper.addGoodText(player, getText("IGUI_StoryEngine_Politics_Lobby_Done_" .. tostring(args.how),
                UI.npcName(args.faction)))
        else
            HaloTextHelper.addBadText(player, getText("IGUI_StoryEngine_Politics_Lobby_Error_" .. tostring(args.error),
                num(args.need)))
        end
    elseif not args.ok then
        HaloTextHelper.addBadText(player, getText("IGUI_StoryEngine_Politics_Why_" .. tostring(args.error), "0"))
    end
end

-- 공동 작업장에 보낼 수 있는 물건인가 (닳은 도구·근접 무기·총)
function Politics.workshopItem(item)
    if not item or not item.getFullType then return false end
    local Value = StoryEngine.Value
    local ok, cat = pcall(Value.categoryOf, item:getFullType())
    if not ok or not Politics.WORKSHOP_CATS[cat or ""] then return false end
    local okC, worn = pcall(function() return item:getConditionMax() > 0 and item:getCondition() < item:getConditionMax() end)
    return okC and worn == true
end

local function onFillInventory(playerNum, context, items)
    local d = Cache.politics
    if not (d and d.on and d.workshop) then return end
    local pick = nil
    for _, v in ipairs(items or {}) do
        local it = v
        if type(v) == "table" and v.items then it = v.items[1] end
        if Politics.workshopItem(it) then
            pick = it
            break
        end
    end
    if not pick then return end
    local option = context:addOption(getText("ContextMenu_StoryEngine_Workshop"), pick, function(item)
        local p = getSpecificPlayer(playerNum)
        if p then Net.toServer(p, "politicsWorkshop", { item = item:getID() }) end
    end)
    if (d.workshop.wait or 0) > 0 then
        option.notAvailable = true
        local tip = ISToolTip:new()
        tip:initialise()
        tip:setVisible(false)
        tip.description = getText("IGUI_StoryEngine_Politics_Workshop_Wait", num(d.workshop.wait))
        option.toolTip = tip
    end
end

Events.OnFillInventoryObjectContextMenu.Add(onFillInventory)

return Politics
