# Building KOReader For iOS

This guide covers local iOS builds from this branch.

It assumes you already have Xcode and the iOS components you want to target.
That means the iOS SDK is installed for hardware builds and an iOS Simulator
runtime is installed for simulator builds.

## Homebrew Dependencies

Install the build tools KOReader expects:

```sh
brew install make findutils coreutils gnu-sed grep gnu-getopt gettext util-linux cmake ninja pkg-config autoconf automake libtool
```

The GNU tools must be preferred over the BSD tools that ship with macOS. If your
shell startup files do not already do that, use this minimal build prefix:

```sh
PATH="/opt/homebrew/opt/util-linux/bin:/opt/homebrew/opt/make/libexec/gnubin:/opt/homebrew/opt/findutils/libexec/gnubin:/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/opt/gnu-sed/libexec/gnubin:/opt/homebrew/opt/grep/libexec/gnubin:/opt/homebrew/opt/gnu-getopt/bin:/opt/homebrew/opt/gettext/bin:$PATH"
```

On Intel Macs, Homebrew may be installed under `/usr/local` instead of
`/opt/homebrew`. Adjust the prefix paths if needed.

## Clone With Submodules

Clone the parent repository and initialize submodules:

```sh
git clone --recursive <repo-url> koreader
cd koreader
```

If you already cloned without submodules:

```sh
git submodule update --init --recursive
```

This iOS branch depends on a matching `base` submodule commit. If you are using
a fork, make sure the parent repository points at a `base` commit that your
machine can fetch.

## Simulator Build

Build for Apple Silicon iOS Simulator:

```sh
./kodev release --ignore-translation ios-sim-arm64
```

The output is an unsigned simulator IPA:

```text
koreader-ios-sim-arm64-v*.ipa
```

Install and launch it:

```sh
xcrun simctl list devices available
DEVICE="<simulator-udid>"
APP_TMP="$(mktemp -d /tmp/koreader-ios.XXXXXX)"
ditto -x -k koreader-ios-sim-arm64-v*.ipa "$APP_TMP"
xcrun simctl boot "$DEVICE"
xcrun simctl install "$DEVICE" "$APP_TMP/Payload/KOReader.app"
xcrun simctl launch "$DEVICE" rocks.koreader.koreader
```

If the simulator is already booted, `xcrun simctl boot` may report that it is
already booted. That is harmless.

To collect recent app logs:

```sh
xcrun simctl spawn "$DEVICE" log show --last 5m --predicate 'process == "KOReader" OR eventMessage CONTAINS "KOReader"'
```

## Hardware Build

Build for physical iPhone/iPad hardware:

```sh
./kodev release --ignore-translation ios-arm64
```

The build creates an unsigned hardware IPA and a hardware app bundle under a
directory named like:

```text
koreader-ios-arm64-apple-*-iphoneos/
```

The app bundle inside that directory is:

```text
KOReader.app
```

## Signing For A Device

The hardware app must be signed before it can be installed on a real device.
Use an Apple Development identity and a provisioning profile whose app id
matches:

```text
rocks.koreader.koreader
```

The exact signing command depends on your local certificate and provisioning
profile. The general flow is:

1. Put the provisioning profile into `KOReader.app/embedded.mobileprovision`.
2. Extract the profile entitlements.
3. Sign nested dylibs/framework-like binaries first, if present.
4. Sign `KOReader.app` with the extracted entitlements.
5. Package `Payload/KOReader.app` into an IPA.
6. Install with Xcode, Devices and Simulators, or `xcrun devicectl`.

Useful commands for discovering local signing state:

```sh
security find-identity -v -p codesigning
xcrun devicectl list devices
```

Install a signed IPA on a connected device:

```sh
xcrun devicectl device install app --device <device-identifier> /path/to/koreader-ios-arm64-signed.ipa
```

## Build Outputs

The iOS build intentionally produces separate trees for simulator and hardware
so their native libraries do not collide:

```text
koreader-ios-arm64-apple-*-iphoneos/
koreader-ios-arm64-apple-*-iphonesimulator/
```

Do not mix the artifacts. A simulator dylib cannot be linked into a hardware
app, even when both are `arm64`.

## Plugin ZIPs

iOS plugin ZIP management is available from KOReader's plugin manager. A ZIP can
be structured in either of these forms:

```text
Example.koplugin/main.lua
Example.koplugin/...
```

or:

```text
main.lua
...
```

GitHub-generated ZIPs with a single wrapper directory also work when that
wrapper contains `main.lua`.

The installed plugin is copied into KOReader's iOS Application Support data
directory. The app bundle itself remains read-only.

## Common Failures

`unsupported getopt version`

The macOS `getopt` is being used. Install `gnu-getopt` and make sure its bin
directory is before `/usr/bin`.

`your version of make is too old: 3.81`

The macOS system `make` is being used. Install Homebrew `make` and make sure
`gmake`/GNU make is first in PATH through Homebrew's `gnubin` directory.

`building for 'iOS', but linking in dylib ... built for 'iOS-simulator'`

The hardware and simulator build outputs were mixed. Clean the affected build
tree or rebuild with the current branch, which keeps `iphoneos` and
`iphonesimulator` outputs separated.

App opens with content under the notch/island

Make sure the app includes `LaunchScreen.storyboard` and the current iOS device
safe-area code. The app reads safe-area insets after launch and applies a
KOReader framebuffer viewport.
