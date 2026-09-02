---
description: Passe de revue par sous-agents sur le code qui vient d'être modifié
allowed-tools: Agent, Bash(find:*), Bash(cat:*), Bash(ls:*), Bash(git status:*), Bash(git diff:*)
argument-hint: "[fichiers à réviser à la place de la liste détectée]"
---

## Fichiers de code modifiés détectés

!`sh -c 'd="${CLAUDE_PROJECT_DIR:-$PWD}"; find "$d/.claude/.state" -maxdepth 1 \( -name "*.review" -o -name "*.pending" \) -exec cat {} + 2>/dev/null | sort -u | grep . || echo "(liste vide — déterminer le périmètre avec git)"'`

## Sous-agents installés dans ce projet

!`sh -c 'd="${CLAUDE_PROJECT_DIR:-$PWD}"; ls "$d/.claude/agents" 2>/dev/null | sed "s/\.md$//" | grep . || echo "(aucun)"'`

Périmètre demandé par l'utilisateur (prioritaire s'il est renseigné) : $ARGUMENTS

## Ta tâche

Fais tourner la passe de revue sur ce périmètre, avec **les sous-agents listés
ci-dessus et eux seuls** — n'en invoque jamais un qui n'est pas installé.

**Si un sous-agent listé ci-dessus est refusé par l'outil Agent** (« Agent type
'x' not found »), c'est qu'il a été copié dans `.claude/agents/` après le
démarrage de cette session : la liste est lue au lancement. Dis-le à
l'utilisateur et demande-lui de redémarrer sa session. Ne te rabats **jamais**
sur `general-purpose` en lui donnant la description de l'agent : tu perdrais tout
le prompt système qui fait la valeur de l'agent, en croyant l'avoir remplacé.

Les étapes ci-dessous nomment les agents tels que le plugin les livre. Un projet
équipé avant le plugin peut les avoir sous d'autres noms (`code-quality`,
`security`, `project-memory`, `user-guide`…) : raisonne alors par **rôle**, en te
fiant à la description de chaque agent installé, et non au nom exact.

Si la liste de fichiers détectée est vide et qu'aucun périmètre n'est fourni,
détermine-le avec `git status --porcelain` et `git diff`. Si rien n'a changé non
plus, dis-le et arrête-toi.

Avant de déléguer, prépare **un résumé factuel des changements** : fichiers
touchés, ce qui a été ajouté / modifié / supprimé, et pourquoi. Chaque sous-agent
reçoit ce résumé — il ne connaît pas la conversation.

### Étape 0 — signaler que la passe commence

```bash
sh -c 'd="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/.state"; mkdir -p "$d" && touch "$d/revue-en-cours"'
```

Tant que ce marqueur existe, les hooks `Stop` et `PostToolUse` se taisent : sans
lui, les éditions faites **par** les sous-agents comptent comme du code non
révisé, et la revue se redemande elle-même à chaque tour. Il périme seul au bout
de 30 minutes, pour qu'une passe interrompue ne désarme pas le filet
indéfiniment.

### Étape 1 — correction du code (séquentiel)

`error-handling`, puis `qualite-code`, puis `securite` : **l'un après l'autre,
jamais en parallèle**, car ils éditent les mêmes fichiers. Enrichis le résumé à
chaque passage de ce que le sous-agent précédent a modifié.

`securite` passe **en dernier** des trois : il doit auditer le code final, et
`qualite-code` ne doit pas pouvoir retirer comme « code mort » un contrôle de
sécurité tout juste ajouté.

Saute `error-handling` et `qualite-code` si les changements ne comportent aucune
logique (reformatage, renommage local, typo, commentaires).

Saute `securite` **uniquement** si rien dans le périmètre ne touche à un point
d'entrée, une requête de données, l'authentification ou les rôles, un chemin de
fichier, un appel réseau sortant, l'envoi de courriel, ou l'affichage de contenu
fourni par l'utilisateur. Dans le doute, lance-le : une faille manquée coûte plus
cher qu'une passe inutile.

### Étape 2 — documentation (parallèle)

Une fois le code figé par l'étape 1, lance en **parallèle** (plusieurs appels
Agent dans un seul message) ceux qui s'appliquent — ils écrivent dans des
fichiers distincts, aucun conflit possible :

- `memoire-projet` — seulement si un changement mérite d'être consigné : décision
  d'architecture, contrainte ou piège non évident, changement de schéma ou de
  contrat partagé, apparition ou disparition d'un sous-système.
- `guide-utilisateur` — seulement si l'interface change pour l'utilisateur final.
- `reference-api` — seulement si un contrat exposé change : route, paramètre,
  champ de réponse, exigence d'authentification, code d'erreur.

Donne-leur le résumé des changements **après** correction par l'étape 1, pas le
résumé initial.

### Étape 3 — purge de l'état

Une fois tous les sous-agents terminés, vide la file d'attente pour que les
éditions faites *par* les sous-agents ne déclenchent pas une seconde revue :

```bash
sh -c 'd="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/.state"; rm -f "$d/revue-en-cours"; find "$d" -maxdepth 1 \( -name "*.review" -o -name "*.pending" \) -delete'
```

Le retrait du marqueur fait partie de la purge : ne l'oublie pas, les hooks
resteraient muets jusqu'à sa péremption.

## Rapport final

Un tableau court : sous-agent | verdict | ce qui a été corrigé. Signale
explicitement les sous-agents sautés et pourquoi, ainsi que tout problème qu'un
sous-agent a remonté sans pouvoir le corriger.

Remonte **en tête du rapport**, hors tableau, toute faille que `securite` a
marquée CRITIQUE ou signalée sans la corriger : ce sont les seuls résultats qui
appellent une décision de l'utilisateur.
