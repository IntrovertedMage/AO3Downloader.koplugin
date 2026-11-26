local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local BD = require("ui/bidi")
local DownloadedFanfics = require("downloaded_fanfics")
local FanficBrowser = require("fanficbrowser")
local FanficMenu = require("fanfic_menu")
local FanficReader = require("fanfic_reader")
local Config = require("fanfic_config")
local Event = require("ui/event")
local Dispatcher = require("dispatcher")
local AO3DownloaderClient = require("AO3_downloader_client")
local Cancellable = require("cancellable")
local UIResult = require("ui_result")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")

local Fanfic = WidgetContainer:extend{
    name = "AO3 downloader",
    is_doc_only = false,
    menu_stack = {}
}

local unwrap = UIResult.unwrap

local stale_part_files_checked = false

-- Delete leftover ".part" files from cancelled or killed EPUB downloads.
local function removeStalePartFiles()
    if stale_part_files_checked then
        return
    end
    stale_part_files_checked = true
    local folder = Config:readSetting("fanfic_folder_path")
    if lfs.attributes(folder, "mode") ~= "directory" then
        return
    end
    for name in lfs.dir(folder) do
        if name:match("%.epub%.part$") then
            os.remove(folder .. "/" .. name)
        end
    end
end

function Fanfic:init()
    if self.ui.name == "ReaderUI" then
        FanficReader:initializeFromReaderUI(self.ui)
    else
        self.ui.menu:registerToMainMenu(self)
    end

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    DownloadedFanfics.load() -- Load fanfic history
    removeStalePartFiles()
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

    self.menu = FanficMenu:show(self)
    UIManager:show(self.menu)
end

function Fanfic:onOpenFanficReader(fanfic_path, current_fanfic, start_chapter)
    self:closeAllMenus()
    FanficReader:show({
        fanfic_path = fanfic_path,
        current_fanfic = current_fanfic,
        chapter_opening_at = start_chapter,
    })
end

function Fanfic:closeAllMenus()
    for menu_widget, _ in pairs(self.menu_stack) do
        if menu_widget then
            UIManager:close(menu_widget)
        end
    end
    self.menu_stack = {}
end

function Fanfic.GenerateFileName(metadata)
    local template = Config:readSetting("filename_template", "%I")
    -- local template = "%T--%A--(%I)"
    local function sanitize(value)
        return util.getSafeFilename(tostring(value or ""))
    end

    local replace = {
        ["%I"] = sanitize(metadata.id),
        ["%T"] = sanitize(metadata.title):gsub("%s+", "_"),
        ["%A"] = sanitize(metadata.author):gsub("%s+", "_"),
    }
    return sanitize((template:gsub("(%%%a)", replace)))
end

-- Shows the works from fetchPage(page), a paged client call, under a Cancel dialog.
function Fanfic:browse(text, fetchPage, total)
    Cancellable.run(text, function()
        local pager = UIResult.paged(fetchPage)
        if pager then
            FanficBrowser:show(self, pager, pager.items.total or total)
        end
    end)
end

local function fetchWorkMetadata(id)
    local metadata = unwrap(AO3DownloaderClient:getWorkMetadata(id))
    if metadata and not metadata.epub_link then
        UIResult.showError("EPUB link not found for this work")
        return
    end
    return metadata
end

-- Downloads the EPUB to fanfic.path, then refreshes and stores its record; returns true on success.
local function saveWork(fanfic, metadata)
    if not unwrap(AO3DownloaderClient:downloadEpub(metadata.epub_link, fanfic.path)) then
        return false
    end
    DownloadedFanfics.storeDownload(fanfic, metadata)
    return true
end

-- Returns true once saved, when called inside another action (see Cancellable).
Fanfic.DownloadFanfic = Cancellable.wrap(_("Downloading work…"), function(self, id)
    local metadata = fetchWorkMetadata(id)
    if not metadata then
        return
    end

    local fanfic = {
        id = id,
        path = Config:readSetting("fanfic_folder_path") .. "/" .. self.GenerateFileName(metadata) .. ".epub",
    }
    if not saveWork(fanfic, metadata) then
        return
    end

    UIManager:show(ConfirmBox:new{
        text = T(_("File saved to:\n%1\nWould you like to read the downloaded work now?"), BD.filepath(fanfic.path)),
        ok_text = _("Read now"),
        ok_callback = function()
            self:onOpenFanficReader(fanfic.path, fanfic)
        end,
    })
    return true
end)

Fanfic.UpdateFanfic = Cancellable.wrap(_("Downloading work…"), function(self, fanfic)
    local metadata = fetchWorkMetadata(fanfic.id)
    if not metadata or not saveWork(fanfic, metadata) then
        return
    end

    UIManager:show(InfoMessage:new{
        text = T(_("Fanfic '%1' has been updated successfully."), fanfic.title),
    })
end)

Fanfic.showUserInfo = Cancellable.wrap(_("Loading profile…"), function(self, username, pseud)
    local user_data = unwrap(AO3DownloaderClient:getUserData(username, pseud))
    if user_data then
        require("AO3_user_browser"):show(user_data, self.ui, self)
    end
end)

return Fanfic
