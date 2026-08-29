local Device = require("device")
local InputDialog = require("ui/widget/inputdialog")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Font = require("ui/font")
local InputText = require("ui/widget/inputtext")
local Size = require("ui/size")
local CheckButton = require("ui/widget/checkbutton")
local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")

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
    self.bookmark_notes_field = self._input_widget
    self.bookmark_notes_field:setText(self.bookmark_notes_original or "")
    self.bookmark_notes_field.callback = function(self)
        self:setModified()
    end


    self.bookmark_tags_field = InputText:new {
        width = self.width - Size.padding.default - Size.border.inputtext - 30,
        text = self.bookmark_tags_original,
        focused = false,
        show_parent = self,
        parent = self,
        hint = "Enter tags separated by commas",
        face = Font:getFace("cfont", 16),

        callback = function(self, text)
            self:setModified()
        end
    }

    self.bookmark_collections_field = InputText:new {
        width = self.width - Size.padding.default - Size.border.inputtext - 30,
        text = self.bookmark_collections_original,
        focused = false,
        show_parent = self,
        parent = self,
        hint = "Enter collections separated by commas",
        face = Font:getFace("cfont", 16),

        callback = function(self, text)
            self:setModified()
        end
    }

    self.bookmark_private_field = CheckButton:new {
        text = "Private",
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
    self:addWidget(self.bookmark_collections_field)
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
