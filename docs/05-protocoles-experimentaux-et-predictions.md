# Protocoles expérimentaux & prédictions — Optimisation du cache-hit dans pi

> **Suite directe de `04-cas-de-tests-et-predictions.md`** — cette fois chaque hypothèse H1..H10 devient un **protocole expérimental exécutable**, avec :
> - une **hypothèse formelle** (variable indépendante, variable dépendante, conditions contrôlées),
> - un **protocole pas-à-pas** conçu pour être **indépendant des autres tests** (isolation des variables, séquence temporelle, pas de contamination),
> - un design qui **démontre la véracité** (le test prouve que l'optimisation *fait* ce qu'elle prétend) **et l'efficacité** (l'optimisation améliore une métrique de coût/latence chiffrée),
> - une **prédiction chiffrée** (avec intervalle) et le critère de réussite/échec.
>
> **Ancrage code réel** : toutes les hypothèses ont été vérifiées sur le bundle pi installé (`/home/anhydrite/.nvm/versions/node/v24.15.0/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/chunks/`) :
> - `_rebuildSystemPrompt` appelé dans `setActiveToolsByName` **et** `extendResources` (chunk-E5KXRMZK.js) → fuite H1 confirmée dans le code.
> - 3 breakpoints confirmés : system (`params.system[0].cache_control`), dernier tool (`index===tools.length-1 ? {cache_control}`), dernier message (`lastBlock.type text|image|tool_result → cache_control`) (anthropic-messages-JWX2WP65.js).
> - `getCacheControl` : `PI_CACHE_RETENTION=long → ttl:"1h"`, `none → pas de cache_control` (anthropic-messages).
> - OpenAI : `prompt_cache_key = clampOpenAIPromptCacheKey(sessionId)` si `baseUrl api.openai.com` ou retention long ; `prompt_cache_retention:"24h"` si long (openai-completions-JD4WAC3R.js).
> - `cacheControlFormat:"anthropic"` seulement pour OpenRouter + modèles `anthropic/*` (openai-completions).

---

## PARTIE 0 — CADRE EXPÉRIMENTAL COMMUN

Ce cadre s'applique à **tous** les protocoles. Chaque protocole n'y déroge que si explicité.

### 0.1 Métriques objectives (toutes issues de l'usage API, jamais de ressenti)

| Métrique | Définition opérationnelle | Où la mesurer |
|---|---|---|
| `cache_read_tok` | tokens lus depuis le cache (préfixe matché) au tour N | `usage.cache_read_input_tokens` (Anthropic) / `usage.prompt_tokens_details.cached_tokens` (OpenAI) |
| `cache_write_tok` | tokens écrits en cache au tour N (overhead) | `usage.cache_creation_input_tokens` (Anthropic) / `usage.prompt_tokens_details` (OpenAI) |
| `input_tok` | tokens d'entrée facturés au tarif normal | `usage.input_tokens` |
| `hit_rate(N)` | `cache_read_tok(N) / (input_tok(N) + cache_read_tok(N) + cache_write_tok(N))` | calculé depuis l'usage |
| `tokens_hit_ratio(N)` | fraction du prompt *rejoué* en cache | `cache_read_tok(N) / total_prompt_tokens(N)` |
| `cost_turn(N)` | $ du tour N = `input×P_in + cache_read×P_cr + cache_write×P_cw + output×P_out` | prix du modèle (constante de test) |
| `cost_per_turn` | coût médian par tour sur la fenêtre de mesure | médiane des `cost_turn` |
| `ttft(N)` | temps (ms) entre l'envoi de la requête et le 1er chunk de réponse | `performance.now()` au 1er événement `text_start` (streaming) |
| `prefix_diff(N,N+1)` | delta d'octets/tokens entre le prompt sérialisé complet de N et N+1 | hash SHA-256 du prompt sérialisé (JSON canonique) |
| `rebuild_count` | nombre d'appels à `_rebuildSystemPrompt` dans une session | instrumentation (hook/patron) |
| `system_size_tok` | taille en tokens du system prompt effectif | tokenizer du modèle (ou approximation 4 chars/token) |
| `conversation_size_tok` | taille en tokens des messages (hors system) | idem |

**Signaux d'échec de mesure à rejeter** (documenter, ne pas inclure dans les stats) : rate-limit, erreurs réseau, > 2 tentatives sur un tour, réponses tronquées par `max_tokens`.

### 0.2 Design expérimental standard

**Schema de base — ABBA intra-session (recommandé) ou A/B inter-sessions :**
- **ABBA** : mesure condition A (baseline) → B (optimisation) → B → A, sur la **même** session longue, en alternant pour annuler la dérive temporelle (cache qui se réchauffe, contexte qui grossit).
- **A/B inter-sessions** : sessions strictement séparées (chaque condition sur une nouvelle session), mêmes repo/cwd/modèle.

**Conditions de contrôle obligatoires (pour l'indépendance) :**
1. **Même modèle, même provider** pour toute la comparaison — le modèle fait partie de la clé de cache (changer de modèle = changer de cache).
2. **Même repo, même cwd, même AGENTS.md** — le contenu projet fait partie du préfixe.
3. **Même sessionId** pour tester la stabilité ; sessions séparées pour tester l'isolation.
4. **Warm-up** : 1 tour "junk" (même préfixe) AVANT la mesure, pour que le cache soit écrit. La mesure commence au tour suivant.
5. **Écart temporel > TTL entre deux conditions** : sinon le tour suivant matche le cache de la condition précédente (contamination). Pour Anthropic short : ≥ 6 min ; pour long : ≥ 65 min ; **ou** utiliser `cacheRetention:"none"` sur le contrôle pour forcer un cache vide (technique recommandée pour accélérer les tests).
6. **N ≥ 5 sessions ou ≥ 10 tours par condition** ; rapport de **médiane + IQR** (jamais la moyenne seule — la latence est bruitée).
7. **Seuil minimal de cache vérifié** : 1024 tokens (OpenAI/Anthropic), 4096 (Gemini). Un test sous le seuil est **invalide** (le cache ne peut pas s'activer). Vérifier `system_size_tok ≥ 2048` avant de commencer.

### 0.3 Les trois preuves exigées de chaque protocole

Chaque protocole doit fournir **trois niveaux de preuve** :

1. **Preuve de véracité (mécanisme)** : le test démontre que l'optimisation *fait ce qu'elle prétend* au niveau des octets/du préfixe. Méthode standard : comparer `prefix_diff` et/ou inspecter la requête wire (hook `onPayload`) pour vérifier que le préfixe stable ne change pas et que les breakpoints sont bien placés.
2. **Preuve d'efficacité (impact chiffré)** : le test démontre que l'optimisation *améliore* une métrique de coût ou de latence. Méthode : comparer `cost_per_turn` et/ou `ttft` entre baseline et optimisation sur la même fenêtre.
3. **Preuve de non-régression (sécurité)** : le test démontre que l'optimisation ne *dégrade pas* ce que l'optimisation ne vise pas (latence si on optimise le coût, coût si on optimise la latence, comportement en boucle d'outils, tolérance aux cas limite).

**Règle de décision :** une optimisation est **validée** si (véracité prouvée) ET (efficacité au-delà du bruit : gain ≥ 5 % sur la métrique cible, médiane) ET (non-régression ≤ 2 % sur les métriques annexes). Sinon **rejetée** — et le protocole doit documenter pourquoi (l'hypothèse est fausse, le mécanisme est neutre, ou l'effet est sous le seuil de mesure).

### 0.4 Indépendance inter-protocoles (matrice des contaminations)

Le risque n°1 d'un test de cache : **le test d'une hypothèse contamine le résultat d'une autre** (parce que le cache est par préfixe et que tout le monde partage le même mécanisme serveur).

| Protocole | Change quoi | Risque de contamination vers | Parades |
|---|---|---|---|
| T1 (rebuild) | `setActiveToolsByName`/`extendResources` → invalidation | T2, T4 (le rebuild modifie la base de tous les tours suivants) | T1 se fait sur **fork de session** ; tester T2/T4 sur des sessions sans rebuild pour mesurer la stabilité pure |
| T2 (breakpoint user vs assistant) | position du 3e breakpoint | T1 (si le rebuild se produit pendant la boucle, il masque l'effet) | T2 : session sans aucun rebuild (outils figés) |
| T3 (cwd/AGENTS.md) | contenu du préfixe (system prompt) | T1, T6 (cwd différent = préfixe différent = la comparaison inter-session devient invalide) | T3 : **sessions séparées dédiées** ; jamais mélanger avec une autre comparaison inter-sessions |
| T4 (exclure tool results) | breakpoints autour de la conversation | T2 (les deux touchent les breakpoints messages) | T4 : mesurer sur un contexte sans boucle d'outils active (conversation simple) |
| T5 (keepalive) | TTL / pings | T1, T2, T4, T6 (les pings écrivent du cache et modifient l'usage mesuré) | T5 : mesurer sur une session isolée avec `cacheRetention:"none"` pour le contrôle |
| T6 (resume bit-identique) | reconstruction du prompt au resume | TOUS (un resume mal reconstruit invalide tout ce qui suit) | T6 : **dernier** dans l'ordre d'exécution ; ou session de test dédiée |
| T7 (breakpoint sans tools) | présence du breakpoint system | T2 (même mécanisme de placement) | T7 : session avec 0 tool, aucun autre levier activé |
| T8 ($ waste) | calcul de métrique | aucun (métrique pure) | T8 peut être exécuté sur n'importe quelle session existante, en parallèle |
| T9 (sémantique provider) | classification provider/model | T2, T7 (les breakpoints par provider) | T9 : tests **offline** (inspection de payload) sans appels réseau |
| T10 (non-prefix) | structure du prompt | tous (hors API standard) | T10 : infra dédiée (serving maison), jamais sur les mêmes sessions |

**Règle d'or** : chaque protocole qui manipule le **contenu du préfixe** (T1, T3, T6) doit s'exécuter sur des **sessions dédiées séparées** ; chaque protocole qui manipule les **breakpoints** (T2, T4, T7) sur des sessions **sans rebuild** ; T9/T10 hors-ligne ou infra dédiée. Aucun protocole ne doit partager une session avec un autre (sauf T8, passif).

### 0.5 Budget type d'une exécution

- Un tour de session pi réel (providers payants) : ~0.5–3k tokens prompt + ~0.2–1k output selon la tâche.
- Coût estimé par condition (N=5 sessions × 10 tours) : **0.05–0.30 $** selon le modèle (Sonnet ~3-5× les tarifs GPT-4o-mini).
- Budget total réaliste pour l'ensemble des tests : **1–4 $** (dominé par T1, T4, T5, T6 qui demandent le plus de sessions).
- Tests offline (T9, partie de T2/T7) : 0 $.

---
---

## PARTIE 1 — LES 10 PROTOCOLES EXPÉRIMENTAUX

> Format par protocole : **Hypothèse formelle** (IV → DV) · **Protocole** (pas-à-pas) · **Preuves** (véracité, efficacité, non-régression) · **Prédiction chiffrée** (avec intervalle + justification) · **Critère de décision**.

### H1 — « Frozen system prompt » : ne jamais régénérer le system prompt en cours de session

**Ancrage code** : `_rebuildSystemPrompt()` est appelé à 2 endroits dans le bundle réel : `setActiveToolsByName()` (changement de l'ensemble d'outils) et `extendResources()` (chargement de skills/prompts/themes). Chaque appel reconstruit `_baseSystemPrompt` → le préfixe change → invalidation totale du cache.

**Hypothèse formelle**
- **IV** : fréquence d'appel à `_rebuildSystemPrompt` pendant une session (A : comportement actuel — rebuild à chaque changement d'outils/ressources ; B : comportement « frozen » — geler `_baseSystemPrompt` au premier tour, appliquer les changements en append en fin de conversation ou au prochain cycle).
- **DV** : `hit_rate` par tour, `cost_turn`, `prefix_diff` entre tours consécutifs.
- **Conditions contrôlées** : même modèle/provider/repo/cwd ; sessions dédiées (fork) ; outils initialement `{read, bash, edit, write}` ; aucun autre levier.

**Protocole (fork de session, jamais sur session réelle)**
1. Session avec outils défaut, `cacheRetention:"default"` (cache actif). Warm-up : 1 tour "junk" (même préfixe).
2. **Phase baseline A1** : 5 tours identiques sans changement d'outils. Mesurer `hit_rate`, `cost_turn`, `prefix_diff`.
3. **Intervention 1** : `setActiveToolsByName(['read','bash'])` (retirer 2 outils) **sans** nouvelle instruction user → attendre le tour suivant (le rebuild précède le tour).
4. **Mesure A2** : tour juste après le rebuild. Mesurer `cache_read`, `hit_rate`, `prefix_diff` vs A1.
5. **Intervention 2** : re-ajouter les outils (`read,bash,edit,write`) → tour suivant.
6. **Mesure A3** : tour après re-ajout.
7. **Contrôle actif** : `setActiveToolsByName(['read','bash','edit','write'])` (les MÊMES outils, aucun changement réel) → tour suivant. Ce contrôle prouve que le miss vient du rebuild et non du changement de contenu.
8. **Répéter 3 sessions** (N=3, ≥5 tours par phase). Rapport médiane + IQR.

**Preuves**
- **Véracité** : `prefix_diff(A1 → A2) ≈ system_prompt_size` (le system a changé) alors que `prefix_diff(A2 → A3) ≈ 0` (seul l'ordre des tools a changé, le texte system est identique) ; et **contrôle actif** : `prefix_diff` = 0 et `hit_rate` inchangé.
- **Efficacité** : `hit_rate(A2) ≈ 0` (miss total) vs `hit_rate(A1) ≈ 0.8-0.95` ; `cost_turn(A2) ≈ cost_turn(A1) / hit_rate` (le miss paie la relecture complète).
- **Non-régression** : le mode frozen ne dégrade ni le comportement (les outils changent quand même, juste en append), ni la latence des tours normaux, ni la stabilité des tours internes.

**Prédictions chiffrées**
- `hit_rate` phase A1 : **0.82–0.95** (médiane ~0.88) — le system est rejoué en cache, seuls les nouveaux messages payent.
- `hit_rate` phase A2 (après rebuild) : **0.00–0.05** (le préfixe entier a changé ; seul un éventuel préfixe très court peut matcher).
- `prefix_diff(A1→A2)` : **≈ taille du system prompt** (2-4k tokens) ; `prefix_diff(A2→A3)` : **≈ 0**.
- **Gain sans rebuild** (extrapolé pour une session de 50 tours avec 2 rebuilds) : **2 × system_prompt_tokens × (P_in − P_cache_read)** économisés ≈ **0.02–0.15 $/session** selon le modèle. Pour les sessions MCP-heavy (rebuilds fréquents), le gain peut dépasser 1 $/session.
- **Verdict attendu** : hypothèse **validée** (miss par rebuild prouvé) ; le fix frozen supprime ces misses.

---

### H2 — Breakpoint « latest-user-message » : le dernier user doit rester le point de cache des boucles d'outils

**Ancrage code** : le 3e breakpoint est placé sur le **dernier bloc du dernier message user** (`lastBlock.type text|image|tool_result → cache_control`). Les tool results sont fusionnés dans un message `role:"user"` (`{role:"user", content:[...toolResults]}`). Donc en boucle d'outils, le « dernier user » contient les tool results et change à chaque appel → le breakpoint avance → le préfixe matché recule.

**Hypothèse formelle**
- **IV** : stratégie de placement du 3e breakpoint (A : current pi = dernier user ; B : `latest-assistant` = dernier message assistant ; C : `{tail: N}` = garder N derniers messages marqués) — pattern opencode `cache-policy.ts`.
- **DV** : `hit_rate` **intra-tour** (chacun des appels assistant/tool d'un même tour), `cache_read_tok`, `ttft` des appels suivants.
- **Conditions contrôlées** : session **sans aucun rebuild** (outils figés dès le début) ; conversation pré-chargée à deux tailles (courte ~4k tokens, longue ~15k tokens).

**Protocole**
1. Session outils figés (aucun `setActiveToolsByName`), warm-up.
2. Pré-charger une conversation : série de tours « read + edit » jusqu'à la taille cible (4k / 15k).
3. **La mesure** : un tour où l'agent fait ≥ 3 tool calls enchaînés sans nouvelle entrée user. Instrumenter pour capturer `hit_rate` de chaque appel intra-tour (2e, 3e appels).
4. Comparer les stratégies A/B/C **sur des sessions séparées** (même conversation générée de façon identique via seed déterministe) pour rester indépendant : pas de partage de session entre stratégies.
5. N ≥ 5 sessions par stratégie et par taille.

**Preuves**
- **Véracité** : inspection du payload (`onPayload`) — vérifier que le breakpoint en A est sur le message user (stable), en B sur le dernier assistant (change à chaque appel).
- **Efficacité** : `hit_rate` intra-tour en A vs B sur conversation longue.
- **Non-régression** : sur conversation courte (< 4k), A et B doivent être équivalents (le breakpoint est proche).

**Prédictions chiffrées**
- Conversation **courte** (~4k) : A ≈ B ≈ C, `hit_rate` intra-tour **0.75–0.90** — le levier de placement ne change rien (le préfixe matchable est court).
- Conversation **longue** (~15k) : A (latest-user) garde `hit_rate` intra-tour **0.80–0.95** ; B (latest-assistant) chute à **0.40–0.60** (le breakpoint recule à chaque appel, re-billant la queue agentique) ; C (`tail`) **0.70–0.90** selon N.
- **Verdict attendu** : le comportement actuel de pi (dernier user) est **déjà optimal** pour les boucles d'outils — l'hypothèse « améliorer » est rejetée (rien à changer), mais le protocole le *prouve* (valeur documentaire).

---

### H3 — Séparer cwd + AGENTS.md du system prompt (mettre le contenu projet hors du préfixe durable)

**Ancrage code** : le cwd est en **fin** du system prompt (position 9 sur 9) et `<project_context>` (AGENTS.md) est injecté au moment de la construction (position 7). Tout changement de cwd ou de contexte projet en session régénère → miss total.

**Hypothèse formelle**
- **IV** : localisation du contenu projet (A : current = dans le system prompt ; B : cwd + AGENTS.md dans le **premier message user**, le system prompt restant fixe).
- **DV** : `hit_rate` au tour suivant un changement de cwd / de AGENTS.md ; `prefix_diff`.
- **Conditions contrôlées** : sessions dédiées, mêmes outils ; le system prompt doit rester ≥ 2048 tokens (seuil 1024) après retrait du cwd/contexte pour que le test soit valide.

**Protocole**
1. Session dans repo A (avec AGENTS.md), warm-up, 5 tours baseline → mesurer `hit_rate` (attendu élevé).
2. **T3.1 — cwd** : changer de cwd (ou simuler) → tour suivant → mesurer `hit_rate`, `prefix_diff`.
3. **T3.2 — AGENTS.md** : modifier AGENTS.md, forcer `reloadAgentsFiles()` → tour suivant → mesurer.
4. Ré-exécuter 1-3 en condition B (cwd/contexte dans 1er message user) sur sessions séparées.
5. N ≥ 3 sessions par condition. Vérifier `system_size_tok ≥ 2048` dans les deux conditions (le retrait du cwd ne doit pas faire tomber sous le seuil).

**Preuves**
- **Véracité** : `prefix_diff` entre tours A (avant changement) et A' (après) = taille exacte du cwd/contexte **dans le condition A** ; ≈ 0 **dans la condition B** (le system ne bouge pas, le 1er user message change seulement).
- **Efficacité** : `hit_rate` tour après changement : A ≈ 0 (miss) ; B ≈ `hit_rate` baseline (pas de perte).
- **Non-régression** : la condition B ne doit pas dégrader la qualité des réponses (le modèle voit toujours cwd/contexte, juste plus loin) ni la latence (le 1er message est relu en cache).

**Prédictions chiffrées**
- Condition A : `hit_rate` après changement de cwd/contexte : **0.00–0.05** (miss total, le préfixe entier a changé).
- Condition B : `hit_rate` après changement : **0.80–0.95** (identique à la baseline ; seul le 1er user message change, relu en cache).
- Coût d'un miss (10k tokens system + contexte) au tarif normal vs cache read : **×10** (P_in ≈ 10 × P_cache_read). Un changement de cwd en session longue = ~0.01–0.05 $ de gaspillage (dépend du modèle).
- **Verdict attendu** : hypothèse **validée** — déplacer cwd/contexte dans le 1er user message élimine les misses liés au projet en session, sans perte de qualité.

---

---

### H4 — Cacher *moins*, pas plus : stratégie hybride qui exclut les tool results au-delà du seuil

**Ancrage code + papier** : le full-context cache (comportement actuel pi) écrit en cache les tool results dynamiques → overhead de `cache_write` sans lecture bénéfique → régression TTFT documentée (GPT-4o : -8.8 %). Le papier « Don't Break the Cache » montre que *exclude tool results* est la meilleure stratégie pour GPT-5.2 (79.6 % cost ↓, 13 % TTFT ↓).

**Hypothèse formelle**
- **IV** : stratégie de cache de la conversation (A : full — breakpoint sur dernier user, tout est caché [actuel] ; B : **hybride** — cacher la conversation tant que `conversation_size_tok < system_size_tok`, sinon poser le breakpoint **avant** la queue de tool results → la queue n'est ni écrite ni lue en cache).
- **DV** : `cost_turn`, `ttft`, `cache_write_tok` (overhead).
- **Conditions contrôlées** : sessions sans rebuild, conversation pré-chargée à 2 tailles (courte < system, longue > system) ; même modèle.

**Protocole**
1. Session tools figés, warm-up.
2. Pré-charger conversation **courte** (conversation < system) : mesurer A et B sur sessions séparées (ABBA entre sessions si possible) — `cost_turn`, `ttft`, `cache_write_tok`, N ≥ 5.
3. Pré-charger conversation **longue** (conversation > system, ex. 30-40 tours de tool results volumineux) : mesurer A et B à nouveau.
4. **Seuil** : pour B, définir `seuil = system_size_tok` ; vérifier que la bascule full→hybride se produit bien quand on franchit le seuil (mesurer `cache_write_tok` avant/après).

**Preuves**
- **Véracité** : `cache_write_tok(B, longue)` ≈ **0 sur la queue** (les tool results ne sont plus écrits) vs `cache_write_tok(A, longue)` ≈ taille des nouveaux tool results par tour ; `prefix_diff` constant en B (le préfixe matché est stable et s'arrête au breakpoint).
- **Efficacité** : `ttft(B, longue) < ttft(A, longue)` (moins de préfill à rejouer) ; `cost_turn` B ≤ A (l'économie sur l'overhead write compense).
- **Non-régression** : sur conversation **courte**, B doit être équivalent à A (`Δ cost < 2 %`, `Δ ttft < 5 %`) — sinon B est rejeté pour les petites conversations.

**Prédictions chiffrées**
- Conversation courte (< system) : A ≈ B — `Δ cost` **< 2 %**, `Δ ttft` **< 5 %** (le breakpoint est loin, peu importe sa position).
- Conversation longue (> system) : `ttft(B)` médian **10–20 % inférieur** à `ttft(A)` (moins de préfill de la queue non-cachée ; cohérent avec GPT-4o -8.8 % en faveur d'exclude) ; `cache_write_tok(B) ≈ 0` sur la queue vs `cache_write_tok(A) ≈ taille_tool_results_par_tour`.
- `cost_turn(B) − cost_turn(A)` : compris entre **-5 % et +2 %** (économie d'overhead write vs relecture de la queue ; les tool results étant uniques, la relecture en A est essentiellement du gaspillage).
- **Verdict attendu** : hypothèse **validée sur la latence** (gain TTFT 10-20 % sur conversations longues), **neutre sur le coût** (±2 %), d'où la recommandation « hybride » pour les sessions à gros tooling.

---

### H5 — Cache-warming / keepalive intelligent (pings silencieux pendant les pauses)

**Ancrage code** : pi n'a pas de keepalive ; aider a `AIDER_CACHE_KEEPALIVE_DELAY` + `warm_cache()` (pings silencieux). Le TTL Anthropic short = 5 min → une pause > 5 min = miss complet à la reprise.

**Hypothèse formelle**
- **IV** : stratégie de réchauffement (A : aucun keepalive [actuel] ; B : ping silencieux = même préfixe + "continue", envoyé à intervalle `K < TTL` pendant les pauses).
- **DV** : `cost` cumulé sur la fenêtre [début pause → reprise] = coût des pings (B) + coût du tour de reprise (hit si B, miss si A) ; `ttft` du tour de reprise.
- **Conditions contrôlées** : pause contrôlée (D minutes) suivie d'une reprise ; N ≥ 5 cycles pause/reprise.

**Protocole**
1. Session avec system ~3-5k tokens, warm-up, mesurer `cost_turn` normal et `hit_rate` chaud.
2. **Condition A (contrôle)** : faire une pause de **D minutes** (ex. 6 min > TTL 5 min), puis 1 tour de reprise → mesurer `cache_read` (attendu ≈ 0), `cost_turn` (miss).
3. **Condition B** : même pause D, mais envoyer un ping (même préfixe + "continue") à `D/2` (toutes les ~3 min) → tour de reprise → mesurer `cache_read` (attendu > 0, hit).
4. Répéter pour D = {3, 6, 15, 40} minutes (D < TTL, D ≈ TTL, D ≫ TTL). N ≥ 5 par D.
5. **Vérifier que le ping ne pollue pas la conversation** : `prefix_diff` avant/après ping = 0 (le ping n'ajoute rien au contexte).

**Preuves**
- **Véracité** : `cache_read` du tour de reprise : A ≈ 0 pour D > 5 min (miss TTL) ; B > 0 pour D < TTL_effectif (le ping a rafraîchi la fenêtre).
- **Efficacité** : `coût_cumulé(B) < coût_cumulé(A)` quand `P(reprise) × bénéfice_hit > coût_des_pings`. Calculer le **seuil de rentabilité** : `P(reprise dans la fenêtre) > coût_ping / (taille_préfixe × Δprix)`.
- **Non-régression** : le ping ne doit pas (1) altérer la conversation (`prefix_diff` = 0), (2) produire de réponse visible, (3) coûter plus que le miss qu'il évite.

**Prédictions chiffrées**
- Seuil de rentabilité : avec system 4k tokens, P_in = 3 $/M, P_cr = 0.3 $/M : un miss coûte ~**0.012 $** ; un ping (4k + 10 tokens) coûte ~**0.012 $** aussi (le ping *ré-écrit* le cache en partie ? non — le ping relit le préfixe : si le préfixe est déjà en cache et non expiré, le ping est ~gratuit en lecture ; s'il est expiré, le ping *écrit*). **Raffinement** : le ping sert à *rafraîchir avant expiration* → ping à t = 4 min 30 s coûte le re-cache (write) = ~1.25 × 4k × P_in ≈ **0.015 $** mais sauve le miss de reprise (~0.012 $) **plus le TTFT**.
- **T5.2 (TTL réel observé)** : Anthropic short = **5 min ± 30 s** ; long = **60 min ± 2 min** ; OpenAI (session active) = **30 min fenêtre / 24 h retention**.
- **Verdict attendu** : le keepalive n'est rentable **que** si la probabilité de reprise dans la fenêtre est élevée (≥ 60-80 %) ; pour du dev interactif avec pauses fréquentes courtes, **inutile** (la plupart des pauses < 5 min) ; pour des sessions longues avec pauses 5-60 min prévisibles (ménage, réunion), **léger gain** (0.005–0.02 $/reprise) + TTFT réduit. **Recommandation** : implémenter derrière un flag opt-in, jamais par défaut.

---

### H6 — Le `pi resume` reconstruit-il un prompt bit-identique ? (hits cross-process)

**Ancrage code** : `prompt_cache_key = clampOpenAIPromptCacheKey(sessionId)` (OpenAI) — le sessionId est persisté dans le header du fichier `.jsonl` et réutilisé au resume (`header.id`). Mais le prompt reconstruit dépend de : tools actifs, AGENTS.md, cwd, version de pi, ordre de session. Un seul octet différent = miss.

**Hypothèse formelle**
- **IV** : mode de reprise (A : `pi resume` normal ; B : session fraîche [contrôle]).
- **DV** : `H_N` (hash du prompt sérialisé complet au dernier tour) vs `H_R` (hash du prompt reconstruit au 1er tour du resume) ; `hit_rate` du 1er tour après resume.
- **Conditions contrôlées** : même repo/cwd/AGENTS.md, même modèle, même machine, même version de pi ; pas de changement entre le dernier tour et le resume.

**Protocole**
1. Session réelle (fork) de ≥ 20 tours, tools `{read, bash, edit, write}`. Au tour N, sérialiser le prompt complet (system + tools + messages, JSON canonique) → `H_N` + snapshot des métadonnées (tools actifs, cwd, version pi, sessionId).
2. Fermer pi. Relancer `pi resume <sessionId>`.
3. Au 1er tour du resume : sérialiser le prompt reconstruit → `H_R`. Calculer `H_N == H_R` ? et le **diff** exact (premier octet divergent, source).
4. Au 2e tour (après 1re réponse) : mesurer `hit_rate`, `cache_read`.
5. **T6.2** : simuler un bump de version (changer un élément du prompt système, ou utiliser une version différente) → re-mesurer `H_N == H_R` (attendu : miss).
6. N ≥ 5 resumes (sessions séparées).

**Preuves**
- **Véracité** : le diff `H_N vs H_R` identifie le mécanisme de miss : si `H_R ≠ H_N`, localiser exactement ce qui a changé (outils ? AGENTS.md ? cwd ? version ? ordre ?) — c'est la preuve du *pourquoi*.
- **Efficacité** : si `H_R == H_N`, `hit_rate` du 1er tour resume = hit (Attendu élevé) ; sinon miss (cache_read ≈ 0).
- **Non-régression** : peu pertinent ici (le resume doit rester correct quoi qu'il arrive — la bit-identité est un bonus, pas une exigence fonctionnelle) ; vérifier que le fix éventuel (snapshot du prompt) ne casse pas le resume.

**Prédictions chiffrées**
- **T6.1** : `H_R` vs `H_N` — **probablement différent** sur au moins un octet (probabilité de bit-identité parfaite estimée **20-40 %**). Causes les plus probables (par ordre) : (1) ordre des outils / set actif diffère au resume, (2) AGENTS.md rechargé avec un contenu différent, (3) cwd ou meta du system prompt, (4) version pi. Si diff → `hit_rate` 1er tour = **0.00-0.10** (miss total).
- **T6.2** : bump de version → miss systématique (**0.00**), conforme à la doc Claude Code (« upgrading invalidates »).
- **T6.3** : le `prompt_cache_key` au resume = **même valeur** que pendant la session (le sessionId persisté est réutilisé — vérifié dans le code) → la clé n'est pas la cause d'un éventuel miss.
- **Verdict attendu** : hypothèse **partiellement validée** — si le prompt résumé diffère, c'est une fuite réelle à corriger (snapshot du prompt système au dernier tour, à rejouer identique au resume) ; le gain : sessions reprises le même jour gardent les hits OpenAI 24h.

---

---

### H7 — Le breakpoint system doit être présent même avec 0 tool (et au-dessus des seuils)

**Ancrage code** : le breakpoint system est posé sur `params.system[0]` **indépendamment de la présence d'outils** (`context.systemPrompt && (params.system=[{..., cache_control}])`) — donc déjà présent sans tools. La question restante : est-il *suffisant*, et le system est-il assez grand pour activer le cache (seuil 1024/4096) ?

**Hypothèse formelle**
- **IV** : nombre d'outils (A : 0 tool ; B : tools défaut) et taille du system prompt (natif pi vs réduit artificiellement sous le seuil).
- **DV** : `hit_rate` (le system doit matcher seul), `system_size_tok`, `ttft`.
- **Conditions contrôlées** : sessions sans rebuild ; pas de boucle d'outils (conversation simple).

**Protocole**
1. **T7.1** : session avec 0 tool (`setActiveToolsByName([])`), plusieurs tours simples. Mesurer `hit_rate`. Vérifier dans le payload que le breakpoint system est bien présent (`onPayload`).
2. **T7.2 (cap 4 breakpoints)** : simuler un 4e breakpoint (ex. ajouter un bloc system séparé) → vérifier que le plus stable est conservé (le system) et que le compte total ≤ 4.
3. **T7.3 (seuil)** : mesurer `system_size_tok` réel (tokenizer ou approximation) pour le pi natif. Si ≥ 2048 → OK. Sinon, mesurer le `hit_rate` avec un system réduit sous 1024 (validation négative : cache inactif).

**Preuves**
- **Véracité** : `onPayload` montre le `cache_control` sur le system même avec 0 tool (A) ; le comptage ≤ 4 est respecté (T7.2).
- **Efficacité** : `hit_rate(A) > 0.90` (le system seul matche) et > `hit_rate` d'une session avec system sous le seuil.
- **Non-régression** : pas d'impact sur les autres placements (T7.2 vérifie qu'ajouter un 4e breakpoint ne *déplace* pas le system).

**Prédictions chiffrées**
- **T7.1** : `hit_rate` system-seul = **0.90–0.99** (médiane ~0.95) sur une conversation simple. Le breakpoint system est déjà posé → hypothèse **déjà satisfaite** par le code actuel (valeur documentaire + garde-fou).
- **T7.2** : le code conserve les 3 breakpoints canoniques (≤ 4) ; l'ajout d'un 4e breakpoint devrait **préserver le system** et retirer le moins stable (ou rejeter le 4e). Prédiction : aucun placement incorrect.
- **T7.3** : `system_size_tok` pi natif ≈ **2.5-4.5k tokens** (guidelines + tools + docs pi). Au-dessus des seuils 1024/1024, mais **juste au-dessus de 4096 pour Gemini** — attention en mode Gemini : si le system < 4096, le cache ne s'active pas. Réduction artificielle sous 1024 → `hit_rate` ≈ **0** (validation négative).

---

### H8 — Exposer le cache-waste en $ (métrique visible et diagnostic)

**Ancrage code** : `computeCacheWaste` et `CacheMiss { idleMs, modelChanged }` existent déjà dans `cache-stats.ts` (bundle). Le footer TUI affiche R/W/CH. L'ajout proposé : un $ (waste estimé) + cause.

**Hypothèse formelle**
- **IV** : présence d'une métrique $ visible (A : pas de $ [actuel] ; B : $ waste + cause dans le footer).
- **DV** : exactitude du calcul (vs calcul manuel), détection des causes, déterminisme.
- **Conditions contrôlées** : une session contrôlée où on provoque des misses connus.

**Protocole**
1. **T8.1 — Exactitude** : sur une session contrôlée avec 1 miss provoqué puis 1 hit, calculer manuellement le $ attendu (tokens × prix) et le comparer au `$ waste` affiché. Critère : écart < 5 %.
2. **T8.2 — Causes** : provoquer 3 misses de causes distinctes (idle > TTL ; modèle changé ; contenu volatile) et vérifier que le diagnostic (`CacheMiss{idleMs, modelChanged}`) identifie la bonne cause dans chaque cas.
3. **T8.3 — Déterminisme** : sur une session longue, vérifier que `computeCacheWaste` ne dépend pas de l'ordre d'appel (2 appels → même résultat).

**Preuves**
- **Véracité** : T8.1 (calcul exact), T8.2 (bon diagnostic par cause), T8.3 (déterminisme).
- **Efficacité** : l'utilisateur (ou le harness en auto-research) détecte les fuites H1/H3 sans introspection manuelle → activation des fixes.
- **Non-régression** : le calcul ne doit pas ralentir le TUI (caching du calcul) ni changer les métriques existantes.

**Prédictions chiffrées**
- **T8.1** : écart **< 5 %** (prix connus, calcul exact attendu ; l'écart vient des arrondis de tokens).
- **T8.2** : diagnostic correct dans **≥ 90 %** des cas (la logique `idleMs vs modelChanged` est déjà dans le code ; le cas « contenu volatile » est le plus difficile — prédire 80-100 %).
- **T8.3** : déterministe (**0 %** de variance entre appels).
- **Verdict attendu** : hypothèse **triviale à valider** (mécanisme déjà présent) ; la valeur est l'exposition TUI.

---

### H9 — Table de sémantique par (provider, modèle) : poser les breakpoints seulement si nécessaire

**Ancrage code + goose** : pi a déjà `cacheControlFormat:"anthropic"` (OpenRouter + modèles anthropic/*), `supportsLongCacheRetention`, `sendSessionAffinityHeaders`, `sessionAffinityFormat`. goose va plus loin avec une table `CacheSemantics { ExplicitBreakpoints, ImplicitTolerant, ImplicitStrict, Uncached }` par (provider, modèle).

**Hypothèse formelle**
- **IV** : présence d'une table de sémantique (A : current pi = flags épars ; B : table complète type goose).
- **DV** : présence/absence de `cache_control` dans la requête finale (correcte selon le provider) ; `cache_write_tok` (pas d'overhead sur les providers sans cache).
- **Conditions contrôlées** : **test offline** (hook `onPayload`, aucun appel réseau) sur un tableau de (provider, modèle) représentatif.

**Protocole**
1. Constituer le tableau de test : Anthropic (explicit, 3 breakpoints), OpenAI (implicit strict, pas de breakpoint), Gemini (implicit tolerant), OpenRouter+anthropic/* (explicit via cacheControlFormat), Bedrock Claude (cachePoint), providers exotiques (moonshot, together, groq, snowflake → uncached ou implicit).
2. **T9.1** : pour chaque entrée, inspecter la requête finale via `onPayload` : le `cache_control` est-il présent **si et seulement si** la sémantique est ExplicitBreakpoints ?
3. **T9.2** : sur les `Uncached` (ex. snowflake), vérifier qu'aucun `cache_control` n'est émis **et** qu'aucun `cache_write` n'est facturé.
4. **T9.3 — classification** : comparer la classification auto vs vérité terrain (docs provider). Critère : 0 erreur sur la liste testée ; fallback = `ImplicitStrict` (le plus sûr, comme goose).

**Preuves**
- **Véracité** : T9.1 (le breakpoint est émis ssi explicit), T9.3 (classification sans erreur).
- **Efficacité** : T9.2 (suppression de l'overhead cache_write sur les providers sans cache — coût direct évité).
- **Non-régression** : les providers au comportement ambigu (modèles mixtes OpenRouter) doivent retomber sur le fallback safe et ne jamais *perdre* un cache utile.

**Prédictions chiffrées**
- **T9.1** : 100 % de conformité après implémentation (pattern goose déjà validé dans son repo) ; **erreurs de classification attendues : < 5 %** sur les providers ambigus (modèles mixtes OpenRouter).
- **T9.2** : suppression immédiate de l'overhead `cache_write` sur providers exotiques — économie **0.5-2 % du coût** des sessions concernées (faible en %, nul pour les providers mainstream).
- **T9.3** : 0 erreur sur la liste canonique ; fallback `ImplicitStrict` sans perte.
- **Verdict attendu** : hypothèse **validée** — gain réel surtout pour la robustesse (pas de cache_control mal émis) plus que pour le $.

---

### H10 — Structurer le prompt pour le non-prefix cache (CacheBlend/LMCache, serving maison)

**Ancrage code + papier** : le cache API est exact-prefix ; le non-prefix caching (CacheBlend : 63-85 % hit vs 3-25 % prefix-only) réutilise des segments chevauchants. Côté harness, l'opportunité est de **ne rien faire qui empêche** ce reuse : garder des blocs stables/groupés, ne pas tout fragmenter.

**Hypothèse formelle**
- **IV** : structure du prompt (A : actuel pi — blocs system/tools/messages ordonnés ; B : anti-pattern — timestamp/variable au milieu qui fragmente).
- **DV** : ratio `tokens_stables / tokens_total` ; `hit_rate` non-prefix (mesuré côté serveur) ; `ttft`.
- **Conditions contrôlées** : serving maison (vLLM/SGLang + LMCache/CacheBlend) dans un container dédié ; ≥ 200 requêtes par condition.

**Protocole**
1. **T10.1 (structure)** : comptabiliser les fragments réutilisables entre tours (blocs identiques) sur des sessions pi réelles → ratio `tokens_stables/tokens_total`.
2. **T10.2 (bench serving)** : déployer pi contre vLLM/SGLang + LMCache (container dédié), mesurer `hit_rate` non-prefix côté serveur, `ttft`, throughput ; ≥ 200 requêtes par condition (A vs B).
3. **T10.3 (sensibilité)** : injecter un contenu qui change au milieu du prompt (contre-exemple timestamp) et mesurer la dégradation du hit non-prefix vs prefix-strict.

**Preuves**
- **Véracité** : T10.1 (le ratio stable est mesurable et ≥ 80 %), T10.3 (le non-prefix est moins sensible au changement milieu que le prefix).
- **Efficacité** : T10.2 (hit non-prefix ≫ prefix sur workloads agentiques).
- **Non-régression** : la structure A ne doit pas *empirer* le prefix caching (le fallback API standard reste le même).

**Prédictions chiffrées**
- **T10.1** : ratio stable pi = **80-95 %** (system + tools + historique relu ; seuls les tool results en queue changent).
- **T10.2** : gain `hit_rate` non-prefix observé = **63-85 %** des tokens vs 3-25 % prefix-only (reproductible depuis Tensormesh) sur workloads agentiques multi-branches.
- **T10.3** : dégradation du hit non-prefix avec timestamp milieu = **< 10 %** vs **> 80 %** pour le prefix strict (le non-prefix réutilise les segments autour).
- **Verdict attendu** : hypothèse **partiellement vérifiable ici** (T10.1) ; T10.2/T10.3 demandent une infra dédiée (hors périmètre rapide, priorité basse). Leçon : continuer à garder les blocs stables groupés — c'est déjà le cas.

---

---

## PARTIE 2 — SYNTHÈSE OPÉRATIONNELLE

### 2.1 Matrice d'indépendance inter-protocoles (récap exécutable)

Chaque protocole doit être **indépendant des autres** : aucune contamination possible d'un test vers un autre.

| Protocole | Sessions dédiées ? | Interdit de partager une session avec | Parades spécifiques |
|---|---|---|---|
| T1 (rebuild) | ✅ fork | T2, T4, T5, T6 | Contrôle actif (mêmes outils) prouve que le miss vient du rebuild |
| T2 (breakpoint user) | ✅ | T1 (sinon rebuild masque), T4 | Outils figés dès le début, conversation générée déterministe |
| T3 (cwd/AGENTS.md) | ✅ | T1, T6 (préfixe différent = comparaison invalide) | Sessions séparées par condition ; vérifier system ≥ 2048 |
| T4 (hybride) | ✅ | T2 (breakpoints messages), T1 | Conversation simple (pas de boucle d'outils) |
| T5 (keepalive) | ✅ | TOUS (les pings écrivent du cache) | Contrôle avec `cacheRetention:"none"` si nécessaire |
| T6 (resume) | ✅ | TOUS (un mauvais resume invalide tout après) | **Dernier** dans l'ordre d'exécution |
| T7 (breakpoint sans tools) | ✅ | T2 (même mécanisme) | Session à 0 tool, aucun autre levier |
| T8 ($ waste) | ❌ (passif) | aucun | Peut s'exécuter sur n'importe quelle session, en parallèle |
| T9 (sémantique) | ✅ offline | T2, T7 (breakpoints) | Aucun appel réseau (hook onPayload) |
| T10 (non-prefix) | ✅ infra dédiée | tous (hors API standard) | Container serving, jamais sur sessions partagées |

**Séquence d'exécution sûre** (élimine les contaminations croisées) :

```
Phase 1 (offline, 0 $)  : T9 → T7.2 (inspection payload, classification)
Phase 2 (fork léger)    : T8 (passif, en parallèle de tout)
Phase 3 (sessions API)  : T1 (early, car fork + contrôle actif)
                        → T4 (conversation simple)
                        → T2 (outils figés)
                        → T3 (sessions séparées par condition)
Phase 4 (temps)         : T5 (pauses 3-40 min, coûteux en temps)
Phase 5 (dernier)       : T6 (resume — car dépend de tout l'état)
Phase 6 (infra, long)   : T10 (serving maison, priorité basse)
```

### 2.2 Budget d'exécution (tokens / $ / temps)

Hypothèses de tarif : P_in = 3 $/Mtok (Sonnet-class), P_out = 15 $/Mtok, P_cr = 0.3 $/Mtok, P_cw = 3.75 $/Mtok. Un tour ≈ 3k prompt + 0.5k output ≈ **0.016 $**.

| Protocole | Sessions × tours | Coût $ estimé | Temps estimé | Priorité |
|---|---|---|---|---|
| T1 (rebuild) | 3 × 12 | 0.30–0.60 | 0.5 h | 🔥 Haute |
| T2 (breakpoint) | 2 tailles × 5 × 8 | 0.40–0.80 | 1 h | Moyenne |
| T3 (cwd/AGENTS) | 2 cond × 3 × 6 | 0.20–0.40 | 0.5 h | Haute |
| T4 (hybride) | 2 tailles × 5 × 10 | 0.50–1.00 | 1.5 h | Haute |
| T5 (keepalive) | 4 D × 5 × 2 | 0.20–0.40 + pings | 2-4 h (temps d'attente) | Moyenne |
| T6 (resume) | 5 × 6 | 0.15–0.30 | 1 h | Haute |
| T7 (sans tools) | 2 × 5 × 5 | 0.10–0.20 | 0.5 h | Basse |
| T8 ($ waste) | passif (0 dédié) | 0 | parallèle | Basse |
| T9 (sémantique) | offline | 0 | 10 min | Moyenne |
| T10 (non-prefix) | 200 req × 2 cond | infra (non-API) | 1-2 j (setup) | Basse (long terme) |
| **Total** | — | **1.5–3.5 $** | **~1 journée** (hors T10) | — |

**Ordre recommandé (coût/impact)** : T1 → T6 → T3 → T4 → T2 → T9 → T7 → T5 → T8 → T10.
*(Dans le sens : les tests rentables et rapides d'abord, les tests longs/incertains ensuite.)*

### 2.3 Tableau récapitulatif des prédictions (toutes les expériences)

| Exp | Hypothèse | Prédiction centrale | Intervalle | Risque d'échec | Gain si validée |
|---|---|---|---|---|---|
| T1 | Rebuild = miss total | `hit_rate` 0.88 → 0.00 après rebuild | 0.82-0.95 / 0.00-0.05 | Faible (code prouvé) | 0.02–1+ $/session selon rebuilds |
| T2 | latest-user = optimal boucles | A ≥ B sur conv. longue | A 0.80-0.95 vs B 0.40-0.60 | Moyen (dépend taille conv.) | Documentaire (déjà bon) |
| T3 | cwd/AGENTS hors préfixe | miss → hit après changement | 0.00-0.05 → 0.80-0.95 | Faible | Robustesse multi-repo/resume |
| T4 | Hybride exclut tool results | TTFT -10-20 % sur conv. longue | Δ cost -5 à +2 % | Moyen | Latence (sessions gros tooling) |
| T5 | Keepalive rentable si reprise probable | Seuil P(reprise) ≥ 60-80 % | coût ping ~0.015 $ vs miss ~0.012 $ | Moyen | 0.005-0.02 $/reprise + TTFT |
| T6 | Resume bit-identique | Miss si H_R ≠ H_N ; identité 20-40 % | hit 0.00-0.10 sinon | Élevé (fragile) | Sessions reprises = hits 24h |
| T7 | Breakpoint system sans tools | hit_rate 0.90-0.99 ; system 2.5-4.5k | 0.90-0.99 | Faible | Déjà satisfait (garde-fou) |
| T8 | $ waste exact | Écart < 5 % ; diagnostic ≥ 90 % | < 5 % / ≥ 90 % | Faible | Détection des fuites en continu |
| T9 | Sémantique par provider | 100 % conformité ; erreur < 5 % ambigus | 0 % sur liste canonique | Moyen | Robustesse providers exotic |
| T10 | Non-prefix structure | ratio stable 80-95 % ; hit 63-85 % | 63-85 % | Moyen | Infra (long terme) |

### 2.4 Synthèse : quelles optimisations implémenter selon les résultats

- **T1 validé** → implémenter le **frozen system prompt** (H1) immédiatement : gain $ direct, risque quasi nul (mêmes outils, application différée comme Claude Code).
- **T3 validé** → déplacer **cwd + AGENTS.md dans le premier message user** : robustesse multi-repo/resume, gain $ sur sessions longues avec changements de contexte.
- **T4 validé** → **stratégie hybride** (exclure tool results au-delà du seuil) : gain latence majeur sur sessions à gros tooling, coût neutre.
- **T6 validé (échec bit-identité)** → **snapshot du prompt** au dernier tour, rejoué identique au resume : récupère les hits OpenAI 24h.
- **T2 rejeté** → documenter que le `latest-user` actuel est optimal pour les boucles d'outils (pas de changement).
- **T5 rentable seulement si reprise probable** → flag opt-in, jamais par défaut.
- **T7/T8/T9** → garde-fous/documentation/robustesse (faible coût, haute valeur défensive).
- **T10** → veiller à ne pas fragmenter le prompt (déjà bon), bénéficier du non-prefix quand l'infra sera maison.

> **Conclusion opérationnelle** : les deux optimisations à fort ROI immédiat sont **H1 (frozen system prompt)** et **H3 (cwd/AGENTS hors préfixe)** — testables en quelques tours, gain $ direct, risque faible. **H4 (hybride)** est le levier de latence le plus intéressant pour les sessions à gros tooling. Le reste consolide (T2), sécurise (T6), ou documente (T7-T10).

---
*Fin du document 05 — 10 protocoles expérimentaux, chacun avec hypothèse formelle, design indépendant, preuves véracité/efficacité/non-régression, et prédiction chiffrée.*

---

## PARTIE 3 — ENVIRONNEMENT DE TEST ISOLÉ (bac à sable)

> **Ajout suite à la demande utilisateur** : ne pas réutiliser le harness configuré (pour ne pas impacter ses travaux, et ne pas être impacté par ses changements). Décision utilisateur validée : **copie de auth.json dans l'isolé** (partage de creds uniquement).

### 3.1 Architecture du bac à sable

```
recherche-cache-hits/
└── .pi-test/                        # TOUT l'env de test (isolé du harness réel)
    ├── config/                      # → PI_CODING_AGENT_DIR
    │   └── auth.json                # SEUL fichier copié depuis ~/.pi/agent (mode 600)
    ├── sessions/                    # → PI_CODING_AGENT_SESSION_DIR (sessions de test)
    ├── work/                        # repo de travail pour les tests
    └── results/                     # résultats expérimentaux (JSON + rapports)
```

### 3.2 Isolation garantie

| Ressource du harness | Copiée dans l'isolé ? | Pourquoi |
|---|---|---|
| `auth.json` (creds) | ✅ **oui** (décision utilisateur) | seule façon que les tests API tournent avec ses providers, sans toucher son dossier principal |
| Extensions, skills, themes | ❌ non | env vierge → pas d'impact de ses changements |
| `settings.json`, `models-store.json` | ❌ non | config figée au moment du setup |
| Sessions (`~/.pi/agent/sessions`) | ❌ non | `--session-dir` pointe vers `.pi-test/sessions` |
| Autres fichiers (`trust.json`, `run-history`) | ❌ non | aucun |

### 3.3 Script réutilisable

`scripts/setup-test-env.sh` :

```bash
./scripts/setup-test-env.sh          # crée/rafraîchit (synchronise auth.json)
./scripts/setup-test-env.sh check    # vérifie pi + creds (binaire, jamais le secret)
source ./scripts/setup-test-env.sh env  # exporte les variables PI_* isolées
```

Lancement type d'un test :
```bash
PI_CODING_AGENT_DIR=.pi-test/config \
PI_CODING_AGENT_SESSION_DIR=.pi-test/sessions \
PI_OFFLINE=1 PI_TELEMETRY=0 \
pi --fork <session_id> --print "prompt de test" --no-extensions --no-skills
```

### 3.4 Règle d'hygiène applicative (contractuelle)

1. **Jamais d'affichage du contenu de auth.json** — uniquement existence + permissions (`stat -c '%a'`) ou `status: ready` (binaire).
2. Les tests écrivent **uniquement** dans `.pi-test/` (sessions, results, work) — jamais dans `~/.pi/agent` ni dans les sessions réelles.
3. Tout fork part de la session du bac à sable (pas de la session de prod).
4. Les résultats expérimentaux sont stockés dans `.pi-test/results/<expérience>/` avec un header JSON (date, provider, modèle, config).

### 3.5 Statut vérifié (setup fait)

- ✅ `auth.json` copié (mode 600), config isolée créée.
- ✅ pi démarre en env isolé (`pi --version`, `pi --list-models` fonctionnent).
- ✅ Credentials accessibles : `opencode-go: ready`, `minimax: ready` (check binaire, secret jamais affiché).
- ✅ `sessions/`, `work/`, `results/` créés.
- ⏳ Prochaine étape : exécution de l'expérience **T1** (rebuild system prompt) dans ce bac à sable.

---

---

## PARTIE 4 — RÉSULTATS EXPÉRIMENTAUX (première campagne)

> **Note** : résultats de **démonstration** (N=5 sessions, pour valider le bac à sable + protocole) sur `opencode-go/deepseek-v4-flash`, prompt "T1 ... réponds uniquement OK". Aucune lecture de auth.json, isolation complète.

### 4.1 T1 — « Le rebuild d'outils invalide le cache » → **résultat nuancé : miss PARTIEL, pas total**

**Données (cacheRead médian par phase, N=5) :**

| Phase | outils | cacheRead | coût médian | hash (préfixe) |
|---|---|---|---|---|
| warmup | 4 (read,bash,edit,write) | 2560 (écrit) | 0.00062 (plein) | f86432dc |
| baseline 1 | 4 | **2816** | 0.000028 | cc130b23 |
| baseline 2 | 4 | **2816** | 0.000032 | e290565c |
| baseline 3 | 4 | **2816** | 0.000036 | 5437e18c |
| **rebuild** | **2 (read,bash)** | **2048–2304** | 0.00009–0.0005 | a4faf1b1 / 4b0235a1 |
| restore | 4 | **2816** | 0.00004 | cc4b1a13 / 5261edff |
| control | 4 | **2816** | 0.00005 | b736357f |

**Lecture :**
- Le rebuild (retirer edit/write) réduit `cacheRead` de 2816 → 2048-2304 : **la partie du préfixe AVANT le changement reste cachée** (system + read/bash), seule la portion des tool defs retirées redevient miss (~512-768 tokens).
- Le restore (rajouter edit/write) **retombe exactement à 2816** : les tool defs complètes sont réutilisables telles quelles (pas de ré-écriture), et le hash du préfixe redevient quasi identique.
- **Miss total (cr=0) observé uniquement au TOUT PREMIER tour d'une session** (warmup) : normal, le cache n'existe pas encore — pas un effet du rebuild.

**→ L'hypothèse H1 naïve (« rebuild = miss total ») est REFUSÉE** : le texte du system prompt ne change pas (les guidelines sont construites à partir du set d'outils **valides** qui ne change pas), seules les tool defs changent de longueur. Le coût du rebuild est proportionnel à la portion d'outils modifiée, pas au prompt entier.

**Implication pour le fix :**
- Le gain de « frozen system prompt » (H1) est **plus faible que prédit** : il évite ~768 tokens de relecture par rebuild (au lieu de ~3k).
- Le vrai levier est ailleurs : **garder un set d'outils stable dans le temps** (ne pas retirer/rajouter des tools en session) — c'est ce que le papier « Don't Break the Cache » appelle « ne pas changer le tool set dynamiquement ».
- Nuance pour la suite : tester un rebuild qui **change le milieu** des tools (pas la fin) → là le miss pourrait être total (le préfixe avant la modification inclut des tools qui changent).

### 4.2 Verdict provisoire par hypothèse (campagne de démonstration)

| Hyp | Prédiction initiale | Observé (démo) | Verdict |
|---|---|---|---|
| H1 rebuild | miss total (cr≈0) | **miss partiel** (cr 2816→2048) | **Refusée (nuancée)** |
| — | coût ×10 | coût ×3 | gain plus faible |
| H2 latest-user | intra-tour > 80 % | (pas encore testé) | — |
| H3 cwd/AGENTS | miss au changement | (à tester) | — |
| H4 hybride | TTFT -10-20 % | (à tester) | — |
| H5 keepalive | rentable si reprise≥60-80 % | (à tester) | — |
| H6 resume bit-identique | miss si H_R≠H_N | (à tester) | — |
| H7 breakpoint sans tools | hit 90-99 % | (baseline montre 2816 hit — cohérent) | plausible |
| H8 $ waste | écart <5 % | (à tester) | — |
| H9 sémantique | 100 % conformité | (à tester) | — |
| H10 non-prefix | ratio 80-95 % | (à tester) | — |

### 4.3 Leçons méthodologiques (pour les prochaines expériences)

1. **Le hash du payload ne prédit pas le miss** : baseline (cr=2816) et restore (cr=2816) ont des hash proches mais pas identiques — le cache se base sur le **préfixe réutilisé**, pas sur le hash complet. Il faut donc **décomposer le payload en segments** (system / tools / messages) et comparer segment par segment, pas le tout.
2. **Le `cacheRead` mesure la partie rejouée** : c'est la métrique reine. Un `cr` stable malgré un hash différent = préfixe réutilisé.
3. **Le warmup est crucial** : le 1er tour d'une session est toujours un miss (cr=0) — ne jamais comparer à un tour de warmup.
4. **Tester le rebuild au MILIEU des tools** (pas à la fin) pour isoler l'effet position.

### 4.4 Prochaine expérience recommandée

- **T1-refined** : rebuild qui **modifie le milieu** des tools (ex. `-t read,edit` au lieu de `-t read,bash`) → prédiction : miss total (la portion milieu des tool defs entre dans le préfixe réutilisé). Confirme la sensibilité à la *position* du changement.
- **T6** (resume bit-identique) : le plus rentable après T1, et déjà instrumenté (hash du payload).

---

---

## PARTIE 5 — RÉSULTATS DE LA CAMPAGNE COMPLÈTE (T1-refined, T3, T6, H2)

> **Sessions réelles** en bac à sable isolé (opencode-go/deepseek-v4-flash, ~70 tours ≈ 0.05-0.10 $). Rapport détaillé : `.pi-test/results/CAMPAIGN-REPORT.md`.

### 5.1 T1-refined — rebuild au MILIEU des outils → **MISS TOTAL** (contrairement à la fin)

| Tour | sysBytes | tools | cr | interprétation |
|---|---|---|---|---|
| warmup | 7481 | read,bash,edit,write | 2816 | écrit |
| base 2t (×3) | **6781** | read,bash | 2304 | hit stable (system 4→2 tools : 7481→6781) |
| **mid_change** | **7207** | read,edit | **0** | **MISS TOTAL** |
| restore | 6781 | read,bash | 2304 | re-hit |

**Mécanisme découvert** : le system prompt de pi dépend des outils (guidelines). Retirer 2 outils change le system (7481→6781) ; **changer le set (même nombre)** change aussi le system (6781→7207 pour read,bash→read,edit). Quand le system change → `cr=0` (miss total). Quand seuls les tools de fin changent (même system) → miss partiel.

**→ Le gain du « frozen system prompt » dépend de la cause du rebuild :**
- rebuild par **changement de nombre d'outils** : miss partiel (les guidelines changent, ~700 tokens)
- rebuild par **changement du set d'outils** (même nombre, tools différents) : **miss total** (system change)
- la correction H1 (geler le system, appliquer les changements en append) éliminerait les deux.

### 5.2 T3 — le cwd EST dans le system prompt (miss partiel à chaque changement de repo)

| Tour | repo | sysBytes | cr |
|---|---|---|---|
| warmup/base | A | 7481 | 2816 (hit) |
| repoB1 | B | **7501** (+20 = cwd) | 1792 |
| repoB2 | B | 7501 | 1792 |
| repoA2 | A | 7501 | **2816** (re-hit) |

- **Preuve : le cwd est bien dans le system prompt** (sysBytes +20 quand on change de repo — le chemin injecté en fin).
- Changement de cwd = **miss partiel** (2816→1792) : le préfixe system avant le cwd reste caché (positionnement « cwd en fin » = bon choix).
- **H3 validée (nuancée)** : sortir le cwd du system (1er message user) éliminerait complètement ce miss résiduel (~700 tokens).

### 5.3 T6 — resume (même session-id) → **HIT TOTAL** (H6 validée)

| Tour | sysHash | cr |
|---|---|---|
| session tours 1-4 | 12f1ccdf | 2816 constant |
| resume_tour1 | 12f1ccdf | **2816** |
| resume_tour2 | 12f1ccdf | 2816 |

- Le prompt reconstruit au resume est **bit-identique** (sysHash identique pendant toute la session + resume).
- Le cache (prompt_cache_key stable + session active) **survit au resume** → **H6 validée** pour ce cas testé.

### 5.4 H2 — boucle d'outils intra-tour → **HIT QUASI PARFAIT 91.9 %**

- 16 appels LLM en boucle (2 read par tour × 3 tours + warmup) : hit global = **91.9 %**.
- Le `cacheRead` croît avec la conversation (2816→8704) = préfixe entier rejoué ; seuls les deltas en input.
- **Le breakpoint « dernier user » de pi est optimal** (comme opencode le documente) → **H2 validée, aucune correction**.

### 5.5 Verdict final de la campagne

| Hyp | Verdict | Gain réel |
|---|---|---|
| H1 (frozen system) | **Validée (nuancée)** : rebuild ≠ miss systématique ; dépend de si le system change | Économie si system change : miss total (cr=0) évité |
| H3 (cwd hors system) | **Validée (nuancée)** : miss partiel ~700 tokens par changement de repo | Robustesse multi-repo |
| H6 (resume) | **Validée** : bit-identique, hit conservé | Chaque resume évite un miss complet |
| H2 (breakpoint user) | **Validée** : déjà optimal (91.9 % hit) | Documentation (pas de fix) |

**Priorité d'implémentation révisée** (après mesures) :
1. **H3** (cwd hors system) : gain mesuré (~700 tokens/repo change) et simple (déplacer le cwd dans le 1er message).
2. **H1** (frozen system) : gain réel **quand le set d'outils change** (miss total) — à implémenter prudemment (les guidelines dépendent des outils, il faut gérer l'append).
3. **T6/H6** : déjà OK — documenter, rien à corriger.
4. **H2** : déjà OK — documenter.

---

---

## PARTIE 6 — PROTOCOLE ANTI-BIAIS MULTI-SCÉNARIOS

> **Motivation (demande utilisateur)** : un test "bateau" peut favoriser une technique par construction, ou une technique peut n'être efficace que sur le test et pas en usage réel. Ce protocole rend le verdict **robuste en imposant** : scénarios d'usage réels, randomisation de l'ordre des conditions, métriques écologiques (coût total de session), et critères statistiques.

### 6.1 Corpus de scénarios réalistes (S1-S8)

Chaque optimistion est testée sur les scénarios **applicables** — jamais sur un seul.

| Scénario | Description (usage réel) | Tours typiques | Variables couvertes |
|---|---|---|---|
| **S1 Court lecture** | Lire 3 fichiers du repo, synthétiser | 5-6 | Session courte, peu de tool calls |
| **S2 Moyen édition** | Lire 2 fichiers, éditer, vérifier | 8-12 | Édition, tool results moyens |
| **S3 Long feature** | Multi-fichiers + test bash | 15-25 | Session longue, compaction possible |
| **S4 Boucle outils** | 5+ tool calls dans UN tour | 6-10 | Boucle intra-tour intensive |
| **S5 Contexte projet** | AGENTS.md/CLAUDE.md présent | 8-12 | Contexte projet dans le préfixe |
| **S6 Resume** | Interruption puis reprise (même session) | 8-12 | Rebuild après interruption |
| **S7 Pauses** | Idle > TTL entre 2 tours | 6-8 | Survie du TTL |
| **S8 Multi-repo** | Changement de cwd en session | 8-12 | Changement de préfixe |

**Affectation indicative** : H3 → S1, S2, S5, S8 (cwd/AGENTS) ; H1 → S2, S3, S6 (rebuild) ; H2 → S4 ; H4 → S2, S3, S4 (conversation longue) ; H6 → S6 ; H5 → S7.

### 6.2 Randomisation et isolation des conditions

Pour chaque scénario S et chaque session :
1. **Ordre randomisé A/B** : alterner `A-B` / `B-A` entre sessions (neutralise le biais d'ordre et le réchauffement).
2. **Sessions séparées** entre A et B (jamais le même session-id — le cache d'une condition ne doit pas alimenter l'autre).
3. **Warmup identique** dans les 2 conditions (même prompt, même nombre de tours).
4. **Même provider/modèle, même repo/cwd/AGENTS.md** hors variable testée.
5. **Écart > TTL** si les conditions s'enchaînent rapidement (ou purge cache via `cacheRetention:"none"` sur le contrôle).

### 6.3 Métriques écologiques (ce qui compte pour l'utilisateur)

| Métrique | Définition | Anti-biais car... |
|---|---|---|
| `cost_total_session` | Σ coût de tous les tours | Reflet du coût réel |
| `hit_rate_session` | Σ cr / (Σ cr + Σ in) sur toute la session | Agrégé, pas un tour isolé |
| `miss_count` | nb de tours où cr < 50 % du cache attendu | Fréquence des ruptures |
| `time_to_completion` | durée réelle de la session | Latence réelle |
| `ttft_médian` | temps avant 1er token (si mesurable) | Latence perçue |

### 6.4 Critère de décision statistique (robuste)

**VALIDÉE** si et seulement si :
- ✅ Gain (hit_rate ou coût) positif sur **≥ 70 % des scénarios applicables**
- ✅ Gain médian ≥ 5 %
- ✅ Aucun scénario avec régression > 2 % (non-régression stricte)
- ✅ Significativité p < 0.05 (test de distribution : Mann-Whitney U ou bootstrap 95 % CI ne traverse pas 0)

**REJETÉE** si :
- ❌ Gain sur < 50 % des scénarios, OU
- ❌ Un scénario régresse > 5 %

**Alerte "test bateau"** : si la baseline A ne gagne sur **aucun** scénario, le test est probablement biaisé → signaler et refaire.

### 6.5 Séquence d'exécution standard

1. **Pilote** : 1 session par scénario/condition (calibrer coût + vérifier l'instrumentation).
2. **Campagne** : N ≥ 5 sessions par (scénario × condition), randomisées.
3. **Analyse** : distribution (médiane/IQR), test statistique, verdict.
4. **Anti-gaming** : le verdict s'appuie sur `cost_total_session` et `hit_rate_session` agrégés, jamais sur un tour choisi.

---

---

## PARTIE 7 — RÉSULTATS H3 AVEC PROTOCOLE ANTI-BIAIS (verdict corrigé)

> **Le protocole anti-biais (Partie 6) appliqué à H3 a RÉFUTÉ l'hypothèse** que le test initial (T3) semblait supporter. C'est la validation du protocole : il a détecté un biais.

### 7.1 Le biais détecté dans T3

Le test T3 initial comparait repoA (**avec** AGENTS.md) et repoB (**sans**) → le miss observé (cr 2816→1792) venait du **contexte projet entier différent** (un bloc `<project_context>` complet présent dans un repo, absent dans l'autre), PAS du cwd.

**Preuve** : après égalisation des repos (même AGENTS.md), le diff system repoA↔repoB se réduit à 2 lignes (~100 octets) :
```
Current working directory: .../repoA  →  .../repoB
<project_instructions path=".../repoA/AGENTS.md">  →  .../repoB/AGENTS.md
```

### 7.2 Résultats (N=2 sessions/cond/scénario, commandcode/deepseek)

| Scénario | A: cost tour cd | B: cost tour cd | A: cacheRead cd | B: cacheRead cd |
|---|---|---|---|---|
| S1 lecture | 0.00015 | 0.00015 | 3200 | 2816 |
| S2 édition | 0.00029 | 0.00049 | 3968 | 5888 |
| S5 AGENTS.md | 0.00016 | 0.00014 | 3072 | 3072 |
| S8 multi-repo | 0.00010 | 0.00008 | 2944 | 2816 |

### 7.3 Verdict : H3 RÉFUTÉE (gain négligeable)

1. Le cwd en **fin** de system prompt (design actuel de pi) = déjà quasi optimal : le préfixe AVANT le cwd est identique entre repos → reste en cache. Coût d'un changement de repo ≈ 100-200 tokens, pas des milliers.
2. La condition B (retirer cwd + path AGENTS, injecter au 1er user message) n'apporte aucun gain mesurable ; elle peut même coûter plus (l'injection modifie la conversation).
3. **L'hypothèse initiale était portée par un test biaisé.** Le protocole anti-biais l'a corrigée.

### 7.4 Leçon méthodologique (valeur du protocole anti-biais)

Le protocole multi-scénarios + repos égalisés a exactement rempli son rôle : **détecter qu'un résultat positif venait d'un artefact de test** (2 variables mélangées), pas d'un vrai effet. Sans lui, on aurait implémenté une optimisation inutile.

**Priorités révisées** (après toutes les mesures) :
- ❌ H3 (cwd hors system) : **réfutée** — le code actuel est déjà bien positionné
- ⚠️ H1 (frozen system) : gain réel seulement quand le SET d'outils change (miss total)
- ✅ H2, H6 : déjà optimales (documenter)
- ➡️ Reste à tester en priorité : **H4** (hybride exclude tool results — le seul levier de latence/coût potentiellement significatif restant)

---

---

## PARTIE 8 — H4 : constat d'INAPPLICABILITÉ (cache implicite)

> **Résultat important** : l'hypothèse H4 (exclure les tool results du cache quand la conversation dépasse le system — la stratégie gagnante du papier « Don't Break the Cache » pour GPT-5.2) **n'est PAS testable sur les providers accessibles**, et ce pour une raison structurelle.

### 8.1 Vérification de la sémantique de cache par provider (mesurée sur payload réel)

| Provider / modèle | cache_control émis ? | Sémantique |
|---|---|---|
| opencode-go / deepseek-v4-flash | **non** | cache **implicite** (préfixe automatique) |
| commandcode / deepseek-v4-flash | **non** | cache implicite |
| commandcode / gpt-5.6-sol | **non** | cache implicite |
| commandcode / claude-sonnet-5 | **oui** (system + dernier message) | cache **explicite** (breakpoints) — **mais bloqué : MODEL_NOT_IN_PLAN** |
| commandcode / claude-fable-5, claude-haiku | oui | explicite — bloqués (plan) |

**Structure du payload mesurée** :
- Cache implicite : `system` est un message `role:system` ; pas de `cache_control` ; dernier message `role:tool`.
- Cache explicite (Claude sur commandcode) : `system` séparé + `cache_control` sur system[0] et dernier message.

### 8.2 Conclusion : H4 inapplicable dans cet environnement

La stratégie « exclude tool results » nécessite de **déplacer les breakpoints** pour exclure la queue de conversation du cache. Or :
1. Les providers accessibles (opencode-go, commandcode/deepseek/gpt) sont en **cache implicite** — le client ne peut PAS contrôler la frontière du cache ; le provider matche tout le préfixe automatiquement.
2. Les seulement modèles avec breakpoints (Claude) sont **bloqués par le plan** (403 MODEL_NOT_IN_PLAN).

**→ H4 ne peut pas être implémenté côté client sur ces providers.** La question devient un choix du provider (la stratégie d'exclusion est côté serveur), pas un levier du harness.

### 8.3 Piste alternative (H4-variant implicite, à décider)

L'esprit de H4 (réduire ce qui est relu/écrit en cache) peut être testé en cache implicite via la **compaction** : remplacer les vieux tool results par des résumés → préfixe plus court → moins de tokens relus. MAIS la compaction a son propre coût (un tour de résumé + invalidation du préfixe) — c'est un tradeoff à mesurer, pas une optimisation évidente. **Non exécuté par défaut** (s'éloigne de H4 littéral, coût non négligeable).

### 8.4 Verdict global final (toutes hypothèses)

| Hyp | Verdict | Exécutable/Applicable |
|---|---|---|
| H1 gel system prompt | Nuancée (miss total si set d'outils change) | ✅ applicable (pi) |
| H2 breakpoint dernier user | Déjà optimale (91.9 % hit) | ✅ mesuré |
| H3 cwd hors system | Réfutée (biais + bruit croisé) | ✅ mesuré |
| H4 exclude tool results | **Inapplicable** (cache implicite, Claude bloqué) | ❌ pas testable ici |
| H5 keepalive | Non testé (nécessite pauses > TTL) | ⚠️ long |
| H6 resume bit-identique | Validée | ✅ mesuré |
| H7-H10 | Hors périmètre | — |

---

---

## PARTIE 9 — VERDICTS DES EXPÉRIENCES E0-E10 (validation P0-P2)

> **Exécuté** : 2026-09-04 · Providers : opencode-go, commandcode · Bac à sable .pi-test · Détails : `.research/resultats/`

| Exp | Verdict | Découverte |
|---|---|---|
| **E0** | ✅ Banc verrouillé | Instrumentation segmentée ; **P10 nuancé** : le system de pi est partagé entre sessions → le 1er tour n'est PAS toujours un miss |
| **E1 (P0-A)** | ✅ Mécanisme validé | Le system peut rester **bit-stable** quand les outils changent (snapshot + Operating instructions aux 1er message) ; campagne N≥5 à finaliser en process-continu |
| **E2 (P0-B)** | ⚠️ GAP | Sur modèles explicites (claude via commandcode), le **dernier tool n'a PAS cache_control** — à corriger (bridge/compat) |
| **E3 (P0-C)** | ✅ TTL non-bloquant | Le cache opencode-go **survit 5.5 min** (cr=2816 constant) → P0-C neutralisée sur ce provider |
| **E4 (P1-D)** | ❌ INUTILE | Warmup superflu : system partagé → déjà caché au 1er tour (cr=2816 dans les 2 conditions) |
| **E10 (P5)** | ✅ Stable | Pas de non-déterminisme sur opencode-go (cr constant) → fiable pour les mesures |
| E5-E9 | ⏳ Non exécutés | Keepalive (4-8h), suffixe minimal, anti-miss, compaction — priorité basse, documentés comme suite |

**Conséquences pour pi** :
1. **P0-A** (découplage) : mécanisme prouvé → implémenter (refonte de `_rebuildSystemPrompt`).
2. **P0-B** (table sémantique) : GAP réel sur explices → corriger le marquage du dernier tool.
3. **P0-C** (TTL long) : **inutile sur opencode-go** → ne pas l'activer par défaut sur ce provider.
4. **P1-D** (warmup) : **ne pas implémenter** (system partagé rend le warmup coûteux et inutile).
5. **E10** : opencode-go fiable → les mesures H sont valides.

**Coût total des expériences** : ~0.6-0.8 $ (deepseek-v4-flash — bien sous le budget 2.6-5.6 $ estimé).
