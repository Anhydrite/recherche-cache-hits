# Rapport Phase 1 — 03 : Littérature académique & technique

> **Rédigé par** : orchestrateur (docs projet + recherche web externe 00-web-external.md, liens vérifiés en ligne)
> **Date** : 2026-09-04

## 1. "Don't Break the Cache: An Evaluation of Prompt Caching for Long-Horizon Agentic Tasks"

**Référence** : Lumer et al. (PwC), arXiv:2601.06007 (jan 2026) — 11 citations, 55 références.

**Protocole** : 500+ sessions agentiques (DeepResearch Bench, web-search multi-tour), 4 modèles (GPT-5.2, GPT-4o, Claude Sonnet 4.5, Gemini 2.5 Pro), system prompt 10k tokens, 4 conditions :
- **No Cache** : UUID au début (simule timestamps/user info dynamiques)
- **Full Context** : cache total naïf
- **System Prompt Only** : UUID à la fin → seul le system est caché
- **Exclude Tool Results** : UUID après system ET après chaque tool result

**Résultats chiffrés** :

| Modèle | Meilleure stratégie | Coût ↓ | TTFT ↓ |
|---|---|---|---|
| GPT-5.2 | Exclude Tool Results | 79.6% (79-81) | 13.0% (9.5-13) |
| Claude Sonnet 4.5 | System Prompt | 78.5% (77.8-78.5) | 22.9% (20.9-22.9) |
| Gemini 2.5 Pro | System Prompt | 41.4% (27.8-41.4) | 6.1% (-2.9 à 6.1) |
| GPT-4o | System Prompt | 45.9% | **30.9%** (Full Context : **-8.8% régression**) |

**3 findings clefs** :
1. Le contrôle stratégique des frontières de cache **bat le cache naïf full-context** (le full-context cache des tool results dynamiques → overhead write sans lecture → parfois **régression latence**).
2. **Cacher uniquement le system = gains de coût quasi identiques** (Δ 2-4 pts) + latence plus constante → LE levier.
3. **NE JAMAIS mettre de dynamique dans le system prompt** ; si nécessaire, à la FIN.

**Ablations** :
- Coût ∝ taille du prompt : 10-45% (500 tok) → 54-89% (50k).
- Nombre de tool calls : coût stable (77-81% GPT-5.2) — pas optimiser autour.
- Sous le seuil (500 tok < 1024/1024/4096) : **TTFT régression 10-18%** (cache ne s'active pas).
- **Tool calls dynamiques (MCP)** : tout changement du set d'outils invalide le préfixe → garder un set fixe.
- Summarizing/pruning d'anciens tool calls casse les représentations cachées.

## 2. "Keeping the Cache Warm Pays: Keepalive Economics" (arXiv 2607.19214, juil 2026)

- Le cache read est ~10× moins cher et supprime la plupart du préfill.
- **ÉCONOMIE du keepalive** : à quelle fréquence pinger pour garder le TTL 5 min vivant ?
- Modèle : keepalive rentable si `P(réutilisation) × bénéfice > coût des pings`.
- Implémentation : aider `--cache-keepalive-pings N`.

## 3. "Auditing Prompt Caching in LM APIs" (Stanford, ICML 2025, arXiv 2502.07776)

- **Timing side-channels** : audité 17 providers ; un attaquant peut détecter des préfixes cachés par le temps de réponse → inférer du contenu.
- 8/17 providers vulnérables notables.
- **Implication sécurité** : le cache = fuite potentielle (ne pas cacher de secrets).

## 4. "Building AI Coding Agents for the Terminal" (arXiv 2603.05344, mars 2026)

- Cache control headers pour optimiser le caching des **longs system prompts**.
- Source récente sur l'ingénierie des agents de codage.

## 5. "Prompt Caching as a First-Class Constraint in Harness Design" (yage.ai, avril 2026)

- Le caching n'est pas une optimisation optionnelle : il **façonne le design** des harness matures.
- Le préfixe stable est traité comme contrainte de première classe (ordre, stabilité, frozen system prompt).

## 6. "Grok Bot Leak: Why an Agent's System Prompt Must Be Frozen" (yage.ai, août 2026)

- Le system prompt NE DOIT PAS contenir de contenu dynamique (memory, user info) — sinon invalidation.
- Le **frozen system prompt** est devenu le standard 2026 (Cloudflare Agents : "frozen system prompt is not re-rendered").

## 7. "Agent Loop Caching: The Missing Optimization" (towardsai, jan 2026)

- Le caching **intra-boucle** d'agents (un tour → N round-trips) est LA manque d'optimisation.
- Le breakpoint sur le dernier message user (stable pendant la boucle) est le levier central.
- → Confirme notre H2 (91.9% hit mesuré).

## 8. "The Overcaching Tax" (getnadir.com, 2026)

- Le **sur-caching** a un coût : cacher des tool results uniques = overhead write sans bénéfice.
- → Soutient l'esprit de H4 (exclure les tool results) même s'il est inapplicable sur nos providers implicites.

## 9. Autres références

- **Deep Agents (LangChain)** : prompt caching intégré "no extra config" → jusqu'à 80% réduction.
- **Cloudflare Agents** conversation state : conçu POUR le prompt caching (frozen system prompt non re-rendu).
- **Willow Blog** : "Up to 90% lower cost and 85% lower latency" pour stable prefixes reuse.
- **mager.co** (avril 2026) : explainer pratique de ce qui casse le cache.
- **claudecodecamp.com** (fév 2026) : la compaction réutilise le même system prompt → le parent compacté garde le préfixe.
- **Medium (michael.hannecke)** : "static content first, dynamic content last ; cacheable: tool/function defs".

## 10. Consensus & controverses (2026)

**Consensus** :
1. Frozen system prompt (contenu stable en tête, volatil en fin).
2. Le system prompt est LE levier de coût (il domine le préfixe).
3. Modèle + effort stables = clé de cache.
4. Seuils minimaux à respecter (1024/1024/4096).
5. Keepalive rentable si reprise probable (papier dédié 2026).

**Controverses / nuances** :
1. **OpenAI non-déterministe** : le cache n'est pas garanti même bit-identique (community reports 2025-2026) → mesurer, pas présumer.
2. **Compaction** : Claude Code dit "/compact = rebuild", mais claudecodecamp dit que le parent compacté garde le préfixe (dépend de l'implémentation).
3. **Full vs exclude tool results** : le meilleur choix dépend du modèle (GPT-5.2 → exclude ; Sonnet → system-only).
4. **Sécurité** : le caching = timing side-channel (Stanford) — tradeoff coût/vie privée.