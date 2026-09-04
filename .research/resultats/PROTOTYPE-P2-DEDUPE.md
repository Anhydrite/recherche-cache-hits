# Prototype P2 — Déduplication des relectures (A2) : VALIDÉ en conditions réelles

> **Statut** : prototype fonctionnel, mesuré sur opencode-go/deepseek-v4-flash, bac à sable `.pi-test/`.
> **Extension** : `.pi-test/extensions/dedupe-reads.ts` (hook `tool_result`, store persistant hash→contenu).
> **Date** : septembre 2026 · **Coût du test** : ~0.03 $.

## Problème mesuré (P3)

Sur les gros résultats d'outils (>2k chars) des sessions réelles :
- **93 % du volume est du contenu bit-identique relu plusieurs fois** (le même fichier lu 175×, parfois via `read` ET `cat`)
- 74 contenus distincts pour 559 gros read
- Les « presque identiques » = lectures **partielles** du même fichier (préfixes), pas des variantes sémantiques

## Ce que fait l'extension

Chaque gros résultat (`read`/`bash` > 2 000 chars) est hashé (MD5) et comparé à un **store persistant** (JSONL) des contenus déjà vus :
1. **Hash identique** → remplacé par une référence : `<déjà lu — N chars (fichier déjà fourni)>` + rappel des 3 premières lignes.
2. **Préfixe d'un contenu connu** (lecture partielle d'un fichier déjà vu complet) → idem, marqué « sous-ensemble ».
3. **Nouveau contenu** → stocké dans le store pour les prochaines fois.

Le contenu complet reste dans l'historique de la session (relu en cache) → le modèle garde l'information, on ne re-paie pas le doublon.

## Résultats mesurés

### 1. Simulation offline (sur les 733 gros résultats réels)

| Métrique | Valeur |
|---|---|
| Gros résultats dédupliqués | 527 / 733 (**72 %**) |
| **Chars économisés** | **9.66 M / 11.4 M (85 % du volume)** |
| Entrées stockées | 206 |

### 2. Test qualité (conditions réelles)

| Test | Résultat |
|---|---|
| Session C : le fichier est déjà dans le store → l'agent reçoit la **référence** seule. Question : « quel est le micro-levier n°1 et son gain prédit ? » | ✅ **Réponse précise et complète** (mécanisme, −30 % médian, critère de validation, coût estimé) — le contenu était déjà dans le contexte/historique |

→ La déduplication par référence **ne dégrade pas la capacité de réponse** quand le contenu a déjà été fourni dans la session.

### 3. Relecture réelle (2 sessions partageant le store)

| | Session A (1er read) | Session B (relecture) |
|---|---|---|
| Résultat examiné | 1 (stocké) | 2 |
| Dédupliqué | 0 | **1 (6 252 chars économisés)** |

### 4. Combiné A2+A3 (même scénario : ls gros + read gros)

| | Baseline | Avec A2+A3 | Gain |
|---|---|---|---|
| **Input payé plein tarif** | 30 600 tokens | 19 588 tokens | **−11 012 tok (−36 %)** |
| **Coût** | 0.00687 $ | 0.00449 $ | **−35 %** |

## Conclusion

**P2 validé au niveau prototype** : la déduplication par hash exact + détection de préfixe élimine **72 % des gros résultats en double (85 % du volume)** dans les sessions réelles, sans perte de qualité mesurable (le contenu reste accessible via l'historique ou une relecture). Combiné à A3 (réécriture des listings), le gain atteint **−35-36 % sur un scénario mixte** en conditions réelles.

## Limites & suite

- **Le vrai gain A2 est sur les relectures** (même fichier lu plusieurs fois) — fréquent dans les sessions longues multi-agents, rare dans une session courte. Le store persistant inter-sessions maximise le bénéfice.
- **Risque qualité** : si le contenu dédupliqué n'est PAS dans le contexte (session trop courte, contenu compacté), la référence seule ne suffit pas. Atténuation : la référence indique « utilise read/cat si besoin » → l'agent peut relire (le fichier est sur disque).
- À **généraliser** : mesure sur sessions complètes N≥5, seuil optimal (2000 ? 1000 ?), politique de rotation du store (bornage à 200 entrées actuel), et vérification que la référence ne pousse pas l'agent à relire systématiquement (ce qui annulerait le gain).

## Réponse à la question « embedding pour unifier les mots similaires ? »

Testé et **écarté par les données** :
- Les doublons réels sont **bit-identiques à 100 %** (hash exact suffit, coût nul).
- Les « presque identiques » sont des **lectures partielles** (préfixes) — détectées par test de préfixe, pas besoin d'embedding.
- Le contenu est **technique** (fichiers, chemins) : paraphraser casserait l'information (l'agent doit retrouver `repoA`, pas « dépôt A »).
- Le cache API est **bit-exact** : 2 textes « similaires à 95 % » ne matchent jamais. L'embedding n'aide pas le cache, seulement une éventuelle déduplication approximative qui n'existe pas dans nos données.
- Coût/risque : appel API par résultat + risque de fausse unification.
→ **L'embedding est la mauvaise brique ici** ; le hash exact + préfixe couvre 100 % des cas mesurés à 0 $.

## Addendum — Test à l'échelle session (après correction du bug de format)

**Bug corrigé** : le retour `{ content: <string> }` plantait sur l'outil `read` (pi attend un tableau de blocs) → corrigé en `{ content: [{ type:'text', text }] }`. Le `read` natif de pi est le 2e gros producteur de doublons (559 résultats >2k), donc cette correction est essentielle.

**Test A/B (session fraîche relisant un fichier déjà dans le store) :**

| | Sans A2 (1er read) | Avec A2 (relecture) |
|---|---|---|
| Input total | 2 137 tokens | 1 580 tokens |
| Relecture dédupliquée | — | ✅ 6 252 chars remplacés par référence |
| Qualité | — | ✅ l'agent cite correctement le micro-levier n°2 depuis la référence |

**À l'échelle des sessions longues (mesure P3 élargie)** : les sessions avec gros volume de tool results (>50k chars) ont **49-79 % de doublons intra-session** (le même fichier relu dans la session). Les sessions >200k chars : 69 % en moyenne. → A2 a un **vrai potentiel sur les sessions longues/multi-agents**, pas sur les sessions courtes.

**Limite identifiée (importante)** : quand l'agent reçoit la référence seule (contenu pas dans son contexte immédiat), il peut **relire par fragments** (`sed`, `head`, `cat`) pour retrouver l'info — ce qui peut annuler une partie du gain. Atténuations possibles : (a) inclure plus de contexte dans la référence (tête + sections clés), (b) ne dédupliquer que si le contenu est encore dans la fenêtre récente, (c) marquer la référence avec le chemin pour un `read` ciblé rapide.
