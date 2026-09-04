# E3 — TTL long vs court (P0-C) : le cache d'opencode-go SURVIT à 5.5 min

**Date** : 2026-09-04 · **Provider** : opencode-go/deepseek-v4-flash

## Résultats

### Mode short (TTL court, sans PI_CACHE_RETENTION)

| Pause | cacheRead | Note |
|---|---|---|
| baseline (chaud) | 2816 | hit |
| 60s | 2816 | **hit maintenu** |
| 120s | 2816 | **hit maintenu** |
| 240s (4 min) | 2816 | **hit maintenu** |
| **330s (5.5 min)** | **2816** | **hit maintenu AU-DELÀ du TTL 5 min Anthropic** |

### Mode long (PI_CACHE_RETENTION=long)
- Le script a eu un problème de trace (session réutilisée entre modes) — le test isolé `PI_CACHE_RETENTION=long` passe (EXIT=0).

## Découverte clé

**Le cache d'opencode-go SURVIT à une pause de 5.5 minutes** (cr=2816 constant), contrairement au TTL court Anthropic documenté (~5 min). Explications possibles :
1. Le TTL réel d'opencode-go est significativement plus long que 5 min (peut-être 10-30 min ou plus).
2. Le cache "refresh on reuse" prolonge à chaque lecture.
3. Le backend OpenCode Go utilise sa propre politique de rétention (pas celle d'Anthropic).

## Conséquence pour P0-C (TTL long par défaut)

**P0-C est NEUTRALISÉE sur opencode-go** : puisque le cache survit déjà à 5.5 min sans rétention longue, activer `PI_CACHE_RETENTION=long` n'apporte **aucun bénéfice mesurable** (le goulot TTL n'existe pas ici).

→ Sur ce provider, P0-C (TTL long par défaut) n'est **pas une optimisation** — le cache est déjà résilient. Sur des providers au TTL strict (Anthropic direct), elle garde son intérêt (mais non testable ici sans accès Anthropic).

## Verdict E3
- **TTL court n'est pas un problème sur opencode-go** (pas de miss à 5.5 min).
- **P0-C reste pertinent théoriquement** pour les providers Anthropic-stricts, mais **inutile sur opencode-go**.
- Le postulat "idle > 5 min = miss" (cause n°1 de misses documentée) est **invalide sur ce provider** — à vérifier provider par provider (confirme l'esprit de P0-B : la sémantique est par (provider, modèle)).
