# E10 — Non-déterminisme du cache (postulat P5) : caractérisation

**Date** : 2026-09-04 · **Provider** : opencode-go/deepseek-v4-flash · **Méthode** : 6 requêtes bit-identiques, même session, consécutives.

## Résultat

| Req | cacheRead | input | Note |
|---|---|---|---|
| req1 | 0 | 2816 | 1ère → écriture |
| req2 | 2816 | 53 | hit chaud |
| req3 | 2816 | 100 | hit |
| req4 | 2816 | 133 | hit |
| req5 | 2816 | 147 | hit |
| req6 | 2816 | 161 | hit |

## Verdict

**Aucun non-déterminisme observable sur opencode-go/deepseek** : après le 1er tour (échauffement normal), cr = 2816 constant sur 5 requêtes identiques.

**Nuance par rapport aux reports OpenAI GPT-5** ("caching is borked", hit 1/20, non-déterministe) :
- Ce comportement instable documenté concerne **GPT-5 via l'API OpenAI directe** et se manifeste avec délai/volume/éviction LRU.
- **opencode-go/deepseek est fiable** pour les mesures (cache stable), ce qui valide le bac à sable pour E1/E3/E4.

## Limites
- Pas de test avec délai inter-requêtes ici (E3 le couvre avec les pauses).
- Pas de test multi-sessions simultanées (éviction LRU) — à explorer si besoin.
- Le non-déterminisme OpenAI reste un risque pour les optimisations qui reposent sur la clé (H6 resume sur modèles GPT via OpenAI direct) — à re-tester si accès OpenAI direct.
