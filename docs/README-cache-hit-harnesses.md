# Cache hit dans les harness d'agents de code : tour d'horizon

> **Objectif** : recenser les harness d'agents de codage open source et documenter précisément les mesures qu'ils prennent pour maximiser le taux de cache hit (prompt caching) côté API.

**Date** : 2026-07 (recherche faite sur doc officielle + code source cloné).

**Harnesses étudiés en profondeur (code source cloné)**
- **pi** (earendil-works) — est le sujet principal, doc + `dist/` du package npm
- **opencode** (sst/opencode) — cloné : `packages/llm`, `packages/opencode`
- **aider** (Aider-AI/aider) — cloné : `aider/coders/chat_chunks.py`, `base_coder.py`, `repomap.py`
- **cline** (cline/cline) — cloné : `sdk/packages/llms`, `sdk/packages/shared`
- **goose** (block/goose) — cloné : `crates/goose-provider-types/src/cache_semantics.rs`
- **Claude Code (référence propriétaire)** — doc officielle `code.claude.com/docs/en/prompt-caching`
- **Codex CLI (openai/codex)** — recherches web + issues
- **Gemini CLI (google-gemini/gemini-cli)** — recherches web + issues

---

## 0. Rappel : comment marche le prompt caching (le mécanisme partagé)

Tous les harnesses reposent sur le même mécanisme serveur :

1. Le provider calcule des **KV-cache** (key/value tensors) pour le *préfixe* d'une requête.
2. Une requête suivante qui partage le **même préfixe exact** (mêmes octets) réutilise ce travail : les tokens re-lus sont facturés au tarif `cache read` (souvent 10–25 % du prix normal).
3. **La correspondance est exacte et par préfixe** : un changement *n'importe où* dans le préfixe invalide tout ce qui le suit. "Il n'y a pas de cache par fichier ou par segment" (doc Claude Code).
4. Deux familles d'implémentation :
   - **Breakpoints explicites** (`cache_control: {type: "ephemeral"}`, Anthropic) : le client *marque* jusqu'à 4 blocs (système, dernier tool, dernier message). Le provider ne peut cacher *que* un préfixe se terminant à un breakpoint marqué.
   - **Caching implicite** (OpenAI, Gemini) : pas de marqueur, le provider cherche le plus long préfixe commun automatiquement. La clé de cache est le préfixe lui-même (plus, chez OpenAI récent, un `prompt_cache_key` de session).

**Conséquence design n°1 pour tous les harnesses** : l'ordre du prompt est la décision n°1. Contenu stable en tête (system prompt → contexte projet → conversation), contenu qui change à chaque tour en queue (derniers messages/tool results).

**Conséquence design n°2** : tout ce qui change au milieu du préfixe = cache miss. Les "ennemis" : timestamp injecté dans le system prompt, ordre de liste de tags de fichiers, session id aléatoire, l'horodatage dans un message.

**Conséquence design n°3** : il faut un *renouvellement* régulier du cache (TTL : 5 min Anthropic par défaut, 1h avec TTL long, 24h OpenAI/Gemini optionnel). Les harnesses ont donc des mécanismes de **cache-warming / keepalive** (aider : pings silencieux ; opencode : TTL optionnel ; pi : `PI_CACHE_RETENTION=long`).

---

## 1. pi (earendil-works/pi-coding-agent)

> Sujet central de la demande. Sources : README.md, docs/providers.md, docs/models.md, docs/compaction.md, docs/session-format.md, code bundle `dist/` (provider streams anthropic/openai), `dist/core/cache-stats.d.ts`.

### 1.1 Positionnement des cache points (dialecte Anthropic)

Extrait du stream `anthropic-messages` (bundle `anthropic-messages-JWX2WP65.js`) :

```js
function getCacheControl(model, cacheRetention, env) {
  let retention = resolveCacheRetention(cacheRetention, env); // PI_CACHE_RETENTION=long → "long"
  if (retention === "none") return { retention };
  let ttl = retention === "long" && model.compat.supportsLongCacheRetention ? "1h" : undefined;
  return { retention, cacheControl: { type: "ephemeral", ...(ttl && { ttl }) } };
}
```

**Pi marque (cache_control) :**
- le **system prompt** (`params.system[0]` en mode Claude Code OAuth ; sinon le system prompt comme bloc texte) ;
- le **dernier tool definition** (`...cacheControl && index === tools.length - 1 ? { cache_control: cacheControl } : {}`) ;
- le **dernier message** (dernier bloc texte/image/tool_result du dernier message user : `convertMessages` → `lastMessage.content[lastMessage.content.length-1].cache_control = cacheControl`).

C'est le pattern de base retenu partout (voir opencode §2, aider §3, goose §5).

Détails notables du code pi :
- `supportsCacheControlOnTools` : compat flag par modèle (défaut `true`) — certains providers rejettent `cache_control` sur les tools.
- `supportsLongCacheRetention` : si provider accepte le TTL long (`cache_control.ttl: "1h"` pour Anthropic ; `prompt_cache_retention: "24h"` pour OpenAI).
- `cacheControlFormat: "anthropic"` : pour les providers "OpenAI-compatible" qui exposent le cache à la Anthropic (markers sur text content et tool definitions) — ex. OpenRouter pour les modèles `anthropic/*`.
- Le **cap 4 breakpoints** (limite Anthropic) : `ccCount <= 4 ? { cache_control: {...} } : {}` (visible dans le code console d'opencode, structure identique côté pi).
- Fallback OAuth "Claude Code" : en mode token `sk-ant-oat`, pi émet 2 blocs système : "You are Claude Code, Anthropic's official CLI for Claude." + system prompt, marqués tous deux.

### 1.2 Dialecte OpenAI (Responses / Completions)

Extrait du stream `openai-responses` :

```js
params = {
  model, input: messages, stream: true,
  prompt_cache_key: cacheRetention === "none" ? undefined : clampOpenAIPromptCacheKey(options.sessionId),
  prompt_cache_retention: cacheRetention === "long" && compat.supportsLongCacheRetention ? "24h" : undefined,
  prompt_cache_options: cacheRetention === "none" && compat.supportsExplicitPromptCacheMode ? { mode: "explicit" } : undefined,
  store: false,
}
```

→ **Clé de cache = `prompt_cache_key` dérivé du sessionId** (stabilité cross-requêtes), TTL 24h optionnel (`PI_CACHE_RETENTION=long`), et mode "explicit" pour désactiver le cache imprudent si demandé.

### 1.3 Session affinity (headers)

Pi envoie des **headers de session** pour renforcer la stabilité de la route de cache chez les providers qui l'acceptent :

```js
// openai-responses : createClient(...)
headers.session_id = sessionId;            // format "openai"
headers["x-client-request-id"] = sessionId;
// format "openrouter" : headers["x-session-id"] = sessionId

// openai-completions (en plus) :
if (compat.sendSessionAffinityHeaders) headers["x-session-affinity"] = sessionId;
```

- `sessionAffinityFormat` : `"openai"` | `"openai-nosession"` | `"openrouter"` (auto-détecté sauf override `compat`).
- Pour **Anthropic** : header `x-session-affinity: <sessionId>` envoyé quand `sendSessionAffinityHeaders` est vrai.
- **Bedrock** : cache points via `cachePoint: { type: "default" }` + `AWS_BEDROCK_FORCE_CACHE=1` pour les profils d'inférence applicatifs (IDs non reconnaissables).
- **GitHub Copilot** : headers dynamiques `buildCopilotDynamicHeaders` — Copilot route le cache avec ses propres en-têtes de session.

### 1.4 TTL et rétention

- Variable d'env **`PI_CACHE_RETENTION`** : `long` → cache étendu (Anthropic 1h, OpenAI 24h). Valeurs : `short` (défaut) | `long` | `none`.
- `cache-stats.d.ts` : **`CACHE_TTL_MS`** — TTL de référence pour détecter les misses "attendus" (5 min Anthropic). Servi par `computeCacheWaste(entries, models)` : cumul des tokens de prompt qui *étaient* dans le prompt du tour précédent mais ont été refacturés en input normal → estimation du **gaspillage $**.
- Footer TUI : `↑ input ↓ output R cache read W cache write CH latest cache hit rate` + `showCacheMissNotices` (settings) pour logs de misses significatifs.

### 1.5 Ordre du prompt, compaction et stabilité de préfixe

`docs/session-format.md` (+ `compaction.md`) :

- **Compaction** : quand `contextTokens > contextWindow - reserveTokens` (réserve 16 384), pi garde `keepRecentTokens` (20k) en queue, résume le reste via un appel LLM structuré (même format que branch summary), écrit un `CompactionEntry`. Le LLM voit : `system | summary | messages depuis firstKeptEntryId`.
- Le résumé de compaction est **inséré au début de la conversation** (juste après system) → il est **dans le préfixe stable**.
- Les **compactions et branch-summary utilisent des sessionId de routage frais et désactivent l'écriture de cache** (ces prompts one-shot ne seront pas relus).
- `retainedTail` sur les entrées de compaction récentes : rejouer/rebuild context sans re-rendre tous les anciens messages.

### 1.6 Évaluation du cache dans le TUI

- Footer totals : `R` cache read, `W` cache write, `CH` latest cache hit rate (pourcentage du dernier tour), `cost`, `context usage`.
- `CacheMiss { missedTokens, missedCost, idleMs, modelChanged }` : pi **explique le miss** = soit TTL expiré (idle > 5 min), soit changement de modèle, soit contenu quasi-stable perturbé.

### 1.7 Ce que pi ne fait pas (ou de façon spécifique)

- Pas de "repo map" type aider (pi envoie ce que l'agent a lu, pas un index pré-chargé) → pas de gaspillage de cache sur un index statique qui change.
- Pas de cache-warming keepalive type aider (pas trouvé dans le bundle ; la stratégie pi = TTL long plutôt que pings).
- Stats et notices, pas de "tuning" automatique des breakpoints au-delà du pattern standard.

---

## 2. opencode (sst/opencode)

> Sources : `packages/llm/src/cache-policy.ts`, `packages/llm/src/protocols/anthropic-messages.ts`, `packages/opencode/src/provider/transform.ts`, tests `packages/llm/test/cache-policy.test.ts`.

### 2.1 Une vraie **CachePolicy** configurable

`cache-policy.ts` — le plus abouti des OSS croisés :

```ts
const AUTO: CachePolicyObject = {
  tools: true,          // breakpoint sur le dernier tool
  system: true,         // breakpoint sur le dernier bloc système
  messages: "latest-user-message", // breakpoint sur le dernier message user
}
const NONE: CachePolicyObject = {}
```

- Résolution : `undefined | "auto"` → AUTO ; `"none"` → NONE ; objet → exactement ce que le caller demande.
- Stratégies messages : `"latest-user-message"` | `"latest-assistant"` | `{ tail: N }` (marque les N derniers).
- **Pourquoi "latest-user-message"** (commentaire du code) : dans une boucle d'outils, le dernier message user reste en place pendant qu'un tour explose en N allers-retours assistant/tool. Cacher à cette frontière permet à **chaque appel intra-tour** de matcher le préfixe. (Convergence avec le "playbook kern-ai 10x cost reduction" cité en commentaire.)
- **Skip total pour les protocoles sans hints inline** : `RESPECTS_INLINE_HINTS = {"anthropic-messages", "bedrock-converse"}` — OpenAI/Gemini sont en implicite, inutile de marquer.
- Le coût justifie le défaut ON (commentaire) : Anthropic write 1.25x, read 0.1x → **1 seul reuse dans les 5 min suffit à gagner**.

Ordre des placements (tests `cache-policy.test.ts`) :
1. system : dernier part → `{type:"ephemeral"}`
2. tools : dernier tool → `cache_control`
3. messages : dernier user (ou dernier bloc texte du dernier message)

### 2.2 Marquage Anthropic au niveau protocol

`protocols/anthropic-messages.ts` :
- jusqu'à **4 breakpoints** par requête (constante), en-tête de commentaire explicite.
- `cacheControl(breakpoints, part.cache)` répandu : system, tool defs, `tool_result` blocks, dernier user.
- TTL optionnel : `ttlSeconds >= 3600 → cache_control ttl: "1h"` (test ligne 766).

### 2.3 Transform : applyCaching par provider

`provider/transform.ts` :

```ts
const providerOptions = {
  anthropic:    { cacheControl: { type: "ephemeral" } },
  openrouter:   { cacheControl: { type: "ephemeral" } },
  bedrock:      { cachePoint: { type: "default" } },
  openaiCompatible: { cache_control: { type: "ephemeral" } },
  copilot:      { copilot_cache_control: { type: "ephemeral" } },
  alibaba:      { cacheControl: { type: "ephemeral" } },
}
```

- Marque **jusqu'à 2 messages système** + **les 2 derniers messages** (`slice(0,2)` / `slice(-2)`), avec placement au niveau "content part" vs "message" selon provider.
- Exclut les parts `tool-approval-request/response` (ne pas cacher des blocs qui changent).

### 2.4 Compaction (taille de préfixe maîtrisée)

`session/compaction.ts` :
- Lookback : quand le contexte déborde, opencode résume les messages plus vieux (`msg.info.summary`), **efface la sortie des tool calls plus anciens** pour libérer de la place (le "maigreur" du préfixe = moins de tokens à re-lire).
- `SessionV1.ContextOverflowError` si même compacté le contexte dépasse la limite (ex. médias).
- Le résumé antérieur est réinjecté (`previousSummary`) → le préfixe reste stable et compact.

### 2.5 TTL / rétention

- `LLMRequest.cache` supporte `ttlSeconds` (nouveauté ; le cache-policy le propage en `CacheHint`).

---

## 3. aider (Aider-AI/aider)

> Sources : `aider/coders/chat_chunks.py`, `aider/coders/base_coder.py`, `aider/repomap.py` (cache disque des tags via diskcache, CACHE_VERSION), issue #1086 "Claude Prompt Caching".

### 3.1 Ordre des chunks — la référence "chat chunks"

`chat_chunks.py` :

```python
def all_messages(self):
    return (
        self.system          # 1. system prompt
        + self.examples      # 2. exemples édits
        + self.readonly_files  # 3. fichiers lus (read-only)
        + self.repo          # 4. repo-map (si activé)
        + self.done          # 5. messages passés (historique)
        + self.chat_files    # 6. fichiers de la conversation
        + self.cur           # 7. message courant
        + self.reminder      # 8. rappel
    )
```

→ **L'ordre est pensé pour le cache** : le plus stable (system, exemples, fichiers lus, repo map) en tête ; le plus volatile (message courant) en fin.

`add_cache_control_headers()` — breakpoints (Anthropic-style `{ type: "ephemeral" }`) positionnés à la **fin de chaque chunk de tête** :
1. fin des exemples (ou du system si pas d'exemples)
2. fin du chunk repo (marque read-only files + repo map ensemble) — sinon fin des read-only files
3. fin des chat_files

Emplacement exact : toujours sur le **dernier bloc de contenu du dernier message du chunk**, convertissant `str` en `{"type":"text",...}` si besoin.

### 3.2 Reuse / meilleure frontière de cache

`cacheable_messages()` : cherche le **dernier message avec cache_control** (en partant de la fin) et ne renvoie que les messages jusqu'à lui → aide pour calculer ce qui est réellement re-utilisable.

### 3.3 Cache warming / keepalive — mesure originale

`base_coder.py` :
- `add_cache_headers` activé si `cache_prompts and main_model.cache_control` (donc modèle par défaut : cache POUR la plupart des modèles; désactivable).
- **`warm_cache(chunks)`** : si `num_cache_warming_pings` > 0 et `ok_to_warm_cache`, envoie des **pings silencieux** à intervalle `AIDER_CACHE_KEEPALIVE_DELAY` (env, défaut… en secondes) pour **rafraîchir le TTL de 5 min** même sans activité. `ok_to_warm_cache` forcé à False quand un autre `from_coder` est actif (threads partagés → ne pas voler du budget cache).
- En-tête d'usage : `output += ", prompt cache"` si `add_cache_headers or main_model.caches_by_default` (dans le compteur de tokens affiché).
- Repo-map : cache disque des tags (`diskcache`, `.aider.tags.cache.v4`, `CACHE_VERSION=4`) → pas de reparse ; `tree-sitter` + PageRank → repo map trié/compact.

### 3.4 Point-clé issue #1086

"Aider orders the chat that gets sent to the LLM to try and maximize caching. Read only files from /read and the repo-map will be cached along with the system prompt." → c'est la stratégie moteur d'aider (avant même la sortie du cache Anthropic, le design était déjà "ordre stable en tête").

---

## 4. cline (cline/cline)

> Sources : `sdk/packages/llms/src/providers/routing/*`, `sdk/packages/shared/src/remote-config/schema.ts`.

### 4.1 Routing par provider avec options cache

`providers/routing/anthropic-compatible.ts` :
- `cache_control: { type: "ephemeral" }` émis dans les options au niveau **part de contenu** (pas message) : "cache_control remains on the content part instead of being collapsed" (preserve le breakpoint quand plusieurs parts).
- `providers/routing/provider-options.test.ts` : tests du bucket `anthropic`/`openrouter`/`openaiCompatible`/`copilot`/`alibaba` — cline a le même mapping de providers qu'opencode (AI SDK), et gère le cas **bedrock cache-point** sans émettre de `cache_control` anthropic (routing dédié).
- `providers/routing/utils.ts` : helper générique `{ cache_control: { type: "ephemeral" } }`.

### 4.2 Config remote (opencode keeper / télémetrie)

`sdk/packages/shared/src/remote-config/schema.ts` : `promptCachingEnabled: z.boolean().optional()` → cline peut piloter l'activation du cache à distance (feature flag).

### 4.3 Observation

- Pas de `cache-policy` aussi structurée qu'opencode ; plutôt une application "aveugle" du breakpoint via les provider-options Vercel AI SDK à chaque requête (avec tests d'invariance de préfixe — voir goose pour l'équivalent Rust).
- Le desktop shell de cline n'ajoute pas de warming.

---

## 5. goose (block/goose)

> Sources : `crates/goose-provider-types/src/cache_semantics.rs`, les tests `prefix_invariance.rs`.

### 5.1 MODÈLE : une sémantique de cache déclarée par (provider, model)

`CacheSemantics` — l'approche la plus rigoureuse conceptuellement :

```rust
pub enum CacheSemantics {
    ExplicitBreakpoints { max_breakpoints: usize }, // marqueurs posés par le client
    ImplicitTolerant,   // plus long préfixe matche, tolérant aux trous
    ImplicitStrict,     // ne réutilise que si le préfixe est rejoué octet par octet depuis le début
    Uncached,           // aucun cache connu
}

pub fn for_model(provider, model) -> Self {
    // anthropic | minimax | zai | kimi_code
    // aws_bedrock/databricks/gcp_vertex_ai si "claude" dans le nom
    // openrouter | litellm si "anthropic/" → ExplicitBreakpoints { max_breakpoints: 4 }
    // openai | azure_openai | github_copilot → ImplicitStrict si responses, sinon ImplicitTolerant
    // moonshot | custom_deepseek | groq | together | fireworks-ai | mistral | zhipu | alibaba → ImplicitTolerant
    // snowflake | sagemaker_tgi → Uncached
    // défaut → ImplicitStrict ("sûr pour tous les caches")
}
```

→ goose **déclare la sémantique**, ne la suppose pas depuis le protocole. C'est la leçon compacte de tout le marché.

### 5.2 Breakpoints Anthropic-dialecte sur payloads OpenAI-style (OpenRouter/LiteLLM/Databricks)

`apply_chat_payload_breakpoints` :
- Du fait que sur l'enveloppe OpenAI-chat les tool results sont `role: "tool"` et les tool calls sur `role: "assistant"`, **ancrer par rôle** piégerait les deux breakpoints messages sur le dernier tour humain → **re-billerait la queue agentique à chaque itération**. goose **ancre par position de bloc de contenu** (offets cumulés) :
  - breakpoint principal sur le dernier message avec contenu cachable ;
  - **breakpoint secondaire à ~LOOKBACK_BLOCKS=20 blocs en arrière** pour rester dans la fenêtre de lookback d'Anthropic quand un tour ajoute beaucoup de blocs (tool calls parallèles) ;
  - system : marque le dernier bloc ; dernier tool : `cache_control` sur `function`.
- Tests `prefix_invariance.rs` : vérifient que le placement des `cache_control` **ne modifie pas le préfixe** (invariance) et que le compte de breakpoints ≤ 4.

### 5.3 Détails de robustesse

- `has_cacheable_content` : Anthropic **rejette** `cache_control` sur texte vide (tool results vides) et sur thinking blocks (Databricks `type:"reasoning"`) ; assistant tool-call messages `content: null` → ne pas marquer.
- `supports_cache_control` disponible par provider (`base.rs`).

---

## 6. Claude Code (référence propriétaire — ce que tous copient)

> Source : doc officielle `code.claude.com/docs/en/prompt-caching` (téléchargée).

### 6.1 Organisation du cache — les 3 couches ordonnées

> "To get the most out of prefix matching, Claude Code orders each request so content that rarely changes between turns comes first :"

| Couche | Contenu | Change quand |
|---|---|---|
| System prompt | Instructions, définitions de tools, output style | Tool defs chargées, upgrade de CC |
| Project context | CLAUDE.md, auto-memory, règles non-scopées | Session start, `/clear`, `/compact` |
| Conversation | Messages, réponses, tool results | **Chaque tour** |

- "A change to the conversation layer leaves the system prompt and project context cached. **A change to the system prompt invalidates everything**."
- Plan mode et skill loading **appendent leurs instructions comme messages de conversation** → le préfixe caché reste intact. (Leçon clé : les modes doivent être des messages, pas des modifications du system prompt.)
- **Partie de la clé de cache qui n'est pas du texte** : le **modèle** (chaque modèle a SON cache) et le **niveau d'effort** (chaque effort a son cache). "Pick your model and effort level at the top of a session... The fewer changes you make mid-task, the higher your cache hit rate."

### 6.2 Actions qui invalident le cache (checklist)

**Invalident** : switch de modèle, changement d'effort, fast mode, connecter/déconnecter un MCP, activer/désactiver un plugin (avec nuances selon type de plugin), **refuser un tool entier** (deny all → change les tool defs ?), **compacter la conversation** (force rebuild), **accumuler beaucoup d'images**, upgrade de CC.
**NE changent PAS le préfixe / gardent le cache** : éditer des fichiers du repo, éditer CLAUDE.md *en cours de session* (documenté : les changements ne s'appliquent qu'au prochain cycle pour ne pas casser le cache), changer l'output style, changer la permission mode, invoquer skills et commands, `/recap`, rewinding la conversation.

→ **Conception** : CC *retarde* l'application de certains changements (CLAUDE.md, output style) pour préserver le préfixe. C'est une **mesure anti-invalidation délibérée**.

### 6.3 Nouveau bloc système "mid-conversation" marqué pour cache

- CC **appende du contexte système en milieu de conversation** (ex. file-change notices) et **marque ce bloc pour le cache sur chaque provider/connexion**. Bedrock/Mantle, Google Cloud Agent Platform, Microsoft Foundry cachent ce bloc pareil que l'API Claude.
- **Comportement via gateway** (`ANTHROPIC_BASE_URL` custom, LLM gateway) :
  - forward tel quel → tout cache ;
  - **rejet 400 nommant `cache_control`** → CC **re-envoie la requête avec le marker RETIRÉ du bloc et mis sur le dernier message de conversation**, et le garde ainsi pour toute la session ; le bloc facturé en input non-caché, la conversation reste cachée ;
  - markers supprimés silencieusement → tout le contexte facturé non-caché à chaque tour.
  → Annexe utile : fallback robuste de cache via gateway.

### 6.4 TTL et subagents

- Entrées de cache expirant après inactivité ; "Cache lifetime" détaille les TTL par requête et le choix du TTL (les requêtes au cache long paient plus de cache-write pour vivre plus longtemps — tradeoff).
- **Subagents et le cache** : section dédiée — les subagents partagent/détruisent le cache de la session parent selon leur propre contexte (détaillé dans la doc).

---

## 7. Codex CLI (openai/codex)

> Sources : web (issues GitHub, blog posts, docs OpenAI).

- **OpenAI = caching implicite par préfixe** + `prompt_cache_key` (routing stable cross-sessions) + `prompt_cache_retention` optionnel (24h).
- Issue `openai/codex#35300` ("GPT-5.6 prompt caching: Codex cannot emit...") : un gros préfixe stable suivi d'un suffixe qui change peut perdre des hits même quand le préfixe est inchangé — le caching a des exigences de **stabilité de jetons** ; le problème est spécifiquement évoqué pour la génération de `prompt_cache_key`.
- Codex : **sessions persistées localement** (`codex resume <SESSION_ID>`, `--last`, `fork`) ; le `session_id` alimente l'affinité de cache.
- 30-min lifetime OpenAI : "begins when the prefix is written and **refreshes whenever the prefix is reused**" (Reddit r/codex).
- Recommandation pratico-pratique observée dans la communauté : clé de cache = `hash(tenant_id + session_id + prompt_version)` et "tune for peak traffic per tenant" (doc OpenAI).
- Le harness codex-as-api expose : "An explicit `prompt_cache_key` wins; otherwise the non-empty session ID supplies cache affinity" — même logique que pi.

---

## 8. Gemini CLI (google-gemini/gemini-cli)

> Sources : web (issues gemini-cli#4237, docs ai.google.dev, substack "Inside Gemini CLI's memory").

- **Implicit caching activé par défaut pour tous les modèles Gemini 2.5+** (pas de marqueur client) ; réduction latence jusqu'à ~30 % (chiffre cité pour Gemini Code Assist / GCA).
- **Explicit caching** = API `cachedContents` séparée (créer une ressource de cache nommée, la référencer) → nécessite un appel API dédié ; la plupart des agents ne l'utilisent pas, d'où issue #4237 demandant le support au niveau "modèle" dans gemini-cli.
- Gemini CLI gère surtout le côté **context management local** (compact context) : le préfixe envoyé est lui-même réduit → moins de tokens à matcher ; couplé au cache serveur implicite.
- Leçon : les providers à cache implicite n'ont pas besoin de placement de breakpoints, ils ont besoin de **stabilité de préfixe** (ne rien injecter de volatile en tête) et de réduction de taille (compaction/compact context).

---

## 9. Synthèse : les mesures de cache-hit par harness

### 9.1 Matrice

| Mesure | pi | opencode | aider | cline | goose | ClaudeCode | Codex | GeminiCLI |
|---|---|---|---|---|---|---|---|---|
| Breakpoints `cache_control` system | ✅ | ✅ (policy) | ✅ | ✅ (routing) | ✅ | ✅ | n/a | n/a |
| Breakpoint dernier tool | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | n/a | n/a |
| Breakpoint dernier message | ✅ (dernier user) | ✅ (latest-user-message) | ✅ (chat_files) | ✅ | ✅ (position bloc) | ✅ | n/a | n/a |
| Ordre prompt stable-d'abord | ✅ (implicite) | ✅ | ✅ **explicite (chunks)** | ✅ | ✅ | ✅ **explicite (couches)** | ✅ | ✅ |
| Cap 4 breakpoints respecté | ✅ | ✅ | (1-several par chunk) | ✅ | ✅ | ✅ | n/a | n/a |
| TTL long optionnel | ✅ `PI_CACHE_RETENTION=long` | ✅ `ttlSeconds` | – | – | – | ✅ (*choose TTL*) | ✅ `retention:24h` | ✅ (explicit API) |
| Cache warming / keepalive | – | – | ✅ **pings silencieux** | – | – | ✅ (implicite via usage) | – | – |
| Key de session stable | ✅ `prompt_cache_key`+headers | – | – | – | – | inconnu | ✅ session_id | n/a |
| Désactivation du cache possible | ✅ `none` | ✅ `cache:"none"` | ✅ per-model | ✅ flag distant | ✅ semantics | ✅ | ✅ | n/a |
| Compaction qui protège le préfixe | ✅ summary en tête | ✅ +efface tool outputs | ✅ /drop | ✅ | ✅ | ✅ `/compact` (invalide par contre) | ✅ | ✅ compact context |
| Anti-invalidation (retard d'appl. des changements) | partiel | – | – | – | – | ✅ **délibéré** | – | – |
| Stats cache visibles | ✅ footer + $ waste | – | ✅ token count | – | – | ✅ cache hit rate | ✅ usage | – |
| Sémantique par (provider, model) déclarée | ✅ compat flags | ✅ (partiel) | ✅ (per-model cache_control) | ✅ | ✅ **meilleur** | n/a | n/a | n/a |

### 9.2 Les 12 leçons transverses (ce qu'un harness doit faire pour maximiser le cache hit)

1. **Ordonner le prompt par stabilité décroissante** : system → contexte projet → historique → dernier message. C'est la mesure n°1 chez TOUS.
2. **Penser aux breakpoints comme à des "points de retour"** : un breakpoint ne sert qu'à matcher un préfixe *futur* ; le poser sur du contenu qui change à chaque tour ne sert à rien (pire : il force le coût de relecture des tokens derrière lui).
3. **Le dernier message user est le breakpoint le plus rentable** pour les boucles d'outils (opencode le documente) : pendant un tour multi-tool, il ne bouge pas → chaque appel intra-tour matche.
4. **Mode/skills = messages de conversation, pas editions du system prompt** (Claude Code) : append en fin de conversation conserve le préfixe.
5. **Ne pas injecter de volatile dans le préfixe** : horodatage/timestamp dans le system prompt = invalidation totale (anti-pattern connu, cf. "Why your bill is 5x").
6. **Un modèle = un cache ; un effort = un cache** : changer de modèle/effort mid-session coûte le rebuild complet.
7. **TTL long quand le fournisseur le permet** (5 min default Anthropic → 1h ; OpenAI 24h) — pi `PI_CACHE_RETENTION=long` ; gouffre de coût si la session est inactive > 5 min.
8. **Cache-warming par pings silencieux** (aider) pour garder la fenêtre de 5 min vivante pendant une activité sporadique. Ne pas le faire si un autre agent partage la session (aider : `ok_to_warm_cache=false`).
9. **Stabiliser la clé de cache** : `prompt_cache_key` dérivé du sessionId (pi, OpenAI), headers `session_id`/`x-session-affinity`/`x-session-id`.
10. **Réduire la taille du préfixe = réduire la facture de relecture** : compaction + suppression des tool outputs périmés (opencode), repo map compacte/rankée (aider), résumé en tête de conversation (pi).
11. **Compaction : coûteuse pour le cache** (Claude Code : `/compact` = invalidation) → mieux vaut un **compact context** progressif qui préserve le préfixe (Gemini CLI, opencode) que des /compact fréquents.
12. **Mesurer et expliquer les misses** (pi) : TTL expiré / modèle changé / contenu volatile = diagnostics qui guident le design du prompt. Réutiliser le tarif `cacheRead` pour chiffrer le gaspillage.

### 9.3 Les trois architectures de placement observées

- **A. Breakpoints explicites multi-frontières** (Anthropic-dialecte ; pi, opencode, aider, goose, cline) : 3-4 breakpoints (system/fin system, dernier tool, dernier message/dernier bloc de chunk).
- **B. Cache implicite + stabilité de clé** (OpenAI, Gemini) : pas de marqueur ; la qualité = stabilité du préfixe + `prompt_cache_key`/session affinity ; le "tuning" est dans le prompt et la session.
- **C. Sémantique déclarée par (provider, modèle)** (goose, pi compat flags) : savoir si on est en breakpoints / implicite-strict / implicite-tolérant / non-caché avant de décider quoi faire. C'est le niveau de maturité le plus élevé.

---

## 10. Anti-patterns & pièges documentés

1. **Timestamp courant dans le system prompt** → invalidation à chaque requête (source : "Why Your Claude Code Bill Is 5x...").
2. **Préfixe stable + suffixe changeant** peut perdre des hits chez OpenAI quand la stabilité token n'est pas garantie (issue codex #35300).
3. **Anthropic rejette `cache_control` sur** : texte vide (tool result vide), thinking blocks (Databricks `type:"reasoning"`), `content: null` (assistant tool-call) → il faut un `has_cacheable_content` (goose).
4. **$. Gateway qui vire les markers** → tout passe en input non-caché ; gateway qui 400 → fallback marker sur dernier message (Claude Code).
5. **Ancrage par rôle sur enveloppe chat-style** piège les deux breakpoints messages sur le dernier user → re-bill de la queue agentique (goose) → ancrer par position de bloc.
6. **Compacter souvent** = re-invalidation ; **switcher de modèle/effort** mid-session = rebuild.
7. **`store: false`** (pi, OpenAI Responses) évite des frais de stockage mais pas le cache — à ne pas confondre.
8. Cache-warming inutile si l'usage réel est continu ; coûteuse en tokens si mal réglée (pings = petits prompts).

---

## 11. Sources & pistes pour approfondir

- Doc pi : `README.md`, `docs/providers.md`, `docs/models.md`, `docs/compaction.md`, `docs/session-format.md`, code `dist/bundle/chunks/{anthropic-messages,openai-responses,openai-completions}*.js`, `dist/core/cache-stats.d.ts`. Repo source : github.com/earendil-works/pi-mono.
- opencode : `packages/llm/src/cache-policy.ts`, `packages/llm/test/cache-policy.test.ts`, `packages/llm/src/protocols/anthropic-messages.ts`, `packages/opencode/src/provider/transform.ts`, `packages/opencode/src/session/compaction.ts`, `packages/opencode/src/session/overflow.ts`.
- aider : `aider/coders/chat_chunks.py`, `aider/coders/base_coder.py` (warm_cache, AIDER_CACHE_KEEPALIVE_DELAY), `aider/repomap.py`, issue Aider-AI/aider#1086.
- cline : `sdk/packages/llms/src/providers/routing/{anthropic-compatible.ts,utils.ts}`, `sdk/packages/shared/src/remote-config/schema.ts`.
- goose : `crates/goose-provider-types/src/cache_semantics.rs`, `crates/goose-provider-types/tests/prefix_invariance.rs`.
- Claude Code : `https://code.claude.com/docs/en/prompt-caching` (page complète lue : organisation 3 couches, invalidations, gateway fallback, TTL, subagents).
- Anthropic API : platform.claude.com/docs prompt-caching (≤4 breakpoints, TTL 5m/1h, cache hit = input×0.1, write = 1.25×).
- OpenAI : developers.openai.com/api/docs/guides/prompt-caching (implicite, `prompt_cache_key`, retention 24h, 30-min lifetime refreshed on reuse).
- Gemini : ai.google.dev/gemini-api/docs/caching (implicite 2.5+ ; explicit = `cachedContents`).
- Blog/reference : "Lessons from building Claude Code: Prompt caching is everything" (Thariq Shihipar / Anthropic), "How Prompt Caching Actually Works in Claude Code" (claudecodecamp.com), "Harnesses: Eager vs Just-in-Time" (towardsai, premier tour & time-to-first-byte / cache).

---

## 12. Questions ouvertes / pistes pour la suite

- [ ] Mesurer précisément le hit-rate pi par provider sur une vraie session longue (footer `CH` vs $ de `cacheRead`).
- [ ] Comparer le "tail" de messages que pi garde vs opencode (`slice(-2)`) vs aider (chunks) — impact sur les hits intra-tour.
- [ ] Tester `PI_CACHE_RETENTION=long` côté anthropic/OpenAI sur des sessions avec pauses > 5 min.
- [ ] Explorer le cache-warming : reproduire le keepalive aider dans pi (boucle pings → frais, quand activer ?).
- [ ] Vérifier le comportement pi en gateway (fallback marker → dernier message ?) — copier la robustesse de Claude Code ?.
- [ ] Lire la section "Subagents and the cache" de Claude Code en entier (impact des subagents sur le cache parent) — pi a des subagents aussi.
- [ ] Regarder les changelogs récents opencode/gemini-cli sur le caching (issues ouvertes #4237 gemini-cli explicit caching).
- [ ] Codex CLI : vérifier si le résumé de session ("thread compaction") est re-caché ou pas.