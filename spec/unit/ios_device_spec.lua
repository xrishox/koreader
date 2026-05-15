describe("iOS device geometry", function()
    local function withIOSDevice(initial_insets, fn)
        local saved = {
            ios = package.loaded.ios,
            sdl_device = package.loaded["device/sdl/device"],
            sdl = package.loaded["ffi/SDL3"],
            ios_device = package.loaded["device/ios/device"],
            filemanager = package.loaded["apps/filemanager/filemanager"],
        }

        local fake_ios = { insets = initial_insets }
        function fake_ios.getDocumentsPath() return "." end
        function fake_ios.getSafeAreaInsets() return fake_ios.insets end
        function fake_ios.canShareText() return false end
        function fake_ios.shareText(text, reason, title, mimetype)
            fake_ios.shared_text = {
                text = text,
                reason = reason,
                title = title,
                mimetype = mimetype,
            }
            return true
        end

        local fake_sdl = {
            SDL = {
                SDL_EVENT_WINDOW_RESIZED = 518,
                SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED = 519,
                SDL_EVENT_DISPLAY_ORIENTATION = 337,
                SDL_EVENT_DISPLAY_USABLE_BOUNDS_CHANGED = 344,
            },
        }

        local fake_sdl_device = {
            init = function() end,
            UIManagerReady = function() end,
            _resizeSDLWindow = function(self, ev)
                self.resize_count = (self.resize_count or 0) + 1
                if ev and ev.code == fake_sdl.SDL.SDL_EVENT_WINDOW_RESIZED and ev.value then
                    self.screen:setRawSize(ev.value.data1, ev.value.data2)
                end
                return self.screen:getSize()
            end,
        }
        function fake_sdl_device:extend(o)
            o = o or {}
            for k, v in pairs(self) do
                if o[k] == nil then
                    o[k] = v
                end
            end
            o.parent = self
            o.__index = o
            function o:new(instance)
                instance = instance or {}
                setmetatable(instance, o)
                if instance.init then instance:init() end
                return instance
            end
            return o
        end

        package.loaded.ios = fake_ios
        package.loaded["ffi/SDL3"] = fake_sdl
        package.loaded["device/sdl/device"] = fake_sdl_device
        package.loaded["device/ios/device"] = nil
        package.loaded["apps/filemanager/filemanager"] = { instance = nil }

        local ok, err = pcall(function()
            fn(require("device/ios/device"), fake_ios, fake_sdl)
        end)

        package.loaded.ios = saved.ios
        package.loaded["ffi/SDL3"] = saved.sdl
        package.loaded["device/sdl/device"] = saved.sdl_device
        package.loaded["device/ios/device"] = saved.ios_device
        package.loaded["apps/filemanager/filemanager"] = saved.filemanager
        assert.is_true(ok, err)
    end

    local function newScreen(w, h)
        local screen = {
            raw_w = w,
            raw_h = h,
            width = w,
            height = h,
            viewports = {},
        }
        function screen:getScreenWidth() return self.raw_w end
        function screen:getScreenHeight() return self.raw_h end
        function screen:getWidth() return self.width end
        function screen:getHeight() return self.height end
        function screen:getSize() return { w = self.width, h = self.height } end
        function screen:setRawSize(new_w, new_h)
            self.raw_w = new_w
            self.raw_h = new_h
            self.width = new_w
            self.height = new_h
        end
        function screen:setViewport(viewport)
            table.insert(self.viewports, viewport)
            self.width = viewport.w
            self.height = viewport.h
            self.viewport = viewport
        end
        return screen
    end

    local function newInput()
        return {
            hook_count = 0,
            reset_count = 0,
            adjustTouchTranslate = function() end,
            registerEventAdjustHook = function(self, _, params)
                self.hook_count = self.hook_count + 1
                self.hook_params = params
            end,
            resetState = function(self)
                self.reset_count = self.reset_count + 1
            end,
        }
    end

    it("updates the safe-area viewport and reuses the input translation hook", function()
        withIOSDevice({ top = 30, right = 6, bottom = 20, left = 5 }, function(Device, ios)
            local input = newInput()
            local device = Device:new{
                screen = newScreen(300, 600),
                input = input,
            }

            assert.are.equals(5, device.viewport.x)
            assert.are.equals(30, device.viewport.y)
            assert.are.equals(289, device.viewport.w)
            assert.are.equals(570, device.viewport.h)
            assert.are.equals(-5, input.hook_params.x)
            assert.are.equals(-30, input.hook_params.y)
            assert.are.equals(1, input.hook_count)

            device.screen:setRawSize(600, 300)
            ios.insets = { top = 0, right = 20, bottom = 10, left = 20 }
            assert.is_true(device:applySafeAreaViewport("test"))

            assert.are.equals(20, device.viewport.x)
            assert.are.equals(0, device.viewport.y)
            assert.are.equals(560, device.viewport.w)
            assert.are.equals(300, device.viewport.h)
            assert.are.equals(-20, input.hook_params.x)
            assert.are.equals(0, input.hook_params.y)
            assert.are.equals(1, input.hook_count)
            assert.are.equals(290, device:getReaderUsableScreenSize().h)
        end)
    end)

    it("hides unsupported user-facing iOS actions", function()
        withIOSDevice({ top = 0, right = 0, bottom = 0, left = 0 }, function(Device, ios)
            assert.is_false(Device:canSuspend())
            assert.is_false(Device:canExecuteScript("script.sh"))
            assert.is_function(Device.doShareText)

            assert.is_true(Device:doShareText("text", "reason", "title", "text/plain"))
            assert.are.equals("text", ios.shared_text.text)
            assert.are.equals("reason", ios.shared_text.reason)
            assert.are.equals("title", ios.shared_text.title)
            assert.are.equals("text/plain", ios.shared_text.mimetype)
        end)
    end)

    it("keeps native iOS lifecycle suspend and resume handlers", function()
        withIOSDevice({ top = 0, right = 0, bottom = 0, left = 0 }, function(Device)
            local calls = {}
            local device = Device:new{
                screen = newScreen(300, 600),
                input = newInput(),
            }
            device._beforeSuspend = function(_, inhibit)
                calls[#calls + 1] = { event = "suspend", inhibit = inhibit }
            end
            device._afterResume = function(_, inhibit)
                calls[#calls + 1] = { event = "resume", inhibit = inhibit }
            end

            local uimgr = { event_handlers = {} }
            device:setEventHandlers(uimgr)
            assert.is_function(uimgr.event_handlers.Suspend)
            assert.is_function(uimgr.event_handlers.Resume)

            uimgr.event_handlers.Suspend()
            uimgr.event_handlers.Resume()

            assert.are.equals("suspend", calls[1].event)
            assert.is_false(calls[1].inhibit)
            assert.are.equals("resume", calls[2].event)
            assert.is_false(calls[2].inhibit)
        end)
    end)

    it("reserves only the footer height that extends above the bottom unsafe area", function()
        withIOSDevice({ top = 30, right = 0, bottom = 20, left = 0 }, function(Device)
            local device = Device:new{
                screen = newScreen(300, 600),
                input = newInput(),
            }

            assert.are.equals(0, device:getReaderFooterReservedHeight(10))
            assert.are.equals(0, device:getReaderFooterReservedHeight(20))
            assert.are.equals(10, device:getReaderFooterReservedHeight(30))
            assert.are.equals(0, device:getReaderFooterReservedHeight(nil))
        end)
    end)

    it("resizes before broadcasting iOS geometry changes", function()
        withIOSDevice({ top = 30, right = 0, bottom = 20, left = 0 }, function(Device, ios, SDL)
            local input = newInput()
            local scheduled = {}
            local broadcasts = {}
            local uimgr = {
                broadcastEvent = function(_, ev) table.insert(broadcasts, ev) end,
                setDirty = function() end,
                scheduleIn = function(_, delay, callback)
                    table.insert(scheduled, { delay = delay, callback = callback })
                end,
            }
            local device = Device:new{
                screen = newScreen(300, 600),
                input = input,
            }
            device.uimgr = uimgr

            ios.insets = { top = 0, right = 20, bottom = 10, left = 20 }
            device:onSDLWindowGeometryChanged{
                code = SDL.SDL.SDL_EVENT_WINDOW_RESIZED,
                value = { data1 = 600, data2 = 300 },
            }

            assert.are.equals(1, input.reset_count)
            assert.are.equals(1, device.resize_count)
            assert.are.equals(560, device.viewport.w)
            assert.are.equals(300, device.viewport.h)
            assert.are.equals(2, #scheduled)
            assert.are.equals("onSetDimensions", broadcasts[1].handler)
            assert.are.equals(560, broadcasts[1].args[1].w)
            assert.are.equals(290, broadcasts[1].args[1].h)
            assert.are.equals("onScreenResize", broadcasts[2].handler)
            assert.are.equals("onRedrawCurrentPage", broadcasts[3].handler)
        end)
    end)

    it("keeps a safe-area broadcast pending until UI windows exist", function()
        withIOSDevice({ top = 30, right = 0, bottom = 20, left = 0 }, function(Device)
            local broadcasts = {}
            local dirty_count = 0
            local uimgr = {
                _window_stack = {},
                broadcastEvent = function(_, ev) table.insert(broadcasts, ev) end,
                setDirty = function() dirty_count = dirty_count + 1 end,
            }
            local device = Device:new{
                screen = newScreen(300, 600),
                input = newInput(),
            }

            assert.is_true(device.ios_safe_area_broadcast_pending)
            device.uimgr = uimgr

            assert.is_true(device:applySafeAreaViewport("pending", true))
            assert.is_true(device.ios_safe_area_broadcast_pending)
            assert.are.equals(0, #broadcasts)

            table.insert(uimgr._window_stack, { widget = {} })

            assert.is_true(device:applySafeAreaViewport("pending", true))
            assert.is_false(device.ios_safe_area_broadcast_pending)
            assert.are.equals("onSetDimensions", broadcasts[1].handler)
            assert.are.equals("onScreenResize", broadcasts[2].handler)
            assert.are.equals("onRedrawCurrentPage", broadcasts[3].handler)
            assert.are.equals(1, dirty_count)
        end)
    end)

    it("forces an immediate repaint after changing a visible iOS viewport", function()
        withIOSDevice({ top = 0, right = 0, bottom = 0, left = 0 }, function(Device, ios)
            local repaint_count = 0
            local uimgr = {
                _window_stack = { { widget = {} } },
                broadcastEvent = function() end,
                setDirty = function() end,
                forceRePaint = function() repaint_count = repaint_count + 1 end,
            }
            local device = Device:new{
                screen = newScreen(300, 600),
                input = newInput(),
            }
            device.uimgr = uimgr
            ios.insets = { top = 30, right = 0, bottom = 20, left = 0 }

            assert.is_true(device:applySafeAreaViewport("visible change"))
            assert.are.equals(1, repaint_count)
            assert.is_false(device.ios_safe_area_broadcast_pending)
        end)
    end)
end)
