# Phase 5 — 02 : Hypothèses théoriques (nouvelles, au-delà de l'existant)

> **Rôle** : théoricien du cache.
> **Mandat** : proposer des hypothèses théoriques NOUVELLES sur le fonctionnement du cache d'un harness — testables, même si elles ne correspondent à aucune optimisation immédiate.
> **Accès** : phase1-recherche (00-web, 01-harnesses, 02-cache-infra, 03-literature), phase2-analyse (01-mecanisme, 02-gouvernance-pi), phase3-blind (01-blind-harness I-01…I-30, 02-blind-infra a1…e5), phase4-synthese (01-actions P0…P2/T-P1…T-P8, 02-architecture), docs/05-protocoles-experimentaux-et-predictions.md (verdicts mesurés H1-H6, protocole anti-biais Partie 6).
> **Date** : septembre 2026.
> **Cadre expérimental** : chaque hypothèse est rédigée dans le cadre commun de docs/05 (métriques `cache_read_tok`/`hit_rate`/`cost_turn`/`prefix_diff`, warmup obligatoire car « le 1er tour d'une session est toujours un miss », N ≥ 5, médiane + IQR, repos égalisés, sessions séparées par condition, randomisation A/B, bac à sable `.pi-test`). Providers accessibles : opencode-go et commandcode (deepseek-v4-flash, gpt-5.6-sol) en cache implicite ; Claude (explicite) bloqué par le plan (MODEL_NOT_IN_PLAN) — les designs ci-dessous s'adaptent aux 2 sémantiques et mentionnent quand un design exige l'explicite.

---

## 0. Positionnement : ce qui existe vs ce qui est nouveau

L'existant a déjà établi (mesures docs/05, ne pas re-discuter) :
- **H1 nuancée** : rebuild « fin » des outils = miss partiel ; rebuild « set » (même nombre) = miss **total** (cr=0).
- **H2 déjà optimale** : 91,9 % de hit en boucle d'outils, ancre « dernier user ».
- **H3 réfutée** : cwd en fin de system = quasi optimal (miss ~100-200 tokens), Δ = bruit inter-sessions.
- **H4 inapplicable** : cache implicite chez nos providers (le client ne contrôle pas la frontière).
- **H5 non testé** (keepalive), **H6 validée** (resume bit-identique = hit conservé).
- **Fait établi non mesuré** : le cache OpenAI est **non-déterministe même bit-identique** (reports 2025-2026 : hits 1/20 sur GPT-5, `prompt_cache_key` = « entrée de hash » pas une garantie, population asynchrone « secondes à minutes », `cached_tokens=0` intermittents).

**Ce mandat produit des hypothèses qui dépassent le corpus sur 3 axes** :
1. **Quantifier le probable** (le corpus dit « mesurer, pas présumer » sans modèle probabiliste du hit) → TH-O1…O4, TH-W1…W3.
2. **Cartographier des courbes et des points de bascule** (saturation du préfixe, échauffement, éviction LRU, compaction minimale) que les protocoles existants n'ont jamais tracées → TH-P1…P3, TH-E1…E3, TH-C1…C3.
3. **Ajouter la dimension qualité** (le corpus mentionne la non-régression qualité comme garde-fou mais ne l'a jamais testée comme variable d'intérêt) → TH-M1…M3, TH-Q1…Q3.

Conventions de nommage : `TH-<domaine><n>`. Chaque hypothèse : **formulation testable** (IV/DV), **design d'expérience court**, **prédiction qualitative**, **intérêt** (pourquoi la tester même sans optimisation immédiate).

---

## TH-O — Le non-déterminisme OpenAI : peut-on prédire P(hit) ?

### État des lieux (du corpus)
`cached_tokens=0` est observé sur des préfixes pourtant bit-identiques, `prompt_cache_key` améliore le hit (Azure : 60 % → 87 %) sans le garantir, la population est asynchrone (délai de secondes à minutes), et les hits « GPT-5 borked » (1/20) coïncident avec des fenêtres de rollout. Aucun modèle probabiliste n'a été formulé.

### TH-O1 — « P(hit | préfixe bit-identique) est une fonction du temps de population, pas une constante »
- **Formulation** : sur un préfixe bit-identique, la probabilité de hit suit une rampe temporelle : P ≈ 0 immédiatement après le premier write (population asynchrone), croît vers un plateau P_max ≤ 1 après un délai δ, puis décroît avec la fenêtre TTL. Variables instrumentales : `Δ = délai entre write et re-soumission` (0 s, 0,5 s, 2 s, 10 s, 60 s, 5 min) ; dépendante : `cached_tokens` (binaire hit/miss sur le même préfixe).
- **Design** : 1 session de warmup écrit le préfixe ; puis N ≥ 20 re-soumissions du **même payload bit-identique** à des délais contrôlés (intercaler des requêtes « poubelles » sur une autre clé pour ne pas biaiser). 2 providers (opencode-go, commandcode), 2 modèles (deepseek-v4-flash, gpt-5.6-sol).
- **Prédiction** : rampe en S ; P(0 s) ≈ 0-20 %, plateau P_max ∈ [0,7 ; 0,95] atteint à δ ≈ 1-10 s selon le fournisseur ; la forme δ/P_max est une **signature du provider**, pas du modèle.
- **Intérêt** : (a) conditionne le retry « 2ᵉ chance » (I-19 : re-soumettre après un miss bit-identique à `cached_tokens=0` — rentable seulement si δ est court et P_max haut) ; (b) conditionne le warmup (P1-D : un warmup suivi immédiatement d'un premier appel réel peut être inutile si δ > temps de démarrage) ; (c) fournit le premier **modèle prédictif** du miss « inexpliqué » (F6) — à défaut, chaque `cached_tokens=0` reste indécidable entre bug et bruit.

### TH-O2 — « Le sel du hash : les paramètres de requête ne font PAS partie de la clé, la version de rollout SI »
- **Formulation** : le hash de cache inclut la version des poids (rollout) et peut-être certains champs de requête, mais pas les paramètres de décodage (temperature, top_p, max_tokens) qui n'affectent pas le KV. Donc : (a) varier `temperature` sur préfixe identique **ne perd pas** le hit ; (b) varier un champ routé (p. ex. forcer `user`, `metadata`, `store`) **perd** le hit si le champ est hashé. IV : champ varié ; DV : `cached_tokens`.
- **Design** : A/B intra-session : préfixe chaud (cr vérifié > 0), puis re-soumissions variantes d'UN champ à la fois (temperature / top_p / store / user-agent / un header routé). N = 10 par champ. Compléter par une séries temporelle de `hit_rate` quotidienne (détection des fenêtres de rollout : stationnaire par morceaux, chutes synchrones sur les 2 providers = rollout).
- **Prédiction** : temperature/top_p : 0 perte (hits conservés à ≥ 90 %) ; champs routés : perte partielle ou totale selon provider ; le `hit_rate` agrégé montre des **chutes en escalier** (rollouts) plutôt qu'un bruit blanc.
- **Intérêt** : élimine ou confirme une classe entière de misses attribués à tort au contenu ; sépare « faute harness » (champ routé instable, I-21 : headers figés par session) de « faute provider » (rollout) ; alimente la taxonomie de miss (M2/M5 de la gouvernance cible) d'une cause « rollout » détectable.

### TH-O3 — « prompt_cache_key a un effet mesurable localisable sur la route, pas sur le hash »
- **Formulation** : les reports disent « merely an additional input to the hashing » (pas de garantie) ET azure montre +27 pts de hit avec la clé. L'hypothèse hiérarchisée : la clé agit **sur le routage** (colle les requêtes d'une session à la même instance/topologie) et seulement indirectement sur le hash ; son effet devrait donc être d'autant plus visible que la flotte d'instances est grande, et **nul sur un endpoint mono-instance**. IV : clé présente/absente × charge (heure creuse/pleine) ; DV : distribution de `cached_tokens`.
- **Design** : 2 sessions jumelles A/B (même préfixe, avec/sans `prompt_cache_key`), 10 sessions × 5 tours par condition, sur 2 créneaux horaires. Métrique : médiane et variance du hit du 2ᵉ tour (le 1ᵉʳ écrit).
- **Prédiction** : avec clé : hit médian plus haut et **variance plus basse** (la route est stable) ; sans clé : variance inter-sessions élevée (le load-balancer disperse). En heure pleine (beaucoup d'instances) l'écart s'accroît.
- **Intérêt** : tranche la question « la clé sert-elle à quelque chose ? » (F6, H6) ; justifie ou non la stabilisation de la clé par projet (I-11, risque d'éviction mutuelle) ; la **réduction de variance** est en soi une propriété de gouvernance (un cache dont on ne peut pas prédire le comportement est ingouvernable).

### TH-O4 — « Le miss bit-identique est corrélé au volume global de trafic du provider (éviction sous charge) »
- **Formulation** : une partie des `cached_tokens=0` intermittents vient de l'éviction du KV sous pression multi-tenant (capacité d'instance bornée) ; la probabilité de hit d'un préfixe diminue avec la charge globale du provider. IV : créneau horaire (creux/plein) ; DV : hit-rate sur préfixe chaud, toutes choses égales par ailleurs (même heure locale, mêmes sessions).
- **Design** : réutiliser TH-O1 en l'exécutant à 2 créneaux (ex. 08 h vs 14 h heure locale) ; N ≥ 10 par créneau, mêmes payloads. Contrôle : mesurer aussi la latence globale (TTFT d'un préfixe froid) comme proxy de charge.
- **Prédiction** : chute de P_max en heure pleine (≥ 10-20 pts) et allongement de δ ; corrélation TTFT froid ↔ hit chaud négative.
- **Intérêt** : si confirmée, une partie des misses est **explicable et prévisible par calendrier** (SLO par créneau, pas global — améliore le calibrage de l'auto-toggle I-22 sans fausser le seuil de 85 %).

---

## TH-P — La longueur du préfixe stable : existe-t-il une saturation ?

### État des lieux
Le system prompt pi mesure ~2,5-4,5k tokens (sysBytes 6781-7501), au-dessus des seuils 1024 (OpenAI/Anthropic), juste au-dessus de 4096 (Gemini). Le papier de référence dit que le system domine le coût (41-80 % d'économie). Mais **personne n'a tracé la courbe bénéfice marginal vs longueur**.

### TH-P1 — « Le gain marginal du préfixe stable s'annule au-delà d'un point de saturation ≈ (longueur de conversation réutilisée) »
- **Formulation** : pour une session de L tokens réellement rejoués par tour, un préfixe stable de taille S rapporte `S × (P_in − P_read)` par tour de hit, mais coûte `S × P_write` au write (1er tour, invalidation, TTL expiré). Le bénéfice net par session est donc ≈ `S × [n_hits × (P_in − P_read) − n_writes × P_write]`. Il existe un **point de saturation** S* où la dérivée du bénéfice net s'annule (au-delà : écrire un préfixe que la session ne relira jamais assez). IV : S (longueur du bloc stable, de 1k à 12k tokens, via padding utile stable — jamais de remplissage pur) ; DV : coût total de session à longueur de session fixée.
- **Design** : sessions de longueur contrôlée (L ≈ 3k, 10k, 30k tokens de conversation), S variant dans {1k ; 2k ; 4k ; 8k ; 12k} ; N ≥ 5 par cellule. Métrique : `cost_total_session` normalisé, et point de coude de la courbe coût(S).
- **Prédiction** : courbe en L décroissante puis plate, avec coude à S* ≈ L_rejoué (dans le rapport 1-2× selon les prix read/write) ; pour les sessions courtes (3k), un system de 12k est **nettement sous-optimal** (write payé, peu de relus) ; pour les sessions longues, le coude repousse.
- **Intérêt** : dimensionne « la bonne taille » d'un system/footprint — aujourd'hui la recherche voue un culte au « préfixe long » (I-02, C2) sans borne ; cette hypothèse borne l'optimisation et évite de payer un write géant pour une session courte (l'anti-overcaching I-14 appliqué à la **longueur** et non aux frontières).

### TH-P2 — « Le hit-rate (ratio) est borné par le ratio system/(system+conversation), pas par la stabilité »
- **Formulation** : même avec stabilité parfaite, `hit_rate_session = cacheRead/(input+cacheRead)` converge vers `S/(S + Δ_conversation)` où Δ = tokens nouveaux par tour. Donc le hit-rate agrégé **décroît naturellement** quand la conversation croît, sans aucune invalidation — c'est un plafond géométrique, pas un défaut. IV : longueur de session ; DV : hit_rate_session.
- **Design** : réutiliser les traces H2 existantes (16 appels, cr 2816→8704) + 3 sessions longues (30-50 tours) ; tracer hit_rate vs tour. Modèle prédictif : `S/(S + Σ deltas)`.
- **Prédiction** : le modèle ajuste les données à ± 5 pts ; le hit mesuré ne dépasse jamais le plafond calculé ; l'écart entre plafond et mesure est la vraie « fuite » à traquer.
- **Intérêt** : fournit une **baseline théorique de référence** pour le SLO (I-22) : un hit « bas » sur une session longue peut être parfaitement sain ; sans ce plafond, on risque d'auto-toggle un provider sain ou de fuiter une vraie régression. C'est la métrique manquante du tableau de bord (M2).

### TH-P3 — « Le seuil minimal n'est pas un seuil mais une famille : la frontière 1024/2048/4096 est un effet de batch, pas une constante »
- **Formulation** : les seuils documentés (1024 OpenAI, 4096 Gemini, possiblement 2048 Anthropic récent) sont des frontières de rentabilité du matcher (coût de lookup vs bénéfice), pas des lois physiques : la probabilité de hit devrait donc présenter une **transition douce** autour du seuil et non un marchepied, avec une zone grise. IV : taille du préfixe stable autour du seuil (900-1300, 1800-2200, 3900-4300) ; DV : P(hit) au 2ᵉ tour.
- **Design** : sessions à system artificiellement dimensionné (padding utile) dans les 3 zones, N ≥ 5 par cellule, 2 providers. Tracer la courbe P(hit) vs taille.
- **Prédiction** : transition douce (logistique) avec zone grise ± 15 % autour du seuil documenté ; la pente et le centre diffèrent entre providers (signature d'implémentation du matcher).
- **Intérêt** : guide les designs « juste au-dessus du seuil » (pi est à 2,5-4,5k, donc à la frontière Gemini) : savoir si 4,1k suffit ou s'il faut viser 4,6k change le dimensionnement du footprint (I-02/T-P4) ; et rafraîchit la donnée même de la littérature (le « montée à 2048 Anthropic » devient mesurable, pas anecdotique).

---

## TH-M — Le niveau de thinking/reasoning : partie de la clé, et coût d'un changement

### État des lieux
Le corpus affirme « modèle + effort = clé de cache » (Claude Code) et F3 (changement de modèle/thinking en session = miss total mesurable via `modelChanged`) — mais **le niveau de reasoning lui-même n'a jamais été isolé comme variable** dans les mesures pi, et le comportement des blocs thinking dans le préfixe est documenté (goose refuse de marquer les thinking blocks, `has_cacheable_content`) sans avoir été testé.

### TH-M1 — « Le niveau de reasoning est une entrée de la clé au même titre que le modèle : le changer en session = miss total du préfixe entier »
- **Formulation** : IV : passage du niveau de reasoning (off → low → high) en session, préfixe texte **strictement inchangé** ; DV : `cached_tokens` au tour suivant. Contrôle crucial : le payload ne doit contenir aucun autre changement (le niveau de reasoning est un champ de requête, pas du contenu).
- **Design** : session de 5 tours warmup avec level X (cr vérifié > 0), bascule du level → 1 tour → mesurer ; puis retour → mesurer. N ≥ 3 sessions par paire de niveaux. Sur gpt-5.6-sol (expose un reasoning_effort) et deepseek-v4-flash (si exposé).
- **Prédiction** : cr = 0 sur le tour suivant la bascule (le KV est par poids+temperature… non : par clé de génération) ; la récupération exige un write complet — coût = préfixe entier au tarif plein. Si au contraire le hit survit (cr > 0), le reasoning n'est PAS dans la clé — résultat tout aussi précieux.
- **Intérêt** : classe la décision UX « changer le niveau de thinking en cours de session » comme événement gouverné coûteux (P4), mesurable en $ ; aujourd'hui pi le constate (modelChanged) sans le prévenir ex ante (I-27). Banal, mais JAMAIS mesuré — c'est une hypothèse théorique pure qui peut renverser la doc Claude Code.

### TH-M2 — « Les blocs thinking (extended thinking) dans l'historique dégradent le taux de hit des tours suivants s'ils sont re-sérialisés ou exclus du matcher »
- **Formulation** : deux mécanismes concurrents possibles : (a) le provider exclut les thinking blocks du cache → chaque tour avec thinking réduit le préfixe matché d'autant (le hit recule) ; (b) le provider les inclut mais leur sérialisation varie entre runs (longueur de pensée non déterministe) → miss sporadiques « fantômes ». IV : thinking activé/désactivé × sérialisation stable/instable ; DV : hit-rate des tours 2-5 et variance.
- **Design** : sessions thinking ON vs OFF (même conversation générée par seed), inspecter le wire (`onPayload`) pour vérifier la sérialisation des thinking blocks tour à tour (`prefix_diff` ciblé sur les blocs thinking), comparer hit-rate. Complément offline : vérifier qu'aucun `cache_control` n'est posé sur un thinking block (pi/geese `has_cacheable_content`).
- **Prédiction** : si (a) : hit-rate inférieur de façon *constante* (décalage de préfixe) ; si (b) : hit-rate avec pics de `cached_tokens=0` corrélés aux variations de longueur des pensées ; le cas (b) est le plus dangereux car indécidable sans cette instrumentation.
- **Intérêt** : explique une classe probable de misses non-déterministes « OpenAI-like » sur les modèles thinking (gpt-5.x) sans invoquer le hasard ; décide si le harness doit pacager les thinking blocks en fin de préfixe, hors zone marquée, ou les tronquer (I-28 restait spéculatif).

### TH-M3 — « Le thinking est un multiplicateur du coût des misses : le préfixe à re-préfill inclut les pensées des tours précédents »
- **Formulation** : les thinking blocks sont persistés dans les messages assistant → ils font partie du préfixe ; un miss (invalidation, TTL, bascule M1) re-préfill donc system + conversation **+ pensées passées**. Le coût d'un miss en mode thinking ≈ coût du même miss × (1 + ratio pensées/conversation). IV : ratio pensées/conversation (penser court vs long) × événement invalidant ; DV : `cost_turn` et TTFT du tour post-invalidation.
- **Design** : 2 sessions jumelles (thinking court vs long sur les mêmes tâches), une invalidation provoquée (changement d'outils = miss total connu H1, ou TTL expiré), mesurer le coût du tour de récupération.
- **Prédiction** : le coût de récupération est proportionnel à la somme (system + conversation + pensées) et non à system seul ; ×1,5 à ×3 selon le modèle — les sessions thinking sont **structurellement plus sensibles** aux misses, ce qui augmente la valeur du gel de préfixe (H1) pour ces modèles.
- **Intérêt** : ajuste la priorité des optimisations par profil de modèle (le « MCP-heavy » est le profil H1 identifié ; le « thinking-heavy » pourrait l'être plus) ; et donne un argument chiffré pour la troncature des pensées passées après compaction.

---

## TH-W — Cold vs warm start : la courbe d'échauffement

### État des lieux
Mesuré : le 1er tour d'une session est TOUJOURS un miss (warmup indispensable). Non mesuré : **combien de tours pour atteindre le hit maximal**, et si la courbe est identique entre providers. Le warmup (P1-D) suppose implicite-ment qu'UN appel suffit à écrire le cache.

### TH-W1 — « Le plateau de hit est atteint en un nombre fini et PETIT de tours (1-3), et la forme de la courbe diffère par architecture (explicite vs implicite) »
- **Formulation** : IV : index du tour après warmup ; DV : hit-rate. Prédiction de forme : **explicite (Anthropic)** : plateau dès le tour 2 (le write du tour 1 marquait le system, le read du tour 2 le relit — marchepied) ; **implicite (OpenAI)** : rampe de 1 à 3 tours (write asynchrone + croissance de la conversation au-dessus de la granularité de matcher) ; **Gemini** : plateau seulement quand system+conversation > 4096 (retardé de plusieurs tours si system court).
- **Design** : 6 sessions × 2 providers × 3 modèles, 8 tours chacune, mesurer cr par index de tour ; superposer les courbes (normalisée par taille de system). Pas de tâche stupide : scénarios S1/S2 du protocole anti-biais.
- **Prédiction** : ANOVA des courbes : la variable explicative dominante est l'architecture (implicite/explicite), pas le modèle ; la pente de la rampe implicite ∝ 1/δ_population (voir TH-O1).
- **Intérêt** : calibre le warmup (P1-D) : si la rampe dure 3 tours, un warmup à `max_tokens≈1` suivi immédiatement du 1er tour réel ne suffit PAS (il faut aussi le δ de population) — le warmup optimal rejoue le **premier tour réel** plutôt qu'un ping isolé ; et explique pourquoi les mesures du corpus (cr 2816 dès le tour 2) ont pu masquer cet échauffement.

### TH-W2 — « Après une interruption > TTL, l'échauffement est récupéré en 1 tour, pas rejoué intégralement »
- **Formulation** : la reprise après TTL expiré coûte un miss (le cache est parti), mais la **monotone** : le 2ᵉ tour post-reprise doit retrouver le plateau immédiatement (le write du tour 1 post-reprise ré-écrit tout le préfixe → tour 2 = hit plein), contrairement à un cold start complet. IV : reprise froide vs démarrage froid ; DV : cr du 2ᵉ tour.
- **Design** : 2 conditions : (A) session interrompue 10 min (TTL court expiré) puis reprise ; (B) nouvelle session même repo (cold). Mesurer cr des tours 1-3. N ≥ 5.
- **Prédiction** : A : tour 1 = miss, tour 2 = hit complet (cr ≈ taille préfixe) ; B : tour 1 = miss, tour 2 = hit complet aussi — les deux courbes coïncident ; l'« échauffement » est donc indépendant de l'historique passé : ce n'est qu'une fonction de (write → read) + δ.
- **Intérêt** : réfute ou confirme l'intuition de I-17 (« cold resume = context perdu ») sous l'angle du cache : si les courbes coïncident, la **valeur cache** d'un resume froid est nulle (seule la valeur contexte-état reste) — ce qui change l'arbitrage UX « reprendre vs session neuve » (I-17) ; et simplifie la gouvernance (le keepalive H5 ne protège que les reprises < TTL, sinon autant re-writer au tour 1).

### TH-W3 — « La courbe d'échauffement dépend de la taille, pas du contenu : la qualité de la tâche n'affecte pas le nombre de tours au plateau »
- **Formulation** : le nombre de tours au plateau est une fonction pure des longueurs (system, conversation, seuils) et du δ de population — indépendant de la nature de la tâche. IV : tâche (lecture simple S1 vs boucle d'outils S4 vs édition S2) à longueurs égales ; DV : index du tour au plateau.
- **Design** : contrôler les longueurs (padding utilitaire) à égalité entre tâches, mesurer le plateau dans les 3 scénarios anti-biais, N ≥ 5.
- **Prédiction** : index du plateau identique à ± 1 tour entre tâches ; les écarts de courbes entre scénarios du corpus (H3 : bruit inter-sessions) s'expliquent par les longueurs, pas par les tâches.
- **Intérêt** : si confirmée, les protocoles peuvent se **passer de scénarios multiples** pour tout ce qui concerne le timing d'échauffement (économie de campagne) — une propriété de « neutralité de tâche » rare et utile pour la planification expérimentale future.

---

## TH-E — L'éviction mutuelle des clés (LRU multi-sessions)

### État des lieux
Le corpus pose le problème (I-11 : risque d'éviction mutuelle pour une clé projet partagée ; I-25 : orchestrer l'éviction) mais le déclasse spéculatif **faute de mesure**. Or c'est la question qui décide si partager la clé entre sessions est sûr, et comment se comportent les orchestrations multi-agents.

### TH-E1 — « Avec M sessions actives sur la même topologie de cache, le hit de chaque session se dégrade au-delà d'un point de basculement N* (capacité d'instance) »
- **Formulation** : le KV d'une instance est borné (éviction LRU sous charge) ; M sessions à longs préfixes en compétition → le hit de la session i au tour t dépend du coût total des autres sessions depuis leur dernier accès. La dégradation n'est pas linéaire en M mais en **somme des tailles actives** (Σ longueurs × recency). IV : M ∈ {1, 2, 3, 5} sessions parallèles, préfixes partagés (même system, conversations différentes) ; DV : hit-rate par session par tour, et le tour d'apparition du premier miss inattendu.
- **Design** : lancer M sessions en parallèle (même repo, même modèle, clés de session distinctes — c'est-à-dire la topologie déjà utilisée par un orchestrateur multi-agents), faire avancer toutes les sessions d'un tour à la fois, chronométrer ; répéter avec des longueurs de conversation croissantes (5k, 15k, 30k). N ≥ 3 répétitions par M.
- **Prédiction** : pour conversations courtes : pas de dégradation jusqu'à M = 5 ; pour 15k+ : dégradation visible dès M = 2-3 (miss « fantômes » corrélés en temps entre sessions) ; le point de basculement suit Σ tailles actives ≈ constante (capacité), pas M seul.
- **Intérêt** : (a) détermine si les sessions parallèles du même projet (pattern courant : un agent par terminal) s'évinsent déjà au quotidien — le cache serait alors une ressource à **ordonnancer**, pas un bonus gratuit ; (b) calibre I-11/I-25 : une clé projet partagée augmente la topologie commune et donc l'éviction mutuelle ; (c) explique une partie des misses « inexplicables » en usage multi-agents (le report `cached_tokens=0` sur orchestrateur multi-agent du corpus).

### TH-E2 — « L'éviction est réellement LRU : la session inactive est sacrifiée, la session active conserve ses hits intra-tour »
- **Formulation** : si le serveur évince par recency, une session en pause (idle inter-tours) perd son bloc au profit d'une session en activité continue — la boucle d'outils de la session active « vole » le cache de la session en pause. IV : pattern d'interleaving (A actif pendant que B dort, puis inversion) ; DV : hit de B au réveil vs hit de A pendant l'activité.
- **Design** : 2 sessions partageant le préfixe system ; alterner 5 épisodes « A actif, B inactif » puis « B actif, A inactif » ; mesurer cr au premier tour de chaque réveil.
- **Prédiction** : le réveil de B après un épisode long de A → miss de B (le bloc de B a été évincé) ; l'inverse se produit symétriquement ; la taille de l'épisode actif nécessaire à l'éviction est mesurable (≈ capacité/taille des blocs).
- **Intérêt** : confirme le modèle LRU (s'il est confirmé, les heuristiques de gouvernance deviennent simples : « ne pas multiplexer plus de K sessions lourdes par topologie ») et donne une **cause déterministe** aux misses d'idle qui ne sont PAS des expirations TTL (aujourd'hui `CacheMiss{idleMs}` amalgame les deux).

### TH-E3 — « Des prompt_cache_key distinctes isolent les sessions : l'éviction mutuelle est neutralisée, au prix de la réutilisation inter-sessions »
- **Formulation** : si la clé sélectionne une topologie de cache (TH-O3), alors deux sessions avec clés distinctes ne partagent PAS la même capacité et ne s'évinsent pas — mais perdent aussi la réutilisation inter-sessions (I-01 : le hit du 1er appel d'une session sur le system écrit par la précédente). C'est un **arbitrage isolement vs réutilisation**. IV : clés identiques vs distinctes (M = 3 sessions) ; DV : dégradation du hit par session et hit du 1er appel.
- **Design** : refaire TH-E1 en deux variantes (même clé, clés distinctes) ; ajouter la mesure `cached_tokens` du 1ᵉʳ appel de la session suivante (réutilisation).
- **Prédiction** : clés distinctes → pas de dégradation mutuelle mais hit du 1ᵉʳ appel ≈ 0 ; clés identiques → réutilisation possible mais dégradation à M ≥ 3 en conversation longue ; l'optimum est un **compromis paramétrable** (clé par (projet, modèle) et pas par session — I-11 — avec rotation quand la charge monte).
- **Intérêt** : fournit la table de vérité qui manque à I-25 (l'« orchestrateur d'éviction » spéculatif) ; détermine la politique de clé par défaut pour les environnements multi-agents (le compromis réutilisation/éviction est une décision produit, pas un détail technique).

---

## TH-C — La compaction minimale : le progressif préserve-t-il vraiment le hit ?

### État des lieux
Mesuré/documenté : la compaction de masse est un miss total (le préfixe change) ; pi persiste `previousSummary` et `keepRecentTokens` (le suffixe récent survit) ; la littérature diverge (« summarize/pruner casse les représentations » vs « le parent compacté garde le préfixe » — claudecodecamp). La variante progressive (I-04/I-08/I-26) n'a **jamais été mesurée**. L'hypothèse théorique à trancher est exactement ce point de littérature.

### TH-C1 — « Un compact-context progressif (fenêtre glissante par la tête + résumé bit-stable en ancre) retombe à hit ≥ 50 % dès le tour suivant la compaction, contre ≈ 0 % pour le /compact massif »
- **Formulation** : IV : stratégie de compaction (A : massif actuel — tout l'historique résumé en un bloc ; B : progressif — résumé bit-stable en tête + fenêtre glissante qui évince par la fin de la zone résumée, jamais au milieu) ; DV : `cached_tokens` et hit-rate du tour N+1 (post-compaction) et des 5 tours suivants.
- **Design** : session longue artificielle (200 tours, scénario S3 adapté, recommandé docs/05 Partie 6) ; 3 compactions successives dans chaque stratégie (sessions séparées A/B randomisées) ; mesurer cr au tour suivant chaque compaction + bit-identité du résumé entre compactions (hash). N ≥ 3.
- **Prédiction** : A : cr ≈ 0 au tour N+1 après CHAQUE compaction (le préfixe complet change) ; B : cr > 0 dès N+1 si le résumé est bit-stable (system + résumé matchent), avec dégradation à la 2ᵉ compaction si le résumé v1 est réécrit — sauf conception append-delta (I-26 simple : extension du bloc résumé, jamais réécriture).
- **Intérêt** : tranche la controverse littéraire avec une mesure directe ; décide si l'architecture « summary-anchor » (I-04/P2-H) vaut son coût d'implémentation ; et quantifie le vrai coût caché de la compaction de masse — jusqu'ici le corpus l'estime (« le point le plus cher de la session ») sans le chiffrer tour à tour.

### TH-C2 — « Le coût cumulé du progressif est inférieur au massif malgré des réécritures de résumé plus fréquentes »
- **Formulation** : le massif paie 1 miss géant (préfixe à sa longueur maximale) par compaction rare ; le progressif paie des miss petits et fréquents (zone évincée seulement) + des writes de résumé. Le coût total sur 200 tours est une fonction en U de la fréquence de compaction — et le minimum du progressif est en dessous du massif. IV : stratégie × seuil de déclenchement (réserve 8k/16k/32k) ; DV : `cost_total_session` + `waste` cumulé (`computeCacheWaste`).
- **Design** : variable de la campagne TH-C1 : compter coût cumulé (tours + résumés + misses) au lieu du seul tour N+1 ; faire varier le seuil.
- **Prédiction** : courbe en U : trop fréquent = writes de résumé dominants (overcaching tax sur des résumés jamais relus : les écrits de résumé sont des contenus one-shot) ; trop rare = miss géants de compaction ; l'optimum du progressif est situé à un seuil plus bas que l'optimum du massif, avec un coût total inférieur de 10-30 %.
- **Intérêt** : transforme le « moins de compactions = mieux » (consensus actuel) en « fréquence optimale mesurable » ; le résultat conditionne le dimensionnement de `reserveTokens`/`keepRecentTokens` (P2-H) et l'idée I-29 (réserve dimensionnée par coût du miss).

### TH-C3 — « L'anchor bit-stable (2 premiers tours conservés en brut) est la seule pièce qui rend le progressif rentable en cache implicite »
- **Formulation** : en cache implicite, le matcher cherche le plus long préfixe commun — sans anchor, le préfixe commun post-compaction = system seul (le résumé est nouveau) ; avec anchor (2 premiers tours bruts jamais résumés), le préfixe commun = system + anchor. La rentabilité du progressif dépend donc de la taille de l'anchor par rapport au seuil du matcher. IV : anchor absent/présent (0, 2, 5 tours) ; DV : hit post-compaction.
- **Design** : variante de TH-C1 avec tailles d'anchor croissantes ; vérifier que l'anchor reste bit-identique entre compactions (sinon biais) ; mesurer cr au tour N+1.
- **Prédiction** : sans anchor, le hit post-compaction reste ≈ 0 en implicite quoi qu'on fasse au résumé (le résumé est nouveau texte) ; avec anchor ≥ 2 tours : hit partiel proportionnel à (system + anchor) ; la valeur de l'anchor monte quand system < seuil 1024 (elle fait repasser le préfixe commun au-dessus du seuil).
- **Intérêt** : isole LA condition nécessaire du progressif (l'anchor) et la distingue de la condition suffisante (résumé bit-stable) ; sans cette distinction, une implémentation de P2-H pourrait échouer en implicite pour une raison précise et découverte trop tard.

---

## TH-Q — Le préfixe figé maximal vs la qualité : le gel a-t-il un prix ?

### État des lieux
Le corpus recommande le gel maximal (frozen system prompt = consensus 2026, H1/P0-A) et pose « non-régression qualité » comme garde-fou — **sans jamais tester la qualité comme variable** (aucun protocole du corpus mesure la réussite de tâche). C'est le trou le plus net de la recherche : on optimise un coût sans mesurer le bien qu'on achète.

### TH-Q1 — « Le gel maximal du contexte projet dégrade la réussite des tâches au-delà d'un seuil de divergence repo ↔ contexte figé »
- **Formulation** : IV : delta de divergence D entre l'état figé (AGENTS.md, contextFiles, doc pi inclus dans le system au tour 1) et l'état réel du repo au moment de la tâche (D = aucune divergence / divergences mineures / majeures : fichiers référencés modifiés ou supprimés, instructions projet obsolètes) ; DV : réussite de tâche (juge simple binaire : « la tâche aboutit-elle ? », selon les scénarios S1-S3) + nombre de tours de correction.
- **Design** : tâches réelles (S1 lecture, S2 édition) exécutées avec system figé dès le tour 1, puis le testeur modifie le repo à mi-session (D croissant) sans re-render ; A/B : gel intégral vs rafraîchissement du contexte projet (append en fin de couche projet, miss partiel court). N ≥ 10 par niveau de D. C'est le seul design du corpus où l'AGENTS.md est VOLONTAIREMENT modifié à mi-session — isolé en sessions dédiées (contrainte anti-contamination docs/05 §0.4).
- **Prédiction** : courbe en S : réussite ≈ 100 % pour D faible, chute marquée au-delà de D* (premier cas où l'agent agit sur une info périmée : ex. il édite un fichier renommé, ou applique une convention abrogée), puis plancher ; D* est attendu plus tôt pour l'édition (S2, les actions concrètes révèlent la vétusté) que pour la lecture (S1, synthèse tolérante).
- **Intérêt** : introduit la **courbe de tradeoff coût↔qualité** au lieu du gel dogmatique ; sans elle, l'implémentation P0-A risque de geler trop (la fraîcheur du contexte projet est exactement ce que P5 « la stabilité prime sur la fraîcheur » sacrifie — la question est : de combien ?). C'est l'hypothèse qui justifie que la recherche ait une dimension produit, pas seulement une dimension comptable.

### TH-Q2 — « La vétusté s'accumule : la probabilité d'erreur croît avec le nombre de tours écoulés depuis le gel, à divergence constante »
- **Formulation** : même divergence D fixe (le repo bouge une fois, le system est figé), l'impact sur la qualité croît avec le nombre de tours (l'agent « creuse » son erreur en chaînant des actions cohérentes avec l'info périmée). IV : position de la tâche test dans la session (tour 2 vs tour 30, D identique) ; DV : réussite + tokens de correction.
- **Design** : sessions longues (30-40 tours) où le repo diverge au tour 5 et où des tâches-tests sont injectées à intervalles réguliers après ; comparer aux sessions témoin sans divergence.
- **Prédiction** : non-linéarité : les premières tâches post-divergence réussissent (l'agent remarque l'écart via les outils read/bash — le tool result est frais !), mais dès qu'une action chaînée part d'une hypothèse périmée, l'erreur se propage et le coût de correction explose (d'où la forme en S de TH-Q1, avec une composante « profondeur de session »).
- **Intérêt** : nuance TH-Q1 avec la variable temps (le gel n'est pas également dangereux à tout âge de session) ; renseigne la politique P5 (le différé des changements dans les FIRST tours est peu coûteux en qualité, coûteux dans les derniers — le bon moment de rafraîchir n'est pas « la prochaine frontière » mais « avant que l'agent ne chaîne des actions »).

### TH-Q3 — « Le compromis optimal est le gel structurel + rafraîchissement ciblé en queue : il surperforme le gel total ET le rafraîchissement total »
- **Formulation** : le gel total (H1 pur) maximise le hit mais minimise la fraîcheur ; le rafraîchissement total maximise la fraîcheur mais paie des misses ; l'hypothèse : le point Pareto-optimal est le gel du **noyau structurel** (intro, guidelines, doc pi, ordre d'outils) + rafraîchissement **des faits projet uniquement, en fin de couche projet** (miss partiel court ~100-700 tokens, cf. H3 mesuré) — car les faits projet sont l'élément qui pèse le plus sur la qualité (TH-Q1) et le moins sur le coût quand il est en queue (positionnement mesuré de pi). IV : 3 politiques (gel total / gel-structurel + rafraîchissement queue / rafraîchissement total) ; DV : (coût total de session, réussite de tâche) — bi-objectif.
- **Design** : A/B/C randomisé sur les scénarios S1/S2/S5 (celui-ci avec AGENTS.md), 2 niveaux de divergence (faible/forte) ; tracer le front de Pareto coût × qualité (3 points par cellule suffisent à ordonner).
- **Prédiction** : gel total : coût min, qualité dégradée au-delà de D* ; rafraîchissement total : qualité max, coût max (miss total à chaque changement de contexte) ; politique 2 : coût ≈ gel total (miss partiel ≤ 700 tokens, H3 l'a mesuré) avec qualité ≈ rafraîchissement total — dominante sur les deux autres pour D élevé.
- **Intérêt** : donne le **design de P0-A final** (le découplage F1 n'est pas « geler tout » mais « geler le bon étage ») ; et fournit la première fonction objectif bi-dimensionnelle de la recherche, réutilisable pour arbitrer toutes les autres optimisations (une optimisation qui réduit le coût mais dégrade la qualité au-delà du bruit doit être rejetée par construction — c'est la règle de non-régression 2 % du corpus, étendue à la qualité).

---

## Synthèse : dépendances, priorité, budget

### Dépendances entre hypothèses
```
TH-O1 (δ population, P_max) ──► TH-W1 (forme de l'échauffement : rampe = f(δ))
TH-O3 (rôle de la clé)      ──► TH-E3 (isolement par clé vs réutilisation)
TH-W2 (reprise froide = cold) ──► arbitrage I-17 (resume vs session neuve)
TH-C3 (anchor = condition nécessaire) ──► TH-C1/TH-C2 (mesure du progressif)
TH-Q1 (seuil de divergence)  ──► TH-Q3 (Pareto) ──► design final de P0-A/H1
```

### Ordonnancement recommandé (coût d'abord, en bac à sable `.pi-test`)

| Ordre | Hypothèses | Pourquoi d'abord | Coût estimé |
|---|---|---|---|
| 1 | TH-O1/O2/O3 | 0 contenu modifié : diffs de champ/délai seulement ; calibre les autres | 0,2-0,6 $ |
| 2 | TH-W1/W2 | réutilise TH-O1 (mêmes sessions prolongées) | 0,1-0,3 $ |
| 3 | TH-P1/P3 | padding utile simulé, sessions courtes | 0,2-0,5 $ |
| 4 | TH-C1/C2/C3 | sessions longues artificielles (les plus coûteuses), à faire ensemble | 0,5-1,0 $ |
| 5 | TH-E1/E2/E3 | parallélisme : coûteux en temps réel | 0,3-0,8 $ + temps |
| 6 | TH-M1/M2/M3 | dépend de l'API des modèles (thinking exposé) | 0,2-0,5 $ |
| 7 | TH-Q1/Q2/Q3 | nécessite un juge (manuel ou modèle) — à planifier séparément | 0,3-0,6 $ + jugement |

**Total** : ≈ 2-4 $ + temps réel, dans l'enveloppe des campagnes docs/05 (1,5-3,5 $). Toutes passent par le cadre anti-biais (repos égalisés, sessions séparées, randomisation, warmup, N ≥ 5, médiane + IQR) ; TH-Q est le seul qui ajoute un juge.

### Ce que ces hypothèses décident de façon unique
1. **TH-O** → le SLO/auto-toggle (I-22) peut-il être calibré hors bruit ? Sinon toute optimisation est pilotée par un cache qu'on ne comprend pas.
2. **TH-P** → borné la « cuite au préfixe long » (I-02) : la bonne taille d'un footprint est une fonction de la longueur de session, pas un slogan.
3. **TH-M** → le niveau de thinking est-il un événement gouverné coûteux (P4) ou un mythe ?
4. **TH-W** → le warmup (P1-D) est-il un ping ou un premier tour réel ?
5. **TH-E** → le cache est-il une ressource à ordonnancer (multi-agents) ? La clé projet (I-11) est-elle sûre ?
6. **TH-C** → la controverse littéraire compaction se tranche par mesure, et P2-H reçoit sa spécification (anchor oui/non, seuil optimal).
7. **TH-Q** → le gel (H1/P0-A) s'implémente-t-il à quel étage ? (structurel seulement, faits projet rafraîchis en queue)

## Risques résiduels (pour l'orchestrateur)
- **Accessibilité** : TH-M suppose un modèle avec thinking exposé et mesurable (gpt-5.6-sol sur commandcode est le candidat) ; si l'API ne sérialise pas les pensées côté usage, TH-M2 devient inobservable → le réduire à TH-M1 (field de requête) seul.
- **Observabilité** : l'éviction LRU (TH-E) est inférée depuis le client (`cached_tokens`) ; sans métrique serveur, on mesure un composé (routage + éviction + TTL) — les conclusions sont donc en termes de « topologie de cache » cohérents avec TH-O3, pas en mécanismes serveur purs.
- **Faux positifs temporels** : TH-O4 (charge) et TH-E1 (éviction) peuvent se confondre (une chute de hit en heure pleine peut être de l'éviction OU de la dispersion de routage) — les designs séparent les créneaux et utilisent la clé comme contrôle ; à documenter dans les traces.
- **Coût des longues sessions** : TH-C et TH-E sont les plus coûteuses ; les réduire d'abord à un pilote (1 session par cellule) avant campagne complète (pattern pilote/campagne docs/05 §6.5).
- **TH-Q et le protocole anti-biais** : modifier AGENTS.md à mi-session est l'anti-pattern du protocole (repos égalisés) — TH-Q requiert un **dérivé spécifique** du cadre (divergence contrôlée et ISOLÉE dans des sessions dédiées), à valider par l'orchestrateur avant exécution pour ne pas contaminer les autres campagnes.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Rapport rédigé au chemin de sortie imposé (phase5-hypotheses/02-hypotheses-theoriques.md), en français : 7 domaines explorés (TH-O non-déterminisme OpenAI, TH-P longueur de préfixe, TH-M effet thinking, TH-W cold/warm start, TH-E éviction LRU, TH-C compaction minimale, TH-Q stabilité vs qualité), chacun avec formulation testable (IV/DV), design d'expérience court (N≥5, framework anti-biais docs/05), prédiction qualitative et intérêt ; plus synthèse des dépendances, priorisation avec budget et risques résiduels. Le corpus existant a été lu intégralement (phase1, phase2, phase3, phase4, docs/05) et les verdicts mesurés (H1 nuancée, H2 optimale, H3 réfutée, H4 inapplicable, H5 non testé, H6 validée) sont respectés — aucune hypothèse réfutée réintroduite ; les propositions sont des extensions (courbes, points de bascule, modèles probabilistes, dimension qualité) absent du corpus."
    }
  ],
  "changedFiles": [
    "/home/anhydrite/.pi/agent/sessions/--home-anhydrite-Documents-beta_labo-recherche-cache-hits--/subagent-artifacts/outputs/52ba480d-42fd-4f94-ad02-bc75bc25eaf5/.research/phase5-hypotheses/02-hypotheses-theoriques.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "read corpus complet : phase1 (00-web, 01-harnesses, 02-cache-infra, 03-literature), phase2 (01-mecanisme, 02-gouvernance-pi), phase3-blind (01-blind-harness, 02-blind-infra), phase4-synthese (01-actions, 02-architecture), docs/03-conclusions, docs/05-protocoles (intégral, 821 lignes), README",
      "result": "passed",
      "summary": "Contexte intégral lu avant rédaction ; verdicts H1-H6 vérifiés ; 19 hypothèses théoriques nouvelles rédigées (TH-O1..O4, TH-P1..P3, TH-M1..M3, TH-W1..W3, TH-E1..E3, TH-C1..C3, TH-Q1..Q3), chacune testable avec design court, prédiction qualitative et intérêt"
    },
    {
      "command": "mkdir -p + vérification du dossier de sortie (subagent-artifacts/outputs/52ba480d-.../.research/phase5-hypotheses)",
      "result": "passed",
      "summary": "Dossier créé, fichier écrit au chemin imposé (vérifié par écriture directe du write tool)"
    }
  ],
  "validationOutput": [
    "Fichier écrit au chemin exact imposé ; structure markdown : positionnement (existant vs nouveau), 7 sections TH-O/P/M/W/E/C/Q avec formulation testable/design court/prédiction qualitative/intérêt, synthèse (dépendances, ordonnancement priorisé avec budget estimé 2-4 $, décisions uniques), risques résiduels, acceptance-report"
  ],
  "residualRisks": [
    "TH-M dépend de l'exposition du thinking dans l'API des modèles accessibles (gpt-5.6-sol candidat) ; si les pensées ne sont pas sérialisées côté usage, TH-M2 devient inobservable et se réduit à TH-M1 (field de requête)",
    "TH-E (éviction LRU) est une inférence client via cached_tokens : le signal mesure un composé routage+éviction+TTL, interprété en termes de topologie de cache cohérents avec TH-O3 — pas de mesure serveur possible via les APIs",
    "TH-O4 (charge) et TH-E1 (éviction) peuvent se confondre temporellement : les designs séparent les créneaux et utilisent la clé comme contrôle, à documenter dans les traces",
    "TH-C et TH-E sont les campagnes les plus coûteuses (~0,5-1 $ chacune) : passer par un pilote 1 session/cellule avant campagne complète (pattern docs/05 §6.5)",
    "TH-Q requiert une dérogation au protocole anti-biais (modification contrôlée d'AGENTS.md à mi-session, en sessions dédiées) : à valider par l'orchestrateur avant exécution pour éviter toute contamination des autres campagnes"
  ],
  "noStagedFiles": true,
  "diffSummary": "Création du livrable phase5-hypotheses/02-hypotheses-theoriques.md : 19 hypothèses théoriques nouvelles réparties sur les 7 domaines du mandat, chacune avec formulation testable (IV/DV), design expérimental court, prédiction qualitative et intérêt ; synthèse des dépendances inter-hypothèses, ordonnancement priorisé avec budget, et risques résiduels",
  "reviewFindings": [
    "no blockers: document autonome, en français, conforme au format demandé (formulation testable / design court / prédiction qualitative / intérêt), respecte les verdicts mesurés H1-H6 et le cadre anti-biais docs/05, cite les sources du corpus par identifiant (H/I/P/T)"
  ],
  "manualNotes": "Le fichier a été écrit directement au chemin de sortie imposé. Nouveauté principale : les hypothèses TH-Q (gel maximal vs qualité) introduisent la première dimension qualité de la recherche (le corpus ne l'a jamais mesurée) et TH-O fournit le premier modèle probabiliste du non-déterminisme OpenAI (rampe de population δ/P_max, sel du hash, règle de la clé, corrélation charge) — utile pour calibrer le SLO/auto-toggle I-22. Le dossier phase5-hypotheses ne contenait pas encore de fichier 01 au moment de la rédaction ; coordination avec le sister-agent sur la numérotation recommandée si le fichier 01 existe désormais."
}
```