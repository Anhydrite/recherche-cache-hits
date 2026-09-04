#!/usr/bin/env bash
# =============================================================================
# run-h2.sh — Expérience H2 : boucle d'outils intra-tour et hit de cache
# =============================================================================
# Question : quand pi fait plusieurs tool_use dans un même tour (boucle),
# chaque appel assistant/tool suivant matche-t-il le préfixe (cache hit) ?
# Le 3e breakpoint est sur le dernier user (avec tool results) → si la bouscule
# le fait bouger, le 2e/3e appel intra-tour re-billent la conversation.
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
RESULTS="$ROOT/.pi-test/results/h2"
mkdir -p "$RESULTS"
SID="h2-$(date +%s)"
TR="$RESULTS/trace.jsonl"

run() { # $1=label $2=trace $3=prompt_suffix
  ./scripts/exp-runner.sh "$1" "$SID" "" "$TR" --print "Fais ${3:-2} choses en séquence : (1) lis le fichier README-cache-hit-harnesses.md (head -30 via read), (2) puis lis le fichier 03-conclusions-hypotheses-optimisation.md (head -30 via read). Réponds juste OK."
}

echo "=== H2 — Boucle d'outils intra-tour ==="
echo "Session $SID — chaque tour demande 2 tool calls (read) consécutifs"
# warmup (1 tour)
run warmup "$TR"
# tours avec boucle de 2 tool calls
for i in 1 2 3; do run "loop$i" "$TR"; done

echo "--- Résultats H2 (chaque REQ = un appel LLM, y compris intra-tour) ---"
node -e '
  const fs = require("fs");
  const f = process.argv[1];
  const lines = fs.readFileSync(f,"utf8").trim().split("\n").filter(Boolean);
  let cur = null, out = [];
  for (const l of lines) {
    const o = JSON.parse(l);
    if (o.kind === "request") cur = { ...o };
    if (o.kind === "usage" && cur) {
      const u = o.usage;
      out.push({ sysHash: cur.systemHash?.slice(0,10), tools: (cur.toolNames||[]).join(","),
        msgs: cur.messages, in: u.input, cr: u.cacheRead, cw: u.cacheWrite,
        cost: (u.cost?.total??0).toFixed(6) });
      cur = null;
    }
  }
  out.forEach((r,i) => console.log(`  REQ#${i+1} sys=${r.sysHash} tools=[${r.tools}] msgs=${r.msgs} in=${String(r.in).padEnd(6)} cr=${String(r.cr).padEnd(6)} cost=${r.cost}`));
' "$TR"