describe("iOS folder access", function()
    local IOSFolderAccess
    local saved_settings

    local function saveSettings(keys)
        saved_settings = {}
        for _, key in ipairs(keys) do
            saved_settings[key] = {
                has = G_reader_settings:has(key),
                value = G_reader_settings:readSetting(key),
            }
        end
    end

    local function restoreSettings()
        for key, saved in pairs(saved_settings) do
            if saved.has then
                G_reader_settings:saveSetting(key, saved.value)
            else
                G_reader_settings:delSetting(key)
            end
        end
    end

    local function fakeDevice(resolvers)
        local device = {
            released = {},
        }
        function device:resolveExternalFolderBookmark(bookmark)
            local resolver = resolvers and resolvers[bookmark]
            if resolver then
                return resolver(bookmark)
            end
            return nil, "missing resolver"
        end
        function device:releaseExternalFolderBookmark(bookmark)
            table.insert(self.released, bookmark)
            return true
        end
        return device
    end

    setup(function()
        require("commonrequire")
        IOSFolderAccess = require("iosfolderaccess")
    end)

    before_each(function()
        saveSettings({
            "ios_external_folders",
            "folder_shortcuts",
            "home_dir",
            "lastdir",
            "lastfile",
        })
        G_reader_settings:saveSetting("ios_external_folders", {})
        G_reader_settings:saveSetting("folder_shortcuts", {})
        G_reader_settings:delSetting("home_dir")
        G_reader_settings:delSetting("lastdir")
        G_reader_settings:delSetting("lastfile")
    end)

    after_each(function()
        restoreSettings()
    end)

    it("saves picked folders as marked folder shortcuts", function()
        local device = fakeDevice()

        assert.is_true(IOSFolderAccess:savePickedFolder(device, "Cloud", "/tmp/cloud/", "bookmark-1"))

        local entries = G_reader_settings:readSetting("ios_external_folders")
        assert.are.equals(1, #entries)
        assert.are.equals("Cloud", entries[1].name)
        assert.are.equals("/tmp/cloud", entries[1].path)
        assert.are.equals("bookmark-1", entries[1].bookmark)

        local shortcuts = G_reader_settings:readSetting("folder_shortcuts")
        assert.are.equals("Cloud", shortcuts["/tmp/cloud"].text)
        assert.is_true(shortcuts["/tmp/cloud"].ios_external_folder)
        assert.are.equals("bookmark-1", shortcuts["/tmp/cloud"].ios_external_folder_bookmark)
    end)

    it("replaces duplicate picked folders and releases the old bookmark", function()
        local device = fakeDevice()

        assert.is_true(IOSFolderAccess:savePickedFolder(device, "Old", "/tmp/cloud", "bookmark-1"))
        assert.is_true(IOSFolderAccess:savePickedFolder(device, "New", "/tmp/cloud", "bookmark-2"))

        local entries = G_reader_settings:readSetting("ios_external_folders")
        assert.are.equals(1, #entries)
        assert.are.equals("New", entries[1].name)
        assert.are.equals("bookmark-2", entries[1].bookmark)
        assert.are.same({ "bookmark-1" }, device.released)
    end)

    it("resolves saved bookmarks and rewrites path drift", function()
        local device = fakeDevice({
            ["bookmark-1"] = function()
                return "/new/root", nil, "bookmark-2"
            end,
        })
        G_reader_settings:saveSetting("ios_external_folders", {
            { name = "Drive", path = "/old/root", bookmark = "bookmark-1", time = 12 },
        })
        G_reader_settings:saveSetting("folder_shortcuts", {
            ["/old/root"] = {
                text = "Drive",
                ios_external_folder = true,
                ios_external_folder_bookmark = "bookmark-1",
            },
            ["/old/root/Child"] = { text = "Child", time = 13 },
        })
        G_reader_settings:saveSetting("home_dir", "/old/root")
        G_reader_settings:saveSetting("lastdir", "/old/root/Sub")
        G_reader_settings:saveSetting("lastfile", "/old/root/Sub/book.epub")

        IOSFolderAccess:resolveSavedFolders(device)

        local entries = G_reader_settings:readSetting("ios_external_folders")
        assert.are.equals("/new/root", entries[1].path)
        assert.are.equals("bookmark-2", entries[1].bookmark)

        local shortcuts = G_reader_settings:readSetting("folder_shortcuts")
        assert.is_nil(shortcuts["/old/root"])
        assert.are.equals("Drive", shortcuts["/new/root"].text)
        assert.is_true(shortcuts["/new/root"].ios_external_folder)
        assert.are.equals("bookmark-2", shortcuts["/new/root"].ios_external_folder_bookmark)
        assert.are.equals("Child", shortcuts["/new/root/Child"].text)

        assert.are.equals("/new/root", G_reader_settings:readSetting("home_dir"))
        assert.are.equals("/new/root/Sub", G_reader_settings:readSetting("lastdir"))
        assert.are.equals("/new/root/Sub/book.epub", G_reader_settings:readSetting("lastfile"))
        assert.are.same({ "bookmark-1" }, device.released)
    end)

    it("keeps saved entries when bookmark resolution temporarily fails", function()
        local device = fakeDevice({
            ["bookmark-1"] = function()
                return nil, "provider unavailable"
            end,
        })
        G_reader_settings:saveSetting("ios_external_folders", {
            { name = "Drive", path = "/old/root", bookmark = "bookmark-1", time = 12 },
        })
        G_reader_settings:saveSetting("folder_shortcuts", {
            ["/old/root"] = {
                text = "Drive",
                ios_external_folder = true,
                ios_external_folder_bookmark = "bookmark-1",
            },
        })

        IOSFolderAccess:resolveSavedFolders(device)

        local entries = G_reader_settings:readSetting("ios_external_folders")
        assert.are.equals(1, #entries)
        assert.are.equals("/old/root", entries[1].path)
        assert.are.equals("bookmark-1", entries[1].bookmark)
        assert.is_table(G_reader_settings:readSetting("folder_shortcuts")["/old/root"])
        assert.are.same({}, device.released)
    end)

    it("removes external folder records when their shortcut is removed", function()
        local device = fakeDevice()
        G_reader_settings:saveSetting("ios_external_folders", {
            { name = "Drive", path = "/cloud", bookmark = "bookmark-1", time = 12 },
            { name = "Other", path = "/other", bookmark = "bookmark-2", time = 13 },
        })
        G_reader_settings:saveSetting("folder_shortcuts", {
            ["/cloud"] = {
                text = "Drive",
                ios_external_folder = true,
                ios_external_folder_bookmark = "bookmark-1",
            },
            ["/other"] = {
                text = "Other",
                ios_external_folder = true,
                ios_external_folder_bookmark = "bookmark-2",
            },
        })

        assert.is_true(IOSFolderAccess:removeShortcut("/cloud", device))

        local entries = G_reader_settings:readSetting("ios_external_folders")
        assert.are.equals(1, #entries)
        assert.are.equals("/other", entries[1].path)
        assert.is_nil(G_reader_settings:readSetting("folder_shortcuts")["/cloud"])
        assert.are.same({ "bookmark-1" }, device.released)
    end)

    it("renames external folder records with their shortcut", function()
        G_reader_settings:saveSetting("ios_external_folders", {
            { name = "Drive", path = "/cloud", bookmark = "bookmark-1", time = 12 },
        })
        G_reader_settings:saveSetting("folder_shortcuts", {
            ["/cloud"] = {
                text = "Drive",
                ios_external_folder = true,
                ios_external_folder_bookmark = "bookmark-1",
            },
        })

        assert.is_true(IOSFolderAccess:renameShortcut("/cloud", "Books"))

        local entries = G_reader_settings:readSetting("ios_external_folders")
        assert.are.equals("Books", entries[1].name)
        assert.are.equals("Books", G_reader_settings:readSetting("folder_shortcuts")["/cloud"].text)
    end)
end)
