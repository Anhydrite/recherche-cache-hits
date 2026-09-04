# SYNTHÈSE HONNÊTE E1 — le vrai gain de P0-A (correction de surestimation)

**Date** : 2026-09-04 · **Provider** : opencode-go/deepseek-v4-flash · **Tests** : process RPC continu, 4 tours, rebuild au tour 3, 3 conditions (témoin / baseline / découplé), petit ET gros préfixe.

## 1. Tableau comparatif (petit préfixe ~2900 tokens)

| Condition | hit_rate tour4 | cr (tokens relus) | in (tokens payés) | sysStable |
|---|---|---|---|---|
| **Témoin** (pas de rebuild) | **97.0%** | 2816 | ~86 | ✅ |
| **Baseline** (rebuild) | **0.0%** | **0** | **2388** | ❌ |
| **Découplé** (fix) | **87.4%** | **2304** | ~331 | ✅ |

→ Sur PETIT préfixe : le découplé ramène le hit de 0% → 87%, économise ~2000 tokens/tour.

## 2. Le test de proportionnalité (gros préfixe ~11k tokens) — CORRECTION CRITIQUE

| Condition (gros préfixe) | cr tour4 | in tour4 | hit_rate |
|---|---|---|---|
| Baseline (rebuild) | **11008** | 253 | **97.8%** |
| Découplé (fix) | ~11008 | ~250 | ~97.8% |

**Découverte** : avec un gros préfixe (append-system-prompt 11k tokens), le rebuild NE casse PLUS le hit (97.8% au tour 4 !). Pourquoi :
- Le rebuild ne régénère que le **system NATIF** (7481 octets ≈ 1900 tokens).
- Le gros bloc appendé (positionné APRÈS le system) **ne change pas** → il reste en cache.
- Le miss se limite à la portion system natif changeante, **pas au préfixe entier**.

## 3. Conclusion : le gain de P0-A est BORNÉ

**Le gain réel de P0-A est ~500-2000 tokens par rebuild** (= la taille du system natif + guidelines), **PAS proportionnel à la taille totale du préfixe**. L'intuition "plus le préfixe est long, plus le miss coûte" est FAUSSE ici car le rebuild ne touche que le début (system), pas l'appendé.

### En % de cache hit (la métrique qui t'intéresse)
- **Petit préfixe** : hit_rate passe 0% → 87% au tour rebuild (**+87 points**)
- **Gros préfixe** : hit_rate passe ~97.8% → ~97.8% (**+0 point** net, le miss n'est pas total)

### La conclusion honnête
**P0-A a un impact réel seulement si** :
1. Les rebuilds sont **fréquents** (skills/MCP/tools dynamiques), ET
2. Le préfixe system natif est **substantiel** par rapport au total (peu d'append/contexte projet).

**Sur tes sessions réelles** (avec skills + gros contextes projet), le gain est probablement **faible en % global** (le % est déjà élevé quand le contexte est gros et stable), mais **réel en tokens absolus** sur les sessions à rebuilds fréquents.

## Recommandation
- **Ne PAS implémenter P0-A en priorité** sur la base du gain seul (~500-2000 tok/rebuild).
- L'implémenter seulement si les rebuilds sont fréquents (à mesurer sur tes sessions réelles : combien de rebuilds/session).
- La valeur de P0-A est surtout **structurelle** (préfixe stable = fondation), pas économique immédiate.
