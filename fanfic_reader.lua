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
local FanficBookmarkDialog = require("fanfic_bookmark_dialog")
local logger = require("logger")

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
                                        text = "Error: " .. request_result.error .. (self.current_fanfic.subscriptionID or ""),
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

                                local request_result = AO3DownloaderClient:getUsersWorkBookmark(self.current_fanfic.id)
                                if  request_result.success then
                                    self.current_fanfic.bookmarkContent = request_result.bookmark_data

                                    if request_result.bookmark_id then
                                        self.current_fanfic.bookmarkID = request_result.bookmark_id
                                    else
                                        self.current_fanfic.bookmarkID = false
                                    end
                                    DownloadedFanfics.update(self.current_fanfic, false)

                                else
                                    local info_message = InfoMessage:new({
                                        text = "Error: " .. request_result.error,
                                    })
                                    info_message[1].ignore = "height"
                                    UIManager:show(info_message)
                                end


                                local fanficBookmark_dialog =  FanficBookmarkDialog:new({
                                    current_fanfic = self.current_fanfic,
                                    bookmark_notes_original = self.current_fanfic.bookmarkContent and self.current_fanfic.bookmarkContent.notes or nil,
                                    bookmark_tags_original = self.current_fanfic.bookmarkContent and self.current_fanfic.bookmarkContent.tags or nil,
                                    bookmark_collections_original = self.current_fanfic.bookmarkContent and self.current_fanfic.bookmarkContent.collections or nil,
                                    bookmark_private = self.current_fanfic.bookmarkContent and self.current_fanfic.bookmarkContent.private or false,
                                    bookmark_rec = self.current_fanfic.bookmarkContent and self.current_fanfic.bookmarkContent.rec or false,
                                    save_dialog_callback = function(bookmark_data)
                                        local request_result = AO3DownloaderClient:updateBookmark(
                                            self.current_fanfic.id,
                                            self.current_fanfic.bookmarkID,
                                            bookmark_data.notes,
                                            bookmark_data.tags,
                                            bookmark_data.collections,
                                            bookmark_data.private,
                                            bookmark_data.rec
                                        )

                                        if request_result.success then
                                            local originalBMID = self.current_fanfic.bookmarkID

                                            self.current_fanfic.bookmarkContent = bookmark_data

                                            if request_result.bookmark_id then
                                                self.current_fanfic.bookmarkID = request_result.bookmark_id
                                            else
                                                self.current_fanfic.bookmarkID = false
                                            end
                                            DownloadedFanfics.update(self.current_fanfic, false)

                                            UIManager:show(InfoMessage:new({
                                                text = originalBMID and "Updated Bookmark" or "Created Bookmark",
                                            }))
                                            return true
                                        else
                                            UIManager:show(InfoMessage:new({
                                                text = "Error: " .. request_result.error,
                                            }))
                                            return false
                                        end

                                    end,
                                    delete_dialog_callback = function(bookmark_data)
                                        local request_result = AO3DownloaderClient:deleteBookmark(self.current_fanfic.bookmarkID)

                                        if request_result.success then
                                            self.current_fanfic.bookmarkID = false
                                            self.current_fanfic.bookmarkContent = {}
                                            DownloadedFanfics.update(self.current_fanfic, false)

                                            UIManager:show(InfoMessage:new({
                                                text = "Deleted Bookmark",
                                            }))
                                            return true
                                        else
                                            UIManager:show(InfoMessage:new({
                                                text = "Error: " .. request_result.error,
                                            }))
                                            return false
                                        end

                                    end,

                                })
                                fanficBookmark_dialog.close_widget_callback = function()
                                    UIManager:close(fanficBookmark_dialog)
                                end
                                UIManager:show(fanficBookmark_dialog)
                                fanficBookmark_dialog:onShowKeyboard()

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
