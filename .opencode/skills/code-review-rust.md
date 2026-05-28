---
name: code-review-rust
description: >-
  Use when reviewing Rust source code for security vulnerabilities. Covers
  unsafe block analysis, integer issues, Send/Sync safety, panic safety,
  buffer overflow in FFI, cryptographic misuse, and unsafe code reachable
  via safe API. Patterned after reviews of blockchain, Web3, and systems
  programming targets.
---

# Rust Code Review for Vulnerabilities

## Key Insight: Rust's Safety is NOT Absolute

Rust prevents memory safety bugs in *safe* code, but:
- `unsafe` blocks bypass ALL safety guarantees
- Safe code can trigger panics → denial of service
- `unsafe` trait implementations (`Send`, `Sync`) can create race conditions
- FFI boundary is a trust violation point
- Integer overflow behavior depends on compilation mode

## Vulnerability Classes

### 1. Unsafe Block Analysis
```rust
// BAD: raw pointer dereference without validation
unsafe {
    let ptr = some_raw_pointer;
    let val = *ptr;  // UB if ptr is dangling/null
}

// BAD: unsafe transmute
unsafe {
    let bytes: [u8; 4] = [0x00, 0x00, 0x00, 0x01];
    let n: u32 = std::mem::transmute(bytes);  // UB if bytes not valid representation
}

// BAD: unsafe function returning safe type
fn lookup_data(key: &str) -> &[u8] {
    unsafe {
        // lifetime from raw pointer — caller can get dangling ref
        std::slice::from_raw_parts(ptr, len)
    }
}

// GOOD: documented safety invariants
/// # Safety
/// - `ptr` must be non-null and aligned for `T`
/// - `len` must not exceed the allocated size
unsafe fn read_data(ptr: *const u8, len: usize) -> &[u8] {
    assert!(!ptr.is_null());
    std::slice::from_raw_parts(ptr, len)
}
```

**Checklist for unsafe:**
- Is the `# Safety` doc present and correct?
- Are preconditions actually checked at call sites?
- Can safe code trigger UB through this unsafe function?
- Are `unsafe` blocks small and auditable (not whole functions)?
- `std::mem::transmute` — are source/target types the same size?
- `std::mem::zeroed` — is `T` valid when zeroed? (e.g., `bool`, `NonNull<T>`)

### 2. Integer Overflow / Wraparound
```rust
// BAD: overflow in debug = panic in release = wraparound
let total = a * b;  // debug: panic on overflow; release: wraps

// BAD: checked arithmetic ignored
let (result, overflowed) = a.overflowing_mul(b);
// overflowed is never checked!

// BAD: unsigned wraparound in loop
for i in (0..n).rev() {  // if n == 0, i wraps to usize::MAX!
    arr[i] = ...;  // OOB access
}

// GOOD: explicit overflow handling
let total = a.checked_mul(b).ok_or(Error::Overflow)?;
let total = a.saturating_mul(b);  // saturate at MAX

// Array indexing with unchecked math
let idx = start + offset;  // could overflow
if idx >= arr.len() { return Err("OOB"); }
arr[idx]  // safe after bounds check
```

**Build modes:**
```bash
# Debug mode: panics on overflow (can hide release bugs)
cargo build
# Release mode: wraps on overflow (UB for signed)
cargo build --release
# Always test release mode for integer bugs:
cargo test --release
```

### 3. Panic Safety / Unwrap Risks
```rust
// BAD: unwrap on external input
let n = user_input.parse::<i32>().unwrap();  // panic on invalid input

// BAD: expect with no context
let val = map.get(&key).expect("");  // no context for debugging

// BAD: panic in library code
if !is_valid(data) {
    panic!("invalid data: {}", data);  // library should never panic
}

// BAD: index panic
let third = vec[2];  // panics if len < 3

// GOOD: graceful error handling
let n = user_input.parse::<i32>()
    .map_err(|e| format!("invalid number: {}", e))?;

let third = vec.get(2).ok_or(Error::OutOfBounds)?;
```

**Panic-prone patterns:**
- `unwrap()`, `expect("")` on user-controlled data
- `[]` indexing instead of `.get()`
- `parse().unwrap()` on network/file input
- `[..n]` slicing — panics if `n > len`
- `assert!()` in library code (should be `debug_assert!`)
- `todo!()`, `unreachable!()` left in production code

### 4. Send / Sync Trait Violations
```rust
// BAD: UnsafeCell without Send/Sync guards
struct Shared {
    data: UnsafeCell<Vec<u8>>,
}
// Safe code can share across threads!
unsafe impl Send for Shared {}  // no mutex!

// BAD: Rc in shared state (not thread-safe)
struct AppState {
    cache: Rc<RefCell<HashMap<String, Vec<u8>>>>,
}
// Rc is !Send, so this won't compile across threads
// But with unsafe impl Send — race condition!

// GOOD: use Arc + Mutex/RwLock
struct AppState {
    cache: Arc<RwLock<HashMap<String, Vec<u8>>>>,
}

// Check for:
unsafe impl Send for ...   // why is this unsafe?
unsafe impl Sync for ...   // is interior mutability protected?
```

### 5. Buffer Overflow in FFI
```rust
// BAD: FFI call with user-controlled size
extern "C" {
    fn process_data(ptr: *const u8, len: usize);
}

fn handle_input(input: &[u8]) {
    unsafe {
        // User controls len — if len > input.len(), OOB read in C
        process_data(input.as_ptr(), user_controlled_len);
    }
}

// BAD: CString from user input
let c_str = CString::new(user_input).unwrap();
// If user_input contains interior null bytes, CString::new returns Err
// unwrap() panics before the C function can be called (good)
// But if user_input is huge, CString allocates and copies

// GOOD: validate lengths at FFI boundary
fn handle_input(input: &[u8], user_len: usize) -> Result<()> {
    if user_len > input.len() {
        return Err(Error::InvalidLength);
    }
    unsafe {
        process_data(input.as_ptr(), user_len);
    }
    Ok(())
}
```

### 6. Cryptographic Misuse
```rust
// BAD: non-constant-time comparison
if a == b {  // timing side-channel

// BETTER: constant-time comparison
use subtle::ConstantTimeEq;
if a.ct_eq(&b).into() {

// BAD: static IV/nonce
let nonce = [0u8; 12];  // reused nonce = catastrophic

// BAD: custom crypto implementation
fn my_encrypt(data: &[u8], key: &[u8]) -> Vec<u8> {
    // homemade XOR cipher
    data.iter().zip(key.iter().cycle()).map(|(d, k)| d ^ k).collect()
}

// GOOD: use audited libraries
use aes_gcm::{Aes256Gcm, Nonce};
use aead::{Aead, KeyInit};

// BAD: hardcoded key
const SECRET_KEY: &str = "hunter2";

// BAD: PRNG seeded with timestamp for crypto
use rand::SeedableRng;
let mut rng = rand::rngs::StdRng::seed_from_u64(
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
);
```

### 7. Data Races via Safe Code
```rust
// BAD: interior mutability without Sync protection
use std::cell::Cell;

struct Stats {
    counter: Cell<u64>,  // Cell is Sync but NOT thread-safe
}

// Arc<Cell<u64>> compiles but is a data race!
let stats = Arc::new(Stats { counter: Cell::new(0) });
// Safe code can create a data race through this API

// GOOD: use atomic or mutex
use std::sync::atomic::{AtomicU64, Ordering};
struct Stats {
    counter: AtomicU64,
}
```

**Key types and thread safety:**
| Type | Send | Sync | Notes |
|------|------|------|-------|
| `Cell<T>` | Yes | Yes | NOT thread-safe despite being Sync! |
| `RefCell<T>` | Yes | No | Single-threaded only |
| `Rc<T>` | No | No | Reference-counted, not atomic |
| `Arc<T>` | Yes | Yes (if T: Sync) | Atomic ref-count |
| `Mutex<T>` | Yes | Yes | Thread-safe interior mutability |
| `RwLock<T>` | Yes | Yes | Reader-writer lock |
| `Atomic*` | Yes | Yes | Lock-free atomics |

## Testing Commands

```bash
# Check for unsafe usage
cargo geiger  # cargo-install cargo-geiger
cargo audit   # known vulnerabilities in deps
cargo deny check  # deny policy for deps

# Standard safety checks
cargo test
cargo test --release  # test with release overflow semantics
cargo clippy -- -W clippy::unwrap_used -W clippy::panic

# Miri (experimental UB detection)
cargo miri test  # detects UB in unsafe code

# Fuzz with cargo-fuzz
cargo fuzz init
cargo fuzz add parse_input
cargo fuzz run parse_input -- -runs=100000

# Thread sanitizer
RUSTFLAGS="-Z sanitizer=thread" cargo test -Zbuild-std --target x86_64-unknown-linux-gnu
```

## Pattern: Unsafe Leaking Through Safe API

```rust
// VULNERABLE: safe function returns reference to deallocated memory
pub fn get_config(key: &str) -> Option<&str> {
    let config = load_config();  // local, dropped at end
    config.get(key)  // returns reference to dropped data!
}
// This compiles if config is a static/leaked reference internally

// VULNERABLE: lifetime elision hides unsoundness
pub fn get_data() -> &'static [u8] {
    let data = vec![0u8; 100];
    // Leak the memory — but is this intentional?
    let leaked: &'static mut [u8] = Box::leak(data.into_boxed_slice());
    leaked
}
```

## High-Value Targets in Rust Codebases

1. **Custom parsers with unsafe** — blockchain transaction parsers, network protocols
2. **FFI wrappers** — C library bindings, OS syscalls
3. **Unsafe trait impls** — `Send`/`Sync`, `Index`, `Deref` on wrapper types
4. **Cryptographic implementations** — custom algorithms, nonce management
5. **Network services** — bytes over socket → unsafe conversion
6. **Zero-copy parsing** — `from_raw_parts`, `cast`, `transmute` in parsers
7. **Memory-mapped I/O** — `mmap` + unsafe access patterns

## References
- Trust Wallet Core CBOR bugs: C++ pero mismo patrón aplica a unsafe Rust parsers (sesión 52)
- Block Open Source / Cash App targets incluyen Rust (sesión 39)
- FalkorDB thread pool bugs: mismo patrón en Rust con Arc/Mutex (sesiones 2-8)
