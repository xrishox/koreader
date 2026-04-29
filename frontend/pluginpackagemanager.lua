local Archiver = require("ffi/archiver")
local DataStorage = require("datastorage")
local Device = require("device")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local PluginPackageManager = {}

local function stripKopluginSuffix(name)
    return name:gsub("%.koplugin$", "")
end

local function sanitizePluginName(name)
    name = util.splitFileNameSuffix(name)
    name = name:gsub("%.koplugin$", "")
    name = util.getSafeFilename(name, nil, 80) or ""
    name = name:gsub("%s+", "_")
    name = name:gsub("[^%w._-]", "_")
    name = name:gsub("^[_%.%-]+", ""):gsub("[_%.%-]+$", "")
    if name == "" then
        return nil
    end
    return name .. ".koplugin"
end

local function normalizeArchivePath(path)
    if type(path) ~= "string" or path == "" then
        return nil, _("Invalid empty archive entry.")
    end
    if path:find("\\", 1, true) then
        return nil, T(_("Archive entry contains a backslash: %1"), path)
    end
    if path:sub(1, 1) == "/" then
        return nil, T(_("Archive entry is an absolute path: %1"), path)
    end

    path = path:gsub("^%./+", "")
    path = path:gsub("/+$", "")
    if path == "" then
        return nil, _("Archive contains an invalid root entry.")
    end

    for part in path:gmatch("[^/]+") do
        if part == "." or part == ".." then
            return nil, T(_("Archive entry contains an unsafe path: %1"), path)
        end
    end
    return path
end

local function getTopLevel(path)
    return path:match("^([^/]+)")
end

local function getSingleTopLevel(top_levels)
    local count, name = 0, nil
    for top in pairs(top_levels) do
        count = count + 1
        name = top
    end
    if count == 1 then
        return name
    end
end

function PluginPackageManager:getUserPluginDir()
    return DataStorage:getDataDir() .. "/plugins"
end

function PluginPackageManager:getUserPluginPath(plugin_name, plugin_dir)
    return (plugin_dir or self:getUserPluginDir()) .. "/" .. plugin_name
end

function PluginPackageManager:isBundledPluginName(plugin_name)
    return lfs.attributes("plugins/" .. plugin_name, "mode") == "directory"
end

function PluginPackageManager:listUserPlugins(plugin_dir)
    plugin_dir = plugin_dir or self:getUserPluginDir()
    local plugins = {}
    if lfs.attributes(plugin_dir, "mode") ~= "directory" then
        return plugins
    end
    for entry in lfs.dir(plugin_dir) do
        local path = plugin_dir .. "/" .. entry
        if entry:sub(-9) == ".koplugin" and lfs.attributes(path, "mode") == "directory" then
            table.insert(plugins, entry)
        end
    end
    table.sort(plugins)
    return plugins
end

function PluginPackageManager:analyzeZip(zip_path)
    local reader = Archiver.Reader:new()
    if not reader:open(zip_path) then
        return nil, reader.err or _("Could not open plugin ZIP archive.")
    end

    local entries = {}
    local top_levels = {}
    local koplugin_roots = {}
    for entry in reader:iterate() do
        if entry.mode ~= "file" and entry.mode ~= "directory" then
            reader:close()
            return nil, T(_("Unsupported archive entry type: %1"), entry.mode)
        end
        local normalized, err = normalizeArchivePath(entry.path)
        if not normalized then
            reader:close()
            return nil, err
        end
        local top = getTopLevel(normalized)
        top_levels[top] = true
        if top:sub(-9) == ".koplugin" then
            koplugin_roots[top] = true
        end
        table.insert(entries, {
            archive_path = entry.path,
            path = normalized,
            mode = entry.mode,
        })
    end
    reader:close()

    if #entries == 0 then
        return nil, _("Plugin ZIP archive is empty.")
    end

    local root_count, root_name = 0, nil
    for root in pairs(koplugin_roots) do
        root_count = root_count + 1
        root_name = root
    end
    if root_count > 1 then
        return nil, _("Plugin ZIP archive contains multiple .koplugin folders.")
    end

    local plugin_name
    local strip_root
    if root_count == 1 then
        for top in pairs(top_levels) do
            if top ~= root_name then
                return nil, _("Plugin ZIP archive mixes a .koplugin folder with other root files.")
            end
        end
        plugin_name = root_name
        strip_root = root_name
    else
        local _, file_name = util.splitFilePathName(zip_path)
        plugin_name = sanitizePluginName(file_name)
        if not plugin_name then
            return nil, _("Plugin ZIP filename does not produce a valid plugin name.")
        end
        local single_root = getSingleTopLevel(top_levels)
        if single_root then
            for _, entry in ipairs(entries) do
                if entry.path == single_root .. "/main.lua" then
                    strip_root = single_root
                    break
                end
            end
        end
    end

    local has_main = false
    local extracted = {}
    for _, entry in ipairs(entries) do
        local relative_path = entry.path
        if strip_root then
            relative_path = entry.path:sub(#strip_root + 2)
        end
        if relative_path and relative_path ~= "" then
            if relative_path == "main.lua" then
                has_main = true
            end
            table.insert(extracted, {
                archive_path = entry.archive_path,
                relative_path = relative_path,
                mode = entry.mode,
            })
        end
    end
    if not has_main then
        return nil, _("Plugin ZIP archive must contain main.lua.")
    end

    return {
        plugin_name = plugin_name,
        plugin_key = stripKopluginSuffix(plugin_name),
        entries = extracted,
    }
end

local function removePathIfExists(path)
    local mode = lfs.attributes(path, "mode")
    if mode == "directory" then
        return ffiUtil.purgeDir(path)
    elseif mode ~= nil then
        return os.remove(path)
    end
    return true
end

function PluginPackageManager:installZip(zip_path, opts)
    opts = opts or {}
    local plan, err = self:analyzeZip(zip_path)
    if not plan then
        return nil, err
    end
    if self:isBundledPluginName(plan.plugin_name) then
        return nil, _("A bundled plugin with this name already exists.")
    end

    local plugin_dir = opts.plugin_dir or self:getUserPluginDir()
    local ok, mkdir_err = util.makePath(plugin_dir)
    if not ok then
        return nil, mkdir_err
    end

    local destination = self:getUserPluginPath(plan.plugin_name, plugin_dir)
    if lfs.attributes(destination, "mode") ~= nil and not opts.replace then
        return nil, "exists", plan
    end

    local staging = destination .. ".installing"
    ok, err = removePathIfExists(staging)
    if not ok then
        return nil, err
    end
    ok, err = util.makePath(staging)
    if not ok then
        return nil, err
    end

    local reader = Archiver.Reader:new()
    if not reader:open(zip_path) then
        removePathIfExists(staging)
        return nil, reader.err or _("Could not open plugin ZIP archive.")
    end

    local entries_by_archive_path = {}
    for _, entry in ipairs(plan.entries) do
        entries_by_archive_path[entry.archive_path] = entry
    end

    for archive_entry in reader:iterate() do
        local entry = entries_by_archive_path[archive_entry.path]
        -- Entries outside the selected plugin root were rejected during
        -- analysis, but the root directory itself is intentionally skipped.
        if entry then
            local dest_path = staging .. "/" .. entry.relative_path
            if entry.mode == "directory" then
                ok, err = util.makePath(dest_path)
            else
                ok, err = util.makePath(ffiUtil.dirname(dest_path))
                if ok then
                    ok = reader:extractToPath(archive_entry.index, dest_path)
                    err = reader.err
                end
            end
            if not ok then
                reader:close()
                removePathIfExists(staging)
                return nil, err or T(_("Could not extract archive entry: %1"), entry.relative_path)
            end
        end
    end
    reader:close()

    ok, err = removePathIfExists(destination)
    if not ok then
        removePathIfExists(staging)
        return nil, err
    end
    ok, err = os.rename(staging, destination)
    if not ok then
        removePathIfExists(staging)
        return nil, err
    end

    local plugins_disabled = G_reader_settings:readSetting("plugins_disabled") or {}
    plugins_disabled[plan.plugin_key] = nil
    G_reader_settings:saveSetting("plugins_disabled", plugins_disabled)
    self:resetPluginLoaderCache()

    return true, plan
end

function PluginPackageManager:removeUserPlugin(plugin_name, opts)
    opts = opts or {}
    if type(plugin_name) ~= "string" or plugin_name:sub(-9) ~= ".koplugin" then
        return nil, _("Invalid plugin name.")
    end
    local plugin_dir = opts.plugin_dir or self:getUserPluginDir()
    local plugin_path = self:getUserPluginPath(plugin_name, plugin_dir)
    if lfs.attributes(plugin_path, "mode") ~= "directory" then
        return nil, _("Plugin is not installed in the user plugin folder.")
    end
    local ok, err = ffiUtil.purgeDir(plugin_path)
    if not ok then
        return nil, err
    end

    local plugins_disabled = G_reader_settings:readSetting("plugins_disabled") or {}
    plugins_disabled[stripKopluginSuffix(plugin_name)] = nil
    G_reader_settings:saveSetting("plugins_disabled", plugins_disabled)
    self:resetPluginLoaderCache()
    return true
end

function PluginPackageManager:resetPluginLoaderCache()
    local ok, PluginLoader = pcall(require, "pluginloader")
    if ok then
        PluginLoader.enabled_plugins = nil
        PluginLoader.disabled_plugins = nil
        PluginLoader.loaded_plugins = nil
        PluginLoader.all_plugins = nil
    end
end

local function showInfo(text, icon)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{
        text = text,
        icon = icon,
    })
end

function PluginPackageManager:showInstallResult(ok, result)
    local UIManager = require("ui/uimanager")
    if ok then
        UIManager:askForRestart(T(_("Plugin %1 was installed. It will be available after restarting KOReader."), result.plugin_name))
    else
        showInfo(T(_("Plugin installation failed: %1"), result or _("unknown error")), "notice-warning")
    end
end

function PluginPackageManager:installZipWithConfirmation(zip_path)
    local ok, result, plan = self:installZip(zip_path)
    if ok then
        self:showInstallResult(true, result)
        return
    end
    if result ~= "exists" then
        self:showInstallResult(false, result)
        return
    end

    if not plan then
        local analyzed, err = self:analyzeZip(zip_path)
        plan = analyzed
        if not plan then
            self:showInstallResult(false, err)
            return
        end
    end

    local UIManager = require("ui/uimanager")
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Plugin %1 is already installed. Replace it?"), plan.plugin_name),
        ok_text = _("Replace"),
        ok_callback = function()
            local replace_ok, replace_result = self:installZip(zip_path, { replace = true })
            self:showInstallResult(replace_ok, replace_result)
        end,
    })
end

function PluginPackageManager:showIOSZipPicker()
    local UIManager = require("ui/uimanager")
    if not Device:isIOS() or not Device.requestPluginZipImport then
        showInfo(_("Plugin ZIP import is only available on iOS."), "notice-warning")
        return
    end
    if not Device:requestPluginZipImport() then
        showInfo(_("Could not open the iOS file picker."), "notice-warning")
        return
    end

    showInfo(_("Choose a plugin ZIP file."))
    local function pollPicker()
        local status, value = Device:getPluginZipImportResult()
        if status == "pending" then
            UIManager:scheduleIn(0.25, pollPicker)
        elseif status == "ok" then
            self:installZipWithConfirmation(value)
        elseif status == "cancelled" then
            -- Nothing to report.
        else
            showInfo(T(_("Plugin ZIP import failed: %1"), value or _("unknown error")), "notice-warning")
        end
    end
    UIManager:scheduleIn(0.25, pollPicker)
end

function PluginPackageManager:genRemoveUserPluginMenu()
    local menu = {}
    local plugins = self:listUserPlugins()
    if #plugins == 0 then
        return {
            {
                text = _("No user-installed plugins"),
                enabled = false,
            },
        }
    end

    for _, plugin_name in ipairs(plugins) do
        table.insert(menu, {
            text = plugin_name,
            callback = function()
                local UIManager = require("ui/uimanager")
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = T(_("Remove plugin %1?"), plugin_name),
                    ok_text = _("Remove"),
                    ok_callback = function()
                        local ok, err = self:removeUserPlugin(plugin_name)
                        if ok then
                            UIManager:askForRestart(T(_("Plugin %1 was removed. Changes will take effect after restarting KOReader."), plugin_name))
                        else
                            showInfo(T(_("Plugin removal failed: %1"), err or _("unknown error")), "notice-warning")
                        end
                    end,
                })
            end,
        })
    end
    return menu
end

function PluginPackageManager:genIOSMenuItems()
    if not Device:isIOS() then
        return {}
    end
    return {
        {
            text = _("Install plugin from ZIP…"),
            callback = function()
                self:showIOSZipPicker()
            end,
        },
        {
            text = _("Remove user plugin…"),
            sub_item_table_func = function()
                return self:genRemoveUserPluginMenu()
            end,
            separator = true,
        },
    }
end

PluginPackageManager._test = {
    normalizeArchivePath = normalizeArchivePath,
    sanitizePluginName = sanitizePluginName,
}

return PluginPackageManager
