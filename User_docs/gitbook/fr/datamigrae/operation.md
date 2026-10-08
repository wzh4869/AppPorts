# Guide pratique de migration des données

Cette page décrit les opérations de migration des répertoires de données. Pour les détails techniques, consultez le [fonctionnement](baseinfo.md).

## Trouver les répertoires associés à une application <a href="#trouver-les-repertoires-associes-a-une-application" id="trouver-les-repertoires-associes-a-une-application"></a>

1. Dans la fenêtre principale d’AppPorts, ouvrez l’onglet « Répertoires de données ».
2. En haut, choisissez « Répertoires d'outils » ou « App Data ».
3. Pour les données d’application, sélectionnez une application à gauche. Ses répertoires associés dans `~/Library/` apparaissent à droite.

AppPorts utilise le Bundle ID ou le nom de l’application pour trouver les emplacements suivants :

| Chemin analysé | Correspondance | Méthode de migration |
|------|------|------|
| `~/Library/Application Support/` | Bundle ID ou nom de l’application | Lien symbolique |
| `~/Library/Preferences/` | Bundle ID ou nom de l’application | Lien symbolique |
| `~/Library/Containers/` | Bundle ID | **Migration par montage** |
| `~/Library/Group Containers/` | Bundle ID | **Migration par montage** |
| `~/Library/Caches/` | Bundle ID ou nom de l’application | Lien symbolique |
| `~/Library/WebKit/` | Bundle ID | Lien symbolique |
| `~/Library/HTTPStorages/` | Bundle ID | Lien symbolique |
| `~/Library/Application Scripts/` | Bundle ID | Lien symbolique |
| `~/Library/Logs/` | Nom de l’application | Lien symbolique |
| `~/Library/Saved Application State/` | Nom de l’application | Lien symbolique |

Pour comprendre le cas particulier des conteneurs, consultez [Migration par montage](mount-migration.md).

## Répertoires d’outils <a href="#repertoires-d-outils" id="repertoires-d-outils"></a>

AppPorts reconnaît les répertoires créés par les outils de développement courants dans le dossier personnel, comme `~/.npm` ou `~/.gradle` :

1. Dans « Répertoires de données », choisissez « Répertoires d'outils ».
2. La liste affiche les répertoires reconnus, leur taille, leur priorité et leur état.

Si le répertoire local n’existe plus, mais qu’un répertoire géré par AppPorts reste à l’emplacement canonique du disque externe, son état est « En attente de reconnexion ». Voir la liste dans [Reconnaissance des répertoires d’outils](tools.md).

## Migration de dossiers personnalisés <a href="#migration-de-dossiers-personnalises" id="migration-de-dossiers-personnalises"></a>

L’onglet « Directory Migration » déplace n’importe quel dossier du dossier personnel. Il convient aux grands projets, modèles et bibliothèques de ressources.

1. Ouvrez « Directory Migration ».
2. Cliquez sur « + » dans l’en-tête « Local Folders ».
3. Choisissez le dossier local, puis le répertoire racine de destination sur le disque externe. La destination est `目标根目录/文件夹名`.

Règles de validation : le dossier local doit se trouver dans le dossier personnel, sans être celui-ci ; ni son chemin ni ses parents ne peuvent être des liens symboliques ; il ne peut contenir un répertoire déjà géré ni être contenu par celui-ci. La destination externe doit se trouver hors du dossier personnel et ne peut ni contenir le dossier local ni être contenue par lui.

Après migration, le panneau local indique l’état du chemin d’origine et le panneau externe celui de la copie. Vous pouvez choisir « Relier » ou « Restaurer ». Supprimer la configuration efface uniquement l’enregistrement, pas les données.

## Migration par lien symbolique <a href="#migration-par-lien-symbolique" id="migration-par-lien-symbolique"></a>

Cette méthode convient à tous les répertoires situés hors des conteneurs.

1. Repérez le répertoire et cliquez sur « Migrate ».
2. AppPorts copie les données sur le disque externe, écrit le marqueur de gestion, renomme le répertoire d’origine en sauvegarde, crée le lien symbolique au chemin d’origine, puis supprime la sauvegarde.
3. L’état devient « Lié ».

{% hint style="success" %}
**Re-signer après la migration**

Le commutateur « Re-signer après la migration » se trouve dans la barre d’outils des répertoires de données et est désactivé par défaut. Lorsqu’il est activé, AppPorts re-signe l’application associée avec Ad-hoc après migration, uniquement pour traiter un message « endommagée ». Les applications en bac à sable sont ignorées. Il est généralement inutile de l’activer ; voir [Re-signature et prévention des plantages](resign.md).
{% endhint %}

## Migration par montage <a href="#migration-par-montage" id="migration-par-montage"></a>

Cette méthode concerne les répertoires sous `Containers` et `Group Containers`. Le bouton affiche « Migration par montage ».

1. Vérifiez que le disque externe est APFS et quittez l’application associée.
2. Cliquez sur « Migration par montage », lisez les trois indications de confirmation, puis continuez.
3. AppPorts crée un volume externe, copie les données et monte le volume au répertoire d’origine.
4. L’état devient « Monté ». À la première ouverture de l’application, autorisez l’accès dans le dialogue système.

Consultez le guide complet de [migration par montage](mount-migration.md).

## Restauration <a href="#restauration" id="restauration"></a>

**Répertoire migré par lien symbolique** (état « Lié ») : cliquez sur « Restaurer ». AppPorts recopie les données localement, supprime le lien symbolique, puis la copie externe.

**Répertoire migré par montage** (état « Monté » ou « En attente de montage ») : cliquez sur « Restaurer ». AppPorts recopie les données du volume localement, puis démonte et supprime le volume. Gardez le disque externe connecté.

Les deux méthodes copient les données avant de basculer les chemins. Un échec intermédiaire ne fait pas perdre les données.

## Résoudre les états inhabituels <a href="#resoudre-les-etats-inhabituels" id="resoudre-les-etats-inhabituels"></a>

| État | Signification | Action |
|------|------|------|
| Normalisation requise | Lien géré par AppPorts, mais chemin externe non canonique | « Normaliser » déplace les données au chemin canonique et recrée le lien |
| En attente de reconnexion | Les données externes existent, mais le lien local a disparu | « Relier » recrée le lien symbolique |
| Lien symbolique existant | Lien créé en dehors d’AppPorts | « Détails du lien » permet de le prendre en charge |
| En attente de montage | Le volume est disponible, mais non monté | « Monter » |
| Disque externe déconnecté | Le volume de données est introuvable | Connectez le disque externe ; AppPorts le reconnectera automatiquement |

La reconnexion et la normalisation s’appliquent uniquement aux répertoires. Si un fichier ordinaire occupe la destination externe, AppPorts s’arrête et conserve ce fichier.

## Contexte des journaux <a href="#contexte-des-journaux" id="contexte-des-journaux"></a>

Les opérations sur les répertoires de données consignent l’application associée pour faciliter le diagnostic :

| Champ | Description |
|------|------|
| `app_name` | Nom de l’application associée |
| `app_status` | État de l’application |
| `app_is_resigned` | Indique si l’application a été re-signée |
| `app_bundle_id` | Bundle ID de l’application réelle |
| `app_real_path` | Chemin de l’application réelle |

Les opérations de migration par montage consignent également le nom du volume, son Volume UUID et la sortie des commandes `diskutil`.

## Vue arborescente <a href="#vue-arborescente" id="vue-arborescente"></a>

Les répertoires contenant des sous-répertoires sont présentés en arborescence : une flèche à gauche du parent permet de les développer, les enfants sont décalés, et chaque nœud affiche sa taille, son état et ses propres boutons.
