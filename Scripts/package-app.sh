#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
VERSION="${AUTO_MACRO_VERSION:-${2:-0.1.0}}"
BUILD_NUMBER="${AUTO_MACRO_BUILD_NUMBER:-1}"
VERSION="${VERSION#v}"
APP_NAME="Auto Macro"
EXECUTABLE_NAME="AutoMacro"
DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"

cd "$ROOT"
swift build -c "$CONFIGURATION" --product "$EXECUTABLE_NAME"
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE_NAME" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
cp "$ROOT/Sources/AutoMacroApp/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

RESOURCE_BUNDLE="$BIN_DIR/AutoMacro_AutoMacroApp.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ko</string>
    <key>CFBundleDisplayName</key>
    <string>Auto Macro</string>
    <key>CFBundleExecutable</key>
    <string>AutoMacro</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>app.automacro.desktop</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Auto Macro</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Auto Macro</string>
    <key>NSInputMonitoringUsageDescription</key>
    <string>사용자가 기록을 시작한 동안 키보드와 마우스 동작을 함께 기록하여 정확한 매크로를 만듭니다.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>선택한 화면의 변화를 기록하고 화면 조건을 인식하기 위해 화면 기록 권한이 필요합니다.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>사용자가 승인한 매크로 동작을 대상 앱에서 재생하기 위해 접근 권한이 필요합니다.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
        <key>NSExceptionDomains</key>
        <dict>
            <key>localhost</key>
            <dict>
                <key>NSIncludesSubdomains</key>
                <true/>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
            </dict>
        </dict>
    </dict>
</dict>
</plist>
PLIST

chmod +x "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
# Ad-hoc signing is intentionally used so releases do not require an Apple
# Developer account. It lets macOS validate the bundle's internal integrity,
# but it is not a Developer ID signature.
codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "$APP_DIR"
