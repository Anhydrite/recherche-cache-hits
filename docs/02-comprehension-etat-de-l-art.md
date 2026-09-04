# Compréhension détaillée du cache-hit + État de l'art

> **Suite du README-cache-hit-harnesses.md** — cette fois : (A) compréhension *fine* du fonctionnement, appuyée sur le code source réel de pi (`pi-mono` cloné en local), (B) état de l'art académique & industriel, (C) techniques d'optimisation applicables à un harness.

**Sources principales lues en entier :**
- `pi-mono` cloné (`/tmp/pi-mono`) : `packages/ai/src/api/{anthropic-messages,openai-completions,openai-responses,openai-prompt-cache}.ts`, `packages/ai/src/types.ts`, `packages/coding-agent/src/core/{agent-session,session-manager,system-prompt,compaction/compaction,messages,provider-composer}.ts`, `packages/agent/src/{agent,agent-loop}.ts`
- Papier **"Don't Break the Cache: An Evaluation of Prompt Caching for Long-Horizon Agentic Tasks"** (Lumer et al., PwC, arXiv:2601.06007) — PDF téléchargé et lu en entier (/tmp/dont-break-cache.txt)
- Recherches : LMCache, CacheBlend, Hydragen, Auditing Prompt Caching (Stanford, ICML 2025, arXiv:2502.07776), Deep Agents (LangChain), SGLang RadixAttention, vLLM APC

---

## Partie A — COMPRÉHENSION DÉTAILLÉE DU FONCTIONNEMENT

### A.1 La chaîne complète chez pi (de la session au wire request)

```
SessionManager (entries, leafId)
   └─ buildSessionContext()                [session-manager.ts:418] 
        ├─ buildSessionPath()              → chemin feuille→racine
        ├─ detecte le dernier CompactionEntry
        └─ buildContextEntries() → liste ordonnée:
              [compaction?] + [entrées depuis firstKeptEntryId] + [après compaction]
        └─ flatMap(sessionEntryToContextMessages) → AgentMessage[]
   └─ agent.state.messages = sessionContext.messages   [agent-session.ts:2033]

Agent.runPromptMessages(messages)                     [agent/agent.ts]
   └─ runAgentLoop → streamAssistantResponse            [agent/agent-loop.ts:274]
        ├─ transformContext? (AgentMessage[]→AgentMessage[])   [pi hook]
        ├─ convertToLlm(messages)  → Message[]           [core/messages.ts:148]
        ├─ Context = { systemPrompt, messages, tools }
        └─ streamFunction(model, context, { sessionId, cacheRetention, ... })
             └─ provider stream (anthropic/openai/...)  [packages/ai/src/api/*]
                  └─ applyCacheControl / prompt_cache_key → requête wire
```

**Point crucial : le `systemPrompt` est une chaîne construite une fois** par `buildSystemPrompt()` ([system-prompt.ts]) au démarrage/regénération de la session, et **réutilisée identique à chaque tour**. C'est le composant le plus stable du MDC (most dynamic content) et donc le cœur du cache.

### A.2 Le contenu exact du system prompt de pi (et sa stabilité)

Ordre des blocs dans `buildSystemPrompt()` :

1. "You are an expert coding assistant operating inside pi..."
2. `Available tools:` (une ligne par tool — snippet)
3. "In addition to the tools above..." (bloc fixe)
4. `Guidelines:` (bullets dynamiques selon les tools présents — **stables par session**)
5. Bloc "Pi documentation (read only when the user asks about pi itself...)" (fixe)
6. `appendSystemPrompt` (optionnel, fixe une fois appliqué)
7. `<project_context>` : fichiers de contexte projet (AGENTS.md, etc.) — **injectés une fois** à la construction
8. Skills (formatSkillsForPrompt)
9. `Current working directory: <cwd>` → **en position finale** (bon : le cwd est stable en pratique mais s'il change, seule la fin du prompt est touchée — la répartition du cache n'est pas cassée ; le cwd est par ailleurs l'élément le plus variable d'une machine à l'autre, cf. anti-article Dan MacKinlay sur les presets qui "break prompt caching across machines").

⚠️ **Points de vigilance identifiés dans le code pi (pour le cache) :**
- **Le cwd est dans le system prompt** (fin). Si l'utilisateur change de dossier milieu de session ou sur une autre machine avec le même session file → le préfixe change → miss. Les harnesses "recommandés" mettent le cwd dans le *premier message user* au lieu du system prompt (voir état de l'art, Manus/context engineering).
- **`<project_context>` (AGENTS.md) est dans le system prompt**, donc dans le préfixe caché. Si un fichier de contexte projet change **en cours de session**, pi doit régénérer le system prompt → **invalidation totale** du cache. Claude Code a exactement ce comportement documenté ("editing CLAUDE.md mid-session… changes don't apply until the next cycle" — ils *retardent* l'application pour préserver le cache). pi devrait faire pareil si ce n'est pas déjà le cas (vérifier).
- `promptGuidelines` / `appendSystemPrompt` : stables par session.
- **Pas de timestamp** dans le system prompt pi — excellent pour le cache (l'anti-article "bill 5x" cite le timestamp courant comme cause n°1 de miss).

### A.3 Convertir en messages (convertToLlm) — l'ordre de la conversation

`core/messages.ts:148` — produit `Message[]` dans l'ordre des `AgentMessage` de session : user → assistant → toolResult → user → ... **C'est l'ordre chronologique** (pas de réarrangement type aider). Les entrées `compaction`/`branch_summary` deviennent des messages `user`/`assistant` synthétiques (createCompactionSummaryMessage).

**Implication cache** : le contenu *exactement identique* d'un tour à l'autre = tous les messages sauf le dernier. Grâce au cache par préfixe, chaque nouveau tour ne recalcule que le delta. Mais chaque **nouvelle entrée de session** (tool result) allonge la queue — c'est le comportement attendu et correct pour un cache par préfixe (le préfixe stable = tout sauf la queue).

### A.4 Où le cache est activé côté provider (le cœur)

**Anthropic (`api/anthropic-messages.ts`) :**

```ts
function getCacheControl(model, cacheRetention?, env?): { retention, cacheControl? } {
  const retention = resolveCacheRetention(cacheRetention, env); // "short"|"long"|"none" (PI_CACHE_RETENTION)
  if (retention === "none") return { retention };
  const ttl = retention === "long" && compat.supportsLongCacheRetention ? "1h" : undefined;
  return { retention, cacheControl: { type: "ephemeral", ...(ttl && { ttl }) } };
}
```

Placements (par ordre dans la requête) :
1. **system prompt** : `params.system = [{ type:"text", text: systemPrompt, cache_control }]`
2. **dernier tool definition** : `tools[tools.length-1].cache_control = {type:"ephemeral"}`
3. **dernier message** (à la toute fin de convertMessages) : le dernier bloc (text|image|tool_result) du dernier message user reçoit `cache_control`.

C'est le **pattern universel 3-breakpoints** : `[system] | [tools...] | [conversation...|dernier user]`. Anthropic n'accepte que ≤ 4 breakpoints, les 3 placements en utilisent 3.

> Détail important : le **3e breakpoint sur le dernier message user** est ce qui rend les boucles d'outils efficaces (cf. opencode `cache-policy.ts` : "the latest user message stays put while a single turn explodes into many assistant/tool round-trips"). Sans lui, chaque appel intra-tour re-billerait toute la conversation.

**Fallback OAuth Claude Code** (token `sk-ant-oat`) : pi envoie 2 blocs system (`"You are Claude Code..."` + le vrai system prompt), tous deux marqués. Le nommage exact des outils suit la version Claude Code courante (`claudeCodeVersion = "2.1.251"`, source cchistory.mariozechner.at) — nécessaire car le préfixe system doit matcher ce qu'attend la plage serving de Claude.

**OpenAI (`api/openai-completions.ts` / `openai-responses.ts`) :**

```ts
params = {
  model, messages, stream: true,
  prompt_cache_key: cacheRetention !== "none" ? clampOpenAIPromptCacheKey(sessionId) : undefined,
  prompt_cache_retention: cacheRetention === "long" && supportsLongCacheRetention ? "24h" : undefined,
  prompt_cache_options: (retention==="none" && supportsExplicitPromptCacheMode) ? { mode: "explicit" } : undefined,
  store: false,
}
```

- `prompt_cache_key` clampé à 64 chars (`openai-prompt-cache.ts`) : le sessionId (uuidv7) est tronqué. C'est la **clé de stabilité cross-requêtes** : sans elle, OpenAI utilise le préfixe seul ; avec, on fige la topologie de cache.
- `prompt_cache_retention: "24h"` quand `PI_CACHE_RETENTION=long`.
- OpenAI = **caching implicite** par préfixe. Le client ne pose pas de breakpoint : il garantit juste un préfixe stable + la clé de session.
- `store: false` évite les frais de stockage serveur (indépendant du cache).

**OpenAI-compatible / OpenRouter (completions)** : flag `cacheControlFormat: "anthropic"` → pi applique `applyAnthropicCacheControl(messages, tools, cacheControl)` qui marque system + dernier tool + dernier message (le même pattern, sur des messages chat-style).

**Bedrock** : `cachePoint: { type: "default" }` + `AWS_BEDROCK_FORCE_CACHE=1` pour les profils d'inférence applicatifs.

**Session-affinity headers** (stabilité de routing de cache) :
- Anthropic : `x-session-affinity: <sessionId>` (si compat).
- OpenAI responses/completions : `session_id`, `x-client-request-id`, `x-session-affinity` ; OpenRouter : `x-session-id`.
- GitHub Copilot : headers dynamiques.

### A.5 sessionId — sa vie et sa rotation (impact cache)

- `createSessionId() = uuidv7()` ([session-manager.ts:208]).
- Généré au démarrage, **stable pendant toute la session**, enregistré dans le header du fichier `.jsonl`.
- **Rotation** : à chaque `newSession`/`newBranch` (nouvelles branches du `/tree` etc.) → sessionId changé → `prompt_cache_key`/session-affinity changé → **la topologie de cache change** (mais pas le contenu du préfixe, donc le cache implicite OpenAI peut toujours matcher si le contenu du préfixe est identique).
- **Compaction/branch-summary utilisent des sessionId de routage frais et désactivent l'écriture de cache** (`docs/compaction.md`) : ces prompts one-shot ne seront jamais relus, écrire un cache coûte sans bénéfice.

### A.6 Compaction & branches — protéger la stabilité du préfixe

`core/session-manager.ts:418` `buildContextEntries()` :
- Le dernier `CompactionEntry` remplace tout ce qui est avant lui (sauf `firstKeptEntryId..compaction` et après compaction).
- La vue LLM devient : `system | [summary] | [messages depuis firstKeptEntryId]`.
- Le summary est donc dans le **préfixe stable** (juste après system) — il reste caché tant qu'il ne change pas.
- **En revanche, la compaction elle-même change le préfixe** (elle supprime des messages) → le tour suivant la compaction est un **cache miss total** (Claude Code le documente : "/compact force rebuild"). C'est le coût caché de la compaction. pi le sait (docs) mais le tradeoff est : perdre du cache vs garder le contexte sous la limite.

**Ce que pi fait déjà bien (vs anti-patterns du papier) :**
- Pas de timestamp dynamique dans le system prompt ✔
- Cwd à la fin du system prompt ✔ (plutôt qu'au début)
- La compaction met le summary en tête (préfixe court = moins de relecture) ✔
- Session-id stable pour le routage OpenAI ✔

---

## Partie B — ÉTAT DE L'ART

### B.1 Le papier central : "Don't Break the Cache" (arXiv:2601.06007, PwC, 2026)

**Protocole** : 500+ sessions agentiques (DeepResearch Bench, agents web-search multi-tour), 4 modèles (GPT-5.2, GPT-4o, Claude Sonnet 4.5, Gemini 2.5 Pro), system prompt de 10 000 tokens. 4 conditions de cache :
- **No Cache** : UUID au début du system prompt (simule timestamps/user info dynamiques) → ce qu'un mauvais harness produit naturellement.
- **Full Context** : cache total automatique (naïf).
- **System Prompt Only** : UUID à la fin du system prompt → seul le system est caché.
- **Exclude Tool Results** : UUID après system ET après chaque tool result.

**Résultats chiffrés (Table 1 & 2)** :

| Modèle | Meilleure stratégie | Coût ↓ | TTFT ↓ |
|---|---|---|---|
| GPT-5.2 | Exclude Tool Results (best) | 79.6 % (79-81) | 13.0 % (9.5-13) |
| Claude Sonnet 4.5 | System Prompt | 78.5 % (77.8-78.5) | 22.9 % (20.9-22.9) |
| Gemini 2.5 Pro | System Prompt | 41.4 % (27.8-41.4) | 6.1 % (-2.9 à 6.1) |
| GPT-4o | System Prompt | 45.9 % (45.9-47.8) | **30.9 %** (Full Context : **-8.8 %** régression !) |

**Trois findings clefs :**
1. **Le contrôle stratégique des frontières de cache bat le cache naïf full-context.** Le full-context cache des tool results dynamiques → overhead de *cache write* sans lecture bénéfique → parfois **régression en latence** (GPT-4o : -8.8 %).
2. **Cacher uniquement le system prompt = gains de coût presque identiques (dans 2-4 points) et gains de latence plus constants.** Le system prompt pilotant la majorité du coût, c'est LE levier.
3. **Ne JAMAIS mettre de dynamique (timestamp, UUID, session id, user info) dans le system prompt.** Si nécessaire : à la FIN du system prompt (le suffixe dynamique est le seul recalculé).

**Ablations** :
- Coût ∝ taille du prompt : 10-45 % à 500 tokens → 54-89 % à 50 000 (linéaire, universellement positif). **Le préfixe cachable (essentiellement system prompt) est le facteur dominant.**
- Nombre de tool calls : le coût reste stable (77-81 % GPT-5.2) — ne pas optimiser autour du nombre d'outils.
- En-dessous du seuil (500 tokens < les seuils 1024 / 1024 / 4096 OpenAI/Anthropic/Google) : **TTFT régression 10-18 %** (le cache ne s'active pas, variance serveur). Il faut dépasser les seuils minimaux.
- **Tool calls dynamiques** (MCP, tool discovery) : tout changement de l'ensemble d'outils **invalide le préfixe** → stratégie : garder un set fixe de fonctions généralistes, implémenter la dynamique par code généré plutôt que par function calling.
- **Summarizing/pruning d'anciens tool calls** casse les représentations cachées → contre-productif si on cherche le cache tool calls ; le pattern émergent = system stable + tool calls traités comme contenu dynamique.

### B.2 Le serveur d'inférence (la couche en-dessous)

Le cache API n'est qu'un produit **au-dessus** des techniques de réutilisation KV cache côté serveur :
- **PagedAttention** (vLLM, arXiv:2309.06180) : mémoire paginée → évite fragmentation, permet le partage.
- **RadixAttention** (SGLang, arXiv:2312.07104, LMSYS) : arbre radix des préfixes partagés, réutilisation automatique du KV cache, "token drift" évité. C'est le mécanisme qui rend possible le cache par préfixe exact.
- **Automatic Prefix Caching (vLLM APC)** : KV cache par blocs hachés, lookup à la volée.
- **Hydragen** (arXiv:2402.05099) : attention décomposée sur les préfixes partagés dans un batch → jusqu'à 32× throughput sur les workloads à préfixes partagés (batching de plusieurs requêtes partageant le même préfixe).
- **LMCache** (github.com/lmcache/lmcache, arXiv:2510.09665) : couche de gestion KV cache reutilisable (DRAM/disk), cross-engine (vLLM/SGLang), **CacheBlend** intégré.
- **CacheBlend** (Tensormesh, arXiv:2405.16444) : **reuse du KV cache AU-DELÀ du préfixe** (non-prefix reuse) en fusionnant des segments chevauchants + re-calcul sélectif → 63-85 % cache hit vs 3-25 % avec du préfixe seul ; 25× le hit-rate sur agentic/RAG. C'est la prochaine frontière : le cache par préfixe "tue les tokenomics" des agents ; le non-prefix le répare.

→ **Leçon pour un harness** : le cache API est *exact-prefix* ; le cache infra (si agent tourne sur son propre serving) peut être *radix/non-prefix*. Les contraintes côté harness diffèrent : côté API on contrôle l'ordre/la stabilité ; côté serving on contrôle la réutilisation KV.

### B.3 Frameworks d'agents (langchain Deep Agents, ADK, smolagents, autogen)

- **Deep Agents (LangChain)** : prompt caching intégré "no extra config" across providers → jusqu'à 80 % de réduction. (blog.langchain.com/deep-agents-prompt-caching)
- **ADK (Google)** : contexte explicite + caching implicite côté Gemini.
- La philosophie générale : le framework doit **piloter les breakpoints** (ou la stabilité) pour toi, avec des défauts "auto" qui suivent le pattern `[system][tools][dernier user]`.

### B.4 Sécurité & vie privée (le revers du cache)

- **Timing side-channels** : Stanford (Gu et al., ICML 2025, arXiv:2502.07776) — audité 17 providers ; un attaquant peut **détecter des préfixes cachés** (temps de réponse), donc inférer du contenu. 8/17 providers vulnérables notables. Implications pour harness : le cache = une fuite potentielle de données (ne pas cacher de secrets, comprendre le modèle de menace).
- **Key collision attack on semantic caching** (OpenReview) : collision sur les clés de cache sémantique.
- **Data residency** : le cache vit côté provider (Anthropic infini, Bedrock/Vertex chez le client cloud, gateways…) → conformité (médium article "Hidden Data Residency Problem").

### B.5 Manus / context engineering (l'école "prompt engineering du cache")

"Context Engineering for AI Agents: Lessons from Building Manus" (Ji, manus.im, 2025) :
- **Traiter le system prompt comme une base stable** ; tout ce qui est session-specific dans le corps des messages.
- Les dynamiques (timestamp, user info) en **queue du system prompt** ou dans le premier message user.
- Limiter le "function calling dynamique" (MCP tool discovery) qui invalide le préfixe.
- **Summarization/pruning** : à utiliser avec parcimonie car ils cassent le cache des tool calls.

---

## Partie C — TECHNIQUES D'OPTIMISATION DU CACHE POUR UN HARNESS (synthèse actionnable)

### C.1 L'ordre du prompt — la décision n°1 (tous)

```
[SYSTEM PROMPT (stable)]  →  [tools defs (stables)]  →  [conversation historique]
      →  [tool results (dynamiques)]  →  [dernier message user (le plus changeant)]
```
- Tout ce qui est *stable par session* en tête ; tout ce qui *change à chaque tour* en queue.
- **Breakpoints là où ça compte** : fin du system, dernier tool, dernier message user (ce dernier = le levier des boucles d'outils).
- Mode/plan/skills = **messages de conversation** (append en queue), PAS d'édition du system prompt (Claude Code le documente ; pi fait de même ?).

### C.2 Contre les invalidations involontaires

- ❌ timestamp/datetime/UUID/session-id dans le system prompt → si nécessaire, tout en fin.
- ❌ changer l'ensemble d'outils (MCP) en milieu de session → tool defs dynamiques = miss. Préférer des outils fixes + code généré.
- ⚠️ changer `cwd` / `<project_context>` (AGENTS.md) en cours de session → régénère le system prompt → **retarder l'application** (pattern Claude Code "s'applique au prochain cycle").
- ⚠️ compaction / branch switching → le tour suivant = miss total ; minimiser la fréquence, utiliser compact-context progressif quand possible.

### C.3 Maximiser le surcoût amorti (l'économie)

- **Seuil minimal** par provider : 1024 tokens (OpenAI/Anthropic), 4096 (Gemini). En-dessous, le cache ne s'active pas et peut même régresser en TTFT. → Si le system prompt d'un harness fait ~1-2k, on est juste au bord ; viser ≥ 2k pour être sûr.
- **TTL** : 5 min (Anthropic short) → 1h (long) ; 24h (OpenAI long). `PI_CACHE_RETENTION=long` = lever le bon levier quand les sessions ont des pauses.
- **Cache-warming / keepalive** (aider) : pings silencieux périodiques pour garder la fenêtre de 5 min vivante. Économique seulement si ces pings sont petits et le TTL sinon expiré.
- **Le breakpoint system** paie le plus (le system domine le coût) ; les breakpoints message/tool paient marginalement si la conversation est plus petite que le system.

### C.4 La clé de stabilité (OpenAI)

- `prompt_cache_key` stable (dérivé du sessionId) + headers `session_id`/`x-session-affinity` → fixe la topologie de cache cross-requêtes. Vérifier que le sessionId ne bouge pas sur resume/fork/compaction si on veut des hits cross-fichiers.

### C.5 Mesure & diagnostic (pour boucler la boucle)

- Exposer `cacheRead`/`cacheWrite`/`cache_hit_rate` par tour (pi : footer `R/W/CH`, `computeCacheWaste` en $).
- Détecter les misses **explicables** (idle > TTL, modèle changé, contenu volatile) — pi le fait via `CacheMiss{idleMs, modelChanged}`.
- `showCacheMissNotices` : visiblement documenté pour debug.

### C.6 Ce que pi pourrait améliorer (liste priorisée)

1. **⚠️ DÉCOUVERTE — pi régénère le system prompt en cours de session (invalidation cachée)** : `_rebuildSystemPrompt()` est appelé à :
   - ligne 983 : à chaque **changement de l'ensemble d'outils** (loop sur les tools, `validToolNames` reconstruit) — ex. tools activés/désactivés en milieu de session, cf. contexte ligne 975-983 : `this.agent.state.tools = tools; this._baseSystemPrompt = this._rebuildSystemPrompt(validToolNames);`
   - ligne 2491 : à chaque **extension de ressources** (skills/prompts/themes chargés dynamiquement) — `this._resourceLoader.extendResources(...); this._baseSystemPrompt = this._rebuildSystemPrompt(...)`
   - Il prend aussi `getAgentsFiles()` (AGENTS.md / contexte projet) à chaque rebuild.
   → **Tout rebuild change le texte du system prompt → invalidation TOTALE du cache API** (le préfixe entier change). Ce n'est pas documenté comme coût ; c'est le point n°1 à surveiller : ces rebuilds ne devraient se faire qu'au démarrage de session (ou retardés, pattern Claude Code).

2. **cwd dans le system prompt** : le mettre plutôt en fin (déjà fait) et documenter que changer de cwd = miss ; si pi supporte le multi-repo par session, considérer le premier message user.
3. **MCP/tool discovery** : si les outils pi changent selon les MCP connectés (que nous n'avons pas vu de connexion MCP par défaut), prévoir un ordre stable des tools + set fixe.
4. **Compaction** : le summary est déjà en tête ; vérifier qu'on ne régénère pas le summary à chaque tour (il ne devrait que changer à la compaction). Pour les très longues sessions, envisager un compact-context progressif (garder les N derniers tool results, résumer le reste) plutôt que des /compact fréquents.
5. **Cache warming optionnel** : reprendre le pattern aider (pings silencieux) derrière un flag, utile pour les utilisateurs à longues sessions avec pauses.
6. **Exposer la stratégie par provider** (comme goose `CacheSemantics`) : une table (provider, modèle) → explicite/implicite/non-caché, pour décider si on pose des breakpoints ou pas.
7. **Seuils minimaux** : s'assurer que le system prompt dépasse confortablement 1024 tokens par défaut (pi y est probablement, ~1-2k, mais le vérifier).

---

## Partie D — RÉFÉRENCES COMPLÈTES

### Papiers académiques
| Sujet | Réf |
|---|---|
| **Don't Break the Cache** (évaluation 3 providers, 4 stratégies, seuils, TTL) | Lumer et al., arXiv:2601.06007 (2026) |
| **Auditing Prompt Caching in LM APIs** (timing side-channels, 17 providers) | Gu et al., ICML 2025, arXiv:2502.07776 |
| **CacheBlend** (non-prefix KV reuse) | Yao et al., arXiv:2405.16444 (2024) |
| **LMCache** (couche KV cache reutilisable) | Liu et al., arXiv:2510.09665 (2025) |
| **Hydragen** (attention préfixes partagés, 32×) | Juravsky et al., arXiv:2402.05099 (2024) |
| **SGLang / RadixAttention** | Zheng et al., arXiv:2312.07104 (2023) |
| **PagedAttention (vLLM)** | Kwon et al., arXiv:2309.06180 (2023) |
| **ChunkAttention / prefix-aware KV** | (réf open review, 2023) |

### Blogs en anglais (sources primaires)
- "How Claude Code uses prompt caching" — code.claude.com/docs/en/prompt-caching
- "Lessons from Building Claude Code: Prompt caching is everything" — Thariq (Anthropic / trq212)
- "Context Engineering for AI Agents: Lessons from Building Manus" — Ji, manus.im/blog (2025)
- "How Prompt Caching Actually Works in Claude Code" — claudecodecamp.com
- "An Evaluation of Prompt Caching..." (résumé) — alphaxiv.org/abs/2601.06007
- "Prompt Caching in Production AI Systems: Architecture, Economics, Governance" — medium (adnanmasood)
- "How CacheBlend Improved Tokenomics by 25x" / "Non-Prefix Caching" — bisok.com, tensormesh.ai

### Sources issues du code (clonées)
- pi-mono : packages/ai/src/api/{anthropic-messages,openai-completions,openai-responses,openai-prompt-cache}.ts ; core/{session-manager,system-prompt,agent-session,compaction}.ts ; agent/{agent,agent-loop}.ts
- opencode : packages/llm/src/cache-policy.ts (+tests), packages/opencode/src/provider/transform.ts
- aider : aider/coders/chat_chunks.py (warm_cache, AIDER_CACHE_KEEPALIVE_DELAY)
- goose : crates/goose-provider-types/src/cache_semantics.rs
- cline : sdk/packages/llms/src/providers/routing/*

### Docs officielles provider
- Anthropic : platform.claude.com/docs/en/build-with-claude/prompt-caching (breakpoints ≤4, TTL 5m/1h, read 0.1×, write 1.25×)
- OpenAI : developers.openai.com/api/docs/guides/prompt-caching (implicite, 1024 min, retention 24h, 30-min lifetime refreshed on reuse)
- Google Gemini : ai.google.dev/gemini-api/docs/caching (implicite 2.5+, 4096 min, explicite CachedContent)

### Métriques de référence retenues
- Coût gagné : **41-80 %** (4 modèles, 500+ sessions, papiers). System-only ≈ full-context en coût (Δ 2-4 pts), meilleur en latence.
- TTFT : **13-31 %** d'amélioration ; full-context parfois **régression** (GPT-4o : -8.8 %).
- Seuils min : 1024 / 1024 / 4096 (OpenAI / Anthropic / Google).
- TTL : 5 min (short) → 1h / 24h (long).
- Non-prefix caching (CacheBlend) : hit-rate 63-85 % vs 3-25 % prefix-only ; ×25.