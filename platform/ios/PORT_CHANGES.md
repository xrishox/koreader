# iOS Port Implementation Notes

This document explains what changed to make KOReader run as an iOS app and why
those changes were necessary.

## Overview

KOReader already has most of the pieces needed for a mobile app: a Lua
frontend, native rendering through SDL, a cross-compiled third-party dependency
tree, and platform-specific device abstractions. The iOS port keeps that shape.
It does not rewrite KOReader as a UIKit app. Instead, it packages the existing
reader into an iOS application bundle, starts KOReader from a small Objective-C
host, and exposes the small set of iOS APIs that KOReader needs through FFI.

The final runtime looks like this:

- `KOReader.app/KOReader` is a small native iOS executable.
- `KOReader.app/reader/` contains the usual KOReader Lua/resources payload.
- `KOReader.app/reader/libs/` contains the native libraries built for either
  `iphoneos` or `iphonesimulator`.
- Lua sees iOS as a normal KOReader device implementation in
  `frontend/device/ios/device.lua`.
- The Objective-C host in `platform/ios/native/KOReaderIOSMain.m` bridges iOS
  paths, sharing, clipboard, safe-area insets, link opening, document picker
  imports, and external folder access.

## Build Target Separation

The build now recognizes `TARGET=ios`. The iOS target is configured in the
`base` submodule and in the parent KOReader Makefile.

The important distinction is that iOS has two incompatible SDK families:

- `iphoneos` for physical devices
- `iphonesimulator` for Simulator

Both can be `arm64` on Apple Silicon Macs, but the binaries are not
interchangeable. An `arm64` simulator library cannot be linked into an `arm64`
device app, and vice versa. To prevent those outputs from overwriting each
other, the machine/build directory name now includes the SDK suffix. That is why
the build creates directories such as:

- `arm64-apple-darwin...-iphoneos`
- `arm64-apple-darwin...-iphonesimulator`

Without this split, a simulator build could accidentally reuse a device library,
or a device build could link against a simulator dylib.

## Cross-Compilation Through Xcode

The iOS target uses Xcode's compiler tools through `xcrun`. The base build now
sets the compiler, linker, archiver, ranlib, SDK path, architecture, deployment
target, and CMake/Meson cross-compilation variables from the selected iOS SDK.

Conceptually:

- `IOS_ARCH=arm64` selects a hardware build.
- `IOS_ARCH=sim-arm64` selects a simulator build.
- `IOS_SDK=iphoneos` or `iphonesimulator` follows from that architecture.
- `xcrun -sdk <sdk>` provides the correct clang, SDK root, and Apple tools.
- CMake gets `CMAKE_SYSTEM_NAME=iOS`, `CMAKE_OSX_SYSROOT`,
  `CMAKE_OSX_ARCHITECTURES`, and `CMAKE_OSX_DEPLOYMENT_TARGET`.
- Meson gets `system = ios` and `cpu_family = aarch64`.

Several third-party CMake files were adjusted so their configure/link behavior
works in an iOS cross-build instead of assuming desktop Darwin or Linux.

## LuaJIT On iOS

iOS does not allow normal apps to generate executable memory at runtime. That
means LuaJIT cannot use its JIT compiler on iOS in the way it does on desktop
platforms. The port still uses LuaJIT, but it relies on LuaJIT's interpreter
mode for executing Lua code.

This matters because "LuaJIT" is both:

- a Lua 5.1-compatible runtime with an interpreter, FFI, and runtime library;
- a tracing JIT compiler.

The iOS port uses the first part and avoids depending on the second part.
KOReader still benefits from LuaJIT's FFI support, C module loading behavior,
and compatibility with the rest of the existing codebase. The tradeoff is that
hot Lua loops do not get native machine-code traces on iOS. Most KOReader work
is still dominated by native libraries, rendering, document parsing, font work,
I/O, and UI operations, so keeping LuaJIT as the interpreter is much less
invasive than porting KOReader to a different Lua runtime.

The LuaJIT build was changed for iOS in the base submodule:

- it passes `TARGET_SYS=iOS`;
- it avoids building/installing the standalone `luajit` command-line binary;
- it uses Xcode's iOS compiler/linker flags;
- it keeps the LuaJIT shared library available for the app and native Lua
  modules.

## Native Library Loading

KOReader normally loads many native modules through `ffi.loadlib`. On iOS the
libraries live inside the app bundle, under:

```text
KOReader.app/reader/libs/
```

The loader now asks the iOS bridge for the native library directory and uses
`.dylib` naming on iOS. The monolibtic library path also works from that iOS
bundle location.

This lets existing Lua code continue to call `ffi.loadlib(...)` without knowing
where iOS stores the app bundle.

## iOS App Bundle And IPA Packaging

The parent repository gained `make/ios.mk`, which turns KOReader's install tree
into a real iOS app bundle:

1. Build the normal KOReader Lua/resources/native payload.
2. Build the native iOS host with CMake.
3. Copy `KOReader.app` from the native build.
4. Copy the KOReader payload into `KOReader.app/reader`.
5. Fill in bundle metadata such as bundle id and version.
6. Package `Payload/KOReader.app` into an IPA zip.

The generated IPA is unsigned. Simulator IPAs can be installed directly into
Simulator. Hardware IPAs must be signed with a provisioning profile and Apple
Development identity before installation on a real device.

## Objective-C Host

The native host is in `platform/ios/native/KOReaderIOSMain.m`. It exists because
iOS apps need a real application bundle executable that UIKit can launch.

The host links against:

- `Foundation`
- `UIKit`
- `UniformTypeIdentifiers`
- `SDL3`
- `luajit`

Its job is intentionally small:

- start the SDL/Lua KOReader process;
- expose C-callable functions that Lua can reach with FFI;
- bridge app-container paths;
- bridge iOS-only UI operations.

The C bridge functions include:

- bundle/resource/Documents/Application Support paths;
- native library directory;
- safe-area insets;
- external link opening;
- clipboard read/write;
- share sheet support;
- document picker based plugin ZIP and file import;
- external folder picker and bookmark resolution.

## Data And Resource Paths

iOS apps cannot write freely into their own app bundle. The bundle is read-only
at runtime, while app data belongs in the app container.

The iOS bridge maps KOReader paths to iOS container locations:

- bundled resources come from the app bundle;
- user-visible files use Documents;
- KOReader settings/cache/plugins use Application Support;
- native libraries come from `KOReader.app/reader/libs`.

`datastorage.lua` and `setupkoenv.lua` were adjusted so iOS uses these container
paths instead of desktop assumptions.

## Device Abstraction

`frontend/device/ios/device.lua` extends the existing SDL device implementation.
That keeps iOS close to the desktop SDL path while overriding behavior that is
different on iOS.

The iOS device reports:

- touch-first behavior;
- no hardware keyboard/D-pad assumptions;
- no KOReader-managed suspend/restart/poweroff options;
- no OTA update support;
- native clipboard support;
- native link opening;
- native share support;
- plugin ZIP import support.

## Safe Area Handling

Modern iPhones have rounded corners, a home indicator, and sometimes a Dynamic
Island or notch. A fullscreen SDL surface can render under those areas unless
the app accounts for UIKit's safe-area insets.

The port reads safe-area insets from the UIKit key window and converts them from
points to framebuffer pixels. Lua then applies a KOReader framebuffer viewport:

- the top viewport offset avoids the island/notch and rounded top corners;
- the bottom inset avoids the home indicator;
- touch input is translated by the same offset so hit testing still matches the
  visible UI.

The safe area is read more than once after startup because UIKit often reports
zero insets very early in launch. The first read may happen before the window is
fully active; later reads return the real values.

The app also includes a launch storyboard and hides the iOS status bar. The
launch storyboard is important because without it iOS can treat the app as a
legacy scaled app instead of giving it the full modern display area.

## SDL Input

SDL can synthesize mouse events from touches and touch events from mouse input.
On iOS that can produce duplicate or confusing input paths, especially in
Simulator. The SDL setup disables those synthetic conversions for iOS so KOReader
gets the native touch path cleanly.

The app plist also enables indirect input events so Simulator trackpad/mouse
interaction works as expected.

## Plugin ZIP Management

iOS users cannot manage KOReader plugin folders the same way desktop users can.
The port adds a plugin package manager that appears from KOReader's plugin menu.

It can:

- open a native Files picker for ZIP files;
- install a ZIP with a top-level `*.koplugin` directory;
- install a ZIP whose plugin files are directly at the archive root;
- install a GitHub-style ZIP with a single wrapper directory containing
  `main.lua`;
- list user-installed plugins;
- remove user-installed plugins.

The installer validates archive paths before extracting. It rejects absolute
paths, backslashes, `.`/`..` path components, multiple plugin roots, mixed roots,
and archives without `main.lua`.

User plugins are installed into KOReader's iOS Application Support data
directory, not into the read-only app bundle.

## App Metadata And Icons

`platform/ios/Info.plist` declares the iOS bundle, document support, app icon,
supported orientations, status bar behavior, file sharing support, and indirect
input support.

The icon files in `platform/ios/icons/` are generated from the existing KOReader
artwork and copied into the app bundle by the native CMake target.

## Xcode Project Generation

`platform/ios/project.yml` is the XcodeGen source for a local
`KOReader.xcodeproj`. The generated project is ignored and should be recreated
with `./kodev xcodeproj` when needed.

The Xcode target compiles the same native Objective-C host used by the CMake
bundle. Its build phases call `platform/ios/xcode-make.sh`, which maps Xcode's
`PLATFORM_NAME` and `ARCHS` to the existing `TARGET=ios IOS_ARCH=...` Makefile
flow, stages the KOReader payload, and embeds it into the Xcode-built `.app`.
For hardware builds, Xcode owns the final Apple Development signing step.

## What This Port Does Not Do

The port does not make KOReader a native UIKit reader. UIKit is used only for
the app shell and system integrations. Rendering and input still flow through
SDL and KOReader's existing Lua UI.

The port also does not include signing credentials. Hardware builds produce an
unsigned IPA. Signing remains local to the developer because Apple certificates,
profiles, and devices are inherently account-specific.
