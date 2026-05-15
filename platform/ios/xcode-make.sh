#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

prepend_path() {
    if [[ -d "$1" ]]; then
        PATH="$1:${PATH}"
    fi
}

for prefix in /opt/homebrew /usr/local; do
    prepend_path "${prefix}/opt/util-linux/bin"
    prepend_path "${prefix}/opt/make/libexec/gnubin"
    prepend_path "${prefix}/opt/findutils/libexec/gnubin"
    prepend_path "${prefix}/opt/coreutils/libexec/gnubin"
    prepend_path "${prefix}/opt/gnu-sed/libexec/gnubin"
    prepend_path "${prefix}/opt/grep/libexec/gnubin"
    prepend_path "${prefix}/opt/gnu-getopt/bin"
    prepend_path "${prefix}/opt/gettext/bin"
done
export PATH

find_gnu_make() {
    local candidate
    for candidate in "${MAKE:-}" make gmake /opt/homebrew/opt/make/libexec/gnubin/make /usr/local/opt/make/libexec/gnubin/make; do
        [[ -n "${candidate}" ]] || continue
        if command -v "${candidate}" >/dev/null 2>&1 && "${candidate}" --version 2>/dev/null | head -n 1 | grep -q "GNU Make"; then
            command -v "${candidate}"
            return 0
        fi
    done
    return 1
}

MAKE_BIN="$(find_gnu_make || true)"
if [[ -z "${MAKE_BIN}" ]]; then
    echo "GNU make 4.1+ is required. Install it with: brew install make" >&2
    exit 1
fi

platform="${PLATFORM_NAME:-iphoneos}"
arch="${CURRENT_ARCH:-}"
if [[ -z "${arch}" || "${arch}" = "undefined_arch" ]]; then
    read -r arch _ <<<"${ARCHS:-arm64}"
fi
arch="${arch:-arm64}"

case "${platform}" in
    iphoneos)
        ios_arch="${arch}"
        ;;
    iphonesimulator)
        ios_arch="sim-${arch}"
        ;;
    *)
        echo "Unsupported Xcode platform: ${platform}" >&2
        exit 2
        ;;
esac

make_args=(
    -C "${ROOT}"
    TARGET=ios
    IOS_ARCH="${ios_arch}"
    IOS_MIN_VERSION="${IPHONEOS_DEPLOYMENT_TARGET:-15.0}"
)

if [[ "${CONFIGURATION:-}" = "Debug" ]]; then
    make_args+=(KODEBUG=1)
fi

exec "${MAKE_BIN}" "${make_args[@]}" "$@"
