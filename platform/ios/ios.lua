--[[--
Minimal iOS bridge used by Lua before the native launcher is complete.

The native iOS host is expected to replace these values through a preload
module or environment variables before `reader.lua` starts.
]]

local ffi_ok, ffi = pcall(require, "ffi")

if ffi_ok then
    ffi.cdef[[
    const char *KOIOSGetBundlePath(void);
    const char *KOIOSGetResourcePath(void);
    const char *KOIOSGetDocumentsPath(void);
    const char *KOIOSGetApplicationSupportPath(void);
    const char *KOIOSGetNativeLibraryDir(void);
    void KOIOSGetSafeAreaInsets(int *top, int *right, int *bottom, int *left);
    int KOIOSOpenLink(const char *url);
    int KOIOSHasClipboardText(void);
    const char *KOIOSGetClipboardText(void);
    int KOIOSSetClipboardText(const char *text);
    int KOIOSCanShareText(void);
    int KOIOSShareText(const char *text, const char *reason, const char *title, const char *mimetype);
    int KOIOSRequestPluginZipImport(void);
    int KOIOSGetPluginZipImportStatus(void);
    const char *KOIOSGetPluginZipImportPath(void);
    const char *KOIOSGetPluginZipImportError(void);
    void KOIOSConsumePluginZipImportResult(void);
    int KOIOSRequestFileImport(const char *destination_path);
    int KOIOSGetFileImportStatus(void);
    int KOIOSGetFileImportCount(void);
    const char *KOIOSGetFileImportError(void);
    void KOIOSConsumeFileImportResult(void);
    int KOIOSRequestExternalFolderPicker(void);
    int KOIOSGetExternalFolderPickerStatus(void);
    const char *KOIOSGetExternalFolderPickerPath(void);
    const char *KOIOSGetExternalFolderPickerBookmark(void);
    const char *KOIOSGetExternalFolderPickerError(void);
    void KOIOSConsumeExternalFolderPickerResult(void);
    int KOIOSResolveExternalFolderBookmark(const char *bookmark_b64,
                                           char *out_path, size_t path_capacity,
                                           char *out_bookmark_b64, size_t bookmark_capacity,
                                           char *out_error, size_t error_capacity);
    int KOIOSReleaseExternalFolderBookmark(const char *bookmark_b64);
    ]]
end

local function cstring(fn, fallback)
    if not ffi_ok then return fallback end
    local ok, value = pcall(fn)
    if ok and value ~= nil then
        return ffi.string(value)
    end
    return fallback
end

local function cint(fn, fallback)
    if not ffi_ok then return fallback end
    local ok, value = pcall(fn)
    if ok then
        return tonumber(value) ~= 0
    end
    return fallback
end

local external_folder_path_max = 4096
local external_folder_bookmark_max = 65536
local external_folder_error_max = 1024

local ios = {}

ios.bundlePath = cstring(function() return ffi.C.KOIOSGetBundlePath() end, os.getenv("KO_IOS_BUNDLE_PATH") or ".")
ios.resourcePath = cstring(function() return ffi.C.KOIOSGetResourcePath() end, os.getenv("KO_IOS_RESOURCE_PATH") or ios.bundlePath)
ios.documentsPath = cstring(function() return ffi.C.KOIOSGetDocumentsPath() end, os.getenv("KO_IOS_DOCUMENTS_PATH") or ".")
ios.applicationSupportPath = cstring(function() return ffi.C.KOIOSGetApplicationSupportPath() end, os.getenv("KO_IOS_APPLICATION_SUPPORT_PATH") or ios.documentsPath)
ios.libraryPath = os.getenv("KO_IOS_LIBRARY_PATH") or ios.applicationSupportPath
ios.nativeLibraryDir = cstring(function() return ffi.C.KOIOSGetNativeLibraryDir() end, os.getenv("KO_IOS_NATIVE_LIBRARY_DIR") or ios.resourcePath .. "/reader/libs")

function ios.getDataDir()
    return ios.applicationSupportPath .. "/koreader"
end

function ios.getResourcePath()
    return ios.resourcePath
end

function ios.getNativeLibraryDir()
    return ios.nativeLibraryDir
end

function ios.getDocumentsPath()
    return ios.documentsPath
end

function ios.getSafeAreaInsets()
    if not ffi_ok then
        return { top = 0, right = 0, bottom = 0, left = 0 }
    end
    local top = ffi.new("int[1]", 0)
    local right = ffi.new("int[1]", 0)
    local bottom = ffi.new("int[1]", 0)
    local left = ffi.new("int[1]", 0)
    local ok = pcall(function()
        ffi.C.KOIOSGetSafeAreaInsets(top, right, bottom, left)
    end)
    if not ok then
        return { top = 0, right = 0, bottom = 0, left = 0 }
    end
    return {
        top = tonumber(top[0]) or 0,
        right = tonumber(right[0]) or 0,
        bottom = tonumber(bottom[0]) or 0,
        left = tonumber(left[0]) or 0,
    }
end

function ios.openLink(link)
    return cint(function() return ffi.C.KOIOSOpenLink(link) end, false)
end

function ios.hasClipboardText()
    return cint(function() return ffi.C.KOIOSHasClipboardText() end, false)
end

function ios.getClipboardText()
    return cstring(function() return ffi.C.KOIOSGetClipboardText() end, "")
end

function ios.setClipboardText(text)
    return cint(function() return ffi.C.KOIOSSetClipboardText(text) end, false)
end

function ios.canShareText()
    return cint(function() return ffi.C.KOIOSCanShareText() end, false)
end

function ios.shareText(text, reason, title, mimetype)
    return cint(function()
        return ffi.C.KOIOSShareText(text, reason, title, mimetype)
    end, false)
end

function ios.requestPluginZipImport()
    return cint(function() return ffi.C.KOIOSRequestPluginZipImport() end, false)
end

function ios.getPluginZipImportResult()
    if not ffi_ok then
        return "failed", "iOS bridge is not available"
    end
    local ok, status = pcall(function()
        return tonumber(ffi.C.KOIOSGetPluginZipImportStatus())
    end)
    if not ok then
        return "failed", "iOS bridge is not available"
    end
    if status == 1 then
        return "pending"
    elseif status == 2 then
        local path = cstring(function() return ffi.C.KOIOSGetPluginZipImportPath() end, "")
        if path == "" then
            return "failed", "No plugin ZIP path was returned"
        end
        return "ok", path
    elseif status == 3 then
        return "cancelled"
    elseif status == 4 then
        return "failed", cstring(function() return ffi.C.KOIOSGetPluginZipImportError() end, "")
    end
    return "idle"
end

function ios.consumePluginZipImportResult()
    if not ffi_ok then
        return
    end
    pcall(function() ffi.C.KOIOSConsumePluginZipImportResult() end)
end

function ios.requestFileImport(destination_path)
    return cint(function() return ffi.C.KOIOSRequestFileImport(destination_path) end, false)
end

function ios.getFileImportResult()
    if not ffi_ok then
        return "failed", "iOS bridge is not available"
    end
    local ok, status = pcall(function()
        return tonumber(ffi.C.KOIOSGetFileImportStatus())
    end)
    if not ok then
        return "failed", "iOS bridge is not available"
    end
    if status == 1 then
        return "pending"
    elseif status == 2 then
        local count = 0
        pcall(function()
            count = tonumber(ffi.C.KOIOSGetFileImportCount()) or 0
        end)
        return "ok", count, cstring(function() return ffi.C.KOIOSGetFileImportError() end, "")
    elseif status == 3 then
        return "cancelled"
    elseif status == 4 then
        return "failed", cstring(function() return ffi.C.KOIOSGetFileImportError() end, "")
    end
    return "idle"
end

function ios.consumeFileImportResult()
    if not ffi_ok then
        return
    end
    pcall(function() ffi.C.KOIOSConsumeFileImportResult() end)
end

function ios.requestExternalFolderPicker()
    return cint(function() return ffi.C.KOIOSRequestExternalFolderPicker() end, false)
end

function ios.getExternalFolderPickerResult()
    if not ffi_ok then
        return "failed", "iOS bridge is not available"
    end
    local ok, status = pcall(function()
        return tonumber(ffi.C.KOIOSGetExternalFolderPickerStatus())
    end)
    if not ok then
        return "failed", "iOS bridge is not available"
    end
    if status == 1 then
        return "pending"
    elseif status == 2 then
        local path = cstring(function() return ffi.C.KOIOSGetExternalFolderPickerPath() end, "")
        local bookmark = cstring(function() return ffi.C.KOIOSGetExternalFolderPickerBookmark() end, "")
        if path == "" or bookmark == "" then
            return "failed", "No external folder path was returned"
        end
        return "ok", path, bookmark
    elseif status == 3 then
        return "cancelled"
    elseif status == 4 then
        return "failed", cstring(function() return ffi.C.KOIOSGetExternalFolderPickerError() end, "")
    end
    return "idle"
end

function ios.consumeExternalFolderPickerResult()
    if not ffi_ok then
        return
    end
    pcall(function() ffi.C.KOIOSConsumeExternalFolderPickerResult() end)
end

function ios.resolveExternalFolderBookmark(bookmark)
    if not ffi_ok then
        return nil, "iOS bridge is not available"
    end
    local out_path = ffi.new("char[?]", external_folder_path_max)
    local out_bookmark = ffi.new("char[?]", external_folder_bookmark_max)
    local out_error = ffi.new("char[?]", external_folder_error_max)
    local ok, resolved = pcall(function()
        return tonumber(ffi.C.KOIOSResolveExternalFolderBookmark(
            bookmark,
            out_path, external_folder_path_max,
            out_bookmark, external_folder_bookmark_max,
            out_error, external_folder_error_max
        )) ~= 0
    end)
    if not ok then
        return nil, "iOS bridge is not available"
    end
    if not resolved then
        return nil, ffi.string(out_error)
    end
    local refreshed_bookmark = ffi.string(out_bookmark)
    if refreshed_bookmark == "" then
        refreshed_bookmark = nil
    end
    return ffi.string(out_path), nil, refreshed_bookmark
end

function ios.releaseExternalFolderBookmark(bookmark)
    return cint(function() return ffi.C.KOIOSReleaseExternalFolderBookmark(bookmark) end, false)
end

return ios
