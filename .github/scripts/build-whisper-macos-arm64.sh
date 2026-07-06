#!/usr/bin/env bash
set -euo pipefail

DEPS_DIR="${VOICEINK_DEPS_DIR:-$HOME/VoiceInk-Dependencies}"
WHISPER_CPP_DIR="$DEPS_DIR/whisper.cpp"
FRAMEWORK_PATH="$WHISPER_CPP_DIR/build-apple/whisper.xcframework"
WHISPER_CPP_REF="${WHISPER_CPP_REF:-master}"

mkdir -p "$DEPS_DIR"

if [ -d "$FRAMEWORK_PATH" ]; then
  echo "Using cached whisper.xcframework at $FRAMEWORK_PATH"
  exit 0
fi

if [ ! -d "$WHISPER_CPP_DIR/.git" ]; then
  rm -rf "$WHISPER_CPP_DIR"
  git clone --depth 1 --branch "$WHISPER_CPP_REF" https://github.com/ggml-org/whisper.cpp.git "$WHISPER_CPP_DIR"
fi

cd "$WHISPER_CPP_DIR"

echo "Building whisper.cpp ref: $(git rev-parse --short HEAD)"

cmake -B build-macos -G Xcode \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="" \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_BLAS_DEFAULT=ON \
  -DGGML_METAL_USE_BF16=ON \
  -DGGML_NATIVE=OFF \
  -DGGML_OPENMP=OFF \
  -DWHISPER_COREML=ON \
  -DWHISPER_COREML_ALLOW_FALLBACK=ON \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -S .

cmake --build build-macos --config Release -- -quiet

FRAMEWORK_DIR="$WHISPER_CPP_DIR/build-apple/macos-arm64/whisper.framework"
BIN_PATH="$FRAMEWORK_DIR/Versions/A/whisper"
HEADER_DIR="$FRAMEWORK_DIR/Versions/A/Headers"
MODULE_DIR="$FRAMEWORK_DIR/Versions/A/Modules"
RESOURCE_DIR="$FRAMEWORK_DIR/Versions/A/Resources"
TEMP_DIR="$WHISPER_CPP_DIR/build-apple/temp"

rm -rf "$WHISPER_CPP_DIR/build-apple"
mkdir -p "$HEADER_DIR" "$MODULE_DIR" "$RESOURCE_DIR" "$TEMP_DIR"

ln -sfn A "$FRAMEWORK_DIR/Versions/Current"
ln -sfn Versions/Current/Headers "$FRAMEWORK_DIR/Headers"
ln -sfn Versions/Current/Modules "$FRAMEWORK_DIR/Modules"
ln -sfn Versions/Current/Resources "$FRAMEWORK_DIR/Resources"
ln -sfn Versions/Current/whisper "$FRAMEWORK_DIR/whisper"

cp include/whisper.h "$HEADER_DIR/"
[ -f include/parakeet.h ] && cp include/parakeet.h "$HEADER_DIR/"
cp ggml/include/ggml.h "$HEADER_DIR/"
cp ggml/include/ggml-alloc.h "$HEADER_DIR/"
cp ggml/include/ggml-backend.h "$HEADER_DIR/"
cp ggml/include/ggml-metal.h "$HEADER_DIR/"
cp ggml/include/ggml-cpu.h "$HEADER_DIR/"
cp ggml/include/ggml-blas.h "$HEADER_DIR/"
cp ggml/include/gguf.h "$HEADER_DIR/"

cat > "$MODULE_DIR/module.modulemap" <<'MODULEMAP'
framework module whisper {
    header "whisper.h"
    header "ggml.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    header "ggml-metal.h"
    header "ggml-cpu.h"
    header "ggml-blas.h"
    header "gguf.h"

    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"

    export *
}
MODULEMAP

cat > "$RESOURCE_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>whisper</string>
    <key>CFBundleIdentifier</key>
    <string>org.ggml.whisper</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>whisper</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>13.3</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>DTPlatformName</key>
    <string>macosx</string>
</dict>
</plist>
PLIST

libs=(
  "build-macos/src/Release/libwhisper.a"
  "build-macos/src/Release/libparakeet.a"
  "build-macos/src/Release/libwhisper.coreml.a"
  "build-macos/ggml/src/Release/libggml.a"
  "build-macos/ggml/src/Release/libggml-base.a"
  "build-macos/ggml/src/Release/libggml-cpu.a"
  "build-macos/ggml/src/ggml-metal/Release/libggml-metal.a"
  "build-macos/ggml/src/ggml-blas/Release/libggml-blas.a"
)

existing_libs=()
for lib in "${libs[@]}"; do
  if [ -f "$lib" ]; then
    existing_libs+=("$lib")
  else
    echo "Skipping missing optional library: $lib"
  fi
done

libtool -static -o "$TEMP_DIR/combined.a" "${existing_libs[@]}"

xcrun -sdk macosx clang++ -dynamiclib \
  -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
  -arch arm64 \
  -mmacosx-version-min=13.3 \
  -Wl,-force_load,"$TEMP_DIR/combined.a" \
  -framework Foundation \
  -framework Metal \
  -framework Accelerate \
  -framework CoreML \
  -install_name "@rpath/whisper.framework/Versions/Current/whisper" \
  -o "$BIN_PATH"

xcodebuild -create-xcframework \
  -framework "$FRAMEWORK_DIR" \
  -output "$FRAMEWORK_PATH"

xcrun lipo -archs "$BIN_PATH"
find "$FRAMEWORK_PATH" -maxdepth 3 -type f -o -type l
