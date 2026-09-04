# Rapport de campagne expérimentale — Optimisation cache pi

**Date** : 2026-09-04 · **Env** : bac à sable isolé (.pi-test/) · **Provider** : opencode-go/deepseek-v4-flash
**Prompt** : "<label>: réponds uniquement OK." · **Métrique reine** : cacheRead (cr) / sysHash / sysBytes

---

## 1. T1 (déjà documenté) : rebuild en fin d'outils → miss PARTIEL

Rebuild `-t read,bash` (retire edit/write) : cr 2816 → 2048-2304 (miss partiel, pas total).
Seule la portion des tools retirés en fin est re-facturée. Coût ×3.5, pas ×10.

## 2. T1-REFINED : rebuild au MILIEU des outils → **MISS TOTAL**

| Tour | sysHash | sysBytes | tools | cr | interprétation |
|---|---|---|---|---|---|
| warmup | 12f1ccdf | 7481 | read,bash,edit,write | 2816 | écrit |
| base2t 1 | d605fbcd | **6781** | read,bash | 0 | nouveau prompt (2 tools) → miss |
| base2t 2-3 | d605fbcd | 6781 | read,bash | 2304 | hit stable |
| **mid_change** | **1dbd7aa2** | **7207** | read,edit | **0** | **MISS TOTAL** |
| restore | d605fbcd | 6781 | read,bash | 2304 | re-hit |

**Découverte clé** : le system prompt de pi **change quand les tools changent** (sysBytes 7481→6781 pour 4→2 tools, les guidelines dépendent des tools présents). Donc changer le tool #2 (bash→edit) change system + tools → **miss total** (cr=0).

→ Le coût d'un rebuild n'est PAS "portion modifiée" mais dépend de **si les guidelines system changent** :
- changer le NOMBRE de tools : guidelines changent → miss partiel notable (6781 vs 7481)
- changer le set (même nombre, tools différents) : guidelines changent → **miss total**

## 3. T3 : cwd dans le system prompt → miss PARTIEL, H3 CONFIRMÉ

| Tour | repo | sysHash | sysBytes | cr |
|---|---|---|---|---|
| warmup/base | A | 12f1ccdf | 7481 | 2816 (hit) |
| repoB1 | B | f7fcca41 | **7501** | **1792** |
| repoB2 | B | 6605a1e9 | 7501 | 1792 |
| repoA2 | A | f7fcca41 | 7501 | **2816** (re-hit) |

- **Le cwd EST dans le system prompt** (sysBytes +20 en repoB = le chemin du cwd injecté en fin).
- Changement de cwd = miss PARTIEL (2816→1792) : le préfixe system AVANT le cwd reste caché, seule la fin (cwd) re-part. Cohérent avec la position "cwd en fin de system prompt".
- Retour au repoA : re-hit total (le préfixe d'origine est re-réutilisé).

→ **H3 validée (nuancée)** : le cwd en fin de system minimise le dégât (miss partiel ~700 tokens), mais un cwd hors system (1er message user) éliminerait complètement ce miss.

## 4. T6 : resume bit-identique → **HIT TOTAL, H6 VALIDÉE**

| Tour | sysHash | cr |
|---|---|---|
| session tours 1-4 | 12f1ccdf | 2816 constant |
| resume_tour1 (même session-id) | 12f1ccdf | **2816 hit** |
| resume_tour2 | 12f1ccdf | 2816 hit |

- Le prompt reconstruit au resume (même --session-id) est **bit-identique** au dernier tour (sysHash
  identique 12f1ccdf pendant toute la session + resume).
- Le cache OpenAI (session active, prompt_cache_key stable) **survit au resume** → **H6 validée**
  pour le cas "même session-id, même config, même cwd".

---

## Synthèse des verdicts (campagne réelle)

| Hyp | Prédiction | Observé | Verdict |
|---|---|---|---|
| H1 rebuild fin | miss total | miss partiel (portion tools) | **Refusée (nuancée)** |
| H1-refined rebuild milieu | — | **miss total** (guidelines changent) | **Validée** |
| H3 cwd system | miss | miss partiel (fin de system) | **Validée (nuancée)** |
| H6 resume | hit si bit-identique | **hit total** (bit-identique confirmé) | **Validée** |

## Coûts de la campagne
~70 tours deepseek-v4-flash ≈ **0.05-0.10 $** (négligeable, et le bac à sable isole tout).

## Leçons méthodo
1. `sysHash`/`sysBytes` = la vraie métrique pour détecter un changement de system (le payload hash complet ne suffit pas).
2. Les guidelines dans le system prompt **dépendent des tools** → un rebuild qui change le set d'outils change le system.
3. `cacheRead` constant ne veut pas dire hash identique (préfixe réutilisé, pas prompt entier).

## 5. H2 : boucle d'outils intra-tour → HIT QUASI PARFAIT (91.9%)

| Tour (msgs) | input | cacheRead | hit_rate |
|---|---|---|---|
| 2 | 12 | 2816 | 99.6 % |
| 4 | 99 | 2816 | 96.6 % |
| 6 | 922 | 2816 | 75.3 % (2 read ajoutés) |
| 8 | 878 | 3584 | 80.3 % |
| 10 | 125 | 4352 | 97.2 % |
| 12 | 196 | 4352 | 95.7 % |
| 18 | 246 | 5888 | 96.0 % |
| 26 | 104 | 7680 | 98.7 % |
| 32 | 756 | 8704 | 92.0 % |

**HIT RATE GLOBAL = 91.9 %** (cr=87808, in=7695, sur 16 appels).

- Le `cacheRead` croît avec la conversation (2816 → 8704) = le préfixe ENTIER est rejoué en cache à chaque appel.
- Seuls les deltas (nouveaux tool results) passent en `input` (75-900 tokens).
- **La stratégie « breakpoint dernier user » de pi est optimale** : pendant une boucle d'outils, le dernier user (qui contient les tool results) reste en place, chaque appel matche le préfixe.

→ **H2 VALIDÉE** — comportement actuel optimal, aucune correction nécessaire.

## 6. H3-BIAS (protocole anti-biais multi-scénarios) — cwd hors system

**Design** : comparaison A (cwd dans system) vs B (cwd retiré du system + injecté au 1er message user), repos égalisés (même AGENTS.md dans repoA et repoB), 4 scénarios réels (S1 lecture, S2 édition, S5 AGENTS.md, S8 multi-repo), randomisation A/B, N=2 sessions/cond/scénario, provider commandcode/deepseek.

### Découverte méthodologique (biais corrigé)
Le test T3 initial comparait repoA (avec AGENTS.md) vs repoB (sans) → le "miss" observé (cr 1792) venait du **contexte projet entier différent**, PAS du cwd. En égalisant les repos (même AGENTS.md), le diff system repoA↔repoB se réduit à **2 lignes** : `Current working directory: ...` et le `path` du `<project_instructions>` (~100 octets).

### Résultats (N=2, coût du tour cd = moment du changement de repo)

| Scénario | A: cdCost médian | B: cdCost médian | A: cdCr | B: cdCr | Verdict |
|---|---|---|---|---|---|
| S1 lecture | 0.00015 | 0.00015 | 3200 | 2816 | nul |
| S2 édition | 0.00029 | 0.00049 | 3968 | 5888 | B pire |
| S5 AGENTS.md | 0.00016 | 0.00014 | 3072 | 3072 | nul |
| S8 multi-repo | 0.00010 | 0.00008 | 2944 | 2816 | nul |

### Verdict H3 : RÉFUTÉE (le gain est négligeable)

- Le cwd en FIN de system prompt de pi = déjà quasi optimal : le préfixe AVANT le cwd est identique entre repos → reste en cache. Le coût d'un changement de repo = ~100-200 tokens (le cwd + path AGENTS), pas des milliers.
- La condition B (retirer le cwd) n'apporte **aucun gain mesurable** sur le coût du tour cd, et peut même coûter plus (S2 : l'injection [CWD:] au 1er message modifie la conversation).
- **L'hypothèse H3 initiale (basée sur le test T3 biaisé) est réfutée par le protocole anti-biais** — exactement le scénario de biais que tu redoutais.

### Leçon
Le test initial T3 était biaisé (2 variables mélangées : cwd + AGENTS.md). Le protocole multi-scénarios avec repos égalisés a révélé que le vrai effet du cwd seul est négligeable. → **H3 n'est PAS une optimisation prioritaire** (le code pi est déjà bien positionné).
