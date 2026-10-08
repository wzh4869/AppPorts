# Guide de mise à niveau vers macOS 27

{% hint style="success" %}
**L’essentiel**

Si WeChat ou une autre app ne s’ouvre plus depuis Finder / Dock sous macOS 27 après une re-signature acceptée dans une ancienne version ou une version de test d’AppPorts, commencez par la réparation ci-dessous. Restaurez les anciens liens de conteneur, puis l’app d’origine, ou réinstallez sa version officielle. **Ne supprimez pas les dossiers de données et ne re-signez pas à nouveau.** Une erreur de signature ne prouve pas que les données sont endommagées.
{% endhint %}

## Réparation <a href="#reparation" id="reparation"></a>

Cliquez directement sur **« Réparer »** dans la ligne de l’app, ou choisissez « Voir les étapes de réparation » dans le menu contextuel. Aucune commande Terminal n’est nécessaire. Ce guide décrit la version en développement ; les étapes manuelles conviennent aussi aux versions sans panneau de réparation. Branchez le disque d’origine, quittez complètement l’app et conservez données et sauvegardes.

{% hint style="success" %}
**Re-signature automatique à l’ouverture de session**

La version de développement actuelle désactive la re-signature automatique à l’ouverture de session sous macOS 27 ou version ultérieure, puis arrête et supprime l’ancienne tâche. Si le nettoyage est incomplet, réessayez dans les réglages.

**Mettez à jour et ouvrez AppPorts une fois avant de mettre macOS à niveau**, afin d’ajouter la vérification de version à la tâche d’arrière-plan installée. Télécharger la nouvelle version sans l’ouvrir ne met pas à jour l’ancienne tâche.
{% endhint %}

### 1. Restaurer les données migrées par d’anciens liens <a href="#_1-restaurer-les-donnees-migrees-par-d-anciens-liens" id="_1-restaurer-les-donnees-migrees-par-d-anciens-liens"></a>

Si le panneau trouve des liens de conteneur vers le disque externe, cliquez sur « Tout restaurer ». Sinon, passez cette étape. Manuellement : Répertoires de données → Données des apps → sélectionner l’app → restaurer ses conteneurs liés. Une migration APFS par montage n’a pas besoin d’être annulée pour réparer uniquement la signature.

### 2. Restaurer l’app d’origine ou réinstaller la version officielle <a href="#_2-restaurer-l-app-d-origine-ou-reinstaller-la-version-officielle" id="_2-restaurer-l-app-d-origine-ou-reinstaller-la-version-officielle"></a>

- **Sauvegarde complète de l’app d’origine :** utilisez « Restaurer la signature d’origine ». L’app réelle sur le disque externe peut être restaurée directement, sans revenir d’abord sur le Mac. AppPorts vérifie que l’app actuelle correspond à la sauvegarde. Une app mise à jour ou modifiée nécessite un original officiel correspondant.
- **Ancien enregistrement d’identité seulement :** sélectionnez une `.app` officielle de même version ou réinstallez depuis l’App Store / le site du développeur. Le nom du certificat ne suffit pas à recréer une signature.
- **Réinstallation par-dessus une app externe :** ramenez d’abord l’app sur le Mac pour ne pas remplacer uniquement son lanceur local.

**Ne supprimez pas les dossiers de données de conteneur.** Sauvegardez séparément les données importantes. L’accès aux conversations et aux sessions dépend aussi des versions, des autorisations et des données. Voir [Sauvegarde et restauration des signatures](datamigrae/resign.md).

### 3. Vérifier à nouveau et ouvrir depuis Finder / Dock <a href="#_3-verifier-a-nouveau-et-ouvrir-depuis-finder-dock" id="_3-verifier-a-nouveau-et-ouvrir-depuis-finder-dock"></a>

Cliquez sur « Vérifier à nouveau », puis ouvrez l’app depuis Finder / Dock et vérifiez ses données. Une vérification impossible ne signifie ni signature remplacée ni réparation terminée : rebranchez le disque et réessayez. Les analyses conservent les sauvegardes. Une app qui s’ouvre encore peut être traitée plus tard ; cela ne prouve pas le retour de sa signature d’origine.

### 4. Facultatif : poursuivre la migration des données <a href="#_4-facultatif-poursuivre-la-migration-des-donnees" id="_4-facultatif-poursuivre-la-migration-des-donnees"></a>

Après réparation, sélectionnez le répertoire dans Données des apps et cliquez sur « Migrer ». AppPorts vérifie la destination et utilise la [migration APFS par montage](datamigrae/mount-migration.md) pour les conteneurs, en conservant la signature. Il faut actuellement un **disque externe APFS non chiffré**. Vous pouvez choisir un autre disque ou garder les données sur le Mac. Autorisez l’accès aux volumes amovibles si macOS le demande et branchez le disque avant d’utiliser l’app. Voir [Préparer APFS](why-apfs.md#what-to-do).

## Qui est concerné ? <a href="#qui-est-concerne" id="qui-est-concerne"></a>

| Élément | Explication |
|------|------|
| Déclencheur | Mise à niveau vers macOS 27 |
| Applications concernées | Applications dont les données de `~/Library/Containers/` ou `~/Library/Group Containers/` ont été migrées puis re-signées avec Ad-hoc, ou applications en bac à sable re-signées manuellement par le menu contextuel |
| Symptômes typiques | Aucune réaction au double-clic dans Finder / Dock ; l’icône apparaît brièvement puis disparaît, sans dialogue d’erreur. Toutes les applications re-signées ne sont pas touchées : QQ Music fonctionne sur le même Mac sous 27 |
| Données | Une erreur de signature ne prouve pas une corruption ; conservez les données d’origine et leurs sauvegardes |
| Cas confirmé | WeChat 4.1.15, macOS 27.0 (26A428) |

La re-signature retire l’identité de bac à sable. Quand macOS 27 vérifie le droit de l’application à accéder à son conteneur, une autorisation déjà enregistrée pour l’ancienne signature peut ne plus correspondre à la nouvelle. L’accès est alors refusé ; WeChat journalise `Failed to match existing code requirement`. Les applications sans ancien enregistrement, comme QQ Music, passent actuellement, mais leurs autorisations perdues, notamment celles du trousseau, ne sont pas rétablies. Voir [Données de conteneur, bac à sable et identité de signature](datamigrae/container-identity.md).

AppPorts ne signale un remplacement que si une sauvegarde indique une identité de développeur d’origine et si l’app réelle est actuellement confirmée Ad-hoc. Un délai dépassé ou une app externe illisible demande une nouvelle vérification. Une app initialement Ad-hoc, sa migration ou son lanceur local ne justifient pas une re-signature.

## Ce qu’il ne faut pas faire <a href="#ce-qu-il-ne-faut-pas-faire" id="ce-qu-il-ne-faut-pas-faire"></a>

| Action | Pourquoi elle ne suffit pas |
|------|------|
| Considérer la seule restauration des données comme une réparation | Elle rétablit l’accès aux données externes, pas la signature. Une application re-signée peut toujours quitter immédiatement |
| Re-signer une nouvelle fois | C’est la cause du problème ; cela retire encore les autorisations |
| Ajouter l’application à Accès complet au disque | Peut contourner le contrôle du conteneur, mais les autorisations du trousseau sont perdues et la session reste problématique. Solution temporaire seulement |
| Considérer l’ouverture depuis Terminal comme une réparation | L’application emprunte les permissions de Terminal. Vérifiez avec Finder / Dock |

## Avant la mise à niveau : vérifier <a href="#avant-la-mise-a-niveau-verifier" id="avant-la-mise-a-niveau-verifier"></a>

Consultez d’abord les badges « Signature remplacée » dans AppPorts et suivez la réparation ci-dessus. L’absence d’avertissement ne garantit pas la compatibilité macOS 27. Le script facultatif ne vérifie que les chemins accessibles des anciennes sauvegardes ; apps déplacées, disques débranchés et lanceurs peuvent rendre la liste incomplète.

<details>
<summary>Facultatif : vérifications techniques</summary>

```bash
BACKUP_DIR="$HOME/Library/Application Support/AppPorts/signature-backups"
for plist in "$BACKUP_DIR"/*.plist; do
  [ -f "$plist" ] || continue
  original=$(/usr/libexec/PlistBuddy -c "Print :signingIdentity" "$plist" 2>/dev/null)
  app=$(/usr/libexec/PlistBuddy -c "Print :originalPath" "$plist" 2>/dev/null)
  case "$original" in ""|ad-hoc) continue ;; esac
  [ -d "$app" ] || continue
  if codesign -dv "$app" 2>&1 | grep -q "Signature=adhoc"; then
    printf "%s\n    %s\n" "$app" "$original"
  fi
done
```

</details>

## Après la mise à niveau : confirmer les symptômes <a href="#apres-la-mise-a-niveau-confirmer-les-symptomes" id="apres-la-mise-a-niveau-confirmer-les-symptomes"></a>

Ouvrez d’abord l’app depuis Finder / Dock. En cas d’échec et de signature remplacée confirmée, suivez la réparation ci-dessus. Sinon, vérifiez aussi la version, les autorisations et le disque externe.

<details>
<summary>Facultatif : vérifications techniques</summary>

Remplacez l’exemple par le **chemin de l’app réelle**, pas celui de son lanceur. Ces commandes lisent uniquement des informations. Comparez Ad-hoc avec l’identité d’origine ; un refus d’accès dans les journaux est un indice, pas une preuve de sa cause.

```bash
codesign -dv --verbose=4 "/Applications/WeChat.app" 2>&1 | grep -E "Authority|TeamIdentifier|Signature"
log show --last 1m --style compact 2>/dev/null | grep -i "rejected approval request"
```

</details>

## Ce qu’AppPorts 1.9.0 a changé <a href="#ce-qu-appports-1-9-0-a-change" id="ce-qu-appports-1-9-0-a-change"></a>

Ces comportements correspondent à la version en développement :

- Le mode par défaut migre les conteneurs par montage APFS et refuse de re-signer les apps en bac à sable.
- Les sauvegardes complètes restaurent l’app d’origine. Les anciens enregistrements exigent une app officielle correspondante.
- Les remplacements confirmés et les vérifications impossibles sont affichés séparément ; les éléments de restauration sont conservés.
- Le [mode classique de migration des données](settings.md#classic-data-migration-mode) est désactivé par défaut. Mettre à jour AppPorts ne restaure pas automatiquement les signatures remplacées.

## Questions fréquentes <a href="#questions-frequentes" id="questions-frequentes"></a>

### Vais-je perdre mon historique ? <a href="#vais-je-perdre-mon-historique" id="vais-je-perdre-mon-historique"></a>

Une erreur de signature ne signifie pas que les conversations sont perdues. Conservez conteneurs, données externes et sauvegardes. Évitez les désinstalleurs qui effacent les données. Vérifiez l’accès après réparation ; certaines autorisations de connexion peuvent devoir être rétablies.

### J’ai restauré les données, mais l’application ne s’ouvre toujours pas <a href="#j-ai-restaure-les-donnees-mais-l-application-ne-s-ouvre-toujours-pas" id="j-ai-restaure-les-donnees-mais-l-application-ne-s-ouvre-toujours-pas"></a>

Restaurer les chemins ne restaure pas la signature du développeur. Restaurez l’app d’origine depuis une sauvegarde complète ou réinstallez la version officielle, puis vérifiez. Si le problème persiste avec une signature correcte, examinez version et autorisations.

### Cela ne concerne-t-il que WeChat ? <a href="#cela-ne-concerne-t-il-que-wechat" id="cela-ne-concerne-t-il-que-wechat"></a>

Non. Les tests existants montrent des résultats différents selon l’app. L’avertissement signale un risque à vérifier, pas une panne certaine.

### AppPorts a-t-il endommagé mes données ? <a href="#appports-a-t-il-endommage-mes-donnees" id="appports-a-t-il-endommage-mes-donnees"></a>

Les échecs observés sont liés à l’ancienne méthode de re-signature, sans constituer une preuve de corruption. Conservez les originaux pour toute autre investigation. La migration APFS des conteneurs en mode normal conserve les signatures.

## Documents associés <a href="#documents-associes" id="documents-associes"></a>

- [Données de conteneur, bac à sable et identité de signature](datamigrae/container-identity.md) : fonctionnement
- [Migration par montage](datamigrae/mount-migration.md) : nouvelle méthode
- [Pourquoi le disque externe doit être APFS](why-apfs.md)
- [Re-signature et prévention des plantages](datamigrae/resign.md)
