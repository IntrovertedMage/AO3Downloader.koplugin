
local KeyValuePage = require("ui/widget/keyvaluepage")
local UIManager = require("ui/uimanager")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local logger = require("logger")
local InfoMessage = require("ui/widget/infomessage")
local MenuStack = require("menu_stack")
local AO3Manager = require("AO3_manager")
local FanficBrowser = require("fanficbrowser")

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


function AO3UserBrowser:show(userData)
    self.userData = userData

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
            self:openUserCollectionsList()
        end,
    }

    table.insert(kv_pairs, collections_item)

    local gifts_item = {
        "Gifted works:",
        self.userData.total_gifts,
        callback = function()
            self:openFanficBrowserForGifts()
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
                self:openFanficBrowserForCategory("works", fandom.count, fandom.name)
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
        MenuStack.menu_stack[self.AO3UserWindow] = nil
    end

    self.AO3UserWindow = UserWindow:new({
        title = title,
        kv_pairs = menu_table,
        title_bar_fm_style = true,
        is_popout = false,
        is_borderless = true,
        show_page = set_page,
    })
    MenuStack.menu_stack[self.AO3UserWindow] = true
    UIManager:show(self.AO3UserWindow)
end

function AO3UserBrowser:openFanficBrowserForCategory(category, total, fandom_name)
    local status, searchResult = AO3Manager:getWorksFromUserPage(self.userData.username, self.userData.pseud, category, fandom_name)
    if status then
        searchResult.count = total
        FanficBrowser:show(searchResult)
    else
        UIManager:show(InfoMessage:new{
            text = "Error: Failed to fetch works for category: " .. tostring(category),
        })
    end
end

function AO3UserBrowser:openFanficBrowserForGifts()
    local status, searchResult = AO3Manager:getWorksFromUserGifts(self.userData.username)
    if status then
        FanficBrowser:show(searchResult)
    else
        UIManager:show(InfoMessage:new{
            text = "Error: Failed to fetch gift works for user: " .. tostring(self.userData.username),
        })
    end
end

function AO3UserBrowser:openUserSeriesList()
    local success, seriesList, getNextPage = AO3Manager:getSeriesFromUserPage(self.userData.username, self.userData.pseud)  --
    if success and seriesList then
        local series_menu_kv = {}

        local function insert_back_to_profile_item()
            table.insert(series_menu_kv, 1, {
                "← Back to profile",
                "",
                separator = true,
                callback = function()
                    self:GoUpInMenu()
                end,
            })
        end

        local function add_series_to_menu(series)
            table.insert(series_menu_kv, {
                series.title,
                "",
                callback = function()
                    local status, searchResult = AO3Manager:getWorksFromSeries(series.id)
                    if not status then
                        return
                    end

                    FanficBrowser:show(searchResult)
                end,
                separator = true,
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

        local function refreshSeriesMenu()
            series_menu_kv = {}
            insert_back_to_profile_item()

            for __, series in pairs(seriesList) do
                add_series_to_menu(series)
                series_menu_kv[#series_menu_kv].separator = true
            end

            table.insert(series_menu_kv, {
                "Load more series...",
                "",
                callback = function()
                    local extra_series_list = getNextPage()

                    if #extra_series_list > 0 then
                        for __, series in pairs(extra_series_list) do
                            table.insert(seriesList, series)
                        end

                        refreshSeriesMenu()
                        self:loadPage("Series", series_menu_kv, true)


                    end
                end,
            })
        end

        refreshSeriesMenu()


        self:GoDownInMenu("Series", series_menu_kv)
    end
end

function AO3UserBrowser:openUserCollectionsList()
    local success, collectionsList, getNextPage = AO3Manager:getCollectionsFromUserPage(self.userData.username)
    if success and collectionsList then
        local collections_menu_kv = {}

        local function insert_back_to_profile_item()
            table.insert(collections_menu_kv, 1, {
                "← Back to profile",
                "",
                separator = true,
                callback = function()
                    self:GoUpInMenu()
                end,
            })
        end

        local function add_collection_to_menu(collection)
            table.insert(collections_menu_kv, {
                collection.title,
                "",
                callback = function()
                    local status, searchResult = AO3Manager:getWorksFromCollection(collection.id)
                    if not status then
                        return
                    end

                    FanficBrowser:show(searchResult)
                end,
                separator = true,
            })
            table.insert(collections_menu_kv,{
                "Tags:"
                , table.concat(collection.tags, ", "),
            })
            table.insert(collections_menu_kv,{
                "Work count:"
                , collection.work_count,
            })
            table.insert(collections_menu_kv,{
                "Author:"
                , collection.author,
            })
            table.insert(collections_menu_kv,{
                "Date:"
                , collection.date_posted,
            })
            if collection.summary and collection.summary ~= "" then
                table.insert(collections_menu_kv,{
                    "Summary:"
                    , collection.summary,
                })
            end
        end

        local function refreshCollectionsMenu()
            collections_menu_kv = {}
            insert_back_to_profile_item()

            for __, collection in pairs(collectionsList) do
                add_collection_to_menu(collection)
                collections_menu_kv[#collections_menu_kv].separator = true
            end

            table.insert(collections_menu_kv, {
                "Load more collections...",
                "",
                callback = function()
                    local extra_collections_list = getNextPage()

                    if #extra_collections_list > 0 then
                        for __, collection in pairs(extra_collections_list) do
                            table.insert(collectionsList, collection)
                        end

                        refreshCollectionsMenu()
                        self:loadPage("Collections", collections_menu_kv, true)
                    end
                end,
            })
        end

        refreshCollectionsMenu()
        self:GoDownInMenu("Collections", collections_menu_kv)
    end
end

function AO3UserBrowser:openPseudsList()
    local success, pseuds = AO3Manager:getPseudsForUser(self.userData.username)
    if success and pseuds then
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
                    local success, userData = AO3Manager:getUserData(self.userData.username, pseud.name)
                    if success then
                        self:show(userData)
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
