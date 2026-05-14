# KOReader iOS Port Rebase Guide

This document records what this iOS port changed relative to upstream KOReader,
why those changes exist, which constraints are real iOS limitations, and what
to preserve or reconsider when rebasing onto newer upstream KOReader and
KOReader base.

It is intended for maintainers doing future upstream rebases. It is not a user
build guide. For build commands, see `platform/ios/BUILDING.md`.

## Baselines

The iOS branch was originally audited against:

- KOReader parent baseline: `v2026.03`
- KOReader base submodule baseline:
  `7a46ea3812539083ee25b06f0c81ac58b1356ee0`

The current iOS branch includes:

- Parent iOS branch head at the time of this guide:
  `49b340c01db76bb1eb248fbdce6bf53107a57736`
- Base iOS branch head at the time of this guide:
  `eba9182113391142d7d83019b366d4a0da548e99`

The iOS branch also changes `.gitmodules` so the `base` submodule is fetched
from the iOS base fork. That is currently required because several iOS build
and runtime changes live in `base`, not only in the parent KOReader tree.

## Rebase Goal

When rebasing, the goal is not to preserve every fork diff blindly. The goal is
to keep KOReader working on iOS while minimizing long-term fork drift.

Use these categories when resolving conflicts:

- Required iOS adaptation: keep it unless upstream now provides an equivalent.
- Upstream-compatible change: prefer upstream if it has landed there.
- Temporary workaround: keep only while the underlying iOS build/runtime issue
  still exists.
- Candidate to remove: delete if upstream now handles it cleanly.
- Known limitation: document clearly rather than hiding behind accidental
  breakage.

Avoid broad refactors during a rebase. Prefer upstream structure and patch only
the iOS-specific behavior that cannot be expressed through existing hooks.

## iOS Constraints

These constraints are the reason most of the port exists:

- The app bundle is read-only at runtime.
- User data must live in the app container, mainly Documents and Application
  Support.
- Physical-device apps must be signed, and embedded native code must be part of
  the signed app bundle. User-installed unsigned `.dylib` or `.so` plugin code
  should not be expected to load.
- iOS apps cannot rely on shell utilities such as `cp`, `mv`, `zip`, or
  Ghostscript helpers.
- iOS apps cannot rely on `fork`/subprocess behavior used by desktop KOReader.
- LuaJIT must run in interpreter mode. iOS does not allow normal apps to create
  arbitrary executable JIT memory.
- UIKit must provide the launchable application shell, safe-area information,
  file picker, clipboard, sharing, and external URL opening.
- Simulator and device builds are not interchangeable, even when both are
  `arm64`.

## Parent Repository Changes

### Submodule Source

Files:

- `.gitmodules`
- `base`

The parent repo points the `base` submodule at the iOS base fork. This is not
ideal, but it is currently necessary because the parent-only changes do not
cover iOS cross-compilation, native library loading, LuaJIT build behavior, SDL
lifecycle events, or iOS-incompatible subprocess/shell behavior.

Rebase guidance:

- Keep the iOS base fork until all required base changes are upstreamed or
  otherwise replaced.
- When moving parent KOReader forward, update the base fork first or in lockstep.
- Verify that a fresh clone with submodules fetches the intended base commit.

### iOS Build And Packaging

Files:

- `Makefile`
- `kodev`
- `make/ios.mk`
- `platform/ios/Info.plist`
- `platform/ios/native/CMakeLists.txt`
- `platform/ios/native/LaunchScreen.storyboard`
- `platform/ios/icons/*`
- `tools/mkrelease.sh`

The parent build now recognizes iOS targets:

- `ios-arm64` for physical devices
- `ios-sim-arm64` for Apple Silicon simulator

`make/ios.mk` builds the normal KOReader payload, builds a small native iOS
host with CMake, copies the payload into `KOReader.app/reader`, writes bundle
metadata, and packages `Payload/KOReader.app` into an IPA.

Important design decisions:

- Build output names include the iOS SDK family so `iphoneos` and
  `iphonesimulator` artifacts do not collide.
- Hardware output is unsigned. Signing is intentionally local to the developer
  because Apple identities and provisioning profiles are account-specific.
- Fonts are copied instead of symlinked into the app payload. Symlinks inside
  the final iOS bundle are a packaging/signing risk.
- Several plugins and tools are excluded from iOS release packaging when they
  depend on unsupported behavior.
- `tools/mkrelease.sh` accepts `7zz` as well as `7z`, which is useful on modern
  macOS/Homebrew installations.

Rebase guidance:

- Preserve simulator/device output separation.
- Preserve copied resources where iOS signing or bundle portability requires
  real files.
- Recheck release excludes after upstream plugin changes. Do not exclude a
  plugin merely because it is inconvenient; exclude it only if it is genuinely
  incompatible with iOS or the current port.

### Native UIKit Host

Files:

- `platform/ios/native/KOReaderIOSMain.m`
- `platform/ios/ios.lua`

KOReader is not rewritten as a UIKit app. UIKit only provides the iOS app shell
and native OS integrations. The Objective-C host starts LuaJIT, changes into
the bundled `reader` directory, sets iOS path environment variables, creates a
Lua state, and runs `reader.lua`.

The bridge exposes C-callable functions that Lua reaches through FFI:

- bundle path
- resource path
- Documents path
- Application Support path
- native library directory
- safe-area insets
- external URL opening
- clipboard read/write
- share sheet
- plugin ZIP document picker

Design decisions:

- The bridge returns retained UTF-8 strings so Lua FFI callers are not handed
  pointers to short-lived Objective-C objects.
- UIKit operations are dispatched to the main thread where required.
- Plugin ZIP selection copies the chosen security-scoped file into a temporary
  app-controlled location before Lua processes it.
- The bridge keeps plugin picker state explicitly: idle, pending, finished,
  cancelled, failed.

Rebase guidance:

- Keep the native bridge small. Do not move reader logic into Objective-C.
- Preserve security-scoped file access for document picker imports.
- Preserve the temporary-copy model for plugin ZIPs. Lua should not process
  external provider URLs directly.
- If adding more bridge APIs, expose narrow operations rather than UIKit objects.

### Data And Module Paths

Files:

- `datastorage.lua`
- `setupkoenv.lua`
- `platform/ios/ios.lua`

iOS needs KOReader data outside the app bundle. The port maps:

- bundled runtime/resources: `KOReader.app/reader`
- user-visible files: iOS Documents
- settings/cache/plugins: Application Support, under `KOReader/koreader`
- native libraries: `KOReader.app/reader/libs`

`setupkoenv.lua` adds iOS-specific Lua and native module search paths,
including `.dylib` paths under `libs`.

Rebase guidance:

- Do not let KOReader write settings or plugins into the app bundle.
- Keep resource and data paths distinct.
- If upstream changes `datastorage.lua`, preserve iOS as an early platform
  detection path without introducing recursive device dependencies.

### Device Abstraction

Files:

- `frontend/device.lua`
- `frontend/device/generic/device.lua`
- `frontend/device/ios/device.lua`
- `frontend/device/sdl/device.lua`

The iOS device extends the existing SDL device rather than creating a separate
rendering/input stack.

iOS overrides these capabilities:

- `isIOS = true`
- no KOReader-managed restart/poweroff/OTA
- no hardware keyboard/D-pad assumptions
- no external dictionary lookup
- no background rerendering
- no subprocess support
- native clipboard/link/share support
- plugin ZIP import support

Lifecycle behavior:

- SDL iOS foreground/background events are converted to KOReader suspend/resume.
- On startup, backgrounding, and periodically while running, settings are
  flushed. This reduces data-loss risk because iOS may suspend or kill apps
  without the same exit path desktop KOReader expects.

Rebase guidance:

- Preserve `canRunInSubProcess = false` and `canBackgroundRerender = false`
  unless the specific codepaths are proven safe on iOS.
- Keep lifecycle settings flushes deliberate. Do not rely only on normal
  KOReader shutdown.
- If upstream adds generic app lifecycle hooks, migrate to those hooks rather
  than keeping duplicate iOS-only scheduling.

### Safe Area And Reader Layout

Files:

- `frontend/device/ios/device.lua`
- `frontend/apps/reader/modules/readerfooter.lua`
- `frontend/apps/reader/modules/readerhighlight.lua`
- `frontend/apps/reader/modules/readermenu.lua`
- `frontend/apps/reader/modules/readerpagemap.lua`
- `frontend/apps/reader/modules/readerrolling.lua`
- `frontend/apps/reader/modules/readertypeset.lua`
- `frontend/apps/reader/modules/readerview.lua`
- `frontend/apps/reader/modules/readerzooming.lua`
- `frontend/apps/reader/readerui.lua`
- `frontend/apps/filemanager/filemanagermenu.lua`

Modern iPhones have unsafe display regions: Dynamic Island/notch, rounded
corners, and the home indicator. SDL renders fullscreen, so KOReader must apply
safe-area constraints itself.

The iOS device reads UIKit safe-area insets, converts them from points to
framebuffer pixels, applies a framebuffer viewport, and registers an input
translation hook so touch coordinates still match the visible KOReader UI.

The reader footer changes distinguish:

- full footer widget height, including iOS-only padding
- reserved document height, excluding padding that only protects the home
  indicator

That distinction prevents the document layout from losing too much vertical
space while still keeping footer text and progress bars above the home
indicator.

Additional top unsafe-area tap zones route taps in the notch/top inset region to
the menu. This keeps the app usable when UIKit reports a top safe area but the
SDL viewport has shifted input.

Rebase guidance:

- Preserve the distinction between `getHeight()` and `getReservedHeight()`.
- Any upstream footer/status-bar changes must be checked for whether they use
  physical widget height or document-reserved height.
- Re-test both portrait and landscape on devices with bottom safe areas.
- Watch for negative widths after upstream layout changes; the iOS code clamps
  widths to avoid invalid widget geometry.

### File Manager Copy And Move

Files:

- `frontend/apps/filemanager/filemanager.lua`
- `spec/unit/filemanager_spec.lua`

Upstream file operations use shell commands (`cp`, `mv`). iOS cannot rely on
those. The port adds Lua/FFI file operations for iOS:

- direct `os.rename` for moves when possible
- copy/delete fallback for cross-device moves
- recursive directory copy without shelling out
- temporary file path for safer file copy
- cleanup of partial temp files on failure
- protection against copying a directory into itself
- rejection of symlink copies
- destination semantics matching shell behavior when the target is a directory

Rebase guidance:

- Prefer upstream file-manager structure, but preserve iOS-specific no-shell
  behavior.
- If upstream adds a generic file operation abstraction, move the iOS operations
  into that rather than maintaining a separate forked block.
- Keep tests for partial-copy cleanup and self-copy prevention.

### Plugin Management

Files:

- `frontend/pluginloader.lua`
- `frontend/pluginpackagemanager.lua`
- `spec/unit/pluginloader_spec.lua`
- `spec/unit/pluginpackagemanager_spec.lua`

iOS plugin management has two separate concerns:

- KOReader plugin discovery and enable/disable state.
- Installing/removing user plugin packages from the writable iOS app container.

The iOS package manager supports:

- native iOS ZIP selection through the document picker
- ZIPs with a top-level `*.koplugin` directory
- flat ZIPs with `main.lua` at archive root
- GitHub-style ZIPs with one wrapper directory containing `main.lua`
- replacement with rollback if activation fails
- listing only user-installed plugins
- removing inactive user plugins immediately
- marking active user plugins for removal on restart
- cleanup of pending removals before plugin discovery on next startup

Security and filesystem decisions:

- Archive paths are normalized and validated.
- Absolute paths, backslashes, `.` and `..` components, mixed plugin roots, and
  archives without `main.lua` are rejected.
- User plugins install only under Application Support.
- Bundled plugins in the signed app bundle cannot be replaced or removed.
- Symlinked plugin dirs are ignored for user plugin removal.
- Temporary imported ZIP cleanup only removes files from the known temporary
  plugin-import location.

Plugin identity decisions:

- The stable plugin key is the `.koplugin` directory basename without suffix.
- A plugin may expose another runtime `name`; both may need to be considered
  when clearing old disabled-state keys.
- `loaded_plugin_info` preserves path/key metadata for active plugins even when
  discovery caches are reset.

Active plugin removal:

- Physical deletion of an active plugin is deferred.
- Disabling plus pending removal is safer because arbitrary plugins may have
  registered UI/event state and may not fully unload from the running Lua VM.
- The pending removal record stores disabled keys so the next startup can clean
  the correct state after the files are removed.

Current upstream overlap:

Upstream after `v2026.03` added:

- directory-name based plugin identity
- plugin deletion
- built-in/user plugin submenus

Rebase guidance:

- Prefer upstream's plugin identity model and menu split.
- Keep iOS ZIP import and pending active-plugin removal as iOS-specific layers.
- Do not keep a second generic plugin deletion implementation if upstream now
  owns that behavior.
- On iOS, upstream deletion must be constrained to writable user plugins only.
  Never call a generic purge against a bundled app plugin path.
- Native plugin payloads remain a known limitation. User-installed unsigned
  `.dylib` or `.so` files should be rejected or warned about clearly if support
  is attempted.

### Subprocess And Background Work

Files:

- `frontend/ui/trapper.lua`
- `frontend/apps/reader/modules/readerrolling.lua`
- `frontend/apps/reader/modules/readerthumbnail.lua`
- `plugins/coverbrowser.koplugin/bookinfomanager.lua`
- `base/ffi/util.lua`

Several KOReader paths assume subprocesses, shell commands, or forked
background workers. Those assumptions do not hold on iOS.

The port:

- makes `ffi/util.execute()` return failure on iOS
- makes `ffi/util.runInSubProcess()` unavailable on iOS
- gates Trapper subprocess helpers behind `Device:canRunInSubProcess()`
- runs cover metadata extraction in-process on iOS
- disables CRE background partial rerendering on iOS
- skips PageBrowser thumbnail subprocess generation on iOS
- guards shared `mmap` setup and disables background rerendering if setup fails

Rebase guidance:

- Treat any new `runInSubProcess`, `execute`, `os.execute`, `io.popen`, or
  direct shell helper as a rebase hotspot.
- Prefer synchronous fallback or feature disablement over silent failure.
- If upstream adds generic capability flags, align iOS with those.

## Base Submodule Changes

### iOS Target And Toolchain

Files:

- `base/Makefile.defs`
- `base/cmake/CMakeLists.txt`

Base adds an iOS target that uses Xcode tools through `xcrun`. It selects:

- SDK: `iphoneos` or `iphonesimulator`
- architecture: usually `arm64`
- deployment target: currently iOS 15.0
- compiler/linker/archive tools from the selected SDK
- CMake system name `iOS`
- Meson cross system `ios`

It also appends the SDK family to the machine/build directory to avoid mixing
device and simulator libraries.

Rebase guidance:

- Preserve SDK-family output separation.
- Preserve `xcrun` tool selection.
- Review upstream changes around Homebrew prefix, CMake toolchain generation,
  Meson cross files, and `-march=native` handling. These are overlapping areas.

### LuaJIT

Files:

- `base/Makefile.defs`
- `base/thirdparty/luajit/CMakeLists.txt`

iOS uses LuaJIT as a Lua 5.1-compatible interpreter with FFI, not as a tracing
JIT runtime. The base changes:

- skip the standalone LuaJIT command-line binary on iOS
- pass `TARGET_SYS=iOS`
- adjust cross-compile arguments so Xcode's iOS clang is used correctly
- use host flags for host-side LuaJIT build helpers where needed

Rebase guidance:

- Keep LuaJIT FFI available.
- Do not introduce runtime JIT assumptions.
- Re-test native module loading after LuaJIT upstream bumps.

### Native Library Loading

Files:

- `base/ffi/loadlib.lua`
- `setupkoenv.lua`

On iOS, native libraries are in `KOReader.app/reader/libs` and use `.dylib`
names. The loader asks the iOS bridge for this directory and builds monolibtic
paths accordingly.

Rebase guidance:

- Preserve iOS `.dylib` search behavior.
- If upstream changes `ffi/loadlib.lua`, keep iOS path resolution localized and
  avoid hardcoding absolute container paths in generic code.

### SDL Lifecycle And Input

Files:

- `base/ffi/SDL3.lua`
- `frontend/device/sdl/device.lua`

The port disables SDL synthetic mouse/touch conversion on iOS to avoid duplicate
or skewed input, especially in Simulator. It also forwards iOS SDL lifecycle
events so Lua can simulate suspend/resume and flush settings.

Rebase guidance:

- Preserve `SDL_TOUCH_MOUSE_EVENTS=0` and `SDL_MOUSE_TOUCH_EVENTS=0` for iOS
  unless upstream SDL handling makes them unnecessary.
- Preserve foreground/background event forwarding, or migrate to upstream's
  equivalent lifecycle hook if one appears.

### File Copy Hardening

Files:

- `base/ffi/util.lua`

The base copy helper now closes the input file if opening the destination fails,
checks write/read errors, checks close errors, and reports failures. This is
not only iOS-specific, but it matters because the iOS file manager uses this
Lua copy path instead of shell `cp`.

Rebase guidance:

- Keep the hardening if upstream has not adopted it.
- If upstream has an equivalent, prefer upstream.

### Third-Party Build Adjustments

Files:

- `base/thirdparty/cmake_modules/koreader_targets.cmake`
- `base/thirdparty/cmake_modules/koreader_thirdparty_libs.cmake`
- `base/thirdparty/glib/CMakeLists.txt`
- `base/thirdparty/libiconv/CMakeLists.txt`
- `base/thirdparty/libk2pdfopt/CMakeLists.txt`
- `base/thirdparty/libk2pdfopt/ios-no-system.patch`
- `base/thirdparty/md4c/CMakeLists.txt`
- `base/thirdparty/sdcv/CMakeLists.txt`

The changes are build-compatibility patches for iOS:

- Do not treat Apple/iOS exactly like desktop macOS in all CMake paths.
- Avoid linking `rt` on Apple.
- Apply GLib compatibility patches for missing Linux APIs.
- Build only the usable library parts of libiconv for iOS.
- Disable `md2html` executable for md4c.
- Skip building/installing the `sdcv` CLI on iOS.
- Patch k2pdfopt/willuslib codepaths that use shell commands, zip helpers,
  Ghostscript execution, or platform APIs unavailable on iOS.

Current upstream overlap:

Upstream base after our baseline removed `thirdparty/libiconv` and introduced
`miniconv`. This directly conflicts with our libiconv iOS work.

Rebase guidance:

- Do not re-add libiconv blindly if upstream has moved to miniconv.
- Translate only the still-needed iOS behavior onto upstream's current
  miniconv/iconv setup.
- Re-evaluate `md4c` because upstream later added a generic
  "do not build md2html executable" change.
- Re-evaluate any CMake/macOS toolchain changes because upstream has also
  changed Homebrew prefix and SDL detection logic.
- Keep the k2pdfopt no-shell patch unless upstream has removed those iOS
  incompatible calls or provided a better compile-time option.

## Current Upstream Rebase Hotspots

As of the last audit, current upstream `origin/master` overlaps these iOS files:

- `base`
- `datastorage.lua`
- `frontend/apps/filemanager/filemanager.lua`
- `frontend/apps/filemanager/filemanagermenu.lua`
- `frontend/apps/reader/modules/readerfooter.lua`
- `frontend/apps/reader/modules/readerhighlight.lua`
- `frontend/apps/reader/modules/readerthumbnail.lua`
- `frontend/apps/reader/modules/readerview.lua`
- `frontend/apps/reader/readerui.lua`
- `frontend/pluginloader.lua`
- `spec/unit/pluginloader_spec.lua`
- `tools/mkrelease.sh`

Expected hard areas:

- `base`: build plumbing, LuaJIT, SDL, `ffi/util`, libiconv/miniconv.
- `pluginloader.lua`: upstream plugin deletion and menu split versus iOS ZIP
  install/remove.

Expected manageable areas:

- file manager copy/move, if upstream did not restructure file operations
  heavily
- footer/safe-area layout, if upstream footer changes are reviewed carefully
- `tools/mkrelease.sh`, likely a small command lookup conflict

## Rebase Strategy

1. Rebase or merge the iOS base fork onto upstream base first.
2. Resolve base conflicts by keeping upstream dependency upgrades and applying
   only required iOS adaptations.
3. Build base for `TARGET=ios IOS_ARCH=sim-arm64`.
4. Update the parent repo submodule pointer to the rebased base commit.
5. Rebase parent KOReader.
6. In `pluginloader.lua`, start from upstream's current implementation and add:
   iOS ZIP menu entries, safe user-plugin install/remove, pending active-plugin
   removal, and iOS-only startup cleanup.
7. Re-run focused unit tests.
8. Build and launch simulator.
9. Build and install on device when signing is available.

## Validation Checklist

Focused tests:

- `spec/unit/pluginloader_spec.lua`
- `spec/unit/pluginpackagemanager_spec.lua`
- `spec/unit/filemanager_spec.lua`
- `spec/unit/readerfooter_spec.lua`
- `spec/unit/ios_bridge_spec.lua`

Build validation:

- fresh clone with submodules
- `gmake TARGET=ios IOS_ARCH=sim-arm64 update`
- `gmake TARGET=ios IOS_ARCH=arm64 update`
- simulator install and launch
- physical device signing/install/launch when possible

Manual iOS validation:

- app starts without content under notch or home indicator
- orientation changes keep layout and input aligned
- settings survive background/foreground and force-close scenarios
- plugin ZIP install succeeds from Files picker
- plugin replacement rollback works on failure
- inactive user plugin removal deletes files
- active user plugin removal disables now and deletes after restart
- built-in plugins cannot be deleted from the app bundle
- file manager copy/move works within Documents/Application Support
- cross-volume move fallback works if available to test
- recursive copy refuses to copy a folder into itself
- cover extraction does not spawn a subprocess
- page thumbnails/background rerendering do not try unsupported subprocess paths

## Warning Signs After A Rebase

Investigate immediately if any of these appear:

- simulator build links against `iphoneos` libraries, or device build links
  against `iphonesimulator` libraries
- KOReader tries to write under `KOReader.app/reader`
- plugin removal purges a path under the app bundle
- active plugin removal physically deletes the plugin before restart
- `os.execute`, `io.popen`, `ffiUtil.execute`, or `runInSubProcess` runs on iOS
  without an explicit fallback
- footer/home-indicator padding is counted as document-reserved height
- touches are offset from visible UI after safe-area viewport changes
- user-installed native `.dylib` plugins are treated as supported without
  signing/embedding work

## What Should Eventually Move Upstream

Some changes are generally useful and should not remain iOS-only forever if
upstream accepts them:

- safer `ffi/util.copyFile` error handling
- stable plugin identity by plugin directory
- generic plugin deletion safety around user-installed versus bundled plugins
- a generic file operation abstraction that avoids shelling out on platforms
  without shell tools
- generic capability flags for subprocess/background-render availability
- safe-area-aware layout hooks if more platforms need them

Until then, keep the iOS patches narrow and well-tested.
