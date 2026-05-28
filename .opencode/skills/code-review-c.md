---
name: code-review-c
description: >-
  Use when reviewing C or C++ source code for memory corruption, integer
  issues, thread safety bugs. Includes LLVM sanitizer setup, common
  vulnerability patterns, ASSERT analysis, and thread pool inspection.
---

# C/C++ Code Review for Vulnerabilities

## Vulnerability Classes (prioritized)

### 1. NULL Pointer Dereference
- `ASSERT(ptr)` que se compila en Release (se convierte en no-op)
- Falta de NULL check después de `malloc`/`calloc`/`realloc`
- `if (!ptr) { /* early return */ }` pero se usa `ptr` en otro thread
- `static_cast` o `reinterpret_cast` sin validación

### 2. Double-Free / Use-After-Free
- `free()` sin setear `ptr = NULL`
- Múltiples paths de error que llaman `free()` al mismo ptr
- Objetos compartidos entre threads sin ownership tracking
- `unique_ptr`/`shared_ptr` circulares

### 3. Integer Overflow / Wraparound
- `size_t` arithmetic en allocation size → heap buffer underflow
- Signed integer overflow en loop bounds
- `n * sizeof(T)` sin check de overflow
- Comparaciones entre signed/unsigned
- Shift operations sin rango (≥ width de tipo)

### 4. Race Conditions (Thread Pools)
- Objetos compartidos sin mutex/atomic
- `ASSERT` en data path (solo debug, compilado en Release)
- `atomic` operations sin memory ordering explícito
- Lock-free structures sin verificación formal
- Thread pool tasks que capturan `this` por referencia

### 5. Buffer Overflow
- `memcpy`/`memmove`/`strcpy`/`sprintf` sin bound check
- Array indexing con índice signed sin validación de < 0
- `gets()` / `scanf("%s")` / `read()` en buffers fijos

## LLVM Sanitizer Flags

```bash
# ASAN + UBSan + glog (recommended)
CFLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -g -O1"
LDFLAGS="-fsanitize=address,undefined"

# MSan (requires full instrumented linkage)
CFLAGS="-fsanitize=memory -fno-omit-frame-pointer -g -O2 -fsanitize-memory-track-origins"

# TSAN (for thread pool bugs)
CFLAGS="-fsanitize=thread -g -O1"
```

## ASSERT Analysis Pattern

```c
// BAD: ASSERT solo en debug
ASSERT(ptr != NULL);
ptr->do_something();  // crash en Release

// GOOD: check en ambas configs
if (ptr == NULL) return ERROR_NULL_PTR;
ASSERT(ptr != NULL);
ptr->do_something();
```

**Siempre buscar:** macros de aserción condicionales (solo debug),
especialmente en paths de error y edge cases.

## Thread Pool Inspection

1. ¿Las tasks capturan `this` o punteros sin ownership tracking?
2. ¿Hay objetos mutables compartidos sin locks?
3. ¿Los callbacks se ejecutan en qué thread?
4. ¿Hay `ASSERT` en data paths que se compilan en Release?
5. ¿El cleanup de threads es ordenado vs destructivo?

## File I/O Patterns (CVE-prone)

- `realpath`/`Readlink` faltante en `open()`/`fopen()` → symlink race
- `chdir` + `open` no atómico → TOCTOU
- `stat()` + `open()` con archivos creados por otro usuario → symlink race
- `fscanf`/`fgets` en archivos no confiables
