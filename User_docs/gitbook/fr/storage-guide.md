---
icon: "hard-drive"
description: "Consultez les critères de choix, de formatage et d’utilisation des disques externes."
layout:
  width: "default"
  outline:
    visible: true
---

# Guide du stockage externe

La fiabilité du stockage externe influe directement sur le lancement des applications migrées, l’accès aux répertoires de données et les mises à jour ultérieures. Privilégiez un SSD externe aux performances stables et de capacité suffisante.

## Configuration recommandée <a href="#configuration-recommandee" id="configuration-recommandee"></a>

| Élément | Recommandation | Description |
|--------|--------|------|
| Capacité | 256 GB ou plus | Les besoins dépendent du nombre d’applications et de répertoires de données à migrer |
| Interface | USB 3.0 ou supérieur / Thunderbolt | USB 2.0 est lent et allonge la migration des applications volumineuses |
| Système de fichiers | APFS | Seul format pris en charge pour migrer les données de conteneur ; permet aussi les clones, les instantanés et le partage d’espace, avec les meilleures performances |

## Comparaison des interfaces <a href="#comparaison-des-interfaces" id="comparaison-des-interfaces"></a>

| Interface | Débit théorique | Débit de migration réel | Usage |
|------|----------|-------------|----------|
| USB 2.0 | 480 Mbps | ~30 MB/s | Déconseillé : migration lente des applications volumineuses |
| USB 3.0 (USB-A) | 5 Gbps | ~350 MB/s | Suffisant pour les besoins courants |
| USB 3.1 Gen 2 (USB-C) | 10 Gbps | ~700 MB/s | Recommandé |
| Thunderbolt 3/4 | 40 Gbps | ~2500 MB/s | Meilleures performances |
| NVMe (Thunderbolt) | 40 Gbps | ~2800 MB/s | Meilleures performances |

## Choix du système de fichiers <a href="#choix-du-systeme-de-fichiers" id="choix-du-systeme-de-fichiers"></a>

### APFS (recommandé) <a href="#apfs-recommande" id="apfs-recommande"></a>

- Prend en charge les clones, les instantanés et le partage d’espace.
- Offre les meilleures performances, particulièrement sur SSD.
- Est pris en charge nativement par macOS.
- **La migration des données de conteneur (`~/Library/Containers/`, par exemple l’historique WeChat) nécessite un disque externe APFS**. Voir les raisons et les expériences dans [Pourquoi le disque externe doit être APFS](why-apfs.md).

### HFS+ <a href="#hfs" id="hfs"></a>

- Bonne compatibilité, adapté aux anciens Mac.
- Ne prend pas en charge les clones ni les instantanés.
- Convient aux disques durs mécaniques.

### exFAT <a href="#exfat" id="exfat"></a>

- Bonne compatibilité entre plateformes, pour partager des fichiers entre macOS et Windows.
- Ne prend pas en charge les liens physiques ni les clones.
- Performances relativement faibles.
- Convient aux échanges de fichiers entre plusieurs systèmes.
- Ne permet pas de migrer les données de conteneur. Si vous utilisez aussi Windows, vous pouvez réserver une partition APFS à AppPorts. Lorsqu’exFAT occupe tout le disque, les outils système ne peuvent pas le réduire directement : sauvegardez d’abord les données, puis repartitionnez. Voir les [conditions et méthodes de partitionnement](why-apfs.md#prepare-apfs).

## Prévoir la capacité <a href="#prevoir-la-capacite" id="prevoir-la-capacite"></a>

L’espace externe utilisé par AppPorts dépend de la taille des applications et des répertoires de données migrés. Voici quelques tailles indicatives :

| Type d’application | Taille |
|----------|------|
| Chrome | ~500 MB |
| Microsoft Office | ~5 GB |
| Adobe Creative Cloud | ~20-50 GB |
| Xcode | ~15 GB |
| Final Cut Pro | ~5 GB |
| Grands modèles de langage locaux (Ollama) | ~4-30 GB |

{% hint style="success" %}
**Capacité conseillée**

- Usage léger (5-10 applications) : 128 GB.
- Usage modéré (10-20 applications) : 256 GB.
- Usage intensif (20+ applications et répertoires de données) : 512 GB ou plus.
{% endhint %}

## Précautions <a href="#precautions" id="precautions"></a>

- Le stockage externe doit rester connecté ; les applications et les répertoires de données migrés sont inutilisables lorsqu’il est hors ligne.
- Sauvegardez régulièrement les données importantes du stockage externe.
- Ne débranchez pas le stockage externe pendant une migration, pour éviter une copie interrompue ou un état incohérent.
- Avant de débrancher le disque, quittez les applications qui utilisent les données externes. Pour les répertoires migrés par montage, cliquez d’abord de préférence sur « Démonter » dans AppPorts.
- Ne placez pas manuellement un fichier ordinaire au chemin cible d’un répertoire de données externe d’AppPorts ; seuls les véritables répertoires peuvent être reconnectés ou normalisés.
- Si le stockage externe rencontre une panne, vous pouvez essayer de ramener les applications sur le Mac avec AppPorts une fois la connexion rétablie.
