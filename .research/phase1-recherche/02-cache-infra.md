# Rapport Phase 1 — 02 : Infrastructure, APIs & comportements réels du cache

> **Rédigé par** : orchestrateur (docs projet + recherche web externe 00-web-external.md, sources 2025-2026 vérifiées en ligne)
> **Date** : 2026-09-04

## 1. Mécanismes serveur (la couche en-dessous du cache API)

| Mécanisme | Principe | Source |
|---|---|---|
| **RadixAttention** (SGLang) | Arbre radix mutable des préfixes partagés ; réutilisation automatique du KV ; métrique `radix_cache_hit_rate` | arXiv 2407.04391 |
| **vLLM APC** | Blocs de 16 tokens hachés ; lookup à la volée ; `vllm:prefix_cache_hit_rate` ; **byte-stability obligatoire** (1 octet change = bloc invalide) | docs vLLM |
| **LMCache** | KV hiérarchique GPU→CPU→disque→S3/Redis ; cross-engine (vLLM/SGLang) | arXiv 2510.09665 |
| **CacheBlend** | **Reuse non-préfixe** : fusion de segments KV chevauchants + re-calcul sélectif ; ~63-85% hit vs 3-25% prefix-only ; ~4× TTFT | arXiv 2405.16444 |
| **Hydragen** | Attention **intra-batch** sur préfixes longs partagés (prototype) | arXiv 2402.05099 |

**Leçon** : le cache API = exact-prefix ; le cache infra = radix/non-prefix. Côté harness, on contrôle l'ordre/la stabilité ; côté serving, la réutilisation KV.

## 2. APIs provider (les chiffres actualisés)

### Anthropic (explicite — breakpoints)
- `cache_control: {type:"ephemeral"}` sur ≤ 4 blocs/requête.
- Tarifs : write **1.25×**, read **0.1×**.
- TTL : 5 min (default) / 1h (long).
- Seuil minimal : 1024 tokens (⚠️ possible montée à 2048 selon les sources récentes).
- Observabilité : `cache_read_input_tokens`, `cache_creation_input_tokens`.
- **Nouveauté** : "The system automatically applies the cache breakpoint to the last cacheable block and moves it forward" — breakpoint automatique (platform docs 2026).

### OpenAI (implicite)
- ≥ 1024 tokens de préfixe stable ; read **0.5×**.
- TTL glissant 5-10 min (30-min lifetime "refreshed on reuse").
- `prompt_tokens_details.cached_tokens`.
- **⚠️ CRITIQUE (sources community 2025-2026 — non-déterministe)** :
  - "Caching is borked for GPT-5 models" (sept 2025) : **cache hit rate 1/20**, `prompt_cache_key` SANS effet — "merely an additional input to the hashing".
  - "prompt_cache_key is NOT deterministic" : 2 prompts identiques à la suite → le 2e n'est PAS garanti 100% caché ; prend des **secondes à minutes** pour prendre effet.
  - "cached_tokens=0 intermittently même préfixe statique identique" (juil 2026).
  - → **Le cache OpenAI n'est PAS garanti même bit-identique** ; le prompt_cache_key est un indice de locality, pas une garantie.
  - Azure OpenAI : +prompt_cache_key a fait passer le hit de 60% → 87% (un déploiement, avril 2026).

### Gemini
- Implicite (2.5+) : jusqu'à −75% (⚠️ ~1h TTL).
- Explicite : `CachedContent` (TTL configurable ~20min→30j, stockage payant) — rarement utilisé par les agents.
- Seuil 4096 tokens.

## 3. Best practices client (consensus 2025-2026)

1. **Statique en tête, dynamique en fin** : 1 timestamp en tête = miss total ("bill 5x").
2. **Timestamps/IDs/sérialisation déterministes en suffixe**.
3. **Session affinity mono-région** (caches régionaux ; ne pas changer de région en session).
4. **Keepalive calé sur le TTL** : 4-5 min OpenAI glissant ; <5 min ou TTL 1h Anthropic. ⚠️ Les lectures ne prolongent PAS forcément le TTL ; coût write 1.25×.
5. **Seuil minimal** : rester ≥ 1024 (Anthropic/OpenAI) / ≥ 4096 (Gemini). Rentable dès ~2 réutilisations.
6. **Ne pas changer de modèle/version/effort en session** (modèle = clé de cache).
7. **Frozen system prompt** = consensus 2026 (yage.ai "Grok Bot Leak", Cloudflare Agents, self-evolving agents) : contenu stable en tête, volatil rejeté en fin/1er user.
8. **Sur-caching = taxe** ("The Overcaching Tax", getnadir) : cacher des tool results uniques = overhead write sans bénéfice.
9. **Agent loop caching** (towardsai, 2026) : la boucle intra-tour est LE levier central (breakpoint sur dernier user stable).

## 4. Keepalive — le papier dédié (arXiv 2607.19214, juil 2026)

"Keeping the Cache Warm Pays: Keepalive Economics"
- Cached input tokens ~10× moins chers + suppression de la plupart du préfill.
- Question centrale : **à quelle fréquence ping ?** — tradeoff entre coût des pings et bénéfice des hits.
- Modèle économique : keepalive rentable si `P(réutilisation dans la fenêtre) × bénéfice_hit > coût_des_pings`.
- Implémentation pratique : aider `--cache-keepalive-pings N` (ping toutes les 5 min).
- **Correspond exactement à notre H5.**

## 5. Implications pour un harness (pi)

1. Le cache OpenAI est **non-déterministe** même bit-identique → H6 (resume) : le hit n'est pas garanti à 100%, mais le bit-identique maximize la probabilité.
2. Le frozen system prompt est le consensus → notre H1 est la bonne direction ; la mesure montre le vrai gain quand le set d'outils change.
3. L'overcaching tax soutient l'esprit de H4 (même s'il est inapplicable sur nos providers implicites).
4. Le keepalive a une littérature dédiée (H5) — réévaluer avec les chiffres du papier.
5. La boucle d'outils est confirmée comme levier central (notre H2 = 91.9% hit mesuré).