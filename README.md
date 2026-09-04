# Recherche Cache-Hits dans pi — ce que valent vraiment les optimisations

> **Question** : le cache API fonctionne-t-il déjà bien dans pi (earendil-works), et quelles optimisations valent la peine d'être implémentées ?
> **Réponse courte** : le cache marche déjà très bien (le hit-rate atteint **~91 %** : 91 % des tokens d'entrée sont relus depuis le cache au lieu d'être re-payés). Une session de dev coûte **~0.1 à 3 cents**. La plupart des optimisations « connues » ne font rien gagner (bruit ou poste déjà gratuit). **Le seul levier qui peut vraiment réduire la facture : couper les résultats d'outils trop longs** (−30-45 % du poste résultats d'outils, soit ~12-18 % du coût d'une session d'édition).
> **Mesures** : 2 114 tours sur 126 sessions réelles (traces `results/`), providers commandcode + opencode-go, modèle deepseek-v4-flash · **Date** : septembre 2026 · Détail complet : `.research/resultats/BASELINE-QUANTITATIVE.md`

---

## 1 · De quoi on part (la référence)

### 1.1 Les prix réels (déduits des traces)

| | Prix | En clair |
|---|---|---|
| Lire depuis le cache | 0.007 $/M tokens | **31× moins cher** que du nouveau |
| Envoyer du texte **nouveau** (jamais vu) | 0.22 $/M tokens | c'est **ça** qui coûte |
| Réponse du modèle | 0.66 $/M tokens | — |

### 1.2 Combien coûte une session pi réelle ?

| Usage réel | Exemple | Tours | **Coût total** |
|---|---|---|---|
| Lecture | lire 3 fichiers, synthétiser | ~19 | **0.33 cent** |
| Travail avec AGENTS.md | contexte projet | ~14 | **0.73 cent** |
| Changer de repo en session | multi-repo | ~12 | **0.11 cent** |
| **Édition (tâche type)** | **lire, éditer, vérifier** | **~33** | **≈ 2-3 cents** |

→ **Une tâche de dev complète ≈ 2-3 cents. Un tour ≈ 0.02-0.07 cent.** C'est l'ordre de grandeur à garder en tête pour juger chaque optimisation.
→ Exemple chiffré (une session d'édition type) : relecture en cache 680k tokens = **0.48 cent** · input nouveau (résultats d'outils) = **1.68 cent** · réponse = 0.45 cent.

### 1.3 Où part l'argent d'une session ? (la clé pour comprendre tout le reste)

| Poste de dépense | Part du coût | En clair |
|---|---|---|
| **Texte nouveau envoyé** (résultats d'outils, nouveaux messages) | **64 %** | **c'est ici qu'il y a de l'argent à économiser** |
| Relecture du contexte depuis le cache | 18 % | déjà presque gratuit |
| Réponse du modèle | 17 % | incompressible |
| Le system prompt entier relu à chaque tour | **2 %** | **quasi gratuit** |

→ **Conséquence n°1** : les optimisations qui réorganisent le « system prompt » (geler, déplacer le cwd, etc.) jouent sur **2 % du coût**. Même parfaites, elles ne peuvent pas économiser grand-chose.
→ **Conséquence n°2** : les résultats d'outils sont payés **plein tarif** quand ils sont créés (64 % du coût). Les **tronquer** est le seul levier à fort potentiel.

---

## 2 · Comparaison simple : chaque optimisation testée, avant / après, en chiffres

> Lecture : chaque ligne compare le **coût actuel de pi** vs le **coût avec l'optimisation**, sur la même situation. Verdict en langage clair.

| # | Optimisation testée | Situation mesurée | Coût actuel | Coût avec l'opti | Gain réel | Verdict |
|---|---|---|---|---|---|---|
| **1** | **Geler le system prompt** quand les outils changent (P0-A) | le tour juste après un changement d'outils | 0.02 cent (tour normal) | 0.05 cent (le cache casse, tout est re-payé) | **0.03 cent économisé par rebuild** (le tour cassé coûte ×15-25 un tour normal, mais reste minuscule) | ⚠️ **Utile seulement si des dizaines de rebuilds par session** (outils/MCP dynamiques). Inutile sur un usage normal. |
| **2** | **Sortir le cwd du system prompt** (H3) | changement de repo en session | 0.11-2.9 cents/session | identique ± bruit | **0.00** (les 2 versions coûtent pareil ; les écarts changent de signe entre providers = bruit) | ❌ **Inutile** — le cwd est déjà bien placé (en fin de system, le gros du préfixe reste caché) |
| **3** | **Warmup** : envoyer un appel bidon avant de commencer (P1-D) | 1er tour d'une session | déjà 0.02 cent (le system est déjà en cache, partagé entre sessions) | coûte 1 tour d'écriture en plus | **négatif** | ❌ **Inutile, voire nuisible** (on paie un appel pour rien) |
| **4** | **TTL long** : garder le cache plus longtemps (P0-C) | pause de 5.5 min entre 2 tours | le cache **survit déjà** (0 perdu) | identique | **0.00** sur ce provider | ❌ **Inutile ici** (le cache survit > 5 min). Peut servir sur des providers stricts non testés. |
| **5** | **Breakpoint « dernier message »** (H2) | boucle d'outils intra-tour | **91.9 %** de hit | — | déjà optimal | ✅ **Rien à faire**, le comportement actuel est le bon |
| **6** | **Reprise de session** bit-identique (H6) | `pi resume` | le cache **survit** à la reprise (hit total) | — | déjà bon | ✅ **Rien à faire** |
| **7** | **Tronquer les résultats d'outils** trop longs (micro-levier n°1) — *non encore testé* | résultats d'outils = ~70 % de l'input nouveau (le poste payé plein tarif) | — | **estimation** : −30-45 % sur ce poste | **~0.35-0.5 cent par session d'édition** (~12-18 % de la facture) | 🔥 **Seul vrai levier restant — à tester** (protocole prêt, ~0.5-1 $) |
| 8 | Descriptions d'outils plus courtes (micro-levier n°2) | footprint fixe des outils | relu en cache | −300-500 tok/tour… **en cache** | **≈ 0.01 cent/session** | ❌ **Déclassé par la baseline** (c'était annoncé « −300-500 tok », mais ces tokens sont relus en cache = presque gratuits) |
| 9 | Compaction de l'historique (micro-levier n°3) | très longues sessions | historique relu en cache | préfixe plus court | faible (agit sur la relecture, déjà bon marché) | ⚠️ Utile seulement si le contexte approche la limite de la fenêtre du modèle |

**En une phrase** : les optimisations « de préfixe » (1, 2, 3, 4, 8) agissent sur des tokens **relus en cache = déjà presque gratuits** ; la seule qui agit sur des tokens **payés plein tarif** est la **troncature des résultats d'outils** (7).

---

## 3 · Protocole expérimental (comment ces chiffres ont été obtenus)

### 3.1 Mesures (toutes issues de l'usage API, jamais du ressenti)

| Mesure | Définition | Utile pour |
|---|---|---|
| `cr` | tokens **relus depuis le cache** à chaque tour | savoir si le cache matche |
| `in` | tokens **nouveaux payés plein tarif** | **c'est le vrai coût** |
| coût du tour | $ = `in×0.22 + cr×0.007 + out×0.66` (deepseek-v4-flash) | comparer les situations |
| hit-rate | `cr / (cr + in)` = part du contexte rejouée depuis le cache | qualité globale du cache |
| hash du system prompt | empreinte du texte système | détecter quand pi le reconstruit |

### 3.2 Règles pour qu'un test soit crédible (anti-biais)

1. **Même modèle, même repo, même AGENTS.md** entre les 2 conditions comparées (sinon on compare 2 choses à la fois).
2. **1 tour d'échauffement** avant de mesurer (le cache doit être écrit).
3. **≥ 5 sessions** par condition, comparer les **médianes** (pas les moyennes).
4. **Sessions séparées** entre conditions A et B (le cache de l'une ne doit pas servir à l'autre).
5. **Scénarios d'usage réels** (lire, éditer, AGENTS.md, multi-repo) — pas des prompts « réponds OK ».
6. **2 providers** : un résultat n'est vrai que s'il a le même signe sur les deux.
7. **Toujours tester avec un gros contexte projet** (le vrai usage) — les tests à petit préfixe surestiment l'effet des rebuilds.
8. Critère de verdict : gain ≥ 5 % (médiane) sur ≥ 70 % des scénarios, aucune régression > 2 % → sinon rejeté **en expliquant pourquoi**.

### 3.3 Environnement
Bac à sable isolé `.pi-test/` (le harness de prod n'est jamais touché). Drivers : `scripts/run-t1.sh`, `run-campaign.sh`, `run-h2.sh`, `run-h3-bias.sh`, `run-e3.sh`, `run-e4.sh`. Détail des protocoles : `docs/05-protocoles-experimentaux-et-predictions.md`.

---

## 4 · Les expériences et leurs données (pour vérifier)

### 4.1 Hit-rate réel mesuré par expérience (qualité du cache)

| Expérience | Ce qui a été testé | Hit-rate | Tokens relus/tour | Tokens neufs/tour |
|---|---|---|---|---|
| **Usage réel** (h3bias, 96 sessions) | scénarios S1/S2/S5/S8 | **90.9-91.3 %** | 12 000-13 600 | 1 250-1 300 |
| **H2** | boucle d'outils | 91.9 % | 5 500 | 480 |
| **T6** | reprise de session | 96.7 % | 2 800 | 96 |
| **T1** | rebuild en fin d'outils | 81.5 % | 2 300 | 530 |
| **T3** | changement de repo (cwd) | 87.0 % | 2 500 | 370 |
| **T1-refined** | rebuild au milieu des outils | 70.1 % | 1 700 | 730 |

→ En usage réel, **pi est déjà à ~91 % de hit**. Les bancs qui « cassent » (rebuilds) descendent à 70-81 %, mais sur des situations artificielles rares en pratique.

### 4.2 Les 10 hypothèses testées (H1-H10) et leur sort

| Hypothèse | Question | Verdict |
|---|---|---|
| H1 | Geler le system prompt quand les outils changent | ⚠️ Nuancé : le rebuild casse le cache, mais ne coûte que ~0.03 cent/occurrence |
| H2 | Le « dernier message user » est-il le bon point de cache ? | ✅ Déjà optimal (91.9 %) |
| H3 | Sortir le cwd du system prompt | ❌ Réfutée (aucun gain mesuré, test initial biaisé) |
| H4 | Exclure les résultats d'outils du cache | ❌ Inapplicable : les providers utilisés sont en « cache implicite », le client ne contrôle pas la frontière |
| H5 | Keepalive (pings pendant les pauses) | ⏳ Non testé (pauses > 5 min requises) ; rentable seulement si reprise très probable |
| H6 | Le resume reconstruit-il un prompt identique ? | ✅ Validé (le cache survit à la reprise) |
| H7 | Breakpoint système présent sans outils | ✅ Déjà satisfait par le code |
| H8 | Afficher le coût gaspillé en $ | Hors périmètre (métrique de confort) |
| H9 | Table de sémantique par provider | ⚠️ GAP réel trouvé (voir E2 ci-dessous) |
| H10 | Structurer pour le cache non-préfixe | Hors périmètre (infra maison) |

### 4.3 Expériences E0-E10 (validation des optimisations P0-P2)

| Exp | Ce qui a été testé | Découverte chiffrée |
|---|---|---|
| E0 | Fiabilité du banc | Le system prompt de pi est **partagé entre sessions** → déjà en cache au 1er tour (d'où l'inutilité du warmup) |
| E1 + RPC | Découplage system ↔ outils | Mécanisme validé : le system peut rester figé malgré un changement d'outils (hit 2304 au lieu de miss 0). Gain : ~0.03 cent/rebuild |
| Synthèse honnête | Le gain est-il proportionnel au préfixe ? | **Non, borné** : un rebuild ne casse que le system natif (~500-2000 tokens), pas tout le contexte → les estimations précédentes étaient surestimées |
| E2 | Table de sémantique (provider → stratégie) | **GAP** : sur les modèles « explicites » (claude), le dernier outil n'a pas de marqueur de cache → à corriger, mais modèles bloqués par le plan |
| E3 | TTL long vs court | Cache **survit 5.5 min** → rien à gagner sur ce provider |
| E4 | Warmup | **Inutile** : déjà en cache au 1er tour, le warmup ne fait que coûter un appel |
| E10 | Le cache est-il stable/non-déterministe ? | **Stable** sur opencode-go → les mesures sont fiables |
| E5-E9 | Keepalive, suffixe minimal, anti-miss, compaction | Non exécutés (longs), priorité basse |

### 4.4 La comparaison A/B la plus complète (H3-bias) — pourquoi c'est du bruit

Coût total d'une session, cwd dans le system (A) vs au 1er message (B) :

| Scénario | commandcode A / B | opencode-go A / B | Verdict |
|---|---|---|---|
| Lecture | 0.30 c / 0.33 c (+13 %) | 0.36 c / 0.30 c (−16 %) | signes opposés → bruit |
| Édition | 2.61 c / 3.00 c (+15 %) | 2.91 c / 2.64 c (−9 %) | signes opposés → bruit |
| AGENTS.md | 0.80 c / 0.74 c (−7 %) | 0.73 c / 0.71 c (−3 %) | ~ rien |
| Multi-repo | 0.11 c / 0.08 c (−24 %) | 0.12 c / 0.10 c (−13 %) | ~ 0.02-0.03 cent = bruit |

→ **Aucun scénario n'a le même signe sur les 2 providers** : les « gains » de B sont annulés par des « pertes » ailleurs. Sans la validation croisée, le « −24 % » de commandcode/multi-repo aurait pu sembler prometteur — c'est un artefact. **Leçon : ne jamais croire un test sur 1 seul provider.**

---

## 5 · Conclusions finales

| # | Conclusion | En clair | Action |
|---|---|---|---|
| 1 | **Le cache fonctionne déjà très bien** | hit-rate ~91 % (la plupart des tokens d'entrée sont relus en cache, 31× moins cher que du nouveau) | rien |
| 2 | **Le coût réel est minuscule** | une session ≈ 0.1-3 cents | garder cet ordre de grandeur avant de chasser chaque centime |
| 3 | **L'argent est dans les résultats d'outils, pas dans le system prompt** | 64 % du coût = texte nouveau (dont ~70 % de résultats d'outils) ; le system relu = 2 % | **tester la troncature des résultats d'outils** (−30-45 % du poste, ~0.35-0.5 cent/session) |
| 4 | Les optimisations « de préfixe » sont sans objet | geler le system (0.03 c/rebuild), sortir le cwd (0), TTL long (0), warmup (négatif) | ne pas implémenter (sauf P0-A si usage très dynamique en outils) |
| 5 | Deux comportements actuels sont déjà optimaux | breakpoint dernier message (91.9 %), resume bit-identique (hit conservé) | documenter, ne pas toucher |
| 6 | Le seul vrai bug trouvé | sur modèles explicites (claude), le dernier outil n'est pas marqué pour le cache | corriger quand un accès claude sera disponible (bloqué par le plan aujourd'hui) |
| 7 | **Méthode** | un résultat doit se confirmer sur 2 providers avec gros contexte, sinon c'est du bruit | appliquer pour la suite |

**Prochaine étape concrète** : implémenter et mesurer la **troncature des résultats d'outils** (extension + driver, ~0.5-1 $) — c'est la seule optimisation qui agit sur le poste qui coûte vraiment.

---

*Fichiers : `README.md` (synthèse) · `.research/resultats/BASELINE-QUANTITATIVE.md` (chiffres détaillés) · `.research/resultats/RAPPORT-EXPERIENCES.md` (E0-E10) · `docs/05-protocoles-experimentaux-et-predictions.md` (protocoles) · `results/` (traces brutes).*
