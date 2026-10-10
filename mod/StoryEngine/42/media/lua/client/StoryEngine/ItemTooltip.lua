-- 인벤토리 아이템 툴팁에 StoryEngine 정보 몇 줄 (2026-09-30 사용자 요청).
--   거래: 도구 · 가치 8
--   대가로 받는 곳: 레이 머서, 에이머스 파이크, ...
--   물자 지원: 무기 / 듀이 프로젝트: 차량 부품 6점
-- 바닐라 ISToolTipInv:render 를 감싸 원래 툴팁을 그린 뒤, 그 아래에(화면 밖이면 위에) 작은 상자를 하나 더 그린다.
-- 원래 함수를 부르므로 툴팁을 고치는 다른 모드와 같이 쓸 수 있다. 분류 규칙은 shared/StoryEngine/Value.lua.

if isServer() then return end

require "ISUI/ISToolTipInv"
require "StoryEngine/Core"
require "StoryEngine/Value"
require "StoryEngine/Factions"

local Value = StoryEngine.Value
local Factions = StoryEngine.Factions

local ItemTooltip = {}
StoryEngine.ItemTooltip = ItemTooltip

local PAD = 5
local COLOR = { 0.95, 0.8, 0.5 }
local DIM = { 0.7, 0.7, 0.7 }
local GIFT = { 1, 0.86, 0.55 }

local function fmt(n)
    n = tonumber(n) or 0
    local whole = math.floor(n * 10 + 0.5) / 10
    if whole == math.floor(whole) then return StoryEngine.intToString(whole) end
    return tostring(whole)
end

-- 떠나거나 죽은 NPC 는 빼고 이름으로
local function names(ids)
    local Cache = StoryEngine.Cache
    local out = {}
    for _, fid in ipairs(ids or {}) do
        local ch = Cache and Cache.channels and Cache.channels[fid]
        if not (ch and ch.gone) then out[#out + 1] = Factions.name(fid) end
    end
    return table.concat(out, ", ")
end

-- 툴팁 줄 { { text, color } }. 모드와 상관없는 물건이면 빈 목록
function ItemTooltip.lines(item)
    local out = {}
    -- 생존자들의 선물 (카운티 회의, Gifts.lua)
    local Gifts = StoryEngine.Gifts
    if Gifts then
        local okG, tip = pcall(Gifts.tip, item)
        if okG and tip then out[#out + 1] = { tip, GIFT } end
    end
    local ok, s = pcall(Value.summary, item)
    if not ok or not s then return out end
    if s.quest then
        out[#out + 1] = { getText("IGUI_StoryEngine_Tip_Quest"), DIM }
        return out
    end
    if s.raw then
        out[#out + 1] = { getText(s.raw == "made" and "IGUI_StoryEngine_Tip_RawMade" or "IGUI_StoryEngine_Tip_Raw"), DIM }
        return out
    end
    if s.category then
        local cat = getText("IGUI_StoryEngine_Cat_" .. s.category)
        if s.tier then cat = getText("IGUI_StoryEngine_Tip_CatTier", cat, StoryEngine.intToString(s.tier)) end
        out[#out + 1] = { getText("IGUI_StoryEngine_Tip_Trade", cat, fmt(s.value)), COLOR }
        local who = names(s.wanted)
        out[#out + 1] = { who ~= "" and getText("IGUI_StoryEngine_Tip_Wanted", who) or getText("IGUI_StoryEngine_Tip_NotWanted"),
                          who ~= "" and COLOR or DIM }
    end
    if s.kind then
        -- 거래 품목이 아닌 분류 (전자기기·차량 부품·기호품): NPC 부탁 점수에 쓰인다
        local cat = getText("IGUI_StoryEngine_Cat_" .. s.kind)
        if s.tier then cat = getText("IGUI_StoryEngine_Tip_CatTier", cat, StoryEngine.intToString(s.tier)) end
        out[#out + 1] = { getText("IGUI_StoryEngine_Tip_Kind", cat), COLOR }
    end
    if s.resource then
        out[#out + 1] = { getText("IGUI_StoryEngine_Tip_Donate", getText("IGUI_StoryEngine_Life_Res_" .. s.resource),
            fmt(s.resValue)), COLOR }
    end
    if s.vehicle then
        out[#out + 1] = { getText("IGUI_StoryEngine_Tip_Vehicle", Factions.name("dewey"), fmt(s.vehicle)), COLOR }
    end
    if s.rotten then out[#out + 1] = { getText("IGUI_StoryEngine_Tip_Rotten"), DIM } end
    if s.broken then
        out[#out + 1] = { getText("IGUI_StoryEngine_Tip_Broken"), DIM }
    elseif s.worn then
        out[#out + 1] = { getText("IGUI_StoryEngine_Tip_Worn", StoryEngine.intToString(s.worn)), DIM }
    end
    return out
end

local original = ISToolTipInv.render

function ISToolTipInv:render()
    original(self)
    if not self.item or (ISContextMenu.instance and ISContextMenu.instance.visibleCheck) then return end
    local ok, lines = pcall(ItemTooltip.lines, self.item)
    if not ok or #lines == 0 then return end
    local tm = getTextManager()
    local fh = tm:getFontHeight(UIFont.Small)
    local w = self.width
    for _, l in ipairs(lines) do w = math.max(w, tm:MeasureStringX(UIFont.Small, l[1]) + PAD * 2) end
    local h = #lines * fh + PAD * 2
    -- 아래에 붙이고, 화면 밖이면 위에
    local y = self.height
    if self:getAbsoluteY() + self.height + h > getCore():getScreenHeight() then y = -h end
    local bg, bd = self.backgroundColor, self.borderColor
    self:drawRect(0, y, w, h, math.max(0.75, bg.a), bg.r, bg.g, bg.b)
    self:drawRectBorder(0, y, w, h, bd.a, bd.r, bd.g, bd.b)
    for i, l in ipairs(lines) do
        self:drawText(l[1], PAD, y + PAD + (i - 1) * fh, l[2][1], l[2][2], l[2][3], 1, UIFont.Small)
    end
end

return ItemTooltip
