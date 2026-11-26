
local DataStorage = require("datastorage")
local logger = require("logger")
local DownloadedFanfics = require("downloaded_fanfics")
local util = require("util")
local Paths = require("FanficPaths")

local config_instance = nil

local function createConfig()
    local config = {}

    config.default_settings = {
        AO3_domain = "https://archiveofourown.org",
        show_adult_warning = true,
        version = 1,
        bookmarkedFandoms = {
            "原神 | Genshin Impact (Video Game)",
            "Miraculous Ladybug",
            "Marvel Cinematic Universe",
            "Star Wars - All Media Types",
        },
        filename_template = "%I",
        fanfic_folder_path = Paths.getHomeDirectory() .. "/Downloads",
        show_current_chapter = true
    }

    function config:init()
        if not util.fileExists(DataStorage:getSettingsDir() .. "/fanfic.lua") then
            self:setup()
        end

        if self:readSetting("version") == nil then
            self:updateSettingsFile_1()
        end
    end

    function config:setup()
        util.makePath(Paths:getHomeDirectory())
        util.makePath(Paths:getHomeDirectory().."/Downloads/")
    end

    function config:updateSettingsFile_1()
        -- update filter menu
        local filter_set = config:readSetting("saved_filters", {} )
        local new_filter_set = {}

        for __, filter in pairs(filter_set) do
            logger.dbg(filter)
            new_filter_set[filter.title] = filter
        end

        config:saveSetting("saved_filters", new_filter_set)

        -- update chapter menu
        DownloadedFanfics.updateDownloadFile_1()
        config:saveSetting("version", 1)

    end

    function config:readSetting(key, default)
        local settings = require("luasettings"):open(DataStorage:getSettingsDir() .. "/fanfic.lua")

        default =  default or config.default_settings[key]

        -- no flush: reads must not write
        return settings:readSetting(key, default)
    end

    function config:saveSetting(key, default)
        local settings = require("luasettings"):open(DataStorage:getSettingsDir() .. "/fanfic.lua")
        settings:saveSetting(key, default)
        settings:close()
    end

    -- Removes value from the stored list setting if present, otherwise appends it; returns true when added.
    function config:toggleInSetting(key, value)
        local list = self:readSetting(key, {})
        local index = util.arrayContains(list, value)
        if index then
            table.remove(list, index)
        else
            table.insert(list, value)
        end
        self:saveSetting(key, list)
        return not index
    end

    function config:getAO3Domain()
        return self:readSetting("AO3_domain")
    end

    return config

end

-- Return the singleton instance
return (function()
    if not config_instance then
        config_instance = createConfig()
        config_instance:init()
    end
    return config_instance
end)()
