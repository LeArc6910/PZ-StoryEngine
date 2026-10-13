-- 연립·불신임·분열·군정·시설·증언, 클라이언트 쪽 (서버 Regime.lua): 의회 탭의 글과 메뉴 줄, 알림.

if isServer() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Factions"
require "StoryEngine/UIUtil"
require "StoryEngine/Client"

local Net = StoryEngine.Net
local UI = StoryEngine.UI
local Client = StoryEngine.Client

local RC = {}
StoryEngine.RegimeClient = RC

RC.NOTICES = { coalition = true, coalition_broken = true, mend = true, wedge = true, split_cut = true, split_back = true,
               reunite = true, reunited = true, reunite_failed = true, martial_order = true, martial_obeyed = true,
               martial_defied = true, martial_settled = true, martial_over = true, facility_held = true, facility_lost = true,
               facility_back = true, testify_open = true, testified = true, tithe = true, tithe_paid = true,
               tithe_unpaid = true, curfew_warn = true, curfew_caught = true, post_snub = true }
RC.GOOD = { coalition = true, mend = true, split_back = true, reunite = true, reunited = true, martial_obeyed = true,
            martial_over = true, facility_held = true, facility_back = true, testify_open = true, testified = true,
            tithe_paid = true }
RC.ERRORS = { how = true, closed = true, wait = true, no_coalition = true, trust = true, no_target = true, no_secret = true,
              no_chair = true, busy = true, no_split = true, no_ask = true, no_martial = true, no_blame = true, done = true }

local function num(n) return StoryEngine.intToString(math.floor((n or 0) + 0.5)) end

local function line(parts, text, rgb)
    parts[#parts + 1] = " <RGB:" .. (rgb or "0.9,0.9,0.9") .. "> " .. UI.escape(text) .. " <LINE> "
end

local function names(list)
    local out = {}
    for _, fid in ipairs(list or {}) do out[#out + 1] = UI.npcName(fid) end
    return table.concat(out, ", ")
end

local function blocName(b) return getText("IGUI_StoryEngine_Politics_Bloc_" .. tostring(b)) end

local function blocNames(list)
    local out = {}
    for _, b in ipairs(list or {}) do out[#out + 1] = blocName(b) end
    return table.concat(out, " + ")
end

local function what(kind) return getText("IGUI_StoryEngine_Regime_" .. (kind == "water" and "Water" or "Power")) end

local function hoursText(h)
    if (h or 0) >= 48 then return getText("IGUI_StoryEngine_Politics_Days", num(h / 24)) end
    return getText("IGUI_StoryEngine_Politics_Hours", num(h))
end

-- 의회 탭의 글 (정치 글 아래에 붙는다). d = 서버 Politics.payload
function RC.textOf(d)
    local r = d and d.on and d.regime
    if not r then return "" end
    local parts = {}
    -- 독주의 색: 그 파벌의 모습으로 굳은 카운티
    local ru = r.rule
    if ru then
        line(parts, getText("IGUI_StoryEngine_Regime_Rule_" .. tostring(ru.bloc) .. "_good"), "0.7,0.9,0.7")
        line(parts, getText("IGUI_StoryEngine_Regime_Rule_" .. tostring(ru.bloc) .. "_bad"), "0.95,0.7,0.5")
        if ru.tithe then
            line(parts, getText("IGUI_StoryEngine_Regime_Tithe"), "1,0.86,0.55")
        elseif ru.titheDays then
            line(parts, getText("IGUI_StoryEngine_Regime_Tithe_Next", num(ru.titheDays)), "0.7,0.8,0.9")
        end
    end
    local sp = r.split
    if sp then
        line(parts, getText("IGUI_StoryEngine_Regime_Split"), "0.95,0.6,0.4")
        for _, h in ipairs(sp.halves or {}) do
            local text = getText("IGUI_StoryEngine_Regime_Split_Half", blocNames(h.blocs), names(h.members), what(h.hold), num(h.avg))
            if h.cut then text = text .. "  " .. getText("IGUI_StoryEngine_Regime_Split_Cut", what(h.hold)) end
            line(parts, text, h.cut and "0.95,0.5,0.4" or "0.9,0.9,0.9")
        end
        line(parts, getText("IGUI_StoryEngine_Regime_Split_Rule"), "0.7,0.8,0.9")
        if sp.reunion then
            line(parts, getText("IGUI_StoryEngine_Regime_Reunion", tostring(sp.reunion.by or "?"), hoursText(sp.reunion.hours)), "0.75,0.95,0.75")
        elseif (sp.wait or 0) > 0 then
            line(parts, getText("IGUI_StoryEngine_Regime_Reunion_Wait", num(sp.wait)), "0.6,0.6,0.6")
        end
    end
    local m = r.martial
    if m then
        line(parts, getText("IGUI_StoryEngine_Regime_Martial", UI.npcName(m.by)), "0.95,0.6,0.4")
        if m.against then line(parts, getText("IGUI_StoryEngine_Regime_Martial_Against", UI.npcName(m.against)), "0.85,0.8,0.6") end
        line(parts, getText("IGUI_StoryEngine_Regime_Martial_Count", num(m.obeyed), num(m.defied), num(m.settleAt)), "0.9,0.9,0.9")
        if m.settled then line(parts, getText("IGUI_StoryEngine_Regime_Martial_Settled"), "0.95,0.7,0.5") end
        line(parts, m.order and getText("IGUI_StoryEngine_Regime_Martial_Order")
            or getText("IGUI_StoryEngine_Regime_Martial_Next", num(m.days)), "0.7,0.8,0.9")
        if m.backed then line(parts, getText("IGUI_StoryEngine_Regime_Martial_Backed"), "0.75,0.95,0.75") end
        line(parts, getText("IGUI_StoryEngine_Regime_Martial_Petition", num(m.yes), num(m.need)),
            (m.yes or 0) >= (m.need or 1) and "0.75,0.95,0.75" or "0.7,0.8,0.9")
    end
    local c = r.coalition
    if c and #(c.blocs or {}) >= 2 then
        local text = getText("IGUI_StoryEngine_Regime_Coalition", blocNames(c.blocs))
        if (c.strain or 0) > 0 then
            text = text .. "  " .. getText("IGUI_StoryEngine_Regime_Coalition_Strain", num(c.strain), num(c.limit))
        end
        line(parts, text, (c.strain or 0) > 0 and "0.95,0.7,0.5" or "0.85,0.8,0.6")
    elseif c then
        line(parts, getText("IGUI_StoryEngine_Regime_Coalition_Alone", blocNames(c.blocs)), "0.85,0.8,0.6")
    end
    local f = r.facility
    if f then
        for _, h in ipairs(f.held or {}) do
            line(parts, getText("IGUI_StoryEngine_Regime_Facility_Held", what(h.what), blocName(h.bloc)), "0.85,0.8,0.6")
        end
        for _, x in ipairs(f.down or {}) do
            line(parts, getText("IGUI_StoryEngine_Regime_Facility_Down", what(x.what), num(x.days)), "0.95,0.5,0.4")
        end
    end
    local b = r.blame
    if b then
        if b.used then
            line(parts, getText("IGUI_StoryEngine_Regime_Blame_Used", tostring(b.by or "?"), blocName(b.bloc)), "0.75,0.95,0.75")
        else
            line(parts, getText("IGUI_StoryEngine_Regime_Blame", hoursText(b.hours)), "1,0.86,0.55")
        end
    end
    if #parts == 0 then return "" end
    return " <LINE> " .. table.concat(parts)
end

-- [제안·선거·의장...] 메뉴에 더하는 줄: { { label, ok, tip, args } } (args 는 regimeAct 에 그대로)
function RC.rows(d)
    local rows = {}
    local r = d and d.on and d.regime
    if not r then return rows end
    local b = r.blame
    if b and not b.used then
        for _, bl in ipairs(d.blocs or {}) do
            if #(bl.members or {}) > 0 then
                rows[#rows + 1] = { label = getText("IGUI_StoryEngine_Regime_Testify", blocName(bl.id)), ok = true,
                                    tip = getText("IGUI_StoryEngine_Regime_Testify_Tip"), args = { what = "testify", bloc = bl.id } }
            end
        end
    end
    local c = r.coalition
    if c and #(c.blocs or {}) >= 2 then
        local wait = c.mendWait or 0
        rows[#rows + 1] = { label = getText("IGUI_StoryEngine_Regime_Mend"), ok = wait <= 0,
            tip = (wait > 0 and (getText("IGUI_StoryEngine_Regime_Error_wait") .. " <LINE> ") or "") .. getText("IGUI_StoryEngine_Regime_Mend_Tip"),
            args = { what = "mend" } }
        local inside = {}
        for _, fid in ipairs(c.members or {}) do inside[fid] = true end
        for _, fid in ipairs(d.secrets or {}) do
            if inside[fid] then
                rows[#rows + 1] = { label = getText("IGUI_StoryEngine_Regime_Wedge", UI.npcName(fid)), ok = true,
                                    tip = getText("IGUI_StoryEngine_Regime_Wedge_Tip"), args = { what = "wedge", fid = fid } }
            end
        end
    end
    local nc = r.noconf
    if nc then
        local why = nil
        if d.bill then why = "busy" elseif (nc.wait or 0) > 0 then why = "wait" end
        rows[#rows + 1] = { label = getText("IGUI_StoryEngine_Regime_NoConf", UI.npcName(nc.fid)), ok = why == nil,
            tip = (why and (getText("IGUI_StoryEngine_Regime_Error_" .. why) .. " <LINE> ") or "") .. getText("IGUI_StoryEngine_Regime_NoConf_Tip"),
            args = { what = "noconf" } }
    end
    local sp = r.split
    if sp then
        local why = nil
        if sp.reunion then why = "busy" elseif (sp.wait or 0) > 0 then why = "wait" end
        rows[#rows + 1] = { label = getText("IGUI_StoryEngine_Regime_Reunite"), ok = why == nil,
            tip = (why and (getText("IGUI_StoryEngine_Regime_Error_" .. why) .. " <LINE> ") or "") .. getText("IGUI_StoryEngine_Regime_Reunite_Tip"),
            args = { what = "reunite" } }
    end
    local m = r.martial
    if m then
        rows[#rows + 1] = { label = getText("IGUI_StoryEngine_Regime_Petition", UI.npcName(m.by)), ok = (m.yes or 0) >= (m.need or 1),
            tip = getText("IGUI_StoryEngine_Regime_Petition_Tip", num(m.yes), num(m.need)), args = { what = "petition" } }
    end
    return rows
end

-- 알림 문장 (PoliticsClient.noticeText 가 묻는다). 반환: 문장 | nil, 좋은 소식인가
function RC.noticeText(args)
    local kind = tostring(args.kind)
    if not RC.NOTICES[kind] then return nil, true end
    local good = RC.GOOD[kind] == true
    local key = "IGUI_StoryEngine_Regime_Notice_" .. kind
    if kind == "coalition" then
        if #(args.blocs or {}) < 2 then return nil, true end
        return getText(key, blocNames(args.blocs)), good
    elseif kind == "coalition_broken" then
        return getText(key, blocNames(args.blocs), num(args.laws)), good
    elseif kind == "mend" then
        return getText(key, UI.npcName(args.a), UI.npcName(args.b)), good
    elseif kind == "wedge" then
        return getText(key, UI.npcName(args.fid), blocName(args.bloc)), good
    elseif kind == "split_cut" or kind == "split_back" then
        return getText(key, blocNames(args.blocs), what(args.hold)), good
    elseif kind == "martial_order" then
        return getText(key .. (args.sweep and "_sweep" or "_levy"), UI.npcName(args.by)), good
    elseif kind == "martial_obeyed" or kind == "martial_defied" or kind == "martial_settled" then
        return getText(key, UI.npcName(args.by)), good
    elseif kind == "facility_held" then
        if args.bloc then return getText(key .. "_bloc", what(args.what), blocName(args.bloc)), good end
        return getText(key, what(args.what)), good
    elseif kind == "facility_lost" then
        return getText(key, what(args.what), num(args.days)), good
    elseif kind == "facility_back" then
        return getText(key, what(args.what)), good
    elseif kind == "testified" then
        return getText(key, tostring(args.name), blocName(args.bloc)), good
    elseif kind == "reunite" then
        return getText(key, tostring(args.name)), good
    elseif kind == "tithe" or kind == "curfew_caught" then
        return getText(key, UI.npcName(args.fid)), good
    elseif kind == "tithe_paid" then
        return getText(key, args.fid and UI.npcName(args.fid) or "?"), good
    elseif kind == "post_snub" then
        return getText(key, blocName(args.bloc)), good
    end
    return getText(key), good
end

function Client.handlers.regimeResult(args)
    local p = getPlayer()
    if not p then return end
    if args.ok then
        HaloTextHelper.addGoodText(p, getText("IGUI_StoryEngine_Regime_Done_" .. tostring(args.what)))
        return
    end
    local err = tostring(args.error)
    if err == "trust" and args.what == "petition" then
        HaloTextHelper.addBadText(p, getText("IGUI_StoryEngine_Regime_Error_petition", num(args.a), num(args.b)))
    elseif err == "trust" then
        HaloTextHelper.addBadText(p, getText("IGUI_StoryEngine_Regime_Error_trust", num(args.a)))
    else
        HaloTextHelper.addBadText(p, RC.ERRORS[err] and getText("IGUI_StoryEngine_Regime_Error_" .. err) or err)
    end
end

return RC
