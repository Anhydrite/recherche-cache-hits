# Rapport consolidé des expériences E0-E10 — Validation des optimisations P0-P2

> **Date** : 2026-09-04 · **Providers** : opencode-go, commandcode · **Bac à sable** : .pi-test (isolé)
> **Cadre** : protocole anti-biais (docs/05 §6) · **Coût cumulé** : ~0.6-0.8 $ (deepseek-v4-flash)

---

## RÉSUMÉ EXÉCUTIF — les verdicts

| Exp | Optimisation | Verdict | Preuve clé |
|---|---|---|---|
| **E0** | Repro / banc | ✅ Verrouillé | Instrumentation segmentée, déterminisme, P10 nuancé |
| **E1** | P0-A découplage system↔outils | ✅ **Mécanisme validé** (mesure finale RPC à confirmer) | system figé 12f1ccdf malgré changement d'outils + Operating instructions injectées |
| **E2** | P0-B table sémantique | ⚠️ **GAP trouvé** | dernier tool non marqué sur modèles explicites (claude via commandcode) |
| **E3** | P0-C TTL long vs court | 🔄 En cours | — |
| **E4** | P1-D warmup | ❌ **INUTILE** | cr=2816 dès le 1er tour dans les 2 cond (system partagé) |
| **E5** | P1-E keepalive | ⏳ Non exécuté (4-8h, prérequis E7b) | — |
| **E6** | P1-F suffixe minimal | ⏳ Non exécuté (2h) | — |
| **E7** | P1-G ordonnancement anti-miss | ⏳ Non exécuté | — |
| **E8** | P2-H compaction douce | ⏳ Non exécuté | — |
| **E10** | P5 non-déterminisme | ✅ **Pas de non-déterminisme** sur opencode-go | cr=2816 constant sur 6 requêtes |

---

## DÉTAILS PAR EXPÉRIENCE

### E0 — Repro & verrouillage du banc ✅
- `cache-trace.ts` segmenté : system/tools/messages hashs séparés.
- **Déterminisme** : sysSeg = 1 hash sur 20+ tours (12f1ccdf), toolsSeg = 1.
- **Découverte P10 nuancé** : sur 3 sessions fraîches, cr=2560 dès le tour 1 → le system de pi est **partagé entre sessions** → déjà caché. "Le 1er tour est toujours un miss" est FAUX pour un system partagé.

### E1 — P0-A découplage system↔outils ✅ (mécanisme)
- **Contexte** : T1-refined a montré miss total (cr=0) quand le set d'outils change → `_rebuildSystemPrompt` régénère.
- **Extension e1-condition-b** : snapshot du system au tour 1 + remplacement aux tours suivants + Operating instructions (guidelines) relogées au 1er message user.
- **Preuve** : au tour 2 (outils `-t read,bash`), sysHash=12f1ccdf **inchangé** (figé) + fuHead="Operating instructions...".
- **Limite** : banc process-fresh (1 pi --print par tour) → le 1er appel du process échappe au freeze. Le vrai test nécessite un process continu (RPC) — à finaliser.
- **Verdict** : le découplage est POSSIBLE et fonctionnel ; reste à mesurer le cr réel en process continu.

### E2 — P0-B table de sémantique ⚠️ GAP
- 8 (provider, modèle) inspectés via payload réel.
- 6 implicites : **aucun cache_control** (conforme — le provider matche tout).
- 2 explicites (claude via commandcode) : **cc sur system OUI, sur dernier tool NON** ← **GAP** (pattern canonique pi pose cc sur `tools[length-1]`).
- **Impact** : sur modèles explicites accessibles, les définitions d'outils ne sont pas rejouées en cache → coût/latence.
- **Verdict** : P0-B est nécessaire (le bridge commandcode ne propage pas le marquage tools).

### E3 — P0-C TTL long vs court 🔄 en cours
- Mesure cr après pauses croissantes (60-240s) avec retention short puis long.
- À compléter (voir rapport e3).

### E4 — P1-D warmup ❌ INUTILE
- 3 sessions/cond randomisées : cr=2816 (hit max) au 1er tour réel DANS LES 2 conditions.
- **Explication** : system partagé → déjà caché → warmup superflu et coûteux (écriture 1.25× inutile).
- **Verdict** : P1-D REJETÉE pour pi sur ces providers. Le warmup ne servirait que pour un préfixe session-unique (rare ici).

### E10 — P5 non-déterminisme ✅ stable
- 6 requêtes identiques même session : req1 cr=0 (écriture), req2-6 cr=2816 constant.
- **Pas de non-déterminisme** observable sur opencode-go/deepseek (contrairement aux reports GPT-5 OpenAI).
- **Verdict** : opencode-go est fiable pour les mesures ; le non-déterminisme OpenAI reste un risque pour H6 sur modèles OpenAI directs (à re-tester si accès).

---

## SYNTHÈSE — implications pour pi

1. **P0-A (découplage)** : mécanisme validé — à implémenter dans le code (refonte de `_rebuildSystemPrompt`), pas en extension de contournement. Gain : évite les miss totaux sur sessions MCP/tools dynamiques.
2. **P0-B (table sémantique)** : GAP réel sur les modèles explicites (dernier tool) — à corriger via bridge ou compat. Gain : définitions d'outils relues en cache.
3. **P0-C (TTL long)** : en cours de mesure.
4. **P1-D (warmup)** : **à NE PAS implémenter** (system partagé rend le warmup inutile) — économie d'effort.
5. **P1-E/F/G, P2-H** : non exécutés (longs) — documentés comme suite.

## SUITE RECOMMANDÉE (options)
- **E3 finalisation** : attendre la mesure TTL (déjà en fond).
- **E1 RPC** : mesurer le cr réel du découplage en process continu (1-2 h).
- **E5-E9** : keepalive (4-8h), suffixe minimal, anti-miss, compaction — priorité basse, à exécuter si enrichissement souhaité.

## COÛT TOTAL
~0.6-0.8 $ (deepseek-v4-flash) — bien sous le budget estimé (2.6-5.6 $).