local logger = require("logger")
local socketutil = require("socketutil")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local Config = require("fanfic_config")
local HTTPQueryHandler = require("ao3_http")
local AO3WebParser = require("ao3_parser")
local encodeHelper = HTTPQueryHandler.encodeHelper
local htmlparser = require("htmlparser")
htmlparser_looplimit = 1000000000

local function getAO3URL()
    return Config:readSetting("AO3_domain")
end

local AO3DownloaderClient = {}

function AO3DownloaderClient:requestAO3Token()
    logger.dbg("AO3Downloader.koplugin: Requesting AO3 token…")
    local tokenRequestURL = getAO3URL() .. "/token_dispenser.json"

    local response_body = {}

    local headers = HTTPQueryHandler:get_default_headers()
    headers["Accept"] = "application/json, text/javascript, */*; q=0.01"
    headers["Accept-Encoding"] = nil

    local request = {
        url = tokenRequestURL,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = T("Failed to request AO3 token. Status: %1", request_result.status or "unknown error"),
        }
    end

    local html_body = table.concat(response_body)

    local json = require("rapidjson")
    local token_data = json.decode(html_body) -- rapidjson returns nil on bad JSON, it doesn't raise

    if not token_data then
        return {
            success = false,
            error = T("Failed to parse AO3 token response."),
        }
    end

    if token_data and token_data.token then
        return {
            success = true,
            token = token_data.token,
        }
    else
        return {
            success = false,
            error = T("AO3 token not found in response."),
        }
    end
end

function AO3DownloaderClient:startLoggedInSession(username, password)
    local homepage_url = getAO3URL()

    local response_body = {}

    local request = {
        url = homepage_url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = T("Failed to access AO3 homepage. Status: %1", request_result.status or "unknown error"),
        }
    end

    local ao3_token = self:requestAO3Token()

    if not ao3_token.success then
        return {
            success = false,
            error = T("Failed to retrieve AO3 token: %1", ao3_token.error or "unknown error"),
        }
    end

    local headers = HTTPQueryHandler:get_default_headers()
    headers["Content-Type"] = "application/x-www-form-urlencoded"

    local form_data = encodeHelper:generateParametersStringForm({
        ["authenticity_token"] = ao3_token.token,
        ["user[login]"] = username,
        ["user[password]"] = password,
        ["commit"] = "Log+In",
    })

    headers["Content-Length"] = tostring(#form_data)
    local response_body = {}

    local request = {
        url = homepage_url .. "/users/login",
        method = "POST",
        headers = headers,
        sink = ltn12.sink.table(response_body),
        source = ltn12.source.string(form_data),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success or request_result.status ~= 302 then
        return {
            success = false,
            error = T("Login failed. Status: %1", request_result.status or "unknown error"),
        }
    end

    local redirect_url = request_result.response_headers["location"] or homepage_url

    response_body = {}
    local request = {
        url = redirect_url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = T("Failed to complete login redirect. Status: %1", request_result.status or "unknown error"),
        }
    end

    local body_content = table.concat(response_body)

    if body_content:find('<body[^>]*class="[^"]*logged%-in[^"]*"') then
        return {
            success = true,
        }
    else
        return {
            success = false,
            error = T("Login failed. Please check your credentials."),
        }
    end
end

function AO3DownloaderClient:endLoggedInSession()
    logger.dbg("AO3Downloader.koplugin: Ending logged-in AO3 session…")
    local authenticity_token = self:requestAO3Token()

    if not authenticity_token.success then
        return {
            success = false,
            error = T("Failed to retrieve AO3 token for logout: %1", authenticity_token.error or "unknown error"),
        }
    end

    local logout_url = T("%1/users/logout", getAO3URL())

    local headers = HTTPQueryHandler:get_default_headers()
    headers["Content-Type"] = "application/x-www-form-urlencoded"

    local form_data = encodeHelper:generateParametersStringForm({
        ["_method"] = "delete",
        ["authenticity_token"] = authenticity_token.token,
    })
    headers["Content-Length"] = tostring(#form_data)

    local response_body = {}

    local request = {
        url = logout_url,
        method = "POST",
        headers = headers,
        sink = ltn12.sink.table(response_body),
        source = ltn12.source.string(form_data),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success or request_result.status ~= 302 then
        return {
            success = false,
            error = T("Failed to perform logout request. Status: %1", request_result.status or "unknown error"),
        }
    end

    local redirect_url = request_result.response_headers["location"] or getAO3URL()
    response_body = {}

    local request = {
        url = redirect_url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)
    if not request_result.success then
        return {
            success = false,
            error = T("Failed to complete logout redirect. Status: %1", request_result.status or "unknown error"),
        }
    end

    local body_content = table.concat(response_body)
    if body_content:find('<body[^>]*class="[^"]*logged%-out[^"]*"') then
        return {
            success = true,
        }
    else
        return {
            success = false,
            error = T("Logout may have failed; still appears to be logged in."),
        }
    end
end

function AO3DownloaderClient:GetSessionStatus()
    logger.dbg("AO3Downloader.koplugin: Checking AO3 session status…")
    local homepage_url = getAO3URL()
    local response_body = {}

    local request = {
        url = homepage_url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = T("Failed to access AO3 homepage. Status: %1", request_result.status or "unknown error"),
        }
    end

    local body_content = table.concat(response_body)
    local root = htmlparser.parse(body_content)

    local is_logged_in = #root:select('body.logged-in') > 0

    if is_logged_in then
        local usernames_select = root:select('a[href^="/users/"]')

        -- Filter out any links that do not match the expected "/users/username" pattern
        for index = #usernames_select, 1, -1 do
            local href = usernames_select[index].attributes and usernames_select[index].attributes.href
            if not href or not href:match('^/users/[^/]+$') then
                table.remove(usernames_select, index)
            end
        end

        if  #usernames_select == 0 then
            return {
                session_exists = true,
                success = false,
                error = T("Failed to parse username from AO3 homepage."),
            }
        end


        -- parse username from "/users/username" href
        local username = usernames_select[1].attributes.href:match("/users/([^/]+)")

        return {
            session_exists = true,
            logged_in = true,
            username = username,
            success = true,
        }
    else
        return {
            session_exists = true,
            logged_in = false,
            username = nil,
            success = true,
        }

    end
end

function AO3DownloaderClient:getWorkMetadata(work_id)
    logger.dbg("AO3Downloader.koplugin: Fetching metadata for work ID: " .. tostring(work_id))
    local url = T("%1/works/%2", getAO3URL(), work_id)

    local response_body = {}

    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
        cookies = {["view_adult"] = "true" },
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = T("Failed to fetch work metadata. Status: %1", request_result.status or "unknown error");
        }
    end

    local body = table.concat(response_body)
    local html_root = htmlparser.parse(body)

    local work_metadata = AO3WebParser.parseWorkPage(html_root);
    work_metadata.id = work_id
    work_metadata.epub_link = work_metadata.epub_href and getAO3URL() .. work_metadata.epub_href
    work_metadata.epub_href = nil

    return {
        success = true,
        work_metadata = work_metadata,
    }

end

function AO3DownloaderClient:downloadEpub(download_link, filepath)
    logger.dbg("AO3Downloader.koplugin: Downloading EPUB from link: " .. tostring(download_link) .. " to filepath: " .. tostring(filepath))
    if not download_link or not download_link:match("^https?://") then
        return {
            success = false,
            error = T("Invalid or missing URL for EPUB download: %1", tostring(download_link)),
        }
    end

    local file, err = io.open(filepath, "w")
    if err then
        return {
            success = false,
            error = T("Failed to open file for writing. Error: %1", tostring(err)),
        }
    end

    local headers = HTTPQueryHandler:get_default_headers()
    headers["Accept"] = "application/epub+zip"

    local request = {
        url = download_link,
        headers = headers,
        sink = socketutil.file_sink(file),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = T("Failed to download EPUB. Status: %1", request_result.status or "unknown error"),
        }
    end

    return {
        success = true,
        filepath = filepath,
    }
end

function AO3DownloaderClient:searchByParameters(parameters, page_no)
    local page = page_no or 1 -- Default to the first page if no page is specified
    logger.dbg("AO3Downloader.koplugin: Executing work search by parameters. Page no: " .. tostring(page_no))
    local query = {}

    -- Build the query string from the parameters
    for key, value in pairs(parameters) do
        if value == "" then
            table.insert(query, string.format("%s=", encodeHelper:urlEncode(key))) -- Include empty parameters
        elseif type(value) == "table" then
            -- Handle nested parameters (e.g., include_work_search[character_ids][])
            for _, subValue in ipairs(value) do
                table.insert(query, string.format("%s=%s", encodeHelper:urlEncode(key), encodeHelper:urlEncode(subValue))) -- Encode [] as %5B%5D
            end
        else
            table.insert(query, string.format("%s=%s", encodeHelper:urlEncode(key), encodeHelper:urlEncode(value)))
        end
    end
    table.insert(query, "page=" .. page)
    local queryString = table.concat(query, "&")

    -- Construct the full URL
    local url = string.format("%s/works?commit=Sort+and+Filter&%s", getAO3URL(), queryString)

    local response_body = {}

    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local response_result = HTTPQueryHandler:performHTTPRequest(request)

    if not response_result.success then
        return {
            success = false,
            error = T("%1/works?commit=Sort+and+Filter&%2", getAO3URL(), queryString)
        }
    end

    local html_body = table.concat(response_body)

    local root = htmlparser.parse(html_body)
    local works = AO3WebParser.parseWorkSearchResults(root)

    return {
        success = true,
        works = works,
    }
end

function AO3DownloaderClient:searchByTag(tag_name, sort_by, page_no)
    local page = page_no or 1
    logger.dbg("AO3Downloader.koplugin: Executing work search by tag: " .. tostring(tag_name) .. ", page no: " .. tostring(page_no))
    local sort_column = sort_by or "revised_at"

    local encoded_tag_name = tag_name
        :gsub("/", "*s*")
        :gsub("&", "*a*")
        :gsub("%.", "*d*")

    encoded_tag_name = encodeHelper:urlEncode(encoded_tag_name)

    local AO3URL = Config:readSetting("AO3_domain")
    local url = T("%1/tags/%2/works?page=%3&work_search[sort_column]=%4", AO3URL, encoded_tag_name, page, sort_column)

    local response_body = {}
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = T("Search request failed. Status: %1", request_result.status or "unknown error"),
        }
    end

    local html_body = table.concat(response_body)

    local root = htmlparser.parse(html_body)
    local works = AO3WebParser.parseWorkSearchResults(root)

    return {
        success = true,
        result_works = works,
    }
end

function AO3DownloaderClient:searchForTags(search_query, tag_type)
    logger.dbg("AO3Downloader.koplugin: Executing tag search for query: " .. tostring(search_query) .. ", tag type: " .. tostring(tag_type))
    if not search_query or search_query == "" then
        return {
            success = false,
            error = "Tag search query cannot be empty"
        }
    end

    tag_type = tag_type or "Fandom"

    local encoded_query = encodeHelper:urlEncode(search_query)

    local url = string.format(
        "%s/tags/search?tag_search%%5Bname%%5D=%s&tag_search%%5Bfandoms%%5D=&tag_search%%5Btype%%5D=%s&tag_search%%5Bwrangling_status%%5D=canonical&tag_search%%5Bsort_column%%5D=uses&tag_search%%5Bsort_direction%%5D=desc&commit=Search+Tags",
        getAO3URL(),
        encoded_query,
        tag_type
    )

    local response_body = {}

    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = T("HTTP tag search request failed. Status: %1", request_result.status or "unknown error"),
        }
    end

    local body = table.concat(response_body)

    local html_root = htmlparser.parse(body)

    local fandoms = AO3WebParser.parseTagSearchResults(html_root)


    return {
        success = true,
        result_tags = fandoms,
    }

end

function AO3DownloaderClient:getWorksFromSeries(series_id, page_no)
    logger.dbg("AO3Downloader.koplugin: Fetching works from series ID: " .. tostring(series_id) .. ", page no: " .. tostring(page_no))
    page_no = page_no or 1
    local url = T("%1/series/%2?page=%3", getAO3URL(), series_id, page_no)

    local response_body = {}
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = T("Failed to fetch series works. Status: %1", request_result.status or "unknown error"),
        }
    end

    local html_body = table.concat(response_body)

    local root = htmlparser.parse(html_body)

    local works = AO3WebParser.parseWorkSearchResults(root)

    return {
        success = true,
        works = works,
    }
end

function AO3DownloaderClient:getWorksFromCollection(collection_id, page_no)
    logger.dbg("AO3Downloader.koplugin: Fetching works from collection ID: " .. tostring(collection_id) .. ", page no: " .. tostring(page_no))
    page_no = page_no or 1
    local url = T("%1/collections/%2/works?page=%3", getAO3URL(), collection_id, page_no)

    local response_body = {}
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = T("Failed to fetch collection works. Status: %1", request_result.status or "unknown error"),
        }
    end

    local html_body = table.concat(response_body)

    local root = htmlparser.parse(html_body)

    local works = AO3WebParser.parseWorkSearchResults(root)

    return {
        success = true,
        works = works,
    }
end

function AO3DownloaderClient:getWorksFromUserPage(username, pseud, catagory, fandom_id, page_no)
    local url
    if catagory == "gifts" then
        url = T("%1/users/%2/gifts", getAO3URL(), username)
    else
        url = T("%1/users/%2/pseuds/%3/%4", getAO3URL(), username, pseud, catagory)
    end

    page_no = page_no or 1

    logger.dbg("AO3Downloader.koplugin: Fetching works from user page. Username: " .. tostring(username) .. ", category: " .. tostring(catagory) .. (fandom_id and (", fandom ID: " .. tostring(fandom_id)) or "") .. ", page no: " .. tostring(page_no))
    local parameters = {["fandom_id"] = fandom_id, ["page"] = page_no}

    local parameter_string = table.concat(
        (function()
            local parts = {}
            for key, value in pairs(parameters) do
                if value then
                    table.insert(parts, string.format("%s=%s", key, value))
                end
            end
            return parts
        end)(),
        "&"
    )

    url = url .. "?" .. parameter_string


    local response_body = {}
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = T("Failed to fetch user works. Status: %1", request_result.status or "unknown error"),
        }
    end

    local html_body = table.concat(response_body)

    local root = htmlparser.parse(html_body)

    local works = nil

    if catagory == "bookmarks" then
        works = AO3WebParser.parseUserBookmarks(root)
    else
         works = AO3WebParser.parseWorkSearchResults(root)
    end

    return {
        success = true,
        works = works,
    }

end

function AO3DownloaderClient:getWorksFromAccountHistory(marked_for_later, page_no)

    local login_status = self:GetSessionStatus()

    if not login_status.success or not login_status.logged_in then
        return {
            success = false,
            error = T("User is not logged in. Please log in to access " .. (marked_for_later and "marked for later list." or "account history.")),
        }
    end

    local username = login_status.username

    local url

    url = T("%1/users/%2/readings", getAO3URL(), username)

    page_no = page_no or 1

    logger.dbg("AO3Downloader.koplugin: Fetching works from account history page. Username: " .. tostring(username) .. ", page no: " .. tostring(page_no))
    local parameters = {["show"] = marked_for_later and "to-read" or "",["page"] = page_no}

    local parameter_string = table.concat(
        (function()
            local parts = {}
            for key, value in pairs(parameters) do
                if value then
                    table.insert(parts, string.format("%s=%s", key, value))
                end
            end
            return parts
        end)(),
        "&"
    )

    url = url .. "?" .. parameter_string


    local response_body = {}
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = T("Failed to fetch account history. Status: %1", request_result.status or "unknown error"),
        }
    end

    local html_body = table.concat(response_body)

    local root = htmlparser.parse(html_body)

    local works = nil

    works = AO3WebParser.parseAccountHistory(root)

    return {
        success = true,
        works = works,
    }

end

function AO3DownloaderClient:getUserSeries(username, pseud, page_no)
    page_no = page_no or 1
    logger.dbg("AO3Downloader.koplugin: Fetching series for user: " .. tostring(username) .. ", page no: " .. tostring(page_no))
    local url = T("%1/users/%2/pseuds/%3/series?page=%4", getAO3URL(), username, pseud, page_no)

    local response_body = {}
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = T("Failed to fetch user series. Status: %1", request_result.status or "unknown error"),
        }
    end

    local html_body = table.concat(response_body)

    local root = htmlparser.parse(html_body)

    local series = AO3WebParser.parseUserSeriesPage(root)

    return {
        success = true,
        series = series,
    }
end

function AO3DownloaderClient:getUserCollections(username, page_no)
    page_no = page_no or 1
    logger.dbg("AO3Downloader.koplugin: Fetching collections for user: " .. tostring(username) .. ", page no: " .. tostring(page_no))
    local url = T("%1/users/%2/collections?page=%3", getAO3URL(), username, page_no)

    local response_body = {}
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = T("Failed to fetch user collections. Status: %1", request_result.status or "unknown error"),
        }
    end

    local html_body = table.concat(response_body)

    local root = htmlparser.parse(html_body)

    local collections = AO3WebParser.parseUserCollectionsPage(root)

    return {
        success = true,
        collections = collections,
    }
end

function AO3DownloaderClient:getUserData(username, pseud)
    local url = T("%1/users/%2/pseuds/%3", getAO3URL(),username, pseud)

    local response_body = {}
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if request_result.status == 404 then
        return {
            success = false,
            error = T("User '%1' not found.", username),
        }
    end

    if not request_result.success then
        return {
            success = false,
            error = T("Failed to fetch user data. Status: %1", request_result.status or "unknown error"),
        }
    end


    local html_body = table.concat(response_body)

    local root = htmlparser.parse(html_body)
    local user_data = AO3WebParser.parseUserPage(root)
    user_data.username = username

    return {
        success = true,
        user_data = user_data,
    }

end

function AO3DownloaderClient:getUserPseuds(username)
    local url = T("%1/users/%2/pseuds", getAO3URL(), username)

    local response_body = {}
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if request_result.status == 404 then
        return {
            success = false,
            error = T("User '%1' not found.", username),
        }
    end

    if not request_result.success then
        return {
            success = false,
            error = T("Failed to fetch user pseuds. Status: %1", request_result.status or "unknown error"),
        }
    end

    local html_body = table.concat(response_body)
    local root = htmlparser.parse(html_body)
    local pseuds = AO3WebParser.parseUserPseuds(root)

    return {
        success = true,
        pseuds = pseuds,
    }
end

function AO3DownloaderClient:getAccountPseudID(username)
    local url = T("%1/users/%2/pseuds/%2/edit", getAO3URL(), username)

    local response_body = {}
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if request_result.status == 404 then
        return {
            success = false,
            error = T("Pseud edit page for '%1' not found.", username),
        }
    end

    if not request_result.success then
        return {
            success = false,
            error = T("Failed to fetch accound pseud ID. Status: %1", request_result.status or "unknown error"),
        }
    end

    local html_body = table.concat(response_body)
    local root = htmlparser.parse(html_body)
    local pseud_id = AO3WebParser.parseAccountPseudID(root)

    if not pseud_id then
        return {
            success = false,
            error = T("Failed to parse accound pseud ID"),
        }
    end

    return {
        success = true,
        pseud_id = pseud_id,
    }
end

function AO3DownloaderClient:searchForUsers(search_query, page_no)
    logger.dbg("AO3Downloader.koplugin: Executing user search for query: " .. tostring(search_query) .. ", page no: " .. tostring(page_no))
    if not search_query or search_query == "" then
        return {
            success = false,
            error = "User search query cannot be empty"
        }
    end

    page_no = page_no or 1

    local encoded_query = encodeHelper:urlEncode(search_query)

    local url = string.format(
        "%s/people/search?people_search%%5Bquery%%5D=%s&page=%d",
        getAO3URL(),
        encoded_query,
        page_no
    )

    local response_body = {}

    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = T("HTTP user search request failed. Status: %1", request_result.status or "unknown error"),
        }
    end

    local body = table.concat(response_body)
    local html_root = htmlparser.parse(body)

    local users = AO3WebParser.parseUserSearchResults(html_root)

    return {
        success = true,
        result_users = users,
    }
end

function AO3DownloaderClient:searchForCollections(search_query)
    logger.dbg("AO3Downloader.koplugin: Executing collection search for query: " .. tostring(search_query))
    if (not search_query or search_query == "") then
        return {
            success = false,
            error = "Collection search query cannot be empty"
        }
    end

    local encoded_query = encodeHelper:urlEncode(search_query)

    local url = string.format(
        "%s/autocomplete/collection_title?term=%s",
        getAO3URL(),
        encoded_query
    )

    local response_body = {}
    local headers = HTTPQueryHandler:get_default_headers()
    headers["Accept"] = "application/json, text/javascript, */*; q=0.01"
    headers["X-Requested-With"] = "XMLHttpRequest"
    headers["Accept-Encoding"] = nil

    local request = {
        url = url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = T("HTTP collection search request failed. Status: %1", request_result.status or "unknown error"),
        }
    end

    local results = table.concat(response_body)
    local json = require("rapidjson")
    local collection_results = json.decode(results)

    if not collection_results then
        return {
            success = false,
            error = T("Failed to parse collection search results."),
        }
    end

    return {
        success = true,
        collections = collection_results,
    }

end

function AO3DownloaderClient:kudosWork(work_id)
    logger.dbg("AO3Downloader.koplugin: Sending kudos to work. Work ID: " .. tostring(work_id))
    local login_status = self:GetSessionStatus()
    if not login_status.success then
        return {
            success = false,
            error = T("Failed to check login status: %1", login_status.error or "unknown error"),
        }
    end

    if not login_status.logged_in then
        return {
            success = false,
            error = T("User must be logged in to kudos works."),
        }
    end

    local authenticity_token_request = self:requestAO3Token()

    if not authenticity_token_request.success then
        return {
            success = false,
            error = T("Failed to retrieve AO3 token for kudos: %1", authenticity_token_request.error or "unknown error"),
        }
    end

    local authenticity_token = authenticity_token_request.token

    local kudos_url = T("%1/kudos.js", getAO3URL())

    local response_body = {}
    local headers = HTTPQueryHandler:get_default_headers()
    headers["Content-Type"] = "application/x-www-form-urlencoded"

    local form_data = encodeHelper:generateParametersStringForm({
        ["authenticity_token"] = authenticity_token,
        ["kudo[commentable_id]"] = tostring(work_id),
        ["kudo[commentable_type]"] = "Work",
    })
    headers["Content-Length"] = tostring(#form_data)


    local request = {
        url = kudos_url,
        method = "POST",
        headers = headers,
        sink = ltn12.sink.table(response_body),
        source = ltn12.source.string(form_data),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if request_result.status == 201 then
        return {
            success = true,
        }
    end

    if request_result.status == 422 then
        return {
            success = false,
            error = T("You have already left kudos here. :)"),
        }
    end

    return {
        success = false,
        error = T("Failed to kudos work. Status: %1", request_result.status or "unknown error"),
    }
end

function AO3DownloaderClient:commentOnWork(comment_content, work_id, chapter_id)
    logger.dbg("AO3Downloader.koplugin: Posting comment on work. Work ID: " .. tostring(work_id) .. ", chapter ID: " .. tostring(chapter_id))

    if not comment_content or comment_content == "" then
        return {
            success = false,
            error = T("Comment content cannot be empty."),
        }
    end

    if comment_content:len() > 10000 then
        return {
            success = false,
            error = T("Comment content exceeds maximum length of 10,000 characters."),
        }
    end

    local login_status = self:GetSessionStatus()
    if not login_status.success then
        return {
            success = false,
            error = T("Failed to check login status: %1", login_status.error or "unknown error"),
        }
    end

    if not login_status.logged_in then
        return {
            success = false,
            error = T("User must be logged in to comment on works."),
        }
    end

    local comment_url = getAO3URL()
        .. ((chapter_id and ("/chapters/" .. chapter_id)) or ("/works/" .. work_id))
        .. "/comments"

    local response_body = {}

    local request = {
        url = comment_url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
        cookies = { ["view_adult"] = "true"}
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = T("Failed to fetch comment comment form. Status: %1", request_result.status or "unknown error"),
        }
    end


    local body = table.concat(response_body)
    local html_root = htmlparser.parse(body)

    local form = html_root:select("#comment_for_" .. (chapter_id or work_id))[1]
    local authenticity_token = form and form:select("[name='authenticity_token']")[1].attributes["value"]
    local pseud_id = form and form:select("[name='comment[pseud_id]']")[1].attributes["value"]

    if not authenticity_token or not pseud_id then
        return {
            success = false,
            error = T("Failed to retrieve necessary tokens for commenting from comment form."),
        }
    end

    local headers = HTTPQueryHandler:get_default_headers()
    headers["Content-Type"] = "application/x-www-form-urlencoded"
    headers["Referer"] = comment_url

    local custom_cookies = {
        ["user_credentials"] = "1",
        ["view_adult"] = "true",
    }

    local form_data  = encodeHelper:generateParametersStringForm({
        ["authenticity_token"] = authenticity_token,
        ["comment[pseud_id]"] = pseud_id,
        ["comment[comment_content]"] = comment_content,
        ["controller_name"] = "comments",
        ["commit"] = "Comment",
    })

    headers["Content-Length"] = tostring(#form_data)

    local request = {
        url = comment_url,
        method = "POST",
        headers = headers,
        sink = ltn12.sink.table(response_body),
        source = ltn12.source.string(form_data),
        cookies = custom_cookies,
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = T("Failed to post comment. Status: %1", request_result.status or "unknown error"),
        }
    end

    if request_result.response == 1 then
        return {
            success = true,
        }
    end

    return {
        success = false;
        error = T("Failed to post comment. Status: %1", request_result.status or "unknown error"),
    }
end

function AO3DownloaderClient:markForLaterWork(work_id, later_or_read)
    logger.dbg("AO3Downloader.koplugin: Marking work. Work ID: " .. tostring(work_id))
    local login_status = self:GetSessionStatus()
    if not login_status.success then
        return {
            success = false,
            error = T("Failed to check login status: %1", login_status.error or "unknown error"),
        }
    end

    if not login_status.logged_in then
        return {
            success = false,
            error = T("User must be logged in to mark work."),
        }
    end

    local authenticity_token_request = self:requestAO3Token()

    if not authenticity_token_request.success then
        return {
            success = false,
            error = T("Failed to retrieve AO3 token for marking work: %1", authenticity_token_request.error or "unknown error"),
        }
    end

    local authenticity_token = authenticity_token_request.token

    -- Mark As Read True, Mark For Later False
    local kudos_url = T("%1/works/%2/%3", getAO3URL(), work_id, later_or_read and "mark_as_read" or "mark_for_later")

    local response_body = {}
    local headers = HTTPQueryHandler:get_default_headers()
    headers["Content-Type"] = "application/x-www-form-urlencoded"

    local form_data = encodeHelper:generateParametersStringForm({
        ["authenticity_token"] = authenticity_token,
        ["_method"] = "patch"
    })
    headers["Content-Length"] = tostring(#form_data)


    local request = {
        url = kudos_url,
        method = "POST",
        headers = headers,
        sink = ltn12.sink.table(response_body),
        source = ltn12.source.string(form_data),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if request_result.status == 302 then
        return {
            success = true,
        }
    end

    return {
        success = false,
        error = T("Failed to mark work. Status: %1", request_result.status or "unknown error"),
    }
end

function AO3DownloaderClient:setWorkSubscription(work_id, subscription_id)
    logger.dbg("AO3Downloader.koplugin: Setting subscription. Work ID: " .. tostring(work_id))

    local login_status = self:GetSessionStatus()
    if not login_status.success then
        return {
            success = false,
            error = T("Failed to check login status: %1", login_status.error or "unknown error"),
        }
    end

    if not login_status.logged_in then
        return {
            success = false,
            error = T("User must be logged in to subscribe."),
        }
    end

    local token_request = self:requestAO3Token()
    if not token_request.success then
        return {
            success = false,
            error = T("Failed to retrieve AO3 token: %1", token_request.error or "unknown error"),
        }
    end

    local authenticity_token = token_request.token

    local url
    local form

    if not subscription_id then
        url = T("%1/users/%2/subscriptions", getAO3URL(), login_status.username)

        form = encodeHelper:generateParametersStringForm({
            ["authenticity_token"] = authenticity_token,
            ["subscription[subscribable_id]"] = tostring(work_id),
            ["subscription[subscribable_type]"] = "Work",
        })
    else
        if not subscription_id then
            return {
                success = false,
                error = T("Subscription ID required to unsubscribe."),
            }
        end

        url = T("%1/users/%2/subscriptions/%3",
            getAO3URL(),
            login_status.username,
            subscription_id
        )

        form = encodeHelper:generateParametersStringForm({
            ["authenticity_token"] = authenticity_token,
            ["_method"] = "delete",
            ["subscription[subscribable_id]"] = tostring(work_id),
            ["subscription[subscribable_type]"] = "Work",
        })
    end

    local response_body = {}
    local headers = HTTPQueryHandler:get_default_headers()
    headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
    headers["Content-Length"] = tostring(#form)
    headers["Accept"] = "application/json, text/javascript, */*; q=0.01"
    headers["X-Requested-With"] = "XMLHttpRequest"
    headers["X-CSRF-Token"] = authenticity_token

    local request = {
        url = url,
        method = "POST",
        headers = headers,
        sink = ltn12.sink.table(response_body),
        source = ltn12.source.string(form),
    }

    local result = HTTPQueryHandler:performHTTPRequest(request)

    local response_text = table.concat(response_body)

    if result.status == 201 then
        local json = require("rapidjson")
        local decoded = json.decode(response_text)

        if decoded then
            return {
                success = true,
                subscription_id = tostring(decoded.item_id),
            }
        end

        return {
            success = true,
        }
    end
    if result.status == 302 or result.status == 200 then
        return {
            success = true
        }
    end

    return {
        success = false,
        error = T("Failed to update subscription. Status: %1", result.status or "unknown error"),
    }
end

function AO3DownloaderClient:getUsersWorkBookmark(work_id)
    logger.dbg("AO3Downloader.koplugin: Fetching bookmark for work. Work ID: " .. tostring(work_id))

    local login_status = self:GetSessionStatus()
    if not login_status.success then
        return {
            success = false,
            error = T("Failed to check login status: %1", login_status.error or "unknown error"),
        }
    end

    if not login_status.logged_in then
        return {
            success = false,
            error = T("User must be logged in to fetch bookmarks."),
        }
    end

    local url = T("%1/works/%2/bookmarks", getAO3URL(), work_id)

    local response_body = {}

    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local result = HTTPQueryHandler:performHTTPRequest(request)

    if not result.success then
        return {
            success = false,
            error = T("Failed to fetch bookmark. Status: %1", result.status or "unknown error"),
        }
    end

    local html_body = table.concat(response_body)
    local root = htmlparser.parse(html_body)


    local bookmark_trigger_button = root:select("a.bookmark_form_trigger_for_" .. work_id)[1]
    if not bookmark_trigger_button  and bookmark_trigger_button:getcontent() ~= "Edit Bookmark" then
        return {
            success = false,
            error = T("Bookmark not found from this user for work ID: %1", work_id),
        }
    end

    local bookmark_form_url = T("%1%2", getAO3URL(), bookmark_trigger_button.attributes["href"])

    local request = {
        url = bookmark_form_url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local result = HTTPQueryHandler:performHTTPRequest(request)

    if not result.success then
        return {
            success = false,
            error = T("Failed to fetch bookmark form. Status: %1", result.status or "unknown error"),
        }
    end

    local html_body = table.concat(response_body)
    logger.dbg("AO3Downloader.koplugin: Bookmark form response body: " .. tostring(html_body))
    -- look foor bookmark_div.html("...") and parse html

    local root = htmlparser.parse(html_body)

    local bookmark_data = AO3WebParser.parseUsersWorkBookmark(root)

    return {
        success = true,
        bookmark_data = bookmark_data,
        bookmark_id = bookmark_trigger_button.attributes["href"]:match("/bookmarks/(%d+)/edit")
    }
end

function AO3DownloaderClient:updateBookmark(work_id, bookmark_id, notes, tags, collections, private, rec)
    logger.dbg("AO3Downloader.koplugin: Updating bookmark. Work ID: " .. tostring(work_id))

    local login_status = self:GetSessionStatus()
    if not login_status.success then
        return {
            success = false,
            error = T("Failed to check login status: %1", login_status.error or "unknown error"),
        }
    end

    if not login_status.logged_in then
        return {
            success = false,
            error = T("User must be logged in to edit bookmarks."),
        }
    end

    local token_request = self:requestAO3Token()
    if not token_request.success then
        return {
            success = false,
            error = T("Failed to retrieve AO3 token: %1", token_request.error or "unknown error"),
        }
    end

    local authenticity_token = token_request.token

    local url
    local form_data = {
        ["authenticity_token"] = authenticity_token,
        ["bookmark[bookmarker_notes]"] = notes or "",
        ["bookmark[tag_string]"] = tags or "",
        ["bookmark[collection_names]"] = collections or "",
        ["bookmark[private]"] = private and "1" or "0",
        ["bookmark[rec]"] = rec and "1" or "0",
    }

    if bookmark_id then
        url = T("%1/bookmarks/%2", getAO3URL(), bookmark_id)
        form_data["_method"] = "put"
        form_data["commit"] = "Update"
    else
        url = T("%1/works/%2/bookmarks", getAO3URL(), work_id)
        form_data["commit"] = "Create"

        local pseud_result = AO3DownloaderClient:getAccountPseudID(login_status.username)

        if not pseud_result.success then
            return {
                success = false,
                error = T("Error: %1", pseud_result.error)
            }
        end

        form_data["bookmark[pseud_id]"] = tostring(pseud_result.pseud_id)
    end

    local form = encodeHelper:generateParametersStringForm(form_data)

    local response_body = {}
    local headers = HTTPQueryHandler:get_default_headers()
    headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
    headers["Content-Length"] = tostring(#form)
    headers["X-CSRF-Token"] = authenticity_token

    local request = {
        url = url,
        method = "POST",
        headers = headers,
        sink = ltn12.sink.table(response_body),
        source = ltn12.source.string(form),
    }

    local result = HTTPQueryHandler:performHTTPRequest(request)

    if result.status == 302 or result.status == 200 then
        local body_content = table.concat(response_body)
        local root = htmlparser.parse(body_content)

        if (root:select("div.#error") and #root:select("div.#error") > 0) then
            local error_message = root:select("div.#error")[1]:getcontent()
            -- remove htmml tags from error message and convert code points eg &#39; to characters
            error_message = error_message:gsub("<[^>]+>", "")
            error_message = encodeHelper:unescapeText(error_message)

            return {
                success = false,
                error = T("Failed to update bookmark. Error message: %1", error_message or "unknown error"),
            }
        end

        return {
            success = true,
            bookmark_id = result.response_headers and result.response_headers["location"]
                and result.response_headers["location"]:match("/bookmarks/(%d+)")
        }
    end

    return {
        success = false,
        error = T("Failed to update bookmark. Status: %1", result.status or "unknown error"),
    }
end

function AO3DownloaderClient:deleteBookmark(bookmark_id)
    logger.dbg("AO3Downloader.koplugin: Deleting bookmark. Bookmark ID: " .. tostring(bookmark_id))

    local login_status = self:GetSessionStatus()
    if not login_status.success then
        return {
            success = false,
            error = T("Failed to check login status: %1", login_status.error or "unknown error"),
        }
    end

    if not login_status.logged_in then
        return {
            success = false,
            error = T("User must be logged in to delete bookmarks."),
        }
    end

    local token_request = self:requestAO3Token()
    if not token_request.success then
        return {
            success = false,
            error = T("Failed to retrieve AO3 token: %1", token_request.error or "unknown error"),
        }
    end

    local authenticity_token = token_request.token

    local url = T("%1/bookmarks/%2", getAO3URL(), bookmark_id)
    local form_data = {
        ["authenticity_token"] = authenticity_token,
        ["_method"] = "delete"
    }

    local form = encodeHelper:generateParametersStringForm(form_data)

    local response_body = {}
    local headers = HTTPQueryHandler:get_default_headers()
    headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
    headers["Content-Length"] = tostring(#form)
    headers["X-CSRF-Token"] = authenticity_token

    local request = {
        url = url,
        method = "POST",
        headers = headers,
        sink = ltn12.sink.table(response_body),
        source = ltn12.source.string(form),
    }

    local result = HTTPQueryHandler:performHTTPRequest(request)

    if result.status == 302 then
        return {
            success = true,
        }
    end

    return {
        success = false,
        error = T("Failed to update bookmark. Status: %1", result.status or "unknown error"),
    }
end

return AO3DownloaderClient
