local json = require("rapidjson")
local Paths = require("FanficPaths")
local logger = require("logger")
local ffiUtil = require("ffi/util")
local Device = require("device")

local DownloadedFanfics = {}

local history_file_path = Paths.getHomeDirectory() .. "/fanfic_history.json"
local downloaded_fanfics = {}
local save_blocked = false -- set when an unreadable history file couldn't be backed up

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

-- Placeholders older versions stored in place of an empty tag list.
local TAG_PLACEHOLDERS = { ["N/A"] = true, ["No tags available"] = true }

-- Returns field as a list of trimmed items. Older records stored "a, b" or { "a, b" };
-- splitting on commas is safe because AO3 tags can't contain them.
local function normalizeField(field)
    local items = {}
    for _, value in ipairs(type(field) == "table" and field or { field }) do
        for item in tostring(value):gmatch("[^,]+") do
            item = item:match("^%s*(.-)%s*$")
            if item ~= "" and not TAG_PLACEHOLDERS[item] then
                table.insert(items, item)
            end
        end
    end
    return items
end

-- Normalizes a fanfic record's fields to the shapes the rest of the code expects.
local function normalizeFanfic(fanfic)
    fanfic.id = tostring(fanfic.id)
    fanfic.fandoms = normalizeField(fanfic.fandoms)
    fanfic.relationships = normalizeField(fanfic.relationships)
    fanfic.characters = normalizeField(fanfic.characters)
    fanfic.tags = normalizeField(fanfic.tags)
end

-- Metadata fields copied from a fresh work page onto a downloaded work's record.
local METADATA_FIELDS = {
    "title", "author", "chapters", "summary", "fandoms", "tags", "relationships",
    "characters", "warnings", "hits", "kudos", "bookmarks", "comments", "rating",
    "category", "iswip", "updated", "published", "wordcount",
}

-- Account-state fields: always taken from the fresh page, never merged with stored values.
local ACCOUNT_FIELDS = {
    "markedForLater", "subscriptionID", "bookmarkID", "bookmarkContent",
}

-- Returns chapters with read flags carried over from old_chapters: matched by chapter id
-- (so an inserted chapter doesn't shift progress), by position for records without ids.
local function carryReadProgress(old_chapters, chapters)
    local old_by_id = {}
    for _, chapter in ipairs(old_chapters) do
        if chapter.id then
            old_by_id[chapter.id] = chapter
        end
    end
    for idx, chapter in ipairs(chapters) do
        local old
        if chapter.id and next(old_by_id) then
            old = old_by_id[chapter.id]
        else
            old = old_chapters[idx]
        end
        chapter.read = old and old.read or false
    end
    return chapters
end

-- Save the downloaded fanfic history to a file
function DownloadedFanfics.save()
    if save_blocked then
        logger.err("Not saving fanfic history: the existing file is unreadable and has no backup")
        return
    end
    local content, encode_err = json.encode(downloaded_fanfics, { pretty = true })
    if not content then
        logger.err("Failed to encode fanfic history:", encode_err)
        return
    end

    local file, err = io.open(history_file_path, "w")
    if not file then
        logger.err("Failed to save fanfic history:", err)
        return
    end

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

    local ok, history, decode_err = pcall(json.decode, content)
    if not ok or type(history) ~= "table" then
        -- set the unreadable file aside, or the next save would overwrite it with an empty history
        local backup_path = history_file_path .. "." .. os.date("%Y%m%d-%H%M%S") .. ".bak"
        local renamed, rename_err = os.rename(history_file_path, backup_path)
        save_blocked = not renamed
        logger.err("Failed to load fanfic history:", ok and decode_err or history,
            renamed and ("kept as " .. backup_path) or ("and could not back it up: " .. tostring(rename_err)))
        return
    end

    -- Normalize fields for all loaded fanfics
    for _, fanfic in pairs(history) do
        normalizeFanfic(fanfic)
    end

    downloaded_fanfics = history
    logger.dbg("Fanfic history loaded successfully.")
end

-- Get all downloaded fanfics
function DownloadedFanfics.getAll()
    return deepcopy(downloaded_fanfics)
end

-- Update an existing fanfic in the downloaded list
function DownloadedFanfics.update(fanfic, notSave)
    normalizeFanfic(fanfic)
    downloaded_fanfics[fanfic.id] = fanfic
    if notSave then
        return
    end
    DownloadedFanfics.save()
end

-- Refreshes fanfic's record from freshly downloaded work metadata and saves it.
-- Nil metadata fields keep the stored value; read progress carries over.
function DownloadedFanfics.storeDownload(fanfic, metadata)
    -- a whole-work read flag is stale once per-chapter data exists
    if fanfic.chapter_data and #fanfic.chapter_data == 0 then
        fanfic.read = nil
    end
    for _, field in ipairs(METADATA_FIELDS) do
        if metadata[field] ~= nil then
            fanfic[field] = metadata[field]
        end
    end
    for _, field in ipairs(ACCOUNT_FIELDS) do
        fanfic[field] = metadata[field]
    end
    fanfic.chapter_data = carryReadProgress(fanfic.chapter_data or {}, metadata.chapterData)
    fanfic.last_accessed = os.date("%Y-%m-%d %H:%M:%S")
    DownloadedFanfics.update(fanfic)
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

function DownloadedFanfics.markChapterAsRead(fanficId, chapter_index)
    downloaded_fanfics[tostring(fanficId)].chapter_data[chapter_index].read = true
    DownloadedFanfics.save()
    return deepcopy(downloaded_fanfics[tostring(fanficId)])
end

function DownloadedFanfics.markWorkAsRead(fanficId)
    downloaded_fanfics[tostring(fanficId)].read = true
    DownloadedFanfics.save()
    return deepcopy(downloaded_fanfics[tostring(fanficId)])
end

function DownloadedFanfics.checkIfStored(fanficId)
    return downloaded_fanfics[tostring(fanficId)]
end





local mv_bin = Device:isAndroid() and "/system/bin/mv" or "/bin/mv"
local function moveFile(from, to)
    return ffiUtil.execute(mv_bin, from, to) == 0
end

function DownloadedFanfics.changePath(fanficId, newPath, notSave)
    local fanfic = downloaded_fanfics[tostring(fanficId)]
    if fanfic.path ~= newPath then
        local sdrFilePath = fanfic.path:sub(1, -5) .. "sdr"
        local newSdrFilePath = newPath:sub(1, -5) .. "sdr"
        moveFile(fanfic.path, newPath)
        moveFile(sdrFilePath, newSdrFilePath)
        fanfic.path = newPath
    end

    DownloadedFanfics.update(fanfic, notSave)
end


return DownloadedFanfics
