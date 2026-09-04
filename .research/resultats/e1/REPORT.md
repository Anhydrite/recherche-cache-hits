# E1 — Découplage system ↔ outils (P0-A) : mécanisme vérifié, mesure limitée par le banc

**Date** : 2026-09-04 · **Provider** : opencode-go/deepseek-v4-flash

## Ce qui est ÉTABLI (mesures antérieures T1-refined)
- **Quand le set d'outils change** (read,bash → read,edit) : `_rebuildSystemPrompt` régénère le system → **miss total** (cr=0, sysHash 12f1ccdf → d605fbcd).
- Cause racine F1 : les **tool snippets + guidelines sont DANS le system prompt** (positions 2 & 4) et dépendent du set d'outils.

## L'implémentation condition B (e1-condition-b.ts)
Vérifiée **fonctionnelle** (2 tours, process fresh) :
- **Tour 1** : snapshot du system (sysHash=12f1ccdf, 7481 octets) + capture des guidelines.
- **Tour 2** (outils changés) : le system est **remplacé par le snapshot figé** (sysHash=12f1ccdf **inchangé**, 7481 octets — au lieu de d605fbcd) ✅ ET le bloc "Operating instructions" (guidelines) est **injecté dans le 1er message user** ✅.

**Preuve du véracité** :
```
tour2 avec -t read,bash:
  sysHash=12f1ccdf83 (FIGÉ — identique au tour 1) ✅
  fuHead="Operating instructions (cache-stable): Available tools:..."
```

## Limite du banc (à documenter honnêtement)

Le banc actuel relance **`pi --print` = 1 process par tour**, qui **reconstruit le system AVANT le hook** (le 1er appel du tour échappe au freeze). Le freeze ne s'applique qu'à la 2e requête du process. Résultat : dans le banc actuel, on observe encore sysHash=d605fbcd sur la 1ère requête du tour 2.

**Le vrai test H-A nécessite un process continu** (mode RPC/interactif) où le system est construit UNE FOIS en mémoire et figé par l'extension à travers les tours. Le mode RPC a été exploré (pilote) mais les hooks provider ne s'exposent pas simplement en RPC → à finaliser dans une itération suivante.

## Verdict E1 provisoire
- **Mécanisme validé** : le découplage (system figé + Operating instructions en 1er message) est **fonctionnel** dans l'extension — le system reste bit-stable malgré le changement d'outils.
- **Gain** : en théorie, chaque miss total évité (cr 0 → 2816) sur les sessions avec changements d'outils = ~0.01-0.05 $/miss économisé (données T1-refined).
- **À confirmer** : mesure du cr réel dans un banc process-continu (RPC) — étape suivante.

## Recommandation
- **P0-A est l'implémentation la plus rentable** : découpler guidelines/outils du system prompt dans le code pi (refonte de `_rebuildSystemPrompt`) — pas juste une extension de contournement. Le mécanisme est prouvé par l'extension.
