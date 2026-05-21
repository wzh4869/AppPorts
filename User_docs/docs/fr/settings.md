---
outline: deep
---

# Réglages

La page des réglages d'AppPorts est accessible via l'icône d'engrenage en haut à droite de la fenêtre principale.

## Réglages App Store et iOS

| Réglage | Description | Défaut |
|---------|-------------|--------|
| Migration des applications App Store | Autorise la migration des applications App Store. Doit être activé manuellement sur les versions macOS inférieures à 15.1 | Désactivé |
| Migration des applications iOS | Autorise la migration des applications iOS/iPadOS (version Mac) | Désactivé |

::: tip 💡 Utilisateurs de macOS 15.1+
macOS 15.1 et ultérieur supportent l'installation native d'applications App Store sur des disques externes. Il est recommandé d'activer « Télécharger et installer les grandes applications sur un disque externe » dans les réglages de l'App Store plutôt que d'utiliser le commutateur de migration d'AppPorts.
:::

## Réglages de signature

| Réglage | Description | Défaut |
|---------|-------------|--------|
| Re-signature automatique | Exécute automatiquement la re-signature Ad-hoc sur les applications associées après la migration du répertoire de données | Désactivé |
| Re-signature à la connexion | Re-signe automatiquement les applications migrées avec des signatures expirées à chaque connexion de l'utilisateur | Activé |

Quand activé, chaque migration de répertoire de données sauvegarde automatiquement la signature originale et exécute la re-signature pour éviter les messages « Endommagé » après la migration. La re-signature à la connexion utilise un LaunchAgent de macOS pour s'exécuter automatiquement en arrière-plan à chaque connexion de l'utilisateur, garantissant que les signatures expirées sont renouvelées sans intervention manuelle.

::: tip 💡 Re-signature automatique pour les applications liées
Pour les applications liées (statut : « Liée »), la re-signature automatique résout automatiquement le **vrai chemin de l'application externe** derrière le shell Stub Portal ou le lien symbolique, garantissant que les changements de signature sont appliqués au vrai package d'application. La sauvegarde et la re-signature sont identifiées par le Bundle ID de la vraie application.
:::

## Réglages de journalisation

| Réglage | Description | Défaut |
|---------|-------------|--------|
| Activer la journalisation | Écrit les journaux d'exécution dans un fichier | Activé |
| Taille maximale du journal | Tronque automatiquement la moitié la plus ancienne quand le fichier journal dépasse cette taille | 2 Mo |
| Emplacement du journal | Chemin de sauvegarde du fichier journal | `~/Library/Application Support/AppPorts/AppPorts_Log.txt` |

### Opérations sur les journaux

| Opération | Description |
|-----------|-------------|
| Voir dans le Finder | Ouvre le répertoire contenant le fichier journal |
| Exporter le package de diagnostic | Génère un fichier ZIP contenant les journaux, les enregistrements d'opérations et les informations système |
| Effacer le journal | Efface le contenu actuel du fichier journal |

Pour des descriptions détaillées des journaux, voir [Journalisation et diagnostic](/fr/logging).
