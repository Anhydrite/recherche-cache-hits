# BASELINE QUANTITATIVE — mesurée sur les traces réelles

> Mesures extraites des traces JSONL (`results/`, `.pi-test/results/`) — 2 114 tours « usage » sur 126 traces.
> Provider : **deepseek-v4-flash** via commandcode et opencode-go. Tarifs déduits des traces :
> **cache 0.007 $/M · input 0.22 $/M · output 0.66 $/M** (relire en cache = **31× moins cher** que payer du nouveau).

## 1. Coût d'une session réelle (scénarios d'usage S1/S2/S5/S8)

| Scénario d'usage | Exemple | Tours | **Coût total (médiane)** | Min–max |
|---|---|---|---|---|
| S1 lecture courte | lire 3 fichiers + synthèse | 19 | **0.33 cent** | 0.23–0.68 |
| S5 contexte projet | travail avec AGENTS.md | 14 | **0.73 cent** | 0.47–1.01 |
| S8 multi-repo | changer de repo en session | 12 | **0.11 cent** | 0.08–0.12 |
| **S2 édition moyenne** | **lire 2 fichiers, éditer, vérifier** | **~33** | **~2.9 cents** | 1.76–3.85 |

→ Une **tâche de dev pi complète** (édition, ~33 tours) coûte **~3 cents**. Un tour normal ≈ **0.02-0.07 cent**.

## 2. Où part l'argent ? (session S2 type, 33 tours)

| Poste | Tokens | Coût | % du coût | Commentaire |
|---|---|---|---|---|
| **Input nouveau** (deltas : tool results, nouveaux messages) | 76 388 | 1.68 cents | **64 %** | **c'est ici que part l'argent** (0.22 $/M) |
| **Relecture cache** (system + historique relus à chaque tour) | 679 680 | 0.48 cent | 18 % | quasi gratuit (0.007 $/M) — **le cache marche très bien** |
| Output (réponse du modèle) | 6 847 | 0.45 cent | 17 % | — |

→ Le system prompt (~2 300 tok) relu à chaque tour ne coûte que **0.05 cent/session (~2 % du coût)**. Les optimisations « de préfixe » (H1/H3) jouent sur un poste déjà presque gratuit.
→ **Le seul vrai levier économique = réduire les NOUVEAUX tokens par tour** (troncature/compaction des tool results), pas réarranger le préfixe.

## 3. Événements qui cassent le cache — coût réel par occurrence

| Événement | Coût du tour normal | Coût du tour cassé | Surcoût |
|---|---|---|---|
| Rebuild au milieu des outils (T1-refined) | 0.02-0.04 cent | **0.051 cent** (miss, in=2309) | **×15-25** mais reste **~0.05 cent** |
| Changement de repo (cwd, T3) | 0.02 cent | 0.02 cent (miss partiel ~700 tok) | ≈ nul |
| Resume session (T6) | 0.02 cent | **0.02 cent** (hit total conservé) | nul (rien ne casse) |

→ **Même le pire événement (rebuild) ne coûte que ~0.05 cent** par occurrence. Pour que P0-A (frozen system) « vaille le coup », il faut des dizaines de rebuilds par session — ou un modèle plus cher.

## 4. Conditions A/B comparées (H3-bias) — coût total de session médian

| Scénario | A (cwd dans system) | B (cwd au 1er message) | Δ B−A | Verdict |
|---|---|---|---|---|
| S1 commandcode | 0.30 c | 0.33 c | +12.8 % | ~ (bruit) |
| S2 commandcode | 2.61 c | 3.00 c | +14.9 % | ~ (bruit) |
| S5 commandcode | 0.80 c | 0.74 c | −7.2 % | ~ |
| S8 commandcode | 0.11 c | 0.08 c | −23.7 % | ~ (bruit : 0.03 c) |
| S1 opencode-go | 0.36 c | 0.30 c | −16.0 % | ~ (bruit) |
| S2 opencode-go | 2.91 c | 2.64 c | −9.2 % | ~ (bruit) |
| S5 opencode-go | 0.73 c | 0.71 c | −3.0 % | ~ |
| S8 opencode-go | 0.12 c | 0.10 c | −13.1 % | ~ (bruit) |

→ **Signes inversés entre providers, amplitudes < 0.3 cent** = bruit inter-sessions, pas d'effet. Le cwd est déjà bien placé.

## 5. Hit-rate réel mesuré par expérience

| Expérience | Hit-rate global | cr moyen/tour | in moyen/tour |
|---|---|---|---|
| cache (smoke/tests) | 90.1 % | 5 843 | 644 |
| h2 (boucle outils) | 91.9 % | 5 488 | 481 |
| h3bias-commandcode | 90.9 % | 12 453 | 1 251 |
| h3bias-opencode-go | 91.3 % | 13 637 | 1 303 |
| t1 (rebuild fin) | 81.5 % | 2 345 | 533 |
| t1ref (rebuild milieu) | 70.1 % | 1 719 | 734 |
| t3 (cwd) | 87.0 % | 2 475 | 368 |
| t6 (resume) | 96.7 % | 2 816 | 96 |

→ **En usage réel, pi est déjà à ~91 % de hit-rate** (le préfixe est massivement rejoué en cache). Les expériences « qui cassent » (rebuilds) font baisser à 70-81 % mais sur des bancs artificiels à petit préfixe.

## 6. Conclusion chiffrée

1. **Le cache fonctionne déjà très bien** : 91 % de hit, relecture 31× moins chère que l'input neuf.
2. **Une session pi coûte ~0.1-3 cents** selon la tâche. Les gains potentiels de toutes les optimisations testées se mesurent en **fractions de cent par événement**.
3. **Le seul poste où il y a de l'argent** : les nouveaux tokens (tool results) = **64 %** du coût → **troncature = le seul levier à fort ROI restant** (−30-45 % estimé de ce poste, soit ~12-18 % de la facture).
4. Le gros du coût d'une session est l'**output + input nouveaux** (64 + 17 = 81 %), pas la relecture cache (18 %, déjà bon marché) : même un cache parfait ne réduirait le coût que de la part « relecture » (~18 %), déjà presque gratuite.
