# Rapport consolidé — Orchestration multi-agents (5 phases) : optimiser le cache-hit de pi

> **Méthode** : orchestration de 11 agents en 5 phases (recherche → analyse → blind → synthèse → hypothèses), avec **séparation des préoccupations** pour éviter le biais de confirmation.
> **Date** : 2026-09-04 · **Repo** : github.com/Anhydrite/recherche-cache-hits

---

## 1. Le design d'orchestration

```
Phase 1 · 3 × researcher  → Recherche état de l'art (harnesses, infra, littérature)
Phase 2 · 2 × analyste    → Comprendre le cache (mécanisme) + gouvernance pi (code réel)
Phase 3 · 2 × blind       → Proposer des optimisations SANS connaître la recherche (isolation stricte)
Phase 4 · 2 × synthèse    → Croiser chercheurs + blind + mesures → solutions à tester/implémenter
Phase 5 · 2 × finale      → Postulats + hypothèses formelles + protocoles + hypothèses théoriques
```

**Point clé** : les agents **blind** (phase 3) n'ont reçu **aucune référence** aux rapports des chercheurs — leurs prompts étaient auto-suffisants (connaissance générale du cache + code de pi). La convergence entre leurs idées et la recherche sourcée constitue une **validation indépendante**.

## 2. Résultat clé : la CONVERGENCE chercheurs ↔ blind

Les agents blind ont proposé **indépendamment** les mêmes leviers que les chercheurs (avec sources) :

| Levier | Blind (sans accès) | Chercheurs (sourcé) | Verdict croisé |
|---|---|---|---|
| **Frozen system prompt** (découplage system↔outils) | I-03 (tranche A, impact capital) | Consensus 2026 + Claude Code + "Don't Break the Cache" + F1 | **Confirmé — priorité n°1** |
| **TTL long par défaut** | c1 | Docs + régime moyen | **Confirmé** |
| **Keepalive économique** | I-10, c2-c4 | arXiv 2607.19214 + aider | **À tester** |
| **Anti-overcaching** (exclure tool results) | I-14, b4 | Papier "Don't Break the Cache" | **Confirmé esprit** (inapplicable tel quel) |
| **Séparer cwd/AGENTS du system** | I-04, a4 | Consensus 2026 | **Contredit par nos mesures** (H3 réfutée) |
| **Résumé pour préserver le préfixe** (compaction douce) | I-08, e1 | claudecodecamp + pi docs | **Confirmé esprit** |

**→ La convergence est la validation méthodologique** : les leviers qui émergent des 2 côtés sont les plus crédibles.

## 3. Les solutions à implémenter (Phase 4, croisées avec nos mesures)

### Priorité haute (P0)
| ID | Solution | Justification croisée | Gain attendu |
|---|---|---|---|
| **P0-A** | Découplage system prompt ↔ outils + gel (F1) | Consensus 2026 + nos mesures (miss total quand le set change) | Évite les miss totaux sur sessions MCP/tools dynamiques |
| **P0-B** | Table sémantique (provider, modèle) type goose + anti-overcaching | goose + H9 + nos mesures (cache implicite) | Pas de cache_control sur providers sans cache |
| **P0-C** | TTL long par défaut | Docs + régime moyen (pauses 5 min-1h) | Évite les misses idleMs |

### Priorité moyenne (P1)
- **P1-D** Warmup au démarrage (coût : 1 write, gain : TTFT 1er tour + hits)
- **P1-E** Keepalive probabiliste opt-in (conditionné à la mesure P7 : les lectures prolongent-elles le TTL ?)
- **P1-F** Suffixe minimal (troncature + purge des tool results périmés, −30 % tokens relus attendu)
- **P1-G** Ordonnancement anti-miss (grouper/avancer les invalidations inévitables)

### Priorité basse (P2)
- **P2-H** Compaction douce (résumé stable, moins de /compact massifs)

### Écartés (preuves à l'appui)
- **cwd/AGENTS hors system** (H3 réfutée par anti-biais : miss ~100-200 tokens seulement, le cwd fin de system est déjà bien)
- **Exclude tool results littéral** (inapplicable : providers en cache implicite)

## 4. Postulats et hypothèses à valider (Phase 5)

### Postulats vérifiés
- **P1** : cache = préfixe exact bit-identique ✅ (mesuré)
- **P4** : cwd/path AGENTS en fin de system, miss partiel ~100-200 tokens ✅ (mesuré)
- **P8** : resume bit-identique ✅ (mesuré sur opencode-go)
- **P9** : providers accessibles en cache implicite ✅ (payload mesuré)

### Postulats à vérifier (les plus critiques)
- **P7** : *les lectures prolongent-elles le TTL du cache ?* (critique pour le keepalive — si FAUX, le ping en lecture pure ne sert à rien)
- **P2/P3** : comportement exact du cache OpenAI (non-déterminisme, éviction LRU entre sessions)

### Hypothèses formelles chiffrées (extrait)
- **H-A (P0-A)** : découplage → cr au tour après rebuild ≈ cr baseline (vs 0 aujourd'hui), N≥5, scénarios S2-S6
- **H-F (P1-F)** : tokens relus −30 % médian (intervalle −25 à −45 %)
- **H-E (P1-E)** : keepalive rentable si P(reprise) ≥ 60-80 %, ttft reprise −30 à −70 %

## 5. Livrables complets (.research/)

```
.research/
├── phase1-recherche/  00-web-external.md (87 l.), 01-harnesses.md (95 l.), 02-cache-infra.md (70 l.), 03-literature.md (97 l.)
├── phase2-analyse/    01-mecanisme.md (291 l.), 02-gouvernance-pi.md (266 l.)
├── phase3-blind/      01-blind-harness.md (244 l., 30 idées I-01..I-30), 02-blind-infra.md (266 l., a1..e5)
├── phase4-synthese/   01-actions.md (177 l., P0-P2), 02-architecture.md (297 l., 10 principes)
└── phase5-hypotheses/ 01-postulats-experiences.md (295 l.), 02-hypotheses-theoriques.md (250 l.)
```

## 6. Prochaine étape recommandée

1. **Valider les postulats critiques** P7 (TTL prolongé par lecture ?) et P2/P3 (non-déterminisme OpenAI) — ce sont les prérequis du keepalive (H-E) et de la confiance dans le cache.
2. **Implémenter P0-A** (découplage system↔outils) — le chantier n°1, confirmé par 3 sources indépendantes.
3. **Tester H-A, H-D, H-F** avec le protocole anti-biais (docs/05 §6) sur 2 providers.

**Budget estimé** : tests P0-P2 complets ≈ 1-2 $ (deepseek-v4-flash / commandcode).