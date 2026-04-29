local SDLDevice = require("device/sdl/device")
local Geom = require("ui/geometry")
local ios = require("ios")
local logger = require("logger")

local function yes() return true end
local function no() return false end

local Device = SDLDevice:extend{
    model = "iOS",
    isIOS = yes,
    isDesktop = no,
    isDefaultFullscreen = yes,
    hasKeys = no,
    hasKeyboard = no,
    hasDPad = no,
    canRestart = no,
    hasExitOptions = no,
    canSuspend = yes,
    canStandby = no,
    hasSystemFonts = no,
    hasOTAUpdates = no,
    home_dir = ios.getDocumentsPath(),
    canOpenLink = yes,
    openLink = function(_, link)
        return ios.openLink(link)
    end,
    canExternalDictLookup = no,
    canImportFiles = yes,
    canShareText = ios.canShareText,
    shareText = function(_, text, reason, title, mimetype)
        return ios.shareText(text, reason, title, mimetype)
    end,
    requestPluginZipImport = function()
        return ios.requestPluginZipImport()
    end,
    getPluginZipImportResult = function()
        return ios.getPluginZipImportResult()
    end,
}

function Device:init()
    SDLDevice.init(self)
    self.hasClipboard = yes
    self:applySafeAreaViewport()
end

function Device:applySafeAreaViewport()
    local insets = ios.getSafeAreaInsets()
    logger.info(string.format("iOS safe area insets: top=%d right=%d bottom=%d left=%d",
        insets.top, insets.right, insets.bottom, insets.left))
    if insets.top == 0 and insets.right == 0 and insets.bottom == 0 and insets.left == 0 then
        return
    end

    local screen_w = self.screen:getScreenWidth()
    local screen_h = self.screen:getScreenHeight()
    local viewport = Geom:new{
        x = insets.left,
        y = insets.top,
        w = screen_w - insets.left - insets.right,
        h = screen_h - insets.top - insets.bottom,
    }
    if viewport.w <= 0 or viewport.h <= 0 then
        logger.warn(string.format("Ignoring invalid iOS safe area viewport: x=%d y=%d w=%d h=%d",
            viewport.x, viewport.y, viewport.w, viewport.h))
        return
    end
    if self.viewport
    and self.viewport.x == viewport.x
    and self.viewport.y == viewport.y
    and self.viewport.w == viewport.w
    and self.viewport.h == viewport.h then
        return
    end

    logger.info(string.format("iOS safe area viewport: x=%d y=%d w=%d h=%d",
        viewport.x, viewport.y, viewport.w, viewport.h))
    self.viewport = viewport
    self.screen:setViewport(viewport)
    if self.screen.full_bb and self.screen._render then
        self.screen.full_bb:fill(require("ffi/blitbuffer").COLOR_WHITE)
        self.screen:_render(self.screen.full_bb, 0, 0, screen_w, screen_h)
    end
    if not self.ios_safe_area_input_adjusted then
        self.input:registerEventAdjustHook(
            self.input.adjustTouchTranslate,
            { x = 0 - viewport.x, y = 0 - viewport.y }
        )
        self.ios_safe_area_input_adjusted = true
    end
    if self.uimgr then
        self.uimgr:setDirty("all", "full")
    end
end

function Device:UIManagerReady(uimgr)
    SDLDevice.UIManagerReady(self, uimgr)
    self.uimgr = uimgr
    logger.info("iOS UIManager ready; enabling settings flush")
    self:flushSettingsForIOS("startup")
    uimgr:scheduleIn(0.5, function() self:applySafeAreaViewport() end)
    uimgr:scheduleIn(1.5, function() self:applySafeAreaViewport() end)
    uimgr:scheduleIn(5, function() self:flushSettingsForIOSPeriodically() end)
end

function Device:flushSettingsForIOS(reason)
    if self.uimgr then
        self.uimgr:flushSettings()
    end
    if G_reader_settings then
        logger.info("iOS settings flush:", reason or "manual", G_reader_settings.file or "unknown")
        local ok, err = pcall(function() G_reader_settings:flush() end)
        if not ok then
            logger.warn("iOS settings flush failed:", err)
        end
    else
        logger.warn("iOS settings flush skipped: G_reader_settings is nil")
    end
end

function Device:flushSettingsForIOSPeriodically()
    self:flushSettingsForIOS("periodic")
    if self.uimgr then
        self.uimgr:scheduleIn(5, function() self:flushSettingsForIOSPeriodically() end)
    end
end

function Device:simulateSuspend()
    logger.info("iOS app entering background; flushing settings")
    self:flushSettingsForIOS("suspend")
    self:_beforeSuspend(false)
end

function Device:simulateResume()
    logger.info("iOS app entering foreground")
    self.powerd:invalidateCapacityCache()
    self:_afterResume(false)
end

function Device:getClipboardText()
    return ios.getClipboardText()
end

function Device:setClipboardText(text)
    return ios.setClipboardText(text)
end

function Device:otaModel()
    return nil, nil
end

return Device
