# Doppler CLI + MCP Server Security Review — 2026-08-07

## Target
- **Platform**: HackerOne
- **Asset**: https://github.com/DopplerHQ/cli (In Scope) + https://github.com/DopplerHQ/mcp-server
- **Languages**: Go (CLI), TypeScript (MCP Server)
- **Bounty Range**: $250 - $20,000

---

## Finding 1: Open Redirect via API-Controlled `authUrl` in MCP Server Device Auth Flow

**Severity**: Medium
**CVSS**: 6.1 (AV:N/AC:L/PR:N/UI:R/S:U/C:L/I:L/A:N)
**CWE-601**: Open Redirect

### Description

The Doppler MCP Server's device authentication flow fetches an `authUrl` from the API endpoint `/v3/auth/cli/generate/2` and displays it directly to the user without validation. An attacker who controls the API endpoint (via custom `DOPPLER_BASE_URL` or MITM) can redirect users to a phishing page during the MCP server login process.

### Vulnerable Code

`mcp-server/src/device-auth.ts:47-70`:
```typescript
const url = `${baseUrl}/v3/auth/cli/generate/2?${params.toString()}`;
const response = await fetch(url, { method: "GET", ... });
const data = await response.json();
return {
  code: data.code,
  pollingCode: data.polling_code,
  authUrl: data.auth_url,  // No validation
};
```

`mcp-server/src/index.ts:407-413`:
```typescript
if (browserChoice === 0) {
  try {
    await openBrowser(authState.authUrl);  // Opens attacker-controlled URL
  } catch {}
}
console.error(`\nComplete authorization at ${authState.authUrl}`);
```

### Attack Scenario

1. User is tricked into using a custom API endpoint:
   ```bash
   DOPPLER_BASE_URL=https://attacker-api.example.com npx @dopplerhq/mcp-server login
   ```

2. Attacker's server responds to `GET /v3/auth/cli/generate/2` with:
   ```json
   {
     "code": "ABCDEF123456",
     "polling_code": "POLLXYZ789",
     "auth_url": "https://phishing-site.example.com/doppler-mcp-login"
   }
   ```

3. MCP server displays: "Complete authorization at https://phishing-site.example.com/doppler-mcp-login"

4. If user chooses to open browser, they're redirected to attacker's phishing page.

### Impact
- Credential theft via phishing
- Account compromise if user enters credentials on fake login page

### PoC

```bash
# 1. Start attacker-controlled API server
cat > /tmp/evil-mcp-api.py << 'EOF'
from http.server import HTTPServer, BaseHTTPRequestHandler
import json

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if '/v3/auth/cli/generate' in self.path:
            response = {
                "code": "FAKECODE123",
                "polling_code": "FAKEPOLL456",
                "auth_url": "https://evil.example.com/mcp-phish"
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

# 2. User runs MCP login with attacker's base URL
DOPPLER_BASE_URL=http://localhost:8443 npx @dopplerhq/mcp-server login

# 3. MCP server displays phishing URL to user
```

### Fix Recommendation

Validate that `auth_url` belongs to `*.doppler.com` before displaying or opening:

```typescript
function validateAuthUrl(url: string): boolean {
  try {
    const parsed = new URL(url);
    return parsed.hostname.endsWith('doppler.com');
  } catch {
    return false;
  }
}

const authUrl = data.auth_url;
if (!validateAuthUrl(authUrl)) {
  throw new Error('Invalid authorization URL received from server');
}
```

---

## Finding 2: No Size Limit on API Response Bodies (Go CLI)

**Severity**: Low
**CVSS**: 3.7 (AV:N/AC:H/PR:N/UI:N/S:U/C:N/I:N/A:L)
**CWE-400**: Uncontrolled Resource Consumption

### Description

The Go CLI's HTTP client reads the entire response body into memory without any size limit. A malicious API server (or MITM attacker with `--no-verify-tls`) could return an extremely large response, causing the CLI process to consume all available memory and crash (OOM kill).

### Vulnerable Code

`pkg/http/http.go:330`:
```go
body, err := ioutil.ReadAll(response.Body)
```

### Attack Scenario

1. User runs CLI with a custom API host:
   ```bash
   doppler secrets get --api-host https://attacker-controlled.com --no-verify-tls
   ```

2. Attacker's server responds with a multi-GB JSON response.

3. CLI process consumes all available memory and is OOM-killed.

### Impact
- Denial of service via memory exhaustion
- Potential crash of CI/CD pipelines using the CLI

### Fix Recommendation

Limit response body reads:

```go
const maxResponseBodySize = 10 * 1024 * 1024 // 10MB

body, err := ioutil.ReadAll(io.LimitReader(response.Body, maxResponseBodySize))
if err != nil {
    return response.StatusCode, nil, nil, err
}
```

---

## Finding 3: Weak Fallback File Passphrase Derivation

**Severity**: Low
**CVSS**: 3.3 (AV:L/AC:H/PR:N/UI:R/S:U/C:L/I:N/A:N)
**CWE-330**: Use of Insufficiently Random Values

### Description

The fallback file passphrase is derived deterministically from `token:project:config` (or just `token` if project/config are not set). If any of these values are known (e.g., leaked in logs, environment variables, or process memory), all fallback files encrypted with that passphrase can be decrypted.

### Vulnerable Code

`pkg/cmd/run.go:606-610`:
```go
func getPassphrase(cmd *cobra.Command, flag string, config models.ScopedOptions) string {
    // ...
    if config.EnclaveProject.Value != "" && config.EnclaveConfig.Value != "" {
        return fmt.Sprintf("%s:%s:%s", config.Token.Value, config.EnclaveProject.Value, config.EnclaveConfig.Value)
    }
    return config.Token.Value
}
```

### Impact
- If the auth token is compromised, all fallback files are decryptable
- Fallback files may contain historical secrets

### Fix Recommendation

Use a randomly generated passphrase stored in a secure location (e.g., system keyring) rather than deriving from known values.

---

## Additional Observations

### 4. MCP Server Logs Base URL in Verbose Mode
`mcp-server/src/index.ts:266`: `log('Base URL: ${client.getBaseUrl()}')` — Could leak API endpoint info in shared environments.

### 5. Custom API Host Enables SSRF
Users can set `--api-host` (Go CLI) or `DOPPLER_BASE_URL` (MCP Server) to any URL, allowing the client to make requests to internal networks. This is by design but worth noting.

### 6. Auth Code Copied to Clipboard (Go CLI)
`pkg/cmd/login.go:96`: OAuth auth code is copied to clipboard, readable by other processes with clipboard access.

---

## Summary

| # | Finding | Severity | Exploitability | New? |
|---|---------|----------|----------------|------|
| 1 | MCP Server Open Redirect via authUrl | Medium | Requires custom API endpoint | Yes |
| 2 | No size limit on API responses | Low | Requires MITM or custom API host | Yes |
| 3 | Weak fallback file passphrase | Low | Requires token compromise | Partially |

**Recommended Priority**: Finding 1 is the most reportable as it has a clear exploit path in the MCP server (newer, less reviewed codebase) and is a variant of the already-identified CLI Finding 1.

---

*Report generated: 2026-08-07 by agent3*
