-- 정치 위기, 클라이언트 쪽 (서버 Crises.lua): 의회 탭의 글, 선택 메뉴, 배분 창.

if isServer() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Factions"
require "StoryEngine/UIUtil"
require "StoryEngine/Client"

local Net = StoryEngine.Net
local UI = StoryEngine.UI
local Client = StoryEngine.Client

local CC = {}
StoryEngine.CrisesClient = CC

CC.NOTICES = { open = true, split = true, split_mended = true, split_over = true, transformer_done = true, night = true,
               transformer_site = true,
               night_over = true, ration_done = true, refugees_done = true, quarantine_open = true, quarantine_seal = true,
               boat_hold = true, boat_let = true, boat_back = true, tribunal_testify = true, tribunal_hide = true,
               tribunal_refused = true }
CC.GOOD = { split_mended = true, split_over = true, transformer_done = true, night_over = true, boat_back = true,
            tribunal_refused = true }
CC.ERRORS = { no_crisis = true, waiting = true, how = true, bad_share = true, bad_total = true, no_ask = true, bill_busy = true,
              inquiry = true, no_case = true, no_witness = true, asked = true, silent = true, nothing = true, no_proof = true,
              few_clues = true, no_probe = true, no_radio = true }
CC.INQ_NOTICES = { clue = true, refuted = true, verdict = true, lapsed = true, reveal = true, exposed = true, hinted = true,
                   held = true, probe = true, probe_over = true }

local function num(n) return StoryEngine.intToString(math.floor((n or 0) + 0.5)) end

local function line(parts, text, rgb)
    parts[#parts + 1] = " <RGB:" .. (rgb or "0.9,0.9,0.9") .. "> " .. UI.escape(text) .. " <LINE> "
end

-- 위기의 설명에 넣을 이름 (격리: 앓는 거점, 재판: 죽인 쪽·죽은 쪽)
local function subject(c)
    if c.sick then return UI.npcName(c.sick) end
    if c.case and c.case.accused then return UI.npcName(c.case.accused), UI.npcName(c.case.victim) end
    return ""
end

-- 조사의 답 이름: NPC 면 그 이름, 아니면 번역 문장
function CC.answerName(id)
    if StoryEngine.Factions.byId[id] then return UI.npcName(id) end
    return getText("IGUI_StoryEngine_Inq_Answer_" .. tostring(id))
end

-- 수사 수첩: 찾은 단서를 사실 문장으로만
function CC.caseLines(parts, case)
    line(parts, getText("IGUI_StoryEngine_Inq_Count", num(case.found), num(case.need)), "0.7,0.8,0.9")
    local names = {}
    for _, a in ipairs(case.answers or {}) do names[#names + 1] = CC.answerName(a) end
    line(parts, getText("IGUI_StoryEngine_Inq_Answers", table.concat(names, " / ")), "0.8,0.8,0.8")
    for _, c in ipairs(case.clues or {}) do
        local mode = c.clears and "clears" or "points"
        local who = CC.answerName(c.clears or c.points)
        local text
        if c.kind == "word" then
            text = getText("IGUI_StoryEngine_Inq_Clue_word_" .. mode, UI.npcName(c.fid), who)
            if c.refuted then text = getText("IGUI_StoryEngine_Inq_Clue_word_refuted", UI.npcName(c.fid), who) end
        else
            -- 위기마다 다른 단서 문장 (없으면 공통 문장)
            local own = "IGUI_StoryEngine_Inq_" .. tostring(case.kind) .. "_" .. tostring(c.n)
            if UI.hasText(own) then
                text = getText(own, who)
            else
                text = getText("IGUI_StoryEngine_Inq_Clue_" .. c.kind .. "_" .. mode, who)
            end
        end
        line(parts, "- " .. text, "0.9,0.88,0.8")
    end
end

-- 의회 탭에 덧붙이는 글. e = 서버 Crises.payload
function CC.textOf(e)
    if not e then return "" end
    local parts = {}
    local c = e.current
    if c then
        parts[#parts + 1] = " <LINE> "
        line(parts, getText("IGUI_StoryEngine_Crisis2_Head", getText("IGUI_StoryEngine_Crisis2_" .. c.id), num(c.hours)), "1,0.6,0.4")
        line(parts, getText("IGUI_StoryEngine_Crisis2_" .. c.id .. "_Desc", subject(c)))
        if c.case then
            CC.caseLines(parts, c.case)
        elseif c.waiting then
            line(parts, getText(c.vote and "IGUI_StoryEngine_Crisis2_WaitVote" or "IGUI_StoryEngine_Crisis2_WaitAsks"), "0.7,0.8,0.9")
        elseif c.allot then
            line(parts, getText("IGUI_StoryEngine_Crisis2_AllotHint"), "0.7,0.8,0.9")
        elseif c.site then
            line(parts, getText("IGUI_StoryEngine_Crisis2_SiteHint"), "0.7,0.8,0.9")
        elseif c.collect then
            line(parts, getText("IGUI_StoryEngine_Crisis2_CollectHint"), "0.7,0.8,0.9")
        end
    end
    local pr = e.probe
    if pr then
        parts[#parts + 1] = " <LINE> "
        line(parts, getText("IGUI_StoryEngine_Inq_Probe", num(pr.days), num(pr.hints), num(pr.max)), "0.95,0.7,0.5")
        if pr.open then
            line(parts, getText("IGUI_StoryEngine_Inq_Probe_Open", UI.npcName(pr.open.fid), num(pr.open.hours)), "1,0.6,0.4")
        end
    end
    if #(e.fx or {}) > 0 then
        parts[#parts + 1] = " <LINE> "
        for _, f in ipairs(e.fx) do
            local text
            if f.id == "split" then
                text = getText("IGUI_StoryEngine_Crisis2_Fx_split", num(f.days),
                    f.hold and getText("IGUI_StoryEngine_Crisis2_Hold_" .. tostring(f.hold)) or "")
            elseif f.id == "route" then
                text = getText("IGUI_StoryEngine_Crisis2_Fx_route")
            else
                text = getText("IGUI_StoryEngine_Crisis2_Fx_" .. tostring(f.id), num(f.days))
            end
            line(parts, text, "0.9,0.75,0.6")
        end
    end
    return table.concat(parts)
end

-- 선택 메뉴의 줄. 반환: { { label, tip, ok, option | allot } }
function CC.rows(e)
    local rows = {}
    -- 유도신문에 메뉴로 하는 대답 (AI 가 없어도 된다)
    local pr = e and e.probe
    if pr and pr.open then
        for _, choice in ipairs({ "safe", "vague", "frank" }) do
            rows[#rows + 1] = { label = getText("IGUI_StoryEngine_Inq_Reply_" .. choice, UI.npcName(pr.open.fid)), ok = true,
                                tip = getText("IGUI_StoryEngine_Inq_Reply_" .. choice .. "_Tip"),
                                inquiry = { what = "answer", choice = choice } }
        end
    end
    local c = e and e.current
    if not c or c.waiting then return rows end
    if c.case then
        local case = c.case
        for _, w in ipairs(case.words or {}) do
            if w.state == "ask" or w.state == "silent" then
                rows[#rows + 1] = { label = getText("IGUI_StoryEngine_Inq_Ask", UI.npcName(w.fid)), ok = w.state == "ask",
                                    tip = getText(w.state == "ask" and "IGUI_StoryEngine_Inq_Ask_Tip" or "IGUI_StoryEngine_Inq_Silent_Tip"),
                                    inquiry = { what = "ask", fid = w.fid } }
            elseif w.state == "confront" then
                rows[#rows + 1] = { label = getText("IGUI_StoryEngine_Inq_Confront", UI.npcName(w.fid)), ok = true,
                                    tip = getText("IGUI_StoryEngine_Inq_Confront_Tip"), inquiry = { what = "confront", fid = w.fid } }
            end
        end
        for _, a in ipairs(case.answers or {}) do
            if case.hows then
                for _, how in ipairs(case.hows) do
                    rows[#rows + 1] = { label = getText("IGUI_StoryEngine_Inq_Judge_How", CC.answerName(a),
                                            getText("IGUI_StoryEngine_Inq_How_" .. how)), ok = case.canJudge == true,
                                        tip = getText("IGUI_StoryEngine_Inq_How_" .. how .. "_Tip"),
                                        inquiry = { what = "judge", answer = a, how = how } }
                end
            else
                rows[#rows + 1] = { label = getText("IGUI_StoryEngine_Inq_Judge", CC.answerName(a)), ok = case.canJudge == true,
                                    tip = getText("IGUI_StoryEngine_Inq_Judge_" .. tostring(case.kind) .. "_Tip"),
                                    inquiry = { what = "judge", answer = a } }
            end
        end
        return rows
    end
    if c.allot then
        rows[1] = { label = getText("IGUI_StoryEngine_Crisis2_AllotOpen", getText("IGUI_StoryEngine_Crisis2_" .. c.id)),
                    tip = getText("IGUI_StoryEngine_Crisis2_" .. c.id .. "_AllotTip"), ok = true, allot = c }
        return rows
    end
    for _, opt in ipairs(c.options or {}) do
        rows[#rows + 1] = { label = getText("IGUI_StoryEngine_Crisis2_" .. c.id .. "_" .. opt, subject(c)),
                            tip = getText("IGUI_StoryEngine_Crisis2_" .. c.id .. "_" .. opt .. "_Tip"), ok = true, option = opt }
    end
    return rows
end

function CC.act(row)
    local p = getPlayer()
    if not p or not row then return end
    if row.inquiry then
        Net.toServer(p, "inquiryAct", row.inquiry)
    elseif row.allot then
        if StoryEngineAllotWindow then StoryEngineAllotWindow.open(row.allot) end
    else
        Net.toServer(p, "crisisChoose", { option = row.option })
    end
end

function CC.noticeText(args)
    local kind = tostring(args.kind)
    if not CC.NOTICES[kind] then return nil end
    if kind == "open" then return getText("IGUI_StoryEngine_Crisis2_Notice_open", getText("IGUI_StoryEngine_Crisis2_" .. tostring(args.id))), false end
    if kind == "refugees_done" then return getText("IGUI_StoryEngine_Crisis2_Notice_refugees_done", num(args.taken), num(args.away)), (args.taken or 0) > 0 end
    if kind == "quarantine_open" or kind == "quarantine_seal" then
        return getText("IGUI_StoryEngine_Crisis2_Notice_" .. kind, UI.npcName(args.sick)), false
    end
    return getText("IGUI_StoryEngine_Crisis2_Notice_" .. kind, num(args.days)), CC.GOOD[kind] == true
end

function Client.handlers.crisisNotice(args)
    local p = getPlayer()
    if not p then return end
    local text, good = CC.noticeText(args or {})
    if text then
        if good then HaloTextHelper.addGoodText(p, text) else HaloTextHelper.addBadText(p, text) end
    end
    Net.toServer(p, "politicsState", {})
end

function CC.inquiryText(args)
    local kind = tostring(args.kind)
    if not CC.INQ_NOTICES[kind] then return nil end
    if kind == "clue" then return getText("IGUI_StoryEngine_Inq_Notice_clue", num(args.found)), true end
    if kind == "refuted" then return getText("IGUI_StoryEngine_Inq_Notice_refuted", UI.npcName(args.fid)), true end
    if kind == "probe" or kind == "hinted" or kind == "held" then
        return getText("IGUI_StoryEngine_Inq_Notice_" .. kind, args.fid and UI.npcName(args.fid) or ""), kind == "held"
    end
    if kind == "exposed" then
        local text = getText("IGUI_StoryEngine_Inq_Notice_exposed")
        if args.quote and args.quote ~= "" then text = text .. " " .. getText("IGUI_StoryEngine_Inq_Notice_quote", tostring(args.quote)) end
        return text, false
    end
    return getText("IGUI_StoryEngine_Inq_Notice_" .. kind), kind == "verdict" or kind == "probe_over"
end

function Client.handlers.inquiryNotice(args)
    local p = getPlayer()
    if not p then return end
    local text, good = CC.inquiryText(args or {})
    if text then
        if good then HaloTextHelper.addGoodText(p, text) else HaloTextHelper.addBadText(p, text) end
    end
    Net.toServer(p, "politicsState", {})
end

function Client.handlers.crisisResult(args)
    local p = getPlayer()
    if not p or args.ok then return end
    local err = tostring(args.error)
    HaloTextHelper.addBadText(p, CC.ERRORS[err] and getText("IGUI_StoryEngine_Crisis2_Error_" .. err) or err)
end

-- ---------------------------------------------------------------- 배분 계산 (창과 테스트가 함께 쓴다)

-- 몫을 한 칸 올리거나 내린다. 반환: 바뀌었는가
function CC.bump(allot, shares, fid, dir)
    local cur = shares[fid] or 0
    local used = 0
    for _, n in pairs(shares) do used = used + n end
    local nextV = cur + dir * allot.step
    if nextV < 0 or nextV > allot.max then return false end
    if dir > 0 and used + allot.step > allot.total then return false end
    shares[fid] = nextV
    return true
end

function CC.left(allot, shares)
    local used = 0
    for _, n in pairs(shares) do used = used + n end
    return allot.total - used
end

-- 보낼 수 있는가: 배급은 남김없이, 난민은 남겨도 된다 (남은 사람은 돌려보낸다)
function CC.canSend(allot, shares)
    local left = CC.left(allot, shares)
    if allot.partial then return left >= 0 end
    return left == 0
end

-- 고르게 나눈다 (한 칸씩 돌아가며)
function CC.even(allot)
    local shares = {}
    local n = #allot.rows
    if n == 0 then return shares end
    local i, guard = 0, 0
    while CC.left(allot, shares) > 0 and guard < 1000 do
        local fid = allot.rows[i % n + 1].fid
        if not CC.bump(allot, shares, fid, 1) then
            local any = false
            for _, r in ipairs(allot.rows) do
                if (shares[r.fid] or 0) + allot.step <= allot.max then any = true end
            end
            if not any then break end
        end
        i, guard = i + 1, guard + 1
    end
    return shares
end

-- ---------------------------------------------------------------- 배분 창

local FONT_H = getTextManager():getFontHeight(UIFont.Small)
local PAD = 8
local BUTTON_H = FONT_H + 10
local ROW_H = FONT_H + 14

StoryEngineAllotWindow = ISCollapsableWindow:derive("StoryEngineAllotWindow")
StoryEngineAllotWindow.instance = nil

function StoryEngineAllotWindow:new(x, y, w, h, crisis)
    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.crisis = crisis
    o.allot = crisis.allot
    o.shares = {}
    o.title = getText("IGUI_StoryEngine_Crisis2_" .. tostring(crisis.id))
    o.resizable = false
    return o
end

function StoryEngineAllotWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local top = self:titleBarHeight() + PAD + FONT_H + PAD
    self.minus, self.plus = {}, {}
    for i, row in ipairs(self.allot.rows) do
        local y = top + (i - 1) * ROW_H
        local minus = ISButton:new(self.width - PAD - 30 * 2 - 70, y, 28, BUTTON_H, "-", self, StoryEngineAllotWindow.onBump)
        minus.internal, minus.dir = row.fid, -1
        minus:initialise()
        self:addChild(minus)
        local plus = ISButton:new(self.width - PAD - 28, y, 28, BUTTON_H, "+", self, StoryEngineAllotWindow.onBump)
        plus.internal, plus.dir = row.fid, 1
        plus:initialise()
        self:addChild(plus)
        self.minus[row.fid], self.plus[row.fid] = minus, plus
    end
    local by = top + #self.allot.rows * ROW_H + PAD + FONT_H + PAD
    self.evenButton = ISButton:new(PAD, by, 140, BUTTON_H, getText("IGUI_StoryEngine_Crisis2_AllotEven"), self,
        StoryEngineAllotWindow.onEven)
    self.evenButton:initialise()
    self:addChild(self.evenButton)
    self.sendButton = ISButton:new(self.width - PAD - 140, by, 140, BUTTON_H, getText("IGUI_StoryEngine_Crisis2_AllotSend"), self,
        StoryEngineAllotWindow.onSend)
    self.sendButton:initialise()
    self:addChild(self.sendButton)
    self:setHeight(by + BUTTON_H + PAD)
end

function StoryEngineAllotWindow:onBump(button)
    CC.bump(self.allot, self.shares, button.internal, button.dir)
end

function StoryEngineAllotWindow:onEven()
    self.shares = CC.even(self.allot)
end

function StoryEngineAllotWindow:onSend()
    local p = getPlayer()
    if p and CC.canSend(self.allot, self.shares) then
        local shares = {}
        for _, row in ipairs(self.allot.rows) do shares[row.fid] = self.shares[row.fid] or 0 end
        Net.toServer(p, "crisisChoose", { shares = shares })
    end
    self:close()
end

function StoryEngineAllotWindow:render()
    ISCollapsableWindow.render(self)
    local top = self:titleBarHeight() + PAD
    self:drawText(getText("IGUI_StoryEngine_Crisis2_" .. tostring(self.crisis.id) .. "_AllotHead", num(self.allot.total),
        num(self.allot.step), num(self.allot.max)), PAD, top, 0.9, 0.85, 0.6, 1, UIFont.Small)
    top = top + FONT_H + PAD
    for i, row in ipairs(self.allot.rows) do
        local y = top + (i - 1) * ROW_H + 5
        self:drawText(getText("IGUI_StoryEngine_Crisis2_AllotRow", UI.npcName(row.fid), num(row.trust), num(row.food)),
            PAD, y, 0.9, 0.9, 0.9, 1, UIFont.Small)
        local v = num(self.shares[row.fid] or 0)
        local w = getTextManager():MeasureStringX(UIFont.Small, v)
        self:drawText(v, self.width - PAD - 30 - 35 - w / 2, y, 1, 1, 1, 1, UIFont.Small)
    end
    local left = CC.left(self.allot, self.shares)
    local y = top + #self.allot.rows * ROW_H + PAD
    self:drawText(getText(self.allot.partial and "IGUI_StoryEngine_Crisis2_AllotLeftAway" or "IGUI_StoryEngine_Crisis2_AllotLeft", num(left)),
        PAD, y, left == 0 and 0.6 or 0.95, left == 0 and 0.9 or 0.7, 0.5, 1, UIFont.Small)
    self.sendButton:setEnable(CC.canSend(self.allot, self.shares))
end

function StoryEngineAllotWindow:close()
    StoryEngineAllotWindow.instance = nil
    self:removeFromUIManager()
end

function StoryEngineAllotWindow.open(crisis)
    if StoryEngineAllotWindow.instance then StoryEngineAllotWindow.instance:close() end
    local w, h = 460, 200 + #crisis.allot.rows * ROW_H
    local x = (getCore():getScreenWidth() - w) / 2
    local y = (getCore():getScreenHeight() - h) / 2
    local win = StoryEngineAllotWindow:new(x, y, w, h, crisis)
    win:initialise()
    win:addToUIManager()
    StoryEngineAllotWindow.instance = win
    return win
end

return CC
