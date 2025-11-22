local htmlparser = require("htmlparser")
htmlparser_looplimit = 1000000000
local logger = require("logger")
local https = require("ssl.https") -- Use luasec for HTTPS requests
local ltn12 = require("ltn12")
local Paths = require("FanficPaths")
local Config = require("fanfic_config")
local socketutil = require("socketutil")
local socket = require("socket")
local util = require("util")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template

local AO3Downloader = {}

local cookies = {}

local function urlEncode(str)
    if str then
        str = str:gsub("([^%w%-%.%_%~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
    end
    return str
end

local function formEncode(str)
    if str then
        str = string.gsub(str, " ", "+")
        str = str:gsub("([^%w%-%.%_%~%+])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
    end
    return str
end

local function saveCookiesToConfig()
    Config:saveSetting("cookies", cookies)
end

local function loadCookiesFromConfig()
    local savedCookies = Config:readSetting("cookies")
    if savedCookies then
        cookies = savedCookies
    end
end


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

    logger.dbg(set_cookie_value)
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
        if not isParameter(name) then
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

local function get_default_headers()
    return {
        ["User-Agent"] = "Mozilla/5.0 (platform; rv:gecko-version) Gecko/gecko-trail Firefox/firefox-version",
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "en-US,en;q=0.5",
        ["Sec-GPC"] = 1,
        ["Connection"] = "keep-alive",
        ["DNT"] = "1", -- Do Not Track
    }
end

local function getAO3URL()
    return Config:readSetting("AO3_domain")
end

local function getCookies(custom_cookies, url, method)
    loadCookiesFromConfig() -- Ensure cookies are loaded from the config
    local cookieHeader = {}
    local request_domain = url:match("^(https?://[^/]+)")
    local cookies_for_this_domain = cookies[request_domain]

    if cookies_for_this_domain == nil then
        return ""
    end

    for __, cookie in pairs(cookies_for_this_domain) do
            table.insert(cookieHeader, cookie.name .. "=" .. cookie.value)
    end

    if custom_cookies then
        for key, value in pairs(custom_cookies) do
            table.insert(cookieHeader, key .. "=" .. value)
        end
    end

    return table.concat(cookieHeader, "; ")
end

local function setCookies(responseHeaders, url)
    local request_domain = url:match("^(https?://[^/]+)")
    if responseHeaders["set-cookie"] then
        local set_cookie_value = responseHeaders["set-cookie"]
        local parsed_cookies = parseSetCookie(set_cookie_value)

        for _, current_cookie in ipairs(parsed_cookies) do
            if not cookies[request_domain] then
                cookies[request_domain] = {}
            end
            cookies[request_domain][current_cookie.name] = current_cookie
        end

        saveCookiesToConfig()
    end
end

local function generateParametersStringURL(parameters)
    local query = {}

    for key, value in pairs(parameters) do
        table.insert(query, string.format("%s=%s", urlEncode(key), urlEncode(value)))
    end

    local queryString = table.concat(query, "&")

    return queryString
end

local function generateParametersStringForm(parameters)
    local query = {}

    for key, value in pairs(parameters) do
        table.insert(query, string.format("%s=%s", urlEncode(key), formEncode(value)))
    end

    local queryString = table.concat(query, "&")

    return queryString
end

local unescape_map = {
    ["lt"] = "<",
    ["gt"] = ">",
    ["amp"] = "&",
    ["quot"] = '"',
    ["apos"] = "'",
}

local gsub = string.gsub
local function unescape(str)
    return gsub(str, "(&(#?)([%d%a]+);)", function(orig, n, s)
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
end
-- Helper function to handle retries for HTTPS requests
local function performHttpsRequest(request, retries)
    local max_retries = retries or 3
    local response, status, response_headers

    -- Add cookies to the request headers
    logger.dbg("Request URL: " .. request.url)
    request.headers = request.headers or {}
    request.headers["Cookie"] = getCookies(request.cookies, request.url, request.method)

    for i = 0, max_retries do
        logger.dbg("Attempt " .. (i + 1) .. " for URL: " .. request.url)
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        response, status, response_headers = https.request({
            url = request.url,
            method = request.method or "GET",
            headers = request.headers,
            sink = request.sink,
            source = request.source,
            protocol = "tlsv1_3", -- Explicitly set the protocol
            options = "all",
        })

        -- Parse and store cookies from the response
        if response_headers then
            setCookies(response_headers, request.url)
        end

        logger.dbg("Response status: " .. tostring(status))

        -- handle redirects
        if status == 301 and response_headers["location"] then
            local new_url = response_headers["location"]
            logger.dbg("Redirecting to new URL: " .. new_url)
            request.url = new_url -- Update the request URL
            return performHttpsRequest(request, retries) -- Recursive call for the new URL
        elseif response == 1 then
            socketutil:reset_timeout()
            return response, status, response_headers -- Exit if the request succeeds
        elseif i == max_retries then
            logger.dbg("Request failed after " .. max_retries .. " attempts. Status: " .. tostring(status))
            return nil, "Failed to connect using available protocols", nil
        end

        -- Add a sleep to prevent rate limiting
        socket.sleep(1)
    end

    return nil, "Failed to connect using available protocols", nil
end

local function requestAO3Token()
    local url = getAO3URL() .. "/token_dispenser.json"
    local response_body = {}

    local headers = get_default_headers()
    headers["Accept"] = "application/json, text/javascript, */*; q=0.01"
    headers["Accept-Encoding"] = nil

    logger.dbg("Requesting AO3 token from:", url)

    local request = {
        url = url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body),
    }

    local response, status = performHttpsRequest(request)

    if not response then
        logger.dbg("Failed to fetch AO3 token. Status:", status or "unknown error")
        return nil, "Failed to fetch AO3 token"
    end

    local body = table.concat(response_body)

    -- Parse the JSON response to extract the token
    local json = require("dkjson")
    local success, token_data = pcall(json.decode, body)

    if not success then
        logger.dbg("Failed to decode JSON response. Error:", token_data)
        return nil, "Invalid JSON response"
    end

    if token_data and token_data.token then
        AO3_Token = token_data.token
        logger.dbg("AO3 token successfully retrieved and saved.")
        return AO3_Token
    else
        logger.dbg("Failed to parse AO3 token from response.")
        return nil, "Invalid token response"
    end
end

local SessionManager = {}

function SessionManager:StartLoggedInSession(username, password)
    -- Step 1: Perform a basic request to the AO3 homepage to initialize cookies
    local homepage_url = getAO3URL()
    local response_body = {}

    local headers = get_default_headers()
    logger.dbg("Initializing session by visiting AO3 homepage:", homepage_url)

    local request = {
        url = homepage_url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body),
    }

    local response, status, response_headers = performHttpsRequest(request, 1)

    if not response then
        logger.dbg("Failed to initialize session. Status:", status or "unknown error")
        return false
    end

    -- Step 2: Request the authenticity token
    local authenticity_token = requestAO3Token()
    if not authenticity_token then
        return false
    end

    -- Step 3: Perform the login request
    local login_url = getAO3URL() .. "/users/login"
    response_body = {}

    local headers = get_default_headers()
    headers["Content-Type"] = "application/x-www-form-urlencoded"

    local form_data = generateParametersStringForm({
        ["authenticity_token"] = authenticity_token,
        ["user[login]"] = username,
        ["user[password]"] = password,
        ["commit"] = "Log+In",
    })
    headers["Content-Length"] = tostring(#form_data)

    logger.dbg("Logging in to AO3 with URL:", login_url)

    request = {
        url = login_url,
        method = "POST",
        headers = headers,
        sink = ltn12.sink.table(response_body),
        source = ltn12.source.string(form_data),
    }

    response, status, response_headers = performHttpsRequest(request, 1)

    if status ~= 302 then
        logger.dbg("Login failed. Status:", status or "unknown error")
        return false
    end

    local headers = get_default_headers()
    -- Step 4: Follow the redirect to finalize the session
    local redirect_url = response_headers["location"] or homepage_url
    response_body = {}

    logger.dbg("Following redirect to:", redirect_url)

    request = {
        url = redirect_url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body),
    }

    response, status = performHttpsRequest(request, 3)

    if not response then
        logger.dbg("Failed to finalize session. Status:", status or "unknown error")
        return false
    end

    -- Step 5: Check if the user is logged in by looking for the "logged-in" class in the <body> tag
    local body_content = table.concat(response_body)

    -- Use a more flexible pattern to match the logged-in class
    if body_content:find('<body[^>]*class="[^"]*logged%-in[^"]*"') then
        logger.dbg("Session successfully initialized and logged in.")
        return true
    else
        logger.dbg("Login failed. User is not logged in.")
        return false
    end
end

function SessionManager:EndLoggedInSession()
    -- Step 1: Request the authenticity token
    local authenticity_token = requestAO3Token()
    if not authenticity_token then
        return false
    end

    -- Step 3: Perform the log out request
    local logout_url = getAO3URL() .. "/users/logout"
    local response_body = {}

    local headers = get_default_headers()
    headers["Content-Type"] = "application/x-www-form-urlencoded"

    local form_data = generateParametersStringForm({
        ["_method"] = "delete",
        ["authenticity_token"] = authenticity_token,
    })
    headers["Content-Length"] = tostring(#form_data)

    logger.dbg("Logging out of AO3 with URL:", logout_url)

    local request = {
        url = logout_url,
        method = "POST",
        headers = headers,
        sink = ltn12.sink.table(response_body),
        source = ltn12.source.string(form_data),
    }

    local response, status, response_headers = performHttpsRequest(request, 1)

    if status ~= 302 then
        logger.dbg("Log out failed. Status:", status or "unknown error")
        return false
    end

    local headers = get_default_headers()
    -- Step 4: Follow the redirect to finalize the session
    local redirect_url = response_headers["location"] or homepage_url
    response_body = {}

    logger.dbg("Following redirect to:", redirect_url)

    local request = {
        url = redirect_url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body),
    }

    local response, status = performHttpsRequest(request, 3)

    if not response then
        logger.dbg("Failed to finalize closing session. Status:", status or "unknown error")
        return false
    end

    -- Step 5: Check if the user is logged in by looking for the "logged-in" class in the <body> tag
    local body_content = table.concat(response_body)
    logger.dbg("Final HTML body content: ", body_content)

    -- Use a more flexible pattern to match the logged-in class
    if body_content:find('<body[^>]*class="[^"]*logged%-out[^"]*"') then
        logger.dbg("Session successfully ended and logged out.")
        return true
    else
        logger.dbg("Log out failed. User is still logged in.")
        return false
    end
end

function SessionManager:GetSessionStatus()
    -- Step 1: Perform a basic request to the AO3 homepage to initialize cookies
    local homepage_url = getAO3URL()
    local response_body = {}

    local headers = get_default_headers()
    logger.dbg("Initializing session by visiting AO3 homepage:", homepage_url)

    local request = {
        url = homepage_url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body),
    }

    local response, status, response_headers = performHttpsRequest(request, 1)

    if not response then
        logger.dbg("Failed to get session status. Status:", status or "unknown error")
        return false
    end

    local body_content = table.concat(response_body)

    -- Use a more flexible pattern to match the logged-in class
    if body_content:find('<body[^>]*class="[^"]*logged%-in[^"]*"') then
        logger.dbg("Session: logged in")
        local username = body_content:match('<a href="/users/([%w_]+)"')
        return true, true, username
    else
        logger.dbg("Session: logged out")
        return true, false, nil
    end
end

local function parseToCodepoints(str)
    return unescape(str)
end

function AO3Downloader:parseSearchResults(root)
    local works = {}
    local elements = root:select("li.work") -- Adjust the selector based on AO3's HTML structure

    logger.dbg("Number of works found: " .. #elements)
    local count = 1

    -- Extract the total number of works from the resultsCountElement
    local resultsCountElement = root:select("#main > h3")[1]
    if resultsCountElement then
        local resultsText = resultsCountElement:getcontent()
        -- Match a number at the beginning of the string, ignoring leading spaces
        local totalWorks = resultsText:match("^%s*([%d,]+) Found")
        if totalWorks then
            totalWorks = tonumber(totalWorks:gsub(",", ""), 10) -- Remove commas and convert to a number
            works["total"] = totalWorks
        end
    end

    if not works["total"] then
        local resultsCountElement = root:select("#main > h2")[1]
        if resultsCountElement then
            local resultsText = resultsCountElement:getcontent()
            -- Match the number after "of" and before "Works"
            local totalWorks = resultsText:match("of%s*([%d,]+)%s*Works")
            if not totalWorks then
                -- Fallback: Match the number at the beginning of the string followed by "Works"
                totalWorks = resultsText:match("^%s*([%d,]+)%s*Works")
            end
            if totalWorks then
                totalWorks = totalWorks:gsub(",", "") -- Remove commas and convert to a number
                works["total"] = tonumber(totalWorks)
            end
        end
    end

    for _, element in ipairs(elements) do
        local titleElement = element:select(".heading > a")[1]
        local restrictedElement = element:select("img[title='Restricted']")[1]
        local authorElement = element:select(".heading > a[rel='author']")[1]
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
                        local content = parseToCodepoints(tag:getcontent())
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
                        local content = parseToCodepoints(relationship:getcontent())
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
                        local content = parseToCodepoints(character:getcontent())
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
                        local content = parseToCodepoints(warning:getcontent())
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
                    local content = parseToCodepoints(fandom:getcontent())
                    if content then
                        table.insert(fandoms, content)
                    end
                end
            end

            -- Extract additional metadata
            local date = dateElement and parseToCodepoints(dateElement:getcontent()) or "N/A"
            local language = languageElement and parseToCodepoints(languageElement:getcontent()) or "N/A"
            local words = wordsElement and parseToCodepoints(wordsElement:getcontent()) or "N/A"
            local chapters = chaptersElement and parseToCodepoints(chaptersElement:getcontent():gsub("<[^>]+>", ""))
                or "N/A"
            local hits = hitsElement and parseToCodepoints(hitsElement:getcontent():gsub("<[^>]+>", "")) or "0"
            local comments = commentsElement and parseToCodepoints(commentsElement:getcontent():gsub("<[^>]+>", ""))
                or "0"
            local kudos = kudosElement and parseToCodepoints(kudosElement:getcontent():gsub("<[^>]+>", "")) or "0"
            local bookmarks = bookmarksElement and parseToCodepoints(bookmarksElement:getcontent():gsub("<[^>]+>", ""))
                or "0"
            local rating = ratingElement and ratingElement.attributes["title"] or "N/A"
            local category = categoryElement and categoryElement.attributes["title"] or "N/A"
            local iswip = iswipElement and iswipElement.attributes["title"] or "N/A"
            local author = authorElement and parseToCodepoints(authorElement:getcontent()) or "N/A"
            local tags = #tags > 0 and table.concat(tags, ", ") or "N/A"

            -- Remove HTML formatting, replace <br> with new lines, and preserve paragraph formatting
            local summary = summaryElement
                    and parseToCodepoints(
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
                and parseToCodepoints(titleElement:getcontent():gsub("<[^>]+>", ""):gsub("^%s*(.-)%s*$", "%1"))
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

            -- Add the work to the list
            table.insert(works, count, work)
            count = count + 1
        end
    end

    return works
end

function AO3Downloader:getWorkMetadata(work_id)
    local url = string.format("%s/works/%s", getAO3URL(), work_id)
    local response_body = {}

    local headers = get_default_headers()

    logger.dbg("Fetching metadata for work ID:", work_id)

    local request = {
        url = url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body),
        cookies = { ["view_adult"] = "true" },
    }

    local response, status = performHttpsRequest(request)

    if not response then
        logger.dbg("Failed to fetch work metadata. Status:", status or "unknown error")
        return nil, "Failed to fetch work metadata"
    end

    local body = table.concat(response_body)
    local root = htmlparser.parse(body)

    -- Extract metadata
    local titleElement = root:select(".title")[1]
    local authorElement = root:select("a[rel='author']")[1]
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
        and parseToCodepoints(titleElement:getcontent():gsub("<[^>]+>", ""):gsub("^%s*(.-)%s*$", "%1"))
        or "Unknown title"
    local author = authorElement and parseToCodepoints(authorElement:getcontent()) or "Unknown author"
    local summary = summaryElement
        and parseToCodepoints(
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
            local content = parseToCodepoints(tag:getcontent())
            if content then
                table.insert(tags, content)
            end
        end
    end

    local relationships = {}
    if relationshipsElement then
        for _, relationship in ipairs(relationshipsElement:select("li > a")) do
            local content = parseToCodepoints(relationship:getcontent())
            if content then
                table.insert(relationships, content)
            end
        end
    end

    local characters = {}
    if charactersElement then
        for _, character in ipairs(charactersElement:select("li > a")) do
            local content = parseToCodepoints(character:getcontent())
            if content then
                table.insert(characters, content)
            end
        end
    end

    local warnings = {}
    if warningsElement then
        for _, warning in ipairs(warningsElement:select("li > a")) do
            local content = parseToCodepoints(warning:getcontent())
            if content then
                table.insert(warnings, content)
            end
        end
    end

    -- Extract additional metadata values
    local fandoms = {}
    if fandomElement then
        for _, fandom in ipairs(fandomElement:select("li > a")) do
            local content = parseToCodepoints(fandom:getcontent())
            if content then
                table.insert(fandoms, content)
            end
        end
    end

    local publishedDate = publishedElement and parseToCodepoints(publishedElement:getcontent()) or "Unknown date"
    local updatedDate = updatedElement and parseToCodepoints(updatedElement:getcontent()) or "Unknown date"
    local chapters = chaptersElement and parseToCodepoints(chaptersElement:getcontent():gsub("<[^>]+>", ""))
        or "Unknown chapters"
    local language = languageElement and parseToCodepoints(languageElement:getcontent()) or "Unknown language"

    -- Extract EPUB link
    local epub_link = nil
    for _, e in ipairs(epubElement) do
        if parseToCodepoints(e:getcontent()):lower() == "epub" then
            epub_link = getAO3URL() .. e.attributes.href
            break
        end
    end

    -- Extract stats values
    local hits = hitsElement and parseToCodepoints(hitsElement:getcontent():gsub("<[^>]+>", "")) or "0"
    local kudos = kudosElement and parseToCodepoints(kudosElement:getcontent():gsub("<[^>]+>", "")) or "0"
    local comments = commentsElement and parseToCodepoints(commentsElement:getcontent():gsub("<[^>]+>", "")) or "0"
    local bookmarks = bookmarksElement and parseToCodepoints(bookmarksElement:getcontent():gsub("<[^>]+>", "")) or "0"
    local wordcount = wordCountElement and wordCountElement:getcontent():gsub(",", "") or "unknown"

    local iswip = iswipElement and iswipElement:getcontent():gsub(":", "") -- Remove colon
    if iswip == "Completed" then
        iswip = "Complete"
    elseif iswip == "Updated" then
        iswip = "Work in Progress"
    end

    -- Return metadata as a table
    local work = {
        id = work_id,
        title = title,
        author = author,
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

function AO3Downloader:downloadEpub(link, filename)
    if not link or not link:match("^https?://") then
        logger.dbg("Invalid or missing URL for EPUB download: " .. tostring(link))
        return false
    end

    local path =  T("%1/%2.epub", Config:readSetting("fanfic_folder_path"), filename)

    local file, err = io.open(path, "w")
    if not file then
        logger.dbg("Failed to open file for writing: " .. tostring(err))
        return false
    end

    local headers = get_default_headers()
    headers["Accept"] = "application/epub+zip"

    local request = {
        url = link,
        headers = headers,
        sink = socketutil.file_sink(file),
    }

    local response, status = performHttpsRequest(request, nil)

    if not response then
        logger.dbg("Failed to download EPUB. HTTP status code: " .. tostring(status))
        return false
    end

    logger.dbg("EPUB downloaded successfully: " .. path)
    return true, path
end

function AO3Downloader:searchFic(parameters, page)
    page = page or 1 -- Default to the first page if no page is specified
    local query = {}

    -- Build the query string from the parameters
    for key, value in pairs(parameters) do
        if value == "" then
            table.insert(query, string.format("%s=", urlEncode(key))) -- Include empty parameters
        elseif type(value) == "table" then
            -- Handle nested parameters (e.g., include_work_search[character_ids][])
            for _, subValue in ipairs(value) do
                table.insert(query, string.format("%s=%s", urlEncode(key), urlEncode(subValue))) -- Encode [] as %5B%5D
            end
        else
            table.insert(query, string.format("%s=%s", urlEncode(key), urlEncode(value)))
        end
    end

    table.insert(query, "page=" .. page) -- Add the page number to the query
    local queryString = table.concat(query, "&")

    -- Construct the full URL
    local url = string.format("%s/works?commit=Sort+and+Filter&%s", getAO3URL(), queryString)
    local response_body = {}

    local headers = get_default_headers()

    logger.dbg("Starting search request to:", url)

    local request = {
        url = url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body),
    }

    local response, status = performHttpsRequest(request)

    if not response then
        logger.dbg("Search request failed. Status:", status or "unknown error")
        return nil, "Search request failed"
    end

    local body = table.concat(response_body)

    -- Parse the HTML response
    local root = htmlparser.parse(body)
    local works = self:parseSearchResults(root)

    return works
end

function AO3Downloader:searchByTag(tag_name, page, sort_column)
    page = page or 1 -- Default to the first page if no page is specified
    sort_column = sort_column or "revised_at" -- Default to sorting by most recently updated

    -- Encode the tag name for use in the URL
    local encoded_tag_name = tag_name
        :gsub("/", "*s*") -- Replace / with */*
        :gsub(" & ", "*a*")

    encoded_tag_name = urlEncode(encoded_tag_name)
    -- Construct the URL
    local url = string.format(
        "%s/tags/%s/works?page=%d&work_search[sort_column]=%s",
        getAO3URL(),
        encoded_tag_name,
        page,
        sort_column
    )

    logger.dbg("Starting search request to:", url)

    local response_body = {}
    local headers = get_default_headers()

    local request = {
        url = url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body),
    }

    local response, status = performHttpsRequest(request)

    if not response then
        logger.dbg("Search request failed. Status:", status or "unknown error")
        return nil, "Search request failed"
    end

    local body = table.concat(response_body)

    -- Parse the HTML response
    local root = htmlparser.parse(body)
    local works = self:parseSearchResults(root)

    return works
end

function AO3Downloader:searchForTag(query, type)
    if not query or query == "" then
        return nil, "Search query cannot be empty"
    end

    if not type then
        type = "Fandom"
    end

    -- Encode the query for use in the URL
    local encoded_query = urlEncode(query)

    -- Construct the URL for the fandom search with `wrangling_status` set to `canonical`
    local url = string.format(
        "%s/tags/search?tag_search%%5Bname%%5D=%s&tag_search%%5Bfandoms%%5D=&tag_search%%5Btype%%5D=%s&tag_search%%5Bwrangling_status%%5D=canonical&tag_search%%5Bsort_column%%5D=uses&tag_search%%5Bsort_direction%%5D=desc&commit=Search+Tags",
        getAO3URL(),
        encoded_query,
        type
    )

    logger.dbg("Starting fandom search request to:", url)

    local response_body = {}
    local headers = get_default_headers()

    local request = {
        url = url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body),
    }

    local response, status = performHttpsRequest(request)

    if not response then
        logger.dbg("Fandom search request failed. Status:", status or "unknown error")
        return false, nil, "Fandom search request failed"
    end

    local body = table.concat(response_body)

    -- Parse the HTML response
    local root = htmlparser.parse(body)
    local fandom_elements = root:select("li > span > a.tag") -- Adjust the selector based on AO3's HTML structure

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
                    name = parseToCodepoints(fandom_name),
                    uses = tonumber(uses_text),
                })
            end
        end
    end

    return true, fandoms
end

function AO3Downloader:login(username, password)
    local success = SessionManager:StartLoggedInSession(username, password)

    if success then
        logger.dbg("Login successful for user: " .. username)
        return true
    else
        logger.dbg("Login failed for user: " .. username)
        return false, "Failed to log in. Please check your credentials or network connection."
    end
end

function AO3Downloader:logout()
    local success = SessionManager:EndLoggedInSession()

    if success then
        logger.dbg("Log out successful")
        return true
    else
        logger.dbg("Log out failed")
        return false, "Failed to log in. Please check your credentials or network connection."
    end
end

function AO3Downloader:getLoggedIn()
    return SessionManager:GetSessionStatus()
end

function AO3Downloader:kudosWork(work_id)
    local success, logged_in = self:getLoggedIn()

    if not success then
        return false, "Log in check failed"
    end

    if not logged_in then
        return false, "Please log in to your AO3 account"
    end

    local authenticity_token = requestAO3Token()
    if not authenticity_token then
        return false
    end

    -- Step 3: Perform the login request
    local kudos_url = getAO3URL() .. "/kudos.js"
    local response_body = {}

    local headers = get_default_headers()
    headers["Content-Type"] = "application/x-www-form-urlencoded"

    local form_data = generateParametersStringForm({
        ["authenticity_token"] = authenticity_token,
        ["kudo[commentable_id]"] = tostring(work_id),
        ["kudo[commentable_type]"] = "Work",
    })
    headers["Content-Length"] = tostring(#form_data)

    logger.dbg("Attempt to give kudos to work with URL:", kudos_url)

    local request = {
        url = kudos_url,
        method = "POST",
        headers = headers,
        sink = ltn12.sink.table(response_body),
        source = ltn12.source.string(form_data),
    }

    local response, status, response_headers = performHttpsRequest(request, 1)

    if status == 201 then
        logger.dbg("Work " .. work_id .. " has been given kudos")
        return true
    end

    if status == 422 then
        logger.dbg("Work " .. work_id .. " has already been given kudos")
        return false, "Already given kudos"
    end

    logger.dbg("Work has not been given kudos due to unknown error")
    return false, "Unknown error"
end

function AO3Downloader:commentOnWork(comment_content, work_id, chapter_id)
    local success, logged_in = self:getLoggedIn()

    if not success then
        return false, "Log in check failed"
    end

    if not logged_in then
        return false, "Please log in to your AO3 account"
    end

    -- Step 1: Request and parse comment form
    local comment_url = getAO3URL()
        .. ((chapter_id and ("/chapters/" .. chapter_id)) or ("/works/" .. work_id))
        .. "/comments"

    local response_body = {}

    local headers = get_default_headers()

    logger.dbg("Fetching metadata for work ID:", work_id)

    local request = {
        url = comment_url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body),
        cookies = { ["view_adult"] = "true" },
    }

    local response, status = performHttpsRequest(request)

    logger.dbg(table.concat(response_body))

    if not response then
        logger.dbg("Failed to fetch work comment page. Status:", status or "unknown error")
        return nil, "Failed to fetch work comment page"
    end

    local body = table.concat(response_body)
    local root = htmlparser.parse(body)

    local form = root:select("#comment_for_" .. (chapter_id or work_id))[1]
    local authenticity_token = form:select("[name='authenticity_token']")[1].attributes["value"]
    local pseud_id = form:select("[name='comment[pseud_id]']")[1].attributes["value"]

    local headers = get_default_headers()
    headers["Content-Type"] = "application/x-www-form-urlencoded"
    headers["Referer"] = comment_url

    local custom_cookies = {
        ["user_credentials"] = "1",
        ["view_adult"] = "true",
    }

    local form_data = generateParametersStringForm({
        ["authenticity_token"] = authenticity_token,
        ["comment[pseud_id]"] = pseud_id,
        ["comment[comment_content]"] = comment_content,
        ["controller_name"] = "comments",
        ["commit"] = "Comment",
    })
    headers["Content-Length"] = tostring(#form_data)

    logger.dbg("Attempt to comment on work with URL:", comment_url)
    logger.dbg("form data:" .. form_data)

    local request = {
        url = comment_url,
        method = "POST",
        headers = headers,
        sink = ltn12.sink.table(response_body),
        source = ltn12.source.string(form_data),
        cookies = custom_cookies,
    }

    local response, status, response_headers = performHttpsRequest(request, 1)

    if response == 1 then
        logger.dbg("Comment has been submitted to: " .. work_id)
        return true
    end

    logger.dbg("Work has not been commented on due to unknown error")
    return false, "Unknown error"
end

return AO3Downloader
