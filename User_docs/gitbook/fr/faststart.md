# Commencer

## Installation d'AppPorts <a href="#installation-d-appports" id="installation-d-appports"></a>

L'installation d'AppPorts nécessite les deux prérequis suivants :
1. Un périphérique de stockage externe stable (comme un disque dur)
2. Système d'exploitation au minimum macOS 12.0 (Monterey) ou ultérieur

### Téléchargement <a href="#telechargement" id="telechargement"></a>

Rendez-vous sur la page [Github releases](https://github.com/wzh4869/AppPorts/releases) pour télécharger le dernier installateur .dmg

{% hint style="success" %}

Si le lien ci-dessus ne peut pas être ouvert, veuillez visiter ce lien pour obtenir l'installateur [téléchargement direct](https://file.shimoko.com/AppPorts)
{% endhint %}

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/download.gif?sign=Xb9FOEqPxR8Q7WLixKzg5NCYcjVzmzq2eh0634xGdG0=:0)


### Installation et lancement <a href="#installation-et-lancement" id="installation-et-lancement"></a>
1. Ouvrir l'installateur .dmg
2. Glisser l'application dans le dossier Applications
3. Lancer l'application

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/install.gif?sign=dg-gU67tz19m6DGdI3NywEAcuqKnyTpWGas0YhZeGfM=:0)


### Autorisation requise <a href="#autorisation-requise" id="autorisation-requise"></a>

Au premier lancement, AppPorts a besoin de la permission Accès complet au disque pour lire et modifier le répertoire /Applications.
1. Ouvrir Réglages Système → Confidentialité et sécurité.
Sélectionner Accès complet au disque.
2. Cliquer sur le bouton +, ajouter AppPorts, puis activer le commutateur.
3. Redémarrer AppPorts.

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/outh.gif?sign=fTXqbKCR_tZBKDb6p1DziuJYjD9NZAJk-Zsw7c4oOJM=:0)

#### Autorisation de mise à jour automatique des applications App Store <a href="#autorisation-de-mise-a-jour-automatique-des-applications-app-store" id="autorisation-de-mise-a-jour-automatique-des-applications-app-store"></a>

Les utilisateurs avec macOS 15.1 (Sequoia) ou ultérieur doivent activer « Télécharger et installer les grandes applications sur un disque externe » dans l'App Store pour qu'AppPorts crée un dossier `/Applications` sur le stockage externe afin de supporter les mises à jour automatiques des applications App Store.
{% hint style="warning" %}
**⚠️ Les systèmes avant macOS 15.1 (Sequoia) ne prennent pas en charge cette fonctionnalité en raison de limitations du système d'exploitation**

Vous devez activer le paramètre « Autoriser la migration des applications App Store » dans les réglages d'AppPorts. Les mises à jour ultérieures des applications nécessitent une re-migration manuelle pour écraser.
{% endhint %}

1. Ouvrir l'App Store
2. Dans la barre d'état, cliquer sur Réglages et cocher « Télécharger et installer les grandes applications sur un disque externe », en sélectionnant le même périphérique de stockage externe que la bibliothèque de stockage externe d'AppPorts

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appstore.gif?sign=JwDPVgjgPb3AulPjZq6Y2KgubkHxmGNqaUawCBRhCEM=:0)
