-- Network actions under a Cancel dialog. Started from a tap, run/wrap return
-- before the action ends; started inside a running action, they just run fn
-- under that action's dialog and return its results.
local ButtonDialog = require("ui/widget/buttondialog")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Cancellable = {
    CANCELLED = {},
}

local widget -- dialog of the running action, if any

-- Runs fn as a network action under a Cancel dialog
function Cancellable.run(text, fn)
    if widget then
        return fn()
    end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected(function()
            Cancellable.run(text, fn)
        end)
        return
    end
    Trapper:wrap(function()
        local dialog
        local cancelled = false
        dialog = ButtonDialog:new{
            title = text,
            dismissable = false,
            buttons = { { {
                text = _("Cancel"),
                callback = function()
                    cancelled = true
                    UIManager:close(dialog)
                    -- Trapper sets dismiss_callback per Cancellable.call and never clears it; still safe,
                    -- because taps are only dispatched while a call is yielding, so it's always current
                    if dialog.dismiss_callback then
                        dialog.dismiss_callback()
                    end
                end,
            } } },
        }
        UIManager:show(dialog)
        UIManager:forceRePaint()
        widget = dialog
        -- traceback taken before unwinding, so Trapper's log points at the real error
        local ok, err = xpcall(fn, function(e)
            return e == Cancellable.CANCELLED and e or debug.traceback(e)
        end)
        widget = nil
        if not cancelled then
            UIManager:close(dialog)
        end
        if not ok and err ~= Cancellable.CANCELLED then
            error(err, 0)
        end
    end)
end

function Cancellable.wrap(text, fn)
    return function(...)
        local args, n = { ... }, select("#", ...)
        return Cancellable.run(text, function()
            return fn(unpack(args, 1, n))
        end)
    end
end

-- Runs fn in a subprocess the Cancel dialog can kill. Only fn's first two
-- return values come back; capture more here if a caller ever needs them.
function Cancellable.call(fn)
    if not widget then
        error("AO3Downloader.koplugin: request outside Cancellable.run", 2)
    end
    local completed, a, b = Trapper:dismissableRunInSubprocess(fn, widget)
    if not completed then
        error(Cancellable.CANCELLED, 0)
    end
    return a, b
end

return Cancellable
