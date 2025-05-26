local json = require("dkjson")
local Paths = require("FanficPaths")
local logger = require("logger")
local DataStorage = require("datastorage")
local util = require("util")

local DownloadedFanfics = {}

local history_file_path = Paths.getHomeDirectory() .. "/fanfic_history.json"
local downloaded_fanfics = {}

-- Helper function to ensure a field is always a table
local function normalizeField(field)
    if type(field) == "string" then
        return { field } -- Convert single string to a table
    elseif type(field) == "table" then
        return field -- Already a table
    else
        return {} -- Default to an empty table
    end
end

-- Save the downloaded fanfic history to a file
function DownloadedFanfics.save()
    local file, err = io.open(history_file_path, "w")
    if not file then
        logger.err("Failed to save fanfic history:", err)
        return
    end

    local content = json.encode(downloaded_fanfics, { indent = true })
    file:write(content)
    file:close()
    logger.dbg("Fanfic history saved successfully.")
end

-- Load the downloaded fanfic history from a file
function DownloadedFanfics.load()
    local file, err = io.open(history_file_path, "r")
    if not file then
        logger.dbg("No fanfic history file found. Starting fresh.")
        return
    end

    local content = file:read("*a")
    file:close()

    local history, _, err = json.decode(content)
    if not history then
        logger.err("Failed to load fanfic history:", err)
        return
    end

    -- Normalize fields for all loaded fanfics
    for _, fanfic in ipairs(history) do
        fanfic.fandoms = normalizeField(fanfic.fandoms) -- Ensure fandoms is a table
        fanfic.relationships = normalizeField(fanfic.relationships)
        fanfic.characters = normalizeField(fanfic.characters)
        fanfic.tags = normalizeField(fanfic.tags)
    end

    downloaded_fanfics = history
    logger.dbg("Fanfic history loaded successfully.")
end

-- Get all downloaded fanfics
function DownloadedFanfics.getAll()
    return downloaded_fanfics
end

-- Add a new fanfic to the downloaded list
function DownloadedFanfics.add(fanfic)
    fanfic.fandoms = normalizeField(fanfic.fandoms) -- Ensure fandoms is a table
    fanfic.relationships = normalizeField(fanfic.relationships) -- Ensure relationships is a table
    fanfic.characters = normalizeField(fanfic.characters) -- Ensure characters is a table
    fanfic.tags = normalizeField(fanfic.tags) -- Ensure tags is a table
    table.insert(downloaded_fanfics, 1, fanfic) -- Insert at the beginning of the list
    DownloadedFanfics.save()
end

-- Update an existing fanfic in the downloaded list
function DownloadedFanfics.update(fanfic)
    for i, existing in ipairs(downloaded_fanfics) do
        if tostring(existing.id) == tostring(fanfic.id) then
            fanfic.fandoms = normalizeField(fanfic.fandoms) -- Ensure fandoms is a table
            fanfic.relationships = normalizeField(fanfic.relationships) -- Ensure relationships is a table
            fanfic.characters = normalizeField(fanfic.characters) -- Ensure characters is a table
            fanfic.tags = normalizeField(fanfic.tags) -- Ensure tags is a table
            downloaded_fanfics[i] = fanfic
            DownloadedFanfics.save()
            return
        end
    end
end

-- Delete a fanfic from the downloaded list
function DownloadedFanfics.delete(fanficId)
    for i, fanfic in ipairs(downloaded_fanfics) do
        if tostring(fanfic.id) == tostring(fanficId) then
            table.remove(downloaded_fanfics, i)
            DownloadedFanfics.save()
            return true
        end
    end
    return false
end

function DownloadedFanfics.markChapterAsRead(fanficId, chapter_id)
    for i, fanfic in pairs(downloaded_fanfics) do
        if tostring(fanfic.id) == tostring(fanficId) then
            downloaded_fanfics[i].chapter_data[chapter_id].read = true
            DownloadedFanfics.save()
            return downloaded_fanfics[i]
        end
    end
end

return DownloadedFanfics
