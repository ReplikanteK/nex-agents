#!/usr/bin/env bash
set -uo pipefail

# === Agent3 Default Daily Scanner ===
# Se ejecuta cuando no hay tareas pendientes
# Escanea plataformas bug bounty y deja informe

echo "[nex3] Running daily scanner..."
export PATH="$HOME/.opencode/bin:$PATH"
DATE=$(date +%Y-%m-%d)
REPORT="$HOME/nex-agents/reports/scanner-${DATE}.md"

cat > "$REPORT" << EOF
# Scanner Report - ${DATE}

## Status
- Platform scan: pending
- New targets: pending
- Top recommendations: pending

## Notas
Reporte generado automaticamente por agent3.
Completar con opencode: \`opencode --config \$HOME/opencode-agent3/opencode.json\`
EOF

# Push report structure
cd "$HOME/nex-agents" || exit 1
git add reports/ && git commit -m "agent3: daily scanner report structure ${DATE}" && git push 2>/dev/null || true

echo "[nex3] Report structure created: reports/scanner-${DATE}.md"
echo "[nex3] Run opencode to complete the analysis."
