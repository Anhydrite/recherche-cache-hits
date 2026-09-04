# E4 — Warmup du 1er appel (P1-D) : INUTILE sur opencode-go

**Date** : 2026-09-04 · **Provider** : opencode-go/deepseek-v4-flash · **N** : 3 sessions/cond (randomisé)

## Résultats (cr du 1er tour réel)

| Session | cond A (sans warmup) | cond B (avec warmup) |
|---|---|---|
| 1 | reel: cr=2816 | ping cr=2560 → reel cr=2816 |
| 2 | reel: cr=2816 | ping cr=2560 → reel cr=2816 |
| 3 | reel: cr=2816 | ping cr=2560 → reel cr=2816 |

## Verdict : warmup INUTILE ici

- **cr = 2816 (hit maximal) dès le 1er tour réel dans les 2 conditions.**
- **Explication (confirme E0)** : le system prompt de pi est *partagé entre sessions* (même contenu) → déjà en cache du provider au 1er tour, sans warmup.
- Le ping warmup **coûte** (écrit ~2560 tokens au tarif plein, cw=0 mais in=254+écriture) sans bénéfice.

## Nuance (où le warmup pourrait servir)
- Uniquement pour un préfixe **session-unique** (ex. premier message user qui contient du contexte projet spécifique) — hors du system partagé.
- Sur des providers à **system session-specific** (contexte projet injecté par session), le warmup aurait un sens. Pas ici.

## Conséquence
- **P1-D (warmup) → REJETÉE pour pi sur ces providers** : le system partagé rend le warmup superflu ; c'est même un coût net (écriture 1.25× inutile si la session s'arrête vite).
- Le postulat "le 1er tour est toujours un miss" (P10) est **invalide pour un system partagé** — nuance importante déjà vue en E0.
