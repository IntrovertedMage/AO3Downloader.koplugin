
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

    local author_string

    if self.userData.pseud ~= self.userData.username then
        author_string = T("%1 (%2)", self.userData.pseud, self.userData.username)
    else
        author_string = self.userData.username
    end

    self.AO3UserWindow = UserWindow:new({
        title = "AO3 User: " .. author_string,
        kv_pairs = menuTable,
        title_bar_fm_style = true,
        is_popout = false,
        is_borderless = true,
        show_page = 1,
    })

    UIManager:show(self.AO3UserWindow)

end

function AO3UserBrowser:generateMenuTable()
    local kv_pairs = {}

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
        "Works by fandoms",
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
