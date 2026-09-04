#!/usr/bin/env bash
# =============================================================================
# run-t1.sh — Expérience T1 : "rebuild system prompt → invalidations de cache"
# =============================================================================
#
# Protocole (5 sessions indépendantes, N≥3 tours par phase) :
#   P0 warm-up   : 1 tour (écrit le cache)
#   P1 baseline  : 3 tours SANS rebuild → hit attendu (cacheRead > 0)
#   P2 rebuild   : 1 tour AVEC -t read,bash (retire edit/write) → miss attendu
#   P3 restore   : 1 tour AVEC tous les outils → re-hit attendu (TTL vivant)
#   P4 controle  : 1 tour outils IDENTIQUES à P1 → preuve que miss vient du rebuild
#
# Chaque session : --session-id t1-run-<n> identique pour toute la session
# (même clé de cache), extension de trace, sortie dans .pi-test/results/t1/.
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
CFG_DIR="$ROOT/.pi-test/config"
SESS_DIR="$ROOT/.pi-test/sessions"
TRACE_BASE="$ROOT/.pi-test/results/t1"
EXT="$ROOT/.pi-test/extensions/t1-trace.ts"
PROVIDER="${T1_PROVIDER:-opencode-go}"
MODEL="${T1_MODEL:-deepseek-v4-flash}"

export PI_CODING_AGENT_DIR="$CFG_DIR"
export PI_CODING_AGENT_SESSION_DIR="$SESS_DIR"
export PI_OFFLINE=1
export PI_TELEMETRY=0

run_turn() { # $1=label $2=session_id $3=trace_file $4=tools_flag(${4:-""}=tous)
  local label="$1" sid="$2" trace="$3" tools="${4:-}"
  local args=(--print "T1 $label: réponds uniquement OK."
              --session-id "$sid" --provider "$PROVIDER" --model "$MODEL")
  [ -n "$tools" ] && args+=( $tools )
  T1_TRACE_PATH="$trace" timeout 90 pi --extension "$EXT" "${args[@]}" >/dev/null 2>&1
  echo "  [$label] exit=$?"
}

echo "=== T1 — Invalidation par rebuild system prompt ==="
echo "provider=$PROVIDER model=$MODEL sessions=5"
mkdir -p "$TRACE_BASE"

N=${T1_SESSIONS:-5}
for s in $(seq 1 "$N"); do
  SID="t1-run-$s-$(date +%s)"
  TRACE="$TRACE_BASE/run-$s.jsonl"
  rm -f "$TRACE"
  echo "--- Session $s ($SID) ---"
  run_turn "warmup"   "$SID" "$TRACE" ""          # P0 : écrit le cache
  for i in 1 2 3; do
    run_turn "baseline$i" "$SID" "$TRACE" ""      # P1 : hit attendu
  done
  run_turn "rebuild"  "$SID" "$TRACE" "-t read,bash"   # P2 : miss attendu
  run_turn "restore"  "$SID" "$TRACE" ""               # P3 : re-hit attendu
  run_turn "control"  "$SID" "$TRACE" ""               # P4 : même outils que P1
done

echo
echo "=== Résumé (cacheRead/cost par tour) ==="
for s in $(seq 1 "$N"); do
  echo "— Session $s —"
  node -e '
    const fs = require("fs");
    const f = process.argv[1];
    if (!fs.existsSync(f)) { console.log("  (pas de trace)"); process.exit(0); }
    const lines = fs.readFileSync(f,"utf8").trim().split("\n").filter(Boolean);
    let cur = null;
    for (const l of lines) {
      const o = JSON.parse(l);
      if (o.kind==="request") cur = { hash: o.hash.slice(0,10), toolDefs: o.toolDefs };
      if (o.kind==="usage") {
        const u = o.usage;
        console.log(`  req hash=${cur?.hash} tools=${cur?.toolDefs} in=${u.input} cr=${u.cacheRead} cw=${u.cacheWrite} cost=${(u.cost?.total??0).toFixed(6)}`);
      }
    }
  ' "$TRACE_BASE/run-$s.jsonl"
done