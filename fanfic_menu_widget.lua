local Menu = require("ui/widget/menu")
local _ = require("gettext")
local UIManager = require("ui/uimanager")
local util = require("util")
local MenuStack = require("menu_stack")

function util.contains(table, value)
    for _, v in ipairs(table) do
        if v == value then
            return true
        end
    end
    return false
end

local FanficMenuWidget = Menu:extend({
    is_popout = false,
    is_borderless = true,
    paths = nil,
    title = "AO3 downloader",
    subtitle = "",
    lock_return = false,
})

-- Menu action on return-arrow tap (go to one-level upper catalog)
function FanficMenuWidget:onReturn()
    if self.lock_return then
        return
    end
    local path = self.paths[#self.paths]
    if path then
        self:switchItemTable(path.title, path.items, -1, -1, path.subtitle)
        self.title = path.title
        self.subtitle = path.subtitle
        table.remove(self.paths, #self.paths)
    end
    return true
end

function FanficMenuWidget:GoDownInMenu(newTitle, newItems, newSubtitle)
    table.insert(self.paths, {
        title = self.title,
        items = self.item_table,
        subtitle = self.subtitle,
    })
    self:switchItemTable(newTitle, newItems, -1, -1, newSubtitle)
    self.title = newTitle
    self.subtitle = newSubtitle
end

function FanficMenuWidget:updateMenuBack(backAmount, newTitle, newItems, newSubtitle)
    local currentBackMenu = self.paths[#self.paths]
    local index = #self.paths - (backAmount - 1)
    self.paths[index].title = newTitle or currentBackMenu.title
    self.paths[index].items = newItems or currentBackMenu.items
    self.paths[index].subtitle = newSubtitle or currentBackMenu.subtitle
end

function FanficMenuWidget:onClose()
    MenuStack.menu_stack[self] = nil
    return Menu.onClose(self)
end

function FanficMenuWidget:onSwipe(arg, ges_ev)
    local direction = ges_ev.direction
    if direction == "west" then
        self:onNextPage()
    elseif direction == "east" then
        self:onPrevPage()
    elseif direction == "south" then
        if not self.no_title then
            -- If there is a titlebar with a close button displayed (so, this Menu can be
            -- closed), allow easier closing with swipe south.
            if #self.paths == 0 then
                self:onClose()
            end
            self:onReturn()
        end
        -- If there is no close button, it's a top level Menu and swipe
        -- up/down may hide/show top menu
    elseif direction == "north" then
        -- no use for now
        do end -- luacheck: ignore 541
    else -- diagonal swipe
        -- trigger full refresh
        UIManager:setDirty(nil, "full")
    end
end

return FanficMenuWidget