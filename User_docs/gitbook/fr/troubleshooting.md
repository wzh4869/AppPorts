---
icon: "wrench"
description: "Trouvez les vérifications et correctifs liés aux autorisations, aux états de migration et aux problèmes courants."
layout:
  width: "default"
  outline:
    visible: true
---

# Dépannage

## L’icône apparaît puis disparaît au double-clic <a href="#l-icone-apparait-puis-disparait-au-double-clic" id="l-icone-apparait-puis-disparait-au-double-clic"></a>

La cause la plus fréquente est une application re-signée par AppPorts, à laquelle macOS 27 refuse l’accès à son conteneur après mise à niveau. Cela ne touche pas toutes les applications re-signées, mais WeChat est confirmé. Les données sont intactes.

Pour vérifier :

```bash
codesign -dv --verbose=4 /Applications/<应用名>.app 2>&1 | grep -E "Signature|TeamIdentifier"
# 出现 Signature=adhoc 和 TeamIdentifier=not set 即是
```

Réparation : restaurer les données de conteneur → réinstaller depuis une source officielle → migrer par montage si nécessaire. **Ne re-signez pas encore** et ne considérez pas la seule restauration des données comme une réparation. Voir les [étapes macOS 27](macos-27.md#reparation).

## Échec de migration par montage <a href="#echec-de-migration-par-montage" id="echec-de-migration-par-montage"></a>

| Message | Cause | Action |
|------|------|------|
| Stockage externe non APFS | Disque exFAT / NTFS / HFS+ | Gardez la situation actuelle : conteneurs locaux, autres données migrées normalement. Pour les conteneurs, choisissez un disque APFS ou suivez la [préparation](why-apfs.md#prepare-apfs). Les outils intégrés ne réduisent pas directement exFAT |
| Stockage externe chiffré | APFS chiffré dont le nouveau volume n’hériterait pas du mot de passe | Gardez en l’état ou choisissez APFS non chiffré ; voir [Disques chiffrés](why-apfs.md#encrypted-drives) |
| Espace insuffisant | Disque externe trop plein pour migrer, ou espace local insuffisant pour restaurer | Libérez de l’espace et réessayez. Le contrôle précède la création du volume ou la copie ; aucune donnée n’a changé |
| Échec de commande disque … `kDAReturnNotPrivileged` | Un ancien système, comme macOS 12, interdit à l’utilisateur ordinaire le montage sur un chemin personnalisé | AppPorts réessaie avec un dialogue administrateur. Saisissez le mot de passe ; cette étape n’existait pas avant 1.9.0 |
| Autorisation administrateur annulée | Dialogue de mot de passe annulé | Relancez l’opération |
| Point de montage non vide | L’application a écrit des fichiers localement pendant l’absence du volume | Déplacez-les puis cliquez sur « Monter » |
| Vérification après montage échouée | Le volume est monté au mauvais endroit | Exportez un diagnostic et ouvrez une Issue |
| Volume externe introuvable | Disque absent ou volume supprimé | Reconnectez et actualisez ; si le volume a été supprimé, les données ne sont pas récupérables |

Lors d’un échec, AppPorts supprime le nouveau volume et remet le répertoire d’origine en place. Vous pouvez vérifier dans Utilitaire de disque qu’aucun volume `AppPorts-` résiduel ne subsiste.

## L’application ne voit pas les données après migration par montage <a href="#l-application-ne-voit-pas-les-donnees-apres-migration-par-montage" id="l-application-ne-voit-pas-les-donnees-apres-migration-par-montage"></a>

Vérifiez dans cet ordre :

1. **Connexion du disque et montage du volume** : dans « App Data », le répertoire doit être « Monté ». Pour « En attente de montage », cliquez sur « Monter » ; pour « Disque externe déconnecté », connectez le disque.
2. **Autorisation refusée** : ouvrez Réglages Système → Confidentialité et sécurité → Fichiers et dossiers, puis activez Volumes amovibles pour l’application. Sinon, exécutez `tccutil reset SystemPolicyRemovableVolumes <Bundle ID>` dans Terminal pour renouveler la demande.
3. **Application système** : les applications sous `/System/Applications` sont refusées sans dialogue. AppPorts ne migre pas leurs données.
4. Consultez les journaux système :

   ```bash
   log show --last 2m --style compact 2>/dev/null | grep -E "deny\(1\)|RemovableVolumes"
   ```

   `kTCCServiceSystemPolicyRemovableVolumes` correspond au point 2.

## L’application ne démarre pas après migration <a href="#l-application-ne-demarre-pas-apres-migration" id="l-application-ne-demarre-pas-apres-migration"></a>

1. Vérifiez que le disque externe est connecté.
2. « Lien orphelin » indique une application externe manquante ; supprimez le lien.
3. Si l’application est dite endommagée, essayez d’abord une réinstallation, puis envisagez « Resigner cette app ». Les applications en bac à sable sont refusées ; voir [Re-signature et prévention des plantages](datamigrae/resign.md).
4. Le verrouillage `uchg` peut empêcher l’actualiseur de fonctionner ; c’est attendu.
5. Ouvrez la barre des menus → Journaux → Voir dans le Finder et cherchez les erreurs.
6. Choisissez « Ramener sur ce Mac » dans la bibliothèque externe pour déterminer si le disque est en cause.

## Échec de restauration de la signature <a href="#echec-de-restauration-de-la-signature" id="echec-de-restauration-de-la-signature"></a>

| Cause | Action |
|------|------|
| Sauvegarde absente | Aucun enregistrement utilisable : réinstallez depuis une source officielle. Un enregistrement a pu être nettoyé ; son absence ne prouve pas l’absence de re-signature |
| Ancienne sauvegarde sans application d’origine | Choisissez un `.app` officiel de même version ou réinstallez. Une sauvegarde complète récente ne demande pas de clé privée |
| Application mise à jour ou sauvegarde non valide | Conserver application et sauvegarde sans écraser ; choisir un original officiel correspondant ou réinstaller |
| Application protégée et impossible à remplacer | Conserver application et sauvegarde ; réinstaller avec l’App Store ou l’installateur officiel |
| Application appartenant à root | Un dialogue administrateur demande de changer le propriétaire ; l’annulation fait échouer l’opération |
| Application en bac à sable | Re-signature refusée par défaut. Après re-signature en mode classique, restaurez les conteneurs avant la signature d’origine |

## Migration interrompue <a href="#migration-interrompue" id="migration-interrompue"></a>

Après déconnexion du disque, panne système ou fermeture forcée d’AppPorts :

- **Lien symbolique** : rouvrez AppPorts. Il vérifie `.appports-link-metadata.plist` sur le disque externe et reprend si tout correspond ; sinon, il attend votre intervention. Recherchez « Normalisation requise » ou « En attente de reconnexion ».
- **Montage** : un échec en cours d’opération est automatiquement annulé. Si AppPorts a été forcé à quitter, rouvrez-le : si le répertoire d’origine existe encore, il est intact et les volumes `AppPorts-` supplémentaires peuvent être supprimés dans Utilitaire de disque. S’il a été renommé `.appports-migration-backup-*`, remettez son nom initial.

## Stockage externe hors ligne <a href="#stockage-externe-hors-ligne" id="stockage-externe-hors-ligne"></a>

- Répertoires migrés par lien symbolique : le lien pointe vers un chemin indisponible et l’application ne lit pas les données.
- Répertoires migrés par montage : ils apparaissent vides et l’application n’écrit pas localement.
- Application : le lanceur ne peut pas ouvrir l’application externe, mais ne plante pas lui-même.

AppPorts relance automatiquement l’analyse après reconnexion et remonte les volumes migrés. Les anciens systèmes demandent une fois le mot de passe administrateur.

## Impossible de migrer une application App Store vers le disque externe <a href="#impossible-de-migrer-une-application-app-store-vers-le-disque-externe" id="impossible-de-migrer-une-application-app-store-vers-le-disque-externe"></a>

**Avant macOS 15.1** : l’installation externe native n’est pas disponible. Activez la migration App Store dans les réglages d’AppPorts et migrez manuellement, puis recommencez après les mises à jour.

**macOS 15.1 et ultérieurs** : dans les réglages de l’App Store, activez « Télécharger et installer les apps volumineuses sur un disque distinct » et choisissez le même disque qu’AppPorts.

## La destination existe déjà <a href="#la-destination-existe-deja" id="la-destination-existe-deja"></a>

- **Application** : AppPorts s’arrête si le fichier externe n’est ni l’ancienne copie correspondant à « Sortie en attente », ni un ancien lanceur reconnu. Identifiez la destination dans Finder avant de décider.
- **Données** : sans marqueur correspondant, AppPorts ne prend pas automatiquement le contrôle du répertoire et ne l’écrase pas sur la seule base de sa taille. Vérifiez puis traitez-le manuellement.
- **Retour local** : aucune application réelle homonyme ni aucun lien appartenant à une autre application externe ne sont écrasés.

## Affichage incorrect des répertoires de données <a href="#affichage-incorrect-des-repertoires-de-donnees" id="affichage-incorrect-des-repertoires-de-donnees"></a>

1. AppPorts surveille le système de fichiers et actualise normalement automatiquement.
2. En changeant rapidement d’application, les anciens résultats ne remplacent pas les nouveaux. Si la liste est momentanément vide, attendez la fin de l’analyse.
3. Sinon, cliquez sur le bouton d’actualisation en haut.
4. Si le problème persiste, recherchez les erreurs d’analyse dans les journaux.
