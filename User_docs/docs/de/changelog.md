---
outline: deep
---

# Changelog

## v1.6.2

- Neu: Automatische Neuzeichnung bei Anmeldung. Signiert migrierte Apps mit abgelaufenen Signaturen bei jedem Benutzeranmeldung automatisch neu, ohne manuelle Aktion. Standardmäßig aktiviert, kann in den Einstellungen deaktiviert werden
- Verbesserung: Stub Portal verwendet jetzt einen nativen Mach-O-Binärstarter anstelle des Legacy-Bash-Skripts und behebt das Problem, dass doppelklick auf zugehörige Dokumente im Finder die externe App nicht öffnen konnte (#42)
- Verbesserung: Über-Seitenlayout mit scrollbarem Inhaltsbereich optimiert, sodass Inhalte bei kleinem Fenster nicht mehr abgeschnitten werden
- Behoben: Natives Stub Portal wurde fälschlicherweise als reguläre lokale App identifiziert
- Behoben: Natives Stub Portal konnte beim Zurückverschieben in den lokalen Speicher nicht korrekt bereinigt werden
- Behoben: App-Shell wurde bei der Rückverknüpfung als vollständige App behandelt
- Behoben: AutoResignInstaller hat bei fehlgeschlagener Installation stillschweigend Erfolg gemeldet

## v1.6.1

- Behoben: Automatische Neuzeichnung nach Datenverzeichnismigration signiert jetzt korrekt die echte externe App statt der lokalen Stub-Shell
- Behoben: Neuzeichnung- und Signaturwiederherstellungsoperationen lösen jetzt korrekt den echten Pfad für verknüpfte Apps auf
- Behoben: „Neu signiert"-Status-Erkennung für verknüpfte Apps erkennt jetzt korrekt den Signaturstatus der echten externen App
- Verbessert: Log-Ausgabe enthält strukturierte Fehlercodes und zugehörige Pfadinformationen

## v1.6.0

- Migrierte Apps zeigen keine Pfeil-Badges mehr an
- Auto-Update-Apps werden nach Migration durch Updates nicht mehr beschädigt
- App-Signaturverwaltungsfunktion hinzugefügt, um „Beschädigt"-Meldungen nach Migration zu beheben
- Externer Speicher-Trennung zeigt jetzt rote „Verwaiste Verbindung"-Warnungen
- macOS 15.1+ Benutzer können App Store-Apps direkt auf externe Laufwerke installieren
- Datenverzeichnismigration sicherer: Verhindert versehentliche Systemverzeichnis-Migration, automatische Wiederherstellung nach Unterbrechung
- Scannen und Größenberechnung schneller; Liste springt nicht mehr
- Dateikopie in externen Speicher stabiler; keine Fehler mehr bei Unterbrechung
- App-Status-Badges neu gestaltet mit reichhaltigeren Informationen und klickbaren Details
- App-Liste behält Auswahl nach Aktualisierung; Datenverzeichnisse unterstützen Baumansicht
- UI-Verbesserungen: Suche, Sortierung, Gruppenkarten, Icon-Laden usw.
- Martian-Sprachoption hinzugefügt
- Automatisierungstest-Updates

## v1.5.5

- macOS 15.1+ App Store-App externe Installationsunterstützung hinzugefügt
- Automatische Neuzeichnung-Funktion hinzugefügt (automatisch nach Datenverzeichnismigration ausgeführt)
- `LocalizationAuditTests` Lokalisierungsprüfungen hinzugefügt
- Stub Portal Info.plist Generierungslogik verbessert
- Launchpad-Icon-Verlust nach Migration bei einigen Apps behoben

## v1.4.0

- Datenverzeichnis-Baumansicht hinzugefügt
- Tool-Verzeichnis-Erkennung hinzugefügt (30+ Entwicklungstools)
- Diagnosepaket-Export-Funktion hinzugefügt
- Selbstupdate-Erkennung verbessert (Chrome, Edge und andere Custom Updater)
- Auto-Wiederherstellungsmechanismus nach Migrationsunterbrechung behoben

## v1.3.0

- Datenverzeichnismigration-Funktion hinzugefügt
- Code-Signatur-Verwaltung hinzugefügt (Sicherung/Wiederherstellung ursprünglicher Signaturen)
- Sparkle- und Electron-App-Autoerkennung hinzugefügt
- Gesperrte Migration verbessert (`chflags uchg`)
- Badge-Anzeigeprobleme im Finder behoben

## v1.2.0

- Stub Portal-Migrationsstrategie hinzugefügt (ersetzt Deep Contents Wrapper)
- iOS-App-Migrationsunterstützung hinzugefügt (Mac-Version iOS-Apps)
- Batch-Migrationsleistung verbessert
- Problem behoben, bei dem einige Apps nach der Wiederherstellung nicht gestartet werden konnten

## v1.1.0

- Mehrsprachige Unterstützung hinzugefügt (20+ Sprachen)
- App-Suite-Verzeichnismigration hinzugefügt (z. B. Microsoft Office)
- Externe Speicher-Offline-Erkennung verbessert
- Symbolische Link-Durchdringung bei Deep Contents Wrapper-Strategie behoben

## v1.0.0

- Erste offizielle Version
- App-Migration in den externen Speicher unterstützt (Deep Contents Wrapper / Whole App Symlink)
- App-Wiederherstellung und Link-Verwaltung unterstützt
- FolderMonitor-Echtzeit-Dateisystemüberwachung unterstützt
