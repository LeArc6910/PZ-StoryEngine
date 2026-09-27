-- StoryEngine 공용 코어. 전역은 StoryEngine 테이블 하나만 쓴다.

StoryEngine = StoryEngine or {}

StoryEngine.MODULE = "StoryEngine"   -- sendClientCommand / sendServerCommand 의 module 이름
StoryEngine.VERSION = "0.1.0"

StoryEngine.Config = {
    dataDir = "StoryEngine/",          -- Zomboid/Lua/ 기준 상대 경로
    pollMs = 500,                      -- 응답 파일 확인 주기 (실시간)
    heartbeatCheckMs = 2000,           -- heartbeat.json 확인 주기
    heartbeatTimeoutMs = 15000,        -- 이 시간 동안 seq 가 안 바뀌면 연결 끊김
    requestTimeoutMs = 90000,          -- 응답을 기다리는 최대 시간
}

function StoryEngine.log(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    print("[StoryEngine] " .. table.concat(parts, " "))
end

-- 서버 역할: 싱글플레이 또는 멀티 서버 프로세스
function StoryEngine.isServerSide()
    return not isClient()
end

-- 큰 정수를 지수 표기 없이 문자열로 바꾼다 (getTimestampMs 같은 long 값용).
function StoryEngine.intToString(n)
    n = math.floor(n)
    if n == 0 then return "0" end
    local negative = n < 0
    if negative then n = -n end
    local digits = {}
    while n > 0 do
        local d = n % 10
        digits[#digits + 1] = string.char(48 + d)
        n = math.floor(n / 10)
    end
    local out = {}
    for i = #digits, 1, -1 do
        out[#out + 1] = digits[i]
    end
    return (negative and "-" or "") .. table.concat(out)
end

-- 샌드박스 옵션 StoryEngine.<name>. 옵션이 없는 예전 세이브에서는 default
function StoryEngine.option(name, default)
    local vars = SandboxVars and SandboxVars.StoryEngine
    local value = vars and vars[name]
    if value == nil then return default end
    return value
end

function StoryEngine.nowMs()
    return getTimestampMs()
end
