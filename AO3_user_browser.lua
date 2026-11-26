
local KeyValuePage = require("ui/widget/keyvaluepage")
local UIManager = require("ui/uimanager")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local InfoMessage = require("ui/widget/infomessage")
local Cancellable = require("cancellable")
local UIResult = require("ui_result")
local AO3DownloaderClient = require("AO3_downloader_client")
local _ = require("gettext")

local AO3UserBrowser = {
    Fanfic = nil,
    userData = nil,
    uiManager = nil,
    menu = nil,
    menu_layers = {},
}

local UserWindow = KeyValuePage:extend{
    title = "",
    kv_pairs = {},
}

function AO3UserBrowser:GoDownInMenu(new_title, new_keypairs)
    local current_state = {
        title = self.AO3UserWindow.title,
        kv_pairs = self.AO3UserWindow.kv_pairs,
    }
    table.insert(self.menu_layers, current_state)

    self:loadPage(new_title, new_keypairs)
end

function AO3UserBrowser:GoUpInMenu()
    local previousState = self.menu_layers[#self.menu_layers]
    self.menu_layers[#self.menu_layers] = nil
    if previousState then
        self:loadPage(previousState.title, previousState.kv_pairs)
    end
end


function AO3UserBrowser:show(userData, ui, fanfic)
    self.userData = userData
    self.ui = ui
    self.Fanfic = fanfic

    self:reloadProfile()


end

function AO3UserBrowser:generateMenuTable()
    local kv_pairs = {}

    local Config = require("fanfic_config")

    local bookmarked_users = Config:readSetting("bookmarkedUsers", {})

    local user_display_name = (self.userData.username == self.userData.pseud and self.userData.username or self.userData.pseud .. " (" .. self.userData.username .. ")")

    local is_bookmarked = require("util").arrayContains(bookmarked_users, user_display_name)

    local bookmark_user_item = {
        is_bookmarked and "★ Remove user from bookmarks" or "☆ Bookmark user",
        "",
        callback = function()
            -- re-reads the current list, toggles this user in it, and persists it
            local added = Config:toggleInSetting("bookmarkedUsers", user_display_name)
            UIManager:show(InfoMessage:new({
                text = T("User: '%1' has been %2.", user_display_name,
                    added and "added to your bookmarks" or "removed from your bookmarks"),
            }))
            self:reloadProfile()
        end,
        separator = true,
    }

    table.insert(kv_pairs, bookmark_user_item)

    local pseuds_item = {
        "Other Pseuds:",
        self.userData.total_pseuds,
        callback = function()
            self:openPseudsList()
        end,
        separator = true,
    }

    table.insert(kv_pairs, pseuds_item)

    local all_works_item = {
        "Works:",
        self.userData.total_works,
        callback = function()
            self:openFanficBrowserForCategory("works", nil)
        end,
    }

    table.insert(kv_pairs, all_works_item)

    local series_item = {
        "Series:",
        self.userData.total_series,
        callback = function()
            self:openUserSeriesList()
        end,
    }

    table.insert(kv_pairs, series_item)

    local bookmarks_item = {
        "Bookmarked works:",
        self.userData.total_bookmarks,
        callback = function()
            self:openFanficBrowserForCategory("bookmarks", self.userData.total_bookmarks, nil)
        end,
    }

    table.insert(kv_pairs, bookmarks_item)

    local collections_item = {
        "Collections:",
        self.userData.total_collections,
        callback = function()
            self:openUserCollectionsList()
        end,
    }

    table.insert(kv_pairs, collections_item)

    local gifts_item = {
        "Gifted works:",
        self.userData.total_gifts,
        callback = function()
            self:openFanficBrowserForCategory("gifts", self.userData.total_gifts, nil)
        end,
        separator = true,
    }

    table.insert(kv_pairs, gifts_item)

    local fandom_title_item = {
        "Works by fandom:",
        "",
        separator = true,

    }

    table.insert(kv_pairs, fandom_title_item)

    for __, fandom in pairs(self.userData.fandoms) do
        local fandom_item = {
            T("(%1) %2", fandom.count, fandom.name),
            "",
            callback = function()
                self:openFanficBrowserForCategory("works", fandom.count, fandom.id)
            end
        }
        table.insert(kv_pairs, fandom_item)
    end


    return kv_pairs
end

function AO3UserBrowser:reloadProfile()
    local author_string
    self.menu_layers = {}

    if self.userData.pseud ~= self.userData.username then
        author_string = T("%1 (%2)", self.userData.pseud, self.userData.username)
    else
        author_string = self.userData.username
    end

    local new_menu_table = self:generateMenuTable()
    self:loadPage(author_string, new_menu_table)
end

function AO3UserBrowser:loadPage(title, menu_table, keeping_current_page)
    local set_page = 1
    if keeping_current_page and self.AO3UserWindow then
        set_page = self.AO3UserWindow.show_page
    end
    if self.AO3UserWindow then
        UIManager:close(self.AO3UserWindow)
        self.Fanfic.menu_stack[self.AO3UserWindow] = nil
    end

    self.AO3UserWindow = UserWindow:new({
        title = title,
        kv_pairs = menu_table,
        title_bar_fm_style = true,
        is_popout = false,
        is_borderless = true,
        show_page = set_page,
    })
    self.Fanfic.menu_stack[self.AO3UserWindow] = true
    UIManager:show(self.AO3UserWindow)
end

function AO3UserBrowser:openFanficBrowserForCategory(category, total, fandom_id)
    self.Fanfic:browse(_("Loading works…"), function(page)
        return AO3DownloaderClient:getWorksFromUserPage(self.userData.username, self.userData.pseud, category, fandom_id, page)
    end, total or 0)
end

-- Shows a paged list of series or collections; tapping one browses its works.
-- detailRows(item) returns the key/value rows shown under each item's title.
function AO3UserBrowser:openPagedList(title, pager, fetchWorks, detailRows)
    local function buildMenu()
        local kv_pairs = { {
            "← Back to profile",
            "",
            separator = true,
            callback = function()
                self:GoUpInMenu()
            end,
        } }
        for __, item in ipairs(pager.items) do
            table.insert(kv_pairs, {
                item.title,
                "",
                separator = true,
                callback = function()
                    self.Fanfic:browse(_("Loading works…"), function(page)
                        return fetchWorks(item.id, page)
                    end, item.work_count or 0)
                end,
            })
            for __, row in ipairs(detailRows(item)) do
                table.insert(kv_pairs, row)
            end
            kv_pairs[#kv_pairs].separator = true
        end
        if pager.done then
            return kv_pairs
        end
        table.insert(kv_pairs, {
            T("Load more %1…", title:lower()),
            "",
            callback = Cancellable.wrap(T(_("Loading more %1…"), title:lower()), function()
                if pager:loadMore(title:lower()) then
                    self:loadPage(title, buildMenu(), true)
                end
            end),
        })
        return kv_pairs
    end
    self:GoDownInMenu(title, buildMenu())
end

-- Appends the summary row when there is one.
local function withSummary(rows, summary)
    if summary and summary ~= "" then
        table.insert(rows, { "Summary:", summary })
    end
    return rows
end

AO3UserBrowser.openUserSeriesList = Cancellable.wrap(_("Loading series…"), function(self)
    local pager = UIResult.paged(function(page)
        return AO3DownloaderClient:getUserSeries(self.userData.username, self.userData.pseud, page)
    end)
    if not pager then
        return
    end
    self:openPagedList("Series", pager, function(id, page)
        return AO3DownloaderClient:getWorksFromSeries(id, page)
    end, function(item)
        return withSummary({
            { "Fandoms:", table.concat(item.fandoms, ", ") },
            { "Work count:", item.work_count },
            { "Word count:", item.word_count },
            { "Author:", item.author },
            { "Date:", item.date_posted },
        }, item.summary)
    end)
end)

AO3UserBrowser.openUserCollectionsList = Cancellable.wrap(_("Loading collections…"), function(self)
    local pager = UIResult.paged(function(page)
        return AO3DownloaderClient:getUserCollections(self.userData.username, page)
    end)
    if not pager then
        return
    end
    self:openPagedList("Collections", pager, function(id, page)
        return AO3DownloaderClient:getWorksFromCollection(id, page)
    end, function(item)
        return withSummary({
            { "Tags:", table.concat(item.tags, ", ") },
            { "Work count:", item.work_count },
            { "Author:", item.author },
            { "Date:", item.date_posted },
        }, item.summary)
    end)
end)

AO3UserBrowser.openPseudsList = Cancellable.wrap(_("Loading pseuds…"), function(self)
    local pseuds = UIResult.unwrap(AO3DownloaderClient:getUserPseuds(self.userData.username))
    if pseuds then
        local pseuds_menu_kv = {}

        table.insert(pseuds_menu_kv, {
            "← Back to profile",
            "",
            separator = true,
            callback = function()
                self:GoUpInMenu()
            end,
        })

        for __, pseud in pairs(pseuds) do
            table.insert(pseuds_menu_kv, {
                T("%1 (%2 works) (%3 recs)", pseud.name, pseud.works_count, pseud.recs_count),
                "",
                callback = function()
                    self.Fanfic:showUserInfo(self.userData.username, pseud.name)
                end,
            })

        end

        pseuds_menu_kv[#pseuds_menu_kv].separator = true


        self:GoDownInMenu("Other Pseuds", pseuds_menu_kv)
    end
end)

return AO3UserBrowser
