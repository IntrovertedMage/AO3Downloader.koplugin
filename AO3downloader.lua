local htmlparser = require("htmlparser")
htmlparser_looplimit = 1000000000
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local ssl = require("ssl")
local https = require("ssl.https") -- Use luasec for HTTPS requests
local ltn12 = require("ltn12")
local Paths = require("FanficPaths")
local Config = require("config")
local socketutil = require("socketutil")
local socket = require("socket")
ssl.debug = true
local util = require("util")

local AO3Downloader = {}

local cookies = {}

local function getAO3URL()
    return Config:readSetting("AO3_domain")
end

local function getCookies()
    local cookieHeader = {}
    for key, value in pairs(cookies) do
        table.insert(cookieHeader, key .. "=" .. value)
    end
    return table.concat(cookieHeader, "; ")
end

local function setCookies(responseHeaders)
    if responseHeaders["set-cookie"] then
        for _, cookie in ipairs(responseHeaders["set-cookie"]) do
            local key, value = cookie:match("([^=]+)=([^;]+)")
            if key and value then
                cookies[key] = value
            end
        end
    end
end

local unescape_map  = {
    ["lt"] = "<",
    ["gt"] = ">",
    ["amp"] = "&",
    ["quot"] = '"',
    ["apos"] = "'"
}

local gsub = string.gsub
local function unescape(str)
    return gsub(str, '(&(#?)([%d%a]+);)', function(orig, n, s)
        if unescape_map[s] then
            return unescape_map[s]
        elseif n == "#" then  -- unescape unicode
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
local function performHttpsRequest(request)
    local max_retries = 3
    local response, status, response_headers

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)

    -- Add cookies to the request headers
    request.headers = request.headers or {}
    request.headers["Cookie"] = getCookies()
    for i = 0, max_retries do
        response, status, response_headers = socket.skip(1, https.request{
            url = request.url,
            method = request.method or "GET",
            headers = request.headers,
            sink = request.sink,
            protocol = "tlsv1_3", -- Explicitly set the protocol
            options = "all",
        })
        -- Parse and store cookies from the response
        if response_headers then
            setCookies(response_headers)
        end
        logger.dbg("response:"..response)

        if not (response == 200) and i == max_retries then
            logger.dbg("Request failed Status:", status)
            socketutil:reset_timeout()
            return nil
        elseif response == 200 then
            socketutil:reset_timeout()
            return response, status -- Exit if the request succeeds
        end

    end

    return nil, "Failed to connect using available protocols"
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
            totalWorks = tonumber(totalWorks:gsub(",",""), 10) -- Remove commas and convert to a number
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
                totalWorks = totalWorks:gsub(",","") -- Remove commas and convert to a number
                works["total"] = tonumber(totalWorks)
            end
        end
    end

    for _, element in ipairs(elements) do
        local titleElement = element:select(".heading > a")[1]
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
            local date = dateElement and parseToCodepoints(dateElement:getcontent()) or "Unknown date"
            local language = languageElement and parseToCodepoints(languageElement:getcontent()) or "Unknown language"
            local words = wordsElement and parseToCodepoints(wordsElement:getcontent()) or "Unknown word count"
            local chapters = chaptersElement and parseToCodepoints(chaptersElement:getcontent():gsub("<[^>]+>", "")) or "Unknown chapters"
            local hits = hitsElement and parseToCodepoints(hitsElement:getcontent():gsub("<[^>]+>", "")) or "0"
            local comments = commentsElement and parseToCodepoints(commentsElement:getcontent():gsub("<[^>]+>", "")) or "0"
            local kudos = kudosElement and parseToCodepoints(kudosElement:getcontent():gsub("<[^>]+>", "")) or "0"
            local bookmarks = bookmarksElement and parseToCodepoints(bookmarksElement:getcontent():gsub("<[^>]+>", "")) or "0"
            local rating = ratingElement and ratingElement.attributes["title"]
            local category = categoryElement and categoryElement.attributes["title"]
            local iswip = iswipElement and iswipElement.attributes["title"]


            -- Remove HTML formatting, replace <br> with new lines, and preserve paragraph formatting
            local summary = summaryElement and parseToCodepoints(
                summaryElement:getcontent()
                    :gsub("<br%s*/?>", "\n") -- Replace <br> tags with new lines
                    :gsub("</p>", "\n\n") -- Add double new lines for paragraph breaks
                    :gsub("<[^>]+>", "") -- Remove other HTML tags
                    :gsub("^%s*(.-)%s*$", "%1") -- Trim whitespace
            ) or "No summary available"

            -- Remove leading and trailing whitespace from the title
            local title = parseToCodepoints(titleElement:getcontent():gsub("^%s*(.-)%s*$", "%1"))

            -- Create the work object
            local work = {
                id = id,
                title = title,
                rating = rating or "Unknown",
                category = category or "Unknown",
                iswip = iswip,
                link = getAO3URL() .. href,
                author = authorElement and parseToCodepoints(authorElement:getcontent()) or "Unknown",
                summary = summary,
                tags = #tags > 0 and table.concat(tags, ", ") or "No tags available",
                relationships = relationships or {},
                characters = characters or {},
                warnings = warnings or {},
                fandoms = fandoms or {},
                date = date,
                language = language,
                words = words,
                chapters = chapters, -- Cleaned chapters value
                hits = hits,
                comments = comments,
                kudos = kudos,
                bookmarks = bookmarks,
            }

            -- Add the work to the list
            table.insert(works, count, work)
            count = count + 1
        end
    end

    return works
end

local function urlEncode(str)
    if str then
        str = str:gsub("([^%w%-%.%_%~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
    end
    return str
end

function AO3Downloader:getWorkMetadata(work_id)
    local url = string.format("%s/works/%s?view_adult=true", getAO3URL(), work_id)
    local response_body = {}

    local headers = {
        ["User-Agent"] = "Mozilla/5.0 (platform; rv:gecko-version) Gecko/gecko-trail Firefox/firefox-version",
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "en-US,en;q=0.5",
        ["Connection"] = "keep-alive",
        ["DNT"] = "1", -- Do Not Track
    }

    logger.dbg("Fetching metadata for work ID:", work_id)

    local request = {
        url = url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body),
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
    local title = titleElement and parseToCodepoints(titleElement:getcontent():gsub("^%s*(.-)%s*$", "%1")) or "Unknown title" -- Trim whitespace
    local author = authorElement and parseToCodepoints(authorElement:getcontent()) or "Unknown author"
    local summary = summaryElement and parseToCodepoints(
        summaryElement:getcontent()
            :gsub("<br%s*/?>", "\n") -- Replace <br> tags with new lines
            :gsub("</p>", "\n\n") -- Add double new lines for paragraph breaks
            :gsub("<[^>]+>", "") -- Remove other HTML tags
            :gsub("^%s*(.-)%s*$", "%1") -- Trim whitespace
    ) or "No summary available"


    local chapterData = {}
    if chapterIDElements then
        for __, option in pairs(chapterIDElements) do
            logger.dbg("chapter element:" ..  option:gettext())
            if option.attributes.value then
                table.insert(chapterData, {id = option.attributes.value, name = option:getcontent()})
            end
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
    local chapters = chaptersElement and parseToCodepoints(chaptersElement:getcontent():gsub("<[^>]+>", "")) or "Unknown chapters"
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
    local wordcount = wordCountElement and wordCountElement:getcontent():gsub(",","") or "unknown"

    local iswip = iswipElement and iswipElement:getcontent():gsub(":", "") -- Remove colon
    if iswip == "Completed" then
        iswip = "Complete"
    elseif iswip == "Updated" then
        iswip = "Work in Progress"
    end

    -- Return metadata as a table
    return {
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
        epub_link = epub_link or "No EPUB link available",
        hits = hits,
        kudos = kudos,
        comments = comments,
        bookmarks = bookmarks,
        rating = ratingElement and ratingElement:getcontent(),
        category = categoryElement and categoryElement:getcontent(),
        iswip = iswip

    }
end

function AO3Downloader:downloadEpub(link, filename)
    if not link or not link:match("^https?://") then
        logger.dbg("Invalid or missing URL for EPUB download: " .. tostring(link))
        return false
    end

    local path = Paths.getHomeDirectory() .. "/Downloads/" .. filename .. ".epub" -- Use a writable directory on Kobo

    local file, err = io.open(path, "w")
    if not file then
        logger.dbg("Failed to open file for writing: " .. tostring(err))
        return false
    end

    local headers = {
        ["User-Agent"] = "Mozilla/5.0 (platform; rv:gecko-version) Gecko/gecko-trail Firefox/firefox-version",
        ["Accept"] = "application/epub+zip",
        ["Accept-Language"] = "en-US,en;q=0.5",
        ["Connection"] = "keep-alive",
        ["DNT"] = "1", -- Do Not Track
    }

    local request = {
        url = link,
        headers = headers,
        sink = socketutil.file_sink(file), -- Pass the file sink here
    }

    local response, status = performHttpsRequest(request)

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

    local headers = {
        ["User-Agent"] = "Mozilla/5.0 (platform; rv:gecko-version) Gecko/gecko-trail Firefox/firefox-version",
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "en-US,en;q=0.5",
        ["Connection"] = "keep-alive",
        ["DNT"] = "1", -- Do Not Track
    }

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

    logger.dbg("Found works:", works)
    return works
end

function AO3Downloader:searchByTag(tag_name, page, sort_column)
    page = page or 1 -- Default to the first page if no page is specified
    sort_column = sort_column or "revised_at" -- Default to sorting by most recently updated

    -- Encode the tag name for use in the URL
    local encoded_tag_name = tag_name
        :gsub("/", "*s*") -- Replace / with */*
        :gsub(" & ", "*a*")
        :gsub(" ", "%%20")
        :gsub("|", "%%7C")
        :gsub("%(", "%%28")
        :gsub("%)", "%%29")

    -- Construct the URL
    local url = string.format("%s/tags/%s/works?page=%d&work_search[sort_column]=%s", getAO3URL(), encoded_tag_name, page, sort_column)

    logger.dbg("Starting search request to:", url)

    local response_body = {}
    local headers = {
        ["User-Agent"] = "Mozilla/5.0 (platform; rv:gecko-version) Gecko/gecko-trail Firefox/firefox-version",
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "en-US,en;q=0.5",
        ["Connection"] = "keep-alive",
        ["DNT"] = "1", -- Do Not Track
    }

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
    logger.dbg("Search response body:", body)

    -- Parse the HTML response
    local root = htmlparser.parse(body)
    local works = self:parseSearchResults(root)

    logger.dbg("Found works:", works)
    return works
end

function AO3Downloader:searchForTag(query, type)
    if not query or query == "" then
        return nil, "Search query cannot be empty"
    end

    if not type  then
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
    local headers = {
        ["User-Agent"] = "Mozilla/5.0 (platform; rv:gecko-version) Gecko/gecko-trail Firefox/firefox-version",
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "en-US,en;q=0.5",
        ["Connection"] = "keep-alive",
        ["DNT"] = "1", -- Do Not Track
    }

    local request = {
        url = url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body),
    }

    local response, status = performHttpsRequest(request)

    if not response then
        logger.dbg("Fandom search request failed. Status:", status or "unknown error")
        return nil, "Fandom search request failed"
    end

    local body = table.concat(response_body)
    logger.dbg(body)

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

    logger.dbg("Found fandoms:", fandoms)
    return fandoms
end

return AO3Downloader
