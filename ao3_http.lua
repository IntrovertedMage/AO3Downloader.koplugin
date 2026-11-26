local logger = require("logger")
local socketutil = require("socketutil")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local Config = require("fanfic_config")
local https = require("ssl.https") -- Use luasec for HTTPS requests
local ltn12 = require("ltn12")
local Cancellable = require("cancellable")

local HTTPQueryHandler = {}

-- { [domain] = { [name] = cookie } }; loaded once from the plugin config, saved back on change
local cookies = Config:readSetting("cookies") or {}

local function parseSetCookie(set_cookie_value)
    local function isParameter(targetString)
        local parameter_names = { "Domain", "Expires", "HttpOnly", "Max-Age", "Partitioned", "Path", "SameSite", "Secure" }
        for _, value in ipairs(parameter_names) do
            if string.lower(targetString) == string.lower(value) then
                return true
            end
        end
        return false
    end

    local cookies_values = {}
    local parts = {}
    local in_expires = false
    local buffer = ""

    for part in set_cookie_value:gmatch("[^,;]+") do
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
        part = part:match("^%s*(.-)%s*$")
        local name, value = part:match("([^=]+)=?(.*)")
        if not isParameter(name) and value ~= "" and value ~= nil then
            if current_cookie then
                table.insert(cookies_values, current_cookie)
            end
            current_cookie = {}
            current_cookie["name"] = name
            current_cookie["value"] = value
        elseif name and current_cookie then -- attributes before any cookie are dropped
            current_cookie[name] = value or true
        end
    end
    if current_cookie then
        table.insert(cookies_values, current_cookie)
    end

    return cookies_values
end

local function domainOf(url)
    return url:match("^(https?://[^/]+)")
end

local function cookieHeader(custom_cookies, url)
    local header = {}
    for __, cookie in pairs(cookies[domainOf(url)] or {}) do
        table.insert(header, T("%1=%2", cookie.name, cookie.value))
    end
    for key, value in pairs(custom_cookies or {}) do
        table.insert(header, T("%1=%2", key, value))
    end
    return table.concat(header, "; ")
end

local function storeCookies(set_cookie_value, request_url)
    local domain = domainOf(request_url)
    for _, cookie in ipairs(parseSetCookie(set_cookie_value)) do
        cookies[domain] = cookies[domain] or {}
        cookies[domain][cookie.name] = cookie
    end
end

local DEFAULT_HEADERS = {
    ["User-Agent"] = "AO3Downloader.koplugin (KOReader; +https://github.com/IntrovertedMage/AO3Downloader.koplugin)",
    ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    ["Accept-Language"] = "en-US,en;q=0.5",
    ["Sec-GPC"] = "1",
    ["Connection"] = "keep-alive",
    ["DNT"] = "1", -- Do Not Track
}

-- Sent instead of the HTML Accept when opts.json is set.
local JSON_HEADERS = {
    ["Accept"] = "application/json, text/javascript, */*; q=0.01",
    ["X-Requested-With"] = "XMLHttpRequest",
}

-- DEFAULT_HEADERS, then JSON_HEADERS if opts.json, then extra, then opts.headers; later keys win.
local function defaultHeaders(opts, extra)
    local headers = {}
    for _, source in ipairs({ DEFAULT_HEADERS, opts.json and JSON_HEADERS or {}, extra or {}, opts.headers or {} }) do
        for key, value in pairs(source) do
            headers[key] = value
        end
    end
    return headers
end

function HTTPQueryHandler.encode(str)
    return (tostring(str):gsub("[^%w%-%.%_%~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function encodeParams(fields)
    local encode = HTTPQueryHandler.encode
    local parts = {}
    for key, value in pairs(fields) do
        for _, item in ipairs(type(value) == "table" and value or { value }) do
            if item ~= false then
                table.insert(parts, encode(key) .. "=" .. encode(item))
            end
        end
    end
    return table.concat(parts, "&")
end

function HTTPQueryHandler.withQuery(url, fields)
    return url .. (url:find("?", 1, true) and "&" or "?") .. encodeParams(fields)
end

local MAX_ATTEMPTS = 3

-- Runs in the request subprocess: returns the result (with the cookie jar if it changed) and the body.
local function fetch(request)
    local response, status, response_headers, buffer
    local cookies_changed = false
    local attempt = 1

    if request.body then
        request.headers["Content-Length"] = tostring(#request.body)
    end

    logger.dbg("AO3Downloader.koplugin: Performing HTTP request to: " .. request.url)

    while true do
        logger.dbg("AO3Downloader.koplugin: Attempt " .. attempt .. " for URL: " .. request.url)
        request.headers["Cookie"] = cookieHeader(request.cookies, request.url)
        buffer = {}
        local sink = ltn12.sink.table(buffer)
        if request.filepath then
            local file, err = io.open(request.filepath, "wb")
            if not file then
                return { success = false, error = err, cookies = cookies_changed and cookies or nil }
            end
            sink = socketutil.file_sink(file)
        end
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        response, status, response_headers = https.request({
            url = request.url,
            method = request.method,
            headers = request.headers,
            sink = sink,
            source = request.body and ltn12.source.string(request.body),
            protocol = "tlsv1_3",
            options = "all",
        })
        socketutil:reset_timeout()

        if response_headers and response_headers["set-cookie"] then
            storeCookies(response_headers["set-cookie"], request.url)
            cookies_changed = true
        end

        if status == 301 and response_headers["location"] then
            logger.dbg("AO3Downloader.koplugin: Redirecting to new URL: " .. response_headers["location"])
            request.url = response_headers["location"]
            attempt = 1
        elseif (response == 1 and status ~= 418) or attempt >= MAX_ATTEMPTS then
            break
        else
            attempt = attempt + 1
        end
    end

    local success = response == 1 and status < 400
    if not success then
        logger.dbg("AO3Downloader.koplugin: Request failed. Status: " .. tostring(status))
    end
    return {
        success = success,
        response = response,
        response_headers = response_headers,
        status = status,
        cookies = cookies_changed and cookies or nil,
    }, table.concat(buffer)
end

local function performRequest(request)
    local result, body = Cancellable.call(function()
        return fetch(request)
    end)
    if not result then
        return { success = false, error = "request subprocess failed" }
    end
    if result.cookies then
        cookies = result.cookies
        Config:saveSetting("cookies", cookies)
    end
    return result, body
end

function HTTPQueryHandler.get(url, opts)
    opts = opts or {}
    return performRequest({
        url = url,
        method = "GET",
        headers = defaultHeaders(opts),
        cookies = opts.cookies,
        filepath = opts.filepath,
    })
end

function HTTPQueryHandler.postForm(url, fields, opts)
    opts = opts or {}
    return performRequest({
        url = url,
        method = "POST",
        headers = defaultHeaders(opts, { ["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8" }),
        body = encodeParams(fields),
        cookies = opts.cookies,
    })
end

return HTTPQueryHandler
