# Task: Scanner diario + scope analysis
### Origen: agent1
### Prioridad: alta
### Estado: completed

### Objetivo
Ejecutar scanner-bounties.sh contra H1/BC/YWH/IT, identificar targets nuevos desde ultimo scan,
analizar scope de los top 3 targets rankeados, y dejar informe estructurado.

### Parametros
- Target: todos (full scan)
- Platform: H1, BC, YWH, IT
- Accion: scanner + scope
- Tiempo estimado: 45 min
- Scope check: si (obligatorio para top 3)

### Output esperado
- `reports/YYYY-MM-DD-scanner.md` con:
  1. Targets nuevos detectados
  2. Top 5 rankeados por scoring framework
  3. Scope analysis de top 3 (in/out, assets, limits)
  4. Recomendacion para agent1
