---
name: code-review-pygo
description: >-
  Use when reviewing Python or Go source code for security vulnerabilities.
  Covers debug logging leakage, race conditions (Go), template injection,
  and dependency confusion. For SSRF, path traversal, command injection, and
  auth bypass patterns see web-security skill. Based on HackerOne, Bugcrowd,
  and Intigriti research.
---

# Python/Go Code Review for Vulnerabilities

## Vulnerability Classes

### 1. Debug Logging Leakage
- `logging.debug(f"key={secret_key}")` con datos sensibles
- `print()` / `fmt.Sprintf` con secrets en debug mode
- Environment variable dumps en error handlers
- Stack traces con argumentos de función
- Go: `log.Printf` con datos de request

### 2. Race Conditions (Go goroutines)
- Shared mutable state sin mutex/atomic
- `map` escrito desde múltiples goroutines sin `sync.Map`
- `close(ch)` en producer sin verificación de estado
- `select` sin default en canales no bufferizados
- Test race: `go test -race ./...` siempre en data paths

### 3. Authentication / Authorization Bypass
- `@login_required` faltante en views
- Session fixation: login sin regenerar session ID

### 4. Template Injection (SSTI)
- `render_template_string(user_input)` (Jinja2)
- `Template(user_input).render()` sin sandbox
- Go: `html/template` vs `text/template` confusion
- SSTI en motores de templates custom

## Patterns from DNA of Successful Bugs

### Debug logging / info leakage
```python
# BAD
logger.debug(f"User data: {user.to_dict()}")

# GOOD
if not url.startswith(ALLOWED_DOMAINS):
    raise ValueError("domain not allowed")
content = urllib.request.urlopen(url).read()
```

### Trust boundary crossing
```python
# BAD
data = request.json
os.system(f"process_data {data['filename']}")

# GOOD
filename = shlex.quote(data['filename'])
os.system(f"process_data {filename}")
```

### Missing realpath resolution
```python
# BAD
path = os.path.join(BASE_DIR, user_input)
open(path).read()

# GOOD
real = os.path.realpath(os.path.join(BASE_DIR, user_input))
if not real.startswith(os.path.realpath(BASE_DIR)):
    raise ValueError("path traversal detected")
open(real).read()
```

## Go-specific Checks

```go
// BAD: debug log leaks secret
log.Printf("Private key: %s", privateKey)

// BAD: race condition
var counter int
go func() { counter++ }()
go func() { counter-- }()  // data race!

// GOOD: usar atomic o mutex
var counter atomic.Int64
```

For SSRF, command injection, path traversal, and auth bypass patterns, see the **web-security** skill.

## Testing Commands

```bash
# Python: bandit + safety
pip install bandit safety
bandit -r src/ -f json
safety check

# Go: go vet + race detector
go vet ./...
go test -race ./...
```

## References
- Trust Wallet Core CBOR bugs: CWE-125 (C++ pero aplica a cualquier custom parser)
- Firefox Relay DoS: CWE-400 (auto-creation abuse, aplica a Python/Go)
- Discourse Backup Path Traversal: path join sin realpath
- Doppler CLI Token Leak: debug logging leakage
