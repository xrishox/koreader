describe("PluginPackageManager", function()
    local Archiver, DataStorage, PluginLoader, PluginPackageManager, ffiUtil, lfs, util
    local test_dir

    local function path(name)
        return test_dir .. "/" .. name
    end

    local function makeZip(name, entries)
        local zip_path = path(name)
        local writer = Archiver.Writer:new()
        assert.is_true(writer:open(zip_path, "zip"))
        assert.is_true(writer:setZipCompression("store"))
        for entry_path, content in pairs(entries) do
            assert.is_true(writer:addFileFromMemory(entry_path, content))
        end
        writer:close()
        return zip_path
    end

    local function makeZipFromPath(name, entry_root, root)
        local zip_path = path(name)
        local writer = Archiver.Writer:new()
        assert.is_true(writer:open(zip_path, "zip"))
        assert.is_true(writer:setZipCompression("store"))
        writer:addPath(entry_root, root, true)
        assert.is_nil(writer.err)
        writer:close()
        return zip_path
    end

    setup(function()
        require("commonrequire")
        Archiver = require("ffi/archiver")
        DataStorage = require("datastorage")
        PluginLoader = require("pluginloader")
        PluginPackageManager = require("pluginpackagemanager")
        ffiUtil = require("ffi/util")
        lfs = require("libs/libkoreader-lfs")
        util = require("util")
    end)

    before_each(function()
        test_dir = DataStorage:getDataDir() .. "/pluginpackagemanager_spec"
        ffiUtil.purgeDir(test_dir)
        assert.is_true(util.makePath(test_dir))
        PluginLoader.enabled_plugins = nil
        PluginLoader.disabled_plugins = nil
        PluginLoader.loaded_plugins = nil
        PluginLoader.loaded_plugin_info = nil
        PluginLoader.all_plugins = nil
        G_reader_settings:saveSetting("plugins_disabled", {})
        G_reader_settings:saveSetting("plugins_pending_removal", {})
    end)

    after_each(function()
        ffiUtil.purgeDir(test_dir)
        PluginLoader.enabled_plugins = nil
        PluginLoader.disabled_plugins = nil
        PluginLoader.loaded_plugins = nil
        PluginLoader.loaded_plugin_info = nil
        PluginLoader.all_plugins = nil
        G_reader_settings:saveSetting("plugins_disabled", {})
        G_reader_settings:saveSetting("plugins_pending_removal", {})
    end)

    it("installs a zip with a top-level .koplugin directory", function()
        local zip_path = makeZip("package.zip", {
            ["specroot.koplugin/main.lua"] = "return {}",
            ["specroot.koplugin/_meta.lua"] = "return {}",
        })

        local ok, plan = PluginPackageManager:installZip(zip_path, { plugin_dir = path("plugins") })

        assert.is_true(ok)
        assert.are.equal("specroot.koplugin", plan.plugin_name)
        assert.are.equal("file", lfs.attributes(path("plugins/specroot.koplugin/main.lua"), "mode"))
    end)

    it("installs a flat zip under a plugin name derived from the zip filename", function()
        local zip_path = makeZip("Simple UI.zip", {
            ["main.lua"] = "return {}",
            ["sub/module.lua"] = "return {}",
        })

        local ok, plan = PluginPackageManager:installZip(zip_path, { plugin_dir = path("plugins") })

        assert.is_true(ok)
        assert.are.equal("Simple_UI.koplugin", plan.plugin_name)
        assert.are.equal("file", lfs.attributes(path("plugins/Simple_UI.koplugin/main.lua"), "mode"))
        assert.are.equal("file", lfs.attributes(path("plugins/Simple_UI.koplugin/sub/module.lua"), "mode"))
    end)

    it("installs a zip with a single source wrapper directory", function()
        local zip_path = makeZip("Storyteller-Koreader-Plugin-main.zip", {
            ["Storyteller-Koreader-Plugin-main/README.md"] = "docs",
            ["Storyteller-Koreader-Plugin-main/main.lua"] = "return {}",
            ["Storyteller-Koreader-Plugin-main/st_api.lua"] = "return {}",
        })

        local ok, plan = PluginPackageManager:installZip(zip_path, { plugin_dir = path("plugins") })

        assert.is_true(ok)
        assert.are.equal("Storyteller-Koreader-Plugin-main.koplugin", plan.plugin_name)
        assert.are.equal("file", lfs.attributes(path("plugins/Storyteller-Koreader-Plugin-main.koplugin/main.lua"), "mode"))
        assert.are.equal("file", lfs.attributes(path("plugins/Storyteller-Koreader-Plugin-main.koplugin/st_api.lua"), "mode"))
    end)

    it("requires confirmation before replacing an existing user plugin", function()
        local zip_path = makeZip("replace.zip", {
            ["main.lua"] = "return { version = 1 }",
        })
        local plugin_dir = path("plugins")
        assert.is_true(PluginPackageManager:installZip(zip_path, { plugin_dir = plugin_dir }))

        local ok, err, plan = PluginPackageManager:installZip(zip_path, { plugin_dir = plugin_dir })
        assert.is_nil(ok)
        assert.are.equal("exists", err)
        assert.are.equal("replace.koplugin", plan.plugin_name)

        ok = PluginPackageManager:installZip(zip_path, { plugin_dir = plugin_dir, replace = true })
        assert.is_true(ok)
    end)

    it("preserves the custom plugin dir when confirming replacement", function()
        local zip_path = makeZip("custom-confirm-spec.zip", {
            ["main.lua"] = "return { version = 1 }",
        })
        local plugin_dir = path("plugins")
        local default_path = PluginPackageManager:getUserPluginPath("custom-confirm-spec.koplugin")
        ffiUtil.purgeDir(default_path)
        assert.is_true(PluginPackageManager:installZip(zip_path, { plugin_dir = plugin_dir }))

        local UIManager = require("ui/uimanager")
        local old_show = UIManager.show
        local old_ask_for_restart = UIManager.askForRestart
        local confirm_shown = false
        UIManager.show = function(_, widget)
            confirm_shown = true
            assert.is_function(widget.ok_callback)
            widget.ok_callback()
        end
        UIManager.askForRestart = function() end

        local ok, err = pcall(function()
            PluginPackageManager:installZipWithConfirmation(zip_path, { plugin_dir = plugin_dir })
        end)

        UIManager.show = old_show
        UIManager.askForRestart = old_ask_for_restart
        ffiUtil.purgeDir(default_path)
        assert.is_true(ok, err)
        assert.is_true(confirm_shown)
        assert.are.equal("file", lfs.attributes(plugin_dir .. "/custom-confirm-spec.koplugin/main.lua", "mode"))
    end)

    it("replaces plugins from staging and clears old disabled keys", function()
        local plugin_dir = path("plugins")
        local plugin_path = plugin_dir .. "/replace.koplugin"
        assert.is_true(util.makePath(plugin_path))
        local fp = assert(io.open(plugin_path .. "/main.lua", "w"))
        fp:write("return { name = 'old_internal_name' }")
        fp:close()
        G_reader_settings:saveSetting("plugins_disabled", {
            ["replace"] = true,
            old_internal_name = true,
            new_internal_name = true,
        })
        local zip_path = makeZip("replace.zip", {
            ["main.lua"] = "return { name = 'new_internal_name' }",
        })

        local ok = PluginPackageManager:installZip(zip_path, { plugin_dir = plugin_dir, replace = true })

        assert.is_true(ok)
        assert.are.equal("file", lfs.attributes(plugin_path .. "/main.lua", "mode"))
        assert.is_nil(lfs.attributes(plugin_path .. ".installing", "mode"))
        assert.is_nil(lfs.attributes(plugin_path .. ".replacing", "mode"))
        assert.is_nil(G_reader_settings:readSetting("plugins_disabled")["replace"])
        assert.is_nil(G_reader_settings:readSetting("plugins_disabled")["old_internal_name"])
        assert.is_nil(G_reader_settings:readSetting("plugins_disabled")["new_internal_name"])
    end)

    it("clears pending removal when a plugin is reinstalled before restart", function()
        local plugin_dir = path("plugins")
        local plugin_path = plugin_dir .. "/replace.koplugin"
        assert.is_true(util.makePath(plugin_path))
        local fp = assert(io.open(plugin_path .. "/main.lua", "w"))
        fp:write("return { name = 'old_internal_name' }")
        fp:close()
        G_reader_settings:saveSetting("plugins_pending_removal", {
            ["replace.koplugin"] = true,
        })
        local zip_path = makeZip("replace.zip", {
            ["main.lua"] = "return { name = 'new_internal_name' }",
        })

        local ok = PluginPackageManager:installZip(zip_path, { plugin_dir = plugin_dir, replace = true })

        assert.is_true(ok)
        assert.are.equal("file", lfs.attributes(plugin_path .. "/main.lua", "mode"))
        assert.is_nil(G_reader_settings:readSetting("plugins_pending_removal")["replace.koplugin"])
    end)

    it("rejects archives with multiple .koplugin roots", function()
        local zip_path = makeZip("multi.zip", {
            ["one.koplugin/main.lua"] = "return {}",
            ["two.koplugin/main.lua"] = "return {}",
        })

        local ok, err = PluginPackageManager:installZip(zip_path, { plugin_dir = path("plugins") })

        assert.is_nil(ok)
        assert.truthy(err:match("multiple"))
    end)

    it("rejects unsafe archive paths", function()
        local zip_path = makeZip("unsafe.zip", {
            ["main.lua"] = "return {}",
            ["../evil.lua"] = "return {}",
        })

        local ok, err = PluginPackageManager:installZip(zip_path, { plugin_dir = path("plugins") })

        assert.is_nil(ok)
        assert.truthy(err:match("unsafe"))
    end)

    it("rejects archives without main.lua", function()
        local zip_path = makeZip("missing-main.zip", {
            ["helper.lua"] = "return {}",
        })

        local ok, err = PluginPackageManager:installZip(zip_path, { plugin_dir = path("plugins") })

        assert.is_nil(ok)
        assert.truthy(err:match("main.lua"))
    end)

    it("rejects archives where main.lua is a directory", function()
        local main_dir = path("main-dir/main.lua")
        assert.is_true(util.makePath(main_dir))
        local fp = assert(io.open(main_dir .. "/helper.lua", "w"))
        fp:write("return {}")
        fp:close()
        local zip_path = makeZipFromPath("main-dir.zip", "main.lua", main_dir)

        local ok, err = PluginPackageManager:installZip(zip_path, { plugin_dir = path("plugins") })

        assert.is_nil(ok)
        assert.truthy(err:match("main.lua"))
    end)

    it("rejects unsafe plugin removal names", function()
        local plugin_dir = path("plugins")
        assert.is_true(util.makePath(plugin_dir .. "/remove-me.koplugin"))

        local ok, err = PluginPackageManager:removeUserPlugin("../remove-me.koplugin", { plugin_dir = plugin_dir })

        assert.is_nil(ok)
        assert.truthy(err:match("Invalid plugin name"))
        assert.are.equal("directory", lfs.attributes(plugin_dir .. "/remove-me.koplugin", "mode"))
    end)

    it("closes the remove menu before showing confirmation", function()
        local plugin_dir = PluginPackageManager:getUserPluginDir()
        local plugin_path = PluginPackageManager:getUserPluginPath("menu-remove.koplugin")
        ffiUtil.purgeDir(plugin_path)
        assert.is_true(util.makePath(plugin_path))

        local UIManager = require("ui/uimanager")
        local old_next_tick = UIManager.nextTick
        local old_show = UIManager.show
        local sequence = {}
        UIManager.nextTick = function(_, callback)
            table.insert(sequence, "nextTick")
            callback()
        end
        UIManager.show = function()
            table.insert(sequence, "show")
        end

        local menu = PluginPackageManager:genRemoveUserPluginMenu()

        for _, item in ipairs(menu) do
            if item.text == "menu-remove.koplugin" then
                assert.is_true(item.keep_menu_open)
                item.callback({
                    closeMenu = function()
                        table.insert(sequence, "close")
                    end,
                })
                UIManager.nextTick = old_next_tick
                UIManager.show = old_show
                ffiUtil.purgeDir(plugin_path)
                assert.are.same({ "close", "nextTick", "show" }, sequence)
                return
            end
        end
        UIManager.nextTick = old_next_tick
        UIManager.show = old_show
        error("menu-remove.koplugin not found in remove menu")
    end)

    it("removes user plugins and clears disabled state", function()
        local plugin_dir = path("plugins")
        assert.is_true(util.makePath(plugin_dir .. "/remove-me.koplugin"))
        local fp = assert(io.open(plugin_dir .. "/remove-me.koplugin/main.lua", "w"))
        fp:write("return { name = 'internal-remove-name' }")
        fp:close()
        G_reader_settings:saveSetting("plugins_disabled", {
            ["remove-me"] = true,
            ["internal-remove-name"] = true,
        })

        local ok = PluginPackageManager:removeUserPlugin("remove-me.koplugin", { plugin_dir = plugin_dir })

        assert.is_true(ok)
        assert.is_nil(lfs.attributes(plugin_dir .. "/remove-me.koplugin"))
        assert.is_nil(G_reader_settings:readSetting("plugins_disabled")["remove-me"])
        assert.is_nil(G_reader_settings:readSetting("plugins_disabled")["internal-remove-name"])
    end)

    it("defers active user plugin removal until restart", function()
        local plugin_dir = path("plugins")
        local plugin_path = plugin_dir .. "/active-plugin.koplugin"
        assert.is_true(util.makePath(plugin_path))
        local fp = assert(io.open(plugin_path .. "/main.lua", "w"))
        fp:write("return { name = 'active_internal_name' }")
        fp:close()
        PluginLoader.enabled_plugins = {
            {
                path = plugin_path,
                name = "active_internal_name",
                plugin_key = "active-plugin",
            },
        }
        local stopped = false
        PluginLoader.loaded_plugins = {
            active_internal_name = {
                stopPlugin = function(_, force)
                    assert.is_nil(force)
                    stopped = true
                    return true
                end,
            },
        }
        G_reader_settings:saveSetting("plugins_disabled", {
            ["active-plugin"] = true,
            active_internal_name = true,
        })

        local ok, err = PluginPackageManager:removeUserPlugin("active-plugin.koplugin", { plugin_dir = plugin_dir })

        assert.is_nil(ok)
        assert.truthy(err:match("currently active"))
        assert.is_false(stopped)
        assert.are.equal("directory", lfs.attributes(plugin_path, "mode"))
        assert.is_true(G_reader_settings:readSetting("plugins_disabled")["active-plugin"])
        assert.is_true(G_reader_settings:readSetting("plugins_disabled")["active_internal_name"])
        assert.is_true(G_reader_settings:readSetting("plugins_pending_removal")["active-plugin.koplugin"])
    end)

    it("does not purge active user plugins without a stop hook", function()
        local plugin_dir = path("plugins")
        local plugin_path = plugin_dir .. "/active-plugin.koplugin"
        assert.is_true(util.makePath(plugin_path))
        local fp = assert(io.open(plugin_path .. "/main.lua", "w"))
        fp:write("return { name = 'active_internal_name' }")
        fp:close()
        PluginLoader.loaded_plugins = {
            active_internal_name = {},
        }

        local ok, err, status = PluginPackageManager:removeUserPlugin("active-plugin.koplugin", { plugin_dir = plugin_dir })

        assert.is_nil(ok)
        assert.truthy(err:match("currently active"))
        assert.are.equal("restart_required", status)
        assert.are.equal("directory", lfs.attributes(plugin_path, "mode"))
        assert.is_true(G_reader_settings:readSetting("plugins_disabled")["active-plugin"])
        assert.is_true(G_reader_settings:readSetting("plugins_disabled")["active_internal_name"])
        assert.is_true(G_reader_settings:readSetting("plugins_pending_removal")["active-plugin.koplugin"])
    end)

    it("uses loader records when detecting active user plugins", function()
        local plugin_dir = path("plugins")
        local plugin_path = plugin_dir .. "/active-plugin.koplugin"
        assert.is_true(util.makePath(plugin_path))
        local fp = assert(io.open(plugin_path .. "/main.lua", "w"))
        fp:write("return {}")
        fp:close()
        PluginLoader.enabled_plugins = {
            {
                path = plugin_path,
                name = "loader_internal_name",
                plugin_key = "active-plugin",
            },
        }
        PluginLoader.loaded_plugins = {
            loader_internal_name = {},
        }

        local ok, err, status = PluginPackageManager:removeUserPlugin("active-plugin.koplugin", { plugin_dir = plugin_dir })

        assert.is_nil(ok)
        assert.truthy(err:match("currently active"))
        assert.are.equal("restart_required", status)
        assert.are.equal("directory", lfs.attributes(plugin_path, "mode"))
        assert.is_true(G_reader_settings:readSetting("plugins_disabled")["active-plugin"])
        assert.is_true(G_reader_settings:readSetting("plugins_pending_removal")["active-plugin.koplugin"])
    end)

    it("uses loaded plugin metadata after discovery caches are reset", function()
        local plugin_dir = path("plugins")
        local plugin_path = plugin_dir .. "/active-plugin.koplugin"
        assert.is_true(util.makePath(plugin_path))
        local fp = assert(io.open(plugin_path .. "/main.lua", "w"))
        fp:write("return { name = compute_name_somehow }")
        fp:close()
        PluginLoader.enabled_plugins = nil
        PluginLoader.disabled_plugins = nil
        PluginLoader.loaded_plugins = {
            loader_internal_name = {},
        }
        PluginLoader.loaded_plugin_info = {
            loader_internal_name = {
                path = plugin_path,
                plugin_key = "active-plugin",
                name = "loader_internal_name",
            },
        }

        local ok, err, status = PluginPackageManager:removeUserPlugin("active-plugin.koplugin", { plugin_dir = plugin_dir })

        assert.is_nil(ok)
        assert.truthy(err:match("currently active"))
        assert.are.equal("restart_required", status)
        assert.are.equal("directory", lfs.attributes(plugin_path, "mode"))
        assert.is_true(G_reader_settings:readSetting("plugins_disabled")["loader_internal_name"])
    end)

    it("cleans pending plugin removals on startup", function()
        local plugin_dir = path("plugins")
        local plugin_path = plugin_dir .. "/pending-plugin.koplugin"
        assert.is_true(util.makePath(plugin_path))
        local fp = assert(io.open(plugin_path .. "/main.lua", "w"))
        fp:write("return { name = 'pending_internal_name' }")
        fp:close()
        G_reader_settings:saveSetting("plugins_disabled", {
            ["pending-plugin"] = true,
            pending_internal_name = true,
        })
        G_reader_settings:saveSetting("plugins_pending_removal", {
            ["pending-plugin.koplugin"] = true,
        })

        local ok = PluginPackageManager:cleanupPendingRemovals({ plugin_dir = plugin_dir })

        assert.is_true(ok)
        assert.is_nil(lfs.attributes(plugin_path, "mode"))
        assert.is_nil(G_reader_settings:readSetting("plugins_pending_removal")["pending-plugin.koplugin"])
        assert.is_nil(G_reader_settings:readSetting("plugins_disabled")["pending-plugin"])
        assert.is_nil(G_reader_settings:readSetting("plugins_disabled")["pending_internal_name"])
    end)

    it("resets discovery caches without dropping live plugin instances", function()
        local running_instance = {}
        PluginLoader.enabled_plugins = {}
        PluginLoader.disabled_plugins = {}
        PluginLoader.loaded_plugins = {
            running_plugin = running_instance,
        }
        PluginLoader.loaded_plugin_info = {
            running_plugin = {
                path = "running.koplugin",
                plugin_key = "running",
                name = "running_plugin",
            },
        }
        PluginLoader.all_plugins = {}

        PluginPackageManager:resetPluginLoaderCache()

        assert.is_nil(PluginLoader.enabled_plugins)
        assert.is_nil(PluginLoader.disabled_plugins)
        assert.is_nil(PluginLoader.all_plugins)
        assert.are.same(running_instance, PluginLoader.loaded_plugins.running_plugin)
        assert.are.equal("running", PluginLoader.loaded_plugin_info.running_plugin.plugin_key)
    end)

    it("cleans temporary iOS imports without deleting arbitrary zip files", function()
        local import_dir = path("koreader-plugin-imports")
        assert.is_true(util.makePath(import_dir))
        local imported_zip = import_dir .. "/plugin.zip"
        local regular_zip = path("plugin.zip")
        local fp = assert(io.open(imported_zip, "w"))
        fp:write("temporary")
        fp:close()
        fp = assert(io.open(regular_zip, "w"))
        fp:write("regular")
        fp:close()

        PluginPackageManager._test.cleanupImportedZip(imported_zip)
        PluginPackageManager._test.cleanupImportedZip(regular_zip)

        assert.is_nil(lfs.attributes(imported_zip, "mode"))
        assert.are.equal("file", lfs.attributes(regular_zip, "mode"))
    end)
end)
