---
outline: deep
---

# Journal des modifications

## v1.6.2

- Nouveau : Re-signature automatique à la connexion. Re-signe automatiquement les applications migrées avec des signatures expirées à chaque connexion de l'utilisateur, sans action manuelle. Activé par défaut, peut être désactivé dans les Paramètres
- Amélioration : Stub Portal utilise désormais un lanceur binaire Mach-O natif au lieu du script bash hérité, corrigeant le problème où un double-clic sur les documents associés dans le Finder ne parvenait pas à ouvrir l'application externe (#42)
- Amélioration : Mise en page de la page À propos optimisée avec une zone de contenu défilable, corrigeant le contenu tronqué lorsque la fenêtre est trop petite
- Corrigé : Le Stub Portal natif était incorrectement identifié comme une application locale normale
- Corrigé : Impossible de nettoyer correctement le Stub Portal natif lors du déplacement des applications vers le stockage local
- Corrigé : Le shell de l'application était traité comme une application complète lors des opérations de liaison inverse
- Corrigé : AutoResignInstaller signalait un succès silencieusement lorsque l'installation échouait

## v1.6.1

- Corrigé : La re-signature automatique après la migration du répertoire de données signe maintenant correctement la vraie application externe au lieu du shell stub local
- Corrigé : Les opérations de re-signature et de restauration de signature résolvent maintenant correctement le chemin réel pour les applications liées
- Corrigé : La détection du statut « Re-signé » pour les applications liées identifie maintenant correctement le statut de signature de la vraie application externe
- Amélioré : La sortie des logs inclut des codes d'erreur structurés et des informations de chemin associées

## v1.6.0

- Les applications migrées n'affichent plus de badges fléchés
- Les applications à mise à jour automatique ne sont plus corrompues par les mises à jour après migration
- Ajout de la fonctionnalité de gestion de signature d'application pour corriger les messages « Endommagé » après migration
- La déconnexion du stockage externe affiche maintenant des avertissements rouges « Lien orphelin »
- Les utilisateurs de macOS 15.1+ peuvent installer des applications App Store directement sur des disques externes
- Migration des répertoires de données plus sûre : prévention de la migration accidentelle du répertoire système, récupération automatique après interruption
- Scan et calcul de taille plus rapides ; la liste ne saute plus
- Copie de fichiers vers le stockage externe plus stable ; plus d'erreurs d'interruption
- Badges de statut d'application redessinés avec des informations plus riches et des détails cliquables
- La liste d'applications conserve la sélection après actualisation ; les répertoires de données supportent la vue arborescente
- Améliorations UI : recherche, tri, cartes de groupe, chargement d'icônes, etc.
- Ajout de l'option de langue Martien
- Mises à jour des tests automatisés

## v1.5.5

- Ajout du support d'installation externe d'applications App Store macOS 15.1+
- Ajout de la fonctionnalité de re-signature automatique (exécutée automatiquement après la migration du répertoire de données)
- Ajout des tests d'audit de localisation `LocalizationAuditTests`
- Amélioration de la logique de génération du Info.plist du Stub Portal
- Correction du problème de perte d'icône Launchpad pour certaines applications après migration

## v1.4.0

- Ajout de la vue en arborescence des répertoires de données
- Ajout de la détection des répertoires d'outils (30+ outils de développement)
- Ajout de la fonctionnalité d'exportation de package de diagnostic
- Amélioration de la détection des mises à jour automatiques (Chrome, Edge et autres mises à jour personnalisées)
- Correction du mécanisme de récupération automatique après interruption de migration

## v1.3.0

- Ajout de la fonctionnalité de migration des répertoires de données
- Ajout de la gestion des signatures de code (sauvegarde/restauration des signatures originales)
- Ajout de la détection automatique des applications Sparkle et Electron
- Amélioration de la protection de migration verrouillée (`chflags uchg`)
- Correction des problèmes d'affichage des badges dans le Finder

## v1.2.0

- Ajout de la stratégie de migration Stub Portal (remplaçant Deep Contents Wrapper)
- Ajout du support de migration des applications iOS (applications iOS version Mac)
- Amélioration des performances de migration par lots
- Correction du problème où certaines applications ne pouvaient pas se lancer après restauration

## v1.1.0

- Ajout du support multilingue (20+ langues)
- Ajout de la migration des répertoires de suites d'applications (par ex., Microsoft Office)
- Amélioration de la détection de stockage externe hors ligne
- Correction du problème de pénétration de lien symbolique avec la stratégie Deep Contents Wrapper

## v1.0.0

- Première version officielle
- Support de la migration d'applications vers le stockage externe (Deep Contents Wrapper / Whole App Symlink)
- Support de la restauration d'applications et de la gestion des liens
- Support de la surveillance de système de fichiers en temps réel FolderMonitor
