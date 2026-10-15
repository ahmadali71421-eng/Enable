#!/usr/bin/env bash
# MT Pro - FFmpeg 9.0 (Android arm64) build with Vulkan enabled
# Run on Linux (Ubuntu / GitHub Actions) with Android NDK installed.
# Output: build_mt/out/libffmpeg_exec.so and libffprobe_exec.so
# (executables named lib*.so so Android packages them from jniLibs, same trick as libsox_exec.so)
set -euo pipefail

NDK="${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to your NDK path}"
API=28
FFMPEG_VER=9.0
TARGET=aarch64-linux-android
WORK="$PWD/build_mt"
PREFIX="$WORK/prefix"
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
SYSROOT="$TC/sysroot"
export PATH="$TC/bin:$PATH"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
mkdir -p "$WORK/out" "$PREFIX/lib/pkgconfig" "$PREFIX/include"
JOBS="$(nproc)"

echo "==> [1/4] vulkan.pc (headers + libvulkan.so come from the NDK)"
VKH="$SYSROOT/usr/include/vulkan/vulkan_core.h"
VKVER="$(grep -m1 '#define VK_HEADER_VERSION ' "$VKH" | awk '{print $3}')"
if grep -q 'VK_API_VERSION_1_4' "$VKH"; then VKMAJ="1.4"; else VKMAJ="1.3"; fi
cat > "$PREFIX/lib/pkgconfig/vulkan.pc" <<EOF
prefix=$SYSROOT/usr
includedir=\${prefix}/include
libdir=\${prefix}/lib/$TARGET/$API
Name: vulkan
Description: Vulkan (Android NDK)
Version: $VKMAJ.$VKVER
Libs: -L\${libdir} -lvulkan
Cflags: -I\${includedir}
EOF

echo "==> [2/4] shaderc (FFmpeg Vulkan filters need a GLSL->SPIR-V compiler)"
cd "$WORK"
if [ ! -d shaderc ]; then
  git clone --depth 1 https://github.com/google/shaderc.git
  (cd shaderc && python3 utils/git-sync-deps)
fi
cmake -S shaderc -B shaderc/build -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-$API -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release \
  -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON -DSHADERC_SKIP_COPYRIGHT_CHECK=ON \
  -DSHADERC_ENABLE_SHARED_CRT=ON
cmake --build shaderc/build -j"$JOBS" --target shaderc_combined
cp shaderc/build/libshaderc/libshaderc_combined.a "$PREFIX/lib/"
cp -r shaderc/libshaderc/include/shaderc "$PREFIX/include/"
cat > "$PREFIX/lib/pkgconfig/shaderc.pc" <<EOF
prefix=$PREFIX
Name: shaderc
Description: shaderc (static)
Version: 2024.1
Libs: -L$PREFIX/lib -lshaderc_combined -lc++_static -lc++abi
Cflags: -I$PREFIX/include
EOF

echo "==> [3/4] FFmpeg $FFMPEG_VER source"
cd "$WORK"
if [ ! -d ffmpeg ]; then
  if curl -fL "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VER.tar.xz" -o ffmpeg.tar.xz; then
    mkdir ffmpeg && tar -xf ffmpeg.tar.xz -C ffmpeg --strip-components=1
  else
    git clone --depth 1 -b "release/$FFMPEG_VER" https://git.ffmpeg.org/ffmpeg.git ffmpeg
  fi
fi
cd ffmpeg

echo "==> [4/4] configure + make"

# FFmpeg renames this option between versions, so read it from configure --help
HELP="$(./configure --help)"
echo "---- Vulkan / shader related options in this FFmpeg ----"
echo "$HELP" | grep -iE 'shaderc|glslang|spirv|vulkan' || true
echo "--------------------------------------------------------"
SPV_OPT=""
for o in --enable-libshaderc --enable-shaderc --enable-spirv-compiler; do
  if echo "$HELP" | grep -qE -- "^[[:space:]]*${o}([[:space:]=]|$)"; then SPV_OPT="$o"; break; fi
done
if [ -z "$SPV_OPT" ]; then
  echo "ERROR: no shaderc option found in ./configure --help. Send the list above to Claude."
  exit 1
fi
echo "Using shader compiler option: $SPV_OPT"

./configure \
  --prefix="$WORK/ffout" \
  --target-os=android --arch=aarch64 --cpu=armv8-a \
  --enable-cross-compile \
  --cc="$TC/bin/${TARGET}${API}-clang" --cxx="$TC/bin/${TARGET}${API}-clang++" \
  --ar="$TC/bin/llvm-ar" --nm="$TC/bin/llvm-nm" --ranlib="$TC/bin/llvm-ranlib" --strip="$TC/bin/llvm-strip" \
  --sysroot="$SYSROOT" \
  --pkg-config=pkg-config --pkg-config-flags="--static" \
  --disable-gpl --disable-nonfree \
  --enable-static --disable-shared --enable-pic \
  --disable-doc --disable-ffplay --enable-ffmpeg --enable-ffprobe \
  --enable-network --enable-iconv --disable-bzlib \
  --enable-gray --enable-swscale-alpha --enable-runtime-cpudetect \
  --enable-jni --enable-mediacodec \
  --enable-vulkan $SPV_OPT \
  --extra-cflags="-O3 -fpic" \
  --extra-ldexeflags="-pie"

make -j"$JOBS"

cp ffmpeg  "$WORK/out/libffmpeg_exec.so"
cp ffprobe "$WORK/out/libffprobe_exec.so"
"$TC/bin/llvm-strip" "$WORK/out/"*.so

echo "==> Verify"
readelf -d "$WORK/out/libffmpeg_exec.so" | grep NEEDED || true
for f in scale_vulkan nlmeans_vulkan avgblur_vulkan xfade_vulkan; do
  strings -a "$WORK/out/libffmpeg_exec.so" | grep -qx "$f" && echo "OK  $f" || echo "MISSING $f"
done
ls -lh "$WORK/out"
