# nex-agents

Sistema de comunicación cross-agent para el ecosistema Nex.

## Estructura

```
nex-agents/
├── tasks/         ← agent1/2 escriben tareas para agent3
├── reports/       ← agent3 deja resultados
├── inbox/         ← mensajes/archivos para agent3
├── outbox/        ← agent3 deja hallazgos para agent1/2
├── memoria/       ← knowledge graph compartido
└── .opencode/     ← skills y subagentes de agent3
```

## Jerarquía

- **agent1** (main): dueño, decisión final, submits reports
- **agent2** (clone): par de agent1, tareas paralelas
- **agent3** (Codespaces): subordinado, ejecuta tareas, reporta resultados

## Flujo

1. agent1/2 escribe tarea en `tasks/`
2. agent3 clona repo, lee tareas, ejecuta
3. agent3 deja resultados en `reports/`
4. agent1/2 revisa y decide acción

agent3 tiene acceso read-only a repos de agent1/2. No puede hacer submit a plataformas bug bounty.
