# Pourquoi le disque externe doit être APFS

{% hint style="success" %}
**L’essentiel**

Depuis la version 1.9.0, pour migrer `~/Library/Containers/`, qui contient notamment l’historique WeChat, AppPorts crée un volume dans le conteneur APFS du disque externe et le raccorde directement au répertoire d’origine. Seul un disque APFS le permet. Nous avons essayé une image disque sur exFAT / NTFS : **un débranchement a rendu l’image entière inutilisable**. Cette solution n’est donc pas proposée.

**Si votre disque n’est pas APFS, inutile de le modifier immédiatement.** Les applications et répertoires de données ordinaires peuvent toujours être migrés. Seules les données de conteneur restent sur ce Mac, sans gêner l’utilisation. Pour les migrer plus tard, consultez [Préparer un disque externe APFS](#prepare-apfs). De l’espace libre à l’intérieur d’une partition exFAT ne permet pas forcément de créer directement une nouvelle partition.
{% endhint %}

## Quelles opérations exigent APFS ? <a href="#quelles-operations-exigent-apfs" id="quelles-operations-exigent-apfs"></a>

| Opération | Exigence de format externe |
|---|---|
| Migrer l’application elle-même, son `.app` | Aucune ; exFAT convient aussi |
| Migrer des données ordinaires : `Application Support`, caches, outils comme `~/.npm`, dossiers personnalisés | Aucune |
| Migrer les **données de conteneur** de `~/Library/Containers/` et `~/Library/Group Containers/`, utilisées par WeChat, QQ Music et les applications App Store | **APFS obligatoire** |

Seule la troisième catégorie est concernée, mais elle contient souvent les données les plus volumineuses que l’on souhaite déplacer.

## Pourquoi les données de conteneur sont particulières <a href="#pourquoi-les-donnees-de-conteneur-sont-particulieres" id="pourquoi-les-donnees-de-conteneur-sont-particulieres"></a>

La plupart des applications Mac fonctionnent dans un bac à sable : le système attribue à chacune un dossier réservé sous `~/Library/Containers/`, où elle peut lire et écrire. C’est une protection de macOS, obligatoire pour les applications App Store.

Autrefois, AppPorts copiait le dossier sur le disque externe et laissait un « raccourci », ou lien symbolique, à sa place. Cela fonctionne pour les données ordinaires, mais **n’a jamais réellement fonctionné pour les applications en bac à sable** :

- Le système ne vérifie pas l’emplacement du raccourci, mais **sa destination**. Un disque externe se trouve hors du dossier réservé ; l’accès est refusé.
- L’ancienne méthode semblait fonctionner parce qu’une re-signature retirait l’identité de bac à sable. L’application n’étant plus isolée, elle n’était plus soumise à cette restriction.
- La conséquence apparaît sous macOS 27 : lorsque le système vérifie si l’application a le droit d’accéder au dossier, cette identité ne correspond plus et elle peut quitter une seconde après un double-clic. C’est confirmé pour WeChat ; QQ Music s’ouvre encore. Il faut réinstaller l’application pour réparer. Voir le [guide de mise à niveau vers macOS 27](macos-27.md).

La nouvelle méthode doit donc respecter une règle : **les données doivent être sur le disque externe sans « sortir » du dossier réservé.**

## Comment fonctionne la nouvelle méthode <a href="#comment-fonctionne-la-nouvelle-methode" id="comment-fonctionne-la-nouvelle-methode"></a>

Au lieu d’un raccourci, une partie du disque externe est **montée directement sur le dossier d’origine**. Imaginez que le dossier reste au même endroit, mais que son « plancher » soit remplacé par le disque externe.

- Le chemin vu par l’application reste strictement identique et les vérifications du système passent normalement.
- Aucun octet de signature n’est modifié. La re-signature est inutile et cette méthode ne provoque pas de problème lors d’une future mise à niveau du système.
- Sans le disque externe, le dossier est vide. L’application le voit sans données et n’écrit pas une seconde copie locale.

Pour monter un espace sur un dossier, cet espace doit être un **volume** indépendant. APFS permet **d’ajouter plusieurs volumes dans un même conteneur et de partager son espace libre**, sans fixer leur taille ni repartitionner. AppPorts crée ainsi un volume dédié à chaque répertoire migré. Ajouter un volume n’est pas créer une partition sur le disque physique.

Il est impossible d’ajouter ainsi un volume APFS dans une partition exFAT ou NTFS. Pour conserver ces formats et APFS sur le même disque, APFS a besoin de sa propre partition : utilisez un espace non alloué ou réduisez d’abord la partition existante avec un outil compatible. Sinon, sauvegardez puis repartitionnez. AppPorts ne modifie pas les partitions à votre place.

## Le contournement que nous avons essayé <a href="#le-contournement-que-nous-avons-essaye" id="le-contournement-que-nous-avons-essaye"></a>

Comme beaucoup d’utilisateurs ont des disques exFAT, nous avons envisagé une image disque sparsebundle, du type utilisé par Time Machine sur les disques réseau. L’image contient APFS et peut être montée sur un dossier.

Les premiers essais sur macOS 27 en septembre 2026 semblaient prometteurs :

- Aucun disque APFS nécessaire ; le fichier peut être stocké sur tout format.
- Pas de demande d’accès aux volumes amovibles à la première utilisation, contrairement au volume APFS.
- Performances de lecture et d’écriture similaires au volume APFS.
- Même des applications système comme Aide-mémoire pouvaient l’utiliser, ce que la méthode du volume APFS ne permet pas.

Puis nous avons effectué un essai réaliste : **débrancher pendant une écriture**. Sur une clé USB de 64 GB formatée en APFS, nous avons préparé un volume APFS et une image disque, chacun monté sur un dossier. Deux programmes écrivaient continuellement dans leurs bases, comme WeChat ou QQ Music pour l’historique et les playlists. Après une dizaine de secondes, nous avons débranché puis reconnecté la clé.

| | Écrit avant débranchement | Après reconnexion |
|---|---|---|
| Volume APFS, essai 1, écritures ordinaires | 7177 entrées | Une erreur de corruption de base ; réparation ayant récupéré les 7172 entrées, système de fichiers intact |
| Volume APFS, essai 2, écritures forcées sur disque | 1906 entrées | 1905 entrées intactes, seule la dernière perdue |
| Image disque, essai 1, écritures ordinaires | 25574 entrées | **L’image ne s’ouvre plus**, toutes les données sont inaccessibles |
| Image disque, essai 2, écritures forcées sur disque | 373 entrées | **L’image ne s’ouvre toujours pas** |

La différence n’est pas de perdre un peu plus ou un peu moins, mais quelques entrées ou tout l’accès aux données.

Une image disque se compose de fichiers de 8 MB sur le disque externe. Son propre « catalogue » se trouve dans le premier fichier et est réécrit toutes les quelques secondes. Au débranchement, le disque externe garantit l’intégrité des fichiers eux-mêmes, pas celle d’un contenu interrompu à mi-écriture. Si le catalogue est touché, l’image devient un ensemble de fragments sans répertoire. Forcer les écritures de l’application ne corrige pas cette couche, qui appartient à l’image.

Les utilisateurs de Time Machine sur réseau connaissent parfois le message indiquant que la sauvegarde est endommagée et doit être recréée. C’est le même problème. Une sauvegarde peut être recommencée ; un historique de discussion perdu, non.

Nous avons donc abandonné les images disque après ces essais. Un outil de migration ne peut pas proposer une option où un simple débranchement risque de rendre toutes les données inaccessibles, même si elle est pratique par ailleurs.

## Que faire maintenant ? <a href="#what-to-do" id="what-to-do"></a>

Déterminez d’abord si vous voulez migrer **des données de conteneur**. Sinon, ne changez rien. Si oui, choisissez selon votre disque :

| Situation | Conseil |
|---|---|
| Disque APFS déjà non chiffré | Cliquez sur « Migration par montage » dans « App Data » |
| Disque exFAT / NTFS que vous ne voulez pas modifier | **Garder en l’état** : laissez les données de conteneur sur ce Mac et migrez le reste normalement |
| Autre disque APFS disponible ou disque dédié envisagé | Sélectionnez ce stockage dans AppPorts, puis migrez les données de conteneur |
| Vous souhaitez réserver un espace APFS sur le disque actuel | Suivez [Préparer un disque externe APFS](#prepare-apfs), en sauvegardant d’abord |
| Disque APFS chiffré | Pas encore pris en charge ; voir [Disques externes chiffrés](#encrypted-drives) |

En cas de doute, cliquez une fois sur « Migration par montage » : AppPorts vérifie d’abord le disque en lecture seule et explique la situation sans rien modifier.

**Vérifier le format** : sélectionnez le disque dans Finder, appuyez sur `⌘ I` et consultez « Format ». APFS convient ; ExFAT, NTFS ou Mac OS étendu (HFS+) correspondent au deuxième cas du tableau.

## Préparer un disque externe APFS <a href="#prepare-apfs" id="prepare-apfs"></a>

{% hint style="warning" %}
**Avant toute modification du disque**

Sauvegardez les données avant chacune des méthodes ci-dessous. AppPorts n’efface pas le disque et ne modifie pas les partitions à votre place.
{% endhint %}

**Le disque ne contient rien d’important** : ouvrez Utilitaire de disque, sélectionnez le disque, cliquez sur Effacer, choisissez APFS et Table de partition GUID. L’effacement vide tout le disque.

**Le disque contient des données et vous souhaitez conserver la partition** : vérifiez d’abord qu’il utilise une Table de partition GUID. La capacité disponible affichée dans Finder est l’espace libre **à l’intérieur du système de fichiers, pas l’espace non alloué hors des partitions**.

| Situation actuelle | Préparer de l’espace APFS |
|---|---|
| Conteneur APFS existant | Sélectionnez un de ses volumes dans AppPorts ; les volumes de migration seront ajoutés automatiquement, sans repartitionnement |
| Assez d’espace non alloué utilisable pour une nouvelle partition | Créez une partition APFS dans cet espace sans effacer l’ancienne ; vérifiez la portée des changements dans Utilitaire de disque |
| Une partition exFAT occupe tout le disque | Ni Utilitaire de disque de macOS ni Gestion des disques de Windows ne peuvent réduire exFAT. Avec les outils intégrés, sauvegardez, effacez, repartitionnez puis restaurez les fichiers |
| Partition NTFS sans espace non alloué | macOS ne peut pas réduire NTFS sans perte. Réduisez d’abord NTFS avec Gestion des disques de Windows, puis créez une partition APFS sous macOS dans l’espace libéré. La réduction possible dépend notamment de la disposition des fichiers |
| Partition Mac OS étendu journalisé (HFS+) ou conteneur APFS | macOS permet une réduction sans perte si l’espace et la disposition des partitions s’y prêtent, puis la création d’une partition APFS. Sauvegardez tout de même d’abord |

Si le disque n’utilise pas une Table de partition GUID, n’appliquez pas directement ces instructions : sauvegardez et repartitionnez d’abord avec ce schéma. Une fois prêt, choisissez le volume APFS comme stockage externe dans AppPorts.

Références : `resizeVolume` dans `man diskutil` exige **journaled HFS+** ; APFS utilise `apfs resizeContainer`. La [documentation Microsoft sur la réduction d’un volume de base](https://learn.microsoft.com/en-us/windows-server/storage/disk-management/shrink-a-basic-volume) indique NTFS ou un volume sans système de fichiers, pas exFAT. La capacité d’un outil tiers à réduire exFAT sans perte doit être vérifiée séparément et n’est pas une fonction intégrée du système.

**Le disque doit aussi fonctionner sous Windows** : Windows ne lit ni n’écrit APFS par défaut. Utilisez deux partitions, exFAT pour Windows et APFS pour AppPorts. Si exFAT occupe tout le disque, les outils intégrés ne peuvent pas en extraire directement une partition APFS : sauvegardez puis repartitionnez.

## Disques externes chiffrés <a href="#encrypted-drives" id="encrypted-drives"></a>

La migration crée un volume dans le conteneur APFS externe, et ce volume **n’hérite pas** du mot de passe d’origine. Un historique auparavant protégé localement par FileVault se retrouverait alors sur un volume lisible par toute personne branchant le disque. Tant que le déverrouillage automatique à la connexion et la gestion des mots de passe ne sont pas prêts, AppPorts ne propose pas cette migration sur un disque APFS chiffré et ne crée pas discrètement un volume non chiffré.

Vos options :

- **Garder en l’état** : laissez les données de conteneur sur ce Mac, toujours protégées par FileVault.
- **Utiliser un disque ou une partition APFS non chiffré** : migrez en sachant que ces données ne seront pas chiffrées sur le disque externe.

## Mode classique de migration des données <a href="#mode-classique-de-migration-des-donnees" id="mode-classique-de-migration-des-donnees"></a>

Le mode classique des réglages rétablit les liens symboliques et la re-signature de la version 1.8.1. Il n’exige pas APFS, mais conserve tous les risques : applications en bac à sable qui ne s’ouvrent plus sous macOS 27, sessions perdues. Il reste disponible uniquement pour les utilisateurs qui dépendent déjà de cette méthode. **Ne l’activez pas simplement pour contourner l’exigence APFS.** Voir les [réglages](settings.md#classic-data-migration-mode).

## Questions fréquentes <a href="#questions-frequentes" id="questions-frequentes"></a>

### Que faire des données de conteneur déjà migrées sur exFAT ? <a href="#que-faire-des-donnees-de-conteneur-deja-migrees-sur-exfat" id="que-faire-des-donnees-de-conteneur-deja-migrees-sur-exfat"></a>

L’ancienne migration utilisait un lien et une re-signature, indépendamment du format du disque. Le problème est la signature, pas le format. Suivez le [guide macOS 27](macos-27.md), puis [préparez un disque APFS](#prepare-apfs) si vous souhaitez conserver les données sur un disque externe.

### Pourquoi ne pas proposer « J’accepte le risque » sur exFAT ? <a href="#pourquoi-ne-pas-proposer-«-j-accepte-le-risque-»-sur-exfat" id="pourquoi-ne-pas-proposer-«-j-accepte-le-risque-»-sur-exfat"></a>

Le risque n’est pas une petite perte occasionnelle, mais la perte de tout l’accès aux données après un débranchement, une opération courante avec un disque portable. Une fois l’historique perdu, rappeler qu’un avertissement existait ne sert à rien.

### APFS change-t-il les performances ? <a href="#apfs-change-t-il-les-performances" id="apfs-change-t-il-les-performances"></a>

Non : APFS est le format natif de macOS et est généralement plus rapide qu’exFAT sur SSD. Dans nos essais sur la même clé USB, les écritures de base de données sur le volume APFS étaient environ dix fois plus rapides que directement sur exFAT.

### HFS+ (Mac OS étendu) convient-il ? <a href="#hfs-mac-os-etendu-convient-il" id="hfs-mac-os-etendu-convient-il"></a>

Pas directement pour la migration par montage. HFS+ n’offre pas le partage d’espace entre plusieurs volumes d’APFS. Toutefois, les outils de macOS peuvent réduire sans perte une partition HFS+ journalisée pour créer une partition APFS si les conditions sont réunies, contrairement à exFAT. Sauvegardez d’abord et consultez [Préparer un disque externe APFS](#prepare-apfs).

## Documents associés <a href="#documents-associes" id="documents-associes"></a>

- [Migration par montage](datamigrae/mount-migration.md) : utiliser la nouvelle méthode
- [Expérience : débranchement](https://app.gitbook.com/s/XSPACE_EN/research/unplug-test) : données brutes des essais
- [Guide de mise à niveau vers macOS 27](macos-27.md) : pourquoi l’ancienne méthode échoue sous 27
- [Guide du stockage externe](storage-guide.md) : interfaces, capacité et systèmes de fichiers
