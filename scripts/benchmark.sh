#!/bin/sh
# Benchmark reprodutível sem UI (§21.1/§25.8). Não instala nem abre o app.
# Uso: scripts/benchmark.sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Colmeia.app"

echo "== engine cold boot + floor switch (socket/git real) =="
"$ROOT/test.sh" --filter PerformanceBudgetTests

echo
echo "== bundle =="
if [ -d "$APP" ]; then
  # Bytes aparentes no disco; inclui app, engine e CLI após build-app.sh.
  BYTES="$(du -sk "$APP" | awk '{print $1 * 1024}')"
  printf 'BENCH bundle_bytes=%s (meta < 62914560)\n' "$BYTES"
else
  echo "BENCH bundle_bytes=SKIPPED (rode scripts/build-app.sh antes; benchmark não cria nem instala o app)"
fi

cat <<'EOF'

Manual, ainda obrigatório em MacBook M4 com o bundle release:
  - clique → canvas interativo (< 2 s);
  - RAM UI com 5 PTYs (< 150 MB) e engine com 5 PTYs (< 50 MB);
  - tecla → eco visível p95 (< 15 ms);
  - 60 fps em pan/zoom com 10 terminais.

Não há harness GUI confiável para esses quatro itens; este script não os simula.
EOF
