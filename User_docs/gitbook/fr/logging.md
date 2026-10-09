---
icon: "file-lines"
layout:
  width: "default"
  outline:
    visible: true
---

# Journalisation et diagnostic

AppPorts dispose d'un système de journalisation intégré qui enregistre les événements clés, les opérations de migration, les informations système et les détails d'erreur pendant l'exécution de l'application. En cas de problèmes, vous pouvez exporter un paquet de diagnostic et le soumettre sur la page [Issues](https://github.com/wzh4869/AppPorts/issues) du projet pour le dépannage.

## Contenu journalisé <a href="#contenu-journalise" id="contenu-journalise"></a>

### Informations de session de démarrage <a href="#informations-de-session-de-demarrage" id="informations-de-session-de-demarrage"></a>

Les informations suivantes sont enregistrées à chaque démarrage de l'application :

| Élément | Description |
|---------|-------------|
| ID de session | Identifiant unique pour cette exécution (préfixe UUID de 8 caractères) |
| ID de processus | Identifiant de processus système |
| Bundle ID | Identifiant de l'application |
| Langue de l'application | Code de langue actuellement sélectionné |
| Paramètres régionaux système | Identifiant des paramètres régionaux système |
| Fuseau horaire | Identifiant du fuseau horaire actuel |
| Liste de langues préférées | Ordre des langues préférées du système |

### Informations de diagnostic système <a href="#informations-de-diagnostic-systeme" id="informations-de-diagnostic-systeme"></a>

| Élément | Description |
|---------|-------------|
| Version de l'application | Numéro de version et numéro de build |
| Version de macOS | Version du système et nom commercial (par ex., « macOS Sequoia 15.x ») |
| Modèle de l'appareil | Modèle et nom convivial (par ex., « MacBook Pro (14-inch, M3 Pro, 2023) ») |
| Informations processeur | Chaîne de marque, nombre de cœurs, nombre de cœurs actifs |
| Mémoire physique | Mémoire totale |

### Informations de stockage externe <a href="#informations-de-stockage-externe" id="informations-de-stockage-externe"></a>

Enregistrées lors de la sélection d'un volume de stockage externe :

| Élément | Description |
|---------|-------------|
| Nom du volume | Nom du volume de stockage |
| Capacité totale / Espace disponible | Informations d'espace de stockage |
| Format du système de fichiers | Par ex., APFS, HFS+, exFAT, etc. |
| Protocole d'interface | USB, Thunderbolt, NVMe/SATA |
| Vitesse de l'appareil | Informations de taux de transfert |
| Taille de bloc | Taille de bloc de stockage |
| UUID du volume | Identifiant unique du volume de stockage |

### Événements d'opération de migration <a href="#evenements-d-operation-de-migration" id="evenements-d-operation-de-migration"></a>

Chaque opération de migration génère un ID d'opération unique (par ex., `data-migrate-ABCD1234`), enregistrant :

- Début et fin de l'opération
- Progression de chaque étape (copie, suppression du répertoire original, création du lien symbolique, annulation)
- Instantanés de l'état du chemin avant et après les étapes (existence, permissions, taille, cible du symlink, drapeau immuable)
- Détection de données de migration résiduelles et récupération automatique
- Progression de la copie de fichiers, erreurs et réessais

### Rapports de performance de migration <a href="#rapports-de-performance-de-migration" id="rapports-de-performance-de-migration"></a>

| Élément | Description |
|---------|-------------|
| Nom de l'application | Nom de l'application migrée |
| Taille des données | Volume de données migré |
| Durée | Durée de la migration (secondes) |
| Vitesse de transfert | Taux de transfert (MB/s) |
| Chemin source / Chemin de destination | Chemins de début et fin de la migration |

### Détails des erreurs <a href="#details-des-erreurs" id="details-des-erreurs"></a>

Les journaux d'erreur contiennent des informations structurées :

| Champ | Description |
|-------|-------------|
| Description de l'erreur | Description d'erreur lisible par l'humain |
| Type / Domaine / Code d'erreur | Informations structurées NSError |
| Code d'erreur | Code d'erreur interne AppPorts (voir tableau ci-dessous) |
| Raison de l'échec | Raison détaillée de l'échec |
| Suggestion de récupération | Suggestion de récupération fournie par le système |
| Chemin du fichier | Chemin du fichier affecté |
| Chemins associés | Chemins d'applications associés à l'opération (`relatedURLs`) |
| Erreur sous-jacente | Erreur imbriquée enregistrée récursivement |

### Codes d'erreur <a href="#codes-d-erreur" id="codes-d-erreur"></a>

| Code d’erreur | Signification |
|--------|------|
| `BACKUP-SIGNATURE-FAILED` | Échec de la sauvegarde de signature |
| `APP-MOVE-DESTINATION-CONFLICT` | La destination de migration de l’application existe déjà et son remplacement ne peut pas être confirmé comme sûr |
| `APP-RESTORE-LOCAL-CONFLICT` | Un élément local de même nom ne peut pas être écrasé automatiquement lors du retour sur le Mac |
| `DATA-MIGRATE-DESTINATION-CONFLICT` | La destination de migration du répertoire existe déjà et ses métadonnées ne correspondent pas entièrement |
| `RESIGN-FAILED` | Échec de la nouvelle signature ; l’application peut échouer à la vérification de signature de macOS |
| `DATA-RESIGN-FAILED` | Échec de la nouvelle signature automatique après migration du répertoire de données |
| `RESIGN-REFUSED-SANDBOXED` | Nouvelle signature refusée pour une application en bac à sable |
| `RESTORE-SIGNATURE-IDENTITY-UNAVAILABLE` | Certificat de signature d’origine absent de ce Mac ; restauration refusée |
| `CONTAINER-MOUNT-*` | Échec à une étape de migration par montage, par exemple `CONTAINER-MOUNT-EXTERNAL-NOT-APFS` ou `CONTAINER-MOUNT-SWITCH-FAILED` |
| `CONTAINER-RESTORE-*` | Échec à une étape de restauration d’un répertoire migré par montage |
| `DATA-BACKUP-SIGNATURE-FAILED` | Échec de la sauvegarde de signature avant migration du répertoire de données ; une restauration ultérieure ne pourra pas utiliser l’identité d’origine |


### Contexte des opérations de répertoire de données <a href="#contexte-des-operations-de-repertoire-de-donnees" id="contexte-des-operations-de-repertoire-de-donnees"></a>

Les opérations sur les répertoires de données (migration, restauration, normalisation, re-liage) incluent automatiquement les informations de contexte de l'application associée dans les journaux :

| Champ | Description |
|-------|-------------|
| `app_name` | Nom de l'application associée |
| `app_status` | Statut de l'application (« Lié », « Local », etc.) |
| `app_is_resigned` | Si l'application a été re-signée |
| `app_bundle_id` | Bundle ID de l'application (lu depuis le vrai chemin) |
| `app_real_path` | Vrai chemin externe de l'application |

### Résumé des opérations <a href="#resume-des-operations" id="resume-des-operations"></a>

Chaque opération de migration génère un `OperationSummaryRecord`, conservant les 100 enregistrements les plus récents :

| Champ | Description |
|-------|-------------|
| `operationID` | Identifiant unique de l'opération |
| `category` | Catégorie d'opération (`app_move`, `data-migrate`, `file-copy`, etc.) |
| `result` | Résultat (`success`, `failed`, `rolled_back`, `success_with_warning`) |
| `errorCode` | Code d'erreur (le cas échéant) |
| `startedAt` / `endedAt` | Heure de début et de fin |
| `durationMs` | Durée (millisecondes) |

## Configuration des journaux <a href="#configuration-des-journaux" id="configuration-des-journaux"></a>

### Emplacement de stockage <a href="#emplacement-de-stockage" id="emplacement-de-stockage"></a>

Chemin par défaut du journal :

```text
~/Library/Application Support/AppPorts/AppPorts_Log.txt
```

Peut être personnalisé via :

- Barre de menus → Journaux → Définir l'emplacement du journal...
- Paramètres → Paramètres du journal → chemin personnalisé

### Format du journal <a href="#format-du-journal" id="format-du-journal"></a>

```text
[2026-05-08 09:30:00] [INFO] [session:a1b2c3d4] [pid:12345] 应用启动
[2026-05-08 09:30:01] [DIAG] [session:a1b2c3d4] [pid:12345]   app_version: 1.6.1 (123)
[2026-05-08 09:30:05] [PERF] [session:a1b2c3d4] [pid:12345]   迁移完成: 2.3 GB, 45.2 MB/s, 52.1s
```

### Niveaux de journal <a href="#niveaux-de-journal" id="niveaux-de-journal"></a>

| Niveau | Description |
|--------|-------------|
| `INFO` | Informations générales |
| `ERROR` | Informations d'erreur (avec détails d'erreur structurés) |
| `DIAG` | Informations de diagnostic système |
| `DISK` | Informations de volume de stockage externe |
| `PERF` | Rapport de performance de migration |
| `TRACE` | État de chemin de bas niveau et surveillance de dossiers |
| `DEBUG` | Informations de débogage (calcul de taille, vérifications de répertoires imbriqués) |
| `WARN` | Avertissements (données de migration résiduelles, mode de récupération) |

### Rotation des journaux <a href="#rotation-des-journaux" id="rotation-des-journaux"></a>

- Taille maximale par défaut : **2 MB** (configurable : 1 MB, 5 MB, 10 MB, 50 MB, 100 MB)
- Troncation automatique en cas de dépassement : Supprime la moitié la plus ancienne des lignes, conserve la moitié la plus récente

## Exporter le paquet de diagnostic <a href="#exporter-le-paquet-de-diagnostic" id="exporter-le-paquet-de-diagnostic"></a>

Lorsque des problèmes nécessitent un retour, veuillez exporter un paquet de diagnostic et le joindre à l'Issue.

### Méthodes d'exportation <a href="#methodes-d-exportation" id="methodes-d-exportation"></a>

**Méthode 1 : Barre de menus**

1. Cliquer sur Barre de menus → Journaux → Exporter le paquet de diagnostic
2. Choisir l'emplacement de sauvegarde
3. Le système génère automatiquement un fichier `.zip` et l'ouvre dans le Finder

**Méthode 2 : Page des réglages**

1. Ouvrir AppPorts → Paramètres (coin supérieur droit)
2. Trouver la section « Paramètres du journal »
3. Cliquer sur le bouton « Exporter le paquet de diagnostic »
4. Choisir l'emplacement de sauvegarde

### Contenu du paquet de diagnostic <a href="#contenu-du-paquet-de-diagnostic" id="contenu-du-paquet-de-diagnostic"></a>

Le fichier `AppPorts-Diagnostic-<日期时间>.zip` exporté contient :

| Fichier | Format | Description |
|---------|--------|-------------|
| `diagnostic-summary.json` | JSON | Métadonnées (ID de session, version, paramètres régionaux, fuseau horaire, etc.) |
| `diagnostic-summary.txt` | Texte brut | Résumé de diagnostic lisible par l'humain |
| `recent-operations.json` | JSON | 100 enregistrements d'opérations les plus récents |
| `recent-failures.json` | JSON | 20 opérations échouées/avec avertissement les plus récentes |
| `AppPorts_Log.share-safe.txt` | Texte brut | Journal complet (anonymisé) |

### Protection de la vie privée <a href="#protection-de-la-vie-privee" id="protection-de-la-vie-privee"></a>

Les fichiers journaux du paquet de diagnostic sont anonymisés :

| Contenu original | Remplacé par |
|------------------|--------------|
| Chemin du répertoire personnel de l'utilisateur (par ex., `/Users/john`) | `/Users/<redacted-user>` |
| Nom du volume de stockage externe (par ex., `/Volumes/MyDrive`) | `/Volumes/<redacted-volume>` |
| Chemin complet `$HOME` | `~` |

## Soumettre des Issues <a href="#soumettre-des-issues" id="soumettre-des-issues"></a>

Après avoir obtenu le paquet de diagnostic, suivez ces étapes pour soumettre :

1. Visiter la page [Issues](https://github.com/wzh4869/AppPorts/issues) du projet
2. Cliquer sur « New Issue », sélectionner le modèle de rapport de bug
3. Décrire le problème et les étapes de reproduction
4. Glisser le fichier `.zip` de diagnostic dans la zone des pièces jointes pour le joindre
5. Soumettre l'Issue

{% hint style="success" %}
**💡 Améliorer l'efficacité des retours**

Soumettre des Issues avec des paquets de diagnostic peut accélérer significativement la résolution des problèmes. Le paquet de diagnostic contient l'historique complet des opérations, les détails d'erreur et les informations d'environnement système, permettant aux développeurs de reproduire et analyser les problèmes sans communication répétée.
{% endhint %}
