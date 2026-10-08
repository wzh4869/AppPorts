# Détection des répertoires d'outils

![](https://pic.cdn.shimoko.com/tools.png)

AppPorts peut détecter automatiquement les répertoires de données (dot-folders) créés par les outils de développement courants, les outils d'IA et les éditeurs dans le répertoire personnel de l'utilisateur, et prend en charge leur migration vers le stockage externe. Pour davantage de besoins de migration d'outils, veuillez les soumettre sur la page [Issues](https://github.com/wzh4869/AppPorts/issues) du projet.

## Niveaux de priorité <a href="#niveaux-de-priorite" id="niveaux-de-priorite"></a>

| Priorité | Signification |
|----------|---------------|
| `critical` | Doit fonctionner après la migration ; affecte les fonctionnalités principales de l'application |
| `recommended` | Économie d'espace importante ; bénéfice de migration élevé |
| `optional` | Taille faible ou reconstituable |

## Outils de développement / Gestionnaires de packages <a href="#outils-de-developpement-gestionnaires-de-packages" id="outils-de-developpement-gestionnaires-de-packages"></a>

| Outil | Chemin | Priorité | Description |
|-------|--------|----------|-------------|
| npm | `~/.npm` | recommended | Cache local du gestionnaire de packages Node.js |
| Maven | `~/.m2` | recommended | Dépôt de dépendances Java Maven |
| Gradle | `~/.gradle` | recommended | Cache de build, Wrapper et données de dépendances Gradle |
| Données de développement Android | `~/.android` | recommended | Configuration et caches Android, ADB et émulateur |
| Flutter/Dart Pub | `~/.pub-cache` | recommended | Cache de packages Pub pour Dart et Flutter |
| Bun | `~/.bun` | recommended | Runtime JavaScript et cache Bun |
| Conda | `~/.conda` | recommended | Données d'environnement Anaconda/Miniconda |
| Composer | `~/.composer` | optional | Packages globaux PHP Composer |
| Nexus | `~/.nexus` | optional | Cache proxy Nexus |

## Outils IA / Apprentissage automatique <a href="#outils-ia-apprentissage-automatique" id="outils-ia-apprentissage-automatique"></a>

| Outil | Chemin | Priorité | Description |
|-------|--------|----------|-------------|
| Ollama | `~/.ollama` | recommended | Stockage de modèles de langage locaux |
| PyTorch | `~/.cache/torch` | recommended | Cache des poids de modèles pré-entraînés |
| Whisper | `~/.cache/whisper` | recommended | Modèles de reconnaissance vocale OpenAI |
| Keras | `~/.keras` | optional | Modèles et jeux de données Keras |
| NLTK | `~/nltk_data` | optional | Corpus de traitement du langage naturel |

## Assistants de codage IA <a href="#assistants-de-codage-ia" id="assistants-de-codage-ia"></a>

| Outil | Chemin | Priorité | Description |
|-------|--------|----------|-------------|
| Lingma | `~/.lingma` | optional | Assistant de codage IA Alibaba Cloud |
| Trae IDE | `~/.trae` | optional | Trae IDE de ByteDance |
| Trae CN | `~/.trae-cn` | optional | Trae IDE version nationale |
| Trae AICC | `~/.trae-aicc` | optional | Trae AICC |
| MarsCode | `~/.marscode` | optional | MarsCode IDE de ByteDance |
| CodeBuddy | `~/.codebuddy` | optional | Assistant IA Tencent |
| CodeBuddy CN | `~/.codebuddycn` | optional | CodeBuddy Tencent version nationale |
| Qwen | `~/.qwen` | optional | Alibaba Tongyi Qianwen |
| ClawBOT | `~/.clawdbot` | optional | Outil IA ClawdBOT |

## Éditeurs / IDE <a href="#editeurs-ide" id="editeurs-ide"></a>

| Outil | Chemin | Priorité | Description |
|-------|--------|----------|-------------|
| VS Code | `~/.vscode` | optional | Extensions et configuration |
| Cursor | `~/.cursor` | optional | Éditeur IA Cursor |
| Spring Tool Suite 4 | `~/.sts4` | optional | Données STS4 |

## Navigateurs / Automatisation de tests <a href="#navigateurs-automatisation-de-tests" id="navigateurs-automatisation-de-tests"></a>

| Outil | Chemin | Priorité | Description |
|-------|--------|----------|-------------|
| Selenium | `~/.cache/selenium` | optional | Pilotes de navigateur téléchargés automatiquement |
| Chromium | `~/.chromium-browser-snapshots` | optional | Instantanés de navigateur utilisés par Playwright/Selenium |
| WDM | `~/.wdm` | optional | Programmes pilotes WebDriver Manager |

## Environnements d'exécution <a href="#environnements-d-execution" id="environnements-d-execution"></a>

| Outil | Chemin | Priorité | Description |
|-------|--------|----------|-------------|
| Docker | `~/.docker` | optional | Configuration et contexte CLI Docker Desktop |
| OpenClaw | `~/.openclaw` | optional | Données de l'outil OpenClaw |

## Répertoires système non migrables <a href="#repertoires-systeme-non-migrables" id="repertoires-systeme-non-migrables"></a>

Les répertoires suivants contiennent des références de chemin absolu ou des fichiers exécutables ; leur migration peut provoquer des défaillances des outils. **Migration non supportée** :

| Chemin | Raison |
|--------|--------|
| `~/.local` | Contient des références de chemin exécutables ; les outils en ligne de commande peuvent échouer après la migration |
| `~/.config` | Contient des configurations de chemin absolu ; les configurations des outils peuvent échouer après la migration |

## Gestion spéciale de la distribution Conda <a href="#gestion-speciale-de-la-distribution-conda" id="gestion-speciale-de-la-distribution-conda"></a>

Quand le Bundle ID ou le nom d'une application contient `anaconda`, `conda` ou `miniconda`, AppPorts analyse supplémentairement les chemins suivants pour identifier la racine d'installation Conda :

- `/opt/anaconda3`
- `/opt/miniconda3`
- `/usr/local/anaconda3`
- `/usr/local/miniconda3`
- `~/anaconda3`
- `~/miniconda3`
