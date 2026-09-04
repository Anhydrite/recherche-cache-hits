# Phase 2 — 02 : Gouvernance du cache dans pi (analyse du code)

> **Rédigé par** : sous-agent analyste pi (analyse du code dist bundlé + rapports phase 1)
> **Méthode** : lecture du bundle `@earendil-works/pi-coding-agent/dist/bundle/chunks/` (chunk-E5KXRMZK.js, anthropic-messages-JWX2WP65.js, openai-completions-JD4WAC3R.js, openai-responses-BSOJMSEV.js, chunk-GMWCTUPB.js, chunk-PRRNXB7S.js, pi-messages-TPFH44NP.js), docs officielles (docs/*.md), CHANGELOG, et rapport `01-harnesses.md` (phase 1).

---

## 0. Modèle mental : le cache = f(clé de préfixe)

Tous les mécanismes de prompt caching provider reposent sur le **KV-cache par préfixe exact** : un octet qui change dans le préfixe invalide tout ce qui le suit. La « gouvernance » d'un harness se réduit donc à 4 questions :

1. **Quoi** : qu'est-ce qui compose le préfixe (system + tools + messages) ?
2. **Ordre** : comment est ordonné le contenu (stabilité décroissante) ?
3. **Stabilité** : qu'est-ce qui peut changer en session (et invalide) ?
4. **Clé/locality** : comment le provider est aidé à retrouver le bon bloc (breakpoints, prompt_cache_key, session-affinity) ?

Ce rapport décline ces 4 questions pour pi, avec références de code vérifiées dans le bundle, puis compare avec les autres harnesses (01-harnesses.md) et propose une gouvernance idéale.

---

## 1. Décisions de design de pi qui impactent le cache

### 1.1 L'assemblage du system prompt : `buildSystemPrompt()` (chunk-E5KXRMZK.js)

pi construit son system prompt à partir de `_rebuildSystemPrompt(toolNames)` qui assemble `_baseSystemPromptOptions = {cwd, skills, contextFiles, customPrompt, appendSystemPrompt, selectedTools, toolSnippets, promptGuidelines}` puis appelle `buildSystemPrompt(options)`.

**Ordre de composition du system prompt (réf. code exact, chunk-E5KXRMZK.js) :**

```
1. "You are an expert coding assistant... pi, a coding agent harness."     (intro fixe)
2. "Available tools:" + liste `- <name>: <snippet>` (toolSnippets)         (dépend du set d'outils)
3. "In addition to the tools above, you may have access to other custom tools..." (fixe)
4. "Guidelines:" + guidelines                                              (dépendent des outils !)
5. Bloc "Pi documentation" (README.md, docs/...)                           (fixe)
6. [appendSection — si un system prompt additionnel est configuré]
7. [<project_context> — instructions projet/issues si contextFiles]         (variable par projet)
8. [Skills formatés si tool "read" actif]
9. "Current working directory: <cwd>"                                     (LE PLUS VOLATILE, EN FIN ✓)
```

**Points de gouvernance décisifs :**

| Décision | Impact cache | Verdict |
|---|---|---|
| **cwd en dernière ligne du system prompt** | Le seul élément volatile (changement de repo, déplacement) est en fin de system → au pire un miss partiel court (~100 tokens), jamais un miss total | ✅ Bonne décision (confirmée expérimentalement : H3 phase 1, « réfutée comme optimisation » car l'impact est minime) |
| **Tool snippets & guidelines dépendent du set d'outils et sont intégrés DANS le system prompt (positions 2 & 4)** | Tout changement du set d'outils actifs → rebuild du system → **miss total** (c'est notre H1 : « rebuild quand le set d'outils change → miss total ») | ⚠️ C'est LA fuite principale (voir §2.2) |
| **`Current working directory` en fin de system** | démontre une conscience du cache dans pi (le volatile en queue) | ✅ |
| **Absence de date/timestamp dans le system** | CHANGELOG : « Fixed system prompt cache invalidation across dates by removing the current date from the default prompt (#6621) » — c'était une fuite, corrigée | ✅ |
| **System prompt OAuth Claude Code** : pi envoie 2 blocs system : « You are Claude Code... » (fixe) + systemPrompt avec cache_control chacun | 2 breakpoints sur system (dont un bloc immuable) | ✅ pour le mode OAuth /claude-code |

### 1.2 Les breakpoints `cache_control` : `getCacheControl()` + `convertMessages()` (anthropic-messages-JWX2WP65.js)

```js
function getCacheControl(model,cacheRetention,env){
  let retention=resolveCacheRetention(cacheRetention,env);        // PI_CACHE_RETENTION=long → "long"
  if(retention==="none") return {retention};
  let ttl=retention==="long"&&getAnthropicCompat(model).supportsLongCacheRetention ? "1h" : void 0;
  return {retention, cacheControl:{type:"ephemeral", ...ttl&&{ttl}}}
}
```

Placement des 3 breakpoints (≤ 4 max côté Anthropic) :
1. **System** : `params.system=[{type:"text",text:systemPrompt,...cacheControl}]` (buildParams)
2. **Dernier tool** : `convertTools(..., cacheControl)` → `cacheControl && index===tools.length-1 ? {cache_control:cacheControl} : {}` si `supportsCacheControlOnTools`
3. **Dernier message user/assistant/tool** : à la fin de `convertMessages` → breakpoint sur le **dernier bloc text/image/tool_result du dernier message user** (et pi avance à travers les tool results : `lastBlock.type==="text"||"image"||"tool_result"`).

En boucle d'outils, le dernier message user reste stable → la boucle intra-tour matche le préfixe (H2 = 91.9% hit mesuré). ⚠️ Attention : le breakpoint n'est pas posé si le dernier message est `assistant` avec des tool_use (le contenu assistant n'a pas de bloc text) — dans ce cas le breakpoint « conversation » est absent (pi ne le pose que sur un message se terminant par text/image/tool_result). C'est assumé et correct : le breakpoint sur tool_result est le dernier du préfixe stable.

**Design important : `retention: "none"` désactive tout** (pas de breakpoint, pas de prompt_cache_key, pas de headers d'affinité). `PI_CACHE_RETENTION=long` → TTL "1h" Anthropic / "24h" OpenAI (avec `supportsLongCacheRetention`).

### 1.3 La clé de cache OpenAI : `prompt_cache_key` + session-affinity (openai-completions-JD4WAC3R.js)

```js
params={
  ...
  prompt_cache_key:
    (model.baseUrl.includes("api.openai.com") && cacheRetention!=="none") ||
    (cacheRetention==="long" && compat.supportsLongCacheRetention)
      ? clampOpenAIPromptCacheKey(options?.sessionId) : void 0,
  prompt_cache_retention: cacheRetention==="long" && compat.supportsLongCacheRetention ? "24h" : void 0,
  ...
}
```

- `clampOpenAIPromptCacheKey(key)` (chunk-PRRNXB7S.js) : limite à **64 chars** (limite provider) ; sessionId (uuidv7) < 64 donc inchangé.
- **sessionId = clé stable par session** : `createSessionId() = uuidv7()` ; sur resume, pi lit l'id depuis le header de session (`sessionId=header?.id??createSessionId()`), donc la clé est bit-identique d'un resume à l'autre (H6).
- `--no-session --session-id` : mode éphémère mais clé déterministe (CHANGELOG #6070).
- **Headers de session-affinity** (createClient, openai-completions) :
  - `compat.sessionAffinityFormat==="openrouter"` → `x-session-id`
  - `"openai"` → `session_id`, `x-client-request-id`, `x-session-affinity`
  - `"openai-nosession"` → pas de `session_id` (Codex proxy, #6645)
- `sendSessionAffinityHeaders` : default `false` en openai-completions (détecté par provider), `true` pour openai-responses/Cloudflare par défaut (détecté en openai-responses via `compat.sessionAffinityFormat`).
- Anthropic côté headers : `x-session-affinity: sessionId` quand `compat.sendSessionAffinityHeaders` (activé pour Cloudflare AI Gateway, Bedrock via catalog : `sendSessionAffinityHeaders:!0` dans le catalog Cloudflare).
- **OpenRouter** : `cacheControlFormat: "anthropic"` **uniquement** pour `model.id.startsWith("anthropic/")` (detectCompat, openai-completions) — sinon pas de breakpoints. Cf. CHANGELOG #6941 : breakpoints qui avancent à travers les tool results pour `anthropic/*-latest`.

### 1.4 Compaction : `_checkCompaction` / `_runAutoCompaction` / `prepareCompaction` (chunk-E5KXRMZK.js)

- Déclencheurs : `contextOverflow` (stopReason length) ou `shouldCompact(contextTokens, contextWindow, settings)` quand `contextTokens > contextWindow - reserveTokens` (default `reserveTokens:16384`, `keepRecentTokens:20000`).
- `prepareCompaction` : trouve un cut point, résume `messagesToSummarize` (+ `turnPrefixMessages` si tour coupé), conserve `firstKeptEntryId`.
- **Impact cache** : la compaction remplace tout l'historique par un summary → le préfixe « messages » change entièrement → **miss total inévitable** (le summary est du nouveau contenu). Pi le sait et l'isole : `scan()` (statistiques de cache) remet `prev=void 0` sur les entrées `compaction`/`branch_summary` pour ne pas compter ces misses comme des fuites.
- Design : persistance de `previousSummary` dans les entrées de session → l'histo compacté reste stable entre compactions ; `keepRecentTokens` préserve la fin de conversation (le préfixe récent) → après compaction, le prefix system+tools+summary est nouveau MAIS le suffixe récent est conservé → le **breakpoint system reste utile** en post-compaction.

### 1.5 Statistiques et observabilité : footer R/W/CH + `computeCacheWaste` + `showCacheMissNotices`

- Footer (README) : `R` cache read, `W` cache write, **`CH` = latest prompt cache hit rate** (ajout #1083).
- `/session` : hit rate `cacheRead/promptTokens`, `Uncached`, et `computeCacheWaste(entries, models)` avec `detectMiss` :
  ```js
  function detectMiss(prev,message,models){
    let missedTokens=Math.min(prev.promptTokens,promptTokens)-usage.cacheRead;
    if(missedTokens<=1024) return;                       // seuil de rentabilité
    return {missedTokens, missedCost: missedTokens*Math.max(0, paidPerToken-readPerToken),
            idleMs: message.timestamp-prev.timestamp, modelChanged: ...}
  }
  ```
  → **Waste en $, tokens relus, temps d'idle, et détection de changement de modèle** : c'est exactement la télémétrie dont un « responsable du cache » a besoin.
- `showCacheMissNotices` (settings, default false) : notices de miss significatifs dans le transcript (settings.md).
- Télémétrie OTLP : attributs `pi.ai.usage.cache_read_tokens`, `cache_write_tokens` (chunk-E5KXRMZK.js, schema telemetry).

### 1.6 Mode pi-messages (proxy Radius) : `resolveCacheRetention` (pi-messages-TPFH44NP.js)

Le payload passe `cacheRetention` + `sessionId` au proxy → la décision de cache est déléguée au backend (le proxy peut choisir sa stratégie). Design gouvernance : **pi ne décide pas, il transmet**.

---

## 2. Fuites potentielles (invalidation du préfixe)

### 2.1 F1 — Rebuild du system prompt à chaque changement d'outils actifs

```js
setActiveToolsByName(toolNames){
  ...
  this.agent.state.tools=tools,
  this._baseSystemPrompt=this._rebuildSystemPrompt(validToolNames),   // ← REBUILD
  this.agent.state.systemPrompt=this._systemPromptOverride??this._baseSystemPrompt
}
```

- `toolSnippets[name]` et `promptGuidelines` sont **injectés dans le system prompt** (positions 2 & 4 de buildSystemPrompt). Tout outil ajouté/retiré → texte différent → **miss total système** (H1).
- **Même un outil ajouté SANS snippet ni guidelines change la liste** « Available tools » → miss total. La seule voie cache-friendly est le **deferred tool loading** (voir §3.1).
- Guidelines dérivées des outils : `hasBash||hasPowerShell → "Use bash ... for file operations"` — dépend de la présence d'outils, donc volatile par construction : le choix « guidelines dans le system » est la racine de F1.
- Atténuations existantes : (a) deferred loading natif (Anthropic `defer_loading` / OpenAI `tool_search`), (b) `splitDeferredTools` déplace les tools jamais utilisés en `deferred` → le set immediate reste stable, (c) doc : « Pi detects purely additive changes... applies the updated active set before the next model request » — mais **les tools ajoutés avec promptSnippet/promptGuidelines reconstruisent le system prompt** (documenté dans extensions.md : "activating a tool with promptSnippet or promptGuidelines rebuilds the system prompt").

### 2.2 F2 — Changement de cwd / projet en session

`_rebuildSystemPrompt` capture `cwd: this._cwd` ; `buildSystemPrompt` termine par `Current working directory: ${promptCwd}`. Si pi navigue dans un autre repo en session (ou si cwd change), la dernière ligne du system change → miss partiel court (le reste du system et l'historique sont préservés). **Impact faible par design** (cwd en fin), mesuré dans H3 (miss partiel ~100 tokens, réfuté comme optimisation). F2 est donc « contenu » mais pas critique. Attention toutefois : les changements de cwd côté projet changent aussi `contextFiles` (project_context) → miss plus large.

### 2.3 F3 — Changement de modèle / provider / thinking en session

- `asPreviousRequest` enregistre `modelKey = provider/model`; `detectMiss` remonte `modelChanged` → pi sait mesurer le coût exact d'un switch de modèle.
- Chat completions OpenAI : le cache est **par modèle** (le préfixe tokenisé dépend du tokenizer) ; changer de modèle = miss total (littérature : « Model + effort = clé de cache », 01-harnesses.md §Claude Code).
- Thinking : `params.thinking`/`reasoning_effort` sont dans la requête mais ne font pas partie du préfixe de messages côté Anthropic (les thinking blocks sont dans les messages assistant, donc dans le préfixe) — un changement de niveau thinking en session peut altérer la sérialisation des tours précédents.

### 2.4 F4 — Injections volatiles dans les messages (extensions, temps réel)

- `before_request` / `before_payload` / `transform_context` hooks (HOOK_NAMES dans chunk-E5KXRMZK.js) : une extension qui injecte un timestamp/ID dans le premier user message, ou dans le system via `systemPromptOverride`, invalide tout. Le payload est modifiable par `onPayload` (`nextParams=await options?.onPayload?.(params,model)`) — aucune protection contre les extensions qui cassent le préfixe.
- `_expandSkillCommand` : `/skill:` injecte le contenu du skill dans le message user courant → **premier message de la session** → si le skill est utilisé en premier message, le préfixe des tours suivants inclut le skill (stable après) — acceptable ; si le skill change, miss « conversation entière »? Non : le skill n'est pas ré-injecté aux tours suivants (il est dans le user message 1). OK.

### 2.5 F5 — Retry (préfixe différent) et messages intercalés

- `_handlePostAgentRun` → `retryProviderRequest` : les retries ré-envoient le même payload (même préfixe) → pas de fuite sauf si le retry inclut de nouveaux messages (compaction de retry `_runAutoCompaction("overflow", willRetry)`).
- Erreur/abort : le message assistant partiel n'est pas persisté → pas de fuite.

### 2.6 F6 — OpenAI non-déterministe (externe)

Voir 01-harnesses/02-cache-infra : le cache OpenAI n'est **pas** garanti bit-identique (community reports 2025-2026, prompt_cache_key = indice de localité). pi ne peut rien y faire sinon maximiser la stabilité (H6) — c'est un risque résiduel **externe**, à suivre dans la gouvernance (à surveiller via les métriques CH/waste).

### 2.7 F7 — Changement de version de pi / bundle

Le system prompt pi contient des références aux docs (README.md, docs/) qui changent entre versions ; une mise à jour de pi → nouveau system prompt → miss du premier tour de la session suivante. Impact unique et négligeable.

---

## 3. Ce que pi fait déjà bien vs les autres harnesses (base : 01-harnesses.md)

### Force 1 — « Statique en tête, volatile en fin » : cwd en queue de system (unique à pi)
Contrairement à la synthèse de phase 1 (« ordonner par stabilité décroissante »), pi met la seule donnée volatile du system (cwd) **en toute fin de system prompt**, après le project_context et les skills. Claude Code met le project context en couche séparée (équivalent) mais pi le fait dans le system en le faisant suivre de la ligne cwd. Résultat : changement de repo = miss ~100 tokens (mesuré H3), là où un system avec cwd en tête coûterait tout le préfixe system.

### Force 2 — Clé de cache stable : sessionId uuid persisté + prompt_cache_key 64-chars + session-affinity multi-formats
- Codex CLI « sessions persistées = affinité » est le seul concurrent au même niveau ; pi fait pareil (header de session avec id persisté, `--no-session --session-id` pour mode éphémère) + `prompt_cache_key` clampé à 64 (limite OpenAI, #4720) + 3 formats de session-affinity (openai / openrouter / openai-nosession + codex websocket) + `x-session-affinity` Anthropic quand supporté.
- goose a une table (provider, modèle) → sémantique ; pi fait de même via `compat.*` (detectCompat + catalog).

### Force 3 — Breakpoints aux 3 frontières + contournement du plafond de 4 blocs
pi pose exactement les 3 breakpoints recommandés (system, dernier tool, dernier user). Le breakpoint tool avance avec les tool results (n'écrase pas le dernier message) — c'est le pattern opencode `latest-user-message` équivalent. Et pour les models qui supportent `eager_input_streaming`/`defer_loading`, pi réduit le set immédiat → préfixe plus stable que cline (qui marque des content blocks) sans le coût du fallback opencode.

### Force 4 — Mesure et monétisation des misses
`computeCacheWaste` (tokens + $ + idleMs + modelChanged + seuil 1024) est le seul indicateur économique de la comparaison ; les autres harnesses mesurent au mieux le hit rate. aider a `warm_cache` pings (absent chez pi — voir opportunité), opencode a une CachePolicy configurable (pi fixe la politique par provider, pas par session — voir opportunité).

### Force 5 — Désactivation propre : `PI_CACHE_RETENTION=none` coupe tout
`retention:"none"` → ni breakpoint (Anthropic), ni prompt_cache_key/prompt_cache_retention (OpenAI), ni session-affinity headers, ni `prompt_cache_options:{mode:"explicit"}` (OpenAI Responses). C'est le « uncached » de goose `CacheSemantics` en plus simple.

### Force 6 — Compaction consciente du cache
Les entrées compaction brisent la chaîne de mesure (pas de faux miss), `keepRecentTokens` préserve un suffixe utile, et le breakpoint system reste rentable après compaction. Claude Code fait pareil implicitement (3 couches) ; opencode supprime les tool outputs anciens (pi ne le fait pas — voir opportunité).

### Faiblesses / retards
1. **Pas de keepalive** (aider `--cache-keepalive-pings`, papier arXiv 2607.19214) : pi ne ping pas — pour des sessions interactives à pauses > 5 min, le TTL expire → miss total au retour. À évaluer (H5 phase 1).
2. **Pas de suppression ciblée des tool outputs périmés** avant compaction (opencode le fait ; pi compacte en masse).
3. **Tool loading interactif** : le fallback non-additive (remplacement d'un set d'outils) régénère le system prompt → miss total (F1) ; opencode + goose ont des stratégies de sérialisation différentes mais toutes subissent le même problème quand le system est dérivé des tools — pi est documenté, c'est déjà ça.
4. **Politique de cache configurable par session** : opencode propose CachePolicy (tools/system/messages); pi est binaire (short/long/none). Pour un « responsable du cache », le levier « per-session » manque (ex. désactiver le breakpoint tool dans les sessions à outils uniques).

---

## 4. Gouvernance idéale du cache pour pi (proposition)

### 4.1 Principes de gouvernance (règles à écrire dans la doc projet)

1. **Toute modification d'un composant du préfixe doit être quantifiée avant d'être livrée** : system prompt (y compris guidelines dérivées des tools), ordre des messages, sérialisation, clé de cache, navigation cwd/contextFiles.
2. **Ne jamais injecter de volatil dans le préfixe** : timestamps, IDs, compteurs, contenu temps réel → fin de system (comme cwd) ou premier message user, jamais en tête de system.
3. **La stabilité prime sur la fraîcheur** dans le system : un contextFile qui change en session doit être traité comme le cwd (fin de system), pas réordonnancé en tête.
4. **Changement de modèle/thinking = événement gouverné** : coûte le préfixe entier → le déclencher est une décision (mesurer idleMs + missedCost via computeCacheWaste).
5. **Le cache est un contrat entre pi, l'extension et le provider** : les extensions qui touchent system/messages (before_request, systemPromptOverride, onPayload) sont des surfaces de gouvernance à encadrer (lint « préfixe-stable »).

### 4.2 Ce qu'un responsable du cache devrait surveiller (métriques pi existantes)

| Métrique | Source pi | Seuil d'alerte suggéré |
|---|---|---|
| Hit rate (CH, footer, /session) | `cacheRead/promptTokens` | < 85% en boucle d'outils = régression à investiguer |
| Coût gaspillé ($) | `computeCacheWaste` (missedCost) | pic > budget (fixer un budget par session) |
| Miss > 1024 tokens | `detectMiss` (seuil) + `showCacheMissNotices` | tout miss > seuil après le 1er tour |
| Change de modèle en session | `detectMiss.modelChanged` | tout switch = miss total annoncé |
| Idle entre requêtes | `idleMs` | > TTL (5 min default / 1h long) → candidat keepalive |
| Compactions | événements `compaction_start/end` | fréquence élevée = problème de fenêtre |
| Télémétrie OTLP | `pi.ai.usage.cache_read/write_tokens` | agrégation multi-sessions |

### 4.3 Décisions à trancher (recommandations)

1. **Guidelines dérivées des tools (F1)** : déplacer les guidelines dépendantes des outils **hors du system prompt** (dans le premier message user, ou dans les tool descriptions) pour découpler le system du set d'outils actifs. C'est le chantier le plus rentable : il transforme le miss total H1 en miss partiel.
2. **Keepalive (H5)** : ajouter un ping optionnel calé sur le TTL (5 min) similaire à aider `warm_cache`, activable via `PI_CACHE_KEEPALIVE` — rentable si P(reprise dans la fenêtre) × économie > coût des pings (arXiv 2607.19214).
3. **Stabilisation du set d'outils** : documenter/vérifier que les outils indépendants (sans snippet/guidelines) puissent être « deferred » par défaut (splitDeferredTools déjà en place pour anthropic/openai-responses) ; encourager les extensions à donner des `description` riches sans `promptSnippet`/`promptGuidelines` (déjà documenté dans extensions.md §Dynamic Tool Loading).
4. **Verrouiller la clé de cache par session** : garantir que sessionId ne change qu'avec `/new` (jamais en cours de session, même après une navigation dans le tree — vérifier l'usage de `sessionId` dans les branches).
5. **Politique par session** : exposer `cacheRetention` en option de run (comme opencode CachePolicy) plutôt que seulement global `PI_CACHE_RETENTION`.
6. **Guardrails extension** : dans la doc extensions, encadrer `before_payload`/`onPayload`/`systemPromptOverride` pour empêcher l'injection de volatil dans le préfixe (lint « prefix-stable » + notice si le system prompt est override).

### 4.4 Ordre de priorité

1. **F1 / guidelines hors system** (gros gain mesurable H1, low risk) — décision de design.
2. **Keepalive** (gain certain en sessions longues/pause, medium risk, littérature solide).
3. **Verrouillage sessionId/tree** (évite les misses « fantômes ») — audit rapide.
4. **Politique par session** (alignement opencode) — UX provider-agnostique.
5. **Guardrails extension** (prévention de régression) — doc + éventuel warning runtime.

---

## 5. Références de code (fichiers vérifiés)

| Composant | Fichier (bundle chunks/) | Symboles |
|---|---|---|
| System prompt | chunk-E5KXRMZK.js | `buildSystemPrompt`, `_rebuildSystemPrompt`, `_baseSystemPromptOptions`, `_expandSkillCommand` |
| Breakpoints Anthropic | anthropic-messages-JWX2WP65.js | `getCacheControl`, `resolveCacheRetention`, `buildParams` (system+tools), `convertMessages` (dernier message), `convertTools` (`index===tools.length-1`) |
| Compat Anthropic | anthropic-messages-JWX2WP65.js | `getAnthropicCompat` (`supportsLongCacheRetention`, `sendSessionAffinityHeaders`, `supportsCacheControlOnTools`, `supportsEagerToolInputStreaming`) ; `createClient` (`x-session-affinity`) |
| Clé OpenAI | openai-completions-JD4WAC3R.js ; chunk-PRRNXB7S.js | `clampOpenAIPromptCacheKey` (64 chars), `prompt_cache_key`, `prompt_cache_retention:"24h"`, `createClient` (session affinity formats), `detectCompat` (`cacheControlFormat` openrouter anthropic/*) |
| OpenAI Responses | openai-responses-BSOJMSEV.js | `prompt_cache_options:{mode:"explicit"}`, `detectSessionAffinityFormat`, `getPromptCacheRetention` |
| Stats/cache waste | chunk-E5KXRMZK.js | `detectMiss` (seuil 1024), `computeCacheWaste`, `scan`, `asPreviousRequest`, `/session`, footer `CH` |
| Compaction | chunk-E5KXRMZK.js | `_checkCompaction`, `_runAutoCompaction`, `prepareCompaction`, `shouldCompact`, `DEFAULT_COMPACTION_SETTINGS={enabled:true,reserveTokens:16384,keepRecentTokens:20000}` |
| Tool deferred | chunk-GMWCTUPB.js ; docs/extensions.md §Dynamic Tool Loading | `splitDeferredTools` (immediate/deferred), `defer_loading`, `tool_search` |
| Session | chunk-E5KXRMZK.js | `createSessionId()` (uuidv7), `assertValidSessionId`, resume `sessionId=header?.id` |
| Proxy pi-messages | pi-messages-TPFH44NP.js | `resolveCacheRetention`, payload `cacheRetention`+`sessionId` transmis |
| Doc/leviers | docs/settings.md, docs/models.md, docs/extensions.md, README.md, CHANGELOG.md | `PI_CACHE_RETENTION=long`, `showCacheMissNotices`, `compat.supportsLongCacheRetention`, `cacheControlFormat`, `sessionAffinityFormat`, #6621 (date), #4720 (64 chars), #6941 (openrouter breakpoints), #1083 (CH footer) |

---

## 6. Synthèse exécutive

- pi a une **architecture de cache déjà mature** : system prompt figé avec volatile en queue (cwd), breakpoints aux 3 frontières, clé de cache déterministe par session (uuid persisté + prompt_cache_key clampé + session-affinity multi-provider), mesure économique des misses (`computeCacheWaste`), désactivation propre (`PI_CACHE_RETENTION=none`), compaction consciente, et deferred tool loading pour préserver le préfixe.
- La **fuite structurelle principale est F1** : le system prompt intègre les snippets + guidelines des outils → tout changement de set d'outils régénère le system (miss total, notre H1). La gouvernance idéale commence par découpler guidelines/outils du system.
- La fuite secondaire est **F3 (changement de modèle/thinking)** : pi la mesure déjà (modelChanged) mais ne la prévient pas.
- **Points d'amélioration vs état de l'art** : keepalive (aider, arXiv 2607.19214), politique de cache par session (opencode CachePolicy), suppression ciblée de tool outputs périmés (opencode), guardrails extension sur le préfixe.