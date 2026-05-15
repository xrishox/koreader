# KOReader iOS Port

This directory contains the iOS packaging and runtime bridge for KOReader.
The port uses SDL3 for rendering/input and builds separate artifacts for
iPhone/iPad hardware and Apple Silicon iOS simulators.

## Requirements

- macOS with Xcode installed
- iOS platform support and an iOS Simulator runtime installed from Xcode
- Homebrew build tools used by KOReader

The build expects GNU tools ahead of the macOS BSD variants:

```sh
brew install make findutils coreutils gnu-sed grep gnu-getopt gettext util-linux cmake ninja pkg-config autoconf automake libtool xcodegen
```

Use this PATH prefix when building:

```sh
export PATH="/opt/homebrew/opt/util-linux/bin:/opt/homebrew/opt/make/libexec/gnubin:/opt/homebrew/opt/findutils/libexec/gnubin:/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/opt/gnu-sed/libexec/gnubin:/opt/homebrew/opt/grep/libexec/gnubin:/opt/homebrew/opt/gnu-getopt/bin:/opt/homebrew/opt/gettext/bin:$PATH"
```

## Simulator Build

```sh
./kodev release --ignore-translation ios-sim-arm64
```

This creates:

```text
koreader-ios-sim-arm64-v*.ipa
```

Install and run it in a booted simulator:

```sh
DEVICE="<simulator-udid>"
APP_TMP="$(mktemp -d /tmp/koreader-ios.XXXXXX)"
ditto -x -k koreader-ios-sim-arm64-v*.ipa "$APP_TMP"
xcrun simctl install "$DEVICE" "$APP_TMP/Payload/KOReader.app"
xcrun simctl launch "$DEVICE" rocks.koreader.koreader
```

## Hardware Build

```sh
./kodev release --ignore-translation ios-arm64
```

This creates an unsigned hardware IPA. For the normal local build/sign/install
flow on a connected iPhone/iPad, use the generated Xcode project and let Xcode
perform Apple Development signing with the selected development team.

## Xcode Project

Generate an Xcode project when you want to pick a signing team and run from
Xcode:

```sh
./kodev xcodeproj
open KOReader.xcodeproj
```

The generated project uses Xcode for the app shell, signing, and launch. Its
build phases call back into the existing KOReader iOS Makefile to stage the Lua
payload and native libraries, so the command-line and Xcode builds use the same
runtime layout.

## Plugins

On iOS, plugin ZIP files can be imported from the KOReader plugin manager.
The ZIP may contain either a top-level `*.koplugin` directory or the plugin
files directly at the archive root. A plugin must contain `main.lua`.
