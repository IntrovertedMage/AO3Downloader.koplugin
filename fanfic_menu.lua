local Menu = require("ui/widget/menu")
local _ = require("gettext")
local FanficSearch = require("fanfic_search")
local FanficBrowser = require("fanficbrowser")
local Config = require("config")
local UIManager = require("ui/uimanager")
local DownloadedFanficsMenu = require("downloaded_fanfics_menu")
local ButtonDialog = require("ui/widget/buttondialog")
local util = require("util")
local Socket = require("socket")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local logger = require("logger")
local CustomFilterMenu = require("custom_filter_menu")

function util.contains(table, value)
    for _, v in ipairs(table) do
        if v == value then
            return true
        end
    end
    return false
end

local FanficMenuWidget = Menu:extend{
    fanfic = nil,
    is_popout = false,
    is_borderless = true,
    paths = nil,
    title = _("Fanfiction downloader"),
    subtitle = "",
    lock_return = false,
}

-- Menu action on return-arrow tap (go to one-level upper catalog)
function FanficMenuWidget:onReturn()
    if self.lock_return then
        return
    end
    logger.dbg(self.paths[#self.paths])
    local path = self.paths[#self.paths]
    if path then
        self:switchItemTable(path.title, path.items, -1, -1, path.subtitle)
        self.title = path.title
        self.subtitle = path.subtitle
        table.remove(self.paths, #self.paths)
    end
    return true
end

function FanficMenuWidget:GoDownInMenu(newTitle, newItems, newSubtitle)
    table.insert(self.paths, {
        title = self.title,
        subtitle = self.subtitle,
        items = self.item_table,

    })
    self:switchItemTable(newTitle, newItems, -1, -1, newSubtitle)
    self.title = newTitle
    self.subtitle = newSubtitle
end
local FanficMenu = {}

function FanficMenu:show(fanfic)
    self.fanfic = fanfic
    self.menuWidget = FanficMenuWidget:new{
        title = _("Fanfiction downloader"),
        item_table = {
            {
                text = "\u{f002} Search and download works from AO3",
                callback = function()
                    self:onSearchFanficMenu()
                end,
            },
            {
                text = "\u{2193} View downloaded fanfics",
                callback = function()
                    self:onViewDownloadedFanfics()
                end,
            },
            {
                text = "\u{2699} Settings",
                callback = function()
                    self:onOpenSettings()
                end,
            },
        },
    }

    return self.menuWidget
end


function FanficMenu:onSearchFanficMenu()
    local menu_items = {
        {
            text = _("Quick search"),
            callback = function()
                self:onQuickSearchMenu()
            end
        },
        {
            text = _("Search using Filter search"), -- New menu item
            callback = function()
                CustomFilterMenu:show(self.menuWidget, self.fanfic)
            end,
        },
        {
            text = _("Download work by ID"),
            callback = function()
                self:onShowFanficSearch()
            end,
        },
    }
    self.menuWidget:GoDownInMenu("Select search mode" , menu_items)
end

function FanficMenu:onQuickSearchMenu()
    local menu_items = {
        {
            text = "Browse works by Fandom",
            callback = function()
                self:onSelectTag("Fandom")
            end,
        },
        {
            text = "Browse works by Character",
            callback = function()
                self:onSelectTag("Character")
            end,
        },
        {
            text = "Browse works by Relationship",
            callback = function()
                self:onSelectTag("Relationship")
            end,
        },
        {
            text = "Browse works by Freeform tag",
            callback = function()
                self:onSelectTag("Freeform")
            end,
        },
    }
    self.menuWidget:GoDownInMenu("Select quick search mode" , menu_items)

end

function FanficMenu:onShowFanficSearch()
    FanficSearch:show(self.menuWidget, function(fanficId)
        self.fanfic:DownloadFanfic(fanficId)
    end)
end


function FanficMenu:onSelectTag(category)
    local bookmarkSetting = T("bookmarked%1s", category)
    logger.dbg("setting name: " .. bookmarkSetting)
    local function refreshMenu()
        local menu_items = {}

        -- Add an option to search for fandoms
        table.insert(menu_items, {
            text = T("\u{f002} Search %1", category),
            callback = function()
                self:onSearchTag(category)
            end,
        })

        -- Get the list of bookmarked fandoms
        local bookmarks = Config:readSetting(bookmarkSetting, {})

        -- Add bookmarked fandoms to the menu
        for __, tag in ipairs(bookmarks) do
            local displayText = T("★ %1", tag)
            table.insert(menu_items, {
                text = displayText,
                callback = function()
                    -- Submenu for the selected fandom
                    local dialog
                    dialog = ButtonDialog:new{
                        title = displayText,
                        buttons = {
                            {
                            {
                                text = _("Browse Works"),
                                callback = function()
                                    self:onBrowseByTag(tag)
                                    UIManager:close(dialog)
                                end,
                            },
                            {
                                text = _(T("Unbookmark %1", category)),
                                callback = function()
                                    -- Remove the fandom from bookmarks
                                    for i, v in ipairs(bookmarks) do
                                        if v == tag then
                                            table.remove(bookmarks, i)
                                            break
                                        end
                                    end
                                    Config:saveSetting(bookmarkSetting, bookmarks)
                                    UIManager:show(InfoMessage:new{
                                        text = T("'%1' has been removed from your bookmarks.", tag),
                                    })
                                    UIManager:close(dialog)
                                    refreshMenu() -- Refresh the menu to update the star
                                    self.menuWidget.item_table = refreshMenu() -- Refresh the menu to update the star
                                    self.menuWidget:updateItems()
                                end,
                            },
                            }
                        }
                    }
                    UIManager:show(dialog)
                end,
            })
        end

        return menu_items
    end

    -- Initial menu display

    self.menuWidget:GoDownInMenu(T("Select a %1 tag", category), refreshMenu())
end

function FanficMenu:onSearchTag(category)
    -- Show an input dialog to enter the fandom search query
    local searchDialog
    local bookmarkSetting = T("bookmarked%1s", category)
    searchDialog = InputDialog:new{
        title = T("Search for %1s tags on AO3", category),
        input = "",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Close"),
                    id = "close",
                    callback = function()
                        UIManager:close(searchDialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local query = searchDialog:getInputText()
                        local success, tags
                        -- Function to refresh the menu items
                        local function refreshMenu()
                            local bookmarks = Config:readSetting(bookmarkSetting, {})

                            -- Show the matching fandoms in a menu
                            local menu_items = {}
                            for __, tag in ipairs(tags) do
                                local isBookmarked = util.contains(bookmarks, tag.name)
                                local displayText = isBookmarked and T("★ (%1) %2", tag.uses, tag.name) or T("(%1) %2", tag.uses, tag.name)

                                table.insert(menu_items, {
                                    text = displayText,
                                    callback = function()
                                        local dialog
                                        dialog = ButtonDialog:new{
                                            title = displayText,
                                            buttons = {
                                                {
                                                {
                                                    text = _("Browse Works"),
                                                    callback = function()
                                                        self:onBrowseByTag(tag.name)
                                                        UIManager:close(dialog)
                                                    end,
                                                },
                                                {
                                                    text = _(not isBookmarked and T("Bookmark %1", category) or T("Unbookmark %1", category)),
                                                    callback = function()
                                                        -- Add the fandom to bookmarks
                                                        if not isBookmarked then
                                                            table.insert(bookmarks, tag.name)
                                                            Config:saveSetting(bookmarkSetting , bookmarks)
                                                            UIManager:show(InfoMessage:new{
                                                                text = T("'%1' has been added to your bookmarks.", tag.name),
                                                            })
                                                        else
                                                            for i, v in ipairs(bookmarks) do
                                                                if v == tag.name then
                                                                    table.remove(bookmarks, i)
                                                                    break
                                                                end
                                                            end
                                                            Config:saveSetting(bookmarkSetting, bookmarks)
                                                            UIManager:show(InfoMessage:new{
                                                                text = T("'%1' has been removed from your bookmarks.", tag.name),
                                                            })
                                                        end
                                                        UIManager:close(dialog)
                                                        self.menuWidget.item_table = refreshMenu() -- Refresh the menu to update the star
                                                        self.menuWidget:updateItems()
                                                    end,
                                                },
                                                }
                                            }
                                        }
                                        UIManager:show(dialog)
                                    end,
                                })
                            end
                            return menu_items
                        end
                        UIManager:scheduleIn(1, function()
                            tags = self.fanfic:searchForTags(query, category)

                            UIManager:close(searchDialog)


                            if not tags then
                                return
                            end
                            --

                            -- Initial menu display

                            self.menuWidget:GoDownInMenu(T('"%1" %2 query results', query, category), refreshMenu())
                        end)
                        UIManager:show(InfoMessage:new{
                            text = T("Downloading %1 info may take some time…", category),
                            timeout = 1,
                        })
                end,
                },
            },
        }
    }

    UIManager:show(searchDialog)
    searchDialog:onShowKeyboard()
end

function FanficMenu:onBrowseByTag(selectedTag)

    -- Define available sorting options
    local sorting_options = {
        { text = _("Sort by Author"), value = "authors_to_sort_on" },
        { text = _("Sort by Title"), value = "title_to_sort_on" },
        { text = _("Sort by Date Posted"), value = "created_at" },
        { text = _("Sort by Date Updated"), value = "revised_at" },
        { text = _("Sort by Word Count"), value = "word_count" },
        { text = _("Sort by Hits"), value = "hits" },
        { text = _("Sort by Kudos"), value = "kudos_count" },
        { text = _("Sort by Comments"), value = "comments_count" },
        { text = _("Sort by Bookmarks"), value = "bookmarks_count" },
    }

    -- Create a menu for sorting options
    local menu_items = {}
    for __, option in ipairs(sorting_options) do

        table.insert(menu_items, {
            text = option.text,
            callback = function()
                UIManager:scheduleIn(1, function()
                    local success, ficResults, fetchNextPage = self.fanfic:fetchFanficsByTag(selectedTag, option.value)
                    if not success then
                        return
                    end
                    FanficBrowser:show(
                        self.ui,
                        self.menuWidget,
                        ficResults,
                        fetchNextPage,
                        function(fanfic) self.fanfic:UpdateFanfic(fanfic) end, -- Update callback
                        function(fanficId, parentMenu) self.fanfic:DownloadFanfic(fanficId, parentMenu) end -- Download callback
                    )
                end)
                UIManager:show(InfoMessage:new{
                    text = _("Downloading works data may take some time…"),
                    timeout = 1,
                })
            end,
        })
    end

    self.menuWidget:GoDownInMenu("Sort by...",menu_items)
end

function FanficMenu:onViewDownloadedFanfics()
    DownloadedFanficsMenu:show(self.fanfic.ui, self.menuWidget, function(fanfic)
        self.fanfic:UpdateFanfic(fanfic)
    end)
end

function FanficMenu:onOpenSettings()
    local settings_options = {
        {text = "AO3 URL", setting = "AO3_domain"}
    }
    local settings_menu_items = {}

    for __, setting in ipairs(settings_options) do
        table.insert(settings_menu_items, {
            text = setting.text,
            callback = function()
                -- Show an input dialog to update the setting
                local inputDialog
                inputDialog = InputDialog:new{
                    title = T("Set value for '%1'", setting.text),
                    input = Config:readSetting(setting.setting),
                    input_type = "text",
                    buttons = {
                        {
                        {
                            text = _("Cancel"),
                            callback = function()
                                UIManager:close(inputDialog)
                            end,
                        },
                        {
                            text = _("Save"),
                            is_enter_default = true,
                            callback = function()
                                local newValue = inputDialog:getInputText()
                                Config:saveSetting(setting.setting, newValue)
                                UIManager:close(inputDialog)
                                UIManager:show(InfoMessage:new{
                                    text = T("'%1' updated successfully.", setting.text),
                                })
                            end,
                        },
                        }
                    },
                }
                UIManager:show(inputDialog)
                inputDialog:onShowKeyboard()
            end,
        })
    end

    self.menuWidget:GoDownInMenu("Settings", settings_menu_items)
end



return FanficMenu

