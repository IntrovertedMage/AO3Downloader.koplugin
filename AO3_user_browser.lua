
local KeyValuePage = require("ui/widget/keyvaluepage")
local UIManager = require("ui/uimanager")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local logger = require("logger")

local AO3UserBrowser = {
    Fanfic = nil,
    userData = nil,
    uiManager = nil,
    parentMenu = nil,
    menu = nil,
}

function AO3UserBrowser:show(userData, ui, parentMenu, fanfic)
    self.userData = userData
    self.parentMenu = parentMenu
    self.ui = ui
    self.Fanfic = fanfic

    local menuTable = self:generateMenuTable()

    UserWindow = KeyValuePage:extend{
        title = "",
        kv_pairs = {},
    }

    self:loadPage()


end

function AO3UserBrowser:generateMenuTable()
    local kv_pairs = {}

    local table_contains = function(table, element)
        for _, value in pairs(table) do
            if value == element then
                return true
            end
        end
        return false
    end

    local table_remove = function(table, element)
        for i, value in pairs(table) do
            if value == element then
                table[i] = nil
                return
            end
        end
    end

    local Config = require("fanfic_config")

    local bookmarked_users = Config:readSetting("bookmarkedUsers", {})

    local user_display_name = (self.userData.username == self.userData.pseud and self.userData.username or self.userData.pseud .. " (" .. self.userData.username .. ")")

    local is_bookmarked = table_contains(bookmarked_users, user_display_name)

    local bookmark_user_item = {
        is_bookmarked and "★ Remove user from bookmarks" or "☆ Bookmark user",
        "",
        callback = function()
            -- Make sure to get most recent version of bookmarks in case of changes elsewhere
            bookmarked_users = Config:readSetting("bookmarkedUsers", {})
            is_bookmarked = table_contains(bookmarked_users, user_display_name)
            local InfoMessage = require("ui/widget/infomessage")
            if is_bookmarked then
                table_remove(bookmarked_users, user_display_name)
                Config:saveSetting("bookmarkedUsers", bookmarked_users)
                UIManager:show(InfoMessage:new({
                    text = T("User: '%1' has been removed from your bookmarks.", user_display_name),
                }))
            else
                table.insert(bookmarked_users, user_display_name)
                Config:saveSetting("bookmarkedUsers", bookmarked_users)
                UIManager:show(InfoMessage:new({
                    text = T("User: '%1' has been added to your bookmarks.", user_display_name),
                }))
            end

            self:loadPage()
        end,
        separator = true,
    }

    table.insert(kv_pairs, bookmark_user_item)

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

    -- table.insert(kv_pairs, series_item)

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
            self:openFanficBrowserForCategory("collections", self.userData.total_collections, nil)
        end,
    }

    -- table.insert(kv_pairs, collections_item)

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

function AO3UserBrowser:loadPage()
    if self.AO3UserWindow then
        UIManager:close(self.AO3UserWindow)
    end
    local author_string
    if self.userData.pseud ~= self.userData.username then
        author_string = T("%1 (%2)", self.userData.pseud, self.userData.username)
    else
        author_string = self.userData.username
    end

    self.AO3UserWindow = UserWindow:new({
        title = "AO3 User: " .. author_string,
        kv_pairs = self:generateMenuTable(),
        title_bar_fm_style = true,
        is_popout = false,
        is_borderless = true,
        show_page = 1,
    })
    UIManager:show(self.AO3UserWindow)
end

function AO3UserBrowser:openFanficBrowserForCategory(category, total, fandom_id)
    local success, works, getNextPage = self.Fanfic:getWorksFromUserPage(self.userData.username, self.userData.pseud, category, fandom_id)
    works.total =  works.total or total or 0
    if success then
        self.Fanfic:onShowFanficBrowser(self.parentMenu, works, getNextPage)
    else
        self.ui:showMessageBox("Error", "Failed to fetch works for category: " .. tostring(category))
    end
end

function AO3UserBrowser:openUserSeriesList()
    local success, seriesList = self.Fanfic:getSeriesFromUserPage(self.userData.username)  --
    if success then
        logger.dbg(seriesList)
    end
end

return AO3UserBrowser
