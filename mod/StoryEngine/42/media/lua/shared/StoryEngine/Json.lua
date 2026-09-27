-- 최소 JSON 인코더/디코더. Kahlua 호환을 위해 패턴·format 의존을 줄이고 문자 단위로 처리한다.
-- 브릿지와 주고받는 작은 파일 전용이다. null 은 nil 로 디코딩되고, 빈 테이블은 {} 로 인코딩된다.

require "StoryEngine/Core"

local Json = {}
StoryEngine.Json = Json

local HEX = "0123456789abcdef"

local function hex4(n)
    local out = ""
    for _ = 1, 4 do
        local d = n % 16
        out = string.sub(HEX, d + 1, d + 1) .. out
        n = math.floor(n / 16)
    end
    return out
end

local ESC = {
    [34] = '\\"', [92] = "\\\\", [8] = "\\b", [12] = "\\f",
    [10] = "\\n", [13] = "\\r", [9] = "\\t",
}

local function encodeString(s)
    local out = { '"' }
    local start = 1
    local len = string.len(s)
    for i = 1, len do
        local c = string.byte(s, i)
        if c < 32 or c == 34 or c == 92 then
            if i > start then out[#out + 1] = string.sub(s, start, i - 1) end
            out[#out + 1] = ESC[c] or ("\\u" .. hex4(c))
            start = i + 1
        end
    end
    if start <= len then out[#out + 1] = string.sub(s, start) end
    out[#out + 1] = '"'
    return table.concat(out)
end

local function encodeNumber(n)
    if n ~= n or n == math.huge or n == -math.huge then return "null" end
    if n == math.floor(n) and math.abs(n) < 1e15 then
        return StoryEngine.intToString(n)
    end
    return tostring(n)
end

local function isArray(t)
    local count = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then return false end
        count = count + 1
    end
    for i = 1, count do
        if t[i] == nil then return false end
    end
    return count > 0, count
end

local encodeValue

local function encodeTable(t, depth)
    if depth > 32 then error("json: nesting too deep") end
    local array, count = isArray(t)
    local out = {}
    if array then
        for i = 1, count do
            out[#out + 1] = encodeValue(t[i], depth + 1)
        end
        return "[" .. table.concat(out, ",") .. "]"
    end
    for k, v in pairs(t) do
        local tv = type(v)
        if tv ~= "function" and tv ~= "userdata" then
            out[#out + 1] = encodeString(tostring(k)) .. ":" .. encodeValue(v, depth + 1)
        end
    end
    return "{" .. table.concat(out, ",") .. "}"
end

encodeValue = function(v, depth)
    local tv = type(v)
    if tv == "nil" then return "null" end
    if tv == "boolean" then return v and "true" or "false" end
    if tv == "number" then return encodeNumber(v) end
    if tv == "string" then return encodeString(v) end
    if tv == "table" then return encodeTable(v, depth) end
    return encodeString(tostring(v))
end

function Json.encode(v)
    return encodeValue(v, 0)
end

-- ---------------------------------------------------------------- decode

local function skipWs(s, i)
    while true do
        local c = string.byte(s, i)
        if c == 32 or c == 9 or c == 10 or c == 13 then
            i = i + 1
        else
            return i
        end
    end
end

local decodeValue

local function decodeString(s, i)
    -- s[i] == '"'
    local out = {}
    i = i + 1
    local len = string.len(s)
    local start = i
    while i <= len do
        local c = string.byte(s, i)
        if c == 34 then
            if i > start then out[#out + 1] = string.sub(s, start, i - 1) end
            return table.concat(out), i + 1
        elseif c == 92 then
            if i > start then out[#out + 1] = string.sub(s, start, i - 1) end
            local e = string.sub(s, i + 1, i + 1)
            if e == "n" then out[#out + 1] = "\n"
            elseif e == "t" then out[#out + 1] = "\t"
            elseif e == "r" then out[#out + 1] = "\r"
            elseif e == "b" then out[#out + 1] = string.char(8)
            elseif e == "f" then out[#out + 1] = string.char(12)
            elseif e == "u" then
                local code = tonumber(string.sub(s, i + 2, i + 5), 16)
                if not code then error("json: bad \\u escape at " .. i) end
                out[#out + 1] = string.char(code)
                i = i + 4
            else
                out[#out + 1] = e   -- \" \\ \/
            end
            i = i + 2
            start = i
        else
            i = i + 1
        end
    end
    error("json: unterminated string")
end

local NUMBER_CHARS = {}
for _, ch in ipairs({ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "-", "+", ".", "e", "E" }) do
    NUMBER_CHARS[string.byte(ch)] = true
end

local function decodeNumber(s, i)
    local j = i
    while NUMBER_CHARS[string.byte(s, j) or 0] do j = j + 1 end
    local n = tonumber(string.sub(s, i, j - 1))
    if n == nil then error("json: bad number at " .. i) end
    return n, j
end

local function decodeArray(s, i, depth)
    local out = {}
    i = skipWs(s, i + 1)
    if string.byte(s, i) == 93 then return out, i + 1 end
    while true do
        local v
        v, i = decodeValue(s, i, depth + 1)
        out[#out + 1] = v
        i = skipWs(s, i)
        local c = string.byte(s, i)
        if c == 93 then return out, i + 1 end
        if c ~= 44 then error("json: expected , or ] at " .. i) end
        i = skipWs(s, i + 1)
    end
end

local function decodeObject(s, i, depth)
    local out = {}
    i = skipWs(s, i + 1)
    if string.byte(s, i) == 125 then return out, i + 1 end
    while true do
        if string.byte(s, i) ~= 34 then error("json: expected key at " .. i) end
        local k
        k, i = decodeString(s, i)
        i = skipWs(s, i)
        if string.byte(s, i) ~= 58 then error("json: expected : at " .. i) end
        local v
        v, i = decodeValue(s, skipWs(s, i + 1), depth + 1)
        out[k] = v
        i = skipWs(s, i)
        local c = string.byte(s, i)
        if c == 125 then return out, i + 1 end
        if c ~= 44 then error("json: expected , or } at " .. i) end
        i = skipWs(s, i + 1)
    end
end

decodeValue = function(s, i, depth)
    if depth > 32 then error("json: nesting too deep") end
    i = skipWs(s, i)
    local c = string.byte(s, i)
    if c == 123 then return decodeObject(s, i, depth) end
    if c == 91 then return decodeArray(s, i, depth) end
    if c == 34 then return decodeString(s, i) end
    if c == 116 and string.sub(s, i, i + 3) == "true" then return true, i + 4 end
    if c == 102 and string.sub(s, i, i + 4) == "false" then return false, i + 5 end
    if c == 110 and string.sub(s, i, i + 3) == "null" then return nil, i + 4 end
    if c and NUMBER_CHARS[c] then return decodeNumber(s, i) end
    error("json: unexpected character at " .. i)
end

-- 성공: value / 실패: nil, 오류 메시지
function Json.decode(s)
    if type(s) ~= "string" or s == "" then return nil, "empty" end
    local ok, value, nextIndex = pcall(decodeValue, s, 1, 0)
    if not ok then return nil, value end
    if skipWs(s, nextIndex) <= string.len(s) then return nil, "json: trailing data" end
    return value
end

return Json
