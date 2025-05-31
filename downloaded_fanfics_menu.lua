local Menu = require("ui/widget/menu")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local util = require("util")
local logger = require("logger")
local DownloadedFanfics = require("downloaded_fanfics")
local FanficReader = require("fanfic_reader")
local _ = require("gettext")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local UIManager = require("ui/uimanager")

local DownloadedFanficsMenu = {}

-- Helper function to normalize a field to always be a table
local function normalizeField(field)
    if type(field) == "string" then
        -- Split the string by commas and trim whitespace
        local result = {}
        for item in string.gmatch(field, "([^,]+)") do
            table.insert(result, util.trim(item))
        end
        return result
    elseif type(field) == "table" then
        return field -- Already a table
    else
        return {}    -- Default to an empty table
    end
end

function DownloadedFanficsMenu:show(ui, parentMenu, updateFanficCallback)
    local function refreshDownloadMenu()
        local downloaded_fanfics = DownloadedFanfics.getAll()
        if next(downloaded_fanfics) == nil then
            UIManager:show(InfoMessage:new({
                text = "No fanfics downloaded yet.",
            }))
            return
        end

        -- Normalize relationships, characters, and tags for each fanfic
        for _, fanfic in pairs(downloaded_fanfics) do
            fanfic.relationships = normalizeField(fanfic.relationships)
            fanfic.characters = normalizeField(fanfic.characters)
            fanfic.tags = normalizeField(fanfic.tags)
        end

        -- Group fanfics by fandom and track the most recent `last_accessed` timestamp
        local fandom_groups = {}
        local fandom_last_accessed = {}
        for __, fanfic in pairs(downloaded_fanfics) do
            local fandoms = fanfic.fandoms or { _("Unknown Fandom") }
            for __, fandom in pairs(fandoms) do
                if not fandom_groups[fandom] then
                    fandom_groups[fandom] = {}
                    fandom_last_accessed[fandom] = fanfic.last_accessed or "0000-00-00 00:00:00"
                end
                table.insert(fandom_groups[fandom], fanfic)
                -- Update the most recent `last_accessed` timestamp for the fandom
                if fanfic.last_accessed and fanfic.last_accessed > fandom_last_accessed[fandom] then
                    fandom_last_accessed[fandom] = fanfic.last_accessed
                end
            end
        end

        -- Sort fandoms by the most recent `last_accessed` timestamp in descending order
        local sorted_fandoms = {}
        for fandom, _ in pairs(fandom_groups) do
            table.insert(sorted_fandoms, fandom)
        end
        table.sort(sorted_fandoms, function(a, b)
            return fandom_last_accessed[a] > fandom_last_accessed[b]
        end)

        -- Create the main menu with submenus for each fandom
        local menu_items = {}
        for __, fandom in pairs(sorted_fandoms) do
            local fanfics = fandom_groups[fandom]

            -- Sort fanfics in each fandom by `last_accessed` in descending order
            table.sort(fanfics, function(a, b)
                return (a.last_accessed or "") > (b.last_accessed or "")
            end)

            -- Define the action for selecting a fandom
            table.insert(menu_items, {
                text = T("(%1) %2", #fanfics, fandom),
                callback = function()
                    -- Create the submenu for the selected fandom
                    local submenu_items = {}
                    for __, fanfic in pairs(fanfics) do
                        local fanfic_read = true

                        if fanfic.chapter_data and #fanfic.chapter_data > 0 then
                            for index, chapter in pairs(fanfic.chapter_data) do
                                if not chapter.read then
                                    fanfic_read = false
                                    break
                                end
                            end
                        else
                            fanfic_read = false
                        end

                        local fanfic_complete = true

                        local chapter_count, chapter_total = fanfic.chapters:match("([^//]+)/([^//]+)")

                        if string.find(fanfic.chapters, "?") or chapter_count < chapter_total then
                            fanfic_complete = false
                        end

                        table.insert(submenu_items, {
                            text = T("%1 (%2) %3", fanfic_read and (not fanfic_complete) and "=" or  fanfic_read and fanfic_complete and "✓" or "  ", fanfic.chapters, fanfic.title),
                            id = fanfic.id,
                            callback = function()
                                -- Show options for the fanfic
                                local dialog
                                dialog = ButtonDialog:new({
                                    title = T(_("Options for '%1'"), fanfic.title),
                                    buttons = {
                                        {
                                            {
                                                text = _("Open"),
                                                callback = function()

                                                    -- Update the `last_accessed` field
                                                    fanfic.last_accessed = os.date("%Y-%m-%d %H:%M:%S")
                                                    DownloadedFanfics.update(fanfic) -- Save the updated metadata
                                                    if (not fanfic.chapter_data) or #fanfic.chapter_data == 0 then
                                                        UIManager:close(parentMenu)
                                                        UIManager:close(dialog)
                                                        ---@diagnostic disable-next-line: missing-fields
                                                        FanficReader:show({
                                                            fanfic_path = fanfic.path,
                                                            current_fanfic = fanfic,
                                                        })
                                                    else
                                                        local open_method
                                                        open_method = ButtonDialog:new({
                                                            buttons = {
                                                                {
                                                                    {
                                                                        text = "Open",
                                                                        callback = function()
                                                                            UIManager:close(parentMenu)
                                                                            UIManager:close(dialog)
                                                                            UIManager:close(open_method)
                                                                            ---@diagnostic disable-next-line: missing-fields
                                                                            FanficReader:show({
                                                                                fanfic_path = fanfic.path,
                                                                                current_fanfic = fanfic,
                                                                            })
                                                                        end,
                                                                    },
                                                                },
                                                                {
                                                                    {
                                                                        text = "Open at chapter",
                                                                        callback = function()
                                                                            UIManager:close(dialog)
                                                                            UIManager:close(open_method)
                                                                            DownloadedFanficsMenu:showFanficChapterSelect(
                                                                                ui,
                                                                                fanfic,
                                                                                parentMenu
                                                                            )
                                                                        end,
                                                                    },
                                                                },
                                                            },
                                                        })
                                                        UIManager:show(open_method)
                                                    end
                                                end,
                                            },
                                            {
                                                text = _("View Details"),
                                                callback = function()
                                                    -- Show detailed information
                                                    local details = string.format(
                                                        "Fandoms: %s\n\nStatus: %s \nChapters: %s\nPublished: %s\nUpdated: %s\nAuthor: %s\n\nSummary:\n%s\n\nRating: %s\nCategory: %s\n\nTags:\nWarnings:\n%s\n\nRelationships:\n%s\n\nCharacters:\n%s\n\nOther Tags:\n%s\n\nStats: \nWords: %s \nHits: %s\nKudos: %s\nBookmarks: %s\nComments: %s",
                                                        (
                                                            #fanfic.fandoms > 0 and table.concat(fanfic.fandoms, ", ")
                                                            or "No fandoms available"
                                                        ),
                                                        fanfic.iswip or "Unknown",
                                                        fanfic.chapters or "Unknown",
                                                        fanfic.published or "Unknown",
                                                        fanfic.updated or "Unknown",
                                                        fanfic.author or "Unknown",
                                                        fanfic.summary or "No summary available",
                                                        fanfic.rating or "Unknown",
                                                        fanfic.category or "Unknown",
                                                        (
                                                            #fanfic.warnings > 0 and table.concat(fanfic.warnings, ", ")
                                                            or "No warnings available"
                                                        ),
                                                        (
                                                            #fanfic.relationships > 0
                                                            and table.concat(fanfic.relationships, ", ")
                                                            or "No relationships available"
                                                        ),
                                                        (
                                                            #fanfic.characters > 0
                                                            and table.concat(fanfic.characters, ", ")
                                                            or "No characters available"
                                                        ),
                                                        (
                                                            #fanfic.tags > 0 and table.concat(fanfic.tags, ", ")
                                                            or "No tags available"
                                                        ),
                                                        fanfic.wordcount or "Unknown",
                                                        fanfic.hits or "0",
                                                        fanfic.kudos or "0",
                                                        fanfic.bookmarks or "0",
                                                        fanfic.comments or "0"
                                                    )
                                                    UIManager:show(TextViewer:new({
                                                        title = fanfic.title,
                                                        text = details,
                                                    }))
                                                    UIManager:close(dialog)
                                                end,
                                            },
                                        },
                                        {
                                            {
                                                text = _("Update"),
                                                callback = function()
                                                    UIManager:scheduleIn(1, function()
                                                        -- Update the fanfic
                                                        updateFanficCallback(fanfic)
                                                        UIManager:close(dialog)
                                                    end)
                                                    UIManager:show(InfoMessage:new({
                                                        text = _("Downloading work may take some time…"),
                                                        timeout = 1,
                                                    }))
                                                end,
                                                UIManager:close(dialog),
                                            },
                                            {
                                                text = _("Delete"),
                                                callback = function()
                                                    local confirmDialog
                                                    -- Confirm deletion
                                                    confirmDialog = ButtonDialog:new({
                                                        title = T(_("Are you sure you want to delete '%1'?"), fanfic.title),
                                                        buttons = {
                                                            {
                                                                {
                                                                    text = _("Delete"),
                                                                    callback = function()
                                                                        -- Remove the fanfic from the list
                                                                        local file_path = fanfic.path
                                                                        DownloadedFanfics.delete(fanfic.id)

                                                                        -- Delete the file
                                                                        local success, err = util.removeFile(file_path)
                                                                        if success then
                                                                            UIManager:show(
                                                                                InfoMessage:new({
                                                                                    text = T(
                                                                                        _("'%1' has been deleted."),
                                                                                        fanfic.title
                                                                                    ),
                                                                                })
                                                                            )
                                                                        else
                                                                            logger.err("Failed to delete file:", err)
                                                                            UIManager:show(
                                                                                InfoMessage:new({
                                                                                    text = T(
                                                                                        _(
                                                                                            "Failed to delete file for '%1': %2, record has still been removed"
                                                                                        ),
                                                                                        fanfic.title,
                                                                                        err
                                                                                    ),
                                                                                })
                                                                            )
                                                                        end
                                                                        for i, menu_item in pairs(parentMenu.item_table) do
                                                                            if tostring(menu_item.id) == tostring(fanfic.id) then
                                                                                table.remove(parentMenu.item_table, i)
                                                                            end
                                                                        end
                                                                        parentMenu:updateItems()
                                                                        parentMenu:updateMenuBack(1, nil, refreshDownloadMenu(), nil)
                                                                        UIManager:close(confirmDialog)

                                                                    end,
                                                                },
                                                                {
                                                                    text = _("Cancel"),
                                                                    callback = function()
                                                                        UIManager:close(confirmDialog)
                                                                    end,
                                                                },
                                                            },
                                                        },
                                                    })
                                                    UIManager:show(confirmDialog)
                                                    UIManager:close(dialog)
                                                end,
                                            },
                                        },
                                        {
                                            {
                                                text = _("Cancel"),
                                                callback = function()
                                                    UIManager:close(dialog)
                                                end,
                                            },
                                        },
                                    },
                                })
                                UIManager:show(dialog)
                            end,
                        })
                    end

                    -- Use GoDownInMenu to navigate into the submenu
                    parentMenu:GoDownInMenu(T(_("Fanfics in '%1'"), fandom), submenu_items)
                end,
                hold_callback = function()
                    -- Show a notification with the full fandom name
                    UIManager:show(InfoMessage:new({
                        text = T("%1", fandom),
                    }))
                end,
            })
        end
        return menu_items
    end


    local download_menu_items = refreshDownloadMenu()
    if not download_menu_items then
        return
    end
    -- Create and show the main menu
    parentMenu:GoDownInMenu("Downloaded Works by Fandom", download_menu_items)
end

function DownloadedFanficsMenu:showFanficChapterSelect(ui, fanfic, parentMenu)
    if not fanfic.chapter_data then
        return
    end

    local chapter_options = {}

    for idx, chapter in pairs(fanfic.chapter_data) do
        table.insert(chapter_options, {
            text = (chapter.read and "✓ " or "") .. chapter.name,
            callback = function()
                FanficReader:show({
                    fanfic_path = fanfic.path,
                    current_fanfic = fanfic,
                    chapter_opening_at = idx,
                })
                UIManager:close(parentMenu)
            end,
        })
    end

    parentMenu:GoDownInMenu("Select Chapter to Open", chapter_options)
end

return DownloadedFanficsMenu
