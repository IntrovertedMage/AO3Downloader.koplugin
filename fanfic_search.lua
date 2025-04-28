local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local FanficSearch = {}

function FanficSearch:show(parentMenu, onDownloadCallback)
    local fanfic_lookup_dialog
    fanfic_lookup_dialog = InputDialog:new{
        title = _("Enter AO3 fanfic id to download"),
        input = "",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(fanfic_lookup_dialog)
                    end,
                },
                {
                    text = _("Download"),
                    is_enter_default = true,
                    callback = function()
                        local inputText = fanfic_lookup_dialog:getInputText()
                        if inputText == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Error: No fanfic ID entered."),
                            })
                            return
                        end

                        UIManager:close(fanfic_lookup_dialog)
                        UIManager:show(InfoMessage:new{
                            text = _("Downloading fanfiction epub....")
                        })

                        -- Call the provided callback with the entered ID
                        onDownloadCallback(inputText)
                        UIManager:close(parentMenu)
                    end,
                },
            }
        },
    }

    UIManager:show(fanfic_lookup_dialog)
    fanfic_lookup_dialog:onShowKeyboard()
end

return FanficSearch
