#!/usr/bin/env bash
# =============================================================================
# run-h3-cross-provider.sh — Validation croisée H3 par provider
# =============================================================================
# Exécute le protocole H3 anti-biais sur PLUSIEURS providers et compare.
#   - Campagne 1 : commandcode  (déjà exécutée → résultats h3bias-commandcode)
#   - Campagne 2 : opencode-go  (à exécuter quand le quota le permet)
# Usage : ./run-h3-cross-provider.sh [sessions] [provider [model]]
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
N="${1:-3}"
PROVIDER="${2:-opencode-go}"
MODEL="${3:-deepseek-v4-flash}"

echo "=== Validation croisée H3 : provider $PROVIDER/$MODEL, N=$N sessions/scénario/cond ==="
echo "(La campagne commandcode est déjà faite — on compare les dossiers résultats)"

# Exécuter la campagne pour ce provider
H3_PROVIDER="$PROVIDER" H3_MODEL="$MODEL" N="$N" ./scripts/run-h3-bias.sh

echo
echo "=================== COMPARAISON CROISÉE DES VERDICTS ==================="
echo "Providers comparés : commandcode (campagne 1) vs $PROVIDER (campagne 2)"
echo

# Agrégateur : pour chaque dossier h3bias-*, sortir le résumé par scénario
compare() {
  node << 'NODEEOF'
const fs = require("fs"), path = require("path");
const root = process.env.ROOT || ".";
const dirs = fs.readdirSync(path.join(root, ".pi-test/results"))
  .filter(d => d.startsWith("h3bias-"));
console.log("Dossiers résultats trouvés : " + dirs.join(", "));
for (const dir of dirs) {
  const full = path.join(root, ".pi-test/results", dir);
  const prov = dir.replace("h3bias-", "");
  console.log(`\n=== PROVIDER ${prov} ===`);
  for (const scen of ["s1","s2","s5","s8"]) {
    for (const cond of ["A","B"]) {
      const files = fs.readdirSync(full).filter(f => f.startsWith(scen+"-cond"+cond) && f.endsWith(".jsonl"));
      let totCr=0, totIn=0, totCost=0, n=0, cdCosts=[], sysBs=new Set();
      for (const f of files) {
        const lines = fs.readFileSync(path.join(full,f),"utf8").trim().split("\n").filter(Boolean);
        let cur=null;
        for (const l of lines) {
          const o=JSON.parse(l);
          if(o.kind==="request") cur=o;
          if(o.kind==="usage"&&cur){
            const u=o.usage;
            totCr+=u.cacheRead; totIn+=u.input; totCost+=(u.cost?.total??0); n++;
            if(cur.label && cur.label.startsWith("cd_")) cdCosts.push(u.cost?.total??0);
            if(cur.systemBytes) sysBs.add(cur.systemBytes);
            cur=null;
          }
        }
      }
      const hr = (totCr+totIn)>0 ? (totCr/(totCr+totIn)*100).toFixed(1) : "0";
      const cdMed = cdCosts.length ? cdCosts.sort((a,b)=>a-b)[Math.floor(cdCosts.length/2)] : null;
      console.log(`  ${scen}${cond}: hit=${hr}% cr=${totCr} in=${totIn} cost=$${totCost.toFixed(4)} tours=${n} cdCostMedian=${cdMed?cdMed.toFixed(5):"n/a"} sysBytes=[${[...sysBs].join(",")}]`);
    }
  }
}
NODEEOF
}
ROOT="$ROOT" compare
echo
echo "=== INTERPRÉTATION ==="
echo "1. Si hit_rate/cdCost sont comparables entre providers → H3 réfutée de façon robuste (pas un artefact provider)."
echo "2. Si un provider montre un écart A/B et l'autre non → le résultat dépend du provider (à documenter)."
echo "3. sysBytes identiques entre A et B = condition B a bien stabilisé le system des 2 côtés."
echo
echo "===== FIN COMPARAISON CROISÉE ====="