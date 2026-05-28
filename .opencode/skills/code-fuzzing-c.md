---
name: code-fuzzing-c
description: >-
  Use when fuzzing C or C++ code. Covers ASAN/UBSan/TSAN setup, harness
  writing, libFuzzer/AFL++/cargo-fuzz orchestration, crash triage via
  sanitizer traces, PoC generation, and corpus strategies.
---

# C/C++ Fuzzing Playbook

## 1. Sanitizer Compiler Flags

```bash
# ASAN + UBSan (recommended for first pass)
export CFLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -g -O1"
export CXXFLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -g -O1"
export LDFLAGS="-fsanitize=address,undefined"

# ASAN + UBSan + Coverage (for libFuzzer)
export CFLAGS="-fsanitize=address,undefined,fuzzer-no-link -fno-omit-frame-pointer -g -O1 -fcoverage-mapping"
export CXXFLAGS="-fsanitize=address,undefined,fuzzer-no-link -fno-omit-frame-pointer -g -O1 -fcoverage-mapping"

# TSAN (for race conditions — needs pure instrumented linkage)
export CFLAGS="-fsanitize=thread -g -O1 -fno-omit-frame-pointer"
export CXXFLAGS="-fsanitize=thread -g -O1 -fno-omit-frame-pointer"

# MSan (for uninitialized memory reads)
export CFLAGS="-fsanitize=memory -g -O2 -fno-omit-frame-pointer -fsanitize-memory-track-origins"
```

**Environment variable helpers:**
```bash
export ASAN_OPTIONS="detect_leaks=1:halt_on_error=1:abort_on_error=1:print_stats=1"
export UBSAN_OPTIONS="halt_on_error=1:abort_on_error=1:print_stacktrace=1"
export TSAN_OPTIONS="halt_on_error=1:log_path=./tsan.log"
export LSAN_OPTIONS="suppressions=lsan.supp"
```

## 2. Fuzzing Engine Setup

### libFuzzer (C/C++, clang)
```bash
# Single-file harness
clang++ -fsanitize=address,fuzzer -g -O1 harness.cpp -o fuzzer

# With project library
clang++ -fsanitize=address,fuzzer -g -O1 harness.cpp target.o -o fuzzer
```

### AFL++ (if installed)
```bash
afl-clang-fast -fsanitize=address -g -O1 harness.c -o fuzzer_afl
afl-fuzz -i corpus/ -o findings/ ./fuzzer_afl @@
```

### cargo-fuzz (Rust)
```bash
cargo init --lib myfuzz && cd myfuzz
cargo fuzz init
# write fuzz_targets/fuzz_1.rs
cargo fuzz add fuzz_1
cargo fuzz run fuzz_1 -- -max_len=4096 -runs=1000000
```

## 3. Harness Writing

### libFuzzer C harness
```c
// fuzz_harness.c
#include <stdint.h>
#include <stddef.h>

extern int target_function(const char *input, size_t len);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    // null-terminate if target expects strings
    char *buf = (char *)malloc(size + 1);
    if (!buf) return 0;
    memcpy(buf, data, size);
    buf[size] = '\0';

    target_function(buf, size);

    free(buf);
    return 0;
}
```

### libFuzzer C++ harness
```cpp
// fuzz_harness.cpp
#include <stdint.h>
#include <stddef.h>
#include <string>
#include <vector>

extern void parse_config(const std::string &input);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    std::string input(reinterpret_cast<const char *>(data), size);
    parse_config(input);
    return 0;
}
```

### Key rules:
1. **No ASSERT in harness** — ASSERT crashes in debug but not in fuzzer
2. **Catch exceptions** in C++ harnesses if target might throw
3. **Limit memory** via `-rss_limit_mb=2048`
4. **Timeout per input** via `-timeout=10`

## 4. Running the Fuzzer

```bash
# Basic run
./fuzzer -max_len=4096 -runs=1000000 corpus/

# With dictionary
./fuzzer -dict=protocol.dict -max_len=8192 corpus/

# Merge corpora
./fuzzer -merge=1 new_corpus/ existing_corpus/

# Minimize a specific crash
./fuzzer -minimize_crash=1 -exact_artifact_path=minimal.poc crash-*.bin
```

## 5. Crash Triage

### ASAN trace interpretation
```
=== ASAN: heap-buffer-overflow ===
READ of size 4 at 0x...  →  read past allocated buffer
  #0 memcpy()                             → 源头：memcpy size too large
  #1 parse_header(buf, len)               →  falta bound check
  #2 LLVMFuzzerTestOneInput               →  input triggers header parsing

=== ASAN: heap-use-after-free ===
  #0 target_method()                      →  usando ptr after free
  #1 ...                                  →  buscar double free o dangling ref

=== ASAN: stack-buffer-overflow ===
  → array local sin bound check

=== UBSan: undefined behavior ===
  src/target.c:123: signed integer overflow
  src/target.c:456: shift exponent too large
```

### Crash classification
| Sanitizer | Signal | Bug Class | CVE Potential |
|-----------|--------|-----------|---------------|
| ASAN | SIGABRT/SIGSEGV | OOB read/write | High |
| ASAN+LSAN | SIGABRT | Use-after-free | High |
| ASAN | SIGABRT | Double-free | High |
| UBSan | SIGABRT | Integer overflow | Medium |
| UBSan | SIGABRT | Shift exponent UB | Medium |
| TSAN | SIGABRT | Data race | High |
| MSan | SIGABRT | Uninit memory | Medium |

## 6. PoC Generation

```bash
# libFuzzer writes crash-*.bin automatically
# To convert to human-readable PoC:

# Hex dump
xxd crash-123.bin | head -20

# Base64 (for web input PoCs)
base64 crash-123.bin > poc.txt

# Check if repro works with target binary
./target_program $(cat crash-123.bin)
```

For PoC files that demonstrate the bug:
1. Use the crash input file as-is
2. Minimize it: `./fuzzer -minimize_crash=1 -exact_artifact_path=min.poc crash.bin`
3. Write a standalone reproducer script/program
4. Include the ASAN trace in the PoC

## 7. Corpus Strategies

1. **Seed corpus from existing tests** — `find tests/ -name '*.bin' -o -name '*.dat'`
2. **Dictionary generation** — extract keywords/patterns from source
3. **Fuzz one function at a time** — better coverage than end-to-end
4. **Merge corpora** regularly to remove redundant inputs
5. **Use `-fork=N`** or `-jobs=N` for parallel fuzzing

## 8. High-Value Fuzz Targets in C/C++ Code

1. **Parsers** — config files, wire protocols, serialization
2. **URL/URI handlers** — `parse_url`, `url_decode`, query string parsers
3. **String utilities** — `strcpy`, `sprintf`, custom string builders
4. **Compression/decompression** — zlib, brotli, custom formats
5. **Network message handlers** — protocol decoders, packet parsers
6. **Config loaders** — YAML/JSON/TOML/INI parsers
7. **File format parsers** — image, audio, archive format decoders
8. **Command/argument parsers** — `getopt`, custom CLI parsers

## 9. Automation Workflow

```
1. git clone <target>
2. Identify small parsing functions (< 50 lines) that handle input
3. Write harness around each function
4. Compile with: -fsanitize=address,undefined,fuzzer -g -O1
5. Run: ./fuzzer -max_len=4096 -runs=500000 -timeout=10 corpus/
6. On crash:
   a. Minimize input
   b. Read ASAN trace → identify root cause
   c. Verify with standalone repro
   d. Classify bug type + severity
   e. Write PoC
```
