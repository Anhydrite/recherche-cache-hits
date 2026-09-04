# Recherche & Expérimentation — Cache Hits dans les Harnesses d'Agents de Code (pi)

> **Objectif** : optimiser le taux de cache-hit (prompt caching) côté API pour le harness d'agent de codage **pi** (earendil-works). Cette repo contient la recherche documentaire, les hypothèses, les protocoles expérimentaux **anti-biais**, et les résultats mesurés sur **2 providers** (validation croisée).

**Date** : septembre 2026 · **Auteur** : Anhydrite

---

## 📚 Contenu de la repo

| Fichier | Contenu |
|---|---|
| `docs/README-cache-hit-harnesses.md` | État de l'art : comment 8 harnesses (pi, opencode, aider, cline, goose, Claude Code, Codex, Gemini CLI) maximisent le cache |
| `docs/02-comprehension-etat-de-l-art.md` | Compréhension fine du mécanisme + analyse du code source de pi + état de l'art académique (papier « Don't Break the Cache » arXiv:2601.06007) |
| `docs/03-conclusions-hypotheses-optimisation.md` | 10 hypothèses d'optimisation (H1-H10) avec mécanisme + prédictions |
| `docs/04-cas-de-tests-et-predictions.md` | Cas de tests objectifs & indépendants par hypothèse |
| `docs/05-protocoles-experimentaux-et-predictions.md` | **Protocoles expérimentaux exécutables + protocole anti-biais multi-scénarios + résultats complets** |
| `scripts/setup-test-env.sh` | Bac à sable isolé pour les tests (ne touche jamais le harness de prod) |
| `scripts/exp-runner.sh` | Harness d'exécution d'un tour de test avec instrumentation |
| `scripts/run-t1.sh` / `run-campaign.sh` / `run-h2.sh` | Drivers des expériences T1, T1-refined, T2, T3, T6 |
| `scripts/run-h3-bias.sh` | Driver du protocole anti-biais H3 (scénarios réalistes, randomisation A/B) |
| `scripts/run-h3-cross-provider.sh` | Validation croisée H3 sur 2 providers |
| `results/` | Traces JSONL brutes + rapports par expérience (63 fichiers, ~0.51 $ de coût API total) |

---

## 🧪 Méthodologie

### Le problème du biais de test
Un test "bateau" peut favoriser une technique par construction, ou une technique peut n'être efficace que sur le test et pas en usage réel. **Le protocole anti-biais (doc 05 Partie 6) impose** :
1. **Scénarios d'usage réels** (lecture, édition, AGENTS.md, multi-repo) — pas "réponds OK"
2. **Randomisation A/B** de l'ordre des conditions (neutralise le biais d'ordre)
3. **Sessions séparées** par condition (le cache d'une condition ne doit pas alimenter l'autre)
4. **Repos égalisés** (même AGENTS.md partout — sinon on mélange 2 variables)
5. **Métriques écologiques** : `hit_rate_session` agrégé + coût du tour "événement" (le moment où l'optimisation devrait agir)
6. **Validation croisée par provider** : un résultat doit se confirmer sur ≥ 2 providers pour être crédible

### Le bac à sable isolé
Tous les tests tournent dans `.pi-test/` (config + sessions + résultats séparés) — **le harness de prod n'est jamais touché**. Les credentials sont partagés (auth.json copié) mais leur contenu n'est jamais affiché.

---

## 📊 Résultats consolidés

### Coût total des expériences : **~0.51 $** (63 traces, 2 providers, ~50 sessions)

### T1 — Rebuild du system prompt (changement d'outils)

| Config | Résultat |
|---|---|
| Rebuild **fin** d'outils (retirer edit/write) | **Miss PARTIEL** : cr 2816→2048 (seule la portion retirée re-part) |
| Rebuild **milieu** d'outils (read,bash → read,edit) | **Miss TOTAL** : cr 2816→0 (le system prompt change car les guidelines dépendent des outils) |

→ Le vrai levier : **garder un set d'outils stable** (le system prompt de pi change quand les tools changent).

### T2 / H2 — Boucle d'outils intra-tour

**HIT RATE GLOBAL = 91.9 %** (16 appels). Le breakpoint « dernier user » de pi est **optimal** (comme opencode le documente) : chaque appel intra-tour matche le préfixe, seuls les deltas passent en input. **Rien à corriger.**

### T3 / H3 — cwd dans le system prompt (validation croisée)

**Découverte méthodologique majeure** : le test initial T3 était **biaisé** (les 2 repos avaient des AGENTS.md différents → le "miss" observé venait du contexte projet, pas du cwd).

Après correction (repos égalisés) + validation croisée sur **commandcode** et **opencode-go** (N=3, 4 scénarios) :

| Scénario | commandcode Δcoût | opencode-go Δcoût | Cohérence |
|---|---|---|---|
| lecture | +1 % (neutre) | -13 % (B meilleur) | ❌ diverge |
| édition | +65 % (B pire) | -11 % (B meilleur) | ❌ diverge |
| AGENTS.md | -15 % (B meilleur) | +18 % (B pire) | ❌ diverge |
| multi-repo | -23 % (B meilleur) | +14 % (B pire) | ❌ diverge |

**→ H3 RÉFUTÉE** : les Δ sont du bruit inter-sessions (coûts de l'ordre de 0.0001 $), pas un signal. Aucun scénario n'a le même signe sur les 2 providers. **Le cwd en fin de system prompt (design actuel de pi) est déjà quasi optimal** (préfixe stable avant le cwd).

### T6 / H6 — Resume bit-identique

**VALIDÉE** : le prompt reconstruit au resume (même session-id) est bit-identique (sysHash constant), le cache OpenAI survit au resume (cr 2816 → 2816 hit total).

---

## ✅ Verdicts finaux

| Hypothèse | Verdict | Preuve |
|---|---|---|
| H1 frozen system prompt | **Nuancée** | Rebuild fin = miss partiel (×3.5), rebuild milieu = miss total (cr=0) |
| H2 breakpoint dernier user | **Déjà optimale** | Hit 91.9 % en boucle d'outils |
| H3 cwd hors system | **RÉFUTÉE** | Δ = bruit, signes inversés entre providers |
| H6 resume bit-identique | **Validée** | Hit total au resume, sysHash identique |
| H4 hybride exclude tool results | **Inapplicable** (cache implicite, Claude bloqué par plan) | Vérifié payload |
| H5 keepalive | Non testé (besoin pauses > 5 min) | — |
| H7-H10 | Hors périmètre rapide | — |

**Recommandation d'implémentation dans pi** :
1. **H1 (nuancée)** : geler le system prompt quand le set d'outils change (miss total évité) — gain réel sur les sessions avec tools dynamiques/MCP
2. **H6** : rien à faire (déjà bon)
3. **H3** : ne PAS implémenter (le design actuel est déjà optimal)

---

## 🔬 Reproduire

```bash
# 1. Bac à sable (jamais le harness prod)
./scripts/setup-test-env.sh check

# 2. Campagne H3 sur un provider (résultats dans results/h3bias-<provider>/)
H3_PROVIDER=commandcode H3_MODEL=deepseek/deepseek-v4-flash N=3 ./scripts/run-h3-bias.sh

# 3. Validation croisée (compare les dossiers résultats)
./scripts/run-h3-cross-provider.sh

# 4. Autres expériences
./scripts/run-t1.sh          # rebuild fin d'outils
./scripts/run-campaign.sh    # T1-refined + T3 + T6
./scripts/run-h2.sh          # boucle d'outils
```

**Providers testés** : `commandcode` (deepseek/deepseek-v4-flash) et `opencode-go` (deepseek-v4-flash).