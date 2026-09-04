# Prototype P1 — Réécriture des sorties bash (A3+B1) : VALIDÉ en conditions réelles

> **Statut** : prototype fonctionnel, mesuré sur opencode-go/deepseek-v4-flash, bac à sable `.pi-test/`.
> **Extension** : `.pi-test/extensions/rewrite-bash-output.ts` (hook `tool_result`, réécrit avant envoi au provider).
> **Date** : septembre 2026 · **Coût du test** : ~0.02 $ (3 tours).

## Ce que fait l'extension

Sur les résultats `bash` de type **listing de fichiers** (`ls -la`, `ls -R`, sorties multi-répertoires) de plus de 1 000 chars :
- **Réécrit** le listing verbeux (perms/owner/group/size/date par fichier) en **liste compacte de noms** :
  ```
  AVANT :  drwxrwxr-x  5 anhydrite anhydrite  4096 Sep  4 12:07 .
           -rw-rw-r--  1 anhydrite anhydrite 25434 Sep  3 16:50 doc.md
           ... (245 entrées × ~110 chars de métadonnées)
  APRÈS :  [fichiers]
           doc.md · script.sh · sous-dossier ...
  ```
- Ne touche **jamais** les logs, erreurs, ou contenus réels (uniquement les listings, détectés par le motif de permissions Unix).
- **B1** : neutralise les timestamps variables sur les autres sorties longues.

## Résultats mesurés

### 1. Compression (offline, sur 105 listings réels des sessions passées)

| Métrique | Valeur |
|---|---|
| Listings réels compressés | 105 |
| **Économie de caractères moyenne** | **82 %** |
| Exemple petit `ls` (6 fichiers) | 1 121 → 44 chars (**96 %**) |
| Exemple gros `ls` de sessions | 31 480 → 15 486 chars (**51 %**, noms longs horodatés) |

### 2. Test qualité (conditions réelles)

| Test | Résultat |
|---|---|
| « Combien de fichiers .jsonl ? premier/dernier par ordre alpha ? » | ✅ **527 exact**, premier et dernier corrects, noms réels cités |

→ La réécriture ne perd **aucune information utile** pour les tâches de listing (l'agent n'a jamais besoin des permissions/dates).

### 3. Coût mesuré (A/B, un tour avec `ls -la .pi-test/sessions`)

| | Sans ext. | Avec ext. | Gain |
|---|---|---|---|
| **Input payé plein tarif** | 28 231 tokens | 17 446 tokens | **−10 785 tok (−38 %)** |
| **Coût du tour** | 0.00621 $ | 0.00384 $ | **−38 %** |

## Conclusion

**P1 validé au niveau prototype** : réécrire les sorties bash verbeuses en format compact (A3) réduit le coût des tours à gros listing de **~38 %**, sans perte de qualité mesurable. C'est le premier levier de la recherche qui agit sur des tokens **payés plein tarif** (pas sur du déjà-caché) avec un effet démontré.

## Limites & suite

- Testé sur 1 type de tâche (listing) et 1 modèle. À **généraliser** : (a) mesurer sur des sessions complètes (S2 édition) avec N≥5, (b) vérifier la non-régression de qualité sur des tâches où l'agent DOIT utiliser les métadonnées (rare), (c) étendre aux `read` de gros fichiers (autre gros producteur, 559 résultats >2k) avec la stratégie A1 (résumé + hash, plus risquée).
- Le gain réel sur une session dépend de la **fréquence des gros listings** (P3 : 23 % des résultats = 95 % des chars, mais tous ne sont pas des listings réécrivables).
- **B1** (neutralisation timestamps) : implémenté mais non mesuré séparément — son bénéfice est de *créer* des hits entre exécutions du même `ls` (à mesurer avec 2 exécutions espacées).
