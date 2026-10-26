local UIManager = require("ui/uimanager")

local MenuStack = {
    menu_stack = {}
}

function MenuStack:closeAllMenus()
    for menu_widget, _ in pairs(self.menu_stack) do
        if menu_widget then
            UIManager:close(menu_widget)
        end
    end
    self.menu_stack = {}
end

return MenuStack