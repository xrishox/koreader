describe("PluginPackageManager", function()
    local Archiver, DataStorage, PluginPackageManager, ffiUtil, lfs, util
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

    setup(function()
        require("commonrequire")
        Archiver = require("ffi/archiver")
        DataStorage = require("datastorage")
        PluginPackageManager = require("pluginpackagemanager")
        ffiUtil = require("ffi/util")
        lfs = require("libs/libkoreader-lfs")
        util = require("util")
    end)

    before_each(function()
        test_dir = DataStorage:getDataDir() .. "/pluginpackagemanager_spec"
        ffiUtil.purgeDir(test_dir)
        assert.is_true(util.makePath(test_dir))
    end)

    after_each(function()
        ffiUtil.purgeDir(test_dir)
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

    it("removes user plugins and clears disabled state", function()
        local plugin_dir = path("plugins")
        assert.is_true(util.makePath(plugin_dir .. "/remove-me.koplugin"))
        local fp = assert(io.open(plugin_dir .. "/remove-me.koplugin/main.lua", "w"))
        fp:write("return {}")
        fp:close()
        G_reader_settings:saveSetting("plugins_disabled", { ["remove-me"] = true })

        local ok = PluginPackageManager:removeUserPlugin("remove-me.koplugin", { plugin_dir = plugin_dir })

        assert.is_true(ok)
        assert.is_nil(lfs.attributes(plugin_dir .. "/remove-me.koplugin"))
        assert.is_nil(G_reader_settings:readSetting("plugins_disabled")["remove-me"])
    end)
end)
