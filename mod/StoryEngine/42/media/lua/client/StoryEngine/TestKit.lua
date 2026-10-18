-- 감염 진단 키트 (2026-10-18): 인벤토리 우클릭 "감염 진단 키트 사용" -> 서버가 판정하고 키트를 없앤다 -> 결과를 머리 위에

if isServer() then return end

require "StoryEngine/Core"
require "StoryEngine/Net"
require "StoryEngine/Client"

local Net = StoryEngine.Net
local Client = StoryEngine.Client

local TestKit = {}
StoryEngine.TestKit = TestKit
TestKit.ITEM = "StoryEngine.InfectionTestKit"

function TestKit.kitOf(items)
    for _, v in ipairs(items or {}) do
        local it = v
        if type(v) == "table" and v.items then it = v.items[1] end
        if it and it.getFullType and it:getFullType() == TestKit.ITEM then return it end
    end
    return nil
end

-- 결과 문장 (테스트도 씀)
function TestKit.resultText(args)
    if args.error then return getText("IGUI_StoryEngine_TestKit_Missing"), false end
    if not args.infected then return getText("IGUI_StoryEngine_TestKit_Negative"), true end
    if args.pct then
        return getText("IGUI_StoryEngine_TestKit_Positive", StoryEngine.intToString(args.pct)), false
    end
    return getText("IGUI_StoryEngine_TestKit_PositiveUnknown"), false
end

function Client.handlers.testKitResult(args)
    local p = getPlayer()
    if not p then return end
    local text, good = TestKit.resultText(args or {})
    if good then HaloTextHelper.addGoodText(p, text) else HaloTextHelper.addBadText(p, text) end
    if not args.error and p.Say then p:Say(text) end
end

local function onFillInventory(playerNum, context, items)
    local it = TestKit.kitOf(items)
    if not it then return end
    context:addOption(getText("ContextMenu_StoryEngine_UseTestKit"), it, function(item)
        local p = getSpecificPlayer(playerNum)
        if p then Net.toServer(p, "testKitUse", { id = item:getID() }) end
    end)
end

if Events and Events.OnFillInventoryObjectContextMenu then
    Events.OnFillInventoryObjectContextMenu.Add(onFillInventory)
end
TestKit.onFillInventory = onFillInventory

return TestKit
