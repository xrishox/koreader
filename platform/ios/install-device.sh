#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEVICE=""
NO_BUILD=0
LAUNCH=0
KEEP_WORK=0
WORK=""

usage() {
    cat <<'EOF'
Usage: platform/ios/install-device.sh [options]

Build, sign, and install KOReader on a connected iPhone/iPad.

Options:
  --device <id|name>  Device identifier, UDID, ECID, serial, or device name.
                      Defaults to the first available iPhone/iPad from devicectl.
  --no-build          Reuse the existing iphoneos app bundle.
  --launch            Launch rocks.koreader.koreader after install.
  --keep-work         Keep the temporary signed export directory.
  -h, --help          Show this help.

The script uses Xcode archive export signing instead of direct codesign. That
avoids command-line keychain ACL failures such as errSecInternalComponent while
still producing a normal Apple Development signed app.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)
            DEVICE="${2:-}"
            if [[ -z "${DEVICE}" ]]; then
                echo "--device requires a value" >&2
                exit 2
            fi
            shift 2
            ;;
        --no-build)
            NO_BUILD=1
            shift
            ;;
        --launch)
            LAUNCH=1
            shift
            ;;
        --keep-work)
            KEEP_WORK=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

export PATH="/opt/homebrew/opt/util-linux/bin:/opt/homebrew/opt/make/libexec/gnubin:/opt/homebrew/opt/findutils/libexec/gnubin:/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/opt/gnu-sed/libexec/gnubin:/opt/homebrew/opt/grep/libexec/gnubin:/opt/homebrew/opt/gnu-getopt/bin:/opt/homebrew/opt/gettext/bin:$PATH"

if [[ "${NO_BUILD}" -eq 0 ]]; then
    (cd "${ROOT}" && ./kodev release --ignore-translation ios-arm64)
fi

APP_DIR="$(find "${ROOT}" -maxdepth 1 -type d -name 'koreader-ios-arm64-apple-*-iphoneos' -print | sort | tail -n 1)/KOReader.app"
if [[ ! -d "${APP_DIR}" ]]; then
    echo "Could not find iphoneos KOReader.app output. Run the ios-arm64 build first." >&2
    exit 1
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP_DIR}/Info.plist")"
BUNDLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "${APP_DIR}/Info.plist" 2>/dev/null || echo KOReader)"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP_DIR}/Info.plist")"
BUNDLE_SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_DIR}/Info.plist" 2>/dev/null || echo "${BUNDLE_VERSION}")"

if [[ -z "${DEVICE}" ]]; then
    DEVICE="$(xcrun devicectl list devices 2>/dev/null \
        | awk '/available/ && ($0 ~ /iPhone|iPad/) { print $3; exit }')"
fi
if [[ -z "${DEVICE}" ]]; then
    echo "No available iPhone/iPad found. Pass --device <id|name>." >&2
    xcrun devicectl list devices >&2 || true
    exit 1
fi

TEAM_ID=""
if [[ -f "${APP_DIR}/embedded.mobileprovision" ]]; then
    PROFILE_PLIST="$(mktemp /tmp/koreader-profile.XXXXXX.plist)"
    security cms -D -i "${APP_DIR}/embedded.mobileprovision" > "${PROFILE_PLIST}"
    TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "${PROFILE_PLIST}" 2>/dev/null || true)"
    rm -f "${PROFILE_PLIST}"
fi

WORK="$(mktemp -d /tmp/koreader-ios-device.XXXXXX)"
cleanup() {
    if [[ "${KEEP_WORK}" -eq 0 && -n "${WORK}" ]]; then
        rm -rf "${WORK}"
    fi
}
trap cleanup EXIT

ARCHIVE="${WORK}/${BUNDLE_NAME}.xcarchive"
EXPORT="${WORK}/export"
mkdir -p "${ARCHIVE}/Products/Applications" "${EXPORT}"
ditto "${APP_DIR}" "${ARCHIVE}/Products/Applications/${BUNDLE_NAME}.app"

cat > "${ARCHIVE}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>ApplicationProperties</key><dict>
    <key>ApplicationPath</key><string>Applications/${BUNDLE_NAME}.app</string>
    <key>ArchiveVersion</key><string>2</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleShortVersionString</key><string>${BUNDLE_SHORT_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUNDLE_VERSION}</string>
    <key>SigningIdentity</key><string>Apple Development</string>
    <key>Team</key><string>${TEAM_ID}</string>
  </dict>
  <key>CreationDate</key><date>$(date -u +%Y-%m-%dT%H:%M:%SZ)</date>
  <key>Name</key><string>${BUNDLE_NAME}</string>
  <key>SchemeName</key><string>${BUNDLE_NAME}</string>
</dict></plist>
EOF

cat > "${WORK}/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>debugging</string>
  <key>signingStyle</key><string>automatic</string>
  <key>signingCertificate</key><string>Apple Development</string>
  <key>destination</key><string>export</string>
EOF
if [[ -n "${TEAM_ID}" ]]; then
    cat >> "${WORK}/ExportOptions.plist" <<EOF
  <key>teamID</key><string>${TEAM_ID}</string>
EOF
fi
cat >> "${WORK}/ExportOptions.plist" <<'EOF'
</dict></plist>
EOF

xcrun xcodebuild -exportArchive \
    -archivePath "${ARCHIVE}" \
    -exportPath "${EXPORT}" \
    -exportOptionsPlist "${WORK}/ExportOptions.plist" \
    -allowProvisioningUpdates

SIGNED_APP="${EXPORT}/${BUNDLE_NAME}.app"
codesign --verify --deep --strict --verbose=2 "${SIGNED_APP}"

xcrun devicectl device install app --device "${DEVICE}" "${SIGNED_APP}" --timeout 180
xcrun devicectl device info apps --device "${DEVICE}" --bundle-id "${BUNDLE_ID}" --timeout 60

mkdir -p "${WORK}/ipa/Payload"
ditto "${SIGNED_APP}" "${WORK}/ipa/Payload/${BUNDLE_NAME}.app"
(cd "${WORK}/ipa" && ditto -c -k --keepParent Payload "${WORK}/${BUNDLE_NAME}-ios-arm64-signed.ipa")

if [[ "${LAUNCH}" -eq 1 ]]; then
    xcrun devicectl device process launch --device "${DEVICE}" "${BUNDLE_ID}" --timeout 60
fi

echo "Installed ${BUNDLE_ID} on ${DEVICE}"
if [[ "${KEEP_WORK}" -eq 1 ]]; then
    echo "Signed app: ${SIGNED_APP}"
    echo "Signed IPA: ${WORK}/${BUNDLE_NAME}-ios-arm64-signed.ipa"
fi
