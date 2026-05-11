describe("PluginLoader", function()
    local DataStorage, PluginLoader, ffiUtil, util
    local test_dir

    local function path(name)
        return test_dir .. "/" .. name
    end

    setup(function()
        require("commonrequire")
        DataStorage = require("datastorage")
        PluginLoader = require("pluginloader")
        ffiUtil = require("ffi/util")
        util = require("util")
    end)

    before_each(function()
        test_dir = DataStorage:getDataDir() .. "/pluginloader_spec"
        ffiUtil.purgeDir(test_dir)
        assert.is_true(util.makePath(test_dir))
        PluginLoader.enabled_plugins = {}
        PluginLoader.disabled_plugins = {}
        PluginLoader.loaded_plugins = {}
        PluginLoader.loaded_plugin_info = {}
        PluginLoader.all_plugins = nil
        PluginLoader.show_info = false
        G_reader_settings:saveSetting("plugins_disabled", {})
    end)

    after_each(function()
        ffiUtil.purgeDir(test_dir)
        PluginLoader.enabled_plugins = nil
        PluginLoader.disabled_plugins = nil
        PluginLoader.loaded_plugins = nil
        PluginLoader.loaded_plugin_info = nil
        PluginLoader.all_plugins = nil
        PluginLoader.show_info = true
        G_reader_settings:saveSetting("plugins_disabled", {})
    end)

    it("disables plugins by stable directory key, not display name", function()
        PluginLoader.all_plugins = {
            {
                name = "internal_name",
                plugin_key = "folder-key",
                fullname = "Plugin display name",
                description = "",
                enable = true,
            },
        }

        local menu = PluginLoader:genPluginManagerSubItem()
        assert.are.equal("Plugin display name", menu[1].text)

        menu[1].callback()

        local plugins_disabled = G_reader_settings:readSetting("plugins_disabled")
        assert.is_true(plugins_disabled["folder-key"])
        assert.is_nil(plugins_disabled["internal_name"])
    end)

    it("keeps disabled plugins manageable when _meta.lua is missing", function()
        local plugin_path = path("folder-key.koplugin")
        assert.is_true(util.makePath(plugin_path))
        local fp = assert(io.open(plugin_path .. "/main.lua", "w"))
        fp:write("return { name = 'internal_name', description = 'Loaded only when enabled' }")
        fp:close()

        PluginLoader:_load({
            {
                main = plugin_path .. "/_meta.lua",
                meta = plugin_path .. "/_meta.lua",
                path = plugin_path,
                disabled = true,
                name = "folder-key.koplugin",
                plugin_key = "folder-key",
            },
        })

        assert.are.equal(1, #PluginLoader.disabled_plugins)
        assert.are.equal("folder-key", PluginLoader.disabled_plugins[1].name)
        assert.are.equal("folder-key", PluginLoader.disabled_plugins[1].plugin_key)
    end)

    it("keeps path metadata for loaded plugin instances", function()
        local plugin = {
            name = "internal_name",
            plugin_key = "folder-key",
            path = path("folder-key.koplugin"),
            new = function()
                return {}
            end,
        }

        local ok = PluginLoader:createPluginInstance(plugin, {})

        assert.is_true(ok)
        assert.is_table(PluginLoader.loaded_plugins.internal_name)
        assert.are.equal("folder-key", PluginLoader.loaded_plugin_info.internal_name.plugin_key)
        assert.are.equal(path("folder-key.koplugin"), PluginLoader.loaded_plugin_info.internal_name.path)

        PluginLoader:finalize()

        assert.are.same({}, PluginLoader.loaded_plugins)
        assert.are.same({}, PluginLoader.loaded_plugin_info)
    end)

    it("preserves live plugin tracking when rediscovering plugins", function()
        local running_instance = {}
        PluginLoader.enabled_plugins = nil
        PluginLoader.disabled_plugins = nil
        PluginLoader.loaded_plugins = {
            internal_name = running_instance,
        }
        PluginLoader.loaded_plugin_info = {
            internal_name = {
                name = "internal_name",
                plugin_key = "folder-key",
                path = path("folder-key.koplugin"),
            },
        }
        local old_discover = PluginLoader._discover
        PluginLoader._discover = function()
            return {}
        end

        local ok, err = pcall(function()
            PluginLoader:loadPlugins()
        end)
        PluginLoader._discover = old_discover

        assert.is_true(ok, err)
        assert.are.same(running_instance, PluginLoader.loaded_plugins.internal_name)
        assert.are.equal("folder-key", PluginLoader.loaded_plugin_info.internal_name.plugin_key)
    end)
end)
