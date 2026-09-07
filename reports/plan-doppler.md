# Plan: Quick Scan - Doppler CLI

## Target
- **Name**: Doppler
- **Platform**: hackerone
- **Score**: 66
- **Repo**: https://github.com/DopplerHQ/cli (Go, 391 stars)
- **Scope**: CLI binary, api.doppler.com, dashboard.doppler.com, share.doppler.com, doppler.team

## Attack Surface Analysis

### In-Scope Assets
1. **CLI Repository** (Go) - Primary code review target
2. **api.doppler.com** - REST API endpoints
3. **dashboard.doppler.com** - Web dashboard
4. **share.doppler.com** - Secret sharing feature
5. **doppler.team** - Internal tools (Cloudflare Access protected)

### Key Code Areas Reviewed
| File | Purpose | Risk Level |
|------|---------|------------|
| `pkg/cmd/login.go` | Auth flow, token management | HIGH |
| `pkg/cmd/run.go` | Secret injection, fallback files | HIGH |
| `pkg/http/http.go` | HTTP client, TLS config | MEDIUM |
| `pkg/http/api.go` | API endpoints | MEDIUM |
| `pkg/configuration/config.go` | Config storage, scope handling | HIGH |
| `pkg/controllers/update.go` | Binary updates | HIGH |
| `pkg/controllers/fallback.go` | Fallback file encryption | MEDIUM |
| `pkg/crypto/aes.go` | AES-256-GCM encryption | LOW |
| `pkg/controllers/secrets.go` | Secret management, templates | MEDIUM |

## Vulnerability Hypotheses (Priority Order)

### H1: Scope Confusion in Configuration (HIGH)
**Location**: `pkg/configuration/config.go:73-95`
**Issue**: The `Get()` function uses longest-prefix matching for scopes. Multiple scopes can match a path, and the one with the longest scope path wins.
**Risk**: If scopes aren't properly normalized, a token scoped to `/home/user` could potentially be accessed from `/home/user/evil` if the normalization is flawed.
**Test**: Create config with overlapping scopes, verify isolation.

### H2: Update Script Execution Without Integrity Verification (HIGH)
**Location**: `pkg/controllers/update.go:77-135`
**Issue**: `RunInstallScript()` downloads a shell script via HTTP and executes it. While the install script may have GPG verification internally, the CLI itself doesn't verify the script's integrity before execution.
**Risk**: MITM attack could serve malicious install script if TLS is intercepted.
**Test**: Check if install script URL uses HTTPS, verify GPG verification in script.

### H3: Auth URL Open Redirect (MEDIUM)
**Location**: `pkg/cmd/login.go:69`
**Issue**: `open.Run(authURL)` opens the auth URL from API response without validation.
**Risk**: If API is compromised or DNS is poisoned, attacker could redirect to malicious auth page.
**Test**: Verify if auth URL domain is validated against expected domain.

### H4: Passphrase Derivation Weakness (MEDIUM)
**Location**: `pkg/cmd/run.go:295-310`
**Issue**: Fallback file passphrase defaults to `token:project:config` or just `token`.
**Risk**: If token is leaked, all fallback files for that token can be decrypted.
**Test**: Verify passphrase derivation, check if token alone is sufficient.

### H5: Config File Permission Issues (LOW)
**Location**: `pkg/configuration/config.go:298-305`
**Issue**: Config file is written with 0600 permissions, but fallback files may have different permissions.
**Risk**: Local privilege escalation if fallback files are world-readable.
**Test**: Check fallback file permissions.

## Plan Steps

### Step 1: Quick Recon (5 min)
- [x] Identify repo structure and key files
- [x] Map API endpoints from `pkg/http/api.go`
- [x] Identify auth flow from `pkg/cmd/login.go`
- [x] Check scope definitions from HackerOne

### Step 2: Targeted Code Review (15 min)
- [ ] **H1**: Analyze scope normalization in `configuration/config.go`
  - Read `NormalizeScope()` and `ParsePath()` functions
  - Test scope overlap scenarios
  - Check for path traversal in scope handling
- [ ] **H2**: Analyze update mechanism in `controllers/update.go`
  - Trace install script download URL
  - Verify HTTPS usage
  - Check for integrity verification
- [ ] **H3**: Analyze auth URL handling in `cmd/login.go`
  - Check if domain is validated
  - Test open redirect scenarios

### Step 3: PoC Development (5 min)
- [ ] If vulnerability found, create minimal reproduction
- [ ] Document impact and affected versions
- [ ] Draft report for HackerOne submission

## Success Criteria
- Find 1 confirmed vulnerability with working PoC
- Prioritize auth logic, URL validation, file handling, or API authorization
- Complete within 25 minute timebox

## Notes
- Doppler is SOC 2 Type 2 compliant
- Previous vulnerabilities have been reported and fixed
- The CLI is open source, making code review straightforward
- Focus on logic flaws rather than dependency vulnerabilities
