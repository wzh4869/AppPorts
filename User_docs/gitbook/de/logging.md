---
icon: "file-lines"
layout:
  width: "default"
  outline:
    visible: true
---

# Protokollierung & Diagnose

AppPorts verfügt über ein eingebautes Protokollierungssystem, das Schlüsselereignisse, Migrationsvorgänge, Systeminformationen und Fehlerdetails während der App-Laufzeit aufzeichnet. Wenn Probleme auftreten, können Sie ein Diagnosepaket exportieren und zur Projekt-[Issues](https://github.com/wzh4869/AppPorts/issues)-Seite einreichen zur Fehlerbehebung.

## Protokollierte Inhalte <a href="#protokollierte-inhalte" id="protokollierte-inhalte"></a>

### Start-Sitzungsinformationen <a href="#start-sitzungsinformationen" id="start-sitzungsinformationen"></a>

Die folgenden Informationen werden bei jedem App-Start aufgezeichnet:

| Element | Beschreibung |
|---------|--------------|
| Sitzungs-ID | Eindeutige Kennung für diesen Lauf (8-stelliges UUID-Präfix) |
| Prozess-ID | Systemprozess-Kennung |
| Bundle ID | App-Kennung |
| App-Sprache | Aktuell ausgewählter Sprachcode |
| System-Locale | System-Locale-Kennung |
| Zeitzone | Aktuelle Zeitzonen-Kennung |
| Bevorzugte Sprachliste | System-Reihenfolge bevorzugter Sprachen |

### Systemdiagnoseinformationen <a href="#systemdiagnoseinformationen" id="systemdiagnoseinformationen"></a>

| Element | Beschreibung |
|---------|--------------|
| App-Version | Versionsnummer und Build-Nummer |
| macOS-Version | Systemversion und Marketing-Name (z. B. „macOS Sequoia 15.x") |
| Gerätemodell | Modell und benutzerfreundlicher Name (z. B. „MacBook Pro (14-inch, M3 Pro, 2023)") |
| Prozessorinformationen | Markenzeichenkette, Kernanzahl, aktive Kernanzahl |
| Physischer Speicher | Gesamtspeicher |

### Externe Speicherinformationen <a href="#externe-speicherinformationen" id="externe-speicherinformationen"></a>

Aufgezeichnet bei der Auswahl eines externen Speichervolumes:

| Element | Beschreibung |
|---------|--------------|
| Volume-Name | Speichervolume-Name |
| Gesamtkapazität / Verfügbarer Platz | Speicherplatzinformationen |
| Dateisystemformat | z. B. APFS, HFS+, exFAT usw. |
| Schnittstellenprotokoll | USB, Thunderbolt, NVMe/SATA |
| Gerätegeschwindigkeit | Übertragungsrateninformationen |
| Blockgröße | Speicherblockgröße |
| Volume-UUID | Eindeutige Speichervolume-Kennung |

### Migrationsvorgangsereignisse <a href="#migrationsvorgangsereignisse" id="migrationsvorgangsereignisse"></a>

Jeder Migrationsvorgang erzeugt eine eindeutige Operations-ID (z. B. `data-migrate-ABCD1234`) und zeichnet auf:

- Operationsstart und -ende
- Fortschritt jedes Schritts (Kopieren, lokales Verzeichnis löschen, symbolischen Link erstellen, Rollback)
- Pfadzustands-Snapshots vor und nach Schritten (Vorhandensein, Berechtigungen, Größe, Symlink-Ziel, immutable Flag)
- Erkennung verbleibender Migrationsdaten und Auto-Wiederherstellung
- Dateikopierfortschritt, Fehler und Wiederholungen

### Migrationsleistungsberichte <a href="#migrationsleistungsberichte" id="migrationsleistungsberichte"></a>

| Element | Beschreibung |
|---------|--------------|
| App-Name | Name der migrierten App |
| Datengröße | Migrierte Datenmenge |
| Dauer | Migrationsdauer (Sekunden) |
| Übertragungsrate | Übertragungsrate (MB/s) |
| Quellpfad / Zielpfad | Migrationsstart- und Endpfade |

### Fehlerdetails <a href="#fehlerdetails" id="fehlerdetails"></a>

Fehlerprotokolle enthalten strukturierte Informationen:

| Feld | Beschreibung |
|------|--------------|
| Fehlerbeschreibung | Menschenlesbare Fehlerbeschreibung |
| Fehlertyp / Domain / Code | NSError-strukturierte Informationen |
| Fehlercode | AppPorts interner Fehlercode (siehe Tabelle unten) |
| Fehlergrund | Detaillierter Fehlergrund |
| Wiederherstellungsvorschlag | Systembereitgestellter Wiederherstellungsvorschlag |
| Dateipfad | Betroffener Dateipfad |
| Zugehörige Pfade | Zugehörige App-Pfade der Operation (`relatedURLs`) |
| Ursächlicher Fehler | Rekursiv aufgezeichneter verschachtelter Fehler |

### Fehlercodes <a href="#fehlercodes" id="fehlercodes"></a>

| Fehlercode | Bedeutung |
|------------|-----------|
| `BACKUP-SIGNATURE-FAILED` | Signatursicherung fehlgeschlagen |
| `APP-MOVE-DESTINATION-CONFLICT` | Das Migrationsziel der App existiert bereits; ein sicheres Ersetzen kann nicht bestätigt werden |
| `APP-RESTORE-LOCAL-CONFLICT` | Beim Zurückholen auf den Mac wurde ein gleichnamiges lokales Objekt gefunden, das nicht automatisch überschrieben werden kann |
| `DATA-MIGRATE-DESTINATION-CONFLICT` | Das Ziel der Datenverzeichnismigration existiert bereits, und die Metadaten stimmen nicht vollständig überein |
| `RESIGN-FAILED` | Erneutes Signieren fehlgeschlagen; die App besteht möglicherweise die macOS-Signaturprüfung nicht |
| `DATA-RESIGN-FAILED` | Automatisches erneutes Signieren nach der Datenverzeichnismigration fehlgeschlagen |
| `RESIGN-REFUSED-SANDBOXED` | Erneutes Signieren einer Sandbox-App verweigert |
| `RESTORE-SIGNATURE-IDENTITY-UNAVAILABLE` | Das ursprüngliche Signaturzertifikat ist auf diesem Mac nicht vorhanden; Wiederherstellung verweigert |
| `CONTAINER-MOUNT-*` | Fehler in einer Phase der Mount-Migration, etwa `CONTAINER-MOUNT-EXTERNAL-NOT-APFS` oder `CONTAINER-MOUNT-SWITCH-FAILED` |
| `CONTAINER-RESTORE-*` | Fehler in einer Phase der Wiederherstellung eines per Mount-Migration verschobenen Verzeichnisses |
| `DATA-BACKUP-SIGNATURE-FAILED` | Signatursicherung vor der Datenverzeichnismigration fehlgeschlagen; bei einer späteren Wiederherstellung steht die ursprüngliche Identität nicht zur Verfügung |

### Datenverzeichnis-Operationskontext <a href="#datenverzeichnis-operationskontext" id="datenverzeichnis-operationskontext"></a>

Datenverzeichnisoperationen (Migration, Wiederherstellung, Normalisierung, Neuverlinkung) fügen automatisch Kontextinformationen der zugehörigen App in die Protokolle ein:

| Feld | Beschreibung |
|------|--------------|
| `app_name` | Name der zugehörigen App |
| `app_status` | App-Status (Verknüpft, Lokal usw.) |
| `app_is_resigned` | Ob die App neu signiert wurde |
| `app_bundle_id` | Bundle ID der App (aus realem Pfad gelesen) |
| `app_real_path` | Realer externer Pfad der App |

### Operationszusammenfassung <a href="#operationszusammenfassung" id="operationszusammenfassung"></a>

Jeder Migrationsvorgang erzeugt einen `OperationSummaryRecord`, der die letzten 100 Aufzeichnungen behält:

| Feld | Beschreibung |
|------|--------------|
| `operationID` | Eindeutige Operations-Kennung |
| `category` | Operationskategorie (`app_move`, `data-migrate`, `file-copy` usw.) |
| `result` | Ergebnis (`success`, `failed`, `rolled_back`, `success_with_warning`) |
| `errorCode` | Fehlercode (falls vorhanden) |
| `startedAt` / `endedAt` | Start- und Endzeit |
| `durationMs` | Dauer (Millisekunden) |

## Protokollkonfiguration <a href="#protokollkonfiguration" id="protokollkonfiguration"></a>

### Speicherort <a href="#speicherort" id="speicherort"></a>

Standardprotokollpfad:

```text
~/Library/Application Support/AppPorts/AppPorts_Log.txt
```

Kann angepasst werden über:

- Menüleiste → Protokolle → Protokollspeicherort festlegen...
- Einstellungen → Protokolleinstellungen → Benutzerdefinierter Pfad

### Protokollformat <a href="#protokollformat" id="protokollformat"></a>

```text
[2026-05-08 09:30:00] [INFO] [session:a1b2c3d4] [pid:12345] 应用启动
[2026-05-08 09:30:01] [DIAG] [session:a1b2c3d4] [pid:12345]   app_version: 1.6.1 (123)
[2026-05-08 09:30:05] [PERF] [session:a1b2c3d4] [pid:12345]   迁移完成: 2.3 GB, 45.2 MB/s, 52.1s
```

### Protokollebenen <a href="#protokollebenen" id="protokollebenen"></a>

| Ebene | Beschreibung |
|-------|--------------|
| `INFO` | Allgemeine Informationen |
| `ERROR` | Fehlerinformationen (mit strukturierten Fehlerdetails) |
| `DIAG` | Systemdiagnoseinformationen |
| `DISK` | Externe Speichervolume-Informationen |
| `PERF` | Migrationsleistungsbericht |
| `TRACE` | Niedrigstufiger Pfadzustand und Ordnerüberwachung |
| `DEBUG` | Debug-Informationen (Größenberechnung, verschachtelte Verzeichnisprüfungen) |
| `WARN` | Warnungen (verbleibende Migrationsdaten, Wiederherstellungsmodus) |

### Protokollrotation <a href="#protokollrotation" id="protokollrotation"></a>

- Standardmaximale Größe: **2 MB** (konfigurierbar: 1 MB, 5 MB, 10 MB, 50 MB, 100 MB)
- Automatische Kürzung bei Überschreitung: Verwirft die ältere Hälfte der Zeilen, behält die neuere Hälfte

## Diagnosepaket exportieren <a href="#diagnosepaket-exportieren" id="diagnosepaket-exportieren"></a>

Wenn Probleme auftreten, die Feedback erfordern, exportieren Sie bitte ein Diagnosepaket und hängen Sie es an das Issue an.

### Exportmethoden <a href="#exportmethoden" id="exportmethoden"></a>

**Methode 1: Menüleiste**

1. Klicken Sie auf Menüleiste → Protokolle → Diagnosepaket exportieren
2. Speicherort wählen
3. System generiert automatisch eine `.zip`-Datei und öffnet sie im Finder

**Methode 2: Einstellungsseite**

1. AppPorts → Einstellungen öffnen (oben rechts)
2. Den Abschnitt „Protokolleinstellungen" finden
3. Auf die Schaltfläche „Diagnosepaket exportieren" klicken
4. Speicherort wählen

### Diagnosepaket-Inhalt <a href="#diagnosepaket-inhalt" id="diagnosepaket-inhalt"></a>

Das exportierte `AppPorts-Diagnostic-<日期时间>.zip` enthält:

| Datei | Format | Beschreibung |
|-------|--------|--------------|
| `diagnostic-summary.json` | JSON | Metadaten (Sitzungs-ID, Version, Locale, Zeitzone usw.) |
| `diagnostic-summary.txt` | Klartext | Menschenlesbare Diagnosezusammenfassung |
| `recent-operations.json` | JSON | Neueste 100 Operationsaufzeichnungen |
| `recent-failures.json` | JSON | Neueste 20 fehlgeschlagene/Warnungs-Operationen |
| `AppPorts_Log.share-safe.txt` | Klartext | Vollständiges Protokoll (redacted) |

### Datenschutz <a href="#datenschutz" id="datenschutz"></a>

Protokolldateien im Diagnosepaket werden anonymisiert:

| Ursprünglicher Inhalt | Ersetzt durch |
|----------------------|---------------|
| Benutzer-Home-Verzeichnis-Pfad (z. B. `/Users/john`) | `/Users/<redacted-user>` |
| Externe Speicher-Volume-Name (z. B. `/Volumes/MyDrive`) | `/Volumes/<redacted-volume>` |
| `$HOME` vollständiger Pfad | `~` |

## Issues einreichen <a href="#issues-einreichen" id="issues-einreichen"></a>

Nach Erhalt des Diagnosepakets folgen Sie diesen Schritten zur Einreichung:

1. Besuchen Sie die Projekt-[Issues](https://github.com/wzh4869/AppPorts/issues)-Seite
2. Klicken Sie auf „New Issue" und wählen Sie die Bug-Report-Vorlage
3. Beschreiben Sie das Problem und die Reproduktionsschritte
4. Ziehen Sie die Diagnose-`.zip`-Datei in den Anhangsbereich zum Hochladen
5. Reichen Sie das Issue ein

{% hint style="success" %}
**💡 Feedback-Effizienz verbessern**

Die Einreichung von Issues mit Diagnosepaketen kann die Problemlösung erheblich beschleunigen. Das Diagnosepaket enthält die vollständige Operationshistorie, Fehlerdetails und Systemumgebungsinformationen, sodass Entwickler Probleme ohne wiederholte Kommunikation reproduzieren und analysieren können.
{% endhint %}
