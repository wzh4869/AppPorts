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
  title:
    visible: false
  description:
    visible: false
  cover:
    visible: true
    size: "background"
icon: "book-open"
cover: ".gitbook/assets/home-cover.svg"
coverY: 0
---

# AppPorts

## Les disques externes sauvent le monde <a href="#les-disques-externes-sauvent-le-monde" id="les-disques-externes-sauvent-le-monde"></a>

Le guide macOS pour installer AppPorts, migrer vos apps et données et les gérer au quotidien.

<button type="button" class="button primary" data-action="ask" data-icon="gitbook-assistant">Que souhaitez-vous savoir sur AppPorts ?</button>

<a href="faststart.md" class="button primary">Démarrage rapide</a> <a href="AppPorts.md" class="button secondary">Introduction</a>

<h3 align="center">Commencer ici <a href="#commencer-ici" id="commencer-ici"></a></h3>

<p align="center">Choisissez un guide pour débuter, déplacer vos applications ou migrer vos données.</p>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th></th><th></th><th></th></tr></thead>
<tbody>
<tr><td><i class="fa-rocket"></i></td><td><h4>Premiers pas <a href="#start-1" id="start-1"></a></h4></td><td>Découvrez AppPorts, son installation, les autorisations et les réglages de base.</td><td><a data-mention href="faststart.md">Démarrage rapide</a></td><td><a data-mention href="AppPorts.md">Introduction</a></td><td><a data-mention href="settings.md">Réglages</a></td></tr>
<tr><td><i class="fa-layer-group"></i></td><td><h4>Migration des applications <a href="#start-2" id="start-2"></a></h4></td><td>Consultez les méthodes de migration et de restauration, ainsi que les stratégies par type d’application.</td><td><a data-mention href="core.md">Fonctionnalités principales</a></td><td><a data-mention href="migration-strategy/portal.md">Stratégies de migration</a></td><td><a data-mention href="migration-strategy/strategy-map.md">Types d’apps et stratégies</a></td></tr>
<tr><td><i class="fa-database"></i></td><td><h4>Migration de données <a href="#start-3" id="start-3"></a></h4></td><td>Consultez les guides sur les répertoires de données, les données des outils et la migration des conteneurs par montage.</td><td><a data-mention href="datamigrae/operation.md">Guide de migration</a></td><td><a data-mention href="datamigrae/tools.md">Détection des répertoires d’outils</a></td><td><a data-mention href="datamigrae/mount-migration.md">Migration par montage</a></td></tr>
</tbody>
</table>

***

<h3 align="center">Stockage et maintenance <a href="#storage-and-maintenance" id="storage-and-maintenance"></a></h3>

<p align="center">Consultez les exigences des disques externes, les mises à jour et les guides de dépannage.</p>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th></th><th></th><th></th></tr></thead>
<tbody>
<tr><td><i class="fa-hard-drive"></i></td><td><h4>Stockage externe <a href="#maintain-1" id="maintain-1"></a></h4></td><td>Consultez les critères de choix d’un disque, les cas nécessitant APFS et les limites de compatibilité.</td><td><a data-mention href="storage-guide.md">Guide du stockage externe</a></td><td><a data-mention href="why-apfs.md">Exigences APFS</a></td><td><a data-mention href="limitations.md">Compatibilité et limites</a></td></tr>
<tr><td><i class="fa-arrows-rotate"></i></td><td><h4>Mises à jour et maintenance <a href="#maintain-2" id="maintain-2"></a></h4></td><td>Comprenez les mises à jour des apps, les changements de macOS 27 et le lien entre données de conteneur et identité de signature.</td><td><a data-mention href="migration-strategy/updater-detection.md">Apps à mise à jour automatique</a></td><td><a data-mention href="macos-27.md">Mise à niveau vers macOS 27</a></td><td><a data-mention href="datamigrae/container-identity.md">Données de conteneur et signature</a></td></tr>
<tr><td><i class="fa-life-ring"></i></td><td><h4>Dépannage <a href="#maintain-3" id="maintain-3"></a></h4></td><td>Consultez les vérifications par symptôme, la FAQ et les conseils d’analyse des journaux.</td><td><a data-mention href="troubleshooting.md">Dépannage</a></td><td><a data-mention href="faq.md">Questions fréquentes</a></td><td><a data-mention href="logging.md">Journalisation et diagnostic</a></td></tr>
</tbody>
</table>

***

<h3 align="center">Découvrir les fonctions principales <a href="#decouvrir-les-fonctions-principales" id="decouvrir-les-fonctions-principales"></a></h3>

<p align="center">Découvrez les trois fonctionnalités principales d’AppPorts.</p>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-layer-group"></i></td><td><strong>Migration sans flèche de raccourci</strong></td><td>Déplacez les applications volumineuses vers le stockage externe en un clic. Seule une enveloppe de lancement légère reste en local ; Finder n’affiche pas de flèche de raccourci, et Launchpad ainsi que les menus d’applications fonctionnent normalement.</td><td><a href="core.md">core.md</a></td></tr>
<tr><td><i class="fa-arrows-rotate"></i></td><td><strong>Protection contre les mises à jour automatiques</strong></td><td>AppPorts détecte les applications à mise à jour automatique comme Sparkle et Electron, et propose « Migration verrouillée ». Une application locale plus récente que sa copie externe reçoit le badge « Sortie en attente ».</td><td><a href="migration-strategy/updater-detection.md">migration-strategy/updater-detection.md</a></td></tr>
<tr><td><i class="fa-database"></i></td><td><strong>Gestion des répertoires de données</strong></td><td>Déplacez les sous-répertoires de ~/Library/, ~/.npm et d’autres données vers le stockage externe. Les données de conteneurs en bac à sable, comme l’historique WeChat, sont migrées par montage sur un disque externe APFS, sans modifier la signature.</td><td><a href="datamigrae/README.md">datamigrae/README.md</a></td></tr>
</tbody>
</table>

***

<h3 align="center">Pour aller plus loin <a href="#keep-exploring" id="keep-exploring"></a></h3>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-clock-rotate-left"></i></td><td><h4>Journal des modifications <a href="#explore-1" id="explore-1"></a></h4></td><td>Consultez les changements et les correctifs par version.</td><td><a href="changelog.md">changelog.md</a></td></tr>
<tr><td><i class="fa-flask"></i></td><td><h4>Expériences <a href="#explore-2" id="explore-2"></a></h4></td><td>Consultez les expériences sur le bac à sable, les montages, le débranchement des disques et le démarrage.</td><td><a href="research/README.md">research/README.md</a></td></tr>
<tr><td><i class="fa-code-pull-request"></i></td><td><h4>Contribuer <a href="#explore-3" id="explore-3"></a></h4></td><td>Découvrez comment participer au développement, aux tests et à la documentation.</td><td><a href="contributing.md">contributing.md</a></td></tr>
</tbody>
</table>
