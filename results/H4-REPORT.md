# Rapport H4 — « Exclure les tool results du cache » : INAPPLICABLE

**Date** : 2026-09-04 · **Provider testés** : commandcode (deepseek, gpt-5.6-sol, claude-sonnet-5), opencode-go (deepseek-v4-flash)

## Question
La stratégie « exclude tool results » (gagnante du papier *Don't Break the Cache*, GPT-5.2 : 79.6 % cost ↓, 13 % TTFT ↓) peut-elle être implémentée côté harness pi ?

## Vérification (payload réel, hook before_provider_request)

| Provider / modèle | cache_control émis | Sémantique | Accessible |
|---|---|---|---|
| opencode-go / deepseek-v4-flash | non | implicite | ✅ |
| commandcode / deepseek-v4-flash | non | implicite | ✅ |
| commandcode / gpt-5.6-sol | non | implicite | ✅ |
| commandcode / claude-sonnet-5 | **oui** (system + msg) | explicite | ❌ 403 MODEL_NOT_IN_PLAN |
| commandcode / claude-fable-5, haiku | oui | explicite | ❌ 403 MODEL_NOT_IN_PLAN |

## Verdict

**H4 est INAPPLICABLE dans cet environnement** :
1. Les 3 modèles accessibles sont en **cache implicite** — le client ne contrôle pas la frontière du cache (pas de cache_control), donc ne peut PAS exclure la queue.
2. Les seuls modèles avec breakpoints (Claude) sont bloqués par le plan.
3. Le « full vs exclude » du papier concerne des modèles à cache explicite : ce n'est pas un levier du harness sur les providers utilisés.

## Piste future
- Re-tester H4 quand un modèle anthropic/à breakpoints sera accessible (plan Pro / clé API Anthropic directe).
- Alternative (H4-variant implicite) : compaction progressive des vieux tool results → préfixe plus court. Non exécutée (coût + éloignement de H4 littéral).

## Leçon
Le choix de la stratégie de cache dépend de la **sémantique du provider** (explicite vs implicite) — exactement le point H9 (table de sémantique type goose). Pour du cache implicite, le seul levier harness = stabilité du préfixe + taille (compaction), pas les breakpoints.
