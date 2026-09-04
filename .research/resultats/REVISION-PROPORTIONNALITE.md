# RÉVISION GLOBALE — la découverte de proportionnalité change-t-elle les verdicts ?

**Découverte** : le rebuild d'outils ne casse que le **system natif** (~1900-2500 tokens), pas le préfixe complet (le contexte projet appendé reste en cache). Démontré par le test gros préfixe (baseline → 97.8% hit, pas 0%).

## Impact par expérience

| Exp | Verdict avant | Verdict après | Changé ? |
|---|---|---|---|
| H1/T1 rebuild tools | miss total (cr=0) | **miss partiel sur sessions réelles** (seul le system natif change) | ⚠️ surestimé |
| T1-refined set change | miss total | idem (partiel si gros contexte) | ⚠️ |
| H3 cwd | réfuté (~100-200 tok) | **inchangé** (bonne échelle) | ✅ |
| E1 P0-A découplage | 0%→87%, fort | **borné** : +0 pt sur gros préfixe, seul ~500-2000 tok/rebuild sauvés | ❌ déclassé |
| E3 TTL | non-bloquant | inchangé | ✅ |
| E4 warmup | inutile | inchangé | ✅ |
| E2 table sémantique | GAP dernier tool | inchangé (bug marquage) | ✅ |
| H2 boucle | 91.9% | inchangé | ✅ |
| H6 resume | bit-identique | inchangé | ✅ |

## Conclusion révisée

1. **Le problème H1 est moins grave que montré** : sur des sessions réelles avec gros contextes, le rebuild ne relit que ~500-1900 tokens (le system), pas tout.
2. **P0-A n'est plus une priorité économique** : son gain en % de cache hit est ~nul sur gros préfixe.
3. **Les expériences qui résistent** (E3, E4, E2, H2, H6) confirment le tableau : pi est déjà assez optimal ; les optimisations populaires sont écartées.
4. **Le seul point actionnable** reste E2 (GAP marquage dernier tool) mais pour des modèles bloqués par le plan.

## Leçon méthodologique
La question "le hit_rate % ne dit rien sans la taille du préfixe" a révélé un biais de mesure : **tous les tests précédents utilisaient un petit préfixe (system seul), sur-estimant l'impact des rebuilds**. Les tests futurs doivent TOUJOURS inclure un contexte projet réaliste (gros préfixe) — c'est l'état réel.
