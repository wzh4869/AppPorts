---
description: "Le guide macOS pour installer AppPorts, migrer vos apps et données et les gérer au quotidien."
layout:
  width: "wide"
  outline:
    visible: false
  pagination:
    visible: false
  metadata:
    visible: false
icon: "book-open"
---

# AppPorts

## Les disques externes sauvent le monde <a href="#les-disques-externes-sauvent-le-monde" id="les-disques-externes-sauvent-le-monde"></a>

<a href="faststart.md" class="button primary">Démarrage rapide</a> <a href="AppPorts.md" class="button secondary">Introduction</a>

**Commencer ici**

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-rocket"></i></td><td><strong>Démarrage rapide</strong></td><td>Téléchargez et installez AppPorts, puis accordez les autorisations nécessaires au premier lancement.</td><td><a href="faststart.md">faststart.md</a></td></tr>
<tr><td><i class="fa-hard-drive"></i></td><td><strong>Guide du stockage externe</strong></td><td>Consultez les critères de choix, de formatage et d’utilisation des disques externes.</td><td><a href="storage-guide.md">storage-guide.md</a></td></tr>
<tr><td><i class="fa-wrench"></i></td><td><strong>Dépannage</strong></td><td>Trouvez les vérifications et correctifs liés aux autorisations, aux états de migration et aux problèmes courants.</td><td><a href="troubleshooting.md">troubleshooting.md</a></td></tr>
</tbody>
</table>

**Découvrir les fonctions principales**

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-layer-group"></i></td><td><strong>Migration sans flèche de raccourci</strong></td><td>Déplacez les applications volumineuses vers le stockage externe en un clic. Seule une enveloppe de lancement légère reste en local ; Finder n’affiche pas de flèche de raccourci, et Launchpad ainsi que les menus d’applications fonctionnent normalement.</td><td><a href="core.md">core.md</a></td></tr>
<tr><td><i class="fa-arrows-rotate"></i></td><td><strong>Protection contre les mises à jour automatiques</strong></td><td>AppPorts détecte les applications à mise à jour automatique comme Sparkle et Electron, et propose « Migration verrouillée ». Une application locale plus récente que sa copie externe reçoit le badge « Sortie en attente ».</td><td><a href="migration-strategy/updater-detection.md">migration-strategy/updater-detection.md</a></td></tr>
<tr><td><i class="fa-database"></i></td><td><strong>Gestion des répertoires de données</strong></td><td>Déplacez les sous-répertoires de ~/Library/, ~/.npm et d’autres données vers le stockage externe. Les données de conteneurs en bac à sable, comme l’historique WeChat, sont migrées par montage sur un disque externe APFS, sans modifier la signature.</td><td><a href="datamigrae/README.md">datamigrae/README.md</a></td></tr>
</tbody>
</table>
