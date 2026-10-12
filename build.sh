#!/bin/bash
# Bygger Filmklipparen.app för macOS 11 Big Sur och senare (t.ex. MacBook Pro 2013, Intel)
# och på en nyare Mac med Apple silicon (då blir appen "universal").
set -euo pipefail
cd "$(dirname "$0")"

APP="Filmklipparen"
BUILD="build"
OUT="$BUILD/$APP.app"
INSTALL=1
[ "${1:-}" = "--no-install" ] && INSTALL=0

echo "== Filmklipparen =="

if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "Apples utvecklarverktyg saknas. En ruta öppnas nu: klicka Installera."
    xcode-select --install || true
    echo "Kör det här skriptet igen när installationen är klar."
    exit 1
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"
VER="$(xcrun swiftc --version 2>&1 | grep -oE 'Swift version [0-9]+\.[0-9]+' | head -n 1 | awk '{print $3}')"
echo "Swift: $VER"
MAJ="${VER%%.*}"; MIN="${VER#*.}"
if [ -z "$VER" ] || [ "$MAJ" -lt 5 ] || { [ "$MAJ" -eq 5 ] && [ "$MIN" -lt 5 ]; }; then
    echo
    echo "Utvecklarverktygen är för gamla (Swift $VER, minst 5.5 behövs)."
    echo "Uppdatera dem: Systeminställningar > Programuppdatering, eller kör i Terminal:"
    echo "  sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install"
    echo "Enklast är annars att använda den färdiga appen från GitHub-bygget."
    exit 1
fi

rm -rf "$BUILD"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

ARCHS=(x86_64)
[ "$(uname -m)" = "arm64" ] && ARCHS=(x86_64 arm64)

BINS=()
for a in "${ARCHS[@]}"; do
    echo "Bygger för $a …"
    xcrun swiftc -O -swift-version 5 -parse-as-library \
        -sdk "$SDK" -target "$a-apple-macos11.0" \
        -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
        Sources/*.swift -o "$BUILD/$APP-$a"
    BINS+=("$BUILD/$APP-$a")
done
lipo -create "${BINS[@]}" -output "$OUT/Contents/MacOS/$APP"
cp Info.plist "$OUT/Contents/Info.plist"

# Swifts samtidighetsbibliotek finns i systemet först från macOS 12.
# Länkar appen mot det får den med en egen kopia (som Xcode gör), annars startar den inte på macOS 11.
CONC="$(otool -L "$OUT/Contents/MacOS/$APP" | grep libswift_Concurrency || true)"
if [ -n "$CONC" ]; then
    echo "Länkar: $CONC"
    case "$CONC" in
        *@rpath*)
            BD="$(dirname "$(xcrun --find swiftc)")/../lib/swift-5.5/macosx/libswift_Concurrency.dylib"
            if [ ! -f "$BD" ]; then
                echo "FEL: hittar inte $BD"
                exit 1
            fi
            mkdir -p "$OUT/Contents/Frameworks"
            cp "$BD" "$OUT/Contents/Frameworks/"
            echo "Lade med libswift_Concurrency för macOS 11."
            ;;
        *)
            echo "FEL: appen länkar mot systemets libswift_Concurrency, som saknas i macOS 11."
            exit 1
            ;;
    esac
fi

# Ikon
if [ -f Resources/AppIcon.png ]; then
    ICONSET="$BUILD/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2))
        sips -z $d $d Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/AppIcon.icns"
fi

codesign --force --deep --sign - "$OUT"
(cd "$BUILD" && ditto -c -k --keepParent "$APP.app" "$APP.zip")

if [ $INSTALL = 1 ]; then
    rm -rf "/Applications/$APP.app"
    cp -R "$OUT" "/Applications/"
    echo "Klart! Filmklipparen ligger i Program."
    open "/Applications/$APP.app"
else
    echo "Klart! Appen ligger i $OUT (och som zip i $BUILD/$APP.zip)."
fi
