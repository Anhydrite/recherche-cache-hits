# E2 — Table de sémantique (P0-B) : inspection payload réelle

**Date** : 2026-09-04 · **Méthode** : hook `before_provider_request` (offline, 0 $) sur 8 (provider, modèle).

## Résultats (conformité du marquage)

| Provider / modèle | system cache_control | dernier tool cache_control | Sémantique détectée | Conforme ? |
|---|---|---|---|---|
| opencode-go/deepseek-v4-flash | n/a (pas de system séparé) | non | **implicite** | ✅ (attendue) |
| opencode-go/deepseek-v4-pro | n/a | non | implicite | ✅ |
| opencode-go/glm-5.1 | n/a | non | implicite | ✅ |
| opencode-go/qwen3.6-plus | n/a | non | implicite | ✅ |
| commandcode/deepseek-v4-flash | n/a | non | implicite | ✅ |
| commandcode/gpt-5.6-sol | n/a | non | implicite | ✅ |
| commandcode/claude-sonnet-5 | **OUI** | **non** | **explicite (partiel)** | ⚠️ GAP |
| commandcode/claude-haiku-4-5 | **OUI** | **non** | explicite (partiel) | ⚠️ GAP |

## Finding clé : GAP sur le dernier tool des modèles explicites

Le pattern canonique pi pose `cache_control` sur le **dernier tool** (`index===tools.length-1`) pour les providers explicites. Or sur commandcode/claude (explicites), le **dernier tool n'a PAS de cache_control** — seul le system en a.

**Hypothèses** : (1) le bridge commandcode ne propage pas le marquage tools ; (2) pi détecte commandcode comme non-explicite pour les tools malgré le system explicite. À vérifier (voir E9/P0-B implémentation).

**Impact** : sans breakpoint sur le dernier tool, le préfixe rejoué s'arrête au system → les **tools (définitions) ne sont pas rejoués en cache** sur les modèles explicites accessibles → coût + latence sur ces modèles (mais ils sont bloqués par le plan ici).

## Conformité globale
- **Implicite** (6/6) : conforme — aucun cache_control émis (correct : le provider matche tout seul).
- **Explicite** (2/2) : system marqué ✅, dernier tool NON marqué ⚠️.

## Verdict E2
P0-B (table de sémantique) est **nécessaire** : pi doit connaître (provider, modèle) → sémantique pour (a) ne PAS émettre de cc sur implicite (déjà bon), (b) émettre le cc sur le **dernier tool** pour explicite (à corriger via bridge commandcode ou compat).
