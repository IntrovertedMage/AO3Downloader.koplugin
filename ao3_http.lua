local logger = require("logger")
local socketutil = require("socketutil")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local Config = require("fanfic_config")
local util = require("util")
local https = require("ssl.https") -- Use luasec for HTTPS requests

local HTTPQueryHandler = {}

local encodeHelper = {}
HTTPQueryHandler.encodeHelper = encodeHelper



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

function encodeHelper:parseFromHTML(str)
    return encodeHelper:parseToCodepoints(
                    str
                        :gsub("<br%s*/?>", "\n") -- Replace <br> tags with new lines
                        :gsub("</p>", "\n\n") -- Add double new lines for paragraph breaks
                        :gsub("<[^>]+>", "") -- Remove other HTML tags
                        :gsub("^%s*(.-)%s*$", "%1") -- Trim whitespace
                )
end

function encodeHelper:generateParametersStringForm(params)
    local form_parts = {}
    for key, value in pairs(params) do
        table.insert(form_parts, encodeHelper:formEncode(key) .. "=" .. encodeHelper:formEncode(value))
    end
    return table.concat(form_parts, "&")
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
    local cookies_for_this_domain = self.cookies[request_domain] or {}

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
        ["User-Agent"] = "AO3Downloader.koplugin (KOReader; +https://github.com/IntrovertedMage/AO3Downloader.koplugin)",
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
        elseif response == 1 and status ~= 418 then
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

return HTTPQueryHandler
