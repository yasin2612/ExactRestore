#!/bin/bash
# Builds a universal "Exact Restore.app" with macvdmtool bundled inside. Run on an Apple Silicon Mac with Xcode installed.
set -euo pipefail

# Your GitHub username, shown in About Exact Restore. Keep it in sync with AppInfo.swift.
AUTHOR="yasin2612"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Exact Restore.app"

rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "Building macvdmtool"
git clone --depth 1 https://github.com/AsahiLinux/macvdmtool.git "$BUILD/macvdmtool"
# Patched version: DFU on every host port, not only RID 0.
cp "$ROOT/vendor/macvdmtool/main.cpp" "$BUILD/macvdmtool/main.cpp"
make -C "$BUILD/macvdmtool"

echo "Building Exact Restore (Apple Silicon and Intel)"
for ARCH in arm64 x86_64; do
    swift build --package-path "$ROOT" -c release --arch "$ARCH"
done
ARM_BIN="$(swift build --package-path "$ROOT" -c release --arch arm64 --show-bin-path)/ExactRestore"
X86_BIN="$(swift build --package-path "$ROOT" -c release --arch x86_64 --show-bin-path)/ExactRestore"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$ARM_BIN" "$X86_BIN" -output "$APP/Contents/MacOS/ExactRestore"
cp "$BUILD/macvdmtool/macvdmtool" "$APP/Contents/Resources/macvdmtool"
# macvdmtool is Apache 2.0: its licence must ship with the app.
cp "$BUILD/macvdmtool/LICENSE" "$APP/Contents/Resources/macvdmtool-LICENSE" 2>/dev/null || true
iconutil -c icns "$ROOT/Branding/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ExactRestore</string>
    <key>CFBundleIdentifier</key><string>com.exactsolution.exactrestore</string>
    <key>CFBundleName</key><string>Exact Restore</string>
    <key>CFBundleDisplayName</key><string>Exact Restore</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHumanReadableCopyright</key><string>© $(date +%Y) $AUTHOR · github.com/$AUTHOR</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/Resources/macvdmtool"
codesign --force --sign - "$APP"

ditto -c -k --keepParent "$APP" "$BUILD/Exact Restore.zip"

echo "Done:"
echo "  $APP"
echo "  $BUILD/Exact Restore.zip  (copy this to other hosts)"
