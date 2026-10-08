# Guide utilisateur AppPorts

Ce guide présente les principales fonctionnalités d’AppPorts, ses principes de conception et son fonctionnement technique. Pour plus de détails techniques, consultez [DeepWiki](https://deepwiki.com/wzh4869/AppPorts). Les suggestions d’amélioration sont les bienvenues dans les [Issues](https://github.com/wzh4869/AppPorts/issues) du projet.

## Présentation <a href="#presentation" id="presentation"></a>

AppPorts est un outil de migration et de liaison d’applications conçu pour [macOS](https://www.apple.com/macos/). Il permet de déplacer les applications volumineuses vers un périphérique de stockage externe, en préservant autant que possible leur comportement dans Finder, Launchpad, les menus d’applications et les mises à jour du système.

### Philosophie d’AppPorts <a href="#philosophie-d-appports" id="philosophie-d-appports"></a>

| Principe | Description |
|------|------|
| **Expérience transparente** | Faire en sorte que l’utilisateur et le système utilisent les applications migrées comme des applications locales |
| **Stratégies stables** | Privilégier les méthodes éprouvées offrant une migration plus stable |
| **Faible charge système** | Ne pas dépendre de démons et éviter de consommer des ressources système en permanence |
| **Internationalisation étendue** | Couvrir davantage de langues et améliorer continuellement la qualité des traductions |
| **Accessibilité** | Offrir une prise en charge de l’accessibilité aussi complète que possible |

## Fonctionnalités principales <a href="#fonctionnalites-principales" id="fonctionnalites-principales"></a>

- **Migration sans flèche de raccourci** : déplace les applications volumineuses vers le stockage externe en un clic. Seule une enveloppe de lancement légère reste en local ; Finder n’affiche pas de flèche de raccourci, et Launchpad ainsi que les menus d’applications macOS fonctionnent normalement.
- **Protection contre les mises à jour automatiques** : détecte les applications capables de se mettre à jour elles-mêmes (Sparkle, Electron, Chrome, etc.) et propose « Migration verrouillée » pour empêcher leur programme de mise à jour de supprimer ou d’écraser l’application externe.
- **Indication de synchronisation des versions** : lorsque la véritable application locale est plus récente que sa copie externe, « Sortie en attente » indique que cette nouvelle version peut être déplacée pour remplacer l’ancienne copie externe.
- **Synchronisation des versions de Stub Portal** : après une mise à jour d’une application externe par l’App Store, les informations de version du Stub Portal local sont synchronisées automatiquement. Le menu « Ouvrir avec » affiche toujours la bonne version.
- **Répertoires d’analyse personnalisés** : permet d’ajouter des répertoires d’applications locales (par exemple JetBrains Toolbox ou Steam), de les enregistrer automatiquement et de surveiller leurs modifications.
- **Gestion des signatures de code** : si une application est signalée comme endommagée après le déplacement de ses fichiers, le menu contextuel permet de la resigner. La sauvegarde et la restauration de la signature originale sont prises en charge. Les applications en bac à sable ne sont jamais resignées.
- **Prise en charge de l’App Store sous macOS 15.1+** : permet d’installer les applications App Store directement sur le stockage externe et de les y mettre à jour sur place, sans les ramener sur le Mac.
- **Restauration en un clic** : ramène les applications sur le Mac et supprime automatiquement les liens. Une migration interrompue peut être récupérée automatiquement.
- **Gestion des répertoires de données** : déplace les données d’applications (sous-répertoires de `~/Library/`, `~/.npm`, etc.) vers le stockage externe, avec une vue en arborescence, la recherche et le tri. Les métadonnées AppPorts servent à vérifier strictement les cibles de restauration.
- **Migration des données de conteneur par montage** : déplace les données de conteneurs en bac à sable, comme l’historique WeChat, en créant un volume dédié sur un disque externe APFS et en le montant à l’emplacement du répertoire d’origine. La signature de l’application reste intacte.
- **Migration de répertoires** : déplace n’importe quel dossier réel du dossier de départ vers le stockage externe. Cette fonction convient aux grands projets, modèles, bibliothèques de ressources et caches d’outils ; elle propose la reconnexion, la restauration et la vérification des chevauchements de chemins.

## Stratégies de migration <a href="#strategies-de-migration" id="strategies-de-migration"></a>

### Deep Contents Wrapper (migration du répertoire Contents) <a href="#deep-contents-wrapper-migration-du-repertoire-contents" id="deep-contents-wrapper-migration-du-repertoire-contents"></a>

Une application macOS possède habituellement la structure suivante :

```text
/Applications/Safari.app/
├── Contents/
│   ├── MacOS/
│   ├── Resources/
│   ├── Frameworks/
│   └── Info.plist
└── ...
```

Deep Contents Wrapper déplace tout le contenu de l’application vers le stockage externe et crée en local un répertoire `.app` vide du même nom, qui contient uniquement un lien symbolique vers le répertoire `Contents` externe. macOS reconnaît un paquet `.app` complet, et non un raccourci : Finder n’affiche donc pas de flèche, tandis que l’icône, Launchpad et les menus d’applications fonctionnent normalement.

{% hint style="warning" %}
**Cette stratégie est obsolète dans la version actuelle**

Le principal défaut de Deep Contents Wrapper est que le programme de mise à jour automatique peut suivre le lien symbolique et modifier directement les fichiers externes, ce qui risque d’endommager l’application.
{% endhint %}

### Stub Portal (enveloppe de lancement) <a href="#stub-portal-enveloppe-de-lancement" id="stub-portal-enveloppe-de-lancement"></a>

Stub Portal crée en local une enveloppe `.app` minimale, qui contient uniquement les quatre éléments suivants :

| Composant | Description |
|------|------|
| `Contents/MacOS/launcher` | Lanceur qui exécute `open "/Volumes/External/SomeApp.app"` |
| `Contents/Resources/` | Fichiers d’icônes copiés depuis l’application externe |
| `Contents/Info.plist` | Version simplifiée du `Info.plist` externe : `CFBundleExecutable` vaut `launcher`, `LSUIElement=true` masque l’application dans le Dock, et toutes les clés de configuration liées aux mises à jour sont supprimées |
| `Contents/PkgInfo` | Fichier d’identification standard de 4 octets |

Lorsque l’utilisateur clique sur cette enveloppe, macOS exécute `launcher`, qui ouvre la véritable application externe avec la commande `open`. Aucun lien symbolique n’est présent en local ; le programme de mise à jour ne peut donc pas suivre un lien jusqu’à l’application externe.

### iOS Stub Portal (enveloppe de lancement iOS) <a href="#ios-stub-portal-enveloppe-de-lancement-ios" id="ios-stub-portal-enveloppe-de-lancement-ios"></a>

Le principe est celui de Stub Portal, mais le traitement des icônes diffère. Les icônes des applications iOS ne sont pas définies dans `Info.plist` : plusieurs fichiers `AppIcon.png` sont stockés dans `Wrapper/` ou `WrappedBundle/`. Le traitement suit ces étapes :

1. Rechercher le fichier `AppIcon.png` de plus haute résolution.
2. Le redimensionner à 256×256 pixels avec `sips`.
3. Le convertir au format `.icns` avec `sips`.
4. Générer `Info.plist` à partir de `iTunesMetadata.plist`, car les applications iOS n’ont pas de `Info.plist` standard.

### Whole Symlink (lien symbolique de l’application entière) <a href="#whole-symlink-lien-symbolique-de-l-application-entiere" id="whole-symlink-lien-symbolique-de-l-application-entiere"></a>

Le répertoire `.app` entier devient un lien symbolique vers le stockage externe :

```text
/Applications/SomeApp.app → /Volumes/External/SomeApp.app
```

Seul un lien symbolique reste en local, sans fichiers d’application. macOS peut généralement ouvrir l’application, mais Finder affiche une flèche de raccourci sur son icône et Launchpad peut rencontrer des problèmes de compatibilité. Le programme de mise à jour peut également suivre ce lien pour modifier les fichiers externes. Cette méthode sert donc principalement de solution de repli à AppPorts.
