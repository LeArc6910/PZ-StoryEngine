-- 복구 작전·전력망 클라이언트 핸들러 (UI 는 Dummy)
local T = { __client = true }

function T.op_notice_asks_for_quest_list()
    H.addPlayer("tester", "Gerald", "Kar")
    StoryEngine.Client.handlers.opNotice({ event = "act", kind = "water", act = 2, acts = 5 })
    StoryEngine.Client.handlers.opNotice({ event = "failed", kind = "power", act = 4, acts = 5 })
    local asked = 0
    for _, c in ipairs(H.toServer or {}) do if c.command == "questList" then asked = asked + 1 end end
    H.eq(asked, 2)
end

function T.grid_sync_applies_sandbox_values()
    local so = { values = { ElecShutModifier = 14, WaterShutModifier = 14 } }
    function so:set(name, v) self.values[name] = v end
    function so:getElecShutModifier() return self.values.ElecShutModifier end
    function so:getWaterShutModifier() return self.values.WaterShutModifier end
    function so:toLua() end
    function so:doesPowerGridExist() return true end
    getSandboxOptions = function() return so end
    StoryEngine.Client.handlers.gridSync({ power = 75, water = 0 })
    H.eq(so.values.ElecShutModifier, 75)
    H.eq(so.values.WaterShutModifier, 0)
end

return T
