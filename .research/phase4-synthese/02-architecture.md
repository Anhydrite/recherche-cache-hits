# Phase 4 — 02 : Gouvernance cible du cache pour pi (synthèse architecturale)

> **Rédigé par** : sous-agent synthétiseur architectural
> **Sources** : phase2-analyse/02-gouvernance-pi.md (analyse du code, fuites F1-F7) ; phase3-blind/01-blind-harness.md (idées I-01…I-30) et 02-blind-infra.md (a1…a6, b1…b5, c1…c4, d1…d5, e1…e5) ; croisés avec les rapports phase 1 (harnesses, infra, littérature) et les mesures H1-H6.
> **Mandat** : définir la gouvernance cible du cache de pi — principes, architecture du system prompt, TTL/keepalive/clé, compaction, métriques, plan d'implémentation par étapes. Réaliste : des incréments ciblés dans la codebase pi, pas une refonte.

---

## 0. Résumé exécutif

pi a déjà une architecture de cache mature (breakpoints aux 3 frontières, cwd en queue de system, clé de session stable, mesure économique des misses, compaction consciente, deferred tool loading). **La gouvernance cible ne part pas de zéro : elle verrouille ce qui est bon, et élimine les deux fuites structurelles restantes.**

1. **Fuite principale (F1)** : le system prompt intègre les snippets outils + guidelines dérivées → tout changement du set d'outils régénère le system → **miss total** (H1). Cible : **rendre le system strictement outil-indépendant** — guidelines dérivées et annuaire des outils relogés dans le premier message user (bit-stable), le contenu du system devenant une fonction pure de (version pi, projet, config canonique).
2. **Fuite secondaire (F3)** : changement de modèle/effort en session = clé de cache différente → miss du préfixe entier. Cible : **le gel de clé comme événement gouverné** — pi le mesure déjà (`modelChanged`) ; il doit le *prévenir* (avertissement) au lieu de le constater.
3. **Leviers à activer** (par ordre : TTL long par défaut → append-only du rebuild → construction canonique inter-sessions → keepalive conditionnel) : tous documentés dans le blind, alignés avec le consensus 2026 (frozen system prompt, arXiv 2601.06007, arXiv 2607.19214).
4. **L'observabilité est le prérequis de tout** : la métrique la plus importante à ajouter est un **compteur de rebuilds du system en session** (chaque rebuild = miss total annoncé) et le **hit-rate du premier appel** (qui mesure la réutilisation inter-sessions).

---

## 1. Les principes de gouvernance (a)

Les principes sont les décisions de design qui protègent le cache. Ils déclinent l'invariant unique — *un octet qui change dans le préfixe invalide tout le suffixe* — en règles opératoires.

### P1 — Le system prompt est une fonction pure, jamais régénérée en session
`system = F(version_pi, repo, config_canonique)` — zéro composante non déterministe : pas d'horodatage, pas d'ordre de découverte non trié (MCP), pas de chemin machine-dépendant, tri canonique de tout ce qui est listé (idée blind I-01, a1). **Conséquence opératoire** : toute évolution en session (nouvel outil, skill, contextFile) = **append en fin de la zone concernée ou message suivant**, jamais réécriture du bloc initial. Le CI doit vérifier le déterminisme (hash à froid 2×).

### P2 — Le system prompt ne dépend JAMAIS du set d'outils actifs
C'est la traduction directe de la fuite F1 (I-03). Les snippets de la liste « Available tools: » et les guidelines dérivées (`hasBash||hasPowerShell → "Use bash…"`) sortent du system. Leurs destinations : les `description` des tools (cacheable, breakpoint derrière le dernier tool) et un bloc d'instructions opérationnelles **en tête du premier message user** (bit-stable pour toute la session). Un changement d'outils ne peut alors produire qu'un miss partiel court (le bloc du premier message a changé), jamais un miss du system.

### P3 — Statique en tête, volatile en queue, hiérarchie de stabilité officielle
Ordre contraint et vérifié par tests (I-05) : intro+doc figées par version → couche projet → annuaire/goodies → **cwd et état en toute dernière ligne** (déjà en place, H3 : ~100 tokens de miss partiel au changement de repo — à préserver). Interdiction formelle d'injecter timestamp/ID/état dans le préfixe (pi a déjà corrigé la date, CHANGELOG #6621).

### P4 — Tout changement de clé est un événement gouverné
Trois entrées de la clé sont sous contrôle pi : le **contenu du préfixe** (P1-P3), le **modèle/effort** (F3), et la **route/clé de session**. Règle : changer l'un en session est une décision explicite, mesurée (coût ex post via `computeCacheWaste`, idée I-27 = prédiction ex ante) et annoncée à l'utilisateur — jamais un effet de bord silencieux (extension, skill, hook).

### P5 — La stabilité prime sur la fraîcheur
Un contextFile qui change en session est traité comme le cwd : **différé à la frontière suivante** (fin de tour, nouvelle session) ou append réfléchi en fin de couche projet — pattern Claude Code (« les modifs de CLAUDE.md s'appliquent au prochain cycle », I-06) : grouper et avancer les invalidations inévitables, le coût d'un miss étant proportionnel à la longueur de la conversation.

### P6 — Ne pas cacher ce qui ne sera jamais relu (anti-overcaching)
Les contenus one-shot (gros tool_results, résultats de commandes) et les entrées compaction/branch_summary ne doivent pas générer de writes payants : breakpoint seulement aux 3 frontières (jamais sur contenu unique), `scan()` continue d'exclure les misses attendus, troncature à la source des sorties d'outils (I-07). Le hit-rate n'est pas la seule métrique : **le coût des writes et le TTFT comptent autant** (« Overcaching Tax » ; GPT-4o en full-context = −8.8 % TTFT).

### P7 — Le cache se gouverne aussi entre sessions
L'unité d'optimisation n'est pas la session, c'est (repo × modèle × fenêtre temporelle). Construction canonique (I-01) + empreinte repo stable (I-02) + clé de route stable font du **premier appel d'une session un hit partiel** sur le system écrit par les sessions précédentes. Le TTL long est l'outil principal de cette fenêtre inter-sessions (1 h/24 h = « keepalive gratuit »).

### P8 — Les extensions sont une surface de gouvernance, pas une zone de non-droit
Les hooks `before_request` / `before_payload` / `onPayload` / `systemPromptOverride` peuvent injecter du volatil dans le préfixe (F4, I-23). Règle : doc extensions encadrant ces surfaces (« le préfixe est stable, positionnez votre volatil en fin de premier message ») + avertissement runtime si le hash du système change hors points autorisés (lint « prefix-stable »).

### P9 — Mesurer, pas présumer
Le cache OpenAI n'est pas garanti même bit-identique (reports 2025-2026). Toute décision de gouvernance (keepalive, politique par session, clé projet) est validée par mesure sur le terrain (SLO par (provider, modèle), I-22), jamais par intuition. Un `cached_tokens=0` ponctuel n'est pas un bug : il se diagnostique via `CacheMiss{idleMs, modelChanged}` et `computeCacheWaste`.

### P10 — La sécurité est une entrée de gouvernance
Le cache = fuite potentielle (timing side-channels, Stanford ICML 2025 ; data residency). Interdiction de secrets dans le préfixe cacheable ; documenter le modèle de menace pour les environnements sensibles (rétention longue à valider contractuellement, I-12).

**Croisement avec le blind** : P1←I-01/a1/a2 ; P2←I-03/a4 ; P3←I-05/a3 ; P4←d3/I-27 ; P5←I-06 ; P6←I-07/b4/I-14 ; P7←I-02/I-11/I-12 ; P8←I-23 ; P9←I-22 ; P10←littérature (Stanford).

---

## 2. Architecture cible du system prompt (b)

### 2.1 État actuel (diagnostic confirmé phase 2)

```
Ordre actuel de buildSystemPrompt() :
1. Intro fixe "You are an expert coding assistant..."            [FIXE]
2. "Available tools:" + - <name>: <snippet>                      [F1 ⚠️ dépend du set d'outils]
3. "In addition to the tools above..."                           [FIXE]
4. "Guidelines:" + guidelines                                    [F1 ⚠️ dépendent des outils]
5. Bloc "Pi documentation" (README/docs)                         [FIXE par version]
6. [appendSection utilisateur]                                   [stable si configuré]
7. [project_context — contextFiles]                              [variable par projet]
8. [Skills formatés]                                             [appends]
9. "Current working directory: <cwd>"                            [VOLATILE, en fin ✓]
```

Bilan : positions 2 et 4 cassent P1/P2 (rebuild → miss total mesuré H1) ; la position 9 est le bon design (H3 validé) ; l'absence de date est déjà corrigée (#6621) ; le mode OAuth Claude Code envoie un bloc system fixe supplémentaire avec son propre breakpoint (bon pour la localité).

### 2.2 Structure cible : trois couches de stabilité

```
┌─ COUCHE A — NOYAU FIGÉ (frozen kernel) ─────────────────────────────
│  A1. Intro fixe "You are an expert coding assistant..."           [figé]
│  A2. Bloc "Pi documentation" épinglé au hash de version pi         [figé par version]
│  A3. Guidelines statiques (indépendantes de tout outil,            [figé par version]
│      ordre canonique ; les guidelines dépendantes d'un outil
│      sont relogées dans B/tool descriptions — cf. 2.3)
│  A4. [appendSection utilisateur]                                   [append initial seulement]
├─ COUCHE B — COUCHE PROJET (stable en session, appends seulement) ──
│  B1. project_context (contextFiles) — triés par chemin canonique   [append réfléchi, jamais
│      [nouveau tri], changement en session = append en fin de       réordonnancement]
│      cette sous-couche, différé à la frontière (P5)
│  B2. Skills formatés — triés par nom                               [append ordonné]
│  B3. [Empreinte repo (I-02) — option étoile, épinglée à HEAD]      [régénérée sur commit]
├─ COUCHE C — QUEUE VOLATILE (au plus tard possible) ────────────────
│  C1. Annuaire des outils disponibles (noms seuls, tri canonique)   [append si changement,
│      — à masquer derrière flag si redondant avec l'API tools]      sinon figé]
│  C2. "Current working directory: <cwd>"                            [VOLATILE — dernier ✓]
└────────────────────────────────────────────────────────────────────
```

**Règle d'or de l'assemblage** : le contenu de chaque couche a un taux de stabilité ≥ à celui de la couche suivante ; tout élément qui change en session est soit différé (P5), soit appendé en fin de sa couche — jamais inséré au milieu, jamais réordonné. Le test d'ordre « prefix-stability » (déplacer un composant simulé → le hash du préfixe ne change qu'à l'emplacement autorisé) devient une condition de CI (I-05).

### 2.3 Intégration des outils sans régénération (cœur de F1)

La cible est une **triple relocalisation**, par ordre croissant d'effort :

1. **`description` des tools = l'endroit unique de la doc outil** (riche, bit-stable, cacheable côté Anthropic avec le breakpoint sur le dernier tool). C'est déjà la destination recommandée par extensions.md (les extensions devraient écrire une `description` riche sans `promptSnippet`/`promptGuidelines`).
2. **Guidelines dérivées des outils** (`hasBash || hasPowerShell → …`) : sortent du system vers un bloc **« Operating instructions » en tête du premier message user** — créé au tour 1, bit-stable pour toute la session, positionné juste après le system dans le flux de préfixe (a4 / a3). Si le set d'outils change en session, ce bloc est régénéré **en restant le premier message** : le miss qui en résulte est partiel (le system reste intact et les tours qui suivent re-matchent), là où aujourd'hui c'est un miss total (H1 : cr = 0 pour un rebuild « milieu »).
3. **Annuaire « Available tools: »** : soit supprimé (les outils sont déjà déclarés dans le paramètre API `tools` — la liste system est redondante), soit réduit à un listing de **noms triés canoniquement** placé en C1, en queue. Dans les deux cas, l'ajout d'un outil en session ne touche jamais la couche A.

**Règles d'hygiène du set d'outils** (appliquées dès maintenant, sans refonte) :
- **Tri canonique des définitions d'outils par nom** — l'ordre de découverte MCP est non déterministe ; réordonner une liste = miss (1 octet).
- **Activations mid-session différées** : tout ajout d'outil (MCP, skill, extension) est appliqué au prochain cycle (I-06) ou en append du bloc Operating instructions — jamais par rewinder du system.
- **Deferred loading par défaut** : généraliser `splitDeferredTools` (immediate/deferred) pour que le set immediate reste stable, y compris pour les outils sans snippet (la seule voie cache-friendly déjà documentée).
- **Garde-fou mesure** : un compteur de `_rebuildSystemPrompt` en session (toute valeur > 0 hors tour 1 = événement gouverné, cf. §5).

### 2.4 Tableau de synthèse de la cible

| Bloc | Figé / Appendé / Volatile | Changement en session | Coût d'un changement |
|---|---|---|---|
| A1 intro | figé | — | — |
| A2 doc pi | figé par version | upgrade pi | miss unique du 1er tour (F7, négligeable) |
| A3 guidelines statiques | figé par version | — | — |
| A4 appendSection | figé après le 1er tour | changement de config | miss partiel court |
| B1 project_context | stable, tri canonique | différé à la frontière (P5) | miss partiel de la couche B |
| B2 skills | appends ordonnés | nouveaux skills en fin | miss partiel court |
| B3 footprint repo (opt.) | épinglé à HEAD | commit | miss limité au bloc (I-30) |
| C1 annuaire outils | append en fin (noms triés) | outil ajouté/retiré | miss partiel court (vs miss total aujourd'hui) |
| C2 cwd | **volatile, dernier** | navigation repo | ~100 tokens (H3, vérifié) |
| Operating instructions (1er user msg) | bit-stable en session | set d'outils change | miss partiel du premier message |
| Tools (param API) | descriptions bit-stables | outil ajouté | miss partiel de la définition |

---

## 3. Stratégie TTL / keepalive / clé (c)

### 3.1 TTL : long par défaut, politique par session

- **Recommandation** : `PI_CACHE_RETENTION=long` (Anthropic 1 h / OpenAI 24 h) **par défaut** quand `supportsLongCacheRetention` (I-12, c1). C'est le levier au meilleur rapport coût/bénéfice : il élargit la fenêtre de réutilisation sans effort ni ping — adresse la cause n°1 de miss mesurée (`CacheMiss{idleMs}`).
- **Politique par session** (alignement opencode CachePolicy, faiblesse n°4 identifiée en phase 2) : exposer `cacheRetention ∈ {off | short | long | adaptive}` en option de run, en plus de la variable globale. `adaptive` = « long si la session a déjà montré des hits, short sinon » — évite d'écrire des caches pour des sessions à usage unique (anti-write-tax, P6).
- `retention: "none"` reste le bouton d'arrêt propre (ni breakpoint, ni clé, ni headers d'affinité) — à conserver tel quel.
- **Réserve** : dans les environnements régulés, la rétention longue est un choix de gouvernance (résidu de données côté provider) — documenter, ne pas forcer.

### 3.2 Keepalive : conditionnel, et seulement après mesure

Le keepalive (I-10, c2/c3/c4, arXiv 2607.19214) est **P3** — il n'est pas un gain certain tant que deux questions ne sont pas tranchées par la mesure : (a) les **lectures prolongent-elles le TTL** sur les providers cibles ? Si non, le ping est inutile et coûteux ; (b) la probabilité de reprise justifie-t-elle le coût des pings (`P(reprise) × bénéfice > coût`).

Contraintes de design si activation :
- **Ping = lecture pure** : même payload de préfixe (system + tools + dernier message user), `max_tokens ≈ 1`, température 0, sans nouveau contenu — jamais un ping qui réécrit (write 1.25×).
- **Déclencheur probabiliste** : ne pinger que les sessions « vivantes en attente » (dernier échange récent, processus en cours), jamais les sessions abandonnées ; cadence calée sur TTL/2 (aider : toutes les 5 min, `AIDER_CACHE_KEEPALIVE_DELAY`).
- **Implémentation pi** : timer d'idle dans le cycle de session (à côté de `_checkCompaction`), option `PI_CACHE_KEEPALIVE` ; le seuil de rentabilité est défini par les stats `idleMs` existantes (distribution des reprises mesurée sur le terrain avant mise en prod).

### 3.3 Clé et localité : verrouiller ce qui existe

Ce que pi fait déjà bien (à préserver absolument) : sessionId uuidv7 persisté (resume bit-identique, H6 validé), `prompt_cache_key` clampé 64 chars (#4720), 3 formats d'affinité de route (openai / openrouter / openai-nosession), `x-session-affinity` Anthropic. La gouvernance cible ajoute :
- **d1 — Verrouillage du sessionId en session** : audit des chemins de rotation (branches, undo, `/new`, navigation tree) ; le sessionId ne change qu'avec une décision explicite de nouvelle conversation. À chaque rotation, le préfixe reste le même mais la topologie de route change → miss possible : c'est un événement gouverné (P4).
- **d2 — Headers stables** : figer user-agent et `x-client-request-id` (un par session, pas aléatoire) sur tous les appels (I-21, coût nul).
- **d3 — Modèle/effort gelé en session** : ne jamais changer de modèle/effort/endpoint en cours de tour sans avertissement « miss total annoncé » (F3). Détecter aussi les surclassements silencieux du provider (rollout change) via les stats de cache, pas les logs.
- **d4 — Resume bit-identique** : le fingerprinter `sysHash` existant s'étend au prompt complet (tools + couche projet) : le diff byte-à-byte entre le dernier tour et le prompt reconstruit au `pi resume` doit être vide (d4) — c'est le test qui garantit l'héritage du cache long (24 h) entre deux processus.
- **I-11 (spéculatif) — clé par projet** : pour les sessions courtes répétées (le pattern quotidien), `prompt_cache_key = H(provider ∥ modèle ∥ repo_id)` partagée entre sessions du même repo, à n'activer qu'après mesure (risque d'éviction mutuelle entre sessions lourdes parallèles — I-25).

---

## 4. Stratégie de compaction / contexte préservant le préfixe (d)

### 4.1 État actuel : déjà consciente, deux trous à combler

pi compacte sur seuil de tokens (`contextTokens > contextWindow − reserveTokens`, défauts : reserve 16384, keepRecent 20000). Le résumé est inséré après le system, **persisté entre compactions** (`previousSummary`), et `scan()` exclut les entrées compaction/branch_summary du calcul de fuite. Bilan : le tour post-compaction est un miss total **inévitable** (le contenu a changé), mais les tours suivants re-matchent le nouveau préfixe [system + summary + tours récents] — c'est le bon design (e1). Les deux trous :

1. **Déterminisme du résumé non garanti** : si le résumé contient des éléments non déterministes (ou est régénéré différemment), le nouveau socle n'est pas bit-stable → chaque tour post-compaction est un miss.
2. **Régénération du résumé à chaque compaction suivante** : à la 2ᵉ compaction, le résumé ancien est lui-même résumé → le préfixe change de nouveau → miss total répété (I-04).

### 4.2 Cible

1. **Résumé = fonction déterministe** : même template, même ordre des sections (jamais de timestamp dans le résumé — il appartient au préfixe cacheable), contenu canonique. Test CI : deux compactions du même historique → résumés bit-identiques.
2. **Le résumé reste le socle : bit-stable entre compactions** : une 2ᵉ compaction produit un **résumé incrémental qui s'append au bloc résumé existant** (le delta en fin de bloc, les blocs précédents intacts — esprit I-26, forme simple : extension du `previousSummary` plutôt que réécriture). Le préfixe [system + summary v1] survit à la 2ᵉ compaction.
3. **Anchor bit-stable (I-04, option à tester)** : conserver les 1-2 premiers tours **en brut** (jamais résumés), juste après le system ; seul le milieu est résumé. Le préfixe commun inter-compactions devient [system + anchor] au lieu de [system] → les longs hits post-compaction couvrent une part substantielle du préfixe.
4. **Frontière de suppression** : ne jamais supprimer/compacter de messages **avant** le dernier breakpoint stable (ne toucher que ce qui est derrière la frontière de réutilisation — I-07) ; pour les tool_results périmés, troncature à la source plutôt qu'attente de la compaction de masse (opencode fait déjà cette purge ; pi ne la fait pas).
5. **Fréquence maîtrisée** : rendre les compactions rares (réserve/budget calibrés) et dimensionner la réserve **par coût attendu** (I-29, option) : élever la réserve quand le préfixe est cher (gros system + footprint), la réduire sinon.
6. **Post-compaction : vérifier le seuil** : le nouveau préfixe (system + résumé + tours récents) doit rester ≥ 1024 tokens (a5), sinon la session bascule en non-cacheable avec régression TTFT (10-18 % mesurée sous les seuils). Si le résumé est trop court, l'épaissir (ou allonger `keepRecentTokens`) avant de repartir.

### 4.3 Branches et forks

Rester **append-only** (I-09) : au fork, ne jamais muter les messages antérieurs au point de divergence ; le passé partagé reste bit-identique et le premier appel de la branche matche le préfixe commun. Hériter le résumé compacté du parent (déjà : branch_summary) avec une clé de route dérivée stable du parent. L'undo/rewind au-delà du dernier tour est signalé comme miss volontaire (P4).

---

## 5. Métriques de gouvernance (e)

### 5.1 Ce qui doit être visible (tableau de bord)

| # | Métrique | Source pi existante | Lecture / seuil d'alerte |
|---|---|---|---|
| M1 | **Compteur de rebuilds du system en session** | `_rebuildSystemPrompt` (à instrumenter) | **> 0 hors tour 1 = miss total annoncé** (F1) — LA métrique de gouvernance n°1 |
| M2 | Hit-rate CH par (provider, modèle) | footer R/W/CH, `/session` (`cacheRead/promptTokens`) | < 85 % en boucle d'outils = régression à investiguer ; < 40 % durable = auto-toggle off (I-22) |
| M3 | **Hit-rate du 1er appel** (turn-1) | `asPreviousRequest` (à agréger) | mesure la réutilisation inter-sessions (I-01/I-02) : doit croître avec les sessions du même repo |
| M4 | Waste en $ | `computeCacheWaste` (missedTokens > 1024, missedCost) | pic > budget par session ; seuil 1024 conservé |
| M5 | Changement de modèle en session | `detectMiss.modelChanged` | tout switch = miss total annoncé (F3), décompte par session |
| M6 | Idle entre requêtes | `idleMs` | > TTL (5 min / 1 h) → candidat keepalive ; alimente la distribution P(reprise) |
| M7 | Compactions | événements `compaction_start/end` (existant) | fréquence élevée = problème de fenêtre ; + assert « résumé bit-stable entre compactions » |
| M8 | Writes (cache_creation_input_tokens) | usage Anthropic | ratio writes/reads élevé = sur-caching (P6) ; surveiller le TTFT en parallèle |
| M9 | Télémétrie OTLP | `pi.ai.usage.cache_read/write_tokens` | agrégation multi-sessions, dashboards |
| M10 | Stability fingerprint | `sysHash` (existant) étendu au prompt complet | diff du préfixe par requête ; alerte si changement hors points autorisés (I-23) |

### 5.2 Boucle de gouvernance

1. **Constater** : M1-M10 par session et agrégés par (provider, modèle).
2. **Expliquer** : chaque miss significatif se classe en `idleMs` / `modelChanged` / `toolsetChanged (M1)` / `compaction` / `extHook (M10)` / `provider (non déterministe)` — la taxonomie est déjà à moitié dans `CacheMiss{}`.
3. **Décider** : seuils → alertes (`showCacheMissNotices` passe en default-on dès que la taxonomie est fiable) ; auto-toggle I-22 pour les providers défaillants (basculer off/short en cas de hit-rate < 40 % durable — cas réel OpenAI GPT-5 « borked »).
4. **Prévenir** : M1/M5 deviennent des **avertissements ex ante** (I-27) : « ce changement d'outils va coûter ~N tokens relus (~X¢) — continuer ? » ; le coût est estimé depuis le préfixe courant.

---

## 6. Plan d'implémentation par étapes (f)

Ordre voulu : **low risk → high impact**, chaque étape livrant une amélioration autonome et mesurable, sans refonte. Les fichiers/symboles pi à toucher sont indiqués (références du bundle, phase 2).

### Étape 0 — Verrouiller l'existant (coût quasi nul, P1)
- Tests **prefix-invariance** (pattern goose) : poser les `cache_control` ne modifie pas le hash du préfixe (b1).
- Test **snapshot wire** (a2) : diff byte-à-byte du préfixe entre 2 tours → vide.
- Test **déterminisme du system** : `buildSystemPrompt` 2× à froid → hash identique (prérequis I-01).
- Audit **sessionId** : aucune rotation en session (d1) ; headers stables (I-21).
- *Critère de sortie* : CI vert incluant ces 4 tests ; zéro changement de comportement.

### Étape 1 — Discipline d'assemblage (risque faible, gains H1 exploités)
- **Append-only du rebuild** : toute modification du system en session = append en fin de zone, jamais d'insertion ou réordonnancement (transforme le miss total en miss partiel ×3.5, mesuré H1).
- **Tris canoniques** : outils par nom, contextFiles par chemin canonique, skills par nom (I-01 partiel).
- **Guidelines dérivées précalculées** dans un ordre fixe keyé par nom d'outil (l'ajout d'un outil append sa guideline en queue au lieu de réordonner).
- **TTL long par défaut** quand `supportsLongCacheRetention` (c1, I-12) + instrumentation M1 (compteur de rebuilds) et M3 (turn-1 hit).
- *Critère de sortie* : sur session avec ajout d'outil MCP en cours, `cache_creation_input_tokens` ≠ 0 (au lieu de cr = 0) ; M1 visible dans `/session`.

### Étape 2 — Découplage system ↔ outils (F1, l'étape structurante)
- Reloger guidelines dérivées + annuaire dans le bloc **« Operating instructions » en tête du premier message user** (P2) ; `description` outil = doc unique ; system strictement outil-indépendant.
- Mode compat : les extensions utilisant `promptSnippet`/`promptGuidelines` émettent un avertissement de migration (leur contenu est relogé dans le premier message, pas dans le system).
- **Compaction déterministe** (e1) : résumé template fixe + bit-stable entre compactions + vérification du seuil post-compaction (a5) + purge des tool_results uniquement derrière la frontière (I-07).
- **Politique par session** `cacheRetention` (off|short|long|adaptive) — option de run, pas seulement variable globale.
- *Critère de sortie* : changer le set d'outils en session longue → le hit-rate des tours suivants revient au niveau pré-changement (miss partiel mesuré < rebuilt actuel) ; résumé bit-identique entre 2 compactions consécutives.

### Étape 3 — Réutilisation inter-sessions (I-01/I-02, le plus gros gain potentiel)
- **Construction canonique complète** : version pi épinglée dans le system (hash), chemins **relatifs au repo** (cross-machine), ordre 100 % déterministe, CI de hash à froid.
- **Empreinte repo épinglée à HEAD** (I-02/I-30) : bandeau projet (README condensé, structure, index de symboles, AGENTS.md) régénéré seulement sur commit — épaissit le préfixe commun inter-sessions et fait dépasser les seuils (Gemini 4096).
- **Keepalive probabiliste** : d'abord la mesure (les lectures prolongent-elles le TTL ? distribution des reprises via M6), puis ping lecture pure calé TTL/2 sur sessions « vivantes en attente » (c2/c3/c4).
- *Critère de sortie* : M3 (turn-1 hit) > 0 sur sessions séquentielles du même repo (system ≥ 1024 tokens) ; keepalive activé seulement si l'expérience le justifie, sinon resté en option désactivée.

### Étape 4 — Prévention et pilotage (optionnel, spéculatif)
- **Lint « prefix-stable »** pour extensions et hooks : hash avant/après transformation du payload, alerte si changement hors points autorisés (I-23) ; avertissement ex ante du coût d'un miss (I-27).
- **Auto-toggle SLO** par (provider, modèle) (I-22) : bascule automatique off/short sur hit-rate < 40 % durable.
- **Anchor bit-stable à travers compactions** (I-04) et **clé par projet** (I-11), uniquement après validation sur le terrain (I-25 pour le parallélisme).
- *Critère de sortie* : aucun miss inexpliqué dans la taxonomie M1-M10 sur 2 semaines de télémétrie.

### Étapes à ne pas faire (déclassées)
- Sortir le cwd du system (H3 réfutée : bruit inter-sessions).
- Breakpoints par rôle (piège du tool_result sur dernier user ; rester positionnel, comme goose).
- Cacher tout partout (overcaching tax P6).
- Compact « delta » append-only intégral (I-26) : complexité/risque mémoire élevés ; la forme simple de l'étape 2 (résumé incrémental) couvre l'essentiel.

---

## 7. Décisions à trancher par l'orchestrateur

1. **Périmètre du découplage F1 (étape 2)** : relogement des guidelines dans le premier message user vs enrichissement des descriptions seules — les deux, dans cet ordre (l'annuaire doit rester visible du modèle : un annuaire de noms en tête de premier message + descriptions riches est le compromis qualité/sécurité cache).
2. **TTL long par défaut** : oui/non selon la gouvernance données des environnements cibles (résidu de cache 1 h/24 h chez le provider).
3. **Keepalive** : attendre la mesure « lectures prolongent le TTL ? » avant tout développement (sinon perte sèche).
4. **Compat extensions** : le découplage F1 est un changement de comportement pour les extensions avec `promptSnippet`/`promptGuidelines` — briser en douceur (avertissement + migration) ou en dur (flag) ?
5. **Clé par projet (I-11)** : à n'envisager qu'après visualisation de M3 (si le turn-1 hit est déjà bon via I-01, le gain marginal est faible et le risque d'éviction mutuelle reste).

---

## 8. Correspondance idées blind → gouvernance pi (rappel)

| Idée blind | Où elle s'incarne dans la gouvernance cible | Statut |
|---|---|---|
| I-01 construction canonique | P1, §2.2, étape 3 (CI de hash, tris canoniques) | à partir de l'étape 0 |
| I-02 empreinte repo | P7, B3, étape 3 | optionnel (étoile) |
| I-03 découplage system↔outils | P2, §2.3, étape 2 | **cœur de la cible** (F1) |
| I-05 ordre canonique + CI | P3, §2.2, étape 0-1 | établi |
| I-06 groupement/avance des invalidations | P5, différé à la frontière | étape 1 |
| I-07 suffixe minimal | P6, §4.2 point 4 | étape 2 |
| I-10 warmup + keepalive | §3.2 (conditionnel) | étape 3, P3 |
| I-11 clé par projet | §3.3 (spéculatif) | étape 4 |
| I-12 TTL long + politique par session | §3.1, étape 1-2 | établi |
| a1 frozen system | Couche A, P1 | à verrouiller |
| a4 projet hors préfixe system | Couche B, §2.3 | étape 1-2 |
| d3 modèle/effort stable | P4, F3, §3.3 | étape 0 (audit) + mesurer |
| d4 resume bit-identique | §3.3 d4 (sysHash étendu) | étape 0 |
| e1 compaction préservant le préfixe | §4.2 | étape 2 |
| I-22 SLO/auto-toggle | §5.2, M2 | étape 4 |
| I-23 lint préfixe-stable | P8, M10 | étape 4 |
| I-04 anchor | §4.2 point 3 | étape 4 (à tester) |

---

## 9. Synthèse exécutive

- **La gouvernance cible de pi tient en 3 verbes** : **geler** ce qui est stable (system = fonction pure, outil-indépendant), **appendre** ce qui change (outils, skills, context, config — jamais réécrire le passé), **mesurer** tout le reste (rebuilds en session, turn-1 hits, waste en $, compactions) avant d'activer les leviers incertains (keepalive, clé projet, anchor).
- **Le chantier structurant est le découplage system ↔ outils (F1)** : il transforme le miss total le plus fréquent (changement de set d'outils, MCP, plugins) en miss partiel court. Il est à mi-chemin du plan (étape 2) : la discipline d'assemblage (étape 1) et le verrouillage par tests (étape 0) le préparent à risque nul.
- **Le gain le plus sous-exploité est inter-sessions** : construction canonique + empreinte repo (étape 3) font du premier appel d'une session un hit — c'est le levier ×2-×5 du blind, et pi a déjà 80 % de ce qu'il faut (frozen system, clé stable, resume bit-identique).
- **Les fuites restantes après le plan** : non-déterminisme OpenAI (externe, à surveiller via SLO), changements silencieux de rollout côté provider (F7), releases de pi (miss unique négligeable), et le keepalive tant que « lectures prolongent TTL ? » n'est pas tranché.