# Migration par montage : placer les données de conteneur sur un disque externe

{% hint style="success" %}
**L’essentiel**

Les données de `~/Library/Containers/` et `~/Library/Group Containers/`, comme l’historique WeChat, le cache QQ Music et les données des applications App Store, ne peuvent pas être déplacées par lien symbolique. Depuis AppPorts 1.9.0, un volume de données APFS dédié est créé sur le disque externe. Les données y sont copiées, puis le volume est **monté sur le répertoire d’origine**. Le chemin vu par l’application et sa signature restent identiques.

Trois conditions : un disque APFS non chiffré, accepter l’autorisation à la première ouverture de l’application et connecter le disque avant de l’utiliser.
{% endhint %}

## Quand cette méthode s’applique <a href="#quand-cette-methode-s-applique" id="quand-cette-methode-s-applique"></a>

Dans « Répertoires de données » → « App Data », sélectionnez une application. Pour les répertoires des groupes `Containers` et `Group Containers`, le bouton affiche « Migration par montage » au lieu de « Migrate ». Les autres groupes, comme `Application Support` et les caches, ainsi que les répertoires d’outils et personnalisés, continuent à utiliser les liens symboliques.

Pour comprendre pourquoi les conteneurs sont particuliers et pourquoi le bac à sable du programme principal n’est pas le critère, consultez [Données de conteneur, bac à sable et identité de signature](container-identity.md).

## Après avoir cliqué sur « Migration par montage » <a href="#preflight" id="preflight"></a>

AppPorts effectue d’abord une vérification en lecture seule du stockage externe, sans rien modifier, puis propose la suite adaptée :

| Résultat | Affichage | Options |
|---|---|---|
| APFS non chiffré avec assez d’espace | Espace libéré sur ce Mac, autorisation à accepter à la première ouverture et nécessité de garder le disque connecté | « Migrer les données » pour commencer |
| exFAT, NTFS, HFS+, etc. | « Ce stockage externe utilise le format exFAT » | « Garder en l’état », « Choisir un autre emplacement », « Voir la préparation » |
| APFS chiffré | « Ce stockage externe est chiffré » | Garder en l’état ou choisir un emplacement APFS non chiffré |
| Espace insuffisant | Espace nécessaire et espace restant | Libérer de l’espace et vérifier à nouveau, ou choisir un autre emplacement |
| Aucun stockage choisi ou disque déconnecté | Invitation à choisir ou connecter un stockage externe | Choisir un stockage et vérifier à nouveau |

**Si la migration est impossible, vous n’avez rien à changer.** L’application, `Application Support`, les caches et les répertoires d’outils peuvent toujours être migrés sur ce disque. Seules les données de conteneur restent sur ce Mac, sans gêner l’utilisation. Pour les migrer plus tard, suivez [Préparer un disque externe APFS](../why-apfs.md#prepare-apfs).

{% hint style="info" %}
**Pourquoi les disques APFS chiffrés ne sont pas encore pris en charge**

Le nouveau volume de données n’hérite pas du mot de passe du volume d’origine. Migrer ainsi placerait sur un volume sans mot de passe un historique de discussion auparavant protégé localement par FileVault. AppPorts ne réduit pas discrètement cette protection tant que le déverrouillage automatique et la gestion des mots de passe ne sont pas prêts. Voir [Disques externes chiffrés](../why-apfs.md#encrypted-drives).
{% endhint %}

## Avant la migration <a href="#avant-la-migration" id="avant-la-migration"></a>

- **Placez AppPorts dans le dossier Applications et ouvrez-le depuis ce dossier.** L’agent de connexion a besoin d’un chemin durable. Depuis Téléchargements ou un DMG, macOS peut utiliser un chemin temporaire App Translocation ; AppPorts bloque alors les nouvelles migrations par montage et demande son installation. Après avoir déplacé ou mis à jour AppPorts, ouvrez-le une fois pour corriger le chemin de l’agent. Si le chemin ne change pas, l’agent n’est pas rechargé.
- **Quittez complètement l’application concernée.** AppPorts vérifie qu’elle n’est plus en cours d’exécution.
- **AppPorts doit disposer de l’accès complet au disque.** Le système contrôle le montage sur un chemin de conteneur et le refuse sans cette autorisation.
- **Pensez à la sauvegarde.** Comme pour toute migration, sauvegardez d’abord les données importantes. Ensuite, ces données sont sur le disque externe, que Time Machine ne sauvegarde généralement pas. Au besoin, vérifiez son inclusion dans les options de Réglages Système › Général › Time Machine.

## Ce qui se passe pendant la migration <a href="#ce-qui-se-passe-pendant-la-migration" id="ce-qui-se-passe-pendant-la-migration"></a>

1. Créer un volume dans le conteneur APFS du disque externe, sans montage automatique dans `/Volumes`. Son nom suit le modèle `AppPorts-<Bundle ID>-<目录名>-xxxxxx`. Il partage l’espace libre avec les autres volumes et ne nécessite pas de taille fixe.
2. Monter temporairement le volume sous `~/Library/Application Support/AppPorts/mounts/`, y copier le contenu avec le copieur d’AppPorts, écrire `.appports-mount-metadata.plist` à sa racine, puis le démonter.
3. Renommer le répertoire original en sauvegarde de sécurité sur le même volume, créer un répertoire vide à son ancien chemin, y monter le volume et vérifier son identité.
4. Écrire l’enregistrement dans `~/Library/Application Support/AppPorts/container-mounts.plist`, installer l’agent de remontage à la connexion, puis supprimer la sauvegarde de sécurité.

Si le disque externe manque d’espace, l’opération s’arrête avant de créer le volume. En cas d’échec avant la fin de la migration, AppPorts tente un retour arrière. S’il ne peut pas le terminer sans risque, il conserve les copies et indique leurs chemins.

Si la migration est terminée mais que la suppression finale de la sauvegarde de sécurité locale échoue, les données montées restent utilisables. AppPorts indique explicitement le chemin de la sauvegarde qu’il reste à supprimer. Il n’est pas nécessaire de relancer la migration.

Après migration, la commande `mount` montre le volume directement sur le chemin du conteneur :

```
/dev/disk7s5 on /Users/<user>/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files (apfs, local, nodev, nosuid, journaled, noowners, nobrowse)
```

## Première ouverture après migration <a href="#premiere-ouverture-apres-migration" id="premiere-ouverture-apres-migration"></a>

Le système demande si l’application peut accéder aux fichiers d’un volume amovible. **Cliquez sur Autoriser.** Cette vérification normale de macOS pour les données externes n’apparaît qu’une fois.

Si vous refusez, l’application se comporte comme si elle n’avait aucune donnée. Pour corriger cela, allez dans Réglages Système → Confidentialité et sécurité → Fichiers et dossiers, ou Volumes amovibles, et activez l’accès pour l’application. Vous pouvez aussi exécuter `tccutil reset SystemPolicyRemovableVolumes <Bundle ID>` dans Terminal pour que la question soit reposée.

Les applications système de `/System/Applications` sont refusées silencieusement, sans dialogue. AppPorts ne les migre pas.

## Utilisation quotidienne <a href="#utilisation-quotidienne" id="utilisation-quotidienne"></a>

**Connectez le disque externe avant d’ouvrir l’application.** Sans disque, le point de montage est un répertoire vide verrouillé, avec les permissions 000. L’application voit des données vides, sans erreur, et ne crée pas de seconde copie locale. Dès le disque connecté, AppPorts remonte automatiquement le volume et les données redeviennent accessibles.

**Ces volumes de données sont normalement invisibles dans Finder.** AppPorts utilise l’option `nobrowse` : ils n’apparaissent ni dans la barre latérale ni sur le bureau. Pendant une ou deux secondes après connexion, macOS peut d’abord les monter dans `/Volumes` et afficher une icône, qui disparaît lorsqu’AppPorts les remet en place. Les anciens volumes encore visibles sont masqués sur place au prochain lancement d’AppPorts ou à la prochaine connexion du disque, sans démontage. Les volumes `AppPorts-…` restent visibles dans Utilitaire de disque. **Ne les effacez ni ne les supprimez : ils contiennent les données migrées.**

**Avant de débrancher, quittez l’application, puis cliquez sur « Démonter » dans AppPorts ou éjectez le disque dans Finder.** Un retrait direct peut perdre les dernières secondes d’écriture et nécessiter une réparation de la base de données. Nos essais sur les volumes APFS n’ont perdu que les dernières transactions ; voir l’[expérience de débranchement](https://app.gitbook.com/s/XSPACE_EN/research/unplug-test).

**Quand la reconnexion est automatique :**

- AppPorts ouvert : au lancement et à chaque connexion d’un volume, il remonte les volumes disponibles qui ne le sont pas.
- AppPorts fermé : après une migration réussie, un agent de connexion remonte les volumes silencieusement à la connexion et à chaque branchement, puis se termine. Il est désinstallé après restauration du dernier enregistrement.
- Une application ouverte juste après connexion peut encore voir un répertoire vide pendant une dizaine de secondes, car le système lance l’agent après les éléments d’ouverture. Quittez puis rouvrez l’application. Le point de montage reste vide pendant l’attente : même lancée trop tôt, l’application n’écrit pas de données locales divergentes. Elle récupère ensuite lorsque le volume revient, comme observé lors de trois essais WeChat.

{% hint style="warning" %}
**Les anciens systèmes, comme macOS 12, demandent un mot de passe administrateur**

macOS 27 autorise un utilisateur ordinaire à monter un volume sous son propre répertoire ; macOS 12 ne l’a pas permis lors des essais. AppPorts réessaie alors avec le dialogue système de mot de passe administrateur, généralement une seule fois par migration. L’agent de connexion n’a pas d’interface et ne peut pas demander ce mot de passe. Sur ces systèmes, ouvrez AppPorts après connexion pour le saisir ou cliquez manuellement sur « Monter » dans « App Data ». Les versions 13 à 26 n’ont pas été vérifiées individuellement.
{% endhint %}

## États et actions <a href="#statuses" id="statuses"></a>

| État | Signification | Actions |
|------|------|------|
| Monté | Volume monté sur le répertoire d’origine ; lecture et écriture normales | Démonter, Restaurer |
| En attente de montage | Volume disponible mais non monté, après branchement ou démontage manuel | Monter, Restaurer |
| Disque externe déconnecté | Volume de données introuvable, généralement parce que le disque est déconnecté | Connectez le disque pour une reconnexion automatique ; s’il est déjà connecté, voir le [dépannage](#troubleshooting) |

**Restaurer** recopie les données du volume sur ce Mac, puis supprime le volume et l’enregistrement. Le disque externe doit rester connecté :

- L’espace libre local est vérifié avant de commencer. S’il est insuffisant, le volume et l’enregistrement sont conservés tels quels.
- Après la copie, AppPorts transforme d’abord l’enregistrement de montage en informations de nettoyage en attente pour empêcher le remontage automatique, puis remet le répertoire local en place. Il supprime uniquement le point de montage vide laissé après démontage, jamais récursivement un répertoire.
- Si la remise en place du répertoire local ne se termine pas, la copie locale temporaire et le volume externe sont conservés. La copie locale reste dans un dossier masqué `.appports-restore-staging-…` du même répertoire. Suivez les chemins conservés et les indications affichés par AppPorts.
- Si le répertoire local est restauré mais que la suppression du volume externe ou la mise à jour de l’enregistrement de nettoyage échoue, AppPorts indique clairement que la restauration est terminée, mais pas le nettoyage. Vous pouvez réessayer le nettoyage depuis la page Répertoires de données. Ne relancez ni la migration ni la restauration.

Si vous ne pouvez pas confirmer qu’une copie existe encore, vous pouvez choisir « Supprimer uniquement l’enregistrement de nettoyage » ; cette action ne supprime ni les sauvegardes locales ni les volumes externes et ne remonte rien, et les copies restantes doivent être nettoyées manuellement.

Si des fichiers locaux apparaissent au point de montage, par exemple parce qu’une application a trouvé un moyen d’y écrire sans le disque, AppPorts refuse de les recouvrir par un montage. Déplacez ces fichiers avant de monter le volume.

## Avant de supprimer ou déplacer AppPorts <a href="#avant-de-supprimer-ou-deplacer-appports" id="avant-de-supprimer-ou-deplacer-appports"></a>

La migration par montage dépend de l’agent de connexion d’AppPorts pour remettre les volumes en place. **Avant de supprimer AppPorts, utilisez « Restaurer » dans « App Data » pour ramener les répertoires migrés sur ce Mac.** Sinon, les données restent intactes sur les volumes externes, mais rien ne les remonte à la connexion et l’application voit des répertoires vides. Réinstaller AppPorts et l’ouvrir une fois rétablit le fonctionnement.

Après une simple mise à jour ou un déplacement d’AppPorts, ouvrez la nouvelle version une fois : elle corrige automatiquement le chemin de l’agent.

## Dépannage <a href="#troubleshooting" id="troubleshooting"></a>

| Symptôme | Action |
|---|---|
| « Disque externe déconnecté » alors que le disque est connecté | Vérifiez dans Utilitaire de disque la présence des volumes `AppPorts-…`. S’ils existent, actualisez AppPorts ou reconnectez le disque. S’ils ont été supprimés, ces données ne sont plus sur le disque et doivent être restaurées depuis une sauvegarde |
| L’application semble vide | Vérifiez l’état « Monté ». Sinon, connectez le disque ou cliquez sur « Monter ». Si le volume est monté, vérifiez que vous n’avez pas refusé l’autorisation à la [première ouverture](#premiere-ouverture-apres-migration) |
| « Monter » signale un point de montage non vide | Identifiez les fichiers locaux qui s’y trouvent et déplacez-les avant de monter |
| Migration ou restauration indiquant une connexion externe en arrière-plan | L’agent de connexion effectue un montage ; attendez quelques secondes et réessayez |

## Pourquoi ne pas utiliser une image disque <a href="#pourquoi-ne-pas-utiliser-une-image-disque" id="pourquoi-ne-pas-utiliser-une-image-disque"></a>

Nous avons sérieusement essayé, pour les utilisateurs exFAT, de stocker une image APFS sparsebundle sur le disque puis de la monter. Elle évitait la demande d’autorisation, offrait des performances comparables et fonctionnait sur tout format.

Puis nous avons débranché la clé USB pendant une écriture. Le volume APFS n’a perdu que les dernières transactions et sa base était réparable. Lors des deux essais, **l’image disque entière ne s’ouvrait plus**, rendant toutes ses données inaccessibles. Son propre « répertoire » est réécrit toutes les quelques secondes ; interrompre cette écriture transforme l’image en fragments sans catalogue. Voir les [données de l’expérience](https://app.gitbook.com/s/XSPACE_EN/research/unplug-test) et l’explication [Pourquoi le disque externe doit être APFS](../why-apfs.md).

Seuls les volumes APFS sont donc pris en charge.

## Détails techniques <a href="#technical-details" id="technical-details"></a>

### Ordre du remontage automatique <a href="#ordre-du-remontage-automatique" id="ordre-du-remontage-automatique"></a>

- L’agent `~/Library/LaunchAgents/com.shimoko.AppPorts.container-mount.plist` exécute `AppPorts --mount-agent`. Il surveille aussi `/Volumes` et se relance lorsqu’un disque apparaît. Au démarrage mesuré le 2026-09-22 : connexion terminée → agent lancé après 4.6 secondes → deux volumes remis sur les chemins de conteneur après 18 secondes. C’était environ 19 secondes plus rapide que la version précédente, mais les applications d’ouverture démarraient après environ 3 secondes. Voir la chronologie dans l’[expérience de montage avant connexion](https://app.gitbook.com/s/XSPACE_EN/research/prelogin-mount).
- **Si le disque tarde, l’agent ne se contente pas d’un essai.** Il observe `/Volumes` dans son processus et réessaie à la prochaine **modification réelle**, plutôt qu’à intervalles fixes. Le système peut mettre plusieurs minutes à reconnaître un disque au démarrage ; le 2026-09-23, il a fallu 2 minutes 33 secondes. Un sondage périodique solliciterait `diskutil` au pire moment ou manquerait le lancement des applications. Sans événement, une vérification de secours a lieu toutes les 20 secondes, pendant 180 secondes au total. L’agent ne détient pas le verrou pendant l’attente. Mesure : environ 1 seconde entre apparition du volume et montage terminé.
- **Vérifier d’abord `/Volumes/<卷名>`.** Au démarrage ou au branchement, le système y monte presque toujours le volume en premier. `statfs` et une lecture du marqueur à la racine, en microsecondes, permettent de reconnaître notre volume et d’éviter un `diskutil info`. Le 2026-09-23, cette requête avait pris **9 secondes**, l’étape la plus coûteuse. Une requête `diskutil` n’est utilisée qu’en cas d’échec de reconnaissance, par exemple après renommage système ou absence de marqueur.
- **Vérifier après montage.** Si le système a déjà monté le volume dans `/Volumes`, `diskutil mount -mountPoint` peut **ignorer le point demandé, afficher quand même `mounted` et renvoyer 0**. AppPorts vérifie donc le chemin réel après chaque montage. S’il est incorrect, il recherche le point actuel, démonte le volume de `/Volumes` et réessaie, jusqu’à 3 cycles. Ce cas s’est produit les 2026-09-21 et 09-23 ; les versions d’alors abandonnaient et WeChat lisait ensuite un répertoire vide.
- **N’agir que sur ses propres volumes.** Avant montage, démontage ou restauration, le Volume UUID du point de montage doit correspondre à l’enregistrement. Un autre volume provoque un arrêt, sans démontage, écrasement ni suppression.
- L’agent et AppPorts partagent un verrou interprocessus : `~/Library/Application Support/AppPorts/operation.lock`. Si AppPorts migre, démonte ou restaure, l’agent attend jusqu’à 120 secondes, puis abandonne ce cycle pour le prochain branchement ou la prochaine connexion. Inversement, AppPorts ne commence pas sans verrou et demande de réessayer. Le verrou ne couvre que chaque cycle de montage, pas les minutes d’attente du disque, afin de ne pas bloquer vos opérations.
- Si le fichier d’enregistrements est illisible, AppPorts ne l’écrase pas comme s’il était vide. Il conserve le fichier et refuse l’ajout ou la suppression d’enregistrements.
- `/etc/fstab` n’est pas utilisé : la forme `UUID=` n’a pas fonctionné lors des essais, les numéros de périphérique changent au rebranchement et les montages par root au démarrage restent soumis aux contrôles d’autorisation.

### Index Spotlight du volume <a href="#index-spotlight-du-volume" id="index-spotlight-du-volume"></a>

Le système traite un volume monté sur un chemin de conteneur comme un volume externe ordinaire et crée son propre index. Les deux volumes WeChat testés contenaient au total 110 MB de `.Spotlight-V100`, encore réécrits après démarrage. Cet index est inutile pour ces données d’application :

- Après création, un fichier vide `.metadata_never_index` est écrit à la racine pour que mds ignore tout le volume. Si `.Spotlight-V100` existe déjà, il est supprimé.
- Le marqueur suit le volume ; il n’est pas nécessaire de le recréer après changement d’emplacement du disque ou restauration d’une migration par montage.
- Les volumes migrés avant cette version reçoivent automatiquement le marqueur au prochain montage.
- Il n’est pas recopié localement lors de la restauration : `.metadata_never_index` est ignoré comme `.fseventsd` et `.Spotlight-V100`.

### Commandes de vérification <a href="#commandes-de-verification" id="commandes-de-verification"></a>

```bash
# 挂载记录
plutil -p ~/Library/Application\ Support/AppPorts/container-mounts.plist

# 当前挂载
mount | grep Containers

# 登录代理
launchctl print gui/$(id -u)/com.shimoko.AppPorts.container-mount

# 卷根有没有防索引标记；系统的索引状态应为 Indexing disabled
ls -la "<挂载点路径>/.metadata_never_index"
mdutil -s "<挂载点路径>"

# 手动重挂（要在有完全磁盘访问权限的终端里执行；旧系统前面加 sudo）
diskutil mount nobrowse -mountPoint "<挂载点路径>" <Volume UUID>
```

## Documents associés <a href="#documents-associes" id="documents-associes"></a>

- [Pourquoi le disque externe doit être APFS](../why-apfs.md)
- [Données de conteneur, bac à sable et identité de signature](container-identity.md)
- [Guide de mise à niveau vers macOS 27](../macos-27.md) : passer de l’ancienne méthode à la nouvelle
- [Expérience : points de montage](https://app.gitbook.com/s/XSPACE_EN/research/sandbox-mountpoint) : essais à l’origine de cette fonction
