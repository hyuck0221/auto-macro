#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
CLT_LIBRARIES="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

cd "$ROOT"

# GitHub-hosted Xcode toolchains run Swift Testing through the standard test
# command. Newer toolchains reject the old explicit enable flag below.
if [[ "${CI:-}" == "true" ]]; then
    exec swift test
fi

if [[ ! -d "$CLT_FRAMEWORKS/Testing.framework" ]]; then
    exec swift test
fi

# CommandLineTools 26 can compile Swift Testing but its swiftpm-testing-helper
# does not invoke the test bundle entry point. Build with SwiftPM, then link the
# same objects to the tiny executable entry point bundled with this project.
swift test --enable-swift-testing --disable-xctest >/dev/null
BIN_DIR="$(swift build --show-bin-path)"
APP_BUILD="$BIN_DIR/AutoMacroApp.build"
TEST_BUILD="$BIN_DIR/AutoMacroAppTests.build"
MODULES="$BIN_DIR/Modules"
RUNNER="${TMPDIR:-/tmp}/AutoMacroSwiftTests"

app_objects=("$APP_BUILD"/*.swift.o)
filtered_objects=()
for object in "${app_objects[@]}"; do
    if [[ "$object" != */AutoMacroApp.swift.o ]]; then
        filtered_objects+=("$object")
    fi
done
test_objects=("$TEST_BUILD"/*.swift.o)

swiftc -parse-as-library \
    "$ROOT/Scripts/SwiftTestingMain.swift" \
    "${filtered_objects[@]}" \
    "${test_objects[@]}" \
    -I "$MODULES" \
    -F "$CLT_FRAMEWORKS" \
    -framework Testing \
    -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$CLT_LIBRARIES" \
    -o "$RUNNER"

exec "$RUNNER"
