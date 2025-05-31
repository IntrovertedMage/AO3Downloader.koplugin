local ButtonDialog = require("ui/widget/buttondialog")
local KeyValuePage = require("ui/widget/keyvaluepage")
local UIManager = require("ui/uimanager")
local DownloadedFanfics = require("downloaded_fanfics")
local InfoMessage = require("ui/widget/infomessage")
local FanficReader = require("fanfic_reader")
local Config = require("config")
local _ = require("gettext")
local util = require("util")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local logger = require("logger")

local FanficBrowser = {}

function FanficBrowser:generateTable(kv_pairs, ficResults, updateFanficCallback, downloadFanficCallback)
    -- Helper function to check if a fanfic is already downloaded
    local function isDownloaded(fanficId)
        local downloaded_fanfics = DownloadedFanfics.getAll()
        return downloaded_fanfics[tostring(fanficId)]
    end

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

    -- Populate the initial list of fanfics
    for __, v in pairs(ficResults) do
        if __ == "total" then
            goto continue
        end
        -- Normalize relationships, characters, and tags
        v.relationships = normalizeField(v.relationships)
        v.characters = normalizeField(v.characters)
        v.tags = normalizeField(v.tags)

        -- Check if the fanfic is already downloaded
        local downloadedFanfic = isDownloaded(v.id)
        local title = v.title

        if downloadedFanfic then
            title = "✓ " .. title -- Append the download symbol to the title
        end

        -- Add the fanfic to the list with appropriate callback

        local title_item
        title_item = {
            title,
            "",
            callback = function()
                local downloadedFanfic = isDownloaded(v.id)
                if downloadedFanfic then
                    -- Show options to update or view the fanfic
                    local dialog
                    dialog = ButtonDialog:new({
                        title = _("Fanfic is already downloaded, what would you like to do?"),
                        buttons = {
                            {
                                {
                                    text = _("Update"),
                                    callback = function()
                                        UIManager:scheduleIn(1, function()
                                            updateFanficCallback(downloadedFanfic)
                                            UIManager:close(dialog)
                                        end)
                                        UIManager:show(InfoMessage:new({
                                            text = _("Downloading work may take some time…"),
                                            timeout = 1,
                                        }))
                                    end,
                                },
                                {
                                    text = _("Open"),
                                    callback = function()
                                        UIManager:close(self.browse_window)
                                        FanficReader:show({
                                            fanfic_path = downloadedFanfic.path,
                                            current_fanfic = downloadedFanfic,
                                            chapter_opening_at = nil,
                                        })
                                    end,
                                },
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
                else
                    if Config:readSetting("show_adult_warning") and (v.rating == "Explicit" or v.rating == "Mature" or v.rating == "Not Rated") then
                        self:showAdultWarningDialog(v)
                    else
                        self:showDownloadDialog(v)
                    end
                end
            end,
        }

        table.insert(kv_pairs, title_item)
        -- Add additional details about the fanfic
        table.insert(kv_pairs, { "     " .. "Author:", v.author })
        table.insert(kv_pairs, { "     " .. "Rating:", v.rating })
        table.insert(
            kv_pairs,
            { "     " .. "Fandom:", #v.fandoms > 0 and table.concat(v.fandoms, ", ") or "No fandoms available" }
        )
        table.insert(kv_pairs, { "     " .. "Date:", v.date })
        table.insert(
            kv_pairs,
            { "     " .. "Warnings:", #v.warnings > 0 and table.concat(v.warnings, ", ") or "No warnings available" }
        )
        table.insert(kv_pairs, {
            "     " .. "Relationships:",
            "("
            .. v.category
            .. ") "
            .. (#v.relationships > 0 and table.concat(v.relationships, ", ") or "No relationships available"),
        })
        table.insert(kv_pairs, {
            "     " .. "Characters:",
            #v.characters > 0 and table.concat(v.characters, ", ") or "No characters available",
        })
        table.insert(
            kv_pairs,
            { "     " .. "Other Tags:", #v.tags > 0 and table.concat(v.tags, ", ") or "No tags available" }
        )
        table.insert(kv_pairs, { "     " .. "Summary:", v.summary })
        table.insert(kv_pairs, { "     " .. "Language:", v.language })
        table.insert(kv_pairs, { "     " .. "Words:", v.words })
        table.insert(kv_pairs, { "     " .. v.iswip .. ", Chapters:", v.chapters })

        -- Combine comments, kudos, bookmarks, and hits into one line
        local stats = string.format(
            "Hits: %s | Kudos: %s | Bookmarks: %s | Comments: %s",
            v.comments or "0",
            v.kudos or "0",
            v.bookmarks or "0",
            v.hits or "0"
        )
        table.insert(kv_pairs, { "     " .. "Stats:", stats, separator = true })
        ::continue::
    end

    return kv_pairs
end
function FanficBrowser:showDownloadDialog(fanfic)
    local confirmDialog
    confirmDialog = ButtonDialog:new({
        title = T("Would you like to download the work: %1 by %2?", fanfic.title, fanfic.author),
        buttons = {
            {
                {
                    text = ("No"),
                    callback = function()
                        UIManager:close(confirmDialog)
                    end,
                },
                {
                    text = ("Yes"),
                    callback = function()
                        UIManager:scheduleIn(1, function()
                            self.downloadFanficCallback(tonumber(fanfic.id), self.browse_window)
                            self.browse_window:reload()
                        end)
                        UIManager:show(InfoMessage:new({
                            text = _("Downloading work may take some time…"),
                            timeout = 1,
                        }))
                        UIManager:close(confirmDialog)
                    end,
                },
            },
        },
    })
    UIManager:show(confirmDialog)
end

function FanficBrowser:showAdultWarningDialog(fanfic)
    local warningDialog
    warningDialog = ButtonDialog:new({
        title = "This work could have adult content. If you continue, you have agreed that you are willing to see such content",
        buttons = {
            {
                {
                    text = ("Cancel"),
                    callback = function()
                        UIManager:close(warningDialog)
                    end,
                },
                {
                    text = ("Continue"),
                    callback = function()
                        UIManager:close(warningDialog)
                        self:showDownloadDialog(fanfic)
                    end,
                }
            }

        }
    })
    UIManager:show(warningDialog)
end

function FanficBrowser:show(ui, parentMenu, ficResults, fetchNextPage, updateFanficCallback, downloadFanficCallback)
    self.ui = ui
    self.updateFanficCallback = updateFanficCallback
    self.downloadFanficCallback = downloadFanficCallback

    local kv_pairs = self:generateTable({}, ficResults, updateFanficCallback, downloadFanficCallback)
    local total_fic_count = ficResults.total
    ficResults.total = nil
    self.fanfics_loaded = ficResults

    local BrowseWindow = KeyValuePage:extend({
        parentMenu = nil,
        preventParentClose = nil,
    })
    -- Override _populateItems to check if it's the last page and load more results
    local originalPopulateItems = KeyValuePage._populateItems
    BrowseWindow._populateItems = function(selfself)
        if selfself.show_page == selfself.pages then
            -- Fetch more results if on the last page
            local newFics = fetchNextPage()
            if newFics and #newFics > 0 then
                selfself:addNewFanfics(newFics)
            end
        end

        -- Call the original _populateItems function
        KeyValuePage._populateItems(selfself)
    end

    BrowseWindow.addNewFanfics = function(selfself, newFics)
        selfself.kv_pairs = self:generateTable(selfself.kv_pairs, newFics, updateFanficCallback, downloadFanficCallback)

        newFics.total = nil
        -- Add new works to loaded fanfics table
        for k, v in pairs(newFics) do
            table.insert(self.fanfics_loaded, v)
        end

        -- Update the total number of pages
        selfself.pages = math.ceil(#selfself.kv_pairs / selfself.items_per_page)
        self.browse_window = BrowseWindow:new({
            title = selfself.title,
            title_bar_fm_style = true,
            is_popout = false,
            is_borderless = true,
            kv_pairs = selfself.kv_pairs,
            show_page = selfself.show_page,
            value_overflow_align = "center",
            parentMenu = selfself.parentMenu,
            preventParentClose = true,
        })
        UIManager:show(self.browse_window)
        UIManager:close(selfself)
        selfself:onClose()
    end

    BrowseWindow.reload = function(selfself)
        selfself.kv_pairs = self:generateTable({}, self.fanfics_loaded, updateFanficCallback, downloadFanficCallback)

        -- Update the total number of pages
        selfself.pages = math.ceil(#selfself.kv_pairs / selfself.items_per_page)
        self.browse_window = BrowseWindow:new({
            title = selfself.title,
            title_bar_fm_style = true,
            is_popout = false,
            is_borderless = true,
            kv_pairs = selfself.kv_pairs,
            show_page = selfself.show_page,
            value_overflow_align = "center",
            parentMenu = selfself.parentMenu,
            preventParentClose = true,
        })
        UIManager:show(self.browse_window)
        UIManager:close(selfself)
        selfself:onClose()
    end

    BrowseWindow.onClose = function(self)
        -- Only close the parent menu if explicitly required
        if self.parentMenu and not self.preventParentClose then
            self.parentMenu:onClose()
        end
        KeyValuePage.onClose(self)
    end

    -- Create the KeyValuePage
    self.browse_window = BrowseWindow:new({
        title = T("(%1) Tap fanfic title to download", total_fic_count or "ERROR"),
        title_bar_fm_style = true,
        is_popout = false,
        is_borderless = true,
        kv_pairs = kv_pairs,
        parentMenu = parentMenu,
        value_overflow_align = "center",
        preventParentClose = true,
        show_page = 1,
    })

    UIManager:show(self.browse_window)
end

return FanficBrowser
