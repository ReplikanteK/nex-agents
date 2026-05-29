---
name: bounty-hunting
description: >-
  Use when analyzing a new bug bounty target's source code. Covers success
  patterns, DNA of bug, target scoring framework, and strategic heuristics
  derived from 82 sessions across HackerOne, Bugcrowd, Intigriti, and
  YesWeHack.
---

# Bounty Hunting Playbook

## DNA de un Bug Exitoso

1. **Input parsing sin validación** — URLs, symlinks, emails, configs
2. **Trust boundary crossing** — User input → system action sin sanitize
3. **Plugin/extension auth bypass** — `checkPluginRequest` missing or incomplete
4. **Auto-actions sin rate limit** — Auto-creation, auto-forwarding
5. **Debug logging leakage** — Configs, keys, tokens en DEBUG level
6. **Missing realpath** — Check on symlink path, not resolved target

## Vectores Prioritarios (ordenados por hit rate)

1. SSRF via dependency URLs / webhooks / plugins
2. Plugin/extension auth bypass (Mattermost pattern)
3. Symlink traversal en file operations
4. Auto-creation abuse sin rate limit
5. Sensitive data logging (DEBUG)
6. Race conditions / thread pool bugs (C/C++)
7. NULL deref / ASSERT failures (C/C++)
8. Integer overflow / wraparound (C/C++)

## Target Scoring Framework

| Criterio | Pts |
|----------|-----|
| Bounty Economics | /25 |
| Code Accessibility | /20 |
| Attack Surface | /20 |
| Likelihood of Success | /20 |
| **Surface Type** | **/15** |
| **TOTAL** | **/100** |

### Surface Type (nuevo)

Penaliza targets que son infraestructura interna, librerías, SDKs, o herramientas de desarrollo — difíciles de explotar desde externo y con impacto limitado.

| Tipo | Pts | Ejemplos |
|------|-----|----------|
| Producto público (web/API/service) | 15 | nextjs-auth0, Discourse, Mattermost |
| SDK/Librería cliente | 8 | Cash App Pay SDK, AfterPay SDK |
| Herramienta interna/infra | 3 | Smokescreen, pghoard, droplet-agent |
| CLI/Dev tool | 5 | Doppler CLI, Turborepo |

**Detectado por:** topics del repo (proxy, infrastructure, sdk, cli, library),
descripción conteniendo keywords (internal, proxy, library, sdk, client),
o tipo de asset en bounty program (URL vs binary/library).

### Exploitability Filter (post-scoring)

Antes de reportar, todo hallazgo debe pasar este filtro. Si no pasa, se archiva:

```
□ ¿El hallazgo requiere acceso interno/red interna para explotar?
  → SÍ = descartar (no demostrable contra asset del programa)
□ ¿Depende de configuración del servidor (allowed URLs, CORS, debug flags)?
  → SÍ = descartar (alto riesgo de rechazo)
□ ¿El PoC funciona contra el asset real del programa (no localhost)?
  → NO = descartar (inconsistencia de código no es suficiente)
□ ¿El hallazgo es un defense-in-depth sin PoC funcional?
  → SÍ = baja prioridad, no reportar
□ ¿El componente ya tiene CVEs conocidos del mismo tipo?
  → SÍ = verificar que no sea duplicado antes de reportar
```

**Regla**: Si no pasan TODAS las preguntas, el hallazgo no se reporta.
Se guarda en `memoria/archivo-hallazgos.md` para referencia futura.

**Decisiones:** ≥70 Atacar, 50-69 Considerar, <50 Descartar

**Reglas de oro:**
- Código cerrado = descarte automático
- >50k líneas = descarte automático
- Sin bounty directo = descarte
- Máx 2 targets activos simultáneos
- Timebox 4h por análisis inicial
- Hallazgos contra herramientas internas/infra = descarte (smokescreen pattern)
- Sin PoC contra asset real del programa = descarte (Auth0/firebase pattern)

## Lecciones Aprendidas (sesiones 50-107)

### Lo que NO funciona
- **Teams de seguridad maduros**: Discourse, Auth0, Trust Wallet ya tienen tooling interno que encuentra bugs antes que nosotros
- **Bugs de inconsistencia de código**: sin impacto demostrable contra el target real, son alto riesgo de rechazo (Auth0 nextjs-auth0)
- **Datos proxy-dependientes**: allOrigins devuelve sus propios headers, no los del target
- **Bugs de config**: "allowed URLs", CORS, etc. dependen del deployment específico
- **Infraestructura interna**: proxies, SDKs, CLIs, librerías — difíciles de explotar desde externo, impacto limitado (Smokescreen pattern, sesión 107)

### Lo que SÍ funciona
- **Proyectos <1 año** o componentes oscuros dentro de proyectos grandes
- **Bugs con PoC funcional** contra el asset real del programa
- **PRs a open source** (FalkorDB) — pagan en reputación si no en bounty
- **Fuzzing C/C++ con ASAN** — crashes estables y demostrables
- **Hallazgos con impacto demostrable**: el bug debe poder dispararse desde el asset público del programa

### Criterios de Reporte (sesión 74)
Un reporte debe tener **impacto demostrable** contra el asset del programa:
1. No basta con inconsistencia de código — hay que demostrar explotación real
2. Bugs que dependen de configuración del servidor son high risk de rechazo
3. Defense-in-depth sin PoC funcional = baja probabilidad de aceptación
4. Mejor calidad sobre cantidad: 1 reporte aceptado > 5 rechazados

## Lenguajes por Hit Rate

1. **Python** — Auth custom, logging, config management
2. **Go** — HTTP services, webhooks, plugins
3. **C/C++** — Memory safety, ASSERTs, thread pools
4. **Ruby** — Dependabot, Rails patterns

## Tips de Revisión

- Buscar `http.Get`, `http.DefaultClient`, `http.Client{}` sin timeout → SSRF
- Buscar `url.Parse()` + `http.Get(url)` sin validación de host → SSRF
- Buscar `startsWith(path)` + `readFile(path)` → symlink traversal
- Buscar `self.log.debug(obj)` / `fmt.Sprintf("%+v", obj)` → info leak
- Buscar `ASSERT()` en C/C++ en paths de error → crash potential
- Buscar auto-creación de recursos (alias, webhooks, tokens) sin rate limit
- Buscar `realpath`/`Readlink` faltante después de validación de path
- Buscar `checkPluginRequest` / `interPluginAuthorizationRequired` → auth bypass
- Buscar `log.Fatalf` en Go en paths de error → DoS por crash

## Targets Ideales

Package managers (pip, cargo), CI/CD runners, email alias services,
backup/encryption tools, database engines con thread pools,
plugins/extensions de plataformas colaborativas.
