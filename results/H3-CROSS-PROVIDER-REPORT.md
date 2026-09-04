# Rapport consolidé H3 — Validation croisée (commandcode vs opencode-go)

**Expérience** : H3 (sortir le cwd du system prompt) testée avec le **protocole anti-biais multi-scénarios** (doc 05 Partie 6).
**Providers** : commandcode (deepseek/deepseek-v4-flash) + opencode-go (deepseek-v4-flash) — même protocole, N=3 sessions/cond/scénario, 4 scénarios réalistes, repos égalisés, randomisation A/B.
**Coût** : ~0.3 $ (2 campagnes, 48 traces).

## Contexte : pourquoi ce test existe

Le test initial T3 (session unique, 2 repos avec/sans AGENTS.md) montrait un "miss" au changement de cwd (cr 2816→1792). **Mais ce test était biaisé** : les 2 repos avaient des contenus différents (AGENTS.md présent/absent) → le miss venait du contexte projet entier, pas du cwd.

**Correction** : repos égalisés (même AGENTS.md, même contenu), puis comparaison A (cwd dans system) vs B (cwd retiré du system + injecté au 1er message user), sur 4 scénarios d'usage réels.

## Résultats détaillés (coût médian du tour "cd_" = le moment du changement de repo)

| Scénario | Provider | A (cwd system) | B (cwd hors system) | Δ | Verdict |
|---|---|---|---|---|---|
| Lecture | commandcode | $0.00015 | $0.00015 | +1 % | neutre |
| Lecture | opencode-go | $0.00016 | $0.00014 | -13 % | B "meilleur" |
| Édition | commandcode | $0.00029 | $0.00049 | **+65 %** | B pire |
| Édition | opencode-go | $0.00031 | $0.00028 | -11 % | B "meilleur" |
| AGENTS.md | commandcode | $0.00016 | $0.00014 | -15 % | B "meilleur" |
| AGENTS.md | opencode-go | $0.00017 | $0.00020 | +18 % | B pire |
| Multi-repo | commandcode | $0.00010 | $0.00008 | -23 % | B "meilleur" |
| Multi-repo | opencode-go | $0.00010 | $0.00012 | +14 % | B pire |

## Interprétation (validation croisée)

**Aucun scénario n'a le même signe sur les 2 providers.** Les Δ de coût (l'ordre de 0.0001 $) sont du **bruit inter-sessions**, pas un signal :

- Les "gains" de B sur certains scénarios (lecture, multi-repo) sont annulés par des "pertes" sur les autres (édition, AGENTS.md),
- Le signe s'inverse entre commandcode et opencode-go sur chaque scénario,
- Les coûts en jeu (~0.0001 $ par tour) sont 10-100× plus petits que la variabilité des tarifs/rounding.

## Verdict final

**H3 est RÉFUTÉE.** Sortir le cwd du system prompt n'apporte aucun gain mesurable :

1. **Le design actuel de pi est déjà quasi optimal** : le cwd est en FIN de system prompt → le préfixe stable avant le cwd reste en cache ; un changement de repo ne coûte que ~100-200 tokens (le cwd + le path projet), pas des milliers.
2. **La condition B peut même coûter plus** (l'injection `[CWD:...]` au 1er message modifie la conversation).
3. **La validation croisée est la preuve décisive** : sans elle, le scénario "multi-repo -23 %" (commandcode) aurait pu sembler prometteur — le provider opencode-go montre +14 % sur le même scénario.

## Leçon méthodologique (valeur du protocole anti-biais)

Ce protocole a **évité un faux positif** : l'hypothèse initiale (issue d'un test biaisé) aurait conduit à implémenter une optimisation inutile dans pi. Les garde-fous qui ont fonctionné :
1. **Égalisation des repos** (isoler UNE variable : le cwd)
2. **Scénarios multiples** (l'effet n'est pas uniforme)
3. **Validation croisée 2 providers** (le signe s'inverse → bruit)

**Traces brutes** : non versionnées (volumineuses), disponibles dans `.pi-test/results/h3bias-<provider>/` après `./scripts/run-h3-bias.sh`.