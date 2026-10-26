local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local UIManager = require("ui/uimanager")
local DownloadedFanfics = require("downloaded_fanfics")
local FanficMenu = require("fanfic_menu")
local FanficReader = require("fanfic_reader")
local Event = require("ui/event")
local Dispatcher = require("dispatcher")

local Fanfic = WidgetContainer:extend{
    name = "AO3 downloader",
    is_doc_only = false,
}

function Fanfic:init()
    if self.ui.name == "ReaderUI" then
        FanficReader:initializeFromReaderUI(self.ui)
    else
        self.ui.menu:registerToMainMenu(self)
    end

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    DownloadedFanfics.load() -- Load fanfic history
end

function Fanfic:addToMainMenu(menu_items)
    if self.ui.file_chooser then
        menu_items.AO3_downloader = {
            text = "AO3 Downloader",
            sorting_hint = "search",
            callback = function()
                self.ui:handleEvent(Event:new("OpenAO3DownloaderMenu"))
            end,
        }
    end
end

function Fanfic:onDispatcherRegisterActions()
    Dispatcher:registerAction("AO3Downloader_openPluginMenu", {
        category = "none",
        event = "OpenAO3DownloaderMenu",
        title = _("AO3 Downloader: open menu"),
        general = true,
    })

end

function Fanfic:onOpenAO3DownloaderMenu()
    if not self.ui.file_chooser then
        self.ui:handleEvent(Event:new("Home"))
    end

    self.menu = FanficMenu:show()
    UIManager:show(self.menu)
end

return Fanfic
