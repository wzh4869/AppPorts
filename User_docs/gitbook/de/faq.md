---
icon: "circle-question"
layout:
  width: "default"
  outline:
    visible: true
---

# Häufige Fragen

## Installation und Berechtigungen <a href="#installation-und-berechtigungen" id="installation-und-berechtigungen"></a>

### Welche Berechtigungen benötigt AppPorts? <a href="#welche-berechtigungen-benotigt-appports" id="welche-berechtigungen-benotigt-appports"></a>

AppPorts benötigt **Festplattenvollzugriff**, um `/Applications` zu lesen und zu ändern. Beim ersten Start wirst du durch die Freigabe geführt. Du kannst AppPorts auch unter Systemeinstellungen → Datenschutz & Sicherheit → Festplattenvollzugriff manuell hinzufügen.

### Welche macOS-Versionen werden unterstützt? <a href="#welche-macos-versionen-werden-unterstutzt" id="welche-macos-versionen-werden-unterstutzt"></a>

Mindestens macOS 12.0 (Monterey). Ab macOS 15.1 (Sequoia) können App Store-Apps zusätzlich nativ extern installiert und dort direkt aktualisiert werden.

### Kann ich ein NAS oder Netzlaufwerk als externen Speicher verwenden? <a href="#kann-ich-ein-nas-oder-netzlaufwerk-als-externen-speicher-verwenden" id="kann-ich-ein-nas-oder-netzlaufwerk-als-externen-speicher-verwenden"></a>

AppPorts ist hauptsächlich für lokale externe Geräte wie mobile Festplatten, externe SSDs und Laufwerksgehäuse gedacht. NAS-, SMB-, rclone- und SFTP-Mounts können theoretisch als macOS-Dateisystempfade dienen. Stabilität, Berechtigungen, Latenz und Wiederverbindung hängen aber von der jeweiligen Mount-Lösung ab.

Teste zunächst unwichtige Apps oder wiederherstellbare Datenordner und prüfe:

- Der Mountpfad ist schon vor dem AppPorts-Start erreichbar.
- Nach einem Netzwerkausfall wird automatisch derselbe Pfad wieder eingebunden.
- Dateisystemrechte, erweiterte Attribute und symbolische Links entsprechen den Anforderungen der App.
- Beginne nicht mit wertvollen oder häufig beschriebenen Daten wie WeChat, virtuellen Maschinen oder Spielebibliotheken.

## Apps migrieren <a href="#apps-migrieren" id="apps-migrieren"></a>

### Wie scanne ich Apps außerhalb von /Applications? <a href="#wie-scanne-ich-apps-außerhalb-von-applications" id="wie-scanne-ich-apps-außerhalb-von-applications"></a>

Klicke rechts neben „Lokale Apps“ auf „+“ und wähle einen zusätzlichen Ordner, etwa für JetBrains Toolbox oder Steam. Die Ordner werden gespeichert, beim nächsten Start automatisch gescannt und auf Änderungen überwacht. Die Titelleiste zeigt ihre Anzahl. Über dieses Zählmenü kannst du die hinzugefügten Ordner ansehen oder entfernen.

### Was tun, wenn eine migrierte App nicht öffnet? <a href="#was-tun-wenn-eine-migrierte-app-nicht-offnet" id="was-tun-wenn-eine-migrierte-app-nicht-offnet"></a>

1. Prüfe, ob der externe Speicher angeschlossen und erreichbar ist.
2. „Verwaister Link“ bedeutet, dass die externe App fehlt. Hebe die Verknüpfung manuell auf.
3. Bei „beschädigt“ zuerst neu installieren. Erst danach „Diese App neu signieren“ im Kontextmenü versuchen; Sandbox-Apps werden abgelehnt.
4. Falls nötig, unter „Externes Laufwerk“ mit „Zurück auf diesen Mac“ den lokalen Betrieb wiederherstellen.
5. Bei einem kurz aufblinkenden, sofort verschwindenden Symbol siehe [Upgrade auf macOS 27](macos-27.md).

### Was bedeutet die Meldung „beschädigt“? <a href="#was-bedeutet-die-meldung-„beschadigt" id="was-bedeutet-die-meldung-„beschadigt"></a>

Meist hat die macOS-Signaturprüfung eine Änderung der App-Paketstruktur erkannt. Gehe so vor:

1. Lade die App erneut von der offiziellen Website oder aus dem App Store und installiere sie neu. Das reicht meistens.
2. Bleibt die Meldung, wähle in AppPorts im Kontextmenü „Diese App neu signieren“. AppPorts sichert die Originalsignatur und signiert mit Ad-hoc neu.
3. Sandbox-Apps werden abgelehnt, weil sie danach unter macOS 27 nicht mehr öffnen könnten. Diese müssen neu installiert werden.

Siehe [Neusignierung und Schutz vor Abstürzen](datamigrae/resign.md).

### Stürzt die App beim Abziehen des externen Speichers ab? <a href="#sturzt-die-app-beim-abziehen-des-externen-speichers-ab" id="sturzt-die-app-beim-abziehen-des-externen-speichers-ab"></a>

Das lokale Stub Portal versucht mit `open`, die externe App zu starten. Fehlt das Laufwerk, startet die App nicht; das Portal selbst stürzt aber nicht ab. Nach erneutem Anschließen funktioniert es wieder.

### Warum erscheint bei manchen migrierten Apps noch ein Verknüpfungspfeil? <a href="#warum-erscheint-bei-manchen-migrierten-apps-noch-ein-verknupfungspfeil" id="warum-erscheint-bei-manchen-migrierten-apps-noch-ein-verknupfungspfeil"></a>

Das kann bei alten AppPorts-Versionen vorkommen. Aktuelle Versionen verwenden für normale `.app`-Pakete standardmäßig Stub Portal. Das lokale Symbol sieht wie eine normale App aus und hat gewöhnlich keinen Pfeil.

Ein verbliebener Pfeil weist meist auf ein älteres Portal mit vollständigem symbolischem Link hin. Hole die App lokal zurück und migriere sie mit der aktuellen Version erneut.

### Lassen sich migrierte Apps aktualisieren? <a href="#lassen-sich-migrierte-apps-aktualisieren" id="lassen-sich-migrierte-apps-aktualisieren"></a>

Das hängt vom App-Typ ab:

| App-Typ | Automatische Updates | Erklärung |
|----------|:---:|------|
| Native App ohne Selbstupdater | ✓ | Bisherige Aktualisierungsmethode weiterverwenden |
| Chrome, Edge mit eigenem Updater | ✓ | Update wird lokal installiert; eine neuere lokale Version wird als „Ausstehende Auslagerung“ markiert |
| Sparkle / Electron | ✗ | Sperren verhindert interne Updates; zuerst mit AppPorts lokal zurückholen und dann aktualisieren |
| App Store-App, macOS 15.1+ | ✓ | App Store aktualisiert direkt extern |
| App Store-App, macOS <15.1 | ✗ | Erneute manuelle Migration nötig |

### Was bedeutet „Ausstehende Auslagerung“? <a href="#was-bedeutet-„ausstehende-auslagerung" id="was-bedeutet-„ausstehende-auslagerung"></a>

Lokal existiert eine tatsächliche App, deren Version AppPorts als neuer als die externe Kopie derselben App erkennt. Häufig haben Chrome, Edge oder andere eigene Updater eine neue Version lokal installiert, während extern noch die alte liegt.

Migriere dann erneut extern, um die alte Kopie durch die lokale neue Version zu ersetzen. AppPorts gleicht zuerst die Bundle ID und ersatzweise den normalisierten Namen ab. Fehlen Versionsnummern, sind sie nicht vergleichbar oder unterscheiden sich die Bundle IDs gleichnamiger Apps, erscheint dieser Status nicht.

### Wird ein bereits vorhandenes externes Ziel überschrieben? <a href="#wird-ein-bereits-vorhandenes-externes-ziel-uberschrieben" id="wird-ein-bereits-vorhandenes-externes-ziel-uberschrieben"></a>

Nicht unmittelbar. AppPorts bereinigt das Ziel nur in folgenden Fällen automatisch und setzt dann fort:

- Bei „Ausstehende Auslagerung“ ist das Ziel die alte Kopie derselben App.
- Das Ziel ist ein erkanntes altes AppPorts-Stub-Portal, ein Deep Contents Wrapper oder ein vollständiges symbolisches Link-Portal.
- Das Ziel ist ein alter Rest eines AppPorts-Migrationsvorgangs.

Bei einer tatsächlichen App oder einem Ordner mit unklarer Zuordnung stoppt AppPorts mit einem Zielkonflikt, um keine Nutzerdaten versehentlich zu löschen.

### Wie migriere ich App Store-Apps extern? <a href="#wie-migriere-ich-app-store-apps-extern" id="wie-migriere-ich-app-store-apps-extern"></a>

**macOS 15.1+:** Aktiviere in den App Store-Einstellungen das Laden und Installieren großer Apps auf einem separaten Laufwerk. Wähle denselben externen Speicher wie für die externe App-Bibliothek von AppPorts.

**macOS <15.1:** Aktiviere „Migration von Mac App Store-Apps erlauben“ in AppPorts. Du musst manuell migrieren und nach Updates erneut die externe Kopie ersetzen.

### Warum erscheint vor der Migration „Geschützte Apps“? <a href="#warum-erscheint-vor-der-migration-„geschutzte-apps" id="warum-erscheint-vor-der-migration-„geschutzte-apps"></a>

App Store-Apps oder Apps mit Eigentümer root sind häufig durch macOS-Berechtigungen geschützt. AppPorts kann die lokale Kopie dann möglicherweise nicht entfernen oder ersetzen. Sicherer ist es, die App zuerst im Finder auf den externen Speicher zu ziehen und das Administratorpasswort einzugeben. Erstelle anschließend in AppPorts den lokalen Link zur externen App. Du kannst die automatische Migration fortsetzen, sie kann aber an fehlenden Berechtigungen scheitern.

### Nach einem App Store-Update gibt es mehrere Einträge unter „Öffnen mit“ oder falsche Versionen <a href="#nach-einem-app-store-update-gibt-es-mehrere-eintrage-unter-„offnen-mit-oder-falsche-versionen" id="nach-einem-app-store-update-gibt-es-mehrere-eintrage-unter-„offnen-mit-oder-falsche-versionen"></a>

Ab v1.8.0 synchronisiert AppPorts die Version der externen App automatisch ins lokale Stub Portal. „Öffnen mit“ wird mit aktualisiert. Bei weiter abweichenden Versionen löst die Aktualisierungsschaltfläche die Synchronisierung manuell aus.

Für v1.7.0 und älter:

1. AppPorts öffnen und beide App-Listen aktualisieren.
2. Ist die lokale Version neuer, erneut migrieren und die externe Kopie ersetzen.
3. Ist nur das lokale Portal fehlerhaft, die Verknüpfung aufheben und aus der externen Bibliothek „Zurück zu Lokal verknüpfen“ ausführen.

Ab macOS 15.1 ist die native externe App Store-Installation vorzuziehen, um auseinanderlaufende Versionen zu vermeiden.

### Ein Doppelklick auf ein Dokument startet die App, öffnet aber die Datei nicht <a href="#ein-doppelklick-auf-ein-dokument-startet-die-app-offnet-aber-die-datei-nicht" id="ein-doppelklick-auf-ein-dokument-startet-die-app-offnet-aber-die-datei-nicht"></a>

Das betrifft oft Office oder WPS, die Dateizuordnungsargumente benötigen. Alte Stub Portals starteten möglicherweise nur die App, ohne den Dokumentpfad korrekt weiterzugeben. Aktualisiere auf mindestens v1.6.2 und hole die App lokal zurück, um sie erneut zu migrieren, oder führe extern erneut „Zurück zu Lokal verknüpfen“ aus.

Bleibt das Problem, exportiere ein Diagnosepaket und melde ein Issue mit Installationsquelle, etwa App Store, offizielle `.pkg` oder DMG, und Reproduktionsschritten.

### Lassen sich Anwendungssuiten wie Adobe oder Office migrieren? <a href="#lassen-sich-anwendungssuiten-wie-adobe-oder-office-migrieren" id="lassen-sich-anwendungssuiten-wie-adobe-oder-office-migrieren"></a>

Du kannst es versuchen. Solche Suiten bestehen oft aus mehreren Apps, gemeinsam genutzten Komponenten, Hintergrunddiensten und Lizenzmodulen statt einer unabhängigen `.app`. AppPorts versucht sie als Ordner zu behandeln; die Kompatibilität hängt weiter von ihrer Struktur ab.

Beende vorher alle Apps der Suite und prüfe Anmeldung oder Aktivierung. Bei Lizenzproblemen, nicht geöffneten verknüpften Dateien oder fehlenden Komponenten hole die Suite lokal zurück. Migriere gegebenenfalls nur große eigenständige Apps oder Datenordner.

### Was tun bei langsamer oder scheinbar festhängender Migration? <a href="#was-tun-bei-langsamer-oder-scheinbar-festhangender-migration" id="was-tun-bei-langsamer-oder-scheinbar-festhangender-migration"></a>

- Nahe 100% kann der Fortschritt ein bis zwei Sekunden pausieren, während das lokale Portal erstellt und abschließend geprüft wird.
- Große Apps wie Xcode oder Adobe benötigen naturgemäß mehr Zeit.
- Bei längerem Stillstand prüfe die Verbindung zum externen Speicher.
- USB 2.0 ist langsam. USB 3.0 oder neuer beziehungsweise Thunderbolt wird empfohlen.

## Datenordner migrieren <a href="#datenordner-migrieren" id="datenordner-migrieren"></a>

### Können App-Daten durch die Migration verloren gehen? <a href="#konnen-app-daten-durch-die-migration-verloren-gehen" id="konnen-app-daten-durch-die-migration-verloren-gehen"></a>

Normalerweise nicht. AppPorts kopiert zuerst vollständig extern und prüft den Erfolg, bevor es den lokalen Originalordner entfernt und einen symbolischen Link erstellt. Bei Fehlern wird eine automatische Rückabwicklung versucht.

Existiert das externe Ziel bereits, wird nur bei vollständig passender `.appports-link-metadata.plist` fortgesetzt: Quellpfad, Zielpfad und Datenordnertyp müssen stimmen. Echte Ordner ohne passende Metadaten gelten als Konflikt. Ähnliche Größe reicht nicht für Übernahme oder Überschreiben.

### Wann kann Datenmigration App-Probleme verursachen? <a href="#wann-kann-datenmigration-app-probleme-verursachen" id="wann-kann-datenmigration-app-probleme-verursachen"></a>

- Die App verwendet Dateisperren oder SQLite-WAL-Protokolle.
- Erweiterte Attribute gehen beim Zugriff über Links verloren oder verhalten sich anders.
- Mehrere Apps desselben Teams teilen `Group Containers`.

Ordner unter `~/Library/Containers/` und `~/Library/Group Containers/` verwenden Mount-Migration statt symbolischer Links. Sie benötigen ein APFS-Laufwerk und eine bestätigte Zugriffsabfrage beim ersten Öffnen. Siehe [Mount-Migration](datamigrae/mount-migration.md).

### Können WeChat-Chats extern gespeichert werden? <a href="#konnen-wechat-chats-extern-gespeichert-werden" id="konnen-wechat-chats-extern-gespeichert-werden"></a>

Ja, mit „Mount-Migration“. Wähle WeChat unter „App Data“. Die nach Konto aufgeteilten `xwechat_files`-Unterordner in `Containers` und `Application Support/com.tencent.xinWeChat` können per Mount-Migration ausgelagert werden. APFS ist erforderlich. Erlaube beim ersten WeChat-Start nach der Migration den Zugriff.

**Verwende nicht** die alte Kombination aus Migration und Neusignierung. Sie verhindert unter macOS 27 das Öffnen von WeChat.

### Nach der WeChat-Datenmigration fehlen die Chats <a href="#nach-der-wechat-datenmigration-fehlen-die-chats" id="nach-der-wechat-datenmigration-fehlen-die-chats"></a>

Unterscheide zwei Fälle:

- **Mount-Migration mit 1.9.0:** Prüfe Laufwerk, Status „Eingebunden“ und ob die Zugriffsabfrage abgelehnt wurde. Siehe [Fehlerbehebung](troubleshooting.md#app-sieht-nach-mount-migration-keine-daten).
- **Alte Migration über symbolische Links:** Die Sandbox kann Daten außerhalb des Containers nicht lesen. Das ist eine Systembeschränkung. Stelle den Ordner in AppPorts lokal wieder her. Hattest du der Neusignierung zugestimmt, installiere WeChat zusätzlich von der offiziellen Website neu. Siehe [Reparatur für macOS 27](macos-27.md#reparatur).

**Signiere nicht erneut**, um das zu reparieren; das verschlechtert die Situation.

### Mein externes Laufwerk ist exFAT. Kann ich WeChat-Daten migrieren? <a href="#mein-externes-laufwerk-ist-exfat-kann-ich-wechat-daten-migrieren" id="mein-externes-laufwerk-ist-exfat-kann-ich-wechat-daten-migrieren"></a>

Nein, Mount-Migration unterstützt nur APFS. **Alles unverändert zu lassen ist völlig in Ordnung:** WeChat-Daten bleiben lokal nutzbar, Apps und andere Datenordner können weiter auf dieses Laufwerk. Später ist ein anderes APFS-Laufwerk am einfachsten. Gibt es bereits nicht zugewiesenen Speicher, kann bei geeigneter Partitionsanordnung eine APFS-Partition erstellt werden. Belegt exFAT das ganze Laufwerk, können macOS- und Windows-Systemwerkzeuge es nicht direkt verkleinern; zuerst sichern und neu partitionieren. Freier Speicher innerhalb von exFAT ist kein nicht zugewiesener Speicher. Der getestete Image-Umweg wurde verworfen, weil das gesamte Image beim Abziehtest unbrauchbar wurde. Siehe [Warum APFS erforderlich ist](why-apfs.md#what-to-do). Apps selbst und andere Datenordner sind nicht betroffen.

### Erscheinen nach Mount-Migration zusätzliche Laufwerkssymbole im Finder? <a href="#erscheinen-nach-mount-migration-zusatzliche-laufwerkssymbole-im-finder" id="erscheinen-nach-mount-migration-zusatzliche-laufwerkssymbole-im-finder"></a>

Nein. Die Datenvolumes werden in Seitenleiste und Schreibtisch ausgeblendet. Direkt nach dem Anschließen können sie ein bis zwei Sekunden erscheinen, verschwinden aber nach dem erneuten Einbinden. Im Festplattendienstprogramm bleiben `AppPorts-…`-Volumes sichtbar. Darauf liegen die Daten; lösche sie nicht. Siehe [Mount-Migration im Alltag](datamigrae/mount-migration.md#alltag).

### Warum kann mein verschlüsseltes Laufwerk keine Mount-Migration verwenden? <a href="#warum-kann-mein-verschlusseltes-laufwerk-keine-mount-migration-verwenden" id="warum-kann-mein-verschlusseltes-laufwerk-keine-mount-migration-verwenden"></a>

Das neue Datenvolume übernimmt das Passwort des ursprünglichen Volumes nicht. Geschützte Daten würden auf einem passwortlosen Volume landen. AppPorts stoppt deshalb, statt die Sicherheit unbemerkt zu verringern. Siehe [Verschlüsselte externe Laufwerke](why-apfs.md#encrypted-drives).

### Was muss ich vor dem Löschen von AppPorts tun? <a href="#was-muss-ich-vor-dem-loschen-von-appports-tun" id="was-muss-ich-vor-dem-loschen-von-appports-tun"></a>

Stelle per Mount-Migration migrierte Ordner unter „App Data“ mit „Wiederherstellen“ lokal wieder her. Andernfalls bleiben die Daten extern erhalten, werden bei der Anmeldung aber nicht mehr verbunden. Die App sieht dann einen leeren Ordner. Eine Neuinstallation von AppPorts und einmaliges Öffnen beheben dies.

### Hängt ein plötzlicher App-Ausfall nach macOS 27 mit früherer Datenmigration zusammen? <a href="#hangt-ein-plotzlicher-app-ausfall-nach-macos-27-mit-fruherer-datenmigration-zusammen" id="hangt-ein-plotzlicher-app-ausfall-nach-macos-27-mit-fruherer-datenmigration-zusammen"></a>

Die Daten sind intakt; die Signatur ist das Problem. Wer bei früherer Containermigration der Neusignierung zustimmte, entfernte die Sandbox-Identität der App. macOS 27 verweigert ihr den Zugriff auf den eigenen Container. Stelle die Daten wieder her und installiere die App neu. Siehe [Upgrade auf macOS 27](macos-27.md).

### Eignen sich Crossover, Parallels, virtuelle Maschinen oder Spielebibliotheken zur Migration? <a href="#eignen-sich-crossover-parallels-virtuelle-maschinen-oder-spielebibliotheken-zur-migration" id="eignen-sich-crossover-parallels-virtuelle-maschinen-oder-spielebibliotheken-zur-migration"></a>

Die App selbst ist oft nicht besonders groß. Meist belegen VM-Images, Container, Spielebibliotheken oder Modellcaches den Speicher. Prüfe zuerst unter „Datenverzeichnisse“ und „Tool-Verzeichnisse“, ob diese großen Datenordner erkannt wurden.

Bei virtuellen Datenträgern, Datenbanken oder häufig beschriebenen Dateien sind stabiler externer Speicher und ein vorheriges Backup wichtig. Netzlaufwerke werden für solche häufigen Schreibvorgänge nicht empfohlen.

### Wie stelle ich migrierte Datenordner wieder her? <a href="#wie-stelle-ich-migrierte-datenordner-wieder-her" id="wie-stelle-ich-migrierte-datenordner-wieder-her"></a>

Wähle den Ordner in der Datenverzeichnisse-Liste und klicke auf „Wiederherstellen“. Bei symbolischen Links werden zuerst Daten lokal kopiert, dann Link und externe Kopie entfernt. Bei Mount-Migration werden die Volumedaten lokal kopiert und danach das Volume entfernt. Das externe Laufwerk muss angeschlossen bleiben.

## Sonstiges <a href="#sonstiges" id="sonstiges"></a>

### Sammelt AppPorts meine Daten? <a href="#sammelt-appports-meine-daten" id="sammelt-appports-meine-daten"></a>

Nein. AppPorts arbeitet vollständig offline und sammelt oder überträgt keine Nutzerdaten. Protokolle liegen lokal unter `~/Library/Application Support/AppPorts/`.

### Wie melde ich ein Problem? <a href="#wie-melde-ich-ein-problem" id="wie-melde-ich-ein-problem"></a>

Melde es auf der [Issues-Seite](https://github.com/wzh4869/AppPorts/issues). Ein Diagnosepaket über Menüleiste → „Protokolle“ → „Diagnosepaket exportieren“ hilft bei der Eingrenzung.
