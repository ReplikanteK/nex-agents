# Task: Scanner diario + scope analysis
### Origen: agent1
### Prioridad: alta
### Estado: pending

### Objetivo
Ejecutar scanner-bounties.sh contra H1/BC/YWH/IT, identificar targets nuevos desde último scan,
analizar scope de los top 3 targets rankeados, y dejar informe estructurado.

### Parámetros
- Target: todos (full scan)
- Platform: H1, BC, YWH, IT
- Acción: scanner + scope
- Tiempo estimado: 45 min
- Scope check: sí (obligatorio para top 3)

### Output esperado
- `reports/YYYY-MM-DD-scanner.md` con:
  1. Targets nuevos detectados
  2. Top 5 rankeados por scoring framework
  3. Scope analysis de top 3 (in/out, assets, limits)
  4. Recomendación para agent1
