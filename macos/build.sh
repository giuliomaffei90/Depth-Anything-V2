#!/bin/zsh
# Builds build/Depth Anything.app: downloads Apple's Core ML port of Depth-Anything-V2-Small if missing,
# compiles it and bundles it with the SwiftUI app.
set -euo pipefail
cd "${0:A:h}"

MIN_MACOS=14.0
MODEL=DepthAnythingV2SmallF16
APP="build/Depth Anything.app"

if [[ ! -d Models/$MODEL.mlpackage ]]; then
    base=https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/main/$MODEL.mlpackage
    for f in Manifest.json Data/com.apple.CoreML/model.mlmodel Data/com.apple.CoreML/weights/weight.bin; do
        curl -fL --create-dirs -o "Models/$MODEL.mlpackage/$f" "$base/$f"
    done
fi

# The explicit platform_version stamps the real SDK, so macOS 26+ draws the Liquid Glass design.
swift build -c release -Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_MACOS" \
    -Xlinker "$(xcrun --show-sdk-version)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DepthAnything "$APP/Contents/MacOS/"
xcrun coremlcompiler compile "Models/$MODEL.mlpackage" "$APP/Contents/Resources" >/dev/null
# AppIcon.icon is an Icon Composer document: Assets.car (Liquid Glass on macOS 26+) plus AppIcon.icns for older systems.
xcrun actool AppIcon.icon --compile "$APP/Contents/Resources" --app-icon AppIcon --include-all-app-icons \
    --platform macosx --target-device mac --minimum-deployment-target "$MIN_MACOS" \
    --output-partial-info-plist "$(mktemp -t depthanything-icon)" >/dev/null

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DepthAnything</string>
    <key>CFBundleIdentifier</key><string>com.depthanything.mac</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleName</key><string>Depth Anything</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array><dict>
        <key>CFBundleTypeName</key><string>Image</string>
        <key>CFBundleTypeRole</key><string>Viewer</string>
        <key>LSHandlerRank</key><string>Alternate</string>
        <key>LSItemContentTypes</key><array><string>public.image</string><string>public.folder</string></array>
    </dict></array>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"
echo "Built $APP"
