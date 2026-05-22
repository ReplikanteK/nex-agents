#!/usr/bin/env bash
set -uo pipefail

# === Agent3 Daily Entrypoint ===
# Se ejecuta automáticamente al arrancar el Codespace
# 1. Lee tareas de nex-agents/tasks/
# 2. Ejecuta la tarea prioritaria
# 3. Deja resultados en reports/
# 4. Pushea resultados a GitHub

echo "[nex3] $(date) - Agent3 daily run starting..."
export PATH="$HOME/.opencode/bin:$PATH"

cd "$HOME/nex-agents" || { echo "[nex3] ERROR: nex-agents no encontrado"; exit 1; }

# Pull latest tasks from GitHub
git pull origin main 2>/dev/null || true

# Find pending tasks sorted by priority
PENDING=$(find tasks/ -maxdepth 1 -name "*.md" -newer tasks/template.md 2>/dev/null | head -1)

if [ -z "$PENDING" ]; then
  echo "[nex3] No pending tasks. Running default scanner..."
  # Default action: scanner diario si no hay tareas
  bash "$HOME/nex-agents/setup/daily-scanner.sh" 2>/dev/null || true
else
  TASK_NAME=$(basename "$PENDING" .md)
  echo "[nex3] Processing task: $TASK_NAME"
  
  # Mark task as in_progress
  sed -i 's/Estado: pending/Estado: in_progress/' "$PENDING"
  
  # Launch opencode with the task context
  echo "[nex3] Launching opencode for task: $TASK_NAME"
  opencode --config "$HOME/opencode-agent3/opencode.json" -p "Ejecuta la tarea descrita en $PENDING. Deja el resultado en reports/${TASK_NAME}-result.md"
  
  # Mark task as completed
  sed -i 's/Estado: in_progress/Estado: completed/' "$PENDING"
  
  # Push results
  git add tasks/ reports/ && git commit -m "agent3: $TASK_NAME completado" && git push 2>/dev/null || true
fi

echo "[nex3] $(date) - Agent3 daily run finished."
