local logger = require("logger")

local IOSFolderAccess = {
    settings_key = "ios_external_folders",
    shortcut_marker = "ios_external_folder",
    shortcut_bookmark_key = "ios_external_folder_bookmark",
}

local function normalizePath(path)
    if type(path) ~= "string" then return nil end
    path = path:gsub("/+$", "")
    if path == "" then return "/" end
    return path
end

local function basename(path)
    path = normalizePath(path)
    if not path then return "" end
    return path:match("([^/]+)$") or path
end

local function isUnderPath(path, root)
    path = normalizePath(path)
    root = normalizePath(root)
    if not path or not root then return false end
    return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function replacePathPrefix(path, old_root, new_root)
    path = normalizePath(path)
    old_root = normalizePath(old_root)
    new_root = normalizePath(new_root)
    if not path or not old_root or not new_root or not isUnderPath(path, old_root) then
        return nil
    end
    if path == old_root then
        return new_root
    end
    return new_root .. path:sub(#old_root + 1)
end

local function readSettingTable(key)
    if not G_reader_settings then return {} end
    local value = G_reader_settings:readSetting(key)
    if type(value) ~= "table" then
        value = {}
        G_reader_settings:saveSetting(key, value)
    end
    return value
end

local function flushSettings()
    if G_reader_settings and G_reader_settings.flush then
        pcall(function() G_reader_settings:flush() end)
    end
end

local function makeShortcutItem(name, bookmark, time)
    return {
        text = name,
        time = time or os.time(),
        [IOSFolderAccess.shortcut_marker] = true,
        [IOSFolderAccess.shortcut_bookmark_key] = bookmark,
    }
end

local function isExternalShortcut(item, bookmark)
    if type(item) ~= "table" then return false end
    if item[IOSFolderAccess.shortcut_bookmark_key] == bookmark then return true end
    return item[IOSFolderAccess.shortcut_marker] == true and bookmark == nil
end

local function rewriteSimplePathSettings(old_path, new_path)
    if not G_reader_settings then return end
    for _, key in ipairs({ "home_dir", "lastdir", "lastfile" }) do
        local value = G_reader_settings:readSetting(key)
        local updated = replacePathPrefix(value, old_path, new_path)
        if updated and updated ~= value then
            G_reader_settings:saveSetting(key, updated)
        end
    end
end

local function rewriteShortcutPaths(shortcuts, old_path, new_path, bookmark)
    local updates = {}
    for path, item in pairs(shortcuts) do
        local updated = replacePathPrefix(path, old_path, new_path)
        if updated and updated ~= path then
            table.insert(updates, { old = path, new = updated, item = item })
        elseif isExternalShortcut(item, bookmark) then
            item[IOSFolderAccess.shortcut_bookmark_key] = bookmark
        end
    end
    for _, update in ipairs(updates) do
        shortcuts[update.old] = nil
        if shortcuts[update.new] == nil then
            shortcuts[update.new] = update.item
        end
    end
end

local function rewriteShortcutBookmark(shortcuts, old_bookmark, new_bookmark)
    if not old_bookmark or not new_bookmark or old_bookmark == new_bookmark then
        return
    end
    for _, item in pairs(shortcuts) do
        if type(item) == "table" and item[IOSFolderAccess.shortcut_bookmark_key] == old_bookmark then
            item[IOSFolderAccess.shortcut_bookmark_key] = new_bookmark
        end
    end
end

local function releaseBookmark(device, bookmark)
    if device and device.releaseExternalFolderBookmark and bookmark then
        pcall(function() device:releaseExternalFolderBookmark(bookmark) end)
    end
end

function IOSFolderAccess:getSavedFolders()
    return readSettingTable(self.settings_key)
end

function IOSFolderAccess:getFolderShortcuts()
    return readSettingTable("folder_shortcuts")
end

function IOSFolderAccess:savePickedFolder(device, name, path, bookmark)
    path = normalizePath(path)
    if not path or type(bookmark) ~= "string" or bookmark == "" then
        return false, "missing path or bookmark"
    end
    name = type(name) == "string" and name ~= "" and name or basename(path)

    local entries = self:getSavedFolders()
    local shortcuts = self:getFolderShortcuts()
    for i = #entries, 1, -1 do
        local entry = entries[i]
        if type(entry) ~= "table" or entry.bookmark == bookmark or normalizePath(entry.path) == path then
            if type(entry) == "table" then
                if entry.bookmark ~= bookmark then
                    releaseBookmark(device, entry.bookmark)
                end
                if entry.path and isExternalShortcut(shortcuts[normalizePath(entry.path)], entry.bookmark) then
                    shortcuts[normalizePath(entry.path)] = nil
                end
            end
            table.remove(entries, i)
        end
    end

    local entry = {
        name = name,
        path = path,
        bookmark = bookmark,
        time = os.time(),
    }
    table.insert(entries, entry)
    shortcuts[path] = makeShortcutItem(name, bookmark, entry.time)
    G_reader_settings:saveSetting(self.settings_key, entries)
    G_reader_settings:saveSetting("folder_shortcuts", shortcuts)
    flushSettings()
    return true
end

function IOSFolderAccess:resolveSavedFolders(device)
    if not G_reader_settings or not device or not device.resolveExternalFolderBookmark then
        return
    end

    local entries = self:getSavedFolders()
    local shortcuts = self:getFolderShortcuts()
    local refreshed_entries = {}
    local changed = false

    for _, entry in ipairs(entries) do
        if type(entry) == "table" and type(entry.bookmark) == "string" and entry.bookmark ~= "" then
            local old_path = normalizePath(entry.path)
            local old_bookmark = entry.bookmark
            local path, err, refreshed_bookmark = device:resolveExternalFolderBookmark(entry.bookmark)
            path = normalizePath(path)
            if path then
                entry.name = type(entry.name) == "string" and entry.name ~= "" and entry.name or basename(path)
                entry.path = path
                entry.bookmark = refreshed_bookmark or entry.bookmark
                entry.time = entry.time or os.time()

                if old_path and old_path ~= path then
                    rewriteSimplePathSettings(old_path, path)
                    rewriteShortcutPaths(shortcuts, old_path, path, old_bookmark)
                    changed = true
                end
                if old_bookmark ~= entry.bookmark then
                    rewriteShortcutBookmark(shortcuts, old_bookmark, entry.bookmark)
                    releaseBookmark(device, old_bookmark)
                    changed = true
                end

                shortcuts[path] = makeShortcutItem(entry.name, entry.bookmark, entry.time)
            else
                logger.warn("iOS external folder could not be restored:", entry.name or old_path or "unknown", err or "unknown error")
            end
            table.insert(refreshed_entries, entry)
        else
            changed = true
        end
    end

    if changed or #refreshed_entries ~= #entries then
        G_reader_settings:saveSetting(self.settings_key, refreshed_entries)
    end
    G_reader_settings:saveSetting("folder_shortcuts", shortcuts)
end

function IOSFolderAccess:removeShortcut(folder, device)
    folder = normalizePath(folder)
    if not folder or not G_reader_settings then return false end

    local entries = self:getSavedFolders()
    local shortcuts = self:getFolderShortcuts()
    local shortcut = shortcuts[folder]
    local bookmark = type(shortcut) == "table" and shortcut[self.shortcut_bookmark_key] or nil
    local removed = false

    for i = #entries, 1, -1 do
        local entry = entries[i]
        if type(entry) ~= "table"
            or (bookmark and entry.bookmark == bookmark)
            or normalizePath(entry.path) == folder then
            if type(entry) == "table" then
                releaseBookmark(device, entry.bookmark)
            end
            table.remove(entries, i)
            removed = true
        end
    end

    if removed then
        shortcuts[folder] = nil
        G_reader_settings:saveSetting(self.settings_key, entries)
        G_reader_settings:saveSetting("folder_shortcuts", shortcuts)
        flushSettings()
    end
    return removed
end

function IOSFolderAccess:renameShortcut(folder, new_name)
    folder = normalizePath(folder)
    if not folder or type(new_name) ~= "string" or new_name == "" then return false end

    local entries = self:getSavedFolders()
    local shortcuts = self:getFolderShortcuts()
    local shortcut = shortcuts[folder]
    local bookmark = type(shortcut) == "table" and shortcut[self.shortcut_bookmark_key] or nil
    local renamed = false

    for _, entry in ipairs(entries) do
        if type(entry) == "table"
            and ((bookmark and entry.bookmark == bookmark) or normalizePath(entry.path) == folder) then
            entry.name = new_name
            renamed = true
        end
    end

    if renamed then
        if type(shortcut) == "table" then
            shortcut.text = new_name
        end
        G_reader_settings:saveSetting(self.settings_key, entries)
        G_reader_settings:saveSetting("folder_shortcuts", shortcuts)
        flushSettings()
    end
    return renamed
end

return IOSFolderAccess
