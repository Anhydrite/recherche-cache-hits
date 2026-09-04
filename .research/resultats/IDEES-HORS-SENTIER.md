# Idées « hors-sentier » — réécrire le contenu pour le cache

> **Constat qui motive ce document** : toute la recherche (docs 02-05, phases blind, E0-E10) a traité les optimisations de **structure** — *où placer* les blocs (geler le system, appendre en fin, breakpoints, ordre canonique, troncature). Ta remarque pointe le vide inverse : **réécrire activement le contenu des messages pour qu'il serve mieux le cache** (pas seulement le couper).
> **Base mesurée** : tool results réels dans les sessions — un `ls -la` = **31 480 chars**, un dump bash = **28 274 chars**, un `read` de doc = **24 789 chars** (parfois relu plusieurs fois). L'input nouveau (dont ces résultats) = **64 % du coût** d'une session.
> **Loi de puissance mesurée** : dans une session d'édition type, **8 % des tool results = 62 % des caractères** → quelques gros résultats dominent, et ce sont exactement ceux qu'une réécriture intelligente peut compresser. Exemple réel : un `ls -la` de 28 274 chars = 302 lignes dont **245 entrées de fichiers** (~110 chars chacune avec permissions/owner/taille/date) → compressible en **arbre de chemins** (~30 chars/entrée) ≈ **×3**, et un vrai arbre avec structure peut faire mieux.
> **Implémentable** : les hooks pi existent (`message_end` réécrit les messages y compris toolResult ; `before_provider_request` remplace le payload). Tout est testable dans le bac à sable `.pi-test/`.

---

## A · Réécrire les résultats d'outils (le gisement n°1)

### A1. Résumé+signature à l'écriture (pas troncature bête)
**Idée** : au lieu de couper le résultat long (perte d'info), le remplacer par un **résumé structuré en 3 parties** : (1) en-tête de 2-3 lignes décrivant ce que le résultat contient, (2) les N lignes « utiles » (grep/erreurs/dernières lignes), (3) une **signature** (hash court) du contenu complet.
**Gain cache** : si l'agent a besoin du contenu exact, il relance l'outil avec `--fingerprint <hash>` → pi garde une **table hash→contenu plein en local** et peut le ré-injecter sans le renvoyer au provider s'il est déjà dans la session... mais surtout, le petit résultat devient **stable et re-cacheable**, alors que le résultat de 28k relu est un poids mort.
**Différence vs troncature** : la troncature coupe et oublie ; ici on garde la **traçabilité** (hash) et on permet la **récupération à la demande**. C'est le « cache de données » que l'API ne donne pas.

### A2. Déduplication inter-résultats dans la session
**Idée** : si deux tool results contiennent des **blocs identiques** (ex. : le même fichier listé par 2 `ls`, le même en-tête de 2 commandes, la même doc lue 2×), ne garder le contenu qu'**une seule fois** (première occurrence) et remplacer les suivantes par `<voir résultat précédent #k — identique>`.
**Gain** : les 24 789 chars lus 6× deviennent 1× + 5 références. **C'est le seul moyen de gagner sur du contenu qui est déjà dans le préfixe** (le cache API relit tout le préfixe à chaque tour — la redondance interne n'est jamais dédupliquée par le provider).

### A3. Réécrire les sorties bash verbeuses en format compact
**Idée** : reconnaître les motifs de sortie et les réécrire en plus dense :
- `ls -la` / `find` → **arbre condensé** (répertoires + fichiers, sans dates/permissions inutiles sauf si demandé)
- sorties numériques/tabulaire → **table markdown compacte**
- logs répétitifs → **comptage** (« 142 lignes identiques → 1 ligne ×142 »)
**Gain** : le `ls -la` de 31 480 chars (qui ne sert qu'à montrer l'arborescence) peut passer à ~500 chars. L'agent a l'info, le préfixe relu est 60× plus petit.

### A4. Marqueurs de « déjà-vu » pour le modèle
**Idée** : quand un résultat contient du contenu déjà présent dans un tour antérieur, l'**annoter** (`# déjà vu au tour 3 — contenu identique, voir là-bas`) plutôt que de le recopier. Exploite le fait que le modèle a le contexte complet en cache : inutile de lui re-servir 24k de texte qu'il a déjà « vu ».

---

## B · Réécrire le prompt pour le cache

### B1. Normalisation bit-stable des nombres/paths/ordres volatils
**Idée** : la cause n°1 de « miss » sur un préfixe *presque* identique, ce sont les petites variations : timestamps (`Sep 4 12:01`), chemins absolus machine, ordre de fichiers non trié. Réécrire ces zones **avant envoi** :
- trier canoniquement toute liste (fichiers, tools, skills, options)
- **neutraliser les timestamps** dans les tool results (remplacer par `[ts]`) pour que 2 exécutions du même `ls` donnent le même octet
- chemin relatif vs absolu : forcer un seul style
**Gain** : transforme des préfixes « presque identiques » (qui cassent le cache exact-préfixe) en préfixes **vraiment identiques**. C'est de la *réécriture pour la réutilisabilité*, le cœur du prompt-caching.

### B2. Réécrire le system prompt pour maximiser la stabilité inter-sessions
**Idée** : le system de pi (~2 300 tok) est partagé entre sessions → déjà en cache. **Le rendre encore plus stable et plus gros** (au-dessus des seuils) en y intégrant les éléments réellement invariants par projet :
- les guidelines **communes à tous les projets** (déjà là)
- mais surtout : **sortir les éléments qui varient** même rarement (les paths des docs pi changent à chaque release → les remplacer par des pointeurs stables)
**Angle nouveau** : au lieu de *réduire* le system (pour payer moins), **l'enrichir de contenu stable utile** — car au-dessus du seuil, un system plus gros ne coûte rien de plus en relecture (0.007 $/M) mais **augmente la portion du contexte couverte par le cache**, donc réduit ce qui doit être renvoyé en input neuf. Contre-intuitif mais mesurable.

### B3. « Anchoring » du premier message : réécrire l'entrée user pour créer un préfixe de session stable
**Idée** : le premier message user (avec le contexte projet, cwd, la demande) est **unique par session** → il casse le cache inter-sessions. Le réécrire en un **bloc structuré canonique** : `<session-context>` (projet, fichiers clés, contraintes) séparé de `<demande>` — pour que (a) le bloc contexte soit *réutilisable entre sessions du même projet* (le provider le cache), (b) les tours suivants qui n'ont pas besoin de re-préciser le contexte matchent un préfixe plus long.
**Variante** : garder le contexte projet (AGENTS.md, arborescence) dans un **message séparé réutilisable**, pas dans le system (déjà testé en H3, réfuté — mais ici l'angle est de *rendre le bloc stable inter-sessions*, pas de le sortir du system).

### B4. Écriture « cache-first » des réponses de l'agent
**Idée** : quand l'agent produit une réponse qui sera relue ensuite (ex. un plan, un résumé, un choix d'architecture), la **formater pour qu'elle soit stable** si elle est re-générée : éviter les formulations qui varient, figer les décisions dans un format structuré (liste de décisions, pas de prose). Le but : si une sous-branche (fork) rejoue le même tour, le préfixe matche.

---

## C · Réécrire l'historique (au-delà de la compaction)

### C1. Normalisation progressive de l'historique (pas seulement « résumer »)
**Idée** : la compaction actuelle résume en masse et casse le préfixe. Alternative : **réécrire en continu les vieux tool results en version compacte normalisée**, sans changer leur rôle, en conservant le **hash de la version pleine** pour retrace. Le préfixe change une fois (à la réécriture) au lieu de changer à chaque compaction de masse.
**Différence vs I-08/e1** : eux proposent de *résumer* (perte sémantique + nouveau bloc). Ici on *compacte mécaniquement* (ls→arbre, logs→comptage) : l'information est conservée, juste plus dense.

### C2. Déduplication inter-sessions (cache de contenu projet local)
**Idée** : pi a une **table locale hash→contenu** (du A1) **partagée entre sessions du même projet**. Si un outil retourne un contenu déjà vu (même fichier, même sortie), le message envoyé au provider contient `<contenu #a3f2 déjà fourni en session X — inchangé>`. Le provider ne l'a jamais vu (cache API par session), mais le modèle... lui non plus. **Donc à faire avec prudence** : seulement pour les contenus réellement identifiables et récupérables (le fichier est sur disque, l'agent peut le relire si besoin). Gain : évite de re-payer l'input neuf d'un contenu que l'agent a déjà « en main » via son contexte précédent ? Non — le contexte précédent n'est pas dans la fenêtre si compacté... **à réserver aux contenus référençables** (chemins de fichiers, IDs), pas aux blobs.

---

## D · Tableau récapitulatif

| # | Idée | Quoi | Gain estimé | Effort | Risque qualité | Statut |
|---|---|---|---|---|---|---|
| A1 | Résumé+signature à l'écriture | remplacer le résultat long par en-tête + utile + hash, récupérable à la demande | élevé (résultats = 64 % du coût) | moyen | faible-moyen | **nouveau** (troncature améliorée) |
| A2 | Déduplication inter-résultats | blocs identiques → 1× + référence | moyen (relu plusieurs fois) | moyen | faible | **nouveau** |
| A3 | Réécriture compacte des sorties | ls→liste dense de noms, logs→comptage, table→md | **✅ TESTÉ : −38 % du coût du tour** (28 231→17 446 tok sur un ls réel), qualité parfaite | moyen | moyen (info perdue si mal fait) | **testé** (prototype P1) |
| A4 | Marqueurs « déjà-vu » | annoter au lieu de recopier | moyen | faible | faible | **nouveau** |
| B1 | Normalisation bit-stable | trier, neutraliser ts/paths, un style | moyen (évite des miss) | moyen | nul | **nouveau** (≠ I-01 qui trie le system, ici les tool results) |
| B2 | System prompt enrichi stable | plus de contenu stable utile, moins de volatil | contre-intuitif, à mesurer | faible | nul | **nouveau** (inverse de « réduire ») |
| B3 | Anchoring du 1er message | bloc contexte canonique réutilisable | moyen | faible | nul | **variante** de H3/I-04 (angle inter-sessions) |
| B4 | Réponses cache-first | formater les réponses re-générées pour stabilité | faible | faible | nul | **nouveau** |
| C1 | Normalisation progressive | compactage mécanique continu (≠ résumé) | élevé (longues sessions) | élevé | moyen | **variante** de I-08/e1 (angle réécriture) |
| C2 | Cache de contenu projet | table locale hash→contenu inter-sessions | spéculatif | élevé | élevé | spéculatif, à écarter d'emblée |

---

## E · Ce qui est vraiment « out of the box » (à creuser en priorité)

1. **A3 (réécrire les sorties bash en format dense)** — le plus grand gisement mesuré. Personne ne le fait : opencode *tronque*, personne ne *réécrit* la sortie pour la rendre informative ET compacte. **Déjà testé (prototype)** : −38 % du coût du tour sur un `ls -la` réel, qualité parfaite (voir `PROTOTYPE-P1-REWRITE.md`). Reste à généraliser sur sessions complètes N≥5.
2. **A1 (résumé + signature + récupération à la demande)** — transforme la perte d'info de la troncature en choix conscient : on peut toujours re-demander le plein via le hash. À étendre aux gros `read` (559 résultats >2k = 2e gisement).
3. **B1 (neutraliser timestamps/paths dans les tool results)** — rend des préfixes « presque identiques » vraiment identiques. C'est la seule idée qui **crée** des hits là où il n'y en a pas (les autres évitent des misses). Implémenté, à mesurer.
4. **B2 (enrichir le system au lieu de le réduire)** — contre-intuitif : au-dessus du seuil, un system stable plus gros ne coûte rien en relecture mais couvre plus de contexte → moins d'input neuf. Inverser le réflexe « moins = mieux ».

## E-bis · Réponse à la question « hashmap de caractères pour compresser ? »

**Non, un hashmap de caractères ne marche pas** — et la raison est le tokenizer :
- Le vocabulaire (la table token→texte) est **figé côté modèle**. Un symbole que tu inventes (hash, abréviation) n'existe pas dans le vocabulaire → le tokenizer le découpe en éclats inconnus → **plus** de tokens, pas moins. Le serveur ne « décompresse » pas.
- Le ratio réel mesuré est **5.13 octets/token** en moyenne — mais les **caractères rares** (UUID hex denses, unicode exotique) coûtent ~1 token CHACUN, alors que les mots fréquents coûtent 1 token pour 4-6 chars.
- **La version qui marche** : remplacer les *blocs* (pas les caractères) par des **références courtes à tokens fréquents** — `<résultat #k>` au lieu de 5 500 tokens de `ls`. C'est A1/A2 : un **cache applicatif au-dessus du cache API** (table hash→contenu en local, réinjection à la demande). vLLM fait ça au niveau infra (blocs de 16 tokens hachés) ; personne au niveau du contenu sémantique.
- **Bonus sûr** : éviter les caractères rares et les métadonnées inutiles (A3) = la version la plus simple du gain.

**À écarter** : C2 (cache inter-sessions de contenu — le modèle n'a pas le contenu en fenêtre), et tout ce qui repose sur le modèle « se souvenir » d'un contenu hors fenêtre.

---

## F · Protocole de test rapide (dans le bac à sable existant)

1. Prendre les **sessions S2 réelles** déjà tracées et **rejouer** les mêmes prompts avec une extension qui applique A3 (sorties denses) ou B1 (neutralisation).
2. Comparer : tokens input neufs par tour, hit-rate, et **qualité** (le modèle arrive-t-il au même résultat ?).
3. Cibler d'abord les **gros résultats mesurés** (ls 31k, dump 28k, read 24k) — le gain est maximal là.
4. Coût : ~0.5-1 $ (rejeu de 10-20 sessions S2/S1 sur deepseek-v4-flash).
