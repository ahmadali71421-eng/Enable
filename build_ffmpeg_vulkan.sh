#!/usr/bin/env bash
# MT Pro - FFmpeg 9.0 (Android arm64) FULL build
#   Vulkan filters (needs host glslc + SPIR-V headers), x264, MP3 (lame), Opus, Vorbis,
#   freetype (drawtext), libass (subtitles), libwebp, dav1d (AV1 decode), soxr (audio resampler)
# Every extra library is optional: if one fails to build it is skipped and the rest still build.
# Output: build_mt/out/libffmpeg_exec.so and libffprobe_exec.so
set -euo pipefail

ENABLE_GPL=1        # 1 = x264 + GPL filters (hqdn3d etc). App/license becomes GPL. 0 = LGPL only.
API=28
FFMPEG_VER=9.0
TARGET=aarch64-linux-android

export API TARGET FFMPEG_VER ENABLE_GPL   # the per-library sub-shells need these too
set -a   # export everything below so the per-library sub-shells see it
NDK="${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to your NDK path}"
WORK="$PWD/build_mt"; PREFIX="$WORK/prefix"; SRC="$WORK/src"
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64"; SYSROOT="$TC/sysroot"
JOBS="$(nproc)"
PATH="$TC/bin:$PATH"
CC="$TC/bin/${TARGET}${API}-clang"; CXX="$TC/bin/${TARGET}${API}-clang++"
AR="$TC/bin/llvm-ar"; RANLIB="$TC/bin/llvm-ranlib"; STRIP="$TC/bin/llvm-strip"; NM="$TC/bin/llvm-nm"
CFLAGS="-O3 -fPIC -I$PREFIX/include"; CXXFLAGS="-O3 -fPIC -I$PREFIX/include"; LDFLAGS="-L$PREFIX/lib"
PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"; PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
CXXLIBS="-lc++_static -lc++abi"
set +a
mkdir -p "$WORK/out" "$SRC" "$PREFIX/lib/pkgconfig" "$PREFIX/include"

echo "==> [0] host tools (glslc + SPIR-V headers are needed for Vulkan filters)"
SUDO=""; [ "$(id -u)" != "0" ] && SUDO="sudo"
$SUDO apt-get update -y >/dev/null
for p in cmake ninja-build pkg-config python3 git curl xz-utils make meson glslc spirv-headers; do
  $SUDO apt-get install -y "$p" >/dev/null || echo "WARNING: could not install $p"
done
command -v glslc || echo "WARNING: glslc not found, Vulkan filters will not build"
[ -d /usr/include/spirv ] && cp -r /usr/include/spirv "$PREFIX/include/" || echo "WARNING: spirv headers not found"

echo "==> [0b] glslc that understands Vulkan 1.4 (Ubuntu's apt glslc is too old for FFmpeg 9.0)"
glslc_ok() {
  printf '#version 460\nlayout(local_size_x=1) in;\nvoid main(){}\n' > /tmp/t.comp
  "$1" --target-env=vulkan1.4 --target-spv=spv1.6 -o /tmp/t.spv /tmp/t.comp >/dev/null 2>&1
}
GLSLC=""
for c in "$NDK/shader-tools/linux-x86_64/glslc" "$(command -v glslc || true)"; do
  if [ -n "$c" ] && [ -x "$c" ] && glslc_ok "$c"; then GLSLC="$c"; break; fi
done
if [ -z "$GLSLC" ]; then
  echo "    No usable glslc found, building shaderc/glslc from source (host build, ~10 min)"
  HOSTB="$WORK/hostbin"; mkdir -p "$HOSTB"
  (
    set -e
    cd "$WORK"
    [ -d shaderc_host ] || git clone --depth 1 https://github.com/google/shaderc.git shaderc_host
    cd shaderc_host
    python3 utils/git-sync-deps
    env -u CC -u CXX -u CFLAGS -u CXXFLAGS -u LDFLAGS -u AR -u RANLIB -u STRIP -u NM \
      cmake -S . -B _b -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON -DSHADERC_SKIP_COPYRIGHT_CHECK=ON
    env -u CC -u CXX -u CFLAGS -u CXXFLAGS -u LDFLAGS -u AR -u RANLIB -u STRIP -u NM \
      cmake --build _b --target glslc_exe -j"$JOBS"
    cp _b/glslc/glslc "$HOSTB/glslc"
  ) && glslc_ok "$HOSTB/glslc" && GLSLC="$HOSTB/glslc" || echo "WARNING: could not build a usable glslc"
fi
if [ -n "$GLSLC" ]; then
  export PATH="$(dirname "$GLSLC"):$PATH"
  echo "    Using glslc: $GLSLC"
  glslc --version > "$WORK/glslc_version.txt" 2>&1 || true
  head -n 4 "$WORK/glslc_version.txt"
fi

echo "==> [1] vulkan.pc (Vulkan headers + libvulkan.so come from the NDK)"
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

# ---------- helpers ----------
fetch() {  # fetch <url> <dir>   (extracts tarball into $SRC/<dir>)
  [ -d "$SRC/$2" ] && return 0
  mkdir -p "$SRC/$2"
  curl -fL --retry 3 "$1" -o "$SRC/$2.tar"
  tar -xf "$SRC/$2.tar" -C "$SRC/$2" --strip-components=1
}
cmk() {    # cmk <srcdir> [extra cmake args]
  local s="$1"; shift
  cmake -S "$s" -B "$s/_b" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-$API -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_FIND_ROOT_PATH="$PREFIX" \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "$@"
  cmake --build "$s/_b" -j"$JOBS"
  cmake --install "$s/_b"
}
acfg() {   # autotools cross configure + build + install
  ./configure --host="$TARGET" --prefix="$PREFIX" --disable-shared --enable-static --with-pic "$@"
  make -j"$JOBS"; make install
}

# ---------- libraries ----------
lib_ogg()    { fetch https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.xz ogg; cd "$SRC/ogg"; acfg; }
lib_vorbis() { fetch https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.xz vorbis; cd "$SRC/vorbis"; acfg --with-ogg="$PREFIX" --disable-oggtest; }
lib_opus()   { fetch https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz opus; cd "$SRC/opus"; acfg --disable-doc --disable-extra-programs; }
lib_lame()   { fetch https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz lame; cd "$SRC/lame"; acfg --disable-frontend; }
lib_x264()   {
  if [ ! -d "$SRC/x264" ]; then git clone --depth 1 https://code.videolan.org/videolan/x264.git "$SRC/x264"; fi
  cd "$SRC/x264"
  AS="$CC" ./configure --host="$TARGET" --cross-prefix="$TC/bin/llvm-" --prefix="$PREFIX" \
    --enable-static --enable-pic --disable-cli --disable-opencl
  make -j"$JOBS"; make install
}
lib_freetype() {
  fetch https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz freetype
  cmk "$SRC/freetype" -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON
}
lib_fribidi() { fetch https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz fribidi; cd "$SRC/fribidi"; acfg --disable-docs; }
lib_harfbuzz() {
  fetch https://github.com/harfbuzz/harfbuzz/releases/download/10.1.0/harfbuzz-10.1.0.tar.xz harfbuzz
  cmk "$SRC/harfbuzz" -DHB_HAVE_FREETYPE=ON -DHB_BUILD_UTILS=OFF \
    -DFREETYPE_LIBRARY="$PREFIX/lib/libfreetype.a" \
    -DFREETYPE_INCLUDE_DIR_freetype2="$PREFIX/include/freetype2" -DFREETYPE_INCLUDE_DIR_ft2build="$PREFIX/include/freetype2"
}
lib_libass() {
  fetch https://github.com/libass/libass/releases/download/0.17.3/libass-0.17.3.tar.xz libass
  cd "$SRC/libass"
  LIBS="$CXXLIBS" acfg --disable-fontconfig --disable-require-system-font-provider --disable-asm
}
lib_webp() {
  fetch https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.4.0.tar.gz webp
  cmk "$SRC/webp" -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
    -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
}
lib_dav1d() {
  fetch https://downloads.videolan.org/pub/videolan/dav1d/1.5.0/dav1d-1.5.0.tar.xz dav1d
  cat > "$SRC/cross.txt" <<EOX
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8-a'
endian = 'little'
EOX
  cd "$SRC/dav1d"
  meson setup _b --cross-file "$SRC/cross.txt" --prefix="$PREFIX" --libdir=lib --default-library=static \
    --buildtype=release -Denable_tools=false -Denable_tests=false
  ninja -C _b install
}
lib_soxr() {
  fetch https://downloads.sourceforge.net/project/soxr/soxr-0.1.3-Source.tar.xz soxr
  cmk "$SRC/soxr" -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF -DWITH_OPENMP=OFF -DWITH_LSR_BINDINGS=OFF
}
export -f fetch cmk acfg lib_ogg lib_vorbis lib_opus lib_lame lib_x264 lib_freetype lib_fribidi lib_harfbuzz lib_libass lib_webp lib_dav1d lib_soxr

FF_ENABLES=()
EXTRA_LIBS="-lm"
build() {  # build <name> <function>   (runs in its own bash so one failure does not stop the rest)
  echo "==> [lib] $1"
  if bash -euo pipefail -c "$2" > "$WORK/log_$1.txt" 2>&1; then
    echo "    OK      $1"; return 0
  else
    echo "    FAILED  $1 (skipped). Last log lines:"; tail -n 25 "$WORK/log_$1.txt" | sed 's/^/      /'; return 1
  fi
}

build ogg lib_ogg || true
if build ogg_check "test -f $PREFIX/lib/libogg.a"; then
  build vorbis lib_vorbis && FF_ENABLES+=(--enable-libvorbis)
fi
build opus lib_opus && FF_ENABLES+=(--enable-libopus)
build lame lib_lame && FF_ENABLES+=(--enable-libmp3lame)
if [ "$ENABLE_GPL" = "1" ]; then build x264 lib_x264 && FF_ENABLES+=(--enable-libx264); fi
if build freetype lib_freetype; then
  FF_ENABLES+=(--enable-libfreetype)
  if build fribidi lib_fribidi && build harfbuzz lib_harfbuzz; then
    FF_ENABLES+=(--enable-libfribidi --enable-libharfbuzz); EXTRA_LIBS="$EXTRA_LIBS $CXXLIBS"
    build libass lib_libass && FF_ENABLES+=(--enable-libass)
  fi
fi
build webp lib_webp && FF_ENABLES+=(--enable-libwebp)
build dav1d lib_dav1d && FF_ENABLES+=(--enable-libdav1d)
build soxr lib_soxr && FF_ENABLES+=(--enable-libsoxr)

echo "==> FFmpeg $FFMPEG_VER source"
cd "$WORK"
if [ ! -d ffmpeg ]; then
  if curl -fL "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VER.tar.xz" -o ffmpeg.tar.xz; then
    mkdir ffmpeg && tar -xf ffmpeg.tar.xz -C ffmpeg --strip-components=1
  else
    git clone --depth 1 -b "release/$FFMPEG_VER" https://git.ffmpeg.org/ffmpeg.git ffmpeg
  fi
fi
cd ffmpeg

GPL_FLAG="--disable-gpl"; [ "$ENABLE_GPL" = "1" ] && GPL_FLAG="--enable-gpl"
echo "==> FFmpeg configure. Extra libs enabled: ${FF_ENABLES[*]:-none}"
./configure \
  --prefix="$WORK/ffout" \
  --target-os=android --arch=aarch64 --cpu=armv8-a --enable-cross-compile \
  --cc="$CC" --cxx="$CXX" --ar="$AR" --nm="$NM" --ranlib="$RANLIB" --strip="$STRIP" \
  --sysroot="$SYSROOT" \
  --pkg-config=pkg-config --pkg-config-flags="--static" \
  $GPL_FLAG --disable-nonfree \
  --enable-static --disable-shared --enable-pic \
  --disable-doc --disable-ffplay --enable-ffmpeg --enable-ffprobe \
  --enable-network --enable-iconv --disable-bzlib \
  --enable-gray --enable-swscale-alpha --enable-runtime-cpudetect \
  --disable-jni --disable-mediacodec --disable-indev=android_camera \
  --enable-vulkan \
  ${FF_ENABLES[@]+"${FF_ENABLES[@]}"} \
  --extra-cflags="-O3 -fpic -I$PREFIX/include" \
  --extra-ldflags="-L$PREFIX/lib" \
  --extra-ldexeflags="-pie" \
  --extra-libs="$EXTRA_LIBS"

echo "---- configured features ----"
for k in VULKAN LIBX264 LIBMP3LAME LIBOPUS LIBVORBIS LIBFREETYPE LIBASS LIBWEBP LIBDAV1D LIBSOXR; do
  if grep -qE "^#define CONFIG_${k} 1" config.h; then echo "ON   $k"; else echo "OFF  $k"; fi
done
NVF="$(grep -hcE '^#define CONFIG_[A-Z0-9_]*VULKAN_FILTER 1' config_components.h || true)"
echo "Vulkan filters enabled: $NVF"
if [ "${NVF:-0}" = "0" ]; then
  echo "ERROR: no Vulkan filters enabled (glslc / SPIR-V headers problem). Relevant config.log lines:"
  grep -n -i -E 'glslc|spirv' ffbuild/config.log | tail -n 25 || true
  exit 1
fi

make -j"$JOBS"

cp ffmpeg  "$WORK/out/libffmpeg_exec.so"
cp ffprobe "$WORK/out/libffprobe_exec.so"
"$STRIP" "$WORK/out/"*.so

echo "==> Verify"
readelf -d "$WORK/out/libffmpeg_exec.so" | grep NEEDED || true
if readelf -d "$WORK/out/libffmpeg_exec.so" | grep -E 'libandroid|libmediandk|libcamera2ndk|libbinder'; then
  echo "WARNING: binary still links Android platform libs; it will not start as a standalone process"
fi
strings -a "$WORK/out/libffmpeg_exec.so" > "$WORK/strings.txt"
for f in scale_vulkan nlmeans_vulkan avgblur_vulkan xfade_vulkan drawtext subtitles hqdn3d; do
  if grep -qx "$f" "$WORK/strings.txt"; then echo "OK      $f"; else echo "MISSING $f"; fi
done
ls -lh "$WORK/out"
