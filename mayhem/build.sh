#!/usr/bin/env bash
#
# mayhem/build.sh — build mozjpeg's fuzz harnesses (sanitized + standalone) and the ctest oracle.
# Runs inside the commit image as `mayhem` in /mayhem; offline-safe (no fetches), idempotent.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
B="$SRC/mayhem/build"
mkdir -p "$B"

# Arithmetic coding on: cjpeg_fuzzer passes -arithmetic (cjpeg exit()s without it) and upstream ships testimgari.jpg.
ARITH="-DWITH_ARITH_ENC=1 -DWITH_ARITH_DEC=1"
# The cmake cache embeds the resolved compiler path (ccache masquerade at image build, /usr/bin later); a
# changed path makes cmake discard the cache AND the -D flags, so every configure starts from a clean cache.

# Fuzz target -> harness source under fuzz/ (upstream names the decompress harness libjpeg_turbo).
# Upstream's fuzz/CMakeLists.txt is not used: it omits rdjpeg.c/cjpeg's 12/16-bit readers (cjpeg_fuzzer
# no longer links) and builds compress12_lossless_fuzzer from compress12.cc instead of its own source.
FUZZERS="cjpeg compress compress12 compress12_lossless compress_lossless compress16_lossless compress_yuv libjpeg_turbo decompress_yuv transform"
harness_src() { case "$1" in libjpeg_turbo) echo decompress;; *) echo "$1";; esac; }

# Leak detection off at build time (ASan/UBSan stay on and halting).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$B/lsan_off.o"
# Run-once driver, compiled as C so LLVMFuzzerTestOneInput keeps C linkage.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "${STANDALONE_FUZZ_MAIN:-/opt/mayhem/StandaloneFuzzTargetMain.c}" -o "$B/standalone_main.o"

# build_variant <name> <extra compile flags> <engine object/flags>: sanitized libs + every harness.
build_variant() {
  local name="$1" extra="$2" engine="$3" d="$B/$1" cf f
  cf="$SANITIZER_FLAGS $DEBUG_FLAGS $extra"
  rm -rf "$d/CMakeCache.txt" "$d/CMakeFiles"
  cmake -S "$SRC" -B "$d" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$cf" -DCMAKE_CXX_FLAGS="$cf" \
    -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS" \
    -DWITH_SIMD=0 -DPNG_SUPPORTED=0 -DBUILD_SHARED_LIBS=0 $ARITH
  cmake --build "$d" -j"$MAYHEM_JOBS" --target jpeg-static turbojpeg-static
  mkdir -p "$d/obj"
  local cdj="-DBMP_SUPPORTED -DGIF_SUPPORTED -DPPM_SUPPORTED -DTARGA_SUPPORTED"
  for f in cdjpeg rdbmp rdgif rdppm rdjpeg rdswitch rdtarga; do
    $CC $cf -O2 -DNDEBUG $cdj -I"$SRC" -I"$d" -c "$SRC/$f.c" -o "$d/obj/$f.o"
  done
  for f in rdgif rdppm; do
    for bits in 12 16; do
      $CC $cf -O2 -DNDEBUG -DBITS_IN_JSAMPLE=$bits -DGIF_SUPPORTED -DPPM_SUPPORTED \
        -I"$SRC" -I"$d" -c "$SRC/$f.c" -o "$d/obj/${f}$bits.o"
    done
  done
  mkdir -p "$d/fuzz"
  for f in $FUZZERS; do
    if [ "$f" = cjpeg ]; then
      $CXX $cf -O2 -DNDEBUG $cdj -I"$SRC" -I"$d" -c "$SRC/mayhem/cjpeg_harness.cc" -o "$d/obj/cjpeg_harness.o"
      $CXX $cf $d/obj/cjpeg_harness.o $d/obj/{cdjpeg,rdbmp,rdgif,rdppm,rdjpeg,rdswitch,rdtarga,rdgif12,rdgif16,rdppm12,rdppm16}.o \
        ${engine//;/ } "$d/libjpeg.a" -lm -o "$d/fuzz/${f}_fuzzer"
    else
      $CXX $cf -O2 -DNDEBUG -I"$SRC" -I"$d" "$SRC/fuzz/$(harness_src "$f").cc" \
        ${engine//;/ } "$d/libturbojpeg.a" -lm -o "$d/fuzz/${f}_fuzzer"
    fi
  done
}

# 1) libFuzzer binaries: project instrumented with sanitizers + SanCov (fuzzer-no-link).
build_variant fuzz "-fsanitize=fuzzer-no-link" "$LIB_FUZZING_ENGINE;$B/lsan_off.o"
# 2) Standalone (non-fuzzer) reproducers: same sanitizers, run-once driver instead of libFuzzer.
build_variant standalone "" "$B/standalone_main.o;$B/lsan_off.o"
for f in $FUZZERS; do
  cp "$B/fuzz/fuzz/${f}_fuzzer" "$SRC/${f}_fuzzer"
  cp "$B/standalone/fuzz/${f}_fuzzer" "$SRC/${f}_fuzzer-standalone"
done

# 3) Oracle build: the project's NORMAL flags, no sanitizers, no fuzz targets; test.sh runs ctest on it.
rm -rf "$B/tests/CMakeCache.txt" "$B/tests/CMakeFiles"
cmake -S "$SRC" -B "$B/tests" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DWITH_SIMD=0 -DPNG_SUPPORTED=0 -DBUILD_SHARED_LIBS=0 $ARITH
cmake --build "$B/tests" -j"$MAYHEM_JOBS"
