# Réglages

Les réglages d’AppPorts sont accessibles par l’icône d’engrenage en haut à droite de la fenêtre principale.

## Réglages App Store et iOS <a href="#reglages-app-store-et-ios" id="reglages-app-store-et-ios"></a>

| Réglage | Description | Valeur par défaut |
|------|------|------|
| Migration des applications App Store | Autorise la migration des applications App Store. À activer manuellement sous macOS antérieur à 15.1 pour migrer ces applications | Désactivé |
| Migration des applications iOS | Autorise la migration des applications iOS/iPadOS pour Mac | Désactivé |

{% hint style="success" %}
**Utilisateurs de macOS 15.1+**

macOS 15.1 et versions ultérieures permettent l’installation native d’applications App Store sur un stockage externe. Privilégiez « Télécharger et installer les apps volumineuses sur un disque distinct » dans les réglages de l’App Store plutôt que le réglage de migration manuelle d’AppPorts.
{% endhint %}

## Réglages de signature <a href="#reglages-de-signature" id="reglages-de-signature"></a>

| Réglage | Emplacement | Description | Valeur par défaut |
|------|------|------|------|
| Re-signer après la migration | Barre d’outils des répertoires de données, **uniquement en mode classique** | Applique une nouvelle signature Ad-hoc à l’application associée après une migration par lien symbolique | Désactivé |
| Re-signature à la connexion | Réglages | À la connexion, signe de nouveau les applications dont la sauvegarde indique une signature initialement Ad-hoc, pour corriger son invalidation après redémarrage ; ignore les applications en bac à sable, sauf en mode classique | Désactivé pour une nouvelle installation ; reste activé pour les utilisateurs ayant déjà installé l’agent de connexion |

Hors mode classique, aucune commande ne signe de nouveau les applications en bac à sable : elles pourraient ne plus s’ouvrir sous macOS 27. Les données de conteneur utilisent la [migration par montage](datamigrae/mount-migration.md), qui ne nécessite pas de modifier la signature.

Le script de connexion ignore les nouveaux enregistrements accompagnés d’une sauvegarde complète de l’application d’origine. AppPorts vérifie les opérations de signature et remplace les fichiers en toute sécurité. Le script installé est synchronisé au lancement de l’application.

« Re-signature à la connexion » installe le LaunchAgent `com.shimoko.AppPorts.re-sign` et écrit dans le journal par défaut d’AppPorts. La signature et la sauvegarde concernent l’application réelle sur le disque externe, et non le lanceur local. Voir [Signature et prévention des plantages](datamigrae/resign.md).

## Mode classique de migration des données (déconseillé) <a href="#classic-data-migration-mode" id="classic-data-migration-mode"></a>

Ce commutateur, en bas des réglages, est désactivé par défaut. Il est réservé aux utilisateurs qui dépendent déjà de la méthode de la version 1.8.1 et ne peuvent pas encore en changer. Si le disque externe n’est pas APFS, gardez la situation actuelle en laissant les données de conteneur sur ce Mac, au lieu d’activer ce mode pour contourner cette exigence. Voir [Pourquoi le disque externe doit être APFS](why-apfs.md#what-to-do). Avant de l’activer, cochez « Je comprends ces risques » dans la confirmation. Sous macOS 27, un avertissement précise que les applications en bac à sable signées de nouveau peuvent ne plus s’ouvrir. Une fois le mode activé :

| Élément | Désactivé (par défaut) | Activé |
|------|------|------|
| Boutons des répertoires de conteneur | « Migration par montage » uniquement | « Migrate » par lien symbolique et « Migration par montage » |
| Confirmation de nouvelle signature avant migration du conteneur | Absente | Affichée, avec migration seule par défaut |
| Nouvelle signature des applications en bac à sable | Refusée partout | Autorisée après une seconde confirmation expliquant les conséquences |
| Commutateur « Re-signer après la migration » | Masqué | Affiché dans la barre d’outils des répertoires de données |
| « Normaliser », « Relier » et « Détails du lien » pour les conteneurs | Désactivés ; invitation à restaurer avant de migrer par montage | Disponibles |

Le mode classique rétablit entièrement l’ancienne méthode, avec ses risques : les applications en bac à sable signées de nouveau peuvent ne plus s’ouvrir sous macOS 27 et nécessiter une restauration des données puis une réinstallation. AppPorts les marque « Signature remplacée » et vous avertit au lancement ; voir le [guide de mise à niveau vers macOS 27](macos-27.md). Désactiver ce mode ne modifie pas les migrations par lien symbolique existantes. « Restaurer » reste disponible.

## Réglages liés à la migration par montage <a href="#reglages-lies-a-la-migration-par-montage" id="reglages-lies-a-la-migration-par-montage"></a>

Il n’existe pas de réglage distinct pour cette migration. « État de préparation » vérifie l’accès complet au disque, l’emplacement d’AppPorts et le format du stockage externe, puis indique ce qui demande une intervention. À la première migration par montage réussie, AppPorts installe l’agent de connexion `com.shimoko.AppPorts.container-mount` pour remonter les volumes disponibles dans les conteneurs après connexion. Il est désinstallé après restauration du dernier enregistrement de montage. Sur les anciens systèmes comme macOS 12, l’agent ne peut pas afficher le dialogue de mot de passe administrateur ; ouvrez AppPorts après connexion pour terminer le remontage.

## Réglages des journaux <a href="#reglages-des-journaux" id="reglages-des-journaux"></a>

| Réglage | Description | Valeur par défaut |
|------|------|------|
| Activer la journalisation | Écrit les journaux d’exécution dans un fichier | Activé |
| Taille maximale du journal | Supprime la moitié la plus ancienne lorsque la limite est dépassée | 2 MB |
| Emplacement du journal | Chemin du fichier journal | `~/Library/Application Support/AppPorts/AppPorts_Log.txt` |

### Opérations sur les journaux <a href="#operations-sur-les-journaux" id="operations-sur-les-journaux"></a>

| Opération | Description |
|------|------|
| Voir dans le Finder | Ouvre le dossier contenant le journal |
| Exporter le paquet de diagnostic | Produit un ZIP contenant les journaux, les opérations et les informations système |
| Effacer le journal | Efface le contenu du journal actuel |

Pour plus de détails, consultez [Journaux et diagnostic](logging.md).

Avant une sauvegarde, une signature ou une restauration manuelle, AppPorts arrête la tâche de signature en arrière-plan de cette session et attend la fin de ses processus enfants, afin de ne pas écraser une signature qui vient d’être restaurée. La configuration de l’agent est conservée et le réglage s’applique à la prochaine connexion. Si l’arrêt de la tâche ne peut pas être confirmé, l’opération manuelle est interrompue.
