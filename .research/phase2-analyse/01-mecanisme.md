# Phase 2 — 01 : Le mécanisme du prompt caching (comment ça marche, pourquoi ça casse)

> **Analyse** : phase2-analyse/01 — rédigée à partir des rapports Phase 1 (`00-web-external.md`, `01-harnesses.md`, `02-cache-infra.md`, `03-literature.md`), croisés avec `docs/02-comprehension-etat-de-l-art.md`, `docs/README-cache-hit-harnesses.md` et les résultats expérimentaux H1–H6 mesurés sur pi.
> **Objet** : expliquer *le fonctionnement* — mécanisme fondamental, les 3 architectures, TTL/keepalive, seuils et pièges, et le non-déterminisme du cache OpenAI.

---

## 0. Résumé exécutif (TL;DR)

1. **Le cache de prompt est un cache de préfixe exact au niveau des tokens.** Le provider réutilise les vecteurs clé/valeur (KV-cache) des tokens déjà calculés — et seulement s'ils sont *bit-identiques* au début de la requête. Un octet changé n'importe où dans le préfixe = tout ce qui suit est recalculé (miss total sur le suffixe).
2. **Trois façons de piloter ça** : breakpoints explicites (Anthropic — le client marque jusqu'à 4 blocs), cache implicite (OpenAI/Gemini — le provider matche le plus long préfixe commun tout seul), sémantique déclarée (goose — une table (provider, modèle) dit au harness quoi faire).
3. **TTL** : 5 min par défaut (Anthropic) / 1 h (rétention longue) ; OpenAI ~5-10 min glissant, 24 h en rétention longue ; Gemini ~1 h. Le **keepalive** (pings silencieux) est rentable seulement si `P(réutilisation) × bénéfice > coût des pings`.
4. **Les ennemis** : timestamp dans le system prompt (miss total), set d'outils qui change en session (régénère le system → miss total), compaction (miss au tour suivant), sur-caching (écrits inutiles), modèle/effort qui change (modèle = partie de la clé).
5. **Le cache OpenAI n'est PAS garanti, même bit-identique** : `prompt_cache_key` est un *indice* de localité, pas une garantie (community reports 2025-2026 : hit 1/20 sur GPT-5, `cached_tokens=0` intermittents, délais de secondes à minutes). → **Mesurer, pas présumer.**

---

## 1. Le mécanisme fondamental : KV-cache + préfixe exact

### 1.1 Ce qu'est un KV-cache (la couche en dessous de l'API)

Quand un LLM génère, chaque token du prompt passe dans les couches d'attention, qui calculent pour chaque token des vecteurs **K** (clé) et **V** (valeur), puis une attention causale : chaque token ne regarde que les tokens *avant* lui. Ces vecteurs K/V ne dépendent donc **que du préfixe qui précède** le token.

Conséquence : si une nouvelle requête commence par la même séquence de tokens qu'une requête précédente, les K/V de ces tokens sont **mathématiquement identiques** — le provider peut les réutiliser sans les recalculer, et ne calculer le K/V que des tokens *nouveaux* (le suffixe). C'est un **cache de préfixe** : il évite la quasi-totalité du préfill (le calcul du prompt) et raccourcit le temps au premier token (TTFT).

Côté infrastructure serving, ça se matérialise par :
- **vLLM — Automatic Prefix Caching (APC)** : le K/V est stocké par blocs de 16 tokens hachés ; lookup du plus long préfixe commun à la volée. Métrique `prefix_cache_hit_rate`.
- **SGLang — RadixAttention** : arbre radix (préfixes partagés en arbre), réutilisation automatique, métrique `radix_cache_hit_rate`.
- **CacheBlend / LMCache** : réutilisation *non-préfixe* (fusion de segments KV chevauchants) — la prochaine frontière, mais **pas** ce que les APIs exposent.

> **Leçon** : l'API que consomme un harness est du *exact-prefix* caching. Les techniques radix/non-préfixe existent côté serving privé, mais côté API le contrat est : préfixe exact, byte-stable.

### 1.2 La règle du préfixe exact

Le cache est indexé par **la séquence de token IDs du préfixe** (plus la clé modèle, cf. §1.4). Deux requêtes matchent si leurs premiers tokens sont identiques, jusqu'à la fin du plus long préfixe commun :

```
Requête 1 :  [A B C D E F G H]
Requête 2 :  [A B C D E F X Y Z]   → préfixe commun [A B C D E F], seul [X Y Z] est recalculé
Requête 3 :  [A B C Z ...]         → préfixe commun [A B C], D.. recaléculés
```

C'est **tout-ou-rien pour le suffixe** : le cache ne connaît pas de « segments » (comme la doc Claude Code le dit : *"Il n'y a pas de cache par fichier ou par segment"*). Le préfixe est soit réutilisé en bloc, soit pas.

La **métrique du hit-rate** est donc : `cacheRead / input total` (tokens relus en cache / tokens d'entrée). pi l'affiche en footer (`R/W/CH`) et chez OpenAI c'est `prompt_tokens_details.cached_tokens`.

### 1.3 Pourquoi UN octet changé invalide tout ce qui suit

Deux étages de déterminisme :

1. **Tokenisation** : le tokenizer est une fonction *déterministe* de la chaîne d'octets. Changer un octet dans le prompt change au moins un token à cet endroit (souvent plusieurs, à cause des fusions/merges de sous-mots autour).
2. **KV-cache** : chaque K/V dépend de tous les tokens qui précèdent. Dès que la séquence de tokens diverge, **tous les K/V qui suivent sont différents** — même ceux dont le texte est identique.

Donc : à partir du premier token divergent, **tout le reste du prompt est recalculé**, même si la fin est bit-identique. Un timestamp en tête de system prompt, un UUID, un `session_id` injecté au milieu = le préfixe entier change de clé = miss **total**. C'est ce que l'équipe Lumer et al. simule dans « Don't Break the Cache » avec la condition *No Cache* (UUID au début) : c'est *l'anti-pattern naturel des mauvais harness*.

Nuance pédagogique précise : le match se fait au niveau des **token IDs**, pas des octets. En théorie, deux chaînes d'octets différentes peuvent produire les mêmes token IDs (cas limites de tokenisation). Mais le contrat sûr d'un harness est : **bit-identique ⇒ candidat au hit ; toute autre différence ⇒ miss**. Et même bit-identique n'est pas une garantie à 100 % chez OpenAI (§5).

Inversement : un changement **après** la frontière de réutilisation ne coûte que le suffixe. C'est toute la stratégie : *ce qui change le plus souvent doit être le plus tard possible*. Un changement de 100 octets à la fin d'un system prompt de 2 000 tokens coûte ~100 tokens de re-lecture (miss partiel), pas 2 000 (H3 mesuré chez pi : changement de `cwd` en fin de system = miss partiel de ~100 tokens, coût médian 0.00015 $).

### 1.4 Ce qui compose la clé : (modèle, préfixe, route)

La clé d'un hit n'est pas seulement le texte du prompt :

- **Le modèle** : les poids du modèle changent le calcul des K/V. Changer de modèle (ou de version/rollout, d'effort) en cours de session = espace KV différent = rebuild complet. C'est le « modèle + effort = clé de cache » de Claude Code.
- **Le préfixe tokenisé** : cf. §1.3.
- **L'instance / la région** : les caches vivent dans les instances serving, qui sont régionales. Un cache OpenAI à `us-east` n'existe pas à `eu-west`. Les headers de **session-affinity** (`session_id`, `x-session-id` OpenRouter, `x-session-affinity` Anthropic, `x-client-request-id`) visent à renvoyer les requêtes d'une session vers la même route/instance, où le cache est chaud. Changer de région en session = cache perdu.
- **La clé de session** (OpenAI) : `prompt_cache_key`, une entrée supplémentaire du hash — voir §5.

### 1.5 Les breakpoints : où le préfixe peut être découpé

Un préfixe est réutilisable **en un seul bloc continu**. Mais chez Anthropic, le client peut choisir des **frontières** : le fournisseur ne peut cacher qu'un préfixe qui se termine à un bloc marqué `cache_control`. Les breakpoints définissent donc *la granularité* de ce qui sera re-lu. Chez OpenAI/Gemini (implicite), pas de marqueurs : le provider choisit lui-même le plus long préfixe commun au-dessus du seuil — la « frontière » est alors le point de divergence naturel de la conversation.

---

## 2. Les 3 architectures de déclenchement

### 2.1 Architecture 1 — Breakpoints explicites (Anthropic, Bedrock, Claude Code, OpenRouter `anthropic/*`)

Le client marque des blocs avec `cache_control: {type: "ephemeral"}` (ou `ttl: "1h"` en rétention longue), **jusqu'à 4 blocs par requête**. Le provider ne cache que les préfixes se terminant à un breakpoint marqué.

Le pattern standard (pi, opencode, aider, cline, goose le partagent) — les **3 breakpoints** :

1. **Fin du system prompt** — le bloc le plus stable et volumineux → LE levier de coût dominant.
2. **Dernière définition de tool** (`tools[tools.length-1]`) — la frontière entre system et conversation.
3. **Dernier message user** (dernier bloc texte/image/tool_result du dernier message user) — la frontière dynamique.

Pourquoi le 3ᵉ est le plus rentable en boucle d'outils : **pendant qu'un tour « explose » en N allers-retours assistant/tool**, le dernier message user reste *en place* (les tool_results s'accumulent dans la queue, avant lui). Chaque appel intra-tour matche donc le préfixe jusqu'au dernier user, et ne paie que les tool results frais. Sans ce breakpoint, chaque appel intra-tour re-billerait **toute** la conversation. C'est la stratégie `latest-user-message` documentée par opencode (*cache-policy.ts*), et c'est ce que pi fait déjà — H2 l'a confirmé expérimentalement : **91.9 % de hit-rate global** en boucle d'outils (cr 2816 → 8704 qui croît avec la conversation, seuls les deltas passent en input).

Détails d'implémentation chez pi (`getCacheControl`) :
- `PI_CACHE_RETENTION=long` → `ttl: "1h"` (si `supportsLongCacheRetention`), sinon breakpoint sans TTL (5 min).
- `supportsCacheControlOnTools` : certains providers rejettent `cache_control` sur les tools → compat flag par modèle.
- Cap **4 breakpoints** (limite Anthropic) : pi n'en pose que 3.
- `cacheControlFormat: "anthropic"` : sur les providers OpenAI-compatible qui exposent un cache à la Anthropic (OpenRouter pour `anthropic/*`), les marqueurs sont posés sur les blocks texte et les définitions de tools (même pattern, dialecte différent).
- Mode OAuth Claude Code : 2 blocs system ("You are Claude Code…" + le vrai system), tous deux marqués — nécessaire pour matcher le préfixe qu'attend la plage serving de Claude.
- **Nouveauté 2026 (Anthropic)** : le breakpoint devient *causal* côté provider — « the system automatically applies the cache breakpoint to the last cacheable block and moves it forward as conversations grow » — c'est-à-dire que même sans marquage parfait du client, la frontière suit la croissance de la conversation. Claude Code documente aussi le fallback gateway (400 sur `cache_control` → renvoi sans marker, marker sur le dernier message).

Économie (Anthropic) : write **1.25×**, read **0.1×**. Un system de 3 000 tokens : 1ᵉʳ tour = 3 750 tokens équivalents (write), chaque hit suivant = 300. **Dès ~1-2 réutilisations dans la fenêtre TTL, c'est rentable.** (Littérature : « rentable dès ~2 réutilisations ».)

### 2.2 Architecture 2 — Cache implicite (OpenAI, Gemini)

Pas de marqueur. Le provider cherche le plus long préfixe commun à chaque requête (au-dessus du seuil, dans la fenêtre TTL) et le facture en tokens « cached ».

Le rôle du client se déplace de *choisir les frontières* vers **garantir la stabilité du préfixe et la stabilité de la route** :

- préfixe stable bit-identique (le system prompt surtout) ;
- `prompt_cache_key = clampOpenAIPromptCacheKey(sessionId)` (64 chars, dérivé du uuidv7) : fige la topologie de cache cross-requêtes ;
- headers `session_id` / `x-session-affinity` / `x-client-request-id` (OpenAI), `x-session-id` (OpenRouter) : affinité de route ;
- `prompt_cache_retention: "24h"` quand `PI_CACHE_RETENTION=long` ;
- `store: false` (évite les frais de stockage serveur, indépendant du cache) ;
- seuil minimal : ≥ 1024 tokens de préfixe (OpenAI), ≥ 4096 (Gemini).

Tarification OpenAI : tokens cachés à **0.5×**. Gemini (2.5+) : implicite activé par défaut, jusqu'à −75 % de latence/coût, TTL ~1 h. Gemini a aussi un cache **explicite** (`CachedContent`, TTL configurable ~20 min → 30 j, stockage payant) — rarement utilisé par les agents.

Chez OpenAI, `cached_tokens` est la seule observabilité (`prompt_tokens_details.cached_tokens`). Codex CLI : sessions persistées localement = affinité de cache (30-min lifetime « refreshed on reuse »).

### 2.3 Architecture 3 — Sémantique déclarée (goose `CacheSemantics`)

L'innovation de goose : au lieu d'un marquage inconditionnel, le harness **déclare la sémantique attendue** par (provider, modèle) et adapte son comportement :

```rust
pub enum CacheSemantics {
    ExplicitBreakpoints,  // anthropic/bedrock : poser cache_control
    ImplicitTolerant,     // OpenAI/Gemini : pas de marqueur, préfixe stable
    ImplicitStrict,       // idem mais stricte
    Uncached,             // snowflake/sagemaker-tgi : ne rien faire (pas de cache)
}
```

C'est la même philosophie que l'hypothèse H9 de pi : une table de décision (provider, modèle) → quelle stratégie. Détails remarquables du code goose (`cache_semantics.rs`) :

- **Ancrage par position de bloc, pas par rôle** : marquer « le dernier user » par rôle piégerait les 2 breakpoints messages sur le même message quand le dernier message est un tool_result appartenant au user ; l'ancre positionnelle préserve l'invariance du préfixe.
- Breakpoint secondaire à ~`LOOKBACK_BLOCKS = 20` blocs en arrière.
- `has_cacheable_content` : refuse de marquer texte vide / thinking blocks / `content: null`.
- Tests `prefix_invariance.rs` : vérifient que le placement des `cache_control` **ne modifie pas le préfixe** (un marqueur mal posé peut casser le JSON et donc le hash).

### 2.4 Comparaison

| | Breakpoints explicites | Implicite | Sémantique déclarée |
|---|---|---|---|
| Providers | Anthropic, Bedrock, Claude, OpenRouter `anthropic/*` | OpenAI, Gemini, OpenRouter (défaut) | goose : table (provider, modèle) |
| Déclenchement | client marque ≤ 4 blocs `cache_control` | plus long préfixe commun automatique | le harness choisit la stratégie selon la table |
| Rôle du client | choisir les frontières | stabilité du préfixe + clé + route | choisir expl./impl./rien |
| Tarif | write 1.25×, read 0.1× | read 0.5× (OpenAI) | selon provider |
| Seuil | ≥ 1024 (⚠️ sources récentes : peut-être 2048) | ≥ 1024 (OpenAI) / ≥ 4096 (Gemini) | selon provider |
| Observabilité | `cache_read_input_tokens`, `cache_creation_input_tokens` | `cached_tokens` | selon provider |

---

## 3. TTL, rétention et keepalive

### 3.1 Les valeurs de TTL

| Provider | TTL court | TTL long | Mode |
|---|---|---|---|
| Anthropic | 5 min (défaut, glissant sur réutilisation) | 1 h (`ttl: "1h"`) | explicite |
| OpenAI | ~5-10 min glissant (« refreshed on reuse » ; Codex : 30 min) | 24 h (`prompt_cache_retention: "24h"`) | implicite |
| Gemini | ~1 h (implicite 2.5+) | `CachedContent` : 20 min → 30 j (stockage payant) | implicite + explicite |

La fenêtre de réutilisation est donc courte : un utilisateur qui laisse la session inactive > 5 min (Anthropic short) perd le cache. C'est la cause n°1 de miss « attendu » chez pi (`CacheMiss{idleMs}`, `CACHE_TTL_MS = 5 min` de référence).

### 3.2 Glissant vs fixe

Chez OpenAI, le TTL est **glissant** : chaque réutilisation du préfixe rafraîchit la fenêtre. Chez Anthropic, le comportement est similaire (réutilisation = prolongation), avec une nuance importante rapportée par les sources : **les lectures ne prolongent pas forcément le TTL chez tous les providers** — et en explicite, chaque requête qui réécrit du contenu facture du write (1.25×). C'est le tradeoff central du keepalive : un ping qui « réécrit » le préfixe entier coûte cher ; un ping qui relit seulement peut ne pas prolonger le TTL.

### 3.3 Le keepalive : l'économie des pings

Le keepalive = envoyer périodiquement une petite requête qui réutilise le préfixe, pour rafraîchir la fenêtre TTL pendant une pause.

- **aider** : `warm_cache(chunks)` — pings silencieux calés sur le TTL 5 min (`AIDER_CACHE_KEEPALIVE_DELAY`, `--cache-keepalive-pings N`).
- **Le papier dédié** (arXiv:2607.19214, « Keeping the Cache Warm Pays », juil 2026) : le cache read est ~10× moins cher que l'input normal **et supprime la plupart du préfill**. La question n'est pas « faut-il pinger ? » mais « à quelle fréquence ? » : le modèle économique est
  **`P(réutilisation dans la fenêtre) × bénéfice_du_hit > coût_des_pings`**.
- Le ping doit être petit (pas de re-write massive) et ne concerner que les sessions où la reprise est probable.
- pi n'implémente pas de keepalive : sa stratégie est le **TTL long** (`PI_CACHE_RETENTION=long` → 1 h / 24 h), ce qui est une alternative quand le provider le supporte (pas de coût de ping, mais pas de prolongation active non plus).

Mesure expérimentale pi : H5 (keepalive) n'a pas pu être testé faute de sessions avec pauses > 5 min — la question reste ouverte.

### 3.4 Le réglage pi

`PI_CACHE_RETENTION` : `short` (défaut) | `long` (Anthropic 1 h, OpenAI 24 h) | `none` (désactive le cache : pas de breakpoint, `prompt_cache_options: {mode: "explicit"}` sur les providers qui l'acceptent). C'est LE levier global « fenêtre de réutilisation » du harness.

---

## 4. Seuils et pièges

### 4.1 Les seuils minimaux de préfixe

Un préfixe trop court n'est **jamais** caché : ≥ 1024 tokens (Anthropic/OpenAI — ⚠️ sources récentes évoquent une montée à 2048 côté Anthropic), ≥ 4096 (Gemini). L'ablation du papier « Don't Break the Cache » (500 tokens < seuils) montre une **régression TTFT de 10-18 %** quand le cache ne s'active pas : la vérification de préfixe + la variance serveur coûtent plus que ce qu'elles sauvent. Le system prompt de pi (~1-2k tokens) est juste au bord ; viser confortablement ≥ 2k est recommandé.

### 4.2 Timestamps, IDs et contenu volatile → miss total

Un `datetime`, UUID, session id, user info, météo… injecté **dans le préfixe** change la clé à chaque tour → miss total permanent. Règle d'or (consensus 2026, « frozen system prompt ») : **statique en tête, dynamique en fin** ; si un élément dynamique est inévitable, le mettre à la toute fin du system prompt ou dans le premier message user (le suffixe dynamique est le seul recalculé). Les pierres d'achoppement réelles des harness : ordre de liste de fichiers, sérialisation non déterministe de JSON, horodatage dans un message, `cwd`/path machine-dépendant (anti-article Dan MacKinlay sur les presets qui cassent le cache cross-machines).

Mesure pi — H3 : le `cwd` est déjà en **position finale** du system prompt ; le changer coûte un miss partiel de ~100 tokens. H3 « sortir le cwd du system » est **réfutée** : le Δ est du bruit inter-sessions (signes inversés entre providers, coûts ~0.0001 $). Le design actuel est quasi-optimal.

### 4.3 Le set d'outils qui change → invalidation cachée (pi)

C'est le piège le plus subtil et le plus coûteux : **tout changement du set d'outils régénère le system prompt** (les guidelines de pi dépendent des tools). Dans le code pi (`agent-session.ts`) :

- ligne ~983 : à chaque **changement du set d'outils** (`this._baseSystemPrompt = this._rebuildSystemPrompt(validToolNames)`) ;
- ligne ~2491 : à chaque **extension de ressources** (skills/prompts/themes chargés dynamiquement).

Or changer d'un seul caractère le system prompt = nouveau préfixe = **miss total** sur tout ce qui suit. Mesures H1 : rebuild « en fin » (tools supplémentaires seulement en queue de guidelines) = miss **partiel** (coût ×3.5) ; rebuild « au milieu » (guidelines réordonnées) = **miss total** (cr = 0).

La leçon est générale (MCP, tool discovery, plugins) : l'architecture de plugins peut casser le cache à elle seule (issue `oh-my-openagent#1247` : « Plugin architecture prevents Prompt Caching (0% hit) »). Stratégie recommandée : **set d'outils fixe et ordre stable**, dynamique par code généré plutôt que par function calling, et tout changement différé (pattern Claude Code : les modifs de CLAUDE.md s'appliquent au prochain cycle). Attention aussi à l'ordre des définitions de tools : réordonner = miss.

### 4.4 Compaction et résumés

La compaction (quand `contextTokens > contextWindow − reserveTokens`) supprime des messages anciens et insère un résumé juste après le system prompt :

- Le résumé est dans le **préfixe stable** (il ne change pas entre compactions) → il reste caché tant qu'il est stable. C'est le bon design.
- MAIS **le tour qui suit la compaction est un miss total** : le préfixe entier a changé (messages supprimés). C'est le « coût caché » de la compaction — Claude Code le documente (« /compact force rebuild »). Il faut minimiser la fréquence des compactions et préférer un compact-context progressif (garder les N derniers tool results, résumer le reste).
- Les prompts one-shot (compaction, branch-summary) utilisent des **sessionId de routage frais et désactivent l'écriture de cache** : ce contenu ne sera jamais relu, écrire un cache coûte sans bénéfice.
- Controverse littérature : « summarize/ pruner d'anciens tool calls casse les représentations cachées » vs « le parent compacté garde le préfixe » (claudecodecamp) — dépend de l'implémentation.

### 4.5 L'overcaching tax (le sur-caching coûte)

Cacher un contenu **unique** (tool results qui ne se répètent jamais) = des writes (1.25× chez Anthropic, coût de write partout) sans jamais de lecture → overhead net, parfois **régression de latence** : dans le papier, GPT-4o en *full-context* naïf régresse de **−8.8 % TTFT** vs system-only. La stratégie gagnante dépend du modèle (GPT-5.2 → exclure les tool results ; Sonnet → system-only suffit) : contrôler les frontières, ne pas tout cacher. Cet « esprit » de H4 est inapplicable en pratique sur nos providers implicites (pas de marqueur pour exclure), mais guide le placement des breakpoints en explicite.

### 4.6 Rotations de sessionId, modèle/effort

- `newSession`/`newBranch` → nouveau sessionId → nouvelle topologie de cache (`prompt_cache_key`, session-affinity). Le contenu du préfixe, lui, ne change pas : un cache implicite peut toujours matcher si le texte est identique.
- Changer de **modèle ou d'effort** en session = clé de cache différente = rebuild (Claude Code le documente explicitement).
- Changer de région / d'endpoint = cache perdu.
- Sous le seuil (prompts courts, ex. agents sans system volumineux) : pas de cache du tout.

### 4.7 Sécurité (le revers)

Le cache = fuite potentielle : timing side-channels (Stanford, ICML 2025 : 8/17 providers vulnérables — un attaquant peut détecter un préfixe caché par le temps de réponse) et data residency (le cache vit chez le provider). Consigne : ne pas injecter de secrets dans le préfixe, connaître le modèle de menace.

---

## 5. Pourquoi le cache OpenAI est non-déterministe même bit-identique

### 5.1 Les faits (community reports 2025-2026, sources vérifiées en ligne)

1. **« Caching is borked for GPT-5 models »** (sept 2025, community.openai.com) : hit rate ~1/20, `prompt_cache_key` **sans effet** — cité littéralement : *« It is merely an additional input to the hashing »*.
2. **`prompt_cache_key` n'est PAS déterministe** : deux prompts identiques envoyés à la suite → le second n'est pas 100 % caché ; il faut des **secondes à minutes** pour que le cache prenne effet.
3. **`cached_tokens = 0` intermittents** même avec préfixe statique identique (juil 2026), observés sur un orchestrateur multi-agent.
4. Contre-point Azure (avril 2026) : ajouter `prompt_cache_key` a fait passer le hit de 60 % → 87 % sur un déploiement de prod → la clé *aide* (routing) mais ne garantit pas.

### 5.2 Ce que ces symptômes suggèrent sur l'implémentation (hypothèses, non vérifiées)

Le comportement rapporté est cohérent avec une architecture où le hit dépend de **beaucoup plus que le texte du prompt** :

- **Le hash contient d'autres entrées que le préfixe** : famille/version du modèle (rollout), paramètres de génération, champs de requête (`store`, `temperature`, etc.), `prompt_cache_key`, métadonnées de routing. Si l'une de ces entrées bouge (rollout de modèle déployé en cours de journée, changement de config d'infra), le hash change → miss malgré préfixe identique. C'est exactement le « merely an additional input to the hashing » des rapports.
- **Le cache est réparti sur des instances, pas global** : le load-balancer envoie la requête sur une instance dont l'état de cache local dépend de son historique (et de son éviction LRU sous charge multi-tenant). Deux requêtes identiques peuvent tomber sur deux instances au passé différent → l'une hit, l'autre miss. Les headers de session-affinity réduisent ce problème sans le supprimer (ils sont un indice de routage, pas une garantie).
- **Population asynchrone/lazy** : le premier appel « écrit » le cache de façon asynchrone ; un second appel immédiat peut le rater (d'où le délai de secondes à minutes avant effet). L'éviction peut aussi être proactive (protéger la capacité de génération) ou déclenchée par la montée en charge.
- **Churn des rollouts** : les rapports « GPT-5 borked » coïncident avec des fenêtres de déploiement de versions — cohérent avec un cache keyé par version de poids.
- **Seuils et fenêtres internes** : le TTL ~5-10 min est appliqué par-dessus une politique d'éviction variable ; un préfixe « juste au seuil » peut passer ou non selon la charge.

### 5.3 `prompt_cache_key` : indice de localité, pas garantie

Le `prompt_cache_key` (pi : 64 chars clampés dérivés du sessionId) **n'active pas** le cache : il ajoute une entrée au hash et aide le routing à aligner les requêtes d'une session sur la même topologie de cache. La preuve empirique : sans clé, OpenAI matche sur le préfixe seul (60 % en Azure) ; avec clé stable, la route se fige (87 %). Mais 100 % n'est jamais garanti.

### 5.4 Conséquences pour un harness (mesurer, pas présumer)

- Le **bit-identique reste le meilleur pari** : il maximise la probabilité de hit. C'est ce que H6 a validé chez pi : le prompt reconstruit au resume est bit-identique (`sysHash` constant) et le cache OpenAI **survit au resume** (cr 2816 → 2816, hit total).
- Mais un `cached_tokens = 0` ponctuel n'est **pas** un bug : c'est le comportement attendu d'un cache probabiliste. Le diagnostiquer via les stats (`cacheRead`, `CacheMiss{idleMs, modelChanged}`, `computeCacheWaste` en $) plutôt que de l'interpréter comme une invalidité.
- Stabiliser sessionId + headers d'affinité à travers resume/fork pour maximiser la probabilité.
- En environnement de prod : mesurer le hit-rate comme un **SLO** (objectif de statistique, pas une certitude) et comparer les variantes (avec/sans clé, avec/sans `prompt_cache_retention: "24h"`) sur le terrain.

---

## 6. Synthèse : quel levier agit sur quoi

| # | Levier | Mécanisme | Impact sur le hit-rate | Preuve / mesure |
|---|---|---|---|---|
| 1 | **Ordre du prompt** (stabilité décroissante : system → contexte → historique → dernier user) | La frontière du préfixe commun suit le point de divergence naturel | Fondamental : déplace la frontière de réutilisation aussi loin que possible | Consensus tous harness ; papier « Don't Break the Cache » |
| 2 | **Breakpoints aux 3 frontières** (system, dernier tool, dernier user) | Rend le préfixe *découpable* aux bons endroits (explicite) | Le breakpoint « dernier user » donne les hits intra-boucle | H2 pi : **91.9 %** en boucle d'outils |
| 3 | **Frozen system prompt** (jamais de rebuild en session) | Évite le changement de clé du plus gros bloc | Évite le miss total | H1 : rebuild milieu = cr=0 ; littérature = consensus 2026 |
| 4 | **Tout le volatile en queue** (timestamp, cwd, IDs) | Un octet en tête = miss total ; en queue = miss partiel | Transforme un miss total en miss partiel | H3 : cwd en fin = ~100 tokens relus |
| 5 | **TTL long** (`PI_CACHE_RETENTION=long` : 1 h / 24 h) | Élargit la fenêtre de réutilisation | Évite les misses d'idle (5 min → 1 h/24 h) | `supportsLongCacheRetention` par modèle |
| 6 | **Keepalive** (pings silencieux calés sur le TTL) | Rafraîchit la fenêtre pendant les pauses | Maintient les hits sur sessions longues ; rentable si P(reprise) × bénéfice > coût des pings | aider `warm_cache` ; arXiv 2607.19214 |
| 7 | **Stabiliser la clé** (`prompt_cache_key` + session-affinity + sessionId stable) | Fige la topologie/route de cache | Réduit les hits « aléatoires » (instance, rollout) | Azure : 60 → 87 % ; H6 : hit au resume |
| 8 | **Respecter les seuils** (≥ 1024 / 4096 tokens de préfixe) | Le cache ne s'active pas sous le seuil | En-dessous : 0 hit + TTFT régression 10-18 % | Ablation du papier (500 tokens) |
| 9 | **Set d'outils fixe + ordre stable** | Un tool en plus/à une autre place = system régénéré | Évite le miss total le plus fréquent (tools/MCP) | H1 ; issue `oh-my-openagent#1247` (plugins = 0 % hit) |
| 10 | **Compaction rare + summary en tête** | Le résumé stable reste caché ; la compaction elle-même = miss | Minimise la fréquence du miss total de compaction | docs pi/compaction ; claudecodecamp |
| 11 | **Modèle + effort stables en session** | Le modèle est une entrée de la clé | Éviter les rebuilds de clé | Claude Code docs |
| 12 | **Mesurer** (`cacheRead`, `cached_tokens`, `computeCacheWaste`) | Boucle de rétroaction | Détecte misses explicables vs non-déterminisme | footer R/W/CH ; `CacheMiss{idleMs, modelChanged}` |

Le pattern gagnant (confirmé par la littérature ET les mesures H1-H6 sur pi) :
**system prompt figé + tout le dynamique en queue + breakpoints aux 3 frontières + modèle/effort stables + TTL long + keepalive si pauses prévisibles + clé de session stable + mesurer les misses.**

---

## 7. Références principales

- Rapports Phase 1 : `00-web-external.md` (web 2025-2026), `01-harnesses.md` (8 harnesses), `02-cache-infra.md` (infra/APIs/comportements), `03-literature.md` (papiers).
- Papiers : « Don't Break the Cache » (arXiv:2601.06007) ; « Keepalive Economics » (arXiv:2607.19214) ; RadixAttention (SGLang, arXiv:2312.07104) ; vLLM APC ; « Auditing Prompt Caching » (Stanford, arXiv:2502.07776) ; CacheBlend (arXiv:2405.16444).
- Code : pi (`getCacheControl`, `_rebuildSystemPrompt`, `openai-prompt-cache.ts`), opencode (`cache-policy.ts`), goose (`cache_semantics.rs`, `prefix_invariance.rs`), aider (`chat_chunks.py`, `base_coder.py`).
- Mesures pi : H1 (rebuild = miss partiel/total), H2 (91.9 % boucle d'outils), H3 (cwd réfutée), H6 (resume bit-identique = hit).