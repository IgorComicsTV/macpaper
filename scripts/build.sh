#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
BUILD_DIR="$ROOT_DIR/work/build"
MODULE_DIR="$BUILD_DIR/modules"
APP_PATH="$ROOT_DIR/outputs/MacPaper.app"
STAGING_APP="$BUILD_DIR/MacPaper.app"
CONTENTS="$STAGING_APP/Contents"
ICONSET="$BUILD_DIR/AppIcon.iconset"
SYSTEM_SDK="$(xcrun --show-sdk-path)"
SYSTEM_SDK_REAL="$(cd "$SYSTEM_SDK" && pwd -P)"
SDK_PATH="$ROOT_DIR/work/patched-sdk/MacOSX.sdk"
LOCAL_TOOLCHAIN="$ROOT_DIR/work/toolchain"

mkdir -p "$BUILD_DIR" "$MODULE_DIR"
running_pids="$(pgrep -f "^$ROOT_DIR/(outputs|work/build)/MacPaper.app/Contents/MacOS/MacPaper$" || true)"
if [[ -n "$running_pids" ]]; then
  echo "$running_pids" | xargs kill
fi

BASE_SWIFT_ENV=(
  -sdk "$SYSTEM_SDK"
  -module-cache-path "$BUILD_DIR/module-cache"
  -target arm64-apple-macosx14.0
)
SWIFT_ENV=("${BASE_SWIFT_ENV[@]}")

# Fallback para uma revisão específica das Command Line Tools 26 que veio com
# compilador e SDK incompatíveis. A correção é local e nunca altera o sistema.
if ! swiftc "${BASE_SWIFT_ENV[@]}" -typecheck "$ROOT_DIR/Sources/MacPaperCore/Models.swift" >/dev/null 2>&1; then
  if [[ ! -d "$SDK_PATH" ]]; then
    cp -cR "$SYSTEM_SDK_REAL" "$SDK_PATH"
  fi
  find "$SDK_PATH" -name '*.swiftinterface' -print0 | xargs -0 perl -pi -e \
    's/swiftlang-6\.2\.0\.9\.904 clang-1700\.3\.9\.904/swiftlang-6.2.0.9.909 clang-1700.3.9.907/g'
  if [[ ! -d "$LOCAL_TOOLCHAIN/usr/lib/swift" ]]; then
    mkdir -p "$LOCAL_TOOLCHAIN/usr/lib" "$LOCAL_TOOLCHAIN/usr/include/swift"
    cp -cR /Library/Developer/CommandLineTools/usr/lib/swift "$LOCAL_TOOLCHAIN/usr/lib/swift"
    cp -cR /Library/Developer/CommandLineTools/usr/lib/clang "$LOCAL_TOOLCHAIN/usr/lib/clang"
    cp /Library/Developer/CommandLineTools/usr/include/swift/bridging "$LOCAL_TOOLCHAIN/usr/include/swift/bridging"
    cp /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap "$LOCAL_TOOLCHAIN/usr/include/swift/module.modulemap"
  fi
  SWIFT_ENV=(
  -sdk "$SDK_PATH"
  -resource-dir "$LOCAL_TOOLCHAIN/usr/lib/swift"
  -module-cache-path "$BUILD_DIR/module-cache"
  -target arm64-apple-macosx14.0
  )
fi

CORE_SOURCES=("$ROOT_DIR"/Sources/MacPaperCore/*.swift)
APP_SOURCES=("$ROOT_DIR"/Sources/MacPaper/*.swift)

swiftc "${SWIFT_ENV[@]}" -O -parse-as-library -emit-library -static -emit-module \
  -module-name MacPaperCore \
  -emit-module-path "$MODULE_DIR/MacPaperCore.swiftmodule" \
  "${CORE_SOURCES[@]}" \
  -o "$BUILD_DIR/libMacPaperCore.a"

swiftc "${SWIFT_ENV[@]}" -O -I "$MODULE_DIR" -L "$BUILD_DIR" -lMacPaperCore \
  -framework AppKit -framework AVFoundation -framework ServiceManagement -framework IOKit -framework CryptoKit \
  -framework Metal -framework CoreImage -framework QuartzCore \
  "${APP_SOURCES[@]}" \
  -o "$BUILD_DIR/MacPaper"

swiftc "${SWIFT_ENV[@]}" -O -I "$MODULE_DIR" -L "$BUILD_DIR" -lMacPaperCore \
  "$ROOT_DIR/scripts/verify.swift" -o "$BUILD_DIR/verify"
"$BUILD_DIR/verify"

if [[ "$STAGING_APP" == "$ROOT_DIR/work/build/MacPaper.app" ]]; then
  rm -rf "$STAGING_APP"
fi
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BUILD_DIR/MacPaper" "$CONTENTS/MacOS/MacPaper"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"
cp -R "$ROOT_DIR/Resources/en.lproj" "$CONTENTS/Resources/"
cp -R "$ROOT_DIR/Resources/pt-BR.lproj" "$CONTENTS/Resources/"
cp -R "$ROOT_DIR/Resources/pt.lproj" "$CONTENTS/Resources/"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" "512:512x512" "1024:512x512@2x"; do
  pixels="${spec%%:*}"
  name="${spec#*:}"
  sips -s format png -z "$pixels" "$pixels" "$ROOT_DIR/Resources/AppIcon.svg" \
    --out "$ICONSET/icon_${name}.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"

signature_ok=false
for attempt in 1 2 3; do
  xattr -cr "$STAGING_APP"
  xattr -d com.apple.FinderInfo "$STAGING_APP" 2>/dev/null || true
  if codesign --force --deep --sign - "$STAGING_APP" && codesign --verify --deep --strict "$STAGING_APP"; then
    signature_ok=true
    break
  fi
  sleep 0.2
done
if [[ "$signature_ok" != true ]]; then
  echo "Não foi possível assinar o bundle após 3 tentativas." >&2
  exit 1
fi
plutil -lint "$CONTENTS/Info.plist"
if [[ "$APP_PATH" == "$ROOT_DIR/outputs/MacPaper.app" ]]; then
  rm -rf "$APP_PATH"
fi
ditto --noextattr "$STAGING_APP" "$APP_PATH"
xattr -cr "$APP_PATH"
xattr -d com.apple.FinderInfo "$APP_PATH" 2>/dev/null || true
codesign --verify --deep --strict "$APP_PATH"
echo "$APP_PATH"
