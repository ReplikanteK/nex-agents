# agent3 Memory Boundaries

## Principio Fundamental
agent3 es un **subordinado de agent1**. Su trabajo es recolectar datos, filtrar targets, y generar reportes estructurados. **NO modifica la memoria principal de agent1.**

## Sistema de Memoria (v8.0)
- **Source of truth**: SQLite FTS5 (`~/.local/share/opencode-agent/memory.db`)
- **KG complemento**: `~/.local/share/opencode-agent/memory.jsonl`
- **Export**: `~/opencode-agent/memoria/memory-*.md` (generados, no editar)
- **Script**: `~/opencode-agent/scripts/nex-memory.py`

## Reglas Estrictas

### ESCRITURA PERMITIDA
- `reports/*.md` — reportes de scan, code review, scout triage
- `memoria/targets-ranked.json` — ranking de targets procesados
- `memoria/agent3-latest.json` — resumen del último run
- `setup/*` — scripts de infraestructura

### ESCRITURA PROHIBIDA
- `~/.local/share/opencode-agent/memory.db` (memoria principal de agent1)
- `~/.local/share/opencode-agent/memory.jsonl` (KG de agent1)
- `~/opencode-agent/memoria/memory-*.md` (exports de agent1)
- `~/opencode-agent/scripts/nex-memory.py` (script de agent1)
- `reports/` NO referencias a memoria agent1

### LECTURA PERMITIDA
- Puede leer `memoria/` local para entender contexto
- Puede leer `reports/` históricos para no duplicar trabajo
- Puede leer `targets-state.json` para saber qué ya se analizó
- Puede ejecutar `nex-memory.py stats` para ver estado (read-only)

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
- NO modificar la memoria SQLite de agent1
