# Phase 5 — Postulats, hypothèses formelles & protocoles : valider les optimisations P0–P2

> **Rôle** : expérimentateur méthodologiste final.
> **Accès** : toute la recherche — `.research/phase1-recherche/`, `phase2-analyse/` (gouvernance F1-F7, mécanisme), `phase3-blind/` (I-01..I-30, a1..e5), `phase4-synthese/` (01-actions P0-P2, 02-architecture cible), et surtout `docs/05-protocoles-experimentaux-et-predictions.md` (cadre anti-biais §0-§6 + résultats mesurés H1-H6, Parties 4-8).
> **Mandat** : formaliser les **postulats** non prouvés, les **hypothèses formelles** et les **protocoles d'expérience** restants pour confirmer (ou infirmer) les optimisations **P0-A, P0-B, P0-C, P1-D, P1-E, P1-F, P1-G, P2-H** proposées en phase 4.
> **Règle d'or** : les verdicts déjà mesurés ne sont pas re-discutés ; chaque optimisation est soumise au protocole anti-biais de `docs/05 §6` (scénarios réels S1-S8, A/B randomisé, sessions séparées, reposes égalisés, médiane+IQR, validation croisée 2 providers si possible, critère : gain ≥ 5 % sur ≥ 70 % des scénarios applicables, non-régression ≤ 2 %, p < 0.05).

---

## 0. Point de départ — verdicts verrouillés (sources `docs/05` Parties 4-8, phase4 §0)

| Hyp. mesurée | Verdict | Conséquence pour la phase 5 |
|---|---|---|
| **H1** rebuild system ↔ outils | **Nuancée** : le system prompt de pi **dépend du set d'outils** (snippets + guidelines, positions 2 & 4) ; changement de *nombre* d'outils = miss partiel ; changement de *set* (même nombre) = **miss total** (cr=0, sysBytes 7207 vs 6781/7481) | P0-A reste le chantier n°1 ; ce qui reste à prouver = **l'efficacité du correctif découplé**, pas l'existence du miss |
| **H2** breakpoint dernier-user | **Déjà optimale** (91.9 % hit en boucle d'outils) | Verrouiller par tests d'invariance (E9), rien d'autre |
| **H3** cwd + AGENTS hors system | **Réfutée** (anti-biais P7) : cwd en fin de system = miss ~100-200 tokens, B coûte autant ou plus | **Ne pas implémenter** (déjà écarté E-1) |
| **H4** exclude tool results | **Inapplicable** (providers en cache implicite, Claude bloqué MODEL_NOT_IN_PLAN) | Esprit relayé vers P0-B (table sémantique) + P2-H (compaction) |
| **H5** keepalive | **Non testé** (pas de sessions à pauses > TTL) | P1-E conditionné aux mesures E5 + E7b |
| **H6** resume bit-identique | **Validée** (sysHash 12f1ccdf stable, cr 2816 au resume, hit total) | Verrouiller par régression (E9), étendre à d'autres configs |
| **H7-H10** | Hors périmètre (T7 : déjà satisfait ; T8 : trivial ; T9 : alimente P0-B ; T10 : infra dédiée, priorité basse) | — |

**Leçons méthodologiques verrouillées** (`docs/05 §4.3`, §7.4) : le hash global du payload ne prédit pas le miss → **segmenter le payload** (system/tools/messages) ; `cacheRead` est la **métrique reine** ; le **1er tour est TOUJOURS un miss** (warmup obligatoire) ; égaliser les **repos** (AGENTS.md) sous peine de biais comme H3 ; un cr=0 ponctuel n'est pas un bug (non-déterminisme).

---

## 1. POSTULATS — affirmations de base non prouvées

Chaque postulat : énoncé testable, statut (vérifié par nos mesures / non vérifié), **preuve** (comment le trancher VRAI/FAUX), conséquence sur les optimisations si FAUX. Les postulats **non vérifiés** sont les maillons faibles à mesurer en priorité.

| ID | Postulat (énoncé testable) | Statut | Comment le prouver (VRAI/FAUX) | Conséquence si FAUX |
|---|---|---|---|---|
| **P1** | Le cache API = **préfixe exact bit-identique** : 1 octet modifié n'importe où dans le préfixe = invalidation de tout le suffixe | **Vérifié** (mesures H1/H3 : cr chute quand sysHash/sysBytes changent ; littérature §C1) | 2 requêtes séquentielles, insérer 1 octet au milieu du préfixe → `cached_tokens` du tour 2 = 0 | Toutes les optimisations « stabilité » perdent leur sens |
| **P2** | Le system prompt de pi intègre les **snippets + guidelines des outils** (positions 2 & 4 de `buildSystemPrompt`) → il dépend du set d'outils actifs | **Vérifié** (bundle phase2 §1.1 ; T1-refined : sysBytes 7481→6781→7207 selon les tools) | Hacher le system 2× avec des sets d'outils différents → hash différents ; même set → hash identiques | P0-A sans objet (mais il est confirmé) |
| **P3** | Changer le **set d'outils en session** déclenche `_rebuildSystemPrompt` → **miss total** si les guidelines changent (cr=0 au tour suivant) | **Vérifié** (T1-refined : mid_change read,bash→read,edit : cr=0 ; restore : re-hit) | Rejouer le protocole T1-refined avec N≥5 → cr=0 à chaque changement de set | P0-A élimine des misses existants → gain réel |
| **P4** | Le **cwd + path AGENTS.md sont en fin de system prompt** (position 9) ; changer de repo coûte un miss partiel ~100-200 tokens seulement | **Vérifié** (H3-bias : diff 2 lignes ~100 octets ; miss partiel) | Hash du segment system **hors cwd** identique entre 2 repos ; seulement la dernière ligne change | Rediriger l'effort P0-A vers le découplage réel (outils) et non vers le cwd |
| **P5** | Le **cache OpenAI n'est pas déterministe même bit-identique** : `prompt_cache_key` = indice de localité, pas garantie ; population **asynchrone** (secondes à minutes) ; `cached_tokens=0` intermittents ; éviction LRU multi-tenant | **NON VÉRIFIÉ** (rapports communauté 2025-2026, `02-cache-infra` §5 ; aucune mesure sur notre compte) | **Expérience E10** : N≥10 paires de requêtes **bit-identiques** séquentielles → taux de 2ᵉ hit, délai de prise d'effet (0-120 s), variance jour/heure | Si VRAI : P2-L (auto-toggle) indispensable, les prédictions de hit restent des distributions. Si FAUX : les hits deviennent déterministes, toutes les prédictions se resserrent |
| **P6** | **TTL long** (`PI_CACHE_RETENTION=long`, 1 h Anthropic / 24 h OpenAI via `supportsLongCacheRetention`) supprime la **majorité des misses d'idle** (pauses 5 min-1 h) | **NON VÉRIFIÉ sur notre compte** (C6 : plausible ; doc provider) | **E3/E7a** : reprise après pause D ∈ {6, 10, 30, 45} min en short vs long → cr attendu : short ≈ 0, long > 80 % du préfixe | Si FAUX : P0-C n'apporte rien (mais coût nul — reste un reflexe raisonnable) |
| **P7** | Les **lectures prolongent le TTL** (fenêtre glissante « refreshed on reuse ») sur les providers cibles | **NON VÉRIFIÉ — variable par provider** (nuance `02-mecanisme §3.2` : « les lectures ne prolongent pas forcément le TTL chez tous les providers ») | **E7b** (sous-expérience de E5) : ping de lecture à t=4 min 50 s après un tour, reprise à t=8 min → cr>0 signifie prolongation | **Si FAUX, P1-E est VIDE** : le keepalive ne rafraîchit rien et ne fait que payer des écritures. Mesurer AVANT tout développement |
| **P8** | `pi resume` reconstruit un prompt **bit-identique** (sysHash stable) → le cache (OpenAI 24 h) survit au resume | **Vérifié sur opencode-go** (H6 : hit total) ; à étendre (autres providers, changement de cwd/config entre sessions) | E9 : snapshot du prompt au dernier tour vs prompt reconstruit (diff byte-à-byte) sur 5 resumes, 2 providers | Si FAUX dans une config : P2-K (snapshot resume) devient un correctif, pas un verrouillage |
| **P9** | Les providers accessibles (opencode-go, commandcode) sont en **cache implicite** : le client ne contrôle pas la frontière → H4 littéral inapplicable | **Vérifié** (`docs/05 §8.1` : payload sans `cache_control`, cache implicite) | `onPayload` : aucun `cache_control` émis ; `cached_tokens` possible sans marqueur | Confirme P0-B (table de sémantique) comme seul levier « frontière » possible |
| **P10** | Le **1er tour d'une session est toujours un miss** (le cache n'existe pas encore) | **Vérifié** (P4.3, warmup indispensable) | cr(warmup) = 0 sur 100 % des sessions | Justifie P1-D (warmup) et interdit les comparaisons sur le tour 1 |
| **P11** | Le **tour post-compaction = miss total** (préfixe messages entièrement changé) ET le **résumé est censé être bit-stable entre compactions** (`previousSummary` persisté) sans avoir jamais été vérifié | **NON VÉRIFIÉ** (docs phase2 §1.4 : design, pas de mesure ; π compacte en masse → le résumé régénéré peut différer) | **E8** : 2 compactions successives du même historique → sysHash(system + summary v1) doit survivre à la 2ᵉ compaction | Si FAUX : P2-H commence par rendre le résumé **déterministe** (template, ordre canonique, pas de timestamp) avant d'ajuster les paramètres |
| **P12** | Sous les **seuils** (1024 tokens / 4096 Gemini), pas de cache + **régression TTFT 10-18 %** | Vérifié littérature seulement (ablation du papier, §4.1) | Réduire artificiellement le system sous 1024 → hit_rate ≈ 0 + TTFT en hausse | P0-A doit maintenir le system ≥ 2048 tokens (marge au-dessus de 1024, ~au niveau Gemini 4096) ; sinon le découplage crée une régression |

**Lecture** : les postulats P5, P6, P7, P11 sont les quatre maillons faibles qui conditionnent P2-L/P0-C/P1-E/P2-H — ils doivent être mesurés **avant la décision d'implémentation** de ces optimisations. P1-P4, P8, P9, P10 sont verrouillés et servent de fondations.

---

## 2. HYPOTHÈSES FORMELLES — P0-A .. P2-H

Format commun : **Ancrage** (source/mesure) · **Hn : IV → DV** · **Conditions contrôlées** · **Prédiction chiffrée** (médiane + intervalle + justification) · **Critère de décision** (règle `docs/05 §6.4`, jamais de jugement sur un tour isolé).

### H-A — P0-A : Découplage system ↔ outils + gel du system (le fix de F1 lui-même)

- **Ancrage** : fuite F1 (phase2 §2.1) ; T1-refined (miss total quand le set change, cr=0) ; I-03 ; architecture cible phase4-02 §2.3 (guidelines dérivées + annuaire relogés dans « Operating instructions » en tête du **1er message user bit-stable**, descriptions d'outils = doc unique, system strictement outil-indépendant et figé au tour 1, mises à jour en append).
- **IV** : construction du system prompt — **A** (actuel : snippets + guidelines d'outils dans le system) vs **B** (découplé : system outil-indépendant figé + bloc Operating instructions en tête du 1er message user + annuaire de noms triés en fin de system).
- **DV** : **métrique reine** = `cacheRead` au tour suivant un **changement de set d'outils** (les 2 cas : changement de nombre *et* changement de set à nombre égal) ; secondaires = `hit_rate_session`, `cost_total_session`, `ttft`, **qualité** (juge binaire : la tâche aboutit-elle dans les 2 conditions ?).
- **Conditions contrôlées** : mêmes repo/cwd/AGENTS.md (repos égalisés — leçon H3-bias), même provider/modèle, outils `{read,bash,edit,write}` + 2 rebuilds planifiés identiques dans A et B (retrait en fin puis changement de set au milieu), warmup 1 tour exclu des stats, scénarios **S2, S3, S4, S5, S6**, N ≥ 5 sessions par condition, ordre A/B randomisé, repos ≥ 2048 tokens en B (P12).
- **Prédiction chiffrée** :
  - Tour suivant un rebuild : **A → `cacheRead` ≈ 0** (intervalle 0-5 % du préfixe, mesuré : miss total) ; **B → `cacheRead` ≥ 70 % du préfixe chaud** (intervalle 70-95 %). *Justification* : en B le system ne contient plus rien d'outil-dépendant (P2 relogé) ; seuls le bloc Operating instructions régénéré (~200-500 tokens) et les déf. d'outils du paramètre `tools` changent — le reste du préfixe (system + historique) est rejoué tel quel.
  - `hit_rate_session` sur une session de 20 tours avec 2 rebuilds : **A ∈ [0.55, 0.80]** (2 ruptures totales) ; **B ∈ [0.85, 0.95]** (*justification* : 2 misses évités ; le hit-rate reste plafonné par les deltas incompressibles de conversation).
  - `cost_total_session` : **B ≤ A, gain médian −15 %** (intervalle −10 à −30 %). *Justification* : chaque miss total coûte ~(system+conversation 8-15k tokens) au tarif plein ; sur deepseek-flash ≈ 0.01-0.05 $/miss (extrapolation docs/05 §0.5), ×2 misses évités.
  - **Non-régression** : Δ qualité < 2 % (les guidelines déplacées restent visibles du modèle au même rang logique) ; Δ ttft des tours normaux ≤ 2 %.
- **Critère de décision** : **VALIDÉE** si et seulement si (1) **véracité** : `systemHash` stable en B sur 100 % des tours avec changement de set (le system ne bouge plus) ; (2) gain coût médian ≥ **5 %** sur ≥ **70 %** des scénarios applicables ; (3) aucune régression qualité/ttft > **2 %** ; (4) p < 0.05 (Mann-Whitney U ou bootstrap 95 % CI ≠ 0). Sinon **REJETÉE** (avec documentation du mécanisme — l'effet peut être sous le seuil de mesure).
- **Biais à éviter** : ne jamais comparer au tour de warmup (P10) ; identiques rebuilds dans A et B ; ne pas mélanger les sessions entre conditions ; vérifier que le bloc Operating instructions n'alourdit pas le tour 1 (écriture 1.25× d'un bloc supplémentaire — compté dans `cost_total_session`).

### H-B — P0-B : Table de sémantique (provider, modèle) type goose

- **Ancrage** : goose `CacheSemantics` (01-harnesses §goose) ; H9 (T9 offline) ; `docs/05 §8` (implicite/explicite mesuré par provider) ; flags `compat.*` existants (phase2 §1.2-1.3) ; anti-overcaching (P6).
- **IV** : stratégie de cache — **A** (flags épars actuels) vs **B** (table complète `ExplicitBreakpoints | ImplicitStrict | ImplicitTolerant | Uncached`, fallback `ImplicitStrict` ; émission de `cache_control` **si et seulement si** ExplicitBreakpoints ; `retention:none` sur Uncached ; pas de `prompt_cache_key` hors OpenAI-compatible).
- **DV** : (1) présence/absence de `cache_control` dans la requête finale **conforme à la vérité terrain** (offline, `onPayload`) ; (2) `cache_write_tokens` facturés sur providers « sans cache » ; (3) erreurs 400 (marqueurs rejetés) ; (4) `cacheRead` des sessions sur providers courants (non-régression).
- **Conditions contrôlées** : **test offline** (hook `onPayload`, 0 appel réseau) sur la liste canonique — Anthropic, OpenAI completions, OpenAI responses, Gemini, OpenRouter `anthropic/*`, OpenRouter défaut, Bedrock Claude, minimax, moonshot, together, groq, snowflake (12 entrées) ; vérité terrain = docs providers.
- **Prédiction chiffrée** :
  - **T9.1** : conformité du marquage **100 %** (0 entrée mal classée sur la liste canonique) ; erreur de classification attendue **< 5 %** sur les modèles mixtes OpenRouter (fallback safe `ImplicitStrict`, sans perte de cache utile).
  - **T9.2** : sur les entrants `Uncached` : **0 `cache_control` émis ET 0 `cache_write` facturé** ; économie mesurée **0.5-2 % du coût** des sessions concernées (*justification* : les writes sont facturés 1.25× chez Anthropic, ~coût de write partout ; la part des sessions sur providers exotiques est faible).
  - **Non-régression** : sur opencode-go / commandcode (implicites courants) : Δ `cacheRead` **≤ 2 %** par rapport à l'actuel.
- **Critère de décision** : **VALIDÉE** si T9.1 = 100 % conforme offline ET T9.2 (aucun write sur uncached, mesuré sur ≥ 2 sessions réelles si un provider uncached est accessible ; sinon vérifié sur le seul provider exotique disponible) ET non-régression ≤ 2 % sur les providers courants. Le gain $ principal est la **robustesse** (pas de marqueur mal émis → pas de 400, pas de write-taxe), pas un gain de hit.
- **Biais à éviter** : ne jamais envoyer de payload marqué sur un provider qui le rejetterait (inspection offline d'abord) ; les modèles Claude bloqués par le plan (MODEL_NOT_IN_PLAN) → **offline seulement** (le `onPayload` s'exécute avant le réseau, coût 0) ; ne pas co-exécuter avec H-A (les deux manipulent les breakpoints → sessions dédiées).

### H-C — P0-C : TTL long par défaut

- **Ancrage** : I-12/c1 ; C6 (régime moyen : misses d'idle 5 min-1 h = cause n°1 `CacheMiss{idleMs}`) ; `getCacheControl` + `supportsLongCacheRetention` (phase2 §1.2) ; P6 (postulat non vérifié).
- **IV** : `PI_CACHE_RETENTION` — **A** = `short` (défaut actuel) vs **B** = `long` (Anthropic `ttl:"1h"` / OpenAI `prompt_cache_retention:"24h"`), uniquement quand `supportsLongCacheRetention`.
- **DV** : `cacheRead` du **tour de reprise** après une pause D ; `cost_total_session` (avec 2 pauses simulées) ; absence d'erreurs de payload (`ttl:"1h"` accepté).
- **Conditions contrôlées** : scénario **S7 (pauses)**, D ∈ {6, 10, 30, 45} min ; N ≥ 5 cycles par D ; sessions dédiées par condition ; warmup ; **E7a** (calibrage du TTL effectif) exécuté avant le verdict.
- **Prédiction chiffrée** :
  - Tour de reprise : **A → `cacheRead` ≈ 0-10 % du préfixe** (TTL court 5 min expiré) ; **B → ≥ 80 %** (intervalle 80-95 % du préfixe ; TTL long 1 h encore vivant, les deltas de conversation restent en input). *Justification* : P6 — la fenêtre long couvre les pauses < 1 h, soit le régime « café/réunion » ; mesure directe du TTL effectif via E7a.
  - `cost_total_session` avec 2 pauses de 15 min : **B ≤ A de −15 à −40 %** (*justification* : 2 misses de ~8-15k tokens évités × delta prix read/input ; sur un modèle Sonnet-class ≈ 0.01-0.05 $/miss, docs/05 §2.2).
  - Non-régression : Δ coût des tours normaux **≤ 2 %** ; aucun rejet `ttl:"1h"` (0 erreur sur 10 tours).
- **Critère de décision** : **VALIDÉE** si (1) reprise long > 80 % de cr pour D ∈ [30, 45] min sur ≥ 70 % des sessions testées, (2) 0 erreur de payload, (3) non-régression ≤ 2 %. P0-C est le **quick win** à implémenter en premier si validée (effort F, risque F) — documenter le résidu de données provider (gouvernance §3.1).
- **Biais à éviter** : le TTL « court » peut être glissant > 5 min → calibrer avec E7a avant de conclure ; ne jamais exécuter A et B en parallèle sur le même provider (contamination du cache de préfixe) ; repos égalisés ; temps d'attente réel (voir E3).

### H-D — P1-D : Warmup du 1er appel

- **Ancrage** : P10 (1er tour = miss systématique) ; I-10a ; OpenAI population asynchrone (P5) ; gate T-P1 phase4.
- **IV** : présence d'un **ping warmup avant le 1er appel réel** — **A** (aucun) vs **B** (préfixe system+tools+1er message, `max_tokens≈1`, sans persistance dans la conversation).
- **DV** : `cached_tokens` du 1er appel réel (métrique reine) ; `cost_total_session` (sessions de 3 et 5 tours) ; `ttft` du 1er appel réel ; `prefix_diff` (le warmup ne doit rien modifier).
- **Conditions contrôlées** : scénarios **S1, S2, S5** (sessions courte/moyenne, AGENTS.md) ; N ≥ 5 sessions par condition ; isolation des sessions ; ratio de warmup plafonné (pas de warmup pour les sessions < 2 tours probables).
- **Prédiction chiffrée** :
  - 1er appel réel : **A → cr = 0** (100 % des cas, mesuré P10) ; **B → cr ≥ 60 %** du préfixe (intervalle 60-90 %). *Justification* : la population OpenAI est asynchrone (secondes à minutes, P5) — le warmup « écrit » ; le 1er appel réel dans les secondes suivantes peut encore rater une partie → E10 calibre la décote ; sur les providers fiables l'attente est nulle.
  - `cost_total_session` : à 3 tours, **parité** (intervalle −2 à +5 %) ; à ≥ 5 tours, **gain médian ≥ 5 %** (intervalle 5-15 %). *Justification* : le warmup coûte 1 write (1.25× du préfixe) au tour 0, le tour 1 réel relit à 0.1-0.5× au lieu de payer le préfixe plein — la parité est atteinte dès ~2-3 tours ; au-delà, chaque tour économise le delta (input plein − read) du préfixe.
  - Non-régression : `prefix_diff` = 0 (le ping n'ajoute rien), Δ ttft du tour 1 réel ≤ 0 % (le préfill est déjà calculé → attendu plus court).
- **Critère de décision** : **VALIDÉE** si cr(B, tour 1) > 0 sur ≥ 70 % des sessions ET gain coût médian ≥ 5 % sur les sessions ≥ 5 tours ET `prefix_diff` = 0 sur toutes les sessions. Sinon rejetée (l'asynchronisme P5 peut rendre le warmup inutile sur un provider donné — réévaluer provider par provider).
- **Biais à éviter** : le coût du warmup **doit** être inclus dans `cost_total_session` (sinon gain factice) ; ne pas rejouer le warmup quand la session s'arrête à 1 tour ; sessions séparées A/B randomisées ; temps d'exécution court (30 min).

### H-E — P1-E : Keepalive probabiliste opt-in

- **Ancrage** : H5 non testé (docs/05) ; arXiv 2607.19214 (règle `P(reprise) × bénéfice > coût des pings`) ; aider `warm_cache` ; **P7 (postulat critique : les lectures prolongent-elles le TTL ?)**.
- **IV** : pendant une pause D, envoi d'un **ping silencieux** (même préfixe + `max_tokens≈1`) à TTL/2 — **A** (aucun ping) vs **B** (ping à D/2) — sur sessions « vivantes en attente » (dernier échange récent, processus en cours).
- **DV** : `cacheRead` du tour de reprise (reine) ; `cost_cumulé` sur [pause + reprise] **pings inclus** ; `ttft` de reprise ; `prefix_diff` avant/après ping = 0 ; non-visibilité du ping.
- **Conditions contrôlées** : scénario **S7** ; D ∈ {6, 15} min × N ≥ 5 cycles par D dans un premier temps (40 min en option) ; prérequis **E7b** : vérifier provider par provider que **la lecture prolonge le TTL** ; profil « reprise probable » pour le critère de rentabilité ; contrôle avec `cacheRetention:"none"` si nécessaire.
- **Prédiction chiffrée** :
  - Tour de reprise : **A → cr ≈ 0-10 %** (D > TTL court) ; **B → cr 60-95 %** du préfixe *si P7 est vrai* (sinon B ≈ A et l'hypothèse est morte).
  - `cost_cumulé` : **B ≤ A seulement si P(reprise) ≥ 60-80 %** ; économie **0.005-0.02 $/reprise** (system 4k, docs/05 H5 : miss ≈ 0.012 $, ping ≈ 0.015 $ max si réécrit — un ping *lecture pure* avant expiration est ~gratuit) ; `ttft` reprise **−30 à −70 %** (préfill supprimé, cohérent avec H4/paper).
  - Non-régression : `prefix_diff` = 0, aucune réponse visible (max_tokens=1, température 0), aucun write inattendu sur le préfixe lors du ping.
- **Critère de décision** : **VALIDÉE** si (1) **E7b positif** (la lecture prolonge le TTL chez le provider testé), (2) coût cumulé médian B ≤ A −5 % sur le scénario « pauses prévisibles avec reprise probable », (3) aucun effet de bord. **Sinon REJETÉE et P1-E reste OFF par défaut** (c'est la décision acceptée dans tous les cas — le keepalive n'est jamais activé sans mesure).
- **Biais à éviter** : compter le coût réel des pings (nombre × coût unitaire, pas zéro) ; ne pas pinger les sessions actives (inutile, boucle déjà à 91.9 % H2) ; l'expérience est **dominée par le temps d'attente** (6-8 h) → paralléliser E7b (autre provider) pendant les fenêtres ; ne jamais partager les sessions avec E3/E4 (les pings écrivent du cache).

### H-F — P1-F : Suffixe minimal (troncature à la source + purge des tool results périmés)

- **Ancrage** : I-07 ; opencode purge les tool outputs anciens (01-harnesses) ; anti-overcaching P6 ; esprit H4 relayé (cache implicite → pas de breakpoint à bouger, mais **réduire le suffixe relu** reste possible) ; phase2 faiblesse n°2.
- **IV** : traitement des tool results — **A** (texte intégral) vs **B** (troncature tête/queue + « N lignes omises », plein conservé dans l'état local ; suppression/compaction des tool results obsolètes **derrière le dernier breakpoint** — jamais avant).
- **DV** : **métrique reine** = tokens relus par tour (`input` + `cacheRead` rejoués) ; secondaires = `hit_rate_session` (**doit rester stable** : le préfixe avant le point de divergence n'est pas touché), `cost_total_session`, `ttft`, **qualité** = juge binaire standardisé de réussite de tâche.
- **Conditions contrôlées** : scénarios **S3 (long feature, sorties bash/read longues)** et **S4 (boucle d'outils)** ; N ≥ 5 sessions par condition ; mêmes tâches avec sorties **standardisées de même taille** dans les 2 conditions ; warmup ; randomisation A/B.
- **Prédiction chiffrée** :
  - Tokens relus par tour : **B ≤ A de −30 % en médiane** (intervalle −25 à −45 %). *Justification* : les tool results représentent 60-80 % de la croissance inter-tours dans les sessions riches en outils (mesure H2 : deltas de 75-922 tokens/tour dont la majorité sont les résultats) ; la troncature agit sur ce flux ; la purge retire les résultats jamais relus.
  - `hit_rate_session` : **inchangé ±1 %** (*justification* : le préfixe stable system+conversation reste entier ; on ne touche que la queue relue).
  - Qualité : ≥ 90 % de réussite dans les 2 conditions, Δ ≤ 2 % (troncature agressive = plafond 6000 chars/outil + marqueur « omis », l'état local garde le plein pour les retries).
  - `ttft` : attendu neutre ou légèrement négatif (moins de préfill à calculer) — mesurer, pas présumer.
- **Critère de décision** : **VALIDÉE** si tokens relus −30 %+ (médiane) sur ≥ 70 % des scénarios applicables ET hit_rate ≥ baseline −2 % ET Δ qualité ≤ 2 %. Le gain s'applique à **tous** les profils (levier multiplicatif L3, phase3-blind).
- **Biais à éviter** : ne **jamais** tronquer avant le dernier breakpoint (casserait le préfixe — le pire des cas) ; standardiser les tâches (même contenu de sorties) sinon le Δ de tokens mesure le hasard ; juge qualité en **aveugle** (sans savoir la condition) ; ne pas mélanger avec E1 (qui change le préfixe).

### H-G — P1-G : Ordonnancement anti-miss (grouper/avancer les invalidations inévitables)

- **Ancrage** : I-06 ; Claude Code diffère les changements de CLAUDE.md au prochain cycle (01-harnesses) ; coût d'un miss ∝ longueur de la conversation (02-blind-infra §remarque 5) ; P5 (stabilité prime sur fraîcheur).
- **IV** : moment d'application des changements de clé (skills, outils MCP additifs, contextFiles) — **A** (immédiat, à chaque événement) vs **B** (différé + **groupé** à la prochaine frontière = fin de tour/cycle, avec notification UX).
- **DV** : `miss_count` = nombre de tours avec cr < 50 % du cache attendu (reine) ; `cost_total_session` ; UX (le différé est-il notifié et bien appliqué au tour suivant ?).
- **Conditions contrôlées** : session longue artificielle de **30 tours** avec 3 changements planifiés (ajout de skill tour 5, ajout d'outil MCP tour 12, édition contextFile tour 18) ; N ≥ 5 sessions par condition ; mêmes changements dans A et B ; scénarios **S3, S6** (compatibles sessions longues/resume).
- **Prédiction chiffrée** :
  - `miss_count` : **A ≈ 3** (un miss total à chaque changement, cr chute au tour suivant) vs **B ≈ 1** (les 3 changements appliqués à la 1ᵉʳᵉ frontière suivante → 1 seul miss groupé). *Justification* : le coût d'un miss = préfixe entier au moment où il se produit ; regrouper 3 changements en une frontière = 1 miss Facturé au lieu de 3.
  - `cost_total_session` : **B ≤ A de −10 à −25 %** (*justification* : 2 des 3 misses économisés ; le 3ᵉ (souvent le plus tard, donc le plus cher — conversation longue) est déplacé tôt → coût réduit d'autant).
  - Non-régression fonctionnelle : le skill/outil/context modifié **est actif au tour suivant la frontière dans 100 % des cas** (sinon le différé casse le flux utilisateur).
- **Critère de décision** : **VALIDÉE** si miss_count B ≤ A/2 (≥ 2× moins de ruptures) ET coût −5 %+ ET application garantie au prochain cycle (0 échec d'application). 
- **Biais à éviter** : différences de timing identiques entre A et B (sinon l'effet mesure le timing, pas le regroupement) ; vérifier que le différé ne bloque pas une tâche critique (ex. skill requis immédiatement — cas limite à documenter) ; sessions dédiées (le changement de clé contamine tout le contexte).

### H-H — P2-H : Compaction douce (moins de misses + résumé stable en tête)

- **Ancrage** : I-08/e1-e2 ; phase2 §1.4 (compaction de masse actuelle : reserve 16384, keepRecent 20000) ; P11 (résumé bit-stable non vérifié) ; esprit H4 (remplacer les vieux tool results par des résumés raccourcit le suffixe relu, applicable en cache implicite) ; docs/05 §8.3.
- **IV** : stratégie de compaction — **A** (actuelle : déclenchement sur réserve, résumé régénéré, suppression de masse) vs **B** (douce : **résumé incrémental appendé** au bloc résumé stable (le préfixe [system + summary v1] survit), réserve ajustée au coût du préfixe, purge des vieux tool results **derrière la frontière** avant compaction).
- **DV** : fréquence des compactions (reine) ; `miss_count` (tours cr=0 hors tour 1) ; `waste` cumulé (`computeCacheWaste`) ; **bit-stabilité inter-compactions** (sysHash du préfixe avant 2ᵉ compaction) ; qualité ; ttft.
- **Conditions contrôlées** : **session artificielle de 200 tours** reproduisant S3 (tâches réelles mixtes + sorties d'outils) ; N ≥ 3 sessions par condition (le volume est le coût principal) ; mêmes paramètres de fenêtre dans A et B.
- **Prédiction chiffrée** :
  - Fréquence : **compactions B ≤ A/2** (*justification* : compaction douce + purge préalable → le budget de tokens est mieux utilisé, la fenêtre est franchie moins souvent).
  - `miss_count` / `waste` cumulé : **B ≤ A de −20 %** (intervalle −20 à −40 %). *Justification* : chaque compaction de masse = un miss du **préfixe maximal** (le point le plus cher de la session) ; réduire de moitié la fréquence + garder un socle [system + summary v1] rejouable = économie directe ; la purge derrière la frontière raccourcit aussi le suffixe de chaque tour (effet H-F).
  - **Bit-stabilité** : `hash(system + summary v1)` **identique entre la 1ᵉʳᵉ et la 2ᵉ compaction** (le résumé v1 n'est pas réécrit, seul un delta s'append) ; *sinon* l'implémentation B ne fait pas ce qu'elle prétend.
  - Non-régression : Δ qualité ≤ 2 % ; Δ ttft post-compaction ≤ 5 % (le nouveau préfixe doit rester ≥ 1024 tokens, P12).
- **Critère de décision** : **VALIDÉE** si bit-stabilité vérifiée sur ≥ 90 % des paires de compactions ET waste/miss −20 %+ ET non-régression ≤ 2 %. 
- **Biais à éviter** : la session artificielle doit être un vrai usage (pas des « réponds OK » — la compaction ne se déclencherait jamais) ; les paramètres A doivent être ceux du bundle réel (pas un mock) ; la qualité se juge sur les tâches réelles du mix ; sessions dédiées très longues → exécuter sur le modèle le moins cher (deepseek-flash) et hors des fenêtres des autres expériences.

---

## 3. PROTOCOLES D'EXÉCUTION — cadre anti-biais appliqué

### 3.1 Règles transversales (toutes les expériences, `docs/05 §0.1-0.4, §6`)

1. **Métriques** : `cacheRead` reine, `cost_turn`/`cost_total_session`, `ttft` si mesurable (timestamps des événements provider/`message_end` — sinon via proxy ; documenter si indisponible), `miss_count`, `hit_rate_session` agrégé (jamais un tour choisi).
2. **Design** : A/B **inter-sessions** (jamais le même session-id entre conditions), **randomisation de l'ordre** A-B / B-A (seed par session), warmup identique exclu des stats, repos égalisés (AGENTS.md), écart > TTL entre conditions ou `cacheRetention:"none"` sur le contrôle, N ≥ 5 sessions par (scénario × condition), médiane + IQR, test Mann-Whitney U ou bootstrap 95 % CI.
3. **Rejets de mesure** (à documenter, jamais dans les stats) : rate-limit, erreurs réseau, > 2 tentatives par tour, réponses tronquées par `max_tokens`, cr=0 ponctuel isolé sans explication (non-déterminisme P5 — un seul point ne fait pas un verdict).
4. **Validation croisée** : chaque expérience tourne sur **opencode-go/deepseek-v4-flash** (provider principal, déjà qualifié) et, si quota disponible, sur **commandcode/deepseek** (ou gpt-5.6-sol). Verdicts divergents = effet provider → documenter, ne pas généraliser.
5. **Marche à suivre** : pilote 1 session par (scénario × condition) → calibration + vérification de l'instrumentation (`cache-trace.ts` : hash segmenté system/tools/messages) → campagne N ≥ 5 → analyse → verdict. Infrastructure : bac à sable `.pi-test`, `scripts/exp-runner.sh`, extensions `cache-trace.ts` (+ une extension par condition B, pattern `h3-condition-b.ts`).

### 3.2 Matrice de contamination (les 8 nouvelles expériences)

| Expérience | Change quoi | Contamine | Parades |
|---|---|---|---|
| **E0** (repro) | rien (vérifications) | rien | passif, prérequis |
| **E1** (P0-A) | **contenu du préfixe** (system découplé) | E6, E7, E8, E9 (tout ce qui repose sur le préfixe standard — comparaisons inter-sessions invalides) | sessions dédiées ; jamais partager ; exécuter E1 avant les mesures « structure » |
| **E2** (P0-B) | émission des marqueurs | E1 (même mécanisme breakpoints) | **offline** (onPayload, 0 $) + 2 sessions réelles dédiées |
| **E3** (P0-C) | rétention/TTL global | toutes (le TTL long élargit les fenêtres) | sessions dédiées ; E3 et E5 ne partagent jamais de fenêtre temporelle avec une autre mesure du même provider |
| **E4** (P1-D) | écrit le cache au tour 0 | E3, E5 (écritures) | sessions dédiées ; ne pas évaluer dans la même fenêtre qu'un test de pause |
| **E5** (P1-E) | pings (écritures/lectures de cache) | **toutes** (les pings modifient l'usage mesuré) | sessions isolées, contrôle `retention:none`, fenêtres d'attente exploitées sur **un autre provider** |
| **E6** (P1-F) | contenu de la queue (tool results) | E1 (si le préfixe bouge) | surfaces de test standard ; ne pas toucher au préfixe ; pas de coexistence avec E1 |
| **E7** (P1-G) | timing des changements de clé | toutes (le contexte change) | sessions longues dédiées (30 tours) |
| **E8** (P2-H) | masse du contexte | toutes | sessions très longues dédiées, sur un provider distinct |
| **E9** (verrouillage) | rien (passif/offline) | aucune | peut tourner en parallèle de tout |
| **E10** (P5) | rien (lecture seule) | aucune (attention à l'asynchronisme) | parallèle, léger |

### 3.3 Protocoles détaillés

#### E0 — Repro & verrouillage du banc (prérequis, 0.05 $)
- **But** : garantir que chaque expérience part de métriques fiables et d'un environnement reproductible.
- **Étapes** : (1) hash `buildSystemPrompt` 2× à froid → identique (déterminisme) ; (2) warmup : cr=0 au tour 1 sur 3 sessions ; (3) instrumenter `cache-trace.ts` pour segmenter system/tools/messages (leçon P4.3) ; (4) pilote de 1 session par (scénario × condition) des expériences à venir pour calibrer coûts.
- **Biais à éviter** : vérifier que les pièges de payload (ordre JSON, clés inutiles) n'introduisent pas de bruit ; documenter les versions (pi, provider, modèle).

#### E1 — P0-A découplage system↔outils (‑0.60-1.20 $, ~2-3 h)
- **Scénarios** : S2, S3, S4, S5, S6 (rebuild + project context + resume).
- **N** : ≥ 5 sessions × 2 conditions × 5 scénarios ≈ 50 sessions × ~6 tours ; pilote avant.
- **Métriques** : cr au tour suivant rebuild (reine), hit_rate_session, cost_total_session, ttft, juge qualité.
- **Étapes** : implementation de la condition B dans le bac à sable (bloc Operating instructions dans le 1er message user — pattern `h3-condition-b.ts` étendu — + system gelé) ; campagne A/B randomisée avec les 2 types de rebuild (nombre ≠ set) ; E7a/E7b non nécessaires ici mais le timing des fenêtres doit éviter E3/E5.
- **Biais spécifiques** : repos égalisés impérativement (leçon H3) ; rebuilds identiques entre A et B ; le bloc Operating instructions alourdit le tour 1 → compté dans cost_total_session ; vérification du seuil P12 (system ≥ 2048 tokens) après le découplage.

#### E2 — P0-B table de sémantique (offline 0 $ + 0.10-0.20 $)
- **Scénarios** : aucun (offline) + 2 sessions réelles sur un provider « uncached » si accessible.
- **N** : liste canonique de 12 (provider, modèle) → 12 inspections de payload ; puis 2 sessions de validation.
- **Métriques** : conformité du marquage (véracité), cache_write facturé (efficacité), erreurs 400 (sécurité).
- **Biais spécifiques** : ne rien envoyer au réseau avant l'inspection ; modèles Claude bloqués → offline ; ne pas co-exécuter avec E1.

#### E3 — P0-C TTL long (0.20-0.40 $, ~6-8 h de temps d'attente)
- **Scénarios** : S7 (pauses).
- **N** : D ∈ {6, 10, 30, 45} min × N ≥ 5 cycles par condition.
- **Métriques** : cr du tour de reprise (reine), cost_total_session, erreurs de payload (ttl:"1h" accepté).
- **Sous-expérience E7a** : mesurer le **TTL effectif** en short (fenêtre vraie avant miss) pour le calibrage — 3 paires de reprises échelonnées (4, 5, 6, 7 min).
- **Biais spécifiques** : un seul test de pause par fenêtre temporelle par provider ; exécuter pendant les autres expériences sur un autre provider pour amortir l'attente ; vérifier `supportsLongCacheRetention` réellement actif dans le payload (`ttl:"1h"` présent).

#### E4 — P1-D warmup (0.20-0.40 $, ~30-45 min)
- **Scénarios** : S1, S2, S5 (session courte/moyenne).
- **N** : ≥ 5 sessions × 2 conditions × 3 scénarios (sessions de 3 et 5 tours).
- **Métriques** : cached_tokens du 1er appel réel (reine), cost_total_session, ttft, prefix_diff.
- **Biais spécifiques** : coût du warmup inclus dans le total ; ne pas warmup quand P(session > 2 tours) est faible ; vérifier que le ping n'est pas persisté (pas de « faux » message assistant).

#### E5 — P1-E keepalive (0.20-0.40 $ + 4-8 h d'attente)
- **Scénarios** : S7 ; profil « reprise probable » (dernier échange récent).
- **N** : D ∈ {6, 15} min × N ≥ 5 cycles × 2 conditions (ping à TTL/2 vs rien) ; D=40 optionnelle.
- **Métriques** : cr du tour de reprise (reine), cost cumulé pings inclus, ttft reprise, prefix_diff = 0, réponse invisible.
- **Sous-expérience E7b (PRÉALABLE)** : 3 cycles « tour → ping lecture à t=4 min 50 s → reprise à t=8 min » : si cr reprise > 0, les lectures prolongent le TTL (P7 VRAI) → continuer ; sinon REJETER P1-E sans campagne.
- **Biais spécifiques** : le ping est un vrai coût — le compter ; jamais de ping sur session active ; fenêtres d'attente utilisées pour E3/E7b/E10 sur d'autres providers ; contrôle `retention:none` si le cache résiduel brouille la mesure.

#### E6 — P1-F suffixe minimal (0.50-1.00 $, ~2 h)
- **Scénarios** : S3 (long feature), S4 (boucle) — sorties longues volontaires standardisées.
- **N** : ≥ 5 sessions × 2 conditions × 2 scénarios.
- **Métriques** : tokens relus/tour (reine), hit_rate_session (invariance), cost_total_session, ttft, juge qualité en aveugle.
- **Biais spécifiques** : mêmes sorties dans A et B (taille de fixture fixe) ; jamais tronquer avant le dernier breakpoint ; juge binaire sans connaissance de la condition ; ne pas exécuter dans une fenêtre E1/E5.

#### E7 — P1-G anti-miss (0.40-0.80 $, ~2-3 h)
- **Scénarios** : S3, S6 (sessions longues, interactions avec cycles).
- **N** : ≥ 5 sessions × 2 conditions × 30 tours avec 3 changements planifiés.
- **Métriques** : miss_count (reine), cost_total_session, application effective des changements au tour suivant.
- **Biais spécifiques** : timing identique des 3 changements dans A et B ; vérifier l'UX (notification du différé) ; le différé ne doit pas bloquer une commande critique (cas limite documenté).

#### E8 — P2-H compaction douce (0.40-0.80 $, ~3-4 h)
- **Scénarios** : S3 reproduit × 200 tours (vraies tâches).
- **N** : ≥ 3 sessions par condition (coût volume).
- **Métriques** : fréquence des compactions (reine), miss_count, waste cumulé, bit-stabilité du résumé (sysHash), qualité, ttft, seuil post-compaction (P12).
- **Biais spécifiques** : la condition A = paramètres réels du bundle (réserve 16384, keepRecent 20000) ; usage réel (pas « réponds OK ») sinon pas de compaction ; sessions très longues sur le provider le moins cher, en dehors des fenêtres E3/E5.

#### E9 — Verrouillage + observabilité (P2-I lint, P2-J doc hors system, P2-K clé, P2-L SLO) (0 $ + passif)
- **But** : transformer les optimisations « déjà bonnes » en garde-fous : tests prefix-invariance en CI (le placement des cache_control ne modifie pas le hash), audit sessionId/headers (d1-d2), test snapshot resume (d4, régression H6), agrégats M1-M10 + 2 semaines de télémétrie passive (T-P6) pour calibrer l'auto-toggle.
- **N** : 5 resumes × 2 providers pour d4 ; passif ensuite.
- **Biais** : aucun réseau supplémentaire ; peut tourner en parallèle de tout.

#### E10 — Postulat P5 : non-déterminisme du cache OpenAI (0.05-0.15 $, ~30 min)
- **But** : trancher VRAI/FAUX le postulat qui porte P2-L (auto-toggle) et la lecture de toutes les autres mesures.
- **Protocole** : N ≥ 10 paires de requêtes **bit-identical** (même préfixe, même `prompt_cache_key`, back-to-back puis avec délais 1 s / 5 s / 30 s / 120 s) ; mesurer `cached_tokens` de la 2ᵉ ; faire 2 sessions à des heures différentes (population/éviction).
- **Prédiction** : taux de 2ᵉ hit ≥ 50 % seulement après population (secondes-minutes) ; variance inter-délais observable.
- **Biais à éviter** : ne pas modifier un seul octet entre les paires (sinon on teste P1, pas P5) ; enregistrer la région/route si l'API l'expose.

---

## 4. PRIORISATION & BUDGET

### 4.1 Ordre d'exécution recommandé (impact / coût / temps)

| Rang | Expérience | Optimisation validée | Coût $ est. | Temps | Pourquoi là |
|---|---|---|---|---|---|
| 1 | **E0** (repro) | prérequis | 0.05 | 30 min | fiabilité de tout le reste |
| 2 | **E2** (P0-B) | table de sémantique | 0-0.20 | 1 h | offline, 0 $, calibre P0-B avant campagne |
| 3 | **E3** (P0-C) | TTL long par défaut | 0.20-0.40 | 6-8 h d'attente | quick win (effort F) ; lancer tôt, amortir l'attente |
| 4 | **E10** (P5) | postulat non-déterminisme OpenAI | 0.05-0.15 | 30 min | tranche P2-L et la lecture des autres mesures ; parallèle |
| 5 | **E4** (P1-D) | warmup | 0.20-0.40 | 45 min | court, gain immédiat si validée |
| 6 | **E1** (P0-A) | découplage system↔outils | 0.60-1.20 | 2-3 h | chantier structurant (F1) — le plus gros gain potentiel |
| 7 | **E7** (P1-G) | ordonnancement anti-miss | 0.40-0.80 | 2-3 h | complète le système de P0-A (gouvernance des changements) |
| 8 | **E6** (P1-F) | suffixe minimal | 0.50-1.00 | 2 h | levier multiplicatif toutes sessions |
| 9 | **E5** (P1-E) | keepalive | 0.20-0.40 | 4-8 h d'attente | le plus lent ; **après E7b (préalable)** et E3 (calibrage TTL) |
| 10 | **E8** (P2-H) | compaction douce | 0.40-0.80 | 3-4 h | sessions très longues, à isoler |
| 11 | **E9** (verrouillage) | lint, clé, SLO (P2-I..L) | 0 + passif | continu | en parallèle ; SLO sur 2 semaines |
| | **Total** | — | **~2.6-5.6 $** | **~1.5-2 jours** (dont ~12-16 h d'attente E3/E5) | sur deepseek-flash (≈ 3-5× moins cher que Sonnet : les fourchettes docs/05 §2.2 sont des bornes hautes) |

### 4.2 Règle de décision de la phase (synthèse)

1. **Implémenter** P0-A (si H-A validée), P0-B (si H-B validée), P0-C (si H-C validée — implémentation immédiate dès validation, effort F), P1-D (si H-D), P1-F (si H-F), P1-G (si H-G), P2-H (si H-H).
2. **Never by default** : P1-E (keepalive) — conditionné à E7b positif + seuil de rentabilité mesuré (P(reprise) ≥ 60-80 %).
3. **Postulats critiques à trancher en premier** : P5 (E10), P6 (E3), P7 (E7b), P11 (E8) — leur valeur pilote P2-L, P0-C, P1-E, P2-H.
4. **Alerte « test bateau »** (`docs/05 §6.4`) : si la baseline A ne gagne sur **aucun** scénario, le test est biaisé → signaler et refaire, ne jamais conclure.
5. **Après chaque verdict** : réintégrer dans la gouvernance (M1-M10, phase4-02 §5) le levier validé ; un échec = documentation du mécanisme (aussi utile qu'une validation).

### 4.3 Budget consolidé

- Campagne complète (E0-E9, sans E8 en option) : **2.6-4.8 $** — dominée par E1 (0.60-1.20 $), E6 (0.50-1.00 $), E7 (0.40-0.80 $), E8 (0.40-0.80 $).
- **E8 facultative** si le budget se resserre : la compaction est le levier le plus tardif (P2-H) ; elle peut attendre les gains P0-A/P0-C.
- **E10** (0.05-0.15 $) est le meilleur rapport info/coût : elle conditionne l'interprétation de toutes les autres mesures (à faire avant E1-E8, en parallèle de E3).
- Le tout dans le bac à sable `.pi-test` (isolation contractuelle `docs/05 §3.4`) : jamais de sessions réelles, jamais d'affichage des creds.

---

*Fin du document phase 5 — 12 postulats, 8 hypothèses formelles (H-A..H-H), 11 protocoles (E0..E10) avec matrice de contamination, priorisation et budget. Chaque verdict applique le protocole anti-biais `docs/05 §6` et alimente la gouvernance phase 4.*

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Livrable complet rédigé et écrit au chemin imposé (phase5-hypotheses/01-postulats-experiences.md) : (1) 12 postulats testables VRAI/FAUX avec preuve et conséquence si FAUX, dont 4 marqués NON VÉRIFIÉ (P5 non-déterminisme OpenAI, P6 TTL long, P7 lecture-prolonge-TTL, P11 bit-stabilité du résumé) ; (2) 8 hypothèses formelles H-A..H-H au format IV → DV, conditions contrôlées, prédiction chiffrée avec intervalle + justification, critère de décision (règle docs/05 §6.4) ; (3) 11 protocoles E0..E10 appliquant le protocole anti-biais (scénarios S1-S8, N ≥ 5, randomisation A/B, sessions séparées, repos égalisés, validation croisée 2 providers, métriques cacheRead reine + coût + TTFT si possible), biais spécifiques par expérience + matrice de contamination ; (4) priorisation impact/coût (E0 → E2 → E3 → E10 → E4 → E1 → E7 → E6 → E5 → E8 → E9) et budget total ~2.6-5.6 $ / ~1.5-2 jours. Les verdicts mesurés docs/05 (H1 nuancée, H2 optimale, H3 réfutée, H4 inapplicable, H5 non testé, H6 validée) sont posés en tête et jamais re-discutés ; les optimisations écartées en phase 4 (cwd hors system, exclude tool results) ne sont pas réintroduites."
    }
  ],
  "changedFiles": [
    "/home/anhydrite/.pi/agent/sessions/--home-anhydrite-Documents-beta_labo-recherche-cache-hits--/subagent-artifacts/outputs/52ba480d-42fd-4f94-ad02-bc75bc25eaf5/.research/phase5-hypotheses/01-postulats-experiences.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "read docs/05-protocoles-experimentaux-et-predictions.md (intégral, 821 lignes, Parties 0-8), .research/phase4-synthese/01-actions.md + 02-architecture.md, .research/phase2-analyse/01-mecanisme.md + 02-gouvernance-pi.md, docs/03-conclusions-hypotheses-optimisation.md, .pi-test/results/CAMPAIGN-REPORT.md, .pi-test/extensions/cache-trace.ts + h3-condition-b.ts, scripts/exp-runner.sh + run-h3-bias.sh, .research/phase3-blind (extraits)",
      "result": "passed",
      "summary": "Toutes les sources phase 2-4, les mesures H1-H6 et l'infrastructure réelle du bac à sable (.pi-test, extensions, scripts) lues intégralement avant rédaction"
    }
  ],
  "validationOutput": [
    "Fichier créé au chemin de sortie exact. Structure markdown validée : §0 verdicts verrouillés H1-H6 + leçons méthodologiques ; §1 12 postulats (table : énoncé/statut/preuve/conséquence si FAUX) ; §2 8 hypothèses formelles H-A..H-H complètes (ancrage, IV→DV, conditions, prédiction chiffrée avec intervalle et justification, critère de décision) ; §3 11 protocoles avec règles transversales, matrice de contamination et biais spécifiques par expérience ; §4 priorisation rangée par impact/coût + budget en $ et en temps ; rapport d'acceptation final."
  ],
  "residualRisks": [
    "P5 (non-déterminisme OpenAI) reste NON VÉRIFIÉ : toute prédiction de hit sur ce provider est une distribution ; E10 (premier rang) est conçu pour le trancher — ne pas implémenter P2-L avant",
    "P7 (les lectures prolongent-elles le TTL ?) n'est pas mesuré : P1-E (keepalive) est explicitement conditionné à E7b — hors mesure positive, aucune implémentation",
    "Les providers Claude (explicites, seuls testables pour H4 littéral) sont bloqués par MODEL_NOT_IN_PLAN : P0-B est validée offline sur ces entrants, l'observation réelle est limitée aux providers implicites accessibles",
    "Les gains chiffrés (−15 % P0-A, −30 % P1-F, −20 % P2-H) sont des estimations extrapolées des mesures existantes (T1-refined, H2, docs/05 §2.2) ; ils ne valent que si le critère statistique docs/05 §6.4 est respecté (médiane ≥ 5 %, ≥ 70 % scénarios, p < 0.05)",
    "Le TTFT n'est pas instrumenté dans cache-trace.ts actuel : les mesures TTFT (E1, E4, E6, E8) nécessitent un ajout d'instrumentation (timestamps provider) — sinon documenté comme indisponible",
    "La compaction douce (P2-H) reste la moins contrainte : P11 (bit-stabilité du résumé) n'a jamais été vérifié — si faux, l'implémentation B doit d'abord rendre le résumé déterministe"
  ],
  "noStagedFiles": true,
  "diffSummary": "Rédaction du livrable méthodologique phase 5 (01-postulats-experiences.md) : 12 postulats (8 vérifiés, 4 à mesurer), 8 hypothèses formelles couvrant P0-A/B/C, P1-D/E/F/G, P2-H, 11 protocoles exécutables dans le bac à sable .pi-test avec matrice de contamination, priorisation et budget (~2.6-5.6 $)",
  "reviewFindings": [
    "no blockers: le document est autonome, cohérent avec les verdicts mesurés docs/05 (aucune idée réfutée réintroduite : H3 cwd et H4 exclude restent écartées), chaque hypothèse suit le format exigé (IV→DV, conditions, prédiction chiffrée + justification, critère de décision), et chaque optimisation phase 4 est reliée à sa gate de test"
  ],
  "manualNotes": "Points d'attention pour le parent : (1) l'ordre E2 → E3 → E10 avant E1 maximise l'information par dollar — E10 (0.05-0.15 $) conditionne la lecture de toutes les autres mesures (non-déterminisme P5) ; (2) P1-E keepalive ne doit JAMAIS être développé avant E7b (lectures prolongent-elles le TTL ?) ; (3) l'implémentation de la condition B de P0-A réutilise le pattern existant h3-condition-b.ts (extension before_provider_request + contexte) qu'il faudra étendre aux guidelines/annuaire ; (4) le TTFT nécessite un enrichissement de cache-trace.ts (timestamps des événements provider) avant les campagnes qui l'utilisent."
}
```