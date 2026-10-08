# Contribuer

Merci de votre intérêt pour AppPorts ! Nous accueillons les membres de la communauté pour contribuer, qu'il s'agisse de corriger des bugs, d'améliorer la documentation ou d'ajouter de nouvelles fonctionnalités.

## Avant de commencer <a href="#avant-de-commencer" id="avant-de-commencer"></a>

1. Rechercher les [Issues](https://github.com/wzh4869/AppPorts/issues) existants pour confirmer l'absence de doublons
2. Forker le projet et cloner localement
3. Créer une branche de fonctionnalité (`feat/votre-fonctionnalité`) ou de correction (`fix/votre-correction`) basée sur la branche `develop`

## Approche de développement <a href="#approche-de-developpement" id="approche-de-developpement"></a>

### À propos du Vibe Coding <a href="#a-propos-du-vibe-coding" id="a-propos-du-vibe-coding"></a>

Le projet AppPorts accepte le développement Vibe Coding utilisant des outils assistés par IA (par ex., Cursor, GitHub Copilot, Claude). Nous comprenons que les outils d'IA peuvent améliorer significativement l'efficacité du développement, **mais la qualité et la correction du code soumis sont la responsabilité du contributeur**.

Lors de l'utilisation du Vibe Coding :

- **Les assistants IA doivent suivre le fichier `CLAUDE.md` à la racine du projet**, qui définit les directives de codage, les conventions d'architecture, les commandes de build et le flux de travail de développement. Si l'assistant IA ne lit pas automatiquement ce fichier, demandez-lui explicitement de lire `CLAUDE.md` d'abord dans vos prompts
- Envisagez de valider de manière croisée la qualité et la sécurité du code généré avec plusieurs modèles d'IA pour éviter les angles morts d'un modèle unique
- Le code généré par IA peut ne pas correspondre au style existant du projet ; veuillez le réviser manuellement avant la soumission
- L'IA ne peut pas remplacer la compréhension du comportement du système macOS ; veuillez vérifier manuellement la logique impliquant les opérations de système de fichiers, la signature de code et la gestion des permissions
- Les changements de **fonctionnalités principales** (par ex., stratégies de migration, migration des répertoires de données, signature de code) doivent d'abord être discutés via Issue avant le développement

### Conventions de code <a href="#conventions-de-code" id="conventions-de-code"></a>

- Suivre les conventions de code Swift et le style existant du projet
- Écrire des commentaires de documentation Swift clairs pour la logique complexe
- Les littéraux de chaîne SwiftUI utilisent l'API `LocalizedStringKey` ; les chaînes AppKit/API utilisent `.localized`

## Exigences de test <a href="#exigences-de-test" id="exigences-de-test"></a>

{% hint style="warning" %}
**⚠️ Tous les PR doivent passer les tests**

Quelle que soit la méthode de développement, les tests suivants doivent être complétés avant de soumettre un PR. Le CI exécute automatiquement des vérifications de compilation ; les PR non validés seront bloqués pour la fusion.
{% endhint %}

### Requis : Vérification de compilation <a href="#requis-verification-de-compilation" id="requis-verification-de-compilation"></a>

Tous les PR doivent passer la compilation Xcode Release — c'est une exigence stricte pour la fusion :

```bash
xcodebuild clean build \
  -scheme "AppPorts" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

### À la demande : Tests spécialisés <a href="#a-la-demande-tests-specialises" id="a-la-demande-tests-specialises"></a>

Quand un PR implique les modules correspondants, il est recommandé d'exécuter proactivement les tests spécialisés suivants. Le CI les exécute aussi en mode Consultatif dans les PR ; les résultats ne bloquent pas la fusion mais fournissent des retours.

#### Tests de répertoires de données <a href="#tests-de-repertoires-de-donnees" id="tests-de-repertoires-de-donnees"></a>

Exécuter quand le PR implique `DataDirMover`, `DataDirScanner` ou la logique de migration des répertoires de données :

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/DataDirMoverTests" \
  -only-testing:"AppPortsTests/DataDirScannerTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

#### Tests de migration d'applications <a href="#tests-de-migration-d-applications" id="tests-de-migration-d-applications"></a>

Exécuter quand le PR implique `AppMigrationService`, `AppScanner` ou la logique de migration d'applications :

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/AppMigrationServiceTests" \
  -only-testing:"AppPortsTests/AppScannerTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

#### Tests de journalisation <a href="#tests-de-journalisation" id="tests-de-journalisation"></a>

Exécuter quand le PR implique `AppLogger` ou la fonctionnalité de diagnostic :

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/AppLoggerTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

#### Audit de localisation <a href="#audit-de-localisation" id="audit-de-localisation"></a>

Exécuter quand le PR implique du texte visible par l'utilisateur, des menus, des popups, des réglages ou des messages d'erreur :

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/LocalizationAuditTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

### Vue d'ensemble des tests <a href="#vue-d-ensemble-des-tests" id="vue-d-ensemble-des-tests"></a>

| Suite de tests | Modules | Quand exécuter |
|----------------|---------|----------------|
| Vérification de compilation | Projet entier | **Requis** (imposé par le CI) |
| `DataDirMoverTests` | Migration des répertoires de données | Quand impliquant `DataDirMover` |
| `DataDirScannerTests` | Analyse des répertoires de données | Quand impliquant `DataDirScanner` |
| `AppMigrationServiceTests` | Migration d'applications | Quand impliquant `AppMigrationService` |
| `AppScannerTests` | Analyse d'applications | Quand impliquant `AppScanner` |
| `AppLoggerTests` | Journalisation et diagnostic | Quand impliquant `AppLogger` |
| `LocalizationAuditTests` | Localisation | Quand impliquant du texte visible par l'utilisateur |

## Localisation <a href="#localisation" id="localisation"></a>

- L'adaptation de la localisation est recommandée mais pas obligatoire pour les PR de contributeurs externes
- Si un PR ajoute, modifie ou supprime du texte visible par l'utilisateur, vous êtes invité à mettre à jour `Localizable.xcstrings` dans le même PR
- Si vous ne le traitez pas cette fois, veuillez expliquer brièvement la raison ou le plan futur dans la description du PR
- Les littéraux de chaîne SwiftUI utilisent l'API `LocalizedStringKey` ; les chaînes AppKit/API utilisent `.localized`
- Le texte dynamique doit utiliser des clés formatées, par ex., `String(format: "Trier : %@".localized, value)`
- La liste des langues est maintenue dans `AppLanguageCatalog` ; ne pas dupliquer sur plusieurs pages
- Si un PR modifie les menus, popups, réglages, exports de journaux, messages d'erreur, textes de statut ou textes d'accueil, il est recommandé de vérifier au moins les résultats d'affichage `zh-Hans` et `en`

Plus de règles voir : [LOCALIZATION.md](https://github.com/wzh4869/AppPorts/blob/main/LOCALIZATION.md)

## Conventions de commit <a href="#conventions-de-commit" id="conventions-de-commit"></a>

- **Issue d'abord** : Les changements de fonctionnalités importantes doivent d'abord être discutés via Issue
- **Garder atomique** : Chaque PR devrait idéalement ne traiter qu'un seul problème ou ajouter une seule fonctionnalité
- **Suggestions de message de commit** :
  - `feat: ...` — Nouvelle fonctionnalité
  - `fix: ...` — Correction de bug
  - `docs: ...` — Mise à jour de documentation
  - `refactor: ...` — Refactorisation
  - `test: ...` — Lié aux tests

## Soumettre un PR <a href="#soumettre-un-pr" id="soumettre-un-pr"></a>

1. S'assurer que votre branche est basée sur la dernière branche `develop`
2. Pousser vers votre dépôt Fork
3. Soumettre un Pull Request vers la branche `develop` d'AppPorts
4. Remplir les éléments requis dans le modèle de PR
5. Attendre que les vérifications du CI passent et la revue de code

{% hint style="success" %}
**💡 Améliorer l'efficacité de la fusion**

- Garder chaque PR concentré sur un seul problème ou fonctionnalité
- Remplir honnêtement la situation des tests dans le modèle de PR
- Inclure des captures d'écran pour les changements d'interface
{% endhint %}

## Domaines de contribution bienvenus <a href="#domaines-de-contribution-bienvenus" id="domaines-de-contribution-bienvenus"></a>

- Améliorations de stabilité et de performance pour la logique principale comme `AppScanner`
- Optimisation UI/UX, en particulier les améliorations qui se sentent natives à macOS
- Synchronisation et amélioration de la documentation chinoise et anglaise
