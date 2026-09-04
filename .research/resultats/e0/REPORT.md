# E0 — Repro & verrouillage du banc (prérequis)

**Date** : 2026-09-04 · **Provider** : opencode-go/deepseek-v4-flash
**But** : garantir un environnement reproductible pour toutes les expériences.

## Résultats

### 1. Instrumentation segmentée (leçon P4.3) ✅
`cache-trace.ts` trace désormais les **hashs segmentés** : `systemSegmentHash`, `toolsSegmentHash`, `messagesSegmentHash` (en plus du hash global).

### 2. Déterminisme du system prompt ✅
Sur 20+ tours : **sysSeg = 1 hash distinct** (12f1ccdf) et **toolsSeg = 1 hash** (8999d02c) → le system prompt et les tools sont **déterministes** à l'intérieur d'une session.

### 3. Warmup : DÉCOUVERTE — le "1er tour = miss" est FAUX ici
Sur 3 sessions fraîches (nouveau session-id) : **cr=2560 dès le 1er tour** (au lieu de 0).

**Explication** : le préfixe system+tools de pi est **identique entre sessions** → le cache du provider (par préfixe) matche dès le 1er tour, même sans historique de session. Le postulat P10 ("le premier tour est TOUJOURS un miss") n'est vrai que si le system prompt est **session-spécifique** (unique). Pour pi, le system est partagé → pas de warmup nécessaire pour le system ; le warmup ne servirait que pour un préfixe **session-unique**.

**Implication pour E4 (warmup)** : à réévaluer — le warmup avant le 1er appel est inutile si le préfixe system est déjà partagé/caché. Le gain réel du warmup est sur les **premiers messages user** (qui sont session-spécifiques), pas sur le system.

### 4. Piège vérifié : le hash global ne prédit pas le miss ✅
msgsSeg change à chaque tour (normal, la conversation croît) mais cr reste maximal → le hash global des messages ne dit RIEN sur le hit (seuls system+tools comptent pour le préfixe).

## Verdict E0
✅ Banc verrouillé : instrumentation segmentée OK, déterminisme OK, comportement de chaleur inter-sessions documenté (nuance sur P10).
