#!/usr/bin/env bash
# MT Pro - FFmpeg 9.0 (Android arm64) build with Vulkan enabled
# Run on Linux (Ubuntu / GitHub Actions) with Android NDK installed.
# (FFmpeg 9.0 needs no shader compiler option: Vulkan is autodetected)
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

echo "==> [1/3] vulkan.pc (headers + libvulkan.so come from the NDK)"
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

echo "==> [2/3] FFmpeg $FFMPEG_VER source"
cd "$WORK"
if [ ! -d ffmpeg ]; then
  if curl -fL "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VER.tar.xz" -o ffmpeg.tar.xz; then
    mkdir ffmpeg && tar -xf ffmpeg.tar.xz -C ffmpeg --strip-components=1
  else
    git clone --depth 1 -b "release/$FFMPEG_VER" https://git.ffmpeg.org/ffmpeg.git ffmpeg
  fi
fi
cd ffmpeg

echo "==> [3/3] configure + make"

# Show Vulkan related options of this FFmpeg version in the log
./configure --help | grep -iE 'shaderc|glslang|spirv|vulkan' || true

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
  --enable-vulkan \
  --extra-cflags="-O3 -fpic" \
  --extra-ldexeflags="-pie"

make -j"$JOBS"

cp ffmpeg  "$WORK/out/libffmpeg_exec.so"
cp ffprobe "$WORK/out/libffprobe_exec.so"
"$TC/bin/llvm-strip" "$WORK/out/"*.so

echo "==> Verify"
readelf -d "$WORK/out/libffmpeg_exec.so" | grep NEEDED || true
strings -a "$WORK/out/libffmpeg_exec.so" > "$WORK/strings.txt"
for f in scale_vulkan nlmeans_vulkan avgblur_vulkan xfade_vulkan; do
  if grep -qx "$f" "$WORK/strings.txt"; then echo "OK  $f"; else echo "MISSING $f"; fi
done
ls -lh "$WORK/out"
