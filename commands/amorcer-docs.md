---
description: Construire ou auditer les fichiers de documentation depuis le dépôt entier (passe unique)
allowed-tools: Agent, Read, Glob, Grep, Bash(ls:*), Bash(date:*), Bash(mkdir:*), Bash(touch:*), Bash(wc:*), Bash(git log:*)
argument-hint: "[agents à amorcer — sinon tous ceux qui sont installés]"
---

## Agents de documentation installés dans ce projet

!`ls "$CLAUDE_PROJECT_DIR/.claude/agents" 2>/dev/null | sed 's/\.md$//' | grep -E '^(memoire-projet|project-memory|guide-utilisateur|user-guide|reference-api|api-reference)$' || echo "(aucun)"`

## État des fichiers de documentation

!`cd "$CLAUDE_PROJECT_DIR" && for f in PROJECT_MEMORY.md USER_GUIDE.md API_REFERENCE.md; do if [ -f "$f" ]; then printf '%s — présent (%s lignes)\n' "$f" "$(wc -l < "$f" | tr -d ' ')"; else printf '%s — absent\n' "$f"; fi; done`

Agents demandés par l'utilisateur (prioritaire si renseigné) : $ARGUMENTS

## Ta tâche

Passe **d'amorçage** : construire les fichiers de documentation absents et
auditer ceux qui existent, à partir du dépôt entier. C'est l'opération que le
fonctionnement normal des agents ne sait pas faire — ils travaillent sur un diff,
pas sur un codebase.

Elle ne se fait qu'une fois par projet. Elle est coûteuse. Ne la relance pas
d'initiative.

### 1. Vérifier les préalables

Si un agent de documentation porte encore ses marqueurs
`<!-- CONTEXTE-PROJET:DEBUT -->`, adapte d'abord son contexte au projet (comme le
fait `/sous-agents:agents-setup`) : un agent qui ne connaît pas le projet amorcera mal son
fichier.

S'il n'y a aucun agent de documentation installé, dis-le et arrête-toi.

### 2. Préparer le terrain

Avant de déléguer, établis un **portrait factuel du projet** que tu transmettras
à chaque agent : nature de l'application, langages et frameworks, sous-systèmes
et leur rôle, points d'entrée, emplacement de l'interface, de la déclaration des
routes et des schémas de données.

Constate-le dans le dépôt — arborescence, manifestes, configuration, fichiers
d'entrée. Ne le suppose pas. Ce portrait leur évite de refaire trois fois la même
exploration, mais il ne les dispense pas de lire le code : chacun ira vérifier ce
qu'il écrit.

### 3. Lancer les agents installés, en parallèle

Un seul message, plusieurs appels `Agent` — ils écrivent dans des fichiers
distincts, aucun conflit possible. N'invoque que ceux qui sont installés (ou ceux
que `$ARGUMENTS` nomme).

Dans le message que tu donnes à chacun, dis explicitement :

> **Mode amorçage. Périmètre : le dépôt entier, pas un diff.** Applique la
> section « Mode amorçage » de tes instructions. Le fichier est absent → tu le
> construis ; il existe → tu l'audites ligne par ligne contre le code et tu
> retires ce qui est faux, invérifiable ou qu'un `grep` donnerait mieux.

Ajoute le portrait de l'étape 2, et rappelle-leur qu'un fichier court et exact
vaut mieux qu'un fichier complet et approximatif.

### 4. Marquer la passe comme faite

Une fois les agents terminés :

```bash
mkdir -p "$CLAUDE_PROJECT_DIR/.claude/.state" && date > "$CLAUDE_PROJECT_DIR/.claude/.state/docs-amorcage"
```

Ce marqueur empêche le hook de session de reproposer l'amorçage. Ne le crée
**que** si la passe a réellement eu lieu — un amorçage interrompu ou refusé ne se
marque pas.

## Rapport final

Une ligne par fichier : construit / audité / laissé tel quel, nombre de lignes
avant → après, et **ce qui a été retiré** — c'est la partie qui compte, et celle
que personne d'autre ne fera.

Signale à part tout ce qu'un agent n'a pas pu vérifier dans le code, et toute
zone du projet qu'il a jugée non documentable en l'état.
