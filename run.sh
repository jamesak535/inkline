#!/usr/bin/env bash
# Build the Rust core + Swift shell and assemble Inkline.app, then launch it.
#
#   ./run.sh          build, (re)assemble the bundle, and open Inkline.app
#   ./run.sh --build  build + assemble only (don't launch)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HOME/.cargo/env" 2>/dev/null || true

# Cargo workspace places build artifacts in the workspace-root target/ dir.
COREDIR="$ROOT/target/release"
APP="$ROOT/mac/build/Inkline.app"
BUNDLE_ID="com.inkline.app"

echo "==> Building Rust core (release)…"
( cd "$ROOT" && cargo build --release -p inkline-core )

echo "==> Syncing generated header into the Swift module…"
cp "$ROOT/core/include/inkline.h" "$ROOT/mac/Sources/CInklineCore/inkline.h"

# Make the dylib's install name @rpath-relative so the bundled copy resolves via
# the rpath we add to the executable below.
echo "==> Fixing dylib install name…"
install_name_tool -id @rpath/libinkline_core.dylib "$COREDIR/libinkline_core.dylib"

echo "==> Building Swift app (release)…"
( cd "$ROOT/mac" && swift build -c release \
    -Xlinker -L"$COREDIR" \
    -Xlinker -linkline_core \
    -Xlinker -rpath -Xlinker "$COREDIR" )

EXE="$ROOT/mac/.build/release/inkline"

echo "==> Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$ROOT/mac/Info.plist" "$APP/Contents/Info.plist"
cp "$EXE" "$APP/Contents/MacOS/Inkline"
cp "$COREDIR/libinkline_core.dylib" "$APP/Contents/Frameworks/"
# Shared cross-platform settings UI (the Windows shell will host the same file).
cp "$ROOT/ui/settings.html" "$APP/Contents/Resources/"
# Resolve the dylib from inside the bundle at runtime.
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Inkline" 2>/dev/null || true

# Prefer the persistent "Inkline Dev" identity (see scripts/setup-signing.sh) so
# Accessibility/TCC grants survive rebuilds. Fall back to ad-hoc if it's absent.
SIGN_IDENTITY="Inkline Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    SIGN_ARG="$SIGN_IDENTITY"
    echo "==> Code-signing with \"$SIGN_IDENTITY\" (stable identity)…"
else
    SIGN_ARG="-"
    echo "==> Ad-hoc code-signing (run ./scripts/setup-signing.sh for a stable identity)…"
    echo "    NOTE: ad-hoc means you must re-grant Accessibility after each rebuild."
fi
codesign --force --sign "$SIGN_ARG" --identifier "$BUNDLE_ID" "$APP/Contents/Frameworks/libinkline_core.dylib"
codesign --force --sign "$SIGN_ARG" --identifier "$BUNDLE_ID" "$APP/Contents/MacOS/Inkline"
codesign --force --sign "$SIGN_ARG" --identifier "$BUNDLE_ID" "$APP"

# Point the app at a model: first *.gguf in models/ (override with INKLINE_MODEL).
MODEL_PATH="${INKLINE_MODEL:-$(ls "$ROOT"/models/*.gguf 2>/dev/null | head -1 || true)}"
if [[ -n "$MODEL_PATH" ]]; then
    defaults write "$BUNDLE_ID" InklineModelPath "$MODEL_PATH"
    echo "==> Model: $MODEL_PATH"
else
    defaults delete "$BUNDLE_ID" InklineModelPath >/dev/null 2>&1 || true
    echo "==> No GGUF in models/ — core will use the stub generator."
fi

if [[ "${1:-}" == "--build" ]]; then
    echo "==> Built: $APP"
    exit 0
fi

echo "==> Launching Inkline.app…"
echo "    • First run: grant Accessibility in System Settings when prompted."
echo "    • Then type in TextEdit; press Tab to accept ghost text, Esc to dismiss."
echo "    • Quit from the ✎ menu-bar item."
echo "    • Logs: log stream --predicate 'process == \"Inkline\"' --level info"
# Relaunch fresh so a new build is picked up.
osascript -e 'quit app "Inkline"' >/dev/null 2>&1 || true
sleep 0.3
open "$APP"
