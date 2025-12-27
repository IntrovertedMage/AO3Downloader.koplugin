
local KeyValuePage = require("ui/widget/keyvaluepage")
local UIManager = require("ui/uimanager")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local logger = require("logger")
local InfoMessage = require("ui/widget/infomessage")

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

function AO3UserBrowser:loadPage(title, menu_table)
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
        show_page = 1,
    })
    self.Fanfic.menu_stack[self.AO3UserWindow] = true
    UIManager:show(self.AO3UserWindow)
end

function AO3UserBrowser:openFanficBrowserForCategory(category, total, fandom_id)
    local success, works, getNextPage = self.Fanfic:getWorksFromUserPage(self.userData.username, self.userData.pseud, category, fandom_id)
    works.total =  works.total or total or 0
    if success then
        self.Fanfic:onShowFanficBrowser(works, getNextPage)
    else
        self.ui:showMessageBox("Error", "Failed to fetch works for category: " .. tostring(category))
    end
end

function AO3UserBrowser:openUserSeriesList()
    local success, seriesList = self.Fanfic:getSeriesFromUserPage(self.userData.username)  --
    if success then
        local series_menu_kv = {}
        table.insert(series_menu_kv, {
            "← Back to profile",
            "",
            separator = true,
            callback = function()
                self:GoUpInMenu()
            end,
        })
        for __, series in pairs(seriesList) do
            series_menu_kv[#series_menu_kv].separator = true

            table.insert(series_menu_kv, {
                series.title,
                "",
                callback = function()
                    local success, seriesWorks, fetchNextPage = self.Fanfic:getWorksFromSeries(series.id)
                    if success == false then
                        return
                    end

                    seriesWorks.total = series.work_count or 0
                    self.Fanfic:onShowFanficBrowser(seriesWorks, fetchNextPage)
                end,
                seperator = true,
            })
            table.insert(series_menu_kv,{
                "Fandoms:"
                , table.concat(series.fandoms, ", "),
            })
            table.insert(series_menu_kv,{
                "Work count:"
                , series.work_count,
            })
            table.insert(series_menu_kv,{
                "Word count:"
                , series.word_count,
            })
            table.insert(series_menu_kv,{
                "Author:"
                , series.author,
            })
            table.insert(series_menu_kv,{
                "Date:"
                , series.date_posted,
            })
            if series.summary and series.summary ~= "" then
                table.insert(series_menu_kv,{
                    "Summary:"
                    , series.summary,
                })
            end
        end

        self:GoDownInMenu("Series", series_menu_kv)
    end
end

function AO3UserBrowser:openPseudsList()
    local success, pseuds = self.Fanfic:getPseudsForUser(self.userData.username)
    if success then
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
                    local success, userData = self.Fanfic:getUserData(self.userData.username, pseud.name)
                    if success then
                        self:show(userData, self.ui, self.Fanfic)
                    else
                        UIManager:show(InfoMessage:new({
                            text = T("Failed to fetch data for pseud: '%1'", pseud.name),
                        }))
                    end
                end,
            })

        end

        pseuds_menu_kv[#pseuds_menu_kv].separator = true


        self:GoDownInMenu("Other Pseuds", pseuds_menu_kv)
    else
        UIManager:show(InfoMessage:new({
            text = T("Failed to fetch pseuds for user: '%1'", self.userData.username),
        }))
    end
end

return AO3UserBrowser
