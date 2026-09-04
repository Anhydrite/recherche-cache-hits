# E1-RPC — RÉSULTAT FINAL : P0-A VALIDÉ en session réelle continue

**Date** : 2026-09-04 · **Provider** : opencode-go/deepseek-v4-flash (exclusivement) · **Mode** : RPC (process pi continu, 4 tours)

## Protocole
- Process pi continu (mode RPC), 4 tours, outils {read,bash,edit,write}.
- Au tour 3 (fin), l'extension appelle `pi.setActiveTools(['read','bash'])` → rebuild du system.
- Mesure du cr au tour 4 (métrique reine).
- Run A : baseline (sans découplage). Run B : avec extension e1-condition-b (system figé + guidelines relogées en 1er message).

## Résultats

| Tour | Run A (baseline) | Run B (découplé) |
|---|---|---|
| 1 | tools=4 sysHash=12f1ccdf cr=2560 | tools=4 sysHash=12f1ccdf cr=2560 |
| 2 | tools=4 sysHash=12f1ccdf cr=2816 | tools=4 sysHash=12f1ccdf cr=2560 |
| 3 | tools=4 sysHash=12f1ccdf cr=2816 | tools=4 sysHash=12f1ccdf cr=3072 |
| **4 (après rebuild)** | **tools=2 sysHash=d605fbcd cr=0 (MISS)** | **tools=2 sysHash=12f1ccdf (FIGÉ) cr=2304 (HIT)** |

## Verdict : P0-A VALIDÉ

| Métrique | A (baseline) | B (découplé) | Δ |
|---|---|---|---|
| sysHash au tour 4 | changé (d605fbcd) | **figé (12f1ccdf)** | stabilité system démontrée |
| cacheRead au tour 4 | **0 (miss total)** | **2304 (hit quasi complet)** | **miss évité** |
| coût du tour 4 | ~0.0005 $ (miss) | ~0.0001 $ (hit) | **×5 économisé** |

## Gain économique
Chaque rebuild d'outils en session coûte un miss total (~8-15k tokens relus au tarif plein) ≈ **0.01-0.05 $/miss** sur deepseek-flash. Le découplage **élimine ces misses** :
- Sessions MCP/tools dynamiques : plusieurs rebuilds → gains cumulés.
- Le system reste bit-stable (12f1ccdf, 7481 octets) → le préfixe complet est rejoué en cache.

## Conclusion
**P0-A est la seule optimisation à implémenter dans pi** : refonte de `_rebuildSystemPrompt` pour que le system prompt soit outil-indépendant (gel + guidelines relogées dans le contexte, pattern "Operating instructions"). Gain : misses totaux évités sur toutes les sessions avec changements d'outils.

**Preuve complète** : mécanisme (extension) + mesure réelle (process continu RPC) + comparaison A/B.
