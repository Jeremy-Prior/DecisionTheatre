#!/usr/bin/env bash
set -euo pipefail

# Build release packages for Decision Theatre.
#
# Usage:
#   ./scripts/build-packages.sh [--platform linux|windows|darwin|all] [--arch amd64|arm64] [--version VERSION]
#
# Produces dist/ artefacts:
#   Linux:   .tar.gz, .deb, .rpm  (native build, requires nfpm for deb/rpm)
#   Windows: .zip with .exe       (cross-compile via mingw-w64, or native on Windows)
#   macOS:   .tar.gz (or .dmg if on macOS with hdiutil)
#
# Prerequisites (available in nix develop):
#   - go, gcc, pkg-config          (always)
#   - nfpm                         (linux deb/rpm)
#   - x86_64-w64-mingw32-gcc / CXX (windows cross-compile from linux)
#   - zip                          (windows .zip)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
PLATFORM="all"
ARCH="amd64"
VERSION=""

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform) PLATFORM="$2"; shift 2 ;;
        --arch)     ARCH="$2";     shift 2 ;;
        --version)  VERSION="$2";  shift 2 ;;
        *)          echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

VERSION="${VERSION:-$(cd "$PROJECT_ROOT" && git describe --tags --always --dirty 2>/dev/null || echo "dev")}"
DIST_DIR="$PROJECT_ROOT/dist"
BINARY_NAME="decision-theatre"
LDFLAGS="-s -w -X main.version=${VERSION}"

mkdir -p "$DIST_DIR"

# -------------------------------------------------------
# Helper: build the frontend + docs into embed dirs
# -------------------------------------------------------
ensure_frontend() {
    if [ ! -f "$PROJECT_ROOT/internal/server/static/index.html" ]; then
        echo "==> Building frontend..."
        make -C "$PROJECT_ROOT" build-frontend
    fi
    if [ ! -d "$PROJECT_ROOT/internal/server/docs_site" ] || [ -z "$(ls -A "$PROJECT_ROOT/internal/server/docs_site" 2>/dev/null)" ]; then
        echo "==> Building docs..."
        make -C "$PROJECT_ROOT" build-docs
    fi
}

# -------------------------------------------------------
# Linux native build
# -------------------------------------------------------
build_linux() {
    local arch="${1:-$ARCH}"
    echo "==> Building linux/${arch}..."
    ensure_frontend

    CGO_ENABLED=1 GOOS=linux GOARCH="$arch" \
        go build -ldflags "$LDFLAGS" -o "$DIST_DIR/${BINARY_NAME}" "$PROJECT_ROOT"

    # tar.gz
    local tarball="${BINARY_NAME}-linux-${arch}-v${VERSION}.tar.gz"
    tar -czf "$DIST_DIR/$tarball" -C "$DIST_DIR" "$BINARY_NAME"
    echo "  -> $DIST_DIR/$tarball"

    # deb + rpm via nfpm (if available)
    if command -v nfpm &>/dev/null; then
        echo "==> Building .deb and .rpm via nfpm..."
        export VERSION GOARCH="$arch"
        (cd "$PROJECT_ROOT" && nfpm package --packager deb --target "$DIST_DIR/")
        (cd "$PROJECT_ROOT" && nfpm package --packager rpm --target "$DIST_DIR/")
    else
        echo "  (nfpm not found — skipping .deb/.rpm; install with: nix profile install nixpkgs#nfpm)"
    fi

    rm -f "$DIST_DIR/${BINARY_NAME}"
}

# -------------------------------------------------------
# Windows cross-compile
# -------------------------------------------------------
build_windows() {
    local arch="${1:-$ARCH}"
    echo "==> Building windows/${arch}..."
    ensure_frontend

    # Determine cross-compiler
    local cc cxx
    if [ "$arch" = "amd64" ]; then
        cc="x86_64-w64-mingw32-gcc"
        cxx="x86_64-w64-mingw32-g++"
    else
        cc="aarch64-w64-mingw32-gcc"
        cxx="aarch64-w64-mingw32-g++"
    fi

    if ! command -v "$cc" &>/dev/null; then
        echo "ERROR: $cc not found. Install mingw-w64 for Windows cross-compilation." >&2
        echo "  On NixOS / nix: nix-shell -p pkgsCross.mingwW64.stdenv.cc" >&2
        echo "  On Ubuntu:      sudo apt install gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64" >&2
        return 1
    fi

    CGO_ENABLED=1 CC="$cc" CXX="$cxx" GOOS=windows GOARCH="$arch" \
        go build -ldflags "$LDFLAGS" -o "$DIST_DIR/${BINARY_NAME}.exe" "$PROJECT_ROOT"

    # Create zip
    local zipname="${BINARY_NAME}-windows-${arch}-v${VERSION}.zip"
    (cd "$DIST_DIR" && zip -j "$zipname" "${BINARY_NAME}.exe")
    echo "  -> $DIST_DIR/$zipname"

    # Build .msi via WiX Toolset (if wix CLI available)
    if command -v wix &>/dev/null; then
        echo "==> Building Windows .msi installer via WiX..."
        local msiname="${BINARY_NAME}-windows-${arch}-v${VERSION}.msi"
        wix build \
            -d Version="$VERSION" \
            -o "$DIST_DIR/$msiname" \
            "$PROJECT_ROOT/packaging/windows/product.wxs"
        echo "  -> $DIST_DIR/$msiname"
    else
        echo "  (wix CLI not found — skipping .msi; install WiX Toolset v4+ or build on Windows)"
    fi

    rm -f "$DIST_DIR/${BINARY_NAME}.exe"
}

# -------------------------------------------------------
# macOS build (native only — CGO cross-compile not viable)
# -------------------------------------------------------
build_darwin() {
    local arch="${1:-$ARCH}"
    echo "==> Building darwin/${arch}..."
    ensure_frontend

    if [ "$(uname -s)" != "Darwin" ]; then
        echo "WARNING: macOS builds require running on macOS (CGO + webview). Skipping." >&2
        return 0
    fi

    CGO_ENABLED=1 GOOS=darwin GOARCH="$arch" \
        go build -ldflags "$LDFLAGS" -o "$DIST_DIR/${BINARY_NAME}" "$PROJECT_ROOT"

    # Use create-dmg.sh if available, otherwise tar.gz
    if command -v hdiutil &>/dev/null && [ -f "$PROJECT_ROOT/packaging/macos/create-dmg.sh" ]; then
        (cd "$DIST_DIR" && bash "$PROJECT_ROOT/packaging/macos/create-dmg.sh" "${BINARY_NAME}" "$VERSION" "$arch")
    else
        local tarball="${BINARY_NAME}-darwin-${arch}-v${VERSION}.tar.gz"
        tar -czf "$DIST_DIR/$tarball" -C "$DIST_DIR" "$BINARY_NAME"
        echo "  -> $DIST_DIR/$tarball"
    fi

    rm -f "$DIST_DIR/${BINARY_NAME}"
}

# -------------------------------------------------------
# Checksums
# -------------------------------------------------------
generate_checksums() {
    echo "==> Generating checksums..."
    (cd "$DIST_DIR" && sha256sum *.tar.gz *.zip *.deb *.rpm *.msi *.dmg 2>/dev/null > "checksums-v${VERSION}.sha256" || true)
    echo "  -> $DIST_DIR/checksums-v${VERSION}.sha256"
}

# -------------------------------------------------------
# Main dispatch
# -------------------------------------------------------
case "$PLATFORM" in
    linux)   build_linux "$ARCH" ;;
    windows) build_windows "$ARCH" ;;
    darwin)  build_darwin "$ARCH" ;;
    all)
        build_linux "$ARCH"
        build_windows "$ARCH" || true
        build_darwin "$ARCH" || true
        generate_checksums
        ;;
    *)
        echo "Unknown platform: $PLATFORM (use linux, windows, darwin, or all)" >&2
        exit 1
        ;;
esac

echo ""
echo "Packages in $DIST_DIR:"
ls -lh "$DIST_DIR/"*v${VERSION}* 2>/dev/null || echo "  (none)"
