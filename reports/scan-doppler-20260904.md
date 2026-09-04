# Quick Scan Report: Doppler

**Date**: 2026-09-04
**Target**: Doppler (doppler.com)
**Platform**: HackerOne
**Score**: 66
**Scan Duration**: 25 minutes
**Analyst**: agent3

---

## Executive Summary

Doppler is a multi-cloud SecretOps Platform for secrets management. The scope includes api.doppler.com, dashboard.doppler.com, share.doppler.com, doppler.team, and the CLI source code at github.com/DopplerHQ/cli.

**Finding**: No confirmed exploitable vulnerability with PoC within the time constraint. The CLI codebase demonstrates strong security practices. The web application has some low-severity findings that may warrant further investigation.

---

## Attack Surface

### In-Scope Assets
- `api.doppler.com` - REST API
- `dashboard.doppler.com` - Web dashboard
- `share.doppler.com` - Secret sharing service
- `doppler.team` - Team domain
- `github.com/DopplerHQ/cli` - CLI source code (Go)

### Technology Stack
- **CLI**: Go, Cobra CLI framework
- **API**: REST, Bearer token auth
- **Infrastructure**: Cloudflare WAF, GCP (us-central1)
- **Kubernetes Operator**: Go, controller-runtime

---

## Code Review Findings

### 1. CLI Security Posture (GOOD)

**Token Storage**: Tokens stored in system keyring when available, with encrypted fallback to `~/.doppler/.doppler.yaml`. Config file created with `0600` permissions.

**Fallback Files**: Encrypted using AES with configurable passphrase. Default passphrase derived from `token:project:config`.

**Dangerous Secret Names**: CLI warns when secrets have names that could lead to environment variable injection (e.g., `LD_PRELOAD`, `PYTHONWARNINGS`).

**Location**: `pkg/configuration/keyring.go:40-85`, `pkg/controllers/secrets.go:42-66`

### 2. API Host Configuration (INFORMATIONAL)

The `--api-host` flag and `DOPPLER_API_HOST` environment variable allow specifying an arbitrary API host. While this is a client-side tool, an attacker who can control these values could redirect tokens to a malicious server.

**Impact**: Requires local access or social engineering to exploit. Not a server-side vulnerability.

**Location**: `pkg/http/http.go:54-71` (`generateURL` function)

### 3. Kubernetes Operator RBAC (INFORMATIONAL)

The operator has permissions to create/update/delete secrets and list/watch deployments. Cross-namespace secret references are restricted unless the DopplerSecret is in the operator's namespace.

**Location**: `controllers/dopplersecret_controller.go:80-104`

---

## Web Application Observations

### Missing Security Headers

Based on external analysis, doppler.com appears to be missing:
- Content-Security-Policy
- X-Frame-Options
- X-Content-Type-Options
- Referrer-Policy

These are defense-in-depth measures and may not be directly exploitable.

### Previous Vulnerabilities (Disclosed)

1. **DOM XSS in share.doppler.com** (Report #2921905): WAF bypass + jQuery escapeSelector Unicode handling issue. Disclosed 2025-01-13.

2. **Broken Link Takeover** (Report #2418210): Acquisition-related broken link. Low severity.

3. **Business Logic Errors** (Report on project name vulnerabilities): Availability impact. Low severity.

---

## Recommendations for Further Investigation

1. **API Authorization Model**: Investigate IDOR potential in API endpoints (requires valid token to test).

2. **Share.doppler.com**: The previous DOM XSS suggests this endpoint may have additional client-side vulnerabilities. Look for similar Unicode handling issues.

3. **OIDC Flow**: The `doppler oidc login` command accepts an OIDC JWT token - investigate if token validation can be bypassed.

4. **Template Injection**: The `doppler secrets substitute` command renders Go templates with secret values - investigate Server-Side Template Injection (SSTI) potential.

---

## Conclusion

The Doppler CLI demonstrates strong security practices with proper token storage, encrypted fallback files, and input validation. No confirmed exploitable vulnerability was found within the 25-minute scan window. The most promising areas for further investigation are the share.doppler.com endpoint and the API authorization model.

**Verdict**: No actionable finding to report to HackerOne at this time.
