
local logger = require("logger")
local socketutil = require("socketutil")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local Config = require("fanfic_config")
local util = require("util")
local https = require("ssl.https") -- Use luasec for HTTPS requests
local htmlparser = require("htmlparser")
htmlparser_looplimit = 1000000000

local function getAO3URL()
    return Config:readSetting("AO3_domain")
end

local AO3DownloaderClient = {}

local AO3WebParser = {}

local HTTPQueryHandler = {}

local encodeHelper = {}


function encodeHelper:urlEncode(str)
    if str then
        str = str:gsub("([^%w%-%.%_%~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
    end
    return str
end

function encodeHelper:formEncode(str)
    if str then
        str = string.gsub(str, " ", "+")
        str = str:gsub("([^%w%-%.%_%~%+])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
    end
    return str
end

function encodeHelper:unescapeText(str)
    local unescape_map = {
        ["lt"] = "<",
        ["gt"] = ">",
        ["amp"] = "&",
        ["quot"] = '"',
        ["apos"] = "'",
    }

    local gsub = string.gsub
    local result = gsub(str, "(&(#?)([%d%a]+);)", function(orig, n, s)
        if unescape_map[s] then
            return unescape_map[s]
        elseif n == "#" then -- unescape unicode
            local codepoint
            -- Determine if the code point is written as a decimal or hexadecimal number
            if string.sub(s, 1, 1) == "x" then
                codepoint = tonumber(string.sub(s, 2), 16)
            else
                codepoint = tonumber(s)
            end
            return util.unicodeCodepointToUtf8(codepoint)
        else
            return orig
        end
    end)
    return result
end

function encodeHelper:parseToCodepoints(str)
    return self:unescapeText(str)
end

function encodeHelper:generateParametersStringForm(params)
    local form_parts = {}
    for key, value in pairs(params) do
        table.insert(form_parts, encodeHelper:formEncode(key) .. "=" .. encodeHelper:formEncode(value))
    end
    return table.concat(form_parts, "&")
end

function AO3DownloaderClient:requestAO3Token()
    logger.dbg("AO3Downloader.koplugin: Requesting AO3 token...")
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

    local json = require("dkjson")
    local success, token_data = pcall(json.decode, html_body)

    if not success then
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
    logger.dbg("AO3Downloader.koplugin: Ending logged-in AO3 session...")
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
    logger.dbg("AO3Downloader.koplugin: Checking AO3 session status...")
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

    if body_content:find('<body[^>]*class="[^"]*logged%-in[^"]*"') then
        local username = body_content:match('<a href="/users/([%w_]+)"')
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

    local work_metadata = AO3WebParser:parseWorkPage(html_root);
    work_metadata.id = work_id

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
    local works = AO3WebParser:parseWorkSearchResults(root)

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
    local works = AO3WebParser:parseWorkSearchResults(root)

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

    local fandoms = AO3WebParser:parseTagSearchResults(html_root)


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

    local works = AO3WebParser:parseWorkSearchResults(root)

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
        works = AO3WebParser:parseUserBookmarks(root)
    else
         works = AO3WebParser:parseWorkSearchResults(root)
    end

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

    local series = AO3WebParser:parseUserSeriesPage(root)

    return {
        success = true,
        series = series,
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
    local user_data = AO3WebParser:parseUserPage(root)
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
    local pseuds = AO3WebParser:parseUserPseuds(root)

    return {
        success = true,
        pseuds = pseuds,
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

    local users = AO3WebParser:parseUserSearchResults(html_root)

    return {
        success = true,
        result_users = users,
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
            error = T("Work has already been kudosed by this user."),
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



-- AO3WebParser
function AO3WebParser:parseWorkSearchResults(root)
    local works = {}
    local elements = root:select("li.work")

    local count = 1

    local resultsCountElement = root:select("#main > h3")[1]
    if resultsCountElement then
        local resultsText = resultsCountElement:getcontent()
        local totalWorks = resultsText:match("^%s*([%d,]+) Found")
        if totalWorks then
            totalWorks = tonumber(totalWorks:gsub(",", ""), 10)
            works["total"] = totalWorks
        end
    end

    if not works["total"] then
        local resultsCountElement = root:select("#main > h2")[1]
        if resultsCountElement then
            local resultsText = resultsCountElement:getcontent()
            local totalWorks = resultsText:match("of%s*([%d,]+)%s*Works")
            if not totalWorks then
                totalWorks = resultsText:match("^%s*([%d,]+)%s*Works")
            end
            if totalWorks then
                totalWorks = totalWorks:gsub(",", "")
                works["total"] = tonumber(totalWorks)
            end
        end
    end


    for _, element in ipairs(elements) do
        local work = self:parseWorkElement(element)
        if work then
            table.insert(works, count, work)
            count = count + 1
        end
    end

    return works
end

function AO3WebParser:parseUserBookmarks(root)
    local bookmarks = {}
    local elements = root:select("li.bookmark")

    local count = 1

    for _, element in ipairs(elements) do
        -- Check if bookmark is for deleted fic, if so, set title accordingly
        local deletedElement = element:select(".message")[1]
        if deletedElement and deletedElement:getcontent():find("This has been deleted, sorry!") then
            local work = {}
            work.title = "Deleted Work"
            work.id = nil
            work.is_deleted = true
            table.insert(bookmarks, count, work)
            count = count + 1

        else
            local work = self:parseWorkElement(element)
            if work then
                table.insert(bookmarks, count, work)
                count = count + 1
            end
        end
    end

    return bookmarks

end

function AO3WebParser:parseUserSeriesPage(root)
    local series_list = {}
    local elements = root:select("li.series")

    local count = 1

    for _, element in ipairs(elements) do
        local titleElement = element:select(".heading > a")[1]
        if titleElement then
            local href = titleElement.attributes.href
            local id = tonumber(href:match("/series/(%d+)"))
            local title = titleElement:getcontent()

            local authorElement = element:select(".heading > a[rel='author']")[1]
            local author = authorElement and encodeHelper:parseToCodepoints(authorElement:getcontent()) or nil

            local dateElement = element:select(".datetime")[1]

            local date_posted = dateElement and encodeHelper:parseToCodepoints(dateElement:getcontent()) or ""

            local fandomElements = element:select(".fandoms > a")
            local fandoms = {}
            for _, fandomElement in pairs(fandomElements) do
                local content = fandomElement:getcontent()
                if content then
                    table.insert(fandoms, encodeHelper:parseToCodepoints(content))
                end
            end

            local warningElements = element:select(".warnings > strong > a")

            local warnings = {}

            for _, warningElement in pairs(warningElements) do
                local content = warningElement:getcontent()
                if content then
                    table.insert(warnings, encodeHelper:parseToCodepoints(content))
                end
            end

            local relationshipsElements = element:select(".relationships > a")
            local relationships = {}
            for _, relationshipElement in pairs(relationshipsElements) do
                local content = relationshipElement:getcontent()
                if content then
                    table.insert(relationships, encodeHelper:parseToCodepoints(content))
                end
            end

            local charactersElements = element:select(".characters > a")
            local characters = {}

            for _, characterElement in pairs(charactersElements) do
                local content = characterElement:getcontent()
                if content then
                    table.insert(characters, encodeHelper:parseToCodepoints(content))
                end
            end

            local otherTagsElements = element:select(".freeforms > a")
            local other_tags = {}

            for _, otherTagElement in pairs(otherTagsElements) do
                local content = otherTagElement:getcontent()
                if content then
                    table.insert(other_tags, encodeHelper:parseToCodepoints(content))
                end
            end

            local summaryElement = element:select(".summary")[1]
            local summary = summaryElement and encodeHelper:parseToCodepoints(summaryElement:getcontent()
                :gsub("<br%s*/?>", "\n") -- Replace <br> tags with new lines
                :gsub("</p>", "\n\n") -- Add double new lines for paragraph breaks
                :gsub("<[^>]+>", "") -- Remove other HTML tags
                :gsub("^%s*(.-)%s*$", "%1") -- Trim whitespace) or ""
            )

            local wordCountElement = element:select("dd.words")[1]
            logger.dbg(wordCountElement and wordCountElement:getcontent():gsub(",", "") or "No word count element found")
            local word_count = wordCountElement and tonumber(wordCountElement:getcontent():gsub(",", ""), 10) or 0

            local workCountElement = element:select("dd.works")[1]
            local work_count = workCountElement and tonumber(workCountElement:getcontent():gsub(",", ""), 10) or 0

            local bookmark_countElement = element:select("dd.bookmarks")[1]
            local bookmark_count = bookmark_countElement and tonumber(bookmark_countElement:getcontent():gsub(",", ""), 10) or 0

            local series = {
                id = id,
                title = title,
                author = author,
                date_posted = date_posted,
                fandoms = fandoms,
                warnings = warnings,
                relationships = relationships,
                characters = characters,
                tags = other_tags,
                summary = summary,
                word_count = word_count,
                work_count = work_count,
                bookmark_count = bookmark_count,
            }

            table.insert(series_list, count, series)
            count = count + 1
        end
    end

    return series_list
end

function AO3WebParser:parseWorkElement(element)
    local titleElement = element:select(".heading > a")[1]
    local restrictedElement = element:select("img[title='Restricted']")[1]
    local authorElements = element:select(".heading > a[rel='author']")
    local giftElements = element:select(".heading > a[href$='/gifts']")
    local summaryElement = element:select(".summary")[1]
    local tagsElement = element:select(".tags > .freeforms")
    local relationshipsElement = element:select(".tags > .relationships")
    local charactersElement = element:select(".tags > .characters")
    local warningsElement = element:select(".tags > .warnings")
    local fandomsElement = element:select(".fandoms")[1]
    local dateElement = element:select(".datetime")[1]
    local languageElement = element:select("dd.language")[1]
    local wordsElement = element:select("dd.words")[1]
    local chaptersElement = element:select("dd.chapters")[1]
    local hitsElement = element:select("dd.hits")[1]
    local commentsElement = element:select("dd.comments")[1]
    local kudosElement = element:select("dd.kudos")[1]
    local bookmarksElement = element:select("dd.bookmarks")[1]
    local ratingElement = element:select(".rating")[1]
    local categoryElement = element:select(".category")[1]
    local iswipElement = element:select(".iswip")[1]

    if titleElement then
        -- Extract the work ID from the href attribute
        local href = titleElement.attributes.href
        local id = tonumber(href:match("/works/(%d+)")) -- Extract the numeric ID and convert to number
        local isRestricted = restrictedElement and true or false -- Set to true if restrictedElement exists, otherwise false

        -- Extract and clean tags
        local tags = {}
        if tagsElement then
            for __, tagset in ipairs(tagsElement) do
                for _, tag in ipairs(tagset:select("a")) do
                    local content = encodeHelper:parseToCodepoints(tag:getcontent())
                    if content then
                        table.insert(tags, content)
                    end
                end
            end
        end

        -- Extract and clean relationships
        local relationships = {}
        if relationshipsElement then
            for __, relationshipset in ipairs(relationshipsElement) do
                for _, relationship in ipairs(relationshipset:select("a")) do
                    local content = encodeHelper:parseToCodepoints(relationship:getcontent())
                    if content then
                        table.insert(relationships, content)
                    end
                end
            end
        end

        -- Extract and clean characters
        local characters = {}
        if charactersElement then
            for __, characterset in ipairs(charactersElement) do
                for _, character in ipairs(characterset:select("a")) do
                    local content = encodeHelper:parseToCodepoints(character:getcontent())
                    if content then
                        table.insert(characters, content)
                    end
                end
            end
        end

        -- Extract and clean warnings
        local warnings = {}
        if warningsElement then
            for __, warningset in ipairs(warningsElement) do
                for _, warning in ipairs(warningset:select("strong > a")) do
                    local content = encodeHelper:parseToCodepoints(warning:getcontent())
                    if content then
                        table.insert(warnings, content)
                    end
                end
            end
        end

        -- Extract and clean fandoms
        local fandoms = {}
        if fandomsElement then
            for _, fandom in ipairs(fandomsElement:select("a")) do
                local content = encodeHelper:parseToCodepoints(fandom:getcontent())
                if content then
                    table.insert(fandoms, content)
                end
            end
        end

        -- Extract additional metadata
        local date = dateElement and encodeHelper:parseToCodepoints(dateElement:getcontent()) or "N/A"
        local language = languageElement and encodeHelper:parseToCodepoints(languageElement:getcontent()) or "N/A"
        local words = wordsElement and encodeHelper:parseToCodepoints(wordsElement:getcontent()) or "N/A"
        local chapters = chaptersElement and encodeHelper:parseToCodepoints(chaptersElement:getcontent():gsub("<[^>]+>", ""))
            or "N/A"
        local hits = hitsElement and encodeHelper:parseToCodepoints(hitsElement:getcontent():gsub("<[^>]+>", "")) or "0"
        local comments = commentsElement and encodeHelper:parseToCodepoints(commentsElement:getcontent():gsub("<[^>]+>", ""))
            or "0"
        local kudos = kudosElement and encodeHelper:parseToCodepoints(kudosElement:getcontent():gsub("<[^>]+>", "")) or "0"
        local bookmarks = bookmarksElement and encodeHelper:parseToCodepoints(bookmarksElement:getcontent():gsub("<[^>]+>", ""))
            or "0"
        local rating = ratingElement and ratingElement.attributes["title"] or "N/A"
        local category = categoryElement and categoryElement.attributes["title"] or "N/A"
        local iswip = iswipElement and iswipElement.attributes["title"] or "N/A"
        local author_table = {}
        for _, author in pairs(authorElements) do
            table.insert(author_table, encodeHelper:parseToCodepoints(author:getcontent()))
        end

        local author = #authorElements > 0 and table.concat(author_table, ", ") or nil

        local giftedTo_table = {}
        for _, gift in pairs(giftElements) do
            table.insert(giftedTo_table, encodeHelper:parseToCodepoints(gift:getcontent()))
        end

        local gifted_to = #giftElements > 0 and table.concat(giftedTo_table, ", ") or nil
        local tags = #tags > 0 and table.concat(tags, ", ") or "N/A"

        -- Remove HTML formatting, replace <br> with new lines, and preserve paragraph formatting
        local summary = summaryElement
                and encodeHelper:parseToCodepoints(
                    summaryElement
                        :getcontent()
                        :gsub("<br%s*/?>", "\n") -- Replace <br> tags with new lines
                        :gsub("</p>", "\n\n") -- Add double new lines for paragraph breaks
                        :gsub("<[^>]+>", "") -- Remove other HTML tags
                        :gsub("^%s*(.-)%s*$", "%1") -- Trim whitespace
                )
            or "No summary available"

        -- Remove leading and trailing whitespace from the title
        local title = titleElement
            and encodeHelper:parseToCodepoints(titleElement:getcontent():gsub("<[^>]+>", ""):gsub("^%s*(.-)%s*$", "%1"))
            or "Unknown title" -- Trim whitespace and remove internal tags

        -- Create the work object
        local work = {
            id = id,
            title = title,
            rating = rating,
            category = category,
            iswip = iswip,
            link = getAO3URL() .. href,
            author = author,
            gifted_to = gifted_to,
            summary = summary,
            tags = tags,
            relationships = relationships or {},
            characters = characters or {},
            warnings = warnings or {},
            fandoms = fandoms or {},
            date = date,
            language = language,
            words = words,
            chapters = chapters,
            hits = hits,
            comments = comments,
            kudos = kudos,
            bookmarks = bookmarks,
            is_restricted = isRestricted, -- Add the restricted status
        }

        return work
    end
    return nil
end

function AO3WebParser:parseTagSearchResults(root)
    local fandom_elements = root:select("li > span > a.tag") -- Adjust the selector based on AO3's HTML structure
--
    local fandoms = {}
    for _, element in ipairs(fandom_elements) do
        -- Extract the fandom name
        local fandom_name = element:getcontent()

        -- Extract the number of uses from the parent `<span>` element
        local parent_span = element.parent
        if parent_span then
            -- Remove the fandom name from the parent span content
            local parent_content = parent_span:getcontent()
            -- Extract the last set of parentheses
            local uses_text = parent_content:match(".*%((%d+)%)$") -- Match the last number in parentheses

            if fandom_name and uses_text then
                table.insert(fandoms, {
                    name = encodeHelper:parseToCodepoints(fandom_name),
                    uses = tonumber(uses_text),
                })
            end
        end
    end

    return fandoms
end

function AO3WebParser:parseWorkPage(root)
    -- Extract metadata
    local titleElement = root:select(".title")[1]
    local authorElements = root:select("a[rel='author']")
    local giftElements = root:select(".associations > li > a[href$='/gifts']")
    local summaryElement = root:select(".summary > blockquote")[1]
    local tagsElement = root:select(".freeform > ul")[1]
    local relationshipsElement = root:select(".relationship > ul")[1]
    local charactersElement = root:select(".character > ul")[1]
    local warningsElement = root:select(".warning > ul")[1]
    local epubElement = root:select(".download > .expandable > li > a")
    local ratingElement = root:select(".rating > ul > li > a")[1]
    local categoryElement = root:select(".category > ul > li > a")[1]
    local iswipElement = root:select("dt.status")[1]

    -- Extract additional metadata
    local fandomElement = root:select(".fandom > ul")[1]
    local publishedElement = root:select("dd.published")[1]
    local updatedElement = root:select("dd.status")[1]
    local chaptersElement = root:select("dd.chapters")[1]
    local languageElement = root:select("dd.language")[1]

    -- Extract stats
    local hitsElement = root:select("dd.hits")[1]
    local kudosElement = root:select("dd.kudos")[1]
    local commentsElement = root:select("dd.comments")[1]
    local bookmarksElement = root:select("dd.bookmarks > a")[1]
    local wordCountElement = root:select("dd.words")[1]
    local chapterIDElements = root:select("#chapter_index > li > form > p > select > option")

    -- Extract metadata values
    local title = titleElement
        and encodeHelper:parseToCodepoints(titleElement:getcontent():gsub("<[^>]+>", ""):gsub("^%s*(.-)%s*$", "%1"))
        or "Unknown title"


    local author_table = {}
    for _, author in pairs(authorElements) do
        table.insert(author_table, encodeHelper:parseToCodepoints(author:getcontent()))
    end

    local author = authorElements and table.concat(author_table, ", ") or "Anonymous"

    local giftedTo_table = {}
    for _, gift in pairs(giftElements) do
        table.insert(giftedTo_table, encodeHelper:parseToCodepoints(gift:getcontent()))
    end

    local gifted_to = giftElements and table.concat(giftedTo_table, ", ") or nil

    local summary = summaryElement
        and encodeHelper:parseToCodepoints(
            summaryElement
            :getcontent()
            :gsub("<br%s*/?>", "\n") -- Replace <br> tags with new lines
            :gsub("</p>", "\n\n") -- Add double new lines for paragraph breaks
            :gsub("<[^>]+>", "") -- Remove other HTML tags
            :gsub("^%s*(.-)%s*$", "%1") -- Trim whitespace
        )
        or "No summary available"

    local chapterData = {}
    if chapterIDElements then
        for __, option in pairs(chapterIDElements) do
            if option.attributes.value then
                table.insert(
                    chapterData,
                    { id = option.attributes.value, #chapterData + 1, name = option:getcontent() }
                )
            end
        end
    end

    if #chapterData == 0 then
        local single_chapter_title = root:select(".chapter.preface.group > h3.title")[1]

        if single_chapter_title then
            local content = single_chapter_title:getcontent()
            local chapter_title = string.match(content, "</a>:%s*(.+)") or "Chapter 1"
            local chapter_id = string.match(content, "/chapters/(%d+)")
            table.insert(chapterData, { id = chapter_id, #chapterData + 1, name = "1. " .. chapter_title })
        end
    end

    local tags = {}
    if tagsElement then
        for _, tag in ipairs(tagsElement:select("li > a")) do
            local content = encodeHelper:parseToCodepoints(tag:getcontent())
            if content then
                table.insert(tags, content)
            end
        end
    end

    local relationships = {}
    if relationshipsElement then
        for _, relationship in ipairs(relationshipsElement:select("li > a")) do
            local content = encodeHelper:parseToCodepoints(relationship:getcontent())
            if content then
                table.insert(relationships, content)
            end
        end
    end

    local characters = {}
    if charactersElement then
        for _, character in ipairs(charactersElement:select("li > a")) do
            local content = encodeHelper:parseToCodepoints(character:getcontent())
            if content then
                table.insert(characters, content)
            end
        end
    end

    local warnings = {}
    if warningsElement then
        for _, warning in ipairs(warningsElement:select("li > a")) do
            local content = encodeHelper:parseToCodepoints(warning:getcontent())
            if content then
                table.insert(warnings, content)
            end
        end
    end

    -- Extract additional metadata values
    local fandoms = {}
    if fandomElement then
        for _, fandom in ipairs(fandomElement:select("li > a")) do
            local content = encodeHelper:parseToCodepoints(fandom:getcontent())
            if content then
                table.insert(fandoms, content)
            end
        end
    end

    local publishedDate = publishedElement and encodeHelper:parseToCodepoints(publishedElement:getcontent()) or "Unknown date"
    local updatedDate = updatedElement and encodeHelper:parseToCodepoints(updatedElement:getcontent()) or "Unknown date"
    local chapters = chaptersElement and encodeHelper:parseToCodepoints(chaptersElement:getcontent():gsub("<[^>]+>", ""))
        or "Unknown chapters"
    local language = languageElement and encodeHelper:parseToCodepoints(languageElement:getcontent()) or "Unknown language"

    -- Extract EPUB link
    local epub_link = nil
    for _, e in ipairs(epubElement) do
        if encodeHelper:parseToCodepoints(e:getcontent()):lower() == "epub" then
            epub_link = getAO3URL() .. e.attributes.href
            break
        end
    end

    -- Extract stats values
    local hits = hitsElement and encodeHelper:parseToCodepoints(hitsElement:getcontent():gsub("<[^>]+>", "")) or "0"
    local kudos = kudosElement and encodeHelper:parseToCodepoints(kudosElement:getcontent():gsub("<[^>]+>", "")) or "0"
    local comments = commentsElement and encodeHelper:parseToCodepoints(commentsElement:getcontent():gsub("<[^>]+>", "")) or "0"
    local bookmarks = bookmarksElement and encodeHelper:parseToCodepoints(bookmarksElement:getcontent():gsub("<[^>]+>", "")) or "0"
    local wordcount = wordCountElement and wordCountElement:getcontent():gsub(",", "") or "unknown"

    local iswip = iswipElement and iswipElement:getcontent():gsub(":", "") -- Remove colon
    if iswip == "Completed" then
        iswip = "Complete"
    elseif iswip == "Updated" then
        iswip = "Work in Progress"
    end

    -- Return metadata as a table
    local work = {
        title = title,
        author = author,
        gifted_to = gifted_to,
        chapterData = chapterData,
        summary = summary,
        tags = #tags > 0 and table.concat(tags, ", ") or "No tags available",
        relationships = relationships or {},
        characters = characters or {},
        warnings = warnings or {},
        fandoms = fandoms or {},
        published = publishedDate,
        updated = updatedDate,
        wordcount = wordcount,
        chapters = chapters,
        language = language,
        epub_link = epub_link or nil,
        hits = hits,
        kudos = kudos,
        comments = comments,
        bookmarks = bookmarks,
        rating = ratingElement and ratingElement:getcontent(),
        category = categoryElement and categoryElement:getcontent(),
        iswip = iswip,
    }

    return work
end

function AO3WebParser:parseUserPage(root)
    -- Implementation for parsing user page goes here
    local user_fandoms = root:select("div #user-fandoms > ol > li")


    local fandom_list = {}

    for _, fandom in pairs(user_fandoms) do
        local name = encodeHelper:parseToCodepoints(fandom:select("a")[1]:getcontent())
        local count = fandom:getcontent():gsub("<a[^>]*>.-</a>", ""):match("%((%d+)%)")
        local fandom_id = fandom:select("a")[1].attributes.href:match("fandom_id=(%d+)")
        if name then
            table.insert(fandom_list, {name = name, count = count and tonumber(count) or 0, id = fandom_id})
        end
    end

    local username_element = root:select("div.primary > h2.heading")[1]
    local author_full = username_element and encodeHelper:parseToCodepoints(username_element:getcontent())
    author_full = author_full and author_full:gsub("%s+","") or "Unknown User"

    local username, pseud
    if string.find(author_full, "%(") and string.find(author_full, "%)") then
        username = string.match(author_full, "%((.-)%)")
        pseud = string.match(author_full, "^(.-)%s*%(")
    else
        username = author_full
        pseud = author_full
    end

    local total_pseuds_search = T("a[href$='%1/pseuds']", username)
    local total_pseuds_element = root:select(total_pseuds_search)[1]

    local total_pseuds = nil
    if total_pseuds_element then
        local total_pseuds_text = total_pseuds_element:getcontent()
        total_pseuds = total_pseuds_text:match("All Pseuds%s*%((%d+)%)")

        total_pseuds = tonumber(total_pseuds)
    end

    local total_works_search = T("[href$='%1/works']", pseud)
    local total_works_element = root:select(total_works_search)[1]

    local total_works = nil
    if total_works_element then
        local total_works_text = total_works_element:getcontent()
        total_works = total_works_text:match("Works%s*%((%d+)%)")

        total_works = tonumber(total_works)
    end

    local total_series_search = T("[href$='%1/series']", pseud)
    local total_series_element = root:select(total_series_search)[1]

    local total_series = nil

    if total_series_element then
        local total_series_text = total_series_element:getcontent()
        total_series = total_series_text:match("Series%s*%((%d+)%)")
        logger.dbg("AO3Downloader.koplugin: Found total series text: " .. tostring(total_series_text) .. ", extracted total series: " .. tostring(total_series))

        total_series = tonumber(total_series)
    end

    local total_bookmarks_search = T("[href$='%1/bookmarks']", pseud)
    local total_bookmarks_element = root:select(total_bookmarks_search)[1]
    local total_bookmarks = nil

    if total_bookmarks_element then
        local total_bookmarks_text = total_bookmarks_element:getcontent()
        total_bookmarks = total_bookmarks_text:match("Bookmarks%s*%((%d+)%)")

        total_bookmarks = tonumber(total_bookmarks)
    end

    local total_collections_search = T("[href$='%1/collections']", username)
    local total_collections_element = root:select(total_collections_search)[1]
    local total_collections = nil

    if total_collections_element then
        local total_collections_text = total_collections_element:getcontent()
        total_collections = total_collections_text:match("Collections%s*%((%d+)%)")

        total_collections = tonumber(total_collections)
    end

    local total_gifts_search = T("[href$='%1/gifts']", username)
    local total_gifts_element = root:select(total_gifts_search)[1]
    local total_gifts = nil

    if total_gifts_element then
        local total_gifts_text = total_gifts_element:getcontent()
        total_gifts = total_gifts_text:match("Gifts%s*%((%d+)%)")

        total_gifts = tonumber(total_gifts)
    end

    return {
        username = username,
        pseud = pseud,
        fandoms = fandom_list,
        total_pseuds = total_pseuds or 1,
        total_works = total_works or 0,
        total_series = total_series or 0,
        total_bookmarks = total_bookmarks or 0,
        total_collections = total_collections or 0,
        total_gifts = total_gifts or 0,
    }
end

function AO3WebParser:parseUserPseuds(root)
    local pseuds = {}
    local elements = root:select("li.pseud")

    local count = 1

    for _, element in ipairs(elements) do
        local pseudElement = element:select("h4.heading > a")[1]
        if pseudElement then
            local pseud_name = encodeHelper:parseToCodepoints(pseudElement:getcontent())

            local worksElement = element:select("h5.heading > a[href$='/works']")[1]
            local recsElement = element:select("h5.heading > a[href$='recs_only=true']")[1]

            local work_count = nil
            local rec_count = nil

            if worksElement then
                local works_text = worksElement:getcontent()
                work_count = tonumber(works_text:match("([%d,]+) works"):gsub(",", ""), 10)
            end

            if recsElement then
                local recs_text = recsElement:getcontent()
                rec_count = tonumber(recs_text:match("([%d,]+) rec"):gsub(",", ""), 10)
            end

            local pseud = {
                name = pseud_name,
                works_count = work_count or 0,
                recs_count = rec_count or 0,
            }

            table.insert(pseuds, count, pseud)
            count = count + 1
        end
    end

    return pseuds
end

function AO3WebParser:parseUserSearchResults(root)
    local users = {}
    local elements = root:select("li.user")

    local count = 1

    for _, element in ipairs(elements) do
        local usernameElements = element:select("h4.heading > a")
        if usernameElements then
            local username = nil
            local pseud = nil
            local work_count = nil
            local bookmark_count = nil

            if usernameElements[2] == nil then
                username = encodeHelper:parseToCodepoints(usernameElements[1]:getcontent())
                pseud = username
            else
                username = encodeHelper:parseToCodepoints(usernameElements[2]:getcontent())
                pseud = usernameElements[1]:getcontent()
            end

            local worksElement = element:select("h5.heading > a[href$='/works']")[1]
            local bookmarksElement = element:select("h5.heading > a[href$='/bookmarks']")[1]

            if worksElement then
                local works_text = worksElement:getcontent()
                work_count = tonumber(works_text:match("([%d,]+) works"):gsub(",", ""), 10)
            end

            if bookmarksElement then
                local bookmarks_text = bookmarksElement:getcontent()
                bookmark_count = tonumber(bookmarks_text:match("([%d,]+) bookmarks"):gsub(",", ""), 10)
            end





            local user = {
                username = username,
                pseud = pseud,
                works_count = work_count or 0,
                bookmarks_count = bookmark_count or 0,
            }

            table.insert(users, count, user)
            count = count + 1
        end
    end

    return users
end


-- HTTPQueryHandler
HTTPQueryHandler.cookies = {}

local function parseSetCookie(set_cookie_value)
    local function isParameter(targetString)
        local parameter_names = { "Domain", "Expires", "HttpOnly", "Max-Age", "Partioned", "Path", "SameSite", "Secure" }
        for _, value in ipairs(parameter_names) do
            if string.lower(targetString) == string.lower(value) then
                return true
            end
        end
        return false
    end

    local cookies_values = {}
    -- Split the set-cookie string by ',' or ';' to handle each part separately
    local parts = {}
    local in_expires = false
    local buffer = ""

    for part in set_cookie_value:gmatch("[^,;]+") do
        -- Allow for expires value to contain single ,
        if part:find("expires=", 1, true) then
            in_expires = true
            buffer = part
        elseif in_expires then
            buffer = buffer .. "," .. part
            if part:find(" ") then
                table.insert(parts, buffer)
                in_expires = false
                buffer = ""
            end
        else
            table.insert(parts, part)
        end
    end

    if buffer ~= "" then
        table.insert(parts, buffer)
    end

    local current_cookie = nil
    for _, part in ipairs(parts) do
        -- Trim leading and trailing spaces
        part = part:match("^%s*(.-)%s*$")
        -- Match key-value pairs or key-only values
        local name, value = part:match("([^=]+)=?(.*)")
        if not isParameter(name) and value ~= "" and value ~= nil then
            if current_cookie then
                table.insert(cookies_values, current_cookie)
            end
            current_cookie = {}
            current_cookie["name"] = name
            current_cookie["value"] = value
        elseif name then
            current_cookie[name] = value or true
        end
    end
    if current_cookie then
        table.insert(cookies_values, current_cookie)
    end

    return cookies_values
end

function HTTPQueryHandler:saveCookiesToConfig()
    Config:saveSetting("cookies", self.cookies)
end

function HTTPQueryHandler:loadCookiesFromConfig()
    local savedCookies = Config:readSetting("cookies")
    if savedCookies then
        self.cookies = savedCookies
    end
end

function HTTPQueryHandler:getCookies(custom_cookies, url)
    self:loadCookiesFromConfig()
    local cookieHeader = {}
    local request_domain = url:match("^(https?://[^/]+)")
    local cookies_for_this_domain = self.cookies[request_domain];

    if cookies_for_this_domain == nil then
        return "";
    end

    for __, cookie in pairs(cookies_for_this_domain) do
        table.insert(cookieHeader, T("%1=%2", cookie.name, cookie.value))
    end

    if custom_cookies then
        for key, value in pairs(custom_cookies) do
            table.insert(cookieHeader, T("%1=%2", key, value))
        end
    end

    return table.concat(cookieHeader, "; ");
end

function HTTPQueryHandler:setCookies(response_headers, request_url)
    local request_domain = request_url:match("^(https?://[^/]+)")
    if response_headers["set-cookie"] then
        local set_cookie_value = response_headers["set-cookie"]
        local parsed_cookies = parseSetCookie(set_cookie_value)

        for _, current_cookie in ipairs(parsed_cookies) do
            if not self.cookies[request_domain] then
                self.cookies[request_domain] = {}
            end
            self.cookies[request_domain][current_cookie.name] = current_cookie
        end

        self:saveCookiesToConfig()
    end
end

function HTTPQueryHandler.get_default_headers()
    return {
        ["User-Agent"] = "Mozilla/5.0 (platform; rv:gecko-version) Gecko/gecko-trail Firefox/firefox-version",
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "en-US,en;q=0.5",
        ["Sec-GPC"] = 1,
        ["Connection"] = "keep-alive",
        ["DNT"] = "1", -- Do Not Track
    }
end

function HTTPQueryHandler:performHTTPRequest(request, retries)
    local max_retries = retries or 3;

    local response, status, response_headers

    request.headers = request.headers or self.get_default_headers()
    request.headers["Cookie"] = HTTPQueryHandler:getCookies(request.cookies, request.url);



    logger.dbg("AO3Downloader.koplugin: Peforming HTTP request to :" .. request.url);



    for i = 1, max_retries do
        logger.dbg("AO3Downloader.koplugin: Attempt " .. (i) .. " for URL: " .. request.url)
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        response, status, response_headers = https.request({
            url = request.url,
            method = request.method or "GET",
            headers = request.headers,
            sink = request.sink,
            source = request.source,
            protocol = "tlsv1_3",
            options = "all",
        })

        -- Parse cookies from set_cookie
        if response_headers then
            HTTPQueryHandler:setCookies(response_headers, request.url)
        end

        -- deal out redirects
        if status == 301 and response_headers["location"] then
            local new_url = response_headers["location"]
            logger.dbg("AO3Downloader.koplugin: Redirecting to new URL: " .. new_url)
            request.url = new_url -- Update the request URL
            return self:performHTTPRequest(request, retries) -- Recursive call for the new URL
        elseif response == 1 then
            socketutil:reset_timeout()
            return {
                success = true,
                response = response,
                response_headers = response_headers,
                status = status,
            }
        end

    end

    logger.dbg("AO3Downloader.koplugin: Request failed after " .. max_retries .. " attempts. Status: " .. tostring(status))
    return {
        success = false,
        response = response,
        response_headers = response_headers,
        status = status,
    }
end

return AO3DownloaderClient
