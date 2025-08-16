local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local logger = require("logger")
local UIManager = require("ui/uimanager")
local Downloader = require("AO3downloader")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local BD = require("ui/bidi")
local DownloadedFanfics = require("downloaded_fanfics")
local FanficBrowser = require("fanficbrowser")
local FanficMenu = require("fanfic_menu")
local FanficReader = require("fanfic_reader")
local Config = require("fanfic_config")
local util = require("util")

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

    self.ui.menu:registerToMainMenu(self)
    DownloadedFanfics.load() -- Load fanfic history
end

function Fanfic:addToMainMenu(menu_items)
    if self.ui.file_chooser then
        menu_items.AO3_downloader = {
            text = "AO3 Downloader",
            sorting_hint = "search",
            callback = function()
                self.menu = FanficMenu:show(self)
                UIManager:show(self.menu)
            end,
        }
    end
end

local function GenerateFileName(metadata)
    local template = Config:readSetting("filename_template", "%I")
    -- local template = "%T--%A--(%I)"

    local replace = {
        ["%I"] = metadata.id,
        ["%T"] = metadata.title:gsub("%s+", "_"),
        ["%A"] = metadata.author:gsub("%s+", "_"),
    }
    return template:gsub("(%%%a)", replace)
end

function Fanfic:DownloadFanfic(id)
    local NetworkMgr = require("ui/network/manager")

    logger.dbg("id:" .. id)
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected(function () self:DownloadFanfic(id) end)
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

    os.execute("sleep " .. math.random(1, 3))

    local filename = GenerateFileName(metadata)
    -- Download the EPUB file
    local succeeded, path = Downloader:downloadEpub(url, filename)
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
        title = metadata.title,
        author = metadata.author,
        chapters = metadata.chapters,
        chapter_data = metadata.chapterData,
        summary = metadata.summary,
        fandoms = metadata.fandoms,
        tags = metadata.tags,
        relationships = metadata.relationships,
        characters = metadata.characters,
        warnings = metadata.warnings,
        hits = metadata.hits,
        kudos = metadata.kudos,
        bookmarks = metadata.bookmarks,
        comments = metadata.comments,
        last_accessed = os.date("%Y-%m-%d %H:%M:%S"), --current date
        rating = metadata.rating,
        category = metadata.category,
        iswip = metadata.iswip,
        updated = metadata.updated,
        published = metadata.published,
        wordcount = metadata.wordcount,
    }

    if fanfic.chapter_data then
        for idx, __ in pairs(fanfic.chapter_data) do
            fanfic.chapter_data[idx].read = false
        end
    end

    DownloadedFanfics.add(fanfic)



    -- Show confirmation dialog
    UIManager:show(ConfirmBox:new{
        text = T(_("File saved to:\n%1\nWould you like to read the downloaded work now?"), BD.filepath(path)),
        ok_text = _("Read now"),
        ok_callback = function()
            if self.menu.browse_window then
                self.menu.browse_window:onClose()
            end

            self.menu:onClose()
            FanficReader:show({
                fanfic_path = fanfic.path,
                current_fanfic = fanfic,
            })

        end,
    })
end

function Fanfic:UpdateFanfic(fanfic)
    local NetworkMgr = require("ui/network/manager")

    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected(function () self:UpdateFanfic(fanfic) end)
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

    local filename = GenerateFileName(metadata)
    -- Re-download the EPUB file
    local succeeded, path = Downloader:downloadEpub(url, filename)
    if not succeeded then
        UIManager:show(InfoMessage:new{
            text = _("Error: failed to download and write updated EPUB")
        })
        return
    end

    -- delete old file if filename has changed since last update
    if path ~= fanfic.path then
        util.removeFile(fanfic.path)
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
    fanfic.wordcount = metadata.wordcount or fanfic.wordcount

    if #fanfic.chapter_data == 0 and not (metadata.chapterData == 0) then
        fanfic.read = nil
    end

    if fanfic.chapter_data then
        for idx, chapter in pairs(fanfic.chapter_data) do
            if metadata.chapterData[idx] then
                metadata.chapterData[idx].read = chapter.read or false
            end
        end
    end

    fanfic.chapter_data = metadata.chapterData



    DownloadedFanfics.update(fanfic)

    -- Show confirmation dialog
    UIManager:show(InfoMessage:new{
        text = T(_("Fanfic '%1' has been updated successfully."), fanfic.title),
    })
end

function Fanfic:fetchFanficsByTag(selectedFandom, sortBy)
    local NetworkMgr = require("ui/network/manager")

    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected()
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
            text = _("Error: Failed to fetch fanfics for the selected tag.")
        })
        return false
    end

    return true, ficResults, fetchNextPage

end


function Fanfic:executeSearch(parameters)
    local NetworkMgr = require("ui/network/manager")

    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected()
        return false
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

function Fanfic:searchForTags(query, type)
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected()
        return false, {}
    end
    local success, tags, error_message = Downloader:searchForTag(query, type)
    if not success then
        UIManager:show(InfoMessage:new{
            text = "Error: Tag search request failed. " .. (error_message or "Unknown error"),
        })
    end
    return success, tags
end

function Fanfic:checkLoggedIn()
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected()
        return
    end
    local success, logged_in, error_message = Downloader:getLoggedIn()
    if not success then
        UIManager:show(InfoMessage:new{
            text = "Error: Check logged in request failed. " .. (error_message or "Unknown error"),
        })
    end

    -- Check logged in status using the Downloader module
    return success, logged_in, error_message

end

function Fanfic:loginToAO3(username, password)
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected()
        return false
    end

    -- Attempt to log in using the Downloader module
    local success, error_message = Downloader:login(username, password)

    if success then
        UIManager:show(InfoMessage:new{
            text = "Login successful! Welcome, " .. username .. "!, You'll stay logged in for 2 weeks unless you choose to log out earlier",
        })
        return true
    else
        UIManager:show(InfoMessage:new{
            text = "Error: Failed to log in. " .. (error_message or "Unknown error"),
        })
        return false
    end
end

function Fanfic:logoutOfAO3()
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected()
        return false
    end

    -- Attempt to log in using the Downloader module
    local success, error_message = Downloader:logout()

    if success then
        UIManager:show(InfoMessage:new{
            text = _("Successfully logged out"),
        })
        return true
    else
        UIManager:show(InfoMessage:new{
            text = _("Error: Failed to log out. ") .. (error_message or "Unknown error"),
        })
        return false
    end
end

return Fanfic
