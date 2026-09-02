local Device = require("device")
local InputDialog = require("ui/widget/inputdialog")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Font = require("ui/font")
local InputText = require("ui/widget/inputtext")
local Size = require("ui/size")
local CheckButton = require("ui/widget/checkbutton")
local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local logger = require("logger")
local Button = require("ui/widget/button")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local AO3DownloaderClient = require("AO3_downloader_client")
local _ = require("gettext")

local FanficBookmarkDialog = InputDialog:extend{
    title = "Bookmark Fanfic",
    allow_newline = true,
    results = {},
    padding = 10,

    current_fanfic = nil,

    bookmark_notes_original = nil,
    bookmark_tags_original = nil,
    bookmark_collections_original = nil,

    bookmark_private = false,
    bookmark_rec = false,

    bookmark_notes_field = nil,
    bookmark_tags_field = nil,
    bookmark_collections_field = nil,
    bookmark_private_field = nil,
    bookmark_rec_field = nil,


    save_bookmark_callback = nil,
    delete_bookmark_callback = nil,
    close_widget_callback = nil,

}



function FanficBookmarkDialog:init()

    local text_widget = TextBoxWidget:new{
        text = "l\n\nj",
        face = Font:getFace("cfont", 16),
        for_measurement_only = true,

    }

    self.text_height = text_widget:getTextHeight()

    self.save_bookmark_callback = function()
        return self.save_dialog_callback({
            notes = self.bookmark_notes_field:getText(),
            tags = self.bookmark_tags_field:getText(),
            collections = self.bookmark_collections_field:getText(),
            private = self.bookmark_private,
            rec = self.bookmark_rec,
        })
    end

    self.delete_bookmark_callback = function()
        return self.delete_dialog_callback({
            notes = self.bookmark_notes_field:getText(),
            tags = self.bookmark_tags_field:getText(),
            collections = self.bookmark_collections_field:getText(),
            private = self.bookmark_private,
            rec = self.bookmark_rec,
        })
    end

    local buttons = {}

    table.insert(buttons, {
        text = self.current_fanfic.bookmarkID and "Update" or "Create",
        id = "save",
        is_enter_default = true,
        callback = function()
            if self.save_bookmark_callback then
                local result = self.save_bookmark_callback()
                if result then
                    self.close_widget_callback()
                end
            end
        end
    })

    if self.current_fanfic.bookmarkID then
        table.insert(buttons, {
            text = "Delete",
            id = "delete",
            callback = function()
                local confirmDialog
                confirmDialog = ButtonDialog:new{
                    title = "Are you sure you want to delete this bookmark?",
                    buttons = { {
                        {
                            text = "Yes",
                            is_enter_default = true,
                            callback = function()
                                if self.delete_bookmark_callback then
                                    local result = self.delete_bookmark_callback()
                                    if result then
                                        self.close_widget_callback()
                                    end
                                end
                                UIManager:close(confirmDialog)
                            end
                        },
                        {
                            text = "No",
                            id = "close",
                            callback = function()
                                UIManager:close(confirmDialog)
                            end
                        },
                    }
                    }
                }
                UIManager:show(confirmDialog)
            end
        })
    end

    table.insert(buttons, {
        text = "Cancel",
        id = "close",
        callback = function()
            self.close_widget_callback()
        end
    })

    self.buttons = { { }}
    self.buttons[1] = buttons
    InputDialog.init(self)

    if self.current_fanfic.bookmarkID then
        self.button_table:getButtonById("save"):disable()
        self:refreshButtons()
    end

    self.bookmark_notes_field = self._input_widget
    self.bookmark_notes_field:setText(self.bookmark_notes_original or "")
    self.bookmark_notes_field.edit_callback = function(is_edited)
        if is_edited then
            self:setModified()
        end
    end


    self.bookmark_tags_field = InputText:new {
        width = self.width - Size.padding.default - Size.border.inputtext - 30,
        text = self.bookmark_tags_original,
        focused = false,
        show_parent = self,
        parent = self,
        hint = "Enter tags separated by commas \n",
        face = Font:getFace("cfont", 16),

        edit_callback = function(is_edited)
            if is_edited then
                self:setModified()
            end
        end
    }

    self.bookmark_collections_field = InputText:new {
        width = ((self.width - 30) / 5) * 4 - Size.padding.default - Size.border.inputtext,
        text = self.bookmark_collections_original,
        focused = false,
        show_parent = self,
        parent = self,
        hint = "Use search button or enter collection ids split by commas",
        face = Font:getFace("cfont", 16),
        edit_callback = function(is_edited)
            if is_edited then
                self:setModified()
            end
        end
    }

    -- Create search button for collections
    local search_button = Button:new{
        text = "\u{f002}",
        width = ((self.width - 30) / 5),
        callback = function()
            self:collectionSearchWidget()
        end,
        show_parent = self,
    }

    -- Create horizontal group with collections field and search button
    local collections_group = HorizontalGroup:new{
        self.bookmark_collections_field,
        search_button,
    }

    self.bookmark_private_field = CheckButton:new {
        text = "Private",
        width = self.width - 30,
        checked = self.bookmark_private,
        show_parent = self,
        parent = self,
        check = self.bookmark_private,
        face = Font:getFace("cfont", 16),

        callback = function()
            self.bookmark_private = self.bookmark_private_field.checked
            self:setModified()
        end
    }

    self.bookmark_rec_field = CheckButton:new {
        text = "Rec",
        width = self.width - 30,
        checked = self.bookmark_rec,
        show_parent = self,
        parent = self,
        check = self.bookmark_rec,
        face = Font:getFace("cfont", 16),

        callback = function()
            self.bookmark_rec = self.bookmark_rec_field.checked
            self:setModified()
        end
    }

    self:addWidget(self.bookmark_tags_field)
    self:addWidget(collections_group)
    self:addWidget(self.bookmark_private_field)
    self:addWidget(self.bookmark_rec_field)

end

function FanficBookmarkDialog:onConfigChoose()
    UIManager:tickAfterNext(function()
        UIManager:setDirty(self.dialog, "ui")
    end)
end


function FanficBookmarkDialog:setModified()
    if self.input then
        self._text_modified = true
        if self.button_table then
            self.button_table:getButtonById("save"):enable()
            self:refreshButtons()
        end
    end
end

function FanficBookmarkDialog:getCollectionsFromField()
    local collections_text = self.bookmark_collections_field:getText()
    local collections = {}
    if collections_text and collections_text ~= "" then
        for collection in collections_text:gmatch("[^,]+") do
            table.insert(collections, collection:match("^%s*(.-)%s*$"))  -- Trim whitespace
        end
    end
    return collections
end

function FanficBookmarkDialog:updateCollectionsField(collections)
    local collections_text = table.concat(collections, ", ")
    self.bookmark_collections_field:setText(collections_text)
    self:setModified()
end

function FanficBookmarkDialog:collectionSearchWidget()
    self:onCloseKeyboard()

    local inputDialog
    inputDialog = InputDialog:new({
        title = "Search for Collections",
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
                        local success, request_result = pcall(function()
                            return AO3DownloaderClient:searchForCollections(value)
                        end)
                        if success and request_result.success then
                            self:collectionSearchSelectionWidget(
                                "Select collections to add",
                                request_result.collections
                            )
                            inputDialog:onCloseKeyboard()
                            UIManager:close(inputDialog)
                        else
                            UIManager:show(require("ui/widget/infomessage"):new({
                                text = "Error searching collections: " .. (request_result and request_result.error or "Unknown error"),
                            }))
                        end
                    end,
                },
            },
        },
    })
    UIManager:show(inputDialog)
    inputDialog:onShowKeyboard()
end

function FanficBookmarkDialog:collectionSearchSelectionWidget(title, collection_results)
    if not collection_results or #collection_results == 0 then
        UIManager:show(require("ui/widget/infomessage"):new({
            text = "No collections found.",
        }))
        return
    end

    local current_collections = self:getCollectionsFromField()
    local buttons = {}

    -- Back button
    table.insert(buttons, {
        {
            text = "← Back to Search",
            callback = function()
                if self.collection_dialog then
                    UIManager:close(self.collection_dialog)
                end
                self:collectionSearchWidget()
            end,
        },
    })

    -- Create buttons for each collection (up to 5 per row)
    local row = {}
    for __, collection in pairs(collection_results) do
        local collection_name = collection.name

        local collection_id = collection.name:match("^(.-):")
        local is_selected = false

        for _, selected_col in ipairs(current_collections) do
            if selected_col == collection_id then
                is_selected = true
                break
            end
        end

        local button_text = is_selected and "✓ " .. collection_name or collection_name

        table.insert(row, {
            text = button_text,
            callback = function()
                local collections = self:getCollectionsFromField()
                local found = false

                -- Toggle selection
                for i, col in ipairs(collections) do
                    if col == collection_id then
                        table.remove(collections, i)
                        found = true
                        break
                    end
                end

                if not found then
                    table.insert(collections, collection_id)
                end

                self:updateCollectionsField(collections)

                -- Refresh dialog
                if self.collection_dialog then
                    UIManager:close(self.collection_dialog)
                end
                self:collectionSearchSelectionWidget(title, collection_results)
            end,
        })

        -- Start a new row after 2 buttons
        if #row >= 2 then
            table.insert(buttons, row)
            row = {}
        end
    end

    -- Add remaining buttons
    if #row > 0 then
        table.insert(buttons, row)
    end

    self.collection_dialog = ButtonDialog:new{
        title = title,
        buttons = buttons,
    }

    UIManager:show(self.collection_dialog)
end

-- copied from MultiInputDialog
function FanficBookmarkDialog:onSwitchFocus(inputbox)
      -- unfocus current inputbox
  self._input_widget:unfocus()
  -- and close its existing keyboard (via InputDialog's thin wrapper around _input_widget's own method)
  self:onCloseKeyboard()

  UIManager:setDirty(nil, function()
    return "ui", self.dialog_frame.dimen
  end)

  -- focus new inputbox
  self._input_widget = inputbox
  self._input_widget:focus()
  self.focused_field_idx = inputbox.idx

  if (Device:hasKeyboard() or Device:hasScreenKB()) and G_reader_settings:isFalse("virtual_keyboard_enabled") then
    -- do not load virtual keyboard when user is hiding it.
    return
  end
  -- Otherwise make sure we have a (new) visible keyboard
  self:onShowKeyboard()
end


return FanficBookmarkDialog
