---
description: Choisir, ajouter ou retirer les sous-agents de ce projet
allowed-tools: AskUserQuestion, Read, Write, Edit, Glob, Grep, Bash(ls:*), Bash(cat:*), Bash(mkdir:*), Bash(cp:*), Bash(rm:*), Bash(find:*)
argument-hint: "[noms des agents voulus, séparés par des espaces — sinon la question est posée]"
---

## Modèles fournis par le plugin

!`ls "${CLAUDE_PLUGIN_ROOT}/templates/agents" 2>/dev/null | sed 's/\.md$//' || echo "(dossier de modèles introuvable)"`

## Sous-agents actuellement installés dans ce projet

!`ls "$CLAUDE_PROJECT_DIR/.claude/agents" 2>/dev/null | sed 's/\.md$//' || echo "(aucun)"`

Sélection demandée par l'utilisateur (prioritaire si renseignée) : $ARGUMENTS

## Ta tâche

Mets la sélection de sous-agents de ce projet en conformité avec ce que veut
l'utilisateur.

### 1. Déterminer la sélection

Si `$ARGUMENTS` est renseigné, c'est la sélection finale : les agents nommés
doivent être présents, les autres retirés.

Sinon, pose **une seule** question avec `AskUserQuestion` (`multiSelect: true`) :
une option par modèle disponible, en reprenant sa description comme explication,
et coche par défaut ce qui est déjà installé. Précise dans la question que les
agents non retenus seront retirés du projet.

### 2. Installer

1. `mkdir -p "$CLAUDE_PROJECT_DIR/.claude/agents"`.
2. Copie depuis `${CLAUDE_PLUGIN_ROOT}/templates/agents/` les agents retenus qui
   ne sont pas encore installés.
3. Retire de `.claude/agents/` les agents que l'utilisateur ne veut plus —
   **uniquement** ceux qui viennent de ce plugin. Un agent écrit à la main par
   l'utilisateur, absent des modèles, ne se touche jamais : signale-le et
   laisse-le.
4. Ne réécrase **jamais** un agent déjà installé sans le dire : sa section
   « Contexte du projet » a probablement été adaptée. Si l'utilisateur veut le
   remettre à neuf, demande-le-lui d'abord.

### 3. Adapter chaque agent nouvellement copié

Pour chaque fichier copié, remplace le bloc délimité par
`<!-- CONTEXTE-PROJET:DEBUT -->` et `<!-- CONTEXTE-PROJET:FIN -->` par le
contexte réel de ce projet, puis retire les deux marqueurs.

Constate ce contexte dans le dépôt, ne le suppose pas : manifestes de paquets,
fichiers de configuration, arborescence, quelques fichiers représentatifs
(déclaration des routes, un contrôleur, un service, un composant d'interface).
Chaque agent indique dans son propre bloc ce dont il a besoin — remplis ce qui
est demandé, rien de plus.

Règles :
- Sois concret et vérifiable : chemins réels, noms de frameworks réels, commandes
  de build / lint / test réellement présentes dans le projet.
- Liste les dossiers générés et les dépendances qu'aucun agent ne doit modifier.
- Si un point ne peut pas être vérifié, **écris moins** plutôt que d'inventer :
  un agent avec un contexte partiel mais juste travaille bien ; un agent avec un
  contexte inventé fait des dégâts.
- Ne modifie rien d'autre dans le fichier : le reste du prompt est volontaire.

### 4. Rapport

Une ligne par agent : installé / conservé / retiré / ignoré (avec la raison).
Termine en rappelant que la revue se lance avec `/revue`, et que le rappel
automatique après modification de code est déjà actif.

Si l'utilisateur ne veut aucun agent, crée le fichier vide
`$CLAUDE_PROJECT_DIR/.claude/.state/agents-setup-skipped` pour que la question ne
soit plus posée au démarrage des sessions suivantes, et dis-le-lui.
