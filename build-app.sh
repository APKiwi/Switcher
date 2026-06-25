#!/bin/bash

# Build script for SimpleSwitcher.app
# Creates a proper macOS application bundle

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY_NAME="SimpleSwitcher"
APP_NAME="Switcher"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"

# Use debug build by default (more reliable with event tap)
# Pass "release" as argument to use release build
BUILD_CONFIG="${1:-debug}"

echo "Building $APP_NAME ($BUILD_CONFIG)..."

# Clean previous build
rm -rf "$APP_BUNDLE"

# Create app bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cd "$PROJECT_DIR"

if [ "$BUILD_CONFIG" = "release" ]; then
    if swift build -c release 2>/dev/null; then
        BINARY=".build/release/$BINARY_NAME"
        echo "Release build successful"
    elif [ -f ".build/release/$BINARY_NAME" ]; then
        BINARY=".build/release/$BINARY_NAME"
        echo "Using existing release build"
    else
        echo "ERROR: Release build failed. Run 'swift build -c release' first."
        exit 1
    fi
else
    if swift build 2>/dev/null; then
        BINARY=".build/debug/$BINARY_NAME"
        echo "Debug build successful"
    elif [ -f ".build/debug/$BINARY_NAME" ]; then
        BINARY=".build/debug/$BINARY_NAME"
        echo "Using existing debug build"
    else
        echo "ERROR: Debug build failed. Run 'swift build' first."
        exit 1
    fi
fi

# Copy binary to app bundle
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/"

# Copy Info.plist
cp "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/"

# Copy icon if it exists
if [ -f "$PROJECT_DIR/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
    echo "Icon copied"
else
    echo "Note: No AppIcon.icns found. Run ./create-icon.sh to create one."
fi

# Create PkgInfo file
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Code sign. Prefer the shared self-signed identity "AP Kiwi Local Signing" so the
# Accessibility grant survives rebuilds (TCC keys on the cert, not the per-build
# code hash). Fall back to ad-hoc if it isn't on this machine, in which case the
# grant must be re-given after each rebuild. Create it once with
# Scripts/make_signing_cert.sh.
SIGN_ID="AP Kiwi Local Signing"
if security find-identity -p codesigning -v 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "Code signing with stable identity: $SIGN_ID"
    codesign --force --deep --sign "$SIGN_ID" "$APP_BUNDLE"
else
    echo "Code signing ad-hoc ('$SIGN_ID' not found; grant will not persist across rebuilds)"
    codesign --force --deep --sign - "$APP_BUNDLE"
fi
echo "Code signing complete"

echo ""
echo "Build complete: $APP_BUNDLE"
echo ""
echo "To install:"
echo "  1. Move to Applications: mv '$APP_BUNDLE' /Applications/"
echo "  2. Grant Accessibility permission when prompted (System Settings > Privacy & Security > Accessibility)"
echo "  3. Add to Login Items in System Settings > General > Login Items"
echo ""
echo "To run directly:"
echo "  open '$APP_BUNDLE'"
