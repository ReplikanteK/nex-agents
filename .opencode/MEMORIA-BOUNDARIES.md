# agent3 Memory Boundaries

## Principio Fundamental
agent3 es un **subordinado de agent1**. Su trabajo es recolectar datos, filtrar targets, y generar reportes estructurados. **NO modifica la memoria principal de agent1.**

## Reglas Estrictas

### ESCRITURA PERMITIDA
- `reports/*.md` — reportes de scan, code review, scout triage
- `memoria/targets-ranked.json` — ranking de targets procesados
- `memoria/agent3-latest.json` — resumen del último run
- `setup/*` — scripts de infraestructura

### ESCRITURA PROHIBIDA
- `memoria/000-identidad.md`
- `memoria/001-estado.md`
- `memoria/002-activo.md`
- `memoria/archivo-sesiones.md`
- `memoria/memoria-index.md`
- `reports/` NO referencias a memoria agent1

### LECTURA PERMITIDA
- Puede leer cualquier archivo en `memoria/` para entender contexto
- Puede leer `reports/` históricos para no duplicar trabajo
- Puede leer `targets-state.json` para saber qué ya se analizó

## Ciclo de Vida
1. agent3 scrapea + filtra + rankea → `targets-ranked.json`
2. Si hay target ≥70: `scout subagent` triage → `reports/scout-{target}.md`
3. Si scout dice go: `opencode run` con skills → `reports/codereview-{target}.md`
4. agent1 consulta reportes y decide si reportar

## Prohibiciones
- NO ejecutar `git push` en repos que no sean `nex-agents`
- NO leer/ejecutar scripts fuera del workspace del codespace
- NO modificar config de opencode del host
- NO enviar reportes a plataformas de bug bounty (eso es de agent1)
