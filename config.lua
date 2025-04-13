
local DataStorage = require("datastorage")
local logger = require("logger")

local config_instance = nil

local function createConfig()
    local config = {}

    config.default_settings = {
        AO3_domain = "https://archiveofourown.org"
    }

    function config:init()
        self.settings = require("luasettings"):open(DataStorage:getSettingsDir() .. "/fanfic.lua")
        if next(self.settings.data) == nil then
            self.updated = true -- first run, force flush
        end
        self.settings:readSetting("AO3_domain", self.default_settings.AO3_domain)
        self.settings:readSetting("bookmarkedFandoms", self.defaultFandoms)
        self:onFlushSettings()
    end

    function config:readSetting(key, default)
        local setting = self.settings:readSetting(key, default)
        self.updated = true
        self:onFlushSettings()
        return setting
    end

    function config:saveSetting(key, default)
        self.settings:saveSetting(key, default)
        self.updated = true
        self:onFlushSettings()
    end

    function config:getFandoms()
        local fandoms = self.settings:readSetting("bookmarkedFandoms", {})
        return fandoms
    end


    config.defaultFandoms = {
        [1] = "原神 | Genshin Impact (Video Game)",
        [2] = "Miraculous Ladybug",
        [3] = "Marvel Cinematic Universe",
        [4] = "Star Wars - All Media Types",
    }


    function config:onFlushSettings()
        if self and self.updated then
            self.settings:flush()
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
