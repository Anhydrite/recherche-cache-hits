#!/usr/bin/env bash
# =============================================================================
# run-e3.sh — E3 : TTL long vs court (PI_CACHE_RETENTION)
# =============================================================================
# Mesure le cacheRead après des pauses croissantes, pour une session donnée,
# en mode SHORT (défaut) puis LONG (PI_CACHE_RETENTION=long).
# Protocole par mode :
#   warmup (tour 1) → baseline (tour 2, hit chaud) → pause D → reprise (tour 3)
# D ∈ {60s, 180s, 300s, 420s, 600s} — le TTL court Anthropic ≈ 5 min => miss
# attendu au-delà ; le TTL long (1h) devrait conserver le hit.
#
# Usage : ./run-e3.sh [durees_csv]   (défaut: 60,180,300,420,600)
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
CFG="$ROOT/.pi-test/config"
SESS="$ROOT/.pi-test/sessions"
EXT="$ROOT/.pi-test/extensions/cache-trace.ts"
PROVIDER="${E3_PROVIDER:-opencode-go}"
MODEL="${E3_MODEL:-deepseek-v4-flash}"
DURATIONS="${1:-60,180,300,420,600}"
RESULTS="$ROOT/.research/resultats/e3"
mkdir -p "$RESULTS"

export PI_CODING_AGENT_DIR="$CFG"
export PI_CODING_AGENT_SESSION_DIR="$SESS"
export PI_OFFLINE=1 PI_TELEMETRY=0

turn() { # $1=label $2=sid $3=trace $4=retention(short|long)
  local label="$1" sid="$2" trace="$3" ret="$4"
  local env_ret=()
  [ "$ret" = "long" ] && env_ret+=(PI_CACHE_RETENTION=long)
  TRACE_PATH="$trace" TRACE_LABEL="$label" "${env_ret[@]}" \
    timeout 60 pi --extension "$EXT" --print "$label: réponds uniquement OK." \
    --session-id "$sid" --provider "$PROVIDER" --model "$MODEL" >/dev/null 2>&1
}

analyze() { # $1=trace → dernier usage
  node -e '
    const fs=require("fs");
    const f=process.argv[1];
    if(!fs.existsSync(f)){ console.log("(pas de trace)"); process.exit(0); }
    const lines=fs.readFileSync(f,"utf8").trim().split("\n").filter(Boolean);
    let cur=null,last=null;
    for(const l of lines){
      const o=JSON.parse(l);
      if(o.kind==="request") cur=o;
      if(o.kind==="usage"&&cur){ last={cr:o.usage.cacheRead,in:o.usage.input,cw:o.usage.cacheWrite,cost:(o.usage.cost?.total??0),label:cur.label}; cur=null; }
    }
    console.log(last?`  [${last.label}] cr=${last.cr} in=${last.in} cost=${last.cost.toFixed(5)}`:"  (aucun usage)");
  ' "$1"
}

for RET in short long; do
  echo "===== MODE $RET ====="
  SID="e3-$RET-$(date +%s)"
  TR="$RESULTS/$RET.jsonl"
  rm -f "$TR"
  turn warmup "$SID" "$TR" "$RET"
  turn baseline "$SID" "$TR" "$RET"
  echo "-- baseline (chaud):"; analyze "$TR"
  for D in ${DURATIONS//,/ }; do
    echo "-- pause ${D}s puis reprise..."
    sleep "$D"
    turn "after_${D}s" "$SID" "$TR" "$RET"
    analyze "$TR"
  done
done
echo; echo "===== E3 TERMINÉ ====="