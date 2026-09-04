# Phase 4 — Synthèse opérationnelle : SOLUTIONS À TESTER ET IMPLÉMENTER pour maximiser le cache-hit de pi

> **Rôle** : synthétiseur opérationnel.
> **Sources croisées** : phase1-recherche (00-web-external, 01-harnesses, 02-cache-infra, 03-literature), phase3-blind (01-blind-harness I-01..I-30, 02-blind-infra a1..e5), phase2-analyse (01-mecanisme, 02-gouvernance-pi), et mesures expérimentales `docs/05-protocoles-experimentaux-et-predictions.md` (Parties 5-8) + protocole anti-biais (Partie 6).
> **Méthode** : (1) croiser idées blind ↔ recherche, (2) ajouter les optimisations issues des rapports phase 1, (3) éliminer ce que nos mesures ont réfuté, (4) produire les 3 listes : IMPLÉMENTER / TESTER D'ABORD / ÉCARTÉES.

---

## 0. Base de décision : verdicts expérimentaux mesurés (docs/05, ne pas re-discuter)

| Hyp | Verdict mesuré (docs/05 P5-P8) | Conséquence pour ce document |
|---|---|---|
| **H1** frozen system prompt | **Nuancée** : rebuild par changement de *nombre* d'outils = miss **partiel** (cr 2816→2048, ~512-768 toks) ; rebuild par changement de *set* (même nombre) = **miss total** (cr=0, system régénéré car guidelines dépendent des outils) | Le fix « gerler le system » reste le chantier n°1, mais le gain est concentré sur les changements de set (MCP/plugins) et les tools à `promptSnippet`/`promptGuidelines` (F1) |
| **H2** breakpoint dernier-user | **Déjà optimale** (91.9 % hit en boucle d'outils) | Rien à implémenter ; verrouiller par tests d'invariance |
| **H3** cwd + AGENTS.md hors system | **Réfutée** (anti-biais P7) : cwd en fin de system = déjà quasi optimal (miss ~100-200 toks) ; la condition B coûte autant ou plus | Écartée (E-1) — ne PAS implémenter |
| **H4** exclude tool results | **Inapplicable** sur nos providers (cache implicite opencode-go/commandcode ; Claude bloqué par plan) | Écartée en littéral (E-2) ; garder l'esprit via compaction + table de sémantique |
| **H5** keepalive | **Non testé** (pas de sessions à pauses > TTL) | À TESTER d'abord (T-P2), implémenter opt-in après mesure |
| **H6** resume bit-identique | **Validée** (hit conservé, sessionId stable) | Rien à corriger ; verrouiller par test de régression (T6) |

**Leçons méthodologiques verrouillées** (docs/05 P4.3) : le hash du payload ne prédit pas le miss → segmenter le payload (system/tools/messages) ; `cacheRead` est la métrique reine ; le 1er tour d'une session est TOUJOURS un miss (le warmup est indispensable à toute mesure) ; les tests doivent égaliser les repos (AGENTS.md) sous peine de biais.

---

## 1. Croisement idées blind ↔ recherche phase 1 : confirmations, contradictions, conditions

### 1.1 Idées blind CONFIRMÉES par la recherche (+ nos mesures)

| Idée blind | Soutien phase 1 / mesures | Renforcement |
|---|---|---|
| **I-03** découplage system ↔ outils | Frozen system prompt consensus 2026 (00-web §2) ; Claude Code « A change to the system prompt invalidates everything » (01-harnesses §Claude Code) ; Don't Break the Cache : set d'outils dynamique (MCP) = invalidation (03-literature §1) ; oh-my-openagent#1247 : plugins ⇒ 0 % hit (00-web §7) ; F1 gouvernance ; **mesure docs/05 : miss total quand le set change** | CONFIRMÉE — priorité n°1 |
| **I-05** ordre canonique stabilité décroissante + CI | Consensus « statique en tête, volatil en fin » (02-cache-infra §3.1) ; pi a déjà corrigé la date (#6621) et met le cwd en fin (mesure T3) | CONFIRMÉE (discipline, coût nul) |
| **I-10** warmup + keepalive | Keepalive Economics arXiv 2607.19214 (dédié H5) ; aider `warm_cache`/`--cache-keepalive-pings` ; cause n°1 de miss = `CacheMiss{idleMs}` ; OpenAI : population asynchrone « secondes à minutes » (00-web §5) ; **mesure : 1er tour = miss systématique** | CONFIRMÉE — TTL long d'abord, keepalive opt-in après test |
| **I-12** TTL long par défaut + politique par session | Best practice 02-cache-infra §3.4 ; C6 (docs/03) : régime moyen = TTL long ; opencode CachePolicy (01-harnesses) | CONFIRMÉE — quick win |
| **I-14** breakpoints/writes sélectifs par (provider, modèle) | goose `cache_semantics.rs` ; Overcaching Tax (00-web §3, 03-literature §8) ; H9 ; pi `compat.*` déjà épars | CONFIRMÉE — formaliser en table |
| **I-07** suffixe minimal / purge tool results périmés | opencode supprime les tool outputs anciens (01-harnesses) ; l'overcaching tax (contenu one-shot) ; docs phase2 faiblesse n°3 : « suppression ciblée absente » | CONFIRMÉE |
| **I-06** ordonnancement anti-miss (grouper+avancer les invalidations) | Claude Code : édition CLAUDE.md différée au prochain cycle (01-harnesses) ; coût d'un miss ∝ longueur conversation | CONFIRMÉE |
| **I-04 / I-08** compaction qui préserve le préfixe | claudecodecamp : le parent compacté garde le préfixe (00-web §7) ; pi persiste `previousSummary` + `keepRecentTokens` (gouvernance §1.4) ; breakpoint system reste utile post-compaction | CONFIRMÉE (démarche, à mesurer) |
| **I-20** doc pi hors system (outil help) | F7 (changement de version = miss) ; consensus frozen system (00-web §2) | CONFIRMÉE |
| **I-22** SLO + auto-toggle par (provider, modèle) | OpenAI « borked » 2025-2026 : hits 1/20, `prompt_cache_key` sans effet — **désactiver le cache est parfois la bonne décision** (00-web §5, 02-cache-infra §2) ; pi a déjà `computeCacheWaste` + footer CH | CONFIRMÉE |
| **I-23** lint « préfixe-stable » extensions | oh-my-openagent#1247 (architecture de plugins Casse le cache) ; F4 (surfaces `before_request`/`onPayload`/`systemPromptOverride` non surveillées) | CONFIRMÉE |
| **I-19** re-soumission après miss (2ᵉ chance) | OpenAI : la population est asynchrone, un préfixe bit-identique peut devenir hit 1-3 s plus tard (00-web §5) | CONFIRMÉE (test léger) |
| **I-01** construction canonique inter-sessions | yage.ai : le caching est une contrainte de première classe (00-web §1) ; Willow : −90 % coût / −85 % latence pour préfixe stable ; clé par session déjà stable chez pi (gouvernance Force 2) | CONFIRMÉE comme direction long terme |
| **I-21** headers/session stables | pi envoie déjà 3 formats de session-affinity + `prompt_cache_key` clampé 64 chars (gouvernance §1.3) | CONFIRMÉE = audit, pas de code nouveau |

### 1.2 Idées blind CONTREDITES ou CONDITIONNÉES par nos mesures

| Idée blind | Contradiction / condition | Sort |
|---|---|---|
| **I-04 + a4/cwd variant** : sortir cwd+AGENTS.md du system | **H3 réfutée** (docs/05 P7) : cwd en fin = miss ~100-200 toks, gain nul, injection en 1er message peut coûter plus | Écartée (E-1) |
| **b2 variants / ancrage « par rôle »** : améliorer le breakpoint boucle | **H2 déjà optimale** (91.9 %) ; l'ancrage par rôle piège sur dernier message tool_result (goose `prefix_invariance.rs`) | Écartée (E-3) |
| **b4/e3** exclude tool results (hybride) | **H4 inapplicable** : nos providers sont en cache implicite, le client ne contrôle pas la frontière ; Claude bloqué (MODEL_NOT_IN_PLAN) | Écartée en littéral (E-2), esprit via compaction |
| **I-17** cold resume → session neuve + mémoire | **H6 validée** : le resume est bit-identique et conserve le hit — la prémiisse « resume = miss de l'historique » est fausse dans notre environnement | Écartée (E-4) |
| **I-16** padding pour dépasser les seuils | L'ablation (03-literature §1) : sous le seuil → régression TTFT 10-18 % — mais **padding pur = taxe** (write 1.25× au 1er tour, « bill 5x ») ; pi system ≈ 2.5-4.5k toks (T7.3), juste au-dessus de Gemini 4096 | Conditionnée : uniquement « padding utile » stable (T-P4) |
| **I-11** clé par projet | Confortée par Azure 60→87 % (00-web §5) MAIS limitée par le non-déterminisme OpenAI (clé = indice, pas garantie) et l'éviction LRU mutuelle (I-25) | À tester (T-P8), pas d'implémentation directe |
| **I-30** footprint épinglé à HEAD | Pertinent, mais vétusté sur branche active ⇒ miss partiel du bloc ; à coupler avec I-01 (chemins relatifs) | Sous-condition de T-P4 |

### 1.3 Optimisations issues DIRECTEMENT des rapports phase 1 (à intégrer, hors idées blind)

1. **Frozen system prompt comme consensus 2026** (00-web §2, 03-literature §6) → corps de l'implémentation P0-A (append des changements, jamais de réécriture du bloc initial).
2. **Exclude tool results « selon le modèle »** (03-literature §1, table par modèle : GPT-5.2 → exclude ; Sonnet → system-only) → entrée de la table de sémantique P0-B pour les providers explicites ; inapplicable en implicite (E-2).
3. **Keepalive economics** (arXiv 2607.19214, 02-cache-infra §4) → règle économique du keepalive : `P(réutilisation) × bénéfice > coût des pings` ; ping = lecture du préfixe existant, pas ré-écriture.
4. **prompt_cache_key non-déterministe** (00-web §5, F6) → **mesurer, pas présumer** : SLO + auto-toggle (P2-L), jamais de confiance aveugle dans la clé.
5. **Anti-overcaching** (00-web §3/getnadir) → `cacheRetention:"none"` sur les contenus one-shot (appels de résumé de compaction — pi le fait déjà), table sémantique `Uncached`.

---

## 2. (a) SOLUTIONS À IMPLÉMENTER dans pi — liste priorisée

> Justification croisée [chercheurs + blind + mesures]. Effort : F=faible (<1 j), M=moyen (1-3 j), E=élevé (>3 j). Risque et gain = appréciation.

### P0-A — Découplage system prompt ↔ outils + gel du system (I-03 / a1 / F1)
- **Quoi** : (1) sortir du system prompt les guidelines dérivées du set d'outils (`hasBash||hasPowerShell→…`, snippets) → les reloger dans les **descriptions d'outils** (cacheables) ou en append de fin ; (2) geler `_baseSystemPrompt` au 1er tour ; tout changement d'outils/ressources = **application différée** au prochain cycle (pattern Claude Code) ou append en queue de prompt — jamais de réécriture du bloc initial.
- **Justification** : chercheurs — Claude Code « une modif du system invalide tout », Don't Break the Cache « garder un set fixe », consensus frozen 2026, oh-my-openagent#1247 (0 % hit par plugins) ; gouvernance F1 (racine du miss massif) ; blind I-03 Tranche A. **Mesures docs/05** : miss **total** (cr=0) dès que le set change en gardant le nombre (read,bash→read,edit), miss partiel quand le nombre change — le fix élimine les deux.
- **Effort** : E (refonte `buildSystemPrompt` + discipline extensions). **Risque** : M (guidelines relogées : valider la qualité — le modèle doit garder les règles). **Gain attendu** : le miss le plus fréquent des sessions MCP/plugins est éliminé ; prédiction docs/05 H1 : 0.02-0.15 $/session en dev normal, **>1 $/session en MCP-heavy**.

### P0-B — Table de sémantique (provider, modèle) type goose + écritures sélectives (I-14 / H9 / b5 + anti-overcaching)
- **Quoi** : formaliser `(provider, modèle) → ExplicitBreakpoints | ImplicitStrict | ImplicitTolerant | Uncached` (fallback `ImplicitStrict`) ; émettre `cache_control` **si et seulement si** ExplicitBreakpoints ; `retention:"none"` sur Uncached ; pas de `prompt_cache_key` hors OpenAI-compatible ; intégrer le choix provider « exclude tool results » pour les modèles où le papier le recommande (GPT-5.2 class), et system-only pour Sonnet class. Réutiliser les flags `compat.*` existants + les mesurer contre vérité terrain.
- **Justification** : goose `cache_semantics.rs` (01-harnesses §goose) ; Overcaching Tax (00-web §3) ; H9 (T9 offline 0 $) ; 02-cache-infra §3.8 ; blind I-14/b5.
- **Effort** : M. **Risque** : F-M. **Gain** : pas de `cache_control`/`cache_write` sur providers sans cache (0.5-2 % du coût des sessions concernées) + robustesse (pas d'erreurs 400, pas de write-taxes). Gate : T9 offline puis observations 2 semaines.

### P0-C — TTL long par défaut (quand supporté) + politique par session (I-12 / c1)
- **Quoi** : `PI_CACHE_RETENTION=long` par défaut si `compat.supportsLongCacheRetention` (1 h Anthropic / 24 h OpenAI) ; exposer `cacheRetention` par session (`off|short|long`) à la opencode CachePolicy ; garder `none` pour les contenus one-shot.
- **Justification** : 02-cache-infra §3.4 ; C6 régime moyen (pauses 5 min-1 h = cause n°1 de miss `idleMs`) ; blind c1 P1. « Keepalive gratuit » sans coût de ping.
- **Effort** : F. **Risque** : F (documenter résidu de données/résidence pour env. sensibles). **Gain** : élimine les misses de pause 5 min-1 h sans écrire de code de ping.

### P1-D — Warmup au démarrage (I-10a)
- **Quoi** : avant le 1er appel réel, envoyer le préfixe (system + tools) seul, `max_tokens≈1`, si la session a de fortes chances de dépasser 2 tours ; ratio plafonné. (Le 1er tour réel est un miss — mesuré docs/05 — le warmup le transforme en hit.)
- **Justification** : mesure docs/05 (« le 1er tour est toujours un miss ») ; OpenAI population asynchrone (00-web §5) ; blind I-10.
- **Effort** : F-M. **Risque** : F (coût = 1 write 1.25× du préfixe si la session est abandonnée — garder l'option off). **Gain** : chaque démarrage de session coûte moins (préfixe relu à 0.1-0.5×) + TTFT du 1er tour réduit. **Gate : test T-P1 d'abord.**

### P1-E — Keepalive probabiliste opt-in (I-10b / c2-c4 / H5)
- **Quoi** : flag `PI_CACHE_KEEPALIVE` (miroir `AIDER_CACHE_KEEPALIVE_DELAY`) ; ping = même préfixe + `max_tokens≈1`, à TTL/2 pendant l'inactivité, **uniquement** si (a) session « vive » (activité récente, process en cours) et (b) P(reprise) estimée élevée — règle économique arXiv:2607.19214 : `P(reprise) × bénéfice > coût des pings`. Vérifier provider par provider que les lectures prolongent le TTL avant activation.
- **Justification** : papier dédié 2026 (02-cache-infra §4) ; aider (01-harnesses) ; prédiction docs/05 H5 : rentable si reprise ≥ 60-80 %, sinon inutile (pauses courtes déjà couvertes par le TTL).
- **Effort** : M. **Risque** : M (si TTL non prolongé par lecture ⇒ inutile ; ping write mal réglé = taxe 1.25×). **Gain** : 0.005-0.02 $/reprise évitée + TTFT sur sessions à pauses prévisibles. **Gate : test T-P2 d'abord, OFF par défaut.**

### P1-F — Suffixe minimal : troncature à la source + purge ciblée des tool results périmés (I-07 / e3)
- **Quoi** : tronquer les sorties longues (bash/read/grep) dès l'envoi (tête/queue + « N lignes omises », plein conservé dans l'état local) ; supprimer/compacter les tool results obsolètes **derrière le dernier point de divergence** (jamais avant — ne pas casser le préfixe).
- **Justification** : opencode (01-harnesses) ; levier L3 « multiplicateur » (toutes sessions, sans toucher au hit-rate) ; l'overcaching tax (contenu one-shot) ; docs phase2 faiblesse n°3.
- **Effort** : M. **Risque** : F-M (qualité si troncature agressive ; valider par tests de tâche). **Gain** : tokens relus par tour réduits sur TOUS les profils (×1.3-×1.8 estimé blind). **Gate : test T-P3.**

### P1-G — Ordonnancement anti-miss : grouper/avancer les invalidations inévitables (I-06)
- **Quoi** : en session longue, différer tout changement de clé (skills, outils MCP additifs, contextFiles) à la prochaine frontière (fin de tour / prochain cycle) ; grouper plusieurs changements dans un seul tour ; notification UX du différé.
- **Justification** : Claude Code anti-invalidation délibérée (01-harnesses) ; coût d'un miss ∝ longueur de conversation (remarque 5 du mécanisme, 02-blind-infra) ; blind I-06.
- **Effort** : M. **Risque** : F (UX différé à gérer). **Gain** : le coût des changements en sessions longues passe de « préfixe entier » à « préfixe court » (×1.5-×2 estimé).

### P2-H — Compaction : moins de misses, résumé stable en tête (I-08 / e1-e2)
- **Quoi** : augmenter `keepRecentTokens`/réserve (compactions moins fréquentes = miss de compaction rare) ; garantir `previousSummary` bit-stable pendant la session (déjà persisté — verrouiller par test) ; ordre post-compaction : system → summary stable → tours récents.
- **Justification** : miss de compaction = point le plus cher de la session (préfixe maximal) ; claudecodecamp (parent compacté garde le préfixe) ; gouvernance §1.4 (pi compacte en masse, isole les entrées compaction) ; blind I-08. Esprit H4 inapplicable relayé ici (P8.3 : remplacer les vieux tool results par des résumés raccourcit le suffixe relu).
- **Effort** : M. **Risque** : M (qualité, débordement de fenêtre). **Gain** : sessions longues (×1.2-×1.5). **Gate : test T-P5.**

### P2-I — Lint « préfixe-stable » + guardrails extensions (I-23 / F4)
- **Quoi** : hook garde qui hache le préfixe (system+outils+début conversation) avant/après `before_request`/`onPayload`/`systemPromptOverride` et émet un warning si le hash change hors points autorisés (cwd, dernier message) ; doc extensions.
- **Justification** : oh-my-openagent#1247 (les plugins cassent le cache → 0 % hit) ; F4 (surfaces non surveillées) ; gouvernance 4.3.6.
- **Effort** : M. **Risque** : F. **Gain** : prévention de régression (protège toutes les autres optimisations).

### P2-J — Doc pi hors system prompt (I-20 / F7)
- **Quoi** : déplacer le bloc « Pi documentation » (README/docs) dans un outil `help` appelable on-demand ; le system ne change plus qu'aux vraies règles.
- **Justification** : F7 (upgrade pi = miss du 1er tour) ; consensus frozen system (00-web §2).
- **Effort** : F. **Risque** : F-M (tokens par appel de doc ; le modèle perd la doc en contexte permanent — tester la qualité). **Gain** : stabilité inter-versions.

### P2-K — Verrouillage de la clé : sessionId stable + snapshot resume (I-21 / d1-d2 / garde-fou H6)
- **Quoi** : audit — sessionId ne change qu'avec `/new` (branches, navigation tree) ; headers d'affinité et user-agent stables par session ; test de régression « snapshot dernier tour vs prompt reconstruit au resume » (H6 déjà OK — le verrouiller).
- **Justification** : H6 validée (docs/05) ; 00-web §5 (la clé est un indice, pas une garantie → maximiser la probabilité par stabilité) ; gouvernance 4.3.4.
- **Effort** : F. **Risque** : F. **Gain** : protège tout (les sessions reprises gardent les hits 24 h).

### P2-L — SLO + auto-toggle par (provider, modèle) (I-22 / F6)
- **Quoi** : agrégat `cacheRead/promptTokens` et `computeCacheWaste` par (provider, modèle) ; seuil d'alerte (hit < 40-85 % selon profil) ; **auto-toggle** : si hit durablement < seuil sur préfixe stable → basculer la stratégie (off / short / pas de breakpoints). C'est la réponse au cache OpenAI non-déterministe (mesurer, pas présumer).
- **Justification** : OpenAI « borked » hits 1/20 (00-web §5) ; blind I-22 ; gouvernance 4.2 (CH < 85 % en boucle = régression).
- **Effort** : M. **Risque** : F. **Gain** : évite de payer l'overhead de cache sur les providers défaillants ; pilotage par les données.

---

## 3. (b) SOLUTIONS À TESTER D'ABORD — protocoles courts

> Cadre : bac à sable `.pi-test` (docs/05 Partie 3), anti-biais (docs/05 Partie 6 : scénarios S1-S8, sessions séparées A/B randomisées, warmup, repos égalisés, médiane+IQR, critère : gain ≥ 5 % sur ≥ 70 % des scénarios applicables, non-régression ≤ 2 %). Coût global campagne ≈ 1.5-3.5 $ (docs/05 §2.2).

| # | Solution (source) | Protocole court (tours, conditions, métrique) | Prédiction chiffrée (docs/05 §0.1) | Décision |
|---|---|---|---|---|
| **T-P1** | Warmup 1er appel (I-10a) | 2 conditions (avec/sans warmup) × N≥5 sessions de 3 tours, même repo/modèle ; mesurer `cached_tokens` du 1er appel réel + `cost_total_session`. Scénarios S1, S2 | avec : cr > 0 dès le 1er appel ; sans : cr = 0 (1er tour = miss systématique, mesuré) | Activer si gain médian ≥ 5 % coût total, sans régression TTFT |
| **T-P2** | Keepalive (H5/T5 docs/05) | Pauses contrôlées D = {3, 6, 15, 40} min × 3 configs (aucun ping / ping TTL/2) × N≥5 ; mesurer cr au tour de reprise, coût cumulé pings inclus, `prefix_diff=0` après ping ; vérifier si les lectures prolongent le TTL (provider par provider). Scénario S7 | miss de reprise ≈ 0.012 $ (system 4k) ; ping ≈ 0.015 $ (write) ; rentable si P(reprise) ≥ 60-80 % | OFF par défaut ; ON seulement si le seuil de rentabilité est atteint sur le profil |
| **T-P3** | Troncature/purge tool results (I-07) | A/B sessions avec sorties volontairement longues (S4 boucle, S3 long feature) ; mesurer tokens relus/tour (hit-rate attendu inchangé) + qualité de la tâche (juge simple : la tâche aboutit-elle ?) | tokens relus −30 %+ à hit-rate identique (91.9 % baseline H2) ; qualité non dégradée | Activer si tokens relus ≥ −30 % et aucune régression > 2 % |
| **T-P4** | Footprint repo utile / padding utile (I-02+I-16, conditionnel I-30) | Sur repo avec AGENTS.md : bloc `repo_footprint` épinglé au HEAD (README condensé, structure, index) ; CI : hash du system 2× à froid = identique ; A/B 2 sessions séquentielles même repo : cr du 1er appel ; vérifier dépassement des seuils (Gemini 4096 — système pi ≈ 2.5-4.5k, T7.3) | cr 1er appel > 0 sur ≥ 70 % des sessions ; pas de « bill 5x » (padding pur interdit) | Activer si le contenu est utile (jamais du remplissage) et stable inter-sessions |
| **T-P5** | Compaction douce (I-08) | Session longue artificielle (200 tours) : fenêtre glissante vs compaction de masse actuelle ; mesurer waste cumulé, nb de cr=0, qualité | waste −20 %+, miss_count réduit, fréquence de compaction ÷2-3 | Activer selon les résultats + non-régression qualité évaluée |
| **T-P6** | Auto-toggle SLO (I-22, passif) | 2 semaines de télémétrie par (provider, modèle) : CH + `computeCacheWaste` + causes de miss (déjà instrumenté) — 0 $, en parallèle de tout | hit ≥ 85 % en boucle sur les providers sains ; détection des providers défaillants (OpenAI intermittents) | Calibrer les seuils d'auto-toggle avec les données |
| **T-P7** | Re-soumission 2ᵉ chance (I-19) | Sur préfixe chaud observé cr=0 (ou retry réseau) : re-soumettre le payload bit-identique ; mesurer le taux de 2ᵉ hits (N≥10) | taux ≥ 50 % si la population OpenAI est bien asynchrone (00-web §5) | Intégrer au retry provider existant si ≥ 50 % |
| **T-P8** | Clé par projet (I-11, spéculatif) | 10 sessions courtes séquentielles même repo, `prompt_cache_key = H(provider ∥ repo_id)` vs par-session ; distribution de cr du 1er appel ; surveiller l'éviction mutuelle avec 2 sessions parallèles (I-25) | médiane de cr du 1er appel plus haute avec clé projet (inspiré Azure 60→87 %) | N'implémenter que si le gain se confirme ET pas d'éviction mutuelle |

**Priorité faible / plus tard** (protocole = variantes des précédents, pas de campagne dédiée) : I-13 (fusion de messages courts — 2 sessions jumelles, 1 tour économisé) ; I-28 (blocs thinking isolés — sessions thinking sur provider explicite) ; I-15 (pre-warming cron — 2 jours, cr du 1er appel matinal) ; I-18 (résumé de session croisé — 5 sessions successives, cr du 1er appel) ; I-27 (coût de miss ex ante — UX A/B).

---

## 4. (c) SOLUTIONS ÉCARTÉES (et pourquoi)

| # | Solution écartée | Source | Raison (mesure / recherche) |
|---|---|---|---|
| **E-1** | Déplacer cwd + AGENTS.md hors du system prompt (H3, a4, variantes I-04/I-05 cwd) | docs/05 P7 | **RÉFUTÉE par nos mesures** : cwd en fin de system = miss ~100-200 toks seulement ; la condition B n'apporte aucun gain mesurable et peut coûter plus (injection dans la conversation). Le test initial positif était **biaisé** (repos avec/sans AGENTS.md) — leçon anti-biais. |
| **E-2** | Exclude tool results via déplacement de breakpoints (H4 littéral, b4/e3, « hybride ») | docs/05 P8 | **INAPPLICABLE** : nos providers (opencode-go, commandcode/deepseek/gpt) sont en cache **implicite** — le client ne contrôle pas la frontière ; les modèles Claude (explicites) sont bloqués (MODEL_NOT_IN_PLAN). L'esprit survit via la compaction (P2-H) et la table de sémantique (P0-B). |
| **E-3** | Autres placements de breakpoints en boucle (« par rôle », latest-assistant, tail-N) | H2 (docs/05) | **DÉJÀ OPTIMAL** : 91.9 % hit mesuré avec l'ancre « dernier user » de pi ; l'ancrage par rôle piège quand le dernier message est un tool_result (goose `prefix_invariance.rs`). Rien à changer ; verrouiller par tests d'invariance. |
| **E-4** | Cold resume → session neuve + mémoire (I-17) | H6 validée + docs/05 | **CONTREDITE** : le resume de pi est bit-identique et conserve le hit (H6 validée) ; la prémiisse « resume = miss de l'historique » ne tient pas dans notre environnement. Bénéfice marginal, perte de contexte perçue. |
| **E-5** | Proxy normalisateur « prompt shaper » (I-24) | 01-blind-harness | Coût élevé, gain incertain : les émetteurs pi sont déjà déterministes ; redondant avec I-01/CI. |
| **E-6** | Orchestration d'éviction multi-sessions (I-25) et compact delta append-only (I-26) | 01-blind-harness | Spéculatifs, coût élevé ; I-26 est éclipsé par I-08 (même objectif, plus simple). Réévaluer après T-P5. |
| **E-7** | Padding pur pour dépasser les seuils (I-16 « remplissage ») | 03-literature + 00-web | Overcaching tax : écritures inutiles 1.25× + régression TTFT documentée (GPT-4o −8.8 %) ; « bill 5x » au 1er tour. Seul le padding **utile et stable** est accepté (T-P4). |
| **E-8** | Do NOTs listés par les blind eux-mêmes : breakpoints par rôle ; pinger pendant les commandes courtes (boucle déjà à 91.9 %) ; « stabiliser » le texte des tool_results (ils sont dans le suffixe relu de toute façon) ; cache complet partagé entre conversations différentes via clé commune (texte diffère dès le 1er message + éviction mutuelle) ; tout cacher partout | 01-blind-harness §8, 02-blind-infra | Confirmés par les mesures : H2, l'overcaching tax, la nature suffixe des tool results. |

---

## 5. Règles de gouvernance à verrouiller (transverses, coût nul)

1. **Déterminisme de construction** : hash du system à froid 2× en CI (prérequis I-01/T-P4) ; interdiction formelle de volatil dans le préfixe (déjà #6621 pour la date).
2. **Un seul point de divergence par tour** : tout nouveau contenu en queue ; jamais de mutation de l'historique hors frontière connue (compaction).
3. **Changement de clé = événement gouverné** : mesuré en $ (`computeCacheWaste`), groupé et avancé (P1-G), jamais accidentel (lint P2-I).
4. **Segmenter le payload pour diagnostiquer** (leçon docs/05 P4.3 : le hash global ne prédit pas le miss — comparer system/tools/messages séparément).
5. **Mesurer, pas présumer** : le cache OpenAI est probabiliste (F6) ; les décisions d'auto-toggle s'appuient sur ≥ 2 semaines de données (T-P6).

**Ordre d'exécution recommandé** : T9 offline (table sémantique) → P0-C (TTL long, 1 jour) → T-P1/T-P2/T-P3 (campagne 1.5-3.5 $, ~1 journée) → P0-A + P1-G (chantier system, semaines 2-3) → P0-B/P1-F/P1-E selon les gates → P2-H/P2-I/P2-J/P2-K/P2-L en continu.

---

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Synthèse opérationnelle complète écrite au chemin imposé (phase4-synthese/01-actions.md), en français : croisement blind↔recherche (14 confirmations, 6 contradictions/conditions, 5 apports phase 1), liste (a) 12 solutions priorisées P0-P2 avec justification croisée/effort/risque/gain, liste (b) 8 protocoles de test courts + 5 faibles priorités, liste (c) 8 solutions écartées avec raisons (H3 réfutée, H4 inapplicable, H2 déjà optimale, H6 contredit I-17, etc.), règles de gouvernance et ordre d'exécution. Les verdicts mesurés docs/05 (H1 nuancée, H2 optimale, H3 réfutée, H4 inapplicable, H6 validée) ont été intégrés comme base de décision et ont éliminé les idées réfutées."
    }
  ],
  "changedFiles": [
    "/home/anhydrite/.pi/agent/sessions/--home-anhydrite-Documents-beta_labo-recherche-cache-hits--/subagent-artifacts/outputs/f3a106ae-d039-40d0-af39-a8bb379805e6/.research/phase4-synthese/01-actions.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "read .research/phase1-recherche/{00-web-external,01-harnesses,02-cache-infra,03-literature}.md, .research/phase3-blind/{01-blind-harness,02-blind-infra}.md, .research/phase2-analyse/02-gouvernance-pi.md, docs/03, docs/05 (intégral, 821 lignes)",
      "result": "passed",
      "summary": "Toutes les sources phase 1, phase 3, phase 2 et les mesures expérimentales docs/05 (Parties 0-8) lues intégralement avant rédaction"
    }
  ],
  "validationOutput": [
    "Fichier créé au chemin de sortie exact ; structure markdown : verdicts mesurés de référence (H1-H6), tableau de croisement blind↔recherche (12 confirmées / 6 contredites-conditionnées / 5 apports phase 1), liste (a) 12 implémentations priorisées P0-P2 avec effort/risque/gain, liste (b) 8 protocoles courts avec prédictions chiffrées et critère de décision, liste (c) 8 écartées avec justification, gouvernance + ordre d'exécution"
  ],
  "residualRisks": [
    "H5 (keepalive) reste non mesuré : l'implémentation P1-E est conditionnée au test T-P2 et au comportement de TTL « lecture prolonge-t-elle ? » par provider — ne pas activer par défaut",
    "P0-A (découplage system↔outils) touche la qualité des guidelines relogées : nécessite des tests de non-régression comportementale, pas seulement de cache",
    "Les gains chiffrés (×1.3-×1.8, 0.02-1 $/session) sont des estimations issues de la littérature et des prédictions docs/05, à confirmer par les protocoles T-P1..T-P8",
    "Le cache OpenAI reste non-déterministe même bit-identique (F6) : aucune optimisation ne garantit 100 % de hits sur ce provider — l'auto-toggle (P2-L) est la parade"
  ],
  "noStagedFiles": true,
  "diffSummary": "Rédaction du livrable de synthèse opérationnelle phase 4 (01-actions.md) : croisement phase1×phase3, liste IMPLÉMENTER (12 items P0-P2), liste TESTER D'ABORD (8 protocoles courts), liste ÉCARTÉES (8 items), règles de gouvernance et ordre d'exécution",
  "reviewFindings": [
    "no blockers: document autonome, conforme au format demandé (a/b/c concrets et actionnables), verdicts expérimentaux docs/05 respectés (aucune idée réfutée réintroduite), chemins de fichiers sources cités"
  ],
  "manualNotes": "Base de décision explicite posée en tête (table H1-H6 docs/05) pour que le parent puisse vérifier que l'élimination (liste c) colle aux mesures. Les implémentations P0-A et P0-B sont les deux chantiers structurants (fuite F1 du code + table goose) ; P0-C est le quick win immédiat (1 jour). Toutes les mesures de test passent par le bac à sable .pi-test avec le protocole anti-biais docs/05 Partie 6 (repos égalisés, warmup, randomisation A/B, critère statistique)."
}
```