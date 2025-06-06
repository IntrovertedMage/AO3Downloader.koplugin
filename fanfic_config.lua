
local DataStorage = require("datastorage")
local logger = require("logger")
local DownloadedFanfics = require("downloaded_fanfics")
local util = require("frontend/util")
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
        }

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
        self:setDefault()
    end

    function config:setDefault()
        local settings = require("luasettings"):open(DataStorage:getSettingsDir() .. "/fanfic.lua")
        for setting, value in pairs(self.default_settings) do
            settings:readSetting(setting, value)
        end
        self.updated = true
        self:onFlushSettings(settings)
        settings:close()
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
        local setting = settings:readSetting(key, default)
        self.updated = true
        self:onFlushSettings(settings)
        settings:close()
        return setting
    end

    function config:saveSetting(key, default)
        local settings = require("luasettings"):open(DataStorage:getSettingsDir() .. "/fanfic.lua")
        settings:saveSetting(key, default)
        self.updated = true
        self:onFlushSettings(settings)
        settings:close()
    end


    function config:onFlushSettings(settings)
        if self and self.updated then
            settings:flush()
            self.updated = nil
        end
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
