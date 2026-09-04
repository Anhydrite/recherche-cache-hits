# MICRO-LEVIERS — optimisations de petits gains identifiées après la recherche

> **Contexte** : après les expériences E0-E10 et la révision de proportionnalité, le gros gain (P0-A) est déclassé. Les opportunités restantes sont des **petits gains cumulés** — d'où la nécessité de "tatilloner".
> **Date** : 2026-09-04 · **Provider** : opencode-go/deepseek-v4-flash (uniquement)
> **Base** : mesures H2 (tokens relus par tour : 75-922), E1-RPC, synthèse honnête.

---

## 1. Où partent les tokens (diagnostic mesuré)

À CHAQUE tour, le préfixe est relu en cache (`cacheRead`) :
| Composant | Taille (tokens) | Remarque |
|---|---|---|
| System prompt pi | ~1900-2500 | Parfaitement stable — déjà optimisé |
| Tool defs (4 outils) | ~400-700 | **Footprint fixe, relu à chaque tour** |
| Historique conversation | croît (0 → N) | Compaction seule solution |

À CHAQUE tour, le delta est payé en plein (`input` — mesuré en H2) :
| Composant | Taille (tokens/tour) | Remarque |
|---|---|---|
| **Tool results** | **75-922** | **LE poste dominant du delta** — croissance inter-tours |
| Réponse assistant + nouveau msg | 50-300 | Incompressible |

**→ Le levier le plus rentable = TRONQUER les tool results** (le flux qui grossit le contexte entre tours).

---

## 2. Micro-levier n°1 — Troncature des tool results (PRIORITAIRE)

### Mécanisme
Quand un outil (bash, read, edit, write) retourne un résultat volumineux (> seuil S), pi l'injecte **en entier** dans le contexte → relu à **chaque tour suivant**.

**Optimisation** : tronquer le résultat à l'écriture du tool result (patron opencode) :
- Garder **tête + queue** du résultat (ex. 1000 + 500 chars) + marqueur `…[N lignes omises]`
- **Garder le plein dans l'état local** (pour les retries / ré-injections si besoin)

### Pourquoi ça marche (données H2)
- Tool results = 60-80% de la croissance inter-tours (deltas mesurés 75-922 tokens/tour dont la majorité sont les résultats).
- La troncature agit sur **ce flux** → les tokens relus par tour diminuent.
- Le préfixe stable (system + outils) n'est PAS touché → hit_rate inchangé.

### Prédiction chiffrée (H-F du protocole phase 5)
- Tokens relus par tour : **B ≤ A de −30% en médiane** (intervalle −25 à −45%)
- `hit_rate_session` : **inchangé ±1%** (le préfixe stable reste entier)
- Qualité : ≥ 90% de réussite dans les 2 conditions, Δ ≤ 2% (troncature à 6000 chars + marqueur)
- Biais à éviter : **jamais tronquer avant le dernier breakpoint** (casserait le préfixe — le pire des cas) ; standardiser les tâches (mêmes sorties) ; juge qualité en aveugle.

### Protocole (anti-biais, doc 05 §6)
1. **Scénarios** : S3 (long feature, sorties bash/read longues) + S4 (boucle d'outils).
2. **N ≥ 5 sessions** par condition (A : texte intégral, B : tronqué), randomisation A/B, sessions séparées.
3. **Même tâches** avec sorties **standardisées de même taille** dans les 2 conditions.
4. **Métriques** : tokens relus par tour (reine), `hit_rate_session`, `cost_total_session`, `ttft`, qualité (juge binaire).
5. **Verdict** : VALIDÉE si tokens relus −30%+ (médiane) sur ≥ 70% des scénarios ET hit_rate ≥ baseline −2% ET Δ qualité ≤ 2%.

### Effort / risque / gain
| | |
|---|---|
| Effort | Faible (troncature à l'écriture du tool result, ~30-50 lignes) |
| Risque | Faible-moyen (qualité si troncature agressive → valider par tests de tâche) |
| Gain | −30-45% des tokens relus par tour sur TOUS les profils (levier multiplicatif) |
| Coût test | ~0.5-1 $ (S3/S4, N≥5) |

---

## 3. Micro-levier n°2 — Réduire les descriptions d'outils

### Mécanisme
Les 4 tool defs (read, bash, edit, write) font ~400-700 tokens, **relus à chaque tour**. Des descriptions verbeuses (~100-150 tok/tool) gonflent ce footprint fixe.

### Optimisation
Raccourcir les descriptions à l'essentiel (1-2 lignes par tool) — pi garde l'essentiel ("Use read to examine files instead of cat or sed", etc.).

### Prédiction
- Tokens relus/tour : **−300-500** (fixe, cumulé sur toute la session).
- **Risque** : qualité (le modèle moins guidé) — à valider par tests de tâche (le modèle pi connaît déjà ses outils via l'expérience).
- **Verdict attendu** : gain réel et permanent, mais risque qualité — priorité moyenne.

### Note
Le gain est **proportionnel à la longueur de session** (le footprint fixe est relu à chaque tour) → très intéressant sur sessions longues.

---

## 4. Micro-levier n°3 — Compaction de l'historique

### Mécanisme
Le préfixe relu grossit avec la session (conversation ∝ tours). Au-delà d'un seuil, résumer les vieux échanges (résumé dans le préfixe, détails tronqués).

### Prédiction
- Sur sessions > 20 tours : évite la croissance linéaire du préfixe relu.
- Coût : un tour de résumé + invalidation partielle (le résumé change le préfixe) — tradeoff.
- **Verdict** : utile sur très longues sessions, priorité basse (pi a déjà une compaction).

---

## 5. Micro-levier n°4 — Mesurer les rebuilds réels (P0-A conditionnel)

### Mécanisme
P0-A (découplage system↔outils) est déclassé en % global, mais reste utile SI les rebuilds sont fréquents (skills/MCP/tools dynamiques) : ~500-1900 tokens/rebuild.

### À faire
Mesurer sur les sessions réelles de l'utilisateur : **combien de rebuilds par session** (scanner les sessions réelles pour les changements de set d'outils). Si ≥ 3-5 rebuilds/session → P0-A redevient pertinent cumulativement.

---

## 6. Table récapitulative des micro-leviers

| Levier | Gain estimé | Effort | Risque | Priorité |
|---|---|---|---|---|
| **1. Troncature tool results** | **−30-45% tokens relus/tour** | Faible | Faible-moyen | 🔥 **1** |
| 2. Descriptions outils courtes | −300-500 tok/tour (fixe) | Faible | Moyen (qualité) | 2 |
| 3. Compaction historique | Évite croissance linéaire | Moyen | Faible | 3 |
| 4. Rebuilds réels (P0-A) | ~500-1900/rebuild SI fréquents | Mesure d'abord | Faible | 4 (conditionnel) |

---

## 7. Prochaine étape recommandée

**Construire et exécuter l'expérience de troncature (levier 1)** :
1. Extension `truncate-tool-results.ts` (tronque les résultats > 6000 chars avec marqueur, garde le plein en état local).
2. Driver `run-truncate.sh` (S3/S4, N≥5, randomisé, deepseek-v4-flash).
3. Mesurer tokens relus/tour, hit_rate, qualité.
4. Verdict : −30%+ attendu.

Coût estimé : ~0.5-1 $.