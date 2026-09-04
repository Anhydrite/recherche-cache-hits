#!/usr/bin/env bash
# =============================================================================
# run-h3-bias.sh — Protocole anti-biais H3 : cwd hors system prompt
# =============================================================================
# Compare condition A (baseline : cwd dans system) vs B (cwd dans 1er message)
# sur des SCÉNARIOS D'USAGE RÉELS (tâches, pas "réponds OK"), avec :
#   - randomisation A/B de l'ordre des sessions
#   - sessions séparées par condition (jamais le même session-id)
#   - warmup identique
#   - événement clé : changement de cwd (repo A → B → A)
#
# Usage : ./run-h3-bias.sh [sessions_per_scenario] [--dry-run]
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
EXP_PROVIDER="${H3_PROVIDER:-opencode-go}"
EXP_MODEL="${H3_MODEL:-deepseek-v4-flash}"
# Dossier de résultats distinct par provider (comparaison croisée possible)
EXP_TAG="${H3_TAG:-$(echo "$EXP_PROVIDER" | tr "/" "-")}"
RESULTS="$ROOT/.pi-test/results/h3bias-$EXP_TAG"
echo "Provider=$EXP_PROVIDER/$EXP_MODEL — résultats dans $RESULTS"
N="${1:-3}"                 # sessions par scénario×condition (défaut 3, cible ≥5)
mkdir -p "$RESULTS"
# Repos de test (deux cwd distincts pour provoquer le changement)
REPO_A="$ROOT/.pi-test/work/repoA"
REPO_B="$ROOT/.pi-test/work/repoB"
mkdir -p "$REPO_A" "$REPO_B"
# Un AGENTS.md dans le repo A (scénario S5)
[ -f "$REPO_A/AGENTS.md" ] || echo "# Rules du repoA de test" > "$REPO_A/AGENTS.md"

COND_A_EXT=""
COND_B_EXT="$ROOT/.pi-test/extensions/h3-condition-b.ts"
TRACE_EXT="$ROOT/.pi-test/extensions/cache-trace.ts"

# -------------------- Tâches réalistes --------------------
# S1 : lecture de 3 fichiers du repo
TASK_S1="Liste les 3 fichiers .md les plus importants de ce repo (lis-les en entier avec read) puis résume en 3 lignes ce que fait le projet."
# S2 : moyenne édition — lire 2 fichiers + éditer + vérifier
TASK_S2="Lis 02-comprehension-etat-de-l-art.md et 03-conclusions-hypotheses-optimisation.md (avec read), puis ajoute une ligne '<!-- lu par test h3 -->' en fin du fichier 04-cas-de-tests-et-predictions.md, puis relis la fin du fichier pour confirmer."
# S5 : avec contexte projet (AGENTS.md)
TASK_S5="Tu es dans un repo avec un AGENTS.md. Lis le AGENTS.md, puis le fichier README-cache-hit-harnesses.md, et réponds en 2 lignes quelles sont les 3 stratégies de cache les plus citées."
# S8 : multi-repo (le changement de cwd EST l'événement)
TASK_S8="Lis le fichier test.txt de ce repo (crée-le avec write si absent) et réponds son contenu."

# -------------------- Utilitaires --------------------
run_turn() { # $1=label $2=sid $3=trace $4=repo $5=condition(A/B) $6+=args
  local label="$1" sid="$2" trace="$3" repo="$4" cond="$5"; shift 5
  # ORDRE IMPORTANT : la condition B (qui modifie le system) doit être chargée AVANT
  # le traceur (qui logge le payload) pour que la trace reflète le payload modifié.
  local ext_args=()
  if [ "$cond" = "B" ]; then ext_args+=(--extension "$COND_B_EXT"); fi
  ext_args+=(--extension "$TRACE_EXT")
  (cd "$repo" && PI_CODING_AGENT_DIR="$ROOT/.pi-test/config" \
    PI_CODING_AGENT_SESSION_DIR="$ROOT/.pi-test/sessions" PI_OFFLINE=1 PI_TELEMETRY=0 \
    TRACE_PATH="$trace" TRACE_LABEL="$label" timeout 120 pi "${ext_args[@]}" --print "$label: $*" \
    --session-id "$sid" --provider "$EXP_PROVIDER" --model "$EXP_MODEL" >/dev/null 2>&1)
  echo "  [$label cond=$cond] exit=$?"
}

scenario() { # $1=name $2=task $3=repo $4=num_tours $5=AGENTS?(0/1)
  local name="$1" task="$2" repo="$3" turns="$4"
  echo "=== Scénario $name (repo=$repo, $turns tours) ==="
  # Randomisation : chaque session alterne l'ordre des conditions
  for s in $(seq 1 "$N"); do
    # Ordre randomisé A-B / B-A (seed = s)
    if [ $((s % 2)) -eq 1 ]; then ORDER="A B"; else ORDER="B A"; fi
    for cond in $ORDER; do
      local sid="$name-c$cond-s$s-$(date +%s)"
      local tr="$RESULTS/$name-cond$cond-s$s.jsonl"
      rm -f "$tr"
      # warmup (même tâche, 1 tour)
      run_turn "warmup_$name" "$sid" "$tr" "$repo" "$cond" "$task"
      # tours baseline (même tâche, N tours → hit stable)
      for i in $(seq 1 "$turns"); do
        run_turn "base_${name}_$i" "$sid" "$tr" "$repo" "$cond" "$task"
      done
      # événement : changer de cwd (repo A↔B) puis revenir
      local other="$REPO_A"; [ "$repo" = "$REPO_A" ] && other="$REPO_B"
      run_turn "cd_${name}" "$sid" "$tr" "$other" "$cond" "$task"
      run_turn "back_${name}" "$sid" "$tr" "$repo" "$cond" "$task"
    done
  done
}

# -------------------- Analyse --------------------
analyze_all() {
  echo; echo "=== ANALYSE AGRÉGÉE (par scénario × condition) ==="
  for prefix in "s1" "s2" "s5" "s8"; do
    echo "— Scénario $prefix —"
    for cond in A B; do
      ANALYZE_DIR="$RESULTS" ANALYZE_PREFIX="$prefix" ANALYZE_COND="$cond" node << 'NODEEOF'
const fs = require("fs"), path = require("path");
const dir = process.env.ANALYZE_DIR, pref = process.env.ANALYZE_PREFIX, cond = process.env.ANALYZE_COND;
const files = fs.readdirSync(dir).filter(f => f.startsWith(pref+"-cond"+cond) && f.endsWith(".jsonl"));
let totCr = 0, totIn = 0, totCost = 0, totTours = 0, cds = [];
for (const f of files) {
  const lines = fs.readFileSync(path.join(dir,f),"utf8").trim().split("\n").filter(Boolean);
  let cur = null, seq=[];
  for (const l of lines) {
    const o = JSON.parse(l);
    if (o.kind==="request") cur = { ...o };
    if (o.kind==="usage" && cur) {
      const u = o.usage;
      totCr += u.cacheRead; totIn += u.input; totCost += (u.cost?.total??0); totTours++;
      seq.push({label:cur.label, cr:u.cacheRead, in:u.input, sd:cur.systemBytes,
                sh:cur.systemHash?.slice(0,8), tools:(cur.toolNames||[]).join(",")});
      cur = null;
    }
  }
  const cd = seq.find(r => r.label.startsWith("cd_"));
  if (cd) cds.push({ cr: cd.cr, sb: cd.sd, tools: cd.tools });
}
const hitRate = (totCr+totIn)>0 ? (totCr/(totCr+totIn)*100).toFixed(1) : "0";
let cdMed = "n/a", cdSb = "n/a";
if (cds.length) {
  cdMed = cds.map(c=>c.cr).sort((a,b)=>a-b)[Math.floor(cds.length/2)];
  cdSb = cds[0].sb;
}
console.log("  cond "+cond+": hit_rate="+hitRate+"%  cr="+totCr+" in="+totIn+" cost=$"+totCost.toFixed(4)+" tours="+totTours+"  [cd_ cr median="+cdMed+", sysBytes="+cdSb+"]");
NODEEOF
    done
  done
}

# -------------------- Exécution --------------------
scenario s1 "$TASK_S1" "$REPO_A" 3 0     # lecture (3 fichiers)
scenario s2 "$TASK_S2" "$REPO_A" 3 0     # édition
scenario s5 "$TASK_S5" "$REPO_A" 2 1     # AGENTS.md
scenario s8 "$TASK_S8" "$REPO_A" 2 1     # multi-repo

analyze_all
echo; echo "===== FIN H3-BIAS ====="