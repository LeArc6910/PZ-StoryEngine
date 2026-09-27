-- 클라이언트 ↔ 서버 명령 전달.
--
-- B42 확인 사항:
-- * sendClientCommand 는 싱글플레이에서도 내부 SinglePlayerClient 를 거쳐 OnClientCommand 로 전달된다.
-- * sendServerCommand 는 서버 프로세스(GameServer.server)에서만 동작한다.
--   싱글플레이에서는 아무 일도 하지 않으므로 클라이언트 핸들러를 직접 호출한다.

require "StoryEngine/Core"

local Net = {}
StoryEngine.Net = Net

-- 클라이언트 → 서버
function Net.toServer(player, command, args)
    sendClientCommand(player, StoryEngine.MODULE, command, args or {})
end

local function dispatchLocal(command, args)
    if StoryEngine.Client and StoryEngine.Client.dispatch then
        StoryEngine.Client.dispatch(command, args or {})
    end
end

-- 서버 → 특정 클라이언트
function Net.toClient(player, command, args)
    if isServer() then
        sendServerCommand(player, StoryEngine.MODULE, command, args or {})
    else
        dispatchLocal(command, args)
    end
end

-- 서버 → 모든 클라이언트
function Net.toAll(command, args)
    if isServer() then
        sendServerCommand(StoryEngine.MODULE, command, args or {})
    else
        dispatchLocal(command, args)
    end
end

return Net
