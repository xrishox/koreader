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
    ffi.C.KOIOSGetSafeAreaInsets(top, right, bottom, left)
    return {
        top = tonumber(top[0]),
        right = tonumber(right[0]),
        bottom = tonumber(bottom[0]),
        left = tonumber(left[0]),
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
    local status = tonumber(ffi.C.KOIOSGetPluginZipImportStatus())
    if status == 1 then
        return "pending"
    elseif status == 2 then
        return "ok", cstring(function() return ffi.C.KOIOSGetPluginZipImportPath() end, "")
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

return ios
