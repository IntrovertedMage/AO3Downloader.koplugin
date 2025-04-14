local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local logger = require("logger")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local Downloader = require("AO3downloader")
local InfoMessage = require("ui/widget/infomessage")
local Paths = require("FanficPaths")
local socket = require("socket")
local ReaderUI = require("apps/reader/readerui")
local KeyValuePage = require("ui/widget/keyvaluepage")
local ConfirmBox = require("ui/widget/confirmbox")
local BD = require("ui/bidi")
local Menu = require("ui/widget/menu")
local Config = require("config")
local json = require("dkjson")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local ButtonDialog = require("ui/widget/buttondialog")
local TextViewer = require("ui/widget/textviewer")
local DownloadedFanfics = require("downloaded_fanfics")
local FanficBrowser = require("fanficbrowser")
local FanficMenu = require("fanfic_menu")

local Fanfic = WidgetContainer:extend{
    name = "Fanfic downloader",
    is_doc_only = false,
}

function Fanfic:init()
    lfs.mkdir(Paths:getHomeDirectory())
    lfs.mkdir(Paths:getHomeDirectory().."/Downloads/")
    self.ui.menu:registerToMainMenu(self)
    DownloadedFanfics.load() -- Load fanfic history
end

function Fanfic:addToMainMenu(menu_items)
    if self.ui.file_chooser then
        menu_items.fanfic = {
            text = _("Fanfiction downloader"),
            sorting_hint = "search",
            callback = function()
                self.menu = FanficMenu:show(self)
                UIManager:show(self.menu)
            end,
        }
    end
end



function Fanfic:DownloadFanfic(id, parentMenu)
    local NetworkMgr = require("ui/network/manager")

    logger.dbg("id:" .. id)
    if NetworkMgr:willRerunWhenOnline(function()
                self:DownloadFanfic(id)
            end) then
        return
    end

    -- Fetch metadata for the work
    local metadata, error_message = Downloader:getWorkMetadata(id)
    if not metadata then
        UIManager:show(InfoMessage:new{
            text = _("Error: failed to fetch work metadata: ") .. (error_message or "Unknown error")
        })
        return
    end

    -- Extract the EPUB link from the metadata
    local url = metadata.epub_link
    if not url then
        UIManager:show(InfoMessage:new{
            text = _("Error: EPUB link not found for this work")
        })
        return
    end

    os.execute("sleep " .. math.random(2, 5)) -- Random delay between 2-5 seconds

    -- Download the EPUB file
    local succeeded, path = Downloader:downloadEpub(url, tostring(id))
    if not succeeded then
        UIManager:show(InfoMessage:new{
            text = _("Error: failed to download and write EPUB")
        })
        return
    end

    -- Save metadata of the downloaded fanfic
    local fanfic = {
        id = id,
        path = path,
        title = (metadata.title or T("Fanfic #%1", id)),
        author = metadata.author or "Unknown",
        date = metadata.date or "Unknown",
        chapters = metadata.chapters or "Unknown",
        summary = metadata.summary or "No summary available",
        fandoms = metadata.fandoms or {},
        tags = metadata.tags or {},
        relationships = metadata.relationships or {},
        characters = metadata.characters or {},
        warnings = metadata.warnings or {},
        hits = metadata.hits or "0",
        kudos = metadata.kudos or "0",
        bookmarks = metadata.bookmarks or "0",
        comments = metadata.comments or "0",
        last_accessed = os.date("%Y-%m-%d %H:%M:%S"), -- Add last_accessed field
        rating = metadata.rating or "Unknown",
        category = metadata.category or "Unknown",
        iswip = metadata.iswip or "Unknown",
        updated = metadata.updated or "Unknown",
        published = metadata.published or "Unknown"
    }
    DownloadedFanfics.add(fanfic)

    -- Show confirmation dialog
    UIManager:show(ConfirmBox:new{
        text = T(_("File saved to:\n%1\nWould you like to read the downloaded book now?"), BD.filepath(path)),
        ok_text = _("Read now"),
        ok_callback = function()
            if self.ui.document then
                self.ui:switchDocument(path)
            else
                self.ui:openFile(path)
            end
            if parentMenu then
                parentMenu:onClose()
            end
            self.menu:onClose()
        end,
    })
end

function Fanfic:UpdateFanfic(fanfic)
    local NetworkMgr = require("ui/network/manager")

    if NetworkMgr:willRerunWhenOnline(function()
                self:UpdateFanfic(fanfic)
            end) then
        return
    end

    -- Fetch updated metadata for the work
    local metadata, error_message = Downloader:getWorkMetadata(fanfic.id)
    if not metadata then
        UIManager:show(InfoMessage:new{
            text = _("Error: failed to fetch updated metadata: ") .. (error_message or "Unknown error")
        })
        return
    end

    -- Extract the EPUB link from the metadata
    local url = metadata.epub_link
    if not url then
        UIManager:show(InfoMessage:new{
            text = _("Error: EPUB link not found for this work")
        })
        return
    end

    os.execute("sleep " .. math.random(2, 5)) -- Random delay between 2-5 seconds

    -- Re-download the EPUB file
    local succeeded, path = Downloader:downloadEpub(url, tostring(fanfic.id))
    if not succeeded then
        UIManager:show(InfoMessage:new{
            text = _("Error: failed to download and write updated EPUB")
        })
        return
    end

    -- Update the metadata and file path
    fanfic.path = path
    fanfic.title = metadata.title or fanfic.title
    fanfic.date = metadata.date or fanfic.date
    fanfic.chapters = metadata.chapters or fanfic.chapters
    fanfic.author = metadata.author or fanfic.author
    fanfic.fandoms = metadata.fandoms or fanfic.fandoms
    fanfic.summary = metadata.summary or fanfic.summary
    fanfic.tags = metadata.tags or fanfic.tags
    fanfic.relationships = metadata.relationships or fanfic.relationships
    fanfic.characters = metadata.characters or fanfic.characters
    fanfic.warnings = metadata.warnings or fanfic.warnings
    fanfic.hits = metadata.hits or fanfic.hits
    fanfic.kudos = metadata.kudos or fanfic.kudos
    fanfic.bookmarks = metadata.bookmarks or fanfic.bookmarks
    fanfic.comments = metadata.comments or fanfic.comments
    fanfic.last_accessed = os.date("%Y-%m-%d %H:%M:%S") -- Update last_accessed field
    fanfic.rating = metadata.rating or fanfic.rating
    fanfic.category = metadata.category or fanfic.category
    fanfic.iswip = metadata.iswip or fanfic.iswip
    fanfic.updated = metadata.updated or fanfic.updated
    fanfic.published = metadata.published or fanfic.published

    DownloadedFanfics.update(fanfic)

    -- Show confirmation dialog
    UIManager:show(InfoMessage:new{
        text = T(_("Fanfic '%1' has been updated successfully."), fanfic.title),
    })
end



function Fanfic:fetchFanficsByTag(selectedFandom, sortBy)
    local NetworkMgr = require("ui/network/manager")

    local success, ficResults, fetchNextPage
    if NetworkMgr:willRerunWhenOnline(function()
            success, ficResults, fetchNextPage =  self:fetchFanficsByFandom(selectedFandom, sortBy)
        end) then
        return false
    end

    local currentPage = 1

    -- Define the function to fetch the next page for the selected fandom
    local function fetchNextPage()
        currentPage = currentPage + 1
        logger.dbg("currentpagefetching:"..currentPage)
        return Downloader:searchByTag(selectedFandom, currentPage, sortBy)
    end

    -- Fetch the first page of results
    local ficResults = Downloader:searchByTag(selectedFandom, currentPage, sortBy)

    if not ficResults then
        UIManager:show(InfoMessage:new{
            text = _("Error: Failed to fetch fanfics for the selected fandom.")
        })
        return false
    end

    return true, ficResults, fetchNextPage

end


function Fanfic:executeSearch(parameters)
    local NetworkMgr = require("ui/network/manager")

    local success, works, fetchNextPage
    if NetworkMgr:willRerunWhenOnline(function()
                success, works, fetchNextPage = self:executeSearch(parameters)
            end) then
        return success, works, fetchNextPage
    end
    local currentPage = 1

    -- Define the function to fetch the next page for the search parameters
    local function fetchNextPage()
        currentPage = currentPage + 1
        return Downloader:searchFic(parameters, currentPage)
    end

    -- Fetch the first page of results
    local works, error_message = Downloader:searchFic(parameters, currentPage)

    if not works then
        UIManager:show(InfoMessage:new{
            text = _("Error: ") .. (error_message or "Unknown error"),
        })
        return false
    end

    return true, works, fetchNextPage
end

function Fanfic:onShowFanficBrowser(parentMenu, ficResults, fetchNextPage)
    FanficBrowser:show(
        self.ui,
        parentMenu,
        ficResults,
        fetchNextPage,
        function(fanfic) self:UpdateFanfic(fanfic) end, -- Update callback
        function(fanficId, parentMenu) self:DownloadFanfic(fanficId, parentMenu) end -- Download callback
    )
end


function Fanfic:fetchFandomSearch(query)
    local NetworkMgr = require("ui/network/manager")
    local success, works
    if NetworkMgr:willRerunWhenOnline(function()
                success, works  = self:fetchFandomSearch(query)
            end) then
        return success, works
    end
    if query == "" then
        UIManager:show(InfoMessage:new{
            text = _("Error: No search query entered."),
        })
        return
    end


    -- Fetch matching fandoms
    local fandoms, error_message = Downloader:searchForTag(query, "Fandom")
    if not fandoms then
        UIManager:show(InfoMessage:new{
            text = _("Error: ") .. (error_message or "Unknown error"),
        })
        return false
    end

    return true, fandoms
end

function Fanfic:onSearchFandoms()
    -- Show an input dialog to enter the fandom search query
    local searchDialog
    searchDialog = InputDialog:new{
        title = _("Search Fandoms"),
        input = "",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Close"),
                    id = "close",
                    callback = function()
                        UIManager:close(searchDialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local query = searchDialog:getInputText()
                        if query == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Error: No search query entered."),
                            })
                            return
                        end

                        UIManager:close(searchDialog)

                        -- Fetch matching fandoms
                        local fandoms, error_message = Downloader:searchForTag(query)
                        if not fandoms then
                            UIManager:show(InfoMessage:new{
                                text = _("Error: ") .. (error_message or "Unknown error"),
                            })
                            return
                        end

                        -- Show the matching fandoms in a menu
                        local menu_items = {}
                        for _, fandom in ipairs(fandoms) do
                            table.insert(menu_items, {
                                text = T("%1 (works: %2)", fandom.name, fandom.uses),
                                callback = function()
                                    self:onBrowseByFandom(fandom.name)
                                end,
                            })
                        end
                        self.fandomMenu:GoDownInMenu("Select a Fandom", menu_items)
                    end,
                },
            }
        },
    }

    UIManager:show(searchDialog)
    searchDialog:onShowKeyboard()
end


function Fanfic:searchForTags(query, type)
    local tags, error_message = Downloader:searchForTag(query, type)
    return tags
end
return Fanfic
