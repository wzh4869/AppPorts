# Données de conteneur, bac à sable et identité de signature

{% hint style="success" %}
**L’essentiel**

Les données de `~/Library/Containers/` et `~/Library/Group Containers/` appartiennent à des **applications en bac à sable**. Les déplacer sur un disque externe avec un « raccourci », ou lien symbolique, les rend illisibles pour l’application. AppPorts contournait cela en re-signant l’application, au prix d’échecs d’ouverture possibles sous macOS 27 et d’une perte de session.

Depuis la version 1.9.0, les conteneurs utilisent la [migration par montage](mount-migration.md), sans modifier un octet de signature. Les applications déjà re-signées doivent être réinstallées ; voir le [guide de mise à niveau vers macOS 27](../macos-27.md).
{% endhint %}

Cette page explique l’origine du problème. Si votre application ne s’ouvre plus, consultez directement les réparations du [guide macOS 27](../macos-27.md).

## Qu’est-ce qu’un conteneur ? <a href="#qu-est-ce-qu-un-conteneur" id="qu-est-ce-qu-un-conteneur"></a>

La plupart des applications macOS fonctionnent dans un bac à sable. Le système réserve à chacune un dossier `~/Library/Containers/<Bundle ID>/` dans lequel elle peut lire et écrire. C’est obligatoire pour l’App Store et courant aussi pour les applications téléchargées sur leur site, comme WeChat ou QQ Music. Les données partagées entre applications se trouvent dans `~/Library/Group Containers/`.

Pour reconnaître une application en bac à sable, cherchez `com.apple.security.app-sandbox` dans ses autorisations :

```bash
codesign -d --entitlements - --xml /Applications/WeChat.app 2>/dev/null | grep -c app-sandbox
# 输出 1 就是沙盒应用
```

**Un programme principal non isolé ne signifie pas que ses conteneurs peuvent être déplacés librement.** Chrome et Edge n’isolent pas leur programme principal, mais leurs widgets et extensions ont leurs propres conteneurs, appartenant à des processus isolés. AppPorts traite donc tous les répertoires sous `Containers` de la même manière, indépendamment du programme principal.

## Trois façons de déplacer les données de conteneur <a href="#trois-facons-de-deplacer-les-donnees-de-conteneur" id="trois-facons-de-deplacer-les-donnees-de-conteneur"></a>

| Méthode | Résultat | Raison |
|------|------|------|
| Copier sur le disque externe et laisser un lien symbolique | L’application s’ouvre mais ne lit pas les données ; WeChat indique que l’emplacement de stockage est inutilisable | Le bac à sable vérifie **la destination** du lien et refuse toute sortie du conteneur, vers un disque externe comme vers le bureau |
| Lien symbolique et re-signature Ad-hoc | Fonctionne sous macOS 26 et antérieurs ; peut quitter immédiatement après double-clic sous 27, confirmé avec WeChat mais pas QQ Music | Le lien « fonctionne » parce que la signature retire l’identité de bac à sable. Elle supprime aussi le lien d’appartenance entre application et conteneur, vérifié à partir de 27 |
| Monter un volume APFS externe sur le répertoire d’origine | Fonctionnement normal, signature inchangée | Le chemin reste dans le conteneur et passe le contrôle. Le stockage externe provoque une demande d’autorisation à accepter une fois |

Les trois méthodes ont été vérifiées sous macOS 27. Les journaux originaux figurent dans les expériences sur les [liens symboliques](https://app.gitbook.com/s/OOJEV4rd6jhAZxZO5wvY/guide/research/sandbox-symlink) et les [points de montage](https://app.gitbook.com/s/OOJEV4rd6jhAZxZO5wvY/guide/research/sandbox-mountpoint).

## Ce que la re-signature modifie réellement <a href="#ce-que-la-re-signature-modifie-reellement" id="ce-que-la-re-signature-modifie-reellement"></a>

Une re-signature Ad-hoc avec `codesign --force --deep --sign -` retire :

| Élément perdu | Conséquence |
|------|------|
| `com.apple.security.app-sandbox` | L’application ne s’exécute plus avec une identité de bac à sable |
| `com.apple.security.application-groups` | Les données partagées dans `Group Containers` ne sont plus lisibles |
| `keychain-access-groups` | La session et les clés de base de données du trousseau ne sont plus accessibles |
| Team ID | L’identité ne correspond plus lors de la vérification de propriété du conteneur |

L’application ne tombe pas immédiatement en panne. Elle lit son conteneur comme un processus ordinaire, ce que macOS 26 et antérieurs autorisent. Sous 27, si une autorisation liée à son ancienne signature existe déjà, l’accès est refusé pour non-correspondance de l’exigence de code :

```
sandboxd rejected approval request from WeChat for kTCCServiceSystemPolicyAppData
  (/Users/<user>/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files): denied
runningboardd: termination reported by launchd (0, 0, 65280)
```

Pour le même WeChat re-signé sur la même machine :

| Système | Comportement |
|------|------|
| macOS 26.6.2 | Utilisation normale pendant deux jours et demi |
| macOS 27.0 | Fermeture environ 0.4 seconde après chaque lancement |

{% hint style="warning" %}
**Avoir fonctionné auparavant ne prouve pas l’absence de risque**

Une application re-signée peut fonctionner plusieurs semaines ou mois, puis échouer à la prochaine mise à niveau majeure, sans avertissement avant ou après. Le certificat d’origine du développeur n’est pas sur votre Mac ; les autorisations retirées ne peuvent pas être recréées par une nouvelle signature. Il faut réinstaller.
{% endhint %}

## Pourquoi l’application s’ouvre depuis Terminal <a href="#pourquoi-l-application-s-ouvre-depuis-terminal" id="pourquoi-l-application-s-ouvre-depuis-terminal"></a>

Ce point peut tromper le diagnostic. Le système attribue les permissions au « processus responsable ». Depuis Finder ou Dock, l’application est responsable et demande avec sa propre identité, qui est refusée. Depuis Terminal ou un hôte disposant déjà de l’accès complet au disque, la responsabilité revient à l’hôte et l’application emprunte ses permissions.

Une ouverture depuis Terminal ne prouve donc pas une réparation. Le critère est l’ouverture par double-clic dans Finder / Dock.

## Vérification <a href="#verification" id="verification"></a>

Remplacez `/Applications/WeChat.app` par l’application à vérifier :

```bash
# 1. 签名身份
codesign -dv --verbose=4 /Applications/WeChat.app 2>&1 | grep -E "Authority|TeamIdentifier|Signature"

# 2. 授权（正常输出一段 XML；只有 Executable= 一行说明已被抹掉）
codesign -d --entitlements - /Applications/WeChat.app

# 3. 容器里有没有指向外置盘的符号链接
find ~/Library/Containers/<Bundle ID> -maxdepth 6 -type l -exec readlink {} \; 2>/dev/null

# 4. 复现一次，看系统有没有拒绝
open -a /Applications/WeChat.app; sleep 3
log show --last 1m --style compact 2>/dev/null | grep -iE "rejected approval request|deny\(1\) file-read-data"
```

| Observation | Signification |
|------|------|
| `Signature=adhoc` et `TeamIdentifier=not set` | Application re-signée ; réinstallez-la si elle ne s’ouvre plus |
| L’étape 3 produit un chemin vers `/Volumes/...` | D’anciens liens symboliques subsistent dans le conteneur ; restaurez-les d’abord |
| `kTCCServiceSystemPolicyAppData ... denied` dans les journaux | L’application est privée d’accès à son propre conteneur à cause de la re-signature |
| `deny(1) file-read-data /Volumes/...` dans les journaux | Le bac à sable refuse le lien symbolique vers les données externes |

Les deux messages peuvent apparaître ensemble. Ils correspondent à deux problèmes indépendants à traiter séparément.

## Réparation <a href="#reparation" id="reparation"></a>

Respectez l’ordre, sinon l’application réinstallée trouvera encore un lien symbolique et semblera toujours en panne :

1. **Restaurer les données de conteneur** : dans « App Data », utilisez « Restaurer » sur chacun des conteneurs « Lié » de l’application.
2. **Réinstaller l’application** : installez par-dessus depuis une source officielle pour rétablir la signature et le bac à sable. Cela ne supprime pas les données du conteneur.
3. **Migrer par montage si nécessaire** : les conteneurs affichent ensuite « Migration par montage ». Utilisez cette option pour remettre les données sur le disque externe.

« Restaurer la signature originale » dans la nouvelle version d’AppPorts restaure l’application d’origine depuis une sauvegarde complète, sans clé privée du développeur. Un ancien enregistrement limité au nom de l’identité exige un original officiel de même version ou une réinstallation officielle ; voir [Sauvegarde et restauration de la signature](resign.md#sauvegarde-et-restauration-de-la-signature). Restaurez toujours d’abord les conteneurs migrés en mode classique.

Pour les étapes détaillées et le cas d’une application elle-même migrée, consultez la [réparation sous macOS 27](../macos-27.md#reparation).

## Cas réel <a href="#cas-reel" id="cas-reel"></a>

Chronologie complète sur une machine réelle, en septembre 2026 :

| Date | Événement |
|------|------|
| 9/15 04:46 | AppPorts migre les conversations WeChat sur le disque externe et laisse un lien symbolique |
| 9/15 04:47 | AppPorts re-signe WeChat avec Ad-hoc |
| 9/16 à 9/18 | WeChat fonctionne normalement deux jours et demi sous macOS 26.6.2 |
| 9/18 04:46 | Mise à niveau vers macOS 27.0 |
| Depuis 9/18 | Fermeture environ 0.4 seconde après chaque lancement |
| 9/18 05:04 | L’utilisateur restaure les données et re-signe encore ; le problème persiste |
| 9/18 | Restauration des données puis réinstallation officielle de WeChat : fonctionnement rétabli, historique intact |

Les données n’ont jamais été endommagées. La cause latente était la re-signature, sans symptôme avant la mise à niveau.

## Documents associés <a href="#documents-associes" id="documents-associes"></a>

- [Guide de mise à niveau vers macOS 27](../macos-27.md) : vérifications et réparation
- [Migration par montage](mount-migration.md) : nouvelle méthode
- [Pourquoi le disque externe doit être APFS](../why-apfs.md)
- [Re-signature et prévention des plantages](resign.md) : limites actuelles de cette fonction
