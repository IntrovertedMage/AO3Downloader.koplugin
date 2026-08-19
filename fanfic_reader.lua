-- Based upon code found in rakuyomi.koplugin maintained by hanatsumi , https://github.com/hanatsumi/rakuyomi
local ReaderUI = require("apps/reader/readerui")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Event = require("ui/event")
local Notification = require("ui/widget/notification")
local DownloadedFanfics = require("downloaded_fanfics")
local AO3DownloaderClient = require("AO3_downloader_client")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")

local FFIUtil = require("ffi/util")
local T = FFIUtil.template

local FanficReader = {
    on_return_callback = nil,
    on_end_of_book_callback = nil,
    is_showing = false,
    current_fanfic = nil,
    current_chapter = nil,
}

function FanficReader:show(options)
    self.current_fanfic = options.current_fanfic

    if self.is_showing then
        -- if we're showing, just switch the document
        ReaderUI.instance:switchDocument(options.fanfic_path)
    else
        -- took this from opds reader
        local Event = require("ui/event")
        UIManager:broadcastEvent(Event:new("SetupShowReader"))

        ReaderUI:showReader(options.fanfic_path)
    end

    self.chapter_opening_at = options.chapter_opening_at
    self.is_showing = true
end

function FanficReader:addToMainMenu(menu_items)
    local function showCommentDialog(chapter_index)
        local chapter = self.current_fanfic.chapter_data and self.current_fanfic.chapter_data[chapter_index]
        local chapter_id = chapter and chapter.id or nil
        self.input_dialog = InputDialog:new({
            title = "Type out your comment:",
            input = "",
            input_type = "text",
            allow_newline = true,
            buttons = {
                {
                    {
                        text = "Cancel",
                        id = "close",
                        callback = function()
                            UIManager:close(self.input_dialog)
                        end,
                    },
                    {
                        text = "Comment",
                        is_enter_default = true,
                        callback = function()
                            local NetworkMgr = require("ui/network/manager")

                            if not NetworkMgr:isConnected() then
                                NetworkMgr:runWhenConnected()
                                return
                            end

                            if self.input_dialog:getInputText() == "" then
                                return
                            end
                            local request_result = AO3DownloaderClient:commentOnWork(
                                self.input_dialog:getInputText(),
                                self.current_fanfic.id,
                                chapter_id
                            )
                            if request_result.success then
                                UIManager:show(InfoMessage:new({
                                    text = "Successfuly commented on work",
                                }))
                                UIManager:close(self.input_dialog)
                                return
                            end

                            UIManager:show(InfoMessage:new({
                                text = "Error: " .. request_result.error,
                            }))
                        end,
                    },
                },
            },
        })
        UIManager:show(self.input_dialog)
        self.input_dialog:onShowKeyboard()
    end

    menu_items.AO3_manage_work = {
        text = "Manage work",
        sorting_hint = "main",
        keep_menu_open = false,
        callback = function()
            local dialog
            dialog = ButtonDialog:new({
                title = T("Options for '%1'", self.current_fanfic.title),
                buttons = { 
                {
                    {
                        text = self.current_fanfic.markedForLater and "Mark as read" or "Mark for later",
                        callback = function()
                            local NetworkMgr = require("ui/network/manager")

                            if not NetworkMgr:isConnected() then
                                NetworkMgr:runWhenConnected()
                                return
                            end

                            local request_result = AO3DownloaderClient:markForLaterWork(self.current_fanfic.id,
                                self.current_fanfic.markedForLater)

                            self.current_fanfic.markedForLater = not self.current_fanfic.markedForLater
                            DownloadedFanfics.update(self.current_fanfic, false)

                            if request_result.success then
                                UIManager:show(InfoMessage:new({
                                    text = self.current_fanfic.markedForLater and "Fanfic Marked for Later" or
                                        "Fanfic Marked as Read",
                                }))
                            else
                                UIManager:show(InfoMessage:new({
                                    text = "Error: " .. request_result.error,
                                }))
                            end

                            UIManager:close(dialog)
                        end,
                    }
                    },
                    {
                        {
                            text = self.current_fanfic.subscriptionID and "Unsubscribe from work" or "Subscribe to work",
                            callback = function()
                                local NetworkMgr = require("ui/network/manager")

                                if not NetworkMgr:isConnected() then
                                    NetworkMgr:runWhenConnected()
                                    return
                                end

                                local request_result = AO3DownloaderClient:setWorkSubscription(self.current_fanfic.id,
                                    self.current_fanfic.subscriptionID)
                                if request_result.success then
                                    if request_result.subscription_id then
                                        self.current_fanfic.subscriptionID = request_result.subscription_id
                                    else
                                        self.current_fanfic.subscriptionID = false
                                    end
                                    DownloadedFanfics.update(self.current_fanfic, false)

                                    UIManager:show(InfoMessage:new({
                                        text = self.current_fanfic.subscriptionID and "Subscribed to Fanfic" or
                                        "Unsubscribed from Fanfic",
                                    }))
                                else
                                    UIManager:show(InfoMessage:new({
                                        text = "Error: " .. request_result.error .. self.current_fanfic.subscriptionID,
                                    }))
                                end

                                UIManager:close(dialog)
                            end,
                        }
                    },
                    {
                        {
                            text = self.current_fanfic.bookmarkID and "Edit Bookmark" or "Bookmark Work",
                            callback = function ()
                                local NetworkMgr = require("ui/network/manager")
                                if not NetworkMgr:isConnected() then
                                    NetworkMgr:runWhenConnected()
                                    return
                                end

                                local bookmark_input
                                local bookmarkContent = {notes="",tags="",collections=""}

                                local buttons = {
                                    {
                                        text = "Cancel",
                                        id = "close",
                                        callback = function()
                                            UIManager:close(bookmark_input)
                                        end
                                    },
                                    {
                                        text = self.current_fanfic.bookmarkID and "Update" or "Create",
                                        callback = function()
                                            local fields = bookmark_input:getFields()
                                            bookmarkContent.private = fields[1] == "y" or fields[1] == "Y"
                                            bookmarkContent.rec = fields[2] == "y" or fields[2] == "Y"

                                            local request_result = AO3DownloaderClient:updateBookmark(
                                                self.current_fanfic.id,
                                                self.current_fanfic.bookmarkID,
                                                bookmarkContent.notes,
                                                bookmarkContent.tags,
                                                bookmarkContent.collections,
                                                bookmarkContent.private,
                                                bookmarkContent.rec
                                            )

                                            if request_result.success then
                                                local originalBMID = self.current_fanfic.bookmarkID

                                                self.current_fanfic.bookmarkContent = bookmarkContent

                                                if request_result.bookmark_id then
                                                    self.current_fanfic.bookmarkID = request_result.bookmark_id
                                                end
                                                DownloadedFanfics.update(self.current_fanfic, false)

                                                UIManager:show(InfoMessage:new({
                                                    text = originalBMID and "Updated Bookmark" or "Created Bookmark",
                                                }))
                                            else
                                                UIManager:show(InfoMessage:new({
                                                    text = "Error: " .. request_result.error,
                                                }))
                                            end

                                            UIManager:close(bookmark_input)
                                        end
                                    }
                                }

                                if self.current_fanfic.bookmarkID then
                                    table.insert(buttons, {
                                        text = "Delete",
                                        callback = function()
                                            local confirmDialog
                                            -- Confirm deletion
                                            confirmDialog = ButtonDialog:new({
                                                title = "Are you sure you want to delete this bookmark?",
                                                buttons = {
                                                    {
                                                        {
                                                            text = "Delete",
                                                            callback = function()
                                                                local request_result = AO3DownloaderClient:deleteBookmark(self.current_fanfic.bookmarkID)

                                                                if request_result.success then
                                                                    self.current_fanfic.bookmarkID = false
                                                                    self.current_fanfic.bookmarkContent = {}
                                                                    DownloadedFanfics.update(self.current_fanfic, false)

                                                                    UIManager:show(InfoMessage:new({
                                                                        text = "Deleted Bookmark",
                                                                    }))
                                                                else
                                                                    UIManager:show(InfoMessage:new({
                                                                        text = "Error: " .. request_result.error,
                                                                    }))
                                                                end

                                                                UIManager:close(confirmDialog)
                                                                UIManager:close(bookmark_input)
                                                            end,
                                                        },
                                                        {
                                                            text = "Cancel",
                                                            callback = function()
                                                                UIManager:close(confirmDialog)
                                                            end,
                                                        },
                                                    },
                                                },
                                            })
                                            UIManager:show(confirmDialog)
                                        end
                                    })
                                    if self.current_fanfic.bookmarkContent then
                                        for k, v in pairs(self.current_fanfic.bookmarkContent) do
                                            bookmarkContent[k] = v
                                        end
                                    end
                                end

                                bookmark_input = MultiInputDialog:new {
                                    title = self.current_fanfic.bookmarkID and "Update existing bookmark" or "Save a bookmark!",
                                    fields = {
                                        {
                                            hint = "Y/N",
                                            text = self.current_fanfic.bookmarkContent and (self.current_fanfic.bookmarkContent.private and "Y" or "N") or nil,
                                            description = "Private bookmark"
                                        },
                                        {
                                            hint = "Y/N",
                                            text = self.current_fanfic.bookmarkContent and (self.current_fanfic.bookmarkContent.rec and "Y" or "N") or nil,
                                            description = "Rec"
                                        },
                                    },
                                    buttons = {
                                        {
                                            {
                                                text = "Edit Notes",
                                                callback = function()
                                                    local notes_input
                                                    notes_input = InputDialog:new {
                                                        title = "Notes",
                                                        input = bookmarkContent.notes or nil,
                                                        fullscreen = true,
                                                        condensed = true,
                                                        allow_newline = true,
                                                        add_scroll_buttons = true,
                                                        buttons = {
                                                            {
                                                                {
                                                                    text = "\u{f00d}",
                                                                    id = "close",
                                                                    callback = function()
                                                                        UIManager:close(notes_input)
                                                                    end,
                                                                },
                                                                {
                                                                    text = "\u{f00c}",
                                                                    callback = function()
                                                                        bookmarkContent.notes = notes_input:getInputText()
                                                                        UIManager:close(notes_input)
                                                                    end,
                                                                },
                                                            }
                                                        },
                                                    }
                                                    UIManager:show(notes_input)
                                                    notes_input:onShowKeyboard()
                                                end
                                            },
                                        },
                                        {
                                            {
                                                text = "Edit Tags",
                                                callback = function()
                                                    local tags_input
                                                    tags_input = InputDialog:new {
                                                        title = "Your tags (Comma Seperated)",
                                                        input = bookmarkContent.tags or nil,
                                                        fullscreen = true,
                                                        condensed = true,
                                                        add_scroll_buttons = true,
                                                        buttons = {
                                                            {
                                                                {
                                                                    text = "\u{f00d}",
                                                                    id = "close",
                                                                    callback = function()
                                                                        UIManager:close(tags_input)
                                                                    end,
                                                                },
                                                                {
                                                                    text = "\u{f00c}",
                                                                    callback = function()
                                                                        bookmarkContent.tags = tags_input:getInputText()
                                                                        UIManager:close(tags_input)
                                                                    end,
                                                                },
                                                            }
                                                        },
                                                    }
                                                    UIManager:show(tags_input)
                                                    tags_input:onShowKeyboard()
                                                end
                                            },
                                            {
                                                text = "Edit Collections",
                                                callback = function()
                                                    local collections_input
                                                    collections_input = InputDialog:new {
                                                        title = "Add to collections (Comma Seperated)",
                                                        input = bookmarkContent.collections or nil,
                                                        fullscreen = true,
                                                        condensed = true,
                                                        add_scroll_buttons = true,
                                                        buttons = {
                                                            {
                                                                {
                                                                    text = "\u{f00d}",
                                                                    id = "close",
                                                                    callback = function()
                                                                        UIManager:close(collections_input)
                                                                    end,
                                                                },
                                                                {
                                                                    text = "\u{f00c}",
                                                                    callback = function()
                                                                        bookmarkContent.collections = collections_input:getInputText()
                                                                        UIManager:close(collections_input)
                                                                    end,
                                                                },
                                                            }
                                                        },
                                                    }
                                                    UIManager:show(collections_input)
                                                    collections_input:onShowKeyboard()
                                                end
                                            }
                                        },
                                        buttons
                                    },
                                }
                                UIManager:show(bookmark_input)
                                bookmark_input:onShowKeyboard()

                                UIManager:close(dialog)

                            end
                        }
                    }
                },
            })
            UIManager:show(dialog)
        end
    }
    menu_items.AO3_downloader_kudos_work = {
        text = "Give kudos to work ♥",
        sorting_hint = "main",
        keep_menu_open = true,
        callback = function()
            local NetworkMgr = require("ui/network/manager")

            if not NetworkMgr:isConnected() then
                NetworkMgr:runWhenConnected()
                return
            end

            local request_result = AO3DownloaderClient:kudosWork(self.current_fanfic.id)

            if request_result.success then
                UIManager:show(InfoMessage:new({
                    text = "Thank you for leaving kudos!",
                }))
                return
            end

            UIManager:show(InfoMessage:new({
                text = "Error: " .. request_result.error,
            }))
        end,
    }

    menu_items.AO3_downloader_comment_work = {
        text = "Comment on work",
        sorting_hint = "main",
        keep_menu_open = true,
    }

    if self.current_fanfic.chapter_data and #self.current_fanfic.chapter_data > 0 then
        local chapter_menu_options = {}
        for idx, chapter in pairs(self.current_fanfic.chapter_data) do
            local option = {
                text = chapter.name,
                callback = function()
                    showCommentDialog(idx)
                end,
                keep_menu_open = true,
            }
            table.insert(chapter_menu_options, option)
        end
        menu_items.AO3_downloader_comment_work.sub_item_table = chapter_menu_options
    else
        menu_items.AO3_downloader_comment_work.callback = function()
            showCommentDialog(nil)
        end
    end

end

function FanficReader:initializeFromReaderUI(ui)
    if self.is_showing then
        ui.menu:registerToMainMenu(FanficReader)
    end

    ui:registerPostInitCallback(function()
        self:hookWithPriorityOntoReaderUiEvents(ui)
    end)
end

function FanficReader:onReaderReady()
    if self.is_showing then
        UIManager:nextTick(function()
            if self.chapter_opening_at then
                local toc = ReaderUI.instance.document:getToc()
                UIManager:broadcastEvent(Event:new("GotoPage", toc[self.chapter_opening_at + 1].page))
            end
        end)
    end
end

function FanficReader:hookWithPriorityOntoReaderUiEvents(ui)
    -- We need to reorder the `ReaderUI` children such that we are the first children,
    -- in order to receive events before all other widgets
    assert(ui.name == "ReaderUI", "expected to be inside ReaderUI")

    local eventListener = WidgetContainer:new({})
    eventListener.onCloseWidget = function()
        self:onReaderUiCloseWidget()
    end
    eventListener.onPageUpdate = function(__, pageno)
        self:onPageUpdate(pageno)
    end
    eventListener.onReaderReady = function()
        self:onReaderReady()
    end

    table.insert(ui, 2, eventListener)
end

function FanficReader:onFinishChapter(chapter_index)
    if not self.current_fanfic.chapter_data then
        return
    end
    if self.current_fanfic.chapter_data[chapter_index].read then
        return
    end

    UIManager:show(Notification:new({
        text = "Finished chapter: " .. tostring(self.current_fanfic.chapter_data[chapter_index].name),
    }))

    -- Update fanfic chapter read status
    self.current_fanfic = DownloadedFanfics.markChapterAsRead(self.current_fanfic.id, chapter_index)
end

function FanficReader:onFinishSingleChapterWork()
    if self.current_fanfic.read then
        return
    end

    UIManager:show(Notification:new({
        text = "Finished work: " .. tostring(self.current_fanfic.title),
    }))

    self.current_fanfic = DownloadedFanfics.markWorkAsRead(self.current_fanfic.id)
end

function FanficReader:onPageUpdate(pageno)
    if self.is_showing then
        if ReaderUI.instance then
            local logger = require("logger")
            logger.dbg(self.current_fanfic)
            if #self.current_fanfic.chapter_data ~= 0 then
                local document_chapter_index = ReaderUI.instance.toc:getTocIndexByPage(pageno)
                if
                    document_chapter_index > 1
                    and (document_chapter_index - 1) <= #self.current_fanfic.chapter_data
                    and ReaderUI.instance.toc:isChapterEnd(pageno)
                then
                    FanficReader:onFinishChapter(document_chapter_index - 1)
                end
            else
                local document_chapter_index = ReaderUI.instance.toc:getTocIndexByPage(pageno)
                if document_chapter_index == 2 and ReaderUI.instance.toc:isChapterEnd(pageno) then
                    FanficReader:onFinishSingleChapterWork()
                end
            end
        end
    end
end

--- @private
function FanficReader:onReaderUiCloseWidget()
    self.is_showing = false
end

return FanficReader
