# Fehlerbehebung

## Doppelklick ohne Reaktion, Symbol verschwindet sofort <a href="#doppelklick-ohne-reaktion-symbol-verschwindet-sofort" id="doppelklick-ohne-reaktion-symbol-verschwindet-sofort"></a>

Am häufigsten wurde die App von AppPorts neu signiert und darf nach dem Upgrade auf macOS 27 nicht mehr auf ihren eigenen Container zugreifen. Nicht jede neu signierte App ist betroffen; WeChat ist bestätigt. Die Daten sind nicht beschädigt.

So prüfst du es:

```bash
codesign -dv --verbose=4 /Applications/<应用名>.app 2>&1 | grep -E "Signature|TeamIdentifier"
# 出现 Signature=adhoc 和 TeamIdentifier=not set 即是
```

Reparatur: Containerdaten wiederherstellen → aus offizieller Quelle neu installieren → bei Bedarf Mount-Migration. **Signiere nicht erneut** und betrachte die Datenwiederherstellung allein nicht als Reparatur. Die vollständige Anleitung steht unter [Upgrade auf macOS 27](macos-27.md#reparatur).

## Mount-Migration schlägt fehl <a href="#mount-migration-schlagt-fehl" id="mount-migration-schlagt-fehl"></a>

| Meldung | Ursache | Vorgehen |
|------|------|------|
| Externer Speicher verwendet kein APFS | exFAT / NTFS / HFS+ | Du kannst alles so belassen: Containerdaten bleiben lokal, anderes lässt sich weiter migrieren. Verwende später ein anderes APFS-Laufwerk oder [bereite APFS vor](why-apfs.md#prepare-apfs). Systemwerkzeuge können exFAT nicht direkt verkleinern |
| Externer Speicher ist verschlüsselt | Verschlüsseltes APFS; das neue Volume übernimmt das Passwort nicht | So belassen oder unverschlüsseltes APFS wählen. Siehe [Verschlüsselte externe Laufwerke](why-apfs.md#encrypted-drives) |
| Zu wenig Platz | Extern bei Migration oder lokal bei Wiederherstellung | Platz schaffen und erneut versuchen. Die Prüfung erfolgt vor Volumeerstellung oder Kopieren; keine Daten wurden verändert |
| Festplattenbefehl fehlgeschlagen … `kDAReturnNotPrivileged` | Ältere Systeme wie macOS 12 erlauben normalen Nutzern keine eigenen Mountpfade | AppPorts versucht es mit dem Administratorpasswortdialog erneut. Vor 1.9.0 gab es diesen Schritt nicht |
| Administratorautorisierung abgebrochen | Passwortdialog abgebrochen | Vorgang erneut ausführen |
| Mountpunkt ist nicht leer | Die App hat ohne eingebundenes Volume lokal Dateien geschrieben | Dateien verschieben, dann „Einbinden“ wählen |
| Prüfung nach dem Einbinden fehlgeschlagen | Volume liegt nicht am erwarteten Pfad | Diagnosepaket exportieren und ein Issue melden |
| Externes Volume nicht gefunden | Laufwerk fehlt oder Volume wurde gelöscht | Laufwerk anschließen und aktualisieren. Die Daten eines gelöschten Volumes sind nicht wiederherstellbar |

Bei Fehlern rollt AppPorts zurück: Das neue Volume wird entfernt und der ursprüngliche Ordner zurückbenannt. Im Festplattendienstprogramm kannst du prüfen, dass keine übrigen Volumes mit Präfix `AppPorts-` vorhanden sind.

## App sieht nach Mount-Migration keine Daten <a href="#app-sieht-nach-mount-migration-keine-daten" id="app-sieht-nach-mount-migration-keine-daten"></a>

Prüfe in dieser Reihenfolge:

1. **Laufwerk angeschlossen und Volume eingebunden:** Unter „App Data“ sollte der Ordner „Eingebunden“ anzeigen. Bei „Einbindung ausstehend“ klicke auf „Einbinden“, bei „Laufwerk nicht verbunden“ schließe das Laufwerk an.
2. **Zugriffsabfrage abgelehnt:** Unter Systemeinstellungen → Datenschutz & Sicherheit → Dateien und Ordner für die App „Wechselmedien“ aktivieren. Alternativ mit `tccutil reset SystemPolicyRemovableVolumes <Bundle ID>` im Terminal die nächste Abfrage erneut ermöglichen.
3. **Mitgelieferte System-App:** Apps unter `/System/Applications` erhalten keine Abfrage und werden direkt abgewiesen. Ihre Datenmigration wird nicht unterstützt.
4. Systemprotokoll prüfen:

   ```bash
   log show --last 2m --style compact 2>/dev/null | grep -E "deny\(1\)|RemovableVolumes"
   ```

   `kTCCServiceSystemPolicyRemovableVolumes` verweist auf Punkt 2.

## App startet nach der Migration nicht <a href="#app-startet-nach-der-migration-nicht" id="app-startet-nach-der-migration-nicht"></a>

1. Prüfe, ob das externe Laufwerk angeschlossen ist.
2. „Verwaister Link“ bedeutet, dass die externe App fehlt; hebe die Verknüpfung auf.
3. Bei „beschädigt“ zuerst neu installieren. Erst danach „Diese App neu signieren“ im Kontextmenü erwägen. Sandbox-Apps werden abgelehnt. Siehe [Neusignierung und Schutz vor Abstürzen](datamigrae/resign.md).
4. Bei mit `uchg` gesperrten Apps können Selbstupdater nicht funktionieren; das ist beabsichtigt.
5. Menüleiste → „Protokolle“ → „Im Finder anzeigen“; suche nach zugehörigen Fehlern.
6. Wähle in „Externes Laufwerk“ die Aktion „Zurück auf diesen Mac“, um das Laufwerk als Ursache einzugrenzen.

## Signatur lässt sich nicht wiederherstellen <a href="#signatur-lasst-sich-nicht-wiederherstellen" id="signatur-lasst-sich-nicht-wiederherstellen"></a>

| Ursache | Vorgehen |
|------|------|
| Sicherungsdatei fehlt | Kein Wiederherstellungsdatensatz vorhanden; offiziell neu installieren. Datensätze können auch bereits bereinigt worden sein und beweisen nicht, ob neu signiert wurde |
| Alte Sicherung enthält keine Original-App | Offizielle Original-`.app` derselben Version wählen oder neu installieren. Neue vollständige Sicherungen benötigen keinen privaten Entwicklerschlüssel |
| App aktualisiert oder Sicherungsprüfung fehlgeschlagen | App und Sicherung behalten; nicht überschreiben. Passendes offizielles Original wählen oder neu installieren |
| Systemschutz verhindert Ersetzen | App und Sicherung behalten; über App Store oder offiziellen Installer neu installieren |
| App gehört root | Administratorpasswortdialog zum Ändern des Eigentümers; Abbrechen lässt den Vorgang scheitern |
| Sandbox-App | Neusignierung standardmäßig verweigert. Nach klassischer Neusignierung zuerst Containerdaten, dann Originalsignatur wiederherstellen |

## Migration unterbrochen <a href="#migration-unterbrochen" id="migration-unterbrochen"></a>

Bei getrenntem Laufwerk, Systemabsturz oder erzwungenem Beenden von AppPorts:

- **Symbolische Links:** Öffne AppPorts erneut. Es prüft `.appports-link-metadata.plist` im externen Ordner. Bei vollständiger Übereinstimmung wird fortgesetzt, sonst auf deine Prüfung gewartet. Achte auf „Normalisierung nötig“ oder „Wartet auf erneute Verknüpfung“.
- **Mount-Migration:** Fehler während des Ablaufs werden zurückgerollt. Wurde AppPorts selbst erzwungen beendet, prüfe nach dem Neustart den ursprünglichen Ordner. Ist er vorhanden, ist er intakt; zusätzliche `AppPorts-`-Volumes können im Festplattendienstprogramm entfernt werden. Wurde er zu `.appports-migration-backup-*` umbenannt, gib ihm den ursprünglichen Namen zurück.

## Externer Speicher offline <a href="#externer-speicher-offline" id="externer-speicher-offline"></a>

- Symbolisch verlinkte Ordner: Das Ziel ist ungültig, die App kann die Daten nicht lesen.
- Per Mount-Migration migrierte Ordner: Sie erscheinen leer; die App schreibt keine lokalen Daten.
- App selbst: Die lokale Startapp kann die externe App nicht öffnen, stürzt aber selbst nicht ab.

Nach erneutem Anschließen scannt AppPorts automatisch neu und bindet die Volumes wieder ein. Ältere Systeme benötigen einmal das Administratorpasswort.

## App Store-App lässt sich nicht extern migrieren <a href="#app-store-app-lasst-sich-nicht-extern-migrieren" id="app-store-app-lasst-sich-nicht-extern-migrieren"></a>

**Vor macOS 15.1:** Keine native externe Installation. Aktiviere in AppPorts „Migration von Mac App Store-Apps erlauben“ und migriere manuell. Nach App-Updates ist eine erneute Migration nötig.

**Ab macOS 15.1:** Aktiviere in den App Store-Einstellungen die Option zum Laden und Installieren großer Apps auf einem separaten Laufwerk und wähle dasselbe Laufwerk wie in AppPorts.

## Ziel existiert bereits <a href="#ziel-existiert-bereits" id="ziel-existiert-bereits"></a>

- **Apps:** Wenn das Ziel weder die alte Kopie zu „Ausstehende Auslagerung“ noch ein erkanntes altes AppPorts-Portal ist, stoppt AppPorts. Prüfe das Ziel im Finder, bevor du entscheidest.
- **Datenordner:** Ohne passende AppPorts-Markierung erfolgt keine automatische Übernahme; ähnliche Größen rechtfertigen kein Überschreiben. Inhalte prüfen und manuell behandeln.
- **Lokale Wiederherstellung:** Eine echte lokale App gleichen Namens oder ein Link zu einer anderen externen App wird nicht überschrieben.

## Datenordnerliste wird falsch angezeigt <a href="#datenordnerliste-wird-falsch-angezeigt" id="datenordnerliste-wird-falsch-angezeigt"></a>

1. AppPorts überwacht Dateisystemänderungen und aktualisiert normalerweise automatisch.
2. Beim schnellen App-Wechsel überschreiben alte Ergebnisse die aktuelle Auswahl nicht. Warte bei kurzzeitig leerer Liste das Ende des Scans ab.
3. Falls nötig, verwende die Aktualisierungsschaltfläche oben.
4. Bei anhaltenden Problemen prüfe Scanfehler im Protokoll.
