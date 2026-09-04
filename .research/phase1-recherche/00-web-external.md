# Complément de recherche WEB EXTERNE (sources 2025-2026, vérifiées en ligne)

> **Source** : recherches web externes (minimax_web_search) effectuées par l'orchestrateur pendant la Phase 1.
> **Pourquoi** : les agents researcher n'avaient pas d'outil web et leurs connaissances s'arrêtent à ~2025-Q1.
> **Usage** : à intégrer dans Phases 2 (analyse), 4 (synthèse) et 5 (hypothèses) — sources RÉCENTES (2026).

---

## 1. Le caching comme contrainte de design (pas une optimisation optionnelle)

**Source** : yage.ai — "Prompt Caching as a First-Class Constraint in Harness Design" (avril 2026)
- Le prompt caching **façonne le design** des harness matures, ce n'est pas un coût optimisable en option.
- Les harness sérieux traitent le cache comme une **contrainte de première classe** : ordre du prompt, stabilité du préfixe, frozen system prompt.

## 2. Le "frozen system prompt" est devenu un standard (2026)

**Sources** : yage.ai ("Grok Bot Leak: Why an Agent's System Prompt Must Be Frozen", août 2026), Cloudflare Agents docs, self-evolving agent papers
- Un **system prompt figé** (frozen) est la recommandation dominante : contenu stable en tête, volatil (memory, timestamps) après.
- Cloudflare Agents : "frozen system prompt is not re-rendered" — le LLM voit les mises à jour au tour suivant (pattern Claude Code).
- "Up to 90% lower cost and 85% lower latency" (Willow Blog) pour stable prefixes reuse.
- Le system prompt NE DOIT PAS contenir de contenu dynamique (memory, session id, user info) — sinon invalidation.

## 3. "Don't Break the Cache" (arXiv 2601.06007) — confirmé et cité largement

**Sources** : arXiv abs/html v2, Semantic Scholar (11 citations), getnadir, tensormesh.ai, LinkedIn analyses
- Le papier évalue le prompt caching pour tâches agentiques longues (tool-calling).
- Finding clé : **"naive full-context caching can actually make agents slower"** (LinkedIn/Patel).
- Stratégie gagnante : contrôler les frontières de cache (pas tout cacher), exclure les tool results dynamiques.
- "The Overcaching Tax" (getnadir) : le sur-caching a un coût — cacher trop (tool results uniques) = overhead sans bénéfice.

## 4. Agent Loop Caching (towardsai, jan 2026)

**Source** : pub.towardsai.net — "Agent Loop Caching: The Missing Optimization for Agent Workflows"
- Le caching **dans les boucles d'agents** (intra-tour) est LA manque d'optimisation : quand un tour explose en N round-trips, chaque appel doit matcher le préfixe.
- Le breakpoint sur le dernier message user (stable pendant la boucle) est le levier central.

## 5. prompt_cache_key OpenAI : comportements INATTENDUS (2025-2026) — CRITIQUE pour H6/H9

**Sources** : community.openai.com (plusieurs threads)
- "Caching is borked for GPT-5 models" (sept 2025) : **cache hit rate 1/20**, prompt_cache_key **sans effet** — "It is merely an additional input to the hashing".
- "prompt_cache_key is NOT deterministic" : 2 prompts identiques à la suite → le 2e n'est PAS 100% caché, ça prend des secondes à minutes pour prendre effet.
- "cached_tokens=0 intermittently même avec préfixe statique identique" (juil 2026) — hits incohérents sur l'orchestrateur multi-agent.
- → **Le cache OpenAI n'est PAS garanti même avec préfixe identique** : le prompt_cache_key est un indice (locality), pas une garantie. C'est une limitation réelle documentée par les utilisateurs.
- Azure OpenAI : ajouter prompt_cache_key a fait passer les hit rates de 60% → 87% dans un déploiement de prod (avril 2026).

## 6. Nouveaux papiers et ressources

- **arXiv 2603.05344** : "Building AI Coding Agents for the Terminal" (mars 2026) — cache control headers pour optimiser le caching des longs system prompts.
- **OnlyTerp/prompt-cache-skills** (GitHub) : repo de "drop-in prompt-caching fixes" pour harness d'agents — patchs prêts à appliquer.
- **Tessl registry** (anthropics/claude-api skills) : "Keep stable content first (frozen system prompt, deterministic tool list)".
- **Cloudflare Agents** conversation state : conçu pour le prompt caching.

---

## Synthèse pour les phases suivantes

1. **Le frozen system prompt est le consensus 2026** — notre H1 est la bonne direction, mais la mesure montre que le vrai gain vient quand le set d'outils change (le system est régénéré).
2. **Le cache OpenAI est non-déterministe** — important pour H6 (resume) : même bit-identique, le hit n'est pas garanti à 100%.
3. **Le sur-caching a un coût** (overcaching tax) — soutient l'esprit de H4 même s'il est inapplicable sur nos providers.
4. **La boucle d'outils est le levier central** (agent loop caching) — notre mesure H2 (91.9% hit) le confirme.
5. Le caching est une **contrainte de première classe** dans les harness matures — pi devrait le traiter comme tel (docs, choix de design).
---

## 7. Complément 2 — Harnesses (sources GitHub/web vérifiées)

### Opencode
- **JackDrogon/opencode-context-cache** : plugin opencode pour prompt cache + sticky session (SHA256-based cache), efficace avec les gateways AIs.
- Issue **anomalyco/opencode#25974** (mai 2026) : proposition de *client-side* prompt cache (normalize prompts + cache responses avec TTL).
- **oh-my-openagent#1247** (jan 2026) : "Plugin architecture prevents Prompt Caching (0% hit)" — une architecture de plugins peut CASSER le caching (leçon : la composition de plugins peut invalider le préfixe).

### Aider
- Doc officielle **aider.chat/docs/usage/caching** : `--cache-keepalive-pings N` pour ping toutes les 5 minutes et garder le cache chaud.
- Issue **Aider-AI/aider#1152** (août 2024) : keep-alive automatique pour éviter le timeout 5 min.
- **arXiv 2607.19214** : "Keeping the Cache Warm Pays: Keepalive Economics for..." (juil 2026) — un papier dédié à l'ÉCONOMIE du keepalive (exactement H5) : cache read ~10x moins cher, keepalive rentable si la probabilité de réutilisation est suffisante.

### Goose
- **Ghenghis/Super-Goose** (fév 2026) : built on Block's Goose core (Rust), "Prompt Caching 80-90% input cost reduction" — optimise ses propres prompts overnight.
- Goose core : `cache_semantics.rs` (déjà documenté dans nos docs).

### Claude Code (source primaire)
- **code.claude.com/docs/en/prompt-caching** : "A change to the conversation layer leaves the system prompt and project context cached. A change to the system prompt invalidates everything."
- **claudecodecamp.com** (fév 2026) : la compaction réutilise le même system prompt → le parent compacté garde le préfixe (détail important !)
- **Anthropic platform docs** : "The system automatically applies the cache breakpoint to the last cacheable block and moves it forward as conversations grow" — CASUAL breakpoint automatique (nouveauté récente ?)

### Pi/OpenCode Go provider
- **OnlyTerp/prompt-cache-skills** : drop-in skills pour maximiser le cache hit sur **Pi's OpenCode Go provider** — directement notre contexte !

