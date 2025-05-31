local json = require("dkjson")
local Paths = require("FanficPaths")
local logger = require("logger")

local DownloadedFanfics = {}

local history_file_path = Paths.getHomeDirectory() .. "/fanfic_history.json"
local downloaded_fanfics = {}


-- From: http://lua-users.org/wiki/CopyTable
local function deepcopy(orig, copies)
    copies = copies or {}
    local orig_type = type(orig)
    local copy
    if orig_type == "table" then
        if copies[orig] then
            copy = copies[orig]
        else
            copy = {}
            copies[orig] = copy
            for orig_key, orig_value in next, orig, nil do
                copy[deepcopy(orig_key, copies)] = deepcopy(orig_value, copies)
            end
            setmetatable(copy, deepcopy(getmetatable(orig), copies))
        end
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end

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

function DownloadedFanfics.updateDownloadFile_1()
    DownloadedFanfics.load()

    local new_fanfics_set = {}

    for __, fanfic in pairs(downloaded_fanfics) do
        new_fanfics_set[fanfic.id] = fanfic
    end

    downloaded_fanfics = new_fanfics_set

    DownloadedFanfics.save()


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
        fanfic.id = tostring(fanfic.id)
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
    return deepcopy(downloaded_fanfics)
end

-- Add a new fanfic to the downloaded list
function DownloadedFanfics.add(fanfic)
    fanfic.fandoms = normalizeField(fanfic.fandoms) -- Ensure fandoms is a table
    fanfic.relationships = normalizeField(fanfic.relationships) -- Ensure relationships is a table
    fanfic.characters = normalizeField(fanfic.characters) -- Ensure characters is a table
    fanfic.tags = normalizeField(fanfic.tags) -- Ensure tags is a table
    downloaded_fanfics[tostring(fanfic.id)] = fanfic
    DownloadedFanfics.save()
end

-- Update an existing fanfic in the downloaded list
function DownloadedFanfics.update(fanfic)
    fanfic.fandoms = normalizeField(fanfic.fandoms) -- Ensure fandoms is a table
    fanfic.relationships = normalizeField(fanfic.relationships) -- Ensure relationships is a table
    fanfic.characters = normalizeField(fanfic.characters) -- Ensure characters is a table
    fanfic.tags = normalizeField(fanfic.tags) -- Ensure tags is a table
    downloaded_fanfics[tostring(fanfic.id)] = fanfic
    DownloadedFanfics.save()
end

-- Delete a fanfic from the downloaded list
function DownloadedFanfics.delete(fanficId)
    if not downloaded_fanfics[tostring(fanficId)] then
        return false
    end
    downloaded_fanfics[tostring(fanficId)] = nil
    DownloadedFanfics.save()
    return true
end

function DownloadedFanfics.markChapterAsRead(fanficId, chapter_id)
        downloaded_fanfics[tostring(fanficId)].chapter_data[tostring(chapter_id)].read = true
        DownloadedFanfics.save()
        return deepcopy(downloaded_fanfics[fanficId])
end

function DownloadedFanfics.markWorkAsRead(fanficId)
    downloaded_fanfics[tostring(fanficId)].read = true
    DownloadedFanfics.save()
    return deepcopy(downloaded_fanfics[fanficId])
end


function DownloadedFanfics.checkIfStored(fanficId)
    return downloaded_fanfics[tostring(fanficId)]
end

return DownloadedFanfics
