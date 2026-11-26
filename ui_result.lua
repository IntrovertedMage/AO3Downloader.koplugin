-- Turns client results (value, or nil and an error) into UI feedback.
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template

local UIResult = {}

-- Shows err as the plugin's single error toast.
function UIResult.showError(err)
    UIManager:show(InfoMessage:new{
        text = T("Error: %1", err or "Unknown error"),
        icon = "notice-warning",
    })
end

-- Returns value, or shows err and returns nil.
function UIResult.unwrap(value, err)
    if value == nil then
        UIResult.showError(err)
    end
    return value
end

-- Returns page 1 of fetchPage(page) and a function fetching each following page (nil on error).
function UIResult.paged(fetchPage)
    local items = UIResult.unwrap(fetchPage(1))
    if not items then
        return nil
    end
    local page = 1
    local function fetchNextPage()
        local next_items = UIResult.unwrap(fetchPage(page + 1))
        if next_items and #next_items > 0 then
            page = page + 1
        end
        return next_items
    end
    return items, fetchNextPage
end

return UIResult
