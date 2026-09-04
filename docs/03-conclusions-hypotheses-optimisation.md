# Conclusions & Hypothèses : optimiser le cache au niveau du harness

> **Suite directe des deux documents précédents** (`README-cache-hit-harnesses.md`, `02-comprehension-etat-de-l-art.md`).
> Ce document tranche : quelles conclusions tirer de l'étude (code + état de l'art) et quelles hypothèses concrètes tester pour **optimiser le cache-hit au niveau du harness**.

---

## Partie 1 — CONCLUSIONS (ce qui est établi)

### C1. Le mécanisme est un contrat d'octets exact — tout se joue sur la *stabilité du préfixe*

Le cache API ne matche que si le **préfixe complet** est identique octet pour octet. Conséquences dures :
- *Toute* modification du system prompt invalide *tout* le cache (même les couches suivantes).
- Le seul levier d'un harness est : **(1) ordonner** le prompt par stabilité décroissante et **(2) ne jamais laisser se faufiler de contenu volatil dans le préfixe**.
- C'est pourquoi le pattern gagnant (confirmé par le papier PwC) est : **system prompt stable + tout le dynamique en queue** (messages) + breakpoints aux 3 frontières (fin system, dernier tool, dernier message user).

### C2. Le system prompt domine le coût : c'est l'actif n°1 à protéger

Papier arXiv:2601.06007 : le system prompt (10k tokens) est responsable de la **majorité** des économies (41-80 % de cost ↓). Les stratégies "system prompt only" et "full context" sont à **2-4 points près** en coût. Conclusion : **maximiser la taille et la stabilité du system prompt caché** rapporte plus que d'optimiser la queue conversationnelle.

### C3. Le full-context caching naïf peut être contre-productif (latence)

Cache des tool results dynamiques → overhead de *cache write* sans lecture bénéfique → **régression TTFT** (GPT-4o : -8.8 % ; GPT-5.2 : full-context 9.5 % vs 13 % avec exclusion). Conclusion : **ne pas cacher ce qui ne se répète pas** (tool results, contenu session-specific).

### C4. pi a déjà les bons réflexes de base, vérifiés dans le code

Lus/approuvés dans `pi-mono` :
1. ✅ Pas de timestamp/session-id dans le system prompt.
2. ✅ 3 breakpoints `cache_control` corrects (system, dernier tool, dernier user) — le pattern canonique.
3. ✅ cwd en fin de system prompt (moins de dégâts s'il change).
4. ✅ `prompt_cache_key` clampé à 64 chars dérivé du sessionId stable (OpenAI).
5. ✅ `PI_CACHE_RETENTION=long` (1h/24h).
6. ✅ Compaction : summary inséré en tête (préfixe court) + `cacheRetention:"none"` sur les appels de résumé (pas de cache write gaspillé).
7. ✅ Session-affinity headers.
8. ✅ Métriques/notices de miss (`cache-stats.ts`, `showCacheMissNotices`).

### C5. Trois fuites de cache identifiées dans le code pi (à corriger ou documenter)

1. **🔥 `_rebuildSystemPrompt` invalide tout le cache en cours de session.**
   - Déclencheurs trouvés : (a) changement de la liste d'outils (agent-session.ts:983) et (b) extension de ressources skills/prompts/themes (agent-session.ts:2491). Chaque rebuild change le system prompt → miss total au tour suivant.
   - **Recommandation** : retarder l'application (pattern Claude Code) : les changements d'outils/ressources devraient soit ne s'appliquer qu'au prochain cycle de session, soit être *appendés en queue* plutôt que de régénérer l'ensemble. Coût potentiel : plusieurs $/session sur des sessions longues avec MCP.
2. **Le cwd est dans le system prompt.** Changer de dossier (ou reprendre un session file sur une autre machine) → miss. Recommandation : le déplacer dans le *premier message user* ou utiliser une "session fingerprint" stable. (Le cwd reste nécessaire au modèle, mais il ne devrait pas faire partie du préfixe caché *durablement*.)
3. **Le `<project_context>` (AGENTS.md) est dans le system prompt.** Si un fichier de contexte projet change en cours de session → rebuild → miss total. Même recommandation que C5.1.

### C6. Le modèle de coût : 3 régimes, 3 leviers distincts

| Régime | Levier dominant | Exemple |
|---|---|---|
| **Court** (pauses < 5 min) | Breakpoints + stabilité du préfixe | Sessions interactives continues |
| **Moyen** (pauses 5 min–1 h) | **TTL long** (`PI_CACHE_RETENTION=long`) | Dev avec pauses café |
| **Long** (cross-session, > 1 h) | **re-use cross-session** (OpenAI `prompt_cache_key` + clé stable) ou cache infra LMCache | Sessions reprises (`pi resume`) |

> Clairement : aucun harness ne gère le régime long avec les APIs standard (TTL 24h OpenAI est le max ; Anthropic 1h) — la valeur est surtout dans le régime court → moyen.

---

## Partie 2 — HYPOTHÈSES D'OPTIMISATION (à tester)

> Format : **Hypothèse → mécanisme → prédiction testable → coût/risque**. Numérotées H1..H10, ordonnées par rapport bénéfice/effort estimé.

### H1. « Frozen system prompt » : ne JAMAIS régénérer le system prompt en cours de session
- **Mécanisme** : geler `_baseSystemPrompt` au premier tour. Toute modification (outils/ressources/AGENTS.md) = *version diff* appliquée en fin de prompt (append) ou reportée au prochain `/new`/resume — jamais de réécriture du bloc initial.
- **Prédiction** : le taux de hit passe de « variable » à « ~100 % sur le bloc system » dès qu'une session dépasse quelques tours. Gain direct $ (chaque tour économise la relecture du system complet).
- **Test** : longues sessions avec MCP/skills chargés en cours de route ; comparer `cacheRead`/`cacheWrite` avant/après.
- **Cohérence avec l'état de l'art** : c'est exactement le pattern documenté de Claude Code (« editing CLAUDE.md mid-session… changes don't apply until the next cycle »). Le papier « Don't Break the Cache » le confirme stratégiquement (dynamique en queue seulement).

### H2. Contrôle fin des breakpoints : « latest-user-message » comme cible (pas le dernier message quel qu'il soit)
- **Mécanisme** : pi marque le dernier bloc du **dernier message user**. Vérifier que quand un tour éclate en N assistant/tool round-trips (sans nouveau user), le breakpoint reste sur le dernier user (stable) et non sur un tool result (qui change) — cf. code opencode `cache-policy.ts` (stratégie `latest-user-message`, documentée comme la plus rentable).
- **Prédiction** : les sessions à nombreux appels d'outils gardent un hit élevé intra-tour.
- **Test** : instrumenter `applyCacheControl` : compter hits intra-tour sur des boucles bash/edit répétées.

### H3. Séparer « contenu projet » du « system prompt » : cwd + AGENTS.md en tête de *messages*, pas du *prompt*
- **Mécanisme** : déplacer cwd et `<project_context>` dans le **premier message user** (ou un message system *séparé* après le system prompt principal, avec son propre breakpoint).
- **Prédiction** : les changements de cwd/multi-repo/AGENTS.md en cours de session ne cassent plus le préfixe system principal.
- **Risque** : attention au seuil min de cache (1024 tokens) — si le system prompt seul tombe sous le seuil, on perd le cache. Il faut donc garder un system ≥ ~2k tokens (instructions + tools + docs pi le dépassent déjà largement).

### H4. Cacher *moins*, pas plus : exclure les tool results du cache (stratégie « exclude tool results »)
- **Mécanisme** : sur Anthropic, poser un breakpoint **avant** la partie tool results/queue de conversation (ou ne pas placer de breakpoint sur le dernier user quand la queue est énorme et instable), plutôt que de tout cacher. C'est la stratégie gagnante du papier pour GPT-5.2 (79.6 % cost ↓, 13 % TTFT ↓, la meilleure sur la latence).
- **Prédiction** : la latence (TTFT) des tours suivants s'améliore car on évite des *cache writes* inutiles sur du contenu qui ne se repète jamais.
- **Risque** : perte de coût si la conversation est plus grande que le system (la partie conversation n'est plus relue en cache). **Donc : stratégie hybride** — cacher la conversation tant qu'elle est < system, l'exclure au-delà. C'est l'hypothèse la plus nuancée et la plus intéressante à tester.

### H5. Cache-warming / keepalive intelligent (réglable)
- **Mécanisme** : reprendre le pattern aider (`AIDER_CACHE_KEEPALIVE_DELAY`, pings silencieux) : quand une session est active mais avec des pauses > 4 min, envoyer un petit ping (dernier contexte + "continue") pour rafraîchir le TTL Anthropic 5 min. Ne pas le faire si ça coûte plus que ça ne sauve (le ping est un vrai appel).
- **Prédiction** : sur des sessions longues avec pauses, éviter le miss complet à la reprise.
- **Test** : mesurer le coût du ping vs le $ économisé sur le tour de reprise. **Faut-il l'activer par défaut ?** probabiliste : si la probabilité de reprise > coût du ping / bénéfice du hit, oui.

### H6. « Session fingerprint » pour le resume cross-process
- **Mécanisme** : si un utilisateur ferme et reprend `pi resume`, le sessionId devrait être **stable** (il l'est : uuidv7 persisté) mais le **cwd + contexte projet** doivent être identiques pour que le cache OpenAI 24h matche. Vérifier que le prompt réassemblé sur resume est **bit-identique** au dernier tour (mêmes tools, mêmes AGENTS.md, même ordre).
- **Prédiction** : les sessions reprises (même jour) gardent les hits GPT-4o/GPT-5.2 (24h).
- **Test** : snapshot du prompt au dernier tour vs prompt reconstruit au resume → diff.

### H7. Le breakpoint système doit TOUJOURS être en place même quand il n'y a pas de tools
- **Mécanisme** : dans les configurations minimales (peu de tools), le breakpoint system reste critique car c'est le seul contenu vraiment stable et volumineux. Vérifier que le code pi le pose même si `tools.length === 0`.
- **Prédiction** : les sessions sans tools (critique/plan) gardent quand même le cost ↓ system.
- **Note** : vérifier aussi le **seuil de 4 breakpoints** (Anthropic) : pi n'en pose que 3, donc OK, mais si un jour on ajoute un 4e (ex. projet), s'assurer que le plus stable est conservé.

### H8. Mesurer le « cache-waste » en $ et l'afficher en header/footer
- **Mécanisme** : utiliser `computeCacheWaste` (déjà dans `cache-stats.ts`) pour afficher « $ de cache perdu cette session » (miss×coût) + la cause (idle>TTL, modèle changé, contenu volatile). L'utiliser pour auto-research.
- **Prédiction** : les utilisateurs (et le harness lui-même) détectent les fuites (H1/H3) sans introspection manuelle.
- **Note** : partie du footer existe déjà (`R/W/CH`) ; l'ajouter en $.

### H9. Adapter la stratégie au provider (table de sémantique type goose)
- **Mécanisme** : table (provider, modèle) → `ExplicitBreakpoints | ImplicitStrict | ImplicitTolerant | Uncached` (pattern goose `cache_semantics.rs`). Choisir quoi faire :
  - `ExplicitBreakpoints` → poser les 3 breakpoints (anthropic/minimax/zai/kimi/bedrock-claude).
  - `ImplicitTolerant/Strict` (OpenAI, Gemini…) → ne pas poser de breakpoint, se concentrer sur la stabilité du préfixe + `prompt_cache_key`/session-affinity.
  - `Uncached` (snowflake/sagemaker-tgi…) → ne rien faire.
- **Prédiction** : moins de frais inutiles (pas de cache_write sur des providers sans cache) et un comportement plus robuste sur les providers "exotic".

### H10. Opportunités au-delà des APIs : le harness comme *consumer* du non-prefix cache (CacheBlend/LMCache sur serving maison)
- **Mécanisme** : pour qui sert soi-même (vLLM/SGLang + LMCache), le harness peut **bénéficier du non-prefix reuse** (CacheBlend : 63-85 % hit vs 3-25 % prefix-only) — mais c'est côté infra, pas côté harness. Au niveau harness, l'opportunité est de **ne rien faire qui empêche ce reuse** (garder des blocs stables réutilisables, ne pas tout fragmenter).
- **Prédiction** : un harness qui garde ses messages ordonnés/groupés (plutôt que re-injectés à chaque fois) profite du radix/non-prefix caching des serveurs modernes.
- **Long terme** : les fournisseurs poussent vers le cache non-prefix (Tensormesh, LMCache) ; les contraintes du harness vont s'assouplir (le préfixe exact deviendra moins critique) mais la **structuration du contenu** restera le levier.

---

## Partie 3 — SYNTHeSE : le modèle mental du harness « cache-optimal »

**1. Court terme (ce que pi est déjà, ~90 % du chemin)**
- System prompt figé par session (H1), breakpoints standard (H2, H7), cwd/projet hors préfixe (H3), TTL long dispo (C6), métriques $ (H8).

**2. Moyen terme (les 3 gains mesurables)**
- H1 (frozen system prompt) : gain $ quasi immédiat sur sessions longues.
- H3 (séparer cwd/AGENTS.md) : robustesse multi-repo et resume.
- H4 (exclude tool results / hybride) : meilleure latence sur sessions à gros tooling.

**3. Long terme (au-delà des APIs, vers l'infra)**
- H9 (sémantique par provider) : robustesse cross-provider.
- H10 (respect du non-prefix cache) : bénéficier des prochaines générations de serving.

---

## Partie 4 — APPENDICE : données chiffrées de référence (pour étayer les prédictions)

| Paramètre | Valeur | Source |
|---|---|---|
| Coût gagné par le cache (optimal) | 41-80 % | arXiv:2601.06007 |
| TTFT gagné (optimal) | 13-31 % | idem |
| Full-context vs system-only (coût) | Δ 2-4 pts | idem |
| Full-context vs system-only (TTFT) | jusqu'à -8.8 % régression (GPT-4o) | idem |
| Seuil min tokens (OpenAI/Anthropic/Google) | 1024 / 1024 / 4096 | idem (Table 4) |
| TTL (short / long) | 5 min / 1h (Anthropic), 24h (OpenAI) | docs providers |
| Prix cache read / write (Anthropic) | 0.1× / 1.25× | docs Anthropic |
| Breakpoints max par requête (Anthropic) | 4 | docs Anthropic |
| Non-prefix cache hit (CacheBlend) | 63-85 % vs 3-25 % | arXiv:2405.16444 / Tensormesh |
| Cache hit rate agentic (Deep Agents) | jusqu'à 80 % cost ↓ "no config" | LangChain blog |

---

## Partie 5 — PROCHAINES ÉTAPES CONCRÈTES (si tu veux que je continue)

1. **[Instrumenter]** Tracer `_rebuildSystemPrompt` sur une vraie session : combien de rebuilds, quand, quel delta de tokens → chiffrer la fuite H1.
2. **[Tester H4]** Sur une session réelle, comparer coût/TTFT entre le mode actuel (cache tout) et un mode « exclude tool results » ; avec change de seuil conversation > system.
3. **[Tester H6]** Vérifier que le prompt reconstruit au `pi resume` est bit-identique (sinon corriger).
4. **[Prototyper H2/H7]** Un mini-module `cache-policy.ts` pi (comme opencode) : `auto/none/objet + latest-user-message`, exposé en options.
5. **[Documenter]** Publier dans les docs pi une page « Prompt caching » de même niveau que celle de Claude Code (invalidations, TTL, conseils), car c'est un levier de coût massif pour les utilisateurs.
6. **[Benchmark]** Reproduire l'ablation arXiv sur un harness léger (500/5k/50k tokens, 3/10/50 tools) pour valider les prédictions H4/H7 avec nos modèles par défaut.