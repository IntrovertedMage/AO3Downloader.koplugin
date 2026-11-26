-- Network actions under a wait message. A function that starts an action
-- (run/wrap) is a tap target: it returns before the action ends, and it may
-- not be called from inside another action.
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")

local Cancellable = {}

local running = false

-- Runs fn as a network action under a wait message
function Cancellable.run(text, fn)
    if running then
        error("AO3Downloader.koplugin: Cancellable.run inside another action", 2)
    end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected(function()
            Cancellable.run(text, fn)
        end)
        return
    end
    local message = InfoMessage:new{ text = text }
    UIManager:show(message)
    UIManager:forceRePaint()
    running = true
    local ok, err = xpcall(fn, debug.traceback)
    running = false
    UIManager:close(message)
    if not ok then
        error(err, 0)
    end
end

function Cancellable.wrap(text, fn)
    return function(...)
        local args, n = { ... }, select("#", ...)
        Cancellable.run(text, function()
            return fn(unpack(args, 1, n))
        end)
    end
end

-- Runs a request; only valid inside Cancellable.run.
function Cancellable.call(fn)
    if not running then
        error("AO3Downloader.koplugin: request outside Cancellable.run", 2)
    end
    return fn()
end

return Cancellable
