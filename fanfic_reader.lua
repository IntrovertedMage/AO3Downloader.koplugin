-- Based upon code found in rakuyomi.koplugin maintained by hanatsumi , https://github.com/hanatsumi/rakuyomi
local ReaderUI = require("apps/reader/readerui")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Event = require("ui/event")
local Notification = require("ui/widget/notification")
local DownloadedFanfics = require("downloaded_fanfics")

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

function FanficReader:initializeFromReaderUI(ui)
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

function FanficReader:onFinishWork()
    UIManager:show(Notification:new({
        text = "Finished work: " .. tostring(self.current_fanfic.title),
    }))

    DownloadedFanfics.markWorkAsRead(self.current_fanfic.id)
end

function FanficReader:onPageUpdate(pageno)
    if self.is_showing then
        if ReaderUI.instance then
            if #self.current_fanfic.chapter_data ~= 0 then
                local document_chapter_index = ReaderUI.instance.toc:getTocIndexByPage(pageno)
                if document_chapter_index > 1 and (document_chapter_index - 1) <= #self.current_fanfic.chapter_data and ReaderUI.instance.toc:isChapterEnd(pageno) then
                    FanficReader:onFinishChapter(document_chapter_index - 1)
                end
            else
                local document_chapter_index = ReaderUI.instance.toc:getTocIndexByPage(pageno)
                if document_chapter_index == 2 and ReaderUI.instance.toc:isChapterEnd(pageno) then
                    FanficReader:onFinishWork(document_chapter_index - 1)
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
