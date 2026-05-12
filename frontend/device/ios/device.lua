local SDLDevice = require("device/sdl/device")
local Event = require("ui/event")
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
    canBackgroundRerender = no,
    canRunInSubProcess = no,
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
    consumePluginZipImportResult = function()
        return ios.consumePluginZipImportResult()
    end,
}

function Device:init()
    SDLDevice.init(self)
    self.hasClipboard = yes
    self:applySafeAreaViewport()
end

function Device:applySafeAreaViewport()
    local insets = ios.getSafeAreaInsets()
    insets.top = math.max(0, tonumber(insets.top) or 0)
    insets.right = math.max(0, tonumber(insets.right) or 0)
    insets.bottom = math.max(0, tonumber(insets.bottom) or 0)
    insets.left = math.max(0, tonumber(insets.left) or 0)
    local previous_insets = self.ios_safe_area_insets or { top = 0, right = 0, bottom = 0, left = 0 }
    local insets_changed = previous_insets.top ~= insets.top
        or previous_insets.right ~= insets.right
        or previous_insets.bottom ~= insets.bottom
        or previous_insets.left ~= insets.left

    local screen_w = self.screen:getScreenWidth()
    local screen_h = self.screen:getScreenHeight()
    local viewport = Geom:new{
        x = insets.left,
        y = insets.top,
        w = screen_w - insets.left - insets.right,
        h = screen_h - insets.top,
    }
    if viewport.w <= 0 or viewport.h <= 0 then
        logger.warn(string.format("Ignoring invalid iOS safe area viewport: x=%d y=%d w=%d h=%d",
            viewport.x, viewport.y, viewport.w, viewport.h))
        return
    end
    self.ios_safe_area_insets = insets
    logger.info(string.format("iOS safe area insets: top=%d right=%d bottom=%d left=%d",
        insets.top, insets.right, insets.bottom, insets.left))
    local viewport_changed = not self.viewport
        or self.viewport.x ~= viewport.x
        or self.viewport.y ~= viewport.y
        or self.viewport.w ~= viewport.w
        or self.viewport.h ~= viewport.h
    if not viewport_changed and not insets_changed then
        return
    end

    if viewport_changed then
        logger.info(string.format("iOS safe area viewport: x=%d y=%d w=%d h=%d",
            viewport.x, viewport.y, viewport.w, viewport.h))
        self.viewport = viewport
        self.screen:setViewport(viewport)
        if self.screen.full_bb and self.screen._render then
            self.screen.full_bb:fill(require("ffi/blitbuffer").COLOR_WHITE)
            self.screen:_render(self.screen.full_bb, 0, 0, screen_w, screen_h)
        end
    end

    self.ios_safe_area_input_offset = self.ios_safe_area_input_offset or { x = 0, y = 0 }
    self.ios_safe_area_input_offset.x = 0 - viewport.x
    self.ios_safe_area_input_offset.y = 0 - viewport.y
    if not self.ios_safe_area_input_adjusted then
        self.input:registerEventAdjustHook(
            self.input.adjustTouchTranslate,
            self.ios_safe_area_input_offset
        )
        self.ios_safe_area_input_adjusted = true
    end

    if self.uimgr then
        local usable_size = self:getReaderUsableScreenSize()
        self.uimgr:broadcastEvent(Event:new("SetDimensions", usable_size))
        self.uimgr:broadcastEvent(Event:new("ScreenResize", usable_size))
        self.uimgr:broadcastEvent(Event:new("RedrawCurrentPage"))
        self.uimgr:setDirty("all", "full")
    end
end

function Device:getSafeAreaInsets()
    return self.ios_safe_area_insets or { top = 0, right = 0, bottom = 0, left = 0 }
end

function Device:getBottomSafeAreaInset()
    return self:getSafeAreaInsets().bottom or 0
end

function Device:getTopSafeAreaInset()
    return self:getSafeAreaInsets().top or 0
end

function Device:getReaderUsableScreenSize()
    return Geom:new{
        w = self.screen:getWidth(),
        h = self.screen:getHeight() - self:getBottomSafeAreaInset(),
    }
end

function Device:scheduleIOSSettingsFlush()
    if self.uimgr and not self.ios_settings_flush_scheduled then
        self.ios_settings_flush_scheduled = true
        self.uimgr:scheduleIn(5, function() self:flushSettingsForIOSPeriodically() end)
    end
end

function Device:UIManagerReady(uimgr)
    SDLDevice.UIManagerReady(self, uimgr)
    self.uimgr = uimgr
    logger.info("iOS UIManager ready; enabling settings flush")
    self:flushSettingsForIOS("startup")
    uimgr:scheduleIn(0.5, function() self:applySafeAreaViewport() end)
    uimgr:scheduleIn(1.5, function() self:applySafeAreaViewport() end)
    self:scheduleIOSSettingsFlush()
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
    self.ios_settings_flush_scheduled = false
    self:flushSettingsForIOS("periodic")
    self:scheduleIOSSettingsFlush()
end

function Device:simulateSuspend()
    logger.info("iOS app entering background; flushing settings")
    self:flushSettingsForIOS("suspend")
    self:_beforeSuspend(false)
end

function Device:simulateResume()
    logger.info("iOS app entering foreground")
    if self.powerd and self.powerd.invalidateCapacityCache then
        self.powerd:invalidateCapacityCache()
    end
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
