# Cas de tests objectifs & indépendants par hypothèse + prédictions

> **Suite de `03-conclusions-hypotheses-optimisation.md`.** Pour chaque hypothèse H1..H10 : des **cas de tests** conçus pour être (1) **objectifs** (métrique mesurable, pas d'appréciation) et (2) **indépendants** (chaque test isole une variable, ordre des tests sans contamination), plus une **prédiction chiffrée** (avec intervalle) et le critère de réussite.

---

## Méthodologie commune (à lire avant tout test)

### M.1 Métriques objectives retenues (toutes issues d'usage API, pas de ressenti)
| Métrique | Définition | Source |
|---|---|---|
| `hit_rate` | `cache_read / (cache_read + input + cache_write)` | usage API (pi l'expose déjà : footer `R/W/CH`) |
| `cost_per_turn` | `$ (input×P_in + cache_read×P_cr + cache_write×P_cw + output×P_out)` calculé avec les prix du modèle | `calculateCost` dans pi |
| `cache_write_tokens` | tokens écrits en cache (overhead) | usage API |
| `ttft` | temps (ms) entre l'envoi de la requête et le 1er chunk de réponse (streaming) | `performance.now()` au moment du 1er événement `text_start` |
| `tokens_hit_ratio` | fraction du prompt relue en cache (`cache_read / total_input`) | usage API |
| `prefix_diff` | nombre d'octets/tokens différents entre le prompt du tour N et N+1 (avant le delta attendu) | hash du prompt sérialisé |

### M.2 Conditions de contrôle pour l'indépendance
- **Même modèle, même provider** pour toute la comparaison (le modèle fait partie de la clé de cache — jamais comparer entre modèles).
- **Même repo, même cwd, même AGENTS.md** (le contenu projet fait partie du préfixe).
- **Même session** (sessionId stable) pour tester la stabilité ; **sessions séparées** pour tester l'isolation.
- **Séquencer les tests dans le temps** : attendre > TTL entre deux conditions (sinon contamination : le tour suivant pourrait matcher le cache du test précédent). Pour Anthropic short (5 min) et OpenAI (min.) : attendre ≥ 6 min ; pour long : ≥ 65 min (ou utiliser `cacheRetention:"none"` sur le test contrôle pour forcer un cache vide).
- **Warm-up obligatoire** : 1 tour "junk" (même préfixe) avant la mesure pour que le cache soit écrit, puis mesurer sur les tours suivants.
- **Rejeter les tours anormaux** : rate-limit, erreurs réseau, réponses trop longues (les exclure des stats, les documenter).
- **Répétabilité** : chaque condition mesurée sur **N ≥ 5 sessions** (ou ≥ 10 tours par session) ; rapporter médiane + IQR (pas la moyenne seule, la latence est bruitée).
- **Rapporter le seuil min de cache** (1024/1024/4096) : si le prompt effectif < seuil, le test est invalide (le cache ne peut pas s'activer).

### M.3 Filet de sécurité (ne pas casser la prod)
- Les tests d'invalidation/simulation de fuite (H1, H2) se font sur un **fork de session** (pi supporte les branches) ou un répertoire de test dédié — jamais sur la session réelle d'un utilisateur.
- Un flag `PI_TEST_CACHE=1` peut forcer `cacheRetention`/branch pour isoler.

---

## H1 — « Frozen system prompt » : ne jamais régénérer le system prompt en cours de session

**Mécanisme testé** : `setActiveToolsByName()` appelle `_rebuildSystemPrompt()` à chaque changement d'outils (agent-session.ts:983). Le doc code dit "Changes take effect on the next agent turn" → le rebuild précède le tour suivant → miss au tour suivant.

### Tests

**T1.1 — Invalidation par changement d'outils (le test clé)**
1. Session avec outils `{read, bash, edit, write}` (défaut).
2. Tour A : prompt normal, attendre réponse. Enregistrer `cache_read_A`, `input_A`.
3. Tour B : **même prompt, aucun outil changé** (contre-exemple : vérifier que le cache matche, hit attendu).
4. Tour C : `setActiveToolsByName(['read','bash'])` (retirer 2 outils) **PUIS** tour suivant.
5. Tour D : re-ajouter les outils, tour suivant.
- **Mesure** : `cache_read` sur les tours B, C, D ; `prefix_diff` entre les prompts consécutifs.
- **Critère objectif** : si `cache_read_c ≈ 0` alors que `cache_read_B > 0`, le rebuild a bien cassé le cache.

**T1.2 — Invalidation par extension de ressources (skills/prompts)**
- Mécanisme ($2.491) : `extendResources()` → rebuild. Charger un skill en cours de session entre deux tours identiques, mesurer le `cache_read` du tour suivant.
- **Critère** : `cache_read` chute à ~0 après le chargement du skill ; redevient > 0 au tour suivant (re-écriture).

**T1.3 — Vérifier que le rebuild est la SEULE cause** (indépendance)
- Même scénario que T1.1 mais avec `cacheRetention:"none"` : le miss observé ne doit PAS dépendre du rebuild (le cache est de toute façon désactivé) → confirme que la mesure isole bien l'invalidation.
- **Critère** : `cache_read = 0` partout (cohérent, pas de faux positif).

**Prédiction T1.1** : `cache_read_C ≈ 0` (0-2 % du prompt) et `cache_read_D ≈ 0` (le cache a été ré-écrit au tour C avec le nouveau prompt, donc D devrait matcher... **attention** : si le prompt C diffère du prompt D, D est aussi un miss). **Prédiction nuancée** : chaque rebuild = 1 tour de miss complet (cache_read = 0), puis le tour suivant matche. Coût : ~1 × relecture complète du system (≈2-3k tokens) par rebuild.
**Prédiction T1.2** : idem, 1 miss complet par extension chargée.

---

## H2 — Breakpoint « latest-user-message » (pas le dernier message, qui peut être un tool result)

**Mécanisme** : pi pose le 3e breakpoint sur le dernier bloc du **dernier message `role:"user"`** (anthropic-messages.ts:1376). Or les tool results sont fusionnés dans un message `role:"user"` (ligne 1368 : `{role:"user", content:[...toolResults]}`). Donc : dans une boucle d'outils, le "dernier message user" **contient les tool results** et change à chaque appel → le breakpoint bouge → risque de miss intra-tour si la conversation est longue.

### Tests

**T2.1 — Boucle d'outils continue (le cas d'usage)**
1. Session courte : `read` un fichier, puis un `bash`, puis un `edit`, enchaînés **sans nouvelle entrée user** (l'agent continue tout seul).
2. Mesurer `hit_rate` sur chaque appel intra-tour (les 2e, 3e appels).
3. Renouveler sur une conversation plus longue (pré-charger 20 tours, puis boucle d'outils).
- **Critère** : hit_rate des appels intra-tour ; comparer avec la prédiction.

**T2.2 — Comparaison de stratégies de breakpoint (test d'indépendance par contre-exemple)**
- Même scénario, mais on force le breakpoint sur le **dernier message assistant** (variable `latest-assistant`, comme opencode le permet) au lieu du dernier user.
- **Mesure** : hit_rate intra-tour et `cache_read` des appels suivants, pour les deux stratégies.
- **Critère** : le hit_rate est-il plus élevé avec `latest-user-message` ? (prédiction : oui quand la boucle grossit)

**Prédiction T2.1** : pour une conversation courte (< ~4k tokens), les deux stratégies se comportent pareil (le breakpoint est peu loin). Pour une **conversation longue** (> 10k), `latest-user-message` garde un hit_rate intra-tour > 80 %, alors qu'un breakpoint sur le dernier tool result donnerait ~0 % (chaque résultat est unique). **Prédiction centrale** : le breakpoint actuel de pi (dernier user, qui inclut les tool results) est correct **tant que les tool results restent en fin** — mais si un jour une conversation rejoue des tool results, il faut re-ancrer.

---

## H3 — Séparer cwd + AGENTS.md du system prompt (les mettre hors préfixe durable)

**Mécanisme** : cwd et `<project_context>` sont dans `buildSystemPrompt()` → dans le préfixe caché. Un changement de cwd (ou de contexte, ou de machine au resume) casse le préfixe.

### Tests

**T3.1 — Changement de cwd en cours de session**
1. Session dans repo A, plusieurs tours (cache chaud).
2. `cd` vers repo B au milieu (ou changer le cwd simulé), tour suivant.
- **Mesure** : `cache_read` avant/après le changement ; `prefix_diff`.
- **Critère** : miss total si le cwd est dans le system prompt ; pas de perte si hors préfixe.

**T3.2 — Changement d'AGENTS.md en cours de session + reload**
1. Session avec `AGENTS.md` chargé, cache chaud.
2. Modifier `AGENTS.md`, forcer un `reloadAgentsFiles` (ou attendre le prochain reload), tour suivant.
- **Mesure** : `cache_read` avant/après.
- **Critère** : miss si le contexte est dans le system prompt et rechargé ; intact sinon.

**T3.3 — Reprise de session identique (même repo, même cwd, même AGENTS.md), même jour**
- Fermer pi, relancer, `pi resume` la session, tour suivant immédiat.
- **Mesure** : `cache_read` du 1er tour après resume.
- **Critère** : cache hit attendu si le prompt reconstruit est **bit-identique** (cf. H6).

**Prédiction T3.1** : miss total (cache_read ≈ 0) au tour suivant le `cd` — **MAIS** c'est le comportement actuel, et le fix proposé (cwd hors system) éliminerait ce miss. Coût d'un miss à 10k tokens ≈ relecture complète (~10× le prix d'un hit).
**Prédiction T3.2** : miss si reload ; le reload ne devrait pas survenir spontanément (pas de watcher), donc rare.
**Prédiction T3.3** : dépend de l'identité du prompt ; avec `AGENTS.md` + cwd identiques et `prompt_cache_key` stable (H6), hit attendu.

---

## H4 — Exclure les tool results du cache (stratégie hybride : conversation < system → cacher, sinon exclure)

**Mécanisme** : le full-context cache des tool results dynamiques → overhead de cache_write sans lecture → régression TTFT possible (documenté GPT-4o -8.8 %). Hypothèse : cacher la conversation tant qu'elle < system ; l'exclure (breakpoint avant la queue) au-delà.

### Tests

**T4.1 — Conversation courte vs system (le seuil)**
1. system ~2-4k tokens ; conversation < system (quelques tours) → mode "cacher tout".
2. conversation > system (20-30 tours de tool results volumineux) → mode "exclure la queue".
- **Mesure** : `cost_per_turn` et `ttft` pour chaque mode, N≥5 sessions.
- **Critère** : le mode hybride ne doit jamais être pire que "full" ni que "exclude" sur les deux métriques.

**T4.2 — Overhead de cache_write mesuré**
- Comparer `cache_write_tokens` entre "full" et "hybride" sur la même taille de conversation (> system).
- **Prédiction** : dans le mode "full", chaque nouveau tour écrit en cache les nouveaux tool results ; en hybride, ces tokens ne sont ni écrits ni lus.

**T4.3 — TTFT, latence perçue**
- Mesurer `ttft` sur 10 tours consécutifs, médiane, mode full vs hybride.

**Prédiction T4.1** : conversation < system → les deux se valent (Δ coût < 2 %) mais hybride l'emporte sur ttft dès que la conversation > system (moins de préfill). Prédiction : **à conversation > system, hybride gagne 10-20 % de TTFT** (cohérent avec GPT-4o -8.8 % en faveur d'exclude).
**Prédiction T4.2** : `cache_write` hybride ≈ 0 sur la queue ; full ≈ taille des nouveaux tool results par tour.
**Prédiction T4.3** : médiane TTFT hybride < médiane TTFT full (intervalle : 5-25 %).

---

## H5 — Cache-warming / keepalive intelligent

**Mécanisme** : pings silencieux périodiques (pattern aider `AIDER_CACHE_KEEPALIVE_DELAY`) pour garder le TTL Anthropic 5 min vivant pendant les pauses.

### Tests

**T5.1 — Coût d'un ping vs bénéfice d'un hit (le calcul économique)**
1. Ping = petit prompt (le même préfixe + "continue") → mesurer son coût exact (`cost_per_turn` d'un ping) et son `cache_read`.
2. Tour de reprise après pause > 5 min sans ping → coût du miss (`cost_per_turn` du miss).
3. Comparer : coût total(n pings + reprise hit) vs (reprise miss).
- **Critère objectif** : activer le keepalive **si et seulement si** `coût(pings) < bénéfice(hit)`, avec un modèle de décision probabiliste : `P(reprise dans la fenêtre)` × bénéfice > coût des pings.

**T5.2 — TTL réel observé**
- Sur chaque provider, mesurer le temps exact après lequel un tour identique devient un miss (idle expiré). Documenter 5/60/1440 min.

**T5.3 — Faux positifs du ping (ne pas gêner)
- Vérifier qu'un ping n'altère pas le flux (pas de réponse visible, pas de nouvelle entrée dans la conversation) — mesurer `prefix_diff` entre le contexte avant et après ping = 0.

**Prédiction T5.1** : sur une session active (pauses < 5 min), le keepalive est inutile (coût > bénéfice). Sur pauses 5 min–1 h avec reprise probable, bénéfice net positif si le system est > ~4k tokens (le miss coûte la relecture complète). **Seuil de déclenchement prédit** : `keepalive` rentable quand `P(reprise) × (size_system × Δprix)` > `coût_ping`, typiquement quand la session a une activité prévisible.
**Prédiction T5.2** : Anthropic short = 5 min, long = 1 h (observé), OpenAI = 24 h (ou 30 min de fenêtre de réutilisation).
**Prédiction T5.3** : ping n'altère pas le préfixe (0 diff) si implémenté correctement.

---

## H6 — Le resume reconstruit un prompt bit-identique (hits cross-process)

**Mécanisme** : `pi resume` doit reconstruire exactement le même system prompt + messages que le dernier tour pour matcher le cache OpenAI 24h / Anthropic 1h.

### Tests

**T6.1 — Bit-identité du prompt reconstruit**
1. Tour N : sérialiser le prompt complet (system + messages + tools) → hash H_N.
2. Fermer pi, `pi resume`, demander 1 tour → sérialiser le prompt reconstruit → hash H_R.
- **Critère** : `H_R == H_N` (les outils, l'ordre des tools, les AGENTS.md, le cwd, la version de pi doivent être identiques). Toute différence = miss au resume.

**T6.2 — Version de pi change-t-elle le prompt ?**
- Modifier la version de pi entre deux tours (ou simuler un message de version dans le prompt), comparer les hashs. (Le prompt pi contient la doc paths ; pas de version explicite vue, mais si des références changent → diff.)

**T6.3 — Le prompt_cache_key survit-il au resume ?**
- Vérifier que le sessionId persisté est bien réutilisé comme `prompt_cache_key` au resume (pas un nouveau uuidv7).

**Prédiction T6.1** : avec mêmes repo/cwd/AGENTS.md et même version, `H_R == H_N` est attendu... **mais attention** : le session file contient les messages + le header (sessionId, model). Si le resume reconstruit les messages **avec plus ou moins de détails** (ex. tool results re-chargés différemment), le diff apparaît. Prédiction : **miss au 1er tour du resume** si un seul octet diffère (le model du header, la clé de cache, ou l'ordre des tools). C'est le point le plus fragile.
**Prédiction T6.2** : un bump de version qui change le system prompt = miss (conforme au comportement documenté "upgrading Claude Code invalidates"). Encourager : versioner le system prompt pour que les changements soient appendés, pas réécrits.
**Prédiction T6.3** : le sessionId persisté est réutilisé (vérifié dans le code : `header.id` au load, session-manager.ts:959) → la clé ne change pas → OK pour la clé.

---

## H7 — Breakpoint system toujours présent, même sans tools

**Mécanisme** : le breakpoint system est posé conditionnellement à `context.systemPrompt` (anthropic-messages.ts:1059-1070) — donc **oui** il est posé sans tools (vérifié dans le code). La question est de savoir si ce breakpoint *suffit* quand la conversation devient la partie dominante.

### Tests

**T7.1 — Session sans tools (mode critique/plan)**
- Session avec 0 tool, plusieurs tours. Mesurer `hit_rate` (le system seul doit matcher).
- **Critère** : hit_rate élevé (> 90 %) sur le system.

**T7.2 — Le cap des 4 breakpoints respecté quand on ajoute un 4e**
- Simuler un 4e breakpoint (ex. project context) et vérifier que le plus stable est conservé (pas de drop du system).

**T7.3 — Seuil minimal (1024/4096) : le system est-il assez grand ?**
- Mesurer la taille en tokens du system prompt pi réel (infos ~2-4k ?). Vérifier qu'il dépasse le seuil. En dessous, cacher ne sert à rien (régression TTFT 10-18 % observée dans le papier).

**Prédiction T7.1** : hit_rate > 90 % sur system-seul (le system est stable). **Prédiction T7.2** : le code conserve les 3 breakpoints canoniques et n'en ajoute pas un 4e — rien à faire, mais à tester si un jour le project context devient un breakpoint séparé. **Prédiction T7.3** : system pi ≈ 2-4k tokens → au-dessus des seuils OpenAI/Anthropic, mais **juste au-dessus de 1024** — attention si on réduit les guidelines : ne pas descendre sous 1024. **Critère : system ≥ 2k tokens recommandé.**

---

## H8 — Afficher le coût du cache-waste en $ (métrique visible)

**Mécanisme** : `computeCacheWaste` (cache-stats.ts) existe déjà ; l'exposer dans le footer en $.

### Tests

**T8.1 — Exactitude du calcul de waste**
- Sur une session contrôlée (1 miss provoqué, 1 hit), vérifier manuellement que le $ affiché correspond au calcul attendu (tokens × prix).
- Exemple : system 3k tokens, 1 miss complet → waste_attendu = 3000 × (P_input - P_cache_read).

**T8.2 — Détection des causes**
- Provoquer 3 misses de causes différentes (idle > TTL, modèle changé, contenu volatile) et vérifier que le diagnostic (CacheMiss{idleMs, modelChanged}) identifie la bonne cause dans chaque cas.

**T8.3 — Stabilité du calcul sur session normale**
- Sur une session longue, vérifier que `computeCacheWaste` ne fluctue pas avec l'ordre d'appel (déterminisme).

**Prédiction T8.1** : le calcul devrait matcher à < 5 % près (les prix sont connus). **Prédiction T8.2** : le diagnostic distingue correctement idle vs modelChanged vs volatile (logique déjà dans le code). **Prédiction T8.3** : déterministe (aucune dépendance à l'ordre des appels).

---

## H9 — Table de sémantique par provider (pattern goose)

**Mécanisme** : table (provider, modèle) → `ExplicitBreakpoints | ImplicitStrict | ImplicitTolerant | Uncached` pour décider de poser ou non les breakpoints.

### Tests

**T9.1 — Breakpoints posés uniquement quand nécessaire**
- Sur un provider `ImplicitStrict` (OpenAI), vérifier qu'aucun `cache_control` n'est émis (juste la clé de session). Sur `ExplicitBreakpoints` (Anthropic), vérifier les 3 breakpoints.
- **Mesure** : inspection de la requête finale (hook `onPayload`).

**T9.2 — Pas de cache_write sur les providers Uncached**
- Providers sans cache (snowflake/sagemaker-tgi...) : vérifier que l'appel part sans cache_control ET sans écrire (pas d'overhead).

**T9.3 — Détection automatique correcte**
- Tableau de (provider, modèle) -> sémantique détectée, comparé à la vérité terrain (docs provider).
- **Critère** : aucune erreur de classification sur la liste testée.

**Prédiction T9.1** : OK une fois implémenté (pattern goose déjà validé dans son repo). **Prédiction T9.2** : suppression immédiate d'overhead sur les providers exotiques. **Prédiction T9.3** : risque d'erreur sur les providers ambigus (modèles mixtes) : prévoir un fallback `ImplicitStrict` (le plus sûr) comme goose le fait (défaut safe).

---

## H10 — Bénéficier du non-prefix cache (CacheBlend/LMCache) côté infra

**Mécanisme** : si on sert soi-même (vLLM/SGLang + LMCache), le harness doit garder des blocs stables réutilisables (pas tout fragmenter) pour que le radix/non-prefix reuse fonctionne ; côté API, c'est le fournisseur qui décide.

### Tests

**T10.1 — Structure du prompt favorable au non-prefix**
- Comptabiliser les "fragments" réutilisables (blocs identiques entre tours) : ratio `tokens_stables / tokens_total` dans le prompt.
- **Critère** : ce ratio doit être ≥ 80 % (les tool results en queue étant exclus, le reste stable).

**T10.2 — Comparaison sur serving maison**
- Bench pi sur vLLM+SGLang avec et sans LMCache/CacheBlend : hit_rate réel (mesuré côté serveur), ttft, throughput. Reproduire l'expérience dans un container dédié.
- Nombre de requêtes : ≥ 200 par condition.

**T10.3 — Sensibilité à la fragmentation**
- Ajouter un contenu qui change (timestamp) au milieu du prompt (contre-exemple) et mesurer la dégradation du hit_rate non-prefix (devrait être moins sensible qu'en préfixe strict).

**Prédiction T10.1** : ratio stable ≈ 80-95 % (le system est stable, la queue change). **Prédiction T10.2** : gain hit_rate non-prefix 63-85 % observés par Tensormesh sur agentic — reproduisible si la structure est bonne. **Prédiction T10.3** : le non-prefix est **moins** sensible à une modification au milieu (c'est son avantage) — la dégradation doit être nettement inférieure à celle du préfixe strict.

---

## Partie finale — Tableau récapitulatif des prédictions

| Hypothèse | Test clé | Prédiction (chiffrée) | Risque d'échec | Priorité |
|---|---|---|---|---|
| H1 | T1.1 (change tools) | cache_read_C ≈ 0 ; 1 miss complet par rebuild | Faible (logique prouvée dans le code) | 🔥 Haute |
| H2 | T2.1 (boucle outils) | hit_rate intra-tour > 80 % long context avec latest-user | Moyen (dépend de la taille de conversation) | Moyenne |
| H3 | T3.1 (cd) | miss total au cd ; fix élimine | Faible | Haute |
| H4 | T4.1 (sous/sur seuil) | hybride ≥ full en coût, mieux en TTFT (Δ 10-20 %) sur conversation > system | Moyen (dépend du balancement) | Haute |
| H5 | T5.1 (coût ping) | keepalive rentable seulement si P(reprise)×bénéfice > coût ping | Moyen (économie incertaine) | Moyenne |
| H6 | T6.1 (hash) | H_R ≠ H_N probable si un octet diffère | Élevé (fragile) | Haute |
| H7 | T7.1 (no tools) | hit_rate > 90 % system-seul | Faible | Basse |
| H8 | T8.1 (exactitude $) | match < 5 % | Faible | Basse |
| H9 | T9.1 (providers) | pas de breakpoint sur implicit ; 3 sur explicit | Moyen (classification) | Moyenne |
| H10 | T10.2 (serving) | hit_rate non-prefix ≫ prefix (63-85 %) | Moyen (dépend infra) | Basse (long terme) |

**Ordre de priorité recommandé pour exécuter les tests** : H1 → H6 → H3 → H4 → H2 → H7 → H5 → H8 → H9 → H10.

(Le plus simple à mesurer et le plus rentable = **H1** : l'invalidation par rebuild d'outils, testable en quelques tours, avec un gain $ immédiat si le fix est appliqué.)
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->

<!-- lu par test h3 --><!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->

<!-- lu par test h3 -->

<!-- lu par test h3 -->

<!-- lu par test h3 -->

<!-- lu par test h3 -->

<!-- lu par test h3 -->

<!-- lu par test h3 -->

<!-- lu par test h3 -->

<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->

<!-- lu par test h3 -->

<!-- lu par test h3 -->

<!-- lu par test h3 -->

<!-- lu par test h3 -->
<!-- lu par test h3 -->

<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->

<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->

<!-- lu par test h3 -->
<!-- lu par test h3 -->

<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->

<!-- lu par test h3 -->
<!-- lu par test h3 -->

<!-- lu par test h3 -->

<!-- lu par test h3 -->

<!-- lu par test h3 -->

<!-- lu par test h3 -->

<!-- lu par test h3 -->

<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->

<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->

<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->

<!-- lu par test h3 -->

<!-- lu par test h3 -->

<!-- lu par test h3 -->

<!-- lu par test h3 -->
<!-- lu par test h3 -->

<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
<!-- lu par test h3 -->
