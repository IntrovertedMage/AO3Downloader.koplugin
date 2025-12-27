local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local logger = require("logger")
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

local Fanfic = WidgetContainer:extend{
    name = "AO3 downloader",
    is_doc_only = false,
    menu_stack = {}
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

    local replace = {
        ["%I"] = metadata.id,
        ["%T"] = metadata.title:gsub("%s+", "_"),
        ["%A"] = metadata.author:gsub("%s+", "_"),
    }
    return template:gsub("(%%%a)", replace)
end

function Fanfic:onShowFanficBrowser(ficResults, fetchNextPage)
    logger.dbg("AO3Downloader.koplugin: Showing fanfic browser")
    FanficBrowser:show(
        self.ui,
        ficResults,
        fetchNextPage,
        function(fanfic) self:UpdateFanfic(fanfic) end, -- Update callback
        function(fanficId) self:DownloadFanfic(fanficId) end, -- Download callback
        function (author)
            -- Check if author contains pseud, if yes parse the pseud (format: "pseeud (username)" or username)
            local username
            local pseud

            if string.find(author, "%(") and string.find(author, "%)") then
                username = string.match(author, "%((.-)%)")
                pseud = string.match(author, "^(.-)%s*%(")
            else
                username = author
                pseud = author
            end
            logger.dbg("Opening user browser for author: " .. username .. " pseud: " .. pseud)
            self:showUserInfo(username, pseud)

        end,-- Open author user browser callback
        self
    )

end

function Fanfic:DownloadFanfic(id)
    local NetworkMgr = require("ui/network/manager")

    logger.dbg("id:" .. id)
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected(function () self:DownloadFanfic(id) end)
        return
    end

    -- Fetch metadata for the work
    local request_result  = AO3DownloaderClient:getWorkMetadata(id)
    if not request_result.success then
        UIManager:show(InfoMessage:new{
            text = _("Error: failed to fetch work metadata: ") .. (request_result.error or "Unknown error")
        })
        return
    end

    -- Extract the EPUB link from the metadata
    local url = request_result.work_metadata.epub_link
    if not url then
        UIManager:show(InfoMessage:new{
            text = _("Error: EPUB link not found for this work")
        })
        return
    end

    os.execute("sleep " .. math.random(1, 3))

    local filename = self.GenerateFileName(request_result.work_metadata)
    -- Download the EPUB file
    local download_request_result = AO3DownloaderClient:downloadEpub(url, Config:readSetting("fanfic_folder_path") .. "/" .. filename .. ".epub")
    if not download_request_result.success then
        UIManager:show(InfoMessage:new{
            text = _("Error: failed to download and write EPUB, " .. (download_request_result.error_message or ""))
        })
        return
    end

    -- Save metadata of the downloaded fanfic
    local fanfic = {
        id = id,
        path = download_request_result.filepath,
        title = request_result.work_metadata.title,
        author = request_result.work_metadata.author,
        chapters = request_result.work_metadata.chapters,
        chapter_data = request_result.work_metadata.chapterData,
        summary = request_result.work_metadata.summary,
        fandoms = request_result.work_metadata.fandoms,
        tags = request_result.work_metadata.tags,
        relationships = request_result.work_metadata.relationships,
        characters = request_result.work_metadata.characters,
        warnings = request_result.work_metadata.warnings,
        hits = request_result.work_metadata.hits,
        kudos = request_result.work_metadata.kudos,
        bookmarks = request_result.work_metadata.bookmarks,
        comments = request_result.work_metadata.comments,
        last_accessed = os.date("%Y-%m-%d %H:%M:%S"), --current date
        rating = request_result.work_metadata.rating,
        category = request_result.work_metadata.category,
        iswip = request_result.work_metadata.iswip,
        updated = request_result.work_metadata.updated,
        published = request_result.work_metadata.published,
        wordcount = request_result.work_metadata.wordcount,
    }

    if fanfic.chapter_data then
        for idx, __ in pairs(fanfic.chapter_data) do
            fanfic.chapter_data[idx].read = false
        end
    end

    DownloadedFanfics.add(fanfic)



    -- Show confirmation dialog
    UIManager:show(ConfirmBox:new{
        text = T(_("File saved to:\n%1\nWould you like to read the downloaded work now?"), BD.filepath(fanfic.path)),
        ok_text = _("Read now"),
        ok_callback = function()
            self:onOpenFanficReader(fanfic.path, fanfic)
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
    local request_result  = AO3DownloaderClient:getWorkMetadata(fanfic.id)
    if not request_result.success then
        UIManager:show(InfoMessage:new{
            text = T("Error: failed to fetch updated metadata: %1", request_result.error_message or "Unknown error")
        })
        return
    end

    -- Extract the EPUB link from the metadata
    local url = request_result.work_metadata.epub_link
    if not url then
        UIManager:show(InfoMessage:new{
            text = _("Error: EPUB link not found for this work")
        })
        return
    end

    os.execute("sleep " .. math.random(2, 5)) -- Random delay between 2-5 seconds

    -- Re-download the EPUB file
    local download_request_result = AO3DownloaderClient:downloadEpub(url, fanfic.path)
    if not download_request_result.success then
        UIManager:show(InfoMessage:new{
            text = "Error: failed to download and write updated EPUB"
        })
        return
    end


    -- Update the metadata and file path
    fanfic.path = fanfic.path
    fanfic.title = request_result.work_metadata.title or fanfic.title
    fanfic.date = request_result.work_metadata.date or fanfic.date
    fanfic.chapters = request_result.work_metadata.chapters or fanfic.chapters
    fanfic.author = request_result.work_metadata.author or fanfic.author
    fanfic.fandoms = request_result.work_metadata.fandoms or fanfic.fandoms
    fanfic.summary = request_result.work_metadata.summary or fanfic.summary
    fanfic.tags = request_result.work_metadata.tags or fanfic.tags
    fanfic.relationships = request_result.work_metadata.relationships or fanfic.relationships
    fanfic.characters = request_result.work_metadata.characters or fanfic.characters
    fanfic.warnings = request_result.work_metadata.warnings or fanfic.warnings
    fanfic.hits = request_result.work_metadata.hits or fanfic.hits
    fanfic.kudos = request_result.work_metadata.kudos or fanfic.kudos
    fanfic.bookmarks = request_result.work_metadata.bookmarks or fanfic.bookmarks
    fanfic.comments = request_result.work_metadata.comments or fanfic.comments
    fanfic.last_accessed = os.date("%Y-%m-%d %H:%M:%S") -- Update last_accessed field
    fanfic.rating = request_result.work_metadata.rating or fanfic.rating
    fanfic.category = request_result.work_metadata.category or fanfic.category
    fanfic.iswip = request_result.work_metadata.iswip or fanfic.iswip
    fanfic.updated = request_result.work_metadata.updated or fanfic.updated
    fanfic.published = request_result.work_metadata.published or fanfic.published
    fanfic.wordcount = request_result.work_metadata.wordcount or fanfic.wordcount

    if #fanfic.chapter_data == 0 and not (request_result.work_metadata.chapterData == 0) then
        fanfic.read = nil
    end

    if fanfic.chapter_data then
        for idx, chapter in pairs(fanfic.chapter_data) do
            if request_result.work_metadata.chapterData[idx] then
                request_result.work_metadata.chapterData[idx].read = chapter.read or false
            end
        end
    end

    fanfic.chapter_data = request_result.work_metadata.chapterData



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
        logger.dbg("fetching page:"..currentPage)
        local next_page_results =  AO3DownloaderClient:searchByTag(selectedFandom, sortBy, currentPage)
        if not next_page_results.success then
            UIManager:show(InfoMessage:new{
                text = T("Error: %1", next_page_results.error),
                icon = "notice-warning",
            })
        end

        return next_page_results.result_works
    end

    -- Fetch the first page of results
    local search_results = AO3DownloaderClient:searchByTag(selectedFandom, sortBy, currentPage)

    if not search_results.success then
        UIManager:show(InfoMessage:new{
            text = T("Error: %1", search_results.error),
            icon = "notice-warning",
        })
        return false
    end

    return true, search_results.result_works, fetchNextPage

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
        local request_result = AO3DownloaderClient:searchByParameters(parameters, currentPage)

        if not request_result.success then
            UIManager:show(InfoMessage:new{
                text = _("Error: ") .. (request_result.error or "Unknown error"),
            })
            currentPage = currentPage - 1
            return false
        end

        -- no more works to fetch
        if #request_result.works == 0 then
            currentPage = currentPage - 1
            return {}
        end

        return request_result.works
    end

    -- Fetch the first page of results
    local request_result = AO3DownloaderClient:searchByParameters(parameters, currentPage)

    if not request_result.success then
        UIManager:show(InfoMessage:new{
            text = _("Error: ") .. (request_result.error or "Unknown error"),
        })
        return false
    end

    return true, request_result.works, fetchNextPage
end


function Fanfic:searchForUsers(query)
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected()
        return false, {}
    end
    local search_results = AO3DownloaderClient:searchForUsers(query)
    if not search_results.success then
        UIManager:show(InfoMessage:new{
            text = "Error: User search request failed. " .. (search_results.error or "Unknown error"),
        })
        return false
    end

    logger.dbg(search_results.result_users)

    local current_page = 1

    local function getNextPage()
        current_page = current_page + 1
        local next_page_result = AO3DownloaderClient:searchForUsers(query, current_page)
        if not next_page_result.success then
            current_page = current_page - 1
            UIManager:show(InfoMessage:new{
                text = "Error: User search request failed. " .. (next_page_result.error or "Unknown error"),
            })
            return {}
        end

        -- no more users to fetch
        if #next_page_result.result_users == 0 then
            current_page = current_page - 1
            return {}
        end

        return  next_page_result.result_users
    end

    return true,search_results.result_users, getNextPage
end

function Fanfic:showUserInfo(username, pseud)
    local AO3UserBrowser = require("AO3_user_browser")
    local request_result = AO3DownloaderClient:getUserData(username, pseud)
    if not request_result.success then
        UIManager:show(InfoMessage:new{
            text = T("Error: Failed to fetch user info: %1", request_result.error or "Unknown error"),
        })
        return
    end
    AO3UserBrowser:show(request_result.user_data, self.ui, self)
end

function Fanfic:getUserData(username, pseud)
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected()
        return false, {}
    end
    local user_data_result = AO3DownloaderClient:getUserData(username, pseud)
    if not user_data_result.success then
        UIManager:show(InfoMessage:new{
            text = "Error: Failed to fetch user data: " .. (user_data_result.error or "Unknown error"),
        })
        return false
    end

    return true, user_data_result.user_data

end

function Fanfic:getWorksFromUserPage(username, pseud, category, fandom_id)
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected()
        return false, {}
    end
    local works_result = AO3DownloaderClient:getWorksFromUserPage(username, pseud, category, fandom_id)
    if not works_result.success then
        UIManager:show(InfoMessage:new{
            text = "Error: Failed to fetch works from user page: " .. (works_result.error or "Unknown error"),
        })
        return false
    end

    local currentPage = 1

    local function getNextPage()
        currentPage = currentPage + 1
        local next_page_result = AO3DownloaderClient:getWorksFromUserPage(username, pseud, category, fandom_id, currentPage)
        if not next_page_result.success then
            currentPage = currentPage - 1
            UIManager:show(InfoMessage:new{
                text = "Error: Failed to fetch works from user page: " .. (next_page_result.error or "Unknown error"),
            })
            return {}
        end

        -- no more works to fetch
        if #next_page_result.works == 0 then
            currentPage = currentPage - 1
            return {}
        end

        return  next_page_result.works
    end

    return true, works_result.works, getNextPage

end

function Fanfic:getPseudsForUser(username)
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected()
        return false, {}
    end
    local pseuds_result = AO3DownloaderClient:getUserPseuds(username)
    if not pseuds_result.success then
        UIManager:show(InfoMessage:new{
            text = "Error: Failed to fetch pseuds for user: " .. (pseuds_result.error or "Unknown error"),
        })
        return false
    end

    return true, pseuds_result.pseuds

end

function Fanfic:getSeriesFromUserPage(username)
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected()
        return false, {}
    end
    local series_result = AO3DownloaderClient:getUserSeries(username)
    if not series_result.success then
        UIManager:show(InfoMessage:new{
            text = "Error: Failed to fetch series from user page: " .. (series_result.error or "Unknown error"),
        })
        return false
    end

    return true, series_result.series

end

function Fanfic:getWorksFromSeries(series_id)
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected()
        return false, {}
    end
    local works_result = AO3DownloaderClient:getWorksFromSeries(series_id)
    if not works_result.success then
        UIManager:show(InfoMessage:new{
            text = "Error: Failed to fetch works from series: " .. (works_result.error or "Unknown error"),
        })
        return false
    end

    local currentpage = 1

    local function fetchNextPage()
        currentpage = currentpage + 1
        local next_page_result = AO3DownloaderClient:getWorksFromSeries(series_id, currentpage)
        if not next_page_result.success then
            currentpage = currentpage - 1
            UIManager:show(InfoMessage:new{
                text = "Error: Failed to fetch works from series: " .. (next_page_result.error or "Unknown error"),
            })
            return {}
        end

        -- no more works to fetch
        if #next_page_result.works == 0 then
            currentpage = currentpage - 1
            return {}
        end

        return  next_page_result.works

    end

    return true, works_result.works, fetchNextPage

end

function Fanfic:searchForTags(query, type)
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected()
        return false, {}
    end
    local search_results = AO3DownloaderClient:searchForTags(query, type)
    if not search_results.success then
        UIManager:show(InfoMessage:new{
            text = "Error: Tag search request failed. " .. (search_results.error or "Unknown error"),
        })
        return false
    end
    return true,search_results.result_tags
end

function Fanfic:checkLoggedIn()
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected()
        return
    end
    local request_result = AO3DownloaderClient:GetSessionStatus()
    if not request_result.success then
        UIManager:show(InfoMessage:new{
            text = "Error: Check logged in request failed. " .. (request_result.error or "Unknown error"),
        })
    end

    -- Check logged in status using the Downloader module
    return request_result.success, request_result.logged_in, request_result.username

end

function Fanfic:loginToAO3(username, password)
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected()
        return false
    end

    -- Attempt to log in using the Downloader module
    local request_result = AO3DownloaderClient:startLoggedInSession(username, password)

    if request_result.success then
        UIManager:show(InfoMessage:new{
            text = "Login successful! Welcome, " .. username .. "!",
        })
        return true
    else
        UIManager:show(InfoMessage:new{
            text = "Failed to log in. Error:" .. (request_result.error or "Unknown error"),
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
    local request_result = AO3DownloaderClient:endLoggedInSession()


    if request_result.success then
        UIManager:show(InfoMessage:new{
            text = _("Successfully logged out"),
        })
        return true
    else
        UIManager:show(InfoMessage:new{
            text = _("Error: Failed to log out. ") .. (request_result.error or "Unknown error"),
        })
        return false
    end
end

return Fanfic
