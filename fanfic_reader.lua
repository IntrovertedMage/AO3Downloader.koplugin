local ReaderUI = require("apps/reader/readerui")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local Event = require("ui/event")

--- @class FanficReader
--- This is a singleton that contains a simpler interface with ReaderUI.
local FanficReader = {
  on_return_callback = nil,
  on_end_of_book_callback = nil,
  is_showing = false,
  current_fanfic = nil,
  current_chapter = nil,
}

--- @class FanficReaderOptions
--- @field fanfic_path string Path to the file to be displayed.
--- @field on_return_callback fun(): nil Function to be called when the user selects "Go back to Rakuyomi".
--- @field on_end_of_book_callback fun(): nil Function to be called when the user reaches the end of the file.
--- @field current_fanfic table: nil A table that contains all the data of the fanfic that is being open
--- @field chapter_opening_at integer: nil

--- Displays the file located in `path` in the KOReader's reader.
--- If a file is already being displayed, it will be replaced.
---
--- @param options FanficReaderOptions
function FanficReader:show(options)
  self.on_return_callback = options.on_return_callback
  self.on_end_of_book_callback = options.on_end_of_book_callback

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

--- @param ui unknown The `ReaderUI` instance we're being called from.
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


--- @private
--- @param ui unknown The currently active `ReaderUI` instance.
function FanficReader:hookWithPriorityOntoReaderUiEvents(ui)
  -- We need to reorder the `ReaderUI` children such that we are the first children,
  -- in order to receive events before all other widgets
  assert(ui.name == "ReaderUI", "expected to be inside ReaderUI")

  local eventListener = WidgetContainer:new({})
  eventListener.onEndOfBook = function()
    -- FIXME this makes `self:onEndOfBook()` get called twice if it does not
    -- return true in the first invocation...
    return self:onEndOfBook()
  end
  eventListener.onCloseWidget = function()
    self:onReaderUiCloseWidget()
  end
  eventListener.onPageUpdate = function(__ ,pageno)
    self:onPageUpdate(pageno)
  end
  eventListener.onReaderReady = function()
    self:onReaderReady()
  end

  table.insert(ui, 2, eventListener)
end

--- Used to add the "Go back to Rakuyomi" menu item. Is called from `ReaderUI`, via the
--- `registerToMainMenu` call done in `initializeFromReaderUI`.
--- @private
function FanficReader:addToMainMenu(menu_items)
  menu_items.go_back_to_fanfic_downloader = {
    text = "Go back to fanfic downloader...",
    sorting_hint = "main",
    callback = function()
      -- self:onReturn()
    end
  }
end

--- @private
function FanficReader:onReturn()
  self:closeReaderUi(function()
    self.on_return_callback()
  end)
end

function FanficReader:closeReaderUi(done_callback)
  -- Let all event handlers run before closing the ReaderUI, because
  -- some stuff might break if we just remove it ASAP
  UIManager:nextTick(function()
    local FileManager = require("apps/filemanager/filemanager")

    -- we **have** to reopen the `FileManager`, because
    -- apparently this is the only way to get out of the `ReaderUI` without shit
    -- completely breaking (koreader really does not like when there's no `ReaderUI`
    -- nor `FileManager`)
    ReaderUI.instance:onClose()
    if FileManager.instance then
      FileManager.instance:reinit()
    else
      FileManager:showFiles()
    end

    -- (done_callback or function() end)()
  end)
end

--- To be called when the last page of the manga is read.
function FanficReader:onEndOfBook()
  if self.is_showing then
    logger.info("Got end of book")

    -- self.on_end_of_book_callback()
    return true
  end
end

function FanficReader:onPageUpdate(pageno)
    if self.is_showing then
        logger.dbg("page number uwu")
        logger.dbg(pageno)
        if ReaderUI.instance  and #self.current_fanfic.chapter_data ~= 0 then
            local chapter_index = ReaderUI.instance.toc:getTocIndexByPage(pageno)
            if chapter_index ~= 1 then
                logger.dbg("current chapter:" .. tostring(self.current_fanfic.chapter_data[chapter_index - 1].name))
            end
        end
    end

end

--- @private
function FanficReader:onReaderUiCloseWidget()
  self.is_showing = false
end

return FanficReader
