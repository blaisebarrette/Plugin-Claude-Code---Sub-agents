---
description: Choisir, ajouter ou retirer les sous-agents de ce projet
allowed-tools: AskUserQuestion, Read, Write, Edit, Glob, Grep, Bash(ls:*), Bash(cat:*), Bash(grep:*), Bash(mkdir:*), Bash(cp:*), Bash(rm:*), Bash(find:*)
argument-hint: "[noms des agents voulus, séparés par des espaces — sinon la question est posée]"
---

## Modèles fournis par le plugin

!`ls "${CLAUDE_PLUGIN_ROOT}/templates/agents" 2>/dev/null | sed 's/\.md$//' || echo "(dossier de modèles introuvable)"`

## Sous-agents actuellement installés dans ce projet

!`ls "$CLAUDE_PROJECT_DIR/.claude/agents" 2>/dev/null | sed 's/\.md$//' || echo "(aucun)"`

## Agents installés dont le contexte n'a jamais été rempli

!`grep -l 'CONTEXTE-PROJET' "$CLAUDE_PROJECT_DIR/.claude/agents"/*.md 2>/dev/null | sed 's|.*/||; s|\.md$||' || echo "(aucun)"`

Sélection demandée par l'utilisateur (prioritaire si renseignée) : $ARGUMENTS

## Ta tâche

Mets la sélection de sous-agents de ce projet en conformité avec ce que veut
l'utilisateur.

### 1. Déterminer la sélection

Si `$ARGUMENTS` est renseigné, c'est la sélection finale : les agents nommés
doivent être présents, les autres retirés.

Sinon, pose la question avec `AskUserQuestion` en `multiSelect: true`, en
reprenant la description de chaque modèle comme explication de son option.

**L'outil n'accepte que quatre options par question.** Avec six modèles, répartis
la sélection sur deux questions — correcteurs de code, puis tenues de
documentation. Précise dans chacune que les agents non retenus seront retirés du
projet.

**Garde-fou contre les doublons de rôle.** Un projet équipé avant le plugin a
souvent déjà un agent qui couvre le rôle d'un modèle, sous un autre nom
(`code-quality` pour `qualite-code`, `security` pour `securite`,
`project-memory` pour `memoire-projet`, `user-guide` pour `guide-utilisateur`).
Compare les rôles, pas les noms : ne propose jamais d'installer un modèle dont le
rôle est déjà tenu. Signale-le à l'utilisateur en une ligne — s'il veut vraiment
remplacer son agent par le modèle, il te le dira.

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

### 3. Adapter les agents qui attendent leur contexte

Cela concerne **deux** groupes : les agents que tu viens de copier, et ceux
listés plus haut comme n'ayant jamais reçu leur contexte — installés à un moment
où le dépôt était encore vide.

Pour chacun, remplace le bloc délimité par `<!-- CONTEXTE-PROJET:DEBUT -->` et
`<!-- CONTEXTE-PROJET:FIN -->` par le contexte réel de ce projet, puis retire les
deux marqueurs.

**Sauf si le projet n'a encore rien à observer** (pas de code, pas de manifeste
de paquets) : dans ce cas, laisse le bloc et ses marqueurs **intacts**. Un
contexte inventé est pire que pas de contexte, et les marqueurs sont ce qui
permettra à une prochaine session de finaliser l'adaptation. Si l'utilisateur
mentionne la pile prévue, consigne-la dans le bloc en la marquant
`(déclarée par l'utilisateur, non vérifiée dans le code)`, sans retirer les
marqueurs.

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

### 4. Hygiène du dépôt

Ajoute la ligne `.claude/.state/` au `.gitignore` du projet si elle n'y est pas
déjà — ce dossier ne contient que de l'état de session, purgé au bout de deux
jours. Crée le fichier s'il n'existe pas. Si le projet n'est pas un dépôt git,
passe cette étape sans rien dire.

### 5. Rapport

Une ligne par agent : installé / conservé / adapté / retiré / ignoré (avec la
raison). Signale explicitement les agents laissés en attente de contexte, et
pourquoi.
Termine en rappelant que la revue se lance avec `/revue` ou `/sous-agents:revue`, et que le rappel
automatique après modification de code est déjà actif.

Si l'utilisateur ne veut aucun agent, crée le fichier vide
`$CLAUDE_PROJECT_DIR/.claude/.state/agents-setup-skipped` pour que la question ne
soit plus posée au démarrage des sessions suivantes, et dis-le-lui.
