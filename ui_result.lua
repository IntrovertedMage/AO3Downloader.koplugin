-- Turns client results (value, or nil and an error) into UI feedback.
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("gettext")

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

-- Fetches page 1 of fetchPage(page); returns nil after showing the error, else a pager:
-- pager.items is every item so far, pager.done is set once AO3 has no more pages.
function UIResult.paged(fetchPage)
    local items = UIResult.unwrap(fetchPage(1))
    if not items then
        return nil
    end
    local pager = { items = items, page = 1, done = false }

    -- Appends the next page; returns true when callers should rebuild, nil after showing an error.
    -- noun names the items in the "No more …" notice.
    function pager:loadMore(noun)
        local more = UIResult.unwrap(fetchPage(self.page + 1))
        if not more then
            return nil
        end
        if #more == 0 then
            self.done = true
            UIManager:show(InfoMessage:new{ text = T(_("No more %1."), noun), timeout = 2 })
        end
        self.page = self.page + 1
        for _, item in ipairs(more) do
            table.insert(self.items, item)
        end
        return true
    end

    return pager
end

return UIResult
