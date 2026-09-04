#!/usr/bin/env bash
# =============================================================================
# run-campaign.sh — Campagne complète d'expériences cache (T1-refined, T3, T6)
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
RESULTS="$ROOT/.pi-test/results"

run() { # $1=label $2=sid $3=tools $4=trace $5+=args
  local label="$1" sid="$2" tools="$3" trace="$4"; shift 4
  ./scripts/exp-runner.sh "$label" "$sid" "$tools" "$trace" "$@" >/dev/null 2>&1
}

analyze() { # $1 = trace
  node -e '
    const fs = require("fs");
    const f = process.argv[1];
    if (!fs.existsSync(f)) { console.log("  (pas de trace)"); process.exit(0); }
    const lines = fs.readFileSync(f,"utf8").trim().split("\n").filter(Boolean);
    let cur = null;
    const out = [];
    for (const l of lines) {
      const o = JSON.parse(l);
      if (o.kind === "request") cur = { ...o };
      if (o.kind === "usage" && cur) {
        const u = o.usage;
        out.push({ label: cur.label, sysHash: cur.systemHash?.slice(0,10), sysBytes: cur.systemBytes,
          tools: (cur.toolNames||[]).join(","), in: u.input, cr: u.cacheRead, cw: u.cacheWrite,
          cost: (u.cost?.total ?? 0).toFixed(6) });
        cur = null;
      }
    }
    for (const r of out) {
      console.log(`  ${(r.label||"?").padEnd(16)} sys=${(r.sysHash||"-").slice(0,8)} sysB=${String(r.sysBytes).padEnd(6)} tools=[${r.tools}] in=${String(r.in).padEnd(6)} cr=${String(r.cr).padEnd(6)} cost=${r.cost}`);
    }
  ' "$1"
}

# =============================================================================
echo "========== EXPERIENCE T1-REFINED : rebuild au MILIEU des tools =========="
T="$RESULTS/t1ref"; mkdir -p "$T"; SID="t1ref-$(date +%s)"; TR="$T/trace.jsonl"; rm -f "$TR"
echo "--- Session $SID ---"
run warmup "$SID" "" "$TR"
for i in 1 2 3; do run "base_2t_$i" "$SID" "-t read,bash" "$TR"; done
run mid_change "$SID" "-t read,edit" "$TR"
run restore "$SID" "-t read,bash" "$TR"
run control "$SID" "-t read,bash" "$TR"
echo "--- Résultats T1-refined ---"; analyze "$TR"

# =============================================================================
echo; echo "========== EXPERIENCE T3 : cwd / AGENTS.md hors préfixe =========="
T="$RESULTS/t3"; mkdir -p "$T"; SID="t3-$(date +%s)"; TR="$T/trace.jsonl"; rm -f "$TR"
echo "--- Session $SID (AGENTS.md ABSENT du repo → test sur cwd) ---"
run warmup "$SID" "" "$TR"
for i in 1 2; do run "base_ctx$i" "$SID" "" "$TR"; done
# T3.1 : cwd CHANGE entre les tours (créer un 2e repo test et y lancer pi)
REPO_A="$ROOT/.pi-test/work/repoA"; REPO_B="$ROOT/.pi-test/work/repoB"
mkdir -p "$REPO_A" "$REPO_B"
# Tour dans repo A
(cd "$REPO_A" && PI_CODING_AGENT_DIR="$ROOT/.pi-test/config" PI_CODING_AGENT_SESSION_DIR="$ROOT/.pi-test/sessions" \
  PI_OFFLINE=1 PI_TELEMETRY=0 TRACE_PATH="$TR" timeout 90 pi --extension "$ROOT/.pi-test/extensions/cache-trace.ts" \
  --print "repoA1: réponds OK" --session-id "$SID" --provider opencode-go --model deepseek-v4-flash >/dev/null 2>&1)
# Tour dans repo B (cwd différent → miss attendu si cwd dans le prefère)
(cd "$REPO_B" && PI_CODING_AGENT_DIR="$ROOT/.pi-test/config" PI_CODING_AGENT_SESSION_DIR="$ROOT/.pi-test/sessions" \
  PI_OFFLINE=1 PI_TELEMETRY=0 TRACE_PATH="$TR" timeout 90 pi --extension "$ROOT/.pi-test/extensions/cache-trace.ts" \
  --print "repoB1: réponds OK" --session-id "$SID" --provider opencode-go --model deepseek-v4-flash >/dev/null 2>&1)
# Retour repo A (doit re-hit si le cwd n'était pas dans le prefère stable)
(cd "$REPO_A" && PI_CODING_AGENT_DIR="$ROOT/.pi-test/config" PI_CODING_AGENT_SESSION_DIR="$ROOT/.pi-test/sessions" \
  PI_OFFLINE=1 PI_TELEMETRY=0 TRACE_PATH="$TR" timeout 90 pi --extension "$ROOT/.pi-test/extensions/cache-trace.ts" \
  --print "repoA2: réponds OK" --session-id "$SID" --provider opencode-go --model deepseek-v4-flash >/dev/null 2>&1)
echo "--- Résultats T3 (cwd change) ---"; analyze "$TR"

# =============================================================================
echo; echo "========== EXPERIENCE T6 : resume bit-identique =========="
T="$RESULTS/t6"; mkdir -p "$T"; SID="t6-$(date +%s)"
TR1="$T/trace-part1.jsonl"; rm -f "$TR1" "$T/trace-resume.jsonl"
for i in 1 2 3 4; do run "tour$i" "$SID" "" "$TR1"; done
echo "--- Partie 1 (session initiale) ---"; analyze "$TR1"
TR2="$T/trace-resume.jsonl"
run resume_tour1 "$SID" "" "$TR2"
run resume_tour2 "$SID" "" "$TR2"
echo "--- Partie 2 (resume, même session-id) ---"; analyze "$TR2"

echo; echo "===== FIN CAMPAGNE ====="
