# Recherche & Expérimentation — Cache Hits dans les Harnesses d'Agents de Code (pi)

> **Objet** : optimiser le taux de cache-hit (prompt caching) côté API pour le harness d'agent de codage **pi** (earendil-works). Mesures sur **2 providers** (commandcode, opencode-go — deepseek-v4-flash), validation croisée, protocoles **anti-biais**.
> **Date** : septembre 2026 · **Auteur** : Anhydrite · **Coût total cumulé** : ~0.6-0.8 $ (sous le budget 2.6-5.6 $ estimé)

---

## 1 · Protocole expérimental

### 1.1 Métriques objectives (usage API, jamais de ressenti)

| Métrique | Définition |
|---|---|
| `cr` (cache_read_tok) | tokens **relus depuis le cache** au tour N (préfixe matché) — *métrique reine* |
| `cw` (cache_write_tok) | tokens **écrits en cache** (overhead) |
| `in` (input_tok) | tokens d'entrée facturés **plein tarif** (le delta non-caché) |
| `hit_rate(N)` | `cr / (cr + in + cw)` |
| `cost_turn(N)` | $ du tour = `in×P_in + cr×P_cr + cw×P_cw + out×P_out` |
| `ttft(N)` | latence avant le 1er token (streaming) |
| `sysHash` / `sysBytes` | hash / taille du system prompt — **détecte un rebuild** (le hash global du payload, lui, ne prédit pas le miss) |

### 1.2 Design standard & conditions de contrôle

- **Schéma** : ABBA intra-session (recommandé) ou A/B inter-sessions (sessions strictement séparées par condition).
- **Contrôles obligatoires** : même modèle/provider (fait partie de la clé de cache) · même repo/cwd/AGENTS.md · **warm-up** de 1 tour avant toute mesure · écart > TTL entre 2 conditions (ou `cacheRetention:"none"` pour vider le cache) · N ≥ 5 sessions ou ≥ 10 tours · **médiane + IQR** (jamais la moyenne seule) · **seuil de cache** : ≥ 1024 tokens (OpenAI/Anthropic) ou 4096 (Gemini), sinon test invalide.
- **3 preuves exigées** : (1) **véracité** = l'optimisation fait ce qu'elle prétend au niveau des octets (inspection du préfixe / payload) ; (2) **efficacité** = gain ≥ 5 % sur la métrique cible (médiane) ; (3) **non-régression** = ≤ 2 % sur les métriques annexes. Validée si les 3 ; sinon rejetée **en documentant pourquoi**.
- **Anti-contamination** : chaque protocole s'exécute sur des **sessions dédiées** — ceux qui manipulent le contenu du préfixe (rebuild, cwd, resume) ne partagent jamais une session ; les tests de breakpoints se font sur sessions sans rebuild ; les tests de sémantique (T9) sont **offline** (inspection de payload, 0 $). Ordre sûr : offline → T1 → T4 → T2 → T3 → T5 → **T6 (resume, dernier)** → T10 (infra dédiée).

### 1.3 Les 10 protocoles (H1-H10)

| # | Hypothèse testée | Design / mesure clé |
|---|---|---|
| **H1** | Le rebuild du system prompt (changement d'outils/ressources) invalide le cache | Fork de session, retirer/remettre des outils, mesurer cr au tour suivant + **contrôle actif** (mêmes outils) |
| **H2** | Le breakpoint « dernier message user » est optimal en boucle d'outils | Tour avec ≥ 3 tool calls enchaînés, hit_rate **intra-tour** ; outils figés, 2 tailles de conversation |
| **H3** | Sortir cwd + AGENTS.md du system prompt (les mettre au 1er message user) | Protocole **anti-biais multi-scénarios** (S1, S2, S5, S8), repos égalisés, A/B randomisé, 2 providers |
| **H4** | Exclure les tool results du cache (stratégie hybride « Don't Break the Cache ») | Conversation courte vs longue (> system) ; mesurer cw sur la queue + ttft |
| **H5** | Keepalive / pings silencieux pendant les pauses > TTL | Pauses D = {3, 6, 15, 40} min ; comparer coût cumulé ping + reprise ; seuil de rentabilité P(reprise) |
| **H6** | Le `pi resume` (même session-id) reconstruit un prompt **bit-identique** | Hash du prompt sérialisé au tour N vs au resume ; cr du 1er tour après resume |
| **H7** | Le breakpoint system doit exister même avec 0 tool | Session à 0 tool + vérification payload ; cap ≤ 4 breakpoints |
| **H8** | Exposer le cache-waste en $ (diagnostic) | Exactitude < 5 % vs calcul manuel ; détection de cause par miss provoqué |
| **H9** | Table de sémantique par (provider, modèle) — breakpoints seulement si nécessaires | **Offline** : conformité cache_control sur un tableau de providers (explicite/implicite/uncached) |
| **H10** | Structurer le prompt pour le non-prefix cache (CacheBlend/LMCache) | Ratio tokens stables/total + bench serving maison (infra dédiée) |

### 1.4 Protocole anti-biais multi-scénarios (pour les verdicts robustes)

Un test « bateau » favorise une technique par construction. **Un résultat n'est crédible que s'il se confirme sur ≥ 2 providers et des scénarios d'usage réels.**

**Corpus de scénarios** : S1 lecture courte (5-6 tours) · S2 édition moyenne (8-12) · S3 feature longue (15-25) · S4 boucle d'outils (6-10) · S5 contexte projet AGENTS.md (8-12) · S6 resume (8-12) · S7 pauses > TTL (6-8) · S8 multi-repo (8-12).

**Règles** : ① ordre A/B **randomisé** entre sessions (neutralise le biais d'ordre) ; ② **sessions séparées** par condition (le cache d'une condition ne doit pas alimenter l'autre) ; ③ warm-up identique ; ④ **repos égalisés** (même AGENTS.md partout — sinon on mélange 2 variables) ; ⑤ écart > TTL entre conditions.

**Métriques écologiques** : `cost_total_session` · `hit_rate_session` = Σcr / (Σcr + Σin) · `miss_count` · `time_to_completion` · `ttft` médian. Jamais un tour choisi.

**Critère de décision** : **VALIDÉE** ssi gain positif sur ≥ 70 % des scénarios applicables **et** médiane ≥ 5 % **et** aucune régression > 2 % **et** p < 0.05. **REJETÉE** si gain < 50 % des scénarios ou une régression > 5 %. Alerte « test bateau » si la baseline ne gagne jamais.

### 1.5 Environnement d'exécution

- **Bac à sable isolé** `.pi-test/` (config + sessions + résultats séparés) — le harness de prod n'est jamais touché ; seul `auth.json` (creds, jamais affiché) y est copié. Setup : `./scripts/setup-test-env.sh [check|env]`.
- **Drivers** : `run-t1.sh` (rebuild), `run-campaign.sh` (T1-refined/T3/T6), `run-h2.sh` (boucle d'outils), `run-h3-bias.sh` (anti-biais A/B), `run-h3-cross-provider.sh` (validation croisée), `run-e3.sh` (TTL), `run-e4.sh` (warmup), `exp-runner.sh` (instrumentation segmentée).
- Détail complet des protocoles : `docs/05-protocoles-experimentaux-et-predictions.md` · cas de tests : `docs/04-...` · rapports détaillés : `.research/resultats/` et `results/`.

---

## 2 · Expériences & données

### Campagne H — mesures directes (opencode-go/deepseek-v4-flash, ~70 tours ≈ 0.05-0.10 $)

| Exp | Question | Design | Données observées |
|---|---|---|---|
| **T1** | Rebuild en **fin** d'outils (H1) | Retirer edit/write, N=5 | cr **2816 → 2048-2304** (miss **partiel** : seule la portion retirée re-part, ~512-768 tok) ; restore → 2816 ; coût ×3.5 (pas ×10) |
| **T1-refined** | Rebuild au **milieu** des outils | read,bash → read,edit | sysBytes 7481→**7207** (les guidelines dépendent des outils) → **cr=0 MISS TOTAL** ; le nombre ET le set d'outils changent le system prompt |
| **T2 / H2** | Breakpoint « dernier user » en boucle d'outils | 16 appels LLM intra-tour | **hit global 91.9 %** (cr 87808 / in 7695) ; cr croît avec la conversation (2816→8704) = préfixe entier rejoué, seuls les deltas passent en input (75-900 tok) |
| **T3** | cwd dans le system prompt (changement de repo) | repoA → repoB → repoA | cr **2816 → 1792** (miss partiel ~700 tok) ; re-hit 2816 au retour ; sysBytes +20 en repoB → preuve que le cwd est en **fin** de system |
| **T6** | Resume même session-id (H6) | 4 tours + `pi resume` | **sysHash constant 12f1ccdf** → prompt reconstruit **bit-identique** → **cr=2816 hit total** au resume |

### H3-BIAS — protocole anti-biais + validation croisée (2 campagnes, 48 traces, ~0.3 $)

| Exp | Question | Design | Données observées |
|---|---|---|---|
| **H3-bias** | cwd hors system : A (cwd dans system) vs B (injecté au 1er message user) | 4 scénarios réels (S1 lecture, S2 édition, S5 AGENTS.md, S8 multi-repo) × 2 providers × N=2-3/cond, repos **égalisés**, A/B randomisé | Δ coût tour « cd » : S1 cc **+1 %** / og **−13 %** · S2 cc **+65 %** / og **−11 %** · S5 cc **−15 %** / og **+18 %** · S8 cc **−23 %** / og **+14 %** → **aucun scénario n'a le même signe sur les 2 providers** = bruit inter-sessions (~0.0001 $/tour) |
| **Découverte méthodo** | Le T3 initial était-il biaisé ? | Égaliser les repos (même AGENTS.md) | OUI : le « miss » de T3 venait du **contexte projet entier différent**, pas du cwd ; après égalisation le diff repoA↔repoB = **2 lignes (~100 octets)** |
| **H4** | Exclure les tool results du cache | Payload réel (hook before_provider_request, offline) sur 8 (provider, modèle) | **Inapplicable** : les 3 modèles accessibles sont en **cache implicite** (aucun cache_control, le client ne contrôle pas la frontière) ; les seuls modèles à breakpoints (claude) → **403 MODEL_NOT_IN_PLAN** |

### E0-E10 — validation des optimisations P0-P2 (opencode-go / commandcode)

| Exp | Question | Design | Données observées |
|---|---|---|---|
| **E0** | Banc reproductible + déterminisme | Instrumentation **segmentée** (sys/tools/msgs hashs séparés) | sysHash unique sur 20+ tours (12f1ccdf) ; **découverte** : le system de pi est **partagé entre sessions** → **cr=2560 dès le 1er tour** de sessions fraîches → « le 1er tour est toujours un miss » est **FAUX** ici (nuance P10) |
| **E1 + E1-RPC** | P0-A : découplage system↔outils (system figé + guidelines relogées au 1er message user) | Extension e1-condition-b, puis process RPC continu 4 tours, rebuild au tour 3, A/B | Mécanisme ✅ : sysHash **12f1ccdf figé** malgré le changement d'outils. RPC : tour 4 — A (baseline) sysHash changé **cr=0 (miss)** vs B (découplé) sysHash figé **cr=2304 (hit)** → coût du tour ×5 économisé |
| **Synthèse honnête** | Le gain P0-A est-il proportionnel au préfixe ? | Rebuild avec **gros préfixe** (~11k tokens appendés) | **NON, gain BORNÉ** : le rebuild ne casse que le **system natif** (~1.9-2.5k tok), l'appendé reste en cache → baseline garde **97.8 % de hit** même après rebuild. Gain réel P0-A = **~500-2000 tok/rebuild**. Petit préfixe : hit 0 % → 87.4 % |
| **E2** | P0-B : table de sémantique (provider, modèle) | Inspection payload de 8 (provider, modèle) | 6/6 implicites : aucun cache_control (conforme) ; **2/2 explicites (claude via commandcode) : cache_control sur le system OUI, sur le dernier tool NON** ← **GAP** (le pattern pi pose cc sur `tools[length-1]`) |
| **E3** | P0-C : TTL long vs court | Pauses 60/120/240/**330 s** (5.5 min > TTL 5 min Anthropic) | **cr=2816 constant** → le cache opencode-go **survit > 5 min** → P0-C **neutralisée** sur ce provider |
| **E4** | P1-D : warmup du 1er appel | 3 sessions/cond, randomisé | **cr=2816 (hit max) dès le 1er tour dans les 2 conditions** (system partagé = déjà caché) → warmup **inutile et coûteux** (écriture 1.25× sans bénéfice) |
| **E10** | P5 : non-déterminisme du cache | 6 requêtes bit-identiques, même session | req1 cr=0 (écriture normale) ; **req2-6 cr=2816 constant** → **pas de non-déterminisme** sur opencode-go (fiable pour les mesures) |
| E5-E9 | Keepalive, suffixe minimal, anti-miss, compaction | — | **Non exécutés** (4-8 h / 2 h de temps requis) — priorité basse, documentés comme suite |

### Post-analyse (non exécuté — leviers restants identifiés)

| Levier | Estimation (analyse H2 + E1-RPC) | Priorité |
|---|---|---|
| **Troncature des tool results** (tête + queue + marqueur, plein gardé en état local) | **−30-45 %** des tokens relus/tour (le poste dominant du delta : 75-922 tok/tour mesurés) ; hit_rate inchangé ±1 % | 🔥 1 — à tester |
| Descriptions d'outils courtes | −300-500 tok/tour (footprint fixe relu à chaque tour) | 2 |
| Compaction de l'historique (sessions très longues) | Évite la croissance linéaire du préfixe relu | 3 |
| P0-A découplage (conditionnel) | ~500-1900 tok/rebuild **si** rebuilds fréquents (skills/MCP) — mesurer d'abord | 4 |

---

## 3 · Synthèse des conclusions

| Groupe | Conclusion | Preuve chiffrée clé | Action pour pi |
|---|---|---|---|
| **H1 / P0-A** (frozen system / découplage system↔outils) | **Nuancée et bornée** : miss total seulement quand le **system change** (rebuild au milieu / set différent) ; miss partiel si seule la fin des tools change ; sur gros préfixe le rebuild ne casse que le system natif | T1-refined cr=0 · E1-RPC cr 0→2304 · gros préfixe : 97.8 % hit conservé → gain réel ~500-2000 tok/rebuild | Implémenter (refonte de `_rebuildSystemPrompt`) **seulement si les rebuilds sont fréquents** sur l'usage réel ; sinon priorité basse — valeur surtout structurelle (préfixe stable) |
| **H2 / T2** (breakpoint dernier user) | **Déjà optimale** | hit 91.9 % en boucle d'outils (16 appels) | Rien à faire |
| **H3** (cwd hors system) | **RÉFUTÉE** — le design actuel (cwd en fin de system) est quasi optimal ; le T3 initial qui la soutenait était **biaisé** | Δ = bruit : signes inversés entre commandcode et opencode-go sur les 4 scénarios ; coût réel d'un changement de repo ≈ 100-200 tok | Ne pas implémenter |
| **H4** (exclure tool results) | **INAPPLICABLE** ici — providers accessibles en **cache implicite** (frontière non contrôlable côté client) ; modèles à breakpoints bloqués | Payload réel : 0 cache_control sur deepseek/gpt ; claude 403 MODEL_NOT_IN_PLAN | Re-tester quand un modèle Anthropic / à breakpoints sera accessible |
| **H5** (keepalive) | Non testé (requiert pauses > 5 min) ; théoriquement rentable **seulement si P(reprise) ≥ 60-80 %** | seuil : coût ping ~0.015 $ vs miss ~0.012 $ + TTFT | Flag opt-in, jamais par défaut |
| **H6** (resume bit-identique) | **Validée** | sysHash 12f1ccdf identique session + resume, cr=2816 hit total | Rien (déjà bon) — réserve : non-déterminisme OpenAI documenté si modèles GPT directs |
| H7-H10 | Hors périmètre rapide / non testés (H7 satisfait par le code : breakpoint system posé sans tools) | — | H8 (métrique $), H9 (table sémantique → cf. P0-B), H10 (non-prefix) = défensif / long terme |
| **Postulat P10** (« 1er tour = toujours un miss ») | **FAUX pour pi** : le system est partagé entre sessions → déjà en cache au 1er tour | cr=2560 dès le tour 1 de sessions fraîches (E0, E4) | Conséquence : **P1-D warmup rejeté** (inutile, coûteux) |
| **P0-B** (table de sémantique) | **Nécessaire — GAP réel** : sur modèles explicites le dernier tool n'est pas marqué | E2 : claude via commandcode → cc system ✅ / dernier tool ❌ | Corriger le marquage du dernier tool (bridge commandcode ou compat) — mais modèles concernés bloqués par le plan |
| **P0-C** (TTL long par défaut) | **Neutralisée sur opencode-go** (cache survit > 5.5 min) | E3 : cr=2816 après 330 s de pause | Ne pas activer par défaut sur ce provider ; pertinent seulement providers Anthropic-stricts |
| **P5** (non-déterminisme cache) | **Stable sur opencode-go** → banc fiable pour toutes les mesures | E10 : cr constant sur 5 requêtes identiques | — |
| **Micro-leviers** | Les seules opportunités restantes sont des **petits gains cumulés** | troncature tool results : −30-45 % tokens relus/tour ; descriptions : −300-500 tok/tour | Tester la **troncature des tool results** en premier (effort faible, levier multiplicatif) |
| **Méthodologie** | ① Le hit_rate % ne veut **rien dire sans la taille du préfixe** (tous les tests à petit préfixe surestimaient les rebuilds) · ② le hash global du payload ne prédit pas le miss (segmenter system/tools/messages) · ③ le protocole anti-biais a **évité un faux positif** (H3) | révision proportionnalité · E0 · H3-bias | Tester désormais **toujours avec un contexte projet réaliste (gros préfixe)** |

**Verdict global** : sur les providers testés (cache implicite), pi est **déjà quasi optimal** sur les leviers « populaires » (breakpoint user, resume, cwd en fin de system). Les implémentations défendables se limitent à **P0-B** (gap de marquage), **P0-A conditionnel** (si rebuilds fréquents) et le chantier à venir : **troncature des tool results** (le seul gain significatif restant, −30-45 % des tokens relus/tour).

*Références détaillées : `docs/05` (protocoles + résultats par campagne) · `results/` (rapports T/H) · `.research/resultats/` (rapports E0-E10, synthèse honnête, révision proportionnalité, micro-leviers) · `.research/RAPPORT-CONSOLIDE.md` (recherche multi-agents 5 phases, convergence chercheurs ↔ blind).*
