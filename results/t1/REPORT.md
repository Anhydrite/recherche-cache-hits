# Rapport T1 — « Rebuild d'outils → invalidation de cache ? »

**Date** : 2026-09-04
**Environnement** : bac à sable isolé (.pi-test/) — jamais le harness prod
**Provider** : opencode-go / deepseek-v4-flash
**Prompt** : "T1 <phase>: réponds uniquement OK."
**Session** : même `--session-id` par session de test (clé de cache stable)

## Protocole exécuté (N=5 sessions démo, 3 traces analysées)

| Phase | Outils | Attendu |
|---|---|---|
| warmup | 4 (read,bash,edit,write) | écrit le cache |
| baseline 1-3 | 4 | hit (cr > 0) |
| rebuild | **2 (read,bash)** | miss prédit |
| restore | 4 | re-hit |
| control | 4 (mêmes que baseline) | hit |

## Résultat

| Phase | cacheRead médian | coût médian | hash |
|---|---|---|---|
| warmup | 0-2560 (1er tour) | 0.00062 | f86432dc |
| baseline 1-3 | **2816** | 0.000028-0.000036 | cc130b23... |
| rebuild (2 tools) | **2048-2304** | 0.00009-0.0005 | a4faf1b1... |
| restore | **2816** | 0.00004 | cc4b1a13... |
| control | **2816** | 0.00005 | b736357f... |

## Verdict

**L'hypothèse H1 naïve (« rebuild → miss total ») est REFUSÉE.**
Le rebuild d'outils en fin de liste ne casse que la portion modifiée (~768 tokens),
pas le system prompt. Le cache system + tools avant le changement reste hit.

- Coût du rebuild : ×3.5 (pas ×10).
- Le restore retombe à 2816 (réutilisation des tool defs complètes).
- Miss total observé UNIQUEMENT au tout premier tour d'une session (warmup).

## Leçon pour les prochaines expériences

1. Le **hash complet du payload ne prédit pas le miss** — comparer segment par segment.
2. Tester le rebuild **au milieu** des tools (changement de l'ordre) → miss potentiellement total.
3. `cacheRead` est la métrique reine (partie rejouée), pas le hash.
