---
icon: "tags"
layout:
  width: "default"
  outline:
    visible: true
---

# Guide des badges d’état

AppPorts utilise des badges colorés en forme de capsule pour indiquer l’état des applications et des répertoires de données. Certains badges sont cliquables et affichent des explications ou des conseils supplémentaires.

## Badges des applications <a href="#badges-des-applications" id="badges-des-applications"></a>

### État du lien <a href="#etat-du-lien" id="etat-du-lien"></a>

| Badge | Icône | Couleur | Signification |
|------|------|------|------|
| Lié | `link` | Vert | L’application a été migrée vers le stockage externe et possède une entrée locale |
| Migration verrouillée | `lock.fill` | Vert | L’application est liée et verrouillée avec `uchg` pour protéger la copie externe des mises à jour automatiques |
| Migration non verrouillée | `lock.open` | Orange | L’application est liée mais non verrouillée ; une mise à jour depuis l’application peut supprimer ou écraser la copie externe |
| Partiellement lié | `link.badge.plus` | Jaune | Certains composants de l’application sont liés, par exemple certains paquets `.app` d’un répertoire |
| Lien orphelin | `link.badge.exclamationmark` | Rouge | L’application externe est introuvable, mais son entrée locale existe toujours |
| Non lié | `externaldrive.badge.xmark` | Orange | L’application se trouve sur le stockage externe et n’a pas encore été reliée au Mac |
| Externe | `externaldrive` | Orange | Application externe sans entrée locale |
| Sortie en attente | `arrow.up.right.circle` | Cyan | La véritable application locale est plus récente que sa copie externe du même nom ; elle peut être déplacée pour remplacer cette ancienne copie |
| Local | `macmini` | Couleur secondaire | Application locale ordinaire, non migrée ; affiché en l’absence d’autre badge |

{% hint style="success" %}
**Comment « Sortie en attente » est déterminé**

AppPorts rapproche d’abord les applications locales et externes par Bundle ID, puis, si nécessaire, par leur nom normalisé. « Sortie en attente » n’apparaît que si les deux numéros de version sont comparables et que la version locale est plus récente. Si une version manque, si son format ne permet pas la comparaison ou si deux applications de même nom ont des Bundle ID différents, AppPorts conserve l’état local ordinaire pour éviter d’écraser la mauvaise application externe.
{% endhint %}

### Frameworks <a href="#frameworks" id="frameworks"></a>

| Badge | Icône | Couleur | Signification | Explication au clic |
|------|------|------|------|----------|
| Sparkle | `arrow.triangle.2.circlepath` | Cyan | Utilise le framework Sparkle pour les mises à jour automatiques | Après migration, les mises à jour depuis l’application peuvent entraîner la perte de la copie externe ; le verrouillage de la migration est recommandé |
| Electron | `atom` | Indigo | Application Electron pouvant prendre en charge les mises à jour automatiques | Après migration, les mises à jour depuis l’application peuvent entraîner la perte de la copie externe ; le verrouillage de la migration est recommandé |

### Types d’application <a href="#types-d-application" id="types-d-application"></a>

| Badge | Icône | Couleur | Signification |
|------|------|------|------|
| En cours | `play.fill` | Violet | L’application est en cours d’exécution |
| Système | `lock.fill` | Gris | Application système macOS |
| Non natif | `iphone` | Rose | Application iOS/iPadOS exécutée sur une puce Apple |
| Store | `applelogo` | Bleu | Application du Mac App Store |

### Badges particuliers <a href="#badges-particuliers" id="badges-particuliers"></a>

| Badge | Icône | Couleur | Signification |
|------|------|------|------|
| Resigné | `seal.fill` | Cyan | L’application possède actuellement une signature Ad-hoc et AppPorts en conserve une sauvegarde de signature |
| Signature remplacée | `exclamationmark.shield.fill` | Rouge | AppPorts a remplacé la signature du développeur par une signature Ad-hoc. L’application peut ne plus s’ouvrir sous macOS 27. Cliquez sur le badge pour les explications, ou sur « Voir les étapes de réparation » dans le menu contextuel pour ouvrir le panneau de réparation. Voir le [guide de mise à niveau vers macOS 27](macos-27.md) |

{% hint style="success" %}
**Différence entre « Resigné » et « Signature remplacée »**

Les deux indiquent une signature Ad-hoc actuelle ; la différence est **la signature d’origine**. Une application « Resigné » n’avait pas de signature de développeur, ou sa signature d’origine ne peut plus être confirmée : la nouvelle signature lui permet simplement de s’ouvrir normalement. Une application « Signature remplacée » avait une signature de développeur, remplacée par une signature Ad-hoc. Une application en bac à sable peut alors ne plus s’ouvrir sous macOS 27 ; c’est pourquoi ce badge est rouge et donne accès à la réparation.
{% endhint %}

{% hint style="success" %}
**Particularité du badge « Store »**

Le badge « Store » est cliquable et présente l’installation native sur disque externe de macOS 15.1+ lorsque :

- L’application se trouve dans `/Volumes/{drive}/Applications/` sur le stockage externe.
- L’application est gérée nativement par macOS et l’App Store peut effectuer les mises à jour incrémentales directement dans ce répertoire.
{% endhint %}

## Badges des répertoires de données <a href="#badges-des-repertoires-de-donnees" id="badges-des-repertoires-de-donnees"></a>

| État | Couleur | Signification |
|------|------|------|
| Local | Couleur secondaire | Répertoire local non migré. Une icône de bouclier à côté d’un conteneur indique qu’il utilise la migration par montage |
| Lié | Vert | Migration par lien symbolique terminée ; le lien local pointe vers le disque externe |
| Monté | Violet | Migration par montage terminée ; le volume externe est monté à l’emplacement du répertoire d’origine |
| En attente de montage | Orange | Le volume de migration par montage est en ligne mais non monté ; cliquez sur « Monter » |
| Disque externe déconnecté | Rouge | Le volume de données est introuvable, généralement parce que le disque externe est déconnecté ; AppPorts le reconnecte automatiquement au branchement |
| Normalisation requise | Jaune | Lien géré par AppPorts dont la cible externe n’est pas à l’emplacement standard ; utilisez « Normaliser » |
| En attente de reconnexion | Orange | Les données externes sont toujours présentes, mais le lien local a disparu ; utilisez « Relier » |
| Lien symbolique existant | Bleu | Lien symbolique créé en dehors d’AppPorts, que vous pouvez choisir de lui confier |

## Exemples de combinaisons <a href="#exemples-de-combinaisons" id="exemples-de-combinaisons"></a>

Une application peut afficher plusieurs badges simultanément :

```text
[已链接] [Sparkle] [运行中]
```
Signification : l’application a été migrée vers le stockage externe, utilise Sparkle pour les mises à jour automatiques et est en cours d’exécution.

```text
[外部] [商店] [非原生]
```
Signification : application iOS pour Mac, installée par l’App Store sur le stockage externe.

```text
[孤立链接]
```
Signification : l’application externe a disparu ou a été supprimée, mais son entrée locale subsiste. Le lien doit être supprimé manuellement.

```text
[待迁出]
```
Signification : une nouvelle version de la véritable application est présente en local, tandis que la copie externe est ancienne. Une nouvelle migration permet de déplacer la version locale et de remplacer l’ancienne copie externe.
