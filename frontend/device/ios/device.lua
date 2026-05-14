local SDLDevice = require("device/sdl/device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local SDL = require("ffi/SDL3")
local ios = require("ios")
local logger = require("logger")

local function yes() return true end
local function no() return false end
local safe_area_refresh_delays = { 0.1, 0.5 }

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
    self:applySafeAreaViewport("init")
end

local function normalizeInsets(insets)
    insets = insets or {}
    return {
        top = math.max(0, tonumber(insets.top) or 0),
        right = math.max(0, tonumber(insets.right) or 0),
        bottom = math.max(0, tonumber(insets.bottom) or 0),
        left = math.max(0, tonumber(insets.left) or 0),
    }
end

local function sameInsets(a, b)
    return a.top == b.top
        and a.right == b.right
        and a.bottom == b.bottom
        and a.left == b.left
end

local function sameViewport(a, b)
    return a and b
        and a.x == b.x
        and a.y == b.y
        and a.w == b.w
        and a.h == b.h
end

function Device:_hasVisibleUI()
    if not self.uimgr then
        return false
    end
    if self.uimgr.getTopmostVisibleWidget then
        return self.uimgr:getTopmostVisibleWidget() ~= nil
    end
    if self.uimgr._window_stack then
        return #self.uimgr._window_stack > 0
    end
    return true
end

function Device:_broadcastIOSGeometryChanged()
    if not self.uimgr or not self:_hasVisibleUI() then
        self.ios_safe_area_broadcast_pending = true
        return false
    end
    local usable_size = self:getReaderUsableScreenSize()
    self.uimgr:broadcastEvent(Event:new("SetDimensions", usable_size))
    self.uimgr:broadcastEvent(Event:new("ScreenResize", usable_size))
    self.uimgr:broadcastEvent(Event:new("RedrawCurrentPage"))

    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance:reinit(FileManager.instance.path,
            FileManager.instance.focused_file)
    end

    self.uimgr:setDirty("all", "full")
    self.ios_safe_area_broadcast_pending = false
    return true
end

function Device:applySafeAreaViewport(reason, force_broadcast)
    local insets = ios.getSafeAreaInsets()
    insets = normalizeInsets(insets)
    local previous_insets = self.ios_safe_area_insets or { top = 0, right = 0, bottom = 0, left = 0 }
    local insets_changed = not sameInsets(previous_insets, insets)

    local screen_w = self.screen:getScreenWidth()
    local screen_h = self.screen:getScreenHeight()
    local previous_screen_size = self.ios_safe_area_screen_size or { w = 0, h = 0 }
    local screen_size_changed = previous_screen_size.w ~= screen_w
        or previous_screen_size.h ~= screen_h
    local viewport = Geom:new{
        x = insets.left,
        y = insets.top,
        w = screen_w - insets.left - insets.right,
        h = screen_h - insets.top,
    }
    if viewport.w <= 0 or viewport.h <= 0 then
        logger.warn(string.format("Ignoring invalid iOS safe area viewport: x=%d y=%d w=%d h=%d",
            viewport.x, viewport.y, viewport.w, viewport.h))
        return false
    end
    local viewport_changed = not sameViewport(self.viewport, viewport)
    local broadcast_pending = self.ios_safe_area_broadcast_pending
    if not viewport_changed and not insets_changed and not screen_size_changed
        and not force_broadcast and not broadcast_pending then
        return false
    end

    self.ios_safe_area_insets = insets
    self.ios_safe_area_screen_size = { w = screen_w, h = screen_h }
    logger.info(string.format("iOS safe area insets (%s): top=%d right=%d bottom=%d left=%d",
        reason or "refresh", insets.top, insets.right, insets.bottom, insets.left))

    if viewport_changed then
        logger.info(string.format("iOS safe area viewport: x=%d y=%d w=%d h=%d",
            viewport.x, viewport.y, viewport.w, viewport.h))
        self.viewport = viewport
        self.screen:setViewport(viewport)
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

    local broadcasted = self:_broadcastIOSGeometryChanged()
    if viewport_changed and broadcasted and self.uimgr.forceRePaint then
        self.uimgr:forceRePaint()
    end
    return true
end

function Device:scheduleSafeAreaViewportRefresh(reason, force_broadcast)
    self.ios_safe_area_refresh_generation = (self.ios_safe_area_refresh_generation or 0) + 1
    local generation = self.ios_safe_area_refresh_generation
    self:applySafeAreaViewport(reason, force_broadcast)
    if not self.uimgr then
        return
    end
    for _, delay in ipairs(safe_area_refresh_delays) do
        self.uimgr:scheduleIn(delay, function()
            if generation == self.ios_safe_area_refresh_generation then
                self:applySafeAreaViewport(reason, self.ios_safe_area_broadcast_pending)
            end
        end)
    end
end

function Device:_schedulePendingSafeAreaBroadcast(reason)
    if not self.uimgr then
        return
    end
    local attempts_left = 12
    local retry
    retry = function()
        self:applySafeAreaViewport(reason, self.ios_safe_area_broadcast_pending)
        attempts_left = attempts_left - 1
        if self.ios_safe_area_broadcast_pending and attempts_left > 0 then
            self.uimgr:scheduleIn(0.25, retry)
        end
    end
    if self.uimgr.nextTick then
        self.uimgr:nextTick(retry)
    else
        retry()
    end
end

function Device:onSDLWindowGeometryChanged(ev)
    local code = ev.code
    if self.input and self.input.resetState then
        self.input:resetState()
    end
    if code == SDL.SDL.SDL_EVENT_WINDOW_RESIZED
        or code == SDL.SDL.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED
        or code == SDL.SDL.SDL_EVENT_DISPLAY_ORIENTATION
        or code == SDL.SDL.SDL_EVENT_DISPLAY_USABLE_BOUNDS_CHANGED then
        self:_resizeSDLWindow(ev)
    end
    self:scheduleSafeAreaViewportRefresh("sdl event " .. tostring(code))
    return true
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

function Device:getReaderFooterReservedHeight(footer_reserved_height)
    footer_reserved_height = math.max(0, tonumber(footer_reserved_height) or 0)
    return math.max(0, footer_reserved_height - self:getBottomSafeAreaInset())
end

function Device:getReaderUsableScreenSize()
    return Geom:new{
        w = self.screen:getWidth(),
        h = math.max(1, self.screen:getHeight() - self:getBottomSafeAreaInset()),
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
    self:scheduleSafeAreaViewportRefresh("startup delayed", true)
    self:_schedulePendingSafeAreaBroadcast("startup pending")
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
