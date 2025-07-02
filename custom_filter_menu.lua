local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local FanficBrowser = require("fanficbrowser")
local Config = require("fanfic_config")
local UIManager = require("ui/uimanager")
local util = require("util")
local logger = require("logger")
local _ = require("gettext")

function util.contains(tableValue, value, comparisonFunction)
    logger.dbg(tableValue)
    if comparisonFunction == nil then
        comparisonFunction = function(v1, v2)
            return v1 == v2
        end
    end

    for _, v in pairs(tableValue) do
        if comparisonFunction(v, value) then
            return true
        end
    end
    return false
end

function util.remove(tableValue, value)
    for i, v in ipairs(tableValue) do
        if v == value then
            table.remove(tableValue, i)
            break
        end
    end
end

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

local CustomFilterMenu = {}

function CustomFilterMenu:goBack()
    self.menuWidget:onReturn()
    self.menuWidget:updateItems(1)
end

function CustomFilterMenu:checkboxWidget(title, options, settingValue)
    local excludeSettingValue = "exclude_" .. settingValue -- Corrected typo
    logger.dbg("exclude setting value:" .. excludeSettingValue)
    if self.filter[settingValue] == nil then
        self.filter[settingValue] = {}
    end
    if self.filter[excludeSettingValue] == nil then
        self.filter[excludeSettingValue] = {}
    end
    self.menuWidget.lock_return = true
    local menu_items = {}
    for __, option in pairs(options) do
        table.insert(menu_items, {
            text_func = function()
                local show_checked = util.contains(self.filter[settingValue], option.value)
                local show_crossed = util.contains(self.filter[excludeSettingValue], option.value)
                if show_checked then
                    return "✓ " .. option.text
                elseif show_crossed then
                    return "× " .. option.text
                else
                    return option.text
                end
            end,
            callback = function()
                if util.contains(self.filter[settingValue], option.value) then
                    util.remove(self.filter[settingValue], option.value)
                    table.insert(self.filter[excludeSettingValue], option.value)
                elseif util.contains(self.filter[excludeSettingValue], option.value) then
                    util.remove(self.filter[excludeSettingValue], option.value)
                else
                    table.insert(self.filter[settingValue], option.value)
                end
                self.menuWidget:updateItems()
            end,
        })
    end

    table.insert(menu_items, {
        text = "← Back to filters",
        callback = function()
            if #self.filter[settingValue] == 0 then
                self.filter[settingValue] = nil
            end
            if #self.filter[excludeSettingValue] == 0 then
                self.filter[excludeSettingValue] = nil
            end
            self.menuWidget.lock_return = false
            self:goBack()
            self.menuWidget:updateItems()
        end,
    })

    self.menuWidget:GoDownInMenu(title, menu_items, "Tap to add to add to filter, and again for exclude filter")
end

function CustomFilterMenu:textboxWidget(title, setting)
    local inputDialog
    inputDialog = InputDialog:new({
        title = title,
        input = "",
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
                    text = _("Enter"),
                    is_enter_default = true,
                    callback = function()
                        local value = inputDialog:getInputText()
                        if value == "" then
                            value = nil
                        end
                        self.filter[setting] = value
                        self.menuWidget:updateItems()
                        UIManager:close(inputDialog)
                    end,
                },
            },
        },
    })
    UIManager:show(inputDialog)
    inputDialog:onShowKeyboard()
end

function CustomFilterMenu:selectionWidget(title, options, setting)
    self.menuWidget.lock_return = true
    local menu_items = {}
    for __, option in pairs(options) do
        table.insert(menu_items, {
            text = option.text,
            callback = function()
                self.filter[setting] = option.value
                self.menuWidget.lock_return = false
                self:goBack()
            end,
        })
    end
    self.menuWidget:GoDownInMenu(title, menu_items, "Select option to filter by")
end

function CustomFilterMenu:tagSelectionWidget(title, tagCatagoryForSearch, settingValue)
    self.menuWidget.lock_return = true
    local excludeSettingValue = "exclude_" .. settingValue

    if self.filter[settingValue] == nil then
        self.filter[settingValue] = {}
    end
    if self.filter[excludeSettingValue] == nil then
        self.filter[excludeSettingValue] = {}
    end

    local function refresh()
        local menu_items = {}
        table.insert(menu_items, {
            text = "← Back to filters menu",
            callback = function()
                if #self.filter[settingValue] == 0 then
                    self.filter[settingValue] = nil
                end
                if #self.filter[excludeSettingValue] == 0 then
                    self.filter[excludeSettingValue] = nil
                end

                self.menuWidget.lock_return = false
                self:goBack()
            end,
        })

        table.insert(menu_items, {
            text = "\u{f002} Search for tags to add to filter",
            callback = function()
                local inputDialog
                inputDialog = InputDialog:new({
                    title = title,
                    input = "",
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
                                text = _("Search"),
                                is_enter_default = true,
                                callback = function()
                                    local value = inputDialog:getInputText()
                                    if value == "" then
                                        return
                                    end
                                    local success, tagSearchResults = self.fanfic:searchForTags(value, tagCatagoryForSearch)
                                    if success then
                                        self:tagSearchSelectionWidget(
                                            "Tap on character tags to add to filter",
                                            tagSearchResults,
                                            settingValue,
                                            refresh
                                        )
                                        UIManager:close(inputDialog)
                                    end
                                end,
                            },
                        },
                    },
                })
                UIManager:show(inputDialog)
                inputDialog:onShowKeyboard()
            end,
        })

        for __, tag in pairs(self.filter[settingValue]) do
            table.insert(menu_items, {
                text = "✓ " .. tag,
                value = tag,
                callback = function()
                    local optionsDialog
                    optionsDialog = ButtonDialog:new({
                        buttons = {
                            {
                                {
                                    text = "Move to exclude filter",

                                    callback = function()
                                        util.remove(self.filter[settingValue], tag)
                                        table.insert(self.filter[excludeSettingValue], tag)

                                        self.menuWidget.item_table = refresh()
                                        self.menuWidget:updateItems(1)
                                        UIManager:close(optionsDialog)
                                    end,
                                },
                                {
                                    text = "Remove tag",
                                    callback = function()
                                        util.remove(self.filter[settingValue], tag)
                                        self.menuWidget.item_table = refresh()
                                        self.menuWidget:updateItems(1)
                                        UIManager:close(optionsDialog)
                                    end,
                                },
                                {
                                    text = "Cancel",
                                    callback = function()
                                        UIManager:close(optionsDialog)
                                    end,
                                },
                            },
                        },
                    })
                    UIManager:show(optionsDialog)
                end,
            })
        end
        for __, tag in pairs(self.filter[excludeSettingValue]) do
            table.insert(menu_items, {
                text = "× " .. tag,
                value = tag,
                callback = function()
                    local optionsDialog
                    optionsDialog = ButtonDialog:new({
                        buttons = {
                            {
                                {
                                    text = "Move to include filter",

                                    callback = function()
                                        util.remove(self.filter[excludeSettingValue], tag)
                                        table.insert(self.filter[settingValue], tag)

                                        self.menuWidget.item_table = refresh()
                                        self.menuWidget:updateItems(1)
                                        UIManager:close(optionsDialog)
                                    end,
                                },
                            },
                            {
                                {
                                    text = "Remove tag",
                                    callback = function()
                                        util.remove(self.filter[excludeSettingValue], tag)
                                        self.menuWidget.item_table = refresh()
                                        self.menuWidget:updateItems(1)
                                        UIManager:close(optionsDialog)
                                    end,
                                },
                            },
                            {
                                {
                                    text = "Cancel",
                                    callback = function()
                                        UIManager:close(optionsDialog)
                                    end,
                                },
                            },
                        },
                    })
                    UIManager:show(optionsDialog)
                end,
            })
        end

        return menu_items
    end

    self.menuWidget:GoDownInMenu(title, refresh())
end

function CustomFilterMenu:tagSearchSelectionWidget(title, tagSearchResults, settingValue, refreshCallback)
    local menu_items = {}
    local excludeSettingValue = "exclude_" .. settingValue

    table.insert(menu_items, {
        text = "← Exit search",
        callback = function()
            self.menuWidget.lock_return = false
            self:goBack()
            self.menuWidget.lock_return = true
            self.menuWidget.item_table = refreshCallback()
            self.menuWidget:updateItems()
        end,
    })

    for __, tag in pairs(tagSearchResults) do
        table.insert(menu_items, {
            text_func = function()
                local show_checked = util.contains(self.filter[settingValue], tag.name)
                local show_cross = util.contains(self.filter[excludeSettingValue], tag.name)
                if show_checked then
                    return "✓ " .. tag.name
                elseif show_cross then
                    return "× " .. tag.name
                else
                    return tag.name
                end
            end,
            callback = function()
                if util.contains(self.filter[settingValue], tag.name) then
                    util.remove(self.filter[settingValue], tag.name)
                    table.insert(self.filter[excludeSettingValue], tag.name)
                elseif util.contains(self.filter[excludeSettingValue], tag.name) then
                    util.remove(self.filter[excludeSettingValue], tag.name)
                else
                    table.insert(self.filter[settingValue], tag.name)
                end
                self.menuWidget:updateItems()
            end,
        })
    end

    self.menuWidget:GoDownInMenu(title, menu_items, "Tap tag to add to filter, again for exclude filter")
end

function CustomFilterMenu:singleTagSelection(title, tagCatagoryForSearch, settingValue)
    local inputDialog
    inputDialog = InputDialog:new({
        title = title,
        input = "",
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
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local value = inputDialog:getInputText()
                        if value == "" then
                            return
                        end
                        local success, tagSearchResults = self.fanfic:searchForTags(value, tagCatagoryForSearch)
                        if success then
                            self:singleTagSearchSelection(
                                "Tap on character tags to add to filter",
                                tagSearchResults,
                                settingValue
                            )
                            UIManager:close(inputDialog)
                        end
                    end,
                },
            },
        },
    })
    UIManager:show(inputDialog)
    inputDialog:onShowKeyboard()
end

function CustomFilterMenu:singleTagSearchSelection(title, tagSearchResults, settingValue)
    local menu_items = {}

    table.insert(menu_items, {
        text = "← Exit search",
        callback = function()
            self:goBack()
        end,
    })

    for __, tag in pairs(tagSearchResults) do
        table.insert(menu_items, {
            text_func = function()
                local show_checked = self.filter[settingValue] == tag.name
                if show_checked then
                    return "✓ " .. tag.name
                else
                    return tag.name
                end
            end,
            callback = function()
                self.filter[settingValue] = tag.name
                self:goBack()
            end,
        })
    end

    self.menuWidget:GoDownInMenu(title, menu_items)
end

function CustomFilterMenu:show(menuWidget, fanfic)
    self.menuWidget = menuWidget
    self.fanfic = fanfic

    self.menuWidget:GoDownInMenu("Select filter", self:refreshMainMenu())
end

function CustomFilterMenu:refreshMainMenu()
    local menuOptions = {
        {
            text = "+ Create new filter",
            callback = function()
                CustomFilterMenu:FilterCrafter()
            end,
        },
    }
    local filters = Config:readSetting("saved_filters", {})
    if #filters > 0 then
        table.insert(menuOptions, {
            text = "Saved filters:",
        })
    end
    for __, filter in pairs(filters) do
        table.insert(menuOptions, {
            text = "     " .. filter.title,
            callback = function()
                local optionsDialog
                optionsDialog = ButtonDialog:new({
                    buttons = {
                        {
                            {
                                text = "Search using filter",
                                callback = function()
                                    self.filter = filter.parameters
                                    self:executeSearch()
                                    UIManager:close(optionsDialog)
                                end,
                            },
                        },
                        {
                            {
                                text = "Edit filter",
                                callback = function()
                                    self:UpdateFilterCrafter(filter)
                                    UIManager:close(optionsDialog)
                                end,
                            },
                        },
                        {
                            {
                                text = "Delete filter",
                                callback = function()
                                    self.filter = filter.parameters
                                    local filters = Config:readSetting("saved_filters")
                                    filters[filter.title] = nil
                                    Config:saveSetting("saved_filters", filters)
                                    self.menuWidget.item_table = self:refreshMainMenu()
                                    self.menuWidget:updateItems()
                                    UIManager:close(optionsDialog)
                                end,
                            },
                        },
                        {
                            {
                                text = "Cancel",
                                callback = function()
                                    UIManager:close(optionsDialog)
                                end,
                            },
                        },
                    },
                })
                UIManager:show(optionsDialog)
            end,
        })
    end
    return menuOptions
end

function CustomFilterMenu:FilterCrafter()
    -- Initialize filter options
    self.filter = {
        main_tag = nil,
        completion_status = nil,
        crossovers = nil,
        single_chapter = nil,
        word_count = nil,
        language_id = nil,
        date_from = nil,
        date_to = nil,
        fandoms = nil,
        exclude_fandoms = nil,
        rating = nil,
        exclude_rating = nil,
        warnings = nil,
        exclude_warnings = nil,
        categories = nil,
        exclude_categories = nil,
        characters = nil,
        exclude_characters = nil,
        relationships = nil,
        exclude_relationships = nil,
        additional_tags = nil,
        exclude_additional_tags = nil,
        hits = nil,
        kudos = nil,
        comments = nil,
        bookmarks = nil,
        sort_by = nil,
        sort_direction = nil,
    }

    local filterMenuOptions = {
        {
            text_func = function()
                return "Main tag (Required): " .. (self.filter["main_tag"] or "None")
            end,
            callback = function()
                self:selectMainTag()
            end,
        },
        {
            text = "Work Info filters \u{23F5}",
            callback = function()
                self:WorkInfoSubmenu()
            end,
        },
        {
            text = "Work Tags filters \u{23F5}",
            callback = function()
                self:WorkTagsSubmenu()
            end,
        },
        {
            text = "Work Stats filters \u{23F5}",
            callback = function()
                self:WorkStatSubmenu()
            end,
        },
        {
            text = "Search Order filters \u{23F5}",
            callback = function()
                self:WorkOrderSubmenu()
            end,
        },
        {
            text = "\u{2193} Save current filter",
            callback = function()
                self:SaveFilters()
            end,
        },
        {
            text = "\u{f002} Execute Search",
            callback = function()
                self:executeSearch()
            end,
        },
    }

    self.menuWidget:GoDownInMenu("Create filter", filterMenuOptions)
end

function CustomFilterMenu:UpdateFilterCrafter(filter)
    self.filter = deepcopy(filter.parameters)
    local filterMenuOptions = {
        {
            text_func = function()
                return "Main tag (Required): " .. (self.filter["main_tag"] or "None")
            end,
            callback = function()
                self:selectMainTag()
            end,
        },
        {
            text = "Work Info filters \u{23F5}",
            callback = function()
                self:WorkInfoSubmenu()
            end,
        },
        {
            text = "Work Tags filters \u{23F5}",
            callback = function()
                self:WorkTagsSubmenu()
            end,
        },
        {
            text = "Work Stats filters \u{23F5}",
            callback = function()
                self:WorkStatSubmenu()
            end,
        },
        {
            text = "Search Order filters \u{23F5}",
            callback = function()
                self:WorkOrderSubmenu()
            end,
        },
        {
            text = "\u{2193} Save as current filter",
            callback = function()
                local optionsDialog
                optionsDialog = ButtonDialog:new({
                    title = "Do you want to overwrite the filter '" .. filter.title .. "' ?",
                    buttons = {
                        {
                            {
                                text = "Cancel",

                                callback = function()
                                    UIManager:close(optionsDialog)
                                end,
                            },
                            {
                                text = "Overwrite",
                                callback = function()
                                    UIManager:close(optionsDialog)
                                    self:OverwriteFilter(filter)
                                end,
                            },
                        },
                    },
                })
                UIManager:show(optionsDialog)
            end,
        },
        {
            text = "\u{2193} Save as new filter",
            callback = function()
                self:SaveFilters()
            end,
        },
        {
            text = "\u{f002} Execute Search",
            callback = function()
                self:executeSearch()
            end,
        },
    }

    self.menuWidget:GoDownInMenu("Edit filter: " .. filter.title, filterMenuOptions)
end

function CustomFilterMenu:selectMainTag()
    self:singleTagSelection("Select main tag", "", "main_tag")
end

function CustomFilterMenu:OverwriteFilter(filter)
    local filters = Config:readSetting("saved_filters", {})


    filters[filter.title] =  { title = filter.title, parameters = self.filter }
    Config:saveSetting("saved_filters", filters)
    UIManager:show(InfoMessage:new({
        text = 'Filter "' .. filter.title .. '" has been overwritten',
    }))
    self.menuWidget:updateMenuBack(1, nil, CustomFilterMenu:refreshMainMenu(), nil)
end

function CustomFilterMenu:SaveFilters()
    local inputDialog
    inputDialog = InputDialog:new({
        title = "Enter title to save filter under",
        input = "",
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
                        local value = inputDialog:getInputText()
                        if value == "" then
                            return
                        end


                        local filters = Config:readSetting("saved_filters", {})
                        local alreadyUsed = filters[value]

                        if alreadyUsed then
                            UIManager:show(InfoMessage:new({
                                text = 'Title "' .. value .. '" is already being used, enter different title',
                            }))
                            return
                        end

                        local newFilter = { title = value, parameters = self.filter }
                        filters[newFilter.title] = newFilter
                        Config:saveSetting("saved_filters", filters)
                        UIManager:show(InfoMessage:new({
                            text = 'Filter "' .. value .. '" has been saved',
                        }))
                        self:goBack()
                        self:UpdateFilterCrafter(newFilter)
                        UIManager:close(inputDialog)
                        self.menuWidget:updateMenuBack(1, nil, CustomFilterMenu:refreshMainMenu(), nil)
                    end,
                },
            },
        },
    })
    UIManager:show(inputDialog)
    inputDialog:onShowKeyboard()
end

function CustomFilterMenu:WorkTagsSubmenu()
    local menu_items = {
        {
            text_func = function()
                local fandomStrings = {}

                if self.filter.fandom_names then
                    for __, fandom in pairs(self.filter.fandom_names) do
                        table.insert(fandomStrings, fandom)
                    end
                end

                if self.filter.exclude_fandom_names then
                    for __, fandom in pairs(self.filter.exclude_fandom_names) do
                        table.insert(fandomStrings, "-" .. fandom)
                    end
                end
                return "Fandoms: " .. ((#fandomStrings > 0) and table.concat(fandomStrings, ", ") or "Any")
            end,
            callback = function()
                self:selectedFandoms()
            end,
        },
        {
            text_func = function()
                local key_to_rating = {
                    ["9"] = "not rated",
                    ["10"] = "general audiences",
                    ["11"] = "teen and up audiences",
                    ["12"] = "mature",
                    ["13"] = "explicit",
                }

                return "Rating: " .. (key_to_rating[self.filter.rating] or "Any")
            end,
            callback = function()
                self:selectRating()
            end,
        },
        {
            text_func = function()
                local key_to_warnings = {
                    ["14"] = "Creator Choose Not To Use Archive Warnings",
                    ["17"] = "Graphic Depictions Of Violence",
                    ["18"] = "Major Character Death",
                    ["16"] = "No Archive Warnings Apply",
                    ["19"] = "Rape/Non-Con",
                    ["20"] = "Underage Sex",
                }
                local warningStrings = {}
                if self.filter.warnings then
                    for __, warning in pairs(self.filter.warnings) do
                        table.insert(warningStrings, key_to_warnings[warning] or "")
                    end
                end

                if self.filter.exclude_warnings then
                    for __, warning in pairs(self.filter.exclude_warnings) do
                        table.insert(warningStrings, ("-" .. key_to_warnings[warning]) or "")
                    end
                end
                return "Warnings: " .. ((#warningStrings > 0) and table.concat(warningStrings, ", ") or "Any")
            end,

            callback = function()
                self:selectWarnings()
            end,
        },
        {
            text_func = function()
                local key_to_catagory = {
                    ["116"] = "F/F",
                    ["22"] = "F/M",
                    ["21"] = "Gen",
                    ["23"] = "M/M",
                    ["2246"] = "Multi",
                    ["24"] = "Other",
                }

                local catagoryStrings = {}

                if self.filter.categories then
                    for __, catagory in pairs(self.filter.categories) do
                        table.insert(catagoryStrings, key_to_catagory[catagory])
                    end
                end

                if self.filter.exclude_categories then
                    for __, catagory in pairs(self.filter.exclude_categories) do
                        table.insert(catagoryStrings, "-" .. key_to_catagory[catagory])
                    end
                end
                logger.dbg(catagoryStrings)
                return "Catagories: " .. ((#catagoryStrings > 0) and table.concat(catagoryStrings, ", ") or "Any")
            end,
            callback = function()
                self:selectCatagories()
            end,
        },
        {
            text_func = function()
                local characterStrings = {}

                if self.filter.characters then
                    for __, character in pairs(self.filter.characters) do
                        table.insert(characterStrings, character)
                    end
                end

                if self.filter.exclude_characters then
                    for __, character in pairs(self.filter.exclude_characters) do
                        table.insert(characterStrings, "-" .. character)
                    end
                end
                logger.dbg(characterStrings)
                return "Characters: " .. ((#characterStrings > 0) and table.concat(characterStrings, ", ") or "Any")
            end,
            callback = function()
                self:selectCharacters()
            end,
        },
        {
            text_func = function()
                local relationshipStrings = {}

                if self.filter.relationships then
                    for __, relationship in pairs(self.filter.relationships) do
                        table.insert(relationshipStrings, relationship)
                    end
                end

                if self.filter.exclude_relationships then
                    for __, relationship in pairs(self.filter.exclude_relationships) do
                        table.insert(relationshipStrings, "-" .. relationship)
                    end
                end
                return "Relationships: "
                    .. ((#relationshipStrings > 0) and table.concat(relationshipStrings, ", ") or "Any")
            end,
            callback = function()
                self:selectRelationships()
            end,
        },
        {
            text_func = function()
                local freemformStrings = {}

                if self.filter.additional_tags then
                    for __, tag in pairs(self.filter.additional_tags) do
                        table.insert(freemformStrings, tag)
                    end
                end

                if self.filter.exclude_additional_tags then
                    for __, tag in pairs(self.filter.additional_tags) do
                        table.insert(freemformStrings, "-" .. tag)
                    end
                end
                return "Additional Tags: "
                    .. ((#freemformStrings > 0) and table.concat(freemformStrings, ", ") or "Any")
            end,
            callback = function()
                self:selectAdditionalTags()
            end,
        },
    }
    self.menuWidget:GoDownInMenu("Create filter: Work Tags", menu_items)
end

function CustomFilterMenu:WorkInfoSubmenu()
    local menu_items = {
        {
            text_func = function()
                local key_to_completion = {
                    ["T"] = "Complete works only",
                    ["F"] = "Works in progress only",
                }

                return "Completion status: " .. (key_to_completion[self.filter.completion_status] or "All works")
            end,
            callback = function()
                self:selectCompletionStatus()
            end,
        },
        {
            text_func = function()
                local key_to_crossovers = {
                    ["F"] = "Exclude crossovers",
                    ["T"] = "Only crossovers",
                }

                return "Crossovers: " .. (key_to_crossovers[self.filter.crossovers] or "Include crossovers")
            end,
            callback = function()
                self:selectCrossovers()
            end,
        },
        {
            text_func = function()
                return "Single Chapter: " .. (self.filter.single_chapter and "Single chapter works only" or "All works")
            end,
            callback = function()
                self:selectSingleChapter()
            end,
        },
        {
            text_func = function()
                return "Word Count: " .. (self.filter.word_count or "Any")
            end,
            callback = function()
                self:selectWordCount()
            end,
        },
        {
            text_func = function()
                return "Language: " .. (self.filter.language_id or "Any")
            end,
            callback = function()
                self:selectLanguage()
            end,
        },
        {
            text_func = function()
                return "Date Updated from: " .. (self.filter.date_from or "Any")
            end,
            callback = function()
                self:selectDateFrom()
            end,
        },
        {
            text_func = function()
                return "Date Updated to: " .. (self.filter.date_to or "Any")
            end,
            callback = function()
                self:selectDateTo()
            end,
        },
    }
    self.menuWidget:GoDownInMenu("Create filter: Work Info", menu_items)
end

function CustomFilterMenu:WorkStatSubmenu()
    local menu_items = {
        {
            text_func = function()
                return "Hits: " .. (self.filter.hits or "any amount")
            end,
            callback = function()
                self:selectHits()
            end,
        },
        {
            text_func = function()
                return "Kudos: " .. (self.filter.kudos or "any amount")
            end,
            callback = function()
                self:selectKudos()
            end,
        },
        {
            text_func = function()
                return "Comments: " .. (self.filter.comments or "any amount")
            end,
            callback = function()
                self:selectWordCount()
            end,
        },
        {
            text_func = function()
                return "Bookmarks: " .. (self.filter.bookmarks or "any amount")
            end,
            callback = function()
                self:selectWordCount()
            end,
        },
    }
    self.menuWidget:GoDownInMenu("Create filter: Work Stats", menu_items)
end

function CustomFilterMenu:WorkOrderSubmenu()
    local menu_items = {
        {
            text_func = function()
                local key_to_sort = {
                    ["authors_to_sort_on"] = "Author",
                    ["title_to_sort_on"] = "Title",
                    ["created_at"] = "Date Posted",
                    ["revised_at"] = "Date Updated",
                    ["word_count"] = "Word Count",
                    ["hits"] = "Hits",
                    ["kudos_count"] = "Kudos",
                    ["comments_count"] = "Comments",
                    ["bookmarks_count"] = "Bookmarks",
                }

                return "Sort By: " .. (key_to_sort[self.filter.sort_by] or "Date Updated")
            end,
            callback = function()
                self:selectSortBy()
            end,
        },
        {
            text_func = function()
                local key_to_direction = {
                    ["asc"] = "Ascending",
                    ["desc"] = "Descending",
                }

                return "Sort by: " .. (key_to_direction[self.filter.sort_direction] or "Descending")
            end,
            callback = function()
                self:selectSortDirection()
            end,
        },
    }
    self.menuWidget:GoDownInMenu("Create filter: Search Order", menu_items)
end

function CustomFilterMenu:selectCompletionStatus()
    local title = "Select Completion Status"

    local options = {
        {
            text = "All works",
            value = nil,
        },
        {
            text = "Complete works only",
            value = "T",
        },
        {
            text = "Works in progress only",
            value = "F",
        },
    }

    local setting = "completion_status"

    self:selectionWidget(title, options, setting)
end

function CustomFilterMenu:selectCrossovers()
    local title = "Select Crossover filter"

    local options = {
        {
            text = "Include crossovers",
            value = nil,
        },
        {
            text = "Exclude crossovers",
            value = "F",
        },
        {
            text = "Only crossovers",
            value = "T",
        },
    }

    local setting = "crossovers"

    self:selectionWidget(title, options, setting)
end

function CustomFilterMenu:selectSingleChapter()
    local title = "Select chapter count filter"

    local options = {
        {
            text = "All works",
            value = nil,
        },
        {
            text = "Single chapter works only",
            value = "1",
        },
    }

    local setting = "single_chapter"

    self:selectionWidget(title, options, setting)
end

function CustomFilterMenu:selectRating()
    local title = "Select Rating"

    local options = {
        {
            text = "Any",
            value = nil,
        },
        {
            text = "Not Rated",
            value = "9",
        },
        {
            text = "General Audiences",
            value = "10",
        },
        {
            text = "Teen and Up Audiences",
            value = "1q",
        },
        {
            text = "Mature",
            value = "12",
        },
        {
            text = "Explicit",
            value = "13",
        },
    }

    local setting = "rating"

    self:selectionWidget(title, options, setting)
end

function CustomFilterMenu:selectWordCount()
    local title = "Enter Word Count Range (amount or <amount or >amount or min-max)"
    local setting = "word_count"
    self:textboxWidget(title, setting)
end

function CustomFilterMenu:selectLanguage()
    local title = "Enter language id (eg en for English, es for Spanish)"
    local setting = "language_id"
    self:textboxWidget(title, setting)
end

function CustomFilterMenu:selectDateFrom()
    local title = "Enter date updated from (YYYY-MM-DD)"
    local setting = "date_from"
    self:textboxWidget(title, setting)
end

function CustomFilterMenu:selectDateTo()
    local title = "Enter date updated to (YYYY-MM-DD)"
    local setting = "date_to"
    self:textboxWidget(title, setting)
end

function CustomFilterMenu:selectedFandoms()
    self:tagSelectionWidget("Select Fandoms", "Fandom", "fandom_names")
end

function CustomFilterMenu:selectWarnings()
    local title = "Select warnings"
    local menu_items = {
        {
            text = "Creator Choose Not To Use Archive Warnings",
            value = "14",
        },
        {
            text = "Graphic Depictions Of Violence",
            value = "17",
        },
        {
            text = "Major Character Death",
            value = "18",
        },
        {
            text = "No Archive Warnings Apply",
            value = "16",
        },
        {
            text = "Rape/Non-Con",
            value = "19",
        },
        {
            text = "Underage Sex",
            value = "20",
        },
    }

    local setting = "warnings"
    self:checkboxWidget(title, menu_items, setting)
end

function CustomFilterMenu:selectCatagories()
    local title = "Select catagories"
    local options = {
        {
            text = "F/F",
            value = "116",
        },
        {
            text = "F/M",
            value = "22",
        },
        {
            text = "Gen",
            value = "21",
        },
        {
            text = "M/M",
            value = "23",
        },
        {
            text = "Multi",
            value = "2246",
        },
        {
            text = "Other",
            value = "24",
        },
    }
    local setting = "categories"
    self:checkboxWidget(title, options, setting)
end

function CustomFilterMenu:selectCharacters()
    self:tagSelectionWidget("Select character tags", "Character", "characters")
end

function CustomFilterMenu:selectRelationships()
    self:tagSelectionWidget("Select Relationship tags", "Relationship", "relationships")
end

function CustomFilterMenu:selectAdditionalTags()
    self:tagSelectionWidget("Select Additional tags", "Freeform", "additional_tags")
end

function CustomFilterMenu:selectHits()
    local title = "Enter Hits Range (amount or <amount or >amount or min-max)"
    local setting = "hits"
    self:textboxWidget(title, setting)
end

function CustomFilterMenu:selectKudos()
    local title = "Enter Kudos Range (amount or <amount or >amount or min-max)"
    local setting = "kudos"
    self:textboxWidget(title, setting)
end

function CustomFilterMenu:selectComments()
    local title = "Enter Comment Count Range (amount or <amount or >amount or min-max)"
    local setting = "comments"
    self:textboxWidget(title, setting)
end

function CustomFilterMenu:selectBookmarks()
    local title = "Enter Bookmark Count Range (amount or <amount or >amount or min-max)"
    local setting = "bookmarks"
    self:textboxWidget(title, setting)
end

function CustomFilterMenu:selectSortBy()
    local title = "Select value to sort by"
    local options = {
        {
            text = "Author",
            value = "authors_to_sort_on",
        },
        {
            text = "Title",
            value = "title_to_sort_on",
        },
        {
            text = "Date posted",
            value = "created_at",
        },
        {
            text = "Date Updated",
            value = "revised_at",
        },
        {
            text = "Word Count",
            value = "word_count",
        },
        {
            text = "Hits",
            value = "hits",
        },
        {
            text = "Kudos",
            value = "kudos_count",
        },
        {
            text = "Comments",
            value = "comment_count",
        },
        {
            text = "Bookmarks",
            value = "bookmarks_count",
        },
    }
    local setting = "sort_by"
    self:selectionWidget(title, options, setting)
end

function CustomFilterMenu:selectSortDirection()
    local title = "Select sort direction"
    local options = {
        {
            text = "Ascending",
            value = "asc",
        },
        {
            text = "Descending",
            value = "desc",
        },
    }
    local setting = "sort_direction"
    self:selectionWidget(title, options, setting)
end

-- Execute the search with the crafted filter
function CustomFilterMenu:executeSearch()
    if not self.filter.main_tag then
        UIManager:show(InfoMessage:new({
            text = _("Main tag is required"),
        }))
        return
    end
    UIManager:scheduleIn(1, function()
        local parameters = {
            ["work_search[complete]"] = self.filter.completion_status or nil,
            ["work_search[crossover]"] = self.filter.crossovers or nil,
            ["work_search[single_chapter]"] = self.filter.single_chapter or nil,
            ["work_search[word_count]"] = self.filter.word_count or nil,
            ["work_search[language_id]"] = self.filter.language_id or nil,
            ["work_search[date_from]"] = self.filter.date_from or nil,
            ["work_search[date_to]"] = self.filter.date_to or nil,
            ["work_search[fandom_names]"] = self.filter.fandom_names and table.concat(self.filter.fandom_names, ",")
                or nil,
            ["work_search[rating_ids]"] = self.filter.rating or nil,
            ["work_search[archive_warning_ids][]"] = self.filter.warnings or nil,
            ["exclude_work_search[archive_warning_ids][]"] = self.filter.exclude_warnings or nil,
            ["work_search[category_ids][]"] = self.filter.categories or nil,
            ["exclude_work_search[category_ids][]"] = self.filter.exclude_categories or nil,
            ["work_search[character_names]"] = self.filter.characters and table.concat(self.filter.characters, ",")
                or nil,
            ["work_search[relationship_names]"] = self.filter.relationships
                and table.concat(self.filter.relationships, ",")
                or nil,
            ["work_search[freeform_names]"] = self.filter.additional_tags
                and table.concat(self.filter.additional_tags, ",")
                or nil,
            ["work_search[hits]"] = self.filter.hits or nil,
            ["work_search[kudos_count]"] = self.filter.kudos or nil,
            ["work_search[comments_count]"] = self.filter.comments or nil,
            ["work_search[bookmarks_count]"] = self.filter.bookmarks or nil,
            ["work_search[sort_column]"] = self.filter.sort_by or nil,
            ["work_search[sort_direction]"] = self.filter.sort_direction or nil,
            ["tag_id"] = self.filter.main_tag or nil,
            ["work_search[excluded_tag_names]"] = table.concat({
                self.filter.exclude_fandom_names and table.concat(self.filter.exclude_fandom_names, ",") or "",
                self.filter.exclude_characters and table.concat(self.filter.exclude_characters, ",") or "",
                self.filter.exclude_relationships and table.concat(self.filter.exclude_relationships, ",") or "",
                self.filter.exclude_additional_tags and table.concat(self.filter.exclude_additional_tags, ",") or "",
            }, ","),
        }
        local success, ficResults, fetchNextPage = self.fanfic:executeSearch(parameters)

        if not success then
            UIManager:show(InfoMessage:new({
                text = _("Failed to fetch results for the custom filter."),
                timeout = 2,
            }))
            return
        end

        -- Show the results in the FanficBrowser
        FanficBrowser:show(
            self.fanfic.ui,
            self.menuWidget,
            ficResults,
            fetchNextPage,
            function(fanfic)
                self.fanfic:UpdateFanfic(fanfic)
            end, -- Update callback
            function(fanficId, parentMenu)
                self.fanfic:DownloadFanfic(fanficId, parentMenu)
            end -- Download callback
        )
    end)

    UIManager:show(InfoMessage:new({
        text = _("Searching with custom filter..."),
        timeout = 1,
    }))
end

return CustomFilterMenu
