#!/usr/bin/env bash
#
# mayhem/test.sh — RUN mozjpeg's OWN ctest suite (built by mayhem/build.sh), plus known-answer probes.
# exit 0 = pass. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

B="$SRC/mayhem/build/tests"
[ -f "$B/CTestTestfile.cmake" ] || { echo "missing $B — mayhem/build.sh must build the ctest tree first" >&2; exit 2; }

# ctest only judges exit codes, and the neutered-program check _exit(0)s every project binary it
# launches, so known-answer probes run the built tools from bash and compare exact output digests.
probes_pass=0; probes_fail=0
probe() {  # probe <name> <expected md5> <file>
  local got; got=$(md5sum "$3" 2>/dev/null | cut -d' ' -f1)
  if [ "$got" = "$2" ]; then probes_pass=$((probes_pass+1)); echo "PASS probe $1"
  else probes_fail=$((probes_fail+1)); echo "FAIL probe $1: got '${got}' want '$2'"; fi
}
T="$SRC/testimages"; W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
CJ="$B/cjpeg-static"; DJ="$B/djpeg-static"
[ -x "$CJ" ] && [ -x "$DJ" ] || { echo "missing cjpeg-static/djpeg-static in $B" >&2; exit 2; }
"$CJ" -revert -rgb -dct int -icc "$T/test1.icc" -outfile "$W/rgb.jpg" "$T/testorig.ppm"
probe cjpeg-rgb-islow 1d44a406f61da743b5fd31c0a9abdca3 "$W/rgb.jpg"
"$DJ" -dct int -ppm -outfile "$W/rgb.ppm" "$W/rgb.jpg"
probe djpeg-rgb-islow 00a257f5393fef8821f2b88ac7421291 "$W/rgb.ppm"
"$CJ" -revert -gray -dct int -outfile "$W/gray.jpg" "$T/testorig.ppm"
probe cjpeg-gray-islow 72b51f894b8f4a10b3ee3066770aa38d "$W/gray.jpg"
"$DJ" -dct int -outfile "$W/gray.ppm" "$W/gray.jpg"
probe djpeg-gray-islow 8d3596c56eace32f205deccc229aa5ed "$W/gray.ppm"

# Arithmetic coding is compiled in (WITH_ARITH_*), which activates two upstream jpegtran tests that omit
# -revert (mozjpeg's jpegtran defaults to progressive+optimized, so their digests can never match);
# they are replaced by the corrected probes below.
JT="$B/jpegtran-static"; [ -x "$JT" ] || { echo "missing jpegtran-static in $B" >&2; exit 2; }
"$JT" -revert -outfile "$W/ari2huff.jpg" "$T/testimgari.jpg"
probe jpegtran-ari-to-huff 9a68f56bc76e466aa7e52f415d0f4a5f "$W/ari2huff.jpg"
"$JT" -revert -arithmetic -outfile "$W/int2ari.jpg" "$T/testimgint.jpg"
probe jpegtran-huff-to-ari e986fb0a637a8d833d96e8a6d6d84ea1 "$W/int2ari.jpg"

out=$(cd "$B" && ctest -j"$MAYHEM_JOBS" -E 'jpegtran-static-420-islow(-ari)?-cmp' 2>&1); rc=$?
printf '%s\n' "$out" | tail -40
total=$(printf '%s\n' "$out" | sed -n 's/.*tests passed, [0-9]* tests failed out of \([0-9]*\).*/\1/p' | tail -1)
failed=$(printf '%s\n' "$out" | sed -n 's/.*tests passed, \([0-9]*\) tests failed out of.*/\1/p' | tail -1)
if [ -z "$total" ] || [ "${total:-0}" -eq 0 ]; then echo "ctest ran no tests" >&2; total=0; failed=1; fi
passed=$(( total - failed ))
[ "$rc" -eq 0 ] || [ "$failed" -gt 0 ] || failed=1
emit_ctrf "ctest+kat" $(( passed + probes_pass )) $(( failed + probes_fail )) 0
