---
icon: "triangle-exclamation"
layout:
  width: "default"
  outline:
    visible: true
---

# Compatibilité et limites

## Configuration requise <a href="#configuration-requise" id="configuration-requise"></a>

| Exigence | Description |
|------|------|
| Système minimum | macOS 12.0 (Monterey) |
| Architecture | Intel x86_64 / Apple Silicon (arm64) |
| Autorisation | Accès complet au disque |
| Stockage externe | Au moins un périphérique externe |

## Compatibilité des fonctions <a href="#compatibilite-des-fonctions" id="compatibilite-des-fonctions"></a>

### Selon la version de macOS <a href="#selon-la-version-de-macos" id="selon-la-version-de-macos"></a>

| Fonction | macOS 12.0 - 15.0 | macOS 15.1+ |
|------|:---:|:---:|
| Migration d’applications avec Stub Portal | ✓ | ✓ |
| Migration de données par lien symbolique | ✓ | ✓ |
| Migration par montage des conteneurs | ✓, mot de passe administrateur nécessaire pour monter | ✓, sans mot de passe lors des essais sous 27 ; versions 13 à 26 non vérifiées individuellement |
| Migration de dossiers personnalisés | ✓ | ✓ |
| Gestion des signatures de code | ✓ | ✓ |
| Migration externe des applications App Store | ✗ | ✓ |
| Mise à jour App Store directement sur le stockage externe | ✗ | ✓ |
| Migration des applications iOS | ✓ | ✓ |

{% hint style="warning" %}
**Applications App Store avant macOS 15.1**

Avant macOS 15.1 (Sequoia), l’installation externe native des applications App Store n’est pas disponible. Pour les migrer, activez manuellement leur migration dans les réglages d’AppPorts. Après chaque mise à jour, migrez de nouveau pour remplacer la copie externe.
{% endhint %}

### Selon le type d’application <a href="#selon-le-type-d-application" id="selon-le-type-d-application"></a>

| Type | Migration | Restauration | Mise à jour automatique | Description |
|------|:---:|:---:|:---:|------|
| Application native macOS | ✓ | ✓ | ✓ | Meilleure compatibilité |
| Sparkle | ✓ | ✓ | Verrouillage requis | Le verrouillage bloque les mises à jour internes ; ramenez l’application localement pour la mettre à jour |
| Electron | ✓ | ✓ | Verrouillage requis | Comme Sparkle |
| Chrome / Edge, actualiseur personnalisé | ✓ | ✓ | ✓ | La mise à jour s’installe localement sans endommager la copie externe |
| App Store, macOS 15.1+ | ✓ | ✓ | ✓ | Installation externe native et mise à jour directe par l’App Store |
| App Store, macOS <15.1 | ✓ | ✓ | Manuelle | Nouvelle migration après chaque mise à jour |
| iOS pour Mac | ✓ | ✓ | ✓ | Utilise iOS Stub Portal |
| Application système | ✗ | — | — | Protégée par SIP, non migrable |

{% hint style="warning" %}
**Migration d’applications protégées**

Les permissions macOS peuvent empêcher AppPorts de supprimer ou remplacer automatiquement la copie locale d’une application App Store ou appartenant à root. Si un avertissement apparaît, déplacez-la d’abord vers le disque externe dans Finder, puis créez son lien local dans AppPorts.
{% endhint %}

{% hint style="success" %}
**Flèches de raccourci dans Finder**

Les anciens lanceurs AppPorts peuvent être des liens symboliques globaux, affichés avec une flèche. La version actuelle utilise Stub Portal par défaut pour les `.app` ordinaires, généralement sans flèche. Si elle subsiste, ramenez l’application localement et migrez-la de nouveau.
{% endhint %}

{% hint style="success" %}
**À propos de « Sortie en attente »**

« Sortie en attente » exige des versions comparables et une identification fiable de la même application. AppPorts compare d’abord les Bundle ID, puis les noms normalisés si nécessaire. Cet état n’apparaît pas si les versions manquent, ne sont pas comparables ou si des applications homonymes ont des Bundle ID différents.
{% endhint %}

### Selon le type de répertoire de données <a href="#selon-le-type-de-repertoire-de-donnees" id="selon-le-type-de-repertoire-de-donnees"></a>

| Répertoire | Méthode | Risque |
|------|:---:|------|
| `~/Library/Application Support/` | Lien symbolique | Moyen : verrous de fichiers ou journal SQLite WAL possibles |
| `~/Library/Preferences/` | Lien symbolique | Faible à moyen : le cache `cfprefsd` peut renvoyer d’anciens réglages |
| `~/Library/Containers/` | Montage | Moyen : disque APFS non chiffré, autorisation à la première ouverture et disque connecté avant utilisation |
| `~/Library/Group Containers/` | Montage | Moyen : mêmes exigences ; les données partagées affectent les autres applications de la même Team |
| `~/Library/Caches/` | Lien symbolique | Faible : caches recréables |
| `~/Library/Logs/` | Lien symbolique | Faible : journaux uniquement |
| `~/Library/WebKit/` | Lien symbolique | Moyen : stockage local WebKit |
| `~/Library/HTTPStorages/` | Lien symbolique | Faible : stockage des sessions réseau |
| `~/Library/Application Scripts/` | Lien symbolique | Faible : scripts d’extensions |
| `~/Library/Saved Application State/` | Lien symbolique | Faible : restauration de l’état des fenêtres |
| Dossiers masqués comme `~/.npm` et `~/.m2` | Lien symbolique | Faible : caches d’outils de développement |
| Dossiers personnalisés dans le dossier personnel | Lien symbolique | Selon le contenu : fermez les applications ou outils qui écrivent avant de migrer |

{% hint style="warning" %}
**Données importantes**

Historiques WeChat, images de machines virtuelles, bibliothèques de jeux, bases de données et caches de modèles sont souvent volumineux, modifiés fréquemment et sensibles aux chemins et aux verrous. Faites une sauvegarde indépendante avant migration. En cas d’anomalie, restaurez d’abord localement avant de diagnostiquer.
{% endhint %}

{% hint style="warning" %}
**Les conteneurs exigent la migration par montage**

Les applications en bac à sable ne peuvent pas lire les données de `~/Library/Containers/` et `~/Library/Group Containers/` déplacées par lien symbolique. L’ancienne méthode contournait cela par une re-signature, qui peut empêcher l’ouverture sous macOS 27. Depuis 1.9.0, ces répertoires proposent uniquement la [migration par montage](datamigrae/mount-migration.md) et les applications isolées ne sont plus re-signées. Voir [Données de conteneur, bac à sable et identité de signature](datamigrae/container-identity.md).
{% endhint %}

{% hint style="warning" %}
**Périmètre des dossiers personnalisés**

La migration concerne des dossiers réels du dossier personnel. Elle exclut les fichiers, liens symboliques, chemins dans la destination externe, répertoires système et chemins contenant un élément géré ou contenus dans celui-ci.
{% endhint %}

{% hint style="warning" %}
**Conflit de destination**

Une taille externe proche ne suffit pas à reprendre une migration de données. AppPorts reprend automatiquement uniquement si ses métadonnées correspondent entièrement à l’opération actuelle. Sinon, il signale un conflit avec un répertoire réel et s’arrête.
{% endhint %}

## Éléments non migrables <a href="#elements-non-migrables" id="elements-non-migrables"></a>

### Protégés par SIP <a href="#proteges-par-sip" id="proteges-par-sip"></a>

| Chemin | Raison |
|------|------|
| Applications système macOS, dont Safari et Finder | Protection de l’intégrité du système |
| Répertoires de premier niveau de `~/Library/Containers/` | Protection système macOS |

### Contenant des références de chemins <a href="#contenant-des-references-de-chemins" id="contenant-des-references-de-chemins"></a>

| Chemin | Raison |
|------|------|
| `~/.local` | Références aux exécutables ; les outils de ligne de commande peuvent cesser de fonctionner |
| `~/.config` | Configurations avec chemins absolus ; les réglages des outils peuvent devenir invalides |

## Exigences du stockage externe <a href="#exigences-du-stockage-externe" id="exigences-du-stockage-externe"></a>

| Exigence | Description |
|------|------|
| Système de fichiers | Applications et données ordinaires : APFS, HFS+ ou exFAT. **Conteneurs : APFS uniquement** |
| Espace minimum | Dépend de la taille des applications |
| Interface | USB, Thunderbolt et NVMe pris en charge |
| Connexion | Le disque doit rester connecté après migration, sinon les applications concernées ne démarrent pas |

{% hint style="success" %}
**Choisir un système de fichiers**

- **APFS** : recommandé, seul format permettant la migration par montage des conteneurs, et meilleures performances.
- **HFS+** : compatible avec les anciens Mac, mais ne permet pas de migrer les conteneurs.
- **exFAT** : multiplateforme, mais ne permet pas de migrer les conteneurs. Pour Windows, utilisez une partition APFS distincte. Si exFAT occupe tout le disque, les outils intégrés ne peuvent pas le réduire directement : sauvegardez et repartitionnez. Un espace non alloué existant peut accueillir APFS selon les [conditions de partitionnement](why-apfs.md#prepare-apfs).

Les raisons et les alternatives testées sont décrites dans [Pourquoi le disque externe doit être APFS](why-apfs.md).
{% endhint %}

### Disques réseau <a href="#disques-reseau" id="disques-reseau"></a>

NAS, SMB, rclone et SFTP ne sont pas les principales cibles de validation d’AppPorts. Ils peuvent fonctionner, mais vous devez vérifier la stabilité, la constance du chemin, les permissions, les attributs étendus et les liens symboliques. Ils ne sont pas recommandés en premier choix pour les données continuellement écrites.
