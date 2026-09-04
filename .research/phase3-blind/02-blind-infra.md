# Phase 3 — 02 (BLIND) : Optimisations de prompt caching côté client — question ouverte d'architecture

> **Rédigé par** : sous-agent phase 3 (blind) — exercice d'architecture *client-side* : « que peut faire le harness quand on connaît les mécanismes serveur ? »
> **Méthode** : question ouverte, rédigée à partir des mécanismes serveur connus (phase 1 : `02-cache-infra.md`, `03-literature.md` ; phase 2 : `01-mecanisme.md`) et de l'état des hypothèses H1–H10 (`docs/03-conclusions-hypotheses-optimisation.md`), **sans** re-mesurer quoi que ce soit. Statut : hypothèses d'architecture à arbitrer — pas une décision.
> **Référentiel serveur** : cache = préfixe exact bit-identique au niveau tokens ; clé = (modèle, préfixe tokenisé, route/instance, clé de session) ; TTL 5 min–24 h ; seuils 1024–4096 tokens ; implicite (OpenAI/Gemini) vs explicite ≤ 4 breakpoints (Anthropic) ; observabilité : `cached_tokens` vs `cache_read/creation_input_tokens`.

---

## 0. Résumé exécutif

Le client ne contrôle **que 4 choses**, quel que soit le provider :
**la composition du préfixe** (quoi), **son ordre** (stabilité décroissante), **sa stabilité dans le temps** (qui ne doit jamais changer en session), et **la localité** (aider le provider à retrouver le bon bloc : breakpoints, clé, session-affinity, TTL).

Trois conclusions transversales :

1. **L'invariant universel domine tout** : un octet qui change dans le préfixe invalide tout le suffixe. Toutes les optimisations de plus haut impact (a, b, e) sont des déclinaisons de « *statique en tête, dynamique en fin, jamais de réécriture du bloc initial* ».
2. **La seule différence structurelle entre implicite et explicite** est *qui choisit la frontière* : le provider (implicite, point de divergence naturel) ou le client (explicite, ≤ 4 breakpoints). Les optimisations de localité (d) et de temporalité (c) sont, elles, **indépendantes de l'architecture**.
3. **Priorités** (détail §7) : P1 = frozen system prompt + ordre stabilité décroissante (aucun coût, gain certain) ; P1 = contrôle du capping et de l'ancre de breakpoints (explicite) ; P2 = TTL long + résumé/compaction préservant le préfixe ; P3 = keepalive probabiliste et exclusion hybride (à mesurer avant d'activer).

---

## 1. Le contrat serveur auquel le client doit se conformer (rappel utile)

| Paramètre | Valeur connue | Conséquence client |
|---|---|---|
| Unité de cache | préfixe exact, bit-identique | toute instabilité = miss du suffixe |
| Clé | (modèle, préfixe tokenisé, région/route, clé session) | modèle/effort/région = partie de la clé, pas de « cache » possible à travers |
| Seuil minimal (implicite/explicite) | ~1024 tokens (Anthropic/OpenAI ; Gemini 4096) | un préfixe sous le seuil n'est jamais caché |
| TTL | 5 min court, 1 h / 24 h long (glissant à la réutilisation) | la fenêtre de réutilisation est courte ; il faut la prolonger (TTL long, keepalive) ou survivre au miss |
| Tarifs | read 0.1×–0.5× ; write 1.25× (Anthropic) | trop de cache-writes = taxe ; le coût marginal d'un hit est presque nul |
| Architecture | implicite (frontière choisie par provider) vs explicite ≤ 4 breakpoints (frontière choisie par client) | le rôle du client change : stabilité + localité vs choix des frontières |
| Observabilité | `cached_tokens` / `cache_*_input_tokens` | rien n'est mesurable sans instrumentation ; optimiser sans mesurer = spéculer |

⚠️ Incertitudes à garder en tête (elles conditionnent plusieurs optimisations) : seuil Anthropic peut monter à 2048 ; TTL OpenAI « ~5–10 min glissant » avec des valeurs divergentes (Codex 30 min) ; dans certains cas les **lectures ne prolongent pas le TTL** ; le cache OpenAI est **non-déterministe même bit-identique** (la clé est un indice de localité, pas une garantie).

---

## 2. (a) Optimisations pour **cache implicite** (OpenAI, Gemini, OpenRouter défaut)

Pas de breakpoints : le provider matche le plus long préfixe commun au-dessus du seuil. Le rôle du client est de **garantir l'existence et la stabilité d'un long préfixe commun**, et de ne jamais le fragmenter.

### a1. Frozen system prompt (levier n°1, tous providers)
- **Mécanisme** : geler le system prompt intégralement au premier tour de session ; toute évolution (nouveaux tools, ressources, AGENTS.md, réglages) = append en fin de prompt ou diff appliqué au tour suivant, **jamais** de réécriture du bloc initial.
- **Pourquoi ça aide** : le system est le bloc le plus volumineux et le plus stable ; un miss sur lui = re-préfill de tout le system à chaque tour, à coût plein (5× chez Anthropic en write-relu, ~2× en OpenAI). Un système figé rend le hit du préfixe quasi déterministe en implicite (le point de divergence naturel se déplace vers la conversation, pas vers le system).
- **Risques** : si le system prompt tombe sous le seuil minimal (1024/4096), on perd tout le cache implicite — il faut donc un system ≥ ~2k tokens (le cas pi : instructions + tools le dépassent largement) ; geler trop longtemps = instructions obsolètes (mais les appendles rejetés en fin de prompt résolvent le besoin sans casser le préfixe).
- **Test** : sessions longues avec modification de tools/ressources en cours ; comparer `cached_tokens` avant/après la modification ; vérifier que le prefix match s'arrête là où le content diverge, pas plus tôt.

### a2. Sérialisation bit-stable (ordre, JSON, headers)
- **Mécanisme** : ordre des messages, ordre des définitions de tools, formatage JSON, indentation, encodage : tout doit être **déterministe et inchangé en session** (mêmes types, mêmes champs, protocoles de sérialisation figés).
- **Pourquoi** : en implicite le match est au niveau **tokens** ; une reformatage (même cosmétique) d'un élément du préfixe = miss silencieux du suffixe, sans aucun message d'erreur.
- **Risques** : les refactors de code du harness (bump de version de la lib de sérialisation, changement d'ordre de tri des tools…) cassent silencieusement le cache entre deux versions — indétectable sans mesure.
- **Test** : snapshot du prompt wire (bytes) sur deux tours consécutifs → diff doit être vide sur le préfixe attendu ; c'est le test de régression le plus rentable du repo.

### a3. Statique en tête, dynamique en fin (déplacement des volatils)
- **Mécanisme** : timestamps, IDs, compteurs, cwd, variables d'environnement volatiles : tout ce qui peut changer est rejeté **en fin de prompt** (fin du system ou premier message user), jamais en tête.
- **Pourquoi** : 1 timestamp en tête = le préfixe diverge dès le début = miss total (« bill 5x » documenté). En queue, ces éléments ne paient que leur propre coût au tour N.
- **Risques** : si un composant volatil est *nécessaire* au raisonnement du modèle dès le début (ex. date courante dans les instructions), le déplacer en tête de **messages** (après le system figé) plutôt qu'en tête du system, et l'accepter comme point de divergence naturel.
- **Test** : injecter une variable volatile en tête vs en queue sur deux sessions jumelles ; comparer `cached_tokens` et le TTFT.

### a4. Séparer contenu projet (cwd, AGENTS.md, contexte repo) du system prompt
- **Mécanisme** : le contenu projet (cwd, multi-repo, AGENTS.md, instructions projet) sort du system prompt principal et passe dans le **premier message user** (ou un message system séparé post-préfixe).
- **Pourquoi** : changer de cwd/repo/AGENTS.md en cours de session ne devrait pas casser le préfixe principal (le plus cher) — en implicite le point de divergence sera alors *après* le system, au niveau du message projet.
- **Risques** : (1) le system seul peut tomber sous le seuil → perdre le cache entier (cf. a1) ; (2) implique un **ordre figé** de ce message projet (toujours en 2ᵉ position, contenu déterministe), sinon on déplace le problème.
- **Test** : session avec changement de repo en cours ; vérifier que `cached_tokens` reste ≥ taille du system sur les tours suivants.

### a5. Maintenir le préfixe cacheable au-dessus du seuil
- **Mécanisme** : veiller à ce que le préfixe stable (system + outils + début de conversation) reste **≥ 1024 tokens** (OpenAI) — et 4096 pour Gemini — y compris en session courte ou après compaction.
- **Pourquoi** : sous le seuil, aucun hit n'est possible : tout ce qui suit est facturé plein. À l'inverse, tout excédent stable au-dessus du seuil est « monétisable » à 0.5×.
- **Risques** : gonfler artificiellement le system (padding, répétitions) pour atteindre le seuil = coût plein au 1ᵉʳ tour et au-delà si jamais le cache casse ; c'est un levier d'**optimisation de réglage**, pas de contenu.
- **Test** : mesurer où se situe le préfixe stable par rapport au seuil sur un échantillon de sessions ; vérifier le comportement aux frontières 1024/2048/4096.

### a6. Exploiter (au lieu de combattre) le point de divergence naturel
- **Mécanisme** : comprendre que la frontière implicite = l'endroit où la conversation diverge ; donc **tout contenu qui va changer doit être placé au plus tard possible** dans la requête (ex. : les tool_results de la boucle courante, qui ne seront jamais relus, doivent rester en **fin de conversation**, derrière le dernier message user stable).
- **Pourquoi** : cela maximise la probabilité que le provider trouve un long préfixe commun (la conversation jusqu'au dernier user) au-dessus du seuil.
- **Risques** : si au contraire du contenu *stable* est placé après du contenu *déstabilisant* (ex. un tool result instable au milieu), le préfixe commun s'arrête trop tôt et un bloc stable entier est payé plein à chaque tour.
- **Test** : sur une boucle d'outils N-tours, vérifier que `cached_tokens` croît avec la conversation (le préfixe re-matche à chaque appel) et n'est pas plafonné à un niveau inférieur.

> **Synthèse (a)** : en implicite il n'y a **pas de levier de frontière** (pas de marqueur) — l'optimisation est : préfixe long, stable, bit-identique, au-dessus du seuil, volatils en queue. Les leviers a1/a2/a3 sont sans coût et sans risque réel ; a4/a5/a6 sont des variations d'architecture de prompt à valider par mesure.

---

## 3. (b) Optimisations pour **cache explicite à breakpoints** (Anthropic, Bedrock, OpenRouter `anthropic/*`)

Le client choisit ≤ 4 frontières : chaque préfixe terminant à un breakpoint devient une **unité cacheable** (write 1.25× / read 0.1×).

### b1. Poser les 3 breakpoints canoniques (pattern « 3-points »)
- **Mécanisme** : breakpoint (1) fin du system prompt, (2) dernière définition de tool, (3) dernier message user (ancre dynamique). C'est le pattern partagé par pi/opencode/aider/cline/Claude Code.
- **Pourquoi** : (1) rend le system re-éditable à 0.1× ; (2) sépare system/conversation (la conversation peut croître sans invalider le system) ; (3) est LE levier de coût de la boucle d'outils (voir b2).
- **Risques** : breakpoints posés sur des blocs **non-cacheables** (texte vide, `content: null`, thinking blocks) = erreurs 400 ou breakpoints muets ; un breakpoint mal posé peut *changer le JSON* et donc le hash (un marqueur n'est pas du contenu — mais sa position dans la structure l'est, à vérifier par test `prefix_invariance`).
- **Test** : vérifier qu'aucun `cache_control` ne se pose sur bloc vide/thinking (test unitaire sur tous les types de contenu) ; vérifier que le placement du breakpoint ne modifie pas le préfixe tokenisé du bloc précédent.

### b2. Ancre dynamique = « dernier message user », pas « dernier message »
- **Mécanisme** : le breakpoint n°3 cible le dernier bloc du **dernier message user** — jamais un tool_result. Pendant qu'un tour explose en N allers-retours assistant/tool, le dernier message user reste en place : chaque appel intra-tour matche le préfixe jusqu'à lui et ne paie que les tool results frais.
- **Pourquoi** : c'est la mesure de référence du repo : **91.9 % de hit global** observé dans la boucle d'outils de pi quand l'ancre est le dernier user (cr 2816 → 8704 : seuls les deltas passent en input).
- **Risques** : ancrage par **rôle** (et non par position) peut mettre les 2 breakpoints (conversation + ancre) sur le même message quand le dernier message *appartient* au user mais contient un tool_result ; la bonne pratique est l'ancrage **positionnel** (goose : ancre positionnelle + breakpoint secondaire à ~20 blocs en arrière).
- **Test** : instrumenter `applyCacheControl` sur des boucles bash/edit répétées : compter les hits intra-tour (breakpoint re-matché) et vérifier qu'il n'y a jamais 2 breakpoints sur le même message.

### b3. Breakpoint system toujours présent (même sans tools)
- **Mécanisme** : le breakpoint fin-de-system doit exister même si `tools.length === 0` (sessions de critique/plan, providers à tools réduits).
- **Pourquoi** : le system est le seul bloc stable et volumineux dans ces sessions ; sans breakpoint, chaque tour re-write le system complet à 1.25× au lieu de le lire à 0.1×.
- **Risques** : tickets de compat (certains providers rejettent `cache_control` sur tools — `supportsCacheControlOnTools`) ; ne pas dépasser le cap de 4 breakpoints (pi n'en pose que 3 — vérifier que tout 4ᵉ ajout éventuel sacrifie le breakpoint le moins stable).
- **Test** : session sans tools ; vérifier que `cache_read_input_tokens` reflète bien des reads du system sur les tours 2+.

### b4. Stratégie « exclude tool results » / hybride (cacher moins)
- **Mécanisme** : quand la conversation (surtout les tool results, uniques par nature) devient ≥ la taille du system, **arrêter de la cacher** : breakpoint avant la queue de conversation, ou pas de breakpoint sur le dernier user si la queue est énorme et instable. Hybride : cacher la conversation tant qu'elle est < system, l'exclure au-delà.
- **Pourquoi** : cacher du contenu qui ne se répétera jamais = **overcaching tax** (write 1.25× pour un read qui ne viendra jamais). Le papier de référence mesure cette stratégie comme la meilleure en latence (79.6 % cost ↓, 13 % TTFT ↓, meilleure sur la latence).
- **Risques** : perte de coût si la conversation est en fait réutilisée (elle gagne — il faut la **mesure par session**, pas une règle globale) ; risque de fragmentation du KV cache côté serving si on alterne les frontières d'un tour à l'autre.
- **Test** : comparer coût TTFT et $ sur : tout-cacher vs exclure-les-tool-results vs hybride, sur des sessions à gros tooling ; porter le critère de bascule (taille conversation > system) en paramètre.

### b5. Gestion des dialectes et compatibilité des marqueurs
- **Mécanisme** : le même pattern « 3 breakpoints » doit s'adapter au dialecte du provider : marqueurs style Anthropic (blocs messages) vs style OpenAI-compatible (OpenRouter pour `anthropic/*` : marqueurs sur blocs texte + tool defs, format différent) ; flag `cacheControlFormat` ; fallback gateway : 400 reçu sur `cache_control` → renvoi sans marqueur (puis éventuellement marqueur sur le dernier message).
- **Pourquoi** : un provider qui rejette les marqueurs (ou les ignore) transforme des écrits 1.25× en **pure perte** ; le fallback et la table de compat évitent la perte et les erreurs 400.
- **Risques** : trop de cas particuliers = complexité et régressions silencieuses ; chaque nouveau provider doit entrer dans la table avant activation.
- **Test** : matrice (provider × dialecte) en staging : valider que les marqueurs sont acceptés ET que les reads apparaissent dans les métriques.

> **Synthèse (b)** : en explicite le client a le **choix des frontières** — c'est le seul endroit où il peut exclure du contenu du cache. b1/b2 sont des conditions de base (déjà en place chez pi — à verrouiller par tests d'invariance), b3/b5 sont de la robustesse, b4 est le vrai levier économique extra à mesurer (le plus nuancé des H du repo).

---

## 4. (c) Optimisations **TTL / keepalive**

Indépendantes de l'architecture implicite/explicite. Le problème : la fenêtre de réutilisation est courte (5 min court) et la cause n°1 de miss attendue est l'**inactivité > TTL** (`CacheMiss{idleMs}` chez pi).

### c1. Levier de rétention long (à activer par défaut quand disponible)
- **Mécanisme** : `PI_CACHE_RETENTION=long` → Anthropic `ttl: "1h"`, OpenAI `prompt_cache_retention: "24h"` ; `short` par défaut (5 min).
- **Pourquoi** : c'est **l'alternative au keepalive sans coût de ping** : il suffit que le provider le supporte (pas de prolongation active à écrire). Rapport coût/bénéfice excellent.
- **Risques** : rétention longue souvent payante ou réservée (à vérifier par provider) ; certains providers ignorent le champ silencieusement ; ne doit pas être activé sur des providers sans cache (écriture inutile).
- **Test** : sur les 2 providers du repo, comparer la rétention effective (reprendre une session après 10 min et après 30 min ; lire `cache_*_input_tokens` / `cached_tokens`).

### c2. Keepalive — la règle économique d'abord
- **Mécanisme** : envoyer périodiquement une mini-requête qui réutilise le préfixe pour rafraîchir la fenêtre. Le déclencheur doit être **probabiliste** : pinger seulement si `P(réutilisation dans la fenêtre) × bénéfice_hit > coût_des_pings` (arXiv 2607.19214 : lecture ~10× moins chère + suppression du préfill).
- **Pourquoi** : les sessions longues avec pauses (≥ 4-5 min de réflexion, lecture de fichiers, pauses utilisateur) sont les plus pénalisées par le TTL court ; un seul hit évité rembourse souvent des dizaines de pings (read 0.1×–0.5×).
- **Risques** : (1) un ping qui **réécrit** du contenu coûte en write 1.25×, pas 0.1× — le ping doit être un **read** de préfixe existant ; (2) chez certains providers les **lectures ne prolongent pas le TTL** — dans ce cas le keepalive est inutile/coûteux, à détecter par provider ; (3) déclenchement non désiré sur sessions qu'on sait abandonnées (fermetures).
- **Test** : sur pi, H5 n'a pas pu être exécuté (pas de sessions à pauses > 5 min) — protocole : sessions avec pauses contrôlées (6-8 min), 3 configs (aucun ping / ping read / ping write), mesurer $ et TTFT au tour de reprise vs coût des pings ; établir la fréquence optimale (aider : ping toutes les 5 min, paramétré `AIDER_CACHE_KEEPALIVE_DELAY`).

### c3. Ping minimal et « shape » du ping
- **Mécanisme** : le ping doit être structurellement minimal : même préfixe (system + tools + dernier user), réponse la plus courte possible (max_tokens ≈ 1, température 0), sans nouveau contenu. Résultat : ~préfill entier économisé à 0.1×.
- **Pourquoi** : le coût d'un ping est dominé par le write du préfixe s'il réécrit ; un ping qui relit un préfixe existant au-dessus du seuil est presque gratuit (seuil minimal : le ping doit réutiliser ≥ 1024 tokens pour être rentable).
- **Risques** : amplification du bruit (requêtes visibles dans les logs/quotas, rate limits, quotas par minute) ; ping quand la session est à l'état « fini » inutile.
- **Test** : vérifier que le ping génère des opérations de **lecture** (et pas de write) côté provider sur 10 essais ; mesurer le taux de hit au tour de reprise.

### c4. Fenêtre de décision du keepalive (pour qui, quand)
- **Mécanisme** : ne pinger que si (session considérée « active en attente » — l'utilisateur a laissé un agent en cours d'exécution / une pause de travail courte ; historique de reprise élevé) et si le préfixe dépasse le seuil.
- **Pourquoi** : le modèle économique repose sur la probabilité de réutilisation ; pinger une session abandonnée = perte sèche.
- **Risques** : faux positifs (pauses « réflexion » vs « abandon ») — notion d'heuristique à calibrer.
- **Test** : télémétrie locale (non partagée) : reprises effectives par session vs décision de ping ; ajuster le seuil de probabilité.

> **Synthèse (c)** : le TTL long (c1) est le quick win immédiat ; le keepalive (c2/c3/c4) est un levier réel mais **incertain** (TTL glissant vs fixe, lectures prolongeant ou non le TTL, non-testé chez pi) — à activer par défaut seulement après mesure, car un keepalive « écrit » mal réglé est une taxe.

---

## 5. (d) Optimisations **clé de cache / session**

Tout ce qui aide le provider à **retrouver le bon bloc KV** (localité), indépendant de l'architecture.

### d1. Clé de cache explicite stable (prompt_cache_key)
- **Mécanisme** : dériver une clé stable de la session (uuidv7, clamp 64 chars) envoyée comme `prompt_cache_key` (OpenAI).
- **Pourquoi** : fige la topologie de cache cross-requêtes : les requêtes de la même session convergent vers le même slot KV.
- **Risques** : le cache OpenAI est **non garanti même bit-identique** (hits 1/20 rapportés sur GPT-5, `cached_tokens=0` intermittents) — la clé est un **indice de localité**, pas une garantie ; générer une nouvelle clé par requête (bug) = miss systématique.
- **Test** : vérifier la stabilité de la clé sur une session complète (même valeur sur tous les appels) ; mesurer la variance de hits entre sessions avec/sans clé, sur plusieurs jours.

### d2. Session-affinity (route/instance) + mono-région
- **Mécanisme** : headers `x-session-id` (OpenRouter), `x-session-affinity` / `x-client-request-id` (OpenAI/Anthropic) ; plus largement : **ne pas changer de région/route en session**.
- **Pourquoi** : les caches sont régionaux/par instance ; deux requêtes d'une même session routées vers deux instances différentes = miss mutuel.
- **Risques** : certains providers ignorent les headers ; l'affinité peut dégrader la latence si une instance est surchargée (tradeoff équilibrage vs cache) — acceptable car le cache réduit aussi le préfill, donc le TTFT.
- **Test** : comparer la distribution des hits sur 100 requêtes avec et sans headers d'affinité ; surveiller le TTFT (pas de régression par collocation).

### d3. Modèle / effort / version = clé : ne pas changer en session
- **Mécanisme** : geler le (modèle, variante, effort, température gérante, endpoint) pour toute la session ; si l'utilisateur change de modèle, assumer le miss et **informer** (métrique `cache-waste`).
- **Pourquoi** : les poids du modèle changent le calcul des KV — c'est la partie la plus « dure » de la clé ; inutile d'optimiser le préfixe si on change de modèle au milieu.
- **Risques** : fournisseurs/routeurs qui « surclassent » silencieusement le modèle ou l'effort en cours de session (à détecter par les métriques de cache, pas par les logs d'appel).
- **Test** : session avec changement de modèle explicite → vérifier `cached_tokens=0` au tour suivant (comportement attendu, pas un bug) ; session stable → pas de chute.

### d4. Resume cross-process : bit-identité du prompt reconstruit
- **Mécanisme** : sur `pi resume` (ou reprise après fermeture), le prompt réassemblé doit être **bit-identique** à celui du dernier tour : même sessionId (uuidv7 persisté), même cwd/contexte projet, mêmes tools, même ordre, même version de sérialisation.
- **Pourquoi** : c'est la seule façon d'hériter du cache long (24 h OpenAI) entre deux processus — le varier non-determiniquement (cwd différent, tools régénérés dans un ordre différent) = miss garanti à la reprise.
- **Risques** : le contexte projet qui n'est pas persisté correctement (d'où l'intérêt de a4 : le séparer du system pour le reconstruire de façon fiable) ; changements de versions du harness entre fermeture et reprise (cf. a2).
- **Test** : snapshot du prompt du dernier tour vs prompt reconstruit au resume → diff byte-à-byte ; reproduire la reprise le même jour et mesurer les hits (24 h).

### d5. Éviter les frais de stockage non liés au cache
- **Mécanisme** : `store: false` (OpenAI) tant que le stockage serveur n'est pas utile au produit.
- **Pourquoi** : le stockage est facturé indépendamment du prompt cache ; le désactiver élimine une ligne de coût sans toucher au cache.
- **Risques** : aucun pour le cache ; vérifier seulement que des features (reprise serveur, historisation) n'en dépendent pas.
- **Test** : comparer la facture avec `store: true/false` à usage identique.

> **Synthèse (d)** : d1/d2/d3 sont **à coût d'implémentation quasi nul** (headers + clé + invariant de session) et protègent tout le reste ; d4 est le levier le plus sous-estimé (le resume est un moment où le cache long peut rapporter gros) ; d5 est trivial.

---

## 6. (e) Optimisations de **STRUCTURE du contexte** : compaction, résumés, exclusion

Le préfixe parfait ne sert à rien s'il est mal découpé ou si l'historique devient trop gros pour être re-préfillable même en cache. C'est le chantier le plus complexe (interagit avec la qualité du raisonnement, pas juste le coût).

### e1. Compaction qui préserve le préfixe (le résumé devient le nouveau socle)
- **Mécanisme** : lors d'une compaction, le résumé du contexte ancien + les messages récents conservés doivent former un **nouveau préfixe stable, dès le premier tour post-compaction** : résumé déterministe, en tête, jamais régénéré en session ; messages récents de type tool_result régénérés avant le résumé (jamais entre lui et le reste).
- **Pourquoi** : une compaction « naïve » (résumé régénéré à chaque tour, ou ordre instable) = miss au tour suivant, exactement ce que le cache devait éviter ; un résumé bit-stable re-rend cacheable tous les tours suivants.
- **Risques** : le résumé coûte un tour de génération (écrit à 1.25×, une fois) ; risque de perte d'information (qualité agent) ; le seuil minimal doit rester ≥ 1024 tokens après compaction, sinon le nouveau préfixe n'est pas cacheable (surveiller avec a5).
- **Test** : mesurer `cache_*_input_tokens` au tour post-compaction et sur les 5 tours suivants (doit redevenir stable) ; vérifier la bit-identité du résumé entre tours.

### e2. Granularité et déclenchement de la compaction
- **Mécanisme** : compacter sur un seuil en tokens (pas en messages) ; favoriser la compaction **au moment où l'historique cesse d'être rentable à cacher** (conversation ≫ system → cf. b4) ; garder intact le préfixe tant que possible.
- **Pourquoi** : le coût du contexte croît linéairement avec sa taille — même en cache (read) ; compacter au bon moment plafonne le coût par tour et le TTFT du préfill.
- **Risques** : compacter trop tôt = perte d'information et *générations de résumés coûteuses* ; compacter trop tard = read 0.1× d'un préfixe géant (acceptable en coût, moins en TTFT — le préfill reste un préfill).
- **Test** : sur sessions longues, mesurer coût cumulé et TTFT par stratégie de seuil (tokens) ; rechercher le point de bascule coût/latence.

### e3. Exclusion structurelle du contenu jamais réutilisé
- **Mécanisme** : contenu « one-shot » (résultats de commandes, gros diffs, sorties d'outils, images) : en **explicite** via le placement des breakpoints (b4) ; en **implicite** via la structure (le placer en fin de requête derrière le point de divergence naturel, a6) ; idéalement tronquer/normaliser le contenu énorme avant envoi.
- **Pourquoi** : ce contenu ne sera jamais relu (il n'existe qu'une fois) ; le cacher = write plein ou coût de préfill sans aucun read futur ; le tronquer réduit la taille du préfixe non-réutilisable payé à chaque tour.
- **Risques** : l'agent peut avoir besoin de relire ces contenus (d'où l'importance de garder des **références/chemins de fichier** plutôt que le contenu intégral) ; sur-tronquer = capacité de raisonnement réduite.
- **Test** : sessions à gros output d'outils : mesurer la part du préfixe jamais re-matchée (diff entre cached_tokens re-matchés et input total) ; valider que la troncature ne dégrade pas la qualité de la tâche (tests de régression de comportement).

### e4. Ordre de stabilité décroissante généralisé
- **Mécanisme** : structurer la requête comme : system figé → outils (ordre stable) → contexte/projet stable (résumé, AGENTS.md agrégé) → historique conversation → **messages récents en fin**. Règle : toute section a un taux de stabilité ≥ à la suivante.
- **Pourquoi** : maximise la longueur du préfixe commun au point de divergence ; c'est la généralisation de a3 à l'échelle de la requête entière.
- **Risques** : l'ordre « naturel » de la conversation (chronologique) peut entrer en conflit avec l'ordre « optimal » (stabilité) — il faut décider où tracer la frontière entre historique et messages récents (ex. : chronologie conservée à l'intérieur de chaque zone).
- **Test** : comparer deux ordres sur sessions identiques (mesure A/B) : `cached_tokens` et TTFT.

### e5. Ne rien faire qui **empêche** le reuse non-prefix côté serving
- **Mécanisme** : conserver des messages **regroupés et ordonnés** (pas de re-injection à chaque tour, pas de fragmentation, pas de duplication du même bloc à plusieurs endroits) — les serveurs modernes (RadixAttention, vLLM APC, CacheBlend non-prefix reuse : 63–85 % hit) réutilisent aussi des segments hors-préfixe si le contenu est stable et localisé.
- **Pourquoi** : c'est la seule optimisation côté harness qui profite des deux générations de cache — à coût nul, juste en évitant les anti-patterns (contenu dupliqué, ordre aléatoire, floats de UUID dans le contenu).
- **Risques** : aucune ; l'effet est seulement non-garanti (dépend du serving).
- **Test** : sur serving maison (vLLM/SGLang + LMCache), comparer `prefix_cache_hit_rate` et (si dispo) les métriques de reuse non-prefix avant/après restructuration.

> **Synthèse (e)** : les gains sont réels mais conditionnés par la mesure (la compaction touche aussi la qualité). e1/e2 sont la priorité (coût plafonné) ; e3 réplique b4 côté structure ; e4/e5 sont des règles d'hygiène sans coût.

---

## 7. Priorisation impact / effort

| # | Optimisation | Cat. | Impact attendu | Effort | Priorité |
|---|---|---|---|---|---|
| a1 | Frozen system prompt | (a) | Fort ($ : chaque tour au lieu de recalculer le system) | Faible (déjà en partie en place) | **P1** |
| a2 | Sérialisation bit-stable + test diff | (a) | Fort (protège tout le reste) | Faible (tests) | **P1** |
| a3 | Statique en tête / volatils en fin | (a) | Moyen-Fort | Faible | **P1** |
| b1/b2 | 3 breakpoints + ancre dernier-user (positionnelle) | (b) | Fort (boucle d'outils : 91.9 % mesuré) | Faible (vérifier ancrage positionnel + invariance) | **P1** |
| b3 | Breakpoint system toujours présent | (b) | Moyen | Faible | P1/P2 |
| d1/d2/d3 | prompt_cache_key + session-affinity + invariant modèle | (d) | Moyen (protège localité) | Très faible | **P1** |
| c1 | TTL long par défaut | (c) | Moyen (évite les miss 5 min) | Très faible | **P1** |
| b5 | Dialectes/compat + fallback 400 | (b) | Moyen (robustesse, évite les write taxes) | Moyen | P2 |
| a4 | Projet (cwd/AGENTS.md) hors préfixe system | (a) | Moyen (robustesse multi-repo/resume) | Moyen | P2 |
| e1/e2 | Compaction préservant le préfixe + seuil tokens | (e) | Fort sur sessions longues | Moyen-Fort | P2 |
| d4 | Resume bit-identique (fingerprint) | (d) | Moyen (hérite du 24 h) | Moyen | P2 |
| a5 | Maintien au-dessus du seuil | (a) | Faible-Moyen | Faible | P2 |
| b4/e3 | Exclusion tool results / contenu one-shot (hybride) | (b)/(e) | Moyen (latence + $) | Moyen | P2/P3 (mesurer d'abord) |
| c2/c3/c4 | Keepalive probabiliste | (c) | Moyen (sessions à pauses) | Moyen-Fort | **P3** (incertain : H5 jamais testé) |
| e4/e5 | Ordre stabilité décroissante + hygiène non-prefix | (e) | Faible-Moyen | Faible | P3 |
| d5 | `store:false` | (d) | Faible ($) | Trivial | P3 |

**Lecture** : P1 = ce que le harness devrait **déjà faire et verrouiller par tests** (stabilité + localité + levier TTL). P2 = les gains économiques ciblés (résumé/compaction, resume, exclusion hybride) — tous conditionnés à la mesure. P3 = les leviers incertains ou cosmétiques (keepalive tant que le comportement TTL glissant/lecture n'est pas établi ; règles d'hygiène).

---

## 8. Limites et questions ouvertes (à arbitrer par l'orchestrateur)

1. **Non-déterminisme du cache OpenAI même bit-identique** : quel niveau de confiance donner à `prompt_cache_key` et aux hits attendus ? Implique de mesurer les taux par (provider, modèle), pas de présumer.
2. **Le TTL est-il prolongé par les lectures ?** Documenté de façon contradictoire. C'est la variable qui décide si le keepalive (c2) a un sens — à établir par expérience avant tout investissement.
3. **Seuil Anthropic 1024 vs 2048** : change la rentabilité des préfixes courts (system minimal) — à confirmer sur les modèles effectivement utilisés.
4. **Où tracer la frontière entre historique et messages récents** (e4) et entre « conversation cacheable » et « conversation exclue » (b4) : deux seuils de conception à calibrer par mesure, pas par intuition.
5. **Compaction et qualité agent** : les gains $ (e1) ne doivent pas être achetés au prix d'une dégradation mesurable des tâches — les tests de qualité doivent accompagner les tests de cache.
6. **Télémétrie locale vs observabilité produit** : les métriques (`cache-waste` en $, causes de miss) sont la precondition de *toutes* les optimisations P2/P3 ; sans elles, les régressions sont silencieuses.

---

## 9. Synthèse en une phrase

Le harness cache-optimal fait trois choses : **il ne casse jamais le préfixe qu'il a lui-même construit** (a1/a2/a3/b1/b2), **il aide le provider à retrouver ce préfixe** (b/d/c1), et **il mesure ce qui se passe** (observabilité) avant d'activer les leviers qui touchent la structure du contexte ou le keepalive (e/c2).