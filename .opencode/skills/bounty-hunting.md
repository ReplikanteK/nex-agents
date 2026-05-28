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
| Code Accessibility | /25 |
| Attack Surface | /25 |
| Likelihood of Success | /25 |
| **TOTAL** | **/100** |

**Decisiones:** ≥70 Atacar, 50-69 Considerar, <50 Descartar

**Reglas de oro:**
- Código cerrado = descarte automático
- >50k líneas = descarte automático
- Sin bounty directo = descarte
- Máx 2 targets activos simultáneos
- Timebox 4h por análisis inicial

## Lecciones Aprendidas (sesiones 50-82)

### Lo que NO funciona
- **Teams de seguridad maduros**: Discourse, Auth0, Trust Wallet ya tienen tooling interno que encuentra bugs antes que nosotros
- **Bugs de inconsistencia de código**: sin impacto demostrable contra el target real, son alto riesgo de rechazo
- **Datos proxy-dependientes**: allOrigins devuelve sus propios headers, no los del target
- **Bugs de config**: "allowed URLs", CORS, etc. dependen del deployment específico

### Lo que SÍ funciona
- **Proyectos <1 año** o componentes oscuros dentro de proyectos grandes
- **Bugs con PoC funcional** contra el asset real del programa
- **PRs a open source** (FalkorDB) — pagan en reputación si no en bounty
- **Fuzzing C/C++ con ASAN** — crashes estables y demostrables

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
