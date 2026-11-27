local _ = require("gettext")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local logger = require("logger")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local BD = require("ui/bidi")
local DownloadedFanfics = require("downloaded_fanfics")
local FanficReader = require("fanfic_reader")
local Config = require("fanfic_config")
local AO3DownloaderClient = require("AO3_downloader_client")
local util = require("util")

local AO3Manager = {}

function AO3Manager:generateFileName(metadata)
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

function AO3Manager:DownloadFanfic(id)
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

    local filename = self:generateFileName(request_result.work_metadata)
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
        language = request_result.work_metadata.language,
        chapter_data = request_result.work_metadata.chapterData,
        summary = request_result.work_metadata.summary,
        fandoms = request_result.work_metadata.fandoms,
        series = request_result.work_metadata.series,
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
        markedForLater = request_result.work_metadata.markedForLater,
        subscriptionID = request_result.work_metadata.subscriptionID,
        bookmarkID = request_result.work_metadata.bookmarkID,
        bookmarkContent = request_result.work_metadata.bookmarkContent
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

            FanficReader:show({
                fanfic_path = fanfic.path,
                current_fanfic = fanfic,
                chapter_opening_at = nil,
            })

        end,
    })
end

function AO3Manager:UpdateFanfic(fanfic, metadataOnly)
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

    if not metadataOnly then
        -- Extract the EPUB link from the metadata
        local url = request_result.work_metadata.epub_link
        if not url then
            UIManager:show(InfoMessage:new {
                text = _("Error: EPUB link not found for this work")
            })
            return
        end

        os.execute("sleep " .. math.random(2, 5)) -- Random delay between 2-5 seconds

        -- Re-download the EPUB file
        local download_request_result = AO3DownloaderClient:downloadEpub(url, fanfic.path)
        if not download_request_result.success then
            UIManager:show(InfoMessage:new {
                text = "Error: failed to download and write updated EPUB"
            })
            return
        end
    end

    -- Update the metadata and file path
    fanfic.path = fanfic.path
    fanfic.title = request_result.work_metadata.title or fanfic.title
    fanfic.chapters = request_result.work_metadata.chapters or fanfic.chapters
    fanfic.language = request_result.work_metadata.language or fanfic.language
    fanfic.author = request_result.work_metadata.author or fanfic.author
    fanfic.fandoms = request_result.work_metadata.fandoms or fanfic.fandoms
    fanfic.series = request_result.work_metadata.series or fanfic.series
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
    fanfic.markedForLater = request_result.work_metadata.markedForLater
    fanfic.subscriptionID = request_result.work_metadata.subscriptionID
    fanfic.bookmarkID = request_result.work_metadata.bookmarkID
    fanfic.bookmarkContent = request_result.work_metadata.bookmarkContent

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

function AO3Manager:fetchFanficsByTag(selectedFandom, sortBy)

    local filter = {
        sort_by = sortBy,
        main_tag = selectedFandom,
        type = "works"
    }
    local status, searchResult = AO3Manager:executeSearch(filter)

    return status, searchResult

end

function AO3Manager:getWorksFromAccountHistory(marked_for_later)
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected()
        return false
    end

    local currentPage = 1

    -- Fetch the first page of results
    local status, searchResult = AO3DownloaderClient:getWorksFromAccountHistory(marked_for_later, currentPage)

    if not status then
        UIManager:show(InfoMessage:new{
            text = T("Error: %1", searchResult.error),
            icon = "notice-warning",
        })
        return false
    end

    -- Define the function to fetch the next page for the selected fandom
    searchResult.fetchNextPage = function()
        currentPage = currentPage + 1
        local status, searchResult =  AO3DownloaderClient:getWorksFromAccountHistory(marked_for_later, currentPage)
        if not status then
            UIManager:show(InfoMessage:new{
                text = T("Error: %1", searchResult.error),
                icon = "notice-warning",
            })
        end

        return searchResult.works
    end

    return true, searchResult

end

function AO3Manager:executeSearch(filter)
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected()
        return false, {}
    end
    
    local currentPage = 1

    -- Fetch the first page of results
    local status, searchResult = AO3DownloaderClient:searchByFilter(filter, currentPage)
    if not status then
        UIManager:show(InfoMessage:new{
            text = _("Error: ") .. (searchResult.error or "Unknown error"),
        })
        return false, {}
    end

    -- Define the function to fetch the next page for the search parameters
    searchResult.fetchNextPage = function()
        currentPage = currentPage + 1
        local status, searchResult = AO3DownloaderClient:searchByFilter(filter, currentPage)

        if not status then
            UIManager:show(InfoMessage:new{
                text = _("Error: ") .. (searchResult.error or "Unknown error"),
            })
            currentPage = currentPage - 1
            return false
        end

        -- no more works to fetch
        if #searchResult.works == 0 then
            currentPage = currentPage - 1
            return {}
        end

        return searchResult.works
    end

    return true, searchResult
end

function AO3Manager:searchForUsers(query)
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

function AO3Manager:showUserInfo(username, pseud)
    local AO3UserBrowser = require("AO3_user_browser")
    local request_result = AO3DownloaderClient:getUserData(username, pseud)
    if not request_result.success then
        UIManager:show(InfoMessage:new{
            text = T("Error: Failed to fetch user info: %1", request_result.error or "Unknown error"),
        })
        return
    end
    AO3UserBrowser:show(request_result.user_data)
end

function AO3Manager:getUserData(username, pseud)
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

function AO3Manager:getWorksFromUserPage(username, pseud, category, fandom_name)
    local filter = {
        user_id = username,
        pseud_id = pseud,
        type = category,
        fandom_names = {fandom_name}
    }
    local status, searchResult = AO3Manager:executeSearch(filter)

    return status, searchResult
end

function AO3Manager:getPseudsForUser(username)
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

function AO3Manager:getSeriesFromUserPage(username, pseud)
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected()
        return false, {}
    end


    local current_page = 1

    local series_result = AO3DownloaderClient:getUserSeries(username, pseud, current_page)

    local function getNextPage()
        current_page = current_page + 1
        local next_page_result = AO3DownloaderClient:getUserSeries(username, pseud, current_page)
        if not next_page_result.success then
            current_page = current_page - 1
            UIManager:show(InfoMessage:new{
                text = "Error: Failed to fetch series from users page: " .. (next_page_result.error or "Unknown error"),
            })
            return {}
        end

        -- no more series to fetch
        if #next_page_result.series == 0 then
            current_page = current_page - 1
            return {}
        end

        return  next_page_result.series

    end
    if not series_result.success then
        UIManager:show(InfoMessage:new{
            text = "Error: Failed to fetch series from users page: " .. (series_result.error or "Unknown error"),
        })
        return false
    end

    return true, series_result.series, getNextPage

end

function AO3Manager:getWorksFromUserGifts(username)
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected()
        return false
    end

    local currentPage = 1

    -- Fetch the first page of results
    local status, searchResult = AO3DownloaderClient:getWorksFromUserGifts(username, currentPage)

    if not status then
        UIManager:show(InfoMessage:new{
            text = T("Error: %1", searchResult.error),
            icon = "notice-warning",
        })
        return false, searchResult
    end

    -- Define the function to fetch the next page for the selected fandom
    searchResult.fetchNextPage = function()
        currentPage = currentPage + 1
        local status, searchResult =  AO3DownloaderClient:getWorksFromUserGifts(username, currentPage)
        if not status then
            UIManager:show(InfoMessage:new{
                text = T("Error: %1", searchResult.error),
                icon = "notice-warning",
            })
        end

        return searchResult.works
    end

    return true, searchResult

end

function AO3Manager:getCollectionsFromUserPage(username)
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected()
        return false, {}
    end

    local currentPage = 1

    local works_result = AO3DownloaderClient:getUserCollections(username, currentPage)
    if not works_result.success then
        UIManager:show(InfoMessage:new{
            text = "Error: Failed to fetch collections from users collections page: " .. (works_result.error or "Unknown error"),
        })
        return false
    end


    local function getNextPage()
        currentPage = currentPage + 1
        local next_page_result = AO3DownloaderClient:getUserCollections(username, currentPage)
        if not next_page_result.success then
            currentPage = currentPage - 1
            UIManager:show(InfoMessage:new{
                text = "Error: Failed to fetch collections from users collections page: " .. (next_page_result.error or "Unknown error"),
            })
            return {}
        end

        -- no more works to fetch
        if #next_page_result.collections == 0 then
            currentPage = currentPage - 1
            return {}
        end

        return  next_page_result.collections
    end

    return true, works_result.collections, getNextPage
end

function AO3Manager:getWorksFromSeries(series_id)
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected()
        return false, {}
    end
    local status, searchResult = AO3DownloaderClient:getWorksFromSeries(series_id)
    if not status then
        UIManager:show(InfoMessage:new{
            text = "Error: Failed to fetch works from series: " .. (searchResult.error or "Unknown error"),
        })
        return false, {}
    end

    local currentpage = 1

    searchResult.fetchNextPage = function()
        currentpage = currentpage + 1
        local status, searchResult = AO3DownloaderClient:getWorksFromSeries(series_id, currentpage)
        if not status then
            currentpage = currentpage - 1
            UIManager:show(InfoMessage:new{
                text = "Error: Failed to fetch works from series: " .. (searchResult.error or "Unknown error"),
            })
            return {}
        end

        -- no more works to fetch
        if #searchResult.works == 0 then
            currentpage = currentpage - 1
            return {}
        end

        return searchResult.works

    end

    return true, searchResult

end

function AO3Manager:getWorksFromCollection(collection_id)
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected()
        return false, {}
    end
    local status, searchResult = AO3DownloaderClient:getWorksFromCollection(collection_id)
    if not status then
        UIManager:show(InfoMessage:new{
            text = "Error: Failed to fetch works from collection: " .. (searchResult.error or "Unknown error"),
        })
        return false
    end

    local currentpage = 1

    searchResult.fetchNextPage = function()
        currentpage = currentpage + 1
        local status, searchResult = AO3DownloaderClient:getWorksFromCollection(collection_id, currentpage)
        if not status then
            currentpage = currentpage - 1
            UIManager:show(InfoMessage:new{
                text = "Error: Failed to fetch works from collection: " .. (searchResult.error or "Unknown error"),
            })
            return {}
        end

        -- no more works to fetch
        if #searchResult.works == 0 then
            currentpage = currentpage - 1
            return {}
        end

        return  searchResult.works

    end

    return true, searchResult

end

function AO3Manager:searchForTags(query, type)
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

function AO3Manager:checkLoggedIn()
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

function AO3Manager:loginToAO3(username, password)
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

function AO3Manager:logoutOfAO3()
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

return AO3Manager