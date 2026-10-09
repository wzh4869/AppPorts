---
icon: "arrows-left-right"
description: "Datenverzeichnisse Schritt für Schritt migrieren oder wiederherstellen."
layout:
  width: "default"
  outline:
    visible: true
---

# Anleitung zur Datenmigration

Diese Seite beschreibt die praktische Datenmigration. Die technische Umsetzung steht unter [Grundlagen](baseinfo.md).

## Datenordner einer App finden <a href="#datenordner-einer-app-finden" id="datenordner-einer-app-finden"></a>

1. Öffne im AppPorts-Hauptfenster „Datenverzeichnisse“.
2. Wechsle oben zwischen „Tool-Verzeichnisse“ und „App Data“.
3. Für App-Daten wählst du links eine App; rechts erscheinen ihre zugehörigen Ordner unter `~/Library/`.

AppPorts gleicht diese Orte anhand der Bundle ID oder des App-Namens ab:

| Durchsuchter Pfad | Abgleich | Migrationsverfahren |
|----------|----------|----------|
| `~/Library/Application Support/` | Bundle ID oder App-Name | Symbolischer Link |
| `~/Library/Preferences/` | Bundle ID oder App-Name | Symbolischer Link |
| `~/Library/Containers/` | Bundle ID | **Mount-Migration** |
| `~/Library/Group Containers/` | Bundle ID | **Mount-Migration** |
| `~/Library/Caches/` | Bundle ID oder App-Name | Symbolischer Link |
| `~/Library/WebKit/` | Bundle ID | Symbolischer Link |
| `~/Library/HTTPStorages/` | Bundle ID | Symbolischer Link |
| `~/Library/Application Scripts/` | Bundle ID | Symbolischer Link |
| `~/Library/Logs/` | App-Name | Symbolischer Link |
| `~/Library/Saved Application State/` | App-Name | Symbolischer Link |

Warum Container anders behandelt werden, erklärt [Mount-Migration](mount-migration.md).

## Tool-Verzeichnisse <a href="#tool-verzeichnisse" id="tool-verzeichnisse"></a>

AppPorts erkennt Ordner verbreiteter Entwicklungswerkzeuge im Benutzerordner, etwa `~/.npm` und `~/.gradle`:

1. Wechsle unter „Datenverzeichnisse“ zu „Tool-Verzeichnisse“.
2. Die Liste zeigt erkannte Ordner, Größe, Priorität und Status.

Fehlt der lokale Ordner, existiert am vorgesehenen externen Ort aber noch ein verwalteter AppPorts-Ordner, erscheint „Wartet auf erneute Verknüpfung“. Die Liste unterstützter Tools steht unter [Tool-Verzeichnisse erkennen](tools.md).

## Eigene Ordner migrieren <a href="#eigene-ordner-migrieren" id="eigene-ordner-migrieren"></a>

„Directory Migration“ migriert beliebige Ordner unter deinem Benutzerordner, etwa große Projekte, Modelle und Mediensammlungen.

1. Öffne „Directory Migration“.
2. Klicke neben „Local Folders“ auf „+“.
3. Wähle den lokalen Ordner und anschließend den Zielstammordner auf dem externen Laufwerk. Das Ziel lautet `目标根目录/文件夹名`.

Geprüft wird: Der lokale Ordner muss innerhalb des Benutzerordners liegen, darf aber nicht dieser selbst sein. Weder er noch übergeordnete Pfade dürfen symbolische Links sein. Er darf verwaltete Ordner weder enthalten noch in ihnen liegen. Das externe Ziel darf nicht im Benutzerordner liegen und darf mit dem lokalen Ordner kein Enthaltensein in einer der beiden Richtungen bilden.

Nach der Migration zeigt der lokale Bereich den ursprünglichen Pfadstatus, der externe Bereich den Status der Kopie. „Erneut verlinken“ und „Wiederherstellen“ sind verfügbar. Das Entfernen der Konfiguration löscht nur den Eintrag, keine Daten.

## Migration über symbolische Links <a href="#migration-uber-symbolische-links" id="migration-uber-symbolische-links"></a>

Für alle Ordner außerhalb von Containern.

1. Finde den Ordner und klicke auf „Migrate“.
2. AppPorts kopiert extern, schreibt die Verwaltungsmarkierung, benennt den lokalen Ordner zur Sicherheitskopie um, erstellt am ursprünglichen Pfad einen Link und bereinigt zuletzt die Sicherung.
3. Danach lautet der Status „Verknüpft“.

{% hint style="success" %}
**Nach Migration neu signieren**

Oben auf der Datenverzeichnisse-Seite gibt es „Nach Migration neu signieren“, standardmäßig ausgeschaltet. Damit wird die zugehörige App nach der Migration mit Ad-hoc neu signiert, ausschließlich gegen eine anschließende Meldung „beschädigt“. Sandbox-Apps werden übersprungen. Normalerweise ist dies unnötig; siehe [Neusignierung und Schutz vor Abstürzen](resign.md).
{% endhint %}

## Mount-Migration <a href="#mount-migration" id="mount-migration"></a>

Für Ordner unter `Containers` und `Group Containers`; die Schaltfläche heißt „Mount-Migration“.

1. Prüfe, dass das externe Laufwerk APFS verwendet, und beende die zugehörige App.
2. Klicke auf „Mount-Migration“, lies die drei Hinweise im Bestätigungsfenster und fahre fort.
3. AppPorts erstellt extern ein Volume, kopiert die Daten hinein und bindet es am ursprünglichen Ordner ein.
4. Danach lautet der Status „Eingebunden“. Erlaube beim ersten Öffnen der App die Systemabfrage.

Die vollständige Anleitung steht unter [Mount-Migration](mount-migration.md).

## Wiederherstellen <a href="#wiederherstellen" id="wiederherstellen"></a>

**Über symbolische Links migrierte Ordner** mit Status „Verknüpft“: „Wiederherstellen“ kopiert die Daten lokal zurück, entfernt den symbolischen Link und anschließend die externe Kopie.

**Per Mount-Migration migrierte Ordner** mit „Eingebunden“ oder „Einbindung ausstehend“: „Wiederherstellen“ kopiert die Volumedaten lokal zurück, hängt das Volume aus und entfernt es. Das Laufwerk muss verbunden bleiben.

Beide Verfahren kopieren zuerst und wechseln erst danach um. Ein Fehler währenddessen führt nicht zu Datenverlust.

## Ungewöhnliche Statuswerte behandeln <a href="#ungewohnliche-statuswerte-behandeln" id="ungewohnliche-statuswerte-behandeln"></a>

| Status | Bedeutung | Aktion |
|------|------|------|
| Normalisierung nötig | AppPorts verwaltet den Link, aber der externe Pfad liegt nicht am vorgesehenen Ort | „Normalisieren“ verschiebt die Daten dorthin und erstellt den Link neu |
| Wartet auf erneute Verknüpfung | Externe Daten sind vorhanden, der lokale Link fehlt | „Erneut verlinken“ erstellt den symbolischen Link neu |
| Vorhandener Symlink | Nicht von AppPorts erstellt | Unter „Linkdetails“ kann die Verwaltung übernommen werden |
| Einbindung ausstehend | Das Mount-Migrationsvolume ist erreichbar, aber nicht eingebunden | „Einbinden“ |
| Laufwerk nicht verbunden | Datenvolume der Mount-Migration nicht gefunden | Laufwerk anschließen; AppPorts bindet automatisch wieder ein |

Erneutes Verlinken und Normalisieren gelten nur für Ordner. Ist das externe Ziel eine normale Datei, hält AppPorts an und bewahrt sie.

## Kontext im Protokoll <a href="#kontext-im-protokoll" id="kontext-im-protokoll"></a>

Zur Diagnose enthalten Datenordner-Operationen Informationen zur zugehörigen App:

| Feld | Beschreibung |
|------|------|
| `app_name` | Name der zugehörigen App |
| `app_status` | App-Status |
| `app_is_resigned` | Ob die App neu signiert wurde |
| `app_bundle_id` | Bundle ID der tatsächlichen App |
| `app_real_path` | Pfad der tatsächlichen App |

Mount-Migration protokolliert zusätzlich Volumename, Volume UUID und die Ausgabe der `diskutil`-Befehle.

## Baumansicht <a href="#baumansicht" id="baumansicht"></a>

Ordner mit Unterordnern erscheinen als Baum: links ein Pfeil zum Aufklappen, eingerückte Unterordner und pro Knoten eigene Größen-, Status- und Aktionsanzeigen.
