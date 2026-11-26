-- Every public method returns its value on success, or nil and an error message.
-- Methods make requests, so they must run inside Cancellable.run (one action at a time);
-- calling one outside raises.
local logger = require("logger")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local Config = require("fanfic_config")
local HTTPQueryHandler = require("ao3_http")
local AO3WebParser = require("ao3_parser")
local htmlparser = require("htmlparser")
local json = require("rapidjson")
htmlparser_looplimit = 1000000000

local AO3DownloaderClient = {}

local function failure(error_message, result)
    return nil, T("%1 Status: %2", error_message, result.error or result.status or "unknown error")
end

-- Returns the parsed page, or nil and an error; opts.not_found replaces the message on a 404.
local function getPage(url, error_message, opts)
    local result, body = HTTPQueryHandler.get(url, opts)
    if not result.success then
        if result.status == 404 and opts and opts.not_found then
            return nil, opts.not_found
        end
        return failure(error_message, result)
    end
    return htmlparser.parse(body)
end

-- Returns parse(root) for the page at url, or nil and an error.
local function parsePage(url, error_message, parse, opts)
    local root, err = getPage(url, error_message, opts)
    if not root then
        return nil, err
    end
    return parse(root)
end

local function getJSON(url, error_message)
    local result, body = HTTPQueryHandler.get(url, { json = true })
    if not result.success then
        return failure(error_message, result)
    end
    local data = json.decode(body)
    if not data then
        return nil, T("%1 Invalid JSON response.", error_message)
    end
    return data
end

-- POSTs a form; returns the result and body when its status is one of ok_statuses, else nil and an error.
local function postAction(url, fields, ok_statuses, error_message, opts)
    local result, body = HTTPQueryHandler.postForm(url, fields, opts)
    for _, status in ipairs(ok_statuses) do
        if result.status == status then
            return result, body
        end
    end
    return failure(error_message, result)
end

local function fetchToken()
    logger.dbg("AO3Downloader.koplugin: Requesting AO3 token…")
    local data, err = getJSON(Config:getAO3Domain() .. "/token_dispenser.json", "Failed to request AO3 token.")
    if data and not data.token then
        data, err = nil, "AO3 token not found in response."
    end
    if not data then
        return nil, T("Failed to retrieve AO3 token: %1", err)
    end
    return data.token
end

-- Returns the session, or nil and an error unless logged in.
local function requireLogin(action)
    local session, err = AO3DownloaderClient:GetSessionStatus()
    if not session then
        return nil, T("Failed to check login status: %1", err)
    end
    if not session.logged_in then
        return nil, T("User must be logged in to %1.", action)
    end
    return session
end

-- Like requireLogin, with a fresh authenticity token in session.token.
local function requireLoginToken(action)
    local session, err = requireLogin(action)
    if not session then
        return nil, err
    end
    session.token, err = fetchToken()
    if not session.token then
        return nil, err
    end
    return session
end

-- Follows a login/logout redirect and checks the page body has the expected class.
local function followSessionRedirect(result, error_message, body_class, mismatch_message)
    local root, err = getPage(result.response_headers["location"] or Config:getAO3Domain(), error_message)
    if not root then
        return nil, err
    end
    if #root:select("body." .. body_class) == 0 then
        return nil, mismatch_message
    end
    return true
end

function AO3DownloaderClient:startLoggedInSession(username, password)
    local homepage_url = Config:getAO3Domain()

    local homepage = HTTPQueryHandler.get(homepage_url)
    if not homepage.success then
        return failure("Failed to access AO3 homepage.", homepage)
    end

    local token, err = fetchToken()
    if not token then
        return nil, err
    end

    local result
    result, err = postAction(homepage_url .. "/users/login", {
        ["authenticity_token"] = token,
        ["user[login]"] = username,
        ["user[password]"] = password,
        ["commit"] = "Log In",
    }, { 302 }, "Login failed.")
    if not result then
        return nil, err
    end

    return followSessionRedirect(result, "Failed to complete login redirect.", "logged-in",
        "Login failed. Please check your credentials.")
end

function AO3DownloaderClient:endLoggedInSession()
    logger.dbg("AO3Downloader.koplugin: Ending logged-in AO3 session…")
    local token, err = fetchToken()
    if not token then
        return nil, err
    end

    local result
    result, err = postAction(Config:getAO3Domain() .. "/users/logout", {
        ["_method"] = "delete",
        ["authenticity_token"] = token,
    }, { 302 }, "Failed to perform logout request.")
    if not result then
        return nil, err
    end

    return followSessionRedirect(result, "Failed to complete logout redirect.", "logged-out",
        "Logout may have failed; still appears to be logged in.")
end

-- Returns { logged_in, username }.
function AO3DownloaderClient:GetSessionStatus()
    logger.dbg("AO3Downloader.koplugin: Checking AO3 session status…")
    local root, err = getPage(Config:getAO3Domain(), "Failed to access AO3 homepage.")
    if not root then
        return nil, err
    end

    if #root:select("body.logged-in") == 0 then
        return { logged_in = false }
    end

    for _, link in ipairs(root:select('a[href^="/users/"]')) do
        local username = link.attributes and link.attributes.href and link.attributes.href:match("^/users/([^/]+)$")
        if username then
            return { logged_in = true, username = username }
        end
    end
    return nil, "Failed to parse username from AO3 homepage."
end

function AO3DownloaderClient:getWorkMetadata(work_id)
    logger.dbg("AO3Downloader.koplugin: Fetching metadata for work ID: " .. tostring(work_id))
    local work_metadata, err = parsePage(T("%1/works/%2", Config:getAO3Domain(), work_id), "Failed to fetch work metadata.",
        AO3WebParser.parseWorkPage, { cookies = { ["view_adult"] = "true" } })
    if work_metadata then
        work_metadata.id = work_id
        work_metadata.epub_link = work_metadata.epub_href and Config:getAO3Domain() .. work_metadata.epub_href
        work_metadata.epub_href = nil
    end
    return work_metadata, err
end

-- Returns the filepath written.
function AO3DownloaderClient:downloadEpub(download_link, filepath)
    logger.dbg("AO3Downloader.koplugin: Downloading EPUB from link: " .. tostring(download_link) .. " to filepath: " .. tostring(filepath))
    if not download_link or not download_link:match("^https?://") then
        return nil, T("Invalid or missing URL for EPUB download: %1", tostring(download_link))
    end

    local result = HTTPQueryHandler.get(download_link, {
        headers = { ["Accept"] = "application/epub+zip" },
        filepath = filepath,
    })
    if not result.success then
        return failure("Failed to download EPUB.", result)
    end

    return filepath
end

local function listWorks(url, error_message)
    return parsePage(url, error_message, AO3WebParser.parseWorkSearchResults)
end

function AO3DownloaderClient:searchByParameters(parameters, page_no)
    logger.dbg("AO3Downloader.koplugin: Executing work search by parameters. Page no: " .. tostring(page_no))
    local query = { commit = "Sort and Filter", page = page_no or 1 }
    for key, value in pairs(parameters) do
        query[key] = value
    end
    return listWorks(HTTPQueryHandler.withQuery(Config:getAO3Domain() .. "/works", query), "Search request failed.")
end

function AO3DownloaderClient:searchByTag(tag_name, sort_by, page_no)
    logger.dbg("AO3Downloader.koplugin: Executing work search by tag: " .. tostring(tag_name) .. ", page no: " .. tostring(page_no))
    local encoded_tag_name = tag_name
        :gsub("/", "*s*")
        :gsub("&", "*a*")
        :gsub("%.", "*d*")

    local url = HTTPQueryHandler.withQuery(T("%1/tags/%2/works", Config:getAO3Domain(), HTTPQueryHandler.encode(encoded_tag_name)), {
        page = page_no or 1,
        ["work_search[sort_column]"] = sort_by or "revised_at",
    })
    return listWorks(url, "Search request failed.")
end

function AO3DownloaderClient:searchForTags(search_query, tag_type)
    logger.dbg("AO3Downloader.koplugin: Executing tag search for query: " .. tostring(search_query) .. ", tag type: " .. tostring(tag_type))
    if not search_query or search_query == "" then
        return nil, "Tag search query cannot be empty"
    end

    local url = HTTPQueryHandler.withQuery(Config:getAO3Domain() .. "/tags/search", {
        ["tag_search[name]"] = search_query,
        ["tag_search[fandoms]"] = "",
        ["tag_search[type]"] = tag_type or "Fandom",
        ["tag_search[wrangling_status]"] = "canonical",
        ["tag_search[sort_column]"] = "uses",
        ["tag_search[sort_direction]"] = "desc",
        commit = "Search Tags",
    })
    return parsePage(url, "HTTP tag search request failed.", AO3WebParser.parseTagSearchResults)
end

function AO3DownloaderClient:getWorksFromSeries(series_id, page_no)
    logger.dbg("AO3Downloader.koplugin: Fetching works from series ID: " .. tostring(series_id) .. ", page no: " .. tostring(page_no))
    return listWorks(T("%1/series/%2?page=%3", Config:getAO3Domain(), series_id, page_no or 1), "Failed to fetch series works.")
end

function AO3DownloaderClient:getWorksFromCollection(collection_id, page_no)
    logger.dbg("AO3Downloader.koplugin: Fetching works from collection ID: " .. tostring(collection_id) .. ", page no: " .. tostring(page_no))
    return listWorks(T("%1/collections/%2/works?page=%3", Config:getAO3Domain(), collection_id, page_no or 1), "Failed to fetch collection works.")
end

function AO3DownloaderClient:getWorksFromUserPage(username, pseud, category, fandom_id, page_no)
    logger.dbg("AO3Downloader.koplugin: Fetching works from user page. Username: " .. tostring(username) .. ", category: " .. tostring(category) .. (fandom_id and (", fandom ID: " .. tostring(fandom_id)) or "") .. ", page no: " .. tostring(page_no))
    local url
    if category == "gifts" then
        url = T("%1/users/%2/gifts", Config:getAO3Domain(), username)
    else
        url = T("%1/users/%2/pseuds/%3/%4", Config:getAO3Domain(), username, pseud, category)
    end
    url = HTTPQueryHandler.withQuery(url, { fandom_id = fandom_id, page = page_no or 1 })

    local parse = category == "bookmarks" and AO3WebParser.parseUserBookmarks or AO3WebParser.parseWorkSearchResults
    return parsePage(url, "Failed to fetch user works.", parse)
end

function AO3DownloaderClient:getWorksFromAccountHistory(marked_for_later, page_no)
    local session, err = requireLogin(marked_for_later and "access the marked for later list" or "access account history")
    if not session then
        return nil, err
    end

    logger.dbg("AO3Downloader.koplugin: Fetching works from account history page. Username: " .. tostring(session.username) .. ", page no: " .. tostring(page_no))
    local url = HTTPQueryHandler.withQuery(T("%1/users/%2/readings", Config:getAO3Domain(), session.username), {
        show = marked_for_later and "to-read" or "",
        page = page_no or 1,
    })
    return parsePage(url, "Failed to fetch account history.", AO3WebParser.parseAccountHistory)
end

function AO3DownloaderClient:getUserSeries(username, pseud, page_no)
    logger.dbg("AO3Downloader.koplugin: Fetching series for user: " .. tostring(username) .. ", page no: " .. tostring(page_no))
    return parsePage(T("%1/users/%2/pseuds/%3/series?page=%4", Config:getAO3Domain(), username, pseud, page_no or 1),
        "Failed to fetch user series.", AO3WebParser.parseUserSeriesPage)
end

function AO3DownloaderClient:getUserCollections(username, page_no)
    logger.dbg("AO3Downloader.koplugin: Fetching collections for user: " .. tostring(username) .. ", page no: " .. tostring(page_no))
    return parsePage(T("%1/users/%2/collections?page=%3", Config:getAO3Domain(), username, page_no or 1),
        "Failed to fetch user collections.", AO3WebParser.parseUserCollectionsPage)
end

function AO3DownloaderClient:getUserData(username, pseud)
    local user_data, err = parsePage(T("%1/users/%2/pseuds/%3", Config:getAO3Domain(), username, pseud),
        "Failed to fetch user data.", AO3WebParser.parseUserPage, { not_found = T("User '%1' not found.", username) })
    if user_data then
        user_data.username = username
    end
    return user_data, err
end

function AO3DownloaderClient:getUserPseuds(username)
    return parsePage(T("%1/users/%2/pseuds", Config:getAO3Domain(), username),
        "Failed to fetch user pseuds.", AO3WebParser.parseUserPseuds, { not_found = T("User '%1' not found.", username) })
end

function AO3DownloaderClient:getAccountPseudID(username)
    local pseud_id, err = parsePage(T("%1/users/%2/pseuds/%2/edit", Config:getAO3Domain(), username),
        "Failed to fetch account pseud ID.", AO3WebParser.parseAccountPseudID,
        { not_found = T("Pseud edit page for '%1' not found.", username) })
    if pseud_id == false then
        return nil, "Failed to parse account pseud ID"
    end
    return pseud_id, err
end

function AO3DownloaderClient:searchForUsers(search_query, page_no)
    logger.dbg("AO3Downloader.koplugin: Executing user search for query: " .. tostring(search_query) .. ", page no: " .. tostring(page_no))
    if not search_query or search_query == "" then
        return nil, "User search query cannot be empty"
    end

    local url = HTTPQueryHandler.withQuery(Config:getAO3Domain() .. "/people/search", {
        ["people_search[query]"] = search_query,
        page = page_no or 1,
    })
    return parsePage(url, "HTTP user search request failed.", AO3WebParser.parseUserSearchResults)
end

function AO3DownloaderClient:searchForCollections(search_query)
    logger.dbg("AO3Downloader.koplugin: Executing collection search for query: " .. tostring(search_query))
    if not search_query or search_query == "" then
        return nil, "Collection search query cannot be empty"
    end

    local url = HTTPQueryHandler.withQuery(Config:getAO3Domain() .. "/autocomplete/collection_title", { term = search_query })
    return getJSON(url, "HTTP collection search request failed.")
end

function AO3DownloaderClient:kudosWork(work_id)
    logger.dbg("AO3Downloader.koplugin: Sending kudos to work. Work ID: " .. tostring(work_id))
    local session, err = requireLoginToken("kudos works")
    if not session then
        return nil, err
    end

    local result
    result, err = postAction(Config:getAO3Domain() .. "/kudos.js", {
        ["authenticity_token"] = session.token,
        ["kudo[commentable_id]"] = tostring(work_id),
        ["kudo[commentable_type]"] = "Work",
    }, { 201, 422 }, "Failed to kudos work.")
    if not result then
        return nil, err
    end
    if result.status == 422 then
        return nil, "You have already left kudos here. :)"
    end
    return true
end

function AO3DownloaderClient:commentOnWork(comment_content, work_id, chapter_id)
    logger.dbg("AO3Downloader.koplugin: Posting comment on work. Work ID: " .. tostring(work_id) .. ", chapter ID: " .. tostring(chapter_id))

    if not comment_content or comment_content == "" then
        return nil, "Comment content cannot be empty."
    end
    if comment_content:len() > 10000 then
        return nil, "Comment content exceeds maximum length of 10,000 characters."
    end

    local session, err = requireLogin("comment on works")
    if not session then
        return nil, err
    end

    local comment_url = Config:getAO3Domain()
        .. ((chapter_id and ("/chapters/" .. chapter_id)) or ("/works/" .. work_id))
        .. "/comments"

    local root
    root, err = getPage(comment_url, "Failed to fetch comment form.", { cookies = { ["view_adult"] = "true" } })
    if not root then
        return nil, err
    end

    local form = root:select("#comment_for_" .. (chapter_id or work_id))[1]
    local token_input = form and form:select("[name='authenticity_token']")[1]
    local pseud_input = form and form:select("[name='comment[pseud_id]']")[1]
    if not token_input or not pseud_input then
        return nil, "Failed to retrieve necessary tokens for commenting from comment form."
    end

    local result
    result, err = postAction(comment_url, {
        ["authenticity_token"] = token_input.attributes["value"],
        ["comment[pseud_id]"] = pseud_input.attributes["value"],
        ["comment[comment_content]"] = comment_content,
        ["controller_name"] = "comments",
        ["commit"] = "Comment",
    }, { 200, 201, 302 }, "Failed to post comment.", {
        headers = { ["Referer"] = comment_url },
        cookies = { ["user_credentials"] = "1", ["view_adult"] = "true" },
    })
    return result and true, err
end

-- later_or_read: true marks as read, false marks for later.
function AO3DownloaderClient:markForLaterWork(work_id, later_or_read)
    logger.dbg("AO3Downloader.koplugin: Marking work. Work ID: " .. tostring(work_id))
    local session, err = requireLoginToken("mark work")
    if not session then
        return nil, err
    end

    local url = T("%1/works/%2/%3", Config:getAO3Domain(), work_id, later_or_read and "mark_as_read" or "mark_for_later")
    local result
    result, err = postAction(url, {
        ["authenticity_token"] = session.token,
        ["_method"] = "patch",
    }, { 302 }, "Failed to mark work.")
    return result and true, err
end

-- Subscribes, or unsubscribes when subscription_id is given; returns { subscription_id } (nil once unsubscribed).
function AO3DownloaderClient:setWorkSubscription(work_id, subscription_id)
    logger.dbg("AO3Downloader.koplugin: Setting subscription. Work ID: " .. tostring(work_id))
    local session, err = requireLoginToken("subscribe")
    if not session then
        return nil, err
    end

    local url = T("%1/users/%2/subscriptions", Config:getAO3Domain(), session.username)
    local form = {
        ["authenticity_token"] = session.token,
        ["subscription[subscribable_id]"] = tostring(work_id),
        ["subscription[subscribable_type]"] = "Work",
    }
    if subscription_id then
        url = url .. "/" .. subscription_id
        form["_method"] = "delete"
    end

    local result, body = postAction(url, form, { 201, 302, 200 }, "Failed to update subscription.",
        { json = true, headers = { ["X-CSRF-Token"] = session.token } })
    if not result then
        return nil, body
    end

    local decoded = result.status == 201 and json.decode(body)
    return { subscription_id = decoded and tostring(decoded.item_id) or nil }
end

-- Returns { bookmark_id, data }, or {} when the user hasn't bookmarked the work.
function AO3DownloaderClient:getUsersWorkBookmark(work_id)
    logger.dbg("AO3Downloader.koplugin: Fetching bookmark for work. Work ID: " .. tostring(work_id))
    local session, err = requireLogin("fetch bookmarks")
    if not session then
        return nil, err
    end

    local work_root
    work_root, err = getPage(T("%1/works/%2/bookmarks", Config:getAO3Domain(), work_id), "Failed to fetch bookmark.")
    if not work_root then
        return nil, err
    end

    local trigger = work_root:select("a.bookmark_form_trigger_for_" .. work_id)[1]
    if not trigger then
        return nil, T("Bookmark button not found for work ID: %1", work_id)
    end
    if trigger:getcontent() ~= "Edit Bookmark" then
        return {}
    end

    local href = trigger.attributes["href"]
    local data
    data, err = parsePage(Config:getAO3Domain() .. href, "Failed to fetch bookmark form.", AO3WebParser.parseUsersWorkBookmark)
    if not data then
        return nil, err
    end
    return { bookmark_id = href:match("/bookmarks/(%d+)/edit"), data = data }
end

-- Creates the bookmark, or updates it when bookmark_id is given; returns { bookmark_id }.
function AO3DownloaderClient:updateBookmark(work_id, bookmark_id, notes, tags, collections, private, rec)
    logger.dbg("AO3Downloader.koplugin: Updating bookmark. Work ID: " .. tostring(work_id))
    local session, err = requireLoginToken("edit bookmarks")
    if not session then
        return nil, err
    end

    local url
    local form = {
        ["authenticity_token"] = session.token,
        ["bookmark[bookmarker_notes]"] = notes or "",
        ["bookmark[tag_string]"] = tags or "",
        ["bookmark[collection_names]"] = collections or "",
        ["bookmark[private]"] = private and "1" or "0",
        ["bookmark[rec]"] = rec and "1" or "0",
    }

    if bookmark_id then
        url = T("%1/bookmarks/%2", Config:getAO3Domain(), bookmark_id)
        form["_method"] = "put"
        form["commit"] = "Update"
    else
        url = T("%1/works/%2/bookmarks", Config:getAO3Domain(), work_id)
        form["commit"] = "Create"
        local pseud_id
        pseud_id, err = self:getAccountPseudID(session.username)
        if not pseud_id then
            return nil, T("Error: %1", err)
        end
        form["bookmark[pseud_id]"] = tostring(pseud_id)
    end

    local result, body = postAction(url, form, { 302, 200 }, "Failed to update bookmark.",
        { headers = { ["X-CSRF-Token"] = session.token } })
    if not result then
        return nil, body
    end

    local error_message = AO3WebParser.parseFormError(htmlparser.parse(body))
    if error_message then
        return nil, T("Failed to update bookmark. Error message: %1", error_message)
    end

    local location = result.response_headers and result.response_headers["location"]
    return { bookmark_id = location and location:match("/bookmarks/(%d+)") }
end

function AO3DownloaderClient:deleteBookmark(bookmark_id)
    logger.dbg("AO3Downloader.koplugin: Deleting bookmark. Bookmark ID: " .. tostring(bookmark_id))
    local session, err = requireLoginToken("delete bookmarks")
    if not session then
        return nil, err
    end

    local result
    result, err = postAction(T("%1/bookmarks/%2", Config:getAO3Domain(), bookmark_id), {
        ["authenticity_token"] = session.token,
        ["_method"] = "delete",
    }, { 302 }, "Failed to delete bookmark.", { headers = { ["X-CSRF-Token"] = session.token } })
    return result and true, err
end

return AO3DownloaderClient
