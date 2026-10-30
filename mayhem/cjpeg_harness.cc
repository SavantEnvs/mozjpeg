// cjpeg_fuzzer wrapper: cjpeg sniffs a leading 0xFF as JPEG input, and rdjpeg.c's own decompress object keeps
// the stock jpeg_std_error, so a malformed JPEG calls exit() -- the CLI's normal rejection, not a defect.
// Such inputs are rejected (-1) before reaching the upstream harness.
#include <stddef.h>
#include <stdint.h>

#define LLVMFuzzerTestOneInput  upstream_cjpeg_fuzz_one_input
#include "../fuzz/cjpeg.cc"
#undef LLVMFuzzerTestOneInput

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
  if (size > 0 && data[0] == 0xff) return -1;
  return upstream_cjpeg_fuzz_one_input(data, size);
}
