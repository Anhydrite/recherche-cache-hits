# Phase 3 — 01 (blind) : Brainstorming général — maximiser le cache-hit d'un agent de codage en terminal

> **Nature** : exercice aveugle d'ingénierie. Toutes les idées d'optimisation imaginables sont proposées, y compris hors-sentier battu, sans pré-validation. Chaque idée : (1) mécanisme exact, (2) pourquoi elle devrait améliorer le hit-rate, (3) risque/coût, (4) protocole de test. Classées par **impact potentiel estimé** (ordre de grandeur qualitatif sur l'économie de tokens relus / le nombre de misses évités).
> **Statut des idées** : `[établi]` = consensus documenté (phases 1-2, mesures pi H1-H6, littérature) ; `[à tester]` = plausible, mécanisme clair, non mesuré ; `[spéculatif]` = mécanisme plausible mais risque élevé ou dépendance provider.
> **Rappel des contraintes du mécanisme (ce qui dérive toutes les idées)** :
> 1. Cache = **préfixe de tokens exact** (bit-identique) ; 1 octet changé en tête = tout ce qui suit est relu.
> 2. Le **modèle fait partie de la clé** ; le TTL borne la fenêtre de réutilisation (5 min → 24 h selon provider/rétention).
> 3. En cache **implicite** (OpenAI/Gemini) le client ne contrôle que *la stabilité du texte* + la *clé de routage* (`prompt_cache_key`, session-affinity). En **explicite** (Anthropic) il contrôle en plus les ≤ 4 breakpoints.
> 4. Seuils minimaux : ≥ 1024 tokens de préfixe (OpenAI/Anthropic), ≥ 4096 (Gemini) ; sous le seuil, pas de cache et TTFT en régression.
> 5. Le coût d'un miss = **préfixe entier** (system + historique) ; il **croît avec la longueur de la conversation**.

---

## 0. Carte du territoire : les 9 leviers fondamentaux

Toutes les idées ci-après sont des déclinaisons de 9 leviers élémentaires :

| # | Levier fondamental | Déclinaison typique | Idées |
|---|---|---|---|
| L1 | **Allonger le préfixe commun** | system prompt volumineux mais figé, couches projet stables | I-01, I-02, I-04, I-16, I-18, I-19 |
| L2 | **Stabiliser le préfixe** (ne jamais le faire changer) | frozen system, volatile en queue, tri canonique | I-03, I-05, I-06, I-09, I-11 |
| L3 | **Rétrécir le suffixe relu** | tool_results courts, suppression des périmés, fenêtre | I-07, I-08 |
| L4 | **Placer la frontière optimalement** | breakpoints aux 3 frontières, ancrage par position | (déjà optimal chez pi — H2) |
| L5 | **Élargir la fenêtre temporelle** | TTL long, keepalive, warmup, cron | I-10, I-12, I-15 |
| L6 | **Stabiliser la route/clé** | sessionId, prompt_cache_key, headers, user-agent | I-11, I-13, I-14 |
| L7 | **Réutiliser entre sessions** | construction canonique, mémoire de session, préfixe partagé par repo | I-01, I-02, I-16, I-17 |
| L8 | **Minimiser la fréquence des invalidations inévitables** | grouper les changements tôt dans la session, compactions rares | I-06, I-08, I-20 |
| L9 | **Mesurer et piloter** | télémétrie, décision de cache par (provider, modèle), lint | I-21, I-22, I-23 |

---

## 1. Tranche A — Impact capital (ordre de grandeur : ×2 à ×5 sur l'économie, ou évite des misses de 10³–10⁴ tokens)

### I-01 — Construction canonique et déterministe du system prompt → réutilisation inter-sessions (LE levier généraliste)

- **Mécanisme exact** : faire du system prompt une **fonction pure** `system = F(version_pi, repo, config, set_outils_canonique)` — zéro composante non déterministe : pas d'horodatage, pas d'ordre de découverte MCP non trié, pas de chemin absolu machine-dépendant (chemins **relatifs au repo**), tri des contextFiles par chemin canonique, tri des définitions d'outils par nom, version de pi épinglée. Toute session qui démarre sur le même repo+config construit alors un system **bit-identique** à celui des sessions précédentes.
- **Pourquoi ça marche** : en cache implicite, le matcher n'a pas besoin de la « même session » — il a besoin du **même préfixe de texte**. Le system (~1-2k tokens, souvent 50-100 % du premier appel) devient le préfixe commun de *toutes* les sessions du repo. Le **premier appel d'une nouvelle session** matche alors le system des sessions passées (si TTL non expiré) → le démarrage passe de « miss total du premier tour » à « hit sur l'essentiel du préfixe ». C'est l'analogue « templating » de ce qui se passe déjà intra-session, mais à l'échelle inter-sessions. Bonus : même bénéfice *cross-machine* (2 laptops sur le même repo) si les chemins sont relativisés.
- **Risque/coût** : coût de développement élevé (refonte de `buildSystemPrompt` + discipline sur les extensions). Risque de régression si un composant non déterministe subsiste (le CI doit hasher le system à froid). Interaction avec les versions : une mise à jour de pi change F → miss unique au premier lancement post-upgrade (accepté, c'est l'invalidation voulue d'un changement de contenu).
- **Test** : CI de « prompt determinism » (construire le system 2× à froid, comparer les hash) + mesure terrain : deux sessions séquentielles sur le même repo, `cached_tokens` du *premier* appel de la session 2 (attendu > 0 si le system dépasse le seuil).

### I-02 — Couche « empreinte du repo » : un bandeau projet stable qui épaissit le préfixe commun inter-sessions

- **Mécanisme exact** : après le system, insérer un bloc `repo_footprint` généré une fois par (repo, HEAD) — README condensé, structure de dossiers, index de symboles, extraits AGENTS.md — et **épinglé à un hash du HEAD commit**. Tant que HEAD ne bouge pas, le bloc est bit-identique entre sessions et à chaque tour.
- **Pourquoi ça marche** : (a) il **allonge le préfixe commun** inter-sessions de plusieurs milliers de tokens (plus d'économie à chaque hit) ; (b) il fait **dépasser les seuils** (notamment Gemini 4096) ; (c) il est *utile au modèle* (pas du padding parasite — cf. l'overcaching tax qui ne s'applique pas à du contenu relu). C'est du « préfixe productif » : le contenu est payé une fois (write), relu à 0.1-0.5× ensuite.
- **Risque/coût** : si HEAD change souvent (branche active), le bloc change à chaque commit → le miss « périmée » ne touche que le bloc (s'il est en queue du préfixe, miss partiel ~taille du bloc) — acceptable. Coût mémoire : un gros bloc gonfle le prompt. Dérive : ne jamais y mettre de contenu volatile (statuts, timestamps).
- **Test** : A/B sur N sessions du même repo : avec/sans footprint ; mesurer `cached_tokens` du 1er appel et le coût relatif du « 2e tour » après un commit (attendu : miss partiel limité au bloc).

### I-03 — Découplage total system ↔ outils : zéro dépendance du system au set d'outils actifs

- **Mécanisme exact** : sortir du system prompt tout ce qui est dérivé du set d'outils (snippets, guidelines « if tool X then … ») ; les déplacer dans les **descriptions de tools** (cacheables côté Anthropic) ou dans le **premier message user** ; garder un system 100 % fixe par version. Le set d'outils peut alors changer **sans toucher au system** (miss partiel limité aux définitions d'outils ajoutées/retirées, qui sont déjà en queue du préfixe system en explicite, ou qui ne sont matcheurs que pour le suffixe en implicite).
- **Pourquoi ça marche** : c'est la fuite structurelle n°1 mesurée (H1 : rebuild « milieu » = miss total, cr = 0 ; rebuild « fin » = miss partiel ×3.5 — et le cas réel MCP/plugins = miss total systématique, cf. issue oh-my-openagent#1247 « 0 % hit ») . Découpler transforme le miss total le plus fréquent en miss partiel court, voire nul en implicite si le texte stable du system est préservé.
- **Risque/coût** : les guidelines dépendantes des outils sont utiles au modèle → les reloger coûte des tokens par tour (premier message) ou réduit la précision des descriptions longues. Effort de refonte de l'assemblage. Risque de régression qualité si le modèle « oublie » les règles dans les descriptions.
- **Test** : reprendre le protocole T1 (rebuild fin/milieu) après refonte : mesurer `cache_read_input_tokens`/`cache_creation_input_tokens` lors d'un changement d'outils en session longue (attendu : plus jamais cr = 0 sauf si le contenu du system change).

### I-04 — Fenêtre d'historique « anchor » : garder les premiers tours bit-stables à travers les compactions

- **Mécanisme exact** : lors d'une compaction, réordonner la conversation en `[system || tours_anchor bit-identiques (1er user, 1-2 premiers tours) || résumé (bloc texte autonome) || tours récents]`. Les tours_anchor ne sont **jamais modifiés ni résumés** — on résume seulement le milieu.
- **Pourquoi ça marche** : aujourd'hui la compaction change tout le préfixe ≥ system → miss total au tour suivant (coût caché, éventuellement énorme en session longue : le préfixe complet est relu). Avec les tours_anchor en tête **bit-stables entre compactions**, le préfixe commun inter-compactions = `[system + anchor]` → le hit post-compaction couvre une part substantielle du préfixe. Le résumé reste *après* l'anchor pour que le modèle garde le contexte demandé.
- **Risque/coût** : le résumé placé après l'anchor est sémantiquement inhabituel (le modèle lit le résumé en milieu de conversation) → à valider qualitativement ; coût d'un résumé qui doit référencer l'anchor. Fonctionne mieux en explicite (breakpoint sur l'anchor) ; en implicite, la seule condition est le bit-identique.
- **Test** : mesurer `cached_tokens` du tour suivant la 1ʳᵉ et la 2ᵉ compaction, avec/sans anchor (attendu : 2ᵉ compaction avec anchor > 0 ; sans anchor ≈ 0). Croiser 2 providers.

---

## 2. Tranche B — Impact majeur (ordre de grandeur : ×1.5 à ×2 sur l'économie, fonction du profil d'usage)

### I-05 — Ordre canonique par stabilité décroissante, formalisé comme contrainte de design (pas du « bon sens »)

- **Mécanisme exact** : règle d'assemblage vérifiée par CI : `statique en tête, volatile en queue`, avec une **hiérarchie officielle** : (1) intro+généralités fixes → (2) parties dépendant de la version pi → (3) contexte projet (contextFiles, footprint) → (4) ligne volatile (cwd, état) **en dernier** → (5) conversation (l'ordre y est déjà contraint par le protocole). Interdiction formelle d'injecter timestamp/ID/météo/état dans le préfixe (consensus 2026 ; pi a déjà corrigé la date — CHANGELOG #6621 — et met le cwd en fin — H3 validé).
- **Pourquoi ça marche** : chaque élément volatile en tête transforme un miss partiel (taille de l'élément) en miss total (tout ce qui suit). L'ordre canonique minimise la **valeur attendue** du coût de chaque changement inévitable : `E[coût] = Σ P(changement_i) × tokens_après_i`.
- **Risque/coût** : faible ; uniquement disciplinaire (CI + revue). Coût de mise en place des tests d'ordre.
- **Test** : test unitaire « prefix-stability » qui déplace un composant (cwd simulé) et vérifie que le hash du préfixe ne change pas avant l'emplacement autorisé ; mesure A/B sur le scénario « changement de repo en session » (attendu : miss < 200 tokens, chiffre déjà mesuré H3 ≈ 100).

### I-06 — Ordonnancement anti-miss : grouper et *avancer* toutes les invalidations inévitables

- **Mécanisme exact** : un « scheduleur de changements de clé » dans le harness : quand plusieurs événements invalidants sont en attente (activation de skills, ajout d'outils MCP, mise à jour de contextFiles, switch de modèle), les **grouper dans un seul tour** (une seule invalidation) et les **déclencher tôt** (début de session, conversation courte) plutôt qu'en milieu de session longue. Politique : « en session longue, tout changement de clé est différé à la prochaine frontière (fin de tour / nouvelle session) » — pattern Claude Code (« les modifs de CLAUDE.md s'appliquent au prochain cycle »).
- **Pourquoi ça marche** : le coût d'un miss = préfixe entier ; donc `coût(miss à t) ∝ longueur(conversation(t))`. Un changement groupé tôt coûte peu ; le même changement tardif coûte tout l'historique. Les sessions longues deviennent « conservatrices » par construction.
- **Risque/coût** : l'utilisateur voit ses changements appliqués en différé (UX à gérer, notifications) ; risque de « forcer » un résumé précoce qui change le préfixe (à éviter : le groupement se fait par report, pas par réécriture).
- **Test** : scénario « nouvelle skill à mi-session » comparé à « skill déclarée au tour 2 » : mesurer les tokens relus cumulés (attendu : coût du cas tardif ~ préfixe complet × 1 ; cas précoce ~ rapport des longueurs).

### I-07 — Suffixe minimal par tour : troncature systématique et suppression ciblée des tool_results périmés

- **Mécanisme exact** : à chaque tour, le suffixe relu = deltas accumulés depuis le dernier breakpoint/point de divergence. Réduire ce suffixe de deux façons : (a) **tronquer dès la source** les sorties de `bash`/`read`/grep (tête/queue, méta-résumé « N lignes omises ») ; (b) **supprimer/compacter les tool_results périmés** (ex. : sorties de `bash` dont le contenu est obsolète après l'édition suivante) — ce que fait opencode, pas pi — sans attendre la compaction de masse.
- **Pourquoi ça marche** : chaque tour de boucle relit le suffixe des tool_results. Réduire leur taille de moitié = réduire le coût *structurel* de chaque tour de moitié, sur **toutes** les sessions, sans toucher au hit-rate lui-même (le rate reste haut, mais les tokens relus baissent). C'est le levier « multiplicateur » le plus robuste.
- **Risque/coût** : le modèle peut avoir besoin du contenu tronqué (retour en arrière) → garder le plein dans l'état local, tronquer seulement ce qui est envoyé ; risque de perte de qualité sur les diffs longs. La suppression de tool_results change l'historique → **ne supprimer que derrière le dernier breakpoint/point de divergence** pour ne jamais casser le préfixe.
- **Test** : campagne de boucle d'outils (protocole H2) avec sorties artificiellement longues : mesurer `cached_tokens` relus par tour avec/puis troncature (attendu : tokens relus ∝ taille du suffixe, hit-rate inchangé).

### I-08 — Compaction douce continue (anti-compaction-de-masse) : fenêtre glissante par la tête, jamais par réécriture

- **Mécanisme exact** : au lieu de laisser la conversation croître jusqu'au seuil puis tout résumer (miss total), maintenir en permanence `[system || résumé-stable || tours 1..K]` avec une **fenêtre de taille fixe** : quand le tour K+1 arrive, les tours « délogés » sont ajoutés au résumé **en queue** du résumé-stable… et surtout : le résumé-stable et le début de la fenêtre restent bit-identiques. Nuance cruciale : la suppression de tours *au milieu* change leur contenu et ce qui suit — donc la fenêtre doit être évincée **par la fin de la zone résumée** (les tours les plus anciens de la zone vivante deviennent la fin du bloc résumé, la partie récente « glisse » ; le texte du préfixe reste intact tant que l'éviction ne touche que la zone déjà derrière la frontière).
- (Version pragmatique) : à défaut, **réduire la fréquence** des compactions (agrandir la fenêtre/réserve) et **élever le budget** de tours récents conservés (`keepRecentTokens`), pour que le miss de compaction soit rare et que le suffixe post-compaction soit utile.
- **Pourquoi ça marche** : le miss de compaction est proportionnel au préfixe entier au moment le plus long de la session — le point le plus cher possible. Le rendre rare (×2-×3 moins fréquent) et *peu profond* (résumé progressif : la zone perdue est plus courte) réduit directement l'économie cumulée. Le résumé-stable EN TÊTE continue de matcher (breakpoint system en explicite ; préfixe court commun en implicite).
- **Risque/coût** : fenêtre trop grande → débordement de contexte (délégation au modèle) ; résumé progressif plus fréquent = écritures de résumé (mais petites) ; complexité d'implémentation moyenne. À valider la non-régression qualité.
- **Test** : session longue artificielle (200 tours) : comparer `waste` cumulé et nombre de `cached_tokens=0` entre compaction de masse (état actuel) vs fenêtre glissante. Croiser 2 providers.

### I-09 — Fork/branches « append-only » : le passé partagé n'est jamais réécrit quand on bifurque

- **Mécanisme exact** : lors d'un fork/branch/undo : (a) ne **jamais muter** les messages antérieurs au point de divergence — tout ce qui est propre à la branche est ajouté **en queue** ; (b) hériter l'historique compacté de la session parente (pattern branch-summary existant chez pi) avec **sessionId dérivé stable** du parent (clé de routage proche) ; (c) interdire le « rewind/undo » mutateur au-delà du dernier tour (ou le signaler comme miss volontaire).
- **Pourquoi ça marche** : bifurquer à tour 50 avec réécriture du passé détruit le préfixe complet (miss = 50 tours). En append-only, le préfixe (`[system … tour 50]`) est bit-identique au moment du fork → le premier appel de la branche matche tout le préfixe partagé, seuls les deltas de la branche sont relus. Le coût d'un fork passe de « conversation entière » à « delta de branche ».
- **Risque/coût** : l'historique partagé gonfle la conversation de branche (mémoire) ; sémantique « l'historique dit une chose, la branche en fait une autre » à gérer (résumé). L'undo simple devient coûteux (miss) — arbitrage UX.
- **Test** : fork à mi-session sur une longue session : `cached_tokens` du premier appel de la branche (attendu : proche du préfixe partagé, pas 0).

### I-10 — Warmup au démarrage + keepalive pendant l'inactivité (gestion active du TTL)

- **Mécanisme exact** : (a) **warmup write** : au lancement d'une session (avant le premier vrai appel, pendant que l'utilisateur tape), envoyer une requête de préchauffage — system + outils + couche projet uniquement, `max_tokens ≈ 1` — qui écrit le KV-cache du préfixe ; (b) **keepalive** : timer qui, pendant l'inactivité utilisateur (attente de saisie ou commande outil longue), renvoie un ping minimal réutilisant le préfixe le plus long, calé sur `TTL/2` (pattern aider `warm_cache`, papier arXiv:2607.19214 : rentable si `P(reprise dans la fenêtre) × bénéfice > coût des pings`).
- **Pourquoi ça marche** : le cache ne sert que s'il *existe* au moment du premier appel (population asynchrone chez OpenAI : il faut compter une latence de secondes/minutes) et s'il *survit* aux pauses. Deux causes structurantes de miss : `idle > TTL` (cause n°1 mesurée chez pi : `CacheMiss{idleMs}`) et premier appel à froid. Le warmup rend le 1er appel hit ; le keepalive rend la reprise hit. Coût d'un ping = ~0.1× le préfixe ; un seul hit sauvé le rembourse.
- **Risque/coût** : coût des pings si reprise improbable (le modèle économique doit être appliqué par session : ne pinger que les sessions « vives » — du texte tapé récemment, un process en cours) ; distraction du backend si les pings sont trop fréquents ; certains providers ne prolongent pas le TTL sur simple lecture (à mesurer provider par provider).
- **Test** : (a) premier appel d'une session avec/sans warmup → `cached_tokens` ; (b) pause de 6 min (TTL 5 min) avec/sans ping à 2:30 → `cached_tokens` au retour. Sur 2 providers, N ≥ 3.

---

## 3. Tranche C — Impact moyen (ordre de grandeur : ×1.1 à ×1.5, situationnel)

### I-11 — Clé de cache et route verrouillées au niveau projet (au-delà de la session)

- **Mécanisme exact** : en plus de la clé par session, offrir un mode « clé par projet » : `prompt_cache_key = H(provider ∥ modèle ∥ repo_id)` (stable tant que le repo ne change pas de nom/chemin canonique), et non par session. Toutes les sessions du projet partagent la même topologie de route (même instance serveur probable).
- **Pourquoi ça marche** : le routage par clé identique augmente la probabilité que deux sessions *consécutives* du même projet arrivent sur l'instance qui détient encore le system prompt écrit par la session précédente (cas Azure mesuré : 60 % → 87 % ; H6 : le hit survit au resume quand sessionId est stable). Les sessions courtes et répétées (le pattern quotidien du développeur : 10 sessions/jour, 2-5 tours chacune) deviennent des « reprises déguisées » de la même topologie.
- **Risque/coût** : deux sessions *simultanées* lourdes sur le même projet partagent le LRU d'instance → évictions mutuelles possibles (voir I-25) ; la clé projet perd l'isolement entre conversations (fuite d'état potentielle si le provider corrèle par clé — à documenter). Coté OpenAI : clé = « entrée de hash », pas une garantie.
- **Test** : 10 sessions courtes séquentielles sur le même repo, avec/sans clé projet : comparer la distribution de `cached_tokens` sur le **premier** appel (attendu : médiane plus haute avec clé projet) ; surveiller ensuite le cas sessions parallèles.

### I-12 — Rétention longue activée par défaut + politique par session (pas seulement globale)

- **Mécanisme exact** : généraliser `PI_CACHE_RETENTION=long` (1 h / 24 h) par défaut quand `supportsLongCacheRetention`, et exposer une politique **par session** (`cacheRetention` en option de run, à la opencode CachePolicy) : `off | short | long | adaptive` (adaptive = long si la session a déjà montré des hits, short sinon).
- **Pourquoi ça marche** : le TTL long est un « keepalive gratuit » (le provider prolonge sans ping) — il élargit la fenêtre de réutilisation de 5 min à 1-24 h, ce qui supprime la cause n°1 des misses mesurés (`idleMs`). Le mode `off` évite l'overcaching tax sur les contenus uniques (voir I-14).
- **Risque/coût** : TTL long → le cache vit plus longtemps côté provider (résidu de données, side-channel timing ; data residency) — à documenter pour les environnements sensibles ; coût de stockage si le provider facture la rétention longue (à vérifier contractuellement).
- **Test** : A/B `short` vs `long` sur des sessions avec pauses naturelles de 5-20 min : différence de `cached_tokens` au tour de reprise.

### I-13 — Fusion des messages utilisateur courts avant le premier appel

- **Mécanisme exact** : si l'utilisateur tape plusieurs messages brefs avant le premier appel (pattern « hmm… en fait… attends »), les **fusionner en un seul message user** avant l'envoi ; ne jamais intercaler une réponse intermédiaire.
- **Pourquoi ça marche** : chaque message user supplémentaire après le premier appelle une réévaluation ; fusionner évite un tour inutile et surtout évite qu'une partie de la conversation soit « figée » sous une forme sous-optimale. Effet cache : direct (un tour de moins = un relu de moins) et indirect (le premier message devient un bloc d'ancrage propre, cf. I-04).
- **Risque/coût** : la fusion retarde la première réponse (latence perçue) ; normer séparément les « commandes » (trailing slash) des « remarques » (fusionnables). Risque faible.
- **Test** : comparer 2 sessions, même contenu, « 3 messages » vs « 1 message fusionné » : tokens totaux relus (attendu : économie d'un tour complet du préfixe de la conversation naissante).

### I-14 — Politique de breakpoints et de writes sélective par (provider, modèle) — l'anti-overcaching

- **Mécanisme exact** : généraliser la sémantique déclarée de goose / compat pi : table `(provider, modèle) → {marquer system ? marquer tools ? marquer dernier message ? exclure les tool_results ?}`. En explicite, **ne poser des breakpoints que sur les blocs réellement relus** (ex. : modèles où le full-context régresse le TTFT — papier « Overcaching Tax » : GPT-4o −8.8 % TTFT en full-context ; GPT-5.2 → exclure les tool_results ; Sonnet → system-only). En implicite : teste si désactiver la clé dans les sessions à usage unique réduit le bruit.
- **Pourquoi ça marche** : chaque write a un coût (1.25× chez Anthropic). Écrire des caches pour des contenus jamais relus = overhead net + risque de régression de latence. Une table par (provider, modèle) remplace la politique binaire actuelle par une politique *rentable par construction*.
- **Risque/coût** : courbe d'apprentissage des valeurs de la table (nécessite des mesures par modèle) ; risque de poser trop peu de breakpoints si la table est fausse (hit-rate bas). La table doit être un fichier de données vérifié par les métriques (boucle I-22).
- **Test** : pour un modèle donné, 3 variantes (system-only / +tools / +dernier message) en boucle d'outils : comparer `waste` en $ (pas seulement le hit-rate — un hit-rate haut avec trop de writes peut coûter plus).

### I-15 — Pre-warming planifié (cron / hooks de projet) pour les providers à TTL court

- **Mécanisme exact** : un hook externe (cron, alias de shell, extension de lancement de session) qui, avant les heures d'usage probables (démarrage du poste le matin, retour de pause déjeuner), envoie un warmup du préfixe des projets actifs (system + footprint, `max_tokens≈1`). Équivalent « chauffage à froid » du keepalive, pour les fenêtres > TTL impossible à couvrir par ping (la nuit).
- **Pourquoi ça marche** : le premier appel du matin sur un provider à TTL 5 min est un miss certain (12 h d'écart) ; un warmup à T-30 min le transforme en hit. Le coût est minuscule (un write du system ~2k tokens) et le bénéfice est le préfixe entier du premier tour réel (system + premier message, typiquement 2-4k tokens). S'applique aussi aux « reprises de projet » après week-end.
- **Risque/coût** : nécessite un composant hors harness (cron/shell) et une liste de projets « chauds » (à dériver des sessions récentes) ; consomme quelques appels API/jour ; peut heurter les quotas de ping de certains providers (à vérifier).
- **Test** : 2 jours de mesure : `cached_tokens` du premier appel du matin avec/sans warmup à T-30 min (attendu : > 1024 avec, ≈ 0 sans, sur TTL court).

---

## 4. Tranche D — Impact marginal ou très situationnel (ordre de grandeur : ×1.05 ou cas rares mais réels)

- **I-16 — Padding utile sous les seuils** : si le préfixe est sous le seuil (sessions à system court, ex. agents sans gros system ; Gemini 4096), ajouter du contenu **utile et stable** (documentation des conventions du repo, glossaire du domaine, index d'API) en tête pour dépasser le seuil — jamais du remplissage pur (overcaching tax). Sous-texte : sous le seuil il n'y a pas de cache du tout **et** une régression TTFT 10-18 % (ablation du papier). Test : sessions à system court, `cached_tokens` à 0 → ajouter le bloc, mesurer au tour 2.
- **I-17 — « Cold resume » → session neuve avec mémoire de session** : si une session est reprise après une inactivité > TTL, le préfixe (avec tout l'historique) est de toute façon expiré : le **resume coûte un miss de tout l'historique** ; démarrer une session *neuve* avec un **résumé de session** (memory persistée par repo) coûte un miss du system seul… et le résumé est réutilisable (bit-stable) entre les sessions suivantes. Recommandation UX contre-intuitive à tester : après longue inactivité, proposer « reprendre (miss total) vs nouvelle session avec résumé (hit system + mémoire) ». Test : mesurer waste du premier tour dans les deux voies sur une session de 100 tours revenue après 30 min.
- **I-18 — Résumé de session croisé inter-sessions (mémoire + cache)** : produire en fin de session un `session_summary` bit-stable, injecté en tête des sessions suivantes du même repo (juste après le system, avant le premier message). Double bénéfice : contexte continu (mémoire d'agent) + **préfixe commun inter-sessions allongé** (I-01/I-02 sur l'axe conversation). Risque : contenu volatil dans le résumé (timestamps) → le figer par convention ; dérive de la fenêtre si le résumé change trop. Test : 5 sessions successives sur le même repo, distribution des `cached_tokens` du 1er appel ; + évaluation qualitative du contexte.
- **I-19 — Re-soumission après miss inattendu (2ᵉ chance)** : en cache implicite, la population est asynchrone → un miss bit-identique « frais » peut devenir hit 1-3 s plus tard. Sur les providers OpenAI-compatibles, si un appel échoue (erreur réseau, timeout) ou si `cached_tokens=0` est observé sur un préfixe supposé chaud, **re-soumettre le même payload** (retry existant chez pi — s'assurer qu'il ré-envoie le payload *identique*, pas régénéré). Test : après un 1er appel à `cached_tokens=0` sur un préfixe chaud, re-soumettre sans modification : taux de 2ᵉ hits.
- **I-20 — Geler le contenu de la documentation épinglée dans le system** : le bloc « Pi documentation » (README/docs de pi) change à chaque release → miss systématique au 1er lancement post-upgrade. Options : (a) épingler un « docs hash » de version dans le system (diagnostic) ; (b) **déplacer la doc pi vers un outil** (`help`/`man` appelable) au lieu de l'inclure → le system devient stable même entre versions pi. Coût : tokens par appel de doc ; bénéfice : le system visible ne change qu'avec les vraies règles, jamais avec la doc. Test : session après upgrade pi avec/sans bloc doc dans le system → `cached_tokens` du 1er appel.
- **I-21 — Normalisation des headers/User-Agent par session** : geler user-agent, `x-client-request-id` (stable par session, pas aléatoire), version du client SDK dans les headers — le routage du provider peut dépendre de ces champs (littérature F7 interne : les configs de routing hash assez largement). Coût nul, test trivial (capturer les headers sur 2 appels et vérifier l'égalité des champs routés).
- **I-22 — Boucle de mesure → décision automatique (SLO cache)** : faire du hit-rate un **SLO** par (provider, modèle) : `cached_tokens/prompt_tokens` agrégé, seuil d'alerte, et surtout **auto-toggle** : si un (provider, modèle) montre un hit-rate durablement < seuil (ex. < 40 % en boucle) malgré un préfixe stable, basculer sa stratégie (off / short / pas de breakpoints) — l'OpenAI 2025-2026 « borked » est un cas réel où *désactiver* le cache (et son overhead d'écriture) est la bonne décision. Test : tableau de bord `waste` en $ par (provider, modèle) sur 2 semaines, puis réglage des seuils.
- **I-23 — Lint « préfixe-stable » pour extensions et hooks** : les extensions (`before_request`, `onPayload`, `systemPromptOverride`, skills dynamiques) sont une surface d'invalidation non surveillée (F4). Ajouter un lint/hook de garde qui **hache le préfixe** avant/après transformation de chaque payload et émet un warning si le hash change hors points autorisés (cwd, dernier message). Coût : hash par requête (négligeable). Test : suite d'extensions connues pour injecter du volatil → le lint doit les signaler.

---

## 5. Tranche E — Hors-sentier battu / spéculatif (potentiel réel mais incertain, à valider)

- **I-24 — « Prompt shaper » local (proxy de normalisation)** : un proxy (le pi-messages/Ray existant peut le faire) qui **normalise les requêtes** avant envoi : tri des clés JSON, ordre stable des tableaux, échappement canonique, suppression des champs inutiles (`store`, options parasites), padding des champs routés. Il garantit le bit-déterminisme même si l'émetteur est bavard (extensions qui ajoutent des champs dans un ordre variable). C'est le « cache shaper » : la stabilité devient une propriété *du canal*, pas de chaque client. Test : 2 clients différents pointant le même proxy + même modèle : taux de hits croisés entre clients.
- **I-25 — Orchestration de l'éviction : ne pas laisser deux sessions lourdes partager une clé LRU** : en mode « clé projet » (I-11) ou multi-agents, deux conversations longues simultanées sur la même topologie peuvent s'évincer mutuellement du LRU d'instance. Option : « sessions parallèles lourdes ⇒ clés de route distinctes ; sessions séquentielles courtes ⇒ clé partagée ». Une heuristique par (nombre de sessions actives, longueur moyenne) à mesurer : taux de hits croisés avant/après.
- **I-26 — Compact « delta » append-only** : remplacer le résumé unique par une **suite de résumés incrémentaux** en blocs marqués (chacun avec breakpoint en explicite), où chaque compaction **n'ajoute que le delta** en queue du bloc et ne réécrit jamais les blocs précédents → le préfixe des blocs résumés reste bit-identique à travers les compactions (seule la zone `[delta_k … tours récents]` est relue). Limite : le bloc résumé croît (mémoire), et en implicite le « delta » est nouveau texte (la part conservée = blocs précédents, ce qui dépasse nettement I-04). Test ciblé : 3 compactions successives, évolution de `cached_tokens` post-compaction (attendu : décroît d'une compaction à l'autre, au lieu de retomber à 0).
- **I-27 — « Decision engine » : estimer le coût d'un miss pour arbitrer les changements** : avant tout événement invalidant (switch de modèle, nouvelle skill, /compact manuel), calculer `coût_miss_estimé = préfixe_tokens × prix_input` et l'afficher/arbitrer (« ce changement coûte X¢ relus — continuer ? »). C'est la monétisation des misses (déjà ébauchée par `computeCacheWaste`) passée en **prédiction ex ante** plutôt que constat ex post. Test : UX A/B sur l'usage réel (mesurer si l'arbitrage réduit le waste total).
- **I-28 — Multimodal et pensée « COT » : séparer les blocs instables en blocs à part** : sur les modèles avec thinking/reasoning, **ne jamais** consolider les blocs de pensée dans les messages textuels (leur longueur varie d'un run à l'autre) — les garder dans des blocs `thinking` dédiés et exclus de la zone marquée (goose `has_cacheable_content` refuse déjà les thinking blocks). Test : sessions avec thinking activé, `cached_tokens` avec/sans consolidation.
- **I-29 — « Cache-aware token budget » : dimensionner la fenêtre par coût, pas par tokens** : le pare-feu de compaction devrait tenir compte du coût du *miss attendu* : augmenter la réserve (donc la longueur de session avant compaction) quand le préfixe est cher (gros system + footprint), la réduire quand il est bon marché. Effet : le miss de compaction survient au moment le *moins* coûteux en relu (début de session) — combinable avec I-06. Test : coût total (waste + input) sur 50 sessions sous deux politiques de réserve.
- **I-30 — « Git-aware caching » : invalidation *documentée* du footprint** : étendre I-02 avec un tracker de branche : le bloc footprint est régénéré uniquement sur `HEAD` (pas à chaque changement de fichier), et une convention « le footprint d'un commit est stable même si des fichiers changent dans l'arbre de travail » (épingler au dernier commit). Le développeur qui travaille sur une branche stable garde un préfixe identique pendant des heures. Test : session de 2 h sur branche stable : nombre de changements de bloc observés (attendu : 0), et sur branche active : misses limités au bloc.

---

## 6. Table récapitulative classée (impact × coût × risque)

Numéros = idées ci-dessus. « **Impact estimé** » = ordre de grandeur qualitatif de l'économie relative de tokens relus (ou de misses évités) sur un profil d'usage type (interactif, sessions 5-50 tours, plusieurs sessions/jour, boucles d'outils fréquentes).

| Rang | Idée | Levier | Impact estimé | Coût d'implémentation | Risque | Statut |
|---|---|---|---|---|---|---|
| 1 | I-01 Construction canonique du system (inter-sessions) | L7/L2 | **×2-×5** (transforme chaque démarrage de session) | Élevé | Moyen (régression si non-déterministe persistante) | [à tester] |
| 2 | I-02 Couche footprint du repo | L1 | **×2-×3** sur le 1er tour + seuils dépassés | Moyen | Moyen (vétusté sur branche active) | [à tester] |
| 3 | I-03 Découplage system ↔ outils | L2 | **Évite le miss total le + fréquent** (MCP/plugins) | Élevé | Moyen (qualité des guidelines relogées) | [établi] (H1) |
| 4 | I-04 Anchor bit-stable à travers compactions | L2/L8 | **×1.5-×2** (miss de compaction réduits) | Moyen | Moyen (sémantique du résumé déplacé) | [à tester] |
| 5 | I-05 Ordre canonique formel + CI | L2 | ×1.5 (discipline) | Faible | Faible | [établi] |
| 6 | I-06 Ordonnancement anti-miss (tôt + groupé) | L8 | ×1.5-×2 (sessions longues) | Moyen | Faible (UX différé) | [à tester] |
| 7 | I-07 Suffixe minimal (troncature + purge périmés) | L3 | ×1.3-×1.8 (tous profils, structurel) | Moyen | Faible (qualité si troncature agressive) | [à tester] |
| 8 | I-08 Compaction douce continue | L3/L8 | ×1.2-×1.5 | Élevé | Moyen | [à tester] |
| 9 | I-09 Fork append-only | L2/L6 | ×1.3-×2 (profil branching) | Moyen | Moyen (mémoire, undo) | [à tester] |
| 10 | I-10 Warmup + keepalive | L5 | ×1.2-×1.5 (pauses et 1er tour) | Faible→Moyen | Faible (coût des pings) | [établi] (H5 non testé) |
| 11 | I-11 Clé par projet | L6/L7 | ×1.1-×1.4 (sessions courtes répétées) | Faible | Moyen (parallélisme, éviction) | [spéculatif] |
| 12 | I-12 TTL long par défaut + politique par session | L5 | ×1.1-×1.3 | Faible | Faible (rétention données) | [établi] |
| 13 | I-13 Fusion des messages courts | L2 | ×1.05-×1.15 | Faible | Faible | [à tester] |
| 14 | I-14 Breakpoints/writes sélectifs par modèle | L8 | ×1.05-×1.2 (ou évite régression TTFT) | Moyen | Moyen (table à calibrer) | [établi] (H4 inapplicable ; esprit validé) |
| 15 | I-15 Pre-warming cron | L5 | ×1.05-×1.2 (matin/reprises) | Faible (hors harness) | Faible (quota) | [spéculatif] |
| 16 | I-16 Padding utile sous seuils | L1 | ×1.1 (agents à system court / Gemini) | Faible | Faible | [à tester] |
| 17 | I-17 Cold resume → session neuve + mémoire | L5/L7 | ×1.1-×1.3 (sessions reprises) | Moyen | Moyen (perte de contexte perçue) | [spéculatif] |
| 18 | I-18 Résumé de session croisé | L7/L1 | ×1.1-×1.4 (multi-sessions) + mémoire | Moyen | Moyen (volatilité du résumé) | [spéculatif] |
| 19 | I-19 Re-soumission après miss (2ᵉ chance) | L5 | ×1.05 (OpenAI asynchrone) | Faible | Faible (coût d'appel si miss persiste) | [spéculatif] |
| 20 | I-20 Doc pi hors system (outil help) | L2 | ×1.05 (après upgrades) | Faible | Faible | [à tester] |
| 21 | I-21 Headers/session stables | L6 | ×1.05 | Nul | Nul | [établi] |
| 22 | I-22 SLO + auto-toggle par (provider, modèle) | L9 | ×1.05-×1.2 (évite les providers défaillants) | Moyen | Faible | [établi] (gouvernance) |
| 23 | I-23 Lint préfixe-stable (extensions) | L9/L2 | ×1.05 (prévention de régression) | Moyen | Faible | [à tester] |
| 24 | I-24 Proxy normalisateur (prompt shaper) | L2 | ×1.05-×1.3 (multi-clients) | Élevé | Faible | [spéculatif] |
| 25 | I-25 Ordonnancement d'éviction multi-sessions | L6 | ×1.05 (multi-agents) | Moyen | Faible | [spéculatif] |
| 26 | I-26 Compact delta append-only | L8/L1 | ×1.2-×1.5 (très longues sessions) | Élevé | Élevé (mémoire, modèle) | [spéculatif] |
| 27 | I-27 Decision engine (coût de miss ex ante) | L9 | ×1.05-×1.15 | Moyen | Faible | [spéculatif] |
| 28 | I-28 Thinking blocks isolés non consolidés | L2 | ×1.05 (modèles thinking) | Faible | Faible | [à tester] |
| 29 | I-29 Fenêtre dimensionnée par coût | L8 | ×1.05 | Moyen | Faible | [spéculatif] |
| 30 | I-30 Footprint épinglé à HEAD | L1/L2 | ×1.1 (sessions longues stables) | Moyen | Faible | [spéculatif] |

---

## 7. Règles transverses (ce que TOUT harness devrait garantir, dérivées du brainstorming)

1. **Déterminisme total de la construction du préfixe** : le system + couches stables doivent être une fonction pure, testée par CI (hash à froid 2×, ordre canonique). C'est le prérequis de la réutilisation inter-sessions (I-01) et le filet de sécurité de toutes les autres.
2. **Un seul « point de divergence » par tour** : tout nouveau contenu va en queue ; rien n'est jamais muté dans l'historique (I-09, I-23) sauf en frontière connue (compaction, qui suit I-04/I-08/I-26).
3. **Le volatile vit en fin de préfixe ou dans des tool_results, jamais en tête** (I-05, I-07).
4. **Tout changement de clé est un événement gouverné** : mesuré (coût en $, I-22/I-27), groupé et avancé (I-06), jamais accidentel (I-23).
5. **Le cache se gère aussi entre sessions** : warmup (I-10/I-15), clé projet (I-11), mémoire de session (I-18) — l'unité d'optimisation n'est pas la session, c'est (repo × modèle × fenêtre temporelle).
6. **Le hit-rate n'est pas la seule métrique** : les tokens relus par tour (suffixe, I-07) et le coût des writes (I-14) comptent autant. Métrique ultime : **`waste` en $ par session** (pi : `computeCacheWaste`) et **TTFT** (éviter les régressions de latence du sur-caching).

## 8. Idées écartées ou déclassées (et pourquoi)

| Idée | Verdict | Raison |
|---|---|---|
| Garder le cwd hors du system prompt | Déclassée (H3, réfutée — bruit inter-sessions) | le cwd est déjà en fin de system ; le déplacer ne change rien de mesurable |
| Breakpoints « par rôle » (dernier user par rôle) | Déclassée au profit de l'ancrage par position | piège quand le dernier message est un tool_result user (goose `prefix_invariance.rs`) |
| Cache entier partagé entre sessions de *conversations* différentes via prompt_cache_key commune | Partiellement déclassée (I-11 la restreint au préfixe system + routage) | le texte des conversations diffère dès le 1er message ; le partage ne profite qu'au system, et ouvre l'éviction mutuelle |
| Pinger pendant l'exécution de commandes courtes | Déclassée (overhead > bénéfice) | boucle d'outils déjà à 91.9 % de hit (H2) ; le ping ne s'applique qu'aux pauses > TTL/2 |
| Modifier les tool_results pour « stabiliser » le texte (normalisation ANSI, timestamps) | Déclassée | les tool_results sont dans le suffixe relu de toute façon ; seule la troncature (I-07) paie |
| Vorace : tout cacher partout | Déclassée (overcaching tax) | écritures inutiles = overhead net et régression TTFT possible |

---

## 9. Synthèse exécutive (en 5 lignes)

- Le levier **dominant et sous-exploité** est la **réutilisation inter-sessions** : rendre la construction du préfixe **canonique et déterministe** (I-01) puis l'**épaissir** avec une empreinte de repo stable (I-02) — le premier appel de chaque session devient un hit, pas un miss.
- Le levier **structurel** reste le **découplage system ↔ outils** (I-03) : c'est le seul moyen d'éliminer le miss total le plus fréquent (MCP/plugins/skills dynamiques).
- Le levier **temporel** (warmup au démarrage, keepalive pendant l'inactivité, TTL long, pre-warming cron — I-10/I-12/I-15) adresse la cause n°1 mesurée des misses : l'expiration par inactivité.
- Le levier **multiplicatif** (suffixe minimal, compaction douce — I-07/I-08) réduit les tokens relus sur tous les profils sans toucher au hit-rate.
- Tout le reste (I-04 à I-30) est de l'arbitrage fin, de la discipline (CI/lint), ou du spéculatif à valider par les métriques `waste`/TTFT — sachant que le cache OpenAI reste probabiliste (mesurer, pas présumer).

---
```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Livrable complet écrit au chemin imposé (phase3-blind/01-blind-harness.md), en français, au format demandé : ~30 idées (I-01 à I-30 et 6 idées écartées), chacune avec (1) mécanisme exact, (2) justification hit-rate, (3) risque/coût, (4) protocole de test, classées par impact potentiel en 5 tranches (Tranche A ×2-×5 à Tranche E spéculatif) + table récapitulative classée + règles transverses + synthèse exécutive."
    }
  ],
  "changedFiles": [
    "/home/anhydrite/.pi/agent/sessions/--home-anhydrite-Documents-beta_labo-recherche-cache-hits--/subagent-artifacts/outputs/8a1b068a-5786-4f40-9dbd-95cb65b3457d/.research/phase3-blind/01-blind-harness.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "ls/find sur .research/ et lectures des rapports phase1-2 (00-web, 01-harnesses, 02-cache-infra, 03-literature, 01-mecanisme, 02-gouvernance-pi, README)",
      "result": "passed",
      "summary": "Contexte de recherche lu intégralement (mécanisme, gouvernance pi, mesures H1-H6, littérature) avant rédaction du brainstorming"
    }
  ],
  "validationOutput": [
    "Fichier créé au chemin de sortie exact ; format markdown structuré ; 30 idées avec les 4 rubriques exigées ; classement par ordre de grandeur d'impact explicite (Tranches A-E + rang dans la table)"
  ],
  "residualRisks": [
    "Le brainstorming est aveugle par conception (phase3-blind) : aucun chiffre n'a été mesuré pour les idées classées [à tester]/[spéculatif] ; les impacts estimés sont des ordres de grandeur qualitatifs à valider par les protocoles décrits",
    "Certaines idées (I-11 clé projet, I-17 cold resume, I-26 compact delta) dépendent fortement du comportement interne des providers (LRU, asynchronisme de population, TTL sur lecture) qui n'est pas entièrement observable depuis le client",
    "Le hindsight du contexte lu (mesures H1-H6 déjà réalisées) a pu orienter le classement ; les idées marquées [établi] s'appuient sur la doc de recherche, pas sur de nouvelles mesures"
  ],
  "noStagedFiles": true,
  "diffSummary": "Rédaction du livrable de brainstorming général (01-blind-harness.md) dans le dossier phase3-blind : carte des 9 leviers, 30 idées classées par impact potentiel avec mécanisme/justification/risque/test, 6 idées écartées, table récapitulative, règles transverses et synthèse",
  "reviewFindings": [
    "no blockers: document autonome et conforme au format demandé (structure, français, chemin de sortie imposé)"
  ],
  "manualNotes": "Le fichier a été écrit directement au chemin de sortie imposé (dossier .research/phase3-blind). Les idées s'articulent autour de la découverte que l'unité d'optimisation naturelle dépasse la session (réutilisation inter-sessions via construction canonique + footprint de repo + mémoire de session), ce qui constitue le champ le moins exploré par les phases 1-2."
}
```