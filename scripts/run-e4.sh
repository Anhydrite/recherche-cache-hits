#!/usr/bin/env bash
# =============================================================================
# run-e4.sh — E4 : Warmup du 1er appel réel (P1-D)
# =============================================================================
# Hypothèse H-D : un ping warmup (préfixe + max_tokens≈1) avant le 1er appel
# réel augmente le cacheRead du 1er appel.
# MAIS découverte E0 : le system de pi est partagé entre sessions → déjà caché.
# La question devient : le warmup aide-t-il pour le 1er MESSAGE session-spécifique ?
#
# Protocole (N sessions/condition) :
#   A (sans warmup) : 1 tour réel "tâche" → cr mesuré
#   B (avec warmup) : ping warmup (même préfixe + "ping") → puis tour réel → cr
# Métrique : cr du 1er tour réel (et coût total des 2 tours en B).
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
CFG="$ROOT/.pi-test/config"
SESS="$ROOT/.pi-test/sessions"
EXT="$ROOT/.pi-test/extensions/cache-trace.ts"
PROVIDER="${E4_PROVIDER:-opencode-go}"
MODEL="${E4_MODEL:-deepseek-v4-flash}"
N="${E4_N:-5}"
RESULTS="$ROOT/.research/resultats/e4"
mkdir -p "$RESULTS"

export PI_CODING_AGENT_DIR="$CFG"
export PI_CODING_AGENT_SESSION_DIR="$SESS"
export PI_OFFLINE=1 PI_TELEMETRY=0

turn() { # $1=label $2=sid $3=trace $4=prompt
  TRACE_PATH="$3" TRACE_LABEL="$1" timeout 60 pi --extension "$EXT" \
    --print "$4" --session-id "$2" --provider "$PROVIDER" --model "$MODEL" >/dev/null 2>&1
}

analyze_last() { # $1=trace $2=session_id → ext ratio warmup
  node -e '
    const fs=require("fs");
    const f=process.argv[1];
    const lines=fs.readFileSync(f,"utf8").trim().split("\n").filter(Boolean);
    let cur=null, out=[];
    for(const l of lines){ const o=JSON.parse(l);
      if(o.kind==="request") cur=o;
      if(o.kind==="usage"&&cur){ out.push({label:cur.label,cr:o.usage.cacheRead,in:o.usage.input,cw:o.usage.cacheWrite}); cur=null; }
    }
    // les 2 derniers usages = ping + tour réel (B) ou 1 seul (A)
    for(const r of out) console.log(`    ${r.label}: cr=${r.cr} in=${r.in}`);
  ' "$1"
}

echo "=== E4 — Warmup du 1er appel (N=$N sessions/cond, $PROVIDER/$MODEL) ==="

for s in $(seq 1 "$N"); do
  # Randomisation A/B
  if [ $((s % 2)) -eq 1 ]; then ORDER="A B"; else ORDER="B A"; fi
  for cond in $ORDER; do
    SID="e4-$cond-$s-$(date +%s)"
    TR="$RESULTS/$cond-s$s.jsonl"
    rm -f "$TR"
    if [ "$cond" = "B" ]; then
      # ping warmup : même préfixe, max_tokens minimal (~1), pas persisté
      TRACE_PATH="$TR" TRACE_LABEL="ping" timeout 60 pi --extension "$EXT" \
        --print "ping: réponds juste OK" --session-id "$SID" --provider "$PROVIDER" --model "$MODEL" \
        >/dev/null 2>&1
    fi
    # tour réel (tâche)
    turn "reel" "$SID" "$TR" "réponds uniquement: CHÈVRE" 
    echo "-- session $s cond $cond —"
    analyze_last "$TR"
  done
done
echo "===== E4 TERMINÉ ====="