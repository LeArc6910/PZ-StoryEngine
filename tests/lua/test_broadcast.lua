-- 게임 속 라디오 방송 (Broadcast.lua, 아이디어 2번)
local T = {}

local function setup()
    local p = H.addPlayer("tester", "Gerald", "Kar")
    local ps = StoryEngine.Store.player(p)
    ps.lang = "KO"
    H.fire("OnLoadRadioScripts", H.scriptManager({ { freq = 105400, uuid = "SOMEONE-ELSE" } }), true)
    return p, ps
end

local B = function() return StoryEngine.Broadcast end
local function toHour(h)
    local now = H.clockMin % 1440
    local want = h * 60
    H.advance(want > now and want - now or 1440 - now + want)
end
local function bridgeCount()
    local n = 0
    for _, b in ipairs(H.bridge) do if b.module == "broadcast" then n = n + 1 end end
    return n
end

function T.channel_takes_a_free_frequency()
    setup()
    H.eq(B().freq, 105600, "105.4 was taken, next 0.2 step")
    H.eq(H.gtModData.storyEngineBroadcastFreq, 105600, "remembered in GameTime ModData")
    H.eq(B().freqText(), "105.6")
    H.eq(B().channel.uuid, B().UUID)
    H.eq(B().channel.cat, "Radio")
end

function T.evening_news_gathers_facts_and_airs()
    local p, ps = setup()
    local now = StoryEngine.Sensor.now()
    StoryEngine.Social.news("all", "A helicopter flew low over the county today.")
    StoryEngine.Social.onStorm()
    StoryEngine.Life.npc("ray").res.food = 5
    StoryEngine.Store.data().quests.q1 = { id = "q1", kind = "horde", state = "completed", endedT = now.t,
        origin = { faction = "ray" }, targetName = "Gerald Kar", place = { town = "Riverside" } }
    StoryEngine.Store.data().quests.q2 = { id = "q2", kind = "fetch", state = "failed", endedT = now.t - 3000,
        origin = { faction = "doc" } }
    H.climate.forecast = { min = 17, max = 26, heavyRain = true }
    toHour(18)
    B().tick()
    H.eq(bridgeCount(), 0, "not before 19:00")
    toHour(19)
    B().tick()
    local req = H.lastBridge("broadcast")
    H.ok(req, "requested at 19:00")
    local pl = req.payload
    H.eq(pl.host, "casey")
    H.eq(pl.lang, "KO")
    H.eq(pl.freq, "105.6")
    H.eq(pl.weather, "Tomorrow: 17 to 26 C, heavy rain")
    local all = table.concat(pl.facts, " | ")
    H.ok(string.find(all, "helicopter", 1, true), "news for everyone")
    H.ok(string.find(all, "storm rolled in", 1, true), "storm")
    H.ok(string.find(all, "Gerald Kar cleared out a pack of the dead for Ray Mercer near Riverside.", 1, true), all)
    H.ok(not string.find(all, "lost package", 1, true), "old quest left out")
    H.ok(string.find(all, "Ray Mercer's people are running short of food.", 1, true), "low resources")
    B().tick()
    H.eq(bridgeCount(), 1, "once a day")
    req.callback({ ok = true, json = { lines = { "Valley Station, 105.6.", "", "News one.", "Good night." },
                                       rerun = "Replay of last night." } })
    local aired = H.radio.aired[#H.radio.aired]
    H.eq(aired.freq, 105600)
    H.eq(#aired.lines, 3, "empty line dropped")
    H.eq(aired.lines[1], "Valley Station, 105.6.")
    local air = H.sentOf("broadcastAir")[1]
    H.ok(air and air.id, "clients told")
    H.eq(air.host, "casey")
    H.eq(air.freq, 105600)
    -- 들은 사람
    H.ok(B().heard(p, air.id))
    local note = ps.notes[#ps.notes]
    H.eq(note.kind, "broadcast_heard")
    H.eq(note.faction, "casey")
    H.eq(note.lines[3], "Good night.")
    H.ok(not B().heard(p, air.id), "only once")
    H.ok(not B().heard(p, "SE-1"), "stale id")
    H.ok(string.find(B().statusText(), "heard=1", 1, true), B().statusText())
    -- 다음 날 아침 재방송
    toHour(7)
    B().tick()
    aired = H.radio.aired[#H.radio.aired]
    H.eq(aired.lines[1], "Replay of last night.")
    H.eq(#aired.lines, 4)
    local rerun = H.sentOf("broadcastAir")[2]
    H.ok(rerun.rerun, "marked as rerun")
    H.ok(rerun.id ~= air.id, "new airing id")
    H.ok(not B().heard(p, rerun.id), "already heard this broadcast")
    local count = #H.radio.aired
    B().tick()
    H.eq(#H.radio.aired, count, "one rerun")
end

function T.ai_failure_means_no_show()
    setup()
    toHour(19)
    B().tick()
    H.lastBridge("broadcast").callback({ ok = false, error = "timeout" })
    H.eq(#H.radio.aired, 0)
    H.ok(H.logHas("no show tonight"))
end

function T.ray_takes_over_then_static()
    setup()
    local Factions = StoryEngine.Factions
    local gone = { casey = true }
    Factions.isGone = function(fid) return gone[fid] == true end
    toHour(19)
    B().tick()
    H.eq(H.lastBridge("broadcast").payload.host, "ray")
    H.eq(select(2, B().build(StoryEngine.Sensor.now())), "busy", "one request at a time")
    H.lastBridge("broadcast").callback({ ok = false, error = "timeout" })
    gone.ray = true
    local before = bridgeCount()
    B().build(StoryEngine.Sensor.now())
    H.eq(bridgeCount(), before, "nobody to ask")
    H.eq(H.radio.aired[#H.radio.aired].lines[1], "<fzzt>")
end

function T.option_off_and_nobody_online()
    setup()
    SandboxVars.StoryEngine.Broadcast = false
    toHour(19)
    B().tick()
    H.eq(bridgeCount(), 0, "disabled")
    SandboxVars.StoryEngine.Broadcast = true
    H.players = {}
    B().tick()
    H.eq(bridgeCount(), 0, "nobody online")
end

function T.command_and_debug()
    local p = setup()
    H.fire("OnClientCommand", StoryEngine.MODULE, "broadcastHeard", p, { id = "nope" })
    H.eq(#(StoryEngine.Store.player(p).notes or {}), 0)
end

return T
