# Rapport Phase 1 — 01 : Harnesses & prompt caching

> **Rédigé par** : orchestrateur (à partir des docs 02-05 du projet + recherche web externe 00-web-external.md)
> **Date** : 2026-09-04

## 1. Vue d'ensemble

8 harnesses étudiés : pi (sujet principal), opencode, aider, cline, goose, Claude Code (réf.), Codex CLI, Gemini CLI. Tous reposent sur le même mécanisme serveur : **KV-cache par préfixe exact**. Un changement d'UN octet dans le préfixe invalide tout ce qui suit. Deux familles d'implémentation :
- **Breakpoints explicites** (`cache_control: {type:"ephemeral"}`, Anthropic) : le client marque jusqu'à 4 blocs (system, dernier tool, dernier message).
- **Caching implicite** (OpenAI, Gemini) : pas de marqueur, le provider matche automatiquement le plus long préfixe commun. La clé est le préfixe (+ `prompt_cache_key` chez OpenAI).

## 2. Par harness

### pi (sujet — déjà documenté en détail dans docs/02, docs/05)
- `getCacheControl()` : `PI_CACHE_RETENTION=long` → ttl "1h" (Anthropic), "24h" (OpenAI).
- 3 breakpoints `cache_control` : system, dernier tool (`index===tools.length-1`), dernier message user.
- `prompt_cache_key = clampOpenAIPromptCacheKey(sessionId)` (64 chars, OpenAI).
- Headers de session-affinity : `x-session-affinity`, `session_id`, `x-session-id` (OpenRouter).
- `cacheControlFormat: "anthropic"` seulement pour OpenRouter+anthropic/*.
- **Mesures expérimentales (nos travaux)** : H2 = hit 91.9% en boucle d'outils ; H3 = cwd en fin de system (miss partiel ~100 tokens au changement de repo, réfutée comme optimisation) ; H6 = resume bit-identique (hit conservé) ; H1 = rebuild quand le set d'outils change → miss total (system régénéré car guidelines dépendent des tools).

### opencode (sst/opencode)
- `packages/llm/src/cache-policy.ts` : CachePolicy AUTO = `{tools:true, system:true, messages:"latest-user-message"}` ; NONE = `{}`.
- **Pourquoi "latest-user-message"** : dans une boucle d'outils, le dernier message user reste en place → chaque appel intra-tour matche le préfixe.
- Jusqu'à 4 breakpoints par requête (constante), `RESPECTS_INLINE_HINTS` (seuls anthropic-messages et bedrock les respectent).
- `provider/transform.ts` : providerOptions (anthropic/openrouter/bedrock/openaiCompatible/copilot/alibaba).
- Compaction : supprime les tool outputs anciens → préfixe plus léger.
- Écosystème 2026 : plugins opencode-context-cache (SHA256 sticky session), issue client-side cache (#25974).

### aider (Aider-AI/aider)
- `aider/coders/chat_chunks.py` : **l'ordre des chunks est pensé pour le cache** : system → examples → readonly_files → repo-map → done (historique) → chat_files → cur (courant) → reminder.
- `add_cache_control_headers()` : breakpoints à la fin des chunks de tête (exemples, read-only+repo, chat_files).
- `base_coder.py` : `warm_cache(chunks)` — **pings silencieux** (`AIDER_CACHE_KEEPALIVE_DELAY`) pour garder le TTL 5 min vivant ; `--cache-keepalive-pings N` documenté.
- Repo-map : cache disque des tags (diskcache, CACHE_VERSION), pas de reparse.
- Issue #1152 : keep-alive automatique.

### cline (cline/cline)
- `sdk/packages/llms/src/providers/routing/anthropic-compatible.ts` : `cache_control: {type:"ephemeral"}` au niveau **part de contenu** (pas message) pour préserver le breakpoint.
- routing provider-options testés (anthropic/openrouter/openaiCompatible/copilot/alibaba).
- Feature flag remote : `promptCachingEnabled` (telemetry).
- Discussion #9892 : enable prompt caching claude.

### goose (block/goose)
- `crates/goose-provider-types/src/cache_semantics.rs` : **CacheSemantics** = ExplicitBreakpoints | ImplicitTolerant | ImplicitStrict | Uncached. Table (provider, modèle) → sémantique.
- `apply_chat_payload_breakpoints` : ancre **par position de bloc** (pas par rôle — piegerait les 2 breakpoints messages sur le dernier user) ; breakpoint secondaire à ~LOOKBACK_BLOCKS=20.
- Tests `prefix_invariance.rs` : vérifient que le placement des cache_control ne modifie pas le préfixe.
- `has_cacheable_content` : refuse de marquer texte vide / thinking blocks / content:null.
- Super-Goose (fork, fév 2026) : "80-90% input cost reduction" via prompt caching.

### Claude Code (référence propriétaire)
- 3 couches ordonnées : **System prompt** (Instructions, tools) → **Project context** (CLAUDE.md, auto-memory) → **Conversation** (messages, tool results).
- "A change to the conversation layer leaves the system prompt and project context cached. **A change to the system prompt invalidates everything.**"
- Anti-invalidation délibérée : editer CLAUDE.md en session = différé au prochain cycle (préserve le cache).
- Modes/skills = messages de conversation (append), pas d'édition du system prompt.
- **Modèle + effort = clé de cache** : changer l'un en mid-session = rebuild.
- Gateway fallback : si 400 sur cache_control → re-envoi sans marker, marker sur dernier message.
- Nouveauté Anthropic : breakpoint automatique "applied to the last cacheable block and moves it forward".

### Codex CLI (openai/codex)
- Caching implicite + `prompt_cache_key`. Issue #35300 : stabilité de tokens requise.
- Sessions persistées localement, session_id = affinité de cache.
- 30-min lifetime OpenAI : "refreshes whenever the prefix is reused".

### Gemini CLI
- Implicit caching activé par défaut (2.5+), réduction latence ~30%.
- Explicit = API `cachedContents` séparée (rarement utilisée par les agents).
- Compact context local = préfixe réduit.

## 3. Synthèse — techniques communes

1. **Ordonner par stabilité décroissante** (system → contexte → historique → dernier message).
2. **Breakpoints aux 3 frontières** : fin system, dernier tool, dernier message user (le plus rentable en boucle).
3. **Ne rien injecter de volatile dans le préfixe** (timestamp = miss total).
4. **Modèle + effort stables** en session.
5. **TTL long** quand dispo (PI_CACHE_RETENTION=long).
6. **Keepalive** (aider, papier arXiv 2607.19214) : rentable si P(reprise) suffisant.
7. **Stabiliser la clé** : prompt_cache_key + session-affinity.
8. **Réduire le préfixe** : compaction, suppression tool outputs périmés.
9. **Compaction coûteuse** (invalide) → compact-context progressif.
10. **Mesurer les misses** (pi : footer R/W/CH + computeCacheWaste).

## 4. Innovations originales par harness

| Harness | Innovation |
|---|---|
| aider | Ordre des chunks explicite + repo-map cache disque + warm_cache pings |
| goose | Sémantique (provider, modèle) déclarée + ancrage par position de bloc |
| opencode | CachePolicy configurable + latest-user-message documenté |
| Claude Code | 3 couches + anti-invalidation délibérée + gateway fallback |
| pi | prompt_cache_key stable + session-affinity headers + stats R/W/CH + computeCacheWaste $ |
| Codex | sessions persistées = affinité de cache |

## 5. Leçons pour maximiser le cache hit (synthèse finale)

Le pattern gagnant (confirmé par la littérature + nos mesures) :
**system prompt figé + tout le dynamique en queue + breakpoints aux 3 frontières + modèle/effort stables + TTL long + keepalive si pauses prévisibles.**