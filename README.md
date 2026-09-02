# Sous-agents de projet — plugin Claude Code

> **English summary** — A Claude Code plugin bundling six ready-to-use subagents:
> code quality, error handling, security, user guide, API reference and project
> memory. On the first session in a project, Claude asks which ones you want,
> copies them into `.claude/agents/`, and fills in their "project context"
> section from the repository itself — so each agent knows your stack, your build
> commands and the folders it must never touch. A `PostToolUse` hook then reads
> that folder at runtime and reminds Claude to invoke the relevant agents after
> every code change; a `Stop` hook catches the turns where it didn't. On an
> existing project, a one-off `/amorcer-docs` pass builds the documentation files
> from the whole repository — or audits the ones already there.
> Hooks are POSIX `sh`, dependency-free (`jq` used when available), and work on
> macOS, Linux and WSL. **The agent prompts, commands and documentation are
> written in French.**
>
> ```
> /plugin marketplace add blaisebarrette/Plugin-Claude-Code---Sub-agents
> /plugin install sous-agents@blaise-plugins
> ```

Six sous-agents prêts à l'emploi, **choisis projet par projet** au premier
lancement, puis rappelés automatiquement après chaque modification de code.

| Agent | Rôle | Écrit dans |
|---|---|---|
| `qualite-code` | doublons, code mort, fuites de ressources, optimisation | le code |
| `error-handling` | validation des entrées, exceptions, codes de retour, valeurs nulles | le code |
| `securite` | failles réellement exploitables (IDOR, injection, SSRF, XSS, fuites, abus de quota) | le code |
| `guide-utilisateur` | référence pour rédiger plus tard un guide utilisateur | `USER_GUIDE.md` |
| `reference-api` | contrats exposés : routes, paramètres, réponses, erreurs | `API_REFERENCE.md` |
| `memoire-projet` | contexte, décisions clés, pièges — à lire en début de session | `PROJECT_MEMORY.md` |

## Installation

```bash
/plugin marketplace add blaisebarrette/Plugin-Claude-Code---Sub-agents
```

```bash
/plugin install sous-agents@blaise-plugins
```

Pour travailler sur le plugin lui-même, on peut aussi pointer la place de marché
vers une copie locale, depuis le dossier **parent** du dépôt :

```bash
/plugin marketplace add "./Plugin Claude code - Sub agents"
```

## Usage

### Premier lancement dans un projet

À l'ouverture d'une session dans un projet dont `.claude/agents/` est absent ou
vide, Claude demande **lesquels des six agents** installer. Les agents retenus
sont copiés dans `.claude/agents/` du projet, et leur section
« Contexte du projet » est remplie à partir du dépôt réel : langages, frameworks,
commandes de build, dossiers à ne pas toucher, conventions d'erreurs.

La question n'est posée **qu'une fois** : dès que `.claude/agents/` contient un
agent, le hook ne fait plus rien. Si vous n'en voulez aucun, le fichier
`.claude/.state/agents-setup-skipped` est créé et la question ne revient pas.

La ligne `.claude/.state/` est ajoutée au `.gitignore` du projet au passage.

### Projet encore vide à l'installation

Un dépôt neuf n'offre rien à observer : dans ce cas les agents sont copiés **sans
être adaptés**, et leur bloc « Contexte du projet » reste en place avec ses
marqueurs. Ils fonctionnent quand même — le bloc leur dit alors de lire les
fichiers concernés avant d'agir plutôt que de supposer des conventions.

Dès que le projet contient du code (seuil : trois fichiers source hors
dépendances), la session suivante propose de finaliser l'adaptation. Un refus
crée `.claude/.state/agents-context-skipped` et la proposition ne revient plus ;
`/agents-setup` reste disponible à tout moment.

Une pile technique annoncée à l'oral n'est jamais écrite comme un fait : elle est
consignée `(déclarée par l'utilisateur, non vérifiée dans le code)` et les
marqueurs restent, pour qu'une vérification ait lieu plus tard.

### Amorçage de la documentation

Les trois agents de documentation travaillent sur un **diff** : ils tiennent un
fichier à jour, mais ne savent ni le construire depuis rien, ni redresser un
fichier écrit avant eux. Un `PROJECT_MEMORY.md` créé à partir d'une modification
isolée documenterait cette modification, pas le projet.

`/amorcer-docs` fait l'autre moitié du travail, avec le dépôt entier pour
périmètre : fichier absent → construit depuis le code ; fichier existant →
audité ligne par ligne, ce qui est faux, invérifiable ou qu'un `grep` donnerait
mieux étant retiré. C'est la commande à lancer sur un projet **déjà en cours**,
qu'il ait ou non une documentation existante.

La première session où un agent de documentation est installé, que le projet a du
code et que la passe n'a jamais eu lieu, Claude la propose — une fois. La passe
faite écrit `.claude/.state/docs-amorcage` ; un refus écrit
`.claude/.state/docs-amorcage-skipped`, et la proposition ne revient plus.

### Après chaque modification de code

Le hook `PostToolUse` lit à chaud le contenu de `.claude/agents/` — aucun nom
n'est codé en dur — et rappelle à Claude d'invoquer ceux dont le périmètre
correspond, dans le bon ordre. Un seul rappel par tour, quelle que soit le nombre
d'éditions.

Le hook `Stop` sert de filet : si du code a été modifié sans revue, il bloque
**une seule fois** la fin du tour et demande `/revue`.

### Commandes

| Commande | Effet |
|---|---|
| `/revue` | passe complète : `error-handling` → `qualite-code` → `securite` en séquence, puis les agents de documentation en parallèle |
| `/agents-setup` | rejouer la sélection : ajouter ou retirer des agents, adapter leur contexte |
| `/amorcer-docs` | passe unique : construire les fichiers de documentation absents, auditer ceux qui existent, à partir du dépôt entier |

`/agents-setup` accepte des noms directement : `/agents-setup securite memoire-projet`.

## Migrer un projet qui a déjà ses propres hooks

Un projet équipé à la main avant le plugin — agents dans `.claude/agents/`, hooks
dans `.claude/settings.json` — se migre dans cet ordre :

1. **Installer le plugin d'abord.** Migrer avant, c'est retirer des hooks qui
   fonctionnent pour n'en mettre aucun à la place.
2. **Garder les agents du projet.** Ils sont déjà adaptés au code, souvent mieux
   que les modèles génériques. Le hook `PostToolUse` lit le dossier à chaud : il
   les listera tels quels, sans rien exiger sur leur nom.
3. **Retirer du `.claude/settings.json` du projet les hooks que le plugin
   remplace** — typiquement l'équivalent de `post-tool-use.sh` et de
   `require-review.sh`. Sinon deux files d'attente s'alimentent en parallèle et
   le tour se fait bloquer deux fois. Les hooks propres au projet (statusline,
   `git fetch` au démarrage, build) restent.
4. **Supprimer la commande `/revue` du projet** si elle existe, pour éviter la
   collision avec celle du plugin — sauf si elle contient des règles spécifiques
   au projet, auquel cas garde la version projet et ignore celle du plugin.
5. **Lancer `/amorcer-docs`** pour auditer les fichiers de documentation
   existants : c'est le seul moyen de redresser un fichier écrit avant le plugin.

Les noms d'agents anglophones courants (`project-memory`, `user-guide`,
`api-reference`) sont reconnus comme équivalents de leurs versions françaises :
aucun renommage n'est nécessaire.

## Structure

```
.claude-plugin/
  plugin.json          métadonnées du plugin
  marketplace.json     permet /plugin install en local
templates/agents/      les 6 modèles (non chargés automatiquement — voir plus bas)
hooks/
  hooks.json           SessionStart · PostToolUse · Stop
  lib.sh               fonctions communes (parsing JSON, échappement, filtres)
  session-start.sh     propose la sélection si le projet n'a pas d'agents
  post-tool-use.sh     file d'attente + rappel d'invocation
  require-review.sh    filet de sécurité en fin de tour
commands/
  agents-setup.md      /agents-setup
  revue.md             /revue
```

### Pourquoi `templates/agents/` et non `agents/`

Claude Code charge automatiquement le dossier `agents/` d'un plugin : les six
agents seraient alors actifs dans **tous** les projets, et choisir n'aurait plus
d'effet. En les gardant dans `templates/`, seuls les agents copiés dans
`.claude/agents/` du projet existent — et ils gardent leur nom court
(`@securite` plutôt que `@sous-agents:securite`).

## Notes techniques

- **Portabilité** : scripts en `sh` POSIX, sans bashisme. Testés sous bash
  (macOS), dash (Debian/Ubuntu/WSL) et zsh. `jq` est utilisé s'il est présent,
  sinon repli automatique sur `sed`/`awk` — aucune dépendance obligatoire.
- **Robustesse** : stdin vide, tronqué ou malformé ⇒ sortie silencieuse en code 0.
  Aucun hook ne peut interrompre une session. Timeouts de 10 s.
- **Anti-boucle** : le rappel est émis une fois par tour utilisateur
  (`prompt_id`) ; le hook `Stop` se désarme via `stop_hook_active` ; les
  éditions dans `.claude/`, les dépendances, les artefacts générés et les trois
  fichiers de documentation produits par les agents ne déclenchent rien.
- **État** : `.claude/.state/` du projet (file d'attente, verrous, marqueurs de
  refus). Purge automatique au-delà de 2 jours ; la ligne `.claude/.state/` est
  ajoutée au `.gitignore` du projet lors de l'installation des agents.

- **Fichiers produits** : `PROJECT_MEMORY.md`, `USER_GUIDE.md` et
  `API_REFERENCE.md` à la racine du projet. Pour changer ces noms, modifiez-les
  dans le modèle d'agent correspondant.

## Adapter un agent après coup

Les agents installés sont de simples fichiers dans `.claude/agents/` du projet :
éditez-les librement, ils appartiennent au projet. Pour modifier le comportement
**par défaut** de tous les futurs projets, éditez le modèle correspondant dans
`templates/agents/` de ce plugin.
