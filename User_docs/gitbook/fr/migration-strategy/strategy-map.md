---
icon: "table-list"
description: "Trouvez la stratégie de migration correspondant à chaque type d’application."
layout:
  width: "default"
  outline:
    visible: true
---

# Types d'applications et stratégies

| Type d'application | Classification du conteneur | Stratégie de migration | Protection par verrouillage | Notes |
|---------------------|----------------------------|------------------------|-----------------------------|-------|
| Application macOS native (sans mise à jour auto) | `standaloneApp` | macOS Stub Portal | Non | Par ex., Safari, Finder |
| Application avec mise à jour auto Sparkle | `standaloneApp` | macOS Stub Portal | **Oui** | Par ex., certaines applications de développeurs indépendants |
| Application Electron (sans `app-update.yml`) | `standaloneApp` | macOS Stub Portal | Non | Par ex., VS Code |
| Application Electron (avec `app-update.yml`) | `standaloneApp` | macOS Stub Portal | **Oui** | Par ex., Slack, Discord |
| Application hybride Electron + Sparkle | `standaloneApp` | macOS Stub Portal | **Oui** | Les deux indicateurs détectés indépendamment |
| Applications avec mise à jour auto personnalisée (Chrome, Edge) | `standaloneApp` | macOS Stub Portal | Non | Identifiées via `LaunchServices`, `KSProductID`, etc. |
| Application iOS (version Mac) | `standaloneApp` | iOS Stub Portal | Non | Icônes extraites de `WrappedBundle` ; pas de signature |
| Application Mac App Store | `standaloneApp` | macOS Stub Portal | Non | Protection SIP ; ne peut pas être re-signée |
| Répertoire de conteneur d'application unique | `singleAppContainer` | Whole App Symlink | Non | Répertoire avec seulement 1 `.app` ; symlink entier |
| Répertoire de suite d'applications (par ex., Office) | `appSuiteFolder` | Whole App Symlink | Dépend des applications internes | Répertoire avec 2+ `.app` ; symlink entier |
| Chemin non `.app` | — | Whole App Symlink | — | Chemin avec extension autre que `.app` |

{% hint style="warning" %}
**⚠️ À propos de la protection par verrouillage**

Quand une application est marquée comme nécessitant un verrouillage (`needsLock = true`), AppPorts exécute `chflags -R uchg` sur l'application externe après la fin de la migration, définissant le drapeau immuable. Cela empêche les mises à jour automatiques de supprimer ou modifier la copie externe, mais signifie aussi que l'application ne peut pas se mettre à jour automatiquement. Les utilisateurs doivent déverrouiller manuellement dans AppPorts avant de mettre à jour.
{% endhint %}

{% hint style="success" %}
**💡 Pourquoi les applications avec mise à jour auto personnalisée ne sont pas verrouillées**

Les applications utilisant des mises à jour automatiques personnalisées comme Chrome et Edge ne sont pas verrouillées. Les programmes de mise à jour de ces applications installent généralement les nouvelles versions sur le stockage interne local. En raison des caractéristiques d'isolation de liaison de macOS Stub Portal, cela n'endommage pas les fichiers de l'application sur le stockage externe.

Quand AppPorts détecte que la version de l'application sur le stockage interne local est supérieure à celle sur le stockage externe, il marque automatiquement l'application avec « Migration sortante en attente », incitant l'utilisateur à re-migrer pour synchroniser la dernière version.
{% endhint %}
