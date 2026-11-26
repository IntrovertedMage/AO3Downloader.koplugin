local ButtonDialog = require("ui/widget/buttondialog")
local KeyValuePage = require("ui/widget/keyvaluepage")
local UIManager = require("ui/uimanager")
local DownloadedFanfics = require("downloaded_fanfics")
local Config = require("fanfic_config")
local _ = require("gettext")
local Cancellable = require("cancellable")
local AO3WebParser = require("ao3_parser")
local util = require("util")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template

local ITEMS_PER_FIC = 14 -- rows per work, so each page shows one work

local FanficBrowser = {
    Fanfic = nil,
    -- per window, set on the instance show() makes: browse_window, title, pager (UIResult.paged)
}

local BrowseWindow = KeyValuePage:extend{}

function BrowseWindow:onClose()
    FanficBrowser.Fanfic.menu_stack[self] = nil
    return KeyValuePage.onClose(self)
end

function FanficBrowser:showAuthor(name)
    local username, pseud = AO3WebParser.parseAuthorName(util.trim(name))
    self.Fanfic:showUserInfo(username, pseud)
end

function FanficBrowser:generateTable(kv_pairs, ficResults)
    -- Helper function to check if a fanfic is already downloaded
    local function isDownloaded(fanficId)
        return DownloadedFanfics.checkIfStored(fanficId)
    end

    -- Populate the initial list of fanfics
    for __, v in ipairs(ficResults) do
        if v.is_deleted then
            table.insert(kv_pairs, { "DELETED WORK", "", separator = true })
            for i = 1, ITEMS_PER_FIC - 2 do
                table.insert(kv_pairs, { "", "" })
            end
            table.insert(kv_pairs, { "", "", separator = true })
            goto continue
        end
        -- Check if the fanfic is already downloaded
        local downloadedFanfic = isDownloaded(v.id)
        local title = v.title

        -- Add a lock symbol if the work is restricted
        if v.is_restricted then
            title = "🔒 " .. title
        end

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
                                        self.Fanfic:UpdateFanfic(downloadedFanfic)
                                        UIManager:close(dialog)
                                    end,
                                },
                                {
                                    text = _("Open"),
                                    callback = function()
                                        UIManager:close(dialog)
                                        self.Fanfic:onOpenFanficReader(downloadedFanfic.path, downloadedFanfic)
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
                    if
                        Config:readSetting("show_adult_warning")
                        and (v.rating == "Explicit" or v.rating == "Mature" or v.rating == "Not Rated")
                    then
                        self:showAdultWarningDialog(v)
                    else
                        self:showDownloadDialog(v)
                    end
                end
            end,
        }

        table.insert(kv_pairs, title_item)
        -- Add additional details about the fanfic
        table.insert(kv_pairs, { "     " .. "Author:", (v.author or "Anonymous") .. (v.gifted_to and (" (Gifted to: " .. v.gifted_to .. ")") or "") ,
        callback = function()

            local buttons = {}

            local dialog

            if v.author then
                for author in string.gmatch(v.author, '([^,]+)') do
                    table.insert(buttons, {{
                        text = util.trim(author),
                        callback = function()
                                UIManager:close(dialog)
                                self:showAuthor(author)
                        end,
                    }})
                end
            end

            if v.gifted_to then
                for giftee in string.gmatch(v.gifted_to, '([^,]+)') do
                    table.insert(buttons, {{
                        text = util.trim(giftee) .. " (Giftee)",
                        callback = function()
                                UIManager:close(dialog)
                                self:showAuthor(giftee)
                        end,
                    }})
                end
            end

            -- If no buttons were created, just return
            if #buttons == 0 then
                return
            end

            table.insert(buttons,{{
                text = _("Close"),
                callback = function()
                    UIManager:close(dialog)
                end,
            }})

            dialog = ButtonDialog:new({

                -- anonymous gift works have giftee buttons but no author
                title = v.author and T("Work %1: %2", v.author:find(",") and "authors" or "author", v.author) or v.title,
                buttons = buttons,
            })
            UIManager:show(dialog)
        end,
        })
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
            v.hits or "0",
            v.kudos or "0",
            v.bookmarks or "0",
            v.comments or "0"
        )
        table.insert(kv_pairs, { "     " .. "Stats:", stats, separator = true })
        ::continue::
    end

    -- shortcut: KeyValuePage has no public per-page size, so refresh() fakes one work per page with a fixed row count
    assert(#kv_pairs == ITEMS_PER_FIC * #ficResults, "each work must render ITEMS_PER_FIC rows")
    return kv_pairs
end

function FanficBrowser:showDownloadDialog(fanfic)
    if not fanfic.id then 
        return
    end

    local confirmDialog
    confirmDialog = ButtonDialog:new({
        title = T("Would you like to download the work: %1 by %2?", fanfic.title, fanfic.author or "Anonymous"),
        buttons = {
            {
                {
                    text = "No",
                    callback = function()
                        UIManager:close(confirmDialog)
                    end,
                },
                {
                    text = "Yes",
                    callback = function()
                        -- the outer action keeps DownloadFanfic's result, so the list can show it as downloaded
                        Cancellable.run(_("Downloading work…"), function()
                            if self.Fanfic:DownloadFanfic(fanfic.id) then
                                self:refresh()
                            end
                        end)
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
                    text = "Cancel",
                    callback = function()
                        UIManager:close(warningDialog)
                    end,
                },
                {
                    text = "Continue",
                    callback = function()
                        UIManager:close(warningDialog)
                        self:showDownloadDialog(fanfic)
                    end,
                },
            },
        },
    })
    UIManager:show(warningDialog)
end

-- Rebuilds the window from the loaded works on the page it was showing, replacing the old one.
function FanficBrowser:refresh()
    local kv_pairs = self:generateTable({}, self.pager.items)
    if not self.pager.done then
        table.insert(kv_pairs, {
            _("Load more works…"),
            "",
            callback = function()
                self:loadMore()
            end,
        })
    end

    local old = self.browse_window
    self.browse_window = BrowseWindow:new{
        title = self.title,
        title_bar_fm_style = true,
        is_popout = false,
        is_borderless = true,
        kv_pairs = kv_pairs,
        show_page = old and old.show_page or 1,
        value_overflow_align = "center",
    }
    local window = self.browse_window
    if window.items_per_page > ITEMS_PER_FIC then
        window.items_per_page = ITEMS_PER_FIC
        window.pages = math.ceil(#kv_pairs / ITEMS_PER_FIC)
    end
    -- reaching the end drops the "Load more works…" row, which was alone on the last page
    window.show_page = math.max(1, math.min(window.show_page, window.pages))
    window:_populateItems()
    self.Fanfic.menu_stack[window] = true
    UIManager:show(window)
    if old then
        self.Fanfic.menu_stack[old] = nil -- UIManager:close doesn't call onClose
        UIManager:close(old)
    end
end

-- The "Load more works…" row sits on the page after the last work, so the first new work lands on that same page.
FanficBrowser.loadMore = Cancellable.wrap(_("Loading more works…"), function(self)
    if self.pager:loadMore(_("works")) then
        self:refresh()
    end
end)

function FanficBrowser:show(Fanfic, pager, total)
    FanficBrowser.Fanfic = Fanfic -- BrowseWindow:onClose reads it
    setmetatable({
        title = T("(%1) Tap fanfic title to download", total or "?"),
        pager = pager,
    }, { __index = FanficBrowser }):refresh()
end

return FanficBrowser
