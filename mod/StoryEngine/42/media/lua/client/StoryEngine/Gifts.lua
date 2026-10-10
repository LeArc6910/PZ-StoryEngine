-- 카운티 회의의 결실 (서버 Era.lua): 생존자들의 선물과 헌장이 도착했다는 알림, 선물 이름표.
-- 선물은 바닐라 아이템에 modData seGiftFrom(세력)·seGiftVoice(준 사람이 후임이면 그 id)·seGiftKey 가 붙어 온다.
-- 이름은 보는 사람 언어로 여기서 붙인다 (서버는 번역을 못 읽는다). 멀티에서는 이름이 다음 접속 때 서버 것(영어)으로
-- 돌아올 수 있어 접속할 때마다 다시 붙이고, 툴팁의 "~의 선물" 줄(ItemTooltip.lua)은 늘 맞다.

if isServer() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Client"
require "StoryEngine/Factions"
require "StoryEngine/UIUtil"

local Client = StoryEngine.Client
local Factions = StoryEngine.Factions

local Gifts = {}
StoryEngine.Gifts = Gifts

-- 준 사람 이름 (괄호 속 거점은 뺀다). voice: 후임 id | nil(처음 사람)
function Gifts.giver(fid, voice)
    local name = Factions.nameAs(tostring(fid), voice or false)
    name = string.gsub(name, "%s*%(.*%)%s*$", "")
    return name
end

-- 이 물건이 선물이면 { from, voice, key }
function Gifts.of(item)
    if not item or not item.getModData then return nil end
    local ok, mod = pcall(function() return item:getModData() end)
    if not ok or not mod or not mod.seGiftFrom then return nil end
    return { from = mod.seGiftFrom, voice = mod.seGiftVoice, key = mod.seGiftKey }
end

-- 선물의 이름 ("휘태커 병장의 소총")
function Gifts.nameOf(g)
    local key = "IGUI_StoryEngine_Gift_Name_" .. tostring(g.key)
    if not StoryEngine.UI.hasText(key) then return nil end
    return getText(key, Gifts.giver(g.from, g.voice))
end

-- 툴팁 줄 ("휘태커 병장의 선물 - 교회를 지킨 날")
function Gifts.tip(item)
    local g = Gifts.of(item)
    if not g then return nil end
    return getText("IGUI_StoryEngine_Tip_Gift", Gifts.giver(g.from, g.voice))
end

-- 가진 선물에 이름을 붙인다. 반환: 바꾼 수
function Gifts.relabel(player)
    if not player then return 0 end
    local n = 0
    pcall(function()
        local list = player:getInventory():getAllEvalRecurse(function(item) return Gifts.of(item) ~= nil end)
        for i = 0, list:size() - 1 do
            local item = list:get(i)
            local name = Gifts.nameOf(Gifts.of(item))
            if name and item.setName and item:getName() ~= name then
                item:setName(name)
                if item.setCustomName then item:setCustomName(true) end
                n = n + 1
            end
        end
    end)
    return n
end

function Client.handlers.councilGifts(args)
    local player = getPlayer()
    if not player then return end
    if args.charter then HaloTextHelper.addGoodText(player, getText("IGUI_StoryEngine_Charter_Got")) end
    local count = #(args.gifts or {})
    if count > 0 then
        HaloTextHelper.addGoodText(player, getText("IGUI_StoryEngine_Gift_Got", StoryEngine.intToString(count)))
    end
    Gifts.relabel(player)
end

-- 의회 시대가 시작됐다
function Client.handlers.eraNotice(args)
    local player = getPlayer()
    if not player then return end
    HaloTextHelper.addGoodText(player, getText("IGUI_StoryEngine_Era_Notice_" .. tostring(args.kind or "begin")))
end

Events.OnGameStart.Add(function()
    pcall(Gifts.relabel, getPlayer())
end)

return Gifts
