#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="imd"
EXEC_NAME="imd"
SRC="App.swift"
OUT="build"
APP="$OUT/$APP_NAME.app"
SHARED="../shared"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "[1/5] compile Swift"
swiftc -O -parse-as-library \
    -target arm64-apple-macos14.0 \
    "$SRC" \
    -o "$APP/Contents/MacOS/$EXEC_NAME" \
    -framework AppKit -framework SwiftUI -framework WebKit -framework UniformTypeIdentifiers

echo "[2/5] render Info.plist (year-aware copyright)"
YEAR=$(date +%Y)
if [ "$YEAR" -gt 2026 ]; then CPYEAR="2026-$YEAR"; else CPYEAR="2026"; fi
COPYRIGHT="©️${CPYEAR} Thinking（anqi.ssx@163.com）"
sed "s/__COPYRIGHT__/$COPYRIGHT/g" Info.plist > "$APP/Contents/Info.plist"

echo "[3/5] copy shared preview + snippets + icon"
cp "$SHARED/preview/marked.min.js" "$SHARED/preview/preview.css" "$SHARED/preview/preview.js" "$APP/Contents/Resources/"
cp "$SHARED/snippets.json" "$APP/Contents/Resources/snippets.json"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true

echo "[4/5] generate lproj from shared/l10n json"
python3 - "$APP" "$SHARED" <<'PY'
import json, os, sys
app, shared = sys.argv[1], sys.argv[2]
for lang in ("en", "zh-Hans"):
    d = json.load(open(os.path.join(shared, "l10n", f"{lang}.json")))
    dst = os.path.join(app, "Contents/Resources", f"{lang}.lproj")
    os.makedirs(dst, exist_ok=True)
    with open(os.path.join(dst, "Localizable.strings"), "w") as f:
        f.write(f"/* {lang} */\n")
        for k, v in d.items():
            f.write(f'"{k}" = "{v}";\n')
PY

echo "[5/5] ad-hoc sign"
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo
echo "done: $(pwd)/$APP"
